//! Closed, identity-guarded phrase recognition with generic fallback.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const storage = @import("kernel_storage.zig");
const numeric = @import("kernel_numeric.zig");
const order = @import("kernel_order.zig");
const sequence = @import("kernel_sequence.zig");
const dict_text = @import("kernel_dict_text.zig");
const combinators = @import("combinators.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const Context = enum { direct, each, zip_with, fold, scan };
pub const DirectOp = enum {
    sort,
    first,
    rest,
    reverse,
    distinct,
    vals,
    dip,

    pub fn spelling(self: DirectOp) []const u8 {
        return @tagName(self);
    }
};
pub const Operation = union(enum) {
    unary: numeric.UnaryOp,
    binary: numeric.BinaryOp,
    direct: DirectOp,

    pub fn spelling(self: Operation) []const u8 {
        return switch (self) {
            .unary => |operation| operation.spelling(),
            .binary => |operation| operation.spelling(),
            .direct => |operation| operation.spelling(),
        };
    }
};
pub const BindingKind = enum { builtin, source };
pub const ExpectedWord = struct {
    spelling: []const u8,
    binding: BindingKind = .builtin,
};
pub const PatternAtom = union(enum) {
    constant,
    /// A literal capture wrapper: a one-element list whose single element
    /// becomes the operation's constant operand. `literal` builds this shape
    /// as `((value) first)`, so `partial` prefixes it onto its quotation.
    capture,
    literal,
    operation,
    word: ExpectedWord,
};
pub const RegistryEntry = struct {
    context: Context,
    pattern: []const PatternAtom,
    operation: Operation,
    constant_left: bool = false,
    source_word: ?[]const u8 = null,
};

const operation_pattern = [_]PatternAtom{.operation};
const constant_operation_pattern = [_]PatternAtom{ .constant, .operation };
const constant_swap_operation_pattern = [_]PatternAtom{
    .constant,
    .{ .word = .{ .spelling = "swap" } },
    .operation,
};
const capture_operation_pattern = [_]PatternAtom{
    .capture,
    .{ .word = .{ .spelling = "first", .binding = .source } },
    .operation,
};
const capture_swap_operation_pattern = [_]PatternAtom{
    .capture,
    .{ .word = .{ .spelling = "first", .binding = .source } },
    .{ .word = .{ .spelling = "swap" } },
    .operation,
};
const sort_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "grade" } },
    .{ .word = .{ .spelling = "at" } },
};
const neg_pattern = [_]PatternAtom{ .literal, .{ .word = .{ .spelling = "*" } } };
const abs_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "neg", .binding = .source } },
    .literal,
    .{ .word = .{ .spelling = "+" } },
    .{ .word = .{ .spelling = "swap" } },
    .{ .word = .{ .spelling = "max" } },
};
const mod_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "over", .binding = .source } },
    .{ .word = .{ .spelling = "over", .binding = .source } },
    .{ .word = .{ .spelling = "div" } },
    .{ .word = .{ .spelling = "*" } },
    .{ .word = .{ .spelling = "-" } },
};
const ne_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "=" } },
    .{ .word = .{ .spelling = "not" } },
};
const le_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = ">" } },
    .{ .word = .{ .spelling = "not" } },
};
const ge_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "<" } },
    .{ .word = .{ .spelling = "not" } },
};
const and_pattern = [_]PatternAtom{
    .literal,
    .{ .word = .{ .spelling = "dip", .binding = .source } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "min" } },
};
const or_pattern = [_]PatternAtom{
    .literal,
    .{ .word = .{ .spelling = "dip", .binding = .source } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "not" } },
    .{ .word = .{ .spelling = "max" } },
};
const first_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "len" } },
    .{ .word = .{ .spelling = "pop" } },
    .literal,
    .{ .word = .{ .spelling = "at" } },
};
const rest_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "first", .binding = .source } },
    .{ .word = .{ .spelling = "pop" } },
    .literal,
    .{ .word = .{ .spelling = "drop" } },
};
const reverse_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "len" } },
    .{ .word = .{ .spelling = "dup" } },
    .literal,
    .{ .word = .{ .spelling = "=" } },
    .literal,
    .literal,
    .{ .word = .{ .spelling = "if" } },
};
const distinct_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "group" } },
    .{ .word = .{ .spelling = "keys" } },
};
const dip_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "swap" } },
    .{ .word = .{ .spelling = "literal", .binding = .source } },
    .{ .word = .{ .spelling = "compose", .binding = .source } },
    .{ .word = .{ .spelling = "call" } },
};
const vals_pattern = [_]PatternAtom{
    .{ .word = .{ .spelling = "dup" } },
    .{ .word = .{ .spelling = "keys" } },
    .{ .word = .{ .spelling = "swap" } },
    .literal,
    .{ .word = .{ .spelling = "partial", .binding = .source } },
    .{ .word = .{ .spelling = "each" } },
};

