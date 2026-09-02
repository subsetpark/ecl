const std = @import("std");
const pkg_lock_fixture = @import("pkg_lock_fixture.zig");
const pkg_example_hash = "315c772a16778673e205ae556185d25b4109ad40641e60e6b5d96d1f7db99745";
const pkg_runtime_hash = "362f3e41985531be0e370732383222845a4533c75f07ca384323e49ea93801eb";
const pkg_runtime_key = "a-1.0.0-" ++ pkg_runtime_hash;
const pkg_runtime_manifest =
    "{'format 1 'name \"root\" 'version \"0.1.0\" 'exports {} 'requires " ++
    "{\"a\" {'package \"a\" 'version \"1.0.0\" 'url \"https://example.invalid/a.tgz\" " ++
    "'hash \"sha256-" ++ pkg_runtime_hash ++ "\"}}}\n";
const pkg_runtime_lock =
    "{'format 1\n" ++
    " 'root \"root\"\n" ++
    " 'packages\n" ++
    " {\"a\" {'version \"1.0.0\" 'url \"https://example.invalid/a.tgz\" 'hash \"sha256-" ++ pkg_runtime_hash ++ "\"}}\n" ++
    " 'requires\n" ++
    " {\"a\" {}\n" ++
    "  \"root\" {\"a\" {'package \"a\" 'version \"1.0.0\"}}}}\n";
const pkg_runtime_vendor_lock =
    "{'format 1\n" ++
    " 'root \"root\"\n" ++
    " 'store 'vendor\n" ++
    " 'packages\n" ++
    " {\"a\" {'version \"1.0.0\" 'url \"https://example.invalid/a.tgz\" 'hash \"sha256-" ++ pkg_runtime_hash ++ "\"}}\n" ++
    " 'requires\n" ++
    " {\"a\" {}\n" ++
    "  \"root\" {\"a\" {'package \"a\" 'version \"1.0.0\"}}}}\n";

const test_project_lock =
    "{'format 1 'root \"app\" 'packages {} 'requires {\"app\" {}}}\n";

test "e2e: proc direct execution preserves argv cwd environment and policy" {
    const ecl_exe = try absoluteExe();
    defer allocator.free(ecl_exe);
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const cwd = try scratch.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    const expected = try std.fmt.allocPrint(
        allocator,
        "cwd={s}\nprobe=overlay\narg[0]=alpha\narg[1]=beta\n",
        .{cwd},
    );
    defer allocator.free(expected);
    var program = std.Io.Writer.Allocating.init(allocator);
    defer program.deinit();
    try program.writer.print(
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"inspect\" \"alpha\" \"beta\") " ++
            "'env {{\"ECL_PROCESS_PROBE\" \"overlay\"}}}} run " ++
            "dup 'stdout at ",
        .{process_exe},
    );
    try appendByteList(&program.writer, expected);
    try program.writer.writeAll(
        " match? swap dup 'stderr at [] match? swap " ++
            "'term at {'kind 'exited 'code 0} match?",
    );
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_PROCESS_PROBE", "base");
    var result = try cli.runOptions(.{
        .argv = &.{ ecl_exe, program.written() },
        .cwd = .{ .dir = scratch.dir },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "1 1 1\n", .stderr = "" });
}

test "e2e: proc ports stream binary data with backpressure and EOF" {
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    const program = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"echo\") 'stdin [0 1 255 2]}} run " ++
            "dup 'stdout at [0 1 255 2] match? swap 'stderr at [] match?",
        .{process_exe},
    );
    defer allocator.free(program);
    var result = try cli.run(&.{ build_options.ecl_exe, program });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "1 1\n", .stderr = "" });

    const large = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"large\" \"100000\" \"90000\")}} run " ++
            "dup 'stdout at len swap 'stderr at len",
        .{process_exe},
    );
    defer allocator.free(large);
    var large_result = try cli.run(&.{ build_options.ecl_exe, large });
    defer large_result.deinit();
    try large_result.expect(.{ .exit_code = 0, .stdout = "100000 90000\n", .stderr = "" });

    // A child may fill stderr before it ever makes stdout readable. Capture
    // must wait on both pipes after stdin closes or this shape deadlocks.
    const stderr_first = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"large\" \"0\" \"90000\")}} run " ++
            "dup 'stdout at len swap 'stderr at len",
        .{process_exe},
    );
    defer allocator.free(stderr_first);
    var stderr_first_result = try cli.runOptions(.{
        .argv = &.{ build_options.ecl_exe, stderr_first },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
    });
    defer stderr_first_result.deinit();
    try stderr_first_result.expect(.{ .exit_code = 0, .stdout = "0 90000\n", .stderr = "" });
}

test "e2e: proc wait returns stable tagged termination and idempotent lifecycle" {
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    const program = try std.fmt.allocPrint(
        allocator,
        "'proc ('spawn 'wait 'terminate 'kill) import " ++
            "{{'executable \"{s}\" 'args (\"exit\" \"7\")}} spawn 'p set " ++
            "p wait {{'kind 'exited 'code 7}} match? " ++
            "p terminate p kill p wait {{'kind 'exited 'code 7}} match?",
        .{process_exe},
    );
    defer allocator.free(program);
    var result = try cli.run(&.{ build_options.ecl_exe, program });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "1 1\n", .stderr = "" });
}

test "e2e: proc run captures split output termination timeout and overflow" {
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    const capture = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"split\" \"abc\" \"de\")}} run " ++
            "dup 'term at {{'kind 'exited 'code 0}} match? " ++
            "swap dup 'stdout at [97 98 99] match? swap 'stderr at [100 101] match?",
        .{process_exe},
    );
    defer allocator.free(capture);
    var captured = try cli.run(&.{ build_options.ecl_exe, capture });
    defer captured.deinit();
    try captured.expect(.{ .exit_code = 0, .stdout = "1 1 1\n", .stderr = "" });

    const deadline = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"block\") 'timeout-ms 25}} run",
        .{process_exe},
    );
    defer allocator.free(deadline);
    var timed_out = try cli.run(&.{ build_options.ecl_exe, deadline });
    defer timed_out.deinit();
    try timed_out.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'timeout", "process deadline expired" },
    });

    const immediate_deadline = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"block\") 'timeout-ms 0}} run",
        .{process_exe},
    );
    defer allocator.free(immediate_deadline);
    var immediately_timed_out = try cli.run(&.{ build_options.ecl_exe, immediate_deadline });
    defer immediately_timed_out.deinit();
    try immediately_timed_out.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'timeout", "process deadline expired" },
    });

    const broken_stdin = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"close-stdin\")}} 'stdin [1] 200000 take pair " ++
            "dict.from-flat dict.merge run",
        .{process_exe},
    );
    defer allocator.free(broken_stdin);
    var broken = try cli.run(&.{ build_options.ecl_exe, broken_stdin });
    defer broken.deinit();
    try broken.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "process pipe operation failed" },
    });

    const limited = try std.fmt.allocPrint(
        allocator,
        "'proc ('run) import {{'executable \"{s}\" " ++
            "'args (\"large\" \"16\" \"0\") 'stdout-limit 8}} run",
        .{process_exe},
    );
    defer allocator.free(limited);
    var overflowed = try cli.run(&.{ build_options.ecl_exe, limited });
    defer overflowed.deinit();
    try overflowed.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'overflow", "capture limit exceeded" },
    });
}

test "e2e: proc write serializes at scheduler call arrival" {
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    const program = try std.fmt.allocPrint(
        allocator,
        "'proc ('spawn 'write 'close-input 'read-stdout 'wait) import " ++
            "{{'executable \"{s}\" 'args (\"first-byte\")}} spawn 'p set " ++
            "[1] 200000 take 'bytes set " ++
            "[] (p bytes write) @spawn 'first set [] () @spawn await pop " ++
            "p [2] write first await pop p close-input p 1 read-stdout [1] match? p wait pop",
        .{process_exe},
    );
    defer allocator.free(program);
    var result = try runWithWorkers(&.{ build_options.ecl_exe, program }, "1");
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "1\n", .stderr = "" });
}

test "e2e: proc scope cancellation kills and reaps the process group" {
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    const program = try std.fmt.allocPrint(
        allocator,
        "'proc ('spawn 'read-stdout) import 'io ('pp) import " ++
            "{{'executable \"{s}\" 'args (\"descendant\")}} spawn " ++
            "dup 128 read-stdout pp",
        .{process_exe},
    );
    defer allocator.free(program);
    var result = try cli.runOptions(.{
        .argv = &.{ build_options.ecl_exe, program },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{ "[100 101 115 99 101 110 100 97 110 116 61", "<port:1>" },
        .stderr = "",
    });
    const processes = try descendantProcesses(result.stdout);
    try expectProcessGone(processes.descendant, processes.leader);
}

test "e2e: proc leader exit cleans retained and redirected descendants" {
    const process_exe = try absoluteProcessExe();
    defer allocator.free(process_exe);
    for ([_][]const u8{ "retained", "redirected" }) |mode| {
        const program = try std.fmt.allocPrint(
            allocator,
            "'proc ('run) import 'io ('pp) import " ++
                "{{'executable \"{s}\" 'args (\"orphan-descendant\" \"{s}\")}} run " ++
                "'stdout at pp",
            .{ process_exe, mode },
        );
        defer allocator.free(program);
        var result = try cli.runOptions(.{
            .argv = &.{ build_options.ecl_exe, program },
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
        });
        defer result.deinit();
        try result.expect(.{ .exit_code = 0, .stderr = "" });
        const processes = try descendantProcesses(result.stdout);
        try expectProcessGone(processes.descendant, processes.leader);
    }
}

