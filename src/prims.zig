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
const test_prims = @import("test_prims.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "dup", .primitive = dup, .effect = "x -- x x", .doc = "Duplicate the top stack value." },
        .{ .name = "swap", .primitive = swap, .effect = "x y -- y x", .doc = "Exchange the top two stack values." },
        .{ .name = "pop", .primitive = pop, .effect = "x --", .doc = "Discard the top stack value." },
        .{ .name = "stack", .primitive = stack, .effect = null, .doc = "Copy the visible operand stack into a bottom-to-top list while leaving every original value in place." },
        .{ .name = "cons", .primitive = cons, .effect = "value list -- list", .doc = "Prepend a value or executable form to a list." },
        .{ .name = "match?", .primitive = match, .effect = "left right -- bool", .doc = "Return whether two complete values are structurally equal." },
        .{ .name = "type", .primitive = typeWord, .effect = "value -- type", .doc = "Return the value kind as a symbol." },
        .{ .name = "execute", .primitive = execute, .effect = "word -- ...", .doc = "Execute a word through ordinary name resolution and dispatch." },
        .{ .name = "parse", .primitive = parse, .effect = "string -- quotation", .doc = "Parse source text into an unevaluated quotation." },
        .{ .name = "chars", .primitive = chars, .effect = "value -- string", .doc = "Return a value's text content as a string: a string unchanged, a symbol or word spelling, " ++
            "a char as a one-element string, or a byte list decoded as UTF-8." },
        .{ .name = "bytes", .primitive = bytesWord, .effect = "value -- bytes", .doc = "Encode a string as UTF-8 into a byte list, or return a byte list unchanged." },
        .{ .name = "symbol", .primitive = symbolWord, .effect = "value -- symbol", .doc = "Return a symbol or word as a symbol, or the already-interned symbol a string spells; " ++
            "a spelling that was never interned is 'domain." },
        .{ .name = "intern", .primitive = internWord, .effect = "value -- symbol", .doc = "Return a symbol or word as a symbol, or create the symbol a string spells, growing the " ++
            "process-lifetime name table when it is new." },
        .{ .name = "int", .primitive = intWord, .effect = "value -- int", .doc = "Return an int unchanged, a char's codepoint, or the value of an integer-literal string." },
        .{ .name = "float", .primitive = floatWord, .effect = "value -- float", .doc = "Return a float unchanged, an int as a float, or the value of a numeric-literal string." },
        .{ .name = "char", .primitive = charWord, .effect = "value -- char", .doc = "Return a char unchanged, the char with an int's codepoint, or the single char of a one-char string." },
        .{ .name = "@attempt", .primitive = attempt, .effect = "values quotation -- result", .doc = "Run a body with an explicit initial stack in a fresh unit and return an ok or error result dictionary; observationally `@spawn await`." },
        .{ .name = "raise", .primitive = raise, .effect = "error --", .doc = "Raise a language error from an error dictionary." },
        .{ .name = "args", .primitive = args, .effect = "-- arguments", .doc = "Return the process arguments as a list of strings." },
        .{ .name = "exit", .primitive = exit, .effect = "status --", .doc = "Request root-session termination with the given exit status." },
        .{ .name = "getenv", .primitive = getenv, .effect = "name -- string", .doc = "Return an environment variable's value from the session snapshot." },
        .{ .name = "_ll", .primitive = bindLocals, .effect = "... n --", .doc = "Move the top n values into the head-binder locals, last name first. " ++
            "The reader emits this; write `|a b|` instead." },
        .{ .name = "_gl", .primitive = readLocal, .effect = "n -- x", .doc = "Copy head-binder local n, counting from the most recently bound name. " ++
            "The reader emits this; write the local's name instead." },
        .{ .name = "_dl", .primitive = unbindLocals, .effect = "n --", .doc = "Discard the top n head-binder locals. The reader emits this at the end " ++
            "of a binder body." },
    };
    try core.installBuiltins(&definitions);
    try combinators.install(core);
    try kernels.install(core);
    try module_prims.install(core);
    try task_prims.install(core);
    try test_prims.install(core);
}
/// Head-binder backend: `_ll` loads locals, `_gl` gets one, `_dl` drops them.
/// The reader lowers `|a b|` into these three, and they are reserved binding
/// names so a session definition cannot change what a local read means. The
/// underscore marks them as reader-internal vocabulary and keeps three ordinary
/// words out of the reservation. They move values between the operand stack and the unit's
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

