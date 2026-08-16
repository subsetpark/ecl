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
        .{ .name = "over", .primitive = over },
        .{ .name = "cons", .primitive = cons },
        .{ .name = "compose", .primitive = compose },
        .{ .name = "match", .primitive = match },
        .{ .name = "type", .primitive = typeWord },
        .{ .name = "str", .primitive = strWord },
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
fn over(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    try evaluator.pushBorrowed(items[items.len - 2]);
}
fn cons(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (collection.borrow() != .list) return evaluator.typeError("a list");
    var item = try evaluator.popValue();
    defer item.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    const values = try evaluator.allocator().alloc(Value, count + 1);
    errdefer evaluator.allocator().free(values);
    const state = try evaluator.allocator().create(ConcatDriver);
    state.* = ConcatDriver.init(evaluator.allocator(), .cons, item.borrow(), collection.borrow(), values);
    _ = item.take();
    _ = collection.take();
    evaluator.installWorkDriver(state);
}
fn compose(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    if (left.borrow() != .list or right.borrow() != .list) return evaluator.typeError("two lists");
    const left_len: usize = @intCast(left.borrow().list.length());
    const right_len: usize = @intCast(right.borrow().list.length());
    const values = try evaluator.allocator().alloc(Value, left_len + right_len);
    errdefer evaluator.allocator().free(values);
    const state = try evaluator.allocator().create(ConcatDriver);
    state.* = ConcatDriver.init(evaluator.allocator(), .compose, left.borrow(), right.borrow(), values);
    _ = left.take();
    _ = right.take();
    evaluator.installWorkDriver(state);
}

const ConcatDriver = struct {
    mode: enum { cons, compose },
    left: Value,
    right: Value,
    values: []Value,
    index: usize = 0,
    materializing: bool = false,
    materializer: kernel_storage.ValueMaterializer,

    fn init(
        allocator: std.mem.Allocator,
        mode: @FieldType(ConcatDriver, "mode"),
        left: Value,
        right: Value,
        values: []Value,
    ) ConcatDriver {
        return .{
            .mode = mode,
            .left = left,
            .right = right,
            .values = values,
            .materializer = .init(allocator, values),
        };
    }

    pub fn advance(evaluator: *Machine, self: *ConcatDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget = machine.kernel_poll_quantum;
        while (!self.materializing and budget != 0 and self.index != self.values.len) : (budget -= 1) {
            self.values[self.index] = switch (self.mode) {
                .cons => if (self.index == 0)
                    self.left
                else
                    list.atUnchecked(self.right, self.index - 1),
                .compose => blk: {
                    const left_len: usize = @intCast(self.left.list.length());
                    break :blk if (self.index < left_len)
                        list.atUnchecked(self.left, self.index)
                    else
                        list.atUnchecked(self.right, self.index - left_len);
                },
            };
            self.index += 1;
        }
        if (self.index != self.values.len) return .yielded;
        self.materializing = true;
        if (budget == 0) return .yielded;
        return switch (try self.materializer.advance(budget)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *ConcatDriver) void {
        self.materializer.retire(releases);
        allocator.free(self.values);
        releases.releaseValue(self.left);
        releases.releaseValue(self.right);
        allocator.destroy(self);
    }
};
fn match(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const state = try evaluator.allocator().create(MatchDriver);
    errdefer evaluator.allocator().destroy(state);
    state.* = .{
        .left = left.borrow(),
        .right = right.borrow(),
        .cursor = try .init(evaluator.allocator(), left.borrow(), right.borrow()),
    };
    _ = left.take();
    _ = right.take();
    evaluator.installWorkDriver(state);
}

const MatchDriver = struct {
    left: Value,
    right: Value,
    cursor: equal.MatchCursor,

    pub fn advance(evaluator: *Machine, self: *MatchDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |matches| .{ .output = .{ .int = @intFromBool(matches) } },
        };
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *MatchDriver) void {
        self.cursor.deinit();
        releases.releaseValue(self.left);
        releases.releaseValue(self.right);
        allocator.destroy(self);
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
fn strWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const state = try evaluator.allocator().create(StrDriver);
    errdefer evaluator.allocator().destroy(state);
    state.* = .{ .item = item.borrow(), .render = try .init(evaluator.allocator(), item.borrow()) };
    _ = item.take();
    evaluator.installWorkDriver(state);
}

const StrDriver = struct {
    item: Value,
    render: printer.OwnedStringCursor,
    rendered: ?[]u8 = null,
    utf8: ?kernel_storage.Utf8Materializer = null,

    pub fn advance(evaluator: *Machine, self: *StrDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.utf8 == null) switch (try self.render.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |bytes| {
                self.rendered = bytes;
                self.utf8 = .init(evaluator.allocator(), bytes);
                return .yielded;
            },
        };
        return switch (self.utf8.?.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => unreachable,
        }) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *StrDriver) void {
        if (self.utf8) |*utf8| utf8.retire(releases);
        if (self.rendered) |bytes| allocator.free(bytes);
        self.render.deinit();
        releases.releaseValue(self.item);
        allocator.destroy(self);
    }
};

