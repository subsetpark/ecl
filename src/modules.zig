//! Per-session module registry with typed names and atomic generation publication.
const std = @import("std");
const env = @import("env.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const native_module = @import("native_module.zig");
const poll = @import("poll.zig");
const snapshot_api = @import("snapshot.zig");

pub const ModuleGeneration = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    name: intern.NamespaceName,
    generation: u64 = 0,
    environment: env.Environment,
    scope: env.Scope,
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: union(enum) {
        live,
        scope: env.Scope.EmbeddedTeardownCursor,
        environment: env.Environment.TeardownCursor,
    } = .live,

    pub fn create(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        name: intern.NamespaceName,
    ) error{OutOfMemory}!*ModuleGeneration {
        const result = try allocator.create(ModuleGeneration);
        result.allocator = allocator;
        result.refs = .init(1);
        result.name = name;
        result.generation = 0;
        result.environment = env.Environment.init(allocator, releases);
        result.scope = env.Scope.moduleRoot(allocator, &result.environment, name);
        result.retirement = .{};
        result.retirement_state = .live;
        return result;
    }

    pub fn retain(self: *ModuleGeneration) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    pub fn release(self: *ModuleGeneration) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        self.retirement_state = .{ .scope = .init(&self.scope) };
        self.environment.releases.retire(self, &self.retirement);
    }

    pub fn advanceRetirement(
        _: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *ModuleGeneration,
    ) bool {
        return switch (self.retirement_state) {
            .live => unreachable,
            .scope => |*scope| result: {
                if (!scope.advance()) break :result false;
                self.retirement_state = .{ .environment = .init(&self.environment) };
                break :result false;
            },
            .environment => |*environment| {
                if (!environment.advance()) return false;
                allocator.destroy(self);
                return true;
            },
        };
    }

    pub fn resolve(
        self: *const ModuleGeneration,
        id: u32,
        public_only: bool,
    ) ?env.BindingLease {
        var cursor = self.resolveCursor(id, public_only);
        defer cursor.deinit();
        return poll.drive(?env.BindingLease, &cursor, .{});
    }

    pub const ResolveProgress = poll.Progress(?env.BindingLease);
    pub const ResolveCursor = struct {
        allocator: std.mem.Allocator,
        public_only: bool,
        lookup: env.DirectLookupCursor,
        pin: GenerationPin,

        pub fn deinit(self: *ResolveCursor) void {
            self.lookup.deinit();
            self.pin.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *ResolveCursor) ResolveProgress {
            return switch (self.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    var lease = maybe_lease orelse break :result .{ .complete = null };
                    if (self.public_only and lease.visibility == .private) {
                        lease.deinit();
                        break :result .{ .complete = null };
                    }
                    break :result .{ .complete = lease };
                },
            };
        }
    };
    pub fn resolveCursor(
        self: *const ModuleGeneration,
        id: u32,
        public_only: bool,
    ) ResolveCursor {
        const home = ModuleHome.init(@constCast(self));
        return .{
            .allocator = self.allocator,
            .public_only = public_only,
            .lookup = self.environment.directLookupCursor(id),
            .pin = home.pinInternal(),
        };
    }

    pub fn publicNamesOwned(
        self: *const ModuleGeneration,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u32 {
        var visible = poll.ChunkList(u32).init(allocator);
        defer visible.retire(self.environment.releases);
        var cursor = self.publicNameCursor();
        defer cursor.deinit();
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => break,
            .item => |id| try visible.append(id),
        };
        const result = try allocator.alloc(u32, visible.count);
        errdefer allocator.free(result);
        var iterator = visible.iterator();
        var index: usize = 0;
        while (iterator.next()) |id| : (index += 1) result[index] = id.*;
        return result;
    }

    pub const PublicNameProgress = poll.StreamProgress(u32);
    pub const PublicNameCursor = struct {
        allocator: std.mem.Allocator,
        inner: env.NameCursor,
        pin: GenerationPin,
        pub fn deinit(self: *PublicNameCursor) void {
            self.inner.deinit();
            self.pin.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *PublicNameCursor) PublicNameProgress {
            return switch (self.inner.advance()) {
                .pending => .pending,
                .complete => .complete,
                .item => |entry| result: {
                    var lease = entry.lease;
                    defer lease.deinit();
                    break :result if (lease.visibility == .public)
                        .{ .item = entry.name }
                    else
                        .pending;
                },
            };
        }
    };
    pub fn publicNameCursor(self: *const ModuleGeneration) PublicNameCursor {
        const home = ModuleHome.init(@constCast(self));
        return .{
            .allocator = self.allocator,
            .inner = self.environment.nameCursor(),
            .pin = home.pinInternal(),
        };
    }
};

const GenerationPublisher = snapshot_api.Publisher(ModuleGeneration);
const ModuleSlot = struct {
    publisher: GenerationPublisher = .init(null),

    fn destroy(self: *ModuleSlot, allocator: std.mem.Allocator) void {
        if (self.publisher.currentOwned()) |generation| generation.release();
        allocator.destroy(self);
    }
};

