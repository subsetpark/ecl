//! Immutable dictionary operations in one mixed host/hosted module.
//!
//! Representation observers and user-sized rebuilds reuse the host kernels.
//! Derived operations schedule ordinary quotations in this module's home, in
//! the same way the derived `io` words do. Quotation-dependent `update` reuses
//! the core combinator backend, while the one host helper needed by the hosted
//! `merge-with` fold is private, so no implementation primitive leaks through
//! qualified lookup, import, invocation, or reflection.
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const combinators = @import("../combinators.zig");
const dict_kernels = @import("../kernel_dict_text.zig");
const dict_storage = @import("../dict.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "size",
        .doc = "( dict -- count ) Return a dictionary's entry count.",
        .primitive = dict_kernels.sizeForModule,
    },
    .{
        .name = "keys",
        .doc = "( dict -- keys ) Return a dictionary's keys in insertion order.",
        .primitive = dict_kernels.keysForModule,
    },
    .{
        .name = "vals",
        .doc = "( dict -- values ) Return a dictionary's values in insertion order.",
        .primitive = dict_kernels.valsForModule,
    },
    .{
        .name = "pairs",
        .doc = "( dict -- pairs ) Return key/value pairs in insertion order.",
        .primitive = pairs,
    },
    .{
        .name = "has?",
        .doc = "( dict key -- bool ) Return whether a dictionary contains a whole-value key.",
        .primitive = dict_kernels.hasForModule,
    },
    .{
        .name = "at",
        .doc = "( dict keys -- values ) Return values for a key list in request order, failing if any key is absent.",
        .primitive = valuesAt,
    },
    .{
        .name = "merge",
        .doc = "( left right -- dict ) Merge two dictionaries, with right-hand values winning.",
        .primitive = dict_kernels.mergeForModule,
    },
    .{
        .name = "from-flat",
        .doc = "( entries -- dict ) Build a dictionary from one flat adjacent key/value list.",
        .primitive = fromFlat,
    },
    .{
        .name = "from-lists",
        .doc = "( keys values -- dict ) Build a dictionary from parallel key and value lists.",
        .primitive = dict_kernels.fromListsForModule,
    },
    .{
        .name = "from-pairs",
        .doc = "( pairs -- dict ) Build a dictionary from distinct two-element key/value pairs in list order.",
        .primitive = fromPairs,
    },
    .{
        .name = "from-keys",
        .doc = "( keys value -- dict ) Build a dictionary assigning one value to every distinct key.",
        .primitive = fromKeys,
    },
    .{
        .name = "keys-exactly?",
        .doc = "( candidate declared -- bool ) Test whether a dictionary has exactly the distinct declared keys, in any order.",
        .primitive = keysExactly,
    },
    .{
        .name = "update",
        .doc = "( dict keys quotation -- dict ) Apply a unary quotation at each requested whole-value key without reordering entries.",
        .primitive = combinators.updateDictKeysForModule,
    },
    .{
        .name = "update-or",
        .doc = "( dict key default quotation -- dict ) Update an existing value, or insert the default unchanged when absent.",
        .primitive = updateOr,
    },
    .{
        .name = "map",
        .doc = "( dict quotation -- dict ) Map a ( key value -- value ) quotation while preserving keys and order.",
        .primitive = map,
    },
    .{
        .name = "filter",
        .doc = "( dict predicate -- dict ) Keep entries selected by a ( key value -- bool ) predicate.",
        .primitive = filter,
    },
    .{
        .name = "reject",
        .doc = "( dict predicate -- dict ) Discard entries selected by a ( key value -- bool ) predicate.",
        .primitive = reject,
    },
    .{
        .name = "take",
        .doc = "( dict keys -- dict ) Keep named entries in dictionary order, ignoring missing keys.",
        .primitive = take,
    },
    .{
        .name = "drop",
        .doc = "( dict keys -- dict ) Remove named entries in dictionary order, ignoring missing keys.",
        .primitive = drop,
    },
    .{
        .name = "split",
        .doc = "( dict keys -- selected rejected ) Partition a dictionary by a key list.",
        .primitive = split,
    },
    .{
        .name = "merge-with",
        .doc = "( left right quotation -- dict ) Merge dictionaries and resolve collisions with ( key left right -- value ).",
        .primitive = mergeWith,
    },
};

