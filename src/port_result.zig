//! Terminal exchange facts and one-time result publication for every adapter.
const std = @import("std");
const heap = @import("heap.zig");
const scheduler = @import("scheduler.zig");
const messages = @import("port_messages.zig");
const Publication = @import("port_resource.zig").Publication;
const Failure = @import("port_bytes.zig").Failure;
const diagnostics = @import("port_error_data.zig");
const Value = @import("value.zig").Value;

pub const Terminal = union(enum) { success, cancelled, failed: Failure };
pub const Completion = union(enum) { pending, ready, cancelled, failed: diagnostics.Observation };
pub const Claim = union(enum) { pending, claimed, value: Value, cancelled, failed: diagnostics.Observation };

/// A prepared failure is borrowed from its issuing exchange through retirement.
/// Its immutable report and diagnostics cannot be changed after construction.
pub const PreparedFailure = opaque {};
const Choice = struct {
    failure: Failure,
    details: *diagnostics.Owned,
    next: ?*Choice = null,
    fn capability(self: *Choice) *const PreparedFailure {
        return @ptrCast(self);
    }
};
const max_failure_choices = 32;
const State = struct {
    host: *const heap.HostCleanup,
    mutex: std.Io.Mutex = .init,
    phase: union(enum) { running, frozen, terminal: Terminal } = .running,
    details: ?*diagnostics.Owned = null,
    choices: struct { first: ?*Choice = null, last: ?*Choice = null, count: usize = 0, selected: ?*Choice = null } = .{},
    value: union(enum) { available: *messages.Envelope, claimed, discarded, rejected },

    /// Callers hold mutex while choosing the immutable terminal view.
    fn diagnosticView(self: *const State) ?*const diagnostics.View {
        return if (self.choices.selected) |choice| choice.details.view() else if (self.details) |details| details.view() else null;
    }

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
        if (owned.details) |details| details.release();
        var choice = owned.choices.first;
        // At most max_failure_choices records exist; diagnostic release only
        // enqueues bounded value retirement in the issuing reclamation domain.
        while (choice) |current| {
            choice = current.next;
            current.details.release();
            owned.host.allocator().destroy(current);
        }
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
    /// Success consumes diagnostics; rejection retains them. Final release owns
    /// their retirement even after close discards ordinary result storage.
    pub fn replaceDetails(self: *Result, incoming: *diagnostics.Owned) bool {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        if (owned.phase != .running) {
            std.Io.Threaded.mutexUnlock(&owned.mutex);
            return false;
        }
        const previous = owned.details;
        owned.details = incoming;
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (previous) |details| details.release();
        return true;
    }
    /// Success consumes diagnostics; failure retains them. Both the report and
    /// diagnostic envelope are allocated before commit can freeze this result.
    pub fn prepareFailure(self: *Result, failure: Failure, details: *diagnostics.Owned) error{ OutOfMemory, InvalidState, Overflow }!void {
        const owned = self.state();
        const choice = try owned.host.allocator().create(Choice);
        errdefer owned.host.allocator().destroy(choice);
        choice.* = .{ .failure = failure, .details = details };
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase != .running) return error.InvalidState;
        if (owned.choices.count == max_failure_choices) return error.Overflow;
        if (owned.choices.last) |last| last.next = choice else owned.choices.first = choice;
        owned.choices.last = choice;
        owned.choices.count += 1;
    }
    pub fn preparedFailure(self: *Result) ?*const PreparedFailure {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase != .running) return null;
        return if (owned.choices.last) |choice| choice.capability() else null;
    }
    /// Selection performs no allocation or value mutation. Validate identity
    /// against this issuer before dereferencing an extension-supplied token.
    pub fn selectFailure(self: *Result, token: *const PreparedFailure) ?Failure {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase != .frozen or owned.choices.selected != null) return null;
        var cursor = owned.choices.first;
        while (cursor) |choice| : (cursor = choice.next) {
            if (choice.capability() != token) continue;
            owned.choices.selected = choice;
            return choice.failure;
        }
        return null;
    }
    /// Reserve immutable, capability-free output before irreversible work.
    /// Rejection preserves the current result. No allocation or publication of
    /// provisional resource attachments can follow this transition.
    pub fn freeze(self: *Result) bool {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        if (owned.phase == .terminal or owned.value != .available) {
            std.Io.Threaded.mutexUnlock(&owned.mutex);
            return false;
        }
        const view = owned.value.available.borrow();
        const permitted = view.attachments().len == 0;
        if (permitted) owned.phase = .frozen;
        std.Io.Threaded.mutexUnlock(&owned.mutex);
        view.release();
        return permitted;
    }
    pub fn mutable(self: *Result) bool {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        return owned.phase == .running and owned.value == .available;
    }
    /// Called only after controller return and cancellation acknowledgement.
    /// The first terminal fact wins; repeating observation cannot revise it.
    pub fn complete(self: *Result, terminal: Terminal) void {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        if (owned.phase != .terminal) owned.phase = .{ .terminal = terminal };
    }
    pub fn completion(self: *Result) Completion {
        const owned = self.state();
        std.Io.Threaded.mutexLock(&owned.mutex);
        defer std.Io.Threaded.mutexUnlock(&owned.mutex);
        return switch (owned.phase) {
            .running, .frozen => .pending,
            .terminal => |terminal| switch (terminal) {
                .success => .ready,
                .cancelled => .cancelled,
                .failed => |failure| .{ .failed = .{ .report = failure, .details = owned.diagnosticView() } },
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
            .running, .frozen => return false,
            .terminal => |terminal| switch (terminal) {
                .success => {},
                .cancelled => {
                    if (self.state.value == .available) self.reject();
                    self.result = .cancelled;
                    return false;
                },
                .failed => |failure| {
                    self.result = .{ .failed = .{ .report = failure, .details = self.state.diagnosticView() } };
                    return false;
                },
            },
        }
        self.result = switch (self.state.value) {
            .claimed => .claimed,
            .rejected => .cancelled,
            .discarded => .{ .failed = .{ .report = Failure.init(.io, "exchange result was discarded by close") } },
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
