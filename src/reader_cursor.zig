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
const Token = struct {
    kind: TokenKind,
    bytes: []const u8 = &.{},
    span: Span,
    source_start: usize = 0,
    source_end: usize = 0,
};

const SourceProgress = union(enum) { pending, complete, incomplete: reader.Incomplete };
const TokenizeProgress = SourceProgress;
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
    token_source_start: usize = 0,
    token_span: Span = .{},
    string_escaped: bool = false,
    character_first: bool = false,

    fn init(source: []const u8, tokens: ?*TokenList) Tokenizer {
        return .{ .source = source, .tokens = tokens, .cursor = .init(source) };
    }
    fn append(
        self: *Tokenizer,
        kind: TokenKind,
        bytes: []const u8,
        span: Span,
        source_start: usize,
        source_end: usize,
    ) error{OutOfMemory}!void {
        const tokens = self.tokens orelse return;
        try tokens.append(.{
            .kind = kind,
            .bytes = bytes,
            .span = span,
            .source_start = source_start,
            .source_end = source_end,
        });
    }
    fn startAtom(self: *Tokenizer, kind: TokenKind) void {
        if (kind == .atom) self.token_source_start = self.cursor.byteIndex();
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
            self.token_source_start,
            self.cursor.byteIndex(),
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
                    const source_start = self.cursor.byteIndex();
                    _ = self.bump();
                    try self.append(kind, &.{}, span, source_start, self.cursor.byteIndex());
                    return .pending;
                }
                if (next == '"') {
                    self.token_source_start = self.cursor.byteIndex();
                    _ = self.bump();
                    self.token_start = self.cursor.byteIndex();
                    self.token_span = span;
                    self.string_escaped = false;
                    self.mode = .string;
                    return .pending;
                }
                if (next == '\'') {
                    self.token_source_start = self.cursor.byteIndex();
                    _ = self.bump();
                    self.startAtom(.quoted);
                    return .pending;
                }
                if (next == '\\') {
                    self.token_source_start = self.cursor.byteIndex();
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
                    try self.append(
                        .string,
                        bytes,
                        self.token_span,
                        self.token_source_start,
                        self.cursor.byteIndex(),
                    );
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
        owned.text.remove(0, owned.text.len());
        owned.checkpoint = .initial;
    }
    /// Where a cursor at the end of `line_prefix` sits, continuing from this
    /// unit. Only the new bytes are scanned, so asking costs the line rather
    /// than everything typed before it.
    pub fn contextAfter(self: PendingUnit, line_prefix: []const u8) LexicalContext {
        return lexicalContext(self.state().checkpoint, line_prefix);
    }
};

const ScalarProgress = poll.Progress(Value);
const AtomBuilder = struct {
    token: Token,
    quoted: bool,
    /// The scope the words this atom yields were written in — the reading
    /// unit's. Zero for a quoted name, which is inert data.
    word_scope: u32,
    classifier: ?lexer.ClassifyCursor = null,
    classification: ?lexer.Classification = null,
    symbol: ?lexer.SymbolCursor = null,
    inserter: ?intern.InternInsertionCursor = null,
    task_index: usize = 0,
    /// Runtime capabilities print an unreadable marker, and this is the one
    /// place source recognizes them so every capability rejects identically.
    /// `<module>` is one exact spelling; `<task:N>` needs its digits scanned,
    /// which is why recognition is a cursor step rather than a comparison.
    marker: enum { none, module, task_digits },

    fn init(token: Token, quoted: bool, word_scope: u32) AtomBuilder {
        return .{
            .token = token,
            .word_scope = word_scope,
            .quoted = quoted,
            .marker = if (quoted)
                .none
            else if (std.mem.eql(u8, token.bytes, "<module>"))
                .module
            else if (std.mem.startsWith(u8, token.bytes, "<task:") and
                token.bytes.len >= "<task:0>".len and token.bytes[token.bytes.len - 1] == '>')
                .task_digits
            else
                .none,
        };
    }
    fn advance(self: *AtomBuilder, diag: *reader.Diag) (error{ OutOfMemory, Parse })!ScalarProgress {
        switch (self.marker) {
            .none => {},
            .module => {
                diag.set(self.token.span, "module display markers are runtime-only and cannot be parsed");
                return error.Parse;
            },
            .task_digits => {
                const end = self.token.bytes.len - 1;
                if (self.task_index == 0) self.task_index = 6;
                if (self.task_index != end) {
                    if (!std.ascii.isDigit(self.token.bytes[self.task_index])) {
                        self.marker = .none;
                    } else self.task_index += 1;
                    return .pending;
                }
                diag.set(self.token.span, "task display markers are runtime-only and cannot be parsed");
                return error.Parse;
            },
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
            .complete => |id| .{
                .complete = if (self.quoted)
                    .{ .symbol = id }
                else
                    // The unit that read this text is the scope the word was
                    // written in. A quoted name is inert data and stays unscoped.
                    .{ .word = .{ .name = id, .scope = self.word_scope } },
            },
        };
    }
};

