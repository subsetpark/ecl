//! Heap allocation and precise atomic reference counting.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const ListHandle = value.ListHandle;
pub const DictHandle = value.DictHandle;
pub const TaskHandle = value.TaskHandle;
pub const HeapKind = value.HeapKind;
pub const DictPayload = value.DictPayload;

/// Capabilities are nominal opaque pointers with the same address as Header.
/// Only this module can issue them without an explicit unsafe cast.
const InitializingList = opaque {};
const InitializingDict = opaque {};
const InitializingTask = opaque {};
const UniqueHeader = opaque {};
pub const UniqueList = opaque {};
pub const UniqueDict = opaque {};

/// Makes copy-on-write ownership visible to callers. `in_place` aliases the
/// caller's existing owner; `replacement` is one additional owned root.
pub const UpdateResult = union(enum) {
    in_place: Value,
    replacement: Value,

    pub fn value(self: UpdateResult) Value {
        return switch (self) {
            inline else => |item| item,
        };
    }
};

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

pub const DictStorage = union(enum) {
    initializing,
    ready: struct {
        payload: DictPayload,
        index: ?[]u32 = null,
    },

    pub fn payload(self: *const DictStorage) *const DictPayload {
        return switch (self.*) {
            .initializing => unreachable,
            .ready => |*ready| &ready.payload,
        };
    }

    pub fn index(self: *const DictStorage) ?[]const u32 {
        return switch (self.*) {
            .initializing => unreachable,
            .ready => |ready| ready.index,
        };
    }
};

pub const TaskStorage = struct {
    identity: u64,
    payload: *anyopaque,
    destroy: *const fn (std.mem.Allocator, *anyopaque) ?Value,
};

