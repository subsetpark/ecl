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

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try support.installPrimitive(core, "keys", keysPrimitive);
    try support.installPrimitive(core, "vals", valsPrimitive);
    try support.installPrimitive(core, "put", putPrimitive);
    try support.installPrimitive(core, "to-dict", toDictPrimitive);
    try support.installPrimitive(core, "del", delPrimitive);
    try support.installPrimitive(core, "merge", mergePrimitive);
    try support.installPrimitive(core, "has?", hasPrimitive);
    try support.installPrimitive(core, "split", splitPrimitive);
    try support.installPrimitive(core, "join", joinPrimitive);
    try support.installPrimitive(core, "format", formatPrimitive);
}

fn keysPrimitive(evaluator: *Machine) MachineError!void {
    const dictionary = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), dictionary);
    if (dictionary != .dict) return evaluator.typeError("a dict");
    const keys = dict.keysOf(dictionary) catch return evaluator.typeError("a dict");
    try evaluator.pushBorrowed(keys);
}

fn valsPrimitive(evaluator: *Machine) MachineError!void {
    const dictionary = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), dictionary);
    if (dictionary != .dict) return evaluator.typeError("a dict");
    const values = dict.valsOf(dictionary) catch return evaluator.typeError("a dict");
    try evaluator.pushBorrowed(values);
}

fn hasPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const key = try evaluator.popOwned();
    var key_owned = true;
    defer if (key_owned) heap.releaseValue(evaluator.allocator(), key);
    const dictionary = try evaluator.popOwned();
    var dictionary_owned = true;
    defer if (dictionary_owned) heap.releaseValue(evaluator.allocator(), dictionary);
    if (dictionary != .dict) return evaluator.typeError("a dict");
    const driver = try evaluator.allocator().create(HasDriver);
    driver.* = .{
        .dictionary = dictionary,
        .key = key,
        .cursor = storage.DictFindCursor.initHeader(evaluator.allocator(), dictionary.dict, key),
    };
    key_owned = false;
    dictionary_owned = false;
    evaluator.installWorkDriver(driver, HasDriver.advance, HasDriver.destroy);
}

const HasDriver = struct {
    dictionary: Value,
    key: Value,
    cursor: storage.DictFindCursor,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *HasDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        return switch (try self.cursor.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |found| completed: {
                try evaluator.pushOwned(.{ .int = @intFromBool(found != null) });
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *HasDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        heap.releaseValue(allocator, self.dictionary);
        heap.releaseValue(allocator, self.key);
        allocator.destroy(self);
    }
};

fn putPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    const new_value = try evaluator.popOwned();
    var value_owned = true;
    defer if (value_owned) heap.releaseValue(evaluator.allocator(), new_value);
    const key = try evaluator.popOwned();
    var key_owned = true;
    defer if (key_owned) heap.releaseValue(evaluator.allocator(), key);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    switch (collection) {
        .dict => {
            const driver = try evaluator.allocator().create(DictPutDriver);
            driver.* = .{
                .dictionary = collection,
                .key = key,
                .new_value = new_value,
                .finder = storage.DictFindCursor.initHeader(
                    evaluator.allocator(),
                    collection.dict,
                    key,
                ),
            };
            evaluator.installWorkDriver(driver, DictPutDriver.advance, DictPutDriver.destroy);
        },
        .list => {
            if (key != .int) return evaluator.typeError("an integer list index");
            if (key.int < 0) return evaluator.fail(.domain, "put index is negative");
            const index = std.math.cast(usize, key.int) orelse
                return evaluator.fail(.domain, "put index is out of bounds");
            const count: usize = @intCast(collection.list.length());
            if (index >= count) return evaluator.fail(.domain, "put index is out of bounds");
            const values = try evaluator.allocator().alloc(Value, count);
            errdefer evaluator.allocator().free(values);
            const driver = try evaluator.allocator().create(ListPutDriver);
            driver.* = .{
                .collection = collection,
                .key = key,
                .new_value = new_value,
                .replace_index = index,
                .values = values,
            };
            evaluator.installWorkDriver(driver, ListPutDriver.advance, ListPutDriver.destroy);
        },
        .int, .float, .char, .symbol, .word, .task => return evaluator.typeError("a list or dict"),
    }
    collection_owned = false;
    key_owned = false;
    value_owned = false;
}

