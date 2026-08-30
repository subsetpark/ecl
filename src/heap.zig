//! Heap allocation and precise atomic reference counting.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const ListHandle = value.ListHandle;
pub const DictHandle = value.DictHandle;
pub const TaskHandle = value.TaskHandle;
pub const ModuleHandle = value.ModuleHandle;
pub const UnitPlanHandle = value.UnitPlanHandle;
pub const HeapKind = value.HeapKind;
/// A read capability over one list's unboxed payload.
///
/// Acquiring it retains the owning root for the reader's whole lifetime, which
/// is the structural reason a typed loop can hold a slice across a suspension:
/// the list cannot be retired underneath it, and no caller correlates a raw
/// pointer, an allocator, and a release domain by hand. `slice` is bounded by
/// the header length, unlike the capacity-sliced payload accessors above.
pub fn LeafReader(comptime kind_value: HeapKind) type {
    requireLeafRepresentation(kind_value, "LeafReader");
    const Element = LeafElement(kind_value);
    return struct {
        const Self = @This();
        pub const Item = Element;

        /// The retained root. Null only after `release`, which is the one
        /// transition that consumes this capability's reference.
        root: ?*ListHandle,

        /// Retains `handle`; the caller keeps its own reference. The reader
        /// owns a second one until `release`, on every path including failure.
        pub fn acquire(handle: *ListHandle) Self {
            std.debug.assert(listKind(handle) == kind_value);
            incRef(handle);
            return .{ .root = handle };
        }

        pub fn slice(self: *const Self) []const Element {
            const root = self.root.?;
            const items = payloadItems(Element, mutableHeader(root));
            return items[0..@intCast(listLength(root))];
        }

        pub fn len(self: *const Self) usize {
            return @intCast(listLength(self.root.?));
        }

        /// Consumes the retained reference through the release domain, so
        /// reclamation stays bounded work outside any publication lock.
        pub fn release(self: *Self, releases: *ReleaseDomain) void {
            if (self.root) |root| releases.releaseHeader(root);
            self.root = null;
        }

        /// The `heap.Owned` disposal protocol, so a driver can hold a reader as
        /// an owned field and have cancellation retire it with everything else.
        pub fn retire(self: *Self, releases: *ReleaseDomain) void {
            self.release(releases);
        }
    };
}

/// A write capability over one freshly allocated typed output buffer.
///
/// It owns its allocation, exposes only bounded range writes, and publishes
/// through exactly one consuming `finish`. There is deliberately no
/// whole-slice accessor: a caller that must know a block's faults before
/// storing it cannot be handed the destination to scribble on, which is what
/// keeps the rescan evidence of an aliased input intact.
pub fn LeafWriter(comptime kind_value: HeapKind) type {
    requireLeafRepresentation(kind_value, "LeafWriter");
    const Element = LeafElement(kind_value);
    return struct {
        const Self = @This();
        pub const Item = Element;

        builder: ?ListBuilder(kind_value),
        length: usize,

        /// Allocates exactly `len_value` elements at full length: a typed
        /// producer knows its result size before it fills anything. On failure
        /// this capability owns nothing.
        pub fn init(allocator: std.mem.Allocator, len_value: usize) error{OutOfMemory}!Self {
            return .{
                .builder = try ListBuilder(kind_value).init(allocator, len_value, len_value),
                .length = len_value,
            };
        }

        pub fn len(self: *const Self) usize {
            return self.length;
        }

        /// Stores one bounded half-open range. Asserts containment rather than
        /// clamping: an out-of-range store is a loop bug, not an input error.
        pub fn writeRange(self: *Self, offset: usize, source: []const Element) void {
            std.debug.assert(offset + source.len <= self.length);
            if (source.len == 0) return;
            @memcpy(self.builder.?.items()[offset..][0..source.len], source);
        }

        /// The fill counterpart, for producers whose block is one repeated
        /// element and which therefore need no staging buffer at all.
        pub fn fillRange(self: *Self, offset: usize, count: usize, element: Element) void {
            std.debug.assert(offset + count <= self.length);
            if (count == 0) return;
            @memset(self.builder.?.items()[offset..][0..count], element);
        }

        /// The one publishing transition. Consumes the capability: the caller
        /// owns the returned value's only reference.
        pub fn finish(self: *Self) Value {
            var builder = self.builder.?;
            self.builder = null;
            return .{ .list = builder.finish() };
        }

        /// Abandonment. Consumes the capability and retires the partially
        /// written buffer through the release domain; nothing is published.
        pub fn retirePartial(self: *Self, releases: *ReleaseDomain) void {
            if (self.builder) |*builder| {
                var owned = builder.*;
                owned.retirePartial(releases);
            }
            self.builder = null;
        }

        /// The `heap.Owned` disposal protocol: abandoning is what an owner does
        /// with an unfinished writer.
        pub fn retire(self: *Self, releases: *ReleaseDomain) void {
            self.retirePartial(releases);
        }
    };
}

/// The unique-input reuse authority.
///
/// Claiming it proves the list is solely owned and that its stored elements
/// occupy the same bytes as the result's, so the result can take over the
/// buffer by retag instead of by allocation. The authority is consumed exactly
/// once — by `finish`, which republishes that same list as the result, or by
/// `abandon`, which leaves the input exactly as it was. Callers never see the
/// header: the claim is the only door to in-place reuse, and `writeRange`
/// stores nothing a caller has not already decided is fault-free.
pub fn UniqueLeafAdoption(comptime result_kind: HeapKind) type {
    requireLeafRepresentation(result_kind, "UniqueLeafAdoption");
    const Element = LeafElement(result_kind);
    return struct {
        const Self = @This();
        pub const Item = Element;

        claimed: ?*UniqueList,
        handle: *ListHandle,
        length: usize,

        /// Null when the list is shared, when its element width differs from
        /// the result's, or when it cannot hold `len_value` elements. A null
        /// claim retains nothing and leaves the caller's reference untouched.
        pub fn claim(handle: *ListHandle, len_value: usize) ?Self {
            const source_kind = listKind(handle);
            if (leafElementSize(source_kind) != leafElementSize(result_kind)) return null;
            if (source_kind == .generic_spine or result_kind == .generic_spine) return null;
            if (capacity(handle) < len_value) return null;
            const unique = claimUniqueList(handle) orelse return null;
            return .{ .claimed = unique, .handle = handle, .length = len_value };
        }

        pub fn len(self: *const Self) usize {
            return self.length;
        }

        /// The reused buffer read as its original representation, bounded by the
        /// claimed length. Reads stay const and stores stay ranged, which is
        /// what makes reuse safe: an element is read in its own block, before
        /// that block's mask is known and therefore before anything is stored.
        pub fn sourceSlice(self: *const Self, comptime source_kind: HeapKind) []const LeafElement(source_kind) {
            std.debug.assert(leafElementSize(source_kind) == leafElementSize(result_kind));
            const items = payloadItems(LeafElement(source_kind), mutableHeader(self.handle));
            return items[0..self.length];
        }

        pub fn writeRange(self: *Self, offset: usize, source: []const Element) void {
            std.debug.assert(self.claimed != null);
            std.debug.assert(offset + source.len <= self.length);
            if (source.len == 0) return;
            const items = payloadItems(Element, mutableHeader(self.handle));
            @memcpy(items[offset..][0..source.len], source);
        }

        /// Consumes the authority and republishes the claimed list under the
        /// result representation. The caller's existing reference becomes the
        /// result's reference: it must not also release the input.
        pub fn finish(self: *Self) Value {
            const claimed = self.claimed.?;
            self.claimed = null;
            setUniqueListKind(claimed, result_kind);
            setUniqueListLength(claimed, self.length);
            return .{ .list = self.handle };
        }

        /// Consumes the authority without publishing. The input keeps its
        /// representation, its length, and the caller's reference.
        pub fn abandon(self: *Self) void {
            self.claimed = null;
        }

        /// The `heap.Owned` disposal protocol. Abandoning consumes the authority
        /// and touches neither the input nor any reference.
        pub fn retire(self: *Self, releases: *ReleaseDomain) void {
            _ = releases;
            self.abandon();
        }
    };
}

/// Retag a solely-owned list. Legal only between representations whose
/// elements occupy the same bytes, because the payload allocation is freed
/// against the element type the kind names.
fn setUniqueListKind(list_header: *UniqueList, kind_value: HeapKind) void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
    std.debug.assert(leafElementSize(uniqueImpl(header).kind()) == leafElementSize(kind_value));
    uniqueImpl(header).setKind(kind_value);
}

test "leaf capabilities keep roots alive publish once and reuse only unique buffers" {
    const allocator = std.testing.allocator;
    var cleanup = testing.Cleanup.init(allocator);
    defer cleanup.deinit();

    // A reader outliving its caller's reference is the whole point of the
    // capability: the root stays retained until the reader releases it.
    var source = try ListBuilder(.leaf_i64).init(allocator, 3, 3);
    @memcpy(source.items(), &[_]i64{ 7, 8, 9 });
    const numbers = source.finish();
    var reader = LeafReader(.leaf_i64).acquire(numbers);
    cleanup.domain().releaseHeader(numbers);
    try std.testing.expectEqual(@as(usize, 3), reader.len());
    try std.testing.expectEqualSlices(i64, &.{ 7, 8, 9 }, reader.slice());
    reader.release(cleanup.domain());

    // The writer publishes through finish and only through finish.
    var writer = try LeafWriter(.leaf_f64).init(allocator, 4);
    writer.writeRange(0, &.{ 1.5, 2.5 });
    writer.fillRange(2, 2, -0.5);
    const published = writer.finish();
    defer cleanup.releaseValue(published);
    try std.testing.expectEqual(HeapKind.leaf_f64, listKind(published.list));
    try std.testing.expectEqual(@as(u64, 4), listLength(published.list));
    var published_reader = LeafReader(.leaf_f64).acquire(published.list);
    defer published_reader.release(cleanup.domain());
    try std.testing.expectEqualSlices(f64, &.{ 1.5, 2.5, -0.5, -0.5 }, published_reader.slice());

    // An abandoned writer publishes nothing and leaks nothing.
    var abandoned = try LeafWriter(.leaf_i64).init(allocator, 2);
    abandoned.writeRange(0, &.{1});
    abandoned.retirePartial(cleanup.domain());

    // Reuse: same-width claims succeed on a solely-owned list, and the retag
    // republishes that same list rather than allocating a second one.
    var reusable = try ListBuilder(.leaf_i64).init(allocator, 2, 2);
    @memcpy(reusable.items(), &[_]i64{ 4, 5 });
    const reused_input = reusable.finish();
    var adoption = UniqueLeafAdoption(.leaf_f64).claim(reused_input, 2).?;
    try std.testing.expectEqualSlices(i64, &.{ 4, 5 }, adoption.sourceSlice(.leaf_i64));
    adoption.writeRange(0, &.{ 4.25, 5.25 });
    const reused = adoption.finish();
    defer cleanup.releaseValue(reused);
    try std.testing.expectEqual(reused_input, reused.list);
    try std.testing.expectEqual(HeapKind.leaf_f64, listKind(reused.list));
    var reused_reader = LeafReader(.leaf_f64).acquire(reused.list);
    defer reused_reader.release(cleanup.domain());
    try std.testing.expectEqualSlices(f64, &.{ 4.25, 5.25 }, reused_reader.slice());

    // A shared list refuses the claim, and so does a width change.
    var shared_builder = try ListBuilder(.leaf_i64).init(allocator, 1, 1);
    @memcpy(shared_builder.items(), &[_]i64{6});
    const shared = shared_builder.finish();
    defer cleanup.domain().releaseHeader(shared);
    incRef(shared);
    defer cleanup.domain().releaseHeader(shared);
    try std.testing.expect(UniqueLeafAdoption(.leaf_f64).claim(shared, 1) == null);
    var narrow_builder = try ListBuilder(.leaf_char1).init(allocator, 1, 1);
    narrow_builder.items()[0] = 'a';
    const narrow = narrow_builder.finish();
    defer cleanup.domain().releaseHeader(narrow);
    try std.testing.expect(UniqueLeafAdoption(.leaf_i64).claim(narrow, 1) == null);

    // An abandoned claim leaves the input exactly as it was.
    var keeper_builder = try ListBuilder(.leaf_i64).init(allocator, 1, 1);
    keeper_builder.items()[0] = 11;
    const keeper = keeper_builder.finish();
    defer cleanup.domain().releaseHeader(keeper);
    var keeper_claim = UniqueLeafAdoption(.leaf_f64).claim(keeper, 1).?;
    keeper_claim.abandon();
    try std.testing.expectEqual(HeapKind.leaf_i64, listKind(keeper));
}

