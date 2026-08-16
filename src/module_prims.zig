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
    var body = try evaluator.popValue();
    defer body.deinit();
    if (body.borrow() != .list) return evaluator.typeError("a quotation/list");
    const name = try popSymbol(evaluator);
    const driver = try evaluator.allocator().create(ModuleStartDriver);
    driver.* = .{ .body = body.take().list, .validation = .init(name) };
    evaluator.installWorkDriver(driver);
}
fn useModule(evaluator: *Machine) MachineError!void {
    const name = try popSymbol(evaluator);
    const driver = try evaluator.allocator().create(UseNameDriver);
    driver.* = .{ .name = name, .dot = intern.dotCursor(intern.get(name)) };
    evaluator.installWorkDriver(driver);
}
fn aliasModule(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const target = try popSymbol(evaluator);
    const short = try popSymbol(evaluator);
    const driver = try evaluator.allocator().create(AliasDriver);
    driver.* = .{
        .short_validation = .init(short),
        .target_validation = .init(target),
    };
    evaluator.installWorkDriver(driver);
}

const ModuleStartDriver = struct {
    body: ?*value.ListHandle,
    validation: intern.NamespaceCursor,
    pub fn advance(evaluator: *Machine, self: *ModuleStartDriver) MachineError!machine.WorkProgress {
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
    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *ModuleStartDriver) void {
        if (self.body) |body| releases.releaseHeader(body);
        allocator.destroy(self);
    }
};

const UseNameDriver = struct {
    name: u32,
    dot: intern.DotCursor,
    pub fn advance(evaluator: *Machine, self: *UseNameDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.dot.advance()) {
            .pending => {},
            .complete => |dot| {
                if (dot != null) return evaluator.fail(.domain, "use requires an unqualified name");
                const name = self.name;
                evaluator.detachWorkDriver(self);
                evaluator.allocator().destroy(self);
                try evaluator.useOrLoad(name);
                return .detached;
            },
        };
        return .yielded;
    }
    pub fn destroy(_: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *UseNameDriver) void {
        allocator.destroy(self);
    }
};

const AliasDriver = struct {
    short_validation: intern.NamespaceCursor,
    target_validation: intern.NamespaceCursor,
    short: ?intern.NamespaceName = null,
    target: ?intern.NamespaceName = null,
    cursor: ?modules.Registry.AliasCursor = null,
    pub fn advance(evaluator: *Machine, self: *AliasDriver) MachineError!machine.WorkProgress {
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
    pub fn destroy(_: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *AliasDriver) void {
        if (self.cursor) |*cursor| cursor.deinit();
        allocator.destroy(self);
    }
};
fn popSymbol(evaluator: *Machine) MachineError!u32 {
    var item = try evaluator.popValue();
    defer item.deinit();
    return switch (item.borrow()) {
        .symbol => |id| id,
        else => evaluator.typeError("a symbol name"),
    };
}
fn words(evaluator: *Machine) MachineError!void {
    const driver = try evaluator.allocator().create(WordsDriver);
    driver.* = .init(evaluator);
    evaluator.installWorkDriver(driver);
}

const WordsDriver = struct {
    const Phase = enum { visible, materialize, unique, actions, render, write };
    allocator: std.mem.Allocator,
    visible: reflection.VisibleNameCursor,
    phase: Phase = .visible,
    found: poll_api.ChunkList(u32),
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
            .visible = .init(
                .{ .scope = evaluator.currentScope() },
                evaluator.currentEnv().coreView(),
                evaluator.unit.registry,
            ),
            .found = .init(evaluator.allocator()),
        };
    }
    fn append(self: *WordsDriver, name: u32) error{OutOfMemory}!void {
        try self.found.append(name);
    }
    pub fn advance(evaluator: *Machine, self: *WordsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.phase) {
            .visible => switch (self.visible.advance()) {
                .pending => {},
                .complete => {
                    self.names = try self.allocator.alloc(u32, self.found.count);
                    self.found_iterator = self.found.iterator();
                    self.phase = .materialize;
                },
                .name => |name| try self.append(name),
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
                if (evaluator.unit.console) |console| {
                    console.writeOutput(self.rendered.?, false) catch return writeFailure(evaluator);
                    return .completed;
                }
                const output = try outputWriter(evaluator);
                output.writeAll(self.rendered.?) catch return writeFailure(evaluator);
                output.flush() catch return evaluator.fail(.io, "standard output flush failed");
                return .completed;
            },
        };
        return .yielded;
    }
    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *WordsDriver) void {
        self.visible.deinit();
        if (self.sorter) |*sorter| sorter.deinit();
        if (self.plan) |*plan| plan.deinit();
        if (self.rendered) |rendered| allocator.free(rendered);
        if (self.actions) |actions| allocator.free(actions);
        if (self.names) |names| allocator.free(names);
        self.found.retire(releases);
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
    var path_value = try evaluator.popValue();
    defer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string path");
    const driver = try evaluator.allocator().create(LoadPathDriver);
    driver.* = .{
        .path_value = path_value.borrow(),
        .encoder = .init(evaluator.allocator(), path_value.borrow()),
    };
    _ = path_value.take();
    evaluator.installWorkDriver(driver);
}
const LoadPathDriver = struct {
    path_value: ?Value,
    encoder: kernel_storage.ToUtf8Cursor,
    path: ?[]u8 = null,
    pub fn advance(evaluator: *Machine, self: *LoadPathDriver) MachineError!machine.WorkProgress {
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
        evaluator.detachWorkDriver(self);
        LoadPathDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
        evaluator.loadFileOwned(path, path_value) catch |err| {
            evaluator.allocator().free(path);
            evaluator.releaseDomain().releaseValue(path_value);
            return err;
        };
        return .detached;
    }
    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *LoadPathDriver) void {
        if (self.path) |path| allocator.free(path);
        self.encoder.deinit();
        if (self.path_value) |path_value| releases.releaseValue(path_value);
        allocator.destroy(self);
    }
};
