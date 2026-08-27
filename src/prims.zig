//! Stack/control primitives and the installer for the closed kernel surface.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const intern = @import("intern.zig");
const lexer = @import("lexer.zig");
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
        .{ .name = "match?", .primitive = match },
        .{ .name = "type", .primitive = typeWord },
        .{ .name = "execute", .primitive = execute },
        .{ .name = "parse", .primitive = parse },
        .{ .name = "parse-int", .primitive = parseInt },
        .{ .name = "parse-float", .primitive = parseFloat },
        .{ .name = "@attempt", .primitive = attempt },
        .{ .name = "unseed", .primitive = unseedWord },
        .{ .name = "raise", .primitive = raise },
        .{ .name = "args", .primitive = args },
        .{ .name = "exit", .primitive = exit },
        .{ .name = "getenv", .primitive = getenv },
        .{ .name = "_ll", .primitive = bindLocals },
        .{ .name = "_gl", .primitive = readLocal },
        .{ .name = "_dl", .primitive = unbindLocals },
    };
    try core.installBuiltins(definitions);
    try combinators.install(core);
    try kernels.install(core);
    try module_prims.install(core);
    try task_prims.install(core);
}
/// Head-binder backend: `_ll` loads locals, `_gl` gets one, `_dl` drops them.
/// The reader lowers `|a b|` into these three, and they are reserved binding
/// names so a session definition cannot change what a local read means. The
/// underscore marks them as the reader's, not a vocabulary anyone writes by
/// hand, and keeps three ordinary words out of the reservation. They move values between the operand stack and the unit's
/// locals, which is storage the reader alone addresses: every index the three
/// ever see was computed by the binder from names it had already resolved.
fn bindLocals(evaluator: *Machine) MachineError!void {
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    if (count_value.borrow() != .int) return evaluator.typeError("an integer local count");
    if (count_value.borrow().int < 0) return evaluator.fail(.domain, "_ll count is negative");
    const count = std.math.cast(usize, count_value.borrow().int) orelse
        return evaluator.fail(.domain, "_ll count is out of range");
    try evaluator.require(count);
    return evaluator.bindLocals(count);
}

fn readLocal(evaluator: *Machine) MachineError!void {
    var index_value = try evaluator.popValue();
    defer index_value.deinit();
    if (index_value.borrow() != .int) return evaluator.typeError("an integer _gl index");
    if (index_value.borrow().int < 0) return evaluator.fail(.domain, "_gl index is negative");
    const index = std.math.cast(usize, index_value.borrow().int) orelse
        return evaluator.fail(.domain, "_gl index is out of bounds");
    if (index >= evaluator.localDepth())
        return evaluator.fail(.domain, "_gl index is out of bounds");
    return evaluator.readLocal(index);
}

fn unbindLocals(evaluator: *Machine) MachineError!void {
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    if (count_value.borrow() != .int) return evaluator.typeError("an integer local count");
    if (count_value.borrow().int < 0) return evaluator.fail(.domain, "un_ll count is negative");
    const count = std.math.cast(usize, count_value.borrow().int) orelse
        return evaluator.fail(.domain, "un_ll count is out of range");
    if (count > evaluator.localDepth())
        return evaluator.fail(.domain, "un_ll count exceeds the live locals");
    evaluator.unbindLocals(count);
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
    materializer: heap.Owned(list.ValueMaterializer),

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
    // Only a list against a list or a dict against a dict has structure to
    // walk; every other pair is one comparison, which the cursor would reach
    // after allocating a worklist and a driver to hold it.
    if (equal.matchWithoutStructure(left.borrow(), right.borrow())) |matches| {
        return evaluator.pushOwned(.{ .int = @intFromBool(matches) });
    }
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
        .module => "module",
        .unit_plan => "unit-plan",
    };
    try evaluator.pushOwned(.{ .symbol = try intern.intern(spelling) });
}
fn execute(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const word = switch (item.borrow()) {
        .word => |word| word,
        else => return evaluator.typeError("a word"),
    };
    try evaluator.executeWord(word);
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
        evaluator.retireDriver(self);
        try evaluator.parseSourceOwned(source);
        return .detached;
    }
};

const NumericParseTarget = enum { integer, float };

fn parseInt(evaluator: *Machine) MachineError!void {
    return startNumericParse(evaluator, .integer);
}

fn parseFloat(evaluator: *Machine) MachineError!void {
    return startNumericParse(evaluator, .float);
}

fn startNumericParse(evaluator: *Machine, target: NumericParseTarget) MachineError!void {
    var source_value = try evaluator.popString();
    defer source_value.deinit();
    const source = source_value.borrow();
    if (source.list.kind() != .leaf_char1) return invalidNumericText(evaluator, target);
    const length: usize = @intCast(source.list.length());
    const bytes = heap.chars8(source.list)[0..length];
    try evaluator.startDriver(NumericParseDriver{
        .source_value = .init(source_value.take()),
        .classifier = .init(bytes),
        .target = target,
    });
}

