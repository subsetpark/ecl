//! Closed, identity-guarded phrase recognition with generic fallback.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");
const numeric = @import("kernel_numeric.zig");
const order = @import("kernel_order.zig");
const sequence = @import("kernel_sequence.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const Context = enum { direct, each, each2, fold, scan };
pub const Operation = union(enum) {
    unary: numeric.UnaryOp,
    binary: numeric.BinaryOp,
    direct_sort,

    pub fn spelling(self: Operation) []const u8 {
        return switch (self) {
            .unary => |operation| operation.spelling(),
            .binary => |operation| operation.spelling(),
            .direct_sort => "sort",
        };
    }
};
pub const CoreWord = enum {
    dup,
    swap,
    grade,
    at,

    pub fn spelling(self: CoreWord) []const u8 {
        return @tagName(self);
    }
};
pub const PatternAtom = union(enum) {
    constant,
    operation,
    core_word: CoreWord,
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
    .{ .core_word = .swap },
    .operation,
};
const sort_pattern = [_]PatternAtom{
    .{ .core_word = .dup },
    .{ .core_word = .grade },
    .{ .core_word = .at },
};

const unary_count = std.meta.fields(numeric.UnaryOp).len;
const binary_count = std.meta.fields(numeric.BinaryOp).len;
pub const registry = blk: {
    var entries: [unary_count + binary_count * 3 + 9]RegistryEntry = undefined;
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
            .context = .each2,
            .pattern = &operation_pattern,
            .operation = .{ .binary = operation },
        };
        index += 3;
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
    entries[index] = .{
        .context = .direct,
        .pattern = &sort_pattern,
        .operation = .direct_sort,
        .source_word = "sort",
    };
    break :blk entries;
};

pub fn tryApply(evaluator: *Machine, request: machine.IdiomRequest) MachineError!bool {
    if (evaluator.unit.idiom_mode == .generic_only) return false;
    const candidate = requestCandidate(evaluator, request) orelse return false;
    for (registry) |entry| {
        if (entry.context != candidate.context) continue;
        const capture = (try matchPattern(evaluator, candidate.phrase, entry)) orelse continue;
        if (!canApplyEntry(evaluator, entry)) return false;
        const direct_parent = if (entry.context == .direct)
            evaluator.commitDirectIdiomTrace()
        else
            null;
        evaluator.unit.idiom_hits += 1;
        applyEntry(evaluator, entry, capture) catch |err| {
            if (err == error.Ecl) {
                evaluator.setFailureSite(candidate.phrase.list, capture.active_index.?);
                if (direct_parent) |word| evaluator.setFailureTraceParent(word);
            }
            return err;
        };
        return true;
    }
    return false;
}

const Candidate = struct { context: Context, phrase: Value };
const Capture = struct {
    constant: ?Value = null,
    active_word: ?u32 = null,
    active_index: ?u32 = null,
};

fn requestCandidate(evaluator: *Machine, request: machine.IdiomRequest) ?Candidate {
    const context: Context = switch (request) {
        .direct => .direct,
        .each => .each,
        .each2 => .each2,
        .fold => .fold,
        .scan => .scan,
    };
    const phrase: Value = switch (request) {
        .direct => |quotation| .{ .list = quotation },
        .each => blk: {
            if (evaluator.available() < 2) return null;
            break :blk evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1];
        },
        .each2, .fold, .scan => blk: {
            if (evaluator.available() < 3) return null;
            break :blk evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1];
        },
    };
    if (phrase != .list) return null;
    return .{ .context = context, .phrase = phrase };
}

fn matchPattern(
    evaluator: *Machine,
    phrase: Value,
    entry: RegistryEntry,
) MachineError!?Capture {
    if (phrase.list.length() != entry.pattern.len) return null;
    var capture: Capture = .{};
    for (entry.pattern, 0..) |pattern_atom, index| {
        try evaluator.advanceKernel(1);
        const actual = list.atUnchecked(phrase, index);
        switch (pattern_atom) {
            .constant => {
                if (capture.constant != null) return null;
                if (actual == .word) return null;
                capture.constant = actual;
            },
            .operation => {
                const word = if (actual == .word) actual.word else return null;
                if (!std.mem.eql(u8, intern.get(word), entry.operation.spelling()) or
                    !try guardPrimitive(evaluator, word, operationPrimitive(entry.operation))) return null;
                capture.active_word = word;
                capture.active_index = @intCast(index);
            },
            .core_word => |expected_word| {
                const word = if (actual == .word) actual.word else return null;
                if (!std.mem.eql(u8, intern.get(word), expected_word.spelling()) or
                    !try guardPrimitive(evaluator, word, corePrimitive(expected_word))) return null;
                if (expected_word == .grade) {
                    capture.active_word = word;
                    capture.active_index = @intCast(index);
                }
            },
        }
    }
    return capture;
}

fn canApplyEntry(evaluator: *Machine, entry: RegistryEntry) bool {
    const stack = evaluator.unit.stack.items;
    return switch (entry.operation) {
        .unary => stack[stack.len - 2] == .list,
        .binary => switch (entry.context) {
            .each => stack[stack.len - 2] == .list,
            .each2 => blk: {
                const right = stack[stack.len - 2];
                const left = stack[stack.len - 3];
                if (left != .list and right != .list) break :blk false;
                break :blk left != .list or right != .list or left.list.length() == right.list.length();
            },
            .fold, .scan => stack[stack.len - 3] == .list,
            .direct => unreachable,
        },
        .direct_sort => evaluator.available() >= 1 and stack[stack.len - 1] == .list,
    };
}

