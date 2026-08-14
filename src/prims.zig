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
    const item = try evaluator.popOwned();
    heap.releaseValue(evaluator.allocator(), item);
}
fn over(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    try evaluator.pushBorrowed(items[items.len - 2]);
}
fn cons(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const item = try evaluator.popOwned();
    var item_owned = true;
    defer if (item_owned) heap.releaseValue(evaluator.allocator(), item);
    const count: usize = @intCast(collection.list.length());
    const values = try evaluator.allocator().alloc(Value, count + 1);
    errdefer evaluator.allocator().free(values);
    const state = try evaluator.allocator().create(ConcatDriver);
    state.* = ConcatDriver.init(evaluator.allocator(), .cons, item, collection, values);
    item_owned = false;
    collection_owned = false;
    evaluator.installWorkDriver(state, ConcatDriver.advance, ConcatDriver.destroy);
}
fn compose(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);
    if (left != .list or right != .list) return evaluator.typeError("two lists");
    const left_len: usize = @intCast(left.list.length());
    const right_len: usize = @intCast(right.list.length());
    const values = try evaluator.allocator().alloc(Value, left_len + right_len);
    errdefer evaluator.allocator().free(values);
    const state = try evaluator.allocator().create(ConcatDriver);
    state.* = ConcatDriver.init(evaluator.allocator(), .compose, left, right, values);
    left_owned = false;
    right_owned = false;
    evaluator.installWorkDriver(state, ConcatDriver.advance, ConcatDriver.destroy);
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

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ConcatDriver = @ptrCast(@alignCast(raw));
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
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ConcatDriver = @ptrCast(@alignCast(raw));
        self.materializer.deinit();
        allocator.free(self.values);
        heap.releaseValue(allocator, self.left);
        heap.releaseValue(allocator, self.right);
        allocator.destroy(self);
    }
};
fn match(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);
    const state = try evaluator.allocator().create(MatchDriver);
    errdefer evaluator.allocator().destroy(state);
    state.* = .{ .left = left, .right = right, .cursor = try .init(evaluator.allocator(), left, right) };
    left_owned = false;
    right_owned = false;
    evaluator.installWorkDriver(state, MatchDriver.advance, MatchDriver.destroy);
}

const MatchDriver = struct {
    left: Value,
    right: Value,
    cursor: equal.MatchCursor,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *MatchDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (try self.cursor.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |matches| completed: {
                try evaluator.pushOwned(.{ .int = @intFromBool(matches) });
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *MatchDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        heap.releaseValue(allocator, self.left);
        heap.releaseValue(allocator, self.right);
        allocator.destroy(self);
    }
};
fn typeWord(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const spelling: []const u8 = switch (item) {
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
    const item = try evaluator.popOwned();
    var item_owned = true;
    defer if (item_owned) heap.releaseValue(evaluator.allocator(), item);
    const state = try evaluator.allocator().create(StrDriver);
    errdefer evaluator.allocator().destroy(state);
    state.* = .{ .item = item, .render = try .init(evaluator.allocator(), item) };
    item_owned = false;
    evaluator.installWorkDriver(state, StrDriver.advance, StrDriver.destroy);
}

const StrDriver = struct {
    item: Value,
    render: printer.OwnedStringCursor,
    rendered: ?[]u8 = null,
    utf8: ?kernel_storage.Utf8Materializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *StrDriver = @ptrCast(@alignCast(raw));
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
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *StrDriver = @ptrCast(@alignCast(raw));
        if (self.utf8) |*utf8| utf8.deinit();
        if (self.rendered) |bytes| allocator.free(bytes);
        self.render.deinit();
        heap.releaseValue(allocator, self.item);
        allocator.destroy(self);
    }
};

fn parse(evaluator: *Machine) MachineError!void {
    const source_value = try evaluator.popOwned();
    if (!source_value.isString()) {
        heap.releaseValue(evaluator.allocator(), source_value);
        return evaluator.typeError("a string");
    }
    errdefer heap.releaseValue(evaluator.allocator(), source_value);
    const driver = try evaluator.allocator().create(ParseDriver);
    driver.* = .{
        .source_value = source_value,
        .encoder = .init(evaluator.allocator(), source_value),
    };
    evaluator.installWorkDriver(driver, ParseDriver.advance, ParseDriver.destroy);
}
const ParseDriver = struct {
    source_value: Value,
    encoder: kernel_storage.ToUtf8Cursor,
    source: ?[]u8 = null,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ParseDriver = @ptrCast(@alignCast(raw));
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
        evaluator.unit.work_driver = null;
        ParseDriver.destroy(evaluator.allocator(), self);
        evaluator.parseSourceOwned(source) catch |err| {
            evaluator.allocator().free(source);
            return err;
        };
        return .detached;
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ParseDriver = @ptrCast(@alignCast(raw));
        if (self.source) |source| allocator.free(source);
        self.encoder.deinit();
        heap.releaseValue(allocator, self.source_value);
        allocator.destroy(self);
    }
};
fn dictOf(evaluator: *Machine) MachineError!void {
    const entries = try evaluator.popOwned();
    var entries_owned = true;
    defer if (entries_owned) heap.releaseValue(evaluator.allocator(), entries);
    if (entries != .list) return evaluator.typeError("a flat key/value list");
    const count: usize = @intCast(entries.list.length());
    if (count % 2 != 0) {
        return evaluator.fail(.contract, "dict-of requires an even-length key/value list");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count / 2);
    errdefer evaluator.allocator().free(pairs);
    const driver = try evaluator.allocator().create(DictOfDriver);
    driver.* = .{ .entries = entries, .pairs = pairs };
    entries_owned = false;
    evaluator.installWorkDriver(driver, DictOfDriver.advance, DictOfDriver.destroy);
}

