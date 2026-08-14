//! Poll-aware construction, lookup, and update for kernel-owned traversals.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const poll = @import("poll.zig");

const Value = value.Value;
const Header = value.Header;
const Poller = poll.Poller;
const index_threshold = 16;
const empty_index: u32 = 0;

const ProfileKind = enum { empty, int, float, char, symbol, mixed };
const Profile = struct { kind: ProfileKind, max_codepoint: u32 = 0 };

pub fn fromValues(
    allocator: std.mem.Allocator,
    source: []const Value,
    poller: Poller,
) poll.Error!Value {
    const item_profile = try profile(source, poller);
    return switch (item_profile.kind) {
        .empty, .mixed => genericValues(allocator, source, poller),
        .int => typedValues(i64, .leaf_i64, allocator, source, poller),
        .float => typedValues(f64, .leaf_f64, allocator, source, poller),
        .char => charValues(allocator, source, item_profile.max_codepoint, poller),
        .symbol => typedValues(u32, .leaf_symbol, allocator, source, poller),
    };
}

pub fn fromValuesGeneric(
    allocator: std.mem.Allocator,
    source: []const Value,
    poller: Poller,
) poll.Error!Value {
    return genericValues(allocator, source, poller);
}

pub fn fromI64Slice(
    allocator: std.mem.Allocator,
    source: []const i64,
    poller: Poller,
) poll.Error!Value {
    const header = try heap.allocHeader(allocator, .leaf_i64, source.len, initialCapacity(source.len));
    errdefer heap.decRef(allocator, heap.publish(header));
    for (source, 0..) |item, index| {
        try poller.poll();
        heap.initI64s(header)[index] = item;
    }
    return .{ .list = heap.publish(header) };
}

pub fn fromCodepoints(
    allocator: std.mem.Allocator,
    source: []const u32,
    poller: Poller,
) poll.Error!Value {
    var max_codepoint: u32 = 0;
    for (source) |codepoint| {
        try poller.poll();
        max_codepoint = @max(max_codepoint, codepoint);
    }
    if (max_codepoint <= std.math.maxInt(u8)) {
        return codepointValuesOf(u8, .leaf_char1, allocator, source, poller);
    }
    if (max_codepoint <= std.math.maxInt(u16)) {
        return codepointValuesOf(u16, .leaf_char2, allocator, source, poller);
    }
    return codepointValuesOf(u32, .leaf_char4, allocator, source, poller);
}

pub const Utf8Error = poll.Error || error{InvalidUtf8};

pub fn utf8CodepointCount(bytes: []const u8, poller: Poller) Utf8Error!usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < bytes.len) {
        try poller.poll();
        _ = try decodeUtf8Codepoint(bytes, &index);
        count = std.math.add(usize, count, 1) catch return error.OutOfMemory;
    }
    return count;
}

pub fn decodeUtf8Into(
    bytes: []const u8,
    output: []u32,
    poller: Poller,
) Utf8Error!void {
    var index: usize = 0;
    var destination: usize = 0;
    while (index < bytes.len) {
        try poller.poll();
        if (destination == output.len) return error.InvalidUtf8;
        output[destination] = try decodeUtf8Codepoint(bytes, &index);
        destination += 1;
    }
    if (destination != output.len) return error.InvalidUtf8;
}

pub fn fromUtf8(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    poller: Poller,
) Utf8Error!Value {
    const count = try utf8CodepointCount(bytes, poller);
    const codepoints = try allocator.alloc(u32, count);
    defer allocator.free(codepoints);
    try decodeUtf8Into(bytes, codepoints, poller);
    return fromCodepoints(allocator, codepoints, poller);
}

