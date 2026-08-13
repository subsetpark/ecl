//! Per-session module registry with atomic generation publication.
const std = @import("std");
const env = @import("env.zig");
const intern = @import("intern.zig");
fn validName(id: u32) bool {
    const name = intern.get(id);
    return name.len > 0 and std.mem.indexOfScalar(u8, name, '.') == null;
}
pub const ModuleGeneration = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    name: u32,
    generation: u64 = 0,
    environment: env.Environment,
    scope: env.Scope,
    pub fn create(
        allocator: std.mem.Allocator,
        name: u32,
    ) error{OutOfMemory}!*ModuleGeneration {
        const result = try allocator.create(ModuleGeneration);
        result.allocator = allocator;
        result.refs = .init(1);
        result.name = name;
        result.generation = 0;
        result.environment = env.Environment.init(allocator);
        result.scope = env.Scope.direct(allocator, &result.environment, null, .module_root);
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
    pub fn resolve(self: *const ModuleGeneration, id: u32, public_only: bool) ?env.BindingLease {
        var lease = self.environment.resolveDirect(id) orelse return null;
        if (public_only and lease.visibility == .private) {
            lease.deinit(self.allocator);
            return null;
        }
        return lease;
    }
    pub fn publicNamesOwned(
        self: *const ModuleGeneration,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u32 {
        const all = try self.environment.namesOwned(allocator);
        defer allocator.free(all);
        const result = try allocator.alloc(u32, all.len);
        errdefer allocator.free(result);
        var count: usize = 0;
        for (all) |id| {
            var lease = self.environment.resolveDirect(id).?;
            defer lease.deinit(allocator);
            if (lease.visibility == .public) {
                result[count] = id;
                count += 1;
            }
        }
        return allocator.realloc(result, count);
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
    modules: std.AutoHashMapUnmanaged(u32, *ModuleSlot) = .empty,
    aliases: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    previous: ?*Directory = null,
    fn destroy(self: *Directory, allocator: std.mem.Allocator) void {
        self.modules.deinit(allocator);
        self.aliases.deinit(allocator);
        allocator.destroy(self);
    }
    fn clone(
        allocator: std.mem.Allocator,
        old: ?*Directory,
        extra_modules: usize,
        extra_aliases: usize,
    ) error{OutOfMemory}!*Directory {
        const result = try allocator.create(Directory);
        result.* = .{ .previous = old };
        errdefer result.destroy(allocator);
        const module_count = if (old) |directory| directory.modules.count() else 0;
        const alias_count = if (old) |directory| directory.aliases.count() else 0;
        try result.modules.ensureTotalCapacity(allocator, @intCast(module_count + extra_modules));
        try result.aliases.ensureTotalCapacity(allocator, @intCast(alias_count + extra_aliases));
        if (old) |directory| {
            var modules_iterator = directory.modules.iterator();
            while (modules_iterator.next()) |entry| {
                result.modules.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
            }
            var aliases_iterator = directory.aliases.iterator();
            while (aliases_iterator.next()) |entry| {
                result.aliases.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return result;
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
pub const RegistryError = error{ OutOfMemory, NameConflict, MissingModule, InvalidDefinition };
pub const NativeDefinition = struct {
    name: u32,
    binding: env.Binding,
    visibility: env.Visibility = .public,
    effect: ?env.Effect = null,
};
pub const Registry = struct {
    allocator: std.mem.Allocator,
    writer: std.atomic.Mutex = .unlocked,
    directory: std.atomic.Value(?*Directory) = .init(null),
    slots: std.ArrayList(*ModuleSlot) = .empty,
    loading: std.AutoHashMapUnmanaged(u32, void) = .empty,
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        Directory.destroyChain(self.directory.load(.acquire), self.allocator);
        for (self.slots.items) |slot| slot.destroy(self.allocator);
        self.slots.deinit(self.allocator);
        self.loading.deinit(self.allocator);
        self.* = undefined;
    }
    fn lock(self: *Registry) void {
        while (!self.writer.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Registry) void {
        self.writer.unlock();
    }
    pub fn createCandidate(
        self: *Registry,
        name: u32,
    ) error{OutOfMemory}!*ModuleGeneration {
        return ModuleGeneration.create(self.allocator, name);
    }
    /// Consumes a fully built candidate only after successful publication.
    pub fn commit(
        self: *Registry,
        candidate: *ModuleGeneration,
    ) RegistryError!u64 {
        if (!validName(candidate.name)) return error.InvalidDefinition;
        self.lock();
        defer self.unlock();
        const old = self.directory.load(.acquire);
        if (old) |directory| if (directory.aliases.contains(candidate.name)) {
            return error.NameConflict;
        };
        if (old) |directory| if (directory.modules.get(candidate.name)) |slot| {
            const prior = slot.current.load(.acquire).?;
            candidate.generation = prior.generation + 1;
            candidate.environment.freeze();
            slot.current.store(candidate, .seq_cst);
            while (slot.readers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
            prior.release();
            return candidate.generation;
        };
        const slot = try self.allocator.create(ModuleSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{};
        try self.slots.ensureUnusedCapacity(self.allocator, 1);
        const next = try Directory.clone(self.allocator, old, 1, 0);
        errdefer next.destroy(self.allocator);
        next.modules.putAssumeCapacityNoClobber(candidate.name, slot);
        candidate.generation = 1;
        candidate.environment.freeze();
        slot.current.store(candidate, .seq_cst);
        self.slots.appendAssumeCapacity(slot);
        self.directory.store(next, .release);
        return 1;
    }
    pub fn canonical(self: *const Registry, name: u32) ?u32 {
        const directory = self.directory.load(.acquire) orelse return null;
        if (directory.modules.contains(name)) return name;
        return directory.aliases.get(name);
    }
    pub fn acquire(self: *const Registry, name: u32) ?GenerationLease {
        const directory = self.directory.load(.acquire) orelse return null;
        const canonical_name = if (directory.modules.contains(name))
            name
        else
            directory.aliases.get(name) orelse return null;
        const slot = directory.modules.get(canonical_name).?;
        _ = slot.readers.fetchAdd(1, .seq_cst);
        const generation = slot.current.load(.seq_cst);
        if (generation) |present| present.retain();
        _ = slot.readers.fetchSub(1, .seq_cst);
        return .{ .generation = generation orelse return null };
    }
    pub fn alias(self: *Registry, short: u32, target: u32) RegistryError!void {
        if (!validName(short) or !validName(target)) return error.InvalidDefinition;
        self.lock();
        defer self.unlock();
        const old = self.directory.load(.acquire) orelse return error.MissingModule;
        if (old.modules.contains(short)) return error.NameConflict;
        const canonical_target = if (old.modules.contains(target))
            target
        else
            old.aliases.get(target) orelse return error.MissingModule;
        if (old.aliases.get(short)) |existing| if (existing == canonical_target) return;
        const extra: usize = @intFromBool(!old.aliases.contains(short));
        const next = try Directory.clone(self.allocator, old, 0, extra);
        errdefer next.destroy(self.allocator);
        next.aliases.putAssumeCapacity(short, canonical_target);
        self.directory.store(next, .release);
    }
    pub fn registerNative(
        self: *Registry,
        name: u32,
        definitions: []const NativeDefinition,
    ) RegistryError!u64 {
        const candidate = try self.createCandidate(name);
        errdefer candidate.destroy();
        const separator = try intern.intern("--");
        for (definitions) |definition| {
            if (!validName(definition.name)) return error.InvalidDefinition;
            switch (definition.binding) {
                .word, .primitive => if (definition.effect == null) return error.InvalidDefinition,
                .value => if (definition.effect != null) return error.InvalidDefinition,
            }
            if (definition.effect) |effect| if (!effect.isValid(separator)) return error.InvalidDefinition;
            _ = candidate.environment.bindDetailed(definition.name, .{
                .binding = definition.binding,
                .visibility = definition.visibility,
                .home = name,
                .effect = definition.effect,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => unreachable,
            };
        }
        return self.commit(candidate);
    }
    pub fn beginLoading(self: *Registry, name: u32) error{OutOfMemory}!bool {
        self.lock();
        defer self.unlock();
        const entry = try self.loading.getOrPut(self.allocator, name);
        return !entry.found_existing;
    }
    pub fn endLoading(self: *Registry, name: u32) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.loading.remove(name));
    }
};
test "registry replacement is monotone and old generations survive" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const first = try registry.createCandidate(1);
    try std.testing.expectEqual(@as(u64, 1), try registry.commit(first));
    var old = registry.acquire(1).?;
    defer old.deinit();
    const second = try registry.createCandidate(1);
    try std.testing.expectEqual(@as(u64, 2), try registry.commit(second));
    try std.testing.expectEqual(@as(u64, 1), old.generation.generation);
    var current = registry.acquire(1).?;
    defer current.deinit();
    try std.testing.expectEqual(@as(u64, 2), current.generation.generation);
}
