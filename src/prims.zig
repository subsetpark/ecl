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
const kernel_flat = @import("kernel_flat.zig");
const task_prims = @import("task_prims.zig");
const test_prims = @import("test_prims.zig");
const Value = value.Value;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "dup", .primitive = dup, .effect = "x -- x x", .doc = "Duplicate the top stack value." },
        .{ .name = "swap", .primitive = swap, .effect = "x y -- y x", .doc = "Exchange the top two stack values." },
        .{ .name = "over", .primitive = over, .effect = "x y -- x y x", .doc = "Copy the value beneath the top of the stack onto the top." },
        .{ .name = "pop", .primitive = pop, .effect = "x --", .doc = "Discard the top stack value." },
        .{ .name = "nip", .primitive = nip, .effect = "x y -- y", .doc = "Discard the second value on the stack." },
        .{ .name = "dup2", .primitive = dup2, .effect = "x y -- x y x y", .doc = "Copy the top two stack values onto the top, preserving their order." },
        .{ .name = "rollup", .primitive = rollup, .effect = "x y z -- z x y", .doc = "Rotate the top three stack values upward." },
        .{ .name = "rolldown", .primitive = rolldown, .effect = "x y z -- y z x", .doc = "Rotate the top three stack values downward." },
        .{ .name = "stack", .primitive = stack, .effect = null, .doc = "Copy the operand stack into a bottom-to-top list while leaving every original value in place." },
        .{ .name = "match?", .primitive = match, .effect = "left right -- bool", .doc = "Whole-value structural equality.\n\nEx.:\n```\n  [1 2] [1 2] =\n[1 1]\n  [1 2] [1 2] match?\n1\n```" },
        .{ .name = "type", .primitive = typeWord, .effect = "value -- type", .doc = "Return the value's kind as a symbol: one of `int`, `float`, `char`, `symbol`, `list`, `dict`, `task`, `port`, or `address`." },
        .{ .name = "execute", .primitive = execute, .effect = "word -- ...", .doc = "Evaluate a symbol's binding and dispatch. Non-symbols are `` `type ``; missing words are `` `undefined-word ``." },
        .{ .name = "parse", .primitive = parse, .effect = "string -- quotation", .doc = "Parse source text into an unevaluated quotation. Reading interns every symbol and word in the string." },
        .{ .name = "chars", .primitive = chars, .effect = "value -- string", .doc = "Return a value's text content as a string: a string unchanged, the spelling of a symbol, a char as a one-element string, or a byte list decoded as UTF-8. Bytes that are not valid UTF-8 are `` `domain `` with `` `reason `invalid-utf8 ``; a list that is neither a string nor a byte list, or any other kind, is `` `type ``. See [Conversions](SPEC.md#conversions)." },
        .{ .name = "bytes", .primitive = bytesWord, .effect = "value -- bytes", .doc = "Encode a UTF-8 string as a byte list: an integer list whose elements are 0 through 255. A byte list is returned unchanged. Any other value is `` `type ``. Inverse of `chars`; see [Conversions](SPEC.md#conversions)." },
        .{ .name = "symbol", .primitive = symbolWord, .effect = "value -- symbol", .doc = "Given a string, return the symbol with the same spelling. Returns a symbol unchanged. A spelling that is not yet interned is `` `domain ``, as is a string that is not a valid symbol spelling; any other value is `` `type ``. Every symbol written in loaded source is interned, so this succeeds for any key a program compares against and never grows the interned name space; use `intern` to create one. See [Conversions](SPEC.md#conversions)." },
        .{ .name = "intern", .primitive = internWord, .effect = "value -- symbol", .doc = "Given a string, return the symbol with the same spelling. Returns a symbol unchanged. A new valid spelling is added to the intern table; a string that is not a valid symbol spelling is `` `domain ``. Interned symbols live for the whole process and are never reclaimed, and the table's capacity is fixed, so interning unbounded external input can exhaust it and fail with out-of-memory. See [Conversions](SPEC.md#conversions)." },
        .{ .name = "int", .primitive = intWord, .effect = "value -- int", .doc = "Return an int unchanged, a char's codepoint, or the value of a string in the integer-literal grammar. A string outside that grammar is `` `parse ``. A float is `` `type ``: choose `floor`, `round`, or `ceil` instead. Any other value is also `` `type ``." },
        .{ .name = "float", .primitive = floatWord, .effect = "value -- float", .doc = "Return a float unchanged, an int as a float, or the value of a string in the numeric-literal grammar. A string outside that grammar is `` `parse ``; any other value is `` `type ``." },
        .{ .name = "char", .primitive = charWord, .effect = "value -- chars", .doc = "Return a char unchanged, or the char with an int's codepoint. A string is returned unchanged, whatever its length, and a list of chars or codepoints becomes the string of those chars. An int outside the Unicode scalar range, or a list element outside it, is `` `domain ``; any other value is `` `type ``." },
        .{ .name = "@attempt", .primitive = attempt, .effect = "quotation -- result", .doc = "Run the quotation as a new unit on an empty, isolated stack. It will push a result object, containing either `ok <values>` with the successful stack values as a list, or `{err <error dict>}`. To start the unit on values, build them into the quotation: `values (q) cat @attempt`." },
        .{ .name = "raise", .primitive = raise, .effect = "error --", .doc = "Raise an error from an error dict." },
        .{ .name = "helper", .primitive = helper, .effect = "quotation -- quotation", .doc = "Mark a quotation read from source as a helper body and return it. A word defined with a helper body reports a failure inside it at the place that called the word, as an assertion does: `(body) helper `name def`. Every word still appears in `trace`. The mark belongs to that quotation, not to an equal one; a list built at run time is `` `domain ``, and any other value is `` `type ``." },
        .{ .name = "args", .primitive = args, .effect = "-- arguments", .doc = "The process arguments following the script or source, as a list of strings." },
        .{ .name = "exit", .primitive = exit, .effect = "status --", .doc = "Root-only outside `@attempt` (`` `domain `` otherwise): cancel and quiesce all descendants, then terminate the process with the given status." },
        .{ .name = "getenv", .primitive = getenv, .effect = "name -- string", .doc = "The value of an environment variable, read from an immutable snapshot taken once at session start. An unset variable is an error. Absent host IO is `` `io ``." },
    };
    try core.installBuiltins(&definitions);
    try combinators.install(core);
    try kernels.install(core);
    try module_prims.install(core);
    try task_prims.install(core);
    try test_prims.install(core);
}
fn dup(fiber: *Fiber) MachineError!void {
    try fiber.require(1);
    try fiber.pushBorrowed(fiber.stack.items[fiber.stack.items.len - 1]);
}
fn swap(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    const items = fiber.stack.items;
    std.mem.swap(Value, &items[items.len - 1], &items[items.len - 2]);
}
fn over(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    try fiber.pushBorrowed(fiber.stack.items[fiber.stack.items.len - 2]);
}
fn pop(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    item.deinit();
}
fn nip(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    try swap(fiber);
    try pop(fiber);
}
fn dup2(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var copies = try fiber.reserveStack(2);
    const items = fiber.stack.items;
    const x = items[items.len - 2];
    const y = items[items.len - 1];
    copies.pushBorrowed(x);
    copies.pushBorrowed(y);
}
fn rollup(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    const top = fiber.stack.items[fiber.stack.items.len - 3 ..];
    std.mem.rotate(Value, top, 2);
}
fn rolldown(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    const top = fiber.stack.items[fiber.stack.items.len - 3 ..];
    std.mem.rotate(Value, top, 1);
}

