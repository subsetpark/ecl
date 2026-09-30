//! Allocation-free scheduler policy.
//!
//! This module knows nothing about threads, locks, clocks, queues, task
//! payloads, or the evaluator.  It accepts immutable state plus one event and
//! returns the next state and the command an imperative scheduler must carry
//! out.  The same transition functions drive the runtime shell and the
//! generated interleaving model tests.

const std = @import("std");

pub const Completion = enum(u2) {
    success,
    language_error,
    out_of_memory,
};

pub const WakeReason = union(enum) {
    task: u32,
    timeout,
    cancellation,
    io,
    out_of_memory,
    /// The wait's deadline lies beyond any instant its clock can report.
    overflow,
    external_ready,
    external_io,

    pub fn eql(a: WakeReason, b: WakeReason) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .task => |index| index == b.task,
            .timeout, .cancellation, .io, .out_of_memory, .overflow, .external_ready, .external_io => true,
        };
    }
};

const Active = struct {
    cancellation_requested: bool = false,
};

pub const Unit = union(enum) {
    constructing,
    ready: Active,
    running: Active,
    parked: Active,
    closing: Completion,
    done: Completion,

    pub fn phase(self: Unit) UnitPhase {
        return std.meta.activeTag(self);
    }

    pub fn cancellationRequested(self: Unit) bool {
        return switch (self) {
            .ready, .running, .parked => |active| active.cancellation_requested,
            .constructing, .closing, .done => false,
        };
    }
};

pub const UnitPhase = std.meta.Tag(Unit);

pub const UnitEvent = union(enum) {
    publish,
    dispatch,
    yield,
    park,
    wake: WakeReason,
    cancel,
    body_finished: Completion,
    scope_quiescent,
};

pub const UnitCommand = union(enum) {
    none,
    enqueue,
    cancel_before_dispatch,
    register_wait,
    race_cancellation,
    close_scope,
    publish: Completion,
};

pub const UnitDecision = struct {
    next: Unit,
    command: UnitCommand,
};

pub const TransitionError = error{InvalidTransition};

pub fn decideUnit(before: Unit, event: UnitEvent) TransitionError!UnitDecision {
    return switch (before) {
        .constructing => switch (event) {
            .publish => .{ .next = .{ .ready = .{} }, .command = .enqueue },
            else => error.InvalidTransition,
        },
        .ready => |active| switch (event) {
            .dispatch => .{
                .next = .{ .running = active },
                .command = if (active.cancellation_requested)
                    .cancel_before_dispatch
                else
                    .none,
            },
            .cancel => .{
                .next = .{ .ready = .{ .cancellation_requested = true } },
                .command = .none,
            },
            else => error.InvalidTransition,
        },
        .running => |active| switch (event) {
            .yield => .{ .next = .{ .ready = active }, .command = .enqueue },
            .park => if (active.cancellation_requested)
                .{
                    .next = .{ .ready = active },
                    .command = .enqueue,
                }
            else
                .{ .next = .{ .parked = active }, .command = .register_wait },
            .cancel => .{
                .next = .{ .running = .{ .cancellation_requested = true } },
                .command = .none,
            },
            .body_finished => |completion| .{
                .next = .{ .closing = completion },
                .command = .close_scope,
            },
            else => error.InvalidTransition,
        },
        .parked => |active| switch (event) {
            .wake => .{ .next = .{ .ready = active }, .command = .enqueue },
            .cancel => .{
                .next = .{ .parked = .{ .cancellation_requested = true } },
                .command = .race_cancellation,
            },
            else => error.InvalidTransition,
        },
        .closing => |completion| switch (event) {
            .cancel => .{ .next = before, .command = .none },
            .scope_quiescent => .{
                .next = .{ .done = completion },
                .command = .{ .publish = completion },
            },
            else => error.InvalidTransition,
        },
        .done => switch (event) {
            .cancel => .{ .next = before, .command = .none },
            else => error.InvalidTransition,
        },
    };
}

pub const Wait = union(enum) {
    registering,
    selected: WakeReason,
    active,
    delivered: WakeReason,
};

