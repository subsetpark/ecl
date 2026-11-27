//! Immutable dict operations and the core `put`/`del` collection updates.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const support = @import("kernel_support.zig");
const kernel_flat = @import("kernel_flat.zig");
const poll = @import("poll.zig");

const Value = value.Value;
const Fiber = support.Fiber;
const MachineError = support.MachineError;

const Op = support.DictOp;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(Op)) |operation| {
        try core.installBuiltin(comptime definition(operation));
    }
}

fn definition(comptime operation: Op) env.BuiltinWord {
    return switch (operation) {
        .put => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "collection selector value -- collection", .doc = "Set the element at `selector` to `value` inside of `collection`. When `collection` is a list, selector behaviour is pervasive; when `collection` is a dict, `selector` is treated as a whole-value key." },
        .del => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "collection selector -- collection", .doc = "Remove the element at `selector` inside of `collection`. When `collection` is a list, selector behaviour is pervasive; when `collection` is a dict, `selector` is treated as a whole-value key." },
    };
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(fiber: *Fiber) MachineError!void {
            return switch (operation) {
                .put => putPrimitive(fiber),
                .del => delPrimitive(fiber),
            };
        }
    }.run);
}

fn keysPrimitive(fiber: *Fiber) MachineError!void {
    var dictionary = try fiber.popDict();
    defer dictionary.deinit();
    const keys = dict.keysOf(dictionary.borrow().dict);
    try fiber.pushBorrowed(keys);
}

pub fn keysForModule(fiber: *Fiber) MachineError!void {
    return keysPrimitive(fiber);
}

fn sizePrimitive(fiber: *Fiber) MachineError!void {
    var dictionary = try fiber.popDict();
    defer dictionary.deinit();
    try fiber.pushOwned(.{ .int = @intCast(dictionary.borrow().dict.length()) });
}

pub fn sizeForModule(fiber: *Fiber) MachineError!void {
    return sizePrimitive(fiber);
}

fn valsPrimitive(fiber: *Fiber) MachineError!void {
    var dictionary = try fiber.popDict();
    defer dictionary.deinit();
    const values = dict.valsOf(dictionary.borrow().dict);
    try fiber.pushBorrowed(values);
}

pub fn valsForModule(fiber: *Fiber) MachineError!void {
    return valsPrimitive(fiber);
}

fn hasPrimitive(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var key = try fiber.popValue();
    defer key.deinit();
    var dictionary = try fiber.popDict();
    defer dictionary.deinit();
    return hasKey(fiber, &dictionary, &key);
}

/// Whether `dictionary` holds `key` as one whole-value key: `dict.core.has?`
/// and core membership over a dict haystack. The caller owns both operands
/// and releases whichever this does not take.
pub fn hasKey(fiber: *Fiber, dictionary: *heap.OwnedValue, key: *heap.OwnedValue) MachineError!void {
    std.debug.assert(dictionary.borrow() == .dict);
    const cursor = dict.FindCursor.initHeader(
        fiber.allocator,
        dictionary.borrow().dict,
        key.borrow(),
    );
    try fiber.startDriver(HasDriver{
        .dictionary = .init(dictionary.take()),
        .key = .init(key.take()),
        .cursor = .init(cursor),
    });
}

pub fn hasForModule(fiber: *Fiber) MachineError!void {
    return hasPrimitive(fiber);
}

const HasDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// Searching a dict is bounded work over however many entries it has, so
    /// the driver is earned; its creation is not. `dict.FindCursor` already
    /// allocates nothing for a key without structure, which left this as the
    /// only cost of asking whether a dict holds a symbol.
    pub const inline_driver = true;
    dictionary: heap.Owned(Value),
    key: heap.Owned(Value),
    cursor: heap.Owned(dict.FindCursor),

    pub fn advance(fiber: *Fiber, self: *HasDriver) MachineError!machine.WorkProgress {
        return switch (try self.cursor.borrowMut().advance(fiber.workBudget())) {
            .pending => .stepped,
            .complete => |found| .{ .output = .{ .int = @intFromBool(found != null) } },
        };
    }
};

pub fn putForModule(fiber: *Fiber) MachineError!void {
    return putImpl(fiber, true);
}

fn putPrimitive(fiber: *Fiber) MachineError!void {
    return putImpl(fiber, false);
}

