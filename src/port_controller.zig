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