fn appendByteList(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('[');
    for (bytes, 0..) |byte, index| {
        if (index != 0) try writer.writeByte(' ');
        try writer.print("{d}", .{byte});
    }
    try writer.writeByte(']');
}

const DescendantProcesses = struct {
    descendant: std.posix.pid_t,
    leader: std.posix.pid_t,
};

fn descendantProcesses(output: []const u8) !DescendantProcesses {
    if (output.len == 0 or output[0] != '[') return error.InvalidDescendantOutput;
    const close = std.mem.indexOfScalar(u8, output, ']') orelse return error.InvalidDescendantOutput;
    var decoded: [128]u8 = undefined;
    var count: usize = 0;
    var encoded = std.mem.tokenizeScalar(u8, output[1..close], ' ');
    while (encoded.next()) |item| {
        if (count == decoded.len) return error.InvalidDescendantOutput;
        decoded[count] = try std.fmt.parseInt(u8, item, 10);
        count += 1;
    }
    const prefix = "descendant=";
    const line = std.mem.trim(u8, decoded[0..count], "\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidDescendantOutput;
    const leader_separator = " leader=";
    const separator = std.mem.indexOf(u8, line, leader_separator) orelse
        return error.InvalidDescendantOutput;
    return .{
        .descendant = try std.fmt.parseInt(std.posix.pid_t, line[prefix.len..separator], 10),
        .leader = try std.fmt.parseInt(
            std.posix.pid_t,
            line[separator + leader_separator.len ..],
            10,
        ),
    };
}

fn expectProcessGone(pid: std.posix.pid_t, expected_group: std.posix.pid_t) !void {
    for (0..200) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            error.PermissionDenied => return error.ProcessProbePermissionDenied,
            else => |unexpected| return unexpected,
        };
        if (processStatus(pid)) |status| {
            if (status.state == 'Z' or status.state == 'X') return;
        }
        const pause: std.Io.Clock.Duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(5),
        };
        try pause.sleep(io);
    }
    const status = processStatus(pid) orelse return error.DescendantStatusUnavailable;
    if (status.group != expected_group) return error.DescendantLeftProcessGroup;
    return switch (status.state) {
        'R' => error.DescendantRunning,
        'S' => error.DescendantSleeping,
        'D' => error.DescendantUninterruptible,
        'T', 't' => error.DescendantStopped,
        else => error.DescendantStillRunning,
    };
}

const ProcessStatus = struct {
    state: u8,
    group: std.posix.pid_t,
};

fn processStatus(pid: std.posix.pid_t) ?ProcessStatus {
    if (builtin.os.tag != .linux) return null;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;
    const file = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch return null;
    defer _ = std.posix.system.close(file);
    var stat_buffer: [4096]u8 = undefined;
    var stat_len: usize = 0;
    while (stat_len != stat_buffer.len) {
        const amount = std.posix.read(file, stat_buffer[stat_len..]) catch return null;
        if (amount == 0) break;
        stat_len += amount;
    }
    const stat = stat_buffer[0..stat_len];
    const command_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    if (command_end + 2 >= stat.len or stat[command_end + 1] != ' ')
        return null;
    var fields = std.mem.tokenizeScalar(u8, stat[command_end + 2 ..], ' ');
    const state = fields.next() orelse return null;
    if (state.len != 1) return null;
    _ = fields.next() orelse return null;
    const group = std.fmt.parseInt(std.posix.pid_t, fields.next() orelse return null, 10) catch
        return null;
    return .{ .state = state[0], .group = group };
}

fn writeTestProject(
    directory: std.Io.Dir,
    manifest: []const u8,
    files: []const struct { path: []const u8, source: []const u8 },
) !void {
    try directory.writeFile(io, .{ .sub_path = "ecl.pkg", .data = manifest });
    try directory.writeFile(io, .{ .sub_path = "ecl.lock", .data = test_project_lock });
    for (files) |file| try directory.writeFile(io, .{
        .sub_path = file.path,
        .data = file.source,
    });
}

test "e2e: ecl test runs the default stateful runner" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try writeTestProject(
        scratch.dir,
        "{'format 1 'name \"app\" 'version \"0.1.0\" " ++
            "'exports {\"app.suite\" [\"suite.ecl\"]} 'requires {}}\n",
        &.{.{
            .path = "suite.ecl",
            .source = "[] (0 " ++
                "((1 + dup without) within dup 1 = {'kind 'user} assert) 'first test " ++
                "((dup without) within dup 1 = {'kind 'user} assert) 'second test " ++
                "(missing) 'third-fails test " ++
                "(1) 'z-after test" ++
                ") 'app.suite @defm\n",
        }},
    );
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var result = try cli.runOptions(.{
        .argv = &.{ exe, "test" },
        .cwd = .{ .dir = scratch.dir },
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 1,
        .stdout_contains = &.{
            "ok app.suite.first\n",
            "ok app.suite.second\n",
            "FAIL {'module 'app.suite 'name 'third-fails}",
            "ok app.suite.z-after\n",
        },
        .stderr = "",
    });
}

test "e2e: ecl test accepts a userland runner" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try writeTestProject(
        scratch.dir,
        "{'format 1 'name \"app\" 'version \"0.1.0\" " ++
            "'exports {\"app.suite\" [\"suite.ecl\"] " ++
            "\"app.custom\" [\"custom.ecl\"]} " ++
            "'requires {}}\n",
        &.{
            .{
                .path = "suite.ecl",
                .source = "[] ((42) 'answer test) 'app.suite @defm\n",
            },
            .{
                .path = "custom.ecl",
                .source = "[] ((args [\"chosen\"] match? {'kind 'user} assert " ++
                    "tests dup len 1 = {'kind 'user} assert " ++
                    "first @test 'ok dict.has? {'kind 'user} assert " ++
                    "\"custom\" io.print) 'run def) 'app.custom.runner @defm\n",
            },
        },
    );
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var result = try cli.runOptions(.{
        .argv = &.{ exe, "test", "--runner", "app.custom.runner.run", "--", "chosen" },
        .cwd = .{ .dir = scratch.dir },
    });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "custom\n", .stderr = "" });
}

test "e2e: ecl test reports project and runner failures" {
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var absent = try cli.runOptions(.{
        .argv = &.{ exe, "test" },
        .cwd = .{ .dir = empty.dir },
    });
    defer absent.deinit();
    try absent.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{"lock-backed root project"},
    });

    var invalid = std.testing.tmpDir(.{});
    defer invalid.cleanup();
    try invalid.dir.writeFile(io, .{
        .sub_path = "ecl.pkg",
        .data = "{'format 1 'name \"app\" 'version \"0.1.0\" 'exports {} 'requires {}}\n",
    });
    try invalid.dir.writeFile(io, .{ .sub_path = "ecl.lock", .data = "not a lock\n" });
    var invalid_result = try cli.runOptions(.{
        .argv = &.{ exe, "test" },
        .cwd = .{ .dir = invalid.dir },
    });
    defer invalid_result.deinit();
    try invalid_result.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{"invalid project lock"},
    });

    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    try writeTestProject(
        project.dir,
        "{'format 1 'name \"app\" 'version \"0.1.0\" " ++
            "'exports {\"app.suite\" [\"suite.ecl\"]} 'requires {}}\n",
        &.{.{ .path = "suite.ecl", .source = "[] ((1) 'one test) 'app.suite @defm\n" }},
    );
    var unqualified = try cli.runOptions(.{
        .argv = &.{ exe, "test", "--runner", "run" },
        .cwd = .{ .dir = project.dir },
    });
    defer unqualified.deinit();
    try unqualified.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{"runner must be a qualified public word"},
    });
    var missing = try cli.runOptions(.{
        .argv = &.{ exe, "test", "--runner", "missing.runner.run" },
        .cwd = .{ .dir = project.dir },
    });
    defer missing.deinit();
    try missing.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "missing.runner", "'kind 'undefined-word" },
    });
}

