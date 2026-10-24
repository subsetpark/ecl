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
                if (try startTypedVectorPut(evaluator, &collection, key.borrow(), new_value.borrow())) return;
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
        .int, .float, .char, .symbol, .word, .task, .module, .port => return evaluator.typeError("a list or dict"),
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
        .generic_spine, .dict, .task, .module, .port, .reserved_mask => unreachable,
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
            if (!self.cursor.complete()) return .stepped;
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

/// What a typed vector put stores: one atom at every selected position, or a
/// conforming leaf read in the collection's representation. A byte leaf widens
/// losslessly into an integer collection, since literal and profiled integer
/// lists are bytes whenever they can be.
fn VectorReplacement(comptime kind: value.HeapKind) type {
    return union(enum) {
        const Self = @This();
        atom: heap.LeafElement(kind),
        same: heap.LeafReader(kind),
        bytes: heap.LeafReader(.leaf_u8),

        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .atom => {},
                .same => |*reader| reader.release(releases),
                .bytes => |*reader| reader.release(releases),
            }
        }
    };
}

/// The result buffer: a fresh copy, or the collection itself when this put
/// holds its only reference. Indices are validated before the first store, so
/// a reused collection is never left half-replaced by a failing put.
fn VectorPutOutput(comptime kind: value.HeapKind) type {
    return union(enum) {
        const Self = @This();
        fresh: struct { writer: heap.LeafWriter(kind), source: heap.LeafReader(kind) },
        /// `root` is the collection's reference; publishing republishes that
        /// same list, so the reference becomes the result's.
        reuse: struct { adoption: heap.UniqueLeafAdoption(kind), root: Value },

        fn items(self: *Self, count: usize) []heap.LeafElement(kind) {
            return switch (self.*) {
                .fresh => |*fresh| fresh.writer.unpublishedRange(0, count),
                .reuse => |*reuse| reuse.adoption.inPlaceRange(0, count),
            };
        }

        fn finish(self: *Self, releases: *heap.ReleaseDomain) Value {
            switch (self.*) {
                .fresh => |*fresh| {
                    fresh.source.release(releases);
                    return fresh.writer.finish();
                },
                .reuse => |*reuse| return reuse.adoption.finish(),
            }
        }

        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .fresh => |*fresh| {
                    fresh.writer.retirePartial(releases);
                    fresh.source.release(releases);
                },
                .reuse => |*reuse| {
                    reuse.adoption.abandon();
                    releases.releaseValue(reuse.root);
                },
            }
        }
    };
}

