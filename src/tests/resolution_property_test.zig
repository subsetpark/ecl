//! Generated winner, shadow, and reverse-use precedence properties.
const std = @import("std");
const minish = @import("minish");
const resolution = @import("../resolution_core.zig");

fn runTrace(encoded: u64) !void {
    const count: usize = @intCast(encoded % 13);
    var remaining = encoded / 13;
    var state: resolution.Search = .searching;
    var winner: ?resolution.Candidate = null;
    var shadows: usize = 0;
    for (0..count) |index| {
        const candidate = resolution.Candidate{
            .trace_word = @truncate(remaining),
            .origin = @enumFromInt((remaining >> 8) & 0x3),
        };
        remaining = std.math.rotr(u64, remaining, 11);
        const decision = resolution.consider(state, candidate);
        state = decision.next;
        switch (decision.command) {
            .winner => |selected| {
                try std.testing.expectEqual(@as(usize, 0), index);
                try std.testing.expect(winner == null);
                winner = selected;
            },
            .shadow => {
                try std.testing.expect(winner != null);
                shadows += 1;
            },
        }
        if (winner) |selected| try std.testing.expectEqual(selected, state.resolved);
    }
    try std.testing.expectEqual(count != 0, winner != null);
    try std.testing.expectEqual(if (count == 0) 0 else count - 1, shadows);

    for (0..count) |ordinal| {
        try std.testing.expectEqual(count - ordinal - 1, resolution.usedIndex(count, ordinal).?);
    }
    try std.testing.expectEqual(@as(?usize, null), resolution.usedIndex(count, count));
}

test "resolution properties: first wins later candidates shadow and uses reverse" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), runTrace, .{
        .num_runs = 512,
        .seed = 0xae50_1a71_0a11,
        .max_shrink_attempts = 256,
    });
}