test "e2e: package lock resolves import by name with ECL PATH unset" {
    var fixture = try pkg_lock_fixture.Fixture.init(allocator, io, true);
    defer fixture.deinit();
    var nested = try fixture.openNested();
    defer nested.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", fixture.cache);
    var result = try cli.runOptions(.{
        .argv = &.{ exe, "-e", "smoke.answer io.pp" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });
}

test "e2e: locked missing store entry never fetches or falls back" {
    var fixture = try pkg_lock_fixture.Fixture.init(allocator, io, false);
    defer fixture.deinit();
    var nested = try fixture.openNested();
    defer nested.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", fixture.cache);
    try environment.put("ECL_PATH", fixture.search);
    var result = try cli.runOptions(.{
        .argv = &.{ exe, "-e", "smoke.answer io.pp" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "'kind 'io", "locked package `smoke`", "ecl pkg sync" },
    });
}

test "e2e: pkg CLI reports usage without a subcommand" {
    var result = try run(&.{ build_options.ecl_exe, "pkg" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{
            "ecl pkg <init|add|sync|tree|why|verify|vendor|gc>",
            "sync [--offline]",
        },
    });
}

test "e2e: pkg init derives a canonical root manifest without overwriting" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "sample", .default_dir);
    var project = try scratch.dir.openDir(io, "sample", .{});
    defer project.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);

    var initialized = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "init" },
        .cwd = .{ .dir = project },
    });
    defer initialized.deinit();
    try initialized.expect(.{
        .exit_code = 0,
        .stdout = "initialized ecl.pkg for sample\n",
        .stderr = "",
    });
    const manifest = try project.readFileAlloc(io, "ecl.pkg", allocator, .unlimited);
    defer allocator.free(manifest);
    try std.testing.expectEqualStrings(
        "{'format 1 'name \"sample\" 'version \"0.1.0\" 'exports {} 'requires {}}\n",
        manifest,
    );

    var repeated = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "init" },
        .cwd = .{ .dir = project },
    });
    defer repeated.deinit();
    try repeated.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "ecl.pkg", "already exists" },
    });

    try scratch.dir.createDir(io, "Bad_Name", .default_dir);
    var invalid_project = try scratch.dir.openDir(io, "Bad_Name", .{});
    defer invalid_project.close(io);
    var invalid_derived = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "init" },
        .cwd = .{ .dir = invalid_project },
    });
    defer invalid_derived.deinit();
    try invalid_derived.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "Bad_Name", "ecl pkg init <name>" },
    });
    var named = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "init", "valid.name" },
        .cwd = .{ .dir = invalid_project },
    });
    defer named.deinit();
    try named.expect(.{
        .exit_code = 0,
        .stdout = "initialized ecl.pkg for valid.name\n",
        .stderr = "",
    });
}

test "e2e: pkg tree and why explain the locked graph from a nested directory" {
    var fixture = try pkg_lock_fixture.Fixture.init(allocator, io, false);
    defer fixture.deinit();
    var nested = try fixture.openNested();
    defer nested.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", fixture.cache);

    var tree = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "tree" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer tree.deinit();
    try tree.expect(.{
        .exit_code = 0,
        .stdout = "root\nroot -> smoke 1.0.0\n",
        .stderr = "",
    });

    var why = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "why", "smoke.answer" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer why.deinit();
    try why.expect(.{
        .exit_code = 0,
        .stdout = "smoke.answer: root -> smoke 1.0.0\n",
        .stderr = "",
    });
}

test "e2e: pkg offline sync and verify use sealed immutable store entries" {
    var fixture = try pkg_lock_fixture.Fixture.init(allocator, io, true);
    defer fixture.deinit();
    var nested = try fixture.openNested();
    defer nested.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", fixture.cache);

    var sync = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "sync", "--offline" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer sync.deinit();
    try sync.expect(.{
        .exit_code = 0,
        .stdout = "synced 1 packages\n",
        .stderr = "",
    });

    var verified = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "verify" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer verified.deinit();
    try verified.expect(.{
        .exit_code = 0,
        .stdout = "verified 1 packages\n",
        .stderr = "",
    });

    try fixture.directory.dir.writeFile(io, .{
        .sub_path = "cache/smoke-1.0.0-" ++ pkg_lock_fixture.package_hash[7..] ++ "/.ecl-package.tgz",
        .data = "tampered fixture\n",
    });
    var tampered = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "verify" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer tampered.deinit();
    try tampered.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{"package `smoke` archive seal does not match lock hash"},
    });
}

test "e2e: pkg sync regenerates a corrupt lock from the explicit project" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "project", .default_dir);
    try scratch.dir.createDir(io, "cache", .default_dir);
    try scratch.dir.writeFile(io, .{
        .sub_path = "project/ecl.pkg",
        .data = "{'format 1 'name \"root\" 'version \"0.1.0\" 'exports {} 'requires {}}\n",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "project/ecl.lock",
        .data = "not a lock\n",
    });
    var project = try scratch.dir.openDir(io, "project", .{});
    defer project.close(io);
    const cache = try scratch.dir.realPathFileAlloc(io, "cache", allocator);
    defer allocator.free(cache);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", cache);

    var synced = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "sync", "--offline" },
        .cwd = .{ .dir = project },
        .environ_map = &environment,
    });
    defer synced.deinit();
    try synced.expect(.{ .exit_code = 0, .stdout = "synced 0 packages\n", .stderr = "" });
    const lock = try project.readFileAlloc(io, "ecl.lock", allocator, .unlimited);
    defer allocator.free(lock);
    try std.testing.expectEqualStrings(
        "{'format 1\n 'root \"root\"\n 'packages\n {}\n 'requires\n {\"root\" {}}}\n",
        lock,
    );
}

test "e2e: pkg offline sync names an absent immutable store entry without fetching" {
    var fixture = try pkg_lock_fixture.Fixture.init(allocator, io, false);
    defer fixture.deinit();
    var nested = try fixture.openNested();
    defer nested.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", fixture.cache);

    var result = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "sync", "--offline" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{
            "offline synchronization is missing a package store entry",
            "'package \"smoke\"",
        },
    });
}

test "e2e: checked-in package consumer executes and remains byte-stable offline" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "project", .default_dir);
    try scratch.dir.createDir(io, "cache", .default_dir);
    try scratch.dir.createDir(
        io,
        "cache/smoke-1.0.0-" ++ pkg_example_hash,
        .default_dir,
    );
    try scratch.dir.writeFile(io, .{ .sub_path = "project/ecl.pkg", .data = build_options.pkg_example_manifest });
    try scratch.dir.writeFile(io, .{ .sub_path = "project/ecl.lock", .data = build_options.pkg_example_lock });
    try scratch.dir.writeFile(io, .{ .sub_path = "project/main.ecl", .data = build_options.pkg_example_program });
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/smoke-1.0.0-" ++ pkg_example_hash ++ "/ecl.pkg",
        .data = "{'format 1 'name \"smoke\" 'version \"1.0.0\" 'exports {\"smoke\" [\"**/*\"]} 'requires {}}\n",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/smoke-1.0.0-" ++ pkg_example_hash ++ "/smoke.ecl",
        .data = "[] ((42) 'answer def) 'smoke @defm\n",
    });
    const cache = try scratch.dir.realPathFileAlloc(io, "cache", allocator);
    defer allocator.free(cache);
    var project = try scratch.dir.openDir(io, "project", .{});
    defer project.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", cache);

    var execution = try cli.runOptions(.{
        .argv = &.{ exe, "main.ecl" },
        .cwd = .{ .dir = project },
        .environ_map = &environment,
    });
    defer execution.deinit();
    try execution.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });

    var offline = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "sync", "--offline" },
        .cwd = .{ .dir = project },
        .environ_map = &environment,
    });
    defer offline.deinit();
    try offline.expect(.{ .exit_code = 0, .stdout = "synced 1 packages\n", .stderr = "" });
    const rewritten_lock = try project.readFileAlloc(io, "ecl.lock", allocator, .unlimited);
    defer allocator.free(rewritten_lock);
    try std.testing.expectEqualStrings(build_options.pkg_example_lock, rewritten_lock);

    var why = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "why", "smoke.answer" },
        .cwd = .{ .dir = project },
        .environ_map = &environment,
    });
    defer why.deinit();
    try why.expect(.{
        .exit_code = 0,
        .stdout = "smoke.answer: example.pkg-smoke -> smoke 1.0.0\n",
        .stderr = "",
    });
}

test "e2e: pkg vendor makes locked execution and verification cache-independent" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "project", .default_dir);
    try scratch.dir.createDir(io, "project/nested", .default_dir);
    try scratch.dir.createDir(io, "cache", .default_dir);
    try scratch.dir.createDir(io, "cache/" ++ pkg_runtime_key, .default_dir);
    try scratch.dir.writeFile(io, .{ .sub_path = "project/ecl.pkg", .data = pkg_runtime_manifest });
    try scratch.dir.writeFile(io, .{ .sub_path = "project/ecl.lock", .data = pkg_runtime_lock });
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/" ++ pkg_runtime_key ++ "/ecl.pkg",
        .data = "{'format 1 'name \"a\" 'version \"1.0.0\" 'exports {\"a\" [\"**/*\"]} 'requires {}}\n",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/" ++ pkg_runtime_key ++ "/a.ecl",
        .data = "[] ((42) 'answer def) 'a @defm\n",
    });
    const archive = try decodeHex(build_options.pkg_runtime_archive);
    defer allocator.free(archive);
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/" ++ pkg_runtime_key ++ "/.ecl-package.tgz",
        .data = archive[0 .. archive.len - 1],
    });
    const cache = try scratch.dir.realPathFileAlloc(io, "cache", allocator);
    defer allocator.free(cache);
    var nested = try scratch.dir.openDir(io, "project/nested", .{});
    defer nested.close(io);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", cache);

    var rejected = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "vendor" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer rejected.deinit();
    try rejected.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{"archive seal does not match lock hash"},
    });
    const unchanged = try scratch.dir.readFileAlloc(io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(pkg_runtime_lock, unchanged);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.dir.statFile(io, "project/vendor/" ++ pkg_runtime_key, .{ .follow_symlinks = false }),
    );
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/" ++ pkg_runtime_key ++ "/.ecl-package.tgz",
        .data = archive,
    });

    var vendored = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "vendor" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer vendored.deinit();
    try vendored.expect(.{ .exit_code = 0, .stdout = "vendored 1 packages\n", .stderr = "" });
    const rewritten = try scratch.dir.readFileAlloc(io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(rewritten);
    try std.testing.expectEqualStrings(pkg_runtime_vendor_lock, rewritten);

    try scratch.dir.deleteTree(io, "cache");
    var execution = try cli.runOptions(.{
        .argv = &.{ exe, "-e", "a.answer io.pp" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer execution.deinit();
    try execution.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });

    var verified = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "verify" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer verified.deinit();
    try verified.expect(.{ .exit_code = 0, .stdout = "verified 1 packages\n", .stderr = "" });

    var synced = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "sync", "--offline" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer synced.deinit();
    try synced.expect(.{ .exit_code = 0, .stdout = "synced 1 packages\n", .stderr = "" });
    const preserved = try scratch.dir.readFileAlloc(io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(pkg_runtime_vendor_lock, preserved);

    var repeated = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "vendor" },
        .cwd = .{ .dir = nested },
        .environ_map = &environment,
    });
    defer repeated.deinit();
    try repeated.expect(.{ .exit_code = 0, .stdout = "vendored 1 packages\n", .stderr = "" });
}

