//! Specialized flat leaves and generic value spines.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const ListHandle = value.ListHandle;
pub const HeapKind = value.HeapKind;

pub const Error = error{ OutOfMemory, NotAList, IndexOutOfBounds };

pub const ElemProfile = enum {
    empty,
    all_byte,
    all_int,
    all_float,
    all_char,
    all_symbol,
    mixed,
};

/// The representation a list takes: the one lattice every list builder
/// consults, whether it sees elements one at a time or whole typed pieces.
/// Bytes widen to ints and narrower characters to wider ones; anything across
/// classes, and any element that is not an atom, makes a generic spine.
pub const ListProfile = struct {
    kind: ElemProfile = .empty,
    max_codepoint: u32 = 0,

    /// The profile with one more element.
    pub fn add(self: ListProfile, item: Value) ListProfile {
        return self.join(of(item));
    }

    /// One element's profile.
    pub fn of(item: Value) ListProfile {
        return switch (item) {
            .int => |integer| .{ .kind = if (integer >= 0 and integer <= std.math.maxInt(u8)) .all_byte else .all_int },
            .float => .{ .kind = .all_float },
            .char => |codepoint| .{ .kind = .all_char, .max_codepoint = codepoint },
            .symbol => .{ .kind = .all_symbol },
            .word, .list, .dict, .task, .module, .port => .{ .kind = .mixed },
        };
    }

    /// A whole typed leaf's profile, read from its representation rather than
    /// its elements. A generic spine's elements are unknown without a scan.
    pub fn ofKind(kind: HeapKind) ListProfile {
        return switch (kind) {
            .leaf_u8 => .{ .kind = .all_byte },
            .leaf_i64 => .{ .kind = .all_int },
            .leaf_f64 => .{ .kind = .all_float },
            .leaf_char1 => .{ .kind = .all_char, .max_codepoint = std.math.maxInt(u8) },
            .leaf_char2 => .{ .kind = .all_char, .max_codepoint = std.math.maxInt(u16) },
            .leaf_char4 => .{ .kind = .all_char, .max_codepoint = std.math.maxInt(u21) },
            .leaf_symbol => .{ .kind = .all_symbol },
            .generic_spine, .dict, .task, .port, .module, .reserved_mask => .{ .kind = .mixed },
        };
    }

    pub fn join(self: ListProfile, other: ListProfile) ListProfile {
        if (self.kind == .empty) return other;
        if (other.kind == .empty) return self;
        if (self.kind == .mixed or other.kind == .mixed) return .{ .kind = .mixed };
        if (self.kind == other.kind) return .{ .kind = self.kind, .max_codepoint = @max(self.max_codepoint, other.max_codepoint) };
        const byte_int = (self.kind == .all_byte or self.kind == .all_int) and (other.kind == .all_byte or other.kind == .all_int);
        return .{ .kind = if (byte_int) .all_int else .mixed };
    }

    /// The representation this profile publishes as.
    pub fn heapKind(self: ListProfile) HeapKind {
        return switch (self.kind) {
            .empty, .mixed => .generic_spine,
            .all_byte => .leaf_u8,
            .all_int => .leaf_i64,
            .all_float => .leaf_f64,
            .all_char => if (self.max_codepoint <= std.math.maxInt(u8))
                .leaf_char1
            else if (self.max_codepoint <= std.math.maxInt(u16))
                .leaf_char2
            else
                .leaf_char4,
            .all_symbol => .leaf_symbol,
        };
    }

    /// The representation holding two typed leaves' elements; usable at
    /// compile time.
    pub fn joinKinds(left: HeapKind, right: HeapKind) HeapKind {
        return ofKind(left).join(ofKind(right)).heapKind();
    }
};

pub const MaterializeResult = poll.Progress(Value);