fn putImpl(fiber: *Fiber, comptime dictionary_only: bool) MachineError!void {
    try fiber.require(3);
    var new_value = try fiber.popValue();
    defer new_value.deinit();
    var key = try fiber.popValue();
    defer key.deinit();
    var collection = try fiber.popValue();
    defer collection.deinit();
    if (dictionary_only and collection.borrow() != .dict) return fiber.typeError("a dict");
    switch (collection.borrow()) {
        .dict => {
            const finder = dict.FindCursor.initHeader(
                fiber.allocator,
                collection.borrow().dict,
                key.borrow(),
            );
            try fiber.startDriver(DictPutDriver{
                .dictionary = .init(collection.take()),
                .key = .init(key.take()),
                .new_value = .init(new_value.take()),
                .work = .init(.{ .finding = finder }),
            });
        },
        .list => {
            if (key.borrow() == .list) {
                if (try startTypedVectorPut(fiber, &collection, &key, &new_value)) return;
                const count: usize = @intCast(collection.borrow().list.length());
                const values = try fiber.allocator.alloc(Value, count);
                var actions = poll.ChunkStack(PutAction).init(fiber.allocator);
                errdefer actions.deinit();
                try actions.push(.{ .node = .{
                    .selector = key.borrow(),
                    .replacement = new_value.borrow(),
                    .depth = 0,
                } });
                try fiber.startDriver(PervasivePutDriver{
                    .collection = .init(collection.take()),
                    .selector = .init(key.take()),
                    .replacement = .init(new_value.take()),
                    .values = .init(values),
                    .actions = .init(actions),
                });
                return;
            }
            if (key.borrow() != .int) return fiber.typeError("an integer list index");
            if (key.borrow().int < 0) return fiber.fail(.domain, "put index is negative");
            const index = std.math.cast(usize, key.borrow().int) orelse
                return fiber.fail(.domain, "put index is out of bounds");
            const count: usize = @intCast(collection.borrow().list.length());
            if (index >= count) return fiber.fail(.domain, "put index is out of bounds");
            if (try startTypedListPut(
                fiber,
                &collection,
                new_value.borrow(),
                index,
                count,
            )) return;
            const values = try fiber.allocator.alloc(Value, count);
            try fiber.startDriver(ListPutDriver{
                .collection = .init(collection.take()),
                .key = .init(key.take()),
                .new_value = .init(new_value.take()),
                .replace_index = index,
                .values = .init(values),
            });
        },
        .int, .float, .char, .symbol, .task, .port, .address => return fiber.typeError("a list or dict"),
    }
}

const PutAction = union(enum) {
    node: struct {
        selector: Value,
        replacement: Value,
        depth: usize,
    },
    children: struct {
        selectors: Value,
        replacement: Value,
        conforming_replacements: bool,
        depth: usize,
        index: usize,
    },
};

const PervasivePutDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    collection: heap.Owned(Value),
    selector: heap.Owned(Value),
    replacement: heap.Owned(Value),
    values: heap.Owned([]Value),
    actions: heap.Owned(poll.ChunkStack(PutAction)),
    copy_index: usize = 0,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(fiber: *Fiber, self: *PervasivePutDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        const output = self.values.borrow();

        if (self.copy_index != output.len) {
            const end = self.copy_index + work.take(output.len - self.copy_index);
            while (self.copy_index != end) : (self.copy_index += 1)
                output[self.copy_index] = list.atUnchecked(self.collection.borrow(), self.copy_index);
            if (self.copy_index != output.len) return .stepped;
        }

        while (!self.actions.borrow().isEmpty() and work.spend()) {
            const action = self.actions.borrowMut().pop().?;
            switch (action) {
                .node => |node| {
                    if (node.selector == .list) {
                        if (node.depth >= support.max_depth)
                            return fiber.fail(.domain, "put selector nesting exceeds 256 levels");
                        const selector_count: usize = @intCast(node.selector.list.length());
                        const conforming = node.replacement == .list;
                        if (conforming) {
                            const replacement_count: usize = @intCast(node.replacement.list.length());
                            if (selector_count != replacement_count)
                                return fiber.conformError(selector_count, replacement_count);
                        }
                        try self.actions.borrowMut().push(.{ .children = .{
                            .selectors = node.selector,
                            .replacement = node.replacement,
                            .conforming_replacements = conforming,
                            .depth = node.depth + 1,
                            .index = 0,
                        } });
                        continue;
                    }
                    if (node.selector != .int)
                        return fiber.typeError("an integer list index");
                    if (node.selector.int < 0)
                        return fiber.fail(.domain, "put index is negative");
                    const index = std.math.cast(usize, node.selector.int) orelse
                        return fiber.fail(.domain, "put index is out of bounds");
                    if (index >= output.len)
                        return fiber.fail(.domain, "put index is out of bounds");
                    output[index] = node.replacement;
                },
                .children => |children| {
                    if (children.index == children.selectors.list.length()) continue;
                    try self.actions.borrowMut().reserve(2);
                    self.actions.borrowMut().pushReserved(.{ .children = .{
                        .selectors = children.selectors,
                        .replacement = children.replacement,
                        .conforming_replacements = children.conforming_replacements,
                        .depth = children.depth,
                        .index = children.index + 1,
                    } });
                    self.actions.borrowMut().pushReserved(.{ .node = .{
                        .selector = list.atUnchecked(children.selectors, children.index),
                        .replacement = if (children.conforming_replacements)
                            list.atUnchecked(children.replacement, children.index)
                        else
                            children.replacement,
                        .depth = children.depth,
                    } });
                },
            }
        }
        if (!self.actions.borrow().isEmpty()) return .stepped;

        if (self.materializer == null)
            self.materializer = .init(list.ValueMaterializer.init(fiber.allocator, output));
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                self.materializer.?.deinit(fiber.releases, fiber.allocator);
                self.materializer = null;
                break :completed .{ .output = result };
            },
        };
    }
};

