//! Immutable dict operations and Unicode-codepoint text kernels.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");
const kernel_flat = @import("kernel_flat.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

/// The sized-operation taxonomy lives in `kernel_support` so the registry in
/// `kernels.zig` classifies exactly the operations this installer publishes.
const Op = support.TextOp;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (std.meta.fields(Op)) |field| {
        const operation: Op = @enumFromInt(field.value);
        try support.installPrimitive(core, operation.spelling(), bind(operation));
    }
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return switch (operation) {
                .keys => keysPrimitive(evaluator),
                .put => putPrimitive(evaluator),
                .to_dict => toDictPrimitive(evaluator),
                .del => delPrimitive(evaluator),
                .merge => mergePrimitive(evaluator),
                .has => hasPrimitive(evaluator),
                .split => splitPrimitive(evaluator),
                .join => joinPrimitive(evaluator),
                .str => strPrimitive(evaluator),
                .format => formatPrimitive(evaluator),
            };
        }
    }.run;
}

fn strPrimitive(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const renderer = try printer.OwnedStringCursor.init(evaluator.allocator(), item.borrow());
    try evaluator.startDriver(StrDriver{
        .item = .init(item.take()),
        .work = .init(.{ .rendering = renderer }),
    });
}

const StrPhase = union(enum) {
    rendering: printer.OwnedStringCursor,
    materializing: struct {
        bytes: []u8,
        cursor: storage.Utf8Materializer,
    },
    complete,

    pub fn retire(
        self: *StrPhase,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .rendering => |*renderer| renderer.deinit(),
            .materializing => |*materializing| {
                materializing.cursor.retire(releases);
                allocator.free(materializing.bytes);
            },
            .complete => {},
        }
        self.* = .complete;
    }
};

const StrDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    pub const inline_driver = true;
    item: heap.Owned(Value),
    work: heap.Owned(StrPhase),

    pub fn advance(evaluator: *Machine, self: *StrDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const phase = self.work.borrowMut();
        return switch (phase.*) {
            .rendering => |*renderer| switch (try renderer.advance(machine.kernel_poll_quantum)) {
                .pending => .yielded,
                .complete => |bytes| transitioned: {
                    renderer.deinit();
                    phase.* = .{ .materializing = .{
                        .bytes = bytes,
                        .cursor = .init(evaluator.allocator(), bytes),
                    } };
                    break :transitioned .yielded;
                },
            },
            .materializing => |*materializing| switch (materializing.cursor.advance(
                machine.kernel_poll_quantum,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return evaluator.fail(
                    .domain,
                    "canonical rendering is not valid UTF-8",
                ),
            }) {
                .pending => .yielded,
                .complete => |result| completed: {
                    materializing.cursor.deinit();
                    evaluator.allocator().free(materializing.bytes);
                    phase.* = .complete;
                    break :completed .{ .output = result };
                },
            },
            .complete => unreachable,
        };
    }
};

fn keysPrimitive(evaluator: *Machine) MachineError!void {
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const keys = dict.keysOf(dictionary.borrow().dict);
    try evaluator.pushBorrowed(keys);
}

fn valsPrimitive(evaluator: *Machine) MachineError!void {
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const values = dict.valsOf(dictionary.borrow().dict);
    try evaluator.pushBorrowed(values);
}

pub fn valsForIdiom(evaluator: *Machine) MachineError!void {
    return valsPrimitive(evaluator);
}

fn hasPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var key = try evaluator.popValue();
    defer key.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const cursor = storage.DictFindCursor.initHeader(
        evaluator.allocator(),
        dictionary.borrow().dict,
        key.borrow(),
    );
    try evaluator.startDriver(HasDriver{
        .dictionary = .init(dictionary.take()),
        .key = .init(key.take()),
        .cursor = .init(cursor),
    });
}

const HasDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// Searching a dict is bounded work over however many entries it has, so
    /// the driver is earned; its creation is not. `DictFindCursor` already
    /// allocates nothing for a key without structure, which left this as the
    /// only cost of asking whether a dict holds a symbol.
    pub const inline_driver = true;
    dictionary: heap.Owned(Value),
    key: heap.Owned(Value),
    cursor: heap.Owned(storage.DictFindCursor),

    pub fn advance(evaluator: *Machine, self: *HasDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |found| .{ .output = .{ .int = @intFromBool(found != null) } },
        };
    }
};

