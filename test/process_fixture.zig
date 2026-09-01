//! Hermetic subprocess fixture for the public `proc` acceptance surface.
//!
//! Every behavior is selected by an explicit mode. The fixture performs no
//! PATH lookup, shell invocation, network access, or timing-based readiness.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingMode;
    const mode = arguments[1];
    if (std.mem.eql(u8, mode, "inspect")) return inspect(init, arguments[2..]);
    if (std.mem.eql(u8, mode, "echo")) return echo(init);
    if (std.mem.eql(u8, mode, "split")) return split(init, arguments[2..]);
    if (std.mem.eql(u8, mode, "exit")) return exitWith(arguments[2..]);
    if (std.mem.eql(u8, mode, "large")) return large(init, arguments[2..]);
    if (std.mem.eql(u8, mode, "block")) return block(init);
    if (std.mem.eql(u8, mode, "descendant")) return descendant(init, arguments[0]);
    return error.UnknownMode;
}

fn stdoutWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(io, buffer);
}

fn stderrWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(io, buffer);
}

fn inspect(init: std.process.Init, arguments: []const []const u8) !void {
    var output_buffer: [4096]u8 = undefined;
    var output = stdoutWriter(init.io, &output_buffer);
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    try output.interface.print("cwd={s}\n", .{cwd});
    try output.interface.print("probe={s}\n", .{init.environ_map.get("ECL_PROCESS_PROBE") orelse "<absent>"});
    for (arguments, 0..) |argument, index|
        try output.interface.print("arg[{d}]={s}\n", .{ index, argument });
    try output.interface.flush();
}

fn echo(init: std.process.Init) !void {
    var input_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output_buffer: [8192]u8 = undefined;
    var output = stdoutWriter(init.io, &output_buffer);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const amount = try input.interface.readSliceShort(&chunk);
        if (amount == 0) break;
        try output.interface.writeAll(chunk[0..amount]);
        try output.interface.flush();
    }
}

fn split(init: std.process.Init, arguments: []const []const u8) !void {
    if (arguments.len != 2) return error.BadArguments;
    var output_buffer: [4096]u8 = undefined;
    var output = stdoutWriter(init.io, &output_buffer);
    var error_buffer: [4096]u8 = undefined;
    var error_output = stderrWriter(init.io, &error_buffer);
    try output.interface.writeAll(arguments[0]);
    try error_output.interface.writeAll(arguments[1]);
    try output.interface.flush();
    try error_output.interface.flush();
}

fn exitWith(arguments: []const []const u8) !void {
    if (arguments.len != 1) return error.BadArguments;
    std.process.exit(try std.fmt.parseInt(u8, arguments[0], 10));
}

fn large(init: std.process.Init, arguments: []const []const u8) !void {
    if (arguments.len != 2) return error.BadArguments;
    const stdout_bytes = try std.fmt.parseInt(usize, arguments[0], 10);
    const stderr_bytes = try std.fmt.parseInt(usize, arguments[1], 10);
    var output_buffer: [8192]u8 = undefined;
    var output = stdoutWriter(init.io, &output_buffer);
    var error_buffer: [8192]u8 = undefined;
    var error_output = stderrWriter(init.io, &error_buffer);
    var remaining_stdout = stdout_bytes;
    var remaining_stderr = stderr_bytes;
    const stdout_chunk = "o" ** 4096;
    const stderr_chunk = "e" ** 4096;
    while (remaining_stdout != 0 or remaining_stderr != 0) {
        if (remaining_stdout != 0) {
            const amount = @min(remaining_stdout, stdout_chunk.len);
            try output.interface.writeAll(stdout_chunk[0..amount]);
            try output.interface.flush();
            remaining_stdout -= amount;
        }
        if (remaining_stderr != 0) {
            const amount = @min(remaining_stderr, stderr_chunk.len);
            try error_output.interface.writeAll(stderr_chunk[0..amount]);
            try error_output.interface.flush();
            remaining_stderr -= amount;
        }
    }
}

fn block(init: std.process.Init) !void {
    var input_buffer: [256]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var discarded: [256]u8 = undefined;
    while (try input.interface.readSliceShort(&discarded) != 0) {}
    // EOF is an input event, not permission to make the blocking fixture
    // terminate. This keeps proc.run deadline tests hermetic after it performs
    // its required close-input step; TERM/KILL still stop the process.
    var forever: std.Io.Event = .unset;
    forever.waitUncancelable(init.io);
}

fn descendant(init: std.process.Init, executable: []const u8) !void {
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ executable, "block" },
        .stdin = .inherit,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var output_buffer: [128]u8 = undefined;
    var output = stdoutWriter(init.io, &output_buffer);
    try output.interface.print("descendant={d}\n", .{child.id.?});
    try output.interface.flush();
    try block(init);
    _ = try child.wait(init.io);
}
