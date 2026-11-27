//! Reads a quotation's forms before they run. One walk follows what the forms
//! do to the stack: which values are quotation literals the code pushed, what
//! each local holds, and what every combinator applied to literals makes of
//! them. What a value is beyond that is the reader's own: nothing for a stack
//! summary, a register for a scalar program.
const std = @import("std");
const value = @import("value.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const combinators = @import("combinators.zig");
const prims = @import("prims.zig");

const Header = value.ListHandle;
const Fiber = machine.Fiber;

/// What code does to the stack: how many values it takes from beneath where
/// it starts and how many it leaves there.
pub const Counts = struct {
    consumed: u32,
    produced: u32,
};

/// Why a walk has no answer: a form it cannot read, or a bound it reached
/// before it could tell.
pub const Stop = error{ Unread, Exhausted };

/// Where a form was written.
pub const At = struct { code: *Header, index: u32 };

pub const Policy = struct {
    /// The most values the walk follows at once.
    capacity: usize,
    /// A quotation a combinator applies is not read past this length.
    max_operand_forms: usize,
    /// Forms one walk may visit across everything it descends into, which
    /// bounds it by a constant rather than by the program.
    max_visited: usize,
    /// How far a walk descends through quotation literals.
    max_depth: usize,
    /// Whether `if` over two literals is read. It is when both leave the
    /// same counts; what they leave is then known only by count.
    branches: bool,
};

/// The most locals one walk holds bound at once.
pub const max_locals = 16;

/// One value on the stack as the walk sees it: the quotation literal the code
/// pushed, when it is one, and whatever the reader keeps of it.
pub fn Slot(comptime Payload: type) type {
    return struct {
        literal: ?*Header = null,
        payload: ?Payload = null,
    };
}

/// A walk for one reader. `Mode` supplies:
///
/// - `Payload`, what it keeps of a value;
/// - `policy`, its bounds;
/// - `constant(form) ?Payload`, for a form that pushes itself, null when the
///   reader has no use for it;
/// - `builtin(primitive, word, at, inputs, outputs) bool`, for a builtin
///   whose declared effect is exact, false when the reader has no use for it;
/// - `source(fiber, visited, source) !Counts`, for a source word.
pub fn Walker(comptime Mode: type) type {
    return struct {
        const Self = @This();
        const policy: Policy = Mode.policy;
        pub const Item = Slot(Mode.Payload);
        const Items = [policy.capacity]Item;

        fiber: *Fiber,
        mode: *Mode,
        /// Forms visited so far, shared with the walks this one rests on.
        visited: *usize,
        // SAFETY: only the first `height` entries are read.
        slots: Items = undefined,
        height: usize = 0,
        /// The lowest height any form has needed since a combinator last set
        /// it: what the quotation being read consumes lies above this.
        low: usize = 0,
        // SAFETY: only the first `bound` entries are read.
        locals: [max_locals]Item = undefined,
        bound: usize = 0,

        /// Starts the walk on `count` values, which the caller fills in.
        pub fn open(self: *Self, count: usize) []Item {
            std.debug.assert(count <= policy.capacity);
            self.height = count;
            self.low = count;
            return self.slots[0..count];
        }

        fn push(self: *Self, item: Item) Stop!void {
            if (self.height == policy.capacity) return error.Unread;
            self.slots[self.height] = item;
            self.height += 1;
        }

        fn pushAll(self: *Self, items: []const Item) Stop!void {
            if (items.len > policy.capacity - self.height) return error.Unread;
            @memcpy(self.slots[self.height..][0..items.len], items);
            self.height += items.len;
        }

        fn pop(self: *Self) Stop!Item {
            if (self.height == 0) return error.Unread;
            self.height -= 1;
            self.low = @min(self.low, self.height);
            return self.slots[self.height];
        }

        /// Notes that the top `count` values were needed.
        fn need(self: *Self, count: usize) Stop!void {
            if (self.height < count) return error.Unread;
            self.low = @min(self.low, self.height - count);
        }

        /// Pops the quotation a combinator is about to apply: known only when
        /// it is a literal the code pushed.
        fn operand(self: *Self) Stop!*Header {
            const literal = (try self.pop()).literal orelse return error.Unread;
            if (literal.length() > policy.max_operand_forms) return error.Unread;
            return literal;
        }

        /// What the forms read so far consumed from beneath `floor`, the
        /// height the walk started at, and left there.
        pub fn counts(self: *const Self, floor: usize) Counts {
            return .{ .consumed = @intCast(floor - self.low), .produced = @intCast(self.height - self.low) };
        }

        /// Reads `code` where the stack stands. Its locals are its own: it
        /// reads none of its caller's and leaves none bound.
        pub fn run(self: *Self, code: *Header, site: machine.ExecutionSite, depth: usize) (Stop || error{OutOfMemory})!void {
            const length: usize = @intCast(code.length());
            if (depth > policy.max_depth) return error.Exhausted;
            self.visited.* += length;
            if (self.visited.* > policy.max_visited) return error.Exhausted;
            const outer = self.bound;
            for (0..length) |index| {
                const form = list.atUnchecked(.{ .list = code }, index);
                const word = switch (form) {
                    .symbol => |reference| reference,
                    .list => |literal| {
                        try self.push(.{ .literal = literal });
                        continue;
                    },
                    else => {
                        try self.push(.{ .payload = self.mode.constant(form) orelse return error.Unread });
                        continue;
                    },
                };
                // A quoted occurrence pushes its symbol.
                if (env.isQuoted(word.slot)) {
                    try self.push(.{ .payload = self.mode.constant(form) orelse return error.Unread });
                    continue;
                }
                if (env.localOperand(word.slot)) |count_or_index| {
                    try self.local(word.name, count_or_index, outer);
                    continue;
                }
                try self.call(word, .{ .code = code, .index = @intCast(index) }, site, depth);
            }
            // A local left bound stays visible to the caller, which no
            // reader can describe.
            if (self.bound != outer) return error.Unread;
        }

        /// One lowered locals operation of the code whose locals start at
        /// `outer`: bind the top `count_or_index` values, push that local, or
        /// drop that many. Stored as the runtime stores them, the top value
        /// first, so a read counts back from the end.
        fn local(self: *Self, name: u32, count_or_index: u32, outer: usize) Stop!void {
            const words = self.fiber.environment.localsWords();
            if (name == words.load) {
                if (count_or_index > max_locals - self.bound) return error.Unread;
                for (0..count_or_index) |index| self.locals[self.bound + index] = try self.pop();
                self.bound += count_or_index;
            } else if (name == words.get) {
                if (count_or_index >= self.bound - outer) return error.Unread;
                try self.push(self.locals[self.bound - 1 - count_or_index]);
            } else if (name == words.drop) {
                if (count_or_index > self.bound - outer) return error.Unread;
                self.bound -= count_or_index;
            } else return error.Unread;
        }

        fn call(self: *Self, word: value.Symbol, at: At, site: machine.ExecutionSite, depth: usize) (Stop || error{OutOfMemory})!void {
            switch (try self.fiber.summaryTarget(word, site)) {
                .none => return error.Unread,
                .source => |source| {
                    const read = try self.mode.source(self.fiber, self.visited, source);
                    for (0..read.consumed) |_| _ = try self.pop();
                    for (0..read.produced) |_| try self.push(.{});
                },
                .builtin => |builtin| {
                    if (prims.shuffle(builtin.primitive)) |moved| return self.shuffle(moved);
                    if (prims.unsummarizable(builtin.primitive)) return error.Unread;
                    const declared = exact(builtin.effect) orelse return self.combinator(builtin.primitive, site, depth);
                    // An exact declared effect says everything, unless the
                    // word runs a quotation where no walk reads it.
                    if (takesQuotation(builtin.effect.?)) return error.Unread;
                    try self.need(declared.consumed);
                    // SAFETY: only the first `produced` are read, and the
                    // reader writes each.
                    var outputs: Items = undefined;
                    if (declared.produced > outputs.len) return error.Unread;
                    const inputs = self.slots[self.height - declared.consumed .. self.height];
                    if (!self.mode.builtin(builtin.primitive, word, at, inputs, outputs[0..declared.produced])) return error.Unread;
                    self.height -= declared.consumed;
                    try self.pushAll(outputs[0..declared.produced]);
                },
            }
        }

        /// A word that only moves values: the slots move as the values will.
        fn shuffle(self: *Self, moved: prims.Shuffle) Stop!void {
            switch (moved) {
                .dup => {
                    try self.need(1);
                    try self.push(self.slots[self.height - 1]);
                },
                .swap => {
                    try self.need(2);
                    std.mem.swap(Item, &self.slots[self.height - 1], &self.slots[self.height - 2]);
                },
                .over => {
                    try self.need(2);
                    try self.push(self.slots[self.height - 2]);
                },
                .pop => _ = try self.pop(),
            }
        }

        /// A combinator applied to quotation literals, read as what it would
        /// run. A quotation consumes what it needed from beneath where it
        /// started and leaves what stands above that.
        fn combinator(self: *Self, primitive: env.PrimitiveImpl, site: machine.ExecutionSite, depth: usize) (Stop || error{OutOfMemory})!void {
            const applied_site = site.applied();
            // SAFETY: the first `count` are written before they are read.
            var quotations: [combinators.max_counted]*Header = undefined;
            switch (combinators.flow(primitive)) {
                .declared => {
                    const sharing = combinators.listSharing(primitive) orelse return error.Unread;
                    const held = (try self.pop()).literal orelse return error.Unread;
                    const count: usize = @intCast(held.length());
                    if (count == 0 or count > quotations.len) return error.Unread;
                    for (0..count) |index| switch (list.atUnchecked(.{ .list = held }, index)) {
                        .list => |quotation| {
                            if (quotation.length() > policy.max_operand_forms) return error.Unread;
                            quotations[index] = quotation;
                        },
                        else => return error.Unread,
                    };
                    return switch (sharing) {
                        .cleave => self.cleave(quotations[0..count], applied_site, depth),
                        .spread => self.spread(quotations[0..count], applied_site, depth),
                    };
                },
                .apply => return self.run(try self.operand(), applied_site, depth + 1),
                .dip => {
                    const applied = try self.operand();
                    const protected = try self.pop();
                    try self.run(applied, applied_site, depth + 1);
                    return self.push(protected);
                },
                .branch => {
                    if (!policy.branches) return error.Unread;
                    const otherwise = try self.operand();
                    const then = try self.operand();
                    _ = try self.pop();
                    const before = self.slots;
                    const start = self.height;
                    const beneath = self.low;
                    self.low = start;
                    try self.run(otherwise, applied_site, depth + 1);
                    const left = self.counts(start);
                    self.slots = before;
                    self.height = start;
                    self.low = start;
                    try self.run(then, applied_site, depth + 1);
                    // Which branch runs is data, so the counts are known
                    // only when the branches agree, and the values not at
                    // all.
                    if (!std.meta.eql(left, self.counts(start))) return error.Unread;
                    @memset(self.slots[self.low..self.height], .{});
                    self.low = @min(beneath, self.low);
                },
                // A measured word leaves its quotation's results and the
                // inputs it consumed.
                .measured => |placement| {
                    const applied = try self.operand();
                    const before = self.slots;
                    const start = self.height;
                    const beneath = self.low;
                    self.low = start;
                    try self.run(applied, applied_site, depth + 1);
                    const reached = self.low;
                    // SAFETY: only the first `count` are read.
                    var results: Items = undefined;
                    const count = self.height - reached;
                    @memcpy(results[0..count], self.slots[reached..self.height]);
                    self.height = reached;
                    self.low = @min(beneath, reached);
                    const consumed = before[reached..start];
                    switch (placement) {
                        .above => {
                            try self.pushAll(results[0..count]);
                            try self.pushAll(consumed);
                        },
                        .below => {
                            try self.pushAll(consumed);
                            try self.pushAll(results[0..count]);
                        },
                    }
                },
                .cleave => |count| {
                    if (count > quotations.len) return error.Unread;
                    for (0..count) |index| quotations[count - 1 - index] = try self.operand();
                    return self.cleave(quotations[0..count], applied_site, depth);
                },
                .spread => |count| {
                    if (count > quotations.len) return error.Unread;
                    for (0..count) |index| quotations[count - 1 - index] = try self.operand();
                    return self.spread(quotations[0..count], applied_site, depth);
                },
            }
        }

        /// Every quotation runs from the same inputs; their results follow
        /// one another in the quotations' order.
        fn cleave(self: *Self, quotations: []const *Header, site: machine.ExecutionSite, depth: usize) (Stop || error{OutOfMemory})!void {
            const before = self.slots;
            const start = self.height;
            const beneath = self.low;
            // SAFETY: only the first `count` are read.
            var results: Items = undefined;
            var count: usize = 0;
            var reached = start;
            for (quotations) |each| {
                self.slots = before;
                self.height = start;
                self.low = start;
                try self.run(each, site, depth + 1);
                const left = self.height - self.low;
                if (left > results.len - count) return error.Unread;
                @memcpy(results[count..][0..left], self.slots[self.low..self.height]);
                count += left;
                reached = @min(reached, self.low);
            }
            self.slots = before;
            self.height = reached;
            self.low = @min(beneath, reached);
            return self.pushAll(results[0..count]);
        }

        /// Each quotation runs on its own inputs, the last on the top of the
        /// stack; their results follow one another in the quotations' order.
        fn spread(self: *Self, quotations: []const *Header, site: machine.ExecutionSite, depth: usize) (Stop || error{OutOfMemory})!void {
            const beneath = self.low;
            // SAFETY: only the entries from `first` on are read.
            var results: Items = undefined;
            var first = results.len;
            var index = quotations.len;
            while (index != 0) {
                index -= 1;
                self.low = self.height;
                try self.run(quotations[index], site, depth + 1);
                const left = self.height - self.low;
                if (left > first) return error.Unread;
                first -= left;
                @memcpy(results[first..][0..left], self.slots[self.low..self.height]);
                // The quotation before takes from what this one left beneath.
                self.height = self.low;
            }
            self.low = @min(beneath, self.low);
            return self.pushAll(results[first..]);
        }
    };
}

/// A declared effect that says exactly what its word consumes and leaves.
pub fn exact(declared: ?env.ValidatedEffect) ?Counts {
    const effect = declared orelse return null;
    if (effect.result_depth != .exact) return null;
    return .{ .consumed = effect.inputs, .produced = effect.outputs };
}

/// Whether a word's declared inputs include a quotation slot. Such a word
/// runs the quotation where no walk reads it, and that code may publish a
/// definition the walk rests on. Only the combinators with a rule of their
/// own are read, and they do not reach here.
pub fn takesQuotation(effect: env.ValidatedEffect) bool {
    const header = effect.header();
    for (0..effect.inputs) |index| {
        if (list.atUnchecked(.{ .list = header }, index) == .list) return true;
    }
    return false;
}
