//! Console and UTF-8 file operations, grouped behind the `io` module.
//!
//! The host-backed words reuse the core implementations directly. The two
//! derived words schedule fixed quotations in their definition-site module,
//! so `print` remains `prin "\n" prin` and `lines` remains
//! `slurp "\n" split` without exposing the host primitives globally.
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
        .name = "stdin",
        .doc = "( -- string ) Read the whole standard input stream once.",
        .primitive = prims.ioStdin,
    },
    .{
        .name = "slurp",
        .doc = "( path -- string ) Read one whole UTF-8 file.",
        .primitive = prims.ioSlurp,
    },
    .{
        .name = "spit",
        .doc = "( string path -- ) Write a string to one file, truncating and replacing it.",
        .primitive = prims.ioSpit,
    },
    .{
        .name = "lines",
        .doc = "( path -- lines ) Read one UTF-8 file and split it at newline characters.",
        .primitive = lines,
    },
};

fn print(evaluator: *Machine) MachineError!void {
    return callWithNewline(evaluator, "io.prin", "io.prin");
}

fn inspect(evaluator: *Machine) MachineError!void {
    const quotation = try list.fromValues(evaluator.allocator(), &.{
        .{ .word = try intern.intern("dup") },
        .{ .word = try intern.intern("io.pp") },
    });
    try evaluator.callOwned(quotation.list);
}

fn lines(evaluator: *Machine) MachineError!void {
    return callWithNewline(evaluator, "io.slurp", "split");
}

/// Schedule either `prin "\n" prin` or `slurp "\n" split` as an ordinary
/// definition-site quotation. The body is fixed-size; its one heap value is
/// retained by the quotation before the local owner releases it.
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
        .{ .word = try intern.intern(first) },
        newline.borrow(),
        .{ .word = try intern.intern(last) },
    });
    try evaluator.callOwned(quotation.list);
}
