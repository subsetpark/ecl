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
    external_ready,
    external_io,

    pub fn eql(a: WakeReason, b: WakeReason) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .task => |index| index == b.task,
            .timeout, .cancellation, .io, .out_of_memory, .external_ready, .external_io => true,
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