const Directory = struct {
    const ModuleMap = poll.FixedMap(intern.NamespaceName, *ModuleSlot);
    const AliasMap = poll.FixedMap(intern.NamespaceName, intern.NamespaceName);

    modules: ModuleMap,
    aliases: AliasMap,
    previous: ?*Directory,
    retirement: heap.ReleaseDomain.Retirement = .{},

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Directory,
    ) bool {
        const previous = self.previous;
        self.modules.deinit();
        self.aliases.deinit();
        allocator.destroy(self);
        if (previous) |next| releases.retire(next, &next.retirement);
        return true;
    }

    fn destroy(self: *Directory, allocator: std.mem.Allocator) void {
        self.modules.deinit();
        self.aliases.deinit();
        allocator.destroy(self);
    }

    fn destroyChain(first: ?*Directory, allocator: std.mem.Allocator) void {
        var cursor = first;
        while (cursor) |directory| {
            cursor = directory.previous;
            directory.destroy(allocator);
        }
    }
};
const DirectoryPublisher = snapshot_api.Publisher(Directory);

const DirectoryLease = struct {
    registry: *const Registry,
    lease: DirectoryPublisher.Lease,
    directory: ?*const Directory,

    fn deinit(self: *DirectoryLease) void {
        const registry = @constCast(self.registry);
        if (self.lease.deinit()) {
            registry.lockBlocking();
            const retired = registry.detachRetiredDirectories();
            registry.unlock();
            if (retired) |first| registry.releaseDomain().retire(first, &first.retirement);
        }
        self.* = undefined;
    }
};

/// Session-owned authority required to turn observation state into frame
/// execution state. Session and Unit storage own the seal; registered native
/// callbacks never receive it.
pub const ExecutionAccess = opaque {};

