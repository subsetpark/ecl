//! Whole-message transport. Queue occupancy is charged before publication;
//! dequeue publication is a separate, allocation-free consuming transition.
const std = @import("std");
const scheduler = @import("scheduler.zig");
const heap = @import("heap.zig");
const external = @import("external.zig");
const message = @import("port_message.zig");
const Value = @import("value.zig").Value;
pub const Failure = @import("port_bytes.zig").Failure;
const max_messages = 16;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const EnvelopeState = struct {
    host: *const heap.HostCleanup,
    value: Value,
    footprint: message.Footprint,
    attachments: [31]?*heap.PortHandle = .{null} ** 31,
    reservation: ?*Budget = null,
    refs: std.atomic.Value(usize) = .init(1),
    fn capability(self: *EnvelopeState) *Envelope {
        return @ptrCast(self);
    }
    fn releaseView(self: *EnvelopeState) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        heap.hostDomain(self.host).releaseValue(self.value);
        self.host.allocator().destroy(self);
    }
};

/// Unique delivery ownership of an immutable, already-validated message.
/// Observation uses a distinct View. A delivery keeps its budget reservation
/// while a controller forwards it, preventing input from starving output.
pub const Envelope = opaque {
    fn state(self: *Envelope) *EnvelopeState {
        return @ptrCast(@alignCast(self));
    }
    /// Borrows input on both outcomes; success owns an independent reference.
    pub fn create(host: *const heap.HostCleanup, input: *const message.Validated) error{OutOfMemory}!*Envelope {
        const owned = try host.allocator().create(EnvelopeState);
        owned.* = .{ .host = host, .value = input.value(), .footprint = input.footprint() };
        @memcpy(owned.attachments[0..input.attachments().len], input.attachments());
        heap.retainValue(owned.value);
        return owned.capability();
    }
    pub fn value(self: *Envelope) Value {
        return self.state().value;
    }
    pub fn empty(host: *const heap.HostCleanup) error{OutOfMemory}!*Envelope {
        const owned = try host.allocator().create(EnvelopeState);
        errdefer host.allocator().destroy(owned);
        const input = try @import("list.zig").fromValues(host.allocator(), &.{});
        owned.* = .{ .host = host, .value = input, .footprint = .{ .nodes = 1 } };
        return owned.capability();
    }
    pub fn borrow(self: *Envelope) *View {
        _ = self.state().refs.fetchAdd(1, .monotonic);
        return @ptrCast(self);
    }
    pub fn release(self: *Envelope) void {
        self.releaseQueueCapacity();
        self.state().releaseView();
    }
    /// Moving a delivery to a terminal result ends its queue reservation.
    /// The caller still uniquely owns the envelope and all of its values.
    pub fn releaseQueueCapacity(self: *Envelope) void {
        const owned = self.state();
        if (owned.reservation) |budget| {
            owned.reservation = null;
            budget.returnBytes(owned.footprint.bytes);
            budget.release();
        }
    }
};

/// A retained observation cannot be enqueued or used as delivery ownership.
pub const View = opaque {
    fn state(self: *View) *EnvelopeState {
        return @ptrCast(@alignCast(self));
    }
    pub fn value(self: *View) Value {
        return self.state().value;
    }
    pub fn attachments(self: *View) []const ?*heap.PortHandle {
        return self.state().attachments[0..self.state().footprint.capabilities];
    }
    pub fn observes(self: *View, envelope: *Envelope) bool {
        return self.state() == envelope.state();
    }
    pub fn release(self: *View) void {
        self.state().releaseView();
    }
};

const BudgetState = struct {
    host: *const heap.HostCleanup,
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(BudgetState) = .{},
    limit: usize,
    used: usize = 0,
    epoch: u64 = 0,
    fn capability(self: *BudgetState) *Budget {
        return @ptrCast(self);
    }
    pub fn retainReadiness(self: *BudgetState) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *BudgetState) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.host.allocator().destroy(self);
    }
    pub fn readyLocked(self: *BudgetState, key: u64) bool {
        return key != self.epoch;
    }
    pub fn wakeReasonLocked(_: *BudgetState, _: u64) external.Wake {
        return .ready;
    }
    pub fn registerReadiness(self: *BudgetState, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(BudgetState).register(self, key, target);
    }
    fn notifyLocked(self: *BudgetState) void {
        self.epoch +%= 1;
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
    }
};