const ListPutDriver = struct {
    collection: Value,
    key: Value,
    new_value: Value,
    replace_index: usize,
    values: []Value,
    index: usize = 0,
    materializer: ?storage.ValueMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ListPutDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.materializer == null) {
            const end = @min(self.index + budget, self.values.len);
            const copied = end - self.index;
            while (self.index != end) : (self.index += 1) self.values[self.index] =
                if (self.index == self.replace_index)
                    self.new_value
                else
                    list.atUnchecked(self.collection, self.index);
            budget -= copied;
            if (self.index != self.values.len) return .yielded;
            self.materializer = .init(evaluator.allocator(), self.values);
        }
        if (budget == 0) return .yielded;
        return switch (try self.materializer.?.advance(budget)) {
            .pending => .yielded,
            .complete => |result| completed: {
                self.materializer.?.deinit();
                self.materializer = null;
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ListPutDriver = @ptrCast(@alignCast(raw));
        if (self.materializer) |*materializer| materializer.deinit();
        allocator.free(self.values);
        heap.releaseValue(allocator, self.collection);
        heap.releaseValue(allocator, self.key);
        heap.releaseValue(allocator, self.new_value);
        allocator.destroy(self);
    }
};

const DictPutDriver = struct {
    dictionary: Value,
    key: Value,
    new_value: Value,
    finder: ?storage.DictFindCursor,
    found_index: ?usize = null,
    pairs: ?[]dict.Pair = null,
    index: usize = 0,
    materializer: ?storage.DictMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *DictPutDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.finder) |*finder| switch (try finder.advance(budget)) {
            .pending => return .yielded,
            .complete => {
                self.found_index = finder.foundIndex();
                finder.deinit();
                self.finder = null;
                const old_count: usize = @intCast(self.dictionary.dict.length());
                self.pairs = try evaluator.allocator().alloc(
                    dict.Pair,
                    old_count + @intFromBool(self.found_index == null),
                );
                return .yielded;
            },
        };
        if (self.materializer == null) {
            const old_count: usize = @intCast(self.dictionary.dict.length());
            const end = @min(self.index + budget, self.pairs.?.len);
            const copied = end - self.index;
            while (self.index != end) : (self.index += 1) {
                if (self.index == old_count) {
                    self.pairs.?[self.index] = .{ self.key, self.new_value };
                } else {
                    self.pairs.?[self.index] = .{
                        dict.keyAt(self.dictionary.dict, self.index),
                        if (self.found_index == self.index)
                            self.new_value
                        else
                            dict.valueAt(self.dictionary.dict, self.index),
                    };
                }
            }
            budget -= copied;
            if (self.index != self.pairs.?.len) return .yielded;
            self.materializer = try .init(evaluator.allocator(), self.pairs.?, false);
        }
        if (budget == 0) return .yielded;
        return switch (try self.materializer.?.advance(budget)) {
            .pending => .yielded,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.materializer.?.deinit();
                self.materializer = null;
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *DictPutDriver = @ptrCast(@alignCast(raw));
        if (self.finder) |*finder| finder.deinit();
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.pairs) |pairs| allocator.free(pairs);
        heap.releaseValue(allocator, self.dictionary);
        heap.releaseValue(allocator, self.key);
        heap.releaseValue(allocator, self.new_value);
        allocator.destroy(self);
    }
};

fn toDictPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const values = try evaluator.popOwned();
    var values_owned = true;
    defer if (values_owned) heap.releaseValue(evaluator.allocator(), values);
    const keys = try evaluator.popOwned();
    var keys_owned = true;
    defer if (keys_owned) heap.releaseValue(evaluator.allocator(), keys);
    if (keys != .list or values != .list) return evaluator.typeError("two lists");
    const count: usize = @intCast(keys.list.length());
    if (values.list.length() != keys.list.length()) {
        return evaluator.fail(.shape, "to-dict requires equal key and value lengths");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count);
    errdefer evaluator.allocator().free(pairs);
    const driver = try evaluator.allocator().create(ToDictDriver);
    driver.* = .{ .keys = keys, .values = values, .pairs = pairs };
    keys_owned = false;
    values_owned = false;
    evaluator.installWorkDriver(driver, ToDictDriver.advance, ToDictDriver.destroy);
}