/// Exact-size resumable construction for a typed leaf. The source remains
/// caller-owned until completion; the destination never relocates.
fn ExactSliceMaterializer(comptime Source: type, comptime kind: HeapKind) type {
    return struct {
        const Self = @This();
        pub const owned_disposal: heap.OwnedDisposal = .retire;

        allocator: std.mem.Allocator,
        source: []const Source,
        builder: ?heap.ListBuilder(kind) = null,
        index: usize = 0,
        complete: bool = false,

        pub fn init(allocator: std.mem.Allocator, source: []const Source) Self {
            return .{ .allocator = allocator, .source = source };
        }
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.builder == null);
            self.* = undefined;
        }
        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            if (self.builder) |*builder| builder.retirePartial(releases);
        }
        pub fn advance(self: *Self, work: *poll.WorkBudget) error{OutOfMemory}!MaterializeResult {
            std.debug.assert(!self.complete);
            if (self.builder == null)
                self.builder = try .init(
                    self.allocator,
                    self.source.len,
                    initialCapacity(self.source.len),
                );
            const end = self.index + work.take(self.source.len - self.index);
            @memcpy(self.builder.?.items()[self.index..end], self.source[self.index..end]);
            self.index = end;
            if (self.index != self.source.len) return .pending;
            const header = self.builder.?.finish();
            self.builder = null;
            self.complete = true;
            return .{ .complete = .{ .list = header } };
        }
    };
}

pub const ByteListMaterializer = ExactSliceMaterializer(u8, .leaf_u8);
pub const I64Materializer = ExactSliceMaterializer(i64, .leaf_i64);
pub const F64Materializer = ExactSliceMaterializer(f64, .leaf_f64);
pub const SymbolMaterializer = ExactSliceMaterializer(u32, .leaf_symbol);

pub const CodepointMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    source: []const u32,
    phase: enum { profile, fill, complete } = .profile,
    index: usize = 0,
    max_codepoint: u32 = 0,
    provenance_namespace: heap.CodeProvenanceNamespace = .none,
    builder: ?heap.AnyListBuilder = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u32) CodepointMaterializer {
        return .{ .allocator = allocator, .source = source };
    }
    pub fn initCode(
        allocator: std.mem.Allocator,
        source: []const u32,
        provenance_namespace: heap.CodeProvenanceNamespace,
    ) CodepointMaterializer {
        return .{
            .allocator = allocator,
            .source = source,
            .provenance_namespace = provenance_namespace,
        };
    }
    pub fn deinit(self: *CodepointMaterializer) void {
        std.debug.assert(self.builder == null);
        self.* = undefined;
    }
    pub fn retire(self: *CodepointMaterializer, releases: *heap.ReleaseDomain) void {
        if (self.builder) |*builder| builder.retirePartial(releases);
    }
    pub fn advance(self: *CodepointMaterializer, work: *poll.WorkBudget) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(self.phase != .complete);
        while (true) switch (self.phase) {
            .profile => {
                if (self.index == self.source.len) {
                    const kind: HeapKind = if (self.max_codepoint <= std.math.maxInt(u8))
                        .leaf_char1
                    else if (self.max_codepoint <= std.math.maxInt(u16))
                        .leaf_char2
                    else
                        .leaf_char4;
                    self.builder = try .initCode(
                        self.allocator,
                        kind,
                        self.source.len,
                        initialCapacity(self.source.len),
                        self.provenance_namespace,
                    );
                    self.phase = .fill;
                    self.index = 0;
                    continue;
                }
                if (!work.spend()) return .pending;
                self.max_codepoint = @max(self.max_codepoint, self.source[self.index]);
                self.index += 1;
            },
            .fill => {
                const end = self.index + work.take(self.source.len - self.index);
                while (self.index != end) : (self.index += 1)
                    self.builder.?.writeCodepoint(self.index, self.source[self.index]);
                if (self.index != self.source.len) return .pending;
                const header = self.builder.?.finish();
                self.builder = null;
                self.phase = .complete;
                return .{ .complete = .{ .list = header } };
            },
            .complete => unreachable,
        };
        return .pending;
    }
};

