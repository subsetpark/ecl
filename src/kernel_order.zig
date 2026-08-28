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
const poll = @import("poll.zig");
const kernel_flat = @import("kernel_flat.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

/// The sized-operation taxonomy lives in `kernel_support` so the registry in
/// `kernels.zig` classifies exactly the operations this installer publishes.
const Op = support.OrderOp;

const Entry = support.InstallationEntry(Op);
const Installation = support.ClosedInstallation(struct {
    pub const Operation = Op;
    pub const entries = [_]Entry{
        Entry.installed(.cmp),
        Entry.installed(.grade),
        Entry.installed(.group),
    };

    pub fn bind(comptime operation: Operation) env.PrimitiveImpl {
        return bindOperation(operation);
    }
});

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try Installation.install(core);
}

fn bindOperation(comptime operation: Op) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return switch (operation) {
                .cmp => cmpPrimitive(evaluator),
                .grade => gradePrimitive(evaluator),
                .group => groupPrimitive(evaluator),
            };
        }
    }.run;
}

fn cmpPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const left_item = left.borrow();
    const right_item = right.borrow();
    if (try startTypedStringCompare(evaluator, left_item, right_item)) return;
    // Only two strings have anything to walk. Every other pair is one call to
    // `compareScalars` -- the cursor's own answer for them -- which a driver and
    // a scheduler turn were being allocated to reach.
    if (!left_item.isString() and !right_item.isString()) {
        const ordering = equal.compareScalars(left_item, right_item) catch
            return evaluator.typeError("two comparable numbers, chars, or strings");
        return evaluator.pushOwned(.{ .int = switch (ordering) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        } });
    }
    try evaluator.startDriver(CompareDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .cursor = .init(left_item, right_item),
    });
}

const order_leaf_kinds = [_]value.HeapKind{
    .leaf_u8,
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
    .leaf_symbol,
};

const char_leaf_kinds = [_]value.HeapKind{ .leaf_char1, .leaf_char2, .leaf_char4 };

fn TypedStringCompareDriver(comptime left_kind: value.HeapKind, comptime right_kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        left: heap.Owned(heap.LeafReader(left_kind)),
        right: heap.Owned(heap.LeafReader(right_kind)),
        cursor: kernel_flat.FlatCursor,

        fn done(self: *Self, evaluator: *Machine, ordering: std.math.Order) machine.WorkProgress {
            self.left.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.right.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = .{ .int = switch (ordering) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            } } };
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            const left = self.left.borrow().slice();
            const right = self.right.borrow().slice();
            if (try self.cursor.nextRange(context)) |range| {
                for (range.start..range.end) |index| {
                    const left_char: u32 = left[index];
                    const right_char: u32 = right[index];
                    if (left_char < right_char) return self.done(evaluator, .lt);
                    if (left_char > right_char) return self.done(evaluator, .gt);
                }
            }
            if (!self.cursor.complete()) return .yielded;
            return self.done(evaluator, if (left.len < right.len)
                .lt
            else if (left.len > right.len)
                .gt
            else
                .eq);
        }
    };
}

fn startTypedStringCompare(evaluator: *Machine, left: Value, right: Value) MachineError!bool {
    if (!left.isString() or !right.isString()) return false;
    const left_kind = left.list.kind();
    const right_kind = right.list.kind();
    inline for (char_leaf_kinds) |candidate_left| {
        if (left_kind == candidate_left) inline for (char_leaf_kinds) |candidate_right| {
            if (right_kind == candidate_right) {
                const Driver = TypedStringCompareDriver(candidate_left, candidate_right);
                try evaluator.startDriver(Driver{
                    .left = .init(heap.LeafReader(candidate_left).acquire(left.list)),
                    .right = .init(heap.LeafReader(candidate_right).acquire(right.list)),
                    .cursor = kernel_flat.FlatCursor.init(@min(
                        @as(usize, @intCast(left.list.length())),
                        @as(usize, @intCast(right.list.length())),
                    )),
                });
                return true;
            }
        };
    }
    unreachable;
}

fn gradePrimitive(evaluator: *Machine) MachineError!void {
    return startGrade(evaluator, false);
}