/// `put` with a flat typed index vector into a typed leaf: validate every
/// index, copy the collection unless it is reused, then scatter. Each phase
/// takes a granted range per transition. Validation reports the first bad
/// index in selector order, as on the pervasive path.
fn TypedVectorPutDriver(comptime kind: value.HeapKind, comptime index_kind: value.HeapKind) type {
    const Element = heap.LeafElement(kind);
    const Index = heap.LeafElement(index_kind);
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        indices: heap.Owned(heap.LeafReader(index_kind)),
        replacement: heap.Owned(VectorReplacement(kind)),
        output: heap.Owned(VectorPutOutput(kind)),
        count: usize,
        phase: enum { validate, copy, scatter } = .validate,
        position: usize = 0,

        fn scatter(out: []Element, indices: []const Index, offset: usize, replacement: VectorReplacement(kind)) void {
            switch (replacement) {
                .atom => |item| for (indices) |index| {
                    out[@intCast(index)] = item;
                },
                .same => |reader| for (indices, reader.slice()[offset..][0..indices.len]) |index, item| {
                    out[@intCast(index)] = item;
                },
                .bytes => |reader| if (kind == .leaf_i64) {
                    for (indices, reader.slice()[offset..][0..indices.len]) |index, item| out[@intCast(index)] = item;
                } else unreachable,
            }
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            try evaluator.pollKernel();
            const work = evaluator.workBudget();
            const indices = self.indices.borrow().slice();
            while (!work.exhausted()) switch (self.phase) {
                .validate => {
                    if (self.position == indices.len) {
                        self.position = 0;
                        self.phase = if (self.output.borrow() == .fresh) .copy else .scatter;
                        continue;
                    }
                    const granted = work.take(indices.len - self.position);
                    const selected = indices[self.position..][0..granted];
                    if (kernel_flat.firstIndexFault(Index, selected, self.count)) |fault| return switch (fault.kind) {
                        .negative => evaluator.fail(.domain, "put index is negative"),
                        .out_of_bounds => evaluator.fail(.domain, "put index is out of bounds"),
                    };
                    self.position += granted;
                },
                .copy => {
                    if (self.position == self.count) {
                        self.position = 0;
                        self.phase = .scatter;
                        continue;
                    }
                    const fresh = &self.output.borrowMut().fresh;
                    const granted = work.take(self.count - self.position);
                    fresh.writer.writeRange(self.position, fresh.source.slice()[self.position..][0..granted]);
                    self.position += granted;
                },
                .scatter => {
                    if (self.position == indices.len) {
                        self.indices.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.replacement.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        var output = self.output.take();
                        return .{ .output = output.finish(evaluator.releaseDomain()) };
                    }
                    const granted = work.take(indices.len - self.position);
                    scatter(
                        self.output.borrowMut().items(self.count),
                        indices[self.position..][0..granted],
                        self.position,
                        self.replacement.borrow(),
                    );
                    self.position += granted;
                },
            };
            return .stepped;
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
    selector: Value,
    replacement: Value,
) MachineError!bool {
    const kind = collection.borrow().list.kind();
    const index_kind = selector.list.kind();
    if (index_kind != .leaf_u8 and index_kind != .leaf_i64) return false;
    const selected: usize = @intCast(selector.list.length());
    if (replacement == .list and replacement.list.length() != selected) return false;
    inline for (put_leaf_kinds) |candidate| {
        if (kind == candidate) {
            const Replacement = VectorReplacement(candidate);
            const typed_replacement: Replacement = switch (replacement) {
                .list => |items| if (items.kind() == candidate)
                    .{ .same = heap.LeafReader(candidate).acquire(items) }
                else if (candidate == .leaf_i64 and items.kind() == .leaf_u8)
                    .{ .bytes = heap.LeafReader(.leaf_u8).acquire(items) }
                else
                    return false,
                else => .{ .atom = typedReplacement(candidate, replacement) orelse return false },
            };
            inline for ([_]value.HeapKind{ .leaf_u8, .leaf_i64 }) |candidate_index| {
                if (index_kind == candidate_index) {
                    return startTypedVectorPutDriver(candidate, candidate_index, evaluator, collection, selector, typed_replacement);
                }
            }
            unreachable;
        }
    }
    return false;
}

fn startTypedVectorPutDriver(
    comptime kind: value.HeapKind,
    comptime index_kind: value.HeapKind,
    evaluator: *Machine,
    collection: *heap.OwnedValue,
    selector: Value,
    replacement: VectorReplacement(kind),
) MachineError!bool {
    var held_replacement = replacement;
    var replacement_held = true;
    errdefer if (replacement_held) held_replacement.retire(evaluator.releaseDomain());
    const count: usize = @intCast(collection.borrow().list.length());
    const output: VectorPutOutput(kind) = if (heap.UniqueLeafAdoption(kind).claim(collection.borrow().list, count)) |claim|
        .{ .reuse = .{ .adoption = claim, .root = collection.take() } }
    else
        .{ .fresh = .{
            .writer = try heap.LeafWriter(kind).init(evaluator.allocator(), count),
            .source = heap.LeafReader(kind).acquire(collection.borrow().list),
        } };
    replacement_held = false;
    try evaluator.startDriver(TypedVectorPutDriver(kind, index_kind){
        .indices = .init(heap.LeafReader(index_kind).acquire(selector.list)),
        .replacement = .init(held_replacement),
        .output = .init(output),
        .count = count,
    });
    return true;
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
                const selection: ?DelSelection = switch (key.borrow().list.kind()) {
                    .leaf_u8 => .{ .bytes = heap.LeafReader(.leaf_u8).acquire(key.borrow().list) },
                    .leaf_i64 => .{ .ints = heap.LeafReader(.leaf_i64).acquire(key.borrow().list) },
                    else => null,
                };
                if (selection) |typed| if (try startTypedDel(evaluator, collection.borrow(), typed)) return;
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
            if (try startTypedDel(evaluator, collection.borrow(), .{ .one = index })) return;
            const values = try evaluator.allocator().alloc(Value, count - 1);
            try evaluator.startDriver(ListDelDriver{
                .collection = .init(collection.take()),
                .key = .init(key.take()),
                .removed_index = index,
                .values = .init(values),
            });
        },
        .int, .float, .char, .symbol, .word, .task, .module, .port => return evaluator.typeError("a list or dict"),
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
const DelSelection = union(enum) {
    one: usize,
    bytes: heap.LeafReader(.leaf_u8),
    ints: heap.LeafReader(.leaf_i64),

    pub fn retire(self: *DelSelection, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .one => {},
            .bytes => |*reader| reader.release(releases),
            .ints => |*reader| reader.release(releases),
        }
    }
};

