//! Checked scalar and flat-leaf arithmetic plus d.13 pervasive descent.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const env = @import("env.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;
const HeapKind = value.HeapKind;
const Machine = support.Machine;
const MachineError = support.MachineError;
pub const BinaryOp = support.BinaryOp;
pub const UnaryOp = support.UnaryOp;

const ScalarError = error{ Type, Overflow, Domain };
const ScalarBinary = *const fn (Value, Value) ScalarError!Value;
const ScalarUnary = *const fn (Value) ScalarError!Value;
const binary_op_count = std.meta.fields(BinaryOp).len;
const unary_op_count = std.meta.fields(UnaryOp).len;
const heap_kind_count = std.meta.fields(HeapKind).len;
const FaultMask = [support.fault_block / 64]u64;
const BinaryMatrix = [binary_op_count][heap_kind_count][heap_kind_count]?ScalarBinary;
const UnaryMatrix = [unary_op_count][heap_kind_count]?ScalarUnary;

const binary_matrix: BinaryMatrix = blk: {
    @setEvalBranchQuota(10_000);
    var matrix = std.mem.zeroes(BinaryMatrix);
    for (std.meta.fields(BinaryOp)) |operation_field| {
        const operation: BinaryOp = @enumFromInt(operation_field.value);
        for (std.meta.fields(HeapKind)) |left_field| {
            const left: HeapKind = @enumFromInt(left_field.value);
            for (std.meta.fields(HeapKind)) |right_field| {
                const right: HeapKind = @enumFromInt(right_field.value);
                const left_sample = leafSample(left);
                const right_sample = leafSample(right);
                if (left_sample != null and right_sample != null and
                    supports(operation, left_sample.?, right_sample.?))
                {
                    matrix[operation_field.value][left_field.value][right_field.value] =
                        selectScalar(operation);
                }
            }
        }
    }
    break :blk matrix;
};

const unary_matrix: UnaryMatrix = blk: {
    var matrix = std.mem.zeroes(UnaryMatrix);
    for (std.meta.fields(UnaryOp)) |operation_field| {
        const operation: UnaryOp = @enumFromInt(operation_field.value);
        for (std.meta.fields(HeapKind)) |operand_field| {
            const kind: HeapKind = @enumFromInt(operand_field.value);
            const sample = leafSample(kind);
            if (sample != null and supportsUnary(operation, sample.?)) {
                matrix[operation_field.value][operand_field.value] = selectUnary(operation);
            }
        }
    }
    break :blk matrix;
};

pub fn install(core: *env.Env) error{OutOfMemory}!void {
    inline for (std.meta.fields(BinaryOp)) |field| {
        const operation: BinaryOp = @enumFromInt(field.value);
        try support.installPrimitive(core, operation.spelling(), bindBinary(operation));
    }
    inline for (std.meta.fields(UnaryOp)) |field| {
        const operation: UnaryOp = @enumFromInt(field.value);
        try support.installPrimitive(core, operation.spelling(), bindUnary(operation));
    }
}

fn bindBinary(comptime operation: BinaryOp) env.Primitive {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return binaryPrimitive(evaluator, operation);
        }
    }.run;
}

fn bindUnary(comptime operation: UnaryOp) env.Primitive {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return unaryPrimitive(evaluator, operation);
        }
    }.run;
}

fn binaryPrimitive(evaluator: *Machine, operation: BinaryOp) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);

    if (try tryInPlaceBinary(.{ .evaluator = evaluator }, operation, left, right)) |reused| {
        switch (reused.source) {
            .left => left_owned = false,
            .right => right_owned = false,
        }
        return evaluator.pushOwned(reused.value);
    }

    var result = try pervadeBinary(.{ .evaluator = evaluator }, operation, left, right, 0, null);
    var result_owned = true;
    defer if (result_owned) heap.releaseValue(evaluator.allocator(), result);

    if (canAdopt(left, result)) {
        heap.adoptRepresentation(evaluator.allocator(), left.heapHeader().?, result.heapHeader().?);
        result = left;
        left_owned = false;
        result_owned = false;
    } else if (canAdopt(right, result)) {
        heap.adoptRepresentation(evaluator.allocator(), right.heapHeader().?, result.heapHeader().?);
        result = right;
        right_owned = false;
        result_owned = false;
    }
    result_owned = false;
    try evaluator.pushOwned(result);
}

/// Test hook for proving the full pervasive kernel without constructing an
/// env binding. Inputs are borrowed; the result is owned by the caller.
pub fn binaryForTest(
    evaluator: *Machine,
    operation: BinaryOp,
    left: Value,
    right: Value,
) MachineError!Value {
    return pervadeBinary(.{ .evaluator = evaluator }, operation, left, right, 0, null);
}

