//! Heap allocation and precise atomic reference counting.

const std = @import("std");
const value = @import("value.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const HeapKind = value.HeapKind;
pub const DictPayload = value.DictPayload;

/// Capabilities are nominal opaque pointers with the same address as Header.
/// Only this module can issue them without an explicit unsafe cast.
pub const InitializingHeader = opaque {};
pub const UniqueHeader = opaque {};

const HeaderImpl = extern struct {
    rc: std.atomic.Value(u32),
    meta: u32,
    len: u64,

    const kind_mask: u32 = 0xff;

    fn init(kind_value: HeapKind, len_value: u64) HeaderImpl {
        return .{
            .rc = .init(1),
            .meta = @intFromEnum(kind_value),
            .len = len_value,
        };
    }

    fn kind(self: *const HeaderImpl) HeapKind {
        return @enumFromInt(self.meta & kind_mask);
    }

    fn setKind(self: *HeaderImpl, new_kind: HeapKind) void {
        self.meta = (self.meta & ~kind_mask) | @intFromEnum(new_kind);
    }
};

comptime {
    if (@sizeOf(HeaderImpl) != 16) @compileError("heap header must remain exactly 16 bytes");
}

pub const DictStorage = struct {
    payload: ?DictPayload = null,
    initialized: bool = false,
    index: ?[*]u32 = null,
    index_len: usize = 0,
};

const Object = struct {
    header: HeaderImpl,
    capacity: usize,
    payload: ?*anyopaque,
    next_destroy: ?*Header,
};

fn object(header: *Header) *Object {
    return @fieldParentPtr("header", headerImpl(header));
}

fn objectConst(header: *const Header) *const Object {
    return @fieldParentPtr("header", headerImplConst(header));
}

fn headerImpl(header: *Header) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn headerImplConst(header: *const Header) *const HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn initializingImpl(header: *InitializingHeader) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn uniqueImpl(header: *UniqueHeader) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

pub fn kind(header: *const Header) HeapKind {
    return headerImplConst(header).kind();
}

pub fn length(header: *const Header) u64 {
    return headerImplConst(header).len;
}

pub fn refCount(header: *const Header) u32 {
    return headerImplConst(header).rc.load(.acquire);
}

pub fn publish(header: *InitializingHeader) *Header {
    return @ptrCast(@alignCast(header));
}

pub fn initializingLength(header: *const InitializingHeader) u64 {
    const impl: *const HeaderImpl = @ptrCast(@alignCast(header));
    return impl.len;
}

pub fn setInitializingLength(header: *InitializingHeader, new_len: usize) void {
    std.debug.assert(new_len <= object(publish(header)).capacity or initializingImpl(header).kind() == .dict);
    initializingImpl(header).len = new_len;
}

pub fn claimUnique(header: *Header) ?*UniqueHeader {
    if (headerImpl(header).rc.load(.acquire) != 1) return null;
    return @ptrCast(@alignCast(header));
}

pub fn uniqueHeader(header: *UniqueHeader) *Header {
    return @ptrCast(@alignCast(header));
}

pub fn capacity(header: *const Header) usize {
    return objectConst(header).capacity;
}

pub fn allocHeader(
    allocator: std.mem.Allocator,
    kind_value: HeapKind,
    len_value: usize,
    capacity_value: usize,
) error{OutOfMemory}!*InitializingHeader {
    std.debug.assert(len_value <= capacity_value or kind_value == .dict);
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    obj.* = .{
        .header = HeaderImpl.init(kind_value, len_value),
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
    const initializing: *InitializingHeader = @ptrCast(@alignCast(&obj.header));
    if (kind_value == .dict) initDictStorage(initializing).* = .{};
    return initializing;
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

fn payloadItems(comptime T: type, header: *Header) []T {
    const cap = capacity(header);
    if (cap == 0) return &.{};
    const ptr: [*]T = @ptrCast(@alignCast(object(header).payload.?));
    return ptr[0..cap];
}

pub fn valuesConst(header: *const Header) []const Value {
    std.debug.assert(kind(header) == .generic_spine);
    return payloadItems(Value, @constCast(header));
}

pub fn i64s(header: *const Header) []const i64 {
    std.debug.assert(kind(header) == .leaf_i64);
    return payloadItems(i64, @constCast(header));
}

pub fn f64s(header: *const Header) []const f64 {
    std.debug.assert(kind(header) == .leaf_f64);
    return payloadItems(f64, @constCast(header));
}

pub fn chars8(header: *const Header) []const u8 {
    std.debug.assert(kind(header) == .leaf_char1);
    return payloadItems(u8, @constCast(header));
}

pub fn chars16(header: *const Header) []const u16 {
    std.debug.assert(kind(header) == .leaf_char2);
    return payloadItems(u16, @constCast(header));
}

pub fn chars32(header: *const Header) []const u32 {
    std.debug.assert(kind(header) == .leaf_char4);
    return payloadItems(u32, @constCast(header));
}

pub fn symbols(header: *const Header) []const u32 {
    std.debug.assert(kind(header) == .leaf_symbol);
    return payloadItems(u32, @constCast(header));
}

pub fn initValues(header: *InitializingHeader) []Value {
    std.debug.assert(initializingImpl(header).kind() == .generic_spine);
    return payloadItems(Value, publish(header));
}

pub fn initI64s(header: *InitializingHeader) []i64 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_i64);
    return payloadItems(i64, publish(header));
}

pub fn initF64s(header: *InitializingHeader) []f64 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_f64);
    return payloadItems(f64, publish(header));
}