fn putPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var new_value = try evaluator.popValue();
    defer new_value.deinit();
    var key = try evaluator.popValue();
    defer key.deinit();
    var collection = try evaluator.popValue();
    defer collection.deinit();
    switch (collection.borrow()) {
        .dict => {
            const finder = storage.DictFindCursor.initHeader(
                evaluator.allocator(),
                collection.borrow().dict,
                key.borrow(),
            );
            try evaluator.startDriver(DictPutDriver{
                .dictionary = .init(collection.take()),
                .key = .init(key.take()),
                .new_value = .init(new_value.take()),
                .work = .init(.{ .finding = finder }),
            });
        },
        .list => {
            if (key.borrow() != .int) return evaluator.typeError("an integer list index");
            if (key.borrow().int < 0) return evaluator.fail(.domain, "put index is negative");
            const index = std.math.cast(usize, key.borrow().int) orelse
                return evaluator.fail(.domain, "put index is out of bounds");
            const count: usize = @intCast(collection.borrow().list.length());
            if (index >= count) return evaluator.fail(.domain, "put index is out of bounds");
            if (try startTypedListPut(
                evaluator,
                &collection,
                new_value.borrow(),
                index,
                count,
            )) return;
            const values = try evaluator.allocator().alloc(Value, count);
            try evaluator.startDriver(ListPutDriver{
                .collection = .init(collection.take()),
                .key = .init(key.take()),
                .new_value = .init(new_value.take()),
                .replace_index = index,
                .values = .init(values),
            });
        },
        .int, .float, .char, .symbol, .word, .task, .module => return evaluator.typeError("a list or dict"),
    }
}

const put_leaf_kinds = [_]value.HeapKind{
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
    .leaf_symbol,
};

fn typedReplacement(comptime kind: value.HeapKind, item: Value) ?heap.LeafElement(kind) {
    return switch (kind) {
        .leaf_i64 => switch (item) {
            .int => |number| number,
            else => null,
        },
        .leaf_f64 => switch (item) {
            .float => |number| number,
            else => null,
        },
        .leaf_char1 => switch (item) {
            .char => |codepoint| std.math.cast(u8, codepoint),
            else => null,
        },
        .leaf_char2 => switch (item) {
            .char => |codepoint| std.math.cast(u16, codepoint),
            else => null,
        },
        .leaf_char4 => switch (item) {
            .char => |codepoint| codepoint,
            else => null,
        },
        .leaf_symbol => switch (item) {
            .symbol => |symbol| symbol,
            else => null,
        },
        .generic_spine, .dict, .task, .module, .reserved_mask => unreachable,
    };
}

fn TypedListPutDriver(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        source: heap.Owned(heap.LeafReader(kind)),
        writer: heap.Owned(heap.LeafWriter(kind)),
        replacement: Element,
        replace_index: usize,
        cursor: kernel_flat.FlatCursor,

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            if (try self.cursor.nextRange(context)) |range| {
                const source = self.source.borrow().slice();
                var block: [kernel_flat.block_size]Element = undefined;
                var offset: usize = 0;
                while (offset != range.len()) {
                    const piece = kernel_flat.blockRange(range, offset);
                    @memcpy(block[0..piece.len()], source[piece.start..piece.end]);
                    if (self.replace_index >= piece.start and self.replace_index < piece.end) {
                        block[self.replace_index - piece.start] = self.replacement;
                    }
                    self.writer.borrowMut().writeRange(piece.start, block[0..piece.len()]);
                    offset += piece.len();
                }
            }
            if (!self.cursor.complete()) return .yielded;
            self.source.deinit(evaluator.releaseDomain(), evaluator.allocator());
            return .{ .output = self.writer.borrowMut().finish() };
        }
    };
}

/// Same-kind leaf replacement is either one store under a heap-issued unique
/// authority or one exact-size typed copy. A value that changes the leaf class
/// deliberately returns false so the profiling path can widen its result.
fn startTypedListPut(
    evaluator: *Machine,
    collection: *heap.OwnedValue,
    new_value: Value,
    replace_index: usize,
    count: usize,
) MachineError!bool {
    const kind = collection.borrow().list.kind();
    if (kind == .generic_spine) return false;
    inline for (put_leaf_kinds) |candidate| {
        if (kind == candidate) {
            const replacement = typedReplacement(candidate, new_value) orelse return false;
            if (heap.UniqueLeafAdoption(candidate).claim(collection.borrow().list, count)) |claim| {
                var adoption = claim;
                adoption.writeRange(replace_index, &.{replacement});
                _ = collection.take();
                var result = heap.OwnedValue.init(evaluator.releaseDomain(), adoption.finish());
                defer result.deinit();
                try evaluator.pushOwned(result.take());
                return true;
            }

            const Driver = TypedListPutDriver(candidate);
            var writer = try heap.LeafWriter(candidate).init(evaluator.allocator(), count);
            var held_locally = true;
            errdefer if (held_locally) writer.retirePartial(evaluator.releaseDomain());
            const driver = Driver{
                .source = .init(heap.LeafReader(candidate).acquire(collection.borrow().list)),
                .writer = .init(writer),
                .replacement = replacement,
                .replace_index = replace_index,
                .cursor = kernel_flat.FlatCursor.init(count),
            };
            held_locally = false;
            try evaluator.startDriver(driver);
            return true;
        }
    }
    unreachable;
}

