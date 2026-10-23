//! Sequence, search, and rectangular-shape kernels.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const support = @import("kernel_support.zig");
const kernel_flat = @import("kernel_flat.zig");
const poll = @import("poll.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

/// The sized-operation taxonomy lives in `kernel_support` so the registry in
/// `kernels.zig` classifies exactly the operations this installer publishes.
const Op = support.SequenceOp;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(Op)) |operation| {
        if (comptime definition(operation)) |word| try core.installBuiltin(word);
    }
}

fn definition(comptime operation: Op) ?env.BuiltinWord {
    return switch (operation) {
        .at => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "collection key -- value", .doc = "Select a list index or dictionary key, pervading over list indices." },
        .where => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "counts -- indices", .doc = "Expand integer counts into their replicated zero-based indices." },
        .first_where => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "counts -- index", .doc = "Return the first index with a positive count, or the count-list length when none exists; counts after the first hit are not inspected." },
        .in_word => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "value list -- bool", .doc = "Test whole-value membership, pervading over the sought value and never into the list." },
        .raze => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- list", .doc = "Flatten one level of a list." },
        .cat => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "left right -- list", .doc = "Concatenate two lists." },
        .take => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list count -- list", .doc = "Take a signed number of list elements, cycling when necessary." },
        .drop => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list count -- list", .doc = "Drop a signed number of elements from a list." },
        .range => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "bound -- list", .doc = "Return the integers from zero through one less than a nonnegative bound." },
        .shape => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- shape", .doc = "Return the dimensions of a rectangular list." },
        .len => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- count", .doc = "Return a list's top-level element count." },
        .flip => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list -- list", .doc = "Transpose a rectangular list." },
        .reshape => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list shape -- list", .doc = "Cycle list data into the requested rectangular shape." },
        .cut => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list starts -- pieces", .doc = "Split a list into pieces that begin at each nondecreasing start index and end at the next; elements before the first start are dropped." },
        .rotate => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "list count -- rotated", .doc = "Rotate a list left by a count, wrapping cyclically; a negative count rotates right and an empty list is returned unchanged." },
        .reverse, .first, .rest => null,
    };
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Machine) MachineError!void {
            return primitive(evaluator, operation);
        }
    }.run);
}

fn primitive(evaluator: *Machine, comptime operation: Op) MachineError!void {
    return switch (operation) {
        .at => atPrimitive(evaluator),
        .where => wherePrimitive(evaluator),
        .first_where => firstWherePrimitive(evaluator),
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
        .cut => cutPrimitive(evaluator),
        .rotate => rotatePrimitive(evaluator),
    };
}

fn atPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var index = try evaluator.popValue();
    defer index.deinit();
    var collection = try evaluator.popValue();
    defer collection.deinit();
    // A typed index vector over a typed source is one gather: the result's
    // representation is the source's, known before the first read.
    if (index.borrow() == .list and
        (index.borrow().list.kind() == .leaf_u8 or index.borrow().list.kind() == .leaf_i64))
    {
        if (try startTypedCopy(
            evaluator,
            &collection,
            null,
            &index,
            .gather,
            @intCast(index.borrow().list.length()),
        )) return;
        if (collection.borrow() == .list and index.borrow().list.length() != 0) {
            const count: usize = @intCast(index.borrow().list.length());
            const values = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), count);
            return evaluator.runDriver(FlatGatherDriver{
                .source = .init(collection.take()),
                .indices = .init(index.take()),
                .values = .init(values),
                .cursor = kernel_flat.FlatCursor.init(count),
            });
        }
    }
    // A scalar index into a list is the cursor's own leaf case, reached in one
    // step with no state to carry. `IndexCursor` allocates a frame stack and a
    // driver to run exactly the four lines below, so its checks are reproduced
    // here in full rather than approximated: same order, same error kinds,
    // same messages.
    if (collection.borrow() == .list and index.borrow() == .int) {
        if (index.borrow().int < 0) return evaluator.fail(.domain, "at index is negative");
        const position = std.math.cast(usize, index.borrow().int) orelse
            return evaluator.fail(.domain, "at index is out of bounds");
        if (position >= collection.borrow().list.length())
            return evaluator.fail(.domain, "at index is out of bounds");
        return evaluator.pushBorrowed(list.atUnchecked(collection.borrow(), position));
    }
    // A dict has one key to find and nothing to descend into, so it needs the
    // find cursor and not the index cursor's frame stack -- which is sized by
    // its widest frame and costs a chunk allocation per lookup to hold one
    // entry. `dict.FindCursor` allocates nothing for a key without structure,
    // and falls back to its own worklists for one that has some.
    if (collection.borrow() == .dict) {
        const find = dict.FindCursor.initHeader(
            evaluator.allocator(),
            collection.borrow().dict,
            index.borrow(),
        );
        return evaluator.runDriver(DictAtDriver{
            .collection = .init(collection.take()),
            .key = .init(index.take()),
            .cursor = .init(find),
        });
    }
    const cursor = try IndexCursor.init(
        evaluator.releaseDomain(),
        evaluator.allocator(),
        collection.borrow(),
        index.borrow(),
    );
    try evaluator.runDriver(IndexDriver{
        .collection = .init(collection.take()),
        .index = .init(index.take()),
        .cursor = .init(cursor),
    });
}

const IndexDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    index: heap.Owned(Value),
    cursor: heap.Owned(IndexCursor),
    pub fn advance(evaluator: *Machine, self: *IndexDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator, evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

/// Integer selectors address whole cells, even when the cells have structure.
/// Materialization retains the ordinary indexing path's narrowing semantics.
const FlatGatherDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    source: heap.Owned(Value),
    indices: heap.Owned(Value),
    values: heap.Owned(heap.OwnedValueBuffer),
    cursor: kernel_flat.FlatCursor,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *FlatGatherDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (try self.cursor.nextRange(.{ .evaluator = evaluator })) |range| {
            const source = self.source.borrow();
            for (range.start..range.end) |index| {
                const position = list.atUnchecked(self.indices.borrow(), index).int;
                if (position < 0) return evaluator.fail(.domain, "at index is negative");
                const offset = std.math.cast(usize, position) orelse
                    return evaluator.fail(.domain, "at index is out of bounds");
                if (offset >= source.list.length()) return evaluator.fail(.domain, "at index is out of bounds");
                self.values.borrowMut().appendBorrowed(list.atUnchecked(source, offset));
            }
            return .stepped;
        }
        if (!self.cursor.complete()) return .stepped;
        if (self.materializer == null)
            self.materializer = .init(.initOwned(evaluator.allocator(), self.values.borrowMut().take()));
        return switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

/// Finding one key in one dict: no descent, so no frame stack. The miss is the
/// same failure `IndexCursor` reports, because it is the only other caller of
/// this cursor for the same job.
const DictAtDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    pub const inline_driver = true;
    collection: heap.Owned(Value),
    key: heap.Owned(Value),
    cursor: heap.Owned(dict.FindCursor),
    pub fn advance(evaluator: *Machine, self: *DictAtDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |maybe_result| result: {
                const found = maybe_result orelse
                    return evaluator.fail(.domain, "at could not find the dict key");
                heap.retainValue(found);
                break :result .{ .output = found };
            },
        };
    }
};

const IndexProgress = poll.Progress(Value);
const IndexCursor = struct {
    const Node = struct { collection: Value, index: Value, depth: usize };
    const Build = struct {
        collection: Value,
        indices: Value,
        depth: usize,
        values: heap.OwnedValueBuffer,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?list.ValueMaterializer = null,
        result: ?Value = null,
    };
    const Frame = union(enum) { node: Node, build: Build };
    releases: *heap.ReleaseDomain,
    allocator: std.mem.Allocator,
    frames: @import("poll.zig").ChunkStack(Frame),
    last: ?Value = null,

    fn init(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        collection: Value,
        index: Value,
    ) error{OutOfMemory}!IndexCursor {
        var frames = @import("poll.zig").ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .node = .{ .collection = collection, .index = index, .depth = 0 } });
        return .{ .releases = releases, .allocator = allocator, .frames = frames };
    }
    pub fn deinit(self: *IndexCursor) void {
        if (self.last) |last| self.releases.releaseValue(last);
        while (self.frames.pop()) |frame_value| self.deinitFrame(frame_value);
        self.frames.deinit();
        self.* = undefined;
    }
    fn deinitFrame(self: *IndexCursor, frame_value: Frame) void {
        switch (frame_value) {
            .node => {},
            .build => |build_value| {
                var build = build_value;
                if (build.materializer) |*materializer| materializer.retire(self.releases);
                build.values.deinit();
                if (build.result) |result| self.releases.releaseValue(result);
            },
        }
    }
    fn delegates(frame: *const Frame) bool {
        return switch (frame.*) {
            .build => |*build| build.result == null and !build.waiting and build.index == build.values.capacity(),
            .node => false,
        };
    }
    pub fn advance(self: *IndexCursor, evaluator: *Machine, work: *poll.WorkBudget) MachineError!IndexProgress {
        while (true) {
            // A frame handing work to a nested cursor is charged by that
            // cursor; spending first would starve it at a one-unit grain.
            if (self.frames.topPtr()) |top| {
                if (!delegates(top) and !work.spend()) return .pending;
            }

            var frame = self.frames.pop() orelse {
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            errdefer self.deinitFrame(frame);
            switch (frame) {
                .node => |node| {
                    if (node.depth >= support.max_depth and node.index == .list)
                        return evaluator.fail(.domain, "index nesting exceeds 256 levels");
                    // A dict never arrives here: `at` answers a dict itself,
                    // and a nested node inherits its parent's collection, so
                    // the only collection this cursor ever descends is a list.
                    if (node.collection != .list) return evaluator.typeError("a list or dict");
                    {
                        if (node.index == .list) {
                            var values = try heap.OwnedValueBuffer.init(
                                self.releases,
                                @intCast(node.index.list.length()),
                            );
                            errdefer values.deinit();
                            try self.frames.reserve(1);
                            self.frames.pushReserved(.{ .build = .{
                                .collection = node.collection,
                                .indices = node.index,
                                .depth = node.depth,
                                .values = values.take(),
                            } });
                        } else {
                            if (node.index != .int) return evaluator.typeError("an integer index");
                            if (node.index.int < 0) return evaluator.fail(.domain, "at index is negative");
                            const position = std.math.cast(usize, node.index.int) orelse
                                return evaluator.fail(.domain, "at index is out of bounds");
                            if (position >= node.collection.list.length())
                                return evaluator.fail(.domain, "at index is out of bounds");
                            const result = list.atUnchecked(node.collection, position);
                            heap.retainValue(result);
                            self.last = result;
                        }
                    }
                },
                .build => |*build| {
                    if (build.result) |result| {
                        build.values.deinit();
                        build.result = null;
                        self.last = result;
                        continue;
                    }
                    if (build.waiting) {
                        build.values.appendOwned(self.last.?);
                        self.last = null;
                        build.index += 1;
                        build.waiting = false;
                    }
                    if (build.index != build.values.capacity()) {
                        const index = build.index;
                        build.waiting = true;
                        try self.frames.reserve(2);
                        self.frames.pushReserved(.{ .build = build.* });
                        self.frames.pushReserved(.{ .node = .{
                            .collection = build.collection,
                            .index = list.atUnchecked(build.indices, index),
                            .depth = build.depth + 1,
                        } });
                        continue;
                    }
                    if (build.materializer == null)
                        build.materializer = .init(self.allocator, build.values.values());
                    try self.frames.reserve(1);
                    switch (try build.materializer.?.advance(work)) {
                        .pending => {
                            self.frames.pushReserved(.{ .build = build.* });
                            return .pending;
                        },
                        .complete => |result| {
                            build.result = result;
                            self.frames.pushReserved(.{ .build = build.* });
                        },
                    }
                },
            }
        }
        return .pending;
    }
};

