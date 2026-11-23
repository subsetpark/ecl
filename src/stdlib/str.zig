//! Host primitives behind the `str` module, which imports them. `str?`
//! answers in constant time for the representation every string producer
//! uses, and scans only a generic list, whose elements may be anything.
//! `format`, `split`, and `join` are the text kernels `str` re-exports.
const env = @import("../env.zig");
const text = @import("../kernel_text.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const Value = machine.Value;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Host kernels behind the `str` module, which validates their operands and composes them into
    \\its public words, and re-exports `str?`, `format`, `split`, and `join`.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "str?",
        .effect = "value -- bool",
        .doc = "Return 1 when `value` is a list of chars.",
        .primitive = isString,
    },
    .{
        .name = "format",
        .effect = "values template -- string",
        .doc = "Interpolate positional `{}` placeholders. Strings are rendered verbatim; other values are rendered with `str`. User `{{` and `}}` to emit literal braces.",
        .primitive = text.formatPrimitive,
    },
    .{
        .name = "split",
        .effect = "string separator -- parts",
        .doc = "Split `string` at every occurrence of `separator`. When `separator` is \"\", then `parts` will be a list of single-codepoint strings.",
        .primitive = text.splitPrimitive,
    },
    .{
        .name = "join",
        .effect = "strings separator -- string",
        .doc = "Join `strings` with `separator`.",
        .primitive = text.joinPrimitive,
    },
};

fn isString(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const answer = switch (item.borrow()) {
        .list => |header| if (header.length() == 0) true else switch (header.kind()) {
            .leaf_char1, .leaf_char2, .leaf_char4 => true,
            .generic_spine => return fiber.startDriver(ScanDriver{ .collection = .init(item.take()) }),
            .leaf_u8, .leaf_i64, .leaf_f64, .dict, .task, .port, .address, .reserved_mask => false,
        },
        else => false,
    };
    try fiber.pushOwned(.{ .int = @intFromBool(answer) });
}

/// A generic list may hold chars, so its elements are examined one budget
/// unit each until a non-char answers 0 or the end answers 1.
const ScanDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    pub const inline_driver = true;
    collection: heap.Owned(Value),
    index: usize = 0,

    pub fn advance(fiber: *Fiber, self: *ScanDriver) MachineError!machine.WorkProgress {
        const collection = self.collection.borrow();
        const count: usize = @intCast(collection.list.length());
        const budget = fiber.workBudget();
        while (self.index < count) : (self.index += 1) {
            if (!budget.spend()) return .stepped;
            if (list.atUnchecked(collection, self.index) != .char) return .{ .output = .{ .int = 0 } };
        }
        return .{ .output = .{ .int = 1 } };
    }
};
