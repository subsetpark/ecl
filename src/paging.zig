//! The operand stack's floor: how far down a word may reach. A boundary or an
//! isolated application sets a hard floor; a paging application sets one that
//! lowers on demand and puts back afterwards what its quotation only looked
//! at. Everything that reads or moves the floor lives here.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll_api = @import("poll.zig");
const machine = @import("machine.zig");
const Value = value.Value;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

/// A fiber's current floor. `guard` is what an operand check compares
/// against: the base, or one past the highest returned original of the
/// innermost paging floor. It is never above the stack depth, and every
/// change to the floor goes through `set`.
pub const StackFloor = struct {
    base: usize = 0,
    /// The innermost paging floor, when the current floor is one; its
    /// `floor` then equals `base`.
    paging: ?*PagingFloor = null,
    guard: usize = 0,

    /// The floor an application or boundary sets or restores, and whether it
    /// is a paging one. `guard` follows.
    pub fn set(self: *StackFloor, base: usize, paging: ?*PagingFloor) void {
        self.base = base;
        self.paging = paging;
        self.guard = if (paging) |floor| floor.watermark() else base;
    }

    /// The current floor as something `restore` can put back.
    pub fn beneath(self: *const StackFloor) Beneath {
        return if (self.paging) |outer| .{ .paging = outer } else .{ .hard = self.base };
    }

    /// Puts back a floor that an application or boundary set another over.
    pub fn restore(self: *StackFloor, saved: Beneath) void {
        switch (saved) {
            .hard => |base| self.set(base, null),
            .paging => |outer| self.set(outer.floor, outer),
        }
    }

    /// Makes `floor` the innermost paging floor at `base`, over whatever
    /// floor is current; `restore(floor.beneath)` undoes it.
    pub fn enter(self: *StackFloor, floor: *PagingFloor, base: usize) void {
        floor.floor = base;
        floor.beneath = self.beneath();
        self.set(base, floor);
    }

    /// A shrink to `depth` that no operand check covered consumes any
    /// returned original at or above it.
    pub fn noteShrink(self: *StackFloor, depth: usize) void {
        if (depth >= self.guard) return;
        const floor = self.paging.?;
        floor.dropReturnedFrom(depth);
        self.guard = floor.watermark();
    }

    /// The hard floor beneath every paging floor: where underflow happens.
    fn hard(self: *const StackFloor) usize {
        var floor = self.paging orelse return self.base;
        while (true) switch (floor.beneath) {
            .hard => |base| return base,
            .paging => |outer| floor = outer,
        };
    }
};

/// The floor beneath the current one: a hard floor at a depth, or a paging
/// floor, whose depth is read when it is restored because a paging floor
/// moves. Whatever sets a floor over another keeps one of these.
pub const Beneath = union(enum) {
    hard: usize,
    paging: *PagingFloor,
};

/// The floor of a paging application: its quotation runs on a substack that
/// starts empty and takes operands from beneath on demand. When a word needs
/// more operands than the substack holds, the fiber retains a copy of each
/// missing value in `originals` and lowers the floor to include it, so the
/// quotation consumes exactly what its words required: the stack effect it
/// presents as a black box. Underflow remains the hard floor's beneath.
///
/// Restoring is not producing. A value `dip` took aside straight from
/// across the floor returns as the same original, recorded here by its
/// position until a later word requires it, and so does a value an inner
/// restore puts back that this floor holds as an original too: one it paged
/// for the inner floor, or one `dip` had returned to it. A finalize sweeps
/// the recorded values out before it restores its own copies, so a word
/// that only looked at a value beneath the floor did not produce it.
pub const PagingFloor = struct {
    /// This application's floor: the fiber's floor base while it is the
    /// innermost paging floor.
    floor: usize = 0,
    /// The floor this one was entered over.
    beneath: Beneath = .{ .hard = 0 },
    /// Retained copies of the paged values, the one nearest the entry first.
    /// A few live inline, so a small quotation pages without allocating.
    originals: heap.InlineList(Original, 4, .{ .value = .{ .int = 0 }, .shared = false }) = .empty,
    /// Positions of returned originals in the substack, ascending.
    returned: std.ArrayList(u32) = .empty,

    const Original = struct {
        value: Value,
        /// The floor beneath holds this value as an original as well, so a
        /// restore puts it back as that floor's returned original.
        shared: bool,
    };

    fn beneathFloor(self: *const PagingFloor) usize {
        return switch (self.beneath) {
            .hard => |base| base,
            .paging => |outer| outer.floor,
        };
    }
    /// The depth an operand check compares against while this floor is
    /// innermost: one past the highest returned original, or the floor
    /// itself.
    fn watermark(self: *const PagingFloor) usize {
        if (self.returned.items.len == 0) return self.floor;
        return @as(usize, self.returned.items[self.returned.items.len - 1]) + 1;
    }
    /// Every returned original at or above `position` is consumed now.
    fn dropReturnedFrom(self: *PagingFloor, position: usize) void {
        while (self.returned.items.len != 0 and self.returned.items[self.returned.items.len - 1] >= position)
            _ = self.returned.pop();
    }
    /// Whether `position` is a returned original: the slot `dip` is about to
    /// take, which then stays an original through its next return.
    fn takeReturnedAt(self: *PagingFloor, position: usize) bool {
        if (self.returned.items.len == 0) return false;
        if (self.returned.items[self.returned.items.len - 1] != position) return false;
        _ = self.returned.pop();
        return true;
    }
    fn retire(self: *PagingFloor, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        for (self.originals.items()) |original| releases.releaseValue(original.value);
        self.originals.deinit(allocator);
        self.returned.deinit(allocator);
    }
};