fn wherePrimitive(evaluator: *Machine) MachineError!void {
    var counts = try evaluator.popValue();
    defer counts.deinit();
    if (counts.borrow() != .list) return evaluator.typeError("a non-negative integer count list");
    // A typed count list is pinned once for the driver's whole life, which is
    // what lets the counting pass read a slice instead of one boxed cell at a
    // time; a boxed list keeps the bounded per-element read.
    const reader: ?heap.LeafReader(.leaf_i64) = if (counts.borrow().list.kind() == .leaf_i64)
        heap.LeafReader(.leaf_i64).acquire(counts.borrow().list)
    else
        null;
    try evaluator.runDriver(WhereDriver{
        .counts = .init(counts.take()),
        .reader = if (reader) |acquired| .init(acquired) else null,
    });
}

/// Counts, then fills. The result is an exact-size index vector whose element
/// type is known before the first store, so the fill writes `leaf_i64` storage
/// directly.
///
/// A typed count list is read through a pinned typed slice and validated a
/// block at a time; only a block that fails is rescanned element by element, to
/// report the first failing position. A boxed one keeps the bounded
/// per-element read, which is its registry classification. Both share one
/// fill loop, and both charge the budget once per granted range rather than
/// once per element.
const WhereDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    counts: heap.Owned(Value),
    phase: enum { count, fill, materialize } = .count,
    index: usize = 0,
    total: usize = 0,
    writer: ?heap.Owned(heap.LeafWriter(.leaf_i64)) = null,
    reader: ?heap.Owned(heap.LeafReader(.leaf_i64)) = null,
    destination: usize = 0,
    /// What remains of the run at `index` when a step's budget ran out inside it.
    repetition: usize = 0,

    /// Counts already validated by the counting pass, read without boxing.
    const TypedCounts = struct {
        items: []const i64,
        fn at(self: TypedCounts, index: usize) usize {
            return @intCast(self.items[index]);
        }
    };
    const BoxedCounts = struct {
        items: Value,
        fn at(self: BoxedCounts, index: usize) usize {
            return @intCast(list.atUnchecked(self.items, index).int);
        }
    };

    /// The sum of one block of typed counts, or null when the block holds a
    /// count that is negative or too large to sum without a checked add. Every
    /// count below 2^55 keeps a block's sum below 2^63, so one `or` decides both.
    fn blockSum(counts: []const i64) ?usize {
        std.debug.assert(counts.len <= kernel_flat.block_size);
        var bits: i64 = 0;
        var sum: i64 = 0;
        for (counts) |item| {
            bits |= item;
            sum +%= item;
        }
        if (bits >> 55 != 0) return null;
        return std.math.cast(usize, sum);
    }

    /// Validates and adds the count at `index`: the exact per-element check,
    /// which reports the first failing position.
    fn countOne(self: *WhereDriver, evaluator: *Machine, item: Value) MachineError!void {
        if (item != .int) return evaluator.failAtIndex(
            .type,
            "where expected integer counts",
            self.index,
        );
        if (item.int < 0) return evaluator.failAtIndex(
            .domain,
            "where counts must be non-negative",
            self.index,
        );
        const repetitions = std.math.cast(usize, item.int) orelse
            return evaluator.failAtIndex(
                .overflow,
                "where count exceeds addressable size",
                self.index,
            );
        self.total = std.math.add(usize, self.total, repetitions) catch
            return evaluator.fail(.overflow, "where result is too large");
        self.index += 1;
    }

    /// Counts one granted range of a typed list, a block at a time.
    fn countTyped(self: *WhereDriver, evaluator: *Machine, counts: []const i64) MachineError!void {
        var offset: usize = 0;
        while (offset != counts.len) {
            const block = counts[offset..][0..@min(kernel_flat.block_size, counts.len - offset)];
            offset += block.len;
            if (blockSum(block)) |sum| {
                if (std.math.add(usize, self.total, sum)) |total| {
                    self.total = total;
                    self.index += block.len;
                    continue;
                } else |_| {}
            }
            for (block) |item| try self.countOne(evaluator, .{ .int = item });
        }
    }

    /// Writes as much of the result as `work` pays for: one unit per count
    /// read, or per element written when a count is above one. A count of zero
    /// or one stores its index unconditionally and advances by the count, so a
    /// mask fills without a branch on its contents; the store a zero leaves
    /// behind lies inside the result and is overwritten by the next index.
    fn fill(self: *WhereDriver, work: *poll.WorkBudget, counts: anytype) void {
        const out = self.writer.?.borrowMut().unpublishedRange(
            self.destination,
            self.total - self.destination,
        );
        const limit = work.remaining;
        var spent: usize = 0;
        var written: usize = 0;
        var index = self.index;
        if (self.repetition != 0) {
            const run = @min(self.repetition, limit);
            @memset(out[0..run], @intCast(index));
            written = run;
            spent = run;
            self.repetition -= run;
            if (self.repetition == 0) index += 1;
        }
        while (self.repetition == 0 and written != out.len and spent != limit) : (index += 1) {
            const repetitions = counts.at(index);
            out[written] = @intCast(index);
            if (repetitions <= 1) {
                written += repetitions;
                spent += 1;
                continue;
            }
            const run = @min(repetitions, limit - spent);
            @memset(out[written..][0..run], @intCast(index));
            written += run;
            spent += run;
            if (run != repetitions) {
                self.repetition = repetitions - run;
                break;
            }
        }
        _ = work.take(spent);
        self.index = index;
        self.destination += written;
    }

    pub fn advance(evaluator: *Machine, self: *WhereDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.counts.borrow().list.length());
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .count => {
                if (self.index == count) {
                    // Every index the fill stores is below `count`.
                    if (count != 0 and std.math.cast(i64, count - 1) == null)
                        return evaluator.fail(.overflow, "where index exceeds integer range");
                    self.writer = .init(try heap.LeafWriter(.leaf_i64).init(
                        evaluator.allocator(),
                        self.total,
                    ));
                    self.index = 0;
                    self.phase = .fill;
                    continue;
                }
                if (self.reader) |*pinned| {
                    const granted = work.take(count - self.index);
                    try self.countTyped(evaluator, pinned.borrow().slice()[self.index..][0..granted]);
                } else {
                    try self.countOne(evaluator, list.atUnchecked(self.counts.borrow(), self.index));
                    _ = work.spend();
                }
            },
            .fill => {
                // Counts after the last nonzero one contribute nothing.
                if (self.destination == self.total) {
                    self.phase = .materialize;
                    continue;
                }
                if (self.reader) |*pinned|
                    self.fill(work, TypedCounts{ .items = pinned.borrow().slice() })
                else
                    self.fill(work, BoxedCounts{ .items = self.counts.borrow() });
            },
            .materialize => {
                if (self.reader) |*pinned| pinned.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.reader = null;
                return .{ .output = self.writer.?.borrowMut().finish() };
            },
        };
        return .stepped;
    }
};

fn firstWherePrimitive(evaluator: *Machine) MachineError!void {
    var counts = try evaluator.popValue();
    defer counts.deinit();
    if (counts.borrow() != .list) return evaluator.typeError("a non-negative integer count list");
    const count: usize = @intCast(counts.borrow().list.length());
    const kind = counts.borrow().list.kind();
    inline for ([_]value.HeapKind{ .leaf_u8, .leaf_i64 }) |candidate| {
        if (kind == candidate) {
            const Driver = TypedFirstWhereDriver(candidate);
            return evaluator.runDriver(Driver{
                .counts = .init(heap.LeafReader(candidate).acquire(counts.borrow().list)),
                .cursor = .init(count),
                .count = count,
            });
        }
    }
    try evaluator.runDriver(FirstWhereDriver{
        .counts = .init(counts.take()),
    });
}

/// The first index whose count is positive, or the input length when none is.
/// This is a search rather than a validating transform: once a positive count
/// is found, the unobserved suffix cannot affect the result and is not read.
fn TypedFirstWhereDriver(comptime kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;
        pub const inline_driver = true;

        counts: heap.Owned(heap.LeafReader(kind)),
        cursor: kernel_flat.FlatCursor,
        count: usize,

        fn finish(self: *Self, evaluator: *Machine, index: usize) machine.WorkProgress {
            self.counts.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = .{ .int = @intCast(index) } };
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            if (try self.cursor.nextRange(context)) |range| {
                const items = self.counts.borrow().slice();
                for (items[range.start..range.end], range.start..) |item, index| {
                    if (kind == .leaf_i64 and item < 0) return evaluator.failAtIndex(
                        .domain,
                        "first-where counts must be non-negative",
                        index,
                    );
                    if (item != 0) return self.finish(evaluator, index);
                }
            }
            if (!self.cursor.complete()) return .stepped;
            return self.finish(evaluator, self.count);
        }
    };
}

const FirstWhereDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    pub const inline_driver = true;

    counts: heap.Owned(Value),
    index: usize = 0,

    fn finish(self: *FirstWhereDriver, evaluator: *Machine, index: usize) machine.WorkProgress {
        self.counts.deinit(evaluator.releaseDomain(), evaluator.allocator());
        return .{ .output = .{ .int = @intCast(index) } };
    }

    pub fn advance(evaluator: *Machine, self: *FirstWhereDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.counts.borrow().list.length());
        const work = evaluator.workBudget();
        while (self.index != count and work.spend()) {
            const item = list.atUnchecked(self.counts.borrow(), self.index);
            if (item != .int) return evaluator.failAtIndex(
                .type,
                "first-where expected integer counts",
                self.index,
            );
            if (item.int < 0) return evaluator.failAtIndex(
                .domain,
                "first-where counts must be non-negative",
                self.index,
            );
            if (item.int != 0) return self.finish(evaluator, self.index);
            self.index += 1;
        }
        if (self.index != count) return .stepped;
        return self.finish(evaluator, count);
    }
};

fn inPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var collection = try evaluator.popValue();
    defer collection.deinit();
    var needle = try evaluator.popValue();
    defer needle.deinit();
    if (collection.borrow() != .list) return evaluator.typeError("a list haystack");
    if (try startTypedMembership(evaluator, needle.borrow(), collection.borrow())) return;
    const cursor = try MembershipCursor.init(
        evaluator.releaseDomain(),
        evaluator.allocator(),
        needle.borrow(),
        collection.borrow(),
    );
    try evaluator.runDriver(MembershipDriver{
        .needle = .init(needle.take()),
        .collection = .init(collection.take()),
        .cursor = .init(cursor),
    });
}

fn membershipKindsCompatible(comptime needle_kind: value.HeapKind, comptime haystack_kind: value.HeapKind) bool {
    const needle_numeric = needle_kind == .leaf_u8 or needle_kind == .leaf_i64 or needle_kind == .leaf_f64;
    const haystack_numeric = haystack_kind == .leaf_u8 or haystack_kind == .leaf_i64 or haystack_kind == .leaf_f64;
    const needle_char = needle_kind == .leaf_char1 or needle_kind == .leaf_char2 or needle_kind == .leaf_char4;
    const haystack_char = haystack_kind == .leaf_char1 or haystack_kind == .leaf_char2 or haystack_kind == .leaf_char4;
    return (needle_numeric and haystack_numeric) or
        (needle_char and haystack_char) or
        (needle_kind == .leaf_symbol and haystack_kind == .leaf_symbol);
}