fn leafCapabilityFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var writer = try LeafWriter(.leaf_i64).init(allocator, 3);
    errdefer writer.retirePartial(cleanup.domain());
    writer.writeRange(0, &.{ 1, 2, 3 });
    const published = writer.finish();
    defer cleanup.releaseValue(published);
    var reader = LeafReader(.leaf_i64).acquire(published.list);
    defer reader.release(cleanup.domain());
    try std.testing.expectEqual(@as(usize, 3), reader.slice().len);
    var adoption = UniqueLeafAdoption(.leaf_f64).claim(published.list, 3) orelse return;
    adoption.abandon();
}

test "leaf capabilities exhaust allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        leafCapabilityFailureProbe,
        .{},
    );
}

/// A stand-in for the semantic module image. The heap only ever calls
/// `releaseImage`, so the probe can prove the ownership contract without
/// importing the module layer and creating a cycle.
const ProbeImage = struct {
    releases: usize = 0,

    fn releaseImage(self: *ProbeImage) void {
        self.releases += 1;
    }
};

/// Ownership on both exits: a failed `createModule` publishes nothing and the
/// caller still owns its image reference, while a published value releases the
/// image exactly once when its last reference drops.
fn moduleCapabilityFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var image: ProbeImage = .{};
    const item = try createModule(ProbeImage, allocator, &image);
    try std.testing.expectEqual(HeapKind.module, kind(item.heapHeader().?));
    retainValue(item);
    cleanup.releaseValue(item);
    cleanup.capability().drain();
    try std.testing.expectEqual(@as(usize, 0), image.releases);
    cleanup.releaseValue(item);
    cleanup.capability().drain();
    try std.testing.expectEqual(@as(usize, 1), image.releases);
}

test "module capability exhausts allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        moduleCapabilityFailureProbe,
        .{},
    );
}

/// Ownership on both exits: a failed `createUnitPlan` publishes nothing and
/// the caller still owns both lists, while a published plan releases each of
/// them exactly once when its last reference drops. The two slots stay
/// distinct, and both are the exact lists handed in rather than copies.
fn unitPlanCapabilityFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var seed_writer = try LeafWriter(.leaf_i64).init(allocator, 1);
    errdefer seed_writer.retirePartial(cleanup.domain());
    seed_writer.writeRange(0, &.{7});
    var seeds = OwnedValue.init(cleanup.domain(), seed_writer.finish());
    errdefer seeds.deinit();
    var body_writer = try LeafWriter(.leaf_i64).init(allocator, 1);
    errdefer body_writer.retirePartial(cleanup.domain());
    body_writer.writeRange(0, &.{9});
    var body = OwnedValue.init(cleanup.domain(), body_writer.finish());
    errdefer body.deinit();

    const plan = try createUnitPlan(allocator, seeds.borrow().list, body.borrow().list);
    try std.testing.expectEqual(HeapKind.unit_plan, kind(plan.heapHeader().?));
    try std.testing.expectEqual(seeds.borrow().list, unitPlanSeeds(plan.unit_plan));
    try std.testing.expectEqual(body.borrow().list, unitPlanBody(plan.unit_plan));
    _ = seeds.take();
    _ = body.take();
    cleanup.releaseValue(plan);
    cleanup.capability().drain();
}

test "unit plan capability exhausts allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        unitPlanCapabilityFailureProbe,
        .{},
    );
}

pub const DictPayload = value.DictPayload;

/// Capabilities are nominal opaque pointers with the same address as Header.
/// Only this module can issue them without an explicit unsafe cast.
const InitializingList = opaque {};
const InitializingDict = opaque {};
const InitializingTask = opaque {};
const InitializingModule = opaque {};
const InitializingUnitPlan = opaque {};
const UniqueHeader = opaque {};
pub const UniqueList = opaque {};
pub const UniqueDict = opaque {};

/// Makes copy-on-write ownership visible to callers. `in_place` aliases the
/// caller's existing owner; `replacement` is one additional owned root.
pub const UpdateResult = union(enum) {
    in_place: Value,
    replacement: Value,

    pub fn value(self: UpdateResult) Value {
        return switch (self) {
            inline else => |item| item,
        };
    }
};

const HeaderImpl = extern struct {
    rc: std.atomic.Value(u32),
    meta: u32,
    len: u64,

    const kind_mask: u32 = 0xff;
    const identity_shift = 8;
    const identity_max = std.math.maxInt(u24);

    fn init(kind_value: HeapKind, len_value: u64) HeaderImpl {
        return .{
            .rc = .init(1),
            .meta = @intFromEnum(kind_value),
            .len = len_value,
        };
    }

    fn kind(self: *const HeaderImpl) HeapKind {
        return @enumFromInt(self.meta & kind_mask);
    }

    fn setKind(self: *HeaderImpl, new_kind: HeapKind) void {
        self.meta = (self.meta & ~kind_mask) | @intFromEnum(new_kind);
    }

    fn identity(self: *const HeaderImpl) ?CodeIdentity {
        const raw = self.meta >> identity_shift;
        return if (raw == 0) null else @enumFromInt(raw);
    }

    fn assignIdentity(self: *HeaderImpl, assigned: CodeIdentity) void {
        std.debug.assert(self.identity() == null);
        const raw = @intFromEnum(assigned);
        std.debug.assert(raw != 0 and raw <= identity_max);
        self.meta |= raw << identity_shift;
    }
};

comptime {
    if (@sizeOf(HeaderImpl) != 16) @compileError("heap header must remain exactly 16 bytes");
}

pub const DictStorage = union(enum) {
    initializing,
    ready: struct {
        payload: DictPayload,
        index: ?[]u32 = null,
    },

    pub fn payload(self: *const DictStorage) *const DictPayload {
        return switch (self.*) {
            .initializing => unreachable,
            .ready => |*ready| &ready.payload,
        };
    }

    pub fn index(self: *const DictStorage) ?[]const u32 {
        return switch (self.*) {
            .initializing => unreachable,
            .ready => |ready| ready.index,
        };
    }
};

pub const TaskStorage = struct {
    identity: u64,
    payload: *anyopaque,
    destroy: *const fn (std.mem.Allocator, *anyopaque) ?Value,
};

/// A module value owns exactly one release of an opaque semantic payload.
/// The heap never learns what a module image is: it stores the payload and
/// the callback its factory derived, and the callback is what enters bounded
/// retirement in the layer that owns the image's graph.
pub const ModuleStorage = struct {
    payload: *anyopaque,
    release: *const fn (*anyopaque) void,
};

/// A unit plan owns one reference to its seed list and one to its construction
/// body, kept apart for the whole life of the plan. Private, and typed: both
/// slots are list handles, so a plan holding anything else is unrepresentable
/// rather than merely asserted against. `createUnitPlan` is the only producer,
/// `unitPlanSeeds` and `unitPlanBody` are the only readers, and both are
/// borrows.
const UnitPlanStorage = struct {
    seeds: *ListHandle,
    body: *ListHandle,
};

const Object = struct {
    header: HeaderImpl,
    capacity: usize,
    payload: ?*anyopaque,
    provenance_namespace: CodeProvenanceNamespace,
    next_destroy: ?*Header,
    destroy_index: usize,
};

fn object(header: *Header) *Object {
    return @fieldParentPtr("header", headerImpl(header));
}

fn objectConst(header: *const Header) *const Object {
    return @fieldParentPtr("header", headerImplConst(header));
}

fn headerImpl(header: *Header) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn headerImplConst(header: *const Header) *const HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn initializingImpl(header: anytype) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

fn initializingHeader(header: anytype) *Header {
    return @ptrCast(@alignCast(header));
}

fn uniqueImpl(header: *UniqueHeader) *HeaderImpl {
    return @ptrCast(@alignCast(header));
}

pub fn kind(header: *const Header) HeapKind {
    return headerImplConst(header).kind();
}

/// Session-local identity for one reader-built code value, stable for that
/// value's lifetime. It is a shared key rather than a private field of any one
/// consumer: `spans.SpanArchive` keys source spans on it, and `env`'s scope
/// labels key the scope a quotation's text was written in on it. Zero is
/// reserved for runtime-built and copy-on-write headers, so those remain
/// naturally absent from the source archive — and a quotation built at run
/// time by `partial`, `cons`, or `compose` has no identity, hence no span and
/// no label, hence resolves where it is invoked.
pub const CodeIdentity = enum(u32) { _ };
pub const max_code_identity: u32 = std.math.maxInt(u24);
pub const CodeProvenanceNamespace = enum(u64) { none = 0, _ };

const CodeIdentityIssuerState = struct {
    allocator: std.mem.Allocator,
    namespace: CodeProvenanceNamespace,
};
var next_code_provenance_namespace: std.atomic.Value(u64) = .init(1);

/// Archive-owned issuer for one provenance namespace. Construction receives
/// only its numeric namespace; assignment requires the still-opaque issuer.
pub const CodeIdentityIssuer = opaque {
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*CodeIdentityIssuer {
        var next = next_code_provenance_namespace.load(.monotonic);
        while (next != 0) {
            if (next_code_provenance_namespace.cmpxchgWeak(
                next,
                next +% 1,
                .monotonic,
                .monotonic,
            )) |observed| {
                next = observed;
            } else {
                const state = try allocator.create(CodeIdentityIssuerState);
                state.* = .{ .allocator = allocator, .namespace = @enumFromInt(next) };
                return @ptrCast(state);
            }
        }
        return error.OutOfMemory;
    }

    pub fn deinit(self: *CodeIdentityIssuer) void {
        const state = codeIdentityIssuerState(self);
        const allocator = state.allocator;
        allocator.destroy(state);
    }

    pub fn constructionNamespace(self: *const CodeIdentityIssuer) CodeProvenanceNamespace {
        return codeIdentityIssuerStateConst(self).namespace;
    }
};

fn codeIdentityIssuerState(issuer: *CodeIdentityIssuer) *CodeIdentityIssuerState {
    return @ptrCast(@alignCast(issuer));
}

