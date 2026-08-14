//! Sequence, search, and rectangular-shape kernels.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
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
    var index_owned = true;
    defer if (index_owned) heap.releaseValue(evaluator.allocator(), index);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    const driver = try evaluator.allocator().create(IndexDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .collection = collection,
        .index = index,
        .cursor = try .init(evaluator.allocator(), collection, index),
    };
    collection_owned = false;
    index_owned = false;
    evaluator.installWorkDriver(driver, IndexDriver.advance, IndexDriver.destroy);
}

pub fn atPrimitiveForIdiom() env.PrimitiveImpl {
    return bind(.at);
}

pub fn atForIdiom(evaluator: *Machine) MachineError!void {
    return atPrimitive(evaluator);
}

const IndexDriver = struct {
    collection: Value,
    index: Value,
    cursor: IndexCursor,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *IndexDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (try self.cursor.advance(evaluator, machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *IndexDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        heap.releaseValue(allocator, self.collection);
        heap.releaseValue(allocator, self.index);
        allocator.destroy(self);
    }
};

const IndexProgress = union(enum) { pending, complete: Value };
const IndexCursor = struct {
    const Node = struct { collection: Value, index: Value, depth: usize };
    const Build = struct {
        collection: Value,
        indices: Value,
        depth: usize,
        values: []Value,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?storage.ValueMaterializer = null,
        result: ?Value = null,
        release_index: usize = 0,
    };
    const Frame = union(enum) { node: Node, build: Build, find: storage.DictFindCursor };
    allocator: std.mem.Allocator,
    frames: @import("poll.zig").ChunkStack(Frame),
    last: ?Value = null,

    fn init(allocator: std.mem.Allocator, collection: Value, index: Value) error{OutOfMemory}!IndexCursor {
        var frames = @import("poll.zig").ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .node = .{ .collection = collection, .index = index, .depth = 0 } });
        return .{ .allocator = allocator, .frames = frames };
    }
    fn deinit(self: *IndexCursor) void {
        if (self.last) |last| heap.releaseValue(self.allocator, last);
        while (self.frames.pop()) |frame_value| switch (frame_value) {
            .node => {},
            .find => |cursor_value| {
                var cursor = cursor_value;
                cursor.deinit();
            },
            .build => |build_value| {
                var build = build_value;
                if (build.materializer) |*materializer| materializer.deinit();
                releaseValues(self.allocator, build.values[build.release_index..build.index]);
                self.allocator.free(build.values);
                if (build.result) |result| heap.releaseValue(self.allocator, result);
            },
        };
        self.frames.deinit();
        self.* = undefined;
    }
    fn advance(self: *IndexCursor, evaluator: *Machine, budget: usize) MachineError!IndexProgress {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
            var frame = self.frames.pop() orelse {
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            switch (frame) {
                .node => |node| {
                    if (node.depth >= support.max_depth and node.index == .list)
                        return evaluator.fail(.domain, "index nesting exceeds 256 levels");
                    if (node.collection == .dict) {
                        try self.frames.push(.{ .find = storage.DictFindCursor.init(
                            self.allocator,
                            node.collection,
                            node.index,
                        ) catch @panic("dictionary lookup cursor rejected a dictionary") });
                    } else {
                        if (node.collection != .list) return evaluator.typeError("a list or dict");
                        if (node.index == .list) {
                            const values = try self.allocator.alloc(Value, @intCast(node.index.list.length()));
                            try self.frames.push(.{ .build = .{
                                .collection = node.collection,
                                .indices = node.index,
                                .depth = node.depth,
                                .values = values,
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
                .find => |*find| switch (try find.advance(remaining)) {
                    .pending => {
                        try self.frames.push(.{ .find = find.* });
                        return .pending;
                    },
                    .complete => |maybe_result| {
                        find.deinit();
                        const result = maybe_result orelse
                            return evaluator.fail(.domain, "at could not find the dict key");
                        heap.retainValue(result);
                        self.last = result;
                    },
                },
                .build => |*build| {
                    if (build.result) |result| {
                        if (build.release_index != build.index) {
                            heap.releaseValue(self.allocator, build.values[build.release_index]);
                            build.release_index += 1;
                            try self.frames.push(.{ .build = build.* });
                            continue;
                        }
                        self.allocator.free(build.values);
                        build.result = null;
                        self.last = result;
                        continue;
                    }
                    if (build.waiting) {
                        build.values[build.index] = self.last.?;
                        self.last = null;
                        build.index += 1;
                        build.waiting = false;
                    }
                    if (build.index != build.values.len) {
                        const index = build.index;
                        build.waiting = true;
                        try self.frames.push(.{ .build = build.* });
                        try self.frames.push(.{ .node = .{
                            .collection = build.collection,
                            .index = list.atUnchecked(build.indices, index),
                            .depth = build.depth + 1,
                        } });
                        continue;
                    }
                    if (build.materializer == null)
                        build.materializer = .init(self.allocator, build.values);
                    switch (try build.materializer.?.advance(remaining)) {
                        .pending => {
                            try self.frames.push(.{ .build = build.* });
                            return .pending;
                        },
                        .complete => |result| {
                            build.result = result;
                            try self.frames.push(.{ .build = build.* });
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
    const counts = try evaluator.popOwned();
    var counts_owned = true;
    defer if (counts_owned) heap.releaseValue(evaluator.allocator(), counts);
    if (counts != .list) return evaluator.typeError("a non-negative integer count list");
    const driver = try evaluator.allocator().create(WhereDriver);
    driver.* = .{ .counts = counts };
    counts_owned = false;
    evaluator.installWorkDriver(driver, WhereDriver.advance, WhereDriver.destroy);
}

const WhereDriver = struct {
    counts: Value,
    phase: enum { count, fill, materialize } = .count,
    index: usize = 0,
    total: usize = 0,
    indices: ?[]i64 = null,
    destination: usize = 0,
    repetition: usize = 0,
    materializer: ?storage.I64Materializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *WhereDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        const count: usize = @intCast(self.counts.list.length());
        var budget = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .count => {
                if (self.index == count) {
                    self.indices = try evaluator.allocator().alloc(i64, self.total);
                    self.index = 0;
                    self.phase = .fill;
                    continue;
                }
                const item = list.atUnchecked(self.counts, self.index);
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
                    self.materializer = .init(evaluator.allocator(), self.indices.?);
                    self.phase = .materialize;
                    continue;
                }
                if (self.repetition == 0) {
                    self.repetition = @intCast(list.atUnchecked(self.counts, self.index).int);
                    if (self.repetition == 0) {
                        self.index += 1;
                        budget -= 1;
                        continue;
                    }
                }
                self.indices.?[self.destination] = std.math.cast(i64, self.index) orelse
                    return evaluator.fail(.overflow, "where index exceeds integer range");
                self.destination += 1;
                self.repetition -= 1;
                if (self.repetition == 0) self.index += 1;
                budget -= 1;
            },
            .materialize => return switch (try self.materializer.?.advance(budget)) {
                .pending => .yielded,
                .complete => |result| completed: {
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    break :completed .completed;
                },
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *WhereDriver = @ptrCast(@alignCast(raw));
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.indices) |indices| allocator.free(indices);
        heap.releaseValue(allocator, self.counts);
        allocator.destroy(self);
    }
};

fn inPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    const needle = try evaluator.popOwned();
    var needle_owned = true;
    defer if (needle_owned) heap.releaseValue(evaluator.allocator(), needle);
    if (collection != .list) return evaluator.typeError("a list haystack");
    const driver = try evaluator.allocator().create(MembershipDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .needle = needle,
        .collection = collection,
        .cursor = try .init(evaluator.allocator(), needle, collection),
    };
    needle_owned = false;
    collection_owned = false;
    evaluator.installWorkDriver(driver, MembershipDriver.advance, MembershipDriver.destroy);
}

const MembershipDriver = struct {
    needle: Value,
    collection: Value,
    cursor: MembershipCursor,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *MembershipDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (try self.cursor.advance(evaluator, machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *MembershipDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        heap.releaseValue(allocator, self.needle);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
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
        values: []Value,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?storage.ValueMaterializer = null,
        result: ?Value = null,
        release_index: usize = 0,
    };
    const Frame = union(enum) { node: Node, search: Search, build: Build };
    allocator: std.mem.Allocator,
    collection: Value,
    frames: @import("poll.zig").ChunkStack(Frame),
    last: ?Value = null,

    fn init(allocator: std.mem.Allocator, needle: Value, collection: Value) error{OutOfMemory}!MembershipCursor {
        var frames = @import("poll.zig").ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        try frames.push(.{ .node = .{ .needle = needle, .depth = 0 } });
        return .{ .allocator = allocator, .collection = collection, .frames = frames };
    }
    fn deinit(self: *MembershipCursor) void {
        if (self.last) |last| heap.releaseValue(self.allocator, last);
        while (self.frames.pop()) |frame_value| switch (frame_value) {
            .node => {},
            .search => |search_value| if (search_value.match) |cursor_value| {
                var cursor = cursor_value;
                cursor.deinit();
            },
            .build => |build_value| {
                var build = build_value;
                if (build.materializer) |*materializer| materializer.deinit();
                releaseValues(self.allocator, build.values[build.release_index..build.index]);
                self.allocator.free(build.values);
                if (build.result) |result| heap.releaseValue(self.allocator, result);
            },
        };
        self.frames.deinit();
        self.* = undefined;
    }
    fn advance(self: *MembershipCursor, evaluator: *Machine, budget: usize) MachineError!IndexProgress {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
            var frame = self.frames.pop() orelse {
                const result = self.last.?;
                self.last = null;
                return .{ .complete = result };
            };
            switch (frame) {
                .node => |node| {
                    if (node.depth >= support.max_depth and node.needle == .list)
                        return evaluator.fail(.domain, "membership nesting exceeds 256 levels");
                    if (node.needle != .list) {
                        try self.frames.push(.{ .search = .{ .needle = node.needle } });
                    } else {
                        const values = try self.allocator.alloc(Value, @intCast(node.needle.list.length()));
                        try self.frames.push(.{ .build = .{
                            .needle = node.needle,
                            .depth = node.depth,
                            .values = values,
                        } });
                    }
                },
                .search => |*search| {
                    const count: usize = @intCast(self.collection.list.length());
                    if (search.candidate == count) {
                        self.last = .{ .int = 0 };
                        continue;
                    }
                    if (search.match == null) search.match = try .init(
                        self.allocator,
                        search.needle,
                        list.atUnchecked(self.collection, search.candidate),
                    );
                    switch (try search.match.?.advance(remaining)) {
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
                            return .pending;
                        },
                    }
                },
                .build => |*build| {
                    if (build.result) |result| {
                        if (build.release_index != build.index) {
                            heap.releaseValue(self.allocator, build.values[build.release_index]);
                            build.release_index += 1;
                            try self.frames.push(.{ .build = build.* });
                            continue;
                        }
                        self.allocator.free(build.values);
                        build.result = null;
                        self.last = result;
                        continue;
                    }
                    if (build.waiting) {
                        build.values[build.index] = self.last.?;
                        self.last = null;
                        build.index += 1;
                        build.waiting = false;
                    }
                    if (build.index != build.values.len) {
                        const index = build.index;
                        build.waiting = true;
                        try self.frames.push(.{ .build = build.* });
                        try self.frames.push(.{ .node = .{
                            .needle = list.atUnchecked(build.needle, index),
                            .depth = build.depth + 1,
                        } });
                        continue;
                    }
                    if (build.materializer == null)
                        build.materializer = .init(self.allocator, build.values);
                    switch (try build.materializer.?.advance(remaining)) {
                        .pending => {
                            try self.frames.push(.{ .build = build.* });
                            return .pending;
                        },
                        .complete => |result| {
                            build.result = result;
                            try self.frames.push(.{ .build = build.* });
                            return .pending;
                        },
                    }
                },
            }
        }
        return .pending;
    }
};

fn razePrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const driver = try evaluator.allocator().create(RazeDriver);
    driver.* = .{ .collection = collection };
    collection_owned = false;
    evaluator.installWorkDriver(driver, RazeDriver.advance, RazeDriver.destroy);
}

const RazeDriver = struct {
    collection: Value,
    phase: enum { count, fill, materialize } = .count,
    index: usize = 0,
    child_index: usize = 0,
    total: usize = 0,
    values: ?[]Value = null,
    destination: usize = 0,
    materializer: ?storage.ValueMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *RazeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        const count: usize = @intCast(self.collection.list.length());
        var budget = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .count => {
                if (self.index == count) {
                    self.values = try evaluator.allocator().alloc(Value, self.total);
                    self.index = 0;
                    self.phase = .fill;
                    continue;
                }
                const item = list.atUnchecked(self.collection, self.index);
                const contribution: usize = if (item == .list) @intCast(item.list.length()) else 1;
                self.total = std.math.add(usize, self.total, contribution) catch
                    return evaluator.fail(.overflow, "raze result is too large");
                self.index += 1;
                budget -= 1;
            },
            .fill => {
                if (self.index == count) {
                    self.materializer = .init(evaluator.allocator(), self.values.?);
                    self.phase = .materialize;
                    continue;
                }
                const item = list.atUnchecked(self.collection, self.index);
                if (item != .list) {
                    self.values.?[self.destination] = item;
                    self.destination += 1;
                    self.index += 1;
                } else if (self.child_index == item.list.length()) {
                    self.child_index = 0;
                    self.index += 1;
                    continue;
                } else {
                    self.values.?[self.destination] = list.atUnchecked(item, self.child_index);
                    self.destination += 1;
                    self.child_index += 1;
                }
                budget -= 1;
            },
            .materialize => return switch (try self.materializer.?.advance(budget)) {
                .pending => .yielded,
                .complete => |result| completed: {
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    break :completed .completed;
                },
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *RazeDriver = @ptrCast(@alignCast(raw));
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.values) |values| allocator.free(values);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

fn catPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);
    if (left != .list or right != .list) return evaluator.typeError("two lists");
    const left_count: usize = @intCast(left.list.length());
    const right_count: usize = @intCast(right.list.length());
    if (left_count == 0 and right_count == 0 and (left.isString() or right.isString())) {
        return evaluator.pushOwned(try emptyLike(
            evaluator.allocator(),
            if (left.isString()) left else right,
        ));
    }
    try ListCopyDriver.installCat(evaluator, left, right, left_count, right_count);
    left_owned = false;
    right_owned = false;
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
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    if (count == 0) return evaluator.fail(.domain, "rest requires a non-empty list");
    if (count == 1) return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection));
    try ListCopyDriver.installOne(evaluator, collection, 1, count, false);
    collection_owned = false;
}

fn takePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const count_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), count_value);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
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
    const start = if (result_count == 0 or count_value.int >= 0)
        0
    else
        (source_count - (result_count % source_count)) % source_count;
    const state = try evaluator.allocator().create(TakeDriver);
    errdefer evaluator.allocator().destroy(state);
    const values = try evaluator.allocator().alloc(Value, result_count);
    errdefer evaluator.allocator().free(values);
    state.* = .{
        .collection = collection,
        .values = values,
        .source_index = start,
        .source_count = source_count,
        .materializer = storage.ValueMaterializer.init(evaluator.allocator(), values),
    };
    collection_owned = false;
    evaluator.installWorkDriver(state, TakeDriver.advance, TakeDriver.destroy);
}