test "e2e: pkg gc retains the union of named locks and preserves unknown cache nodes" {
    const hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const hash_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const hash_d = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const hash_e = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const key_a = "a-1.0.0-" ++ hash_a;
    const key_b = "b-2.0.0-" ++ hash_b;
    const key_c = "c-3.0.0-" ++ hash_c;
    const key_d = "d-4.0.0-" ++ hash_d;
    const key_e = "e-5.0.0-" ++ hash_e;
    const lock_a = "{'format 1 'root \"one\" 'packages {\"a\" {'version \"1.0.0\" " ++
        "'url \"https://example.invalid/a.tgz\" 'hash \"sha256-" ++ hash_a ++
        "\"}} 'requires {\"a\" {} \"one\" {\"a\" {'package \"a\" 'version \"1.0.0\"}}}}\n";
    const lock_b = "{'format 1 'root \"two\" 'packages {\"b\" {'version \"2.0.0\" " ++
        "'url \"https://example.invalid/b.tgz\" 'hash \"sha256-" ++ hash_b ++
        "\"}} 'requires {\"b\" {} \"two\" {\"b\" {'package \"b\" 'version \"2.0.0\"}}}}\n";

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "cache", .default_dir);
    try scratch.dir.createDir(io, "cache/" ++ key_a, .default_dir);
    try scratch.dir.createDir(io, "cache/" ++ key_b, .default_dir);
    try scratch.dir.createDir(io, "cache/" ++ key_c, .default_dir);
    try scratch.dir.createDir(io, "cache/" ++ key_c ++ "/nested", .default_dir);
    try scratch.dir.createDir(io, "cache/" ++ key_c ++ "/nested/deep", .default_dir);
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/" ++ key_c ++ "/nested/deep/payload",
        .data = "garbage\n",
    });
    try scratch.dir.createDir(io, "cache/.ecl-gc-interrupted", .default_dir);
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/.ecl-gc-interrupted/payload",
        .data = "stale\n",
    });
    try scratch.dir.createDir(io, "cache/.ecl-gc-1-" ++ key_c, .default_dir);
    try scratch.dir.writeFile(io, .{
        .sub_path = "cache/.ecl-gc-1-" ++ key_c ++ "/payload",
        .data = "collision\n",
    });
    try scratch.dir.createDir(io, "cache/operator-notes", .default_dir);
    try scratch.dir.writeFile(io, .{ .sub_path = "cache/" ++ key_d, .data = "not a directory\n" });
    try scratch.dir.symLink(io, "operator-notes", "cache/" ++ key_e, .{});
    try scratch.dir.writeFile(io, .{ .sub_path = "one.lock", .data = lock_a });
    try scratch.dir.writeFile(io, .{ .sub_path = "two.lock", .data = lock_b });
    const cache = try scratch.dir.realPathFileAlloc(io, "cache", allocator);
    defer allocator.free(cache);
    const exe = try absoluteExe();
    defer allocator.free(exe);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_CACHE", cache);

    var collected = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "gc", "one.lock", "two.lock" },
        .cwd = .{ .dir = scratch.dir },
        .environ_map = &environment,
    });
    defer collected.deinit();
    try collected.expect(.{ .exit_code = 0, .stdout = "removed 1 packages\n", .stderr = "" });
    _ = try scratch.dir.statFile(io, "cache/" ++ key_a, .{ .follow_symlinks = false });
    _ = try scratch.dir.statFile(io, "cache/" ++ key_b, .{ .follow_symlinks = false });
    try std.testing.expectError(
        error.FileNotFound,
        scratch.dir.statFile(io, "cache/" ++ key_c, .{ .follow_symlinks = false }),
    );
    try std.testing.expectError(
        error.FileNotFound,
        scratch.dir.statFile(io, "cache/.ecl-gc-interrupted", .{ .follow_symlinks = false }),
    );
    try std.testing.expectError(
        error.FileNotFound,
        scratch.dir.statFile(io, "cache/.ecl-gc-1-" ++ key_c, .{ .follow_symlinks = false }),
    );
    _ = try scratch.dir.statFile(io, "cache/operator-notes", .{ .follow_symlinks = false });
    const preserved_file = try scratch.dir.statFile(io, "cache/" ++ key_d, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, preserved_file.kind);
    const preserved_link = try scratch.dir.statFile(io, "cache/" ++ key_e, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, preserved_link.kind);

    var repeated = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "gc", "one.lock", "two.lock" },
        .cwd = .{ .dir = scratch.dir },
        .environ_map = &environment,
    });
    defer repeated.deinit();
    try repeated.expect(.{ .exit_code = 0, .stdout = "removed 0 packages\n", .stderr = "" });

    // A relative ECL_CACHE keeps its meaning: it is resolved once against the
    // startup working directory, so a fresh unreferenced entry there is
    // collected exactly as through the absolute spelling.
    try scratch.dir.createDir(io, "cache/f-6.0.0-" ++ hash_a, .default_dir);
    var relative_environment = std.process.Environ.Map.init(allocator);
    defer relative_environment.deinit();
    try relative_environment.put("ECL_CACHE", "cache");
    var relative = try cli.runOptions(.{
        .argv = &.{ exe, "pkg", "gc", "one.lock", "two.lock" },
        .cwd = .{ .dir = scratch.dir },
        .environ_map = &relative_environment,
    });
    defer relative.deinit();
    try relative.expect(.{ .exit_code = 0, .stdout = "removed 1 packages\n", .stderr = "" });
    try std.testing.expectError(
        error.FileNotFound,
        scratch.dir.statFile(io, "cache/f-6.0.0-" ++ hash_a, .{ .follow_symlinks = false }),
    );
}
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli_test_support.zig");

test {
    _ = @import("scheduler_shell_property.zig");
}

const allocator = std.testing.allocator;
const io = std.testing.io;

fn run(arguments: []const []const u8) !cli.Result {
    return cli.run(arguments);
}

fn runWithWorkers(arguments: []const []const u8, workers: []const u8) !cli.Result {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_WORKERS", workers);
    return cli.runOptions(.{ .argv = arguments, .environ_map = &environment });
}

fn runWithNativePath(arguments: []const []const u8) !cli.Result {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_PATH", build_options.native_fixture_dir);
    return cli.runOptions(.{ .argv = arguments, .environ_map = &environment });
}

fn absoluteExe() ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(
        io,
        build_options.ecl_exe,
        allocator,
    );
}

fn absoluteProcessExe() ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(
        io,
        build_options.process_exe,
        allocator,
    );
}

fn decodeHex(encoded: []const u8) ![]u8 {
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    var high: ?u8 = null;
    for (encoded) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        const nibble = try std.fmt.charToDigit(byte, 16);
        if (high) |first| {
            try bytes.writer.writeByte(first << 4 | nibble);
            high = null;
        } else high = nibble;
    }
    if (high != null) return error.InvalidFixture;
    return allocator.dupe(u8, bytes.written());
}

fn runWithInput(arguments: []const []const u8, input: []const u8) !cli.Result {
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const stdout = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(stdout);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(stderr);
    return .{ .term = try child.wait(io), .stdout = stdout, .stderr = stderr };
}

