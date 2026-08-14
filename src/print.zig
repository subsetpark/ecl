//! Canonical, representation-exposing value rendering.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const poll_api = @import("poll.zig");

pub const Value = value.Value;

const Action = union(enum) {
    render: Value,
    sequence: struct { collection: Value, index: usize },
    dictionary: struct { header: *value.Header, index: usize, key: bool },
    string: struct { collection: Value, index: usize },
    bytes: struct { source: []const u8, index: usize },
};

pub const RenderProgress = enum { pending, complete };

/// Owned rendering state. Each transition writes only a scalar rendering, one
/// collection edge, one codepoint, or at most 256 identifier bytes.
pub const RenderCursor = struct {
    actions: poll_api.ChunkStack(Action),

    pub fn init(allocator: std.mem.Allocator, item: Value) error{OutOfMemory}!RenderCursor {
        var actions = poll_api.ChunkStack(Action).init(allocator);
        errdefer actions.deinit();
        try actions.push(.{ .render = item });
        return .{ .actions = actions };
    }

    pub fn deinit(self: *RenderCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }

    pub fn advance(
        self: *RenderCursor,
        writer: *std.Io.Writer,
        budget: usize,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!RenderProgress {
        std.debug.assert(budget != 0);
        for (0..budget) |_| {
            const action = self.actions.pop() orelse return .complete;
            try self.renderAction(action, writer);
            if (self.actions.isEmpty()) return .complete;
        }
        return .pending;
    }

    fn renderAction(
        self: *RenderCursor,
        action: Action,
        writer: *std.Io.Writer,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!void {
        switch (action) {
            .render => |current| switch (current) {
                .int => |number| try writer.print("{d}", .{number}),
                .float => |number| try writeFloat(number, writer),
                .char => |codepoint| try writeChar(codepoint, writer),
                .symbol => |id| {
                    try writer.writeByte('\'');
                    try self.pushBytes(intern.get(id));
                },
                .word => |id| try self.pushBytes(intern.get(id)),
                .list => |header| switch (header.kind()) {
                    .leaf_char1, .leaf_char2, .leaf_char4 => {
                        try writer.writeByte('"');
                        if (header.length() == 0) try writer.writeByte('"') else try self.actions.push(.{ .string = .{ .collection = current, .index = 0 } });
                    },
                    .generic_spine, .leaf_i64, .leaf_f64, .leaf_symbol => {
                        try writer.writeByte(if (header.kind() == .generic_spine) '(' else '[');
                        try self.actions.push(.{ .sequence = .{ .collection = current, .index = 0 } });
                    },
                    .dict, .task, .reserved_mask => unreachable,
                },
                .dict => |header| {
                    try writer.writeByte('{');
                    try self.actions.push(.{ .dictionary = .{ .header = header, .index = 0, .key = true } });
                },
                .task => |header| try writer.print("<task:{d}>", .{heap.taskStorage(header).identity}),
            },
            .sequence => |continuation| {
                const count: usize = @intCast(continuation.collection.list.length());
                if (continuation.index == count) {
                    try writer.writeByte(if (continuation.collection.list.kind() == .generic_spine) ')' else ']');
                    return;
                }
                if (continuation.index > 0) try writer.writeByte(' ');
                try self.actions.push(.{ .sequence = .{
                    .collection = continuation.collection,
                    .index = continuation.index + 1,
                } });
                try self.actions.push(.{ .render = list.atUnchecked(
                    continuation.collection,
                    continuation.index,
                ) });
            },
            .dictionary => |continuation| {
                const count: usize = @intCast(continuation.header.length());
                if (continuation.index == count) {
                    try writer.writeByte('}');
                    return;
                }
                if (!continuation.key or continuation.index > 0) try writer.writeByte(' ');
                const child = if (continuation.key)
                    dict.keyAt(continuation.header, continuation.index)
                else
                    dict.valueAt(continuation.header, continuation.index);
                try self.actions.push(.{ .dictionary = .{
                    .header = continuation.header,
                    .index = continuation.index + @intFromBool(!continuation.key),
                    .key = !continuation.key,
                } });
                try self.actions.push(.{ .render = child });
            },
            .string => |continuation| {
                try writeStringCodepoint(
                    list.atUnchecked(continuation.collection, continuation.index).char,
                    writer,
                );
                const next = continuation.index + 1;
                if (next == continuation.collection.list.length()) {
                    try writer.writeByte('"');
                } else {
                    try self.actions.push(.{ .string = .{
                        .collection = continuation.collection,
                        .index = next,
                    } });
                }
            },
            .bytes => |continuation| {
                const end = @min(continuation.index + 256, continuation.source.len);
                try writer.writeAll(continuation.source[continuation.index..end]);
                if (end != continuation.source.len) {
                    try self.actions.push(.{ .bytes = .{ .source = continuation.source, .index = end } });
                }
            },
        }
    }

    fn pushBytes(self: *RenderCursor, bytes: []const u8) error{OutOfMemory}!void {
        if (bytes.len != 0) try self.actions.push(.{ .bytes = .{ .source = bytes, .index = 0 } });
    }
};

pub const OwnedStringProgress = union(enum) { pending, complete: []u8 };

/// Exact-size two-pass rendering state for scheduler drivers. No growable
/// writer is used in the cancellable path.
pub const OwnedStringCursor = struct {
    allocator: std.mem.Allocator,
    item: Value,
    cursor: RenderCursor,
    phase: enum { count, fill, complete } = .count,
    byte_count: usize = 0,
    output: ?[]u8 = null,
    written: usize = 0,

    pub fn init(allocator: std.mem.Allocator, item: Value) error{OutOfMemory}!OwnedStringCursor {
        return .{
            .allocator = allocator,
            .item = item,
            .cursor = try RenderCursor.init(allocator, item),
        };
    }

    pub fn deinit(self: *OwnedStringCursor) void {
        self.cursor.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.* = undefined;
    }

    pub fn advance(
        self: *OwnedStringCursor,
        budget: usize,
    ) error{OutOfMemory}!OwnedStringProgress {
        std.debug.assert(budget != 0 and self.phase != .complete);
        switch (self.phase) {
            .count => {
                var buffer: [256]u8 = undefined;
                var counter = std.Io.Writer.Discarding.init(&buffer);
                const progress = self.cursor.advance(&counter.writer, budget) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
                const produced = std.math.cast(usize, counter.fullCount()) orelse
                    return error.OutOfMemory;
                self.byte_count = std.math.add(usize, self.byte_count, produced) catch
                    return error.OutOfMemory;
                if (progress == .pending) return .pending;
                var fill_cursor = try RenderCursor.init(self.allocator, self.item);
                errdefer fill_cursor.deinit();
                const output = try self.allocator.alloc(u8, self.byte_count);
                self.cursor.deinit();
                self.cursor = fill_cursor;
                self.output = output;
                self.phase = .fill;
                return .pending;
            },
            .fill => {
                var fixed = std.Io.Writer.fixed(self.output.?[self.written..]);
                const progress = self.cursor.advance(&fixed, budget) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
                self.written += fixed.buffered().len;
                if (progress == .pending) return .pending;
                std.debug.assert(self.written == self.output.?.len);
                const result = self.output.?;
                self.output = null;
                self.phase = .complete;
                return .{ .complete = result };
            },
            .complete => unreachable,
        }
    }
};

pub fn print(item: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    printWithAllocator(std.heap.smp_allocator, item, writer) catch |err| switch (err) {
        error.OutOfMemory => return error.WriteFailed,
        error.WriteFailed => return error.WriteFailed,
    };
}

pub fn printWithAllocator(
    allocator: std.mem.Allocator,
    item: Value,
    writer: *std.Io.Writer,
) (error{OutOfMemory} || std.Io.Writer.Error)!void {
    var cursor = try RenderCursor.init(allocator, item);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(writer, 1024)) {
        .pending => {},
        .complete => return,
    };
}

pub fn toOwnedString(
    allocator: std.mem.Allocator,
    item: Value,
) error{OutOfMemory}![]u8 {
    var cursor = try OwnedStringCursor.init(allocator, item);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(1024)) {
        .pending => {},
        .complete => |rendered| return rendered,
    };
}

