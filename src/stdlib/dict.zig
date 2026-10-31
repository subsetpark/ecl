//! The host kernels behind the `dict` module, published as `dict.core`.
//!
//! Representation observers and user-sized rebuilds reuse the host kernels;
//! quotation-dependent `update` reuses the core combinator backend. The
//! derived words (`pairs`, `from-pairs`, `map`, ...) are ECL definitions in
//! `dict.ecl`, which forwards every word here under its public name.
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
const Unit = machine.Unit;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "at-or",
        .effect = "dict keys default -- values",
        .doc = "Like `dict.at`, using `default` as a whole value for each missing key.",
        .primitive = valuesAtOr,
    },
    .{
        .name = "size",
        .effect = "dict -- count",
        .doc = "Return the dictionary's entry count.",
        .primitive = dict_kernels.sizeForModule,
    },
    .{
        .name = "keys",
        .effect = "dict -- keys",
        .doc = "Return keys in insertion order.",
        .primitive = dict_kernels.keysForModule,
    },
    .{
        .name = "vals",
        .effect = "dict -- values",
        .doc = "Return values in insertion order.",
        .primitive = dict_kernels.valsForModule,
    },
    .{
        .name = "get",
        .effect = "dict key default -- value",
        .doc = "The value of one whole-value key, or `default` when the dictionary has no such key. A non-dictionary is `` `type ``.",
        .primitive = get,
    },
    .{
        .name = "has?",
        .effect = "dict key -- bool",
        .doc = "Whole-value key membership. Keys are inert and only absence is false: lookup machinery failures are errors, never converted to 0.",
        .primitive = dict_kernels.hasForModule,
    },
    .{
        .name = "at",
        .effect = "dict keys -- values",
        .doc = "Look up each top-level key in request order, preserving duplicates. An absent key is `` `domain ``. Strings and composite keys are whole values; the result has one element per requested key.",
        .primitive = valuesAt,
    },
    .{
        .name = "merge",
        .effect = "left right -- dict",
        .doc = "Merge two dictionaries; right-hand values win. Existing left keys retain their positions and right-only keys append in right order. Key-aligned arithmetic remains pervasive `+` on dicts.",
        .primitive = dict_kernels.mergeForModule,
    },
    .{
        .name = "associate",
        .effect = "value key -- dict",
        .doc = "Build a one-entry dictionary associating `key` with `value`.",
        .primitive = associate,
    },
    .{
        .name = "from-flat",
        .effect = "entries -- dict",
        .doc = "Build a dictionary from one flat, even-length list by pairing adjacent entries without executing them. This is the runtime counterpart of the `{…}` literal: `` `total 3 4 + pair dict.from-flat `` is `{total 7}`. An odd entry count is `` `contract ``; duplicate keys are `` `domain ``.",
        .primitive = fromFlat,
    },
    .{
        .name = "from-lists",
        .effect = "keys values -- dict",
        .doc = "Build a dictionary from parallel conforming key and value lists. Unequal lengths are `` `shape ``; duplicate keys are `` `domain ``.",
        .primitive = dict_kernels.fromListsForModule,
    },
    .{
        .name = "put",
        .effect = "dict key value -- dict",
        .doc = "Assign one whole key and value. An existing key retains its position; a new key appends at the end.",
        .primitive = dict_kernels.putForModule,
    },
    .{
        .name = "update",
        .effect = "dict keys quotation -- dict",
        .doc = "Apply an isolated `( value -- value )` quotation to each whole top-level key without moving entries. Keys are processed in request order, so duplicates observe earlier updates. All keys are validated before the quotation is first applied; an absent key is `` `domain ``, and an empty key list returns the dictionary unchanged.",
        .primitive = combinators.updateDictKeysForModule,
    },
    .{
        .name = "take",
        .effect = "dict keys -- dict",
        .doc = "Keep entries named by a key list, ignoring absent keys. Output follows dictionary order independently of the requested key-list order.",
        .primitive = take,
    },
    .{
        .name = "del",
        .effect = "dict keys -- dict",
        .doc = "Remove entries named by whole top-level keys, ignoring absent and duplicate keys and preserving retained dictionary order.",
        .primitive = del,
    },
    .{
        .name = "merge-with",
        .effect = "left right quotation -- dict",
        .doc = "Merge two dictionaries, resolving each shared key with `( key left-value right-value -- value )`. Existing left keys keep their positions; right-only keys append in right order.",
        .primitive = mergeWith,
    },
};

