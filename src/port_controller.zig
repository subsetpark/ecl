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

pub fn Outcome(comptime Result: type) type {
    return union(enum) { aborted, completed: Result };
}

/// Owns one resource pin across startup, controller jobs, and synchronous
/// cancellation setup. Callers borrow activities; only this boundary retires
/// them. The final callback runs after root return, all joins, and all borrows.
pub fn Group(comptime Cell: type, comptime Result: type, comptime lifetime: anytype) type {
    return opaque {
        const Self = @This();
        const Terminal = Outcome(Result);
        const Data = struct {
            allocator: std.mem.Allocator,
            executor: *Executor,
            cell: *Cell,
            mutex: std.Io.Mutex = .init,
            phase: union(enum) { provisional, open: usize, draining: struct { count: usize, outcome: Terminal }, retired } = .provisional,
        };
        fn data(self: *Self) *Data {
            return @ptrCast(@alignCast(self));
        }
        pub fn init(allocator: std.mem.Allocator, executor: *Executor, cell: *Cell) error{OutOfMemory}!*Self {
            const state = try allocator.create(Data);
            state.* = .{ .allocator = allocator, .executor = executor, .cell = cell };
            return @ptrCast(state);
        }
        /// The resource's final destructor consumes the drained group storage.
        pub fn deinit(self: *Self) void {
            const state = self.data();
            switch (state.phase) {
                .provisional, .retired => state.allocator.destroy(state),
                .open, .draining => @panic("destroying a live controller group"),
            }
        }
        /// Preparation may publish cancellation access. Failure always runs
        /// rollback before surrendering the root; success transfers the root
        /// into the executor. No backend receives its release authority.
        pub fn start(self: *Self, args: anytype, comptime prepare: anytype, comptime run: anytype, comptime rollback: fn (*Cell) void) (@typeInfo(@typeInfo(@TypeOf(prepare)).@"fn".return_type.?).error_union.error_set || error{ OutOfMemory, Io, Closed })!void {
            const state = self.data();
            lifetime.retain(state.cell);
            std.Io.Threaded.mutexLock(&state.mutex);
            switch (state.phase) {
                .provisional => state.phase = .{ .open = 1 },
                .open, .draining, .retired => @panic("controller group already started"),
            }
            std.Io.Threaded.mutexUnlock(&state.mutex);
            errdefer {
                rollback(state.cell);
                self.dropRoot(.aborted);
            }
            try @call(.auto, prepare, .{state.cell} ++ args);
            const Root = struct {
                fn main(execution: *Execution, group: *Self) Result {
                    return run(execution, group.data().cell);
                }
                fn retire(values: struct { *Self }, result: Result) void {
                    values[0].dropRoot(.{ .completed = result });
                }
            };
            try state.executor.spawn(Root.main, .{self}, Root.retire);
        }
        fn acquire(self: *Self) bool {
            const state = self.data();
            std.Io.Threaded.mutexLock(&state.mutex);
            defer std.Io.Threaded.mutexUnlock(&state.mutex);
            switch (state.phase) {
                .open => |*count| count.* += 1,
                .provisional, .draining, .retired => return false,
            }
            return true;
        }
        fn dropRoot(self: *Self, outcome: Terminal) void {
            const state = self.data();
            std.Io.Threaded.mutexLock(&state.mutex);
            const outstanding = state.phase.open;
            state.phase = .{ .draining = .{ .count = outstanding, .outcome = outcome } };
            std.Io.Threaded.mutexUnlock(&state.mutex);
            self.release();
        }
        fn release(self: *Self) void {
            const state = self.data();
            std.Io.Threaded.mutexLock(&state.mutex);
            const outcome: ?Terminal = switch (state.phase) {
                .open => |*count| blk: {
                    count.* -= 1;
                    break :blk null;
                },
                .draining => |*draining| blk: {
                    draining.count -= 1;
                    break :blk if (draining.count == 0) draining.outcome else null;
                },
                .provisional, .retired => unreachable,
            };
            if (outcome != null) state.phase = .retired;
            std.Io.Threaded.mutexUnlock(&state.mutex);
            if (outcome) |terminal| {
                const cell = state.cell;
                std.Io.Threaded.mutexLock(&cell.mutex);
                lifetime.retireLocked(cell, terminal);
                var detached = lifetime.ownership(cell).release();
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                lifetime.release(cell);
                detached.detachAll();
            }
            // Releasing the execution pin may destroy the cell and this group.
        }
        /// The callback borrows the resource for exactly its dynamic extent.
        /// A declined activity runs no callback and owns no release obligation.
        pub fn with(self: *Self, args: anytype, comptime function: anytype) void {
            if (!self.acquire()) return;
            defer self.release();
            @call(.auto, function, .{self.data().cell} ++ args);
        }
        /// Failure returns all acquired lifetime to the group; arguments remain
        /// caller-owned. Success owns them until the shared executor joins.
        pub fn spawn(self: *Self, args: anytype, comptime run: anytype) error{ OutOfMemory, Io, Closed }!void {
            if (!self.acquire()) return error.Closed;
            errdefer self.release();
            const Args = @TypeOf(args);
            const JobWork = struct {
                fn main(execution: *Execution, group: *Self, values: Args) void {
                    @call(.auto, run, .{ execution, group.data().cell } ++ values);
                }
                fn retire(values: struct { *Self, Args }, _: void) void {
                    values[0].release();
                }
            };
            try self.data().executor.spawn(JobWork.main, .{ self, args }, JobWork.retire);
        }
    };
}

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
const CancellationPolicy = enum { release, acknowledge, close_resource };
pub const CancelAction = enum { retired, interrupt, close_resource, settled };
pub const Completion = enum { retired, close_resource };
pub const ExecutionState = enum { preparing, queued, active, cancelling, reusable, cancelled, done };

