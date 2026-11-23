//! Host primitives behind the `stream` module, which imports them: the three
//! standard devices as port endpoints, the byte-stream operations every
//! endpoint shares (which live in `port.zig` beside the message words they
//! share machinery with).
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const port_words = @import("port.zig");
const streams = @import("../standard_streams.zig");

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Host primitives behind the `stream` module, which composes them into its public words.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "in",
        .effect = "-- stream",
        .doc = "Return a handle to stdin.",
        .primitive = input,
    },
    .{
        .name = "out",
        .effect = "-- stream",
        .doc = "Return a handle to stdout.",
        .primitive = output,
    },
    .{
        .name = "err",
        .effect = "-- stream",
        .doc = "Return a handle to stderr.",
        .primitive = diagnostics,
    },
    .{ .name = "read", .effect = "stream max -- bytes", .doc = "Read at most `max` bytes from `stream`, parking until data or EOF.", .primitive = port_words.read },
    .{ .name = "read-line", .effect = "stream -- bytes", .doc = "Read through the next newline and return those bytes, including \\n.", .primitive = port_words.readLine },
    .{ .name = "write", .effect = "stream bytes --", .doc = "Write `bytes` to `stream`.", .primitive = port_words.write },
};

fn input(fiber: *Fiber) MachineError!void {
    return device(fiber, .input);
}
fn output(fiber: *Fiber) MachineError!void {
    return device(fiber, .output);
}
fn diagnostics(fiber: *Fiber) MachineError!void {
    return device(fiber, .diagnostics);
}

fn device(fiber: *Fiber, which: streams.Device) MachineError!void {
    const item = fiber.inherited.runtime().standard_streams.value(which) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProgramSource => return fiber.fail(.io, "stdin is the program source"),
    };
    try fiber.pushBorrowed(item);
}
