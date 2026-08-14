//! Definition annotations and binding metadata reflection.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const kernel_support = @import("kernel_support.zig");
const kernel_storage = @import("kernel_storage.zig");
const reflection = @import("reflection.zig");
const doc_text = @import("doc.zig");
const poll = @import("poll.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Mode = enum { def, set, defp, setp };
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };

fn bind(comptime mode: Mode) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return define(evaluator, mode);
        }
    }.run;
}

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "def", .primitive = bind(.def) },
        .{ .name = "set", .primitive = bind(.set) },
        .{ .name = "defp", .primitive = bind(.defp) },
        .{ .name = "setp", .primitive = bind(.setp) },
        .{ .name = "body", .primitive = body },
        .{ .name = "doc", .primitive = doc },
        .{ .name = "which", .primitive = which },
        .{ .name = "see", .primitive = see },
    };
    try core.installBuiltins(definitions);
}

const Annotation = struct {
    effect: ?env.Effect = null,
    effect_value: ?Value = null,
    doc_value: ?*env.DocumentationString = null,
    doc_owned: ?Value = null,

    fn deinit(self: *Annotation, allocator: std.mem.Allocator) void {
        if (self.effect_value) |item| heap.releaseValue(allocator, item);
        if (self.doc_owned) |item| heap.releaseValue(allocator, item);
        self.* = undefined;
    }
};

fn define(evaluator: *Machine, mode: Mode) MachineError!void {
    try evaluator.require(2);
    const word_binding = mode == .def or mode == .defp;
    const private = mode == .defp or mode == .setp;
    const scope = evaluator.currentScope();
    const module_root = scope.kind() == .module_root;
    if (private and !module_root) return evaluator.fail(.domain, "defp/setp are legal only in a module root");
    const name = try unqualifiedSymbol(evaluator, try evaluator.popOwned(), "def/set");

    var annotation: Annotation = .{};
    defer annotation.deinit(evaluator.allocator());
    var annotation_value: ?Value = null;
    defer if (annotation_value) |item| heap.releaseValue(evaluator.allocator(), item);
    var item = try evaluator.popOwned();
    var item_owned = true;
    defer if (item_owned) heap.releaseValue(evaluator.allocator(), item);
    if (word_binding and item == .list) {
        if (try parseAnnotation(evaluator, item.list)) |parsed| {
            annotation = parsed;
            annotation_value = item;
            item_owned = false;
            try evaluator.require(1);
            item = try evaluator.popOwned();
            item_owned = true;
        }
    }
    if (word_binding and item != .list) return evaluator.fail(.type, "def expected a list body; use set for values");
    if (module_root and word_binding and annotation.effect == null) {
        return evaluator.fail(.domain, "module def/defp requires an effect declaration");
    }
    const visibility: env.Visibility = if (private) .private else .public;
    const work = poll.WorkContext.init((kernel_support.Context{ .evaluator = evaluator }).structuralPoller());
    const publication_result = if (module_root) blk: {
        const publication: env.ModulePublication = if (word_binding) .{ .word = .{
            .body = env.quotation(item.list) orelse
                return evaluator.fail(.domain, "definition body has an invalid heap representation"),
            .visibility = visibility,
            .effect = annotation.effect.?,
            .doc = annotation.doc_value,
        } } else .{ .value = .{ .item = item, .visibility = visibility } };
        break :blk scope.publishModule(name, publication, work);
    } else blk: {
        const publication: env.TopPublication = if (word_binding) .{ .word = .{
            .body = env.quotation(item.list) orelse
                return evaluator.fail(.domain, "definition body has an invalid heap representation"),
            .effect = annotation.effect,
            .doc = annotation.doc_value,
        } } else .{ .value = item };
        break :blk scope.publishTop(name, publication, work);
    };
    _ = publication_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.Ecl,
        error.Frozen => return evaluator.fail(.domain, "module environments are immutable after registration"),
    };
}

