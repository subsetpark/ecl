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