/// A retained, bottom-to-top copy of the visible operand window. Capturing is
/// chunked because the window is user-sized, and the exact backing allocation
/// never relocates while a later cursor borrows it.
const StackSnapshot = struct {
    values: heap.OwnedValueBuffer,
    depth: usize,
    index: usize = 0,

    fn init(evaluator: *Machine) error{OutOfMemory}!StackSnapshot {
        const depth = evaluator.available();
        return .{
            .values = try .init(evaluator.releaseDomain(), depth),
            .depth = depth,
        };
    }

    fn advanceCapture(self: *StackSnapshot, evaluator: *Machine, budget: usize) bool {
        std.debug.assert(evaluator.available() == self.depth);
        const end = @min(self.index + budget, self.depth);
        while (self.index != end) : (self.index += 1)
            self.values.appendBorrowed(evaluator.visibleOperandBorrowed(self.index));
        return self.index == self.depth;
    }

    fn items(self: *const StackSnapshot) []const Value {
        std.debug.assert(self.index == self.depth);
        return self.values.values();
    }

    pub fn retire(self: *StackSnapshot, _: *heap.ReleaseDomain) void {
        self.values.deinit();
    }
};

fn stack(evaluator: *Machine) MachineError!void {
    try evaluator.startDriver(StackSnapshotDriver{
        .snapshot = .init(try .init(evaluator)),
    });
}

const StackSnapshotDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    snapshot: heap.Owned(StackSnapshot),
    materializer: ?heap.Owned(list.ValueMaterializer) = null,
    result: ?heap.Owned(Value) = null,

    pub fn advance(evaluator: *Machine, self: *StackSnapshotDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (!self.snapshot.borrowMut().advanceCapture(
            evaluator,
            machine.kernel_poll_quantum,
        )) return .yielded;

        if (self.materializer == null) {
            self.materializer = .init(.init(evaluator.allocator(), self.snapshot.borrow().items()));
            return .yielded;
        }
        if (self.result == null) switch (try self.materializer.?.borrowMut().advance(
            machine.kernel_poll_quantum,
        )) {
            .pending => return .yielded,
            .complete => |result| {
                self.result = .init(result);
                return .yielded;
            },
        };

        self.snapshot.deinit(evaluator.releaseDomain(), evaluator.allocator());
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }
};

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
        .port => "port",
        .module => "module",
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
    encoder: heap.Owned(kernel_storage.StringEncoder),
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

// ── Kind conversions ────────────────────────────────────────────────────────
//
// Each word names its target kind and accepts the documented source kinds;
// anything else is `'type`. Toward text one polymorphic word suffices
// (`chars`), because every source has one text content. Away from text the
// target must be named (`int`, `float`, `char`, `symbol`, `bytes`), because a
// string alone does not say what it should become. `str` stays the readable
// representation and `parse` the reader; neither is a conversion.

const chars_expected = "a string, symbol, word, char, or byte list";

fn chars(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .list => {
            if (item.borrow().isString()) return evaluator.pushOwned(item.take());
            const encoder = kernel_storage.ByteVectorEncoder.init(evaluator.allocator(), item.borrow());
            try evaluator.startDriver(BytesToCharsDriver{
                .source_value = .init(item.take()),
                .encoder = .init(encoder),
            });
        },
        .symbol => |id| try startSpellingChars(evaluator, id),
        .word => |word| try startSpellingChars(evaluator, word.name),
        .char => |codepoint| {
            const one = [_]u32{codepoint};
            try evaluator.pushOwned(try list.fromCodepoints(evaluator.allocator(), &one));
        },
        else => return evaluator.typeError(chars_expected),
    }
}

/// Spellings are process-lifetime bytes validated as UTF-8 when interned, so
/// the driver borrows them and owns only the string it builds.
fn startSpellingChars(evaluator: *Machine, id: u32) MachineError!void {
    try evaluator.startDriver(SpellingCharsDriver{
        .text = .init(.init(evaluator.allocator(), intern.get(id))),
    });
}

const SpellingCharsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    text: heap.Owned(kernel_storage.Utf8Materializer),

    pub fn advance(evaluator: *Machine, self: *SpellingCharsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.text.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return invalidUtf8(evaluator, "spelling is not valid UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |text| .{ .output = text },
        };
    }
};

fn invalidUtf8(evaluator: *Machine, message: []const u8) MachineError {
    const failure = evaluator.fail(.domain, message);
    evaluator.addErrorReason(.{ .symbol = intern.intern("invalid-utf8") catch return error.OutOfMemory });
    return failure;
}

const BytesToCharsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.ByteVectorEncoder),
    bytes: ?heap.Owned(kernel_storage.ByteVector) = null,
    text: ?heap.Owned(kernel_storage.Utf8Materializer) = null,

    pub fn advance(evaluator: *Machine, self: *BytesToCharsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.bytes == null) switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.typeError(chars_expected),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                self.bytes = .init(bytes);
                self.text = .init(.init(evaluator.allocator(), self.bytes.?.borrowMut().bytes()));
                return .yielded;
            },
        };
        return switch (self.text.?.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return invalidUtf8(evaluator, "byte list is not valid UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |text| .{ .output = text },
        };
    }
};

fn bytesWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (item.borrow() != .list) return evaluator.typeError("a string or byte list");
    if (item.borrow().isString()) {
        const encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), item.borrow());
        return evaluator.startDriver(StringBytesDriver{
            .source_value = .init(item.take()),
            .encoder = .init(encoder),
        });
    }
    const encoder = kernel_storage.ByteVectorEncoder.init(evaluator.allocator(), item.borrow());
    try evaluator.startDriver(ByteListIdentityDriver{
        .source_value = .init(item.take()),
        .encoder = .init(encoder),
    });
}

const StringBytesDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),
    encoded: ?heap.Owned([]u8) = null,
    materializer: ?heap.Owned(list.ByteListMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *StringBytesDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.encoded == null) switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |encoded| {
                self.encoded = .init(encoded);
                self.materializer = .init(.init(evaluator.allocator(), self.encoded.?.borrow()));
                return .yielded;
            },
        };
        return switch (try self.materializer.?.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }
};

/// A byte list is already bytes; the driver only proves it is one before
/// handing the same value back, so `bytes` is idempotent like `chars`.
const ByteListIdentityDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.ByteVectorEncoder),

    pub fn advance(evaluator: *Machine, self: *ByteListIdentityDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.typeError("a string or byte list"),
        }) {
            .pending => return .yielded,
            .complete => |vector| {
                var owned = vector;
                owned.retire(evaluator.releaseDomain(), evaluator.allocator());
                return .{ .output = self.source_value.take() };
            },
        }
    }
};

const SymbolConversion = enum { lookup, insert };

fn symbolWord(evaluator: *Machine) MachineError!void {
    return startSymbolConversion(evaluator, .lookup);
}

fn internWord(evaluator: *Machine) MachineError!void {
    return startSymbolConversion(evaluator, .insert);
}

fn startSymbolConversion(evaluator: *Machine, mode: SymbolConversion) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .symbol => try evaluator.pushOwned(item.take()),
        .word => |word| try evaluator.pushOwned(.{ .symbol = word.name }),
        .list => {
            if (!item.borrow().isString()) return evaluator.typeError("a string, symbol, or word");
            const encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), item.borrow());
            try evaluator.startDriver(SymbolConversionDriver{
                .source_value = .init(item.take()),
                .encoder = .init(encoder),
                .mode = mode,
            });
        },
        else => return evaluator.typeError("a string, symbol, or word"),
    }
}

/// `symbol` and `intern` differ only in the final cursor: lookup answers
/// absence with `'domain`, insertion grows the process-lifetime table.
const SymbolConversionDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),
    mode: SymbolConversion,
    spelling: ?heap.Owned([]u8) = null,
    validation: ?lexer.SymbolCursor = null,
    name: union(enum) {
        none,
        lookup: intern.InternLookupCursor,
        insert: intern.InternInsertionCursor,
    } = .none,

    pub fn advance(evaluator: *Machine, self: *SymbolConversionDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.spelling == null) switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |spelling| {
                self.spelling = .init(spelling);
                self.validation = .init(spelling);
                return .yielded;
            },
        };
        var budget: usize = machine.kernel_poll_quantum;
        if (self.validation) |*validation| {
            while (budget != 0) : (budget -= 1) switch (validation.advance()) {
                .pending => {},
                .complete => |valid| {
                    if (!valid) return evaluator.fail(.domain, "string is not a valid symbol spelling");
                    self.validation = null;
                    const spelling = self.spelling.?.borrow();
                    self.name = switch (self.mode) {
                        .lookup => .{ .lookup = intern.lookupCursor(spelling) },
                        .insert => .{ .insert = intern.insertionCursor(spelling) },
                    };
                    break;
                },
            };
            if (self.validation != null) return .yielded;
        }
        while (budget != 0) : (budget -= 1) switch (self.name) {
            .none => unreachable,
            .lookup => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |maybe_id| {
                    const id = maybe_id orelse
                        return evaluator.fail(.domain, "symbol spelling is not interned; use intern to create it");
                    return .{ .output = .{ .symbol = id } };
                },
            },
            .insert => |*cursor| switch (try cursor.advance()) {
                .pending => {},
                .complete => |id| return .{ .output = .{ .symbol = id } },
            },
        };
        return .yielded;
    }
};

