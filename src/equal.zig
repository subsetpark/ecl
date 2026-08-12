//! Iterative, representation-independent structural equality and hashing.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");

pub const Value = value.Value;
pub const Header = value.Header;

const Pair = struct { a: Value, b: Value };

const Action = union(enum) {
    compare: Pair,
    list_continue: struct {
        a: Value,
        b: Value,
        next: usize,
        len: usize,
    },
    dict_search: struct {
        a: *Header,
        b: *Header,
        entry: usize,
        candidate: usize,
    },
    dict_after_key: struct {
        a: *Header,
        b: *Header,
        entry: usize,
        candidate: usize,
    },
    dict_after_value: struct {
        a: *Header,
        b: *Header,
        entry: usize,
    },
};

/// Convenience wrapper for tests and small tools that do not own an
/// allocator. Runtime code must use `matchWithAllocator` so OOM remains an
/// ordinary error.
pub fn match(a: Value, b: Value) bool {
    return matchWithAllocator(std.heap.smp_allocator, a, b) catch
        @panic("structural equality out of memory");
}

pub fn matchWithAllocator(
    allocator: std.mem.Allocator,
    a: Value,
    b: Value,
) error{OutOfMemory}!bool {
    var actions: std.ArrayList(Action) = .empty;
    defer actions.deinit(allocator);
    try actions.append(allocator, .{ .compare = .{ .a = a, .b = b } });
    var last = false;

    while (actions.pop()) |action| switch (action) {
        .compare => |pair| {
            if (numericPair(pair.a, pair.b)) {
                last = numberEqual(pair.a, pair.b);
                continue;
            }
            if (pair.a.tag() != pair.b.tag()) {
                last = false;
                continue;
            }
            switch (pair.a) {
                .int, .float => unreachable,
                .char => |codepoint| last = codepoint == pair.b.char,
                .symbol => |id| last = id == pair.b.symbol,
                .word => |id| last = id == pair.b.word,
                .list => |a_header| {
                    const b_header = pair.b.list;
                    if (a_header == b_header) {
                        last = true;
                        continue;
                    }
                    const a_len: usize = @intCast(a_header.len);
                    const b_len: usize = @intCast(b_header.len);
                    if (a_len != b_len) {
                        last = false;
                    } else if (a_len == 0) {
                        last = true;
                    } else {
                        try actions.append(allocator, .{ .list_continue = .{
                            .a = pair.a,
                            .b = pair.b,
                            .next = 1,
                            .len = a_len,
                        } });
                        try actions.append(allocator, .{ .compare = .{
                            .a = list.atUnchecked(pair.a, 0),
                            .b = list.atUnchecked(pair.b, 0),
                        } });
                    }
                },
                .dict => |a_header| {
                    const b_header = pair.b.dict;
                    if (a_header == b_header) {
                        last = true;
                    } else if (a_header.len != b_header.len) {
                        last = false;
                    } else if (a_header.len == 0) {
                        last = true;
                    } else {
                        try actions.append(allocator, .{ .dict_search = .{
                            .a = a_header,
                            .b = b_header,
                            .entry = 0,
                            .candidate = 0,
                        } });
                    }
                },
            }
        },
        .list_continue => |continuation| {
            if (!last) continue;
            if (continuation.next == continuation.len) {
                last = true;
                continue;
            }
            try actions.append(allocator, .{ .list_continue = .{
                .a = continuation.a,
                .b = continuation.b,
                .next = continuation.next + 1,
                .len = continuation.len,
            } });
            try actions.append(allocator, .{ .compare = .{
                .a = list.atUnchecked(continuation.a, continuation.next),
                .b = list.atUnchecked(continuation.b, continuation.next),
            } });
        },
        .dict_search => |search| {
            const a_key = dictItem(search.a, true, search.entry);
            const a_hash = try hashWithAllocator(allocator, a_key);
            var candidate = search.candidate;
            const b_len: usize = @intCast(search.b.len);
            while (candidate < b_len) : (candidate += 1) {
                const b_key = dictItem(search.b, true, candidate);
                if (a_hash != try hashWithAllocator(allocator, b_key)) continue;
                try actions.append(allocator, .{ .dict_after_key = .{
                    .a = search.a,
                    .b = search.b,
                    .entry = search.entry,
                    .candidate = candidate,
                } });
                try actions.append(allocator, .{ .compare = .{ .a = a_key, .b = b_key } });
                break;
            } else last = false;
        },
        .dict_after_key => |continuation| {
            if (!last) {
                try actions.append(allocator, .{ .dict_search = .{
                    .a = continuation.a,
                    .b = continuation.b,
                    .entry = continuation.entry,
                    .candidate = continuation.candidate + 1,
                } });
                continue;
            }
            try actions.append(allocator, .{ .dict_after_value = .{
                .a = continuation.a,
                .b = continuation.b,
                .entry = continuation.entry,
            } });
            try actions.append(allocator, .{ .compare = .{
                .a = dictItem(continuation.a, false, continuation.entry),
                .b = dictItem(continuation.b, false, continuation.candidate),
            } });
        },
        .dict_after_value => |continuation| {
            if (!last) continue;
            const next = continuation.entry + 1;
            if (next == continuation.a.len) {
                last = true;
            } else {
                try actions.append(allocator, .{ .dict_search = .{
                    .a = continuation.a,
                    .b = continuation.b,
                    .entry = next,
                    .candidate = 0,
                } });
            }
        },
    };
    return last;
}