pub const WaitEvent = union(enum) {
    activate,
    candidate: WakeReason,
};

pub const WaitCommand = union(enum) {
    none,
    deliver: WakeReason,
};

pub const WaitDecision = struct {
    next: Wait,
    command: WaitCommand,
};

pub fn decideWait(before: Wait, event: WaitEvent) TransitionError!WaitDecision {
    return switch (before) {
        .registering => switch (event) {
            .activate => .{ .next = .active, .command = .none },
            .candidate => |candidate| .{
                .next = .{ .selected = candidate },
                .command = .none,
            },
        },
        .selected => |winner| switch (event) {
            .activate => .{
                .next = .{ .delivered = winner },
                .command = .{ .deliver = winner },
            },
            .candidate => .{ .next = before, .command = .none },
        },
        .active => switch (event) {
            .activate => error.InvalidTransition,
            .candidate => |candidate| .{
                .next = .{ .delivered = candidate },
                .command = .{ .deliver = candidate },
            },
        },
        .delivered => switch (event) {
            .activate => error.InvalidTransition,
            .candidate => .{ .next = before, .command = .none },
        },
    };
}

/// Ownership phase for one stable wake registration. The directory reference
/// belongs to its WaitSet. A linked cell reference becomes a delivery
/// reference when completion detaches the node. Cleanup and delivery may then
/// occur in either order without leaving a borrowed pointer behind.
pub const Registration = enum {
    directory,
    linked,
    detached,
    directory_after_delivery,
    delivery_after_cleanup,
    retired,

    pub fn ownerCount(self: Registration) u2 {
        return switch (self) {
            .directory, .directory_after_delivery, .delivery_after_cleanup => 1,
            .linked, .detached => 2,
            .retired => 0,
        };
    }
};

pub const RegistrationEvent = enum {
    link,
    detach,
    cleanup,
    delivery_returned,
};

pub const RegistrationCommand = struct {
    unlink: bool = false,
    retain_external: bool = false,
    release_directory: bool = false,
    release_external: bool = false,
};

pub const RegistrationDecision = struct {
    next: Registration,
    command: RegistrationCommand,
};

pub fn decideRegistration(
    before: Registration,
    event: RegistrationEvent,
) TransitionError!RegistrationDecision {
    return switch (before) {
        .directory => switch (event) {
            .link => .{
                .next = .linked,
                .command = .{ .retain_external = true },
            },
            .cleanup => .{
                .next = .retired,
                .command = .{ .release_directory = true },
            },
            else => error.InvalidTransition,
        },
        .linked => switch (event) {
            .detach => .{ .next = .detached, .command = .{} },
            .cleanup => .{
                .next = .retired,
                .command = .{
                    .unlink = true,
                    .release_directory = true,
                    .release_external = true,
                },
            },
            else => error.InvalidTransition,
        },
        .detached => switch (event) {
            .cleanup => .{
                .next = .delivery_after_cleanup,
                .command = .{ .release_directory = true },
            },
            .delivery_returned => .{
                .next = .directory_after_delivery,
                .command = .{ .release_external = true },
            },
            else => error.InvalidTransition,
        },
        .directory_after_delivery => switch (event) {
            .cleanup => .{
                .next = .retired,
                .command = .{ .release_directory = true },
            },
            else => error.InvalidTransition,
        },
        .delivery_after_cleanup => switch (event) {
            .delivery_returned => .{
                .next = .retired,
                .command = .{ .release_external = true },
            },
            else => error.InvalidTransition,
        },
        .retired => error.InvalidTransition,
    };
}

pub const Scope = union(enum) {
    open: u32,
    closing: u32,
    closed,

    pub fn childCount(self: Scope) u32 {
        return switch (self) {
            .open, .closing => |count| count,
            .closed => 0,
        };
    }
};

pub const ScopeEvent = enum {
    register_child,
    child_terminal,
    close,
};

pub const ScopeCommand = enum {
    none,
    cancel_arriving_child,
    cancel_children,
    notify_quiescent,
};

pub const ScopeDecision = struct {
    next: Scope,
    command: ScopeCommand,
};