const ListPutDriver = struct {
    /// One list rebuilt around a replaced element, then it publishes.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    key: heap.Owned(Value),
    new_value: heap.Owned(Value),
    replace_index: usize,
    values: heap.Owned([]Value),
    index: usize = 0,
    materializer: ?heap.Owned(storage.ValueMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *ListPutDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.materializer == null) {
            const values = self.values.borrow();
            const end = @min(self.index + budget, values.len);
            const copied = end - self.index;
            while (self.index != end) : (self.index += 1) values[self.index] =
                if (self.index == self.replace_index)
                    self.new_value.borrow()
                else
                    list.atUnchecked(self.collection.borrow(), self.index);
            budget -= copied;
            if (self.index != values.len) return .yielded;
            self.materializer = .init(storage.ValueMaterializer.init(evaluator.allocator(), values));
        }
        if (budget == 0) return .yielded;
        return switch (try self.materializer.?.borrowMut().advance(budget)) {
            .pending => .yielded,
            .complete => |result| completed: {
                self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.materializer = null;
                break :completed .{ .output = result };
            },
        };
    }
};

/// The two phases a dict rebuild passes through. They never overlap: the
/// finder locates the key and is retired before anything is materialized, and
/// the materializer is built only after it is gone. Holding a field for each
/// reserved both at once in every driver that rebuilds a dict -- 248 bytes for
/// the finder and 288 for the materializer, in drivers that measured 656 to
/// 688 -- for state that is live in one phase or the other and never both.
const RebuildPhase = union(enum) {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    finding: storage.DictFindCursor,
    materializing: storage.DictMaterializer,
    between,

    pub fn retire(self: *RebuildPhase, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .finding => |*cursor| cursor.deinit(),
            .materializing => |*materializer| materializer.retire(releases),
            .between => {},
        }
        self.* = .between;
    }

    fn finish(self: *RebuildPhase, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
};

const DictPutDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// One dict rebuild, then it publishes: short-lived, so it takes the slot
    /// without holding it across anything else.
    pub const inline_driver = true;
    dictionary: heap.Owned(Value),
    key: heap.Owned(Value),
    new_value: heap.Owned(Value),
    work: heap.Owned(RebuildPhase),
    found_index: ?usize = null,
    pairs: ?heap.Owned([]dict.Pair) = null,
    index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *DictPutDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.work.borrowMut().* == .finding) switch (try self.work.borrowMut().finding.advance(budget)) {
            .pending => return .yielded,
            .complete => {
                self.found_index = self.work.borrowMut().finding.foundIndex();
                self.work.borrowMut().finish(evaluator.releaseDomain());
                const old_count: usize = @intCast(self.dictionary.borrow().dict.length());
                self.pairs = .init(try evaluator.allocator().alloc(
                    dict.Pair,
                    old_count + @intFromBool(self.found_index == null),
                ));
                return .yielded;
            },
        };
        if (self.work.borrowMut().* != .materializing) {
            const old_count: usize = @intCast(self.dictionary.borrow().dict.length());
            const pairs = self.pairs.?.borrow();
            const end = @min(self.index + budget, pairs.len);
            const copied = end - self.index;
            while (self.index != end) : (self.index += 1) {
                if (self.index == old_count) {
                    pairs[self.index] = .{ self.key.borrow(), self.new_value.borrow() };
                } else {
                    pairs[self.index] = .{
                        dict.keyAt(self.dictionary.borrow().dict, self.index),
                        if (self.found_index == self.index)
                            self.new_value.borrow()
                        else
                            dict.valueAt(self.dictionary.borrow().dict, self.index),
                    };
                }
            }
            budget -= copied;
            if (self.index != pairs.len) return .yielded;
            self.work.borrowMut().* = .{
                .materializing = try .init(evaluator.allocator(), pairs, false),
            };
        }
        if (budget == 0) return .yielded;
        return switch (try self.work.borrowMut().materializing.advance(budget)) {
            .pending => .yielded,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.work.borrowMut().finish(evaluator.releaseDomain());
                break :completed .{ .output = result };
            },
        };
    }
};

fn toDictPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var values = try evaluator.popValue();
    defer values.deinit();
    var keys = try evaluator.popValue();
    defer keys.deinit();
    if (keys.borrow() != .list or values.borrow() != .list) return evaluator.typeError("two lists");
    const count: usize = @intCast(keys.borrow().list.length());
    if (values.borrow().list.length() != keys.borrow().list.length()) {
        return evaluator.fail(.shape, "to-dict requires equal key and value lengths");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count);
    try evaluator.startDriver(ToDictDriver{
        .keys = .init(keys.take()),
        .values = .init(values.take()),
        .pairs = .init(pairs),
    });
}

const ToDictDriver = struct {
    /// One dict built from two lists, then it publishes.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;
    keys: heap.Owned(Value),
    values: heap.Owned(Value),
    pairs: heap.Owned([]dict.Pair),
    index: usize = 0,
    materializer: ?heap.Owned(storage.DictMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *ToDictDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.materializer == null) {
            const pairs = self.pairs.borrow();
            const end = @min(self.index + budget, pairs.len);
            const copied = end - self.index;
            while (self.index != end) : (self.index += 1) pairs[self.index] = .{
                list.atUnchecked(self.keys.borrow(), self.index),
                list.atUnchecked(self.values.borrow(), self.index),
            };
            budget -= copied;
            if (self.index != pairs.len or budget == 0) return .yielded;
            self.materializer = .init(try .init(evaluator.allocator(), pairs, true));
        }
        return switch (try self.materializer.?.borrowMut().advance(budget)) {
            .pending => .yielded,
            .duplicate_key => evaluator.fail(.domain, "to-dict keys must be distinct"),
            .complete => |result| completed: {
                self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.materializer = null;
                break :completed .{ .output = result };
            },
        };
    }
};

