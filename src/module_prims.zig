//! Module, environment, reflection, and source-transport primitives.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const modules = @import("modules.zig");
const definition_prims = @import("definition_prims.zig");
const poll_api = @import("poll.zig");
const reflection = @import("reflection.zig");
const kernel_storage = @import("kernel_storage.zig");
const resolution_core = @import("resolution_core.zig");
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
    errdefer heap.decRef(evaluator.allocator(), body);
    const name = try symbolValue(evaluator, try evaluator.popOwned());
    const driver = try evaluator.allocator().create(ModuleStartDriver);
    driver.* = .{ .body = body, .validation = .init(name) };
    evaluator.installWorkDriver(driver, ModuleStartDriver.advance, ModuleStartDriver.destroy);
}
fn useModule(evaluator: *Machine) MachineError!void {
    const name = try symbolValue(evaluator, try evaluator.popOwned());
    const driver = try evaluator.allocator().create(UseNameDriver);
    driver.* = .{ .name = name, .dot = intern.dotCursor(intern.get(name)) };
    evaluator.installWorkDriver(driver, UseNameDriver.advance, UseNameDriver.destroy);
}
fn aliasModule(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const target = try symbolValue(evaluator, try evaluator.popOwned());
    const short = try symbolValue(evaluator, try evaluator.popOwned());
    const driver = try evaluator.allocator().create(AliasDriver);
    driver.* = .{
        .short_validation = .init(short),
        .target_validation = .init(target),
    };
    evaluator.installWorkDriver(driver, AliasDriver.advance, AliasDriver.destroy);
}

const ModuleStartDriver = struct {
    body: ?*value.Header,
    validation: intern.NamespaceCursor,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *ModuleStartDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return evaluator.fail(
                    .domain,
                    "module requires an unqualified, non-reserved name",
                );
                const body = self.body.?;
                self.body = null;
                try evaluator.moduleOwned(name, body);
                return .completed;
            },
        };
        return .yielded;
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *ModuleStartDriver = @ptrCast(@alignCast(raw));
        if (self.body) |body| heap.decRef(allocator, body);
        allocator.destroy(self);
    }
};

const UseNameDriver = struct {
    name: u32,
    dot: intern.DotCursor,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *UseNameDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.dot.advance()) {
            .pending => {},
            .complete => |dot| {
                if (dot != null) return evaluator.fail(.domain, "use requires an unqualified name");
                const name = self.name;
                evaluator.unit.work_driver = null;
                evaluator.allocator().destroy(self);
                try evaluator.useOrLoad(name);
                return .detached;
            },
        };
        return .yielded;
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        allocator.destroy(@as(*UseNameDriver, @ptrCast(@alignCast(raw))));
    }
};

const AliasDriver = struct {
    short_validation: intern.NamespaceCursor,
    target_validation: intern.NamespaceCursor,
    short: ?intern.NamespaceName = null,
    target: ?intern.NamespaceName = null,
    cursor: ?modules.Registry.AliasCursor = null,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *AliasDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.target == null) switch (self.target_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.target = name orelse return evaluator.fail(
                        .domain,
                        "alias target requires an unqualified, non-reserved name",
                    );
                    continue;
                },
            };
            if (self.short == null) switch (self.short_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.short = name orelse return evaluator.fail(
                        .domain,
                        "alias name requires an unqualified, non-reserved name",
                    );
                    continue;
                },
            };
            const registry = evaluator.unit.registry orelse
                return evaluator.fail(.domain, "module registry is unavailable");
            if (self.cursor == null) self.cursor = registry.aliasCursor(self.short.?, self.target.?);
            switch (self.cursor.?.advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => unreachable,
                error.NameConflict => return evaluator.fail(.domain, "alias collides with a module name"),
                error.MissingModule => return evaluator.undefinedModule(intern.namespaceId(self.target.?)),
                error.InvalidDefinition => return evaluator.fail(.domain, "module and alias names must be unqualified"),
            }) {
                .pending => {},
                .complete => return .completed,
            }
        }
        return .yielded;
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *AliasDriver = @ptrCast(@alignCast(raw));
        if (self.cursor) |*cursor| cursor.deinit();
        allocator.destroy(self);
    }
};
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
    const driver = try evaluator.allocator().create(WordsDriver);
    driver.* = .init(evaluator);
    evaluator.installWorkDriver(driver, WordsDriver.advance, WordsDriver.destroy);
}