pub fn toUtf8Owned(
    allocator: std.mem.Allocator,
    string: Value,
    poller: Poller,
) (poll.Error || error{InvalidCodepoint})![]u8 {
    std.debug.assert(string.isString());
    const count: usize = @intCast(string.list.length());
    var byte_count: usize = 0;
    for (0..count) |index| {
        try poller.poll();
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            @intCast(@import("list.zig").atUnchecked(string, index).char),
            &encoded,
        ) catch return error.InvalidCodepoint;
        byte_count = std.math.add(usize, byte_count, length) catch return error.OutOfMemory;
    }
    const bytes = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(bytes);
    var cursor: usize = 0;
    for (0..count) |index| {
        try poller.poll();
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            @intCast(@import("list.zig").atUnchecked(string, index).char),
            &encoded,
        ) catch return error.InvalidCodepoint;
        @memcpy(bytes[cursor..][0..length], encoded[0..length]);
        cursor += length;
    }
    std.debug.assert(cursor == bytes.len);
    return bytes;
}

fn decodeUtf8Codepoint(bytes: []const u8, index: *usize) error{InvalidUtf8}!u32 {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index.*]) catch
        return error.InvalidUtf8;
    if (length > bytes.len - index.*) return error.InvalidUtf8;
    const codepoint = std.unicode.utf8Decode(bytes[index.*..][0..length]) catch
        return error.InvalidUtf8;
    index.* += length;
    return codepoint;
}

fn profile(source: []const Value, poller: Poller) poll.Error!Profile {
    if (source.len == 0) return .{ .kind = .empty };
    try poller.poll();
    var result: Profile = switch (source[0]) {
        .int => .{ .kind = .int },
        .float => .{ .kind = .float },
        .char => |codepoint| .{ .kind = .char, .max_codepoint = codepoint },
        .symbol => .{ .kind = .symbol },
        .word, .list, .dict => .{ .kind = .mixed },
    };
    for (source[1..]) |item| {
        try poller.poll();
        switch (result.kind) {
            .empty => unreachable,
            .int => if (item != .int) return .{ .kind = .mixed },
            .float => if (item != .float) return .{ .kind = .mixed },
            .char => if (item == .char) {
                result.max_codepoint = @max(result.max_codepoint, item.char);
            } else return .{ .kind = .mixed },
            .symbol => if (item != .symbol) return .{ .kind = .mixed },
            .mixed => return result,
        }
    }
    return result;
}

fn typedValues(
    comptime T: type,
    comptime kind: value.HeapKind,
    allocator: std.mem.Allocator,
    source: []const Value,
    poller: Poller,
) poll.Error!Value {
    _ = T;
    const header = try heap.allocHeader(allocator, kind, source.len, initialCapacity(source.len));
    errdefer heap.decRef(allocator, heap.publish(header));
    for (source, 0..) |item, index| {
        try poller.poll();
        switch (kind) {
            .leaf_i64 => heap.initI64s(header)[index] = item.int,
            .leaf_f64 => heap.initF64s(header)[index] = item.float,
            .leaf_symbol => heap.initSymbols(header)[index] = item.symbol,
            else => unreachable,
        }
    }
    return .{ .list = heap.publish(header) };
}

fn charValues(
    allocator: std.mem.Allocator,
    source: []const Value,
    max_codepoint: u32,
    poller: Poller,
) poll.Error!Value {
    if (max_codepoint <= std.math.maxInt(u8)) {
        return charValuesOf(u8, .leaf_char1, allocator, source, poller);
    }
    if (max_codepoint <= std.math.maxInt(u16)) {
        return charValuesOf(u16, .leaf_char2, allocator, source, poller);
    }
    return charValuesOf(u32, .leaf_char4, allocator, source, poller);
}

fn charValuesOf(
    comptime T: type,
    comptime kind: value.HeapKind,
    allocator: std.mem.Allocator,
    source: []const Value,
    poller: Poller,
) poll.Error!Value {
    _ = T;
    const header = try heap.allocHeader(allocator, kind, source.len, initialCapacity(source.len));
    errdefer heap.decRef(allocator, heap.publish(header));
    for (source, 0..) |item, index| {
        try poller.poll();
        switch (kind) {
            .leaf_char1 => heap.initChars8(header)[index] = @intCast(item.char),
            .leaf_char2 => heap.initChars16(header)[index] = @intCast(item.char),
            .leaf_char4 => heap.initChars32(header)[index] = item.char,
            else => unreachable,
        }
    }
    return .{ .list = heap.publish(header) };
}