pub fn decideScope(before: Scope, event: ScopeEvent) TransitionError!ScopeDecision {
    return switch (before) {
        .open => |count| switch (event) {
            .register_child => if (count == std.math.maxInt(u32))
                error.InvalidTransition
            else
                .{ .next = .{ .open = count + 1 }, .command = .none },
            .child_terminal => if (count == 0)
                error.InvalidTransition
            else
                .{ .next = .{ .open = count - 1 }, .command = .none },
            .close => if (count == 0)
                .{ .next = .closed, .command = .notify_quiescent }
            else
                .{ .next = .{ .closing = count }, .command = .cancel_children },
        },
        .closing => |count| switch (event) {
            .register_child => if (count == std.math.maxInt(u32))
                error.InvalidTransition
            else
                .{
                    .next = .{ .closing = count + 1 },
                    .command = .cancel_arriving_child,
                },
            .child_terminal => if (count == 0)
                error.InvalidTransition
            else if (count == 1)
                .{ .next = .closed, .command = .notify_quiescent }
            else
                .{ .next = .{ .closing = count - 1 }, .command = .none },
            .close => .{ .next = before, .command = .none },
        },
        .closed => switch (event) {
            .register_child => .{
                .next = .{ .closing = 1 },
                .command = .cancel_arriving_child,
            },
            .close => .{ .next = before, .command = .notify_quiescent },
            .child_terminal => error.InvalidTransition,
        },
    };
}

/// Evaluation admission. At most `limit` evaluations hold a slot; the rest
/// wait first-come in a queue the shell owns. A cancelling evaluation runs
/// outside admission so cancellation never waits behind the work it stops.
pub const AdmissionNode = enum { idle, waiting, granted };

pub const AdmissionPool = struct {
    admitted: usize,
    limit: usize,
    queue_empty: bool,
    /// Reclamation is behind; no new slot is granted until it catches up.
    backpressured: bool,
};

pub const QueueChange = enum { none, join, leave };

pub const AdmissionDecision = struct {
    node: AdmissionNode,
    admitted: usize,
    queue: QueueChange,
    /// The evaluation may run its slice now.
    run: bool,
};

/// An evaluation asks to run a slice.
pub fn decideAcquire(pool: AdmissionPool, node: AdmissionNode, cancelling: bool) AdmissionDecision {
    if (cancelling) return .{
        .node = if (node == .waiting) .idle else node,
        .admitted = pool.admitted,
        .queue = if (node == .waiting) .leave else .none,
        .run = true,
    };
    return switch (node) {
        .granted => .{ .node = .granted, .admitted = pool.admitted, .queue = .none, .run = true },
        .waiting => .{ .node = .waiting, .admitted = pool.admitted, .queue = .none, .run = false },
        // A newcomer takes a free slot directly only when nobody is waiting,
        // so it can never overtake the queue.
        .idle => if (pool.queue_empty and !pool.backpressured and pool.admitted < pool.limit)
            .{ .node = .granted, .admitted = pool.admitted + 1, .queue = .none, .run = true }
        else
            .{ .node = .waiting, .admitted = pool.admitted, .queue = .join, .run = false },
    };
}

/// Whether one scheduler turn grants the queue's head a slot.
pub fn decideGrant(pool: AdmissionPool) bool {
    return !pool.queue_empty and !pool.backpressured and pool.admitted < pool.limit;
}

pub const ReleaseDecision = struct { node: AdmissionNode, admitted: usize };

/// An evaluation's slice returned. A cancelling one that bypassed admission
/// holds nothing to release.
pub fn decideRelease(pool: AdmissionPool, node: AdmissionNode) TransitionError!ReleaseDecision {
    return switch (node) {
        .granted => .{ .node = .idle, .admitted = pool.admitted - 1 },
        .idle => .{ .node = .idle, .admitted = pool.admitted },
        .waiting => error.InvalidTransition,
    };
}

/// Cancellation reached an evaluation. A waiting one leaves the queue and
/// runs outside admission.
pub fn decideCancel(node: AdmissionNode) struct { node: AdmissionNode, leave_and_run: bool } {
    return if (node == .waiting) .{ .node = .idle, .leave_and_run = true } else .{ .node = node, .leave_and_run = false };
}

