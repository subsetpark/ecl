//! Module, environment, reflection, and source-transport primitives.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const kernel_support = @import("kernel_support.zig");
const poll_api = @import("poll.zig");
const reflection = @import("reflection.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Mode = enum { def, set, defp, setp };
const Definition = struct { name: []const u8, primitive: env.Primitive };
fn bind(comptime mode: Mode) env.Primitive {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return define(evaluator, mode);
        }
    }.run;
}
pub fn install(core: *env.Env) error{OutOfMemory}!void {
    const definitions = [_]Definition{
        .{ .name = "def", .primitive = bind(.def) },
        .{ .name = "set", .primitive = bind(.set) },
        .{ .name = "defp", .primitive = bind(.defp) },
        .{ .name = "setp", .primitive = bind(.setp) },
        .{ .name = "module", .primitive = moduleWord },
        .{ .name = "use", .primitive = useModule },
        .{ .name = "alias", .primitive = aliasModule },
        .{ .name = "body", .primitive = bodyWord },
        .{ .name = "words", .primitive = words },
        .{ .name = "which", .primitive = which },
        .{ .name = "see", .primitive = see },
        .{ .name = "load", .primitive = load },
    };
    for (definitions) |definition| {
        try core.installCore(try intern.intern(definition.name), .{ .primitive = definition.primitive });
    }
}
fn define(evaluator: *Machine, mode: Mode) MachineError!void {
    try evaluator.require(2);
    const word_binding = mode == .def or mode == .defp;
    const private = mode == .defp or mode == .setp;
    const scope = evaluator.currentScope();
    const module_root = scope.kind == .module_root;
    if (private and !module_root) return evaluator.fail(.domain, "defp/setp are legal only in a module root");
    if (module_root and word_binding and evaluator.available() < 3) return evaluator.fail(.domain, "module def/defp requires an effect declaration");
    const name = try unqualifiedSymbol(evaluator, try evaluator.popOwned(), "def/set");
    var effect: ?env.Effect = null;
    var effect_value: ?Value = null;
    defer if (effect_value) |item| heap.releaseValue(evaluator.allocator(), item);
    if (module_root and word_binding) {
        effect_value = try evaluator.popOwned();
        effect = try parseEffect(evaluator, effect_value.?);
    }
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    if (word_binding and item != .list) return evaluator.fail(.type, "def expected a list body; use set for values");
    _ = scope.bindDetailed(name, .{
        .binding = if (word_binding) .{ .word = item.list } else .{ .value = item },
        .visibility = if (private) .private else .public,
        .home = if (module_root) evaluator.currentHome().?.name else null,
        .effect = effect,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Frozen => return evaluator.fail(.domain, "module environments are immutable after registration"),
    };
}
fn parseEffect(evaluator: *Machine, item: Value) MachineError!env.Effect {
    if (item != .list) return evaluator.fail(.domain, "effect declaration must be a quotation");
    return env.Effect.parse(item.list, try intern.intern("--")) orelse
        evaluator.fail(.domain, "effect declaration must contain only words and exactly one --");
}
fn moduleWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const body = try quotationHeader(evaluator, try evaluator.popOwned());
    const name = unqualifiedSymbol(evaluator, try evaluator.popOwned(), "module") catch |err| {
        heap.decRef(evaluator.allocator(), body);
        return err;
    };
    try evaluator.moduleOwned(name, body);
}
fn useModule(evaluator: *Machine) MachineError!void {
    try evaluator.useOrLoad(try unqualifiedSymbol(evaluator, try evaluator.popOwned(), "use"));
}
fn aliasModule(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const target = try unqualifiedSymbol(evaluator, try evaluator.popOwned(), "alias target");
    const short = try unqualifiedSymbol(evaluator, try evaluator.popOwned(), "alias name");
    try evaluator.aliasModule(short, target);
}
fn unqualifiedSymbol(evaluator: *Machine, item: Value, context: []const u8) MachineError!u32 {
    const name = try symbolValue(evaluator, item);
    if (std.mem.indexOfScalar(u8, intern.get(name), '.') != null) return evaluator.failFmt(.domain, "{s} requires an unqualified name", .{context});
    return name;
}
fn symbolValue(evaluator: *Machine, item: Value) MachineError!u32 {
    return switch (item) {
        .symbol => |id| id,
        else => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a symbol name");
        },
    };
}
fn bodyWord(evaluator: *Machine) MachineError!void {
    const requested = try symbolValue(evaluator, try evaluator.popOwned());
    var resolved = (try evaluator.resolveName(requested)) orelse return evaluator.undefinedName(requested);
    defer resolved.deinit(evaluator.allocator());
    const body = switch (resolved.lease.binding) {
        .word => |header| header,
        else => return evaluator.typeError("a source-defined word"),
    };
    try evaluator.pushBorrowed(.{ .list = body });
}
fn words(evaluator: *Machine) MachineError!void {
    const output = try outputWriter(evaluator);
    const names = try visibleNamesOwned(evaluator);
    defer evaluator.allocator().free(names);
    try reflection.sortNames(names, (kernel_support.Context{ .evaluator = evaluator }).structuralPoller());
    var previous: ?u32 = null;
    var emitted: usize = 0;
    for (names) |name| {
        try evaluator.advanceKernel(1);
        if (previous == name) continue;
        if (emitted > 0) try writeBytes(evaluator, output, " ");
        try writeName(evaluator, output, name);
        previous = name;
        emitted += 1;
    }
    try writeBytes(evaluator, output, "\n");
    output.flush() catch return evaluator.fail(.io, "standard output flush failed");
}
fn visibleNamesOwned(evaluator: *Machine) MachineError![]u32 {
    var found = poll_api.ChunkStack(u32).init(evaluator.allocator());
    defer found.deinit();
    var count: usize = 0;
    const poller = (kernel_support.Context{ .evaluator = evaluator }).structuralPoller();
    var scope: ?*env.Scope = evaluator.currentScope();
    while (scope) |current_scope| : (scope = current_scope.parent) {
        if (current_scope.environment) |environment| {
            const direct = try environment.namesOwned(evaluator.allocator(), poller);
            defer evaluator.allocator().free(direct);
            try appendNames(evaluator, &found, &count, direct);
            if (evaluator.unit.registry) |registry| {
                var index = environment.useOrder().len;
                while (index > 0) {
                    index -= 1;
                    var lease = registry.acquire(environment.useOrder()[index]) orelse continue;
                    defer lease.deinit();
                    const names = try lease.generation.publicNamesOwned(evaluator.allocator(), poller);
                    defer evaluator.allocator().free(names);
                    try appendNames(evaluator, &found, &count, names);
                }
            }
        }
    }
    const core_names = try evaluator.currentEnv().core.namesOwned(evaluator.allocator(), poller);
    defer evaluator.allocator().free(core_names);
    try appendNames(evaluator, &found, &count, core_names);
    const result = try evaluator.allocator().alloc(u32, count);
    errdefer evaluator.allocator().free(result);
    var index = count;
    while (found.pop()) |name| {
        try evaluator.advanceKernel(1);
        index -= 1;
        result[index] = name;
    }
    return result;
}
fn appendNames(
    evaluator: *Machine,
    destination: *poll_api.ChunkStack(u32),
    count: *usize,
    names: []const u32,
) MachineError!void {
    for (names) |name| {
        try evaluator.advanceKernel(1);
        const new_count = std.math.add(usize, count.*, 1) catch return error.OutOfMemory;
        try destination.push(name);
        count.* = new_count;
    }
}
fn which(evaluator: *Machine) MachineError!void {
    const requested = try symbolValue(evaluator, try evaluator.popOwned());
    var resolved = (try evaluator.resolveName(requested)) orelse return evaluator.undefinedName(requested);
    defer resolved.deinit(evaluator.allocator());
    const output = try outputWriter(evaluator);
    try writeName(evaluator, output, requested);
    try writeBytes(evaluator, output, " -> ");
    try writeName(evaluator, output, resolved.trace_word);
    try writeBytes(evaluator, output, " ");
    try writeBytes(evaluator, output, switch (resolved.lease.binding) {
        .word => "def",
        .value => "set",
        .primitive => "primitive",
    });
    try writeBytes(evaluator, output, " ");
    try writeBytes(evaluator, output, @tagName(resolved.lease.visibility));
    if (resolved.home) |home| output.print(" generation {d}", .{home.generation}) catch return writeFailure(evaluator);
    if (resolved.lease.effect) |effect| {
        output.writeByte(' ') catch return writeFailure(evaluator);
        try printValue(evaluator, .{ .list = effect.quotation }, output);
    }
    const shadows = try evaluator.shadowTraceIdsOwned(requested);
    defer evaluator.allocator().free(shadows);
    for (shadows) |shadow| {
        try writeBytes(evaluator, output, "; shadows ");
        try writeName(evaluator, output, shadow);
    }
    try writeBytes(evaluator, output, "\n");
    output.flush() catch return evaluator.fail(.io, "standard output flush failed");
}
fn see(evaluator: *Machine) MachineError!void {
    const requested = try symbolValue(evaluator, try evaluator.popOwned());
    var resolved = (try evaluator.resolveName(requested)) orelse return evaluator.undefinedName(requested);
    defer resolved.deinit(evaluator.allocator());
    const output = try outputWriter(evaluator);
    switch (resolved.lease.binding) {
        .word => |body| {
            try printValue(evaluator, .{ .list = body }, output);
            if (resolved.lease.effect) |effect| {
                output.writeByte(' ') catch return writeFailure(evaluator);
                try printValue(evaluator, .{ .list = effect.quotation }, output);
            }
            try writeBytes(evaluator, output, " '");
            try writeName(evaluator, output, resolved.trace_word);
            try writeBytes(evaluator, output, if (resolved.lease.visibility == .private) " defp\n" else " def\n");
        },
        .value => |item| {
            try printValue(evaluator, item, output);
            try writeBytes(evaluator, output, " '");
            try writeName(evaluator, output, resolved.trace_word);
            try writeBytes(evaluator, output, if (resolved.lease.visibility == .private) " setp\n" else " set\n");
        },
        .primitive => {
            output.writeAll("<primitive>") catch return writeFailure(evaluator);
            if (resolved.lease.effect) |effect| {
                output.writeByte(' ') catch return writeFailure(evaluator);
                try printValue(evaluator, .{ .list = effect.quotation }, output);
            }
            try writeBytes(evaluator, output, " '");
            try writeName(evaluator, output, resolved.trace_word);
            try writeBytes(evaluator, output, " def\n");
        },
    }
    output.flush() catch return evaluator.fail(.io, "standard output flush failed");
}
fn outputWriter(evaluator: *Machine) MachineError!*std.Io.Writer {
    return evaluator.unit.output orelse return evaluator.fail(.io, "standard output is unavailable");
}
fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}
fn writeName(evaluator: *Machine, output: *std.Io.Writer, name: u32) MachineError!void {
    return writeBytes(evaluator, output, intern.get(name));
}
fn writeBytes(
    evaluator: *Machine,
    output: *std.Io.Writer,
    bytes: []const u8,
) MachineError!void {
    reflection.writeBytes(
        output,
        bytes,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.WriteFailed => return writeFailure(evaluator),
    };
}
fn printValue(evaluator: *Machine, item: Value, output: *std.Io.Writer) MachineError!void {
    printer.printWithPolling(
        evaluator.allocator(),
        item,
        output,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.WriteFailed => return writeFailure(evaluator),
    };
}
fn load(evaluator: *Machine) MachineError!void {
    const path_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), path_value);
    if (!path_value.isString()) return evaluator.typeError("a string path");
    const count: usize = @intCast(path_value.list.len);
    var byte_count: usize = 0;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            @intCast(list.atUnchecked(path_value, index).char),
            &encoded,
        ) catch return evaluator.fail(.domain, "path contains an invalid Unicode scalar");
        byte_count = std.math.add(usize, byte_count, length) catch return error.OutOfMemory;
    }
    const path = try evaluator.allocator().alloc(u8, byte_count);
    defer evaluator.allocator().free(path);
    var cursor: usize = 0;
    for (0..@as(usize, @intCast(path_value.list.len))) |index| {
        try evaluator.advanceKernel(1);
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(list.atUnchecked(path_value, index).char), &encoded) catch return evaluator.fail(.domain, "path contains an invalid Unicode scalar");
        @memcpy(path[cursor..][0..length], encoded[0..length]);
        cursor += length;
    }
    try evaluator.loadPathOwned(path, null);
}
fn quotationHeader(evaluator: *Machine, item: Value) MachineError!*value.Header {
    return switch (item) {
        .list => |header| header,
        else => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a quotation/list");
        },
    };
}