fn unaryPrimitive(evaluator: *Machine, operation: UnaryOp) MachineError!void {
    const operand = try evaluator.popOwned();
    var operand_owned = true;
    defer if (operand_owned) heap.releaseValue(evaluator.allocator(), operand);
    if (try tryInPlaceUnary(.{ .evaluator = evaluator }, operation, operand)) |result| {
        operand_owned = false;
        return evaluator.pushOwned(result);
    }
    var result = try pervadeUnary(.{ .evaluator = evaluator }, operation, operand, 0, null);
    var result_owned = true;
    defer if (result_owned) heap.releaseValue(evaluator.allocator(), result);
    if (canAdopt(operand, result)) {
        heap.adoptRepresentation(evaluator.allocator(), operand.heapHeader().?, result.heapHeader().?);
        result = operand;
        operand_owned = false;
        result_owned = false;
    }
    result_owned = false;
    try evaluator.pushOwned(result);
}

const ReuseSource = enum { left, right };
const Reused = struct { value: Value, source: ReuseSource };

fn tryInPlaceBinary(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
) MachineError!?Reused {
    const left_flat = left == .list and isFlat(left.list);
    const right_flat = right == .list and isFlat(right.list);
    if (!left_flat and !right_flat) return null;
    if (left == .list and !left_flat or right == .list and !right_flat) return null;
    if (left == .dict or right == .dict) return null;
    const count: usize = if (left_flat)
        @intCast(left.list.len)
    else
        @intCast(right.list.len);
    if (left_flat and right_flat and left.list.len != right.list.len) return null;
    if (count == 0) return null;
    const scalar = if (left_flat and right_flat)
        selectLeafBinary(operation, left.list.kind(), right.list.kind()) orelse return null
    else
        selectScalar(operation);
    const left_scalar = !left_flat;
    const right_scalar = !right_flat;
    const range = support.IndexRange.init(0, count);
    var left_compatible = left_flat and heap.isUnique(left.list);
    var right_compatible = right_flat and heap.isUnique(right.list);
    if (!left_compatible and !right_compatible) return null;

    for (range.start..range.end) |index| {
        try context.poll();
        const a = if (left_scalar) left else list.atUnchecked(left, index);
        const b = if (right_scalar) right else list.atUnchecked(right, index);
        const result = scalar(a, b) catch |fault| return scalarFailure(context, fault, index);
        left_compatible = left_compatible and valueFitsKind(result, left.list.kind());
        right_compatible = right_compatible and valueFitsKind(result, right.list.kind());
    }
    const source: ReuseSource = if (left_compatible)
        .left
    else if (right_compatible)
        .right
    else
        return null;
    const destination = if (source == .left) left else right;
    for (range.start..range.end) |index| {
        try context.poll();
        const a = if (left_scalar) left else list.atUnchecked(left, index);
        const b = if (right_scalar) right else list.atUnchecked(right, index);
        const result = scalar(a, b) catch |fault| return scalarFailure(context, fault, index);
        writeValue(destination.list, index, result);
    }
    return .{ .value = destination, .source = source };
}

fn tryInPlaceUnary(
    context: support.Context,
    operation: UnaryOp,
    operand: Value,
) MachineError!?Value {
    if (operand != .list or !isFlat(operand.list) or
        !heap.isUnique(operand.list) or operand.list.len == 0) return null;
    const scalar = selectLeafUnary(operation, operand.list.kind()) orelse return null;
    const count: usize = @intCast(operand.list.len);
    const range = support.IndexRange.init(0, count);
    for (range.start..range.end) |index| {
        try context.poll();
        const result = scalar(list.atUnchecked(operand, index)) catch |fault|
            return scalarFailure(context, fault, index);
        if (!valueFitsKind(result, operand.list.kind())) return null;
    }
    for (range.start..range.end) |index| {
        try context.poll();
        const result = scalar(list.atUnchecked(operand, index)) catch |fault|
            return scalarFailure(context, fault, index);
        writeValue(operand.list, index, result);
    }
    return operand;
}

fn valueFitsKind(item: Value, kind: HeapKind) bool {
    return switch (kind) {
        .leaf_i64 => item == .int,
        .leaf_f64 => item == .float,
        .leaf_char1 => item == .char and item.char <= std.math.maxInt(u8),
        .leaf_char2 => item == .char and item.char <= std.math.maxInt(u16),
        .leaf_char4 => item == .char,
        .leaf_symbol => item == .symbol,
        .generic_spine, .dict, .reserved_mask => false,
    };
}

fn writeValue(header: *value.Header, index: usize, item: Value) void {
    std.debug.assert(valueFitsKind(item, header.kind()));
    switch (header.kind()) {
        .leaf_i64 => heap.items(i64, header)[index] = item.int,
        .leaf_f64 => heap.items(f64, header)[index] = item.float,
        .leaf_char1 => heap.items(u8, header)[index] = @intCast(item.char),
        .leaf_char2 => heap.items(u16, header)[index] = @intCast(item.char),
        .leaf_char4 => heap.items(u32, header)[index] = item.char,
        .leaf_symbol => heap.items(u32, header)[index] = item.symbol,
        .generic_spine, .dict, .reserved_mask => unreachable,
    }
}