/// The single specialization traversal for ordinary value lists. Blocking
/// constructors and scheduler drivers differ only in who supplies the budget.
pub const ValueMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    source: union(enum) { borrowed: []const Value, owned: heap.OwnedValueBuffer },
    phase: enum { profile, fill, complete } = .profile,
    index: usize = 0,
    item_profile: ListProfile = .{},
    provenance_namespace: heap.CodeProvenanceNamespace = .none,
    builder: ?heap.AnyListBuilder = null,

    pub fn init(allocator: std.mem.Allocator, source: []const Value) ValueMaterializer {
        return .{ .allocator = allocator, .source = .{ .borrowed = source } };
    }
    /// Consumes the initialized buffer on success; this constructor cannot fail.
    /// Generic publication transfers its storage rather than retaining cells again.
    pub fn initOwned(allocator: std.mem.Allocator, source: heap.OwnedValueBuffer) ValueMaterializer {
        return .{ .allocator = allocator, .source = .{ .owned = source } };
    }
    fn values(self: *const ValueMaterializer) []const Value {
        return switch (self.source) {
            .borrowed => |items| items,
            .owned => |*items| items.values(),
        };
    }
    fn retireSource(self: *ValueMaterializer) void {
        if (self.source == .owned) self.source.owned.deinit();
        self.source = .{ .borrowed = &.{} };
    }
    pub fn initCode(
        allocator: std.mem.Allocator,
        source: []const Value,
        provenance_namespace: heap.CodeProvenanceNamespace,
    ) ValueMaterializer {
        return .{
            .allocator = allocator,
            .source = .{ .borrowed = source },
            .provenance_namespace = provenance_namespace,
        };
    }
    pub fn deinit(self: *ValueMaterializer) void {
        std.debug.assert(self.builder == null);
        self.retireSource();
        self.* = undefined;
    }
    pub fn retire(self: *ValueMaterializer, releases: *heap.ReleaseDomain) void {
        if (self.builder) |*builder| builder.retirePartial(releases);
        self.retireSource();
    }
    pub fn advance(
        self: *ValueMaterializer,
        work: *poll.WorkBudget,
    ) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(self.phase != .complete);
        // Both passes take a granted run per transition and charge one unit per
        // element they actually visit: profiling usually settles on `mixed` at
        // the first element of a nested list, and must not bill the rest.
        while (!work.exhausted()) switch (self.phase) {
            .profile => {
                const items = self.values();
                if (self.index == items.len) {
                    if (try self.beginFill()) |result| return .{ .complete = result };
                    continue;
                }
                const run = items[self.index..][0..@min(items.len - self.index, work.remaining)];
                var profile = self.item_profile;
                var visited: usize = 0;
                while (visited != run.len and profile.kind != .mixed) : (visited += 1)
                    profile = profile.add(run[visited]);
                _ = work.take(visited);
                self.item_profile = profile;
                self.index = if (profile.kind == .mixed) items.len else self.index + visited;
            },
            .fill => {
                const items = self.values();
                if (self.index == items.len) return self.finish();
                const granted = work.take(items.len - self.index);
                self.builder.?.writeValues(self.index, items[self.index..][0..granted]);
                self.index += granted;
            },
            .complete => unreachable,
        };
        if (self.phase == .profile and self.index == self.values().len) {
            if (try self.beginFill()) |result| return .{ .complete = result };
        }
        if (self.phase == .fill and self.index == self.values().len) return self.finish();
        return .pending;
    }
    fn beginFill(self: *ValueMaterializer) error{OutOfMemory}!?Value {
        if (self.source == .owned and (self.item_profile.kind == .mixed or self.item_profile.kind == .empty)) {
            const result = self.source.owned.takeList();
            self.source = .{ .borrowed = &.{} };
            self.phase = .complete;
            return result;
        }
        const kind = self.item_profile.heapKind();
        var builder = try heap.AnyListBuilder.initCode(
            self.allocator,
            kind,
            self.values().len,
            initialCapacity(self.values().len),
            self.provenance_namespace,
        );
        if (kind == .generic_spine) switch (builder) {
            .generic => |*generic| generic.setLen(0),
            else => unreachable,
        };
        self.builder = builder;
        self.phase = .fill;
        self.index = 0;
        return null;
    }
    fn finish(self: *ValueMaterializer) MaterializeResult {
        const header = self.builder.?.finish();
        self.builder = null;
        self.phase = .complete;
        return .{ .complete = .{ .list = header } };
    }
};