fn typedElementsMatch(
    comptime needle_kind: value.HeapKind,
    comptime haystack_kind: value.HeapKind,
    needle: heap.LeafElement(needle_kind),
    candidate: heap.LeafElement(haystack_kind),
) bool {
    if (needle_kind == .leaf_u8 and haystack_kind == .leaf_u8) return needle == candidate;
    if (needle_kind == .leaf_u8 and haystack_kind == .leaf_i64) return @as(i64, needle) == candidate;
    if (needle_kind == .leaf_i64 and haystack_kind == .leaf_u8) return needle == @as(i64, candidate);
    if (needle_kind == .leaf_u8 and haystack_kind == .leaf_f64)
        return equal.intFloatEqual(needle, candidate);
    if (needle_kind == .leaf_f64 and haystack_kind == .leaf_u8)
        return equal.intFloatEqual(candidate, needle);
    if (needle_kind == .leaf_i64 and haystack_kind == .leaf_i64) return needle == candidate;
    if (needle_kind == .leaf_i64 and haystack_kind == .leaf_f64)
        return equal.intFloatEqual(needle, candidate);
    if (needle_kind == .leaf_f64 and haystack_kind == .leaf_i64)
        return equal.intFloatEqual(candidate, needle);
    if (needle_kind == .leaf_f64 and haystack_kind == .leaf_f64) return needle == candidate;

    const needle_char = needle_kind == .leaf_char1 or needle_kind == .leaf_char2 or needle_kind == .leaf_char4;
    const haystack_char = haystack_kind == .leaf_char1 or haystack_kind == .leaf_char2 or haystack_kind == .leaf_char4;
    if (needle_char and haystack_char) return @as(u32, needle) == @as(u32, candidate);
    if (needle_kind == .leaf_symbol and haystack_kind == .leaf_symbol) return needle == candidate;
    return false;
}

fn scalarMatchesElement(
    comptime haystack_kind: value.HeapKind,
    needle: Value,
    candidate: heap.LeafElement(haystack_kind),
) bool {
    return switch (haystack_kind) {
        .leaf_u8 => switch (needle) {
            .int => |integer| integer == candidate,
            .float => |floating| equal.intFloatEqual(candidate, floating),
            else => false,
        },
        .leaf_i64 => switch (needle) {
            .int => |integer| integer == candidate,
            .float => |floating| equal.intFloatEqual(candidate, floating),
            else => false,
        },
        .leaf_f64 => switch (needle) {
            .int => |integer| equal.intFloatEqual(integer, candidate),
            .float => |floating| floating == candidate,
            else => false,
        },
        .leaf_char1, .leaf_char2, .leaf_char4 => switch (needle) {
            .char => |codepoint| codepoint == @as(u32, candidate),
            else => false,
        },
        .leaf_symbol => switch (needle) {
            .symbol => |symbol| symbol == candidate,
            else => false,
        },
        .generic_spine, .dict, .task, .module, .port, .reserved_mask => unreachable,
    };
}

fn scalarCanMatchKind(needle: Value, haystack_kind: value.HeapKind) bool {
    return switch (needle) {
        .int, .float => haystack_kind == .leaf_u8 or haystack_kind == .leaf_i64 or haystack_kind == .leaf_f64,
        .char => haystack_kind == .leaf_char1 or haystack_kind == .leaf_char2 or haystack_kind == .leaf_char4,
        .symbol => haystack_kind == .leaf_symbol,
        .word, .list, .dict, .task, .module, .port => false,
    };
}

fn ScalarMembershipDriver(comptime haystack_kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;
        /// Scanning a leaf haystack is bounded work whatever its length, so
        /// this driver earns its existence; it did not earn an allocation to
        /// come into being, and for a short haystack that was the whole cost.
        pub const inline_driver = true;

        haystack: heap.Owned(heap.LeafReader(haystack_kind)),
        needle: Value,
        cursor: kernel_flat.FlatCursor,

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            if (try self.cursor.nextRange(context)) |range| {
                const candidates = self.haystack.borrow().slice();
                for (candidates[range.start..range.end]) |candidate| {
                    if (scalarMatchesElement(haystack_kind, self.needle, candidate)) {
                        self.haystack.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        return .{ .output = .{ .int = 1 } };
                    }
                }
            }
            if (!self.cursor.complete()) return .stepped;
            self.haystack.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = .{ .int = 0 } };
        }
    };
}

/// The distinct needles of a membership test, open-addressed, each marked once
/// the haystack is seen to hold it.
const NeedleTable = struct {
    const Slot = struct { key: equal.LeafMatchKey, found: bool };
    slots: []Slot,
    unfound: usize = 0,

    fn init(allocator: std.mem.Allocator, needles: usize) error{OutOfMemory}!NeedleTable {
        const capacity = std.math.ceilPowerOfTwo(usize, @max(8, needles * 2)) catch return error.OutOfMemory;
        const slots = try allocator.alloc(Slot, capacity);
        for (slots) |*slot| slot.* = .{ .key = .{ .class = .empty, .bits = 0 }, .found = false };
        return .{ .slots = slots };
    }

    pub fn retire(self: *NeedleTable, _: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }

    /// The slot holding `key`, or the empty slot where it belongs.
    fn find(self: *const NeedleTable, key: equal.LeafMatchKey) *Slot {
        const mask = self.slots.len - 1;
        var index: usize = @intCast(key.hash() >> 32 & mask);
        while (self.slots[index].key.class != .empty and !self.slots[index].key.eql(key)) index = (index + 1) & mask;
        return &self.slots[index];
    }

    fn insert(self: *NeedleTable, key: equal.LeafMatchKey) void {
        const slot = self.find(key);
        if (slot.key.class != .empty) return;
        slot.key = key;
        self.unfound += 1;
    }

    fn mark(self: *NeedleTable, key: equal.LeafMatchKey) void {
        const slot = self.find(key);
        if (slot.key.class == .empty or slot.found) return;
        slot.found = true;
        self.unfound -= 1;
    }
};

/// Membership of every needle of a flat leaf in a flat haystack, in O(needles
/// + haystack): the needles' distinct keys are tabled, one pass over the
/// haystack marks the keys it holds and stops once every key is marked, and
/// the mask is written from the table. A disjoint leaf domain or an empty
/// haystack is a fill of zeros.
fn LeafMembershipDriver(
    comptime needle_kind: value.HeapKind,
    comptime haystack_kind: value.HeapKind,
) type {
    const compatible = membershipKindsCompatible(needle_kind, haystack_kind);
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        needles: heap.Owned(heap.LeafReader(needle_kind)),
        haystack: heap.Owned(heap.LeafReader(haystack_kind)),
        writer: heap.Owned(heap.LeafWriter(.leaf_i64)),
        table: heap.Owned(NeedleTable),
        phase: enum { table, scan, write } = .table,
        position: usize = 0,

        fn finish(self: *Self, evaluator: *Machine) machine.WorkProgress {
            self.needles.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.haystack.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.table.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = self.writer.borrowMut().finish() };
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            try evaluator.pollKernel();
            const work = evaluator.workBudget();
            const needles = self.needles.borrow().slice();
            const candidates = self.haystack.borrow().slice();
            const table = self.table.borrowMut();
            while (!work.exhausted()) switch (self.phase) {
                .table => {
                    if (!compatible or candidates.len == 0) {
                        self.phase = .write;
                        continue;
                    }
                    const granted = work.take(needles.len - self.position);
                    for (needles[self.position..][0..granted]) |needle| table.insert(equal.LeafMatchKey.of(needle_kind, needle));
                    self.position += granted;
                    if (self.position != needles.len) continue;
                    self.position = 0;
                    self.phase = .scan;
                },
                .scan => {
                    const granted = work.take(candidates.len - self.position);
                    for (candidates[self.position..][0..granted]) |candidate| {
                        table.mark(equal.LeafMatchKey.of(haystack_kind, candidate));
                        if (table.unfound == 0) break;
                    }
                    self.position = if (table.unfound == 0) candidates.len else self.position + granted;
                    if (self.position != candidates.len) continue;
                    self.position = 0;
                    self.phase = .write;
                },
                .write => {
                    const granted = work.take(needles.len - self.position);
                    const out = self.writer.borrowMut().unpublishedRange(self.position, granted);
                    if (!compatible or candidates.len == 0) {
                        @memset(out, 0);
                    } else for (out, needles[self.position..][0..granted]) |*slot, needle| {
                        slot.* = @intFromBool(table.find(equal.LeafMatchKey.of(needle_kind, needle)).found);
                    }
                    self.position += granted;
                    if (self.position == needles.len) return self.finish(evaluator);
                },
            };
            return .stepped;
        }
    };
}

/// Dispatch membership once on the two leaf representations. A scalar needle
/// is a stride-zero register value; a flat needle list writes its final i64
/// mask directly. Generic-spine needles retain the recursive structural cursor
/// because their result shape is itself recursive.
fn startTypedMembership(evaluator: *Machine, needle: Value, haystack: Value) MachineError!bool {
    const haystack_kind = haystack.list.kind();
    if (haystack_kind == .generic_spine) return false;

    if (needle != .list) {
        if (!scalarCanMatchKind(needle, haystack_kind)) {
            try evaluator.pushOwned(.{ .int = 0 });
            return true;
        }
        inline for (leaf_kinds) |candidate_haystack| {
            if (haystack_kind == candidate_haystack) {
                const Driver = ScalarMembershipDriver(candidate_haystack);
                try evaluator.runDriver(Driver{
                    .haystack = .init(heap.LeafReader(candidate_haystack).acquire(haystack.list)),
                    .needle = needle,
                    .cursor = kernel_flat.FlatCursor.init(@intCast(haystack.list.length())),
                });
                return true;
            }
        }
        unreachable;
    }

    const needle_kind = needle.list.kind();
    if (needle_kind == .generic_spine or needle.list.length() == 0) return false;
    inline for (leaf_kinds) |candidate_needle| {
        if (needle_kind == candidate_needle) inline for (leaf_kinds) |candidate_haystack| {
            if (haystack_kind == candidate_haystack) {
                const Driver = LeafMembershipDriver(candidate_needle, candidate_haystack);
                var writer = try heap.LeafWriter(.leaf_i64).init(
                    evaluator.allocator(),
                    @intCast(needle.list.length()),
                );
                var held_locally = true;
                errdefer if (held_locally) writer.retirePartial(evaluator.releaseDomain());
                var table = try NeedleTable.init(evaluator.allocator(), @intCast(needle.list.length()));
                errdefer if (held_locally) table.retire(evaluator.releaseDomain(), evaluator.allocator());
                const driver = Driver{
                    .needles = .init(heap.LeafReader(candidate_needle).acquire(needle.list)),
                    .haystack = .init(heap.LeafReader(candidate_haystack).acquire(haystack.list)),
                    .writer = .init(writer),
                    .table = .init(table),
                };
                held_locally = false;
                try evaluator.runDriver(driver);
                return true;
            }
        };
    }
    unreachable;
}

const MembershipDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// Same reasoning as the typed scan: the walk is bounded work, its
    /// creation need not allocate. This path also carries a cursor that
    /// allocates its own frame stack, so membership over a generic spine
    /// still costs one; the budget records that rather than claiming it away.
    pub const inline_driver = true;
    needle: heap.Owned(Value),
    collection: heap.Owned(Value),
    cursor: heap.Owned(MembershipCursor),
    pub fn advance(evaluator: *Machine, self: *MembershipDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator, evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

const MembershipCursor = struct {
    const Node = struct { needle: Value, depth: usize };
    const Search = struct {
        needle: Value,
        candidate: usize = 0,
        match: ?equal.MatchCursor = null,
    };
    const Build = struct {
        needle: Value,
        depth: usize,
        values: heap.OwnedValueBuffer,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?list.ValueMaterializer = null,
        result: ?Value = null,
    };
    const Frame = union(enum) { node: Node, search: Search, build: Build };
    releases: *heap.ReleaseDomain,
    allocator: std.mem.Allocator,
    collection: Value,
    frames: @import("poll.zig").ChunkStack(Frame),
    last: ?Value = null,

    fn init(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        needle: Value,
        collection: Value,
    ) error{OutOfMemory}!MembershipCursor {
        var frames = @import("poll.zig").ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .node = .{ .needle = needle, .depth = 0 } });
        return .{ .releases = releases, .allocator = allocator, .collection = collection, .frames = frames };
    }
    pub fn deinit(self: *MembershipCursor) void {
        if (self.last) |last| self.releases.releaseValue(last);
        while (self.frames.pop()) |frame_value| self.deinitFrame(frame_value);
        self.frames.deinit();
        self.* = undefined;
    }
    fn deinitFrame(self: *MembershipCursor, frame_value: Frame) void {
        switch (frame_value) {
            .node => {},
            .search => |search_value| if (search_value.match) |cursor_value| {
                var cursor = cursor_value;
                cursor.deinit();
            },
            .build => |build_value| {
                var build = build_value;
                if (build.materializer) |*materializer| materializer.retire(self.releases);
                build.values.deinit();
                if (build.result) |result| self.releases.releaseValue(result);
            },
        }
    }
    fn delegates(frame: *const Frame) bool {
        return switch (frame.*) {
            .build => |*build| build.result == null and !build.waiting and build.index == build.values.capacity(),
            .search => |*search| search.match != null,
            .node => false,
        };
    }
    pub fn advance(self: *MembershipCursor, evaluator: *Machine, work: *poll.WorkBudget) MachineError!IndexProgress {
        while (true) {
            // A frame handing work to a nested cursor is charged by that
            // cursor; spending first would starve it at a one-unit grain.
            if (self.frames.topPtr()) |top| {
                if (!delegates(top) and !work.spend()) return .pending;
            }

            var frame = self.frames.pop() orelse {
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            errdefer self.deinitFrame(frame);
            switch (frame) {
                .node => |node| {
                    if (node.depth >= support.max_depth and node.needle == .list)
                        return evaluator.fail(.domain, "membership nesting exceeds 256 levels");
                    if (node.needle != .list) {
                        try self.frames.push(.{ .search = .{ .needle = node.needle } });
                    } else {
                        var values = try heap.OwnedValueBuffer.init(
                            self.releases,
                            @intCast(node.needle.list.length()),
                        );
                        errdefer values.deinit();
                        try self.frames.reserve(1);
                        self.frames.pushReserved(.{ .build = .{
                            .needle = node.needle,
                            .depth = node.depth,
                            .values = values.take(),
                        } });
                    }
                },
                .search => |*search| {
                    const count: usize = @intCast(self.collection.list.length());
                    if (search.candidate == count) {
                        self.last = .{ .int = 0 };
                        continue;
                    }
                    // A candidate with no structure against a needle with none
                    // is one comparison. Only a structured pair needs the
                    // nested comparison cursor and its shared budget.
                    const candidate_value = list.atUnchecked(self.collection, search.candidate);
                    if (equal.matchWithoutStructure(search.needle, candidate_value)) |matches| {
                        if (matches) {
                            self.last = .{ .int = 1 };
                            continue;
                        }
                        search.candidate += 1;
                        try self.frames.push(.{ .search = search.* });
                        continue;
                    }
                    if (search.match == null) search.match = try .init(
                        self.allocator,
                        search.needle,
                        candidate_value,
                    );
                    switch (try search.match.?.advance(work)) {
                        .pending => {
                            try self.frames.push(.{ .search = search.* });
                            return .pending;
                        },
                        .complete => |matches| {
                            search.match.?.deinit();
                            search.match = null;
                            if (matches) {
                                self.last = .{ .int = 1 };
                            } else {
                                search.candidate += 1;
                                try self.frames.push(.{ .search = search.* });
                            }
                            continue;
                        },
                    }
                },
                .build => |*build| {
                    if (build.result) |result| {
                        build.values.deinit();
                        build.result = null;
                        self.last = result;
                        continue;
                    }
                    if (build.waiting) {
                        build.values.appendOwned(self.last.?);
                        self.last = null;
                        build.index += 1;
                        build.waiting = false;
                    }
                    if (build.index != build.values.capacity()) {
                        const index = build.index;
                        build.waiting = true;
                        try self.frames.reserve(2);
                        self.frames.pushReserved(.{ .build = build.* });
                        self.frames.pushReserved(.{ .node = .{
                            .needle = list.atUnchecked(build.needle, index),
                            .depth = build.depth + 1,
                        } });
                        continue;
                    }
                    if (build.materializer == null)
                        build.materializer = .init(self.allocator, build.values.values());
                    try self.frames.reserve(1);
                    if (work.exhausted()) {
                        self.frames.pushReserved(.{ .build = build.* });
                        return .pending;
                    }
                    switch (try build.materializer.?.advance(work)) {
                        .pending => {
                            self.frames.pushReserved(.{ .build = build.* });
                            return .pending;
                        },
                        .complete => |result| {
                            build.result = result;
                            self.frames.pushReserved(.{ .build = build.* });
                            continue;
                        },
                    }
                },
            }
        }
        return .pending;
    }
};

fn razePrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    try evaluator.runDriver(RazeDriver{ .collection = .init(collection.take()) });
}

/// The element class a raze's typed result is chosen from.
const RazeClass = enum { none, ints, floats, chars, symbols, boxed };

fn razeClass(kind: value.HeapKind) RazeClass {
    return switch (kind) {
        .leaf_u8, .leaf_i64 => .ints,
        .leaf_f64 => .floats,
        .leaf_char1, .leaf_char2, .leaf_char4 => .chars,
        .leaf_symbol => .symbols,
        .generic_spine, .dict, .task, .module, .port, .reserved_mask => .boxed,
    };
}

/// The typed result buffer, held so a cancelled raze retires it.
const RazeOutput = struct {
    builder: heap.AnyListBuilder,
    pub fn retire(self: *RazeOutput, releases: *heap.ReleaseDomain) void {
        self.builder.retirePartial(releases);
    }
};

/// Flattens one level. When every non-empty child is a typed leaf of one
/// element class, each child's slice is copied, widened where narrower,
/// straight into a typed result as wide as the widest child. Otherwise the
/// children are read into boxed values and the result is profiled.
const RazeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    phase: enum { count, fill, typed_fill, materialize } = .count,
    index: usize = 0,
    child_index: usize = 0,
    total: usize = 0,
    class: RazeClass = .none,
    widest: value.HeapKind = .leaf_u8,
    values: ?heap.Owned([]Value) = null,
    output: ?heap.Owned(RazeOutput) = null,
    destination: usize = 0,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    fn classify(self: *RazeDriver, item: Value) void {
        if (item != .list) {
            self.class = .boxed;
            return;
        }
        if (item.list.length() == 0 or self.class == .boxed) return;
        const kind = item.list.kind();
        const class = razeClass(kind);
        if (self.class == .none) {
            self.class = class;
            self.widest = kind;
        } else if (self.class != class) {
            self.class = .boxed;
        } else if (elementBits(kind) > elementBits(self.widest)) {
            self.widest = kind;
        }
    }

    fn elementBits(kind: value.HeapKind) usize {
        return switch (kind) {
            inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => |leaf| @bitSizeOf(heap.LeafElement(leaf)),
            .generic_spine, .dict, .task, .module, .port, .reserved_mask => unreachable,
        };
    }

    /// Whether every `Source` element coerces to `Out` unchanged. The class
    /// check already keeps floats, symbols, and codepoints apart at run time;
    /// this only decides which pairs need code.
    fn widens(comptime Source: type, comptime Out: type) bool {
        if (Source == Out) return true;
        const from = @typeInfo(Source);
        const to = @typeInfo(Out);
        if (from != .int or to != .int) return false;
        return to.int.bits > from.int.bits and
            (to.int.signedness == .signed or from.int.signedness == .unsigned);
    }

    /// Copies `out.len` elements of `child`, starting at `from`, into `out`.
    fn copyChild(comptime Out: type, out: []Out, child: *heap.ListHandle, from: usize, releases: *heap.ReleaseDomain) void {
        switch (child.kind()) {
            inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => |kind| {
                const Source = heap.LeafElement(kind);
                if (comptime !widens(Source, Out)) unreachable;
                var reader = heap.LeafReader(kind).acquire(child);
                defer reader.release(releases);
                const source = reader.slice()[from..][0..out.len];
                if (Source == Out) {
                    @memcpy(out, source);
                } else for (out, source) |*slot, item| {
                    slot.* = item;
                }
            },
            .generic_spine, .dict, .task, .module, .port, .reserved_mask => unreachable,
        }
    }

    pub fn advance(evaluator: *Machine, self: *RazeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.collection.borrow().list.length());
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .count => {
                if (self.index == count) {
                    self.index = 0;
                    if (self.class != .none and self.class != .boxed) {
                        self.output = .init(.{ .builder = try heap.AnyListBuilder.init(
                            evaluator.allocator(),
                            self.widest,
                            self.total,
                            self.total,
                        ) });
                        self.phase = .typed_fill;
                        continue;
                    }
                    self.values = .init(try evaluator.allocator().alloc(Value, self.total));
                    self.phase = .fill;
                    continue;
                }
                const item = list.atUnchecked(self.collection.borrow(), self.index);
                self.classify(item);
                const contribution: usize = if (item == .list) @intCast(item.list.length()) else 1;
                self.total = std.math.add(usize, self.total, contribution) catch
                    return evaluator.fail(.overflow, "raze result is too large");
                self.index += 1;
                _ = work.spend();
            },
            .typed_fill => {
                if (self.index == count) {
                    var output = self.output.?.take();
                    self.output = null;
                    return .{ .output = .{ .list = output.builder.finish() } };
                }
                const child = list.atUnchecked(self.collection.borrow(), self.index).list;
                const length: usize = @intCast(child.length());
                if (self.child_index == length) {
                    self.child_index = 0;
                    self.index += 1;
                    _ = work.spend();
                    continue;
                }
                const run = work.take(length - self.child_index);
                switch (self.output.?.borrowMut().builder) {
                    .generic => unreachable,
                    inline else => |*builder| copyChild(
                        @TypeOf(builder.items()[0]),
                        builder.items()[self.destination..][0..run],
                        child,
                        self.child_index,
                        evaluator.releaseDomain(),
                    ),
                }
                self.destination += run;
                self.child_index += run;
            },
            .fill => {
                if (self.index == count) {
                    self.materializer = .init(list.ValueMaterializer.init(
                        evaluator.allocator(),
                        self.values.?.borrow(),
                    ));
                    self.phase = .materialize;
                    continue;
                }
                const item = list.atUnchecked(self.collection.borrow(), self.index);
                if (item != .list) {
                    self.values.?.borrow()[self.destination] = item;
                    self.destination += 1;
                    self.index += 1;
                } else if (self.child_index == item.list.length()) {
                    self.child_index = 0;
                    self.index += 1;
                    _ = work.spend();
                    continue;
                } else {
                    self.values.?.borrow()[self.destination] = list.atUnchecked(item, self.child_index);
                    self.destination += 1;
                    self.child_index += 1;
                }
                _ = work.spend();
            },
            .materialize => return switch (try self.materializer.?.borrowMut().advance(work)) {
                .pending => .stepped,
                .complete => |result| .{ .output = result },
            },
        };
        return .stepped;
    }
};

fn catPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    if (left.borrow() != .list or right.borrow() != .list) return evaluator.typeError("two lists");
    const left_count: usize = @intCast(left.borrow().list.length());
    const right_count: usize = @intCast(right.borrow().list.length());
    if (left_count == 0 and right_count == 0 and (left.borrow().isString() or right.borrow().isString())) {
        return evaluator.pushOwned(try emptyLike(
            evaluator.allocator(),
            if (left.borrow().isString()) left.borrow() else right.borrow(),
        ));
    }
    try ListCopyDriver.installCat(evaluator, &left, &right, left_count, right_count);
}

fn firstPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    if (collection.borrow().list.length() == 0) return evaluator.fail(.domain, "first requires a non-empty list");
    try evaluator.pushBorrowed(list.atUnchecked(collection.borrow(), 0));
}