fn codepointValuesOf(
    comptime T: type,
    comptime kind: value.HeapKind,
    allocator: std.mem.Allocator,
    source: []const u32,
    poller: Poller,
) poll.Error!Value {
    _ = T;
    const header = try heap.allocHeader(allocator, kind, source.len, initialCapacity(source.len));
    errdefer heap.decRef(allocator, heap.publish(header));
    for (source, 0..) |codepoint, index| {
        try poller.poll();
        switch (kind) {
            .leaf_char1 => heap.initChars8(header)[index] = @intCast(codepoint),
            .leaf_char2 => heap.initChars16(header)[index] = @intCast(codepoint),
            .leaf_char4 => heap.initChars32(header)[index] = codepoint,
            else => unreachable,
        }
    }
    return .{ .list = heap.publish(header) };
}

fn genericValues(
    allocator: std.mem.Allocator,
    source: []const Value,
    poller: Poller,
) poll.Error!Value {
    const header = try heap.allocHeader(
        allocator,
        .generic_spine,
        source.len,
        initialCapacity(source.len),
    );
    heap.setInitializingLength(header, 0);
    errdefer heap.decRef(allocator, heap.publish(header));
    for (source, 0..) |item, index| {
        try poller.poll();
        heap.retainValue(item);
        heap.initValues(header)[index] = item;
        heap.setInitializingLength(header, index + 1);
    }
    return .{ .list = heap.publish(header) };
}

pub fn fromPairs(
    allocator: std.mem.Allocator,
    pairs: []const dict.Pair,
    poller: Poller,
) error{ OutOfMemory, Ecl, DuplicateKey }!Value {
    return pairsValue(allocator, pairs, poller, true);
}

pub fn fromUniquePairs(
    allocator: std.mem.Allocator,
    pairs: []const dict.Pair,
    poller: Poller,
) poll.Error!Value {
    return pairsValue(allocator, pairs, poller, false) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Ecl => error.Ecl,
        error.DuplicateKey => unreachable,
    };
}

