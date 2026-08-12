//! Seeded cross-module properties for the complete value layer.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");
const testgen = @import("testgen.zig");

const Value = value.Value;

test "seeded arbitrary values lock equality, hash, and print laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0001);
    const random = prng.random();
    for (0..1000) |_| {
        const a = try testgen.generateValue(allocator, random, 4, .allowed);
        defer heap.releaseValue(allocator, a);
        const b = try testgen.generateValue(allocator, random, 4, .allowed);
        defer heap.releaseValue(allocator, b);
        try std.testing.expect(equal.match(a, a));
        try std.testing.expectEqual(equal.match(a, b), equal.match(b, a));
        if (equal.match(a, b)) try std.testing.expectEqual(equal.hash(a), equal.hash(b));

        const first = try printer.toOwnedString(allocator, a);
        defer allocator.free(first);
        const second = try printer.toOwnedString(allocator, a);
        defer allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}

test "seeded specialization and cross-representation laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0002);
    const random = prng.random();
    for (0..1000) |_| {
        const count = random.intRangeAtMost(usize, 1, 8);
        const items = try allocator.alloc(Value, count);
        defer allocator.free(items);
        const use_chars = random.boolean();
        for (items) |*item| item.* = if (use_chars)
            .{ .char = testgen.randomCodepoint(random) }
        else
            .{ .int = random.intRangeAtMost(i64, -1000, 1000) };

        const leaf = try list.fromValues(allocator, items);
        defer heap.releaseValue(allocator, leaf);
        const spine = try list.fromValuesGeneric(allocator, items);
        defer heap.releaseValue(allocator, spine);
        if (use_chars) {
            try std.testing.expect(switch (leaf.list.kind()) {
                .leaf_char1, .leaf_char2, .leaf_char4 => true,
                .generic_spine,
                .leaf_i64,
                .leaf_f64,
                .leaf_symbol,
                .dict,
                .reserved_mask,
                => false,
            });
        } else {
            try std.testing.expectEqual(value.HeapKind.leaf_i64, leaf.list.kind());
        }
        for (items, 0..) |expected, index| {
            try std.testing.expectEqual(expected, try list.at(leaf, index));
        }
        try std.testing.expect(equal.match(leaf, spine));
        try std.testing.expectEqual(equal.hash(leaf), equal.hash(spine));
    }
}

test "seeded numeric and dict ordering laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0003);
    const random = prng.random();
    for (0..1000) |_| {
        const integer = random.intRangeAtMost(i32, -1_000_000, 1_000_000);
        const int_value = Value{ .int = integer };
        const float_value = Value{ .float = @floatFromInt(integer) };
        try std.testing.expect(equal.match(int_value, float_value));
        try std.testing.expectEqual(equal.hash(int_value), equal.hash(float_value));

        const pairs = [_]dict.Pair{
            .{ .{ .int = 1 }, .{ .char = testgen.randomCodepoint(random) } },
            .{ .{ .int = 2 }, .{ .int = integer } },
            .{ .{ .int = 3 }, .{ .word = try testgen.randomInternedId(random) } },
        };
        const reversed = [_]dict.Pair{ pairs[2], pairs[1], pairs[0] };
        const first = try dict.fromPairs(allocator, &pairs);
        defer heap.releaseValue(allocator, first);
        const second = try dict.fromPairs(allocator, &reversed);
        defer heap.releaseValue(allocator, second);
        try std.testing.expect(equal.match(first, second));
        try std.testing.expectEqual(equal.hash(first), equal.hash(second));
    }
}

test "seeded append sharing laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0004);
    const random = prng.random();
    for (0..1000) |_| {
        const original = try list.fromValues(allocator, &.{
            .{ .int = random.int(i32) },
            .{ .int = random.int(i32) },
        });
        defer heap.releaseValue(allocator, original);
        const unique = try list.append(allocator, original, .{ .int = random.int(i32) });
        try std.testing.expectEqual(original.list, unique.list);

        heap.incRef(original.list);
        defer heap.decRef(allocator, original.list);
        const copied = try list.append(allocator, original, .{ .int = random.int(i32) });
        defer heap.releaseValue(allocator, copied);
        try std.testing.expect(original.list != copied.list);
        try std.testing.expectEqual(@as(usize, 3), try list.len(original));
        try std.testing.expectEqual(@as(usize, 4), try list.len(copied));
    }
}

fn countLines(source: []const u8) usize {
    var lines: usize = 0;
    for (source) |byte| lines += @intFromBool(byte == '\n');
    if (source.len > 0 and source[source.len - 1] != '\n') lines += 1;
    return lines;
}

fn countCoreLines(source: []const u8) usize {
    const tests_start = std.mem.indexOf(u8, source, "\ntest \"") orelse source.len;
    return countLines(source[0..tests_start]);
}

test "reader source stays inside the decision-23 core budget" {
    const sources = .{
        @embedFile("value.zig"),
        @embedFile("heap.zig"),
        @embedFile("intern.zig"),
        @embedFile("list.zig"),
        @embedFile("equal.zig"),
        @embedFile("dict.zig"),
        @embedFile("print.zig"),
        @embedFile("lexer.zig"),
        @embedFile("binder.zig"),
        @embedFile("reader.zig"),
        @embedFile("testgen.zig"),
        @embedFile("reader_test.zig"),
    };
    var core_lines: usize = 0;
    var total_lines: usize = countLines(@embedFile("root.zig")) +
        countLines(@embedFile("value_test.zig"));
    inline for (sources) |source| {
        core_lines += countCoreLines(source);
        total_lines += countLines(source);
    }
    std.log.info(
        "reader line budget: {d} core, {d} total including tests",
        .{ core_lines, total_lines },
    );
    try std.testing.expect(core_lines < 3500);
    try std.testing.expect(total_lines < 5000);
}