/// Shared by all message directions of a resource. Its own readiness source
/// avoids acquiring another queue's mutex when returning shared capacity.
pub const Budget = opaque {
    fn state(self: *Budget) *BudgetState {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(host: *const heap.HostCleanup, limit: usize) error{OutOfMemory}!*Budget {
        const owned = try host.allocator().create(BudgetState);
        owned.* = .{ .host = host, .allocator = host.allocator(), .limit = limit };
        return owned.capability();
    }
    pub fn release(self: *Budget) void {
        self.state().releaseReadiness();
    }
    fn returnBytes(self: *Budget, count: usize) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        owned.used -= count;
        owned.notifyLocked();
    }
};

const QueueState = struct {
    budget: *Budget,
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(QueueState) = .{},
    messages: [max_messages]?*Envelope = .{null} ** max_messages,
    capacity: usize,
    head: usize = 0,
    count: usize = 0,
    reader: bool = false,
    phase: union(enum) { open, eof, failed: Failure } = .open,
    fn capability(self: *QueueState) *Queue {
        return @ptrCast(self);
    }
    const Admission = union(enum) { accepted, full, capacity: u64, overflow, failed: Failure };
    fn sendLocked(self: *QueueState, item: *Envelope) Admission {
        switch (self.phase) {
            .eof => return .{ .failed = Failure.init(.io, "message input is finished") },
            .failed => |failure| return .{ .failed = failure },
            .open => {},
        }
        const budget = self.budget.state();
        const size = item.state().footprint.bytes;
        if (size > budget.limit) return .overflow;
        if (self.count == self.capacity) return .full;
        std.Io.Threaded.mutexLock(&budget.mutex);
        defer std.Io.Threaded.mutexUnlock(&budget.mutex);
        if (item.state().reservation) |reserved| {
            if (reserved != self.budget) return .{ .failed = Failure.init(.domain, "message belongs to another transport budget") };
        } else {
            if (size > budget.limit - budget.used) return .{ .capacity = budget.epoch };
            budget.used += size;
            budget.retainReadiness();
            item.state().reservation = self.budget;
        }
        self.messages[(self.head + self.count) % max_messages] = item;
        self.count += 1;
        self.notifyLocked();
        return .accepted;
    }
    pub fn retainReadiness(self: *QueueState) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *QueueState) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.messages) |item| if (item) |owned| {
            owned.release();
        };
        const budget = self.budget;
        self.allocator.destroy(self);
        budget.release();
    }
    pub fn readyLocked(self: *QueueState, key: u64) bool {
        return self.phase != .open or (if (key == 0) self.count != 0 else self.count < self.capacity);
    }
    pub fn wakeReasonLocked(_: *QueueState, _: u64) external.Wake {
        return .ready;
    }
    pub fn registerReadiness(self: *QueueState, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(QueueState).register(self, key, target);
    }
    fn notifyLocked(self: *QueueState) void {
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
    }
};

pub const Send = union(enum) { accepted, pending: external.ReadinessSource, overflow, failed: Failure };
pub const Receive = union(enum) { pending, eof, message: *View, failed: Failure };

