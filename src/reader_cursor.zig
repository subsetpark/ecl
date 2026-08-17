//! Scheduler-owned reader continuation. Every source, token, container, and
//! materialization transition is explicit so no native parser stack survives
//! a scheduler slice.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const lexer = @import("lexer.zig");
const binder = @import("binder.zig");
const poll = @import("poll.zig");
const reader = @import("reader_types.zig");
const storage = @import("kernel_storage.zig");
const dict = @import("dict.zig");
const text_buffer = @import("text_buffer.zig");

const Value = value.Value;
const Span = lexer.Span;
const FormList = poll.ChunkList(binder.SpannedValue);
const NameList = poll.ChunkList(binder.Name);
const TokenList = poll.ChunkList(Token);
const CodepointList = poll.ChunkList(u32);
const SpanList = poll.ChunkList(Span);
const max_nesting_depth = 10_000;

const TokenKind = enum {
    open_paren,
    open_square,
    open_dict,
    close_paren,
    close_square,
    close_dict,
    bar,
    semicolon,
    atom,
    quoted,
    character,
    string,
};
const Token = struct { kind: TokenKind, bytes: []const u8 = &.{}, span: Span };

const TokenizeProgress = union(enum) { pending, complete, incomplete: reader.Incomplete };
const Mode = enum { validate, main, comment, atom, string, character, character_unicode, complete };
const Tokenizer = struct {
    source: []const u8,
    tokens: ?*TokenList,
    cursor: lexer.Cursor,
    validate_index: usize = 0,
    mode: Mode = .validate,
    resume_mode: Mode = .main,
    token_kind: TokenKind = .atom,
    token_start: usize = 0,
    token_span: Span = .{},
    string_escaped: bool = false,
    character_first: bool = false,

    fn init(source: []const u8, tokens: ?*TokenList) Tokenizer {
        return .{ .source = source, .tokens = tokens, .cursor = .init(source) };
    }
    fn append(self: *Tokenizer, kind: TokenKind, bytes: []const u8, span: Span) error{OutOfMemory}!void {
        const tokens = self.tokens orelse return;
        try tokens.append(.{ .kind = kind, .bytes = bytes, .span = span });
    }
    fn startAtom(self: *Tokenizer, kind: TokenKind) void {
        self.token_kind = kind;
        self.token_start = self.cursor.byteIndex();
        self.token_span = self.cursor.span();
        self.mode = if (kind == .character) .character else .atom;
        self.character_first = kind == .character;
    }
    fn bump(self: *Tokenizer) u21 {
        return self.cursor.bump().?;
    }
    fn finishAtom(self: *Tokenizer) error{OutOfMemory}!void {
        try self.append(
            self.token_kind,
            self.source[self.token_start..self.cursor.byteIndex()],
            self.token_span,
        );
        self.mode = .main;
    }
    fn advance(self: *Tokenizer, diag: *reader.Diag) (error{ OutOfMemory, Parse })!TokenizeProgress {
        switch (self.mode) {
            .validate => {
                if (self.validate_index == self.source.len) {
                    self.mode = self.resume_mode;
                    return .pending;
                }
                const length = std.unicode.utf8ByteSequenceLength(self.source[self.validate_index]) catch {
                    diag.set(.{}, "source is not valid UTF-8");
                    return error.Parse;
                };
                if (length > self.source.len - self.validate_index) {
                    diag.set(.{}, "source is not valid UTF-8");
                    return error.Parse;
                }
                _ = std.unicode.utf8Decode(self.source[self.validate_index..][0..length]) catch {
                    diag.set(.{}, "source is not valid UTF-8");
                    return error.Parse;
                };
                self.validate_index += length;
                return .pending;
            },
            .main => {
                const next = self.cursor.peek() orelse {
                    self.mode = .complete;
                    return .complete;
                };
                if (lexer.isWhitespace(next) or next == ',') {
                    _ = self.bump();
                    return .pending;
                }
                if (next == '#') {
                    _ = self.bump();
                    self.mode = .comment;
                    return .pending;
                }
                const span = self.cursor.span();
                const simple: ?TokenKind = switch (next) {
                    '(' => .open_paren,
                    '[' => .open_square,
                    '{' => .open_dict,
                    ')' => .close_paren,
                    ']' => .close_square,
                    '}' => .close_dict,
                    '|' => .bar,
                    ';' => .semicolon,
                    else => null,
                };
                if (simple) |kind| {
                    _ = self.bump();
                    try self.append(kind, &.{}, span);
                    return .pending;
                }
                if (next == '"') {
                    _ = self.bump();
                    self.token_start = self.cursor.byteIndex();
                    self.token_span = span;
                    self.string_escaped = false;
                    self.mode = .string;
                    return .pending;
                }
                if (next == '\'') {
                    _ = self.bump();
                    self.startAtom(.quoted);
                    return .pending;
                }
                if (next == '\\') {
                    _ = self.bump();
                    self.startAtom(.character);
                    return .pending;
                }
                self.startAtom(.atom);
                return .pending;
            },
            .comment => {
                const next = self.cursor.peek() orelse {
                    self.mode = .complete;
                    return .complete;
                };
                if (next == '\n') self.mode = .main else _ = self.bump();
                return .pending;
            },
            .atom => {
                const next = self.cursor.peek();
                if (next == null or lexer.isTokenBoundary(next.?) or next.? == ';' or next.? == '|') {
                    try self.finishAtom();
                } else _ = self.bump();
                return .pending;
            },
            .character => {
                const next = self.cursor.peek() orelse {
                    if (self.character_first) {
                        try self.finishAtom();
                        return .pending;
                    }
                    try self.finishAtom();
                    return .pending;
                };
                if (self.character_first) {
                    self.character_first = false;
                    _ = self.bump();
                    if (next == 'u' and self.cursor.peek() == '{') {
                        _ = self.bump();
                        self.mode = .character_unicode;
                    } else if (lexer.isTokenBoundary(next) or next == ';' or next == '|' or next == '\'' or next == '\\') {
                        try self.finishAtom();
                    }
                    return .pending;
                }
                if (lexer.isTokenBoundary(next) or next == ';' or next == '|')
                    try self.finishAtom()
                else
                    _ = self.bump();
                return .pending;
            },
            .character_unicode => {
                const next = self.cursor.peek() orelse return .{ .incomplete = .{
                    .message = "unclosed Unicode character literal; expected `}`",
                    .span = self.token_span,
                } };
                _ = self.bump();
                if (next == '}') try self.finishAtom();
                return .pending;
            },
            .string => {
                const next = self.cursor.peek() orelse return .{ .incomplete = .{
                    .message = if (self.string_escaped)
                        "unclosed string escape"
                    else
                        "unclosed string; expected `\"`",
                    .span = self.token_span,
                } };
                if (!self.string_escaped and next == '"') {
                    const bytes = self.source[self.token_start..self.cursor.byteIndex()];
                    _ = self.bump();
                    try self.append(.string, bytes, self.token_span);
                    self.mode = .main;
                } else {
                    _ = self.bump();
                    if (self.string_escaped)
                        self.string_escaped = false
                    else if (next == '\\')
                        self.string_escaped = true;
                }
                return .pending;
            },
            .complete => unreachable,
        }
    }
};

