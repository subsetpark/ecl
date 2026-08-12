//! Seeded cross-module properties for the complete value layer.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");

const Value = value.Value;

fn generateValue(
    allocator: std.mem.Allocator,
    random: std.Random,
    depth: usize,
) error{OutOfMemory}!Value {
    const choice = random.uintLessThan(u8, if (depth == 0) 5 else 7);
    return switch (choice) {
        0 => .{ .int = random.intRangeAtMost(i64, -10_000, 10_000) },
        1 => if (random.boolean())
            .{ .float = @floatFromInt(random.intRangeAtMost(i32, -1000, 1000)) }
        else
            .{ .float = random.float(f64) * 2000.0 - 1000.0 },
        2 => .{ .char = randomCodepoint(random) },
        3 => .{ .symbol = try randomInternedId(random) },
        4 => .{ .word = try randomInternedId(random) },
        5 => generateList(allocator, random, depth - 1),
        6 => generateDict(allocator, random, depth - 1),
        else => unreachable,
    };
}

fn generateList(
    allocator: std.mem.Allocator,
    random: std.Random,
    depth: usize,
) error{OutOfMemory}!Value {
    const count = random.uintLessThan(usize, 5);
    const items = try allocator.alloc(Value, count);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |item| heap.releaseValue(allocator, item);

    const shape = random.uintLessThan(u8, 5);
    for (items) |*item| {
        item.* = switch (shape) {
            0 => .{ .int = random.intRangeAtMost(i64, -100, 100) },
            1 => .{ .float = random.float(f64) * 10.0 },
            2 => .{ .char = randomCodepoint(random) },
            3 => .{ .symbol = try randomInternedId(random) },
            4 => try generateValue(allocator, random, depth),
            else => unreachable,
        };
        initialized += 1;
    }
    return list.fromValues(allocator, items);
}

fn generateDict(
    allocator: std.mem.Allocator,
    random: std.Random,
    depth: usize,
) error{OutOfMemory}!Value {
    const count = random.uintLessThan(usize, 4);
    const pairs = try allocator.alloc(dict.Pair, count);
    defer allocator.free(pairs);
    var initialized: usize = 0;
    defer for (pairs[0..initialized]) |pair| {
        heap.releaseValue(allocator, pair[0]);
        heap.releaseValue(allocator, pair[1]);
    };

    const base = random.intRangeAtMost(i64, -1_000_000, 1_000_000);
    for (pairs, 0..) |*pair, index| {
        pair[0] = .{ .int = base + @as(i64, @intCast(index)) };
        pair[1] = try generateValue(allocator, random, depth);
        initialized += 1;
    }
    return dict.fromPairs(allocator, pairs) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateKey => unreachable,
    };
}

fn randomCodepoint(random: std.Random) u32 {
    const samples = [_]u32{ 'a', ' ', '\n', 0xff, 0x100, 0x20ac, 0x10000, 0x1f642 };
    return samples[random.uintLessThan(usize, samples.len)];
}

fn randomInternedId(random: std.Random) error{OutOfMemory}!u32 {
    const names = [_][]const u8{ "alpha", "beta", "gamma", "+", "dup" };
    return intern.intern(names[random.uintLessThan(usize, names.len)]);
}

test "seeded arbitrary values lock equality, hash, and print laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0001);
    const random = prng.random();
    for (0..1000) |_| {
        const a = try generateValue(allocator, random, 4);
        defer heap.releaseValue(allocator, a);
        const b = try generateValue(allocator, random, 4);
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
            .{ .char = randomCodepoint(random) }
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
            .{ .{ .int = 1 }, .{ .char = randomCodepoint(random) } },
            .{ .{ .int = 2 }, .{ .int = integer } },
            .{ .{ .int = 3 }, .{ .word = try randomInternedId(random) } },
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

test "value-core source stays inside the decision-23 core budget" {
    const sources = .{
        @embedFile("value.zig"),
        @embedFile("heap.zig"),
        @embedFile("intern.zig"),
        @embedFile("list.zig"),
        @embedFile("equal.zig"),
        @embedFile("dict.zig"),
        @embedFile("print.zig"),
    };
    var core_lines: usize = 0;
    var total_lines: usize = countLines(@embedFile("root.zig")) +
        countLines(@embedFile("value_test.zig"));
    inline for (sources) |source| {
        core_lines += countCoreLines(source);
        total_lines += countLines(source);
    }
    std.log.info(
        "value-core line budget: {d} core, {d} total including tests",
        .{ core_lines, total_lines },
    );
    try std.testing.expect(core_lines < 2000);
    try std.testing.expect(total_lines < 5000);
}