const StringBuilder = struct {
    allocator: std.mem.Allocator,
    token: Token,
    spans: *reader.SpanTable,
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_scope: u32,
    state: State,

    const Unicode = union(enum) {
        ordinary,
        escape: struct {
            value: u32 = 0,
            digits: usize = 0,
            span: Span,
        },
    };
    const Parsing = struct {
        index: usize = 0,
        line: u32,
        col: u32,
        codepoints: CodepointList,
        char_spans: SpanList,
        unicode: Unicode = .ordinary,

        fn retire(self: *Parsing, releases: *heap.ReleaseDomain) void {
            self.codepoints.retire(releases);
            self.char_spans.retire(releases);
        }
    };
    const AllocatedCodepoints = struct {
        parsing: Parsing,
        codepoints: []u32,
    };
    const Copying = struct {
        parsing: Parsing,
        codepoints: []u32,
        spans: []Span,
        iterator: CodepointList.Iterator,
        index: usize = 0,
    };
    const State = union(enum) {
        parsing: Parsing,
        allocate_codepoints: Parsing,
        allocate_spans: AllocatedCodepoints,
        copy_codepoints: Copying,
        copy_spans: struct {
            parsing: Parsing,
            codepoints: []u32,
            spans: []Span,
            iterator: SpanList.Iterator,
            index: usize = 0,
        },
        materialize: struct {
            codepoints: []u32,
            spans: []Span,
            materializer: storage.CodepointMaterializer,
        },
        spans: struct {
            spans: []Span,
            result: Value,
            writer: reader.SpanTable.PutCursor,
        },
        complete,

        fn retire(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .parsing, .allocate_codepoints => |*parsing| parsing.retire(releases),
                .allocate_spans => |*allocated| {
                    allocator.free(allocated.codepoints);
                    allocated.parsing.retire(releases);
                },
                .copy_codepoints => |*copy| {
                    allocator.free(copy.spans);
                    allocator.free(copy.codepoints);
                    copy.parsing.retire(releases);
                },
                .copy_spans => |*copy| {
                    allocator.free(copy.spans);
                    allocator.free(copy.codepoints);
                    copy.parsing.retire(releases);
                },
                .materialize => |*materialization| {
                    materialization.materializer.retire(releases);
                    allocator.free(materialization.spans);
                    allocator.free(materialization.codepoints);
                },
                .spans => |*span_state| {
                    span_state.writer.deinit();
                    releases.releaseValue(span_state.result);
                    allocator.free(span_state.spans);
                },
                .complete => {},
            }
        }
    };

    fn init(
        allocator: std.mem.Allocator,
        token: Token,
        spans: *reader.SpanTable,
        provenance_namespace: heap.CodeProvenanceNamespace,
        word_scope: u32,
    ) StringBuilder {
        return .{
            .allocator = allocator,
            .token = token,
            .spans = spans,
            .provenance_namespace = provenance_namespace,
            .word_scope = word_scope,
            .state = .{ .parsing = .{
                .line = token.span.line,
                .col = token.span.col + 1,
                .codepoints = .init(allocator),
                .char_spans = .init(allocator),
            } },
        };
    }
    fn deinit(self: *StringBuilder, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
    fn retire(self: *StringBuilder, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases, self.allocator);
    }
    fn bump(self: *StringBuilder, parsing: *Parsing) u21 {
        const length = std.unicode.utf8ByteSequenceLength(self.token.bytes[parsing.index]) catch
            @panic("validated string token contains an invalid UTF-8 start byte");
        const codepoint = std.unicode.utf8Decode(self.token.bytes[parsing.index..][0..length]) catch
            @panic("validated string token contains invalid UTF-8");
        parsing.index += length;
        if (codepoint == '\n') {
            parsing.line += 1;
            parsing.col = 1;
        } else parsing.col += 1;
        return codepoint;
    }
    fn append(parsing: *Parsing, codepoint: u32, span: Span) error{OutOfMemory}!void {
        try parsing.codepoints.append(codepoint);
        try parsing.char_spans.append(span);
    }
    fn failUnknown(self: *StringBuilder, diag: *reader.Diag, codepoint: u21, span: Span) error{Parse} {
        _ = self;
        diag.setFmt(span, "unknown string escape `\\{u}`", .{codepoint});
        return error.Parse;
    }
    const StringParseProgress = enum { pending, complete };
    fn parseOne(
        self: *StringBuilder,
        parsing: *Parsing,
        diag: *reader.Diag,
    ) (error{ OutOfMemory, Parse })!StringParseProgress {
        switch (parsing.unicode) {
            .escape => |*unicode| {
                if (parsing.index == self.token.bytes.len) {
                    diag.set(unicode.span, "unclosed Unicode escape; expected `}`");
                    return error.Parse;
                }
                const codepoint = self.bump(parsing);
                if (codepoint == '}') {
                    if (unicode.digits == 0 or unicode.digits > 6 or
                        unicode.value > 0x10ffff or
                        (unicode.value >= 0xd800 and unicode.value <= 0xdfff))
                    {
                        diag.set(unicode.span, "invalid Unicode escape");
                        return error.Parse;
                    }
                    try append(parsing, unicode.value, unicode.span);
                    parsing.unicode = .ordinary;
                    return .pending;
                }
                if (codepoint > 0x7f or !std.ascii.isHex(@intCast(codepoint))) {
                    diag.setFmt(unicode.span, "invalid character `{u}` in string", .{codepoint});
                    return error.Parse;
                }
                unicode.digits += 1;
                if (unicode.digits <= 6)
                    unicode.value = unicode.value * 16 +
                        @as(u32, std.fmt.charToDigit(@intCast(codepoint), 16) catch
                            @panic("validated Unicode escape contains a non-hex digit"));
                return .pending;
            },
            .ordinary => {},
        }
        if (parsing.index == self.token.bytes.len) return .complete;
        const span: Span = .{ .line = parsing.line, .col = parsing.col };
        const next = self.bump(parsing);
        if (next != '\\') {
            try append(parsing, next, span);
            return .pending;
        }
        if (parsing.index == self.token.bytes.len) {
            diag.set(self.token.span, "unclosed string escape");
            return error.Parse;
        }
        const escaped = self.bump(parsing);
        const codepoint: u32 = switch (escaped) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            't' => '\t',
            'u' => if (parsing.index != self.token.bytes.len and self.token.bytes[parsing.index] == '{') {
                _ = self.bump(parsing);
                parsing.unicode = .{ .escape = .{ .span = span } };
                return .pending;
            } else return self.failUnknown(diag, escaped, span),
            else => return self.failUnknown(diag, escaped, span),
        };
        try append(parsing, codepoint, span);
        return .pending;
    }
    fn advance(
        self: *StringBuilder,
        releases: *heap.ReleaseDomain,
        diag: *reader.Diag,
    ) (error{ OutOfMemory, Parse })!ScalarProgress {
        return switch (self.state) {
            .parsing => |*parsing| switch (try self.parseOne(parsing, diag)) {
                .pending => .pending,
                .complete => result: {
                    const moved = parsing.*;
                    self.state = .{ .allocate_codepoints = moved };
                    break :result .pending;
                },
            },
            .allocate_codepoints => |*parsing| result: {
                const codepoints = try self.allocator.alloc(u32, parsing.codepoints.count);
                const moved = parsing.*;
                self.state = .{ .allocate_spans = .{
                    .parsing = moved,
                    .codepoints = codepoints,
                } };
                break :result .pending;
            },
            .allocate_spans => |*allocated| result: {
                const spans = try self.allocator.alloc(Span, allocated.parsing.char_spans.count);
                const parsing = allocated.parsing;
                const codepoints = allocated.codepoints;
                self.state = .{ .copy_codepoints = .{
                    .parsing = parsing,
                    .codepoints = codepoints,
                    .spans = spans,
                    .iterator = parsing.codepoints.iterator(),
                } };
                break :result .pending;
            },
            .copy_codepoints => |*copy| if (copy.iterator.next()) |item| result: {
                copy.codepoints[copy.index] = item.*;
                copy.index += 1;
                break :result .pending;
            } else result: {
                const parsing = copy.parsing;
                const codepoints = copy.codepoints;
                const spans = copy.spans;
                self.state = .{ .copy_spans = .{
                    .parsing = parsing,
                    .codepoints = codepoints,
                    .spans = spans,
                    .iterator = parsing.char_spans.iterator(),
                } };
                break :result .pending;
            },
            .copy_spans => |*copy| if (copy.iterator.next()) |item| result: {
                copy.spans[copy.index] = item.*;
                copy.index += 1;
                break :result .pending;
            } else result: {
                const codepoints = copy.codepoints;
                const spans = copy.spans;
                const materializer = storage.CodepointMaterializer.initCode(
                    self.allocator,
                    codepoints,
                    self.provenance_namespace,
                );
                copy.parsing.retire(releases);
                self.state = .{ .materialize = .{
                    .codepoints = codepoints,
                    .spans = spans,
                    .materializer = materializer,
                } };
                break :result .pending;
            },
            .materialize => |*materialization| switch (try materialization.materializer.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    const spans = materialization.spans;
                    materialization.materializer.deinit();
                    self.allocator.free(materialization.codepoints);
                    self.state = .{ .spans = .{
                        .spans = spans,
                        .result = item,
                        .writer = .init(self.spans, self.allocator, item.list, spans),
                    } };
                    break :result .pending;
                },
            },
            .spans => |*span_state| switch (try span_state.writer.advance()) {
                .pending => .pending,
                .complete => result: {
                    const item = span_state.result;
                    span_state.writer.deinit();
                    self.allocator.free(span_state.spans);
                    self.state = .complete;
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
    source_start: usize,
    source_end: usize = 0,
    body: FormList,
    names: NameList,
    binder: BinderState,

    fn init(allocator: std.mem.Allocator, kind: ContainerKind, start: Span, source_start: usize) Context {
        return .{
            .kind = kind,
            .start = start,
            .source_start = source_start,
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
    }
};

const CollectionProgress = poll.Progress(binder.SpannedValue);
const CollectionBuilder = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    context: Context,
    spans: *reader.SpanTable,
    diag: *reader.Diag,
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_scope: u32,
    state: State = .allocate_body,

    const Forms = union(enum) {
        body: []binder.SpannedValue,
        lowered: struct {
            forms: []binder.SpannedValue,
            values: heap.OwnedValueBuffer,
        },

        fn elements(self: *const Forms) []const binder.SpannedValue {
            return switch (self.*) {
                .body => |forms| forms,
                .lowered => |lowered| lowered.forms,
            };
        }
        fn retire(
            self: *Forms,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            _ = releases;
            switch (self.*) {
                .body => |forms| allocator.free(forms),
                .lowered => |*lowered| {
                    lowered.values.deinit();
                    allocator.free(lowered.forms);
                },
            }
        }
    };
    const State = union(enum) {
        allocate_body,
        copy_body: struct {
            body: []binder.SpannedValue,
            iterator: FormList.Iterator,
            index: usize = 0,
        },
        allocate_names: []binder.SpannedValue,
        copy_names: struct {
            body: []binder.SpannedValue,
            names: []binder.Name,
            iterator: NameList.Iterator,
            index: usize = 0,
        },
        prepare_lower: struct {
            body: []binder.SpannedValue,
            names: []binder.Name,
        },
        lowering: struct {
            body: []binder.SpannedValue,
            names: []binder.Name,
            cursor: binder.LowerCursor,
        },
        scan_lowered_spans: struct {
            forms: Forms,
            index: usize = 0,
        },
        write_lowered_span: struct {
            forms: Forms,
            index: usize,
            writer: reader.SpanTable.PutCursor,
        },
        allocate_elements: Forms,
        allocate_element_spans: struct {
            forms: Forms,
            values: []Value,
        },
        copy_elements: struct {
            forms: Forms,
            values: []Value,
            spans: []Span,
            index: usize = 0,
        },
        materialize_list: struct {
            forms: Forms,
            values: []Value,
            spans: []Span,
            materializer: storage.ValueMaterializer,
        },
        list_spans: struct {
            spans: []Span,
            result: Value,
            writer: reader.SpanTable.PutCursor,
        },
        allocate_pairs: []binder.SpannedValue,
        copy_pairs: struct {
            body: []binder.SpannedValue,
            pairs: []dict.Pair,
            index: usize = 0,
        },
        materialize_dict: struct {
            body: []binder.SpannedValue,
            pairs: []dict.Pair,
            materializer: storage.DictMaterializer,
        },
        complete,

        fn retire(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .allocate_body, .complete => {},
                .copy_body => |copy| allocator.free(copy.body),
                .allocate_names => |body| allocator.free(body),
                .copy_names => |copy| {
                    allocator.free(copy.names);
                    allocator.free(copy.body);
                },
                .prepare_lower => |preparation| {
                    allocator.free(preparation.names);
                    allocator.free(preparation.body);
                },
                .lowering => |*lowering| {
                    lowering.cursor.deinit();
                    allocator.free(lowering.names);
                    allocator.free(lowering.body);
                },
                .scan_lowered_spans => |*scan| scan.forms.retire(releases, allocator),
                .write_lowered_span => |*write| {
                    write.writer.deinit();
                    write.forms.retire(releases, allocator);
                },
                .allocate_elements => |*forms| forms.retire(releases, allocator),
                .allocate_element_spans => |*allocated| {
                    allocator.free(allocated.values);
                    allocated.forms.retire(releases, allocator);
                },
                .copy_elements => |*copy| {
                    allocator.free(copy.spans);
                    allocator.free(copy.values);
                    copy.forms.retire(releases, allocator);
                },
                .materialize_list => |*materialization| {
                    materialization.materializer.retire(releases);
                    allocator.free(materialization.spans);
                    allocator.free(materialization.values);
                    materialization.forms.retire(releases, allocator);
                },
                .list_spans => |*span_state| {
                    span_state.writer.deinit();
                    releases.releaseValue(span_state.result);
                    allocator.free(span_state.spans);
                },
                .allocate_pairs => |body| allocator.free(body),
                .copy_pairs => |copy| {
                    allocator.free(copy.pairs);
                    allocator.free(copy.body);
                },
                .materialize_dict => |*materialization| {
                    materialization.materializer.retire(releases);
                    allocator.free(materialization.pairs);
                    allocator.free(materialization.body);
                },
            }
        }
    };

    fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        context: Context,
        spans: *reader.SpanTable,
        diag: *reader.Diag,
        provenance_namespace: heap.CodeProvenanceNamespace,
        word_scope: u32,
    ) CollectionBuilder {
        return .{
            .allocator = allocator,
            .releases = releases,
            .context = context,
            .spans = spans,
            .diag = diag,
            .provenance_namespace = provenance_namespace,
            .word_scope = word_scope,
        };
    }
    fn deinit(self: *CollectionBuilder, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
    fn retire(self: *CollectionBuilder, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases, self.allocator);
        self.context.retire(releases);
    }
    fn advance(self: *CollectionBuilder) (error{ OutOfMemory, Parse })!CollectionProgress {
        return switch (self.state) {
            .allocate_body => result: {
                const body = try self.allocator.alloc(binder.SpannedValue, self.context.body.count);
                self.state = .{ .copy_body = .{
                    .body = body,
                    .iterator = self.context.body.iterator(),
                } };
                break :result .pending;
            },
            .copy_body => |*copy| if (copy.iterator.next()) |form| result: {
                copy.body[copy.index] = form.*;
                copy.index += 1;
                break :result .pending;
            } else result: {
                const body = copy.body;
                self.state = if (self.context.hasBinder())
                    .{ .allocate_names = body }
                else if (self.context.kind == .dictionary)
                    .{ .allocate_pairs = body }
                else
                    .{ .allocate_elements = .{ .body = body } };
                break :result .pending;
            },
            .allocate_names => |body| result: {
                const names = try self.allocator.alloc(binder.Name, self.context.names.count);
                self.state = .{ .copy_names = .{
                    .body = body,
                    .names = names,
                    .iterator = self.context.names.iterator(),
                } };
                break :result .pending;
            },
            .copy_names => |*copy| if (copy.iterator.next()) |name| result: {
                copy.names[copy.index] = name.*;
                copy.index += 1;
                break :result .pending;
            } else result: {
                self.state = .{ .prepare_lower = .{
                    .body = copy.body,
                    .names = copy.names,
                } };
                break :result .pending;
            },
            .prepare_lower => |*preparation| result: {
                const lowerer = try binder.LowerCursor.init(
                    self.allocator,
                    self.releases,
                    preparation.names,
                    preparation.body,
                    self.context.start,
                    self.diag,
                );
                const body = preparation.body;
                const names = preparation.names;
                self.state = .{ .lowering = .{
                    .body = body,
                    .names = names,
                    .cursor = lowerer,
                } };
                break :result .pending;
            },
            .lowering => |*lowering| switch (try lowering.cursor.advance()) {
                .pending => .pending,
                .complete => |completed| result: {
                    lowering.cursor.deinit();
                    self.allocator.free(lowering.names);
                    self.allocator.free(lowering.body);
                    self.state = .{ .scan_lowered_spans = .{
                        .forms = .{ .lowered = .{
                            .forms = completed.forms,
                            .values = completed.values,
                        } },
                    } };
                    break :result .pending;
                },
            },
            .scan_lowered_spans => |*scan| result: {
                const elements = scan.forms.elements();
                if (scan.index == elements.len) {
                    const forms = scan.forms;
                    self.state = .{ .allocate_elements = forms };
                    break :result .pending;
                }
                const item = elements[scan.index].value;
                if (item == .list) {
                    const forms = scan.forms;
                    self.state = .{ .write_lowered_span = .{
                        .forms = forms,
                        .index = scan.index,
                        .writer = .initUniform(
                            self.spans,
                            self.allocator,
                            item.list,
                            self.context.start,
                        ),
                    } };
                } else scan.index += 1;
                break :result .pending;
            },
            .write_lowered_span => |*write| switch (try write.writer.advance()) {
                .pending => .pending,
                .complete => result: {
                    write.writer.deinit();
                    const forms = write.forms;
                    self.state = .{ .scan_lowered_spans = .{
                        .forms = forms,
                        .index = write.index + 1,
                    } };
                    break :result .pending;
                },
            },
            .allocate_elements => |*forms| result: {
                const values = try self.allocator.alloc(Value, forms.elements().len);
                const moved = forms.*;
                self.state = .{ .allocate_element_spans = .{
                    .forms = moved,
                    .values = values,
                } };
                break :result .pending;
            },
            .allocate_element_spans => |*allocated| result: {
                const spans = try self.allocator.alloc(Span, allocated.forms.elements().len);
                const forms = allocated.forms;
                const values = allocated.values;
                self.state = .{ .copy_elements = .{
                    .forms = forms,
                    .values = values,
                    .spans = spans,
                } };
                break :result .pending;
            },
            .copy_elements => |*copy| result: {
                const source_elements = copy.forms.elements();
                if (copy.index != source_elements.len) {
                    copy.values[copy.index] = source_elements[copy.index].value;
                    copy.spans[copy.index] = source_elements[copy.index].span;
                    copy.index += 1;
                    break :result .pending;
                }
                const forms = copy.forms;
                const values = copy.values;
                const spans = copy.spans;
                self.state = .{ .materialize_list = .{
                    .forms = forms,
                    .values = values,
                    .spans = spans,
                    .materializer = .initCode(
                        self.allocator,
                        values,
                        self.provenance_namespace,
                    ),
                } };
                break :result .pending;
            },
            .materialize_list => |*materialization| switch (try materialization.materializer.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    const spans = materialization.spans;
                    materialization.materializer.deinit();
                    self.allocator.free(materialization.values);
                    materialization.forms.retire(self.releases, self.allocator);
                    self.state = .{ .list_spans = .{
                        .spans = spans,
                        .result = item,
                        .writer = .initSource(
                            self.spans,
                            self.allocator,
                            item.list,
                            spans,
                            self.context.source_start,
                            self.context.source_end,
                            self.context.start,
                        ),
                    } };
                    break :result .pending;
                },
            },
            .list_spans => |*span_state| switch (try span_state.writer.advance()) {
                .pending => .pending,
                .complete => result: {
                    const item = span_state.result;
                    span_state.writer.deinit();
                    self.allocator.free(span_state.spans);
                    self.state = .complete;
                    break :result .{ .complete = .{ .value = item, .span = self.context.start } };
                },
            },
            .allocate_pairs => |body| result: {
                if (body.len % 2 != 0) {
                    self.diag.set(
                        body[body.len - 1].span,
                        "dictionary literal key is missing its value",
                    );
                    return error.Parse;
                }
                const pairs = try self.allocator.alloc(dict.Pair, body.len / 2);
                self.state = .{ .copy_pairs = .{
                    .body = body,
                    .pairs = pairs,
                } };
                break :result .pending;
            },
            .copy_pairs => |*copy| result: {
                if (copy.index != copy.pairs.len) {
                    copy.pairs[copy.index] = .{
                        copy.body[copy.index * 2].value,
                        copy.body[copy.index * 2 + 1].value,
                    };
                    copy.index += 1;
                    break :result .pending;
                }
                const materializer = try storage.DictMaterializer.init(self.allocator, copy.pairs, true);
                const body = copy.body;
                const pairs = copy.pairs;
                self.state = .{ .materialize_dict = .{
                    .body = body,
                    .pairs = pairs,
                    .materializer = materializer,
                } };
                break :result .pending;
            },
            .materialize_dict => |*materialization| switch (try materialization.materializer.advance(1)) {
                .pending => .pending,
                .duplicate_key => {
                    self.diag.set(self.context.start, "dictionary literal contains a duplicate key");
                    return error.Parse;
                },
                .complete => |item| result: {
                    materialization.materializer.deinit();
                    self.allocator.free(materialization.pairs);
                    self.allocator.free(materialization.body);
                    self.state = .complete;
                    break :result .{ .complete = .{ .value = item, .span = self.context.start } };
                },
            },
            .complete => unreachable,
        };
    }
};