fn delPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var key = try evaluator.popValue();
    defer key.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const finder = storage.DictFindCursor.initHeader(
        evaluator.allocator(),
        dictionary.borrow().dict,
        key.borrow(),
    );
    try evaluator.startDriver(DelDriver{
        .dictionary = .init(dictionary.take()),
        .key = .init(key.take()),
        .work = .init(.{ .finding = finder }),
    });
}

const DelDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// One dict rebuild, then it publishes: short-lived, so it takes the slot
    /// without holding it across anything else.
    pub const inline_driver = true;
    dictionary: heap.Owned(Value),
    key: heap.Owned(Value),
    work: heap.Owned(RebuildPhase),
    removed_index: ?usize = null,
    pairs: ?heap.Owned([]dict.Pair) = null,
    source_index: usize = 0,
    destination_index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *DelDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.work.borrowMut().* == .finding) switch (try self.work.borrowMut().finding.advance(budget)) {
            .pending => return .yielded,
            .complete => {
                self.removed_index = self.work.borrowMut().finding.foundIndex();
                self.work.borrowMut().finish(evaluator.releaseDomain());
                if (self.removed_index == null) {
                    heap.retainValue(self.dictionary.borrow());
                    return .{ .output = self.dictionary.borrow() };
                }
                const count: usize = @intCast(self.dictionary.borrow().dict.length());
                self.pairs = .init(try evaluator.allocator().alloc(dict.Pair, count - 1));
                return .yielded;
            },
        };
        if (self.work.borrowMut().* != .materializing) {
            const count: usize = @intCast(self.dictionary.borrow().dict.length());
            while (budget != 0 and self.source_index != count) : (self.source_index += 1) {
                if (self.source_index != self.removed_index.?) {
                    self.pairs.?.borrow()[self.destination_index] = .{
                        dict.keyAt(self.dictionary.borrow().dict, self.source_index),
                        dict.valueAt(self.dictionary.borrow().dict, self.source_index),
                    };
                    self.destination_index += 1;
                }
                budget -= 1;
            }
            if (self.source_index != count or budget == 0) return .yielded;
            self.work.borrowMut().* = .{ .materializing = try .init(
                evaluator.allocator(),
                self.pairs.?.borrow(),
                false,
            ) };
        }
        return switch (try self.work.borrowMut().materializing.advance(budget)) {
            .pending => .yielded,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.work.borrowMut().finish(evaluator.releaseDomain());
                break :completed .{ .output = result };
            },
        };
    }
};

fn mergePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    if (left.borrow() != .dict or right.borrow() != .dict) return evaluator.typeError("two dicts");
    const left_count: usize = @intCast(left.borrow().dict.length());
    const right_count: usize = @intCast(right.borrow().dict.length());
    const pairs = try evaluator.allocator().alloc(dict.Pair, left_count + right_count);
    try evaluator.startDriver(MergeDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .pairs = .init(pairs),
        .pair_count = left_count,
    });
}

const MergeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// One dict rebuild, then it publishes: short-lived, so it takes the slot
    /// without holding it across anything else.
    pub const inline_driver = true;
    left: heap.Owned(Value),
    right: heap.Owned(Value),
    pairs: heap.Owned([]dict.Pair),
    pair_count: usize,
    phase: enum { copy_left, merge_right, materialize } = .copy_left,
    index: usize = 0,
    work: heap.Owned(RebuildPhase) = .init(.between),

    pub fn advance(evaluator: *Machine, self: *MergeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .copy_left => {
                const count: usize = @intCast(self.left.borrow().dict.length());
                if (self.index == count) {
                    self.phase = .merge_right;
                    self.index = 0;
                    continue;
                }
                self.pairs.borrow()[self.index] = .{
                    dict.keyAt(self.left.borrow().dict, self.index),
                    dict.valueAt(self.left.borrow().dict, self.index),
                };
                self.index += 1;
                budget -= 1;
            },
            .merge_right => {
                const count: usize = @intCast(self.right.borrow().dict.length());
                if (self.index == count) {
                    self.work.borrowMut().* = .{ .materializing = try storage.DictMaterializer.init(
                        evaluator.allocator(),
                        self.pairs.borrow()[0..self.pair_count],
                        false,
                    ) };
                    self.phase = .materialize;
                    continue;
                }
                const key = dict.keyAt(self.right.borrow().dict, self.index);
                if (self.work.borrowMut().* != .finding) self.work.borrowMut().* = .{
                    .finding = storage.DictFindCursor.initHeader(
                        evaluator.allocator(),
                        self.left.borrow().dict,
                        key,
                    ),
                };
                switch (try self.work.borrowMut().finding.advance(1)) {
                    .pending => budget -= 1,
                    .complete => {
                        const found = self.work.borrowMut().finding.foundIndex();
                        self.work.borrowMut().finish(evaluator.releaseDomain());
                        const pair = dict.Pair{ key, dict.valueAt(self.right.borrow().dict, self.index) };
                        if (found) |destination| {
                            self.pairs.borrow()[destination][1] = pair[1];
                        } else {
                            self.pairs.borrow()[self.pair_count] = pair;
                            self.pair_count += 1;
                        }
                        self.index += 1;
                        budget -= 1;
                    },
                }
            },
            .materialize => return switch (try self.work.borrowMut().materializing.advance(budget)) {
                .pending => .yielded,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    self.work.borrowMut().finish(evaluator.releaseDomain());
                    break :completed .{ .output = result };
                },
            },
        };
        return .yielded;
    }
};

