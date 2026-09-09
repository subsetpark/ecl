//! Bounded byte transport shared by port endpoint adapters.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const controllers = @import("port_controller.zig");
const Ring = @import("byte_ring.zig").Ring;
const ErrorKind = @import("machine.zig").ErrorKind;
const max_chunk = 64 * 1024;

pub const Failure = @import("port_failure.zig").Failure(ErrorKind);
pub const Read = union(enum) { pending, eof, data: usize, failed: Failure };
pub const Write = union(enum) { pending, written: usize, failed: Failure };
pub const ControllerRead = union(enum) { eof, data: usize, cancelled, failed: Failure };
pub const ControllerWrite = union(enum) { complete, cancelled, out_of_memory, failed: Failure };
const Writers = controllers.Lane(State, .writer, .{ .retain = State.retainReadiness, .release = State.releaseReadiness, .write = State.writeLocked, .notify = State.notifyLocked, .source = State.source });
pub const WritePermit = Writers.Writer;

/// A stream's terminal fact cannot be replaced by later resource failure or
/// cleanup. The transport owns the lock and decides when accepted writers have
/// finished; every adapter uses these same monotonic transitions.
pub fn StreamPhase(comptime Fault: type) type {
    return union(enum) {
        open,
        finishing,
        eof,
        failed: Fault,

        pub fn terminal(self: @This()) bool {
            return switch (self) {
                .open, .finishing => false,
                .eof, .failed => true,
            };
        }
        pub fn finish(self: *@This()) void {
            if (self.* == .open) self.* = .finishing;
        }
        pub fn complete(self: *@This()) void {
            if (!self.terminal()) self.* = .eof;
        }
        pub fn fail(self: *@This(), failure: Fault) void {
            if (!self.terminal()) self.* = .{ .failed = failure };
        }
    };
}

const State = struct {
    host: *const heap.HostCleanup,
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(State) = .{},
    ring: Ring,
    writers: Writers,
    reader: bool = false,
    epoch: u64 = 0,
    phase: StreamPhase(Failure) = .open,

    fn capabilities(self: *State) Pair {
        return .{ .pipe = @ptrCast(self), .controller = @ptrCast(self) };
    }

    pub fn retainReadiness(self: *State) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.host.allocator();
        allocator.free(self.ring.bytes);
        allocator.destroy(self);
    }
    fn writeLocked(self: *State, turn: bool, bytes: []const u8) Write {
        switch (self.phase) {
            .failed => |failure| return .{ .failed = failure },
            .eof => return .{ .failed = Failure.init(.io, "port input is finished") },
            .open, .finishing => {},
        }
        if (!turn or self.ring.free() == 0) return .pending;
        const count = @min(bytes.len, self.ring.free(), max_chunk);
        self.ring.push(bytes[0..count]);
        self.notifyLocked();
        return .{ .written = count };
    }
    fn notifyLocked(self: *State) void {
        self.epoch +%= 1;
        if (self.phase == .finishing and self.writers.empty()) self.phase.complete();
        self.changed.broadcast(std.Io.Threaded.global_single_threaded.io());
        self.waits.notifyLocked(self);
    }
    fn source(self: *State, key: u64) external.ReadinessSource {
        return external.readinessSource(State, self, key);
    }
    pub fn registerReadiness(self: *State, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(State).register(self, key, target);
    }
    pub fn readyLocked(self: *State, key: u64) bool {
        if (key == 0) return self.ring.len != 0 or self.phase == .eof or self.phase == .failed;
        const writer: *const WritePermit = @ptrFromInt(key);
        return self.phase == .eof or self.phase == .failed or !writer.linked() or (writer.active() and self.ring.free() != 0);
    }
    pub fn wakeReasonLocked(_: *State, _: u64) external.Wake {
        return .ready;
    }
};

