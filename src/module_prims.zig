//! Module, environment, reflection, and source-transport primitives.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
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
        .{ .name = "@module", .primitive = moduleWord },
        .{ .name = "register", .primitive = registerWord },
        .{ .name = "@defm", .primitive = defmWord },
        .{ .name = "unmodule", .primitive = unmoduleWord },
        .{ .name = "within", .primitive = withinWord },
        .{ .name = "without", .primitive = withoutWord },
        .{ .name = "import", .primitive = importWord },
        .{ .name = "alias", .primitive = aliasModule },
        .{ .name = "qualify", .primitive = qualify },
        .{ .name = "invoke", .primitive = invoke },
        .{ .name = "words", .primitive = words },
        .{ .name = "load", .primitive = load },
    };
    try core.installBuiltins(definitions);
}
/// Construction alone: the body builds an anonymous immutable image and the
/// program decides later whether, and under what name, to register it.
fn moduleWord(evaluator: *Machine) MachineError!void {
    var body = try evaluator.popQuotation();
    defer body.deinit();
    return evaluator.moduleOwned(null, body.take().list);
}
/// Publication alone: name an already-constructed image. A missing name
/// creates its registration; an existing one installs this image over the
/// state that registration already owns.
fn registerWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const name = try evaluator.popSymbol();
    var item = try evaluator.popValue();
    errdefer item.deinit();
    if (item.borrow() != .module) return evaluator.typeError("a module");
    try evaluator.startDriver(RegisterDriver{
        .module = .init(item.take()),
        .validation = .init(name),
    });
}
/// The source-module spelling: construction followed immediately by
/// registration, with the same all-or-nothing outcome as writing the two
/// words. Name-last, matching `def` and `set`, so a `with`-seeded definition
/// needs no shuffle above the binder.
fn defmWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const name = try evaluator.popSymbol();
    var body = try evaluator.popQuotation();
    defer body.deinit();
    // The name is carried unvalidated into the construction boundary. The
    // composition this word stands for evaluates the body first, so checking
    // the name here would skip a body `@module` plus `register` would run.
    return evaluator.moduleOwned(name, body.take().list);
}
/// Removal completes the lifecycle. A canonical or alias name is resolved
/// through the registry and drives the owner-issued close protocol.
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

fn importWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const binding = try evaluator.popSymbol();
    const original = try evaluator.popSymbol();
    try evaluator.startDriver(ImportDriver.init(evaluator, original, binding));
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

/// Validates the requested canonical name before any registry mutation, then
/// hands the retained module value to the publication driver.
const RegisterDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    module: ?heap.Owned(Value),
    validation: intern.ModuleNameCursor,
    pub fn advance(evaluator: *Machine, self: *RegisterDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return evaluator.fail(
                    .domain,
                    "register requires a valid module name",
                );
                const item = self.module.?.take();
                self.module = null;
                evaluator.retireDriver(self);
                try evaluator.registerModuleOwned(item, name);
                return .detached;
            },
        };
        return .yielded;
    }
};

const ImportDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    original: u32,
    binding_id: u32,
    scope: *env.Scope,
    binding_validation: intern.NamespaceCursor,
    dot: intern.LastDotCursor,
    binding: ?intern.BindingName = null,
    qualified: bool = false,
    resolution: ?heap.Owned(machine.ResolutionCursor) = null,
    resolved: ?heap.Owned(machine.Resolution) = null,
    forwarding_body: ?heap.Owned(Value) = null,
    publisher: ?heap.Owned(env.Environment.BindCursor) = null,

    fn init(evaluator: *Machine, original: u32, binding: u32) ImportDriver {
        return .{
            .original = original,
            .binding_id = binding,
            .scope = evaluator.currentScope(),
            .binding_validation = .init(binding),
            .dot = intern.lastDotCursor(intern.get(original)),
        };
    }

    pub fn advance(evaluator: *Machine, self: *ImportDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.binding == null) switch (self.binding_validation.advance()) {
                .pending => continue,
                .complete => |maybe_name| {
                    self.binding = maybe_name orelse return evaluator.fail(
                        .domain,
                        "import binding must be unqualified and non-reserved",
                    );
                    continue;
                },
            };
            if (!self.qualified) switch (self.dot.advance()) {
                .pending => continue,
                .complete => |maybe_index| {
                    const index = maybe_index orelse return evaluator.fail(
                        .domain,
                        "import original must be a qualified word",
                    );
                    const bytes = intern.get(self.original);
                    if (index == 0 or index + 1 == bytes.len)
                        return evaluator.fail(.domain, "import original must be a qualified word");
                    self.qualified = true;
                    self.resolution = .init(machine.ResolutionCursor.init(evaluator, self.original));
                    continue;
                },
            };
            if (self.resolved == null and self.publisher == null) switch (self.resolution.?.borrowMut().advance()) {
                .pending => continue,
                .complete => |outcome| switch (outcome) {
                    .resolved => |resolved| {
                        self.resolved = .init(resolved);
                        self.resolution.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.resolution = null;
                        continue;
                    },
                    .unresolved => return evaluator.undefinedName(self.original),
                    .unknown_module_prefix, .unregistered_module => {
                        const binding = self.binding_id;
                        const original = self.original;
                        evaluator.retireDriver(self);
                        return evaluator.retryImportAfterLoad(binding, original, outcome);
                    },
                },
            };
            if (self.forwarding_body == null) {
                self.forwarding_body = .init(try list.fromValuesGeneric(
                    evaluator.allocator(),
                    &.{.{ .word = self.original }},
                ));
                continue;
            }
            if (self.publisher == null) {
                const lease = &self.resolved.?.borrow().lease;
                const body = env.quotation(self.forwarding_body.?.borrow().list) orelse unreachable;
                // `import` inside a module body binds module-locally, the same
                // way `def` does there. Reaching for top publication on a
                // module root used to abort on an `unreachable`, which one
                // line of ordinary source could trigger.
                self.publisher = .init(switch (self.scope.publisher()) {
                    .module => |module| try module.cursor(self.binding.?, .{ .word = .{
                        .body = body,
                        .visibility = .public,
                        .effect = lease.effect,
                        .doc = lease.doc,
                    } }),
                    .top => |top| try top.cursor(self.binding.?, .{ .word = .{
                        .body = body,
                        .effect = lease.effect,
                        .doc = lease.doc,
                    } }),
                });
                self.resolved.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.resolved = null;
                continue;
            }
            switch (self.publisher.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => return evaluator.fail(
                    .domain,
                    "module environments are immutable after registration",
                ),
            }) {
                .pending => {},
                .complete => return .completed,
            }
        }
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

/// Calls one public export of a module value. A handle carries no name, so
/// there is nothing to `qualify` and nothing for the symbol-keyed observation
/// words to look up; this is the one operation a nameless module supports.
fn invoke(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const binding = try evaluator.popSymbol();
    var item = try evaluator.popValue();
    errdefer item.deinit();
    if (item.borrow() != .module) return evaluator.typeError("a module");
    try evaluator.startDriver(InvokeDriver{
        .module = .init(item.take()),
        .validation = .init(binding),
    });
}

/// The binding name is validated before the image is consulted, so an
/// unqualifiable spelling fails the same way it does everywhere else rather
/// than reporting a missing export.
const InvokeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    module: heap.Owned(value.Value),
    validation: intern.NamespaceCursor,

    pub fn advance(evaluator: *Machine, self: *InvokeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return evaluator.fail(
                    .domain,
                    "invoke requires an unqualified binding name",
                );
                const module = self.module.take();
                evaluator.retireDriver(self);
                try evaluator.invokeModuleOwned(module, name);
                return .detached;
            },
        };
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
const LoadPathDriver = machine.PathActionDriver(Machine.loadFileOwned);