const ToDictDriver = struct {
    keys: Value,
    values: Value,
    pairs: []dict.Pair,
    index: usize = 0,
    materializer: ?storage.DictMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ToDictDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.materializer == null) {
            const end = @min(self.index + budget, self.pairs.len);
            const copied = end - self.index;
            while (self.index != end) : (self.index += 1) self.pairs[self.index] = .{
                list.atUnchecked(self.keys, self.index),
                list.atUnchecked(self.values, self.index),
            };
            budget -= copied;
            if (self.index != self.pairs.len or budget == 0) return .yielded;
            self.materializer = try .init(evaluator.allocator(), self.pairs, true);
        }
        return switch (try self.materializer.?.advance(budget)) {
            .pending => .yielded,
            .duplicate_key => evaluator.fail(.domain, "to-dict keys must be distinct"),
            .complete => |result| completed: {
                self.materializer.?.deinit();
                self.materializer = null;
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ToDictDriver = @ptrCast(@alignCast(raw));
        if (self.materializer) |*materializer| materializer.deinit();
        allocator.free(self.pairs);
        heap.releaseValue(allocator, self.keys);
        heap.releaseValue(allocator, self.values);
        allocator.destroy(self);
    }
};

fn delPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const key = try evaluator.popOwned();
    var key_owned = true;
    defer if (key_owned) heap.releaseValue(evaluator.allocator(), key);
    const dictionary = try evaluator.popOwned();
    var dictionary_owned = true;
    defer if (dictionary_owned) heap.releaseValue(evaluator.allocator(), dictionary);
    if (dictionary != .dict) return evaluator.typeError("a dict");
    const driver = try evaluator.allocator().create(DelDriver);
    driver.* = .{
        .dictionary = dictionary,
        .key = key,
        .finder = storage.DictFindCursor.initHeader(evaluator.allocator(), dictionary.dict, key),
    };
    dictionary_owned = false;
    key_owned = false;
    evaluator.installWorkDriver(driver, DelDriver.advance, DelDriver.destroy);
}

const DelDriver = struct {
    dictionary: Value,
    key: Value,
    finder: ?storage.DictFindCursor,
    removed_index: ?usize = null,
    pairs: ?[]dict.Pair = null,
    source_index: usize = 0,
    destination_index: usize = 0,
    materializer: ?storage.DictMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *DelDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        if (self.finder) |*finder| switch (try finder.advance(budget)) {
            .pending => return .yielded,
            .complete => {
                self.removed_index = finder.foundIndex();
                finder.deinit();
                self.finder = null;
                if (self.removed_index == null) {
                    heap.retainValue(self.dictionary);
                    try evaluator.pushOwned(self.dictionary);
                    return .completed;
                }
                const count: usize = @intCast(self.dictionary.dict.length());
                self.pairs = try evaluator.allocator().alloc(dict.Pair, count - 1);
                return .yielded;
            },
        };
        if (self.materializer == null) {
            const count: usize = @intCast(self.dictionary.dict.length());
            while (budget != 0 and self.source_index != count) : (self.source_index += 1) {
                if (self.source_index != self.removed_index.?) {
                    self.pairs.?[self.destination_index] = .{
                        dict.keyAt(self.dictionary.dict, self.source_index),
                        dict.valueAt(self.dictionary.dict, self.source_index),
                    };
                    self.destination_index += 1;
                }
                budget -= 1;
            }
            if (self.source_index != count or budget == 0) return .yielded;
            self.materializer = try .init(evaluator.allocator(), self.pairs.?, false);
        }
        return switch (try self.materializer.?.advance(budget)) {
            .pending => .yielded,
            .duplicate_key => unreachable,
            .complete => |result| completed: {
                self.materializer.?.deinit();
                self.materializer = null;
                errdefer heap.releaseValue(evaluator.allocator(), result);
                try evaluator.pushOwned(result);
                break :completed .completed;
            },
        };
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *DelDriver = @ptrCast(@alignCast(raw));
        if (self.finder) |*finder| finder.deinit();
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.pairs) |pairs| allocator.free(pairs);
        heap.releaseValue(allocator, self.dictionary);
        heap.releaseValue(allocator, self.key);
        allocator.destroy(self);
    }
};