const Object = struct {
    header: HeaderImpl,
    capacity: usize,
    payload: ?*anyopaque,
    next_destroy: ?*Header,
    destroy_index: usize,
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

fn initializingImpl(header: anytype) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn initializingHeader(header: anytype) *Header {
    return @ptrCast(@alignCast(header));
}

fn uniqueImpl(header: *UniqueHeader) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

pub fn kind(header: *const Header) HeapKind {
    return headerImplConst(header).kind();
}

pub fn headerFromList(handle: *ListHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

pub fn headerFromDict(handle: *DictHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

pub fn headerFromTask(handle: *TaskHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

fn mutableHeader(handle: anytype) *Header {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn listKind(handle: *ListHandle) HeapKind {
    const result = kind(headerFromList(handle));
    std.debug.assert(switch (result) {
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => true,
        .dict, .task, .reserved_mask => false,
    });
    return result;
}

pub fn listLength(handle: *ListHandle) u64 {
    return length(headerFromList(handle));
}

pub fn dictLength(handle: *DictHandle) u64 {
    return length(headerFromDict(handle));
}

pub fn length(header: *const Header) u64 {
    return headerImplConst(header).len;
}

pub fn refCount(handle: anytype) u32 {
    return headerImplConst(@ptrCast(@alignCast(handle))).rc.load(.acquire);
}

fn publishList(header: *InitializingList) *ListHandle {
    return @ptrCast(@alignCast(header));
}

fn publishDict(header: *InitializingDict) *DictHandle {
    return @ptrCast(@alignCast(header));
}

fn publishTask(header: *InitializingTask) *TaskHandle {
    return @ptrCast(@alignCast(header));
}

fn initializingLength(header: *const InitializingList) u64 {
    const impl: *const HeaderImpl = @ptrCast(@alignCast(header));
    return impl.len;
}

fn setInitializingLength(header: *InitializingList, new_len: usize) void {
    std.debug.assert(new_len <= object(initializingHeader(header)).capacity);
    initializingImpl(header).len = new_len;
}

fn claimUniqueHeader(header: *Header) ?*UniqueHeader {
    if (headerImpl(header).rc.load(.acquire) != 1) return null;
    return @ptrCast(@alignCast(header));
}

pub fn claimUniqueList(handle: *ListHandle) ?*UniqueList {
    const unique = claimUniqueHeader(mutableHeader(handle)) orelse return null;
    return @ptrCast(@alignCast(unique));
}

pub fn claimUniqueDict(handle: *DictHandle) ?*UniqueDict {
    const unique = claimUniqueHeader(mutableHeader(handle)) orelse return null;
    return @ptrCast(@alignCast(unique));
}

pub fn uniqueHeader(header: *UniqueHeader) *Header {
    return @ptrCast(@alignCast(header));
}

pub fn capacity(handle: anytype) usize {
    const header: *const Header = @ptrCast(@alignCast(handle));
    return objectConst(header).capacity;
}

fn allocObject(
    allocator: std.mem.Allocator,
    kind_value: HeapKind,
    len_value: usize,
    capacity_value: usize,
) error{OutOfMemory}!*Header {
    std.debug.assert(len_value <= capacity_value or kind_value == .dict);
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    obj.* = .{
        .header = HeaderImpl.init(kind_value, len_value),
        .capacity = capacity_value,
        .payload = null,
        .next_destroy = null,
        .destroy_index = 0,
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
        .task => unreachable,
        .reserved_mask => null,
    };
    return @ptrCast(@alignCast(&obj.header));
}

fn allocListHeader(
    allocator: std.mem.Allocator,
    kind_value: HeapKind,
    len_value: usize,
    capacity_value: usize,
) error{OutOfMemory}!*InitializingList {
    std.debug.assert(switch (kind_value) {
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => true,
        .dict, .task, .reserved_mask => false,
    });
    return @ptrCast(@alignCast(try allocObject(allocator, kind_value, len_value, capacity_value)));
}

pub fn ListBuilder(comptime kind_value: HeapKind) type {
    const Element = switch (kind_value) {
        .generic_spine => Value,
        .leaf_i64 => i64,
        .leaf_f64 => f64,
        .leaf_char1 => u8,
        .leaf_char2 => u16,
        .leaf_char4, .leaf_symbol => u32,
        .dict, .task, .reserved_mask => @compileError("ListBuilder requires a list representation"),
    };
    return struct {
        const Self = @This();
        pub const Item = Element;

        header: ?*InitializingList,

        pub fn init(
            allocator: std.mem.Allocator,
            len_value: usize,
            capacity_value: usize,
        ) error{OutOfMemory}!Self {
            return .{ .header = try allocListHeader(
                allocator,
                kind_value,
                len_value,
                capacity_value,
            ) };
        }

        pub fn items(self: *const Self) []Element {
            return payloadItems(Element, initializingHeader(self.header.?));
        }

        pub fn len(self: *const Self) usize {
            return @intCast(initializingLength(self.header.?));
        }

        pub fn capacity(self: *const Self) usize {
            return object(initializingHeader(self.header.?)).capacity;
        }

        pub fn setLen(self: *Self, new_len: usize) void {
            setInitializingLength(self.header.?, new_len);
        }

        pub fn finish(self: *Self) *ListHandle {
            const header = self.header.?;
            self.header = null;
            return publishList(header);
        }

        pub fn retirePartial(self: *Self, releases: *ReleaseDomain) void {
            if (self.header) |header| releases.releaseHeader(publishList(header));
            self.header = null;
        }
    };
}

/// Runtime-selected list construction is still a closed sum of typed
/// builders. Each variant exposes only the element operations valid for that
/// representation; no caller receives a raw initializing header.
pub const AnyListBuilder = union(enum) {
    generic: ListBuilder(.generic_spine),
    i64: ListBuilder(.leaf_i64),
    f64: ListBuilder(.leaf_f64),
    char1: ListBuilder(.leaf_char1),
    char2: ListBuilder(.leaf_char2),
    char4: ListBuilder(.leaf_char4),
    symbol: ListBuilder(.leaf_symbol),

    pub fn init(
        allocator: std.mem.Allocator,
        kind_value: HeapKind,
        len_value: usize,
        capacity_value: usize,
    ) error{OutOfMemory}!AnyListBuilder {
        return switch (kind_value) {
            .generic_spine => .{ .generic = try .init(allocator, len_value, capacity_value) },
            .leaf_i64 => .{ .i64 = try .init(allocator, len_value, capacity_value) },
            .leaf_f64 => .{ .f64 = try .init(allocator, len_value, capacity_value) },
            .leaf_char1 => .{ .char1 = try .init(allocator, len_value, capacity_value) },
            .leaf_char2 => .{ .char2 = try .init(allocator, len_value, capacity_value) },
            .leaf_char4 => .{ .char4 = try .init(allocator, len_value, capacity_value) },
            .leaf_symbol => .{ .symbol = try .init(allocator, len_value, capacity_value) },
            .dict, .task, .reserved_mask => unreachable,
        };
    }

    pub fn finish(self: *AnyListBuilder) *ListHandle {
        return switch (self.*) {
            inline else => |*builder| builder.finish(),
        };
    }

    pub fn retirePartial(self: *AnyListBuilder, releases: *ReleaseDomain) void {
        switch (self.*) {
            inline else => |*builder| builder.retirePartial(releases),
        }
    }

    pub fn writeCodepoint(self: *AnyListBuilder, index: usize, codepoint: u32) void {
        switch (self.*) {
            .char1 => |*builder| builder.items()[index] = @intCast(codepoint),
            .char2 => |*builder| builder.items()[index] = @intCast(codepoint),
            .char4 => |*builder| builder.items()[index] = codepoint,
            else => unreachable,
        }
    }

    pub fn writeValue(self: *AnyListBuilder, index: usize, item: Value) void {
        switch (self.*) {
            .generic => |*builder| {
                retainValue(item);
                builder.items()[index] = item;
                builder.setLen(index + 1);
            },
            .i64 => |*builder| builder.items()[index] = item.int,
            .f64 => |*builder| builder.items()[index] = item.float,
            .char1 => |*builder| builder.items()[index] = @intCast(item.char),
            .char2 => |*builder| builder.items()[index] = @intCast(item.char),
            .char4 => |*builder| builder.items()[index] = item.char,
            .symbol => |*builder| builder.items()[index] = item.symbol,
        }
    }
};

fn allocDictHeader(
    allocator: std.mem.Allocator,
    len_value: usize,
) error{OutOfMemory}!*InitializingDict {
    const object_header = try allocObject(allocator, .dict, len_value, len_value);
    const initializing: *InitializingDict = @ptrCast(@alignCast(object_header));
    initDictStorage(initializing).* = .initializing;
    return initializing;
}

/// Representation-specific construction capability for dictionary storage.
/// Only `finish` can expose a DictHandle, and it requires the complete payload
/// and optional index in one transition.
pub const DictBuilder = struct {
    header: ?*InitializingDict,

    pub fn init(allocator: std.mem.Allocator, len_value: usize) error{OutOfMemory}!DictBuilder {
        return .{ .header = try allocDictHeader(allocator, len_value) };
    }

    pub fn finish(self: *DictBuilder, payload: DictPayload, index: ?[]u32) *DictHandle {
        const header = self.header.?;
        initDictStorage(header).* = .{ .ready = .{ .payload = payload, .index = index } };
        self.header = null;
        return publishDict(header);
    }

    pub fn retirePartial(self: *DictBuilder, releases: *ReleaseDomain) void {
        if (self.header) |header| releases.releaseHeader(publishDict(header));
        self.header = null;
    }
};

fn allocTaskHeader(
    allocator: std.mem.Allocator,
    identity: u64,
    payload: *anyopaque,
    destroy: *const fn (std.mem.Allocator, *anyopaque) ?Value,
) error{OutOfMemory}!*InitializingTask {
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    const storage = try allocator.create(TaskStorage);
    storage.* = .{ .identity = identity, .payload = payload, .destroy = destroy };
    obj.* = .{
        .header = HeaderImpl.init(.task, identity),
        .capacity = 0,
        .payload = @ptrCast(storage),
        .next_destroy = null,
        .destroy_index = 0,
    };
    return @ptrCast(@alignCast(&obj.header));
}

fn TaskDestroyAdapter(comptime Payload: type) type {
    return struct {
        fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) ?Value {
            const payload: *Payload = @ptrCast(@alignCast(raw));
            return Payload.destroy(allocator, payload);
        }
    };
}

/// Allocates and publishes task storage with a destructor derived from the
/// concrete payload type. Raw payload casts cannot be paired at call sites.
pub fn createTask(
    comptime Payload: type,
    allocator: std.mem.Allocator,
    identity: u64,
    payload: *Payload,
) error{OutOfMemory}!*TaskHandle {
    const initializing = try allocTaskHeader(
        allocator,
        identity,
        @ptrCast(payload),
        TaskDestroyAdapter(Payload).destroy,
    );
    return publishTask(initializing);
}

pub fn taskStorage(header: *const TaskHandle) *const TaskStorage {
    return @ptrCast(@alignCast(objectConst(headerFromTask(@constCast(header))).payload.?));
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

pub fn valuesConst(header: *ListHandle) []const Value {
    std.debug.assert(listKind(header) == .generic_spine);
    return payloadItems(Value, mutableHeader(header));
}

pub fn i64s(header: *ListHandle) []const i64 {
    std.debug.assert(listKind(header) == .leaf_i64);
    return payloadItems(i64, mutableHeader(header));
}

pub fn f64s(header: *ListHandle) []const f64 {
    std.debug.assert(listKind(header) == .leaf_f64);
    return payloadItems(f64, mutableHeader(header));
}

pub fn chars8(header: *ListHandle) []const u8 {
    std.debug.assert(listKind(header) == .leaf_char1);
    return payloadItems(u8, mutableHeader(header));
}

pub fn chars16(header: *ListHandle) []const u16 {
    std.debug.assert(listKind(header) == .leaf_char2);
    return payloadItems(u16, mutableHeader(header));
}

pub fn chars32(header: *ListHandle) []const u32 {
    std.debug.assert(listKind(header) == .leaf_char4);
    return payloadItems(u32, mutableHeader(header));
}

pub fn symbols(header: *ListHandle) []const u32 {
    std.debug.assert(listKind(header) == .leaf_symbol);
    return payloadItems(u32, mutableHeader(header));
}

fn initValues(header: *InitializingList) []Value {
    std.debug.assert(initializingImpl(header).kind() == .generic_spine);
    return payloadItems(Value, initializingHeader(header));
}

fn initI64s(header: *InitializingList) []i64 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_i64);
    return payloadItems(i64, initializingHeader(header));
}

fn initF64s(header: *InitializingList) []f64 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_f64);
    return payloadItems(f64, initializingHeader(header));
}

fn initChars8(header: *InitializingList) []u8 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_char1);
    return payloadItems(u8, initializingHeader(header));
}

