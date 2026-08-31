//! Generated public-runtime checks for the scheduler's imperative shell.
const std = @import("std");
const minish = @import("minish");
const build_options = @import("build_options");
const cli = @import("cli_test_support.zig");

const allocator = std.testing.allocator;
const scenario_timeout_seconds: u64 = switch (build_options.optimize) {
    // The installed Debug binary uses the tracing DebugAllocator. Its
    // allocator-heavy task-tree teardown can exceed the release liveness
    // deadline without being stuck, especially after many subprocess cases.
    .Debug => 30,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => 5,
};
const cancel_tree_width: usize = switch (build_options.optimize) {
    // At eight workers the tracing DebugAllocator serializes every child
    // allocation and release on one mutex. Sixty-four children still exercise
    // the real cancellation tree while the release gates retain the full load.
    .Debug => 64,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => 300,
};

const Operation = enum(u5) {
    par_each,
    task_join,
    await_one,
    await_any,
    await_for,
    exit,
    wait_graph,
    kernel_fairness,
    result_fairness,
    raise_fairness,
    attempt_materialization,
    wide_wait_setup,
    cancel_tree,
    tasks_mutation,
    root_quiescence,
    infra_stack_handoff,
    infra_fairness,
    value_owner_handoff,
};

const Scenario = struct {
    operation: Operation,
    width: usize,
    workers: []const u8,

    fn decode(encoded: u16) Scenario {
        const operation_count = @typeInfo(Operation).@"enum".fields.len;
        const operation: Operation = @enumFromInt(encoded % operation_count);
        const width = 1 + (encoded / operation_count) % 12;
        const worker_index = (encoded / (operation_count * 12)) % 4;
        return .{
            .operation = operation,
            .width = width,
            .workers = switch (worker_index) {
                0 => "1",
                1 => "2",
                2 => "4",
                else => "8",
            },
        };
    }
};

fn appendValues(writer: *std.Io.Writer, width: usize, square: bool) !void {
    try writer.writeByte('[');
    for (0..width) |index| {
        if (index != 0) try writer.writeByte(' ');
        const item = if (square) index * index else index;
        try writer.print("{d}", .{item});
    }
    try writer.writeByte(']');
}

fn appendTasks(writer: *std.Io.Writer, width: usize) !void {
    for (0..width) |index| try writer.print("[] ({d}) @spawn ", .{index});
    try writer.print("{d} pack", .{width});
}

