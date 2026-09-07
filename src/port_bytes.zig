//! Bounded byte transport shared by port endpoint adapters.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const controllers = @import("port_controller.zig");
const Ring = @import("byte_ring.zig").Ring;
const ErrorKind = @import("machine.zig").ErrorKind;
const max_chunk = 64 * 1024;

pub const Failure = struct {
    kind: ErrorKind,
    text: [4096]u8,
    len: usize,

    pub fn init(kind: ErrorKind, text: []const u8) Failure {
        // SAFETY: only the prefix initialized below is exposed through len.
        var result: Failure = .{ .kind = kind, .text = undefined, .len = @min(text.len, 4096) };
        if (result.len < text.len) while (result.len != 0 and text[result.len] & 0xc0 == 0x80) {
            result.len -= 1;
        };
        @memcpy(result.text[0..result.len], text[0..result.len]);
        return result;
    }
};
pub const Read = union(enum) { pending, eof, data: usize, failed: Failure };
pub const Write = union(enum) { pending, written: usize, failed: Failure };
const Writers = controllers.Lane(State, .writer, .{ .retain = State.retainReadiness, .release = State.releaseReadiness, .write = State.writeLocked, .notify = State.notifyLocked, .source = State.source });
pub const WritePermit = Writers.Writer;

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
    phase: union(enum) { open, finishing, eof, failed: Failure } = .open,

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
        if (self.phase == .finishing and self.writers.empty()) self.phase = .eof;
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
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase != .open) return error.Finished;
        return (try owned.writers.admitWriter(owned.host.allocator(), owned, std.math.maxInt(usize))).?;
    }
    pub fn finish(self: *Pipe) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase == .open) owned.phase = .finishing;
        owned.notifyLocked();
    }
    pub fn fail(self: *Pipe, failure: Failure, discard: bool) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (discard) owned.ring.discard();
        if (owned.phase == .open or owned.phase == .finishing) owned.phase = .{ .failed = failure };
        owned.notifyLocked();
    }
};

/// Blocking authority is issued only alongside construction by a host owner.
/// Its borrow cannot outlive the owning Pipe reference.
pub const Controller = opaque {
    fn state(self: *Controller) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn read(self: *Controller, bytes: []u8) usize {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        while (owned.ring.len == 0 and (owned.phase == .open or owned.phase == .finishing))
            owned.changed.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &owned.mutex);
        if (owned.phase == .failed) return 0;
        const count = owned.ring.pop(bytes[0..@min(bytes.len, max_chunk)]);
        owned.notifyLocked();
        return count;
    }
    pub fn write(self: *Controller, bytes: []const u8) usize {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        while (owned.ring.free() == 0 and owned.phase == .open)
            owned.changed.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &owned.mutex);
        if (owned.phase != .open) return 0;
        const count = @min(bytes.len, owned.ring.free(), max_chunk);
        owned.ring.push(bytes[0..count]);
        owned.notifyLocked();
        return count;
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