/// Representation-sensitive generic-spine construction for code roots.
pub const GenericValueMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    source: []const Value,
    provenance_namespace: heap.CodeProvenanceNamespace,
    builder: ?heap.ListBuilder(.generic_spine) = null,
    index: usize = 0,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const Value) GenericValueMaterializer {
        return initCode(allocator, source, .none);
    }
    pub fn initCode(
        allocator: std.mem.Allocator,
        source: []const Value,
        provenance_namespace: heap.CodeProvenanceNamespace,
    ) GenericValueMaterializer {
        return .{
            .allocator = allocator,
            .source = source,
            .provenance_namespace = provenance_namespace,
        };
    }
    pub fn deinit(self: *GenericValueMaterializer) void {
        std.debug.assert(self.builder == null);
        self.* = undefined;
    }
    pub fn retire(self: *GenericValueMaterializer, releases: *heap.ReleaseDomain) void {
        if (self.builder) |*builder| builder.retirePartial(releases);
    }
    pub fn advance(self: *GenericValueMaterializer, work: *poll.WorkBudget) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(!self.complete);
        if (self.builder == null) {
            var builder = try heap.ListBuilder(.generic_spine).initCode(
                self.allocator,
                self.source.len,
                initialCapacity(self.source.len),
                self.provenance_namespace,
            );
            builder.setLen(0);
            self.builder = builder;
        }
        const end = self.index + work.take(self.source.len - self.index);
        while (self.index != end) : (self.index += 1) {
            const item = self.source[self.index];
            heap.retainValue(item);
            self.builder.?.items()[self.index] = item;
            self.builder.?.setLen(self.index + 1);
        }
        if (self.index != self.source.len) return .pending;
        const header = self.builder.?.finish();
        self.builder = null;
        self.complete = true;
        return .{ .complete = .{ .list = header } };
    }
};

