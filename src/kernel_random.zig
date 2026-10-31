//! Counter-based pseudorandom kernels and the one entropy capability.
//!
//! Generator state is plain ECL data — a two-int list `[key counter]` — and
//! every word here is a pure function of it. Identical states therefore
//! produce identical results, which is what makes these values rather than
//! effects: a program is reproducible unless it explicitly mixes in
//! `rand.entropy`.
//!
//! The construction is counter-based rather than iterated: draw `i` comes from
//! `SplitMix64.init(key +% ((counter + i) *% gamma))`, so element `i` of a
//! vector depends only on its own index. Filling is order-independent, a
//! bounded refill needs no replay, and two tasks can split a stream by using
//! distinct keys with no coordination.
//!
//! **Not cryptographic.** SplitMix64 is a fast mixer with a 64-bit period per
//! key; `rand.entropy` is the only word that reaches the host CSPRNG.
//!
//! The bounding and float conversion below are deliberately *ours* rather than
//! `std.Random`'s helpers. std's bounded-int routine documents itself as
//! "Lemire's (with an extra tweak from me)," which is only an implementation
//! choice. These sequences are a language-level stability promise
//! pinned by the snapshot corpus.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const poll_api = @import("poll.zig");
const support = @import("kernel_support.zig");
const flat = @import("kernel_flat.zig");
const Value = value.Value;
const Unit = machine.Unit;
const MachineError = machine.MachineError;

/// The golden-ratio odd constant SplitMix64 advances by; reused here as the
/// per-counter stride so consecutive counters land in unrelated sub-streams.
const gamma: u64 = 0x9E3779B97F4A7C15;

pub fn intForModule(evaluator: *Unit) MachineError!void {
    return randInt(evaluator);
}

pub fn intsForModule(evaluator: *Unit) MachineError!void {
    return randInts(evaluator);
}

pub fn floatForModule(evaluator: *Unit) MachineError!void {
    return randFloat(evaluator);
}

pub fn entropyForModule(evaluator: *Unit) MachineError!void {
    return entropy(evaluator);
}

pub fn dealForModule(evaluator: *Unit) MachineError!void {
    return randDeal(evaluator);
}

pub fn shuffleForModule(evaluator: *Unit) MachineError!void {
    return randShuffle(evaluator);
}

/// One decoded generator state. The ECL representation stays a plain list;
/// this is only the host-side view of it.
const State = struct {
    key: u64,
    counter: u64,

    fn decode(item: Value) ?State {
        if (item != .list or item.list.length() != 2) return null;
        const key = list.atUnchecked(item, 0);
        const counter = list.atUnchecked(item, 1);
        if (key != .int or counter != .int) return null;
        return .{ .key = @bitCast(key.int), .counter = @bitCast(counter.int) };
    }

    fn advanced(self: State, draws: u64) State {
        return .{ .key = self.key, .counter = self.counter +% draws };
    }

    /// The sub-stream for one absolute draw index.
    fn mixer(self: State, index: u64) std.Random.SplitMix64 {
        return .init(self.key +% ((self.counter +% index) *% gamma));
    }
};

/// Uniform in `[0, bound)` by rejection, so no residue class is favoured the
/// way a bare modulo would favour the low ones. Rejections pull further from
/// the *same* sub-stream, which keeps draw `i` a function of `i` alone.
fn boundedDraw(state: State, index: u64, bound: u64) u64 {
    var stream = state.mixer(index);
    const threshold = (0 -% bound) % bound;
    var drawn = stream.next();
    while (drawn < threshold) drawn = stream.next();
    return drawn % bound;
}

/// 53 significant bits, the most a f64 represents exactly, scaled into [0,1).
fn floatDraw(state: State, index: u64) f64 {
    var stream = state.mixer(index);
    return @as(f64, @floatFromInt(stream.next() >> 11)) * 0x1.0p-53;
}

fn stateValue(evaluator: *Unit, state: State) error{OutOfMemory}!Value {
    const items = [2]Value{
        .{ .int = @bitCast(state.key) },
        .{ .int = @bitCast(state.counter) },
    };
    var materializer = list.ValueMaterializer.init(evaluator.allocator, &items);
    defer materializer.retire(evaluator.releases);
    var work = poll_api.unbounded();
    return poll_api.driveFallible(Value, &materializer, .{&work});
}