const DictOfDriver = struct {
    entries: Value,
    pairs: []dict.Pair,
    index: usize = 0,
    materializer: ?kernel_storage.DictMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *DictOfDriver = @ptrCast(@alignCast(raw));
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
            .complete => |dictionary| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), dictionary);
                try evaluator.pushOwned(dictionary);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *DictOfDriver = @ptrCast(@alignCast(raw));
        if (self.materializer) |*materializer| materializer.deinit();
        allocator.free(self.pairs);
        heap.releaseValue(allocator, self.entries);
        allocator.destroy(self);
    }
};
fn attempt(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    try evaluator.attemptOwned(try quotationHeader(evaluator, quotation));
}
fn raise(evaluator: *Machine) MachineError!void {
    const raised = try evaluator.popOwned();
    if (raised != .dict) {
        heap.releaseValue(evaluator.allocator(), raised);
        return evaluator.typeError("an error dict");
    }
    var owned = true;
    defer if (owned) heap.releaseValue(evaluator.allocator(), raised);
    const driver = try evaluator.allocator().create(RaiseDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .raised = raised,
        .keys = .{
            try intern.intern("kind"),
            try intern.intern("msg"),
            try intern.intern("word"),
            try intern.intern("trace"),
            try intern.intern("data"),
        },
    };
    owned = false;
    evaluator.installWorkDriver(driver, RaiseDriver.advance, RaiseDriver.destroy);
}
const RaiseDriver = struct {
    raised: Value,
    keys: [5]u32,
    field_index: usize = 0,
    lookup: ?kernel_storage.DictFindCursor = null,
    trace: ?Value = null,
    trace_index: usize = 0,
    transferred: bool = false,
    phase: enum { lookup, trace, finish } = .lookup,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *RaiseDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        switch (self.phase) {
            .lookup => {
                if (self.field_index == self.keys.len) {
                    self.phase = .finish;
                    return .yielded;
                }
                if (self.lookup == null) self.lookup = .initHeader(
                    evaluator.allocator(),
                    self.raised.dict,
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
                self.transferred = true;
                return evaluator.raiseOwned(self.raised);
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
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *RaiseDriver = @ptrCast(@alignCast(raw));
        if (self.lookup) |*lookup| lookup.deinit();
        if (!self.transferred) heap.releaseValue(allocator, self.raised);
        allocator.destroy(self);
    }
};
fn pp(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    var item_owned = true;
    defer if (item_owned) heap.releaseValue(evaluator.allocator(), item);
    if (evaluator.unit.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const state = try evaluator.allocator().create(PpDriver);
    errdefer evaluator.allocator().destroy(state);
    state.* = .{ .item = item, .render = try .init(evaluator.allocator(), item) };
    item_owned = false;
    evaluator.installWorkDriver(state, PpDriver.advance, PpDriver.destroy);
}

const PpDriver = struct {
    item: Value,
    render: printer.OwnedStringCursor,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *PpDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (try self.render.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |rendered| completed: {
                defer evaluator.allocator().free(rendered);
                var locked = if (evaluator.unit.console) |console| console.lockOutput() else null;
                defer if (locked) |*lease| lease.deinit();
                const output = if (locked) |*lease| lease.writer else evaluator.unit.output.?;
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

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *PpDriver = @ptrCast(@alignCast(raw));
        self.render.deinit();
        heap.releaseValue(allocator, self.item);
        allocator.destroy(self);
    }
};

fn prin(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    var item_owned = true;
    defer if (item_owned) heap.releaseValue(evaluator.allocator(), item);
    if (!item.isString()) return evaluator.typeError("a string");
    if (evaluator.unit.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const state = try evaluator.allocator().create(PrinDriver);
    state.* = .{ .item = item, .encoder = .init(evaluator.allocator(), item) };
    item_owned = false;
    evaluator.installWorkDriver(state, PrinDriver.advance, PrinDriver.destroy);
}

const PrinDriver = struct {
    item: Value,
    encoder: kernel_storage.StringEncoder,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *PrinDriver = @ptrCast(@alignCast(raw));
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
                var locked = if (evaluator.unit.console) |console| console.lockOutput() else null;
                defer if (locked) |*lease| lease.deinit();
                const output = if (locked) |*lease| lease.writer else evaluator.unit.output.?;
                output.writeAll(encoded) catch
                    return evaluator.fail(.io, "standard output write failed");
                output.flush() catch
                    return evaluator.fail(.io, "standard output flush failed");
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *PrinDriver = @ptrCast(@alignCast(raw));
        self.encoder.deinit();
        heap.releaseValue(allocator, self.item);
        allocator.destroy(self);
    }
};
fn args(evaluator: *Machine) MachineError!void {
    try evaluator.pushBorrowed(evaluator.unit.arguments);
}
fn exit(evaluator: *Machine) MachineError!void {
    const status = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), status);
    if (status != .int or status.int < 0 or status.int > 255) {
        return evaluator.typeError("an exit status from 0 through 255");
    }
    if (!evaluator.unit.is_root_unit or evaluator.unit.inAttempt()) {
        return evaluator.fail(.domain, "exit is available only to the root unit outside attempt");
    }
    std.debug.assert(evaluator.unit.park_request == null);
    evaluator.unit.park_request = .{ .close_scope = @intCast(status.int) };
}
fn quotationHeader(evaluator: *Machine, item: Value) MachineError!*value.Header {
    return switch (item) {
        .list => |header| header,
        .int, .float, .char, .symbol, .word, .dict, .task => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a quotation/list");
        },
    };
}