const unary_count = std.meta.fields(numeric.UnaryOp).len;
const binary_count = std.meta.fields(numeric.BinaryOp).len;
pub const registry = blk: {
    var entries: [unary_count + binary_count * 5 + 8 + 15]RegistryEntry = undefined;
    var index: usize = 0;
    for (std.meta.fields(numeric.UnaryOp)) |field| {
        entries[index] = .{
            .context = .each,
            .pattern = &operation_pattern,
            .operation = .{ .unary = @enumFromInt(field.value) },
        };
        index += 1;
    }
    for (std.meta.fields(numeric.BinaryOp)) |field| {
        const operation: numeric.BinaryOp = @enumFromInt(field.value);
        entries[index] = .{
            .context = .each,
            .pattern = &constant_operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 1] = .{
            .context = .each,
            .pattern = &constant_swap_operation_pattern,
            .operation = .{ .binary = operation },
            .constant_left = true,
        };
        entries[index + 2] = .{
            .context = .zip_with,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 3] = .{
            .context = .each,
            .pattern = &capture_operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 4] = .{
            .context = .each,
            .pattern = &capture_swap_operation_pattern,
            .operation = .{ .binary = operation },
            .constant_left = true,
        };
        index += 5;
    }
    for ([_]numeric.BinaryOp{ .add, .mul, .min, .max }) |operation| {
        entries[index] = .{
            .context = .fold,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        entries[index + 1] = .{
            .context = .scan,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        index += 2;
    }
    for ([_]struct { operation: Operation, pattern: []const PatternAtom }{
        .{ .operation = .{ .unary = .neg }, .pattern = &neg_pattern },
        .{ .operation = .{ .unary = .abs }, .pattern = &abs_pattern },
        .{ .operation = .{ .binary = .mod }, .pattern = &mod_pattern },
        .{ .operation = .{ .binary = .ne }, .pattern = &ne_pattern },
        .{ .operation = .{ .binary = .le }, .pattern = &le_pattern },
        .{ .operation = .{ .binary = .ge }, .pattern = &ge_pattern },
        .{ .operation = .{ .binary = .and_word }, .pattern = &and_pattern },
        .{ .operation = .{ .binary = .or_word }, .pattern = &or_pattern },
    }) |direct| {
        entries[index] = .{
            .context = .direct,
            .pattern = direct.pattern,
            .operation = direct.operation,
            .source_word = direct.operation.spelling(),
        };
        index += 1;
    }
    for ([_]struct { operation: DirectOp, pattern: []const PatternAtom }{
        .{ .operation = .sort, .pattern = &sort_pattern },
        .{ .operation = .first, .pattern = &first_pattern },
        .{ .operation = .rest, .pattern = &rest_pattern },
        .{ .operation = .reverse, .pattern = &reverse_pattern },
        .{ .operation = .distinct, .pattern = &distinct_pattern },
        .{ .operation = .vals, .pattern = &vals_pattern },
        .{ .operation = .dip, .pattern = &dip_pattern },
    }) |direct| {
        entries[index] = .{
            .context = .direct,
            .pattern = direct.pattern,
            .operation = .{ .direct = direct.operation },
            .source_word = direct.operation.spelling(),
        };
        index += 1;
    }
    std.debug.assert(index == entries.len);
    break :blk entries;
};

pub fn tryApply(
    evaluator: *Machine,
    request: machine.IdiomRequest,
    fallback: machine.IdiomFallback,
) MachineError!void {
    if (evaluator.unit.inherited.idiom_mode == .generic_only or requestCandidate(evaluator, request) == null) {
        defer fallback.deinit(evaluator.releaseDomain(), evaluator.allocator());
        return fallback.run(evaluator);
    }
    try evaluator.startDriver(IdiomDriver{
        .candidate = requestCandidate(evaluator, request).?,
        .fallback = .init(fallback),
    });
}

const Candidate = struct {
    context: Context,
    phrase: Value,
    source_word: ?u32 = null,
};
const Capture = struct {
    constant: ?Value = null,
    active_word: ?u32 = null,
    active_index: ?u32 = null,
};

fn requestCandidate(evaluator: *Machine, request: machine.IdiomRequest) ?Candidate {
    const context: Context = switch (request) {
        .direct => .direct,
        .each => .each,
        .zip_with => .zip_with,
        .fold => .fold,
        .scan => .scan,
    };
    const phrase: Value = switch (request) {
        .direct => |direct| .{ .list = direct.body },
        .each => blk: {
            if (evaluator.available() < 2) return null;
            break :blk evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1];
        },
        .zip_with, .fold, .scan => blk: {
            if (evaluator.available() < 3) return null;
            break :blk evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1];
        },
    };
    if (phrase != .list) return null;
    return .{
        .context = context,
        .phrase = phrase,
        .source_word = switch (request) {
            .direct => |direct| direct.word,
            else => null,
        },
    };
}

