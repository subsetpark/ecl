//! Stable grade/sort and structural-hash distinct/group kernels.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
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
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);
    const driver = try evaluator.allocator().create(CompareDriver);
    driver.* = .{ .left = left, .right = right, .cursor = .init(left, right) };
    left_owned = false;
    right_owned = false;
    evaluator.installWorkDriver(driver, CompareDriver.advance, CompareDriver.destroy);
}

fn gradePrimitive(evaluator: *Machine) MachineError!void {
    return startGrade(evaluator, false);
}

fn startGrade(evaluator: *Machine, sorted_values: bool) MachineError!void {
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a comparable list");
    const count: usize = @intCast(collection.list.length());
    const indices = try evaluator.allocator().alloc(usize, count);
    errdefer evaluator.allocator().free(indices);
    const scratch = try evaluator.allocator().alloc(usize, count);
    errdefer evaluator.allocator().free(scratch);
    const driver = try evaluator.allocator().create(GradeDriver);
    driver.* = .{
        .collection = collection,
        .sorted_values = sorted_values,
        .indices = indices,
        .scratch = scratch,
    };
    collection_owned = false;
    evaluator.installWorkDriver(driver, GradeDriver.advance, GradeDriver.destroy);
}

pub fn gradePrimitiveForIdiom() env.PrimitiveImpl {
    return gradePrimitive;
}

pub fn sortForIdiom(evaluator: *Machine) MachineError!void {
    try startGrade(evaluator, true);
}

const CompareProgress = union(enum) { pending, complete: std.math.Order, not_comparable };
const CompareCursor = struct {
    left: Value,
    right: Value,
    index: usize = 0,

    fn init(left: Value, right: Value) CompareCursor {
        return .{ .left = left, .right = right };
    }

    fn advance(self: *CompareCursor, budget: usize) CompareProgress {
        if (self.left.isString() and self.right.isString()) {
            const left_count: usize = @intCast(self.left.list.length());
            const right_count: usize = @intCast(self.right.list.length());
            const shared = @min(left_count, right_count);
            const end = @min(self.index + budget, shared);
            while (self.index != end) : (self.index += 1) {
                const left_char = list.atUnchecked(self.left, self.index).char;
                const right_char = list.atUnchecked(self.right, self.index).char;
                if (left_char < right_char) return .{ .complete = .lt };
                if (left_char > right_char) return .{ .complete = .gt };
            }
            if (self.index != shared) return .pending;
            return .{ .complete = if (left_count < right_count)
                .lt
            else if (left_count > right_count)
                .gt
            else
                .eq };
        }
        if (self.left.isString() or self.right.isString()) return .not_comparable;
        return .{ .complete = equal.compareScalars(self.left, self.right) catch
            return .not_comparable };
    }
};

const CompareDriver = struct {
    left: Value,
    right: Value,
    cursor: CompareCursor,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *CompareDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (self.cursor.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .not_comparable => evaluator.typeError("two comparable numbers, chars, or strings"),
            .complete => |ordering| completed: {
                try evaluator.pushOwned(.{ .int = switch (ordering) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                } });
                break :completed .completed;
            },
        };
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *CompareDriver = @ptrCast(@alignCast(raw));
        heap.releaseValue(allocator, self.left);
        heap.releaseValue(allocator, self.right);
        allocator.destroy(self);
    }
};