fn initChars16(header: *InitializingList) []u16 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_char2);
    return payloadItems(u16, initializingHeader(header));
}

fn initChars32(header: *InitializingList) []u32 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_char4);
    return payloadItems(u32, initializingHeader(header));
}

fn initSymbols(header: *InitializingList) []u32 {
    std.debug.assert(initializingImpl(header).kind() == .leaf_symbol);
    return payloadItems(u32, initializingHeader(header));
}

pub fn writeUniqueList(list_header: *UniqueList, index: usize, item: Value) void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
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
        .dict, .task, .reserved_mask => unreachable,
    }
}

pub fn setUniqueListLength(list_header: *UniqueList, new_len: usize) void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
    std.debug.assert(new_len <= capacity(uniqueHeader(header)));
    uniqueImpl(header).len = new_len;
}

fn initDictStorage(header: *InitializingDict) *DictStorage {
    return @ptrCast(@alignCast(object(initializingHeader(header)).payload.?));
}

pub fn dictStorageConst(header: *const DictHandle) *const DictStorage {
    return @ptrCast(@alignCast(objectConst(headerFromDict(@constCast(header))).payload.?));
}

pub fn incRef(handle: anytype) void {
    const old = headerImpl(mutableHeader(handle)).rc.fetchAdd(1, .monotonic);
    std.debug.assert(old != 0 and old != std.math.maxInt(u32));
}

