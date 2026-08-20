//! Shared typed machinery for monomorphic flat-leaf kernels.
//!
//! Three pieces live here and nothing else does:
//!
//!   * `FlatCursor` — an absolute logical position plus the rule for choosing
//!     the next half-open range. A range is bounded by the caller's remaining
//!     kernel budget and by the kernel quantum, is charged before it runs, and
//!     an incomplete operation yields once at that chunk boundary rather than
//!     once per element.
//!   * `Block` and the fault protocol — a bounded staging block with one fault
//!     flag. A block that faults is replayed through the same scalar semantics
//!     the generic path uses, so the reported index, kind, message, and data are
//!     the scalar path's. Nothing is stored until a block is known clean, which
//!     is what lets a result share an input's buffer without destroying the
//!     evidence the replay needs.
//!   * `Family` — the comptime loop generator. One instantiation per
//!     (element in, element in, element out) triple, with the operation's body
//!     inlined, so the loop the CPU runs has no representation switch in it.
//!
//! This file imports the heap capabilities and `kernel_support`, and nothing
//! else on purpose: `list.atUnchecked` and `OwnedValueBuffer` are the boxed
//! route, and a typed loop that could reach them would not be a typed loop.
const std = @import("std");
const heap = @import("heap.zig");
const support = @import("kernel_support.zig");

const MachineError = support.MachineError;

/// One half-open range of logical element positions.
pub const Chunk = struct {
    start: usize,
    end: usize,

    pub fn len(self: Chunk) usize {
        return self.end - self.start;
    }
};

/// The staging block size. Small enough to live on the native stack and to keep
/// a faulting replay short; large enough that the per-block bookkeeping is
/// noise next to the loop body.
pub const block_size: usize = 256;

/// An exact-width character result selected after a bounded profiling pass.
/// Text and arithmetic kernels share this capability so width selection and
/// narrowing stores have one implementation. The union switch happens once
/// per block; each copy loop itself is monomorphic.
pub const CodepointWriter = union(enum) {
    char1: heap.LeafWriter(.leaf_char1),
    char2: heap.LeafWriter(.leaf_char2),
    char4: heap.LeafWriter(.leaf_char4),

    pub const owned_disposal: heap.OwnedDisposal = .retire;

    pub fn init(
        allocator: std.mem.Allocator,
        length: usize,
        max_codepoint: u32,
    ) error{OutOfMemory}!CodepointWriter {
        if (max_codepoint <= std.math.maxInt(u8)) return .{ .char1 = try .init(allocator, length) };
        if (max_codepoint <= std.math.maxInt(u16)) return .{ .char2 = try .init(allocator, length) };
        return .{ .char4 = try .init(allocator, length) };
    }

    pub fn writeCodepoints(self: *CodepointWriter, offset: usize, source: []const u32) void {
        std.debug.assert(source.len <= block_size);
        switch (self.*) {
            .char1 => |*writer| {
                var block: [block_size]u8 = undefined;
                for (source, block[0..source.len]) |codepoint, *out| out.* = @intCast(codepoint);
                writer.writeRange(offset, block[0..source.len]);
            },
            .char2 => |*writer| {
                var block: [block_size]u16 = undefined;
                for (source, block[0..source.len]) |codepoint, *out| out.* = @intCast(codepoint);
                writer.writeRange(offset, block[0..source.len]);
            },
            .char4 => |*writer| writer.writeRange(offset, source),
        }
    }

    pub fn finish(self: *CodepointWriter) heap.Value {
        return switch (self.*) {
            inline else => |*writer| writer.finish(),
        };
    }

    pub fn retire(self: *CodepointWriter, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            inline else => |*writer| writer.retirePartial(releases),
        }
    }
};

/// Chooses the next range without touching the budget, so the rule itself is
/// testable in isolation. Returns null exactly when the operation is complete.
///
/// At least one element is always planned: a zero-length range would let a
/// cursor spin without progress when the interval is exhausted, and the charge
/// itself is what resets that interval.
pub fn planRange(index: usize, length: usize, remaining: usize, quantum: usize) ?Chunk {
    std.debug.assert(index <= length);
    std.debug.assert(quantum != 0);
    if (index == length) return null;
    const available = length - index;
    const budget = @max(@min(remaining, quantum), 1);
    const count = @min(available, budget);
    return .{ .start = index, .end = index + count };
}