/// A retained, bottom-to-top copy of the visible operand window. Capturing is
/// chunked because the window is user-sized, and the exact backing allocation
/// never relocates while a later cursor borrows it.
const StackSnapshot = struct {
    values: heap.OwnedValueBuffer,
    depth: usize,
    index: usize = 0,

    fn init(fiber: *Fiber) error{OutOfMemory}!StackSnapshot {
        const depth = fiber.available();
        return .{
            .values = try .init(fiber.releases, depth),
            .depth = depth,
        };
    }

    fn advanceCapture(self: *StackSnapshot, fiber: *Fiber) bool {
        std.debug.assert(fiber.available() == self.depth);
        const end = self.index + fiber.workBudget().take(self.depth - self.index);
        // The snapshot is a list built from stack values, so each enters as
        // data (`value.datum`), as `cons` would store it.
        while (self.index != end) : (self.index += 1)
            self.values.appendBorrowed(value.datum(fiber.visibleOperandBorrowed(self.index)));
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

fn stack(fiber: *Fiber) MachineError!void {
    try fiber.startDriver(StackSnapshotDriver{
        .snapshot = .init(try .init(fiber)),
    });
}

const StackSnapshotDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    snapshot: heap.Owned(StackSnapshot),
    materializer: ?heap.Owned(list.ValueMaterializer) = null,
    result: ?heap.Owned(Value) = null,

    pub fn advance(fiber: *Fiber, self: *StackSnapshotDriver) MachineError!machine.WorkProgress {
        if (!self.snapshot.borrowMut().advanceCapture(fiber)) return .stepped;

        if (self.materializer == null) {
            self.materializer = .init(.init(fiber.allocator, self.snapshot.borrow().items()));
            return .stepped;
        }
        if (self.result == null) switch (try self.materializer.?.borrowMut().advance(fiber.workBudget())) {
            .pending => return .stepped,
            .complete => |result| {
                self.result = .init(result);
                return .stepped;
            },
        };

        self.snapshot.deinit(fiber.releases, fiber.allocator);
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }
};

fn match(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var right = try fiber.popValue();
    defer right.deinit();
    var left = try fiber.popValue();
    defer left.deinit();
    // Only a list against a list or a dict against a dict has structure to
    // walk; every other pair is one comparison, which the cursor would reach
    // after allocating a worklist and a driver to hold it.
    if (equal.matchWithoutStructure(left.borrow(), right.borrow())) |matches| {
        return fiber.pushOwned(.{ .int = @intFromBool(matches) });
    }
    const cursor = try equal.MatchCursor.init(fiber.allocator, left.borrow(), right.borrow());
    try fiber.startDriver(MatchDriver{
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

    pub fn advance(fiber: *Fiber, self: *MatchDriver) MachineError!machine.WorkProgress {
        return switch (try self.cursor.borrowMut().advance(fiber.workBudget())) {
            .pending => .stepped,
            .complete => |matches| .{ .output = .{ .int = @intFromBool(matches) } },
        };
    }
};
fn typeWord(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const spelling: []const u8 = switch (item.borrow()) {
        .int => "int",
        .float => "float",
        .char => "char",
        .symbol => "symbol",
        .list => "list",
        .dict => "dict",
        .task => "task",
        .port => "port",
        .address => "address",
    };
    try fiber.pushOwned(.{ .symbol = .{ .name = try intern.intern(spelling) } });
}
fn execute(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const word = switch (item.borrow()) {
        // `execute` runs the word a symbol names, quoted occurrence or not.
        .symbol => |word| value.Symbol{ .name = word.name, .slot = env.unquoted(word.slot) },
        else => return fiber.typeError("a symbol"),
    };
    try fiber.executeWord(word);
}
fn parse(fiber: *Fiber) MachineError!void {
    var source_value = try fiber.popString();
    defer source_value.deinit();
    const source = source_value.borrow();
    try fiber.startDriver(ParseDriver{
        .source_value = .init(source_value.take()),
        .encoder = .init(.init(fiber.allocator, source)),
    });
}
const ParseDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),
    source: ?heap.Owned([]u8) = null,
    pub fn advance(fiber: *Fiber, self: *ParseDriver) MachineError!machine.WorkProgress {
        if (self.source == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return fiber.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |source| self.source = .init(source),
        };
        const source = self.source.?.take();
        self.source = null;
        fiber.retireDriver(self);
        try fiber.parseSourceOwned(source);
        return .detached;
    }
};

pub const NumericParseTarget = enum {
    integer,
    float,

    pub fn spelling(self: NumericParseTarget) []const u8 {
        return switch (self) {
            .integer => "int",
            .float => "float",
        };
    }
};

// ── Kind conversions ────────────────────────────────────────────────────────
//
// Each word names its target kind and accepts the documented source kinds;
// anything else is `'type`. Toward text one polymorphic word suffices
// (chars), because every source has one text content. Away from text the
// target must be named (int, float, char, symbol, bytes), because a
// string alone does not say what it should become. `str` stays the readable
// representation and `parse` the reader; neither is a conversion.

const chars_expected = "a string, symbol, word, char, or byte list";

fn chars(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .list => {
            if (item.borrow().isString()) return fiber.pushOwned(item.take());
            const encoder = kernel_storage.ByteVectorEncoder.init(fiber.allocator, item.borrow());
            try fiber.startDriver(BytesToCharsDriver{
                .source_value = .init(item.take()),
                .encoder = .init(encoder),
            });
        },
        .symbol => |id| try startSpellingChars(fiber, id.name),
        .char => |codepoint| {
            const one = [_]u32{codepoint};
            try fiber.pushOwned(try list.fromCodepoints(fiber.allocator, &one));
        },
        else => return fiber.typeError(chars_expected),
    }
}

