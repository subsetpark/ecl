const std = @import("std");
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
        "'sample use 41 sample.increment 'sample.increment which 'sample.increment see",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "sample.increment -> sample.increment native public generation 1 " ++
            "(n -- result) requires call, build-values, reschedule\n" ++
            "<native:sample.increment> (n -- result : \"Increment an integer.\") " ++
            "requires call, build-values, reschedule 'sample.increment def\n42\n",
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
        " cccccccccccccccccccccccccccccccccccccccc)\n" ++
        "{'kind 'user}\n" ++
        "raise\n";

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

    var stdin_result = try runWithInput(&.{ build_options.ecl_exe, "fmt", "-" }, input);
    defer stdin_result.deinit();
    try stdin_result.expect(.{ .exit_code = 0, .stdout = expected, .stderr = "" });

    var invalid = try run(&.{ build_options.ecl_exe, "fmt" });
    defer invalid.deinit();
    try invalid.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr = "ecl fmt: expected exactly one FILE or -\n",
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

test "e2e: extracted body acceptance" {
    var extracted = try run(&.{ build_options.ecl_exe, "test/acceptance/body-extraction.ecl" });
    defer extracted.deinit();
    try extracted.expect(.{ .exit_code = 1, .stderr_contains = &.{"'word 's"} });
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
    var missing = try run(&.{ build_options.ecl_exe, "-e", "((dup +) 'fine def) 'm @module 2 m.fine" });
    defer missing.deinit();
    try missing.expect(.{ .exit_code = 0, .stdout = "4\n", .stderr = "" });

    var lying = try run(&.{ build_options.ecl_exe, "-e", "((dup +) ( a -- b c ) 'lies def) 'm @module 1 m.lies" });
    defer lying.deinit();
    try lying.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'contract", "'word 'm.lies" },
    });

    var visible = try run(&.{ build_options.ecl_exe, "-e", "((dup +) ( a -- b ) 'dbl def) 'm @module 'm.dbl see" });
    defer visible.deinit();
    try visible.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{"(a -- b)"},
        .stderr = "",
    });
}

test "e2e: use shadow notice acceptance" {
    var result = try run(&.{
        build_options.ecl_exe,
        "-e",
        "1 'mean set 2 'count set (3 'mean set 4 'count set) 'stats @module 'stats use mean count",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "1 2\n",
        .stderr = "session `count` shadows `stats.count`\n" ++
            "session `mean` shadows `stats.mean`\n",
    });
}

