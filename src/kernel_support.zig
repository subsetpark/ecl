//! Shared contracts for the closed M5 kernel surface.
const std = @import("std");
const value = @import("value.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");

pub const Value = value.Value;
pub const HeapKind = value.HeapKind;
pub const Machine = machine.Machine;
pub const MachineError = machine.MachineError;

pub const max_depth: usize = 256;

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
    band,
    bor,
    bxor,
    bsl,
    bsr,

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
            .band => "band",
            .bor => "bor",
            .bxor => "bxor",
            .bsl => "bsl",
            .bsr => "bsr",
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
    bnot,

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
            .bnot => "bnot",
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

    pub fn failAt(
        self: Context,
        kind: machine.ErrorKind,
        message: []const u8,
        index: usize,
    ) MachineError {
        return self.evaluator.failAtIndex(kind, message, index);
    }
};

pub fn installPrimitive(
    core: *env.BuildingEnv,
    comptime name: []const u8,
    primitive: env.PrimitiveImpl,
) error{OutOfMemory}!void {
    try core.installBuiltin(name, primitive);
}
