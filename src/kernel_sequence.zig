//! Sequence, search, and rectangular-shape kernels.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");
const env = @import("env.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

const Op = enum {
    at,
    where,
    in_word,
    raze,
    cat,
    take,
    drop,
    reverse,
    first,
    rest,
    range,
    shape,
    len,
    flip,
    reshape,

    fn spelling(self: Op) []const u8 {
        return switch (self) {
            .at => "at",
            .where => "where",
            .in_word => "in",
            .raze => "raze",
            .cat => "cat",
            .take => "take",
            .drop => "drop",
            .reverse => "reverse",
            .first => "first",
            .rest => "rest",
            .range => "range",
            .shape => "shape",
            .len => "len",
            .flip => "flip",
            .reshape => "reshape",
        };
    }
};

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (std.meta.fields(Op)) |field| {
        const operation: Op = @enumFromInt(field.value);
        try support.installPrimitive(core, operation.spelling(), bind(operation));
    }
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return primitive(evaluator, operation);
        }
    }.run;
}

fn primitive(evaluator: *Machine, operation: Op) MachineError!void {
    return switch (operation) {
        .at => atPrimitive(evaluator),
        .where => wherePrimitive(evaluator),
        .in_word => inPrimitive(evaluator),
        .raze => razePrimitive(evaluator),
        .cat => catPrimitive(evaluator),
        .take => takePrimitive(evaluator),
        .drop => dropPrimitive(evaluator),
        .reverse => reversePrimitive(evaluator),
        .first => firstPrimitive(evaluator),
        .rest => restPrimitive(evaluator),
        .range => rangePrimitive(evaluator),
        .shape => shapePrimitive(evaluator),
        .len => lenPrimitive(evaluator),
        .flip => flipPrimitive(evaluator),
        .reshape => reshapePrimitive(evaluator),
    };
}

fn atPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const index = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), index);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    const result = try indexValue(.{ .evaluator = evaluator }, collection, index, 0);
    try evaluator.pushOwned(result);
}

pub fn atPrimitiveForIdiom() env.PrimitiveImpl {
    return bind(.at);
}

pub fn atForIdiom(evaluator: *Machine) MachineError!void {
    return atPrimitive(evaluator);
}

fn indexValue(
    context: support.Context,
    collection: Value,
    index: Value,
    depth: usize,
) MachineError!Value {
    if (depth >= support.max_depth and index == .list) {
        return context.evaluator.fail(.domain, "index nesting exceeds 256 levels");
    }
    if (collection == .dict) {
        const found = storage.get(
            context.allocator(),
            collection,
            index,
            context.structuralPoller(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return error.Ecl,
            error.NotADict => unreachable,
        } orelse return context.evaluator.fail(.domain, "at could not find the dict key");
        heap.retainValue(found);
        return found;
    }
    if (collection != .list) return context.evaluator.typeError("a list or dict");
    if (index == .list) {
        const count: usize = @intCast(index.list.length());
        const results = try context.allocator().alloc(Value, count);
        defer context.allocator().free(results);
        var initialized: usize = 0;
        defer releaseValues(context.allocator(), results[0..initialized]);
        for (0..count) |position| {
            try context.poll();
            results[position] = try indexValue(
                context,
                collection,
                list.atUnchecked(index, position),
                depth + 1,
            );
            initialized += 1;
        }
        return storage.fromValues(
            context.allocator(),
            results,
            context.structuralPoller(),
        );
    }
    if (index != .int) return context.evaluator.typeError("an integer index");
    if (index.int < 0) return context.evaluator.fail(.domain, "at index is negative");
    const position = std.math.cast(usize, index.int) orelse
        return context.evaluator.fail(.domain, "at index is out of bounds");
    const count: usize = @intCast(collection.list.length());
    if (position >= count) return context.evaluator.fail(.domain, "at index is out of bounds");
    const result = list.atUnchecked(collection, position);
    heap.retainValue(result);
    return result;
}

fn wherePrimitive(evaluator: *Machine) MachineError!void {
    const counts = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), counts);
    if (counts != .list) return evaluator.typeError("a non-negative integer count list");
    const count: usize = @intCast(counts.list.length());
    var total: usize = 0;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(counts, index);
        if (item != .int) {
            return evaluator.failAtIndex(.type, "where expected integer counts", index);
        }
        if (item.int < 0) {
            return evaluator.failAtIndex(.domain, "where counts must be non-negative", index);
        }
        const repetitions = std.math.cast(usize, item.int) orelse
            return evaluator.failAtIndex(.overflow, "where count exceeds addressable size", index);
        total = std.math.add(usize, total, repetitions) catch
            return evaluator.fail(.overflow, "where result is too large");
    }
    const indices = try evaluator.allocator().alloc(i64, total);
    defer evaluator.allocator().free(indices);
    var cursor: usize = 0;
    for (0..count) |index| {
        const repetitions: usize = @intCast(list.atUnchecked(counts, index).int);
        const result_index = std.math.cast(i64, index) orelse
            return evaluator.fail(.overflow, "where index exceeds integer range");
        for (0..repetitions) |_| {
            try evaluator.advanceKernel(1);
            indices[cursor] = result_index;
            cursor += 1;
        }
    }
    try evaluator.pushOwned(try storage.fromI64Slice(
        evaluator.allocator(),
        indices,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn inPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    const needle = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), needle);
    if (collection != .list) return evaluator.typeError("a list haystack");
    const result = try membership(.{ .evaluator = evaluator }, needle, collection, 0);
    try evaluator.pushOwned(result);
}