pub fn firstForIdiom(evaluator: *Machine) MachineError!void {
    return firstPrimitive(evaluator);
}

fn restPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    if (count == 0) return evaluator.fail(.domain, "rest requires a non-empty list");
    if (count == 1) return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection.borrow()));
    try ListCopyDriver.installOne(evaluator, &collection, 1, count, false);
}

pub fn restForIdiom(evaluator: *Machine) MachineError!void {
    return restPrimitive(evaluator);
}

fn takePrimitive(evaluator: *Machine) MachineError!void {
    var collection, var count_value = try evaluator.popPair();
    defer count_value.deinit();
    defer collection.deinit();
    if (collection.borrow() != .list or count_value.borrow() != .int) {
        return evaluator.typeError("a list and an integer count");
    }
    const source_count: usize = @intCast(collection.borrow().list.length());
    const result_count = std.math.cast(usize, unsignedMagnitude(count_value.borrow().int)) orelse
        return evaluator.fail(.overflow, "take length exceeds addressable size");
    if (result_count == 0) {
        return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection.borrow()));
    }
    if (result_count != 0 and source_count == 0) {
        return evaluator.fail(.domain, "take cannot cycle an empty list");
    }
    const start = if (result_count == 0 or count_value.borrow().int >= 0)
        0
    else
        (source_count - (result_count % source_count)) % source_count;
    if (try startTypedCopy(
        evaluator,
        &collection,
        null,
        null,
        .{ .cyclic = .{ .start = start } },
        result_count,
    )) return;
    const values = try evaluator.allocator().alloc(Value, result_count);
    try evaluator.runDriver(TakeDriver{
        .collection = .init(collection.take()),
        .values = .init(values),
        .source_index = start,
        .source_count = source_count,
        .materializer = .init(list.ValueMaterializer.init(evaluator.allocator(), values)),
    });
}

/// A rotation is a cyclic copy of the whole list from the element the count
/// lands on, so it shares `take`'s typed and boxed copy paths.
fn rotatePrimitive(evaluator: *Machine) MachineError!void {
    var collection, var count_value = try evaluator.popPair();
    defer count_value.deinit();
    defer collection.deinit();
    if (collection.borrow() != .list or count_value.borrow() != .int) {
        return evaluator.typeError("a list and an integer count");
    }
    const count: usize = @intCast(collection.borrow().list.length());
    if (count == 0) return evaluator.pushOwned(collection.take());
    const start: usize = @intCast(@mod(count_value.borrow().int, @as(i64, @intCast(count))));
    if (try startTypedCopy(
        evaluator,
        &collection,
        null,
        null,
        .{ .cyclic = .{ .start = start } },
        count,
    )) return;
    const values = try evaluator.allocator().alloc(Value, count);
    try evaluator.runDriver(TakeDriver{
        .collection = .init(collection.take()),
        .values = .init(values),
        .source_index = start,
        .source_count = count,
        .materializer = .init(list.ValueMaterializer.init(evaluator.allocator(), values)),
    });
}

const TakeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    values: heap.Owned([]Value),
    result_index: usize = 0,
    source_index: usize,
    source_count: usize,
    materializing: bool = false,
    materializer: heap.Owned(list.ValueMaterializer),

    pub fn advance(
        evaluator: *Machine,
        self: *TakeDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        const values = self.values.borrow();
        while (!self.materializing and !work.exhausted() and self.result_index < values.len) {
            values[self.result_index] = list.atUnchecked(self.collection.borrow(), self.source_index);
            self.result_index += 1;
            self.source_index += 1;
            if (self.source_index == self.source_count) self.source_index = 0;
            _ = work.spend();
        }
        if (self.result_index != values.len) return .stepped;
        self.materializing = true;
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

fn dropPrimitive(evaluator: *Machine) MachineError!void {
    var collection, var count_value = try evaluator.popPair();
    defer count_value.deinit();
    defer collection.deinit();
    if (collection.borrow() != .list or count_value.borrow() != .int) {
        return evaluator.typeError("a list and an integer count");
    }
    const count: usize = @intCast(collection.borrow().list.length());
    const magnitude: usize = @intCast(@min(unsignedMagnitude(count_value.borrow().int), count));
    const bounds: struct { start: usize, end: usize } = if (count_value.borrow().int >= 0)
        .{ .start = magnitude, .end = count }
    else
        .{ .start = 0, .end = count - magnitude };
    if (bounds.start == bounds.end)
        return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection.borrow()));
    try ListCopyDriver.installOne(evaluator, &collection, bounds.start, bounds.end, false);
}

fn reversePrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    const count: usize = @intCast(collection.borrow().list.length());
    if (count == 0) return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection.borrow()));
    try ListCopyDriver.installOne(evaluator, &collection, 0, count, true);
}

pub fn reverseForIdiom(evaluator: *Machine) MachineError!void {
    return reversePrimitive(evaluator);
}

const ListCopyDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: ?heap.Owned(Value) = null,
    start: usize,
    end: usize,
    left_count: usize = 0,
    reverse: bool = false,
    values: heap.Owned([]Value),
    index: usize = 0,
    materializer: heap.Owned(list.ValueMaterializer),

    fn installOne(
        evaluator: *Machine,
        collection: *heap.OwnedValue,
        start: usize,
        end: usize,
        reverse: bool,
    ) MachineError!void {
        if (try startTypedCopy(
            evaluator,
            collection,
            null,
            null,
            if (reverse) .{ .reversed = .{ .end = end } } else .{ .contiguous = .{ .start = start } },
            end - start,
        )) return;
        const values = try evaluator.allocator().alloc(Value, end - start);
        try evaluator.runDriver(ListCopyDriver{
            .left = .init(collection.take()),
            .start = start,
            .end = end,
            .reverse = reverse,
            .values = .init(values),
            .materializer = .init(.init(evaluator.allocator(), values)),
        });
    }

    fn installCat(
        evaluator: *Machine,
        left: *heap.OwnedValue,
        right: *heap.OwnedValue,
        left_count: usize,
        right_count: usize,
    ) MachineError!void {
        if (try startTypedCopy(
            evaluator,
            left,
            right,
            null,
            .{ .concat = .{ .left_count = left_count } },
            left_count + right_count,
        )) return;
        const values = try evaluator.allocator().alloc(Value, left_count + right_count);
        try evaluator.runDriver(ListCopyDriver{
            .left = .init(left.take()),
            .right = .init(right.take()),
            .start = 0,
            .end = left_count + right_count,
            .left_count = left_count,
            .values = .init(values),
            .materializer = .init(.init(evaluator.allocator(), values)),
        });
    }

    pub fn advance(evaluator: *Machine, self: *ListCopyDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        const values = self.values.borrow();
        while (self.index != values.len and work.spend()) {
            if (self.right) |*right| {
                values[self.index] = if (self.index < self.left_count)
                    list.atUnchecked(self.left.borrow(), self.index)
                else
                    list.atUnchecked(right.borrow(), self.index - self.left_count);
            } else {
                const source = if (self.reverse) self.end - self.index - 1 else self.start + self.index;
                values[self.index] = list.atUnchecked(self.left.borrow(), source);
            }
            self.index += 1;
        }
        if (self.index != values.len or work.exhausted()) return .stepped;
        return switch (try self.materializer.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

fn emptyLike(allocator: std.mem.Allocator, collection: Value) MachineError!Value {
    return list.emptyLike(allocator, collection) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotAList => unreachable,
    };
}

fn rangePrimitive(evaluator: *Machine) MachineError!void {
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    if (count_value.borrow() != .int) return evaluator.typeError("a non-negative integer");
    if (count_value.borrow().int < 0) return evaluator.fail(.domain, "range requires a non-negative integer");
    const count = std.math.cast(usize, count_value.borrow().int) orelse
        return evaluator.fail(.overflow, "range length exceeds addressable size");
    // A known-width producer selects its builder before filling: `range` is
    // exactly the shape that never needed a boxed intermediate.
    const writer = try heap.LeafWriter(.leaf_i64).init(evaluator.allocator(), count);
    try evaluator.runDriver(RangeDriver{
        .writer = .init(writer),
        .cursor = kernel_flat.FlatCursor.init(count),
    });
}

/// Fills the typed result buffer in place, one charged chunk at a time. There is
/// no intermediate: the element type was known before the first store.
const RangeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    writer: heap.Owned(heap.LeafWriter(.leaf_i64)),
    cursor: kernel_flat.FlatCursor,

    pub fn advance(evaluator: *Machine, self: *RangeDriver) MachineError!machine.WorkProgress {
        const context = support.Context{ .evaluator = evaluator };
        var block: [kernel_flat.block_size]i64 = undefined;
        if (try self.cursor.nextRange(context)) |range| {
            var offset: usize = 0;
            while (offset != range.len()) {
                const piece = kernel_flat.blockRange(range, offset);
                for (piece.start..piece.end) |index| block[index - piece.start] = @intCast(index);
                self.writer.borrowMut().writeRange(piece.start, block[0..piece.len()]);
                offset += piece.len();
            }
        }
        if (!self.cursor.complete()) return .stepped;
        return .{ .output = self.writer.borrowMut().finish() };
    }
};

fn lenPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    try evaluator.pushOwned(.{ .int = @intCast(collection.borrow().list.length()) });
}

const ShapeProgress = union(enum) { pending, complete: []usize, ragged, too_deep };

const ShapeCursor = struct {
    const Action = union(enum) {
        visit: struct { item: Value, depth: usize },
        children: struct { collection: Value, depth: usize, index: usize },
    };
    allocator: std.mem.Allocator,
    actions: @import("poll.zig").ChunkStack(Action),
    dimensions: [support.max_depth]usize = @splat(0),
    rank: usize = 0,
    leaf_depth: ?usize = null,

    fn init(allocator: std.mem.Allocator, collection: Value) error{OutOfMemory}!ShapeCursor {
        var actions = @import("poll.zig").ChunkStack(Action).init(allocator);
        errdefer actions.deinit();
        try actions.push(.{ .visit = .{ .item = collection, .depth = 0 } });
        return .{ .allocator = allocator, .actions = actions };
    }

    pub fn deinit(self: *ShapeCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *ShapeCursor, work: *poll.WorkBudget) error{OutOfMemory}!ShapeProgress {
        while (work.spend()) {
            const action = self.actions.pop() orelse {
                const result = try self.allocator.alloc(usize, self.rank);
                @memcpy(result, self.dimensions[0..self.rank]);
                return .{ .complete = result };
            };
            switch (action) {
                .visit => |visit| {
                    if (visit.item != .list) {
                        if (self.leaf_depth) |depth| {
                            if (depth != visit.depth) return .ragged;
                        } else self.leaf_depth = visit.depth;
                        continue;
                    }
                    if (visit.depth == support.max_depth) return .too_deep;
                    const count: usize = @intCast(visit.item.list.length());
                    if (visit.depth < self.rank) {
                        if (self.dimensions[visit.depth] != count) return .ragged;
                    } else {
                        if (self.leaf_depth != null) return .ragged;
                        self.dimensions[visit.depth] = count;
                        self.rank = visit.depth + 1;
                    }
                    if (count == 0) {
                        const depth = visit.depth + 1;
                        if (self.leaf_depth) |expected| {
                            if (expected != depth) return .ragged;
                        } else self.leaf_depth = depth;
                    } else try self.actions.push(.{ .children = .{
                        .collection = visit.item,
                        .depth = visit.depth + 1,
                        .index = 0,
                    } });
                },
                .children => |children| {
                    const count: usize = @intCast(children.collection.list.length());
                    if (children.index + 1 != count) try self.actions.push(.{ .children = .{
                        .collection = children.collection,
                        .depth = children.depth,
                        .index = children.index + 1,
                    } });
                    try self.actions.push(.{ .visit = .{
                        .item = list.atUnchecked(children.collection, children.index),
                        .depth = children.depth,
                    } });
                },
            }
        }
        return .pending;
    }
};