test "soul test executes the installed artifact" {
    var result = try run(&.{ build_options.ecl_exe, "3 4 +" });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "7\n", .stderr = "" });

    if (builtin.os.tag == .linux) {
        // Hold the release binary at an explicit stdin pipe only after the
        // soul result has been printed. /proc then observes the live process
        // after Session execution began, proving the lazy scheduler did not
        // create workers for an ordinary unit.
        var child = try std.process.spawn(io, .{
            .argv = &.{ build_options.ecl_exe, "-e", "3 4 + io.pp io.stdin pop" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(io);
        var stdout_buffer: [64]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
        try std.testing.expectEqualStrings(
            "7",
            try stdout_reader.interface.takeDelimiterExclusive('\n'),
        );

        var task_path_buffer: [64]u8 = undefined;
        const task_path = try std.fmt.bufPrint(
            &task_path_buffer,
            "/proc/{d}/task",
            .{child.id.?},
        );
        var task_dir = try std.Io.Dir.openDirAbsolute(io, task_path, .{ .iterate = true });
        defer task_dir.close(io);
        var tasks = task_dir.iterate();
        var thread_count: usize = 0;
        while (try tasks.next(io)) |_| thread_count += 1;
        try std.testing.expectEqual(@as(usize, 1), thread_count);

        child.stdin.?.close(io);
        child.stdin = null;
        const term = try child.wait(io);
        switch (term) {
            .exited => |status| try std.testing.expectEqual(@as(u8, 0), status),
            else => return error.UnexpectedTermination,
        }
    }
}

test "e2e: native extension discovery ABI and reflection acceptance" {
    var result = try runWithNativePath(&.{
        build_options.ecl_exe,
        "-e",
        "41 sample.increment 'sample.increment which 'sample.increment see",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "sample.increment -> sample.increment native public generation 1 " ++
            "(n -- result) requires call, build-values, reschedule\n" ++
            "(n -- result : \"Increment an integer.\") <native:sample.increment> requires call build-values\n" ++
            "reschedule\n42\n",
        .stderr = "",
    });
}

test "e2e: worker configuration rejects every non-positive decimal form" {
    const invalid = [_][]const u8{ "", "0", "+1", "-1", "1x", "999999999999999999999999999999999999" };
    for (invalid) |workers| {
        var result = try runWithWorkers(&.{ build_options.ecl_exe, "3 4 +" }, workers);
        defer result.deinit();
        try result.expect(.{
            .exit_code = 2,
            .stdout = "",
            .stderr = "ecl: ECL_WORKERS must be a positive base-10 integer\n",
        });
    }
}

test "e2e: cancellation timeout and @each agree at one and eight workers" {
    for ([_][]const u8{ "1", "8" }) |workers| {
        var cancel_timeout = try runWithWorkers(
            &.{ build_options.ecl_exe, "test/acceptance/cancel-timeout.ecl" },
            workers,
        );
        defer cancel_timeout.deinit();
        try cancel_timeout.expect(.{
            .exit_code = 0,
            .stdout = "'cancelled\n'timeout\n",
            .stderr = "",
        });

        var par_each = try runWithWorkers(
            &.{ build_options.ecl_exe, "test/acceptance/at-each.ecl" },
            workers,
        );
        defer par_each.deinit();
        try par_each.expect(.{
            .exit_code = 0,
            .stdout = "[1 4 9]\n'domain\n'left-missing\n",
            .stderr = "",
        });
    }
}

test "runtime errors are dicts on stderr" {
    var result = try run(&.{ build_options.ecl_exe, "1 0 /" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "'kind 'domain", "'word '/" },
    });

    var missing = try run(&.{ build_options.ecl_exe, "missing" });
    defer missing.deinit();
    try missing.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'undefined-word", "'word 'missing", "'name 'missing" },
    });

    var raised = try run(&.{ build_options.ecl_exe, "{'kind 'custom} raise" });
    defer raised.deinit();
    try raised.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{
            "'kind 'custom",
            "'msg \"raised 'custom\"",
            "'word 'raise",
            "'trace ['raise]",
            "'source \"<command>\"",
        },
    });
}

test "piped stdin is exactly one unit" {
    var result = try runWithInput(&.{ build_options.ecl_exe, "-" }, "5 6 +");
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "11\n", .stderr = "" });
}

test "ecl fmt formats files and stdin without evaluating source" {
    const input = "(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb " ++
        "cccccccccccccccccccccccccccccccccccccccc) {'kind 'user} raise";
    const expected = "(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        " cccccccccccccccccccccccccccccccccccccccc) {'kind 'user} raise\n";

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    try temporary.dir.writeFile(io, .{ .sub_path = "format.ecl", .data = input });
    var file_result = try cli.runOptions(.{
        .argv = &.{ exe, "fmt", "format.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer file_result.deinit();
    try file_result.expect(.{ .exit_code = 0, .stdout = expected, .stderr = "" });
    const unchanged = try temporary.dir.readFileAlloc(io, "format.ecl", allocator, .unlimited);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(input, unchanged);
    const original_info = try temporary.dir.statFile(
        io,
        "format.ecl",
        .{ .follow_symlinks = false },
    );

    var write_result = try cli.runOptions(.{
        .argv = &.{ exe, "fmt", "-w", "format.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer write_result.deinit();
    try write_result.expect(.{ .exit_code = 0, .stdout = "", .stderr = "" });
    const rewritten = try temporary.dir.readFileAlloc(io, "format.ecl", allocator, .unlimited);
    defer allocator.free(rewritten);
    try std.testing.expectEqualStrings(expected, rewritten);
    const rewritten_info = try temporary.dir.statFile(
        io,
        "format.ecl",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(original_info.permissions, rewritten_info.permissions);

    try temporary.dir.symLink(io, "format.ecl", "format-link.ecl", .{});
    var linked_write = try cli.runOptions(.{
        .argv = &.{ exe, "fmt", "-w", "format-link.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer linked_write.deinit();
    try linked_write.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr = "ecl fmt: -w target `format-link.ecl` is not a regular file\n",
    });
    const link_info = try temporary.dir.statFile(
        io,
        "format-link.ecl",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_info.kind);

    const invalid_source = "(unclosed";
    try temporary.dir.writeFile(io, .{ .sub_path = "invalid.ecl", .data = invalid_source });
    var invalid_write = try cli.runOptions(.{
        .argv = &.{ exe, "fmt", "-w", "invalid.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer invalid_write.deinit();
    try invalid_write.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr = "ecl fmt: source does not parse\n",
    });
    const preserved = try temporary.dir.readFileAlloc(io, "invalid.ecl", allocator, .unlimited);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(invalid_source, preserved);

    var stdin_result = try runWithInput(&.{ build_options.ecl_exe, "fmt", "-" }, input);
    defer stdin_result.deinit();
    try stdin_result.expect(.{ .exit_code = 0, .stdout = expected, .stderr = "" });

    var stdin_write = try run(&.{ build_options.ecl_exe, "fmt", "-w", "-" });
    defer stdin_write.deinit();
    try stdin_write.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr = "ecl fmt: -w requires a file path\n",
    });

    var invalid = try run(&.{ build_options.ecl_exe, "fmt" });
    defer invalid.deinit();
    try invalid.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr = "ecl fmt: usage: ecl fmt [-w] <FILE|->\n",
    });
}

test "scripts print only explicitly" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    try temporary.dir.writeFile(io, .{ .sub_path = "quiet.ecl", .data = "3 4 +" });
    var quiet = try cli.runOptions(.{
        .argv = &.{ exe, "quiet.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer quiet.deinit();
    try quiet.expect(.{ .exit_code = 0, .stdout = "", .stderr = "" });

    try temporary.dir.writeFile(io, .{
        .sub_path = "loud.ecl",
        .data = "\"hi\" io.prin 'visible io.pp",
    });
    var loud = try cli.runOptions(.{
        .argv = &.{ exe, "loud.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer loud.deinit();
    try loud.expect(.{ .exit_code = 0, .stdout = "hi'visible\n", .stderr = "" });
}

test "e2e: io.pp and final stack display elide huge lists while str stays canonical" {
    var pretty = try run(&.{ build_options.ecl_exe, "-e", "4096 range io.pp" });
    defer pretty.deinit();
    try pretty.expect(.{
        .exit_code = 0,
        .stdout = "[<4096-values-elided>]\n",
        .stderr = "",
    });

    var final_stack = try run(&.{ build_options.ecl_exe, "-e", "4096 range" });
    defer final_stack.deinit();
    try final_stack.expect(.{
        .exit_code = 0,
        .stdout = "[<4096-values-elided>]\n",
        .stderr = "",
    });

    var parsed_rows = try run(&.{
        build_options.ecl_exe,
        "-e",
        "\"a,b\\n\" 300 str.repeat csv.parse io.pp",
    });
    defer parsed_rows.deinit();
    try parsed_rows.expect(.{
        .exit_code = 0,
        .stdout = "(<300-values-elided>)\n",
        .stderr = "",
    });

    var canonical = try run(&.{ build_options.ecl_exe, "-e", "4096 range str len 4096 >" });
    defer canonical.deinit();
    try canonical.expect(.{ .exit_code = 0, .stdout = "1\n", .stderr = "" });
}

test "invalid UTF-8 files surface parse dicts" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    try temporary.dir.writeFile(io, .{
        .sub_path = "invalid.ecl",
        .data = &.{ 0xff, 0xfe },
    });
    var result = try cli.runOptions(.{
        .argv = &.{ exe, "invalid.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'parse", "not valid UTF-8" },
    });
}

test "e2e: grammar negative acceptance" {
    var mismatched = try run(&.{ build_options.ecl_exe, "-e", "[1 2 3)" });
    defer mismatched.deinit();
    try mismatched.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'parse", "mismatched delimiter" },
    });

    var private_at_top = try run(&.{ build_options.ecl_exe, "-e", "(1) (x) 'x defp" });
    defer private_at_top.deinit();
    try private_at_top.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'domain", "defp/setp are legal only in a module root" },
    });
}

test "missing scripts and version have stable CLI behavior" {
    var missing = try run(&.{ build_options.ecl_exe, "definitely-missing.ecl" });
    defer missing.deinit();
    try missing.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "does not exist" },
    });

    var version = try run(&.{ build_options.ecl_exe, "-V" });
    defer version.deinit();
    try version.expect(.{ .exit_code = 0, .stdout = "ecl 0.1.0\n", .stderr = "" });

    var arguments = try run(&.{ build_options.ecl_exe, "-e", "args", "alpha", "beta" });
    defer arguments.deinit();
    try arguments.expect(.{
        .exit_code = 0,
        .stdout = "(\"alpha\" \"beta\")\n",
        .stderr = "",
    });

    var requested_exit = try run(&.{ build_options.ecl_exe, "7 exit" });
    defer requested_exit.deinit();
    try requested_exit.expect(.{ .exit_code = 7, .stdout = "", .stderr = "" });
}

test "e2e: module privacy acceptance" {
    var privacy = try run(&.{ build_options.ecl_exe, "test/acceptance/modules-privacy.ecl" });
    defer privacy.deinit();
    try privacy.expect(.{
        .exit_code = 1,
        .stdout = "42\n",
        .stderr_contains = &.{"'word 'm.s"},
    });
}

test "e2e: hot reload all access paths acceptance" {
    var result = try run(&.{ build_options.ecl_exe, "test/acceptance/hot-reload.ecl" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "11\n21\n31\n12\n22\n32\n",
        .stderr = "",
    });
}

test "e2e: module effect declaration acceptance" {
    // An omitted effect is legal and adds no inferred check: the word runs
    // across the home boundary exactly as written.
    var missing = try run(&.{ build_options.ecl_exe, "-e", "[] ((dup +) 'fine def) 'm @defm 2 m.fine" });
    defer missing.deinit();
    try missing.expect(.{ .exit_code = 0, .stdout = "4\n", .stderr = "" });

    var lying = try run(&.{ build_options.ecl_exe, "-e", "[] (( a -- b c ) (dup +) 'lies def) 'm @defm 1 m.lies" });
    defer lying.deinit();
    try lying.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'contract", "'word 'm.lies" },
    });

    var visible = try run(&.{ build_options.ecl_exe, "-e", "[] (( a -- b ) (dup +) 'dbl def) 'm @defm 'm.dbl see" });
    defer visible.deinit();
    try visible.expect(.{
        .exit_code = 0,
        .stdout = "(a -- b) (dup +)\n",
        .stderr = "",
    });
}