fn word(name: []const u8) error{OutOfMemory}!Value {
    return .{ .word = .{ .name = try intern.intern(name) } };
}

fn symbol(name: []const u8) error{OutOfMemory}!Value {
    return .{ .symbol = try intern.intern(name) };
}

fn quotation(evaluator: *Machine, items: []const Value) error{OutOfMemory}!heap.OwnedValue {
    return .init(
        evaluator.releaseDomain(),
        try list.fromValues(evaluator.allocator(), items),
    );
}

fn call(evaluator: *Machine, items: []const Value) error{OutOfMemory}!void {
    const body = try list.fromValues(evaluator.allocator(), items);
    try evaluator.callOwned(body.list);
}

fn failureQuotation(
    evaluator: *Machine,
    kind: []const u8,
    message: []const u8,
) error{OutOfMemory}!heap.OwnedValue {
    var text = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), message),
    );
    defer text.deinit();
    return quotation(evaluator, &.{
        try word("pop"),
        try symbol(kind),
        try word("error.new"),
        text.borrow(),
        try word("error.with-message"),
        try word("raise"),
    });
}

fn pairs(evaluator: *Machine) MachineError!void {
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    return call(evaluator, &.{
        dictionary.borrow(),
        try word("dup"),
        try word("dict.keys"),
        try word("swap"),
        try word("dict.vals"),
        try word("zip"),
    });
}

fn valuesAt(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var keys = try evaluator.popList();
    defer keys.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    // This module's public `at` shadows core `at` in quotations scheduled in
    // the module home. A singleton path enters core-authored `at-path`, whose
    // sealed body resolves scalar `at` against core. Besides avoiding recursive
    // `dict.at`, wrapping preserves a structural list as one whole-value key.
    var lookup = try quotation(evaluator, &.{
        try word("swap"),
        try word("wrap"),
        try word("at-path"),
    });
    defer lookup.deinit();
    return call(evaluator, &.{
        keys.borrow(),
        dictionary.borrow(),
        lookup.borrow(),
        try word("partial"),
        try word("each"),
    });
}

fn fromFlat(evaluator: *Machine) MachineError!void {
    var entries = try evaluator.popValue();
    defer entries.deinit();
    if (entries.borrow() != .list) return evaluator.typeError("a flat key/value list");
    const count: usize = @intCast(entries.borrow().list.length());
    if (count % 2 != 0) {
        return evaluator.fail(.contract, "dict.from-flat requires an even-length key/value list");
    }
    const flat_pairs = try evaluator.allocator().alloc(dict_storage.Pair, count / 2);
    try evaluator.startDriver(FromFlatDriver{
        .entries = .init(entries.take()),
        .pairs = .init(flat_pairs),
    });
}

const FromFlatDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    entries: heap.Owned(Value),
    pairs: heap.Owned([]dict_storage.Pair),
    index: usize = 0,
    materializer: ?heap.Owned(dict_storage.Materializer) = null,

    pub fn advance(evaluator: *Machine, self: *FromFlatDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.materializer == null) {
            const flat_pairs = self.pairs.borrow();
            const end = @min(self.index + machine.kernel_poll_quantum, flat_pairs.len);
            while (self.index != end) : (self.index += 1) flat_pairs[self.index] = .{
                list.atUnchecked(self.entries.borrow(), self.index * 2),
                list.atUnchecked(self.entries.borrow(), self.index * 2 + 1),
            };
            if (self.index != flat_pairs.len) return .yielded;
            self.materializer = .init(try .init(evaluator.allocator(), flat_pairs, true));
            return .yielded;
        }
        return switch (try self.materializer.?.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .duplicate_key => evaluator.fail(.domain, "dict.from-flat received a duplicate key"),
            .complete => |dictionary| .{ .output = dictionary },
        };
    }
};