fn pairsValue(
    allocator: std.mem.Allocator,
    pairs: []const dict.Pair,
    poller: Poller,
    check_duplicates: bool,
) error{ OutOfMemory, Ecl, DuplicateKey }!Value {
    if (pairs.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const keys = try allocator.alloc(Value, pairs.len);
    defer allocator.free(keys);
    const vals = try allocator.alloc(Value, pairs.len);
    defer allocator.free(vals);
    const hashes = try allocator.alloc(i64, pairs.len);
    defer allocator.free(hashes);

    for (pairs, 0..) |pair, index| {
        try poller.poll();
        const key_hash = try equal.hashWithPolling(allocator, pair[0], poller);
        if (check_duplicates) {
            for (keys[0..index], 0..) |prior, prior_index| {
                try poller.poll();
                if (@as(u64, @bitCast(hashes[prior_index])) != key_hash) continue;
                if (try equal.matchWithPolling(allocator, prior, pair[0], poller)) {
                    return error.DuplicateKey;
                }
            }
        }
        keys[index] = pair[0];
        vals[index] = pair[1];
        hashes[index] = @bitCast(key_hash);
    }

    const keys_value = try fromValues(allocator, keys, poller);
    var keys_owned = true;
    defer if (keys_owned) heap.releaseValue(allocator, keys_value);
    const vals_value = try fromValues(allocator, vals, poller);
    var vals_owned = true;
    defer if (vals_owned) heap.releaseValue(allocator, vals_value);
    const hashes_value = try fromI64Slice(allocator, hashes, poller);
    var hashes_owned = true;
    defer if (hashes_owned) heap.releaseValue(allocator, hashes_value);

    const index = if (pairs.len >= index_threshold) try buildIndex(allocator, hashes, poller) else null;
    var index_owned = index != null;
    defer if (index_owned) allocator.free(index.?);
    const header = try heap.allocHeader(allocator, .dict, pairs.len, pairs.len);
    heap.initDictStorage(header).* = .{
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
    return .{ .dict = heap.publish(header) };
}

pub fn get(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
    poller: Poller,
) error{ OutOfMemory, Ecl, NotADict }!?Value {
    const header = try dictHeader(dictionary);
    const found = try find(allocator, header, key, poller) orelse return null;
    return dict.valueAt(header, found);
}

pub fn contains(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
    poller: Poller,
) error{ OutOfMemory, Ecl, NotADict }!bool {
    const header = try dictHeader(dictionary);
    return try find(allocator, header, key, poller) != null;
}

pub fn put(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
    new_value: Value,
    poller: Poller,
) error{ OutOfMemory, Ecl, NotADict }!Value {
    const header = try dictHeader(dictionary);
    const found = try find(allocator, header, key, poller);
    const old_len: usize = @intCast(header.length());
    const pairs = try allocator.alloc(dict.Pair, old_len + @intFromBool(found == null));
    defer allocator.free(pairs);
    for (0..old_len) |index| {
        try poller.poll();
        pairs[index] = .{ dict.keyAt(header, index), dict.valueAt(header, index) };
    }
    if (found) |index| pairs[index][1] = new_value else pairs[old_len] = .{ key, new_value };
    return installReplacement(allocator, dictionary, try fromUniquePairs(allocator, pairs, poller));
}

pub fn del(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: Value,
    poller: Poller,
) error{ OutOfMemory, Ecl, NotADict }!Value {
    const header = try dictHeader(dictionary);
    const found = try find(allocator, header, key, poller) orelse return dictionary;
    const old_len: usize = @intCast(header.length());
    const pairs = try allocator.alloc(dict.Pair, old_len - 1);
    defer allocator.free(pairs);
    var dest: usize = 0;
    for (0..old_len) |index| {
        try poller.poll();
        if (index == found) continue;
        pairs[dest] = .{ dict.keyAt(header, index), dict.valueAt(header, index) };
        dest += 1;
    }
    return installReplacement(allocator, dictionary, try fromUniquePairs(allocator, pairs, poller));
}

pub fn merge(
    allocator: std.mem.Allocator,
    left: Value,
    right: Value,
    poller: Poller,
) error{ OutOfMemory, Ecl, NotADict }!Value {
    const left_header = try dictHeader(left);
    const right_header = try dictHeader(right);
    const left_len: usize = @intCast(left_header.length());
    const right_len: usize = @intCast(right_header.length());
    const pairs = try allocator.alloc(dict.Pair, left_len + right_len);
    defer allocator.free(pairs);
    var count = left_len;
    for (0..left_len) |index| {
        try poller.poll();
        pairs[index] = .{ dict.keyAt(left_header, index), dict.valueAt(left_header, index) };
    }
    for (0..right_len) |right_index| {
        try poller.poll();
        const key = dict.keyAt(right_header, right_index);
        if (try find(allocator, left_header, key, poller)) |index| {
            pairs[index][1] = dict.valueAt(right_header, right_index);
        } else {
            pairs[count] = .{ key, dict.valueAt(right_header, right_index) };
            count += 1;
        }
    }
    return installReplacement(
        allocator,
        left,
        try fromUniquePairs(allocator, pairs[0..count], poller),
    );
}

fn find(
    allocator: std.mem.Allocator,
    header: *Header,
    key: Value,
    poller: Poller,
) poll.Error!?usize {
    const count: usize = @intCast(header.length());
    const key_hash = try equal.hashWithPolling(allocator, key, poller);
    const storage = heap.dictStorageConst(header);
    if (count < index_threshold or storage.index == null) {
        for (0..count) |index| {
            try poller.poll();
            if (cachedHash(header, index) != key_hash) continue;
            if (try equal.matchWithPolling(allocator, dict.keyAt(header, index), key, poller)) {
                return index;
            }
        }
        return null;
    }
    const table = storage.index.?[0..storage.index_len];
    var slot: usize = @intCast(key_hash & (table.len - 1));
    for (0..table.len) |_| {
        try poller.poll();
        const encoded = table[slot];
        if (encoded == empty_index) return null;
        const index = encoded - 1;
        if (cachedHash(header, index) == key_hash and
            try equal.matchWithPolling(allocator, dict.keyAt(header, index), key, poller)) return index;
        slot = (slot + 1) & (table.len - 1);
    }
    return null;
}

fn buildIndex(
    allocator: std.mem.Allocator,
    hashes: []const i64,
    poller: Poller,
) poll.Error![]u32 {
    var table_len: usize = 32;
    const minimum = std.math.mul(usize, hashes.len, 2) catch return error.OutOfMemory;
    while (table_len < minimum) {
        table_len = std.math.mul(usize, table_len, 2) catch return error.OutOfMemory;
    }
    const table = try allocator.alloc(u32, table_len);
    errdefer allocator.free(table);
    for (table) |*slot| {
        try poller.poll();
        slot.* = empty_index;
    }
    for (hashes, 0..) |signed_hash, index| {
        try poller.poll();
        const key_hash: u64 = @bitCast(signed_hash);
        var slot: usize = @intCast(key_hash & (table.len - 1));
        while (table[slot] != empty_index) {
            try poller.poll();
            slot = (slot + 1) & (table.len - 1);
        }
        table[slot] = @intCast(index + 1);
    }
    return table;
}

fn cachedHash(header: *Header, index: usize) u64 {
    const hashes = heap.dictStorageConst(header).payload.?.hashes.?;
    return @bitCast(heap.i64s(hashes)[index]);
}

fn dictHeader(dictionary: Value) error{NotADict}!*Header {
    return switch (dictionary) {
        .dict => |header| if (header.kind() == .dict) header else error.NotADict,
        .int, .float, .char, .symbol, .word, .list => error.NotADict,
    };
}

fn installReplacement(allocator: std.mem.Allocator, original: Value, replacement: Value) Value {
    const destination = heap.claimUnique(original.dict) orelse return replacement;
    const source = heap.claimUnique(replacement.dict) orelse unreachable;
    heap.adoptRepresentation(allocator, destination, source);
    return original;
}

fn initialCapacity(used: usize) usize {
    var result: usize = 4;
    while (result < @max(used, 1)) result = std.math.mul(usize, result, 2) catch return used;
    return result;
}

test "poll-aware list materializers charge profiling and copies" {
    const Counter = struct {
        calls: usize = 0,

        fn tick(raw: *anyopaque) poll.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    var counter: Counter = .{};
    const poller: Poller = .{ .context = &counter, .poll_fn = Counter.tick };

    const values = try fromValues(
        std.testing.allocator,
        &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } },
        poller,
    );
    defer heap.releaseValue(std.testing.allocator, values);
    try std.testing.expectEqual(@as(usize, 6), counter.calls);

    counter.calls = 0;
    const integers = try fromI64Slice(std.testing.allocator, &.{ 1, 2, 3 }, poller);
    defer heap.releaseValue(std.testing.allocator, integers);
    try std.testing.expectEqual(@as(usize, 3), counter.calls);

    counter.calls = 0;
    const text = try fromCodepoints(std.testing.allocator, &.{ 'a', 0x100, 0x10000 }, poller);
    defer heap.releaseValue(std.testing.allocator, text);
    try std.testing.expectEqual(@as(usize, 6), counter.calls);
}
