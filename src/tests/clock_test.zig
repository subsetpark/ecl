//! Clock policy and scheduler-backed sleep through the public Session.
//!
//! Every timing assertion runs under a manual scheduler clock that the test
//! advances explicitly, so a passing case means "the sleep completed at the
//! instant it was due", never "the host happened to be slow enough". Cases
//! pass only source strings to their Session and run on the traceless session
//! heap (see `test_heap.zig`); the shutdown cases count allocations instead.
const std = @import("std");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const Options = struct {
    config: session.Config = .cooperative,
    clock: session.ClockPolicy = .{ .monotonic = .manual },
};

/// One Session plus the host writers it borrows. The writers are created in
/// place inside the `open` phase, so the Session's pointers to them stay valid
/// for exactly as long as that phase exists; there is no state in which a
/// writer exists without the Session that reads it.
const Fixture = struct {
    heap: test_heap.SessionHeap = .init,
    output_buffer: [64]u8 = @splat(0),
    diagnostics_buffer: [64]u8 = @splat(0),
    phase: union(enum) {
        closed,
        open: struct {
            output: std.Io.Writer.Discarding,
            diagnostics: std.Io.Writer.Discarding,
            runtime: session.Session,
        },
    } = .closed,

    fn open(self: *Fixture, options: Options) !*session.Session {
        return self.openWith(self.heap.allocator(), options);
    }

    fn openWith(self: *Fixture, allocator: std.mem.Allocator, options: Options) !*session.Session {
        std.debug.assert(self.phase == .closed);
        // A `consumed` Session is the handle type's own "no session" state;
        // construction below replaces it or `errdefer` retires the phase.
        self.phase = .{ .open = .{
            .output = .init(&self.output_buffer),
            .diagnostics = .init(&self.diagnostics_buffer),
            .runtime = .consumed,
        } };
        errdefer self.phase = .closed;
        const active = &self.phase.open;
        active.runtime = try session.Session.initWithHostConfig(allocator, &.{}, .{
            .io = std.testing.io,
            .output = &active.output.writer,
            .diagnostics = &active.diagnostics.writer,
            .clock = options.clock,
        }, options.config);
        return &active.runtime;
    }

    /// Tear the Session down and return to `closed`; the heap stays usable.
    fn closeSession(self: *Fixture) void {
        switch (self.phase) {
            .closed => {},
            .open => |*active| active.runtime.deinit(),
        }
        self.phase = .closed;
    }

    fn close(self: *Fixture) void {
        self.closeSession();
        test_heap.retire(&self.heap);
    }
};