const put_leaf_kinds = [_]value.HeapKind{
    .leaf_u8,
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
};

fn typedReplacement(comptime kind: value.HeapKind, item: Value) ?heap.LeafElement(kind) {
    return switch (kind) {
        .leaf_u8 => switch (item) {
            .int => |number| std.math.cast(u8, number),
            else => null,
        },
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
        .generic_spine, .dict, .task, .port, .address => unreachable,
    };
}

/// A typed copy of a leaf with one element replaced.
fn ListPutKernel(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        pub const arity = 1;
        pub const Params = struct { replacement: Element, index: usize };
        pub const Output = support.LeafResult(kind);
        /// Every position but the replaced one keeps its element, so the
        /// collection may become the result, which then needs one store.
        pub const result: ?support.ResultShape = .{ .kind = kind, .overwritable = &.{0} };

        pub fn positions(_: Params, aliased: bool, length: usize) usize {
            return if (aliased) 1 else length;
        }

        pub fn chunk(put: Params, operands: [1]Value, output: *Output, range: kernel_flat.Chunk, _: *Fiber) MachineError!void {
            if (output.aliased()) return output.store(put.index, &.{put.replacement});
            const out = output.range(range.start, range.len());
            @memcpy(out, heap.leafElements(kind, operands[0].list)[range.start..range.end]);
            if (put.index >= range.start and put.index < range.end) out[put.index - range.start] = put.replacement;
        }

        pub const finish = Output.finish;
    };
}

/// Same-kind leaf replacement through `ListPutKernel`: one store when the
/// kernel takes the collection over, else one exact-size typed copy. A value
/// that changes the leaf class deliberately returns false so the profiling
/// path can widen its result.
fn startTypedListPut(
    fiber: *Fiber,
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
            try support.Kernel(ListPutKernel(candidate)).run(
                fiber,
                .{collection},
                .{ .replacement = replacement, .index = replace_index },
                count,
            );
            return true;
        }
    }
    unreachable;
}

/// What a typed vector put stores: one atom at every selected position, or a
/// conforming leaf read in the collection's representation. A byte leaf widens
/// losslessly into an integer collection, since literal and profiled integer
/// lists are bytes whenever they can be.
const VectorReplacement = enum { atom, same, bytes };