test "e2e: explicit import replacement acceptance" {
    var result = try run(&.{
        build_options.ecl_exe,
        "-e",
        "1 'mean set 2 'count set [] (3 'mean set 4 'count set) 'stats @defm " ++
            "'stats ('mean 'count) import mean count",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "3 4\n",
        .stderr = "",
    });
}

test "e2e: reflection acceptance" {
    var result = try run(&.{
        build_options.ecl_exe,
        "-e",
        "[] (40 's setp ( -- n ) (s 2 +) 'f def) 'm @defm 'm ('f) import 'm.f see 'f which words",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{
            "(s 2 +)",
            "f -> f def public (-- n)",
        },
        .stdout_excludes = &.{" s "},
        .stderr = "",
    });
}

test "e2e: stateful module instance acceptance" {
    const expected = "10\n100\n15\n107\n15\n107\n" ++
        "0\n'word\n1\n" ++
        "3\n'a\n2\n3\n" ++
        "65\n" ++
        "'type\n'domain\n'domain\n";
    for ([_][]const u8{ "1", "8" }) |workers| {
        var result = try runWithWorkers(
            &.{ build_options.ecl_exe, "test/acceptance/stateful-module-instances.ecl" },
            workers,
        );
        defer result.deinit();
        try result.expect(.{ .exit_code = 0, .stdout = expected, .stderr = "" });
    }
}

test "e2e: stateful module reload acceptance" {
    var result = try run(&.{ build_options.ecl_exe, "test/acceptance/stateful-module-reload.ecl" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "6\n6\n16\n32\n1600\n'domain\n1600\n160000\n160000\n",
        .stderr = "",
    });
}

test "e2e: module removal acceptance" {
    const module = "[7] (((dup without) within) 'peek def) 'core.c @defm ";
    var by_name = try run(&.{
        build_options.ecl_exe,
        "-e",
        module ++ "'short 'core.c alias 'short unmodule " ++
            "[] (core.c.peek) @attempt 'err at 'kind at io.pp [] (short.peek) @attempt 'err at 'kind at io.pp " ++
            module ++ "core.c.peek io.pp",
    });
    defer by_name.deinit();
    try by_name.expect(.{
        .exit_code = 0,
        .stdout = "'undefined-word\n'undefined-word\n7\n",
        .stderr = "",
    });

    var by_canonical_name = try run(&.{
        build_options.ecl_exe,
        "-e",
        module ++ "'core.c unmodule [] (core.c.peek) @attempt 'err at 'kind at io.pp",
    });
    defer by_canonical_name.deinit();
    try by_canonical_name.expect(.{ .exit_code = 0, .stdout = "'undefined-word\n", .stderr = "" });
}

test "e2e: optional module annotation acceptance" {
    var result = try run(&.{ build_options.ecl_exe, "test/acceptance/optional-module-annotations.ecl" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "(1 +)\n" ++
            "(n -- n) (2 *)\n" ++
            "(: \"Subtract three.\") (3 -)\n" ++
            "(n -- n : \"Divide by four.\") (4 div)\n" ++
            "\"Subtract three.\"\n" ++
            "11\n20\n7\n3\n59\n" ++
            "1\n" ++
            "(: \"The answer.\") ([42] first)\n" ++
            "([42] first)\n" ++
            "'contract\n'domain\n'domain\n" ++
            "(dup)\n(a b)\n",
        .stderr = "",
    });
}

test "e2e: direct load and ECL_PATH acceptance" {
    var direct = try run(&.{ build_options.ecl_exe, "-e", "\"test/acceptance/load-stack.ecl\" load io.pp" });
    defer direct.deinit();
    try direct.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_PATH", "test/acceptance/modules");
    var result = try cli.runOptions(.{
        .argv = &.{ build_options.ecl_exe, "-e", "'stats ('answer) import answer" },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });

    const exe = try absoluteExe();
    defer allocator.free(exe);
    var module_directory = try std.Io.Dir.cwd().openDir(io, "test/acceptance/modules", .{});
    defer module_directory.close(io);
    var empty_environment = std.process.Environ.Map.init(allocator);
    defer empty_environment.deinit();
    var no_implicit_cwd = try cli.runOptions(.{
        .argv = &.{ exe, "-e", "'stats ('answer) import" },
        .cwd = .{ .dir = module_directory },
        .environ_map = &empty_environment,
    });
    defer no_implicit_cwd.deinit();
    try no_implicit_cwd.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{"'kind 'undefined-word"},
    });
}

test "e2e: M5 ragged equality overflow float and char acceptance" {
    var unified_print = try run(&.{ build_options.ecl_exe, "-e", "(1 2 3)" });
    defer unified_print.deinit();
    try unified_print.expect(.{ .exit_code = 0, .stdout = "[1 2 3]\n", .stderr = "" });

    var unified_match = try run(&.{ build_options.ecl_exe, "-e", "(1 2 3) [1 2 3] match?" });
    defer unified_match.deinit();
    try unified_match.expect(.{ .exit_code = 0, .stdout = "1\n", .stderr = "" });

    var ragged = try run(&.{ build_options.ecl_exe, "-e", "[[1 2] [3]] 10 *" });
    defer ragged.deinit();
    try ragged.expect(.{ .exit_code = 0, .stdout = "([10 20] [30])\n", .stderr = "" });

    var equality = try run(&.{ build_options.ecl_exe, "-e", "[1 2] [1 2] = [1 2] [1 2] match?" });
    defer equality.deinit();
    try equality.expect(.{ .exit_code = 0, .stdout = "[1 1] 1\n", .stderr = "" });

    var overflow = try run(&.{ build_options.ecl_exe, "-e", "9223372036854775806 [1 2] +" });
    defer overflow.deinit();
    try overflow.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'overflow", "'index 1" },
    });

    var scalar = try run(&.{ build_options.ecl_exe, "-e", "inf 1 + 9007199254740993 9007199254740992.0 = \\a 1 +" });
    defer scalar.deinit();
    try scalar.expect(.{ .exit_code = 0, .stdout = "inf 0 \\b\n", .stderr = "" });

    var float_domain = try run(&.{ build_options.ecl_exe, "-e", "inf inf -" });
    defer float_domain.deinit();
    try float_domain.expect(.{ .exit_code = 1, .stderr_contains = &.{"'kind 'domain"} });

    var signed_zero = try run(&.{ build_options.ecl_exe, "-e", "0.0 -0.0 = 0.0 -0.0 match?" });
    defer signed_zero.deinit();
    try signed_zero.expect(.{ .exit_code = 0, .stdout = "1 1\n", .stderr = "" });

    var codepoints = try run(&.{ build_options.ecl_exe, "-e", "\"café\" len" });
    defer codepoints.deinit();
    try codepoints.expect(.{ .exit_code = 0, .stdout = "4\n", .stderr = "" });
}

test "e2e: annotated literal module constant and partial effect acceptance" {
    var constant = try run(&.{
        build_options.ecl_exe,
        "-e",
        "[] ((-- value) 40 literal 'k def) 'm @defm m.k 'm.k which",
    });
    defer constant.deinit();
    try constant.expect(.{
        .exit_code = 0,
        .stdout = "m.k -> m.k def public generation 1 (-- value)\n40\n",
        .stderr = "",
    });

    const partial_module = "[] ((a b -- ...) (pop pop 7 8) 'row def) 'm @defm ";
    var partial = try run(&.{ build_options.ecl_exe, "-e", partial_module ++ "1 2 m.row" });
    defer partial.deinit();
    try partial.expect(.{ .exit_code = 0, .stdout = "7 8\n", .stderr = "" });

    var short = try run(&.{ build_options.ecl_exe, "-e", partial_module ++ "1 m.row" });
    defer short.deinit();
    try short.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'contract", "'word 'm.row", "declared 2 inputs", "'seeded 1" },
    });

    var reserved = try run(&.{ build_options.ecl_exe, "-e", "(1) '... def" });
    defer reserved.deinit();
    try reserved.expect(.{ .exit_code = 1, .stderr_contains = &.{ "'kind 'domain", "non-reserved name" } });

    var inert = try run(&.{ build_options.ecl_exe, "-e", "'..." });
    defer inert.deinit();
    try inert.expect(.{ .exit_code = 0, .stdout = "'...\n", .stderr = "" });

    var reflected = try run(&.{ build_options.ecl_exe, "-e", "'result.either see" });
    defer reflected.deinit();
    try reflected.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{"(|result on-ok on-err|"},
        .stderr = "",
    });
}