fn parse(evaluator: *Machine) MachineError!void {
    var source_value = try evaluator.popValue();
    defer source_value.deinit();
    if (!source_value.borrow().isString()) return evaluator.typeError("a string");
    const driver = try evaluator.allocator().create(ParseDriver);
    driver.* = .{
        .source_value = source_value.borrow(),
        .encoder = .init(evaluator.allocator(), source_value.borrow()),
    };
    _ = source_value.take();
    evaluator.installWorkDriver(driver);
}
const ParseDriver = struct {
    source_value: Value,
    encoder: kernel_storage.ToUtf8Cursor,
    source: ?[]u8 = null,
    pub fn advance(evaluator: *Machine, self: *ParseDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.source == null) switch (self.encoder.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |source| self.source = source,
        };
        const source = self.source.?;
        self.source = null;
        evaluator.detachWorkDriver(self);
        ParseDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
        evaluator.parseSourceOwned(source) catch |err| {
            evaluator.allocator().free(source);
            return err;
        };
        return .detached;
    }
    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *ParseDriver) void {
        if (self.source) |source| allocator.free(source);
        self.encoder.deinit();
        releases.releaseValue(self.source_value);
        allocator.destroy(self);
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
    errdefer evaluator.allocator().free(pairs);
    const driver = try evaluator.allocator().create(DictOfDriver);
    driver.* = .{ .entries = entries.take(), .pairs = pairs };
    evaluator.installWorkDriver(driver);
}

const DictOfDriver = struct {
    entries: Value,
    pairs: []dict.Pair,
    index: usize = 0,
    materializer: ?kernel_storage.DictMaterializer = null,

    pub fn advance(evaluator: *Machine, self: *DictOfDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.materializer == null) {
            const end = @min(self.index + machine.kernel_poll_quantum, self.pairs.len);
            while (self.index != end) : (self.index += 1) self.pairs[self.index] = .{
                list.atUnchecked(self.entries, self.index * 2),
                list.atUnchecked(self.entries, self.index * 2 + 1),
            };
            if (self.index != self.pairs.len) return .yielded;
            self.materializer = try .init(evaluator.allocator(), self.pairs, true);
            return .yielded;
        }
        return switch (try self.materializer.?.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .duplicate_key => evaluator.fail(.domain, "dict-of received a duplicate key"),
            .complete => |dictionary| .{ .output = dictionary },
        };
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *DictOfDriver) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        allocator.free(self.pairs);
        releases.releaseValue(self.entries);
        allocator.destroy(self);
    }
};
fn attempt(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    try evaluator.attemptOwned(try takeQuotation(evaluator, &quotation));
}
fn raise(evaluator: *Machine) MachineError!void {
    var raised = try evaluator.popValue();
    defer raised.deinit();
    if (raised.borrow() != .dict) return evaluator.typeError("an error dict");
    const driver = try evaluator.allocator().create(RaiseDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .raised = raised.take(),
        .keys = .{
            try intern.intern("kind"),
            try intern.intern("msg"),
            try intern.intern("word"),
            try intern.intern("trace"),
            try intern.intern("data"),
        },
    };
    evaluator.installWorkDriver(driver);
}
const RaiseDriver = struct {
    raised: ?Value,
    keys: [5]u32,
    field_index: usize = 0,
    lookup: ?kernel_storage.DictFindCursor = null,
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
                if (self.lookup == null) self.lookup = .initHeader(
                    evaluator.allocator(),
                    self.raised.?.dict,
                    .{ .symbol = self.keys[self.field_index] },
                );
                switch (try self.lookup.?.advance(machine.kernel_poll_quantum)) {
                    .pending => return .yielded,
                    .complete => |found| {
                        self.lookup.?.deinit();
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
                const raised = self.raised.?;
                self.raised = null;
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
    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *RaiseDriver) void {
        if (self.lookup) |*lookup| lookup.deinit();
        if (self.raised) |raised| releases.releaseValue(raised);
        allocator.destroy(self);
    }
};
fn pp(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (evaluator.unit.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const state = try evaluator.allocator().create(PpDriver);
    errdefer evaluator.allocator().destroy(state);
    state.* = .{ .item = item.borrow(), .render = try .init(evaluator.allocator(), item.borrow()) };
    _ = item.take();
    evaluator.installWorkDriver(state);
}

const PpDriver = struct {
    item: Value,
    render: printer.OwnedStringCursor,

    pub fn advance(evaluator: *Machine, self: *PpDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.render.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |rendered| completed: {
                defer evaluator.allocator().free(rendered);
                if (evaluator.unit.console) |console| {
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

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *PpDriver) void {
        self.render.deinit();
        releases.releaseValue(self.item);
        allocator.destroy(self);
    }
};

fn prin(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (!item.borrow().isString()) return evaluator.typeError("a string");
    if (evaluator.unit.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const state = try evaluator.allocator().create(PrinDriver);
    state.* = .{ .item = item.borrow(), .encoder = .init(evaluator.allocator(), item.borrow()) };
    _ = item.take();
    evaluator.installWorkDriver(state);
}

const PrinDriver = struct {
    item: Value,
    encoder: kernel_storage.StringEncoder,

    pub fn advance(evaluator: *Machine, self: *PrinDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.encoder.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "string contains an invalid Unicode scalar",
            ),
        }) {
            .pending => .yielded,
            .complete => |encoded| completed: {
                defer evaluator.allocator().free(encoded);
                if (evaluator.unit.console) |console| {
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

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *PrinDriver) void {
        self.encoder.deinit();
        releases.releaseValue(self.item);
        allocator.destroy(self);
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
fn takeQuotation(evaluator: *Machine, item: *heap.OwnedValue) MachineError!*value.ListHandle {
    if (item.borrow() != .list) return evaluator.typeError("a quotation/list");
    return item.take().list;
}