fn invalidNumericText(evaluator: *Machine, target: NumericParseTarget) MachineError {
    return switch (target) {
        .integer => evaluator.fail(.parse, "parse-int expects an integer literal"),
        .float => evaluator.fail(.parse, "parse-float expects a numeric literal"),
    };
}

const NumericParseDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    source_value: heap.Owned(Value),
    classifier: lexer.ClassifyCursor,
    target: NumericParseTarget,

    pub fn advance(evaluator: *Machine, self: *NumericParseDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.classifier.advance()) {
            .pending => {},
            .complete => |classification| return self.finish(evaluator, classification),
        };
        return .yielded;
    }

    fn finish(
        self: *NumericParseDriver,
        evaluator: *Machine,
        classification: lexer.Classification,
    ) MachineError!machine.WorkProgress {
        return switch (classification) {
            .int => |number| switch (self.target) {
                .integer => .{ .output = .{ .int = number } },
                .float => .{ .output = .{ .float = @floatFromInt(number) } },
            },
            .float => |number| switch (self.target) {
                .integer => invalidNumericText(evaluator, self.target),
                .float => .{ .output = .{ .float = number } },
            },
            .word => invalidNumericText(evaluator, self.target),
            .out_of_range => switch (self.target) {
                .integer => evaluator.fail(.overflow, "parse-int result is outside int64"),
                .float => evaluator.fail(.overflow, "parse-float input is outside the ECL numeric range"),
            },
        };
    }
};
fn attempt(evaluator: *Machine) MachineError!void {
    var input = try evaluator.popUnitInput();
    defer input.deinit(evaluator.releaseDomain());
    try evaluator.attemptOwned(input.move());
}
/// The metaprogramming escape hatch: the exact two values a plan holds, so a
/// program can transform either one and seal the result into another plan.
/// Whether the transformed body is still module text is then answered the same
/// way it is for any other value — by whether the reader wrote it.
fn unseedWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const plan = switch (item.borrow()) {
        .unit_plan => |handle| handle,
        else => return evaluator.typeError("a unit plan"),
    };
    var reservation = try evaluator.reserveStack(2);
    reservation.pushBorrowed(.{ .list = heap.unitPlanSeeds(plan) });
    reservation.pushBorrowed(.{ .list = heap.unitPlanBody(plan) });
    std.debug.assert(reservation.complete());
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
    lookup: ?heap.Owned(dict.FindCursor) = null,
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
pub fn ioPp(evaluator: *Machine) MachineError!void {
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

pub fn ioStack(evaluator: *Machine) MachineError!void {
    if (evaluator.unit.inherited.console == null and evaluator.unit.output == null)
        return evaluator.fail(.io, "standard output is unavailable");
    const count = evaluator.available();
    if (count == 0) return;
    try evaluator.startDriver(StackDisplayDriver{
        .count = count,
    });
}

const StackDisplayDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    count: usize,
    index: usize = 0,
    render: ?heap.Owned(printer.OwnedStringCursor) = null,
    rendered: ?heap.Owned([]u8) = null,
    prefix_written: bool = false,
    written: usize = 0,

    pub fn advance(evaluator: *Machine, self: *StackDisplayDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        std.debug.assert(evaluator.available() == self.count);

        var prefix_buffer: [64]u8 = undefined;
        const prefix = stackDisplayPrefix(&prefix_buffer, self.index);
        if (self.rendered == null) {
            if (self.render == null) {
                self.render = .init(try printer.OwnedStringCursor.initDisplayAtColumn(
                    evaluator.allocator(),
                    evaluator.visibleOperandBorrowed(self.index),
                    prefix.len,
                ));
            }
            switch (try self.render.?.borrowMut().advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |text| {
                    self.render.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.render = null;
                    self.rendered = .init(text);
                    return .yielded;
                },
            }
        }

        if (!self.prefix_written) {
            try writeStackDisplayChunk(evaluator, prefix, false);
            self.prefix_written = true;
            return .yielded;
        }

        const text = self.rendered.?.borrow();
        const end = @min(self.written + 256, text.len);
        const complete = end == text.len;
        try writeStackDisplayChunk(evaluator, text[self.written..end], complete);
        self.written = end;
        if (!complete) return .yielded;

        self.rendered.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
        self.rendered = null;
        self.prefix_written = false;
        self.written = 0;
        self.index += 1;
        return if (self.index == self.count) .completed else .yielded;
    }
};

fn stackDisplayPrefix(buffer: *[64]u8, index: usize) []const u8 {
    var fixed = std.Io.Writer.fixed(buffer);
    fixed.print("[{d}] ", .{index}) catch unreachable;
    return fixed.buffered();
}

fn writeStackDisplayChunk(
    evaluator: *Machine,
    bytes: []const u8,
    newline: bool,
) MachineError!void {
    if (evaluator.unit.inherited.console) |console| {
        console.writeOutput(bytes, newline) catch
            return evaluator.fail(.io, "standard output write failed");
        return;
    }
    const output = evaluator.unit.output.?;
    if (bytes.len != 0)
        output.writeAll(bytes) catch
            return evaluator.fail(.io, "standard output write failed");
    if (newline) {
        output.writeByte('\n') catch
            return evaluator.fail(.io, "standard output write failed");
        output.flush() catch
            return evaluator.fail(.io, "standard output flush failed");
    }
}