fn membership(
    context: support.Context,
    needle: Value,
    collection: Value,
    depth: usize,
) MachineError!Value {
    if (depth >= support.max_depth and needle == .list) {
        return context.evaluator.fail(.domain, "membership nesting exceeds 256 levels");
    }
    if (needle == .list) {
        const count: usize = @intCast(needle.list.length());
        const results = try context.allocator().alloc(Value, count);
        defer context.allocator().free(results);
        var initialized: usize = 0;
        defer releaseValues(context.allocator(), results[0..initialized]);
        for (0..count) |index| {
            try context.poll();
            results[index] = try membership(
                context,
                list.atUnchecked(needle, index),
                collection,
                depth + 1,
            );
            initialized += 1;
        }
        return storage.fromValues(context.allocator(), results, context.structuralPoller());
    }
    const count: usize = @intCast(collection.list.length());
    for (0..count) |index| {
        try context.poll();
        if (try equal.matchWithPolling(
            context.allocator(),
            needle,
            list.atUnchecked(collection, index),
            context.structuralPoller(),
        )) return .{ .int = 1 };
    }
    return .{ .int = 0 };
}

fn razePrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    var total: usize = 0;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(collection, index);
        const contribution: usize = if (item == .list) @intCast(item.list.length()) else 1;
        total = std.math.add(usize, total, contribution) catch
            return evaluator.fail(.overflow, "raze result is too large");
    }
    const values = try evaluator.allocator().alloc(Value, total);
    defer evaluator.allocator().free(values);
    var destination: usize = 0;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(collection, index);
        if (item != .list) {
            values[destination] = item;
            destination += 1;
            continue;
        }
        const child_count: usize = @intCast(item.list.length());
        for (0..child_count) |child_index| {
            try evaluator.advanceKernel(1);
            values[destination] = list.atUnchecked(item, child_index);
            destination += 1;
        }
    }
    std.debug.assert(destination == values.len);
    try evaluator.pushOwned(try storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn catPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    if (left != .list or right != .list) return evaluator.typeError("two lists");
    const left_count: usize = @intCast(left.list.length());
    const right_count: usize = @intCast(right.list.length());
    if (left_count == 0 and right_count == 0 and (left.isString() or right.isString())) {
        return evaluator.pushOwned(try emptyLike(
            evaluator.allocator(),
            if (left.isString()) left else right,
        ));
    }
    const values = try evaluator.allocator().alloc(Value, left_count + right_count);
    defer evaluator.allocator().free(values);
    for (0..left_count) |index| {
        try evaluator.advanceKernel(1);
        values[index] = list.atUnchecked(left, index);
    }
    for (0..right_count) |index| {
        try evaluator.advanceKernel(1);
        values[left_count + index] = list.atUnchecked(right, index);
    }
    try evaluator.pushOwned(try storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn firstPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    if (collection.list.length() == 0) return evaluator.fail(.domain, "first requires a non-empty list");
    try evaluator.pushBorrowed(list.atUnchecked(collection, 0));
}

fn restPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    if (count == 0) return evaluator.fail(.domain, "rest requires a non-empty list");
    try evaluator.pushOwned(try copyRange(evaluator, collection, 1, count, false));
}