fn mergePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    var right_owned = true;
    defer if (right_owned) heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);
    if (left != .dict or right != .dict) return evaluator.typeError("two dicts");
    const left_count: usize = @intCast(left.dict.length());
    const right_count: usize = @intCast(right.dict.length());
    const pairs = try evaluator.allocator().alloc(dict.Pair, left_count + right_count);
    errdefer evaluator.allocator().free(pairs);
    const driver = try evaluator.allocator().create(MergeDriver);
    driver.* = .{ .left = left, .right = right, .pairs = pairs, .pair_count = left_count };
    left_owned = false;
    right_owned = false;
    evaluator.installWorkDriver(driver, MergeDriver.advance, MergeDriver.destroy);
}

const MergeDriver = struct {
    left: Value,
    right: Value,
    pairs: []dict.Pair,
    pair_count: usize,
    phase: enum { copy_left, merge_right, materialize } = .copy_left,
    index: usize = 0,
    finder: ?storage.DictFindCursor = null,
    materializer: ?storage.DictMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *MergeDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .copy_left => {
                const count: usize = @intCast(self.left.dict.length());
                if (self.index == count) {
                    self.phase = .merge_right;
                    self.index = 0;
                    continue;
                }
                self.pairs[self.index] = .{
                    dict.keyAt(self.left.dict, self.index),
                    dict.valueAt(self.left.dict, self.index),
                };
                self.index += 1;
                budget -= 1;
            },
            .merge_right => {
                const count: usize = @intCast(self.right.dict.length());
                if (self.index == count) {
                    self.materializer = try .init(
                        evaluator.allocator(),
                        self.pairs[0..self.pair_count],
                        false,
                    );
                    self.phase = .materialize;
                    continue;
                }
                const key = dict.keyAt(self.right.dict, self.index);
                if (self.finder == null) self.finder = storage.DictFindCursor.initHeader(
                    evaluator.allocator(),
                    self.left.dict,
                    key,
                );
                switch (try self.finder.?.advance(1)) {
                    .pending => budget -= 1,
                    .complete => {
                        const found = self.finder.?.foundIndex();
                        self.finder.?.deinit();
                        self.finder = null;
                        const pair = dict.Pair{ key, dict.valueAt(self.right.dict, self.index) };
                        if (found) |destination| {
                            self.pairs[destination][1] = pair[1];
                        } else {
                            self.pairs[self.pair_count] = pair;
                            self.pair_count += 1;
                        }
                        self.index += 1;
                        budget -= 1;
                    },
                }
            },
            .materialize => return switch (try self.materializer.?.advance(budget)) {
                .pending => .yielded,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    self.materializer.?.deinit();
                    self.materializer = null;
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    break :completed .completed;
                },
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *MergeDriver = @ptrCast(@alignCast(raw));
        if (self.finder) |*finder| finder.deinit();
        if (self.materializer) |*materializer| materializer.deinit();
        allocator.free(self.pairs);
        heap.releaseValue(allocator, self.left);
        heap.releaseValue(allocator, self.right);
        allocator.destroy(self);
    }
};

fn splitPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const separator = try evaluator.popOwned();
    var separator_owned = true;
    defer if (separator_owned) heap.releaseValue(evaluator.allocator(), separator);
    const text = try evaluator.popOwned();
    var text_owned = true;
    defer if (text_owned) heap.releaseValue(evaluator.allocator(), text);
    if (!text.isString() or !separator.isString()) return evaluator.typeError("two strings");
    const text_len: usize = @intCast(text.list.length());
    const separator_len: usize = @intCast(separator.list.length());
    const capacity = if (separator_len == 0)
        std.math.add(usize, text_len, 2) catch
            return evaluator.fail(.overflow, "split result is too large")
    else
        text_len + 1;
    const parts = try evaluator.allocator().alloc(Value, capacity);
    errdefer evaluator.allocator().free(parts);
    const driver = try evaluator.allocator().create(SplitDriver);
    driver.* = .{ .text = text, .separator = separator, .parts = parts };
    text_owned = false;
    separator_owned = false;
    evaluator.installWorkDriver(driver, SplitDriver.advance, SplitDriver.destroy);
}

