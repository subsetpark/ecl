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
    var input = try evaluator.popUnitInput();
    defer input.deinit(evaluator.releaseDomain());
    return evaluator.moduleOwned(null, input.move());
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
/// words. Name-last, matching `def` and `set`, so a seeded definition needs no
/// shuffle above the binder.
fn defmWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const name = try evaluator.popSymbol();
    var input = try evaluator.popUnitInput();
    defer input.deinit(evaluator.releaseDomain());
    // The name is carried unvalidated into the construction boundary. The
    // composition this word stands for evaluates the body first, so checking
    // the name here would skip a body `@module` plus `register` would run.
    return evaluator.moduleOwned(name, input.move());
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
                error.MissingModule => return evaluator.undefinedNameIn(
                    intern.moduleId(self.cursor.?.borrow().requested),
                    .qualified,
                ),
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
                    self.resolution = .init(machine.ResolutionCursor.initAtCurrent(evaluator, self.original));
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
                    .unresolved => |chain| return evaluator.undefinedNameIn(self.original, chain),
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
                    &.{.{ .word = .{ .name = self.original } }},
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
                self.publisher = .init(try self.scope.publishWordCursor(self.binding.?, .{
                    .body = body,
                    .visibility = .public,
                    .effect = lease.effect,
                    .doc = lease.doc,
                }));
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
/// The image is taken here, where the value has to be inspected anyway, so
/// nothing downstream re-checks the type.
fn invoke(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const binding = try evaluator.popSymbol();
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const image = modules.imageRef(item.borrow()) orelse return evaluator.typeError("a module");
    return evaluator.invokeModuleOwned(item.take(), image, binding);
}

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
                .complete => |word| return .{ .output = .{ .word = .{ .name = word } } },
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
    allocator: std.mem.Allocator,
    found: heap.Owned(poll_api.ChunkList(u32)),
    actions: heap.Owned(reflection.ActionPlan),
    state: heap.Owned(State),

    const State = union(enum) {
        visible: heap.Owned(reflection.VisibleNameCursor),
        materialize: struct {
            names: heap.Owned([]u32),
            iterator: poll_api.ChunkList(u32).Iterator,
            index: usize,
        },
        unique: struct {
            names: heap.Owned([]u32),
            sorter: heap.Owned(reflection.NameSortCursor),
        },
        actions: struct {
            names: heap.Owned([]u32),
            scan_index: usize,
            action_index: usize,
            previous: ?u32,
        },
        render: heap.Owned([]u32),
        write: struct {
            names: heap.Owned([]u32),
            rendered: heap.Owned([]u8),
        },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .visible => |*visible| visible.deinit(releases, allocator),
                .materialize => |*materialize| materialize.names.deinit(releases, allocator),
                .unique => |*unique| {
                    unique.sorter.deinit(releases, allocator);
                    unique.names.deinit(releases, allocator);
                },
                .actions => |*actions| actions.names.deinit(releases, allocator),
                .render => |*names| names.deinit(releases, allocator),
                .write => |*write| {
                    write.rendered.deinit(releases, allocator);
                    write.names.deinit(releases, allocator);
                },
            }
        }
    };

    fn init(evaluator: *Machine) WordsDriver {
        return .{
            .allocator = evaluator.allocator(),
            .found = .init(poll_api.ChunkList(u32).init(evaluator.allocator())),
            .actions = .init(reflection.ActionPlan.init(evaluator.allocator())),
            .state = .init(.{ .visible = .init(reflection.VisibleNameCursor.init(
                .{ .scope = evaluator.currentScope() },
                evaluator.currentEnv().coreView(),
            )) }),
        };
    }
    fn append(self: *WordsDriver, name: u32) error{OutOfMemory}!void {
        try self.found.borrowMut().append(name);
    }
    pub fn advance(evaluator: *Machine, self: *WordsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.state.borrowMut().*) {
            .visible => |*visible| switch (visible.borrowMut().advance()) {
                .pending => {},
                .complete => {
                    const names = try self.allocator.alloc(u32, self.found.borrow().count);
                    const iterator = self.found.borrow().iterator();
                    visible.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .materialize = .{
                        .names = .init(names),
                        .iterator = iterator,
                        .index = 0,
                    } };
                },
                .item => |name| try self.append(name),
            },
            .materialize => |*materialize| if (materialize.iterator.next()) |name| {
                materialize.names.borrow()[materialize.index] = name.*;
                materialize.index += 1;
            } else {
                const sorter = try reflection.NameSortCursor.init(
                    self.allocator,
                    materialize.names.borrow(),
                );
                self.state.borrowMut().* = .{ .unique = .{
                    .names = .init(materialize.names.take()),
                    .sorter = .init(sorter),
                } };
            },
            .unique => |*unique| if (unique.sorter.borrowMut().advance(1) == .complete) {
                unique.sorter.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state.borrowMut().* = .{ .actions = .{
                    .names = .init(unique.names.take()),
                    .scan_index = 0,
                    .action_index = 0,
                    .previous = null,
                } };
            },
            .actions => |*actions| {
                if (actions.scan_index != actions.names.borrow().len) {
                    const name = actions.names.borrow()[actions.scan_index];
                    actions.scan_index += 1;
                    if (actions.previous != null and actions.previous.? == name) continue;
                    if (actions.action_index != 0) {
                        try self.actions.borrowMut().add(.{ .bytes = " " });
                        actions.action_index += 1;
                    }
                    try self.actions.borrowMut().add(.{ .name = name });
                    actions.action_index += 1;
                    actions.previous = name;
                    continue;
                }
                try self.actions.borrowMut().add(.{ .bytes = "\n" });
                self.actions.borrowMut().seal();
                self.state.borrowMut().* = .{ .render = .init(actions.names.take()) };
            },
            .render => |*names| switch (try self.actions.borrowMut().advance(1)) {
                .pending => {},
                .complete => |bytes| {
                    self.state.borrowMut().* = .{ .write = .{
                        .names = .init(names.take()),
                        .rendered = .init(bytes),
                    } };
                },
            },
            .write => |*write| {
                if (evaluator.unit.inherited.console) |console| {
                    console.writeOutput(write.rendered.borrow(), false) catch return writeFailure(evaluator);
                    return .completed;
                }
                const output = try outputWriter(evaluator);
                output.writeAll(write.rendered.borrow()) catch return writeFailure(evaluator);
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
