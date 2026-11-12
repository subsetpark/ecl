//! Host primitives behind the `fd` module, published as `fd.core`: the three
//! standard devices as port endpoints, the byte-stream operations every
//! endpoint shares (which live in `port.zig` beside the message words they
//! share machinery with), and the byte-list predicate.
const std = @import("std");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const port_words = @import("port.zig");
const streams = @import("../standard_streams.zig");
const Value = @import("../value.zig").Value;

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Host primitives behind the `fd` module, which composes them into its public words.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "in",
        .effect = "-- fd",
        .doc = "The standard input device: a readable byte endpoint shared by every unit of the session, the same value on every call. Reads return what the host has, `[]` at stable EOF, and keep returning `[]` afterwards; one read may be pending at a time. `` `io `` when standard input is the program source (`ecl -`, and non-terminal invocation with no arguments).",
        .primitive = input,
    },
    .{
        .name = "out",
        .effect = "-- fd",
        .doc = "The standard output device: a writable byte endpoint shared by every unit of the session, the same value on every call. Writes from different units are served in the order they began and each call's bytes stay contiguous.",
        .primitive = output,
    },
    .{
        .name = "err",
        .effect = "-- fd",
        .doc = "The diagnostics device: a writable byte endpoint on standard error, shared by every unit of the session and the same value on every call.",
        .primitive = diagnostics,
    },
    .{ .name = "read", .effect = "fd max -- bytes", .doc = "Read at most positive integer `max` bytes, parking until data or EOF. Return exact integer bytes in `0...255`; `[]` means stable EOF, including on later reads. Reads may be shorter than `max`. A wrong resource or non-integer `max` is `` `type ``; `max <= 0` is `` `domain ``; overlapping reads are `` `contract ``; a transport failure is `` `io ``. No text decoding is performed; use `chars`.", .primitive = port_words.read },
    .{ .name = "read-line", .effect = "fd -- bytes", .doc = "Read through the next newline and return those bytes, newline included, so `[]` is unambiguously EOF. At EOF the rest of the stream is the line, and `[]` follows on every later read. Bytes after the newline stay with the endpoint value for its next read of either kind, so read lines through one value. Errors are `read`'s.", .primitive = port_words.readLine },
    .{ .name = "write", .effect = "fd bytes --", .doc = "Accept a complete byte list in FIFO order under bounded pressure.", .primitive = port_words.write },
    .{ .name = "finish", .effect = "fd --", .doc = "Finish an endpoint's write direction after accepted writes drain. Idempotent; later writes are `` `io ``.", .primitive = port_words.finish },
    .{ .name = "bytes?", .effect = "value -- bool", .doc = "Return 1 when the value is a list of integers in `0...255`, what `write` accepts as one piece, and 0 for anything else, including a string.", .primitive = bytesPredicate },
};

fn bytesPredicate(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const source = item.borrow();
    if (source != .list) return fiber.pushOwned(.{ .int = 0 });
    switch (source.list.kind()) {
        .leaf_u8 => return fiber.pushOwned(.{ .int = 1 }),
        .leaf_i64, .generic_spine => {},
        else => return fiber.pushOwned(.{ .int = 0 }),
    }
    if (source.list.length() == 0) return fiber.pushOwned(.{ .int = 1 });
    try fiber.startDriver(BytesPredicate{ .source = .init(item.take()) });
}

/// `fd.bytes?` over an int or generic list, a block at a time. An int leaf is
/// judged by its block's minimum and maximum; a generic list element by
/// element.
const BytesPredicate = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source: heap.Owned(Value),
    index: usize = 0,

    pub fn advance(fiber: *Fiber, self: *BytesPredicate) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        const source = self.source.borrow();
        const count: usize = @intCast(source.list.length());
        while (!work.exhausted()) {
            if (self.index == count) return .{ .output = .{ .int = 1 } };
            const end = self.index + work.take(count - self.index);
            const accepted = switch (source.list.kind()) {
                .leaf_i64 => range: {
                    var low: i64 = std.math.maxInt(i64);
                    var high: i64 = std.math.minInt(i64);
                    for (heap.i64s(source.list)[self.index..end]) |number| {
                        low = @min(low, number);
                        high = @max(high, number);
                    }
                    break :range low >= 0 and high <= 255;
                },
                else => each: {
                    for (self.index..end) |position| {
                        const element = list.atUnchecked(source, position);
                        if (element != .int or element.int < 0 or element.int > 255) break :each false;
                    }
                    break :each true;
                },
            };
            if (!accepted) return .{ .output = .{ .int = 0 } };
            self.index = end;
        }
        return .stepped;
    }
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