fn runOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("<clock-test>", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.log.err("unexpected language error: {s}", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
}

fn expectDisplay(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    try runOk(runtime, source);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
    try runOk(runtime, "stack len (pop) times");
}

fn expectError(runtime: *session.Session, source: []const u8, expected: support.ErrorCase) !void {
    const failure = switch (try runtime.runUnit("<clock-test>", source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

fn advance(runtime: *session.Session, milliseconds: u64) !void {
    try runtime.advanceManualClock(milliseconds);
}

/// Wait until the scheduler holds exactly `count` timer entries. Progress
/// depends only on the worker registering its sleep, not on host time, so
/// the loop terminates as soon as that step has happened. The bound turns a
/// worker that never registers into a diagnosed failure instead of a hang;
/// it is far above any legitimate registration latency.
fn awaitTimerEntries(runtime: *session.Session, count: usize) void {
    const max_polls: usize = 20_000;
    var polls: usize = 0;
    while (runtime.schedulerTimerEntryCount() != count) : (polls += 1) {
        if (polls == max_polls) std.debug.panic(
            "timer entries never reached {d}; observed {d}",
            .{ count, runtime.schedulerTimerEntryCount() },
        );
        std.Thread.yield() catch @panic("test yield failed");
        const pause: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(1), .clock = .awake };
        pause.sleep(std.testing.io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
}

test "clock: a manual clock starts at zero and moves only when the host advances it" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{});
    try expectDisplay(runtime, "clock.now", "{'monotonic 0}");
    try expectDisplay(runtime, "clock.now clock.elapsed", "0");
    try advance(runtime, 1500);
    try expectDisplay(runtime, "clock.now", "{'monotonic 1500}");
    try expectDisplay(runtime, "{'monotonic 500} clock.elapsed", "1000");
    try advance(runtime, 0);
    try expectDisplay(runtime, "clock.now", "{'monotonic 1500}");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
}

test "clock: a manual clock refuses any advance that would leave its range and never wraps" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{});
    const max: u64 = std.math.maxInt(i64);
    try std.testing.expectError(error.Overflow, runtime.advanceManualClock(max + 1));
    try expectDisplay(runtime, "clock.now", "{'monotonic 0}");
    try advance(runtime, max);
    try expectDisplay(runtime, "clock.now", "{'monotonic 9223372036854775807}");
    // Cumulative overflow is refused too, and the reading is untouched.
    try std.testing.expectError(error.Overflow, runtime.advanceManualClock(1));
    try expectDisplay(runtime, "clock.now", "{'monotonic 9223372036854775807}");
    try advance(runtime, 0);
    try expectDisplay(runtime, "clock.now", "{'monotonic 9223372036854775807}");
}

test "clock: a deadline the clock cannot reach is refused before parking" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    // At reading zero the maximum duration is exactly reachable: the sleep
    // registers a timer entry and is then cancelled.
    try runOk(runtime, "[] (9223372036854775807 clock.sleep) @spawn 'sleeper set");
    awaitTimerEntries(runtime, 1);
    try expectDisplay(runtime, "sleeper dup cancel await 'err at 'kind at", "'cancelled");
    try advance(runtime, 1);
    try expectError(runtime, "9223372036854775807 clock.sleep", .{
        .name = "unreachable sleep",
        .source = "9223372036854775807 clock.sleep",
        .kind = "overflow",
        .word = "clock.sleep",
    });
    try expectError(runtime, "[] ((1) () while) @spawn dup 9223372036854775807 await-for swap cancel", .{
        .name = "unreachable await-for",
        .source = "await-for",
        .kind = "overflow",
        .word = "await-for",
    });
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: a host clock refuses manual advancement and counts from Session start" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 }, .clock = .{ .monotonic = .host } });
    try std.testing.expectError(error.HostClock, runtime.advanceManualClock(1));
    try expectDisplay(runtime, "clock.now 'monotonic at 0 >=", "1");
    try expectDisplay(runtime, "clock.now clock.elapsed 0 >=", "1");
    // A host timestamp is i96 nanoseconds, so the maximum millisecond
    // duration is a reachable deadline: it registers before it is cancelled.
    try runOk(runtime, "[] (9223372036854775807 clock.sleep) @spawn 'sleeper set");
    awaitTimerEntries(runtime, 1);
    try expectDisplay(runtime, "sleeper dup cancel await 'err at 'kind at", "'cancelled");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: the wall clock is absent by default and refused with a reason" {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var runtime = try session.Session.init(heap.allocator(), &.{});
    defer runtime.deinit();
    try expectError(&runtime, "clock.unix", .{
        .name = "absent wall clock",
        .source = "clock.unix",
        .kind = "domain",
        .word = "clock.unix",
        .data = &.{.{ .name = "reason", .expected = .{ .symbol = "unavailable" } }},
    });
    // Monotonic time is always present; only the wall clock is a grant.
    try expectDisplay(&runtime, "clock.now 'monotonic at type", "'int");
}

test "clock: a fixed wall clock returns the configured timestamp on every read" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .clock = .{ .monotonic = .manual, .wall = .{ .fixed = 1700000000000 } } });
    try expectDisplay(runtime, "clock.unix", "{'unix 1700000000000}");
    try advance(runtime, 5000);
    try expectDisplay(runtime, "clock.unix", "{'unix 1700000000000}");
    try expectDisplay(runtime, "clock.unix time.format", "\"2023-11-14T22:13:20.000Z\"");
}