fn fromPairs(evaluator: *Machine) MachineError!void {
    var pairs_value = try evaluator.popValue();
    defer pairs_value.deinit();
    var pair_then = try quotation(evaluator, &.{ try word("len"), .{ .int = 2 }, try word("=") });
    defer pair_then.deinit();
    var pair_else = try quotation(evaluator, &.{ try word("pop"), .{ .int = 0 } });
    defer pair_else.deinit();
    var pair_shaped = try quotation(evaluator, &.{
        try word("dup"),
        try word("type"),
        try symbol("list"),
        try word("match?"),
        pair_then.borrow(),
        pair_else.borrow(),
        try word("if"),
    });
    defer pair_shaped.deinit();
    var shape_failure = try failureQuotation(
        evaluator,
        "shape",
        "dict.from-pairs expects two-element pairs",
    );
    defer shape_failure.deinit();
    var build = try quotation(evaluator, &.{ try word("raze"), try word("dict.from-flat") });
    defer build.deinit();
    var valid_list = try quotation(evaluator, &.{
        try word("dup"),
        pair_shaped.borrow(),
        try word("all?"),
        build.borrow(),
        shape_failure.borrow(),
        try word("if"),
    });
    defer valid_list.deinit();
    var type_failure = try failureQuotation(evaluator, "type", "dict.from-pairs expects a list");
    defer type_failure.deinit();
    return call(evaluator, &.{
        pairs_value.borrow(),
        try word("dup"),
        try word("type"),
        try symbol("list"),
        try word("match?"),
        valid_list.borrow(),
        type_failure.borrow(),
        try word("if"),
    });
}

fn fromKeys(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var repeated = try evaluator.popValue();
    defer repeated.deinit();
    var keys = try evaluator.popValue();
    defer keys.deinit();
    var discard_key = try quotation(evaluator, &.{try word("nip")});
    defer discard_key.deinit();
    return call(evaluator, &.{
        keys.borrow(),
        keys.borrow(),
        repeated.borrow(),
        discard_key.borrow(),
        try word("partial"),
        try word("each"),
        try word("dict.from-lists"),
    });
}

fn keysExactly(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var declared = try evaluator.popValue();
    defer declared.deinit();
    var candidate = try evaluator.popValue();
    defer candidate.deinit();
    var membership = try quotation(evaluator, &.{ try word("swap"), try word("dict.has?") });
    defer membership.deinit();
    return call(evaluator, &.{
        candidate.borrow(),
        try word("dict.keys"),
        try word("len"),
        declared.borrow(),
        try word("len"),
        try word("="),
        declared.borrow(),
        try word("distinct"),
        try word("len"),
        declared.borrow(),
        try word("len"),
        try word("="),
        try word("and"),
        declared.borrow(),
        candidate.borrow(),
        membership.borrow(),
        try word("partial"),
        try word("all?"),
        try word("and"),
    });
}

fn updateOr(evaluator: *Machine) MachineError!void {
    try evaluator.require(4);
    var transform = try evaluator.popQuotation();
    defer transform.deinit();
    var default = try evaluator.popValue();
    defer default.deinit();
    var key = try evaluator.popValue();
    defer key.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    var existing = try quotation(evaluator, &.{
        dictionary.borrow(),
        key.borrow(),
        try word("wrap"),
        try word("at-path"),
        transform.borrow(),
        try word("call"),
    });
    defer existing.deinit();
    var absent = try quotation(evaluator, &.{default.borrow()});
    defer absent.deinit();
    return call(evaluator, &.{
        dictionary.borrow(),
        key.borrow(),
        dictionary.borrow(),
        key.borrow(),
        try word("dict.has?"),
        existing.borrow(),
        absent.borrow(),
        try word("if"),
        try word("put"),
    });
}

fn entryApplication(evaluator: *Machine, transform: Value, negate: bool) error{OutOfMemory}!heap.OwnedValue {
    return quotation(evaluator, if (negate) &.{
        try word("dup"),
        try word("first"),
        try word("swap"),
        .{ .int = 1 },
        try word("wrap"),
        try word("at-path"),
        transform,
        try word("call"),
        try word("not"),
    } else &.{
        try word("dup"),
        try word("first"),
        try word("swap"),
        .{ .int = 1 },
        try word("wrap"),
        try word("at-path"),
        transform,
        try word("call"),
    });
}

