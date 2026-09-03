//! Console operations, grouped behind the `io` module.
//!
//! The host-backed words reuse the core implementations directly. Derived
//! words schedule fixed quotations in their definition-site module,
//! so `print` remains `prin "\n" prin` and `debug` remains
//! `prin ": " prin inspect` without exposing the host primitives globally.
//! `eprint` is the one word addressed to the diagnostics stream; it never
//! falls back to standard output, so a host that supplies no diagnostics
//! writer drops the line rather than mixing it into program output.
//! File access is not here: possession of console output never implies
//! caller-selected filesystem authority, which lives in the capability-gated
//! `fs` module.
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const prims = @import("../prims.zig");
const kernel_storage = @import("../kernel_storage.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Value = machine.Value;

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
        .name = "eprint",
        .doc = "( string -- ) Write a string followed by a newline to the diagnostics stream, never to standard output.",
        .primitive = eprint,
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

/// Bounded like `prin`: the string is encoded under the kernel poll quantum
/// and written once complete. There is no availability precondition because
/// a missing diagnostics writer is not an error for this word.
fn eprint(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popString();
    defer item.deinit();
    const string = item.borrow();
    try evaluator.startDriver(EprintDriver{
        .item = .init(item.take()),
        .encoder = .init(.init(evaluator.allocator(), string)),
    });
}

const EprintDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    item: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),

    pub fn advance(evaluator: *Machine, self: *EprintDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "string contains an invalid Unicode scalar",
            ),
        }) {
            .pending => .yielded,
            .complete => |encoded| completed: {
                defer evaluator.allocator().free(encoded);
                try writeDiagnosticsLine(evaluator, encoded);
                break :completed .completed;
            },
        };
    }
};

/// The Session console is preferred because it serializes diagnostics
/// against the advisory writes made from other threads. A console without a
/// diagnostics writer reports every write as failed, which for this word is
/// "nothing to write to", not a failure; only a writer that exists and
/// refuses the bytes is `'io`.
fn writeDiagnosticsLine(evaluator: *Machine, bytes: []const u8) MachineError!void {
    const inherited = evaluator.unit.inherited;
    if (inherited.console) |console| {
        if (console.diagnostics == null) return;
        return console.writeDiagnostics(bytes, true) catch
            evaluator.fail(.io, "diagnostics stream is unavailable");
    }
    const diagnostics = inherited.diagnostics orelse return;
    diagnostics.writeAll(bytes) catch
        return evaluator.fail(.io, "diagnostics stream is unavailable");
    diagnostics.writeByte('\n') catch
        return evaluator.fail(.io, "diagnostics stream is unavailable");
    diagnostics.flush() catch
        return evaluator.fail(.io, "diagnostics stream is unavailable");
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