const SplitDriver = struct {
    text: Value,
    separator: Value,
    parts: []Value,
    phase: enum { scan, fill_part, materialize_part, materialize_result, release } = .scan,
    cursor: usize = 0,
    start: usize = 0,
    match_index: usize = 0,
    empty_part_index: usize = 0,
    scan_complete: bool = false,
    part_start: usize = 0,
    part_end: usize = 0,
    codepoints: ?[]u32 = null,
    codepoint_index: usize = 0,
    part_count: usize = 0,
    released_parts: usize = 0,
    part_materializer: ?storage.CodepointMaterializer = null,
    result_materializer: ?storage.ValueMaterializer = null,
    result: ?Value = null,

    fn beginPart(self: *SplitDriver, start: usize, end: usize) void {
        self.part_start = start;
        self.part_end = end;
        self.codepoint_index = 0;
        self.phase = .fill_part;
    }

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *SplitDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .scan => {
                const text_len: usize = @intCast(self.text.list.length());
                const separator_len: usize = @intCast(self.separator.list.length());
                if (self.scan_complete) {
                    self.result_materializer = .init(
                        evaluator.allocator(),
                        self.parts[0..self.part_count],
                    );
                    self.phase = .materialize_result;
                    continue;
                }
                if (separator_len == 0) {
                    if (self.empty_part_index == text_len + 2) {
                        self.scan_complete = true;
                        continue;
                    }
                    const part_index = self.empty_part_index;
                    self.empty_part_index += 1;
                    if (part_index == 0 or part_index == text_len + 1) {
                        self.beginPart(0, 0);
                    } else self.beginPart(part_index - 1, part_index);
                    continue;
                }
                if (self.cursor > text_len - @min(text_len, separator_len) or
                    separator_len > text_len - self.cursor)
                {
                    self.scan_complete = true;
                    self.beginPart(self.start, text_len);
                    continue;
                }
                if (list.atUnchecked(self.text, self.cursor + self.match_index).char ==
                    list.atUnchecked(self.separator, self.match_index).char)
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
            .fill_part => {
                if (self.codepoints == null) self.codepoints = try evaluator.allocator().alloc(
                    u32,
                    self.part_end - self.part_start,
                );
                const end = @min(self.codepoint_index + budget, self.codepoints.?.len);
                const copied = end - self.codepoint_index;
                while (self.codepoint_index != end) : (self.codepoint_index += 1) {
                    self.codepoints.?[self.codepoint_index] = list.atUnchecked(
                        self.text,
                        self.part_start + self.codepoint_index,
                    ).char;
                }
                budget -= copied;
                if (self.codepoint_index != self.codepoints.?.len or budget == 0) return .yielded;
                self.part_materializer = .init(evaluator.allocator(), self.codepoints.?);
                self.phase = .materialize_part;
            },
            .materialize_part => switch (try self.part_materializer.?.advance(budget)) {
                .pending => return .yielded,
                .complete => |part| {
                    self.part_materializer.?.deinit();
                    self.part_materializer = null;
                    evaluator.allocator().free(self.codepoints.?);
                    self.codepoints = null;
                    self.parts[self.part_count] = part;
                    self.part_count += 1;
                    self.phase = .scan;
                    return .yielded;
                },
            },
            .materialize_result => switch (try self.result_materializer.?.advance(budget)) {
                .pending => return .yielded,
                .complete => |result| {
                    self.result_materializer.?.deinit();
                    self.result_materializer = null;
                    self.result = result;
                    self.phase = .release;
                },
            },
            .release => {
                if (self.released_parts == self.part_count) {
                    const result = self.result.?;
                    self.result = null;
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    return .completed;
                }
                heap.releaseValue(evaluator.allocator(), self.parts[self.released_parts]);
                self.released_parts += 1;
                budget -= 1;
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *SplitDriver = @ptrCast(@alignCast(raw));
        if (self.part_materializer) |*materializer| materializer.deinit();
        if (self.result_materializer) |*materializer| materializer.deinit();
        if (self.codepoints) |codepoints| allocator.free(codepoints);
        if (self.result) |result| heap.releaseValue(allocator, result);
        for (self.parts[self.released_parts..self.part_count]) |part| heap.releaseValue(allocator, part);
        allocator.free(self.parts);
        heap.releaseValue(allocator, self.text);
        heap.releaseValue(allocator, self.separator);
        allocator.destroy(self);
    }
};

fn joinPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const separator = try evaluator.popOwned();
    var separator_owned = true;
    defer if (separator_owned) heap.releaseValue(evaluator.allocator(), separator);
    const parts = try evaluator.popOwned();
    var parts_owned = true;
    defer if (parts_owned) heap.releaseValue(evaluator.allocator(), parts);
    if (parts != .list or !separator.isString()) {
        return evaluator.typeError("a list of strings and a string separator");
    }
    const driver = try evaluator.allocator().create(JoinDriver);
    driver.* = .{ .parts = parts, .separator = separator };
    parts_owned = false;
    separator_owned = false;
    evaluator.installWorkDriver(driver, JoinDriver.advance, JoinDriver.destroy);
}