test "clock: an anchored wall clock advances with the manual monotonic clock" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .clock = .{ .monotonic = .manual, .wall = .{ .anchored = 1700000000000 } } });
    try expectDisplay(runtime, "clock.unix", "{'unix 1700000000000}");
    try advance(runtime, 2500);
    try expectDisplay(runtime, "clock.unix", "{'unix 1700000002500}");
    try expectDisplay(runtime, "clock.unix time.format", "\"2023-11-14T22:13:22.500Z\"");
    // The two domains stay distinct even when both are driven by one clock.
    try expectDisplay(runtime, "clock.now clock.unix match?", "0");
}

test "clock: a host wall clock reads a tagged integer through host io" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .clock = .{ .monotonic = .host, .wall = .host } });
    // The value is the ambient clock's and is not asserted; the shape is.
    try expectDisplay(runtime, "clock.unix 'unix at type", "'int");
    try expectDisplay(runtime, "clock.unix dict.keys", "['unix]");
}

test "clock: sleep completes exactly when the manual clock reaches its deadline" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    try runOk(runtime, "[] (100 clock.sleep clock.now) @spawn 'sleeper set");
    awaitTimerEntries(runtime, 1);
    try std.testing.expectEqual(@as(usize, 1), runtime.schedulerTimerThreadCount());
    try advance(runtime, 99);
    // A zero deadline is decided at registration, so this observes the
    // sleeper's state without waiting on anything.
    try expectDisplay(runtime, "sleeper 0 await-for 'err at 'kind at", "'timeout");
    try std.testing.expectEqual(@as(usize, 1), runtime.schedulerTimerEntryCount());
    try advance(runtime, 1);
    try expectDisplay(runtime, "sleeper await", "{'ok ({'monotonic 100})}");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: a zero sleep parks and resumes without starting the timer thread" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{});
    try expectDisplay(runtime, "0 clock.sleep 'awake", "'awake");
    try expectDisplay(runtime, "[] (0 clock.sleep 1) @spawn await", "{'ok [1]}");
    try expectDisplay(runtime, "clock.now", "{'monotonic 0}");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: invalid sleep durations fail before any timer is registered" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{});
    try expectError(runtime, "-1 clock.sleep", .{
        .name = "negative",
        .source = "-1 clock.sleep",
        .kind = "domain",
        .word = "clock.sleep",
    });
    try expectError(runtime, "1.5 clock.sleep", .{
        .name = "float",
        .source = "1.5 clock.sleep",
        .kind = "type",
        .word = "clock.sleep",
    });
    try expectError(runtime, "clock.sleep", .{
        .name = "underflow",
        .source = "clock.sleep",
        .kind = "underflow",
        .word = "clock.sleep",
    });
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: cancellation before registration wakes the sleeper as cancelled" {
    var fixture: Fixture = .{};
    defer fixture.close();
    // Cooperative: the task cannot run before `await`, so the cancellation
    // is already recorded when it is first dispatched.
    const runtime = try fixture.open(.{});
    try expectDisplay(runtime, "[] (1000000 clock.sleep) @spawn dup cancel await 'err at 'kind at", "'cancelled");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerThreadCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: cancellation after registration retires the timer entry" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    try runOk(runtime, "[] (1000000 clock.sleep) @spawn 'sleeper set");
    awaitTimerEntries(runtime, 1);
    try expectDisplay(runtime, "sleeper dup cancel await 'err at 'msg at", "\"unit cancelled while sleeping\"");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
    // The clock never moved: the wake came from cancellation alone.
    try expectDisplay(runtime, "clock.now", "{'monotonic 0}");
}

