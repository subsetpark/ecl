//! Generated ordered task-join state-machine properties.
const std = @import("std");
const minish = @import("minish");
const join = @import("../task_join_core.zig");

fn sameFailure(left: ?join.Failure, right: ?join.Failure) bool {
    if (left == null or right == null) return left == null and right == null;
    if (std.meta.activeTag(left.?) != std.meta.activeTag(right.?)) return false;
    return switch (left.?) {
        .contract => |index| index == right.?.contract,
        .raised, .out_of_memory => true,
    };
}

fn runTrace(encoded: u64) !void {
    const count: u32 = @intCast(encoded % 13);
    var decision = join.start(count);
    var state = decision.next;
    var expected_successes: u32 = 0;
    var expected_failure: ?join.Failure = null;
    var remaining = encoded / 13;

    if (count == 0) {
        try std.testing.expect(decision.command.next == .finish);
    } else try std.testing.expectEqual(@as(u32, 0), decision.command.next.request);

    for (0..count) |index_usize| {
        const index: u32 = @intCast(index_usize);
        const event: join.Event = @enumFromInt(remaining & 0x3);
        remaining >>= 2;
        decision = try join.decide(state, event);
        state = decision.next;

        if (expected_failure == null) switch (event) {
            .success => {
                try std.testing.expectEqual(expected_successes, decision.command.store_result.?);
                expected_successes += 1;
            },
            .raised => expected_failure = .raised,
            .contract => expected_failure = .{ .contract = index },
            .out_of_memory => expected_failure = .out_of_memory,
        };
        try std.testing.expectEqual(expected_successes, state.successCount());
        const actual_failure = switch (state) {
            .active => |active| active.failure,
            .complete => |summary| summary.failure,
        };
        try std.testing.expect(sameFailure(expected_failure, actual_failure));
        if (index + 1 == count) {
            try std.testing.expect(decision.command.next == .finish);
        } else {
            try std.testing.expectEqual(index + 1, decision.command.next.request);
        }
    }

    const summary = state.complete;
    try std.testing.expectEqual(count, summary.count);
    try std.testing.expectEqual(expected_successes, summary.successes);
    try std.testing.expect(sameFailure(expected_failure, summary.failure));
    try std.testing.expectError(error.InvalidTransition, join.decide(state, .success));
}

test "task join properties: arbitrary outcomes finish once in input order" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), runTrace, .{
        .num_runs = 512,
        .seed = 0x701a_0ade_5afe,
        .max_shrink_attempts = 256,
    });
}
