//! Stable binding cells, immutable environment shapes, and lazy scopes.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const native_module = @import("native_module.zig");
const primitive_docs = @import("primitive_docs.zig");
const snapshot_api = @import("snapshot.zig");
/// In-tree primitives use Machine's ergonomic error helpers. This binding
/// kind is not part of the native-extension ABI.
pub const PrimitiveImpl = *const fn (*machine.Machine) machine.MachineError!void;

/// A native definition together with the nominal image pin that owns its
/// callback. Only the loader can construct the opaque `ModuleInstance`.
pub const NativeCallable = struct {
    instance: *native_module.ModuleInstance,
    definition: u32,
};

pub const Quotation = opaque {};
pub const DocumentationString = opaque {};
pub const EffectQuotation = opaque {};

pub fn quotation(header: *value.ListHandle) ?*Quotation {
    return switch (header.kind()) {
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => @ptrCast(@alignCast(header)),
        .dict, .task, .reserved_mask => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.ListHandle) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .reserved_mask => null,
    };
}

pub fn documentationHeader(document: *const DocumentationString) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(document)));
}

pub const Binding = union(enum) {
    word: *Quotation,
    value: value.Value,
    builtin: PrimitiveImpl,
    native: NativeCallable,
    pub fn retain(self: Binding) void {
        switch (self) {
            .word => |body| heap.incRef(quotationHeader(body)),
            .value => |item| heap.retainValue(item),
            .builtin => {},
            .native => |callable| callable.instance.retain(),
        }
    }
    pub fn retire(self: Binding, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .word => |body| releases.releaseHeader(quotationHeader(body)),
            .value => |item| releases.releaseValue(item),
            .builtin => {},
            .native => |callable| callable.instance.releasePin(),
        }
    }
};
pub const Visibility = enum { public, private };
pub const BindingOrigin = union(enum) {
    top,
    module: struct {
        home: intern.NamespaceName,
        trace_word: u32,
    },

    pub fn home(self: BindingOrigin) ?intern.NamespaceName {
        return switch (self) {
            .top => null,
            .module => |module| module.home,
        };
    }

    pub fn traceWord(self: BindingOrigin) ?u32 {
        return switch (self) {
            .top => null,
            .module => |module| module.trace_word,
        };
    }
};
pub const ValidatedEffect = struct {
    quotation: *EffectQuotation,
    inputs: u32,
    outputs: u32,
    pub fn header(self: ValidatedEffect) *value.ListHandle {
        return @ptrCast(@alignCast(self.quotation));
    }
    pub fn retain(self: ValidatedEffect) void {
        heap.incRef(self.header());
    }
    pub fn retire(self: ValidatedEffect, releases: *heap.ReleaseDomain) void {
        releases.releaseHeader(self.header());
    }
    pub fn fromValidated(effect_header: *value.ListHandle, separator_index: usize) ValidatedEffect {
        std.debug.assert(effect_header.kind() == .generic_spine and separator_index < effect_header.length());
        return .{
            .quotation = @ptrCast(@alignCast(effect_header)),
            .inputs = @intCast(separator_index),
            .outputs = @intCast(@as(usize, @intCast(effect_header.length())) - separator_index - 1),
        };
    }
    pub const ParseProgress = union(enum) { pending, complete: ?ValidatedEffect };
    pub const ParseCursor = struct {
        header: *value.ListHandle,
        separator: u32,
        index: usize = 0,
        split: ?usize = null,
        pub fn advance(self: *ParseCursor) ParseProgress {
            if (self.header.kind() != .generic_spine) return .{ .complete = null };
            const count: usize = @intCast(self.header.length());
            if (self.index == count) {
                const split = self.split orelse return .{ .complete = null };
                return .{ .complete = .{
                    .quotation = @ptrCast(@alignCast(self.header)),
                    .inputs = @intCast(split),
                    .outputs = @intCast(count - split - 1),
                } };
            }
            const atom = list.atUnchecked(.{ .list = self.header }, self.index);
            if (atom != .word) return .{ .complete = null };
            if (atom.word == self.separator) {
                if (self.split != null) return .{ .complete = null };
                self.split = self.index;
            }
            self.index += 1;
            return .pending;
        }
    };
    pub fn parse(effect_header: *value.ListHandle, separator: u32) ?ValidatedEffect {
        var cursor = ParseCursor{ .header = effect_header, .separator = separator };
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |effect| return effect,
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
    native: struct {
        callable: NativeCallable,
        visibility: Visibility,
        effect: ValidatedEffect,
        doc: *DocumentationString,
    },
};

const BindingSpec = struct {
    binding: Binding,
    visibility: Visibility = .public,
    origin: BindingOrigin = .top,
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
        trace_word: u32,
        publication: ModulePublication,
    ) BindingSpec {
        return switch (publication) {
            .word => |word| .{
                .binding = .{ .word = word.body },
                .visibility = word.visibility,
                .origin = .{ .module = .{ .home = home, .trace_word = trace_word } },
                .effect = word.effect,
                .doc = word.doc,
            },
            .value => |item| .{
                .binding = .{ .value = item.item },
                .visibility = item.visibility,
                .origin = .{ .module = .{ .home = home, .trace_word = trace_word } },
            },
            .native => |native| .{
                .binding = .{ .native = native.callable },
                .visibility = native.visibility,
                .origin = .{ .module = .{ .home = home, .trace_word = trace_word } },
                .effect = native.effect,
                .doc = native.doc,
            },
        };
    }
    fn retain(self: BindingSpec) void {
        self.binding.retain();
        if (self.effect) |effect| effect.retain();
        if (self.doc) |doc| heap.incRef(documentationHeader(doc));
        if (self.compiled) |compiled| heap.incRef(quotationHeader(compiled));
    }
    fn retire(self: BindingSpec, releases: *heap.ReleaseDomain) void {
        self.binding.retire(releases);
        if (self.effect) |effect| effect.retire(releases);
        if (self.doc) |doc| releases.releaseHeader(documentationHeader(doc));
        if (self.compiled) |compiled| releases.releaseHeader(quotationHeader(compiled));
    }
    pub fn deinit(self: *BindingSpec, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
};
const BindingSnapshot = struct {
    retirement: heap.ReleaseDomain.Retirement = .{},
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
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *BindingSnapshot,
    ) bool {
        const previous = self.previous;
        self.spec.retire(releases);
        allocator.destroy(self);
        if (previous) |next| releases.retire(next, &next.retirement);
        return true;
    }
    fn destroyChain(
        first: ?*BindingSnapshot,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
    ) void {
        var cursor = first;
        while (cursor) |snapshot| {
            cursor = snapshot.previous;
            snapshot.spec.retire(releases);
            allocator.destroy(snapshot);
        }
    }
};
/// Owned payload snapshot; release it with the environment's allocator. This
/// is intentionally distinct from the unpublished internal specification.
pub const BindingLease = struct {
    releases: *heap.ReleaseDomain,
    binding: Binding,
    visibility: Visibility,
    origin: BindingOrigin,
    effect: ?ValidatedEffect,
    doc: ?*DocumentationString,
    compiled: ?*Quotation,

    fn fromSpec(spec: BindingSpec, releases: *heap.ReleaseDomain) BindingLease {
        return .{
            .releases = releases,
            .binding = spec.binding,
            .visibility = spec.visibility,
            .origin = spec.origin,
            .effect = spec.effect,
            .doc = spec.doc,
            .compiled = spec.compiled,
        };
    }

    pub fn deinit(self: *BindingLease) void {
        const spec = BindingSpec{
            .binding = self.binding,
            .visibility = self.visibility,
            .origin = self.origin,
            .effect = self.effect,
            .doc = self.doc,
            .compiled = self.compiled,
        };
        spec.retire(self.releases);
        self.* = undefined;
    }

    pub fn home(self: BindingLease) ?intern.NamespaceName {
        return self.origin.home();
    }

    pub fn traceWord(self: BindingLease) ?u32 {
        return self.origin.traceWord();
    }
};
pub const BindingCell = struct {
    const Publisher = snapshot_api.Publisher(BindingSnapshot);
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    publisher: Publisher,
    snapshots: *BindingSnapshot,
    retire_lock: std.Io.Mutex = .init,
    retirement: heap.ReleaseDomain.Retirement = .{},
    fn create(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        spec: BindingSpec,
    ) error{OutOfMemory}!*BindingCell {
        const snapshot = try BindingSnapshot.create(allocator, spec, null);
        errdefer BindingSnapshot.destroyChain(snapshot, allocator, releases);
        const cell = try allocator.create(BindingCell);
        cell.* = .{
            .allocator = allocator,
            .releases = releases,
            .publisher = .init(snapshot),
            .snapshots = snapshot,
        };
        return cell;
    }
    fn replace(
        self: *BindingCell,
        allocator: std.mem.Allocator,
        spec: BindingSpec,
    ) error{OutOfMemory}!void {
        self.lockRetired();
        const snapshot = BindingSnapshot.create(allocator, spec, self.snapshots) catch {
            std.Io.Threaded.mutexUnlock(&self.retire_lock);
            return error.OutOfMemory;
        };
        self.snapshots = snapshot;
        self.publisher.publish(snapshot);
        const retired = self.detachRetired();
        std.Io.Threaded.mutexUnlock(&self.retire_lock);
        if (retired) |first| self.releases.retire(first, &first.retirement);
    }
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *BindingCell,
    ) bool {
        std.debug.assert(self.publisher.quiescent());
        const snapshots = self.publisher.currentOwned();
        self.publisher.publish(null);
        if (snapshots) |first| releases.retire(first, &first.retirement);
        allocator.destroy(self);
        return true;
    }
    fn retire(self: *BindingCell) void {
        self.releases.retire(self, &self.retirement);
    }
    fn lockRetired(self: *BindingCell) void {
        std.Io.Threaded.mutexLock(&self.retire_lock);
    }
    fn detachRetired(self: *BindingCell) ?*BindingSnapshot {
        if (!self.publisher.quiescent()) return null;
        const retired = self.snapshots.previous;
        self.snapshots.previous = null;
        return retired;
    }
    pub fn load(self: *BindingCell) BindingLease {
        var lease = self.publisher.acquire();
        lease.snapshot.?.spec.retain();
        const result = BindingLease.fromSpec(lease.snapshot.?.spec, self.releases);
        if (lease.deinit()) {
            self.lockRetired();
            const retired = self.detachRetired();
            std.Io.Threaded.mutexUnlock(&self.retire_lock);
            if (retired) |first| self.releases.retire(first, &first.retirement);
        }
        return result;
    }
};
const Shape = struct {
    const NameMap = poll.FixedMap(intern.NamespaceName, *BindingCell);
    names: NameMap,
    uses: []u32 = &.{},
    previous: ?*Shape = null,
    retirement: heap.ReleaseDomain.Retirement = .{},
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Shape,
    ) bool {
        const previous = self.previous;
        self.names.deinit();
        if (self.uses.len > 0) allocator.free(self.uses);
        allocator.destroy(self);
        if (previous) |next| releases.retire(next, &next.retirement);
        return true;
    }
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
const ShapePublisher = snapshot_api.Publisher(Shape);