test "clock: many sleepers wake by deadline across one advance" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    // Seventy sleepers span more than one timer-heap chunk. Durations 1..70.
    try runOk(runtime, "70 range (1 +) each (1 pack (clock.sleep clock.now) @spawn) each 'sleepers set");
    awaitTimerEntries(runtime, 70);
    try advance(runtime, 35);
    try expectDisplay(runtime, "sleepers 35 take (await) each ({'ok [{'monotonic 35}]} match?) all?", "1");
    try expectDisplay(runtime, "sleepers 35 drop (0 await-for 'err at 'kind at 'timeout match?) all?", "1");
    try std.testing.expectEqual(@as(usize, 35), runtime.schedulerTimerEntryCount());
    try advance(runtime, 35);
    try expectDisplay(runtime, "sleepers 35 drop (await) each ({'ok [{'monotonic 70}]} match?) all?", "1");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: a parked sleeper does not occupy the only worker" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    try runOk(runtime, "[] (1000000 clock.sleep) @spawn 'sleeper set");
    awaitTimerEntries(runtime, 1);
    try expectDisplay(runtime, "[] (1 2 +) @spawn await", "{'ok [3]}");
    try expectDisplay(runtime, "[] ((1) () while) @spawn dup 0 await-for 'err at 'kind at swap cancel", "'timeout");
    try expectDisplay(runtime, "sleeper dup cancel await 'err at 'kind at", "'cancelled");
}

test "clock: await-for deadlines follow the same manual clock as sleep" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    try runOk(runtime, "[] ((1) () while) @spawn 'spinner set");
    // The root parks on the deadline; a helper advances the clock once the
    // timer entry exists, so the timeout fires at exactly 50 and never sooner.
    const Advancer = struct {
        fn run(target: *session.Session) void {
            awaitTimerEntries(target, 1);
            target.advanceManualClock(50) catch |err|
                std.debug.panic("manual clock refused advancement: {s}", .{@errorName(err)});
        }
    };
    const helper = try std.Thread.spawn(.{}, Advancer.run, .{runtime});
    try expectDisplay(runtime, "spinner 50 await-for 'err at 'kind at", "'timeout");
    helper.join();
    try expectDisplay(runtime, "clock.now", "{'monotonic 50}");
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
    try expectDisplay(runtime, "spinner dup cancel await 'err at 'kind at", "'cancelled");
}

test "clock: a root unit sleeps through the same timer path" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{ .config = .{ .worker_pool = 1 } });
    const Advancer = struct {
        fn run(target: *session.Session) void {
            awaitTimerEntries(target, 1);
            target.advanceManualClock(5) catch |err|
                std.debug.panic("manual clock refused advancement: {s}", .{@errorName(err)});
        }
    };
    const helper = try std.Thread.spawn(.{}, Advancer.run, .{runtime});
    try expectDisplay(runtime, "5 clock.sleep clock.now", "{'monotonic 5}");
    helper.join();
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerTimerEntryCount());
}

test "clock: session shutdown retires pending sleeps and their timers without leaking" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    {
        var fixture: Fixture = .{};
        const runtime = try fixture.openWith(counting.allocator(), .{ .config = .{ .worker_pool = 1 } });
        try runOk(runtime, "3 range (1 pack (1000000 + clock.sleep) @spawn) each pop");
        awaitTimerEntries(runtime, 3);
        fixture.closeSession();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
    var cooperative: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    {
        var fixture: Fixture = .{};
        const runtime = try fixture.openWith(cooperative.allocator(), .{});
        // Never dispatched: shutdown cancels it before any timer exists.
        try runOk(runtime, "[] (1000000 clock.sleep) @spawn pop");
        fixture.closeSession();
    }
    try std.testing.expectEqual(.ok, cooperative.deinit());
}

test "clock: calendar decomposition agrees with the standard library epoch oracle" {
    var fixture: Fixture = .{};
    defer fixture.close();
    const runtime = try fixture.open(.{});
    const seconds = [_]u64{ 0, 1, 59, 86399, 86400, 951782400, 951868799, 1709210096, 4102444800, 253402300799 };
    for (seconds) |secs| {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "[{d} {d} {d} {d} {d} {d}]", .{
            year_day.year,
            month_day.month.numeric(),
            @as(u32, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
        var source_buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_buffer,
            "{d} time.seconds time.from-unix time.to-utc ['year 'month 'day 'hour 'minute 'second] swap (swap at) partial each",
            .{secs},
        );
        try expectDisplay(runtime, source, expected);
    }
}