/// The sole copy-on-write gate in the codebase (decision 23).
pub fn isUnique(handle: anytype) bool {
    return headerImplConst(@ptrCast(@alignCast(handle))).rc.load(.acquire) == 1;
}

pub fn retainValue(item: Value) void {
    switch (item) {
        .int, .float, .char, .symbol, .word => {},
        .list => |header| incRef(header),
        .dict => |header| incRef(header),
        .task => |header| incRef(header),
    }
}

/// Allocator-only cleanup exists only in test builds. Production code cannot
/// name this namespace and must present an explicit host capability or enqueue
/// into its owning `ReleaseDomain`.
pub const testing = if (builtin.is_test) struct {
    pub const Cleanup = struct {
        owner: HostOwner,

        pub fn init(allocator: std.mem.Allocator) Cleanup {
            return .{ .owner = HostOwner.init(allocator) };
        }

        pub fn domain(self: *Cleanup) *ReleaseDomain {
            return self.owner.domain();
        }

        pub fn capability(self: *const Cleanup) *const HostCleanup {
            return self.owner.cleanup();
        }

        pub fn deinit(self: *Cleanup) void {
            self.capability().drain();
        }
    };

    pub fn releaseValue(allocator: std.mem.Allocator, item: Value) void {
        var owner = HostOwner.init(allocator);
        owner.domain().releaseValue(item);
        owner.cleanup().drain();
    }
    pub fn decRef(allocator: std.mem.Allocator, handle: anytype) void {
        var owner = HostOwner.init(allocator);
        owner.domain().releaseHeader(handle);
        owner.cleanup().drain();
    }
} else struct {};

/// Opaque host ownership is issued by exactly one `HostOwner`. Root-owned
/// objects derive allocation and retirement from this capability; blocking
/// drain remains available only to host-side owners that retain it.
pub const HostCleanup = opaque {
    /// Drains only the reclamation domain that issued this capability.
    pub fn drain(self: *const HostCleanup) void {
        hostDomain(self).drainOwned();
    }

    pub fn allocator(self: *const HostCleanup) std.mem.Allocator {
        return hostDomain(self).allocator;
    }
};

/// Root runtime owners store one opaque host capability and derive resources
/// from it. A cached allocator or domain would make cross-owner pairing a
/// writable struct state again.
pub fn requireSingleHostCapability(comptime Root: type) void {
    if (!@hasField(Root, "host") or @FieldType(Root, "host") != *const HostCleanup)
        @compileError(@typeName(Root) ++ " must store exactly its opaque HostCleanup capability");
    const root_info = @typeInfo(Root).@"struct";
    inline for (root_info.fields) |field| {
        if (field.type == std.mem.Allocator or field.type == *ReleaseDomain)
            @compileError(@typeName(Root) ++ " must derive allocator and domain from HostCleanup");
    }
}

pub fn requireOpaqueHostRoot(comptime Handle: type, comptime State: type) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized handle"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized handle");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "consumed") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its consumed state");
    }
    requireSingleHostCapability(State);
}

/// Worker-visible scheduler authority is a non-owning facade. It may retain
/// private allocator/domain execution resources, but it cannot contain host
/// cleanup authority or expose lifecycle operations.
pub fn requireOpaqueWorkerFacade(comptime Handle: type, comptime State: type) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized facade"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized facade");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "invalid") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its invalid state");
    }
    if (@hasDecl(Handle, "settleRootRetirement") or @hasDecl(Handle, "deinit"))
        @compileError(@typeName(Handle) ++ " must not expose host lifecycle control");
    const state_info = switch (@typeInfo(State)) {
        .@"struct" => |info| info,
        else => @compileError(@typeName(State) ++ " must be private worker state"),
    };
    inline for (state_info.fields) |field| {
        if (field.type == *const HostCleanup or
            field.type == *HostCleanup or
            field.type == *const HostOwner or
            field.type == *HostOwner)
        {
            @compileError(@typeName(State) ++ " must not retain host cleanup authority");
        }
    }
}

pub fn requireOpaqueObservation(comptime Handle: type) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized observation handle"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized observation handle");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "invalid") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its invalid state");
    }
    if (@hasDecl(Handle, "deinit"))
        @compileError(@typeName(Handle) ++ " must not own or retire its observed target");
}

/// A session domain stores only its owner. Allocator and retirement access
/// must remain derived methods so the correlated resources cannot diverge.
pub fn requireSingleHostOwner(comptime State: type) void {
    if (!@hasField(State, "host_owner") or @FieldType(State, "host_owner") != *HostOwner)
        @compileError(@typeName(State) ++ " must store exactly one HostOwner pointer");
    const state_info = @typeInfo(State).@"struct";
    inline for (state_info.fields) |field| {
        if (field.type == std.mem.Allocator or
            field.type == *ReleaseDomain or
            field.type == *const HostCleanup or
            field.type == *HostCleanup)
        {
            @compileError(@typeName(State) ++ " must derive allocator and domain from HostOwner");
        }
    }
}