fn get(evaluator: *Unit) MachineError!void {
    try evaluator.require(3);
    var fallback = try evaluator.popValue();
    defer fallback.deinit();
    var key = try evaluator.popValue();
    defer key.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const cursor = dict_storage.FindCursor.initHeader(evaluator.allocator, dictionary.borrow().dict, key.borrow());
    try evaluator.startDriver(GetDriver{
        .dictionary = .init(dictionary.take()),
        .key = .init(key.take()),
        .fallback = .init(fallback.take()),
        .cursor = .init(cursor),
    });
}

/// One key's value, or the default. Searching a dict is bounded work over its
/// entries, so the driver is earned; its creation is not.
const GetDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    pub const inline_driver = true;
    dictionary: heap.Owned(Value),
    key: heap.Owned(Value),
    fallback: heap.Owned(Value),
    cursor: heap.Owned(dict_storage.FindCursor),

    pub fn advance(evaluator: *Unit, self: *GetDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.cursor.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |found| if (found) |item| present: {
                heap.retainValue(item);
                break :present .{ .output = item };
            } else .{ .output = self.fallback.take() },
        };
    }
};

fn valuesAtOr(evaluator: *Unit) MachineError!void {
    return lookupKeys(evaluator, true);
}

fn valuesAt(evaluator: *Unit) MachineError!void {
    return lookupKeys(evaluator, false);
}

fn lookupKeys(evaluator: *Unit, comptime with_default: bool) MachineError!void {
    try evaluator.require(if (with_default) 3 else 2);
    var fallback: ?heap.OwnedValue = if (with_default) try evaluator.popValue() else null;
    defer if (fallback) |*owned| owned.deinit();
    var keys = try evaluator.popList();
    defer keys.deinit();
    var dictionary = try evaluator.popValue();
    defer dictionary.deinit();
    if (dictionary.borrow() != .dict) return evaluator.typeError("a dictionary");
    try evaluator.startDriver(DictLookupDriver{
        .dictionary = .init(dictionary.take()),
        .keys = .init(keys.take()),
        .fallback = if (fallback) |*owned| .init(owned.take()) else null,
    });
}

const DictLookupDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    dictionary: heap.Owned(Value),
    keys: heap.Owned(Value),
    fallback: ?heap.Owned(Value),
    output: ?heap.Owned(heap.OwnedValueBuffer) = null,
    cursor: ?heap.Owned(dict_storage.FindCursor) = null,
    index: usize = 0,

    pub fn advance(evaluator: *Unit, self: *DictLookupDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.keys.borrow().list.length());
        if (self.output == null) self.output = .init(try .init(evaluator.releases, count));
        const work = evaluator.workBudget();
        while (self.index < count and work.spend()) {
            if (self.cursor == null) self.cursor = .init(dict_storage.FindCursor.initHeader(
                evaluator.allocator,
                self.dictionary.borrow().dict,
                list.atUnchecked(self.keys.borrow(), self.index),
            ));
            switch (try self.cursor.?.borrowMut().advance(work)) {
                .pending => {},
                .complete => |found| {
                    self.output.?.borrowMut().appendBorrowed(found orelse if (self.fallback) |*fallback| fallback.borrow() else return evaluator.fail(.domain, "dict.at could not find the dict key"));
                    self.cursor.?.deinit(evaluator.releases, evaluator.allocator);
                    self.cursor = null;
                    self.index += 1;
                },
            }
        }
        if (self.index != count) return .stepped;
        const result = self.output.?.borrowMut().takeList();
        self.output = null;
        return .{ .output = result };
    }
};

fn associate(evaluator: *Unit) MachineError!void {
    try evaluator.require(2);
    var key = try evaluator.popValue();
    defer key.deinit();
    var associated_value = try evaluator.popValue();
    defer associated_value.deinit();
    const pair = [1]dict_storage.Pair{.{ key.borrow(), associated_value.borrow() }};
    const materializer = try dict_storage.Materializer.init(
        evaluator.allocator,
        &pair,
        false,
    );
    try evaluator.startDriver(AssociateDriver{
        .key = .init(key.take()),
        .associated_value = .init(associated_value.take()),
        .materializer = .init(materializer),
    });
}

const AssociateDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    key: heap.Owned(Value),
    associated_value: heap.Owned(Value),
    materializer: heap.Owned(dict_storage.Materializer),

    pub fn advance(evaluator: *Unit, self: *AssociateDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.materializer.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .duplicate_key => unreachable,
            .complete => |dictionary| .{ .output = dictionary },
        };
    }
};

fn fromFlat(evaluator: *Unit) MachineError!void {
    var entries = try evaluator.popValue();
    defer entries.deinit();
    if (entries.borrow() != .list) return evaluator.typeError("a flat key/value list");
    const count: usize = @intCast(entries.borrow().list.length());
    if (count % 2 != 0) {
        return evaluator.fail(.contract, "dict.from-flat requires an even-length key/value list");
    }
    const flat_pairs = try evaluator.allocator.alloc(dict_storage.Pair, count / 2);
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

    pub fn advance(evaluator: *Unit, self: *FromFlatDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.materializer == null) {
            const flat_pairs = self.pairs.borrow();
            const end = self.index + evaluator.workBudget().take(flat_pairs.len - self.index);
            while (self.index != end) : (self.index += 1) flat_pairs[self.index] = .{
                list.atUnchecked(self.entries.borrow(), self.index * 2),
                list.atUnchecked(self.entries.borrow(), self.index * 2 + 1),
            };
            if (self.index != flat_pairs.len) return .stepped;
            self.materializer = .init(try .init(evaluator.allocator, flat_pairs, true));
            return .stepped;
        }
        return switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .duplicate_key => evaluator.fail(.domain, "dict.from-flat received a duplicate key"),
            .complete => |dictionary| .{ .output = dictionary },
        };
    }
};

fn take(evaluator: *Unit) MachineError!void {
    return selectKeys(evaluator, true);
}

fn del(evaluator: *Unit) MachineError!void {
    return selectKeys(evaluator, false);
}

fn selectKeys(evaluator: *Unit, keep: bool) MachineError!void {
    try evaluator.require(2);
    var selector = try evaluator.popList();
    defer selector.deinit();
    var dictionary = try evaluator.popDict();
    defer dictionary.deinit();
    const count: usize = @intCast(dictionary.borrow().dict.length());
    const selected = try evaluator.allocator.alloc(bool, count);
    try evaluator.startDriver(DictSelectDriver{
        .dictionary = .init(dictionary.take()),
        .selector = .init(selector.take()),
        .selected = .init(selected),
        .keep = keep,
    });
}

const DictSelectDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    const Phase = enum { initialize, find, copy, materialize };

    dictionary: heap.Owned(Value),
    selector: heap.Owned(Value),
    selected: heap.Owned([]bool),
    keep: bool,
    key_index: usize = 0,
    finder: ?heap.Owned(dict_storage.FindCursor) = null,
    pairs: ?heap.Owned([]dict_storage.Pair) = null,
    materializer: ?heap.Owned(dict_storage.Materializer) = null,
    phase: Phase = .initialize,
    index: usize = 0,
    selected_count: usize = 0,
    destination_index: usize = 0,

    pub fn advance(evaluator: *Unit, self: *DictSelectDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .initialize => {
                if (self.index == self.selected.borrow().len) {
                    self.index = 0;
                    self.phase = .find;
                    continue;
                }
                self.selected.borrow()[self.index] = false;
                self.index += 1;
                _ = work.spend();
            },
            .find => {
                if (self.finder == null) {
                    if (self.key_index == self.selector.borrow().list.length()) {
                        const count = if (self.keep) self.selected_count else self.selected.borrow().len - self.selected_count;
                        self.pairs = .init(try evaluator.allocator.alloc(dict_storage.Pair, count));
                        self.phase = .copy;
                        continue;
                    }
                    self.finder = .init(dict_storage.FindCursor.initHeader(
                        evaluator.allocator,
                        self.dictionary.borrow().dict,
                        list.atUnchecked(self.selector.borrow(), self.key_index),
                    ));
                    self.key_index += 1;
                }
                if (work.exhausted()) return .stepped;
                const find_progress = try self.finder.?.borrowMut().advance(work);
                _ = work.spend();
                switch (find_progress) {
                    .pending => {},
                    .complete => {
                        if (self.finder.?.borrow().foundIndex()) |position| {
                            if (!self.selected.borrow()[position]) {
                                self.selected.borrow()[position] = true;
                                self.selected_count += 1;
                            }
                        }
                        self.finder.?.deinit(evaluator.releases, evaluator.allocator);
                        self.finder = null;
                    },
                }
            },
            .copy => {
                if (self.index == self.selected.borrow().len) {
                    self.materializer = .init(try dict_storage.Materializer.initBorrowedPairs(
                        evaluator.allocator,
                        self.pairs.?.borrow(),
                        false,
                    ));
                    self.phase = .materialize;
                    continue;
                }
                if (self.selected.borrow()[self.index] == self.keep) {
                    self.pairs.?.borrow()[self.destination_index] = .{
                        dict_storage.keyAt(self.dictionary.borrow().dict, self.index),
                        dict_storage.valueAt(self.dictionary.borrow().dict, self.index),
                    };
                    self.destination_index += 1;
                }
                self.index += 1;
                _ = work.spend();
            },
            .materialize => return switch (try self.materializer.?.borrowMut().advance(work)) {
                .pending => .stepped,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    self.materializer.?.borrowMut().deinit();
                    self.materializer = null;
                    break :completed .{ .output = result };
                },
            },
        };
        return .stepped;
    }
};

