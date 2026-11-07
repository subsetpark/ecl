//! Host primitives behind the `str` module, published as `str.core`. `kind`
//! reads a list's physical representation so `str.str?` can answer in
//! constant time for the representation every string producer uses, and scan
//! only a generic list, whose elements may be anything. `format` is the text
//! kernel `str` re-exports.
const env = @import("../env.zig");
const dict_text = @import("../kernel_dict_text.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Host kernels behind the `str` module, which validates their operands and composes them into
    \\its public words, and re-exports `format`.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "kind",
        .effect = "value -- kind",
        .doc = "`string for a list stored as characters, `generic for a list whose elements must be examined, `other for a value that cannot be a string.",
        .primitive = kind,
    },
    .{
        .name = "format",
        .effect = "values template -- string",
        .doc = "Interpolate positional `{}` placeholders. Strings contribute their contents; other values contribute canonical `str`. `{{` and `}}` emit literal braces.",
        .primitive = dict_text.formatPrimitive,
    },
};

fn kind(evaluator: *Fiber) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const spelling: []const u8 = switch (item.borrow()) {
        .list => |header| if (header.length() == 0) "string" else switch (header.kind()) {
            .leaf_char1, .leaf_char2, .leaf_char4 => "string",
            .generic_spine => "generic",
            .leaf_u8, .leaf_i64, .leaf_f64, .dict, .task, .port, .address, .reserved_mask => "other",
        },
        else => "other",
    };
    try evaluator.pushOwned(.{ .symbol = .{ .name = try intern.intern(spelling) } });
}
