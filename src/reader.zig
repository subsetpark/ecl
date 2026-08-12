//! GRAMMAR.md reader and the code-plane provenance handoff to M3.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const binder = @import("binder.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const Span = lexer.Span;
pub const Diag = lexer.Diag;

pub const Error = error{ OutOfMemory, Parse };
const InternalError = Error || error{Incomplete};
const max_nesting_depth = 10_000;

pub const Incomplete = struct {
    message: []const u8,
    span: Span,
};

/// Provenance is keyed by the identity of reader-built code lists. Runtime-
/// built or CoW-copied lists are naturally absent (decision 23).
pub const SpanTable = struct {
    lists: std.AutoHashMapUnmanaged(*Header, []Span) = .empty,
    top: []Span = &.{},

    pub fn forList(self: *const SpanTable, header: *Header) ?[]const Span {
        return self.lists.get(header);
    }

    pub fn deinit(self: *SpanTable, allocator: std.mem.Allocator) void {
        var iterator = self.lists.valueIterator();
        while (iterator.next()) |spans| if (spans.*.len > 0) allocator.free(spans.*);
        self.lists.deinit(allocator);
        if (self.top.len > 0) allocator.free(self.top);
        self.* = .{};
    }

    fn put(
        self: *SpanTable,
        allocator: std.mem.Allocator,
        header: *Header,
        source: []const Span,
    ) error{OutOfMemory}!void {
        std.debug.assert(self.lists.get(header) == null);
        const owned: []Span = if (source.len == 0) &.{} else try allocator.dupe(Span, source);
        errdefer if (owned.len > 0) allocator.free(owned);
        try self.lists.put(allocator, header, owned);
    }

    fn putUniform(
        self: *SpanTable,
        allocator: std.mem.Allocator,
        header: *Header,
        span: Span,
    ) error{OutOfMemory}!void {
        if (self.lists.get(header) != null) return;
        const count: usize = @intCast(header.len);
        const owned: []Span = if (count == 0) &.{} else try allocator.alloc(Span, count);
        errdefer if (owned.len > 0) allocator.free(owned);
        @memset(owned, span);
        try self.lists.put(allocator, header, owned);
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
    diag.* = .{};
    if (!std.unicode.utf8ValidateSlice(source)) {
        diag.set(.{}, "source is not valid UTF-8");
        return error.Parse;
    }

    var parser = Parser.init(allocator, source, diag);
    defer parser.spans.deinit(allocator);
    var forms: std.ArrayList(binder.SpannedValue) = .empty;
    defer forms.deinit(allocator);
    var forms_owned = true;
    defer if (forms_owned) releaseForms(allocator, forms.items);

    parser.program(&forms) catch |err| switch (err) {
        error.Incomplete => return .{ .incomplete = parser.incomplete.? },
        error.Parse => return error.Parse,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const values = try allocator.alloc(Value, forms.items.len);
    errdefer allocator.free(values);
    const top = try allocator.alloc(Span, forms.items.len);
    errdefer allocator.free(top);
    const owned_source_name = try allocator.dupe(u8, source_name);
    errdefer allocator.free(owned_source_name);
    for (forms.items, 0..) |form, index| {
        values[index] = form.value;
        top[index] = form.span;
    }

    forms_owned = false;
    parser.spans.top = top;
    const spans = parser.spans;
    parser.spans = .{};
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
    body: std.ArrayList(binder.SpannedValue) = .empty,
    names: std.ArrayList(binder.Name) = .empty,
    has_binder: bool = false,

    fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        releaseForms(allocator, self.body.items);
        self.body.deinit(allocator);
        self.names.deinit(allocator);
        self.* = undefined;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    cursor: lexer.Cursor,
    diag: *Diag,
    spans: SpanTable = .{},
    incomplete: ?Incomplete = null,

    fn init(allocator: std.mem.Allocator, source: []const u8, diag: *Diag) Parser {
        return .{ .allocator = allocator, .cursor = .init(source), .diag = diag };
    }

    fn program(self: *Parser, output: *std.ArrayList(binder.SpannedValue)) InternalError!void {
        var contexts: std.ArrayList(Context) = .empty;
        defer {
            for (contexts.items) |*context| context.deinit(self.allocator);
            contexts.deinit(self.allocator);
        }
        while (true) {
            self.cursor.skipIgnored();
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
        output: *std.ArrayList(binder.SpannedValue),
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
        const open = self.cursor.bump().?;
        var context = Context{
            .kind = switch (open) {
                '(' => .paren,
                '[' => .square,
                '{' => .dict,
                else => unreachable,
            },
            .start = start,
        };
        errdefer context.deinit(self.allocator);
        if (context.kind != .dict) {
            self.cursor.skipIgnored();
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
        output: *std.ArrayList(binder.SpannedValue),
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
        _ = self.cursor.bump();
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
        output: *std.ArrayList(binder.SpannedValue),
    ) InternalError!void {
        var lowered: ?[]binder.SpannedValue = null;
        defer if (lowered) |forms| {
            releaseForms(self.allocator, forms);
            self.allocator.free(forms);
        };
        const elements = if (context.has_binder) blk: {
            const result = try binder.lower(
                self.allocator,
                context.names.items,
                context.body.items,
                context.start,
                self.diag,
            );
            lowered = result;
            for (result) |form_item| switch (form_item.value) {
                .list => |header| try self.spans.putUniform(
                    self.allocator,
                    header,
                    context.start,
                ),
                .int, .float, .char, .symbol, .word, .dict => {},
            };
            break :blk result;
        } else context.body.items;

        const collection = try self.buildList(elements, true);
        try appendOwned(self.allocator, output, .{
            .value = collection,
            .span = context.start,
        });
    }

    fn parseBinderNames(self: *Parser, names: *std.ArrayList(binder.Name)) InternalError!void {
        const start = self.cursor.span();
        _ = self.cursor.bump();
        while (true) {
            self.cursor.skipIgnored();
            const next = self.cursor.peek() orelse
                return self.more("unclosed binder; expected `|`", start);
            if (next == '|') {
                _ = self.cursor.bump();
                if (names.items.len == 0) return self.fail(
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
            const token = self.cursor.takeToken();
            if (token.len == 0) return self.fail(
                name_span,
                "binder names must be unquoted, unqualified symbols",
            );
            try names.append(self.allocator, .{ .bytes = token, .span = name_span });
        }
    }

    fn finishDict(
        self: *Parser,
        context: *Context,
        output: *std.ArrayList(binder.SpannedValue),
    ) InternalError!void {
        const dict_of = try intern.intern("dict-of");
        const body_list = try self.buildList(context.body.items, true);
        try appendOwned(self.allocator, output, .{
            .value = body_list,
            .span = context.start,
        });
        try output.append(self.allocator, .{
            .value = .{ .word = dict_of },
            .span = context.start,
        });
    }

    fn parseString(self: *Parser, output: *std.ArrayList(binder.SpannedValue)) InternalError!void {
        const start = self.cursor.span();
        _ = self.cursor.bump();
        var codepoints: std.ArrayList(u32) = .empty;
        defer codepoints.deinit(self.allocator);
        var char_spans: std.ArrayList(Span) = .empty;
        defer char_spans.deinit(self.allocator);
        while (true) {
            const char_span = self.cursor.span();
            const next = self.cursor.peek() orelse
                return self.more("unclosed string; expected `\"`", start);
            if (next == '"') {
                _ = self.cursor.bump();
                break;
            }
            const codepoint: u32 = if (next == '\\') blk: {
                _ = self.cursor.bump();
                break :blk try self.stringEscape(start, char_span);
            } else @intCast(self.cursor.bump().?);
            try codepoints.append(self.allocator, codepoint);
            try char_spans.append(self.allocator, char_span);
        }
        const string = try list.fromCodepoints(self.allocator, codepoints.items);
        self.spans.put(self.allocator, string.list, char_spans.items) catch |err| {
            heap.releaseValue(self.allocator, string);
            return err;
        };
        try appendOwned(self.allocator, output, .{ .value = string, .span = start });
    }

    fn stringEscape(self: *Parser, string_start: Span, escape_span: Span) InternalError!u32 {
        const next = self.cursor.bump() orelse
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
        output: *std.ArrayList(binder.SpannedValue),
    ) InternalError!void {
        const start = self.cursor.span();
        _ = self.cursor.bump();
        const token = self.cursor.takeToken();
        if (!lexer.validSymbol(token)) {
            if (token.len == 0) return self.fail(start, "quoted symbol is missing its name");
            return self.failFmt(start, "invalid quoted symbol `'{s}`", .{token});
        }
        const id = try intern.intern(token);
        try output.append(self.allocator, .{ .value = .{ .symbol = id }, .span = start });
    }

    fn parseCharacter(
        self: *Parser,
        output: *std.ArrayList(binder.SpannedValue),
    ) InternalError!void {
        const start = self.cursor.span();
        _ = self.cursor.bump();
        const next = self.cursor.peek() orelse
            return self.fail(start, "character literal is missing its character");
        const codepoint: u32 = if (next == 'u' and self.cursor.peekN(1) == '{') blk: {
            _ = self.cursor.bump();
            break :blk try self.unicodeEscape(
                start,
                start,
                "Unicode character literal",
            );
        } else if (lexer.isTokenBoundary(next) or
            next == ';' or next == '|' or next == '\'' or next == '\\')
            @intCast(self.cursor.bump().?)
        else blk: {
            const token = self.cursor.takeToken();
            if (std.mem.eql(u8, token, "space")) break :blk ' ';
            if (std.mem.eql(u8, token, "tab")) break :blk '\t';
            if (std.mem.eql(u8, token, "newline")) break :blk '\n';
            break :blk try self.singleCodepoint(token, start);
        };
        try output.append(self.allocator, .{ .value = .{ .char = codepoint }, .span = start });
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
        _ = self.cursor.bump();
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
            _ = self.cursor.bump();
        }
        const digits_end = self.cursor.byteIndex();
        _ = self.cursor.bump();
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

    fn parseAtom(self: *Parser, output: *std.ArrayList(binder.SpannedValue)) InternalError!void {
        const start = self.cursor.span();
        const token = self.cursor.takeToken();
        if (token.len == 0) return self.fail(start, "expected a token");
        const item: Value = switch (lexer.classify(token)) {
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
                if (!lexer.validSymbol(token)) return self.failFmt(
                    start,
                    "invalid word `{s}`",
                    .{token},
                );
                break :blk .{ .word = try intern.intern(token) };
            },
        };
        try output.append(self.allocator, .{ .value = item, .span = start });
    }

    fn buildList(
        self: *Parser,
        forms: []const binder.SpannedValue,
        specialize: bool,
    ) error{OutOfMemory}!Value {
        const values = try self.allocator.alloc(Value, forms.len);
        defer self.allocator.free(values);
        const element_spans = try self.allocator.alloc(Span, forms.len);
        defer self.allocator.free(element_spans);
        for (forms, 0..) |form_item, index| {
            values[index] = form_item.value;
            element_spans[index] = form_item.span;
        }
        const collection = if (specialize)
            try list.fromValues(self.allocator, values)
        else
            try list.fromValuesGeneric(self.allocator, values);
        errdefer heap.releaseValue(self.allocator, collection);
        try self.spans.put(self.allocator, collection.list, element_spans);
        return collection;
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

fn appendOwned(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(binder.SpannedValue),
    form: binder.SpannedValue,
) error{OutOfMemory}!void {
    output.append(allocator, form) catch |err| {
        heap.releaseValue(allocator, form.value);
        return err;
    };
}

fn releaseForms(allocator: std.mem.Allocator, forms: []const binder.SpannedValue) void {
    for (forms) |form| heap.releaseValue(allocator, form.value);
}

fn isCloser(codepoint: u21) bool {
    return codepoint == ')' or codepoint == ']' or codepoint == '}';
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

test "dict literals desugar to two forms" {
    const printer = @import("print.zig");
    var parsed = try parsedForTest("{'answer 40 2 +}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.forms.len);
    const body = try printer.toOwnedString(std.testing.allocator, parsed.forms[0]);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("('answer 40 2 +)", body);
    try std.testing.expectEqualStrings("dict-of", intern.get(parsed.forms[1].word));

    var chars = try parsedForTest("{\\a \\b}");
    defer chars.deinit();
    try std.testing.expectEqual(value.HeapKind.leaf_char1, chars.forms[0].list.kind());
    const char_body = try printer.toOwnedString(std.testing.allocator, chars.forms[0]);
    defer std.testing.allocator.free(char_body);
    try std.testing.expectEqualStrings("\"ab\"", char_body);
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
    try std.testing.expectEqual(@as(usize, 2), parsed.spans.forList(outer.list).?.len);
    const inner = list.atUnchecked(outer, 1);
    try std.testing.expectEqual(@as(usize, 2), parsed.spans.forList(inner.list).?.len);
    const hand_built = try list.fromValues(std.testing.allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(std.testing.allocator, hand_built);
    try std.testing.expect(parsed.spans.forList(hand_built.list) == null);
}

test "all-char quotation is the string value" {
    var parsed = try parsedForTest("[\\a \\b]");
    defer parsed.deinit();
    try std.testing.expectEqual(value.HeapKind.leaf_char1, parsed.forms[0].list.kind());
    try std.testing.expectEqual(@as(usize, 2), parsed.spans.forList(parsed.forms[0].list).?.len);
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