pub fn fromValues(
    allocator: std.mem.Allocator,
    source: []const Value,
) error{OutOfMemory}!Value {
    var cursor = ValueMaterializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

/// Test and tooling hook for constructing a logically ordinary list without
/// construction specialization.
pub fn fromValuesGeneric(
    allocator: std.mem.Allocator,
    source: []const Value,
) error{OutOfMemory}!Value {
    var cursor = GenericValueMaterializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

pub fn fromI64Slice(
    allocator: std.mem.Allocator,
    source: []const i64,
) error{OutOfMemory}!Value {
    var cursor = I64Materializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

pub fn fromU8Slice(
    allocator: std.mem.Allocator,
    source: []const u8,
) error{OutOfMemory}!Value {
    var cursor = ByteListMaterializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

/// ECL has no NaN value; every boundary that turns outside bits into floats
/// rejects one, so a caller here never holds one.
pub fn fromF64Slice(
    allocator: std.mem.Allocator,
    source: []const f64,
) error{OutOfMemory}!Value {
    for (source) |item| std.debug.assert(!std.math.isNan(item));
    var cursor = F64Materializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

pub fn fromCodepoints(
    allocator: std.mem.Allocator,
    source: []const u32,
) error{OutOfMemory}!Value {
    var cursor = CodepointMaterializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

pub fn emptyLike(
    allocator: std.mem.Allocator,
    source: Value,
) error{ OutOfMemory, NotAList }!Value {
    var builder = try heap.AnyListBuilder.init(allocator, (try listHeader(source)).kind(), 0, 0);
    return .{ .list = builder.finish() };
}

pub fn fromSymbolIds(
    allocator: std.mem.Allocator,
    source: []const u32,
) error{OutOfMemory}!Value {
    var cursor = SymbolMaterializer.init(allocator, source);
    var work = poll.unbounded();
    const result = try poll.driveFallible(Value, &cursor, .{&work});
    cursor.deinit();
    return result;
}

pub fn len(collection: Value) error{NotAList}!usize {
    const header = try listHeader(collection);
    return @intCast(header.length());
}

/// Returns a borrowed cell. Heap children remain owned by the list.
pub fn at(collection: Value, index: usize) error{ NotAList, IndexOutOfBounds }!Value {
    const header = try listHeader(collection);
    const used: usize = @intCast(header.length());
    if (index >= used) return error.IndexOutOfBounds;
    return atUnchecked(collection, index);
}

/// Internal fast path for callers that already proved list-ness and bounds.
pub fn atUnchecked(collection: Value, index: usize) Value {
    const header = collection.list;
    return switch (header.kind()) {
        .generic_spine => heap.valuesConst(header)[index],
        .leaf_u8 => .{ .int = heap.u8s(header)[index] },
        .leaf_i64 => .{ .int = heap.i64s(header)[index] },
        .leaf_f64 => .{ .float = heap.f64s(header)[index] },
        .leaf_char1 => .{ .char = heap.chars8(header)[index] },
        .leaf_char2 => .{ .char = heap.chars16(header)[index] },
        .leaf_char4 => .{ .char = heap.chars32(header)[index] },
        .leaf_symbol => .{ .symbol = heap.symbols(header)[index] },
        .dict, .task, .module, .port, .reserved_mask => unreachable,
    };
}

fn listHeader(collection: Value) error{NotAList}!*ListHandle {
    return switch (collection) {
        .list => |header| switch (header.kind()) {
            .generic_spine,
            .leaf_u8,
            .leaf_i64,
            .leaf_f64,
            .leaf_char1,
            .leaf_char2,
            .leaf_char4,
            .leaf_symbol,
            => header,
            .dict, .task, .module, .port, .reserved_mask => error.NotAList,
        },
        .int, .float, .char, .symbol, .word, .dict, .task, .module, .port => error.NotAList,
    };
}

fn initialCapacity(used: usize) usize {
    return growCapacity(@max(used, 1));
}

fn growCapacity(minimum: usize) usize {
    var result: usize = 4;
    while (result < minimum) result = std.math.mul(usize, result, 2) catch return minimum;
    return result;
}

fn constructionFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const child = try fromValues(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer cleanup.releaseValue(child);
    const parent = try fromValues(allocator, &.{ child, .{ .word = .{ .name = 7 } } });
    defer cleanup.releaseValue(parent);
    const generic = try fromValuesGeneric(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer cleanup.releaseValue(generic);
    const ints = try fromI64Slice(allocator, &.{ 1, 2 });
    defer cleanup.releaseValue(ints);
    const bytes = try fromU8Slice(allocator, &.{ 0, 255 });
    defer cleanup.releaseValue(bytes);
    const floats = try fromF64Slice(allocator, &.{ 1.0, 2.0 });
    defer cleanup.releaseValue(floats);
    const chars = try fromCodepoints(allocator, &.{ 'a', 0x100, 0x10000 });
    defer cleanup.releaseValue(chars);
    const symbols = try fromSymbolIds(allocator, &.{ 1, 2 });
    defer cleanup.releaseValue(symbols);
}

test "constructors exhaust allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        constructionFailureProbe,
        .{},
    );
}

test "blocking and resumable list construction share specialization behavior" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const mixed = [_]Value{
        .{ .int = 1 },
        .{ .float = 2.5 },
        .{ .char = 'x' },
        .{ .symbol = 7 },
        .{ .word = .{ .name = 9 } },
    };
    const widened_ints = [_]Value{
        .{ .int = 1 },
        .{ .int = 256 },
        .{ .int = 2 },
    };
    const wide_chars = [_]Value{
        .{ .char = 'x' },
        .{ .char = 0x10000 },
        .{ .char = 0x100 },
    };
    const cases = [_]struct {
        source: []const Value,
        kind: HeapKind,
    }{
        .{ .source = &mixed, .kind = .generic_spine },
        .{ .source = &widened_ints, .kind = .leaf_i64 },
        .{ .source = &wide_chars, .kind = .leaf_char4 },
    };

    for (cases) |case| {
        const blocking = try fromValues(allocator, case.source);
        defer cleanup.releaseValue(blocking);
        var cursor = ValueMaterializer.init(allocator, case.source);
        var pending: usize = 0;
        const resumed = while (true) {
            var step: poll.WorkBudget = .init(1);
            switch (try cursor.advance(&step)) {
                .pending => pending += 1,
                .complete => |result| break result,
            }
        };
        cursor.deinit();
        defer cleanup.releaseValue(resumed);

        try std.testing.expect(pending > case.source.len);
        try std.testing.expectEqual(case.kind, blocking.list.kind());
        try std.testing.expectEqual(blocking.list.kind(), resumed.list.kind());
        try std.testing.expectEqual(try len(blocking), try len(resumed));
        for (case.source, 0..) |expected, index| {
            try std.testing.expectEqual(expected, try at(blocking, index));
            try std.testing.expectEqual(expected, try at(resumed, index));
        }
    }
}