fn codeIdentityIssuerStateConst(issuer: *const CodeIdentityIssuer) *const CodeIdentityIssuerState {
    return @ptrCast(@alignCast(issuer));
}

pub const CodeIdentityInspection = union(enum) {
    unassigned,
    assigned: CodeIdentity,
    foreign_namespace,
};

pub fn inspectCodeIdentity(
    issuer: *const CodeIdentityIssuer,
    handle: *ListHandle,
) CodeIdentityInspection {
    const header = headerFromList(handle);
    if (objectConst(header).provenance_namespace != issuer.constructionNamespace())
        return .foreign_namespace;
    return if (headerImplConst(header).identity()) |identity|
        .{ .assigned = identity }
    else
        .unassigned;
}

pub fn codeIdentity(
    issuer: *const CodeIdentityIssuer,
    handle: *ListHandle,
) ?CodeIdentity {
    return switch (inspectCodeIdentity(issuer, handle)) {
        .assigned => |identity| identity,
        .unassigned, .foreign_namespace => null,
    };
}

pub const CodeIdentityAssignment = enum {
    assigned,
    already_assigned,
    foreign_namespace,
    invalid_identity,
};

pub fn assignCodeIdentity(
    issuer: *const CodeIdentityIssuer,
    handle: *ListHandle,
    identity: CodeIdentity,
) CodeIdentityAssignment {
    const raw_identity = @intFromEnum(identity);
    if (raw_identity == 0 or raw_identity > max_code_identity)
        return .invalid_identity;
    const header = headerFromList(handle);
    if (objectConst(header).provenance_namespace != issuer.constructionNamespace())
        return .foreign_namespace;
    const implementation = headerImpl(header);
    if (implementation.identity() != null) return .already_assigned;
    implementation.assignIdentity(identity);
    return .assigned;
}

