//! Stable grade/sort and structural-hash distinct/group kernels.
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
const Machine = support.Machine;
const MachineError = support.MachineError;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try support.installPrimitive(core, "cmp", cmpPrimitive);
    try support.installPrimitive(core, "grade", gradePrimitive);
    try support.installPrimitive(core, "distinct", distinctPrimitive);
    try support.installPrimitive(core, "group", groupPrimitive);
}

fn cmpPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    const ordering = compareValues(evaluator, left, right) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.NotComparable => return evaluator.typeError("two comparable numbers, chars, or strings"),
    };
    try evaluator.pushOwned(.{ .int = switch (ordering) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } });
}

fn gradePrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a comparable list");
    const count: usize = @intCast(collection.list.length());
    try validateComparable(evaluator, collection);
    const indices = try evaluator.allocator().alloc(usize, count);
    defer evaluator.allocator().free(indices);
    for (indices, 0..) |*index, position| {
        try evaluator.advanceKernel(1);
        index.* = position;
    }
    switch (try chooseGradePathForRuntime(evaluator, collection)) {
        .comparison => try comparisonGrade(evaluator, collection, indices),
        .bucket => try bucketGrade(evaluator, collection, indices),
        .radix => try radixGrade(evaluator, collection, indices),
    }
    const result = try evaluator.allocator().alloc(i64, count);
    defer evaluator.allocator().free(result);
    for (indices, 0..) |index, position| {
        try evaluator.advanceKernel(1);
        result[position] = @intCast(index);
    }
    try evaluator.pushOwned(try storage.fromI64Slice(
        evaluator.allocator(),
        result,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

pub fn gradePrimitiveForIdiom() env.PrimitiveImpl {
    return gradePrimitive;
}

pub fn sortForIdiom(evaluator: *Machine) MachineError!void {
    try evaluator.require(1);
    try evaluator.pushBorrowed(evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1]);
    try gradePrimitive(evaluator);
    try @import("kernel_sequence.zig").atForIdiom(evaluator);
}

pub const GradePath = enum { comparison, bucket, radix };
const comparison_cutoff: usize = 32;

fn chooseGradePath(collection: Value) GradePath {
    const count: usize = @intCast(collection.list.length());
    if (count <= comparison_cutoff) return .comparison;
    return switch (collection.list.kind()) {
        .leaf_i64, .leaf_char1, .leaf_char2, .leaf_char4 => if (smallRange(collection))
            .bucket
        else
            .radix,
        .leaf_f64 => .radix,
        .generic_spine, .leaf_symbol, .dict, .reserved_mask => .comparison,
    };
}

pub fn gradePathForTest(collection: Value) GradePath {
    return chooseGradePath(collection);
}

fn chooseGradePathForRuntime(evaluator: *Machine, collection: Value) MachineError!GradePath {
    const count: usize = @intCast(collection.list.length());
    if (count <= comparison_cutoff) return .comparison;
    return switch (collection.list.kind()) {
        .leaf_i64, .leaf_char1, .leaf_char2, .leaf_char4 => if (try smallRangePolling(
            evaluator,
            collection,
        ))
            .bucket
        else
            .radix,
        .leaf_f64 => .radix,
        .generic_spine, .leaf_symbol, .dict, .reserved_mask => .comparison,
    };
}

fn comparisonGrade(evaluator: *Machine, collection: Value, indices: []usize) MachineError!void {
    if (indices.len < 2) return;
    const scratch = try evaluator.allocator().alloc(usize, indices.len);
    defer evaluator.allocator().free(scratch);
    var source = indices;
    var destination = scratch;
    var source_is_result = true;
    var width: usize = 1;
    while (width < indices.len) {
        var start: usize = 0;
        while (start < indices.len) {
            const middle = start + @min(width, indices.len - start);
            const end = middle + @min(width, indices.len - middle);
            var left = start;
            var right = middle;
            var output = start;
            while (left < middle or right < end) : (output += 1) {
                try evaluator.advanceKernel(1);
                var choose_left = right == end;
                if (!choose_left and left < middle) {
                    const ordering = compareValues(
                        evaluator,
                        list.atUnchecked(collection, source[left]),
                        list.atUnchecked(collection, source[right]),
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Ecl => return error.Ecl,
                        error.NotComparable => unreachable,
                    };
                    choose_left = ordering == .lt or
                        (ordering == .eq and source[left] < source[right]);
                }
                if (choose_left) {
                    destination[output] = source[left];
                    left += 1;
                } else {
                    destination[output] = source[right];
                    right += 1;
                }
            }
            start = end;
        }
        const old_source = source;
        source = destination;
        destination = old_source;
        source_is_result = !source_is_result;
        width = if (width > indices.len / 2) indices.len else width * 2;
    }
    if (!source_is_result) try copyIndices(evaluator, indices, source);
}

fn smallRange(collection: Value) bool {
    const count: usize = @intCast(collection.list.length());
    if (count == 0) return false;
    var minimum = integralKey(collection, 0);
    var maximum = minimum;
    for (1..count) |index| {
        const key = integralKey(collection, index);
        minimum = @min(minimum, key);
        maximum = @max(maximum, key);
    }
    const span: u128 = @intCast(maximum - minimum);
    const adaptive = @max(@as(u128, 256), @as(u128, count) * 4);
    return span + 1 <= adaptive and span < 1_000_000;
}

fn smallRangePolling(evaluator: *Machine, collection: Value) MachineError!bool {
    const count: usize = @intCast(collection.list.length());
    if (count == 0) return false;
    try evaluator.advanceKernel(1);
    var minimum = integralKey(collection, 0);
    var maximum = minimum;
    for (1..count) |index| {
        try evaluator.advanceKernel(1);
        const key = integralKey(collection, index);
        minimum = @min(minimum, key);
        maximum = @max(maximum, key);
    }
    const span: u128 = @intCast(maximum - minimum);
    const adaptive = @max(@as(u128, 256), @as(u128, count) * 4);
    return span + 1 <= adaptive and span < 1_000_000;
}

fn bucketGrade(evaluator: *Machine, collection: Value, indices: []usize) MachineError!void {
    if (indices.len == 0) return;
    try evaluator.advanceKernel(1);
    var minimum = integralKey(collection, 0);
    var maximum = minimum;
    for (1..indices.len) |index| {
        try evaluator.advanceKernel(1);
        const key = integralKey(collection, index);
        minimum = @min(minimum, key);
        maximum = @max(maximum, key);
    }
    const bucket_count: usize = @intCast(maximum - minimum + 1);
    const counts = try evaluator.allocator().alloc(usize, bucket_count);
    defer evaluator.allocator().free(counts);
    for (counts) |*count| {
        try evaluator.advanceKernel(1);
        count.* = 0;
    }
    for (0..indices.len) |index| {
        try evaluator.advanceKernel(1);
        const bucket: usize = @intCast(integralKey(collection, index) - minimum);
        counts[bucket] += 1;
    }
    var total: usize = 0;
    for (counts) |*count| {
        try evaluator.advanceKernel(1);
        const frequency = count.*;
        count.* = total;
        total += frequency;
    }
    const output = try evaluator.allocator().alloc(usize, indices.len);
    defer evaluator.allocator().free(output);
    for (0..indices.len) |index| {
        try evaluator.advanceKernel(1);
        const bucket: usize = @intCast(integralKey(collection, index) - minimum);
        output[counts[bucket]] = index;
        counts[bucket] += 1;
    }
    try copyIndices(evaluator, indices, output);
}

fn radixGrade(evaluator: *Machine, collection: Value, indices: []usize) MachineError!void {
    if (indices.len < 2) return;
    const scratch = try evaluator.allocator().alloc(usize, indices.len);
    defer evaluator.allocator().free(scratch);
    var source = indices;
    var destination = scratch;
    var swapped = false;
    for (0..8) |byte_index| {
        var counts = [_]usize{0} ** 256;
        var only_bucket: ?u8 = null;
        var varied = false;
        for (source) |index| {
            try evaluator.advanceKernel(1);
            const bucket: u8 = @truncate(sortableKey(collection, index) >> @intCast(byte_index * 8));
            counts[bucket] += 1;
            if (only_bucket) |known| {
                varied = varied or known != bucket;
            } else {
                only_bucket = bucket;
            }
        }
        if (!varied) continue;
        var total: usize = 0;
        for (&counts) |*count| {
            try evaluator.advanceKernel(1);
            const frequency = count.*;
            count.* = total;
            total += frequency;
        }
        for (source) |index| {
            try evaluator.advanceKernel(1);
            const bucket: u8 = @truncate(sortableKey(collection, index) >> @intCast(byte_index * 8));
            destination[counts[bucket]] = index;
            counts[bucket] += 1;
        }
        const old_source = source;
        source = destination;
        destination = old_source;
        swapped = !swapped;
    }
    if (swapped) try copyIndices(evaluator, indices, source);
}

fn copyIndices(evaluator: *Machine, destination: []usize, source: []const usize) MachineError!void {
    std.debug.assert(destination.len == source.len);
    for (source, destination) |index, *output| {
        try evaluator.advanceKernel(1);
        output.* = index;
    }
}

fn integralKey(collection: Value, index: usize) i128 {
    const item = list.atUnchecked(collection, index);
    return switch (item) {
        .int => |integer| integer,
        .char => |codepoint| codepoint,
        .float, .symbol, .word, .list, .dict => unreachable,
    };
}

fn sortableKey(collection: Value, index: usize) u64 {
    const item = list.atUnchecked(collection, index);
    return switch (item) {
        .int => |integer| @as(u64, @bitCast(integer)) ^ (@as(u64, 1) << 63),
        .char => |codepoint| codepoint,
        .float => |number| blk: {
            const normalized = if (number == 0.0) 0.0 else number;
            const bits: u64 = @bitCast(normalized);
            break :blk if (bits & (@as(u64, 1) << 63) != 0)
                ~bits
            else
                bits ^ (@as(u64, 1) << 63);
        },
        .symbol, .word, .list, .dict => unreachable,
    };
}

fn validateComparable(evaluator: *Machine, collection: Value) MachineError!void {
    const count: usize = @intCast(collection.list.length());
    if (count == 0) return;
    const first = list.atUnchecked(collection, 0);
    try evaluator.advanceKernel(1);
    _ = compareValues(evaluator, first, first) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.NotComparable => return evaluator.failAtIndex(
            .type,
            "grade expected mutually comparable numbers, chars, or strings",
            0,
        ),
    };
    for (1..count) |index| {
        try evaluator.advanceKernel(1);
        _ = compareValues(evaluator, first, list.atUnchecked(collection, index)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return error.Ecl,
            error.NotComparable => return evaluator.failAtIndex(
                .type,
                "grade expected mutually comparable numbers, chars, or strings",
                index,
            ),
        };
    }
}