fn shapePrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popList();
    defer collection.deinit();
    const cursor = try ShapeCursor.init(evaluator.allocator(), collection.borrow());
    try evaluator.runDriver(ShapeDriver{
        .collection = .init(collection.take()),
        .cursor = .init(cursor),
    });
}

const ShapeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    cursor: heap.Owned(ShapeCursor),
    dimensions: ?heap.Owned([]usize) = null,

    pub fn advance(evaluator: *Machine, self: *ShapeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.dimensions == null) switch (try self.cursor.borrowMut().advance(evaluator.workBudget())) {
            .pending => return .stepped,
            .ragged => return evaluator.fail(.shape, "shape requires a rectangular list"),
            .too_deep => return evaluator.fail(.shape, "shape nesting exceeds 256 levels"),
            .complete => |dimensions| self.dimensions = .init(dimensions),
        };
        const dimensions = self.dimensions.?.borrow();
        var writer = try heap.LeafWriter(.leaf_i64).init(evaluator.allocator(), dimensions.len);
        errdefer writer.retirePartial(evaluator.releaseDomain());
        var values: [support.max_depth]i64 = undefined;
        for (dimensions, values[0..dimensions.len]) |dimension, *destination| destination.* = @intCast(dimension);
        writer.writeRange(0, values[0..dimensions.len]);
        return .{ .output = writer.finish() };
    }
};

fn flipPrimitive(evaluator: *Machine) MachineError!void {
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (collection.borrow() != .list) return evaluator.typeError("a rectangular list");
    const source = collection.borrow();
    const validation: FlipDriver.Validation = if (source.list.length() == 0)
        .{ .flat = 0 }
    else switch (list.atUnchecked(source, 0)) {
        .list => |row| .{ .rows = .{ .columns = @intCast(row.length()), .next = 1 } },
        else => .{ .flat = 1 },
    };
    const leaf_kind: ?value.HeapKind = if (validation == .rows)
        FlipDriver.leafKind(list.atUnchecked(source, 0).list.kind())
    else
        null;
    try evaluator.runDriver(FlipDriver{
        .collection = .init(collection.take()),
        .validation = validation,
        .leaf_kind = leaf_kind,
    });
}

const FlipDriver = struct {
    // Only the two transposed axes belong to flip. Cells are opaque values;
    // ShapeCursor's recursive rectangularity contract belongs to shape.
    const Validation = union(enum) {
        flat: usize,
        rows: struct { columns: usize, next: usize },
        ready: usize,
    };

    collection: heap.Owned(Value),
    validation: Validation,
    /// The one leaf representation every row shares, or null once any row
    /// differs. Rows of one representation transpose without boxing a cell.
    leaf_kind: ?value.HeapKind = null,
    /// The typed route: every column scattered into one flat buffer, which is
    /// then split into the result rows.
    typed: ?heap.Owned(RazeOutput) = null,
    flat: ?heap.Owned(Value) = null,
    result_rows: ?heap.Owned(heap.OwnedValueBuffer) = null,
    cells: ?heap.Owned([]Value) = null,
    column: usize = 0,
    row: usize = 0,
    inner: ?heap.Owned(list.ValueMaterializer) = null,
    outer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *FlipDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const rows: usize = @intCast(self.collection.borrow().list.length());
        const columns = switch (self.validation) {
            .flat => |*next| {
                while (next.* != rows and evaluator.workBudget().spend()) : (next.* += 1) {
                    if (list.atUnchecked(self.collection.borrow(), next.*) == .list)
                        return evaluator.fail(.shape, "flip requires rows of the same length");
                }
                if (next.* != rows) return .stepped;
                try evaluator.pushBorrowed(self.collection.borrow());
                return .completed;
            },
            .rows => |*validation| {
                while (validation.next != rows and evaluator.workBudget().spend()) : (validation.next += 1) {
                    const row = list.atUnchecked(self.collection.borrow(), validation.next);
                    if (row != .list or row.list.length() != validation.columns)
                        return evaluator.fail(.shape, "flip requires rows of the same length");
                    if (self.leaf_kind != null and row.list.kind() != self.leaf_kind.?) self.leaf_kind = null;
                }
                if (validation.next != rows) return .stepped;
                if (validation.columns == 0) return evaluator.fail(
                    .shape,
                    "flip cannot retain trailing axes after a transposed zero dimension",
                );
                self.validation = .{ .ready = validation.columns };
                return .stepped;
            },
            .ready => |columns| columns,
        };
        if (self.leaf_kind) |kind| return self.advanceTyped(evaluator, kind, rows, columns);
        if (self.result_rows == null) {
            self.result_rows = .init(try .init(evaluator.releaseDomain(), columns));
            self.cells = .init(try evaluator.allocator().alloc(Value, rows));
            return .stepped;
        }
        if (self.outer) |*outer| return switch (try outer.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
        if (self.inner) |*inner| switch (try inner.borrowMut().advance(evaluator.workBudget())) {
            .pending => return .stepped,
            .complete => |row_value| {
                inner.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.inner = null;
                self.result_rows.?.borrowMut().appendOwned(row_value);
                self.column += 1;
                self.row = 0;
                if (self.column == columns) {
                    self.outer = .init(.init(
                        evaluator.allocator(),
                        self.result_rows.?.borrow().values(),
                    ));
                }
                return .stepped;
            },
        };
        while (self.row != rows and evaluator.workBudget().spend()) : (self.row += 1) {
            const source_row = list.atUnchecked(self.collection.borrow(), self.row);
            self.cells.?.borrow()[self.row] = list.atUnchecked(source_row, self.column);
        }
        if (self.row == rows) self.inner = .init(.init(
            evaluator.allocator(),
            self.cells.?.borrow(),
        ));
        return .stepped;
    }

    fn leafKind(kind: value.HeapKind) ?value.HeapKind {
        return switch (kind) {
            .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => kind,
            .generic_spine, .dict, .task, .module, .port, .reserved_mask => null,
        };
    }

    /// Scatters every row into the column-major flat buffer, then splits it into
    /// one typed row per column. `row` and `column` index the scatter, then the
    /// split's current result row and position.
    fn advanceTyped(
        self: *FlipDriver,
        evaluator: *Machine,
        kind: value.HeapKind,
        rows: usize,
        columns: usize,
    ) MachineError!machine.WorkProgress {
        const work = evaluator.workBudget();
        if (self.flat == null) {
            if (self.typed == null) {
                const total = std.math.mul(usize, rows, columns) catch
                    return evaluator.fail(.overflow, "flip result is too large");
                self.typed = .init(.{ .builder = try heap.AnyListBuilder.init(evaluator.allocator(), kind, total, total) });
                self.result_rows = .init(try .init(evaluator.releaseDomain(), columns));
                return .stepped;
            }
            while (self.row != rows and !work.exhausted()) {
                // A group of consecutive rows writes consecutive elements of
                // each column, so every touched cache line fills.
                const group = @min(scatter_group, rows - self.row);
                var children: [scatter_group]*heap.ListHandle = undefined;
                for (children[0..group], self.row..) |*child, index|
                    child.* = list.atUnchecked(self.collection.borrow(), index).list;
                const run = @max(1, work.take((columns - self.column) * group) / group);
                switch (self.typed.?.borrowMut().builder) {
                    .generic => unreachable,
                    inline else => |*builder| scatterRows(
                        @TypeOf(builder.items()[0]),
                        builder.items(),
                        children[0..group],
                        self.row,
                        rows,
                        self.column,
                        @min(run, columns - self.column),
                        evaluator.releaseDomain(),
                    ),
                }
                self.column += @min(run, columns - self.column);
                if (self.column == columns) {
                    self.column = 0;
                    self.row += group;
                }
            }
            if (self.row != rows) return .stepped;
            var output = self.typed.?.take();
            self.typed = null;
            self.flat = .init(.{ .list = output.builder.finish() });
            self.row = 0;
            return .stepped;
        }
        const spine = self.result_rows.?.borrowMut();
        while (!work.exhausted()) {
            if (self.typed == null) {
                if (spine.len() == columns) return .{ .output = spine.takeList() };
                self.typed = .init(.{ .builder = try heap.AnyListBuilder.init(evaluator.allocator(), kind, rows, rows) });
                self.row = 0;
            }
            const run = work.take(rows - self.row);
            switch (self.typed.?.borrowMut().builder) {
                .generic => unreachable,
                inline else => |*builder| RazeDriver.copyChild(
                    @TypeOf(builder.items()[0]),
                    builder.items()[self.row..][0..run],
                    self.flat.?.borrow().list,
                    spine.len() * rows + self.row,
                    evaluator.releaseDomain(),
                ),
            }
            self.row += run;
            if (self.row == rows) {
                var output = self.typed.?.take();
                self.typed = null;
                spine.appendOwned(.{ .list = output.builder.finish() });
            }
        }
        return .stepped;
    }

    const scatter_group = 8;

    /// Writes `count` elements of each of the consecutive rows starting at
    /// `first`, from column `from`, to their transposed positions
    /// `column * rows + row` of the flat buffer. The readers live only for
    /// this call.
    fn scatterRows(
        comptime Out: type,
        out: []Out,
        children: []const *heap.ListHandle,
        first: usize,
        rows: usize,
        from: usize,
        count: usize,
        releases: *heap.ReleaseDomain,
    ) void {
        switch (children[0].kind()) {
            inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => |kind| {
                if (comptime heap.LeafElement(kind) != Out) unreachable;
                var readers: [scatter_group]heap.LeafReader(kind) = undefined;
                var sources: [scatter_group][]const Out = undefined;
                for (children, readers[0..children.len], sources[0..children.len]) |child, *reader, *source| {
                    reader.* = heap.LeafReader(kind).acquire(child);
                    source.* = reader.slice();
                }
                defer for (readers[0..children.len]) |*reader| reader.release(releases);
                for (from..from + count) |column| {
                    const line = out[column * rows + first ..][0..children.len];
                    for (line, sources[0..children.len]) |*slot, source| slot.* = source[column];
                }
            },
            .generic_spine, .dict, .task, .module, .port, .reserved_mask => unreachable,
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn reshapePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var shape_value = try evaluator.popValue();
    defer shape_value.deinit();
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (collection.borrow() != .list or shape_value.borrow() != .list) {
        return evaluator.typeError("a list and a non-empty integer shape");
    }
    const rank: usize = @intCast(shape_value.borrow().list.length());
    if (rank == 0) return evaluator.fail(.shape, "reshape requires a non-empty shape");
    if (rank > support.max_depth) return evaluator.fail(.shape, "reshape rank exceeds 256");
    // A flat source reshaped to rank one is exactly a typed cyclic copy. The
    // higher-rank builder still owns nested spine construction, and a
    // zero-length result stays there so its historical empty representation
    // does not change merely because the source happened to be a leaf.
    if (collection.borrow().list.kind() != .generic_spine) {
        const dimension = list.atUnchecked(shape_value.borrow(), 0);
        if (dimension != .int) return evaluator.typeError("an integer shape");
        if (dimension.int < 0) return evaluator.failAtIndex(
            .shape,
            "reshape dimensions must be non-negative",
            0,
        );
        const count = std.math.cast(usize, dimension.int) orelse
            return evaluator.failAtIndex(.overflow, "reshape dimension exceeds addressable size", 0);
        const source_count: usize = @intCast(collection.borrow().list.length());
        if (rank == 1 and count != 0) {
            if (source_count == 0) return evaluator.fail(
                .domain,
                "reshape cannot fill a non-empty shape from empty data",
            );
            if (try startTypedCopy(
                evaluator,
                &collection,
                null,
                null,
                .{ .cyclic = .{ .start = 0 } },
                count,
            )) return;
        }
        if (rank == 2 and source_count != 0 and try startTypedMatrix(
            evaluator,
            collection.borrow(),
            count,
            list.atUnchecked(shape_value.borrow(), 1),
        )) return;
    }
    const dimensions = try evaluator.allocator().alloc(usize, rank);
    var dimensions_owner: ?[]usize = dimensions;
    errdefer if (dimensions_owner) |owned| evaluator.allocator().free(owned);
    const ravel = try RavelCursor.init(evaluator.allocator(), collection.borrow(), null);
    dimensions_owner = null;
    try evaluator.runDriver(ReshapeDriver{
        .collection = .init(collection.take()),
        .shape_value = .init(shape_value.take()),
        .dimensions = .init(dimensions),
        .ravel = .init(ravel),
    });
}

/// A rank-two reshape of a non-empty typed leaf: every row is a cyclic typed
/// copy and the result is one spine of those rows, exactly what the generic
/// builder produces from the same cells. Returns false without consuming
/// anything when the column dimension is not a positive integer or the volume
/// is zero, leaving validation and its errors to the generic driver.
fn startTypedMatrix(
    evaluator: *Machine,
    source: Value,
    rows: usize,
    columns_value: Value,
) MachineError!bool {
    if (columns_value != .int or columns_value.int <= 0 or rows == 0) return false;
    const columns = std.math.cast(usize, columns_value.int) orelse return false;
    _ = std.math.mul(usize, rows, columns) catch return false;
    const source_kind = source.list.kind();
    inline for (leaf_kinds) |candidate| {
        if (candidate == source_kind) {
            var spine = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), rows);
            var held_locally = true;
            errdefer if (held_locally) spine.deinit();
            const driver = TypedMatrixDriver(candidate){
                .source = .init(heap.LeafReader(candidate).acquire(source.list)),
                .spine = .init(spine.take()),
                .columns = columns,
            };
            held_locally = false;
            try evaluator.runDriver(driver);
            return true;
        }
    }
    return false;
}