pub fn headerFromList(handle: *ListHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

pub fn headerFromDict(handle: *DictHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

pub fn headerFromTask(handle: *TaskHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

pub fn headerFromModule(handle: *ModuleHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

pub fn headerFromUnitPlan(handle: *UnitPlanHandle) *Header {
    return @ptrCast(@alignCast(handle));
}

fn mutableHeader(handle: anytype) *Header {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn listKind(handle: *ListHandle) HeapKind {
    const result = kind(headerFromList(handle));
    std.debug.assert(switch (result) {
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => true,
        .dict, .task, .module, .unit_plan, .reserved_mask => false,
    });
    return result;
}

pub fn listLength(handle: *ListHandle) u64 {
    return length(headerFromList(handle));
}

pub fn dictLength(handle: *DictHandle) u64 {
    return length(headerFromDict(handle));
}

pub fn length(header: *const Header) u64 {
    return headerImplConst(header).len;
}

pub fn refCount(handle: anytype) u32 {
    return headerImplConst(@ptrCast(@alignCast(handle))).rc.load(.acquire);
}

fn publishList(header: *InitializingList) *ListHandle {
    return @ptrCast(@alignCast(header));
}

fn publishDict(header: *InitializingDict) *DictHandle {
    return @ptrCast(@alignCast(header));
}

fn publishTask(header: *InitializingTask) *TaskHandle {
    return @ptrCast(@alignCast(header));
}

fn publishModule(header: *InitializingModule) *ModuleHandle {
    return @ptrCast(@alignCast(header));
}

fn publishUnitPlan(header: *InitializingUnitPlan) *UnitPlanHandle {
    return @ptrCast(@alignCast(header));
}

fn initializingLength(header: *const InitializingList) u64 {
    const impl: *const HeaderImpl = @ptrCast(@alignCast(header));
    return impl.len;
}

fn setInitializingLength(header: *InitializingList, new_len: usize) void {
    std.debug.assert(new_len <= object(initializingHeader(header)).capacity);
    initializingImpl(header).len = new_len;
}

fn claimUniqueHeader(header: *Header) ?*UniqueHeader {
    if (headerImpl(header).rc.load(.acquire) != 1) return null;
    return @ptrCast(@alignCast(header));
}

pub fn claimUniqueList(handle: *ListHandle) ?*UniqueList {
    const unique = claimUniqueHeader(mutableHeader(handle)) orelse return null;
    return @ptrCast(@alignCast(unique));
}

pub fn claimUniqueDict(handle: *DictHandle) ?*UniqueDict {
    const unique = claimUniqueHeader(mutableHeader(handle)) orelse return null;
    return @ptrCast(@alignCast(unique));
}

pub fn uniqueHeader(header: *UniqueHeader) *Header {
    return @ptrCast(@alignCast(header));
}

pub fn capacity(handle: anytype) usize {
    const header: *const Header = @ptrCast(@alignCast(handle));
    return objectConst(header).capacity;
}

fn allocObject(
    allocator: std.mem.Allocator,
    kind_value: HeapKind,
    len_value: usize,
    capacity_value: usize,
) error{OutOfMemory}!*Header {
    std.debug.assert(len_value <= capacity_value or kind_value == .dict);
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    obj.* = .{
        .header = HeaderImpl.init(kind_value, len_value),
        .capacity = capacity_value,
        .payload = null,
        .provenance_namespace = .none,
        .next_destroy = null,
        .destroy_index = 0,
    };
    obj.payload = switch (kind_value) {
        .generic_spine => try allocPayload(Value, allocator, capacity_value),
        .leaf_u8 => try allocPayload(u8, allocator, capacity_value),
        .leaf_i64 => try allocPayload(i64, allocator, capacity_value),
        .leaf_f64 => try allocPayload(f64, allocator, capacity_value),
        .leaf_char1 => try allocPayload(u8, allocator, capacity_value),
        .leaf_char2 => try allocPayload(u16, allocator, capacity_value),
        .leaf_char4 => try allocPayload(u32, allocator, capacity_value),
        .leaf_symbol => try allocPayload(u32, allocator, capacity_value),
        .dict => @ptrCast(try allocator.create(DictStorage)),
        .task, .module, .unit_plan => unreachable,
        .reserved_mask => null,
    };
    return @ptrCast(@alignCast(&obj.header));
}

fn allocListHeader(
    allocator: std.mem.Allocator,
    kind_value: HeapKind,
    len_value: usize,
    capacity_value: usize,
    provenance_namespace: CodeProvenanceNamespace,
) error{OutOfMemory}!*InitializingList {
    std.debug.assert(switch (kind_value) {
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => true,
        .dict, .task, .module, .unit_plan, .reserved_mask => false,
    });
    const header = try allocObject(allocator, kind_value, len_value, capacity_value);
    object(header).provenance_namespace = provenance_namespace;
    return @ptrCast(@alignCast(header));
}

/// The unboxed element each list representation stores. One mapping serves the
/// builder, the typed read capability, and the typed write capabilities, so a
/// representation cannot acquire a second element type by being reached through
/// a different door.
pub fn LeafElement(comptime kind_value: HeapKind) type {
    return switch (kind_value) {
        .generic_spine => Value,
        .leaf_u8 => u8,
        .leaf_i64 => i64,
        .leaf_f64 => f64,
        .leaf_char1 => u8,
        .leaf_char2 => u16,
        .leaf_char4, .leaf_symbol => u32,
        .dict, .task, .module, .unit_plan, .reserved_mask => @compileError("a list representation is required"),
    };
}

/// Two representations are reuse-compatible when their elements occupy the same
/// bytes: `leaf_u8`/`leaf_char1`, `leaf_i64`/`leaf_f64`, and
/// `leaf_char4`/`leaf_symbol` are the compatible pairs. That is exactly when a
/// unique input buffer can carry a result of the other kind by retag rather
/// than by reallocation.
pub fn leafElementSize(kind_value: HeapKind) usize {
    return switch (kind_value) {
        .generic_spine => @sizeOf(Value),
        .leaf_u8 => @sizeOf(u8),
        .leaf_i64 => @sizeOf(i64),
        .leaf_f64 => @sizeOf(f64),
        .leaf_char1 => @sizeOf(u8),
        .leaf_char2 => @sizeOf(u16),
        .leaf_char4, .leaf_symbol => @sizeOf(u32),
        .dict, .task, .module, .unit_plan, .reserved_mask => 0,
    };
}

fn requireLeafRepresentation(comptime kind_value: HeapKind, comptime capability: []const u8) void {
    if (kind_value == .generic_spine) @compileError(
        capability ++ " is a typed leaf capability; a generic spine holds boxed cells and " ++
            "must go through ListBuilder, which owns the retain discipline those cells need",
    );
}

pub fn ListBuilder(comptime kind_value: HeapKind) type {
    const Element = LeafElement(kind_value);
    return struct {
        const Self = @This();
        pub const Item = Element;

        header: ?*InitializingList,

        pub fn init(
            allocator: std.mem.Allocator,
            len_value: usize,
            capacity_value: usize,
        ) error{OutOfMemory}!Self {
            return initCode(allocator, len_value, capacity_value, .none);
        }

        pub fn initCode(
            allocator: std.mem.Allocator,
            len_value: usize,
            capacity_value: usize,
            provenance_namespace: CodeProvenanceNamespace,
        ) error{OutOfMemory}!Self {
            return .{ .header = try allocListHeader(
                allocator,
                kind_value,
                len_value,
                capacity_value,
                provenance_namespace,
            ) };
        }

        pub fn items(self: *const Self) []Element {
            return payloadItems(Element, initializingHeader(self.header.?));
        }

        pub fn len(self: *const Self) usize {
            return @intCast(initializingLength(self.header.?));
        }

        pub fn capacity(self: *const Self) usize {
            return object(initializingHeader(self.header.?)).capacity;
        }

        pub fn setLen(self: *Self, new_len: usize) void {
            setInitializingLength(self.header.?, new_len);
        }

        pub fn finish(self: *Self) *ListHandle {
            const header = self.header.?;
            self.header = null;
            return publishList(header);
        }

        pub fn retirePartial(self: *Self, releases: *ReleaseDomain) void {
            if (self.header) |header| releases.releaseHeader(publishList(header));
            self.header = null;
        }

        pub fn retire(self: *Self, releases: *ReleaseDomain) void {
            self.retirePartial(releases);
        }
    };
}

/// Runtime-selected list construction is still a closed sum of typed
/// builders. Each variant exposes only the element operations valid for that
/// representation; no caller receives a raw initializing header.
pub const AnyListBuilder = union(enum) {
    generic: ListBuilder(.generic_spine),
    u8: ListBuilder(.leaf_u8),
    i64: ListBuilder(.leaf_i64),
    f64: ListBuilder(.leaf_f64),
    char1: ListBuilder(.leaf_char1),
    char2: ListBuilder(.leaf_char2),
    char4: ListBuilder(.leaf_char4),
    symbol: ListBuilder(.leaf_symbol),

    pub fn init(
        allocator: std.mem.Allocator,
        kind_value: HeapKind,
        len_value: usize,
        capacity_value: usize,
    ) error{OutOfMemory}!AnyListBuilder {
        return initCode(allocator, kind_value, len_value, capacity_value, .none);
    }

    pub fn initCode(
        allocator: std.mem.Allocator,
        kind_value: HeapKind,
        len_value: usize,
        capacity_value: usize,
        provenance_namespace: CodeProvenanceNamespace,
    ) error{OutOfMemory}!AnyListBuilder {
        return switch (kind_value) {
            .generic_spine => .{ .generic = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_u8 => .{ .u8 = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_i64 => .{ .i64 = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_f64 => .{ .f64 = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_char1 => .{ .char1 = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_char2 => .{ .char2 = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_char4 => .{ .char4 = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .leaf_symbol => .{ .symbol = try .initCode(allocator, len_value, capacity_value, provenance_namespace) },
            .dict, .task, .module, .unit_plan, .reserved_mask => unreachable,
        };
    }

    pub fn finish(self: *AnyListBuilder) *ListHandle {
        return switch (self.*) {
            inline else => |*builder| builder.finish(),
        };
    }

    pub fn retirePartial(self: *AnyListBuilder, releases: *ReleaseDomain) void {
        switch (self.*) {
            inline else => |*builder| builder.retirePartial(releases),
        }
    }

    pub fn writeCodepoint(self: *AnyListBuilder, index: usize, codepoint: u32) void {
        switch (self.*) {
            .char1 => |*builder| builder.items()[index] = @intCast(codepoint),
            .char2 => |*builder| builder.items()[index] = @intCast(codepoint),
            .char4 => |*builder| builder.items()[index] = codepoint,
            else => unreachable,
        }
    }

    pub fn writeValue(self: *AnyListBuilder, index: usize, item: Value) void {
        switch (self.*) {
            .generic => |*builder| {
                retainValue(item);
                builder.items()[index] = item;
                builder.setLen(index + 1);
            },
            .u8 => |*builder| builder.items()[index] = @intCast(item.int),
            .i64 => |*builder| builder.items()[index] = item.int,
            .f64 => |*builder| builder.items()[index] = item.float,
            .char1 => |*builder| builder.items()[index] = @intCast(item.char),
            .char2 => |*builder| builder.items()[index] = @intCast(item.char),
            .char4 => |*builder| builder.items()[index] = item.char,
            .symbol => |*builder| builder.items()[index] = item.symbol,
        }
    }
};

fn allocDictHeader(
    allocator: std.mem.Allocator,
    len_value: usize,
) error{OutOfMemory}!*InitializingDict {
    const object_header = try allocObject(allocator, .dict, len_value, len_value);
    const initializing: *InitializingDict = @ptrCast(@alignCast(object_header));
    initDictStorage(initializing).* = .initializing;
    return initializing;
}

/// Representation-specific construction capability for dictionary storage.
/// Only `finish` can expose a DictHandle, and it requires the complete payload
/// and optional index in one transition.
pub const DictBuilder = struct {
    header: ?*InitializingDict,

    pub fn init(allocator: std.mem.Allocator, len_value: usize) error{OutOfMemory}!DictBuilder {
        return .{ .header = try allocDictHeader(allocator, len_value) };
    }

    pub fn finish(self: *DictBuilder, payload: DictPayload, index: ?[]u32) *DictHandle {
        const header = self.header.?;
        initDictStorage(header).* = .{ .ready = .{ .payload = payload, .index = index } };
        self.header = null;
        return publishDict(header);
    }

    pub fn retirePartial(self: *DictBuilder, releases: *ReleaseDomain) void {
        if (self.header) |header| releases.releaseHeader(publishDict(header));
        self.header = null;
    }

    pub fn retire(self: *DictBuilder, releases: *ReleaseDomain) void {
        self.retirePartial(releases);
    }
};

fn allocTaskHeader(
    allocator: std.mem.Allocator,
    identity: u64,
    payload: *anyopaque,
    destroy: *const fn (std.mem.Allocator, *anyopaque) ?Value,
) error{OutOfMemory}!*InitializingTask {
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    const storage = try allocator.create(TaskStorage);
    storage.* = .{ .identity = identity, .payload = payload, .destroy = destroy };
    obj.* = .{
        .header = HeaderImpl.init(.task, identity),
        .capacity = 0,
        .payload = @ptrCast(storage),
        .provenance_namespace = .none,
        .next_destroy = null,
        .destroy_index = 0,
    };
    return @ptrCast(@alignCast(&obj.header));
}

fn TaskDestroyAdapter(comptime Payload: type) type {
    return struct {
        fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) ?Value {
            const payload: *Payload = @ptrCast(@alignCast(raw));
            return Payload.destroy(allocator, payload);
        }
    };
}

/// Allocates and publishes task storage with a destructor derived from the
/// concrete payload type. Raw payload casts cannot be paired at call sites.
pub fn createTask(
    comptime Payload: type,
    allocator: std.mem.Allocator,
    identity: u64,
    payload: *Payload,
) error{OutOfMemory}!*TaskHandle {
    const initializing = try allocTaskHeader(
        allocator,
        identity,
        @ptrCast(payload),
        TaskDestroyAdapter(Payload).destroy,
    );
    return publishTask(initializing);
}

pub fn taskStorage(header: *const TaskHandle) *const TaskStorage {
    return @ptrCast(@alignCast(objectConst(headerFromTask(@constCast(header))).payload.?));
}

fn allocModuleHeader(
    allocator: std.mem.Allocator,
    payload: *anyopaque,
    release: *const fn (*anyopaque) void,
) error{OutOfMemory}!*InitializingModule {
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    const storage = try allocator.create(ModuleStorage);
    storage.* = .{ .payload = payload, .release = release };
    obj.* = .{
        .header = HeaderImpl.init(.module, 0),
        .capacity = 0,
        .payload = @ptrCast(storage),
        .provenance_namespace = .none,
        .next_destroy = null,
        .destroy_index = 0,
    };
    return @ptrCast(@alignCast(&obj.header));
}

fn ModuleReleaseAdapter(comptime Payload: type) type {
    return struct {
        fn release(raw: *anyopaque) void {
            const payload: *Payload = @ptrCast(@alignCast(raw));
            Payload.releaseImage(payload);
        }
    };
}

/// Wraps one already-owned module image in a value. On success the value owns
/// the reference the caller handed over; on failure the caller still owns it,
/// because nothing was published. Final release calls `releaseImage`, which is
/// where the semantic layer enters its own bounded retirement.
pub fn createModule(
    comptime Payload: type,
    allocator: std.mem.Allocator,
    payload: *Payload,
) error{OutOfMemory}!Value {
    const initializing = try allocModuleHeader(
        allocator,
        @ptrCast(payload),
        ModuleReleaseAdapter(Payload).release,
    );
    return .{ .module = publishModule(initializing) };
}

pub fn moduleStorage(header: *const ModuleHandle) *const ModuleStorage {
    return @ptrCast(@alignCast(objectConst(headerFromModule(@constCast(header))).payload.?));
}

fn allocUnitPlanHeader(
    allocator: std.mem.Allocator,
    seeds: *ListHandle,
    body: *ListHandle,
) error{OutOfMemory}!*InitializingUnitPlan {
    const obj = try allocator.create(Object);
    errdefer allocator.destroy(obj);
    const storage = try allocator.create(UnitPlanStorage);
    storage.* = .{ .seeds = seeds, .body = body };
    obj.* = .{
        .header = HeaderImpl.init(.unit_plan, 0),
        .capacity = 0,
        .payload = @ptrCast(storage),
        .provenance_namespace = .none,
        .next_destroy = null,
        .destroy_index = 0,
    };
    return @ptrCast(@alignCast(&obj.header));
}

/// Seals two already-owned lists into one immutable plan. On success the plan
/// owns both references the caller handed over; on failure the caller still
/// owns both, because nothing was published. Neither list is inspected,
/// copied, or transformed: a plan is exactly the pair it was given.
///
/// The parameter types are the validation, and there is nothing correlated to
/// get wrong: a plan whose seeds are not a list, or whose body is not usable as
/// code, cannot be built here at all, so no consumer needs an assertion to
/// trust what it reads back out and there is nothing for an optimized build to
/// drop. The raw operation is private; the public `UnitPlanSeal` below derives
/// this allocator from its issuing host instead of accepting one from the
/// cross-module caller.
fn createUnitPlan(
    allocator: std.mem.Allocator,
    seeds: *ListHandle,
    body: *ListHandle,
) error{OutOfMemory}!Value {
    return .{ .unit_plan = publishUnitPlan(try allocUnitPlanHeader(allocator, seeds, body)) };
}

fn unitPlanStorage(header: *const UnitPlanHandle) *const UnitPlanStorage {
    return @ptrCast(@alignCast(objectConst(headerFromUnitPlan(@constCast(header))).payload.?));
}

/// The plan's seed list. A borrow: the plan owns the reference.
pub fn unitPlanSeeds(header: *const UnitPlanHandle) *ListHandle {
    return unitPlanStorage(header).seeds;
}

/// The plan's construction body. A borrow: the plan owns the reference.
pub fn unitPlanBody(header: *const UnitPlanHandle) *ListHandle {
    return unitPlanStorage(header).body;
}

fn allocPayload(
    comptime T: type,
    allocator: std.mem.Allocator,
    count: usize,
) error{OutOfMemory}!?*anyopaque {
    if (count == 0) return null;
    const buffer = try allocator.alloc(T, count);
    return @ptrCast(buffer.ptr);
}

fn payloadItems(comptime T: type, header: *Header) []T {
    const cap = capacity(header);
    if (cap == 0) return &.{};
    const ptr: [*]T = @ptrCast(@alignCast(object(header).payload.?));
    return ptr[0..cap];
}

pub fn valuesConst(header: *ListHandle) []const Value {
    std.debug.assert(listKind(header) == .generic_spine);
    return payloadItems(Value, mutableHeader(header));
}

pub fn i64s(header: *ListHandle) []const i64 {
    std.debug.assert(listKind(header) == .leaf_i64);
    return payloadItems(i64, mutableHeader(header));
}

pub fn u8s(header: *ListHandle) []const u8 {
    std.debug.assert(listKind(header) == .leaf_u8);
    return payloadItems(u8, mutableHeader(header));
}

pub fn f64s(header: *ListHandle) []const f64 {
    std.debug.assert(listKind(header) == .leaf_f64);
    return payloadItems(f64, mutableHeader(header));
}

pub fn chars8(header: *ListHandle) []const u8 {
    std.debug.assert(listKind(header) == .leaf_char1);
    return payloadItems(u8, mutableHeader(header));
}

pub fn chars16(header: *ListHandle) []const u16 {
    std.debug.assert(listKind(header) == .leaf_char2);
    return payloadItems(u16, mutableHeader(header));
}

pub fn chars32(header: *ListHandle) []const u32 {
    std.debug.assert(listKind(header) == .leaf_char4);
    return payloadItems(u32, mutableHeader(header));
}

pub fn symbols(header: *ListHandle) []const u32 {
    std.debug.assert(listKind(header) == .leaf_symbol);
    return payloadItems(u32, mutableHeader(header));
}

pub fn writeUniqueList(list_header: *UniqueList, index: usize, item: Value) void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
    const raw = uniqueHeader(header);
    std.debug.assert(index < capacity(raw));
    switch (uniqueImpl(header).kind()) {
        .generic_spine => payloadItems(Value, raw)[index] = item,
        .leaf_u8 => payloadItems(u8, raw)[index] = @intCast(item.int),
        .leaf_i64 => payloadItems(i64, raw)[index] = item.int,
        .leaf_f64 => payloadItems(f64, raw)[index] = item.float,
        .leaf_char1 => payloadItems(u8, raw)[index] = @intCast(item.char),
        .leaf_char2 => payloadItems(u16, raw)[index] = @intCast(item.char),
        .leaf_char4 => payloadItems(u32, raw)[index] = item.char,
        .leaf_symbol => payloadItems(u32, raw)[index] = item.symbol,
        .dict, .task, .module, .unit_plan, .reserved_mask => unreachable,
    }
}

pub fn setUniqueListLength(list_header: *UniqueList, new_len: usize) void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
    std.debug.assert(new_len <= capacity(uniqueHeader(header)));
    uniqueImpl(header).len = new_len;
}

fn initDictStorage(header: *InitializingDict) *DictStorage {
    return @ptrCast(@alignCast(object(initializingHeader(header)).payload.?));
}

pub fn dictStorageConst(header: *const DictHandle) *const DictStorage {
    return @ptrCast(@alignCast(objectConst(headerFromDict(@constCast(header))).payload.?));
}

pub fn incRef(handle: anytype) void {
    const old = headerImpl(mutableHeader(handle)).rc.fetchAdd(1, .monotonic);
    std.debug.assert(old != 0 and old != std.math.maxInt(u32));
}

pub fn retainValue(item: Value) void {
    switch (item) {
        .int, .float, .char, .symbol, .word => {},
        .list => |header| incRef(header),
        .dict => |header| incRef(header),
        .task => |header| incRef(header),
        .module => |header| incRef(header),
        .unit_plan => |header| incRef(header),
    }
}

/// Tests use the same explicit release authority as production owners.
pub const testing = if (builtin.is_test) struct {
    pub const Cleanup = struct {
        owner: HostOwner,

        pub fn init(allocator: std.mem.Allocator) Cleanup {
            return .{ .owner = HostOwner.init(allocator) };
        }

        pub fn domain(self: *Cleanup) *ReleaseDomain {
            return self.owner.domain();
        }

        pub fn capability(self: *const Cleanup) *const HostCleanup {
            return self.owner.cleanup();
        }

        pub fn releaseValue(self: *Cleanup, item: Value) void {
            self.domain().releaseValue(item);
        }

        pub fn deinit(self: *Cleanup) void {
            self.capability().drain();
        }
    };
} else struct {};

/// Opaque host ownership is issued by exactly one `HostOwner`. Root-owned
/// objects derive allocation and retirement from this capability; blocking
/// drain remains available only to host-side owners that retain it.
pub const HostCleanup = opaque {
    /// Drains only the reclamation domain that issued this capability.
    pub fn drain(self: *const HostCleanup) void {
        hostDomain(self).drainOwned();
    }

    pub fn allocator(self: *const HostCleanup) std.mem.Allocator {
        return hostDomain(self).allocator;
    }

    /// Runs the final parked-block walk. See
    /// `ReleaseDomain.reclaimTombstones` for why this is teardown-only and why
    /// the destructor comes from the caller.
    pub fn reclaimTombstones(
        self: *const HostCleanup,
        destroy: *const fn (std.mem.Allocator, *ReleaseDomain.TombstoneNode) void,
    ) void {
        hostDomain(self).reclaimTombstones(destroy);
    }
};

/// Root runtime owners store one opaque host capability and derive resources
/// from it. A cached allocator or domain would make cross-owner pairing a
/// writable struct state again.
pub fn requireSingleHostCapability(comptime Root: type) void {
    if (!@hasField(Root, "host") or @FieldType(Root, "host") != *const HostCleanup)
        @compileError(@typeName(Root) ++ " must store exactly its opaque HostCleanup capability");
    const root_info = @typeInfo(Root).@"struct";
    inline for (root_info.fields) |field| {
        if (field.type == std.mem.Allocator or field.type == *ReleaseDomain)
            @compileError(@typeName(Root) ++ " must derive allocator and domain from HostCleanup");
    }
}

pub fn requireOpaqueHostRoot(comptime Handle: type, comptime State: type) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized handle"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized handle");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "consumed") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its consumed state");
    }
    requireSingleHostCapability(State);
}

/// A host-side opaque owner whose private state retains the one `HostOwner`
/// needed for construction-time registration and final teardown. Unlike a
/// worker facade, this handle may expose lifecycle operations; the owner
/// pointer never crosses through a cleanup capability.
pub fn requireOpaqueHostOwnerRoot(comptime Handle: type, comptime State: type) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized host owner"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized host owner");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "consumed") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its consumed state");
    }
    requireSingleHostOwner(State);
}

/// Worker-visible scheduler authority is a non-owning facade. It may retain
/// private allocator/domain execution resources, but it cannot contain host
/// cleanup authority or expose lifecycle operations.
pub fn requireOpaqueWorkerFacade(comptime Handle: type, comptime State: type) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized facade"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized facade");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "invalid") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its invalid state");
    }
    if (@hasDecl(Handle, "settleRootRetirement") or @hasDecl(Handle, "deinit"))
        @compileError(@typeName(Handle) ++ " must not expose host lifecycle control");
    const state_info = switch (@typeInfo(State)) {
        .@"struct" => |info| info,
        else => @compileError(@typeName(State) ++ " must be private worker state"),
    };
    inline for (state_info.fields) |field| {
        if (field.type == *const HostCleanup or
            field.type == *HostCleanup or
            field.type == *const HostOwner or
            field.type == *HostOwner)
        {
            @compileError(@typeName(State) ++ " must not retain host cleanup authority");
        }
    }
}