/// The lexical state of a cursor at the end of a source prefix.
pub const LexicalContext = union(enum) {
    /// Inside string, character-literal, or comment text, or after source the
    /// tokenizer rejects. Nothing may be spliced in here.
    inert,
    /// In code, with an atom in progress starting at this byte offset.
    atom: usize,
    /// In code at a token boundary, so there is no partial name.
    boundary,
};

/// The tokenizer's state after some prefix of a unit. Private, because a
/// checkpoint is only meaningful beside the bytes that produced it; the pair
/// is exposed as `PendingUnit` so the two cannot be supplied separately or
/// forged from a literal.
const LexicalCheckpoint = union(enum) {
    lexing: struct { mode: Mode, string_escaped: bool, character_first: bool },
    /// The unit already contains source the reader rejects.
    rejected,

    pub const initial: LexicalCheckpoint = .{
        .lexing = .{ .mode = .main, .string_escaped = false, .character_first = false },
    };
};

fn resumed(checkpoint: LexicalCheckpoint, source: []const u8) ?Tokenizer {
    const state = switch (checkpoint) {
        .rejected => return null,
        .lexing => |state| state,
    };
    var tokenizer: Tokenizer = .init(source, null);
    tokenizer.resume_mode = if (state.mode == .complete) .main else state.mode;
    tokenizer.string_escaped = state.string_escaped;
    tokenizer.character_first = state.character_first;
    return tokenizer;
}

fn snapshot(tokenizer: *const Tokenizer) LexicalCheckpoint {
    return .{ .lexing = .{
        .mode = if (tokenizer.mode == .complete) .main else tokenizer.mode,
        .string_escaped = tokenizer.string_escaped,
        .character_first = tokenizer.character_first,
    } };
}

/// Extend a checkpoint over more of the same unit. Callers append a physical
/// line and advance once, so the cost across a whole unit is linear in the
/// unit rather than quadratic in the number of lines.
fn advanceLexical(checkpoint: LexicalCheckpoint, source: []const u8) LexicalCheckpoint {
    var diag: reader.Diag = .{};
    var tokenizer = resumed(checkpoint, source) orelse return .rejected;
    while (true) switch (tokenizer.advance(&diag) catch return .rejected) {
        .pending => {},
        .complete, .incomplete => break,
    };
    return snapshot(&tokenizer);
}

/// Where a cursor at the end of `source` sits, given the unit's checkpoint.
/// The tokenizer finishes an in-progress atom when it runs out of input, so
/// the walk stops on the step before that and reads the live mode instead.
fn lexicalContext(checkpoint: LexicalCheckpoint, source: []const u8) LexicalContext {
    var diag: reader.Diag = .{};
    var tokenizer = resumed(checkpoint, source) orelse return .inert;
    while (tokenizer.mode == .validate or tokenizer.cursor.byteIndex() != source.len) {
        switch (tokenizer.advance(&diag) catch return .inert) {
            .pending => {},
            .complete, .incomplete => break,
        }
    }
    return switch (tokenizer.mode) {
        .atom => .{ .atom = tokenizer.token_start },
        .main, .complete => .boundary,
        else => .inert,
    };
}

const PendingUnitBacking = struct {
    text: text_buffer.TextBuffer,
    checkpoint: LexicalCheckpoint = .initial,
};

