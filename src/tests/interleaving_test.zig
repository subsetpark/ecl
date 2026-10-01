//! Schedule independence, checked through the public Session interface.
//!
//! The scheduler promises no order among ready work. A program whose result
//! is defined without reference to that order must therefore produce the same
//! result, finish, and leak nothing under every order an explored cooperative
//! executor chooses: which ready entry runs next and whether a turn serves
//! ready work or retirement.
const std = @import("std");
const session = @import("../session.zig");
const runtime_fixture = @import("runtime_fixture.zig");

const seeds = 48;

const programs = [_][]const u8{
    "[] (1 2 +) @spawn task.await",
    "[1 2 3 4 5 6 7 8] [] (dup *) @each",
    "[] ([] (10) @spawn [] (20) @spawn pair (task.await) each) @spawn task.await",
    // A wait chain: each task joins the one it spawned.
    "[] ([] ([] (7) @spawn task.await) @spawn task.await) @spawn task.await",
    // A tree of spinners is cancelled and joined. Where cancellation lands is
    // schedule-dependent and visible in the error's trace, so only completion
    // is compared.
    "[] ([1] 12 take ([] ((1) () while) @spawn pop) each (1) () while) @spawn " ++
        "dup task.cancel task.await pop 'done",
    // Failures inside tasks surface as values, whatever ran first.
    "[1 2 3 4] [] ([] (0 /) @attempt pop) @each",
    // Allocation-heavy tasks keep retirement busy between ready turns.
    "[1] 16 take [] (pop [1] 64 take (pop [1 2 3]) each len) @each",
    // A finite task beats a spinner in await-any under every order.
    "[] ((1) () while) @spawn 'spin set [] (5) @spawn spin pair task.await-any " ++
        "spin task.cancel spin task.await pop",
};

fn render(config: session.Config, source: []const u8) ![]u8 {
    var counting: std.heap.DebugAllocator(.{}) = .init;
    const allocator = counting.allocator();
    const rendered = blk: {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), config, .evaluate);
        defer runtime.deinit();
        switch (try runtime.runUnit("interleaving.ecl", source)) {
            .ok => {},
            .incomplete => return error.UnexpectedIncomplete,
            .err => |failure| {
                runtime.release(failure);
                return error.UnexpectedLanguageError;
            },
        }
        var display = try runtime.stackDisplay();
        defer display.deinit();
        break :blk try std.testing.allocator.dupe(u8, display.bytes());
    };
    errdefer std.testing.allocator.free(rendered);
    if (counting.deinit() != .ok) return error.LeakedUnderSchedule;
    return rendered;
}

test "interleaving: results are independent of the order among ready work" {
    for (programs) |source| {
        const expected = try render(.cooperative, source);
        defer std.testing.allocator.free(expected);
        for (1..seeds + 1) |seed| {
            const actual = render(.{ .cooperative_explored = seed }, source) catch |err| {
                std.debug.print("seed {d}: {s}\n  {s}\n", .{ seed, @errorName(err), source });
                return err;
            };
            defer std.testing.allocator.free(actual);
            std.testing.expectEqualStrings(expected, actual) catch |err| {
                std.debug.print("seed {d} changed the result of:\n  {s}\n", .{ seed, source });
                return err;
            };
        }
    }
}