/// Narrow identity used by executing frames. Observation leases never expose
/// this pointer; only code holding the Session's execution authority can
/// obtain its scope or create another lifetime pin.
pub const ModuleHome = opaque {
    fn init(module_generation: *ModuleGeneration) *ModuleHome {
        return @ptrCast(module_generation);
    }
    fn generation(self: *const ModuleHome) *ModuleGeneration {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn scope(self: *const ModuleHome, _: *const ExecutionAccess) *env.Scope {
        return &self.generation().scope;
    }
    pub fn name(self: *const ModuleHome) intern.NamespaceName {
        return self.generation().name;
    }
    pub fn generationNumber(self: *const ModuleHome) u64 {
        return self.generation().generation;
    }
    fn pinInternal(self: *const ModuleHome) GenerationPin {
        const retained = self.generation();
        retained.retain();
        return .initRetained(retained);
    }
    pub fn pin(self: *const ModuleHome, _: *const ExecutionAccess) GenerationPin {
        return self.pinInternal();
    }
};

/// An owned generation reference. The raw generation is never exposed, so a
/// pin can only be consumed by `deinit` and cannot invoke retirement directly.
pub const GenerationPin = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(generation: *ModuleGeneration) GenerationPin {
        return @enumFromInt(@intFromPtr(generation));
    }
    fn home(self: GenerationPin) *ModuleHome {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn deinit(self: *GenerationPin) void {
        if (self.* == .consumed) return;
        self.home().generation().release();
        self.* = .consumed;
    }
    pub fn matches(
        self: GenerationPin,
        expected_home: *const ModuleHome,
        _: *const ExecutionAccess,
    ) bool {
        return self.home() == expected_home;
    }
};

/// Opaque observation capability owning one generation reference.
pub const GenerationLease = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(retained_generation: *ModuleGeneration) GenerationLease {
        return @enumFromInt(@intFromPtr(retained_generation));
    }
    fn generation(self: GenerationLease) *ModuleGeneration {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn generationNumber(self: GenerationLease) u64 {
        return self.generation().generation;
    }
    pub fn name(self: GenerationLease) intern.NamespaceName {
        return self.generation().name;
    }
    pub fn resolveCursor(self: GenerationLease, id: u32, public_only: bool) ModuleGeneration.ResolveCursor {
        return self.generation().resolveCursor(id, public_only);
    }
    pub fn publicNameCursor(self: GenerationLease) ModuleGeneration.PublicNameCursor {
        return self.generation().publicNameCursor();
    }
    pub fn enterExecution(
        self: *GenerationLease,
        _: *const ExecutionAccess,
    ) ExecutionGeneration {
        const generation_ptr = self.generation();
        self.* = .consumed;
        return .initRetained(generation_ptr);
    }
    pub fn deinit(self: *GenerationLease) void {
        if (self.* == .consumed) return;
        self.generation().release();
        self.* = .consumed;
    }
};

/// Session-gated execution capability. Observation can be transferred into
/// execution only by code holding the Session-private authority, and
/// the raw generation remains hidden on both sides of the transition.
pub const ExecutionGeneration = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(generation_ptr: *ModuleGeneration) ExecutionGeneration {
        return @enumFromInt(@intFromPtr(generation_ptr));
    }
    fn generation(self: ExecutionGeneration) *ModuleGeneration {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn home(
        self: ExecutionGeneration,
        _: *const ExecutionAccess,
    ) *ModuleHome {
        return .init(self.generation());
    }
    pub fn deinit(self: *ExecutionGeneration) void {
        if (self.* == .consumed) return;
        self.generation().release();
        self.* = .consumed;
    }
};

/// Unique ownership of an unpublished module generation. Publication consumes
/// the capability; every other exit calls `deinit` without ownership flags.
pub const OwnedCandidate = enum(usize) {
    consumed = 0,
    _,

    fn init(generation: *ModuleGeneration) OwnedCandidate {
        return @enumFromInt(@intFromPtr(generation));
    }
    fn borrow(self: *const OwnedCandidate) *ModuleGeneration {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }
    pub fn executionHome(
        self: *const OwnedCandidate,
        _: *const ExecutionAccess,
    ) *ModuleHome {
        return .init(self.borrow());
    }
    pub fn executionScope(
        self: *const OwnedCandidate,
        _: *const ExecutionAccess,
    ) *env.Scope {
        return &self.borrow().scope;
    }
    pub fn publishDefinition(
        self: *const OwnedCandidate,
        name: intern.NamespaceName,
        publication: env.ModulePublication,
    ) env.BindError!*env.BindingCell {
        return self.borrow().scope.publishModule(name, publication);
    }
    pub fn move(self: *OwnedCandidate) OwnedCandidate {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn deinit(self: *OwnedCandidate) void {
        if (self.* == .consumed) return;
        // The provisional owner is one lifetime guard, not a uniqueness
        // assertion. Tasks spawned before commit hold independent generation
        // pins, so rollback drops only this capability and the generation
        // remains alive until those tasks and their child scopes quiesce.
        self.borrow().release();
        self.* = .consumed;
    }
    fn publish(self: *OwnedCandidate) *ModuleGeneration {
        const generation = self.borrow();
        self.* = .consumed;
        return generation;
    }
};

pub const RegistryError = error{ OutOfMemory, Ecl, NameConflict, MissingModule, InvalidDefinition };

const LoadingNode = struct {
    registry: *Registry,
    name: u32,
    active: std.atomic.Value(bool) = .init(true),
    next: ?*LoadingNode,
};
pub const LoadingLease = enum(usize) {
    finished = 0,
    _,

    fn init(loading: *LoadingNode) LoadingLease {
        return @enumFromInt(@intFromPtr(loading));
    }
    fn node(self: LoadingLease) *LoadingNode {
        std.debug.assert(self != .finished);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn move(self: *LoadingLease) LoadingLease {
        const result = self.*;
        std.debug.assert(result != .finished);
        self.* = .finished;
        return result;
    }
    pub fn finish(self: *LoadingLease) void {
        const loading = self.node();
        loading.active.store(false, .release);
        self.* = .finished;
    }
    pub fn deinit(self: *LoadingLease) void {
        if (self.* == .finished) return;
        const loading = self.node();
        loading.active.store(false, .release);
        self.* = .finished;
    }
};
const RetiredGeneration = struct {
    slot: *ModuleSlot,
    generation: ?*ModuleGeneration,
    next_free: ?*RetiredGeneration = null,
};

const RegistryState = struct {
    host: *const heap.HostCleanup,
    writer: std.Io.Mutex = .init,
    directories: DirectoryPublisher,
    slots: poll.ChunkList(*ModuleSlot),
    retired: poll.ChunkList(RetiredGeneration),
    retired_free: ?*RetiredGeneration = null,
    loading: std.atomic.Value(?*LoadingNode) = .init(null),
};

pub const Registry = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Registry) *RegistryState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    pub fn init(host: *const heap.HostCleanup) error{OutOfMemory}!Registry {
        const owner_allocator = host.allocator();
        const backing = try owner_allocator.create(RegistryState);
        backing.* = .{
            .host = host,
            .directories = .init(null),
            .slots = .init(owner_allocator),
            .retired = .init(owner_allocator),
        };
        return @enumFromInt(@intFromPtr(backing));
    }

    fn allocator(self: *const Registry) std.mem.Allocator {
        return self.privateState().host.allocator();
    }

    fn releaseDomain(self: *const Registry) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    pub fn deinit(self: *Registry) void {
        const backing = self.privateState();
        const owner_allocator = backing.host.allocator();
        std.debug.assert(backing.directories.quiescent());
        Directory.destroyChain(backing.directories.currentOwned(), self.allocator());
        var slots = backing.slots.iterator();
        while (slots.next()) |slot| slot.*.destroy(self.allocator());
        backing.slots.retire(self.releaseDomain());
        var retired = backing.retired.iterator();
        while (retired.next()) |entry| if (entry.generation) |generation| generation.release();
        backing.retired.retire(self.releaseDomain());
        var loading = backing.loading.load(.acquire);
        while (loading) |node| {
            loading = node.next;
            self.allocator().destroy(node);
        }
        backing.host.drain();
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }

    fn lockBlocking(self: *Registry) void {
        std.Io.Threaded.mutexLock(&self.privateState().writer);
    }

    fn unlock(self: *Registry) void {
        std.Io.Threaded.mutexUnlock(&self.privateState().writer);
    }

    fn acquireDirectory(self: *const Registry) DirectoryLease {
        const lease = self.privateState().directories.acquire();
        return .{
            .registry = self,
            .directory = lease.snapshot,
            .lease = lease,
        };
    }

    pub const NamespaceProgress = poll.StreamProgress(intern.NamespaceName);
    /// Snapshot-owning enumeration of canonical module and alias names. The
    /// directory representation remains private and the lease survives until
    /// the cursor is explicitly released, including when iteration is
    /// abandoned early.
    pub const NamespaceCursor = struct {
        directory: DirectoryLease,
        phase: enum { modules, aliases, complete } = .modules,
        modules: ?Directory.ModuleMap.RawEntryCursor = null,
        aliases: ?Directory.AliasMap.RawEntryCursor = null,

        pub fn deinit(self: *NamespaceCursor) void {
            self.directory.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NamespaceCursor) NamespaceProgress {
            while (true) switch (self.phase) {
                .modules => {
                    const entries = &(self.modules orelse {
                        self.phase = .aliases;
                        continue;
                    });
                    switch (entries.advance()) {
                        .pending => return .pending,
                        .item => |entry| return .{ .item = entry.key },
                        .complete => {
                            self.modules = null;
                            self.phase = .aliases;
                        },
                    }
                },
                .aliases => {
                    const entries = &(self.aliases orelse {
                        self.phase = .complete;
                        return .complete;
                    });
                    switch (entries.advance()) {
                        .pending => return .pending,
                        .item => |entry| return .{ .item = entry.key },
                        .complete => {
                            self.aliases = null;
                            self.phase = .complete;
                            return .complete;
                        },
                    }
                },
                .complete => return .complete,
            };
        }
    };

    pub fn namespaceCursor(self: *const Registry) NamespaceCursor {
        const directory = self.acquireDirectory();
        return .{
            .directory = directory,
            .modules = if (directory.directory) |current| current.modules.rawEntries() else null,
            .aliases = if (directory.directory) |current| current.aliases.rawEntries() else null,
        };
    }

    fn detachRetiredDirectories(self: *Registry) ?*Directory {
        if (!self.privateState().directories.quiescent()) return null;
        const current = self.privateState().directories.currentOwned() orelse return null;
        const retired = current.previous;
        current.previous = null;
        return retired;
    }

    const ReclaimProgress = poll.Progress(void);
    const ReclaimCursor = struct {
        registry: *Registry,
        iterator: poll.ChunkList(RetiredGeneration).Iterator,
        fn advance(self: *ReclaimCursor) ReclaimProgress {
            self.registry.lockBlocking();
            const entry_const = self.iterator.next() orelse {
                self.registry.unlock();
                return .complete;
            };
            const entry = @constCast(entry_const);
            const generation = if (entry.generation) |candidate| reclaim: {
                if (!entry.slot.publisher.quiescent()) break :reclaim null;
                entry.generation = null;
                self.registry.recycleRetired(entry);
                break :reclaim candidate;
            } else null;
            self.registry.unlock();
            if (generation) |retired| retired.release();
            return .pending;
        }
    };
    fn reclaimCursor(self: *Registry) ReclaimCursor {
        self.lockBlocking();
        defer self.unlock();
        return .{ .registry = self, .iterator = self.privateState().retired.iterator() };
    }

    fn retireGeneration(
        self: *Registry,
        slot: *ModuleSlot,
        generation: *ModuleGeneration,
    ) error{OutOfMemory}!*RetiredGeneration {
        const backing = self.privateState();
        const entry = if (backing.retired_free) |recycled| entry: {
            backing.retired_free = recycled.next_free;
            break :entry recycled;
        } else try backing.retired.appendPtr(.{ .slot = slot, .generation = generation });
        entry.* = .{ .slot = slot, .generation = generation };
        return entry;
    }

    fn recycleRetired(self: *Registry, entry: *RetiredGeneration) void {
        std.debug.assert(entry.generation == null);
        entry.next_free = self.privateState().retired_free;
        self.privateState().retired_free = entry;
    }

    pub fn createCandidate(
        self: *Registry,
        name: intern.NamespaceName,
    ) error{OutOfMemory}!OwnedCandidate {
        return .init(try ModuleGeneration.create(self.allocator(), self.releaseDomain(), name));
    }

    pub const NativeCandidateProgress = poll.Progress(OwnedCandidate);

    /// The single bounded native-definition publication path used by dynamic
    /// loading and static transport verification. Each turn installs at most
    /// one validated definition into the unpublished generation.
    pub const NativeCandidateCursor = struct {
        instance: *native_module.ModuleInstance,
        candidate: ?OwnedCandidate,
        definition_index: usize = 0,

        pub fn init(
            registry: *Registry,
            instance: *native_module.ModuleInstance,
        ) error{OutOfMemory}!NativeCandidateCursor {
            return .{
                .instance = instance,
                .candidate = try registry.createCandidate(instance.name()),
            };
        }

        pub fn deinit(self: *NativeCandidateCursor) void {
            if (self.candidate) |*candidate| candidate.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NativeCandidateCursor) error{OutOfMemory}!NativeCandidateProgress {
            const definitions = self.instance.validated().definitions();
            if (self.definition_index == definitions.len) {
                const completed = self.candidate.?.move();
                self.candidate = null;
                return .{ .complete = completed };
            }
            const definition = definitions[self.definition_index];
            _ = self.candidate.?.publishDefinition(definition.name, .{ .native = .{
                .callable = .{
                    .instance = self.instance,
                    .definition = @intCast(self.definition_index),
                },
                .visibility = .public,
                .effect = definition.effect,
                .doc = definition.doc,
            } }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => unreachable,
            };
            self.definition_index += 1;
            return .pending;
        }
    };

    pub const CommitProgress = poll.Progress(u64);
    pub const CommitCursor = struct {
        const ModuleBuilder = union(enum) {
            initialize: Directory.ModuleMap.InitCursor,
            clone: Directory.ModuleMap.CloneCursor,

            fn deinit(self: *ModuleBuilder) void {
                switch (self.*) {
                    inline else => |*cursor| cursor.deinit(),
                }
            }
        };
        const AliasBuilder = union(enum) {
            initialize: Directory.AliasMap.InitCursor,
            clone: Directory.AliasMap.CloneCursor,

            fn deinit(self: *AliasBuilder) void {
                switch (self.*) {
                    inline else => |*cursor| cursor.deinit(),
                }
            }
        };
        const Snapshot = struct {
            directory: DirectoryLease,
            old: ?*const Directory,
        };
        const NewBuild = struct {
            snapshot: Snapshot,
            modules: Directory.ModuleMap,
            aliases: Directory.AliasMap,
            slot: *ModuleSlot,
        };
        const State = union(enum) {
            reclaim: ReclaimCursor,
            snapshot,
            alias: struct {
                snapshot: Snapshot,
                cursor: Directory.AliasMap.RawLookupCursor,
            },
            module: struct {
                snapshot: Snapshot,
                cursor: ?Directory.ModuleMap.RawLookupCursor,
            },
            modules: struct {
                snapshot: Snapshot,
                builder: ModuleBuilder,
            },
            aliases: struct {
                snapshot: Snapshot,
                modules: Directory.ModuleMap,
                builder: AliasBuilder,
            },
            prepare_insert: struct {
                snapshot: Snapshot,
                modules: Directory.ModuleMap,
                aliases: Directory.AliasMap,
            },
            insert: struct {
                build: *NewBuild,
                cursor: Directory.ModuleMap.PutCursor,
            },
            commit_existing: *ModuleSlot,
            commit_new: *NewBuild,
            complete,
        };

        registry: *Registry,
        owned: *OwnedCandidate,
        state: State,

        pub fn init(registry: *Registry, owned: *OwnedCandidate) CommitCursor {
            return .{
                .registry = registry,
                .owned = owned,
                .state = .{ .reclaim = registry.reclaimCursor() },
            };
        }
        pub fn deinit(self: *CommitCursor) void {
            switch (self.state) {
                .alias => |*state| state.snapshot.directory.deinit(),
                .module => |*state| state.snapshot.directory.deinit(),
                .modules => |*state| {
                    state.builder.deinit();
                    state.snapshot.directory.deinit();
                },
                .aliases => |*state| {
                    state.builder.deinit();
                    state.modules.deinit();
                    state.snapshot.directory.deinit();
                },
                .prepare_insert => |*state| {
                    state.modules.deinit();
                    state.aliases.deinit();
                    state.snapshot.directory.deinit();
                },
                .insert => |state| self.destroyBuild(state.build),
                .commit_new => |build| self.destroyBuild(build),
                .reclaim, .snapshot, .commit_existing, .complete => {},
            }
            self.* = undefined;
        }
        fn destroyBuild(self: *CommitCursor, build: *NewBuild) void {
            build.modules.deinit();
            build.aliases.deinit();
            self.registry.allocator().destroy(build.slot);
            build.snapshot.directory.deinit();
            self.registry.allocator().destroy(build);
        }
        pub fn advance(self: *CommitCursor) RegistryError!CommitProgress {
            const candidate = self.owned.borrow();
            const name = candidate.name;
            return switch (self.state) {
                .reclaim => |*reclaimer| switch (reclaimer.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.state = .snapshot;
                        break :result .pending;
                    },
                },
                .snapshot => result: {
                    const directory = self.registry.acquireDirectory();
                    const snapshot = Snapshot{
                        .old = directory.directory,
                        .directory = directory,
                    };
                    if (snapshot.old) |old| {
                        self.state = .{ .alias = .{
                            .snapshot = snapshot,
                            .cursor = old.aliases.rawLookup(name),
                        } };
                    } else {
                        self.state = .{ .module = .{
                            .snapshot = snapshot,
                            .cursor = null,
                        } };
                    }
                    break :result .pending;
                },
                .alias => |*state| switch (state.cursor.advance()) {
                    .pending => .pending,
                    .complete => |existing_alias| result: {
                        if (existing_alias != null) return error.NameConflict;
                        self.state = .{ .module = .{
                            .snapshot = state.snapshot,
                            .cursor = state.snapshot.old.?.modules.rawLookup(name),
                        } };
                        break :result .pending;
                    },
                },
                .module => |*state| if (state.cursor) |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_slot| result: {
                        if (maybe_slot) |slot| {
                            state.snapshot.directory.deinit();
                            self.state = .{ .commit_existing = slot };
                        } else {
                            self.state = .{ .modules = .{
                                .snapshot = state.snapshot,
                                .builder = .{ .clone = state.snapshot.old.?.modules.cloneCursor(1) },
                            } };
                        }
                        break :result .pending;
                    },
                } else result: {
                    self.state = .{ .modules = .{
                        .snapshot = state.snapshot,
                        .builder = .{ .initialize = Directory.ModuleMap.initCursor(
                            self.registry.allocator(),
                            1,
                        ) },
                    } };
                    break :result .pending;
                },
                .modules => |*state| switch (state.builder) {
                    inline else => |*builder| switch (try builder.advance()) {
                        .pending => .pending,
                        .complete => |modules| result: {
                            builder.deinit();
                            const alias_builder: AliasBuilder = if (state.snapshot.old) |old|
                                .{ .clone = old.aliases.cloneCursor(0) }
                            else
                                .{ .initialize = Directory.AliasMap.initCursor(
                                    self.registry.allocator(),
                                    0,
                                ) };
                            self.state = .{ .aliases = .{
                                .snapshot = state.snapshot,
                                .modules = modules,
                                .builder = alias_builder,
                            } };
                            break :result .pending;
                        },
                    },
                },
                .aliases => |*state| switch (state.builder) {
                    inline else => |*builder| switch (try builder.advance()) {
                        .pending => .pending,
                        .complete => |aliases| result: {
                            builder.deinit();
                            self.state = .{ .prepare_insert = .{
                                .snapshot = state.snapshot,
                                .modules = state.modules,
                                .aliases = aliases,
                            } };
                            break :result .pending;
                        },
                    },
                },
                .prepare_insert => |*state| result: {
                    const build = try self.registry.allocator().create(NewBuild);
                    const slot = self.registry.allocator().create(ModuleSlot) catch |err| {
                        self.registry.allocator().destroy(build);
                        return err;
                    };
                    slot.* = .{};
                    build.* = .{
                        .snapshot = state.snapshot,
                        .modules = state.modules,
                        .aliases = state.aliases,
                        .slot = slot,
                    };
                    self.state = .{ .insert = .{
                        .build = build,
                        .cursor = build.modules.putCursor(name, slot),
                    } };
                    break :result .pending;
                },
                .insert => |*state| switch (state.cursor.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.state = .{ .commit_new = state.build };
                        break :result .pending;
                    },
                },
                .commit_existing => |slot| result: {
                    self.registry.lockBlocking();
                    const prior = slot.publisher.currentOwned().?;
                    const retired = self.registry.retireGeneration(slot, prior) catch |err| {
                        self.registry.unlock();
                        return err;
                    };
                    candidate.generation = prior.generation + 1;
                    candidate.scope.freezeModule();
                    slot.publisher.publish(self.owned.publish());
                    const release_prior = slot.publisher.quiescent();
                    if (release_prior) {
                        retired.generation = null;
                        self.registry.recycleRetired(retired);
                    }
                    self.registry.unlock();
                    if (release_prior) prior.release();
                    self.state = .complete;
                    break :result .{ .complete = candidate.generation };
                },
                .commit_new => |build| result: {
                    const next = try self.registry.allocator().create(Directory);
                    self.registry.lockBlocking();
                    if (!self.registry.privateState().directories.isCurrent(build.snapshot.old)) {
                        self.registry.unlock();
                        self.registry.allocator().destroy(next);
                        self.destroyBuild(build);
                        self.state = .snapshot;
                        break :result .pending;
                    }
                    next.* = .{
                        .modules = build.modules,
                        .aliases = build.aliases,
                        .previous = @constCast(build.snapshot.old),
                    };
                    self.registry.privateState().slots.append(build.slot) catch {
                        self.registry.unlock();
                        self.registry.allocator().destroy(next);
                        return error.OutOfMemory;
                    };
                    candidate.generation = 1;
                    candidate.scope.freezeModule();
                    build.slot.publisher.publish(self.owned.publish());
                    self.registry.privateState().directories.publish(next);
                    self.registry.unlock();
                    build.snapshot.directory.deinit();
                    self.registry.allocator().destroy(build);
                    self.state = .complete;
                    break :result .{ .complete = 1 };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn commitCursor(self: *Registry, owned: *OwnedCandidate) CommitCursor {
        return .init(self, owned);
    }

    pub const AliasProgress = poll.Progress(void);
    pub const AliasCursor = struct {
        registry: *Registry,
        short: intern.NamespaceName,
        target: intern.NamespaceName,
        directory: ?DirectoryLease = null,
        old: ?*const Directory = null,
        lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,
        canonical_target: ?intern.NamespaceName = null,
        existing_short: ?intern.NamespaceName = null,
        modules_cloner: ?Directory.ModuleMap.CloneCursor = null,
        modules_map: ?Directory.ModuleMap = null,
        aliases_cloner: ?Directory.AliasMap.CloneCursor = null,
        aliases_map: ?Directory.AliasMap = null,
        insertion: ?Directory.AliasMap.PutCursor = null,
        phase: enum { snapshot, short_module, target_module, target_alias, short_alias, modules_map, aliases_map, insert, commit, complete } = .snapshot,

        pub fn init(registry: *Registry, short: intern.NamespaceName, target: intern.NamespaceName) AliasCursor {
            return .{ .registry = registry, .short = short, .target = target };
        }
        pub fn deinit(self: *AliasCursor) void {
            if (self.directory) |*directory| directory.deinit();
            self.resetMaps();
            self.* = undefined;
        }
        fn resetMaps(self: *AliasCursor) void {
            if (self.modules_cloner) |*cursor| cursor.deinit();
            self.modules_cloner = null;
            if (self.modules_map) |*map| map.deinit();
            self.modules_map = null;
            if (self.aliases_cloner) |*cursor| cursor.deinit();
            self.aliases_cloner = null;
            if (self.aliases_map) |*map| map.deinit();
            self.aliases_map = null;
            self.insertion = null;
        }
        fn retry(self: *AliasCursor) void {
            self.resetMaps();
            self.directory.?.deinit();
            self.directory = null;
            self.old = null;
            self.lookup = null;
            self.alias_lookup = null;
            self.existing_short = null;
            self.phase = .snapshot;
        }
        pub fn advance(self: *AliasCursor) RegistryError!AliasProgress {
            return switch (self.phase) {
                .snapshot => result: {
                    self.directory = self.registry.acquireDirectory();
                    self.old = self.directory.?.directory orelse return error.MissingModule;
                    self.lookup = self.old.?.modules.rawLookup(self.short);
                    self.phase = .short_module;
                    break :result .pending;
                },
                .short_module => switch (self.lookup.?.advance()) {
                    .pending => .pending,
                    .complete => |slot| result: {
                        if (slot != null) return error.NameConflict;
                        self.lookup = self.old.?.modules.rawLookup(self.target);
                        self.phase = .target_module;
                        break :result .pending;
                    },
                },
                .target_module => switch (self.lookup.?.advance()) {
                    .pending => .pending,
                    .complete => |slot| result: {
                        if (slot != null) {
                            self.canonical_target = self.target;
                            self.alias_lookup = self.old.?.aliases.rawLookup(self.short);
                            self.phase = .short_alias;
                        } else {
                            self.alias_lookup = self.old.?.aliases.rawLookup(self.target);
                            self.phase = .target_alias;
                        }
                        break :result .pending;
                    },
                },
                .target_alias => switch (self.alias_lookup.?.advance()) {
                    .pending => .pending,
                    .complete => |canonical_name| result: {
                        self.canonical_target = canonical_name orelse return error.MissingModule;
                        self.alias_lookup = self.old.?.aliases.rawLookup(self.short);
                        self.phase = .short_alias;
                        break :result .pending;
                    },
                },
                .short_alias => switch (self.alias_lookup.?.advance()) {
                    .pending => .pending,
                    .complete => |existing| result: {
                        self.existing_short = existing;
                        if (existing != null and existing == self.canonical_target) {
                            self.phase = .complete;
                            break :result .complete;
                        }
                        self.modules_cloner = self.old.?.modules.cloneCursor(0);
                        self.phase = .modules_map;
                        break :result .pending;
                    },
                },
                .modules_map => switch (try self.modules_cloner.?.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        self.modules_cloner.?.deinit();
                        self.modules_cloner = null;
                        self.modules_map = map;
                        self.aliases_cloner = self.old.?.aliases.cloneCursor(
                            @intFromBool(self.existing_short == null),
                        );
                        self.phase = .aliases_map;
                        break :result .pending;
                    },
                },
                .aliases_map => switch (try self.aliases_cloner.?.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        self.aliases_cloner.?.deinit();
                        self.aliases_cloner = null;
                        self.aliases_map = map;
                        self.insertion = self.aliases_map.?.putCursor(
                            self.short,
                            self.canonical_target.?,
                        );
                        self.phase = .insert;
                        break :result .pending;
                    },
                },
                .insert => switch (self.insertion.?.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.insertion = null;
                        self.phase = .commit;
                        break :result .pending;
                    },
                },
                .commit => result: {
                    const next = try self.registry.allocator().create(Directory);
                    self.registry.lockBlocking();
                    if (!self.registry.privateState().directories.isCurrent(self.old)) {
                        self.registry.unlock();
                        self.registry.allocator().destroy(next);
                        self.retry();
                        break :result .pending;
                    }
                    next.* = .{
                        .modules = self.modules_map.?,
                        .aliases = self.aliases_map.?,
                        .previous = @constCast(self.old),
                    };
                    self.modules_map = null;
                    self.aliases_map = null;
                    self.registry.privateState().directories.publish(next);
                    self.registry.unlock();
                    self.phase = .complete;
                    break :result .complete;
                },
                .complete => unreachable,
            };
        }
    };
    pub fn aliasCursor(
        self: *Registry,
        short: intern.NamespaceName,
        target: intern.NamespaceName,
    ) AliasCursor {
        return .init(self, short, target);
    }

    pub const CanonicalProgress = poll.Progress(?u32);
    pub const CanonicalCursor = struct {
        directory: DirectoryLease,
        name: u32,
        phase: enum { module, alias, complete } = .module,
        module_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,

        pub fn deinit(self: *CanonicalCursor) void {
            self.directory.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *CanonicalCursor) CanonicalProgress {
            while (true) switch (self.phase) {
                .module => {
                    const lookup = &(self.module_lookup orelse {
                        self.phase = .complete;
                        return .{ .complete = null };
                    });
                    switch (lookup.advance()) {
                        .pending => return .pending,
                        .complete => |slot| if (slot != null) {
                            self.phase = .complete;
                            return .{ .complete = self.name };
                        } else {
                            const directory = self.directory.directory.?;
                            self.alias_lookup = directory.aliases.rawLookup(@enumFromInt(self.name));
                            self.phase = .alias;
                        },
                    }
                },
                .alias => switch (self.alias_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |canonical_name| {
                        self.phase = .complete;
                        return .{ .complete = if (canonical_name) |found|
                            intern.namespaceId(found)
                        else
                            null };
                    },
                },
                .complete => unreachable,
            };
        }
    };
    pub fn canonicalCursor(self: *const Registry, name: u32) CanonicalCursor {
        const directory = self.acquireDirectory();
        return .{
            .directory = directory,
            .name = name,
            .module_lookup = if (directory.directory) |current|
                current.modules.rawLookup(@enumFromInt(name))
            else
                null,
        };
    }

    pub const AcquireProgress = poll.Progress(?GenerationLease);
    pub const AcquireCursor = struct {
        registry: *const Registry,
        directory: DirectoryLease,
        name: u32,
        phase: enum { module, alias, canonical_module, reclaim, complete } = .module,
        module_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,
        canonical_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        pending_lease: ?GenerationLease = null,
        reclaimer: ?ReclaimCursor = null,

        pub fn deinit(self: *AcquireCursor) void {
            self.directory.deinit();
            if (self.pending_lease) |*lease| lease.deinit();
            self.* = undefined;
        }
        fn acceptSlot(self: *AcquireCursor, slot: *ModuleSlot) AcquireProgress {
            const protected = self.registry.leaseSlot(slot);
            if (protected.needs_reclaim) {
                self.pending_lease = protected.lease;
                self.reclaimer = @constCast(self.registry).reclaimCursor();
                self.phase = .reclaim;
                return .pending;
            }
            self.phase = .complete;
            return .{ .complete = protected.lease };
        }
        pub fn advance(self: *AcquireCursor) AcquireProgress {
            while (true) switch (self.phase) {
                .module => {
                    const lookup = &(self.module_lookup orelse {
                        self.phase = .complete;
                        return .{ .complete = null };
                    });
                    switch (lookup.advance()) {
                        .pending => return .pending,
                        .complete => |slot| if (slot) |found| {
                            return self.acceptSlot(found);
                        } else {
                            const directory = self.directory.directory.?;
                            self.alias_lookup = directory.aliases.rawLookup(@enumFromInt(self.name));
                            self.phase = .alias;
                        },
                    }
                },
                .alias => switch (self.alias_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |canonical_name| if (canonical_name) |found| {
                        self.canonical_lookup = self.directory.directory.?.modules.rawLookup(found);
                        self.phase = .canonical_module;
                    } else {
                        self.phase = .complete;
                        return .{ .complete = null };
                    },
                },
                .canonical_module => switch (self.canonical_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |slot| {
                        return self.acceptSlot(slot orelse unreachable);
                    },
                },
                .reclaim => switch (self.reclaimer.?.advance()) {
                    .pending => return .pending,
                    .complete => {
                        const lease = self.pending_lease;
                        self.pending_lease = null;
                        self.reclaimer = null;
                        self.phase = .complete;
                        return .{ .complete = lease };
                    },
                },
                .complete => unreachable,
            };
        }
    };
    pub fn acquireCursor(self: *const Registry, name: u32) AcquireCursor {
        const directory = self.acquireDirectory();
        return .{
            .registry = self,
            .directory = directory,
            .name = name,
            .module_lookup = if (directory.directory) |current|
                current.modules.rawLookup(@enumFromInt(name))
            else
                null,
        };
    }

    const LeaseSlotResult = struct {
        lease: ?GenerationLease,
        needs_reclaim: bool,
    };
    fn leaseSlot(self: *const Registry, slot: *ModuleSlot) LeaseSlotResult {
        _ = self;
        var snapshot_lease = slot.publisher.acquire();
        const generation = snapshot_lease.snapshot;
        if (generation) |present| {
            @constCast(present).retain();
        }
        const final_reader = snapshot_lease.deinit();
        return .{
            .lease = if (generation) |present| GenerationLease.initRetained(@constCast(present)) else null,
            .needs_reclaim = final_reader,
        };
    }

    /// Consumes a fully built, typed candidate only after successful publication.
    pub fn commit(
        self: *Registry,
        owned: *OwnedCandidate,
    ) RegistryError!u64 {
        var cursor = self.commitCursor(owned);
        defer cursor.deinit();
        return poll.driveFallible(u64, &cursor, .{});
    }

    pub fn canonical(self: *const Registry, name: u32) ?u32 {
        var cursor = self.canonicalCursor(name);
        defer cursor.deinit();
        return poll.drive(?u32, &cursor, .{});
    }

    pub fn acquire(self: *const Registry, name: u32) ?GenerationLease {
        var cursor = self.acquireCursor(name);
        defer cursor.deinit();
        return poll.drive(?GenerationLease, &cursor, .{});
    }

    pub fn alias(
        self: *Registry,
        short: intern.NamespaceName,
        target: intern.NamespaceName,
    ) RegistryError!void {
        var cursor = self.aliasCursor(short, target);
        defer cursor.deinit();
        return poll.driveVoidFallible(&cursor, .{});
    }

    pub fn beginLoading(
        self: *Registry,
        name: u32,
    ) error{OutOfMemory}!?LoadingLease {
        var cursor = self.beginLoadingCursor(name);
        return poll.driveFallible(?LoadingLease, &cursor, .{});
    }

    pub const BeginLoadingProgress = poll.Progress(?LoadingLease);
    pub const BeginLoadingCursor = struct {
        registry: *Registry,
        name: u32,
        observed_head: ?*LoadingNode,
        cursor: ?*LoadingNode,
        phase: enum { scan, commit, complete } = .scan,
        pub fn advance(self: *BeginLoadingCursor) error{OutOfMemory}!BeginLoadingProgress {
            return switch (self.phase) {
                .scan => result: {
                    const node = self.cursor orelse {
                        self.phase = .commit;
                        break :result .pending;
                    };
                    self.cursor = node.next;
                    if (node.name == self.name) {
                        if (node.active.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                            self.phase = .complete;
                            break :result .{ .complete = .init(node) };
                        }
                        if (node.active.load(.acquire)) {
                            self.phase = .complete;
                            break :result .{ .complete = null };
                        }
                    }
                    break :result .pending;
                },
                .commit => result: {
                    self.registry.lockBlocking();
                    defer self.registry.unlock();
                    const current = self.registry.privateState().loading.load(.acquire);
                    if (current != self.observed_head) {
                        self.observed_head = current;
                        self.cursor = current;
                        self.phase = .scan;
                        break :result .pending;
                    }
                    const node = try self.registry.allocator().create(LoadingNode);
                    node.* = .{ .registry = self.registry, .name = self.name, .next = current };
                    self.registry.privateState().loading.store(node, .release);
                    self.phase = .complete;
                    break :result .{ .complete = .init(node) };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn beginLoadingCursor(self: *Registry, name: u32) BeginLoadingCursor {
        const head = self.privateState().loading.load(.acquire);
        return .{ .registry = self, .name = name, .observed_head = head, .cursor = head };
    }
};
comptime {
    heap.requireOpaqueHostRoot(Registry, RegistryState);
}