fn map(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var transform = try evaluator.popQuotation();
    defer transform.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    var apply_entry = try entryApplication(evaluator, transform.borrow(), false);
    defer apply_entry.deinit();
    return call(evaluator, &.{
        dictionary.borrow(),
        try word("dict.keys"),
        dictionary.borrow(),
        try word("dict.pairs"),
        apply_entry.borrow(),
        try word("each"),
        try word("dict.from-lists"),
    });
}

fn selectEntries(evaluator: *Machine, reject_matches: bool) MachineError!void {
    try evaluator.require(2);
    var predicate = try evaluator.popQuotation();
    defer predicate.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    var apply_entry = try entryApplication(evaluator, predicate.borrow(), reject_matches);
    defer apply_entry.deinit();
    return call(evaluator, &.{
        dictionary.borrow(),
        try word("dict.pairs"),
        try word("dup"),
        apply_entry.borrow(),
        try word("each"),
        try word("where"),
        try word("wrap"),
        try word("at-path"),
        try word("dict.from-pairs"),
    });
}

fn filter(evaluator: *Machine) MachineError!void {
    return selectEntries(evaluator, false);
}

fn reject(evaluator: *Machine) MachineError!void {
    return selectEntries(evaluator, true);
}

fn selectKeys(evaluator: *Machine, reject_matches: bool) MachineError!void {
    try evaluator.require(2);
    var keys = try evaluator.popValue();
    defer keys.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    var predicate = try quotation(evaluator, if (reject_matches) &.{
        try word("pop"),
        keys.borrow(),
        try word("in?"),
        try word("not"),
    } else &.{
        try word("pop"),
        keys.borrow(),
        try word("in?"),
    });
    defer predicate.deinit();
    return call(evaluator, &.{ dictionary.borrow(), predicate.borrow(), try word("dict.filter") });
}

fn take(evaluator: *Machine) MachineError!void {
    return selectKeys(evaluator, false);
}

fn drop(evaluator: *Machine) MachineError!void {
    return selectKeys(evaluator, true);
}

fn split(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var keys = try evaluator.popValue();
    defer keys.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    return call(evaluator, &.{
        dictionary.borrow(),
        keys.borrow(),
        try word("dict.take"),
        dictionary.borrow(),
        keys.borrow(),
        try word("dict.drop"),
    });
}

fn mergeWith(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var conflict = try evaluator.popQuotation();
    defer conflict.deinit();
    var right = try evaluator.popDict();
    defer right.deinit();
    var left = try evaluator.popDict();
    defer left.deinit();
    const left_count: usize = @intCast(left.borrow().dict.length());
    const right_count: usize = @intCast(right.borrow().dict.length());
    const pairs_buffer = try evaluator.allocator().alloc(dict_storage.Pair, left_count + right_count);
    var pairs_locally_owned = true;
    errdefer if (pairs_locally_owned) evaluator.allocator().free(pairs_buffer);
    var collision_values = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), right_count);
    defer collision_values.deinit();
    const state = try evaluator.allocator().create(MergeWithState);
    state.* = .{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .quotation = .init(conflict.take().list),
        .pairs = .init(pairs_buffer),
        .collision_values = .init(collision_values.take()),
        .pair_count = left_count,
        .site = evaluator.applicationSite(),
        .word = evaluator.activeWordId(),
    };
    pairs_locally_owned = false;
    try evaluator.startDriver(MergeWithWorkDriver{ .state = .init(state) });
}

const MergeWithPhase = enum { copy_left, merge_right, materialize };

const MergeWithState = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    left: heap.Owned(Value),
    right: heap.Owned(Value),
    quotation: heap.Owned(*value.ListHandle),
    pairs: heap.Owned([]dict_storage.Pair),
    collision_values: heap.Owned(heap.OwnedValueBuffer),
    work: heap.Owned(MergeWithWork) = .init(.between),
    pair_count: usize,
    index: usize = 0,
    collision_index: ?usize = null,
    phase: MergeWithPhase = .copy_left,
    site: machine.ApplicationSite,
    word: intern.TraceWord,
};

