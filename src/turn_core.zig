//! Allocation-free turn policy for a unit's kernel budget.
//!
//! A unit has one budget per turn. This module knows nothing about drivers,
//! frames, or cancellation flags: it accepts the budget, one charge or one
//! driver outcome, and returns what the evaluator must do next. The machine
//! loop carries the decision out; the tests below enumerate every case.

const std = @import("std");
const poll = @import("poll.zig");

/// Why a driver ends its turn without finishing.
pub const Yield = enum {
    /// The driver installed a park request; the unit parks until it is woken.
    park,
    /// The driver waits on something outside its own work: another unit, a
    /// slot's turn, a contended load, or the host.
    wait,
    /// Work that must finish regardless of cancellation, such as a failure
    /// unwind or a completion's cleanup, spent the budget. Ending the turn
    /// here must not observe cancellation.
    settle,
};

pub const Outcome = union(enum) {
    /// Unfinished work that drew on the budget; it may be cancelled between
    /// steps.
    stepped,
    yielded: Yield,
};

pub const Action = enum { resume_driver, end_turn, park };

pub const Decision = struct {
    action: Action,
    /// The step's charge reached the end of the turn, so cancellation must be
    /// observed before anything else runs.
    poll_cancellation: bool,
};

pub const InvalidTurn = error{InvalidTurn};

/// Charges work already committed. Returns true when the charge reaches the
/// end of the turn, which the caller answers by polling cancellation; the
/// budget is then exhausted rather than refilled, so the turn ends.
pub fn charge(budget: *poll.WorkBudget, amount: usize) bool {
    if (amount == 0) return false;
    if (amount >= budget.remaining) {
        budget.remaining = 0;
        return true;
    }
    budget.remaining -= amount;
    return false;
}

/// What the evaluator does after a driver reports it has not finished. A
/// stepped driver is charged one unit for the step itself, so a driver that
/// drew nothing cannot keep the turn indefinitely.
pub fn afterDriver(
    outcome: Outcome,
    budget: *poll.WorkBudget,
    park_requested: bool,
) InvalidTurn!Decision {
    return switch (outcome) {
        .stepped => {
            if (park_requested) return error.InvalidTurn;
            const crossed = charge(budget, 1);
            return .{
                .action = if (budget.exhausted()) .end_turn else .resume_driver,
                .poll_cancellation = crossed,
            };
        },
        .yielded => |reason| switch (reason) {
            .park => if (park_requested)
                .{ .action = .park, .poll_cancellation = false }
            else
                error.InvalidTurn,
            .wait, .settle => if (park_requested)
                error.InvalidTurn
            else
                .{ .action = .end_turn, .poll_cancellation = false },
        },
    };
}

/// The budget each turn begins with.
pub fn beginTurn(quantum: usize) poll.WorkBudget {
    return .init(quantum);
}

const remainders = [_]usize{ 0, 1, 2, 3, 64, 65_535, 65_536 };
const outcomes = [_]Outcome{ .stepped, .{ .yielded = .park }, .{ .yielded = .wait }, .{ .yielded = .settle } };

test "a charge polls exactly when it reaches the end of the turn and never refills" {
    for (remainders) |remaining| {
        for ([_]usize{ 0, 1, 2, 3, 64, 65_536 }) |amount| {
            var budget: poll.WorkBudget = .{ .remaining = remaining };
            const crossed = charge(&budget, amount);
            try std.testing.expectEqual(amount != 0 and amount >= remaining, crossed);
            if (crossed) {
                try std.testing.expectEqual(@as(usize, 0), budget.remaining);
            } else {
                try std.testing.expectEqual(remaining - amount, budget.remaining);
            }
            try std.testing.expect(budget.remaining <= remaining);
        }
    }
}

test "every driver outcome has one decision, and inconsistent ones are refused" {
    for (outcomes) |outcome| {
        for (remainders) |remaining| {
            for ([_]bool{ false, true }) |park_requested| {
                var budget: poll.WorkBudget = .{ .remaining = remaining };
                const result = afterDriver(outcome, &budget, park_requested);
                const consistent = switch (outcome) {
                    .stepped => !park_requested,
                    .yielded => |reason| (reason == .park) == park_requested,
                };
                if (!consistent) {
                    try std.testing.expectError(error.InvalidTurn, result);
                    try std.testing.expectEqual(remaining, budget.remaining);
                    continue;
                }
                const decision = try result;
                switch (outcome) {
                    .stepped => {
                        // One unit for the step; the turn continues only
                        // while budget remains, and cancellation is observed
                        // exactly when this charge ends the turn.
                        try std.testing.expectEqual(remaining -| 1, budget.remaining);
                        try std.testing.expectEqual(remaining <= 1, decision.action == .end_turn);
                        try std.testing.expectEqual(remaining > 1, decision.action == .resume_driver);
                        try std.testing.expectEqual(remaining <= 1, decision.poll_cancellation);
                    },
                    .yielded => |reason| {
                        // Surrender spends nothing and never observes
                        // cancellation: an unwind or cleanup relies on that.
                        try std.testing.expectEqual(remaining, budget.remaining);
                        try std.testing.expect(!decision.poll_cancellation);
                        try std.testing.expectEqual(
                            @as(Action, if (reason == .park) .park else .end_turn),
                            decision.action,
                        );
                    },
                }
            }
        }
    }
}

test "a stepped driver cannot keep the turn past one quantum" {
    for ([_]usize{ 1, 2, 7, 64 }) |quantum| {
        var budget = beginTurn(quantum);
        var steps: usize = 0;
        while (true) {
            steps += 1;
            const decision = try afterDriver(.stepped, &budget, false);
            if (decision.action == .end_turn) {
                try std.testing.expect(decision.poll_cancellation);
                break;
            }
            try std.testing.expect(steps < quantum);
        }
        try std.testing.expectEqual(quantum, steps);
    }
}