fn mergeWith(evaluator: *Unit) MachineError!void {
    try evaluator.require(3);
    var conflict = try evaluator.popQuotation();
    defer conflict.deinit();
    var right = try evaluator.popDict();
    defer right.deinit();
    var left = try evaluator.popDict();
    defer left.deinit();
    const left_count: usize = @intCast(left.borrow().dict.length());
    const right_count: usize = @intCast(right.borrow().dict.length());
    const pairs_buffer = try evaluator.allocator.alloc(dict_storage.Pair, left_count + right_count);
    var pairs_locally_owned = true;
    errdefer if (pairs_locally_owned) evaluator.allocator.free(pairs_buffer);
    var collision_values = try heap.OwnedValueBuffer.init(evaluator.releases, right_count);
    defer collision_values.deinit();
    const state = try evaluator.allocator.create(MergeWithState);
    state.* = .{
        .left = .init(left.take()),
        .right = .init(right.take()),
        .quotation = .init(conflict.take().list),
        .pairs = .init(pairs_buffer),
        .collision_values = .init(collision_values.take()),
        .pair_count = left_count,
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
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
        evaluator: *Unit,
        self: *MergeWithApplication,
        window: machine.StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?machine.ApplicationStep {
        evaluator.active_word = self.state.borrow().word;
        evaluator.chargeContinuationStep();
        const observed = window.observed(evaluator.stack.items.len) orelse 0;
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

    pub fn advance(evaluator: *Unit, self: *MergeWithWorkDriver) MachineError!machine.WorkProgress {
        evaluator.active_word = self.state.borrow().word;
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        const state = self.state.borrow();
        while (!work.exhausted()) switch (state.phase) {
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
                _ = work.spend();
            },
            .merge_right => {
                const count: usize = @intCast(state.right.borrow().dict.length());
                if (state.index == count) {
                    const materializer: dict_storage.Materializer = try .init(evaluator.allocator, state.pairs.borrow()[0..state.pair_count], false);
                    state.work.borrowMut().* = .{ .materializing = materializer };
                    state.phase = .materialize;
                    continue;
                }
                const key = dict_storage.keyAt(state.right.borrow().dict, state.index);
                if (state.work.borrowMut().* != .finding) state.work.borrowMut().* = .{
                    .finding = dict_storage.FindCursor.initHeader(
                        evaluator.allocator,
                        state.left.borrow().dict,
                        key,
                    ),
                };
                switch (try state.work.borrowMut().finding.advance(work)) {
                    .pending => _ = work.spend(),
                    .complete => {
                        const found = state.work.borrowMut().finding.foundIndex();
                        state.work.borrowMut().retire(evaluator.releases);
                        const right_value = dict_storage.valueAt(state.right.borrow().dict, state.index);
                        if (found) |destination| {
                            state.collision_index = destination;
                            var stack = try evaluator.reserveStack(3);
                            stack.pushBorrowed(key);
                            stack.pushBorrowed(state.pairs.borrow()[destination][1]);
                            stack.pushBorrowed(right_value);
                            const application_state = try evaluator.allocator.create(MergeWithApplication);
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
            .materialize => return switch (try state.work.borrowMut().materializing.advance(work)) {
                .pending => .stepped,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    state.work.borrowMut().retire(evaluator.releases);
                    break :completed .{ .output = result };
                },
            },
        };
        return .stepped;
    }
};