pub fn requireOpaqueObservation(comptime Handle: type) void {
    requireOpaqueHandle(Handle, "observation");
}

/// A mutation authority is structurally the same shape as an observation
/// handle — pointer-sized, opaque, owning nothing — and differs only in the
/// operations it grants. It gets its own spelling so a capability that
/// publishes is never documented as one that merely observes.
pub fn requireOpaqueMutation(comptime Handle: type) void {
    requireOpaqueHandle(Handle, "mutation");
}

fn requireOpaqueHandle(comptime Handle: type, comptime role: []const u8) void {
    const handle_info = switch (@typeInfo(Handle)) {
        .@"enum" => |info| info,
        else => @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized " ++ role ++ " handle"),
    };
    if (handle_info.tag_type != usize or @sizeOf(Handle) != @sizeOf(usize))
        @compileError(@typeName(Handle) ++ " must be an opaque pointer-sized " ++ role ++ " handle");
    if (handle_info.is_exhaustive or
        handle_info.fields.len != 1 or
        !std.mem.eql(u8, handle_info.fields[0].name, "invalid") or
        handle_info.fields[0].value != 0)
    {
        @compileError(@typeName(Handle) ++ " must expose only its invalid state");
    }
    if (@hasDecl(Handle, "deinit"))
        @compileError(@typeName(Handle) ++ " must not own or retire its target");
}

/// A session domain stores only its owner. Allocator and retirement access
/// must remain derived methods so the correlated resources cannot diverge.
pub fn requireSingleHostOwner(comptime State: type) void {
    if (!@hasField(State, "host_owner") or @FieldType(State, "host_owner") != *HostOwner)
        @compileError(@typeName(State) ++ " must store exactly one HostOwner pointer");
    const state_info = @typeInfo(State).@"struct";
    inline for (state_info.fields) |field| {
        if (field.type == std.mem.Allocator or
            field.type == *ReleaseDomain or
            field.type == *const HostCleanup or
            field.type == *HostCleanup)
        {
            @compileError(@typeName(State) ++ " must derive allocator and domain from HostOwner");
        }
    }
}

