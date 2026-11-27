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
    /// A well-formed qualified name whose module is not registered, or not
    /// one `searcher` may refer to. A load that follows asks as `searcher`,
    /// the view the lookup searched under, so it fails where the lookup
    /// would miss again.
    unregistered_module: struct { name: intern.ModuleName, searcher: modules.RegistrationProvenance },
    /// Following name aliases did not reach a definition.
    alias_cycle,
};

/// A miss that no module load can turn into a definition.
pub const Unbound = union(enum) {
    unresolved: LookupChain,
    alias_cycle,
};

/// What resolving one word produced. Borrowed: valid while the context's
/// view is held.
pub const Outcome = union(enum) {
    resolved: *env.Definition,
    missed: Miss,
};

/// Resolves one word occurrence. What the spelling is was decided when it
/// was interned, so a resolution scans no spelling: it begins at the lookup
/// its spelling selects.
pub const Resolver = struct {
    pub const Progress = poll.Progress(Outcome);

    name: u32,
    root: env.Root,
    /// The source the word was written in.
    written: modules.RegistrationProvenance,
    spelling: intern.Spelling,
    phase: Phase = .begin,
    work: Work = .none,
    /// The module and binding a qualified lookup is of: the word's own
    /// spelling, then each alias followed.
    target: ?env.Alias = null,
    /// The registration whose directory is being read: the word's own
    /// module, or the module a qualified name selected.
    generation: ?modules.GenerationLease = null,
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

    const Phase = enum {
        begin,
        acquire,
        export_lookup,
        core_lookup,
        own_acquire,
        own_lookup,
        complete,
    };

    const Work = union(enum) {
        none,
        acquisition: machine.ModuleLookupCursor,
        own_acquisition: modules.Registry.AcquireCursor,
        export_lookup: modules.ModuleNameLookupCursor,
        core_lookup: env.CoreMap.RawLookupCursor,

        fn deinit(self: *Work) void {
            switch (self.*) {
                .acquisition => |*cursor| cursor.deinit(),
                .own_acquisition => |*cursor| cursor.deinit(),
                .export_lookup => |*cursor| cursor.deinit(),
                .none, .core_lookup => {},
            }
            self.* = .none;
        }
    };

    pub fn init(context: *const Context, word: value.Symbol) Resolver {
        const environment = context.environment;
        return switch (env.wordTarget(word.slot)) {
            // A word with no cell reads what its interned name records.
            .unlinked, .local => .{
                .name = word.name,
                .root = .core,
                .written = .ordinary,
                .spelling = intern.spelling(word.name),
            },
            .cell => |id| cell: {
                const place = environment.place(id);
                break :cell .{
                    .name = word.name,
                    .root = environment.scopeOf(place.root),
                    .written = .fromSourceId(place.source),
                    .spelling = environment.spelling(id),
                };
            },
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.work.deinit();
        if (self.generation) |*lease| lease.deinit();
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

    fn plainChain(self: *const Resolver) LookupChain {
        return switch (self.root) {
            .core => .core,
            .session => .session,
            .module => .module,
        };
    }

    /// Begins the plain lookup of the word's own name in its root.
    fn beginPlain(self: *Resolver, context: *const Context) Progress {
        const binding: intern.BindingName = @fromBackingInt(self.name);
        switch (self.root) {
            .core => return self.beginCore(context, binding),
            .session => {
                const entry = context.view.sessionFind(binding) orelse return self.beginCore(context, binding);
                return self.follow(context, entry, false);
            },
            // The word's own module is found by name with no visibility
            // check: it is the module the word was written in.
            .module => |name| {
                self.work = .{ .own_acquisition = context.view.acquireCursor(name) };
                self.phase = .own_acquire;
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
    /// resolves as the qualified name it records.
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

    fn followAlias(self: *Resolver, context: *const Context, alias: env.Alias, require_public: bool) Progress {
        if (require_public and alias.visibility != .public)
            return self.miss(.{ .unresolved = .qualified });
        // `core` is a scope, not a registration: an alias into it resolves
        // as the spelling `core.x` does.
        if (intern.isReservedRegistryBytes(intern.get(intern.moduleId(alias.module)))) {
            self.work.deinit();
            self.root = .core;
            return self.beginCore(context, alias.binding);
        }
        self.target = alias;
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
        if (self.generation) |*lease| lease.deinit();
        self.generation = null;
        self.work.deinit();
        self.work = .{ .acquisition = machine.ModuleLookupCursor.initIn(
            &context.view,
            context.registry,
            context.project,
            context.libraries,
            self.provenance(),
            self.target.?.module,
        ) };
        self.phase = .acquire;
        return .pending;
    }

    /// The provenance a qualified name resolves under: the holder's along an
    /// alias chain, and otherwise the source the word was written in. Where
    /// the word runs plays no part.
    fn provenance(self: *const Resolver) modules.RegistrationProvenance {
        return self.owner_provenance orelse self.written;
    }

    pub fn advance(self: *Resolver, context: *const Context) Progress {
        return switch (self.phase) {
            .begin => switch (self.spelling) {
                .plain => self.beginPlain(context),
                .core => |binding| core: {
                    self.root = .core;
                    break :core self.beginCore(context, binding);
                },
                .qualified => |parts| qualified: {
                    self.target = .{ .module = parts.module, .binding = parts.binding };
                    break :qualified self.beginAcquire(context);
                },
                .malformed => self.miss(.{ .unresolved = .qualified }),
            },
            .acquire => switch (self.work.acquisition.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| {
                    self.work.deinit();
                    const generation = maybe_generation orelse return self.miss(.{ .unregistered_module = .{
                        .name = self.target.?.module,
                        .searcher = self.provenance(),
                    } });
                    self.generation = generation;
                    self.work = .{ .export_lookup = generation.lookupCursor(self.target.?.binding) };
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
            .own_acquire => switch (self.work.own_acquisition.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| {
                    self.work.deinit();
                    const binding: intern.BindingName = @fromBackingInt(self.name);
                    const generation = maybe_generation orelse return self.beginCore(context, binding);
                    self.generation = generation;
                    self.work = .{ .export_lookup = generation.lookupCursor(binding) };
                    self.phase = .own_lookup;
                    return .pending;
                },
            },
            .own_lookup => switch (self.work.export_lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_entry| {
                    const entry = maybe_entry orelse {
                        self.work.deinit();
                        return self.beginCore(context, @fromBackingInt(self.name));
                    };
                    self.owner_provenance = self.generation.?.provenance();
                    return self.follow(context, entry, false);
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
