const std = @import("std");
const build_options = @import("native_runtime_options");
const cli = @import("cli_test_support.zig");

const allocator = std.testing.allocator;

fn run(source: []const u8, workers: []const u8, diagnostics: bool) !cli.Result {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_PATH", build_options.fixture_dir);
    try environment.put("ECL_WORKERS", workers);
    if (diagnostics) try environment.put("ECL_NATIVE_DIAGNOSTICS", "1");
    return cli.runOptions(.{
        .argv = &.{ build_options.ecl_exe, "-e", source },
        .environ_map = &environment,
    });
}

fn runPath(source: []const u8, path: []const u8) !cli.Result {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("ECL_PATH", path);
    return cli.runOptions(.{
        .argv = &.{ build_options.ecl_exe, "-e", source },
        .environ_map = &environment,
    });
}

test "native runtime: loaded artifacts behave identically at one and eight workers" {
    const source = "40 sample.increment sample.split sample.singleton " ++
        "sample.cooperative 'sample.increment which";
    var one = try run(source, "1", false);
    defer one.deinit();
    var eight = try run(source, "8", false);
    defer eight.deinit();
    try one.expect(.{
        .exit_code = 0,
        .stdout_contains = &.{
            "native public generation 1",
            "requires call, build-values, reschedule",
            "41 [41] 42",
        },
        .stderr = "",
    });
    try std.testing.expectEqual(one.term, eight.term);
    try std.testing.expectEqualStrings(one.stdout, eight.stdout);
    try std.testing.expectEqualStrings(one.stderr, eight.stderr);
}

test "native runtime: spawned units inherit native loading context" {
    const source = "[] (41 sample.increment) @spawn await";
    var one = try run(source, "1", false);
    defer one.deinit();
    var eight = try run(source, "8", false);
    defer eight.deinit();
    try one.expect(.{ .exit_code = 0, .stdout = "{'ok [42]}\n", .stderr = "" });
    try std.testing.expectEqual(one.term, eight.term);
    try std.testing.expectEqualStrings(one.stdout, eight.stdout);
    try std.testing.expectEqualStrings(one.stderr, eight.stderr);
}

test "native runtime: aggregates larger than one quantum complete" {
    var result = try run(
        "100000 sample.large-list len 70000 sample.large-dict dict.keys len",
        "1",
        false,
    );
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "100000 70000\n", .stderr = "" });
}

test "native runtime: inadmissible values and duplicate keys are language errors" {
    var task_input = try run("[] () @spawn sample.forward", "1", false);
    defer task_input.deinit();
    try task_input.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "'kind 'type", "native words cannot observe task capabilities" },
    });

    // A module image is a runtime capability on the same terms as a task: the
    // ABI has no representation for it, in scalar or in view position.
    var module_input = try run("[] (1) @module sample.forward", "1", false);
    defer module_input.deinit();
    try module_input.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "'kind 'type", "native words cannot observe module capabilities" },
    });

    var module_element = try run("([] (1) @module) sample.sum-list", "1", false);
    defer module_element.deinit();
    try module_element.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{"'kind "},
    });

    var duplicate = try run("sample.duplicate-dict", "1", false);
    defer duplicate.deinit();
    try duplicate.expect(.{
        .exit_code = 1,
        .stdout = "",
        .stderr_contains = &.{ "'kind 'domain", "duplicate dictionary key" },
    });
}

test "native runtime: execute uses ordinary native dispatch" {
    var result = try run("7 'sample 'increment qualify execute", "1", false);
    defer result.deinit();
    try result.expect(.{ .exit_code = 0, .stdout = "8\n", .stderr = "" });
}

test "native runtime: SDK char scalars enforce Unicode scalar bounds" {
    var upper = try run("1114111 sample.make-char type", "1", false);
    defer upper.deinit();
    try upper.expect(.{ .exit_code = 0, .stdout = "'char\n", .stderr = "" });

    const invalid_codepoints = [_]u32{ 0xd800, 0x110000, 0x200000, std.math.maxInt(u32) };
    for (invalid_codepoints) |codepoint| {
        const source = try std.fmt.allocPrint(
            allocator,
            "{d} sample.make-char",
            .{codepoint},
        );
        defer allocator.free(source);
        var invalid = try run(source, "1", false);
        defer invalid.deinit();
        try invalid.expect(.{
            .exit_code = 1,
            .stdout = "",
            .stderr_contains = &.{
                "'kind 'domain",
                "native SDK capability argument was rejected",
            },
        });
    }
}

