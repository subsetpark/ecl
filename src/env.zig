//! Stable binding cells, immutable environment shapes, and lazy scopes.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
/// Public native callbacks cannot split a language-error tag from its payload.
/// The dispatcher installs `.failure` atomically after the callback returns.
pub const PrimitiveOutcome = union(enum) {
    ok,
    failure: machine.EclErr,
};
pub const PrimitiveResult = error{OutOfMemory}!PrimitiveOutcome;
pub const Primitive = *const fn (*machine.Machine) PrimitiveResult;

/// Existing in-tree primitives use Machine's ergonomic error helpers. They
/// occupy a separate binding variant which is unavailable through native
/// module registration; external/native registration accepts only `Primitive`.
pub const PrimitiveImpl = *const fn (*machine.Machine) machine.MachineError!void;

pub const Quotation = opaque {};
pub const DocumentationString = opaque {};
pub const EffectQuotation = opaque {};

pub fn quotation(header: *value.Header) ?*Quotation {
    return switch (header.kind()) {
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => @ptrCast(@alignCast(header)),
        .dict, .reserved_mask => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.Header {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.Header) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .reserved_mask => null,
    };
}

pub fn documentationHeader(document: *const DocumentationString) *value.Header {
    return @ptrCast(@alignCast(@constCast(document)));
}

pub const Binding = union(enum) {
    word: *Quotation,
    value: value.Value,
    primitive: Primitive,
    builtin: PrimitiveImpl,
    pub fn retain(self: Binding) void {
        switch (self) {
            .word => |body| heap.incRef(quotationHeader(body)),
            .value => |item| heap.retainValue(item),
            .primitive, .builtin => {},
        }
    }
    pub fn release(self: Binding, allocator: std.mem.Allocator) void {
        switch (self) {
            .word => |body| heap.decRef(allocator, quotationHeader(body)),
            .value => |item| heap.releaseValue(allocator, item),
            .primitive, .builtin => {},
        }
    }
};
pub const Visibility = enum { public, private };
pub const ValidatedEffect = struct {
    quotation: *EffectQuotation,
    inputs: u32,
    outputs: u32,
    pub fn header(self: ValidatedEffect) *value.Header {
        return @ptrCast(@alignCast(self.quotation));
    }
    pub fn retain(self: ValidatedEffect) void {
        heap.incRef(self.header());
    }
    pub fn release(self: ValidatedEffect, allocator: std.mem.Allocator) void {
        heap.decRef(allocator, self.header());
    }
    pub fn parse(
        effect_header: *value.Header,
        separator: u32,
        work: poll.WorkContext,
    ) poll.Error!?ValidatedEffect {
        if (effect_header.kind() != .generic_spine) return null;
        const item: value.Value = .{ .list = effect_header };
        const count: usize = @intCast(effect_header.length());
        var split: ?usize = null;
        var indices = work.indices(0, count);
        while (try indices.next()) |index| {
            const atom = list.atUnchecked(item, index);
            if (atom != .word) return null;
            if (atom.word == separator) {
                if (split != null) return null;
                split = index;
            }
        }
        const index = split orelse return null;
        return .{
            .quotation = @ptrCast(@alignCast(effect_header)),
            .inputs = @intCast(index),
            .outputs = @intCast(count - index - 1),
        };
    }
};
pub const Effect = ValidatedEffect;

pub const TopPublication = union(enum) {
    word: struct {
        body: *Quotation,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
    },
    value: value.Value,
};
pub const ModulePublication = union(enum) {
    word: struct {
        body: *Quotation,
        visibility: Visibility,
        effect: ValidatedEffect,
        doc: ?*DocumentationString = null,
    },
    value: struct {
        item: value.Value,
        visibility: Visibility,
    },
    primitive: struct {
        callback: Primitive,
        visibility: Visibility,
        effect: ValidatedEffect,
    },
};