fn splitPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var separator = try evaluator.popValue();
    defer separator.deinit();
    var text = try evaluator.popValue();
    defer text.deinit();
    if (!text.borrow().isString() or !separator.borrow().isString()) return evaluator.typeError("two strings");
    const text_len: usize = @intCast(text.borrow().list.length());
    const separator_len: usize = @intCast(separator.borrow().list.length());
    const capacity = if (separator_len == 0) text_len else text_len + 1;
    const parts = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), capacity);
    const text_kind = text.borrow().list.kind();
    const separator_kind = separator.borrow().list.kind();
    inline for (char_leaf_kinds) |candidate_text| {
        if (text_kind == candidate_text) inline for (char_leaf_kinds) |candidate_separator| {
            if (separator_kind == candidate_separator) {
                const Driver = SplitDriver(candidate_text, candidate_separator);
                try evaluator.startDriver(Driver{
                    .text = .init(heap.LeafReader(candidate_text).acquire(text.borrow().list)),
                    .separator = .init(heap.LeafReader(candidate_separator).acquire(separator.borrow().list)),
                    .parts = .init(parts),
                });
                return;
            }
        };
    }
    unreachable;
}

const char_leaf_kinds = [_]value.HeapKind{ .leaf_char1, .leaf_char2, .leaf_char4 };

const AnyCharReader = union(enum) {
    char1: heap.LeafReader(.leaf_char1),
    char2: heap.LeafReader(.leaf_char2),
    char4: heap.LeafReader(.leaf_char4),

    pub const owned_disposal: heap.OwnedDisposal = .retire;

    fn acquire(string: Value) AnyCharReader {
        return switch (string.list.kind()) {
            .leaf_char1 => .{ .char1 = .acquire(string.list) },
            .leaf_char2 => .{ .char2 = .acquire(string.list) },
            .leaf_char4 => .{ .char4 = .acquire(string.list) },
            else => unreachable,
        };
    }

    fn len(self: *const AnyCharReader) usize {
        return switch (self.*) {
            inline else => |*reader| reader.len(),
        };
    }

    /// The representation switch happens once per bounded range, outside the
    /// copy loop; every loop body reads one monomorphic typed slice.
    fn copyCodepoints(self: *const AnyCharReader, start: usize, destination: []u32) void {
        switch (self.*) {
            inline else => |*reader| for (reader.slice()[start..][0..destination.len], destination) |codepoint, *out| {
                out.* = codepoint;
            },
        }
    }

    pub fn retire(self: *AnyCharReader, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            inline else => |*reader| reader.release(releases),
        }
    }
};