fn takePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const count_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), count_value);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list or count_value != .int) {
        return evaluator.typeError("a list and an integer count");
    }
    const source_count: usize = @intCast(collection.list.length());
    const result_count = std.math.cast(usize, unsignedMagnitude(count_value.int)) orelse
        return evaluator.fail(.overflow, "take length exceeds addressable size");
    if (result_count == 0) {
        return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection));
    }
    if (result_count != 0 and source_count == 0) {
        return evaluator.fail(.domain, "take cannot cycle an empty list");
    }
    const values = try evaluator.allocator().alloc(Value, result_count);
    defer evaluator.allocator().free(values);
    const start = if (result_count == 0 or count_value.int >= 0)
        0
    else
        (source_count - (result_count % source_count)) % source_count;
    var source = start;
    for (0..result_count) |index| {
        try evaluator.advanceKernel(1);
        values[index] = list.atUnchecked(collection, source);
        source += 1;
        if (source == source_count) source = 0;
    }
    try evaluator.pushOwned(try storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn dropPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const count_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), count_value);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list or count_value != .int) {
        return evaluator.typeError("a list and an integer count");
    }
    const count: usize = @intCast(collection.list.length());
    const magnitude: usize = @intCast(@min(unsignedMagnitude(count_value.int), count));
    const bounds: struct { start: usize, end: usize } = if (count_value.int >= 0)
        .{ .start = magnitude, .end = count }
    else
        .{ .start = 0, .end = count - magnitude };
    try evaluator.pushOwned(try copyRange(
        evaluator,
        collection,
        bounds.start,
        bounds.end,
        false,
    ));
}

fn reversePrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    try evaluator.pushOwned(try copyRange(
        evaluator,
        collection,
        0,
        @intCast(collection.list.length()),
        true,
    ));
}

fn copyRange(
    evaluator: *Machine,
    collection: Value,
    start: usize,
    end: usize,
    reverse: bool,
) MachineError!Value {
    const count = end - start;
    if (count == 0) return emptyLike(evaluator.allocator(), collection);
    const values = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(values);
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const source = if (reverse) end - index - 1 else start + index;
        values[index] = list.atUnchecked(collection, source);
    }
    return storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    );
}

fn emptyLike(allocator: std.mem.Allocator, collection: Value) MachineError!Value {
    return list.emptyLike(allocator, collection) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotAList => unreachable,
    };
}