const TakeDriver = struct {
    collection: Value,
    values: []Value,
    result_index: usize = 0,
    source_index: usize,
    source_count: usize,
    materializing: bool = false,
    materializer: storage.ValueMaterializer,

    fn advance(
        evaluator: *Machine,
        raw: *anyopaque,
    ) MachineError!machine.WorkProgress {
        const self: *TakeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget = machine.kernel_poll_quantum;
        while (!self.materializing and budget != 0 and self.result_index < self.values.len) {
            self.values[self.result_index] = list.atUnchecked(self.collection, self.source_index);
            self.result_index += 1;
            self.source_index += 1;
            if (self.source_index == self.source_count) self.source_index = 0;
            budget -= 1;
        }
        if (self.result_index != self.values.len) return .yielded;
        self.materializing = true;
        if (budget == 0) return .yielded;
        return switch (try self.materializer.advance(budget)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *TakeDriver = @ptrCast(@alignCast(raw));
        self.materializer.deinit();
        allocator.free(self.values);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

fn dropPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const count_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), count_value);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list or count_value != .int) {
        return evaluator.typeError("a list and an integer count");
    }
    const count: usize = @intCast(collection.list.length());
    const magnitude: usize = @intCast(@min(unsignedMagnitude(count_value.int), count));
    const bounds: struct { start: usize, end: usize } = if (count_value.int >= 0)
        .{ .start = magnitude, .end = count }
    else
        .{ .start = 0, .end = count - magnitude };
    if (bounds.start == bounds.end)
        return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection));
    try ListCopyDriver.installOne(evaluator, collection, bounds.start, bounds.end, false);
    collection_owned = false;
}