pub fn initChars8(header: *InitializingHeader) []u8 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_char1);
    return payloadItems(u8, publish(header));
}

pub fn initChars16(header: *InitializingHeader) []u16 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_char2);
    return payloadItems(u16, publish(header));
}

pub fn initChars32(header: *InitializingHeader) []u32 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_char4);
    return payloadItems(u32, publish(header));
}

pub fn initSymbols(header: *InitializingHeader) []u32 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_symbol);
    return payloadItems(u32, publish(header));
}

pub fn writeUnique(header: *UniqueHeader, index: usize, item: Value) void {
    const raw = uniqueHeader(header);
    std.debug.assert(index < capacity(raw));
    switch (uniqueImpl(header).kind()) {
        .generic_spine => payloadItems(Value, raw)[index] = item,
        .leaf_i64 => payloadItems(i64, raw)[index] = item.int,
        .leaf_f64 => payloadItems(f64, raw)[index] = item.float,
        .leaf_char1 => payloadItems(u8, raw)[index] = @intCast(item.char),
        .leaf_char2 => payloadItems(u16, raw)[index] = @intCast(item.char),
        .leaf_char4 => payloadItems(u32, raw)[index] = item.char,
        .leaf_symbol => payloadItems(u32, raw)[index] = item.symbol,
        .dict, .reserved_mask => unreachable,
    }
}

pub fn setUniqueLength(header: *UniqueHeader, new_len: usize) void {
    std.debug.assert(new_len <= capacity(uniqueHeader(header)));
    uniqueImpl(header).len = new_len;
}

pub fn initDictStorage(header: *InitializingHeader) *DictStorage {
    std.debug.assert(initializingImpl(header).kind() == .dict);
    return @ptrCast(@alignCast(object(publish(header)).payload.?));
}

pub fn dictStorageConst(header: *const Header) *const DictStorage {
    std.debug.assert(kind(header) == .dict);
    return @ptrCast(@alignCast(objectConst(header).payload.?));
}

pub fn incRef(header: *Header) void {
    const old = headerImpl(header).rc.fetchAdd(1, .monotonic);
    std.debug.assert(old != 0 and old != std.math.maxInt(u32));
}

/// The sole copy-on-write gate in the codebase (decision 23).
pub fn isUnique(header: *const Header) bool {
    return headerImplConst(header).rc.load(.acquire) == 1;
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
    const old = headerImpl(header).rc.fetchSub(1, .release);
    std.debug.assert(old != 0);
    if (old != 1) return;
    _ = headerImpl(header).rc.load(.acquire);
    object(header).next_destroy = work.*;
    work.* = header;
}

