//! Shared controller exchange lifetime, scope ownership, and terminal observation.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const controllers = @import("port_controller.zig");
const transfers = @import("port_transfer.zig");
const results = @import("port_result.zig");
const exchanges = @import("port_exchange.zig");
const Value = @import("value.zig").Value;
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn lock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexLock(mutex);
}
fn unlock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexUnlock(mutex);
}

/// Adapters supply typed execution and transport. This owner alone carries
/// cancellation settlement, terminal result publication, and scope lifetime.
pub fn Exchange(comptime Adapter: type) type {
    return struct {
        const Operation = @This();
        pub const Lane = controllers.Lane(Operation, .operation, .{
            .deinit = deinit,
            .runnable = runnable,
            .execute = execute,
            .notifyOperation = notifyLocked,
            .completeResource = completeResourceLocked,
            .retireOperation = settleScope,
            .cancelPolicy = cancelPolicy,
            .cancelResource = cancelResourceLocked,
        });
        const Transfer = transfers.ScopeTransfer(Operation, transferOwnership, transferLive);
        allocator: std.mem.Allocator,
        adapter: Adapter,
        ticket: *Lane.Ticket,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        waits: external.WaitList(Operation) = .{},
        transport_cancelled: std.atomic.Value(bool) = .init(false),
        ownership: external.Ownership = .provisional,
        children: ?*scheduler.ExternalGroup = null,
        lifetime: enum { open, closing, closed } = .open,
        terminal_result: *results.Result,

        const Preparation = struct {
            allocator: std.mem.Allocator,
            node: *Lane.Prepared,
            phase: union(enum) { ready: struct { adapter: Adapter, result: *results.Result }, admitted },
        };
        pub const Prepared = opaque {
            fn state(self: *Prepared) *Preparation {
                return @ptrCast(@alignCast(self));
            }
            /// Called under the issuing resource lock. Success consumes the
            /// prepared payload into its lane; rejection retains it unchanged.
            /// In both cases, deinit retires this wrapper after unlocking.
            pub fn admit(self: *Prepared, limit: usize) ?*Operation {
                const owned = self.state();
                const ready = owned.phase.ready;
                const ticket = owned.node.admit(limit, .{ ready.adapter, ready.result }, initialize) orelse return null;
                owned.phase = .admitted;
                return ticket.owner();
            }
            pub fn deinit(self: *Prepared) void {
                const owned = self.state();
                switch (owned.phase) {
                    .ready => |*ready| {
                        owned.node.discard();
                        ready.result.release();
                        ready.adapter.deinit();
                    },
                    .admitted => {},
                }
                owned.allocator.destroy(owned);
            }
        };
        /// Success consumes the adapter and result and pins the resource.
        /// Failure retains both. All allocation precedes admission locking.
        pub fn prepare(adapter: Adapter, result: *results.Result, lane: *Lane) error{OutOfMemory}!*Prepared {
            const owned = try adapter.allocator().create(Preparation);
            errdefer adapter.allocator().destroy(owned);
            const node = try lane.prepare(adapter.allocator());
            owned.* = .{ .allocator = adapter.allocator(), .node = node, .phase = .{ .ready = .{ .adapter = adapter, .result = result } } };
            owned.phase.ready.adapter.retainResource();
            return @ptrCast(owned);
        }
        fn initialize(self: *Operation, ticket: *Lane.Ticket, adapter: Adapter, result: *results.Result) void {
            self.* = .{ .allocator = adapter.allocator(), .adapter = adapter, .ticket = ticket, .terminal_result = result };
        }
        /// Consumes the admitted observer on every path. Success publishes both
        /// the capability and scope membership before making the lane runnable;
        /// failure cancels the reservation and retires all provisional storage.
        pub fn publish(self: *Operation, identity: u64, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing }!Value {
            const item = exchanges.Exchange.create(Operation, identity, self) catch |err| {
                self.close();
                self.releaseReadiness();
                return err;
            };
            errdefer {
                self.close();
                self.adapter.retireValue(item);
            }
            try transfers.publishScope(Operation, self, scope, transferOwnership);
            const resource_mutex = self.adapter.resourceMutex();
            lock(resource_mutex);
            lock(&self.mutex);
            if (self.ownership.live()) _ = self.ticket.publish();
            unlock(&self.mutex);
            self.adapter.admittedLocked();
            unlock(resource_mutex);
            return item;
        }
        fn runnable(self: *Operation) bool {
            return self.adapter.runnable();
        }
        fn execute(self: *Operation, running: *controllers.Running) void {
            self.adapter.execute(self, running);
        }
        fn completeResourceLocked(self: *Operation, outcome: controllers.Completion) void {
            self.adapter.completeResourceLocked(outcome);
        }
        fn cancelPolicy(self: *Operation) controllers.CallbackCancellation {
            return self.adapter.cancelPolicy();
        }
        fn cancelResourceLocked(self: *Operation, action: controllers.CancelAction) void {
            self.adapter.cancelResourceLocked(action);
        }
        fn deinit(self: *Operation) void {
            if (self.children) |children| children.release();
            self.terminal_result.release();
            self.adapter.deinit();
        }
        pub fn notifyLocked(self: *Operation) void {
            if (self.ticket.isCancelled()) {
                self.transport_cancelled.store(true, .release);
                if (self.children) |children| children.close();
            }
            self.adapter.notifyTransport(self);
            switch (self.ticket.status()) {
                .done => self.terminal_result.complete(self.adapter.terminal()),
                .cancelled => self.terminal_result.complete(.cancelled),
                .preparing, .queued, .active, .cancelling, .reusable => {},
            }
            self.changed.broadcast(io());
            self.waits.notifyLocked(self);
        }
        pub fn exchangeAllocator(self: *Operation) std.mem.Allocator {
            return self.adapter.allocator();
        }
        pub fn exchangeResult(self: *Operation) *results.Result {
            return self.terminal_result;
        }
        pub fn exchangeSource(self: *Operation, interest: exchanges.Interest) external.ReadinessSource {
            return external.readinessSource(Operation, self, @intFromEnum(interest));
        }
        pub fn retainReadiness(self: *Operation) void {
            self.ticket.retain();
        }
        pub fn releaseReadiness(self: *Operation) void {
            self.ticket.release();
        }
        pub fn releasePort(self: *Operation) void {
            self.releaseReadiness();
        }
        pub fn retainExternalMember(self: *Operation) void {
            self.retainReadiness();
        }
        pub fn releaseExternalMember(self: *Operation) void {
            self.releaseReadiness();
        }
        pub fn cancelExternalMember(self: *Operation, scope: *external.ScopeIdentity) void {
            lock(&self.mutex);
            const authorized = self.ownership.authorizesCancellation(scope);
            if (authorized and self.lifetime == .open) self.lifetime = .closing;
            unlock(&self.mutex);
            if (authorized) self.close();
        }
        pub fn close(self: *Operation) void {
            lock(&self.mutex);
            if (self.lifetime == .open) self.lifetime = .closing;
            unlock(&self.mutex);
            self.cancel();
            self.settleScope();
        }
        pub fn settleScope(self: *Operation) void {
            lock(&self.mutex);
            var detached: external.Ownership.Detached = .{};
            const terminal = switch (self.ticket.status()) {
                .done, .cancelled => true,
                .preparing, .queued, .active, .cancelling, .reusable => false,
            };
            const aborting = terminal and self.lifetime != .open;
            const children = if (aborting) self.children else null;
            if (aborting) {
                self.lifetime = .closing;
                self.notifyLocked();
            }
            unlock(&self.mutex);
            if (aborting) {
                self.adapter.abortTransport();
            }
            if (aborting) self.terminal_result.discard();
            if (children) |group| group.close();
            if (aborting and (children == null or children.?.closed())) {
                lock(&self.mutex);
                self.lifetime = .closed;
                detached = self.ownership.release();
                self.notifyLocked();
                unlock(&self.mutex);
            }
            detached.detachAll();
        }
        pub fn childrenClosed(self: *Operation) void {
            self.settleScope();
        }
        pub fn childGroup(self: *Operation) error{ OutOfMemory, Closed }!*scheduler.ExternalGroup {
            lock(&self.mutex);
            const existing = self.children;
            unlock(&self.mutex);
            if (existing) |group| return group;
            const candidate = try scheduler.ExternalGroup.create(self.adapter.scheduler(), Operation, self);
            lock(&self.mutex);
            const unavailable = self.lifetime != .open or self.ticket.isCancelled();
            if (!unavailable and self.children == null) {
                self.children = candidate;
                unlock(&self.mutex);
                return candidate;
            }
            const selected = self.children;
            unlock(&self.mutex);
            candidate.release();
            return selected orelse error.Closed;
        }
        pub fn transferOwnership(self: *Operation) *external.Ownership {
            return &self.ownership;
        }
        fn transferLive(self: *Operation) bool {
            return self.lifetime == .open;
        }
        pub fn prepareScopeTransfer(self: *Operation, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
            return Transfer.prepare(self, from, to);
        }
        pub fn commitScopeTransfer(self: *Operation) void {
            Transfer.commit(self);
        }
        pub fn abortScopeTransfer(self: *Operation) void {
            Transfer.abort(self);
        }
        pub fn closed(self: *Operation) bool {
            lock(&self.mutex);
            defer unlock(&self.mutex);
            return self.lifetime == .closed;
        }
        pub fn registerReadiness(self: *Operation, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
            return external.WaitList(Operation).register(self, key, target);
        }
        pub fn readyLocked(self: *Operation, key: u64) bool {
            return switch (key) {
                @intFromEnum(exchanges.Interest.cleanup) => self.lifetime == .closed,
                @intFromEnum(exchanges.Interest.completion) => self.ticket.status() == .done or self.ticket.status() == .cancelled,
                else => false,
            };
        }
        pub fn wakeReasonLocked(_: *Operation, _: u64) external.Wake {
            return .ready;
        }
        pub fn markCancelled(self: *Operation) void {
            lock(&self.mutex);
            // The resource's lane list contains only outstanding exchanges.
            // Abort their ownership explicitly; a completed exchange has its own
            // scope lifetime and must not infer abortion from resource closure.
            if (self.lifetime == .open) self.lifetime = .closing;
            self.ticket.requestCancellation();
            self.notifyLocked();
            unlock(&self.mutex);
        }
        pub fn cancel(self: *Operation) void {
            self.ticket.cancel();
        }
        pub fn completion(self: *Operation) results.Completion {
            return self.terminal_result.completion();
        }
        pub fn claimResult(self: *Operation, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing, Overflow }!results.Claim {
            return self.terminal_result.claim(scope);
        }
    };
}
