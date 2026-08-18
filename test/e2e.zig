const std = @import("std");
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

test "e2e: cancellation timeout and par-each agree at one and eight workers" {
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
            &.{ build_options.ecl_exe, "test/acceptance/par-each.ecl" },
            workers,
        );
        defer par_each.deinit();
        try par_each.expect(.{
            .exit_code = 0,
            .stdout = "[1 4 9]\n'domain\n",
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
        .data = "\"hi\" prin 'visible pp",
    });
    var loud = try cli.runOptions(.{
        .argv = &.{ exe, "loud.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer loud.deinit();
    try loud.expect(.{ .exit_code = 0, .stdout = "hi'visible\n", .stderr = "" });
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
    var missing = try run(&.{ build_options.ecl_exe, "-e", "'m ((dup +) 'fine def) module 2 m.fine" });
    defer missing.deinit();
    try missing.expect(.{ .exit_code = 0, .stdout = "4\n", .stderr = "" });

    var lying = try run(&.{ build_options.ecl_exe, "-e", "'m ((dup +) ( a -- b c ) 'lies def) module 1 m.lies" });
    defer lying.deinit();
    try lying.expect(.{
        .exit_code = 1,
        .stderr_contains = &.{ "'kind 'contract", "'word 'm.lies" },
    });

    var visible = try run(&.{ build_options.ecl_exe, "-e", "'m ((dup +) ( a -- b ) 'dbl def) module 'm.dbl see" });
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
        "1 'mean set 2 'count set 'stats (3 'mean set 4 'count set) module 'stats use mean count",
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
        "'m (40 's setp (s 2 +) ( -- n ) 'f def) module 'm use 'm.f see 'f which words",
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
    const module = "[7] 'core.c (((dup without) within) 'peek def) module-with ";
    var by_name = try run(&.{
        build_options.ecl_exe,
        "-e",
        module ++ "'short 'core.c alias 'short unmodule " ++
            "(core.c.peek) attempt 'err at 'kind at pp (short.peek) attempt 'err at 'kind at pp " ++
            module ++ "core.c.peek pp",
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
        module ++ "'core.c unmodule (core.c.peek) attempt 'err at 'kind at pp",
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
    var direct = try run(&.{ build_options.ecl_exe, "-e", "\"test/acceptance/load-stack.ecl\" load pp" });
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
    var ragged = try run(&.{ build_options.ecl_exe, "-e", "[[1 2] [3]] 10 *" });
    defer ragged.deinit();
    try ragged.expect(.{ .exit_code = 0, .stdout = "([10 20] [30])\n", .stderr = "" });

    var equality = try run(&.{ build_options.ecl_exe, "-e", "[1 2] [1 2] = [1 2] [1 2] match" });
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

    for (&[_][]const u8{ "slurp", "spit", "getenv", "lines" }) |word| {
        var missing = try cli.runOptions(.{
            .argv = &.{ "./ecl", "-e", word },
            .cwd = .{ .dir = temporary.dir },
            .environ_map = &environment,
        });
        defer missing.deinit();
        try missing.expect(.{
            .exit_code = 1,
            .stderr_contains = &.{ "'kind 'undefined-word", word },
        });
    }
}