fn releaseChildren(header: *Header, work: *?*Header) void {
    switch (kind(header)) {
        .generic_spine => {
            const used: usize = @intCast(length(header));
            for (valuesConst(header)[0..used]) |child| {
                if (child.heapHeader()) |child_header| releaseOnto(child_header, work);
            }
        },
        .dict => {
            const storage = dictStorageConst(header);
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
    switch (kind(header)) {
        .generic_spine => freeItems(Value, allocator, obj.payload, cap),
        .leaf_i64 => freeItems(i64, allocator, obj.payload, cap),
        .leaf_f64 => freeItems(f64, allocator, obj.payload, cap),
        .leaf_char1 => freeItems(u8, allocator, obj.payload, cap),
        .leaf_char2 => freeItems(u16, allocator, obj.payload, cap),
        .leaf_char4 => freeItems(u32, allocator, obj.payload, cap),
        .leaf_symbol => freeItems(u32, allocator, obj.payload, cap),
        .dict => {
            const storage: *DictStorage = @constCast(dictStorageConst(header));
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

fn resizePayload(
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

pub fn replaceBuffer(
    allocator: std.mem.Allocator,
    header: *UniqueHeader,
    new_capacity: usize,
) error{OutOfMemory}!void {
    const raw = uniqueHeader(header);
    return switch (uniqueImpl(header).kind()) {
        .generic_spine => resizePayload(Value, allocator, raw, new_capacity),
        .leaf_i64 => resizePayload(i64, allocator, raw, new_capacity),
        .leaf_f64 => resizePayload(f64, allocator, raw, new_capacity),
        .leaf_char1 => resizePayload(u8, allocator, raw, new_capacity),
        .leaf_char2 => resizePayload(u16, allocator, raw, new_capacity),
        .leaf_char4, .leaf_symbol => resizePayload(u32, allocator, raw, new_capacity),
        .dict, .reserved_mask => unreachable,
    };
}

/// Replaces a unique object's representation after the caller has prepared a
/// complete new buffer. Existing children are released iteratively.
fn replaceRepresentation(
    allocator: std.mem.Allocator,
    header: *UniqueHeader,
    new_kind: HeapKind,
    new_len: usize,
    new_capacity: usize,
    new_payload: ?*anyopaque,
) void {
    const raw = uniqueHeader(header);
    var work: ?*Header = null;
    releaseChildren(raw, &work);
    while (work) |current| {
        const obj = object(current);
        work = obj.next_destroy;
        releaseChildren(current, &work);
        freePayload(allocator, current);
        allocator.destroy(obj);
    }
    freePayload(allocator, raw);
    const obj = object(raw);
    obj.capacity = new_capacity;
    obj.payload = new_payload;
    uniqueImpl(header).setKind(new_kind);
    uniqueImpl(header).len = new_len;
}

/// Moves a fully-built representation into a unique destination header. The
/// source wrapper is destroyed, while its payload becomes owned by dest.
pub fn adoptRepresentation(
    allocator: std.mem.Allocator,
    dest: *UniqueHeader,
    source: *UniqueHeader,
) void {
    const dest_raw = uniqueHeader(dest);
    const source_raw = uniqueHeader(source);
    std.debug.assert(dest_raw != source_raw);
    const source_obj = object(source_raw);
    const source_kind = uniqueImpl(source).kind();
    const source_len = uniqueImpl(source).len;
    const source_capacity = source_obj.capacity;
    const source_payload = source_obj.payload;
    source_obj.capacity = 0;
    source_obj.payload = null;
    uniqueImpl(source).len = 0;
    uniqueImpl(source).setKind(.reserved_mask);
    replaceRepresentation(
        allocator,
        dest,
        source_kind,
        @intCast(source_len),
        source_capacity,
        source_payload,
    );
    decRef(allocator, source_raw);
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
        headers[initialized] = publish(try allocHeader(allocator, kind_value, 0, 8));
        initialized += 1;
    }
}

test "reference-count lifecycle is precise and leak-free" {
    const allocator = std.testing.allocator;
    const header = publish(try allocHeader(allocator, .leaf_i64, 0, 4));
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
    var current = publish(try allocHeader(allocator, .generic_spine, 0, 1));
    for (0..100_000) |_| {
        const parent = try allocHeader(allocator, .generic_spine, 1, 1);
        initValues(parent)[0] = .{ .list = current };
        current = publish(parent);
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
        _ = length(context.header);
        // The root test owner keeps the allocation alive across this drop.
        decRef(context.allocator, context.header);
    }
}

test "reference counting remains exact across threads" {
    const allocator = std.testing.allocator;
    const header = publish(try allocHeader(allocator, .leaf_i64, 0, 4));
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
