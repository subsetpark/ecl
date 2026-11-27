//! Name resolution. A word occurrence carries the root and the source it was
//! written in, and resolves there, under that source's view of the module
//! map, against one captured publication view when it is reached.
//! Nothing resolves a word before then: a definition is published without
//! its body being read, so a word that resolves to nothing fails its call.
const std = @import("std");
const value = @import("value.zig");
const poll = @import("poll.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const map_state = @import("module_snapshot.zig");

/// The chain a miss reports.
pub const LookupChain = machine.LookupChain;

/// Everything a resolution reads besides the word: the captured view and how
/// to find modules.
pub const Context = struct {
    environment: *env.Env,
    /// Owned by the context's holder, which releases it with `deinit`.
    view: modules.View,
    module_access: *const modules.ExecutionAccess,
    registry: *modules.Registry,
    project: ?*const map_state.Snapshot,
    libraries: machine.EmbeddedLibraries,

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
    unknown_module_prefix: struct { bytes: []const u8, searcher: modules.RegistrationProvenance },
    /// A well-formed qualified name whose module is not registered, or not
    /// one `searcher` may refer to. A load that follows asks as `searcher`,
    /// the view the lookup searched under, so it fails where the lookup
    /// would miss again.
    unregistered_module: struct { name: intern.ModuleName, searcher: modules.RegistrationProvenance },
    /// The word was written in an image that has since been torn down.
    retired,
    /// Following name aliases did not reach a definition.
    alias_cycle,
};

/// A miss that no module load can turn into a definition.
pub const Unbound = union(enum) {
    unresolved: LookupChain,
    retired,
    alias_cycle,
};

/// What resolving one word produced. Borrowed: valid while the context's
/// view is held.
pub const Outcome = union(enum) {
    resolved: *env.Definition,
    missed: Miss,
};

/// Resolves one word occurrence.
pub const Resolver = struct {
    pub const Progress = poll.Progress(Outcome);

    name: u32,
    root: Root,
    /// The source the word was written in.
    written: modules.RegistrationProvenance,
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
        core_atom,
        core_lookup,
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
        core_lookup: env.CoreMap.RawLookupCursor,

        fn deinit(self: *Work) void {
            switch (self.*) {
                .acquisition => |*cursor| cursor.deinit(),
                .export_lookup => |*cursor| cursor.deinit(),
                .none, .dot, .atom, .module_validation, .binding_validation, .lookup, .core_lookup => {},
            }
            self.* = .none;
        }
    };

    pub fn init(context: *const Context, word: value.Symbol) Resolver {
        const root: Root = switch (env.wordTarget(word.slot)) {
            .unlinked, .local => .core,
            .cell => |id| switch (context.environment.scopeOf(context.environment.place(id).root)) {
                .unscoped, .core => .core,
                .session => .session,
                .cell => |cell| .{ .image = cell },
                .retired => .retired,
            },
        };
        return .{
            .name = word.name,
            .root = root,
            .written = sourceOf(context.environment, word),
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

    fn found(self: *Resolver, definition: *env.Definition) Progress {
        return self.finish(.{ .resolved = definition });
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
        switch (self.root) {
            .retired => return self.miss(.retired),
            .core => return self.beginCore(context, binding),
            .session => {
                const entry = context.view.sessionFind(binding) orelse return self.beginCore(context, binding);
                return self.follow(context, entry, false);
            },
            .image => |cell| {
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

    fn beginCore(self: *Resolver, context: *const Context, binding: intern.BindingName) Progress {
        self.work = .{ .core_lookup = context.environment.coreLookup(binding) };
        self.phase = .core_lookup;
        return .pending;
    }

    /// Follows one directory entry: a definition resolves, and an alias
    /// starts a qualified lookup of its target.
    fn follow(self: *Resolver, context: *const Context, entry: env.Entry, require_public: bool) Progress {
        switch (entry) {
            .definition => |definition| {
                if (require_public and definition.visibility != .public)
                    return self.miss(.{ .unresolved = .qualified });
                return self.found(definition);
            },
            .alias => |alias| return self.followAlias(context, alias, require_public),
        }
    }

    /// Begins the lookup of the export atom after the module part.
    fn beginExportName(self: *Resolver) Progress {
        self.work.deinit();
        self.work = .{ .atom = intern.lookupCursor(self.spelling()[self.dot_index + 1 ..]) };
        self.phase = .export_name;
        return .pending;
    }

    fn followAlias(self: *Resolver, context: *const Context, alias: env.Alias, require_public: bool) Progress {
        if (require_public and alias.visibility != .public)
            return self.miss(.{ .unresolved = .qualified });
        self.prefix = alias.module;
        self.export_name = alias.binding;
        const hop: Hop = .{
            .module = alias.module,
            .binding = alias.binding,
            .provenance = self.provenance(),
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
        self.work = .{ .acquisition = machine.ModuleLookupCursor.initIn(
            &context.view,
            context.registry,
            context.project,
            context.libraries,
            self.provenance(),
            self.prefix.?,
        ) };
        self.phase = .acquire;
        return .pending;
    }

    /// The provenance a qualified name resolves under: the holder's along an
    /// alias chain, the image's own for a word written in one, and otherwise
    /// the source the word was written in. Where the word runs plays no part.
    fn provenance(self: *const Resolver) modules.RegistrationProvenance {
        if (self.owner_provenance) |owner| return owner;
        switch (self.root) {
            .image => |cell| if (cell.scope.load(.acquire)) |scope| {
                if (self.image_pin != null) {
                    if (modules.homeForModuleRootScope(scope)) |home| return home.registrationProvenance();
                }
            },
            else => {},
        }
        return self.written;
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
                    const prefix = maybe_prefix orelse return self.miss(.{ .unknown_module_prefix = .{
                        .bytes = self.spelling()[0..self.dot_index],
                        .searcher = self.provenance(),
                    } });
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
                    return self.beginExportName();
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
                    const generation = maybe_generation orelse return self.miss(.{ .unregistered_module = .{
                        .name = self.prefix.?,
                        .searcher = self.provenance(),
                    } });
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
            .core_atom => switch (self.work.atom.advance()) {
                .pending => .pending,
                .complete => |maybe_export| {
                    const export_id = maybe_export orelse return self.miss(.{ .unresolved = .core });
                    self.work = .{ .core_lookup = context.environment.coreLookup(@fromBackingInt(export_id)) };
                    self.phase = .core_lookup;
                    return .pending;
                },
            },
            .core_lookup => switch (self.work.core_lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_definition| {
                    const definition = maybe_definition orelse return self.miss(.{ .unresolved = self.plainChain() });
                    // A private core binding is reachable only from core's own
                    // definitions, never by a plain or qualified word.
                    if (definition.visibility == .private) return self.miss(.{ .unresolved = self.plainChain() });
                    return self.found(definition);
                },
            },
            .image_lookup => switch (self.work.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_entry| {
                    if (maybe_entry) |entry| {
                        self.owner_provenance = self.provenance();
                        return self.follow(context, entry, false);
                    }
                    return self.beginCore(context, @fromBackingInt(self.name));
                },
            },
            .complete => unreachable,
        };
    }
};

/// The source `word` was written in: what its cell records, and no source for
/// a word that carries no cell.
pub fn sourceOf(environment: *const env.Env, word: value.Symbol) modules.RegistrationProvenance {
    return switch (env.wordTarget(word.slot)) {
        .unlinked, .local => .ordinary,
        .cell => |id| .fromSourceId(environment.place(id).source),
    };
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