fn reversePrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const count: usize = @intCast(collection.list.length());
    if (count == 0) return evaluator.pushOwned(try emptyLike(evaluator.allocator(), collection));
    try ListCopyDriver.installOne(evaluator, collection, 0, count, true);
    collection_owned = false;
}

const ListCopyDriver = struct {
    left: Value,
    right: ?Value = null,
    start: usize,
    end: usize,
    left_count: usize = 0,
    reverse: bool = false,
    values: []Value,
    index: usize = 0,
    materializer: storage.ValueMaterializer,

    fn installOne(
        evaluator: *Machine,
        collection: Value,
        start: usize,
        end: usize,
        reverse: bool,
    ) error{OutOfMemory}!void {
        const values = try evaluator.allocator().alloc(Value, end - start);
        errdefer evaluator.allocator().free(values);
        const driver = try evaluator.allocator().create(ListCopyDriver);
        driver.* = .{
            .left = collection,
            .start = start,
            .end = end,
            .reverse = reverse,
            .values = values,
            .materializer = .init(evaluator.allocator(), values),
        };
        evaluator.installWorkDriver(driver, ListCopyDriver.advance, ListCopyDriver.destroy);
    }

    fn installCat(
        evaluator: *Machine,
        left: Value,
        right: Value,
        left_count: usize,
        right_count: usize,
    ) error{OutOfMemory}!void {
        const values = try evaluator.allocator().alloc(Value, left_count + right_count);
        errdefer evaluator.allocator().free(values);
        const driver = try evaluator.allocator().create(ListCopyDriver);
        driver.* = .{
            .left = left,
            .right = right,
            .start = 0,
            .end = left_count + right_count,
            .left_count = left_count,
            .values = values,
            .materializer = .init(evaluator.allocator(), values),
        };
        evaluator.installWorkDriver(driver, ListCopyDriver.advance, ListCopyDriver.destroy);
    }

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ListCopyDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget = machine.kernel_poll_quantum;
        while (budget != 0 and self.index != self.values.len) : (budget -= 1) {
            if (self.right) |right| {
                self.values[self.index] = if (self.index < self.left_count)
                    list.atUnchecked(self.left, self.index)
                else
                    list.atUnchecked(right, self.index - self.left_count);
            } else {
                const source = if (self.reverse) self.end - self.index - 1 else self.start + self.index;
                self.values[self.index] = list.atUnchecked(self.left, source);
            }
            self.index += 1;
        }
        if (self.index != self.values.len or budget == 0) return .yielded;
        return switch (try self.materializer.advance(budget)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ListCopyDriver = @ptrCast(@alignCast(raw));
        self.materializer.deinit();
        allocator.free(self.values);
        heap.releaseValue(allocator, self.left);
        if (self.right) |right| heap.releaseValue(allocator, right);
        allocator.destroy(self);
    }
};

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
    errdefer evaluator.allocator().free(values);
    const driver = try evaluator.allocator().create(RangeDriver);
    driver.* = .{
        .values = values,
        .materializer = .init(evaluator.allocator(), values),
    };
    evaluator.installWorkDriver(driver, RangeDriver.advance, RangeDriver.destroy);
}