/// The source accumulated for the unit being typed, together with the
/// tokenizer state at its end. The two are one opaque value because a state
/// paired with the wrong bytes is exactly the defect this replaces, and
/// because only the reader can produce a state that describes them.
pub const PendingUnit = enum(usize) {
    _,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!PendingUnit {
        const backing = try allocator.create(PendingUnitBacking);
        backing.* = .{ .text = .init(allocator) };
        return @enumFromInt(@intFromPtr(backing));
    }
    fn state(self: PendingUnit) *PendingUnitBacking {
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn deinit(self: *PendingUnit) void {
        const owned = self.state();
        const allocator = owned.text.allocator;
        owned.text.deinit();
        allocator.destroy(owned);
        self.* = undefined;
    }
    pub fn source(self: PendingUnit) []const u8 {
        return self.state().text.items();
    }
    pub fn isEmpty(self: PendingUnit) bool {
        return self.state().text.len() == 0;
    }
    /// Append a physical line and its newline, then extend the state over
    /// exactly those bytes. The storage owns and reserves before it writes, so
    /// `line` may be a slice of this unit's own source and a failure leaves
    /// the state describing exactly the bytes the unit still holds.
    pub fn appendLine(self: PendingUnit, line: []const u8) error{OutOfMemory}!void {
        const owned = self.state();
        const start = owned.text.len();
        try owned.text.splice(start, start, &.{ line, "\n" });
        owned.checkpoint = advanceLexical(owned.checkpoint, owned.text.items()[start..]);
    }
    pub fn clear(self: PendingUnit) void {
        const owned = self.state();
        owned.text.splice(0, owned.text.len(), &.{}) catch unreachable;
        owned.checkpoint = .initial;
    }
    /// Where a cursor at the end of `line_prefix` sits, continuing from this
    /// unit. Only the new bytes are scanned, so asking costs the line rather
    /// than everything typed before it.
    pub fn contextAfter(self: PendingUnit, line_prefix: []const u8) LexicalContext {
        return lexicalContext(self.state().checkpoint, line_prefix);
    }
};

const ScalarProgress = union(enum) { pending, complete: Value };
const AtomBuilder = struct {
    token: Token,
    quoted: bool,
    classifier: ?lexer.ClassifyCursor = null,
    classification: ?lexer.Classification = null,
    symbol: ?lexer.SymbolCursor = null,
    inserter: ?intern.InternInsertionCursor = null,
    task_index: usize = 0,
    task_possible: bool,

    fn init(token: Token, quoted: bool) AtomBuilder {
        return .{
            .token = token,
            .quoted = quoted,
            .task_possible = !quoted and std.mem.startsWith(u8, token.bytes, "<task:") and
                token.bytes.len >= "<task:0>".len and token.bytes[token.bytes.len - 1] == '>',
        };
    }
    fn advance(self: *AtomBuilder, diag: *reader.Diag) (error{ OutOfMemory, Parse })!ScalarProgress {
        if (self.task_possible) {
            const end = self.token.bytes.len - 1;
            if (self.task_index == 0) self.task_index = 6;
            if (self.task_index != end) {
                if (!std.ascii.isDigit(self.token.bytes[self.task_index])) {
                    self.task_possible = false;
                } else self.task_index += 1;
                return .pending;
            }
            diag.set(self.token.span, "task display markers are runtime-only and cannot be parsed");
            return error.Parse;
        }
        if (!self.quoted and self.classification == null) {
            if (self.classifier == null) self.classifier = .init(self.token.bytes);
            return switch (self.classifier.?.advance()) {
                .pending => .pending,
                .complete => |classification| result: {
                    self.classification = classification;
                    switch (classification) {
                        .int => |number| break :result .{ .complete = .{ .int = number } },
                        .float => |number| break :result .{ .complete = .{ .float = number } },
                        .out_of_range => |kind| {
                            switch (kind) {
                                .integer => diag.setFmt(
                                    self.token.span,
                                    "integer literal `{s}` is outside int64",
                                    .{self.token.bytes},
                                ),
                                .float => diag.setFmt(
                                    self.token.span,
                                    "float literal `{s}` is outside float64",
                                    .{self.token.bytes},
                                ),
                            }
                            return error.Parse;
                        },
                        .word => {},
                    }
                    self.symbol = .init(self.token.bytes);
                    break :result .pending;
                },
            };
        }
        if (self.symbol == null) self.symbol = .init(self.token.bytes);
        if (self.inserter == null) switch (self.symbol.?.advance()) {
            .pending => return .pending,
            .complete => |valid| {
                if (!valid) {
                    if (self.quoted and self.token.bytes.len == 0)
                        diag.set(self.token.span, "quoted symbol is missing its name")
                    else if (self.quoted)
                        diag.setFmt(
                            self.token.span,
                            "invalid quoted symbol `'{s}`",
                            .{self.token.bytes},
                        )
                    else
                        diag.setFmt(
                            self.token.span,
                            "invalid word `{s}`",
                            .{self.token.bytes},
                        );
                    return error.Parse;
                }
                self.inserter = intern.insertionCursor(self.token.bytes);
                return .pending;
            },
        };
        return switch (try self.inserter.?.advance()) {
            .pending => .pending,
            .complete => |id| .{ .complete = if (self.quoted) .{ .symbol = id } else .{ .word = id } },
        };
    }
};

const StringBuilder = struct {
    allocator: std.mem.Allocator,
    token: Token,
    spans: *reader.SpanTable,
    index: usize = 0,
    line: u32,
    col: u32,
    codepoints: CodepointList,
    char_spans: SpanList,
    unicode_value: u32 = 0,
    unicode_digits: usize = 0,
    unicode_span: Span = .{},
    unicode_mode: bool = false,
    codepoint_array: ?[]u32 = null,
    span_array: ?[]Span = null,
    codepoint_iterator: ?CodepointList.Iterator = null,
    span_iterator: ?SpanList.Iterator = null,
    copy_index: usize = 0,
    materializer: ?storage.CodepointMaterializer = null,
    result: ?Value = null,
    span_writer: ?reader.SpanTable.PutCursor = null,
    phase: enum { parse, copy_codepoints, copy_spans, materialize, spans, complete } = .parse,

    fn init(allocator: std.mem.Allocator, token: Token, spans: *reader.SpanTable) StringBuilder {
        return .{
            .allocator = allocator,
            .token = token,
            .spans = spans,
            .line = token.span.line,
            .col = token.span.col + 1,
            .codepoints = .init(allocator),
            .char_spans = .init(allocator),
        };
    }
    fn deinit(self: *StringBuilder, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
    fn retire(self: *StringBuilder, releases: *heap.ReleaseDomain) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        if (self.span_writer) |*writer| writer.deinit();
        if (self.result) |item| releases.releaseValue(item);
        if (self.codepoint_array) |items| self.allocator.free(items);
        if (self.span_array) |items| self.allocator.free(items);
        self.codepoints.retire(releases);
        self.char_spans.retire(releases);
        self.* = undefined;
    }
    fn bump(self: *StringBuilder) u21 {
        const length = std.unicode.utf8ByteSequenceLength(self.token.bytes[self.index]) catch
            @panic("validated string token contains an invalid UTF-8 start byte");
        const codepoint = std.unicode.utf8Decode(self.token.bytes[self.index..][0..length]) catch
            @panic("validated string token contains invalid UTF-8");
        self.index += length;
        if (codepoint == '\n') {
            self.line += 1;
            self.col = 1;
        } else self.col += 1;
        return codepoint;
    }
    fn append(self: *StringBuilder, codepoint: u32, span: Span) error{OutOfMemory}!void {
        try self.codepoints.append(codepoint);
        try self.char_spans.append(span);
    }
    fn failUnknown(self: *StringBuilder, diag: *reader.Diag, codepoint: u21, span: Span) error{Parse} {
        _ = self;
        diag.setFmt(span, "unknown string escape `\\{u}`", .{codepoint});
        return error.Parse;
    }
    fn parseOne(self: *StringBuilder, diag: *reader.Diag) (error{ OutOfMemory, Parse })!void {
        if (self.unicode_mode) {
            if (self.index == self.token.bytes.len) {
                diag.set(self.unicode_span, "unclosed Unicode escape; expected `}`");
                return error.Parse;
            }
            const codepoint = self.bump();
            if (codepoint == '}') {
                if (self.unicode_digits == 0 or self.unicode_digits > 6 or
                    self.unicode_value > 0x10ffff or
                    (self.unicode_value >= 0xd800 and self.unicode_value <= 0xdfff))
                {
                    diag.set(self.unicode_span, "invalid Unicode escape");
                    return error.Parse;
                }
                try self.append(self.unicode_value, self.unicode_span);
                self.unicode_mode = false;
                return;
            }
            if (codepoint > 0x7f or !std.ascii.isHex(@intCast(codepoint))) {
                diag.setFmt(self.unicode_span, "invalid character `{u}` in string", .{codepoint});
                return error.Parse;
            }
            self.unicode_digits += 1;
            if (self.unicode_digits > 6) return;
            self.unicode_value = self.unicode_value * 16 +
                @as(u32, std.fmt.charToDigit(@intCast(codepoint), 16) catch
                    @panic("validated Unicode escape contains a non-hex digit"));
            return;
        }
        if (self.index == self.token.bytes.len) {
            self.codepoint_array = try self.allocator.alloc(u32, self.codepoints.count);
            self.span_array = try self.allocator.alloc(Span, self.char_spans.count);
            self.codepoint_iterator = self.codepoints.iterator();
            self.span_iterator = self.char_spans.iterator();
            self.phase = .copy_codepoints;
            return;
        }
        const span: Span = .{ .line = self.line, .col = self.col };
        const next = self.bump();
        if (next != '\\') return self.append(next, span);
        if (self.index == self.token.bytes.len) {
            diag.set(self.token.span, "unclosed string escape");
            return error.Parse;
        }
        const escaped = self.bump();
        const codepoint: u32 = switch (escaped) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            't' => '\t',
            'u' => if (self.index != self.token.bytes.len and self.token.bytes[self.index] == '{') {
                _ = self.bump();
                self.unicode_mode = true;
                self.unicode_value = 0;
                self.unicode_digits = 0;
                self.unicode_span = span;
                return;
            } else return self.failUnknown(diag, escaped, span),
            else => return self.failUnknown(diag, escaped, span),
        };
        try self.append(codepoint, span);
    }
    fn advance(self: *StringBuilder, diag: *reader.Diag) (error{ OutOfMemory, Parse })!ScalarProgress {
        return switch (self.phase) {
            .parse => result: {
                try self.parseOne(diag);
                break :result .pending;
            },
            .copy_codepoints => if (self.codepoint_iterator.?.next()) |item| result: {
                self.codepoint_array.?[self.copy_index] = item.*;
                self.copy_index += 1;
                break :result .pending;
            } else result: {
                self.copy_index = 0;
                self.phase = .copy_spans;
                break :result .pending;
            },
            .copy_spans => if (self.span_iterator.?.next()) |item| result: {
                self.span_array.?[self.copy_index] = item.*;
                self.copy_index += 1;
                break :result .pending;
            } else result: {
                self.materializer = .init(self.allocator, self.codepoint_array.?);
                self.phase = .materialize;
                break :result .pending;
            },
            .materialize => switch (try self.materializer.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.result = item;
                    self.materializer.?.deinit();
                    self.materializer = null;
                    self.span_writer = .init(self.spans, self.allocator, item.list, self.span_array.?);
                    self.phase = .spans;
                    break :result .pending;
                },
            },
            .spans => switch (try self.span_writer.?.advance()) {
                .pending => .pending,
                .complete => result: {
                    self.span_writer.?.deinit();
                    self.span_writer = null;
                    const item = self.result.?;
                    self.result = null;
                    self.phase = .complete;
                    break :result .{ .complete = item };
                },
            },
            .complete => unreachable,
        };
    }
};

