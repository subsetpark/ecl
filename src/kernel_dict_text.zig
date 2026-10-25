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
const poll = @import("poll.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

/// The text family also includes the hosted `str.format` idiom;
/// every other text operation is installed directly in core.
const Op = support.TextOp;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(Op)) |operation| {
        if (comptime definition(operation)) |word| try core.installBuiltin(word);
    }
}

pub fn formatForIdiom(evaluator: *Machine) MachineError!void {
    return formatPrimitive(evaluator);
}

fn definition(comptime operation: Op) ?env.BuiltinWord {
    return switch (operation) {
        .put => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "collection selector value -- collection", .doc = "Functionally replace list positions through a pervasive selector, or one whole-value dictionary key." },
        .del => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "collection selector -- collection", .doc = "Functionally remove list positions through a pervasive selector, or one whole-value dictionary key; a missing dictionary key is unchanged." },
        .split => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "string separator -- parts", .doc = "Split a string at every occurrence of a separator; an empty separator yields its Unicode scalar strings." },
        .join => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "strings separator -- string", .doc = "Join a list of strings with a separator string." },
        .str => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "value -- string", .doc = "Return the canonical printed representation of a value as a string." },
        .format => null,
    };
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(evaluator: *Machine) MachineError!void {
            return switch (operation) {
                .put => putPrimitive(evaluator),
                .del => delPrimitive(evaluator),
                .split => splitPrimitive(evaluator),
                .join => joinPrimitive(evaluator),
                .str => strPrimitive(evaluator),
                .format => formatPrimitive(evaluator),
            };
        }
    }.run);
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
            .rendering => |*renderer| switch (try renderer.advance(evaluator.workBudget())) {
                .pending => .stepped,
                .complete => |bytes| transitioned: {
                    renderer.deinit();
                    phase.* = .{ .materializing = .{
                        .bytes = bytes,
                        .cursor = .init(evaluator.allocator(), bytes),
                    } };
                    break :transitioned .stepped;
                },
            },
            .materializing => |*materializing| switch (materializing.cursor.advance(evaluator.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return evaluator.fail(
                    .domain,
                    "canonical rendering is not valid UTF-8",
                ),
            }) {
                .pending => .stepped,
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

pub fn keysForModule(evaluator: *Machine) MachineError!void {
    return keysPrimitive(evaluator);
}

fn sizePrimitive(evaluator: *Machine) MachineError!void {
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    try evaluator.pushOwned(.{ .int = @intCast(dictionary.borrow().dict.length()) });
}

pub fn sizeForModule(evaluator: *Machine) MachineError!void {
    return sizePrimitive(evaluator);
}

fn valsPrimitive(evaluator: *Machine) MachineError!void {
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const values = dict.valsOf(dictionary.borrow().dict);
    try evaluator.pushBorrowed(values);
}

pub fn valsForModule(evaluator: *Machine) MachineError!void {
    return valsPrimitive(evaluator);
}

fn hasPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var key = try evaluator.popValue();
    defer key.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const cursor = dict.FindCursor.initHeader(
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

pub fn hasForModule(evaluator: *Machine) MachineError!void {
    return hasPrimitive(evaluator);
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

    pub fn advance(evaluator: *Machine, self: *HasDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |found| .{ .output = .{ .int = @intFromBool(found != null) } },
        };
    }
};

pub fn putForModule(evaluator: *Machine) MachineError!void {
    return putImpl(evaluator, true);
}

fn putPrimitive(evaluator: *Machine) MachineError!void {
    return putImpl(evaluator, false);
}

fn putImpl(evaluator: *Machine, comptime dictionary_only: bool) MachineError!void {
    try evaluator.require(3);
    var new_value = try evaluator.popValue();
    defer new_value.deinit();
    var key = try evaluator.popValue();
    defer key.deinit();
    var collection = try evaluator.popValue();
    defer collection.deinit();
    if (dictionary_only and collection.borrow() != .dict) return evaluator.typeError("a dict");
    switch (collection.borrow()) {
        .dict => {
            const finder = dict.FindCursor.initHeader(
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
            if (key.borrow() == .list) {
                if (try startTypedVectorPut(evaluator, &collection, &key, &new_value)) return;
                const count: usize = @intCast(collection.borrow().list.length());
                const values = try evaluator.allocator().alloc(Value, count);
                var actions = poll.ChunkStack(PutAction).init(evaluator.allocator());
                errdefer actions.deinit();
                try actions.push(.{ .node = .{
                    .selector = key.borrow(),
                    .replacement = new_value.borrow(),
                    .depth = 0,
                } });
                try evaluator.startDriver(PervasivePutDriver{
                    .collection = .init(collection.take()),
                    .selector = .init(key.take()),
                    .replacement = .init(new_value.take()),
                    .values = .init(values),
                    .actions = .init(actions),
                });
                return;
            }
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
        .int, .float, .char, .symbol, .word, .task, .port => return evaluator.typeError("a list or dict"),
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

    pub fn advance(evaluator: *Machine, self: *PervasivePutDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
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
                            return evaluator.fail(.domain, "put selector nesting exceeds 256 levels");
                        const selector_count: usize = @intCast(node.selector.list.length());
                        const conforming = node.replacement == .list;
                        if (conforming) {
                            const replacement_count: usize = @intCast(node.replacement.list.length());
                            if (selector_count != replacement_count)
                                return evaluator.conformError(selector_count, replacement_count);
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
                        return evaluator.typeError("an integer list index");
                    if (node.selector.int < 0)
                        return evaluator.fail(.domain, "put index is negative");
                    const index = std.math.cast(usize, node.selector.int) orelse
                        return evaluator.fail(.domain, "put index is out of bounds");
                    if (index >= output.len)
                        return evaluator.fail(.domain, "put index is out of bounds");
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
            self.materializer = .init(list.ValueMaterializer.init(evaluator.allocator(), output));
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
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
    .leaf_symbol,
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
        .leaf_symbol => switch (item) {
            .symbol => |symbol| symbol,
            else => null,
        },
        .generic_spine, .dict, .task, .port, .reserved_mask => unreachable,
    };
}

/// A typed copy of a leaf with one element replaced.
fn ListPutKernel(comptime kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    return struct {
        pub const arity = 1;
        pub const Params = struct { replacement: Element, index: usize };
        pub const Output = heap.LeafWriter(kind);

        pub fn prepare(evaluator: *Machine, _: [1]Value, _: Params, length: usize) error{OutOfMemory}!Output {
            return .init(evaluator.allocator(), length);
        }

        pub fn chunk(put: Params, operands: [1]Value, output: *Output, range: kernel_flat.Chunk, _: support.Context) MachineError!void {
            const out = output.unpublishedRange(range.start, range.len());
            @memcpy(out, heap.leafElements(kind, operands[0].list)[range.start..range.end]);
            if (put.index >= range.start and put.index < range.end) out[put.index - range.start] = put.replacement;
        }

        pub fn finish(output: *Output) Value {
            return output.finish();
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
            try support.Kernel(ListPutKernel(candidate)).run(
                evaluator,
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

/// The result buffer: a fresh copy, or the collection itself when this put
/// holds its only reference. Indices are validated before the first store, so
/// a reused collection is never left half-replaced by a failing put.
fn VectorPutOutput(comptime kind: value.HeapKind) type {
    return union(enum) {
        const Self = @This();
        fresh: heap.LeafWriter(kind),
        /// Publishing republishes the collection's own list, so the
        /// collection's reference becomes the result's.
        reuse: heap.UniqueLeafAdoption(kind),

        fn items(self: *Self, count: usize) []heap.LeafElement(kind) {
            return switch (self.*) {
                .fresh => |*writer| writer.unpublishedRange(0, count),
                .reuse => |*adoption| adoption.inPlaceRange(0, count),
            };
        }
    };
}

/// `put` with a flat typed index vector into a typed leaf, in three phases:
/// validate every index, copy the collection unless it is reused, then
/// scatter. Validation reports the first bad index in selector order, as on
/// the pervasive path. Operand 0 is the collection, operand 1 the indices,
/// and operand 2, unless the replacement is an atom, the replacement leaf.
fn VectorPutKernel(
    comptime kind: value.HeapKind,
    comptime index_kind: value.HeapKind,
    comptime replacement: VectorReplacement,
) type {
    const Element = heap.LeafElement(kind);
    const Index = heap.LeafElement(index_kind);
    return struct {
        pub const arity = if (replacement == .atom) 2 else 3;
        /// The atom stored at every selected position.
        pub const Params = if (replacement == .atom) Element else void;
        pub const Output = struct {
            phase: enum { validate, copy, scatter } = .validate,
            result: VectorPutOutput(kind),
            count: usize,
            selected: usize,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                switch (self.result) {
                    .fresh => |*writer| writer.retirePartial(releases),
                    .reuse => |*adoption| adoption.abandon(),
                }
            }
        };

        pub fn prepare(evaluator: *Machine, operands: [arity]Value, _: Params, _: usize) error{OutOfMemory}!Output {
            const collection = operands[0].list;
            const count: usize = @intCast(collection.length());
            return .{
                .result = if (heap.UniqueLeafAdoption(kind).claim(collection, count)) |claim|
                    .{ .reuse = claim }
                else
                    .{ .fresh = try heap.LeafWriter(kind).init(evaluator.allocator(), count) },
                .count = count,
                .selected = @intCast(operands[1].list.length()),
            };
        }

        pub fn chunk(atom: Params, operands: [arity]Value, output: *Output, range: kernel_flat.Chunk, context: support.Context) MachineError!void {
            const indices = heap.leafElements(index_kind, operands[1].list);
            switch (output.phase) {
                .validate => if (kernel_flat.firstIndexFault(Index, indices[range.start..range.end], output.count)) |fault| return switch (fault.kind) {
                    .negative => context.fail(.domain, "put index is negative"),
                    .out_of_bounds => context.fail(.domain, "put index is out of bounds"),
                },
                .copy => output.result.fresh.writeRange(range.start, heap.leafElements(kind, operands[0].list)[range.start..range.end]),
                .scatter => {
                    const out = output.result.items(output.count);
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

        pub fn next(_: support.Context, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .validate => if (output.result == .fresh) {
                    output.phase = .copy;
                    return output.count;
                },
                .copy => {},
                .scatter => return null,
            }
            output.phase = .scatter;
            return output.selected;
        }

        pub fn adopted(output: *const Output) ?usize {
            return if (output.result == .reuse) 0 else null;
        }

        pub fn finish(output: *Output) Value {
            return switch (output.result) {
                .fresh => |*writer| writer.finish(),
                .reuse => |*adoption| adoption.finish(),
            };
        }
    };
}

/// Starts the typed vector put when the collection is a typed leaf, the
/// selector a flat byte or integer leaf, and the replacement an atom of the
/// collection's class or a conforming leaf that needs no widening of the
/// result. Anything else, including a mismatched replacement length, returns
/// false and takes the pervasive path, which owns those errors.
fn startTypedVectorPut(
    evaluator: *Machine,
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
                        try support.Kernel(VectorPutKernel(candidate, candidate_index, .same)).run(evaluator, .{ collection, selector, replacement }, {}, selected)
                    else if (candidate == .leaf_i64 and items.kind() == .leaf_u8)
                        try support.Kernel(VectorPutKernel(candidate, candidate_index, .bytes)).run(evaluator, .{ collection, selector, replacement }, {}, selected)
                    else
                        return false,
                    else => {
                        const atom = typedReplacement(candidate, replacement.borrow()) orelse return false;
                        try support.Kernel(VectorPutKernel(candidate, candidate_index, .atom)).run(evaluator, .{ collection, selector }, atom, selected);
                    },
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

    pub fn advance(evaluator: *Machine, self: *ListPutDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        if (self.materializer == null) {
            const values = self.values.borrow();
            const end = self.index + work.take(values.len - self.index);
            while (self.index != end) : (self.index += 1) values[self.index] =
                if (self.index == self.replace_index)
                    self.new_value.borrow()
                else
                    list.atUnchecked(self.collection.borrow(), self.index);
            if (self.index != values.len) return .stepped;
            self.materializer = .init(list.ValueMaterializer.init(evaluator.allocator(), values));
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
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

    pub fn advance(evaluator: *Machine, self: *DictPutDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        if (self.work.borrowMut().* == .finding) switch (try self.work.borrowMut().finding.advance(work)) {
            .pending => return .stepped,
            .complete => {
                self.found_index = self.work.borrowMut().finding.foundIndex();
                self.work.borrowMut().finish(evaluator.releaseDomain());
                const old_count: usize = @intCast(self.dictionary.borrow().dict.length());
                self.pairs = .init(try evaluator.allocator().alloc(
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
            const materializer: dict.Materializer = try .initBorrowedPairs(evaluator.allocator(), pairs, false);
            self.work.borrowMut().* = .{ .materializing = materializer };
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.work.borrowMut().materializing.advance(work)) {
            .pending => .stepped,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.work.borrowMut().finish(evaluator.releaseDomain());
                break :completed .{ .output = result };
            },
        };
    }
};

pub fn fromListsForModule(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var values = try evaluator.popValue();
    defer values.deinit();
    var keys = try evaluator.popValue();
    defer keys.deinit();
    if (keys.borrow() != .list or values.borrow() != .list) return evaluator.typeError("two lists");
    const count: usize = @intCast(keys.borrow().list.length());
    if (values.borrow().list.length() != keys.borrow().list.length()) {
        return evaluator.fail(.shape, "dict.from-lists requires equal key and value lengths");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count);
    try evaluator.startDriver(FromListsDriver{
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

    pub fn advance(evaluator: *Machine, self: *FromListsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        if (self.materializer == null) {
            const pairs = self.pairs.borrow();
            const end = self.index + work.take(pairs.len - self.index);
            while (self.index != end) : (self.index += 1) pairs[self.index] = .{
                list.atUnchecked(self.keys.borrow(), self.index),
                list.atUnchecked(self.values.borrow(), self.index),
            };
            if (self.index != pairs.len or work.exhausted()) return .stepped;
            self.materializer = .init(try .init(evaluator.allocator(), pairs, true));
        }
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .duplicate_key => evaluator.fail(.domain, "dict.from-lists keys must be distinct"),
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
    var collection = try evaluator.popValue();
    defer collection.deinit();
    switch (collection.borrow()) {
        .dict => {
            const finder = dict.FindCursor.initHeader(
                evaluator.allocator(),
                collection.borrow().dict,
                key.borrow(),
            );
            try evaluator.startDriver(DictDelDriver{
                .dictionary = .init(collection.take()),
                .key = .init(key.take()),
                .work = .init(.{ .finding = finder }),
            });
        },
        .list => {
            if (key.borrow() == .list) {
                if (try startTypedDel(evaluator, &collection, &key)) return;
                const count: usize = @intCast(collection.borrow().list.length());
                const removed = try evaluator.allocator().alloc(bool, count);
                var removed_owned_locally = true;
                errdefer if (removed_owned_locally) evaluator.allocator().free(removed);
                var selector_cursor = try support.PervasiveSelectorCursor.init(
                    evaluator.allocator(),
                    key.borrow(),
                );
                var cursor_owned_locally = true;
                errdefer if (cursor_owned_locally) selector_cursor.retire(evaluator.releaseDomain());
                removed_owned_locally = false;
                cursor_owned_locally = false;
                try evaluator.startDriver(PervasiveDelDriver{
                    .collection = .init(collection.take()),
                    .selector = .init(key.take()),
                    .removed = .init(removed),
                    .selector_cursor = .init(selector_cursor),
                });
                return;
            }
            if (key.borrow() != .int) return evaluator.typeError("an integer list index");
            if (key.borrow().int < 0) return evaluator.fail(.domain, "del index is negative");
            const index = std.math.cast(usize, key.borrow().int) orelse
                return evaluator.fail(.domain, "del index is out of bounds");
            const count: usize = @intCast(collection.borrow().list.length());
            if (index >= count) return evaluator.fail(.domain, "del index is out of bounds");
            if (try startTypedDel(evaluator, &collection, &key)) return;
            const values = try evaluator.allocator().alloc(Value, count - 1);
            try evaluator.startDriver(ListDelDriver{
                .collection = .init(collection.take()),
                .key = .init(key.take()),
                .removed_index = index,
                .values = .init(values),
            });
        },
        .int, .float, .char, .symbol, .word, .task, .port => return evaluator.typeError("a list or dict"),
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

    pub fn advance(evaluator: *Machine, self: *PervasiveDelDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
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
                    .depth_exceeded => return evaluator.fail(.domain, "del selector nesting exceeds 256 levels"),
                    .leaf => |selector| {
                        if (selector != .int)
                            return evaluator.typeError("an integer list index");
                        if (selector.int < 0)
                            return evaluator.fail(.domain, "del index is negative");
                        const position = std.math.cast(usize, selector.int) orelse
                            return evaluator.fail(.domain, "del index is out of bounds");
                        if (position >= self.removed.borrow().len)
                            return evaluator.fail(.domain, "del index is out of bounds");
                        if (!self.removed.borrow()[position]) {
                            self.removed.borrow()[position] = true;
                            self.removed_count += 1;
                        }
                    },
                    .complete => {
                        self.selector_cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.selector_cursor = null;
                        self.values = .init(try evaluator.allocator().alloc(
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
                        evaluator.allocator(),
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
                    self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
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
        pub const Output = heap.LeafWriter(kind);

        pub fn prepare(evaluator: *Machine, _: [1]Value, _: usize, length: usize) error{OutOfMemory}!Output {
            return .init(evaluator.allocator(), length - 1);
        }

        pub fn chunk(removed: usize, operands: [1]Value, output: *Output, range: kernel_flat.Chunk, _: support.Context) MachineError!void {
            const source = heap.leafElements(kind, operands[0].list);
            const left_end = @min(range.end, removed);
            if (range.start < left_end) output.writeRange(range.start, source[range.start..left_end]);
            const right_start = @max(range.start, removed + 1);
            if (right_start < range.end) output.writeRange(right_start - 1, source[right_start..range.end]);
        }

        pub fn finish(output: *Output) Value {
            return output.finish();
        }
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

        pub fn prepare(evaluator: *Machine, operands: [2]Value, _: void, length: usize) error{OutOfMemory}!Output {
            return .{
                .allocator = evaluator.allocator(),
                .removed = try evaluator.allocator().alloc(bool, length),
                .selected = @intCast(operands[1].list.length()),
            };
        }

        pub fn chunk(_: void, operands: [2]Value, output: *Output, range: kernel_flat.Chunk, context: support.Context) MachineError!void {
            switch (output.phase) {
                .initialize => @memset(output.removed[range.start..range.end], false),
                .mark => {
                    const run = heap.leafElements(index_kind, operands[1].list)[range.start..range.end];
                    if (kernel_flat.firstIndexFault(Index, run, output.removed.len)) |fault| return switch (fault.kind) {
                        .negative => context.fail(.domain, "del index is negative"),
                        .out_of_bounds => context.fail(.domain, "del index is out of bounds"),
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

        pub fn next(context: support.Context, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .initialize => {
                    output.phase = .mark;
                    return output.selected;
                },
                .mark => {
                    output.writer = try .init(context.allocator(), output.removed.len - output.removed_count);
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
fn startTypedDel(evaluator: *Machine, collection: *heap.OwnedValue, selection: *heap.OwnedValue) MachineError!bool {
    const kind = collection.borrow().list.kind();
    const count: usize = @intCast(collection.borrow().list.length());
    inline for (put_leaf_kinds) |candidate| {
        if (kind == candidate) {
            switch (selection.borrow()) {
                .int => |index| try support.Kernel(DelOneKernel(candidate)).run(evaluator, .{collection}, @intCast(index), count),
                .list => |indices| switch (indices.kind()) {
                    inline .leaf_u8, .leaf_i64 => |index_kind| try support.Kernel(DelManyKernel(candidate, index_kind)).run(
                        evaluator,
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

    pub fn advance(evaluator: *Machine, self: *ListDelDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
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
                evaluator.allocator(),
                self.values.borrow(),
            ));
        }
        if (work.exhausted()) return .stepped;
        return switch (try self.materializer.?.borrowMut().advance(work)) {
            .pending => .stepped,
            .complete => |result| completed: {
                self.materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
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

    pub fn advance(evaluator: *Machine, self: *DictDelDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        if (self.work.borrowMut().* == .finding) switch (try self.work.borrowMut().finding.advance(work)) {
            .pending => return .stepped,
            .complete => {
                self.removed_index = self.work.borrowMut().finding.foundIndex();
                self.work.borrowMut().finish(evaluator.releaseDomain());
                if (self.removed_index == null) {
                    heap.retainValue(self.dictionary.borrow());
                    return .{ .output = self.dictionary.borrow() };
                }
                const count: usize = @intCast(self.dictionary.borrow().dict.length());
                self.pairs = .init(try evaluator.allocator().alloc(dict.Pair, count - 1));
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
            const materializer: dict.Materializer = try .init(evaluator.allocator(), self.pairs.?.borrow(), false);
            self.work.borrowMut().* = .{ .materializing = materializer };
        }
        return switch (try self.work.borrowMut().materializing.advance(work)) {
            .pending => .stepped,
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

pub fn mergeForModule(evaluator: *Machine) MachineError!void {
    return mergePrimitive(evaluator);
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
        const work = evaluator.workBudget();
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
                    const materializer: dict.Materializer = try .init(evaluator.allocator(), self.pairs.borrow()[0..self.pair_count], false);
                    self.work.borrowMut().* = .{ .materializing = materializer };
                    self.phase = .materialize;
                    continue;
                }
                const key = dict.keyAt(self.right.borrow().dict, self.index);
                if (self.work.borrowMut().* != .finding) self.work.borrowMut().* = .{
                    .finding = dict.FindCursor.initHeader(
                        evaluator.allocator(),
                        self.left.borrow().dict,
                        key,
                    ),
                };
                switch (try self.work.borrowMut().finding.advance(work)) {
                    .pending => _ = work.spend(),
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
                        _ = work.spend();
                    },
                }
            },
            .materialize => return switch (try self.work.borrowMut().materializing.advance(work)) {
                .pending => .stepped,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    self.work.borrowMut().finish(evaluator.releaseDomain());
                    break :completed .{ .output = result };
                },
            },
        };
        return .stepped;
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
    // The scan has one position per comparison it may make: each candidate
    // start costs up to one comparison per separator codepoint. An empty
    // separator makes every codepoint a part, one position each.
    const scan_length = if (separator_len == 0)
        text_len
    else if (separator_len > text_len)
        0
    else
        // No two allocatable strings overflow this.
        std.math.mul(usize, text_len - separator_len + 1, separator_len) catch
            return error.OutOfMemory;
    const text_kind = text.borrow().list.kind();
    const separator_kind = separator.borrow().list.kind();
    inline for (char_leaf_kinds) |candidate_text| {
        if (text_kind == candidate_text) inline for (char_leaf_kinds) |candidate_separator| {
            if (separator_kind == candidate_separator) return support.Kernel(SplitKernel(candidate_text, candidate_separator)).run(
                evaluator,
                .{ &text, &separator },
                {},
                scan_length,
            );
        };
    }
    unreachable;
}

const char_leaf_kinds = [_]value.HeapKind{ .leaf_char1, .leaf_char2, .leaf_char4 };

/// Splits a string at every occurrence of a separator, in three phases: the
/// scan records each part's bounds, the profile finds each part's widest
/// codepoint, and the fill writes each part at exactly that width into the
/// result spine. Operand 0 is the text, operand 1 the separator.
fn SplitKernel(comptime text_kind: value.HeapKind, comptime separator_kind: value.HeapKind) type {
    const Part = struct { start: usize, end: usize, max_codepoint: u32 = 0 };
    return struct {
        pub const arity = 2;
        pub const Params = void;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            phase: enum { scan, profile, fill } = .scan,
            text_len: usize,
            separator_len: usize,
            /// Room for every part's bounds, at most one more than the
            /// text's length; the first `part_count` are recorded.
            parts: []Part,
            part_count: usize = 0,
            /// Where the part being scanned starts, and the first candidate
            /// start not inside a separator already matched.
            part_start: usize = 0,
            next_candidate: usize = 0,
            /// The part a profile or fill is in, and how far into it.
            part: usize = 0,
            offset: usize = 0,
            writer: ?kernel_flat.CodepointWriter = null,
            spine: ?heap.OwnedValueBuffer = null,

            fn record(self: *Output, part: Part) void {
                self.parts[self.part_count] = part;
                self.part_count += 1;
            }

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.allocator.free(self.parts);
                if (self.writer) |*writer| writer.retire(releases);
                if (self.spine) |*spine| spine.deinit();
            }
        };

        pub fn prepare(evaluator: *Machine, operands: [2]Value, _: void, _: usize) error{OutOfMemory}!Output {
            const text_len: usize = @intCast(operands[0].list.length());
            return .{
                .allocator = evaluator.allocator(),
                .text_len = text_len,
                .separator_len = @intCast(operands[1].list.length()),
                .parts = try evaluator.allocator().alloc(Part, text_len + 1),
            };
        }

        pub fn chunk(_: void, operands: [2]Value, output: *Output, range: kernel_flat.Chunk, context: support.Context) MachineError!void {
            const text = heap.leafElements(text_kind, operands[0].list);
            switch (output.phase) {
                .scan => scan(output, text, heap.leafElements(separator_kind, operands[1].list), range),
                .profile => profile(output, text, range.len()),
                .fill => try fill(output, context, text, range.len()),
            }
        }

        pub fn next(context: support.Context, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .scan => {
                    if (output.separator_len != 0) output.record(.{
                        .start = output.part_start,
                        .end = output.text_len,
                    });
                    output.phase = .profile;
                    return partCodepoints(output);
                },
                .profile => {
                    output.spine = try heap.OwnedValueBuffer.init(context.releaseDomain(), output.part_count);
                    output.part = 0;
                    output.offset = 0;
                    output.phase = .fill;
                    // A part also costs one position to begin, so an empty
                    // part is not free.
                    return partCodepoints(output) + output.part_count;
                },
                .fill => return null,
            }
        }

        pub fn finish(output: *Output) Value {
            output.allocator.free(output.parts);
            return output.spine.?.takeList();
        }

        /// What the parts hold: the text less every matched separator.
        fn partCodepoints(output: *const Output) usize {
            if (output.separator_len == 0) return output.text_len;
            return output.text_len - (output.part_count - 1) * output.separator_len;
        }

        fn matchesAt(text: anytype, separator: anytype, start: usize) bool {
            for (separator, text[start..][0..separator.len]) |expected, actual| {
                if (@as(u32, expected) != @as(u32, actual)) return false;
            }
            return true;
        }

        /// Tries each candidate start whose first comparison lies in `range`.
        fn scan(output: *Output, text: anytype, separator: anytype, range: kernel_flat.Chunk) void {
            if (output.separator_len == 0) {
                for (range.start..range.end) |index| output.record(.{ .start = index, .end = index + 1 });
                return;
            }
            const width = output.separator_len;
            var candidate = range.start / width + @intFromBool(range.start % width != 0);
            while (candidate * width < range.end) : (candidate += 1) {
                if (candidate < output.next_candidate or !matchesAt(text, separator, candidate)) continue;
                output.record(.{ .start = output.part_start, .end = candidate });
                output.part_start = candidate + width;
                output.next_candidate = candidate + width;
            }
        }

        /// Finds the widest codepoint of the next `units` codepoints of the parts.
        fn profile(output: *Output, text: anytype, units: usize) void {
            var remaining = units;
            while (remaining != 0) {
                const part = &output.parts[output.part];
                const length = part.end - part.start;
                if (output.offset == length) {
                    output.part += 1;
                    output.offset = 0;
                    continue;
                }
                const take = @min(length - output.offset, remaining);
                for (text[part.start + output.offset ..][0..take]) |codepoint| part.max_codepoint = @max(part.max_codepoint, codepoint);
                output.offset += take;
                remaining -= take;
            }
        }

        /// Spends `units` on the fill: one to begin each part, then one per
        /// codepoint written; a part is appended to the spine once full.
        fn fill(output: *Output, context: support.Context, text: anytype, units: usize) error{OutOfMemory}!void {
            var remaining = units;
            while (true) {
                if (output.writer) |*writer| {
                    const part = output.parts[output.part];
                    const length = part.end - part.start;
                    if (output.offset == length) {
                        output.spine.?.appendOwned(writer.finish());
                        output.writer = null;
                        output.part += 1;
                        output.offset = 0;
                        continue;
                    }
                    if (remaining == 0) return;
                    const take = @min(kernel_flat.block_size, length - output.offset, remaining);
                    var block: [kernel_flat.block_size]u32 = undefined;
                    for (text[part.start + output.offset ..][0..take], block[0..take]) |codepoint, *out| out.* = codepoint;
                    writer.writeCodepoints(output.offset, block[0..take]);
                    output.offset += take;
                    remaining -= take;
                    continue;
                }
                if (remaining == 0 or output.part == output.part_count) return;
                const part = output.parts[output.part];
                output.writer = try kernel_flat.CodepointWriter.init(context.allocator(), part.end - part.start, part.max_codepoint);
                remaining -= 1;
            }
        }
    };
}

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
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        var block: [kernel_flat.block_size]u32 = undefined;
        while (!work.exhausted()) switch (self.phase) {
            .count => {
                const count: usize = @intCast(self.parts.borrow().list.length());
                if (self.part_index == count) {
                    if (!self.separator_profiled and count > 1) {
                        if (self.source == null) self.source = .init(AnyCharReader.acquire(self.separator.borrow()));
                        const source_count = self.source.?.borrow().len();
                        const copied = work.take(@min(kernel_flat.block_size, source_count - self.source_index));
                        self.source.?.borrow().copyCodepoints(self.source_index, block[0..copied]);
                        for (block[0..copied]) |codepoint| self.max_codepoint = @max(self.max_codepoint, codepoint);
                        self.source_index += copied;
                        if (self.source_index != source_count) return .stepped;
                        self.source.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.source = null;
                        self.source_index = 0;
                        self.separator_profiled = true;
                        if (!work.spend()) return .stepped;
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
                const copied = work.take(@min(kernel_flat.block_size, source_count - self.source_index));
                self.source.?.borrow().copyCodepoints(self.source_index, block[0..copied]);
                for (block[0..copied]) |codepoint| self.max_codepoint = @max(self.max_codepoint, codepoint);
                self.source_index += copied;
                if (self.source_index != source_count) return .stepped;
                self.source.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.source = null;
                self.source_index = 0;
                self.part_index += 1;
                if (!work.spend()) return .stepped;
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
                    _ = work.spend();
                    continue;
                }
                const copied = work.take(@min(kernel_flat.block_size, source_count - self.source_index));
                self.source.?.borrow().copyCodepoints(
                    self.source_index,
                    block[0..copied],
                );
                self.writer.?.borrowMut().writeCodepoints(self.output_index, block[0..copied]);
                self.output_index += copied;
                self.source_index += copied;
            },
        };
        return .stepped;
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
        .state = .init(.{ .scan = .{} }),
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
    state: heap.Owned(State),
    const Scan = struct {
        cursor: usize = 0,
        replacement_index: usize = 0,
        output_count: usize = 0,
    };
    const FillMode = union(enum) {
        template,
        replacement: usize,
    };
    const Fill = struct {
        output: heap.Owned([]u32),
        cursor: usize = 0,
        replacement_index: usize = 0,
        output_index: usize = 0,
        mode: FillMode = .template,
    };
    const State = union(enum) {
        scan: Scan,
        render: struct {
            scan: Scan,
            renderer: heap.Owned(printer.OwnedStringCursor),
        },
        materialize_replacement: struct {
            scan: Scan,
            rendered: heap.Owned([]u8),
            materializer: heap.Owned(storage.Utf8Materializer),
        },
        fill: Fill,
        materialize: struct {
            output: heap.Owned([]u32),
            materializer: heap.Owned(list.CodepointMaterializer),
        },
        complete: heap.Owned([]u32),

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .scan => {},
                .render => |*render| render.renderer.deinit(releases, allocator),
                .materialize_replacement => |*materialize| {
                    materialize.materializer.deinit(releases, allocator);
                    materialize.rendered.deinit(releases, allocator);
                },
                .fill => |*fill| fill.output.deinit(releases, allocator),
                .materialize => |*materialize| {
                    materialize.materializer.deinit(releases, allocator);
                    materialize.output.deinit(releases, allocator);
                },
                .complete => |*output| output.deinit(releases, allocator),
            }
        }
    };
    fn templatePair(self: *const FormatDriver, cursor: usize) struct { codepoint: u32, next: ?u32 } {
        const count: usize = @intCast(self.template.borrow().list.length());
        return .{
            .codepoint = list.atUnchecked(self.template.borrow(), cursor).char,
            .next = if (cursor + 1 < count)
                list.atUnchecked(self.template.borrow(), cursor + 1).char
            else
                null,
        };
    }

    pub fn advance(evaluator: *Machine, self: *FormatDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.state.borrowMut().*) {
            .scan => |*scan| {
                const count: usize = @intCast(self.template.borrow().list.length());
                if (scan.cursor == count) {
                    if (scan.replacement_index != self.replacements.borrow().len) {
                        return evaluator.fail(.contract, "format has more values than placeholders");
                    }
                    const output = try evaluator.allocator().alloc(u32, scan.output_count);
                    self.state.borrowMut().* = .{ .fill = .{ .output = .init(output) } };
                    continue;
                }
                const pair = self.templatePair(scan.cursor);
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    try addFormatCount(evaluator, &scan.output_count, 1);
                    scan.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    if (scan.replacement_index == self.replacements.borrow().len) {
                        return evaluator.fail(.contract, "format has more placeholders than values");
                    }
                    scan.cursor += 2;
                    const replacement = list.atUnchecked(
                        self.values.borrow(),
                        scan.replacement_index,
                    );
                    if (replacement.isString()) {
                        self.replacements.borrow()[scan.replacement_index] = .{ .text = replacement };
                        try addFormatCount(
                            evaluator,
                            &scan.output_count,
                            @intCast(replacement.list.length()),
                        );
                        scan.replacement_index += 1;
                    } else {
                        const renderer = try printer.OwnedStringCursor.init(
                            evaluator.allocator(),
                            replacement,
                        );
                        self.state.borrowMut().* = .{ .render = .{
                            .scan = scan.*,
                            .renderer = .init(renderer),
                        } };
                    }
                } else if (pair.codepoint == '{' or pair.codepoint == '}') {
                    return evaluator.fail(.domain, "format contains an unmatched brace");
                } else {
                    try addFormatCount(evaluator, &scan.output_count, 1);
                    scan.cursor += 1;
                }
                _ = work.spend();
            },
            .render => |*render| switch (try render.renderer.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |bytes| {
                    const scan = render.scan;
                    render.renderer.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .materialize_replacement = .{
                        .scan = scan,
                        .rendered = .init(bytes),
                        .materializer = .init(.init(evaluator.allocator(), bytes)),
                    } };
                    return .stepped;
                },
            },
            .materialize_replacement => |*materialize| switch (materialize.materializer.borrowMut().advance(work) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return evaluator.fail(.domain, "rendered value is not valid UTF-8"),
            }) {
                .pending => return .stepped,
                .complete => |text| {
                    var scan = materialize.scan;
                    materialize.materializer.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    materialize.rendered.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.replacements.borrow()[scan.replacement_index] = .{ .text = text };
                    self.replacement_values.borrowMut().appendOwned(text);
                    try addFormatCount(evaluator, &scan.output_count, @intCast(text.list.length()));
                    scan.replacement_index += 1;
                    self.state.borrowMut().* = .{ .scan = scan };
                    return .stepped;
                },
            },
            .fill => |*fill| {
                switch (fill.mode) {
                    .replacement => |replacement_cursor| {
                        const replacement = self.replacements.borrow()[fill.replacement_index];
                        if (replacement_cursor == replacement.text.list.length()) {
                            fill.mode = .template;
                            fill.replacement_index += 1;
                            continue;
                        }
                        fill.output.borrow()[fill.output_index] = list.atUnchecked(
                            replacement.text,
                            replacement_cursor,
                        ).char;
                        fill.mode = .{ .replacement = replacement_cursor + 1 };
                        fill.output_index += 1;
                        _ = work.spend();
                        continue;
                    },
                    .template => {},
                }
                const count: usize = @intCast(self.template.borrow().list.length());
                if (fill.cursor == count) {
                    std.debug.assert(fill.output_index == fill.output.borrow().len);
                    const materializer = list.CodepointMaterializer.init(
                        evaluator.allocator(),
                        fill.output.borrow(),
                    );
                    self.state.borrowMut().* = .{ .materialize = .{
                        .output = .init(fill.output.take()),
                        .materializer = .init(materializer),
                    } };
                    continue;
                }
                const pair = self.templatePair(fill.cursor);
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    fill.output.borrow()[fill.output_index] = pair.codepoint;
                    fill.output_index += 1;
                    fill.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    fill.mode = .{ .replacement = 0 };
                    fill.cursor += 2;
                } else {
                    fill.output.borrow()[fill.output_index] = pair.codepoint;
                    fill.output_index += 1;
                    fill.cursor += 1;
                }
                _ = work.spend();
            },
            .materialize => |*materialize| return switch (try materialize.materializer.borrowMut().advance(work)) {
                .pending => .stepped,
                .complete => |result| completed: {
                    materialize.materializer.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .complete = .init(materialize.output.take()) };
                    break :completed .{ .output = result };
                },
            },
            .complete => unreachable,
        };
        return .stepped;
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
