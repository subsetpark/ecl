//! Canonical, representation-exposing value rendering.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");

pub const Value = value.Value;

const Action = union(enum) {
    render: Value,
    bytes: []const u8,
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
    var actions: std.ArrayList(Action) = .empty;
    defer actions.deinit(allocator);
    try actions.append(allocator, .{ .render = item });
    while (actions.pop()) |action| switch (action) {
        .bytes => |bytes| try writer.writeAll(bytes),
        .render => |current| switch (current) {
            .int => |number| try writer.print("{d}", .{number}),
            .float => |number| try writeFloat(number, writer),
            .char => |codepoint| try writeChar(codepoint, writer),
            .symbol => |id| {
                try writer.writeByte('\'');
                try writer.writeAll(intern.get(id));
            },
            .word => |id| try writer.writeAll(intern.get(id)),
            .list => |header| switch (header.kind()) {
                .leaf_char1, .leaf_char2, .leaf_char4 => try writeString(current, writer),
                .generic_spine,
                .leaf_i64,
                .leaf_f64,
                .leaf_symbol,
                => {
                    const open: u8 = if (header.kind() == .generic_spine) '(' else '[';
                    const close: []const u8 = if (header.kind() == .generic_spine) ")" else "]";
                    try writer.writeByte(open);
                    try pushSequence(allocator, &actions, current, close);
                },
                .dict, .reserved_mask => unreachable,
            },
            .dict => |header| {
                try writer.writeByte('{');
                try actions.append(allocator, .{ .bytes = "}" });
                const count: usize = @intCast(header.len);
                var position = count * 2;
                while (position > 0) {
                    position -= 1;
                    const index = position / 2;
                    const child = if (position % 2 == 0)
                        dict.keyAt(header, index)
                    else
                        dict.valueAt(header, index);
                    try actions.append(allocator, .{ .render = child });
                    if (position > 0) try actions.append(allocator, .{ .bytes = " " });
                }
            },
        },
    };
}

pub fn toOwnedString(
    allocator: std.mem.Allocator,
    item: Value,
) error{OutOfMemory}![]u8 {
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    printWithAllocator(allocator, item, &allocating.writer) catch return error.OutOfMemory;
    return allocating.toOwnedSlice();
}

fn pushSequence(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(Action),
    collection: Value,
    close: []const u8,
) error{OutOfMemory}!void {
    try actions.append(allocator, .{ .bytes = close });
    var index: usize = @intCast(collection.list.len);
    while (index > 0) {
        index -= 1;
        try actions.append(allocator, .{
            .render = list.atUnchecked(collection, index),
        });
        if (index > 0) try actions.append(allocator, .{ .bytes = " " });
    }
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

fn writeString(collection: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    const count: usize = @intCast(collection.list.len);
    for (0..count) |index| {
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

fn writeCodepoint(codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!isScalar(codepoint)) {
        return writer.print("u{{{x}}}", .{codepoint});
    }
    var encoded: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch unreachable;
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