const CharacterBuilder = struct {
    token: Token,
    index: usize = 0,
    value: u32 = 0,
    digits: usize = 0,
    unicode: bool,

    fn init(token: Token) CharacterBuilder {
        return .{
            .token = token,
            .unicode = std.mem.startsWith(u8, token.bytes, "u{") and
                token.bytes.len >= 3 and token.bytes[token.bytes.len - 1] == '}',
            .index = if (std.mem.startsWith(u8, token.bytes, "u{")) 2 else 0,
        };
    }

    fn advance(self: *CharacterBuilder, diag: *reader.Diag) error{Parse}!ScalarProgress {
        if (self.token.bytes.len == 0) {
            diag.set(self.token.span, "character literal is missing its character");
            return error.Parse;
        }
        if (!self.unicode) {
            if (std.mem.eql(u8, self.token.bytes, "space")) return .{ .complete = .{ .char = ' ' } };
            if (std.mem.eql(u8, self.token.bytes, "tab")) return .{ .complete = .{ .char = '\t' } };
            if (std.mem.eql(u8, self.token.bytes, "newline")) return .{ .complete = .{ .char = '\n' } };
            const length = std.unicode.utf8ByteSequenceLength(self.token.bytes[0]) catch
                @panic("validated character token contains an invalid UTF-8 start byte");
            if (length != self.token.bytes.len) {
                diag.setFmt(self.token.span, "unknown character name `\\{s}`", .{self.token.bytes});
                return error.Parse;
            }
            return .{ .complete = .{ .char = std.unicode.utf8Decode(self.token.bytes) catch
                @panic("validated character token contains invalid UTF-8") } };
        }
        const end = self.token.bytes.len - 1;
        if (self.index != end) {
            const byte = self.token.bytes[self.index];
            self.index += 1;
            if (!std.ascii.isHex(byte)) {
                diag.setFmt(
                    self.token.span,
                    "invalid character `{u}` in Unicode character literal",
                    .{@as(u21, byte)},
                );
                return error.Parse;
            }
            self.digits += 1;
            if (self.digits <= 6)
                self.value = self.value * 16 + (std.fmt.charToDigit(byte, 16) catch
                    @panic("validated character escape contains a non-hex digit"));
            return .pending;
        }
        if (self.digits == 0 or self.digits > 6) {
            diag.set(self.token.span, "a Unicode escape needs one to six hexadecimal digits");
            return error.Parse;
        }
        if (self.value > 0x10ffff or (self.value >= 0xd800 and self.value <= 0xdfff)) {
            diag.setFmt(self.token.span, "U+{X:0>4} is not a Unicode scalar value", .{self.value});
            return error.Parse;
        }
        return .{ .complete = .{ .char = self.value } };
    }
};

