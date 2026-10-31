//! Host primitives behind the `str` module, published as `str.core`. The
//! one word here reads a list's physical representation so `str.str?` can
//! answer in constant time for the representation every string producer
//! uses, and scan only a generic list, whose elements may be anything.
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");

const Unit = machine.Unit;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "kind",
        .effect = "value -- kind",
        .doc = "`string for a list stored as characters, `generic for a list whose elements must be examined, `other for a value that cannot be a string.",
        .primitive = kind,
    },
};

fn kind(evaluator: *Unit) MachineError!void {
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
