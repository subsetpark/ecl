//! Stable binding cells, name slots, and lazy scopes.
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
        .dict, .task, .module, .port, .reserved_mask => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.ListHandle) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .module, .port, .reserved_mask => null,
    };
}

pub fn documentationHeader(document: *const DocumentationString) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(document)));
}

pub const Binding = union(enum) {
    word: *Quotation,
    builtin: PrimitiveImpl,
    native: NativeCallable,
    pub fn retain(self: Binding) void {
        switch (self) {
            .word => |body| heap.incRef(quotationHeader(body)),
            .builtin => {},
            .native => |callable| callable.instance.retain(),
        }
    }
    pub fn retire(self: Binding, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .word => |body| releases.releaseHeader(quotationHeader(body)),
            .builtin => {},
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
/// are compiled in and therefore have no loader descriptor to carry it.
/// Slots either side of `--` in a builtin word's declared effect. Fixed
/// because these effects are fixed compiled-in text outside the user-data path.
pub const max_builtin_effect_tokens: usize = 16;

pub const BuiltinWord = struct {
    name: []const u8,
    /// Required: the repository holds module words to a documentation policy
    /// even though M11 made annotations optional as language semantics.
    doc: []const u8,
    /// Slot names either side of `--`, when the successful effect is fixed.
    /// Module invocation checks include deferred work; callback return is not
    /// the completion boundary.
    effect: ?[]const u8 = null,
    primitive: PrimitiveImpl,
};

pub fn assertStaticBuiltin(comptime word: BuiltinWord) void {
    assertStaticNamespace(word.name);
    if (word.doc.len == 0) @compileError("empty builtin documentation: " ++ word.name);
    if (word.effect) |effect| validateBuiltinEffect(word.name, effect);
}

fn validateBuiltinEffect(comptime name: []const u8, comptime effect: []const u8) void {
    if (effect.len == 0 or effect[0] == ' ' or effect[effect.len - 1] == ' ') {
        @compileError("invalid primitive effect: " ++ name);
    }
    for (effect[1..], effect[0 .. effect.len - 1]) |byte, previous| {
        if (byte == ' ' and previous == ' ') @compileError("invalid primitive effect spacing: " ++ name);
    }
    var separators: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, effect, ' ');
    while (iterator.next()) |token| separators += @intFromBool(std.mem.eql(u8, token, "--"));
    if (separators != 1) @compileError("primitive effect requires exactly one separator: " ++ name);
}

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

/// What a trusted definition's body was recognized as, decided once when its
/// environment froze. A frozen environment cannot change what the body's
/// words mean, so the outcome is a property of the definition; only whether
/// a particular call's operands admit it is left to that call. `env` stores
/// the record for the recognizer that produced it and does not interpret it.
pub const DirectIdiom = struct {
    entry: u16,
    /// Borrowed from the body, which the binding retains.
    constant: ?value.Value = null,
    active_word: ?u32 = null,
    active_index: ?u32 = null,
};

/// Recognition performed at a freeze edge. `names` are the only definitions
/// it can recognize, so the edge looks those up rather than walking the
/// environment, and its work does not grow with the environment's size.
pub const FreezeRecognizer = struct {
    names: []const []const u8,
    recognize: *const fn (lookup: FrozenLookup, name: []const u8, body: *Quotation) ?DirectIdiom,
};

/// Name resolution in an environment that is about to freeze, as a word in
/// one of its definitions resolves at runtime: its own environment, then core.
pub const FrozenLookup = struct {
    own: *const Environment,
    /// The core a module image falls back to; null when `own` is core.
    core: ?*const Environment,
    own_scope: u32,
    core_scope: u32,
    /// Where a word's slot is found, so its root can be compared.
    slots: *const SlotIndex,

    pub const Hit = struct {
        lease: BindingLease,
        in_core: bool,
    };

    /// The root id of the slot a word carries, or zero for an unlinked word.
    fn rootOf(self: FrozenLookup, slot_id: u32) u32 {
        return switch (wordTarget(slot_id)) {
            .unlinked => 0,
            .image => |scope| @backingInt(scope),
            .slot => |id| found: {
                const found = self.slots.get(id) orelse break :found 0;
                break :found @backingInt(found.rootCell().id);
            },
        };
    }

    /// Whether a word linked to `slot_id` resolves in this chain: its slot
    /// belongs to this environment or to core.
    pub fn admits(self: FrozenLookup, slot_id: u32) bool {
        const stamp = self.rootOf(slot_id);
        return stamp != 0 and (stamp == self.own_scope or stamp == self.core_scope);
    }

    /// Resolves `name` linked to `slot_id`: a core slot in core alone, the
    /// environment's own slot there first and then in core.
    pub fn resolve(self: FrozenLookup, slot_id: u32, name: u32) ?Hit {
        const stamp = self.rootOf(slot_id);
        const core = self.core orelse self.own;
        if (self.core != null and stamp == self.own_scope) {
            if (lookupFrozen(self.own, name)) |lease| return .{ .lease = lease, .in_core = false };
        }
        const lease = lookupFrozen(core, name) orelse return null;
        return .{ .lease = lease, .in_core = true };
    }
};

/// One lookup on the blocking freeze edge, which owns the environment.
fn lookupFrozen(environment: *const Environment, name: u32) ?BindingLease {
    var cursor = environment.directLookupCursor(name);
    defer cursor.deinit();
    return poll.drive(?BindingLease, &cursor, .{});
}

const BindingSpec = struct {
    binding: Binding,
    visibility: Visibility = .public,
    origin: BindingOrigin = .top,
    effect: ?ValidatedEffect = null,
    doc: ?*DocumentationString = null,
    source: ?reader_types.SourceSlice = null,
    direct_idiom: ?DirectIdiom = null,
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
        if (self.source) |source| source.retain();
    }
    fn retire(self: BindingSpec, releases: *heap.ReleaseDomain) void {
        self.binding.retire(releases);
        if (self.effect) |effect| effect.retire(releases);
        if (self.doc) |doc| releases.releaseHeader(documentationHeader(doc));
        if (self.source) |source| {
            var owned = source;
            owned.deinit();
        }
    }
    pub fn deinit(self: *BindingSpec, releases: *heap.ReleaseDomain) void {
        self.retire(releases);
    }
};

