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

/// The operation family lives in `kernel_support`, beside the others.
const Op = support.OrderOp;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(Op)) |operation| {
        try core.installBuiltin(definition(operation));
    }
}

fn definition(comptime operation: Op) env.BuiltinWord {
    return switch (operation) {
        .cmp => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "left right -- ordering", .doc = "Return -1, 0, or 1 for the whole-value order of two comparable values; lists order lexicographically." },
        .grade => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- indices", .doc = "Return the stable ascending sort permutation of a comparable list." },
        .distinct => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- list", .doc = "Return the first occurrence of each distinct list value in input order." },
        .group_columns => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "columns -- groups", .doc = "Group equal-length columns by composite row keys in first-occurrence order." },
        .group => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- dict", .doc = "Group equal list values into a dictionary of zero-based index lists." },
    };
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Machine) MachineError!void {
            return switch (operation) {
                .cmp => cmpPrimitive(evaluator),
                .grade => gradePrimitive(evaluator),
                .distinct => distinctPrimitive(evaluator),
                .group => groupPrimitive(evaluator),
                .group_columns => groupColumnsPrimitive(evaluator),
            };
        }
    }.run);
}

fn cmpPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const left_item = left.borrow();
    const right_item = right.borrow();
    // Two typed number or char lists, strings among them, have no nesting to
    // descend, so the flat kernel searches their shared prefix.
    if (lexCompareCandidate(left_item, right_item))
        return startLexCompare(evaluator, &left, &right);
    // Only two lists have anything to walk. Every other pair is one call to
    // `compareScalars` -- the cursor's own answer for them -- which a driver and
    // a scheduler turn were being allocated to reach.
    if (left_item != .list or right_item != .list) {
        const ordering = equal.compareScalars(left_item, right_item) catch
            return evaluator.typeError(incomparable_pair);
        return evaluator.pushOwned(.{ .int = switch (ordering) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        } });
    }
    try evaluator.startDriver(CompareDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .cursor = .init(.init(evaluator.allocator(), left_item, right_item)),
    });
}

const incomparable_pair = "two comparable numbers, chars, or lists";
const incomparable_grade = "grade expected mutually comparable numbers, chars, or lists";

/// The kinds `cmp` orders within. Values of two classes never order, and a
/// value with no class orders with nothing.
const OrderClass = enum { number, char, list };

fn orderClass(item: Value) ?OrderClass {
    return switch (item) {
        .int, .float => .number,
        .char => .char,
        .list => .list,
        .symbol, .dict, .task, .port, .address => null,
    };
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

/// The classes `cmp` orders within: numbers with numbers, chars with chars.
const LexClass = enum { number, char };

fn lexClass(comptime kind: value.HeapKind) ?LexClass {
    return switch (kind) {
        .leaf_u8, .leaf_i64, .leaf_f64 => .number,
        .leaf_char1, .leaf_char2, .leaf_char4 => .char,
        else => null,
    };
}

const lex_leaf_kinds = [_]value.HeapKind{ .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4 };

/// Lexicographic order of two typed lists under `cmp`: a search over their
/// shared prefix that stops at the first difference, and otherwise orders by
/// length. A pair `cmp` cannot order faults there, as `cmp` would: lists of
/// two classes fault at their first pair.
fn LexCompareKernel(comptime left_kind: value.HeapKind, comptime right_kind: value.HeapKind) type {
    const comparable = lexClass(left_kind).? == lexClass(right_kind).?;
    const floating = left_kind == .leaf_f64 or right_kind == .leaf_f64;
    return struct {
        pub const arity = 2;
        pub const Params = void;
        pub const Output = struct {
            /// The order of the lengths until a difference decides it.
            ordering: std.math.Order,
            decided: bool = false,

            pub fn retire(_: *Output, _: *heap.ReleaseDomain) void {}
        };

        pub fn prepare(_: *Machine, operands: [2]Value, _: void, _: usize) error{OutOfMemory}!Output {
            return .{ .ordering = std.math.order(operands[0].list.length(), operands[1].list.length()) };
        }

        pub fn chunk(_: void, operands: [2]Value, output: *Output, range: kernel_flat.Chunk, context: support.Context) MachineError!void {
            if (comptime !comparable) return incomparable(context);
            const left = heap.leafElements(left_kind, operands[0].list);
            const right = heap.leafElements(right_kind, operands[1].list);
            for (range.start..range.end) |index| {
                const ordering = if (comptime floating)
                    equal.compareScalars(scalar(left_kind, left[index]), scalar(right_kind, right[index])) catch
                        return incomparable(context)
                else
                    std.math.order(widen(left[index]), widen(right[index]));
                if (ordering != .eq) {
                    output.ordering = ordering;
                    output.decided = true;
                    return;
                }
            }
        }

        fn incomparable(context: support.Context) MachineError {
            return context.evaluator.typeError(incomparable_pair);
        }

        fn widen(element: anytype) if (lexClass(left_kind) == .char) u32 else i64 {
            return element;
        }

        fn scalar(comptime kind: value.HeapKind, element: anytype) Value {
            return if (kind == .leaf_f64) .{ .float = element } else .{ .int = element };
        }

        pub fn done(output: *const Output) bool {
            return output.decided;
        }

        pub fn finish(output: *Output) Value {
            return .{ .int = switch (output.ordering) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            } };
        }
    };
}

