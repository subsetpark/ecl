// zlint-disable no-print -- a test runner reports results on stderr; std.log would count as a test error.
//! Test runner for every non-fuzz test artifact.
//!
//! Zig's default runner gives each test a `SafeAllocator` that records seven
//! frames of allocation stack trace. On macOS each capture is a full DWARF
//! unwind, which dominated the suite's CPU time. This runner keeps the same
//! leak, double-free, and write-after-free checks and the same per-test
//! `std.testing` setup, but records only the allocation traces
//! `-Dalloc-trace-frames` asks for.
//!
//! It runs in `zig build`'s simple mode: it prints failures and a summary to
//! stderr and reports through its exit status. Fuzz targets keep Zig's server
//! runner, which owns the fuzzing protocol.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

var logged_errors: usize = 0;

/// Count error logs, which fail the running test as they do under Zig's
/// runner, and print messages at or above `std.testing.log_level`.
fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) <= @backingInt(std.log.Level.err)) logged_errors +|= 1;
    if (@backingInt(level) <= @backingInt(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
    }
}

/// `std.testing.fuzz` calls back into the runner. Outside a fuzzing session
/// Zig's runner replays the provided corpus and then an empty input; this
/// runner does the same and is never built for fuzzing.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    if (builtin.fuzz) @compileError("fuzz targets use Zig's server-mode test runner");
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

pub fn main(init: std.process.Init.Minimal) void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    for (builtin.test_functions) |test_fn| {
        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
            .stack_trace_frames = @import("alloc_options").trace_frames,
        });
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;
        logged_errors = 0;

        const outcome = test_fn.func();
        const test_errors = logged_errors;
        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() != 0) {
            leaked += 1;
            std.debug.print("{s}: LEAK\n", .{test_fn.name});
        }
        if (outcome) |_| {
            if (test_errors == 0) {
                passed += 1;
            } else {
                failed += 1;
                std.debug.print("{s}: FAIL (logged {d} errors)\n", .{ test_fn.name, test_errors });
            }
        } else |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                failed += 1;
                std.debug.print("{s}: FAIL ({t})\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }
    if (failed == 0 and leaked == 0) return;
    std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked.\n", .{ passed, skipped, failed, leaked });
    std.process.exit(1);
}