const IdiomDriver = struct {
    /// Started once per core-origin word application, which is every prelude
    /// word a program calls.
    pub const inline_driver = true;

    candidate: Candidate,
    fallback: heap.Owned(machine.IdiomFallback),
    entry_index: usize = 0,
    atom_index: usize = 0,
    capture: Capture = .{},
    resolution: ?heap.Owned(machine.ResolutionCursor) = null,
    expected: ?env.PrimitiveImpl = null,
    expected_binding: BindingKind = .builtin,

    fn rejectEntry(self: *IdiomDriver) void {
        self.entry_index += 1;
        self.atom_index = 0;
        self.capture = .{};
        self.expected = null;
        self.expected_binding = .builtin;
    }
    fn finish(
        self: *IdiomDriver,
        evaluator: *Machine,
        entry: ?RegistryEntry,
    ) MachineError!machine.WorkProgress {
        const fallback = self.fallback.take();
        const candidate = self.candidate;
        const capture = self.capture;
        if (self.resolution) |*cursor| cursor.deinit(
            evaluator.releaseDomain(),
            evaluator.allocator(),
        );
        self.resolution = null;
        evaluator.detachWorkDriver(self);
        evaluator.finishDriver(self);
        if (entry) |selected| {
            defer fallback.deinit(evaluator.releaseDomain(), evaluator.allocator());
            const direct_parent = if (selected.context == .direct)
                evaluator.commitDirectIdiomTrace()
            else
                null;
            evaluator.unit.idiom_hits += 1;
            applyEntry(evaluator, selected, capture) catch |err| {
                if (err == error.Ecl) {
                    if (capture.active_index) |index| evaluator.setFailureSite(candidate.phrase.list, index);
                    if (direct_parent) |word| evaluator.setFailureTraceParent(word);
                }
                return err;
            };
            if (capture.active_index) |index| {
                evaluator.setWorkDriverSite(candidate.phrase.list, index);
            }
            if (direct_parent) |word| evaluator.setWorkDriverTraceParent(word);
        } else {
            defer fallback.deinit(evaluator.releaseDomain(), evaluator.allocator());
            try fallback.run(evaluator);
        }
        return .detached;
    }
    pub fn advance(evaluator: *Machine, self: *IdiomDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.resolution) |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => continue,
                .complete => |outcome| {
                    cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.resolution = null;
                    var resolved = outcome.binding() orelse {
                        self.rejectEntry();
                        continue;
                    };
                    defer resolved.deinit(evaluator.allocator());
                    const binding_matches = switch (self.expected_binding) {
                        .builtin => resolved.lease.binding == .builtin and
                            (self.expected == null or resolved.lease.binding.builtin == self.expected.?),
                        .source => resolved.lease.binding == .word,
                    };
                    if (resolved.origin != .core or !binding_matches) {
                        self.rejectEntry();
                        continue;
                    }
                    self.atom_index += 1;
                    self.expected = null;
                    self.expected_binding = .builtin;
                    continue;
                },
            };
            if (self.entry_index == registry.len) return self.finish(evaluator, null);
            const entry = registry[self.entry_index];
            if (entry.context != self.candidate.context or
                self.candidate.phrase.list.length() != entry.pattern.len or
                !sourceWordMatches(self.candidate, entry))
            {
                self.rejectEntry();
                continue;
            }
            if (self.atom_index == entry.pattern.len) {
                return self.finish(evaluator, if (canApplyEntry(evaluator, entry)) entry else null);
            }
            const actual = list.atUnchecked(self.candidate.phrase, self.atom_index);
            switch (entry.pattern[self.atom_index]) {
                .constant => {
                    if (self.capture.constant != null or actual == .word) {
                        self.rejectEntry();
                        continue;
                    }
                    self.capture.constant = actual;
                    self.atom_index += 1;
                },
                .capture => {
                    if (self.capture.constant != null or
                        actual != .list or
                        actual.list.length() != 1)
                    {
                        self.rejectEntry();
                        continue;
                    }
                    self.capture.constant = list.atUnchecked(actual, 0);
                    self.atom_index += 1;
                },
                .literal => {
                    if (actual == .word) {
                        self.rejectEntry();
                        continue;
                    }
                    self.atom_index += 1;
                },
                .operation => {
                    const word = if (actual == .word) actual.word else {
                        self.rejectEntry();
                        continue;
                    };
                    if (!std.mem.eql(u8, intern.get(word), entry.operation.spelling())) {
                        self.rejectEntry();
                        continue;
                    }
                    self.capture.active_word = word;
                    self.capture.active_index = @intCast(self.atom_index);
                    self.expected_binding = operationBinding(entry.operation);
                    self.expected = if (self.expected_binding == .builtin)
                        operationPrimitive(entry.operation)
                    else
                        null;
                    self.resolution = .init(.init(evaluator, word));
                },
                .word => |expected_word| {
                    const word = if (actual == .word) actual.word else {
                        self.rejectEntry();
                        continue;
                    };
                    if (!std.mem.eql(u8, intern.get(word), expected_word.spelling)) {
                        self.rejectEntry();
                        continue;
                    }
                    if (std.mem.eql(u8, expected_word.spelling, "grade")) {
                        self.capture.active_word = word;
                        self.capture.active_index = @intCast(self.atom_index);
                    }
                    self.expected_binding = expected_word.binding;
                    self.expected = null;
                    self.resolution = .init(.init(evaluator, word));
                },
            }
        }
        return .yielded;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