const ParseProgress = SourceProgress;
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
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_scope: u32,
    state: State = .reading,
    retirement_phase: enum { state, contexts, storage, complete } = .state,

    fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        tokens: *const TokenList,
        spans: *reader.SpanTable,
        diag: *reader.Diag,
        provenance_namespace: heap.CodeProvenanceNamespace,
        word_scope: u32,
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
            .provenance_namespace = provenance_namespace,
            .word_scope = word_scope,
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
            .atom => .{ .atom = .init(token, false, self.word_scope) },
            .quoted => .{ .atom = .init(token, true, self.word_scope) },
            .character => .{ .character = .init(token) },
            .string => .{ .string = .init(
                self.allocator,
                token,
                self.spans,
                self.provenance_namespace,
                self.word_scope,
            ) },
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
            .string => |*builder| try builder.advance(self.releases, self.diag),
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
        context.source_end = token.source_end;
        self.context_depth -= 1;
        self.state = .{ .collection = .init(
            self.allocator,
            self.releases,
            context,
            self.spans,
            self.diag,
            self.provenance_namespace,
            self.word_scope,
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
            try self.contexts.push(.init(self.allocator, kind, token.span, token.source_start));
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

pub const ReadProgress = poll.Progress(reader.ReadResult);

/// Owns the complete read pipeline. Advancing it once performs one bounded
/// lexical, parse, lowering, provenance, or final-copy operation.
pub const ReadCursor = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    source_name: []const u8,
    source: []const u8,
    diag: *reader.Diag,
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_scope: u32,
    tokens: TokenList,
    spans: reader.SpanTable,
    tokenizer: Tokenizer,
    parser: ?ParserCursor = null,
    phase: enum { tokenize, parse, allocate, copy, source_name, source, finish, complete } = .tokenize,
    forms: ?heap.OwnedValueBuffer = null,
    top_spans: ?[]Span = null,
    owned_source_name: ?[]u8 = null,
    owned_source: ?[]u8 = null,
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
        return initCode(allocator, releases, source_name, source, diag, .none, 0);
    }

    pub fn initCode(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
        provenance_namespace: heap.CodeProvenanceNamespace,
        word_scope: u32,
    ) ReadCursor {
        const tokens = TokenList.init(allocator);
        diag.* = .{};
        return .{
            .allocator = allocator,
            .releases = releases,
            .source_name = source_name,
            .source = source,
            .diag = diag,
            .provenance_namespace = provenance_namespace,
            .word_scope = word_scope,
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
        if (self.owned_source) |source| self.allocator.free(source);
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
                if (self.owned_source) |source| self.allocator.free(source);
                self.owned_source = null;
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
                        self.provenance_namespace,
                        self.word_scope,
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
                self.owned_source = try self.allocator.alloc(u8, self.source.len);
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
                } else {
                    self.copy_index = 0;
                    self.phase = .source;
                }
                break :result .pending;
            },
            .source => result: {
                if (self.copy_index != self.source.len) {
                    self.owned_source.?[self.copy_index] = self.source[self.copy_index];
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
                const source_bytes = self.owned_source.?;
                self.owned_source = null;
                const source_slice = try reader.SourceSlice.initOwned(self.allocator, source_bytes);
                const parsed: reader.Parsed = .{
                    .allocator = self.allocator,
                    .forms = self.forms.?.take(),
                    .releases = self.releases,
                    .spans = self.spans,
                    .source_name = self.owned_source_name.?,
                    .source = source_slice,
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
    return readCode(host, source_name, source, diag, .none, 0);
}

pub fn readCode(
    host: *const heap.HostCleanup,
    source_name: []const u8,
    source: []const u8,
    diag: *reader.Diag,
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_scope: u32,
) (error{ OutOfMemory, Parse })!reader.HostReadResult {
    const allocator = host.allocator();
    const releases = heap.hostDomain(host);
    var cursor = ReadCursor.initCode(
        allocator,
        releases,
        source_name,
        source,
        diag,
        provenance_namespace,
        word_scope,
    );
    defer cursor.deinitHost();
    return switch (try poll.driveFallible(reader.ReadResult, &cursor, .{})) {
        .incomplete => |incomplete| .{ .incomplete = incomplete },
        .complete => |parsed_value| .{ .complete = .{ .parsed = parsed_value, .host = host } },
    };
}
