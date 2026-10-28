//! Shrinking cross-module properties for the complete value layer.

const std = @import("std");
const minish = @import("minish");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const equal = @import("../equal.zig");
const dict = @import("../dict.zig");
const printer = @import("../print.zig");
const testgen = @import("testgen.zig");

const Value = value.Value;

fn valueLaws(recipe: testgen.ValueRecipe) !void {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const a = try testgen.valueFromRecipe(allocator, cleanup.domain(), recipe, 4, .allowed, 0x00);
    defer cleanup.releaseValue(a);
    const b = try testgen.valueFromRecipe(allocator, cleanup.domain(), recipe, 4, .allowed, 0xa7);
    defer cleanup.releaseValue(b);

    try std.testing.expect(try equal.testing.match(allocator, a, a));
    try std.testing.expectEqual(try equal.testing.match(allocator, a, b), try equal.testing.match(allocator, b, a));
    if (try equal.testing.match(allocator, a, b)) try std.testing.expectEqual(try equal.testing.hash(allocator, a), try equal.testing.hash(allocator, b));

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

fn numericAndDictLaws(encoded: u64) !void {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const integer: i32 = @bitCast(@as(u32, @truncate(encoded)));
    const int_value = Value{ .int = integer };
    const float_value = Value{ .float = @floatFromInt(integer) };
    try std.testing.expect(try equal.testing.match(allocator, int_value, float_value));
    try std.testing.expectEqual(try equal.testing.hash(allocator, int_value), try equal.testing.hash(allocator, float_value));

    const pairs = [_]dict.Pair{
        .{ .{ .int = 1 }, .{ .char = testgen.codepoint(@truncate(encoded >> 32)) } },
        .{ .{ .int = 2 }, .{ .int = integer } },
        .{ .{ .int = 3 }, .{ .symbol = .{ .name = try testgen.internedId(@truncate(encoded >> 40)) } } },
    };
    const reversed = [_]dict.Pair{ pairs[2], pairs[1], pairs[0] };
    const first = try dict.testing.fromPairs(allocator, cleanup.domain(), &pairs);
    defer cleanup.releaseValue(first);
    const second = try dict.testing.fromPairs(allocator, cleanup.domain(), &reversed);
    defer cleanup.releaseValue(second);
    try std.testing.expect(try equal.testing.match(allocator, first, second));
    try std.testing.expectEqual(try equal.testing.hash(allocator, first), try equal.testing.hash(allocator, second));
}

test "numeric and dict ordering laws shrink to integers" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), numericAndDictLaws, .{
        .num_runs = 1000,
        .seed = 0xecc0_0003,
        .max_shrink_attempts = 512,
    });
}
