//! Heap allocation and precise atomic reference counting.

const std = @import("std");
const value = @import("value.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const HeapKind = value.HeapKind;
pub const DictPayload = value.DictPayload;

pub const DictStorage = struct {
    payload: ?DictPayload = null,
    initialized: bool = false,
    index: ?[*]u32 = null,
    index_len: usize = 0,
};

const Object = struct {
    header: Header,
    capacity: usize,
    payload: ?*anyopaque,
    next_destroy: ?*Header,
};

fn object(header: *Header) *Object {
    return @fieldParentPtr("header", header);
}

fn objectConst(header: *const Header) *const Object {
    return @fieldParentPtr("header", header);
}

pub fn capacity(header: *const Header) usize {
    return objectConst(header).capacity;
}

pub fn allocHeader(
    allocator: std.mem.Allocator,
    kind_value: HeapKind,
    len_value: usize,
    capacity_value: usize,
) error{OutOfMemory}!*Header {
    std.debug.assert(len_value <= capacity_value or kind_value == .dict);
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    obj.* = .{
        .header = Header.init(kind_value, len_value),
        .capacity = capacity_value,
        .payload = null,
        .next_destroy = null,
    };
    obj.payload = switch (kind_value) {
        .generic_spine => try allocPayload(Value, allocator, capacity_value),
        .leaf_i64 => try allocPayload(i64, allocator, capacity_value),
        .leaf_f64 => try allocPayload(f64, allocator, capacity_value),
        .leaf_char1 => try allocPayload(u8, allocator, capacity_value),
        .leaf_char2 => try allocPayload(u16, allocator, capacity_value),
        .leaf_char4 => try allocPayload(u32, allocator, capacity_value),
        .leaf_symbol => try allocPayload(u32, allocator, capacity_value),
        .dict => @ptrCast(try allocator.create(DictStorage)),
        .reserved_mask => null,
    };
    if (kind_value == .dict) dictStorage(&obj.header).* = .{};
    return &obj.header;
}

fn allocPayload(
    comptime T: type,
    allocator: std.mem.Allocator,
    count: usize,
) error{OutOfMemory}!?*anyopaque {
    if (count == 0) return null;
    const buffer = try allocator.alloc(T, count);
    return @ptrCast(buffer.ptr);
}

pub fn values(header: *Header) []Value {
    std.debug.assert(header.kind() == .generic_spine);
    const cap = capacity(header);
    if (cap == 0) return &.{};
    const ptr: [*]Value = @ptrCast(@alignCast(object(header).payload.?));
    return ptr[0..cap];
}

pub fn valuesConst(header: *const Header) []const Value {
    return values(@constCast(header));
}

pub fn items(comptime T: type, header: *Header) []T {
    const cap = capacity(header);
    if (cap == 0) return &.{};
    const ptr: [*]T = @ptrCast(@alignCast(object(header).payload.?));
    return ptr[0..cap];
}

pub fn itemsConst(comptime T: type, header: *const Header) []const T {
    return items(T, @constCast(header));
}

pub fn dictStorage(header: *Header) *DictStorage {
    std.debug.assert(header.kind() == .dict);
    return @ptrCast(@alignCast(object(header).payload.?));
}

pub fn dictStorageConst(header: *const Header) *const DictStorage {
    return dictStorage(@constCast(header));
}

pub fn incRef(header: *Header) void {
    const old = header.rc.fetchAdd(1, .monotonic);
    std.debug.assert(old != 0 and old != std.math.maxInt(u32));
}

/// The sole copy-on-write gate in the codebase (decision 23).
pub fn isUnique(header: *const Header) bool {
    return header.rc.load(.acquire) == 1;
}

pub fn retainValue(item: Value) void {
    switch (item) {
        .int, .float, .char, .symbol, .word => {},
        .list => |header| incRef(header),
        .dict => |header| incRef(header),
    }
}

pub fn decRef(allocator: std.mem.Allocator, header: *Header) void {
    var work: ?*Header = null;
    releaseOnto(header, &work);
    while (work) |current| {
        const obj = object(current);
        work = obj.next_destroy;
        releaseChildren(current, &work);
        freePayload(allocator, current);
        allocator.destroy(obj);
    }
}

pub fn releaseValue(allocator: std.mem.Allocator, item: Value) void {
    switch (item) {
        .int, .float, .char, .symbol, .word => {},
        .list => |header| decRef(allocator, header),
        .dict => |header| decRef(allocator, header),
    }
}

fn releaseOnto(header: *Header, work: *?*Header) void {
    const old = header.rc.fetchSub(1, .release);
    std.debug.assert(old != 0);
    if (old != 1) return;
    _ = header.rc.load(.acquire);
    object(header).next_destroy = work.*;
    work.* = header;
}

fn releaseChildren(header: *Header, work: *?*Header) void {
    switch (header.kind()) {
        .generic_spine => {
            const used: usize = @intCast(header.len);
            for (values(header)[0..used]) |child| {
                if (child.heapHeader()) |child_header| releaseOnto(child_header, work);
            }
        },
        .dict => {
            const storage = dictStorage(header);
            if (storage.initialized) {
                const payload = storage.payload.?;
                releaseOnto(payload.keys, work);
                releaseOnto(payload.vals, work);
                if (payload.hashes) |hashes| releaseOnto(hashes, work);
            }
        },
        .leaf_i64,
        .leaf_f64,
        .leaf_char1,
        .leaf_char2,
        .leaf_char4,
        .leaf_symbol,
        .reserved_mask,
        => {},
    }
}

fn freePayload(allocator: std.mem.Allocator, header: *Header) void {
    const obj = object(header);
    const cap = obj.capacity;
    switch (header.kind()) {
        .generic_spine => freeItems(Value, allocator, obj.payload, cap),
        .leaf_i64 => freeItems(i64, allocator, obj.payload, cap),
        .leaf_f64 => freeItems(f64, allocator, obj.payload, cap),
        .leaf_char1 => freeItems(u8, allocator, obj.payload, cap),
        .leaf_char2 => freeItems(u16, allocator, obj.payload, cap),
        .leaf_char4 => freeItems(u32, allocator, obj.payload, cap),
        .leaf_symbol => freeItems(u32, allocator, obj.payload, cap),
        .dict => {
            const storage = dictStorage(header);
            if (storage.index) |index| allocator.free(index[0..storage.index_len]);
            allocator.destroy(storage);
        },
        .reserved_mask => {},
    }
    obj.payload = null;
    obj.capacity = 0;
}

fn freeItems(
    comptime T: type,
    allocator: std.mem.Allocator,
    payload: ?*anyopaque,
    count: usize,
) void {
    if (count == 0) return;
    const ptr: [*]T = @ptrCast(@alignCast(payload.?));
    allocator.free(ptr[0..count]);
}

pub fn replaceBuffer(
    comptime T: type,
    allocator: std.mem.Allocator,
    header: *Header,
    new_capacity: usize,
) error{OutOfMemory}!void {
    const obj = object(header);
    const old_capacity = obj.capacity;
    if (old_capacity == 0) {
        const replacement = try allocator.alloc(T, new_capacity);
        obj.payload = @ptrCast(replacement.ptr);
    } else {
        const ptr: [*]T = @ptrCast(@alignCast(obj.payload.?));
        const replacement = try allocator.realloc(ptr[0..old_capacity], new_capacity);
        obj.payload = @ptrCast(replacement.ptr);
    }
    obj.capacity = new_capacity;
}

/// Replaces a unique object's representation after the caller has prepared a
/// complete new buffer. Existing children are released iteratively.
pub fn replaceRepresentation(
    allocator: std.mem.Allocator,
    header: *Header,
    new_kind: HeapKind,
    new_len: usize,
    new_capacity: usize,
    new_payload: ?*anyopaque,
) void {
    std.debug.assert(isUnique(header));
    var work: ?*Header = null;
    releaseChildren(header, &work);
    while (work) |current| {
        const obj = object(current);
        work = obj.next_destroy;
        releaseChildren(current, &work);
        freePayload(allocator, current);
        allocator.destroy(obj);
    }
    freePayload(allocator, header);
    const obj = object(header);
    obj.capacity = new_capacity;
    obj.payload = new_payload;
    header.setKind(new_kind);
    header.len = new_len;
}

/// Moves a fully-built representation into a unique destination header. The
/// source wrapper is destroyed, while its payload becomes owned by dest.
pub fn adoptRepresentation(
    allocator: std.mem.Allocator,
    dest: *Header,
    source: *Header,
) void {
    std.debug.assert(dest != source);
    std.debug.assert(isUnique(dest));
    std.debug.assert(isUnique(source));
    const source_obj = object(source);
    const source_kind = source.kind();
    const source_len = source.len;
    const source_capacity = source_obj.capacity;
    const source_payload = source_obj.payload;
    source_obj.capacity = 0;
    source_obj.payload = null;
    source.len = 0;
    source.setKind(.reserved_mask);
    replaceRepresentation(
        allocator,
        dest,
        source_kind,
        @intCast(source_len),
        source_capacity,
        source_payload,
    );
    decRef(allocator, source);
}

fn allocationFailureProbe(allocator: std.mem.Allocator) !void {
    const kinds = [_]HeapKind{
        .generic_spine,
        .leaf_i64,
        .leaf_f64,
        .leaf_char1,
        .leaf_char2,
        .leaf_char4,
        .leaf_symbol,
        .dict,
        .reserved_mask,
    };
    var headers: [kinds.len]*Header = undefined;
    var initialized: usize = 0;
    defer for (headers[0..initialized]) |header| decRef(allocator, header);
    for (kinds) |kind_value| {
        headers[initialized] = try allocHeader(allocator, kind_value, 0, 8);
        initialized += 1;
    }
}

test "reference-count lifecycle is precise and leak-free" {
    const allocator = std.testing.allocator;
    const header = try allocHeader(allocator, .leaf_i64, 0, 4);
    try std.testing.expect(isUnique(header));
    incRef(header);
    try std.testing.expect(!isUnique(header));
    decRef(allocator, header);
    try std.testing.expect(isUnique(header));
    decRef(allocator, header);
}

test "deep spine destruction is iterative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var current = try allocHeader(allocator, .generic_spine, 0, 1);
    for (0..100_000) |_| {
        const parent = try allocHeader(allocator, .generic_spine, 1, 1);
        values(parent)[0] = .{ .list = current };
        current = parent;
    }
    decRef(allocator, current);
}

const ReferenceContext = struct {
    allocator: std.mem.Allocator,
    header: *Header,
};

fn referenceWorker(context: ReferenceContext) void {
    for (0..20_000) |_| {
        incRef(context.header);
        _ = context.header.len;
        // The root test owner keeps the allocation alive across this drop.
        decRef(context.allocator, context.header);
    }
}

test "reference counting remains exact across threads" {
    const allocator = std.testing.allocator;
    const header = try allocHeader(allocator, .leaf_i64, 0, 4);
    defer decRef(allocator, header);
    const context = ReferenceContext{ .allocator = allocator, .header = header };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, referenceWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(isUnique(header));
}

test "allocHeader reports every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}