pub fn ioPrin(evaluator: *Machine) MachineError!void {
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
/// Reads one whole UTF-8 file. The path decodes through the ordinary
/// resumable encoder before the read driver owns the byte slice.
pub fn ioSlurp(evaluator: *Machine) MachineError!void {
    var path_value = try evaluator.popValue();
    defer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string path");
    const encoder = kernel_storage.ToUtf8Cursor.init(evaluator.allocator(), path_value.borrow());
    try evaluator.startDriver(SlurpDriver{
        .path_value = .init(path_value.take()),
        .encoder = .init(encoder),
    });
}

const SlurpDriver = machine.PathActionDriver(Machine.slurpFileOwned);

/// Writes one whole file by truncate-and-replace. Both the contents and the
/// path encode to bytes before the write driver takes ownership, so a
/// non-encodable argument fails before the target file is touched.
pub fn ioSpit(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var path_value = try evaluator.popValue();
    errdefer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string path");
    var contents_value = try evaluator.popValue();
    errdefer contents_value.deinit();
    if (!contents_value.borrow().isString()) return evaluator.typeError("a string to write");
    const contents_encoder = kernel_storage.StringEncoder.init(
        evaluator.allocator(),
        contents_value.borrow(),
    );
    const path_encoder = kernel_storage.ToUtf8Cursor.init(
        evaluator.allocator(),
        path_value.borrow(),
    );
    try evaluator.startDriver(SpitDriver{
        .path_value = .init(path_value.take()),
        .contents_value = .init(contents_value.take()),
        .contents_encoder = .init(contents_encoder),
        .path_encoder = .init(path_encoder),
    });
}

const SpitDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    path_value: heap.Owned(Value),
    contents_value: heap.Owned(Value),
    contents_encoder: heap.Owned(kernel_storage.StringEncoder),
    path_encoder: heap.Owned(kernel_storage.ToUtf8Cursor),
    contents: ?heap.Owned([]u8) = null,
    path: ?heap.Owned([]u8) = null,

    pub fn advance(evaluator: *Machine, self: *SpitDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.contents == null) switch (self.contents_encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |contents| self.contents = .init(contents),
        };
        if (self.path == null) switch (self.path_encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "path contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| self.path = .init(path),
        };
        const path = self.path.?.take();
        const contents = self.contents.?.take();
        const path_value = self.path_value.take();
        self.path = null;
        self.contents = null;
        evaluator.retireDriver(self);
        try evaluator.writeFileOwned(path, path_value, contents);
        return .detached;
    }
};

/// Reads one variable from the immutable session environ snapshot. An unset
/// variable is an error, not an empty string: absence is absence, and
/// `@attempt`/`result.or-else` is the defaulting idiom.
fn getenv(evaluator: *Machine) MachineError!void {
    var name_value = try evaluator.popValue();
    defer name_value.deinit();
    if (!name_value.borrow().isString()) return evaluator.typeError("a string variable name");
    const encoder = kernel_storage.ToUtf8Cursor.init(evaluator.allocator(), name_value.borrow());
    try evaluator.startDriver(GetenvDriver{
        .name_value = .init(name_value.take()),
        .encoder = .init(encoder),
    });
}

const GetenvDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    name_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.ToUtf8Cursor),
    name: ?heap.Owned([]u8) = null,
    lookup: ?machine.Environ.LookupCursor = null,
    text: ?heap.Owned(kernel_storage.Utf8Materializer) = null,

    pub fn advance(evaluator: *Machine, self: *GetenvDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.name == null) switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "variable name contains an invalid Unicode scalar",
            ),
        }) {
            .pending => return .yielded,
            .complete => |name| self.name = .init(name),
        };
        if (self.text == null) {
            if (self.lookup == null)
                self.lookup = evaluator.environLookup(self.name.?.borrow());
            switch (self.lookup.?.advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |found| {
                    const bytes = found orelse return evaluator.unsetEnvironVariable(
                        self.name.?.borrow(),
                        self.name_value.borrow(),
                    );
                    self.text = .init(.init(evaluator.allocator(), bytes));
                    return .yielded;
                },
            }
        }
        return switch (self.text.?.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return evaluator.fail(
                .io,
                "environment variable value is not valid UTF-8",
            ),
        }) {
            .pending => .yielded,
            .complete => |text| .{ .output = text },
        };
    }
};

/// Reads the whole standard input stream once. The gate lives in the machine
/// so the CLI mode that owns stdin as program source cannot be raced.
pub fn ioStdin(evaluator: *Machine) MachineError!void {
    return evaluator.readStandardInputOwned();
}

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
        return evaluator.fail(.domain, "exit is available only to the root unit outside @attempt");
    }
    try evaluator.park(.{ .close_scope = @intCast(status.borrow().int) });
}
