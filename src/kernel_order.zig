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
const poll = @import("poll.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try support.installPrimitive(core, "cmp", cmpPrimitive);
    try support.installPrimitive(core, "grade", gradePrimitive);
    try support.installPrimitive(core, "group", groupPrimitive);
}

fn cmpPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const left_item = left.borrow();
    const right_item = right.borrow();
    try evaluator.startDriver(CompareDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .cursor = .init(left_item, right_item),
    });
}

fn gradePrimitive(evaluator: *Machine) MachineError!void {
    return startGrade(evaluator, false);
}

fn startGrade(evaluator: *Machine, sorted_values: bool) MachineError!void {
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (collection.borrow() != .list) return evaluator.typeError("a comparable list");
    const count: usize = @intCast(collection.borrow().list.length());
    const indices = try evaluator.allocator().alloc(usize, count);
    try evaluator.startDriver(GradeDriver{
        .collection = .init(collection.take()),
        .sorted_values = sorted_values,
        .indices = .init(indices),
    });
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

    pub fn advance(self: *CompareCursor, budget: usize) CompareProgress {
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

const GradeComparator = struct {
    pub const Context = Value;
    pub const Cursor = CompareCursor;

    pub fn init(collection: Context, left: usize, right: usize) Cursor {
        return .init(list.atUnchecked(collection, left), list.atUnchecked(collection, right));
    }

    pub fn advance(cursor: *Cursor, budget: usize) poll.Progress(std.math.Order) {
        return switch (cursor.advance(budget)) {
            .pending => .pending,
            .not_comparable => unreachable,
            .complete => |ordering| .{ .complete = ordering },
        };
    }
};

const GradeSortCursor = poll.MergeSortCursor(usize, GradeComparator);

const CompareDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: heap.Owned(Value),
    cursor: CompareCursor,
    pub fn advance(evaluator: *Machine, self: *CompareDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.cursor.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .not_comparable => evaluator.typeError("two comparable numbers, chars, or strings"),
            .complete => |ordering| .{ .output = .{ .int = switch (ordering) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            } } },
        };
    }
};

const GradeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    sorted_values: bool,
    indices: heap.Owned([]usize),
    sort: ?heap.Owned(GradeSortCursor) = null,
    phase: enum { validate, initialize, sort, prepare, materialize } = .validate,
    index: usize = 0,
    comparator: ?CompareCursor = null,
    integers: ?heap.Owned([]i64) = null,
    values: ?heap.Owned([]Value) = null,
    i64_materializer: ?heap.Owned(storage.I64Materializer) = null,
    value_materializer: ?heap.Owned(storage.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *GradeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .validate => {
                if (self.indices.borrow().len == 0 or self.index == self.indices.borrow().len) {
                    self.phase = .initialize;
                    self.index = 0;
                    continue;
                }
                if (self.comparator == null) self.comparator = .init(
                    list.atUnchecked(self.collection.borrow(), 0),
                    list.atUnchecked(self.collection.borrow(), self.index),
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
                const indices = self.indices.borrow();
                const end = @min(self.index + budget, indices.len);
                const initialized = end - self.index;
                while (self.index != end) : (self.index += 1) indices[self.index] = self.index;
                budget -= initialized;
                if (self.index == indices.len) {
                    self.sort = .init(try .init(
                        evaluator.allocator(),
                        indices,
                        self.collection.borrow(),
                    ));
                    self.phase = .sort;
                    self.index = 0;
                }
            },
            .sort => switch (self.sort.?.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => {
                    self.sort.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.sort = null;
                    self.phase = .prepare;
                    self.index = 0;
                    continue;
                },
            },
            .prepare => {
                if (self.sorted_values) {
                    if (self.values == null) self.values = .init(try evaluator.allocator().alloc(
                        Value,
                        self.indices.borrow().len,
                    ));
                    const values = self.values.?.borrow();
                    const indices = self.indices.borrow();
                    const end = @min(self.index + budget, indices.len);
                    const prepared = end - self.index;
                    while (self.index != end) : (self.index += 1)
                        values[self.index] = list.atUnchecked(self.collection.borrow(), indices[self.index]);
                    budget -= prepared;
                    if (self.index == indices.len) {
                        self.value_materializer = .init(storage.ValueMaterializer.init(
                            evaluator.allocator(),
                            values,
                        ));
                        self.phase = .materialize;
                    }
                } else {
                    if (self.integers == null) self.integers = .init(try evaluator.allocator().alloc(
                        i64,
                        self.indices.borrow().len,
                    ));
                    const integers = self.integers.?.borrow();
                    const indices = self.indices.borrow();
                    const end = @min(self.index + budget, indices.len);
                    const prepared = end - self.index;
                    while (self.index != end) : (self.index += 1)
                        integers[self.index] = @intCast(indices[self.index]);
                    budget -= prepared;
                    if (self.index == indices.len) {
                        self.i64_materializer = .init(storage.I64Materializer.init(
                            evaluator.allocator(),
                            integers,
                        ));
                        self.phase = .materialize;
                    }
                }
            },
            .materialize => {
                const progress: union(enum) { pending, complete: Value } = if (self.sorted_values)
                    switch (try self.value_materializer.?.borrowMut().advance(budget)) {
                        .pending => .pending,
                        .complete => |result| .{ .complete = result },
                    }
                else switch (try self.i64_materializer.?.borrowMut().advance(budget)) {
                    .pending => .pending,
                    .complete => |result| .{ .complete = result },
                };
                return switch (progress) {
                    .pending => .yielded,
                    .complete => |result| .{ .output = result },
                };
            },
        };
        return .yielded;
    }
};

