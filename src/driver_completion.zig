//! A terminal driver result owns its cleanup until admission can be released.
//! Normal completion and abandoned execution advance the same bounded cursor.
const std = @import("std");
const heap = @import("heap.zig");
const machine = @import("machine.zig");
const Value = @import("value.zig").Value;

pub const Progress = union(enum) { yielded, completed, output: Value };

pub const Completion = struct {
    phase: union(enum) { running, success: ?Value, failure: machine.MachineError, abandoned, settled } = .running,

    pub fn advance(self: *Completion, evaluator: *machine.Machine, driver: anytype) machine.MachineError!machine.WorkProgress {
        if (self.phase == .running) {
            const progress: Progress = driver.advanceOperation(evaluator) catch |err| {
                self.phase = .{ .failure = err };
                return .yielded;
            };
            switch (progress) {
                .yielded => return .yielded,
                .completed => self.phase = .{ .success = null },
                .output => |value| self.phase = .{ .success = value },
            }
            // Cleanup receives its own bounded allowance on the next turn.
            return .yielded;
        }
        for (0..machine.kernel_poll_quantum) |_| {
            if (!driver.advanceCleanup(evaluator.releaseDomain(), evaluator.allocator())) continue;
            const outcome = self.phase;
            self.phase = .settled;
            return switch (outcome) {
                .success => |value| result: {
                    evaluator.pollKernel() catch |err| {
                        if (value) |owned| evaluator.releaseDomain().releaseValue(owned);
                        return err;
                    };
                    break :result if (value) |owned| .{ .output = owned } else .completed;
                },
                .failure => |err| err,
                .running, .abandoned, .settled => unreachable,
            };
        }
        return .yielded;
    }

    /// Abandoning a pending result consumes it once; cleanup remains resumable.
    pub fn retire(self: *Completion, driver: anytype, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) bool {
        if (self.phase == .settled) return true;
        if (self.phase == .success) if (self.phase.success) |value| releases.releaseValue(value);
        self.phase = .abandoned;
        return driver.advanceCleanup(releases, allocator);
    }
};