const RangeDriver = struct {
    values: []i64,
    index: usize = 0,
    materializer: storage.I64Materializer,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *RangeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        const end = @min(self.index + machine.kernel_poll_quantum, self.values.len);
        while (self.index != end) : (self.index += 1)
            self.values[self.index] = @intCast(self.index);
        if (self.index != self.values.len) return .yielded;
        return switch (try self.materializer.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *RangeDriver = @ptrCast(@alignCast(raw));
        self.materializer.deinit();
        allocator.free(self.values);
        allocator.destroy(self);
    }
};

fn lenPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    try evaluator.pushOwned(.{ .int = @intCast(collection.list.length()) });
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

    fn deinit(self: *ShapeCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }

    fn advance(self: *ShapeCursor, budget: usize) error{OutOfMemory}!ShapeProgress {
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
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const driver = try evaluator.allocator().create(ShapeDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{ .collection = collection, .cursor = try .init(evaluator.allocator(), collection) };
    collection_owned = false;
    evaluator.installWorkDriver(driver, ShapeDriver.advance, ShapeDriver.destroy);
}

const ShapeDriver = struct {
    collection: Value,
    cursor: ShapeCursor,
    dimensions: ?[]usize = null,
    values: ?[]i64 = null,
    materializer: ?storage.I64Materializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ShapeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        if (self.materializer == null) {
            if (self.dimensions == null) switch (try self.cursor.advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .ragged => return evaluator.fail(.shape, "shape requires a rectangular list"),
                .too_deep => return evaluator.fail(.shape, "shape nesting exceeds 256 levels"),
                .complete => |dimensions| self.dimensions = dimensions,
            };
            const values = try evaluator.allocator().alloc(i64, self.dimensions.?.len);
            for (self.dimensions.?, values) |dimension, *destination| destination.* = @intCast(dimension);
            self.values = values;
            self.materializer = .init(evaluator.allocator(), values);
            return .yielded;
        }
        return switch (try self.materializer.?.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ShapeDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.values) |values| allocator.free(values);
        if (self.dimensions) |dimensions| allocator.free(dimensions);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

fn flipPrimitive(evaluator: *Machine) MachineError!void {
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a rectangular list");
    const driver = try evaluator.allocator().create(FlipDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{ .collection = collection, .shape = try .init(evaluator.allocator(), collection) };
    collection_owned = false;
    evaluator.installWorkDriver(driver, FlipDriver.advance, FlipDriver.destroy);
}

const FlipDriver = struct {
    collection: Value,
    shape: ShapeCursor,
    dimensions: ?[]usize = null,
    rows: usize = 0,
    columns: usize = 0,
    result_rows: ?[]Value = null,
    cells: ?[]Value = null,
    column: usize = 0,
    row: usize = 0,
    initialized: usize = 0,
    inner: ?storage.ValueMaterializer = null,
    outer: ?storage.ValueMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *FlipDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        if (self.dimensions == null) switch (try self.shape.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .ragged => return evaluator.fail(.shape, "flip requires a rectangular list"),
            .too_deep => return evaluator.fail(.shape, "flip nesting exceeds 256 levels"),
            .complete => |dimensions| {
                self.dimensions = dimensions;
                if (dimensions.len <= 1) {
                    try evaluator.pushBorrowed(self.collection);
                    return .completed;
                }
                self.rows = dimensions[0];
                self.columns = dimensions[1];
                if (self.columns == 0 and self.rows != 0) return evaluator.fail(
                    .shape,
                    "flip cannot retain trailing axes after a transposed zero dimension",
                );
                self.result_rows = try evaluator.allocator().alloc(Value, self.columns);
                self.cells = try evaluator.allocator().alloc(Value, self.rows);
                return .yielded;
            },
        };
        if (self.outer) |*outer| return switch (try outer.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
        if (self.inner) |*inner| switch (try inner.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |row_value| {
                inner.deinit();
                self.inner = null;
                self.result_rows.?[self.column] = row_value;
                self.initialized += 1;
                self.column += 1;
                self.row = 0;
                if (self.column == self.columns) {
                    self.outer = .init(evaluator.allocator(), self.result_rows.?);
                }
                return .yielded;
            },
        };
        const end = @min(self.row + machine.kernel_poll_quantum, self.rows);
        while (self.row != end) : (self.row += 1) {
            const source_row = list.atUnchecked(self.collection, self.row);
            self.cells.?[self.row] = list.atUnchecked(source_row, self.column);
        }
        if (self.row == self.rows) self.inner = .init(evaluator.allocator(), self.cells.?);
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *FlipDriver = @ptrCast(@alignCast(raw));
        self.shape.deinit();
        if (self.inner) |*inner| inner.deinit();
        if (self.outer) |*outer| outer.deinit();
        if (self.result_rows) |rows| {
            for (rows[0..self.initialized]) |row| heap.releaseValue(allocator, row);
            allocator.free(rows);
        }
        if (self.cells) |cells| allocator.free(cells);
        if (self.dimensions) |dimensions| allocator.free(dimensions);
        heap.releaseValue(allocator, self.collection);
        allocator.destroy(self);
    }
};

fn reshapePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const shape_value = try evaluator.popOwned();
    var shape_owned = true;
    defer if (shape_owned) heap.releaseValue(evaluator.allocator(), shape_value);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list or shape_value != .list) {
        return evaluator.typeError("a list and a non-empty integer shape");
    }
    const rank: usize = @intCast(shape_value.list.length());
    if (rank == 0) return evaluator.fail(.shape, "reshape requires a non-empty shape");
    if (rank > support.max_depth) return evaluator.fail(.shape, "reshape rank exceeds 256");
    const dimensions = try evaluator.allocator().alloc(usize, rank);
    errdefer evaluator.allocator().free(dimensions);
    const driver = try evaluator.allocator().create(ReshapeDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .collection = collection,
        .shape_value = shape_value,
        .dimensions = dimensions,
        .ravel = try .init(evaluator.allocator(), collection, null),
    };
    collection_owned = false;
    shape_owned = false;
    evaluator.installWorkDriver(driver, ReshapeDriver.advance, ReshapeDriver.destroy);
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
    fn deinit(self: *RavelCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }
    fn advance(self: *RavelCursor, budget: usize) error{OutOfMemory}!RavelProgress {
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
        values: []Value,
        index: usize = 0,
        waiting: bool = false,
        materializer: ?storage.ValueMaterializer = null,
        result: ?Value = null,
        release_index: usize = 0,
    };
    allocator: std.mem.Allocator,
    dimensions: []const usize,
    flat: []const Value,
    frames: @import("poll.zig").ChunkStack(Frame),
    flat_index: usize = 0,
    last: ?Value = null,

    fn init(allocator: std.mem.Allocator, dimensions: []const usize, flat: []const Value) error{OutOfMemory}!ReshapeBuildCursor {
        var frames = @import("poll.zig").ChunkStack(Frame).init(allocator);
        errdefer frames.deinit();
        const values = try allocator.alloc(Value, dimensions[0]);
        errdefer allocator.free(values);
        try frames.push(.{ .axis = 0, .values = values });
        return .{ .allocator = allocator, .dimensions = dimensions, .flat = flat, .frames = frames };
    }
    fn deinit(self: *ReshapeBuildCursor) void {
        if (self.last) |last| heap.releaseValue(self.allocator, last);
        while (self.frames.pop()) |frame| self.deinitFrame(frame);
        self.frames.deinit();
        self.* = undefined;
    }
    fn deinitFrame(self: *ReshapeBuildCursor, frame_value: Frame) void {
        var frame = frame_value;
        if (frame.materializer) |*materializer| materializer.deinit();
        if (frame.axis + 1 < self.dimensions.len)
            releaseValues(self.allocator, frame.values[frame.release_index..frame.index]);
        self.allocator.free(frame.values);
        if (frame.result) |result| heap.releaseValue(self.allocator, result);
    }
    fn advance(self: *ReshapeBuildCursor, budget: usize) error{OutOfMemory}!PervadeResult {
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
                if (owns_children and frame.release_index != frame.index) {
                    heap.releaseValue(self.allocator, frame.values[frame.release_index]);
                    frame.release_index += 1;
                    try self.frames.reserve(1);
                    try self.frames.push(frame);
                    continue;
                }
                self.allocator.free(frame.values);
                frame.result = null;
                self.last = result;
                continue;
            }
            if (frame.waiting) {
                frame.values[frame.index] = self.last.?;
                self.last = null;
                frame.index += 1;
                frame.waiting = false;
            }
            if (frame.index != frame.values.len) {
                if (!owns_children) {
                    frame.values[frame.index] = self.flat[self.flat_index % self.flat.len];
                    self.flat_index += 1;
                    frame.index += 1;
                    try self.frames.reserve(1);
                    try self.frames.push(frame);
                    continue;
                }
                frame.waiting = true;
                const child_values = try self.allocator.alloc(Value, self.dimensions[frame.axis + 1]);
                errdefer self.allocator.free(child_values);
                try self.frames.reserve(2);
                try self.frames.push(frame);
                try self.frames.push(.{ .axis = frame.axis + 1, .values = child_values });
                continue;
            }
            if (frame.materializer == null) frame.materializer = .init(self.allocator, frame.values);
            try self.frames.reserve(1);
            switch (try frame.materializer.?.advance(remaining)) {
                .pending => {
                    try self.frames.push(frame);
                    return .pending;
                },
                .complete => |result| {
                    frame.result = result;
                    try self.frames.push(frame);
                    return .pending;
                },
            }
        }
        return .pending;
    }
};