fn distinctPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    const results = try evaluator.allocator().alloc(Value, count);
    try evaluator.startDriver(DistinctDriver{
        .collection = .init(collection.take()),
        .results = .init(results),
    });
}

pub fn distinctForIdiom(evaluator: *Machine) MachineError!void {
    return distinctPrimitive(evaluator);
}

const DistinctDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    results: heap.Owned([]Value),
    result_count: usize = 0,
    item_index: usize = 0,
    candidate: usize = 0,
    matcher: ?heap.Owned(equal.MatchCursor) = null,
    materializer: ?heap.Owned(storage.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *DistinctDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) {
            if (self.materializer) |*materializer| {
                return switch (try materializer.borrowMut().advance(budget)) {
                    .pending => .yielded,
                    .complete => |result| completed: {
                        materializer.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.materializer = null;
                        break :completed .{ .output = result };
                    },
                };
            }
            if (self.item_index == self.results.borrow().len) {
                self.materializer = .init(storage.ValueMaterializer.init(
                    evaluator.allocator(),
                    self.results.borrow()[0..self.result_count],
                ));
                continue;
            }
            if (self.candidate == self.result_count) {
                self.results.borrow()[self.result_count] = list.atUnchecked(
                    self.collection.borrow(),
                    self.item_index,
                );
                self.result_count += 1;
                self.item_index += 1;
                self.candidate = 0;
                budget -= 1;
                continue;
            }
            if (self.matcher == null) self.matcher = .init(try equal.MatchCursor.init(
                evaluator.allocator(),
                self.results.borrow()[self.candidate],
                list.atUnchecked(self.collection.borrow(), self.item_index),
            ));
            switch (try self.matcher.?.borrowMut().advance(1)) {
                .pending => budget -= 1,
                .complete => |matches| {
                    self.matcher.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
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
};

fn groupPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    try evaluator.startDriver(GroupDriver{ .collection = .init(collection.take()) });
}

const GroupDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    keys: ?heap.Owned([]Value) = null,
    assignments: ?heap.Owned([]usize) = null,
    frequencies: ?heap.Owned([]usize) = null,
    offsets: ?heap.Owned([]usize) = null,
    cursors: ?heap.Owned([]usize) = null,
    indices: ?heap.Owned([]i64) = null,
    pairs: ?heap.Owned([]dict.Pair) = null,
    phase: enum { allocate, scan, offsets, cursors, scatter, groups, dictionary } = .allocate,
    item_index: usize = 0,
    key_count: usize = 0,
    candidate: usize = 0,
    index: usize = 0,
    matcher: ?heap.Owned(equal.MatchCursor) = null,
    group_materializer: ?heap.Owned(storage.I64Materializer) = null,
    dict_materializer: ?heap.Owned(storage.DictMaterializer) = null,
    group_values: ?heap.Owned(heap.OwnedValueBuffer) = null,

    fn allocate(self: *GroupDriver, evaluator: *Machine) error{OutOfMemory}!void {
        const allocator = evaluator.allocator();
        const count: usize = @intCast(self.collection.borrow().list.length());
        self.keys = .init(try allocator.alloc(Value, count));
        self.assignments = .init(try allocator.alloc(usize, count));
        self.frequencies = .init(try allocator.alloc(usize, count));
        self.offsets = .init(try allocator.alloc(usize, count + 1));
        self.cursors = .init(try allocator.alloc(usize, count));
        self.indices = .init(try allocator.alloc(i64, count));
        self.pairs = .init(try allocator.alloc(dict.Pair, count));
        self.group_values = .init(try .init(evaluator.releaseDomain(), count));
        self.offsets.?.borrow()[0] = 0;
        self.phase = .scan;
    }

    pub fn advance(evaluator: *Machine, self: *GroupDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .allocate => try self.allocate(evaluator),
            .scan => {
                const count: usize = @intCast(self.collection.borrow().list.length());
                if (self.item_index == count) {
                    self.phase = .offsets;
                    self.index = 0;
                    continue;
                }
                if (self.candidate == self.key_count) {
                    self.keys.?.borrow()[self.key_count] = list.atUnchecked(
                        self.collection.borrow(),
                        self.item_index,
                    );
                    self.frequencies.?.borrow()[self.key_count] = 0;
                    self.key_count += 1;
                    self.assignments.?.borrow()[self.item_index] = self.key_count - 1;
                    self.frequencies.?.borrow()[self.key_count - 1] += 1;
                    self.item_index += 1;
                    self.candidate = 0;
                    budget -= 1;
                    continue;
                }
                if (self.matcher == null) self.matcher = .init(try equal.MatchCursor.init(
                    evaluator.allocator(),
                    self.keys.?.borrow()[self.candidate],
                    list.atUnchecked(self.collection.borrow(), self.item_index),
                ));
                switch (try self.matcher.?.borrowMut().advance(1)) {
                    .pending => budget -= 1,
                    .complete => |matches| {
                        self.matcher.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.matcher = null;
                        if (matches) {
                            self.assignments.?.borrow()[self.item_index] = self.candidate;
                            self.frequencies.?.borrow()[self.candidate] += 1;
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
                self.offsets.?.borrow()[self.index + 1] =
                    self.offsets.?.borrow()[self.index] + self.frequencies.?.borrow()[self.index];
                self.index += 1;
                budget -= 1;
            },
            .cursors => {
                if (self.index == self.key_count) {
                    self.phase = .scatter;
                    self.index = 0;
                    continue;
                }
                self.cursors.?.borrow()[self.index] = self.offsets.?.borrow()[self.index];
                self.index += 1;
                budget -= 1;
            },
            .scatter => {
                if (self.index == self.assignments.?.borrow().len) {
                    self.phase = .groups;
                    self.index = 0;
                    continue;
                }
                const group_index = self.assignments.?.borrow()[self.index];
                self.indices.?.borrow()[self.cursors.?.borrow()[group_index]] = @intCast(self.index);
                self.cursors.?.borrow()[group_index] += 1;
                self.index += 1;
                budget -= 1;
            },
            .groups => {
                if (self.index == self.key_count) {
                    self.dict_materializer = .init(try storage.DictMaterializer.init(
                        evaluator.allocator(),
                        self.pairs.?.borrow()[0..self.key_count],
                        false,
                    ));
                    self.phase = .dictionary;
                    continue;
                }
                if (self.group_materializer == null) self.group_materializer = .init(storage.I64Materializer.init(
                    evaluator.allocator(),
                    self.indices.?.borrow()[self.offsets.?.borrow()[self.index]..self.offsets.?.borrow()[self.index + 1]],
                ));
                switch (try self.group_materializer.?.borrowMut().advance(budget)) {
                    .pending => return .yielded,
                    .complete => |group| {
                        self.group_materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.group_materializer = null;
                        self.pairs.?.borrow()[self.index] = .{ self.keys.?.borrow()[self.index], group };
                        self.group_values.?.borrowMut().appendOwned(group);
                        self.index += 1;
                        return .yielded;
                    },
                }
            },
            .dictionary => switch (try self.dict_materializer.?.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .duplicate_key => unreachable,
                .complete => |result| {
                    self.dict_materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.dict_materializer = null;
                    self.group_values.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.group_values = null;
                    return .{ .output = result };
                },
            },
        };
        return .yielded;
    }
};