/// `put` with a flat typed index vector into a typed leaf, in three phases:
/// validate every index, copy the collection unless it is reused, then
/// scatter. Validation reports the first bad index in selector order, as on
/// the pervasive path. Operand 0 is the collection, operand 1 the indices,
/// and operand 2, unless the replacement is an atom, the replacement leaf.
/// `kind` is the result's representation and `source_kind` the collection's.
/// They differ for a byte collection that takes ints: the copy widens it into
/// a fresh int result, since int lists are bytes whenever they can be and a
/// put of larger values must not fall to the pervasive path for that.
fn VectorPutKernel(
    comptime kind: value.HeapKind,
    comptime source_kind: value.HeapKind,
    comptime index_kind: value.HeapKind,
    comptime replacement: VectorReplacement,
) type {
    comptime std.debug.assert(source_kind == kind or (source_kind == .leaf_u8 and kind == .leaf_i64));
    const widens = source_kind != kind;
    const Element = heap.LeafElement(kind);
    const Index = heap.LeafElement(index_kind);
    return struct {
        pub const arity = if (replacement == .atom) 2 else 3;
        /// The atom stored at every selected position.
        pub const Params = if (replacement == .atom) Element else void;
        pub const Output = struct {
            phase: enum { validate, copy, scatter } = .validate,
            result: support.LeafResult(kind),
            count: usize,
            selected: usize,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.result.retire(releases);
            }
        };

        /// The collection may become the result: indices are validated before
        /// the first store, so it is never left half-replaced, and a taken-over
        /// collection skips the copy.
        pub const result: ?support.ResultShape = .{ .kind = kind, .overwritable = if (widens) &.{} else &.{0} };

        pub fn resultLength(_: Params, operands: [arity]Value, _: usize) usize {
            return @intCast(operands[0].list.length());
        }

        pub fn leafResult(output: *Output) *support.LeafResult(kind) {
            return &output.result;
        }

        pub fn prepare(_: *Fiber, operands: [arity]Value, _: Params, _: usize, prepared: support.LeafResult(kind)) error{OutOfMemory}!Output {
            return .{
                .result = prepared,
                .count = @intCast(operands[0].list.length()),
                .selected = @intCast(operands[1].list.length()),
            };
        }

        pub fn chunk(atom: Params, operands: [arity]Value, output: *Output, range: kernel_flat.Chunk, fiber: *Fiber) MachineError!void {
            const indices = heap.leafElements(index_kind, operands[1].list);
            switch (output.phase) {
                .validate => if (kernel_flat.firstIndexFault(Index, indices[range.start..range.end], output.count)) |fault| return switch (fault.kind) {
                    .negative => fiber.fail(.domain, "put index is negative"),
                    .out_of_bounds => fiber.fail(.domain, "put index is out of bounds"),
                },
                .copy => if (widens) {
                    const source = heap.leafElements(source_kind, operands[0].list)[range.start..range.end];
                    for (output.result.range(range.start, range.len()), source) |*slot, item| slot.* = item;
                } else output.result.store(range.start, heap.leafElements(kind, operands[0].list)[range.start..range.end]),
                .scatter => {
                    const out = output.result.range(0, output.count);
                    switch (replacement) {
                        .atom => for (indices[range.start..range.end]) |index| {
                            out[@intCast(index)] = atom;
                        },
                        .same => for (indices[range.start..range.end], heap.leafElements(kind, operands[2].list)[range.start..range.end]) |index, item| {
                            out[@intCast(index)] = item;
                        },
                        .bytes => for (indices[range.start..range.end], heap.leafElements(.leaf_u8, operands[2].list)[range.start..range.end]) |index, item| {
                            out[@intCast(index)] = item;
                        },
                    }
                },
            }
        }

        pub fn next(_: *Fiber, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .validate => if (!output.result.aliased()) {
                    output.phase = .copy;
                    return output.count;
                },
                .copy => {},
                .scatter => return null,
            }
            output.phase = .scatter;
            return output.selected;
        }

        pub fn finish(output: *Output) Value {
            return output.result.finish();
        }
    };
}

