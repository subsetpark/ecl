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

    /// Reserves and charges the next range. The charge lands on the unit's one
    /// kernel budget, whose refill polls at the interval boundary,
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

/// A bounded staged block of results. Whether a checked producer completed is
/// returned as a nominal status instead of being correlated with this storage.
pub fn Block(comptime Element: type) type {
    return struct {
        const Self = @This();

        items: [block_size]Element,
        len: usize = 0,

        pub fn init() Self {
            // SAFETY: `len` starts at zero, and every producer initializes the
            // complete visible prefix before increasing it.
            return .{ .items = undefined };
        }
        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        pub fn written(self: *const Self) []const Element {
            return self.items[0..self.len];
        }
    };
}

pub const CheckedStatus = enum { clean, faulted };

/// Where a checked vector loop writes. A fresh buffer is unread until
/// published, so a block may be stored before its faults are known. A buffer
/// that is also an operand holds the input at every position not yet stored.
pub const Placement = enum { fresh, over_operands };

/// How a checked vector range ended. `faulted` names the first position a
/// replay must scan, which is also the first whose operands are still the
/// input's: the range start for a fresh output, and the first faulting vector
/// for one written over its operands.
pub const CheckedOutcome = union(enum) { clean, faulted: usize };

/// Monomorphic loops whose element types prove that the operation cannot fault.
pub fn InfallibleFamily(comptime Left: type, comptime Right: type, comptime Out: type) type {
    return struct {
        pub const Staging = Block(Out);

        /// leaf x leaf over one range. Both slices are indexed by the absolute
        /// logical position, which is what makes a resumed chunk read the same
        /// elements a fault replay would.
        pub fn binary(
            comptime body: fn (Left, Right) Out,
            left: []const Left,
            right: []const Right,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= left.len and range.end <= right.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(left[index], right[index]);
            }
            block.len = range.len();
        }

        /// leaf x scalar. The scalar operand remains one value; the loop reads
        /// it from a register at stride zero without materializing a broadcast.
        pub fn binaryScalarRight(
            comptime body: fn (Left, Right) Out,
            left: []const Left,
            right: Right,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= left.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(left[index], right);
            }
            block.len = range.len();
        }

        /// scalar x leaf, the mirror image; operand order is preserved because
        /// the operations are not all commutative.
        pub fn binaryScalarLeft(
            comptime body: fn (Left, Right) Out,
            left: Left,
            right: []const Right,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= right.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(left, right[index]);
            }
            block.len = range.len();
        }

        pub fn unary(
            comptime body: fn (Left) Out,
            operand: []const Left,
            range: Chunk,
            block: *Staging,
        ) void {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= operand.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(operand[index]);
            }
            block.len = range.len();
        }
    };
}

/// Scalar-classified checked loops. A failure returns before the staged prefix
/// becomes publishable; the caller replays the original inputs for diagnostics.
pub fn CheckedFamily(comptime Left: type, comptime Right: type, comptime Out: type) type {
    return struct {
        pub const Staging = Block(Out);
        const Fault = error{Fault};

        pub fn binary(
            comptime body: fn (Left, Right) Fault!Out,
            left: []const Left,
            right: []const Right,
            range: Chunk,
            block: *Staging,
        ) CheckedStatus {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= left.len and range.end <= right.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(left[index], right[index]) catch return .faulted;
            }
            block.len = range.len();
            return .clean;
        }

        pub fn binaryScalarRight(
            comptime body: fn (Left, Right) Fault!Out,
            left: []const Left,
            right: Right,
            range: Chunk,
            block: *Staging,
        ) CheckedStatus {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= left.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(left[index], right) catch return .faulted;
            }
            block.len = range.len();
            return .clean;
        }

        pub fn binaryScalarLeft(
            comptime body: fn (Left, Right) Fault!Out,
            left: Left,
            right: []const Right,
            range: Chunk,
            block: *Staging,
        ) CheckedStatus {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= right.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(left, right[index]) catch return .faulted;
            }
            block.len = range.len();
            return .clean;
        }

        pub fn unary(
            comptime body: fn (Left) Fault!Out,
            operand: []const Left,
            range: Chunk,
            block: *Staging,
        ) CheckedStatus {
            block.reset();
            std.debug.assert(range.len() <= block_size);
            std.debug.assert(range.end <= operand.len);
            for (range.start..range.end) |index| {
                block.items[index - range.start] = body(operand[index]) catch return .faulted;
            }
            block.len = range.len();
            return .clean;
        }
    };
}