fn sourceWordMatches(candidate: Candidate, entry: RegistryEntry) bool {
    const expected = entry.source_word orelse return candidate.source_word == null;
    const actual = candidate.source_word orelse return false;
    return std.mem.eql(u8, intern.get(actual), expected);
}

fn canApplyEntry(evaluator: *Machine, entry: RegistryEntry) bool {
    const stack = evaluator.unit.stack.items;
    return switch (entry.operation) {
        .unary => switch (entry.context) {
            .direct => evaluator.available() >= 1,
            .each => stack[stack.len - 2] == .list,
            else => false,
        },
        .binary => switch (entry.context) {
            .each => stack[stack.len - 2] == .list,
            .zip_with => blk: {
                const right = stack[stack.len - 2];
                const left = stack[stack.len - 3];
                if (left != .list and right != .list) break :blk false;
                break :blk left != .list or right != .list or left.list.length() == right.list.length();
            },
            .fold, .scan => stack[stack.len - 3] == .list,
            .direct => evaluator.available() >= 2,
        },
        // `dip` is the one direct entry that needs a second input, and a
        // non-list top must reach the generic composition so the type error
        // still names the word that observed it.
        .direct => |operation| switch (operation) {
            .dip => evaluator.available() >= 2 and stack[stack.len - 1] == .list,
            else => evaluator.available() >= 1,
        },
    };
}

