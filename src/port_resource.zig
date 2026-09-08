//! Registered resource lifecycle and provisional publication. Adapters bind
//! semantic callbacks at construction; the core owns their identity and pins
//! without depending on any concrete backend type.
const std = @import("std");
const scheduler = @import("scheduler.zig");
const heap = @import("heap.zig");
const external = @import("external.zig");
const transport = @import("port_bytes.zig");
const Value = @import("value.zig").Value;

pub const Shutdown = union(enum) { pending, ready, unsupported, failed: transport.Failure };
pub const Initialization = union(enum) { ready, pending: external.ReadinessSource, failed: transport.Failure };
pub const PublicationMode = enum { direct, staged };

const ProvisionalTable = struct {
    mutex: *const fn (*anyopaque) *std.Io.Mutex,
    group: *const fn (*anyopaque) ?*scheduler.ExternalGroup,
    ownership: *const fn (*anyopaque) *external.Ownership,
    publish: *const fn (*anyopaque) void,
    member: *const fn (*anyopaque) external.ScopeMember,
};
const Table = struct {
    initialization: *const fn (*anyopaque) Initialization,
    close: *const fn (*anyopaque) void,
    joined: *const fn (*anyopaque) bool,
    source: *const fn (*anyopaque) external.ReadinessSource,
    shutdown: *const fn (*anyopaque) Shutdown,
    release: *const fn (*anyopaque) void,
    prepare: *const fn (*anyopaque, *anyopaque, *anyopaque) heap.PortTransferError!void,
    commit: *const fn (*anyopaque) void,
    abort: *const fn (*anyopaque) void,
};
const State = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    payload: *anyopaque,
    type_id: *const u8,
    table: *const Table,
    provisional: ?*const ProvisionalTable,
};
fn Bridge(comptime Adapter: type) type {
    return struct {
        // Mutable storage gives each adapter a nominal, non-mergeable identity.
        var identity: u8 = 0;
        fn typed(raw: *anyopaque) *Adapter {
            return @ptrCast(@alignCast(raw));
        }
        fn close(raw: *anyopaque) void {
            typed(raw).resourceClose();
        }
        fn initialization(raw: *anyopaque) Initialization {
            return typed(raw).resourceInitialization();
        }
        fn joined(raw: *anyopaque) bool {
            return typed(raw).resourceJoined();
        }
        fn source(raw: *anyopaque) external.ReadinessSource {
            return typed(raw).resourceSource();
        }
        fn shutdown(raw: *anyopaque) Shutdown {
            return typed(raw).resourceShutdown();
        }
        fn release(raw: *anyopaque) void {
            typed(raw).releasePort();
        }
        fn prepare(raw: *anyopaque, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
            return typed(raw).prepareScopeTransfer(from, to);
        }
        fn commit(raw: *anyopaque) void {
            typed(raw).commitScopeTransfer();
        }
        fn abort(raw: *anyopaque) void {
            typed(raw).abortScopeTransfer();
        }
        const table: Table = .{ .initialization = initialization, .close = close, .joined = joined, .source = source, .shutdown = shutdown, .release = release, .prepare = prepare, .commit = commit, .abort = abort };
        fn mutex(raw: *anyopaque) *std.Io.Mutex {
            return typed(raw).resourcePublicationMutex();
        }
        fn group(raw: *anyopaque) ?*scheduler.ExternalGroup {
            return typed(raw).resourcePublicationGroupLocked();
        }
        fn ownership(raw: *anyopaque) *external.Ownership {
            return typed(raw).resourceOwnershipLocked();
        }
        fn publish(raw: *anyopaque) void {
            typed(raw).resourceMarkPublishedLocked();
        }
        fn member(raw: *anyopaque) external.ScopeMember {
            return typed(raw).resourceMember();
        }
        const provisional: ProvisionalTable = .{ .mutex = mutex, .group = group, .ownership = ownership, .publish = publish, .member = member };
    };
}

