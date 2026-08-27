//! Stable binding cells, immutable environment shapes, and lazy scopes.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const lexer = @import("lexer.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const native_module = @import("native_module.zig");
const primitive_docs = @import("primitive_docs.zig");
const snapshot_api = @import("snapshot.zig");
const reader_types = @import("reader_types.zig");
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
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => @ptrCast(@alignCast(header)),
        .dict, .task, .module, .unit_plan, .reserved_mask => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.ListHandle) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .module, .unit_plan, .reserved_mask => null,
    };
}

pub fn documentationHeader(document: *const DocumentationString) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(document)));
}

pub const Binding = union(enum) {
    word: *Quotation,
    builtin: PrimitiveImpl,
    /// The one word whose behavior is a binding kind rather than a handler
    /// value: `seed`. Its opaque seal is the authority to allocate a nominal
    /// unit plan in the issuing host's reclamation root.
    seed: *const heap.UnitPlanSeal,
    native: NativeCallable,
    pub fn retain(self: Binding) void {
        switch (self) {
            .word => |body| heap.incRef(quotationHeader(body)),
            .builtin, .seed => {},
            .native => |callable| callable.instance.retain(),
        }
    }
    pub fn retire(self: Binding, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .word => |body| releases.releaseHeader(quotationHeader(body)),
            .builtin, .seed => {},
            .native => |callable| callable.instance.releasePin(),
        }
    }
};
pub const Visibility = enum { public, private };
/// Where a definition was published. A module definition records only its own
/// module-local name: the image it belongs to has no canonical name, and the
/// registration through which a call reached it is what supplies the qualified
/// spelling and the live state. Baking a name here would make one image
/// unregisterable twice; baking a slot here would put a cycle in the value
/// heap.
pub const BindingOrigin = union(enum) {
    top,
    module_local: struct { trace_word: intern.BindingName },

    pub fn traceWord(self: BindingOrigin) ?intern.BindingName {
        return switch (self) {
            .top => null,
            .module_local => |local| local.trace_word,
        };
    }
};
pub const ValidatedEffect = struct {
    quotation: *EffectQuotation,
    inputs: u32,
    outputs: u32,
    /// The after portion is the anonymous row token rather than named slots:
    /// the before row is checked at boundaries, the after row is not.
    row: bool = false,
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
            .row = isRowEffect(effect_header, separator_index),
        };
    }
    /// The after portion is the row token exactly when it is that one word.
    pub fn isRowEffect(effect_header: *value.ListHandle, separator_index: usize) bool {
        const count: usize = @intCast(effect_header.length());
        if (count != separator_index + 2) return false;
        const after = list.atUnchecked(.{ .list = effect_header }, separator_index + 1);
        return after == .word and std.mem.eql(u8, intern.get(after.word.name), lexer.row_token);
    }
    pub const ParseProgress = poll.Progress(?ValidatedEffect);
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
                    .row = isRowEffect(self.header, split),
                } };
            }
            const atom = list.atUnchecked(.{ .list = self.header }, self.index);
            if (atom != .word) return .{ .complete = null };
            if (atom.word.name == self.separator) {
                if (self.split != null) return .{ .complete = null };
                self.split = self.index;
            }
            self.index += 1;
            return .pending;
        }
    };
    pub fn parse(effect_header: *value.ListHandle, separator: u32) ?ValidatedEffect {
        var cursor = ParseCursor{ .header = effect_header, .separator = separator };
        return poll.drive(?ValidatedEffect, &cursor, .{});
    }
};
pub const Effect = ValidatedEffect;

pub const TopPublication = union(enum) {
    word: struct {
        body: *Quotation,
        source: ?reader_types.SourceSlice = null,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
    },
};
/// One word of a builtin-backed module: a host primitive published under a
/// module name. The metadata is authored as plain text because these modules
/// are compiled in, not loaded — there is no descriptor to carry it.
/// Slots either side of `--` in a builtin word's declared effect. Fixed
/// because these effects are compiled-in text, not user data.
pub const max_builtin_effect_tokens: usize = 16;

pub const BuiltinWord = struct {
    name: []const u8,
    /// Required: the repository holds module words to a documentation policy
    /// even though M11 made annotations optional as language semantics.
    doc: []const u8,
    /// Slot names either side of `--`, when the successful effect is fixed.
    effect: ?[]const u8 = null,
    primitive: PrimitiveImpl,
};

