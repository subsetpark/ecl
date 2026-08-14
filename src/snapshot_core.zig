//! Allocation-free snapshot reader and reclamation policy.
//!
//! The imperative shells own atomics, locks, payload retention, and storage.
//! This module makes the required operation order explicit so every snapshot
//! surface uses the same reader protocol and reclamation rule.

pub const Reader = enum {
    idle,
    announced,
    protected,
};

pub const ReaderEvent = enum {
    announce,
    protect,
    leave,
};

pub const ReaderCommand = enum {
    announce,
    retain_payload,
    leave,
};

pub const ReaderDecision = struct {
    next: Reader,
    command: ReaderCommand,
};

pub const TransitionError = error{InvalidTransition};

pub fn decideReader(before: Reader, event: ReaderEvent) TransitionError!ReaderDecision {
    return switch (before) {
        .idle => switch (event) {
            .announce => .{ .next = .announced, .command = .announce },
            .protect, .leave => error.InvalidTransition,
        },
        .announced => switch (event) {
            .protect => .{ .next = .protected, .command = .retain_payload },
            .leave => .{ .next = .idle, .command = .leave },
            .announce => error.InvalidTransition,
        },
        .protected => switch (event) {
            .leave => .{ .next = .idle, .command = .leave },
            .announce, .protect => error.InvalidTransition,
        },
    };
}

pub const ReclaimCommand = enum { keep, reclaim };

pub fn decideReclamation(readers: usize, retired_count: usize) ReclaimCommand {
    return if (readers == 0 and retired_count != 0) .reclaim else .keep;
}