/// Starts the typed vector put when the collection is a typed leaf, the
/// selector a flat byte or integer leaf, and the replacement an atom of the
/// collection's class or a conforming leaf that needs no widening of the
/// result. Anything else, including a mismatched replacement length, returns
/// false and takes the pervasive path, which owns those errors.
fn startTypedVectorPut(
    fiber: *Fiber,
    collection: *heap.OwnedValue,
    selector: *heap.OwnedValue,
    replacement: *heap.OwnedValue,
) MachineError!bool {
    const kind = collection.borrow().list.kind();
    const index_kind = selector.borrow().list.kind();
    if (index_kind != .leaf_u8 and index_kind != .leaf_i64) return false;
    const selected: usize = @intCast(selector.borrow().list.length());
    if (replacement.borrow() == .list and replacement.borrow().list.length() != selected) return false;
    inline for (put_leaf_kinds) |candidate| {
        if (kind == candidate) inline for ([_]value.HeapKind{ .leaf_u8, .leaf_i64 }) |candidate_index| {
            if (index_kind == candidate_index) {
                switch (replacement.borrow()) {
                    .list => |items| if (items.kind() == candidate)
                        try support.Kernel(VectorPutKernel(candidate, candidate, candidate_index, .same)).run(fiber, .{ collection, selector, replacement }, {}, selected)
                    else if (candidate == .leaf_i64 and items.kind() == .leaf_u8)
                        try support.Kernel(VectorPutKernel(candidate, candidate, candidate_index, .bytes)).run(fiber, .{ collection, selector, replacement }, {}, selected)
                    else if (candidate == .leaf_u8 and items.kind() == .leaf_i64)
                        try support.Kernel(VectorPutKernel(.leaf_i64, .leaf_u8, candidate_index, .same)).run(fiber, .{ collection, selector, replacement }, {}, selected)
                    else
                        return false,
                    else => if (typedReplacement(candidate, replacement.borrow())) |atom| {
                        try support.Kernel(VectorPutKernel(candidate, candidate, candidate_index, .atom)).run(fiber, .{ collection, selector }, atom, selected);
                    } else if (candidate == .leaf_u8 and replacement.borrow() == .int) {
                        try support.Kernel(VectorPutKernel(.leaf_i64, .leaf_u8, candidate_index, .atom)).run(fiber, .{ collection, selector }, replacement.borrow().int, selected);
                    } else return false,
                }
                return true;
            }
        };
    }
    return false;
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
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(fiber: *Fiber, self: *ListPutDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        if (self.materializer == null) {
            const values = self.values.borrow();
            const end = self.index + work.take(values.len - self.index);
            while (self.index != end) : (self.index += 1) values[self.index] =
                if (self.index == self.replace_index)
                    self.new_value.borrow()
                else
                    list.atUnchecked(self.collection.borrow(), self.index);
            if (self.index != values.len) return .stepped;
            self.materializer = .init(list.ValueMaterializer.init(fiber.allocator, values));
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                self.materializer.?.deinit(fiber.releases, fiber.allocator);
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

    finding: dict.FindCursor,
    materializing: dict.Materializer,
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

    pub fn advance(fiber: *Fiber, self: *DictPutDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        if (self.work.borrowMut().* == .finding) switch (try self.work.borrowMut().finding.advance(work)) {
            .pending => return .stepped,
            .complete => {
                self.found_index = self.work.borrowMut().finding.foundIndex();
                self.work.borrowMut().finish(fiber.releases);
                const old_count: usize = @intCast(self.dictionary.borrow().dict.length());
                self.pairs = .init(try fiber.allocator.alloc(
                    dict.Pair,
                    old_count + @intFromBool(self.found_index == null),
                ));
                return .stepped;
            },
        };
        if (self.work.borrowMut().* != .materializing) {
            const old_count: usize = @intCast(self.dictionary.borrow().dict.length());
            const pairs = self.pairs.?.borrow();
            const end = self.index + work.take(pairs.len - self.index);
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
            if (self.index != pairs.len) return .stepped;
            const materializer: dict.Materializer = try .initBorrowedPairs(fiber.allocator, pairs, false);
            self.work.borrowMut().* = .{ .materializing = materializer };
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.work.borrowMut().materializing.advance(work)) {
            .pending => .stepped,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.work.borrowMut().finish(fiber.releases);
                break :completed .{ .output = result };
            },
        };
    }
};

pub fn zipForModule(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var values = try fiber.popValue();
    defer values.deinit();
    var keys = try fiber.popValue();
    defer keys.deinit();
    if (keys.borrow() != .list or values.borrow() != .list) return fiber.typeError("two lists");
    const count: usize = @intCast(keys.borrow().list.length());
    if (values.borrow().list.length() != keys.borrow().list.length()) {
        return fiber.fail(.shape, "dict.zip requires equal key and value lengths");
    }
    const pairs = try fiber.allocator.alloc(dict.Pair, count);
    try fiber.startDriver(FromListsDriver{
        .keys = .init(keys.take()),
        .values = .init(values.take()),
        .pairs = .init(pairs),
    });
}

const FromListsDriver = struct {
    /// One dict built from two lists, then it publishes.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;
    keys: heap.Owned(Value),
    values: heap.Owned(Value),
    pairs: heap.Owned([]dict.Pair),
    index: usize = 0,
    materializer: ?heap.Owned(dict.Materializer) = null,

    pub fn advance(fiber: *Fiber, self: *FromListsDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        if (self.materializer == null) {
            const pairs = self.pairs.borrow();
            const end = self.index + work.take(pairs.len - self.index);
            while (self.index != end) : (self.index += 1) pairs[self.index] = .{
                list.atUnchecked(self.keys.borrow(), self.index),
                list.atUnchecked(self.values.borrow(), self.index),
            };
            if (self.index != pairs.len or work.exhausted()) return .stepped;
            self.materializer = .init(try .init(fiber.allocator, pairs, true));
        }
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .duplicate_key => fiber.fail(.domain, "dict.zip keys must be distinct"),
            .complete => |result| completed: {
                self.materializer.?.deinit(fiber.releases, fiber.allocator);
                self.materializer = null;
                break :completed .{ .output = result };
            },
        };
    }
};