const ScalarBuilder = union(enum) {
    atom: AtomBuilder,
    string: StringBuilder,
    character: CharacterBuilder,
    fn deinit(self: *ScalarBuilder, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .string => |*builder| builder.deinit(releases),
            .atom, .character => {},
        }
        self.* = undefined;
    }
};

const ContainerKind = enum {
    paren,
    square,
    dictionary,

    fn open(self: ContainerKind) u21 {
        return switch (self) {
            .paren => '(',
            .square => '[',
            .dictionary => '{',
        };
    }
    fn close(self: ContainerKind) u21 {
        return switch (self) {
            .paren => ')',
            .square => ']',
            .dictionary => '}',
        };
    }
};

const Context = struct {
    const BinderState = union(enum) {
        unavailable,
        unchecked,
        body,
        names: Span,
        body_with_binder,
    };

    kind: ContainerKind,
    start: Span,
    body: FormList,
    names: NameList,
    binder: BinderState,

    fn init(allocator: std.mem.Allocator, kind: ContainerKind, start: Span) Context {
        return .{
            .kind = kind,
            .start = start,
            .body = .init(allocator),
            .names = .init(allocator),
            .binder = if (kind == .dictionary) .unavailable else .unchecked,
        };
    }
    fn hasBinder(self: *const Context) bool {
        return self.binder == .body_with_binder;
    }
    fn deinit(self: *Context, releases: *heap.ReleaseDomain) void {
        self.body.retire(releases);
        self.names.retire(releases);
        self.* = undefined;
    }
    fn retire(self: *Context, releases: *heap.ReleaseDomain) void {
        self.body.retire(releases);
        self.names.retire(releases);
        self.* = undefined;
    }
};

const CollectionProgress = union(enum) { pending, complete: binder.SpannedValue };
const CollectionBuilder = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    context: Context,
    spans: *reader.SpanTable,
    diag: *reader.Diag,
    phase: enum {
        allocate_body,
        copy_body,
        allocate_names,
        copy_names,
        lower,
        lowered_spans,
        allocate_elements,
        copy_elements,
        materialize_list,
        list_spans,
        allocate_pairs,
        copy_pairs,
        materialize_dict,
        complete,
    } = .allocate_body,
    body: ?[]binder.SpannedValue = null,
    body_iterator: ?FormList.Iterator = null,
    names: ?[]binder.Name = null,
    name_iterator: ?NameList.Iterator = null,
    lowered: ?[]binder.SpannedValue = null,
    lowered_values: ?heap.OwnedValueBuffer = null,
    lowerer: ?binder.LowerCursor = null,
    lowered_span_index: usize = 0,
    generated_span_writer: ?reader.SpanTable.PutCursor = null,
    values: ?[]Value = null,
    element_spans: ?[]Span = null,
    element_index: usize = 0,
    materializer: ?storage.ValueMaterializer = null,
    span_writer: ?reader.SpanTable.PutCursor = null,
    pairs: ?[]dict.Pair = null,
    pair_index: usize = 0,
    dict_materializer: ?storage.DictMaterializer = null,
    result: ?Value = null,

    fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        context: Context,
        spans: *reader.SpanTable,
        diag: *reader.Diag,
    ) CollectionBuilder {
        return .{
            .allocator = allocator,
            .releases = releases,
            .context = context,
            .spans = spans,
            .diag = diag,
        };
    }
    fn deinit(self: *CollectionBuilder, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
    fn retire(self: *CollectionBuilder, releases: *heap.ReleaseDomain) void {
        if (self.lowerer) |*lowerer| lowerer.deinit();
        if (self.generated_span_writer) |*writer| writer.deinit();
        if (self.materializer) |*materializer| materializer.retire(releases);
        if (self.span_writer) |*writer| writer.deinit();
        if (self.dict_materializer) |*materializer| materializer.retire(releases);
        if (self.result) |item| releases.releaseValue(item);
        if (self.lowered_values) |*values| values.deinit();
        if (self.lowered) |forms| self.allocator.free(forms);
        if (self.body) |forms| self.allocator.free(forms);
        if (self.names) |names| self.allocator.free(names);
        if (self.values) |values| self.allocator.free(values);
        if (self.element_spans) |spans| self.allocator.free(spans);
        if (self.pairs) |pairs| self.allocator.free(pairs);
        self.context.retire(releases);
        self.* = undefined;
    }
    fn elements(self: *const CollectionBuilder) []const binder.SpannedValue {
        return self.lowered orelse self.body.?;
    }
    fn advance(self: *CollectionBuilder) (error{ OutOfMemory, Parse })!CollectionProgress {
        return switch (self.phase) {
            .allocate_body => result: {
                self.body = try self.allocator.alloc(binder.SpannedValue, self.context.body.count);
                self.body_iterator = self.context.body.iterator();
                self.phase = .copy_body;
                break :result .pending;
            },
            .copy_body => if (self.body_iterator.?.next()) |form| result: {
                self.body.?[self.element_index] = form.*;
                self.element_index += 1;
                break :result .pending;
            } else result: {
                self.element_index = 0;
                self.phase = if (self.context.hasBinder()) .allocate_names else if (self.context.kind == .dictionary)
                    .allocate_pairs
                else
                    .allocate_elements;
                break :result .pending;
            },
            .allocate_names => result: {
                self.names = try self.allocator.alloc(binder.Name, self.context.names.count);
                self.name_iterator = self.context.names.iterator();
                self.phase = .copy_names;
                break :result .pending;
            },
            .copy_names => if (self.name_iterator.?.next()) |name| result: {
                self.names.?[self.element_index] = name.*;
                self.element_index += 1;
                break :result .pending;
            } else result: {
                self.element_index = 0;
                self.lowerer = try .init(
                    self.allocator,
                    self.releases,
                    self.names.?,
                    self.body.?,
                    self.context.start,
                    self.diag,
                );
                self.phase = .lower;
                break :result .pending;
            },
            .lower => switch (try self.lowerer.?.advance()) {
                .pending => .pending,
                .complete => |completed| result: {
                    self.lowered = completed.forms;
                    self.lowered_values = completed.values;
                    self.lowerer.?.deinit();
                    self.lowerer = null;
                    self.phase = .lowered_spans;
                    break :result .pending;
                },
            },
            .lowered_spans => result: {
                if (self.generated_span_writer) |*writer| switch (try writer.advance()) {
                    .pending => break :result .pending,
                    .complete => {
                        writer.deinit();
                        self.generated_span_writer = null;
                        self.lowered_span_index += 1;
                        break :result .pending;
                    },
                };
                if (self.lowered_span_index == self.lowered.?.len) {
                    self.phase = .allocate_elements;
                    break :result .pending;
                }
                const item = self.lowered.?[self.lowered_span_index].value;
                if (item == .list) {
                    self.generated_span_writer = .initUniform(
                        self.spans,
                        self.allocator,
                        item.list,
                        self.context.start,
                    );
                } else self.lowered_span_index += 1;
                break :result .pending;
            },
            .allocate_elements => result: {
                const count = self.elements().len;
                self.values = try self.allocator.alloc(Value, count);
                self.element_spans = try self.allocator.alloc(Span, count);
                self.phase = .copy_elements;
                break :result .pending;
            },
            .copy_elements => result: {
                const source_elements = self.elements();
                if (self.element_index != source_elements.len) {
                    self.values.?[self.element_index] = source_elements[self.element_index].value;
                    self.element_spans.?[self.element_index] = source_elements[self.element_index].span;
                    self.element_index += 1;
                    break :result .pending;
                }
                self.materializer = .init(self.allocator, self.values.?);
                self.phase = .materialize_list;
                break :result .pending;
            },
            .materialize_list => switch (try self.materializer.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.materializer.?.deinit();
                    self.materializer = null;
                    if (self.lowered_values) |*values| values.deinit();
                    self.lowered_values = null;
                    self.result = item;
                    self.span_writer = .init(
                        self.spans,
                        self.allocator,
                        item.list,
                        self.element_spans.?,
                    );
                    self.phase = .list_spans;
                    break :result .pending;
                },
            },
            .list_spans => switch (try self.span_writer.?.advance()) {
                .pending => .pending,
                .complete => result: {
                    self.span_writer.?.deinit();
                    self.span_writer = null;
                    const item = self.result.?;
                    self.result = null;
                    self.phase = .complete;
                    break :result .{ .complete = .{ .value = item, .span = self.context.start } };
                },
            },
            .allocate_pairs => result: {
                if (self.body.?.len % 2 != 0) {
                    self.diag.set(
                        self.body.?[self.body.?.len - 1].span,
                        "dictionary literal key is missing its value",
                    );
                    return error.Parse;
                }
                self.pairs = try self.allocator.alloc(dict.Pair, self.body.?.len / 2);
                self.phase = .copy_pairs;
                break :result .pending;
            },
            .copy_pairs => result: {
                if (self.pair_index != self.pairs.?.len) {
                    self.pairs.?[self.pair_index] = .{
                        self.body.?[self.pair_index * 2].value,
                        self.body.?[self.pair_index * 2 + 1].value,
                    };
                    self.pair_index += 1;
                    break :result .pending;
                }
                self.dict_materializer = try .init(self.allocator, self.pairs.?, true);
                self.phase = .materialize_dict;
                break :result .pending;
            },
            .materialize_dict => switch (try self.dict_materializer.?.advance(1)) {
                .pending => .pending,
                .duplicate_key => {
                    self.diag.set(self.context.start, "dictionary literal contains a duplicate key");
                    return error.Parse;
                },
                .complete => |item| result: {
                    self.dict_materializer.?.deinit();
                    self.dict_materializer = null;
                    self.phase = .complete;
                    break :result .{ .complete = .{ .value = item, .span = self.context.start } };
                },
            },
            .complete => unreachable,
        };
    }
};

