//! Executable proofs for stable ordering, distinct, and group.
const std = @import("std");
const list = @import("../list.zig");
const heap = @import("../heap.zig");
const session = @import("../session.zig");
const helper = @import("kernel_test_support.zig");

test "order: cmp and grade share exact whole-value ordering" {
    try helper.expectStack(
        "1 1 cmp 1 2 cmp 2 1 cmp " ++
            "9223372036854775807 -9223372036854775808 cmp " ++
            "9007199254740993 9007199254740992.0 cmp " ++
            "\"apple\" \"apricot\" cmp \"a\" \"aa\" cmp [\"b\" \"a\"] grade",
        "0 -1 1 1 1 -1 -1 [1 0]",
    );
    try helper.expectErrors(&.{
        .{ .name = "symbols are unordered", .source = "'a 'b cmp", .kind = "type", .word = "cmp" },
        .{ .name = "cross-domain values are unordered", .source = "1 \"x\" cmp", .kind = "type", .word = "cmp" },
        .{ .name = "nested lists are unordered", .source = "[1] [2] cmp", .kind = "type", .word = "cmp" },
    });
}

test "order: grade is stable" {
    try helper.expectStack("[2 1 2 1] grade", "[1 3 0 2]");
}

fn appendNumber(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, number: i64) !void {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
    defer allocator.free(rendered);
    try buffer.appendSlice(allocator, rendered);
}

fn appendDescendingExpectation(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    count: usize,
) !void {
    try buffer.append(allocator, '[');
    var index = count;
    while (index > 0) {
        index -= 1;
        if (index + 1 < count) try buffer.append(allocator, ' ');
        try appendNumber(buffer, allocator, @intCast(index));
    }
    try buffer.append(allocator, ']');
}

test "order: grade handles large numeric char and generic inputs" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);

    try source.append(allocator, '[');
    for (0..64) |index| {
        if (index != 0) try source.append(allocator, ' ');
        try appendNumber(&source, allocator, @intCast(index % 4));
    }
    try source.appendSlice(allocator, "] grade");
    try expected.append(allocator, '[');
    for (0..4) |bucket| for (0..16) |offset| {
        if (bucket != 0 or offset != 0) try expected.append(allocator, ' ');
        try appendNumber(&expected, allocator, @intCast(bucket + offset * 4));
    };
    try expected.append(allocator, ']');
    try helper.expectStack(source.items, expected.items);

    source.clearRetainingCapacity();
    expected.clearRetainingCapacity();
    try source.append(allocator, '[');
    for (0..40) |index| {
        if (index != 0) try source.append(allocator, ' ');
        try appendNumber(&source, allocator, @as(i64, @intCast(40 - index)) * 10_000 - 200_000);
    }
    try source.appendSlice(allocator, "] grade");
    try appendDescendingExpectation(&expected, allocator, 40);
    try helper.expectStack(source.items, expected.items);

    source.clearRetainingCapacity();
    try source.append(allocator, '[');
    for (0..40) |index| {
        if (index != 0) try source.append(allocator, ' ');
        try appendNumber(&source, allocator, @intCast(40 - index));
        try source.appendSlice(allocator, ".5");
    }
    try source.appendSlice(allocator, "] grade");
    try helper.expectStack(source.items, expected.items);

    source.clearRetainingCapacity();
    expected.clearRetainingCapacity();
    try source.appendSlice(allocator, "[-0.0 0.0");
    for (1..37) |number| {
        try source.append(allocator, ' ');
        try appendNumber(&source, allocator, @intCast(number));
        try source.appendSlice(allocator, ".0");
    }
    try source.appendSlice(allocator, " -inf inf] grade");
    try expected.appendSlice(allocator, "[38 0 1");
    for (2..38) |index| {
        try expected.append(allocator, ' ');
        try appendNumber(&expected, allocator, @intCast(index));
    }
    try expected.appendSlice(allocator, " 39]");
    try helper.expectStack(source.items, expected.items);

    source.clearRetainingCapacity();
    expected.clearRetainingCapacity();
    try source.append(allocator, '"');
    for (0..40) |index| try source.appendSlice(allocator, if (index % 2 == 0) "Ā" else "ā");
    try source.appendSlice(allocator, "\" grade");
    try expected.append(allocator, '[');
    for (0..2) |parity| for (0..20) |offset| {
        if (parity != 0 or offset != 0) try expected.append(allocator, ' ');
        try appendNumber(&expected, allocator, @intCast(parity + offset * 2));
    };
    try expected.append(allocator, ']');
    try helper.expectStack(source.items, expected.items);

    source.clearRetainingCapacity();
    expected.clearRetainingCapacity();
    try source.append(allocator, '[');
    for (0..34) |index| {
        if (index != 0) try source.append(allocator, ' ');
        try appendNumber(&source, allocator, @intCast(34 - index));
        if (index == 0) try source.appendSlice(allocator, ".0");
    }
    try source.appendSlice(allocator, "] grade");
    try appendDescendingExpectation(&expected, allocator, 34);
    try helper.expectStack(source.items, expected.items);
}

test "order: sort agrees with grade then at including representation" {
    try helper.expectStack(
        "[2 1 2 1] sort [2 1 2 1] dup grade at",
        "[1 1 2 2] [1 1 2 2]",
    );
}

test "order: stored sort body remains source honest" {
    try helper.expectStack("'sort body", "(dup grade at)");
}

test "order: distinct keeps first values across hash collisions" {
    try helper.expectStack(
        "[9007199254740993 9007199254740992.0 9007199254740993] distinct",
        "(9007199254740993 9007199254740992.0)",
    );
}

test "order: group maps first-seen keys to stable index leaves" {
    try helper.expectStack("[1 2 1 3] group", "{1 [0 2] 2 [1] 3 [3]}");
}

test "order: distinct charges nested structural hash and equality work" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    const integers = try allocator.alloc(i64, 70_000);
    defer allocator.free(integers);
    for (integers, 0..) |*integer, index| integer.* = @intCast(index);

    const left = try list.fromI64Slice(allocator, integers);
    defer cleanup.releaseValue(left);
    const right = try list.fromI64Slice(allocator, integers);
    defer cleanup.releaseValue(right);
    const outer = try list.fromValuesGeneric(allocator, &.{ left, right });
    var outer_owned = true;
    defer if (outer_owned) cleanup.releaseValue(outer);
    try runtime.pushOwned(outer);
    outer_owned = false;

    try std.testing.expect((try runtime.runUnit("<test>", "distinct pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 2);
}
