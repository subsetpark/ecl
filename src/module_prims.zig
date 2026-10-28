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
/// Removal is one directory edit; the retired generation's images release
/// through the superseded directory's own bounded retirement.
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try definition_prims.install(core);
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "@defm", .primitive = defmWord, .effect = "values body module-name --", .doc = "Validate a module name, then evaluate a module body with an explicit initial stack in a fresh unit and register the result under that name." },
        .{ .name = "@defm!", .primitive = defmSeedless, .effect = "body module-name --", .doc = "Validate a module name, then evaluate a module body on an empty stack in a fresh unit and register the result under that name; `[] body name @defm`." },
        .{ .name = "undefm", .primitive = undefmWord, .effect = "module-name --", .doc = "Remove the module registered under a canonical name or alias." },
        .{ .name = "*file*", .primitive = fileWord, .effect = "-- string", .doc = "Return the source name dynamically supplied by the currently executing reader-authored occurrence." },
        .{ .name = "*module*", .primitive = moduleNameWord, .effect = "-- module-name", .doc = "Return the canonical registration name dynamically supplied by the current module activation." },
        .{ .name = "import", .primitive = importAs(.public), .effect = "module-name q --", .doc = "Import a list of public module attributes under their own names, preserving effects and documentation." },
        .{ .name = "importp", .primitive = importAs(.private), .effect = "module-name q --", .doc = "Import a list of public module attributes as private module words under their own names, preserving effects and documentation; legal only in a module root." },
        .{ .name = "alias", .primitive = aliasModule, .effect = "short name --", .doc = "Register a short alias for a qualified module name." },
        .{ .name = "qualify", .primitive = qualify, .effect = "module-name binding-name -- qualified-word", .doc = "Construct an executable qualified word without reparsing source text." },
        .{ .name = "words", .primitive = words, .effect = "--", .doc = "Print the visible dictionary in sorted order." },
        .{ .name = "load", .primitive = load, .effect = "path --", .doc = "Read and evaluate a source file as one transactional unit." },
    };
    try core.installBuiltins(&definitions);
}
/// The one module constructor. The name is validated before the body runs, so
/// a name that could never be published costs no evaluation and no effect.
/// Only a registry change during construction can still refuse publication.
fn defmWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    const name = try evaluator.popSymbol();
    try startDefm(evaluator, name, try evaluator.popUnitInput());
}

fn defmSeedless(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const name = try evaluator.popSymbol();
    try startDefm(evaluator, name, try evaluator.popSeedlessUnitInput());
}

fn startDefm(evaluator: *Machine, name: u32, popped: machine.OwnedUnitInput) MachineError!void {
    var input = popped;
    errdefer input.deinit(evaluator.releaseDomain());
    try evaluator.startDriver(DefmDriver{
        .input = .init(input.move()),
        .validation = .init(name),
    });
}

const DefmDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    input: heap.Owned(machine.OwnedUnitInput),
    validation: intern.ModuleNameCursor,

    pub fn advance(evaluator: *Machine, self: *DefmDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse
                    return evaluator.fail(.domain, "@defm requires a valid module name");
                // The registry refuses `core` too, but only at publication; a
                // name that can never publish must fail before the body runs.
                if (intern.isReservedRegistryBytes(intern.get(intern.moduleId(name))))
                    return evaluator.fail(.domain, "module name `core` is reserved for the core qualifier");
                try evaluator.refuseReservedModule(name, evaluator.unit.current.?.site.registration_provenance);
                const input = self.input.take();
                evaluator.retireDriver(self);
                try evaluator.moduleOwned(name, input);
                return .detached;
            },
        };
        return .stepped;
    }
};
/// Removal completes the lifecycle. A canonical or alias name is resolved
/// through the registry and drives the owner-issued close protocol.
fn undefmWord(evaluator: *Machine) MachineError!void {
    const name = try evaluator.popSymbol();
    try evaluator.startDriver(UndefmDriver{ .validation = .init(name) });
}

/// Returns the canonical registration selected by the active execution home.
/// The name belongs to the home rather than the image: one image can be
/// registered more than once, and an alias still reaches its target's
/// canonical registration. A construction body reports the name it is being
/// built under.
fn moduleNameWord(evaluator: *Machine) MachineError!void {
    const home = evaluator.currentHome() orelse return evaluator.fail(
        .domain,
        "*module* is legal only in code homed in a registered module",
    );
    try evaluator.pushOwned(.{ .symbol = .{ .name = intern.moduleId(home.name()) } });
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
        return switch (try self.text.borrowMut().advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

const UndefmDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    validation: intern.ModuleNameCursor,
    cursor: ?heap.Owned(modules.Registry.RemovalCursor) = null,
    pub fn advance(evaluator: *Machine, self: *UndefmDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) {
            if (self.cursor == null) switch (self.validation.advance()) {
                .pending => continue,
                .complete => |maybe_name| {
                    const name = maybe_name orelse return evaluator.fail(
                        .domain,
                        "undefm requires a valid module name",
                    );
                    try evaluator.refuseReservedModule(name, evaluator.unit.current.?.site.registration_provenance);
                    const registry = evaluator.publicationRegistry(name, evaluator.unit.current.?.site.registration_provenance);
                    self.cursor = .init(registry.removalCursor(name));
                    continue;
                },
            };
            switch (self.cursor.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MissingModule => return evaluator.undefinedNameIn(
                    intern.moduleId(self.cursor.?.borrow().request),
                    .qualified,
                ),
            }) {
                .pending => {},
                .complete => return .completed,
            }
        }
        return .stepped;
    }
};