fn SplitDriver(comptime text_kind: value.HeapKind, comptime separator_kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        text: heap.Owned(heap.LeafReader(text_kind)),
        separator: heap.Owned(heap.LeafReader(separator_kind)),
        parts: heap.Owned(heap.OwnedValueBuffer),
        phase: enum { scan, profile_part, fill_part, materialize_result } = .scan,
        cursor: usize = 0,
        start: usize = 0,
        match_index: usize = 0,
        empty_part_index: usize = 0,
        scan_complete: bool = false,
        part_start: usize = 0,
        part_end: usize = 0,
        codepoint_index: usize = 0,
        part_max_codepoint: u32 = 0,
        part_writer: ?heap.Owned(kernel_flat.CodepointWriter) = null,
        result_materializer: ?heap.Owned(storage.ValueMaterializer) = null,

        fn beginPart(self: *Self, start: usize, end: usize) void {
            self.part_start = start;
            self.part_end = end;
            self.codepoint_index = 0;
            self.part_max_codepoint = 0;
            self.phase = .profile_part;
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            const context = support.Context{ .evaluator = evaluator };
            var budget = @max(context.remaining(), 1);
            try context.advance(budget);
            while (budget != 0) switch (self.phase) {
                .scan => {
                    const text_slice = self.text.borrow().slice();
                    const separator_slice = self.separator.borrow().slice();
                    const text_len = text_slice.len;
                    const separator_len = separator_slice.len;
                    if (self.scan_complete) {
                        self.result_materializer = .init(.init(
                            evaluator.allocator(),
                            self.parts.borrow().values(),
                        ));
                        self.phase = .materialize_result;
                        continue;
                    }
                    if (separator_len == 0) {
                        if (self.empty_part_index == text_len) {
                            self.scan_complete = true;
                            continue;
                        }
                        const part_index = self.empty_part_index;
                        self.empty_part_index += 1;
                        self.beginPart(part_index, part_index + 1);
                        continue;
                    }
                    if (self.cursor > text_len - @min(text_len, separator_len) or
                        separator_len > text_len - self.cursor)
                    {
                        self.scan_complete = true;
                        self.beginPart(self.start, text_len);
                        continue;
                    }
                    if (@as(u32, text_slice[self.cursor + self.match_index]) ==
                        @as(u32, separator_slice[self.match_index]))
                    {
                        self.match_index += 1;
                        if (self.match_index == separator_len) {
                            const match_start = self.cursor;
                            self.cursor += separator_len;
                            self.match_index = 0;
                            self.beginPart(self.start, match_start);
                            self.start = self.cursor;
                        }
                    } else {
                        self.cursor += 1;
                        self.match_index = 0;
                    }
                    budget -= 1;
                },
                .profile_part => {
                    const part_len = self.part_end - self.part_start;
                    const end = @min(self.codepoint_index + budget, part_len);
                    const copied = end - self.codepoint_index;
                    while (self.codepoint_index != end) : (self.codepoint_index += 1) {
                        self.part_max_codepoint = @max(
                            self.part_max_codepoint,
                            self.text.borrow().slice()[self.part_start + self.codepoint_index],
                        );
                    }
                    budget -= copied;
                    if (self.codepoint_index != part_len or budget == 0) return .yielded;
                    self.part_writer = .init(try kernel_flat.CodepointWriter.init(
                        evaluator.allocator(),
                        part_len,
                        self.part_max_codepoint,
                    ));
                    self.codepoint_index = 0;
                    self.phase = .fill_part;
                },
                .fill_part => {
                    const part_len = self.part_end - self.part_start;
                    if (self.codepoint_index == part_len) {
                        self.parts.borrowMut().appendOwned(self.part_writer.?.borrowMut().finish());
                        self.part_writer = null;
                        self.phase = .scan;
                        if (part_len == 0) budget -= 1;
                        return .yielded;
                    }
                    var block: [kernel_flat.block_size]u32 = undefined;
                    const copied = @min(
                        @min(budget, kernel_flat.block_size),
                        part_len - self.codepoint_index,
                    );
                    for (
                        self.text.borrow().slice()[self.part_start + self.codepoint_index ..][0..copied],
                        block[0..copied],
                    ) |codepoint, *out| out.* = codepoint;
                    self.part_writer.?.borrowMut().writeCodepoints(
                        self.codepoint_index,
                        block[0..copied],
                    );
                    self.codepoint_index += copied;
                    budget -= copied;
                },
                .materialize_result => switch (try self.result_materializer.?.borrowMut().advance(budget)) {
                    .pending => return .yielded,
                    .complete => |result| {
                        self.result_materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.result_materializer = null;
                        self.parts.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.text.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.separator.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        return .{ .output = result };
                    },
                },
            };
            return .yielded;
        }
    };
}

fn joinPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var separator = try evaluator.popValue();
    defer separator.deinit();
    var parts = try evaluator.popValue();
    defer parts.deinit();
    if (parts.borrow() != .list or !separator.borrow().isString()) {
        return evaluator.typeError("a list of strings and a string separator");
    }
    try evaluator.startDriver(JoinDriver{
        .parts = .init(parts.take()),
        .separator = .init(separator.take()),
    });
}

