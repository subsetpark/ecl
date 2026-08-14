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
    printInternal(allocator, item, writer, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
        error.Ecl => unreachable,
    };
}

pub fn printWithPolling(
    allocator: std.mem.Allocator,
    item: Value,
    writer: *std.Io.Writer,
    poller: poll_api.Poller,
) (poll_api.Error || std.Io.Writer.Error)!void {
    return printInternal(allocator, item, writer, poller);
}

fn printInternal(
    allocator: std.mem.Allocator,
    item: Value,
    writer: *std.Io.Writer,
    poller: ?poll_api.Poller,
) (poll_api.Error || std.Io.Writer.Error)!void {
    var actions = poll_api.ChunkStack(Action).init(allocator);
    defer actions.deinit();
    try actions.push(.{ .render = item });
    while (actions.pop()) |action| switch (action) {
        .render => |current| {
            try pollMaybe(poller);
            switch (current) {
                .int => |number| try writer.print("{d}", .{number}),
                .float => |number| try writeFloat(number, writer),
                .char => |codepoint| try writeChar(codepoint, writer),
                .symbol => |id| {
                    try writer.writeByte('\'');
                    try writeAllPolling(intern.get(id), writer, poller);
                },
                .word => |id| try writeAllPolling(intern.get(id), writer, poller),
                .list => |header| switch (header.kind()) {
                    .leaf_char1, .leaf_char2, .leaf_char4 => try writeString(current, writer, poller),
                    .generic_spine,
                    .leaf_i64,
                    .leaf_f64,
                    .leaf_symbol,
                    => {
                        const open: u8 = if (header.kind() == .generic_spine) '(' else '[';
                        try writer.writeByte(open);
                        try actions.push(.{ .sequence = .{ .collection = current, .index = 0 } });
                    },
                    .dict, .reserved_mask => unreachable,
                },
                .dict => |header| {
                    try writer.writeByte('{');
                    try actions.push(.{ .dictionary = .{ .header = header, .index = 0, .key = true } });
                },
            }
        },
        .sequence => |continuation| {
            try pollMaybe(poller);
            const count: usize = @intCast(continuation.collection.list.length());
            if (continuation.index == count) {
                try writer.writeByte(if (continuation.collection.list.kind() == .generic_spine) ')' else ']');
                continue;
            }
            if (continuation.index > 0) try writer.writeByte(' ');
            try actions.push(.{ .sequence = .{
                .collection = continuation.collection,
                .index = continuation.index + 1,
            } });
            try actions.push(.{ .render = list.atUnchecked(
                continuation.collection,
                continuation.index,
            ) });
        },
        .dictionary => |continuation| {
            try pollMaybe(poller);
            const count: usize = @intCast(continuation.header.length());
            if (continuation.index == count) {
                try writer.writeByte('}');
                continue;
            }
            if (!continuation.key or continuation.index > 0) try writer.writeByte(' ');
            const child = if (continuation.key)
                dict.keyAt(continuation.header, continuation.index)
            else
                dict.valueAt(continuation.header, continuation.index);
            try actions.push(.{ .dictionary = .{
                .header = continuation.header,
                .index = continuation.index + @intFromBool(!continuation.key),
                .key = !continuation.key,
            } });
            try actions.push(.{ .render = child });
        },
    };
}

pub fn toOwnedString(
    allocator: std.mem.Allocator,
    item: Value,
) error{OutOfMemory}![]u8 {
    return toOwnedStringInternal(allocator, item, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Ecl => unreachable,
    };
}

pub fn toOwnedStringWithPolling(
    allocator: std.mem.Allocator,
    item: Value,
    poller: poll_api.Poller,
) poll_api.Error![]u8 {
    return toOwnedStringInternal(allocator, item, poller);
}

fn toOwnedStringInternal(
    allocator: std.mem.Allocator,
    item: Value,
    poller: ?poll_api.Poller,
) poll_api.Error![]u8 {
    var counter_buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&counter_buffer);
    printInternal(allocator, item, &counter.writer, poller) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.WriteFailed => unreachable,
    };
    const count = std.math.cast(usize, counter.fullCount()) orelse return error.OutOfMemory;
    const result = try allocator.alloc(u8, count);
    errdefer allocator.free(result);
    var fixed = std.Io.Writer.fixed(result);
    printInternal(allocator, item, &fixed, poller) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.WriteFailed => unreachable,
    };
    std.debug.assert(fixed.buffered().len == result.len);
    return result;
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

fn writeString(
    collection: Value,
    writer: *std.Io.Writer,
    poller: ?poll_api.Poller,
) (poll_api.Error || std.Io.Writer.Error)!void {
    try writer.writeByte('"');
    const count: usize = @intCast(collection.list.length());
    for (0..count) |index| {
        try pollMaybe(poller);
        const codepoint = list.atUnchecked(collection, index).char;
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
    try writer.writeByte('"');
}

fn writeAllPolling(
    bytes: []const u8,
    writer: *std.Io.Writer,
    poller: ?poll_api.Poller,
) (poll_api.Error || std.Io.Writer.Error)!void {
    if (poller == null) return writer.writeAll(bytes);
    var start: usize = 0;
    while (start < bytes.len) {
        try pollMaybe(poller);
        const end = @min(start + 256, bytes.len);
        try writer.writeAll(bytes[start..end]);
        start = end;
    }
}

fn pollMaybe(poller: ?poll_api.Poller) poll_api.Error!void {
    if (poller) |active| try active.poll();
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

test "poll-aware rendering can interrupt one large value" {
    const Stop = struct {
        calls: usize = 0,
        at: usize,

        fn tick(raw: *anyopaque) poll_api.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == self.at) return error.Ecl;
        }
    };
    const allocator = std.testing.allocator;
    const numbers = try allocator.alloc(i64, 70_000);
    defer allocator.free(numbers);
    for (numbers, 0..) |*number, index| number.* = @intCast(index);
    const collection = try list.fromI64Slice(allocator, numbers);
    defer heap.releaseValue(allocator, collection);

    var stop = Stop{ .at = 65_537 };
    try std.testing.expectError(error.Ecl, toOwnedStringWithPolling(
        allocator,
        collection,
        .{ .context = &stop, .poll_fn = Stop.tick },
    ));
    try std.testing.expectEqual(stop.at, stop.calls);
}