/// Allocator-scoped retirement queue. Dropping a value performs only the
/// atomic ownership transition and an intrusive queue insertion; graph edges
/// and payload frees are processed by bounded scheduler/root turns.
pub const ReleaseDomain = struct {
    /// Intrusive storage for non-Value runtime retirement. Owners embed one
    /// node and expose `advanceRetirement(domain, allocator) bool`; the typed
    /// adapter is the only erased callback seam. Returning false requeues the
    /// same owner for a later bounded quantum.
    pub const Retirement = struct {
        next: ?*Retirement = null,
        context: ?*anyopaque = null,
        advance_fn: ?*const fn (*ReleaseDomain, std.mem.Allocator, *anyopaque) bool = null,
    };
    const Wake = struct {
        context: *anyopaque,
        wake_fn: *const fn (*anyopaque) void,
    };

    allocator: std.mem.Allocator,
    queue_mutex: std.Io.Mutex = .init,
    drain_mutex: std.Io.Mutex = .init,
    first: ?*Header = null,
    last: ?*Header = null,
    retirement_first: ?*Retirement = null,
    retirement_last: ?*Retirement = null,
    prefer_retirement: bool = false,
    wake: ?Wake = null,

    pub fn init(allocator: std.mem.Allocator) ReleaseDomain {
        return .{ .allocator = allocator };
    }

    pub fn releaseValue(self: *ReleaseDomain, item: Value) void {
        if (item.heapHeader()) |header| self.releaseHeader(header);
    }

    pub fn attachWake(self: *ReleaseDomain, owner: anytype) void {
        const Pointer = @TypeOf(owner);
        const pointer = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("retirement wake owner must be a pointer"),
        };
        if (pointer.size != .one) @compileError("retirement wake owner must be a single-item pointer");
        const adapters = RetirementWakeAdapters(pointer.child);
        std.debug.assert(self.wake == null);
        self.wake = .{ .context = @ptrCast(owner), .wake_fn = adapters.wake };
    }

    pub fn detachWake(self: *ReleaseDomain) void {
        self.wake = null;
    }

    pub fn retire(self: *ReleaseDomain, owner: anytype, node: *Retirement) void {
        const Pointer = @TypeOf(owner);
        const pointer = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("retirement owner must be a pointer"),
        };
        if (pointer.size != .one) @compileError("retirement owner must be a single-item pointer");
        const adapters = RetirementAdapters(pointer.child);
        std.debug.assert(node.context == null and node.advance_fn == null and node.next == null);
        node.context = @ptrCast(owner);
        node.advance_fn = adapters.advance;
        self.enqueueRetirement(node);
    }

    pub fn releaseHeader(self: *ReleaseDomain, handle: anytype) void {
        const header = mutableHeader(handle);
        const old = headerImpl(header).rc.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = headerImpl(header).rc.load(.acquire);
        self.enqueueZero(header);
    }

    fn enqueueZero(self: *ReleaseDomain, header: *Header) void {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        std.debug.assert(object(header).next_destroy == null);
        if (self.last) |last| object(last).next_destroy = header else self.first = header;
        self.last = header;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        self.notifyWork();
    }

    fn enqueueRetirement(self: *ReleaseDomain, node: *Retirement) void {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        std.debug.assert(node.next == null);
        if (self.retirement_last) |last| last.next = node else self.retirement_first = node;
        self.retirement_last = node;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        self.notifyWork();
    }

    fn notifyWork(self: *ReleaseDomain) void {
        if (self.wake) |wake| wake.wake_fn(wake.context);
    }

    fn popZero(self: *ReleaseDomain) ?*Header {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        const header = self.first orelse {
            std.Io.Threaded.mutexUnlock(&self.queue_mutex);
            return null;
        };
        self.first = object(header).next_destroy;
        if (self.first == null) self.last = null;
        object(header).next_destroy = null;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        return header;
    }

    fn popRetirement(self: *ReleaseDomain) ?*Retirement {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        const node = self.retirement_first orelse {
            std.Io.Threaded.mutexUnlock(&self.queue_mutex);
            return null;
        };
        self.retirement_first = node.next;
        if (self.retirement_first == null) self.retirement_last = null;
        node.next = null;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        return node;
    }

    pub fn hasPending(self: *ReleaseDomain) bool {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        return self.first != null or self.retirement_first != null;
    }

    /// Returns true when the queue is empty after at most `budget` object-edge
    /// transitions. Multiple workers may help, but payload destruction is
    /// serialized so every intrusive node has one active owner.
    pub fn advance(self: *ReleaseDomain, budget: usize) bool {
        std.debug.assert(budget != 0);
        std.Io.Threaded.mutexLock(&self.drain_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.drain_mutex);
        return self.advanceLocked(budget);
    }

    /// Scheduler-facing nonblocking turn. A second worker never queues behind
    /// the active retirement owner; it remains available for runnable work.
    pub fn tryAdvance(self: *ReleaseDomain, budget: usize) ?bool {
        std.debug.assert(budget != 0);
        if (!self.drain_mutex.tryLock()) return null;
        defer std.Io.Threaded.mutexUnlock(&self.drain_mutex);
        return self.advanceLocked(budget);
    }

    fn advanceLocked(self: *ReleaseDomain, budget: usize) bool {
        for (0..budget) |_| {
            if (self.prefer_retirement) {
                if (self.popRetirement()) |node| {
                    self.prefer_retirement = false;
                    const advance_fn = node.advance_fn.?;
                    const context = node.context.?;
                    if (!advance_fn(self, self.allocator, context)) {
                        self.enqueueRetirement(node);
                    }
                    continue;
                }
            }
            if (self.popZero()) |header| {
                self.prefer_retirement = true;
                if (self.releaseNextChild(header)) {
                    self.enqueueZero(header);
                } else {
                    freePayload(self.allocator, header);
                    self.allocator.destroy(object(header));
                }
                continue;
            }
            if (self.popRetirement()) |node| {
                self.prefer_retirement = false;
                const advance_fn = node.advance_fn.?;
                const context = node.context.?;
                if (!advance_fn(self, self.allocator, context)) {
                    self.enqueueRetirement(node);
                }
                continue;
            }
            return true;
        }
        return !self.hasPending();
    }

    fn drainOwned(self: *ReleaseDomain) void {
        while (!self.advance(65_536)) {}
    }

    fn releaseNextChild(self: *ReleaseDomain, header: *Header) bool {
        const obj = object(header);
        switch (kind(header)) {
            .generic_spine => {
                const used: usize = @intCast(length(header));
                if (obj.destroy_index == used) return false;
                const child = valuesConst(@ptrCast(@alignCast(header)))[obj.destroy_index];
                obj.destroy_index += 1;
                self.releaseValue(child);
                return true;
            },
            .dict => {
                const storage = dictStorageConst(@ptrCast(@alignCast(header)));
                const payload = switch (storage.*) {
                    .initializing => return false,
                    .ready => |ready| ready.payload,
                };
                const child = switch (obj.destroy_index) {
                    0 => payload.keys,
                    1 => payload.vals,
                    2 => payload.hashes,
                    else => return false,
                };
                obj.destroy_index += 1;
                self.releaseHeader(child);
                return true;
            },
            .task => {
                if (obj.destroy_index != 0) return false;
                obj.destroy_index = 1;
                const storage: *TaskStorage = @constCast(taskStorage(@ptrCast(@alignCast(header))));
                if (storage.destroy(self.allocator, storage.payload)) |child| self.releaseValue(child);
                return true;
            },
            .leaf_i64,
            .leaf_f64,
            .leaf_char1,
            .leaf_char2,
            .leaf_char4,
            .leaf_symbol,
            .reserved_mask,
            => return false,
        }
    }
};