/// Spellings are process-lifetime bytes validated as UTF-8 when interned, so
/// the driver borrows them and owns only the string it builds.
fn startSpellingChars(fiber: *Fiber, id: u32) MachineError!void {
    try fiber.startDriver(SpellingCharsDriver{
        .text = .init(.init(fiber.allocator, intern.get(id))),
    });
}

const SpellingCharsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    text: heap.Owned(kernel_storage.Utf8Materializer),

    pub fn advance(fiber: *Fiber, self: *SpellingCharsDriver) MachineError!machine.WorkProgress {
        return switch (self.text.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return invalidUtf8(fiber, "spelling is not valid UTF-8"),
        }) {
            .pending => .stepped,
            .complete => |text| .{ .output = text },
        };
    }
};

fn invalidUtf8(fiber: *Fiber, message: []const u8) MachineError {
    const failure = fiber.fail(.domain, message);
    fiber.addErrorReason(.{ .symbol = .{ .name = intern.intern("invalid-utf8") catch return error.OutOfMemory } });
    return failure;
}

const BytesToCharsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.ByteVectorEncoder),
    bytes: ?heap.Owned(kernel_storage.ByteVector) = null,
    text: ?heap.Owned(kernel_storage.Utf8Materializer) = null,

    pub fn advance(fiber: *Fiber, self: *BytesToCharsDriver) MachineError!machine.WorkProgress {
        if (self.bytes == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return fiber.typeError(chars_expected),
        }) {
            .pending => return .stepped,
            .complete => |bytes| {
                self.bytes = .init(bytes);
                self.text = .init(.init(fiber.allocator, self.bytes.?.borrowMut().bytes()));
                return .stepped;
            },
        };
        return switch (self.text.?.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return invalidUtf8(fiber, "byte list is not valid UTF-8"),
        }) {
            .pending => .stepped,
            .complete => |text| .{ .output = text },
        };
    }
};

