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

const Profile = struct {
    kind: ElemProfile,
    max_codepoint: u32 = 0,
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
        pub fn advance(self: *Self, budget: usize) error{OutOfMemory}!MaterializeResult {
            std.debug.assert(budget != 0 and !self.complete);
            if (self.builder == null)
                self.builder = try .init(
                    self.allocator,
                    self.source.len,
                    initialCapacity(self.source.len),
                );
            const end = @min(self.index + budget, self.source.len);
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
    pub fn advance(self: *CodepointMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(budget != 0 and self.phase != .complete);
        var remaining = budget;
        while (remaining != 0) switch (self.phase) {
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
                self.max_codepoint = @max(self.max_codepoint, self.source[self.index]);
                self.index += 1;
                remaining -= 1;
            },
            .fill => {
                const end = @min(self.index + remaining, self.source.len);
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
    source: []const Value,
    phase: enum { profile, fill, complete } = .profile,
    index: usize = 0,
    item_profile: Profile = .{ .kind = .empty },
    provenance_namespace: heap.CodeProvenanceNamespace = .none,
    builder: ?heap.AnyListBuilder = null,

    pub fn init(allocator: std.mem.Allocator, source: []const Value) ValueMaterializer {
        return .{ .allocator = allocator, .source = source };
    }
    pub fn initCode(
        allocator: std.mem.Allocator,
        source: []const Value,
        provenance_namespace: heap.CodeProvenanceNamespace,
    ) ValueMaterializer {
        return .{
            .allocator = allocator,
            .source = source,
            .provenance_namespace = provenance_namespace,
        };
    }
    pub fn deinit(self: *ValueMaterializer) void {
        std.debug.assert(self.builder == null);
        self.* = undefined;
    }
    pub fn retire(self: *ValueMaterializer, releases: *heap.ReleaseDomain) void {
        if (self.builder) |*builder| builder.retirePartial(releases);
    }
    pub fn takePartial(self: *ValueMaterializer) ?Value {
        if (self.builder == null) return null;
        const header = self.builder.?.finish();
        self.builder = null;
        return .{ .list = header };
    }
    pub fn advance(self: *ValueMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(budget != 0 and self.phase != .complete);
        var remaining = budget;
        while (remaining != 0) switch (self.phase) {
            .profile => {
                if (self.index == self.source.len) {
                    try self.beginFill();
                    continue;
                }
                self.profileOne(self.source[self.index]);
                self.index += 1;
                remaining -= 1;
                if (self.item_profile.kind == .mixed) self.index = self.source.len;
            },
            .fill => {
                if (self.index == self.source.len) return self.finish();
                self.builder.?.writeValue(self.index, self.source[self.index]);
                self.index += 1;
                remaining -= 1;
            },
            .complete => unreachable,
        };
        if (self.phase == .profile and self.index == self.source.len) try self.beginFill();
        if (self.phase == .fill and self.index == self.source.len) return self.finish();
        return .pending;
    }
    fn profileOne(self: *ValueMaterializer, item: Value) void {
        if (self.index == 0) {
            self.item_profile = switch (item) {
                .int => |integer| .{
                    .kind = if (integer >= 0 and integer <= std.math.maxInt(u8)) .all_byte else .all_int,
                },
                .float => .{ .kind = .all_float },
                .char => |codepoint| .{ .kind = .all_char, .max_codepoint = codepoint },
                .symbol => .{ .kind = .all_symbol },
                .word, .list, .dict, .task, .module, .unit_plan => .{ .kind = .mixed },
            };
            return;
        }
        switch (self.item_profile.kind) {
            .empty => unreachable,
            .all_byte => {
                if (item == .int) {
                    if (item.int < 0 or item.int > std.math.maxInt(u8))
                        self.item_profile.kind = .all_int;
                } else self.item_profile.kind = .mixed;
            },
            .all_int => {
                if (item != .int) self.item_profile.kind = .mixed;
            },
            .all_float => {
                if (item != .float) self.item_profile.kind = .mixed;
            },
            .all_char => {
                if (item == .char) {
                    self.item_profile.max_codepoint = @max(self.item_profile.max_codepoint, item.char);
                } else self.item_profile.kind = .mixed;
            },
            .all_symbol => {
                if (item != .symbol) self.item_profile.kind = .mixed;
            },
            .mixed => {},
        }
    }
    fn beginFill(self: *ValueMaterializer) error{OutOfMemory}!void {
        const kind: HeapKind = switch (self.item_profile.kind) {
            .empty, .mixed => .generic_spine,
            .all_byte => .leaf_u8,
            .all_int => .leaf_i64,
            .all_float => .leaf_f64,
            .all_char => if (self.item_profile.max_codepoint <= std.math.maxInt(u8))
                .leaf_char1
            else if (self.item_profile.max_codepoint <= std.math.maxInt(u16))
                .leaf_char2
            else
                .leaf_char4,
            .all_symbol => .leaf_symbol,
        };
        var builder = try heap.AnyListBuilder.initCode(
            self.allocator,
            kind,
            self.source.len,
            initialCapacity(self.source.len),
            self.provenance_namespace,
        );
        if (kind == .generic_spine) switch (builder) {
            .generic => |*generic| generic.setLen(0),
            else => unreachable,
        };
        self.builder = builder;
        self.phase = .fill;
        self.index = 0;
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
    pub fn advance(self: *GenericValueMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(budget != 0 and !self.complete);
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
        const end = @min(self.index + budget, self.source.len);
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
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
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
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
    cursor.deinit();
    return result;
}

pub fn fromValuesGenericCode(
    allocator: std.mem.Allocator,
    source: []const Value,
    provenance_namespace: heap.CodeProvenanceNamespace,
) error{OutOfMemory}!Value {
    var cursor = GenericValueMaterializer.initCode(allocator, source, provenance_namespace);
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
    cursor.deinit();
    return result;
}

pub fn fromI64Slice(
    allocator: std.mem.Allocator,
    source: []const i64,
) error{OutOfMemory}!Value {
    var cursor = I64Materializer.init(allocator, source);
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
    cursor.deinit();
    return result;
}

pub fn fromU8Slice(
    allocator: std.mem.Allocator,
    source: []const u8,
) error{OutOfMemory}!Value {
    var cursor = ByteListMaterializer.init(allocator, source);
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
    cursor.deinit();
    return result;
}

pub fn fromF64Slice(
    allocator: std.mem.Allocator,
    source: []const f64,
) error{OutOfMemory}!Value {
    var cursor = F64Materializer.init(allocator, source);
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
    cursor.deinit();
    return result;
}

pub fn fromCodepoints(
    allocator: std.mem.Allocator,
    source: []const u32,
) error{OutOfMemory}!Value {
    var cursor = CodepointMaterializer.init(allocator, source);
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
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
    const result = try poll.driveFallible(Value, &cursor, .{std.math.maxInt(usize)});
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
        .dict, .task, .module, .unit_plan, .reserved_mask => unreachable,
    };
}

/// `collection` remains owned by the caller. The result tag states whether
/// that owner was updated or an additional root was returned.
pub fn append(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    collection: Value,
    item: Value,
) Error!heap.UpdateResult {
    const header = try listHeader(collection);
    const unique = heap.claimUniqueList(header) orelse
        return rebuildWithItem(allocator, releases, collection, item, false);

    const used: usize = @intCast(header.length());
    if (used == 0 and header.kind() == .generic_spine) {
        return rebuildWithItem(allocator, releases, collection, item, true);
    }

    const same_kind = switch (header.kind()) {
        .generic_spine => true,
        .leaf_u8 => item == .int and item.int >= 0 and item.int <= std.math.maxInt(u8),
        .leaf_i64 => item == .int,
        .leaf_f64 => item == .float,
        .leaf_char1 => item == .char and item.char <= std.math.maxInt(u8),
        .leaf_char2 => item == .char and item.char <= std.math.maxInt(u16),
        .leaf_char4 => item == .char,
        .leaf_symbol => item == .symbol,
        .dict, .task, .module, .unit_plan, .reserved_mask => return error.NotAList,
    };
    if (!same_kind) return rebuildWithItem(allocator, releases, collection, item, true);

    if (used == heap.capacity(header)) {
        const new_capacity = growCapacity(used + 1);
        try heap.replaceBuffer(allocator, unique, new_capacity);
    }
    switch (header.kind()) {
        .generic_spine => {
            heap.retainValue(item);
            heap.writeUniqueList(unique, used, item);
        },
        .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4, .leaf_symbol => heap.writeUniqueList(unique, used, item),
        .dict, .task, .module, .unit_plan, .reserved_mask => return error.NotAList,
    }
    heap.setUniqueListLength(unique, used + 1);
    return .{ .in_place = collection };
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
            .dict, .task, .module, .unit_plan, .reserved_mask => error.NotAList,
        },
        .int, .float, .char, .symbol, .word, .dict, .task, .module, .unit_plan => error.NotAList,
    };
}

fn rebuildWithItem(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    collection: Value,
    item: Value,
    adopt: bool,
) Error!heap.UpdateResult {
    const old_len = try len(collection);
    const materialized = try allocator.alloc(Value, old_len + 1);
    defer allocator.free(materialized);
    for (0..old_len) |index| materialized[index] = try at(collection, index);
    materialized[old_len] = item;
    const replacement = try fromValues(allocator, materialized);
    if (!adopt) return .{ .replacement = replacement };
    heap.adoptListRepresentationDeferred(
        releases,
        heap.claimUniqueList(collection.list).?,
        heap.claimUniqueList(replacement.list).?,
    );
    return .{ .in_place = collection };
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

fn appendFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const original = try fromValues(allocator, &.{ .{ .char = 'a' }, .{ .char = 'b' } });
    defer cleanup.releaseValue(original);
    const result = try append(allocator, cleanup.domain(), original, .{ .int = 3 });
    if (result == .replacement) cleanup.releaseValue(result.value());
}

test "constructors and append exhaust allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        constructionFailureProbe,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        appendFailureProbe,
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
        const resumed = while (true) switch (try cursor.advance(1)) {
            .pending => pending += 1,
            .complete => |result| break result,
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