const GradeDriver = struct {
    collection: Value,
    sorted_values: bool,
    indices: []usize,
    scratch: []usize,
    phase: enum { validate, initialize, merge, copy, prepare, materialize } = .validate,
    index: usize = 0,
    comparator: ?CompareCursor = null,
    width: usize = 1,
    start: usize = 0,
    middle: usize = 0,
    end: usize = 0,
    left: usize = 0,
    right: usize = 0,
    output: usize = 0,
    run_ready: bool = false,
    source_scratch: bool = false,
    integers: ?[]i64 = null,
    values: ?[]Value = null,
    i64_materializer: ?storage.I64Materializer = null,
    value_materializer: ?storage.ValueMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *GradeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .validate => {
                if (self.indices.len == 0 or self.index == self.indices.len) {
                    self.phase = .initialize;
                    self.index = 0;
                    continue;
                }
                if (self.comparator == null) self.comparator = .init(
                    list.atUnchecked(self.collection, 0),
                    list.atUnchecked(self.collection, self.index),
                );
                switch (self.comparator.?.advance(1)) {
                    .pending => return .yielded,
                    .not_comparable => return evaluator.failAtIndex(
                        .type,
                        "grade expected mutually comparable numbers, chars, or strings",
                        self.index,
                    ),
                    .complete => {
                        self.comparator = null;
                        self.index += 1;
                        budget -= 1;
                    },
                }
            },
            .initialize => {
                const end = @min(self.index + budget, self.indices.len);
                const initialized = end - self.index;
                while (self.index != end) : (self.index += 1) self.indices[self.index] = self.index;
                budget -= initialized;
                if (self.index == self.indices.len) {
                    self.phase = .merge;
                    self.index = 0;
                }
            },
            .merge => {
                if (self.width >= self.indices.len) {
                    self.phase = if (self.source_scratch) .copy else .prepare;
                    self.index = 0;
                    continue;
                }
                if (!self.run_ready) {
                    if (self.start == self.indices.len) {
                        self.source_scratch = !self.source_scratch;
                        self.start = 0;
                        self.width = if (self.width > self.indices.len / 2)
                            self.indices.len
                        else
                            self.width * 2;
                        continue;
                    }
                    self.middle = self.start + @min(self.width, self.indices.len - self.start);
                    self.end = self.middle + @min(self.width, self.indices.len - self.middle);
                    self.left = self.start;
                    self.right = self.middle;
                    self.output = self.start;
                    self.run_ready = true;
                }
                if (self.output == self.end) {
                    self.start = self.end;
                    self.run_ready = false;
                    continue;
                }
                const source = if (self.source_scratch) self.scratch else self.indices;
                var choose_left = self.right == self.end;
                if (!choose_left and self.left != self.middle) {
                    if (self.comparator == null) self.comparator = .init(
                        list.atUnchecked(self.collection, source[self.left]),
                        list.atUnchecked(self.collection, source[self.right]),
                    );
                    switch (self.comparator.?.advance(1)) {
                        .pending => return .yielded,
                        .not_comparable => unreachable,
                        .complete => |ordering| {
                            self.comparator = null;
                            choose_left = ordering == .lt or
                                (ordering == .eq and source[self.left] < source[self.right]);
                        },
                    }
                }
                const destination = if (self.source_scratch) self.indices else self.scratch;
                destination[self.output] = if (choose_left) source[self.left] else source[self.right];
                if (choose_left) self.left += 1 else self.right += 1;
                self.output += 1;
                budget -= 1;
            },
            .copy => {
                const end = @min(self.index + budget, self.indices.len);
                @memcpy(self.indices[self.index..end], self.scratch[self.index..end]);
                const copied = end - self.index;
                self.index = end;
                budget -= copied;
                if (self.index == self.indices.len) {
                    self.phase = .prepare;
                    self.index = 0;
                }
            },
            .prepare => {
                if (self.sorted_values) {
                    if (self.values == null) self.values = try evaluator.allocator().alloc(Value, self.indices.len);
                    const end = @min(self.index + budget, self.indices.len);
                    const prepared = end - self.index;
                    while (self.index != end) : (self.index += 1)
                        self.values.?[self.index] = list.atUnchecked(self.collection, self.indices[self.index]);
                    budget -= prepared;
                    if (self.index == self.indices.len) {
                        self.value_materializer = .init(evaluator.allocator(), self.values.?);
                        self.phase = .materialize;
                    }
                } else {
                    if (self.integers == null) self.integers = try evaluator.allocator().alloc(i64, self.indices.len);
                    const end = @min(self.index + budget, self.indices.len);
                    const prepared = end - self.index;
                    while (self.index != end) : (self.index += 1)
                        self.integers.?[self.index] = @intCast(self.indices[self.index]);
                    budget -= prepared;
                    if (self.index == self.indices.len) {
                        self.i64_materializer = .init(evaluator.allocator(), self.integers.?);
                        self.phase = .materialize;
                    }
                }
            },
            .materialize => {
                const progress: union(enum) { pending, complete: Value } = if (self.sorted_values)
                    switch (try self.value_materializer.?.advance(budget)) {
                        .pending => .pending,
                        .complete => |result| .{ .complete = result },
                    }
                else switch (try self.i64_materializer.?.advance(budget)) {
                    .pending => .pending,
                    .complete => |result| .{ .complete = result },
                };
                return switch (progress) {
                    .pending => .yielded,
                    .complete => |result| completed: {
                        errdefer heap.releaseValue(evaluator.allocator(), result);
                        try evaluator.pushOwned(result);
                        break :completed .completed;
                    },
                };
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *GradeDriver = @ptrCast(@alignCast(raw));
        if (self.i64_materializer) |*materializer| materializer.deinit();
        if (self.value_materializer) |*materializer| materializer.deinit();
        if (self.integers) |integers| allocator.free(integers);
        if (self.values) |values| allocator.free(values);
        allocator.free(self.indices);
        allocator.free(self.scratch);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

fn lessIndex(collection: Value, left: usize, right: usize) error{NotComparable}!bool {
    const ordering = try equal.compareScalars(
        list.atUnchecked(collection, left),
        list.atUnchecked(collection, right),
    );
    return ordering == .lt or (ordering == .eq and left < right);
}

fn distinctPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    const results = try evaluator.allocator().alloc(Value, count);
    errdefer evaluator.allocator().free(results);
    const driver = try evaluator.allocator().create(DistinctDriver);
    driver.* = .{ .collection = collection, .results = results };
    collection_owned = false;
    evaluator.installWorkDriver(driver, DistinctDriver.advance, DistinctDriver.destroy);
}

const DistinctDriver = struct {
    collection: Value,
    results: []Value,
    result_count: usize = 0,
    item_index: usize = 0,
    candidate: usize = 0,
    matcher: ?equal.MatchCursor = null,
    materializer: ?storage.ValueMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *DistinctDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) {
            if (self.materializer) |*materializer| {
                return switch (try materializer.advance(budget)) {
                    .pending => .yielded,
                    .complete => |result| completed: {
                        materializer.deinit();
                        self.materializer = null;
                        errdefer heap.releaseValue(evaluator.allocator(), result);
                        try evaluator.pushOwned(result);
                        break :completed .completed;
                    },
                };
            }
            if (self.item_index == self.results.len) {
                self.materializer = .init(
                    evaluator.allocator(),
                    self.results[0..self.result_count],
                );
                continue;
            }
            if (self.candidate == self.result_count) {
                self.results[self.result_count] = list.atUnchecked(self.collection, self.item_index);
                self.result_count += 1;
                self.item_index += 1;
                self.candidate = 0;
                budget -= 1;
                continue;
            }
            if (self.matcher == null) self.matcher = try .init(
                evaluator.allocator(),
                self.results[self.candidate],
                list.atUnchecked(self.collection, self.item_index),
            );
            switch (try self.matcher.?.advance(1)) {
                .pending => budget -= 1,
                .complete => |matches| {
                    self.matcher.?.deinit();
                    self.matcher = null;
                    if (matches) {
                        self.item_index += 1;
                        self.candidate = 0;
                    } else self.candidate += 1;
                    budget -= 1;
                },
            }
        }
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *DistinctDriver = @ptrCast(@alignCast(raw));
        if (self.matcher) |*matcher| matcher.deinit();
        if (self.materializer) |*materializer| materializer.deinit();
        allocator.free(self.results);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

fn groupPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const driver = try evaluator.allocator().create(GroupDriver);
    driver.* = .{ .collection = collection };
    collection_owned = false;
    evaluator.installWorkDriver(driver, GroupDriver.advance, GroupDriver.destroy);
}