/// Registered resource semantics, shared by every adapter. Only registration
/// sees its concrete type; consumers cannot recover backend authority.
pub const Resource = opaque {
    fn state(self: *Resource) *State {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes one adapter reference. Failure retains that reference.
    /// Allocation authority is derived from the adapter's owning resource.
    pub fn create(comptime Adapter: type, comptime publication: PublicationMode, identity: u64, adapter: *Adapter) error{OutOfMemory}!Value {
        const allocator = adapter.resourceAllocator();
        const owned = try allocator.create(State);
        errdefer allocator.destroy(owned);
        owned.* = .{ .allocator = allocator, .payload = adapter, .type_id = &Bridge(Adapter).identity, .table = &Bridge(Adapter).table, .provisional = switch (publication) {
            .direct => null,
            .staged => &Bridge(Adapter).provisional,
        } };
        return heap.createOwnedPort(Resource, .resource, allocator, identity, @ptrCast(owned));
    }
    pub fn fromValue(item: Value) ?*Resource {
        if (item != .port) return null;
        return heap.portPayload(Resource, .resource, item.port);
    }
    /// Adapter-side typed projection. A different registered adapter cannot
    /// reinterpret a resource, including after its backend has closed.
    pub fn project(comptime Adapter: type, item: Value) ?*Adapter {
        const self = fromValue(item) orelse return null;
        if (self.state().type_id != &Bridge(Adapter).identity) return null;
        return @ptrCast(@alignCast(self.state().payload));
    }
    pub fn close(self: *Resource) void {
        self.state().table.close(self.state().payload);
    }
    pub fn initialization(self: *Resource) Initialization {
        return self.state().table.initialization(self.state().payload);
    }
    pub fn joined(self: *Resource) bool {
        return self.state().table.joined(self.state().payload);
    }
    pub fn source(self: *Resource) external.ReadinessSource {
        return self.state().table.source(self.state().payload);
    }
    pub fn shutdown(self: *Resource) Shutdown {
        return self.state().table.shutdown(self.state().payload);
    }
    pub fn prepareScopeTransfer(self: *Resource, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return self.state().table.prepare(self.state().payload, from, to);
    }
    pub fn commitScopeTransfer(self: *Resource) void {
        self.state().table.commit(self.state().payload);
    }
    pub fn abortScopeTransfer(self: *Resource) void {
        self.state().table.abort(self.state().payload);
    }
    fn retain(self: *Resource) void {
        _ = self.state().refs.fetchAdd(1, .monotonic);
    }
    pub fn releasePort(self: *Resource) void {
        const owned = self.state();
        if (owned.refs.fetchSub(1, .acq_rel) != 1) return;
        owned.table.release(owned.payload);
        owned.allocator.destroy(owned);
    }
};

/// Registration explicitly grants provisional publication authority. Sharing
/// an already-published resource never changes its owning scope.
const ProvisionalResource = struct {
    resource: *Resource,

    fn fromHandle(handle: *heap.PortHandle) ?ProvisionalResource {
        const resource = Resource.fromValue(.{ .port = handle }) orelse return null;
        if (resource.state().provisional == null) return null;
        return .{ .resource = resource };
    }
    fn identity(self: ProvisionalResource) usize {
        return @intFromPtr(self.resource.state().payload);
    }
    fn mutex(self: ProvisionalResource) *std.Io.Mutex {
        const owned = self.resource.state();
        return owned.provisional.?.mutex(owned.payload);
    }
    fn groupLocked(self: ProvisionalResource) ?*scheduler.ExternalGroup {
        const owned = self.resource.state();
        return owned.provisional.?.group(owned.payload);
    }
    fn ownershipLocked(self: ProvisionalResource) *external.Ownership {
        const owned = self.resource.state();
        return owned.provisional.?.ownership(owned.payload);
    }
    fn markPublishedLocked(self: ProvisionalResource) void {
        const owned = self.resource.state();
        owned.provisional.?.publish(owned.payload);
    }
    fn member(self: ProvisionalResource) external.ScopeMember {
        const owned = self.resource.state();
        return owned.provisional.?.member(owned.payload);
    }
    fn retainReadiness(self: ProvisionalResource) void {
        self.resource.retain();
    }
    fn releaseReadiness(self: ProvisionalResource) void {
        self.resource.releasePort();
    }
};

/// A fixed ownership snapshot for an atomic message/result claim. Snapshot
/// pins and replaced memberships retire only after all publication locks are
/// released. A changed snapshot is rejected; it never grants stale authority.
const PublicationState = struct {
    const Entry = struct {
        cell: ProvisionalResource,
        group: *scheduler.ExternalGroup,
        membership: bool,
        detached: external.Ownership.Detached = .{},
    };
    host: *const heap.HostCleanup,
    entries: [16]?Entry = .{null} ** 16,
    groups: [16]?*scheduler.ExternalGroup = .{null} ** 16,
    count: usize = 0,
    group_count: usize = 0,
    published: bool = false,

    fn capability(self: *PublicationState) *Publication {
        return @ptrCast(self);
    }

    fn init(host: *const heap.HostCleanup, attachments: []const ?*heap.PortHandle) error{Overflow}!PublicationState {
        var result: PublicationState = .{ .host = host };
        errdefer result.releasePins();
        for (attachments) |attachment| {
            const cell = ProvisionalResource.fromHandle(attachment orelse continue) orelse continue;
            var duplicate = false;
            for (result.entries[0..result.count]) |entry| if (entry.?.cell.identity() == cell.identity()) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            std.Io.Threaded.mutexLock(cell.mutex());
            if (cell.groupLocked() == null) {
                std.Io.Threaded.mutexUnlock(cell.mutex());
                continue;
            }
            if (result.count == result.entries.len) {
                std.Io.Threaded.mutexUnlock(cell.mutex());
                return error.Overflow;
            }
            const group = cell.groupLocked().?;
            const membership = cell.ownershipLocked().* == .owned;
            cell.retainReadiness();
            group.retain();
            std.Io.Threaded.mutexUnlock(cell.mutex());
            var index = result.count;
            while (index != 0 and result.entries[index - 1].?.cell.identity() > cell.identity()) : (index -= 1)
                result.entries[index] = result.entries[index - 1];
            result.entries[index] = .{ .cell = cell, .group = group, .membership = membership };
            result.count += 1;
            var group_index: usize = 0;
            while (group_index < result.group_count and @intFromPtr(result.groups[group_index].?) < @intFromPtr(group)) : (group_index += 1) {}
            if (group_index < result.group_count and result.groups[group_index].? == group) continue;
            var move = result.group_count;
            while (move > group_index) : (move -= 1) result.groups[move] = result.groups[move - 1];
            result.groups[group_index] = group;
            result.group_count += 1;
        }
        return result;
    }
    pub fn members(self: *@This()) [16]?external.ScopeMember {
        var result: [16]?external.ScopeMember = .{null} ** 16;
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.?.membership) result[index] = entry.?.cell.member();
        }
        return result;
    }
    pub fn lock(self: *@This()) void {
        for (self.groups[0..self.group_count]) |group| group.?.lockPublication();
        for (self.entries[0..self.count]) |entry| std.Io.Threaded.mutexLock(entry.?.cell.mutex());
    }
    pub fn unlock(self: *@This()) void {
        var index = self.count;
        while (index != 0) {
            index -= 1;
            std.Io.Threaded.mutexUnlock(self.entries[index].?.cell.mutex());
        }
        index = self.group_count;
        while (index != 0) {
            index -= 1;
            self.groups[index].?.unlockPublication();
        }
    }
    pub fn validate(self: *@This()) bool {
        for (self.groups[0..self.group_count]) |group| if (!group.?.acceptsPublicationLocked()) return false;
        for (self.entries[0..self.count]) |entry| {
            const item = entry.?;
            if (item.cell.groupLocked() != item.group) return false;
            if (item.membership) {
                if (item.cell.ownershipLocked().* != .owned or !item.group.ownsMembership(item.cell.ownershipLocked().owned)) return false;
            } else if (item.cell.ownershipLocked().* != .none) return false;
        }
        return true;
    }
    pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
        for (self.entries[0..self.count], 0..) |*entry, index| {
            const item = &entry.*.?;
            if (item.membership) {
                item.detached = item.cell.ownershipLocked().release();
                item.cell.ownershipLocked().* = .{ .owned = tokens[index].? };
            }
            item.cell.markPublishedLocked();
        }
        self.published = true;
    }
    fn releasePins(self: *@This()) void {
        for (self.entries[0..self.count]) |*entry| {
            const item = &entry.*.?;
            item.detached.detachAll();
            if (self.published) item.group.release();
            item.group.release();
            item.cell.releaseReadiness();
        }
    }
};

pub const Publication = opaque {
    fn state(self: *@This()) *PublicationState {
        return @ptrCast(@alignCast(self));
    }
    pub fn init(host: *const heap.HostCleanup, attachments: []const ?*heap.PortHandle) error{ OutOfMemory, Overflow }!?*Publication {
        var snapshot = try PublicationState.init(host, attachments);
        errdefer snapshot.releasePins();
        if (snapshot.count == 0) return null;
        const owned = try host.allocator().create(PublicationState);
        owned.* = snapshot;
        return owned.capability();
    }
    pub fn members(self: *@This()) [16]?external.ScopeMember {
        return self.state().members();
    }
    pub fn lock(self: *@This()) void {
        self.state().lock();
    }
    pub fn unlock(self: *@This()) void {
        self.state().unlock();
    }
    pub fn validate(self: *@This()) bool {
        return self.state().validate();
    }
    pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
        self.state().publish(tokens);
    }
    pub fn deinit(self: *@This()) void {
        const owned = self.state();
        owned.releasePins();
        owned.host.allocator().destroy(owned);
    }
};
