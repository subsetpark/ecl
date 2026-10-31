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
const sequence = @import("kernel_sequence.zig");
const kernel_storage = @import("kernel_storage.zig");
const kernel_flat = @import("kernel_flat.zig");
const task_prims = @import("task_prims.zig");
const test_prims = @import("test_prims.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "reduce-groups", .primitive = @import("kernel_numeric.zig").reduceGroups, .effect = "values groups reducer -- results", .doc = "Reduce each top-level index list, preserving group and index order, including repeated indices. Reducer symbols are `` `sum ``, `` `count ``, `` `min ``, and `` `max ``. Sum uses checked numeric addition from zero, left to right; count accepts any selected value. Min/max use whole-value comparison and preserve the first value on ties. Empty groups yield zero for sum/count and raise `` `domain `` for min/max. Noninteger selectors raise `` `type ``; negative or out-of-range indices and unknown symbols raise `` `domain ``. Built-in reducer meanings do not depend on word bindings." },
        .{ .name = "dup", .primitive = dup, .effect = "x -- x x", .doc = "Duplicate the top stack value." },
        .{ .name = "swap", .primitive = swap, .effect = "x y -- y x", .doc = "Exchange the top two stack values." },
        .{ .name = "pop", .primitive = pop, .effect = "x --", .doc = "Discard the top stack value. (`drop` is the sequence word.)" },
        .{ .name = "stack", .primitive = stack, .effect = null, .doc = "Copy the visible operand stack into a bottom-to-top list while leaving every original value in place." },
        .{ .name = "cons", .primitive = cons, .effect = "value list -- list", .doc = "Raw structural prepend. On data, `1 [2 3] cons` is `[1 2 3]`. On code it inserts a form: a prepended word executes when the result is called, so `cons` is not safe partial application — that is `partial`." },
        .{ .name = "match?", .primitive = match, .effect = "left right -- bool", .doc = "Whole-value structural equality; **not** pervasive. `[1 2] [1 2] =` is `[1 1]`; `[1 2] [1 2] match?` is `1`." },
        .{ .name = "type", .primitive = typeWord, .effect = "value -- type", .doc = "Return the value's kind as a symbol: one of `int`, `float`, `char`, `symbol`, `list`, `dict`, `task`, `port`, or `address`." },
        .{ .name = "execute", .primitive = execute, .effect = "word -- ...", .doc = "Resolve and apply a symbol late through the ordinary word-dispatch path, exactly as if that symbol appeared in executable position. Non-symbols are `` `type ``; missing words are `` `undefined-word ``. Module homes, private resolution, annotations, tracing, builtins, native calls, and cancellation are preserved." },
        .{ .name = "literal", .primitive = literal, .effect = "value -- form", .doc = "Return the form that pushes a value when a quotation runs it. A symbol becomes its quoted occurrence, so `` `x literal `` is `` `x `` and running it pushes `x` instead of executing it. Any other value already pushes itself and is returned unchanged. Wrap the form to get a quotation: `` v literal wrap `` pushes `v` when called." },
        .{ .name = "parse", .primitive = parse, .effect = "string -- quotation", .doc = "The reader, reified: parse source text into an unevaluated quotation. Reading interns every symbol and word in the text, so this is a load-class word for trusted source, not a conversion: use `int`, `float`, and `symbol` on data." },
        .{ .name = "chars", .primitive = chars, .effect = "value -- string", .doc = "Return a value's text content as a string: a string unchanged, the spelling of a symbol, a char as a one-element string, or a byte list decoded as UTF-8. Bytes that are not valid UTF-8 are `` `domain `` with `` `reason `invalid-utf8 ``; a list that is neither a string nor a byte list, or any other kind, is `` `type ``. Unlike `str`, the result is content rather than representation: `` (`foo) first chars `` is `\"foo\"`, while `` (`foo) first str `` is `\"`foo\"`. See [Conversions](SPEC.md#conversions)." },
        .{ .name = "bytes", .primitive = bytesWord, .effect = "value -- bytes", .doc = "Encode a string as UTF-8 into a byte list: an integer list whose elements are 0 through 255. A byte list is returned unchanged, so the word is idempotent. Any other value is `` `type ``. Inverse of `chars`; see [Conversions](SPEC.md#conversions)." },
        .{ .name = "symbol", .primitive = symbolWord, .effect = "value -- symbol", .doc = "Return a symbol unchanged, or the already-interned symbol whose spelling a string names. A spelling that is not yet interned is `` `domain ``, as is a string that is not a valid symbol spelling; any other value is `` `type ``. Every symbol written in loaded source is interned, so this succeeds for any key a program compares against and never grows the interned name space; use `intern` to create one. The symbol links to the root of the activation that built it, so `\"dup\" symbol wrap` executes the same `dup` as `(dup)` written there. See [Conversions](SPEC.md#conversions)." },
        .{ .name = "intern", .primitive = internWord, .effect = "value -- symbol", .doc = "Return a symbol unchanged, or create the symbol for a string, interning the spelling when it is new. A string that is not a valid symbol spelling is `` `domain ``; any other value is `` `type ``. Interned names live for the whole process and are never reclaimed, so never apply this to unbounded external input; `symbol` is the lookup-only form. The symbol links to the root of the activation that built it. See [Conversions](SPEC.md#conversions)." },
        .{ .name = "int", .primitive = intWord, .effect = "value -- int", .doc = "Return an int unchanged, a char's codepoint, or the value of a string in the integer-literal grammar. A string outside that grammar is `` `parse ``. A float is `` `type ``: choose `floor`, `round`, or `ceil` instead. Any other value is also `` `type ``." },
        .{ .name = "float", .primitive = floatWord, .effect = "value -- float", .doc = "Return a float unchanged, an int as a float, or the value of a string in the numeric-literal grammar. A string outside that grammar is `` `parse ``; any other value is `` `type ``." },
        .{ .name = "char", .primitive = charWord, .effect = "value -- chars", .doc = "Return a char unchanged, or the char with an int's codepoint. A string is returned unchanged, whatever its length, and a list of chars or codepoints becomes the string of those chars. An int outside the Unicode scalar range, or a list element outside it, is `` `domain ``; any other value is `` `type ``." },
        .{ .name = "@attempt", .primitive = attempt, .effect = "values quotation -- result", .doc = "*Unit constructor.* Initialize an isolated substack from the explicit values list, then run the quotation as a new unit. Use `[]` for no initial values. Always pushes exactly one result: `{ok (values)}` with the successful stack values as a list, or `{err <error dict>}`.\n\nObservationally `@spawn task.await` — same result shape, same error protocol, same self-contained-quotation contract — differing only in scheduling. That identity is what makes the isolation non-arbitrary rather than an implementation accident. The complete form is `values (q) @attempt`. See Errors." },
        .{ .name = "@attempt!", .primitive = attemptSeedless, .effect = "quotation -- result", .doc = "*Unit constructor.* `@attempt` with no values operand: the quotation runs on an empty stack, exactly as `[] (q) @attempt`." },
        .{ .name = "raise", .primitive = raise, .effect = "error --", .doc = "Raise a language error from an error dict." },
        .{ .name = "args", .primitive = args, .effect = "-- arguments", .doc = "The process arguments following the script or source, as a list of strings." },
        .{ .name = "exit", .primitive = exit, .effect = "status --", .doc = "Root-only outside `@attempt` (`` `domain `` otherwise): cancel and quiesce all descendants, then terminate the process with the given status." },
        .{ .name = "getenv", .primitive = getenv, .effect = "name -- string", .doc = "The value of an environment variable, read from an immutable snapshot taken once at session start. An unset variable is an error, never a blank: absence is absence, and `@attempt`/`or-else` is the defaulting idiom. Absent host IO is `` `io ``." },
    };
    try core.installBuiltins(&definitions);
    try combinators.install(core);
    try kernels.install(core);
    try module_prims.install(core);
    try task_prims.install(core);
    try test_prims.install(core);
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

    fn advanceCapture(self: *StackSnapshot, evaluator: *Machine) bool {
        std.debug.assert(evaluator.available() == self.depth);
        const end = self.index + evaluator.workBudget().take(self.depth - self.index);
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
        if (!self.snapshot.borrowMut().advanceCapture(evaluator)) return .stepped;

        if (self.materializer == null) {
            self.materializer = .init(.init(evaluator.allocator(), self.snapshot.borrow().items()));
            return .stepped;
        }
        if (self.result == null) switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => return .stepped,
            .complete => |result| {
                self.result = .init(result);
                return .stepped;
            },
        };

        self.snapshot.deinit(evaluator.releaseDomain(), evaluator.allocator());
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }
};