fn delPrimitive(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var key = try fiber.popValue();
    defer key.deinit();
    var collection = try fiber.popValue();
    defer collection.deinit();
    switch (collection.borrow()) {
        .dict => {
            const finder = dict.FindCursor.initHeader(
                fiber.allocator,
                collection.borrow().dict,
                key.borrow(),
            );
            try fiber.startDriver(DictDelDriver{
                .dictionary = .init(collection.take()),
                .key = .init(key.take()),
                .work = .init(.{ .finding = finder }),
            });
        },
        .list => {
            if (key.borrow() == .list) {
                if (try startTypedDel(fiber, &collection, &key)) return;
                const count: usize = @intCast(collection.borrow().list.length());
                const removed = try fiber.allocator.alloc(bool, count);
                var removed_owned_locally = true;
                errdefer if (removed_owned_locally) fiber.allocator.free(removed);
                var selector_cursor = try support.PervasiveSelectorCursor.init(
                    fiber.allocator,
                    key.borrow(),
                );
                var cursor_owned_locally = true;
                errdefer if (cursor_owned_locally) selector_cursor.retire(fiber.releases);
                removed_owned_locally = false;
                cursor_owned_locally = false;
                try fiber.startDriver(PervasiveDelDriver{
                    .collection = .init(collection.take()),
                    .selector = .init(key.take()),
                    .removed = .init(removed),
                    .selector_cursor = .init(selector_cursor),
                });
                return;
            }
            if (key.borrow() != .int) return fiber.typeError("an integer list index");
            if (key.borrow().int < 0) return fiber.fail(.domain, "del index is negative");
            const index = std.math.cast(usize, key.borrow().int) orelse
                return fiber.fail(.domain, "del index is out of bounds");
            const count: usize = @intCast(collection.borrow().list.length());
            if (index >= count) return fiber.fail(.domain, "del index is out of bounds");
            if (try startTypedDel(fiber, &collection, &key)) return;
            const values = try fiber.allocator.alloc(Value, count - 1);
            try fiber.startDriver(ListDelDriver{
                .collection = .init(collection.take()),
                .key = .init(key.take()),
                .removed_index = index,
                .values = .init(values),
            });
        },
        .int, .float, .char, .symbol, .task, .port, .address => return fiber.typeError("a list or dict"),
    }
}

const PervasiveDelDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    const Phase = enum { initialize, validate, copy, materialize };

    collection: heap.Owned(Value),
    selector: heap.Owned(Value),
    removed: heap.Owned([]bool),
    selector_cursor: ?heap.Owned(support.PervasiveSelectorCursor),
    values: ?heap.Owned([]Value) = null,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,
    phase: Phase = .initialize,
    index: usize = 0,
    removed_count: usize = 0,
    destination_index: usize = 0,

    pub fn advance(fiber: *Fiber, self: *PervasiveDelDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .initialize => {
                if (self.index == self.removed.borrow().len) {
                    self.index = 0;
                    self.phase = .validate;
                    continue;
                }
                self.removed.borrow()[self.index] = false;
                self.index += 1;
                _ = work.spend();
            },
            .validate => {
                _ = work.spend();
                switch (try self.selector_cursor.?.borrowMut().advanceOne()) {
                    .pending => {},
                    .depth_exceeded => return fiber.fail(.domain, "del selector nesting exceeds 256 levels"),
                    .leaf => |selector| {
                        if (selector != .int)
                            return fiber.typeError("an integer list index");
                        if (selector.int < 0)
                            return fiber.fail(.domain, "del index is negative");
                        const position = std.math.cast(usize, selector.int) orelse
                            return fiber.fail(.domain, "del index is out of bounds");
                        if (position >= self.removed.borrow().len)
                            return fiber.fail(.domain, "del index is out of bounds");
                        if (!self.removed.borrow()[position]) {
                            self.removed.borrow()[position] = true;
                            self.removed_count += 1;
                        }
                    },
                    .complete => {
                        self.selector_cursor.?.deinit(fiber.releases, fiber.allocator);
                        self.selector_cursor = null;
                        self.values = .init(try fiber.allocator.alloc(
                            Value,
                            self.removed.borrow().len - self.removed_count,
                        ));
                        self.phase = .copy;
                    },
                }
            },
            .copy => {
                if (self.index == self.removed.borrow().len) {
                    self.materializer = .init(list.ValueMaterializer.init(
                        fiber.allocator,
                        self.values.?.borrow(),
                    ));
                    self.phase = .materialize;
                    continue;
                }
                if (!self.removed.borrow()[self.index]) {
                    self.values.?.borrow()[self.destination_index] =
                        list.atUnchecked(self.collection.borrow(), self.index);
                    self.destination_index += 1;
                }
                self.index += 1;
                _ = work.spend();
            },
            .materialize => return switch (try self.materializer.?.borrowMut().advance(work)) {
                .pending => .stepped,
                .complete => |result| completed: {
                    self.materializer.?.deinit(fiber.releases, fiber.allocator);
                    self.materializer = null;
                    break :completed .{ .output = result };
                },
            },
        };
        return .stepped;
    }
};

/// The positions a typed `del` removes: one validated index, or a flat typed
/// index leaf whose entries are validated as they are marked.
/// `del` of one position from a typed leaf: the result is the two slices
/// around it, one position per source element.
fn DelOneKernel(comptime kind: value.HeapKind) type {
    return struct {
        pub const arity = 1;
        /// The removed position.
        pub const Params = usize;
        pub const Output = support.LeafResult(kind);
        /// Positions before the removed one stay; later ones move down by
        /// one, so the source may become the result.
        pub const result: ?support.ResultShape = .{ .kind = kind, .overwritable = &.{0} };

        pub fn resultLength(_: usize, _: [1]Value, length: usize) usize {
            return length - 1;
        }

        pub fn chunk(removed: usize, operands: [1]Value, output: *Output, range: kernel_flat.Chunk, _: *Fiber) MachineError!void {
            const source = heap.leafElements(kind, operands[0].list);
            const left_end = @min(range.end, removed);
            // Over its source the left part is already in place.
            if (range.start < left_end and !output.aliased()) output.store(range.start, source[range.start..left_end]);
            const right_start = @max(range.start, removed + 1);
            if (right_start < range.end) output.store(right_start - 1, source[right_start..range.end]);
        }

        pub const finish = Output.finish;
    };
}