fn rangePrimitive(evaluator: *Machine) MachineError!void {
    const count_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), count_value);
    if (count_value != .int) return evaluator.typeError("a non-negative integer");
    if (count_value.int < 0) return evaluator.fail(.domain, "range requires a non-negative integer");
    const count = std.math.cast(usize, count_value.int) orelse
        return evaluator.fail(.overflow, "range length exceeds addressable size");
    const values = try evaluator.allocator().alloc(i64, count);
    defer evaluator.allocator().free(values);
    for (values, 0..) |*item, index| {
        try evaluator.advanceKernel(1);
        item.* = @intCast(index);
    }
    try evaluator.pushOwned(try storage.fromI64Slice(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn lenPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    try evaluator.pushOwned(.{ .int = @intCast(collection.list.length()) });
}

const ShapeError = error{ OutOfMemory, Ecl, Ragged, TooDeep };

fn shapePrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const dimensions = rectangularShape(.{ .evaluator = evaluator }, collection, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.Ragged => return evaluator.fail(.shape, "shape requires a rectangular list"),
        error.TooDeep => return evaluator.fail(.shape, "shape nesting exceeds 256 levels"),
    };
    defer evaluator.allocator().free(dimensions);
    const values = try evaluator.allocator().alloc(i64, dimensions.len);
    defer evaluator.allocator().free(values);
    for (dimensions, 0..) |dimension, index| {
        try evaluator.advanceKernel(1);
        values[index] = @intCast(dimension);
    }
    try evaluator.pushOwned(try storage.fromI64Slice(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn rectangularShape(
    context: support.Context,
    collection: Value,
    depth: usize,
) ShapeError![]usize {
    if (depth >= support.max_depth) return error.TooDeep;
    std.debug.assert(collection == .list);
    const count: usize = @intCast(collection.list.length());
    if (count == 0) {
        const result = try context.allocator().alloc(usize, 1);
        result[0] = 0;
        return result;
    }
    const first = list.atUnchecked(collection, 0);
    if (first != .list) {
        for (1..count) |index| {
            try context.poll();
            if (list.atUnchecked(collection, index) == .list) return error.Ragged;
        }
        const result = try context.allocator().alloc(usize, 1);
        result[0] = count;
        return result;
    }
    const child_shape = try rectangularShape(context, first, depth + 1);
    defer context.allocator().free(child_shape);
    for (1..count) |index| {
        try context.poll();
        const child = list.atUnchecked(collection, index);
        if (child != .list) return error.Ragged;
        const candidate = try rectangularShape(context, child, depth + 1);
        defer context.allocator().free(candidate);
        if (!std.mem.eql(usize, child_shape, candidate)) return error.Ragged;
    }
    const result = try context.allocator().alloc(usize, child_shape.len + 1);
    result[0] = count;
    for (child_shape, result[1..]) |dimension, *destination| {
        try context.poll();
        destination.* = dimension;
    }
    return result;
}

fn flipPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a rectangular list");
    const dimensions = rectangularShape(.{ .evaluator = evaluator }, collection, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.Ragged => return evaluator.fail(.shape, "flip requires a rectangular list"),
        error.TooDeep => return evaluator.fail(.shape, "flip nesting exceeds 256 levels"),
    };
    defer evaluator.allocator().free(dimensions);
    if (dimensions.len <= 1) return evaluator.pushBorrowed(collection);
    const rows = dimensions[0];
    const columns = dimensions[1];
    if (columns == 0 and rows != 0) {
        return evaluator.fail(
            .shape,
            "flip cannot retain trailing axes after a transposed zero dimension",
        );
    }
    const result_rows = try evaluator.allocator().alloc(Value, columns);
    defer evaluator.allocator().free(result_rows);
    var initialized: usize = 0;
    defer releaseValues(evaluator.allocator(), result_rows[0..initialized]);
    const cells = try evaluator.allocator().alloc(Value, rows);
    defer evaluator.allocator().free(cells);
    for (0..columns) |column| {
        for (0..rows) |row| {
            try evaluator.advanceKernel(1);
            const source_row = list.atUnchecked(collection, row);
            cells[row] = list.atUnchecked(source_row, column);
        }
        result_rows[column] = try storage.fromValues(
            evaluator.allocator(),
            cells,
            (support.Context{ .evaluator = evaluator }).structuralPoller(),
        );
        initialized += 1;
    }
    try evaluator.pushOwned(try storage.fromValues(
        evaluator.allocator(),
        result_rows,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn reshapePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const shape_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), shape_value);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list or shape_value != .list) {
        return evaluator.typeError("a list and a non-empty integer shape");
    }
    const rank: usize = @intCast(shape_value.list.length());
    if (rank == 0) return evaluator.fail(.shape, "reshape requires a non-empty shape");
    if (rank > support.max_depth) return evaluator.fail(.shape, "reshape rank exceeds 256");
    const dimensions = try evaluator.allocator().alloc(usize, rank);
    defer evaluator.allocator().free(dimensions);
    var volume: usize = 1;
    for (0..rank) |index| {
        try evaluator.advanceKernel(1);
        const dimension = list.atUnchecked(shape_value, index);
        if (dimension != .int) return evaluator.typeError("an integer shape");
        if (dimension.int < 0) return evaluator.failAtIndex(.shape, "reshape dimensions must be non-negative", index);
        dimensions[index] = std.math.cast(usize, dimension.int) orelse
            return evaluator.failAtIndex(.overflow, "reshape dimension exceeds addressable size", index);
        // Values are K-style nested lists rather than rank-bearing arrays.
        // Once an axis is empty there is no child value in which to retain
        // later axes, so accepting such a shape would make `shape reshape`
        // silently lie.  Zero is exact and representable only as the last
        // dimension (for example [2 0], but not [0 3]).
        if (dimensions[index] == 0 and index + 1 < rank) {
            return evaluator.failAtIndex(
                .shape,
                "reshape cannot retain axes after a zero dimension",
                index,
            );
        }
        volume = std.math.mul(usize, volume, dimensions[index]) catch
            return evaluator.fail(.overflow, "reshape volume overflows addressable size");
    }
    const flat_count = try ravelCount(evaluator, collection, 0);
    const flat = try evaluator.allocator().alloc(Value, flat_count);
    defer evaluator.allocator().free(flat);
    var flat_index: usize = 0;
    try ravelInto(evaluator, collection, flat, &flat_index, 0);
    std.debug.assert(flat_index == flat.len);
    if (volume > 0 and flat.len == 0) {
        return evaluator.fail(.domain, "reshape cannot fill a non-empty shape from empty data");
    }
    var cursor: usize = 0;
    const result = try buildReshape(evaluator, flat, dimensions, 0, &cursor);
    try evaluator.pushOwned(result);
}

fn ravelCount(
    evaluator: *Machine,
    item: Value,
    depth: usize,
) MachineError!usize {
    if (depth >= support.max_depth and item == .list) {
        return evaluator.fail(.shape, "reshape data nesting exceeds 256 levels");
    }
    if (item != .list) return 1;
    var total: usize = 0;
    const count: usize = @intCast(item.list.length());
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const child_count = try ravelCount(
            evaluator,
            list.atUnchecked(item, index),
            depth + 1,
        );
        total = std.math.add(usize, total, child_count) catch
            return evaluator.fail(.overflow, "reshape ravel is too large");
    }
    return total;
}