test "e2e: mask filter acceptance" {
    var result = try run(&.{ build_options.ecl_exe, "-e", "[10 20 30 40] [1 0 1 0] where at" });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "[10 30]\n", .stderr = "" });
}

test "e2e: cmp exactness and string-grade agreement" {
    var result = try run(&.{
        build_options.ecl_exe,
        "-e",
        "9007199254740993 9007199254740992.0 cmp \"apple\" \"apricot\" cmp [\"b\" \"a\"] grade",
    });
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "1 -1 [1 0]\n", .stderr = "" });
}

test "e2e: stdlib acceptance fixtures match their expected output" {
    // Every fixture is a Definition-of-Done assertion: DoD-25a result,
    // DoD-26 csv, DoD-25 json, DoD-27/28/29/30 table.
    const fixtures = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "test/acceptance/result.ecl", .expected = @embedFile("acceptance/result.out") },
        .{ .path = "test/acceptance/csv.ecl", .expected = @embedFile("acceptance/csv.out") },
        .{ .path = "test/acceptance/json.ecl", .expected = @embedFile("acceptance/json.out") },
        .{
            .path = "test/acceptance/table-values.ecl",
            .expected = @embedFile("acceptance/table-values.out"),
        },
        .{
            .path = "test/acceptance/table-invalid.ecl",
            .expected = @embedFile("acceptance/table-invalid.out"),
        },
        .{
            .path = "test/acceptance/table-analysis.ecl",
            .expected = @embedFile("acceptance/table-analysis.out"),
        },
        .{
            .path = "test/acceptance/table-joins.ecl",
            .expected = @embedFile("acceptance/table-joins.out"),
        },
    };
    for (fixtures) |fixture| {
        var result = try run(&.{ build_options.ecl_exe, fixture.path });
        defer result.deinit();
        result.expect(.{
            .exit_code = 0,
            .stdout = fixture.expected,
            .stderr = "",
        }) catch |err| {
            std.log.err("acceptance fixture `{s}` failed", .{fixture.path});
            return err;
        };
    }
}

test "e2e: array words fixture matches display output" {
    var result = try run(&.{ build_options.ecl_exe, "test/acceptance/array-words.ecl" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = @embedFile("acceptance/array-words.out"),
        .stderr = "",
    });
}

test "e2e: M6 combinators parse and contract payloads" {
    var behavior = try run(&.{ build_options.ecl_exe, "test/acceptance/combinators.ecl" });
    defer behavior.deinit();
    try behavior.expect(.{
        .exit_code = 0,
        .stdout = "[1 4 9]\n([1 10]\n [2 10]\n [3 10])\n" ++
            "([10 1]\n [10 2]\n [10 3])\n" ++
            "1\n2\n3\n6\n[1 3 6]\n[1 2 3 3]\n3\n222\n111\n\"three\"\n42\n",
        .stderr = "",
    });

    var contract = try run(&.{ build_options.ecl_exe, "-e", "[10 20] (dup) each" });
    defer contract.deinit();
    try contract.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{
            "'kind 'contract",
            "'word 'each",
            "'expected (a -- b)",
            "'seeded 1",
            "'observed 2",
            "'index 0",
        },
    });

    var fold_contract = try run(&.{ build_options.ecl_exe, "-e", "[1] 0 (pop pop 7 8) fold" });
    defer fold_contract.deinit();
    try fold_contract.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{
            "'kind 'contract",
            "'word 'fold",
            "expected final depth 1 from 2 seeded values, observed 2",
            "'expected (acc a -- acc)",
            "'seeded 2",
            "'observed 2",
            "'index 0",
        },
    });

    var rebound = try run(&.{ build_options.ecl_exe, "test/acceptance/redefined-plus.ecl" });
    defer rebound.deinit();
    try rebound.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });

    var isolated = try run(&.{ build_options.ecl_exe, "-e", "[1 2 3] (dup 'k set k *) each pop k" });
    defer isolated.deinit();
    try isolated.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'undefined-word", "'word 'k" },
    });
}

test "e2e: embedded prelude is independent of cwd and ECL_PATH" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), exe, temporary.dir, "ecl", io, .{});
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var result = try cli.runOptions(.{
        .argv = &.{
            "./ecl",
            "-e",
            "1 2 3 4 4 pack \"42\" parse first",
        },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "[1 2 3 4] 42\n",
        .stderr = "",
    });

    // The command line grants exactly one filesystem root, the startup
    // working directory as `'cwd`; the same empty environment proves the
    // capability words are ordinary vocabulary rather than ECL_PATH-dependent.
    var round_trip = try cli.runOptions(.{
        .argv = &.{
            "./ecl",
            "-e",
            "\"alpha\\nbeta\\n\" 'cwd \"round-trip.txt\" fs.create-text " ++
                "'cwd \"round-trip.txt\" fs.read-text io.pp " ++
                "'cwd \"round-trip.txt\" fs.read-text \"\\n\" split io.pp " ++
                "'cwd \".\" fs.list ('name at \"round-trip.txt\" match?) filter io.pp",
        },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer round_trip.deinit();
    try round_trip.expect(.{
        .exit_code = 0,
        .stdout = "\"alpha\\nbeta\\n\"\n(\"alpha\" \"beta\" \"\")\n" ++
            "({'name \"round-trip.txt\" 'kind 'file})\n",
        .stderr = "",
    });

    var missing_file = try cli.runOptions(.{
        .argv = &.{ "./ecl", "-e", "'cwd \"absent.txt\" fs.read-text" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer missing_file.deinit();
    try missing_file.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{
            "'kind 'io",
            "'word 'fs.read-text",
            "'root 'cwd",
            "'path \"absent.txt\"",
            "'reason 'not-found",
        },
    });

    // Only the granted root exists; a path string never widens it.
    var other_root = try cli.runOptions(.{
        .argv = &.{ "./ecl", "-e", "'home \"absent.txt\" fs.exists?" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer other_root.deinit();
    try other_root.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'domain", "'reason 'unknown-root" },
    });

    var unset = try cli.runOptions(.{
        .argv = &.{ "./ecl", "-e", "\"ECL_M12_ABSENT\" getenv" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer unset.deinit();
    try unset.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "'word 'getenv", "'name \"ECL_M12_ABSENT\"" },
    });

    var defaulted = try cli.runOptions(.{
        .argv = &.{
            "./ecl",
            "-e",
            "[] (\"ECL_M12_ABSENT\" getenv) @attempt \"fallback\" result.or-else io.pp",
        },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer defaulted.deinit();
    try defaulted.expect(.{ .exit_code = 0, .stdout = "\"fallback\"\n", .stderr = "" });

    var present = std.process.Environ.Map.init(allocator);
    defer present.deinit();
    try present.put("ECL_M12_PRESENT", "visible");
    var read = try cli.runOptions(.{
        .argv = &.{ "./ecl", "-e", "\"ECL_M12_PRESENT\" getenv io.pp" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &present,
    });
    defer read.deinit();
    try read.expect(.{ .exit_code = 0, .stdout = "\"visible\"\n", .stderr = "" });
}

test "e2e: every stdlib module resolves with no ECL_PATH and no filesystem" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), exe, temporary.dir, "ecl", io, .{});
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();

    // DoD-32, to the letter.
    var dod32 = try cli.runOptions(.{
        .argv = &.{ "./ecl", "'str ('upper) import \"hello\" upper io.pp" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer dod32.deinit();
    try dod32.expect(.{ .exit_code = 0, .stdout = "\"HELLO\"\n", .stderr = "" });

    // Both spellings of the first reference, for every embedded module, from a
    // copied binary in an empty directory with an empty environment.
    const modules = [_]struct { name: []const u8, imported: []const u8, qualified: []const u8 }{
        .{
            .name = "dict",
            .imported = "'dict ('from-pairs) import [['a 1]] from-pairs io.pp",
            .qualified = "[['a 1]] dict.from-pairs io.pp",
        },
        // The moved envelope words prove the whole point of the consolidation:
        // `result.or-raise` needs no import at all under qualified-miss
        // auto-load, with no `ECL_PATH` and no readable directory.
        .{
            .name = "result",
            .imported = "'result ('or-raise) import [] (2 3 +) @attempt or-raise io.pp",
            .qualified = "[] (2 3 +) @attempt result.or-raise io.pp",
        },
        .{ .name = "str", .imported = "'str ('upper) import \"hi\" upper io.pp", .qualified = "\"hi\" str.upper io.pp" },
        .{ .name = "io", .imported = "'io ('print) import \"hi\" print", .qualified = "\"hi\" io.print" },
        .{ .name = "csv", .imported = "'csv ('parse) import \"a,b\" parse io.pp", .qualified = "\"a,b\" csv.parse io.pp" },
        .{ .name = "json", .imported = "'json ('parse) import \"[1]\" parse io.pp", .qualified = "\"[1]\" json.parse io.pp" },
        .{
            .name = "table",
            .imported = "'table ('valid?) import {\"a\" [1]} valid? io.pp",
            .qualified = "{\"a\" [1]} table.valid? io.pp",
        },
        .{
            .name = "rng",
            // The default key is fixed, so an unseeded draw from a fresh
            // process is as reproducible as any other embedded module's output.
            .imported = "'rng ('int) import 6 int io.pp",
            .qualified = "6 rng.int io.pp",
        },
        .{
            .name = "http",
            .imported = "'http ('get) import 'get doc len 0 > io.pp",
            .qualified = "'http.get doc len 0 > io.pp",
        },
    };
    const used_output = [_][]const u8{
        "{'a 1}\n", "[5]\n", "\"HI\"\n", "hi\n", "((\"a\" \"b\"))\n",
        "[1]\n",    "1\n",   "1\n",      "1\n",
    };
    const qualified_output = [_][]const u8{
        "{'a 1}\n", "[5]\n", "\"HI\"\n", "hi\n", "((\"a\" \"b\"))\n",
        "[1]\n",    "1\n",   "1\n",      "1\n",
    };
    for (modules, used_output, qualified_output) |module, want, qualified_want| {
        var used = try cli.runOptions(.{
            .argv = &.{ "./ecl", module.imported },
            .cwd = .{ .dir = temporary.dir },
            .environ_map = &environment,
        });
        defer used.deinit();
        used.expect(.{ .exit_code = 0, .stdout = want }) catch |err| {
            std.log.err("import from stdlib module `{s}` failed", .{module.name});
            return err;
        };
        var qualified = try cli.runOptions(.{
            .argv = &.{ "./ecl", module.qualified },
            .cwd = .{ .dir = temporary.dir },
            .environ_map = &environment,
        });
        defer qualified.deinit();
        qualified.expect(.{ .exit_code = 0, .stdout = qualified_want }) catch |err| {
            std.log.err("qualified reference to stdlib module `{s}` failed", .{module.name});
            return err;
        };
    }

    // The network word reaches the network, and a refused connection is a
    // value-level error rather than a crash (DoD-31's non-network half).
    var refused = try cli.runOptions(.{
        .argv = &.{ "./ecl", "\"http://127.0.0.1:1/nope\" {} http.get" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer refused.deinit();
    try refused.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "'word 'http.get", "'path \"http://127.0.0.1:1/nope\"" },
    });
}

test "e2e: result module exclusively owns the envelope vocabulary" {
    for ([_][]const u8{ "ok?", "or-raise", "or-else" }) |old| {
        var result = try run(&.{ build_options.ecl_exe, "-e", old });
        defer result.deinit();
        try result.expect(.{ .exit_code = 1, .stderr_contains = &.{ "'kind 'undefined-word", old } });
    }
    for ([_][]const u8{ "result.map-error", "result.case" }) |old| {
        var result = try run(&.{ build_options.ecl_exe, "-e", old });
        defer result.deinit();
        try result.expect(.{ .exit_code = 1, .stderr_contains = &.{ "'kind 'undefined-word", old } });
    }

    var unchanged = try run(&.{
        build_options.ecl_exe,
        "-e",
        "[] (\"original\" fail) @attempt dup (result.or-raise) partial [] swap @attempt 'err at swap 'err at match?",
    });
    defer unchanged.deinit();
    try unchanged.expect(.{ .exit_code = 0, .stdout = "1\n", .stderr = "" });
}

test "e2e: stdin is data in -e mode and refuses to be read as program source" {
    var piped = try runWithInput(
        &.{ build_options.ecl_exe, "-e", "io.stdin \"\\n\" split io.pp" },
        "one\ntwo\n",
    );
    defer piped.deinit();
    try piped.expect(.{
        .exit_code = 0,
        .stdout = "(\"one\" \"two\" \"\")\n",
        .stderr = "",
    });

    var twice = try runWithInput(&.{ build_options.ecl_exe, "-e", "io.stdin pop io.stdin" }, "data");
    defer twice.deinit();
    try twice.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "standard input has already been read" },
    });

    var as_source = try runWithInput(&.{build_options.ecl_exe}, "io.stdin\n");
    defer as_source.deinit();
    try as_source.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "stdin is the program source" },
    });
}