/// `del` of a flat typed index leaf from a typed leaf, in three phases: clear
/// a mask over the source, mark the selected positions, checking each range
/// of indices at once, then compact the kept elements into a typed result.
/// Operand 0 is the collection, operand 1 the indices.
fn DelManyKernel(comptime kind: value.HeapKind, comptime index_kind: value.HeapKind) type {
    const Index = heap.LeafElement(index_kind);
    return struct {
        pub const arity = 2;
        pub const Params = void;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            phase: enum { initialize, mark, copy } = .initialize,
            removed: []bool,
            removed_count: usize = 0,
            selected: usize,
            writer: ?heap.LeafWriter(kind) = null,
            destination: usize = 0,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.allocator.free(self.removed);
                if (self.writer) |*writer| writer.retire(releases);
            }
        };

        pub fn prepare(fiber: *Fiber, operands: [2]Value, _: void, length: usize) error{OutOfMemory}!Output {
            return .{
                .allocator = fiber.allocator,
                .removed = try fiber.allocator.alloc(bool, length),
                .selected = @intCast(operands[1].list.length()),
            };
        }

        pub fn chunk(_: void, operands: [2]Value, output: *Output, range: kernel_flat.Chunk, fiber: *Fiber) MachineError!void {
            switch (output.phase) {
                .initialize => @memset(output.removed[range.start..range.end], false),
                .mark => {
                    const run = heap.leafElements(index_kind, operands[1].list)[range.start..range.end];
                    if (kernel_flat.firstIndexFault(Index, run, output.removed.len)) |fault| return switch (fault.kind) {
                        .negative => fiber.fail(.domain, "del index is negative"),
                        .out_of_bounds => fiber.fail(.domain, "del index is out of bounds"),
                    };
                    for (run) |index| {
                        const slot = &output.removed[@intCast(index)];
                        output.removed_count += @intFromBool(!slot.*);
                        slot.* = true;
                    }
                },
                .copy => {
                    const writer = &output.writer.?;
                    const out = writer.unpublishedRange(0, writer.len());
                    const source = heap.leafElements(kind, operands[0].list);
                    for (source[range.start..range.end], output.removed[range.start..range.end]) |item, gone| {
                        if (gone) continue;
                        out[output.destination] = item;
                        output.destination += 1;
                    }
                },
            }
        }

        pub fn next(fiber: *Fiber, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .initialize => {
                    output.phase = .mark;
                    return output.selected;
                },
                .mark => {
                    output.writer = try .init(fiber.allocator, output.removed.len - output.removed_count);
                    output.phase = .copy;
                    return output.removed.len;
                },
                .copy => return null,
            }
        }

        pub fn finish(output: *Output) Value {
            output.allocator.free(output.removed);
            return output.writer.?.finish();
        }
    };
}

/// Starts the typed `del` for a typed leaf collection and a validated scalar
/// position or a flat byte or integer index leaf; false for any other shape.
fn startTypedDel(fiber: *Fiber, collection: *heap.OwnedValue, selection: *heap.OwnedValue) MachineError!bool {
    const kind = collection.borrow().list.kind();
    const count: usize = @intCast(collection.borrow().list.length());
    inline for (put_leaf_kinds) |candidate| {
        if (kind == candidate) {
            switch (selection.borrow()) {
                .int => |index| try support.Kernel(DelOneKernel(candidate)).run(fiber, .{collection}, @intCast(index), count),
                .list => |indices| switch (indices.kind()) {
                    inline .leaf_u8, .leaf_i64 => |index_kind| try support.Kernel(DelManyKernel(candidate, index_kind)).run(
                        fiber,
                        .{ collection, selection },
                        {},
                        count,
                    ),
                    else => return false,
                },
                else => return false,
            }
            return true;
        }
    }
    return false;
}