/// An absolute position in one typed operation. Cursors carry the absolute
/// index rather than a per-chunk local one so a fault reports a logical index
/// and a resumption cannot silently restart an interval.
pub const FlatCursor = struct {
    index: usize = 0,
    length: usize,

    pub fn init(length: usize) FlatCursor {
        return .{ .length = length };
    }

    pub fn complete(self: *const FlatCursor) bool {
        return self.index == self.length;
    }

    pub fn remainingElements(self: *const FlatCursor) usize {
        return self.length - self.index;
    }

    /// Reserves and charges the next range. The charge goes through the one
    /// seam that owns `Unit.kernel_fuel`, which polls at the interval boundary,
    /// so cancellation surfaces here as an error rather than as a missed check.
    /// Element accounting is deliberately conservative: a copied or gathered
    /// element is charged like a computed one.
    pub fn nextRange(self: *FlatCursor, context: support.Context) MachineError!?Chunk {
        const plan = planRange(
            self.index,
            self.length,
            context.remaining(),
            support.poll_quantum,
        ) orelse return null;
        try context.advance(plan.len());
        self.index = plan.end;
        return plan;
    }
};

/// A staged block of results plus the one bit that decides whether they may be
/// stored. `faulted` is accumulated over the whole block rather than checked per
/// element, which is what keeps the clean path branch-light.
pub fn Block(comptime Element: type) type {
    return struct {
        const Self = @This();

        items: [block_size]Element,
        len: usize = 0,
        faulted: bool = false,

        pub fn init() Self {
            // SAFETY: `len` starts at zero, and every producer initializes the
            // complete visible prefix before increasing it.
            return .{ .items = undefined };
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.faulted = false;
        }

        pub fn written(self: *const Self) []const Element {
            return self.items[0..self.len];
        }
    };
}

/// The monomorphic loop family for one element-type triple.
///
/// `body` is the operation, inlined: it answers `null` for a fault so the loop
/// carries one flag instead of an error union per element. `Rescan` is the
/// shared scalar semantics; the loop calls it only for a block that faulted.
pub fn Family(comptime Left: type, comptime Right: type, comptime Out: type) type {
    return struct {
        pub const Staging = Block(Out);

        /// leaf x leaf over one range. Both slices are indexed by the absolute
        /// logical position, which is what makes a resumed chunk read the same
        /// elements a fault replay would.
        pub fn binary(
            comptime body: fn (Left, Right) ?Out,
            left: []const Left,
            right: []const Right,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= left.len and range.end <= right.len);
            var faulted = false;
            for (range.start..range.end) |index| {
                const result = body(left[index], right[index]);
                block.items[index - range.start] = result orelse std.mem.zeroes(Out);
                faulted = faulted or result == null;
            }
            block.len = range.len();
            block.faulted = faulted;
        }

        /// leaf x scalar. The scalar operand is a value, not a materialized
        /// broadcast: the loop reads it from a register, stride zero.
        pub fn binaryScalarRight(
            comptime body: fn (Left, Right) ?Out,
            left: []const Left,
            right: Right,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= left.len);
            var faulted = false;
            for (range.start..range.end) |index| {
                const result = body(left[index], right);
                block.items[index - range.start] = result orelse std.mem.zeroes(Out);
                faulted = faulted or result == null;
            }
            block.len = range.len();
            block.faulted = faulted;
        }

        /// scalar x leaf, the mirror image; operand order is preserved because
        /// the operations are not all commutative.
        pub fn binaryScalarLeft(
            comptime body: fn (Left, Right) ?Out,
            left: Left,
            right: []const Right,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= right.len);
            var faulted = false;
            for (range.start..range.end) |index| {
                const result = body(left, right[index]);
                block.items[index - range.start] = result orelse std.mem.zeroes(Out);
                faulted = faulted or result == null;
            }
            block.len = range.len();
            block.faulted = faulted;
        }

        pub fn unary(
            comptime body: fn (Left) ?Out,
            operand: []const Left,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= operand.len);
            var faulted = false;
            for (range.start..range.end) |index| {
                const result = body(operand[index]);
                block.items[index - range.start] = result orelse std.mem.zeroes(Out);
                faulted = faulted or result == null;
            }
            block.len = range.len();
            block.faulted = faulted;
        }
    };
}

/// The block size a cursor may plan for at once: staging is bounded by the
/// block, so a range longer than one block is executed one block at a time
/// within the same charged chunk.
pub fn blockRange(range: Chunk, offset: usize) Chunk {
    std.debug.assert(offset <= range.len());
    const start = range.start + offset;
    const end = @min(start + block_size, range.end);
    return .{ .start = start, .end = end };
}