fn bytesWord(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    if (item.borrow() != .list) return fiber.typeError("a string or byte list");
    if (item.borrow().isString()) {
        const encoder = kernel_storage.StringEncoder.init(fiber.allocator, item.borrow());
        return fiber.startDriver(StringBytesDriver{
            .source_value = .init(item.take()),
            .encoder = .init(encoder),
        });
    }
    const encoder = kernel_storage.ByteVectorEncoder.init(fiber.allocator, item.borrow());
    try fiber.startDriver(ByteListIdentityDriver{
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

    pub fn advance(fiber: *Fiber, self: *StringBytesDriver) MachineError!machine.WorkProgress {
        if (self.encoded == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return fiber.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |encoded| {
                self.encoded = .init(encoded);
                self.materializer = .init(.init(fiber.allocator, self.encoded.?.borrow()));
                return .stepped;
            },
        };
        return switch (try self.materializer.?.borrowMut().advance(fiber.workBudget())) {
            .pending => .stepped,
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

    pub fn advance(fiber: *Fiber, self: *ByteListIdentityDriver) MachineError!machine.WorkProgress {
        switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return fiber.typeError("a string or byte list"),
        }) {
            .pending => return .stepped,
            .complete => |vector| {
                var owned = vector;
                owned.retire(fiber.releases, fiber.allocator);
                return .{ .output = self.source_value.take() };
            },
        }
    }
};

const SymbolConversion = enum { lookup, insert };

fn symbolWord(fiber: *Fiber) MachineError!void {
    return startSymbolConversion(fiber, .lookup);
}

fn internWord(fiber: *Fiber) MachineError!void {
    return startSymbolConversion(fiber, .insert);
}

fn startSymbolConversion(fiber: *Fiber, mode: SymbolConversion) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .symbol => try fiber.pushOwned(item.take()),
        .list => {
            if (!item.borrow().isString()) return fiber.typeError("a string or symbol");
            const encoder = kernel_storage.StringEncoder.init(fiber.allocator, item.borrow());
            try fiber.startDriver(SymbolConversionDriver{
                .source_value = .init(item.take()),
                .encoder = .init(encoder),
                .mode = mode,
            });
        },
        else => return fiber.typeError("a string or symbol"),
    }
}

/// `symbol` and `intern` differ only in the final cursor: lookup answers
/// absence with `domain, insertion grows the process-lifetime table. Either
/// way the symbol links to the root of the activation that built it, as one
/// written there would: a symbol built from a string is lexical, not dynamic.
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

    pub fn advance(fiber: *Fiber, self: *SymbolConversionDriver) MachineError!machine.WorkProgress {
        if (self.spelling == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return fiber.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |spelling| {
                self.spelling = .init(spelling);
                self.validation = .init(spelling);
                return .stepped;
            },
        };
        const work = fiber.workBudget();
        if (self.validation) |*validation| {
            while (work.spend()) switch (validation.advance()) {
                .pending => {},
                .complete => |valid| {
                    if (!valid) return fiber.fail(.domain, "string is not a valid symbol spelling");
                    self.validation = null;
                    const spelling = self.spelling.?.borrow();
                    self.name = switch (self.mode) {
                        .lookup => .{ .lookup = intern.lookupCursor(spelling) },
                        .insert => .{ .insert = intern.insertionCursor(spelling) },
                    };
                    break;
                },
            };
            if (self.validation != null) return .stepped;
        }
        while (work.spend()) switch (self.name) {
            .none => unreachable,
            .lookup => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |maybe_id| {
                    const id = maybe_id orelse
                        return fiber.fail(.domain, "symbol spelling is not interned; use intern to create it");
                    return .{ .output = .{ .symbol = try fiber.linkedWord(id) } };
                },
            },
            .insert => |*cursor| switch (try cursor.advance()) {
                .pending => {},
                .complete => |id| return .{ .output = .{ .symbol = try fiber.linkedWord(id) } },
            },
        };
        return .stepped;
    }
};

fn intWord(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .int => try fiber.pushOwned(item.take()),
        .char => |codepoint| try fiber.pushOwned(.{ .int = codepoint }),
        .list => {
            if (!item.borrow().isString()) return fiber.typeError(int_expected);
            try startNumericParse(fiber, &item, .integer);
        },
        else => return fiber.typeError(int_expected),
    }
}

const int_expected = "an int, char, or integer string (floor, round, or ceil convert a float)";
const float_expected = "a float, int, or numeric string";

fn floatWord(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .float => try fiber.pushOwned(item.take()),
        .int => |number| try fiber.pushOwned(.{ .float = @floatFromInt(number) }),
        .list => {
            if (!item.borrow().isString()) return fiber.typeError(float_expected);
            try startNumericParse(fiber, &item, .float);
        },
        else => return fiber.typeError(float_expected),
    }
}

