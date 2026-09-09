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

pub const PublicationStatus = union(enum) { published, provisional: *scheduler.ExternalGroup, revoked };

const AuthorityState = struct {
    allocator: std.mem.Allocator,
    phase: union(enum) { provisional: *scheduler.ExternalGroup, published, revoked: *scheduler.ExternalGroup },
};

/// Service-owned authority. All transitions require the service mutex; group
/// arbitration additionally requires the group's publication lock. Revocation
/// retains only a reclamation pin, never permission to attach a membership.
pub const PublicationAuthority = opaque {
    fn state(self: *@This()) *AuthorityState {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(allocator: std.mem.Allocator, group: *scheduler.ExternalGroup) error{OutOfMemory}!*PublicationAuthority {
        const owned = try allocator.create(AuthorityState);
        group.retain();
        owned.* = .{ .allocator = allocator, .phase = .{ .provisional = group } };
        return @ptrCast(owned);
    }
    pub fn statusLocked(self: *@This()) PublicationStatus {
        return switch (self.state().phase) {
            .provisional => |group| .{ .provisional = group },
            .published => .published,
            .revoked => .revoked,
        };
    }
    pub fn revokeLocked(self: *@This()) void {
        if (self.state().phase == .provisional) {
            const group = self.state().phase.provisional;
            self.state().phase = .{ .revoked = group };
        }
    }
    /// Transfers the original group pin to the transaction's retirement.
    pub fn publishLocked(self: *@This()) void {
        if (self.state().phase != .provisional) @panic("publication authority already consumed");
        self.state().phase = .published;
    }
    pub fn deinit(self: *@This()) void {
        const owned = self.state();
        switch (owned.phase) {
            .provisional, .revoked => |group| group.release(),
            .published => {},
        }
        owned.allocator.destroy(owned);
    }
};

const ProvisionalTable = struct {
    mutex: *const fn (*anyopaque) *std.Io.Mutex,
    group: *const fn (*anyopaque) PublicationStatus,
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
        fn group(raw: *anyopaque) PublicationStatus {
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
    fn groupLocked(self: ProvisionalResource) PublicationStatus {
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
/// released. A changed snapshot retries; revoked authority is terminal.
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
    revoked: bool = false,

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
            const group = switch (cell.groupLocked()) {
                .published => {
                    std.Io.Threaded.mutexUnlock(cell.mutex());
                    continue;
                },
                .revoked => {
                    result.revoked = true;
                    std.Io.Threaded.mutexUnlock(cell.mutex());
                    continue;
                },
                .provisional => |group| group,
            };
            if (result.count == result.entries.len) {
                std.Io.Threaded.mutexUnlock(cell.mutex());
                return error.Overflow;
            }
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
    pub fn validate(self: *@This()) Outcome {
        if (self.revoked) return .rejected;
        var changed = false;
        for (self.entries[0..self.count]) |entry| {
            const item = entry.?;
            switch (item.cell.groupLocked()) {
                .revoked => return .rejected,
                .published => {
                    changed = true;
                    continue;
                },
                .provisional => |group| {
                    if (group != item.group) {
                        changed = true;
                        continue;
                    }
                    if (!group.acceptsPublicationLocked()) return .rejected;
                },
            }
            if (item.membership) {
                if (item.cell.ownershipLocked().* != .owned or !item.group.ownsMembership(item.cell.ownershipLocked().owned)) changed = true;
            } else if (item.cell.ownershipLocked().* != .none) changed = true;
        }
        return if (changed) .retry else .ready;
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

pub const Outcome = enum { ready, retry, rejected };

pub const Publication = opaque {
    fn state(self: *@This()) *PublicationState {
        return @ptrCast(@alignCast(self));
    }
    fn init(host: *const heap.HostCleanup, attachments: []const ?*heap.PortHandle) error{ OutOfMemory, Overflow }!?*Publication {
        var snapshot = try PublicationState.init(host, attachments);
        errdefer snapshot.releasePins();
        if (snapshot.count == 0 and !snapshot.revoked) return null;
        const owned = try host.allocator().create(PublicationState);
        owned.* = snapshot;
        return owned.capability();
    }
    /// Delivery owners supply locked identity validation, detachment and commit.
    /// Rejection detaches under locks; each owner retires the detached envelope
    /// after this call returns. Prepared allocation failure leaves it available.
    pub fn deliver(host: *const heap.HostCleanup, attachments: []const ?*heap.PortHandle, scope: *scheduler.TaskScope, owner: anytype) error{ OutOfMemory, ScopeClosing, Overflow }!void {
        const handoff = try init(host, attachments);
        defer if (handoff) |publication| publication.deinit();
        const Transaction = struct {
            owner: @TypeOf(owner),
            handoff: ?*Publication,
            pub fn lock(self: *@This()) void {
                self.owner.lock();
                if (self.handoff) |publication| publication.lock();
            }
            pub fn unlock(self: *@This()) void {
                if (self.handoff) |publication| publication.unlock();
                self.owner.unlock();
            }
            pub fn validate(self: *@This()) bool {
                if (!self.owner.validate()) return false;
                switch (if (self.handoff) |publication| publication.validate() else .ready) {
                    .ready => return true,
                    .retry => return false,
                    .rejected => {
                        self.owner.reject();
                        return false;
                    },
                }
            }
            pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
                if (self.handoff) |publication| publication.publish(tokens);
                self.owner.publish();
            }
        };
        var transaction: Transaction = .{ .owner = owner, .handoff = handoff };
        _ = try scope.scheduler.publishExternalBatch(scope, if (handoff) |publication| publication.members() else .{null} ** 16, &transaction);
    }
    fn members(self: *@This()) [16]?external.ScopeMember {
        return self.state().members();
    }
    pub fn lock(self: *@This()) void {
        self.state().lock();
    }
    pub fn unlock(self: *@This()) void {
        self.state().unlock();
    }
    pub fn validate(self: *@This()) Outcome {
        return self.state().validate();
    }
    pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
        self.state().publish(tokens);
    }
    fn deinit(self: *@This()) void {
        const owned = self.state();
        owned.releasePins();
        owned.host.allocator().destroy(owned);
    }
};

// Registration-backed fixture: the test observes real queue/result delivery,
// scope membership, cancellation callbacks, and allocator leak accounting.
const PublicationProbe = struct {
    const Parent = struct {
        pub fn retainReadiness(_: *@This()) void {}
        pub fn releaseReadiness(_: *@This()) void {}
        pub fn childrenClosed(_: *@This()) void {}
    };
    const Child = struct {
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        authority: *PublicationAuthority,
        ownership: external.Ownership = .none,
        refs: usize = 1,
        pub fn resourceAllocator(self: *@This()) std.mem.Allocator {
            return self.allocator;
        }
        pub fn resourceInitialization(_: *@This()) Initialization {
            return .ready;
        }
        pub fn resourceClose(self: *@This()) void {
            std.Io.Threaded.mutexLock(&self.mutex);
            self.authority.revokeLocked();
            std.Io.Threaded.mutexUnlock(&self.mutex);
        }
        pub fn resourceJoined(_: *@This()) bool {
            return true;
        }
        pub fn resourceSource(_: *@This()) external.ReadinessSource {
            @panic("no pending probe I/O");
        }
        pub fn resourceShutdown(_: *@This()) Shutdown {
            return .ready;
        }
        pub fn releasePort(self: *@This()) void {
            self.refs -= 1;
        }
        pub fn prepareScopeTransfer(_: *@This(), _: *anyopaque, _: *anyopaque) heap.PortTransferError!void {
            return error.Closed;
        }
        pub fn commitScopeTransfer(_: *@This()) void {}
        pub fn abortScopeTransfer(_: *@This()) void {}
        pub fn resourcePublicationMutex(self: *@This()) *std.Io.Mutex {
            return &self.mutex;
        }
        pub fn resourcePublicationGroupLocked(self: *@This()) PublicationStatus {
            return self.authority.statusLocked();
        }
        pub fn resourceOwnershipLocked(self: *@This()) *external.Ownership {
            return &self.ownership;
        }
        pub fn resourceMarkPublishedLocked(self: *@This()) void {
            self.authority.publishLocked();
        }
        pub fn resourceMember(self: *@This()) external.ScopeMember {
            return external.scopeMember(Child, self);
        }
        pub fn retainExternalMember(self: *@This()) void {
            self.refs += 1;
        }
        pub fn releaseExternalMember(self: *@This()) void {
            self.refs -= 1;
        }
        pub fn cancelExternalMember(self: *@This(), origin: *external.ScopeIdentity) void {
            if (self.ownership.authorizesCancellation(origin)) self.resourceClose();
        }
    };
    const Initial = struct {
        child: *Child,
        pub fn lock(self: *@This()) void {
            std.Io.Threaded.mutexLock(&self.child.mutex);
        }
        pub fn unlock(self: *@This()) void {
            std.Io.Threaded.mutexUnlock(&self.child.mutex);
        }
        pub fn validate(_: *@This()) bool {
            return true;
        }
        pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
            self.child.ownership = .{ .owned = tokens[0].? };
        }
    };
    const Preparation = struct {
        pub const Error = error{};
        pub fn prepare(_: *@This(), value: Value) Error!Value {
            heap.retainValue(value);
            return value;
        }
        host: *const heap.HostCleanup,
        pub fn release(self: *@This(), value: Value) void {
            heap.hostDomain(self.host).releaseValue(value);
        }
    };
    const Schedule = enum { publication_first, cancellation_first, snapshot_prepared, membership_prepared, competing_publication };
    // Inject closure at real allocator boundaries, outside all publication
    // locks. This covers a stale snapshot without adding production test hooks.
    const InterleavingAllocator = struct {
        backing: std.mem.Allocator,
        trigger: ?struct {
            group: *scheduler.ExternalGroup,
            remaining: usize,
            rival: ?struct { result: *@import("port_result.zig").Result, scope: *scheduler.TaskScope, host: *const heap.HostCleanup } = null,
        } = null,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.trigger) |*trigger| {
                if (trigger.remaining == 0) {
                    const action = trigger.*;
                    self.trigger = null;
                    if (action.rival) |rival| {
                        const outcome = rival.result.claim(rival.scope) catch return null;
                        if (outcome != .value) @panic("competing probe publication did not deliver");
                        heap.hostDomain(rival.host).releaseValue(outcome.value);
                    }
                    action.group.close();
                } else trigger.remaining -= 1;
            }
            return self.backing.rawAlloc(len, alignment, ra);
        }
        fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.backing.rawResize(memory, alignment, len, ra);
        }
        fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.backing.rawRemap(memory, alignment, len, ra);
        }
        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.backing.rawFree(memory, alignment, ra);
        }
    };
    fn run(backing: std.mem.Allocator, schedule: Schedule, result_delivery: bool) !void {
        var interleaving: InterleavingAllocator = .{ .backing = backing };
        const allocator = interleaving.allocator();
        const cancellation = schedule != .publication_first and schedule != .competing_publication;
        var cleanup = heap.testing.Cleanup.init(allocator);
        defer cleanup.deinit();
        var runtime = try scheduler.Scheduler.init(cleanup.capability(), .cooperative, .manual);
        var scope = scheduler.TaskScope.init(runtime.worker());
        defer runtime.deinit(&scope);
        var parent: Parent = .{};
        const group = try scheduler.ExternalGroup.create(runtime.worker(), Parent, &parent);
        defer group.release();
        const authority = try PublicationAuthority.create(allocator, group);
        defer authority.deinit();
        var child: Child = .{ .allocator = allocator, .authority = authority };
        defer {
            var detached = child.ownership.release();
            detached.detachAll();
        }
        var initial: Initial = .{ .child = &child };
        var members: [16]?external.ScopeMember = .{null} ** 16;
        members[0] = child.resourceMember();
        try std.testing.expect(try group.publish(members, &initial));
        const value = try Resource.create(Child, .staged, 1, &child);
        // Settle heap ownership before the stack-backed registered adapter dies.
        defer cleanup.releaseValue(value);
        const message_api = @import("port_message.zig");
        const messages = @import("port_messages.zig");
        const validating = try message_api.Message.create(allocator, value, .{});
        defer validating.retire(cleanup.domain());
        var work = @import("poll.zig").WorkBudget.init(64);
        try std.testing.expect(try validating.advance(&work) == .complete);
        const budget = try messages.Budget.create(cleanup.capability(), 8);
        defer budget.release();
        const pair = try messages.Queue.create(budget, 1);
        defer pair.queue.release();
        const result = try @import("port_result.zig").Result.create(cleanup.capability());
        defer result.release();
        const rival = try @import("port_result.zig").Result.create(cleanup.capability());
        defer rival.release();
        if (schedule == .competing_publication) {
            const duplicate = try messages.Envelope.create(cleanup.capability(), validating.validated().?);
            try std.testing.expect(rival.replace(duplicate));
            rival.complete(.success);
        }
        const envelope = try messages.Envelope.create(cleanup.capability(), validating.validated().?);
        if (result_delivery) {
            try std.testing.expect(result.replace(envelope));
            result.complete(.success);
        } else try std.testing.expect(pair.queue.send(envelope) == .accepted);
        // Close the publication group without advancing its cancellation walk:
        // the authority still looks provisional, but rejection must be terminal.
        switch (schedule) {
            .publication_first => {},
            .competing_publication => interleaving.trigger = .{
                .group = group,
                .remaining = 0,
                .rival = .{ .result = rival, .scope = &scope, .host = cleanup.capability() },
            },
            .cancellation_first => group.close(),
            .snapshot_prepared, .membership_prepared => interleaving.trigger = .{
                .group = group,
                .remaining = if (schedule == .snapshot_prepared) 0 else 1,
            },
        }
        defer interleaving.trigger = null;
        var preparation: Preparation = .{ .host = cleanup.capability() };
        if (result_delivery) {
            var outcome = result.claim(&scope) catch |err| {
                try std.testing.expect(err == error.OutOfMemory);
                try std.testing.expect(result.completion() == .ready);
                return err;
            };
            if (schedule == .competing_publication) {
                try std.testing.expect(outcome == .pending);
                outcome = try result.claim(&scope);
            }
            if (cancellation) {
                try std.testing.expect(outcome == .cancelled);
                try std.testing.expect(try result.claim(&scope) == .cancelled);
            } else {
                try std.testing.expect(outcome == .value);
                preparation.release(outcome.value);
                try std.testing.expect(try result.claim(&scope) == .claimed);
            }
        } else {
            var outcome = pair.queue.receive(&scope, &preparation) catch |err| {
                try std.testing.expect(err == error.OutOfMemory);
                const view = pair.queue.peek().message;
                defer view.release();
                try std.testing.expect(view.value().port == value.port);
                return err;
            };
            if (schedule == .competing_publication) {
                try std.testing.expect(outcome == .pending);
                outcome = try pair.queue.receive(&scope, &preparation);
            }
            if (cancellation) {
                try std.testing.expect(outcome == .failed);
                try std.testing.expect(pair.queue.peek() == .pending);
            } else {
                try std.testing.expect(outcome == .message);
                preparation.release(outcome.message);
            }
        }
        try std.testing.expect(interleaving.trigger == null);
        if (!cancellation) {
            group.close();
            try std.testing.expectEqual(@as(usize, 1), scope.pending());
            try std.testing.expect(authority.statusLocked() == .published);
        } else try std.testing.expectEqual(@as(usize, 0), scope.pending());
    }
};

test "native: child delivery publication preserves ownership across allocation failure and cancellation" {
    for (std.enums.values(PublicationProbe.Schedule)) |schedule| {
        for ([_]bool{ false, true }) |result_delivery| {
            try std.testing.checkAllAllocationFailures(std.testing.allocator, PublicationProbe.run, .{ schedule, result_delivery });
        }
    }
}
