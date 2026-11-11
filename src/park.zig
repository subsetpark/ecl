//! What a fiber asks of the scheduler when it parks, and what the scheduler
//! delivers when the wait ends. Each request family has its own resume family.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const external = @import("external.zig");
const scheduler_api = @import("scheduler.zig");
const Value = value.Value;

pub const ParkRequest = union(enum) {
    task: Value,
    any: Value,
    deadline: struct { task: Value, milliseconds: u63 },
    /// Park for a number of milliseconds with nothing to wait for but the
    /// clock. Shares the deadline wait's timer registration and arbitration
    /// and resumes through the `sleep` family, never a task result.
    sleep: u63,
    close_scope: u8,
    external: external.ReadinessSource,
    external_until: struct { source: external.ReadinessSource, deadline: scheduler_api.Deadline },
    /// Park on a task mailbox, for a message or for space to queue one. A
    /// deadline resumes the driver exactly as readiness does, so a timed
    /// receive hands back a value instead of raising.
    mailbox: struct { source: external.ReadinessSource, deadline: ?scheduler_api.Deadline },

    /// The one value graph owned by every parking request that carries one.
    /// Scheduler setup, abandonment, and ordinary deinit all use this mapping.
    fn ownedValue(self: ParkRequest) ?Value {
        return switch (self) {
            .task, .any => |item| item,
            .deadline => |deadline| deadline.task,
            .close_scope, .external, .external_until, .mailbox, .sleep => null,
        };
    }

    pub fn taskCount(self: ParkRequest) usize {
        return switch (self) {
            .task, .deadline => 1,
            .any => |tasks| @intCast(tasks.list.length()),
            .close_scope, .external, .external_until, .mailbox, .sleep => 0,
        };
    }

    pub fn taskAt(self: ParkRequest, index: usize) Value {
        return switch (self) {
            .task => |task| single: {
                std.debug.assert(index == 0);
                break :single task;
            },
            .deadline => |deadline| single: {
                std.debug.assert(index == 0);
                break :single deadline.task;
            },
            .any => |tasks| list.atUnchecked(tasks, index),
            .close_scope, .external, .external_until, .mailbox, .sleep => unreachable,
        };
    }

    pub fn deinit(self: ParkRequest, releases: *heap.ReleaseDomain) void {
        if (self.ownedValue()) |item| releases.releaseValue(item);
        switch (self) {
            .external_until => |timed| {
                var owned = timed.source;
                owned.deinit();
            },
            .external => |source| {
                var owned = source;
                owned.deinit();
            },
            .mailbox => |waiting| {
                var owned = waiting.source;
                owned.deinit();
            },
            else => {},
        }
    }
};

/// How a wait on one or more tasks ended.
pub const TaskWaitResume = union(enum) {
    outcome: Value,
    indexed: struct { index: u32, outcome: Value },
    timeout,
    cancelled,
    io,
    /// The deadline lay beyond any instant the scheduler clock can report.
    overflow,
    out_of_memory,

    fn ownedValue(self: TaskWaitResume) ?Value {
        return switch (self) {
            .outcome => |outcome| outcome,
            .indexed => |indexed| indexed.outcome,
            .timeout, .cancelled, .io, .overflow, .out_of_memory => null,
        };
    }
};

/// How a `clock.sleep` ended. Nothing is ever pushed.
const SleepResume = enum { elapsed, cancelled, io, overflow, out_of_memory };

/// How a wait on host readiness ended.
const ExternalResume = union(enum) {
    timeout,
    /// The source reported readiness or its own failure; the driver polls.
    wake: external.Wake,
    cancelled,
    io,
    out_of_memory,
};

/// How a wait on a task mailbox ended. Readiness and the deadline both
/// resume the driver, which polls the mailbox and reads the clock itself.
const MailboxResume = enum { ready, cancelled, io, out_of_memory };

/// One family per park request, so a sleep cannot deliver a task outcome, a
/// task wait cannot report that it slept, and each family's failure wording
/// describes what the fiber was actually doing.
pub const ParkResume = union(enum) {
    task_wait: TaskWaitResume,
    sleep: SleepResume,
    external: ExternalResume,
    mailbox: MailboxResume,
    scope_closed: u8,

    fn ownedValue(self: ParkResume) ?Value {
        return switch (self) {
            .task_wait => |wait| wait.ownedValue(),
            .sleep, .external, .mailbox, .scope_closed => null,
        };
    }

    /// The failure a request receives when no wait service could start.
    pub fn serviceUnavailable(request: ParkRequest) ParkResume {
        return switch (request) {
            .sleep => .{ .sleep = .io },
            .external, .external_until => .{ .external = .io },
            .mailbox => .{ .mailbox = .io },
            .task, .any, .deadline => .{ .task_wait = .io },
            .close_scope => unreachable,
        };
    }

    /// The failure a request receives when its fiber was cancelled before the
    /// wait registered.
    pub fn cancelledFor(request: ParkRequest) ParkResume {
        return switch (request) {
            .sleep => .{ .sleep = .cancelled },
            .external, .external_until => .{ .external = .cancelled },
            .mailbox => .{ .mailbox = .cancelled },
            .task, .any, .deadline => .{ .task_wait = .cancelled },
            .close_scope => unreachable,
        };
    }

    pub fn deinit(self: ParkResume, releases: *heap.ReleaseDomain) void {
        if (self.ownedValue()) |item| releases.releaseValue(item);
    }
};