/// Scheduler-facing transport. Finishing refuses new calls while preserving
/// the FIFO turns already accepted. Terminal failure follows buffered output.
pub const Pipe = opaque {
    fn state(self: *Pipe) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn release(self: *Pipe) void {
        self.state().releaseReadiness();
    }
    pub fn readCapacity(self: *Pipe) usize {
        return @min(self.state().ring.bytes.len, max_chunk);
    }
    pub fn beginRead(self: *Pipe) error{ConcurrentRead}!void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.reader) return error.ConcurrentRead;
        owned.reader = true;
    }
    pub fn endRead(self: *Pipe) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        owned.reader = false;
        std.Io.Threaded.mutexUnlock(&owned.mutex);
    }
    pub fn read(self: *Pipe, bytes: []u8) Read {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.ring.len != 0) {
            const count = owned.ring.pop(bytes[0..@min(bytes.len, max_chunk)]);
            owned.notifyLocked();
            return .{ .data = count };
        }
        return switch (owned.phase) {
            .open, .finishing => .pending,
            .eof => .eof,
            .failed => |failure| .{ .failed = failure },
        };
    }
    pub fn readSource(self: *Pipe) external.ReadinessSource {
        return self.state().source(0);
    }
    pub fn beginWrite(self: *Pipe) error{ OutOfMemory, Finished }!*WritePermit {
        const owned = self.state();
        const prepared = try owned.writers.prepare(owned.host.allocator());
        errdefer prepared.discard();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase != .open) return error.Finished;
        return prepared.admitWriter(owned, std.math.maxInt(usize)).?;
    }
    pub fn finish(self: *Pipe) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        owned.phase.finish();
        owned.notifyLocked();
    }
    pub fn fail(self: *Pipe, failure: Failure, discard: bool) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (discard) owned.ring.discard();
        owned.phase.fail(failure);
        owned.notifyLocked();
    }
    pub fn interrupt(self: *Pipe) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        owned.notifyLocked();
        std.Io.Threaded.mutexUnlock(&owned.mutex);
    }
};

/// Blocking authority is issued only alongside construction by a host owner.
/// Its borrow cannot outlive the owning Pipe reference.
pub const Controller = opaque {
    fn state(self: *Controller) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn readChunk(self: *Controller, bytes: []u8, cancelled: *const std.atomic.Value(bool)) ControllerRead {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        while (!cancelled.load(.acquire) and owned.ring.len == 0 and (owned.phase == .open or owned.phase == .finishing))
            owned.changed.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &owned.mutex);
        if (cancelled.load(.acquire)) return .cancelled;
        if (owned.ring.len == 0) return switch (owned.phase) {
            .failed => |failure| .{ .failed = failure },
            .eof => .eof,
            .open, .finishing => unreachable,
        };
        const count = owned.ring.pop(bytes[0..@min(bytes.len, max_chunk)]);
        owned.notifyLocked();
        return .{ .data = count };
    }
    /// One FIFO admission covers the entire borrowed slice. Success accepts
    /// every byte; interruption may leave an accepted prefix. No caller retry
    /// is implied. The controller's borrow pins the pipe through this call.
    pub fn writeAll(self: *Controller, bytes: []const u8, cancelled: *const std.atomic.Value(bool)) ControllerWrite {
        const owned = self.state();
        const permit = owned.capabilities().pipe.beginWrite() catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Finished => .{ .failed = Failure.init(.io, "port output is finished") },
        };
        // Ending either a successful or interrupted turn wakes the next writer.
        defer permit.finish();
        var offset: usize = 0;
        while (offset < bytes.len) {
            std.Io.Threaded.mutexLock(&owned.mutex);
            const epoch = owned.epoch;
            std.Io.Threaded.mutexUnlock(&owned.mutex);
            if (cancelled.load(.acquire)) return .cancelled;
            switch (permit.write(bytes[offset..])) {
                .written => |count| offset += count,
                .failed => |failure| return .{ .failed = failure },
                .pending => {
                    std.Io.Threaded.mutexLock(&owned.mutex);
                    while (epoch == owned.epoch and !cancelled.load(.acquire))
                        owned.changed.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &owned.mutex);
                    std.Io.Threaded.mutexUnlock(&owned.mutex);
                },
            }
        }
        return .complete;
    }
};

pub const Pair = struct { pipe: *Pipe, controller: *Controller };
pub fn create(host: *const heap.HostCleanup, capacity: usize) error{ OutOfMemory, InvalidCapacity }!Pair {
    if (capacity == 0) return error.InvalidCapacity;
    const owned = try host.allocator().create(State);
    errdefer host.allocator().destroy(owned);
    const bytes = try host.allocator().alloc(u8, capacity);
    owned.* = .{ .host = host, .allocator = host.allocator(), .ring = .{ .bytes = bytes }, .writers = Writers.init(&owned.mutex) };
    return owned.capabilities();
}
