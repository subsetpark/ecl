//! Public Session coverage for the process-port capability.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const fixture = @import("process_fixture_options");
const process = @import("../process_port.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;

fn source(comptime template: []const u8, arguments: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, template, arguments);
}

fn expectStack(program: []const u8, limits: process.Limits, expected: []const u8) !void {
    return expectStackWithWorkers(program, limits, expected, 2);
}

fn expectStackWithWorkers(program: []const u8, limits: process.Limits, expected: []const u8, workers: u32) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .process_limits = limits,
    }), .{ .worker_pool = workers }, .evaluate);
    defer runtime.deinit();
    switch (try runtime.runUnit("<process-test>", program)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.log.err("unexpected process error: {s}", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
}

fn expectError(program: []const u8, limits: process.Limits, expected: support.ErrorCase) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .process_limits = limits,
    }), .cooperative, .evaluate);
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<process-test>", program)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

test "process: port values are opaque identity capabilities" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "'proc ('spawn 'wait) import " ++
            "{{'executable \"{s}\" 'args (\"exit\" \"0\")}} spawn 'p set p type p p match? p wait",
        .{fixture_path},
    );
    defer allocator.free(program);
    try expectStack(
        program,
        .{},
        "'port 1 {'kind 'exited 'code 0}",
    );
}

test "process: registered factories preserve identity and validate input" {
    try expectStack("proc.core.process dup type swap proc.core.process match?", .{}, "'port 1");
    try expectStack("[] (proc.core.process {} port.open) @attempt 'err at 'kind at " ++
        "[] (proc.core.process (dup) port.open) @attempt 'err at 'kind at " ++
        "[] (proc.core.process [0] 4097 take port.open) @attempt 'err at 'kind at", .{}, "'domain 'type 'overflow");
}

test "process: common factories preserve byte streams and repeatable termination" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"echo\")}} port.open 'p set " ++
            "p [0 1 255] proc.write p proc.close-input " ++
            "p 1 proc.read-stdout p 1 proc.read-stdout p 1 proc.read-stdout " ++
            "p proc.wait 'code at p proc.wait 'code at p port.close p port.close p type",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdin_capacity = 1,
        .stdout_capacity = 1,
    }, "[0] [1] [255] 0 0 'port", workers);
}

test "process: common factories preserve unicode arguments environment and working directory" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const expected = "cwd=/\nprobe=é🌍\narg[0]=\narg[1]=λ\n";
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"inspect\" \"\" \"λ\") 'cwd \"/\" 'env {{\"ECL_PROCESS_PROBE\" \"é🌍\"}}}} port.open 'p set " ++
            "p proc.core.stdout port.endpoint 'r set [] (dup len {d} <) (r 8 port.read cat) while chars " ++
            "\"cwd=/\\nprobe=é🌍\\narg[0]=\\narg[1]=λ\\n\" match? r 8 port.read p proc.wait 'code at p port.close",
        .{ fixture_path, expected.len },
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdout_capacity = 1,
    }, "1 [] 0", workers);
}

test "process: common factories reject malformed fields before publishing a resource" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "[] (proc.core.process {{'executable \"{s}\" 'args [1]}} port.open) @attempt 'err at 'kind at " ++
            "[] (proc.core.process {{'executable \"{s}\" 'env {{\"A\" 1}}}} port.open) @attempt 'err at 'kind at " ++
            "[] (proc.core.process {{'executable \"{s}\" 'unknown 1}} port.open) @attempt 'err at 'kind at " ++
            "proc.core.process {{'executable \"{s}\" 'args (\"exit\" \"0\")}} port.open dup proc.wait 'code at swap port.close",
        .{ fixture_path, fixture_path, fixture_path, fixture_path },
    );
    defer allocator.free(program);
    try expectStack(program, .{ .max_live_ports = 1 }, "'type 'type 'domain 0");
}

test "process: common factories transfer owners and clean resources returned by closed scopes" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"block\")}} port.open 'p set " ++
            "p wrap [] (port.close) @give task.await 'ok at len [] (p proc.wait) @attempt 'err at 'kind at " ++
            "[] (proc.core.process {{'executable \"{s}\" 'args (\"block\")}} port.open) @spawn " ++
            "task.await 'ok at first dup type swap wrap (proc.wait) @attempt 'err at 'kind at",
        .{ fixture_path, fixture_path },
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .max_live_ports = 1,
    }, "0 'io 'port 'io", workers);
}