test "range planning bounds by budget quantum and remaining length" {
    // A complete operation plans nothing.
    try std.testing.expect(planRange(4, 4, 100, 100) == null);
    // The shortest of remaining length, budget, and quantum wins.
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 3 }, planRange(0, 3, 100, 100).?);
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 8 }, planRange(0, 100, 8, 100).?);
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 5 }, planRange(0, 100, 8, 5).?);
    // Absolute positions, not per-chunk ones.
    try std.testing.expectEqual(Chunk{ .start = 90, .end = 100 }, planRange(90, 100, 32, 32).?);
    // An exhausted interval still makes progress; the charge resets it.
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 1 }, planRange(0, 100, 0, 32).?);
    // ceil(n / budget) advances, never O(n): 100 elements at budget 8 is 13.
    var cursor = FlatCursor.init(100);
    var advances: usize = 0;
    while (planRange(cursor.index, cursor.length, 8, 32)) |plan| : (advances += 1) {
        cursor.index = plan.end;
    }
    try std.testing.expectEqual(@as(usize, 13), advances);
    try std.testing.expect(cursor.complete());
}

test "blocks stage results and a fault anywhere blocks the whole block" {
    const Ints = Family(i64, i64, i64);
    const add = struct {
        fn body(left: i64, right: i64) ?i64 {
            return std.math.add(i64, left, right) catch null;
        }
    }.body;
    var block = Ints.Staging.init();
    const left = [_]i64{ 1, 2, 3, 4 };
    const right = [_]i64{ 10, 20, 30, 40 };
    Ints.binary(add, &left, &right, .{ .start = 1, .end = 4 }, &block);
    try std.testing.expect(!block.faulted);
    try std.testing.expectEqualSlices(i64, &.{ 22, 33, 44 }, block.written());

    // A scalar operand is read without a broadcast buffer.
    Ints.binaryScalarRight(add, &left, 100, .{ .start = 0, .end = 2 }, &block);
    try std.testing.expectEqualSlices(i64, &.{ 101, 102 }, block.written());
    Ints.binaryScalarLeft(add, 1000, &right, .{ .start = 2, .end = 4 }, &block);
    try std.testing.expectEqualSlices(i64, &.{ 1030, 1040 }, block.written());

    // One overflow marks the block, whatever its position, and the clean
    // elements are not published from a faulted block.
    const overflowing = [_]i64{ std.math.maxInt(i64), 1 };
    Ints.binary(add, &overflowing, &[_]i64{ 1, 1 }, .{ .start = 0, .end = 2 }, &block);
    try std.testing.expect(block.faulted);
    Ints.binary(add, &overflowing, &[_]i64{ 0, 1 }, .{ .start = 0, .end = 2 }, &block);
    try std.testing.expect(!block.faulted);

    const Negate = Family(i64, void, i64);
    const negate = struct {
        fn body(operand: i64) ?i64 {
            return std.math.sub(i64, 0, operand) catch null;
        }
    }.body;
    var unary_block = Negate.Staging.init();
    Negate.unary(negate, &[_]i64{ 1, -2, 3 }, .{ .start = 0, .end = 3 }, &unary_block);
    try std.testing.expectEqualSlices(i64, &.{ -1, 2, -3 }, unary_block.written());
    Negate.unary(negate, &[_]i64{std.math.minInt(i64)}, .{ .start = 0, .end = 1 }, &unary_block);
    try std.testing.expect(unary_block.faulted);
}

test "a long range is executed one bounded block at a time" {
    const range = Chunk{ .start = 0, .end = block_size * 2 + 7 };
    var offset: usize = 0;
    var blocks: usize = 0;
    while (offset != range.len()) : (blocks += 1) {
        const block = blockRange(range, offset);
        try std.testing.expect(block.len() <= block_size);
        offset += block.len();
    }
    try std.testing.expectEqual(@as(usize, 3), blocks);
}

fn typedWriteFailureProbe(allocator: std.mem.Allocator) !void {
    // The typed output path a flat loop uses: one exact-size writer, block
    // stores, one consuming publish. The staging block itself never allocates.
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var writer = try heap.LeafWriter(.leaf_i64).init(allocator, block_size + 1);
    errdefer writer.retirePartial(cleanup.domain());
    const Ints = Family(i64, i64, i64);
    var block = Ints.Staging.init();
    var source: [block_size + 1]i64 = undefined;
    for (&source, 0..) |*item, index| item.* = @intCast(index);
    const range = Chunk{ .start = 0, .end = source.len };
    var offset: usize = 0;
    while (offset != range.len()) {
        const piece = blockRange(range, offset);
        Ints.binaryScalarRight(
            struct {
                fn body(left: i64, right: i64) ?i64 {
                    return left + right;
                }
            }.body,
            &source,
            1,
            piece,
            &block,
        );
        writer.writeRange(piece.start, block.written());
        offset += piece.len();
    }
    const published = writer.finish();
    cleanup.releaseValue(published);
}

test "typed flat writes exhaust allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        typedWriteFailureProbe,
        .{},
    );
}
