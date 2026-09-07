//! Internal port execution. Backends supply typed work and post-join retirement;
//! the extension ABI is only one producer. No ECL worker joins a controller.
const std = @import("std");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
const Job = struct {
    next: ?*Job = null,
    work: union(enum) {
        idle,
        active: struct { thread: std.Thread, retire: *const fn (*Job) void },
    } = .idle,
    payload: [128]u8 align(16),
};

test "native: internal executor retires an independent job while another waits" {
    const Probe = struct {
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        retired: std.Io.Event = .unset,
        fn blocked(_: *Execution, self: *@This()) u32 {
            self.started.set(io());
            self.release.waitUncancelable(io());
            return 41;
        }
        fn independent(_: *Execution, self: *@This()) u32 {
            self.started.waitUncancelable(io());
            return 17;
        }
        fn unblock(args: struct { *@This() }, result: u32) void {
            std.debug.assert(result == 17);
            args[0].release.set(io());
        }
        fn finish(args: struct { *@This() }, result: u32) void {
            std.debug.assert(result == 41);
            args[0].retired.set(io());
        }
    };
    var probe: Probe = .{};
    const owner = try Owner.init(std.testing.allocator, 3);
    defer owner.deinit();
    const executor = owner.access();
    try executor.spawn(Probe.blocked, .{&probe}, Probe.finish);
    // Also lets a failed second spawn roll back without leaving blocked work.
    defer probe.release.set(io());
    try executor.spawn(Probe.independent, .{&probe}, Probe.unblock);
    probe.retired.waitUncancelable(io());
    try std.testing.expect(probe.release.isSet());
}
const State = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    jobs: []Job = &.{},
    unused: usize = 0,
    available: ?*Job = null,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    phase: enum { open, closing } = .open,
    live: usize = 0,
    reaper: ?std.Thread = null,
    first: ?*Job = null,
    last: ?*Job = null,

    fn enqueue(self: *State, job: *Job) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.last) |last| last.next = job else self.first = job;
        self.last = job;
        self.changed.broadcast(io());
    }
    fn reap(self: *State) void {
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (self.first == null and !(self.phase == .closing and self.live == 0))
                self.changed.waitUncancelable(io(), &self.mutex);
            const job = self.first orelse {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return;
            };
            self.first = job.next;
            if (self.first == null) self.last = null;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            // Only finished jobs enter this queue. A blocked backend never
            // holds up retirement of another resource or its child executors.
            job.work.active.thread.join();
            job.work.active.retire(job);
            std.Io.Threaded.mutexLock(&self.mutex);
            job.work = .idle;
            job.next = self.available;
            self.available = job;
            self.live -= 1;
            self.changed.broadcast(io());
            std.Io.Threaded.mutexUnlock(&self.mutex);
        }
    }
};

