//! Insertion-ordered K-style dictionaries with order-independent identity.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");
const poll = @import("poll.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const DictHandle = value.DictHandle;
pub const Pair = [2]Value;

pub const Error = error{ OutOfMemory, DuplicateKey, NotADict };

const index_threshold = 16;
const empty_index: u32 = 0;

pub const MaterializeProgress = union(enum) {
    pending,
    complete: Value,
    duplicate_key,
};

/// The single dictionary construction traversal. Duplicate detection and the
/// retained lookup index share `index_threshold`, so execution mode cannot
/// change either policy.
pub const Materializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    const State = union(enum) {
        table_init: usize,
        hash: struct {
            index: usize = 0,
            cursor: ?equal.HashCursor = null,
        },
        duplicate_linear: struct {
            index: usize,
            candidate: usize = 0,
            cursor: ?equal.MatchCursor = null,
        },
        duplicate_index: struct {
            index: usize,
            slot: usize,
            cursor: ?equal.MatchCursor = null,
        },
        keys: list.ValueMaterializer,
        vals: struct { keys: Value, materializer: list.ValueMaterializer },
        hashes: struct { keys: Value, vals: Value, materializer: list.I64Materializer },
        finish: struct { keys: Value, vals: Value, hashes: Value },
        complete,
    };

    allocator: std.mem.Allocator,
    source_keys: []const Value,
    source_vals: []const Value,
    check_duplicates: bool,
    keys: []Value,
    vals: []Value,
    hashes: []i64,
    table: ?[]u32,
    state: State,

    pub fn init(
        allocator: std.mem.Allocator,
        pairs: []const Pair,
        check_duplicates: bool,
    ) error{OutOfMemory}!Materializer {
        if (pairs.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        const keys = try allocator.alloc(Value, pairs.len);
        errdefer allocator.free(keys);
        const vals = try allocator.alloc(Value, pairs.len);
        errdefer allocator.free(vals);
        const hashes = try allocator.alloc(i64, pairs.len);
        errdefer allocator.free(hashes);
        const table = try allocateIndex(allocator, pairs.len);
        for (pairs, 0..) |pair, index| {
            keys[index] = pair[0];
            vals[index] = pair[1];
        }
        return initOwned(allocator, keys, vals, hashes, table, check_duplicates);
    }

    pub fn initSlices(
        allocator: std.mem.Allocator,
        source_keys: []const Value,
        source_vals: []const Value,
        check_duplicates: bool,
    ) error{OutOfMemory}!Materializer {
        if (source_keys.len != source_vals.len or source_keys.len >= std.math.maxInt(u32))
            return error.OutOfMemory;
        const keys = try allocator.alloc(Value, source_keys.len);
        errdefer allocator.free(keys);
        const vals = try allocator.alloc(Value, source_vals.len);
        errdefer allocator.free(vals);
        const hashes = try allocator.alloc(i64, source_keys.len);
        errdefer allocator.free(hashes);
        const table = try allocateIndex(allocator, source_keys.len);
        @memcpy(keys, source_keys);
        @memcpy(vals, source_vals);
        return initOwned(allocator, keys, vals, hashes, table, check_duplicates);
    }

    fn initOwned(
        allocator: std.mem.Allocator,
        keys: []Value,
        vals: []Value,
        hashes: []i64,
        table: ?[]u32,
        check_duplicates: bool,
    ) Materializer {
        return .{
            .allocator = allocator,
            .source_keys = keys,
            .source_vals = vals,
            .check_duplicates = check_duplicates,
            .keys = keys,
            .vals = vals,
            .hashes = hashes,
            .table = table,
            .state = if (table != null) .{ .table_init = 0 } else .{ .hash = .{} },
        };
    }

    pub fn deinit(self: *Materializer) void {
        std.debug.assert(self.state == .complete);
        self.freeBuffers();
    }
    pub fn retire(self: *Materializer, releases: *heap.ReleaseDomain) void {
        switch (self.state) {
            .table_init => {},
            .hash => |*state| if (state.cursor) |*cursor| cursor.deinit(),
            .duplicate_linear => |*state| if (state.cursor) |*cursor| cursor.deinit(),
            .duplicate_index => |*state| if (state.cursor) |*cursor| cursor.deinit(),
            .keys => |*materializer| materializer.retire(releases),
            .vals => |*state| {
                state.materializer.retire(releases);
                releases.releaseValue(state.keys);
            },
            .hashes => |*state| {
                state.materializer.retire(releases);
                releases.releaseValue(state.keys);
                releases.releaseValue(state.vals);
            },
            .finish => |state| {
                releases.releaseValue(state.keys);
                releases.releaseValue(state.vals);
                releases.releaseValue(state.hashes);
            },
            .complete => {},
        }
        self.freeBuffers();
    }
    fn freeBuffers(self: *Materializer) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.vals);
        self.allocator.free(self.hashes);
        if (self.table) |table| self.allocator.free(table);
    }

    pub fn advance(self: *Materializer, budget: usize) error{OutOfMemory}!MaterializeProgress {
        std.debug.assert(budget != 0 and self.state != .complete);
        while (true) switch (self.state) {
            .table_init => |*index| {
                const table = self.table.?;
                const end = @min(index.* + budget, table.len);
                @memset(table[index.*..end], empty_index);
                index.* = end;
                if (index.* != table.len) return .pending;
                self.state = .{ .hash = .{} };
                return .pending;
            },
            .hash => |*state| {
                if (state.index == self.source_keys.len) {
                    self.state = .{ .keys = .init(self.allocator, self.keys) };
                    continue;
                }
                if (state.cursor == null)
                    state.cursor = try .init(self.allocator, self.source_keys[state.index]);
                switch (try state.cursor.?.advance(budget)) {
                    .pending => return .pending,
                    .complete => |computed| {
                        state.cursor.?.deinit();
                        state.cursor = null;
                        self.hashes[state.index] = @bitCast(computed);
                        if (self.table) |table| {
                            self.state = .{ .duplicate_index = .{
                                .index = state.index,
                                .slot = @intCast(computed & (table.len - 1)),
                            } };
                        } else if (self.check_duplicates and state.index != 0) {
                            self.state = .{ .duplicate_linear = .{ .index = state.index } };
                        } else {
                            state.index += 1;
                        }
                        return .pending;
                    },
                }
            },
            .duplicate_linear => |*state| {
                var remaining = budget;
                while (remaining != 0 and state.candidate != state.index) {
                    if (self.hashes[state.candidate] != self.hashes[state.index]) {
                        state.candidate += 1;
                        remaining -= 1;
                        continue;
                    }
                    if (state.cursor == null) state.cursor = try .init(
                        self.allocator,
                        self.keys[state.candidate],
                        self.keys[state.index],
                    );
                    switch (try state.cursor.?.advance(remaining)) {
                        .pending => return .pending,
                        .complete => |matches| {
                            state.cursor.?.deinit();
                            state.cursor = null;
                            if (matches) return .duplicate_key;
                            state.candidate += 1;
                            return .pending;
                        },
                    }
                }
                if (state.candidate == state.index) {
                    self.state = .{ .hash = .{ .index = state.index + 1 } };
                }
                return .pending;
            },
            .duplicate_index => |*state| {
                var remaining = budget;
                const table = self.table.?;
                while (remaining != 0) {
                    const encoded = table[state.slot];
                    if (encoded == empty_index) {
                        table[state.slot] = @intCast(state.index + 1);
                        self.state = .{ .hash = .{ .index = state.index + 1 } };
                        return .pending;
                    }
                    const candidate = encoded - 1;
                    if (!self.check_duplicates or self.hashes[candidate] != self.hashes[state.index]) {
                        state.slot = (state.slot + 1) & (table.len - 1);
                        remaining -= 1;
                        continue;
                    }
                    if (state.cursor == null) state.cursor = try .init(
                        self.allocator,
                        self.keys[candidate],
                        self.keys[state.index],
                    );
                    switch (try state.cursor.?.advance(remaining)) {
                        .pending => return .pending,
                        .complete => |matches| {
                            state.cursor.?.deinit();
                            state.cursor = null;
                            if (matches) return .duplicate_key;
                            state.slot = (state.slot + 1) & (table.len - 1);
                            return .pending;
                        },
                    }
                }
                return .pending;
            },
            .keys => |*materializer| switch (try materializer.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.state = .{ .vals = .{
                        .keys = item,
                        .materializer = .init(self.allocator, self.vals),
                    } };
                    return .pending;
                },
            },
            .vals => |*state| switch (try state.materializer.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.state = .{ .hashes = .{
                        .keys = state.keys,
                        .vals = item,
                        .materializer = .init(self.allocator, self.hashes),
                    } };
                    return .pending;
                },
            },
            .hashes => |*state| switch (try state.materializer.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.state = .{ .finish = .{
                        .keys = state.keys,
                        .vals = state.vals,
                        .hashes = item,
                    } };
                    continue;
                },
            },
            .finish => |state| {
                var builder = try heap.DictBuilder.init(self.allocator, self.source_keys.len);
                const header = builder.finish(.{
                    .keys = state.keys.list,
                    .vals = state.vals.list,
                    .hashes = state.hashes.list,
                }, self.table);
                self.table = null;
                self.state = .complete;
                return .{ .complete = .{ .dict = header } };
            },
            .complete => unreachable,
        };
    }
};