/// Copyable observation authority for an environment. The backing pointer is
/// intentionally unavailable: readers can create leases and cursors, but
/// cannot retarget allocator or retirement ownership metadata.
pub const EnvironmentView = enum(usize) {
    invalid = 0,
    _,

    fn init(environment: *const Environment) EnvironmentView {
        return @enumFromInt(@intFromPtr(environment));
    }

    fn target(self: EnvironmentView) *const Environment {
        std.debug.assert(self != .invalid);
        return @ptrFromInt(@intFromEnum(self));
    }

    pub fn acquireShape(self: EnvironmentView) ShapeLease {
        return self.target().acquireShape();
    }

    pub fn nameCursor(self: EnvironmentView) NameCursor {
        return self.target().nameCursor();
    }

    pub fn directLookupCursor(self: EnvironmentView, id: u32) DirectLookupCursor {
        return self.target().directLookupCursor(id);
    }

    pub fn resolveDirect(self: EnvironmentView, id: u32) ?BindingLease {
        return self.target().resolveDirect(id);
    }

    pub fn generation(self: EnvironmentView) u64 {
        return self.target().generation();
    }

    pub fn namesOwned(
        self: EnvironmentView,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u32 {
        return self.target().namesOwned(allocator);
    }
};
comptime {
    heap.requireOpaqueObservation(EnvironmentView);
}

pub const ShapeLease = struct {
    environment: EnvironmentView,
    lease: ShapePublisher.Lease,
    shape: ?*const Shape,

    pub fn useOrder(self: *const ShapeLease) []const u32 {
        return if (self.shape) |shape| shape.uses else &.{};
    }

    fn nameCount(self: *const ShapeLease) usize {
        return if (self.shape) |shape| shape.names.count() else 0;
    }

    pub fn deinit(self: *ShapeLease) void {
        const environment = @constCast(self.environment.target());
        if (self.lease.deinit()) {
            environment.lockBlocking();
            const retired = environment.detachRetiredShapes();
            environment.unlock();
            if (retired) |first| environment.releases.retire(first, &first.retirement);
        }
        self.* = undefined;
    }
};
pub const NameEntry = struct { name: u32, lease: BindingLease };
pub const NameCursorProgress = union(enum) { pending, complete, entry: NameEntry };
pub const NameCursor = struct {
    shape: ShapeLease,
    entries: ?Shape.NameMap.RawEntryCursor,

    pub fn deinit(self: *NameCursor) void {
        self.shape.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *NameCursor) NameCursorProgress {
        const entries = &(self.entries orelse return .complete);
        return switch (entries.advance()) {
            .pending => .pending,
            .complete => .complete,
            .entry => |entry| .{ .entry = .{
                .name = intern.namespaceId(entry.key),
                .lease = entry.value.load(),
            } },
        };
    }
};

pub const DirectLookupProgress = union(enum) { pending, complete: ?BindingLease };
pub const DirectLookupCursor = struct {
    shape: ShapeLease,
    lookup: ?Shape.NameMap.RawLookupCursor,
    pub fn deinit(self: *DirectLookupCursor) void {
        self.shape.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *DirectLookupCursor) DirectLookupProgress {
        const lookup = &(self.lookup orelse return .{ .complete = null });
        return switch (lookup.advance()) {
            .pending => .pending,
            .complete => |cell| .{ .complete = if (cell) |binding_cell| binding_cell.load() else null },
        };
    }
};
pub const BindError = error{ OutOfMemory, Frozen };
/// Publishes immutable name/use shapes and stable, lease-backed cells.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    writer: std.Io.Mutex = .init,
    shapes: ShapePublisher,
    cells: poll.ChunkList(*BindingCell),
    shape_generation: std.atomic.Value(u64) = .init(0),
    frozen: std.atomic.Value(bool) = .init(false),

    pub const TeardownCursor = struct {
        target: *Environment,
        state: union(enum) {
            shapes: ?*Shape,
            cells: poll.ChunkList(*BindingCell).Iterator,
            storage,
            complete,
        },

        pub fn init(target: *Environment) TeardownCursor {
            std.debug.assert(target.shapes.quiescent());
            const shapes = target.shapes.currentOwned();
            target.shapes.publish(null);
            return .{ .target = target, .state = .{ .shapes = shapes } };
        }

        pub fn advance(self: *TeardownCursor) bool {
            return switch (self.state) {
                .shapes => |shapes| result: {
                    if (shapes) |first|
                        self.target.releases.retire(first, &first.retirement);
                    self.state = .{ .cells = self.target.cells.iterator() };
                    break :result false;
                },
                .cells => |*cells| if (cells.next()) |binding_cell| result: {
                    const cell = binding_cell.*;
                    self.target.releases.retire(cell, &cell.retirement);
                    break :result false;
                } else result: {
                    self.state = .storage;
                    break :result false;
                },
                .storage => {
                    self.target.cells.retire(self.target.releases);
                    self.state = .complete;
                    return true;
                },
                .complete => true,
            };
        }
    };
    pub fn init(allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) Environment {
        return .{
            .allocator = allocator,
            .releases = releases,
            .shapes = .init(null),
            .cells = .init(allocator),
        };
    }
    fn lockBlocking(self: *Environment) void {
        std.Io.Threaded.mutexLock(&self.writer);
    }
    fn unlock(self: *Environment) void {
        std.Io.Threaded.mutexUnlock(&self.writer);
    }
    fn detachRetiredShapes(self: *Environment) ?*Shape {
        if (!self.shapes.quiescent()) return null;
        const current = self.shapes.currentOwned() orelse return null;
        const retired = current.previous;
        current.previous = null;
        return retired;
    }
    pub fn acquireShape(self: *const Environment) ShapeLease {
        const lease = self.shapes.acquire();
        return .{
            .environment = .init(self),
            .shape = lease.snapshot,
            .lease = lease,
        };
    }
    pub fn nameCursor(self: *const Environment) NameCursor {
        const shape = self.acquireShape();
        return .{
            .entries = if (shape.shape) |current| current.names.rawEntries() else null,
            .shape = shape,
        };
    }
    pub fn directLookupCursor(self: *const Environment, id: u32) DirectLookupCursor {
        const shape = self.acquireShape();
        return .{
            .lookup = if (shape.shape) |current|
                current.names.rawLookup(@enumFromInt(id))
            else
                null,
            .shape = shape,
        };
    }

    pub const BindProgress = union(enum) { pending, complete: *BindingCell };
    pub const BindCursor = struct {
        const Builder = union(enum) {
            initialize: Shape.NameMap.InitCursor,
            clone: Shape.NameMap.CloneCursor,

            fn deinit(self: *Builder) void {
                switch (self.*) {
                    inline else => |*cursor| cursor.deinit(),
                }
            }
        };
        const Built = struct { shape: ShapeLease, names: Shape.NameMap, uses: []u32 };
        const State = union(enum) {
            snapshot,
            lookup: struct { shape: ShapeLease, cursor: ?Shape.NameMap.RawLookupCursor },
            build: struct { shape: ShapeLease, builder: Builder },
            allocate_uses: struct { shape: ShapeLease, names: Shape.NameMap },
            copy_uses: struct {
                built: Built,
                index: usize = 0,
            },
            insert: struct { built: *Built, cursor: Shape.NameMap.PutCursor },
            commit: *Built,
            complete,
        };

        environment: *Environment,
        id: intern.NamespaceName,
        spec: BindingSpec,
        candidate_cell: ?*BindingCell,
        state: State = .snapshot,

        fn init(
            environment: *Environment,
            id: intern.NamespaceName,
            spec: BindingSpec,
        ) error{OutOfMemory}!BindCursor {
            return .{
                .environment = environment,
                .id = id,
                .spec = spec,
                .candidate_cell = try BindingCell.create(
                    environment.allocator,
                    environment.releases,
                    spec,
                ),
            };
        }
        pub fn deinit(self: *BindCursor) void {
            switch (self.state) {
                .lookup => |*state| state.shape.deinit(),
                .build => |*state| {
                    state.builder.deinit();
                    state.shape.deinit();
                },
                .allocate_uses => |*state| {
                    state.names.deinit();
                    state.shape.deinit();
                },
                .copy_uses => |*state| self.deinitBuilt(&state.built),
                .insert => |state| self.destroyBuilt(state.built),
                .commit => |built| self.destroyBuilt(built),
                .snapshot, .complete => {},
            }
            if (self.candidate_cell) |candidate| candidate.retire();
            self.* = undefined;
        }
        fn deinitBuilt(self: *BindCursor, built: *Built) void {
            built.names.deinit();
            self.environment.allocator.free(built.uses);
            built.shape.deinit();
        }
        fn destroyBuilt(self: *BindCursor, built: *Built) void {
            self.deinitBuilt(built);
            self.environment.allocator.destroy(built);
        }
        pub fn advance(self: *BindCursor) BindError!BindProgress {
            return switch (self.state) {
                .snapshot => result: {
                    if (self.environment.frozen.load(.acquire)) return error.Frozen;
                    const shape = self.environment.acquireShape();
                    self.state = .{ .lookup = .{
                        .cursor = if (shape.shape) |current| current.names.rawLookup(self.id) else null,
                        .shape = shape,
                    } };
                    break :result .pending;
                },
                .lookup => |*state| if (state.cursor) |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_cell| result: {
                        if (maybe_cell) |existing| {
                            self.environment.lockBlocking();
                            if (self.environment.frozen.load(.acquire)) {
                                self.environment.unlock();
                                return error.Frozen;
                            }
                            existing.replace(self.environment.allocator, self.spec) catch |err| {
                                self.environment.unlock();
                                return err;
                            };
                            self.environment.unlock();
                            self.candidate_cell.?.retire();
                            self.candidate_cell = null;
                            state.shape.deinit();
                            self.state = .complete;
                            break :result .{ .complete = existing };
                        }
                        self.state = .{ .build = .{
                            .shape = state.shape,
                            .builder = .{ .clone = state.shape.shape.?.names.cloneCursor(1) },
                        } };
                        break :result .pending;
                    },
                } else result: {
                    self.state = .{ .build = .{
                        .shape = state.shape,
                        .builder = .{ .initialize = Shape.NameMap.initCursor(
                            self.environment.allocator,
                            1,
                        ) },
                    } };
                    break :result .pending;
                },
                .build => |*state| switch (state.builder) {
                    inline else => |*builder| switch (try builder.advance()) {
                        .pending => .pending,
                        .complete => |names| result: {
                            builder.deinit();
                            self.state = .{ .allocate_uses = .{
                                .shape = state.shape,
                                .names = names,
                            } };
                            break :result .pending;
                        },
                    },
                },
                .allocate_uses => |*state| result: {
                    const uses = try self.environment.allocator.alloc(u32, state.shape.useOrder().len);
                    self.state = .{ .copy_uses = .{ .built = .{
                        .shape = state.shape,
                        .names = state.names,
                        .uses = uses,
                    } } };
                    break :result .pending;
                },
                .copy_uses => |*state| result: {
                    const prior_uses = state.built.shape.useOrder();
                    if (state.index != prior_uses.len) {
                        state.built.uses[state.index] = prior_uses[state.index];
                        state.index += 1;
                    } else {
                        const built = try self.environment.allocator.create(Built);
                        built.* = state.built;
                        self.state = .{ .insert = .{
                            .built = built,
                            .cursor = built.names.putCursor(self.id, self.candidate_cell.?),
                        } };
                    }
                    break :result .pending;
                },
                .insert => |*state| switch (state.cursor.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.state = .{ .commit = state.built };
                        break :result .pending;
                    },
                },
                .commit => |state| result: {
                    const next = try self.environment.allocator.create(Shape);
                    self.environment.lockBlocking();
                    if (self.environment.frozen.load(.acquire)) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        return error.Frozen;
                    }
                    if (!self.environment.shapes.isCurrent(state.shape.shape)) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        self.destroyBuilt(state);
                        self.state = .snapshot;
                        break :result .pending;
                    }
                    const published_cell = self.candidate_cell.?;
                    self.environment.cells.append(published_cell) catch {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        return error.OutOfMemory;
                    };
                    next.* = .{
                        .names = state.names,
                        .uses = state.uses,
                        .previous = self.environment.shapes.currentOwned(),
                    };
                    self.candidate_cell = null;
                    self.environment.shapes.publish(next);
                    _ = self.environment.shape_generation.fetchAdd(1, .release);
                    self.environment.unlock();
                    state.shape.deinit();
                    self.environment.allocator.destroy(state);
                    self.state = .complete;
                    break :result .{ .complete = published_cell };
                },
                .complete => unreachable,
            };
        }
    };

    fn bindCursor(
        self: *Environment,
        name: intern.NamespaceName,
        spec: BindingSpec,
    ) error{OutOfMemory}!BindCursor {
        return .init(self, name, spec);
    }
    fn bind(
        self: *Environment,
        name: intern.NamespaceName,
        spec: BindingSpec,
    ) BindError!*BindingCell {
        var cursor = try self.bindCursor(name, spec);
        defer cursor.deinit();
        while (true) switch (try cursor.advance()) {
            .pending => {},
            .complete => |cell| return cell,
        };
    }
    pub fn resolveDirect(self: *const Environment, id: u32) ?BindingLease {
        var cursor = self.directLookupCursor(id);
        defer cursor.deinit();
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |lease| return lease,
        };
    }
    pub fn generation(self: *const Environment) u64 {
        return self.shape_generation.load(.acquire);
    }
    fn moveUseToTop(self: *Environment, canonical: u32) BindError!void {
        var cursor = MoveUseCursor.init(self, canonical);
        defer cursor.deinit();
        while (true) switch (try cursor.advance()) {
            .pending => {},
            .complete => return,
        };
    }
    pub const MoveUseProgress = enum { pending, complete };
    pub const MoveUseCursor = struct {
        environment: *Environment,
        canonical: u32,
        shape: ?ShapeLease = null,
        scan_index: usize = 0,
        found: bool = false,
        uses: ?[]u32 = null,
        copy_index: usize = 0,
        output_index: usize = 0,
        cloner: ?Shape.NameMap.CloneCursor = null,
        initializer: ?Shape.NameMap.InitCursor = null,
        names: ?Shape.NameMap = null,
        phase: enum { snapshot, scan, copy, names, commit, complete } = .snapshot,

        pub fn init(environment: *Environment, canonical: u32) MoveUseCursor {
            return .{ .environment = environment, .canonical = canonical };
        }
        pub fn deinit(self: *MoveUseCursor) void {
            if (self.shape) |*shape| shape.deinit();
            if (self.cloner) |*cloner| cloner.deinit();
            if (self.initializer) |*initializer| initializer.deinit();
            if (self.names) |*names| names.deinit();
            if (self.uses) |uses| self.environment.allocator.free(uses);
            self.* = undefined;
        }
        fn reset(self: *MoveUseCursor) void {
            if (self.shape) |*shape| shape.deinit();
            self.shape = null;
            if (self.cloner) |*cloner| cloner.deinit();
            self.cloner = null;
            if (self.initializer) |*initializer| initializer.deinit();
            self.initializer = null;
            if (self.names) |*names| names.deinit();
            self.names = null;
            if (self.uses) |uses| self.environment.allocator.free(uses);
            self.uses = null;
            self.scan_index = 0;
            self.copy_index = 0;
            self.output_index = 0;
            self.found = false;
            self.phase = .snapshot;
        }
        pub fn advance(self: *MoveUseCursor) BindError!MoveUseProgress {
            return switch (self.phase) {
                .snapshot => result: {
                    if (self.environment.frozen.load(.acquire)) return error.Frozen;
                    self.shape = self.environment.acquireShape();
                    const prior = self.shape.?.useOrder();
                    if (prior.len != 0 and prior[prior.len - 1] == self.canonical) {
                        self.phase = .complete;
                        break :result .complete;
                    }
                    self.phase = .scan;
                    break :result .pending;
                },
                .scan => result: {
                    const prior = self.shape.?.useOrder();
                    if (self.scan_index != prior.len) {
                        self.found = self.found or prior[self.scan_index] == self.canonical;
                        self.scan_index += 1;
                    } else {
                        self.uses = try self.environment.allocator.alloc(
                            u32,
                            prior.len + @as(usize, @intFromBool(!self.found)),
                        );
                        self.phase = .copy;
                    }
                    break :result .pending;
                },
                .copy => result: {
                    const prior = self.shape.?.useOrder();
                    if (self.copy_index != prior.len) {
                        const name = prior[self.copy_index];
                        self.copy_index += 1;
                        if (name != self.canonical) {
                            self.uses.?[self.output_index] = name;
                            self.output_index += 1;
                        }
                    } else {
                        self.uses.?[self.output_index] = self.canonical;
                        if (self.shape.?.shape) |shape|
                            self.cloner = shape.names.cloneCursor(0)
                        else
                            self.initializer = Shape.NameMap.initCursor(self.environment.allocator, 0);
                        self.phase = .names;
                    }
                    break :result .pending;
                },
                .names => if (self.cloner) |*cloner| switch (try cloner.advance()) {
                    .pending => .pending,
                    .complete => |names| result: {
                        cloner.deinit();
                        self.cloner = null;
                        self.names = names;
                        self.phase = .commit;
                        break :result .pending;
                    },
                } else switch (try self.initializer.?.advance()) {
                    .pending => .pending,
                    .complete => |names| result: {
                        self.initializer.?.deinit();
                        self.initializer = null;
                        self.names = names;
                        self.phase = .commit;
                        break :result .pending;
                    },
                },
                .commit => result: {
                    const next = try self.environment.allocator.create(Shape);
                    self.environment.lockBlocking();
                    if (self.environment.frozen.load(.acquire)) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        return error.Frozen;
                    }
                    if (!self.environment.shapes.isCurrent(self.shape.?.shape)) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        self.reset();
                        break :result .pending;
                    }
                    next.* = .{
                        .names = self.names.?,
                        .uses = self.uses.?,
                        .previous = self.environment.shapes.currentOwned(),
                    };
                    self.names = null;
                    self.uses = null;
                    self.environment.shapes.publish(next);
                    _ = self.environment.shape_generation.fetchAdd(1, .release);
                    self.environment.unlock();
                    self.phase = .complete;
                    break :result .complete;
                },
                .complete => unreachable,
            };
        }
    };
    pub fn namesOwned(
        self: *const Environment,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u32 {
        var cursor = self.nameCursor();
        defer cursor.deinit();
        const result = try allocator.alloc(u32, cursor.shape.nameCount());
        errdefer allocator.free(result);
        var index: usize = 0;
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => break,
            .entry => |entry| {
                var lease = entry.lease;
                lease.deinit();
                result[index] = entry.name;
                index += 1;
            },
        };
        std.debug.assert(index == result.len);
        return result;
    }
    fn freeze(self: *Environment) void {
        self.lockBlocking();
        defer self.unlock();
        self.frozen.store(true, .release);
    }
};
pub const ScopeKind = enum { session, isolated, module_root };
const ScopeAllocation = enum { embedded, heap };
const ScopeStorage = union(enum) {
    session: *Environment,
    core_build: *Environment,
    module_root: struct { target: *Environment, home: intern.NamespaceName },
    isolated,
};
pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    storage: ScopeStorage,
    refs: std.atomic.Value(u32) = .init(1),
    allocation: ScopeAllocation = .embedded,
    isolated_environment: std.atomic.Value(?*Environment) = .init(null),
    publication_lock: std.Io.Mutex = .init,
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: ?RetireCursor.State = null,

    pub const RetireCursor = struct {
        scope: *Scope,
        state: State,

        const State = union(enum) {
            environment: struct {
                target: *Environment,
                cursor: Environment.TeardownCursor,
            },
            parent,
            destroy,
            complete,
        };

        pub fn init(scope: *Scope) RetireCursor {
            const old = scope.refs.fetchSub(1, .release);
            std.debug.assert(old != 0);
            if (old != 1) return .{ .scope = scope, .state = .complete };
            _ = scope.refs.load(.acquire);
            const target = if (scope.storage == .isolated)
                scope.isolated_environment.load(.acquire)
            else
                null;
            return .{
                .scope = scope,
                .state = if (target) |environment|
                    .{ .environment = .{
                        .target = environment,
                        .cursor = .init(environment),
                    } }
                else
                    .parent,
            };
        }

        pub fn advance(self: *RetireCursor) bool {
            return switch (self.state) {
                .environment => |*environment| result: {
                    if (!environment.cursor.advance()) break :result false;
                    self.scope.isolated_environment.store(null, .release);
                    self.scope.allocator.destroy(environment.target);
                    self.state = .parent;
                    break :result false;
                },
                .parent => result: {
                    if (self.scope.parent) |parent| parent.retire();
                    self.state = .destroy;
                    break :result false;
                },
                .destroy => {
                    const allocator = self.scope.allocator;
                    const allocation = self.scope.allocation;
                    switch (allocation) {
                        .heap => allocator.destroy(self.scope),
                        .embedded => self.scope.* = undefined,
                    }
                    self.state = .complete;
                    return true;
                },
                .complete => true,
            };
        }
    };
    /// Teardown owner for scopes embedded in a larger allocation. Unlike an
    /// ordinary retained reference, the embedding allocation is the scope's
    /// storage authority: it must remain present until every heap child has
    /// propagated its parent release. Only then may the owner reference be
    /// consumed and the embedded scope invalidated.
    pub const EmbeddedTeardownCursor = struct {
        scope: *Scope,
        state: State = .waiting_for_children,

        const State = union(enum) {
            waiting_for_children,
            retiring: RetireCursor,
            complete,
        };

        pub fn init(scope: *Scope) EmbeddedTeardownCursor {
            std.debug.assert(scope.allocation == .embedded);
            return .{ .scope = scope };
        }

        pub fn advance(self: *EmbeddedTeardownCursor) bool {
            return switch (self.state) {
                .waiting_for_children => result: {
                    if (self.scope.refs.load(.acquire) != 1) break :result false;
                    self.state = .{ .retiring = self.scope.retireCursor() };
                    break :result false;
                },
                .retiring => |*cursor| if (cursor.advance()) result: {
                    self.state = .complete;
                    break :result true;
                } else false,
                .complete => true,
            };
        }
    };
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
        parent.retain();
        return .{ .allocator = allocator, .parent = parent, .storage = .isolated };
    }
    pub fn createLazy(allocator: std.mem.Allocator, parent: *Scope) error{OutOfMemory}!*Scope {
        const result = try allocator.create(Scope);
        result.* = lazy(allocator, parent);
        result.allocation = .heap;
        return result;
    }
    pub fn retain(self: *Scope) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }
    pub fn kind(self: *const Scope) ScopeKind {
        return switch (self.storage) {
            .session => .session,
            .module_root => .module_root,
            .core_build => .session,
            .isolated => .isolated,
        };
    }
    pub fn environmentOrNull(self: *const Scope) ?EnvironmentView {
        return switch (self.storage) {
            .session => |target| .init(target),
            .core_build => |target| .init(target),
            .module_root => |module| .init(module.target),
            .isolated => if (self.isolated_environment.load(.acquire)) |target| .init(target) else null,
        };
    }
    fn releaseDomain(self: *const Scope) *heap.ReleaseDomain {
        return switch (self.storage) {
            .session => |target| target.releases,
            .core_build => |target| target.releases,
            .module_root => |module| module.target.releases,
            .isolated => self.parent.?.releaseDomain(),
        };
    }
    pub fn retireCursor(self: *Scope) RetireCursor {
        return .init(self);
    }
    pub fn retire(self: *Scope) void {
        const cursor = self.retireCursor();
        if (cursor.state == .complete) return;
        std.debug.assert(self.allocation == .heap);
        self.retirement_state = cursor.state;
        const releases = self.releaseDomain();
        releases.retire(self, &self.retirement);
    }
    pub fn advanceRetirement(
        _: *heap.ReleaseDomain,
        _: std.mem.Allocator,
        self: *Scope,
    ) bool {
        var cursor = RetireCursor{ .scope = self, .state = self.retirement_state.? };
        if (cursor.advance()) return true;
        self.retirement_state = cursor.state;
        return false;
    }
    pub fn releaseTrivial(self: *Scope) void {
        std.debug.assert(self.parent == null and self.environmentOrNull() != null);
        std.debug.assert(self.storage != .isolated);
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old == 1);
        _ = self.refs.load(.acquire);
        self.* = undefined;
    }
    fn writableEnvironment(self: *Scope) error{OutOfMemory}!*Environment {
        return switch (self.storage) {
            .session => |target| target,
            .core_build => |target| target,
            .module_root => |module| module.target,
            .isolated => blk: {
                if (self.isolated_environment.load(.acquire)) |target| break :blk target;
                std.Io.Threaded.mutexLock(&self.publication_lock);
                defer std.Io.Threaded.mutexUnlock(&self.publication_lock);
                if (self.isolated_environment.load(.acquire)) |target| break :blk target;
                const created = try self.allocator.create(Environment);
                created.* = Environment.init(self.allocator, self.releaseDomain());
                self.isolated_environment.store(created, .release);
                break :blk created;
            },
        };
    }
    pub fn publishTop(
        self: *Scope,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) BindError!*BindingCell {
        return switch (self.storage) {
            .session, .core_build, .isolated => (try self.writableEnvironment()).bind(name, BindingSpec.fromTop(publication)),
            .module_root => unreachable,
        };
    }
    pub fn publishTopCursor(
        self: *Scope,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) error{OutOfMemory}!Environment.BindCursor {
        return switch (self.storage) {
            .session, .core_build, .isolated => (try self.writableEnvironment()).bindCursor(
                name,
                BindingSpec.fromTop(publication),
            ),
            .module_root => unreachable,
        };
    }
    pub fn publishModule(
        self: *Scope,
        name: intern.NamespaceName,
        publication: ModulePublication,
    ) BindError!*BindingCell {
        return switch (self.storage) {
            .module_root => |module| {
                var qualified = try intern.QualifiedCursor.init(
                    self.allocator,
                    intern.namespaceId(module.home),
                    intern.namespaceId(name),
                );
                defer qualified.deinit();
                const trace_word = while (true) switch (try qualified.advance()) {
                    .pending => {},
                    .complete => |id| break id,
                };
                return module.target.bind(
                    name,
                    BindingSpec.fromModule(module.home, trace_word, publication),
                );
            },
            else => unreachable,
        };
    }
    pub fn publishModuleCursor(
        self: *Scope,
        name: intern.NamespaceName,
        trace_word: u32,
        publication: ModulePublication,
    ) error{OutOfMemory}!Environment.BindCursor {
        return switch (self.storage) {
            .module_root => |module| module.target.bindCursor(
                name,
                BindingSpec.fromModule(module.home, trace_word, publication),
            ),
            else => unreachable,
        };
    }
    pub fn moveUseToTop(self: *Scope, canonical: u32) BindError!void {
        return (try self.writableEnvironment()).moveUseToTop(canonical);
    }
    pub fn moveUseCursor(self: *Scope, canonical: u32) error{OutOfMemory}!Environment.MoveUseCursor {
        return .init(try self.writableEnvironment(), canonical);
    }
    pub fn freezeModule(self: *Scope) void {
        switch (self.storage) {
            .module_root => |module| module.target.freeze(),
            else => unreachable,
        }
    }
};
const EnvState = struct {
    host: *const heap.HostCleanup,
    core: Environment,
    session: Environment,
};