pub const Owner = opaque {
    fn state(self: *Owner) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn init(allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!*Owner {
        if (capacity == 0) @panic("executor requires capacity");
        const state_value = try allocator.create(State);
        state_value.* = .{ .allocator = allocator, .capacity = capacity };
        return @ptrCast(state_value);
    }
    /// Consumes the executor after its resources have been asked to close.
    /// Joins every accepted job and its retirement callback before destruction.
    pub fn deinit(self: *Owner) void {
        const state_value = self.state();
        std.Io.Threaded.mutexLock(&state_value.mutex);
        state_value.phase = .closing;
        state_value.changed.broadcast(io());
        std.Io.Threaded.mutexUnlock(&state_value.mutex);
        if (state_value.reaper) |thread| thread.join();
        state_value.allocator.free(state_value.jobs);
        state_value.allocator.destroy(state_value);
    }
    pub fn access(self: *Owner) *Executor {
        return @ptrCast(self);
    }
};

/// Worker-visible submission authority has no join or destruction operation.
pub const Executor = opaque {
    fn state(self: *Executor) *State {
        return @ptrCast(@alignCast(self));
    }
    /// Reserve reusable job storage before resource publication. Once prepared,
    /// submission (including cancellation escalation) never uses the allocator.
    pub fn prepare(self: *Executor) error{ OutOfMemory, Closed }!void {
        const state_value = self.state();
        std.Io.Threaded.mutexLock(&state_value.mutex);
        defer std.Io.Threaded.mutexUnlock(&state_value.mutex);
        if (state_value.phase == .closing) return error.Closed;
        if (state_value.jobs.len != 0) return;
        state_value.jobs = try state_value.allocator.alloc(Job, state_value.capacity);
    }
    /// Success consumes args' execution guards. Failure leaves them with the
    /// caller and invokes neither callback. `finish` runs after joining `run`;
    /// it must not wait for other retirement callbacks. The owner budgets one
    /// record per concurrent job plus one for the callback returning capacity.
    pub fn spawn(self: *Executor, comptime run: anytype, args: anytype, comptime finish: anytype) error{ OutOfMemory, Io, Closed }!void {
        const Args = @TypeOf(args);
        const Result = @typeInfo(@TypeOf(run)).@"fn".return_type.?;
        const Payload = struct {
            args: Args,
            result: union(enum) { pending, finished: Result } = .pending,
            fn data(job: *Job) *@This() {
                return @ptrCast(@alignCast(&job.payload));
            }
            fn main(job: *Job, state_value: *State) void {
                const task = data(job);
                const execution: *Execution = @ptrCast(state_value);
                task.result = .{ .finished = @call(.auto, run, .{execution} ++ task.args) };
                state_value.enqueue(job);
            }
            fn retire(job: *Job) void {
                const task = data(job);
                @call(.auto, finish, .{ task.args, task.result.finished });
            }
        };
        comptime {
            if (@sizeOf(Payload) > 128 or @alignOf(Payload) > 16)
                @compileError("controller job payload exceeds reserved storage");
        }
        try self.prepare();
        const state_value = self.state();
        std.Io.Threaded.mutexLock(&state_value.mutex);
        defer std.Io.Threaded.mutexUnlock(&state_value.mutex);
        if (state_value.phase == .closing) return error.Closed;
        const fresh = state_value.available == null;
        const job = state_value.available orelse if (state_value.unused < state_value.jobs.len)
            &state_value.jobs[state_value.unused]
        else
            return error.Io;
        // SAFETY: the size-checked typed payload is initialized below, before
        // the job becomes reachable by a thread or the retirement queue.
        if (fresh) job.* = .{ .payload = undefined };
        if (state_value.reaper == null)
            state_value.reaper = std.Thread.spawn(.{}, State.reap, .{state_value}) catch return error.Io;
        Payload.data(job).* = .{ .args = args };
        // The worker can run now, but cannot enqueue before this publication.
        const thread = std.Thread.spawn(.{}, Payload.main, .{ job, state_value }) catch return error.Io;
        if (fresh) state_value.unused += 1 else state_value.available = job.next;
        job.next = null;
        job.work = .{ .active = .{ .thread = thread, .retire = Payload.retire } };
        state_value.live += 1;
    }
};

/// Minted only inside a controller job. The worker-facing executor cannot
/// acquire this authority to wait for child execution.
pub const Execution = opaque {
    /// Run lane zero here and the other lanes independently. Failure invokes
    /// the backend's shutdown transition before draining every started lane.
    /// Returns only after all child threads and retirement callbacks finish.
    pub fn runLanes(self: *Execution, count: usize, context: anytype, comptime run: anytype, comptime failed: anytype, comptime ready: anytype) void {
        if (count == 0) @panic("controller requires an execution lane");
        const Context = @TypeOf(context);
        const Children = struct {
            mutex: std.Io.Mutex = .init,
            changed: std.Io.Condition = .init,
            live: usize = 0,
            fn start(_: *Execution, ctx: Context, lane: usize, _: *@This()) void {
                run(ctx, lane);
            }
            fn retire(args: struct { Context, usize, *@This() }, _: void) void {
                const group = args[2];
                std.Io.Threaded.mutexLock(&group.mutex);
                group.live -= 1;
                group.changed.broadcast(io());
                std.Io.Threaded.mutexUnlock(&group.mutex);
            }
        };
        var children: Children = .{};
        const executor: *Executor = @ptrCast(self);
        for (1..count) |lane| {
            std.Io.Threaded.mutexLock(&children.mutex);
            children.live += 1;
            executor.spawn(Children.start, .{ context, lane, &children }, Children.retire) catch {
                children.live -= 1;
                std.Io.Threaded.mutexUnlock(&children.mutex);
                failed(context);
                break;
            };
            std.Io.Threaded.mutexUnlock(&children.mutex);
        }
        ready(context);
        run(context, 0);
        std.Io.Threaded.mutexLock(&children.mutex);
        while (children.live != 0) children.changed.waitUncancelable(io(), &children.mutex);
        std.Io.Threaded.mutexUnlock(&children.mutex);
    }
};

/// Stream writers stop enqueueing synchronously; callback executors either
/// establish reusable state explicitly or require whole-resource shutdown.
pub const CancellationPolicy = enum { release, acknowledge, close_resource };
pub const CancelAction = enum { retired, interrupt, close_resource, settled };
pub const Completion = enum { retired, close_resource };
pub const ExecutionState = enum { queued, active, cancelling, reusable, cancelled, done };

/// Ordered controller-lane ownership, independent of execution, stream state,
/// and wake policy. Queue observations require the owning resource mutex.
/// A ticket owns its turn until retirement, even when execution is cancelled.
/// The queue address remains stable while tickets are linked.
pub fn Lane(comptime Cell: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            allocator: std.mem.Allocator,
            cell: *Cell,
            previous: ?*Node = null,
            next: ?*Node = null,
            phase: union(enum) { created, queued: *Self, active: *Self, retired } = .created,
            execution: ExecutionState = .queued,
        };
        pub const Ticket = opaque {
            fn node(self: *const Ticket) *Node {
                return @ptrCast(@alignCast(@constCast(self)));
            }
            pub fn create(allocator: std.mem.Allocator, cell: *Cell) error{OutOfMemory}!*Ticket {
                const entry = try allocator.create(Node);
                entry.* = .{ .allocator = allocator, .cell = cell };
                return @ptrCast(entry);
            }
            /// Consumes an unqueued or retired ticket. Cancel readiness first.
            pub fn destroy(self: *Ticket) void {
                if (self.linked()) @panic("destroying a queued controller ticket");
                const entry = self.node();
                entry.allocator.destroy(entry);
            }
            pub fn successor(self: *const Ticket) ?*Ticket {
                return if (self.node().next) |next| @ptrCast(next) else null;
            }
            pub fn owner(self: *const Ticket) *Cell {
                return self.node().cell;
            }
            pub fn checkCell(self: *const Ticket, cell: *Cell) void {
                if (self.owner() != cell or !self.linked()) @panic("invalid controller ticket");
            }
            /// Execution observations and transitions require the operation's
            /// state lock. Queue linkage additionally requires the resource
            /// lock, acquired first. Stream writers use that lock for both;
            /// byte ABI operations have a separate stream mutex.
            pub fn status(self: *const Ticket) ExecutionState {
                return self.node().execution;
            }
            pub fn isCancelled(self: *const Ticket) bool {
                return switch (self.status()) {
                    .cancelling, .reusable, .cancelled => true,
                    .queued, .active, .done => false,
                };
            }
            /// Only the turn owner may start work. Repeated stream advances
            /// keep the same active execution until completion or cancellation.
            pub fn begin(self: *Ticket) bool {
                if (!self.active()) return false;
                switch (self.status()) {
                    .queued => self.node().execution = .active,
                    .active => {},
                    .cancelling, .reusable, .cancelled, .done => return false,
                }
                return true;
            }
            pub fn requestCancellation(self: *Ticket) void {
                switch (self.status()) {
                    .queued, .active => self.node().execution = .cancelling,
                    .cancelling, .reusable, .cancelled, .done => {},
                }
            }
            /// Acknowledgement permits reuse only after the executor returns.
            pub fn acknowledgeCancellation(self: *Ticket) bool {
                if (self.status() != .cancelling) return false;
                self.node().execution = .reusable;
                return true;
            }
            fn finish(self: *Ticket) Completion {
                const result: Completion = if (self.status() == .cancelling) .close_resource else .retired;
                self.node().execution = switch (self.status()) {
                    .queued, .active, .done => .done,
                    .cancelling, .reusable, .cancelled => .cancelled,
                };
                return result;
            }
            pub fn active(self: *const Ticket) bool {
                return self.node().phase == .active;
            }
            pub fn linked(self: *const Ticket) bool {
                return switch (self.node().phase) {
                    .queued, .active => true,
                    .created, .retired => false,
                };
            }
        };
        count: usize = 0,
        first: ?*Node = null,
        last: ?*Node = null,

        pub fn front(self: *const Self) ?*Ticket {
            return if (self.first) |entry| @ptrCast(entry) else null;
        }
        pub fn empty(self: *const Self) bool {
            return self.front() == null;
        }
        pub fn hasCapacity(self: *const Self, limit: usize) bool {
            return self.count < limit;
        }
        /// Failure leaves a created ticket with the caller. Success consumes it.
        pub fn tryAppend(self: *Self, ticket: *Ticket, limit: usize) bool {
            if (!self.hasCapacity(limit)) return false;
            self.append(ticket);
            return true;
        }
        /// Consumes the ticket's created state into FIFO ownership.
        pub fn append(self: *Self, ticket: *Ticket) void {
            const node = ticket.node();
            if (node.phase != .created) @panic("controller ticket already admitted");
            if (self.last) |last| {
                last.next = node;
                node.previous = last;
                node.phase = .{ .queued = self };
            } else {
                self.first = node;
                node.phase = .{ .active = self };
            }
            self.last = node;
            self.count += 1;
        }
        /// Both the resource lock and the operation state lock must be held.
        /// The returned action is the only backend work cancellation requests.
        pub fn cancel(self: *Self, ticket: *Ticket, policy: CancellationPolicy) CancelAction {
            if (ticket.status() == .done or ticket.status() == .cancelled) return .settled;
            self.requireMember(ticket);
            switch (ticket.status()) {
                .queued => {
                    ticket.requestCancellation();
                    _ = ticket.acknowledgeCancellation();
                    _ = self.finishAndRemove(ticket);
                    return .retired;
                },
                .active => {
                    ticket.requestCancellation();
                    return switch (policy) {
                        .close_resource => .close_resource,
                        .acknowledge => .interrupt,
                        .release => released: {
                            _ = ticket.acknowledgeCancellation();
                            _ = self.finishAndRemove(ticket);
                            break :released .retired;
                        },
                    };
                },
                .cancelling, .reusable, .cancelled, .done => return .settled,
            }
        }
        /// Consumes execution and FIFO ownership. A returning executor that
        /// has not acknowledged active cancellation requires resource shutdown.
        pub fn complete(self: *Self, ticket: *Ticket) Completion {
            self.requireMember(ticket);
            return self.finishAndRemove(ticket);
        }
        fn requireMember(self: *const Self, ticket: *const Ticket) void {
            const linked_lane = switch (ticket.node().phase) {
                .queued, .active => |lane_owner| lane_owner,
                .created, .retired => @panic("controller ticket is not admitted"),
            };
            if (linked_lane != self) @panic("ticket belongs to another controller lane");
        }
        /// Retires a ticket and promotes its successor if it owned the turn.
        /// The caller notifies backend readiness, then destroys it outside the lock.
        fn finishAndRemove(self: *Self, ticket: *Ticket) Completion {
            const result = ticket.finish();
            const node = ticket.node();
            const was_active = ticket.active();
            if (node.previous) |previous| previous.next = node.next else self.first = node.next;
            if (node.next) |next| {
                next.previous = node.previous;
                if (was_active) next.phase = .{ .active = self };
            } else self.last = node.previous;
            self.count -= 1;
            node.phase = .retired;
            node.previous = null;
            node.next = null;
            return result;
        }
    };
}