fn allocateIndex(allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!?[]u32 {
    if (count < index_threshold) return null;
    var table_len: usize = 32;
    const minimum = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    while (table_len < minimum)
        table_len = std.math.mul(usize, table_len, 2) catch return error.OutOfMemory;
    return try allocator.alloc(u32, table_len);
}

pub const FindProgress = poll.Progress(?Value);

/// The single structural lookup traversal for indexed and small dictionaries.
pub const FindCursor = struct {
    allocator: std.mem.Allocator,
    header: *DictHandle,
    key: Value,
    key_hash: ?u64 = null,
    hash_cursor: ?equal.HashCursor = null,
    match_cursor: ?equal.MatchCursor = null,
    candidate: usize = 0,
    slot: ?usize = null,
    slots_checked: usize = 0,

    pub fn init(allocator: std.mem.Allocator, dictionary: Value, key: Value) error{NotADict}!FindCursor {
        return initHeader(allocator, try dictHeader(dictionary), key);
    }
    pub fn initHeader(allocator: std.mem.Allocator, header: *DictHandle, key: Value) FindCursor {
        return .{ .allocator = allocator, .header = header, .key = key };
    }
    pub fn deinit(self: *FindCursor) void {
        if (self.hash_cursor) |*cursor| cursor.deinit();
        if (self.match_cursor) |*cursor| cursor.deinit();
        self.* = undefined;
    }
    pub fn foundIndex(self: *const FindCursor) ?usize {
        return if (self.candidate < @as(usize, @intCast(self.header.length()))) self.candidate else null;
    }
    pub fn advance(self: *FindCursor, budget: usize) error{OutOfMemory}!FindProgress {
        std.debug.assert(budget != 0);
        if (self.key_hash == null) {
            if (equal.scalarHash(self.key)) |computed| {
                self.key_hash = computed;
                return .pending;
            }
            if (self.hash_cursor == null) self.hash_cursor = try .init(self.allocator, self.key);
            switch (try self.hash_cursor.?.advance(budget)) {
                .pending => return .pending,
                .complete => |computed| {
                    self.hash_cursor.?.deinit();
                    self.hash_cursor = null;
                    self.key_hash = computed;
                    return .pending;
                },
            }
        }
        const count: usize = @intCast(self.header.length());
        const table = heap.dictStorageConst(self.header).index();
        if (table == null) return self.advanceLinear(count, budget);
        if (self.slot == null) self.slot = @intCast(self.key_hash.? & (table.?.len - 1));
        var remaining = budget;
        while (remaining != 0 and self.slots_checked != table.?.len) {
            const encoded = table.?[self.slot.?];
            if (encoded == empty_index) return self.notFound(count);
            self.candidate = encoded - 1;
            if (hashAt(self.header, self.candidate) == self.key_hash.?) {
                if (try self.matchCandidate(remaining)) |matches| {
                    if (matches) return .{ .complete = valueAt(self.header, self.candidate) };
                    self.slot = (self.slot.? + 1) & (table.?.len - 1);
                    self.slots_checked += 1;
                    return .pending;
                } else return .pending;
            }
            self.slot = (self.slot.? + 1) & (table.?.len - 1);
            self.slots_checked += 1;
            remaining -= 1;
        }
        return if (self.slots_checked == table.?.len) self.notFound(count) else .pending;
    }
    fn advanceLinear(self: *FindCursor, count: usize, budget: usize) error{OutOfMemory}!FindProgress {
        var remaining = budget;
        while (remaining != 0 and self.candidate != count) {
            if (hashAt(self.header, self.candidate) == self.key_hash.?) {
                if (try self.matchCandidate(remaining)) |matches| {
                    if (matches) return .{ .complete = valueAt(self.header, self.candidate) };
                    self.candidate += 1;
                    return .pending;
                } else return .pending;
            }
            self.candidate += 1;
            remaining -= 1;
        }
        return if (self.candidate == count) .{ .complete = null } else .pending;
    }
    /// Null means a structural comparison consumed the remainder of this
    /// poll. A boolean is a completed scalar or structural comparison.
    fn matchCandidate(self: *FindCursor, budget: usize) error{OutOfMemory}!?bool {
        if (equal.matchWithoutStructure(keyAt(self.header, self.candidate), self.key)) |matches|
            return matches;
        if (self.match_cursor == null) self.match_cursor = try .init(
            self.allocator,
            keyAt(self.header, self.candidate),
            self.key,
        );
        return switch (try self.match_cursor.?.advance(budget)) {
            .pending => null,
            .complete => |matches| result: {
                self.match_cursor.?.deinit();
                self.match_cursor = null;
                break :result matches;
            },
        };
    }
    fn notFound(self: *FindCursor, count: usize) FindProgress {
        self.candidate = count;
        return .{ .complete = null };
    }
};

pub fn fromPairs(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    pairs: []const Pair,
) error{ OutOfMemory, DuplicateKey }!Value {
    var materializer = try Materializer.init(allocator, pairs, true);
    var completed = false;
    defer if (!completed) materializer.retire(releases);
    while (true) switch (try materializer.advance(std.math.maxInt(usize))) {
        .pending => {},
        .duplicate_key => return error.DuplicateKey,
        .complete => |dictionary| {
            materializer.deinit();
            completed = true;
            return dictionary;
        },
    };
}

/// `fromPairs` for call sites whose keys are distinct by construction.
pub fn fromUniquePairs(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    pairs: []const Pair,
) error{OutOfMemory}!Value {
    var materializer = try Materializer.init(allocator, pairs, false);
    var completed = false;
    defer if (!completed) materializer.retire(releases);
    while (true) switch (try materializer.advance(std.math.maxInt(usize))) {
        .pending => {},
        .duplicate_key => unreachable,
        .complete => |dictionary| {
            materializer.deinit();
            completed = true;
            return dictionary;
        },
    };
}

/// Returns a borrowed value. The dict continues to own heap children.
///
/// This convenience wrapper is for tests and small tools that do not own an
/// allocator. Runtime code must use `getWithAllocator` so OOM remains an
/// ordinary error.
pub fn get(dictionary: Value, key: Value) error{NotADict}!?Value {
    const header = try dictHeader(dictionary);
    const found = findWithAllocator(std.heap.smp_allocator, header, key) catch
        @panic("dictionary lookup out of memory") orelse return null;
    return valueAt(header, found);
}

/// Allocator-aware lookup for runtime code. The returned value is borrowed;
/// the dictionary continues to own heap children.
pub fn getWithAllocator(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
) error{ OutOfMemory, NotADict }!?Value {
    const header = try dictHeader(dictionary);
    const found = try findWithAllocator(allocator, header, key) orelse return null;
    return valueAt(header, found);
}

/// `getWithAllocator` for call sites that have already proved dict-ness.
/// The returned value is borrowed.
pub fn symbolField(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: u32,
) error{OutOfMemory}!?Value {
    return getWithAllocator(allocator, dictionary, .{ .symbol = key }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotADict => unreachable,
    };
}

pub fn keysOf(header: *DictHandle) Value {
    return .{ .list = heap.dictStorageConst(header).payload().keys };
}

pub fn valsOf(header: *DictHandle) Value {
    return .{ .list = heap.dictStorageConst(header).payload().vals };
}

pub fn keyAt(header: *DictHandle, index: usize) Value {
    return list.atUnchecked(.{ .list = heap.dictStorageConst(header).payload().keys }, index);
}

pub fn valueAt(header: *DictHandle, index: usize) Value {
    return list.atUnchecked(.{ .list = heap.dictStorageConst(header).payload().vals }, index);
}

fn dictHeader(dictionary: Value) error{NotADict}!*DictHandle {
    return switch (dictionary) {
        .dict => |header| header,
        .int, .float, .char, .symbol, .word, .list, .task, .module, .unit_plan => error.NotADict,
    };
}

pub fn hashAt(header: *DictHandle, index: usize) u64 {
    const hashes = heap.dictStorageConst(header).payload().hashes;
    return @bitCast(heap.i64s(hashes)[index]);
}

fn findWithAllocator(
    allocator: std.mem.Allocator,
    header: *DictHandle,
    key: Value,
) error{OutOfMemory}!?usize {
    var cursor = FindCursor.initHeader(allocator, header, key);
    defer cursor.deinit();
    _ = try poll.driveFallible(?Value, &cursor, .{std.math.maxInt(usize)});
    return cursor.foundIndex();
}

fn constructionFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const releases = cleanup.domain();
    const dictionary = try fromPairs(allocator, releases, &.{
        .{ .{ .int = 1 }, .{ .word = .{ .name = 10 } } },
        .{ .{ .float = 2.5 }, .{ .word = .{ .name = 20 } } },
    });
    cleanup.releaseValue(dictionary);

    var pairs: [index_threshold]Pair = undefined;
    for (&pairs, 0..) |*pair, index| pair.* = .{ .{ .int = @intCast(index) }, .{ .int = @intCast(index * 2) } };
    const indexed = try fromPairs(allocator, releases, &pairs);
    cleanup.releaseValue(indexed);
}