pub const Queue = opaque {
    fn state(self: *Queue) *QueueState {
        return @ptrCast(@alignCast(self));
    }
    pub fn interrupt(self: *Queue) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        owned.notifyLocked();
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        owned.budget.returnBytes(0);
    }
    pub fn create(budget: *Budget, capacity: usize) error{ OutOfMemory, InvalidCapacity }!Pair {
        if (capacity == 0 or capacity > max_messages) return error.InvalidCapacity;
        const owned = try budget.state().host.allocator().create(QueueState);
        owned.* = .{ .budget = budget, .allocator = budget.state().host.allocator(), .capacity = capacity };
        budget.state().retainReadiness();
        return .{ .queue = owned.capability(), .controller = @ptrCast(owned) };
    }
    pub fn release(self: *Queue) void {
        self.state().releaseReadiness();
    }
    pub fn envelope(self: *Queue, input: *const message.Validated) error{OutOfMemory}!*Envelope {
        return Envelope.create(self.state().budget.state().host, input);
    }
    /// Consumes the message only on accepted; all other outcomes retain it.
    pub fn send(self: *Queue, item: *Envelope) Send {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        return switch (owned.sendLocked(item)) {
            .accepted => .accepted,
            .full => .{ .pending = external.readinessSource(QueueState, owned, 1) },
            .capacity => |epoch| .{ .pending = external.readinessSource(BudgetState, owned.budget.state(), epoch) },
            .overflow => .overflow,
            .failed => |failure| .{ .failed = failure },
        };
    }
    pub fn beginRead(self: *Queue) error{ConcurrentRead}!void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.reader) return error.ConcurrentRead;
        owned.reader = true;
    }
    pub fn endRead(self: *Queue) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        owned.reader = false;
        std.Io.Threaded.mutexUnlock(&owned.mutex);
    }
    /// Returns an independent reference while retaining queue ownership.
    /// Preparing the event may fail without consuming the queued message.
    pub fn peek(self: *Queue) Receive {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.count != 0) return .{ .message = owned.messages[owned.head].?.borrow() };
        return switch (owned.phase) {
            .open => .pending,
            .eof => .eof,
            .failed => |failure| .{ .failed = failure },
        };
    }
    /// Consumes queue ownership on success. The caller keeps its peek reference
    /// on either outcome. Event construction and stack reservation precede this.
    pub fn claim(self: *Queue, item: *View, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing, Overflow }!bool {
        const handoff = try @import("port_resource.zig").Publication.init(self.state().budget.state().host, item.attachments());
        defer if (handoff) |publication| publication.deinit();
        var publication: Publication = .{ .queue = self.state(), .item = item, .handoff = handoff };
        const accepted = try scope.scheduler.publishExternalBatch(scope, if (handoff) |children| children.members() else .{null} ** 16, &publication);
        if (accepted) item.state().capability().release();
        return accepted;
    }
    const Publication = struct {
        queue: *QueueState,
        item: *View,
        handoff: ?*@import("port_resource.zig").Publication,
        pub fn lock(self: *@This()) void {
            std.Io.Threaded.mutexLock(&self.queue.mutex);
            if (self.handoff) |handoff| handoff.lock();
        }
        pub fn unlock(self: *@This()) void {
            if (self.handoff) |handoff| handoff.unlock();
            std.Io.Threaded.mutexUnlock(&self.queue.mutex);
        }
        pub fn validate(self: *@This()) bool {
            return self.queue.count != 0 and self.queue.messages[self.queue.head] == self.item.state().capability() and
                (if (self.handoff) |handoff| handoff.validate() else true);
        }
        pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
            if (self.handoff) |handoff| handoff.publish(tokens);
            const owned = self.queue;
            owned.messages[owned.head] = null;
            owned.head = (owned.head + 1) % max_messages;
            owned.count -= 1;
            owned.notifyLocked();
        }
    };
    pub fn source(self: *Queue) external.ReadinessSource {
        return external.readinessSource(QueueState, self.state(), 0);
    }
    pub fn finish(self: *Queue) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        if (owned.phase == .open) owned.phase = .eof;
        owned.notifyLocked();
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        owned.budget.returnBytes(0);
    }
    pub fn fail(self: *Queue, failure: Failure) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        if (owned.phase == .open) owned.phase = .{ .failed = failure };
        owned.notifyLocked();
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        owned.budget.returnBytes(0);
    }
    /// Detach under the queue lock, then retire references outside it. Scope
    /// cleanup must break cycles formed by messages containing their exchange.
    pub fn abort(self: *Queue) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        const discarded = owned.messages;
        owned.messages = .{null} ** max_messages;
        owned.count = 0;
        if (owned.phase == .open) owned.phase = .{ .failed = Failure.init(.io, "message endpoint is closed") };
        owned.notifyLocked();
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        for (discarded) |item| if (item) |delivery| delivery.release();
        owned.budget.returnBytes(0);
    }
};

pub const Pair = struct { queue: *Queue, controller: *Controller };