/// Whether `lexCompare` orders these two values without a comparator call:
/// two lists whose shared prefix is empty, or two typed number or char lists.
pub fn lexCompareCandidate(left: Value, right: Value) bool {
    if (left != .list or right != .list) return false;
    if (@min(left.list.length(), right.list.length()) == 0) return true;
    return lexKind(left.list.kind()) and lexKind(right.list.kind());
}

fn lexKind(kind: value.HeapKind) bool {
    return std.mem.findScalar(value.HeapKind, &lex_leaf_kinds, kind) != null;
}

/// `( left right -- ordering )`: `cmp`, which is `(cmp) lex-cmp-with`, over
/// two lists that `lexCompareCandidate` admits.
pub fn lexCompare(evaluator: *Machine) MachineError!void {
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    return startLexCompare(evaluator, &left, &right);
}

fn startLexCompare(evaluator: *Machine, left: *heap.OwnedValue, right: *heap.OwnedValue) MachineError!void {
    const left_list = left.borrow().list;
    const right_list = right.borrow().list;
    const shared: usize = @intCast(@min(left_list.length(), right_list.length()));
    if (shared == 0) return evaluator.pushOwned(.{ .int = switch (std.math.order(left_list.length(), right_list.length())) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } });
    inline for (lex_leaf_kinds) |candidate_left| {
        if (left_list.kind() == candidate_left) inline for (lex_leaf_kinds) |candidate_right| {
            if (right_list.kind() == candidate_right)
                return support.Kernel(LexCompareKernel(candidate_left, candidate_right)).run(evaluator, .{ left, right }, {}, shared);
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
    if (try startTypedGrade(evaluator, &collection, sorted_values)) return;
    const count: usize = @intCast(collection.borrow().list.length());
    const indices = try evaluator.allocator().alloc(usize, count);
    try evaluator.startDriver(GradeDriver{
        .collection = .init(collection.take()),
        .sorted_values = sorted_values,
        .indices = .init(indices),
        .state = .init(.{ .validate = 0 }),
    });
}

/// A stable sort of (key, position) pairs. Keys are compared in place rather
/// than through a position into the collection, and floats by an integer
/// image; runs of `run_width` are insertion-sorted first and bottom-up merge
/// passes follow. Each pass is a phase of one position per pair: keying, the
/// runs, every merge pass, and the output. Leaf comparisons are a strict weak
/// order (floats exclude NaN), so any stable sort yields the one permutation
/// `grade` names.
fn GradeKernel(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    // Floats sort by an order-preserving unsigned image, so the merge
    // compares integers; both zeros map to one key and stay in input order.
    const Key = if (Element == f64) u64 else Element;
    const Pair = struct { key: Key, position: usize };
    const run_width = 16;
    return struct {
        pub const arity = 1;
        /// Whether the result is the sorted values rather than their indices.
        pub const Params = bool;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            sorted_values: bool,
            pairs: []Pair,
            scratch: []Pair,
            phase: enum { initialize, runs, merge, output } = .initialize,
            /// The width of the runs being merged, the buffer holding them, and
            /// the progress through the pair of runs that begins at `start`.
            width: usize = run_width,
            from_scratch: bool = false,
            start: usize = 0,
            left: usize = 0,
            right: usize = 0,
            output: usize = 0,
            index_writer: ?heap.LeafWriter(.leaf_i64) = null,
            value_writer: ?heap.LeafWriter(kind) = null,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.allocator.free(self.pairs);
                self.allocator.free(self.scratch);
                if (self.index_writer) |*writer| writer.retire(releases);
                if (self.value_writer) |*writer| writer.retire(releases);
            }

            fn sorted(self: *const Output) []const Pair {
                return if (self.from_scratch) self.scratch else self.pairs;
            }
        };

        pub fn prepare(evaluator: *Machine, _: [1]Value, sorted_values: bool, length: usize) error{OutOfMemory}!Output {
            const pairs = try evaluator.allocator().alloc(Pair, length);
            errdefer evaluator.allocator().free(pairs);
            return .{
                .allocator = evaluator.allocator(),
                .sorted_values = sorted_values,
                .pairs = pairs,
                .scratch = try evaluator.allocator().alloc(Pair, length),
            };
        }

        pub fn chunk(_: bool, operands: [1]Value, output: *Output, range: kernel_flat.Chunk, _: support.Context) MachineError!void {
            const keys = heap.leafElements(kind, operands[0].list);
            switch (output.phase) {
                .initialize => for (output.pairs[range.start..range.end], range.start..) |*pair, position| {
                    pair.* = .{ .key = sortKey(keys[position]), .position = position };
                },
                // A range covers each run it starts, charged one unit per element.
                .runs => {
                    var position = std.mem.alignForward(usize, range.start, run_width);
                    while (position < range.end) : (position += run_width) {
                        sortRun(output.pairs[position..@min(position + run_width, output.pairs.len)]);
                    }
                },
                .merge => merge(output, range.len()),
                .output => {
                    const pairs = output.sorted()[range.start..range.end];
                    if (output.sorted_values) {
                        const out = output.value_writer.?.unpublishedRange(range.start, range.len());
                        for (out, pairs) |*slot, pair| slot.* = if (Key == Element) pair.key else keys[pair.position];
                    } else {
                        const out = output.index_writer.?.unpublishedRange(range.start, range.len());
                        for (out, pairs) |*slot, pair| slot.* = @intCast(pair.position);
                    }
                },
            }
        }

        pub fn next(context: support.Context, output: *Output) MachineError!?usize {
            const count = output.pairs.len;
            switch (output.phase) {
                .initialize => {
                    output.phase = .runs;
                    return count;
                },
                .runs => {},
                .merge => {
                    output.width *|= 2;
                    output.from_scratch = !output.from_scratch;
                },
                .output => return null,
            }
            if (output.width < count) {
                output.phase = .merge;
                output.start = 0;
                output.left = 0;
                output.right = @min(output.width, count);
                output.output = 0;
                return count;
            }
            if (output.sorted_values) {
                output.value_writer = try .init(context.allocator(), count);
            } else {
                output.index_writer = try .init(context.allocator(), count);
            }
            output.phase = .output;
            return count;
        }

        pub fn finish(output: *Output) Value {
            output.allocator.free(output.pairs);
            output.allocator.free(output.scratch);
            return if (output.value_writer) |*writer| writer.finish() else output.index_writer.?.finish();
        }

        fn sortKey(item: Element) Key {
            if (Element != f64) return item;
            const bits: u64 = @bitCast(if (item == 0) 0.0 else item);
            return if (bits >> 63 == 1) ~bits else bits | 1 << 63;
        }

        /// Whether `right` must precede `left`: only when strictly less, so
        /// equal keys keep their input order.
        fn before(right: Key, left: Key) bool {
            return right < left;
        }

        fn sortRun(run: []Pair) void {
            for (1..run.len) |index| {
                const item = run[index];
                var hole = index;
                while (hole != 0 and before(item.key, run[hole - 1].key)) : (hole -= 1) run[hole] = run[hole - 1];
                run[hole] = item;
            }
        }

        /// Merges the next `budget` pairs of the current pass.
        fn merge(self: *Output, budget: usize) void {
            const count = self.pairs.len;
            var produced: usize = 0;
            while (produced != budget) {
                const middle = @min(self.start + self.width, count);
                const end = @min(middle + self.width, count);
                if (self.output == end) {
                    self.start = end;
                    self.left = self.start;
                    self.right = @min(self.start +| self.width, count);
                    continue;
                }
                const source = self.sorted();
                const destination = if (self.from_scratch) self.pairs else self.scratch;
                // The cursors live in locals for the loop: through `self`
                // each store would feed the next element's loads.
                const limit = self.output + @min(budget - produced, end - self.output);
                var left = self.left;
                var right = self.right;
                var output = self.output;
                while (output != limit and left != middle and right != end) : (output += 1) {
                    const take_right = before(source[right].key, source[left].key);
                    destination[output] = if (take_right) source[right] else source[left];
                    right += @intFromBool(take_right);
                    left += @intFromBool(!take_right);
                }
                if (output != limit) {
                    const from = if (left == middle) &right else &left;
                    const run = limit - output;
                    @memcpy(destination[output..][0..run], source[from.*..][0..run]);
                    from.* += run;
                    output += run;
                }
                produced += output - self.output;
                self.left = left;
                self.right = right;
                self.output = output;
            }
        }
    };
}