fn popState(evaluator: *Unit) MachineError!State {
    var item = try evaluator.popValue();
    defer item.deinit();
    return State.decode(item.borrow()) orelse
        evaluator.typeError("a generator state of two integers");
}

/// The two rejections read differently: a non-integer never could have been a
/// count, while an integer below the minimum is a count that is out of range.
fn popCount(evaluator: *Unit, minimum: i64, what: []const u8) MachineError!u64 {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (item.borrow() != .int) return evaluator.typeError(what);
    if (item.borrow().int < minimum) return evaluator.failFmt(
        .domain,
        "{s} expected {s}, not {d}",
        .{ evaluator.activeWordName(), what, item.borrow().int },
    );
    return @intCast(item.borrow().int);
}

fn randInt(evaluator: *Unit) MachineError!void {
    try evaluator.require(2);
    const bound = try popCount(evaluator, 1, "a positive bound");
    const state = try popState(evaluator);
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(1)));
    try evaluator.pushOwned(.{ .int = @bitCast(boundedDraw(state, 0, bound)) });
}

fn randFloat(evaluator: *Unit) MachineError!void {
    try evaluator.require(1);
    const state = try popState(evaluator);
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(1)));
    try evaluator.pushOwned(.{ .float = floatDraw(state, 0) });
}

fn randInts(evaluator: *Unit) MachineError!void {
    try evaluator.require(3);
    const bound = try popCount(evaluator, 1, "a positive bound");
    const count = try popCount(evaluator, 0, "a nonnegative draw count");
    const state = try popState(evaluator);
    // The advanced state is pushed before the vector so the driver's single
    // output lands on top, matching ( state n m -- state' list ).
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(count)));
    // A zero-length draw has no element to type, and the representation of an
    // empty result is the value layer's existing choice: it stays the generic
    // empty list this word has always produced.
    if (count == 0) {
        return evaluator.pushOwned(try list.fromValues(evaluator.allocator, &.{}));
    }
    // Every element of a draw vector is an int: the output representation is
    // known before the first draw, so the fill writes the typed buffer directly
    // and nothing is profiled afterwards.
    try support.Kernel(DrawKernel).run(evaluator, .{}, .{ .state = state, .bound = bound }, @intCast(count));
}

/// Fills an exact-size typed draw vector under the ordinary kernel budget.
/// Because element `i` comes from counter `+ i`, a resumed fill needs no replay
/// of what earlier ranges produced, and because every element is an int the
/// fill writes `leaf_i64` storage directly rather than boxing a cell per draw
/// and profiling the result afterwards.
const DrawKernel = struct {
    pub const arity = 0;
    pub const Params = struct { state: State, bound: u64 };
    pub const Output = support.LeafResult(.leaf_i64);
    pub const result: ?support.ResultShape = .{ .kind = .leaf_i64, .overwritable = &.{} };

    pub fn chunk(params: Params, _: [0]Value, output: *Output, range: flat.Chunk, _: support.Context) MachineError!void {
        for (output.range(range.start, range.len()), range.start..) |*slot, index|
            slot.* = @bitCast(boundedDraw(params.state, index, params.bound));
    }

    pub const finish = Output.finish;
};

