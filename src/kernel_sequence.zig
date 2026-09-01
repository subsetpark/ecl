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
    inline for (std.meta.fields(Op)) |field| {
        const operation: Op = @enumFromInt(field.value);
        if (operation == .reverse or operation == .first or operation == .rest) continue;
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
            collection.borrow(),
            null,
            index.borrow(),
            .gather,
            @intCast(index.borrow().list.length()),
        )) return;
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
        return evaluator.startDriver(DictAtDriver{
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
    try evaluator.startDriver(IndexDriver{
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
        return switch (try self.cursor.borrowMut().advance(evaluator, machine.kernel_poll_quantum)) {
            .pending => .yielded,
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
        return switch (try self.cursor.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
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
    pub fn advance(self: *IndexCursor, evaluator: *Machine, budget: usize) MachineError!IndexProgress {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
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
                    switch (try build.materializer.?.advance(remaining)) {
                        .pending => {
                            self.frames.pushReserved(.{ .build = build.* });
                            return .pending;
                        },
                        .complete => |result| {
                            build.result = result;
                            self.frames.pushReserved(.{ .build = build.* });
                            return .pending;
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
    try evaluator.startDriver(WhereDriver{
        .counts = .init(counts.take()),
        .reader = if (reader) |acquired| .init(acquired) else null,
    });
}

/// Counts, then fills. The result is an exact-size index vector whose element
/// type is known before the first store, so the fill writes `leaf_i64` storage
/// directly; a run of equal indices is one bounded fill rather than a loop.
///
/// A typed count list is read through a pinned typed slice. A boxed one keeps
/// the bounded per-element read, which is its registry classification.
const WhereDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    counts: heap.Owned(Value),
    phase: enum { count, fill, materialize } = .count,
    index: usize = 0,
    total: usize = 0,
    writer: ?heap.Owned(heap.LeafWriter(.leaf_i64)) = null,
    reader: ?heap.Owned(heap.LeafReader(.leaf_i64)) = null,
    destination: usize = 0,
    repetition: usize = 0,

    /// The count at one position: from the pinned typed slice when the input is
    /// a typed leaf, through the bounded boxed read otherwise.
    fn countAt(self: *const WhereDriver, index: usize) Value {
        if (self.reader) |*pinned| return .{ .int = pinned.borrow().slice()[index] };
        return list.atUnchecked(self.counts.borrow(), index);
    }

    pub fn advance(evaluator: *Machine, self: *WhereDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.counts.borrow().list.length());
        var budget = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .count => {
                if (self.index == count) {
                    self.writer = .init(try heap.LeafWriter(.leaf_i64).init(
                        evaluator.allocator(),
                        self.total,
                    ));
                    self.index = 0;
                    self.phase = .fill;
                    continue;
                }
                const item = self.countAt(self.index);
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
                budget -= 1;
            },
            .fill => {
                if (self.index == count) {
                    self.phase = .materialize;
                    continue;
                }
                if (self.repetition == 0) {
                    self.repetition = @intCast(self.countAt(self.index).int);
                    if (self.repetition == 0) {
                        self.index += 1;
                        budget -= 1;
                        continue;
                    }
                }
                const element = std.math.cast(i64, self.index) orelse
                    return evaluator.fail(.overflow, "where index exceeds integer range");
                // One run of equal indices is one bounded fill, charged for the
                // elements it actually wrote.
                const run = @min(self.repetition, budget);
                self.writer.?.borrowMut().fillRange(self.destination, run, element);
                self.destination += run;
                self.repetition -= run;
                budget -= run;
                if (self.repetition == 0) self.index += 1;
            },
            .materialize => {
                if (self.reader) |*pinned| pinned.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.reader = null;
                return .{ .output = self.writer.?.borrowMut().finish() };
            },
        };
        return .yielded;
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
            return evaluator.startDriver(Driver{
                .counts = .init(heap.LeafReader(candidate).acquire(counts.borrow().list)),
                .cursor = .init(count),
                .count = count,
            });
        }
    }
    try evaluator.startDriver(FirstWhereDriver{
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
            if (!self.cursor.complete()) return .yielded;
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
        var budget: usize = machine.kernel_poll_quantum;
        while (self.index != count and budget != 0) : (budget -= 1) {
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
        if (self.index != count) return .yielded;
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
    try evaluator.startDriver(MembershipDriver{
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
        .generic_spine, .dict, .task, .module, .reserved_mask => unreachable,
    };
}

fn scalarCanMatchKind(needle: Value, haystack_kind: value.HeapKind) bool {
    return switch (needle) {
        .int, .float => haystack_kind == .leaf_u8 or haystack_kind == .leaf_i64 or haystack_kind == .leaf_f64,
        .char => haystack_kind == .leaf_char1 or haystack_kind == .leaf_char2 or haystack_kind == .leaf_char4,
        .symbol => haystack_kind == .leaf_symbol,
        .word, .list, .dict, .task, .module => false,
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
            if (!self.cursor.complete()) return .yielded;
            self.haystack.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = .{ .int = 0 } };
        }
    };
}

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
        cursor: kernel_flat.FlatCursor,
        needle_index: usize = 0,

        fn finish(self: *Self, evaluator: *Machine) machine.WorkProgress {
            self.needles.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.haystack.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = self.writer.borrowMut().finish() };
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            const needles = self.needles.borrow().slice();
            const candidates = self.haystack.borrow().slice();

            // A disjoint leaf domain, or an empty haystack, is a typed fill.
            // It is still chunked by the needle count so a large mask cannot
            // bypass cancellation merely because no comparisons are needed.
            if (!compatible or candidates.len == 0) {
                if (try self.cursor.nextRange(context)) |range| {
                    self.writer.borrowMut().fillRange(range.start, range.len(), 0);
                }
                if (!self.cursor.complete()) return .yielded;
                return self.finish(evaluator);
            }

            // Spend one unit-wide fuel interval across as many short searches
            // as fit. A long haystack is one charged range; a short one does
            // not force one scheduler handoff per needle.
            var first = true;
            while (first or context.remaining() != 0) {
                first = false;
                const range = (try self.cursor.nextRange(context)).?;
                var found = false;
                for (candidates[range.start..range.end]) |candidate| {
                    if (typedElementsMatch(
                        needle_kind,
                        haystack_kind,
                        needles[self.needle_index],
                        candidate,
                    )) {
                        found = true;
                        break;
                    }
                }
                if (found or self.cursor.complete()) {
                    self.writer.borrowMut().fillRange(
                        self.needle_index,
                        1,
                        @intFromBool(found),
                    );
                    self.needle_index += 1;
                    if (self.needle_index == needles.len) return self.finish(evaluator);
                    self.cursor = kernel_flat.FlatCursor.init(candidates.len);
                }
            }
            return .yielded;
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
                try evaluator.startDriver(Driver{
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
                const candidate_count: usize = @intCast(haystack.list.length());
                const driver = Driver{
                    .needles = .init(heap.LeafReader(candidate_needle).acquire(needle.list)),
                    .haystack = .init(heap.LeafReader(candidate_haystack).acquire(haystack.list)),
                    .writer = .init(writer),
                    .cursor = kernel_flat.FlatCursor.init(if (membershipKindsCompatible(candidate_needle, candidate_haystack) and candidate_count != 0) candidate_count else @intCast(needle.list.length())),
                };
                held_locally = false;
                try evaluator.startDriver(driver);
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
        return switch (try self.cursor.borrowMut().advance(evaluator, machine.kernel_poll_quantum)) {
            .pending => .yielded,
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
    pub fn advance(self: *MembershipCursor, evaluator: *Machine, budget: usize) MachineError!IndexProgress {
        var work: poll.WorkBudget = .init(budget);
        while (work.spend()) {
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
                    switch (try search.match.?.advanceWithBudget(&work)) {
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
                    switch (try build.materializer.?.advanceWithBudget(&work)) {
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
    try evaluator.startDriver(RazeDriver{ .collection = .init(collection.take()) });
}

const RazeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    phase: enum { count, fill, materialize } = .count,
    index: usize = 0,
    child_index: usize = 0,
    total: usize = 0,
    values: ?heap.Owned([]Value) = null,
    destination: usize = 0,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *RazeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.collection.borrow().list.length());
        var budget = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .count => {
                if (self.index == count) {
                    self.values = .init(try evaluator.allocator().alloc(Value, self.total));
                    self.index = 0;
                    self.phase = .fill;
                    continue;
                }
                const item = list.atUnchecked(self.collection.borrow(), self.index);
                const contribution: usize = if (item == .list) @intCast(item.list.length()) else 1;
                self.total = std.math.add(usize, self.total, contribution) catch
                    return evaluator.fail(.overflow, "raze result is too large");
                self.index += 1;
                budget -= 1;
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
                    continue;
                } else {
                    self.values.?.borrow()[self.destination] = list.atUnchecked(item, self.child_index);
                    self.destination += 1;
                    self.child_index += 1;
                }
                budget -= 1;
            },
            .materialize => return switch (try self.materializer.?.borrowMut().advance(budget)) {
                .pending => .yielded,
                .complete => |result| .{ .output = result },
            },
        };
        return .yielded;
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
    try evaluator.require(2);
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    var collection = try evaluator.popValue();
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
        collection.borrow(),
        null,
        null,
        .{ .cyclic = .{ .start = start } },
        result_count,
    )) return;
    const values = try evaluator.allocator().alloc(Value, result_count);
    try evaluator.startDriver(TakeDriver{
        .collection = .init(collection.take()),
        .values = .init(values),
        .source_index = start,
        .source_count = source_count,
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
        var budget = machine.kernel_poll_quantum;
        const values = self.values.borrow();
        while (!self.materializing and budget != 0 and self.result_index < values.len) {
            values[self.result_index] = list.atUnchecked(self.collection.borrow(), self.source_index);
            self.result_index += 1;
            self.source_index += 1;
            if (self.source_index == self.source_count) self.source_index = 0;
            budget -= 1;
        }
        if (self.result_index != values.len) return .yielded;
        self.materializing = true;
        if (budget == 0) return .yielded;
        return switch (try self.materializer.borrowMut().advance(budget)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }
};

fn dropPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    var collection = try evaluator.popValue();
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
            collection.borrow(),
            null,
            null,
            if (reverse) .{ .reversed = .{ .end = end } } else .{ .contiguous = .{ .start = start } },
            end - start,
        )) return;
        const values = try evaluator.allocator().alloc(Value, end - start);
        try evaluator.startDriver(ListCopyDriver{
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
            left.borrow(),
            right.borrow(),
            null,
            .{ .concat = .{ .left_count = left_count } },
            left_count + right_count,
        )) return;
        const values = try evaluator.allocator().alloc(Value, left_count + right_count);
        try evaluator.startDriver(ListCopyDriver{
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
        var budget = machine.kernel_poll_quantum;
        const values = self.values.borrow();
        while (budget != 0 and self.index != values.len) : (budget -= 1) {
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
        if (self.index != values.len or budget == 0) return .yielded;
        return switch (try self.materializer.borrowMut().advance(budget)) {
            .pending => .yielded,
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
    try evaluator.startDriver(RangeDriver{
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
        if (!self.cursor.complete()) return .yielded;
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
    dimensions: [support.max_depth]usize = .{0} ** support.max_depth,
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

    pub fn advance(self: *ShapeCursor, budget: usize) error{OutOfMemory}!ShapeProgress {
        for (0..budget) |_| {
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
    try evaluator.startDriver(ShapeDriver{
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
        if (self.dimensions == null) switch (try self.cursor.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
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
    const shape = try ShapeCursor.init(evaluator.allocator(), collection.borrow());
    try evaluator.startDriver(FlipDriver{
        .collection = .init(collection.take()),
        .shape = .init(shape),
    });
}

const FlipDriver = struct {
    collection: heap.Owned(Value),
    shape: heap.Owned(ShapeCursor),
    dimensions: ?heap.Owned([]usize) = null,
    rows: usize = 0,
    columns: usize = 0,
    result_rows: ?heap.Owned(heap.OwnedValueBuffer) = null,
    cells: ?heap.Owned([]Value) = null,
    column: usize = 0,
    row: usize = 0,
    inner: ?heap.Owned(list.ValueMaterializer) = null,
    outer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *FlipDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.dimensions == null) switch (try self.shape.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .ragged => return evaluator.fail(.shape, "flip requires a rectangular list"),
            .too_deep => return evaluator.fail(.shape, "flip nesting exceeds 256 levels"),
            .complete => |dimensions| {
                self.dimensions = .init(dimensions);
                if (dimensions.len <= 1) {
                    try evaluator.pushBorrowed(self.collection.borrow());
                    return .completed;
                }
                self.rows = dimensions[0];
                self.columns = dimensions[1];
                if (self.columns == 0 and self.rows != 0) return evaluator.fail(
                    .shape,
                    "flip cannot retain trailing axes after a transposed zero dimension",
                );
                self.result_rows = .init(try .init(evaluator.releaseDomain(), self.columns));
                self.cells = .init(try evaluator.allocator().alloc(Value, self.rows));
                return .yielded;
            },
        };
        if (self.outer) |*outer| return switch (try outer.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
        if (self.inner) |*inner| switch (try inner.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |row_value| {
                inner.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.inner = null;
                self.result_rows.?.borrowMut().appendOwned(row_value);
                self.column += 1;
                self.row = 0;
                if (self.column == self.columns) {
                    self.outer = .init(.init(
                        evaluator.allocator(),
                        self.result_rows.?.borrow().values(),
                    ));
                }
                return .yielded;
            },
        };
        const end = @min(self.row + machine.kernel_poll_quantum, self.rows);
        while (self.row != end) : (self.row += 1) {
            const source_row = list.atUnchecked(self.collection.borrow(), self.row);
            self.cells.?.borrow()[self.row] = list.atUnchecked(source_row, self.column);
        }
        if (self.row == self.rows) self.inner = .init(.init(
            evaluator.allocator(),
            self.cells.?.borrow(),
        ));
        return .yielded;
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
                collection.borrow(),
                null,
                null,
                .{ .cyclic = .{ .start = 0 } },
                count,
            )) return;
        }
    }
    const dimensions = try evaluator.allocator().alloc(usize, rank);
    var dimensions_owner: ?[]usize = dimensions;
    errdefer if (dimensions_owner) |owned| evaluator.allocator().free(owned);
    const ravel = try RavelCursor.init(evaluator.allocator(), collection.borrow(), null);
    dimensions_owner = null;
    try evaluator.startDriver(ReshapeDriver{
        .collection = .init(collection.take()),
        .shape_value = .init(shape_value.take()),
        .dimensions = .init(dimensions),
        .ravel = .init(ravel),
    });
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
    pub fn advance(self: *RavelCursor, budget: usize) error{OutOfMemory}!RavelProgress {
        for (0..budget) |_| {
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
    pub fn advance(self: *ReshapeBuildCursor, budget: usize) error{OutOfMemory}!PervadeResult {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
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
            switch (try frame.materializer.?.advance(remaining)) {
                .pending => {
                    self.frames.pushReserved(frame);
                    return .pending;
                },
                .complete => |result| {
                    frame.result = result;
                    self.frames.pushReserved(frame);
                    return .pending;
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
            const end = @min(self.dimension_index + machine.kernel_poll_quantum, self.dimensions.borrow().len);
            while (self.dimension_index != end) : (self.dimension_index += 1) {
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
            return .yielded;
        }
        if (self.builder) |*builder| return switch (try builder.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
        switch (try self.ravel.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
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
                return .yielded;
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
                return .yielded;
            },
        }
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
            var block: [kernel_flat.block_size]Element = undefined;
            if (try self.cursor.nextRange(context)) |range| {
                const source = self.source.borrow().slice();
                var offset: usize = 0;
                while (offset != range.len()) {
                    const piece = kernel_flat.blockRange(range, offset);
                    switch (self.shape) {
                        .contiguous => |contiguous| {
                            const from = contiguous.start + piece.start;
                            @memcpy(block[0..piece.len()], source[from..][0..piece.len()]);
                        },
                        .reversed => |reversed| {
                            for (piece.start..piece.end) |index| {
                                block[index - piece.start] = source[reversed.end - index - 1];
                            }
                        },
                        .cyclic => |cyclic| {
                            for (piece.start..piece.end) |index| {
                                block[index - piece.start] = source[(cyclic.start + index) % source.len];
                            }
                        },
                        .concat => |concat| {
                            const right = self.other.?.borrow().slice();
                            for (piece.start..piece.end) |index| {
                                block[index - piece.start] = if (index < concat.left_count)
                                    source[index]
                                else
                                    right[index - concat.left_count];
                            }
                        },
                        .gather => {
                            const indices = self.indices.?.borrow().slice();
                            for (piece.start..piece.end) |index| {
                                const position = indices[index];
                                if (index_kind == .leaf_i64 and position < 0)
                                    return context.fail(.domain, "at index is negative");
                                const offset_position = std.math.cast(usize, position) orelse
                                    return context.fail(.domain, "at index is out of bounds");
                                if (offset_position >= source.len)
                                    return context.fail(.domain, "at index is out of bounds");
                                block[index - piece.start] = source[offset_position];
                            }
                        },
                    }
                    self.writer.borrowMut().writeRange(piece.start, block[0..piece.len()]);
                    offset += piece.len();
                }
            }
            if (!self.cursor.complete()) return .yielded;
            self.source.deinit(evaluator.releaseDomain(), evaluator.allocator());
            if (self.other) |*other| other.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.other = null;
            if (self.indices) |*indices| indices.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.indices = null;
            return .{ .output = self.writer.borrowMut().finish() };
        }
    };
}

/// Starts a typed copy when every operand shares one leaf representation.
/// Returns false without consuming anything when they do not, which is the
/// registry's generic classification for a mixed-representation move.
fn startTypedCopy(
    evaluator: *Machine,
    source: Value,
    other: ?Value,
    indices: ?Value,
    shape: CopyShape,
    length: usize,
) MachineError!bool {
    if (length == 0) return false;
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
                var writer = try heap.LeafWriter(candidate).init(evaluator.allocator(), length);
                // Ownership passes to the driver below; a failing `startDriver`
                // retires the driver's fields, so this guard covers only the window
                // before the hand-off.
                var held_locally = true;
                errdefer if (held_locally) writer.retirePartial(evaluator.releaseDomain());
                var driver = Driver{
                    .source = .init(heap.LeafReader(candidate).acquire(source.list)),
                    .writer = .init(writer),
                    .shape = shape,
                    .cursor = kernel_flat.FlatCursor.init(length),
                };
                if (other) |right| {
                    driver.other = .init(heap.LeafReader(candidate).acquire(right.list));
                }
                if (indices) |vector| {
                    driver.indices = .init(heap.LeafReader(candidate_index).acquire(vector.list));
                }
                held_locally = false;
                try evaluator.startDriver(driver);
                return true;
            }
        }
    }
    return false;
}