/// Allocator-scoped retirement queue. Dropping a value performs only the
/// atomic ownership transition and an intrusive queue insertion; graph edges
/// and payload frees are processed by bounded scheduler/root turns.
pub const ReleaseDomain = struct {
    /// Intrusive storage for non-Value runtime retirement. Owners embed one
    /// node and expose `advanceRetirement(domain, allocator) bool`; the typed
    /// adapter is the only erased callback seam. Returning false requeues the
    /// same owner for a later bounded quantum.
    pub const Retirement = struct {
        next: ?*Retirement = null,
        context: ?*anyopaque = null,
        advance_fn: ?*const fn (*ReleaseDomain, std.mem.Allocator, *anyopaque) bool = null,
    };

    /// The bare list link of one parked allocation: something names that
    /// allocation without holding a reference, so it must outlive the contents
    /// it owned.
    ///
    /// The link lives inside the parked block, so parking allocates nothing and
    /// cannot fail — retirement runs on release-domain workers, where an
    /// allocation failure has no caller to report to. Same reason `Retirement`
    /// is embedded rather than boxed.
    ///
    /// Deliberately just the link, with no extent and no per-node destructor.
    /// Both were measured: carrying (ptr, len, alignment) costs 32 bytes a node
    /// and a per-node callback 16, against a parked-anchor budget of roughly 32
    /// bytes total. `reclaimTombstones` takes one destructor from its caller
    /// instead, which keeps this module type-blind at zero per-node cost.
    pub const TombstoneNode = struct {
        next: ?*TombstoneNode = null,
    };
    const Wake = struct {
        context: *anyopaque,
        wake_fn: *const fn (*anyopaque) void,
    };

    /// The archive's O(1) notification that one code header it indexed is
    /// being destroyed, so the directory slot holding that header's lineage can
    /// be cleared and its identity recycled.
    ///
    /// It hangs off the release domain rather than off the header because both
    /// belong to the same reclamation root, and a header carries only its
    /// numeric namespace — not a way back to the issuer. The namespace travels
    /// with the call so an archive can ignore anything that is not its own.
    const CodeRetirement = struct {
        context: *anyopaque,
        retire_fn: *const fn (*anyopaque, CodeProvenanceNamespace, CodeIdentity, *ListHandle) void,
    };

    allocator: std.mem.Allocator,
    queue_mutex: std.Io.Mutex = .init,
    drain_mutex: std.Io.Mutex = .init,
    first: ?*Header = null,
    last: ?*Header = null,
    retirement_first: ?*Retirement = null,
    retirement_last: ?*Retirement = null,
    tombstones: std.atomic.Value(?*TombstoneNode) = .init(null),
    prefer_retirement: bool = false,
    wake: ?Wake = null,
    /// Registration metadata is one state: a callback can exist only together
    /// with the nonzero issuance that owns it, and a vacant slot remembers the
    /// last issuance without leaving independently correlated fields behind.
    code_retirement: union(enum) {
        vacant: u64,
        attached: struct {
            issuance: u64,
            callback: CodeRetirement,
        },
    } = .{ .vacant = 0 },

    pub fn init(allocator: std.mem.Allocator) ReleaseDomain {
        return .{ .allocator = allocator };
    }

    /// Parks one allocation until the final teardown walk.
    ///
    /// Infallible and thread-safe by construction: the node is inside the
    /// parked memory, and a single exchange both publishes it and yields the
    /// predecessor to link to. Writing `next` after the exchange is safe only
    /// because nothing pops this list until teardown, when execution has
    /// stopped — the list is push-only for its whole useful life.
    pub fn parkTombstone(self: *ReleaseDomain, node: *TombstoneNode) void {
        node.next = self.tombstones.swap(node, .acq_rel);
    }

    /// Frees every parked block, using the one destructor its caller supplies.
    ///
    /// One shared destructor rather than one per node: every parked block is
    /// the same type, so the discrimination would be pure overhead in the
    /// budget the retention soaks impose. If a second parked type ever appears
    /// it takes its own list head — it does not turn the node into a
    /// discriminated one.
    ///
    /// Valid only at final host teardown, after execution has provably
    /// stopped. A parked block is reachable from a scope cell that holds no
    /// reference to it, so freeing one while any reader could still resolve a
    /// word is exactly the use-after-free parking exists to prevent. See
    /// `Session.deinit`, whose order supplies that guarantee: `scheduler.deinit`
    /// stops execution before any teardown runs, and this walk is last.
    pub fn reclaimTombstones(
        self: *ReleaseDomain,
        destroy: *const fn (std.mem.Allocator, *TombstoneNode) void,
    ) void {
        var node = self.tombstones.swap(null, .acq_rel);
        while (node) |parked| {
            // The successor is read before the memory holding it is freed.
            node = parked.next;
            destroy(self.allocator, parked);
        }
    }

    pub fn releaseValue(self: *ReleaseDomain, item: Value) void {
        if (item.heapHeader()) |header| self.releaseHeader(header);
    }

    pub fn attachWake(self: *ReleaseDomain, owner: anytype) void {
        const Pointer = @TypeOf(owner);
        const pointer = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("retirement wake owner must be a pointer"),
        };
        if (pointer.size != .one) @compileError("retirement wake owner must be a single-item pointer");
        const adapters = RetirementWakeAdapters(pointer.child);
        std.debug.assert(self.wake == null);
        self.wake = .{ .context = @ptrCast(owner), .wake_fn = adapters.wake };
    }

    pub fn detachWake(self: *ReleaseDomain) void {
        self.wake = null;
    }

    /// Announces one destroyed code header to its archive. O(1), and reached
    /// only from the single destruction site, immediately before the header's
    /// storage goes away.
    fn retireCodeIdentity(self: *ReleaseDomain, header: *Header) void {
        const hook = switch (self.code_retirement) {
            .vacant => return,
            .attached => |attached| attached.callback,
        };
        const obj = objectConst(header);
        if (obj.provenance_namespace == .none) return;
        const identity = headerImplConst(header).identity() orelse return;
        hook.retire_fn(
            hook.context,
            obj.provenance_namespace,
            identity,
            @ptrCast(@alignCast(header)),
        );
    }

    pub fn retire(self: *ReleaseDomain, owner: anytype, node: *Retirement) void {
        const Pointer = @TypeOf(owner);
        const pointer = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("retirement owner must be a pointer"),
        };
        if (pointer.size != .one) @compileError("retirement owner must be a single-item pointer");
        const adapters = RetirementAdapters(pointer.child);
        std.debug.assert(node.context == null and node.advance_fn == null and node.next == null);
        node.context = @ptrCast(owner);
        node.advance_fn = adapters.advance;
        self.enqueueRetirement(node);
    }

    pub fn releaseHeader(self: *ReleaseDomain, handle: anytype) void {
        const header = mutableHeader(handle);
        const old = headerImpl(header).rc.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = headerImpl(header).rc.load(.acquire);
        self.enqueueZero(header);
    }

    fn enqueueZero(self: *ReleaseDomain, header: *Header) void {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        std.debug.assert(object(header).next_destroy == null);
        if (self.last) |last| object(last).next_destroy = header else self.first = header;
        self.last = header;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        self.notifyWork();
    }

    fn enqueueRetirement(self: *ReleaseDomain, node: *Retirement) void {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        std.debug.assert(node.next == null);
        if (self.retirement_last) |last| last.next = node else self.retirement_first = node;
        self.retirement_last = node;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        self.notifyWork();
    }

    fn notifyWork(self: *ReleaseDomain) void {
        if (self.wake) |wake| wake.wake_fn(wake.context);
    }

    fn popZero(self: *ReleaseDomain) ?*Header {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        const header = self.first orelse {
            std.Io.Threaded.mutexUnlock(&self.queue_mutex);
            return null;
        };
        self.first = object(header).next_destroy;
        if (self.first == null) self.last = null;
        object(header).next_destroy = null;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        return header;
    }

    fn popRetirement(self: *ReleaseDomain) ?*Retirement {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        const node = self.retirement_first orelse {
            std.Io.Threaded.mutexUnlock(&self.queue_mutex);
            return null;
        };
        self.retirement_first = node.next;
        if (self.retirement_first == null) self.retirement_last = null;
        node.next = null;
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        return node;
    }

    pub fn hasPending(self: *ReleaseDomain) bool {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        return self.first != null or self.retirement_first != null;
    }

    /// Returns true when the queue is empty after at most `budget` object-edge
    /// transitions. Multiple workers may help, but payload destruction is
    /// serialized so every intrusive node has one active owner.
    pub fn advance(self: *ReleaseDomain, budget: usize) bool {
        std.debug.assert(budget != 0);
        std.Io.Threaded.mutexLock(&self.drain_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.drain_mutex);
        return self.advanceLocked(budget);
    }

    /// Scheduler-facing nonblocking turn. A second worker never queues behind
    /// the active retirement owner; it remains available for runnable work.
    pub fn tryAdvance(self: *ReleaseDomain, budget: usize) ?bool {
        std.debug.assert(budget != 0);
        if (!self.drain_mutex.tryLock()) return null;
        defer std.Io.Threaded.mutexUnlock(&self.drain_mutex);
        return self.advanceLocked(budget);
    }

    fn advanceLocked(self: *ReleaseDomain, budget: usize) bool {
        for (0..budget) |_| {
            if (self.prefer_retirement) {
                if (self.popRetirement()) |node| {
                    self.prefer_retirement = false;
                    const advance_fn = node.advance_fn.?;
                    const context = node.context.?;
                    if (!advance_fn(self, self.allocator, context)) {
                        self.enqueueRetirement(node);
                    }
                    continue;
                }
            }
            if (self.popZero()) |header| {
                self.prefer_retirement = true;
                if (self.releaseNextChild(header)) {
                    self.enqueueZero(header);
                } else {
                    self.retireCodeIdentity(header);
                    freePayload(self.allocator, header);
                    self.allocator.destroy(object(header));
                }
                continue;
            }
            if (self.popRetirement()) |node| {
                self.prefer_retirement = false;
                const advance_fn = node.advance_fn.?;
                const context = node.context.?;
                if (!advance_fn(self, self.allocator, context)) {
                    self.enqueueRetirement(node);
                }
                continue;
            }
            return true;
        }
        return !self.hasPending();
    }

    fn drainOwned(self: *ReleaseDomain) void {
        while (!self.advance(65_536)) {}
    }

    fn releaseNextChild(self: *ReleaseDomain, header: *Header) bool {
        const obj = object(header);
        switch (kind(header)) {
            .generic_spine => {
                const used: usize = @intCast(length(header));
                if (obj.destroy_index == used) return false;
                const child = valuesConst(@ptrCast(@alignCast(header)))[obj.destroy_index];
                obj.destroy_index += 1;
                self.releaseValue(child);
                return true;
            },
            .dict => {
                const storage = dictStorageConst(@ptrCast(@alignCast(header)));
                const payload = switch (storage.*) {
                    .initializing => return false,
                    .ready => |ready| ready.payload,
                };
                const child = switch (obj.destroy_index) {
                    0 => payload.keys,
                    1 => payload.vals,
                    2 => payload.hashes,
                    else => return false,
                };
                obj.destroy_index += 1;
                self.releaseHeader(child);
                return true;
            },
            .task => {
                if (obj.destroy_index != 0) return false;
                obj.destroy_index = 1;
                const storage: *TaskStorage = @constCast(taskStorage(@ptrCast(@alignCast(header))));
                if (storage.destroy(self.allocator, storage.payload)) |child| self.releaseValue(child);
                return true;
            },
            // The image's own graph is user-sized, so the callback only drops
            // one reference; whatever that makes unreachable retires through
            // this same domain in later bounded steps.
            .module => {
                if (obj.destroy_index != 0) return false;
                obj.destroy_index = 1;
                const storage: *ModuleStorage = @constCast(moduleStorage(@ptrCast(@alignCast(header))));
                storage.release(storage.payload);
                return true;
            },
            // The plan's two owned values retire through this same domain, one
            // bounded step each, exactly as a dict's three payload headers do.
            .unit_plan => {
                const storage = unitPlanStorage(@ptrCast(@alignCast(header)));
                const child = switch (obj.destroy_index) {
                    0 => storage.seeds,
                    1 => storage.body,
                    else => return false,
                };
                obj.destroy_index += 1;
                self.releaseHeader(child);
                return true;
            },
            .leaf_u8,
            .leaf_i64,
            .leaf_f64,
            .leaf_char1,
            .leaf_char2,
            .leaf_char4,
            .leaf_symbol,
            .reserved_mask,
            => return false,
        }
    }
};

/// Host-side ownership of a retirement domain and its blocking-cleanup seal.
/// The owner is kept outside every scheduler-attached type; workers receive
/// only `domain()`, while shutdown code may additionally borrow `cleanup()`.
pub const HostOwner = struct {
    cleanup_seal: u8 = 0,
    unit_plan_seal: u8 = 0,
    releases: ReleaseDomain,

    pub fn init(allocator: std.mem.Allocator) HostOwner {
        return .{ .releases = .init(allocator) };
    }

    pub fn domain(self: *HostOwner) *ReleaseDomain {
        return &self.releases;
    }

    pub fn cleanup(self: *const HostOwner) *const HostCleanup {
        return @ptrCast(&self.cleanup_seal);
    }

    /// The sole cross-module authority that can allocate a unit plan in this
    /// owner's reclamation root. The seal is address-derived from this owner,
    /// so allocator and retirement-domain selection are not caller inputs.
    pub fn unitPlanSeal(self: *const HostOwner) *const UnitPlanSeal {
        return @ptrCast(&self.unit_plan_seal);
    }

    /// Registers the archive that owns this root's code provenance, and is the
    /// receipt required to unregister it.
    ///
    /// A receipt names one *issuance*, not an owner address, so a copied or
    /// stale one cannot detach the registration that replaced it. It is
    /// host-side on purpose: workers hold `ReleaseDomain`, which has no
    /// registration surface at all, and both operations belong to the quiescent
    /// construction and teardown phases where the host owner is the only thing
    /// running.
    pub const CodeRetirementRegistration = enum(u64) {
        released = 0,
        _,
    };

    /// Attaching is what turns lineage storage from history-proportional into
    /// live-proportional: without it, every identity ever issued keeps its
    /// directory slot for the archive's whole life. Null means this root already
    /// has a code provenance owner — refused in every build mode, not asserted.
    pub fn attachCodeRetirement(
        self: *HostOwner,
        owner: anytype,
    ) ?CodeRetirementRegistration {
        const Pointer = @TypeOf(owner);
        const pointer = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("code retirement owner must be a pointer"),
        };
        if (pointer.size != .one) @compileError("code retirement owner must be a single-item pointer");
        const last_issuance = switch (self.releases.code_retirement) {
            .vacant => |issuance| issuance,
            .attached => return null,
        };
        const issuance = std.math.add(u64, last_issuance, 1) catch return null;
        if (issuance == 0) return null;
        const adapters = CodeRetirementAdapters(pointer.child);
        self.releases.code_retirement = .{ .attached = .{
            .issuance = issuance,
            .callback = .{
                .context = @ptrCast(owner),
                .retire_fn = adapters.retire,
            },
        } };
        return @enumFromInt(issuance);
    }

    /// Detached before the archive's directory is torn down; headers retiring
    /// after this point simply keep their slots, which are about to be freed
    /// wholesale. Consumes the receipt, and does nothing for one that does not
    /// name the current issuance.
    pub fn detachCodeRetirement(
        self: *HostOwner,
        registration: *CodeRetirementRegistration,
    ) void {
        const claimed = registration.*;
        registration.* = .released;
        if (claimed == .released) return;
        const attached = switch (self.releases.code_retirement) {
            .vacant => return,
            .attached => |attached| attached,
        };
        if (@intFromEnum(claimed) != attached.issuance) return;
        self.releases.code_retirement = .{ .vacant = attached.issuance };
    }
};