/// `del` from a typed leaf: mark the selected positions in a mask, checking
/// each granted run of indices at once, then compact the kept elements into a
/// typed result. One scalar position needs no mask: the result is the two
/// slices around it. Every phase takes a granted range per transition.
fn TypedDelDriver(comptime kind: value.HeapKind) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;

        source: heap.Owned(heap.LeafReader(kind)),
        selection: heap.Owned(DelSelection),
        removed: ?heap.Owned([]bool) = null,
        writer: ?heap.Owned(heap.LeafWriter(kind)) = null,
        phase: enum { initialize, mark, copy } = .initialize,
        position: usize = 0,
        removed_count: usize = 0,
        destination: usize = 0,

        fn mark(self: *Self, evaluator: *Machine, comptime Index: type, indices: []const Index) MachineError!void {
            const removed = self.removed.?.borrow();
            const run = indices[self.position..][0..evaluator.workBudget().take(indices.len - self.position)];
            if (kernel_flat.firstIndexFault(Index, run, removed.len)) |fault| return switch (fault.kind) {
                .negative => evaluator.fail(.domain, "del index is negative"),
                .out_of_bounds => evaluator.fail(.domain, "del index is out of bounds"),
            };
            for (run) |index| {
                const slot = &removed[@intCast(index)];
                self.removed_count += @intFromBool(!slot.*);
                slot.* = true;
            }
            self.position += run.len;
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            try evaluator.pollKernel();
            const work = evaluator.workBudget();
            const source = self.source.borrow().slice();
            while (!work.exhausted()) switch (self.phase) {
                .initialize => {
                    if (self.selection.borrow() == .one) {
                        self.removed_count = 1;
                        self.phase = .copy;
                        continue;
                    }
                    if (self.removed == null) self.removed = .init(try evaluator.allocator().alloc(bool, source.len));
                    const removed = self.removed.?.borrow();
                    const granted = work.take(removed.len - self.position);
                    @memset(removed[self.position..][0..granted], false);
                    self.position += granted;
                    if (self.position != removed.len) continue;
                    self.position = 0;
                    self.phase = .mark;
                },
                .mark => {
                    const length = switch (self.selection.borrowMut().*) {
                        .one => unreachable,
                        .bytes => |*reader| length: {
                            try self.mark(evaluator, u8, reader.slice());
                            break :length reader.len();
                        },
                        .ints => |*reader| length: {
                            try self.mark(evaluator, i64, reader.slice());
                            break :length reader.len();
                        },
                    };
                    if (self.position != length) continue;
                    self.position = 0;
                    self.phase = .copy;
                },
                .copy => {
                    if (self.writer == null) self.writer = .init(try heap.LeafWriter(kind).init(
                        evaluator.allocator(),
                        source.len - self.removed_count,
                    ));
                    const writer = self.writer.?.borrowMut();
                    const end = self.position + work.take(source.len - self.position);
                    switch (self.selection.borrow()) {
                        .one => |removed_index| {
                            const left_end = @min(end, removed_index);
                            if (self.position < left_end)
                                writer.writeRange(self.position, source[self.position..left_end]);
                            const right_start = @max(self.position, removed_index + 1);
                            if (right_start < end)
                                writer.writeRange(right_start - 1, source[right_start..end]);
                        },
                        .bytes, .ints => {
                            const removed = self.removed.?.borrow();
                            const out = writer.unpublishedRange(0, writer.len());
                            for (source[self.position..end], removed[self.position..end]) |item, gone| {
                                if (gone) continue;
                                out[self.destination] = item;
                                self.destination += 1;
                            }
                        },
                    }
                    self.position = end;
                    if (self.position != source.len) continue;
                    self.source.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.selection.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    return .{ .output = writer.finish() };
                },
            };
            return .stepped;
        }
    };
}