/// Test hook matching `binaryForTest` for unary pervasion.
pub fn unaryForTest(
    evaluator: *Machine,
    operation: UnaryOp,
    operand: Value,
) MachineError!Value {
    return pervadeUnary(.{ .evaluator = evaluator }, operation, operand, 0, null);
}

fn canAdopt(candidate: Value, result: Value) bool {
    const candidate_header = candidate.heapHeader() orelse return false;
    const result_header = result.heapHeader() orelse return false;
    return candidate_header != result_header and
        candidate_header.kind() == result_header.kind() and
        heap.isUnique(candidate_header) and heap.isUnique(result_header);
}

pub fn pervadeBinary(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
    depth: usize,
    logical_index: ?usize,
) MachineError!Value {
    if (depth >= support.max_depth and
        (left == .list or left == .dict or right == .list or right == .dict))
    {
        return context.evaluator.fail(.domain, "pervasion nesting exceeds 256 levels");
    }
    // Dicts are the outer pervasive structure: preserve their keys and recurse
    // through values even when the other operand is a list.
    if (left == .dict and right == .dict) {
        return dictBinary(context, operation, left, right, depth);
    }
    if (left == .dict) return dictScalarRight(context, operation, left, right, depth);
    if (right == .dict) return scalarLeftDict(context, operation, left, right, depth);
    if (left == .list and right == .list) {
        const left_len: usize = @intCast(left.list.len);
        const right_len: usize = @intCast(right.list.len);
        if (left_len != right_len) return context.evaluator.conformError(left_len, right_len);
        if (isFlat(left.list) and isFlat(right.list)) {
            return flatBinary(context, operation, left, right, left_len);
        }
        return listBinary(context, operation, left, right, depth);
    }
    if (left == .list) {
        if (isFlat(left.list) and isAtom(right)) {
            return flatScalarRight(context, operation, left, right);
        }
        return listScalarRight(context, operation, left, right, depth);
    }
    if (right == .list) {
        if (isAtom(left) and isFlat(right.list)) {
            return scalarLeftFlat(context, operation, left, right);
        }
        return scalarLeftList(context, operation, left, right, depth);
    }
    return applyScalar(context, selectScalar(operation), left, right, logical_index);
}

pub fn pervadeUnary(
    context: support.Context,
    operation: UnaryOp,
    operand: Value,
    depth: usize,
    logical_index: ?usize,
) MachineError!Value {
    if (depth >= support.max_depth and (operand == .list or operand == .dict)) {
        return context.evaluator.fail(.domain, "pervasion nesting exceeds 256 levels");
    }
    if (operand == .list) {
        if (isFlat(operand.list)) return flatUnary(context, operation, operand);
        const count: usize = @intCast(operand.list.len);
        const results = try context.allocator().alloc(Value, count);
        defer context.allocator().free(results);
        var initialized: usize = 0;
        defer releaseValues(context.allocator(), results[0..initialized]);
        for (0..count) |index| {
            try context.poll();
            results[index] = try pervadeUnary(
                context,
                operation,
                list.atUnchecked(operand, index),
                depth + 1,
                index,
            );
            initialized += 1;
        }
        return storage.fromValues(context.allocator(), results, context.structuralPoller());
    }
    if (operand == .dict) {
        const count: usize = @intCast(operand.dict.len);
        const pairs = try context.allocator().alloc(dict.Pair, count);
        defer context.allocator().free(pairs);
        var initialized: usize = 0;
        defer for (pairs[0..initialized]) |pair| heap.releaseValue(context.allocator(), pair[1]);
        for (0..count) |index| {
            try context.poll();
            pairs[index] = .{
                dict.keyAt(operand.dict, index),
                try pervadeUnary(context, operation, dict.valueAt(operand.dict, index), depth + 1, index),
            };
            initialized += 1;
        }
        return storage.fromUniquePairs(
            context.allocator(),
            pairs,
            context.structuralPoller(),
        );
    }
    return applyUnary(context, selectUnary(operation), operand, logical_index);
}

fn flatBinary(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
    count: usize,
) MachineError!Value {
    if (count == 0) return storage.fromValues(context.allocator(), &.{}, context.structuralPoller());
    const scalar = selectLeafBinary(operation, left.list.kind(), right.list.kind()) orelse
        return scalarFailure(context, error.Type, 0);
    return runFlatBinary(
        context,
        scalar,
        left,
        right,
        support.IndexRange.init(0, count),
        false,
        false,
    );
}

fn flatScalarRight(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
) MachineError!Value {
    const count: usize = @intCast(left.list.len);
    const scalar = selectScalar(operation);
    if (count > 0 and !supports(operation, list.atUnchecked(left, 0), right)) {
        return scalarFailure(context, error.Type, 0);
    }
    return runFlatBinary(
        context,
        scalar,
        left,
        right,
        support.IndexRange.init(0, count),
        false,
        true,
    );
}

