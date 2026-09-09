//! Shared resource execution, controller lanes, and publication lifetime.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const controllers = @import("port_controller.zig");
const transfers = @import("port_transfer.zig");
const port_message = @import("port_message.zig");
const resource_api = @import("port_resource.zig");
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

/// Adapter state contains domain capabilities and typed backend work. This
/// owner determines execution, cancellation, publication, and cleanup order.
pub fn Resource(comptime Adapter: type) type {
    return struct {
        const Cell = @This();
        const Operations = Adapter.Exchange.Lane;
        pub const Group = controllers.Group(Cell, void, .{
            .retain = retainReadiness,
            .retireLocked = retireExecutionLocked,
            .ownership = transferOwnership,
            .release = releaseReadiness,
            .retireAfterUnlock = retireDependency,
        });
        const Transfer = transfers.ScopeTransfer(Cell, transferOwnership, transferLive);
        pub const Parent = struct { cell: *Cell, group: *scheduler.ExternalGroup };
        pub const Admission = @import("port_exchange.zig").Admission;
        adapter: Adapter,
        allocator: std.mem.Allocator,
        scheduler: *const scheduler.WorkerScheduler,
        controllers: *Group,
        lane_count: u32,
        operation_capacity: u32,
        graceful: bool,
        refs: std.atomic.Value(u32) = .init(1),
        closed: std.atomic.Value(bool) = .init(false),
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        waits: external.WaitList(Cell) = .{},
        ownership: external.Ownership = .provisional,
        publication: ?*resource_api.PublicationAuthority = null,
        dependency: union(enum) {
            independent,
            attached: struct { parent: *Cell, membership: external.ScopeMembership },
            retired,
        } = .independent,
        children: ?*scheduler.ExternalGroup = null,
        phase: enum { reserved, initializing, open, closing, cleaned, joined } = .reserved,
        initialization_failure: ?Failure = null,
        shutdown_state: union(enum) { idle, requested, running, completed: ?Failure, aborted } = .idle,
        lanes: [max_lanes]Operations,

        /// Failure retains the prepared adapter. Success consumes it and derives
        /// allocation and executor authority from its owner before publication.
        pub fn initialize(self: *Cell, adapter: Adapter, worker: *const scheduler.WorkerScheduler, lane_count: u32, capacity: u32, graceful: bool) error{ OutOfMemory, InvalidLimits }!void {
            if (lane_count == 0 or lane_count > max_lanes or capacity < lane_count or capacity > 256) return error.InvalidLimits;
            const group = try Group.init(adapter.allocator(), adapter.executor(), self);
            self.* = .{ .adapter = adapter, .allocator = adapter.allocator(), .scheduler = worker, .controllers = group, .lane_count = lane_count, .operation_capacity = capacity, .graceful = graceful, .lanes = .{Operations.init(&self.mutex)} ** max_lanes };
        }
        fn release(self: *Cell) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            if (self.publication) |authority| authority.deinit();
            if (self.children) |children| children.release();
            self.controllers.deinit();
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
            const lanes = if (self.closed.load(.acquire)) 1 else self.lane_count + @as(u32, @intFromBool(self.graceful));
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
        pub fn resourceInitialization(self: *Cell) resource_api.Initialization {
            return switch (self.initialized()) {
                .ready => .ready,
                .pending => .{ .pending = self.source(0) },
                .failed => |failure| .{ .failed = failure },
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
        pub fn readyLocked(self: *Cell, key: u64) bool {
            return switch (key) {
                0 => self.phase != .reserved and self.phase != .initializing,
                1 => self.phase == .joined,
                else => self.closed.load(.acquire) or self.shutdown_state != .idle or key - 2 >= self.lane_count or
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
                .closing, .cleaned, .joined => .{ .failed = self.initialization_failure orelse Failure.init(.io, "port is closed") },
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
            self.phase = .closing;
            if (self.children) |children| children.close();
            // Total admission, across every lane, is capped at 256.
            for (self.lanes[0..self.lane_count]) |*lane| {
                var ticket = lane.front();
                while (ticket) |current| : (ticket = current.successor()) current.owner().markCancelled();
            }
            self.adapter.failTransport();
            if (notify_backend) self.adapter.cancel();
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
            var token: ?external.ScopeMembership = switch (self.dependency) {
                .attached => |attachment| attachment.membership,
                .independent, .retired => null,
            };
            self.dependency = .retired;
            unlock(&self.mutex);
            if (token) |*membership| membership.detach();
        }
        pub fn childrenClosed(_: *Cell) void {}
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
                parent: ?*Cell,
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
                        item.cell.dependency = .{ .attached = .{ .parent = parent, .membership = tokens[0].? } };
                    } else item.cell.ownership = .{ .owned = tokens[0].? };
                }
            };
            var publication: Publication = .{ .cell = self, .parent = null };
            var incoming: [16]?external.ScopeMember = .{null} ** 16;
            incoming[0] = external.scopeMember(Cell, self);
            if (!try provisional.publish(incoming, &publication)) return error.ScopeClosing;
            if (dependent) |parent| {
                publication.parent = parent.cell;
                incoming = .{null} ** 16;
                incoming[0] = external.scopeMember(Cell, self);
                if (!try parent.group.publish(incoming, &publication)) return error.ScopeClosing;
            }
        }
        fn runLane(self: *Cell, index: usize) void {
            if (index == self.lane_count) return self.runShutdown();
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
        pub fn admitOnLane(self: *Cell, selected: Adapter.Request, scope: *scheduler.TaskScope, request: *const port_message.Validated) error{ OutOfMemory, ScopeClosing }!Admission {
            lock(&self.mutex);
            const closed = self.closed.load(.acquire) or self.shutdown_state != .idle;
            const lane = self.adapter.operationLane(selected);
            const invalid = lane >= self.lane_count;
            const full = !invalid and !self.lanes[lane].hasCapacity(self.laneCapacity(lane));
            unlock(&self.mutex);
            if (closed) return .closed;
            if (invalid) return .unsupported;
            if (full) return .{ .pending = self.source(2 + @as(u64, lane)) };
            const candidate = try self.adapter.prepareOperation(self, selected, request, &self.lanes[lane]);
            defer candidate.deinit();
            const op = admit: {
                lock(&self.mutex);
                defer unlock(&self.mutex);
                if (self.closed.load(.acquire) or self.shutdown_state != .idle) return .closed;
                const admitted = candidate.admit(self.laneCapacity(lane)) orelse return .{ .pending = self.source(2 + @as(u64, lane)) };
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
}
