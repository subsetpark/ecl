const std = @import("std");
const session = @import("../session.zig");
const native_fixture = @import("native_fixture_options");

fn runOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("concurrency.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
}

fn display(runtime: *session.Session) !session.RenderedText {
    return runtime.stackDisplay();
}

test "concurrency: cold sessions start no threads and spawn starts the fixed pool" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    try runOk(&runtime, "[] (missing) par-each pop");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    try runOk(&runtime, "(1 2 +) spawn await");
    try std.testing.expectEqual(@as(usize, 1), runtime.schedulerWorkerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("{'ok [3]}", actual.bytes());
}

test "concurrency: cooperative sessions preserve public task behavior without worker threads" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .cooperative);
    defer runtime.deinit();
    try runOk(&runtime, "(1 2 +) spawn await");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("{'ok [3]}", actual.bytes());
}

test "concurrency: native shutdown releases delayed continuations and image pins" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var output_buffer: [64]u8 = undefined;
        var diagnostic_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.Discarding.init(&output_buffer);
        var diagnostics = std.Io.Writer.Discarding.init(&diagnostic_buffer);
        var runtime = try session.Session.initWithHostConfig(
            allocator,
            &.{},
            std.testing.io,
            &output.writer,
            &diagnostics.writer,
            native_fixture.directory,
            .{ .worker_pool = 1 },
        );
        try runOk(&runtime, "'sample use (9 sample.yield-forever) spawn pop");
        runtime.deinit();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "concurrency: cooperative ready work cannot starve bounded retirement" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
        defer runtime.deinit();
        counting.requested_memory_limit = counting.total_requested_bytes + 512 * 1024;
        try runOk(
            &runtime,
            "((1) () while) spawn 'spinner set " ++
                "(0 (dup 4096 <) (1 + [1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16] pop) while pop) " ++
                "spawn await pop spinner cancel spinner await pop",
        );
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "concurrency: default sessions use the build-configured worker count" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try runOk(&runtime, "(1) spawn await pop");
    try std.testing.expectEqual(session.default_worker_count, runtime.schedulerWorkerThreadCount());
}

test "concurrency: relocating a session handle preserves live runtime links" {
    var original = try session.Session.initWithConfig(
        std.testing.allocator,
        &.{},
        .{ .worker_pool = 1 },
    );
    try runOk(&original, "((1) () while) spawn 'relocated-task set");

    // Session is deliberately a movable handle. The live task, root scope, and
    // environment must point only into the heap-stable core after this copy.
    var runtime = original;
    original = undefined;
    defer runtime.deinit();

    try runOk(&runtime, "relocated-task dup cancel await");
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'kind 'cancelled") != null);
}

test "concurrency: task identity rendering dict keys and cached await are observable" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 2 });
    defer runtime.deinit();
    try runOk(&runtime, "(7) spawn dup str");
    {
        var actual = try display(&runtime);
        defer actual.deinit();
        try std.testing.expectEqualStrings("<task:1> \"<task:1>\"", actual.bytes());
    }
    try runOk(
        &runtime,
        "pop 'identity-task set " ++
            "identity-task type identity-task dup match " ++
            "identity-task 9 pair dict-of identity-task has?",
    );
    {
        var actual = try display(&runtime);
        defer actual.deinit();
        try std.testing.expectEqualStrings("'task 1 1", actual.bytes());
    }
    try runOk(&runtime, "pop pop pop (2 3 +) spawn dup await pop await");
    {
        var actual = try display(&runtime);
        defer actual.deinit();
        try std.testing.expectEqualStrings("{'ok [5]}", actual.bytes());
    }
}

test "concurrency: two parked waiters share one cached result with one worker" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "(42) spawn 'shared-task set " ++
            "shared-task shared-task 2 pack (await) par-each",
    );
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("({'ok [42]} {'ok [42]})", actual.bytes());
}

test "concurrency: runtime task markers cannot be parsed bare or nested" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const bare = (try runtime.runUnit("marker.ecl", "\"<task:4>\" parse")).err;
    runtime.release(bare);
    const nested = (try runtime.runUnit("marker.ecl", "\"(<task:4>)\" parse")).err;
    runtime.release(nested);
    try runOk(&runtime, "\"\\\"<task:4>\\\"\" parse");
}

test "concurrency: cancellation timeout and later await remain distinct" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "((1) () while) spawn dup 1 await-for swap cancel");
    try std.testing.expectEqual(@as(usize, 1), runtime.schedulerTimerThreadCount());
    var actual = try display(&runtime);
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'kind 'timeout") != null);
    actual.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
    try runOk(&runtime, "pop ((1) () while) spawn dup cancel await");
    actual = try display(&runtime);
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'kind 'cancelled") != null);
    actual.deinit();
}

test "concurrency: cancellation wins before a ready literal task dispatches" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    // The outer task occupies the sole worker until it parks. Its child is
    // therefore published and cancelled while still ready in the queue.
    try runOk(&runtime, "((1) spawn dup cancel await) spawn await");
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'kind 'cancelled") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'ok [1]") == null);
}

test "concurrency: terminal deadline waits do not start the timer thread" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "(1) spawn dup await pop 1000000 await-for pop");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
}

test "concurrency: an already-expired pending deadline resolves without a timer thread" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .cooperative);
    defer runtime.deinit();
    try runOk(&runtime, "((1) () while) spawn dup 0 await-for");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    var actual = try display(&runtime);
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'kind 'timeout") != null);
    actual.deinit();
    try runOk(&runtime, "pop dup cancel await pop");
}