const BindingSnapshot = struct {
    retirement: heap.ReleaseDomain.Retirement = .{},
    /// Slices read the current snapshot without a reference, so a detached
    /// chain waits for every slice that might have read it before it retires.
    deferred: heap.ReleaseDomain.Deferred = .{},
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
/// A binding's specification as a reader holds it; release it with the
/// environment's allocator. This is intentionally distinct from the
/// unpublished internal specification.
pub const BindingLease = struct {
    releases: *heap.ReleaseDomain,
    held: union(enum) {
        /// A copy holding references, which outlives the cell's snapshot.
        owned: BindingSpec,
        /// A slice reader's borrow: the current snapshot's specification,
        /// valid until the read section ends. It holds no references.
        borrowed: *const BindingSpec,
    },

    /// The specification this lease holds, borrowed from the lease.
    pub fn spec(self: *const BindingLease) *const BindingSpec {
        return switch (self.held) {
            .owned => |*owned| owned,
            .borrowed => |borrowed| borrowed,
        };
    }

    pub fn deinit(self: *BindingLease) void {
        switch (self.held) {
            .owned => |owned| owned.retire(self.releases),
            .borrowed => {},
        }
        self.* = undefined;
    }

    /// The definition's module-local name, or null for a top-level binding.
    /// Present exactly when the binding is module-local.
    pub fn traceWord(self: *const BindingLease) ?intern.BindingName {
        return self.spec().origin.traceWord();
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
        if (retired) |first| self.releases.retireAfterSlices(first, &first.retirement, &first.deferred);
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
        if (snapshots) |first| releases.retireAfterSlices(first, &first.retirement, &first.deferred);
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
        std.Io.Threaded.mutexLockUncancelable(&self.retire_lock);
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
        const result: BindingLease = .{ .releases = self.releases, .held = .{ .owned = lease.snapshot.?.spec } };
        if (lease.deinit()) {
            self.lockRetired();
            const retired = self.detachRetired();
            std.Io.Threaded.mutexUnlock(&self.retire_lock);
            if (retired) |first| self.releases.retireAfterSlices(first, &first.retirement, &first.deferred);
        }
        return result;
    }

    /// The current binding for a reader inside a slice's read section: one
    /// load, no reader count and no references. Valid until the section ends,
    /// because a replaced snapshot retires only after every section that began
    /// before its replacement has ended. The lease owns nothing; anything kept past the
    /// dispatch must be retained on its own, as a scheduled body already is.
    pub fn borrow(self: *BindingCell, slice: *const heap.ReleaseDomain.SliceRecord) BindingLease {
        std.debug.assert(slice.depth != 0);
        const snapshot = self.publisher.current.load(.seq_cst).?;
        return .{ .releases = self.releases, .held = .{ .borrowed = &snapshot.spec } };
    }
};

/// An owned reference to one stable binding cell. Loading always rereads the
/// cell's current snapshot; the one consumer that holds a payload across
/// executions is a data combinator's resolution plan, for the length of a call.
pub const BindingCellHandle = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(binding_cell: *BindingCell) BindingCellHandle {
        binding_cell.retain();
        return @fromBackingInt(@intCast(@intFromPtr(binding_cell)));
    }
    fn cell(self: BindingCellHandle) *BindingCell {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@backingInt(self));
    }
    pub fn load(self: BindingCellHandle) BindingLease {
        return self.cell().load();
    }
    pub fn borrow(self: BindingCellHandle, slice: *const heap.ReleaseDomain.SliceRecord) BindingLease {
        return self.cell().borrow(slice);
    }

    pub fn deinit(self: *BindingCellHandle) void {
        if (self.* == .consumed) return;
        self.cell().release();
        self.* = .consumed;
    }
};
/// Copyable observation authority for an environment. The backing pointer is
/// intentionally unavailable: readers can create leases and cursors, but
/// cannot retarget allocator or retirement ownership metadata.
pub const EnvironmentView = enum(usize) {
    invalid = 0,
    _,

    fn init(environment: *const Environment) EnvironmentView {
        return @fromBackingInt(@intCast(@intFromPtr(environment)));
    }

    fn target(self: EnvironmentView) *const Environment {
        std.debug.assert(self != .invalid);
        return @ptrFromInt(@backingInt(self));
    }

    pub fn nameCursor(self: EnvironmentView) NameCursor {
        return self.target().nameCursor();
    }

    pub fn directLookupCursor(self: EnvironmentView, id: u32) DirectLookupCursor {
        return self.target().directLookupCursor(id);
    }
};

comptime {
    heap.requireOpaqueObservation(EnvironmentView);
}

/// One counted reader of an environment's slots, which teardown waits out.
const ReaderHold = struct {
    environment: *const Environment,

    fn init(environment: *const Environment) ReaderHold {
        _ = @constCast(environment).readers.fetchAdd(1, .acquire);
        return .{ .environment = environment };
    }

    fn deinit(self: *ReaderHold) void {
        _ = @constCast(self.environment).readers.fetchSub(1, .release);
        self.* = undefined;
    }
};

pub const NameEntry = struct { name: u32, lease: BindingLease };
pub const NameCursorProgress = poll.StreamProgress(NameEntry);
/// The names an environment binds, one slot per step. A root's slots are only
/// added while it lives, so a walk reports every name bound before it began
/// and still bound when reached, and may report names bound during it.
pub const NameCursor = struct {
    reader: ReaderHold,
    buckets: []const SlotTable.Bucket,
    bucket: usize = 0,
    next: ?*Slot = null,

    pub fn deinit(self: *NameCursor) void {
        self.reader.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *NameCursor) NameCursorProgress {
        const slot = self.next orelse {
            if (self.bucket == self.buckets.len) return .complete;
            self.next = self.buckets[self.bucket].load(.acquire);
            self.bucket += 1;
            return .pending;
        };
        self.next = slot.next_in_root.load(.acquire);
        const cell = slot.boundCell() orelse return .pending;
        return .{ .item = .{ .name = slot.nameId(), .lease = cell.load() } };
    }
};