test "process: common endpoints stream concurrently through one-byte buffers" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"echo\")}} port.open 'p set " ++
            "p proc.core.stdin port.endpoint 's set p proc.core.stdout port.endpoint 'r set " ++
            "p proc.core.stderr port.endpoint 'd set s wrap ('w set w [0 1 255] 30 take port.write w port.finish) @spawn 'writer set " ++
            "[] (dup len 30 <) (r 8 port.read cat) while [0 1 255] 30 take match? " ++
            "writer task.await 'ok at len s port.finish r 8 port.read len r 8 port.read len d 8 port.read len " ++
            "p proc.wait 'code at p port.close s wrap ([] port.write) @attempt 'err at 'kind at",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdin_capacity = 1,
        .stdout_capacity = 1,
        .stderr_capacity = 1,
    }, "1 0 0 0 0 0 'io", workers);
}

test "process: common selectors borrow process resources and separate output from diagnostics" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "{{'executable \"{s}\" 'args (\"split\" \"abcd\" \"wxyz\")}} proc.spawn 'p set " ++
            "p proc.core.stdout port.endpoint wrap ('r set [] (dup len 4 <) (r 8 port.read cat) while chars) @spawn 'out set " ++
            "p proc.core.stderr port.endpoint wrap ('r set [] (dup len 4 <) (r 8 port.read cat) while chars) @spawn 'err set " ++
            "out task.await 'ok at first err task.await 'ok at first p proc.wait 'code at p port.close",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdout_capacity = 1,
        .stderr_capacity = 1,
    }, "\"abcd\" \"wxyz\" 0", workers);
}

test "process: common and domain readers share exclusion and cancellation restores access" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"echo\")}} port.open 'p set " ++
            "p proc.core.stdin port.endpoint 's set p proc.core.stdout port.endpoint 'r set " ++
            "[] (r 1 port.read) @spawn 'a set [] (p 1 proc.read-stdout) @spawn 'b set " ++
            "a b pair task.await-any 'err at 'kind at swap pop a task.cancel b task.cancel " ++
            "a task.await pop b task.await pop s [9] port.write r wrap (1 port.read) @spawn 'readback set " ++
            "p wrap [] ('q set s port.finish readback task.await 'ok at first q proc.wait pop q port.close) @give task.await 'ok at first " ++
            "r wrap ([] port.write) @attempt 'err at 'kind at s wrap (1 port.read) @attempt 'err at 'kind at " ++
            "r wrap (port.finish) @attempt 'err at 'kind at " ++
            "r wrap [] (pop) 3 pack (@give) @attempt 'err at 'kind at " ++
            "r 1 port.read len r type",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{}, "'contract [9] 'type 'type 'type 'domain 0 'port", workers);
}

test "process: endpoint selectors reject wrong capability variants" {
    try expectStack("proc.core.stdout proc.core.stdout match? " ++
        "[] (proc.core.process proc.core.stdout port.endpoint) @attempt 'err at 'kind at " ++
        "[] (net.core.listener proc.core.stdin port.endpoint) @attempt 'err at 'kind at " ++
        "[] (0 proc.core.process port.endpoint) @attempt 'err at 'kind at " ++
        "[] (proc.core.stdin {} port.open) @attempt 'err at 'kind at", .{}, "1 'type 'type 'type 'type");
}

test "process: shared port operations linearize and converge" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "'proc ('spawn 'write 'close-input 'read-stdout 'wait) import " ++
            "{{'executable \"{s}\" 'args (\"echo\")}} spawn " ++
            "dup [0 1 255] write dup [2 3] write dup close-input " ++
            "dup 16 read-stdout swap wait",
        .{fixture_path},
    );
    defer allocator.free(program);
    try expectStack(
        program,
        .{},
        "[0 1 255 2 3] {'kind 'exited 'code 0}",
    );
}

test "process: stream reads bound storage by the selected pipe capacity" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "'proc ('spawn 'read-stdout 'read-stderr 'wait) import " ++
            "{{'executable \"{s}\" 'args (\"split\" \"abcd\" \"wxyz\")}} spawn 'p set " ++
            "p 9223372036854775807 read-stdout " ++
            "p 9223372036854775807 read-stderr p wait",
        .{fixture_path},
    );
    defer allocator.free(program);
    try expectStack(
        program,
        .{
            .stdout_capacity = 4,
            .stderr_capacity = 4,
        },
        "[97 98 99 100] [119 120 121 122] {'kind 'exited 'code 0}",
    );
}

