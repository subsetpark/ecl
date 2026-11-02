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
    /// The group's construction directory. Null until the group's staged
    /// names have become it.
    directory: ?*const env.GroupMap,
};

/// A top-level definition being constructed: a word written in the root it is
/// published into and spelling its name calls the definition itself.
pub const SelfReference = struct {
    root: env.ScopeId,
    name: u32,
    reservation: *env.Reservation,
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
    /// Construction in progress. Only a binding resolver reads these; an
    /// explicit lookup's context leaves them null.
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

/// Whether a resolution serves an explicit lookup, which can only reach
/// sealed definitions, or a binding, which may also reach a reservation of
/// the construction in progress.
pub const Mode = enum { lookup, binding };

/// What resolving one word produced. Borrowed: valid while the context's
/// view is held.
pub fn OutcomeIn(comptime mode: Mode) type {
    return union(enum) {
        resolved: switch (mode) {
            .lookup => *env.Definition,
            .binding => env.Target,
        },
        missed: Miss,
    };
}

/// An explicit lookup's outcome: a sealed definition or a miss.
pub const Outcome = OutcomeIn(.lookup);
/// Resolves one word for an explicit lookup.
pub const Resolver = ResolverIn(.lookup);

/// Resolves one word occurrence.
pub fn ResolverIn(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        pub const Result = OutcomeIn(mode);
        pub const Progress = poll.Progress(Result);

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
        /// Whether the occurrence or alias being resolved belongs to the group
        /// under construction. Only then does the group's own module name mean
        /// the group; anything else names the registered module.
        group_owned: bool = false,
        /// Brent's cycle detection over alias hops: a hop that repeats the saved
        /// one proves a cycle, and the saved hop moves forward at each power of
        /// two. An acyclic chain of any length still resolves.
        saved_hop: ?Hop = null,
        hops: u64 = 0,
        hop_power: u64 = 1,

        /// Everything the next hop's result depends on.
        const Hop = struct {
            module: intern.ModuleName,
            binding: intern.BindingName,
            provenance: modules.RegistrationProvenance,
            group_owned: bool,
        };

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
            group_image_lookup,
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
            group_lookup: env.GroupMap.RawLookupCursor,

            fn deinit(self: *Work) void {
                switch (self.*) {
                    .acquisition => |*cursor| cursor.deinit(),
                    .export_lookup => |*cursor| cursor.deinit(),
                    .none, .dot, .atom, .module_validation, .binding_validation, .lookup, .group_lookup => {},
                }
                self.* = .none;
            }
        };

        pub fn init(context: *const Context, word: value.Symbol) Self {
            const root: Root = switch (env.wordTarget(word.slot)) {
                .unlinked, .local => .core,
                .root => |id| switch (context.environment.scopeOf(id)) {
                    .unscoped, .core => .core,
                    .session => .session,
                    .cell => |cell| .{ .image = cell },
                    .retired => .retired,
                },
            };
            const group_owned = mode == .binding and switch (root) {
                .image => |cell| if (context.group) |group| group.image_scope == cell.id else false,
                else => false,
            };
            return .{
                .name = word.name,
                .root = root,
                .group_owned = group_owned,
                .work = .{ .dot = intern.lastDotCursor(intern.get(word.name)) },
            };
        }

        pub fn deinit(self: *Self) void {
            self.work.deinit();
            if (self.generation) |*lease| lease.deinit();
            if (self.image_pin) |*pin| pin.deinit();
            self.* = undefined;
        }

        fn finish(self: *Self, outcome: Result) Progress {
            self.work.deinit();
            self.phase = .complete;
            return .{ .complete = outcome };
        }

        fn miss(self: *Self, reason: Miss) Progress {
            return self.finish(.{ .missed = reason });
        }

        /// Whether the group under construction owns what is being resolved:
        /// comptime-false for an explicit lookup, so a lookup never compiles the
        /// paths that could reach a reservation.
        inline fn groupOwned(self: *const Self) bool {
            return mode == .binding and self.group_owned;
        }

        fn found(self: *Self, definition: *env.Definition) Progress {
            return self.finish(.{ .resolved = switch (mode) {
                .lookup => definition,
                .binding => .{ .definition = definition },
            } });
        }

        fn spelling(self: *const Self) []const u8 {
            return intern.get(self.name);
        }

        fn plainChain(self: *const Self) LookupChain {
            return switch (self.root) {
                .core, .retired => .core,
                .session => .session,
                .image => .module,
            };
        }

        /// Begins the plain lookup of the word's own name in its root.
        fn beginPlain(self: *Self, context: *const Context) Progress {
            const binding: intern.BindingName = @fromBackingInt(self.name);
            if (mode == .binding) if (context.self_reference) |reference| {
                if (reference.name == self.name and self.writtenIn(context, reference.root))
                    return self.finish(.{ .resolved = .{ .reserved = reference.reservation } });
            };
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
                    if (self.groupOwned()) {
                        self.work = .{ .group_lookup = context.group.?.directory.?.rawLookup(binding) };
                        self.phase = .group_image_lookup;
                        return .pending;
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

        fn writtenIn(self: *const Self, context: *const Context, root: env.ScopeId) bool {
            return switch (self.root) {
                .core => root == context.environment.coreScopeId(),
                .session => root == context.environment.sessionScopeId(),
                .image => |cell| cell.id == root,
                .retired => false,
            };
        }

        fn beginCore(self: *Self, context: *const Context, binding: intern.BindingName) Progress {
            self.work = .{ .lookup = context.environment.coreLookup(binding) };
            self.phase = .core_lookup;
            return .pending;
        }

        /// Follows one directory entry: a definition resolves, an alias starts a
        /// qualified lookup of its target.
        fn follow(self: *Self, context: *const Context, entry: env.Entry, require_public: bool) Progress {
            switch (entry) {
                .definition => |definition| {
                    if (require_public and definition.visibility != .public)
                        return self.miss(.{ .unresolved = .qualified });
                    return self.found(definition);
                },
                .alias => |alias| return self.followAlias(context, alias, require_public),
            }
        }

        /// Follows one entry of the group under construction.
        fn followGroup(self: *Self, context: *const Context, entry: env.GroupEntry, require_public: bool) Progress {
            comptime std.debug.assert(mode == .binding);
            switch (entry) {
                .reserved => |reservation| {
                    if (require_public and reservation.visibility() != .public)
                        return self.miss(.{ .unresolved = .qualified });
                    return self.finish(.{ .resolved = .{ .reserved = reservation } });
                },
                .definition => |definition| return self.follow(context, .{ .definition = definition }, require_public),
                .alias => |alias| return self.followAlias(context, alias, require_public),
            }
        }

        fn followAlias(self: *Self, context: *const Context, alias: env.Alias, require_public: bool) Progress {
            if (require_public and alias.visibility != .public)
                return self.miss(.{ .unresolved = .qualified });
            self.prefix = alias.module;
            self.export_name = alias.binding;
            const hop: Hop = .{
                .module = alias.module,
                .binding = alias.binding,
                .provenance = self.provenance(context),
                .group_owned = self.group_owned,
            };
            if (self.saved_hop) |saved| if (std.meta.eql(saved, hop)) return self.miss(.alias_cycle);
            self.hops += 1;
            if (self.hops == self.hop_power) {
                self.saved_hop = hop;
                self.hop_power *|= 2;
                self.hops = 0;
            }
            return self.beginAcquire(context);
        }

        fn beginAcquire(self: *Self, context: *const Context) Progress {
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
            if (context.group) |group| if (self.groupOwned() and group.module == self.prefix.?) {
                const export_name = self.export_name orelse return self.miss(.{ .unresolved = .qualified });
                self.work = .{ .group_lookup = group.directory.?.rawLookup(export_name) };
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
        fn provenance(self: *const Self, context: *const Context) modules.RegistrationProvenance {
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

        pub fn advance(self: *Self, context: *const Context) Progress {
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
                        self.group_owned = false;
                        return self.follow(context, entry, true);
                    },
                },
                // Entered only where `groupOwned` holds, which an explicit
                // lookup never compiles.
                .group_export => if (mode == .lookup) unreachable else switch (self.work.group_lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_entry| {
                        const entry = maybe_entry orelse return self.miss(.{ .unresolved = .qualified });
                        return self.followGroup(context, entry, true);
                    },
                },
                .group_image_lookup => if (mode == .lookup) unreachable else switch (self.work.group_lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_entry| {
                        if (maybe_entry) |entry| {
                            self.owner_provenance = self.provenance(context);
                            return self.followGroup(context, entry, false);
                        }
                        return self.beginCore(context, @fromBackingInt(self.name));
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
                                self.found(definition),
                            .alias => alias: {
                                self.group_owned = false;
                                break :alias self.follow(context, entry, true);
                            },
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
}

/// Binds one quotation: every top-level unquoted occurrence in a single pass,
/// before any of it executes. Nested quotations and quoted words stay data.
///
/// Targets are borrowed while binding runs: the context's view keeps every
/// definition it resolves alive. A counted target is noted once in a
/// `DependencySet` whose capacity the forms still to bind bound, so it never
/// grows or rehashes; clearing it and probing it are cursors that charge the
/// unit's budget one slot at a time. Only when the walk completes does the
/// cursor create the exact-size dependency table and take one reference per
/// distinct target, one per step. Until then the cursor owns no references,
/// and afterwards it owns them only through that table, which retires as its
/// own owner: abandoning a cursor at any point is constant work.
pub const BindingCursor = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    /// Retained by the cursor until the bound body takes it.
    code: *value.ListHandle,
    targets: []?*const env.Slot,
    index: u32 = 0,
    any_target: bool = false,
    step: Step = .walk,
    seen: ?env.DependencySet = null,
    dependencies: ?*env.DependencyTable = null,

    const Step = union(enum) {
        walk,
        resolve: ResolverIn(.binding),
        /// Making the set on the first counted target, then noting it.
        open_set: struct { cursor: env.DependencySet.InitCursor, definition: *env.Definition },
        note: env.DependencySet.PutCursor,
        collect: env.DependencySet.RawEntryCursor,

        fn deinit(self: *Step) void {
            switch (self.*) {
                .resolve => |*resolver| resolver.deinit(),
                .open_set => |*open| open.cursor.deinit(),
                .walk, .note, .collect => {},
            }
            self.* = .walk;
        }
    };

    pub const Failure = struct {
        index: u32,
        word: u32,
        miss: Miss,
    };
    pub const Result = union(enum) {
        bound: env.Bound,
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
        const targets: []?*const env.Slot = if (code.kind() == .generic_spine and length != 0)
            try allocator.alloc(?*const env.Slot, length)
        else
            &.{};
        heap.incRef(code);
        return .{
            .allocator = allocator,
            .releases = releases,
            .code = code,
            .targets = targets,
        };
    }

    pub fn deinit(self: *BindingCursor) void {
        self.step.deinit();
        if (self.seen) |*seen| seen.deinit();
        if (self.dependencies) |dependencies| dependencies.retire(self.releases);
        if (self.targets.len != 0) self.allocator.free(self.targets);
        self.releases.releaseHeader(self.code);
        self.* = undefined;
    }

    /// Records the target bound at the current position; a counted one
    /// starts noting it as a dependency, which the following steps finish.
    fn record(self: *BindingCursor, target: env.Target) void {
        self.targets[self.index] = target.slot();
        self.any_target = true;
        self.index += 1;
        const definition = switch (target) {
            .definition => |definition| definition,
            // A reservation is this construction's own, never a dependency.
            .reserved => return,
        };
        if (definition.lifetime != .counted) return;
        if (self.seen) |*seen| {
            self.step = .{ .note = seen.putCursor(.of(definition), {}) };
            return;
        }
        // Every counted target still to come is at or after this position.
        const remaining = self.targets.len - (self.index - 1);
        self.step = .{ .open_set = .{
            .cursor = env.DependencySet.initCursor(self.allocator, remaining),
            .definition = definition,
        } };
    }

    pub fn advance(self: *BindingCursor, context: *const Context, work: *poll.WorkBudget) error{OutOfMemory}!BindProgress {
        while (work.spend()) switch (self.step) {
            .resolve => |*resolver| switch (resolver.advance(context)) {
                .pending => {},
                .complete => |outcome| {
                    self.step.deinit();
                    switch (outcome) {
                        .resolved => |target| self.record(target),
                        .missed => |reason| {
                            const word = heap.valuesConst(self.code)[self.index].symbol.name;
                            return .{ .complete = .{ .failed = .{
                                .index = self.index,
                                .word = word,
                                .miss = reason,
                            } } };
                        },
                    }
                },
            },
            .open_set => |*open| switch (try open.cursor.advance()) {
                .pending => {},
                .complete => |set| {
                    const definition = open.definition;
                    self.seen = set;
                    self.step = .{ .note = self.seen.?.putCursor(.of(definition), {}) };
                },
            },
            .note => |*put| switch (put.advance()) {
                .pending => {},
                .complete => self.step = .walk,
            },
            .collect => |*entries| switch (entries.advance()) {
                .pending => {},
                .item => |entry| self.dependencies.?.hold(entry.key.definition()),
                .complete => {
                    self.step = .walk;
                    self.seen.?.deinit();
                    self.seen = null;
                },
            },
            .walk => {
                if (self.index < self.targets.len) {
                    const form = heap.valuesConst(self.code)[self.index];
                    if (executableWord(form)) |word| {
                        self.step = .{ .resolve = ResolverIn(.binding).init(context, word) };
                        continue;
                    }
                    self.targets[self.index] = null;
                    self.index += 1;
                    continue;
                }
                // Hold each distinct counted target once, in an exact-size table.
                if (self.seen) |*seen| {
                    self.dependencies = try env.DependencyTable.create(self.allocator, seen.count());
                    self.step = .{ .collect = seen.rawEntries() };
                    continue;
                }
                const targets: []?*const env.Slot = if (self.any_target) self.targets else empty: {
                    if (self.targets.len != 0) self.allocator.free(self.targets);
                    break :empty &.{};
                };
                const bound: env.Bound = .{
                    .code = self.code,
                    .targets = targets,
                    .dependencies = self.dependencies,
                };
                self.targets = &.{};
                self.dependencies = null;
                heap.incRef(self.code);
                return .{ .complete = .{ .bound = bound } };
            },
        };
        return .pending;
    }
};

/// The most forms `bindReused` binds in one step. A constant, so the inline
/// path is bounded work however it is used.
pub const reused_binding_limit = 16;

/// Binds a short quotation in one step from words its unit has already
/// resolved, or returns null when any executable word is not in `cache`,
/// leaving the full binder to resolve it. `cache.find(word)` returns what the
/// word resolved to in the publication and provenance this binding would see,
/// which is what the resolver would produce: an anonymous binding has no
/// construction in progress, so binding a word is exactly looking it up. The
/// cache keeps what it returns alive until this binding holds it.
pub fn bindReused(
    allocator: std.mem.Allocator,
    code: *value.ListHandle,
    cache: anytype,
) error{OutOfMemory}!?env.Bound {
    const length: usize = @intCast(code.length());
    std.debug.assert(length <= reused_binding_limit);
    if (code.kind() != .generic_spine or length == 0) {
        heap.incRef(code);
        return .{ .code = code, .targets = &.{}, .dependencies = null };
    }
    var found: [reused_binding_limit]?*env.Definition = @splat(null);
    var distinct: [reused_binding_limit]*env.Definition = undefined;
    var distinct_count: usize = 0;
    var any_target = false;
    for (heap.valuesConst(code)[0..length], 0..) |form, index| {
        const word = executableWord(form) orelse continue;
        const definition = cache.find(word) orelse return null;
        found[index] = definition;
        any_target = true;
        if (definition.lifetime != .counted) continue;
        for (distinct[0..distinct_count]) |held| {
            if (held == definition) break;
        } else {
            distinct[distinct_count] = definition;
            distinct_count += 1;
        }
    }
    if (!any_target) {
        heap.incRef(code);
        return .{ .code = code, .targets = &.{}, .dependencies = null };
    }
    const targets = try allocator.alloc(?*const env.Slot, length);
    errdefer allocator.free(targets);
    for (found[0..length], targets) |definition, *target| {
        target.* = if (definition) |held| env.Target.slot(.{ .definition = held }) else null;
    }
    const dependencies: ?*env.DependencyTable = if (distinct_count == 0) null else held: {
        const table = try env.DependencyTable.create(allocator, distinct_count);
        for (distinct[0..distinct_count]) |definition| table.hold(definition);
        break :held table;
    };
    heap.incRef(code);
    return .{ .code = code, .targets = targets, .dependencies = dependencies };
}

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
