//! Shrinking cross-module properties for the complete value layer.

const std = @import("std");
const minish = @import("minish");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const storage = @import("../kernel_storage.zig");
const equal = @import("../equal.zig");
const dict = @import("../dict.zig");
const printer = @import("../print.zig");
const testgen = @import("testgen.zig");

const Value = value.Value;

fn valueLaws(recipe: testgen.ValueRecipe) !void {
    const allocator = std.testing.allocator;
    const a = try testgen.valueFromRecipe(allocator, recipe, 4, .allowed, 0x00);
    defer heap.testing.releaseValue(allocator, a);
    const b = try testgen.valueFromRecipe(allocator, recipe, 4, .allowed, 0xa7);
    defer heap.testing.releaseValue(allocator, b);

    try std.testing.expect(equal.match(a, a));
    try std.testing.expectEqual(equal.match(a, b), equal.match(b, a));
    if (equal.match(a, b)) try std.testing.expectEqual(equal.hash(a), equal.hash(b));

    const first = try printer.toOwnedString(allocator, a);
    defer allocator.free(first);
    const second = try printer.toOwnedString(allocator, a);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "arbitrary values lock equality hash and print laws with shrinking" {
    try minish.check(std.testing.allocator, testgen.value_recipe_generator, valueLaws, .{
        .num_runs = 1000,
        .seed = 0xecc0_0001,
        .max_shrink_attempts = 512,
    });
}

fn specializationLaws(encoded: u64) !void {
    const allocator = std.testing.allocator;
    const count: usize = @intCast(encoded % 8 + 1);
    const items = try allocator.alloc(Value, count);
    defer allocator.free(items);
    const use_chars = encoded & 0x100 != 0;
    var remaining = std.math.rotr(u64, encoded, 9);
    for (items) |*item| {
        item.* = if (use_chars)
            .{ .char = testgen.codepoint(@truncate(remaining)) }
        else
            .{ .int = @as(i16, @bitCast(@as(u16, @truncate(remaining)))) };
        remaining = std.math.rotr(u64, remaining, 8);
    }

    const leaf = try list.fromValues(allocator, items);
    defer heap.testing.releaseValue(allocator, leaf);
    const spine = try list.fromValuesGeneric(allocator, items);
    defer heap.testing.releaseValue(allocator, spine);
    if (use_chars) {
        try std.testing.expect(leaf.isString());
    } else {
        try std.testing.expectEqual(value.HeapKind.leaf_i64, leaf.list.kind());
    }
    for (items, 0..) |expected, index| {
        try std.testing.expectEqual(expected, try list.at(leaf, index));
    }
    try std.testing.expect(equal.match(leaf, spine));
    try std.testing.expectEqual(equal.hash(leaf), equal.hash(spine));
}

test "specialization and cross-representation laws shrink to integers" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), specializationLaws, .{
        .num_runs = 1000,
        .seed = 0xecc0_0002,
        .max_shrink_attempts = 512,
    });
}

fn resumableMaterializationLaw(encoded: u64) !void {
    const allocator = std.testing.allocator;
    const count: usize = @intCast(encoded % 33);
    const items = try allocator.alloc(Value, count);
    defer allocator.free(items);
    var bits = std.math.rotr(u64, encoded, 6);
    for (items) |*item| {
        item.* = switch (bits % 5) {
            0 => .{ .int = @as(i16, @bitCast(@as(u16, @truncate(bits)))) },
            1 => .{ .float = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(bits))))) },
            2 => .{ .char = testgen.codepoint(@truncate(bits)) },
            3 => .{ .symbol = @truncate(bits) },
            else => .{ .word = @truncate(bits) },
        };
        bits = std.math.rotr(u64, bits, 7);
    }

    const expected = try list.fromValues(allocator, items);
    defer heap.testing.releaseValue(allocator, expected);
    var materializer = storage.ValueMaterializer.init(allocator, items);
    defer materializer.deinit();
    const budget: usize = @intCast((encoded >> 48) % 9 + 1);
    const actual = while (true) switch (try materializer.advance(budget)) {
        .pending => continue,
        .complete => |complete| break complete,
    };
    defer heap.testing.releaseValue(allocator, actual);
    try std.testing.expectEqual(expected.list.kind(), actual.list.kind());
    try std.testing.expect(equal.match(expected, actual));
}

test "resumable list materialization preserves specialization under arbitrary slices" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), resumableMaterializationLaw, .{
        .num_runs = 1000,
        .seed = 0xecc0_0005,
        .max_shrink_attempts = 512,
    });
}

fn numericAndDictLaws(encoded: u64) !void {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const integer: i32 = @bitCast(@as(u32, @truncate(encoded)));
    const int_value = Value{ .int = integer };
    const float_value = Value{ .float = @floatFromInt(integer) };
    try std.testing.expect(equal.match(int_value, float_value));
    try std.testing.expectEqual(equal.hash(int_value), equal.hash(float_value));

    const pairs = [_]dict.Pair{
        .{ .{ .int = 1 }, .{ .char = testgen.codepoint(@truncate(encoded >> 32)) } },
        .{ .{ .int = 2 }, .{ .int = integer } },
        .{ .{ .int = 3 }, .{ .word = try testgen.internedId(@truncate(encoded >> 40)) } },
    };
    const reversed = [_]dict.Pair{ pairs[2], pairs[1], pairs[0] };
    const first = try dict.fromPairs(allocator, cleanup.domain(), &pairs);
    defer heap.testing.releaseValue(allocator, first);
    const second = try dict.fromPairs(allocator, cleanup.domain(), &reversed);
    defer heap.testing.releaseValue(allocator, second);
    try std.testing.expect(equal.match(first, second));
    try std.testing.expectEqual(equal.hash(first), equal.hash(second));
}

test "numeric and dict ordering laws shrink to integers" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), numericAndDictLaws, .{
        .num_runs = 1000,
        .seed = 0xecc0_0003,
        .max_shrink_attempts = 512,
    });
}

fn appendSharingLaws(encoded: u64) !void {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const original = try list.fromValues(allocator, &.{
        .{ .int = @as(i32, @bitCast(@as(u32, @truncate(encoded)))) },
        .{ .int = @as(i32, @bitCast(@as(u32, @truncate(encoded >> 16)))) },
    });
    defer heap.testing.releaseValue(allocator, original);
    const unique_update = try list.append(
        allocator,
        cleanup.domain(),
        original,
        .{ .int = @as(i32, @bitCast(@as(u32, @truncate(encoded >> 32)))) },
    );
    try std.testing.expect(unique_update == .in_place);
    const unique = unique_update.value();
    try std.testing.expectEqual(original.list, unique.list);

    heap.incRef(original.list);
    defer heap.testing.decRef(allocator, original.list);
    const copied_update = try list.append(
        allocator,
        cleanup.domain(),
        original,
        .{ .int = @as(i32, @bitCast(@as(u32, @truncate(encoded >> 48)))) },
    );
    try std.testing.expect(copied_update == .replacement);
    const copied = copied_update.value();
    defer heap.testing.releaseValue(allocator, copied);
    try std.testing.expect(original.list != copied.list);
    try std.testing.expectEqual(@as(usize, 3), try list.len(original));
    try std.testing.expectEqual(@as(usize, 4), try list.len(copied));
}

test "append sharing laws shrink to integers" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), appendSharingLaws, .{
        .num_runs = 1000,
        .seed = 0xecc0_0004,
        .max_shrink_attempts = 512,
    });
}
