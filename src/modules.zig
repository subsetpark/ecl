//! Per-session module registry with typed names and atomic generation publication.
const std = @import("std");
const env = @import("env.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");
const snapshot_core = @import("snapshot_core.zig");

fn readerDecision(
    before: snapshot_core.Reader,
    event: snapshot_core.ReaderEvent,
) snapshot_core.ReaderDecision {
    return snapshot_core.decideReader(before, event) catch
        @panic("invalid registry reader transition");
}

pub const ModuleGeneration = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    name: intern.NamespaceName,
    generation: u64 = 0,
    environment: env.Environment,
    scope: env.Scope,

    pub fn create(
        allocator: std.mem.Allocator,
        name: intern.NamespaceName,
    ) error{OutOfMemory}!*ModuleGeneration {
        const result = try allocator.create(ModuleGeneration);
        result.allocator = allocator;
        result.refs = .init(1);
        result.name = name;
        result.generation = 0;
        result.environment = env.Environment.init(allocator);
        result.scope = env.Scope.moduleRoot(allocator, &result.environment, name);
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
        self.environment.deinit();
        self.allocator.destroy(self);
    }

    pub fn destroy(self: *ModuleGeneration) void {
        std.debug.assert(self.refs.load(.acquire) == 1);
        self.release();
    }

    pub fn resolve(
        self: *const ModuleGeneration,
        id: u32,
        public_only: bool,
    ) ?env.BindingLease {
        var cursor = self.resolveCursor(id, public_only);
        defer cursor.deinit();
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |lease| return lease,
        };
    }

    pub const ResolveProgress = union(enum) { pending, complete: ?env.BindingLease };
    pub const ResolveCursor = struct {
        allocator: std.mem.Allocator,
        public_only: bool,
        lookup: env.DirectLookupCursor,

        pub fn deinit(self: *ResolveCursor) void {
            self.lookup.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *ResolveCursor) ResolveProgress {
            return switch (self.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    var lease = maybe_lease orelse break :result .{ .complete = null };
                    if (self.public_only and lease.visibility == .private) {
                        lease.deinit(self.allocator);
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
        return .{
            .allocator = self.allocator,
            .public_only = public_only,
            .lookup = self.environment.directLookupCursor(id),
        };
    }

    pub fn publicNamesOwned(
        self: *const ModuleGeneration,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u32 {
        var visible = poll.ChunkList(u32).init(allocator);
        defer visible.deinit();
        var cursor = self.publicNameCursor();
        defer cursor.deinit();
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => break,
            .name => |id| try visible.append(id),
        };
        const result = try allocator.alloc(u32, visible.count);
        errdefer allocator.free(result);
        var iterator = visible.iterator();
        var index: usize = 0;
        while (iterator.next()) |id| : (index += 1) result[index] = id.*;
        return result;
    }

    pub const PublicNameProgress = union(enum) { pending, complete, name: u32 };
    pub const PublicNameCursor = struct {
        allocator: std.mem.Allocator,
        inner: env.NameCursor,
        pub fn deinit(self: *PublicNameCursor) void {
            self.inner.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *PublicNameCursor) PublicNameProgress {
            return switch (self.inner.advance()) {
                .pending => .pending,
                .complete => .complete,
                .entry => |entry| result: {
                    var lease = entry.lease;
                    defer lease.deinit(self.allocator);
                    break :result if (lease.visibility == .public)
                        .{ .name = entry.name }
                    else
                        .pending;
                },
            };
        }
    };
    pub fn publicNameCursor(self: *const ModuleGeneration) PublicNameCursor {
        return .{ .allocator = self.allocator, .inner = self.environment.nameCursor() };
    }
};

const ModuleSlot = struct {
    current: std.atomic.Value(?*ModuleGeneration) = .init(null),
    readers: std.atomic.Value(u32) = .init(0),

    fn destroy(self: *ModuleSlot, allocator: std.mem.Allocator) void {
        if (self.current.load(.acquire)) |generation| generation.release();
        allocator.destroy(self);
    }
};

const Directory = struct {
    const ModuleMap = poll.U32Map(*ModuleSlot);
    const AliasMap = poll.U32Map(u32);

    modules: ModuleMap,
    aliases: AliasMap,
    previous: ?*Directory,

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

const DirectoryLease = struct {
    registry: *const Registry,
    directory: ?*const Directory,
    protocol: snapshot_core.Reader,

    fn deinit(self: *DirectoryLease) void {
        const registry = @constCast(self.registry);
        const left = readerDecision(self.protocol, .leave);
        self.protocol = left.next;
        std.debug.assert(left.command == .leave);
        if (registry.directory_readers.fetchSub(1, .seq_cst) == 1) {
            registry.lockBlocking();
            registry.reclaimDirectories();
            registry.unlock();
        }
        self.* = undefined;
    }
};

/// Owns one generation reference; callers must call `deinit`.
pub const GenerationLease = struct {
    generation: *ModuleGeneration,
    pub fn deinit(self: *GenerationLease) void {
        self.generation.release();
        self.* = undefined;
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
    pub fn borrow(self: *const OwnedCandidate) *ModuleGeneration {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }
    pub fn move(self: *OwnedCandidate) OwnedCandidate {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn deinit(self: *OwnedCandidate) void {
        if (self.* == .consumed) return;
        self.borrow().destroy();
        self.* = .consumed;
    }
    fn publish(self: *OwnedCandidate) *ModuleGeneration {
        const generation = self.borrow();
        self.* = .consumed;
        return generation;
    }
};

pub const NativePrimitive = struct {
    name: intern.NamespaceName,
    callback: env.Primitive,
    effect: env.ValidatedEffect,
    visibility: env.Visibility = .public,
};
pub const NativeWord = struct {
    name: intern.NamespaceName,
    body: *env.Quotation,
    effect: env.ValidatedEffect,
    visibility: env.Visibility = .public,
};
pub const NativeValue = struct {
    name: intern.NamespaceName,
    item: @import("value.zig").Value,
    visibility: env.Visibility = .public,
};

/// The tag makes metadata compatibility structural: callable definitions must
/// carry an effect and values have no effect field to misuse.
pub const NativeDefinition = union(enum) {
    primitive: NativePrimitive,
    word: NativeWord,
    value: NativeValue,
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
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    writer: std.Io.Mutex = .init,
    directory: std.atomic.Value(?*Directory) = .init(null),
    directory_readers: std.atomic.Value(u32) = .init(0),
    slots: poll.ChunkList(*ModuleSlot),
    retired: poll.ChunkList(RetiredGeneration),
    loading: std.atomic.Value(?*LoadingNode) = .init(null),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .slots = .init(allocator),
            .retired = .init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.directory_readers.load(.acquire) == 0);
        Directory.destroyChain(self.directory.load(.acquire), self.allocator);
        var slots = self.slots.iterator();
        while (slots.next()) |slot| slot.*.destroy(self.allocator);
        self.slots.deinit();
        var retired = self.retired.iterator();
        while (retired.next()) |entry| if (entry.generation) |generation| generation.release();
        self.retired.deinit();
        var loading = self.loading.load(.acquire);
        while (loading) |node| {
            loading = node.next;
            self.allocator.destroy(node);
        }
        self.* = undefined;
    }

    fn lockBlocking(self: *Registry) void {
        std.Io.Threaded.mutexLock(&self.writer);
    }

    fn unlock(self: *Registry) void {
        std.Io.Threaded.mutexUnlock(&self.writer);
    }

    fn acquireDirectory(self: *const Registry) DirectoryLease {
        const announced = readerDecision(.idle, .announce);
        std.debug.assert(announced.command == .announce);
        _ = @constCast(self).directory_readers.fetchAdd(1, .seq_cst);
        return .{
            .registry = self,
            .directory = self.directory.load(.acquire),
            .protocol = announced.next,
        };
    }

    fn reclaimDirectories(self: *Registry) void {
        const current = self.directory.load(.acquire) orelse return;
        const retired_count: usize = @intFromBool(current.previous != null);
        if (snapshot_core.decideReclamation(
            self.directory_readers.load(.seq_cst),
            retired_count,
        ) == .keep) return;
        const retired = current.previous;
        current.previous = null;
        Directory.destroyChain(retired, self.allocator);
    }

    const ReclaimProgress = enum { pending, complete };
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
                if (snapshot_core.decideReclamation(
                    entry.slot.readers.load(.seq_cst),
                    1,
                ) == .keep) break :reclaim null;
                entry.generation = null;
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
        return .{ .registry = self, .iterator = self.retired.iterator() };
    }

    pub fn createCandidate(
        self: *Registry,
        name: intern.NamespaceName,
    ) error{OutOfMemory}!OwnedCandidate {
        return .init(try ModuleGeneration.create(self.allocator, name));
    }

    pub const CommitProgress = union(enum) { pending, complete: u64 };
    pub const CommitCursor = struct {
        registry: *Registry,
        owned: *OwnedCandidate,
        reclaimer: ReclaimCursor,
        directory: ?DirectoryLease = null,
        old: ?*const Directory = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,
        module_lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        existing: ?*ModuleSlot = null,
        module_cloner: ?Directory.ModuleMap.CloneCursor = null,
        module_initializer: ?Directory.ModuleMap.InitCursor = null,
        modules_map: ?Directory.ModuleMap = null,
        alias_cloner: ?Directory.AliasMap.CloneCursor = null,
        alias_initializer: ?Directory.AliasMap.InitCursor = null,
        aliases_map: ?Directory.AliasMap = null,
        slot: ?*ModuleSlot = null,
        insertion: ?Directory.ModuleMap.PutCursor = null,
        phase: enum { reclaim, snapshot, alias, module, modules_map, aliases_map, insert, commit_existing, commit_new, complete } = .reclaim,

        pub fn init(registry: *Registry, owned: *OwnedCandidate) CommitCursor {
            return .{ .registry = registry, .owned = owned, .reclaimer = registry.reclaimCursor() };
        }
        pub fn deinit(self: *CommitCursor) void {
            self.resetBuild();
            if (self.directory) |*directory| directory.deinit();
            if (self.slot) |slot| self.registry.allocator.destroy(slot);
            self.* = undefined;
        }
        fn resetBuild(self: *CommitCursor) void {
            if (self.module_cloner) |*cursor| cursor.deinit();
            self.module_cloner = null;
            if (self.module_initializer) |*cursor| cursor.deinit();
            self.module_initializer = null;
            if (self.modules_map) |*map| map.deinit();
            self.modules_map = null;
            if (self.alias_cloner) |*cursor| cursor.deinit();
            self.alias_cloner = null;
            if (self.alias_initializer) |*cursor| cursor.deinit();
            self.alias_initializer = null;
            if (self.aliases_map) |*map| map.deinit();
            self.aliases_map = null;
            self.insertion = null;
        }
        fn retry(self: *CommitCursor) void {
            self.resetBuild();
            self.directory.?.deinit();
            self.directory = null;
            self.old = null;
            self.alias_lookup = null;
            self.module_lookup = null;
            self.existing = null;
            self.phase = .snapshot;
        }
        pub fn advance(self: *CommitCursor) RegistryError!CommitProgress {
            const candidate = self.owned.borrow();
            const name = intern.namespaceId(candidate.name);
            return switch (self.phase) {
                .reclaim => switch (self.reclaimer.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.phase = .snapshot;
                        break :result .pending;
                    },
                },
                .snapshot => result: {
                    self.directory = self.registry.acquireDirectory();
                    self.old = self.directory.?.directory;
                    if (self.old) |old| {
                        self.alias_lookup = old.aliases.rawLookup(name);
                        self.phase = .alias;
                    } else {
                        self.phase = .module;
                    }
                    break :result .pending;
                },
                .alias => switch (self.alias_lookup.?.advance()) {
                    .pending => .pending,
                    .complete => |existing_alias| result: {
                        if (existing_alias != null) return error.NameConflict;
                        self.module_lookup = self.old.?.modules.rawLookup(name);
                        self.phase = .module;
                        break :result .pending;
                    },
                },
                .module => if (self.module_lookup) |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_slot| result: {
                        if (maybe_slot) |slot| {
                            self.existing = slot;
                            self.phase = .commit_existing;
                        } else {
                            self.module_cloner = self.old.?.modules.cloneCursor(1);
                            self.phase = .modules_map;
                        }
                        break :result .pending;
                    },
                } else result: {
                    self.module_initializer = Directory.ModuleMap.initCursor(self.registry.allocator, 1);
                    self.phase = .modules_map;
                    break :result .pending;
                },
                .modules_map => if (self.module_cloner) |*cloner| switch (try cloner.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        cloner.deinit();
                        self.module_cloner = null;
                        self.modules_map = map;
                        self.alias_cloner = self.old.?.aliases.cloneCursor(0);
                        self.phase = .aliases_map;
                        break :result .pending;
                    },
                } else switch (try self.module_initializer.?.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        self.module_initializer.?.deinit();
                        self.module_initializer = null;
                        self.modules_map = map;
                        self.alias_initializer = Directory.AliasMap.initCursor(self.registry.allocator, 0);
                        self.phase = .aliases_map;
                        break :result .pending;
                    },
                },
                .aliases_map => if (self.alias_cloner) |*cloner| switch (try cloner.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        cloner.deinit();
                        self.alias_cloner = null;
                        self.aliases_map = map;
                        self.phase = .insert;
                        break :result .pending;
                    },
                } else switch (try self.alias_initializer.?.advance()) {
                    .pending => .pending,
                    .complete => |map| result: {
                        self.alias_initializer.?.deinit();
                        self.alias_initializer = null;
                        self.aliases_map = map;
                        self.phase = .insert;
                        break :result .pending;
                    },
                },
                .insert => result: {
                    if (self.slot == null) {
                        self.slot = try self.registry.allocator.create(ModuleSlot);
                        self.slot.?.* = .{};
                    }
                    if (self.insertion == null)
                        self.insertion = self.modules_map.?.putCursor(name, self.slot.?);
                    switch (self.insertion.?.advance()) {
                        .pending => {},
                        .complete => {
                            self.insertion = null;
                            self.phase = .commit_new;
                        },
                    }
                    break :result .pending;
                },
                .commit_existing => result: {
                    self.registry.lockBlocking();
                    defer self.registry.unlock();
                    const slot = self.existing.?;
                    const prior = slot.current.load(.acquire).?;
                    const retired = try self.registry.retired.appendPtr(.{ .slot = slot, .generation = prior });
                    candidate.generation = prior.generation + 1;
                    candidate.scope.freezeModule();
                    slot.current.store(self.owned.publish(), .seq_cst);
                    if (slot.readers.load(.seq_cst) == 0) {
                        retired.generation = null;
                        prior.release();
                    }
                    self.phase = .complete;
                    break :result .{ .complete = candidate.generation };
                },
                .commit_new => result: {
                    const next = try self.registry.allocator.create(Directory);
                    self.registry.lockBlocking();
                    if (self.registry.directory.load(.acquire) != self.old) {
                        self.registry.unlock();
                        self.registry.allocator.destroy(next);
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
                    self.registry.slots.append(self.slot.?) catch {
                        self.modules_map = next.modules;
                        self.aliases_map = next.aliases;
                        self.registry.unlock();
                        self.registry.allocator.destroy(next);
                        return error.OutOfMemory;
                    };
                    const slot = self.slot.?;
                    self.slot = null;
                    candidate.generation = 1;
                    candidate.scope.freezeModule();
                    slot.current.store(self.owned.publish(), .seq_cst);
                    self.registry.directory.store(next, .release);
                    self.registry.reclaimDirectories();
                    self.registry.unlock();
                    self.phase = .complete;
                    break :result .{ .complete = 1 };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn commitCursor(self: *Registry, owned: *OwnedCandidate) CommitCursor {
        return .init(self, owned);
    }

    pub const AliasProgress = enum { pending, complete };
    pub const AliasCursor = struct {
        registry: *Registry,
        short: u32,
        target: u32,
        directory: ?DirectoryLease = null,
        old: ?*const Directory = null,
        lookup: ?Directory.ModuleMap.RawLookupCursor = null,
        alias_lookup: ?Directory.AliasMap.RawLookupCursor = null,
        canonical_target: u32 = 0,
        existing_short: ?u32 = null,
        modules_cloner: ?Directory.ModuleMap.CloneCursor = null,
        modules_map: ?Directory.ModuleMap = null,
        aliases_cloner: ?Directory.AliasMap.CloneCursor = null,
        aliases_map: ?Directory.AliasMap = null,
        insertion: ?Directory.AliasMap.PutCursor = null,
        phase: enum { snapshot, short_module, target_module, target_alias, short_alias, modules_map, aliases_map, insert, commit, complete } = .snapshot,

        pub fn init(registry: *Registry, short: intern.NamespaceName, target: intern.NamespaceName) AliasCursor {
            return .{ .registry = registry, .short = intern.namespaceId(short), .target = intern.namespaceId(target) };
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
                        if (existing != null and existing.? == self.canonical_target) {
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
                        self.insertion = self.aliases_map.?.putCursor(self.short, self.canonical_target);
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
                    const next = try self.registry.allocator.create(Directory);
                    self.registry.lockBlocking();
                    if (self.registry.directory.load(.acquire) != self.old) {
                        self.registry.unlock();
                        self.registry.allocator.destroy(next);
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
                    self.registry.directory.store(next, .release);
                    self.registry.reclaimDirectories();
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

    pub const CanonicalProgress = union(enum) { pending, complete: ?u32 };
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
                            self.alias_lookup = directory.aliases.rawLookup(self.name);
                            self.phase = .alias;
                        },
                    }
                },
                .alias => switch (self.alias_lookup.?.advance()) {
                    .pending => return .pending,
                    .complete => |canonical_name| {
                        self.phase = .complete;
                        return .{ .complete = canonical_name };
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
                current.modules.rawLookup(name)
            else
                null,
        };
    }

    pub const AcquireProgress = union(enum) { pending, complete: ?GenerationLease };
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
                            self.alias_lookup = directory.aliases.rawLookup(self.name);
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
                current.modules.rawLookup(name)
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
        var protocol: snapshot_core.Reader = .idle;
        const announced = readerDecision(protocol, .announce);
        protocol = announced.next;
        std.debug.assert(announced.command == .announce);
        _ = slot.readers.fetchAdd(1, .seq_cst);
        const generation = slot.current.load(.seq_cst);
        if (generation) |present| {
            const protected = readerDecision(protocol, .protect);
            protocol = protected.next;
            std.debug.assert(protected.command == .retain_payload);
            present.retain();
        }
        const left = readerDecision(protocol, .leave);
        std.debug.assert(left.command == .leave and left.next == .idle);
        const final_reader = slot.readers.fetchSub(1, .seq_cst) == 1;
        return .{
            .lease = if (generation) |present| .{ .generation = present } else null,
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
        while (true) switch (try cursor.advance()) {
            .pending => {},
            .complete => |generation| return generation,
        };
    }

    pub fn canonical(self: *const Registry, name: u32) ?u32 {
        var cursor = self.canonicalCursor(name);
        defer cursor.deinit();
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |canonical_name| return canonical_name,
        };
    }

    pub fn acquire(self: *const Registry, name: u32) ?GenerationLease {
        var cursor = self.acquireCursor(name);
        defer cursor.deinit();
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |lease| return lease,
        };
    }

    pub fn alias(
        self: *Registry,
        short: intern.NamespaceName,
        target: intern.NamespaceName,
    ) RegistryError!void {
        var cursor = self.aliasCursor(short, target);
        defer cursor.deinit();
        while (true) switch (try cursor.advance()) {
            .pending => {},
            .complete => return,
        };
    }

    pub fn registerNative(
        self: *Registry,
        name: intern.NamespaceName,
        definitions: []const NativeDefinition,
    ) RegistryError!u64 {
        var candidate = try self.createCandidate(name);
        errdefer candidate.deinit();
        for (definitions) |definition| {
            const publication: env.ModulePublication, const definition_name = switch (definition) {
                .primitive => |primitive| .{ .{
                    .primitive = .{
                        .callback = primitive.callback,
                        .visibility = primitive.visibility,
                        .effect = primitive.effect,
                    },
                }, primitive.name },
                .word => |word| .{ .{
                    .word = .{
                        .body = word.body,
                        .visibility = word.visibility,
                        .effect = word.effect,
                    },
                }, word.name },
                .value => |item| .{ .{
                    .value = .{
                        .item = item.item,
                        .visibility = item.visibility,
                    },
                }, item.name },
            };
            _ = candidate.borrow().scope.publishModule(definition_name, publication) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => unreachable,
            };
        }
        return self.commit(&candidate);
    }

    pub fn beginLoading(
        self: *Registry,
        name: u32,
    ) error{OutOfMemory}!?LoadingLease {
        var cursor = self.beginLoadingCursor(name);
        while (true) switch (try cursor.advance()) {
            .pending => {},
            .complete => |lease| return lease,
        };
    }

    pub const BeginLoadingProgress = union(enum) { pending, complete: ?LoadingLease };
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
                    const current = self.registry.loading.load(.acquire);
                    if (current != self.observed_head) {
                        self.observed_head = current;
                        self.cursor = current;
                        self.phase = .scan;
                        break :result .pending;
                    }
                    const node = try self.registry.allocator.create(LoadingNode);
                    node.* = .{ .registry = self.registry, .name = self.name, .next = current };
                    self.registry.loading.store(node, .release);
                    self.phase = .complete;
                    break :result .{ .complete = .init(node) };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn beginLoadingCursor(self: *Registry, name: u32) BeginLoadingCursor {
        const head = self.loading.load(.acquire);
        return .{ .registry = self, .name = name, .observed_head = head, .cursor = head };
    }
};

test "registry replacement is monotone and old generations survive" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const name = try intern.trustedNamespace("test-module");
    var first = try registry.createCandidate(name);
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 1), try registry.commit(&first));
    var old = registry.acquire(intern.namespaceId(name)).?;
    defer old.deinit();
    var second = try registry.createCandidate(name);
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 2), try registry.commit(&second));
    try std.testing.expectEqual(@as(u64, 1), old.generation.generation);
    var current = registry.acquire(intern.namespaceId(name)).?;
    defer current.deinit();
    try std.testing.expectEqual(@as(u64, 2), current.generation.generation);
}
