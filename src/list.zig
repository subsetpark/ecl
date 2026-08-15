//! Specialized flat leaves and generic value spines.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const ListHandle = value.ListHandle;
pub const HeapKind = value.HeapKind;

pub const Error = error{ OutOfMemory, NotAList, IndexOutOfBounds };

pub const ElemProfile = enum {
    empty,
    all_int,
    all_float,
    all_char,
    all_symbol,
    mixed,
};

const Profile = struct {
    kind: ElemProfile,
    max_codepoint: u32 = 0,
};

pub fn fromValues(
    allocator: std.mem.Allocator,
    source: []const Value,
) error{OutOfMemory}!Value {
    const element_profile = profile(source);
    return switch (element_profile.kind) {
        .empty => fromGenericValues(allocator, source),
        .all_int => fromIntValues(allocator, source),
        .all_float => fromFloatValues(allocator, source),
        .all_char => fromCharValues(allocator, source, element_profile.max_codepoint),
        .all_symbol => fromSymbolValues(allocator, source),
        .mixed => fromGenericValues(allocator, source),
    };
}

/// Test and tooling hook for constructing a logically ordinary list without
/// construction specialization.
pub fn fromValuesGeneric(
    allocator: std.mem.Allocator,
    source: []const Value,
) error{OutOfMemory}!Value {
    return fromGenericValues(allocator, source);
}

pub fn fromI64Slice(
    allocator: std.mem.Allocator,
    source: []const i64,
) error{OutOfMemory}!Value {
    var builder = try heap.ListBuilder(.leaf_i64).init(allocator, source.len, initialCapacity(source.len));
    @memcpy(builder.items()[0..source.len], source);
    return .{ .list = builder.finish() };
}

pub fn fromF64Slice(
    allocator: std.mem.Allocator,
    source: []const f64,
) error{OutOfMemory}!Value {
    var builder = try heap.ListBuilder(.leaf_f64).init(allocator, source.len, initialCapacity(source.len));
    @memcpy(builder.items()[0..source.len], source);
    return .{ .list = builder.finish() };
}

pub fn fromCodepoints(
    allocator: std.mem.Allocator,
    source: []const u32,
) error{OutOfMemory}!Value {
    var max_codepoint: u32 = 0;
    for (source) |codepoint| max_codepoint = @max(max_codepoint, codepoint);
    const cap = initialCapacity(source.len);
    if (max_codepoint <= std.math.maxInt(u8)) {
        var builder = try heap.ListBuilder(.leaf_char1).init(allocator, source.len, cap);
        for (source, 0..) |codepoint, index| builder.items()[index] = @intCast(codepoint);
        return .{ .list = builder.finish() };
    }
    if (max_codepoint <= std.math.maxInt(u16)) {
        var builder = try heap.ListBuilder(.leaf_char2).init(allocator, source.len, cap);
        for (source, 0..) |codepoint, index| builder.items()[index] = @intCast(codepoint);
        return .{ .list = builder.finish() };
    }
    var builder = try heap.ListBuilder(.leaf_char4).init(allocator, source.len, cap);
    @memcpy(builder.items()[0..source.len], source);
    return .{ .list = builder.finish() };
}

pub fn emptyLike(
    allocator: std.mem.Allocator,
    source: Value,
) error{ OutOfMemory, NotAList }!Value {
    var builder = try heap.AnyListBuilder.init(allocator, (try listHeader(source)).kind(), 0, 0);
    return .{ .list = builder.finish() };
}

pub fn fromSymbolIds(
    allocator: std.mem.Allocator,
    source: []const u32,
) error{OutOfMemory}!Value {
    var builder = try heap.ListBuilder(.leaf_symbol).init(allocator, source.len, initialCapacity(source.len));
    @memcpy(builder.items()[0..source.len], source);
    return .{ .list = builder.finish() };
}

pub fn len(collection: Value) error{NotAList}!usize {
    const header = try listHeader(collection);
    return @intCast(header.length());
}

