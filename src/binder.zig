//! Construction-time binding. A word occurrence carries the root it was written
//! in; binding resolves each top-level unquoted occurrence of a quotation in its
//! root, against one captured publication view, and seals the result into an
//! executable whose targets never change. Ordinary dispatch then follows those
//! targets without lookup. Explicit lookups (`execute`, reflection, and
//! incremental top-level evaluation) use the same resolver one word at a time.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const map_state = @import("module_snapshot.zig");

/// The chain a miss reports.
pub const LookupChain = machine.LookupChain;

/// A module group being sealed: words written in its image resolve against its
/// complete directory before the image is published.
pub const Group = struct {
    image_scope: env.ScopeId,
    /// The name the group will be registered under. A qualified name with
    /// this module is the group naming itself, which no registry lookup can
    /// answer before publication.
    module: intern.ModuleName,
    /// Null until the group's staged names have become its directory.
    directory: ?*const env.NameMap,
};

/// A top-level definition being constructed: a word written in the root it is
/// published into and spelling its name calls the definition itself.
pub const SelfReference = struct {
    root: env.ScopeId,
    name: u32,
    definition: *env.Definition,
};

/// Everything a resolution reads besides the word: the captured view, how to
/// find modules, and what construction is in progress.
pub const Context = struct {
    environment: *env.Env,
    /// Owned by the context's holder, which releases it with `deinit`.
    view: modules.View,
    module_access: *const modules.ExecutionAccess,
    registry: *modules.Registry,
    project: ?*const map_state.Snapshot,
    libraries: machine.EmbeddedLibraries,
    /// The provenance a qualified name written outside any module searches
    /// private registries under.
    provenance: modules.RegistrationProvenance,
    group: ?Group = null,
    self_reference: ?SelfReference = null,

    pub fn deinit(self: *Context) void {
        self.view.deinit();
        self.* = undefined;
    }
};

/// Why resolving one word did not produce a definition.
pub const Miss = union(enum) {
    /// Nothing by that name is visible along the chain searched.
    unresolved: LookupChain,
    /// The dotted prefix has never been interned, so nothing can be registered
    /// under it yet; loading may make it resolvable.
    unknown_module_prefix: []const u8,
    /// A well-formed qualified name whose module is not registered.
    unregistered_module: intern.ModuleName,
    /// The word was written in an image that has since been torn down.
    retired,
    /// Following name aliases did not reach a definition.
    alias_cycle,
};

pub const Outcome = union(enum) {
    /// Borrowed: valid while the context's view is held.
    resolved: *env.Definition,
    missed: Miss,
};
pub const Progress = poll.Progress(Outcome);

/// Aliases are followed at most this many times; a longer chain is a cycle.
const max_alias_hops = 64;