/// Host-only blocking transport authority, borrowed for the owning queue's
/// lifetime. Scheduler endpoints receive only Queue capabilities.
pub const Controller = opaque {
    fn state(self: *Controller) *QueueState {
        return @ptrCast(@alignCast(self));
    }
    pub const Received = union(enum) { message: *Envelope, eof, cancelled, failed: Failure };
    /// A message transfers ownership to the controller, including its queue
    /// reservation. Buffered messages precede terminal failure.
    pub fn receiveMessage(self: *Controller, cancelled: *const std.atomic.Value(bool)) Received {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        while (!cancelled.load(.acquire) and owned.count == 0 and owned.phase == .open) owned.changed.waitUncancelable(io(), &owned.mutex);
        if (cancelled.load(.acquire)) return .cancelled;
        if (owned.count == 0) return switch (owned.phase) {
            .eof => .eof,
            .failed => |failure| .{ .failed = failure },
            .open => unreachable,
        };
        const item = owned.messages[owned.head].?;
        owned.messages[owned.head] = null;
        owned.head = (owned.head + 1) % max_messages;
        owned.count -= 1;
        owned.notifyLocked();
        return .{ .message = item };
    }
    /// Consumes only on true. False retains caller ownership.
    pub fn send(self: *Controller, item: *Envelope, cancelled: *const std.atomic.Value(bool)) bool {
        const owned = self.state();
        while (true) {
            std.Io.Threaded.mutexLock(&owned.mutex);
            if (cancelled.load(.acquire)) {
                std.Io.Threaded.mutexUnlock(&owned.mutex);
                return false;
            }
            switch (owned.sendLocked(item)) {
                .accepted => {
                    std.Io.Threaded.mutexUnlock(&owned.mutex);
                    return true;
                },
                .failed, .overflow => {
                    std.Io.Threaded.mutexUnlock(&owned.mutex);
                    return false;
                },
                .full => {
                    owned.changed.waitUncancelable(io(), &owned.mutex);
                    std.Io.Threaded.mutexUnlock(&owned.mutex);
                },
                .capacity => |epoch| {
                    std.Io.Threaded.mutexUnlock(&owned.mutex);
                    const budget = owned.budget.state();
                    std.Io.Threaded.mutexLock(&budget.mutex);
                    while (!cancelled.load(.acquire) and epoch == budget.epoch) budget.changed.waitUncancelable(io(), &budget.mutex);
                    std.Io.Threaded.mutexUnlock(&budget.mutex);
                },
            }
        }
    }
};

test "native: abandoned message publication preserves queue ownership and capacity" {
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    var runtime = try scheduler.Scheduler.init(cleanup.capability(), .cooperative, .manual);
    var scope = scheduler.TaskScope.init(runtime.worker());
    defer runtime.deinit(&scope);
    const budget = try Budget.create(cleanup.capability(), 8);
    defer budget.release();
    const pair = try Queue.create(budget, 1);
    defer pair.queue.release();
    const validating = try message.Message.create(std.testing.allocator, .{ .int = 42 }, .{});
    defer validating.retire(cleanup.domain());
    var work = @import("poll.zig").WorkBudget.init(8);
    try std.testing.expect(try validating.advance(&work) == .complete);
    const item = try pair.queue.envelope(validating.validated().?);
    switch (pair.queue.send(item)) {
        .accepted => {},
        .pending => |source| {
            var retained = source;
            retained.deinit();
            item.release();
            return error.UnexpectedPending;
        },
        .overflow, .failed => {
            item.release();
            return error.UnexpectedFailure;
        },
    }
    try pair.queue.beginRead();
    defer pair.queue.endRead();
    // Event materialization can abandon its observation without claiming it.
    const first = pair.queue.peek().message;
    try std.testing.expectEqual(@as(i64, 42), first.value().int);
    first.release();
    const second = pair.queue.peek().message;
    defer second.release();
    try std.testing.expectEqual(@as(i64, 42), second.value().int);
    try std.testing.expect(try pair.queue.claim(second, &scope));
    try std.testing.expect(!try pair.queue.claim(second, &scope));
    pair.queue.finish();
    try std.testing.expect(pair.queue.peek() == .eof);
}
