//! Scheduler-owned reader continuation. Every source, token, container, and
//! materialization transition is explicit so no native parser stack survives
//! a scheduler slice.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const lexer = @import("lexer.zig");
const locals = @import("locals.zig");
const poll = @import("poll.zig");
const reader = @import("reader_types.zig");
const storage = @import("kernel_storage.zig");
const dict = @import("dict.zig");
const list = @import("list.zig");
const text_buffer = @import("text_buffer.zig");

const Value = value.Value;
const Span = lexer.Span;
const FormList = poll.ChunkList(locals.SpannedValue);
const NameList = poll.ChunkList(locals.Name);
const TokenList = poll.ChunkList(Token);
const CodepointList = poll.ChunkList(u32);
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
/// The most ASCII bytes one validation transition passes.
const ascii_run = 64;

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
    /// Runs transitions until one finishes the source or the budget is spent.
    /// Each transition costs one unit, so a step stays bounded while the
    /// layers above pay their dispatch once per budget, not once per byte.
    fn advance(self: *Tokenizer, diag: *reader.Diag, work: *poll.WorkBudget) (error{ OutOfMemory, Parse })!TokenizeProgress {
        while (work.spend()) {
            const progress = try self.step(diag);
            if (progress != .pending) return progress;
        }
        return .pending;
    }

    /// One transition: a codepoint validated, a character consumed, or a
    /// token finished.
    fn step(self: *Tokenizer, diag: *reader.Diag) (error{ OutOfMemory, Parse })!TokenizeProgress {
        switch (self.mode) {
            .validate => {
                if (self.validate_index == self.source.len) {
                    self.mode = self.resume_mode;
                    return .pending;
                }
                // ASCII needs no decoding, so one transition passes a run of
                // it, at most `ascii_run` bytes; anything else is checked one
                // sequence at a time.
                if (self.source[self.validate_index] < 0x80) {
                    const end = @min(self.source.len, self.validate_index + ascii_run);
                    while (self.validate_index != end and self.source[self.validate_index] < 0x80)
                        self.validate_index += 1;
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
    while (true) switch (tokenizer.step(&diag) catch return .rejected) {
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
        switch (tokenizer.step(&diag) catch return .inert) {
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
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }
    fn state(self: PendingUnit) *PendingUnitBacking {
        return @ptrFromInt(@backingInt(self));
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
    word_linker: value.WordLinker,
    classifier: ?lexer.ClassifyCursor = null,
    classification: ?lexer.Classification = null,
    symbol: ?lexer.SymbolCursor = null,
    inserter: ?intern.InternInsertionCursor = null,
    marker_index: usize = 0,
    /// Runtime capabilities print an unreadable marker, and this is the one
    /// place source recognizes them so every capability rejects identically.
    /// `<module>` is one exact spelling; `<task:N>` needs its digits scanned,
    /// which is why recognition is a cursor step rather than a comparison.
    marker: enum { none, module, task_digits, port_digits },

    fn init(token: Token, quoted: bool, word_linker: value.WordLinker) AtomBuilder {
        return .{
            .token = token,
            .word_linker = word_linker,
            .quoted = quoted,
            .marker = if (quoted)
                .none
            else if (std.mem.eql(u8, token.bytes, "<module>"))
                .module
            else if (std.mem.startsWith(u8, token.bytes, "<task:") and
                token.bytes.len >= "<task:0>".len and token.bytes[token.bytes.len - 1] == '>')
                .task_digits
            else if (std.mem.startsWith(u8, token.bytes, "<port:") and
                token.bytes.len >= "<port:0>".len and token.bytes[token.bytes.len - 1] == '>')
                .port_digits
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
            .task_digits => return self.advanceMarkerDigits(
                diag,
                "task display markers are runtime-only and cannot be parsed",
            ),
            .port_digits => return self.advanceMarkerDigits(
                diag,
                "port display markers are runtime-only and cannot be parsed",
            ),
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
                    .{ .word = .{ .name = id, .slot = try self.word_linker.link(id) } },
            },
        };
    }

    fn advanceMarkerDigits(
        self: *AtomBuilder,
        diag: *reader.Diag,
        message: []const u8,
    ) error{Parse}!ScalarProgress {
        const end = self.token.bytes.len - 1;
        if (self.marker_index == 0) self.marker_index = 6;
        if (self.marker_index != end) {
            if (!std.ascii.isDigit(self.token.bytes[self.marker_index])) {
                self.marker = .none;
            } else self.marker_index += 1;
            return .pending;
        }
        diag.set(self.token.span, message);
        return error.Parse;
    }
};

/// A string literal's codepoints. The string keeps one source position, its
/// own, in its enclosing list; its characters are data and record none.
const StringBuilder = struct {
    allocator: std.mem.Allocator,
    token: Token,
    provenance_namespace: heap.CodeProvenanceNamespace,
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
        /// Over the token's body, positioned in source coordinates.
        cursor: lexer.Cursor,
        codepoints: CodepointList,
        unicode: Unicode = .ordinary,

        fn retire(self: *Parsing, releases: *heap.ReleaseDomain) void {
            self.codepoints.retire(releases);
        }
    };
    const State = union(enum) {
        parsing: Parsing,
        gather: struct {
            parsing: Parsing,
            codepoints: []u32,
            from: CodepointList.Iterator,
            index: usize = 0,
        },
        materialize: struct {
            codepoints: []u32,
            materializer: list.CodepointMaterializer,
        },
        complete,

        fn retire(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .parsing => |*parsing| parsing.retire(releases),
                .gather => |*gather| {
                    allocator.free(gather.codepoints);
                    gather.parsing.retire(releases);
                },
                .materialize => |*materialization| {
                    materialization.materializer.retire(releases);
                    allocator.free(materialization.codepoints);
                },
                .complete => {},
            }
        }
    };

    fn init(
        allocator: std.mem.Allocator,
        token: Token,
        provenance_namespace: heap.CodeProvenanceNamespace,
    ) StringBuilder {
        return .{
            .allocator = allocator,
            .token = token,
            .provenance_namespace = provenance_namespace,
            .state = .{ .parsing = .{
                .cursor = .{ .source = token.bytes, .line = token.span.line, .col = token.span.col + 1 },
                .codepoints = .init(allocator),
            } },
        };
    }
    fn deinit(self: *StringBuilder, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
    fn retire(self: *StringBuilder, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases, self.allocator);
    }
    fn append(parsing: *Parsing, codepoint: u32) error{OutOfMemory}!void {
        try parsing.codepoints.append(codepoint);
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
                if (parsing.cursor.atEnd()) {
                    diag.set(unicode.span, "unclosed Unicode escape; expected `}`");
                    return error.Parse;
                }
                const codepoint = parsing.cursor.bump().?;
                if (codepoint == '}') {
                    if (unicode.digits == 0 or unicode.digits > 6 or
                        unicode.value > 0x10ffff or
                        (unicode.value >= 0xd800 and unicode.value <= 0xdfff))
                    {
                        diag.set(unicode.span, "invalid Unicode escape");
                        return error.Parse;
                    }
                    try append(parsing, unicode.value);
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
        if (parsing.cursor.atEnd()) return .complete;
        const span = parsing.cursor.span();
        const next = parsing.cursor.bump().?;
        if (next != '\\') {
            try append(parsing, next);
            return .pending;
        }
        if (parsing.cursor.atEnd()) {
            diag.set(self.token.span, "unclosed string escape");
            return error.Parse;
        }
        const escaped = parsing.cursor.bump().?;
        const codepoint: u32 = switch (escaped) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            't' => '\t',
            'u' => if (parsing.cursor.peek() == '{') {
                _ = parsing.cursor.bump().?;
                parsing.unicode = .{ .escape = .{ .span = span } };
                return .pending;
            } else return self.failUnknown(diag, escaped, span),
            else => return self.failUnknown(diag, escaped, span),
        };
        try append(parsing, codepoint);
        return .pending;
    }
    /// Gathering codepoints takes further budget units, one a codepoint.
    fn advance(
        self: *StringBuilder,
        releases: *heap.ReleaseDomain,
        diag: *reader.Diag,
        work: *poll.WorkBudget,
    ) (error{ OutOfMemory, Parse })!ScalarProgress {
        return switch (self.state) {
            .parsing => |*parsing| switch (try self.parseOne(parsing, diag)) {
                .pending => .pending,
                .complete => result: {
                    const codepoints = try self.allocator.alloc(u32, parsing.codepoints.count);
                    const moved = parsing.*;
                    self.state = .{ .gather = .{
                        .parsing = moved,
                        .codepoints = codepoints,
                        .from = moved.codepoints.iterator(),
                    } };
                    break :result .pending;
                },
            },
            .gather => |*gather| result: {
                for (0..work.chunk(gather.codepoints.len - gather.index)) |_| {
                    gather.codepoints[gather.index] = gather.from.next().?.*;
                    gather.index += 1;
                }
                if (gather.index != gather.codepoints.len) break :result .pending;
                const codepoints = gather.codepoints;
                gather.parsing.retire(releases);
                self.state = .{ .materialize = .{
                    .codepoints = codepoints,
                    .materializer = .initCode(self.allocator, codepoints, self.provenance_namespace),
                } };
                break :result .pending;
            },
            .materialize => |*materialization| switch (try poll.advanceOne(&materialization.materializer)) {
                .pending => .pending,
                .complete => |item| result: {
                    materialization.materializer.deinit();
                    self.allocator.free(materialization.codepoints);
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
    const LocalsState = union(enum) {
        unavailable,
        unchecked,
        body,
        names: Span,
        body_with_locals,
    };

    kind: ContainerKind,
    start: Span,
    source_start: usize,
    source_end: usize = 0,
    body: FormList,
    names: NameList,
    locals: LocalsState,

    fn init(allocator: std.mem.Allocator, kind: ContainerKind, start: Span, source_start: usize) Context {
        return .{
            .kind = kind,
            .start = start,
            .source_start = source_start,
            .body = .init(allocator),
            .names = .init(allocator),
            .locals = if (kind == .dictionary) .unavailable else .unchecked,
        };
    }
    fn hasLocals(self: *const Context) bool {
        return self.locals == .body_with_locals;
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

const CollectionProgress = poll.Progress(locals.SpannedValue);
const CollectionBuilder = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    context: Context,
    spans: *reader.SpanTable,
    diag: *reader.Diag,
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_linker: value.WordLinker,
    state: State = .start,

    /// Where a list's elements come from: the context's body, which keeps
    /// owning them, or a locals lowering, which owns its output.
    const ElementSource = union(enum) {
        body: FormList.Iterator,
        lowered: struct { output: locals.Lowered, index: usize = 0 },

        fn next(self: *ElementSource) locals.SpannedValue {
            return switch (self.*) {
                .body => |*iterator| iterator.next().?.*,
                .lowered => |*lowered| item: {
                    const item = lowered.output.forms[lowered.index];
                    lowered.index += 1;
                    break :item item;
                },
            };
        }
        fn retire(self: *ElementSource, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .body => {},
                .lowered => |*lowered| {
                    lowered.output.values.deinit();
                    allocator.free(lowered.output.forms);
                },
            }
        }
    };
    const State = union(enum) {
        start,
        gather_locals: struct {
            body: []locals.SpannedValue,
            names: []locals.Name,
            body_from: FormList.Iterator,
            names_from: NameList.Iterator,
            body_index: usize = 0,
            names_index: usize = 0,
        },
        lowering: struct {
            body: []locals.SpannedValue,
            names: []locals.Name,
            cursor: locals.LowerCursor,
        },
        scan_lowered_spans: struct {
            output: locals.Lowered,
            index: usize = 0,
        },
        write_lowered_span: struct {
            output: locals.Lowered,
            index: usize,
            writer: reader.SpanTable.PutCursor,
        },
        gather_elements: struct {
            source: ElementSource,
            values: []Value,
            spans: []Span,
            index: usize = 0,
        },
        materialize_list: struct {
            source: ElementSource,
            values: []Value,
            spans: []Span,
            materializer: list.ValueMaterializer,
        },
        list_spans: struct {
            spans: []Span,
            result: Value,
            writer: reader.SpanTable.PutCursor,
        },
        gather_pairs: struct {
            pairs: []dict.Pair,
            from: FormList.Iterator,
            index: usize = 0,
        },
        materialize_dict: struct {
            pairs: []dict.Pair,
            materializer: dict.Materializer,
        },
        complete,

        fn retire(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .start, .complete => {},
                .gather_locals => |gather| {
                    allocator.free(gather.names);
                    allocator.free(gather.body);
                },
                .lowering => |*lowering| {
                    lowering.cursor.deinit();
                    allocator.free(lowering.names);
                    allocator.free(lowering.body);
                },
                .scan_lowered_spans => |*scan| {
                    scan.output.values.deinit();
                    allocator.free(scan.output.forms);
                },
                .write_lowered_span => |*write| {
                    write.writer.deinit();
                    write.output.values.deinit();
                    allocator.free(write.output.forms);
                },
                .gather_elements => |*gather| {
                    allocator.free(gather.spans);
                    allocator.free(gather.values);
                    gather.source.retire(allocator);
                },
                .materialize_list => |*materialization| {
                    materialization.materializer.retire(releases);
                    allocator.free(materialization.spans);
                    allocator.free(materialization.values);
                    materialization.source.retire(allocator);
                },
                .list_spans => |*span_state| {
                    span_state.writer.deinit();
                    releases.releaseValue(span_state.result);
                    allocator.free(span_state.spans);
                },
                .gather_pairs => |gather| allocator.free(gather.pairs),
                .materialize_dict => |*materialization| {
                    materialization.materializer.retire(releases);
                    allocator.free(materialization.pairs);
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
        word_linker: value.WordLinker,
    ) CollectionBuilder {
        return .{
            .allocator = allocator,
            .releases = releases,
            .context = context,
            .spans = spans,
            .diag = diag,
            .provenance_namespace = provenance_namespace,
            .word_linker = word_linker,
        };
    }
    fn deinit(self: *CollectionBuilder, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
    fn retire(self: *CollectionBuilder, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases, self.allocator);
        self.context.retire(releases);
    }

    /// Allocates a list's values and spans and starts gathering them.
    fn gatherElements(self: *CollectionBuilder, source: ElementSource, count: usize) error{OutOfMemory}!void {
        const values = try self.allocator.alloc(Value, count);
        errdefer self.allocator.free(values);
        const spans = try self.allocator.alloc(Span, count);
        self.state = .{ .gather_elements = .{ .source = source, .values = values, .spans = spans } };
    }

    /// Each call is one paid transition; gathering elements, names, or pairs
    /// takes further units from `work`, one an element.
    fn advance(self: *CollectionBuilder, work: *poll.WorkBudget) (error{ OutOfMemory, Parse })!CollectionProgress {
        return switch (self.state) {
            .start => result: {
                const count = self.context.body.count;
                if (self.context.hasLocals()) {
                    const body = try self.allocator.alloc(locals.SpannedValue, count);
                    errdefer self.allocator.free(body);
                    const names = try self.allocator.alloc(locals.Name, self.context.names.count);
                    self.state = .{ .gather_locals = .{
                        .body = body,
                        .names = names,
                        .body_from = self.context.body.iterator(),
                        .names_from = self.context.names.iterator(),
                    } };
                } else if (self.context.kind == .dictionary) {
                    if (count % 2 != 0) {
                        self.diag.set(
                            self.context.body.lastItem().?.span,
                            "dictionary literal key is missing its value",
                        );
                        return error.Parse;
                    }
                    const pairs = try self.allocator.alloc(dict.Pair, count / 2);
                    self.state = .{ .gather_pairs = .{ .pairs = pairs, .from = self.context.body.iterator() } };
                } else try self.gatherElements(.{ .body = self.context.body.iterator() }, count);
                break :result .pending;
            },
            .gather_locals => |*gather| result: {
                for (0..work.chunk(gather.body.len - gather.body_index)) |_| {
                    gather.body[gather.body_index] = gather.body_from.next().?.*;
                    gather.body_index += 1;
                }
                if (gather.body_index != gather.body.len) break :result .pending;
                for (0..work.chunk(gather.names.len - gather.names_index)) |_| {
                    gather.names[gather.names_index] = gather.names_from.next().?.*;
                    gather.names_index += 1;
                }
                if (gather.names_index != gather.names.len) break :result .pending;
                const lowerer = try locals.LowerCursor.init(
                    self.allocator,
                    self.releases,
                    gather.names,
                    gather.body,
                    self.context.start,
                    self.diag,
                );
                const body = gather.body;
                const names = gather.names;
                self.state = .{ .lowering = .{ .body = body, .names = names, .cursor = lowerer } };
                break :result .pending;
            },
            .lowering => |*lowering| switch (try lowering.cursor.advance()) {
                .pending => .pending,
                .complete => |completed| result: {
                    lowering.cursor.deinit();
                    self.allocator.free(lowering.names);
                    self.allocator.free(lowering.body);
                    self.state = .{ .scan_lowered_spans = .{ .output = completed } };
                    break :result .pending;
                },
            },
            .scan_lowered_spans => |*scan| result: {
                // Skips non-list forms a unit each; a failed allocation below
                // leaves the scan state owning the output.
                const forms = scan.output.forms;
                var allowance = work.chunk(forms.len - scan.index);
                while (allowance != 0 and forms[scan.index].value != .list) : (allowance -= 1) scan.index += 1;
                if (scan.index == forms.len) {
                    try self.gatherElements(.{ .lowered = .{ .output = scan.output } }, forms.len);
                    break :result .pending;
                }
                if (forms[scan.index].value != .list) break :result .pending;
                const output = scan.output;
                self.state = .{ .write_lowered_span = .{
                    .output = output,
                    .index = scan.index,
                    .writer = .initUniform(
                        self.spans,
                        self.allocator,
                        forms[scan.index].value.list,
                        self.context.start,
                    ),
                } };
                break :result .pending;
            },
            .write_lowered_span => |*write| switch (try write.writer.advance(work)) {
                .pending => .pending,
                .complete => result: {
                    write.writer.deinit();
                    const output = write.output;
                    self.state = .{ .scan_lowered_spans = .{
                        .output = output,
                        .index = write.index + 1,
                    } };
                    break :result .pending;
                },
            },
            .gather_elements => |*gather| result: {
                for (0..work.chunk(gather.values.len - gather.index)) |_| {
                    const item = gather.source.next();
                    gather.values[gather.index] = item.value;
                    gather.spans[gather.index] = item.span;
                    gather.index += 1;
                }
                if (gather.index != gather.values.len) break :result .pending;
                const source = gather.source;
                const values = gather.values;
                const spans = gather.spans;
                self.state = .{ .materialize_list = .{
                    .source = source,
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
            .materialize_list => |*materialization| switch (try poll.advanceOne(&materialization.materializer)) {
                .pending => .pending,
                .complete => |item| result: {
                    const spans = materialization.spans;
                    materialization.materializer.deinit();
                    self.allocator.free(materialization.values);
                    materialization.source.retire(self.allocator);
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
            .list_spans => |*span_state| switch (try span_state.writer.advance(work)) {
                .pending => .pending,
                .complete => result: {
                    const item = span_state.result;
                    span_state.writer.deinit();
                    self.allocator.free(span_state.spans);
                    self.state = .complete;
                    break :result .{ .complete = .{ .value = item, .span = self.context.start } };
                },
            },
            .gather_pairs => |*gather| result: {
                for (0..work.chunk(gather.pairs.len - gather.index)) |_| {
                    const key = gather.from.next().?.value;
                    gather.pairs[gather.index] = .{ key, gather.from.next().?.value };
                    gather.index += 1;
                }
                if (gather.index != gather.pairs.len) break :result .pending;
                const materializer = try dict.Materializer.init(self.allocator, gather.pairs, true);
                const pairs = gather.pairs;
                self.state = .{ .materialize_dict = .{ .pairs = pairs, .materializer = materializer } };
                break :result .pending;
            },
            .materialize_dict => |*materialization| switch (try poll.advanceOne(&materialization.materializer)) {
                .pending => .pending,
                .duplicate_key => {
                    self.diag.set(self.context.start, "dictionary literal contains a duplicate key");
                    return error.Parse;
                },
                .complete => |item| result: {
                    materialization.materializer.deinit();
                    self.allocator.free(materialization.pairs);
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
    word_linker: value.WordLinker,
    state: State = .reading,
    retirement_phase: enum { state, contexts, storage, complete } = .state,

    fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        tokens: *const TokenList,
        spans: *reader.SpanTable,
        diag: *reader.Diag,
        provenance_namespace: heap.CodeProvenanceNamespace,
        word_linker: value.WordLinker,
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
            .word_linker = word_linker,
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
    fn appendOwned(self: *ParserCursor, form: locals.SpannedValue) error{OutOfMemory}!void {
        try self.values.appendOwned(form.value);
        const destination = if (self.contexts.topPtr()) |context| &context.body else &self.output.?;
        try destination.append(form);
    }
    fn beginScalar(self: *ParserCursor, token: Token) error{Parse}!void {
        std.debug.assert(self.state == .reading);
        self.state = .{ .scalar = switch (token.kind) {
            .atom => .{ .atom = .init(token, false, self.word_linker) },
            .quoted => .{ .atom = .init(token, true, self.word_linker) },
            .character => .{ .character = .init(token) },
            .string => .{ .string = .init(self.allocator, token, self.provenance_namespace) },
            .semicolon => {
                self.diag.set(token.span, "`;` is reserved");
                return error.Parse;
            },
            .bar => {
                self.diag.set(token.span, "`|` is legal only around a list's leading locals declaration");
                return error.Parse;
            },
            .open_paren, .open_square, .open_dict, .close_paren, .close_square, .close_dict => unreachable,
        } };
    }
    fn advanceScalar(self: *ParserCursor, work: *poll.WorkBudget) (error{ OutOfMemory, Parse })!ParseProgress {
        const scalar = switch (self.state) {
            .scalar => |*scalar| scalar,
            else => unreachable,
        };
        // The builder runs until its scalar is done or the budget is spent, a
        // unit a transition after the one this step was paid for.
        const progress: ScalarProgress = while (true) {
            const next: ScalarProgress = switch (scalar.*) {
                .atom => |*builder| try builder.advance(self.diag),
                .string => |*builder| try builder.advance(self.releases, self.diag, work),
                .character => |*builder| try builder.advance(self.diag),
            };
            if (next != .pending or !work.spend()) break next;
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
    fn handleLocals(self: *ParserCursor, token: Token) (error{ OutOfMemory, Parse })!bool {
        const context = self.contexts.topPtr().?;
        switch (context.locals) {
            .unchecked => {
                if (token.kind == .bar) {
                    context.locals = .{ .names = token.span };
                    return true;
                }
                context.locals = .body;
                return false;
            },
            .unavailable, .body, .body_with_locals => return false,
            .names => {},
        }
        if (token.kind == .bar) {
            if (context.names.count == 0) {
                self.diag.set(context.locals.names, "a locals declaration must contain at least one name");
                return error.Parse;
            }
            context.locals = .body_with_locals;
            return true;
        }
        if (token.kind != .atom) {
            self.diag.set(token.span, "local names must be unquoted, unqualified symbols");
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
            self.word_linker,
        ) };
        // SAFETY: CollectionBuilder owns every allocation formerly held by
        // `context`; the moved-from local is never observed again.
        context = undefined;
    }
    fn processToken(self: *ParserCursor, token: Token) (error{ OutOfMemory, Parse })!void {
        if (self.contexts.topPtr() != null and try self.handleLocals(token)) return;
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
            if (context.locals == .names) return .{ .incomplete = .{
                .message = "unclosed locals declaration; expected `|`",
                .span = context.locals.names,
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
    /// Runs transitions until the parse ends or the budget is spent, one unit
    /// each.
    fn advance(self: *ParserCursor, work: *poll.WorkBudget) (error{ OutOfMemory, Parse })!ParseProgress {
        while (work.spend()) {
            const progress = try self.step(work);
            if (progress != .pending) return progress;
        }
        return .pending;
    }

    /// One transition, already charged; bulk work inside it draws further
    /// units from `work`.
    fn step(self: *ParserCursor, work: *poll.WorkBudget) (error{ OutOfMemory, Parse })!ParseProgress {
        return switch (self.state) {
            .scalar => self.advanceScalar(work),
            // Like a scalar, a container runs until it is built or the budget
            // is spent.
            .collection => |*collection| switch (while (true) {
                const next = try collection.advance(work);
                if (next != .pending or !work.spend()) break next;
            }) {
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
    word_linker: value.WordLinker,
    tokens: TokenList,
    spans: reader.SpanTable,
    state: State,

    const Partial = union(enum) {
        none,
        name: struct { forms: heap.OwnedValueBuffer, top: []Span, name: []u8 },
        source: struct {
            forms: heap.OwnedValueBuffer,
            top: []Span,
            name: []u8,
            source: []u8,
        },

        fn retire(self: *Partial, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .none => {},
                .name => |*partial| {
                    allocator.free(partial.name);
                    allocator.free(partial.top);
                    partial.forms.deinit();
                },
                .source => |*partial| {
                    allocator.free(partial.source);
                    allocator.free(partial.name);
                    allocator.free(partial.top);
                    partial.forms.deinit();
                },
            }
        }
    };
    const ParserOwner = struct {
        allocator: std.mem.Allocator,
        cursor: *ParserCursor,

        fn init(
            allocator: std.mem.Allocator,
            releases: *heap.ReleaseDomain,
            tokens: *const TokenList,
            spans: *reader.SpanTable,
            diag: *reader.Diag,
            provenance_namespace: heap.CodeProvenanceNamespace,
            word_linker: value.WordLinker,
        ) error{OutOfMemory}!ParserOwner {
            const cursor = try allocator.create(ParserCursor);
            errdefer allocator.destroy(cursor);
            cursor.* = try ParserCursor.init(
                allocator,
                releases,
                tokens,
                spans,
                diag,
                provenance_namespace,
                word_linker,
            );
            return .{ .allocator = allocator, .cursor = cursor };
        }
        fn deinit(self: *ParserOwner) void {
            self.cursor.deinit();
            self.allocator.destroy(self.cursor);
        }
        fn retireCompleted(self: *ParserOwner) void {
            self.cursor.retireCompleted();
            self.allocator.destroy(self.cursor);
        }
        fn advanceRetirement(self: *ParserOwner) bool {
            if (!self.cursor.advanceRetirement()) return false;
            self.allocator.destroy(self.cursor);
            return true;
        }
    };
    /// The parsed program's owned copies, allocated together when the parse
    /// ends and filled in budget-sized chunks.
    const CompleteBuild = struct {
        parser: ParserOwner,
        forms: heap.OwnedValueBuffer,
        top: []Span,
        name: []u8,
        source: []u8,
        iterator: FormList.Iterator,
        form_index: usize = 0,
        name_index: usize = 0,
        source_index: usize = 0,
    };
    const State = union(enum) {
        tokenize: Tokenizer,
        parse: ParserOwner,
        build: CompleteBuild,
        source_consumed: struct {
            parser: ParserOwner,
            forms: heap.OwnedValueBuffer,
            top: []Span,
            name: []u8,
        },
        incomplete_tokens,
        incomplete_parser: ParserOwner,
        completed,
        retire_parser: struct { parser: ParserOwner, partial: Partial },
        retire_tokens: Partial,
        retire_spans: struct {
            partial: Partial,
            cursor: reader.SpanTable.RetireCursor,
        },
        retire_owned: Partial,
        retired,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
    ) ReadCursor {
        return initCode(allocator, releases, source_name, source, diag, .none, .unlinked);
    }

    pub fn initCode(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
        provenance_namespace: heap.CodeProvenanceNamespace,
        word_linker: value.WordLinker,
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
            .word_linker = word_linker,
            .tokens = tokens,
            .spans = .init(allocator),
            .state = .{ .tokenize = .init(source, null) },
        };
    }
    fn deinitHost(self: *ReadCursor) void {
        while (!self.advanceRetirement()) {}
    }
    fn beginRetirement(self: *ReadCursor) void {
        switch (self.state) {
            .tokenize, .incomplete_tokens, .completed => {
                self.state = .{ .retire_tokens = .none };
            },
            .parse, .incomplete_parser => |*parser| {
                const moved = parser.*;
                self.state = .{ .retire_parser = .{
                    .parser = moved,
                    .partial = .none,
                } };
            },
            .build => |*build| self.beginCompleteBuildRetirement(build),
            .source_consumed => |*consumed| {
                const parser = consumed.parser;
                const forms = consumed.forms.take();
                const top = consumed.top;
                const name = consumed.name;
                self.state = .{ .retire_parser = .{
                    .parser = parser,
                    .partial = .{ .name = .{
                        .forms = forms,
                        .top = top,
                        .name = name,
                    } },
                } };
            },
            .retire_parser, .retire_tokens, .retire_spans, .retire_owned, .retired => unreachable,
        }
    }
    fn beginCompleteBuildRetirement(self: *ReadCursor, build: *CompleteBuild) void {
        const parser = build.parser;
        const forms = build.forms.take();
        const top = build.top;
        const name = build.name;
        const source = build.source;
        self.state = .{ .retire_parser = .{
            .parser = parser,
            .partial = .{ .source = .{
                .forms = forms,
                .top = top,
                .name = name,
                .source = source,
            } },
        } };
    }
    pub fn advanceRetirement(self: *ReadCursor) bool {
        return switch (self.state) {
            .tokenize,
            .parse,
            .build,
            .source_consumed,
            .incomplete_tokens,
            .incomplete_parser,
            .completed,
            => result: {
                self.beginRetirement();
                break :result false;
            },
            .retire_parser => |*retirement| result: {
                if (!retirement.parser.advanceRetirement()) break :result false;
                const partial = retirement.partial;
                self.state = .{ .retire_tokens = partial };
                break :result false;
            },
            .retire_tokens => |*partial| result: {
                self.tokens.retire(self.releases);
                const moved = partial.*;
                self.state = .{ .retire_spans = .{
                    .partial = moved,
                    .cursor = .init(&self.spans),
                } };
                break :result false;
            },
            .retire_spans => |*retirement| switch (retirement.cursor.advance(self.releases)) {
                .pending => false,
                .complete => result: {
                    const partial = retirement.partial;
                    self.state = .{ .retire_owned = partial };
                    break :result false;
                },
            },
            .retire_owned => |*partial| result: {
                partial.retire(self.allocator);
                self.state = .retired;
                break :result true;
            },
            .retired => unreachable,
        };
    }
    /// Tokenizing, parsing, and copying the result draw from `work`, one unit
    /// per transition, form, or byte.
    pub fn advance(self: *ReadCursor, work: *poll.WorkBudget) (error{ OutOfMemory, Parse })!ReadProgress {
        return switch (self.state) {
            .tokenize => |*tokenizer| switch (try tokenizer: {
                tokenizer.tokens = &self.tokens;
                break :tokenizer tokenizer.advance(self.diag, work);
            }) {
                .pending => .pending,
                .incomplete => |value_incomplete| result: {
                    self.state = .incomplete_tokens;
                    break :result .{ .complete = .{ .incomplete = value_incomplete } };
                },
                .complete => result: {
                    const parser = try ParserOwner.init(
                        self.allocator,
                        self.releases,
                        &self.tokens,
                        &self.spans,
                        self.diag,
                        self.provenance_namespace,
                        self.word_linker,
                    );
                    self.state = .{ .parse = parser };
                    break :result .pending;
                },
            },
            .parse => |*parser| switch (try parser.cursor.advance(work)) {
                .pending => .pending,
                .incomplete => |value_incomplete| result: {
                    const moved = parser.*;
                    self.state = .{ .incomplete_parser = moved };
                    break :result .{ .complete = .{ .incomplete = value_incomplete } };
                },
                .complete => result: {
                    // Every owned copy is allocated in this one transition, so
                    // a failure leaves the cursor parsed and nothing to free.
                    const output = &parser.cursor.output.?;
                    var forms = try heap.OwnedValueBuffer.init(self.releases, output.count);
                    errdefer forms.deinit();
                    const top = try self.allocator.alloc(Span, output.count);
                    errdefer self.allocator.free(top);
                    const name = try self.allocator.alloc(u8, self.source_name.len);
                    errdefer self.allocator.free(name);
                    const source = try self.allocator.alloc(u8, self.source.len);
                    const moved = parser.*;
                    self.state = .{ .build = .{
                        .parser = moved,
                        .forms = forms,
                        .top = top,
                        .name = name,
                        .source = source,
                        .iterator = output.iterator(),
                    } };
                    break :result .pending;
                },
            },
            .build => |*build| result: {
                // Forms one unit each, then the name and source bytes a unit a
                // byte, as much of each as the budget pays for.
                while (build.form_index != build.top.len) {
                    if (!work.spend()) break :result .pending;
                    const form = build.iterator.next().?;
                    build.forms.appendBorrowed(form.value);
                    build.top[build.form_index] = form.span;
                    build.form_index += 1;
                }
                if (!copyBytes(build.name, self.source_name, &build.name_index, work)) break :result .pending;
                if (!copyBytes(build.source, self.source, &build.source_index, work)) break :result .pending;
                const parser = build.parser;
                const forms = build.forms.take();
                const top = build.top;
                const name = build.name;
                const source_bytes = build.source;
                self.state = .{ .source_consumed = .{
                    .parser = parser,
                    .forms = forms,
                    .top = top,
                    .name = name,
                } };
                const source_slice = try reader.SourceSlice.initOwned(self.allocator, source_bytes);
                const consumed = &self.state.source_consumed;
                var output = consumed.parser.cursor.output.?;
                consumed.parser.cursor.output = null;
                output.retire(self.releases);
                consumed.parser.retireCompleted();
                self.tokens.retire(self.releases);
                self.spans.top = consumed.top;
                const parsed: reader.Parsed = .{
                    .allocator = self.allocator,
                    .forms = consumed.forms.take(),
                    .releases = self.releases,
                    .spans = self.spans,
                    .source_name = consumed.name,
                    .source = source_slice,
                };
                self.spans = .init(self.allocator);
                self.state = .completed;
                break :result .{ .complete = .{ .complete = parsed } };
            },
            .source_consumed,
            .incomplete_tokens,
            .incomplete_parser,
            .completed,
            .retire_parser,
            .retire_tokens,
            .retire_spans,
            .retire_owned,
            .retired,
            => unreachable,
        };
    }
};

/// Copies as much of the rest of `origin` into `destination` as `work` pays
/// for, a unit a byte; true once every byte is copied.
fn copyBytes(destination: []u8, origin: []const u8, index: *usize, work: *poll.WorkBudget) bool {
    const granted = work.take(destination.len - index.*);
    @memcpy(destination[index.*..][0..granted], origin[index.*..][0..granted]);
    index.* += granted;
    return index.* == destination.len;
}

pub fn read(
    host: *const heap.HostCleanup,
    source_name: []const u8,
    source: []const u8,
    diag: *reader.Diag,
) (error{ OutOfMemory, Parse })!reader.HostReadResult {
    return readCode(host, source_name, source, diag, .none, .unlinked);
}

pub fn readCode(
    host: *const heap.HostCleanup,
    source_name: []const u8,
    source: []const u8,
    diag: *reader.Diag,
    provenance_namespace: heap.CodeProvenanceNamespace,
    word_linker: value.WordLinker,
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
        word_linker,
    );
    defer cursor.deinitHost();
    const result = while (true) switch (try poll.advanceOne(&cursor)) {
        .pending => {},
        .complete => |read_result| break read_result,
    };
    return switch (result) {
        .incomplete => |incomplete| .{ .incomplete = incomplete },
        .complete => |parsed_value| .{ .complete = .{ .parsed = parsed_value, .host = host } },
    };
}
