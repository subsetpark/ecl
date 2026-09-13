//! Inert declaration inspection shares the reader's discovery rule.
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const reader = @import("../reader.zig");
const Value = @import("../value.zig").Value;

pub const words = [_]env.BuiltinWord{.{
    .name = "declarations",
    .effect = "quotation -- list",
    .doc = "Inspect parsed source without execution; return literal top-level @defm names as symbols in source order, preserving duplicates. Computed and nested registrations are omitted. Use parse first for source text.",
    .primitive = declarations,
}};

fn declarations(evaluator: *machine.Machine) machine.MachineError!void {
    var forms = try evaluator.popQuotation();
    defer forms.deinit();
    try evaluator.startDriver(DeclarationsDriver{ .forms = .init(forms.take()) });
}

const DeclarationsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    forms: heap.Owned(Value),
    scan: reader.DeclarationScan = .{},
    index: usize = 0,
    count: usize = 0,
    // The counting pass fixes the allocation size before materialization.
    output: ?heap.Owned(heap.OwnedValueBuffer) = null,

    pub fn advance(evaluator: *machine.Machine, self: *DeclarationsDriver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const forms = self.forms.borrow();
        const end = @min(self.index + machine.kernel_poll_quantum, forms.list.length());
        while (self.index < end) : (self.index += 1) {
            if (self.scan.feed(list.atUnchecked(forms, self.index))) |name| {
                if (self.output) |*output| {
                    output.borrowMut().appendBorrowed(.{ .symbol = name });
                } else self.count += 1;
            }
        }
        if (self.index != forms.list.length()) return .yielded;
        if (self.output) |*output| {
            const result = output.borrowMut().takeList();
            self.output = null;
            return .{ .output = result };
        }
        self.output = .init(try .init(evaluator.releaseDomain(), self.count));
        self.index = 0;
        self.scan = .{};
        return .yielded;
    }
};