test "e2e: entropy is the one draw that differs between processes" {
    // Every other random word is a pure function of its state, so only a real
    // process can show that `entropy` reaches the host and returns something
    // new each time. Two 128-bit keys colliding is not a flake worth guarding.
    var first = try run(&.{ build_options.ecl_exe, "-e", "rand.entropy io.pp" });
    defer first.deinit();
    try first.expect(.{ .exit_code = 0, .stderr = "" });
    var second = try run(&.{ build_options.ecl_exe, "-e", "rand.entropy io.pp" });
    defer second.deinit();
    try second.expect(.{ .exit_code = 0, .stderr = "" });
    try std.testing.expect(!std.mem.eql(u8, first.stdout, second.stdout));

    // A drawn key is a usable key: seeding with it keeps the module working,
    // and the same key twice reproduces the same draw.
    var seeded = try run(&.{
        build_options.ecl_exe,
        "-e",
        "'rng ('seed 'ints) import " ++
            "rand.entropy dup 'k set seed 100 6 ints 'a set k seed 100 6 ints a match? io.pp",
    });
    defer seeded.deinit();
    try seeded.expect(.{ .exit_code = 0, .stdout = "1\n", .stderr = "" });
}

test "e2e: the old unit-constructor spellings are gone and the boundary error guides" {
    // Hard renames, no aliases: the pre-@ spellings resolve to nothing.
    for ([_][]const u8{
        "attempt",
        "spawn",
        "par-each",
        "module",
        "attempt-with",
        "spawn-with",
        "par-each-with",
        "module-with",
        "@attempt-with",
        "@spawn-with",
        "@each-with",
        "@defm-with",
        "seed",
        "unseed",
    }) |old| {
        var result = try run(&.{ build_options.ecl_exe, "-e", old });
        defer result.deinit();
        try result.expect(.{ .exit_code = 1, .stderr_contains = &.{ "'kind 'undefined-word", old } });
    }
    // The trap the convention exists to make visible: the caller's value is
    // on screen and out of reach, so the error names the isolation.
    var isolated = try run(&.{ build_options.ecl_exe, "-e", "3 [1] (+) @attempt io.pp" });
    defer isolated.deinit();
    try isolated.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{ "'isolation @attempt", "constructor's values operand", "values (q) @attempt" },
    });
    var child = try run(&.{ build_options.ecl_exe, "-e", "3 [1 2] [] (+ +) @each io.pp" });
    defer child.deinit();
    try child.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'isolation @each", "constructor's values operand", "list values (q) @each" },
    });
    // And the seeding composition that fixes it.
    var seeded = try run(&.{ build_options.ecl_exe, "-e", "[3] (1 +) @attempt io.pp" });
    defer seeded.deinit();
    try seeded.expect(.{ .exit_code = 0, .stdout = "{'ok [4]}\n", .stderr = "" });

    var seeded_each = try run(&.{
        build_options.ecl_exe,
        "-e",
        "[1 2] [10] (|x a| x a +) @each io.pp",
    });
    defer seeded_each.deinit();
    try seeded_each.expect(.{ .exit_code = 0, .stdout = "[11 12]\n", .stderr = "" });

    var name_first = try run(&.{ build_options.ecl_exe, "-e", "'wrong [] ((1) 'x def) @defm" });
    defer name_first.deinit();
    try name_first.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'type", "@defm expected a symbol name" },
    });

    // Anonymous construction names nothing, so its isolation advice names the
    // unseeded spelling rather than a registration.
    var anonymous_isolation = try run(&.{ build_options.ecl_exe, "-e", "3 [1] (+) @module" });
    defer anonymous_isolation.deinit();
    try anonymous_isolation.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'isolation @module", "@module" },
    });

    // The value the external binary shows for a module image, and the two
    // words that name one.
    var anonymous_value = try run(&.{ build_options.ecl_exe, "-e", "[] (1 'x set) @module" });
    defer anonymous_value.deinit();
    try anonymous_value.expect(.{ .exit_code = 0, .stdout = "<module>\n", .stderr = "" });

    var registered_twice = try run(&.{
        build_options.ecl_exe,
        "-e",
        "[] (0 ((1 + dup without) within) 'bump def) @module dup 'l register 'r register " ++
            "l.bump l.bump r.bump",
    });
    defer registered_twice.deinit();
    try registered_twice.expect(.{ .exit_code = 0, .stdout = "1 2 1\n", .stderr = "" });
}

test "e2e: escaped quotation authority acceptance" {
    // Confirmed to discriminate against a pre-change reference binary built in a
    // worktree at f2c5cf5: there this fixture printed 'contract / 'other.run and
    // left other's stack at 1000, because the escaped quotation's `within` wrote
    // the caller's slot. Now it is 'domain / 'within with other's stack at 999.
    var result = try run(&.{
        build_options.ecl_exe,
        "test/acceptance/escaped-quotation-authority.ecl",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        // A foreign private still reaches its own privates (99); `within`
        // through it is 'domain, spelled by its unqualified local name; and
        // neither durable stack moved (10, 999).
        .stdout = "99\n'domain\n'within\n10\n999\n",
        .stderr = "",
    });
}