const PervadeResult = union(enum) { pending, complete: Value };

const ReshapeDriver = struct {
    collection: Value,
    shape_value: Value,
    dimensions: []usize,
    dimension_index: usize = 0,
    volume: usize = 1,
    ravel: RavelCursor,
    flat: ?[]Value = null,
    ravel_filling: bool = false,
    builder: ?ReshapeBuildCursor = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ReshapeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        if (self.dimension_index != self.dimensions.len) {
            const end = @min(self.dimension_index + machine.kernel_poll_quantum, self.dimensions.len);
            while (self.dimension_index != end) : (self.dimension_index += 1) {
                const dimension = list.atUnchecked(self.shape_value, self.dimension_index);
                if (dimension != .int) return evaluator.typeError("an integer shape");
                if (dimension.int < 0) return evaluator.failAtIndex(
                    .shape,
                    "reshape dimensions must be non-negative",
                    self.dimension_index,
                );
                self.dimensions[self.dimension_index] = std.math.cast(usize, dimension.int) orelse
                    return evaluator.failAtIndex(
                        .overflow,
                        "reshape dimension exceeds addressable size",
                        self.dimension_index,
                    );
                if (self.dimensions[self.dimension_index] == 0 and
                    self.dimension_index + 1 < self.dimensions.len)
                    return evaluator.failAtIndex(
                        .shape,
                        "reshape cannot retain axes after a zero dimension",
                        self.dimension_index,
                    );
                self.volume = std.math.mul(usize, self.volume, self.dimensions[self.dimension_index]) catch
                    return evaluator.fail(.overflow, "reshape volume overflows addressable size");
            }
            return .yielded;
        }
        if (self.builder) |*builder| return switch (try builder.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| completed: {
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
        switch (try self.ravel.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .too_deep => return evaluator.fail(.shape, "reshape data nesting exceeds 256 levels"),
            .complete => |count| if (!self.ravel_filling) {
                self.flat = try evaluator.allocator().alloc(Value, count);
                var next = try RavelCursor.init(evaluator.allocator(), self.collection, self.flat);
                errdefer next.deinit();
                self.ravel.deinit();
                self.ravel = next;
                self.ravel_filling = true;
                return .yielded;
            } else {
                std.debug.assert(count == self.flat.?.len);
                if (self.volume > 0 and count == 0) return evaluator.fail(
                    .domain,
                    "reshape cannot fill a non-empty shape from empty data",
                );
                self.builder = try .init(evaluator.allocator(), self.dimensions, self.flat.?);
                return .yielded;
            },
        }
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ReshapeDriver = @ptrCast(@alignCast(raw));
        self.ravel.deinit();
        if (self.builder) |*builder| builder.deinit();
        if (self.flat) |flat| allocator.free(flat);
        allocator.free(self.dimensions);
        heap.releaseValue(allocator, self.collection);
        heap.releaseValue(allocator, self.shape_value);
        allocator.destroy(self);
    }
};

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