/// Resolves one word occurrence.
pub const Resolver = struct {
    name: u32,
    root: Root,
    phase: Phase = .dot,
    work: Work = .none,
    dot_index: usize = 0,
    prefix: ?intern.ModuleName = null,
    export_name: ?intern.BindingName = null,
    generation: ?modules.GenerationLease = null,
    /// The pin proving a written-in image live while its directory is read.
    image_pin: ?modules.GenerationPin = null,
    /// The provenance of the image whose directory held the alias being
    /// followed: an alias resolves as its own module would resolve it.
    owner_provenance: ?modules.RegistrationProvenance = null,
    hops: u8 = 0,

    const Root = union(enum) {
        core,
        session,
        image: *env.ScopeCell,
        retired,
    };

    const Phase = enum {
        dot,
        prefix,
        prefix_validate,
        export_name,
        export_validate,
        acquire,
        export_lookup,
        group_export,
        core_atom,
        core_lookup,
        session_lookup,
        image_lookup,
        complete,
    };

    const Work = union(enum) {
        none,
        dot: intern.LastDotCursor,
        atom: intern.InternLookupCursor,
        module_validation: intern.ModuleNameCursor,
        binding_validation: intern.NamespaceCursor,
        acquisition: machine.ModuleLookupCursor,
        export_lookup: modules.ModuleNameLookupCursor,
        lookup: env.NameMap.RawLookupCursor,

        fn deinit(self: *Work) void {
            switch (self.*) {
                .acquisition => |*cursor| cursor.deinit(),
                .export_lookup => |*cursor| cursor.deinit(),
                .none, .dot, .atom, .module_validation, .binding_validation, .lookup => {},
            }
            self.* = .none;
        }
    };

    pub fn init(context: *const Context, word: value.Symbol) Resolver {
        const root: Root = switch (env.wordTarget(word.slot)) {
            .unlinked, .local => .core,
            .root => |id| switch (context.environment.scopeOf(id)) {
                .unscoped, .core => .core,
                .session => .session,
                .cell => |cell| .{ .image = cell },
                .retired => .retired,
            },
        };
        return .{
            .name = word.name,
            .root = root,
            .work = .{ .dot = intern.lastDotCursor(intern.get(word.name)) },
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.work.deinit();
        if (self.generation) |*lease| lease.deinit();
        if (self.image_pin) |*pin| pin.deinit();
        self.* = undefined;
    }

    fn finish(self: *Resolver, outcome: Outcome) Progress {
        self.work.deinit();
        self.phase = .complete;
        return .{ .complete = outcome };
    }

    fn miss(self: *Resolver, reason: Miss) Progress {
        return self.finish(.{ .missed = reason });
    }

    fn spelling(self: *const Resolver) []const u8 {
        return intern.get(self.name);
    }

    fn plainChain(self: *const Resolver) LookupChain {
        return switch (self.root) {
            .core, .retired => .core,
            .session => .session,
            .image => .module,
        };
    }

    /// Begins the plain lookup of the word's own name in its root.
    fn beginPlain(self: *Resolver, context: *const Context) Progress {
        const binding: intern.BindingName = @fromBackingInt(self.name);
        if (context.self_reference) |reference| {
            if (reference.name == self.name and self.writtenIn(context, reference.root))
                return self.finish(.{ .resolved = reference.definition });
        }
        switch (self.root) {
            .retired => return self.miss(.retired),
            .core => return self.beginCore(context, binding),
            .session => {
                const lookup = context.view.sessionLookup(binding) orelse return self.beginCore(context, binding);
                self.work = .{ .lookup = lookup };
                self.phase = .session_lookup;
                return .pending;
            },
            .image => |cell| {
                if (context.group) |group| {
                    if (group.image_scope == cell.id) {
                        self.work = .{ .lookup = group.directory.?.rawLookup(binding) };
                        self.phase = .image_lookup;
                        return .pending;
                    }
                }
                const owner = cell.ownerHandle() orelse return self.beginCore(context, binding);
                self.image_pin = modules.tryPinAnchor(owner, context.module_access) orelse
                    return self.miss(.retired);
                const scope = cell.scopeUnder(.fresh_pin) orelse return self.miss(.retired);
                const home = modules.homeForModuleRootScope(scope) orelse return self.beginCore(context, binding);
                const lookup = home.lookupCursor(binding) orelse return self.beginCore(context, binding);
                self.work = .{ .lookup = lookup };
                self.phase = .image_lookup;
                return .pending;
            },
        }
    }

    fn writtenIn(self: *const Resolver, context: *const Context, root: env.ScopeId) bool {
        return switch (self.root) {
            .core => root == context.environment.coreScopeId(),
            .session => root == context.environment.sessionScopeId(),
            .image => |cell| cell.id == root,
            .retired => false,
        };
    }

    fn beginCore(self: *Resolver, context: *const Context, binding: intern.BindingName) Progress {
        self.work = .{ .lookup = context.environment.coreLookup(binding) };
        self.phase = .core_lookup;
        return .pending;
    }

    /// Follows one directory entry: a definition resolves, an alias starts a
    /// qualified lookup of its target.
    fn follow(self: *Resolver, context: *const Context, entry: env.Entry, require_public: bool) Progress {
        switch (entry) {
            .definition => |definition| {
                if (require_public and definition.visibility != .public)
                    return self.miss(.{ .unresolved = .qualified });
                return self.finish(.{ .resolved = definition });
            },
            .alias => |alias| {
                if (require_public and alias.visibility != .public)
                    return self.miss(.{ .unresolved = .qualified });
                if (self.hops == max_alias_hops) return self.miss(.alias_cycle);
                self.hops += 1;
                self.prefix = alias.module;
                self.export_name = alias.binding;
                return self.beginAcquire(context);
            },
        }
    }

    fn beginAcquire(self: *Resolver, context: *const Context) Progress {
        // A qualified name written in an image searches that image's file
        // registries, so the image is held while its provenance is read.
        if (self.root == .image and self.image_pin == null) {
            const owner = self.root.image.ownerHandle();
            if (owner) |handle| self.image_pin = modules.tryPinAnchor(handle, context.module_access) orelse
                return self.miss(.retired);
        }
        if (self.generation) |*lease| lease.deinit();
        self.generation = null;
        self.work.deinit();
        if (context.group) |group| if (group.module == self.prefix.?) {
            const export_name = self.export_name orelse return self.miss(.{ .unresolved = .qualified });
            self.work = .{ .lookup = group.directory.?.rawLookup(export_name) };
            self.phase = .group_export;
            return .pending;
        };
        self.work = .{ .acquisition = machine.ModuleLookupCursor.initIn(
            &context.view,
            context.registry,
            context.project,
            context.libraries,
            self.provenance(context),
            self.prefix.?,
        ) };
        self.phase = .acquire;
        return .pending;
    }

    /// The provenance private registries are searched under: the image's
    /// own for a word written in one, otherwise the resolving site's.
    fn provenance(self: *const Resolver, context: *const Context) modules.RegistrationProvenance {
        if (self.owner_provenance) |owner| return owner;
        switch (self.root) {
            .image => |cell| if (cell.scope.load(.acquire)) |scope| {
                if (self.image_pin != null) {
                    if (modules.homeForModuleRootScope(scope)) |home| return home.registrationProvenance();
                }
            },
            else => {},
        }
        return context.provenance;
    }

    pub fn advance(self: *Resolver, context: *const Context) Progress {
        return switch (self.phase) {
            .dot => switch (self.work.dot.advance()) {
                .pending => .pending,
                .complete => |maybe_dot| {
                    const dot_index = maybe_dot orelse return self.beginPlain(context);
                    const bytes = self.spelling();
                    if (dot_index == 0 or dot_index + 1 == bytes.len)
                        return self.miss(.{ .unresolved = .qualified });
                    self.dot_index = dot_index;
                    if (intern.isReservedRegistryBytes(bytes[0..dot_index])) {
                        // `core` is a scope, not a registration.
                        self.work = .{ .atom = intern.lookupCursor(bytes[dot_index + 1 ..]) };
                        self.phase = .core_atom;
                        return .pending;
                    }
                    self.work = .{ .atom = intern.lookupCursor(bytes[0..dot_index]) };
                    self.phase = .prefix;
                    return .pending;
                },
            },
            .prefix => switch (self.work.atom.advance()) {
                .pending => .pending,
                .complete => |maybe_prefix| {
                    const prefix = maybe_prefix orelse return self.miss(.{
                        .unknown_module_prefix = self.spelling()[0..self.dot_index],
                    });
                    self.work = .{ .module_validation = .init(prefix) };
                    self.phase = .prefix_validate;
                    return .pending;
                },
            },
            // The module is acquired before its export name is looked up, so a
            // qualified miss reports an unregistered module even when the
            // export atom has never been interned.
            .prefix_validate => switch (self.work.module_validation.advance()) {
                .pending => .pending,
                .complete => |maybe_module| {
                    self.prefix = maybe_module orelse return self.miss(.{ .unresolved = .qualified });
                    self.work = .{ .atom = intern.lookupCursor(self.spelling()[self.dot_index + 1 ..]) };
                    self.phase = .export_name;
                    return .pending;
                },
            },
            .export_name => switch (self.work.atom.advance()) {
                .pending => .pending,
                .complete => |maybe_export| {
                    const export_id = maybe_export orelse {
                        // Still acquire the module, so an unregistered one is
                        // reported (and loaded) as such.
                        self.export_name = null;
                        return self.beginAcquire(context);
                    };
                    self.work = .{ .binding_validation = .init(export_id) };
                    self.phase = .export_validate;
                    return .pending;
                },
            },
            .export_validate => switch (self.work.binding_validation.advance()) {
                .pending => .pending,
                .complete => |maybe_binding| {
                    self.export_name = maybe_binding orelse return self.miss(.{ .unresolved = .qualified });
                    return self.beginAcquire(context);
                },
            },
            .acquire => switch (self.work.acquisition.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| {
                    self.work.deinit();
                    const generation = maybe_generation orelse
                        return self.miss(.{ .unregistered_module = self.prefix.? });
                    self.generation = generation;
                    const export_name = self.export_name orelse return self.miss(.{ .unresolved = .qualified });
                    self.work = .{ .export_lookup = generation.lookupCursor(export_name) };
                    self.phase = .export_lookup;
                    return .pending;
                },
            },
            .export_lookup => switch (self.work.export_lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_entry| {
                    const entry = maybe_entry orelse return self.miss(.{ .unresolved = .qualified });
                    self.owner_provenance = self.generation.?.provenance();
                    return self.follow(context, entry, true);
                },
            },
            .group_export => switch (self.work.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_entry| {
                    const entry = maybe_entry orelse return self.miss(.{ .unresolved = .qualified });
                    return self.follow(context, entry, true);
                },
            },
            .core_atom => switch (self.work.atom.advance()) {
                .pending => .pending,
                .complete => |maybe_export| {
                    const export_id = maybe_export orelse return self.miss(.{ .unresolved = .core });
                    self.work = .{ .lookup = context.environment.coreLookup(@fromBackingInt(export_id)) };
                    self.phase = .core_lookup;
                    return .pending;
                },
            },
            .core_lookup => switch (self.work.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_entry| {
                    const entry = maybe_entry orelse return self.miss(.{ .unresolved = self.plainChain() });
                    // A private core binding is reachable only from core's own
                    // definitions, never by a plain or qualified word.
                    return switch (entry) {
                        .definition => |definition| if (definition.visibility == .private)
                            self.miss(.{ .unresolved = self.plainChain() })
                        else
                            self.finish(.{ .resolved = definition }),
                        .alias => self.follow(context, entry, true),
                    };
                },
            },
            .session_lookup, .image_lookup => switch (self.work.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_entry| {
                    if (maybe_entry) |entry| {
                        if (self.phase == .image_lookup) self.owner_provenance = self.provenance(context);
                        return self.follow(context, entry, false);
                    }
                    return self.beginCore(context, @fromBackingInt(self.name));
                },
            },
            .complete => unreachable,
        };
    }
};

/// Binds one quotation: every top-level unquoted occurrence in a single pass,
/// before any of it executes. Nested quotations and quoted words stay data.
pub const BindingCursor = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    /// Retained by the cursor until the parts take it.
    code: *value.ListHandle,
    targets: []?*env.Definition,
    dependencies: poll.ChunkStack(*env.Definition),
    dependency_count: usize = 0,
    index: u32 = 0,
    resolver: ?Resolver = null,
    collected: ?[]*env.Definition = null,
    collect_index: usize = 0,
    any_target: bool = false,

    pub const Failure = struct {
        index: u32,
        word: u32,
        miss: Miss,
    };
    pub const Result = union(enum) {
        bound: env.Executable.Parts,
        failed: Failure,
    };
    pub const BindProgress = poll.Progress(Result);

    /// `code` is borrowed; the cursor takes its own reference.
    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        code: *value.ListHandle,
    ) error{OutOfMemory}!BindingCursor {
        const length: usize = @intCast(code.length());
        const targets: []?*env.Definition = if (code.kind() == .generic_spine and length != 0)
            try allocator.alloc(?*env.Definition, length)
        else
            &.{};
        heap.incRef(code);
        return .{
            .allocator = allocator,
            .releases = releases,
            .code = code,
            .targets = targets,
            .dependencies = .init(allocator),
        };
    }

    pub fn deinit(self: *BindingCursor) void {
        if (self.resolver) |*resolver| resolver.deinit();
        while (self.dependencies.pop()) |dependency| dependency.release(self.releases);
        self.dependencies.deinit();
        if (self.collected) |collected| {
            for (collected[0..self.collect_index]) |dependency| dependency.release(self.releases);
            self.allocator.free(collected);
        }
        if (self.targets.len != 0) self.allocator.free(self.targets);
        self.releases.releaseHeader(self.code);
        self.* = undefined;
    }

    fn record(self: *BindingCursor, context: *const Context, definition: *env.Definition) error{OutOfMemory}!void {
        self.targets[self.index] = definition;
        self.any_target = true;
        const is_self = if (context.self_reference) |reference| reference.definition == definition else false;
        if (definition.lifetime == .counted and !is_self) {
            try self.dependencies.reserve(1);
            definition.retain();
            self.dependencies.pushReserved(definition);
            self.dependency_count += 1;
        }
    }

    pub fn advance(self: *BindingCursor, context: *const Context, work: *poll.WorkBudget) error{OutOfMemory}!BindProgress {
        while (work.spend()) {
            if (self.resolver) |*resolver| {
                switch (resolver.advance(context)) {
                    .pending => continue,
                    .complete => |outcome| {
                        resolver.deinit();
                        self.resolver = null;
                        switch (outcome) {
                            .resolved => |definition| try self.record(context, definition),
                            .missed => |reason| {
                                const word = heap.valuesConst(self.code)[self.index].symbol.name;
                                return .{ .complete = .{ .failed = .{
                                    .index = self.index,
                                    .word = word,
                                    .miss = reason,
                                } } };
                            },
                        }
                        self.index += 1;
                        continue;
                    },
                }
            }
            if (self.index < self.targets.len) {
                const form = heap.valuesConst(self.code)[self.index];
                if (executableWord(form)) |word| {
                    self.resolver = Resolver.init(context, word);
                    continue;
                }
                self.targets[self.index] = null;
                self.index += 1;
                continue;
            }
            // Materialize the dependency list at its exact size, one per step.
            if (self.collected == null) {
                self.collected = try self.allocator.alloc(*env.Definition, self.dependency_count);
                continue;
            }
            if (self.dependencies.pop()) |dependency| {
                self.collected.?[self.collect_index] = dependency;
                self.collect_index += 1;
                continue;
            }
            const targets: []?*env.Definition = if (self.any_target) self.targets else empty: {
                if (self.targets.len != 0) self.allocator.free(self.targets);
                break :empty &.{};
            };
            const parts: env.Executable.Parts = .{
                .code = self.code,
                .targets = targets,
                .dependencies = self.collected.?,
            };
            self.targets = &.{};
            self.collected = null;
            self.collect_index = 0;
            heap.incRef(self.code);
            return .{ .complete = .{ .bound = parts } };
        }
        return .pending;
    }
};

/// The occurrence a form executes as a word, or null when the form is data:
/// a value, a quoted symbol, or a lowered locals operation.
pub fn executableWord(form: value.Value) ?value.Symbol {
    const word = switch (form) {
        .symbol => |symbol| symbol,
        else => return null,
    };
    if (env.isQuoted(word.slot)) return null;
    if (env.localOperand(word.slot) != null) return null;
    return word;
}