fn cons(evaluator: *Machine) MachineError!void {
    return sequence.consForPrims(evaluator);
}
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
        return switch (try self.cursor.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
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
        .list => "list",
        .dict => "dict",
        .task => "task",
        .port => "port",
        .address => "address",
    };
    try evaluator.pushOwned(.{ .symbol = .{ .name = try intern.intern(spelling) } });
}
/// Every value but a symbol pushes itself when a quotation runs it; a symbol
/// would execute, so its form is its quoted occurrence, linked as written.
fn literal(evaluator: *Machine) MachineError!void {
    try evaluator.require(1);
    var item = try evaluator.popValue();
    defer item.deinit();
    const form: Value = switch (item.borrow()) {
        .symbol => |word| .{ .symbol = .{ .name = word.name, .slot = word.slot | value.quote_flag } },
        else => item.take(),
    };
    return evaluator.pushOwned(form);
}
fn execute(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const word = switch (item.borrow()) {
        // `execute` runs the word a symbol names, quoted occurrence or not.
        .symbol => |word| value.Symbol{ .name = word.name, .slot = env.unquoted(word.slot) },
        else => return evaluator.typeError("a symbol"),
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
        if (self.source == null) switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
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
// (chars), because every source has one text content. Away from text the
// target must be named (int, float, char, symbol, bytes), because a
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
        .symbol => |id| try startSpellingChars(evaluator, id.name),
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
        return switch (self.text.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return invalidUtf8(evaluator, "spelling is not valid UTF-8"),
        }) {
            .pending => .stepped,
            .complete => |text| .{ .output = text },
        };
    }
};