fn startTypedGrade(evaluator: *Machine, collection: *heap.OwnedValue, sorted_values: bool) MachineError!bool {
    const count: usize = @intCast(collection.borrow().list.length());
    if (count == 0 or collection.borrow().list.kind() == .generic_spine) return false;
    const kind = collection.borrow().list.kind();
    if (kind == .leaf_symbol) return evaluator.failAtIndex(.type, incomparable_grade, 0);
    inline for (order_leaf_kinds) |candidate| {
        if (kind == candidate) {
            try support.Kernel(GradeKernel(candidate)).run(evaluator, .{collection}, sorted_values, count);
            return true;
        }
    }
    unreachable;
}

pub fn sortForIdiom(evaluator: *Machine) MachineError!void {
    try startGrade(evaluator, true);
}

const CompareProgress = union(enum) { pending, complete: std.math.Order, not_comparable };

/// `cmp`'s whole-value order: numbers with numbers, chars with chars, and two
/// lists by their first unequal element pair, then by length. Nesting is
/// walked through an explicit stack holding one frame per list pair entered,
/// so depth costs heap frames rather than host stack, and each element pair
/// draws one unit from the lent budget. A pair is compared only until the
/// first difference decides it: elements after it are never visited, so they
/// need not be comparable.
pub const CompareCursor = struct {
    frames: poll.ChunkStack(Frame),
    depth: usize = 0,
    /// The pair named at `init`, until the first `advance` classifies it.
    root: ?Pair,

    const Pair = struct { left: Value, right: Value };
    const Frame = struct { left: Value, right: Value, index: usize = 0 };

    pub fn init(allocator: std.mem.Allocator, left: Value, right: Value) CompareCursor {
        return .{ .frames = .init(allocator), .root = .{ .left = left, .right = right } };
    }

    pub fn deinit(self: *CompareCursor) void {
        self.frames.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *CompareCursor, work: *poll.WorkBudget) error{OutOfMemory}!CompareProgress {
        if (self.root) |root| {
            self.root = null;
            if (root.left != .list or root.right != .list) return complete(root.left, root.right);
            try self.enter(root.left, root.right);
        }
        descend: while (true) {
            const frame = self.frames.topPtr().?;
            const shared: usize = @intCast(@min(frame.left.list.length(), frame.right.list.length()));
            // Typed number or char lists hold no lists, so their prefix is
            // searched in one granted run.
            if (lexCompareCandidate(frame.left, frame.right)) {
                const end = frame.index + work.take(shared - frame.index);
                while (frame.index != end) : (frame.index += 1) {
                    const left = list.atUnchecked(frame.left, frame.index);
                    const right = list.atUnchecked(frame.right, frame.index);
                    const ordering = if (left == .char and right == .char)
                        std.math.order(left.char, right.char)
                    else
                        equal.compareScalars(left, right) catch return .not_comparable;
                    if (ordering != .eq) return .{ .complete = ordering };
                }
                if (frame.index != shared) return .pending;
            }
            while (frame.index != shared) {
                if (!work.spend()) return .pending;
                const left = list.atUnchecked(frame.left, frame.index);
                const right = list.atUnchecked(frame.right, frame.index);
                frame.index += 1;
                if (left == .list and right == .list) {
                    try self.enter(left, right);
                    continue :descend;
                }
                switch (complete(left, right)) {
                    .complete => |ordering| if (ordering != .eq) return .{ .complete = ordering },
                    else => |progress| return progress,
                }
            }
            const ordering = std.math.order(frame.left.list.length(), frame.right.list.length());
            _ = self.frames.pop();
            self.depth -= 1;
            if (ordering != .eq or self.depth == 0) return .{ .complete = ordering };
        }
    }

    fn enter(self: *CompareCursor, left: Value, right: Value) error{OutOfMemory}!void {
        try self.frames.push(.{ .left = left, .right = right });
        self.depth += 1;
    }

    /// A pair that is not two lists: one scalar comparison decides it.
    fn complete(left: Value, right: Value) CompareProgress {
        return .{ .complete = equal.compareScalars(left, right) catch return .not_comparable };
    }
};