/// Opaque authority for sealing the two typed halves of a unit plan. A caller
/// cannot select the plan header's allocator; the issuing `HostOwner` supplies
/// its allocation root. The existing Session-stack ownership invariant remains
/// responsible for the two input handles' root.
pub const UnitPlanSeal = opaque {
    pub fn seal(
        self: *const UnitPlanSeal,
        seeds: *ListHandle,
        body: *ListHandle,
    ) error{OutOfMemory}!Value {
        const owner = unitPlanOwner(self);
        return createUnitPlan(owner.releases.allocator, seeds, body);
    }
};

fn unitPlanOwner(seal: *const UnitPlanSeal) *const HostOwner {
    const byte: *const u8 = @ptrCast(seal);
    return @alignCast(@fieldParentPtr("unit_plan_seal", byte));
}

fn cleanupOwner(host: *const HostCleanup) *const HostOwner {
    const seal: *const u8 = @ptrCast(host);
    return @alignCast(@fieldParentPtr("cleanup_seal", seal));
}

pub fn hostDomain(host: *const HostCleanup) *ReleaseDomain {
    return &@constCast(cleanupOwner(host)).releases;
}

fn RetirementAdapters(comptime Owner: type) type {
    return struct {
        fn advance(
            domain: *ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) bool {
            const owner: *Owner = @ptrCast(@alignCast(raw));
            return Owner.advanceRetirement(domain, allocator, owner);
        }
    };
}

fn CodeRetirementAdapters(comptime Owner: type) type {
    return struct {
        fn retire(
            raw: *anyopaque,
            namespace: CodeProvenanceNamespace,
            identity: CodeIdentity,
            header: *ListHandle,
        ) void {
            const owner: *Owner = @ptrCast(@alignCast(raw));
            Owner.retireCodeIdentity(owner, namespace, identity, header);
        }
    };
}

fn RetirementWakeAdapters(comptime Owner: type) type {
    return struct {
        fn wake(raw: *anyopaque) void {
            const owner: *Owner = @ptrCast(@alignCast(raw));
            Owner.wakeRetirement(owner);
        }
    };
}

/// A movable ownership capability. The optional payload is the state: an
/// empty capability has transferred or retired its value and cannot drop it a
/// second time.
pub const OwnedValue = struct {
    domain: *ReleaseDomain,
    item: ?Value,

    pub fn init(domain: *ReleaseDomain, item: Value) OwnedValue {
        return .{ .domain = domain, .item = item };
    }

    pub fn borrow(self: *const OwnedValue) Value {
        return self.item.?;
    }

    pub fn take(self: *OwnedValue) Value {
        const item = self.item.?;
        self.item = null;
        return item;
    }

    pub fn deinit(self: *OwnedValue) void {
        if (self.item) |item| self.domain.releaseValue(item);
        self.item = null;
    }
};

/// Exhaustive destruction policy for scheduler-owned driver objects.
///
/// Field-owned drivers have no destructor hook: their `Owned` fields are the
/// complete ownership declaration. Bounded-retirement drivers are enqueued by
/// the shared adapter. Self-owned drivers are address-stable aggregates whose
/// teardown must coordinate internal borrows before the allocation is freed.
pub const DriverOwnership = enum {
    fields,
    bounded_retirement,
    self_owned,
};

/// Explicit protocol selected by a structured `Owned(T)` payload. Requiring
/// the type to choose prevents adding a second teardown method from silently
/// changing cancellation behavior.
pub const OwnedDisposal = enum {
    retire,
    deinit,
};

/// Field-level ownership marker for runtime continuations. Unlike
/// `OwnedValue`, this capability does not carry a reclamation root: the
/// enclosing owner supplies that root when its fields are derivedly retired.
pub fn Owned(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const owned_payload = T;

        item: ?T,

        pub fn init(item: T) Self {
            return .{ .item = item };
        }

        pub fn borrow(self: *const Self) T {
            return self.item.?;
        }

        pub fn borrowMut(self: *Self) *T {
            return &self.item.?;
        }

        pub fn take(self: *Self) T {
            const item = self.item.?;
            self.item = null;
            return item;
        }

        pub fn deinit(
            self: *Self,
            releases: *ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            if (self.item) |*item| disposeOwned(T, releases, allocator, item);
            self.item = null;
        }
    };
}

fn disposeOwned(
    comptime T: type,
    releases: *ReleaseDomain,
    allocator: std.mem.Allocator,
    item: *T,
) void {
    if (T == Value) {
        releases.releaseValue(item.*);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                allocator.free(item.*);
                return;
            }
            if (pointer.size == .one and
                (pointer.child == Header or pointer.child == ListHandle or pointer.child == DictHandle))
            {
                releases.releaseHeader(item.*);
                return;
            }
            if (pointer.size == .one and @hasDecl(pointer.child, "ownership")) {
                destroyDriver(releases, allocator, item.*);
                return;
            }
            if (pointer.size == .one and @hasDecl(pointer.child, "releasePin")) {
                item.*.releasePin();
                return;
            }
        },
        .@"struct", .@"union", .@"enum" => {
            const has_retire = @hasDecl(T, "retire");
            const has_deinit = @hasDecl(T, "deinit");
            const disposal: OwnedDisposal = if (@hasDecl(T, "owned_disposal"))
                T.owned_disposal
            else if (has_retire and has_deinit)
                @compileError(@typeName(T) ++ " must choose retire or deinit explicitly")
            else if (has_retire)
                .retire
            else if (has_deinit)
                .deinit
            else
                @compileError("heap.Owned has no disposal protocol for " ++ @typeName(T));
            switch (disposal) {
                .retire => {
                    if (!has_retire)
                        @compileError(@typeName(T) ++ " selects retirement without a retire method");
                    const retire_info = @typeInfo(@TypeOf(T.retire)).@"fn";
                    if (retire_info.params.len == 2)
                        item.retire(releases)
                    else if (retire_info.params.len == 3 and
                        retire_info.params[2].type.? == std.mem.Allocator)
                        item.retire(releases, allocator)
                    else
                        @compileError("unsupported retire protocol for " ++ @typeName(T));
                    return;
                },
                .deinit => {
                    if (!has_deinit)
                        @compileError(@typeName(T) ++ " selects deinit without a deinit method");
                    const deinit_info = @typeInfo(@TypeOf(T.deinit)).@"fn";
                    if (deinit_info.params.len == 1)
                        item.deinit()
                    else if (deinit_info.params.len == 2 and
                        deinit_info.params[1].type.? == std.mem.Allocator)
                        item.deinit(allocator)
                    else if (deinit_info.params.len == 2 and
                        deinit_info.params[1].type.? == *ReleaseDomain)
                        item.deinit(releases)
                    else if (deinit_info.params.len == 3 and
                        deinit_info.params[1].type.? == *ReleaseDomain and
                        deinit_info.params[2].type.? == std.mem.Allocator)
                        item.deinit(releases, allocator)
                    else
                        @compileError("unsupported deinit protocol for " ++ @typeName(T));
                    return;
                },
            }
        },
        else => {},
    }
    @compileError("heap.Owned has no disposal protocol for " ++ @typeName(T));
}

fn isOwnedMarker(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "owned_payload"),
        else => false,
    };
}

/// Retire every explicitly owned field. Each payload's disposal must be
/// self-contained: it may inspect its own state, but it must never dereference
/// a sibling field of the enclosing owner. Declaration order therefore has no
/// lifetime meaning; the reverse walk below is only a deterministic cleanup
/// order. Bare fields are observational state, and ownership is never inferred
/// from a field name or from a destructor body.
fn deinitOwnedFields(
    releases: *ReleaseDomain,
    allocator: std.mem.Allocator,
    owner: anytype,
) void {
    const Owner = @typeInfo(@TypeOf(owner)).pointer.child;
    const fields = @typeInfo(Owner).@"struct".fields;
    inline for (0..fields.len) |offset| {
        const field = fields[fields.len - 1 - offset];
        const Field = field.type;
        if (comptime isOwnedMarker(Field)) {
            @field(owner, field.name).deinit(releases, allocator);
        } else switch (@typeInfo(Field)) {
            .optional => |optional| if (comptime isOwnedMarker(optional.child)) {
                if (@field(owner, field.name)) |*owned| owned.deinit(releases, allocator);
                @field(owner, field.name) = null;
            },
            else => {},
        }
    }
}

fn destroyOwned(
    releases: *ReleaseDomain,
    allocator: std.mem.Allocator,
    owner: anytype,
) void {
    deinitOwnedFields(releases, allocator, owner);
    allocator.destroy(owner);
}

pub fn validateDriverOwnership(comptime Driver: type) DriverOwnership {
    if (!@hasDecl(Driver, "ownership"))
        @compileError(@typeName(Driver) ++ " must declare heap.DriverOwnership");
    if (@hasDecl(Driver, "destroy"))
        @compileError(@typeName(Driver) ++ " must use its declared driver ownership policy");
    const ownership: DriverOwnership = Driver.ownership;
    switch (ownership) {
        .fields => {
            if (@hasDecl(Driver, "deinit"))
                @compileError(@typeName(Driver) ++ " field ownership forbids a destructor hook");
        },
        .bounded_retirement => {
            if (!@hasField(Driver, "retirement"))
                @compileError(@typeName(Driver) ++ " bounded retirement requires a retirement node");
            if (@FieldType(Driver, "retirement") != ReleaseDomain.Retirement)
                @compileError(@typeName(Driver) ++ " has the wrong retirement node type");
            if (!@hasDecl(Driver, "advanceRetirement"))
                @compileError(@typeName(Driver) ++ " bounded retirement requires advanceRetirement");
            if (@hasDecl(Driver, "deinit"))
                @compileError(@typeName(Driver) ++ " bounded retirement forbids a destructor hook");
        },
        .self_owned => {
            if (!@hasDecl(Driver, "address_stable_driver"))
                @compileError(@typeName(Driver) ++ " self-owned destruction requires address-stable construction");
            if (!@hasDecl(Driver, "deinit"))
                @compileError(@typeName(Driver) ++ " self-owned destruction requires deinit");
        },
    }
    return ownership;
}

/// Retire a fully initialized driver's owned fields without freeing the
/// storage holding them — either because the allocation that would have held
/// it failed, or because it never had one and lives in the unit's inline slot.
/// Self-owned drivers are deliberately excluded because their representation
/// is only valid after address-stable construction.
pub fn deinitDriverFields(
    releases: *ReleaseDomain,
    allocator: std.mem.Allocator,
    driver: anytype,
) void {
    const Driver = @typeInfo(@TypeOf(driver)).pointer.child;
    switch (comptime validateDriverOwnership(Driver)) {
        .fields, .bounded_retirement => deinitOwnedFields(releases, allocator, driver),
        .self_owned => @compileError("self-owned drivers cannot be destroyed before installation"),
    }
}

