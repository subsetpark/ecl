//! Module, environment, reflection, and source-transport primitives.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const binder = @import("binder.zig");
const machine = @import("machine.zig");
const modules = @import("modules.zig");
const definition_prims = @import("definition_prims.zig");
const poll_api = @import("poll.zig");
const reflection = @import("reflection.zig");
const kernel_storage = @import("kernel_storage.zig");
const Value = value.Value;
const Header = machine.Header;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
/// Removal is one directory edit; the retired generation's images release
/// through the superseded directory's own bounded retirement.
pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try definition_prims.install(core);
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "@defm", .primitive = defmWord, .effect = "body module-name --", .doc = "Construct a module image and register it under `module-name`. The body is run in a new unit." },
        .{ .name = "*file*", .primitive = fileWord, .effect = "-- string", .doc = "Return the source name attached to the currently executing reader-authored occurrence." },
        .{ .name = "*module*", .primitive = moduleNameWord, .effect = "-- module-name", .doc = "Return the name of the module whose code is running." },
        .{ .name = "import", .primitive = importAs(.public), .effect = "module-name bindings --", .doc = "For each value in `bindings`, create a public alias in the current scope from <value> to <module-name>.<value>." },
        .{ .name = "importp", .primitive = importAs(.private), .effect = "module-name q --", .doc = "For each value in `bindings`, create a private alias in the current scope from <value> to <module-name>.<value>." },
        .{ .name = "qualify", .primitive = qualify, .effect = "module-name binding-name -- qualified-word", .doc = "Create a symbol value containing the qualified name `module-name`.`binding-name`." },
        .{ .name = "words", .primitive = words, .effect = "--", .doc = "Print all visible words in sorted order." },
        .{ .name = "exports", .primitive = exportsWord, .effect = "module-name -- names", .doc = "Return the public words of a module as a list of symbols in codepoint order." },
        .{ .name = "module-doc", .primitive = moduleDocWord, .effect = "module-name -- string", .doc = "Return the docstring of `module-name`'s current image." },
        .{ .name = "@load", .primitive = load, .effect = "path --", .doc = "Evaluate the source file at `path`. The file is run in a new unit." },
    };
    try core.installBuiltins(&definitions);
}
/// Whether `primitive` changes definitions or takes more than its declared
/// inputs, so a stack summary cannot rest on its effect.
pub fn reshapesWords(primitive: env.PrimitiveImpl) bool {
    return definition_prims.binds(primitive) or primitive == &defmWord or primitive == &load or
        primitive == importAs(.public) or primitive == importAs(.private);
}

/// The one module constructor. The name is validated before the body runs, so
/// a name that could never be published costs no evaluation and no effect.
/// Only a registry change during construction can still refuse publication.
fn defmWord(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    const name = try fiber.popSymbol();
    var body = try fiber.popQuotation();
    try startDefm(fiber, name, body.take().list);
}

/// The value beneath the operands documents the module only when it is exactly
/// `(: "text")`. Anything else is the caller's data and stays where it is: a
/// module declares no stack effect, so nothing else could be its annotation.
fn startDefm(fiber: *Fiber, name: u32, body_header: *Header) MachineError!void {
    var body = heap.Owned(*Header).init(body_header);
    errdefer body.deinit(fiber.releases, fiber.allocator);
    var doc: heap.Owned(Value) = .none;
    errdefer doc.deinit(fiber.releases, fiber.allocator);
    if (fiber.available() != 0) {
        if (try moduleDocumentation(fiber.visibleOperandBorrowed(fiber.available() - 1))) |document| {
            heap.retainValue(document);
            doc = .init(document);
            fiber.discard(1);
        }
    }
    // From here the driver owns both; an uninstalled driver disposes them.
    const owned_doc = doc;
    doc = .none;
    try fiber.startDriver(DefmDriver{
        .body = .init(body.take()),
        .validation = .init(name),
        .doc = owned_doc,
    });
}

/// The documentation string of a module annotation, read in constant work.
fn moduleDocumentation(candidate: Value) error{OutOfMemory}!?Value {
    if (candidate != .list or candidate.list.length() != 2) return null;
    const marker = list.atUnchecked(candidate, 0);
    if (marker != .symbol or marker.symbol.name != try intern.intern(":")) return null;
    const document = list.atUnchecked(candidate, 1);
    if (!document.isString() or env.documentation(document.list) == null) return null;
    return document;
}

const DefmDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    body: heap.Owned(*Header),
    validation: intern.ModuleNameCursor,
    /// The module's documentation, consumed from beneath the operands.
    doc: heap.Owned(Value) = .none,

    pub fn advance(fiber: *Fiber, self: *DefmDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) switch (self.validation.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse
                    return fiber.fail(.domain, "@defm requires a valid module name");
                // The registry refuses `core` too, but only at publication; a
                // name that can never publish must fail before the body runs.
                if (intern.isReservedRegistryBytes(intern.get(intern.moduleId(name))))
                    return fiber.fail(.domain, "module name `core` is reserved for the core qualifier");
                const provenance = fiber.current.?.site.registration_provenance;
                try fiber.refuseReservedModule(name, provenance);
                try fiber.refuseUnexportedModule(name, provenance);
                const body = self.body.take();
                var doc = self.doc;
                self.doc = .none;
                defer doc.deinit(fiber.releases, fiber.allocator);
                fiber.retireDriver(self);
                try fiber.moduleOwned(
                    name,
                    body,
                    if (doc.isPresent()) env.documentation(doc.borrow().list).? else null,
                );
                return .detached;
            },
        };
        return .stepped;
    }
};

/// Returns the name of the active execution home's image. A construction
/// body reports the name it is being built under.
fn moduleNameWord(fiber: *Fiber) MachineError!void {
    const home = fiber.currentHome() orelse return fiber.fail(
        .domain,
        "*module* is legal only in code homed in a registered module",
    );
    try fiber.pushOwned(.{ .symbol = .{ .name = intern.moduleId(home.name()) } });
}

/// Returns the reader source that authored the active occurrence. Source names
/// are user-sized host input, so materialization remains scheduled and
/// cancellable rather than hiding a traversal in the primitive callback.
fn fileWord(fiber: *Fiber) MachineError!void {
    const source_name = fiber.activeSourceName() orelse return fiber.fail(
        .domain,
        "*file* is unavailable for code without source provenance",
    );
    try fiber.startDriver(FileDriver{
        .text = .init(.init(fiber.allocator, source_name)),
    });
}

const FileDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    text: heap.Owned(kernel_storage.TextMaterializer),

    pub fn advance(fiber: *Fiber, self: *FileDriver) MachineError!machine.WorkProgress {
        return switch (try self.text.borrowMut().advance(fiber.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};

fn importAs(comptime visibility: env.Visibility) env.PrimitiveImpl {
    return struct {
        fn run(fiber: *Fiber) MachineError!void {
            return importWord(fiber, visibility);
        }
    }.run;
}

fn importWord(fiber: *Fiber, visibility: env.Visibility) MachineError!void {
    try fiber.require(2);
    const scope = try fiber.definitionScope();
    if (visibility == .private and (!scope.isModuleRoot() or fiber.stagingImage(scope) == null))
        return fiber.fail(.domain, "importp is legal only in a module root under construction");
    var requested = try fiber.popList();
    errdefer requested.deinit();
    const module_id = try fiber.popSymbol();
    const requested_count: usize = @intCast(requested.borrow().list.length());
    const prepared = try fiber.allocator.alloc(intern.BindingName, requested_count);
    try fiber.startDriver(ImportDriver.init(
        fiber,
        module_id,
        requested.take(),
        prepared,
        visibility,
    ));
}
/// `import` checks how its operands are spelled and publishes one alias per
/// requested name, `x -> m.x`. It neither loads the module nor reads what the
/// module holds: an alias is followed when its word is reached, and a missing
/// or private attribute fails there. Every spelling is checked before the
/// first name is published, so a refused request installs nothing.
const ImportDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    requested: heap.Owned(Value),
    prepared: heap.Owned([]intern.BindingName),
    scope: *env.Scope,
    visibility: env.Visibility,
    module_validation: intern.ModuleNameCursor,
    module_name: ?intern.ModuleName = null,
    prepare_index: usize = 0,
    binding_validation: ?intern.NamespaceCursor = null,
    publish_index: usize = 0,
    publisher: ?heap.Owned(modules.Registry.DefineCursor) = null,

    fn init(
        fiber: *Fiber,
        module_id: u32,
        requested: Value,
        prepared: []intern.BindingName,
        visibility: env.Visibility,
    ) ImportDriver {
        return .{
            .requested = .init(requested),
            .prepared = .init(prepared),
            .scope = fiber.currentScope(),
            .visibility = visibility,
            .module_validation = .init(module_id),
        };
    }

    pub fn advance(fiber: *Fiber, self: *ImportDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) {
            if (self.module_name == null) switch (self.module_validation.advance()) {
                .pending => continue,
                .complete => |maybe_name| {
                    self.module_name = maybe_name orelse return fiber.fail(
                        .domain,
                        "import requires a valid module name",
                    );
                    continue;
                },
            };

            if (self.prepare_index != self.prepared.borrow().len) {
                if (self.binding_validation == null) {
                    const symbol = switch (list.atUnchecked(self.requested.borrow(), self.prepare_index)) {
                        .symbol => |name| name.name,
                        else => return fiber.typeError("a list of symbols"),
                    };
                    self.binding_validation = .init(symbol);
                }
                switch (self.binding_validation.?.advance()) {
                    .pending => continue,
                    .complete => |maybe_name| {
                        const binding = maybe_name orelse return fiber.fail(
                            .domain,
                            "import attributes must be unqualified and non-reserved symbols",
                        );
                        self.binding_validation = null;
                        self.prepared.borrowMut().*[self.prepare_index] = binding;
                        self.prepare_index += 1;
                        continue;
                    },
                }
            }

            if (self.publish_index == self.prepared.borrow().len) return .completed;
            const binding = self.prepared.borrow()[self.publish_index];
            const alias: env.Alias = .{
                .module = self.module_name.?,
                .binding = binding,
                .visibility = self.visibility,
            };
            switch (self.scope.storage) {
                // A module stages its imports with its definitions; a name
                // introduced twice fails construction.
                .module_root => {
                    const image = fiber.stagingImage(self.scope) orelse return fiber.fail(
                        .domain,
                        "module imports are legal only while the module is under construction",
                    );
                    try image.stageAlias(binding, alias);
                    self.publish_index += 1;
                    continue;
                },
                .core_build => return fiber.fail(.domain, "core does not import"),
                .session => {},
            }
            if (self.publisher == null)
                self.publisher = .init(fiber.inherited.registry.defineCursor(binding, .{ .alias = alias }));
            switch (try self.publisher.?.borrowMut().advance()) {
                .pending => {},
                .complete => |outcome| {
                    if (outcome == .introduced) fiber.warnCoreShadowing(binding, null);
                    self.publisher.?.deinit(fiber.releases, fiber.allocator);
                    self.publisher = null;
                    self.publish_index += 1;
                },
            }
        }
        return .stepped;
    }
};

fn qualify(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    const binding = try fiber.popSymbol();
    const module_name = try fiber.popSymbol();
    try fiber.startDriver(QualifyDriver{
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

    pub fn advance(fiber: *Fiber, self: *QualifyDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) {
            if (self.module_name == null) switch (self.module_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.module_name = name orelse return fiber.fail(
                        .domain,
                        "qualify requires a valid module name",
                    );
                    continue;
                },
            };
            if (self.binding_name == null) switch (self.binding_validation.advance()) {
                .pending => continue,
                .complete => |name| {
                    self.binding_name = name orelse return fiber.fail(
                        .domain,
                        "qualify requires an unqualified, non-reserved binding name",
                    );
                    continue;
                },
            };
            if (self.cursor == null) self.cursor = .init(try .init(
                fiber.allocator,
                intern.qualifiedName(self.module_name.?, self.binding_name.?),
            ));
            switch (try self.cursor.?.borrowMut().advance()) {
                .pending => {},
                .complete => |word| return .{ .output = .{ .symbol = try fiber.linkedWord(word) } },
            }
        }
        return .stepped;
    }
};
fn words(fiber: *Fiber) MachineError!void {
    try fiber.startDriver(WordsDriver.init(fiber));
}

fn exportsWord(fiber: *Fiber) MachineError!void {
    const requested = try fiber.popWord();
    try fiber.startDriver(ExportsDriver.init(fiber, requested));
}

