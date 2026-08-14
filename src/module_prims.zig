//! Module, environment, reflection, and source-transport primitives.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const definition_prims = @import("definition_prims.zig");
const kernel_support = @import("kernel_support.zig");
const poll_api = @import("poll.zig");
const reflection = @import("reflection.zig");
const kernel_storage = @import("kernel_storage.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try definition_prims.install(core);
    const definitions = comptime [_]Definition{
        .{ .name = "module", .primitive = moduleWord },
        .{ .name = "use", .primitive = useModule },
        .{ .name = "alias", .primitive = aliasModule },
        .{ .name = "words", .primitive = words },
        .{ .name = "load", .primitive = load },
    };
    try core.installBuiltins(definitions);
}
fn moduleWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const body = try quotationHeader(evaluator, try evaluator.popOwned());
    const name = namespaceSymbol(evaluator, try evaluator.popOwned(), "module") catch |err| {
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
    const target = try namespaceSymbol(evaluator, try evaluator.popOwned(), "alias target");
    const short = try namespaceSymbol(evaluator, try evaluator.popOwned(), "alias name");
    try evaluator.aliasModule(short, target);
}
fn namespaceSymbol(
    evaluator: *Machine,
    item: Value,
    context: []const u8,
) MachineError!intern.NamespaceName {
    const name = try unqualifiedSymbol(evaluator, item, context);
    return intern.namespaceName(
        name,
        poll_api.WorkContext.init((kernel_support.Context{ .evaluator = evaluator }).structuralPoller()),
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Ecl => error.Ecl,
        error.InvalidName => evaluator.fail(.domain, "-- and : are reserved namespace names"),
    };
}
fn unqualifiedSymbol(evaluator: *Machine, item: Value, context: []const u8) MachineError!u32 {
    const name = try symbolValue(evaluator, item);
    if (try intern.dotIndexPolling(
        intern.get(name),
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) != null) return evaluator.failFmt(.domain, "{s} requires an unqualified name", .{context});
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
    const work = poll_api.WorkContext.init(poller);
    var scope: ?*env.Scope = evaluator.currentScope();
    while (scope) |current_scope| : (scope = current_scope.parent) {
        try work.step();
        if (current_scope.environmentOrNull()) |environment| {
            const direct = try environment.namesOwned(
                evaluator.allocator(),
                work,
            );
            defer evaluator.allocator().free(direct);
            try appendNames(evaluator, &found, &count, direct);
            if (evaluator.unit.registry) |registry| {
                const uses = environment.useOrder();
                var use_indices = work.reverseIndices(0, uses.len);
                while (try use_indices.next()) |index| {
                    var lease = try registry.acquireWork(
                        uses[index],
                        work,
                    ) orelse continue;
                    defer lease.deinit();
                    const names = try lease.generation.publicNamesOwned(
                        evaluator.allocator(),
                        work,
                    );
                    defer evaluator.allocator().free(names);
                    try appendNames(evaluator, &found, &count, names);
                }
            }
        }
    }
    const core_names = try evaluator.currentEnv().core.namesOwned(
        evaluator.allocator(),
        work,
    );
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
fn load(evaluator: *Machine) MachineError!void {
    const path_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), path_value);
    if (!path_value.isString()) return evaluator.typeError("a string path");
    const path = kernel_storage.toUtf8Owned(
        evaluator.allocator(),
        path_value,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.InvalidCodepoint => return evaluator.fail(.domain, "path contains an invalid Unicode scalar"),
    };
    defer evaluator.allocator().free(path);
    try evaluator.loadPathOwned(path);
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