const ListDelDriver = struct {
    /// One list rebuilt without an indexed element, then it publishes.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;
    collection: heap.Owned(Value),
    key: heap.Owned(Value),
    removed_index: usize,
    values: heap.Owned([]Value),
    source_index: usize = 0,
    destination_index: usize = 0,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,

    pub fn advance(fiber: *Fiber, self: *ListDelDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        if (self.materializer == null) {
            const count: usize = @intCast(self.collection.borrow().list.length());
            while (!work.exhausted() and self.source_index != count) : (self.source_index += 1) {
                if (self.source_index != self.removed_index) {
                    self.values.borrow()[self.destination_index] =
                        list.atUnchecked(self.collection.borrow(), self.source_index);
                    self.destination_index += 1;
                }
                _ = work.spend();
            }
            if (self.source_index != count) return .stepped;
            self.materializer = .init(list.ValueMaterializer.init(
                fiber.allocator,
                self.values.borrow(),
            ));
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                self.materializer.?.deinit(fiber.releases, fiber.allocator);
                self.materializer = null;
                break :completed .{ .output = result };
            },
        };
    }
};

const DictDelDriver = struct {
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

    pub fn advance(fiber: *Fiber, self: *DictDelDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        if (self.work.borrowMut().* == .finding) switch (try self.work.borrowMut().finding.advance(work)) {
            .pending => return .stepped,
            .complete => {
                self.removed_index = self.work.borrowMut().finding.foundIndex();
                self.work.borrowMut().finish(fiber.releases);
                if (self.removed_index == null) {
                    heap.retainValue(self.dictionary.borrow());
                    return .{ .output = self.dictionary.borrow() };
                }
                const count: usize = @intCast(self.dictionary.borrow().dict.length());
                self.pairs = .init(try fiber.allocator.alloc(dict.Pair, count - 1));
                return .stepped;
            },
        };
        if (self.work.borrowMut().* != .materializing) {
            const count: usize = @intCast(self.dictionary.borrow().dict.length());
            while (!work.exhausted() and self.source_index != count) : (self.source_index += 1) {
                if (self.source_index != self.removed_index.?) {
                    self.pairs.?.borrow()[self.destination_index] = .{
                        dict.keyAt(self.dictionary.borrow().dict, self.source_index),
                        dict.valueAt(self.dictionary.borrow().dict, self.source_index),
                    };
                    self.destination_index += 1;
                }
                _ = work.spend();
            }
            if (self.source_index != count or work.exhausted()) return .stepped;
            const materializer: dict.Materializer = try .init(fiber.allocator, self.pairs.?.borrow(), false);
            self.work.borrowMut().* = .{ .materializing = materializer };
        }
        return switch (try self.work.borrowMut().materializing.advance(work)) {
            .pending => .stepped,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.work.borrowMut().finish(fiber.releases);
                break :completed .{ .output = result };
            },
        };
    }
};

fn mergePrimitive(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var right = try fiber.popValue();
    defer right.deinit();
    var left = try fiber.popValue();
    defer left.deinit();
    if (left.borrow() != .dict or right.borrow() != .dict) return fiber.typeError("two dicts");
    const left_count: usize = @intCast(left.borrow().dict.length());
    const right_count: usize = @intCast(right.borrow().dict.length());
    const pairs = try fiber.allocator.alloc(dict.Pair, left_count + right_count);
    try fiber.startDriver(MergeDriver{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .pairs = .init(pairs),
        .pair_count = left_count,
    });
}

pub fn mergeForModule(fiber: *Fiber) MachineError!void {
    return mergePrimitive(fiber);
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

    pub fn advance(fiber: *Fiber, self: *MergeDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (!work.exhausted()) switch (self.phase) {
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
                _ = work.spend();
            },
            .merge_right => {
                const count: usize = @intCast(self.right.borrow().dict.length());
                if (self.index == count) {
                    const materializer: dict.Materializer = try .init(fiber.allocator, self.pairs.borrow()[0..self.pair_count], false);
                    self.work.borrowMut().* = .{ .materializing = materializer };
                    self.phase = .materialize;
                    continue;
                }
                const key = dict.keyAt(self.right.borrow().dict, self.index);
                if (self.work.borrowMut().* != .finding) self.work.borrowMut().* = .{
                    .finding = dict.FindCursor.initHeader(
                        fiber.allocator,
                        self.left.borrow().dict,
                        key,
                    ),
                };
                switch (try self.work.borrowMut().finding.advance(work)) {
                    .pending => _ = work.spend(),
                    .complete => {
                        const found = self.work.borrowMut().finding.foundIndex();
                        self.work.borrowMut().finish(fiber.releases);
                        const pair = dict.Pair{ key, dict.valueAt(self.right.borrow().dict, self.index) };
                        if (found) |destination| {
                            self.pairs.borrow()[destination][1] = pair[1];
                        } else {
                            self.pairs.borrow()[self.pair_count] = pair;
                            self.pair_count += 1;
                        }
                        self.index += 1;
                        _ = work.spend();
                    },
                }
            },
            .materialize => return switch (try self.work.borrowMut().materializing.advance(work)) {
                .pending => .stepped,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    self.work.borrowMut().finish(fiber.releases);
                    break :completed .{ .output = result };
                },
            },
        };
        return .stepped;
    }
};
