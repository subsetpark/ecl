//! Console operations, grouped behind the `io` module.
//!
//! The host-backed words reuse the core implementations directly. Derived
//! words schedule fixed quotations in their definition-site module,
//! so `print` remains `prin "\n" prin` and `debug` remains
//! `prin ": " prin inspect` without exposing the host primitives globally.
//! File access is not here: possession of console output never implies
//! caller-selected filesystem authority, which lives in the capability-gated
//! `fs` module.
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const prims = @import("../prims.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "pp",
        .doc = "( value -- ) Pretty-print a value followed by a newline.",
        .primitive = prims.ioPp,
    },
    .{
        .name = "prin",
        .doc = "( string -- ) Write a string without adding a newline.",
        .primitive = prims.ioPrin,
    },
    .{
        .name = "print",
        .doc = "( string -- ) Write a string followed by a newline.",
        .primitive = print,
    },
    .{
        .name = "inspect",
        .doc = "( value -- value ) Pretty-print a value while leaving it on the stack.",
        .primitive = inspect,
    },
    .{
        .name = "debug",
        .doc = "( value label -- value ) Print a label, colon, and value while leaving the value on the stack.",
        .primitive = debug,
    },
    .{
        .name = "stack",
        .doc = "Print bottom-up indexed blocks for the visible operand stack without changing it.",
        .primitive = prims.ioStack,
    },
    .{
        .name = "stdin",
        .doc = "( -- string ) Read the whole standard input stream once.",
        .primitive = prims.ioStdin,
    },
};

fn print(evaluator: *Machine) MachineError!void {
    return callWithNewline(evaluator, "io.prin", "io.prin");
}

fn inspect(evaluator: *Machine) MachineError!void {
    const quotation = try list.fromValues(evaluator.allocator(), &.{
        .{ .word = .{ .name = try intern.intern("dup") } },
        .{ .word = .{ .name = try intern.intern("io.pp") } },
    });
    try evaluator.callOwned(quotation.list);
}

fn debug(evaluator: *Machine) MachineError!void {
    var separator = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), ": "),
    );
    defer separator.deinit();
    const quotation = try list.fromValues(evaluator.allocator(), &.{
        .{ .word = .{ .name = try intern.intern("io.prin") } },
        separator.borrow(),
        .{ .word = .{ .name = try intern.intern("io.prin") } },
        .{ .word = .{ .name = try intern.intern("io.inspect") } },
    });
    try evaluator.callOwned(quotation.list);
}

/// Schedule `prin "\n" prin` as an ordinary definition-site quotation. The
/// body is fixed-size; its one heap value is retained by the quotation before
/// the local owner releases it.
fn callWithNewline(
    evaluator: *Machine,
    comptime first: []const u8,
    comptime last: []const u8,
) MachineError!void {
    var newline = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), "\n"),
    );
    defer newline.deinit();
    const quotation = try list.fromValues(evaluator.allocator(), &.{
        .{ .word = .{ .name = try intern.intern(first) } },
        newline.borrow(),
        .{ .word = .{ .name = try intern.intern(last) } },
    });
    try evaluator.callOwned(quotation.list);
}
