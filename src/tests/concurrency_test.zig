const std = @import("std");
const session = @import("../session.zig");
const heap = @import("../heap.zig");

fn runOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("concurrency.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer heap.releaseValue(runtime.allocator, failure);
            return error.UnexpectedLanguageError;
        },
    }
}

fn display(runtime: *session.Session) ![]u8 {
    return runtime.stackDisplay();
}

test "concurrency: cold sessions start no threads and spawn starts the fixed pool" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    try runOk(&runtime, "(1 2 +) spawn await");
    try std.testing.expectEqual(@as(usize, 1), runtime.schedulerWorkerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    const actual = try display(&runtime);
    defer runtime.allocator.free(actual);
    try std.testing.expectEqualStrings("{'ok [3]}", actual);
}

test "concurrency: default sessions use the build-configured worker count" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try runOk(&runtime, "(1) spawn await pop");
    try std.testing.expectEqual(session.default_worker_count, runtime.schedulerWorkerThreadCount());
}

test "concurrency: task identity rendering dict keys and cached await are observable" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 2 });
    defer runtime.deinit();
    try runOk(&runtime, "(7) spawn dup str");
    {
        const actual = try display(&runtime);
        defer runtime.allocator.free(actual);
        try std.testing.expectEqualStrings("<task:1> \"<task:1>\"", actual);
    }
    try runOk(
        &runtime,
        "pop 'identity-task set " ++
            "identity-task type identity-task dup match " ++
            "identity-task 9 pair dict-of identity-task has?",
    );
    {
        const actual = try display(&runtime);
        defer runtime.allocator.free(actual);
        try std.testing.expectEqualStrings("'task 1 1", actual);
    }
    try runOk(&runtime, "pop pop pop (2 3 +) spawn dup await pop await");
    {
        const actual = try display(&runtime);
        defer runtime.allocator.free(actual);
        try std.testing.expectEqualStrings("{'ok [5]}", actual);
    }
}

test "concurrency: two parked waiters share one cached outcome with one worker" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "(42) spawn 'shared-task set " ++
            "(shared-task await) spawn (shared-task await) spawn pair task-join",
    );
    const actual = try display(&runtime);
    defer runtime.allocator.free(actual);
    try std.testing.expectEqualStrings("({'ok [42]} {'ok [42]})", actual);
}

test "concurrency: runtime task markers cannot be parsed bare or nested" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const bare = (try runtime.runUnit("marker.ecl", "\"<task:4>\" parse")).err;
    heap.releaseValue(runtime.allocator, bare);
    const nested = (try runtime.runUnit("marker.ecl", "\"(<task:4>)\" parse")).err;
    heap.releaseValue(runtime.allocator, nested);
    try runOk(&runtime, "\"\\\"<task:4>\\\"\" parse");
}

test "concurrency: cancellation timeout and later await remain distinct" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "((1) () while) spawn dup 1 await-for swap cancel");
    try std.testing.expectEqual(@as(usize, 1), runtime.schedulerTimerThreadCount());
    var actual = try display(&runtime);
    try std.testing.expect(std.mem.indexOf(u8, actual, "'kind 'timeout") != null);
    runtime.allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
    try runOk(&runtime, "pop ((1) () while) spawn dup cancel await");
    actual = try display(&runtime);
    try std.testing.expect(std.mem.indexOf(u8, actual, "'kind 'cancelled") != null);
    runtime.allocator.free(actual);
}

test "concurrency: cancelling a deadline waiter unlinks its far-future timer" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "((1) () while) spawn 'target-task set " ++
            "(target-task 1000000 await-for) spawn dup cancel await pop " ++
            "target-task cancel target-task await pop",
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "concurrency: timer heap spans fixed chunks and drains every entry" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "((1) () while) spawn 'timer-target set " ++
            "[20] 70 take (timer-target swap await-for) par-each pop " ++
            "timer-target cancel timer-target await pop",
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "concurrency: tasks persist across units and structured close reaches quiescence" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "((1) () while) spawn");
    try runOk(&runtime, "tasks first cancel await");
    const actual = try display(&runtime);
    defer runtime.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "'kind 'cancelled") != null);
}

test "concurrency: tasks snapshots include pending descendants in spawn preorder" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "(((1) () while) spawn pop (1) () while) spawn dup 2 await-for pop tasks len",
    );
    var actual = try display(&runtime);
    try std.testing.expectEqualStrings("<task:1> 2", actual);
    runtime.allocator.free(actual);
    try runOk(&runtime, "pop dup cancel await pop");
    actual = try display(&runtime);
    defer runtime.allocator.free(actual);
    try std.testing.expectEqualStrings("", actual);
}

test "concurrency: one-worker kernel safe points let another unit progress" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "([1] 5000000 take sum) spawn pop " ++
            "([1] 5000000 take sum) spawn " ++
            "(7) spawn pair await-any pop",
    );
    const actual = try display(&runtime);
    defer runtime.allocator.free(actual);
    try std.testing.expectEqualStrings("1", actual);
}

test "concurrency: large task outcomes materialize across scheduler slices" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "([1] 70000 take call) spawn await 'ok at len");
    const actual = try display(&runtime);
    defer runtime.allocator.free(actual);
    try std.testing.expectEqualStrings("70000", actual);
}

test "concurrency: task-join failure cancellation reaches sibling descendants" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "([([1] 70000 take sum pop missing) " ++
            "(((1) () while) spawn pop (1) () while)] " ++
            "(spawn) each task-join) attempt pop",
    );
}

test "concurrency: await-any ties and source par-each preserve program order" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 8 });
    defer runtime.deinit();
    try runOk(&runtime, "(10) spawn dup await pop dup pair await-any pop");
    var actual = try display(&runtime);
    try std.testing.expectEqualStrings("0", actual);
    runtime.allocator.free(actual);
    try runOk(&runtime, "pop [1 2 3] (dup *) par-each");
    actual = try display(&runtime);
    try std.testing.expectEqualStrings("[1 4 9]", actual);
    runtime.allocator.free(actual);
}

test "concurrency: complete console calls do not interleave bytes" {
    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &writer);
    defer runtime.deinit();
    try runOk(&runtime, "[(\"aaaa\" prin 0) (\"bbbb\" prin 0)] (spawn) each task-join pop");
    const written = writer.buffered();
    try std.testing.expect(std.mem.eql(u8, written, "aaaabbbb") or
        std.mem.eql(u8, written, "bbbbaaaa"));
}

test "concurrency: exit is root-owned outside attempt" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_count = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "(7 exit) attempt (7 exit) spawn await");
    try std.testing.expectEqual(@as(?u8, null), runtime.requested_exit);
}