/// Returns a borrowed cell. Heap children remain owned by the list.
pub fn at(collection: Value, index: usize) error{ NotAList, IndexOutOfBounds }!Value {
    const header = try listHeader(collection);
    const used: usize = @intCast(header.length());
    if (index >= used) return error.IndexOutOfBounds;
    return atUnchecked(collection, index);
}

/// Internal fast path for callers that already proved list-ness and bounds.
pub fn atUnchecked(collection: Value, index: usize) Value {
    const header = collection.list;
    return switch (header.kind()) {
        .generic_spine => heap.valuesConst(header)[index],
        .leaf_i64 => .{ .int = heap.i64s(header)[index] },
        .leaf_f64 => .{ .float = heap.f64s(header)[index] },
        .leaf_char1 => .{ .char = heap.chars8(header)[index] },
        .leaf_char2 => .{ .char = heap.chars16(header)[index] },
        .leaf_char4 => .{ .char = heap.chars32(header)[index] },
        .leaf_symbol => .{ .symbol = heap.symbols(header)[index] },
        .dict, .task, .reserved_mask => unreachable,
    };
}

/// `collection` remains owned by the caller. The result tag states whether
/// that owner was updated or an additional root was returned.
pub fn append(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    collection: Value,
    item: Value,
) Error!heap.UpdateResult {
    const header = try listHeader(collection);
    const unique = heap.claimUniqueList(header) orelse
        return rebuildWithItem(allocator, releases, collection, item, false);

    const used: usize = @intCast(header.length());
    if (used == 0 and header.kind() == .generic_spine) {
        return rebuildWithItem(allocator, releases, collection, item, true);
    }

    const same_kind = switch (header.kind()) {
        .generic_spine => true,
        .leaf_i64 => item == .int,
        .leaf_f64 => item == .float,
        .leaf_char1 => item == .char and item.char <= std.math.maxInt(u8),
        .leaf_char2 => item == .char and item.char <= std.math.maxInt(u16),
        .leaf_char4 => item == .char,
        .leaf_symbol => item == .symbol,
        .dict, .task, .reserved_mask => return error.NotAList,
    };
    if (!same_kind) return rebuildWithItem(allocator, releases, collection, item, true);

    if (used == heap.capacity(header)) {
        const new_capacity = growCapacity(used + 1);
        try heap.replaceBuffer(allocator, unique, new_capacity);
    }
    switch (header.kind()) {
        .generic_spine => {
            heap.retainValue(item);
            heap.writeUniqueList(unique, used, item);
        },
        .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => heap.writeUniqueList(unique, used, item),
        .dict, .task, .reserved_mask => return error.NotAList,
    }
    heap.setUniqueListLength(unique, used + 1);
    return .{ .in_place = collection };
}

fn listHeader(collection: Value) error{NotAList}!*ListHandle {
    return switch (collection) {
        .list => |header| switch (header.kind()) {
            .generic_spine,
            .leaf_i64,
            .leaf_f64,
            .leaf_char1,
            .leaf_char2,
            .leaf_char4,
            .leaf_symbol,
            => header,
            .dict, .task, .reserved_mask => error.NotAList,
        },
        .int, .float, .char, .symbol, .word, .dict, .task => error.NotAList,
    };
}

fn profile(source: []const Value) Profile {
    if (source.len == 0) return .{ .kind = .empty };
    var result: Profile = switch (source[0]) {
        .int => .{ .kind = .all_int },
        .float => .{ .kind = .all_float },
        .char => |codepoint| .{ .kind = .all_char, .max_codepoint = codepoint },
        .symbol => .{ .kind = .all_symbol },
        .word, .list, .dict, .task => .{ .kind = .mixed },
    };
    for (source[1..]) |item| switch (result.kind) {
        .empty => unreachable,
        .all_int => if (item != .int) return .{ .kind = .mixed },
        .all_float => if (item != .float) return .{ .kind = .mixed },
        .all_char => if (item == .char) {
            result.max_codepoint = @max(result.max_codepoint, item.char);
        } else return .{ .kind = .mixed },
        .all_symbol => if (item != .symbol) return .{ .kind = .mixed },
        .mixed => return result,
    };
    return result;
}

