//! GRAMMAR.md reader and the code-plane provenance handoff to M3.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const lexer = @import("lexer.zig");
const binder = @import("binder.zig");
const poll = @import("poll.zig");
const storage = @import("kernel_storage.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const Span = lexer.Span;
pub const Diag = lexer.Diag;

pub const Error = error{ OutOfMemory, Parse };
const InternalError = Error || error{ Incomplete, Ecl };
const max_nesting_depth = 10_000;
const FormList = poll.ChunkList(binder.SpannedValue);
const NameList = poll.ChunkList(binder.Name);
const CodepointList = poll.ChunkList(u32);
const SpanList = poll.ChunkList(Span);

pub const Incomplete = struct {
    message: []const u8,
    span: Span,
};

/// Provenance is keyed by the identity of reader-built code lists. Runtime-
/// built or CoW-copied lists are naturally absent (decision 23).
pub const SpanTable = struct {
    const bucket_count = 4096;
    pub const Entry = struct {
        header: *Header,
        spans: []Span,
        next_bucket: ?*Entry = null,
    };
    pub const EntryList = poll.ChunkList(Entry);
    entries: EntryList,
    buckets: []?*Entry = &.{},
    top: []Span = &.{},

    pub fn init(allocator: std.mem.Allocator) SpanTable {
        return .{ .entries = .init(allocator) };
    }
    pub fn forList(
        self: *const SpanTable,
        header: *Header,
        work: poll.WorkContext,
    ) poll.Error!?[]const Span {
        if (self.buckets.len == 0) return null;
        var entry = self.buckets[bucket(header)];
        while (entry) |current| : (entry = current.next_bucket) {
            try work.step();
            if (current.header == header) return current.spans;
        }
        return null;
    }

    pub fn deinit(self: *SpanTable, allocator: std.mem.Allocator) void {
        var entries = self.entries.iterator();
        while (entries.next()) |entry| if (entry.spans.len > 0) allocator.free(entry.spans);
        self.entries.deinit();
        if (self.buckets.len > 0) allocator.free(self.buckets);
        if (self.top.len > 0) allocator.free(self.top);
        self.* = .init(allocator);
    }

    fn put(
        self: *SpanTable,
        allocator: std.mem.Allocator,
        header: *Header,
        source: []const Span,
        work: poll.WorkContext,
    ) (error{OutOfMemory} || error{Ecl})!void {
        const owned: []Span = if (source.len == 0) &.{} else try allocator.alloc(Span, source.len);
        errdefer if (owned.len > 0) allocator.free(owned);
        var indices = work.indices(0, source.len);
        while (try indices.next()) |index| owned[index] = source[index];
        try self.insert(header, owned, work);
    }

    fn putUniform(
        self: *SpanTable,
        allocator: std.mem.Allocator,
        header: *Header,
        span: Span,
        work: poll.WorkContext,
    ) (error{OutOfMemory} || error{Ecl})!void {
        const count: usize = @intCast(header.length());
        const owned: []Span = if (count == 0) &.{} else try allocator.alloc(Span, count);
        errdefer if (owned.len > 0) allocator.free(owned);
        var indices = work.indices(0, owned.len);
        while (try indices.next()) |index| owned[index] = span;
        try self.insert(header, owned, work);
    }

    pub fn putOwned(
        self: *SpanTable,
        header: *Header,
        owned: []Span,
        work: poll.WorkContext,
    ) poll.Error!void {
        try self.insert(header, owned, work);
    }
    fn insert(
        self: *SpanTable,
        header: *Header,
        owned: []Span,
        work: poll.WorkContext,
    ) poll.Error!void {
        if (self.buckets.len == 0) {
            self.buckets = try self.entries.allocator.alloc(?*Entry, bucket_count);
            errdefer {
                self.entries.allocator.free(self.buckets);
                self.buckets = &.{};
            }
            var indices = work.indices(0, self.buckets.len);
            while (try indices.next()) |index| self.buckets[index] = null;
        }
        const index = bucket(header);
        const entry = try self.entries.appendPtr(.{
            .header = header,
            .spans = owned,
            .next_bucket = self.buckets[index],
        });
        self.buckets[index] = entry;
    }
    fn bucket(header: *const Header) usize {
        const address = @intFromPtr(header) >> 4;
        return address & (bucket_count - 1);
    }
};
/// M3 owns this value while executing its code so list identity remains valid
/// for lazy trace construction.
pub const Parsed = struct {
    allocator: std.mem.Allocator,
    forms: []Value,
    spans: SpanTable,
    source_name: []u8,

    pub fn deinit(self: *Parsed) void {
        self.spans.deinit(self.allocator);
        for (self.forms) |form| heap.releaseValue(self.allocator, form);
        self.allocator.free(self.forms);
        self.allocator.free(self.source_name);
        self.* = undefined;
    }
};

pub const ReadResult = union(enum) {
    complete: Parsed,
    incomplete: Incomplete,
};

/// Reads one script/REPL unit. On `error.Parse`, `diag` contains the stable
/// allocation-free diagnostic. Incomplete input is a successful union arm.
pub fn read(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    diag: *Diag,
) Error!ReadResult {
    return readPolling(allocator, source_name, source, diag, .unlimited()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Parse => error.Parse,
        error.Ecl => unreachable,
    };
}

pub fn readPolling(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    diag: *Diag,
    work: poll.WorkContext,
) (Error || error{Ecl})!ReadResult {
    diag.* = .{};
    if (!try validUtf8Polling(source, work)) {
        diag.set(.{}, "source is not valid UTF-8");
        return error.Parse;
    }

    var parser = Parser.init(allocator, source, diag, work);
    defer parser.spans.deinit(allocator);
    var forms = FormList.init(allocator);
    defer forms.deinit();
    var forms_owned = true;
    defer if (forms_owned) releaseFormList(allocator, &forms);

    parser.program(&forms) catch |err| switch (err) {
        error.Incomplete => return .{ .incomplete = parser.incomplete.? },
        error.Parse => return error.Parse,
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
    };

    const values = try allocator.alloc(Value, forms.count);
    errdefer allocator.free(values);
    const top = try allocator.alloc(Span, forms.count);
    errdefer allocator.free(top);
    const owned_source_name = try allocator.dupe(u8, source_name);
    errdefer allocator.free(owned_source_name);
    var iterator = forms.iterator();
    var index: usize = 0;
    while (iterator.next()) |form| : (index += 1) {
        try work.step();
        values[index] = form.value;
        top[index] = form.span;
    }

    forms_owned = false;
    parser.spans.top = top;
    const spans = parser.spans;
    parser.spans = .init(allocator);
    return .{ .complete = .{
        .allocator = allocator,
        .forms = values,
        .spans = spans,
        .source_name = owned_source_name,
    } };
}

const ContainerKind = enum {
    paren,
    square,
    dict,

    fn open(self: ContainerKind) u21 {
        return switch (self) {
            .paren => '(',
            .square => '[',
            .dict => '{',
        };
    }

    fn close(self: ContainerKind) u21 {
        return switch (self) {
            .paren => ')',
            .square => ']',
            .dict => '}',
        };
    }
};

const Context = struct {
    kind: ContainerKind,
    start: Span,
    body: FormList,
    names: NameList,
    has_binder: bool = false,

    fn init(allocator: std.mem.Allocator, kind: ContainerKind, start: Span) Context {
        return .{
            .kind = kind,
            .start = start,
            .body = FormList.init(allocator),
            .names = NameList.init(allocator),
        };
    }

    fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        releaseFormList(allocator, &self.body);
        self.body.deinit();
        self.names.deinit();
        self.* = undefined;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    cursor: lexer.Cursor,
    diag: *Diag,
    spans: SpanTable,
    incomplete: ?Incomplete = null,
    work: poll.WorkContext,

    fn init(allocator: std.mem.Allocator, source: []const u8, diag: *Diag, work: poll.WorkContext) Parser {
        return .{ .allocator = allocator, .cursor = .init(source), .diag = diag, .spans = .init(allocator), .work = work };
    }

    fn program(self: *Parser, output: *FormList) InternalError!void {
        var contexts: std.ArrayList(Context) = .empty;
        defer {
            for (contexts.items) |*context| context.deinit(self.allocator);
            contexts.deinit(self.allocator);
        }
        while (true) {
            try self.cursor.skipIgnoredPolling(self.work);
            const next = self.cursor.peek() orelse {
                if (contexts.items.len == 0) return;
                const unfinished = contexts.items[contexts.items.len - 1];
                return self.more(switch (unfinished.kind) {
                    .paren => "unclosed `(`; expected `)`",
                    .square => "unclosed `[`; expected `]`",
                    .dict => "unclosed `{`; expected `}`",
                }, unfinished.start);
            };
            switch (next) {
                '(', '[', '{' => try self.pushContext(&contexts),
                ')', ']', '}' => try self.closeContext(&contexts, output),
                else => {
                    const destination = if (contexts.items.len == 0)
                        output
                    else
                        &contexts.items[contexts.items.len - 1].body;
                    try self.scalarForm(destination);
                },
            }
        }
    }

    fn scalarForm(
        self: *Parser,
        output: *FormList,
    ) InternalError!void {
        const next = self.cursor.peek().?;
        switch (next) {
            '"' => try self.parseString(output),
            '\'' => try self.parseQuotedSymbol(output),
            '\\' => try self.parseCharacter(output),
            ';' => return self.fail(self.cursor.span(), "`;` is reserved"),
            '|' => return self.fail(
                self.cursor.span(),
                "`|` is legal only around a list's leading binder",
            ),
            '(', ')', '[', ']', '{', '}' => unreachable,
            else => try self.parseAtom(output),
        }
    }

    fn pushContext(
        self: *Parser,
        contexts: *std.ArrayList(Context),
    ) InternalError!void {
        if (contexts.items.len >= max_nesting_depth) return self.fail(
            self.cursor.span(),
            "form nesting too deep",
        );
        const start = self.cursor.span();
        const open = (try self.cursor.bumpPolling(self.work)).?;
        var context = Context.init(
            self.allocator,
            switch (open) {
                '(' => .paren,
                '[' => .square,
                '{' => .dict,
                else => unreachable,
            },
            start,
        );
        errdefer context.deinit(self.allocator);
        if (context.kind != .dict) {
            try self.cursor.skipIgnoredPolling(self.work);
            if (self.cursor.peek() == '|') {
                context.has_binder = true;
                try self.parseBinderNames(&context.names);
            }
        }
        try contexts.append(self.allocator, context);
    }

    fn closeContext(
        self: *Parser,
        contexts: *std.ArrayList(Context),
        output: *FormList,
    ) InternalError!void {
        const actual = self.cursor.peek().?;
        if (contexts.items.len == 0) return self.failFmt(
            self.cursor.span(),
            "unmatched closing delimiter `{u}`",
            .{actual},
        );
        const active = contexts.items[contexts.items.len - 1];
        if (actual != active.kind.close()) {
            if (actual == '}' and active.kind != .dict) return self.fail(
                self.cursor.span(),
                "unmatched closing delimiter `}`",
            );
            return self.failFmt(
                self.cursor.span(),
                "mismatched delimiter: `{u}` must close with `{u}`, not `{u}`",
                .{ active.kind.open(), active.kind.close(), actual },
            );
        }
        _ = try self.cursor.bumpPolling(self.work);
        var context = contexts.pop().?;
        defer context.deinit(self.allocator);
        const destination = if (contexts.items.len == 0)
            output
        else
            &contexts.items[contexts.items.len - 1].body;
        switch (context.kind) {
            .paren, .square => try self.finishList(&context, destination),
            .dict => try self.finishDict(&context, destination),
        }
    }

    fn finishList(
        self: *Parser,
        context: *Context,
        output: *FormList,
    ) InternalError!void {
        var lowered: ?[]binder.SpannedValue = null;
        defer if (lowered) |forms| {
            releaseForms(self.allocator, forms);
            self.allocator.free(forms);
        };
        const body = try context.body.toOwnedSlice(self.work);
        defer self.allocator.free(body);
        const elements = if (context.has_binder) blk: {
            const names = try context.names.toOwnedSlice(self.work);
            defer self.allocator.free(names);
            const result = try binder.lowerPolling(
                self.allocator,
                names,
                body,
                context.start,
                self.diag,
                self.work,
            );
            lowered = result;
            for (result) |form_item| switch (form_item.value) {
                .list => |header| try self.spans.putUniform(
                    self.allocator,
                    header,
                    context.start,
                    self.work,
                ),
                .int, .float, .char, .symbol, .word, .dict => {},
            };
            break :blk result;
        } else body;

        const collection = try self.buildList(elements, true);
        try appendOwned(self.allocator, output, .{
            .value = collection,
            .span = context.start,
        });
    }

    fn parseBinderNames(self: *Parser, names: *NameList) InternalError!void {
        const start = self.cursor.span();
        _ = try self.cursor.bumpPolling(self.work);
        while (true) {
            try self.cursor.skipIgnoredPolling(self.work);
            const next = self.cursor.peek() orelse
                return self.more("unclosed binder; expected `|`", start);
            if (next == '|') {
                _ = try self.cursor.bumpPolling(self.work);
                if (names.count == 0) return self.fail(
                    start,
                    "a binder must contain at least one name",
                );
                return;
            }
            if (switch (next) {
                '(', ')', '[', ']', '{', '}', '"', '\'', '\\', ';' => true,
                else => false,
            }) return self.fail(
                self.cursor.span(),
                "binder names must be unquoted, unqualified symbols",
            );
            const name_span = self.cursor.span();
            const token = try self.cursor.takeTokenPolling(self.work);
            if (token.len == 0) return self.fail(
                name_span,
                "binder names must be unquoted, unqualified symbols",
            );
            try names.append(.{ .bytes = token, .span = name_span });
        }
    }

    fn finishDict(
        self: *Parser,
        context: *Context,
        output: *FormList,
    ) InternalError!void {
        const body = try context.body.toOwnedSlice(self.work);
        defer self.allocator.free(body);
        if (body.len % 2 != 0) return self.fail(
            body[body.len - 1].span,
            "dictionary literal key is missing its value",
        );
        const pairs = try self.allocator.alloc(dict.Pair, body.len / 2);
        defer self.allocator.free(pairs);
        for (pairs, 0..) |*pair, index| {
            try self.work.step();
            pair.* = .{
                body[index * 2].value,
                body[index * 2 + 1].value,
            };
        }
        const dictionary = storage.fromPairs(self.allocator, pairs, self.constructorPoller()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return error.Ecl,
            error.DuplicateKey => return self.fail(
                context.start,
                "dictionary literal contains a duplicate key",
            ),
        };
        try appendOwned(self.allocator, output, .{ .value = dictionary, .span = context.start });
    }

    fn parseString(self: *Parser, output: *FormList) InternalError!void {
        const start = self.cursor.span();
        _ = try self.cursor.bumpPolling(self.work);
        var codepoints = CodepointList.init(self.allocator);
        defer codepoints.deinit();
        var char_spans = SpanList.init(self.allocator);
        defer char_spans.deinit();
        while (true) {
            const char_span = self.cursor.span();
            const next = self.cursor.peek() orelse
                return self.more("unclosed string; expected `\"`", start);
            if (next == '"') {
                _ = try self.cursor.bumpPolling(self.work);
                break;
            }
            const codepoint: u32 = if (next == '\\') blk: {
                _ = try self.cursor.bumpPolling(self.work);
                break :blk try self.stringEscape(start, char_span);
            } else @intCast((try self.cursor.bumpPolling(self.work)).?);
            try codepoints.append(codepoint);
            try char_spans.append(char_span);
        }
        const contiguous_codepoints = try codepoints.toOwnedSlice(self.work);
        defer self.allocator.free(contiguous_codepoints);
        const contiguous_spans = try char_spans.toOwnedSlice(self.work);
        defer self.allocator.free(contiguous_spans);
        const string = try storage.fromCodepoints(self.allocator, contiguous_codepoints, self.constructorPoller());
        self.spans.put(self.allocator, string.list, contiguous_spans, self.work) catch |err| {
            heap.releaseValue(self.allocator, string);
            return err;
        };
        try appendOwned(self.allocator, output, .{ .value = string, .span = start });
    }

    fn stringEscape(self: *Parser, string_start: Span, escape_span: Span) InternalError!u32 {
        const next = (try self.cursor.bumpPolling(self.work)) orelse
            return self.more("unclosed string escape", string_start);
        return switch (next) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            't' => '\t',
            'u' => if (self.cursor.peek() == '{')
                self.unicodeEscape(string_start, escape_span, "string")
            else
                self.unknownEscape(next, escape_span),
            else => self.unknownEscape(next, escape_span),
        };
    }

    fn unknownEscape(self: *Parser, codepoint: u21, span: Span) InternalError!u32 {
        return self.failFmt(span, "unknown string escape `\\{u}`", .{codepoint});
    }

    fn parseQuotedSymbol(
        self: *Parser,
        output: *FormList,
    ) InternalError!void {
        const start = self.cursor.span();
        _ = try self.cursor.bumpPolling(self.work);
        const token = try self.cursor.takeTokenPolling(self.work);
        if (!try lexer.validSymbolPolling(token, self.work)) {
            if (token.len == 0) return self.fail(start, "quoted symbol is missing its name");
            return self.failFmt(start, "invalid quoted symbol `'{s}`", .{token});
        }
        const id = try self.internToken(token);
        try output.append(.{ .value = .{ .symbol = id }, .span = start });
    }

    fn parseCharacter(
        self: *Parser,
        output: *FormList,
    ) InternalError!void {
        const start = self.cursor.span();
        _ = try self.cursor.bumpPolling(self.work);
        const next = self.cursor.peek() orelse
            return self.fail(start, "character literal is missing its character");
        const codepoint: u32 = if (next == 'u' and (try self.cursor.peekNPolling(1, self.work)) == '{') blk: {
            _ = try self.cursor.bumpPolling(self.work);
            break :blk try self.unicodeEscape(
                start,
                start,
                "Unicode character literal",
            );
        } else if (lexer.isTokenBoundary(next) or
            next == ';' or next == '|' or next == '\'' or next == '\\')
            @intCast((try self.cursor.bumpPolling(self.work)).?)
        else blk: {
            const token = try self.cursor.takeTokenPolling(self.work);
            if (std.mem.eql(u8, token, "space")) break :blk ' ';
            if (std.mem.eql(u8, token, "tab")) break :blk '\t';
            if (std.mem.eql(u8, token, "newline")) break :blk '\n';
            break :blk try self.singleCodepoint(token, start);
        };
        try output.append(.{ .value = .{ .char = codepoint }, .span = start });
    }

    fn singleCodepoint(self: *Parser, token: []const u8, span: Span) InternalError!u32 {
        if (token.len == 0) return self.fail(span, "character literal is missing its character");
        const length = std.unicode.utf8ByteSequenceLength(token[0]) catch
            @panic("reader token came from validated UTF-8");
        if (length != token.len) return self.failFmt(
            span,
            "unknown character name `\\{s}`",
            .{token},
        );
        return std.unicode.utf8Decode(token) catch
            @panic("reader token came from validated UTF-8");
    }

    fn unicodeEscape(
        self: *Parser,
        incomplete_span: Span,
        error_span: Span,
        context: []const u8,
    ) InternalError!u32 {
        std.debug.assert(self.cursor.peek() == '{');
        _ = try self.cursor.bumpPolling(self.work);
        const digits_start = self.cursor.byteIndex();
        while (true) {
            const next = self.cursor.peek() orelse return self.more(
                if (std.mem.eql(u8, context, "string"))
                    "unclosed Unicode escape; expected `}`"
                else
                    "unclosed Unicode character literal; expected `}`",
                incomplete_span,
            );
            if (next == '}') break;
            if (next > 0x7f or !std.ascii.isHex(@intCast(next))) return self.failFmt(
                error_span,
                "invalid character `{u}` in {s}",
                .{ next, context },
            );
            _ = try self.cursor.bumpPolling(self.work);
        }
        const digits_end = self.cursor.byteIndex();
        _ = try self.cursor.bumpPolling(self.work);
        const digits = self.cursor.source[digits_start..digits_end];
        if (digits.len == 0 or digits.len > 6) return self.fail(
            error_span,
            "a Unicode escape needs one to six hexadecimal digits",
        );
        const codepoint = std.fmt.parseInt(u32, digits, 16) catch return self.fail(
            error_span,
            "a Unicode escape contains a non-hexadecimal digit",
        );
        if (!isScalar(codepoint)) return self.failFmt(
            error_span,
            "U+{X:0>4} is not a Unicode scalar value",
            .{codepoint},
        );
        return codepoint;
    }

    fn parseAtom(self: *Parser, output: *FormList) InternalError!void {
        const start = self.cursor.span();
        const token = try self.cursor.takeTokenPolling(self.work);
        if (token.len == 0) return self.fail(start, "expected a token");
        const item: Value = switch (try lexer.classifyPolling(token, self.work)) {
            .int => |number| .{ .int = number },
            .float => |number| .{ .float = number },
            .out_of_range => |kind| return switch (kind) {
                .integer => self.failFmt(
                    start,
                    "integer literal `{s}` is outside int64",
                    .{token},
                ),
                .float => self.failFmt(
                    start,
                    "float literal `{s}` is outside float64",
                    .{token},
                ),
            },
            .word => blk: {
                if (!try lexer.validSymbolPolling(token, self.work)) return self.failFmt(
                    start,
                    "invalid word `{s}`",
                    .{token},
                );
                break :blk .{ .word = try self.internToken(token) };
            },
        };
        try output.append(.{ .value = item, .span = start });
    }

    fn buildList(
        self: *Parser,
        forms: []const binder.SpannedValue,
        specialize: bool,
    ) (error{OutOfMemory} || error{Ecl})!Value {
        const values = try self.allocator.alloc(Value, forms.len);
        defer self.allocator.free(values);
        const element_spans = try self.allocator.alloc(Span, forms.len);
        defer self.allocator.free(element_spans);
        for (forms, 0..) |form_item, index| {
            try self.work.step();
            values[index] = form_item.value;
            element_spans[index] = form_item.span;
        }
        const collection = if (specialize)
            try storage.fromValues(self.allocator, values, self.constructorPoller())
        else
            try storage.fromValuesGeneric(self.allocator, values, self.constructorPoller());
        errdefer heap.releaseValue(self.allocator, collection);
        try self.spans.put(self.allocator, collection.list, element_spans, self.work);
        return collection;
    }

    fn internToken(self: *Parser, token: []const u8) poll.Error!u32 {
        return intern.internPolling(token, self.work.asPoller());
    }

    fn constructorPoller(self: *Parser) poll.Poller {
        return self.work.asPoller();
    }

    fn fail(self: *Parser, span: Span, message: []const u8) error{Parse} {
        self.diag.set(span, message);
        return error.Parse;
    }

    fn failFmt(
        self: *Parser,
        span: Span,
        comptime format: []const u8,
        args: anytype,
    ) error{Parse} {
        self.diag.setFmt(span, format, args);
        return error.Parse;
    }

    fn more(self: *Parser, message: []const u8, span: Span) error{Incomplete} {
        self.incomplete = .{ .message = message, .span = span };
        return error.Incomplete;
    }
};