fn charWord(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    switch (item.borrow()) {
        .char => try fiber.pushOwned(item.take()),
        .int => |number| {
            const codepoint = std.math.cast(u21, number) orelse
                return fiber.fail(.domain, "char expects a Unicode scalar value");
            if (!std.unicode.utf8ValidCodepoint(codepoint))
                return fiber.fail(.domain, "char expects a Unicode scalar value");
            try fiber.pushOwned(.{ .char = codepoint });
        },
        .list => {
            if (item.borrow().isString()) return fiber.pushOwned(item.take());
            try fiber.startDriver(CodepointsDriver{ .source = .init(item.take()) });
        },
        else => return fiber.typeError("a char, int, or list of codepoints"),
    }
}

/// `char` over a list: the string whose chars are the list's codepoints. The
/// way back from arithmetic, and the one place a string's width is chosen
/// from the values it will hold: a profiling pass finds the widest, then a
/// fill pass writes the writer that width selects. Each pass charges one
/// unit per element.
const CodepointsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source: heap.Owned(Value),
    phase: enum { profile, fill } = .profile,
    index: usize = 0,
    max_codepoint: u32 = 0,
    writer: ?heap.Owned(kernel_flat.CodepointWriter) = null,

    fn scalar(fiber: *Fiber, number: i64) MachineError!u32 {
        const narrowed = std.math.cast(u21, number) orelse
            return fiber.fail(.domain, "char expects a Unicode scalar value");
        if (!std.unicode.utf8ValidCodepoint(narrowed))
            return fiber.fail(.domain, "char expects a Unicode scalar value");
        return narrowed;
    }

    fn codepoint(fiber: *Fiber, item: Value) MachineError!u32 {
        return switch (item) {
            .char => |existing| existing,
            .int => |number| scalar(fiber, number),
            else => fiber.typeError("a char, int, or list of codepoints"),
        };
    }

    /// The widest codepoint of a block of ints, validated as a block: the
    /// range test is a min and a max over the block, and only a block that
    /// fails it, or that reaches the surrogate range, is walked to find the
    /// faulting element. An int leaf is what arithmetic on a string produces,
    /// so this is the usual input.
    fn profileInts(fiber: *Fiber, numbers: []const i64) MachineError!u32 {
        var low: i64 = std.math.maxInt(i64);
        var high: i64 = std.math.minInt(i64);
        for (numbers) |number| {
            low = @min(low, number);
            high = @max(high, number);
        }
        if (low < 0 or high > 0x10FFFF or (high >= 0xD800 and low <= 0xDFFF)) {
            for (numbers) |number| _ = try scalar(fiber, number);
        }
        return @intCast(high);
    }

    pub fn advance(fiber: *Fiber, self: *CodepointsDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        const source = self.source.borrow();
        const count: usize = @intCast(source.list.length());
        const kind = source.list.kind();
        while (!work.exhausted()) switch (self.phase) {
            .profile => {
                if (self.index == count) {
                    self.writer = .init(try .init(fiber.allocator, count, self.max_codepoint));
                    self.phase = .fill;
                    self.index = 0;
                    continue;
                }
                const end = self.index + work.take(count - self.index);
                switch (kind) {
                    .leaf_i64 => self.max_codepoint = @max(
                        self.max_codepoint,
                        try profileInts(fiber, heap.i64s(source.list)[self.index..end]),
                    ),
                    .leaf_u8 => for (heap.u8s(source.list)[self.index..end]) |byte| {
                        self.max_codepoint = @max(self.max_codepoint, byte);
                    },
                    else => for (self.index..end) |position| {
                        self.max_codepoint = @max(self.max_codepoint, try codepoint(fiber, list.atUnchecked(source, position)));
                    },
                }
                self.index = end;
            },
            .fill => {
                if (self.index == count) {
                    var writer = self.writer.?.take();
                    return .{ .output = writer.finish() };
                }
                const end = self.index + work.take(@min(count - self.index, kernel_flat.block_size));
                var block: [kernel_flat.block_size]u32 = undefined;
                const filled = block[0 .. end - self.index];
                switch (kind) {
                    // The profile pass validated every element.
                    .leaf_i64 => for (heap.i64s(source.list)[self.index..end], filled) |number, *slot| {
                        slot.* = @truncate(@as(u64, @bitCast(number)));
                    },
                    .leaf_u8 => for (heap.u8s(source.list)[self.index..end], filled) |byte, *slot| {
                        slot.* = byte;
                    },
                    else => for (self.index..end, filled) |position, *slot| {
                        slot.* = try codepoint(fiber, list.atUnchecked(source, position));
                    },
                }
                self.writer.?.borrowMut().writeCodepoints(self.index, filled);
                self.index = end;
            },
        };
        return .stepped;
    }
};

fn startNumericParse(
    fiber: *Fiber,
    source_value: *heap.OwnedValue,
    target: NumericParseTarget,
) MachineError!void {
    const source = source_value.borrow();
    if (source.list.kind() != .leaf_char1) return invalidNumericText(fiber, target);
    const length: usize = @intCast(source.list.length());
    const bytes = heap.chars8(source.list)[0..length];
    try fiber.startDriver(NumericParseDriver{
        .source_value = .init(source_value.take()),
        .classifier = .init(bytes),
        .target = target,
    });
}

