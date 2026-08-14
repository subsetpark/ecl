//! Iterative, representation-independent structural equality and hashing.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const poll = @import("poll.zig");

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
    return matchInternal(allocator, a, b, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Ecl => @panic("structural equality polled without a poller"),
    };
}

/// Runtime structural equality. Every visited value passes through `poller`,
/// including values reached while hashing dictionary keys.
pub fn matchWithPolling(
    allocator: std.mem.Allocator,
    a: Value,
    b: Value,
    poller: poll.Poller,
) poll.Error!bool {
    return matchInternal(allocator, a, b, poller);
}

fn matchInternal(
    allocator: std.mem.Allocator,
    a: Value,
    b: Value,
    poller: ?poll.Poller,
) poll.Error!bool {
    var actions = poll.ChunkStack(Action).init(allocator);
    defer actions.deinit();
    try actions.push(.{ .compare = .{ .a = a, .b = b } });
    var last = false;

    while (actions.pop()) |action| switch (action) {
        .compare => |pair| {
            try pollValue(poller);
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
                    const a_len: usize = @intCast(a_header.length());
                    const b_len: usize = @intCast(b_header.length());
                    if (a_len != b_len) {
                        last = false;
                    } else if (a_len == 0) {
                        last = true;
                    } else {
                        try actions.push(.{ .list_continue = .{
                            .a = pair.a,
                            .b = pair.b,
                            .next = 1,
                            .len = a_len,
                        } });
                        try actions.push(.{ .compare = .{
                            .a = list.atUnchecked(pair.a, 0),
                            .b = list.atUnchecked(pair.b, 0),
                        } });
                    }
                },
                .dict => |a_header| {
                    const b_header = pair.b.dict;
                    if (a_header == b_header) {
                        last = true;
                    } else if (a_header.length() != b_header.length()) {
                        last = false;
                    } else if (a_header.length() == 0) {
                        last = true;
                    } else {
                        try actions.push(.{ .dict_search = .{
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
            try actions.push(.{ .list_continue = .{
                .a = continuation.a,
                .b = continuation.b,
                .next = continuation.next + 1,
                .len = continuation.len,
            } });
            try actions.push(.{ .compare = .{
                .a = list.atUnchecked(continuation.a, continuation.next),
                .b = list.atUnchecked(continuation.b, continuation.next),
            } });
        },
        .dict_search => |search| {
            const a_key = dictItem(search.a, true, search.entry);
            const a_hash = try hashInternal(allocator, a_key, poller);
            var candidate = search.candidate;
            const b_len: usize = @intCast(search.b.length());
            while (candidate < b_len) : (candidate += 1) {
                const b_key = dictItem(search.b, true, candidate);
                if (a_hash != try hashInternal(allocator, b_key, poller)) continue;
                try actions.push(.{ .dict_after_key = .{
                    .a = search.a,
                    .b = search.b,
                    .entry = search.entry,
                    .candidate = candidate,
                } });
                try actions.push(.{ .compare = .{ .a = a_key, .b = b_key } });
                break;
            } else last = false;
        },
        .dict_after_key => |continuation| {
            if (!last) {
                try actions.push(.{ .dict_search = .{
                    .a = continuation.a,
                    .b = continuation.b,
                    .entry = continuation.entry,
                    .candidate = continuation.candidate + 1,
                } });
                continue;
            }
            try actions.push(.{ .dict_after_value = .{
                .a = continuation.a,
                .b = continuation.b,
                .entry = continuation.entry,
            } });
            try actions.push(.{ .compare = .{
                .a = dictItem(continuation.a, false, continuation.entry),
                .b = dictItem(continuation.b, false, continuation.candidate),
            } });
        },
        .dict_after_value => |continuation| {
            if (!last) continue;
            const next = continuation.entry + 1;
            if (next == continuation.a.length()) {
                last = true;
            } else {
                try actions.push(.{ .dict_search = .{
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

/// Exact scalar ordering for the provisional M3 arithmetic seam. Mixed
/// int/float comparisons never round the integer through f64 first.
pub fn compareScalars(a: Value, b: Value) error{NotComparable}!std.math.Order {
    return switch (a) {
        .int => |a_int| switch (b) {
            .int => |b_int| orderInt(a_int, b_int),
            .float => |b_float| intFloatOrder(a_int, b_float) orelse
                error.NotComparable,
            .char, .symbol, .word, .list, .dict => error.NotComparable,
        },
        .float => |a_float| switch (b) {
            .int => |b_int| reverseOrder(intFloatOrder(b_int, a_float) orelse
                return error.NotComparable),
            .float => |b_float| {
                if (std.math.isNan(a_float) or std.math.isNan(b_float)) {
                    return error.NotComparable;
                }
                return orderFloat(a_float, b_float);
            },
            .char, .symbol, .word, .list, .dict => error.NotComparable,
        },
        .char => |a_char| switch (b) {
            .char => |b_char| orderInt(a_char, b_char),
            .int, .float, .symbol, .word, .list, .dict => error.NotComparable,
        },
        .symbol, .word, .list, .dict => error.NotComparable,
    };
}

fn intFloatOrder(integer: i64, floating: f64) ?std.math.Order {
    const i64_min_f64: f64 = -9_223_372_036_854_775_808.0;
    const i64_max_exclusive_f64: f64 = 9_223_372_036_854_775_808.0;
    if (std.math.isNan(floating)) return null;
    if (floating < i64_min_f64) return .gt;
    if (floating >= i64_max_exclusive_f64) return .lt;

    const truncated: i64 = @intFromFloat(floating);
    const integer_order = orderInt(integer, truncated);
    if (integer_order != .eq) return integer_order;
    const fraction = floating - @trunc(floating);
    if (fraction > 0.0) return .lt;
    if (fraction < 0.0) return .gt;
    return .eq;
}

fn orderInt(a: anytype, b: @TypeOf(a)) std.math.Order {
    return if (a < b) .lt else if (a > b) .gt else .eq;
}

fn orderFloat(a: f64, b: f64) std.math.Order {
    return if (a < b) .lt else if (a > b) .gt else .eq;
}

fn reverseOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

const HashAction = union(enum) {
    visit: Value,
    list_after: struct {
        collection: Value,
        index: usize,
        state: u64,
    },
    dict_after_key: struct {
        header: *Header,
        index: usize,
        state: u64,
    },
    dict_after_value: struct {
        header: *Header,
        index: usize,
        state: u64,
        key_hash: u64,
    },
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
    return hashInternal(allocator, item, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Ecl => @panic("structural hashing polled without a poller"),
    };
}

/// Runtime structural hash. Charges every nested value to the supplied
/// safe-point budget rather than only the outer collection cell.
pub fn hashWithPolling(
    allocator: std.mem.Allocator,
    item: Value,
    poller: poll.Poller,
) poll.Error!u64 {
    return hashInternal(allocator, item, poller);
}

fn hashInternal(
    allocator: std.mem.Allocator,
    item: Value,
    poller: ?poll.Poller,
) poll.Error!u64 {
    if (scalarHash(item)) |result| {
        try pollValue(poller);
        return result;
    }
    var actions = poll.ChunkStack(HashAction).init(allocator);
    defer actions.deinit();
    try actions.push(.{ .visit = item });
    // SAFETY: every continuation is pushed below a child visit, and empty
    // containers assign their result directly, so `last` is set before read.
    var last: u64 = undefined;

    while (actions.pop()) |action| switch (action) {
        .visit => |current| {
            try pollValue(poller);
            if (scalarHash(current)) |result| {
                last = result;
                continue;
            }
            switch (current) {
                .list => |header| {
                    const count: usize = @intCast(header.length());
                    const state = mix(0x4c49_5354, count);
                    if (count == 0) {
                        last = state;
                    } else {
                        try actions.push(.{ .list_after = .{
                            .collection = current,
                            .index = 0,
                            .state = state,
                        } });
                        try actions.push(.{ .visit = list.atUnchecked(current, 0) });
                    }
                },
                .dict => |header| {
                    const count: usize = @intCast(header.length());
                    const state = mix(0x4449_4354, count);
                    if (count == 0) {
                        last = state;
                    } else {
                        try actions.push(.{ .dict_after_key = .{
                            .header = header,
                            .index = 0,
                            .state = state,
                        } });
                        try actions.push(.{ .visit = dictItem(header, true, 0) });
                    }
                },
                .int, .float, .char, .symbol, .word => unreachable,
            }
        },
        .list_after => |continuation| {
            try pollValue(poller);
            const state = mix(continuation.state, last);
            const next = continuation.index + 1;
            if (next == @as(usize, @intCast(continuation.collection.list.length()))) {
                last = state;
            } else {
                try actions.push(.{ .list_after = .{
                    .collection = continuation.collection,
                    .index = next,
                    .state = state,
                } });
                try actions.push(.{
                    .visit = list.atUnchecked(continuation.collection, next),
                });
            }
        },
        .dict_after_key => |continuation| {
            const key_hash = last;
            try actions.push(.{ .dict_after_value = .{
                .header = continuation.header,
                .index = continuation.index,
                .state = continuation.state,
                .key_hash = key_hash,
            } });
            try actions.push(.{
                .visit = dictItem(continuation.header, false, continuation.index),
            });
        },
        .dict_after_value => |continuation| {
            try pollValue(poller);
            const entry_hash = mix(continuation.key_hash ^ 0x9e37_79b9, last);
            const state = continuation.state +% avalanche(entry_hash);
            const next = continuation.index + 1;
            if (next == @as(usize, @intCast(continuation.header.length()))) {
                last = state;
            } else {
                try actions.push(.{ .dict_after_key = .{
                    .header = continuation.header,
                    .index = next,
                    .state = state,
                } });
                try actions.push(.{ .visit = dictItem(continuation.header, true, next) });
            }
        },
    };
    return last;
}

fn pollValue(poller: ?poll.Poller) poll.Error!void {
    if (poller) |active| try active.poll();
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

fn scalarHash(item: Value) ?u64 {
    return switch (item) {
        .int => |number| numericHash(@floatFromInt(number)),
        .float => |number| numericHash(number),
        .char => |codepoint| mix(0x4348_4152, codepoint),
        .symbol => |id| mix(0x5359_4d42, id),
        .word => |id| mix(0x574f_5244, id),
        .list, .dict => null,
    };
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

test "scalar ordering is exact beyond f64 integer precision" {
    const two_to_53: i64 = 9_007_199_254_740_992;
    try std.testing.expectEqual(
        std.math.Order.gt,
        try compareScalars(.{ .int = two_to_53 + 1 }, .{ .float = 9_007_199_254_740_992.0 }),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        try compareScalars(.{ .float = 9_007_199_254_740_992.0 }, .{ .int = two_to_53 + 1 }),
    );
    try std.testing.expectEqual(
        std.math.Order.eq,
        try compareScalars(.{ .int = two_to_53 }, .{ .float = 9_007_199_254_740_992.0 }),
    );
    try std.testing.expectEqual(
        std.math.Order.eq,
        try compareScalars(.{ .int = std.math.minInt(i64) }, .{ .float = -9_223_372_036_854_775_808.0 }),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        try compareScalars(.{ .int = std.math.maxInt(i64) }, .{ .float = 9_223_372_036_854_775_808.0 }),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        try compareScalars(.{ .int = 4 }, .{ .float = 4.5 }),
    );
    try std.testing.expectEqual(
        std.math.Order.gt,
        try compareScalars(.{ .int = -4 }, .{ .float = -4.5 }),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        try compareScalars(.{ .char = 'a' }, .{ .char = 'b' }),
    );
    try std.testing.expectError(
        error.NotComparable,
        compareScalars(.{ .word = 1 }, .{ .word = 1 }),
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

test "poll-aware hash and equality charge nested values" {
    const PollCounter = struct {
        visits: usize = 0,

        fn tick(raw: *anyopaque) poll.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.visits += 1;
        }
    };
    const allocator = std.testing.allocator;
    const numbers = try allocator.alloc(i64, 70_000);
    defer allocator.free(numbers);
    for (numbers, 0..) |*number, index| number.* = @intCast(index);
    const left = try list.fromI64Slice(allocator, numbers);
    defer heap.releaseValue(allocator, left);
    const right = try list.fromI64Slice(allocator, numbers);
    defer heap.releaseValue(allocator, right);

    var counter: PollCounter = .{};
    const poller = poll.Poller{ .context = &counter, .poll_fn = PollCounter.tick };
    _ = try hashWithPolling(allocator, left, poller);
    // One root visit plus visiting and folding each child.
    try std.testing.expectEqual(@as(usize, 140_001), counter.visits);

    counter.visits = 0;
    try std.testing.expect(try matchWithPolling(allocator, left, right, poller));
    try std.testing.expectEqual(@as(usize, 70_001), counter.visits);
}

test "allocator-aware equality paths propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}
