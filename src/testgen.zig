//! Shared seeded value generators for cross-layer property suites.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");

pub const Value = value.Value;
pub const Dicts = enum { allowed, excluded };

pub fn generateValue(
    allocator: std.mem.Allocator,
    random: std.Random,
    depth: usize,
    dicts: Dicts,
) error{OutOfMemory}!Value {
    const choices: u8 = if (depth == 0) 5 else switch (dicts) {
        .allowed => 7,
        .excluded => 6,
    };
    const choice = random.uintLessThan(u8, choices);
    return switch (choice) {
        0 => .{ .int = random.intRangeAtMost(i64, -10_000, 10_000) },
        1 => if (random.boolean())
            .{ .float = @floatFromInt(random.intRangeAtMost(i32, -1000, 1000)) }
        else
            .{ .float = random.float(f64) * 2000.0 - 1000.0 },
        2 => .{ .char = randomCodepoint(random) },
        3 => .{ .symbol = try randomInternedId(random) },
        4 => .{ .word = try randomInternedId(random) },
        5 => generateList(allocator, random, depth - 1, dicts),
        6 => generateDict(allocator, random, depth - 1),
        else => unreachable,
    };
}

pub fn generateList(
    allocator: std.mem.Allocator,
    random: std.Random,
    depth: usize,
    dicts: Dicts,
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
            4 => try generateValue(allocator, random, depth, dicts),
            else => unreachable,
        };
        initialized += 1;
    }
    return list.fromValues(allocator, items);
}

pub fn generateDict(
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
        pair[1] = try generateValue(allocator, random, depth, .allowed);
        initialized += 1;
    }
    return dict.fromPairs(allocator, pairs) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateKey => unreachable,
    };
}

pub fn randomCodepoint(random: std.Random) u32 {
    const samples = [_]u32{ 'a', ' ', '\n', 0xff, 0x100, 0x20ac, 0x10000, 0x1f642 };
    return samples[random.uintLessThan(usize, samples.len)];
}

pub fn randomInternedId(random: std.Random) error{OutOfMemory}!u32 {
    const names = [_][]const u8{ "alpha", "beta", "gamma", "+", "dup" };
    return intern.intern(names[random.uintLessThan(usize, names.len)]);
}