pub const ModulePublication = union(enum) {
    word: struct {
        body: *Quotation,
        source: ?reader_types.SourceSlice = null,
        visibility: Visibility,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
    },
    native: struct {
        callable: NativeCallable,
        visibility: Visibility,
        effect: ValidatedEffect,
        doc: *DocumentationString,
    },
    /// A primitive published as a module word. `Binding` already had this
    /// arm; only the publication typestate was missing, which is why a
    /// primitive-backed module was unrepresentable.
    builtin: struct {
        primitive: PrimitiveImpl,
        visibility: Visibility,
        effect: ?ValidatedEffect = null,
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
    source: ?reader_types.SourceSlice = null,
    fn fromTop(publication: TopPublication) BindingSpec {
        return switch (publication) {
            .word => |word| .{
                .binding = .{ .word = word.body },
                .source = word.source,
                .effect = word.effect,
                .doc = word.doc,
            },
        };
    }
    fn fromModule(
        name: intern.NamespaceName,
        publication: ModulePublication,
    ) BindingSpec {
        const origin: BindingOrigin = .{ .module_local = .{ .trace_word = name } };
        return switch (publication) {
            .word => |word| .{
                .binding = .{ .word = word.body },
                .source = word.source,
                .visibility = word.visibility,
                .origin = origin,
                .effect = word.effect,
                .doc = word.doc,
            },
            .native => |native| .{
                .binding = .{ .native = native.callable },
                .visibility = native.visibility,
                .origin = origin,
                .effect = native.effect,
                .doc = native.doc,
            },
            .builtin => |primitive| .{
                .binding = .{ .builtin = primitive.primitive },
                .visibility = primitive.visibility,
                .origin = origin,
                .effect = primitive.effect,
                .doc = primitive.doc,
            },
        };
    }
    fn retain(self: BindingSpec) void {
        self.binding.retain();
        if (self.effect) |effect| effect.retain();
        if (self.doc) |doc| heap.incRef(documentationHeader(doc));
        if (self.compiled) |compiled| heap.incRef(quotationHeader(compiled));
        if (self.source) |source| source.retain();
    }
    fn retire(self: BindingSpec, releases: *heap.ReleaseDomain) void {
        self.binding.retire(releases);
        if (self.effect) |effect| effect.retire(releases);
        if (self.doc) |doc| releases.releaseHeader(documentationHeader(doc));
        if (self.compiled) |compiled| releases.releaseHeader(quotationHeader(compiled));
        if (self.source) |source| {
            var owned = source;
            owned.deinit();
        }
    }
    pub fn deinit(self: *BindingSpec, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
};

/// A core name admitted to non-privileged installation. Private construction
/// is the boundary: every generic installer must validate away the canonical
/// `seed` spelling before it can obtain this type.
const OrdinaryCoreName = struct {
    value: intern.NamespaceName,

    const ValidationError = error{PrivilegedCoreName};

    fn validate(name: intern.NamespaceName) ValidationError!OrdinaryCoreName {
        if (std.mem.eql(u8, intern.get(intern.namespaceId(name)), "seed"))
            return error.PrivilegedCoreName;
        return .{ .value = name };
    }
};

/// The privileged name is a closed variant rather than a raw id. No generic
/// path can manufacture it by validating a runtime or compile-time spelling.
const CoreInstallName = union(enum) {
    ordinary: OrdinaryCoreName,
    seed,
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
    source: ?reader_types.SourceSlice,

    fn fromSpec(spec: BindingSpec, releases: *heap.ReleaseDomain) BindingLease {
        return .{
            .releases = releases,
            .binding = spec.binding,
            .visibility = spec.visibility,
            .origin = spec.origin,
            .effect = spec.effect,
            .doc = spec.doc,
            .compiled = spec.compiled,
            .source = spec.source,
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
            .source = self.source,
        };
        spec.retire(self.releases);
        self.* = undefined;
    }

    /// The definition's module-local name, or null for a top-level binding.
    /// Present exactly when the binding is module-local.
    pub fn traceWord(self: BindingLease) ?intern.BindingName {
        return self.origin.traceWord();
    }
};
pub const BindingCell = struct {
    const Publisher = snapshot_api.Publisher(BindingSnapshot);
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    references: std.atomic.Value(u32) = .init(1),
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
        std.debug.assert(self.references.load(.acquire) == 0);
        std.debug.assert(self.publisher.quiescent());
        const snapshots = self.publisher.currentOwned();
        self.publisher.publish(null);
        if (snapshots) |first| releases.retire(first, &first.retirement);
        allocator.destroy(self);
        return true;
    }
    fn retain(self: *BindingCell) void {
        const old = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }
    fn release(self: *BindingCell) void {
        const old = self.references.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.references.load(.acquire);
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
    previous: ?*Shape = null,
    retirement_entries: ?NameMap.RawEntryCursor = null,
    retirement: heap.ReleaseDomain.Retirement = .{},
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Shape,
    ) bool {
        if (self.retirement_entries == null)
            self.retirement_entries = self.names.rawEntries();
        return switch (self.retirement_entries.?.advance()) {
            .pending => false,
            .item => |entry| release: {
                entry.value.release();
                break :release false;
            },
            .complete => complete: {
                const previous = self.previous;
                self.names.deinit();
                allocator.destroy(self);
                if (previous) |next| releases.retire(next, &next.retirement);
                break :complete true;
            },
        };
    }
    fn retire(self: *Shape, releases: *heap.ReleaseDomain) void {
        releases.retire(self, &self.retirement);
    }
};

/// Builds one independently owned shape a bounded slot or insertion probe at
/// a time. Every copied cell is retained before it becomes reachable from the
/// provisional map; abandoning the cursor retires that partial shape through
/// the same bounded path used for published snapshots.
const ShapeBuilder = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    source: ?Shape.NameMap.RawEntryCursor,
    excluded: ?intern.NamespaceName,
    extra_name: ?intern.NamespaceName,
    extra_cell: ?*BindingCell,
    initializer: ?Shape.NameMap.InitCursor,
    built: ?*Shape = null,
    insertion: ?Shape.NameMap.PutCursor = null,
    pending_cell: ?*BindingCell = null,

    fn init(
        environment: *Environment,
        source: ?*const Shape.NameMap,
        expected: usize,
        excluded: ?intern.NamespaceName,
        extra_name: ?intern.NamespaceName,
        extra_cell: ?*BindingCell,
    ) ShapeBuilder {
        std.debug.assert((extra_name == null) == (extra_cell == null));
        return .{
            .allocator = environment.allocator,
            .releases = environment.releases,
            .source = if (source) |names| names.rawEntries() else null,
            .excluded = excluded,
            .extra_name = extra_name,
            .extra_cell = extra_cell,
            .initializer = Shape.NameMap.initCursor(environment.allocator, expected),
        };
    }

    fn deinit(self: *ShapeBuilder) void {
        if (self.initializer) |*initializer| initializer.deinit();
        if (self.pending_cell) |cell| cell.release();
        if (self.built) |shape| shape.retire(self.releases);
        self.* = undefined;
    }

    fn startInsertion(
        self: *ShapeBuilder,
        name: intern.NamespaceName,
        cell: *BindingCell,
    ) void {
        cell.retain();
        self.pending_cell = cell;
        self.insertion = self.built.?.names.putCursor(name, cell);
    }

    fn advance(self: *ShapeBuilder) error{OutOfMemory}!poll.Progress(*Shape) {
        if (self.initializer) |*initializer| switch (try initializer.advance()) {
            .pending => return .pending,
            .complete => |names| {
                initializer.deinit();
                self.initializer = null;
                const built = self.allocator.create(Shape) catch |err| {
                    var abandoned = names;
                    abandoned.deinit();
                    return err;
                };
                built.* = .{ .names = names };
                self.built = built;
                return .pending;
            },
        };
        if (self.insertion) |*insertion| switch (insertion.advance()) {
            .pending => return .pending,
            .complete => {
                self.pending_cell = null;
                self.insertion = null;
                return .pending;
            },
        };
        if (self.source) |*source| return switch (source.advance()) {
            .pending => .pending,
            .item => |entry| pending: {
                if (self.excluded == null or entry.key != self.excluded.?)
                    self.startInsertion(entry.key, entry.value);
                break :pending .pending;
            },
            .complete => complete: {
                self.source = null;
                break :complete .pending;
            },
        };
        if (self.extra_name) |name| {
            const cell = self.extra_cell.?;
            self.extra_name = null;
            self.extra_cell = null;
            self.startInsertion(name, cell);
            return .pending;
        }
        const built = self.built.?;
        self.built = null;
        return .{ .complete = built };
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

    /// How many times this environment published a new *shape* — a name was
    /// created or removed. Rebinding an existing name replaces its cell in
    /// place and deliberately does not bump this, so it is not a mutation
    /// counter and must not be read as one.
    pub fn shapeGeneration(self: EnvironmentView) u64 {
        return self.target().shapeGeneration();
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
pub const NameCursorProgress = poll.StreamProgress(NameEntry);
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
            .item => |entry| .{ .item = .{
                .name = intern.namespaceId(entry.key),
                .lease = entry.value.load(),
            } },
        };
    }
};

