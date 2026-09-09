//! Terminal exchange facts and one-time result publication for every adapter.
const std = @import("std");
const heap = @import("heap.zig");
const scheduler = @import("scheduler.zig");
const messages = @import("port_messages.zig");
const Publication = @import("port_resource.zig").Publication;
const Failure = @import("port_bytes.zig").Failure;
const Value = @import("value.zig").Value;

pub const Terminal = union(enum) { success, cancelled, failed: Failure };
pub const Completion = union(enum) { pending, ready, cancelled, failed: Failure };
pub const Claim = union(enum) { pending, claimed, value: Value, cancelled, failed: Failure };

const State = struct {
    host: *const heap.HostCleanup,
    mutex: std.Io.Mutex = .init,
    phase: union(enum) { running, terminal: Terminal } = .running,
    value: union(enum) { available: *messages.Envelope, claimed, discarded, rejected },

    fn capability(self: *State) *Result {
        return @ptrCast(self);
    }
};

/// The exchange owns this state until all observers and controller execution
/// have released it. Completion never consumes the result or drains transport.
pub const Result = opaque {
    fn state(self: *Result) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(host: *const heap.HostCleanup) error{OutOfMemory}!*Result {
        const owned = try host.allocator().create(State);
        errdefer host.allocator().destroy(owned);
        const initial = try messages.Envelope.empty(host);
        owned.* = .{ .host = host, .value = .{ .available = initial } };
        return owned.capability();
    }
    /// Consumes the state after the owning exchange has joined its users.
    pub fn release(self: *Result) void {
        const owned = self.state();
        if (owned.value == .available) owned.value.available.release();
        owned.host.allocator().destroy(owned);
    }
    /// Success consumes the envelope. Rejection retains it. Previous result
    /// storage retires outside the state lock, including provisional children.
    pub fn replace(self: *Result, incoming: *messages.Envelope) bool {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        if (owned.phase != .running or owned.value != .available) {
            std.Io.Threaded.mutexUnlock(&owned.mutex);
            return false;
        }
        const previous = owned.value.available;
        owned.value = .{ .available = incoming };
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        previous.release();
        return true;
    }
    /// Called only after controller return and cancellation acknowledgement.
    /// The first terminal fact wins; repeating observation cannot revise it.
    pub fn complete(self: *Result, terminal: Terminal) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase == .running) owned.phase = .{ .terminal = terminal };
    }
    pub fn completion(self: *Result) Completion {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        return switch (owned.phase) {
            .running => .pending,
            .terminal => |terminal| switch (terminal) {
                .success => .ready,
                .cancelled => .cancelled,
                .failed => |failure| .{ .failed = failure },
            },
        };
    }
    pub fn discard(self: *Result) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        const discarded = if (owned.value == .available) owned.value.available else null;
        if (discarded != null) owned.value = .discarded;
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (discarded) |item| item.release();
    }
    /// The caller reserves output capacity first. Success publishes every
    /// provisional attachment and claims the value atomically. Allocation and
    /// scope failures retain the result; terminal rejection discards it. No
    /// second caller can claim even a scalar-only value.
    pub fn claim(self: *Result, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing, Overflow }!Claim {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        const view = if (owned.value == .available) owned.value.available.borrow() else null;
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        defer if (view) |item| item.release();
        var publication: ResultPublication = .{ .state = owned, .view = view };
        defer if (publication.consumed) |item| item.release();
        try Publication.deliver(owned.host, if (view) |item| item.attachments() else &.{}, scope, &publication);
        return publication.result;
    }
};

const ResultPublication = struct {
    state: *State,
    view: ?*messages.View,
    consumed: ?*messages.Envelope = null,
    result: Claim = .pending,
    pub fn lock(self: *@This()) void {
        std.Io.Threaded.mutexLock(&self.state.mutex);
    }
    pub fn unlock(self: *@This()) void {
        std.Io.Threaded.mutexUnlock(&self.state.mutex);
    }
    pub fn validate(self: *@This()) bool {
        switch (self.state.phase) {
            .running => return false,
            .terminal => |terminal| switch (terminal) {
                .success => {},
                .cancelled => {
                    if (self.state.value == .available) self.reject();
                    self.result = .cancelled;
                    return false;
                },
                .failed => |failure| {
                    self.result = .{ .failed = failure };
                    return false;
                },
            },
        }
        self.result = switch (self.state.value) {
            .claimed => .claimed,
            .rejected => .cancelled,
            .discarded => .{ .failed = Failure.init(.io, "exchange result was discarded by close") },
            .available => .pending,
        };
        return self.state.value == .available and self.view != null and self.view.?.observes(self.state.value.available);
    }
    pub fn reject(self: *@This()) void {
        self.consumed = self.state.value.available;
        self.state.value = .rejected;
        self.result = .cancelled;
    }
    pub fn publish(self: *@This()) void {
        const item = self.state.value.available;
        self.result = .{ .value = item.value() };
        heap.retainValue(item.value());
        self.consumed = item;
        self.state.value = .claimed;
    }
};