/// Orders two positions of the collection under `cmp`. A pair `cmp` cannot
/// order ends the sort, naming the later of the two positions.
const GradeComparator = struct {
    pub const Context = struct { collection: Value, allocator: std.mem.Allocator };
    pub const Error = error{ OutOfMemory, NotComparable };
    pub const Cursor = struct { compare: CompareCursor, position: usize };

    pub fn init(context: Context, left: usize, right: usize) Cursor {
        return .{
            .compare = .init(
                context.allocator,
                list.atUnchecked(context.collection, left),
                list.atUnchecked(context.collection, right),
            ),
            .position = @max(left, right),
        };
    }

    pub fn advance(cursor: *Cursor, work: *poll.WorkBudget) Error!poll.Progress(std.math.Order) {
        return switch (try cursor.compare.advance(work)) {
            .pending => .pending,
            .not_comparable => error.NotComparable,
            .complete => |ordering| .{ .complete = ordering },
        };
    }

    pub fn deinit(cursor: *Cursor) void {
        cursor.compare.deinit();
    }
};

const GradeSortCursor = poll.MergeSortCursor(usize, GradeComparator);

const CompareDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: heap.Owned(Value),
    cursor: heap.Owned(CompareCursor),
    pub fn advance(evaluator: *Machine, self: *CompareDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .not_comparable => evaluator.typeError(incomparable_pair),
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

    /// `validate` checks every element against the first one's order class,
    /// which settles every scalar pair; a pair of lists can still fail inside
    /// the sort, where `cmp` reaches an incomparable element pair.
    const State = union(enum) {
        validate: usize,
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
                .validate, .initialize, .prepare, .complete => {},
            }
        }
    };

    pub fn advance(evaluator: *Machine, self: *GradeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.state.borrowMut().*) {
            .validate => |*index| {
                const collection = self.collection.borrow();
                const count = self.indices.borrow().len;
                if (count != 0) {
                    const class = orderClass(list.atUnchecked(collection, 0));
                    const end = index.* + work.take(count - index.*);
                    while (index.* != end) : (index.* += 1) {
                        if (class == null or orderClass(list.atUnchecked(collection, index.*)) != class)
                            return evaluator.failAtIndex(.type, incomparable_grade, index.*);
                    }
                }
                if (index.* == count) self.state.borrowMut().* = .{ .initialize = 0 };
            },
            .initialize => |*index| {
                const indices = self.indices.borrow();
                const end = index.* + work.take(indices.len - index.*);
                while (index.* != end) : (index.* += 1) indices[index.*] = index.*;
                if (index.* == indices.len) {
                    const sort = try GradeSortCursor.init(
                        evaluator.allocator(),
                        indices,
                        .{ .collection = self.collection.borrow(), .allocator = evaluator.allocator() },
                    );
                    self.state.borrowMut().* = .{ .sort = .init(sort) };
                }
            },
            .sort => |*sort| switch (sort.borrowMut().advance(work) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotComparable => return evaluator.failAtIndex(
                    .type,
                    incomparable_grade,
                    sort.borrowMut().comparing().?.position,
                ),
            }) {
                .pending => return .stepped,
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
                const end = prepare.index + work.take(indices.len - prepare.index);
                while (prepare.index != end) : (prepare.index += 1)
                    values[prepare.index] = list.atUnchecked(self.collection.borrow(), indices[prepare.index]);
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
                const end = prepare.index + work.take(indices.len - prepare.index);
                var block: [kernel_flat.block_size]i64 = undefined;
                var offset = prepare.index;
                while (offset != end) {
                    const piece_end = @min(offset + kernel_flat.block_size, end);
                    for (offset..piece_end) |index| block[index - offset] = @intCast(indices[index]);
                    prepare.writer.borrowMut().writeRange(offset, block[0 .. piece_end - offset]);
                    offset = piece_end;
                }
                prepare.index = end;
                if (prepare.index == indices.len) {
                    const result = prepare.writer.borrowMut().finish();
                    _ = prepare.writer.take();
                    self.state.borrowMut().* = .complete;
                    return .{ .output = result };
                }
            },
            .materialize_values => |*materialize| {
                return switch (try materialize.materializer.borrowMut().advance(work)) {
                    .pending => .stepped,
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
        return .stepped;
    }
};

