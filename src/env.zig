//! Stable binding cells, immutable environment shapes, and lazy scopes.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const snapshot_core = @import("snapshot_core.zig");
const primitive_docs = @import("primitive_docs.zig");

fn readerDecision(
    before: snapshot_core.Reader,
    event: snapshot_core.ReaderEvent,
) snapshot_core.ReaderDecision {
    return snapshot_core.decideReader(before, event) catch
        @panic("invalid snapshot reader transition");
}
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
        .dict, .task, .reserved_mask => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.Header {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.Header) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .reserved_mask => null,
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
    pub fn fromValidated(effect_header: *value.Header, separator_index: usize) ValidatedEffect {
        std.debug.assert(effect_header.kind() == .generic_spine and separator_index < effect_header.length());
        return .{
            .quotation = @ptrCast(@alignCast(effect_header)),
            .inputs = @intCast(separator_index),
            .outputs = @intCast(@as(usize, @intCast(effect_header.length())) - separator_index - 1),
        };
    }
    pub const ParseProgress = union(enum) { pending, complete: ?ValidatedEffect };
    pub const ParseCursor = struct {
        header: *value.Header,
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
    pub fn parse(effect_header: *value.Header, separator: u32) ?ValidatedEffect {
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
    trace_word: ?u32 = null,
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
                .home = home,
                .trace_word = trace_word,
                .effect = word.effect,
                .doc = word.doc,
            },
            .value => |item| .{
                .binding = .{ .value = item.item },
                .visibility = item.visibility,
                .home = home,
                .trace_word = trace_word,
            },
            .primitive => |primitive| .{
                .binding = .{ .primitive = primitive.callback },
                .visibility = primitive.visibility,
                .home = home,
                .trace_word = trace_word,
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
    trace_word: ?u32,
    effect: ?ValidatedEffect,
    doc: ?*DocumentationString,
    compiled: ?*Quotation,

    fn fromSpec(spec: BindingSpec) BindingLease {
        return .{
            .binding = spec.binding,
            .visibility = spec.visibility,
            .home = spec.home,
            .trace_word = spec.trace_word,
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
            .trace_word = self.trace_word,
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
    retire_lock: std.Io.Mutex = .init,
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
        defer std.Io.Threaded.mutexUnlock(&self.retire_lock);
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
        std.Io.Threaded.mutexLock(&self.retire_lock);
    }
    fn reclaimRetired(self: *BindingCell, allocator: std.mem.Allocator) void {
        const retired_count: usize = @intFromBool(self.snapshots.previous != null);
        if (snapshot_core.decideReclamation(
            self.readers.load(.seq_cst),
            retired_count,
        ) == .keep) return;
        const retired = self.snapshots.previous;
        self.snapshots.previous = null;
        BindingSnapshot.destroyChain(retired, allocator);
    }
    pub fn load(self: *BindingCell) BindingLease {
        var protocol: snapshot_core.Reader = .idle;
        const announced = readerDecision(protocol, .announce);
        protocol = announced.next;
        std.debug.assert(announced.command == .announce);
        _ = self.readers.fetchAdd(1, .seq_cst);
        const snapshot = self.current.load(.seq_cst);
        const protected = readerDecision(protocol, .protect);
        protocol = protected.next;
        std.debug.assert(protected.command == .retain_payload);
        snapshot.spec.retain();
        const result = BindingLease.fromSpec(snapshot.spec);
        const left = readerDecision(protocol, .leave);
        std.debug.assert(left.command == .leave and left.next == .idle);
        if (self.readers.fetchSub(1, .seq_cst) == 1) {
            self.lockRetired();
            self.reclaimRetired(self.allocator);
            std.Io.Threaded.mutexUnlock(&self.retire_lock);
        }
        return result;
    }
};
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
pub const ShapeLease = struct {
    environment: *const Environment,
    shape: ?*const Shape,
    protocol: snapshot_core.Reader,

    pub fn useOrder(self: *const ShapeLease) []const u32 {
        return if (self.shape) |shape| shape.uses else &.{};
    }

    fn nameCount(self: *const ShapeLease) usize {
        return if (self.shape) |shape| shape.names.count() else 0;
    }

    pub fn deinit(self: *ShapeLease) void {
        const environment = @constCast(self.environment);
        const left = readerDecision(self.protocol, .leave);
        self.protocol = left.next;
        std.debug.assert(left.command == .leave);
        if (environment.shape_readers.fetchSub(1, .seq_cst) == 1) {
            environment.lockBlocking();
            environment.reclaimShapes();
            environment.unlock();
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
            .entry => |entry| .{ .entry = .{ .name = entry.key, .lease = entry.value.load() } },
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
    writer: std.Io.Mutex = .init,
    current: std.atomic.Value(?*Shape) = .init(null),
    shape_readers: std.atomic.Value(u32) = .init(0),
    cells: poll.ChunkList(*BindingCell),
    shape_generation: std.atomic.Value(u64) = .init(0),
    frozen: std.atomic.Value(bool) = .init(false),
    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .allocator = allocator, .cells = .init(allocator) };
    }
    pub fn deinit(self: *Environment) void {
        std.debug.assert(self.shape_readers.load(.acquire) == 0);
        Shape.destroyChain(self.current.load(.acquire), self.allocator);
        var cells = self.cells.iterator();
        while (cells.next()) |binding_cell| binding_cell.*.destroy(self.allocator);
        self.cells.deinit();
        self.* = undefined;
    }
    fn lockBlocking(self: *Environment) void {
        std.Io.Threaded.mutexLock(&self.writer);
    }
    fn unlock(self: *Environment) void {
        std.Io.Threaded.mutexUnlock(&self.writer);
    }
    fn reclaimShapes(self: *Environment) void {
        const current = self.current.load(.acquire) orelse return;
        const retired_count: usize = @intFromBool(current.previous != null);
        if (snapshot_core.decideReclamation(
            self.shape_readers.load(.seq_cst),
            retired_count,
        ) == .keep) return;
        const retired = current.previous;
        current.previous = null;
        Shape.destroyChain(retired, self.allocator);
    }
    pub fn acquireShape(self: *const Environment) ShapeLease {
        const announced = readerDecision(.idle, .announce);
        std.debug.assert(announced.command == .announce);
        _ = @constCast(self).shape_readers.fetchAdd(1, .seq_cst);
        return .{
            .environment = self,
            .shape = self.current.load(.acquire),
            .protocol = announced.next,
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
            .lookup = if (shape.shape) |current| current.names.rawLookup(id) else null,
            .shape = shape,
        };
    }

    pub const BindProgress = union(enum) { pending, complete: *BindingCell };
    pub const BindCursor = struct {
        environment: *Environment,
        id: u32,
        spec: BindingSpec,
        candidate_cell: ?*BindingCell,
        shape: ?ShapeLease = null,
        generation: u64 = 0,
        lookup: ?Shape.NameMap.RawLookupCursor = null,
        initializer: ?Shape.NameMap.InitCursor = null,
        cloner: ?Shape.NameMap.CloneCursor = null,
        names: ?Shape.NameMap = null,
        insertion: ?Shape.NameMap.PutCursor = null,
        uses: ?[]u32 = null,
        copy_index: usize = 0,
        phase: enum { snapshot, lookup, build, copy_uses, insert, commit, complete } = .snapshot,

        fn init(
            environment: *Environment,
            id: u32,
            spec: BindingSpec,
        ) error{OutOfMemory}!BindCursor {
            return .{
                .environment = environment,
                .id = id,
                .spec = spec,
                .candidate_cell = try BindingCell.create(environment.allocator, spec),
            };
        }
        pub fn deinit(self: *BindCursor) void {
            if (self.shape) |*shape| shape.deinit();
            if (self.initializer) |*initializer| initializer.deinit();
            if (self.cloner) |*cloner| cloner.deinit();
            if (self.names) |*names| names.deinit();
            if (self.uses) |uses| self.environment.allocator.free(uses);
            if (self.candidate_cell) |candidate| candidate.destroy(self.environment.allocator);
            self.* = undefined;
        }
        fn resetCandidate(self: *BindCursor) void {
            if (self.initializer) |*initializer| initializer.deinit();
            self.initializer = null;
            if (self.cloner) |*cloner| cloner.deinit();
            self.cloner = null;
            if (self.names) |*names| names.deinit();
            self.names = null;
            self.insertion = null;
            if (self.uses) |uses| self.environment.allocator.free(uses);
            self.uses = null;
            self.copy_index = 0;
        }
        fn takeSnapshot(self: *BindCursor) BindError!void {
            if (self.environment.frozen.load(.acquire)) return error.Frozen;
            self.shape = self.environment.acquireShape();
            self.generation = self.environment.shape_generation.load(.acquire);
            self.lookup = if (self.shape.?.shape) |shape| shape.names.rawLookup(self.id) else null;
            self.phase = .lookup;
        }
        fn retry(self: *BindCursor) void {
            self.resetCandidate();
            self.shape.?.deinit();
            self.shape = null;
            self.lookup = null;
            self.phase = .snapshot;
        }
        pub fn advance(self: *BindCursor) BindError!BindProgress {
            return switch (self.phase) {
                .snapshot => result: {
                    try self.takeSnapshot();
                    break :result .pending;
                },
                .lookup => if (self.lookup) |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_cell| result: {
                        if (maybe_cell) |existing| {
                            self.environment.lockBlocking();
                            defer self.environment.unlock();
                            if (self.environment.frozen.load(.acquire)) return error.Frozen;
                            try existing.replace(self.environment.allocator, self.spec);
                            self.candidate_cell.?.destroy(self.environment.allocator);
                            self.candidate_cell = null;
                            self.phase = .complete;
                            break :result .{ .complete = existing };
                        }
                        self.cloner = self.shape.?.shape.?.names.cloneCursor(1);
                        self.phase = .build;
                        break :result .pending;
                    },
                } else result: {
                    self.initializer = Shape.NameMap.initCursor(self.environment.allocator, 1);
                    self.phase = .build;
                    break :result .pending;
                },
                .build => if (self.cloner) |*cloner| switch (try cloner.advance()) {
                    .pending => .pending,
                    .complete => |names| result: {
                        cloner.deinit();
                        self.cloner = null;
                        self.names = names;
                        const prior_uses = self.shape.?.useOrder();
                        self.uses = try self.environment.allocator.alloc(u32, prior_uses.len);
                        self.phase = .copy_uses;
                        break :result .pending;
                    },
                } else switch (try self.initializer.?.advance()) {
                    .pending => .pending,
                    .complete => |names| result: {
                        self.initializer.?.deinit();
                        self.initializer = null;
                        self.names = names;
                        self.uses = try self.environment.allocator.alloc(u32, 0);
                        self.phase = .copy_uses;
                        break :result .pending;
                    },
                },
                .copy_uses => result: {
                    const prior_uses = self.shape.?.useOrder();
                    if (self.copy_index != prior_uses.len) {
                        self.uses.?[self.copy_index] = prior_uses[self.copy_index];
                        self.copy_index += 1;
                    } else {
                        self.insertion = self.names.?.putCursor(self.id, self.candidate_cell.?);
                        self.phase = .insert;
                    }
                    break :result .pending;
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
                    const next = try self.environment.allocator.create(Shape);
                    self.environment.lockBlocking();
                    if (self.environment.frozen.load(.acquire)) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        return error.Frozen;
                    }
                    if (self.environment.shape_generation.load(.acquire) != self.generation) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        self.retry();
                        break :result .pending;
                    }
                    const old = self.environment.current.load(.acquire);
                    next.* = .{ .names = self.names.?, .uses = self.uses.?, .previous = old };
                    self.names = null;
                    self.uses = null;
                    const published_cell = self.candidate_cell.?;
                    self.environment.cells.append(published_cell) catch {
                        self.names = next.names;
                        self.uses = next.uses;
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        return error.OutOfMemory;
                    };
                    self.candidate_cell = null;
                    self.environment.current.store(next, .release);
                    _ = self.environment.shape_generation.fetchAdd(1, .release);
                    self.environment.reclaimShapes();
                    self.environment.unlock();
                    self.phase = .complete;
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
        return .init(self, intern.namespaceId(name), spec);
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
        generation: u64 = 0,
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
                    self.generation = self.environment.shape_generation.load(.acquire);
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
                    if (self.environment.shape_generation.load(.acquire) != self.generation) {
                        self.environment.unlock();
                        self.environment.allocator.destroy(next);
                        self.reset();
                        break :result .pending;
                    }
                    next.* = .{
                        .names = self.names.?,
                        .uses = self.uses.?,
                        .previous = self.environment.current.load(.acquire),
                    };
                    self.names = null;
                    self.uses = null;
                    self.environment.current.store(next, .release);
                    _ = self.environment.shape_generation.fetchAdd(1, .release);
                    self.environment.reclaimShapes();
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
                lease.deinit(allocator);
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
    pub fn environmentOrNull(self: *const Scope) ?*Environment {
        return switch (self.storage) {
            .session => |target| target,
            .core_build => |target| target,
            .module_root => |module| module.target,
            .isolated => self.isolated_environment.load(.acquire),
        };
    }
    pub fn deinit(self: *Scope) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        const allocator = self.allocator;
        const parent = self.parent;
        const allocation = self.allocation;
        if (self.storage == .isolated) {
            const target = self.isolated_environment.load(.acquire) orelse {
                if (parent) |scope| scope.deinit();
                switch (allocation) {
                    .heap => allocator.destroy(self),
                    .embedded => self.* = undefined,
                }
                return;
            };
            target.deinit();
            allocator.destroy(target);
        }
        if (parent) |scope| scope.deinit();
        switch (allocation) {
            .heap => allocator.destroy(self),
            .embedded => self.* = undefined,
        }
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
                created.* = Environment.init(self.allocator);
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
        _ = self.session.bind(name, BindingSpec.fromTop(publication)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => unreachable,
        };
    }
    fn installCoreSpec(self: *Env, name: intern.NamespaceName, spec: BindingSpec) error{OutOfMemory}!void {
        _ = self.core.bind(name, spec) catch |err| switch (err) {
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
        return Scope.direct(allocator, .{ .session = &self.session }, null);
    }
};
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
        const effect_value = try list.fromValuesGeneric(self.target.core.allocator, &tokens);
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
        comptime assertStaticNamespace(name);
        const metadata = comptime primitive_docs.forName(name);
        const document_value = try machine.stringValue(
            self.target.core.allocator,
            metadata.text,
        );
        defer heap.releaseValue(self.target.core.allocator, document_value);
        const builtin_effect: ?BuiltinEffect = if (metadata.effect) |source|
            try self.builtinEffect(source)
        else
            null;
        defer if (builtin_effect) |effect| {
            heap.releaseValue(self.target.core.allocator, effect.value);
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
        return Scope.direct(allocator, .{ .core_build = &self.target.core }, null);
    }
    pub fn finish(self: *BuildingEnv) void {
        self.target.core.freeze();
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
    var core = (environment.core.resolveDirect(intern.namespaceId(name))).?;
    defer core.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), core.binding.value.int);
    try environment.define(name, .{ .value = .{ .int = 2 } });
    var local = (environment.session.resolveDirect(intern.namespaceId(name))).?;
    defer local.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), local.binding.value.int);
    try std.testing.expect(environment.session.resolveDirect(99) == null);
}
test "env: same-name rebind preserves cell identity and shape" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var scope = Scope.direct(std.testing.allocator, .{ .session = &environment }, null);
    defer scope.deinit();
    const name = try intern.trustedNamespace("cell-test");
    const first = try scope.publishTop(name, .{ .value = .{ .int = 1 } });
    const generation = environment.generation();
    const second = try scope.publishTop(name, .{ .value = .{ .int = 2 } });
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(generation, environment.generation());
    var lease = (environment.resolveDirect(intern.namespaceId(name))).?;
    defer lease.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), lease.binding.value.int);
}
test "environment definition propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, definitionFailureProbe, .{});
}