/// Executors alternate between ready work and retirement when both are
/// available, so neither a continuously ready task nor a reclamation backlog
/// starves the other.
pub const ExecutorTurn = enum { ready, retirement };

pub fn chooseExecutorTurn(
    next: ExecutorTurn,
    ready: bool,
    retirement: bool,
) ?struct { turn: ExecutorTurn, next: ExecutorTurn } {
    if (!ready and !retirement) return null;
    if (!ready) return .{ .turn = .retirement, .next = next };
    if (!retirement) return .{ .turn = .ready, .next = next };
    return .{ .turn = next, .next = if (next == .ready) .retirement else .ready };
}

test "external readiness and cancellation still publish one wait winner" {
    const selected = try decideWait(.registering, .{ .candidate = .external_ready });
    try std.testing.expectEqual(Wait{ .selected = .external_ready }, selected.next);
    try std.testing.expectEqual(WaitCommand.none, selected.command);
    const loser = try decideWait(selected.next, .{ .candidate = .cancellation });
    try std.testing.expectEqual(selected.next, loser.next);
    try std.testing.expectEqual(WaitCommand.none, loser.command);
    const delivered = try decideWait(loser.next, .activate);
    try std.testing.expectEqual(Wait{ .delivered = .external_ready }, delivered.next);
    try std.testing.expectEqual(WaitCommand{ .deliver = .external_ready }, delivered.command);
}

/// A model of the scheduler shell's admission operations, driven entirely by
/// the decisions above, for exhaustive exploration. Node 0 is the root: it has
/// no ready-queue entry, so its own acquire also drives a grant turn.
const AdmissionModel = struct {
    const nodes = 3;
    const limit = 2;

    state: [nodes]AdmissionNode = @splat(.idle),
    cancelled: [nodes]bool = @splat(false),
    running: [nodes]bool = @splat(false),
    ticket: [nodes]u32 = @splat(0),
    queue: [nodes]u8 = @splat(0),
    queue_len: usize = 0,
    admitted: usize = 0,
    backpressured: bool = false,
    next_ticket: u32 = 1,

    const Op = union(enum) { acquire: u8, release: u8, cancel: u8, grant_turn, backpressure: bool };

    fn pool(self: *const AdmissionModel) AdmissionPool {
        return .{
            .admitted = self.admitted,
            .limit = limit,
            .queue_empty = self.queue_len == 0,
            .backpressured = self.backpressured,
        };
    }

    fn removeFromQueue(self: *AdmissionModel, node: u8) void {
        var write: usize = 0;
        for (self.queue[0..self.queue_len]) |queued| {
            if (queued == node) continue;
            self.queue[write] = queued;
            write += 1;
        }
        self.queue_len = write;
    }

    fn grantTurn(self: *AdmissionModel) !void {
        if (!decideGrant(self.pool())) return;
        const head = self.queue[0];
        // First-come: the head joined before every other waiter.
        for (self.queue[1..self.queue_len]) |other| try std.testing.expect(self.ticket[head] < self.ticket[other]);
        self.removeFromQueue(head);
        self.state[head] = .granted;
        self.admitted += 1;
    }

    /// Applies one shell operation; returns false when it is not enabled.
    fn apply(self: *AdmissionModel, op: Op) !bool {
        switch (op) {
            .acquire => |node| {
                if (self.running[node]) return false;
                const decision = decideAcquire(self.pool(), self.state[node], self.cancelled[node]);
                // A newcomer takes a slot directly only when nobody waits.
                if (self.state[node] == .idle and decision.node == .granted)
                    try std.testing.expectEqual(@as(usize, 0), self.queue_len);
                switch (decision.queue) {
                    .none => {},
                    .join => {
                        self.queue[self.queue_len] = node;
                        self.queue_len += 1;
                        self.ticket[node] = self.next_ticket;
                        self.next_ticket += 1;
                    },
                    .leave => self.removeFromQueue(node),
                }
                self.state[node] = decision.node;
                self.admitted = decision.admitted;
                if (node == 0) try self.grantTurn();
                self.running[node] = decision.run or self.state[node] == .granted;
            },
            .release => |node| {
                if (!self.running[node]) return false;
                const decision = try decideRelease(self.pool(), self.state[node]);
                self.state[node] = decision.node;
                self.admitted = decision.admitted;
                self.running[node] = false;
                try self.grantTurn();
            },
            .cancel => |node| {
                if (self.cancelled[node]) return false;
                self.cancelled[node] = true;
                const decision = decideCancel(self.state[node]);
                if (decision.leave_and_run) self.removeFromQueue(node);
                self.state[node] = decision.node;
            },
            .grant_turn => try self.grantTurn(),
            .backpressure => |on| {
                if (self.backpressured == on) return false;
                self.backpressured = on;
                if (!on) try self.grantTurn();
            },
        }
        return true;
    }

    fn checkInvariants(self: *const AdmissionModel) !void {
        var granted: usize = 0;
        var waiting: usize = 0;
        for (self.state, self.cancelled, self.running, 0..) |state, cancelled, running, node| {
            if (state == .granted) granted += 1;
            if (state == .waiting) {
                waiting += 1;
                // Cancellation never leaves an evaluation waiting for a slot.
                try std.testing.expect(!cancelled);
                try std.testing.expect(std.mem.indexOfScalar(u8, self.queue[0..self.queue_len], @intCast(node)) != null);
            }
            // Only a granted or a cancelling evaluation runs a slice.
            if (running) try std.testing.expect(state == .granted or cancelled);
        }
        try std.testing.expectEqual(granted, self.admitted);
        try std.testing.expect(self.admitted <= limit);
        try std.testing.expectEqual(waiting, self.queue_len);
    }

    /// Once reclamation catches up, slices that finish and turns that grant
    /// drain the queue: nobody waits forever.
    fn checkDrains(start: AdmissionModel) !void {
        var model = start;
        _ = try model.apply(.{ .backpressure = false });
        for (0..4 * nodes) |_| {
            for (0..nodes) |raw| {
                const node: u8 = @intCast(raw);
                if (model.running[node]) _ = try model.apply(.{ .release = node });
                if (model.state[node] == .granted and !model.running[node]) _ = try model.apply(.{ .acquire = node });
            }
            try model.grantTurn();
            try model.checkInvariants();
        }
        try std.testing.expectEqual(@as(usize, 0), model.queue_len);
    }
};