const JoinDriver = struct {
    /// One string built from a list, then it publishes.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;
    parts: heap.Owned(Value),
    separator: heap.Owned(Value),
    phase: enum { count, fill } = .count,
    part_index: usize = 0,
    total: usize = 0,
    max_codepoint: u32 = 0,
    separator_profiled: bool = false,
    writer: ?heap.Owned(kernel_flat.CodepointWriter) = null,
    output_index: usize = 0,
    source_index: usize = 0,
    separator_mode: bool = false,
    source: ?heap.Owned(AnyCharReader) = null,

    pub fn advance(evaluator: *Machine, self: *JoinDriver) MachineError!machine.WorkProgress {
        const context = support.Context{ .evaluator = evaluator };
        var budget = @max(context.remaining(), 1);
        try context.advance(budget);
        var block: [kernel_flat.block_size]u32 = undefined;
        while (budget != 0) switch (self.phase) {
            .count => {
                const count: usize = @intCast(self.parts.borrow().list.length());
                if (self.part_index == count) {
                    if (!self.separator_profiled and count > 1) {
                        if (self.source == null) self.source = .init(AnyCharReader.acquire(self.separator.borrow()));
                        const source_count = self.source.?.borrow().len();
                        const copied = @min(@min(budget, kernel_flat.block_size), source_count - self.source_index);
                        self.source.?.borrow().copyCodepoints(self.source_index, block[0..copied]);
                        for (block[0..copied]) |codepoint| self.max_codepoint = @max(self.max_codepoint, codepoint);
                        self.source_index += copied;
                        budget -= copied;
                        if (self.source_index != source_count) return .yielded;
                        self.source.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.source = null;
                        self.source_index = 0;
                        self.separator_profiled = true;
                        if (budget == 0) return .yielded;
                        budget -= 1;
                        continue;
                    }
                    self.separator_profiled = true;
                    self.writer = .init(try kernel_flat.CodepointWriter.init(
                        evaluator.allocator(),
                        self.total,
                        self.max_codepoint,
                    ));
                    self.part_index = 0;
                    self.phase = .fill;
                    continue;
                }
                if (self.source == null) {
                    const part = list.atUnchecked(self.parts.borrow(), self.part_index);
                    if (!part.isString()) return evaluator.failAtIndex(
                        .type,
                        "join expected a list of strings",
                        self.part_index,
                    );
                    self.total = std.math.add(usize, self.total, @intCast(part.list.length())) catch
                        return evaluator.fail(.overflow, "joined string is too large");
                    if (self.part_index + 1 < count) self.total = std.math.add(
                        usize,
                        self.total,
                        @intCast(self.separator.borrow().list.length()),
                    ) catch return evaluator.fail(.overflow, "joined string is too large");
                    self.source = .init(AnyCharReader.acquire(part));
                }
                const source_count = self.source.?.borrow().len();
                const copied = @min(@min(budget, kernel_flat.block_size), source_count - self.source_index);
                self.source.?.borrow().copyCodepoints(self.source_index, block[0..copied]);
                for (block[0..copied]) |codepoint| self.max_codepoint = @max(self.max_codepoint, codepoint);
                self.source_index += copied;
                budget -= copied;
                if (self.source_index != source_count) return .yielded;
                self.source.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.source = null;
                self.source_index = 0;
                self.part_index += 1;
                if (budget == 0) return .yielded;
                budget -= 1;
            },
            .fill => {
                const count: usize = @intCast(self.parts.borrow().list.length());
                if (self.part_index == count) {
                    std.debug.assert(self.output_index == self.total);
                    return .{ .output = self.writer.?.borrowMut().finish() };
                }
                if (self.source == null) {
                    const source = if (self.separator_mode)
                        self.separator.borrow()
                    else
                        list.atUnchecked(self.parts.borrow(), self.part_index);
                    self.source = .init(AnyCharReader.acquire(source));
                }
                const source_count = self.source.?.borrow().len();
                if (self.source_index == source_count) {
                    self.source.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.source = null;
                    self.source_index = 0;
                    if (self.separator_mode or self.part_index + 1 == count) {
                        self.separator_mode = false;
                        self.part_index += 1;
                    } else self.separator_mode = true;
                    budget -= 1;
                    continue;
                }
                const copied = @min(@min(budget, kernel_flat.block_size), source_count - self.source_index);
                self.source.?.borrow().copyCodepoints(
                    self.source_index,
                    block[0..copied],
                );
                self.writer.?.borrowMut().writeCodepoints(self.output_index, block[0..copied]);
                self.output_index += copied;
                self.source_index += copied;
                budget -= copied;
            },
        };
        return .yielded;
    }
};

fn formatPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var template = try evaluator.popValue();
    defer template.deinit();
    var values = try evaluator.popValue();
    defer values.deinit();
    if (values.borrow() != .list or !template.borrow().isString()) {
        return evaluator.typeError("a value list and a template string");
    }
    const value_count: usize = @intCast(values.borrow().list.length());
    const replacements = try evaluator.allocator().alloc(RenderedReplacement, value_count);
    var replacements_owner: ?[]RenderedReplacement = replacements;
    errdefer if (replacements_owner) |owned| evaluator.allocator().free(owned);
    const replacement_values = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), value_count);
    replacements_owner = null;
    try evaluator.startDriver(FormatDriver{
        .values = .init(values.take()),
        .template = .init(template.take()),
        .replacements = .init(replacements),
        .replacement_values = .init(replacement_values),
    });
}

const RenderedReplacement = struct { text: Value };