test "native: shared lane admission and cancellation require acknowledged retirement" {
    const Queue = Lane(u8);
    var owner: u8 = 0;
    var lane: Queue = .{};
    // SAFETY: only the initialized prefix tracked by created is read.
    var tickets: [3]*Queue.Ticket = undefined;
    var created: usize = 0;
    defer for (tickets[0..created]) |ticket| {
        if (ticket.linked()) {
            _ = ticket.acknowledgeCancellation();
            _ = lane.complete(ticket);
        }
        ticket.destroy();
    };
    for (&tickets) |*ticket| {
        ticket.* = try Queue.Ticket.create(std.testing.allocator, &owner);
        created += 1;
    }
    const first, const queued, const successor = tickets;
    try std.testing.expect(lane.tryAppend(first, 2));
    try std.testing.expect(lane.tryAppend(queued, 2));
    try std.testing.expect(!lane.tryAppend(successor, 2));
    try std.testing.expect(first.begin());
    try std.testing.expect(!queued.begin());
    try std.testing.expectEqual(CancelAction.retired, lane.cancel(queued, .acknowledge));
    try std.testing.expect(lane.tryAppend(successor, 2));
    try std.testing.expectEqual(CancelAction.interrupt, lane.cancel(first, .acknowledge));
    try std.testing.expect(!successor.begin());
    try std.testing.expect(first.acknowledgeCancellation());
    try std.testing.expect(!successor.begin());
    try std.testing.expectEqual(Completion.retired, lane.complete(first));
    try std.testing.expect(successor.begin());
    try std.testing.expectEqual(CancelAction.interrupt, lane.cancel(successor, .acknowledge));
    try std.testing.expectEqual(Completion.close_resource, lane.complete(successor));
}

test "native: prepared controller jobs reuse storage without allocator access" {
    const Probe = struct {
        done: std.Io.Event = .unset,
        value: usize = 0,
        fn run(_: *Execution, _: *@This(), value: usize) usize {
            return value;
        }
        fn finish(args: struct { *@This(), usize }, value: usize) void {
            args[0].value = value;
            args[0].done.set(io());
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const owner = try Owner.init(failing.allocator(), 2);
    defer owner.deinit();
    const executor = owner.access();
    try executor.prepare();
    failing.fail_index = failing.alloc_index;
    var probe: Probe = .{};
    for (0..3) |index| {
        probe.done.reset();
        try executor.spawn(Probe.run, .{ &probe, index }, Probe.finish);
        probe.done.waitUncancelable(io());
        try std.testing.expectEqual(index, probe.value);
    }
    try std.testing.expect(!failing.has_induced_failure);
}
