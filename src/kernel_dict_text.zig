//! Immutable dict operations and Unicode-codepoint text kernels.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;
const Machine = support.Machine;
const MachineError = support.MachineError;

pub fn install(core: *env.Env) error{OutOfMemory}!void {
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
    defer heap.releaseValue(evaluator.allocator(), key);
    const dictionary = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), dictionary);
    if (dictionary != .dict) return evaluator.typeError("a dict");
    const present = storage.contains(
        evaluator.allocator(),
        dictionary,
        key,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.NotADict => unreachable,
    };
    try evaluator.pushOwned(.{ .int = @intFromBool(present) });
}

fn putPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    const new_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), new_value);
    const key = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), key);
    const collection = try evaluator.popOwned();
    var collection_owned = true;
    defer if (collection_owned) heap.releaseValue(evaluator.allocator(), collection);
    const result = switch (collection) {
        .dict => blk: {
            break :blk storage.put(
                evaluator.allocator(),
                collection,
                key,
                new_value,
                (support.Context{ .evaluator = evaluator }).structuralPoller(),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => return error.Ecl,
                error.NotADict => unreachable,
            };
        },
        .list => blk: {
            if (key != .int) return evaluator.typeError("an integer list index");
            if (key.int < 0) return evaluator.fail(.domain, "put index is negative");
            const index = std.math.cast(usize, key.int) orelse
                return evaluator.fail(.domain, "put index is out of bounds");
            const count: usize = @intCast(collection.list.len);
            if (index >= count) return evaluator.fail(.domain, "put index is out of bounds");
            break :blk try replaceListItem(
                evaluator.allocator(),
                collection,
                index,
                new_value,
                .{ .evaluator = evaluator },
            );
        },
        .int, .float, .char, .symbol, .word => return evaluator.typeError("a list or dict"),
    };
    if (result.heapHeader().? == collection.heapHeader().?) collection_owned = false;
    try evaluator.pushOwned(result);
}

fn replaceListItem(
    allocator: std.mem.Allocator,
    collection: Value,
    index: usize,
    new_value: Value,
    context: ?support.Context,
) MachineError!Value {
    const header = collection.list;
    if (heap.isUnique(header) and fitsListRepresentation(header.kind(), new_value)) {
        try pollUpdate(context);
        switch (header.kind()) {
            .generic_spine => unreachable,
            .leaf_i64 => heap.items(i64, header)[index] = new_value.int,
            .leaf_f64 => heap.items(f64, header)[index] = new_value.float,
            .leaf_char1 => heap.items(u8, header)[index] = @intCast(new_value.char),
            .leaf_char2 => heap.items(u16, header)[index] = @intCast(new_value.char),
            .leaf_char4 => heap.items(u32, header)[index] = new_value.char,
            .leaf_symbol => heap.items(u32, header)[index] = new_value.symbol,
            .dict, .reserved_mask => unreachable,
        }
        return collection;
    }

    const count: usize = @intCast(header.len);
    const values = try allocator.alloc(Value, count);
    defer allocator.free(values);
    for (0..count) |position| {
        try pollUpdate(context);
        values[position] = list.atUnchecked(collection, position);
    }
    values[index] = new_value;
    const replacement = if (context) |active|
        try storage.fromValues(allocator, values, active.structuralPoller())
    else
        try list.fromValues(allocator, values);
    if (!heap.isUnique(header)) return replacement;
    heap.adoptRepresentation(allocator, header, replacement.list);
    return collection;
}

fn pollUpdate(context: ?support.Context) MachineError!void {
    if (context) |active| try active.poll();
}

fn fitsListRepresentation(kind: value.HeapKind, item: Value) bool {
    return switch (kind) {
        .generic_spine => false,
        .leaf_i64 => item == .int,
        .leaf_f64 => item == .float,
        .leaf_char1 => item == .char and item.char <= std.math.maxInt(u8),
        .leaf_char2 => item == .char and item.char <= std.math.maxInt(u16),
        .leaf_char4 => item == .char,
        .leaf_symbol => item == .symbol,
        .dict, .reserved_mask => false,
    };
}