const FormatDriver = struct {
    /// One rendering, then it publishes.
    pub const inline_driver = true;
    values: heap.Owned(Value),
    template: heap.Owned(Value),
    replacements: heap.Owned([]RenderedReplacement),
    replacement_values: heap.Owned(heap.OwnedValueBuffer),
    phase: enum { scan, render, materialize_replacement, fill, materialize } = .scan,
    cursor: usize = 0,
    replacement_index: usize = 0,
    replacement_cursor: usize = 0,
    output_count: usize = 0,
    output: ?heap.Owned([]u32) = null,
    output_index: usize = 0,
    filling_replacement: bool = false,
    renderer: ?heap.Owned(printer.OwnedStringCursor) = null,
    rendered: ?heap.Owned([]u8) = null,
    replacement_materializer: ?heap.Owned(storage.Utf8Materializer) = null,
    materializer: ?heap.Owned(storage.CodepointMaterializer) = null,

    fn templatePair(self: *const FormatDriver) struct { codepoint: u32, next: ?u32 } {
        const count: usize = @intCast(self.template.borrow().list.length());
        return .{
            .codepoint = list.atUnchecked(self.template.borrow(), self.cursor).char,
            .next = if (self.cursor + 1 < count)
                list.atUnchecked(self.template.borrow(), self.cursor + 1).char
            else
                null,
        };
    }

    pub fn advance(evaluator: *Machine, self: *FormatDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .scan => {
                const count: usize = @intCast(self.template.borrow().list.length());
                if (self.cursor == count) {
                    if (self.replacement_index != self.replacements.borrow().len) {
                        return evaluator.fail(.contract, "format has more values than placeholders");
                    }
                    self.output = .init(try evaluator.allocator().alloc(u32, self.output_count));
                    self.cursor = 0;
                    self.replacement_index = 0;
                    self.phase = .fill;
                    continue;
                }
                const pair = self.templatePair();
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    try addFormatCount(evaluator, &self.output_count, 1);
                    self.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    if (self.replacement_index == self.replacements.borrow().len) {
                        return evaluator.fail(.contract, "format has more placeholders than values");
                    }
                    self.cursor += 2;
                    const replacement = list.atUnchecked(
                        self.values.borrow(),
                        self.replacement_index,
                    );
                    if (replacement.isString()) {
                        self.replacements.borrow()[self.replacement_index] = .{ .text = replacement };
                        try addFormatCount(
                            evaluator,
                            &self.output_count,
                            @intCast(replacement.list.length()),
                        );
                        self.replacement_index += 1;
                    } else {
                        self.renderer = .init(try printer.OwnedStringCursor.init(
                            evaluator.allocator(),
                            replacement,
                        ));
                        self.phase = .render;
                    }
                } else if (pair.codepoint == '{' or pair.codepoint == '}') {
                    return evaluator.fail(.domain, "format contains an unmatched brace");
                } else {
                    try addFormatCount(evaluator, &self.output_count, 1);
                    self.cursor += 1;
                }
                budget -= 1;
            },
            .render => switch (try self.renderer.?.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => |bytes| {
                    self.renderer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.renderer = null;
                    self.rendered = .init(bytes);
                    self.replacement_materializer = .init(.init(evaluator.allocator(), bytes));
                    self.phase = .materialize_replacement;
                    return .yielded;
                },
            },
            .materialize_replacement => switch (self.replacement_materializer.?.borrowMut().advance(budget) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return evaluator.fail(.domain, "rendered value is not valid UTF-8"),
            }) {
                .pending => return .yielded,
                .complete => |text| {
                    self.replacement_materializer.?.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    self.replacement_materializer = null;
                    self.rendered.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.rendered = null;
                    self.replacements.borrow()[self.replacement_index] = .{ .text = text };
                    self.replacement_values.borrowMut().appendOwned(text);
                    try addFormatCount(evaluator, &self.output_count, @intCast(text.list.length()));
                    self.replacement_index += 1;
                    self.phase = .scan;
                    return .yielded;
                },
            },
            .fill => {
                if (self.filling_replacement) {
                    const replacement = self.replacements.borrow()[self.replacement_index];
                    if (self.replacement_cursor == replacement.text.list.length()) {
                        self.filling_replacement = false;
                        self.replacement_index += 1;
                        continue;
                    }
                    self.output.?.borrow()[self.output_index] = list.atUnchecked(
                        replacement.text,
                        self.replacement_cursor,
                    ).char;
                    self.replacement_cursor += 1;
                    self.output_index += 1;
                    budget -= 1;
                    continue;
                }
                const count: usize = @intCast(self.template.borrow().list.length());
                if (self.cursor == count) {
                    std.debug.assert(self.output_index == self.output.?.borrow().len);
                    self.materializer = .init(.init(
                        evaluator.allocator(),
                        self.output.?.borrow(),
                    ));
                    self.phase = .materialize;
                    continue;
                }
                const pair = self.templatePair();
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    self.output.?.borrow()[self.output_index] = pair.codepoint;
                    self.output_index += 1;
                    self.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    self.filling_replacement = true;
                    self.replacement_cursor = 0;
                    self.cursor += 2;
                } else {
                    self.output.?.borrow()[self.output_index] = pair.codepoint;
                    self.output_index += 1;
                    self.cursor += 1;
                }
                budget -= 1;
            },
            .materialize => return switch (try self.materializer.?.borrowMut().advance(budget)) {
                .pending => .yielded,
                .complete => |result| completed: {
                    self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.materializer = null;
                    break :completed .{ .output = result };
                },
            },
        };
        return .yielded;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn addFormatCount(
    evaluator: *Machine,
    count: *usize,
    amount: usize,
) MachineError!void {
    count.* = std.math.add(usize, count.*, amount) catch
        return evaluator.fail(.overflow, "formatted string is too large");
}