const ParseProgress = union(enum) { pending, complete, incomplete: reader.Incomplete };
const ParserCursor = struct {
    const State = union(enum) {
        reading,
        scalar: ScalarBuilder,
        collection: CollectionBuilder,
        complete,
    };

    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    values: heap.OwnedValueChain,
    tokens: TokenList.Iterator,
    contexts: poll.ChunkStack(Context),
    context_depth: usize = 0,
    output: ?FormList,
    spans: *reader.SpanTable,
    diag: *reader.Diag,
    state: State = .reading,
    retirement_phase: enum { state, contexts, storage, complete } = .state,

    fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        tokens: *const TokenList,
        spans: *reader.SpanTable,
        diag: *reader.Diag,
    ) error{OutOfMemory}!ParserCursor {
        return .{
            .allocator = allocator,
            .releases = releases,
            .values = try .init(releases),
            .tokens = tokens.iterator(),
            .contexts = .init(allocator),
            .output = .init(allocator),
            .spans = spans,
            .diag = diag,
        };
    }
    fn deinit(self: *ParserCursor) void {
        switch (self.state) {
            .scalar => |*scalar| scalar.deinit(self.releases),
            .collection => |*collection| collection.deinit(self.releases),
            .reading, .complete => {},
        }
        while (self.contexts.pop()) |popped| {
            var context = popped;
            context.deinit(self.releases);
        }
        self.contexts.retire(self.releases);
        if (self.output) |*output| output.deinit();
        self.values.deinit();
        self.* = undefined;
    }
    fn retireCompleted(self: *ParserCursor) void {
        std.debug.assert(self.state == .complete and self.contexts.isEmpty());
        self.contexts.retire(self.releases);
        std.debug.assert(self.output == null);
        self.values.deinit();
        self.* = undefined;
    }
    fn advanceRetirement(self: *ParserCursor) bool {
        return switch (self.retirement_phase) {
            .state => result: {
                switch (self.state) {
                    .scalar => |*scalar| switch (scalar.*) {
                        .string => |*builder| builder.retire(self.releases),
                        else => scalar.deinit(self.releases),
                    },
                    .collection => |*collection| collection.retire(self.releases),
                    .reading, .complete => {},
                }
                self.state = .complete;
                self.retirement_phase = .contexts;
                break :result false;
            },
            .contexts => if (self.contexts.pop()) |popped| result: {
                var context = popped;
                context.retire(self.releases);
                break :result false;
            } else result: {
                self.retirement_phase = .storage;
                break :result false;
            },
            .storage => result: {
                self.contexts.retire(self.releases);
                if (self.output) |*output| output.retire(self.releases);
                self.output = null;
                self.values.deinit();
                self.retirement_phase = .complete;
                break :result true;
            },
            .complete => unreachable,
        };
    }
    fn appendOwned(self: *ParserCursor, form: binder.SpannedValue) error{OutOfMemory}!void {
        try self.values.appendOwned(form.value);
        const destination = if (self.contexts.topPtr()) |context| &context.body else &self.output.?;
        try destination.append(form);
    }
    fn beginScalar(self: *ParserCursor, token: Token) error{Parse}!void {
        std.debug.assert(self.state == .reading);
        self.state = .{ .scalar = switch (token.kind) {
            .atom => .{ .atom = .init(token, false) },
            .quoted => .{ .atom = .init(token, true) },
            .character => .{ .character = .init(token) },
            .string => .{ .string = .init(self.allocator, token, self.spans) },
            .semicolon => {
                self.diag.set(token.span, "`;` is reserved");
                return error.Parse;
            },
            .bar => {
                self.diag.set(token.span, "`|` is legal only around a list's leading binder");
                return error.Parse;
            },
            .open_paren, .open_square, .open_dict, .close_paren, .close_square, .close_dict => unreachable,
        } };
    }
    fn advanceScalar(self: *ParserCursor) (error{ OutOfMemory, Parse })!ParseProgress {
        const scalar = switch (self.state) {
            .scalar => |*scalar| scalar,
            else => unreachable,
        };
        const progress: ScalarProgress = switch (scalar.*) {
            .atom => |*builder| try builder.advance(self.diag),
            .string => |*builder| try builder.advance(self.diag),
            .character => |*builder| try builder.advance(self.diag),
        };
        return switch (progress) {
            .pending => .pending,
            .complete => |item| result: {
                const span = switch (scalar.*) {
                    inline else => |builder| builder.token.span,
                };
                scalar.deinit(self.releases);
                self.state = .reading;
                try self.appendOwned(.{ .value = item, .span = span });
                break :result .pending;
            },
        };
    }
    fn closeKind(token: TokenKind) ?u21 {
        return switch (token) {
            .close_paren => ')',
            .close_square => ']',
            .close_dict => '}',
            else => null,
        };
    }
    fn openKind(token: TokenKind) ?ContainerKind {
        return switch (token) {
            .open_paren => .paren,
            .open_square => .square,
            .open_dict => .dictionary,
            else => null,
        };
    }
    fn handleBinder(self: *ParserCursor, token: Token) (error{ OutOfMemory, Parse })!bool {
        const context = self.contexts.topPtr().?;
        switch (context.binder) {
            .unchecked => {
                if (token.kind == .bar) {
                    context.binder = .{ .names = token.span };
                    return true;
                }
                context.binder = .body;
                return false;
            },
            .unavailable, .body, .body_with_binder => return false,
            .names => {},
        }
        if (token.kind == .bar) {
            if (context.names.count == 0) {
                self.diag.set(context.binder.names, "a binder must contain at least one name");
                return error.Parse;
            }
            context.binder = .body_with_binder;
            return true;
        }
        if (token.kind != .atom) {
            self.diag.set(token.span, "binder names must be unquoted, unqualified symbols");
            return error.Parse;
        }
        try context.names.append(.{ .bytes = token.bytes, .span = token.span });
        return true;
    }
    fn closeContext(self: *ParserCursor, token: Token) (error{ OutOfMemory, Parse })!void {
        const actual = closeKind(token.kind).?;
        const active = self.contexts.topPtr() orelse {
            self.diag.setFmt(token.span, "unmatched closing delimiter `{u}`", .{actual});
            return error.Parse;
        };
        if (actual != active.kind.close()) {
            if (actual == '}' and active.kind != .dictionary)
                self.diag.set(token.span, "unmatched closing delimiter `}`")
            else
                self.diag.setFmt(
                    token.span,
                    "mismatched delimiter: `{u}` must close with `{u}`, not `{u}`",
                    .{ active.kind.open(), active.kind.close(), actual },
                );
            return error.Parse;
        }
        var context = self.contexts.pop().?;
        self.context_depth -= 1;
        self.state = .{ .collection = .init(
            self.allocator,
            self.releases,
            context,
            self.spans,
            self.diag,
        ) };
        // SAFETY: CollectionBuilder owns every allocation formerly held by
        // `context`; the moved-from local is never observed again.
        context = undefined;
    }
    fn processToken(self: *ParserCursor, token: Token) (error{ OutOfMemory, Parse })!void {
        if (self.contexts.topPtr() != null and try self.handleBinder(token)) return;
        if (openKind(token.kind)) |kind| {
            if (self.context_depth == max_nesting_depth) {
                self.diag.set(token.span, "form nesting too deep");
                return error.Parse;
            }
            try self.contexts.push(.init(self.allocator, kind, token.span));
            self.context_depth += 1;
            return;
        }
        if (closeKind(token.kind) != null) return self.closeContext(token);
        try self.beginScalar(token);
    }
    fn eof(self: *ParserCursor) ParseProgress {
        if (self.contexts.topPtr()) |context| {
            if (context.binder == .names) return .{ .incomplete = .{
                .message = "unclosed binder; expected `|`",
                .span = context.binder.names,
            } };
            return .{ .incomplete = .{
                .message = switch (context.kind) {
                    .paren => "unclosed `(`; expected `)`",
                    .square => "unclosed `[`; expected `]`",
                    .dictionary => "unclosed `{`; expected `}`",
                },
                .span = context.start,
            } };
        }
        self.state = .complete;
        return .complete;
    }
    fn advance(self: *ParserCursor) (error{ OutOfMemory, Parse })!ParseProgress {
        return switch (self.state) {
            .scalar => self.advanceScalar(),
            .collection => |*collection| switch (try collection.advance()) {
                .pending => .pending,
                .complete => |form| result: {
                    collection.deinit(self.releases);
                    self.state = .reading;
                    try self.appendOwned(form);
                    break :result .pending;
                },
            },
            .reading => result: {
                const token = self.tokens.next() orelse break :result self.eof();
                try self.processToken(token.*);
                break :result .pending;
            },
            .complete => unreachable,
        };
    }
};