fn distinctPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    if (count != 0) {
        const kind = collection.borrow().list.kind();
        inline for (order_leaf_kinds) |candidate| {
            if (kind == candidate) return support.Kernel(DistinctKernel(candidate)).run(evaluator, .{&collection}, {}, count);
        }
    }
    const results = try evaluator.allocator().alloc(Value, count);
    try evaluator.startDriver(DistinctDriver{
        .collection = .init(collection.take()),
        .results = .init(results),
    });
}

/// One hashed pass in input order: an element is kept when no kept element
/// equals it under the leaf's own `==`, so zeros of either sign meet (floats
/// exclude NaN). Kept elements collect in a scratch buffer, and a second
/// phase copies them into the exact-size result.
fn DistinctKernel(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        pub const arity = 1;
        pub const Params = void;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            /// Open-addressed positions into `kept`, plus one; zero is empty.
            slots: []usize,
            kept: []Element,
            kept_count: usize = 0,
            writer: ?heap.LeafWriter(kind) = null,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.allocator.free(self.slots);
                self.allocator.free(self.kept);
                if (self.writer) |*writer| writer.retire(releases);
            }

            /// Keeps `item` unless an equal element is already kept.
            fn keep(self: *Output, item: Element) void {
                const mask = self.slots.len - 1;
                var slot: usize = @intCast(hash(item) >> 32 & mask);
                while (self.slots[slot] != 0) : (slot = (slot + 1) & mask) {
                    if (self.kept[self.slots[slot] - 1] == item) return;
                }
                self.kept[self.kept_count] = item;
                self.kept_count += 1;
                self.slots[slot] = self.kept_count;
            }
        };

        pub fn prepare(evaluator: *Machine, _: [1]Value, _: void, length: usize) error{OutOfMemory}!Output {
            const allocator = evaluator.allocator();
            const capacity = std.math.ceilPowerOfTwo(usize, @max(8, length * 2)) catch return error.OutOfMemory;
            const slots = try allocator.alloc(usize, capacity);
            errdefer allocator.free(slots);
            @memset(slots, 0);
            return .{ .allocator = allocator, .slots = slots, .kept = try allocator.alloc(Element, length) };
        }

        pub fn chunk(_: void, operands: [1]Value, output: *Output, range: kernel_flat.Chunk, _: support.Context) MachineError!void {
            if (output.writer) |*writer| return writer.writeRange(range.start, output.kept[range.start..range.end]);
            for (heap.leafElements(kind, operands[0].list)[range.start..range.end]) |item| output.keep(item);
        }

        pub fn next(context: support.Context, output: *Output) MachineError!?usize {
            if (output.writer != null) return null;
            output.writer = try .init(context.allocator(), output.kept_count);
            return output.kept_count;
        }

        pub fn finish(output: *Output) Value {
            output.allocator.free(output.slots);
            output.allocator.free(output.kept);
            return output.writer.?.finish();
        }

        fn hash(item: Element) u64 {
            const bits: u64 = if (Element == f64)
                @bitCast(if (item == 0) 0.0 else item)
            else if (Element == i64)
                @bitCast(item)
            else
                item;
            return bits *% 0x9E37_79B9_7F4A_7C15;
        }
    };
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
        const work = evaluator.workBudget();
        while (!work.exhausted()) {
            if (self.materializer) |*materializer| {
                return switch (try materializer.borrowMut().advance(work)) {
                    .pending => .stepped,
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
                _ = work.spend();
                continue;
            }
            if (self.matcher == null) self.matcher = .init(try equal.MatchCursor.init(
                evaluator.allocator(),
                self.results.borrow()[self.candidate],
                list.atUnchecked(self.collection.borrow(), self.item_index),
            ));
            switch (try self.matcher.?.borrowMut().advance(work)) {
                .pending => _ = work.spend(),
                .complete => |matches| {
                    self.matcher.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.matcher = null;
                    if (matches) {
                        self.item_index += 1;
                        self.candidate = 0;
                    } else self.candidate += 1;
                    _ = work.spend();
                },
            }
        }
        return .stepped;
    }
};