fn startGrade(evaluator: *Machine, sorted_values: bool) MachineError!void {
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (collection.borrow() != .list) return evaluator.typeError("a comparable list");
    if (try startTypedGrade(evaluator, collection.borrow(), sorted_values)) return;
    const count: usize = @intCast(collection.borrow().list.length());
    const indices = try evaluator.allocator().alloc(usize, count);
    try evaluator.startDriver(GradeDriver{
        .collection = .init(collection.take()),
        .sorted_values = sorted_values,
        .indices = .init(indices),
        .state = .init(.{ .validate = 0 }),
    });
}

fn typedOrder(comptime kind: value.HeapKind, left: heap.LeafElement(kind), right: heap.LeafElement(kind)) std.math.Order {
    return switch (kind) {
        .leaf_u8, .leaf_i64, .leaf_char1, .leaf_char2, .leaf_char4 => if (left < right)
            .lt
        else if (left > right)
            .gt
        else
            .eq,
        .leaf_f64 => if (left < right) .lt else if (left > right) .gt else .eq,
        .leaf_symbol => unreachable,
        .generic_spine, .dict, .task, .module, .unit_plan, .reserved_mask => unreachable,
    };
}

fn TypedGradeComparator(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        pub const Context = []const Element;
        pub const Cursor = struct { ordering: std.math.Order };

        pub fn init(collection: Context, left: usize, right: usize) Cursor {
            return .{ .ordering = typedOrder(kind, collection[left], collection[right]) };
        }

        pub fn advance(cursor: *Cursor, budget: usize) poll.Progress(std.math.Order) {
            _ = budget;
            return .{ .complete = cursor.ordering };
        }
    };
}

fn TypedGradeDriver(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    const Sort = poll.MergeSortCursor(usize, TypedGradeComparator(kind));
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        collection: heap.Owned(heap.LeafReader(kind)),
        indices: heap.Owned([]usize),
        sorted_values: bool,
        phase: enum { initialize, sort, output } = .initialize,
        cursor: kernel_flat.FlatCursor,
        sort: ?heap.Owned(Sort) = null,
        index_writer: ?heap.Owned(heap.LeafWriter(.leaf_i64)) = null,
        value_writer: ?heap.Owned(heap.LeafWriter(kind)) = null,

        fn finish(self: *Self, evaluator: *Machine) machine.WorkProgress {
            self.collection.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = if (self.sorted_values)
                self.value_writer.?.borrowMut().finish()
            else
                self.index_writer.?.borrowMut().finish() };
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            switch (self.phase) {
                .initialize => {
                    const range = (try self.cursor.nextRange(context)).?;
                    const indices = self.indices.borrow();
                    for (range.start..range.end) |index| indices[index] = index;
                    if (!self.cursor.complete()) return .yielded;
                    self.sort = .init(try Sort.init(
                        evaluator.allocator(),
                        indices,
                        self.collection.borrow().slice(),
                    ));
                    self.phase = .sort;
                    return .yielded;
                },
                .sort => {
                    const charge = @max(context.remaining(), 1);
                    try context.advance(charge);
                    switch (self.sort.?.borrowMut().advance(charge)) {
                        .pending => return .yielded,
                        .complete => {
                            self.sort.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                            self.sort = null;
                            const count = self.indices.borrow().len;
                            if (self.sorted_values) {
                                self.value_writer = .init(try heap.LeafWriter(kind).init(evaluator.allocator(), count));
                            } else {
                                self.index_writer = .init(try heap.LeafWriter(.leaf_i64).init(evaluator.allocator(), count));
                            }
                            self.cursor = kernel_flat.FlatCursor.init(count);
                            self.phase = .output;
                            return .yielded;
                        },
                    }
                },
                .output => {
                    const range = (try self.cursor.nextRange(context)).?;
                    const indices = self.indices.borrow();
                    var value_block: [kernel_flat.block_size]Element = undefined;
                    var index_block: [kernel_flat.block_size]i64 = undefined;
                    var offset: usize = 0;
                    while (offset != range.len()) {
                        const piece = kernel_flat.blockRange(range, offset);
                        if (self.sorted_values) {
                            const source = self.collection.borrow().slice();
                            for (piece.start..piece.end) |index| value_block[index - piece.start] = source[indices[index]];
                            self.value_writer.?.borrowMut().writeRange(piece.start, value_block[0..piece.len()]);
                        } else {
                            for (piece.start..piece.end) |index| index_block[index - piece.start] = @intCast(indices[index]);
                            self.index_writer.?.borrowMut().writeRange(piece.start, index_block[0..piece.len()]);
                        }
                        offset += piece.len();
                    }
                    if (!self.cursor.complete()) return .yielded;
                    return self.finish(evaluator);
                },
            }
        }
    };
}