const CompareError = error{ OutOfMemory, Ecl, NotComparable };

fn compareValues(evaluator: *Machine, left: Value, right: Value) CompareError!std.math.Order {
    if (left.isString() and right.isString()) {
        const left_count: usize = @intCast(left.list.length());
        const right_count: usize = @intCast(right.list.length());
        const shared = @min(left_count, right_count);
        for (0..shared) |index| {
            try evaluator.advanceKernel(1);
            const left_char = list.atUnchecked(left, index).char;
            const right_char = list.atUnchecked(right, index).char;
            if (left_char < right_char) return .lt;
            if (left_char > right_char) return .gt;
        }
        return if (left_count < right_count)
            .lt
        else if (left_count > right_count)
            .gt
        else
            .eq;
    }
    if (left.isString() or right.isString()) return error.NotComparable;
    return equal.compareScalars(left, right) catch error.NotComparable;
}

fn lessIndex(collection: Value, left: usize, right: usize) error{NotComparable}!bool {
    const ordering = try equal.compareScalars(
        list.atUnchecked(collection, left),
        list.atUnchecked(collection, right),
    );
    return ordering == .lt or (ordering == .eq and left < right);
}

const no_index = std.math.maxInt(usize);
const HashSlot = struct { hash: u64 = 0, head: usize = no_index };
const FixedHashTable = struct {
    slots: []HashSlot,

    fn init(evaluator: *Machine, max_entries: usize) MachineError!FixedHashTable {
        const minimum = std.math.mul(usize, max_entries, 2) catch return error.OutOfMemory;
        var capacity: usize = 1;
        while (capacity < minimum) {
            capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
        }
        const slots = try evaluator.allocator().alloc(HashSlot, capacity);
        errdefer evaluator.allocator().free(slots);
        for (slots) |*slot| {
            try evaluator.advanceKernel(1);
            slot.* = .{};
        }
        return .{ .slots = slots };
    }

    fn deinit(self: FixedHashTable, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }

    fn slotFor(self: FixedHashTable, evaluator: *Machine, hash: u64) MachineError!*HashSlot {
        var index: usize = @intCast(hash & (self.slots.len - 1));
        for (0..self.slots.len) |_| {
            try evaluator.advanceKernel(1);
            const slot = &self.slots[index];
            if (slot.head == no_index or slot.hash == hash) return slot;
            index = (index + 1) & (self.slots.len - 1);
        }
        unreachable;
    }
};