fn applyEntry(evaluator: *Machine, entry: RegistryEntry, capture: Capture) MachineError!void {
    if (capture.active_word) |word| evaluator.setActiveWord(.plain(word));
    try switch (entry.operation) {
        .unary => |operation| switch (entry.context) {
            .direct => unaryPrimitive(operation)(evaluator),
            .each => applyUnaryEach(evaluator, operation),
            else => unreachable,
        },
        .binary => |operation| switch (entry.context) {
            .each => applyConstantEach(
                evaluator,
                operation,
                capture.constant.?,
                entry.constant_left,
            ),
            .zip_with => applyZipWith(evaluator, operation),
            .fold, .scan => applyReduction(evaluator, operation, entry.context == .scan),
            .direct => binaryPrimitive(operation)(evaluator),
        },
        .direct => |operation| applyDirect(evaluator, operation),
    };
}

fn applyDirect(evaluator: *Machine, operation: DirectOp) MachineError!void {
    try switch (operation) {
        .sort => order.sortForIdiom(evaluator),
        .first => sequence.firstForIdiom(evaluator),
        .rest => sequence.restForIdiom(evaluator),
        .reverse => sequence.reverseForIdiom(evaluator),
        .distinct => order.distinctForIdiom(evaluator),
        .vals => dict_text.valsForIdiom(evaluator),
        .dip => combinators.dipForIdiom(evaluator),
    };
}

fn applyUnaryEach(evaluator: *Machine, operation: numeric.UnaryOp) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    // Over a numeric leaf, applying the operation to each element and pervading
    // over the leaf are the same computation, so the recognizer enters the typed
    // loop rather than driving one cursor and one scheduler turn per element.
    if (numeric.typedUnaryCandidate(input)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var operand = try evaluator.popValue();
        defer operand.deinit();
        return numeric.idiomUnaryStart(operation)(evaluator, &operand);
    }
    const count: usize = @intCast(input.list.length());
    try PervadeEachDriver.install(evaluator, .{ .unary = operation }, input, null, count, 2);
}

fn applyConstantEach(
    evaluator: *Machine,
    operation: numeric.BinaryOp,
    constant: Value,
    constant_left: bool,
) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    if (numeric.typedConstantCandidate(operation, input, constant, constant_left)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var operand = try evaluator.popValue();
        defer operand.deinit();
        // The captured constant is an atom, so it needs no reference of its own:
        // the typed loop reads it with stride zero.
        var scalar = heap.OwnedValue.init(evaluator.releaseDomain(), constant);
        heap.retainValue(constant);
        defer scalar.deinit();
        return if (constant_left)
            numeric.idiomBinaryStart(operation)(evaluator, &scalar, &operand)
        else
            numeric.idiomBinaryStart(operation)(evaluator, &operand, &scalar);
    }
    const count: usize = @intCast(input.list.length());
    try PervadeEachDriver.install(
        evaluator,
        .{ .constant = .{ .operation = operation, .value = constant, .left = constant_left } },
        input,
        null,
        count,
        2,
    );
}

fn applyZipWith(evaluator: *Machine, operation: numeric.BinaryOp) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const right = stack[stack.len - 2];
    const left = stack[stack.len - 3];
    const left_list = left == .list;
    const right_list = right == .list;
    std.debug.assert(left_list or right_list);
    std.debug.assert(!left_list or !right_list or left.list.length() == right.list.length());
    if (numeric.typedBinaryCandidate(operation, left, right)) {
        var quotation = try evaluator.popValue();
        defer quotation.deinit();
        var right_operand = try evaluator.popValue();
        defer right_operand.deinit();
        var left_operand = try evaluator.popValue();
        defer left_operand.deinit();
        return numeric.idiomBinaryStart(operation)(evaluator, &left_operand, &right_operand);
    }
    const count: usize = if (left_list) @intCast(left.list.length()) else @intCast(right.list.length());
    try PervadeEachDriver.install(
        evaluator,
        .{ .zip_with = .{ .operation = operation, .left_list = left_list, .right_list = right_list } },
        left,
        right,
        count,
        3,
    );
}