fn parseAnnotation(evaluator: *Machine, header: *value.Header) MachineError!?Annotation {
    const separator = try intern.intern("--");
    const colon = try intern.intern(":");
    const candidate: Value = .{ .list = header };
    const count: usize = @intCast(header.length());
    var separator_at: ?usize = null;
    var colon_at: ?usize = null;
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        const item = list.atUnchecked(candidate, index);
        if (item != .word) continue;
        if (item.word == separator) {
            if (separator_at != null) return malformedAnnotation(evaluator);
            separator_at = index;
        } else if (item.word == colon) {
            if (colon_at != null) return malformedAnnotation(evaluator);
            colon_at = index;
        }
    }
    if (separator_at == null and colon_at == null) return null;
    if (separator_at != null and colon_at != null and separator_at.? > colon_at.?) {
        return malformedAnnotation(evaluator);
    }
    const effect_end = colon_at orelse count;
    if (separator_at) |split| {
        for (0..effect_end) |index| {
            try evaluator.advanceKernel(1);
            if (index != split and list.atUnchecked(candidate, index) != .word) {
                return malformedAnnotation(evaluator);
            }
        }
    } else if (colon_at.? != 0) return malformedAnnotation(evaluator);
    var document: ?Value = null;
    if (colon_at) |doc_at| {
        if (count != doc_at + 2) return malformedAnnotation(evaluator);
        const item = list.atUnchecked(candidate, doc_at + 1);
        if (!item.isString()) return malformedAnnotation(evaluator);
        document = item;
    }
    var result: Annotation = .{};
    errdefer result.deinit(evaluator.allocator());
    if (document) |item| {
        const normalized = try doc_text.normalize(
            evaluator.allocator(),
            item,
            (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
        );
        result.doc_owned = normalized;
        result.doc_value = env.documentation(normalized.list) orelse unreachable;
    }
    if (separator_at != null) {
        const effect_items = try evaluator.allocator().alloc(Value, effect_end);
        defer evaluator.allocator().free(effect_items);
        for (0..effect_end) |index| {
            try evaluator.advanceKernel(1);
            effect_items[index] = list.atUnchecked(candidate, index);
        }
        const effect_value = try kernel_storage.fromValuesGeneric(
            evaluator.allocator(),
            effect_items,
            (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
        );
        result.effect_value = effect_value;
        result.effect = try env.ValidatedEffect.parse(
            effect_value.list,
            separator,
            poll.WorkContext.init((kernel_support.Context{ .evaluator = evaluator }).structuralPoller()),
        ) orelse return malformedAnnotation(evaluator);
    }
    return result;
}

fn malformedAnnotation(evaluator: *Machine) MachineError {
    return evaluator.fail(.domain, "malformed definition annotation");
}

fn body(evaluator: *Machine) MachineError!void {
    const requested = try symbolValue(evaluator, try evaluator.popOwned());
    var resolved = (try evaluator.resolveName(requested)) orelse return evaluator.undefinedName(requested);
    defer resolved.deinit(evaluator.allocator());
    const source = switch (resolved.lease.binding) {
        .word => |source| env.quotationHeader(source),
        else => return evaluator.typeError("a source-defined word"),
    };
    try evaluator.pushBorrowed(.{ .list = source });
}

fn doc(evaluator: *Machine) MachineError!void {
    const requested = try symbolValue(evaluator, try evaluator.popOwned());
    var resolved = (try evaluator.resolveName(requested)) orelse return evaluator.undefinedName(requested);
    defer resolved.deinit(evaluator.allocator());
    try evaluator.pushBorrowed(.{ .list = env.documentationHeader(resolved.lease.doc orelse
        return evaluator.fail(.domain, "binding has no documentation")) });
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
        .primitive, .builtin => "primitive",
    });
    try writeBytes(evaluator, output, " ");
    try writeBytes(evaluator, output, @tagName(resolved.lease.visibility));
    if (resolved.home) |home| output.print(" generation {d}", .{home.generation}) catch return writeFailure(evaluator);
    if (resolved.lease.effect) |effect| {
        output.writeByte(' ') catch return writeFailure(evaluator);
        try printValue(evaluator, .{ .list = effect.header() }, output);
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
        .word => |source| {
            try printValue(evaluator, .{ .list = env.quotationHeader(source) }, output);
            try printAnnotation(evaluator, resolved.lease.effect, resolved.lease.doc, output);
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
        .primitive, .builtin => {
            try writeBytes(evaluator, output, "<primitive>");
            try printAnnotation(evaluator, resolved.lease.effect, resolved.lease.doc, output);
            try writeBytes(evaluator, output, " '");
            try writeName(evaluator, output, resolved.trace_word);
            try writeBytes(evaluator, output, " def\n");
        },
    }
    output.flush() catch return evaluator.fail(.io, "standard output flush failed");
}

fn printAnnotation(
    evaluator: *Machine,
    effect: ?env.Effect,
    document: ?*env.DocumentationString,
    output: *std.Io.Writer,
) MachineError!void {
    if (document == null) {
        if (effect) |present| {
            try writeBytes(evaluator, output, " ");
            try printValue(evaluator, .{ .list = present.header() }, output);
        }
        return;
    }
    const effect_count: usize = if (effect) |present| @intCast(present.header().length()) else 0;
    const items = try evaluator.allocator().alloc(Value, effect_count + 2);
    defer evaluator.allocator().free(items);
    if (effect) |present| for (0..effect_count) |index| {
        try evaluator.advanceKernel(1);
        items[index] = list.atUnchecked(.{ .list = present.header() }, index);
    };
    items[effect_count] = .{ .word = try intern.intern(":") };
    items[effect_count + 1] = .{ .list = env.documentationHeader(document.?) };
    const annotation = try kernel_storage.fromValuesGeneric(
        evaluator.allocator(),
        items,
        (kernel_support.Context{ .evaluator = evaluator }).structuralPoller(),
    );
    defer heap.releaseValue(evaluator.allocator(), annotation);
    try writeBytes(evaluator, output, " ");
    try printValue(evaluator, annotation, output);
}

fn unqualifiedSymbol(
    evaluator: *Machine,
    item: Value,
    context: []const u8,
) MachineError!intern.NamespaceName {
    const name = try symbolValue(evaluator, item);
    return intern.namespaceName(
        name,
        poll.WorkContext.init((kernel_support.Context{ .evaluator = evaluator }).structuralPoller()),
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Ecl => error.Ecl,
        error.InvalidName => evaluator.failFmt(.domain, "{s} requires an unqualified, non-reserved name", .{context}),
    };
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

fn outputWriter(evaluator: *Machine) MachineError!*std.Io.Writer {
    return evaluator.unit.output orelse return evaluator.fail(.io, "standard output is unavailable");
}

fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}

fn writeName(evaluator: *Machine, output: *std.Io.Writer, name: u32) MachineError!void {
    return writeBytes(evaluator, output, intern.get(name));
}

fn writeBytes(evaluator: *Machine, output: *std.Io.Writer, bytes: []const u8) MachineError!void {
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