fn validUtf8Polling(source: []const u8, work: poll.WorkContext) poll.Error!bool {
    var index: usize = 0;
    while (index < source.len) {
        try work.step();
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return false;
        if (length > source.len - index) return false;
        _ = std.unicode.utf8Decode(source[index..][0..length]) catch return false;
        index += length;
    }
    return true;
}

fn appendOwned(
    allocator: std.mem.Allocator,
    output: *FormList,
    form: binder.SpannedValue,
) error{OutOfMemory}!void {
    output.append(form) catch |err| {
        heap.releaseValue(allocator, form.value);
        return err;
    };
}

fn releaseForms(allocator: std.mem.Allocator, forms: []const binder.SpannedValue) void {
    for (forms) |form| heap.releaseValue(allocator, form.value);
}

fn releaseFormList(allocator: std.mem.Allocator, forms: *const FormList) void {
    var iterator = forms.iterator();
    while (iterator.next()) |form| heap.releaseValue(allocator, form.value);
}

fn isScalar(codepoint: u32) bool {
    return codepoint <= 0x10ffff and !(codepoint >= 0xd800 and codepoint <= 0xdfff);
}

fn parsedForTest(source: []const u8) !Parsed {
    var diag: Diag = .{};
    return switch (try read(std.testing.allocator, "test", source, &diag)) {
        .complete => |parsed| parsed,
        .incomplete => error.TestUnexpectedResult,
    };
}