fn scalarLeftFlat(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
) MachineError!Value {
    const count: usize = @intCast(right.list.len);
    const scalar = selectScalar(operation);
    if (count > 0 and !supports(operation, left, list.atUnchecked(right, 0))) {
        return scalarFailure(context, error.Type, 0);
    }
    return runFlatBinary(
        context,
        scalar,
        left,
        right,
        support.IndexRange.init(0, count),
        true,
        false,
    );
}

fn runFlatBinary(
    context: support.Context,
    scalar: ScalarBinary,
    left: Value,
    right: Value,
    range: support.IndexRange,
    left_scalar: bool,
    right_scalar: bool,
) MachineError!Value {
    const results = try context.allocator().alloc(Value, range.len());
    defer context.allocator().free(results);
    var block_start = range.start;
    while (block_start < range.end) {
        const block_end = @min(block_start + support.fault_block, range.end);
        try context.advance(block_end - block_start);
        var scratch: [support.fault_block]Value = undefined;
        var faults: FaultMask = @splat(0);
        for (block_start..block_end) |index| {
            const a = if (left_scalar) left else list.atUnchecked(left, index);
            const b = if (right_scalar) right else list.atUnchecked(right, index);
            scratch[index - block_start] = scalar(a, b) catch {
                markFault(&faults, index - block_start);
                continue;
            };
        }
        if (hasFault(faults)) {
            for (block_start..block_end) |index| {
                const a = if (left_scalar) left else list.atUnchecked(left, index);
                const b = if (right_scalar) right else list.atUnchecked(right, index);
                _ = scalar(a, b) catch |fault| return scalarFailure(context, fault, index);
            }
            return context.evaluator.fail(.domain, "kernel fault mask changed during scalar rescan");
        }
        const output_start = block_start - range.start;
        @memcpy(
            results[output_start .. output_start + block_end - block_start],
            scratch[0 .. block_end - block_start],
        );
        block_start = block_end;
    }
    return storage.fromValues(context.allocator(), results, context.structuralPoller());
}

fn flatUnary(context: support.Context, operation: UnaryOp, operand: Value) MachineError!Value {
    const count: usize = @intCast(operand.list.len);
    if (count == 0) return storage.fromValues(context.allocator(), &.{}, context.structuralPoller());
    const scalar = selectLeafUnary(operation, operand.list.kind()) orelse
        return scalarFailure(context, error.Type, 0);
    const range = support.IndexRange.init(0, count);
    const results = try context.allocator().alloc(Value, range.len());
    defer context.allocator().free(results);
    var block_start = range.start;
    while (block_start < range.end) {
        const block_end = @min(block_start + support.fault_block, range.end);
        try context.advance(block_end - block_start);
        var scratch: [support.fault_block]Value = undefined;
        var faults: FaultMask = @splat(0);
        for (block_start..block_end) |index| {
            scratch[index - block_start] = scalar(list.atUnchecked(operand, index)) catch {
                markFault(&faults, index - block_start);
                continue;
            };
        }
        if (hasFault(faults)) {
            for (block_start..block_end) |index| {
                _ = scalar(list.atUnchecked(operand, index)) catch |fault|
                    return scalarFailure(context, fault, index);
            }
            return context.evaluator.fail(.domain, "kernel fault mask changed during scalar rescan");
        }
        const output_start = block_start - range.start;
        @memcpy(
            results[output_start .. output_start + block_end - block_start],
            scratch[0 .. block_end - block_start],
        );
        block_start = block_end;
    }
    return storage.fromValues(context.allocator(), results, context.structuralPoller());
}

fn markFault(mask: *FaultMask, index: usize) void {
    mask[index / 64] |= @as(u64, 1) << @intCast(index % 64);
}

fn hasFault(mask: FaultMask) bool {
    for (mask) |word| if (word != 0) return true;
    return false;
}

fn listBinary(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
    depth: usize,
) MachineError!Value {
    const count: usize = @intCast(left.list.len);
    const results = try context.allocator().alloc(Value, count);
    defer context.allocator().free(results);
    var initialized: usize = 0;
    defer releaseValues(context.allocator(), results[0..initialized]);
    for (0..count) |index| {
        try context.poll();
        results[index] = try pervadeBinary(
            context,
            operation,
            list.atUnchecked(left, index),
            list.atUnchecked(right, index),
            depth + 1,
            index,
        );
        initialized += 1;
    }
    return storage.fromValues(context.allocator(), results, context.structuralPoller());
}

fn listScalarRight(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
    depth: usize,
) MachineError!Value {
    const count: usize = @intCast(left.list.len);
    const results = try context.allocator().alloc(Value, count);
    defer context.allocator().free(results);
    var initialized: usize = 0;
    defer releaseValues(context.allocator(), results[0..initialized]);
    for (0..count) |index| {
        try context.poll();
        results[index] = try pervadeBinary(
            context,
            operation,
            list.atUnchecked(left, index),
            right,
            depth + 1,
            index,
        );
        initialized += 1;
    }
    return storage.fromValues(context.allocator(), results, context.structuralPoller());
}

