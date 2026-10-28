//! Console primitives behind the `io` module, published as `io.core`; the
//! `io` module itself is ECL source over these and over the `fd` devices.
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
        .effect = "value --",
        .doc = "Pretty-print any value plus newline in the display layout of Printing. Best-effort: huge leaves may be elided, so there is no round-trip guarantee. Use core `str` for canonical rendering.",
        .primitive = prims.ioPp,
    },
    .{
        .name = "prin",
        .effect = "string --",
        .doc = "Write a string's characters as UTF-8 to standard output without adding a newline. Non-string is `` `type ``.",
        .primitive = prims.ioPrin,
    },
    .{
        .name = "print",
        .effect = "string --",
        .doc = "Write a string followed by a newline to standard output. Semantically `io.prin \"\\n\" io.prin`.",
        .primitive = print,
    },
    .{
        .name = "eprint",
        .effect = "string --",
        .doc = "Write a string followed by a newline to the Session's diagnostics stream: standard error under the command line, the host's diagnostics writer when embedded, and never standard output. When the host supplies no diagnostics writer the string is dropped and the word succeeds. Non-string is `` `type ``; a failed write is `` `io ``.",
        .primitive = eprint,
    },
    .{
        .name = "inspect",
        .effect = "value -- value",
        .doc = "Pretty-print a value while leaving it on the stack; the pipeline probe. Semantically `dup io.pp`.",
        .primitive = inspect,
    },
    .{
        .name = "debug",
        .effect = "value label -- value",
        .doc = "Write the string label, `\": \"`, and the value's pretty-printed representation plus newline, leaving the value on the stack. Semantically `io.prin \": \" io.prin io.inspect`; a non-string label is the same `` `type `` failure as `io.prin`.",
        .primitive = debug,
    },
    .{
        .name = "stack",
        .effect = "--",
        .doc = "Stack-polymorphic; leaves the operand stack unchanged. Print each value in the currently visible operand window as a bottom-up indexed display block. `[0]` is the bottom and the largest index is the top; continuation lines align after the prefix. An isolated quotation sees only values above its isolation floor. An empty visible window writes nothing. Rendering is best-effort and may use the same multiline dictionary, array, and elision layout as `io.pp`.",
        .primitive = prims.ioStack,
    },
};

fn print(evaluator: *Machine) MachineError!void {
    return callWithNewline(evaluator, "io.core.prin", "io.core.prin");
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
        return switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "string contains an invalid Unicode scalar",
            ),
        }) {
            .pending => .stepped,
            .complete => |encoded| completed: {
                defer evaluator.allocator().free(encoded);
                try writeDiagnosticsLine(evaluator, encoded);
                break :completed .completed;
            },
        };
    }
};

/// Diagnostics share the Session console's serialization with advisory output.
fn writeDiagnosticsLine(evaluator: *Machine, bytes: []const u8) MachineError!void {
    evaluator.unit.inherited.runtime().console.writeDiagnostics(bytes, true) catch
        return evaluator.fail(.io, "diagnostics stream write failed");
}

fn inspect(evaluator: *Machine) MachineError!void {
    const quotation = try list.fromValues(evaluator.allocator(), &.{
        .{ .symbol = try evaluator.coreWord(try intern.intern("dup")) },
        .{ .symbol = try evaluator.coreWord(try intern.intern("io.core.pp")) },
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
        .{ .symbol = try evaluator.coreWord(try intern.intern("io.core.prin")) },
        separator.borrow(),
        .{ .symbol = try evaluator.coreWord(try intern.intern("io.core.prin")) },
        .{ .symbol = try evaluator.coreWord(try intern.intern("io.core.inspect")) },
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
        .{ .symbol = try evaluator.coreWord(try intern.intern(first)) },
        newline.borrow(),
        .{ .symbol = try evaluator.coreWord(try intern.intern(last)) },
    });
    try evaluator.callOwned(quotation.list);
}
