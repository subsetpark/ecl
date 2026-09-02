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
        .{ .name = "*file*", .primitive = fileWord },
        .{ .name = "*module*", .primitive = moduleNameWord },
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
/// Construction alone: seeds initialize the construction stack, the body
/// builds an anonymous immutable image, and the program decides later whether,
/// and under what name, to register it.
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
/// words. Name-last matches `def` and `set`.
fn defmWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
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

/// Returns the canonical registration selected by the active execution home.
/// The name belongs to the home rather than the image: one image can be
/// registered more than once, and an alias still reaches its target's
/// canonical registration. Construction and module-value invocation have no
/// registration to report.
fn moduleNameWord(evaluator: *Machine) MachineError!void {
    const home = evaluator.currentHome() orelse return evaluator.fail(
        .domain,
        "*module* is legal only in code homed in a registered module",
    );
    const name = home.name() orelse return evaluator.fail(
        .domain,
        "*module* is legal only in code homed in a registered module",
    );
    try evaluator.pushOwned(.{ .symbol = intern.moduleId(name) });
}

/// Returns the reader source that authored the active occurrence. Source names
/// are user-sized host input, so materialization remains scheduled and
/// cancellable rather than hiding a traversal in the primitive callback.
fn fileWord(evaluator: *Machine) MachineError!void {
    const source_name = evaluator.activeSourceName() orelse return evaluator.fail(
        .domain,
        "*file* is unavailable for code without source provenance",
    );
    try evaluator.startDriver(FileDriver{
        .text = .init(.init(evaluator.allocator(), source_name)),
    });
}

const FileDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    text: heap.Owned(kernel_storage.TextMaterializer),

    pub fn advance(evaluator: *Machine, self: *FileDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (try self.text.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }
};

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
    var requested = try evaluator.popList();
    errdefer requested.deinit();
    const module_id = try evaluator.popSymbol();
    const requested_count: usize = @intCast(requested.borrow().list.length());
    const prepared = try evaluator.allocator().alloc(ImportName, requested_count);
    try evaluator.startDriver(ImportDriver.init(
        evaluator,
        module_id,
        requested.take(),
        prepared,
    ));
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

const ImportName = struct {
    binding: intern.BindingName,
    qualified: u32,
};