test "grammar form fixtures" {
    const printer = @import("print.zig");
    var parsed = try parsedForTest("1, -2 0x10 3.5 2e3 # hi\n [\\a 'x \"ok\"]");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 6), parsed.forms.len);
    const expected = [_][]const u8{ "1", "-2", "16", "3.5", "2000.0", "(\\a 'x \"ok\")" };
    for (parsed.forms, expected) |form, text| {
        const rendered = try printer.toOwnedString(std.testing.allocator, form);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(text, rendered);
    }

    var unicode = try parsedForTest("\\u{1f642} \"\\u{03bb}\"");
    defer unicode.deinit();
    try std.testing.expectEqual(@as(u32, 0x1f642), unicode.forms[0].char);
    try std.testing.expectEqual(@as(u32, 0x03bb), list.atUnchecked(unicode.forms[1], 0).char);
}

test "dict literals construct one inert value" {
    const printer = @import("print.zig");
    var parsed = try parsedForTest("{'answer (40 2 +) plus +}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.forms.len);
    const rendered = try printer.toOwnedString(std.testing.allocator, parsed.forms[0]);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("{'answer (40 2 +) plus +}", rendered);
    try std.testing.expectEqual(value.Tag.word, dict.valueAt(parsed.forms[0].dict, 1).tag());

    var diag: Diag = .{};
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", "{foo bar baz}", &diag),
    );
    try std.testing.expectEqualStrings("dictionary literal key is missing its value", diag.text());
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", "{1 one 1.0 two}", &diag),
    );
    try std.testing.expectEqualStrings("dictionary literal contains a duplicate key", diag.text());
}