const PervadeEachDriver = struct {
    const Mode = union(enum) {
        unary: numeric.UnaryOp,
        constant: struct { operation: numeric.BinaryOp, value: Value, left: bool },
        zip_with: struct { operation: numeric.BinaryOp, left_list: bool, right_list: bool },
    };

    mode: Mode,
    left: Value,
    right: ?Value,
    results: heap.Owned(heap.OwnedValueBuffer),
    consumed: usize,
    index: usize = 0,
    cursor: ?heap.Owned(numeric.PervadeCursor) = null,
    materializer: ?heap.Owned(storage.ValueMaterializer) = null,

    fn install(
        evaluator: *Machine,
        mode: Mode,
        left: Value,
        right: ?Value,
        count: usize,
        consumed: usize,
    ) error{OutOfMemory}!void {
        const results = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), count);
        try evaluator.startDriver(PervadeEachDriver{
            .mode = mode,
            .left = left,
            .right = right,
            .results = .init(results),
            .consumed = consumed,
        });
    }

    pub fn advance(evaluator: *Machine, self: *PervadeEachDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.index != self.results.borrow().capacity()) {
            if (self.cursor == null) self.cursor = .init(try self.startCursor(
                evaluator.releaseDomain(),
                evaluator.allocator(),
            ));
            switch (try self.cursor.?.borrowMut().advance(evaluator, machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |result| {
                    self.cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.cursor = null;
                    self.results.borrowMut().appendOwned(result);
                    self.index += 1;
                    return .yielded;
                },
            }
        }
        if (self.materializer == null)
            self.materializer = .init(.init(evaluator.allocator(), self.results.borrow().values()));
        return switch (try self.materializer.?.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                popRelease(evaluator, self.consumed);
                break :completed .{ .output = result };
            },
        };
    }

    fn startCursor(
        self: *PervadeEachDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!numeric.PervadeCursor {
        return switch (self.mode) {
            .unary => |operation| .initUnary(
                releases,
                allocator,
                operation,
                list.atUnchecked(self.left, self.index),
            ),
            .constant => |constant| blk: {
                const item = list.atUnchecked(self.left, self.index);
                break :blk .initBinary(
                    releases,
                    allocator,
                    constant.operation,
                    if (constant.left) constant.value else item,
                    if (constant.left) item else constant.value,
                );
            },
            .zip_with => |zip_with| .initBinary(
                releases,
                allocator,
                zip_with.operation,
                if (zip_with.left_list) list.atUnchecked(self.left, self.index) else self.left,
                if (zip_with.right_list) list.atUnchecked(self.right.?, self.index) else self.right.?,
            ),
        };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn applyReduction(
    evaluator: *Machine,
    operation: numeric.BinaryOp,
    scan: bool,
) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const initial = stack[stack.len - 2];
    const input = stack[stack.len - 3];
    std.debug.assert(input == .list);
    const count: usize = @intCast(input.list.length());
    if (count == 0) {
        if (scan) return finishCollected(evaluator, &.{}, 3);
        popRelease(evaluator, 1);
        var accumulator = try evaluator.popValue();
        defer accumulator.deinit();
        popRelease(evaluator, 1);
        try evaluator.pushOwned(accumulator.take());
        return;
    }
    // Over a numeric leaf with an accumulator the operation preserves, the
    // reduction is one typed sequential pass instead of one cursor and one
    // scheduler turn per element. Association stays strictly left-to-right, so
    // float sums keep the generic route's bits.
    if (numeric.typedReduceCandidate(operation, input, initial)) {
        return numeric.idiomReduceStart(operation)(evaluator, input, initial, scan);
    }
    const results: ?heap.OwnedValueBuffer = if (scan)
        try .init(evaluator.releaseDomain(), count)
    else
        null;
    try evaluator.startDriver(ReductionDriver{
        .operation = operation,
        .scan = scan,
        .input = input,
        .accumulator = .init(.{ .borrowed = initial }),
        .results = if (results) |owned_results| .init(owned_results) else null,
        .materializer = null,
    });
}

const ReductionDriver = struct {
    operation: numeric.BinaryOp,
    scan: bool,
    input: Value,
    accumulator: heap.Owned(Accumulator),
    results: ?heap.Owned(heap.OwnedValueBuffer),
    initialized: usize = 0,
    materializing: bool = false,
    materializer: ?heap.Owned(storage.ValueMaterializer),
    cursor: ?heap.Owned(numeric.PervadeCursor) = null,

    pub fn advance(
        evaluator: *Machine,
        self: *ReductionDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (!self.materializing and self.initialized < self.input.list.length()) {
            if (self.cursor == null) self.cursor = .init(try .initBinary(
                evaluator.releaseDomain(),
                evaluator.allocator(),
                self.operation,
                self.accumulator.borrow().value(),
                list.atUnchecked(self.input, self.initialized),
            ));
            const next = switch (try self.cursor.?.borrowMut().advance(evaluator, machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |result| result,
            };
            self.cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.cursor = null;
            if (self.scan) {
                self.results.?.borrowMut().appendOwned(next);
                self.accumulator.borrowMut().* = .{ .borrowed = next };
            } else {
                self.accumulator.borrowMut().replaceOwned(evaluator.releaseDomain(), next);
            }
            self.initialized += 1;
            return .yielded;
        }
        if (!self.scan) {
            popRelease(evaluator, 3);
            return .{ .output = self.accumulator.borrowMut().takeOwned() };
        }
        if (!self.materializing) {
            self.materializer = .init(.init(
                evaluator.allocator(),
                self.results.?.borrow().values(),
            ));
            self.materializing = true;
        }
        return switch (try self.materializer.?.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                popRelease(evaluator, 3);
                break :completed .{ .output = result };
            },
        };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const Accumulator = union(enum) {
    borrowed: Value,
    owned: Value,
    transferred,

    fn value(self: Accumulator) Value {
        return switch (self) {
            .borrowed, .owned => |item| item,
            .transferred => unreachable,
        };
    }

    fn replaceOwned(self: *Accumulator, releases: *heap.ReleaseDomain, next: Value) void {
        switch (self.*) {
            .borrowed, .transferred => {},
            .owned => |item| releases.releaseValue(item),
        }
        self.* = .{ .owned = next };
    }

    fn takeOwned(self: *Accumulator) Value {
        return switch (self.*) {
            .borrowed => unreachable,
            .owned => |item| taken: {
                self.* = .transferred;
                break :taken item;
            },
            .transferred => unreachable,
        };
    }

    pub fn deinit(self: Accumulator, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .borrowed, .transferred => {},
            .owned => |item| releases.releaseValue(item),
        }
    }
};

fn finishCollected(evaluator: *Machine, values: []const Value, consumed: usize) MachineError!void {
    std.debug.assert(values.len == 0);
    const result = try list.fromValuesGeneric(evaluator.allocator(), values);
    popRelease(evaluator, consumed);
    try evaluator.pushOwned(result);
}

fn popRelease(evaluator: *Machine, count: usize) void {
    evaluator.discard(count);
}

fn operationPrimitive(operation: Operation) ?env.PrimitiveImpl {
    return switch (operation) {
        .unary => |selected| unaryPrimitive(selected),
        .binary => |selected| binaryPrimitive(selected),
        .direct => null,
    };
}

fn operationBinding(operation: Operation) BindingKind {
    return switch (operation) {
        .unary => |selected| switch (selected) {
            .neg, .abs => .source,
            else => .builtin,
        },
        .binary => |selected| switch (selected) {
            .mod, .ne, .le, .ge, .and_word, .or_word => .source,
            else => .builtin,
        },
        .direct => .source,
    };
}

fn unaryPrimitive(operation: numeric.UnaryOp) env.PrimitiveImpl {
    return switch (operation) {
        inline else => |selected| numeric.unaryPrimitiveFor(selected),
    };
}

fn binaryPrimitive(operation: numeric.BinaryOp) env.PrimitiveImpl {
    return switch (operation) {
        inline else => |selected| numeric.binaryPrimitiveFor(selected),
    };
}