fn scalarLeftList(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
    depth: usize,
) MachineError!Value {
    const count: usize = @intCast(right.list.len);
    const results = try context.allocator().alloc(Value, count);
    defer context.allocator().free(results);
    var initialized: usize = 0;
    defer releaseValues(context.allocator(), results[0..initialized]);
    for (0..count) |index| {
        try context.poll();
        results[index] = try pervadeBinary(
            context,
            operation,
            left,
            list.atUnchecked(right, index),
            depth + 1,
            index,
        );
        initialized += 1;
    }
    return storage.fromValues(context.allocator(), results, context.structuralPoller());
}

fn dictBinary(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    right: Value,
    depth: usize,
) MachineError!Value {
    const left_count: usize = @intCast(left.dict.len);
    const right_count: usize = @intCast(right.dict.len);
    const pairs = try context.allocator().alloc(dict.Pair, left_count + right_count);
    defer context.allocator().free(pairs);
    const owned = try context.allocator().alloc(bool, left_count + right_count);
    defer context.allocator().free(owned);
    for (owned) |*item_owned| {
        try context.poll();
        item_owned.* = false;
    }
    var count: usize = 0;
    defer for (pairs[0..count], owned[0..count]) |pair, is_owned| {
        if (is_owned) heap.releaseValue(context.allocator(), pair[1]);
    };
    for (0..left_count) |index| {
        try context.poll();
        const key = dict.keyAt(left.dict, index);
        const right_value = storage.get(
            context.allocator(),
            right,
            key,
            context.structuralPoller(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return error.Ecl,
            error.NotADict => unreachable,
        };
        pairs[count] = .{ key, if (right_value) |item|
            try pervadeBinary(context, operation, dict.valueAt(left.dict, index), item, depth + 1, index)
        else
            dict.valueAt(left.dict, index) };
        owned[count] = right_value != null;
        count += 1;
    }
    for (0..right_count) |index| {
        try context.poll();
        const key = dict.keyAt(right.dict, index);
        const left_value = storage.get(
            context.allocator(),
            left,
            key,
            context.structuralPoller(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return error.Ecl,
            error.NotADict => unreachable,
        };
        if (left_value != null) continue;
        pairs[count] = .{ key, dict.valueAt(right.dict, index) };
        count += 1;
    }
    return storage.fromUniquePairs(
        context.allocator(),
        pairs[0..count],
        context.structuralPoller(),
    );
}

fn dictScalarRight(
    context: support.Context,
    operation: BinaryOp,
    dictionary: Value,
    right: Value,
    depth: usize,
) MachineError!Value {
    return mapDict(context, dictionary, struct {
        fn apply(ctx: support.Context, op: BinaryOp, item: Value, other: Value, d: usize, i: usize) MachineError!Value {
            return pervadeBinary(ctx, op, item, other, d + 1, i);
        }
    }.apply, operation, right, depth);
}

fn scalarLeftDict(
    context: support.Context,
    operation: BinaryOp,
    left: Value,
    dictionary: Value,
    depth: usize,
) MachineError!Value {
    const count: usize = @intCast(dictionary.dict.len);
    const pairs = try context.allocator().alloc(dict.Pair, count);
    defer context.allocator().free(pairs);
    var initialized: usize = 0;
    defer for (pairs[0..initialized]) |pair| heap.releaseValue(context.allocator(), pair[1]);
    for (0..count) |index| {
        try context.poll();
        pairs[index] = .{
            dict.keyAt(dictionary.dict, index),
            try pervadeBinary(
                context,
                operation,
                left,
                dict.valueAt(dictionary.dict, index),
                depth + 1,
                index,
            ),
        };
        initialized += 1;
    }
    return storage.fromUniquePairs(
        context.allocator(),
        pairs,
        context.structuralPoller(),
    );
}

fn mapDict(
    context: support.Context,
    dictionary: Value,
    comptime apply: anytype,
    operation: BinaryOp,
    other: Value,
    depth: usize,
) MachineError!Value {
    const count: usize = @intCast(dictionary.dict.len);
    const pairs = try context.allocator().alloc(dict.Pair, count);
    defer context.allocator().free(pairs);
    var initialized: usize = 0;
    defer for (pairs[0..initialized]) |pair| heap.releaseValue(context.allocator(), pair[1]);
    for (0..count) |index| {
        try context.poll();
        pairs[index] = .{
            dict.keyAt(dictionary.dict, index),
            try apply(
                context,
                operation,
                dict.valueAt(dictionary.dict, index),
                other,
                depth,
                index,
            ),
        };
        initialized += 1;
    }
    return storage.fromUniquePairs(
        context.allocator(),
        pairs,
        context.structuralPoller(),
    );
}

fn selectLeafBinary(operation: BinaryOp, left: HeapKind, right: HeapKind) ?ScalarBinary {
    return binary_matrix[@intFromEnum(operation)][@intFromEnum(left)][@intFromEnum(right)];
}

pub fn matrixEntryForTest(operation: BinaryOp, left: HeapKind, right: HeapKind) bool {
    return selectLeafBinary(operation, left, right) != null;
}

fn selectLeafUnary(operation: UnaryOp, operand: HeapKind) ?ScalarUnary {
    return unary_matrix[@intFromEnum(operation)][@intFromEnum(operand)];
}

fn selectScalar(operation: BinaryOp) ScalarBinary {
    return switch (operation) {
        inline else => |comptime_operation| struct {
            fn run(left: Value, right: Value) ScalarError!Value {
                return scalarBinary(comptime_operation, left, right);
            }
        }.run,
    };
}

fn selectUnary(operation: UnaryOp) ScalarUnary {
    return switch (operation) {
        inline else => |comptime_operation| struct {
            fn run(operand: Value) ScalarError!Value {
                return scalarUnary(comptime_operation, operand);
            }
        }.run,
    };
}

fn applyScalar(
    context: support.Context,
    scalar: ScalarBinary,
    left: Value,
    right: Value,
    index: ?usize,
) MachineError!Value {
    return scalar(left, right) catch |fault| scalarFailure(context, fault, index);
}

fn applyUnary(
    context: support.Context,
    scalar: ScalarUnary,
    operand: Value,
    index: ?usize,
) MachineError!Value {
    return scalar(operand) catch |fault| scalarFailure(context, fault, index);
}

fn scalarFailure(context: support.Context, fault: ScalarError, index: ?usize) MachineError {
    const kind: @import("machine.zig").ErrorKind = switch (fault) {
        error.Type => .type,
        error.Overflow => .overflow,
        error.Domain => .domain,
    };
    const message = switch (fault) {
        error.Type => "kernel received incompatible scalar operands",
        error.Overflow => "kernel arithmetic overflow",
        error.Domain => "kernel arithmetic is outside its domain",
    };
    if (index) |logical_index| return context.failAt(kind, message, logical_index);
    return context.evaluator.fail(kind, message);
}

fn scalarBinary(comptime operation: BinaryOp, left: Value, right: Value) ScalarError!Value {
    return switch (operation) {
        .add => add(left, right),
        .sub => sub(left, right),
        .mul => numericBinary(left, right, operation),
        .div => divide(left, right),
        .int_div => integerDivision(left, right, false),
        .mod => integerDivision(left, right, true),
        .pow => power(left, right),
        .atan2 => atan2(left, right),
        .min, .max => minMax(left, right, operation == .min),
        .eq, .ne, .lt, .gt, .le, .ge => comparison(left, right, operation),
        .and_word, .or_word => booleanBinary(left, right, operation == .and_word),
    };
}

fn scalarUnary(comptime operation: UnaryOp, operand: Value) ScalarError!Value {
    return switch (operation) {
        .not_word => .{ .int = @intFromBool(!(try boolean(operand))) },
        .neg => switch (operand) {
            .int => |integer| .{ .int = std.math.sub(i64, 0, integer) catch return error.Overflow },
            .float => |number| try checkedFloat(-number, !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict => error.Type,
        },
        .abs => switch (operand) {
            .int => |integer| if (integer == std.math.minInt(i64))
                error.Overflow
            else
                .{ .int = if (integer < 0) -integer else integer },
            .float => |number| try checkedFloat(@abs(number), !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict => error.Type,
        },
        .sqrt => switch (operand) {
            .int => |integer| if (integer < 0)
                error.Domain
            else
                try checkedFloat(@sqrt(@as(f64, @floatFromInt(integer))), false),
            .float => |number| if (number < 0.0)
                error.Domain
            else
                try checkedFloat(@sqrt(number), !std.math.isFinite(number)),
            .char, .symbol, .word, .list, .dict => error.Type,
        },
        .floor, .ceil, .round => switch (operand) {
            .int => operand,
            .float => |number| floatToInt(switch (operation) {
                .floor => @floor(number),
                .ceil => @ceil(number),
                .round => @round(number),
                else => unreachable,
            }),
            .char, .symbol, .word, .list, .dict => error.Type,
        },
        .exp, .log, .sin, .cos => transcendental(operation, operand),
    };
}

fn add(left: Value, right: Value) ScalarError!Value {
    if (left == .char and right == .int) return offsetChar(left.char, right.int);
    if (left == .int and right == .char) return offsetChar(right.char, left.int);
    if (left == .char or right == .char) return error.Type;
    return numericBinary(left, right, .add);
}

fn sub(left: Value, right: Value) ScalarError!Value {
    if (left == .char and right == .char) {
        return .{ .int = @as(i64, left.char) - @as(i64, right.char) };
    }
    if (left == .char and right == .int) {
        const offset = std.math.sub(i64, 0, right.int) catch return error.Overflow;
        return offsetChar(left.char, offset);
    }
    if (left == .char or right == .char) return error.Type;
    return numericBinary(left, right, .sub);
}

fn numericBinary(left: Value, right: Value, operation: BinaryOp) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    if (left == .int and right == .int) {
        return .{ .int = switch (operation) {
            .add => std.math.add(i64, left.int, right.int) catch return error.Overflow,
            .sub => std.math.sub(i64, left.int, right.int) catch return error.Overflow,
            .mul => std.math.mul(i64, left.int, right.int) catch return error.Overflow,
            else => unreachable,
        } };
    }
    const a = asFloat(left);
    const b = asFloat(right);
    const result = switch (operation) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        else => unreachable,
    };
    return checkedFloat(result, !std.math.isFinite(a) or !std.math.isFinite(b));
}

fn divide(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    const a = asFloat(left);
    const b = asFloat(right);
    if (b == 0.0) return error.Domain;
    return checkedFloat(a / b, !std.math.isFinite(a) or !std.math.isFinite(b));
}

fn integerDivision(left: Value, right: Value, remainder: bool) ScalarError!Value {
    if (left != .int or right != .int) return error.Type;
    if (right.int == 0) return error.Domain;
    if (left.int == std.math.minInt(i64) and right.int == -1) return error.Overflow;
    return .{ .int = if (remainder)
        @rem(left.int, right.int)
    else
        @divTrunc(left.int, right.int) };
}

fn power(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    const a = asFloat(left);
    const b = asFloat(right);
    return checkedFloat(std.math.pow(f64, a, b), !std.math.isFinite(a) or !std.math.isFinite(b));
}

fn atan2(left: Value, right: Value) ScalarError!Value {
    if (!left.isNumber() or !right.isNumber()) return error.Type;
    const y = asFloat(left);
    const x = asFloat(right);
    return checkedFloat(
        std.math.atan2(y, x),
        !std.math.isFinite(y) or !std.math.isFinite(x),
    );
}

fn transcendental(operation: UnaryOp, operand: Value) ScalarError!Value {
    if (!operand.isNumber()) return error.Type;
    const number = asFloat(operand);
    const result = switch (operation) {
        .exp => @exp(number),
        .log => @log(number),
        .sin => @sin(number),
        .cos => @cos(number),
        .neg, .abs, .sqrt, .floor, .ceil, .round, .not_word => unreachable,
    };
    return checkedFloat(result, !std.math.isFinite(number));
}

fn minMax(left: Value, right: Value, choose_min: bool) ScalarError!Value {
    const ordering = equal.compareScalars(left, right) catch return error.Type;
    const choose_left = if (choose_min) ordering != .gt else ordering != .lt;
    return if (choose_left) left else right;
}

fn comparison(left: Value, right: Value, operation: BinaryOp) ScalarError!Value {
    const ordering = equal.compareScalars(left, right) catch return error.Type;
    const result = switch (operation) {
        .eq => ordering == .eq,
        .ne => ordering != .eq,
        .lt => ordering == .lt,
        .gt => ordering == .gt,
        .le => ordering != .gt,
        .ge => ordering != .lt,
        else => unreachable,
    };
    return .{ .int = @intFromBool(result) };
}

fn booleanBinary(left: Value, right: Value, conjunction: bool) ScalarError!Value {
    const a = try boolean(left);
    const b = try boolean(right);
    return .{ .int = @intFromBool(if (conjunction) a and b else a or b) };
}

fn boolean(operand: Value) ScalarError!bool {
    if (operand != .int or (operand.int != 0 and operand.int != 1)) return error.Type;
    return operand.int == 1;
}

fn offsetChar(codepoint: u32, offset: i64) ScalarError!Value {
    const adjusted = std.math.add(i64, @intCast(codepoint), offset) catch return error.Domain;
    if (adjusted < 0 or adjusted > 0x10ffff) return error.Domain;
    const result: u32 = @intCast(adjusted);
    if (result >= 0xd800 and result <= 0xdfff) return error.Domain;
    return .{ .char = result };
}

fn checkedFloat(result: f64, propagating: bool) ScalarError!Value {
    if (std.math.isNan(result)) return error.Domain;
    if (std.math.isInf(result) and !propagating) return error.Overflow;
    return .{ .float = result };
}

fn floatToInt(number: f64) ScalarError!Value {
    const lower: f64 = -9_223_372_036_854_775_808.0;
    const upper: f64 = 9_223_372_036_854_775_808.0;
    if (!std.math.isFinite(number) or number < lower or number >= upper) return error.Overflow;
    return .{ .int = @intFromFloat(number) };
}

fn asFloat(operand: Value) f64 {
    return switch (operand) {
        .int => |integer| @floatFromInt(integer),
        .float => |number| number,
        .char, .symbol, .word, .list, .dict => unreachable,
    };
}

fn supports(operation: BinaryOp, left: Value, right: Value) bool {
    return switch (operation) {
        .add => (left.isNumber() and right.isNumber()) or
            (left == .char and right == .int) or (left == .int and right == .char),
        .sub => (left.isNumber() and right.isNumber()) or
            (left == .char and (right == .char or right == .int)),
        .mul, .div, .pow, .atan2 => left.isNumber() and right.isNumber(),
        .int_div, .mod, .and_word, .or_word => left == .int and right == .int,
        .min, .max, .eq, .ne, .lt, .gt, .le, .ge => (left.isNumber() and right.isNumber()) or (left == .char and right == .char),
    };
}

fn supportsUnary(operation: UnaryOp, operand: Value) bool {
    return switch (operation) {
        .neg, .abs, .sqrt, .floor, .ceil, .round, .exp, .log, .sin, .cos => operand.isNumber(),
        .not_word => operand == .int,
    };
}

fn leafSample(kind: HeapKind) ?Value {
    return switch (kind) {
        .leaf_i64 => .{ .int = 0 },
        .leaf_f64 => .{ .float = 0.0 },
        .leaf_char1, .leaf_char2, .leaf_char4 => .{ .char = 0 },
        .leaf_symbol => .{ .symbol = 0 },
        .generic_spine, .dict, .reserved_mask => null,
    };
}

fn isFlat(header: *value.Header) bool {
    return switch (header.kind()) {
        .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => true,
        .generic_spine, .dict, .reserved_mask => false,
    };
}

fn isAtom(item: Value) bool {
    return switch (item) {
        .int, .float, .char, .symbol, .word => true,
        .list, .dict => false,
    };
}

fn releaseValues(allocator: std.mem.Allocator, values: []const Value) void {
    for (values) |item| heap.releaseValue(allocator, item);
}

test "numeric dispatch matrix rejects symbols explicitly" {
    try std.testing.expect(selectLeafBinary(.add, .leaf_i64, .leaf_f64) != null);
    try std.testing.expect(selectLeafBinary(.add, .leaf_symbol, .leaf_i64) == null);
    try std.testing.expect(selectLeafBinary(.sub, .leaf_char1, .leaf_char4) != null);
}

test "numeric scalar semantics include exact mixed comparison and chars" {
    const large: i64 = (1 << 53) + 1;
    try std.testing.expectEqual(
        @as(i64, 0),
        (try scalarBinary(.eq, .{ .int = large }, .{ .float = @floatFromInt(large - 1) })).int,
    );
    try std.testing.expectEqual(
        @as(u32, 'b'),
        (try scalarBinary(.add, .{ .char = 'a' }, .{ .int = 1 })).char,
    );
    try std.testing.expectError(error.Domain, scalarBinary(.div, .{ .int = 1 }, .{ .int = 0 }));
}

test "numeric in-place preflight leaves a unique faulting leaf untouched" {
    const allocator = std.testing.allocator;
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    var archive = @import("spans.zig").SpanArchive.init(allocator);
    defer archive.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    var unit = @import("machine.zig").Unit.init(
        allocator,
        .empty,
        &environment,
        &archive,
        null,
        .{ .int = 0 },
        &cancelled,
    );
    defer unit.deinit();
    var evaluator = Machine{ .unit = &unit, .current = null };
    const input = try list.fromI64Slice(allocator, &.{ 1, 2 });
    defer heap.releaseValue(allocator, input);

    try std.testing.expectError(error.Ecl, tryInPlaceBinary(
        .{ .evaluator = &evaluator },
        .add,
        .{ .int = std.math.maxInt(i64) - 1 },
        input,
    ));
    try std.testing.expectEqual(@as(i64, 1), list.atUnchecked(input, 0).int);
    try std.testing.expectEqual(@as(i64, 2), list.atUnchecked(input, 1).int);
}

test "numeric in-place reuse deterministically prefers the left leaf" {
    const allocator = std.testing.allocator;
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    var archive = @import("spans.zig").SpanArchive.init(allocator);
    defer archive.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    var unit = @import("machine.zig").Unit.init(
        allocator,
        .empty,
        &environment,
        &archive,
        null,
        .{ .int = 0 },
        &cancelled,
    );
    defer unit.deinit();
    var evaluator = Machine{ .unit = &unit, .current = null };
    const left = try list.fromI64Slice(allocator, &.{ 1, 2 });
    defer heap.releaseValue(allocator, left);
    const right = try list.fromI64Slice(allocator, &.{ 10, 20 });
    defer heap.releaseValue(allocator, right);

    const reused = (try tryInPlaceBinary(.{ .evaluator = &evaluator }, .add, left, right)).?;
    try std.testing.expectEqual(ReuseSource.left, reused.source);
    try std.testing.expectEqual(left.list, reused.value.list);
    try std.testing.expectEqual(@as(i64, 11), list.atUnchecked(left, 0).int);
    try std.testing.expectEqual(@as(i64, 22), list.atUnchecked(left, 1).int);
    try std.testing.expectEqual(@as(i64, 10), list.atUnchecked(right, 0).int);
}