fn TypedMatrixDriver(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        source: heap.Owned(heap.LeafReader(kind)),
        spine: heap.Owned(heap.OwnedValueBuffer),
        columns: usize,
        row: ?heap.Owned(heap.LeafWriter(kind)) = null,
        cursor: kernel_flat.FlatCursor = kernel_flat.FlatCursor.init(0),

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            const spine = self.spine.borrowMut();
            if (self.row == null) {
                if (spine.len() == spine.capacity()) {
                    self.source.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    return .{ .output = spine.takeList() };
                }
                self.row = .init(try heap.LeafWriter(kind).init(evaluator.allocator(), self.columns));
                self.cursor = kernel_flat.FlatCursor.init(self.columns);
            }
            if (try self.cursor.nextRange(context)) |range| {
                const source = self.source.borrow().slice();
                const out: []Element = self.row.?.borrowMut().unpublishedRange(range.start, range.len());
                var from = (spine.len() * self.columns + range.start) % source.len;
                var written: usize = 0;
                while (written != out.len) {
                    const run = @min(source.len - from, out.len - written);
                    @memcpy(out[written..][0..run], source[from..][0..run]);
                    written += run;
                    from = 0;
                }
            }
            if (!self.cursor.complete()) return .stepped;
            var writer = self.row.?.take();
            self.row = null;
            spine.appendOwned(writer.finish());
            return .stepped;
        }
    };
}

const RavelProgress = union(enum) { pending, complete: usize, too_deep };
const RavelCursor = struct {
    const Action = union(enum) {
        visit: struct { item: Value, depth: usize },
        children: struct { collection: Value, depth: usize, index: usize },
    };
    allocator: std.mem.Allocator,
    actions: @import("poll.zig").ChunkStack(Action),
    output: ?[]Value,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator, item: Value, output: ?[]Value) error{OutOfMemory}!RavelCursor {
        var actions = @import("poll.zig").ChunkStack(Action).init(allocator);
        errdefer actions.deinit();
        try actions.push(.{ .visit = .{ .item = item, .depth = 0 } });
        return .{ .allocator = allocator, .actions = actions, .output = output };
    }
    pub fn deinit(self: *RavelCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *RavelCursor, work: *poll.WorkBudget) error{OutOfMemory}!RavelProgress {
        while (work.spend()) {
            const action = self.actions.pop() orelse return .{ .complete = self.count };
            switch (action) {
                .visit => |visit| {
                    if (visit.item != .list) {
                        if (self.output) |output| output[self.count] = visit.item;
                        self.count = std.math.add(usize, self.count, 1) catch return error.OutOfMemory;
                    } else {
                        if (visit.depth == support.max_depth) return .too_deep;
                        if (visit.item.list.length() != 0) try self.actions.push(.{ .children = .{
                            .collection = visit.item,
                            .depth = visit.depth + 1,
                            .index = 0,
                        } });
                    }
                },
                .children => |children| {
                    const count: usize = @intCast(children.collection.list.length());
                    if (children.index + 1 != count) try self.actions.push(.{ .children = .{
                        .collection = children.collection,
                        .depth = children.depth,
                        .index = children.index + 1,
                    } });
                    try self.actions.push(.{ .visit = .{
                        .item = list.atUnchecked(children.collection, children.index),
                        .depth = children.depth,
                    } });
                },
            }
        }
        return .pending;
    }
};