fn writeFloat(number: f64, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.math.isNan(number)) return writer.writeAll("nan");
    if (std.math.isInf(number)) {
        return writer.writeAll(if (number < 0) "-inf" else "inf");
    }
    var buffer: [128]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    fixed.print("{}", .{number}) catch unreachable;
    const rendered = fixed.buffered();
    try writer.writeAll(rendered);
    if (std.mem.indexOfAny(u8, rendered, ".eE") == null) try writer.writeAll(".0");
}

fn writeChar(codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('\\');
    switch (codepoint) {
        ' ' => return writer.writeAll("space"),
        '\t' => return writer.writeAll("tab"),
        '\n' => return writer.writeAll("newline"),
        else => {},
    }
    if (isControl(codepoint) or codepoint == '\\' or codepoint == '\'' or codepoint == '"') {
        return writer.print("u{{{x}}}", .{codepoint});
    }
    return writeCodepoint(codepoint, writer);
}

fn writeStringCodepoint(codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (codepoint) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        else => if (isControl(codepoint) or !isScalar(codepoint)) {
            try writer.print("\\u{{{x}}}", .{codepoint});
        } else {
            try writeCodepoint(codepoint, writer);
        },
    }
}

fn writeCodepoint(codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!isScalar(codepoint)) {
        return writer.print("u{{{x}}}", .{codepoint});
    }
    var encoded: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch
        @panic("validated Unicode scalar failed UTF-8 encoding");
    try writer.writeAll(encoded[0..count]);
}