/// Host-side ownership of a retirement domain and its blocking-cleanup seal.
/// The owner is kept outside every scheduler-attached type; workers receive
/// only `domain()`, while shutdown code may additionally borrow `cleanup()`.
pub const HostOwner = struct {
    cleanup_seal: u8 = 0,
    releases: ReleaseDomain,

    pub fn init(allocator: std.mem.Allocator) HostOwner {
        return .{ .releases = .init(allocator) };
    }

    pub fn domain(self: *HostOwner) *ReleaseDomain {
        return &self.releases;
    }

    pub fn cleanup(self: *const HostOwner) *const HostCleanup {
        return @ptrCast(&self.cleanup_seal);
    }
};

fn cleanupOwner(host: *const HostCleanup) *const HostOwner {
    const seal: *const u8 = @ptrCast(host);
    return @alignCast(@fieldParentPtr("cleanup_seal", seal));
}

pub fn hostDomain(host: *const HostCleanup) *ReleaseDomain {
    return &@constCast(cleanupOwner(host)).releases;
}

fn RetirementAdapters(comptime Owner: type) type {
    return struct {
        fn advance(
            domain: *ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) bool {
            const owner: *Owner = @ptrCast(@alignCast(raw));
            return Owner.advanceRetirement(domain, allocator, owner);
        }
    };
}

fn RetirementWakeAdapters(comptime Owner: type) type {
    return struct {
        fn wake(raw: *anyopaque) void {
            const owner: *Owner = @ptrCast(@alignCast(raw));
            Owner.wakeRetirement(owner);
        }
    };
}

/// A movable ownership capability. The optional payload is the state: an
/// empty capability has transferred or retired its value and cannot drop it a
/// second time.
pub const OwnedValue = struct {
    domain: *ReleaseDomain,
    item: ?Value,

    pub fn init(domain: *ReleaseDomain, item: Value) OwnedValue {
        return .{ .domain = domain, .item = item };
    }

    pub fn borrow(self: *const OwnedValue) Value {
        return self.item.?;
    }

    pub fn take(self: *OwnedValue) Value {
        const item = self.item.?;
        self.item = null;
        return item;
    }

    pub fn deinit(self: *OwnedValue) void {
        if (self.item) |item| self.domain.releaseValue(item);
        self.item = null;
    }
};

