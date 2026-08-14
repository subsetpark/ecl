//! Stack/control primitives and the installer for the closed kernel surface.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const intern = @import("intern.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const module_prims = @import("module_prims.zig");
const combinators = @import("combinators.zig");
const kernels = @import("kernels.zig");
const kernel_support = @import("kernel_support.zig");
const kernel_storage = @import("kernel_storage.zig");
const reader = @import("reader.zig");
const poll = @import("poll.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Definition = struct {
    name: []const u8,
    primitive: env.PrimitiveImpl,
};
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "dup", .primitive = dup },
        .{ .name = "swap", .primitive = swap },
        .{ .name = "pop", .primitive = pop },
        .{ .name = "over", .primitive = over },
        .{ .name = "cons", .primitive = cons },
        .{ .name = "compose", .primitive = compose },
        .{ .name = "match", .primitive = match },
        .{ .name = "type", .primitive = typeWord },
        .{ .name = "str", .primitive = strWord },
        .{ .name = "parse", .primitive = parse },
        .{ .name = "dict-of", .primitive = dictOf },
        .{ .name = "attempt", .primitive = attempt },
        .{ .name = "raise", .primitive = raise },
        .{ .name = "pp", .primitive = pp },
        .{ .name = "prin", .primitive = prin },
        .{ .name = "args", .primitive = args },
        .{ .name = "exit", .primitive = exit },
    };
    try core.installBuiltins(definitions);
    try combinators.install(core);
    try kernels.install(core);
    try module_prims.install(core);
}
fn dup(evaluator: *Machine) MachineError!void {
    try evaluator.require(1);
    try evaluator.pushBorrowed(evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1]);
}
fn swap(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    std.mem.swap(Value, &items[items.len - 1], &items[items.len - 2]);
}
fn pop(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    heap.releaseValue(evaluator.allocator(), item);
}
fn over(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    try evaluator.pushBorrowed(items[items.len - 2]);
}
fn cons(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const count: usize = @intCast(collection.list.length());
    const values = try evaluator.allocator().alloc(Value, count + 1);
    defer evaluator.allocator().free(values);
    values[0] = item;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        values[index + 1] = list.atUnchecked(collection, index);
    }
    try evaluator.pushOwned(try kernel_storage.fromValues(
        evaluator.allocator(),
        values,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}
fn compose(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    if (left != .list or right != .list) return evaluator.typeError("two lists");
    const left_len: usize = @intCast(left.list.length());
    const right_len: usize = @intCast(right.list.length());
    const values = try evaluator.allocator().alloc(Value, left_len + right_len);
    defer evaluator.allocator().free(values);
    for (0..left_len) |index| {
        try evaluator.advanceKernel(1);
        values[index] = list.atUnchecked(left, index);
    }
    for (0..right_len) |index| {
        try evaluator.advanceKernel(1);
        values[left_len + index] = list.atUnchecked(right, index);
    }
    try evaluator.pushOwned(try kernel_storage.fromValues(
        evaluator.allocator(),
        values,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
}
fn match(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    const matches = try equal.matchWithPolling(
        evaluator.allocator(),
        left,
        right,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    );
    try evaluator.pushOwned(.{ .int = @intFromBool(matches) });
}
fn typeWord(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const spelling: []const u8 = switch (item) {
        .int => "int",
        .float => "float",
        .char => "char",
        .symbol => "symbol",
        .word => "word",
        .list => "list",
        .dict => "dict",
    };
    try evaluator.pushOwned(.{ .symbol = try intern.intern(spelling) });
}
fn strWord(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const poller = (kernel_support.Context{ .evaluator = evaluator }).structuralPoller();
    const rendered = try printer.toOwnedStringWithPolling(evaluator.allocator(), item, poller);
    defer evaluator.allocator().free(rendered);
    const result = kernel_storage.fromUtf8(evaluator.allocator(), rendered, poller) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.InvalidUtf8 => unreachable,
    };
    try evaluator.pushOwned(result);
}

fn parse(evaluator: *Machine) MachineError!void {
    const source_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), source_value);
    if (!source_value.isString()) return evaluator.typeError("a string");
    const poller = (kernel_support.Context{ .evaluator = evaluator }).structuralPoller();
    const source = kernel_storage.toUtf8Owned(evaluator.allocator(), source_value, poller) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.InvalidCodepoint => return evaluator.fail(.domain, "string contains an invalid Unicode scalar"),
    };
    defer evaluator.allocator().free(source);
    var diag: reader.Diag = .{};
    const result = reader.readPolling(
        evaluator.allocator(),
        "<parse>",
        source,
        &diag,
        poll.WorkContext.init(poller),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.Parse => {
            const failure = evaluator.fail(.parse, diag.text());
            evaluator.unit.pending.?.setLocation("<parse>", diag.span);
            return failure;
        },
    };
    var parsed = switch (result) {
        .complete => |complete| complete,
        .incomplete => |incomplete| {
            const failure = evaluator.fail(.parse, incomplete.message);
            evaluator.unit.pending.?.setLocation("<parse>", incomplete.span);
            return failure;
        },
    };
    defer parsed.deinit();
    const root = try kernel_storage.fromValuesGeneric(evaluator.allocator(), parsed.forms, poller);
    var root_owned = true;
    defer if (root_owned) heap.releaseValue(evaluator.allocator(), root);
    try evaluator.unit.archive.absorb(&parsed, root, poll.WorkContext.init(poller));
    root_owned = false;
    try evaluator.pushBorrowed(root);
}
fn dictOf(evaluator: *Machine) MachineError!void {
    const entries = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), entries);
    if (entries != .list) return evaluator.typeError("a flat key/value list");
    const count: usize = @intCast(entries.list.length());
    if (count % 2 != 0) {
        return evaluator.fail(.contract, "dict-of requires an even-length key/value list");
    }
    const pairs = try evaluator.allocator().alloc(dict.Pair, count / 2);
    defer evaluator.allocator().free(pairs);
    for (pairs, 0..) |*pair, index| {
        try evaluator.advanceKernel(2);
        pair.* = .{
            list.atUnchecked(entries, index * 2),
            list.atUnchecked(entries, index * 2 + 1),
        };
    }
    const dictionary = kernel_storage.fromPairs(
        evaluator.allocator(),
        pairs,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.DuplicateKey => return evaluator.fail(.domain, "dict-of received a duplicate key"),
    };
    try evaluator.pushOwned(dictionary);
}
fn attempt(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    try evaluator.attemptOwned(try quotationHeader(evaluator, quotation));
}
fn raise(evaluator: *Machine) MachineError!void {
    const raised = try evaluator.popOwned();
    var raised_owned = true;
    defer if (raised_owned) heap.releaseValue(evaluator.allocator(), raised);
    if (raised != .dict) {
        return evaluator.typeError("an error dict");
    }
    const kind_id = try intern.intern("kind");
    const kind = try dict.symbolField(evaluator.allocator(), raised, kind_id) orelse {
        return evaluator.typeError("an error dict containing a symbol at 'kind");
    };
    if (kind != .symbol) {
        return evaluator.typeError("an error dict containing a symbol at 'kind");
    }
    const msg_id = try intern.intern("msg");
    if (try dict.symbolField(evaluator.allocator(), raised, msg_id)) |message| {
        if (!message.isString()) {
            return evaluator.typeError("an error dict with a string at 'msg");
        }
    }
    const word_id = try intern.intern("word");
    if (try dict.symbolField(evaluator.allocator(), raised, word_id)) |word| {
        if (word != .symbol) {
            return evaluator.typeError("an error dict with a symbol at 'word");
        }
    }
    const trace_id = try intern.intern("trace");
    if (try dict.symbolField(evaluator.allocator(), raised, trace_id)) |trace| {
        if (trace != .list or !allSymbols(trace)) {
            return evaluator.typeError("an error dict with symbols at 'trace");
        }
    }
    const data_id = try intern.intern("data");
    if (try dict.symbolField(evaluator.allocator(), raised, data_id)) |data| {
        if (data != .dict) {
            return evaluator.typeError("an error dict with a dict at 'data");
        }
    }
    raised_owned = false;
    return evaluator.raiseOwned(raised);
}
fn allSymbols(item: Value) bool {
    if (item != .list) return false;
    const count: usize = @intCast(item.list.length());
    for (0..count) |index| if (list.atUnchecked(item, index) != .symbol) return false;
    return true;
}
fn pp(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const output = evaluator.unit.output orelse
        return evaluator.fail(.io, "standard output is unavailable");
    printer.printWithPolling(
        evaluator.allocator(),
        item,
        output,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.WriteFailed => return evaluator.fail(.io, "standard output write failed"),
    };
    output.writeByte('\n') catch
        return evaluator.fail(.io, "standard output write failed");
    output.flush() catch
        return evaluator.fail(.io, "standard output flush failed");
}
fn prin(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    if (!item.isString()) return evaluator.typeError("a string");
    const output = evaluator.unit.output orelse
        return evaluator.fail(.io, "standard output is unavailable");
    const count: usize = @intCast(item.list.length());
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            @intCast(list.atUnchecked(item, index).char),
            &encoded,
        ) catch return evaluator.fail(.domain, "string contains an invalid Unicode scalar");
        output.writeAll(encoded[0..length]) catch
            return evaluator.fail(.io, "standard output write failed");
    }
    output.flush() catch
        return evaluator.fail(.io, "standard output flush failed");
}
fn args(evaluator: *Machine) MachineError!void {
    try evaluator.pushBorrowed(evaluator.unit.arguments);
}
fn exit(evaluator: *Machine) MachineError!void {
    const status = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), status);
    if (status != .int or status.int < 0 or status.int > 255) {
        return evaluator.typeError("an exit status from 0 through 255");
    }
    evaluator.unit.exit_status = @intCast(status.int);
}
fn quotationHeader(evaluator: *Machine, item: Value) MachineError!*value.Header {
    return switch (item) {
        .list => |header| header,
        .int, .float, .char, .symbol, .word, .dict => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a quotation/list");
        },
    };
}