pub const DirectLookupProgress = poll.Progress(?BindingLease);
pub const DirectLookupCursor = struct {
    reader: ReaderHold,
    validation: intern.NamespaceCursor,
    capture_cell: bool = false,
    cell: ?BindingCellHandle = null,
    pub fn deinit(self: *DirectLookupCursor) void {
        if (self.cell) |*cell| cell.deinit();
        self.reader.deinit();
        self.* = undefined;
    }
    pub fn captureCell(self: *DirectLookupCursor) void {
        self.capture_cell = true;
    }
    pub fn takeCell(self: *DirectLookupCursor) ?BindingCellHandle {
        const result = self.cell;
        self.cell = null;
        return result;
    }
    pub fn advance(self: *DirectLookupCursor) DirectLookupProgress {
        return switch (self.validation.advance()) {
            .pending => .pending,
            .complete => |name| found: {
                const binding_name = name orelse break :found .{ .complete = null };
                const slot = self.reader.environment.slots.get(@backingInt(binding_name)) orelse
                    break :found .{ .complete = null };
                const binding_cell = slot.boundCell() orelse break :found .{ .complete = null };
                if (self.capture_cell) self.cell = .initRetained(binding_cell);
                break :found .{ .complete = binding_cell.load() };
            },
        };
    }
};
pub const BindError = error{ OutOfMemory, Frozen };
/// One root's bindings: a slot per name it has bound or linked, each holding
/// the name's stable, lease-backed cell.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    writer: std.Io.Mutex = .init,
    /// Counted name and lookup cursors, which teardown waits out.
    readers: std.atomic.Value(u32) = .init(0),
    frozen: std.atomic.Value(bool) = .init(false),
    /// This root's name slots, by raw name id: one for every name it has bound
    /// or a word in it has linked. Guarded by `writer`, so a binding and its
    /// slot are made consistent under one lock. The environment owns them and
    /// frees them when it is torn down.
    slots: SlotTable = .{},
    /// The bucket count the slot table is sized to when its first slot is
    /// made. A module image binds and links few names; the session and core
    /// many.
    slot_buckets: usize = 64,

    pub const TeardownCursor = struct {
        target: *Environment,
        state: enum { waiting_for_readers, complete },

        /// Starts in `waiting_for_readers` rather than asserting quiescence.
        ///
        /// The retain-before-dereference order should make a live reader here
        /// unreachable: a borrow acquires the image before it touches the
        /// scope, so an environment only reaches teardown once its image has no
        /// references left. This wait adds defence beyond the ownership argument. An assert
        /// would be the worst of both -- it neither prevents the race nor
        /// survives ReleaseFast, where it compiles away.
        pub fn init(target: *Environment) TeardownCursor {
            return .{ .target = target, .state = .waiting_for_readers };
        }

        pub fn advance(self: *TeardownCursor) bool {
            switch (self.state) {
                .waiting_for_readers => {
                    if (self.target.readers.load(.acquire) != 0) return false;
                    // The root is retiring, so no word linked to these slots
                    // can prove it live again: drop what they hold.
                    self.target.slots.retireAll(self.target.allocator);
                    self.state = .complete;
                    return true;
                },
                .complete => return true,
            }
        }
    };
    pub fn init(allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) Environment {
        return .{
            .allocator = allocator,
            .releases = releases,
        };
    }
    fn lockBlocking(self: *Environment) void {
        std.Io.Threaded.mutexLockUncancelable(&self.writer);
    }
    fn unlock(self: *Environment) void {
        std.Io.Threaded.mutexUnlock(&self.writer);
    }
    pub fn nameCursor(self: *const Environment) NameCursor {
        return .{ .reader = .init(self), .buckets = self.slots.buckets() };
    }
    pub fn directLookupCursor(self: *const Environment, id: u32) DirectLookupCursor {
        return .{
            .reader = .init(self),
            // A lookup may find a reserved name; only publication may not use
            // one. The runtime installs the words it reserves — the locals
            // backend — and a gate that refused to resolve them would reserve
            // them from their only legitimate caller. Nothing else can reach
            // this table under a reserved name, because every publishing path
            // still validates strictly.
            .validation = .initReserved(id),
        };
    }

    /// The slot for raw name `name`, made unlinked if the root has none.
    /// Caller holds `writer`.
    fn slotLocked(self: *Environment, name: u32) error{OutOfMemory}!*Slot {
        if (self.slots.get(name)) |existing| return existing;
        try self.slots.reserve(self.allocator, self.slot_buckets);
        const created = try self.allocator.create(Slot);
        created.* = .{};
        created.name.store(name, .monotonic);
        self.slots.put(created);
        return created;
    }

    pub const BindProgress = poll.Progress(*BindingCell);
    /// Binds a name in one step under `writer`. A name keeps one cell for the
    /// root's lifetime: the first binding makes it, and every later binding,
    /// including one after removal, replaces its payload.
    pub const BindCursor = struct {
        environment: *Environment,
        id: intern.NamespaceName,
        spec: BindingSpec,
        /// A cell made before taking the lock, for a name that had none then.
        candidate_cell: ?*BindingCell,

        fn init(
            environment: *Environment,
            id: intern.NamespaceName,
            spec: BindingSpec,
        ) error{OutOfMemory}!BindCursor {
            environment.lockBlocking();
            const has_cell = if (environment.slots.get(@backingInt(id))) |slot|
                slot.cell.load(.acquire) != null
            else
                false;
            environment.unlock();
            return .{
                .environment = environment,
                .id = id,
                .spec = spec,
                .candidate_cell = if (has_cell) null else try BindingCell.create(
                    environment.allocator,
                    environment.releases,
                    spec,
                ),
            };
        }
        pub fn deinit(self: *BindCursor) void {
            if (self.candidate_cell) |candidate| candidate.release();
            self.* = undefined;
        }
        pub fn advance(self: *BindCursor) BindError!BindProgress {
            const environment = self.environment;
            environment.lockBlocking();
            defer environment.unlock();
            if (environment.frozen.load(.acquire)) return error.Frozen;
            const slot = try environment.slotLocked(@backingInt(self.id));
            // Cells are never removed while the root lives, so a name that had
            // one when this cursor began still has it; one that had none may
            // have gained one since, and the candidate then goes unused.
            const cell = if (slot.cell.load(.acquire)) |kept| replaced: {
                try kept.replace(environment.allocator, self.spec);
                break :replaced kept;
            } else adopted: {
                const candidate = self.candidate_cell.?;
                self.candidate_cell = null;
                slot.cell.store(candidate, .release);
                break :adopted candidate;
            };
            slot.bound.store(true, .release);
            return .{ .complete = cell };
        }
    };

    /// A retained reference to the cell bound to raw name `name`, or null when
    /// nothing is bound. Caller holds `writer`.
    fn boundCellLocked(self: *Environment, name: u32) ?*BindingCell {
        const slot = self.slots.get(name) orelse return null;
        const cell = slot.boundCell() orelse return null;
        cell.retain();
        return cell;
    }

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
    /// Removes a name in one step under `writer`. The slot keeps its cell,
    /// which still holds the last payload until the name is bound again or the
    /// root retires: dispatch borrows cells without references, so one is
    /// never freed while its root lives.
    pub const UnbindCursor = struct {
        environment: *Environment,
        id: intern.NamespaceName,

        fn init(environment: *Environment, id: intern.NamespaceName) UnbindCursor {
            return .{ .environment = environment, .id = id };
        }
        pub fn deinit(self: *UnbindCursor) void {
            self.* = undefined;
        }
        pub fn advance(self: *UnbindCursor) BindError!UnbindProgress {
            const environment = self.environment;
            environment.lockBlocking();
            defer environment.unlock();
            if (environment.frozen.load(.acquire)) return error.Frozen;
            const slot = environment.slots.get(@backingInt(self.id)) orelse return .{ .complete = false };
            if (!slot.bound.load(.acquire)) return .{ .complete = false };
            slot.bound.store(false, .release);
            return .{ .complete = true };
        }
    };

    fn unbindCursor(self: *Environment, name: intern.NamespaceName) UnbindCursor {
        return .init(self, name);
    }

    /// The mutation authority for a module image's own environment. An image
    /// owns this environment outright, so it publishes and freezes directly
    /// rather than routing through the scope it also owns.
    pub fn modulePublisher(self: *Environment) ModulePublisher {
        return .init(self);
    }
    /// Records each recognizable definition's outcome before the environment
    /// freezes. It republishes only cells that change and never walks the
    /// environment, so a failure leaves every definition as it was.
    fn recognizeDirect(self: *Environment, lookup: FrozenLookup, recognizer: FreezeRecognizer) error{OutOfMemory}!void {
        for (recognizer.names) |spelling| {
            const id = try intern.intern(spelling);
            var lease = lookupFrozen(self, id) orelse continue;
            defer lease.deinit();
            const body = switch (lease.spec().binding) {
                .word => |body| body,
                .builtin, .native => continue,
            };
            const idiom = recognizer.recognize(lookup, spelling, body) orelse continue;
            const name = intern.namespaceName(id) catch continue;
            var recognized = lease.spec().*;
            recognized.direct_idiom = idiom;
            _ = self.bind(name, recognized) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => unreachable,
            };
        }
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
};
pub const Scope = struct {
    allocator: std.mem.Allocator,
    storage: ScopeStorage,
    refs: std.atomic.Value(u32) = .init(1),
    allocation: ScopeAllocation = .embedded,
    /// The cell this root's words and slots name. Allocated on first use, so a
    /// root nothing links into costs nothing. A module image installs its own
    /// before the scope is reachable.
    label_cell: std.atomic.Value(?*ScopeCell) = .init(null),
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: ?RetireCursor.State = null,

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
            destroy,
            complete,
        };

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
            return .{ .scope = scope, .state = .destroy };
        }

        pub fn advance(self: *RetireCursor) bool {
            return switch (self.state) {
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
                // than an oversight. A name or lookup cursor is not counted
                // here, but such a reader can only have reached this scope
                // through a borrow that acquired the image first, and an image
                // with a live reference never reaches retirement -- so by the
                // time this runs, no such reader on this scope can exist. The
                // environment's own cursor waits on its readers anyway, which is
                // where one would be caught if that reasoning were ever falsified.
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
    fn direct(allocator: std.mem.Allocator, storage: ScopeStorage) Scope {
        return .{ .allocator = allocator, .storage = storage };
    }
    /// A module image's root. It carries no canonical name: the same frozen
    /// environment may execute under any number of registrations.
    pub fn moduleRoot(allocator: std.mem.Allocator, target: *Environment) Scope {
        return direct(allocator, .{ .module_root = target });
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
        };
    }
    fn releaseDomain(self: *const Scope) *heap.ReleaseDomain {
        return switch (self.storage) {
            .session => |target| target.releases,
            .core_build => |target| target.releases,
            .module_root => |target| target.releases,
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
        std.debug.assert(self.environmentOrNull() != null);
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old == 1);
        _ = self.refs.load(.acquire);
    }
    fn writableEnvironment(self: *Scope) *Environment {
        return switch (self.storage) {
            .session => |target| target,
            .core_build => |target| target,
            .module_root => |target| target,
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
    /// successful no-op; core bindings are observation-only from here and
    /// become visible again once a local shadow is removed.
    pub fn unpublishWordCursor(
        self: *Scope,
        name: intern.NamespaceName,
    ) UnpublishCursor {
        const target = switch (self.storage) {
            .session => |environment| environment,
            .core_build => |environment| environment,
            .module_root => |environment| environment,
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
            .session, .core_build => .{ .top = .{ .scope = self } },
            .module_root => |target| .{ .module = .init(target) },
        };
    }
};
/// Authority to publish top-level bindings into one scope.
pub const TopPublisher = struct {
    scope: *Scope,

    pub fn publish(
        self: TopPublisher,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) BindError!*BindingCell {
        return self.scope.writableEnvironment().bind(name, BindingSpec.fromTop(publication));
    }

    pub fn cursor(
        self: TopPublisher,
        name: intern.NamespaceName,
        publication: TopPublication,
    ) error{OutOfMemory}!Environment.BindCursor {
        return self.scope.writableEnvironment().bindCursor(
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
        return @fromBackingInt(@intCast(@intFromPtr(environment)));
    }

    fn target(self: ModulePublisher) *Environment {
        std.debug.assert(self != .invalid);
        return @ptrFromInt(@backingInt(self));
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
    /// refused. Recognition runs first, against the image's final bindings;
    /// if it fails, the image is not frozen and is not published.
    pub fn freeze(self: ModulePublisher, own_scope: ScopeId, recognition: ?ModuleRecognition) error{OutOfMemory}!void {
        const environment = self.target();
        if (recognition) |selected| try environment.recognizeDirect(.{
            .own = environment,
            .core = selected.core.target(),
            .own_scope = @backingInt(own_scope),
            .core_scope = @backingInt(selected.core_scope),
            .slots = selected.slots,
        }, selected.recognizer);
        environment.freeze();
    }
};

/// What a module image's freeze edge recognizes against besides the image
/// itself: the core its definitions fall back to.
pub const ModuleRecognition = struct {
    recognizer: FreezeRecognizer,
    core: EnvironmentView,
    core_scope: ScopeId,
    slots: *const SlotIndex,
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
    /// The cell names no image: the session root, which outlives every unit
    /// that reads it, so nothing is acquired.
    non_image,
};

pub const ScopeCell = struct {
    id: ScopeId,
    scope: std.atomic.Value(?*Scope) = .init(null),
    /// The image owner this cell names, opaque here on purpose: `env` never
    /// dereferences it and holds no dependency on `modules`. Null for every
    /// cell that names no image -- the session root and the embedded core cell
    /// -- which is what selects `Liveness.non_image`.
    ///
    /// It outlives the image, so it stays readable after retirement; that is the
    /// whole reason the borrow tests the owner rather than the scope.
    owner: std.atomic.Value(?*anyopaque) = .init(null),
    /// Core is a terminal resolution phase rather than a link in any chain, so
    /// it has no `Scope` to point at. One embedded cell carries this instead,
    /// and a primitive or embedded-prelude literal labels against it.
    core: bool = false,
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

/// A three-level direct directory keyed by the 24 low bits of an id, the same
/// shape and for the same reason as `spans.HeaderIndex`: a sibling consumer of
/// a small dense id space rather than an extension of it. Pages are installed
/// once and live for the directory's lifetime, so a reader needs no lock and
/// lookup is three atomic loads — which is what makes it usable on the
/// dispatch path. Ids are never reused: a stale word holds a bare id and no
/// reference, so a reused id would let it reach an unrelated entry.
fn Directory(comptime Id: type, comptime Entry: type) type {
    return struct {
        const Self = @This();
        const radix = 256;
        const Leaf = struct {
            entries: [radix]std.atomic.Value(?*Entry) = @splat(.init(null)),
        };
        const Branch = struct {
            leaves: [radix]std.atomic.Value(?*Leaf) = @splat(.init(null)),
        };

        mutex: std.Io.Mutex = .init,
        next: std.atomic.Value(u32) = .init(1),
        branches: [radix]std.atomic.Value(?*Branch) = @splat(.init(null)),

        const max_id: u32 = (1 << id_bits) - 1;

        fn coordinates(id: Id) struct { usize, usize, usize } {
            const raw = @backingInt(id);
            std.debug.assert(raw != 0 and raw <= max_id);
            return .{
                @intCast((raw >> 16) & 0xff),
                @intCast((raw >> 8) & 0xff),
                @intCast(raw & 0xff),
            };
        }

        fn get(self: *const Self, id: Id) ?*Entry {
            const branch_index, const leaf_index, const entry_index = coordinates(id);
            const branch = self.branches[branch_index].load(.acquire) orelse return null;
            const leaf = branch.leaves[leaf_index].load(.acquire) orelse return null;
            return leaf.entries[entry_index].load(.acquire);
        }

        /// Issues the next id and installs the entry. A missing page is
        /// allocated with the lock released and the target rechecked after, so
        /// no allocation happens while a publisher holds it and a registration
        /// into existing pages allocates nothing. A candidate a racing
        /// publisher made unnecessary is destroyed unused.
        fn register(
            self: *Self,
            allocator: std.mem.Allocator,
            entry: *Entry,
        ) error{OutOfMemory}!Id {
            var branch_candidate: ?*Branch = null;
            var leaf_candidate: ?*Leaf = null;
            defer {
                if (branch_candidate) |unused| allocator.destroy(unused);
                if (leaf_candidate) |unused| allocator.destroy(unused);
            }

            while (true) {
                std.Io.Threaded.mutexLockUncancelable(&self.mutex);
                const raw = self.next.load(.monotonic);
                const id: Id = @fromBackingInt(@intCast(@min(raw, max_id)));
                const branch_index, const leaf_index, _ = coordinates(id);
                const present = self.branches[branch_index].load(.acquire);
                const needs_branch = present == null and branch_candidate == null;
                const needs_leaf = leaf_candidate == null and
                    (present == null or present.?.leaves[leaf_index].load(.acquire) == null);
                if (raw > max_id or !(needs_branch or needs_leaf)) break;
                std.Io.Threaded.mutexUnlock(&self.mutex);
                if (needs_branch) {
                    branch_candidate = try allocator.create(Branch);
                    branch_candidate.?.* = .{};
                }
                if (needs_leaf) {
                    leaf_candidate = try allocator.create(Leaf);
                    leaf_candidate.?.* = .{};
                }
            }
            defer std.Io.Threaded.mutexUnlock(&self.mutex);
            const raw = self.next.load(.monotonic);
            if (raw > max_id) return error.OutOfMemory;
            const id: Id = @fromBackingInt(@intCast(raw));
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
            std.debug.assert(leaf.entries[entry_index].load(.acquire) == null);
            leaf.entries[entry_index].store(entry, .release);
            self.next.store(raw + 1, .monotonic);
            // Restates what the `max_id` refusal above already guarantees. It
            // is here so that adding a generation tag to the reserved byte
            // cannot silently start overlapping issued indices.
            std.debug.assert(raw >> id_bits == 0);
            return id;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.branches) |*branch_slot| if (branch_slot.load(.acquire)) |branch| {
                for (&branch.leaves) |*leaf_slot| if (leaf_slot.load(.acquire)) |leaf|
                    allocator.destroy(leaf);
                allocator.destroy(branch);
            };
            self.* = .{};
        }
    };
}
const ScopeIndex = Directory(ScopeId, ScopeCell);
const SlotIndex = Directory(SlotId, Slot);

/// The id a word occurrence carries: its name's slot in the root it was
/// written in. Zero is a word linked to nothing, which only the locals
/// backend's reserved words are.
///
/// A word written in a module image carries the image's `ScopeId` with
/// `image_root_flag` set instead, and finds its slot by name in the image's
/// table. Images come and go, so giving each of their slots a directory id,
/// which is never reused, would grow the directory with every module churned;
/// the image's own scope id already names it, and its name is in the word.
pub const SlotId = enum(u32) { none = 0, _ };
pub const image_root_flag: u32 = 1 << 31;

/// What a word's slot field names.
pub const WordTarget = union(enum) {
    unlinked,
    /// A session or core slot, by directory id.
    slot: SlotId,
    /// A module image root; the slot is found by name once the image is proven
    /// live.
    image: ScopeId,
};
pub fn wordTarget(raw: u32) WordTarget {
    if (raw == 0) return .unlinked;
    if (raw & image_root_flag != 0) return .{ .image = @fromBackingInt(raw & ~image_root_flag) };
    return .{ .slot = @fromBackingInt(raw) };
}

/// One name in one root: the session, a module image, or core.
///
/// A word links to its slot when it is written and reads the slot each time it
/// executes, so a definition reaches every word written in that root at its
/// next execution. The slot shares the root's binding cell for its name: a
/// binding made while the slot exists reuses the slot's cell, so the cell's
/// identity never changes and a reader never races a pointer swap. Removing
/// the name only clears `bound`.
///
/// A session or core slot is found through the directory by id, before
/// anything proves its root live, so it is owned by the `Env` for its whole
/// lifetime. A module image's slot is found only by name in the image's own
/// table, after the image is proven live, so it is freed with the image.
pub const Slot = struct {
    /// The id words carry for this slot, zero until a word first links to it.
    /// A binding makes the slots of names no word has linked yet.
    id: std.atomic.Value(u32) = .init(0),
    name: std.atomic.Value(u32) = .init(0),
    /// The root this slot belongs to, set when it is linked. Cells are immortal, so it is readable
    /// whether or not the root is, and it is what a reader proves liveness
    /// against before touching `cell`.
    root: std.atomic.Value(?*ScopeCell) = .init(null),
    /// The root's binding cell for the name, adopted on first binding and held
    /// until the root retires. Null while the name has never been bound here.
    cell: std.atomic.Value(?*BindingCell) = .init(null),
    /// Whether the root currently binds the name. False after removal, when
    /// `cell` still holds the last binding but nothing reads it.
    bound: std.atomic.Value(bool) = .init(false),
    /// Core's binding for the name, the fallback when the root has none. Core
    /// is frozen before any other root links a word, so this is fixed at link
    /// time; core's slot holds the cell for the `Env`'s lifetime. Null for a
    /// core slot and for a name core does not bind.
    core: std.atomic.Value(?*BindingCell) = .init(null),
    /// The next slot in the same bucket of its root's table.
    next_in_root: std.atomic.Value(?*Slot) = .init(null),

    pub fn nameId(self: *const Slot) u32 {
        return self.name.load(.monotonic);
    }
    pub fn rootCell(self: *const Slot) *ScopeCell {
        return self.root.load(.monotonic).?;
    }
    pub fn coreCell(self: *const Slot) ?*BindingCell {
        return self.core.load(.monotonic);
    }

    /// The cell this slot currently yields: the root's binding, else core's.
    /// The caller must have proven the root live.
    pub fn current(self: *const Slot) ?*BindingCell {
        if (self.bound.load(.acquire)) return self.cell.load(.acquire);
        return self.core.load(.monotonic);
    }

    /// The root's own binding for the name, or null when it binds none. Needs
    /// no proof beyond holding the environment: a slot keeps its cell until
    /// the root retires.
    fn boundCell(self: *const Slot) ?*BindingCell {
        if (!self.bound.load(.acquire)) return null;
        return self.cell.load(.acquire);
    }

    /// Drops what the slot holds. Runs only during the root's teardown, when
    /// no reader can prove the root live.
    fn retire(self: *Slot) void {
        self.bound.store(false, .release);
        if (self.cell.swap(null, .acq_rel)) |held| held.release();
        self.core.store(null, .monotonic);
    }
};

/// One root's slots by name: a bucket array chained through the slots, sized
/// once when the root makes its first slot and never rehashed, so no binding
/// or link pays for a resize. Writes are guarded by the root's `writer`; reads
/// need no lock. Dispatch reaches a slot through its id instead.
const SlotTable = struct {
    const Bucket = std.atomic.Value(?*Slot);
    /// Published once, before any slot is put; readers that find it null
    /// find nothing.
    buckets_ptr: std.atomic.Value(?[*]Bucket) = .init(null),
    len: usize = 0,

    fn bucket(len: usize, name: u32) usize {
        const mixed = @as(u64, name) *% 0x9E3779B97F4A7C15;
        return @intCast((mixed >> 32) % len);
    }
    /// Safe without `writer`: a put publishes a fully initialized slot with a
    /// release store, and nothing is removed until the root retires, when no
    /// reader can prove it live.
    fn get(self: *const SlotTable, name: u32) ?*Slot {
        const heads = self.buckets_ptr.load(.acquire) orelse return null;
        var cursor = heads[bucket(self.len, name)].load(.acquire);
        while (cursor) |slot| : (cursor = slot.next_in_root.load(.acquire)) {
            if (slot.nameId() == name) return slot;
        }
        return null;
    }
    /// Every bucket, empty before the first slot is made.
    fn buckets(self: *const SlotTable) []const Bucket {
        const heads = self.buckets_ptr.load(.acquire) orelse return &.{};
        return heads[0..self.len];
    }
    fn reserve(self: *SlotTable, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!void {
        if (self.buckets_ptr.load(.monotonic) != null) return;
        const heads = try allocator.alloc(Bucket, count);
        for (heads) |*head| head.* = .init(null);
        self.len = count;
        self.buckets_ptr.store(heads.ptr, .release);
    }
    fn put(self: *SlotTable, slot: *Slot) void {
        const heads = self.buckets_ptr.load(.monotonic).?;
        const head = &heads[bucket(self.len, slot.nameId())];
        slot.next_in_root.store(head.load(.monotonic), .monotonic);
        head.store(slot, .release);
    }
    /// Retires and frees every slot, then frees the buckets.
    fn retireAll(self: *SlotTable, allocator: std.mem.Allocator) void {
        const heads = self.buckets_ptr.load(.acquire) orelse return;
        for (heads[0..self.len]) |*head| {
            var cursor = head.load(.acquire);
            while (cursor) |slot| {
                cursor = slot.next_in_root.load(.acquire);
                slot.next_in_root.store(null, .monotonic);
                slot.retire();
                allocator.destroy(slot);
            }
        }
        allocator.free(heads[0..self.len]);
        self.* = .{};
    }
};

const EnvState = struct {
    host: *const heap.HostCleanup,
    core: Environment,
    session: Environment,
    core_cell: ScopeCell,
    /// Every cell this Env has issued, freed together at teardown. Images are
    /// constructed concurrently, so the list needs its own lock: it is grown
    /// off the registry's writer lock and off the scope index's.
    cells: std.ArrayList(*ScopeCell) = .empty,
    cells_mutex: std.Io.Mutex = .init,
    scopes: ScopeIndex = .{},
    slot_index: SlotIndex = .{},
    locals_words: intern.LocalsWords,
};

pub const Env = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Env) *EnvState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@backingInt(self.*));
    }

    pub fn init(host_owner: *heap.HostOwner) error{OutOfMemory}!Env {
        const host = host_owner.cleanup();
        const allocator = host.allocator();
        const releases = heap.hostDomain(host);
        const locals_words = try intern.LocalsWords.mint();
        const backing = try allocator.create(EnvState);
        backing.* = .{
            .host = host,
            .core = .{ .allocator = allocator, .releases = releases, .slot_buckets = 1024 },
            .session = .{ .allocator = allocator, .releases = releases, .slot_buckets = 1024 },
            .locals_words = locals_words,
            // SAFETY: the cell needs the Env handle that this very allocation
            // becomes, so it is filled in on the next line, before `backing`
            // escapes and before anything can read it.
            .core_cell = undefined,
        };
        const result: Env = @fromBackingInt(@intCast(@intFromPtr(backing)));
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
        // Drain completely before freeing. Reversing the order causes a
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
        // `DebugAllocator` reports double frees and leaks but cannot report a stray write
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
        backing.slot_index.deinit(allocator);
        allocator.destroy(backing);
        self.* = .consumed;
    }
    /// The id a primitive or embedded-prelude definition's words carry, so
    /// core alone is their chain.
    pub fn coreScopeId(self: *Env) ScopeId {
        return self.privateState().core_cell.id;
    }

    /// The id of a module image's scope cell. `owner` is stored opaque
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

    /// The domain binding snapshots retire into, and so the one a slice must
    /// enter to read them without references.
    pub fn bindingDomain(self: *const Env) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    /// The core environment, which owns core's name slots.
    pub fn coreEnvironment(self: *Env) *Environment {
        return &self.privateState().core;
    }

    /// The directory freeze-time recognition resolves a word's slot through.
    pub fn slotDirectory(self: *const Env) *const SlotIndex {
        return &self.privateState().slot_index;
    }

    /// Links words to their names' slots in the root `root` names. The root
    /// must outlive every use of the linker: the reader or construction that
    /// holds it runs inside that root.
    pub fn linker(self: *Env, root: *ScopeCell) value.WordLinker {
        return .{
            .context = .{ @backingInt(self.*), @intFromPtr(root) },
            .link_fn = linkFromContext,
        };
    }

    fn linkFromContext(context: [2]usize, name: u32) error{OutOfMemory}!u32 {
        var handle: Env = @fromBackingInt(context[0]);
        const root: *ScopeCell = @ptrFromInt(context[1]);
        const environment = if (root.core)
            &handle.privateState().core
        else
            root.scope.load(.acquire).?.writableEnvironment();
        return @backingInt(try handle.linkSlot(root, environment, name));
    }

    /// The slot a word carries, or null for an unlinked word or one whose id
    /// was never issued. A slot is never freed while the `Env` lives, so this
    /// needs no proof; what the slot references does.
    pub fn slot(self: *const Env, id: SlotId) ?*Slot {
        if (id == .none) return null;
        return self.privateState().slot_index.get(id);
    }

    /// The slot for `name` in the root `root` names, whose bindings live in
    /// `environment`, linked on first use: given an id, its root, and core's
    /// binding for the fallback. Linking never defines anything, so a frozen
    /// root links as readily as a live one.
    pub fn linkSlot(
        self: *Env,
        root: *ScopeCell,
        environment: *Environment,
        name: u32,
    ) error{OutOfMemory}!SlotId {
        const backing = self.privateState();
        environment.lockBlocking();
        defer environment.unlock();
        const image = root.ownerHandle() != null;
        // A core-build scope carries a non-core cell, but its words are core's:
        // the slot names core's cell and takes no fallback lock on itself.
        const into_core = root.core or environment == &backing.core;
        const slot_root = if (into_core) &backing.core_cell else root;
        const target = try environment.slotLocked(name);
        if (target.id.load(.monotonic) != 0) return if (image)
            @fromBackingInt(image_root_flag | @backingInt(root.id))
        else
            @fromBackingInt(target.id.load(.monotonic));
        // The id first, so failure leaves the slot unlinked. An image's slots
        // take no directory id; words name the image instead.
        const id: SlotId = if (image)
            @fromBackingInt(image_root_flag | @backingInt(root.id))
        else
            try backing.slot_index.register(backing.host.allocator(), target);
        target.root.store(slot_root, .monotonic);
        if (!into_core) {
            // Core's slots hold its cells until the Env is torn down, so the
            // fallback needs no reference of its own. Lock order is always a
            // root's writer before core's: core never links into another root.
            backing.core.lockBlocking();
            defer backing.core.unlock();
            if (backing.core.boundCellLocked(name)) |cell| {
                target.core.store(cell, .monotonic);
                cell.release();
            }
        }
        target.id.store(@backingInt(id), .release);
        return id;
    }

    /// The slot for `name` in `image`, a module root the caller has proven
    /// live, or null when no word in it named `name`.
    pub fn imageSlot(_: *const Env, image: *Scope, name: u32) ?*Slot {
        return switch (image.storage) {
            .module_root => |environment| environment.slots.get(name),
            .session, .core_build => null,
        };
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
            std.Io.Threaded.mutexLockUncancelable(&backing.cells_mutex);
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
        // the cell itself, requiring the caller to prove liveness before
        // it can read the scope out.
        if (cell.scope.load(.acquire) == null) return .retired;
        return .{ .cell = cell };
    }

    /// The reserved locals backend, bindable without a lookup in any scope.
    pub fn localsWords(self: *const Env) intern.LocalsWords {
        return self.privateState().locals_words;
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
    pub fn beginCoreBuild(self: *Env) BuildingEnv {
        return .{ .target = self };
    }
    pub fn sessionRoot(self: *Env, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .{ .session = &self.privateState().session });
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

    /// Only the static factory can pair authored metadata with its validated
    /// effect builder. Runtime installation never accepts an unchecked word.
    const StaticBuiltin = opaque {
        const EffectData = struct {
            tokens: []const []const u8,
            separator: usize,
            build: *const fn (*BuildingEnv, *const EffectData) error{OutOfMemory}!BuiltinEffect,
        };
        const Data = struct {
            definition: BuiltinWord,
            effect: ?EffectData,
        };

        fn effectBuilder(comptime count: usize) @FieldType(EffectData, "build") {
            return struct {
                fn build(builder: *BuildingEnv, effect: *const EffectData) error{OutOfMemory}!BuiltinEffect {
                    return builder.builtinEffect(count, effect);
                }
            }.build;
        }

        fn init(comptime definition: BuiltinWord) *const StaticBuiltin {
            const data = comptime blk: {
                assertStaticBuiltin(definition);
                const effect: ?EffectData = if (definition.effect) |source| effect: {
                    const count = countEffectTokens(source);
                    var tokens: [count][]const u8 = undefined;
                    var iterator = std.mem.tokenizeScalar(u8, source, ' ');
                    // SAFETY: assertStaticBuiltin guarantees exactly one `--`
                    // token, so the loop assigns separator before it is read.
                    var separator: usize = undefined;
                    for (&tokens, 0..) |*token, index| {
                        token.* = iterator.next().?;
                        if (std.mem.eql(u8, token.*, "--")) separator = index;
                    }
                    const frozen = tokens;
                    break :effect .{ .tokens = &frozen, .separator = separator, .build = effectBuilder(count) };
                } else null;
                break :blk Data{ .definition = definition, .effect = effect };
            };
            return @ptrCast(&data);
        }

        fn install(self: *const StaticBuiltin, builder: *BuildingEnv) error{OutOfMemory}!void {
            const data: *const Data = @ptrCast(@alignCast(self));
            const definition = data.definition;
            const install_name = intern.internReservedNamespace(definition.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => unreachable,
            };
            const core = &builder.target.privateState().core;
            const document_value = try machine.stringValue(core.allocator, core.releases, definition.doc);
            defer core.releases.releaseValue(document_value);
            const builtin_effect: ?BuiltinEffect = if (data.effect) |*effect|
                try effect.build(builder, effect)
            else
                null;
            defer if (builtin_effect) |effect| core.releases.releaseValue(effect.value);
            try builder.target.installCoreSpec(install_name, .{
                .binding = .{ .builtin = definition.primitive },
                .effect = if (builtin_effect) |effect| effect.validated else null,
                .doc = documentation(document_value.list).?,
            });
        }
    };

    fn builtinEffect(
        self: *BuildingEnv,
        comptime token_count: usize,
        effect: *const StaticBuiltin.EffectData,
    ) error{OutOfMemory}!BuiltinEffect {
        const core = &self.target.privateState().core;
        var tokens: [token_count]value.Value = undefined;
        for (effect.tokens, &tokens) |token, *destination| {
            const id = try intern.intern(token);
            destination.* = .{ .word = .{ .name = id } };
        }
        const effect_value = try list.fromValuesGeneric(core.allocator, &tokens);
        return .{
            .value = effect_value,
            .validated = .fromValidated(effect_value.list, effect.separator),
        };
    }

    pub fn installCore(
        self: *BuildingEnv,
        name: intern.NamespaceName,
        body: *Quotation,
    ) error{OutOfMemory}!void {
        try self.target.installCoreSpec(name, .{
            .binding = .{ .word = body },
        });
    }
    pub fn installBuiltin(self: *BuildingEnv, comptime definition: BuiltinWord) error{OutOfMemory}!void {
        return StaticBuiltin.init(definition).install(self);
    }
    pub fn installBuiltins(self: *BuildingEnv, comptime definitions: []const BuiltinWord) error{OutOfMemory}!void {
        const descriptors = comptime blk: {
            @setEvalBranchQuota(100_000);
            var result: [definitions.len]*const StaticBuiltin = undefined;
            for (definitions, 0..) |definition, index| {
                for (definitions[0..index]) |prior| {
                    if (std.mem.eql(u8, prior.name, definition.name)) {
                        @compileError("duplicate builtin namespace name: " ++ definition.name);
                    }
                }
                result[index] = StaticBuiltin.init(definition);
            }
            break :blk result;
        };
        for (descriptors) |descriptor| {
            try descriptor.install(self);
        }
    }
    pub fn runtime(self: *BuildingEnv) *Env {
        return self.target;
    }
    pub fn rootScope(self: *BuildingEnv, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .{ .core_build = &self.target.privateState().core });
    }
    /// Recognizes the core's trusted definitions against their final bindings,
    /// then freezes the core. On failure the core is not frozen and the builder
    /// is not consumed, so the session that owns it does not start.
    pub fn finish(self: *BuildingEnv, recognizer: ?FreezeRecognizer) error{OutOfMemory}!void {
        const core = &self.target.privateState().core;
        const core_scope = @backingInt(self.target.coreScopeId());
        if (recognizer) |selected| try core.recognizeDirect(.{
            .own = core,
            .core = null,
            .own_scope = core_scope,
            .core_scope = core_scope,
            .slots = &self.target.privateState().slot_index,
        }, selected);
        core.freeze();
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
        // Names nothing: this assertion concerns only issued ids.
        const cell = try container.newScopeCell(null, null);
        const raw = @backingInt(cell.id);
        try std.testing.expect(raw != 0);
        try std.testing.expect(raw <= ScopeIndex.max_id);
        try std.testing.expectEqual(@as(u32, 0), raw >> id_bits);
        // Monotonic and never reused, which is the property the reserved byte
        // exists to let us relax later.
        try std.testing.expect(raw > previous);
        previous = raw;
    }
}

test "env: a slot keeps one cell per name across binding, removal, and rebinding" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var container = try Env.init(&host);
    defer container.deinit();
    const backing = container.privateState();
    const list_api = @import("list.zig");

    const one = try list_api.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 1 }});
    defer releases.releaseValue(one);
    const two = try list_api.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 2 }});
    defer releases.releaseValue(two);
    const core_body = try list_api.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 3 }});
    defer releases.releaseValue(core_body);

    const root = try container.newScopeCell(null, null);
    const late = try intern.internNamespace("slot-late");
    const early = try intern.internNamespace("slot-early");
    const shared = try intern.internNamespace("slot-shared");

    // Linked before any binding: unbound, with no core fallback.
    const early_id = try container.linkSlot(root, &backing.session, intern.namespaceId(early));
    const early_slot = container.slot(early_id).?;
    try std.testing.expect(early_slot.current() == null);
    try container.define(early, .{ .word = .{ .body = quotation(one.list).? } });
    const first_cell = early_slot.current().?;

    // Removal clears the slot without dropping its cell; rebinding reuses it.
    var unbind = backing.session.unbindCursor(early);
    defer unbind.deinit();
    try std.testing.expect(try poll.driveFallible(bool, &unbind, .{}));
    try std.testing.expect(early_slot.current() == null);
    try container.define(early, .{ .word = .{ .body = quotation(two.list).? } });
    try std.testing.expectEqual(first_cell, early_slot.current().?);
    var lease = first_cell.load();
    defer lease.deinit();
    try std.testing.expectEqual(@as(i64, 2), list_api.atUnchecked(.{ .list = quotationHeader(lease.spec().binding.word) }, 0).int);

    // Linked after a binding: adopts the environment's cell.
    try container.define(late, .{ .word = .{ .body = quotation(one.list).? } });
    const late_slot = container.slot(try container.linkSlot(root, &backing.session, intern.namespaceId(late))).?;
    try std.testing.expect(late_slot.current() != null);
    try std.testing.expectEqual(late_slot.id.load(.monotonic), @backingInt(try container.linkSlot(root, &backing.session, intern.namespaceId(late))));

    // Core is the fallback until the root shadows the name, and again after.
    _ = try backing.core.bind(shared, BindingSpec.fromTop(.{ .word = .{ .body = quotation(core_body.list).? } }));
    const shared_slot = container.slot(try container.linkSlot(root, &backing.session, intern.namespaceId(shared))).?;
    const core_cell = shared_slot.current().?;
    try container.define(shared, .{ .word = .{ .body = quotation(one.list).? } });
    try std.testing.expect(shared_slot.current().? != core_cell);
    var remove_shadow = backing.session.unbindCursor(shared);
    defer remove_shadow.deinit();
    _ = try poll.driveFallible(bool, &remove_shadow, .{});
    try std.testing.expectEqual(core_cell, shared_slot.current().?);
}