/// Destroy a scheduler-owned driver through its exhaustive type policy. No
/// adapter chooses a destructor by method-name convention.
pub fn destroyDriver(
    releases: *ReleaseDomain,
    allocator: std.mem.Allocator,
    driver: anytype,
) void {
    const Driver = @typeInfo(@TypeOf(driver)).pointer.child;
    switch (comptime validateDriverOwnership(Driver)) {
        .fields => destroyOwned(releases, allocator, driver),
        .bounded_retirement => releases.retire(driver, &driver.retirement),
        .self_owned => {
            driver.deinit(releases, allocator);
            allocator.destroy(driver);
        },
    }
}

/// Exact-capacity, non-relocating ownership for a partially initialized value
/// sequence. Abandonment retires one heap root; it never loops over the
/// initialized prefix on the caller's stack.
pub const OwnedValueBuffer = union(enum) {
    building: struct {
        domain: *ReleaseDomain,
        builder: ListBuilder(.generic_spine),
    },
    moved,

    pub fn init(domain: *ReleaseDomain, capacity_value: usize) error{OutOfMemory}!OwnedValueBuffer {
        return .{ .building = .{
            .domain = domain,
            .builder = try ListBuilder(.generic_spine).init(domain.allocator, 0, capacity_value),
        } };
    }

    pub fn len(self: *const OwnedValueBuffer) usize {
        return switch (self.*) {
            .building => |building| building.builder.len(),
            .moved => unreachable,
        };
    }

    pub fn capacity(self: *const OwnedValueBuffer) usize {
        return switch (self.*) {
            .building => |building| building.builder.capacity(),
            .moved => unreachable,
        };
    }

    pub fn values(self: *const OwnedValueBuffer) []const Value {
        return switch (self.*) {
            .building => |building| building.builder.items()[0..self.len()],
            .moved => unreachable,
        };
    }

    pub fn appendOwned(self: *OwnedValueBuffer, item: Value) void {
        switch (self.*) {
            .building => |*building| {
                const index = building.builder.len();
                std.debug.assert(index < building.builder.capacity());
                building.builder.items()[index] = item;
                building.builder.setLen(index + 1);
            },
            .moved => unreachable,
        }
    }

    pub fn appendBorrowed(self: *OwnedValueBuffer, item: Value) void {
        retainValue(item);
        self.appendOwned(item);
    }

    /// Replaces one initialized slot, consuming the replacement and retiring
    /// the buffer's former value through its own reclamation domain.
    pub fn replaceOwned(self: *OwnedValueBuffer, index: usize, item: Value) void {
        switch (self.*) {
            .building => |*building| {
                std.debug.assert(index < building.builder.len());
                const previous = building.builder.items()[index];
                building.builder.items()[index] = item;
                building.domain.releaseValue(previous);
            },
            .moved => unreachable,
        }
    }

    pub fn takeList(self: *OwnedValueBuffer) Value {
        return switch (self.*) {
            .building => |*building| result: {
                const result: Value = .{ .list = building.builder.finish() };
                self.* = .moved;
                break :result result;
            },
            .moved => unreachable,
        };
    }

    pub fn take(self: *OwnedValueBuffer) OwnedValueBuffer {
        return switch (self.*) {
            .building => |building| result: {
                self.* = .moved;
                break :result .{ .building = building };
            },
            .moved => unreachable,
        };
    }

    pub fn deinit(self: *OwnedValueBuffer) void {
        switch (self.*) {
            .building => |*building| building.builder.retirePartial(building.domain),
            .moved => {},
        }
        self.* = .moved;
    }
};

/// Non-relocating ownership for an unknown number of values. Fixed-size heap
/// chunks form a backwards generic-spine chain, so abandonment retires one
/// root and the release domain walks every prior chunk within its normal
/// budget. Metadata may keep borrowed copies of the values independently.
pub const OwnedValueChain = union(enum) {
    building: struct {
        domain: *ReleaseDomain,
        builder: ListBuilder(.generic_spine),
    },
    moved,

    const chunk_capacity = 257;

    pub fn init(domain: *ReleaseDomain) error{OutOfMemory}!OwnedValueChain {
        return .{ .building = .{
            .domain = domain,
            .builder = try ListBuilder(.generic_spine).init(domain.allocator, 0, chunk_capacity),
        } };
    }

    /// Consumes `item` on both success and allocation failure.
    pub fn appendOwned(self: *OwnedValueChain, item: Value) error{OutOfMemory}!void {
        switch (self.*) {
            .building => |*building| {
                var index = building.builder.len();
                if (index == chunk_capacity) {
                    var next = ListBuilder(.generic_spine).init(
                        building.domain.allocator,
                        1,
                        chunk_capacity,
                    ) catch {
                        building.domain.releaseValue(item);
                        return error.OutOfMemory;
                    };
                    next.items()[0] = .{ .list = building.builder.finish() };
                    building.builder = next;
                    index = 1;
                }
                building.builder.items()[index] = item;
                building.builder.setLen(index + 1);
            },
            .moved => unreachable,
        }
    }

    pub fn appendBorrowed(self: *OwnedValueChain, item: Value) error{OutOfMemory}!void {
        retainValue(item);
        return self.appendOwned(item);
    }

    pub fn deinit(self: *OwnedValueChain) void {
        switch (self.*) {
            .building => |*building| building.builder.retirePartial(building.domain),
            .moved => {},
        }
        self.* = .moved;
    }
};

fn freePayload(allocator: std.mem.Allocator, header: *Header) void {
    const obj = object(header);
    const cap = obj.capacity;
    switch (kind(header)) {
        .generic_spine => freeItems(Value, allocator, obj.payload, cap),
        .leaf_u8 => freeItems(u8, allocator, obj.payload, cap),
        .leaf_i64 => freeItems(i64, allocator, obj.payload, cap),
        .leaf_f64 => freeItems(f64, allocator, obj.payload, cap),
        .leaf_char1 => freeItems(u8, allocator, obj.payload, cap),
        .leaf_char2 => freeItems(u16, allocator, obj.payload, cap),
        .leaf_char4 => freeItems(u32, allocator, obj.payload, cap),
        .leaf_symbol => freeItems(u32, allocator, obj.payload, cap),
        .dict => {
            const storage: *DictStorage = @constCast(dictStorageConst(@ptrCast(@alignCast(header))));
            switch (storage.*) {
                .initializing => {},
                .ready => |ready| if (ready.index) |index| allocator.free(index),
            }
            allocator.destroy(storage);
        },
        .task => {
            const storage: *TaskStorage = @constCast(taskStorage(@ptrCast(@alignCast(header))));
            allocator.destroy(storage);
        },
        .module => {
            const storage: *ModuleStorage = @constCast(moduleStorage(@ptrCast(@alignCast(header))));
            allocator.destroy(storage);
        },
        .unit_plan => {
            const storage: *UnitPlanStorage = @constCast(unitPlanStorage(@ptrCast(@alignCast(header))));
            allocator.destroy(storage);
        },
        .reserved_mask => {},
    }
    obj.payload = null;
    obj.capacity = 0;
}

fn freeItems(
    comptime T: type,
    allocator: std.mem.Allocator,
    payload: ?*anyopaque,
    count: usize,
) void {
    if (count == 0) return;
    const ptr: [*]T = @ptrCast(@alignCast(payload.?));
    allocator.free(ptr[0..count]);
}

fn resizePayload(
    comptime T: type,
    allocator: std.mem.Allocator,
    header: *Header,
    new_capacity: usize,
) error{OutOfMemory}!void {
    const obj = object(header);
    const old_capacity = obj.capacity;
    if (old_capacity == 0) {
        const replacement = try allocator.alloc(T, new_capacity);
        obj.payload = @ptrCast(replacement.ptr);
    } else {
        const ptr: [*]T = @ptrCast(@alignCast(obj.payload.?));
        const replacement = try allocator.realloc(ptr[0..old_capacity], new_capacity);
        obj.payload = @ptrCast(replacement.ptr);
    }
    obj.capacity = new_capacity;
}

pub fn replaceBuffer(
    allocator: std.mem.Allocator,
    list_header: *UniqueList,
    new_capacity: usize,
) error{OutOfMemory}!void {
    const header: *UniqueHeader = @ptrCast(@alignCast(list_header));
    const raw = uniqueHeader(header);
    return switch (uniqueImpl(header).kind()) {
        .generic_spine => resizePayload(Value, allocator, raw, new_capacity),
        .leaf_u8 => resizePayload(u8, allocator, raw, new_capacity),
        .leaf_i64 => resizePayload(i64, allocator, raw, new_capacity),
        .leaf_f64 => resizePayload(f64, allocator, raw, new_capacity),
        .leaf_char1 => resizePayload(u8, allocator, raw, new_capacity),
        .leaf_char2 => resizePayload(u16, allocator, raw, new_capacity),
        .leaf_char4, .leaf_symbol => resizePayload(u32, allocator, raw, new_capacity),
        .dict, .task, .module, .unit_plan, .reserved_mask => unreachable,
    };
}

/// Moves a fully-built representation into a unique destination header. The
/// consumed source wrapper receives the destination's old representation and
/// is retired through the sole graph-reclamation implementation.
pub fn adoptListRepresentationDeferred(
    releases: *ReleaseDomain,
    dest: *UniqueList,
    source: *UniqueList,
) void {
    adoptRepresentationDeferred(
        releases,
        @ptrCast(@alignCast(dest)),
        @ptrCast(@alignCast(source)),
    );
}

pub fn adoptDictRepresentationDeferred(
    releases: *ReleaseDomain,
    dest: *UniqueDict,
    source: *UniqueDict,
) void {
    adoptRepresentationDeferred(
        releases,
        @ptrCast(@alignCast(dest)),
        @ptrCast(@alignCast(source)),
    );
}

fn adoptRepresentationDeferred(
    releases: *ReleaseDomain,
    dest: *UniqueHeader,
    source: *UniqueHeader,
) void {
    const dest_raw = uniqueHeader(dest);
    const source_raw = uniqueHeader(source);
    std.debug.assert(dest_raw != source_raw);
    const dest_obj = object(dest_raw);
    const source_obj = object(source_raw);
    std.debug.assert(dest_obj.next_destroy == null and source_obj.next_destroy == null);

    const dest_kind = uniqueImpl(dest).kind();
    const dest_len = uniqueImpl(dest).len;
    const dest_capacity = dest_obj.capacity;
    const dest_payload = dest_obj.payload;
    const source_kind = uniqueImpl(source).kind();
    const source_len = uniqueImpl(source).len;
    const source_capacity = source_obj.capacity;
    const source_payload = source_obj.payload;

    dest_obj.capacity = source_capacity;
    dest_obj.payload = source_payload;
    dest_obj.destroy_index = 0;
    uniqueImpl(dest).setKind(source_kind);
    uniqueImpl(dest).len = source_len;

    source_obj.capacity = dest_capacity;
    source_obj.payload = dest_payload;
    source_obj.destroy_index = 0;
    uniqueImpl(source).setKind(dest_kind);
    uniqueImpl(source).len = dest_len;
    releases.releaseHeader(source_raw);
}
