//! Insertion-ordered K-style dictionaries with order-independent identity.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const Pair = [2]Value;

pub const Error = error{ OutOfMemory, DuplicateKey, NotADict };

const index_threshold = 16;
const empty_index: u32 = 0;

pub fn fromPairs(
    allocator: std.mem.Allocator,
    pairs: []const Pair,
) error{ OutOfMemory, DuplicateKey }!Value {
    if (pairs.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const keys = try allocator.alloc(Value, pairs.len);
    defer allocator.free(keys);
    const vals = try allocator.alloc(Value, pairs.len);
    defer allocator.free(vals);
    const hashes = try allocator.alloc(i64, pairs.len);
    defer allocator.free(hashes);

    for (pairs, 0..) |pair, index| {
        const key_hash = try equal.hashWithAllocator(allocator, pair[0]);
        for (keys[0..index], 0..) |prior, prior_index| {
            if (@as(u64, @bitCast(hashes[prior_index])) != key_hash) continue;
            if (try equal.matchWithAllocator(allocator, prior, pair[0])) return error.DuplicateKey;
        }
        keys[index] = pair[0];
        vals[index] = pair[1];
        hashes[index] = @bitCast(key_hash);
    }

    const keys_value = try list.fromValues(allocator, keys);
    var keys_owned = true;
    defer if (keys_owned) heap.releaseValue(allocator, keys_value);
    const vals_value = try list.fromValues(allocator, vals);
    var vals_owned = true;
    defer if (vals_owned) heap.releaseValue(allocator, vals_value);
    const hashes_value = try list.fromI64Slice(allocator, hashes);
    var hashes_owned = true;
    defer if (hashes_owned) heap.releaseValue(allocator, hashes_value);

    const index = if (pairs.len >= index_threshold)
        try buildIndex(allocator, hashes)
    else
        null;
    var index_owned = index != null;
    defer if (index_owned) allocator.free(index.?);

    const header = try heap.allocHeader(allocator, .dict, pairs.len, pairs.len);
    const storage = heap.dictStorage(header);
    storage.* = .{
        .payload = .{
            .keys = keys_value.list,
            .vals = vals_value.list,
            .hashes = hashes_value.list,
        },
        .initialized = true,
        .index = if (index) |table| table.ptr else null,
        .index_len = if (index) |table| table.len else 0,
    };
    keys_owned = false;
    vals_owned = false;
    hashes_owned = false;
    index_owned = false;
    return .{ .dict = header };
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

/// Functional-update ownership contract: inputs remain owned by their callers.
/// If the result has the same header as `dictionary`, ownership is unchanged;
/// if it has a different header, the caller owns that additional result.
pub fn put(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
    new_value: Value,
) error{ OutOfMemory, NotADict }!Value {
    const header = try dictHeader(dictionary);
    const found = try findWithAllocator(allocator, header, key);
    const old_len: usize = @intCast(header.len);
    const new_len = old_len + @intFromBool(found == null);
    const pairs = try allocator.alloc(Pair, new_len);
    defer allocator.free(pairs);
    for (0..old_len) |index| pairs[index] = .{ keyAt(header, index), valueAt(header, index) };
    if (found) |index| {
        pairs[index][1] = new_value;
    } else {
        pairs[old_len] = .{ key, new_value };
    }
    const replacement = fromPairs(allocator, pairs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateKey => unreachable,
    };
    return installReplacement(allocator, dictionary, replacement);
}

/// Uses the same functional-update ownership contract as `put`.
pub fn del(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
) error{ OutOfMemory, NotADict }!Value {
    const header = try dictHeader(dictionary);
    const found = try findWithAllocator(allocator, header, key) orelse return dictionary;
    const old_len: usize = @intCast(header.len);
    const pairs = try allocator.alloc(Pair, old_len - 1);
    defer allocator.free(pairs);
    var dest: usize = 0;
    for (0..old_len) |index| {
        if (index == found) continue;
        pairs[dest] = .{ keyAt(header, index), valueAt(header, index) };
        dest += 1;
    }
    const replacement = fromPairs(allocator, pairs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateKey => unreachable,
    };
    return installReplacement(allocator, dictionary, replacement);
}

/// Uses `put`'s ownership contract for `left`; `right` is always unchanged.
pub fn merge(
    allocator: std.mem.Allocator,
    left: Value,
    right: Value,
) error{ OutOfMemory, NotADict }!Value {
    const left_header = try dictHeader(left);
    const right_header = try dictHeader(right);
    const left_len: usize = @intCast(left_header.len);
    const right_len: usize = @intCast(right_header.len);
    const pairs = try allocator.alloc(Pair, left_len + right_len);
    defer allocator.free(pairs);
    var count = left_len;
    for (0..left_len) |index| pairs[index] = .{
        keyAt(left_header, index),
        valueAt(left_header, index),
    };
    for (0..right_len) |right_index| {
        const right_key = keyAt(right_header, right_index);
        var found: ?usize = null;
        for (pairs[0..count], 0..) |pair, index| {
            if (try equal.matchWithAllocator(allocator, pair[0], right_key)) {
                found = index;
                break;
            }
        }
        if (found) |index| {
            pairs[index][1] = valueAt(right_header, right_index);
        } else {
            pairs[count] = .{ right_key, valueAt(right_header, right_index) };
            count += 1;
        }
    }
    const replacement = fromPairs(allocator, pairs[0..count]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateKey => unreachable,
    };
    return installReplacement(allocator, left, replacement);
}

pub fn keysOf(dictionary: Value) error{NotADict}!Value {
    const header = try dictHeader(dictionary);
    return .{ .list = heap.dictStorageConst(header).payload.?.keys };
}

pub fn valsOf(dictionary: Value) error{NotADict}!Value {
    const header = try dictHeader(dictionary);
    return .{ .list = heap.dictStorageConst(header).payload.?.vals };
}

pub fn keyAt(header: *Header, index: usize) Value {
    return list.atUnchecked(.{ .list = heap.dictStorageConst(header).payload.?.keys }, index);
}

pub fn valueAt(header: *Header, index: usize) Value {
    return list.atUnchecked(.{ .list = heap.dictStorageConst(header).payload.?.vals }, index);
}

fn dictHeader(dictionary: Value) error{NotADict}!*Header {
    return switch (dictionary) {
        .dict => |header| if (header.kind() == .dict) header else error.NotADict,
        .int, .float, .char, .symbol, .word, .list => error.NotADict,
    };
}

fn cachedHash(header: *Header, index: usize) u64 {
    const hashes = heap.dictStorageConst(header).payload.?.hashes.?;
    return @bitCast(heap.itemsConst(i64, hashes)[index]);
}

fn findWithAllocator(
    allocator: std.mem.Allocator,
    header: *Header,
    key: Value,
) error{OutOfMemory}!?usize {
    const count: usize = @intCast(header.len);
    const key_hash = try equal.hashWithAllocator(allocator, key);
    const storage = heap.dictStorageConst(header);
    if (count < index_threshold or storage.index == null) {
        for (0..count) |index| {
            if (cachedHash(header, index) != key_hash) continue;
            if (try equal.matchWithAllocator(allocator, keyAt(header, index), key)) return index;
        }
        return null;
    }

    const table = storage.index.?[0..storage.index_len];
    var slot: usize = @intCast(key_hash & (table.len - 1));
    for (0..table.len) |_| {
        const encoded = table[slot];
        if (encoded == empty_index) return null;
        const index = encoded - 1;
        if (cachedHash(header, index) == key_hash and
            try equal.matchWithAllocator(allocator, keyAt(header, index), key)) return index;
        slot = (slot + 1) & (table.len - 1);
    }
    return null;
}

fn buildIndex(
    allocator: std.mem.Allocator,
    hashes: []const i64,
) error{OutOfMemory}![]u32 {
    var table_len: usize = 32;
    const minimum = std.math.mul(usize, hashes.len, 2) catch return error.OutOfMemory;
    while (table_len < minimum) {
        table_len = std.math.mul(usize, table_len, 2) catch return error.OutOfMemory;
    }
    const table = try allocator.alloc(u32, table_len);
    @memset(table, empty_index);
    for (hashes, 0..) |signed_hash, index| {
        const key_hash: u64 = @bitCast(signed_hash);
        var slot: usize = @intCast(key_hash & (table.len - 1));
        while (table[slot] != empty_index) slot = (slot + 1) & (table.len - 1);
        table[slot] = @intCast(index + 1);
    }
    return table;
}

/// Consumes the owned `replacement`. A unique `original` adopts it and keeps
/// its identity; a shared `original` is untouched and the replacement's owned
/// reference is returned to the caller.
fn installReplacement(
    allocator: std.mem.Allocator,
    original: Value,
    replacement: Value,
) Value {
    if (!heap.isUnique(original.dict)) return replacement;
    heap.adoptRepresentation(allocator, original.dict, replacement.dict);
    return original;
}

fn constructionFailureProbe(allocator: std.mem.Allocator) !void {
    const dictionary = try fromPairs(allocator, &.{
        .{ .{ .int = 1 }, .{ .word = 10 } },
        .{ .{ .float = 2.5 }, .{ .word = 20 } },
    });
    heap.releaseValue(allocator, dictionary);
}

fn putFailureProbe(allocator: std.mem.Allocator) !void {
    var dictionary = try fromPairs(allocator, &.{.{ .{ .int = 1 }, .{ .word = 10 } }});
    defer heap.releaseValue(allocator, dictionary);
    _ = try getWithAllocator(allocator, dictionary, .{ .int = 1 });
    dictionary = try put(allocator, dictionary, .{ .int = 2 }, .{ .word = 20 });
    dictionary = try del(allocator, dictionary, .{ .int = 1 });
    const right = try fromPairs(allocator, &.{.{ .{ .int = 2 }, .{ .word = 30 } }});
    defer heap.releaseValue(allocator, right);
    dictionary = try merge(allocator, dictionary, right);
}

test "dicts preserve insertion order and reject duplicate keys" {
    const allocator = std.testing.allocator;
    const dictionary = try fromPairs(allocator, &.{
        .{ .{ .int = 3 }, .{ .word = 30 } },
        .{ .{ .int = 1 }, .{ .word = 10 } },
        .{ .{ .int = 2 }, .{ .word = 20 } },
    });
    defer heap.releaseValue(allocator, dictionary);
    const keys = try keysOf(dictionary);
    try std.testing.expectEqual(@as(i64, 3), (try list.at(keys, 0)).int);
    try std.testing.expectEqual(@as(i64, 1), (try list.at(keys, 1)).int);
    try std.testing.expectEqual(@as(i64, 2), (try list.at(keys, 2)).int);
    try std.testing.expectError(error.DuplicateKey, fromPairs(allocator, &.{
        .{ .{ .int = 2 }, .{ .word = 1 } },
        .{ .{ .float = 2.0 }, .{ .word = 2 } },
    }));
}

test "dict equality and hash ignore insertion order" {
    const allocator = std.testing.allocator;
    const first = try fromPairs(allocator, &.{
        .{ .{ .int = 1 }, .{ .word = 10 } },
        .{ .{ .int = 2 }, .{ .word = 20 } },
    });
    defer heap.releaseValue(allocator, first);
    const second = try fromPairs(allocator, &.{
        .{ .{ .float = 2.0 }, .{ .word = 20 } },
        .{ .{ .float = 1.0 }, .{ .word = 10 } },
    });
    defer heap.releaseValue(allocator, second);
    try std.testing.expect(equal.match(first, second));
    try std.testing.expectEqual(equal.hash(first), equal.hash(second));
}

test "numeric hash collisions above f64 precision remain distinct keys" {
    const allocator = std.testing.allocator;
    const two_to_53: i64 = 1 << 53;
    const dictionary = try fromPairs(allocator, &.{
        .{ .{ .int = two_to_53 + 1 }, .{ .word = 1 } },
        .{ .{ .float = @floatFromInt(two_to_53) }, .{ .word = 2 } },
    });
    defer heap.releaseValue(allocator, dictionary);

    try std.testing.expectEqual(@as(u32, 1), (try get(dictionary, .{ .int = two_to_53 + 1 })).?.word);
    try std.testing.expectEqual(@as(u32, 2), (try get(
        dictionary,
        .{ .float = @floatFromInt(two_to_53) },
    )).?.word);
}

test "dicts index larger tables and accept structural values as keys" {
    const allocator = std.testing.allocator;
    var pairs: [20]Pair = undefined;
    for (&pairs, 0..) |*pair, index| pair.* = .{
        .{ .int = @intCast(index) },
        .{ .word = @intCast(index + 100) },
    };
    const indexed = try fromPairs(allocator, &pairs);
    defer heap.releaseValue(allocator, indexed);
    try std.testing.expect(heap.dictStorageConst(indexed.dict).index != null);
    for (0..pairs.len) |index| {
        const found = (try get(indexed, .{ .float = @floatFromInt(index) })).?;
        try std.testing.expectEqual(@as(u32, @intCast(index + 100)), found.word);
    }

    const leaf_key = try list.fromValues(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.releaseValue(allocator, leaf_key);
    const dictionary = try fromPairs(allocator, &.{.{ leaf_key, .{ .word = 9 } }});
    defer heap.releaseValue(allocator, dictionary);
    const spine_key = try list.fromValuesGeneric(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.releaseValue(allocator, spine_key);
    try std.testing.expectEqual(@as(u32, 9), (try get(dictionary, spine_key)).?.word);
}

test "merge is right-biased and preserves the left insertion story" {
    const allocator = std.testing.allocator;
    const left = try fromPairs(allocator, &.{
        .{ .{ .int = 1 }, .{ .word = 10 } },
        .{ .{ .int = 2 }, .{ .word = 20 } },
    });
    defer heap.releaseValue(allocator, left);
    const right = try fromPairs(allocator, &.{
        .{ .{ .int = 2 }, .{ .word = 200 } },
        .{ .{ .int = 3 }, .{ .word = 30 } },
    });
    defer heap.releaseValue(allocator, right);
    const result = try merge(allocator, left, right);
    defer if (result.dict != left.dict) heap.releaseValue(allocator, result);
    try std.testing.expectEqual(@as(u32, 200), (try get(result, .{ .int = 2 })).?.word);
    const keys = try keysOf(result);
    try std.testing.expectEqual(@as(i64, 1), (try list.at(keys, 0)).int);
    try std.testing.expectEqual(@as(i64, 2), (try list.at(keys, 1)).int);
    try std.testing.expectEqual(@as(i64, 3), (try list.at(keys, 2)).int);
}

test "functional updates mutate only unique dict headers" {
    const allocator = std.testing.allocator;
    const unique = try fromPairs(allocator, &.{.{ .{ .int = 1 }, .{ .word = 10 } }});
    defer heap.releaseValue(allocator, unique);
    const unique_result = try put(allocator, unique, .{ .int = 2 }, .{ .word = 20 });
    try std.testing.expectEqual(unique.dict, unique_result.dict);
    try std.testing.expectEqual(@as(u32, 20), (try get(unique, .{ .int = 2 })).?.word);

    heap.incRef(unique.dict);
    defer heap.decRef(allocator, unique.dict);
    const shared_result = try put(allocator, unique, .{ .int = 3 }, .{ .word = 30 });
    defer heap.releaseValue(allocator, shared_result);
    try std.testing.expect(unique.dict != shared_result.dict);
    try std.testing.expect((try get(unique, .{ .int = 3 })) == null);
    try std.testing.expectEqual(@as(u32, 30), (try get(shared_result, .{ .int = 3 })).?.word);

    const shared_deleted = try del(allocator, unique, .{ .int = 2 });
    defer heap.releaseValue(allocator, shared_deleted);
    try std.testing.expect(unique.dict != shared_deleted.dict);
    try std.testing.expect((try get(unique, .{ .int = 2 })) != null);
    try std.testing.expect((try get(shared_deleted, .{ .int = 2 })) == null);

    const right = try fromPairs(allocator, &.{.{ .{ .int = 4 }, .{ .word = 40 } }});
    defer heap.releaseValue(allocator, right);
    const shared_merged = try merge(allocator, unique, right);
    defer heap.releaseValue(allocator, shared_merged);
    try std.testing.expect(unique.dict != shared_merged.dict);
    try std.testing.expect((try get(unique, .{ .int = 4 })) == null);
    try std.testing.expectEqual(@as(u32, 40), (try get(shared_merged, .{ .int = 4 })).?.word);

    const deleted = try del(allocator, shared_result, .{ .int = 2 });
    defer if (deleted.dict != shared_result.dict) heap.releaseValue(allocator, deleted);
    try std.testing.expect((try get(deleted, .{ .int = 2 })) == null);
}

test "dict allocation paths are exhaustive and leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        constructionFailureProbe,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        putFailureProbe,
        .{},
    );
}