fn invalidNumericText(fiber: *Fiber, target: NumericParseTarget) MachineError {
    return switch (target) {
        .integer => fiber.fail(.parse, "int expects an integer literal"),
        .float => fiber.fail(.parse, "float expects a numeric literal"),
    };
}

const NumericParseDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    source_value: heap.Owned(Value),
    classifier: lexer.ClassifyCursor,
    target: NumericParseTarget,

    pub fn advance(fiber: *Fiber, self: *NumericParseDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) switch (self.classifier.advance()) {
            .pending => {},
            .complete => |classification| return self.finish(fiber, classification),
        };
        return .stepped;
    }

    fn finish(
        self: *NumericParseDriver,
        fiber: *Fiber,
        classification: lexer.Classification,
    ) MachineError!machine.WorkProgress {
        return .{ .output = try numericParseResult(fiber, classification, self.target) };
    }
};

/// What a classified string converts to for `target`, or the word's fault.
fn numericParseResult(fiber: *Fiber, classification: lexer.Classification, target: NumericParseTarget) MachineError!Value {
    return switch (classification) {
        .int => |number| switch (target) {
            .integer => .{ .int = number },
            .float => .{ .float = @floatFromInt(number) },
        },
        .float => |number| switch (target) {
            .integer => invalidNumericText(fiber, target),
            .float => .{ .float = number },
        },
        .symbol => invalidNumericText(fiber, target),
        .out_of_range => switch (target) {
            .integer => fiber.fail(.overflow, "int result is outside int64"),
            .float => fiber.fail(.overflow, "float input is outside the ECL numeric range"),
        },
    };
}
/// `(int) each` and `(float) each`: the conversion of every element of the
/// list beneath the quotation, written straight into the typed result. Each
/// element converts exactly as its word converts it alone, and a fault is
/// that word's, with no list position, as the quotation applied per element
/// reports it. The caller's stack holds the list and quotation until the
/// result is published.
pub fn startConversionEach(fiber: *Fiber, target: NumericParseTarget) MachineError!void {
    const items = fiber.stack.items;
    const input = items[items.len - 2];
    const count: usize = @intCast(input.list.length());
    switch (target) {
        inline else => |selected| {
            const Driver = ConversionEachDriver(selected);
            const writer = try heap.LeafWriter(Driver.kind).init(fiber.allocator, count);
            try fiber.startDriver(Driver{ .input = input, .writer = .init(writer) });
        },
    }
}

fn ConversionEachDriver(comptime target: NumericParseTarget) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;
        const kind: value.HeapKind = switch (target) {
            .integer => .leaf_i64,
            .float => .leaf_f64,
        };

        input: Value,
        writer: heap.Owned(heap.LeafWriter(kind)),
        index: usize = 0,
        /// The string element being read, across turns.
        classifier: ?lexer.ClassifyCursor = null,

        pub fn advance(fiber: *Fiber, self: *Self) MachineError!machine.WorkProgress {
            const work = fiber.workBudget();
            const count: usize = @intCast(self.input.list.length());
            while (self.index != count) {
                if (self.classifier == null) {
                    if (!work.spend()) return .stepped;
                    const item = list.atUnchecked(self.input, self.index);
                    if (try atom(fiber, item)) |converted| {
                        self.store(converted);
                        continue;
                    }
                    if (item.list.kind() != .leaf_char1) return invalidNumericText(fiber, target);
                    self.classifier = .init(heap.chars8(item.list)[0..@intCast(item.list.length())]);
                }
                const classification = while (work.spend()) switch (self.classifier.?.advance()) {
                    .pending => {},
                    .complete => |classification| break classification,
                } else return .stepped;
                self.classifier = null;
                self.store(try parsed(fiber, classification));
            }
            fiber.discard(2);
            return .{ .output = self.writer.borrowMut().finish() };
        }

        fn store(self: *Self, converted: heap.LeafElement(kind)) void {
            self.writer.borrowMut().fillRange(self.index, 1, converted);
            self.index += 1;
        }

        /// A non-string element's conversion, null for a string, or the
        /// word's own type error.
        fn atom(fiber: *Fiber, item: Value) MachineError!?heap.LeafElement(kind) {
            return switch (target) {
                .integer => switch (item) {
                    .int => |number| number,
                    .char => |codepoint| codepoint,
                    .list => if (item.isString()) null else fiber.typeError(int_expected),
                    else => fiber.typeError(int_expected),
                },
                .float => switch (item) {
                    .float => |number| number,
                    .int => |number| @floatFromInt(number),
                    .list => if (item.isString()) null else fiber.typeError(float_expected),
                    else => fiber.typeError(float_expected),
                },
            };
        }

        fn parsed(fiber: *Fiber, classification: lexer.Classification) MachineError!heap.LeafElement(kind) {
            return switch (try numericParseResult(fiber, classification, target)) {
                .int => |number| if (target == .integer) number else unreachable,
                .float => |number| if (target == .float) number else unreachable,
                else => unreachable,
            };
        }
    };
}

