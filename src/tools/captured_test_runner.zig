//! Run a Zig test binary while keeping successful stderr diagnostic-free.
//!
//! Zig 0.16's build runner treats any stderr from an otherwise successful
//! `zig test` process as a diagnostic. Minish 0.3.0 always prints its passing
//! summary there. Run the test as an explicit child so successful library
//! chatter is captured, while real failure output is forwarded unchanged.
const std = @import("std");

pub fn main(init: std.process.Init) void {
    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch
        fail(init.io, "captured test runner: out of memory\n");
    if (arguments.len < 2)
        fail(init.io, "captured test runner: expected a test executable\n");

    const result = std.process.run(init.arena.allocator(), init.io, .{
        .argv = arguments[1..],
    }) catch
        fail(init.io, "captured test runner: could not run the test executable\n");

    if (result.stdout.len != 0) writeFile(init.io, .stdout, result.stdout) catch
        std.process.exit(1);

    switch (result.term) {
        .exited => |status| {
            if (status == 0) return;
            if (result.stderr.len != 0) writeFile(init.io, .stderr, result.stderr) catch
                std.process.exit(1);
            std.process.exit(status);
        },
        else => {
            if (result.stderr.len != 0) writeFile(init.io, .stderr, result.stderr) catch
                std.process.exit(1);
            fail(init.io, "captured test runner: test executable terminated abnormally\n");
        },
    }
}

const Output = enum { stdout, stderr };

fn fail(io: std.Io, message: []const u8) noreturn {
    writeFile(io, .stderr, message) catch {};
    std.process.exit(1);
}

fn writeFile(io: std.Io, output: Output, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = switch (output) {
        .stdout => std.Io.File.stdout().writerStreaming(io, &buffer),
        .stderr => std.Io.File.stderr().writerStreaming(io, &buffer),
    };
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