test "incomplete vs error split" {
    var diag: Diag = .{};
    const result = try read(std.testing.allocator, "<repl>", "1 (2", &diag);
    try std.testing.expect(result == .incomplete);
    try std.testing.expectEqual(Span{ .line = 1, .col = 3 }, result.incomplete.span);
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", "1 (2]", &diag),
    );
    try std.testing.expectEqual(Span{ .line = 1, .col = 5 }, diag.span);
}

test "span table covers reader-built lists" {
    var parsed = try parsedForTest("(1 [2 3])");
    defer parsed.deinit();
    const outer = parsed.forms[0];
    try std.testing.expectEqual(@as(usize, 2), (try parsed.spans.forList(outer.list, .unlimited())).?.len);
    const inner = list.atUnchecked(outer, 1);
    try std.testing.expectEqual(@as(usize, 2), (try parsed.spans.forList(inner.list, .unlimited())).?.len);
    const hand_built = try list.fromValues(std.testing.allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(std.testing.allocator, hand_built);
    try std.testing.expect(try parsed.spans.forList(hand_built.list, .unlimited()) == null);
}

test "all-char quotation is the string value" {
    var parsed = try parsedForTest("[\\a \\b]");
    defer parsed.deinit();
    try std.testing.expectEqual(value.HeapKind.leaf_char1, parsed.forms[0].list.kind());
    try std.testing.expectEqual(@as(usize, 2), (try parsed.spans.forList(parsed.forms[0].list, .unlimited())).?.len);
}

test "whole-token numbers symbols and reserved characters follow the grammar" {
    var parsed = try parsedForTest("2dup 1+ - -3 +inf -inf 'stats.mean stats.mean");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 8), parsed.forms.len);
    try std.testing.expectEqualStrings("2dup", intern.get(parsed.forms[0].word));
    try std.testing.expectEqualStrings("1+", intern.get(parsed.forms[1].word));
    try std.testing.expectEqualStrings("-", intern.get(parsed.forms[2].word));
    try std.testing.expectEqual(@as(i64, -3), parsed.forms[3].int);
    try std.testing.expect(std.math.isPositiveInf(parsed.forms[4].float));
    try std.testing.expect(std.math.isNegativeInf(parsed.forms[5].float));
    try std.testing.expectEqualStrings("stats.mean", intern.get(parsed.forms[6].symbol));
    try std.testing.expectEqualStrings("stats.mean", intern.get(parsed.forms[7].word));

    var diag: Diag = .{};
    const invalid = [_][]const u8{
        ".5",    "5.",    ".name", "name.",  "name..part", "'",
        "'a..b", "don't", "a\\b",  "'don't", ";",          "|",
    };
    for (invalid) |source| try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", source, &diag),
    );
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", "1e9999", &diag),
    );
}

