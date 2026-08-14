//! Per-session module registry with typed names and atomic generation publication.
const std = @import("std");
const env = @import("env.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");

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
        work: poll.WorkContext,
    ) poll.Error!?env.BindingLease {
        var lease = try self.environment.resolveDirect(id, work) orelse return null;
        if (public_only and lease.visibility == .private) {
            lease.deinit(self.allocator);
            return null;
        }
        return lease;
    }

    pub fn publicNamesOwned(
        self: *const ModuleGeneration,
        allocator: std.mem.Allocator,
        work: poll.WorkContext,
    ) poll.Error![]u32 {
        const all = try self.environment.namesOwned(allocator, work);
        defer allocator.free(all);
        const visible = try allocator.alloc(u32, all.len);
        defer allocator.free(visible);
        var count: usize = 0;
        var all_cursor = work.cursor(u32, all);
        while (try all_cursor.next()) |id| {
            if (!try self.isPublic(id, work)) continue;
            visible[count] = id;
            count += 1;
        }
        const result = try allocator.alloc(u32, count);
        errdefer allocator.free(result);
        var source_cursor = work.cursor(u32, visible[0..count]);
        var result_index: usize = 0;
        while (try source_cursor.next()) |id| : (result_index += 1) result[result_index] = id;
        return result;
    }

    fn isPublic(self: *const ModuleGeneration, id: u32, work: poll.WorkContext) poll.Error!bool {
        var lease = (try self.environment.resolveDirect(id, work)).?;
        defer lease.deinit(self.allocator);
        return lease.visibility == .public;
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

    fn clone(
        allocator: std.mem.Allocator,
        old: ?*Directory,
        extra_modules: usize,
        extra_aliases: usize,
        work: poll.WorkContext,
    ) poll.Error!*Directory {
        const module_count = if (old) |directory| directory.modules.count() else 0;
        const alias_count = if (old) |directory| directory.aliases.count() else 0;
        const modules = if (old) |directory|
            try directory.modules.cloneGrow(extra_modules, work)
        else
            try ModuleMap.init(allocator, extra_modules, work);
        errdefer {
            var owned = modules;
            owned.deinit();
        }
        const aliases = if (old) |directory|
            try directory.aliases.cloneGrow(extra_aliases, work)
        else
            try AliasMap.init(allocator, alias_count + extra_aliases, work);
        errdefer {
            var owned = aliases;
            owned.deinit();
        }
        const result = try allocator.create(Directory);
        result.* = .{ .modules = modules, .aliases = aliases, .previous = old };
        _ = module_count;
        return result;
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
    pub fn finish(self: *LoadingLease, work: poll.WorkContext) poll.Error!void {
        const loading = self.node();
        try loading.registry.endLoading(loading, work);
        self.* = .finished;
    }
    pub fn deinit(self: *LoadingLease) void {
        if (self.* == .finished) return;
        const loading = self.node();
        loading.registry.endLoading(loading, .unlimited()) catch unreachable;
        self.* = .finished;
    }
};
const RetiredGeneration = struct {
    slot: *ModuleSlot,
    generation: ?*ModuleGeneration,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    writer: std.atomic.Mutex = .unlocked,
    directory: std.atomic.Value(?*Directory) = .init(null),
    slots: poll.ChunkList(*ModuleSlot),
    retired: poll.ChunkList(RetiredGeneration),
    loading: ?*LoadingNode = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .slots = .init(allocator),
            .retired = .init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        Directory.destroyChain(self.directory.load(.acquire), self.allocator);
        var slots = self.slots.iterator();
        while (slots.next()) |slot| slot.*.destroy(self.allocator);
        self.slots.deinit();
        var retired = self.retired.iterator();
        while (retired.next()) |entry| if (entry.generation) |generation| generation.release();
        self.retired.deinit();
        var loading = self.loading;
        while (loading) |node| {
            loading = node.next;
            self.allocator.destroy(node);
        }
        self.* = undefined;
    }

    fn lock(self: *Registry, work: poll.WorkContext) poll.Error!void {
        while (!self.writer.tryLock()) {
            try work.step();
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Registry) void {
        self.writer.unlock();
    }

    fn reclaimRetired(self: *Registry, work: poll.WorkContext) poll.Error!void {
        var entries = self.retired.workIterator(work);
        while (try entries.next()) |entry_const| {
            const entry = @constCast(entry_const);
            const generation = entry.generation orelse continue;
            if (entry.slot.readers.load(.seq_cst) != 0) continue;
            entry.generation = null;
            generation.release();
        }
    }

    pub fn createCandidate(
        self: *Registry,
        name: intern.NamespaceName,
    ) error{OutOfMemory}!OwnedCandidate {
        return .init(try ModuleGeneration.create(self.allocator, name));
    }

    /// Consumes a fully built, typed candidate only after successful publication.
    pub fn commit(
        self: *Registry,
        owned: *OwnedCandidate,
        work: poll.WorkContext,
    ) RegistryError!u64 {
        const candidate = owned.borrow();
        try self.lock(work);
        defer self.unlock();
        try self.reclaimRetired(work);
        const name = intern.namespaceId(candidate.name);
        const old = self.directory.load(.acquire);
        if (old) |directory| if (try directory.aliases.get(name, work) != null)
            return error.NameConflict;
        if (old) |directory| if (try directory.modules.get(name, work)) |slot| {
            const prior = slot.current.load(.acquire).?;
            // Transfer the slot's old generation reference to stable retired
            // storage before publication. Readers may safely finish retaining
            // it; publication has no cancellable or allocating tail.
            const retired = try self.retired.appendPtr(.{ .slot = slot, .generation = prior });
            candidate.generation = prior.generation + 1;
            candidate.scope.freezeModule();
            slot.current.store(owned.publish(), .seq_cst);
            if (slot.readers.load(.seq_cst) == 0) {
                retired.generation = null;
                prior.release();
            }
            return candidate.generation;
        };
        const slot = try self.allocator.create(ModuleSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{};
        const next = try Directory.clone(self.allocator, old, 1, 0, work);
        errdefer next.destroy(self.allocator);
        _ = try next.modules.put(name, slot, work);
        candidate.generation = 1;
        candidate.scope.freezeModule();
        try self.slots.append(slot);
        slot.current.store(owned.publish(), .seq_cst);
        self.directory.store(next, .release);
        return 1;
    }

    pub fn canonical(self: *const Registry, name: u32) ?u32 {
        return self.canonicalWork(name, .unlimited()) catch unreachable;
    }

    pub fn canonicalWork(
        self: *const Registry,
        name: u32,
        work: poll.WorkContext,
    ) poll.Error!?u32 {
        const directory = self.directory.load(.acquire) orelse return null;
        if (try directory.modules.get(name, work) != null) return name;
        return directory.aliases.get(name, work);
    }

    pub fn acquire(self: *const Registry, name: u32) ?GenerationLease {
        return self.acquireWork(name, .unlimited()) catch unreachable;
    }

    pub fn acquireWork(
        self: *const Registry,
        name: u32,
        work: poll.WorkContext,
    ) poll.Error!?GenerationLease {
        const directory = self.directory.load(.acquire) orelse return null;
        const canonical_name = if (try directory.modules.get(name, work) != null)
            name
        else
            try directory.aliases.get(name, work) orelse return null;
        const slot = (try directory.modules.get(canonical_name, work)).?;
        _ = slot.readers.fetchAdd(1, .seq_cst);
        const generation = slot.current.load(.seq_cst);
        if (generation) |present| present.retain();
        _ = slot.readers.fetchSub(1, .seq_cst);
        return .{ .generation = generation orelse return null };
    }

    pub fn alias(
        self: *Registry,
        short: intern.NamespaceName,
        target: intern.NamespaceName,
        work: poll.WorkContext,
    ) RegistryError!void {
        try self.lock(work);
        defer self.unlock();
        const short_id = intern.namespaceId(short);
        const target_id = intern.namespaceId(target);
        const old = self.directory.load(.acquire) orelse return error.MissingModule;
        if (try old.modules.get(short_id, work) != null) return error.NameConflict;
        const canonical_target = if (try old.modules.get(target_id, work) != null)
            target_id
        else
            try old.aliases.get(target_id, work) orelse return error.MissingModule;
        if (try old.aliases.get(short_id, work)) |existing|
            if (existing == canonical_target) return;
        const extra: usize = @intFromBool(try old.aliases.get(short_id, work) == null);
        const next = try Directory.clone(self.allocator, old, 0, extra, work);
        errdefer next.destroy(self.allocator);
        _ = try next.aliases.put(short_id, canonical_target, work);
        self.directory.store(next, .release);
    }

    pub fn registerNative(
        self: *Registry,
        name: intern.NamespaceName,
        definitions: []const NativeDefinition,
        work: poll.WorkContext,
    ) RegistryError!u64 {
        var candidate = try self.createCandidate(name);
        errdefer candidate.deinit();
        var definitions_cursor = work.cursor(NativeDefinition, definitions);
        while (try definitions_cursor.next()) |definition| {
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
            _ = candidate.borrow().scope.publishModule(definition_name, publication, work) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => return error.Ecl,
                error.Frozen => unreachable,
            };
        }
        return self.commit(&candidate, work);
    }

    pub fn beginLoading(
        self: *Registry,
        name: u32,
        work: poll.WorkContext,
    ) poll.Error!?LoadingLease {
        try self.lock(work);
        defer self.unlock();
        var cursor = self.loading;
        while (cursor) |node| : (cursor = node.next) {
            try work.step();
            if (node.name == name) return null;
        }
        const node = try self.allocator.create(LoadingNode);
        node.* = .{ .registry = self, .name = name, .next = self.loading };
        self.loading = node;
        return .init(node);
    }

    fn endLoading(self: *Registry, target: *LoadingNode, work: poll.WorkContext) poll.Error!void {
        try self.lock(work);
        defer self.unlock();
        var link = &self.loading;
        while (link.*) |node| {
            try work.step();
            if (node == target) {
                link.* = node.next;
                self.allocator.destroy(node);
                return;
            }
            link = &node.next;
        }
        unreachable;
    }
};

test "registry replacement is monotone and old generations survive" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const name = try intern.trustedNamespace("test-module");
    var first = try registry.createCandidate(name);
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 1), try registry.commit(&first, .unlimited()));
    var old = registry.acquire(intern.namespaceId(name)).?;
    defer old.deinit();
    var second = try registry.createCandidate(name);
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 2), try registry.commit(&second, .unlimited()));
    try std.testing.expectEqual(@as(u64, 1), old.generation.generation);
    var current = registry.acquire(intern.namespaceId(name)).?;
    defer current.deinit();
    try std.testing.expectEqual(@as(u64, 2), current.generation.generation);
}