fn fromIntValues(allocator: std.mem.Allocator, source: []const Value) !Value {
    var builder = try heap.ListBuilder(.leaf_i64).init(allocator, source.len, initialCapacity(source.len));
    for (source, 0..) |item, index| builder.items()[index] = item.int;
    return .{ .list = builder.finish() };
}

fn fromFloatValues(allocator: std.mem.Allocator, source: []const Value) !Value {
    var builder = try heap.ListBuilder(.leaf_f64).init(allocator, source.len, initialCapacity(source.len));
    for (source, 0..) |item, index| builder.items()[index] = item.float;
    return .{ .list = builder.finish() };
}

fn fromCharValues(
    allocator: std.mem.Allocator,
    source: []const Value,
    max_codepoint: u32,
) !Value {
    const cap = initialCapacity(source.len);
    if (max_codepoint <= std.math.maxInt(u8)) {
        var builder = try heap.ListBuilder(.leaf_char1).init(allocator, source.len, cap);
        for (source, 0..) |item, index| builder.items()[index] = @intCast(item.char);
        return .{ .list = builder.finish() };
    }
    if (max_codepoint <= std.math.maxInt(u16)) {
        var builder = try heap.ListBuilder(.leaf_char2).init(allocator, source.len, cap);
        for (source, 0..) |item, index| builder.items()[index] = @intCast(item.char);
        return .{ .list = builder.finish() };
    }
    var builder = try heap.ListBuilder(.leaf_char4).init(allocator, source.len, cap);
    for (source, 0..) |item, index| builder.items()[index] = item.char;
    return .{ .list = builder.finish() };
}

fn fromSymbolValues(allocator: std.mem.Allocator, source: []const Value) !Value {
    var builder = try heap.ListBuilder(.leaf_symbol).init(allocator, source.len, initialCapacity(source.len));
    for (source, 0..) |item, index| builder.items()[index] = item.symbol;
    return .{ .list = builder.finish() };
}

fn fromGenericValues(allocator: std.mem.Allocator, source: []const Value) !Value {
    var builder = try heap.ListBuilder(.generic_spine).init(
        allocator,
        source.len,
        initialCapacity(source.len),
    );
    for (source, 0..) |item, index| {
        heap.retainValue(item);
        builder.items()[index] = item;
    }
    return .{ .list = builder.finish() };
}

fn rebuildWithItem(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    collection: Value,
    item: Value,
    adopt: bool,
) Error!heap.UpdateResult {
    const old_len = try len(collection);
    const materialized = try allocator.alloc(Value, old_len + 1);
    defer allocator.free(materialized);
    for (0..old_len) |index| materialized[index] = try at(collection, index);
    materialized[old_len] = item;
    const replacement = try fromValues(allocator, materialized);
    if (!adopt) return .{ .replacement = replacement };
    heap.adoptListRepresentationDeferred(
        releases,
        heap.claimUniqueList(collection.list).?,
        heap.claimUniqueList(replacement.list).?,
    );
    return .{ .in_place = collection };
}

fn initialCapacity(used: usize) usize {
    return growCapacity(@max(used, 1));
}

fn growCapacity(minimum: usize) usize {
    var result: usize = 4;
    while (result < minimum) result = std.math.mul(usize, result, 2) catch return minimum;
    return result;
}