fn startTypedGrade(evaluator: *Machine, collection: Value, sorted_values: bool) MachineError!bool {
    const count: usize = @intCast(collection.list.length());
    if (count == 0 or collection.list.kind() == .generic_spine) return false;
    const kind = collection.list.kind();
    if (kind == .leaf_symbol) return evaluator.failAtIndex(
        .type,
        "grade expected mutually comparable numbers, chars, or strings",
        0,
    );
    inline for (order_leaf_kinds) |candidate| {
        if (kind == candidate) {
            const Driver = TypedGradeDriver(candidate);
            const indices = try evaluator.allocator().alloc(usize, count);
            try evaluator.startDriver(Driver{
                .collection = .init(heap.LeafReader(candidate).acquire(collection.list)),
                .indices = .init(indices),
                .sorted_values = sorted_values,
                .cursor = kernel_flat.FlatCursor.init(count),
            });
            return true;
        }
    }
    unreachable;
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
    state: heap.Owned(State),

    const State = union(enum) {
        validate: usize,
        compare: struct { index: usize, cursor: CompareCursor },
        initialize: usize,
        sort: heap.Owned(GradeSortCursor),
        prepare,
        prepare_values: struct { index: usize, values: heap.Owned([]Value) },
        materialize_values: struct {
            values: heap.Owned([]Value),
            materializer: heap.Owned(list.ValueMaterializer),
        },
        prepare_indices: struct {
            index: usize,
            writer: heap.Owned(heap.LeafWriter(.leaf_i64)),
        },
        complete_values: heap.Owned([]Value),
        complete,

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .sort => |*sort| sort.deinit(releases, allocator),
                .prepare_values => |*prepare| prepare.values.deinit(releases, allocator),
                .materialize_values => |*materialize| {
                    materialize.materializer.deinit(releases, allocator);
                    materialize.values.deinit(releases, allocator);
                },
                .prepare_indices => |*prepare| prepare.writer.deinit(releases, allocator),
                .complete_values => |*values| values.deinit(releases, allocator),
                .validate, .compare, .initialize, .prepare, .complete => {},
            }
        }
    };

    pub fn advance(evaluator: *Machine, self: *GradeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.state.borrowMut().*) {
            .validate => |index| {
                if (self.indices.borrow().len == 0 or index == self.indices.borrow().len) {
                    self.state.borrowMut().* = .{ .initialize = 0 };
                    continue;
                }
                self.state.borrowMut().* = .{ .compare = .{
                    .index = index,
                    .cursor = .init(
                        list.atUnchecked(self.collection.borrow(), 0),
                        list.atUnchecked(self.collection.borrow(), index),
                    ),
                } };
            },
            .compare => |*compare| {
                switch (compare.cursor.advance(1)) {
                    .pending => return .yielded,
                    .not_comparable => return evaluator.failAtIndex(
                        .type,
                        "grade expected mutually comparable numbers, chars, or strings",
                        compare.index,
                    ),
                    .complete => {
                        self.state.borrowMut().* = .{ .validate = compare.index + 1 };
                        budget -= 1;
                    },
                }
            },
            .initialize => |*index| {
                const indices = self.indices.borrow();
                const end = @min(index.* + budget, indices.len);
                const initialized = end - index.*;
                while (index.* != end) : (index.* += 1) indices[index.*] = index.*;
                budget -= initialized;
                if (index.* == indices.len) {
                    const sort = try GradeSortCursor.init(
                        evaluator.allocator(),
                        indices,
                        self.collection.borrow(),
                    );
                    self.state.borrowMut().* = .{ .sort = .init(sort) };
                }
            },
            .sort => |*sort| switch (sort.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => {
                    sort.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .prepare;
                    continue;
                },
            },
            .prepare => {
                if (self.sorted_values) {
                    const values = try evaluator.allocator().alloc(
                        Value,
                        self.indices.borrow().len,
                    );
                    self.state.borrowMut().* = .{ .prepare_values = .{
                        .index = 0,
                        .values = .init(values),
                    } };
                } else {
                    const writer = try heap.LeafWriter(.leaf_i64).init(
                        evaluator.allocator(),
                        self.indices.borrow().len,
                    );
                    self.state.borrowMut().* = .{ .prepare_indices = .{
                        .index = 0,
                        .writer = .init(writer),
                    } };
                }
            },
            .prepare_values => |*prepare| {
                const values = prepare.values.borrow();
                const indices = self.indices.borrow();
                const end = @min(prepare.index + budget, indices.len);
                const prepared = end - prepare.index;
                while (prepare.index != end) : (prepare.index += 1)
                    values[prepare.index] = list.atUnchecked(self.collection.borrow(), indices[prepare.index]);
                budget -= prepared;
                if (prepare.index == indices.len) {
                    const materializer = list.ValueMaterializer.init(
                        evaluator.allocator(),
                        values,
                    );
                    self.state.borrowMut().* = .{ .materialize_values = .{
                        .values = .init(prepare.values.take()),
                        .materializer = .init(materializer),
                    } };
                }
            },
            .prepare_indices => |*prepare| {
                const indices = self.indices.borrow();
                const end = @min(prepare.index + budget, indices.len);
                const prepared = end - prepare.index;
                var block: [kernel_flat.block_size]i64 = undefined;
                var offset = prepare.index;
                while (offset != end) {
                    const piece_end = @min(offset + kernel_flat.block_size, end);
                    for (offset..piece_end) |index| block[index - offset] = @intCast(indices[index]);
                    prepare.writer.borrowMut().writeRange(offset, block[0 .. piece_end - offset]);
                    offset = piece_end;
                }
                prepare.index = end;
                budget -= prepared;
                if (prepare.index == indices.len) {
                    const result = prepare.writer.borrowMut().finish();
                    _ = prepare.writer.take();
                    self.state.borrowMut().* = .complete;
                    return .{ .output = result };
                }
            },
            .materialize_values => |*materialize| {
                return switch (try materialize.materializer.borrowMut().advance(budget)) {
                    .pending => .yielded,
                    .complete => |result| completed: {
                        materialize.materializer.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        self.state.borrowMut().* = .{ .complete_values = .init(
                            materialize.values.take(),
                        ) };
                        break :completed .{ .output = result };
                    },
                };
            },
            .complete_values, .complete => unreachable,
        };
        return .yielded;
    }
};