fn attempt(fiber: *Fiber) MachineError!void {
    var body = try fiber.popQuotation();
    try fiber.attemptOwned(body.take().list);
}
fn helper(fiber: *Fiber) MachineError!void {
    try fiber.require(1);
    const top = fiber.stack.items[fiber.stack.items.len - 1];
    if (top != .list) return fiber.typeError("a quotation/list");
    if (!fiber.archive.markHelper(top.list))
        return fiber.fail(.domain, "helper needs a quotation read from source");
}
fn raise(fiber: *Fiber) MachineError!void {
    var raised = try fiber.popValue();
    defer raised.deinit();
    if (raised.borrow() != .dict) return fiber.typeError("an error dict");
    const keys = [5]u32{
        try intern.intern("kind"),
        try intern.intern("msg"),
        try intern.intern("word"),
        try intern.intern("trace"),
        try intern.intern("data"),
    };
    try fiber.startDriver(RaiseDriver{ .raised = .init(raised.take()), .keys = keys });
}
const RaiseDriver = struct {
    raised: heap.Owned(Value),
    keys: [5]u32,
    field_index: usize = 0,
    lookup: ?heap.Owned(dict.FindCursor) = null,
    trace: ?Value = null,
    trace_index: usize = 0,
    phase: enum { lookup, trace, finish } = .lookup,

    pub fn advance(fiber: *Fiber, self: *RaiseDriver) MachineError!machine.WorkProgress {
        switch (self.phase) {
            .lookup => {
                if (self.field_index == self.keys.len) {
                    self.phase = .finish;
                    return .stepped;
                }
                if (self.lookup == null) self.lookup = .init(.initHeader(
                    fiber.allocator,
                    self.raised.borrow().dict,
                    .{ .symbol = .{ .name = self.keys[self.field_index] } },
                ));
                switch (try self.lookup.?.borrowMut().advance(fiber.workBudget())) {
                    .pending => return .stepped,
                    .complete => |found| {
                        self.lookup.?.deinit(fiber.releases, fiber.allocator);
                        self.lookup = null;
                        try self.validateField(fiber, found);
                        if (self.phase == .lookup) self.field_index += 1;
                        return .stepped;
                    },
                }
            },
            .trace => {
                const trace = self.trace.?;
                const count: usize = @intCast(trace.list.length());
                const end = self.trace_index + fiber.workBudget().take(count - self.trace_index);
                while (self.trace_index != end) : (self.trace_index += 1) {
                    if (list.atUnchecked(trace, self.trace_index) != .symbol)
                        return fiber.typeError("an error dict with symbols at `trace");
                }
                if (self.trace_index == count) {
                    self.trace = null;
                    self.field_index += 1;
                    self.phase = .lookup;
                }
                return .stepped;
            },
            .finish => {
                const raised = self.raised.take();
                return fiber.raiseOwned(raised);
            },
        }
    }
    fn validateField(self: *RaiseDriver, fiber: *Fiber, found: ?Value) MachineError!void {
        switch (self.field_index) {
            0 => if (found == null or found.? != .symbol)
                return fiber.typeError("an error dict containing a symbol at `kind"),
            1 => if (found) |message| {
                if (!message.isString())
                    return fiber.typeError("an error dict with a string at `msg");
            },
            2 => if (found) |word| {
                if (word != .symbol)
                    return fiber.typeError("an error dict with a symbol at `word");
            },
            3 => if (found) |trace| {
                if (trace != .list)
                    return fiber.typeError("an error dict with symbols at `trace");
                self.trace = trace;
                self.trace_index = 0;
                self.phase = .trace;
            },
            4 => if (found) |data| {
                if (data != .dict)
                    return fiber.typeError("an error dict with a dict at `data");
            },
            else => unreachable,
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
pub fn ioPp(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const render = try printer.OwnedStringCursor.initDisplay(fiber.allocator, item.borrow());
    try fiber.startDriver(PpDriver{
        .item = .init(item.take()),
        .render = .init(render),
    });
}

const PpDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    item: heap.Owned(Value),
    render: heap.Owned(printer.OwnedStringCursor),

    pub fn advance(fiber: *Fiber, self: *PpDriver) MachineError!machine.WorkProgress {
        return switch (try self.render.borrowMut().advance(fiber.workBudget())) {
            .pending => .stepped,
            .complete => |rendered| completed: {
                defer fiber.allocator.free(rendered);
                fiber.inherited.runtime().console.writeOutput(rendered, true) catch
                    return fiber.fail(.io, "standard output write failed");
                break :completed .completed;
            },
        };
    }
};

pub fn ioStack(fiber: *Fiber) MachineError!void {
    if (fiber.available() == 0) return;
    try fiber.startDriver(StackDisplayDriver{
        .snapshot = .init(try .init(fiber)),
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

    pub fn advance(fiber: *Fiber, self: *StackDisplayDriver) MachineError!machine.WorkProgress {
        if (!self.snapshot.borrowMut().advanceCapture(fiber)) return .stepped;

        var prefix_buffer: [64]u8 = undefined;
        const prefix = stackDisplayPrefix(&prefix_buffer, self.index);
        if (self.rendered == null) {
            if (self.render == null) {
                self.render = .init(try printer.OwnedStringCursor.initDisplayAtColumn(
                    fiber.allocator,
                    self.snapshot.borrow().items()[self.index],
                    prefix.len,
                ));
            }
            switch (try self.render.?.borrowMut().advance(fiber.workBudget())) {
                .pending => return .stepped,
                .complete => |text| {
                    self.render.?.deinit(fiber.releases, fiber.allocator);
                    self.render = null;
                    self.rendered = .init(text);
                    return .stepped;
                },
            }
        }

        if (!self.prefix_written) {
            try writeStackDisplayChunk(fiber, prefix, false);
            self.prefix_written = true;
            return .stepped;
        }

        const text = self.rendered.?.borrow();
        // Console output is written in chunks of at most 256 bytes, each
        // charged a unit per byte, so a large display spans turns.
        const end = self.written + fiber.workBudget().take(@min(256, text.len - self.written));
        const complete = end == text.len;
        try writeStackDisplayChunk(fiber, text[self.written..end], complete);
        self.written = end;
        if (!complete) return .stepped;

        self.rendered.?.deinit(fiber.releases, fiber.allocator);
        self.rendered = null;
        self.prefix_written = false;
        self.written = 0;
        self.index += 1;
        return if (self.index == self.snapshot.borrow().items().len) .completed else .stepped;
    }
};

fn stackDisplayPrefix(buffer: *[64]u8, index: usize) []const u8 {
    var fixed = std.Io.Writer.fixed(buffer);
    fixed.print("[{d}] ", .{index}) catch unreachable;
    return fixed.buffered();
}

fn writeStackDisplayChunk(
    fiber: *Fiber,
    bytes: []const u8,
    newline: bool,
) MachineError!void {
    fiber.inherited.runtime().console.writeOutput(bytes, newline) catch
        return fiber.fail(.io, "standard output write failed");
}

pub fn ioPrin(fiber: *Fiber) MachineError!void {
    var item = try fiber.popString();
    defer item.deinit();
    const string = item.borrow();
    try fiber.startDriver(PrinDriver{
        .item = .init(item.take()),
        .encoder = .init(.init(fiber.allocator, string)),
    });
}

const PrinDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    item: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),

    pub fn advance(fiber: *Fiber, self: *PrinDriver) MachineError!machine.WorkProgress {
        return switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return fiber.fail(
                .domain,
                "string contains an invalid Unicode scalar",
            ),
        }) {
            .pending => .stepped,
            .complete => |encoded| completed: {
                defer fiber.allocator.free(encoded);
                fiber.inherited.runtime().console.writeOutput(encoded, false) catch
                    return fiber.fail(.io, "standard output write failed");
                break :completed .completed;
            },
        };
    }
};
/// Reads one variable from the immutable session environ snapshot. An unset
/// variable raises an error because absence has no empty-string representation;
/// `@attempt`/`result.or-default` is the defaulting idiom.
fn getenv(fiber: *Fiber) MachineError!void {
    var name_value = try fiber.popValue();
    defer name_value.deinit();
    if (!name_value.borrow().isString()) return fiber.typeError("a string variable name");
    const encoder = kernel_storage.StringEncoder.init(fiber.allocator, name_value.borrow());
    try fiber.startDriver(GetenvDriver{
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

    pub fn advance(fiber: *Fiber, self: *GetenvDriver) MachineError!machine.WorkProgress {
        if (self.name == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return fiber.fail(
                .domain,
                "variable name contains an invalid Unicode scalar",
            ),
        }) {
            .pending => return .stepped,
            .complete => |name| self.name = .init(name),
        };
        if (self.text == null) {
            if (self.lookup == null)
                self.lookup = fiber.environLookup(self.name.?.borrow());
            switch (self.lookup.?.advance(fiber.workBudget())) {
                .pending => return .stepped,
                .complete => |found| {
                    const bytes = found orelse return fiber.unsetEnvironVariable(
                        self.name.?.borrow(),
                        self.name_value.borrow(),
                    );
                    self.text = .init(.init(fiber.allocator, bytes));
                    return .stepped;
                },
            }
        }
        return switch (self.text.?.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return fiber.fail(
                .io,
                "environment variable value is not valid UTF-8",
            ),
        }) {
            .pending => .stepped,
            .complete => |text| .{ .output = text },
        };
    }
};

fn args(fiber: *Fiber) MachineError!void {
    try fiber.pushBorrowed(fiber.inherited.runtime().arguments);
}
fn exit(fiber: *Fiber) MachineError!void {
    var status = try fiber.popValue();
    defer status.deinit();
    if (status.borrow() != .int or status.borrow().int < 0 or status.borrow().int > 255) {
        return fiber.typeError("an exit status from 0 through 255");
    }
    if (fiber.role == .task or fiber.inAttempt()) {
        return fiber.fail(.domain, "exit is available only to the root unit outside @attempt");
    }
    try fiber.park(.{ .close_scope = @intCast(status.borrow().int) });
}