const GroupDriver = struct {
    collection: Value,
    keys: ?[]Value = null,
    assignments: ?[]usize = null,
    frequencies: ?[]usize = null,
    offsets: ?[]usize = null,
    cursors: ?[]usize = null,
    indices: ?[]i64 = null,
    pairs: ?[]dict.Pair = null,
    phase: enum { allocate, scan, offsets, cursors, scatter, groups, dictionary, release } = .allocate,
    item_index: usize = 0,
    key_count: usize = 0,
    candidate: usize = 0,
    index: usize = 0,
    matcher: ?equal.MatchCursor = null,
    group_materializer: ?storage.I64Materializer = null,
    dict_materializer: ?storage.DictMaterializer = null,
    initialized_pairs: usize = 0,
    released_pairs: usize = 0,
    result: ?Value = null,

    fn allocate(self: *GroupDriver, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const count: usize = @intCast(self.collection.list.length());
        self.keys = try allocator.alloc(Value, count);
        self.assignments = try allocator.alloc(usize, count);
        self.frequencies = try allocator.alloc(usize, count);
        self.offsets = try allocator.alloc(usize, count + 1);
        self.cursors = try allocator.alloc(usize, count);
        self.indices = try allocator.alloc(i64, count);
        self.pairs = try allocator.alloc(dict.Pair, count);
        self.offsets.?[0] = 0;
        self.phase = .scan;
    }

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *GroupDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .allocate => try self.allocate(evaluator.allocator()),
            .scan => {
                const count: usize = @intCast(self.collection.list.length());
                if (self.item_index == count) {
                    self.phase = .offsets;
                    self.index = 0;
                    continue;
                }
                if (self.candidate == self.key_count) {
                    self.keys.?[self.key_count] = list.atUnchecked(self.collection, self.item_index);
                    self.frequencies.?[self.key_count] = 0;
                    self.key_count += 1;
                    self.assignments.?[self.item_index] = self.key_count - 1;
                    self.frequencies.?[self.key_count - 1] += 1;
                    self.item_index += 1;
                    self.candidate = 0;
                    budget -= 1;
                    continue;
                }
                if (self.matcher == null) self.matcher = try .init(
                    evaluator.allocator(),
                    self.keys.?[self.candidate],
                    list.atUnchecked(self.collection, self.item_index),
                );
                switch (try self.matcher.?.advance(1)) {
                    .pending => budget -= 1,
                    .complete => |matches| {
                        self.matcher.?.deinit();
                        self.matcher = null;
                        if (matches) {
                            self.assignments.?[self.item_index] = self.candidate;
                            self.frequencies.?[self.candidate] += 1;
                            self.item_index += 1;
                            self.candidate = 0;
                        } else self.candidate += 1;
                        budget -= 1;
                    },
                }
            },
            .offsets => {
                if (self.index == self.key_count) {
                    self.phase = .cursors;
                    self.index = 0;
                    continue;
                }
                self.offsets.?[self.index + 1] = self.offsets.?[self.index] + self.frequencies.?[self.index];
                self.index += 1;
                budget -= 1;
            },
            .cursors => {
                if (self.index == self.key_count) {
                    self.phase = .scatter;
                    self.index = 0;
                    continue;
                }
                self.cursors.?[self.index] = self.offsets.?[self.index];
                self.index += 1;
                budget -= 1;
            },
            .scatter => {
                if (self.index == self.assignments.?.len) {
                    self.phase = .groups;
                    self.index = 0;
                    continue;
                }
                const group_index = self.assignments.?[self.index];
                self.indices.?[self.cursors.?[group_index]] = @intCast(self.index);
                self.cursors.?[group_index] += 1;
                self.index += 1;
                budget -= 1;
            },
            .groups => {
                if (self.index == self.key_count) {
                    self.dict_materializer = try .init(
                        evaluator.allocator(),
                        self.pairs.?[0..self.key_count],
                        false,
                    );
                    self.phase = .dictionary;
                    continue;
                }
                if (self.group_materializer == null) self.group_materializer = .init(
                    evaluator.allocator(),
                    self.indices.?[self.offsets.?[self.index]..self.offsets.?[self.index + 1]],
                );
                switch (try self.group_materializer.?.advance(budget)) {
                    .pending => return .yielded,
                    .complete => |group| {
                        self.group_materializer.?.deinit();
                        self.group_materializer = null;
                        self.pairs.?[self.index] = .{ self.keys.?[self.index], group };
                        self.initialized_pairs += 1;
                        self.index += 1;
                        return .yielded;
                    },
                }
            },
            .dictionary => switch (try self.dict_materializer.?.advance(budget)) {
                .pending => return .yielded,
                .duplicate_key => unreachable,
                .complete => |result| {
                    self.dict_materializer.?.deinit();
                    self.dict_materializer = null;
                    self.result = result;
                    self.phase = .release;
                    self.index = 0;
                },
            },
            .release => {
                if (self.released_pairs == self.initialized_pairs) {
                    const result = self.result.?;
                    self.result = null;
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    return .completed;
                }
                heap.releaseValue(evaluator.allocator(), self.pairs.?[self.released_pairs][1]);
                self.released_pairs += 1;
                budget -= 1;
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *GroupDriver = @ptrCast(@alignCast(raw));
        if (self.matcher) |*matcher| matcher.deinit();
        if (self.group_materializer) |*materializer| materializer.deinit();
        if (self.dict_materializer) |*materializer| materializer.deinit();
        if (self.result) |result| heap.releaseValue(allocator, result);
        if (self.pairs) |pairs| {
            for (pairs[self.released_pairs..self.initialized_pairs]) |pair|
                heap.releaseValue(allocator, pair[1]);
            allocator.free(pairs);
        }
        if (self.keys) |items| allocator.free(items);
        if (self.assignments) |items| allocator.free(items);
        if (self.frequencies) |items| allocator.free(items);
        if (self.offsets) |items| allocator.free(items);
        if (self.cursors) |items| allocator.free(items);
        if (self.indices) |items| allocator.free(items);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

test "order comparator breaks equal values by original position" {
    const allocator = std.testing.allocator;
    const collection = try list.fromI64Slice(allocator, &.{ 2, 1, 2, 1 });
    defer heap.releaseValue(allocator, collection);
    try std.testing.expect(try lessIndex(collection, 1, 3));
    try std.testing.expect(!try lessIndex(collection, 3, 1));
}