/// Makes `count` operands available across the innermost paging floor, when
/// there is one: a returned original the count reaches is consumed now, and
/// values the substack lacks are paged in from beneath. False when a hard
/// floor leaves the count short; the caller names the failure.
pub fn cover(fiber: *Fiber, count: usize) error{OutOfMemory}!bool {
    const floor = fiber.floor.paging orelse return false;
    std.debug.assert(floor.floor == fiber.floor.base);
    const held = fiber.stack.items.len - fiber.floor.base;
    if (count <= held) {
        floor.dropReturnedFrom(fiber.stack.items.len - count);
        fiber.floor.guard = floor.watermark();
        return true;
    }
    return page(fiber, floor, count - held);
}

/// Pages `needed` values across `innermost`, and across each enclosing
/// paging floor whose region cannot cover them, so every floor the values
/// crossed accounts for them. Nothing changes when a hard floor leaves the
/// count short. The copies are bounded by the requiring word's arity.
fn page(fiber: *Fiber, innermost: *PagingFloor, needed: usize) error{OutOfMemory}!bool {
    var floor = innermost;
    var deficit = needed;
    while (true) {
        try floor.originals.ensureUnusedCapacity(fiber.allocator, deficit);
        const held = floor.floor - floor.beneathFloor();
        if (deficit <= held) break;
        switch (floor.beneath) {
            .hard => return false,
            .paging => |outer| {
                deficit -= held;
                floor = outer;
            },
        }
    }
    floor = innermost;
    deficit = needed;
    while (true) {
        const held = floor.floor - floor.beneathFloor();
        // The floor beneath holds a value as an original too when it lies
        // beneath that floor, which the next round pages it across, or when
        // it is one of that floor's returned originals.
        const outer: ?*PagingFloor = switch (floor.beneath) {
            .hard => null,
            .paging => |outer| outer,
        };
        var records: usize = if (outer) |enclosing| enclosing.returned.items.len else 0;
        for (1..deficit + 1) |offset| {
            const position = floor.floor - offset;
            const item = fiber.stack.items[position];
            heap.retainValue(item);
            var shared = false;
            if (outer) |enclosing| {
                if (position < enclosing.floor) {
                    shared = true;
                } else {
                    while (records != 0 and enclosing.returned.items[records - 1] > position) records -= 1;
                    shared = records != 0 and enclosing.returned.items[records - 1] == position;
                }
            }
            floor.originals.appendAssumeCapacity(.{ .value = item, .shared = shared });
        }
        floor.floor -= deficit;
        floor.dropReturnedFrom(innermost.floor);
        if (deficit <= held) break;
        deficit -= held;
        floor = floor.beneath.paging;
    }
    // Enclosing floors that paged nothing may still hold returned originals
    // inside the region the innermost floor now covers.
    while (floor.beneath == .paging) {
        floor = floor.beneath.paging;
        floor.dropReturnedFrom(innermost.floor);
    }
    fiber.floor.set(innermost.floor, innermost);
    return true;
}

/// A value held aside from the stack, and whether it is an original of the
/// innermost paging floor.
pub const Protected = struct { item: heap.OwnedValue, original: bool };

/// Pops the top operand for `dip` to hold aside, reporting whether it is an
/// original of the innermost paging floor: paged in just now for this
/// purpose, or returned by an inner `dip`. `returnProtected` puts it back.
pub fn takeProtected(fiber: *Fiber) MachineError!Protected {
    var original = false;
    if (fiber.floor.paging) |floor| {
        const depth = fiber.stack.items.len;
        if (depth == fiber.floor.base) {
            if (!try cover(fiber, 1)) return fiber.failShort(1);
            original = true;
        } else if (floor.takeReturnedAt(depth - 1)) {
            fiber.floor.guard = floor.watermark();
            original = true;
        }
    }
    return .{ .item = try fiber.popValue(), .original = original };
}