/// One vector result and a lane mask covering its faults. A checked body's
/// mask may over-approximate, so the hot loop can test it once per block; the
/// paired exact mask decides whether a nominated block really faulted.
///
/// The mask is all-ones or zero per lane in an integer as wide as `MaskLane`,
/// the shape a vector compare produces. A `@Vector(lanes, bool)` crossing the
/// body boundary is lowered on x86 as a packed bitmask and re-expanded, which
/// costs more than the arithmetic it guards.
pub fn MaskedVector(comptime Element: type, comptime MaskLane: type, comptime lanes: comptime_int) type {
    return struct {
        values: @Vector(lanes, Element),
        faults: @Vector(lanes, MaskLane),
    };
}

/// Explicit vector loops for a same-width input pair. Full vectors use the
/// target's suggested width; the scalar callback owns the bounded tail.
///
/// Each loop writes one range into `dest`, exactly `range.len()` elements: the
/// output's own range, which may also be the storage of an operand. A loop
/// reads every operand at a position before it stores that position.
pub fn VectorFamily(
    comptime Left: type,
    comptime Right: type,
    comptime Out: type,
    comptime lanes: comptime_int,
) type {
    return struct {
        pub const Staging = Block(Out);
        const LeftVector = @Vector(lanes, Left);
        const RightVector = @Vector(lanes, Right);
        const OutVector = @Vector(lanes, Out);
        const FaultMask = @Vector(lanes, bool);
        const MaskLane = @Int(.unsigned, @bitSizeOf(Left));
        const LaneMask = @Vector(lanes, MaskLane);
        pub const Masked = MaskedVector(Out, MaskLane, lanes);

        /// A lane condition in the mask shape `Masked` carries.
        pub fn mask(condition: FaultMask) LaneMask {
            const none: LaneMask = @splat(0);
            const all: LaneMask = @splat(std.math.maxInt(MaskLane));
            return @select(MaskLane, condition, all, none);
        }
        const Fault = error{Fault};

        /// The three bodies of a checked operation. `vector` may report a
        /// superset of the faulting lanes; `exact` reports precisely the lanes
        /// `scalar` rejects, because a block declared faulted is replayed
        /// through the scalar authority, which must then find its fault.
        pub const Checked = struct {
            vector: fn (LeftVector, RightVector) Masked,
            exact: fn (LeftVector, RightVector) FaultMask,
            scalar: fn (Left, Right) Fault!Out,
        };

        fn storeVector(dest: []Out, offset: usize, values: OutVector) void {
            dest[offset..][0..lanes].* = values;
        }

        /// Vectors a loop handles per iteration. Spelling a group out lets the
        /// target pair its loads and stores and pay loop control once per
        /// group; one vector per iteration ran at about half the bandwidth.
        const unroll = 4;

        /// Calls `step.visit` with the offset of each of `vectors` whole
        /// vectors, in order, `unroll` at a time and then the rest.
        inline fn forEachVector(vectors: usize, step: anytype) void {
            const grouped = vectors / unroll * unroll;
            var vector: usize = 0;
            while (vector != grouped) : (vector += unroll) {
                inline for (0..unroll) |member| step.visit((vector + member) * lanes);
            }
            while (vector != vectors) : (vector += 1) step.visit(vector * lanes);
        }

        const LeafLeaf = struct {
            left: []const Left,
            right: []const Right,

            fn vectors(self: LeafLeaf, index: usize) struct { LeftVector, RightVector } {
                return .{ self.left[index..][0..lanes].*, self.right[index..][0..lanes].* };
            }

            fn scalars(self: LeafLeaf, index: usize) struct { Left, Right } {
                return .{ self.left[index], self.right[index] };
            }
        };

        const LeafScalar = struct {
            left: []const Left,
            right: Right,
            broadcast: RightVector,

            fn vectors(self: LeafScalar, index: usize) struct { LeftVector, RightVector } {
                return .{ self.left[index..][0..lanes].*, self.broadcast };
            }

            fn scalars(self: LeafScalar, index: usize) struct { Left, Right } {
                return .{ self.left[index], self.right };
            }
        };

        const ScalarLeaf = struct {
            left: Left,
            right: []const Right,
            broadcast: LeftVector,

            fn vectors(self: ScalarLeaf, index: usize) struct { LeftVector, RightVector } {
                return .{ self.broadcast, self.right[index..][0..lanes].* };
            }

            fn scalars(self: ScalarLeaf, index: usize) struct { Left, Right } {
                return .{ self.left, self.right[index] };
            }
        };

        fn infallibleRange(
            comptime vector_body: fn (LeftVector, RightVector) OutVector,
            comptime scalar_body: fn (Left, Right) Out,
            source: anytype,
            range: Chunk,
            dest: []Out,
        ) void {
            std.debug.assert(dest.len == range.len());
            const vector_end = range.start + range.len() / lanes * lanes;
            const Step = struct {
                source: @TypeOf(source),
                start: usize,
                dest: []Out,
                inline fn visit(self: @This(), offset: usize) void {
                    const a, const b = self.source.vectors(self.start + offset);
                    storeVector(self.dest, offset, vector_body(a, b));
                }
            };
            forEachVector(range.len() / lanes, Step{ .source = source, .start = range.start, .dest = dest });
            for (vector_end..range.end) |index| {
                const a, const b = source.scalars(index);
                dest[index - range.start] = scalar_body(a, b);
            }
        }

        /// Into a fresh output, accumulates the possibly over-approximate fault
        /// masks across the whole range and reduces them once, instead of
        /// reducing and branching on every vector. Only a nominated range pays
        /// a second, exact pass, which keeps `.faulted` meaning a real scalar
        /// fault. Over its operands, a vector is stored only once known clean,
        /// so a fault leaves the input intact from that vector on.
        fn checkedRange(
            comptime placement: Placement,
            comptime body: Checked,
            source: anytype,
            range: Chunk,
            dest: []Out,
        ) CheckedOutcome {
            std.debug.assert(dest.len == range.len());
            if (placement == .over_operands) return checkedOverOperands(body, source, range, dest);
            // Counting whole vectors keeps one induction variable; stepping an
            // index by `lanes` against `index + lanes <= end` kept two, and the
            // loop control cost more than the arithmetic.
            const vectors = range.len() / lanes;
            const vector_end = range.start + vectors * lanes;
            var suspect: LaneMask = @splat(0);
            const Step = struct {
                source: @TypeOf(source),
                start: usize,
                dest: []Out,
                suspect: *LaneMask,
                inline fn visit(self: @This(), offset: usize) void {
                    const a, const b = self.source.vectors(self.start + offset);
                    const result = body.vector(a, b);
                    self.suspect.* |= result.faults;
                    storeVector(self.dest, offset, result.values);
                }
            };
            forEachVector(vectors, Step{ .source = source, .start = range.start, .dest = dest, .suspect = &suspect });
            for (vector_end..range.end) |index| {
                const a, const b = source.scalars(index);
                dest[index - range.start] = body.scalar(a, b) catch return .{ .faulted = range.start };
            }
            if (@reduce(.Or, suspect) == 0) return .clean;
            for (0..vectors) |vector| {
                const a, const b = source.vectors(range.start + vector * lanes);
                if (@reduce(.Or, body.exact(a, b))) return .{ .faulted = range.start };
            }
            return .clean;
        }

        /// Vectors computed before one mask test over a buffer written in
        /// place. They wait in registers until the group is known clean;
        /// testing every vector cost more than its arithmetic.
        const over_operands_group = 8;

        fn checkedOverOperands(comptime body: Checked, source: anytype, range: Chunk, dest: []Out) CheckedOutcome {
            const group_width = over_operands_group * lanes;
            const groups = range.len() / group_width;
            const vectors = range.len() / lanes;
            const vector_end = range.start + vectors * lanes;
            for (0..groups) |group| {
                const base = group * group_width;
                var values: [over_operands_group]OutVector = undefined;
                var suspect: LaneMask = @splat(0);
                inline for (0..over_operands_group) |member| {
                    const a, const b = source.vectors(range.start + base + member * lanes);
                    const result = body.vector(a, b);
                    values[member] = result.values;
                    suspect |= result.faults;
                }
                if (@reduce(.Or, suspect) != 0) {
                    for (0..over_operands_group) |member| {
                        const offset = base + member * lanes;
                        const a, const b = source.vectors(range.start + offset);
                        if (@reduce(.Or, body.exact(a, b))) return .{ .faulted = range.start + offset };
                        storeVector(dest, offset, values[member]);
                    }
                    continue;
                }
                inline for (0..over_operands_group) |member| storeVector(dest, base + member * lanes, values[member]);
            }
            for (groups * over_operands_group..vectors) |vector| {
                const offset = vector * lanes;
                const a, const b = source.vectors(range.start + offset);
                const result = body.vector(a, b);
                if (@reduce(.Or, result.faults) != 0 and @reduce(.Or, body.exact(a, b)))
                    return .{ .faulted = range.start + offset };
                storeVector(dest, offset, result.values);
            }
            for (vector_end..range.end) |index| {
                const a, const b = source.scalars(index);
                dest[index - range.start] = body.scalar(a, b) catch return .{ .faulted = index };
            }
            return .clean;
        }

        pub fn binary(
            comptime vector_body: fn (LeftVector, RightVector) OutVector,
            comptime scalar_body: fn (Left, Right) Out,
            left: []const Left,
            right: []const Right,
            range: Chunk,
            dest: []Out,
        ) void {
            std.debug.assert(range.end <= left.len and range.end <= right.len);
            infallibleRange(vector_body, scalar_body, LeafLeaf{ .left = left, .right = right }, range, dest);
        }

        pub fn binaryScalarRight(
            comptime vector_body: fn (LeftVector, RightVector) OutVector,
            comptime scalar_body: fn (Left, Right) Out,
            left: []const Left,
            right: Right,
            range: Chunk,
            dest: []Out,
        ) void {
            std.debug.assert(range.end <= left.len);
            const source: LeafScalar = .{ .left = left, .right = right, .broadcast = @splat(right) };
            infallibleRange(vector_body, scalar_body, source, range, dest);
        }

        pub fn binaryScalarLeft(
            comptime vector_body: fn (LeftVector, RightVector) OutVector,
            comptime scalar_body: fn (Left, Right) Out,
            left: Left,
            right: []const Right,
            range: Chunk,
            dest: []Out,
        ) void {
            std.debug.assert(range.end <= right.len);
            const source: ScalarLeaf = .{ .left = left, .right = right, .broadcast = @splat(left) };
            infallibleRange(vector_body, scalar_body, source, range, dest);
        }

        pub fn checkedBinary(
            comptime body: Checked,
            placement: Placement,
            left: []const Left,
            right: []const Right,
            range: Chunk,
            dest: []Out,
        ) CheckedOutcome {
            std.debug.assert(range.end <= left.len and range.end <= right.len);
            const source: LeafLeaf = .{ .left = left, .right = right };
            return switch (placement) {
                inline else => |selected| checkedRange(selected, body, source, range, dest),
            };
        }

        pub fn checkedBinaryScalarRight(
            comptime body: Checked,
            placement: Placement,
            left: []const Left,
            right: Right,
            range: Chunk,
            dest: []Out,
        ) CheckedOutcome {
            std.debug.assert(range.end <= left.len);
            const source: LeafScalar = .{ .left = left, .right = right, .broadcast = @splat(right) };
            return switch (placement) {
                inline else => |selected| checkedRange(selected, body, source, range, dest),
            };
        }

        pub fn checkedBinaryScalarLeft(
            comptime body: Checked,
            placement: Placement,
            left: Left,
            right: []const Right,
            range: Chunk,
            dest: []Out,
        ) CheckedOutcome {
            std.debug.assert(range.end <= right.len);
            const source: ScalarLeaf = .{ .left = left, .right = right, .broadcast = @splat(left) };
            return switch (placement) {
                inline else => |selected| checkedRange(selected, body, source, range, dest),
            };
        }

        pub fn unary(
            comptime vector_body: fn (LeftVector) OutVector,
            comptime scalar_body: fn (Left) Out,
            operand: []const Left,
            range: Chunk,
            dest: []Out,
        ) void {
            std.debug.assert(dest.len == range.len());
            std.debug.assert(range.end <= operand.len);
            const vector_end = range.start + range.len() / lanes * lanes;
            const Step = struct {
                operand: []const Left,
                start: usize,
                dest: []Out,
                inline fn visit(self: @This(), offset: usize) void {
                    const a: LeftVector = self.operand[self.start + offset ..][0..lanes].*;
                    storeVector(self.dest, offset, vector_body(a));
                }
            };
            forEachVector(range.len() / lanes, Step{ .operand = operand, .start = range.start, .dest = dest });
            for (vector_end..range.end) |index| {
                dest[index - range.start] = scalar_body(operand[index]);
            }
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

/// Why an index cannot select from a collection, and where it is.
pub const IndexFault = struct {
    kind: enum { negative, out_of_bounds },
    position: usize,
};

/// The fault of the first index in `indices` that is negative or not below
/// `count`, with its position in `indices`, or null when every index selects. Read as unsigned, a negative
/// index is also past `count`, so the common case is one vector compare per
/// lane group folded into a flag; only a flagged slice is rescanned in order,
/// so the reported fault is the first one a sequential check would meet. A
/// byte index cannot reach a collection longer than a byte's range.
pub fn firstIndexFault(comptime Index: type, indices: []const Index, count: usize) ?IndexFault {
    comptime std.debug.assert(Index == u8 or Index == i64);
    if (Index == u8 and count > std.math.maxInt(u8)) return null;
    const Lane = if (Index == u8) u8 else u64;
    const limit: Lane = @intCast(count);
    const lanes = comptime std.simd.suggestVectorLength(Lane) orelse 1;
    const group = lanes * 4;
    const LaneVector = @Vector(lanes, Lane);
    const none: LaneVector = @splat(0);
    const all: LaneVector = @splat(std.math.maxInt(Lane));
    const bound: LaneVector = @splat(limit);
    var outside = none;
    var offset: usize = 0;
    while (offset + group <= indices.len) : (offset += group) {
        inline for (0..4) |member| {
            const lane_values: LaneVector = @bitCast(indices[offset + member * lanes ..][0..lanes].*);
            outside |= @select(Lane, lane_values >= bound, all, none);
        }
    }
    var flagged = @reduce(.Or, outside) != 0;
    for (indices[offset..]) |index| flagged = flagged or @as(Lane, @bitCast(index)) >= limit;
    if (!flagged) return null;
    for (indices, 0..) |index, position| {
        if (index < 0) return .{ .kind = .negative, .position = position };
        if (@as(Lane, @bitCast(index)) >= limit) return .{ .kind = .out_of_bounds, .position = position };
    }
    unreachable;
}

test "range planning bounds by budget quantum and remaining length" {
    // A complete operation plans nothing.
    try std.testing.expect(planRange(4, 4, 100, 100) == null);
    // The shortest of remaining length, budget, and quantum wins.
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 3 }, planRange(0, 3, 100, 100).?);
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 8 }, planRange(0, 100, 8, 100).?);
    try std.testing.expectEqual(Chunk{ .start = 0, .end = 5 }, planRange(0, 100, 8, 5).?);
    // Positions are absolute across the full input.
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

