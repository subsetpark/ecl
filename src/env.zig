//! Stable binding cells, immutable environment shapes, and lazy scopes.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
pub const Primitive = *const fn (*machine.Machine) machine.MachineError!void;
pub const Binding = union(enum) {
    word: *value.Header,
    value: value.Value,
    primitive: Primitive,
    pub fn retain(self: Binding) void {
        switch (self) {
            .word => |header| heap.incRef(header),
            .value => |item| heap.retainValue(item),
            .primitive => {},
        }
    }
    pub fn release(self: Binding, allocator: std.mem.Allocator) void {
        switch (self) {
            .word => |header| heap.decRef(allocator, header),
            .value => |item| heap.releaseValue(allocator, item),
            .primitive => {},
        }
    }
};
pub const Visibility = enum { public, private };
pub const Effect = struct {
    quotation: *value.Header,
    inputs: u32,
    outputs: u32,
    pub fn retain(self: Effect) void {
        heap.incRef(self.quotation);
    }
    pub fn release(self: Effect, allocator: std.mem.Allocator) void {
        heap.decRef(allocator, self.quotation);
    }
    pub fn parse(quotation: *value.Header, separator: u32) ?Effect {
        const item: value.Value = .{ .list = quotation };
        const count: usize = @intCast(quotation.len);
        var split: ?usize = null;
        for (0..count) |index| {
            const atom = list.atUnchecked(item, index);
            if (atom != .word) return null;
            if (atom.word == separator) {
                if (split != null) return null;
                split = index;
            }
        }
        const index = split orelse return null;
        return .{ .quotation = quotation, .inputs = @intCast(index), .outputs = @intCast(count - index - 1) };
    }
    pub fn isValid(self: Effect, separator: u32) bool {
        const parsed = parse(self.quotation, separator) orelse return false;
        return self.inputs == parsed.inputs and self.outputs == parsed.outputs;
    }
};
pub const BindingSpec = struct {
    binding: Binding,
    visibility: Visibility = .public,
    home: ?u32 = null,
    effect: ?Effect = null,
    doc: ?*value.Header = null,
    compiled: ?*value.Header = null,
    fn retain(self: BindingSpec) void {
        self.binding.retain();
        if (self.effect) |effect| effect.retain();
        if (self.doc) |doc| heap.incRef(doc);
        if (self.compiled) |compiled| heap.incRef(compiled);
    }
    fn release(self: BindingSpec, allocator: std.mem.Allocator) void {
        self.binding.release(allocator);
        if (self.effect) |effect| effect.release(allocator);
        if (self.doc) |doc| heap.decRef(allocator, doc);
        if (self.compiled) |compiled| heap.decRef(allocator, compiled);
    }
    pub fn deinit(self: *BindingSpec, allocator: std.mem.Allocator) void {
        self.release(allocator);
    }
};
const BindingSnapshot = struct {
    spec: BindingSpec,
    previous: ?*BindingSnapshot,
    fn create(
        allocator: std.mem.Allocator,
        spec: BindingSpec,
        previous: ?*BindingSnapshot,
    ) error{OutOfMemory}!*BindingSnapshot {
        const snapshot = try allocator.create(BindingSnapshot);
        spec.retain();
        snapshot.* = .{ .spec = spec, .previous = previous };
        return snapshot;
    }
    fn destroyChain(first: ?*BindingSnapshot, allocator: std.mem.Allocator) void {
        var cursor = first;
        while (cursor) |snapshot| {
            cursor = snapshot.previous;
            snapshot.spec.release(allocator);
            allocator.destroy(snapshot);
        }
    }
};
/// Owned payload snapshot; release it with the environment's allocator.
pub const BindingLease = BindingSpec;
pub const BindingCell = struct {
    allocator: std.mem.Allocator,
    current: std.atomic.Value(*BindingSnapshot),
    snapshots: *BindingSnapshot,
    readers: std.atomic.Value(u32) = .init(0),
    retire_lock: std.atomic.Mutex = .unlocked,
    fn create(
        allocator: std.mem.Allocator,
        spec: BindingSpec,
    ) error{OutOfMemory}!*BindingCell {
        const snapshot = try BindingSnapshot.create(allocator, spec, null);
        errdefer BindingSnapshot.destroyChain(snapshot, allocator);
        const cell = try allocator.create(BindingCell);
        cell.* = .{ .allocator = allocator, .current = .init(snapshot), .snapshots = snapshot };
        return cell;
    }
    fn replace(
        self: *BindingCell,
        allocator: std.mem.Allocator,
        spec: BindingSpec,
    ) error{OutOfMemory}!void {
        self.lockRetired();
        defer self.retire_lock.unlock();
        const snapshot = try BindingSnapshot.create(allocator, spec, self.snapshots);
        self.snapshots = snapshot;
        self.current.store(snapshot, .seq_cst);
        self.reclaimRetired(allocator);
    }
    fn destroy(self: *BindingCell, allocator: std.mem.Allocator) void {
        BindingSnapshot.destroyChain(self.snapshots, allocator);
        allocator.destroy(self);
    }
    fn lockRetired(self: *BindingCell) void {
        while (!self.retire_lock.tryLock()) std.atomic.spinLoopHint();
    }
    fn reclaimRetired(self: *BindingCell, allocator: std.mem.Allocator) void {
        if (self.readers.load(.seq_cst) != 0) return;
        const retired = self.snapshots.previous;
        self.snapshots.previous = null;
        BindingSnapshot.destroyChain(retired, allocator);
    }
    pub fn load(self: *BindingCell) BindingLease {
        _ = self.readers.fetchAdd(1, .seq_cst);
        const snapshot = self.current.load(.seq_cst);
        const result = snapshot.spec;
        result.retain();
        if (self.readers.fetchSub(1, .seq_cst) == 1) {
            self.lockRetired();
            self.reclaimRetired(self.allocator);
            self.retire_lock.unlock();
        }
        return result;
    }
};
/// Superseded shapes are retained until environment teardown so the
/// lock-free read path needs no hazard pointers. Bounded reclamation is
/// a recorded v1 obligation (ARCHITECTURE.md §Environments, M7).
const Shape = struct {
    names: std.AutoHashMapUnmanaged(u32, *BindingCell) = .empty,
    uses: []u32 = &.{},
    previous: ?*Shape = null,
    fn destroyChain(first: ?*Shape, allocator: std.mem.Allocator) void {
        var cursor = first;
        while (cursor) |shape| {
            cursor = shape.previous;
            shape.names.deinit(allocator);
            if (shape.uses.len > 0) allocator.free(shape.uses);
            allocator.destroy(shape);
        }
    }
};
pub const BindError = error{ OutOfMemory, Frozen };
/// Publishes immutable name/use shapes and stable, lease-backed cells.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    writer: std.atomic.Mutex = .unlocked,
    current: std.atomic.Value(?*Shape) = .init(null),
    cells: std.ArrayList(*BindingCell) = .empty,
    shape_generation: std.atomic.Value(u64) = .init(0),
    frozen: std.atomic.Value(bool) = .init(false),
    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Environment) void {
        Shape.destroyChain(self.current.load(.acquire), self.allocator);
        for (self.cells.items) |binding_cell| binding_cell.destroy(self.allocator);
        self.cells.deinit(self.allocator);
        self.* = undefined;
    }
    fn lock(self: *Environment) void {
        while (!self.writer.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Environment) void {
        self.writer.unlock();
    }
    pub fn bind(
        self: *Environment,
        id: u32,
        binding: Binding,
    ) BindError!*BindingCell {
        return self.bindDetailed(id, .{ .binding = binding });
    }
    pub fn bindDetailed(
        self: *Environment,
        id: u32,
        spec: BindingSpec,
    ) BindError!*BindingCell {
        if (self.frozen.load(.acquire)) return error.Frozen;
        self.lock();
        defer self.unlock();
        if (self.frozen.load(.acquire)) return error.Frozen;
        const old = self.current.load(.acquire);
        if (old) |shape| if (shape.names.get(id)) |binding_cell| {
            try binding_cell.replace(self.allocator, spec);
            return binding_cell;
        };
        const binding_cell = try BindingCell.create(self.allocator, spec);
        errdefer binding_cell.destroy(self.allocator);
        try self.cells.ensureUnusedCapacity(self.allocator, 1);
        const shape = try self.allocator.create(Shape);
        errdefer self.allocator.destroy(shape);
        shape.* = .{ .previous = old };
        errdefer shape.names.deinit(self.allocator);
        const old_count = if (old) |prior| prior.names.count() else 0;
        try shape.names.ensureTotalCapacity(self.allocator, @intCast(old_count + 1));
        if (old) |prior| {
            var iterator = prior.names.iterator();
            while (iterator.next()) |entry| {
                shape.names.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
            }
            if (prior.uses.len > 0) shape.uses = try self.allocator.dupe(u32, prior.uses);
        }
        shape.names.putAssumeCapacityNoClobber(id, binding_cell);
        self.cells.appendAssumeCapacity(binding_cell);
        self.current.store(shape, .release);
        _ = self.shape_generation.fetchAdd(1, .release);
        return binding_cell;
    }
    pub fn resolveDirect(self: *const Environment, id: u32) ?BindingLease {
        const shape = self.current.load(.acquire) orelse return null;
        return (shape.names.get(id) orelse return null).load();
    }
    pub fn cell(self: *const Environment, id: u32) ?*BindingCell {
        const shape = self.current.load(.acquire) orelse return null;
        return shape.names.get(id);
    }
    pub fn generation(self: *const Environment) u64 {
        return self.shape_generation.load(.acquire);
    }
    pub fn useOrder(self: *const Environment) []const u32 {
        const shape = self.current.load(.acquire) orelse return &.{};
        return shape.uses;
    }
    pub fn moveUseToTop(self: *Environment, canonical: u32) BindError!void {
        if (self.frozen.load(.acquire)) return error.Frozen;
        self.lock();
        defer self.unlock();
        if (self.frozen.load(.acquire)) return error.Frozen;
        const old = self.current.load(.acquire);
        const prior_uses = if (old) |shape| shape.uses else &.{};
        if (prior_uses.len > 0 and prior_uses[prior_uses.len - 1] == canonical) return;
        var found = false;
        for (prior_uses) |id| found = found or id == canonical;
        const new_len = prior_uses.len + @as(usize, @intFromBool(!found));
        const uses = try self.allocator.alloc(u32, new_len);
        errdefer self.allocator.free(uses);
        var index: usize = 0;
        for (prior_uses) |id| if (id != canonical) {
            uses[index] = id;
            index += 1;
        };
        uses[index] = canonical;
        const shape = try self.allocator.create(Shape);
        errdefer self.allocator.destroy(shape);
        shape.* = .{ .uses = uses, .previous = old };
        errdefer shape.names.deinit(self.allocator);
        if (old) |prior| {
            try shape.names.ensureTotalCapacity(self.allocator, @intCast(prior.names.count()));
            var iterator = prior.names.iterator();
            while (iterator.next()) |entry| {
                shape.names.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        self.current.store(shape, .release);
        _ = self.shape_generation.fetchAdd(1, .release);
    }
    pub fn namesOwned(
        self: *const Environment,
        allocator: std.mem.Allocator,
        poller: ?poll.Poller,
    ) poll.Error![]u32 {
        const shape = self.current.load(.acquire) orelse return allocator.alloc(u32, 0);
        const result = try allocator.alloc(u32, shape.names.count());
        errdefer allocator.free(result);
        var iterator = shape.names.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |id| : (index += 1) {
            if (poller) |active| try active.poll();
            result[index] = id.*;
        }
        return result;
    }
    pub fn freeze(self: *Environment) void {
        self.lock();
        defer self.unlock();
        self.frozen.store(true, .release);
    }
};
pub const ScopeKind = enum { session, isolated, module_root };
pub const Scope = struct {
    allocator: std.mem.Allocator,
    environment: ?*Environment,
    parent: ?*Scope,
    kind: ScopeKind,
    owns_environment: bool = false,
    pub fn direct(
        allocator: std.mem.Allocator,
        environment: *Environment,
        parent: ?*Scope,
        kind: ScopeKind,
    ) Scope {
        return .{ .allocator = allocator, .environment = environment, .parent = parent, .kind = kind };
    }
    pub fn lazy(allocator: std.mem.Allocator, parent: *Scope) Scope {
        return .{ .allocator = allocator, .environment = null, .parent = parent, .kind = .isolated };
    }
    pub fn deinit(self: *Scope) void {
        if (self.owns_environment) {
            self.environment.?.deinit();
            self.allocator.destroy(self.environment.?);
        }
        self.* = undefined;
    }
    fn writableEnvironment(self: *Scope) error{OutOfMemory}!*Environment {
        if (self.environment) |environment| return environment;
        const created = try self.allocator.create(Environment);
        created.* = Environment.init(self.allocator);
        self.environment = created;
        self.owns_environment = true;
        return created;
    }
    pub fn bindDetailed(self: *Scope, id: u32, spec: BindingSpec) BindError!*BindingCell {
        return (try self.writableEnvironment()).bindDetailed(id, spec);
    }
    pub fn moveUseToTop(self: *Scope, canonical: u32) BindError!void {
        return (try self.writableEnvironment()).moveUseToTop(canonical);
    }
};
pub const Env = struct {
    core: Environment,
    session: Environment,
    pub fn init(allocator: std.mem.Allocator) Env {
        return .{
            .core = Environment.init(allocator),
            .session = Environment.init(allocator),
        };
    }
    pub fn deinit(self: *Env) void {
        self.session.deinit();
        self.core.deinit();
        self.* = undefined;
    }
    pub fn define(self: *Env, id: u32, binding: Binding) error{OutOfMemory}!void {
        _ = self.session.bind(id, binding) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => unreachable,
        };
    }
    pub fn installCore(self: *Env, id: u32, binding: Binding) error{OutOfMemory}!void {
        _ = self.core.bind(id, binding) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => unreachable,
        };
    }
    pub fn sealCore(self: *Env) void {
        self.core.freeze();
    }
};
fn definitionFailureProbe(allocator: std.mem.Allocator) !void {
    var environment = Env.init(allocator);
    defer environment.deinit();
    const body = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(allocator, body);
    try environment.define(1, .{ .word = body.list });
    try environment.define(1, .{ .value = .{ .int = 9 } });
}
test "environment lookup and redefine are late-bound" {
    var environment = Env.init(std.testing.allocator);
    defer environment.deinit();
    try environment.installCore(1, .{ .value = .{ .int = 1 } });
    environment.sealCore();
    var core = environment.core.resolveDirect(1).?;
    defer core.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), core.binding.value.int);
    try environment.define(1, .{ .value = .{ .int = 2 } });
    var local = environment.session.resolveDirect(1).?;
    defer local.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), local.binding.value.int);
    try std.testing.expect(environment.session.resolveDirect(99) == null);
}
test "env: same-name rebind preserves cell identity and shape" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const first = try environment.bind(1, .{ .value = .{ .int = 1 } });
    const generation = environment.generation();
    const second = try environment.bind(1, .{ .value = .{ .int = 2 } });
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(generation, environment.generation());
    var lease = environment.resolveDirect(1).?;
    defer lease.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), lease.binding.value.int);
}
test "environment definition propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, definitionFailureProbe, .{});
}