fn constructionFailureProbe(allocator: std.mem.Allocator) !void {
    const child = try fromValues(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.testing.releaseValue(allocator, child);
    const parent = try fromValues(allocator, &.{ child, .{ .word = 7 } });
    defer heap.testing.releaseValue(allocator, parent);
    const generic = try fromValuesGeneric(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.testing.releaseValue(allocator, generic);
    const ints = try fromI64Slice(allocator, &.{ 1, 2 });
    defer heap.testing.releaseValue(allocator, ints);
    const floats = try fromF64Slice(allocator, &.{ 1.0, 2.0 });
    defer heap.testing.releaseValue(allocator, floats);
    const chars = try fromCodepoints(allocator, &.{ 'a', 0x100, 0x10000 });
    defer heap.testing.releaseValue(allocator, chars);
    const symbols = try fromSymbolIds(allocator, &.{ 1, 2 });
    defer heap.testing.releaseValue(allocator, symbols);
}

fn appendFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const original = try fromValues(allocator, &.{ .{ .char = 'a' }, .{ .char = 'b' } });
    defer heap.testing.releaseValue(allocator, original);
    const result = try append(allocator, cleanup.domain(), original, .{ .int = 3 });
    if (result == .replacement) heap.testing.releaseValue(allocator, result.value());
}

test "construction specializes every homogeneous profile" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { values: []const Value, kind: HeapKind }{
        .{ .values = &.{ .{ .int = 1 }, .{ .int = 2 } }, .kind = .leaf_i64 },
        .{ .values = &.{ .{ .float = 1.0 }, .{ .float = 2.0 } }, .kind = .leaf_f64 },
        .{ .values = &.{ .{ .char = 'a' }, .{ .char = 'b' } }, .kind = .leaf_char1 },
        .{ .values = &.{ .{ .symbol = 1 }, .{ .symbol = 2 } }, .kind = .leaf_symbol },
        .{ .values = &.{ .{ .int = 1 }, .{ .float = 2.0 } }, .kind = .generic_spine },
    };
    for (cases) |case| {
        const collection = try fromValues(allocator, case.values);
        defer heap.testing.releaseValue(allocator, collection);
        try std.testing.expectEqual(case.kind, collection.list.kind());
        for (case.values, 0..) |expected, index| {
            try std.testing.expectEqual(expected, try at(collection, index));
        }
    }
}

test "unique append uses slack while shared append copies" {
    const allocator = std.testing.allocator;
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    const unique = try fromValues(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.testing.releaseValue(allocator, unique);
    const unique_update = try append(allocator, releases, unique, .{ .int = 3 });
    try std.testing.expect(unique_update == .in_place);
    const unique_result = unique_update.value();
    try std.testing.expectEqual(unique.list, unique_result.list);
    try std.testing.expectEqual(@as(i64, 3), (try at(unique_result, 2)).int);

    heap.incRef(unique.list);
    defer heap.testing.decRef(allocator, unique.list);
    const shared_update = try append(allocator, releases, unique, .{ .int = 4 });
    try std.testing.expect(shared_update == .replacement);
    const shared_result = shared_update.value();
    defer heap.testing.releaseValue(allocator, shared_result);
    try std.testing.expect(unique.list != shared_result.list);
    try std.testing.expectEqual(@as(usize, 3), try len(unique));
    try std.testing.expectEqual(@as(i64, 4), (try at(shared_result, 3)).int);
}

test "char append promotes width then generalizes on type mismatch" {
    const allocator = std.testing.allocator;
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    const chars = try fromValues(allocator, &.{.{ .char = 'a' }});
    defer heap.testing.releaseValue(allocator, chars);
    _ = try append(allocator, releases, chars, .{ .char = 0x100 });
    try std.testing.expectEqual(HeapKind.leaf_char2, chars.list.kind());
    _ = try append(allocator, releases, chars, .{ .char = 0x10000 });
    try std.testing.expectEqual(HeapKind.leaf_char4, chars.list.kind());
    _ = try append(allocator, releases, chars, .{ .word = 7 });
    try std.testing.expectEqual(HeapKind.generic_spine, chars.list.kind());
}

test "constructors and append exhaust allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        constructionFailureProbe,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        appendFailureProbe,
        .{},
    );
}
