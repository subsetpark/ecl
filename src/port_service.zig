//! Shared resource execution, controller lanes, and publication lifetime.
const ResourceBackend = @import("native_port.zig").ResourceBackend;
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const controllers = @import("port_controller.zig");
const transfers = @import("port_transfer.zig");
const port_message = @import("port_message.zig");
const resource_api = @import("port_resource.zig");
const diagnostics = @import("port_error_data.zig");
const Failure = @import("port_bytes.zig").Failure;
const max_lanes = 16;
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn lock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexLock(mutex);
}
fn unlock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexUnlock(mutex);
}

/// Native resource lifetime owns execution, cancellation, publication, and
/// cleanup order independently of the backend callback implementation.
pub const Resource = struct {
    const Cell = @This();
    const Operation = @import("port_operation.zig").Exchange;
    const Operations = Operation.Lane;
    pub const Request = struct { code: u32, lane: u32, endpoints: u64, mode: @import("port_operation.zig").Mode };
    pub const Group = controllers.Group(Cell, void, .{
        .retain = retainReadiness,
        .retireLocked = retireExecutionLocked,
        .ownership = transferOwnership,
        .release = releaseReadiness,
        .retireAfterUnlock = retireDependency,
    });
    const Transfer = transfers.ScopeTransfer(Cell, transferOwnership, transferLive);
    pub const Parent = struct { cell: *Cell, group: *scheduler.ExternalGroup, lifetime: union(enum) { initialization, resource, inherited: ?*scheduler.ExternalGroup } = .resource };
    const Attachment = struct { parent: *Cell, group: *scheduler.ExternalGroup, membership: external.ScopeMembership };
    const Inherited = struct { group: *scheduler.ExternalGroup, membership: external.ScopeMembership };
    const Initializing = struct { origin: Attachment, inherited: ?Inherited = null };
    pub const Admission = @import("port_exchange.zig").Admission;
    adapter: ResourceBackend,
    allocator: std.mem.Allocator,
    scheduler: *const scheduler.WorkerScheduler,
    controllers: *Group,
    lane_count: u32,
    operation_capacity: u32,
    graceful: bool,
    activity_count: u32 = 0,
    lease_count: usize = 0,
    refs: std.atomic.Value(u32) = .init(1),
    closed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Cell) = .{},
    ownership: external.Ownership = .provisional,
    publication: ?*resource_api.PublicationAuthority = null,
    dependency: union(enum) {
        independent,
        initializing: Initializing,
        inherited: Inherited,
        attached: Attachment,
        retired,
    } = .independent,
    children: ?*scheduler.ExternalGroup = null,
    phase: enum { reserved, reserved_closed, initializing, open, closing, waiting_children, cleaning, cleaned, joined } = .reserved,
    initialization_failure: ?Failure = null,
    initialization_details: ?*diagnostics.Owned = null,
    admission: enum { open, sealing_work, sealing_children, sealing_execution, sealed } = .open,
    shutdown_state: union(enum) { idle, requested, running, completed: ?Failure, aborted } = .idle,
    lanes: [max_lanes]Operations,

    /// Failure retains the prepared adapter. Success consumes it and derives
    /// allocation and executor authority from its owner before publication.
    pub fn initialize(self: *Cell, adapter: ResourceBackend, worker: *const scheduler.WorkerScheduler, lane_count: u32, capacity: u32, graceful: bool, activity_count: u32) error{ OutOfMemory, InvalidLimits }!void {
        if (activity_count > @import("port-declarations").max_activities) return error.InvalidLimits;
        try validateCapacity(lane_count, capacity);
        const group = try Group.init(adapter.allocator(), adapter.executor(), self);
        self.initializeReserved(adapter, worker, lane_count, capacity, graceful, group);
        self.activity_count = activity_count;
    }
    pub fn initializeCooperative(self: *Cell, adapter: ResourceBackend, worker: *const scheduler.WorkerScheduler, lane_count: u32, capacity: u32) error{ OutOfMemory, InvalidLimits, Io }!void {
        try validateCapacity(lane_count, capacity);
        if (lane_count != 1) return error.InvalidLimits;
        const group = try Group.initCooperative(worker, self, advanceCooperative);
        self.initializeReserved(adapter, worker, lane_count, capacity, false, group);
    }
    fn validateCapacity(lane_count: u32, capacity: u32) error{InvalidLimits}!void {
        if (lane_count == 0 or lane_count > max_lanes or capacity < lane_count or capacity > 256) return error.InvalidLimits;
    }
    fn initializeReserved(self: *Cell, adapter: ResourceBackend, worker: *const scheduler.WorkerScheduler, lane_count: u32, capacity: u32, graceful: bool, group: *Group) void {
        self.* = .{ .adapter = adapter, .allocator = adapter.allocator(), .scheduler = worker, .controllers = group, .lane_count = lane_count, .operation_capacity = capacity, .graceful = graceful, .lanes = .{Operations.init(&self.mutex)} ** max_lanes };
    }
    fn advanceCooperative(self: *Cell) scheduler.Cooperative.Progress {
        lock(&self.mutex);
        const phase = self.phase;
        switch (phase) {
            .reserved, .reserved_closed => {
                self.adapter.initState();
                self.phase = if (self.closed.load(.acquire)) .closing else .initializing;
                unlock(&self.mutex);
                return .yielded;
            },
            .initializing => {
                unlock(&self.mutex);
                const progress = self.adapter.advanceInitialize(self);
                if (progress != .completed) return progress;
                lock(&self.mutex);
                if (self.initialization_failure != null) self.closeLocked();
                unlock(&self.mutex);
                self.publishInitialization();
                return .yielded;
            },
            .open, .closing => {
                // One callback slice per queue turn. Empty-lane scanning
                // is bounded by the descriptor's fixed lane ceiling.
                var selected: ?*Operations = null;
                for (self.lanes[0..self.lane_count]) |*lane| {
                    if (lane.dispatchable()) {
                        selected = lane;
                        break;
                    }
                }
                if (selected) |lane| {
                    const finalizer = lane.front().?.owner().mode == .finalizer;
                    if (finalizer and phase == .open) {
                        switch (self.admission) {
                            .sealing_work => {
                                self.admission = .sealing_children;
                                const children = self.children;
                                unlock(&self.mutex);
                                if (children) |group| group.close();
                                return .yielded;
                            },
                            .sealing_children => {
                                if (self.children) |children| if (!children.closed()) {
                                    unlock(&self.mutex);
                                    return .waiting;
                                };
                                if (self.lease_count != 0) {
                                    unlock(&self.mutex);
                                    return .waiting;
                                }
                                self.admission = .sealing_execution;
                            },
                            .sealing_execution => {},
                            .open, .sealed => unreachable,
                        }
                    }
                    unlock(&self.mutex);
                    const progress = lane.advanceNext(Operation.advanceCooperative);
                    if (finalizer and progress == .completed) {
                        lock(&self.mutex);
                        self.admission = .sealed;
                        unlock(&self.mutex);
                    }
                    return switch (progress) {
                        .idle, .waiting => .waiting,
                        .yielded, .completed => .yielded,
                        .parked => |deadline| .{ .parked = deadline },
                    };
                }
                if (phase == .open) {
                    unlock(&self.mutex);
                    return .waiting;
                }
                // Unpublished admissions still own queue positions. Their
                // publication or rollback wakes execution to settle them.
                for (self.lanes[0..self.lane_count]) |*lane| if (!lane.empty()) {
                    unlock(&self.mutex);
                    return .waiting;
                };
                self.phase = .waiting_children;
                unlock(&self.mutex);
                self.adapter.abortTransport();
                if (self.children) |children| children.close();
                return .yielded;
            },
            .waiting_children => {
                if (self.children) |children| if (!children.closed()) {
                    unlock(&self.mutex);
                    return .waiting;
                };
                if (self.lease_count != 0) {
                    unlock(&self.mutex);
                    return .waiting;
                }
                self.phase = .cleaning;
                unlock(&self.mutex);
                return .yielded;
            },
            .cleaning => {
                unlock(&self.mutex);
                const progress = self.adapter.advanceCleanup(self);
                if (progress != .completed) return progress;
                lock(&self.mutex);
                self.phase = .cleaned;
                unlock(&self.mutex);
                return .completed;
            },
            .cleaned, .joined => unreachable,
        }
    }
    fn release(self: *Cell) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.publication) |authority| authority.deinit();
        if (self.children) |children| children.release();
        self.controllers.deinit();
        if (self.initialization_details) |details| details.release();
        self.adapter.destroy(self);
    }
    pub fn run(execution: *controllers.Execution, self: *Cell) void {
        lock(&self.mutex);
        self.adapter.initState();
        const initialize_backend = !self.closed.load(.acquire);
        if (initialize_backend) self.phase = .initializing;
        unlock(&self.mutex);
        if (initialize_backend) self.adapter.initializeBackend(self);
        lock(&self.mutex);
        if (self.initialization_failure != null) self.closed.store(true, .release);
        const lanes = if (self.closed.load(.acquire)) 1 else self.lane_count + @as(u32, @intFromBool(self.graceful)) + self.activity_count;
        unlock(&self.mutex);
        execution.runLanes(lanes, self, Cell.runLane, Cell.failLaneStartup, Cell.publishInitialization);
        // Join all operation execution and cancellation notification before
        // destroying transport and backend state or detaching scope ownership.
        lock(&self.mutex);
        unlock(&self.mutex);
        self.adapter.abortTransport();
        if (self.children) |children| {
            children.close();
            children.join(execution);
        }
        lock(&self.mutex);
        while (self.lease_count != 0) self.changed.waitUncancelable(io(), &self.mutex);
        unlock(&self.mutex);
        self.adapter.cleanup();
        lock(&self.mutex);
        self.phase = .cleaned;
        unlock(&self.mutex);
    }
    fn runShutdown(self: *Cell) void {
        lock(&self.mutex);
        while (self.shutdown_state == .idle and !self.closed.load(.acquire)) self.changed.waitUncancelable(io(), &self.mutex);
        if (self.closed.load(.acquire)) {
            self.shutdown_state = .aborted;
            unlock(&self.mutex);
            return;
        }
        self.shutdown_state = .running;
        unlock(&self.mutex);
        const failure = self.adapter.shutdown(self);
        lock(&self.mutex);
        self.shutdown_state = if (self.closed.load(.acquire)) .aborted else .{ .completed = failure };
        self.closeLocked();
        unlock(&self.mutex);
    }
    pub fn failInitialization(self: *Cell, failure: Failure) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.initialization_failure == null or failure == .out_of_memory) self.initialization_failure = failure;
    }
    /// The initialization callback alone may replace diagnostic storage.
    /// Success consumes it before initialization is published; rejection
    /// retains it. Final resource release retires the immutable result.
    pub fn replaceInitializationDetails(self: *Cell, incoming: *diagnostics.Owned) bool {
        lock(&self.mutex);
        if (self.phase != .initializing) {
            unlock(&self.mutex);
            return false;
        }
        const previous = self.initialization_details;
        self.initialization_details = incoming;
        unlock(&self.mutex);
        if (previous) |details| details.release();
        return true;
    }
    pub fn resourceInitialization(self: *Cell) resource_api.Initialization {
        return switch (self.initialized()) {
            .ready => .ready,
            .pending => .{ .pending = self.source(0) },
            .failed => |failure| .{ .failed = .{ .report = failure, .details = if (self.initialization_details) |details| details.view() else null } },
        };
    }
    pub fn resourceAllocator(self: *Cell) std.mem.Allocator {
        return self.allocator;
    }
    pub fn resourceClose(self: *Cell) void {
        self.close();
    }
    pub fn resourceJoined(self: *Cell) bool {
        return self.joined();
    }
    pub fn resourceSource(self: *Cell) external.ReadinessSource {
        return self.source(1);
    }
    pub fn resourceShutdown(self: *Cell) resource_api.Shutdown {
        return switch (self.shutdown()) {
            .pending => .pending,
            .ready => .ready,
            .unsupported => .unsupported,
            .failed => |failure| .{ .failed = failure },
        };
    }
    pub fn resourcePublicationMutex(self: *Cell) *std.Io.Mutex {
        return &self.mutex;
    }
    pub fn resourcePublicationGroupLocked(self: *Cell) resource_api.PublicationStatus {
        return if (self.publication) |authority| authority.statusLocked() else .published;
    }
    pub fn resourceOwnershipLocked(self: *Cell) *external.Ownership {
        return &self.ownership;
    }
    pub fn resourceMarkPublishedLocked(self: *Cell) void {
        self.publication.?.publishLocked();
    }
    pub fn resourceMember(self: *Cell) external.ScopeMember {
        return external.scopeMember(Cell, self);
    }
    pub fn retainReadiness(self: *Cell) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Cell) void {
        self.release();
    }
    pub fn retainExternalMember(self: *Cell) void {
        self.retainReadiness();
    }
    pub fn releaseExternalMember(self: *Cell) void {
        self.release();
    }
    pub fn cancelExternalMember(self: *Cell, scope: *external.ScopeIdentity) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        const dependent = switch (self.dependency) {
            .attached => |attachment| attachment.membership.authorizesCancellation(scope),
            .inherited => |attachment| attachment.membership.authorizesCancellation(scope),
            .initializing => |attachment| attachment.origin.membership.authorizesCancellation(scope) or
                (if (attachment.inherited) |inherited| inherited.membership.authorizesCancellation(scope) else false),
            .independent, .retired => false,
        };
        if (self.ownership.authorizesCancellation(scope) or dependent) self.closeLocked();
    }
    pub fn releasePort(self: *Cell) void {
        lock(&self.mutex);
        if (self.resourcePublicationGroupLocked() != .published) self.closeLocked();
        unlock(&self.mutex);
        self.release();
    }
    pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Cell).register(self, key, target);
    }
    pub fn prepareInitializationWait(self: *Cell, target: external.WakeTarget) external.RegisterError!*external.WaitList(Cell).Prepared {
        return external.WaitList(Cell).prepare(self, 0, target);
    }
    pub fn readyLocked(self: *Cell, key: u64) bool {
        return switch (key) {
            0 => self.phase != .reserved and self.phase != .initializing,
            1 => self.phase == .joined,
            else => self.closed.load(.acquire) or self.shutdown_state != .idle or self.admission != .open or key - 2 >= self.lane_count or
                self.lanes[key - 2].hasCapacity(self.laneCapacity(@intCast(key - 2))),
        };
    }
    pub fn wakeReasonLocked(_: *Cell, _: u64) external.Wake {
        return .ready;
    }
    pub fn laneCapacity(self: *Cell, lane: u32) u32 {
        const total = self.operation_capacity;
        const lanes = self.lane_count;
        return total / lanes + @as(u32, @intFromBool(lane < total % lanes));
    }
    fn source(self: *Cell, key: u64) external.ReadinessSource {
        return external.readinessSource(Cell, self, key);
    }
    pub fn initialized(self: *Cell) union(enum) { pending, ready, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return switch (self.phase) {
            .reserved, .initializing => .pending,
            .open => .ready,
            .reserved_closed, .closing, .waiting_children, .cleaning, .cleaned, .joined => .{ .failed = self.initialization_failure orelse Failure.init(.io, "port is closed") },
        };
    }
    pub fn joined(self: *Cell) bool {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return self.phase == .joined;
    }
    pub fn close(self: *Cell) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        self.closeLocked();
    }
    pub fn shutdown(self: *Cell) union(enum) { pending, ready, unsupported, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (!self.graceful) return .unsupported;
        switch (self.shutdown_state) {
            .idle => {
                if (self.closed.load(.acquire)) {
                    self.shutdown_state = .aborted;
                } else {
                    self.shutdown_state = .requested;
                    self.changed.broadcast(io());
                    self.waits.notifyLocked(self);
                }
            },
            .requested, .running, .completed, .aborted => {},
        }
        if (self.phase != .joined) return .pending;
        return switch (self.shutdown_state) {
            .completed => |failure| if (failure) |value| .{ .failed = value } else .ready,
            .idle, .requested, .running, .aborted => .{ .failed = Failure.init(.io, "resource closed before graceful shutdown completed") },
        };
    }
    pub fn closeLocked(self: *Cell) void {
        if (self.closed.swap(true, .acq_rel)) return;
        if (self.publication) |authority| authority.revokeLocked();
        const notify_backend = self.phase == .initializing or self.phase == .open;
        self.phase = if (self.phase == .reserved) .reserved_closed else .closing;
        if (self.children) |children| children.close();
        // Total admission, across every lane, is capped at 256.
        for (self.lanes[0..self.lane_count]) |*lane| {
            var ticket = lane.front();
            while (ticket) |current| : (ticket = current.successor()) current.owner().markCancelled();
        }
        self.adapter.failTransport();
        if (notify_backend) self.adapter.cancel();
        self.controllers.wake();
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
    }
    fn failLaneStartup(self: *Cell) void {
        lock(&self.mutex);
        self.initialization_failure = Failure.init(.io, "cannot start port controller lane");
        self.closeLocked();
        unlock(&self.mutex);
    }
    fn publishInitialization(self: *Cell) void {
        lock(&self.mutex);
        // Successful independent construction consumes its temporary
        // parent borrow before readiness can publish the child. Detach
        // outside this lock; parent retirement can wake immediately.
        var temporary: ?external.ScopeMembership = null;
        if (!self.closed.load(.acquire) and self.dependency == .initializing) {
            const initializing = self.dependency.initializing;
            temporary = initializing.origin.membership;
            self.dependency = if (initializing.inherited) |inherited| .{ .inherited = inherited } else .independent;
        }
        unlock(&self.mutex);
        if (temporary) |*membership| membership.detach();
        lock(&self.mutex);
        self.phase = if (self.closed.load(.acquire)) .closing else .open;
        self.waits.notifyLocked(self);
        self.changed.broadcast(io());
        unlock(&self.mutex);
    }
    pub fn prepareStartup(cell: *Cell, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing }!void {
        try transfers.publishScope(Cell, cell, scope, Cell.transferOwnership);
    }
    pub fn abortStartup(cell: *Cell) void {
        cell.closed.store(true, .release);
    }
    fn retireExecutionLocked(cell: *Cell, _: controllers.Outcome(void)) void {
        cell.adapter.retire(cell);
        cell.phase = .joined;
        cell.waits.notifyLocked(cell);
        cell.changed.broadcast(io());
    }
    fn retireDependency(self: *Cell) void {
        lock(&self.mutex);
        const previous = self.dependency;
        self.dependency = .retired;
        unlock(&self.mutex);
        var inherited: ?Inherited = null;
        var origin: ?external.ScopeMembership = null;
        switch (previous) {
            .attached => |attachment| origin = attachment.membership,
            .initializing => |attachment| {
                origin = attachment.origin.membership;
                inherited = attachment.inherited;
            },
            .inherited => |attachment| inherited = attachment,
            .independent, .retired => {},
        }
        if (inherited) |*attachment| {
            attachment.membership.detach();
            attachment.group.release();
        }
        if (origin) |*membership| membership.detach();
    }
    /// Returns an owned group pin; the caller releases it on either outcome.
    /// An inherited lifetime does not grant access to the ancestor's state.
    pub fn inheritChildGroup(self: *Cell) error{Closed}!?*scheduler.ExternalGroup {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.closed.load(.acquire)) return error.Closed;
        const group = switch (self.dependency) {
            .attached => |attachment| attachment.group,
            .inherited => |attachment| attachment.group,
            .initializing => |attachment| if (attachment.inherited) |inherited| inherited.group else return null,
            .independent, .retired => return null,
        };
        group.retain();
        return group;
    }
    /// One admitted native-state lease. Closing the issuer stops new leases;
    /// joined cleanup and finalization wait for every existing lease.
    pub const Lease = opaque {
        fn cell(self: *Lease) *Cell {
            return @ptrCast(@alignCast(self));
        }
        pub fn adapter(self: *Lease) *ResourceBackend {
            return &self.cell().adapter;
        }
        pub fn release(self: *Lease) void {
            const target = self.cell();
            lock(&target.mutex);
            target.lease_count -= 1;
            target.controllers.wake();
            target.changed.broadcast(io());
            unlock(&target.mutex);
            target.releaseReadiness();
        }
    };
    pub fn acquireLease(self: *Cell) error{Closed}!*Lease {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.phase != .open or self.admission != .open or self.closed.load(.acquire)) return error.Closed;
        self.lease_count += 1;
        self.retainReadiness();
        return @ptrCast(self);
    }
    pub fn childrenClosed(self: *Cell) void {
        self.controllers.wake();
    }
    pub fn childGroup(self: *Cell) error{ OutOfMemory, Closed }!*scheduler.ExternalGroup {
        lock(&self.mutex);
        const existing = self.children;
        unlock(&self.mutex);
        if (existing) |group| return group;
        const candidate = try scheduler.ExternalGroup.create(self.scheduler, Cell, self);
        lock(&self.mutex);
        const closed = self.closed.load(.acquire);
        if (!closed and self.children == null) {
            self.children = candidate;
            unlock(&self.mutex);
            return candidate;
        }
        const selected = self.children;
        unlock(&self.mutex);
        candidate.release();
        return selected orelse error.Closed;
    }
    pub fn prepareChildStartup(self: *Cell, provisional: *scheduler.ExternalGroup, dependent: ?Parent) error{ OutOfMemory, ScopeClosing }!void {
        const Publication = struct {
            cell: *Cell,
            parent: ?Parent,
            pub fn lock(item: *@This()) void {
                std.Io.Threaded.mutexLock(&item.cell.mutex);
            }
            pub fn unlock(item: *@This()) void {
                std.Io.Threaded.mutexUnlock(&item.cell.mutex);
            }
            pub fn validate(item: *@This()) bool {
                return !item.cell.closed.load(.acquire) and
                    (if (item.parent != null) item.cell.dependency == .independent else item.cell.ownership == .provisional);
            }
            pub fn publish(item: *@This(), tokens: [16]?external.ScopeMembership) void {
                if (item.parent) |parent| {
                    item.cell.dependency = switch (parent.lifetime) {
                        .initialization, .inherited => .{ .initializing = .{ .origin = .{ .parent = parent.cell, .group = parent.group, .membership = tokens[0].? } } },
                        .resource => .{ .attached = .{ .parent = parent.cell, .group = parent.group, .membership = tokens[0].? } },
                    };
                } else item.cell.ownership = .{ .owned = tokens[0].? };
            }
        };
        var publication: Publication = .{ .cell = self, .parent = null };
        var incoming: [16]?external.ScopeMember = .{null} ** 16;
        incoming[0] = external.scopeMember(Cell, self);
        if (!try provisional.publish(incoming, &publication)) return error.ScopeClosing;
        if (dependent) |parent| {
            publication.parent = parent;
            incoming = .{null} ** 16;
            incoming[0] = external.scopeMember(Cell, self);
            if (!try parent.group.publish(incoming, &publication)) return error.ScopeClosing;
            if (parent.lifetime == .inherited) if (parent.lifetime.inherited) |group| {
                const Inheritance = struct {
                    cell: *Cell,
                    group: *scheduler.ExternalGroup,
                    pub fn lock(item: *@This()) void {
                        std.Io.Threaded.mutexLock(&item.cell.mutex);
                    }
                    pub fn unlock(item: *@This()) void {
                        std.Io.Threaded.mutexUnlock(&item.cell.mutex);
                    }
                    pub fn validate(item: *@This()) bool {
                        return !item.cell.closed.load(.acquire) and item.cell.dependency == .initializing and item.cell.dependency.initializing.inherited == null;
                    }
                    pub fn publish(item: *@This(), tokens: [16]?external.ScopeMembership) void {
                        item.group.retain();
                        item.cell.dependency.initializing.inherited = .{ .group = item.group, .membership = tokens[0].? };
                    }
                };
                var inheritance: Inheritance = .{ .cell = self, .group = group };
                incoming = .{null} ** 16;
                incoming[0] = external.scopeMember(Cell, self);
                if (!try group.publish(incoming, &inheritance)) return error.ScopeClosing;
            };
        }
    }
    fn runLane(self: *Cell, index: usize) void {
        if (index >= self.lane_count) {
            if (self.graceful and index == self.lane_count) return self.runShutdown();
            return self.adapter.runActivity(self, @intCast(index - self.lane_count - @intFromBool(self.graceful)));
        }
        const lane = &self.lanes[index];
        while (true) {
            lock(&self.mutex);
            while (!lane.dispatchable() and !self.closed.load(.acquire)) self.changed.waitUncancelable(io(), &self.mutex);
            const finished = lane.empty();
            unlock(&self.mutex);
            if (finished) return;
            _ = lane.runNext();
        }
    }
    pub fn admitOnLane(self: *Cell, selected: Request, scope: *scheduler.TaskScope, request: *const port_message.Validated) error{ OutOfMemory, ScopeClosing }!Admission {
        lock(&self.mutex);
        const closed = self.closed.load(.acquire) or self.shutdown_state != .idle or self.admission != .open;
        const lane = selected.lane;
        const invalid = lane >= self.lane_count;
        const full = !invalid and !self.lanes[lane].hasCapacity(self.laneCapacity(lane));
        unlock(&self.mutex);
        if (closed) return .closed;
        if (invalid) return .unsupported;
        if (full) return .{ .pending = self.source(2 + @as(u64, lane)) };
        const candidate = try @import("native_port.zig").OperationBackend.prepare(self, selected.code, selected.lane, selected.endpoints, selected.mode, request, &self.lanes[lane]);
        defer candidate.deinit();
        const op = admit: {
            lock(&self.mutex);
            defer unlock(&self.mutex);
            if (self.closed.load(.acquire) or self.shutdown_state != .idle or self.admission != .open) return .closed;
            const mode = candidate.operationMode();
            const admitted = candidate.admit(self.laneCapacity(lane)) orelse return .{ .pending = self.source(2 + @as(u64, lane)) };
            if (mode == .finalizer) self.admission = .sealing_work;
            self.waits.notifyLocked(self);
            self.changed.broadcast(io());
            break :admit admitted;
        };
        const identity = self.adapter.nextIdentity();
        return .{ .exchange = try op.publish(identity, scope) };
    }
    fn transferOwnership(self: *Cell) *external.Ownership {
        return &self.ownership;
    }
    fn transferLive(self: *Cell) bool {
        return !self.closed.load(.acquire);
    }
    pub fn prepareScopeTransfer(self: *Cell, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return Transfer.prepare(self, from, to);
    }
    pub fn commitScopeTransfer(self: *Cell) void {
        Transfer.commit(self);
    }
    pub fn abortScopeTransfer(self: *Cell) void {
        Transfer.abort(self);
    }
};