const WordsDriver = struct {
    const Phase = enum { scopes, direct, uses, acquire, exports, core, materialize, unique, actions, render, write };
    allocator: std.mem.Allocator,
    scope: ?*env.Scope,
    phase: Phase = .scopes,
    found: poll_api.ChunkList(u32),
    direct: ?env.NameCursor = null,
    use_shape: ?env.ShapeLease = null,
    use_ordinal: usize = 0,
    acquisition: ?modules.Registry.AcquireCursor = null,
    generation: ?modules.GenerationLease = null,
    exports: ?modules.ModuleGeneration.PublicNameCursor = null,
    names: ?[]u32 = null,
    found_iterator: ?poll_api.ChunkList(u32).Iterator = null,
    materialize_index: usize = 0,
    sorter: ?reflection.NameSortCursor = null,
    unique_count: usize = 0,
    scan_index: usize = 0,
    actions: ?[]reflection.Action = null,
    action_index: usize = 0,
    previous: ?u32 = null,
    plan: ?reflection.OwnedPlanCursor = null,
    rendered: ?[]u8 = null,

    fn init(evaluator: *Machine) WordsDriver {
        return .{
            .allocator = evaluator.allocator(),
            .scope = evaluator.currentScope(),
            .found = .init(evaluator.allocator()),
        };
    }
    fn append(self: *WordsDriver, name: u32) error{OutOfMemory}!void {
        try self.found.append(name);
    }
    fn nextScope(self: *WordsDriver, evaluator: *Machine) void {
        const current = self.scope orelse {
            self.direct = evaluator.currentEnv().core.nameCursor();
            self.phase = .core;
            return;
        };
        self.scope = current.parent;
        if (current.environmentOrNull()) |environment| {
            self.direct = environment.nameCursor();
            self.phase = .direct;
        }
    }
    fn beginUses(self: *WordsDriver, evaluator: *Machine) void {
        const current = self.direct.?.shape.environment;
        self.direct.?.deinit();
        self.direct = null;
        if (evaluator.unit.registry == null) {
            self.phase = .scopes;
            return;
        }
        self.use_shape = current.acquireShape();
        self.use_ordinal = 0;
        self.phase = .uses;
    }
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *WordsDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.phase) {
            .scopes => self.nextScope(evaluator),
            .direct => switch (self.direct.?.advance()) {
                .pending => {},
                .complete => self.beginUses(evaluator),
                .entry => |entry| {
                    var lease = entry.lease;
                    defer lease.deinit(self.allocator);
                    try self.append(entry.name);
                },
            },
            .uses => {
                const uses = self.use_shape.?.useOrder();
                const index = resolution_core.usedIndex(uses.len, self.use_ordinal) orelse {
                    self.use_shape.?.deinit();
                    self.use_shape = null;
                    self.phase = .scopes;
                    continue;
                };
                self.use_ordinal += 1;
                self.acquisition = evaluator.unit.registry.?.acquireCursor(uses[index]);
                self.phase = .acquire;
            },
            .acquire => switch (self.acquisition.?.advance()) {
                .pending => {},
                .complete => |maybe_generation| {
                    self.acquisition.?.deinit();
                    self.acquisition = null;
                    self.generation = maybe_generation;
                    if (self.generation) |lease| {
                        self.exports = lease.generation.publicNameCursor();
                        self.phase = .exports;
                    } else self.phase = .uses;
                },
            },
            .exports => switch (self.exports.?.advance()) {
                .pending => {},
                .complete => {
                    self.exports.?.deinit();
                    self.exports = null;
                    self.generation.?.deinit();
                    self.generation = null;
                    self.phase = .uses;
                },
                .name => |name| try self.append(name),
            },
            .core => switch (self.direct.?.advance()) {
                .pending => {},
                .complete => {
                    self.direct.?.deinit();
                    self.direct = null;
                    self.names = try self.allocator.alloc(u32, self.found.count);
                    self.found_iterator = self.found.iterator();
                    self.phase = .materialize;
                },
                .entry => |entry| {
                    var lease = entry.lease;
                    defer lease.deinit(self.allocator);
                    try self.append(entry.name);
                },
            },
            .materialize => if (self.found_iterator.?.next()) |name| {
                self.names.?[self.materialize_index] = name.*;
                self.materialize_index += 1;
            } else {
                self.sorter = try .init(self.allocator, self.names.?);
                self.phase = .unique;
            },
            .unique => if (self.sorter.?.advance(1) == .complete) {
                self.sorter.?.deinit();
                self.sorter = null;
                self.scan_index = 0;
                self.previous = null;
                self.unique_count = 0;
                self.phase = .actions;
            },
            .actions => {
                if (self.actions == null) {
                    if (self.scan_index != self.names.?.len) {
                        const name = self.names.?[self.scan_index];
                        self.scan_index += 1;
                        if (self.previous == null or self.previous.? != name) self.unique_count += 1;
                        self.previous = name;
                        continue;
                    }
                    self.actions = try self.allocator.alloc(reflection.Action, @max(self.unique_count * 2, 1));
                    self.scan_index = 0;
                    self.previous = null;
                    continue;
                }
                if (self.scan_index != self.names.?.len) {
                    const name = self.names.?[self.scan_index];
                    self.scan_index += 1;
                    if (self.previous != null and self.previous.? == name) continue;
                    if (self.action_index != 0) {
                        self.actions.?[self.action_index] = .{ .bytes = " " };
                        self.action_index += 1;
                    }
                    self.actions.?[self.action_index] = .{ .name = name };
                    self.action_index += 1;
                    self.previous = name;
                    continue;
                }
                self.actions.?[self.action_index] = .{ .bytes = "\n" };
                self.action_index += 1;
                std.debug.assert(self.action_index == self.actions.?.len);
                self.plan = .init(self.allocator, self.actions.?);
                self.phase = .render;
            },
            .render => switch (try self.plan.?.advance(1)) {
                .pending => {},
                .complete => |bytes| {
                    self.rendered = bytes;
                    self.phase = .write;
                },
            },
            .write => {
                var locked = if (evaluator.unit.console) |console| console.lockOutput() else null;
                defer if (locked) |*lease| lease.deinit();
                const output = if (locked) |*lease| lease.writer else try outputWriter(evaluator);
                output.writeAll(self.rendered.?) catch return writeFailure(evaluator);
                output.flush() catch return evaluator.fail(.io, "standard output flush failed");
                return .completed;
            },
        };
        return .yielded;
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *WordsDriver = @ptrCast(@alignCast(raw));
        if (self.direct) |*cursor| cursor.deinit();
        if (self.use_shape) |*shape| shape.deinit();
        if (self.acquisition) |*cursor| cursor.deinit();
        if (self.exports) |*cursor| cursor.deinit();
        if (self.generation) |*lease| lease.deinit();
        if (self.sorter) |*sorter| sorter.deinit();
        if (self.plan) |*plan| plan.deinit();
        if (self.rendered) |rendered| allocator.free(rendered);
        if (self.actions) |actions| allocator.free(actions);
        if (self.names) |names| allocator.free(names);
        self.found.deinit();
        allocator.destroy(self);
    }
};
fn outputWriter(evaluator: *Machine) MachineError!*std.Io.Writer {
    return evaluator.unit.output orelse return evaluator.fail(.io, "standard output is unavailable");
}
fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}
fn load(evaluator: *Machine) MachineError!void {
    const path_value = try evaluator.popOwned();
    if (!path_value.isString()) {
        heap.releaseValue(evaluator.allocator(), path_value);
        return evaluator.typeError("a string path");
    }
    const driver = try evaluator.allocator().create(LoadPathDriver);
    driver.* = .{ .path_value = path_value, .encoder = .init(evaluator.allocator(), path_value) };
    evaluator.installWorkDriver(driver, LoadPathDriver.advance, LoadPathDriver.destroy);
}
const LoadPathDriver = struct {
    path_value: ?Value,
    encoder: kernel_storage.ToUtf8Cursor,
    path: ?[]u8 = null,
    fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!machine.WorkProgress {
        const self: *LoadPathDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        if (self.path == null) switch (self.encoder.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "path contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| self.path = path,
        };
        const path = self.path.?;
        const path_value = self.path_value.?;
        self.path = null;
        self.path_value = null;
        evaluator.unit.work_driver = null;
        LoadPathDriver.destroy(evaluator.allocator(), self);
        evaluator.loadFileOwned(path, path_value) catch |err| {
            evaluator.allocator().free(path);
            heap.releaseValue(evaluator.allocator(), path_value);
            return err;
        };
        return .detached;
    }
    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *LoadPathDriver = @ptrCast(@alignCast(raw));
        if (self.path) |path| allocator.free(path);
        self.encoder.deinit();
        if (self.path_value) |path_value| heap.releaseValue(allocator, path_value);
        allocator.destroy(self);
    }
};
fn quotationHeader(evaluator: *Machine, item: Value) MachineError!*value.Header {
    return switch (item) {
        .list => |header| header,
        else => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a quotation/list");
        },
    };
}