fn toDictPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const values = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), values);
    const keys = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), keys);
    if (keys != .list or values != .list) return evaluator.typeError("two lists");
    const count: usize = @intCast(keys.list.len);
    if (values.list.len != keys.list.len) {
        return evaluator.fail(.shape, "to-dict requires equal key and value lengths");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count);
    defer evaluator.allocator().free(pairs);
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        pairs[index] = .{
            list.atUnchecked(keys, index),
            list.atUnchecked(values, index),
        };
    }
    const result = storage.fromPairs(
        evaluator.allocator(),
        pairs,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.DuplicateKey => return evaluator.fail(.domain, "to-dict keys must be distinct"),
    };
    try evaluator.pushOwned(result);
}

fn delPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const key = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), key);
    const dictionary = try evaluator.popOwned();
    var dictionary_owned = true;
    defer if (dictionary_owned) heap.releaseValue(evaluator.allocator(), dictionary);
    if (dictionary != .dict) return evaluator.typeError("a dict");
    const result = storage.del(
        evaluator.allocator(),
        dictionary,
        key,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.NotADict => unreachable,
    };
    if (result.dict == dictionary.dict) dictionary_owned = false;
    try evaluator.pushOwned(result);
}

fn mergePrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    var left_owned = true;
    defer if (left_owned) heap.releaseValue(evaluator.allocator(), left);
    if (left != .dict or right != .dict) return evaluator.typeError("two dicts");
    const result = storage.merge(
        evaluator.allocator(),
        left,
        right,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.NotADict => unreachable,
    };
    if (result.dict == left.dict) left_owned = false;
    try evaluator.pushOwned(result);
}

fn splitPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const separator = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), separator);
    const text = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), text);
    if (!text.isString() or !separator.isString()) return evaluator.typeError("two strings");
    const text_len: usize = @intCast(text.list.len);
    const separator_len: usize = @intCast(separator.list.len);
    const poller = (support.Context{ .evaluator = evaluator }).structuralPoller();
    const part_count = if (separator_len == 0)
        std.math.add(usize, text_len, 2) catch
            return evaluator.fail(.overflow, "split result is too large")
    else
        try countSplitParts(evaluator, text, separator);
    const parts = try evaluator.allocator().alloc(Value, part_count);
    defer evaluator.allocator().free(parts);
    var initialized: usize = 0;
    defer for (parts[0..initialized]) |part| heap.releaseValue(evaluator.allocator(), part);
    if (separator_len == 0) {
        parts[initialized] = try storage.fromCodepoints(evaluator.allocator(), &.{}, poller);
        initialized += 1;
        for (0..text_len) |index| {
            try evaluator.advanceKernel(1);
            const codepoint = list.atUnchecked(text, index).char;
            parts[initialized] = try storage.fromCodepoints(
                evaluator.allocator(),
                &.{codepoint},
                poller,
            );
            initialized += 1;
        }
        parts[initialized] = try storage.fromCodepoints(evaluator.allocator(), &.{}, poller);
        initialized += 1;
    } else {
        var start: usize = 0;
        var cursor: usize = 0;
        while (separator_len <= text_len - cursor) {
            if (!try startsWithAtPolling(evaluator, text, separator, cursor)) {
                cursor += 1;
                continue;
            }
            parts[initialized] = try stringSlice(evaluator, text, start, cursor);
            initialized += 1;
            cursor += separator_len;
            start = cursor;
        }
        parts[initialized] = try stringSlice(evaluator, text, start, text_len);
        initialized += 1;
    }
    std.debug.assert(initialized == parts.len);
    try evaluator.pushOwned(try storage.fromValues(evaluator.allocator(), parts, poller));
}

fn countSplitParts(evaluator: *Machine, text: Value, separator: Value) MachineError!usize {
    const text_len: usize = @intCast(text.list.len);
    const separator_len: usize = @intCast(separator.list.len);
    std.debug.assert(separator_len > 0);
    var count: usize = 1;
    var cursor: usize = 0;
    while (separator_len <= text_len - cursor) {
        if (try startsWithAtPolling(evaluator, text, separator, cursor)) {
            count = std.math.add(usize, count, 1) catch
                return evaluator.fail(.overflow, "split result is too large");
            cursor += separator_len;
        } else {
            cursor += 1;
        }
    }
    return count;
}