fn invalidUtf8(evaluator: *Machine, message: []const u8) MachineError {
    const failure = evaluator.fail(.domain, message);
    evaluator.addErrorReason(.{ .symbol = .{ .name = intern.intern("invalid-utf8") catch return error.OutOfMemory } });
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
        if (self.bytes == null) switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.typeError(chars_expected),
        }) {
            .pending => return .stepped,
            .complete => |bytes| {
                self.bytes = .init(bytes);
                self.text = .init(.init(evaluator.allocator(), self.bytes.?.borrowMut().bytes()));
                return .stepped;
            },
        };
        return switch (self.text.?.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return invalidUtf8(evaluator, "byte list is not valid UTF-8"),
        }) {
            .pending => .stepped,
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
        if (self.encoded == null) switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |encoded| {
                self.encoded = .init(encoded);
                self.materializer = .init(.init(evaluator.allocator(), self.encoded.?.borrow()));
                return .stepped;
            },
        };
        return switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
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

    pub fn advance(evaluator: *Machine, self: *ByteListIdentityDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.typeError("a string or byte list"),
        }) {
            .pending => return .stepped,
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
        .list => {
            if (!item.borrow().isString()) return evaluator.typeError("a string or symbol");
            const encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), item.borrow());
            try evaluator.startDriver(SymbolConversionDriver{
                .source_value = .init(item.take()),
                .encoder = .init(encoder),
                .mode = mode,
            });
        },
        else => return evaluator.typeError("a string or symbol"),
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

    pub fn advance(evaluator: *Machine, self: *SymbolConversionDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.spelling == null) switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |spelling| {
                self.spelling = .init(spelling);
                self.validation = .init(spelling);
                return .stepped;
            },
        };
        const work = evaluator.workBudget();
        if (self.validation) |*validation| {
            while (work.spend()) switch (validation.advance()) {
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
            if (self.validation != null) return .stepped;
        }
        while (work.spend()) switch (self.name) {
            .none => unreachable,
            .lookup => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |maybe_id| {
                    const id = maybe_id orelse
                        return evaluator.fail(.domain, "symbol spelling is not interned; use intern to create it");
                    return .{ .output = .{ .symbol = try evaluator.linkedWord(id) } };
                },
            },
            .insert => |*cursor| switch (try cursor.advance()) {
                .pending => {},
                .complete => |id| return .{ .output = .{ .symbol = try evaluator.linkedWord(id) } },
            },
        };
        return .stepped;
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
        .list => {
            if (item.borrow().isString()) return evaluator.pushOwned(item.take());
            try evaluator.startDriver(CodepointsDriver{ .source = .init(item.take()) });
        },
        else => return evaluator.typeError("a char, int, or list of codepoints"),
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

    fn scalar(evaluator: *Machine, number: i64) MachineError!u32 {
        const narrowed = std.math.cast(u21, number) orelse
            return evaluator.fail(.domain, "char expects a Unicode scalar value");
        if (!std.unicode.utf8ValidCodepoint(narrowed))
            return evaluator.fail(.domain, "char expects a Unicode scalar value");
        return narrowed;
    }

    fn codepoint(evaluator: *Machine, item: Value) MachineError!u32 {
        return switch (item) {
            .char => |existing| existing,
            .int => |number| scalar(evaluator, number),
            else => evaluator.typeError("a char, int, or list of codepoints"),
        };
    }

    /// The widest codepoint of a block of ints, validated as a block: the
    /// range test is a min and a max over the block, and only a block that
    /// fails it, or that reaches the surrogate range, is walked to find the
    /// faulting element. An int leaf is what arithmetic on a string produces,
    /// so this is the usual input.
    fn profileInts(evaluator: *Machine, numbers: []const i64) MachineError!u32 {
        var low: i64 = std.math.maxInt(i64);
        var high: i64 = std.math.minInt(i64);
        for (numbers) |number| {
            low = @min(low, number);
            high = @max(high, number);
        }
        if (low < 0 or high > 0x10FFFF or (high >= 0xD800 and low <= 0xDFFF)) {
            for (numbers) |number| _ = try scalar(evaluator, number);
        }
        return @intCast(high);
    }

    pub fn advance(evaluator: *Machine, self: *CodepointsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        const source = self.source.borrow();
        const count: usize = @intCast(source.list.length());
        const kind = source.list.kind();
        while (!work.exhausted()) switch (self.phase) {
            .profile => {
                if (self.index == count) {
                    self.writer = .init(try .init(evaluator.allocator(), count, self.max_codepoint));
                    self.phase = .fill;
                    self.index = 0;
                    continue;
                }
                const end = self.index + work.take(count - self.index);
                switch (kind) {
                    .leaf_i64 => self.max_codepoint = @max(
                        self.max_codepoint,
                        try profileInts(evaluator, heap.i64s(source.list)[self.index..end]),
                    ),
                    .leaf_u8 => for (heap.u8s(source.list)[self.index..end]) |byte| {
                        self.max_codepoint = @max(self.max_codepoint, byte);
                    },
                    else => for (self.index..end) |position| {
                        self.max_codepoint = @max(self.max_codepoint, try codepoint(evaluator, list.atUnchecked(source, position)));
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
                        slot.* = try codepoint(evaluator, list.atUnchecked(source, position));
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
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.classifier.advance()) {
            .pending => {},
            .complete => |classification| return self.finish(evaluator, classification),
        };
        return .stepped;
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
            .symbol => invalidNumericText(evaluator, self.target),
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
fn attemptSeedless(evaluator: *Machine) MachineError!void {
    var input = try evaluator.popSeedlessUnitInput();
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
                    return .stepped;
                }
                if (self.lookup == null) self.lookup = .init(.initHeader(
                    evaluator.allocator(),
                    self.raised.borrow().dict,
                    .{ .symbol = .{ .name = self.keys[self.field_index] } },
                ));
                switch (try self.lookup.?.borrowMut().advance(evaluator.workBudget())) {
                    .pending => return .stepped,
                    .complete => |found| {
                        self.lookup.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.lookup = null;
                        try self.validateField(evaluator, found);
                        if (self.phase == .lookup) self.field_index += 1;
                        return .stepped;
                    },
                }
            },
            .trace => {
                const trace = self.trace.?;
                const count: usize = @intCast(trace.list.length());
                const end = self.trace_index + evaluator.workBudget().take(count - self.trace_index);
                while (self.trace_index != end) : (self.trace_index += 1) {
                    if (list.atUnchecked(trace, self.trace_index) != .symbol)
                        return evaluator.typeError("an error dict with symbols at `trace");
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
                return evaluator.raiseOwned(raised);
            },
        }
    }
    fn validateField(self: *RaiseDriver, evaluator: *Machine, found: ?Value) MachineError!void {
        switch (self.field_index) {
            0 => if (found == null or found.? != .symbol)
                return evaluator.typeError("an error dict containing a symbol at `kind"),
            1 => if (found) |message| {
                if (!message.isString())
                    return evaluator.typeError("an error dict with a string at `msg");
            },
            2 => if (found) |word| {
                if (word != .symbol)
                    return evaluator.typeError("an error dict with a symbol at `word");
            },
            3 => if (found) |trace| {
                if (trace != .list)
                    return evaluator.typeError("an error dict with symbols at `trace");
                self.trace = trace;
                self.trace_index = 0;
                self.phase = .trace;
            },
            4 => if (found) |data| {
                if (data != .dict)
                    return evaluator.typeError("an error dict with a dict at `data");
            },
            else => unreachable,
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
pub fn ioPp(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
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
        return switch (try self.render.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |rendered| completed: {
                defer evaluator.allocator().free(rendered);
                evaluator.unit.inherited.runtime().console.writeOutput(rendered, true) catch
                    return evaluator.fail(.io, "standard output write failed");
                break :completed .completed;
            },
        };
    }
};

pub fn ioStack(evaluator: *Machine) MachineError!void {
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
        if (!self.snapshot.borrowMut().advanceCapture(evaluator)) return .stepped;

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
            switch (try self.render.?.borrowMut().advance(evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |text| {
                    self.render.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.render = null;
                    self.rendered = .init(text);
                    return .stepped;
                },
            }
        }

        if (!self.prefix_written) {
            try writeStackDisplayChunk(evaluator, prefix, false);
            self.prefix_written = true;
            return .stepped;
        }

        const text = self.rendered.?.borrow();
        // Console output is written in chunks of at most 256 bytes, each
        // charged a unit per byte, so a large display spans turns.
        const end = self.written + evaluator.workBudget().take(@min(256, text.len - self.written));
        const complete = end == text.len;
        try writeStackDisplayChunk(evaluator, text[self.written..end], complete);
        self.written = end;
        if (!complete) return .stepped;

        self.rendered.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
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
    evaluator: *Machine,
    bytes: []const u8,
    newline: bool,
) MachineError!void {
    evaluator.unit.inherited.runtime().console.writeOutput(bytes, newline) catch
        return evaluator.fail(.io, "standard output write failed");
}

pub fn ioPrin(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popString();
    defer item.deinit();
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
        return switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "string contains an invalid Unicode scalar",
            ),
        }) {
            .pending => .stepped,
            .complete => |encoded| completed: {
                defer evaluator.allocator().free(encoded);
                evaluator.unit.inherited.runtime().console.writeOutput(encoded, false) catch
                    return evaluator.fail(.io, "standard output write failed");
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
        if (self.name == null) switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "variable name contains an invalid Unicode scalar",
            ),
        }) {
            .pending => return .stepped,
            .complete => |name| self.name = .init(name),
        };
        if (self.text == null) {
            if (self.lookup == null)
                self.lookup = evaluator.environLookup(self.name.?.borrow());
            switch (self.lookup.?.advance(evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |found| {
                    const bytes = found orelse return evaluator.unsetEnvironVariable(
                        self.name.?.borrow(),
                        self.name_value.borrow(),
                    );
                    self.text = .init(.init(evaluator.allocator(), bytes));
                    return .stepped;
                },
            }
        }
        return switch (self.text.?.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return evaluator.fail(
                .io,
                "environment variable value is not valid UTF-8",
            ),
        }) {
            .pending => .stepped,
            .complete => |text| .{ .output = text },
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
        return evaluator.fail(.domain, "exit is available only to the root unit outside @attempt");
    }
    try evaluator.park(.{ .close_scope = @intCast(status.borrow().int) });
}