/// Invocation-local execution authority, minted only while lending a callback.
pub const Running = opaque {
    const Invocation = struct { context: *anyopaque, acknowledge: *const fn (*anyopaque) bool };
    pub fn acknowledgeCancellation(self: *Running) bool {
        const state: *Invocation = @ptrCast(@alignCast(self));
        return state.acknowledge(state.context);
    }
};

pub const CallbackCancellation = enum { acknowledge, close_resource };

/// Admission binds a node to its owner and lane before publishing a handle.
/// Callback payloads and tickets share one allocation; queue and observer
/// references keep it alive. Writer allocations pin their resource until release.
/// Only this boundary unlinks nodes or completes callback execution.
pub fn Lane(comptime Cell: type, comptime mode: enum { operation, writer }, comptime callbacks: anytype) type {
    return struct {
        const Self = @This();
        const owns_cell = mode == .operation;
        const Node = struct {
            allocator: std.mem.Allocator,
            cell: if (owns_cell) Cell else *Cell,
            lane: *Self,
            refs: std.atomic.Value(usize) = .init(2),
            previous: ?*Node = null,
            next: ?*Node = null,
            phase: enum { queued, active, retired },
            execution: ExecutionState = .queued,
            executing: bool = false,

            fn owner(self: *Node) *Cell {
                return if (owns_cell) &self.cell else self.cell;
            }
            fn retain(self: *Node) void {
                _ = self.refs.fetchAdd(1, .monotonic);
            }
            fn release(self: *Node) void {
                if (self.refs.fetchSub(1, .acq_rel) != 1) return;
                const allocator = self.allocator;
                if (owns_cell) {
                    callbacks.deinit(&self.cell);
                    allocator.destroy(self);
                } else {
                    const cell = self.cell;
                    allocator.destroy(self);
                    callbacks.release(cell);
                }
            }
            fn begin(self: *Node) bool {
                if (self.phase != .active) return false;
                switch (self.execution) {
                    .queued => self.execution = .active,
                    .active => {},
                    .preparing, .cancelling, .reusable, .cancelled, .done => return false,
                }
                return true;
            }
            fn requestCancellation(self: *Node) void {
                if (owns_cell and self.execution == .active and !self.executing) return;
                switch (self.execution) {
                    .preparing, .queued, .active => self.execution = .cancelling,
                    .cancelling, .reusable, .cancelled, .done => {},
                }
            }
            fn acknowledgeErased(raw: *anyopaque) bool {
                const self: *Node = @ptrCast(@alignCast(raw));
                return self.acknowledge();
            }
            fn acknowledge(self: *Node) bool {
                if (self.execution != .cancelling) return false;
                self.execution = .reusable;
                return true;
            }
        };
        /// An operation observer owns storage, but cannot begin or complete
        /// backend execution or remove queue entries. Releasing an observer
        /// cannot destroy an operation still owned by its queue.
        pub const Ticket = opaque {
            fn entry(self: *const Ticket) *Node {
                return @ptrCast(@alignCast(@constCast(self)));
            }
            pub fn retain(self: *Ticket) void {
                self.entry().retain();
            }
            /// Consumes one observer reference. Queue ownership is independent.
            pub fn release(self: *Ticket) void {
                self.entry().release();
            }
            pub fn owner(self: *const Ticket) *Cell {
                return self.entry().owner();
            }
            pub fn successor(self: *const Ticket) ?*Ticket {
                return if (self.entry().next) |next| @ptrCast(next) else null;
            }
            pub fn status(self: *const Ticket) ExecutionState {
                return self.entry().execution;
            }
            /// The resource and operation locks are held. Publication follows
            /// successful scope attachment; cancellation cannot be reversed.
            pub fn publish(self: *Ticket) bool {
                const node = self.entry();
                if (node.execution != .preparing) return false;
                node.execution = .queued;
                return true;
            }
            pub fn isCancelled(self: *const Ticket) bool {
                return switch (self.status()) {
                    .cancelling, .reusable, .cancelled => true,
                    .preparing, .queued, .active, .done => false,
                };
            }
            /// Resource shutdown marks operations under their state lock.
            pub fn requestCancellation(self: *Ticket) void {
                self.entry().requestCancellation();
            }
            pub fn cancel(self: *Ticket) void {
                const node = self.entry();
                const cell = node.owner();
                const mutex = node.lane.mutex;
                std.Io.Threaded.mutexLock(mutex);
                std.Io.Threaded.mutexLock(&cell.mutex);
                const policy: CallbackCancellation = callbacks.cancelPolicy(cell);
                const action = node.lane.cancelNode(node, switch (policy) {
                    .acknowledge => .acknowledge,
                    .close_resource => .close_resource,
                });
                callbacks.notifyOperation(cell);
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                callbacks.cancelResource(cell, action);
                std.Io.Threaded.mutexUnlock(mutex);
                if (action == .retired) {
                    callbacks.retireOperation(cell);
                    node.release();
                }
            }
        };
        /// A writer owns a turn across incremental calls. All operations derive
        /// the resource from its admission; there is no separate cell argument.
        pub const Writer = opaque {
            fn entry(self: *const Writer) *Node {
                return @ptrCast(@alignCast(@constCast(self)));
            }
            pub fn linked(self: *const Writer) bool {
                return self.entry().phase != .retired;
            }
            pub fn active(self: *const Writer) bool {
                return self.entry().phase == .active;
            }
            pub fn write(self: *Writer, bytes: []const u8) @typeInfo(@TypeOf(callbacks.write)).@"fn".return_type.? {
                const node = self.entry();
                const cell = node.owner();
                std.Io.Threaded.mutexLock(&cell.mutex);
                defer std.Io.Threaded.mutexUnlock(&cell.mutex);
                return callbacks.write(cell, node.begin(), bytes);
            }
            pub fn source(self: *Writer) @typeInfo(@TypeOf(callbacks.source)).@"fn".return_type.? {
                return callbacks.source(self.entry().owner(), @intFromPtr(self));
            }
            pub fn finish(self: *Writer) void {
                self.end(false);
            }
            pub fn cancel(self: *Writer) void {
                self.end(true);
            }
            fn end(self: *Writer, cancelled: bool) void {
                const node = self.entry();
                const cell = node.owner();
                std.Io.Threaded.mutexLock(&cell.mutex);
                if (cancelled) {
                    _ = node.lane.cancelNode(node, .release);
                } else {
                    _ = node.lane.finishAndRemove(node);
                }
                callbacks.notify(cell);
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                node.release(); // queue ownership
                node.release(); // writer ownership
            }
        };
        mutex: *std.Io.Mutex,
        count: usize = 0,
        first: ?*Node = null,
        last: ?*Node = null,

        pub fn init(mutex: *std.Io.Mutex) Self {
            return .{ .mutex = mutex };
        }
        pub fn front(self: *const Self) ?*Ticket {
            return if (self.first) |node| @ptrCast(node) else null;
        }
        pub fn empty(self: *const Self) bool {
            return self.first == null;
        }
        /// Called with the resource lock held. Unpublished admission reserves
        /// FIFO position but cannot lend execution authority to a controller.
        pub fn dispatchable(self: *const Self) bool {
            const node = self.first orelse return false;
            const cell = node.owner();
            std.Io.Threaded.mutexLock(&cell.mutex);
            defer std.Io.Threaded.mutexUnlock(&cell.mutex);
            return node.execution != .preparing;
        }
        pub fn hasCapacity(self: *const Self, limit: usize) bool {
            return self.count < limit;
        }
        fn allocate(self: *Self, allocator: std.mem.Allocator, limit: usize) error{OutOfMemory}!?*Node {
            if (!self.hasCapacity(limit)) return null;
            const node = try allocator.create(Node);
            node.allocator = allocator;
            node.lane = self;
            node.refs = .init(2);
            node.previous = self.last;
            node.next = null;
            node.phase = if (self.first == null) .active else .queued;
            node.execution = if (owns_cell) .preparing else .queued;
            node.executing = false;
            // The owning payload is initialized by the factory before append.
            return node;
        }
        fn append(self: *Self, node: *Node) void {
            if (self.last) |last| last.next = node else self.first = node;
            self.last = node;
            self.count += 1;
        }
        /// Uninitialized admission storage, allocated outside publication
        /// locks. It owns no operation payload until admission succeeds.
        pub const Prepared = opaque {
            fn entry(self: *Prepared) *Node {
                return @ptrCast(@alignCast(self));
            }
            pub fn discard(self: *Prepared) void {
                const node = self.entry();
                node.allocator.destroy(node);
            }
            /// Requires the issuing resource lock. Success consumes this
            /// candidate; capacity rejection retains it without initializing
            /// or consuming args. Initialization cannot allocate or fail.
            pub fn admit(self: *Prepared, limit: usize, args: anytype, comptime initialize: anytype) ?*Ticket {
                const node = self.entry();
                const lane = node.lane;
                if (!lane.hasCapacity(limit)) return null;
                node.refs = .init(2);
                node.previous = lane.last;
                node.next = null;
                node.phase = if (lane.first == null) .active else .queued;
                node.execution = .preparing;
                node.executing = false;
                const ticket: *Ticket = @ptrCast(node);
                @call(.auto, initialize, .{ &node.cell, ticket } ++ args);
                lane.append(node);
                return ticket;
            }
        };
        pub fn prepare(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!*Prepared {
            if (!owns_cell) @compileError("stream lanes admit writer permits");
            const node = try allocator.create(Node);
            node.allocator = allocator;
            node.lane = self;
            return @ptrCast(node);
        }
        pub fn admitWriter(self: *Self, allocator: std.mem.Allocator, cell: *Cell, limit: usize) error{OutOfMemory}!?*Writer {
            if (owns_cell) @compileError("callback lanes admit operation observers");
            const node = try self.allocate(allocator, limit) orelse return null;
            node.cell = cell;
            callbacks.retain(cell);
            self.append(node);
            return @ptrCast(node);
        }
        /// One lane executor owns dispatch. The runtime establishes both locks,
        /// lends execution authority, and completes only after callback return.
        pub fn runNext(self: *Self) bool {
            const mutex = self.mutex;
            std.Io.Threaded.mutexLock(mutex);
            const node = self.first orelse {
                std.Io.Threaded.mutexUnlock(mutex);
                return false;
            };
            const cell = node.owner();
            std.Io.Threaded.mutexLock(&cell.mutex);
            if (node.execution == .preparing) {
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                std.Io.Threaded.mutexUnlock(mutex);
                return false;
            }
            const execute = callbacks.runnable(cell) and node.begin();
            node.executing = execute;
            if (!execute) node.requestCancellation();
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            std.Io.Threaded.mutexUnlock(mutex);
            if (execute) {
                var execution: Running.Invocation = .{ .context = node, .acknowledge = Node.acknowledgeErased };
                callbacks.execute(cell, @as(*Running, @ptrCast(&execution)));
                std.Io.Threaded.mutexLock(&cell.mutex);
                node.executing = false;
                std.Io.Threaded.mutexUnlock(&cell.mutex);
            }
            std.Io.Threaded.mutexLock(mutex);
            std.Io.Threaded.mutexLock(&cell.mutex);
            const completion = self.finishAndRemove(node);
            callbacks.notifyOperation(cell);
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            callbacks.completeResource(cell, completion);
            std.Io.Threaded.mutexUnlock(mutex);
            callbacks.retireOperation(cell);
            node.release();
            return true;
        }
        fn cancelNode(self: *Self, node: *Node, policy: CancellationPolicy) CancelAction {
            switch (node.execution) {
                .preparing, .queued => {
                    node.requestCancellation();
                    _ = node.acknowledge();
                    _ = self.finishAndRemove(node);
                    return .retired;
                },
                .active => {
                    if (owns_cell and !node.executing) return .settled;
                    node.requestCancellation();
                    return switch (policy) {
                        .close_resource => .close_resource,
                        .acknowledge => .interrupt,
                        .release => blk: {
                            _ = node.acknowledge();
                            _ = self.finishAndRemove(node);
                            break :blk .retired;
                        },
                    };
                },
                .cancelling, .reusable, .cancelled, .done => return .settled,
            }
        }
        fn finishAndRemove(self: *Self, node: *Node) Completion {
            const result: Completion = if (node.execution == .cancelling) .close_resource else .retired;
            node.execution = switch (node.execution) {
                .preparing, .queued, .active, .done => .done,
                .cancelling, .reusable, .cancelled => .cancelled,
            };
            const was_active = node.phase == .active;
            if (node.previous) |previous| previous.next = node.next else self.first = node.next;
            if (node.next) |next| {
                next.previous = node.previous;
                if (was_active) next.phase = .active;
            } else self.last = node.previous;
            self.count -= 1;
            node.phase = .retired;
            node.previous = null;
            node.next = null;
            return result;
        }
    };
}

test "native: shared lane owns admission and writer retirement" {
    const Probe = struct {
        mutex: std.Io.Mutex = .init,
        pins: usize = 0,
        bytes: usize = 0,
        fn retain(self: *@This()) void {
            self.pins += 1;
        }
        fn release(self: *@This()) void {
            self.pins -= 1;
        }
        fn write(self: *@This(), turn: bool, bytes: []const u8) ?usize {
            if (!turn) return null;
            self.bytes += bytes.len;
            return bytes.len;
        }
        fn notify(_: *@This()) void {}
        fn source(_: *@This(), _: u64) u64 {
            return 7;
        }
    };
    const Queue = Lane(Probe, .writer, .{ .retain = Probe.retain, .release = Probe.release, .write = Probe.write, .notify = Probe.notify, .source = Probe.source });
    var probe: Probe = .{};
    var lane = Queue.init(&probe.mutex);
    var owned: [3]?*Queue.Writer = .{null} ** 3;
    defer for (owned) |entry| {
        if (entry) |writer| writer.cancel();
    };
    owned[0] = try lane.admitWriter(std.testing.allocator, &probe, 2);
    owned[1] = try lane.admitWriter(std.testing.allocator, &probe, 2);
    try std.testing.expect((try lane.admitWriter(std.testing.allocator, &probe, 2)) == null);
    const first = owned[0].?;
    const second = owned[1].?;
    try std.testing.expectEqual(@as(?usize, 2), first.write("ab"));
    try std.testing.expect(second.write("x") == null);
    owned[1] = null;
    second.cancel();
    owned[2] = try lane.admitWriter(std.testing.allocator, &probe, 2);
    const third = owned[2].?;
    try std.testing.expect(!third.active());
    owned[0] = null;
    first.finish();
    try std.testing.expect(third.active());
    try std.testing.expectEqual(@as(u64, 7), third.source());
    try std.testing.expectEqual(@as(?usize, 1), third.write("c"));
    owned[2] = null;
    third.finish();
    try std.testing.expectEqual(@as(usize, 3), probe.bytes);
    try std.testing.expectEqual(@as(usize, 0), probe.pins);
}

test "native: lane ownership outlives released operation observers" {
    const Probe = struct {
        mutex: std.Io.Mutex = .init,
        executed: usize = 0,
        destroyed: usize = 0,
    };
    const Operation = struct {
        mutex: std.Io.Mutex = .init,
        probe: *Probe,
        value: usize,
        fn initialize(self: *@This(), _: anytype, probe: *Probe, value: usize) void {
            self.* = .{ .probe = probe, .value = value };
        }
        fn deinit(self: *@This()) void {
            self.probe.destroyed += 1;
        }
        fn runnable(_: *@This()) bool {
            return true;
        }
        fn execute(self: *@This(), _: *Running) void {
            self.probe.executed += self.value;
        }
        fn notify(_: *@This()) void {}
        fn complete(_: *@This(), _: Completion) void {}
        fn cancellation(_: *@This()) CallbackCancellation {
            return .acknowledge;
        }
        fn cancelResource(_: *@This(), _: CancelAction) void {}
    };
    const Queue = Lane(Operation, .operation, .{ .deinit = Operation.deinit, .runnable = Operation.runnable, .execute = Operation.execute, .notifyOperation = Operation.notify, .completeResource = Operation.complete, .cancelPolicy = Operation.cancellation, .cancelResource = Operation.cancelResource, .retireOperation = struct {
        fn retire(_: *Operation) void {}
    }.retire });
    var probe: Probe = .{};
    var lane = Queue.init(&probe.mutex);
    var observers: [2]?*Queue.Ticket = .{null} ** 2;
    defer {
        for (observers) |observer| if (observer) |ticket| {
            ticket.cancel();
            ticket.release();
        };
        while (lane.runNext()) {}
    }
    observers[0] = (try lane.prepare(std.testing.allocator)).admit(2, .{ &probe, @as(usize, 17) }, Operation.initialize);
    observers[1] = (try lane.prepare(std.testing.allocator)).admit(2, .{ &probe, @as(usize, 23) }, Operation.initialize);
    const rejected = try lane.prepare(std.testing.allocator);
    try std.testing.expect(rejected.admit(2, .{ &probe, @as(usize, 99) }, Operation.initialize) == null);
    rejected.discard();
    const first = observers[0].?;
    try std.testing.expect(!lane.runNext());
    try std.testing.expectEqual(@as(usize, 0), probe.executed);
    try std.testing.expect(observers[1].?.publish());
    try std.testing.expect(!lane.runNext());
    try std.testing.expect(first.publish());
    observers[0] = null;
    first.release();
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed);
    try std.testing.expect(lane.runNext());
    try std.testing.expectEqual(@as(usize, 17), probe.executed);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed);
    const retained = observers[1].?;
    retained.retain();
    retained.release();
    try std.testing.expect(lane.runNext());
    try std.testing.expectEqual(ExecutionState.done, retained.status());
    try std.testing.expectEqual(@as(usize, 40), probe.executed);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed);
    observers[1] = null;
    retained.release();
    try std.testing.expectEqual(@as(usize, 2), probe.destroyed);
    const unpublished = (try lane.prepare(std.testing.allocator)).admit(2, .{ &probe, @as(usize, 99) }, Operation.initialize).?;
    defer unpublished.release();
    unpublished.cancel();
    try std.testing.expect(!unpublished.publish());
    try std.testing.expect(!lane.runNext());
    try std.testing.expectEqual(ExecutionState.cancelled, unpublished.status());
    try std.testing.expectEqual(@as(usize, 40), probe.executed);
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
