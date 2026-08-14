//! Allocation-free ordered task-join policy.
//!
//! The evaluator shell owns task values, result buffers, and failure payloads.
//! This module decides progression, first-failure selection, suffix
//! cancellation, result placement, and completion.

pub const Failure = union(enum) {
    raised,
    contract: u32,
    out_of_memory,
};

pub const Summary = struct {
    count: u32,
    successes: u32,
    failure: ?Failure,
};

pub const Active = struct {
    count: u32,
    index: u32,
    successes: u32 = 0,
    failure: ?Failure = null,
};

pub const Join = union(enum) {
    active: Active,
    complete: Summary,

    pub fn successCount(self: Join) u32 {
        return switch (self) {
            .active => |active| active.successes,
            .complete => |summary| summary.successes,
        };
    }
};

pub const Event = enum {
    success,
    raised,
    contract,
    out_of_memory,
};

pub const Next = union(enum) {
    request: u32,
    finish,
};

pub const Command = struct {
    store_result: ?u32 = null,
    record_failure: ?Failure = null,
    cancel_from: ?u32 = null,
    next: Next,
};

pub const Decision = struct {
    next: Join,
    command: Command,
};

pub const TransitionError = error{InvalidTransition};

pub fn start(count: u32) Decision {
    if (count == 0) return .{
        .next = .{ .complete = .{ .count = 0, .successes = 0, .failure = null } },
        .command = .{ .next = .finish },
    };
    return .{
        .next = .{ .active = .{ .count = count, .index = 0 } },
        .command = .{ .next = .{ .request = 0 } },
    };
}

pub fn decide(before: Join, event: Event) TransitionError!Decision {
    var active = switch (before) {
        .active => |state| state,
        .complete => return error.InvalidTransition,
    };
    if (active.index >= active.count or active.successes > active.index)
        return error.InvalidTransition;

    var command = Command{ .next = .finish };
    if (active.failure == null) switch (event) {
        .success => {
            command.store_result = active.successes;
            active.successes += 1;
        },
        .raised => {
            active.failure = .raised;
            command.record_failure = .raised;
            command.cancel_from = active.index + 1;
        },
        .contract => {
            active.failure = .{ .contract = active.index };
            command.record_failure = active.failure;
            command.cancel_from = active.index + 1;
        },
        .out_of_memory => {
            active.failure = .out_of_memory;
            command.record_failure = .out_of_memory;
            command.cancel_from = active.index + 1;
        },
    };

    active.index += 1;
    if (active.index == active.count) {
        command.next = .finish;
        return .{
            .next = .{ .complete = .{
                .count = active.count,
                .successes = active.successes,
                .failure = active.failure,
            } },
            .command = command,
        };
    }
    command.next = .{ .request = active.index };
    return .{ .next = .{ .active = active }, .command = command };
}