fn applyEntry(evaluator: *Machine, entry: RegistryEntry, capture: Capture) MachineError!void {
    if (capture.active_word) |word| evaluator.setActiveWord(word);
    try switch (entry.operation) {
        .unary => |operation| applyUnaryEach(evaluator, operation),
        .binary => |operation| switch (entry.context) {
            .each => applyConstantEach(
                evaluator,
                operation,
                capture.constant.?,
                entry.constant_left,
            ),
            .each2 => applyEach2(evaluator, operation),
            .fold, .scan => applyReduction(evaluator, operation, entry.context == .scan),
            .direct => unreachable,
        },
        .direct_sort => applyDirectSort(evaluator),
    };
}

fn applyDirectSort(evaluator: *Machine) MachineError!void {
    try order.sortForIdiom(evaluator);
}

fn applyUnaryEach(evaluator: *Machine, operation: numeric.UnaryOp) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const input = stack[stack.len - 2];
    std.debug.assert(input == .list);
    const count: usize = @intCast(input.list.length());
    const results = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(results);
    var initialized: usize = 0;
    defer releaseValues(evaluator.allocator(), results[0..initialized]);
    for (results, 0..) |*result, index| {
        try evaluator.advanceKernel(1);
        result.* = try numeric.unaryForTest(evaluator, operation, list.atUnchecked(input, index));
        initialized += 1;
    }
    try finishCollected(evaluator, results, 2);
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
    const count: usize = @intCast(input.list.length());
    const results = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(results);
    var initialized: usize = 0;
    defer releaseValues(evaluator.allocator(), results[0..initialized]);
    for (results, 0..) |*result, index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(input, index);
        result.* = try numeric.binaryForTest(
            evaluator,
            operation,
            if (constant_left) constant else item,
            if (constant_left) item else constant,
        );
        initialized += 1;
    }
    try finishCollected(evaluator, results, 2);
}

fn applyEach2(evaluator: *Machine, operation: numeric.BinaryOp) MachineError!void {
    const stack = evaluator.unit.stack.items;
    const right = stack[stack.len - 2];
    const left = stack[stack.len - 3];
    const left_list = left == .list;
    const right_list = right == .list;
    std.debug.assert(left_list or right_list);
    std.debug.assert(!left_list or !right_list or left.list.length() == right.list.length());
    const count: usize = if (left_list) @intCast(left.list.length()) else @intCast(right.list.length());
    const results = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(results);
    var initialized: usize = 0;
    defer releaseValues(evaluator.allocator(), results[0..initialized]);
    for (results, 0..) |*result, index| {
        try evaluator.advanceKernel(1);
        result.* = try numeric.binaryForTest(
            evaluator,
            operation,
            if (left_list) list.atUnchecked(left, index) else left,
            if (right_list) list.atUnchecked(right, index) else right,
        );
        initialized += 1;
    }
    try finishCollected(evaluator, results, 3);
}

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
        const accumulator = try evaluator.popOwned();
        popRelease(evaluator, 1);
        try evaluator.pushOwned(accumulator);
        return;
    }
    if (scan) {
        const results = try evaluator.allocator().alloc(Value, count);
        defer evaluator.allocator().free(results);
        var initialized: usize = 0;
        defer releaseValues(evaluator.allocator(), results[0..initialized]);
        var accumulator = initial;
        for (results, 0..) |*result, index| {
            try evaluator.advanceKernel(1);
            result.* = try numeric.binaryForTest(
                evaluator,
                operation,
                accumulator,
                list.atUnchecked(input, index),
            );
            accumulator = result.*;
            initialized += 1;
        }
        return finishCollected(evaluator, results, 3);
    }
    var accumulator = initial;
    var accumulator_owned = false;
    defer if (accumulator_owned) heap.releaseValue(evaluator.allocator(), accumulator);
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const next = try numeric.binaryForTest(
            evaluator,
            operation,
            accumulator,
            list.atUnchecked(input, index),
        );
        if (accumulator_owned) heap.releaseValue(evaluator.allocator(), accumulator);
        accumulator = next;
        accumulator_owned = true;
    }
    popRelease(evaluator, 3);
    try evaluator.pushOwned(accumulator);
    accumulator_owned = false;
}

fn finishCollected(evaluator: *Machine, values: []const Value, consumed: usize) MachineError!void {
    const result = try storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    );
    popRelease(evaluator, consumed);
    try evaluator.pushOwned(result);
}

fn popRelease(evaluator: *Machine, count: usize) void {
    for (0..count) |_| heap.releaseValue(evaluator.allocator(), evaluator.unit.stack.pop().?);
}

fn guardPrimitive(evaluator: *Machine, name: u32, expected: ?env.PrimitiveImpl) MachineError!bool {
    var resolved = (try evaluator.resolveName(name)) orelse return false;
    defer resolved.deinit(evaluator.allocator());
    if (resolved.origin != .core or resolved.lease.binding != .builtin) return false;
    return expected == null or resolved.lease.binding.builtin == expected.?;
}

fn operationPrimitive(operation: Operation) ?env.PrimitiveImpl {
    return switch (operation) {
        .unary => |selected| unaryPrimitive(selected),
        .binary => |selected| binaryPrimitive(selected),
        .direct_sort => null,
    };
}

fn corePrimitive(word: CoreWord) ?env.PrimitiveImpl {
    return switch (word) {
        .dup, .swap => null,
        .grade => order.gradePrimitiveForIdiom(),
        .at => sequence.atPrimitiveForIdiom(),
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

fn releaseValues(allocator: std.mem.Allocator, values: []const Value) void {
    for (values) |item| heap.releaseValue(allocator, item);
}