const ReshapeBuildCursor = struct {
    const Frame = struct {
        axis: usize,
        values: heap.OwnedValueBuffer,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?list.ValueMaterializer = null,
        result: ?Value = null,
    };
    releases: *heap.ReleaseDomain,
    allocator: std.mem.Allocator,
    dimensions: []const usize,
    flat: []const Value,
    frames: @import("poll.zig").ChunkStack(Frame),
    flat_index: usize = 0,
    last: ?Value = null,

    fn init(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        dimensions: []const usize,
        flat: []const Value,
    ) error{OutOfMemory}!ReshapeBuildCursor {
        var frames = @import("poll.zig").ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        var values = try heap.OwnedValueBuffer.init(releases, dimensions[0]);
        errdefer values.deinit();
        try frames.reserve(1);
        frames.pushReserved(.{ .axis = 0, .values = values.take() });
        return .{
            .releases = releases,
            .allocator = allocator,
            .dimensions = dimensions,
            .flat = flat,
            .frames = frames,
        };
    }
    pub fn deinit(self: *ReshapeBuildCursor) void {
        if (self.last) |last| self.releases.releaseValue(last);
        while (self.frames.pop()) |frame| self.deinitFrame(frame);
        self.frames.deinit();
        self.* = undefined;
    }
    fn deinitFrame(self: *ReshapeBuildCursor, frame_value: Frame) void {
        var frame = frame_value;
        if (frame.materializer) |*materializer| materializer.retire(self.releases);
        frame.values.deinit();
        if (frame.result) |result| self.releases.releaseValue(result);
    }
    fn delegates(frame: *const Frame) bool {
        return frame.result == null and !frame.waiting and frame.index == frame.values.capacity();
    }
    pub fn advance(self: *ReshapeBuildCursor, work: *poll.WorkBudget) error{OutOfMemory}!PervadeResult {
        while (true) {
            // A frame handing work to a nested cursor is charged by that
            // cursor; spending first would starve it at a one-unit grain.
            if (self.frames.topPtr()) |top| {
                if (!delegates(top) and !work.spend()) return .pending;
            }

            var frame = self.frames.pop() orelse {
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            errdefer self.deinitFrame(frame);
            const owns_children = frame.axis + 1 < self.dimensions.len;
            if (frame.result) |result| {
                frame.values.deinit();
                frame.result = null;
                self.last = result;
                continue;
            }
            if (frame.waiting) {
                frame.values.appendOwned(self.last.?);
                self.last = null;
                frame.index += 1;
                frame.waiting = false;
            }
            if (frame.index != frame.values.capacity()) {
                if (!owns_children) {
                    frame.values.appendBorrowed(self.flat[self.flat_index % self.flat.len]);
                    self.flat_index += 1;
                    frame.index += 1;
                    try self.frames.reserve(1);
                    self.frames.pushReserved(frame);
                    continue;
                }
                frame.waiting = true;
                var child_values = try heap.OwnedValueBuffer.init(
                    self.releases,
                    self.dimensions[frame.axis + 1],
                );
                errdefer child_values.deinit();
                try self.frames.reserve(2);
                self.frames.pushReserved(frame);
                self.frames.pushReserved(.{ .axis = frame.axis + 1, .values = child_values.take() });
                continue;
            }
            if (frame.materializer == null)
                frame.materializer = .init(self.allocator, frame.values.values());
            try self.frames.reserve(1);
            switch (try frame.materializer.?.advance(work)) {
                .pending => {
                    self.frames.pushReserved(frame);
                    return .pending;
                },
                .complete => |result| {
                    frame.result = result;
                    self.frames.pushReserved(frame);
                },
            }
        }
        return .pending;
    }
};

const PervadeResult = union(enum) { pending, complete: Value };

const ReshapeDriver = struct {
    collection: heap.Owned(Value),
    shape_value: heap.Owned(Value),
    dimensions: heap.Owned([]usize),
    dimension_index: usize = 0,
    volume: usize = 1,
    ravel: heap.Owned(RavelCursor),
    flat: ?heap.Owned([]Value) = null,
    ravel_filling: bool = false,
    builder: ?heap.Owned(ReshapeBuildCursor) = null,

    pub fn advance(evaluator: *Machine, self: *ReshapeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.dimension_index != self.dimensions.borrow().len) {
            while (self.dimension_index != self.dimensions.borrow().len and evaluator.workBudget().spend()) : (self.dimension_index += 1) {
                const dimension = list.atUnchecked(self.shape_value.borrow(), self.dimension_index);
                if (dimension != .int) return evaluator.typeError("an integer shape");
                if (dimension.int < 0) return evaluator.failAtIndex(
                    .shape,
                    "reshape dimensions must be non-negative",
                    self.dimension_index,
                );
                self.dimensions.borrow()[self.dimension_index] = std.math.cast(usize, dimension.int) orelse
                    return evaluator.failAtIndex(
                        .overflow,
                        "reshape dimension exceeds addressable size",
                        self.dimension_index,
                    );
                if (self.dimensions.borrow()[self.dimension_index] == 0 and
                    self.dimension_index + 1 < self.dimensions.borrow().len)
                    return evaluator.failAtIndex(
                        .shape,
                        "reshape cannot retain axes after a zero dimension",
                        self.dimension_index,
                    );
                self.volume = std.math.mul(usize, self.volume, self.dimensions.borrow()[self.dimension_index]) catch
                    return evaluator.fail(.overflow, "reshape volume overflows addressable size");
            }
            return .stepped;
        }
        if (self.builder) |*builder| return switch (try builder.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
        switch (try self.ravel.borrowMut().advance(evaluator.workBudget())) {
            .pending => return .stepped,
            .too_deep => return evaluator.fail(.shape, "reshape data nesting exceeds 256 levels"),
            .complete => |count| if (!self.ravel_filling) {
                self.flat = .init(try evaluator.allocator().alloc(Value, count));
                const next = try RavelCursor.init(
                    evaluator.allocator(),
                    self.collection.borrow(),
                    self.flat.?.borrow(),
                );
                self.ravel.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.ravel = .init(next);
                self.ravel_filling = true;
                return .stepped;
            } else {
                std.debug.assert(count == self.flat.?.borrow().len);
                if (self.volume > 0 and count == 0) return evaluator.fail(
                    .domain,
                    "reshape cannot fill a non-empty shape from empty data",
                );
                self.builder = .init(try .init(
                    evaluator.releaseDomain(),
                    evaluator.allocator(),
                    self.dimensions.borrow(),
                    self.flat.?.borrow(),
                ));
                return .stepped;
            },
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn cutPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var starts = try evaluator.popValue();
    defer starts.deinit();
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (collection.borrow() != .list or starts.borrow() != .list)
        return evaluator.typeError("a list and a list of integer start indices");
    try evaluator.runDriver(CutDriver{
        .collection = .init(collection.take()),
        .starts = .init(starts.take()),
    });
}

/// Validates every start, then materializes each piece from borrowed cells and
/// finally the list of pieces. One cell buffer, sized for the longest piece,
/// is reused for every piece.
const CutDriver = struct {
    collection: heap.Owned(Value),
    starts: heap.Owned(Value),
    validated: usize = 0,
    previous: usize = 0,
    longest: usize = 0,
    pieces: ?heap.Owned(heap.OwnedValueBuffer) = null,
    cells: ?heap.Owned([]Value) = null,
    piece: usize = 0,
    filled: usize = 0,
    inner: ?heap.Owned(list.ValueMaterializer) = null,
    outer: ?heap.Owned(list.ValueMaterializer) = null,

    fn start(self: *const CutDriver, index: usize) usize {
        return @intCast(list.atUnchecked(self.starts.borrow(), index).int);
    }

    fn end(self: *const CutDriver, index: usize) usize {
        const count: usize = @intCast(self.starts.borrow().list.length());
        return if (index + 1 == count)
            @intCast(self.collection.borrow().list.length())
        else
            self.start(index + 1);
    }

    pub fn advance(evaluator: *Machine, self: *CutDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.starts.borrow().list.length());
        const length: usize = @intCast(self.collection.borrow().list.length());
        if (self.validated != count) {
            while (self.validated != count and evaluator.workBudget().spend()) : (self.validated += 1) {
                const item = list.atUnchecked(self.starts.borrow(), self.validated);
                if (item != .int) return evaluator.typeError("a list of integer start indices");
                if (item.int < 0 or item.int > length) return evaluator.failAtIndex(
                    .domain,
                    "cut starts must lie within the list",
                    self.validated,
                );
                const position: usize = @intCast(item.int);
                if (self.validated != 0 and position < self.previous) return evaluator.failAtIndex(
                    .domain,
                    "cut starts must be nondecreasing",
                    self.validated,
                );
                if (self.validated != 0) self.longest = @max(self.longest, position - self.previous);
                self.previous = position;
            }
            if (self.validated == count and count != 0)
                self.longest = @max(self.longest, length - self.previous);
            return .stepped;
        }
        if (self.pieces == null) {
            self.pieces = .init(try .init(evaluator.releaseDomain(), count));
            self.cells = .init(try evaluator.allocator().alloc(Value, self.longest));
            if (count == 0) self.outer = .init(.init(evaluator.allocator(), self.pieces.?.borrow().values()));
            return .stepped;
        }
        if (self.outer) |*outer| return switch (try outer.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
        if (self.inner) |*inner| switch (try inner.borrowMut().advance(evaluator.workBudget())) {
            .pending => return .stepped,
            .complete => |piece_value| {
                inner.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.inner = null;
                self.finishPiece(evaluator, piece_value);
                return .stepped;
            },
        };
        const first = self.start(self.piece);
        const size = self.end(self.piece) - first;
        if (size == 0) {
            self.finishPiece(evaluator, try emptyLike(evaluator.allocator(), self.collection.borrow()));
            return .stepped;
        }
        const cells = self.cells.?.borrow();
        while (self.filled != size and evaluator.workBudget().spend()) : (self.filled += 1) {
            cells[self.filled] = list.atUnchecked(self.collection.borrow(), first + self.filled);
        }
        if (self.filled == size) self.inner = .init(.init(evaluator.allocator(), cells[0..size]));
        return .stepped;
    }

    fn finishPiece(self: *CutDriver, evaluator: *Machine, piece_value: Value) void {
        self.pieces.?.borrowMut().appendOwned(piece_value);
        self.piece += 1;
        self.filled = 0;
        if (self.piece == @as(usize, @intCast(self.starts.borrow().list.length())))
            self.outer = .init(.init(evaluator.allocator(), self.pieces.?.borrow().values()));
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn unsignedMagnitude(integer: i64) u64 {
    if (integer >= 0) return @intCast(integer);
    return @as(u64, @intCast(-(integer + 1))) + 1;
}

// ===========================================================================
// Typed copies
//
// `cat`, `take`, `drop`, `rest`, and `reverse` move elements without touching
// them. When every operand and the result share one leaf representation, the
// move is a typed range copy: one reader per pinned source, one exact-size typed
// writer, and a bounded block per charged chunk. Mixed representations keep the
// boxed route, because their result kind is the profiling pass's decision rather
// than the dispatch's.
// ===========================================================================

/// Which source position each result position reads. The shape is chosen once
/// per operation and switched per block, never per element.
const CopyShape = union(enum) {
    /// `result[i] = source[start + i]`
    contiguous: struct { start: usize },
    /// `result[i] = source[end - 1 - i]`
    reversed: struct { end: usize },
    /// `result[i] = source[(start + i) % source.len]`
    cyclic: struct { start: usize },
    /// `result[i] = i < left_count ? left[i] : right[i - left_count]`
    concat: struct { left_count: usize },
    /// `result[i] = source[indices[i]]`, with the same bounds and sign checks
    /// the scalar index path applies, reported identically.
    gather,
};

const leaf_kinds = [_]value.HeapKind{
    .leaf_u8,
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
    .leaf_symbol,
};

fn TypedCopyDriver(comptime kind: value.HeapKind, comptime index_kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    const Index = heap.LeafElement(index_kind);
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        source: heap.Owned(heap.LeafReader(kind)),
        other: ?heap.Owned(heap.LeafReader(kind)) = null,
        /// A typed index vector, pinned for the gather's whole life.
        indices: ?heap.Owned(heap.LeafReader(index_kind)) = null,
        writer: heap.Owned(heap.LeafWriter(kind)),
        shape: CopyShape,
        cursor: kernel_flat.FlatCursor,

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            if (try self.cursor.nextRange(context)) |range| {
                try copyRange(
                    context,
                    self.shape,
                    self.source.borrow().slice(),
                    if (self.other) |*other| other.borrow().slice() else null,
                    if (self.indices) |*indices| indices.borrow().slice() else null,
                    self.writer.borrowMut().unpublishedRange(range.start, range.len()),
                    range,
                );
            }
            if (!self.cursor.complete()) return .stepped;
            // The readers retire with the driver's fields, before the output
            // is pushed, on both the in-place and the installed path.
            return .{ .output = self.writer.borrowMut().finish() };
        }

        /// The whole copy within the caller's call, for a length the remaining
        /// budget already covers: the driver's copy, charged as its one range
        /// would be, with operands read in place under the caller's
        /// references and no driver state. Nothing is consumed; the caller
        /// releases its operands after the result is pushed.
        fn direct(
            evaluator: *Machine,
            source: Value,
            other: ?Value,
            indices: ?Value,
            shape: CopyShape,
            length: usize,
        ) MachineError!void {
            const context = support.Context{ .evaluator = evaluator };
            try context.advance(length);
            var writer = try heap.LeafWriter(kind).init(evaluator.allocator(), length);
            errdefer writer.retirePartial(evaluator.releaseDomain());
            try copyRange(
                context,
                shape,
                heap.leafElements(kind, source.list),
                if (other) |right| heap.leafElements(kind, right.list) else null,
                if (indices) |vector| heap.leafElements(index_kind, vector.list) else null,
                writer.unpublishedRange(0, length),
                .{ .start = 0, .end = length },
            );
            return evaluator.pushOwned(writer.finish());
        }

        /// Copies `range` of the result into `out`. Nothing reads the result
        /// before it is published, so each shape writes its range in place,
        /// with no staging block.
        fn copyRange(
            context: support.Context,
            shape: CopyShape,
            source: []const Element,
            other: ?[]const Element,
            gather_indices: ?[]const Index,
            out: []Element,
            range: kernel_flat.Chunk,
        ) MachineError!void {
            {
                switch (shape) {
                    .contiguous => |contiguous| @memcpy(out, source[contiguous.start + range.start ..][0..out.len]),
                    .reversed => |reversed| for (out, range.start..) |*slot, index| {
                        slot.* = source[reversed.end - index - 1];
                    },
                    .cyclic => |cyclic| {
                        var from = (cyclic.start + range.start) % source.len;
                        var written: usize = 0;
                        while (written != out.len) {
                            const run = @min(source.len - from, out.len - written);
                            @memcpy(out[written..][0..run], source[from..][0..run]);
                            written += run;
                            from = 0;
                        }
                    },
                    .concat => |concat| {
                        const right = other.?;
                        const split = @min(out.len, concat.left_count -| range.start);
                        if (split != 0) @memcpy(out[0..split], source[range.start..][0..split]);
                        const right_start = (range.start + split) -| concat.left_count;
                        @memcpy(out[split..], right[right_start..][0 .. out.len - split]);
                    },
                    .gather => {
                        const indices = gather_indices.?[range.start..range.end];
                        if (kernel_flat.firstIndexFault(Index, indices, source.len)) |fault| return switch (fault.kind) {
                            .negative => context.fail(.domain, "at index is negative"),
                            .out_of_bounds => context.fail(.domain, "at index is out of bounds"),
                        };
                        for (out, indices) |*slot, position| slot.* = source[@intCast(position)];
                    },
                }
            }
        }
    };
}

/// Starts a typed copy when every operand shares one leaf representation,
/// moving each operand's reference into the driver's readers. Returns false
/// without consuming anything when they do not, which is the registry's
/// generic classification for a mixed-representation move.
fn startTypedCopy(
    evaluator: *Machine,
    source_owner: *heap.OwnedValue,
    other_owner: ?*heap.OwnedValue,
    indices_owner: ?*heap.OwnedValue,
    shape: CopyShape,
    length: usize,
) MachineError!bool {
    if (length == 0) return false;
    const source = source_owner.borrow();
    const other: ?Value = if (other_owner) |owner| owner.borrow() else null;
    const indices: ?Value = if (indices_owner) |owner| owner.borrow() else null;
    if (source != .list) return false;
    const source_kind = source.list.kind();
    if (other) |right| {
        if (right != .list or right.list.kind() != source_kind) return false;
    }
    const index_kind = if (indices) |vector| index: {
        if (vector != .list or (vector.list.kind() != .leaf_u8 and vector.list.kind() != .leaf_i64)) return false;
        break :index vector.list.kind();
    } else .leaf_i64;
    inline for (leaf_kinds) |candidate| {
        inline for ([_]value.HeapKind{ .leaf_u8, .leaf_i64 }) |candidate_index| {
            if (candidate == source_kind and candidate_index == index_kind) {
                const Driver = TypedCopyDriver(candidate, candidate_index);
                if (length <= evaluator.remainingKernelFuel()) {
                    try Driver.direct(evaluator, source, other, indices, shape, length);
                    return true;
                }
                var writer = try heap.LeafWriter(candidate).init(evaluator.allocator(), length);
                // Ownership passes to the driver below; a failing `startDriver`
                // retires the driver's fields, so this guard covers only the window
                // before the hand-off.
                var held_locally = true;
                errdefer if (held_locally) writer.retirePartial(evaluator.releaseDomain());
                var driver = Driver{
                    .source = .init(heap.LeafReader(candidate).adopt(source_owner.take().list)),
                    .writer = .init(writer),
                    .shape = shape,
                    .cursor = kernel_flat.FlatCursor.init(length),
                };
                if (other_owner) |right| {
                    driver.other = .init(heap.LeafReader(candidate).adopt(right.take().list));
                }
                if (indices_owner) |vector| {
                    driver.indices = .init(heap.LeafReader(candidate_index).adopt(vector.take().list));
                }
                held_locally = false;
                try evaluator.runDriverAt(&driver);
                return true;
            }
        }
    }
    return false;
}