fn runShellScenario(encoded: u16) !void {
    const scenario = Scenario.decode(encoded);
    var source_buffer = std.Io.Writer.Allocating.init(allocator);
    defer source_buffer.deinit();
    var expected_buffer = std.Io.Writer.Allocating.init(allocator);
    defer expected_buffer.deinit();
    var expected_exit: u8 = 0;

    switch (scenario.operation) {
        .par_each => {
            try appendValues(&source_buffer.writer, scenario.width, false);
            try source_buffer.writer.writeAll(" [] (dup *) @each");
            try appendValues(&expected_buffer.writer, scenario.width, true);
            try expected_buffer.writer.writeByte('\n');
        },
        .task_join => {
            try appendTasks(&source_buffer.writer, scenario.width);
            try source_buffer.writer.writeAll(" [] (await 'ok at first) @each");
            try appendValues(&expected_buffer.writer, scenario.width, false);
            try expected_buffer.writer.writeByte('\n');
        },
        .await_one => {
            try source_buffer.writer.writeAll("[] (42) @spawn await");
            try expected_buffer.writer.writeAll("{'ok [42]}\n");
        },
        .await_any => {
            try source_buffer.writer.writeAll("[] (42) @spawn ");
            for (1..scenario.width) |_| try source_buffer.writer.writeAll("dup ");
            try source_buffer.writer.print("{d} pack await-any", .{scenario.width});
            try expected_buffer.writer.writeAll("0 {'ok [42]}\n");
        },
        .await_for => {
            try source_buffer.writer.writeAll("[] (42) @spawn dup await pop 0 await-for");
            try expected_buffer.writer.writeAll("{'ok [42]}\n");
        },
        .exit => {
            for (0..scenario.width) |_| {
                try source_buffer.writer.writeAll("[] ((1) () while) @spawn pop ");
            }
            try source_buffer.writer.writeAll("7 exit");
            expected_exit = 7;
        },
        .wait_graph => {
            try source_buffer.writer.writeAll("[] ((1) () while) @spawn 'gate set ");
            for (0..scenario.width) |_| try source_buffer.writer.writeAll("[] (gate await) @spawn ");
            try source_buffer.writer.print(
                "{d} pack gate cancel [] (await) @each len",
                .{scenario.width},
            );
            try expected_buffer.writer.print("{d}\n", .{scenario.width});
        },
        .kernel_fairness => {
            try source_buffer.writer.writeAll(
                "[] ([1] 100000 take sum) @spawn pop " ++
                    "[] ([1] 100000 take sum) @spawn " ++
                    "[] (7) @spawn pair await-any pop",
            );
            try expected_buffer.writer.writeAll("1\n");
        },
        .result_fairness => {
            try source_buffer.writer.writeAll(
                "[] ([1] 200000 take call) @spawn " ++
                    "[] (7) @spawn pair await-any pop",
            );
            try expected_buffer.writer.writeAll("1\n");
        },
        .raise_fairness => {
            try source_buffer.writer.writeAll(
                "['x] 200000 take 'trace-value set " ++
                    "[] ([] ('kind 'custom 'trace trace-value 4 pack dict.from-flat raise) @attempt) @spawn " ++
                    "[] (7) @spawn pair await-any pop",
            );
            try expected_buffer.writer.writeAll("1\n");
        },
        .attempt_materialization => {
            try source_buffer.writer.writeAll(
                "[1] 200000 take 'wide set " ++
                    "[] ([] (wide call) @attempt) @spawn await 'ok at call 'ok at len",
            );
            try expected_buffer.writer.writeAll("200000\n");
        },
        .wide_wait_setup => {
            try source_buffer.writer.writeAll(
                "[] ((1) () while) @spawn 'gate set " ++
                    "[] (gate 1 pack 200000 take await-any) @spawn " ++
                    "[] (7) @spawn pair await-any pop",
            );
            try expected_buffer.writer.writeAll("1\n");
        },
        .cancel_tree => {
            try source_buffer.writer.print(
                "[] ([1] {d} take ([] ((1) () while) @spawn pop) each " ++
                    "(1) () while) @spawn dup 20 await-for pop dup cancel await pop",
                .{cancel_tree_width},
            );
        },
        .tasks_mutation => {
            const width = 300 + scenario.width * 20;
            try source_buffer.writer.print(
                "[] ((1) () while) @spawn 'gate set [1] {d} take " ++
                    "(pop [] (gate await pop) @spawn) each pop " ++
                    "gate cancel tasks len pop",
                .{width},
            );
        },
        .root_quiescence => {
            for (0..scenario.width * 20) |_| {
                try source_buffer.writer.writeAll("[] (1) @spawn pop ");
            }
        },
        .infra_stack_handoff => {
            try appendValues(&source_buffer.writer, scenario.width, false);
            try source_buffer.writer.writeAll(" (dup) infra");
            try expected_buffer.writer.writeByte('[');
            for (0..scenario.width) |index| {
                if (index != 0) try expected_buffer.writer.writeByte(' ');
                try expected_buffer.writer.print("{d}", .{index});
            }
            try expected_buffer.writer.print(" {d}]\n", .{scenario.width - 1});
        },
        .infra_fairness => {
            try source_buffer.writer.writeAll(
                "[] ([1] 200000 take () infra len) @spawn " ++
                    "[] (7) @spawn pair await-any pop",
            );
            try expected_buffer.writer.writeAll("1\n");
        },
        .value_owner_handoff => {
            try source_buffer.writer.writeByte('[');
            for (0..scenario.width) |index| {
                if (index != 0) try source_buffer.writer.writeByte(' ');
                try source_buffer.writer.print("{d}", .{index % 3});
            }
            try source_buffer.writer.writeAll("] dup group dict.keys len swap 1 pack \"{}\" str.format pop");
            try expected_buffer.writer.print("{d}\n", .{@min(scenario.width, 3)});
        },
    }

    const source = try source_buffer.toOwnedSlice();
    defer allocator.free(source);
    const expected = try expected_buffer.toOwnedSlice();
    defer allocator.free(expected);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_WORKERS", scenario.workers);
    var result = cli.runOptions(.{
        .argv = &.{ build_options.ecl_exe, source },
        .environ_map = &environment,
        .timeout = .{
            .duration = .{
                .clock = .awake,
                // Release builds retain the strict deadlock detector. Debug's
                // separate budget is selected above rather than weakening the
                // production liveness contract.
                .raw = .fromSeconds(scenario_timeout_seconds),
            },
        },
    }) catch |err| switch (err) {
        error.Timeout => return error.SchedulerLivenessFailure,
        else => |other| return other,
    };
    defer result.deinit();
    const concurrent_finite_race = !std.mem.eql(u8, scenario.workers, "1") and switch (scenario.operation) {
        .kernel_fairness,
        .result_fairness,
        .raise_fairness,
        .infra_fairness,
        => true,
        else => false,
    };
    if (concurrent_finite_race) {
        // Both tasks are finite and run on different workers. await-any's
        // winner is deliberately nondeterministic once either completion can
        // reach the waiter first; the explicit one-worker cases below retain
        // the exact cooperative-fairness assertion.
        try result.expect(.{
            .exit_code = expected_exit,
            .stderr = "",
        });
        try std.testing.expect(
            std.mem.eql(u8, result.stdout, "0\n") or
                std.mem.eql(u8, result.stdout, "1\n"),
        );
        return;
    }
    try result.expect(.{
        .exit_code = expected_exit,
        .stdout = expected,
        .stderr = "",
    });
}

test "scheduler shell property: generated public waits always quiesce" {
    try runShellScenario(@intFromEnum(Operation.kernel_fairness));
    try runShellScenario(@intFromEnum(Operation.result_fairness));
    try runShellScenario(@intFromEnum(Operation.raise_fairness));
    try runShellScenario(@intFromEnum(Operation.attempt_materialization));
    try runShellScenario(@intFromEnum(Operation.wide_wait_setup));
    try runShellScenario(@intFromEnum(Operation.tasks_mutation));
    try runShellScenario(@intFromEnum(Operation.infra_stack_handoff));
    try runShellScenario(@intFromEnum(Operation.infra_fairness));
    try runShellScenario(@intFromEnum(Operation.value_owner_handoff));
    try minish.check(allocator, minish.gen.int(u16), runShellScenario, .{
        .num_runs = 42,
        .seed = 0x5e11_c0de,
        .max_shrink_attempts = 12,
    });
}
