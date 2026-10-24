//! The installer for the kernel surface. `install` publishes the core kernel
//! families; module-backed random draws and hosted idioms enter through their
//! qualified exports.
//!
//! Each family's operations are one enum in `kernel_support`, the same one its
//! installer iterates. How an operation runs for an operand shape is the
//! kernel's own code: a typed shape runs through `support.Kernel`, which the
//! source audit enforces, and every other shape names its reason there.
const std = @import("std");
const env = @import("env.zig");
pub const support = @import("kernel_support.zig");
pub const storage = @import("kernel_storage.zig");
pub const numeric = @import("kernel_numeric.zig");
const sequence = @import("kernel_sequence.zig");
const order = @import("kernel_order.zig");
const dict_text = @import("kernel_dict_text.zig");
pub const random = @import("kernel_random.zig");
pub const flat = @import("kernel_flat.zig");

pub const Registry = struct {
    pub const entries = @import("idioms.zig").registry;
};

// Every phrase head must be a kernel word: only kernel families bind their
// primitives through `support.headed`, so a head outside them would never ask.
comptime {
    @setEvalBranchQuota(100_000);
    const families = .{
        support.BinaryOp,
        support.UnaryOp,
        support.SequenceOp,
        support.OrderOp,
        support.TextOp,
        support.RandomOp,
    };
    for (Registry.entries) |entry| {
        if (entry.following.len == 0) continue;
        var kernel = false;
        for (families) |Family| {
            for (std.meta.tags(Family)) |operation| {
                if (std.mem.eql(u8, operation.spelling(), entry.source_word.?)) kernel = true;
            }
        }
        if (!kernel) @compileError("phrase head is not a kernel word: " ++ entry.source_word.?);
    }
}

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try numeric.install(core);
    try sequence.install(core);
    try order.install(core);
    try dict_text.install(core);
}