const HashAction = union(enum) {
    visit: Value,
    finish_list: usize,
    finish_entry,
    finish_dict: usize,
};

/// Convenience wrapper for tests and small tools that do not own an
/// allocator. Runtime code must use `hashWithAllocator` so OOM remains an
/// ordinary error.
pub fn hash(item: Value) u64 {
    return hashWithAllocator(std.heap.smp_allocator, item) catch
        @panic("structural hashing out of memory");
}

pub fn hashWithAllocator(
    allocator: std.mem.Allocator,
    item: Value,
) error{OutOfMemory}!u64 {
    var actions: std.ArrayList(HashAction) = .empty;
    defer actions.deinit(allocator);
    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try actions.append(allocator, .{ .visit = item });

    while (actions.pop()) |action| switch (action) {
        .visit => |current| switch (current) {
            .int => |number| try results.append(allocator, numericHash(@floatFromInt(number))),
            .float => |number| try results.append(allocator, numericHash(number)),
            .char => |codepoint| try results.append(allocator, mix(0x4348_4152, codepoint)),
            .symbol => |id| try results.append(allocator, mix(0x5359_4d42, id)),
            .word => |id| try results.append(allocator, mix(0x574f_5244, id)),
            .list => |header| {
                const count: usize = @intCast(header.len);
                try actions.append(allocator, .{ .finish_list = count });
                var index = count;
                while (index > 0) {
                    index -= 1;
                    try actions.append(allocator, .{
                        .visit = list.atUnchecked(current, index),
                    });
                }
            },
            .dict => |header| {
                const count: usize = @intCast(header.len);
                try actions.append(allocator, .{ .finish_dict = count });
                var index = count;
                while (index > 0) {
                    index -= 1;
                    try actions.append(allocator, .finish_entry);
                    try actions.append(allocator, .{ .visit = dictItem(header, false, index) });
                    try actions.append(allocator, .{ .visit = dictItem(header, true, index) });
                }
            },
        },
        .finish_list => |count| {
            const start = results.items.len - count;
            var result = mix(0x4c49_5354, count);
            for (results.items[start..]) |child_hash| result = mix(result, child_hash);
            results.shrinkRetainingCapacity(start);
            try results.append(allocator, result);
        },
        .finish_entry => {
            const value_hash = results.pop().?;
            const key_hash = results.pop().?;
            try results.append(allocator, mix(key_hash ^ 0x9e37_79b9, value_hash));
        },
        .finish_dict => |count| {
            const start = results.items.len - count;
            var result = mix(0x4449_4354, count);
            for (results.items[start..]) |entry_hash| result +%= avalanche(entry_hash);
            results.shrinkRetainingCapacity(start);
            try results.append(allocator, result);
        },
    };
    std.debug.assert(results.items.len == 1);
    return results.items[0];
}

fn numericPair(a: Value, b: Value) bool {
    const a_numeric = switch (a) {
        .int, .float => true,
        .char, .symbol, .word, .list, .dict => false,
    };
    const b_numeric = switch (b) {
        .int, .float => true,
        .char, .symbol, .word, .list, .dict => false,
    };
    return a_numeric and b_numeric;
}

/// NaN is excluded by the language boundary. Mixed int/float equality must not
/// round the integer to f64: the float is equal only when it is integral,
/// inside the i64 domain, and converts back to the original integer.
fn numberEqual(a: Value, b: Value) bool {
    return switch (a) {
        .int => |a_int| switch (b) {
            .int => |b_int| a_int == b_int,
            .float => |b_float| intFloatEqual(a_int, b_float),
            .char, .symbol, .word, .list, .dict => unreachable,
        },
        .float => |a_float| switch (b) {
            .int => |b_int| intFloatEqual(b_int, a_float),
            .float => |b_float| a_float == b_float,
            .char, .symbol, .word, .list, .dict => unreachable,
        },
        .char, .symbol, .word, .list, .dict => unreachable,
    };
}

fn intFloatEqual(integer: i64, floating: f64) bool {
    const i64_min_f64: f64 = -9_223_372_036_854_775_808.0;
    const i64_max_exclusive_f64: f64 = 9_223_372_036_854_775_808.0;
    if (!std.math.isFinite(floating) or @trunc(floating) != floating) return false;
    if (floating < i64_min_f64 or floating >= i64_max_exclusive_f64) return false;
    return @as(i64, @intFromFloat(floating)) == integer;
}