fn distinctPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    const results = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(results);
    const next = try evaluator.allocator().alloc(usize, count);
    defer evaluator.allocator().free(next);
    const table = try FixedHashTable.init(evaluator, count);
    defer table.deinit(evaluator.allocator());
    var result_count: usize = 0;
    const poller = (support.Context{ .evaluator = evaluator }).structuralPoller();
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(collection, index);
        const hash = try equal.hashWithPolling(evaluator.allocator(), item, poller);
        const slot = try table.slotFor(evaluator, hash);
        var known = false;
        var candidate = slot.head;
        while (candidate != no_index) : (candidate = next[candidate]) {
            if (try equal.matchWithPolling(
                evaluator.allocator(),
                results[candidate],
                item,
                poller,
            )) {
                known = true;
                break;
            }
        }
        if (known) continue;
        results[result_count] = item;
        next[result_count] = slot.head;
        slot.hash = hash;
        slot.head = result_count;
        result_count += 1;
    }
    try evaluator.pushOwned(try storage.fromValues(
        evaluator.allocator(),
        results[0..result_count],
        poller,
    ));
}

fn groupPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    const keys = try evaluator.allocator().alloc(Value, count);
    defer evaluator.allocator().free(keys);
    const next = try evaluator.allocator().alloc(usize, count);
    defer evaluator.allocator().free(next);
    const assignments = try evaluator.allocator().alloc(usize, count);
    defer evaluator.allocator().free(assignments);
    const frequencies = try evaluator.allocator().alloc(usize, count);
    defer evaluator.allocator().free(frequencies);
    const table = try FixedHashTable.init(evaluator, count);
    defer table.deinit(evaluator.allocator());
    var key_count: usize = 0;
    const poller = (support.Context{ .evaluator = evaluator }).structuralPoller();
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(collection, index);
        const hash = try equal.hashWithPolling(evaluator.allocator(), item, poller);
        const slot = try table.slotFor(evaluator, hash);
        var group_index: ?usize = null;
        var candidate = slot.head;
        while (candidate != no_index) : (candidate = next[candidate]) {
            if (try equal.matchWithPolling(
                evaluator.allocator(),
                keys[candidate],
                item,
                poller,
            )) {
                group_index = candidate;
                break;
            }
        }
        if (group_index == null) {
            group_index = key_count;
            keys[key_count] = item;
            frequencies[key_count] = 0;
            next[key_count] = slot.head;
            slot.hash = hash;
            slot.head = key_count;
            key_count += 1;
        }
        assignments[index] = group_index.?;
        frequencies[group_index.?] += 1;
    }

    const offsets = try evaluator.allocator().alloc(usize, key_count + 1);
    defer evaluator.allocator().free(offsets);
    offsets[0] = 0;
    for (frequencies[0..key_count], 0..) |frequency, index| {
        try evaluator.advanceKernel(1);
        offsets[index + 1] = offsets[index] + frequency;
    }
    std.debug.assert(offsets[key_count] == count);
    const cursors = try evaluator.allocator().alloc(usize, key_count);
    defer evaluator.allocator().free(cursors);
    for (cursors, offsets[0..key_count]) |*cursor, offset| {
        try evaluator.advanceKernel(1);
        cursor.* = offset;
    }
    const indices = try evaluator.allocator().alloc(i64, count);
    defer evaluator.allocator().free(indices);
    for (assignments, 0..) |group_index, index| {
        try evaluator.advanceKernel(1);
        indices[cursors[group_index]] = @intCast(index);
        cursors[group_index] += 1;
    }

    const pairs = try evaluator.allocator().alloc(dict.Pair, key_count);
    defer evaluator.allocator().free(pairs);
    var initialized: usize = 0;
    defer for (pairs[0..initialized]) |pair| heap.releaseValue(evaluator.allocator(), pair[1]);
    for (keys[0..key_count], 0..) |key, index| {
        try evaluator.advanceKernel(1);
        pairs[index] = .{
            key,
            try storage.fromI64Slice(
                evaluator.allocator(),
                indices[offsets[index]..offsets[index + 1]],
                poller,
            ),
        };
        initialized += 1;
    }
    try evaluator.pushOwned(try storage.fromUniquePairs(
        evaluator.allocator(),
        pairs,
        poller,
    ));
}

test "order comparator breaks equal values by original position" {
    const allocator = std.testing.allocator;
    const collection = try list.fromI64Slice(allocator, &.{ 2, 1, 2, 1 });
    defer heap.releaseValue(allocator, collection);
    try std.testing.expect(try lessIndex(collection, 1, 3));
    try std.testing.expect(!try lessIndex(collection, 3, 1));
}
