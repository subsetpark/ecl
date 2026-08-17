//! Stack/control primitives and the installer for the closed kernel surface.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const intern = @import("intern.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const module_prims = @import("module_prims.zig");
const combinators = @import("combinators.zig");
const kernels = @import("kernels.zig");
const kernel_storage = @import("kernel_storage.zig");
const task_prims = @import("task_prims.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Definition = struct {
    name: []const u8,
    primitive: env.PrimitiveImpl,
};
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "dup", .primitive = dup },
        .{ .name = "swap", .primitive = swap },
        .{ .name = "pop", .primitive = pop },
        .{ .name = "cons", .primitive = cons },
        .{ .name = "match", .primitive = match },
        .{ .name = "type", .primitive = typeWord },
        .{ .name = "parse", .primitive = parse },
        .{ .name = "dict-of", .primitive = dictOf },
        .{ .name = "attempt", .primitive = attempt },
        .{ .name = "raise", .primitive = raise },
        .{ .name = "pp", .primitive = pp },
        .{ .name = "prin", .primitive = prin },
        .{ .name = "args", .primitive = args },
        .{ .name = "exit", .primitive = exit },
    };
    try core.installBuiltins(definitions);
    try combinators.install(core);
    try kernels.install(core);
    try module_prims.install(core);
    try task_prims.install(core);
}
fn dup(evaluator: *Machine) MachineError!void {
    try evaluator.require(1);
    try evaluator.pushBorrowed(evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1]);
}
fn swap(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    std.mem.swap(Value, &items[items.len - 1], &items[items.len - 2]);
}
fn pop(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    item.deinit();
}
fn cons(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var collection = try evaluator.popList();
    defer collection.deinit();
    var item = try evaluator.popValue();
    defer item.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    const values = try evaluator.allocator().alloc(Value, count + 1);
    try evaluator.startDriver(ConcatDriver.init(
        evaluator.allocator(),
        item.take(),
        collection.take(),
        values,
    ));
}

const ConcatDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: heap.Owned(Value),
    values: heap.Owned([]Value),
    index: usize = 0,
    materializing: bool = false,
    materializer: heap.Owned(kernel_storage.ValueMaterializer),

    fn init(
        allocator: std.mem.Allocator,
        left: Value,
        right: Value,
        values: []Value,
    ) ConcatDriver {
        return .{
            .left = .init(left),
            .right = .init(right),
            .values = .init(values),
            .materializer = .init(.init(allocator, values)),
        };
    }

    pub fn advance(evaluator: *Machine, self: *ConcatDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget = machine.kernel_poll_quantum;
        const values = self.values.borrow();
        while (!self.materializing and budget != 0 and self.index != values.len) : (budget -= 1) {
            values[self.index] = if (self.index == 0)
                self.left.borrow()
            else
                list.atUnchecked(self.right.borrow(), self.index - 1);
            self.index += 1;
        }
        if (self.index != values.len) return .yielded;
        self.materializing = true;
        if (budget == 0) return .yielded;
        return switch (try self.materializer.borrowMut().advance(budget)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }
};
fn match(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const cursor = try equal.MatchCursor.init(evaluator.allocator(), left.borrow(), right.borrow());
    try evaluator.startDriver(MatchDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .cursor = .init(cursor),
    });
}

const MatchDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: heap.Owned(Value),
    cursor: heap.Owned(equal.MatchCursor),

    pub fn advance(evaluator: *Machine, self: *MatchDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |matches| .{ .output = .{ .int = @intFromBool(matches) } },
        };
    }
};
fn typeWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const spelling: []const u8 = switch (item.borrow()) {
        .int => "int",
        .float => "float",
        .char => "char",
        .symbol => "symbol",
        .word => "word",
        .list => "list",
        .dict => "dict",
        .task => "task",
    };
    try evaluator.pushOwned(.{ .symbol = try intern.intern(spelling) });
}
fn parse(evaluator: *Machine) MachineError!void {
    var source_value = try evaluator.popString();
    defer source_value.deinit();
    const source = source_value.borrow();
    try evaluator.startDriver(ParseDriver{
        .source_value = .init(source_value.take()),
        .encoder = .init(.init(evaluator.allocator(), source)),
    });
}
const ParseDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.ToUtf8Cursor),
    source: ?heap.Owned([]u8) = null,
    pub fn advance(evaluator: *Machine, self: *ParseDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.source == null) switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |source| self.source = .init(source),
        };
        const source = self.source.?.take();
        self.source = null;
        evaluator.detachWorkDriver(self);
        heap.destroyDriver(evaluator.releaseDomain(), evaluator.allocator(), self);
        try evaluator.parseSourceOwned(source);
        return .detached;
    }
};
fn dictOf(evaluator: *Machine) MachineError!void {
    var entries = try evaluator.popValue();
    defer entries.deinit();
    if (entries.borrow() != .list) return evaluator.typeError("a flat key/value list");
    const count: usize = @intCast(entries.borrow().list.length());
    if (count % 2 != 0) {
        return evaluator.fail(.contract, "dict-of requires an even-length key/value list");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count / 2);
    try evaluator.startDriver(DictOfDriver{
        .entries = .init(entries.take()),
        .pairs = .init(pairs),
    });
}

const DictOfDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    entries: heap.Owned(Value),
    pairs: heap.Owned([]dict.Pair),
    index: usize = 0,
    materializer: ?heap.Owned(kernel_storage.DictMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *DictOfDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.materializer == null) {
            const pairs = self.pairs.borrow();
            const end = @min(self.index + machine.kernel_poll_quantum, pairs.len);
            while (self.index != end) : (self.index += 1) pairs[self.index] = .{
                list.atUnchecked(self.entries.borrow(), self.index * 2),
                list.atUnchecked(self.entries.borrow(), self.index * 2 + 1),
            };
            if (self.index != pairs.len) return .yielded;
            self.materializer = .init(try .init(evaluator.allocator(), pairs, true));
            return .yielded;
        }
        return switch (try self.materializer.?.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .duplicate_key => evaluator.fail(.domain, "dict-of received a duplicate key"),
            .complete => |dictionary| .{ .output = dictionary },
        };
    }
};
fn attempt(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    try evaluator.attemptOwned(quotation.take().list);
}
fn raise(evaluator: *Machine) MachineError!void {
    var raised = try evaluator.popValue();
    defer raised.deinit();
    if (raised.borrow() != .dict) return evaluator.typeError("an error dict");
    const keys = [5]u32{
        try intern.intern("kind"),
        try intern.intern("msg"),
        try intern.intern("word"),
        try intern.intern("trace"),
        try intern.intern("data"),
    };
    try evaluator.startDriver(RaiseDriver{ .raised = .init(raised.take()), .keys = keys });
}
const RaiseDriver = struct {
    raised: heap.Owned(Value),
    keys: [5]u32,
    field_index: usize = 0,
    lookup: ?heap.Owned(kernel_storage.DictFindCursor) = null,
    trace: ?Value = null,
    trace_index: usize = 0,
    phase: enum { lookup, trace, finish } = .lookup,

    pub fn advance(evaluator: *Machine, self: *RaiseDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.phase) {
            .lookup => {
                if (self.field_index == self.keys.len) {
                    self.phase = .finish;
                    return .yielded;
                }
                if (self.lookup == null) self.lookup = .init(.initHeader(
                    evaluator.allocator(),
                    self.raised.borrow().dict,
                    .{ .symbol = self.keys[self.field_index] },
                ));
                switch (try self.lookup.?.borrowMut().advance(machine.kernel_poll_quantum)) {
                    .pending => return .yielded,
                    .complete => |found| {
                        self.lookup.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.lookup = null;
                        try self.validateField(evaluator, found);
                        if (self.phase == .lookup) self.field_index += 1;
                        return .yielded;
                    },
                }
            },
            .trace => {
                const trace = self.trace.?;
                const count: usize = @intCast(trace.list.length());
                const end = @min(self.trace_index + machine.kernel_poll_quantum, count);
                while (self.trace_index != end) : (self.trace_index += 1) {
                    if (list.atUnchecked(trace, self.trace_index) != .symbol)
                        return evaluator.typeError("an error dict with symbols at 'trace");
                }
                if (self.trace_index == count) {
                    self.trace = null;
                    self.field_index += 1;
                    self.phase = .lookup;
                }
                return .yielded;
            },
            .finish => {
                const raised = self.raised.take();
                return evaluator.raiseOwned(raised);
            },
        }
    }
    fn validateField(self: *RaiseDriver, evaluator: *Machine, found: ?Value) MachineError!void {
        switch (self.field_index) {
            0 => if (found == null or found.? != .symbol)
                return evaluator.typeError("an error dict containing a symbol at 'kind"),
            1 => if (found) |message| {
                if (!message.isString())
                    return evaluator.typeError("an error dict with a string at 'msg");
            },
            2 => if (found) |word| {
                if (word != .symbol)
                    return evaluator.typeError("an error dict with a symbol at 'word");
            },
            3 => if (found) |trace| {
                if (trace != .list)
                    return evaluator.typeError("an error dict with symbols at 'trace");
                self.trace = trace;
                self.trace_index = 0;
                self.phase = .trace;
            },
            4 => if (found) |data| {
                if (data != .dict)
                    return evaluator.typeError("an error dict with a dict at 'data");
            },
            else => unreachable,
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
fn pp(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (evaluator.unit.inherited.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const render = try printer.OwnedStringCursor.initDisplay(evaluator.allocator(), item.borrow());
    try evaluator.startDriver(PpDriver{
        .item = .init(item.take()),
        .render = .init(render),
    });
}

const PpDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    item: heap.Owned(Value),
    render: heap.Owned(printer.OwnedStringCursor),

    pub fn advance(evaluator: *Machine, self: *PpDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.render.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |rendered| completed: {
                defer evaluator.allocator().free(rendered);
                if (evaluator.unit.inherited.console) |console| {
                    console.writeOutput(rendered, true) catch
                        return evaluator.fail(.io, "standard output write failed");
                    break :completed .completed;
                }
                const output = evaluator.unit.output.?;
                output.writeAll(rendered) catch
                    return evaluator.fail(.io, "standard output write failed");
                output.writeByte('\n') catch
                    return evaluator.fail(.io, "standard output write failed");
                output.flush() catch
                    return evaluator.fail(.io, "standard output flush failed");
                break :completed .completed;
            },
        };
    }
};

fn prin(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popString();
    defer item.deinit();
    if (evaluator.unit.inherited.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const string = item.borrow();
    try evaluator.startDriver(PrinDriver{
        .item = .init(item.take()),
        .encoder = .init(.init(evaluator.allocator(), string)),
    });
}

const PrinDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    item: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),

    pub fn advance(evaluator: *Machine, self: *PrinDriver) MachineError!machine.WorkProgress {
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
                if (evaluator.unit.inherited.console) |console| {
                    console.writeOutput(encoded, false) catch
                        return evaluator.fail(.io, "standard output write failed");
                    break :completed .completed;
                }
                const output = evaluator.unit.output.?;
                output.writeAll(encoded) catch
                    return evaluator.fail(.io, "standard output write failed");
                output.flush() catch
                    return evaluator.fail(.io, "standard output flush failed");
                break :completed .completed;
            },
        };
    }
};
fn args(evaluator: *Machine) MachineError!void {
    try evaluator.pushBorrowed(evaluator.unit.arguments);
}
fn exit(evaluator: *Machine) MachineError!void {
    var status = try evaluator.popValue();
    defer status.deinit();
    if (status.borrow() != .int or status.borrow().int < 0 or status.borrow().int > 255) {
        return evaluator.typeError("an exit status from 0 through 255");
    }
    if (!evaluator.unit.is_root_unit or evaluator.unit.inAttempt()) {
        return evaluator.fail(.domain, "exit is available only to the root unit outside attempt");
    }
    evaluator.unit.installParkRequest(.{ .close_scope = @intCast(status.borrow().int) });
}
