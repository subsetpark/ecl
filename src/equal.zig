//! Iterative, representation-independent structural equality and hashing.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const poll = @import("poll.zig");

pub const Value = value.Value;
pub const DictHandle = value.DictHandle;

const Pair = struct { a: Value, b: Value };
const DictSearch = struct {
    a: *DictHandle,
    b: *DictHandle,
    entry: usize,
    candidate: usize,
};

const Action = union(enum) {
    compare: Pair,
    list_continue: struct {
        a: Value,
        b: Value,
        next: usize,
        len: usize,
    },
    dict_search: DictSearch,
    dict_after_key: struct {
        a: *DictHandle,
        b: *DictHandle,
        entry: usize,
        candidate: usize,
    },
    dict_after_value: struct {
        a: *DictHandle,
        b: *DictHandle,
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
    var cursor = try MatchCursor.init(allocator, a, b);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(1024)) {
        .pending => {},
        .complete => |complete| return complete,
    };
}

pub const MatchProgress = union(enum) { pending, complete: bool };

/// Owned structural-comparison state. `advance` performs at most `budget`
/// worklist transitions, including nested dictionary-key hashing.
pub const MatchCursor = struct {
    allocator: std.mem.Allocator,
    actions: poll.ChunkStack(Action),
    last: bool = false,
    hashing: ?Hashing = null,

    const Hashing = struct {
        search: DictSearch,
        side: enum { left, right },
        left_hash: u64 = 0,
        cursor: HashCursor,
    };

    pub fn init(allocator: std.mem.Allocator, a: Value, b: Value) error{OutOfMemory}!MatchCursor {
        var actions = poll.ChunkStack(Action).init(allocator);
        errdefer actions.deinit();
        try actions.push(.{ .compare = .{ .a = a, .b = b } });
        return .{ .allocator = allocator, .actions = actions };
    }

    pub fn deinit(self: *MatchCursor) void {
        if (self.hashing) |*hashing| hashing.cursor.deinit();
        self.actions.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *MatchCursor, budget: usize) error{OutOfMemory}!MatchProgress {
        std.debug.assert(budget != 0);
        for (0..budget) |_| {
            if (try self.step()) |result| return .{ .complete = result };
        }
        return .pending;
    }

    /// One bounded transition; a non-null result means the cursor is done.
    fn step(self: *MatchCursor) error{OutOfMemory}!?bool {
        if (self.hashing) |*hashing| {
            const maybe_hash = try hashing.cursor.step();
            const computed_hash = maybe_hash orelse return null;
            hashing.cursor.deinit();
            switch (hashing.side) {
                .left => {
                    hashing.left_hash = computed_hash;
                    hashing.side = .right;
                    hashing.cursor = try HashCursor.init(
                        self.allocator,
                        dictItem(hashing.search.b, true, hashing.search.candidate),
                    );
                },
                .right => {
                    const search = hashing.search;
                    const hashes_match = hashing.left_hash == computed_hash;
                    self.hashing = null;
                    if (hashes_match) {
                        try self.actions.push(.{ .dict_after_key = .{
                            .a = search.a,
                            .b = search.b,
                            .entry = search.entry,
                            .candidate = search.candidate,
                        } });
                        try self.actions.push(.{ .compare = .{
                            .a = dictItem(search.a, true, search.entry),
                            .b = dictItem(search.b, true, search.candidate),
                        } });
                    } else {
                        try self.actions.push(.{ .dict_search = .{
                            .a = search.a,
                            .b = search.b,
                            .entry = search.entry,
                            .candidate = search.candidate + 1,
                        } });
                    }
                },
            }
            return null;
        }
        const action = self.actions.pop() orelse return self.last;
        switch (action) {
            .compare => |pair| {
                if (numericPair(pair.a, pair.b)) {
                    self.last = numberEqual(pair.a, pair.b);
                    return null;
                }
                if (pair.a.tag() != pair.b.tag()) {
                    self.last = false;
                    return null;
                }
                switch (pair.a) {
                    .int, .float => unreachable,
                    .char => |codepoint| self.last = codepoint == pair.b.char,
                    .symbol => |id| self.last = id == pair.b.symbol,
                    .word => |id| self.last = id == pair.b.word,
                    .task => |header| self.last = header == pair.b.task,
                    .list => |a_header| {
                        const b_header = pair.b.list;
                        if (a_header == b_header) {
                            self.last = true;
                            return null;
                        }
                        const a_len: usize = @intCast(a_header.length());
                        const b_len: usize = @intCast(b_header.length());
                        if (a_len != b_len) {
                            self.last = false;
                        } else if (a_len == 0) {
                            self.last = true;
                        } else {
                            try self.actions.push(.{ .list_continue = .{
                                .a = pair.a,
                                .b = pair.b,
                                .next = 1,
                                .len = a_len,
                            } });
                            try self.actions.push(.{ .compare = .{
                                .a = list.atUnchecked(pair.a, 0),
                                .b = list.atUnchecked(pair.b, 0),
                            } });
                        }
                    },
                    .dict => |a_header| {
                        const b_header = pair.b.dict;
                        if (a_header == b_header) {
                            self.last = true;
                        } else if (a_header.length() != b_header.length()) {
                            self.last = false;
                        } else if (a_header.length() == 0) {
                            self.last = true;
                        } else {
                            try self.actions.push(.{ .dict_search = .{
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
                if (!self.last) return null;
                if (continuation.next == continuation.len) {
                    self.last = true;
                    return null;
                }
                try self.actions.push(.{ .list_continue = .{
                    .a = continuation.a,
                    .b = continuation.b,
                    .next = continuation.next + 1,
                    .len = continuation.len,
                } });
                try self.actions.push(.{ .compare = .{
                    .a = list.atUnchecked(continuation.a, continuation.next),
                    .b = list.atUnchecked(continuation.b, continuation.next),
                } });
            },
            .dict_search => |search| {
                const b_len: usize = @intCast(search.b.length());
                if (search.candidate == b_len) {
                    self.last = false;
                    return null;
                }
                self.hashing = .{
                    .search = search,
                    .side = .left,
                    .cursor = try HashCursor.init(
                        self.allocator,
                        dictItem(search.a, true, search.entry),
                    ),
                };
            },
            .dict_after_key => |continuation| {
                if (!self.last) {
                    try self.actions.push(.{ .dict_search = .{
                        .a = continuation.a,
                        .b = continuation.b,
                        .entry = continuation.entry,
                        .candidate = continuation.candidate + 1,
                    } });
                    return null;
                }
                try self.actions.push(.{ .dict_after_value = .{
                    .a = continuation.a,
                    .b = continuation.b,
                    .entry = continuation.entry,
                } });
                try self.actions.push(.{ .compare = .{
                    .a = dictItem(continuation.a, false, continuation.entry),
                    .b = dictItem(continuation.b, false, continuation.candidate),
                } });
            },
            .dict_after_value => |continuation| {
                if (!self.last) return null;
                const next = continuation.entry + 1;
                if (next == continuation.a.length()) {
                    self.last = true;
                } else {
                    try self.actions.push(.{ .dict_search = .{
                        .a = continuation.a,
                        .b = continuation.b,
                        .entry = next,
                        .candidate = 0,
                    } });
                }
            },
        }
        return if (self.hashing == null and self.actions.isEmpty()) self.last else null;
    }
};

/// Exact scalar ordering for the provisional M3 arithmetic seam. Mixed
/// int/float comparisons never round the integer through f64 first.
pub fn compareScalars(a: Value, b: Value) error{NotComparable}!std.math.Order {
    return switch (a) {
        .int => |a_int| switch (b) {
            .int => |b_int| orderInt(a_int, b_int),
            .float => |b_float| intFloatOrder(a_int, b_float) orelse
                error.NotComparable,
            .char, .symbol, .word, .list, .dict, .task => error.NotComparable,
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
            .char, .symbol, .word, .list, .dict, .task => error.NotComparable,
        },
        .char => |a_char| switch (b) {
            .char => |b_char| orderInt(a_char, b_char),
            .int, .float, .symbol, .word, .list, .dict, .task => error.NotComparable,
        },
        .symbol, .word, .list, .dict, .task => error.NotComparable,
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
        header: *DictHandle,
        index: usize,
        state: u64,
    },
    dict_after_value: struct {
        header: *DictHandle,
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
    var cursor = try HashCursor.init(allocator, item);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(1024)) {
        .pending => {},
        .complete => |complete| return complete,
    };
}

pub const HashProgress = union(enum) { pending, complete: u64 };

/// Owned structural-hash state. Every transition is bounded and the cursor
/// never relocates its accumulated continuation stack.
pub const HashCursor = struct {
    actions: poll.ChunkStack(HashAction),
    last: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, item: Value) error{OutOfMemory}!HashCursor {
        var actions = poll.ChunkStack(HashAction).init(allocator);
        errdefer actions.deinit();
        try actions.push(.{ .visit = item });
        return .{ .actions = actions };
    }

    pub fn deinit(self: *HashCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *HashCursor, budget: usize) error{OutOfMemory}!HashProgress {
        std.debug.assert(budget != 0);
        for (0..budget) |_| {
            if (try self.step()) |result| return .{ .complete = result };
        }
        return .pending;
    }

    fn step(self: *HashCursor) error{OutOfMemory}!?u64 {
        const action = self.actions.pop() orelse return self.last;
        switch (action) {
            .visit => |current| {
                if (scalarHash(current)) |result| {
                    self.last = result;
                    return null;
                }
                switch (current) {
                    .list => |header| {
                        const count: usize = @intCast(header.length());
                        const state = mix(0x4c49_5354, count);
                        if (count == 0) {
                            self.last = state;
                        } else {
                            try self.actions.push(.{ .list_after = .{
                                .collection = current,
                                .index = 0,
                                .state = state,
                            } });
                            try self.actions.push(.{ .visit = list.atUnchecked(current, 0) });
                        }
                    },
                    .dict => |header| {
                        const count: usize = @intCast(header.length());
                        const state = mix(0x4449_4354, count);
                        if (count == 0) {
                            self.last = state;
                        } else {
                            try self.actions.push(.{ .dict_after_key = .{
                                .header = header,
                                .index = 0,
                                .state = state,
                            } });
                            try self.actions.push(.{ .visit = dictItem(header, true, 0) });
                        }
                    },
                    .int, .float, .char, .symbol, .word, .task => unreachable,
                }
            },
            .list_after => |continuation| {
                const state = mix(continuation.state, self.last);
                const next = continuation.index + 1;
                if (next == @as(usize, @intCast(continuation.collection.list.length()))) {
                    self.last = state;
                } else {
                    try self.actions.push(.{ .list_after = .{
                        .collection = continuation.collection,
                        .index = next,
                        .state = state,
                    } });
                    try self.actions.push(.{
                        .visit = list.atUnchecked(continuation.collection, next),
                    });
                }
            },
            .dict_after_key => |continuation| {
                const key_hash = self.last;
                try self.actions.push(.{ .dict_after_value = .{
                    .header = continuation.header,
                    .index = continuation.index,
                    .state = continuation.state,
                    .key_hash = key_hash,
                } });
                try self.actions.push(.{
                    .visit = dictItem(continuation.header, false, continuation.index),
                });
            },
            .dict_after_value => |continuation| {
                const entry_hash = mix(continuation.key_hash ^ 0x9e37_79b9, self.last);
                const state = continuation.state +% avalanche(entry_hash);
                const next = continuation.index + 1;
                if (next == @as(usize, @intCast(continuation.header.length()))) {
                    self.last = state;
                } else {
                    try self.actions.push(.{ .dict_after_key = .{
                        .header = continuation.header,
                        .index = next,
                        .state = state,
                    } });
                    try self.actions.push(.{ .visit = dictItem(continuation.header, true, next) });
                }
            },
        }
        return if (self.actions.isEmpty()) self.last else null;
    }
};

fn numericPair(a: Value, b: Value) bool {
    const a_numeric = switch (a) {
        .int, .float => true,
        .char, .symbol, .word, .list, .dict, .task => false,
    };
    const b_numeric = switch (b) {
        .int, .float => true,
        .char, .symbol, .word, .list, .dict, .task => false,
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
            .char, .symbol, .word, .list, .dict, .task => unreachable,
        },
        .float => |a_float| switch (b) {
            .int => |b_int| intFloatEqual(b_int, a_float),
            .float => |b_float| a_float == b_float,
            .char, .symbol, .word, .list, .dict, .task => unreachable,
        },
        .char, .symbol, .word, .list, .dict, .task => unreachable,
    };
}

fn intFloatEqual(integer: i64, floating: f64) bool {
    const i64_min_f64: f64 = -9_223_372_036_854_775_808.0;
    const i64_max_exclusive_f64: f64 = 9_223_372_036_854_775_808.0;
    if (!std.math.isFinite(floating) or @trunc(floating) != floating) return false;
    if (floating < i64_min_f64 or floating >= i64_max_exclusive_f64) return false;
    return @as(i64, @intFromFloat(floating)) == integer;
}

fn dictItem(header: *DictHandle, keys: bool, index: usize) Value {
    const payload = heap.dictStorageConst(header).payload().*;
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
        .task => |header| mix(0x5441_534b, @intFromPtr(header)),
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
    defer heap.testing.releaseValue(allocator, left);
    const right = try list.fromValuesGeneric(allocator, &.{
        .{ .float = 1.0 },
        .{ .int = 2 },
        .{ .word = 3 },
    });
    defer heap.testing.releaseValue(allocator, right);
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
    defer heap.testing.releaseValue(allocator, leaf);
    const spine = try list.fromValuesGeneric(allocator, &chars);
    defer heap.testing.releaseValue(allocator, spine);
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
        if (left.heapHeader()) |_| heap.testing.releaseValue(allocator, left);
        left = next_left;
        const next_right = try list.fromValuesGeneric(allocator, &.{right});
        if (right.heapHeader()) |_| heap.testing.releaseValue(allocator, right);
        right = next_right;
    }
    defer heap.testing.releaseValue(allocator, left);
    defer heap.testing.releaseValue(allocator, right);
    try std.testing.expect(match(left, right));
    try std.testing.expectEqual(hash(left), hash(right));
}

test "hash and equality cursors expose bounded nested transitions" {
    const allocator = std.testing.allocator;
    const numbers = try allocator.alloc(i64, 70_000);
    defer allocator.free(numbers);
    for (numbers, 0..) |*number, index| number.* = @intCast(index);
    const left = try list.fromI64Slice(allocator, numbers);
    defer heap.testing.releaseValue(allocator, left);
    const right = try list.fromI64Slice(allocator, numbers);
    defer heap.testing.releaseValue(allocator, right);

    var hash_cursor = try HashCursor.init(allocator, left);
    defer hash_cursor.deinit();
    var hash_steps: usize = 0;
    while (true) {
        hash_steps += 1;
        switch (try hash_cursor.advance(1)) {
            .pending => {},
            .complete => break,
        }
    }
    try std.testing.expectEqual(@as(usize, 140_001), hash_steps);

    var match_cursor = try MatchCursor.init(allocator, left, right);
    defer match_cursor.deinit();
    var match_steps: usize = 0;
    const matches = while (true) {
        match_steps += 1;
        switch (try match_cursor.advance(1)) {
            .pending => {},
            .complete => |complete| break complete,
        }
    };
    try std.testing.expect(matches);
    try std.testing.expect(match_steps > numbers.len);
}

test "allocator-aware equality paths propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}
