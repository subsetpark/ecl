//! Insertion-ordered K-style dictionaries with order-independent identity.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const DictHandle = value.DictHandle;
pub const Pair = [2]Value;

pub const Error = error{ OutOfMemory, DuplicateKey, NotADict };

const index_threshold = 16;
const empty_index: u32 = 0;

pub fn fromPairs(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
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

    var keys_value = heap.OwnedValue.init(releases, try list.fromValues(allocator, keys));
    defer keys_value.deinit();
    var vals_value = heap.OwnedValue.init(releases, try list.fromValues(allocator, vals));
    defer vals_value.deinit();
    var hashes_value = heap.OwnedValue.init(releases, try list.fromI64Slice(allocator, hashes));
    defer hashes_value.deinit();

    var index = if (pairs.len >= index_threshold)
        try buildIndex(allocator, hashes)
    else
        null;
    defer if (index) |owned_index| allocator.free(owned_index);

    var builder = try heap.DictBuilder.init(allocator, pairs.len);
    defer builder.retirePartial(releases);
    const header = builder.finish(.{
        .keys = keys_value.borrow().list,
        .vals = vals_value.borrow().list,
        .hashes = hashes_value.borrow().list,
    }, index);
    _ = keys_value.take();
    _ = vals_value.take();
    _ = hashes_value.take();
    index = null;
    return .{ .dict = header };
}

/// `fromPairs` for call sites whose keys are distinct by construction.
pub fn fromUniquePairs(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    pairs: []const Pair,
) error{OutOfMemory}!Value {
    return fromPairs(allocator, releases, pairs) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateKey => unreachable,
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

/// Inputs remain owned by their callers. The result tag states whether the
/// existing owner was updated or an additional root was returned.
pub fn put(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    dictionary: Value,
    key: Value,
    new_value: Value,
) error{ OutOfMemory, NotADict }!heap.UpdateResult {
    const header = try dictHeader(dictionary);
    const found = try findWithAllocator(allocator, header, key);
    const old_len: usize = @intCast(header.length());
    const new_len = old_len + @intFromBool(found == null);
    const pairs = try allocator.alloc(Pair, new_len);
    defer allocator.free(pairs);
    for (0..old_len) |index| pairs[index] = .{ keyAt(header, index), valueAt(header, index) };
    if (found) |index| {
        pairs[index][1] = new_value;
    } else {
        pairs[old_len] = .{ key, new_value };
    }
    const replacement = try fromUniquePairs(allocator, releases, pairs);
    return installReplacement(releases, dictionary, replacement);
}

/// Uses the same functional-update ownership contract as `put`.
pub fn del(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    dictionary: Value,
    key: Value,
) error{ OutOfMemory, NotADict }!heap.UpdateResult {
    const header = try dictHeader(dictionary);
    const found = try findWithAllocator(allocator, header, key) orelse
        return .{ .in_place = dictionary };
    const old_len: usize = @intCast(header.length());
    const pairs = try allocator.alloc(Pair, old_len - 1);
    defer allocator.free(pairs);
    var dest: usize = 0;
    for (0..old_len) |index| {
        if (index == found) continue;
        pairs[dest] = .{ keyAt(header, index), valueAt(header, index) };
        dest += 1;
    }
    const replacement = try fromUniquePairs(allocator, releases, pairs);
    return installReplacement(releases, dictionary, replacement);
}

/// Uses `put`'s ownership contract for `left`; `right` is always unchanged.
pub fn merge(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    left: Value,
    right: Value,
) error{ OutOfMemory, NotADict }!heap.UpdateResult {
    const left_header = try dictHeader(left);
    const right_header = try dictHeader(right);
    const left_len: usize = @intCast(left_header.length());
    const right_len: usize = @intCast(right_header.length());
    const pairs = try allocator.alloc(Pair, left_len + right_len);
    defer allocator.free(pairs);
    var count = left_len;
    for (0..left_len) |index| pairs[index] = .{
        keyAt(left_header, index),
        valueAt(left_header, index),
    };
    for (0..right_len) |right_index| {
        const right_key = keyAt(right_header, right_index);
        const found = try findWithAllocator(allocator, left_header, right_key);
        if (found) |index| {
            pairs[index][1] = valueAt(right_header, right_index);
        } else {
            pairs[count] = .{ right_key, valueAt(right_header, right_index) };
            count += 1;
        }
    }
    const replacement = try fromUniquePairs(allocator, releases, pairs[0..count]);
    return installReplacement(releases, left, replacement);
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
        .int, .float, .char, .symbol, .word, .list, .task => error.NotADict,
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
    const count: usize = @intCast(header.length());
    const key_hash = try equal.hashWithAllocator(allocator, key);
    const storage = heap.dictStorageConst(header);
    const maybe_index = storage.index();
    if (count < index_threshold or maybe_index == null) {
        for (0..count) |index| {
            if (hashAt(header, index) != key_hash) continue;
            if (try equal.matchWithAllocator(allocator, keyAt(header, index), key)) return index;
        }
        return null;
    }

    const table = maybe_index.?;
    var slot: usize = @intCast(key_hash & (table.len - 1));
    for (0..table.len) |_| {
        const encoded = table[slot];
        if (encoded == empty_index) return null;
        const index = encoded - 1;
        if (hashAt(header, index) == key_hash and
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
    releases: *heap.ReleaseDomain,
    original: Value,
    replacement: Value,
) heap.UpdateResult {
    const destination = heap.claimUniqueDict(original.dict) orelse
        return .{ .replacement = replacement };
    const source = heap.claimUniqueDict(replacement.dict) orelse unreachable;
    heap.adoptDictRepresentationDeferred(releases, destination, source);
    return .{ .in_place = original };
}

fn constructionFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const releases = cleanup.domain();
    const dictionary = try fromPairs(allocator, releases, &.{
        .{ .{ .int = 1 }, .{ .word = 10 } },
        .{ .{ .float = 2.5 }, .{ .word = 20 } },
    });
    cleanup.releaseValue(dictionary);
}

fn putFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const releases = cleanup.domain();
    var dictionary = try fromPairs(allocator, releases, &.{.{ .{ .int = 1 }, .{ .word = 10 } }});
    defer cleanup.releaseValue(dictionary);
    _ = try getWithAllocator(allocator, dictionary, .{ .int = 1 });
    dictionary = (try put(allocator, releases, dictionary, .{ .int = 2 }, .{ .word = 20 })).value();
    dictionary = (try del(allocator, releases, dictionary, .{ .int = 1 })).value();
    const right = try fromPairs(allocator, releases, &.{.{ .{ .int = 2 }, .{ .word = 30 } }});
    defer cleanup.releaseValue(right);
    dictionary = (try merge(allocator, releases, dictionary, right)).value();
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
