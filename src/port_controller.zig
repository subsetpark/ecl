//! Internal port execution. Backends supply typed work and post-join retirement;
//! the extension ABI is only one producer. No ECL worker joins a controller.
const std = @import("std");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
const Job = struct {
    next: ?*Job = null,
    thread: union(enum) { unstarted, running: std.Thread } = .unstarted,
    retire: *const fn (*Job, std.mem.Allocator) void,
};

test "native: internal executor retires an independent job while another waits" {
    const Probe = struct {
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        retired: std.Io.Event = .unset,
        fn blocked(self: *@This()) u32 {
            self.started.set(io());
            self.release.waitUncancelable(io());
            return 41;
        }
        fn independent(self: *@This()) u32 {
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
    const owner = try Owner.init(std.testing.allocator);
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
            job.thread.running.join();
            job.retire(job, self.allocator);
            std.Io.Threaded.mutexLock(&self.mutex);
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
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Owner {
        const state_value = try allocator.create(State);
        state_value.* = .{ .allocator = allocator };
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
    /// Success consumes args' execution guards. Failure leaves them with the
    /// caller and invokes neither callback. `finish` runs after joining `run`;
    /// it must be bounded and must not wait for other retirement callbacks.
    pub fn spawn(self: *Executor, comptime run: anytype, args: anytype, comptime finish: anytype) error{ OutOfMemory, Io, Closed }!void {
        const Args = @TypeOf(args);
        const Result = @typeInfo(@TypeOf(run)).@"fn".return_type.?;
        const Task = struct {
            job: Job = .{ .retire = retire },
            executor: *State,
            args: Args,
            result: union(enum) { pending, finished: Result } = .pending,
            fn main(task: *@This()) void {
                task.result = .{ .finished = @call(.auto, run, task.args) };
                task.executor.enqueue(&task.job);
            }
            fn retire(job: *Job, allocator: std.mem.Allocator) void {
                const task: *@This() = @fieldParentPtr("job", job);
                @call(.auto, finish, .{ task.args, task.result.finished });
                allocator.destroy(task);
            }
        };
        const state_value = self.state();
        const task = try state_value.allocator.create(Task);
        errdefer state_value.allocator.destroy(task);
        task.* = .{ .executor = state_value, .args = args };
        std.Io.Threaded.mutexLock(&state_value.mutex);
        defer std.Io.Threaded.mutexUnlock(&state_value.mutex);
        if (state_value.phase == .closing) return error.Closed;
        if (state_value.reaper == null)
            state_value.reaper = std.Thread.spawn(.{}, State.reap, .{state_value}) catch return error.Io;
        // Publish the thread handle before main can enqueue the job.
        task.job.thread = .{ .running = std.Thread.spawn(.{}, Task.main, .{task}) catch return error.Io };
        state_value.live += 1;
    }
};