fn dictItem(header: *Header, keys: bool, index: usize) Value {
    const payload = heap.dictStorageConst(header).payload.?;
    const child = Value{ .list = if (keys) payload.keys else payload.vals };
    return list.atUnchecked(child, index);
}

fn numericHash(number: f64) u64 {
    const normalized = if (number == 0.0) 0.0 else number;
    return mix(0x4e55_4d42, @bitCast(normalized));
}

fn mix(state: u64, input: u64) u64 {
    return avalanche(state ^ (input +% 0x9e37_79b9_7f4a_7c15));
}

fn avalanche(input: u64) u64 {
    var result = input;
    result ^= result >> 30;
    result *%= 0xbf58_476d_1ce4_e5b9;
    result ^= result >> 27;
    result *%= 0x94d0_49bb_1331_11eb;
    result ^= result >> 31;
    return result;
}

fn allocationFailureProbe(allocator: std.mem.Allocator) !void {
    const left = try list.fromValuesGeneric(allocator, &.{
        .{ .int = 1 },
        .{ .float = 2.0 },
        .{ .word = 3 },
    });
    defer heap.releaseValue(allocator, left);
    const right = try list.fromValuesGeneric(allocator, &.{
        .{ .float = 1.0 },
        .{ .int = 2 },
        .{ .word = 3 },
    });
    defer heap.releaseValue(allocator, right);
    _ = try matchWithAllocator(allocator, left, right);
    _ = try hashWithAllocator(allocator, left);
}

test "ledger equality fixtures are representation independent" {
    const allocator = std.testing.allocator;
    try std.testing.expect(match(.{ .int = 2 }, .{ .float = 2.0 }));
    try std.testing.expect(match(.{ .float = 0.0 }, .{ .float = -0.0 }));
    try std.testing.expect(!match(.{ .symbol = 7 }, .{ .word = 7 }));

    const chars = [_]Value{ .{ .char = 'a' }, .{ .char = 'b' } };
    const leaf = try list.fromValues(allocator, &chars);
    defer heap.releaseValue(allocator, leaf);
    const spine = try list.fromValuesGeneric(allocator, &chars);
    defer heap.releaseValue(allocator, spine);
    try std.testing.expect(match(leaf, spine));
    try std.testing.expectEqual(hash(leaf), hash(spine));
}

test "mixed numeric equality is exact beyond f64 integer precision" {
    const two_to_53: i64 = 1 << 53;
    const i64_min_f64: f64 = -9_223_372_036_854_775_808.0;
    const i64_max_exclusive_f64: f64 = 9_223_372_036_854_775_808.0;

    try std.testing.expect(match(.{ .int = two_to_53 }, .{ .float = @floatFromInt(two_to_53) }));
    try std.testing.expect(!match(
        .{ .int = two_to_53 + 1 },
        .{ .float = @floatFromInt(two_to_53) },
    ));
    try std.testing.expect(!match(
        .{ .float = @floatFromInt(two_to_53) },
        .{ .int = two_to_53 + 1 },
    ));
    try std.testing.expect(match(.{ .int = std.math.minInt(i64) }, .{ .float = i64_min_f64 }));
    try std.testing.expect(!match(
        .{ .int = std.math.maxInt(i64) },
        .{ .float = i64_max_exclusive_f64 },
    ));
    try std.testing.expect(!match(.{ .int = 2 }, .{ .float = 2.5 }));
    try std.testing.expectEqual(
        hash(.{ .int = two_to_53 }),
        hash(.{ .float = @floatFromInt(two_to_53) }),
    );
}

test "match is reflexive and symmetric and hash agrees" {
    const values = [_]Value{
        .{ .int = -3 },
        .{ .float = -3.0 },
        .{ .char = 0x1f642 },
        .{ .symbol = 4 },
        .{ .word = 4 },
    };
    for (values) |a| {
        try std.testing.expect(match(a, a));
        for (values) |b| {
            try std.testing.expectEqual(match(a, b), match(b, a));
            if (match(a, b)) try std.testing.expectEqual(hash(a), hash(b));
        }
    }
}

test "deep structural identity uses explicit worklists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var left = Value{ .int = 1 };
    var right = Value{ .float = 1.0 };
    for (0..100_000) |_| {
        const next_left = try list.fromValuesGeneric(allocator, &.{left});
        if (left.heapHeader()) |_| heap.releaseValue(allocator, left);
        left = next_left;
        const next_right = try list.fromValuesGeneric(allocator, &.{right});
        if (right.heapHeader()) |_| heap.releaseValue(allocator, right);
        right = next_right;
    }
    defer heap.releaseValue(allocator, left);
    defer heap.releaseValue(allocator, right);
    try std.testing.expect(match(left, right));
    try std.testing.expectEqual(hash(left), hash(right));
}

test "allocator-aware equality paths propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}