test "native runtime: source precedence and path-root order are observable" {
    const fixture_path = try std.fs.path.join(
        allocator,
        &.{ build_options.fixture_dir, "sample.eclmod" },
    );
    defer allocator.free(fixture_path);

    var same_root = std.testing.tmpDir(.{});
    defer same_root.cleanup();
    try same_root.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.ecl",
        .data = "[] (100 'increment set) 'sample @defm",
    });
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        fixture_path,
        same_root.dir,
        "sample.eclmod",
        std.testing.io,
        .{},
    );
    const same_root_path = try same_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        allocator,
    );
    defer allocator.free(same_root_path);
    var source_first = try runPath("sample.increment", same_root_path);
    defer source_first.deinit();
    try source_first.expect(.{ .exit_code = 0, .stdout = "100\n", .stderr = "" });

    var native_root = std.testing.tmpDir(.{});
    defer native_root.cleanup();
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        fixture_path,
        native_root.dir,
        "sample.eclmod",
        std.testing.io,
        .{},
    );
    var source_root = std.testing.tmpDir(.{});
    defer source_root.cleanup();
    try source_root.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.ecl",
        .data = "[] (100 'increment set) 'sample @defm",
    });
    const native_root_path = try native_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        allocator,
    );
    defer allocator.free(native_root_path);
    const source_root_path = try source_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        allocator,
    );
    defer allocator.free(source_root_path);
    const ordered_path = try std.fmt.allocPrint(
        allocator,
        "{s}{c}{s}",
        .{ native_root_path, std.fs.path.delimiter, source_root_path },
    );
    defer allocator.free(ordered_path);
    var native_first = try runPath("41 sample.increment", ordered_path);
    defer native_first.deinit();
    try native_first.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });
}

test "native runtime: malformed artifacts are authoritative" {
    const cases = [_]struct { defect: []const u8, message: []const u8 }{
        .{ .defect = "wrong-name", .message = "ModuleNameMismatch" },
        .{ .defect = "abi-version", .message = "AbiVersionMismatch" },
        .{ .defect = "descriptor-size", .message = "RecordSizeMismatch" },
        .{ .defect = "duplicate-word", .message = "DuplicateDefinition" },
        .{ .defect = "missing-doc", .message = "EmptyDocumentation" },
        .{ .defect = "entry-failure", .message = "native module entry failed" },
        .{ .defect = "entry-size", .message = "invalid result record size" },
        .{ .defect = "invalid-effect", .message = "InvalidEffect" },
        .{ .defect = "unsupported-capability", .message = "UnsupportedCapabilityId" },
        .{ .defect = "invalid-continuation", .message = "InvalidContinuation" },
        .{ .defect = "unknown-entry-status", .message = "native module entry failed" },
        .{ .defect = "stride-overread", .message = "RecordSizeMismatch" },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(
            allocator,
            &.{ build_options.fixture_dir, case.defect },
        );
        defer allocator.free(path);
        var environment = std.process.Environ.Map.init(allocator);
        defer environment.deinit();
        const search = try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{ path, std.fs.path.delimiter, build_options.fixture_dir },
        );
        defer allocator.free(search);
        try environment.put("ECL_PATH", search);
        var result = try cli.runOptions(.{
            .argv = &.{ build_options.ecl_exe, "-e", "'sample ('increment) import" },
            .environ_map = &environment,
        });
        defer result.deinit();
        try result.expect(.{
            .exit_code = 1,
            .stdout = "",
            .stderr_contains = &.{ "'kind 'io", case.message, path },
        });
    }
}

test "native runtime: module-written wire values cannot trap or partially commit" {
    const failures = [_]struct { defect: []const u8, message: []const u8 }{
        .{ .defect = "unknown-result", .message = "unknown result tag" },
        .{ .defect = "result-size", .message = "invalid result record size" },
        .{ .defect = "unknown-failure-kind", .message = "valid failure payload" },
        .{ .defect = "unknown-scalar-kind", .message = "valid failure payload" },
        .{ .defect = "scalar-size", .message = "valid failure payload" },
        .{ .defect = "oversized-scalar", .message = "valid failure payload" },
        .{ .defect = "invalid-utf8-scalar", .message = "valid failure payload" },
        .{ .defect = "undeclared-yield", .message = "reschedule capability unavailable" },
        .{ .defect = "consume-without-state", .message = "consume rejected without continuation" },
    };
    for (failures) |case| {
        const path = try std.fs.path.join(allocator, &.{ build_options.fixture_dir, case.defect });
        defer allocator.free(path);
        var result = try runPath("sample.word", path);
        defer result.deinit();
        try result.expect(.{
            .exit_code = 1,
            .stdout = "",
            .stderr_contains = &.{case.message},
        });
    }

    const partial_path = try std.fs.path.join(
        allocator,
        &.{ build_options.fixture_dir, "partial-complete" },
    );
    defer allocator.free(partial_path);
    var partial = try runPath("sample.word", partial_path);
    defer partial.deinit();
    try partial.expect(.{ .exit_code = 0, .stdout = "1 1\n", .stderr = "" });
}

test "native runtime: diagnostics are opt-in and never change results" {
    var ordinary = try run("sample.noncooperative", "1", false);
    defer ordinary.deinit();
    var observed = try run("sample.noncooperative", "1", true);
    defer observed.deinit();
    try ordinary.expect(.{ .exit_code = 0, .stdout = "42\n", .stderr = "" });
    try std.testing.expectEqual(ordinary.term, observed.term);
    try std.testing.expectEqualStrings(ordinary.stdout, observed.stdout);
    try observed.expect(.{
        .exit_code = 0,
        .stdout = "42\n",
        .stderr_contains = &.{"native module `sample` returned after an over-quantum slice"},
    });
}
