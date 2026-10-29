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
const stdlib = @import("stdlib.zig");
const kernel_storage = @import("kernel_storage.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
/// Removal is one directory edit; the retired generation's images release
/// through the superseded directory's own bounded retirement.
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try definition_prims.install(core);
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "@defm", .primitive = defmWord, .effect = "values body module-name --", .doc = "*Unit constructor.* The one module constructor. Validate the name first: a non-symbol is `` `type ``; an invalid module path, the reserved name `core`, or a standard-library module name is `` `domain ``, and the body never runs. Then run the body on a fresh environment and publish the resulting image under the name. A body failure publishes nothing; a registry change during construction may still refuse publication after the body has run.\n\nThe name is last, matching `def` and `set`: the bound name sits nearest the defining word. Registration is therefore ``values (body) `name @defm``. See Modules." },
        .{ .name = "@defm!", .primitive = defmSeedless, .effect = "body module-name --", .doc = "*Unit constructor.* `@defm` with no values operand: the body runs on an empty stack, exactly as ``[] (body) `name @defm``. Module discovery and the formatter's `### module` header recognize this form too." },
        .{ .name = "undefm", .primitive = undefmWord, .effect = "module-name --", .doc = "Remove the module currently registered under a canonical name or unqualified alias, resolved exactly as ordinary registry lookup resolves it. An unregistered name is `` `undefined-word ``. Removal strips every alias targeting the module in the same publish; an already-dispatched call finishes under the generation it resolved. See [Modules](SPEC.md#modules)." },
        .{ .name = "*file*", .primitive = fileWord, .effect = "-- string", .doc = "Return the source name attached to the currently executing reader-authored occurrence. A definition reports the file that authored its body even when another file calls it. `` `domain `` in runtime-assembled code with no source provenance; there is no fallback to the caller's file." },
        .{ .name = "*module*", .primitive = moduleNameWord, .effect = "-- module-name", .doc = "Return the canonical registration name selected by the current module activation. The same image registered under different names reports the name through which it was called; an alias reports its target's canonical name. `` `domain `` at top level or through an escaped quotation whose image has no invoking registration." },
        .{ .name = "import", .primitive = importAs(.public), .effect = "module-name q --", .doc = "Import the public attributes named by the symbol list `q` under their own unqualified names: `` `str (upper lower) import `` binds `upper` and `lower`. Every requested name is validated against one module generation before any binding is published; a missing or private attribute is `` `undefined-word `` and publishes none of the request. A non-list `q` or a non-symbol item is `` `type ``; an invalid module or attribute name is `` `domain ``. Each imported binding dispatches through the module, preserves the original's effect and documentation, and may replace an existing local binding. `see` renders a forwarding binding as its one-word quotation, and a directly bound standard-library builtin as `<primitive>`." },
        .{ .name = "importp", .primitive = importAs(.private), .effect = "module-name q --", .doc = "`import`, publishing each forwarding binding as a private module word: the importing module's words use it, but it is not part of that module's public surface. Legal only inside a module body; elsewhere it is `` `domain ``." },
        .{ .name = "alias", .primitive = aliasModule, .effect = "short name --", .doc = "Register an unqualified short registry name for a canonical, possibly dotted module name. Aliases and module names may not collide in either direction." },
        .{ .name = "qualify", .primitive = qualify, .effect = "module-name binding-name -- qualified-word", .doc = "Validate a canonical module path, or the reserved qualifier `` `core ``, and one unqualified, non-reserved binding segment, then construct their qualified executable word directly from the interned components. It does not parse source, intern anything new, or grant lifecycle authority; use `execute` to invoke the result dynamically. `` `core `dup qualify `` reaches the primitive even where `dup` is shadowed." },
        .{ .name = "words", .primitive = words, .effect = "--", .doc = "Print the visible dictionary in sorted order." },
        .{ .name = "exports", .primitive = exportsWord, .effect = "module-name -- names", .doc = "Return the public words of a module as a list of symbols in codepoint order, loading an embedded or mapped module on first mention. `` `core exports `` lists core's builtins and prelude words. An invalid module name is `` `domain ``; an unknown one is `` `undefined-word ``." },
        .{ .name = "stdlib", .primitive = stdlibWord, .effect = "-- names", .doc = "Return the names of the embedded standard-library modules as a list of symbols in codepoint order." },
        .{ .name = "load", .primitive = load, .effect = "path --", .doc = "Read and evaluate a source file as one transactional unit in the calling session." },
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
    if (visibility == .private and !scope.isUnderConstruction())
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

    /// Whether the attribute being published is a standard-library builtin,
    /// which binds directly: a standard-library module name is never
    /// registered again, so resolving its attribute now or at each call finds
    /// the same builtin, and a forwarding body would only add an activation.
    fn importsBuiltin(self: *const ImportDriver) bool {
        if (self.generation.?.borrow().provenance() != .standard_library) return false;
        return self.resolved.?.borrow().spec().binding == .builtin;
    }

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
            const direct = self.importsBuiltin();
            if (!direct and self.forwarding_body == null) {
                // The forwarding word is written into the importing root.
                const linker = try evaluator.rootLinker(self.scope);
                self.forwarding_body = .init(try list.fromValuesGeneric(
                    evaluator.allocator(),
                    &.{.{ .symbol = .{ .name = requested.qualified, .slot = try linker.link(requested.qualified) } }},
                ));
                continue;
            }
            if (self.publisher == null and direct) {
                const lease = self.resolved.?.borrow();
                self.publisher = .init(try self.scope.publishImportedCursor(requested.binding, .{
                    .primitive = lease.spec().binding.builtin,
                    .visibility = self.visibility,
                    .effect = lease.spec().effect,
                    .doc = lease.spec().doc,
                    .reports_as = .plain(requested.qualified),
                }));
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
                    if (self.forwarding_body) |*body| body.deinit(evaluator.releaseDomain(), evaluator.allocator());
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

fn exportsWord(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    try evaluator.startDriver(ExportsDriver.init(evaluator, requested));
}

/// Collect one module's public names, or core's, then sort them and build the
/// symbol list. A cold module rewinds this call behind the ordinary qualified
/// auto-load, so the replay finds it registered.
const ExportsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    allocator: std.mem.Allocator,
    requested: u32,
    found: heap.Owned(poll_api.ChunkList(u32)),
    state: heap.Owned(State),

    const State = union(enum) {
        validate: intern.ModuleNameCursor,
        acquire: struct {
            name: intern.ModuleName,
            cursor: heap.Owned(machine.ModuleLookupCursor),
        },
        module_names: struct {
            generation: heap.Owned(modules.GenerationLease),
            cursor: heap.Owned(modules.ModulePublicNameCursor),
        },
        core_names: heap.Owned(reflection.VisibleNameCursor),
        sort: heap.Owned(reflection.SortedUniqueNameCursor),
        fill: struct {
            names: heap.Owned(reflection.SortedUniqueNames),
            values: heap.Owned(heap.OwnedValueBuffer),
        },
        build: heap.Owned(list.ValueMaterializer),

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .validate => {},
                .acquire => |*acquire| acquire.cursor.deinit(releases, allocator),
                .module_names => |*names| {
                    names.cursor.deinit(releases, allocator);
                    names.generation.deinit(releases, allocator);
                },
                .core_names => |*cursor| cursor.deinit(releases, allocator),
                .sort => |*cursor| cursor.deinit(releases, allocator),
                .fill => |*fill| {
                    fill.values.deinit(releases, allocator);
                    fill.names.deinit(releases, allocator);
                },
                .build => |*materializer| materializer.deinit(releases, allocator),
            }
        }
    };

    fn init(evaluator: *Machine, requested: u32) ExportsDriver {
        const core_requested = intern.isReservedRegistryBytes(intern.get(requested));
        return .{
            .allocator = evaluator.allocator(),
            .requested = requested,
            .found = .init(poll_api.ChunkList(u32).init(evaluator.allocator())),
            .state = .init(if (core_requested)
                .{ .core_names = .init(reflection.VisibleNameCursor.init(
                    .{ .environment = evaluator.currentEnv().coreView() },
                    evaluator.currentEnv().coreView(),
                    evaluator.unit.bindingPin(),
                )) }
            else
                .{ .validate = .init(requested) }),
        };
    }

    fn replace(self: *ExportsDriver, evaluator: *Machine, next: State) void {
        self.state.borrowMut().deinit(evaluator.releaseDomain(), evaluator.allocator());
        self.state.borrowMut().* = next;
    }

    fn startSort(self: *ExportsDriver, evaluator: *Machine) MachineError!void {
        const cursor = try reflection.SortedUniqueNameCursor.init(self.allocator, self.found.borrowMut());
        self.replace(evaluator, .{ .sort = .init(cursor) });
    }

    pub fn advance(evaluator: *Machine, self: *ExportsDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.state.borrowMut().*) {
            .validate => |*validation| switch (validation.advance()) {
                .pending => {},
                .complete => |name| {
                    const module_name = name orelse
                        return evaluator.fail(.domain, "exports requires a valid module name");
                    self.replace(evaluator, .{ .acquire = .{
                        .name = module_name,
                        .cursor = .init(machine.ModuleLookupCursor.atCurrent(evaluator, module_name)),
                    } });
                },
            },
            .acquire => |*acquire| switch (acquire.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| if (maybe_generation) |generation| {
                    const names = generation.publicNameCursor();
                    self.replace(evaluator, .{ .module_names = .{
                        .generation = .init(generation),
                        .cursor = .init(names),
                    } });
                } else {
                    const requested = self.requested;
                    const module_name = acquire.name;
                    evaluator.retireDriver(self);
                    return evaluator.retryQualifiedOperandAfterLoad(
                        requested,
                        .{ .unregistered_module = module_name },
                    );
                },
            },
            .module_names => |*names| switch (names.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => try self.startSort(evaluator),
                .item => |name| try self.found.borrowMut().append(name),
            },
            .core_names => |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => {},
                .complete => try self.startSort(evaluator),
                .item => |name| try self.found.borrowMut().append(name),
            },
            .sort => |*cursor| switch (try cursor.borrowMut().advance(work)) {
                .pending => {},
                .complete => |names| {
                    var owned_names = heap.Owned(reflection.SortedUniqueNames).init(names);
                    errdefer owned_names.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    const values = try heap.OwnedValueBuffer.init(
                        evaluator.releaseDomain(),
                        owned_names.borrow().items().len,
                    );
                    self.replace(evaluator, .{ .fill = .{
                        .names = .init(owned_names.take()),
                        .values = .init(values),
                    } });
                },
            },
            .fill => |*fill| {
                const names = fill.names.borrow().items();
                const filled = fill.values.borrow().len();
                if (filled != names.len) {
                    fill.values.borrowMut().appendOwned(.{ .symbol = .{ .name = names[filled] } });
                    continue;
                }
                const materializer = list.ValueMaterializer.initOwned(self.allocator, fill.values.take());
                self.replace(evaluator, .{ .build = .init(materializer) });
            },
            .build => |*materializer| switch (try materializer.borrowMut().advance(work)) {
                .pending => {},
                .complete => |result| return .{ .output = result },
            },
        };
        return .stepped;
    }
};

fn stdlibWord(evaluator: *Machine) MachineError!void {
    const names = comptime stdlib.sortedNames();
    var values: [names.len]Value = undefined;
    for (names, &values) |name, *slot| slot.* = .{ .symbol = .{ .name = try intern.intern(name) } };
    return evaluator.pushOwned(try list.fromValues(evaluator.allocator(), &values));
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