test "string and character escapes are re-readable" {
    const printer = @import("print.zig");
    var parsed = try parsedForTest(
        "\\space \\tab \\newline \\u{1f642} \\λ \"a\\\\\\\"\\n\\t\\u{3bb}\"",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, ' '), parsed.forms[0].char);
    try std.testing.expectEqual(@as(u32, '\t'), parsed.forms[1].char);
    try std.testing.expectEqual(@as(u32, '\n'), parsed.forms[2].char);
    try std.testing.expectEqual(@as(u32, 0x1f642), parsed.forms[3].char);
    try std.testing.expectEqual(@as(u32, 0x03bb), parsed.forms[4].char);
    const rendered = try printer.toOwnedString(std.testing.allocator, parsed.forms[5]);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("\"a\\\\\\\"\\n\\tλ\"", rendered);
}

test "binder validation and nesting diagnostics are surfaced by read" {
    var diag: Diag = .{};
    const invalid = [_][]const u8{
        "(||)",
        "(|x x| x)",
        "(|module.x| module.x)",
        "(|1| 1)",
        "(|x| (x))",
    };
    for (invalid) |source| try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", source, &diag),
    );

    var inert_dict = try parsedForTest("(|x| {key (x)})");
    defer inert_dict.deinit();

    var parsed = try parsedForTest("(|lo hi| hi lo)");
    defer parsed.deinit();
    const quotation = parsed.forms[0];
    try std.testing.expectEqual(@as(i64, 1), list.atUnchecked(quotation, 4).int);
    try std.testing.expectEqual(@as(i64, 0), list.atUnchecked(quotation, 8).int);
}

test "every open form reports incomplete while malformed forms fail" {
    var diag: Diag = .{};
    const incomplete = [_][]const u8{ "(", "[1", "{'x 1", "\"open", "(|x", "\"\\u{12" };
    for (incomplete) |source| try std.testing.expect(
        (try read(std.testing.allocator, "<repl>", source, &diag)) == .incomplete,
    );
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", "[1 2)", &diag),
    );
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", "\\u{d800}", &diag),
    );
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "test", &.{ 0xff, 0xfe }, &diag),
    );
}

test "nesting guard reports a diagnostic before exhausting the host stack" {
    const source = try std.testing.allocator.alloc(u8, max_nesting_depth + 1);
    defer std.testing.allocator.free(source);
    @memset(source, '(');
    var diag: Diag = .{};
    try std.testing.expectError(
        error.Parse,
        read(std.testing.allocator, "deep.ecl", source, &diag),
    );
    try std.testing.expectEqualStrings("form nesting too deep", diag.text());
}