/// Collect one module's public names, or core's, then sort them and build the
/// symbol list. A cold module rewinds this call behind the ordinary qualified
/// auto-load, so the replay finds it registered.
const ExportsDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    allocator: std.mem.Allocator,
    /// The operand as written: its link says whose view finds the module.
    requested: value.Symbol,
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

    fn init(fiber: *Fiber, requested: value.Symbol) ExportsDriver {
        const core_requested = intern.isReservedRegistryBytes(intern.get(requested.name));
        return .{
            .allocator = fiber.allocator,
            .requested = requested,
            .found = .init(poll_api.ChunkList(u32).init(fiber.allocator)),
            .state = .init(if (core_requested)
                .{ .core_names = .init(reflection.VisibleNameCursor.init(.core, fiber.environment)) }
            else
                .{ .validate = .init(requested.name) }),
        };
    }

    fn replace(self: *ExportsDriver, fiber: *Fiber, next: State) void {
        self.state.borrowMut().deinit(fiber.releases, fiber.allocator);
        self.state.borrowMut().* = next;
    }

    fn startSort(self: *ExportsDriver, fiber: *Fiber) MachineError!void {
        const cursor = try reflection.SortedUniqueNameCursor.init(self.allocator, self.found.borrowMut());
        self.replace(fiber, .{ .sort = .init(cursor) });
    }

    pub fn advance(fiber: *Fiber, self: *ExportsDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) switch (self.state.borrowMut().*) {
            .validate => |*validation| switch (validation.advance()) {
                .pending => {},
                .complete => |name| {
                    const module_name = name orelse
                        return fiber.fail(.domain, "exports requires a valid module name");
                    self.replace(fiber, .{ .acquire = .{
                        .name = module_name,
                        .cursor = .init(fiber.moduleLookup(self.requested, module_name)),
                    } });
                },
            },
            .acquire => |*acquire| switch (acquire.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| if (maybe_generation) |generation| {
                    const names = generation.publicNameCursor();
                    self.replace(fiber, .{ .module_names = .{
                        .generation = .init(generation),
                        .cursor = .init(names),
                    } });
                } else {
                    const requested = self.requested;
                    const module_name = acquire.name;
                    fiber.retireDriver(self);
                    return fiber.retryQualifiedOperandAfterLoad(
                        requested,
                        .{ .unregistered_module = .{ .name = module_name, .searcher = binder.sourceOf(fiber.environment, requested) } },
                    );
                },
            },
            .module_names => |*names| switch (names.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => try self.startSort(fiber),
                .item => |name| try self.found.borrowMut().append(name),
            },
            .core_names => |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => {},
                .complete => try self.startSort(fiber),
                .item => |name| try self.found.borrowMut().append(name),
            },
            .sort => |*cursor| switch (try cursor.borrowMut().advance(work)) {
                .pending => {},
                .complete => |names| {
                    var owned_names = heap.Owned(reflection.SortedUniqueNames).init(names);
                    errdefer owned_names.deinit(fiber.releases, fiber.allocator);
                    const values = try heap.OwnedValueBuffer.init(
                        fiber.releases,
                        owned_names.borrow().items().len,
                    );
                    self.replace(fiber, .{ .fill = .{
                        .names = .init(owned_names.take()),
                        .values = .init(values),
                    } });
                },
            },
            .fill => |*fill| {
                const names = fill.names.borrow().items();
                const filled = fill.values.borrow().len();
                if (filled != names.len) {
                    fill.values.borrowMut().appendOwned(value.datum(.{ .symbol = try fiber.linkedWord(names[filled]) }));
                    continue;
                }
                const materializer = list.ValueMaterializer.initOwned(self.allocator, fill.values.take());
                self.replace(fiber, .{ .build = .init(materializer) });
            },
            .build => |*materializer| switch (try materializer.borrowMut().advance(work)) {
                .pending => {},
                .complete => |result| return .{ .output = result },
            },
        };
        return .stepped;
    }
};

fn moduleDocWord(fiber: *Fiber) MachineError!void {
    const requested = try fiber.popWord();
    try fiber.startDriver(ModuleDocDriver{ .requested = requested, .validation = .init(requested.name) });
}

