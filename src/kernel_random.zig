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
//! "Lemire's (with an extra tweak from me)" — an implementation choice, not a
//! stability contract — and these sequences are a language-level promise
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
const Machine = machine.Machine;
const MachineError = machine.MachineError;

/// The golden-ratio odd constant SplitMix64 advances by; reused here as the
/// per-counter stride so consecutive counters land in unrelated sub-streams.
const gamma: u64 = 0x9E3779B97F4A7C15;

pub fn intForModule(evaluator: *Machine) MachineError!void {
    return randInt(evaluator);
}

pub fn intsForModule(evaluator: *Machine) MachineError!void {
    return randInts(evaluator);
}

pub fn floatForModule(evaluator: *Machine) MachineError!void {
    return randFloat(evaluator);
}

pub fn entropyForModule(evaluator: *Machine) MachineError!void {
    return entropy(evaluator);
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

fn stateValue(evaluator: *Machine, state: State) error{OutOfMemory}!Value {
    const items = [2]Value{
        .{ .int = @bitCast(state.key) },
        .{ .int = @bitCast(state.counter) },
    };
    var materializer = list.ValueMaterializer.init(evaluator.allocator(), &items);
    defer materializer.retire(evaluator.releaseDomain());
    return poll_api.driveFallible(Value, &materializer, .{2});
}

fn popState(evaluator: *Machine) MachineError!State {
    var item = try evaluator.popValue();
    defer item.deinit();
    return State.decode(item.borrow()) orelse
        evaluator.typeError("a generator state of two integers");
}

/// The two rejections read differently: a non-integer never could have been a
/// count, while an integer below the minimum is a count that is out of range.
fn popCount(evaluator: *Machine, minimum: i64, what: []const u8) MachineError!u64 {
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

fn randInt(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const bound = try popCount(evaluator, 1, "a positive bound");
    const state = try popState(evaluator);
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(1)));
    try evaluator.pushOwned(.{ .int = @bitCast(boundedDraw(state, 0, bound)) });
}

fn randFloat(evaluator: *Machine) MachineError!void {
    try evaluator.require(1);
    const state = try popState(evaluator);
    try evaluator.pushOwned(try stateValue(evaluator, state.advanced(1)));
    try evaluator.pushOwned(.{ .float = floatDraw(state, 0) });
}

fn randInts(evaluator: *Machine) MachineError!void {
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
        return evaluator.pushOwned(try list.fromValues(evaluator.allocator(), &.{}));
    }
    // Every element of a draw vector is an int: the output representation is
    // known before the first draw, so the fill writes the typed buffer directly
    // and nothing is profiled afterwards.
    const writer = try heap.LeafWriter(.leaf_i64).init(evaluator.allocator(), @intCast(count));
    try evaluator.startDriver(DrawDriver{
        .state = state,
        .bound = bound,
        .writer = .init(writer),
        .cursor = flat.FlatCursor.init(@intCast(count)),
    });
}

/// Fills an exact-size typed draw vector under the ordinary kernel budget.
/// Because element `i` comes from counter `+ i`, a resumed fill needs no replay
/// of what earlier turns produced, and because every element is an int the fill
/// writes `leaf_i64` storage directly rather than boxing a cell per draw and
/// profiling the result afterwards.
const DrawDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: State,
    bound: u64,
    writer: heap.Owned(heap.LeafWriter(.leaf_i64)),
    cursor: flat.FlatCursor,

    pub fn advance(evaluator: *Machine, self: *DrawDriver) MachineError!machine.WorkProgress {
        const context = support.Context{ .evaluator = evaluator };
        var block: [flat.block_size]i64 = undefined;
        const range = try self.cursor.nextRange(context) orelse
            return .{ .output = self.writer.borrowMut().finish() };
        var offset: usize = 0;
        while (offset != range.len()) {
            const piece = flat.blockRange(range, offset);
            for (piece.start..piece.end) |index| {
                block[index - piece.start] = @bitCast(boundedDraw(self.state, index, self.bound));
            }
            self.writer.borrowMut().writeRange(piece.start, block[0..piece.len()]);
            offset += piece.len();
        }
        if (!self.cursor.complete()) return .yielded;
        return .{ .output = self.writer.borrowMut().finish() };
    }
};

/// The one impure word. Gated exactly like the filesystem: without the host
/// capability there is no entropy to read, which is also what keeps in-process
/// test sessions deterministic.
fn entropy(evaluator: *Machine) MachineError!void {
    const io = evaluator.unit.inherited.host_io orelse
        return evaluator.fail(.io, "entropy is unavailable");
    var bytes: [8]u8 = undefined;
    std.Io.randomSecure(io, &bytes) catch
        return evaluator.fail(.io, "entropy is unavailable");
    try evaluator.pushOwned(.{ .int = @bitCast(std.mem.readInt(u64, &bytes, .little)) });
}
