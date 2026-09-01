//! Public Session coverage for the process-port capability.
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

fn expectStack(program: []const u8, policy: ?process.ProcessPolicy, expected: []const u8) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(
        heap.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .process_policy = policy,
        },
        .{ .worker_pool = 2 },
    );
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

fn expectError(program: []const u8, policy: ?process.ProcessPolicy, expected: support.ErrorCase) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(
        heap.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .process_policy = policy,
        },
        .cooperative,
    );
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<process-test>", program)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

test "process: authority is explicit and policy validation precedes spawn" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, fixture.process_exe, allocator);
    defer allocator.free(fixture_path);
    const program = try source(
        "'proc ('spawn) import {{'executable \"{s}\" 'args (\"exit\" \"0\")}} spawn",
        .{fixture_path},
    );
    defer allocator.free(program);
    try expectError(program, null, .{
        .name = "missing process authority",
        .source = program,
        .kind = "domain",
        .word = "proc.spawn",
        .message_contains = "unavailable",
    });
    try expectError(program, .{ .executables = .{ .exact = &.{"/definitely/not/the/fixture"} } }, .{
        .name = "denied executable",
        .source = program,
        .kind = "domain",
        .word = "proc.spawn",
        .message_contains = "denied",
    });
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
        .{ .executables = .{ .exact = &.{fixture_path} } },
        "'port 1 {'kind 'exited 'code 0}",
    );
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
        .{ .executables = .{ .exact = &.{fixture_path} } },
        "[0 1 255 2 3] {'kind 'exited 'code 0}",
    );
}