/// Exact-capacity, non-relocating ownership for a partially initialized value
/// sequence. Abandonment retires one heap root; it never loops over the
/// initialized prefix on the caller's stack.
pub const OwnedValueBuffer = union(enum) {
    building: struct {
        domain: *ReleaseDomain,
        builder: ListBuilder(.generic_spine),
    },
    moved,

    pub fn init(domain: *ReleaseDomain, capacity_value: usize) error{OutOfMemory}!OwnedValueBuffer {
        return .{ .building = .{
            .domain = domain,
            .builder = try ListBuilder(.generic_spine).init(domain.allocator, 0, capacity_value),
        } };
    }

    pub fn len(self: *const OwnedValueBuffer) usize {
        return switch (self.*) {
            .building => |building| building.builder.len(),
            .moved => unreachable,
        };
    }

    pub fn capacity(self: *const OwnedValueBuffer) usize {
        return switch (self.*) {
            .building => |building| building.builder.capacity(),
            .moved => unreachable,
        };
    }

    pub fn values(self: *const OwnedValueBuffer) []const Value {
        return switch (self.*) {
            .building => |building| building.builder.items()[0..self.len()],
            .moved => unreachable,
        };
    }

    pub fn appendOwned(self: *OwnedValueBuffer, item: Value) void {
        switch (self.*) {
            .building => |*building| {
                const index = building.builder.len();
                std.debug.assert(index < building.builder.capacity());
                building.builder.items()[index] = item;
                building.builder.setLen(index + 1);
            },
            .moved => unreachable,
        }
    }

    pub fn appendBorrowed(self: *OwnedValueBuffer, item: Value) void {
        retainValue(item);
        self.appendOwned(item);
    }

    pub fn takeList(self: *OwnedValueBuffer) Value {
        return switch (self.*) {
            .building => |*building| result: {
                const result: Value = .{ .list = building.builder.finish() };
                self.* = .moved;
                break :result result;
            },
            .moved => unreachable,
        };
    }

    pub fn take(self: *OwnedValueBuffer) OwnedValueBuffer {
        return switch (self.*) {
            .building => |building| result: {
                self.* = .moved;
                break :result .{ .building = building };
            },
            .moved => unreachable,
        };
    }

    pub fn deinit(self: *OwnedValueBuffer) void {
        switch (self.*) {
            .building => |*building| building.builder.retirePartial(building.domain),
            .moved => {},
        }
        self.* = .moved;
    }
};

/// Non-relocating ownership for an unknown number of values. Fixed-size heap
/// chunks form a backwards generic-spine chain, so abandonment retires one
/// root and the release domain walks every prior chunk within its normal
/// budget. Metadata may keep borrowed copies of the values independently.
pub const OwnedValueChain = union(enum) {
    building: struct {
        domain: *ReleaseDomain,
        builder: ListBuilder(.generic_spine),
    },
    moved,

    const chunk_capacity = 257;

    pub fn init(domain: *ReleaseDomain) error{OutOfMemory}!OwnedValueChain {
        return .{ .building = .{
            .domain = domain,
            .builder = try ListBuilder(.generic_spine).init(domain.allocator, 0, chunk_capacity),
        } };
    }

    /// Consumes `item` on both success and allocation failure.
    pub fn appendOwned(self: *OwnedValueChain, item: Value) error{OutOfMemory}!void {
        switch (self.*) {
            .building => |*building| {
                var index = building.builder.len();
                if (index == chunk_capacity) {
                    var next = ListBuilder(.generic_spine).init(
                        building.domain.allocator,
                        1,
                        chunk_capacity,
                    ) catch {
                        building.domain.releaseValue(item);
                        return error.OutOfMemory;
                    };
                    next.items()[0] = .{ .list = building.builder.finish() };
                    building.builder = next;
                    index = 1;
                }
                building.builder.items()[index] = item;
                building.builder.setLen(index + 1);
            },
            .moved => unreachable,
        }
    }

    pub fn appendBorrowed(self: *OwnedValueChain, item: Value) error{OutOfMemory}!void {
        retainValue(item);
        return self.appendOwned(item);
    }

    pub fn deinit(self: *OwnedValueChain) void {
        switch (self.*) {
            .building => |*building| building.builder.retirePartial(building.domain),
            .moved => {},
        }
        self.* = .moved;
    }
};

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
            const storage: *DictStorage = @constCast(dictStorageConst(@ptrCast(@alignCast(header))));
            switch (storage.*) {
                .initializing => {},
                .ready => |ready| if (ready.index) |index| allocator.free(index),
            }
            allocator.destroy(storage);
        },
        .task => {
            const storage: *TaskStorage = @constCast(taskStorage(@ptrCast(@alignCast(header))));
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
    list_header: *UniqueList,
    new_capacity: usize,
) error{OutOfMemory}!void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
    const raw = uniqueHeader(header);
    return switch (uniqueImpl(header).kind()) {
        .generic_spine => resizePayload(Value, allocator, raw, new_capacity),
        .leaf_i64 => resizePayload(i64, allocator, raw, new_capacity),
        .leaf_f64 => resizePayload(f64, allocator, raw, new_capacity),
        .leaf_char1 => resizePayload(u8, allocator, raw, new_capacity),
        .leaf_char2 => resizePayload(u16, allocator, raw, new_capacity),
        .leaf_char4, .leaf_symbol => resizePayload(u32, allocator, raw, new_capacity),
        .dict, .task, .reserved_mask => unreachable,
    };
}