fn exploreAdmission(model: AdmissionModel, depth: usize) !void {
    try model.checkInvariants();
    try AdmissionModel.checkDrains(model);
    if (depth == 0) return;
    var ops: [3 * AdmissionModel.nodes + 3]AdmissionModel.Op = undefined;
    var count: usize = 0;
    for (0..AdmissionModel.nodes) |raw| {
        const node: u8 = @intCast(raw);
        ops[count] = .{ .acquire = node };
        ops[count + 1] = .{ .release = node };
        ops[count + 2] = .{ .cancel = node };
        count += 3;
    }
    ops[count] = .grant_turn;
    ops[count + 1] = .{ .backpressure = true };
    ops[count + 2] = .{ .backpressure = false };
    count += 3;
    for (ops[0..count]) |op| {
        var next = model;
        if (try next.apply(op)) try exploreAdmission(next, depth - 1);
    }
}

test "admission conserves slots, serves waiters first-come, and always drains" {
    try exploreAdmission(.{}, 6);
}

test "executor turns alternate when both classes are available" {
    for ([_]ExecutorTurn{ .ready, .retirement }) |next| {
        for ([_]bool{ false, true }) |ready| {
            for ([_]bool{ false, true }) |retirement| {
                const chosen = chooseExecutorTurn(next, ready, retirement) orelse {
                    try std.testing.expect(!ready and !retirement);
                    continue;
                };
                try std.testing.expect((chosen.turn == .ready and ready) or (chosen.turn == .retirement and retirement));
                if (ready and retirement) {
                    try std.testing.expectEqual(next, chosen.turn);
                    try std.testing.expect(chosen.next != chosen.turn);
                } else try std.testing.expectEqual(next, chosen.next);
            }
        }
    }
}