fn groupPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    try evaluator.startDriver(GroupDriver{ .collection = .init(collection.take()) });
}

fn groupColumnsPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    try evaluator.startDriver(GroupDriver{ .collection = .init(collection.take()), .columns = true });
}

const GroupDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    columns: bool = false,
    row_count: usize = 0,
    key_rows: ?heap.Owned([]usize) = null,
    slots: ?heap.Owned([]usize) = null,
    hashes: ?heap.Owned([]u64) = null,
    hasher: ?heap.Owned(equal.HashCursor) = null,
    row_hash: u64 = 0,
    cell: usize = 0,
    key_builder: ?heap.Owned(heap.OwnedValueBuffer) = null,
    key_values: ?heap.Owned(heap.OwnedValueBuffer) = null,
    keys: ?heap.Owned([]Value) = null,
    assignments: ?heap.Owned([]usize) = null,
    frequencies: ?heap.Owned([]usize) = null,
    offsets: ?heap.Owned([]usize) = null,
    cursors: ?heap.Owned([]usize) = null,
    indices: ?heap.Owned([]i64) = null,
    phase: enum { validate, allocate, initialize, hash, scan, key, typed_assign, offsets, cursors, scatter, groups, dictionary } = .validate,
    /// A single typed leaf is grouped by its elements' match keys in one bulk
    /// pass, with no boxed reads, hash cursors, or per-cell matching.
    typed: bool = false,
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
        const count = self.row_count;
        self.key_rows = .init(try allocator.alloc(usize, count));
        const capacity = std.math.ceilPowerOfTwo(usize, std.math.add(usize, std.math.mul(usize, count, 2) catch return error.OutOfMemory, 1) catch return error.OutOfMemory) catch return error.OutOfMemory;
        self.slots = .init(try allocator.alloc(usize, capacity));
        self.hashes = .init(try allocator.alloc(u64, count));
        if (self.columns) self.key_values = .init(try .init(evaluator.releaseDomain(), count));
        self.keys = .init(try allocator.alloc(Value, count));
        self.assignments = .init(try allocator.alloc(usize, count));
        self.frequencies = .init(try allocator.alloc(usize, count));
        self.offsets = .init(try allocator.alloc(usize, count + 1));
        self.cursors = .init(try allocator.alloc(usize, count));
        self.indices = .init(try allocator.alloc(i64, count));
        self.group_values = .init(try .init(evaluator.releaseDomain(), count));
        self.offsets.?.borrow()[0] = 0;
        self.phase = .initialize;
    }

    fn cellCount(self: *const GroupDriver) usize {
        return if (self.columns) @intCast(self.collection.borrow().list.length()) else 1;
    }
    fn cellValue(self: *const GroupDriver, row: usize, column: usize) Value {
        const source = self.collection.borrow();
        return list.atUnchecked(if (self.columns) list.atUnchecked(source, column) else source, row);
    }
    /// One typed leaf element as the scalar value it stands for.
    fn leafValue(comptime kind: value.HeapKind, item: heap.LeafElement(kind)) Value {
        return switch (kind) {
            .leaf_u8, .leaf_i64 => .{ .int = item },
            .leaf_f64 => .{ .float = item },
            .leaf_char1, .leaf_char2, .leaf_char4 => .{ .char = item },
            .leaf_symbol => .{ .symbol = .{ .name = item } },
            .generic_spine, .dict, .task, .port, .address, .reserved_mask => unreachable,
        };
    }

    /// Assigns `rows` of a typed leaf to groups. The open-addressed `slots`
    /// hold group numbers plus one; a group's key is its first row's element.
    fn assignTyped(self: *GroupDriver, comptime kind: value.HeapKind, rows: usize, releases: *heap.ReleaseDomain) void {
        var reader = heap.LeafReader(kind).acquire(self.collection.borrow().list);
        defer reader.release(releases);
        const items = reader.slice();
        const slots = self.slots.?.borrow();
        const mask = slots.len - 1;
        const key_rows = self.key_rows.?.borrow();
        const assignments = self.assignments.?.borrow();
        const frequencies = self.frequencies.?.borrow();
        for (self.item_index..self.item_index + rows) |row| {
            const key = equal.LeafMatchKey.of(kind, items[row]);
            var slot: usize = @intCast(key.hash() >> 32 & mask);
            const group = while (slots[slot] != 0) : (slot = (slot + 1) & mask) {
                const existing = slots[slot] - 1;
                if (equal.LeafMatchKey.of(kind, items[key_rows[existing]]).eql(key)) break existing;
            } else fresh: {
                const fresh = self.key_count;
                self.keys.?.borrow()[fresh] = leafValue(kind, items[row]);
                key_rows[fresh] = row;
                frequencies[fresh] = 0;
                slots[slot] = fresh + 1;
                self.key_count += 1;
                break :fresh fresh;
            };
            assignments[row] = group;
            frequencies[group] += 1;
        }
        self.item_index += rows;
    }

    fn assigned(self: *GroupDriver, group: usize) void {
        self.assignments.?.borrow()[self.item_index] = group;
        self.frequencies.?.borrow()[group] += 1;
        self.item_index += 1;
        self.cell = 0;
        self.row_hash = 0;
        self.phase = .hash;
    }

    pub fn advance(evaluator: *Machine, self: *GroupDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .validate => {
                const source = self.collection.borrow();
                if (!self.columns) {
                    self.row_count = @intCast(source.list.length());
                    self.typed = source.list.kind() != .generic_spine;
                    self.phase = .allocate;
                    continue;
                }
                if (source.list.length() == 0) return evaluator.fail(.shape, "group-columns requires at least one column");
                if (self.index == source.list.length()) {
                    self.index = 0;
                    self.phase = .allocate;
                    continue;
                }
                const column = list.atUnchecked(source, self.index);
                if (column != .list) return evaluator.typeError("a list of columns");
                if (self.index == 0) self.row_count = @intCast(column.list.length());
                if (column.list.length() != self.row_count) return evaluator.fail(.shape, "group-columns requires equal-length columns");
                self.index += 1;
                _ = work.spend();
            },
            .allocate => try self.allocate(evaluator),
            .initialize => {
                const slots = self.slots.?.borrow();
                if (self.index == slots.len) {
                    self.index = 0;
                    self.phase = if (self.typed) .typed_assign else .hash;
                    continue;
                }
                const granted = work.take(slots.len - self.index);
                @memset(slots[self.index..][0..granted], 0);
                self.index += granted;
            },
            .typed_assign => {
                if (self.item_index == self.row_count) {
                    self.phase = .offsets;
                    self.index = 0;
                    continue;
                }
                const rows = work.take(self.row_count - self.item_index);
                switch (self.collection.borrow().list.kind()) {
                    inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => |kind| self.assignTyped(kind, rows, evaluator.releaseDomain()),
                    .generic_spine, .dict, .task, .port, .address, .reserved_mask => unreachable,
                }
            },
            .hash => {
                if (self.item_index == self.row_count) {
                    self.phase = .offsets;
                    self.index = 0;
                    continue;
                }
                if (self.cell == self.cellCount()) {
                    self.candidate = @intCast(self.row_hash & (self.slots.?.borrow().len - 1));
                    self.cell = 0;
                    self.phase = .scan;
                    continue;
                }
                const item = self.cellValue(self.item_index, self.cell);
                const hash_value = if (equal.scalarHash(item)) |h| scalar: {
                    _ = work.spend();
                    break :scalar h;
                } else blk: {
                    if (self.hasher == null) self.hasher = .init(try equal.HashCursor.init(evaluator.allocator(), item));
                    const progress = try self.hasher.?.borrowMut().advance(work);
                    switch (progress) {
                        .pending => continue,
                        .complete => |h| {
                            self.hasher.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                            self.hasher = null;
                            break :blk h;
                        },
                    }
                };
                self.row_hash = std.math.rotl(u64, self.row_hash, 13) ^ hash_value;
                self.cell += 1;
            },
            .scan => {
                const slots = self.slots.?.borrow();
                const encoded = slots[self.candidate];
                if (encoded == 0) {
                    self.phase = .key;
                    self.cell = 0;
                    continue;
                }
                const group = encoded - 1;
                if (self.hashes.?.borrow()[group] != self.row_hash) {
                    self.candidate = (self.candidate + 1) & (slots.len - 1);
                    _ = work.spend();
                    continue;
                }
                if (self.cell == self.cellCount()) {
                    self.assigned(group);
                    continue;
                }
                const left = self.cellValue(self.key_rows.?.borrow()[group], self.cell);
                const right = self.cellValue(self.item_index, self.cell);
                if (equal.matchWithoutStructure(left, right)) |matches| {
                    if (matches) self.cell += 1 else {
                        self.cell = 0;
                        self.candidate = (self.candidate + 1) & (slots.len - 1);
                    }
                    _ = work.spend();
                    continue;
                }
                if (self.matcher == null) self.matcher = .init(try equal.MatchCursor.init(evaluator.allocator(), left, right));
                const progress = try self.matcher.?.borrowMut().advance(work);
                switch (progress) {
                    .pending => {},
                    .complete => |matches| {
                        self.matcher.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.matcher = null;
                        if (matches) self.cell += 1 else {
                            self.cell = 0;
                            self.candidate = (self.candidate + 1) & (slots.len - 1);
                        }
                    },
                }
            },
            .key => {
                if (self.columns) {
                    if (self.key_builder == null) self.key_builder = .init(try .init(evaluator.releaseDomain(), self.cellCount()));
                    if (self.cell != self.cellCount()) {
                        self.key_builder.?.borrowMut().appendBorrowed(self.cellValue(self.item_index, self.cell));
                        self.cell += 1;
                        _ = work.spend();
                        continue;
                    }
                    const key = self.key_builder.?.borrowMut().takeList();
                    self.key_builder = null;
                    self.keys.?.borrow()[self.key_count] = key;
                    self.key_values.?.borrowMut().appendOwned(key);
                } else self.keys.?.borrow()[self.key_count] = self.cellValue(self.item_index, 0);
                self.key_rows.?.borrow()[self.key_count] = self.item_index;
                self.hashes.?.borrow()[self.key_count] = self.row_hash;
                self.frequencies.?.borrow()[self.key_count] = 0;
                self.slots.?.borrow()[self.candidate] = self.key_count + 1;
                self.key_count += 1;
                self.assigned(self.key_count - 1);
                _ = work.spend();
            },
            .offsets => {
                if (self.index == self.key_count) {
                    self.phase = .cursors;
                    self.index = 0;
                    continue;
                }
                const offsets = self.offsets.?.borrow();
                const frequencies = self.frequencies.?.borrow();
                const end = self.index + work.take(self.key_count - self.index);
                while (self.index != end) : (self.index += 1)
                    offsets[self.index + 1] = offsets[self.index] + frequencies[self.index];
            },
            .cursors => {
                if (self.index == self.key_count) {
                    self.phase = .scatter;
                    self.index = 0;
                    continue;
                }
                const granted = work.take(self.key_count - self.index);
                @memcpy(
                    self.cursors.?.borrow()[self.index..][0..granted],
                    self.offsets.?.borrow()[self.index..][0..granted],
                );
                self.index += granted;
            },
            .scatter => {
                if (self.index == self.assignments.?.borrow().len) {
                    self.phase = .groups;
                    self.index = 0;
                    continue;
                }
                const assignments = self.assignments.?.borrow();
                const indices = self.indices.?.borrow();
                const cursors = self.cursors.?.borrow();
                const end = self.index + work.take(assignments.len - self.index);
                while (self.index != end) : (self.index += 1) {
                    const group_index = assignments[self.index];
                    indices[cursors[group_index]] = @intCast(self.index);
                    cursors[group_index] += 1;
                }
            },
            .groups => {
                if (self.index == self.key_count) {
                    self.dict_materializer = .init(try dict.Materializer.initBorrowedSlices(
                        evaluator.allocator(),
                        self.keys.?.borrow()[0..self.key_count],
                        self.group_values.?.borrow().values(),
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
                const copied = work.take(end - start - self.group_fill);
                self.group_writer.?.borrowMut().writeRange(
                    self.group_fill,
                    self.indices.?.borrow()[start + self.group_fill .. start + self.group_fill + copied],
                );
                self.group_fill += copied;
                if (self.group_fill != end - start) return .stepped;
                const group = self.group_writer.?.borrowMut().finish();
                self.group_writer = null;
                self.group_fill = 0;
                self.group_values.?.borrowMut().appendOwned(group);
                self.index += 1;
                if (work.exhausted()) return .stepped;
            },
            .dictionary => switch (try self.dict_materializer.?.borrowMut().advance(work)) {
                .pending => return .stepped,
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
        return .stepped;
    }
};