fn intWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .int => try evaluator.pushOwned(item.take()),
        .char => |codepoint| try evaluator.pushOwned(.{ .int = codepoint }),
        .list => {
            if (!item.borrow().isString()) return evaluator.typeError(int_expected);
            try startNumericParse(evaluator, &item, .integer);
        },
        else => return evaluator.typeError(int_expected),
    }
}

const int_expected = "an int, char, or integer string (floor, round, or ceil convert a float)";
const float_expected = "a float, int, or numeric string";

fn floatWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .float => try evaluator.pushOwned(item.take()),
        .int => |number| try evaluator.pushOwned(.{ .float = @floatFromInt(number) }),
        .list => {
            if (!item.borrow().isString()) return evaluator.typeError(float_expected);
            try startNumericParse(evaluator, &item, .float);
        },
        else => return evaluator.typeError(float_expected),
    }
}

fn charWord(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .char => try evaluator.pushOwned(item.take()),
        .int => |number| {
            const codepoint = std.math.cast(u21, number) orelse
                return evaluator.fail(.domain, "char expects a Unicode scalar value");
            if (!std.unicode.utf8ValidCodepoint(codepoint))
                return evaluator.fail(.domain, "char expects a Unicode scalar value");
            try evaluator.pushOwned(.{ .char = codepoint });
        },
        .list => |header| {
            if (!item.borrow().isString()) return evaluator.typeError("a char, int, or one-char string");
            if (header.length() != 1) return evaluator.fail(.domain, "char expects a one-char string");
            try evaluator.pushOwned(list.atUnchecked(item.borrow(), 0));
        },
        else => return evaluator.typeError("a char, int, or one-char string"),
    }
}

fn startNumericParse(
    evaluator: *Machine,
    source_value: *heap.OwnedValue,
    target: NumericParseTarget,
) MachineError!void {
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
        .integer => evaluator.fail(.parse, "int expects an integer literal"),
        .float => evaluator.fail(.parse, "float expects a numeric literal"),
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
                .integer => evaluator.fail(.overflow, "int result is outside int64"),
                .float => evaluator.fail(.overflow, "float input is outside the ECL numeric range"),
            },
        };
    }
};
fn attempt(evaluator: *Machine) MachineError!void {
    var input = try evaluator.popUnitInput();
    defer input.deinit(evaluator.releaseDomain());
    try evaluator.attemptOwned(input.move());
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
    if (evaluator.available() == 0) return;
    try evaluator.startDriver(StackDisplayDriver{
        .snapshot = .init(try .init(evaluator)),
    });
}

const StackDisplayDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    snapshot: heap.Owned(StackSnapshot),
    index: usize = 0,
    render: ?heap.Owned(printer.OwnedStringCursor) = null,
    rendered: ?heap.Owned([]u8) = null,
    prefix_written: bool = false,
    written: usize = 0,

    pub fn advance(evaluator: *Machine, self: *StackDisplayDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (!self.snapshot.borrowMut().advanceCapture(
            evaluator,
            machine.kernel_poll_quantum,
        )) return .yielded;

        var prefix_buffer: [64]u8 = undefined;
        const prefix = stackDisplayPrefix(&prefix_buffer, self.index);
        if (self.rendered == null) {
            if (self.render == null) {
                self.render = .init(try printer.OwnedStringCursor.initDisplayAtColumn(
                    evaluator.allocator(),
                    self.snapshot.borrow().items()[self.index],
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
        return if (self.index == self.snapshot.borrow().items().len) .completed else .yielded;
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
/// Reads one variable from the immutable session environ snapshot. An unset
/// variable raises an error because absence has no empty-string representation;
/// `@attempt`/`result.or-else` is the defaulting idiom.
fn getenv(evaluator: *Machine) MachineError!void {
    var name_value = try evaluator.popValue();
    defer name_value.deinit();
    if (!name_value.borrow().isString()) return evaluator.typeError("a string variable name");
    const encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), name_value.borrow());
    try evaluator.startDriver(GetenvDriver{
        .name_value = .init(name_value.take()),
        .encoder = .init(encoder),
    });
}

const GetenvDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    name_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),
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