fn startsWithAt(text: Value, separator: Value, start: usize) bool {
    const separator_len: usize = @intCast(separator.list.len);
    for (0..separator_len) |index| {
        if (list.atUnchecked(text, start + index).char !=
            list.atUnchecked(separator, index).char) return false;
    }
    return true;
}

fn startsWithAtPolling(
    evaluator: *Machine,
    text: Value,
    separator: Value,
    start: usize,
) MachineError!bool {
    const separator_len: usize = @intCast(separator.list.len);
    for (0..separator_len) |index| {
        try evaluator.advanceKernel(1);
        if (list.atUnchecked(text, start + index).char !=
            list.atUnchecked(separator, index).char) return false;
    }
    return true;
}

fn stringSlice(
    evaluator: *Machine,
    text: Value,
    start: usize,
    end: usize,
) MachineError!Value {
    const codepoints = try evaluator.allocator().alloc(u32, end - start);
    defer evaluator.allocator().free(codepoints);
    for (codepoints, 0..) |*codepoint, index| {
        try evaluator.advanceKernel(1);
        codepoint.* = list.atUnchecked(text, start + index).char;
    }
    return storage.fromCodepoints(
        evaluator.allocator(),
        codepoints,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    );
}

fn joinPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const separator = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), separator);
    const parts = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), parts);
    if (parts != .list or !separator.isString()) {
        return evaluator.typeError("a list of strings and a string separator");
    }
    const count: usize = @intCast(parts.list.len);
    const separator_len: usize = @intCast(separator.list.len);
    var total: usize = 0;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const part = list.atUnchecked(parts, index);
        if (!part.isString()) return evaluator.failAtIndex(.type, "join expected a list of strings", index);
        total = std.math.add(usize, total, @intCast(part.list.len)) catch
            return evaluator.fail(.overflow, "joined string is too large");
        if (index + 1 < count) total = std.math.add(usize, total, separator_len) catch
            return evaluator.fail(.overflow, "joined string is too large");
    }
    const codepoints = try evaluator.allocator().alloc(u32, total);
    defer evaluator.allocator().free(codepoints);
    var cursor: usize = 0;
    for (0..count) |index| {
        const part = list.atUnchecked(parts, index);
        try copyCodepoints(evaluator, codepoints, &cursor, part);
        if (index + 1 < count) try copyCodepoints(evaluator, codepoints, &cursor, separator);
    }
    try evaluator.pushOwned(try storage.fromCodepoints(
        evaluator.allocator(),
        codepoints,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}

fn copyCodepoints(
    evaluator: *Machine,
    output: []u32,
    cursor: *usize,
    text: Value,
) MachineError!void {
    const count: usize = @intCast(text.list.len);
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        output[cursor.*] = list.atUnchecked(text, index).char;
        cursor.* += 1;
    }
}