fn lookupFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const releases = cleanup.domain();
    const stored_key = try list.fromValuesGeneric(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer cleanup.releaseValue(stored_key);
    const query_key = try list.fromValuesGeneric(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer cleanup.releaseValue(query_key);
    const dictionary = try fromPairs(allocator, releases, &.{.{ stored_key, .{ .word = .{ .name = 10 } } }});
    defer cleanup.releaseValue(dictionary);
    _ = try getWithAllocator(allocator, dictionary, query_key);
}

test "dict allocation paths are exhaustive and leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        constructionFailureProbe,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        lookupFailureProbe,
        .{},
    );
}

test "blocking and resumable dictionary APIs share construction and lookup" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const releases = cleanup.domain();

    var pairs: [20]Pair = undefined;
    for (&pairs, 0..) |*pair, index| pair.* = .{
        .{ .int = @intCast(index) },
        .{ .int = @intCast(index * 10) },
    };
    var materializer = try Materializer.init(allocator, &pairs, true);
    var pending: usize = 0;
    const dictionary = while (true) switch (try materializer.advance(1)) {
        .pending => pending += 1,
        .duplicate_key => return error.UnexpectedDuplicateKey,
        .complete => |result| break result,
    };
    materializer.deinit();
    defer cleanup.releaseValue(dictionary);
    try std.testing.expect(pending > pairs.len);

    for (pairs, 0..) |pair, index| {
        try std.testing.expectEqual(pair[0], keyAt(dictionary.dict, index));
        try std.testing.expectEqual(pair[1], (try getWithAllocator(allocator, dictionary, pair[0])).?);
    }
    try std.testing.expect((try getWithAllocator(allocator, dictionary, .{ .int = 99 })) == null);

    const duplicates = [_]Pair{
        .{ .{ .int = 1 }, .{ .int = 10 } },
        .{ .{ .int = 1 }, .{ .int = 20 } },
    };
    try std.testing.expectError(error.DuplicateKey, fromPairs(allocator, releases, &duplicates));
    var duplicate_cursor = try Materializer.init(allocator, &duplicates, true);
    defer duplicate_cursor.retire(releases);
    while (true) switch (try duplicate_cursor.advance(1)) {
        .pending => {},
        .duplicate_key => break,
        .complete => return error.ExpectedDuplicateKey,
    };
}