const BindingSpec = struct {
    binding: Binding,
    visibility: Visibility = .public,
    home: ?intern.NamespaceName = null,
    effect: ?ValidatedEffect = null,
    doc: ?*DocumentationString = null,
    compiled: ?*Quotation = null,
    fn fromTop(publication: TopPublication) BindingSpec {
        return switch (publication) {
            .word => |word| .{
                .binding = .{ .word = word.body },
                .effect = word.effect,
                .doc = word.doc,
            },
            .value => |item| .{ .binding = .{ .value = item } },
        };
    }
    fn fromModule(
        home: intern.NamespaceName,
        publication: ModulePublication,
    ) BindingSpec {
        return switch (publication) {
            .word => |word| .{
                .binding = .{ .word = word.body },
                .visibility = word.visibility,
                .home = home,
                .effect = word.effect,
                .doc = word.doc,
            },
            .value => |item| .{
                .binding = .{ .value = item.item },
                .visibility = item.visibility,
                .home = home,
            },
            .primitive => |primitive| .{
                .binding = .{ .primitive = primitive.callback },
                .visibility = primitive.visibility,
                .home = home,
                .effect = primitive.effect,
            },
        };
    }
    fn retain(self: BindingSpec) void {
        self.binding.retain();
        if (self.effect) |effect| effect.retain();
        if (self.doc) |doc| heap.incRef(documentationHeader(doc));
        if (self.compiled) |compiled| heap.incRef(quotationHeader(compiled));
    }
    fn release(self: BindingSpec, allocator: std.mem.Allocator) void {
        self.binding.release(allocator);
        if (self.effect) |effect| effect.release(allocator);
        if (self.doc) |doc| heap.decRef(allocator, documentationHeader(doc));
        if (self.compiled) |compiled| heap.decRef(allocator, quotationHeader(compiled));
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
/// Owned payload snapshot; release it with the environment's allocator. This
/// is intentionally distinct from the unpublished internal specification.
pub const BindingLease = struct {
    binding: Binding,
    visibility: Visibility,
    home: ?intern.NamespaceName,
    effect: ?ValidatedEffect,
    doc: ?*DocumentationString,
    compiled: ?*Quotation,

    fn fromSpec(spec: BindingSpec) BindingLease {
        return .{
            .binding = spec.binding,
            .visibility = spec.visibility,
            .home = spec.home,
            .effect = spec.effect,
            .doc = spec.doc,
            .compiled = spec.compiled,
        };
    }

    pub fn deinit(self: *BindingLease, allocator: std.mem.Allocator) void {
        const spec = BindingSpec{
            .binding = self.binding,
            .visibility = self.visibility,
            .home = self.home,
            .effect = self.effect,
            .doc = self.doc,
            .compiled = self.compiled,
        };
        spec.release(allocator);
        self.* = undefined;
    }
};
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
        snapshot.spec.retain();
        const result = BindingLease.fromSpec(snapshot.spec);
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
    const NameMap = poll.U32Map(*BindingCell);
    names: NameMap,
    uses: []u32 = &.{},
    previous: ?*Shape = null,
    fn destroyChain(first: ?*Shape, allocator: std.mem.Allocator) void {
        var cursor = first;
        while (cursor) |shape| {
            cursor = shape.previous;
            shape.names.deinit();
            if (shape.uses.len > 0) allocator.free(shape.uses);
            allocator.destroy(shape);
        }
    }
};
pub const BindError = error{ OutOfMemory, Ecl, Frozen };
/// Publishes immutable name/use shapes and stable, lease-backed cells.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    writer: std.atomic.Mutex = .unlocked,
    current: std.atomic.Value(?*Shape) = .init(null),
    cells: poll.ChunkList(*BindingCell),
    shape_generation: std.atomic.Value(u64) = .init(0),
    frozen: std.atomic.Value(bool) = .init(false),
    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .allocator = allocator, .cells = .init(allocator) };
    }
    pub fn deinit(self: *Environment) void {
        Shape.destroyChain(self.current.load(.acquire), self.allocator);
        var cells = self.cells.iterator();
        while (cells.next()) |binding_cell| binding_cell.*.destroy(self.allocator);
        self.cells.deinit();
        self.* = undefined;
    }
    fn lock(self: *Environment, work: poll.WorkContext) poll.Error!void {
        while (!self.writer.tryLock()) {
            try work.step();
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *Environment) void {
        self.writer.unlock();
    }
    fn bind(
        self: *Environment,
        name: intern.NamespaceName,
        spec: BindingSpec,
        work: poll.WorkContext,
    ) BindError!*BindingCell {
        const id = intern.namespaceId(name);
        if (self.frozen.load(.acquire)) return error.Frozen;
        try self.lock(work);
        defer self.unlock();
        if (self.frozen.load(.acquire)) return error.Frozen;
        const old = self.current.load(.acquire);
        if (old) |shape| if (shape.names.get(id, work) catch |err| return err) |binding_cell| {
            try binding_cell.replace(self.allocator, spec);
            return binding_cell;
        };
        const binding_cell = try BindingCell.create(self.allocator, spec);
        errdefer binding_cell.destroy(self.allocator);
        const shape = try self.allocator.create(Shape);
        errdefer self.allocator.destroy(shape);
        const old_count = if (old) |prior| prior.names.count() else 0;
        const names = if (old) |prior|
            try prior.names.cloneGrow(1, work)
        else
            try Shape.NameMap.init(self.allocator, old_count + 1, work);
        shape.* = .{ .names = names, .previous = old };
        errdefer shape.names.deinit();
        errdefer if (shape.uses.len > 0) self.allocator.free(shape.uses);
        if (old) |prior| {
            if (prior.uses.len > 0) {
                shape.uses = try self.allocator.alloc(u32, prior.uses.len);
                var indices = work.indices(0, prior.uses.len);
                while (try indices.next()) |index| shape.uses[index] = prior.uses[index];
            }
        }
        _ = try shape.names.put(id, binding_cell, work);
        try self.cells.append(binding_cell);
        self.current.store(shape, .release);
        _ = self.shape_generation.fetchAdd(1, .release);
        return binding_cell;
    }
    pub fn resolveDirect(
        self: *const Environment,
        id: u32,
        work: poll.WorkContext,
    ) poll.Error!?BindingLease {
        const shape = self.current.load(.acquire) orelse return null;
        return (try shape.names.get(id, work) orelse return null).load();
    }
    pub fn cell(
        self: *const Environment,
        id: u32,
        work: poll.WorkContext,
    ) poll.Error!?*BindingCell {
        const shape = self.current.load(.acquire) orelse return null;
        return shape.names.get(id, work);
    }
    pub fn generation(self: *const Environment) u64 {
        return self.shape_generation.load(.acquire);
    }
    pub fn useOrder(self: *const Environment) []const u32 {
        const shape = self.current.load(.acquire) orelse return &.{};
        return shape.uses;
    }
    fn moveUseToTop(
        self: *Environment,
        canonical: u32,
        work: poll.WorkContext,
    ) BindError!void {
        if (self.frozen.load(.acquire)) return error.Frozen;
        try self.lock(work);
        defer self.unlock();
        if (self.frozen.load(.acquire)) return error.Frozen;
        const old = self.current.load(.acquire);
        const prior_uses = if (old) |shape| shape.uses else &.{};
        if (prior_uses.len > 0 and prior_uses[prior_uses.len - 1] == canonical) return;
        var found = false;
        var prior_cursor = work.cursor(u32, prior_uses);
        while (try prior_cursor.next()) |id| found = found or id == canonical;
        const new_len = prior_uses.len + @as(usize, @intFromBool(!found));
        const uses = try self.allocator.alloc(u32, new_len);
        errdefer self.allocator.free(uses);
        var index: usize = 0;
        var copy_cursor = work.cursor(u32, prior_uses);
        while (try copy_cursor.next()) |id| if (id != canonical) {
            uses[index] = id;
            index += 1;
        };
        uses[index] = canonical;
        const shape = try self.allocator.create(Shape);
        errdefer self.allocator.destroy(shape);
        const names = if (old) |prior|
            try prior.names.cloneGrow(0, work)
        else
            try Shape.NameMap.init(self.allocator, 0, work);
        shape.* = .{ .names = names, .uses = uses, .previous = old };
        errdefer shape.names.deinit();
        self.current.store(shape, .release);
        _ = self.shape_generation.fetchAdd(1, .release);
    }
    pub fn namesOwned(
        self: *const Environment,
        allocator: std.mem.Allocator,
        work: poll.WorkContext,
    ) poll.Error![]u32 {
        const shape = self.current.load(.acquire) orelse return allocator.alloc(u32, 0);
        const result = try allocator.alloc(u32, shape.names.count());
        errdefer allocator.free(result);
        var iterator = shape.names.entries(work);
        var index: usize = 0;
        while (try iterator.next()) |entry| : (index += 1) {
            result[index] = entry.key;
        }
        return result;
    }
    fn freeze(self: *Environment) void {
        self.lock(.unlimited()) catch unreachable;
        defer self.unlock();
        self.frozen.store(true, .release);
    }
};
pub const ScopeKind = enum { session, isolated, module_root };
const ScopeStorage = union(enum) {
    session: *Environment,
    core_build: *Environment,
    module_root: struct { target: *Environment, home: intern.NamespaceName },
    isolated_lazy,
    isolated_owned: *Environment,
};
pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    storage: ScopeStorage,
    fn direct(
        allocator: std.mem.Allocator,
        storage: ScopeStorage,
        parent: ?*Scope,
    ) Scope {
        return .{ .allocator = allocator, .parent = parent, .storage = storage };
    }
    pub fn moduleRoot(
        allocator: std.mem.Allocator,
        target: *Environment,
        home: intern.NamespaceName,
    ) Scope {
        return direct(allocator, .{ .module_root = .{ .target = target, .home = home } }, null);
    }
    pub fn lazy(allocator: std.mem.Allocator, parent: *Scope) Scope {
        return .{ .allocator = allocator, .parent = parent, .storage = .isolated_lazy };
    }
    pub fn kind(self: *const Scope) ScopeKind {
        return switch (self.storage) {
            .session => .session,
            .module_root => .module_root,
            .core_build => .session,
            .isolated_lazy, .isolated_owned => .isolated,
        };
    }
    pub fn environmentOrNull(self: *const Scope) ?*Environment {
        return switch (self.storage) {
            .session => |target| target,
            .core_build => |target| target,
            .module_root => |module| module.target,
            .isolated_lazy => null,
            .isolated_owned => |target| target,
        };
    }
    pub fn deinit(self: *Scope) void {
        if (self.storage == .isolated_owned) {
            const target = self.storage.isolated_owned;
            target.deinit();
            self.allocator.destroy(target);
        }
        self.* = undefined;
    }
    fn writableEnvironment(self: *Scope) error{OutOfMemory}!*Environment {
        return switch (self.storage) {
            .session => |target| target,
            .core_build => |target| target,
            .module_root => |module| module.target,
            .isolated_owned => |target| target,
            .isolated_lazy => blk: {
                const created = try self.allocator.create(Environment);
                created.* = Environment.init(self.allocator);
                self.storage = .{ .isolated_owned = created };
                break :blk created;
            },
        };
    }
    pub fn publishTop(
        self: *Scope,
        name: intern.NamespaceName,
        publication: TopPublication,
        work: poll.WorkContext,
    ) BindError!*BindingCell {
        return switch (self.storage) {
            .session, .core_build, .isolated_lazy, .isolated_owned => (try self.writableEnvironment()).bind(name, BindingSpec.fromTop(publication), work),
            .module_root => unreachable,
        };
    }
    pub fn publishModule(
        self: *Scope,
        name: intern.NamespaceName,
        publication: ModulePublication,
        work: poll.WorkContext,
    ) BindError!*BindingCell {
        return switch (self.storage) {
            .module_root => |module| module.target.bind(
                name,
                BindingSpec.fromModule(module.home, publication),
                work,
            ),
            else => unreachable,
        };
    }
    pub fn moveUseToTop(self: *Scope, canonical: u32, work: poll.WorkContext) BindError!void {
        return (try self.writableEnvironment()).moveUseToTop(canonical, work);
    }
    pub fn freezeModule(self: *Scope) void {
        switch (self.storage) {
            .module_root => |module| module.target.freeze(),
            else => unreachable,
        }
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
    pub fn define(
        self: *Env,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) error{OutOfMemory}!void {
        _ = self.session.bind(name, BindingSpec.fromTop(publication), .unlimited()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => unreachable,
            error.Frozen => unreachable,
        };
    }
    fn installCore(self: *Env, name: intern.NamespaceName, binding: Binding) error{OutOfMemory}!void {
        _ = self.core.bind(name, .{ .binding = binding }, .unlimited()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => unreachable,
            error.Frozen => unreachable,
        };
    }
    pub fn beginCoreBuild(self: *Env) BuildingEnv {
        return .{ .target = self };
    }
    pub fn sessionRoot(self: *Env, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .{ .session = &self.session }, null);
    }
};
/// Typestate capability for the only phase in which core publication is
/// legal. `finish` consumes the capability and freezes the core.
pub const BuildingEnv = struct {
    target: *Env,

    pub fn installCore(
        self: *BuildingEnv,
        name: intern.NamespaceName,
        binding: Binding,
    ) error{OutOfMemory}!void {
        try self.target.installCore(name, binding);
    }
    pub fn installBuiltins(self: *BuildingEnv, comptime definitions: anytype) error{OutOfMemory}!void {
        comptime {
            for (definitions, 0..) |definition, index| {
                assertStaticNamespace(definition.name);
                for (definitions[0..index]) |prior| {
                    if (std.mem.eql(u8, prior.name, definition.name)) {
                        @compileError("duplicate builtin namespace name: " ++ definition.name);
                    }
                }
            }
        }
        inline for (definitions) |definition| {
            try self.installCore(
                try intern.trustedNamespace(definition.name),
                .{ .builtin = definition.primitive },
            );
        }
    }
    pub fn runtime(self: *BuildingEnv) *Env {
        return self.target;
    }
    pub fn rootScope(self: *BuildingEnv, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .{ .core_build = &self.target.core }, null);
    }
    pub fn finish(self: *BuildingEnv) void {
        self.target.core.freeze();
        self.* = undefined;
    }
};
pub fn assertStaticNamespace(comptime name: []const u8) void {
    if (name.len == 0 or intern.isReservedBytes(name) or
        std.mem.indexOfScalar(u8, name, '.') != null)
    {
        @compileError("invalid builtin namespace name: " ++ name);
    }
}
fn definitionFailureProbe(allocator: std.mem.Allocator) !void {
    var environment = Env.init(allocator);
    defer environment.deinit();
    const body = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(allocator, body);
    const name = try intern.trustedNamespace("failure-probe");
    try environment.define(name, .{ .word = .{ .body = quotation(body.list).? } });
    try environment.define(name, .{ .value = .{ .int = 9 } });
}
test "environment lookup and redefine are late-bound" {
    var environment = Env.init(std.testing.allocator);
    defer environment.deinit();
    const name = try intern.trustedNamespace("env-test");
    var building = environment.beginCoreBuild();
    try building.installCore(name, .{ .value = .{ .int = 1 } });
    building.finish();
    var core = (try environment.core.resolveDirect(intern.namespaceId(name), .unlimited())).?;
    defer core.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), core.binding.value.int);
    try environment.define(name, .{ .value = .{ .int = 2 } });
    var local = (try environment.session.resolveDirect(intern.namespaceId(name), .unlimited())).?;
    defer local.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), local.binding.value.int);
    try std.testing.expect(try environment.session.resolveDirect(99, .unlimited()) == null);
}
test "env: same-name rebind preserves cell identity and shape" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var scope = Scope.direct(std.testing.allocator, .{ .session = &environment }, null);
    defer scope.deinit();
    const name = try intern.trustedNamespace("cell-test");
    const first = try scope.publishTop(name, .{ .value = .{ .int = 1 } }, .unlimited());
    const generation = environment.generation();
    const second = try scope.publishTop(name, .{ .value = .{ .int = 2 } }, .unlimited());
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(generation, environment.generation());
    var lease = (try environment.resolveDirect(intern.namespaceId(name), .unlimited())).?;
    defer lease.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), lease.binding.value.int);
}
test "environment definition propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, definitionFailureProbe, .{});
}
