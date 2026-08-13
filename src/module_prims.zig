//! Module, environment, reflection, and source-transport primitives.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Mode = enum { def, let, defp, letp };
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
        .{ .name = "let", .primitive = bind(.let) },
        .{ .name = "defp", .primitive = bind(.defp) },
        .{ .name = "letp", .primitive = bind(.letp) },
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
    const private = mode == .defp or mode == .letp;
    const scope = evaluator.currentScope();
    const module_root = scope.kind == .module_root;
    if (private and !module_root) return evaluator.fail(.domain, "defp/letp are legal only in a module root");
    if (module_root and word_binding and evaluator.available() < 3) return evaluator.fail(.domain, "module def/defp requires an effect declaration");
    const name = try unqualifiedSymbol(evaluator, try evaluator.popOwned(), "def/let");
    var effect: ?env.Effect = null;
    var effect_value: ?Value = null;
    defer if (effect_value) |item| heap.releaseValue(evaluator.allocator(), item);
    if (module_root and word_binding) {
        effect_value = try evaluator.popOwned();
        effect = try parseEffect(evaluator, effect_value.?);
    }
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    if (word_binding and item != .list) return evaluator.fail(.type, "def expected a list body; use let for values");
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
    const names = try evaluator.visibleNamesOwned();
    defer evaluator.allocator().free(names);
    std.mem.sort(u32, names, {}, symbolLessThan);
    for (names, 0..) |name, index| {
        if (index > 0) output.writeByte(' ') catch return writeFailure(evaluator);
        output.writeAll(intern.get(name)) catch return writeFailure(evaluator);
    }
    output.writeByte('\n') catch return writeFailure(evaluator);
    output.flush() catch return evaluator.fail(.io, "standard output flush failed");
}
fn symbolLessThan(_: void, left: u32, right: u32) bool {
    return std.mem.lessThan(u8, intern.get(left), intern.get(right));
}
fn which(evaluator: *Machine) MachineError!void {
    const requested = try symbolValue(evaluator, try evaluator.popOwned());
    var resolved = (try evaluator.resolveName(requested)) orelse return evaluator.undefinedName(requested);
    defer resolved.deinit(evaluator.allocator());
    const output = try outputWriter(evaluator);
    output.print("{s} -> {s} {s} {s}", .{ intern.get(requested), intern.get(resolved.trace_word), switch (resolved.lease.binding) {
        .word => "def",
        .value => "let",
        .primitive => "primitive",
    }, @tagName(resolved.lease.visibility) }) catch return writeFailure(evaluator);
    if (resolved.home) |home| output.print(" generation {d}", .{home.generation}) catch return writeFailure(evaluator);
    if (resolved.lease.effect) |effect| {
        output.writeByte(' ') catch return writeFailure(evaluator);
        try printValue(evaluator, .{ .list = effect.quotation }, output);
    }
    const shadows = try evaluator.shadowTraceIdsOwned(requested);
    defer evaluator.allocator().free(shadows);
    for (shadows) |shadow| output.print("; shadows {s}", .{intern.get(shadow)}) catch return writeFailure(evaluator);
    output.writeByte('\n') catch return writeFailure(evaluator);
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
            output.print(" '{s} {s}\n", .{ intern.get(resolved.trace_word), if (resolved.lease.visibility == .private) "defp" else "def" }) catch return writeFailure(evaluator);
        },
        .value => |item| {
            try printValue(evaluator, item, output);
            output.print(" '{s} {s}\n", .{ intern.get(resolved.trace_word), if (resolved.lease.visibility == .private) "letp" else "let" }) catch return writeFailure(evaluator);
        },
        .primitive => {
            output.writeAll("<primitive>") catch return writeFailure(evaluator);
            if (resolved.lease.effect) |effect| {
                output.writeByte(' ') catch return writeFailure(evaluator);
                try printValue(evaluator, .{ .list = effect.quotation }, output);
            }
            output.print(" '{s} def\n", .{intern.get(resolved.trace_word)}) catch return writeFailure(evaluator);
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
fn printValue(evaluator: *Machine, item: Value, output: *std.Io.Writer) MachineError!void {
    printer.printWithAllocator(evaluator.allocator(), item, output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return writeFailure(evaluator),
    };
}
fn load(evaluator: *Machine) MachineError!void {
    const path_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), path_value);
    if (!path_value.isString()) return evaluator.typeError("a string path");
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(evaluator.allocator());
    for (0..@as(usize, @intCast(path_value.list.len))) |index| {
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(list.atUnchecked(path_value, index).char), &encoded) catch return evaluator.fail(.domain, "path contains an invalid Unicode scalar");
        try path.appendSlice(evaluator.allocator(), encoded[0..length]);
    }
    try evaluator.loadPathOwned(path.items, null);
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