const JoinDriver = struct {
    parts: Value,
    separator: Value,
    phase: enum { count, fill, materialize } = .count,
    part_index: usize = 0,
    total: usize = 0,
    codepoints: ?[]u32 = null,
    output_index: usize = 0,
    source_index: usize = 0,
    separator_mode: bool = false,
    materializer: ?storage.CodepointMaterializer = null,

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *JoinDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .count => {
                const count: usize = @intCast(self.parts.list.length());
                if (self.part_index == count) {
                    self.codepoints = try evaluator.allocator().alloc(u32, self.total);
                    self.part_index = 0;
                    self.phase = .fill;
                    continue;
                }
                const part = list.atUnchecked(self.parts, self.part_index);
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
                    @intCast(self.separator.list.length()),
                ) catch return evaluator.fail(.overflow, "joined string is too large");
                self.part_index += 1;
                budget -= 1;
            },
            .fill => {
                const count: usize = @intCast(self.parts.list.length());
                if (self.part_index == count) {
                    std.debug.assert(self.output_index == self.codepoints.?.len);
                    self.materializer = .init(evaluator.allocator(), self.codepoints.?);
                    self.phase = .materialize;
                    continue;
                }
                const source = if (self.separator_mode)
                    self.separator
                else
                    list.atUnchecked(self.parts, self.part_index);
                const source_count: usize = @intCast(source.list.length());
                if (self.source_index == source_count) {
                    self.source_index = 0;
                    if (self.separator_mode or self.part_index + 1 == count) {
                        self.separator_mode = false;
                        self.part_index += 1;
                    } else self.separator_mode = true;
                    budget -= 1;
                    continue;
                }
                self.codepoints.?[self.output_index] = list.atUnchecked(source, self.source_index).char;
                self.output_index += 1;
                self.source_index += 1;
                budget -= 1;
            },
            .materialize => return switch (try self.materializer.?.advance(budget)) {
                .pending => .yielded,
                .complete => |result| completed: {
                    self.materializer.?.deinit();
                    self.materializer = null;
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    break :completed .completed;
                },
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *JoinDriver = @ptrCast(@alignCast(raw));
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.codepoints) |codepoints| allocator.free(codepoints);
        heap.releaseValue(allocator, self.parts);
        heap.releaseValue(allocator, self.separator);
        allocator.destroy(self);
    }
};

fn formatPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const template = try evaluator.popOwned();
    var template_owned = true;
    defer if (template_owned) heap.releaseValue(evaluator.allocator(), template);
    const values = try evaluator.popOwned();
    var values_owned = true;
    defer if (values_owned) heap.releaseValue(evaluator.allocator(), values);
    if (values != .list or !template.isString()) {
        return evaluator.typeError("a value list and a template string");
    }
    const value_count: usize = @intCast(values.list.length());
    const replacements = try evaluator.allocator().alloc(RenderedReplacement, value_count);
    errdefer evaluator.allocator().free(replacements);
    const driver = try evaluator.allocator().create(FormatDriver);
    driver.* = .{ .values = values, .template = template, .replacements = replacements };
    values_owned = false;
    template_owned = false;
    evaluator.installWorkDriver(driver, FormatDriver.advance, FormatDriver.destroy);
}

const RenderedReplacement = struct { bytes: []u8, codepoints: usize = 0 };