/// Batch import validates and resolves the entire requested public surface
/// against one pinned generation before publishing the first forwarding
/// binding. A missing or private attribute therefore cannot leave a prefix of
/// the request installed in the destination scope.
const ImportDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    module_id: u32,
    requested: heap.Owned(Value),
    prepared: heap.Owned([]ImportName),
    scope: *env.Scope,
    module_validation: intern.ModuleNameCursor,
    module_name: ?intern.ModuleName = null,
    prepare_index: usize = 0,
    binding_validation: ?intern.NamespaceCursor = null,
    qualifier: ?heap.Owned(intern.QualifiedCursor) = null,
    acquisition: ?heap.Owned(modules.Registry.AcquireCursor) = null,
    generation: ?heap.Owned(modules.GenerationLease) = null,
    validation_index: usize = 0,
    resolution: ?heap.Owned(modules.ModuleResolveCursor) = null,
    validated: bool = false,
    publish_index: usize = 0,
    resolved: ?heap.Owned(env.BindingLease) = null,
    forwarding_body: ?heap.Owned(Value) = null,
    publisher: ?heap.Owned(env.Environment.BindCursor) = null,

    fn init(
        evaluator: *Machine,
        module_id: u32,
        requested: Value,
        prepared: []ImportName,
    ) ImportDriver {
        return .{
            .module_id = module_id,
            .requested = .init(requested),
            .prepared = .init(prepared),
            .scope = evaluator.currentScope(),
            .module_validation = .init(module_id),
        };
    }

    pub fn advance(evaluator: *Machine, self: *ImportDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.module_name == null) switch (self.module_validation.advance()) {
                .pending => continue,
                .complete => |maybe_name| {
                    self.module_name = maybe_name orelse return evaluator.fail(
                        .domain,
                        "import requires a valid module name",
                    );
                    continue;
                },
            };

            if (self.prepare_index != self.prepared.borrow().len) {
                const item = list.atUnchecked(self.requested.borrow(), self.prepare_index);
                if (self.binding_validation == null and self.qualifier == null) {
                    const symbol = switch (item) {
                        .symbol => |name| name,
                        else => return evaluator.typeError("a list of symbols"),
                    };
                    self.binding_validation = .init(symbol);
                }
                if (self.qualifier == null) switch (self.binding_validation.?.advance()) {
                    .pending => continue,
                    .complete => |maybe_name| {
                        const binding = maybe_name orelse return evaluator.fail(
                            .domain,
                            "import attributes must be unqualified and non-reserved symbols",
                        );
                        self.binding_validation = null;
                        self.prepared.borrowMut().*[self.prepare_index].binding = binding;
                        self.qualifier = .init(try .init(
                            evaluator.allocator(),
                            intern.qualifiedName(self.module_name.?, binding),
                        ));
                        continue;
                    },
                };
                switch (try self.qualifier.?.borrowMut().advance()) {
                    .pending => continue,
                    .complete => |qualified| {
                        self.prepared.borrowMut().*[self.prepare_index].qualified = qualified;
                        self.qualifier.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.qualifier = null;
                        self.binding_validation = null;
                        self.prepare_index += 1;
                        continue;
                    },
                }
            }

            if (self.generation == null) {
                const registry = evaluator.unit.inherited.registry orelse
                    return evaluator.fail(.domain, "module registry is unavailable");
                if (self.acquisition == null)
                    self.acquisition = .init(registry.acquireCursor(self.module_name.?));
                switch (self.acquisition.?.borrowMut().advance()) {
                    .pending => continue,
                    .complete => |maybe_generation| if (maybe_generation) |generation| {
                        self.generation = .init(generation);
                        self.acquisition.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.acquisition = null;
                        continue;
                    } else {
                        const module_id = self.module_id;
                        const module_name = self.module_name.?;
                        const requested_word = if (self.prepared.borrow().len == 0)
                            module_id
                        else
                            self.prepared.borrow()[0].qualified;
                        const requested = self.requested.take();
                        evaluator.retireDriver(self);
                        return evaluator.retryImportAfterLoad(
                            module_id,
                            requested,
                            module_name,
                            requested_word,
                        );
                    },
                }
            }

            if (self.prepared.borrow().len == 0) return .completed;

            if (!self.validated) {
                if (self.validation_index == self.prepared.borrow().len) {
                    self.validated = true;
                    continue;
                }
                const requested = self.prepared.borrow()[self.validation_index];
                if (self.resolution == null)
                    self.resolution = .init(self.generation.?.borrow().resolveCursor(
                        intern.bindingId(requested.binding),
                    ));
                switch (self.resolution.?.borrowMut().advance()) {
                    .pending => continue,
                    .complete => |maybe_lease| {
                        var lease = maybe_lease orelse
                            return evaluator.undefinedNameIn(requested.qualified, .qualified);
                        lease.deinit();
                        self.resolution.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.resolution = null;
                        self.validation_index += 1;
                        continue;
                    },
                }
            }

            if (self.publish_index == self.prepared.borrow().len) return .completed;
            const requested = self.prepared.borrow()[self.publish_index];
            if (self.resolved == null and self.publisher == null) {
                if (self.resolution == null)
                    self.resolution = .init(self.generation.?.borrow().resolveCursor(
                        intern.bindingId(requested.binding),
                    ));
                switch (self.resolution.?.borrowMut().advance()) {
                    .pending => continue,
                    .complete => |maybe_lease| {
                        self.resolved = .init(maybe_lease orelse unreachable);
                        self.resolution.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.resolution = null;
                        continue;
                    },
                }
            }
            if (self.forwarding_body == null) {
                self.forwarding_body = .init(try list.fromValuesGeneric(
                    evaluator.allocator(),
                    &.{.{ .word = .{ .name = requested.qualified } }},
                ));
                continue;
            }
            if (self.publisher == null) {
                const lease = self.resolved.?.borrow();
                const body = env.quotation(self.forwarding_body.?.borrow().list) orelse unreachable;
                // `import` inside a module body binds module-locally, the same
                // way `def` does there. Reaching for top publication on a
                // module root used to abort on an `unreachable`, which one
                // line of ordinary source could trigger.
                self.publisher = .init(try self.scope.publishWordCursor(requested.binding, .{
                    .body = body,
                    .visibility = .public,
                    .effect = lease.effect,
                    .doc = lease.doc,
                }));
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
                .complete => {
                    self.publisher.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.publisher = null;
                    self.forwarding_body.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.forwarding_body = null;
                    self.resolved.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.resolved = null;
                    self.publish_index += 1;
                },
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
                error.ReservedName => return evaluator.fail(.domain, "alias name `core` is reserved for the core qualifier"),
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
        postprocess: heap.Owned(reflection.SortedUniqueNameCursor),
        actions: struct {
            names: heap.Owned(reflection.SortedUniqueNames),
            index: usize,
        },
        render: heap.Owned(reflection.SortedUniqueNames),
        write: struct {
            names: heap.Owned(reflection.SortedUniqueNames),
            rendered: heap.Owned([]u8),
        },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .visible => |*visible| visible.deinit(releases, allocator),
                .postprocess => |*cursor| cursor.deinit(releases, allocator),
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
                    const cursor = try reflection.SortedUniqueNameCursor.init(
                        self.allocator,
                        self.found.borrowMut(),
                    );
                    visible.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .postprocess = .init(cursor) };
                },
                .item => |name| try self.append(name),
            },
            .postprocess => |*cursor| switch (try cursor.borrowMut().advance(1)) {
                .pending => {},
                .complete => |names| {
                    cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .actions = .{
                        .names = .init(names),
                        .index = 0,
                    } };
                },
            },
            .actions => |*actions| {
                const names = actions.names.borrow().items();
                if (actions.index != names.len) {
                    const name = names[actions.index];
                    if (actions.index != 0)
                        try self.actions.borrowMut().add(.{ .bytes = " " });
                    try self.actions.borrowMut().add(.{ .name = name });
                    actions.index += 1;
                    continue;
                }
                try self.actions.borrowMut().add(.{ .bytes = "\n" });
                self.actions.borrowMut().seal();
                const owned_names = actions.names.take();
                self.state.borrowMut().* = .{ .render = .init(owned_names) };
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