test "process: common shutdown and close join cleanup and reject new operations" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    for ([_]u32{ 1, 8 }) |workers| {
        for ([_][]const u8{ "port.shutdown", "port.close" }, [_][]const u8{ "'io", "'io" }) |closing, expected| {
            const program = try source(
                "{{'executable \"{s}\" 'args (\"ready\")}} proc.spawn 'p set " ++
                    "p 1 proc.read-stdout pop " ++
                    "p {s} p {s} [] (p proc.wait) @attempt 'err at 'kind at",
                .{ fixture_path, closing, closing },
            );
            defer allocator.free(program);
            try expectStackWithWorkers(program, .{
                .stdin_capacity = 1,
                .stdout_capacity = 1,
                .stderr_capacity = 1,
            }, expected, workers);
        }
    }
}

test "process: common close joins a producer with full output rings" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "{{'executable \"{s}\" 'args (\"flood\")}} proc.spawn 'p set " ++
            "p 1 proc.read-stdout pop p port.close p port.close p type [] (p proc.wait) @attempt 'err at 'kind at",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdout_capacity = 1,
        .stderr_capacity = 1,
    }, "'port 'io", workers);
}

test "process: registered operations recover the wait lane and preserve result claims" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"ready\")}} port.open 'p set " ++
            "p proc.core.stdout port.endpoint 1 port.read pop " ++
            "p proc.core.wait [] port.begin 'first set first port.cancel " ++
            "first wrap (port.await) @attempt 'err at 'kind at first port.close " ++
            "p proc.core.wait [] port.begin 'second set " ++
            "p proc.core.capture-limits [] port.call 'stdout at " ++
            "p proc.core.kill [] port.call pop " ++
            "second port.await second port.await second port.result 'signal at " ++
            "second wrap (port.result) @attempt 'err at 'kind at " ++
            "p port.close second port.await second port.close",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdout_capacity = 1,
        .stderr_capacity = 1,
        .max_stdout_capture = 4,
    }, "'cancelled 4 9 'contract", workers);
}

test "process: registered operations reject requests before affecting the process" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "proc.core.process {{'executable \"{s}\" 'args (\"echo\")}} port.open 'p set " ++
            "p wrap (proc.core.kill [1] port.call) @attempt 'err at 'kind at " ++
            "p proc.core.stdin port.endpoint dup [97] port.write port.finish " ++
            "p proc.core.stdout port.endpoint 1 port.read " ++
            "p proc.core.wait [] port.call 'code at p port.close " ++
            "p wrap (proc.core.wait [] port.call) @attempt 'err at 'kind at",
        .{fixture_path},
    );
    defer allocator.free(program);
    try expectStack(program, .{ .stdout_capacity = 1 }, "'domain [97] 0 'io");
}

test "process: run composes concurrent bounded capture and deadlines" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "{{'executable \"{s}\" 'args (\"split\" \"abc\" \"de\")}} proc.run " ++
            "dup 'stdout at swap dup 'stderr at swap 'term at 'code at " ++
            "{{'executable \"{s}\" 'args (\"echo\") 'stdin [0 1 255]}} proc.run 'stdout at " ++
            "[] ({{'executable \"{s}\" 'args (\"large\" \"16\" \"0\") 'stdout-limit 2}} proc.run) @attempt 'err at 'kind at " ++
            "[] ({{'executable \"{s}\" 'args (\"block\") 'timeout-ms 0}} proc.run) @attempt 'err at 'kind at",
        .{ fixture_path, fixture_path, fixture_path, fixture_path },
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdin_capacity = 1,
        .stdout_capacity = 1,
        .stderr_capacity = 1,
        .max_stdout_capture = 4,
        .max_stderr_capture = 4,
    }, "[97 98 99] [100 101] 0 [0 1 255] 'overflow 'timeout", workers);
}

test "process: wait observes broken input after the final accepted write" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "{{'executable \"{s}\" 'args (\"close-stdin\")}} proc.spawn 'p set " ++
            "p 1 proc.read-stdout p [1] proc.write p proc.close-input " ++
            "[] (p proc.wait) @attempt 'err at 'kind at p port.close",
        .{fixture_path},
    );
    defer allocator.free(program);
    for ([_]u32{ 1, 8 }) |workers| try expectStackWithWorkers(program, .{
        .stdin_capacity = 1,
        .stdout_capacity = 1,
        .stderr_capacity = 1,
    }, "[33] 'io", workers);
}