pub const DirectLookupProgress = poll.Progress(?BindingLease);
pub const DirectLookupCursor = struct {
    shape: ShapeLease,
    lookup: ?Shape.NameMap.RawLookupCursor,
    validation: ?intern.NamespaceCursor,
    pub fn deinit(self: *DirectLookupCursor) void {
        self.shape.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *DirectLookupCursor) DirectLookupProgress {
        if (self.validation) |*validation| return switch (validation.advance()) {
            .pending => .pending,
            .complete => |name| validated: {
                self.validation = null;
                const binding_name = name orelse break :validated .{ .complete = null };
                self.lookup = if (self.shape.shape) |current|
                    current.names.rawLookup(binding_name)
                else
                    null;
                break :validated .pending;
            },
        };
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
    shape_generation: std.atomic.Value(u64) = .init(0),
    frozen: std.atomic.Value(bool) = .init(false),

    pub const TeardownCursor = struct {
        target: *Environment,
        state: union(enum) {
            waiting_for_readers,
            shapes: ?*Shape,
            complete,
        },

        /// Starts in `waiting_for_readers` rather than asserting quiescence.
        ///
        /// The retain-before-dereference order should make a live shape reader
        /// here unreachable: a borrow acquires the image before it touches the
        /// scope, so an environment only reaches teardown once its image has no
        /// references left. This wait is defence, not the argument. An assert
        /// would be the worst of both -- it neither prevents the race nor
        /// survives ReleaseFast, where it compiles away.
        pub fn init(target: *Environment) TeardownCursor {
            return .{ .target = target, .state = .waiting_for_readers };
        }

        pub fn advance(self: *TeardownCursor) bool {
            return switch (self.state) {
                .waiting_for_readers => result: {
                    if (!self.target.shapes.quiescent()) break :result false;
                    const shapes = self.target.shapes.currentOwned();
                    self.target.shapes.publish(null);
                    self.state = .{ .shapes = shapes };
                    break :result false;
                },
                .shapes => |shapes| result: {
                    if (shapes) |first|
                        self.target.releases.retire(first, &first.retirement);
                    self.state = .complete;
                    break :result true;
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
            .lookup = null,
            // A lookup may find a reserved name; only publication may not use
            // one. The runtime installs the words it reserves — the head-binder
            // backend — and a gate that refused to resolve them would reserve
            // them from their only legitimate caller. Nothing else can reach
            // this map under a reserved name, because every publishing path
            // still validates strictly.
            .validation = .initReserved(id),
            .shape = shape,
        };
    }

    pub const BindProgress = poll.Progress(*BindingCell);
    pub const BindCursor = struct {
        const State = union(enum) {
            snapshot,
            lookup: struct { shape: ShapeLease, cursor: ?Shape.NameMap.RawLookupCursor },
            build: struct { shape: ShapeLease, builder: ShapeBuilder },
            commit: struct { shape: ShapeLease, built: *Shape },
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
                .commit => |*state| {
                    state.built.retire(self.environment.releases);
                    state.shape.deinit();
                },
                .snapshot, .complete => {},
            }
            if (self.candidate_cell) |candidate| candidate.release();
            self.* = undefined;
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
                            self.candidate_cell.?.release();
                            self.candidate_cell = null;
                            state.shape.deinit();
                            self.state = .complete;
                            break :result .{ .complete = existing };
                        }
                        self.state = .{ .build = .{
                            .shape = state.shape,
                            .builder = .init(
                                self.environment,
                                &state.shape.shape.?.names,
                                state.shape.shape.?.names.count() + 1,
                                null,
                                self.id,
                                self.candidate_cell.?,
                            ),
                        } };
                        break :result .pending;
                    },
                } else result: {
                    self.state = .{ .build = .{
                        .shape = state.shape,
                        .builder = .init(
                            self.environment,
                            null,
                            1,
                            null,
                            self.id,
                            self.candidate_cell.?,
                        ),
                    } };
                    break :result .pending;
                },
                .build => |*state| switch (try state.builder.advance()) {
                    .pending => .pending,
                    .complete => |built| result: {
                        const shape = state.shape;
                        state.builder.deinit();
                        self.state = .{ .commit = .{ .shape = shape, .built = built } };
                        break :result .pending;
                    },
                },
                .commit => |*state| result: {
                    self.environment.lockBlocking();
                    if (self.environment.frozen.load(.acquire)) {
                        self.environment.unlock();
                        return error.Frozen;
                    }
                    if (!self.environment.shapes.isCurrent(state.shape.shape)) {
                        self.environment.unlock();
                        state.built.retire(self.environment.releases);
                        state.shape.deinit();
                        self.state = .snapshot;
                        break :result .pending;
                    }
                    const published_cell = self.candidate_cell.?;
                    state.built.previous = self.environment.shapes.currentOwned();
                    const next = state.built;
                    published_cell.release();
                    self.candidate_cell = null;
                    self.environment.shapes.publish(next);
                    _ = self.environment.shape_generation.fetchAdd(1, .release);
                    self.environment.unlock();
                    state.shape.deinit();
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
        return poll.driveFallible(*BindingCell, &cursor, .{});
    }

    pub const UnbindProgress = poll.Progress(bool);
    pub const UnbindCursor = struct {
        const State = union(enum) {
            snapshot,
            lookup: struct { shape: ShapeLease, cursor: ?Shape.NameMap.RawLookupCursor },
            build: struct { shape: ShapeLease, builder: ShapeBuilder },
            commit: struct { shape: ShapeLease, built: *Shape },
            complete,
        };

        environment: *Environment,
        id: intern.NamespaceName,
        state: State = .snapshot,

        fn init(environment: *Environment, id: intern.NamespaceName) UnbindCursor {
            return .{ .environment = environment, .id = id };
        }
        pub fn deinit(self: *UnbindCursor) void {
            switch (self.state) {
                .lookup => |*state| state.shape.deinit(),
                .build => |*state| {
                    state.builder.deinit();
                    state.shape.deinit();
                },
                .commit => |*state| {
                    state.built.retire(self.environment.releases);
                    state.shape.deinit();
                },
                .snapshot, .complete => {},
            }
            self.* = undefined;
        }
        pub fn advance(self: *UnbindCursor) BindError!UnbindProgress {
            return switch (self.state) {
                .snapshot => snapshot: {
                    if (self.environment.frozen.load(.acquire)) return error.Frozen;
                    const shape = self.environment.acquireShape();
                    self.state = .{ .lookup = .{
                        .cursor = if (shape.shape) |current| current.names.rawLookup(self.id) else null,
                        .shape = shape,
                    } };
                    break :snapshot .pending;
                },
                .lookup => |*state| if (state.cursor) |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_cell| found: {
                        if (maybe_cell == null) {
                            state.shape.deinit();
                            self.state = .complete;
                            break :found .{ .complete = false };
                        }
                        const current = state.shape.shape.?;
                        self.state = .{ .build = .{
                            .shape = state.shape,
                            .builder = .init(
                                self.environment,
                                &current.names,
                                current.names.count() - 1,
                                self.id,
                                null,
                                null,
                            ),
                        } };
                        break :found .pending;
                    },
                } else missing: {
                    state.shape.deinit();
                    self.state = .complete;
                    break :missing .{ .complete = false };
                },
                .build => |*state| switch (try state.builder.advance()) {
                    .pending => .pending,
                    .complete => |built| built_result: {
                        const shape = state.shape;
                        state.builder.deinit();
                        self.state = .{ .commit = .{ .shape = shape, .built = built } };
                        break :built_result .pending;
                    },
                },
                .commit => |*state| commit: {
                    self.environment.lockBlocking();
                    if (self.environment.frozen.load(.acquire)) {
                        self.environment.unlock();
                        return error.Frozen;
                    }
                    if (!self.environment.shapes.isCurrent(state.shape.shape)) {
                        self.environment.unlock();
                        state.built.retire(self.environment.releases);
                        state.shape.deinit();
                        self.state = .snapshot;
                        break :commit .pending;
                    }
                    state.built.previous = self.environment.shapes.currentOwned();
                    const next = state.built;
                    self.environment.shapes.publish(next);
                    _ = self.environment.shape_generation.fetchAdd(1, .release);
                    self.environment.unlock();
                    state.shape.deinit();
                    self.state = .complete;
                    break :commit .{ .complete = true };
                },
                .complete => unreachable,
            };
        }
    };

    fn unbindCursor(self: *Environment, name: intern.NamespaceName) UnbindCursor {
        return .init(self, name);
    }

    pub fn resolveDirect(self: *const Environment, id: u32) ?BindingLease {
        var cursor = self.directLookupCursor(id);
        defer cursor.deinit();
        return poll.drive(?BindingLease, &cursor, .{});
    }
    /// The mutation authority for a module image's own environment. An image
    /// owns this environment outright, so it publishes and freezes directly
    /// rather than routing through the scope it also owns.
    pub fn modulePublisher(self: *Environment) ModulePublisher {
        return .init(self);
    }
    pub fn shapeGeneration(self: *const Environment) u64 {
        return self.shape_generation.load(.acquire);
    }
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
            .item => |entry| {
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
const ScopeAllocation = enum { embedded, heap };
const ScopeStorage = union(enum) {
    session: *Environment,
    core_build: *Environment,
    module_root: *Environment,
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
    /// The scope this scope's published literals name. Allocated on first
    /// publication rather than at construction, so an `@attempt` body that
    /// publishes nothing costs nothing. A module image installs its own before
    /// the scope is reachable.
    label_cell: std.atomic.Value(?*ScopeCell) = .init(null),
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: ?RetireCursor.State = null,

    /// Whether `inner` is this scope or one nested inside it. A word's scope is
    /// a lower bound: when the activation running it is already inside a more
    /// specific scope on the same chain -- an `@attempt` child of the unit that
    /// wrote the word -- that child is where it should resolve, because a
    /// sibling defined in the same child must be visible. Resolution walks
    /// parents, so without this a word written outside the child could never
    /// see anything defined inside it.
    ///
    /// It only ever refines downward within one chain. A module image's scope
    /// has no parent and core denotes no scope at all, so neither is ever an
    /// ancestor of a session scope.
    pub fn encloses(self: *Scope, inner: *Scope) bool {
        var current: ?*Scope = inner;
        while (current) |scope| : (current = scope.parent) {
            if (scope == self) return true;
        }
        return false;
    }

    /// The id of this scope's cell, or `.none` if it has never minted one.
    ///
    /// One atomic load and no allocation, so an activation can record it on
    /// entry and later compare a word's stamp against it with a single integer
    /// compare. A scope with no cell can name no word, so `.none` is not a
    /// missing answer -- it correctly fails every stamp comparison.
    pub fn cellId(self: *const Scope) ScopeId {
        const cell = self.label_cell.load(.acquire) orelse return .none;
        return cell.id;
    }

    /// Whether this scope is a module image's root, so a diagnostic can name
    /// the chain a word actually searched rather than the one the running
    /// activation would have.
    pub fn isModuleRoot(self: *const Scope) bool {
        return self.storage == .module_root;
    }

    pub const RetireCursor = struct {
        scope: *Scope,
        state: State,

        const State = union(enum) {
            /// The cell has been cleared, so no new borrow can succeed; this
            /// waits out the ones that already did. Resumable rather than
            /// spinning, because the release domain drives it -- a borrow is
            /// held by a live activation on some other unit, and blocking a
            /// worker on it would be a hang rather than a wait.
            waiting_for_borrows: *ScopeCell,
            environment: struct {
                target: *Environment,
                cursor: Environment.TeardownCursor,
            },
            parent,
            destroy,
            complete,
        };

        /// The state that follows the cell clear: wait for outstanding borrows
        /// first when there is a cell to wait on, otherwise start tearing down.
        fn afterClear(scope: *Scope, cell: ?*ScopeCell) State {
            if (cell) |named| {
                if (named.borrowed()) return .{ .waiting_for_borrows = named };
            }
            return startTeardown(scope);
        }

        fn startTeardown(scope: *Scope) State {
            const target = if (scope.storage == .isolated)
                scope.isolated_environment.load(.acquire)
            else
                null;
            return if (target) |environment|
                .{ .environment = .{
                    .target = environment,
                    .cursor = .init(environment),
                } }
            else
                .parent;
        }

        pub fn init(scope: *Scope) RetireCursor {
            const old = scope.refs.fetchSub(1, .release);
            std.debug.assert(old != 0);
            if (old != 1) return .{ .scope = scope, .state = .complete };
            _ = scope.refs.load(.acquire);
            // Before any teardown step, so a quotation labelled here reads a
            // definite `retired` and never a scope under teardown. Taken with a
            // swap because a module image retires its own scope's cell as soon
            // as the image's last reference drops, which is earlier than this;
            // whichever path arrives first is the one that drops the owner
            // reference.
            // The words written in this scope name it and nothing else, so its
            // cell retires with it. That is what makes applying a quotation
            // from a replaced image a definite failure rather than a silent
            // change of meaning.
            const cleared = scope.label_cell.swap(null, .acq_rel);
            if (cleared) |cell| cell.retire();
            return .{ .scope = scope, .state = afterClear(scope, cleared) };
        }

        pub fn advance(self: *RetireCursor) bool {
            return switch (self.state) {
                .waiting_for_borrows => |cell| result: {
                    if (cell.borrowed()) break :result false;
                    self.state = startTeardown(self.scope);
                    break :result false;
                },
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
                        .embedded => {},
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
                // Waits on `scope.refs` alone, and that is sufficient rather
                // than an oversight. A shape lease is not counted here, but a
                // shape reader can only have reached this scope through a
                // borrow that acquired the image first, and an image with a live
                // reference never reaches retirement -- so by the time this runs,
                // no shape reader on this scope can exist. The environment's own
                // cursor waits on shape quiescence anyway, which is where a
                // reader would be caught if that reasoning were ever falsified.
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
    /// A module image's root. It carries no canonical name: the same frozen
    /// environment may execute under any number of registrations.
    pub fn moduleRoot(allocator: std.mem.Allocator, target: *Environment) Scope {
        return direct(allocator, .{ .module_root = target }, null);
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
    /// True when nothing has bound in this scope and nobody but its own frame
    /// refers to it. Such a scope carries no state at all: it is pure identity
    /// over its parent, so one is interchangeable with another over the same
    /// parent. Isolation still holds, because a scope that has bound anything
    /// has materialized its environment and fails this test.
    pub fn reusableAsChildOf(self: *const Scope, parent: *const Scope) bool {
        if (self.storage != .isolated) return false;
        if (self.parent != parent) return false;
        if (self.isolated_environment.load(.acquire) != null) return false;
        return self.refs.load(.acquire) == 1;
    }
    pub fn retain(self: *Scope) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }
    pub fn environmentOrNull(self: *const Scope) ?EnvironmentView {
        return switch (self.storage) {
            .session => |target| .init(target),
            .core_build => |target| .init(target),
            .module_root => |target| .init(target),
            .isolated => if (self.isolated_environment.load(.acquire)) |target| .init(target) else null,
        };
    }
    fn releaseDomain(self: *const Scope) *heap.ReleaseDomain {
        return switch (self.storage) {
            .session => |target| target.releases,
            .core_build => |target| target.releases,
            .module_root => |target| target.releases,
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
    /// Drops a root scope that was never really used: `replaceRoot` overwriting
    /// a freshly built one.
    ///
    /// This neither clears a label cell nor frees through `RetireCursor`, so it
    /// is only sound while no cell exists -- which is to say before the unit has
    /// executed anything. Both callers (`prelude.install` and task spawn) run
    /// there. The assert encodes that precondition rather than leaving it to
    /// commentary: a third caller appearing mid-execution trips here instead of
    /// silently stranding a borrow whose cell still names this scope.
    pub fn releaseTrivial(self: *Scope) void {
        std.debug.assert(self.label_cell.load(.acquire) == null);
        std.debug.assert(self.parent == null and self.environmentOrNull() != null);
        std.debug.assert(self.storage != .isolated);
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old == 1);
        _ = self.refs.load(.acquire);
    }
    fn writableEnvironment(self: *Scope) error{OutOfMemory}!*Environment {
        return switch (self.storage) {
            .session => |target| target,
            .core_build => |target| target,
            .module_root => |target| target,
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
    /// One word definition, in the shape both publication kinds accept.
    pub const WordDefinition = struct {
        body: *Quotation,
        source: ?reader_types.SourceSlice = null,
        visibility: Visibility = .public,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
    };

    pub const UnpublishCursor = union(enum) {
        absent,
        environment: Environment.UnbindCursor,

        pub fn deinit(self: *UnpublishCursor) void {
            switch (self.*) {
                .absent => {},
                .environment => |*cursor| cursor.deinit(),
            }
            self.* = undefined;
        }
        pub fn advance(self: *UnpublishCursor) BindError!Environment.UnbindProgress {
            return switch (self.*) {
                .absent => |*state| absent: {
                    state.* = {};
                    break :absent .{ .complete = false };
                },
                .environment => |*cursor| cursor.advance(),
            };
        }
    };

    /// Removes only this scope's direct binding. An absent local binding is a
    /// successful no-op, including for an unmaterialized child scope; parent
    /// and core bindings are observation-only from here and may become visible
    /// again only after a local shadow is removed.
    pub fn unpublishWordCursor(
        self: *Scope,
        name: intern.NamespaceName,
    ) UnpublishCursor {
        const target = switch (self.storage) {
            .session => |environment| environment,
            .core_build => |environment| environment,
            .module_root => |environment| environment,
            .isolated => self.isolated_environment.load(.acquire) orelse return .absent,
        };
        return .{ .environment = target.unbindCursor(name) };
    }

    /// Publishes one word definition, whichever publication this scope
    /// accepts. Callers were switching on `publisher()` themselves and
    /// restating the payload in both arms to differ in one field, so the
    /// narrowing lives here instead: a `TopPublication` has no place for a
    /// visibility, and dropping it is sound because privacy is only offered
    /// where it means something — `defp`/`setp` are refused outside a module
    /// root, so a caller reaching a top scope has already established that
    /// its definition is public. Taking the word fields rather than a whole
    /// `ModulePublication` is what keeps this total: there is no native or
    /// builtin case to reject, because neither can be spelled here.
    pub fn publishWordCursor(
        self: *Scope,
        name: intern.NamespaceName,
        definition: WordDefinition,
    ) error{OutOfMemory}!Environment.BindCursor {
        return switch (self.publisher()) {
            .module => |module| module.cursor(name, .{ .word = .{
                .body = definition.body,
                .source = definition.source,
                .visibility = definition.visibility,
                .effect = definition.effect,
                .doc = definition.doc,
            } }),
            .top => |top| top.cursor(name, .{ .word = .{
                .body = definition.body,
                .source = definition.source,
                .effect = definition.effect,
                .doc = definition.doc,
            } }),
        };
    }

    /// The one publication this scope accepts. Every scope has exactly one,
    /// so a definition sink is chosen by switching on a capability rather
    /// than by asking a kind enum and trusting the answer; neither arm can be
    /// applied to the wrong storage, which is what the two `unreachable`
    /// bodies here used to be for.
    pub fn publisher(self: *Scope) ScopePublisher {
        return switch (self.storage) {
            .session, .core_build, .isolated => .{ .top = .{ .scope = self } },
            .module_root => |target| .{ .module = .init(target) },
        };
    }
};
/// Authority to publish top-level bindings into one scope. It materializes an
/// isolated scope's environment on first publication, so issuing one allocates
/// nothing.
pub const TopPublisher = struct {
    scope: *Scope,

    pub fn publish(
        self: TopPublisher,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) BindError!*BindingCell {
        return (try self.scope.writableEnvironment()).bind(name, BindingSpec.fromTop(publication));
    }

    pub fn cursor(
        self: TopPublisher,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) error{OutOfMemory}!Environment.BindCursor {
        return (try self.scope.writableEnvironment()).bindCursor(
            name,
            BindingSpec.fromTop(publication),
        );
    }
};

/// Authority to publish definitions into one module image's environment and to
/// end its construction. The backing pointer is unavailable, so a holder can
/// define and freeze but cannot retarget the environment or reach its
/// allocator and retirement ownership.
pub const ModulePublisher = enum(usize) {
    invalid = 0,
    _,

    fn init(environment: *Environment) ModulePublisher {
        return @enumFromInt(@intFromPtr(environment));
    }

    fn target(self: ModulePublisher) *Environment {
        std.debug.assert(self != .invalid);
        return @ptrFromInt(@intFromEnum(self));
    }

    pub fn publish(
        self: ModulePublisher,
        name: intern.NamespaceName,
        publication: ModulePublication,
    ) BindError!*BindingCell {
        return self.target().bind(name, BindingSpec.fromModule(name, publication));
    }

    pub fn cursor(
        self: ModulePublisher,
        name: intern.NamespaceName,
        publication: ModulePublication,
    ) error{OutOfMemory}!Environment.BindCursor {
        return self.target().bindCursor(name, BindingSpec.fromModule(name, publication));
    }

    /// Ends construction. A sealed image has no publisher, so this is the one
    /// transition that makes late definition impossible rather than merely
    /// refused.
    pub fn freeze(self: ModulePublisher) void {
        self.target().freeze();
    }
};

/// Which publication one scope accepts. Exactly one arm exists per scope.
pub const ScopePublisher = union(enum) {
    top: TopPublisher,
    module: ModulePublisher,
};
comptime {
    heap.requireOpaqueMutation(ModulePublisher);
}

/// The indirection that lets a quotation name the scope its text was written
/// in without any value holding an owning pointer into the environment. Whoever
/// owns a publishing scope's lifetime allocates one cell and retires it when
/// that scope goes, and each reference to the cell holds a count, so a cell
/// outlives its scope exactly as long as something still names it. Reclamation
/// goes through the release domain rather than happening on a reader's stack,
/// which is what keeps a concurrent reader safe against a publisher clearing
/// the same cell.
///
/// Keeping the owning edge outside the value heap is what keeps the heap
/// acyclic: an owning `*Scope` in a value would close a cycle on the first
/// `def` — Scope -> Environment -> BindingCell -> BindingSpec -> binding.word ->
/// Scope — and precise reference counting cannot release that.
/// A scope's stable public name. A word occurrence carries one of these rather
/// than a pointer, because it has four bytes to spend and not eight. Zero means
/// "no written-in scope" and resolves wherever the word is invoked.
///
/// Ids are issued monotonically and never recycled. A word token holds a bare
/// integer and takes no reference, so a reused id would let a stale token
/// resolve into an unrelated scope — a silent wrong answer, which is worse than
/// any failure this design can otherwise produce. Ids are consumed only by the
/// two roots and by module images, so the space is spent on registrations and
/// reloads rather than on execution.
pub const ScopeId = enum(u32) { none = 0, _ };

/// A `ScopeId` is 24 bits of directory index plus a reserved high byte.
///
/// The byte is reserved for a generation tag, which is what reusing an index
/// would require: a stale word token holds a bare id and takes no reference of
/// its own, so without a tag a reused index would let it resolve into an
/// unrelated scope. Reuse is deferred rather than impossible, and the tag is
/// not the only thing it would need -- see design/INTERPRETER.md for why a weak
/// image reference comes with it. Until then the byte stays clear, asserted on
/// every issued id, so adding the tag later cannot collide with a live value.
pub const id_bits: u5 = 24;
pub const reserved_bits: u5 = 8;

comptime {
    const budget: u16 = @as(u16, id_bits) + @as(u16, reserved_bits);
    if (budget != @bitSizeOf(@typeInfo(ScopeId).@"enum".tag_type))
        @compileError("scope id bit budget does not cover its tag type");
}

/// What a `ScopeId` names right now.
pub const ScopeResolution = union(enum) {
    /// Id zero: a word with no written-in scope.
    unscoped,
    /// An id that was issued and whose scope has since been torn down.
    retired,
    /// Core alone, which the machine spells as a null resolution scope. Core is
    /// a terminal phase rather than a link in any chain, so no `Scope` denotes
    /// it and a primitive or embedded-prelude word names this instead.
    core,
    /// A live cell. The scope is deliberately not handed over here: reaching it
    /// requires a `Liveness` proof, because a cell names its image without
    /// holding it and the bare pointer was exactly the unsound borrow.
    cell: *ScopeCell,
};

/// Proof that a borrowed scope stays alive for the duration of the borrow.
///
/// Three arms and no fourth. The type exists so that obtaining a `*Scope` from
/// a cell is impossible without having decided which one applies -- the defect
/// being fixed is precisely that `scopeOf` used to hand out a pointer nobody
/// held.
pub const Liveness = union(enum) {
    /// The running activation already holds this image, proven by comparing its
    /// anchor against the cell's. Zero atomic cost, and the common case: a
    /// module body executing its own words.
    activation_held,
    /// A reference was acquired for this borrow and is held for at least as
    /// long as the scope pointer is used.
    fresh_pin,
    /// The cell names no image. A session root or an `@attempt` child scope is
    /// owned by the activation or session performing the read and cannot be
    /// retired underneath it, so this arm is today's read, unchanged. Those
    /// lifetimes are deliberately outside this design.
    non_image,
};

pub const ScopeCell = struct {
    id: ScopeId,
    scope: std.atomic.Value(?*Scope) = .init(null),
    /// The image owner this cell names, opaque here on purpose: `env` never
    /// dereferences it and holds no dependency on `modules`. Null for every
    /// cell that names no image -- the session root, an `@attempt` child scope,
    /// and the embedded core cell -- which is what selects `Liveness.non_image`.
    ///
    /// It outlives the image, so it stays readable after retirement; that is the
    /// whole reason the borrow tests the owner rather than the scope.
    owner: std.atomic.Value(?*anyopaque) = .init(null),
    /// Core is a terminal resolution phase rather than a link in any chain, so
    /// it has no `Scope` to point at. One embedded cell carries this instead,
    /// and a primitive or embedded-prelude literal labels against it.
    core: bool = false,
    /// How many borrows currently hold the scope this cell names.
    ///
    /// The count lives here and not on the `Scope` because this cell is
    /// immortal -- `Env`-owned, freed only at `Env` teardown -- so bumping it is
    /// always safe, while the scope it names can be freed underneath a reader.
    /// That is the whole trick: put the count on the metadata that outlives the
    /// object, and a borrow needs no anchor of its own.
    borrows: std.atomic.Value(u32) = .init(0),

    /// Fills in what this cell names, before its id has escaped.
    ///
    /// The owner is stored before the scope, and both before registration, so a
    /// reader that can see the scope can already see what to acquire before
    /// touching it. This used to be a post-hoc store on a cell whose id was
    /// already reachable through the lock-free directory, which left two
    /// windows: an id naming a cell with no scope yet (a spurious `retired` for
    /// a live image), and one naming a live scope with no owner yet (the
    /// `non_image` arm dereferencing an image with nothing held). Being the
    /// only constructor is what closes them.
    pub fn publishOwned(self: *ScopeCell, scope: *Scope, owner: ?*anyopaque) void {
        if (owner) |handle| self.owner.store(handle, .release);
        self.scope.store(scope, .release);
    }

    /// The image owner, or null when this cell names none.
    pub fn ownerHandle(self: *const ScopeCell) ?*anyopaque {
        return self.owner.load(.acquire);
    }

    /// Acquire-then-validate: take a borrow of the named scope, or nothing.
    ///
    /// `RetireCursor.init` clears this cell before any teardown step, which
    /// makes the clear the commit point and covers both interleavings. A
    /// borrower that bumped before the clear is seen by the teardown wait and
    /// held for. One that bumped after sees null here, drops the count, and
    /// never dereferences -- and its bump landed on immortal memory, so nothing
    /// was resurrected.
    pub fn acquire(self: *ScopeCell) ?*Scope {
        _ = self.borrows.fetchAdd(1, .acq_rel);
        if (self.scope.load(.acquire)) |named| return named;
        self.releaseBorrow();
        return null;
    }

    /// Drops one borrow. The teardown wait reads this, so it must run exactly
    /// once per successful `acquire`.
    pub fn releaseBorrow(self: *ScopeCell) void {
        const old = self.borrows.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
    }

    /// Whether any borrow still holds the named scope. Teardown waits on this
    /// after clearing the cell, never before: clearing first is what stops new
    /// borrows from succeeding.
    pub fn borrowed(self: *const ScopeCell) bool {
        return self.borrows.load(.acquire) != 0;
    }

    /// The borrowed scope, obtainable only against a liveness proof. The proof
    /// is not inspected -- it cannot be, since `env` does not know what an
    /// owner is -- so it documents and gates rather than validates. Its value is
    /// that no caller reaches a scope without having stated why that is safe.
    pub fn scopeUnder(self: *const ScopeCell, _: Liveness) ?*Scope {
        return self.scope.load(.acquire);
    }

    /// Marks the cell as naming nothing, which is what a word written in a
    /// replaced or removed image resolves to. Deliberately not freed here: a
    /// cell is read without a lock and without a reference on every word
    /// dispatch, so the `Env` owns them all and frees them together at
    /// teardown, the one point at which no reader exists.
    pub fn retire(self: *ScopeCell) void {
        self.scope.store(null, .release);
    }
};

/// A three-level direct directory keyed by the 24 low bits of a `ScopeId`, the
/// same shape and for the same reason as `spans.HeaderIndex`: a sibling
/// consumer of a small dense id space rather than an extension of it. Pages are
/// installed once and live for the directory's lifetime, so a reader needs no
/// lock and lookup is three atomic loads — which is what makes it usable on the
/// dispatch path.
const ScopeIndex = struct {
    const radix = 256;
    const Leaf = struct {
        cells: [radix]std.atomic.Value(?*ScopeCell) = @splat(.init(null)),
    };
    const Branch = struct {
        leaves: [radix]std.atomic.Value(?*Leaf) = @splat(.init(null)),
    };

    mutex: std.Io.Mutex = .init,
    next: std.atomic.Value(u32) = .init(1),
    branches: [radix]std.atomic.Value(?*Branch) = @splat(.init(null)),

    const max_id: u32 = (1 << id_bits) - 1;

    fn coordinates(id: ScopeId) struct { usize, usize, usize } {
        const raw = @intFromEnum(id);
        std.debug.assert(raw != 0 and raw <= max_id);
        return .{
            @intCast((raw >> 16) & 0xff),
            @intCast((raw >> 8) & 0xff),
            @intCast(raw & 0xff),
        };
    }

    fn get(self: *const ScopeIndex, id: ScopeId) ?*ScopeCell {
        const branch_index, const leaf_index, const entry_index = coordinates(id);
        const branch = self.branches[branch_index].load(.acquire) orelse return null;
        const leaf = branch.leaves[leaf_index].load(.acquire) orelse return null;
        return leaf.cells[entry_index].load(.acquire);
    }

    /// Issues the next id and installs the entry. Candidate pages are allocated
    /// before the lock is taken, so no allocation happens while a publisher
    /// holds it; a racing publisher preparing the same page loses and destroys
    /// its unused candidate.
    fn register(
        self: *ScopeIndex,
        allocator: std.mem.Allocator,
        cell: *ScopeCell,
    ) error{OutOfMemory}!ScopeId {
        var branch_candidate: ?*Branch = try allocator.create(Branch);
        branch_candidate.?.* = .{};
        var leaf_candidate: ?*Leaf = allocator.create(Leaf) catch |err| {
            allocator.destroy(branch_candidate.?);
            return err;
        };
        leaf_candidate.?.* = .{};
        defer {
            if (branch_candidate) |unused| allocator.destroy(unused);
            if (leaf_candidate) |unused| allocator.destroy(unused);
        }

        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const raw = self.next.load(.monotonic);
        if (raw > max_id) return error.OutOfMemory;
        const id: ScopeId = @enumFromInt(raw);
        const branch_index, const leaf_index, const entry_index = coordinates(id);
        const branch = self.branches[branch_index].load(.acquire) orelse installed: {
            const chosen = branch_candidate.?;
            branch_candidate = null;
            self.branches[branch_index].store(chosen, .release);
            break :installed chosen;
        };
        const leaf = branch.leaves[leaf_index].load(.acquire) orelse installed: {
            const chosen = leaf_candidate.?;
            leaf_candidate = null;
            branch.leaves[leaf_index].store(chosen, .release);
            break :installed chosen;
        };
        std.debug.assert(leaf.cells[entry_index].load(.acquire) == null);
        leaf.cells[entry_index].store(cell, .release);
        self.next.store(raw + 1, .monotonic);
        // Restates what the `max_id` refusal above already guarantees. It is
        // here so that adding a generation tag to the reserved byte cannot
        // silently start overlapping issued indices.
        std.debug.assert(raw >> id_bits == 0);
        return id;
    }

    fn deinit(self: *ScopeIndex, allocator: std.mem.Allocator) void {
        for (&self.branches) |*slot| if (slot.load(.acquire)) |branch| {
            for (&branch.leaves) |*leaf_slot| if (leaf_slot.load(.acquire)) |leaf|
                allocator.destroy(leaf);
            allocator.destroy(branch);
        };
        self.* = .{};
    }
};

const EnvState = struct {
    host: *const heap.HostCleanup,
    unit_plan_seal: *const heap.UnitPlanSeal,
    core: Environment,
    session: Environment,
    core_cell: ScopeCell,
    seed_binding: enum { vacant, installed } = .vacant,
    /// Every cell this Env has issued, freed together at teardown. Images are
    /// constructed concurrently, so the list needs its own lock: it is grown
    /// off the registry's writer lock and off the scope index's.
    cells: std.ArrayList(*ScopeCell) = .empty,
    cells_mutex: std.Io.Mutex = .init,
    scopes: ScopeIndex = .{},
};

pub const Env = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Env) *EnvState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    pub fn init(host_owner: *heap.HostOwner) error{OutOfMemory}!Env {
        const host = host_owner.cleanup();
        const allocator = host.allocator();
        const releases = heap.hostDomain(host);
        const backing = try allocator.create(EnvState);
        backing.* = .{
            .host = host,
            .unit_plan_seal = host_owner.unitPlanSeal(),
            .core = Environment.init(allocator, releases),
            .session = Environment.init(allocator, releases),
            // SAFETY: the cell needs the Env handle that this very allocation
            // becomes, so it is filled in on the next line, before `backing`
            // escapes and before anything can read it.
            .core_cell = undefined,
        };
        const result: Env = @enumFromInt(@intFromPtr(backing));
        backing.core_cell = .{ .id = .none, .core = true };
        // Core needs a real id: a prelude word's tokens name it, and id zero
        // would mean "unscoped" and resolve them wherever they were invoked,
        // which is the leak this whole change closes. The core cell is embedded
        // and never retires, so its entry stands for the Env's lifetime.
        backing.core_cell.id = backing.scopes.register(allocator, &backing.core_cell) catch |err| {
            var session_cursor = Environment.TeardownCursor.init(&backing.session);
            while (!session_cursor.advance()) {}
            var core_cursor = Environment.TeardownCursor.init(&backing.core);
            while (!core_cursor.advance()) {}
            backing.scopes.deinit(allocator);
            allocator.destroy(backing);
            return err;
        };
        return result;
    }
    pub fn deinit(self: *Env) void {
        const backing = self.privateState();
        const allocator = backing.host.allocator();
        var session_cursor = Environment.TeardownCursor.init(&backing.session);
        while (!session_cursor.advance()) {}
        var core_cursor = Environment.TeardownCursor.init(&backing.core);
        while (!core_cursor.advance()) {}
        // Drain before freeing, not after. The reverse order is a
        // write-after-free, and the path is short enough to walk: teardown
        // defers each binding cell, whose retirement releases its snapshots,
        // whose `spec.retire` releases a `.word` body's header, whose
        // destruction releases that quotation's elements. A module value
        // element drops the last reference to a stamped image, and
        // `ModuleImage.release` retires the image's `label_cell` -- an
        // Env-owned cell -- before any other teardown step. `drainOwned` runs
        // to quiescence, so every one of those generations lands inside the
        // single drain below.
        //
        // The reachable shape is an *unregistered* image held only by a
        // binding: `((1) 'x def) @module 'm set`. A registered one dies in
        // `Session.deinit`'s earlier registry drain instead, with the cells
        // still alive, which is why the obvious `@defm` repro never reaches
        // this. Note also that a leak checker cannot witness the failure --
        // `DebugAllocator` reports double frees and leaks, not a stray write
        // into freed-but-mapped memory -- so a green allocator result here is
        // not evidence about this ordering. Only a sanitizer or this argument
        // is.
        backing.host.drain();
        for (backing.cells.items) |cell| allocator.destroy(cell);
        backing.cells.deinit(allocator);
        // The directory outlives nothing that reads it: `scopes.get` has exactly
        // one caller, `scopeOf`, reached only from dispatch, and execution stops
        // at `scheduler.deinit` before any teardown begins. Its pages hold
        // pointers nobody follows again.
        backing.scopes.deinit(allocator);
        allocator.destroy(backing);
        self.* = .consumed;
    }
    /// The id a primitive or embedded-prelude definition's words carry, so
    /// core alone is their chain.
    pub fn coreScopeId(self: *Env) ScopeId {
        return self.privateState().core_cell.id;
    }

    /// The id the words of source read in this scope carry.
    pub fn scopeIdFor(self: *Env, scope: *Scope) error{OutOfMemory}!ScopeId {
        return (try self.scopeCell(scope, null)).id;
    }

    /// The same, for a scope owned by a module image. `owner` is stored opaque
    /// and never dereferenced here; it is what lets a borrow acquire the image
    /// before reading the scope, and what stays readable once the image is gone.
    pub fn scopeIdForOwned(
        self: *Env,
        scope: *Scope,
        owner: *anyopaque,
    ) error{OutOfMemory}!ScopeId {
        return (try self.scopeCell(scope, owner)).id;
    }

    /// The cell a primitive or embedded-prelude definition labels against.
    /// It never retires: core lives for the `Env`'s lifetime.
    pub fn coreCell(self: *Env) *ScopeCell {
        return &self.privateState().core_cell;
    }

    /// The cell for one ordinary scope, created on first use. The scope retires
    /// it when its own refcount drops, before any teardown step.
    pub fn scopeCell(
        self: *Env,
        scope: *Scope,
        owner: ?*anyopaque,
    ) error{OutOfMemory}!*ScopeCell {
        if (scope.label_cell.load(.acquire)) |existing| {
            // A cell is born with its owner, so a later mint for the same scope
            // agrees rather than amends. An owner arriving after the id has
            // escaped is precisely the window this shape exists to remove, so
            // reintroducing it here would be the same defect one call deeper.
            std.debug.assert(owner == null or existing.ownerHandle() == owner);
            return existing;
        }
        const cell = try self.newScopeCell(scope, owner);
        if (scope.label_cell.cmpxchgStrong(null, cell, .release, .acquire)) |raced| {
            // The loser's cell is simply never named by anything. It stays
            // owned by the `Env` like every other cell and is freed at
            // teardown; retiring it here only marks it as naming nothing.
            cell.retire();
            return raced.?;
        }
        return cell;
    }

    /// A fresh indirection cell for one publishing scope. The caller owns the
    /// scope's lifetime and must `retire()` the cell before that scope's storage
    /// is torn down.
    /// A cell complete before its id exists.
    ///
    /// `register` is the sole point at which an id escapes into the lock-free
    /// directory, so everything the cell will ever name is set before it. A null
    /// scope is the cell that names nothing -- what a race loser becomes.
    pub fn newScopeCell(
        self: *Env,
        scope: ?*Scope,
        owner: ?*anyopaque,
    ) error{OutOfMemory}!*ScopeCell {
        const backing = self.privateState();
        const allocator = backing.host.allocator();
        const cell = try allocator.create(ScopeCell);
        cell.* = .{ .id = .none };
        if (scope) |named| cell.publishOwned(named, owner);
        // The Env owns every cell for its whole lifetime. A cell is read
        // without a lock and without a reference on every word dispatch, so
        // there is no safe earlier point to free one. Taking ownership before
        // registering leaves the failure path with nothing to undo.
        {
            std.Io.Threaded.mutexLock(&backing.cells_mutex);
            defer std.Io.Threaded.mutexUnlock(&backing.cells_mutex);
            backing.cells.append(allocator, cell) catch |err| {
                allocator.destroy(cell);
                return err;
            };
        }
        // Owned by `cells` from here, so a failed registration leaves a cell
        // that names nothing rather than one that leaks.
        cell.id = try backing.scopes.register(allocator, cell);
        return cell;
    }

    /// What a word's scope id names right now. Zero is a word with no
    /// written-in scope and resolves where it is invoked; a nonzero id with no
    /// entry was issued and has since retired, which is a definite failure
    /// rather than a fallback that would change what the word means.
    pub fn scopeOf(self: *const Env, id: ScopeId) ScopeResolution {
        if (id == .none) return .unscoped;
        const cell = self.privateState().scopes.get(id) orelse return .retired;
        if (cell.core) return .core;
        // A cleared scope is a definite retirement. A live one is handed over as
        // the cell, not as the pointer: the caller has to prove liveness before
        // it can read the scope out.
        if (cell.scope.load(.acquire) == null) return .retired;
        return .{ .cell = cell };
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
    fn installCoreSpec(self: *Env, name: CoreInstallName, spec: BindingSpec) error{OutOfMemory}!void {
        const validated_name: intern.NamespaceName = switch (name) {
            .ordinary => |ordinary| ordinary.value,
            .seed => intern.internReservedNamespace("seed") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => unreachable,
            },
        };
        _ = self.privateState().core.bind(validated_name, spec) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => unreachable,
        };
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
            tokens[index] = .{ .word = .{ .name = id } };
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
        body: *Quotation,
    ) error{ OutOfMemory, PrivilegedCoreName }!void {
        const ordinary = try OrdinaryCoreName.validate(name);
        try self.target.installCoreSpec(.{ .ordinary = ordinary }, .{
            .binding = .{ .word = body },
        });
    }
    /// Installs `seed`, and only `seed`: the name is a `comptime` parameter and
    /// any other word fails to compile. The target, rather than the copyable
    /// builder, records installation, and the binding carries only the opaque
    /// root-issued plan seal.
    pub fn installSeed(
        self: *BuildingEnv,
        comptime name: []const u8,
    ) error{OutOfMemory}!void {
        comptime if (!std.mem.eql(u8, name, "seed")) @compileError(
            "the seed binding kind belongs to `seed` and to no other word; " ++
                "`" ++ name ++ "` may not be installed with it",
        );
        const target = self.target.privateState();
        if (target.seed_binding == .installed) return;
        try self.installBuiltinBinding(.seed, name, .{ .seed = target.unit_plan_seal });
        target.seed_binding = .installed;
    }
    pub fn installBuiltin(
        self: *BuildingEnv,
        comptime name: []const u8,
        primitive: PrimitiveImpl,
    ) error{OutOfMemory}!void {
        comptime assertOrdinaryStaticNamespace(name);
        const raw_name = intern.internReservedNamespace(name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => unreachable,
        };
        const ordinary = OrdinaryCoreName.validate(raw_name) catch
            @panic("compile-time ordinary core-name validation disagreed with runtime validation");
        return self.installBuiltinBinding(
            .{ .ordinary = ordinary },
            name,
            .{ .builtin = primitive },
        );
    }
    fn installBuiltinBinding(
        self: *BuildingEnv,
        install_name: CoreInstallName,
        comptime name: []const u8,
        binding: Binding,
    ) error{OutOfMemory}!void {
        const core = &self.target.privateState().core;
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
            install_name,
            .{
                .binding = binding,
                .effect = if (builtin_effect) |effect| effect.validated else null,
                .doc = documentation(document_value.list).?,
            },
        );
    }
    pub fn installBuiltins(self: *BuildingEnv, comptime definitions: anytype) error{OutOfMemory}!void {
        comptime {
            @setEvalBranchQuota(4000);
            for (definitions, 0..) |definition, index| {
                assertOrdinaryStaticNamespace(definition.name);
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
        if (self.target.privateState().seed_binding != .installed)
            @panic("core build finished without the canonical seed binding");
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
    if (intern.isReservedBytes(name) or !lexer.validSymbolSegment(name)) {
        @compileError("invalid builtin namespace name: " ++ name);
    }
}
fn assertOrdinaryStaticNamespace(comptime name: []const u8) void {
    assertStaticNamespace(name);
    if (std.mem.eql(u8, name, "seed"))
        @compileError("the canonical seed name is reserved for installSeed");
}
pub fn assertStaticModuleName(comptime name: []const u8) void {
    @setEvalBranchQuota(10_000);
    if (name.len == 0) @compileError("embedded module name must be nonempty");
    var segment_start: usize = 0;
    for (name, 0..) |byte, index| {
        if (byte != '.') continue;
        if (index == segment_start or
            intern.isReservedBytes(name[segment_start..index]) or
            !lexer.validSymbolSegment(name[segment_start..index]))
        {
            @compileError("invalid embedded module name: " ++ name);
        }
        segment_start = index + 1;
    }
    if (segment_start == name.len or
        intern.isReservedBytes(name[segment_start..]) or
        !lexer.validSymbolSegment(name[segment_start..]))
    {
        @compileError("invalid embedded module name: " ++ name);
    }
}
pub const testing = if (builtin.is_test) struct {
    pub fn deinitEnvironment(environment: *Environment) void {
        var cursor = Environment.TeardownCursor.init(environment);
        while (!cursor.advance()) {}
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
            var environment = try Env.init(&host);
            defer environment.deinit();
            const body = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 7 }});
            defer releases.releaseValue(body);
            const name = try intern.internNamespace("failure-probe");
            const replacement = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 9 }});
            defer releases.releaseValue(replacement);
            try environment.define(name, .{ .word = .{ .body = quotation(body.list).? } });
            try environment.define(name, .{ .word = .{ .body = quotation(replacement.list).? } });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "env: issued scope ids leave their reserved high bits clear" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var container = try Env.init(&host);
    defer container.deinit();

    // More than one leaf's worth, so the assertion covers ids whose directory
    // coordinates differ in the branch and leaf bytes and not only the entry.
    const issued = ScopeIndex.radix + 3;
    var previous: u32 = 0;
    for (0..issued) |_| {
        // Names nothing: this asserts about issued ids, not about scopes.
        const cell = try container.newScopeCell(null, null);
        const raw = @intFromEnum(cell.id);
        try std.testing.expect(raw != 0);
        try std.testing.expect(raw <= ScopeIndex.max_id);
        try std.testing.expectEqual(@as(u32, 0), raw >> id_bits);
        // Monotonic and never reused, which is the property the reserved byte
        // exists to let us relax later.
        try std.testing.expect(raw > previous);
        previous = raw;
    }
}

test "env: only `seed` may be installed as the seed binding kind" {
    const allocator = std.testing.allocator;
    var host: heap.HostOwner = .init(allocator);
    defer host.cleanup().drain();
    var environment = try Env.init(&host);
    defer environment.deinit();
    var building = environment.beginCoreBuild();
    // Static builtin names reject `seed` at compile time. This runtime surface
    // must reject the same spelling after the canonical binding is installed,
    // leaving the target's seed state and behavior inseparable.
    try building.installSeed("seed");
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer host.domain().releaseValue(body);
    const seed_name = try intern.internReservedNamespace("seed");
    try std.testing.expectError(
        error.PrivilegedCoreName,
        building.installCore(seed_name, quotation(body.list).?),
    );
}