/// Moves a fully-built representation into a unique destination header. The
/// consumed source wrapper receives the destination's old representation and
/// is retired through the sole graph-reclamation implementation.
pub fn adoptListRepresentationDeferred(
    releases: *ReleaseDomain,
    dest: *UniqueList,
    source: *UniqueList,
) void {
    adoptRepresentationDeferred(
        releases,
        @ptrCast(@alignCast(dest)),
        @ptrCast(@alignCast(source)),
    );
}

pub fn adoptDictRepresentationDeferred(
    releases: *ReleaseDomain,
    dest: *UniqueDict,
    source: *UniqueDict,
) void {
    adoptRepresentationDeferred(
        releases,
        @ptrCast(@alignCast(dest)),
        @ptrCast(@alignCast(source)),
    );
}

fn adoptRepresentationDeferred(
    releases: *ReleaseDomain,
    dest: *UniqueHeader,
    source: *UniqueHeader,
) void {
    const dest_raw = uniqueHeader(dest);
    const source_raw = uniqueHeader(source);
    std.debug.assert(dest_raw != source_raw);
    const dest_obj = object(dest_raw);
    const source_obj = object(source_raw);
    std.debug.assert(dest_obj.next_destroy == null and source_obj.next_destroy == null);

    const dest_kind = uniqueImpl(dest).kind();
    const dest_len = uniqueImpl(dest).len;
    const dest_capacity = dest_obj.capacity;
    const dest_payload = dest_obj.payload;
    const source_kind = uniqueImpl(source).kind();
    const source_len = uniqueImpl(source).len;
    const source_capacity = source_obj.capacity;
    const source_payload = source_obj.payload;

    dest_obj.capacity = source_capacity;
    dest_obj.payload = source_payload;
    dest_obj.destroy_index = 0;
    uniqueImpl(dest).setKind(source_kind);
    uniqueImpl(dest).len = source_len;

    source_obj.capacity = dest_capacity;
    source_obj.payload = dest_payload;
    source_obj.destroy_index = 0;
    uniqueImpl(source).setKind(dest_kind);
    uniqueImpl(source).len = dest_len;
    releases.releaseHeader(source_raw);
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
    };
    var headers: [kinds.len]*ListHandle = undefined;
    var initialized: usize = 0;
    defer for (headers[0..initialized]) |header| testing.decRef(allocator, header);
    for (kinds) |kind_value| {
        headers[initialized] = publishList(try allocListHeader(allocator, kind_value, 0, 8));
        initialized += 1;
    }
    const dictionary = publishDict(try allocDictHeader(allocator, 0));
    defer testing.decRef(allocator, dictionary);
}

test "reference-count lifecycle is precise and leak-free" {
    const allocator = std.testing.allocator;
    const header = publishList(try allocListHeader(allocator, .leaf_i64, 0, 4));
    try std.testing.expect(isUnique(header));
    incRef(header);
    try std.testing.expect(!isUnique(header));
    testing.decRef(allocator, header);
    try std.testing.expect(isUnique(header));
    testing.decRef(allocator, header);
}

test "deep spine destruction is iterative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var current = publishList(try allocListHeader(allocator, .generic_spine, 0, 1));
    for (0..100_000) |_| {
        const parent = try allocListHeader(allocator, .generic_spine, 1, 1);
        initValues(parent)[0] = .{ .list = current };
        current = publishList(parent);
    }
    testing.decRef(allocator, current);
}

test "release domain suspends wide value destruction at its budget" {
    const allocator = std.testing.allocator;
    const width = 65_537;
    const initializing = try allocListHeader(allocator, .generic_spine, width, width);
    for (initValues(initializing)) |*item| item.* = .{ .int = 1 };
    var host = HostOwner.init(allocator);
    const releases = host.domain();
    releases.releaseHeader(publishList(initializing));
    try std.testing.expect(!releases.advance(1024));
    host.cleanup().drain();
}

const ReferenceContext = struct {
    allocator: std.mem.Allocator,
    header: *ListHandle,
};

fn referenceWorker(context: ReferenceContext) void {
    for (0..20_000) |_| {
        incRef(context.header);
        _ = context.header.length();
        // The root test owner keeps the allocation alive across this drop.
        testing.decRef(context.allocator, context.header);
    }
}

test "reference counting remains exact across threads" {
    const allocator = std.testing.allocator;
    const header = publishList(try allocListHeader(allocator, .leaf_i64, 0, 4));
    defer testing.decRef(allocator, header);
    const context = ReferenceContext{ .allocator = allocator, .header = header };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, referenceWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(isUnique(header));
}

test "typed heap factories report every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}

test "typed list builders retire every initialized generic prefix" {
    const allocator = std.testing.allocator;
    var host = HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var child_builder = try ListBuilder(.leaf_i64).init(allocator, 1, 1);
    child_builder.items()[0] = 7;
    const child = Value{ .list = child_builder.finish() };
    defer releases.releaseValue(child);

    for (0..257) |prefix| {
        var builder = try AnyListBuilder.init(allocator, .generic_spine, 0, prefix);
        for (0..prefix) |index| builder.writeValue(index, child);
        builder.retirePartial(releases);
        host.cleanup().drain();
        try std.testing.expectEqual(@as(u32, 1), refCount(child.list));
    }
}
