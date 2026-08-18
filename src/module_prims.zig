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
/// Removal advances one owner transition per cursor step. Keep its scheduler
/// slice small enough that cancellation can run after the directory close edge
/// while a user-sized durable stack is still retiring.
const removal_poll_quantum: usize = 256;
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try definition_prims.install(core);
    const definitions = comptime [_]Definition{
        .{ .name = "module", .primitive = moduleWord },
        .{ .name = "unmodule", .primitive = unmoduleWord },
        .{ .name = "within", .primitive = withinWord },
        .{ .name = "without", .primitive = withoutWord },
        .{ .name = "use", .primitive = useModule },
        .{ .name = "alias", .primitive = aliasModule },
        .{ .name = "qualify", .primitive = qualify },
        .{ .name = "words", .primitive = words },
        .{ .name = "load", .primitive = load },
    };
    try core.installBuiltins(definitions);
}
fn moduleWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var body = try evaluator.popQuotation();
    defer body.deinit();
    const name = try evaluator.popSymbol();
    try evaluator.startDriver(ModuleStartDriver{
        .body = .init(body.take().list),
        .validation = .init(name),
    });
}
/// Removal completes the lifecycle. A canonical or alias name is resolved
/// exactly as `use` resolves it and drives the owner-issued close protocol.
fn unmoduleWord(evaluator: *Machine) MachineError!void {
    const name = try evaluator.popSymbol();
    try evaluator.startDriver(UnmoduleDriver{ .validation = .init(name) });
}

const UnmoduleDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    validation: intern.ModuleNameCursor,
    cursor: ?heap.Owned(modules.Registry.RemovalCursor) = null,
    pub fn advance(evaluator: *Machine, self: *UnmoduleDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = removal_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.cursor == null) switch (self.validation.advance()) {
                .pending => continue,
                .complete => |maybe_name| {
                    const name = maybe_name orelse return evaluator.fail(
                        .domain,
                        "unmodule requires a valid module name",
                    );
                    const registry = evaluator.unit.inherited.registry orelse
                        return evaluator.fail(.domain, "module registry is unavailable");
                    self.cursor = .init(registry.removalCursor(
                        name,
                        &evaluator.unit.turn_authority,
                    ));
                    continue;
                },
            };
            switch (self.cursor.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MissingModule => return evaluator.undefinedName(intern.moduleId(
                    self.cursor.?.borrow().requested,
                )),
                error.StateApplicationActive => return evaluator.fail(
                    .domain,
                    "a module cannot be removed from inside a state application",
                ),
            }) {
                .pending => {},
                // The close edge has transferred all remaining ownership to
                // scheduler retirement. Yield before polling cancellation
                // again so abandoning this Unit cannot abandon module state.
                .detached => return .yielded,
                .complete => return .completed,
            }
        }
        return .yielded;
    }
};

/// The explicit stack boundary: the quotation runs against a private draft
/// of the home module's durable stack rather than the ambient caller stack.
fn withinWord(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popQuotation();
    return evaluator.beginWithin(quotation.take().list);
}

/// The explicit outward boundary: one draft value joins the pending output
/// sequence, which reaches the caller only if the transaction publishes.
fn withoutWord(evaluator: *Machine) MachineError!void {
    return evaluator.moveWithout();
}

fn useModule(evaluator: *Machine) MachineError!void {
    const name = try evaluator.popSymbol();
    try evaluator.startDriver(UseNameDriver{ .validation = .init(name) });
}
fn aliasModule(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const target = try evaluator.popSymbol();
    const short = try evaluator.popSymbol();
    try evaluator.startDriver(AliasDriver{
        .short_validation = .init(short),
        .target_validation = .init(target),
    });
}

const ModuleStartDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    body: ?heap.Owned(*value.ListHandle),
    validation: intern.ModuleNameCursor,
    pub fn advance(evaluator: *Machine, self: *ModuleStartDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return evaluator.fail(
                    .domain,
                    "module requires a valid module name",
                );
                const body = self.body.?.take();
                self.body = null;
                try evaluator.moduleOwned(name, body);
                return .completed;
            },
        };
        return .yielded;
    }
};

const UseNameDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    validation: intern.ModuleNameCursor,
    pub fn advance(evaluator: *Machine, self: *UseNameDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return evaluator.fail(.domain, "use requires a valid module name");
                evaluator.detachWorkDriver(self);
                heap.destroyDriver(evaluator.releaseDomain(), evaluator.allocator(), self);
                try evaluator.useOrLoad(name);
                return .detached;
            },
        };
        return .yielded;
    }
};

const AliasDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    short_validation: intern.NamespaceCursor,
    target_validation: intern.ModuleNameCursor,
    short: ?intern.BindingName = null,
    target: ?intern.ModuleName = null,
    cursor: ?heap.Owned(modules.Registry.AliasCursor) = null,
    pub fn advance(evaluator: *Machine, self: *AliasDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.target == null) switch (self.target_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.target = name orelse return evaluator.fail(
                        .domain,
                        "alias target requires a valid module name",
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
            const registry = evaluator.unit.inherited.registry orelse
                return evaluator.fail(.domain, "module registry is unavailable");
            if (self.cursor == null) self.cursor = .init(registry.aliasCursor(self.short.?, self.target.?));
            switch (self.cursor.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NameConflict => return evaluator.fail(.domain, "alias collides with a module name"),
                error.MissingModule => return evaluator.undefinedModule(intern.moduleId(self.target.?)),
            }) {
                .pending => {},
                .complete => return .completed,
            }
        }
        return .yielded;
    }
};

fn qualify(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const binding = try evaluator.popSymbol();
    const module_name = try evaluator.popSymbol();
    try evaluator.startDriver(QualifyDriver{
        .module_validation = .init(module_name),
        .binding_validation = .init(binding),
    });
}

const QualifyDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    module_validation: intern.ModuleNameCursor,
    binding_validation: intern.NamespaceCursor,
    module_name: ?intern.ModuleName = null,
    binding_name: ?intern.BindingName = null,
    cursor: ?heap.Owned(intern.QualifiedCursor) = null,

    pub fn advance(evaluator: *Machine, self: *QualifyDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.module_name == null) switch (self.module_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.module_name = name orelse return evaluator.fail(
                        .domain,
                        "qualify requires a valid module name",
                    );
                    continue;
                },
            };
            if (self.binding_name == null) switch (self.binding_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.binding_name = name orelse return evaluator.fail(
                        .domain,
                        "qualify requires an unqualified, non-reserved binding name",
                    );
                    continue;
                },
            };
            if (self.cursor == null) self.cursor = .init(try .init(
                evaluator.allocator(),
                intern.qualifiedName(self.module_name.?, self.binding_name.?),
            ));
            switch (try self.cursor.?.borrowMut().advance()) {
                .pending => {},
                .complete => |word| return .{ .output = .{ .word = word } },
            }
        }
        return .yielded;
    }
};
fn words(evaluator: *Machine) MachineError!void {
    try evaluator.startDriver(WordsDriver.init(evaluator));
}

const WordsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    const Phase = enum { visible, materialize, unique, actions, render, write };
    allocator: std.mem.Allocator,
    visible: heap.Owned(reflection.VisibleNameCursor),
    phase: Phase = .visible,
    found: heap.Owned(poll_api.ChunkList(u32)),
    names: ?heap.Owned([]u32) = null,
    found_iterator: ?poll_api.ChunkList(u32).Iterator = null,
    materialize_index: usize = 0,
    sorter: ?heap.Owned(reflection.NameSortCursor) = null,
    scan_index: usize = 0,
    actions: heap.Owned(reflection.ActionPlan),
    action_index: usize = 0,
    previous: ?u32 = null,
    rendered: ?heap.Owned([]u8) = null,

    fn init(evaluator: *Machine) WordsDriver {
        return .{
            .allocator = evaluator.allocator(),
            .visible = .init(reflection.VisibleNameCursor.init(
                .{ .scope = evaluator.currentScope() },
                evaluator.currentEnv().coreView(),
                evaluator.unit.inherited.registry,
            )),
            .found = .init(poll_api.ChunkList(u32).init(evaluator.allocator())),
            .actions = .init(reflection.ActionPlan.init(evaluator.allocator())),
        };
    }
    fn append(self: *WordsDriver, name: u32) error{OutOfMemory}!void {
        try self.found.borrowMut().append(name);
    }
    pub fn advance(evaluator: *Machine, self: *WordsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.phase) {
            .visible => switch (self.visible.borrowMut().advance()) {
                .pending => {},
                .complete => {
                    self.names = .init(try self.allocator.alloc(u32, self.found.borrow().count));
                    self.found_iterator = self.found.borrow().iterator();
                    self.phase = .materialize;
                },
                .item => |name| try self.append(name),
            },
            .materialize => if (self.found_iterator.?.next()) |name| {
                self.names.?.borrow()[self.materialize_index] = name.*;
                self.materialize_index += 1;
            } else {
                self.sorter = .init(try .init(self.allocator, self.names.?.borrow()));
                self.phase = .unique;
            },
            .unique => if (self.sorter.?.borrowMut().advance(1) == .complete) {
                self.sorter.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.sorter = null;
                self.scan_index = 0;
                self.previous = null;
                self.phase = .actions;
            },
            .actions => {
                if (self.scan_index != self.names.?.borrow().len) {
                    const name = self.names.?.borrow()[self.scan_index];
                    self.scan_index += 1;
                    if (self.previous != null and self.previous.? == name) continue;
                    if (self.action_index != 0) {
                        try self.actions.borrowMut().add(.{ .bytes = " " });
                        self.action_index += 1;
                    }
                    try self.actions.borrowMut().add(.{ .name = name });
                    self.action_index += 1;
                    self.previous = name;
                    continue;
                }
                try self.actions.borrowMut().add(.{ .bytes = "\n" });
                self.action_index += 1;
                self.actions.borrowMut().seal();
                self.phase = .render;
            },
            .render => switch (try self.actions.borrowMut().advance(1)) {
                .pending => {},
                .complete => |bytes| {
                    self.rendered = .init(bytes);
                    self.phase = .write;
                },
            },
            .write => {
                if (evaluator.unit.inherited.console) |console| {
                    console.writeOutput(self.rendered.?.borrow(), false) catch return writeFailure(evaluator);
                    return .completed;
                }
                const output = try outputWriter(evaluator);
                output.writeAll(self.rendered.?.borrow()) catch return writeFailure(evaluator);
                output.flush() catch return evaluator.fail(.io, "standard output flush failed");
                return .completed;
            },
        };
        return .yielded;
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
    const encoder = kernel_storage.ToUtf8Cursor.init(evaluator.allocator(), path_value.borrow());
    try evaluator.startDriver(LoadPathDriver{
        .path_value = .init(path_value.take()),
        .encoder = .init(encoder),
    });
}
const LoadPathDriver = struct {
    path_value: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.ToUtf8Cursor),
    path: ?heap.Owned([]u8) = null,
    pub fn advance(evaluator: *Machine, self: *LoadPathDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.path == null) switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "path contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| self.path = .init(path),
        };
        const path = self.path.?.take();
        const path_value = self.path_value.take();
        self.path = null;
        evaluator.detachWorkDriver(self);
        heap.destroyDriver(evaluator.releaseDomain(), evaluator.allocator(), self);
        try evaluator.loadFileOwned(path, path_value);
        return .detached;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