pub const Env = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Env) *EnvState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    pub fn init(host: *const heap.HostCleanup) error{OutOfMemory}!Env {
        const allocator = host.allocator();
        const releases = heap.hostDomain(host);
        const backing = try allocator.create(EnvState);
        backing.* = .{
            .host = host,
            .core = Environment.init(allocator, releases),
            .session = Environment.init(allocator, releases),
        };
        return @enumFromInt(@intFromPtr(backing));
    }
    pub fn deinit(self: *Env) void {
        const backing = self.privateState();
        const allocator = backing.host.allocator();
        var session_cursor = Environment.TeardownCursor.init(&backing.session);
        while (!session_cursor.advance()) {}
        var core_cursor = Environment.TeardownCursor.init(&backing.core);
        while (!core_cursor.advance()) {}
        backing.host.drain();
        allocator.destroy(backing);
        self.* = .consumed;
    }
    pub fn coreView(self: *const Env) EnvironmentView {
        return .init(&self.privateState().core);
    }
    pub fn sessionView(self: *const Env) EnvironmentView {
        return .init(&self.privateState().session);
    }
    pub fn define(
        self: *Env,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) error{OutOfMemory}!void {
        _ = self.privateState().session.bind(name, BindingSpec.fromTop(publication)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => unreachable,
        };
    }
    fn installCoreSpec(self: *Env, name: intern.NamespaceName, spec: BindingSpec) error{OutOfMemory}!void {
        _ = self.privateState().core.bind(name, spec) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => unreachable,
        };
    }
    fn installCore(self: *Env, name: intern.NamespaceName, binding: Binding) error{OutOfMemory}!void {
        try self.installCoreSpec(name, .{ .binding = binding });
    }
    pub fn beginCoreBuild(self: *Env) BuildingEnv {
        return .{ .target = self };
    }
    pub fn sessionRoot(self: *Env, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .{ .session = &self.privateState().session }, null);
    }
    pub fn createSessionRoot(self: *Env, allocator: std.mem.Allocator) error{OutOfMemory}!*Scope {
        const root = try allocator.create(Scope);
        root.* = self.sessionRoot(allocator);
        root.allocation = .heap;
        return root;
    }
};
comptime {
    heap.requireOpaqueHostRoot(Env, EnvState);
}
/// Typestate capability for the only phase in which core publication is
/// legal. `finish` consumes the capability and freezes the core.
pub const BuildingEnv = struct {
    target: *Env,

    const BuiltinEffect = struct {
        value: value.Value,
        validated: ValidatedEffect,
    };

    fn builtinEffect(
        self: *BuildingEnv,
        comptime source: []const u8,
    ) error{OutOfMemory}!BuiltinEffect {
        const core = &self.target.privateState().core;
        const token_count = comptime countEffectTokens(source);
        var tokens: [token_count]value.Value = undefined;
        var iterator = std.mem.tokenizeScalar(u8, source, ' ');
        var index: usize = 0;
        var separator_index: ?usize = null;
        while (iterator.next()) |token| : (index += 1) {
            const id = try intern.intern(token);
            tokens[index] = .{ .word = id };
            if (std.mem.eql(u8, token, "--")) separator_index = index;
        }
        std.debug.assert(index == token_count and separator_index != null);
        const effect_value = try list.fromValuesGeneric(core.allocator, &tokens);
        return .{
            .value = effect_value,
            .validated = .fromValidated(effect_value.list, separator_index.?),
        };
    }

    pub fn installCore(
        self: *BuildingEnv,
        name: intern.NamespaceName,
        binding: Binding,
    ) error{OutOfMemory}!void {
        try self.target.installCore(name, binding);
    }
    pub fn installBuiltin(
        self: *BuildingEnv,
        comptime name: []const u8,
        primitive: PrimitiveImpl,
    ) error{OutOfMemory}!void {
        const core = &self.target.privateState().core;
        comptime assertStaticNamespace(name);
        const metadata = comptime primitive_docs.forName(name);
        const document_value = try machine.stringValue(
            core.allocator,
            core.releases,
            metadata.text,
        );
        defer core.releases.releaseValue(document_value);
        const builtin_effect: ?BuiltinEffect = if (metadata.effect) |source|
            try self.builtinEffect(source)
        else
            null;
        defer if (builtin_effect) |effect| {
            core.releases.releaseValue(effect.value);
        };
        try self.target.installCoreSpec(
            try intern.trustedNamespace(name),
            .{
                .binding = .{ .builtin = primitive },
                .effect = if (builtin_effect) |effect| effect.validated else null,
                .doc = documentation(document_value.list).?,
            },
        );
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
            try self.installBuiltin(definition.name, definition.primitive);
        }
    }
    pub fn runtime(self: *BuildingEnv) *Env {
        return self.target;
    }
    pub fn rootScope(self: *BuildingEnv, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .{ .core_build = &self.target.privateState().core }, null);
    }
    pub fn finish(self: *BuildingEnv) void {
        self.target.privateState().core.freeze();
        // SAFETY: Finishing consumes the builder; invalidation catches reuse
        // after its target environment becomes immutable.
        self.* = undefined;
    }
};

