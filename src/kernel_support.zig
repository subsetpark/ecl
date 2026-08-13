//! Shared contracts for the closed M5 kernel surface.
const std = @import("std");
const value = @import("value.zig");
const env = @import("env.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const poll_api = @import("poll.zig");

pub const Value = value.Value;
pub const HeapKind = value.HeapKind;
pub const Machine = machine.Machine;
pub const MachineError = machine.MachineError;

pub const fault_block: usize = 256;
pub const poll_chunk: usize = machine.kernel_poll_quantum;
pub const max_depth: usize = 256;

pub const IndexRange = struct {
    start: usize,
    end: usize,

    pub fn init(start: usize, end: usize) IndexRange {
        std.debug.assert(start <= end);
        return .{ .start = start, .end = end };
    }

    pub fn len(self: IndexRange) usize {
        return self.end - self.start;
    }
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    int_div,
    mod,
    pow,
    atan2,
    min,
    max,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    and_word,
    or_word,

    pub fn spelling(self: BinaryOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .int_div => "div",
            .mod => "mod",
            .pow => "pow",
            .atan2 => "atan2",
            .min => "min",
            .max => "max",
            .eq => "=",
            .ne => "<>",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .and_word => "and",
            .or_word => "or",
        };
    }
};

pub const UnaryOp = enum {
    neg,
    abs,
    sqrt,
    floor,
    ceil,
    round,
    exp,
    log,
    sin,
    cos,
    not_word,

    pub fn spelling(self: UnaryOp) []const u8 {
        return switch (self) {
            .neg => "neg",
            .abs => "abs",
            .sqrt => "sqrt",
            .floor => "floor",
            .ceil => "ceil",
            .round => "round",
            .exp => "exp",
            .log => "log",
            .sin => "sin",
            .cos => "cos",
            .not_word => "not",
        };
    }
};

pub const Context = struct {
    evaluator: *Machine,

    pub fn allocator(self: Context) std.mem.Allocator {
        return self.evaluator.allocator();
    }

    pub fn advance(self: Context, logical_elements: usize) MachineError!void {
        try self.evaluator.advanceKernel(logical_elements);
    }

    pub fn poll(self: Context) MachineError!void {
        try self.advance(1);
    }

    pub fn structuralPoller(self: Context) poll_api.Poller {
        return .{
            .context = @ptrCast(self.evaluator),
            .poll_fn = pollMachine,
        };
    }

    pub fn failAt(
        self: Context,
        kind: machine.ErrorKind,
        message: []const u8,
        index: usize,
    ) MachineError {
        return self.evaluator.failAtIndex(kind, message, index);
    }
};

fn pollMachine(raw: *anyopaque) poll_api.Error!void {
    const evaluator: *Machine = @ptrCast(@alignCast(raw));
    try evaluator.advanceKernel(1);
}

pub fn installPrimitive(
    core: *env.Env,
    name: []const u8,
    primitive: env.Primitive,
) error{OutOfMemory}!void {
    const id = try intern.intern(name);
    try core.installCore(id, .{ .primitive = primitive });
}

test "kernel constants freeze bounded work contracts" {
    try std.testing.expectEqual(@as(usize, 256), fault_block);
    try std.testing.expectEqual(@as(usize, 65_536), poll_chunk);
    try std.testing.expectEqual(@as(usize, 256), max_depth);
    try std.testing.expectEqual(@as(usize, 3), IndexRange.init(4, 7).len());
}