fn ravelInto(
    evaluator: *Machine,
    item: Value,
    output: []Value,
    destination: *usize,
    depth: usize,
) MachineError!void {
    if (depth >= support.max_depth and item == .list) unreachable;
    if (item != .list) {
        output[destination.*] = item;
        destination.* += 1;
        return;
    }
    const count: usize = @intCast(item.list.length());
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        try ravelInto(
            evaluator,
            list.atUnchecked(item, index),
            output,
            destination,
            depth + 1,
        );
    }
}

fn buildReshape(
    evaluator: *Machine,
    flat: []const Value,
    dimensions: []const usize,
    axis: usize,
    cursor: *usize,
) MachineError!Value {
    const count = dimensions[axis];
    const values = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(values);
    var initialized: usize = 0;
    defer if (axis + 1 < dimensions.len) {
        releaseValues(evaluator.allocator(), values[0..initialized]);
    };
    for (0..count) |index| {
        _ = index;
        try evaluator.advanceKernel(1);
        if (axis + 1 == dimensions.len) {
            values[initialized] = flat[cursor.* % flat.len];
            cursor.* += 1;
        } else {
            values[initialized] = try buildReshape(evaluator, flat, dimensions, axis + 1, cursor);
        }
        initialized += 1;
    }
    return storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    );
}

fn unsignedMagnitude(integer: i64) u64 {
    if (integer >= 0) return @intCast(integer);
    return @as(u64, @intCast(-(integer + 1))) + 1;
}

fn releaseValues(allocator: std.mem.Allocator, values: []const Value) void {
    for (values) |item| heap.releaseValue(allocator, item);
}

test "sequence unsigned magnitude includes minInt" {
    try std.testing.expectEqual(@as(u64, 1 << 63), unsignedMagnitude(std.math.minInt(i64)));
}