/// Consumes `item`, recording it as a returned original when `dip` took it
/// as one and the same paging floor is still innermost.
pub fn returnProtected(fiber: *Fiber, item: Value, original: bool) error{OutOfMemory}!void {
    try fiber.pushOwned(item);
    if (original) try noteReturned(fiber, fiber.stack.items.len - 1);
}

/// Records the value at `position` as a returned original of the innermost
/// paging floor, when there is one: a value put back that the floor holds as
/// an original too, so the first operand check that reaches it consumes it
/// and a restore sweeps it out. Positions are recorded ascending, above every
/// record the floor holds.
fn noteReturned(fiber: *Fiber, position: usize) error{OutOfMemory}!void {
    const floor = fiber.floor.paging orelse return;
    std.debug.assert(position >= floor.watermark());
    try floor.returned.append(fiber.allocator, @intCast(position));
    fiber.floor.guard = position + 1;
}

/// Fails as an operand check would unless `count` values lie above the hard
/// floor, without paging any of them: `takeProtected` must still find which
/// are originals.
pub fn requireReachable(fiber: *Fiber, count: usize) MachineError!void {
    if (count > fiber.stack.items.len - fiber.floor.hard()) return fiber.failShort(count);
}

/// One in-place reversal of the stack span `[lo, hi)`, advanced under a
/// work budget. Swapping inward from both ends keeps every slot live between
/// steps, so a fiber torn down mid-reversal releases each value once.
/// Rotating a block of the stack is three reversals.
const StackReversal = struct {
    lo: usize,
    hi: usize,

    const none: StackReversal = .{ .lo = 0, .hi = 0 };

    fn of(lo: usize, hi: usize) StackReversal {
        std.debug.assert(lo <= hi);
        return .{ .lo = lo, .hi = hi };
    }

    /// Advances as far as `work` allows; true once the span is reversed.
    fn advance(self: *StackReversal, items: []Value, work: *poll_api.WorkBudget) bool {
        std.debug.assert(self.hi <= items.len);
        const granted = work.take((self.hi - self.lo) / 2);
        for (0..granted) |_| {
            self.hi -= 1;
            std.mem.swap(Value, &items[self.lo], &items[self.hi]);
            self.lo += 1;
        }
        return self.hi - self.lo < 2;
    }
};

/// One in-place sweep that carries the values at ascending stack positions
/// to the top of the stack and closes the gaps beneath them in order,
/// advanced under a work budget. Every step swaps rather than moves, so each
/// slot stays live until the caller discards the swept top.
const StackSweep = struct {
    read: usize,
    write: usize,
    /// The next position to carry up.
    next: usize = 0,

    fn from(position: usize) StackSweep {
        return .{ .read = position, .write = position };
    }

    /// Advances over the stack above the read position as far as `work`
    /// allows; true once the values at `positions` occupy the top of the
    /// stack, the values between them packed beneath in their order.
    fn advance(self: *StackSweep, items: []Value, positions: []const u32, work: *poll_api.WorkBudget) bool {
        const granted = work.take(items.len - self.read);
        for (0..granted) |_| {
            if (self.next < positions.len and positions[self.next] == self.read) {
                self.next += 1;
            } else {
                std.mem.swap(Value, &items[self.write], &items[self.read]);
                self.write += 1;
            }
            self.read += 1;
        }
        return self.read == items.len;
    }
};

/// What becomes of the region a paged quotation leaves.
pub const Placement = enum {
    /// The restored originals go on top of the region.
    above,
    /// The restored originals go beneath the region.
    below,
    /// The region is dropped: a test's result was read from it, and the
    /// test's only lasting effect on the stack is none.
    discarded,
    /// The region moves into `results`, in stack order, for a cleave to put
    /// back once every quotation has run.
    collected,
};

