//! Shared contracts for the closed M5 kernel surface.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");

pub const Value = value.Value;
pub const HeapKind = value.HeapKind;
pub const Machine = machine.Machine;
pub const MachineError = machine.MachineError;

pub const max_depth: usize = 256;

/// The scheduler's kernel interval, re-exported so typed loops can bound a
/// range without importing the machine. `Context` remains the only door to the
/// budget itself.
pub const poll_quantum: usize = machine.kernel_poll_quantum;

/// Whether the selected target can execute packed i64 multiplication without
/// scalarizing the vector loop. Benchmark classification and kernel dispatch
/// share this predicate so `--explicit-simd-only` describes the loop that will
/// actually run.
pub fn targetHasNativePackedI64Multiply() bool {
    return switch (builtin.cpu.arch) {
        .aarch64 => builtin.cpu.has(.aarch64, .sve),
        .x86, .x86_64 => builtin.cpu.has(.x86, .avx512dq),
        .riscv32, .riscv64 => builtin.cpu.has(.riscv, .v),
        .wasm32, .wasm64 => std.simd.suggestVectorLength(i64) != null,
        else => false,
    };
}

/// The fault vocabulary the scalar semantics raise and the block mask carries.
/// Kernel families share this so a rescan reports exactly what the scalar path
/// reports.
pub const Fault = error{ Type, Overflow, Domain, ShiftCount };

pub fn faultKind(fault: Fault) machine.ErrorKind {
    return switch (fault) {
        error.Type => .type,
        error.Overflow => .overflow,
        error.Domain, error.ShiftCount => .domain,
    };
}

pub fn faultMessage(fault: Fault) []const u8 {
    return switch (fault) {
        error.Type => "kernel received incompatible scalar operands",
        error.Overflow => "kernel arithmetic overflow",
        error.Domain => "kernel arithmetic is outside its domain",
        error.ShiftCount => "a shift count must be from 0 to 63",
    };
}

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

/// The sized-operation taxonomy the kernel registry classifies. Each family's
/// enum is the same one its installer iterates, so an operation cannot exist
/// without a classification or be classified without existing.
pub const SequenceOp = enum {
    at,
    where,
    first_where,
    in_word,
    raze,
    cat,
    take,
    drop,
    reverse,
    first,
    rest,
    range,
    shape,
    len,
    flip,
    reshape,

    pub fn spelling(self: SequenceOp) []const u8 {
        return switch (self) {
            .at => "at",
            .where => "where",
            .first_where => "first-where",
            .in_word => "in?",
            .raze => "raze",
            .cat => "cat",
            .take => "take",
            .drop => "drop",
            .reverse => "reverse",
            .first => "first",
            .rest => "rest",
            .range => "range",
            .shape => "shape",
            .len => "len",
            .flip => "flip",
            .reshape => "reshape",
        };
    }
};

pub const OrderOp = enum {
    cmp,
    grade,
    group,

    pub fn spelling(self: OrderOp) []const u8 {
        return switch (self) {
            .cmp => "cmp",
            .grade => "grade",
            .group => "group",
        };
    }
};

pub const TextOp = enum {
    put,
    del,
    split,
    join,
    str,
    format,

    pub fn spelling(self: TextOp) []const u8 {
        return switch (self) {
            .put => "put",
            .del => "del",
            .split => "split",
            .join => "join",
            .str => "str",
            .format => "format",
        };
    }
};

pub const RandomOp = enum {
    rand_int,
    rand_ints,
    rand_float,
    entropy,

    pub fn spelling(self: RandomOp) []const u8 {
        return switch (self) {
            .rand_int => "rand.int",
            .rand_ints => "rand.ints",
            .rand_float => "rand.float",
            .entropy => "rand.entropy",
        };
    }
};

/// The budget seam for every kernel cursor.
///
/// `advanceKernel` is the only path that charges `Unit.kernel_fuel`, and it
/// asserts the charge stays within the kernel quantum and polls at the
/// boundary. A kernel that calls bare `pollKernel` with a private budget
/// instead is invisible to that accounting, which is what this type exists to
/// prevent: typed cursors accept only the narrow `Context` capability.
pub const Context = struct {
    evaluator: *Machine,

    pub fn allocator(self: Context) std.mem.Allocator {
        return self.evaluator.allocator();
    }

    /// Typed capabilities retire through the domain, never through the
    /// allocator directly, so reclamation stays bounded and off the hot path.
    pub fn releaseDomain(self: Context) *@import("heap.zig").ReleaseDomain {
        return self.evaluator.releaseDomain();
    }

    /// The remaining charge this turn may spend before the machine wants the
    /// unit back. A typed cursor bounds each half-open range by this and by the
    /// kernel quantum, which is what keeps one ready task from monopolizing a
    /// worker without paying a scheduler turn per element.
    pub fn remaining(self: Context) usize {
        return self.evaluator.remainingKernelFuel();
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

    /// The indexless counterpart, for a fault whose position is not part of the
    /// contract the caller is reporting against.
    pub fn fail(self: Context, kind: machine.ErrorKind, message: []const u8) MachineError {
        return self.evaluator.fail(kind, message);
    }

    pub fn conformError(self: Context, left: usize, right: usize) MachineError {
        return self.evaluator.conformError(left, right);
    }
};

pub fn installPrimitive(
    core: *env.BuildingEnv,
    comptime name: []const u8,
    primitive: env.PrimitiveImpl,
) error{OutOfMemory}!void {
    try core.installBuiltin(name, primitive);
}