fn countEffectTokens(comptime source: []const u8) usize {
    if (source.len == 0) @compileError("primitive effect cannot be empty");
    var count: usize = 1;
    for (source) |byte| count += @intFromBool(byte == ' ');
    return count;
}
pub fn assertStaticNamespace(comptime name: []const u8) void {
    if (name.len == 0 or intern.isReservedBytes(name) or
        std.mem.indexOfScalar(u8, name, '.') != null)
    {
        @compileError("invalid builtin namespace name: " ++ name);
    }
}
pub const testing = if (builtin.is_test) struct {
    pub fn deinitEnvironment(environment: *Environment) void {
        var cursor = Environment.TeardownCursor.init(environment);
        while (!cursor.advance()) {}
        environment.* = undefined;
    }

    pub fn deinitScope(scope: *Scope, releases: *heap.ReleaseDomain) void {
        switch (scope.allocation) {
            .embedded => {
                var cursor = Scope.EmbeddedTeardownCursor.init(scope);
                while (!cursor.advance()) _ = releases.advance(256);
            },
            .heap => {
                var cursor = scope.retireCursor();
                while (!cursor.advance()) _ = releases.advance(256);
            },
        }
    }
} else struct {};
test "environment definition propagates every allocation failure" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var host = heap.HostOwner.init(allocator);
            const releases = host.domain();
            defer host.cleanup().drain();
            var environment = try Env.init(host.cleanup());
            defer environment.deinit();
            const body = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 7 }});
            defer releases.releaseValue(body);
            const name = try intern.trustedNamespace("failure-probe");
            try environment.define(name, .{ .word = .{ .body = quotation(body.list).? } });
            try environment.define(name, .{ .value = .{ .int = 9 } });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}