/// The displaced indices of a partial Fisher-Yates over a virtual range: an
/// open-addressed table sized once from the number of positions dealt, so a
/// deal never allocates in proportion to its pool and never rehashes.
const Displacements = struct {
    allocator: std.mem.Allocator,
    /// `std.math.maxInt(u64)` marks an empty bucket; a virtual index can
    /// never be that large, since a pool fits in `i64`.
    keys: []u64,
    values: []u64,

    const empty_key = std.math.maxInt(u64);

    fn init(allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!Displacements {
        // Each dealt position displaces at most one index, and a quarter-full
        // table keeps probes short.
        const wanted = std.math.mul(usize, count, 4) catch return error.OutOfMemory;
        const capacity = std.math.ceilPowerOfTwo(usize, @max(wanted, 8)) catch return error.OutOfMemory;
        const keys = try allocator.alloc(u64, capacity);
        errdefer allocator.free(keys);
        const values = try allocator.alloc(u64, capacity);
        @memset(keys, empty_key);
        return .{ .allocator = allocator, .keys = keys, .values = values };
    }

    fn slot(self: *const Displacements, key: u64) usize {
        var position: usize = @intCast(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) & (self.keys.len - 1));
        while (self.keys[position] != empty_key and self.keys[position] != key)
            position = (position + 1) & (self.keys.len - 1);
        return position;
    }

    fn lookup(self: *const Displacements, index: u64) u64 {
        const position = self.slot(index);
        return if (self.keys[position] == empty_key) index else self.values[position];
    }

    fn record(self: *Displacements, index: u64, displaced: u64) void {
        const position = self.slot(index);
        self.keys[position] = index;
        self.values[position] = displaced;
    }

    fn deinit(self: *Displacements) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
    }
};

/// A partial Fisher-Yates over the virtual range `0..pool`, one position per
/// step: position `i` swaps with `i + draw(i)`, and only displaced indices are
/// recorded, so work and memory follow the number of positions dealt, never
/// the pool. Draw `i` comes from counter `+ i`, like every other kernel here,
/// so the state advances by the count.
const Dealer = struct {
    displaced: Displacements,

    fn init(allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!Dealer {
        return .{ .displaced = try Displacements.init(allocator, count) };
    }

    /// Deals positions `range.start..range.end` into `out`; the ranges
    /// arrive in order.
    fn deal(self: *Dealer, state: State, pool: u64, range: flat.Chunk, out: []i64) void {
        for (out, range.start..) |*slot, position| {
            const index: u64 = @intCast(position);
            const chosen = index + boundedDraw(state, index, pool - index);
            const drawn = self.displaced.lookup(chosen);
            if (chosen != index) self.displaced.record(chosen, self.displaced.lookup(index));
            slot.* = @bitCast(drawn);
        }
    }

    fn deinit(self: *Dealer) void {
        self.displaced.deinit();
    }
};

/// The dealer as a kernel output: the permutation goes straight into the
/// typed result.
const DealOutput = struct {
    dealer: Dealer,
    writer: heap.LeafWriter(.leaf_i64),

    pub fn retire(self: *DealOutput, releases: *heap.ReleaseDomain) void {
        self.dealer.deinit();
        self.writer.retire(releases);
    }
};

/// `( state count pool -- state results )`: `count` distinct ints below `pool`.
fn randDeal(evaluator: *Unit) MachineError!void {
    try evaluator.require(3);
    const pool = try popCount(evaluator, 0, "a nonnegative pool size");
    const count = try popCount(evaluator, 0, "a nonnegative draw count");
    if (count > pool) return evaluator.fail(.domain, "rand.deal cannot draw more values than the pool holds");
    const state = try popState(evaluator);
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(count)));
    if (count == 0) {
        return evaluator.pushOwned(try list.fromValues(evaluator.allocator, &.{}));
    }
    try support.Kernel(DealKernel).run(evaluator, .{}, .{ .state = state, .pool = pool }, @intCast(count));
}

/// The dealer as a kernel: ranges are charged to the budget in order, and the
/// displaced-index map lives in the output across them.
const DealKernel = struct {
    pub const arity = 0;
    pub const Params = struct { state: State, pool: u64 };
    pub const Output = DealOutput;

    pub fn prepare(evaluator: *Unit, _: [0]Value, _: Params, length: usize) error{OutOfMemory}!Output {
        var dealer = try Dealer.init(evaluator.allocator, length);
        errdefer dealer.deinit();
        return .{ .dealer = dealer, .writer = try heap.LeafWriter(.leaf_i64).init(evaluator.allocator, length) };
    }

    pub fn chunk(params: Params, _: [0]Value, output: *Output, range: flat.Chunk, _: support.Context) MachineError!void {
        output.dealer.deal(params.state, params.pool, range, output.writer.unpublishedRange(range.start, range.len()));
    }

    pub fn finish(output: *Output) Value {
        output.dealer.deinit();
        return output.writer.finish();
    }
};