fn isControl(codepoint: u32) bool {
    return codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f);
}

fn isScalar(codepoint: u32) bool {
    return codepoint <= 0x10ffff and !(codepoint >= 0xd800 and codepoint <= 0xdfff);
}

fn expectPrint(expected: []const u8, item: Value) !void {
    const actual = try toOwnedString(std.testing.allocator, item);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "canonical printer matches the Rust proof-of-concept fixtures" {
    const allocator = std.testing.allocator;
    const plus = try intern.intern("+");
    const sym = try intern.intern("sym");
    try expectPrint("2.0", .{ .float = 2.0 });
    try expectPrint("-0.0", .{ .float = -0.0 });
    try expectPrint("0.125", .{ .float = 0.125 });
    try expectPrint("inf", .{ .float = std.math.inf(f64) });
    try expectPrint("-inf", .{ .float = -std.math.inf(f64) });
    try expectPrint("'sym", .{ .symbol = sym });
    try expectPrint("sym", .{ .word = sym });

    const integers = try list.fromValues(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.releaseValue(allocator, integers);
    try expectPrint("[1 2]", integers);
    const quotation = try list.fromValues(allocator, &.{ .{ .int = 1 }, .{ .word = plus } });
    defer heap.releaseValue(allocator, quotation);
    try expectPrint("(1 +)", quotation);
    const singleton = try list.fromValues(allocator, &.{.{ .int = 3 }});
    defer heap.releaseValue(allocator, singleton);
    const nested = try list.fromValues(allocator, &.{ integers, singleton });
    defer heap.releaseValue(allocator, nested);
    try expectPrint("([1 2] [3])", nested);
    const string = try list.fromValues(allocator, &.{ .{ .char = 'a' }, .{ .char = 'b' } });
    defer heap.releaseValue(allocator, string);
    try expectPrint("\"ab\"", string);
    const empty_string = try list.fromCodepoints(allocator, &.{});
    defer heap.releaseValue(allocator, empty_string);
    try expectPrint("\"\"", empty_string);

    const a = try intern.intern("a");
    const dictionary = try dict.fromPairs(allocator, &.{.{ .{ .symbol = a }, .{ .int = 1 } }});
    defer heap.releaseValue(allocator, dictionary);
    try expectPrint("{'a 1}", dictionary);
}

test "char and string escapes follow the grammar" {
    const allocator = std.testing.allocator;
    try expectPrint("\\space", .{ .char = ' ' });
    try expectPrint("\\tab", .{ .char = '\t' });
    try expectPrint("\\newline", .{ .char = '\n' });
    try expectPrint("\\u{5c}", .{ .char = '\\' });
    const string = try list.fromValues(allocator, &.{
        .{ .char = '"' },
        .{ .char = '\n' },
        .{ .char = '\\' },
    });
    defer heap.releaseValue(allocator, string);
    try expectPrint("\"\\\"\\n\\\\\"", string);
}

test "deep rendering uses an explicit worklist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var current = Value{ .int = 1 };
    for (0..100_000) |_| {
        const next = try list.fromValuesGeneric(allocator, &.{current});
        if (current.heapHeader()) |_| heap.releaseValue(allocator, current);
        current = next;
    }
    defer heap.releaseValue(allocator, current);
    const rendered = try toOwnedString(allocator, current);
    defer allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 200_001), rendered.len);
    try std.testing.expectEqual(@as(u8, '('), rendered[0]);
    try std.testing.expectEqual(@as(u8, ')'), rendered[rendered.len - 1]);
}

test "owned rendering exposes resumable transitions for one large value" {
    const allocator = std.testing.allocator;
    const numbers = try allocator.alloc(i64, 70_000);
    defer allocator.free(numbers);
    for (numbers, 0..) |*number, index| number.* = @intCast(index);
    const collection = try list.fromI64Slice(allocator, numbers);
    defer heap.releaseValue(allocator, collection);

    var cursor = try OwnedStringCursor.init(allocator, collection);
    defer cursor.deinit();
    for (0..65_537) |_| try std.testing.expectEqual(
        OwnedStringProgress.pending,
        try cursor.advance(1),
    );
    const rendered = while (true) switch (try cursor.advance(1024)) {
        .pending => {},
        .complete => |complete| break complete,
    };
    defer allocator.free(rendered);
    try std.testing.expect(rendered.len > numbers.len);
}