fn formatPrimitive(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const template = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), template);
    const values = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), values);
    if (values != .list or !template.isString()) {
        return evaluator.typeError("a value list and a template string");
    }
    const template_len: usize = @intCast(template.list.len);
    const value_count: usize = @intCast(values.list.len);
    const Rendered = struct { bytes: []u8, codepoints: usize };
    const replacements = try evaluator.allocator().alloc(Rendered, value_count);
    defer evaluator.allocator().free(replacements);
    var replacement_count: usize = 0;
    defer for (replacements[0..replacement_count]) |replacement| {
        evaluator.allocator().free(replacement.bytes);
    };
    const poller = (support.Context{ .evaluator = evaluator }).structuralPoller();
    var cursor: usize = 0;
    var output_count: usize = 0;
    while (cursor < template_len) {
        try evaluator.advanceKernel(1);
        const codepoint = list.atUnchecked(template, cursor).char;
        const next = if (cursor + 1 < template_len)
            list.atUnchecked(template, cursor + 1).char
        else
            null;
        if (codepoint == '{' and next == '{') {
            try evaluator.advanceKernel(1);
            try addFormatCount(evaluator, &output_count, 1);
            cursor += 2;
        } else if (codepoint == '}' and next == '}') {
            try evaluator.advanceKernel(1);
            try addFormatCount(evaluator, &output_count, 1);
            cursor += 2;
        } else if (codepoint == '{' and next == '}') {
            try evaluator.advanceKernel(1);
            if (replacement_count >= value_count) {
                return evaluator.fail(.contract, "format has more placeholders than values");
            }
            const rendered = try printer.toOwnedStringWithPolling(
                evaluator.allocator(),
                list.atUnchecked(values, replacement_count),
                poller,
            );
            replacements[replacement_count].bytes = rendered;
            replacement_count += 1;
            const replacement = &replacements[replacement_count - 1];
            replacement.codepoints = storage.utf8CodepointCount(rendered, poller) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => return error.Ecl,
                error.InvalidUtf8 => unreachable,
            };
            try addFormatCount(evaluator, &output_count, replacement.codepoints);
            cursor += 2;
        } else if (codepoint == '{' or codepoint == '}') {
            return evaluator.fail(.domain, "format contains an unmatched brace");
        } else {
            try addFormatCount(evaluator, &output_count, 1);
            cursor += 1;
        }
    }
    if (replacement_count != value_count) {
        return evaluator.fail(.contract, "format has more values than placeholders");
    }

    const output = try evaluator.allocator().alloc(u32, output_count);
    defer evaluator.allocator().free(output);
    cursor = 0;
    var output_index: usize = 0;
    var replacement_index: usize = 0;
    while (cursor < template_len) {
        try evaluator.advanceKernel(1);
        const codepoint = list.atUnchecked(template, cursor).char;
        const next = if (cursor + 1 < template_len)
            list.atUnchecked(template, cursor + 1).char
        else
            null;
        if ((codepoint == '{' and next == '{') or (codepoint == '}' and next == '}')) {
            try evaluator.advanceKernel(1);
            output[output_index] = codepoint;
            output_index += 1;
            cursor += 2;
        } else if (codepoint == '{' and next == '}') {
            try evaluator.advanceKernel(1);
            const replacement = replacements[replacement_index];
            const end = output_index + replacement.codepoints;
            storage.decodeUtf8Into(
                replacement.bytes,
                output[output_index..end],
                poller,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => return error.Ecl,
                error.InvalidUtf8 => unreachable,
            };
            output_index = end;
            replacement_index += 1;
            cursor += 2;
        } else {
            std.debug.assert(codepoint != '{' and codepoint != '}');
            output[output_index] = codepoint;
            output_index += 1;
            cursor += 1;
        }
    }
    std.debug.assert(output_index == output.len);
    std.debug.assert(replacement_index == replacements.len);
    try evaluator.pushOwned(try storage.fromCodepoints(
        evaluator.allocator(),
        output,
        poller,
    ));
}

fn addFormatCount(
    evaluator: *Machine,
    count: *usize,
    amount: usize,
) MachineError!void {
    count.* = std.math.add(usize, count.*, amount) catch
        return evaluator.fail(.overflow, "formatted string is too large");
}

test "text substring matcher works across codepoint widths" {
    const allocator = std.testing.allocator;
    const text = try list.fromCodepoints(allocator, &.{ 'a', 0x100, 'b' });
    defer heap.releaseValue(allocator, text);
    const separator = try list.fromCodepoints(allocator, &.{0x100});
    defer heap.releaseValue(allocator, separator);
    try std.testing.expect(startsWithAt(text, separator, 1));
    try std.testing.expect(!startsWithAt(text, separator, 0));
}

test "list put reuses unique headers across representation changes" {
    const allocator = std.testing.allocator;
    const integers = try list.fromI64Slice(allocator, &.{ 1, 2, 3 });
    defer heap.releaseValue(allocator, integers);
    const updated = try replaceListItem(allocator, integers, 1, .{ .int = 9 }, null);
    try std.testing.expectEqual(integers.list, updated.list);
    try std.testing.expectEqual(@as(i64, 9), list.atUnchecked(updated, 1).int);

    const string = try list.fromCodepoints(allocator, &.{ 'a', 'b' });
    defer heap.releaseValue(allocator, string);
    const widened = try replaceListItem(allocator, string, 0, .{ .char = 'λ' }, null);
    try std.testing.expectEqual(string.list, widened.list);
    try std.testing.expectEqual(value.HeapKind.leaf_char2, widened.list.kind());
    try std.testing.expectEqual(@as(u32, 'λ'), list.atUnchecked(widened, 0).char);
}
