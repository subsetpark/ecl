const std = @import("std");
const build_options = @import("build_options");

const allocator = std.testing.allocator;
const io = std.testing.io;

fn run(arguments: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{ .argv = arguments });
}

fn absoluteExe() ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(
        io,
        build_options.ecl_exe,
        allocator,
    );
}

fn expectExit(expected: u8, term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |actual| try std.testing.expectEqual(expected, actual),
        .signal, .stopped, .unknown => return error.UnexpectedTermination,
    }
}

test "soul test executes the installed artifact" {
    const result = try run(&.{ build_options.ecl_exe, "3 4 +" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(0, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runtime errors are dicts on stderr" {
    const result = try run(&.{ build_options.ecl_exe, "1 0 /" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(1, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'kind 'domain") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'word '/") != null);

    const missing = try run(&.{ build_options.ecl_exe, "missing" });
    defer allocator.free(missing.stdout);
    defer allocator.free(missing.stderr);
    try expectExit(1, missing.term);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "'kind 'undefined-word") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "'word 'missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "'name 'missing") != null);

    const raised = try run(&.{ build_options.ecl_exe, "{'kind 'custom} raise" });
    defer allocator.free(raised.stdout);
    defer allocator.free(raised.stderr);
    try expectExit(1, raised.term);
    try std.testing.expect(std.mem.indexOf(u8, raised.stderr, "'kind 'custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, raised.stderr, "'msg \"raised 'custom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raised.stderr, "'word 'raise") != null);
    try std.testing.expect(std.mem.indexOf(u8, raised.stderr, "'trace ['raise]") != null);
    try std.testing.expect(std.mem.indexOf(u8, raised.stderr, "'source \"<command>\"") != null);
}

test "piped stdin is exactly one unit" {
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.ecl_exe, "-" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, "5 6 +");
    child.stdin.?.close(io);
    child.stdin = null;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const stdout = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr);
    const term = try child.wait(io);

    try expectExit(0, term);
    try std.testing.expectEqualStrings("11\n", stdout);
    try std.testing.expectEqualStrings("", stderr);
}

test "scripts print only explicitly" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exe = try absoluteExe();
    defer allocator.free(exe);
    try temporary.dir.writeFile(io, .{ .sub_path = "quiet.ecl", .data = "3 4 +" });
    const quiet = try std.process.run(allocator, io, .{
        .argv = &.{ exe, "quiet.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer allocator.free(quiet.stdout);
    defer allocator.free(quiet.stderr);
    try expectExit(0, quiet.term);
    try std.testing.expectEqualStrings("", quiet.stdout);

    try temporary.dir.writeFile(io, .{
        .sub_path = "loud.ecl",
        .data = "\"hi\" prin 'visible pp",
    });
    const loud = try std.process.run(allocator, io, .{
        .argv = &.{ exe, "loud.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer allocator.free(loud.stdout);
    defer allocator.free(loud.stderr);
    try expectExit(0, loud.term);
    try std.testing.expectEqualStrings("hi'visible\n", loud.stdout);
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
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ exe, "invalid.ecl" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(1, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'kind 'parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "not valid UTF-8") != null);
}

test "missing scripts and version have stable CLI behavior" {
    const missing = try run(&.{ build_options.ecl_exe, "definitely-missing.ecl" });
    defer allocator.free(missing.stdout);
    defer allocator.free(missing.stderr);
    try expectExit(1, missing.term);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "'kind 'io") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "does not exist") != null);

    const version = try run(&.{ build_options.ecl_exe, "-V" });
    defer allocator.free(version.stdout);
    defer allocator.free(version.stderr);
    try expectExit(0, version.term);
    try std.testing.expectEqualStrings("ecl 0.1.0\n", version.stdout);

    const arguments = try run(&.{ build_options.ecl_exe, "-e", "args", "alpha", "beta" });
    defer allocator.free(arguments.stdout);
    defer allocator.free(arguments.stderr);
    try expectExit(0, arguments.term);
    try std.testing.expectEqualStrings("(\"alpha\" \"beta\")\n", arguments.stdout);

    const requested_exit = try run(&.{ build_options.ecl_exe, "7 exit" });
    defer allocator.free(requested_exit.stdout);
    defer allocator.free(requested_exit.stderr);
    try expectExit(7, requested_exit.term);
    try std.testing.expectEqualStrings("", requested_exit.stdout);
}