test "concurrency: cancelling a deadline waiter unlinks its far-future timer" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
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
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
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
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "((1) () while) spawn");
    try runOk(&runtime, "tasks first cancel await");
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes(), "'kind 'cancelled") != null);
}

test "concurrency: tasks snapshots include pending descendants in spawn preorder" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "(((1) () while) spawn pop (1) () while) spawn dup 2 await-for pop tasks len",
    );
    var actual = try display(&runtime);
    try std.testing.expectEqualStrings("<task:1> 2", actual.bytes());
    actual.deinit();
    try runOk(&runtime, "pop dup cancel await pop");
    actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("", actual.bytes());
}

test "concurrency: one-worker kernel safe points let another unit progress" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "([1] 5000000 take sum) spawn pop " ++
            "([1] 5000000 take sum) spawn " ++
            "(7) spawn pair await-any pop",
    );
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("1", actual.bytes());
}

test "concurrency: large task results materialize across scheduler slices" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "([1] 70000 take call) spawn await 'ok at len");
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("70000", actual.bytes());
}

test "concurrency: par-each failure cancellation reaches sibling descendants" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(
        &runtime,
        "([([1] 70000 take sum pop missing) " ++
            "(((1) () while) spawn pop (1) () while)] " ++
            "(call) par-each) attempt pop",
    );
}

test "concurrency: await-any ties and par-each preserve program order" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 8 });
    defer runtime.deinit();
    try runOk(&runtime, "(10) spawn dup await pop dup pair await-any pop");
    var actual = try display(&runtime);
    try std.testing.expectEqualStrings("0", actual.bytes());
    actual.deinit();
    try runOk(&runtime, "pop [1 2 3] (dup *) par-each");
    actual = try display(&runtime);
    try std.testing.expectEqualStrings("[1 4 9]", actual.bytes());
    actual.deinit();
}

test "concurrency: par-each seeds children without resolving capture helpers" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "(pop 99) (x -- y) 'first def [1 2 3] () par-each");
    var actual = try display(&runtime);
    defer actual.deinit();
    try std.testing.expectEqualStrings("[1 2 3]", actual.bytes());
}

test "concurrency: source await-all is ordered result fan-in" {
    const quotation_lists = [_][]const u8{
        "[]",
        "[()]",
        "[(1)]",
        "[() (1) (1 2) (missing)]",
        "[(0 70000 (1 +) times) (20) (30 31) (also-missing) (50)]",
    };
    for ([_]usize{ 1, 8 }) |worker_count| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = worker_count },
        );
        defer runtime.deinit();
        for (quotation_lists) |quotations| {
            var source_bytes: [512]u8 = undefined;
            const source = try std.fmt.bufPrint(
                &source_bytes,
                "{s} (spawn) each dup await-all swap (await) each match",
                .{quotations},
            );
            try runOk(&runtime, source);
            var actual = try display(&runtime);
            defer actual.deinit();
            try std.testing.expectEqualStrings("1", actual.bytes());
            try runOk(&runtime, "pop");
        }
        try runOk(&runtime, "'await-all doc");
        var documentation = try display(&runtime);
        defer documentation.deinit();
        try std.testing.expectEqualStrings(
            "\"Wait for every task and return its result in input order.\"",
            documentation.bytes(),
        );
    }
}

test "concurrency: complete console calls do not interleave bytes" {
    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &writer);
    defer runtime.deinit();
    try runOk(&runtime, "[(\"aaaa\" prin 0) (\"bbbb\" prin 0)] (call) par-each pop");
    const written = writer.buffered();
    try std.testing.expect(std.mem.eql(u8, written, "aaaabbbb") or
        std.mem.eql(u8, written, "bbbbaaaa"));
}

test "concurrency: primitive par-each is reflective and task-join is absent" {
    var output_bytes: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output);
    defer runtime.deinit();
    const direct = try runtime.runUnit("concurrency.ecl", "task-join");
    switch (direct) {
        .err => |failure| runtime.release(failure),
        .ok, .incomplete => return error.ExpectedLanguageError,
    }
    const indirect = try runtime.runUnit("concurrency.ecl", "1 (task-join) keep");
    switch (indirect) {
        .err => |failure| runtime.release(failure),
        .ok, .incomplete => return error.ExpectedLanguageError,
    }
    try runOk(
        &runtime,
        "'par-each doc " ++
            "\"Apply a quotation concurrently to every list element and return one result per element in input order.\" match " ++
            "'par-each which 'par-each see words",
    );
    var reflected = try display(&runtime);
    defer reflected.deinit();
    try std.testing.expectEqualStrings("1", reflected.bytes());
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.buffered(),
        "par-each -> par-each primitive public (sequence quotation -- results)\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.buffered(),
        "<primitive> (sequence quotation -- results : \"Apply a quotation concurrently to every list element and return one result per element in input order.\") 'par-each def\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "await-all") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "par-each") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "task-join") == null);
}

test "concurrency: terminal par-each child errors settle join cleanup" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    for ([_][]const u8{ "[1] (dup) par-each", "[1] (missing) par-each" }) |source| {
        switch (try runtime.runUnit("concurrency.ecl", source)) {
            .err => |failure| runtime.release(failure),
            .ok, .incomplete => return error.ExpectedLanguageError,
        }
        try runOk(&runtime, "tasks len");
        var actual = try display(&runtime);
        try std.testing.expectEqualStrings("0", actual.bytes());
        actual.deinit();
        try runOk(&runtime, "pop");
    }
}

test "concurrency: exit is root-owned outside attempt" {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try runOk(&runtime, "(7 exit) attempt (7 exit) spawn await");
    try std.testing.expectEqual(@as(?u8, null), runtime.requestedExit());
}