test "infallible and checked blocks have distinct publication outcomes" {
    const Ints = InfallibleFamily(i64, i64, i64);
    const add = struct {
        fn body(left: i64, right: i64) i64 {
            return left + right;
        }
    }.body;
    var block = Ints.Staging.init();
    const left = [_]i64{ 1, 2, 3, 4 };
    const right = [_]i64{ 10, 20, 30, 40 };
    Ints.binary(add, &left, &right, .{ .start = 1, .end = 4 }, &block);
    try std.testing.expectEqualSlices(i64, &.{ 22, 33, 44 }, block.written());

    // A scalar operand is read without a broadcast buffer.
    Ints.binaryScalarRight(add, &left, 100, .{ .start = 0, .end = 2 }, &block);
    try std.testing.expectEqualSlices(i64, &.{ 101, 102 }, block.written());
    Ints.binaryScalarLeft(add, 1000, &right, .{ .start = 2, .end = 4 }, &block);
    try std.testing.expectEqualSlices(i64, &.{ 1030, 1040 }, block.written());

    // One overflow marks the block, whatever its position, and the clean
    // elements are not published from a faulted block.
    const CheckedInts = CheckedFamily(i64, i64, i64);
    const checked_add = struct {
        fn body(a: i64, b: i64) error{Fault}!i64 {
            return std.math.add(i64, a, b) catch error.Fault;
        }
    }.body;
    var checked_block = CheckedInts.Staging.init();
    const overflowing = [_]i64{ std.math.maxInt(i64), 1 };
    try std.testing.expectEqual(
        CheckedStatus.faulted,
        CheckedInts.binary(checked_add, &overflowing, &[_]i64{ 1, 1 }, .{ .start = 0, .end = 2 }, &checked_block),
    );
    try std.testing.expectEqual(
        CheckedStatus.clean,
        CheckedInts.binary(checked_add, &overflowing, &[_]i64{ 0, 1 }, .{ .start = 0, .end = 2 }, &checked_block),
    );

    const Negate = CheckedFamily(i64, void, i64);
    const negate = struct {
        fn body(operand: i64) error{Fault}!i64 {
            return std.math.sub(i64, 0, operand) catch error.Fault;
        }
    }.body;
    var unary_block = Negate.Staging.init();
    try std.testing.expectEqual(
        CheckedStatus.clean,
        Negate.unary(negate, &[_]i64{ 1, -2, 3 }, .{ .start = 0, .end = 3 }, &unary_block),
    );
    try std.testing.expectEqualSlices(i64, &.{ -1, 2, -3 }, unary_block.written());
    try std.testing.expectEqual(
        CheckedStatus.faulted,
        Negate.unary(negate, &[_]i64{std.math.minInt(i64)}, .{ .start = 0, .end = 1 }, &unary_block),
    );
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
    const Ints = InfallibleFamily(i64, i64, i64);
    var block = Ints.Staging.init();
    var source: [block_size + 1]i64 = undefined;
    for (&source, 0..) |*item, index| item.* = @intCast(index);
    const range = Chunk{ .start = 0, .end = source.len };
    var offset: usize = 0;
    while (offset != range.len()) {
        const piece = blockRange(range, offset);
        Ints.binaryScalarRight(
            struct {
                fn body(left: i64, right: i64) i64 {
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