test "e2e: reflection acceptance" {
    var result = try run(&.{
        build_options.ecl_exe,
        "-e",
        "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @module 'm use 'm.f see 'f which words",
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{
            "(s 2 +) (-- n) 'm.f def",
            "f -> m.f def public generation 1 (-- n)",
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
    const module = "[7] (((dup without) within) 'peek def) with 'core.c @module ";
    var by_name = try run(&.{
        build_options.ecl_exe,
        "-e",
        module ++ "'short 'core.c alias 'short unmodule " ++
            "(core.c.peek) @attempt 'err at 'kind at io.pp (short.peek) @attempt 'err at 'kind at io.pp " ++
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
        module ++ "'core.c unmodule (core.c.peek) @attempt 'err at 'kind at io.pp",
    });
    defer by_canonical_name.deinit();
    try by_canonical_name.expect(.{ .exit_code = 0, .stdout = "'undefined-word\n", .stderr = "" });
}

test "e2e: optional module annotation acceptance" {
    var result = try run(&.{ build_options.ecl_exe, "test/acceptance/optional-module-annotations.ecl" });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "(1 +) 'forms.bare def\n" ++
            "(2 *) (n -- n) 'forms.effected def\n" ++
            "(3 -) (: \"Subtract three.\") 'forms.documented def\n" ++
            "(4 div) (n -- n : \"Divide by four.\") 'forms.complete def\n" ++
            "\"Subtract three.\"\n" ++
            "11\n20\n7\n3\n59\n" ++
            "1\n" ++
            "([42] first) 'answer def\n" ++
            "([42] first) 'spelled def\n" ++
            "'contract\n'domain\n'domain\n" ++
            "(a b)\n(dup)\n",
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
        .argv = &.{ build_options.ecl_exe, "-e", "'stats use answer" },
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
        .argv = &.{ exe, "-e", "'stats use" },
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
        "(40 literal (-- value) 'k def) 'm @module m.k 'm.k body 'm.k which",
    });
    defer constant.deinit();
    try constant.expect(.{
        .exit_code = 0,
        .stdout = "m.k -> m.k def public generation 1 (-- value)\n40 ([40] first)\n",
        .stderr = "",
    });

    const partial_module = "((pop pop 7 8) (a b -- ...) 'row def) 'm @module ";
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

    var reflected = try run(&.{ build_options.ecl_exe, "-e", "'result use 'result.either see" });
    defer reflected.deinit();
    try reflected.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{ "(result on-ok on-err -- ...", "'result.either def" },
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
            "'wrap body 'pair body 'sort body 'pack body 1 2 3 4 4 pack \"42\" parse first",
        },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer result.deinit();
    try result.expect(.{
        .exit_code = 0,
        .stdout = "(() cons) (() cons cons) (dup grade at) (() swap (cons) times) [1 2 3 4] 42\n",
        .stderr = "",
    });

    // The host scripting words landed with M12; the same empty environment
    // proves they are ordinary vocabulary rather than ECL_PATH-dependent.
    var round_trip = try cli.runOptions(.{
        .argv = &.{
            "./ecl",
            "-e",
            "\"alpha\\nbeta\\n\" \"round-trip.txt\" io.spit " ++
                "\"round-trip.txt\" io.slurp io.pp \"round-trip.txt\" io.lines io.pp",
        },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer round_trip.deinit();
    try round_trip.expect(.{
        .exit_code = 0,
        .stdout = "\"alpha\\nbeta\\n\"\n(\"alpha\" \"beta\" \"\")\n",
        .stderr = "",
    });

    var missing_file = try cli.runOptions(.{
        .argv = &.{ "./ecl", "-e", "\"absent.txt\" io.slurp" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer missing_file.deinit();
    try missing_file.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'io", "'word 'io.slurp", "'path \"absent.txt\"" },
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
            "(\"ECL_M12_ABSENT\" getenv) @attempt \"fallback\" result.or-else io.pp",
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
        .argv = &.{ "./ecl", "'str use \"hello\" str.upper io.pp" },
        .cwd = .{ .dir = temporary.dir },
        .environ_map = &environment,
    });
    defer dod32.deinit();
    try dod32.expect(.{ .exit_code = 0, .stdout = "\"HELLO\"\n", .stderr = "" });

    // Both spellings of the first reference, for every embedded module, from a
    // copied binary in an empty directory with an empty environment.
    const modules = [_]struct { name: []const u8, use: []const u8, qualified: []const u8 }{
        // The moved envelope words prove the whole point of the consolidation:
        // `result.or-raise` needs no `use` at all under qualified-miss
        // auto-load, with no `ECL_PATH` and no readable directory.
        .{
            .name = "result",
            .use = "'result use (2 3 +) @attempt or-raise io.pp",
            .qualified = "(2 3 +) @attempt result.or-raise io.pp",
        },
        .{ .name = "str", .use = "'str use \"hi\" upper io.pp", .qualified = "\"hi\" str.upper io.pp" },
        .{ .name = "io", .use = "'io use \"hi\" print", .qualified = "\"hi\" io.print" },
        .{ .name = "csv", .use = "'csv use \"a,b\" parse io.pp", .qualified = "\"a,b\" csv.parse io.pp" },
        .{ .name = "json", .use = "'json use \"[1]\" parse io.pp", .qualified = "\"[1]\" json.parse io.pp" },
        .{
            .name = "table",
            .use = "'table use {\"a\" [1]} valid? io.pp",
            .qualified = "{\"a\" [1]} table.valid? io.pp",
        },
        .{
            .name = "rng",
            // The default key is fixed, so an unseeded draw from a fresh
            // process is as reproducible as any other embedded module's output.
            .use = "'rng use 6 int io.pp",
            .qualified = "6 rng.int io.pp",
        },
        .{
            .name = "http",
            .use = "'http use 'http.get doc len 0 > io.pp",
            .qualified = "'http.get doc len 0 > io.pp",
        },
    };
    const used_output = [_][]const u8{
        "[5]\n", "\"HI\"\n", "hi\n", "((\"a\" \"b\"))\n",
        "[1]\n", "1\n",      "1\n",  "1\n",
    };
    const qualified_output = [_][]const u8{
        "[5]\n", "\"HI\"\n", "hi\n", "((\"a\" \"b\"))\n",
        "[1]\n", "1\n",      "1\n",  "1\n",
    };
    for (modules, used_output, qualified_output) |module, want, qualified_want| {
        var used = try cli.runOptions(.{
            .argv = &.{ "./ecl", module.use },
            .cwd = .{ .dir = temporary.dir },
            .environ_map = &environment,
        });
        defer used.deinit();
        used.expect(.{ .exit_code = 0, .stdout = want }) catch |err| {
            std.log.err("`use` of stdlib module `{s}` failed", .{module.name});
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
        "(\"original\" fail) @attempt dup (result.or-raise) partial @attempt 'err at swap 'err at match?",
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
    var first = try run(&.{ build_options.ecl_exe, "-e", "entropy io.pp" });
    defer first.deinit();
    try first.expect(.{ .exit_code = 0, .stderr = "" });
    var second = try run(&.{ build_options.ecl_exe, "-e", "entropy io.pp" });
    defer second.deinit();
    try second.expect(.{ .exit_code = 0, .stderr = "" });
    try std.testing.expect(!std.mem.eql(u8, first.stdout, second.stdout));

    // A drawn key is a usable key: seeding with it keeps the module working,
    // and the same key twice reproduces the same draw.
    var seeded = try run(&.{
        build_options.ecl_exe,
        "-e",
        "'rng use entropy dup 'k set seed 100 6 ints 'a set k seed 100 6 ints a match? io.pp",
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
        "@module-with",
    }) |old| {
        var result = try run(&.{ build_options.ecl_exe, "-e", old });
        defer result.deinit();
        try result.expect(.{ .exit_code = 1, .stderr_contains = &.{ "'kind 'undefined-word", old } });
    }
    // The trap the convention exists to make visible: the caller's value is
    // on screen and out of reach, so the error names the isolation.
    var isolated = try run(&.{ build_options.ecl_exe, "-e", "3 (1 +) @attempt io.pp" });
    defer isolated.deinit();
    try isolated.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{ "'isolation @attempt", "with @attempt", "partial" },
    });
    var child = try run(&.{ build_options.ecl_exe, "-e", "3 [1 2] (+ +) @each io.pp" });
    defer child.deinit();
    try child.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'isolation @each", "only its element" },
    });
    // And the seeding composition that fixes it.
    var seeded = try run(&.{ build_options.ecl_exe, "-e", "[3] (1 +) with @attempt io.pp" });
    defer seeded.deinit();
    try seeded.expect(.{ .exit_code = 0, .stdout = "{'ok [4]}\n", .stderr = "" });

    var seeded_each = try run(&.{
        build_options.ecl_exe,
        "-e",
        "[1 2] [10] (|x a| x a +) with @each io.pp",
    });
    defer seeded_each.deinit();
    try seeded_each.expect(.{ .exit_code = 0, .stdout = "[11 12]\n", .stderr = "" });

    var name_first = try run(&.{ build_options.ecl_exe, "-e", "'wrong ((1) 'x def) @module" });
    defer name_first.deinit();
    try name_first.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'type", "@module expected a symbol name" },
    });
}