/// `( state values -- state values )`: a uniformly selected permutation of a
/// list. One kernel in two phases: a full deal over the list's indices, then
/// a gather of the elements through that permutation, so every element kind
/// is permuted and a typed leaf keeps its representation. The state advances
/// by the length.
fn randShuffle(evaluator: *Unit) MachineError!void {
    try evaluator.require(2);
    var values = try evaluator.popValue();
    defer values.deinit();
    if (values.borrow() != .list) return evaluator.typeError("a list to shuffle");
    const state = try popState(evaluator);
    const length: usize = @intCast(values.borrow().list.length());
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(@intCast(length))));
    if (length == 0) return evaluator.pushOwned(values.take());
    const source_kind = values.borrow().list.kind();
    inline for (leaf_kinds) |candidate| {
        if (candidate == source_kind)
            return support.Kernel(ShuffleKernel(candidate)).run(evaluator, .{&values}, state, length);
    }
    return support.Kernel(ShuffleKernel(null)).run(evaluator, .{&values}, state, length);
}

const leaf_kinds = [_]value.HeapKind{
    .leaf_u8,
    .leaf_i64,
    .leaf_f64,
    .leaf_char1,
    .leaf_char2,
    .leaf_char4,
};

/// `kind` is the source's leaf representation, which the result shares, or
/// null for a boxed source, whose elements are retained into a new spine.
fn ShuffleKernel(comptime kind: ?value.HeapKind) type {
    return struct {
        pub const arity = 1;
        pub const Params = State;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            dealer: Dealer,
            permutation: []i64,
            phase: enum { deal, gather },
            result: if (kind) |leaf| heap.LeafWriter(leaf) else heap.OwnedValueBuffer,

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.dealer.deinit();
                self.allocator.free(self.permutation);
                if (kind != null) self.result.retire(releases) else self.result.deinit();
            }
        };

        pub fn prepare(evaluator: *Unit, _: [1]Value, _: State, length: usize) error{OutOfMemory}!Output {
            var dealer = try Dealer.init(evaluator.allocator, length);
            errdefer dealer.deinit();
            const permutation = try evaluator.allocator.alloc(i64, length);
            errdefer evaluator.allocator.free(permutation);
            return .{
                .allocator = evaluator.allocator,
                .dealer = dealer,
                .permutation = permutation,
                .phase = .deal,
                .result = if (kind) |leaf|
                    try heap.LeafWriter(leaf).init(evaluator.allocator, length)
                else
                    try heap.OwnedValueBuffer.init(evaluator.releases, length),
            };
        }

        pub fn chunk(state: State, operands: [1]Value, output: *Output, range: flat.Chunk, _: support.Context) MachineError!void {
            const source = operands[0];
            switch (output.phase) {
                .deal => output.dealer.deal(state, @intCast(source.list.length()), range, output.permutation[range.start..range.end]),
                .gather => {
                    const permutation = output.permutation[range.start..range.end];
                    if (kind) |leaf| {
                        const elements = heap.leafElements(leaf, source.list);
                        for (output.result.unpublishedRange(range.start, range.len()), permutation) |*slot, position|
                            slot.* = elements[@intCast(position)];
                    } else {
                        for (permutation) |position|
                            output.result.appendBorrowed(list.atUnchecked(source, @intCast(position)));
                    }
                },
            }
        }

        /// The deal is over when its cursor is; the gather then runs over
        /// the same length.
        pub fn next(_: support.Context, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .deal => {
                    output.phase = .gather;
                    return output.permutation.len;
                },
                .gather => return null,
            }
        }

        pub fn finish(output: *Output) Value {
            output.dealer.deinit();
            output.allocator.free(output.permutation);
            return if (kind != null) output.result.finish() else output.result.takeList();
        }
    };
}

/// The one impure word reads the process CSPRNG through runtime I/O.
fn entropy(evaluator: *Unit) MachineError!void {
    const io = evaluator.inherited.runtime().host_io;
    var bytes: [8]u8 = undefined;
    std.Io.randomSecure(io, &bytes) catch
        return evaluator.fail(.io, "entropy is unavailable");
    try evaluator.pushOwned(.{ .int = @bitCast(std.mem.readInt(u64, &bytes, .little)) });
}
