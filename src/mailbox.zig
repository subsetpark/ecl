//! A task's mailbox: the only thing an address names.
//!
//! Every task owns one mailbox, created with its cell and closed when the
//! cell's unit becomes terminal. An address value holds a reference to the
//! mailbox and nothing else, so an address can travel through any mailbox
//! without closing a reference cycle: the mailbox never points back at the
//! cell, the cell's result, or any value that could hold an address. The
//! mailbox is a readiness cell in the sense of `external.WaitList`: a
//! receiver waits on `.receive`, a sender under pressure waits on `.space`,
//! and closing wakes both, so no wait outlives the task it watches.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const external = @import("external.zig");
const poll = @import("poll.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");

const Value = value.Value;

/// The readiness predicates one mailbox exposes. They are distinct keys of
/// one wait list, so a sender and a receiver can wait on the same mailbox at
/// once and a message or a closed mailbox wakes only the waits it satisfies.
pub const Key = enum(u64) {
    receive = 0,
    space = 1,
};

/// One queued message. The runtime fills `from` with nothing; a composed
/// caller that wants a reply puts the address to reply to in the value it
/// sends.
pub const Message = struct {
    value: Value,
};

/// Queue depth. A sender parks when the ring is full, so this bounds the
/// values a mailbox holds for a receiver that has not asked for them.
pub const capacity: usize = 16;

pub const EnqueueResult = enum { accepted, full, closed };

pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    identity: u64,
    /// One reference for the owning task cell, one per address value, one
    /// per registered readiness wait or source.
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    waits: external.WaitList(Mailbox) = .{},
    ring: [capacity]Message,
    head: usize = 0,
    length: usize = 0,
    phase: enum { open, closed } = .open,

    pub fn create(allocator: std.mem.Allocator, identity: u64) error{OutOfMemory}!*Mailbox {
        const self = try allocator.create(Mailbox);
        // SAFETY: `length` is zero, so no slot is read before `enqueue` writes it.
        self.* = .{ .allocator = allocator, .identity = identity, .ring = undefined };
        return self;
    }

    pub fn retain(self: *Mailbox) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// The final release destroys the mailbox. By then it holds no message:
    /// a mailbox that was ever open was closed and drained by its task before
    /// the cell released it, and an address keeps the drained shell alive.
    pub fn release(self: *Mailbox) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.length == 0);
        self.allocator.destroy(self);
    }

    /// Closes the mailbox: every queued value is released, and every waiting
    /// receiver and sender wakes to observe the closed phase.
    pub fn close(self: *Mailbox, releases: *heap.ReleaseDomain) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.phase == .closed) return;
        self.phase = .closed;
        while (self.length > 0) {
            const message = self.ring[self.head];
            self.head = (self.head + 1) % capacity;
            self.length -= 1;
            releases.releaseValue(message.value);
        }
        self.waits.notifyLocked(self);
    }

    /// Mints an address value holding one reference to this mailbox.
    pub fn createAddress(self: *Mailbox, allocator: std.mem.Allocator) error{OutOfMemory}!Value {
        self.retain();
        errdefer self.release();
        return heap.createAddress(Mailbox, allocator, self.identity, self);
    }

    pub fn releaseAddress(self: *Mailbox) void {
        self.release();
    }

    /// The mailbox an address value names.
    pub fn fromAddress(address: Value) *Mailbox {
        return @ptrCast(@alignCast(heap.addressTarget(address.address)));
    }

    /// Queues a message the caller owns. Ownership moves only on `accepted`;
    /// a full or closed mailbox leaves it with the caller.
    pub fn enqueue(self: *Mailbox, message: Message) EnqueueResult {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.phase == .closed) return .closed;
        if (self.length == capacity) return .full;
        self.ring[(self.head + self.length) % capacity] = message;
        self.length += 1;
        self.waits.notifyLocked(self);
        return .accepted;
    }

    /// Takes the oldest message, waking a sender parked for space.
    pub fn dequeue(self: *Mailbox) ?Message {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.length == 0) return null;
        const message = self.ring[self.head];
        self.head = (self.head + 1) % capacity;
        self.length -= 1;
        self.waits.notifyLocked(self);
        return message;
    }

    pub fn readinessSource(self: *Mailbox, key: Key) external.ReadinessSource {
        return external.readinessSource(Mailbox, self, @backingInt(key));
    }

    // The readiness-cell contract `external.WaitList` requires.

    pub fn retainReadiness(self: *Mailbox) void {
        self.retain();
    }

    pub fn releaseReadiness(self: *Mailbox) void {
        self.release();
    }

    pub fn registerReadiness(self: *Mailbox, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Mailbox).register(self, key, target);
    }

    pub fn readyLocked(self: *Mailbox, key: u64) bool {
        if (self.phase == .closed) return true;
        return switch (@as(Key, @fromBackingInt(@intCast(key)))) {
            .receive => self.length > 0,
            .space => self.length < capacity,
        };
    }

    pub fn wakeReasonLocked(_: *Mailbox, _: u64) external.Wake {
        return .ready;
    }
};

/// Refuses a payload holding a task handle anywhere, in slices of a lent
/// work budget. Only generic spines and dicts are entered: a flat specialized
/// list holds scalars by construction, so it is accepted in one step however
/// long it is. Addresses and ports pass; a handle would let the receiver
/// reach a task's cached result and close a reference cycle.
pub const HandleCheck = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;
    const Frame = union(enum) {
        item: Value,
        sequence: struct { item: Value, next: usize, count: usize },
    };
    frames: poll.ChunkStack(Frame),

    pub fn init(allocator: std.mem.Allocator, root: Value) error{OutOfMemory}!HandleCheck {
        var frames = poll.ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .item = root });
        return .{ .frames = frames };
    }

    pub fn retire(self: *HandleCheck, releases: *heap.ReleaseDomain) void {
        self.frames.retire(releases);
    }

    fn visit(self: *HandleCheck, item: Value) error{ Handle, OutOfMemory }!void {
        switch (item) {
            .task => return error.Handle,
            .int, .float, .char, .symbol, .port, .address => {},
            .list => |header| {
                if (header.kind() != .generic_spine) return;
                const count: usize = @intCast(header.length());
                if (count != 0) try self.frames.push(.{ .sequence = .{ .item = item, .next = 0, .count = count } });
            },
            .dict => |header| {
                const count: usize = @as(usize, @intCast(header.length())) * 2;
                if (count != 0) try self.frames.push(.{ .sequence = .{ .item = item, .next = 0, .count = count } });
            },
        }
    }

    pub fn advance(self: *HandleCheck, budget: *poll.WorkBudget) error{ Handle, OutOfMemory }!poll.Progress(void) {
        while (budget.spend()) {
            const frame = self.frames.pop() orelse return .complete;
            switch (frame) {
                .item => |item| try self.visit(item),
                .sequence => |sequence| {
                    const item = if (sequence.item == .list)
                        list.atUnchecked(sequence.item, sequence.next)
                    else if (sequence.next % 2 == 0)
                        dict.keyAt(sequence.item.dict, sequence.next / 2)
                    else
                        dict.valueAt(sequence.item.dict, sequence.next / 2);
                    if (sequence.next + 1 < sequence.count) try self.frames.push(.{ .sequence = .{
                        .item = sequence.item,
                        .next = sequence.next + 1,
                        .count = sequence.count,
                    } });
                    try self.visit(item);
                },
            }
        }
        return .pending;
    }
};