pub const ReadProgress = union(enum) { pending, complete: reader.ReadResult };

/// Owns the complete read pipeline. Advancing it once performs one bounded
/// lexical, parse, lowering, provenance, or final-copy operation.
pub const ReadCursor = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    source_name: []const u8,
    source: []const u8,
    diag: *reader.Diag,
    tokens: TokenList,
    spans: reader.SpanTable,
    tokenizer: Tokenizer,
    parser: ?ParserCursor = null,
    phase: enum { tokenize, parse, allocate, copy, source_name, finish, complete } = .tokenize,
    forms: ?heap.OwnedValueBuffer = null,
    top_spans: ?[]Span = null,
    owned_source_name: ?[]u8 = null,
    form_iterator: ?FormList.Iterator = null,
    copy_index: usize = 0,
    span_retirement: ?reader.SpanTable.RetireCursor = null,
    retirement_phase: enum { parser, tokens, spans, owned, complete } = .parser,

    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
    ) ReadCursor {
        const tokens = TokenList.init(allocator);
        diag.* = .{};
        return .{
            .allocator = allocator,
            .releases = releases,
            .source_name = source_name,
            .source = source,
            .diag = diag,
            .tokenizer = .init(source, null),
            .tokens = tokens,
            .spans = .init(allocator),
        };
    }
    fn deinitHost(self: *ReadCursor) void {
        if (self.parser) |*parser| parser.deinit();
        self.tokens.retire(self.releases);
        var spans_cursor = reader.SpanTable.RetireCursor.init(&self.spans);
        while (spans_cursor.advance(self.releases) == .pending) {}
        if (self.forms) |*forms| forms.deinit();
        if (self.top_spans) |spans| self.allocator.free(spans);
        if (self.owned_source_name) |name| self.allocator.free(name);
        self.* = undefined;
    }
    pub fn advanceRetirement(self: *ReadCursor) bool {
        return switch (self.retirement_phase) {
            .parser => if (self.parser) |*parser| result: {
                if (!parser.advanceRetirement()) break :result false;
                self.parser = null;
                self.retirement_phase = .tokens;
                break :result false;
            } else result: {
                self.retirement_phase = .tokens;
                break :result false;
            },
            .tokens => result: {
                self.tokens.retire(self.releases);
                self.retirement_phase = .spans;
                break :result false;
            },
            .spans => result: {
                if (self.span_retirement == null)
                    self.span_retirement = .init(&self.spans);
                switch (self.span_retirement.?.advance(self.releases)) {
                    .pending => break :result false,
                    .complete => {
                        self.span_retirement = null;
                        self.retirement_phase = .owned;
                        break :result false;
                    },
                }
            },
            .owned => result: {
                if (self.forms) |*forms| forms.deinit();
                self.forms = null;
                if (self.top_spans) |spans| self.allocator.free(spans);
                self.top_spans = null;
                if (self.owned_source_name) |name| self.allocator.free(name);
                self.owned_source_name = null;
                self.retirement_phase = .complete;
                break :result true;
            },
            .complete => unreachable,
        };
    }
    fn incomplete(self: *ReadCursor, value_incomplete: reader.Incomplete) ReadProgress {
        self.phase = .complete;
        return .{ .complete = .{ .incomplete = value_incomplete } };
    }
    pub fn advance(self: *ReadCursor) (error{ OutOfMemory, Parse })!ReadProgress {
        if (self.tokenizer.tokens == null) self.tokenizer.tokens = &self.tokens;
        return switch (self.phase) {
            .tokenize => switch (try self.tokenizer.advance(self.diag)) {
                .pending => .pending,
                .incomplete => |value_incomplete| self.incomplete(value_incomplete),
                .complete => result: {
                    self.parser = try .init(
                        self.allocator,
                        self.releases,
                        &self.tokens,
                        &self.spans,
                        self.diag,
                    );
                    self.phase = .parse;
                    break :result .pending;
                },
            },
            .parse => switch (try self.parser.?.advance()) {
                .pending => .pending,
                .incomplete => |value_incomplete| self.incomplete(value_incomplete),
                .complete => result: {
                    self.phase = .allocate;
                    break :result .pending;
                },
            },
            .allocate => result: {
                const count = self.parser.?.output.?.count;
                self.forms = try .init(self.releases, count);
                self.top_spans = try self.allocator.alloc(Span, count);
                self.owned_source_name = try self.allocator.alloc(u8, self.source_name.len);
                self.form_iterator = self.parser.?.output.?.iterator();
                self.phase = .copy;
                break :result .pending;
            },
            .copy => if (self.form_iterator.?.next()) |form| result: {
                self.forms.?.appendBorrowed(form.value);
                self.top_spans.?[self.copy_index] = form.span;
                self.copy_index += 1;
                break :result .pending;
            } else result: {
                self.copy_index = 0;
                self.phase = .source_name;
                break :result .pending;
            },
            .source_name => result: {
                if (self.copy_index != self.source_name.len) {
                    self.owned_source_name.?[self.copy_index] = self.source_name[self.copy_index];
                    self.copy_index += 1;
                } else self.phase = .finish;
                break :result .pending;
            },
            .finish => result: {
                var output = self.parser.?.output.?;
                self.parser.?.output = null;
                output.retire(self.releases);
                self.parser.?.retireCompleted();
                self.parser = null;
                self.tokens.retire(self.releases);
                self.spans.top = self.top_spans.?;
                self.top_spans = null;
                const parsed: reader.Parsed = .{
                    .allocator = self.allocator,
                    .forms = self.forms.?.take(),
                    .releases = self.releases,
                    .spans = self.spans,
                    .source_name = self.owned_source_name.?,
                };
                self.forms = null;
                self.owned_source_name = null;
                self.spans = .init(self.allocator);
                self.phase = .complete;
                break :result .{ .complete = .{ .complete = parsed } };
            },
            .complete => unreachable,
        };
    }
};

pub fn read(
    host: *const heap.HostCleanup,
    source_name: []const u8,
    source: []const u8,
    diag: *reader.Diag,
) (error{ OutOfMemory, Parse })!reader.HostReadResult {
    const allocator = host.allocator();
    const releases = heap.hostDomain(host);
    var cursor = ReadCursor.init(allocator, releases, source_name, source, diag);
    defer cursor.deinitHost();
    while (true) switch (try cursor.advance()) {
        .pending => {},
        .complete => |result| switch (result) {
            .incomplete => |incomplete| return .{ .incomplete = incomplete },
            .complete => |parsed_value| {
                return .{ .complete = .{ .parsed = parsed_value, .host = host } };
            },
        },
    };
}