const MergeWithWork = union(enum) {
    pub const owned_disposal: heap.OwnedDisposal = .retire;
    finding: dict_storage.FindCursor,
    materializing: dict_storage.Materializer,
    between,

    pub fn retire(self: *MergeWithWork, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .finding => |*cursor| cursor.deinit(),
            .materializing => |*materializer| materializer.retire(releases),
            .between => {},
        }
        self.* = .between;
    }
};

const MergeWithApplication = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(*MergeWithState),

    fn application(self: *MergeWithApplication) machine.IsolatedApplication {
        const state = self.state.borrow();
        return machine.typedApplication(self, state.quotation.borrow(), state.site, 3);
    }

    pub fn resumeApplication(
        evaluator: *Machine,
        self: *MergeWithApplication,
        window: machine.StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?machine.ApplicationStep {
        evaluator.setActiveWord(self.state.borrow().word);
        try evaluator.yieldNativeStep();
        const observed = window.observed(evaluator.unit.stack.items.len) orelse 0;
        if (observed != 1)
            return evaluator.fail(.contract, "dict.merge-with quotation must return one value");
        var result = try evaluator.popValue();
        const state = self.state.borrow();
        state.collision_values.borrowMut().appendOwned(result.take());
        const values = state.collision_values.borrow().values();
        state.pairs.borrow()[state.collision_index.?][1] = values[values.len - 1];
        state.collision_index = null;
        state.index += 1;
        try evaluator.startDriver(MergeWithWorkDriver{ .state = .init(self.state.take()) });
        return null;
    }
};

const MergeWithWorkDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(*MergeWithState),

    pub fn advance(evaluator: *Machine, self: *MergeWithWorkDriver) MachineError!machine.WorkProgress {
        evaluator.setActiveWord(self.state.borrow().word);
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        const state = self.state.borrow();
        while (budget != 0) switch (state.phase) {
            .copy_left => {
                const count: usize = @intCast(state.left.borrow().dict.length());
                if (state.index == count) {
                    state.phase = .merge_right;
                    state.index = 0;
                    continue;
                }
                state.pairs.borrow()[state.index] = .{
                    dict_storage.keyAt(state.left.borrow().dict, state.index),
                    dict_storage.valueAt(state.left.borrow().dict, state.index),
                };
                state.index += 1;
                budget -= 1;
            },
            .merge_right => {
                const count: usize = @intCast(state.right.borrow().dict.length());
                if (state.index == count) {
                    state.work.borrowMut().* = .{ .materializing = try .init(
                        evaluator.allocator(),
                        state.pairs.borrow()[0..state.pair_count],
                        false,
                    ) };
                    state.phase = .materialize;
                    continue;
                }
                const key = dict_storage.keyAt(state.right.borrow().dict, state.index);
                if (state.work.borrowMut().* != .finding) state.work.borrowMut().* = .{
                    .finding = dict_storage.FindCursor.initHeader(
                        evaluator.allocator(),
                        state.left.borrow().dict,
                        key,
                    ),
                };
                switch (try state.work.borrowMut().finding.advance(1)) {
                    .pending => budget -= 1,
                    .complete => {
                        const found = state.work.borrowMut().finding.foundIndex();
                        state.work.borrowMut().retire(evaluator.releaseDomain());
                        const right_value = dict_storage.valueAt(state.right.borrow().dict, state.index);
                        if (found) |destination| {
                            state.collision_index = destination;
                            var stack = try evaluator.reserveStack(3);
                            stack.pushBorrowed(key);
                            stack.pushBorrowed(state.pairs.borrow()[destination][1]);
                            stack.pushBorrowed(right_value);
                            const application_state = try evaluator.allocator().create(MergeWithApplication);
                            application_state.* = .{ .state = .init(self.state.take()) };
                            try evaluator.beginIsolatedApplication(application_state.application());
                            return .completed;
                        }
                        state.pairs.borrow()[state.pair_count] = .{ key, right_value };
                        state.pair_count += 1;
                        state.index += 1;
                    },
                }
            },
            .materialize => return switch (try state.work.borrowMut().materializing.advance(budget)) {
                .pending => .yielded,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    state.work.borrowMut().retire(evaluator.releaseDomain());
                    break :completed .{ .output = result };
                },
            },
        };
        return .yielded;
    }
};