fn importAs(comptime visibility: env.Visibility) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return importWord(evaluator, visibility);
        }
    }.run;
}

fn importWord(evaluator: *Machine, visibility: env.Visibility) MachineError!void {
    try evaluator.require(2);
    const scope = try evaluator.definitionScope();
    if (visibility == .private and scope.publisher() != .module)
        return evaluator.fail(.domain, "importp is legal only in a module root");
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
        visibility,
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
    visibility: env.Visibility,
    module_validation: intern.ModuleNameCursor,
    module_name: ?intern.ModuleName = null,
    prepare_index: usize = 0,
    binding_validation: ?intern.NamespaceCursor = null,
    qualifier: ?heap.Owned(intern.QualifiedCursor) = null,
    acquisition: ?heap.Owned(machine.ModuleLookupCursor) = null,
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
        visibility: env.Visibility,
    ) ImportDriver {
        return .{
            .module_id = module_id,
            .requested = .init(requested),
            .prepared = .init(prepared),
            .scope = evaluator.currentScope(),
            .visibility = visibility,
            .module_validation = .init(module_id),
        };
    }

    pub fn advance(evaluator: *Machine, self: *ImportDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) {
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
                        .symbol => |name| name.name,
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
                if (self.acquisition == null)
                    self.acquisition = .init(machine.ModuleLookupCursor.atCurrent(evaluator, self.module_name.?));
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
                // The forwarding word is written into the importing root.
                const linker = try evaluator.rootLinker(self.scope);
                self.forwarding_body = .init(try list.fromValuesGeneric(
                    evaluator.allocator(),
                    &.{.{ .symbol = .{ .name = requested.qualified, .slot = try linker.link(requested.qualified) } }},
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
                    .visibility = self.visibility,
                    .effect = lease.spec().effect,
                    .doc = lease.spec().doc,
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
        return .stepped;
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
        const work = evaluator.workBudget();
        while (work.spend()) {
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
            if (self.cursor == null) {
                // An alias of an embedded module could remove it, and an
                // alias under an embedded name would claim one.
                const provenance = evaluator.unit.current.?.site.registration_provenance;
                try evaluator.refuseReservedModule(self.target.?, provenance);
                if (intern.moduleName(intern.bindingId(self.short.?)) catch null) |short|
                    try evaluator.refuseReservedModule(short, provenance);
                const registry = evaluator.publicationRegistry(self.target.?, evaluator.unit.current.?.site.registration_provenance);
                self.cursor = .init(registry.aliasCursor(self.short.?, self.target.?));
            }
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
        return .stepped;
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
        const work = evaluator.workBudget();
        while (work.spend()) {
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
                .complete => |word| return .{ .output = .{ .symbol = try evaluator.linkedWord(word) } },
            }
        }
        return .stepped;
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
                evaluator.unit.bindingPin(),
            )) }),
        };
    }
    fn append(self: *WordsDriver, name: u32) error{OutOfMemory}!void {
        try self.found.borrowMut().append(name);
    }
    pub fn advance(evaluator: *Machine, self: *WordsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.state.borrowMut().*) {
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
            .postprocess => |*cursor| switch (try cursor.borrowMut().advance(work)) {
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
            .render => |*names| switch (try self.actions.borrowMut().advance(work)) {
                .pending => {},
                .complete => |bytes| {
                    self.state.borrowMut().* = .{ .write = .{
                        .names = .init(names.take()),
                        .rendered = .init(bytes),
                    } };
                },
            },
            .write => |*write| {
                evaluator.unit.inherited.runtime().console.writeOutput(write.rendered.borrow(), false) catch return writeFailure(evaluator);
                return .completed;
            },
        };
        return .stepped;
    }
};
fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}
fn load(evaluator: *Machine) MachineError!void {
    var path_value = try evaluator.popValue();
    defer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string path");
    const encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), path_value.borrow());
    try evaluator.startDriver(LoadPathDriver{
        .path_value = .init(path_value.take()),
        .encoder = .init(encoder),
    });
}
const LoadPathDriver = machine.PathActionDriver(Machine.loadFileOwned);