/// Read one module generation's documentation and normalize it as `doc`
/// does. A cold module rewinds this call behind the ordinary qualified
/// auto-load, so the replay finds it registered.
const ModuleDocDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// The operand as written: its link says whose view finds the module.
    requested: value.Symbol,
    validation: intern.ModuleNameCursor,
    acquire: heap.Owned(machine.ModuleLookupCursor) = .none,
    name: ?intern.ModuleName = null,
    normalization: heap.Owned(definition_prims.DocumentNormalization) = .none,

    pub fn advance(fiber: *Fiber, self: *ModuleDocDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) {
            if (self.normalization.isPresent()) {
                if (try self.normalization.borrowMut().advance(work)) |normalized|
                    return .{ .output = normalized };
            } else if (self.acquire.isPresent()) switch (self.acquire.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| {
                    var generation = heap.Owned(modules.GenerationLease).init(maybe_generation orelse {
                        const requested = self.requested;
                        const module_name = self.name.?;
                        fiber.retireDriver(self);
                        return fiber.retryQualifiedOperandAfterLoad(
                            requested,
                            .{ .unregistered_module = .{ .name = module_name, .searcher = binder.sourceOf(fiber.environment, requested) } },
                        );
                    });
                    defer generation.deinit(fiber.releases, fiber.allocator);
                    const document = generation.borrow().documentation() orelse
                        return fiber.fail(.domain, "module has no documentation");
                    self.acquire.deinit(fiber.releases, fiber.allocator);
                    self.normalization = .init(try .init(fiber, document));
                },
            } else switch (self.validation.advance()) {
                .pending => {},
                .complete => |maybe_name| {
                    const name = maybe_name orelse
                        return fiber.fail(.domain, "module-doc requires a valid module name");
                    if (intern.isReservedRegistryBytes(intern.get(intern.moduleId(name))))
                        return fiber.fail(.domain, "`core` is a qualifier, not a documented module");
                    self.name = name;
                    self.acquire = .init(fiber.moduleLookup(self.requested, name));
                },
            }
        }
        return .stepped;
    }
};

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

    fn init(fiber: *Fiber) WordsDriver {
        return .{
            .allocator = fiber.allocator,
            .found = .init(poll_api.ChunkList(u32).init(fiber.allocator)),
            .actions = .init(reflection.ActionPlan.init(fiber.allocator)),
            .state = .init(.{ .visible = .init(reflection.VisibleNameCursor.init(
                fiber.visibleNameRoot(),
                fiber.environment,
            )) }),
        };
    }
    fn append(self: *WordsDriver, name: u32) error{OutOfMemory}!void {
        try self.found.borrowMut().append(name);
    }
    pub fn advance(fiber: *Fiber, self: *WordsDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) switch (self.state.borrowMut().*) {
            .visible => |*visible| switch (visible.borrowMut().advance()) {
                .pending => {},
                .complete => {
                    const cursor = try reflection.SortedUniqueNameCursor.init(
                        self.allocator,
                        self.found.borrowMut(),
                    );
                    visible.deinit(fiber.releases, fiber.allocator);
                    self.state.borrowMut().* = .{ .postprocess = .init(cursor) };
                },
                .item => |name| try self.append(name),
            },
            .postprocess => |*cursor| switch (try cursor.borrowMut().advance(work)) {
                .pending => {},
                .complete => |names| {
                    cursor.deinit(fiber.releases, fiber.allocator);
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
                fiber.inherited.runtime().console.writeOutput(write.rendered.borrow(), false) catch return writeFailure(fiber);
                return .completed;
            },
        };
        return .stepped;
    }
};
fn writeFailure(fiber: *Fiber) MachineError {
    return fiber.fail(.io, "standard output write failed");
}
fn load(fiber: *Fiber) MachineError!void {
    var path_value = try fiber.popValue();
    defer path_value.deinit();
    if (!path_value.borrow().isString()) return fiber.typeError("a string path");
    const encoder = kernel_storage.StringEncoder.init(fiber.allocator, path_value.borrow());
    try fiber.startDriver(LoadDriver{
        .path_value = .init(path_value.take()),
        .encoder = .init(encoder),
    });
}
const LoadDriver = machine.PathActionDriver(Fiber.loadFileOwned);