/// A quotation run over a paging floor, and the bounded phases that put the
/// stack back together once it returns: originals a `dip` returned are swept
/// to the top of the region and dropped, the region is placed, and the paged
/// originals come back in their original order. Each phase is user-sized and
/// advances only as far as the turn's budget allows, and no phase takes a
/// live value off the stack except to release it or to collect it.
///
/// A restored original the floor beneath holds too goes back as that
/// floor's returned original, so restoring is never producing: a word that
/// only looked at a value beneath the floor did not produce it.
pub const Region = struct {
    placement: Placement,
    /// What `Fiber.beginPagingApplication` runs the quotation over.
    floor: PagingFloor = .{},
    /// What a collected region held, in stack order.
    results: heap.InlineList(Value, 4, .{ .int = 0 }) = .empty,
    /// The region's base: the floor as the quotation left it.
    base: usize = 0,
    /// How many originals come back: the floor's count before they do.
    restored: usize = 0,
    sweep: StackSweep = .from(0),
    /// The reversal that orders a collected region, or the three that rotate
    /// the restored originals beneath the region.
    spans: [3]StackReversal = @splat(.none),
    reversed: usize = 0,
    phase: Phase = .begin,

    const Phase = enum { begin, sweep, drop, clear, reverse, gather, surface, rotate, finished };

    pub fn init(placement: Placement) Region {
        return .{ .placement = placement };
    }

    /// Readies the floor for another quotation once a restore has finished.
    pub fn reset(self: *Region) void {
        std.debug.assert(self.floor.originals.len() == 0 and self.floor.returned.items.len == 0);
        self.phase = .begin;
        self.reversed = 0;
    }

    /// The value a test left on top of its region. A test that left nothing
    /// took its result from beneath, like any operand its words required: the
    /// value is paged now, so the restore gives it back.
    pub fn takeTestResult(self: *Region, fiber: *Fiber) MachineError!heap.OwnedValue {
        if (fiber.stack.items.len != self.base) return fiber.popValue();
        try self.floor.originals.ensureUnusedCapacity(fiber.allocator, 1);
        const taken = try takeProtected(fiber);
        heap.retainValue(taken.item.borrow());
        self.floor.originals.appendAssumeCapacity(.{ .value = taken.item.borrow(), .shared = taken.original });
        self.base -= 1;
        return taken.item;
    }

    /// Restores the stack as far as the turn's budget allows; true once the
    /// region is placed and every original is back.
    pub fn advance(self: *Region, fiber: *Fiber) MachineError!bool {
        const work = fiber.workBudget();
        while (true) switch (self.phase) {
            .begin => {
                self.restored = self.floor.originals.len();
                const returned = self.floor.returned.items;
                if (self.placement == .discarded) {
                    self.phase = .clear;
                } else if (returned.len == 0) {
                    self.placeRegion(fiber);
                } else {
                    // The region lies above the floor beneath, whose returned
                    // originals all sit below it, so only this floor's records
                    // name slots in it.
                    self.sweep = .from(returned[0]);
                    self.phase = .sweep;
                }
            },
            .sweep => {
                if (!self.sweep.advance(fiber.stack.items, self.floor.returned.items, work)) return false;
                self.phase = .drop;
            },
            .drop => {
                const returned = &self.floor.returned;
                const granted = work.take(returned.items.len);
                fiber.discard(granted);
                returned.shrinkRetainingCapacity(returned.items.len - granted);
                if (returned.items.len != 0) return false;
                self.placeRegion(fiber);
            },
            .clear => {
                const granted = work.take(fiber.stack.items.len - self.base);
                fiber.discard(granted);
                if (fiber.stack.items.len != self.base) return false;
                self.floor.returned.clearRetainingCapacity();
                self.phase = .surface;
            },
            .reverse => {
                if (!self.spans[0].advance(fiber.stack.items, work)) return false;
                try self.results.ensureUnusedCapacity(fiber.allocator, fiber.stack.items.len - self.base);
                self.phase = .gather;
            },
            .gather => {
                const granted = work.take(fiber.stack.items.len - self.base);
                for (0..granted) |_| {
                    var item = try fiber.popValue();
                    self.results.appendAssumeCapacity(item.take());
                }
                if (fiber.stack.items.len != self.base) return false;
                self.phase = .surface;
            },
            .surface => {
                const originals = &self.floor.originals;
                const granted = work.take(originals.len());
                for (0..granted) |_| {
                    const index = self.restored - originals.len();
                    const original = originals.pop().?;
                    try fiber.pushOwned(original.value);
                    // Beneath the region, the originals end up at the base
                    // once rotated; the records name those slots now.
                    const position = if (self.placement == .below) self.base + index else fiber.stack.items.len - 1;
                    if (original.shared) try noteReturned(fiber, position);
                }
                if (originals.len() != 0) return false;
                if (self.placement != .below) {
                    self.phase = .finished;
                    continue;
                }
                const top = fiber.stack.items.len;
                const split = top - self.restored;
                self.spans = .{ .of(self.base, split), .of(split, top), .of(self.base, top) };
                self.phase = .rotate;
            },
            .rotate => {
                while (self.reversed != self.spans.len) : (self.reversed += 1) {
                    if (!self.spans[self.reversed].advance(fiber.stack.items, work)) return false;
                }
                self.phase = .finished;
            },
            .finished => return true,
        };
    }

    /// The region holds only results now; what happens to it is the placement.
    fn placeRegion(self: *Region, fiber: *const Fiber) void {
        switch (self.placement) {
            .above, .below => self.phase = .surface,
            .collected => {
                self.spans[0] = .of(self.base, fiber.stack.items.len);
                self.phase = .reverse;
            },
            .discarded => unreachable,
        }
    }

    pub fn retire(self: *Region, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        for (self.results.items()) |item| releases.releaseValue(item);
        self.results.deinit(allocator);
        self.floor.retire(releases, allocator);
    }
};