fn distinctPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    if (count != 0) {
        const kind = collection.borrow().list.kind();
        inline for (order_leaf_kinds) |candidate| {
            if (kind == candidate) {
                const Driver = TypedDistinctDriver(candidate);
                try evaluator.startDriver(Driver{
                    .source = .init(heap.LeafReader(candidate).acquire(collection.borrow().list)),
                });
                return;
            }
        }
    }
    const results = try evaluator.allocator().alloc(Value, count);
    try evaluator.startDriver(DistinctDriver{
        .collection = .init(collection.take()),
        .results = .init(results),
    });
}

fn TypedDistinctDriver(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        source: heap.Owned(heap.LeafReader(kind)),
        writer: ?heap.Owned(heap.LeafWriter(kind)) = null,
        phase: enum { count, fill } = .count,
        item_index: usize = 0,
        candidate: usize = 0,
        distinct_count: usize = 0,
        output_index: usize = 0,

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            var budget = @max(context.remaining(), 1);
            try context.advance(budget);
            const source: []const Element = self.source.borrow().slice();
            while (budget != 0) {
                if (self.item_index == source.len) {
                    if (self.phase == .count) {
                        self.writer = .init(try heap.LeafWriter(kind).init(
                            evaluator.allocator(),
                            self.distinct_count,
                        ));
                        self.phase = .fill;
                        self.item_index = 0;
                        self.candidate = 0;
                        continue;
                    }
                    std.debug.assert(self.output_index == self.distinct_count);
                    self.source.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    return .{ .output = self.writer.?.borrowMut().finish() };
                }
                if (self.candidate == self.item_index) {
                    if (self.phase == .count) {
                        self.distinct_count += 1;
                    } else {
                        self.writer.?.borrowMut().writeRange(
                            self.output_index,
                            &.{source[self.item_index]},
                        );
                        self.output_index += 1;
                    }
                    self.item_index += 1;
                    self.candidate = 0;
                    budget -= 1;
                    continue;
                }
                if (source[self.candidate] == source[self.item_index]) {
                    self.item_index += 1;
                    self.candidate = 0;
                } else self.candidate += 1;
                budget -= 1;
            }
            return .yielded;
        }
    };
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
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

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
                self.materializer = .init(list.ValueMaterializer.init(
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
    if (try startTypedGroup(evaluator, collection.borrow())) return;
    try evaluator.startDriver(GroupDriver{ .collection = .init(collection.take()) });
}

fn typedValue(comptime kind: value.HeapKind, item: heap.LeafElement(kind)) Value {
    return switch (kind) {
        .leaf_u8 => .{ .int = item },
        .leaf_i64 => .{ .int = item },
        .leaf_f64 => .{ .float = item },
        .leaf_char1, .leaf_char2, .leaf_char4 => .{ .char = @intCast(item) },
        .leaf_symbol => .{ .symbol = item },
        .generic_spine, .dict, .task, .module, .unit_plan, .reserved_mask => unreachable,
    };
}

fn TypedGroupDriver(comptime kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        collection: heap.Owned(heap.LeafReader(kind)),
        key_indices: ?heap.Owned([]usize) = null,
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
        group_writer: ?heap.Owned(heap.LeafWriter(.leaf_i64)) = null,
        group_cursor: kernel_flat.FlatCursor = .{ .length = 0 },
        dict_materializer: ?heap.Owned(dict.Materializer) = null,
        group_values: ?heap.Owned(heap.OwnedValueBuffer) = null,

        fn allocate(self: *Self, evaluator: *Machine) error{OutOfMemory}!void {
            const allocator = evaluator.allocator();
            const count = self.collection.borrow().len();
            self.key_indices = .init(try allocator.alloc(usize, count));
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

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };

            if (self.phase == .groups) {
                if (self.index == self.key_count) {
                    self.dict_materializer = .init(try dict.Materializer.init(
                        evaluator.allocator(),
                        self.pairs.?.borrow()[0..self.key_count],
                        false,
                    ));
                    self.phase = .dictionary;
                    return .yielded;
                }
                if (self.group_writer == null) {
                    const start = self.offsets.?.borrow()[self.index];
                    const end = self.offsets.?.borrow()[self.index + 1];
                    self.group_writer = .init(try heap.LeafWriter(.leaf_i64).init(evaluator.allocator(), end - start));
                    self.group_cursor = kernel_flat.FlatCursor.init(end - start);
                }
                if (try self.group_cursor.nextRange(context)) |range| {
                    const start = self.offsets.?.borrow()[self.index];
                    self.group_writer.?.borrowMut().writeRange(
                        range.start,
                        self.indices.?.borrow()[start + range.start .. start + range.end],
                    );
                }
                if (!self.group_cursor.complete()) return .yielded;
                const group = self.group_writer.?.borrowMut().finish();
                self.group_writer = null;
                const key_position = self.key_indices.?.borrow()[self.index];
                self.pairs.?.borrow()[self.index] = .{
                    typedValue(kind, self.collection.borrow().slice()[key_position]),
                    group,
                };
                self.group_values.?.borrowMut().appendOwned(group);
                self.index += 1;
                return .yielded;
            }

            if (self.phase == .dictionary) {
                const charge = @max(context.remaining(), 1);
                try context.advance(charge);
                return switch (try self.dict_materializer.?.borrowMut().advance(charge)) {
                    .pending => .yielded,
                    .duplicate_key => unreachable,
                    .complete => |result| completed: {
                        self.dict_materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.dict_materializer = null;
                        self.group_values.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.group_values = null;
                        self.collection.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        break :completed .{ .output = result };
                    },
                };
            }

            const charge = @max(context.remaining(), 1);
            try context.advance(charge);
            var budget = charge;
            const source = self.collection.borrow().slice();
            while (budget != 0) switch (self.phase) {
                .allocate => try self.allocate(evaluator),
                .scan => {
                    if (self.item_index == source.len) {
                        self.phase = .offsets;
                        self.index = 0;
                        continue;
                    }
                    if (self.candidate == self.key_count) {
                        self.key_indices.?.borrow()[self.key_count] = self.item_index;
                        self.frequencies.?.borrow()[self.key_count] = 0;
                        self.key_count += 1;
                        self.assignments.?.borrow()[self.item_index] = self.key_count - 1;
                        self.frequencies.?.borrow()[self.key_count - 1] += 1;
                        self.item_index += 1;
                        self.candidate = 0;
                    } else if (source[self.key_indices.?.borrow()[self.candidate]] == source[self.item_index]) {
                        self.assignments.?.borrow()[self.item_index] = self.candidate;
                        self.frequencies.?.borrow()[self.candidate] += 1;
                        self.item_index += 1;
                        self.candidate = 0;
                    } else {
                        self.candidate += 1;
                    }
                    budget -= 1;
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
                    if (self.index == source.len) {
                        self.phase = .groups;
                        self.index = 0;
                        return .yielded;
                    }
                    const group_index = self.assignments.?.borrow()[self.index];
                    self.indices.?.borrow()[self.cursors.?.borrow()[group_index]] = @intCast(self.index);
                    self.cursors.?.borrow()[group_index] += 1;
                    self.index += 1;
                    budget -= 1;
                },
                .groups, .dictionary => unreachable,
            };
            return .yielded;
        }
    };
}