/// Starts the typed `del` for a typed leaf collection and a validated scalar
/// position or a flat typed index leaf; false for any other shape.
fn startTypedDel(evaluator: *Machine, collection: Value, selection: DelSelection) MachineError!bool {
    var held = selection;
    const kind = collection.list.kind();
    inline for (put_leaf_kinds) |candidate| {
        if (kind == candidate) {
            try evaluator.startDriver(TypedDelDriver(candidate){
                .source = .init(heap.LeafReader(candidate).acquire(collection.list)),
                .selection = .init(held),
            });
            return true;
        }
    }
    held.retire(evaluator.releaseDomain());
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
        empty_part_index: usize = 0,
        scan_complete: bool = false,
        part_start: usize = 0,
        part_end: usize = 0,
        codepoint_index: usize = 0,
        part_max_codepoint: u32 = 0,
        part_writer: ?heap.Owned(kernel_flat.CodepointWriter) = null,
        result_materializer: ?heap.Owned(list.ValueMaterializer) = null,

        fn matchesAt(text: anytype, separator: anytype, start: usize) bool {
            for (separator, text[start..][0..separator.len]) |expected, actual| {
                if (@as(u32, expected) != @as(u32, actual)) return false;
            }
            return true;
        }

        fn beginPart(self: *Self, start: usize, end: usize) void {
            self.part_start = start;
            self.part_end = end;
            self.codepoint_index = 0;
            self.part_max_codepoint = 0;
            self.phase = .profile_part;
        }

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!machine.WorkProgress {
            try evaluator.pollKernel();
            const work = evaluator.workBudget();
            while (!work.exhausted()) switch (self.phase) {
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
                    // Try the start positions the budget pays for. A position
                    // costs up to one comparison per separator codepoint, and
                    // only the positions actually tried are charged.
                    const positions = @min(
                        text_len - separator_len + 1 - self.cursor,
                        @max(1, work.remaining / separator_len),
                    );
                    const first = self.cursor;
                    const end = self.cursor + positions;
                    const found = while (self.cursor != end) : (self.cursor += 1) {
                        if (matchesAt(text_slice, separator_slice, self.cursor)) break self.cursor;
                    } else null;
                    const tried = (if (found) |match_start| match_start + 1 else end) - first;
                    _ = work.take(tried * separator_len);
                    if (found) |match_start| {
                        self.cursor = match_start + separator_len;
                        self.beginPart(self.start, match_start);
                        self.start = self.cursor;
                    }
                },
                .profile_part => {
                    const part_len = self.part_end - self.part_start;
                    const end = self.codepoint_index + work.take(part_len - self.codepoint_index);
                    while (self.codepoint_index != end) : (self.codepoint_index += 1) {
                        self.part_max_codepoint = @max(
                            self.part_max_codepoint,
                            self.text.borrow().slice()[self.part_start + self.codepoint_index],
                        );
                    }
                    if (self.codepoint_index != part_len) return .stepped;
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
                        if (part_len == 0) _ = work.spend();
                        continue;
                    }
                    var block: [kernel_flat.block_size]u32 = undefined;
                    const copied = work.take(@min(kernel_flat.block_size, part_len - self.codepoint_index));
                    for (
                        self.text.borrow().slice()[self.part_start + self.codepoint_index ..][0..copied],
                        block[0..copied],
                    ) |codepoint, *out| out.* = codepoint;
                    self.part_writer.?.borrowMut().writeCodepoints(
                        self.codepoint_index,
                        block[0..copied],
                    );
                    self.codepoint_index += copied;
                },
                .materialize_result => switch (try self.result_materializer.?.borrowMut().advance(work)) {
                    .pending => return .stepped,
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
            return .stepped;
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