const FormatDriver = struct {
    values: Value,
    template: Value,
    replacements: []RenderedReplacement,
    phase: enum { scan, render, count_rendered, fill, materialize } = .scan,
    cursor: usize = 0,
    replacement_index: usize = 0,
    stored_replacements: usize = 0,
    byte_index: usize = 0,
    output_count: usize = 0,
    output: ?[]u32 = null,
    output_index: usize = 0,
    filling_replacement: bool = false,
    renderer: ?printer.OwnedStringCursor = null,
    materializer: ?storage.CodepointMaterializer = null,

    fn templatePair(self: *const FormatDriver) struct { codepoint: u32, next: ?u32 } {
        const count: usize = @intCast(self.template.list.length());
        return .{
            .codepoint = list.atUnchecked(self.template, self.cursor).char,
            .next = if (self.cursor + 1 < count)
                list.atUnchecked(self.template, self.cursor + 1).char
            else
                null,
        };
    }

    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *FormatDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .scan => {
                const count: usize = @intCast(self.template.list.length());
                if (self.cursor == count) {
                    if (self.replacement_index != self.replacements.len) {
                        return evaluator.fail(.contract, "format has more values than placeholders");
                    }
                    self.output = try evaluator.allocator().alloc(u32, self.output_count);
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
                    if (self.replacement_index == self.replacements.len) {
                        return evaluator.fail(.contract, "format has more placeholders than values");
                    }
                    self.renderer = try printer.OwnedStringCursor.init(
                        evaluator.allocator(),
                        list.atUnchecked(self.values, self.replacement_index),
                    );
                    self.cursor += 2;
                    self.phase = .render;
                } else if (pair.codepoint == '{' or pair.codepoint == '}') {
                    return evaluator.fail(.domain, "format contains an unmatched brace");
                } else {
                    try addFormatCount(evaluator, &self.output_count, 1);
                    self.cursor += 1;
                }
                budget -= 1;
            },
            .render => switch (try self.renderer.?.advance(budget)) {
                .pending => return .yielded,
                .complete => |bytes| {
                    self.renderer.?.deinit();
                    self.renderer = null;
                    self.replacements[self.replacement_index] = .{ .bytes = bytes };
                    self.stored_replacements = self.replacement_index + 1;
                    self.byte_index = 0;
                    self.phase = .count_rendered;
                    return .yielded;
                },
            },
            .count_rendered => {
                const replacement = &self.replacements[self.replacement_index];
                if (self.byte_index == replacement.bytes.len) {
                    try addFormatCount(evaluator, &self.output_count, replacement.codepoints);
                    self.replacement_index += 1;
                    self.phase = .scan;
                    continue;
                }
                _ = storage.decodeUtf8Codepoint(replacement.bytes, &self.byte_index) catch
                    return evaluator.fail(.domain, "rendered value is not valid UTF-8");
                replacement.codepoints += 1;
                budget -= 1;
            },
            .fill => {
                if (self.filling_replacement) {
                    const replacement = self.replacements[self.replacement_index];
                    if (self.byte_index == replacement.bytes.len) {
                        self.filling_replacement = false;
                        self.replacement_index += 1;
                        continue;
                    }
                    self.output.?[self.output_index] = storage.decodeUtf8Codepoint(
                        replacement.bytes,
                        &self.byte_index,
                    ) catch return evaluator.fail(.domain, "rendered value is not valid UTF-8");
                    self.output_index += 1;
                    budget -= 1;
                    continue;
                }
                const count: usize = @intCast(self.template.list.length());
                if (self.cursor == count) {
                    std.debug.assert(self.output_index == self.output.?.len);
                    self.materializer = .init(evaluator.allocator(), self.output.?);
                    self.phase = .materialize;
                    continue;
                }
                const pair = self.templatePair();
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    self.output.?[self.output_index] = pair.codepoint;
                    self.output_index += 1;
                    self.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    self.filling_replacement = true;
                    self.byte_index = 0;
                    self.cursor += 2;
                } else {
                    self.output.?[self.output_index] = pair.codepoint;
                    self.output_index += 1;
                    self.cursor += 1;
                }
                budget -= 1;
            },
            .materialize => return switch (try self.materializer.?.advance(budget)) {
                .pending => .yielded,
                .complete => |result| completed: {
                    self.materializer.?.deinit();
                    self.materializer = null;
                    errdefer heap.releaseValue(evaluator.allocator(), result);
                    try evaluator.pushOwned(result);
                    break :completed .completed;
                },
            },
        };
        return .yielded;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *FormatDriver = @ptrCast(@alignCast(raw));
        if (self.renderer) |*renderer| renderer.deinit();
        if (self.materializer) |*materializer| materializer.deinit();
        for (self.replacements[0..self.stored_replacements]) |replacement|
            allocator.free(replacement.bytes);
        allocator.free(self.replacements);
        if (self.output) |output| allocator.free(output);
        heap.releaseValue(allocator, self.values);
        heap.releaseValue(allocator, self.template);
        allocator.destroy(self);
    }
};

fn addFormatCount(
    evaluator: *Machine,
    count: *usize,
    amount: usize,
) MachineError!void {
    count.* = std.math.add(usize, count.*, amount) catch
        return evaluator.fail(.overflow, "formatted string is too large");
}