fn startTypedGroup(evaluator: *Machine, collection: Value) MachineError!bool {
    const count: usize = @intCast(collection.list.length());
    const kind = collection.list.kind();
    if (count == 0 or kind == .generic_spine) return false;
    inline for (order_leaf_kinds) |candidate| {
        if (kind == candidate) {
            const Driver = TypedGroupDriver(candidate);
            try evaluator.startDriver(Driver{
                .collection = .init(heap.LeafReader(candidate).acquire(collection.list)),
            });
            return true;
        }
    }
    unreachable;
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
    group_writer: ?heap.Owned(heap.LeafWriter(.leaf_i64)) = null,
    group_fill: usize = 0,
    dict_materializer: ?heap.Owned(dict.Materializer) = null,
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
                    self.dict_materializer = .init(try dict.Materializer.init(
                        evaluator.allocator(),
                        self.pairs.?.borrow()[0..self.key_count],
                        false,
                    ));
                    self.phase = .dictionary;
                    continue;
                }
                const start = self.offsets.?.borrow()[self.index];
                const end = self.offsets.?.borrow()[self.index + 1];
                if (self.group_writer == null) self.group_writer = .init(try heap.LeafWriter(.leaf_i64).init(
                    evaluator.allocator(),
                    end - start,
                ));
                const copied = @min(budget, end - start - self.group_fill);
                self.group_writer.?.borrowMut().writeRange(
                    self.group_fill,
                    self.indices.?.borrow()[start + self.group_fill .. start + self.group_fill + copied],
                );
                self.group_fill += copied;
                budget -= copied;
                if (self.group_fill != end - start) return .yielded;
                const group = self.group_writer.?.borrowMut().finish();
                self.group_writer = null;
                self.group_fill = 0;
                self.pairs.?.borrow()[self.index] = .{ self.keys.?.borrow()[self.index], group };
                self.group_values.?.borrowMut().appendOwned(group);
                self.index += 1;
                if (budget == 0) return .yielded;
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
