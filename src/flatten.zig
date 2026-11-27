//! A code list rewritten so that the quotation literals its combinators apply
//! run in place. A fiber flattens a list the first time it runs it at a site
//! and remembers the result for one publication. The flattened list is what
//! the machine then runs; this record says where each of its forms came from
//! and what each of its guards protects, so nothing a program observes
//! depends on which list ran.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const intern = @import("intern.zig");
const combinators = @import("combinators.zig");
const stack_summary = @import("stack_summary.zig");

const Header = value.ListHandle;
const Fiber = machine.Fiber;
const place = stack_summary.place;

/// Where one form of a flattened list was written: the quotation and its
/// position there. A form the rewrite inserted has the position of the word
/// whose phrase it belongs to.
pub const Origin = struct {
    code: *Header,
    index: u32,
    /// Some list of the word this form runs in has forms after it: the
    /// form's own, or one whose combinator applied the quotation it is in,
    /// out to the body of the innermost inlined word, or to the whole list
    /// when there is none. When none does, the evaluations that would have
    /// run those lists are exhausted here.
    continues: bool,
    /// The innermost inlined word this form runs in, by its place in the
    /// record's chain, or `no_word`.
    word: u16 = no_word,
};

pub const no_word: u16 = std.math.maxInt(u16);

/// A source word whose body the rewrite put in place of a call to it: what
/// its activation would have said, had the call been made.
pub const Inlined = struct {
    word: intern.TraceWord,
    attribution: env.Attribution,
    /// Where the word was called, as written.
    code: *Header,
    index: u32,
    /// The inlined word the call is in, or `no_word`.
    outer: u16,
    /// Whether the lists of that outer word, or of the whole list, have
    /// forms after the call.
    call_continues: bool,
};

/// What the guard at the start of a flattened phrase protects, and what to
/// run in the phrase's place when it does not hold.
pub const Guard = struct {
    /// Values the expansion takes for itself, which must be in reach.
    needed: u16,
    /// The phrase is an application or a call in tail position, which the
    /// original would have given the evaluation's tail authority.
    tail: bool,
    /// The forms of the expansion, which follow the guard.
    skip: u32,
    /// The forms that push the phrase's operands, as written, in the
    /// record's `operands`.
    operands_start: u32,
    operands_len: u32,
    /// The word's occurrence, as written.
    word: value.Symbol,
};

/// One flattened list. It lives for as long as the fiber's table holds it or
/// anything else holds its code: an evaluation running the list holds the
/// code, so the record outlives every evaluation that could ask about it.
pub const Flattened = struct {
    /// The list the machine runs. Held.
    code: *Header,
    /// The list as written, which every origin's quotation is part of. Held.
    original: *Header,
    /// What an evaluation of the original would have held.
    owner: env.Owner = .static,
    /// One per form of `code`.
    origins: []Origin,
    guards: []Guard,
    /// The operand forms the guards run, borrowed from the lists this record
    /// holds.
    operands: []value.Value,
    /// The source words inlined into the list.
    chain: []Inlined,
    /// The bodies of those words. Held.
    bodies: []*Header,
    /// The publication it was built in.
    publication: u64,
    /// The root the original ran in when it was flattened.
    scope: env.ScopeId,
    /// The lowest height of the fiber's evaluations at which one began
    /// running this list: the evaluation and everything it leads to, the
    /// frames it suspends beneath and the call sites recorded from it, stand
    /// at that height or above.
    lowest: usize = std.math.maxInt(usize),
    /// The next record waiting for the fiber to come back beneath it.
    retired: ?*Flattened = null,

    fn destroy(self: *Flattened, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        releases.releaseHeader(self.code);
        releases.releaseHeader(self.original);
        for (self.bodies) |held| releases.releaseHeader(held);
        self.owner.release(releases);
        allocator.free(self.origins);
        allocator.free(self.guards);
        allocator.free(self.operands);
        allocator.free(self.chain);
        allocator.free(self.bodies);
        allocator.destroy(self);
    }

    /// Keeps what an evaluation of the original holds, the first time one is
    /// asked for: a word's body keeps its definition.
    pub fn hold(self: *Flattened, owner: env.Owner) void {
        if (self.owner != .static or owner == .static) return;
        owner.retain();
        self.owner = owner;
    }

    /// Notes an evaluation beginning to run this list at `height`.
    pub fn enter(self: *Flattened, height: usize) void {
        self.lowest = @min(self.lowest, height);
    }
};

/// What a fiber has made of the code lists it ran, all in one publication.
///
/// One entry per place and a fixed number of places. Within a publication a
/// place keeps the first list that took it: a second list that lands there
/// runs as written. So records leave the table only when the publication
/// moves. One that may still be running then waits on a chain until the
/// fiber's evaluations have come back beneath the lowest height it was
/// entered at, when nothing can still refer to it. That is a fact about the
/// fiber's own stack, so when a record is retired does not depend on when
/// anything else lets go. The chain is bounded too: while it is full the
/// table takes no new publication, and lists run as written. So the fiber
/// holds a constant number of records however long it runs at one height,
/// and every operation here, releasing them all included, is bounded by
/// that constant.
pub const Cache = struct {
    const capacity = 128;
    /// The most records that may wait at once.
    const max_waiting = 128;

    /// The records by the list each was made from, as written, which the
    /// record holds: so the address stays that list's.
    entries: []?*Flattened = &.{},
    /// The publication every present entry was made in.
    publication: u64 = 0,
    /// Records by the flattened code they own, one per place: an evaluation
    /// asks at each guard, so the answer must not cost a search. A record
    /// that lost its place to another is found by the search and takes the
    /// place back.
    by_code: [capacity]?*Flattened = @splat(null),
    /// The record last asked for: one evaluation's guards ask for the same
    /// one, so most asks end here.
    last: ?*Flattened = null,
    waiting: ?*Flattened = null,
    waiting_count: usize = 0,
    /// Lists found to have nothing to flatten in `plain_publication`, by
    /// address alone and not held. An address that has passed to another
    /// list answers for it too, and so may a list at another site; either
    /// way a list runs as written, which is always right.
    plain: []?*const Header = &.{},
    plain_publication: u64 = 0,

    const plain_capacity = 256;

    /// Whether `code` is known to have nothing to flatten in `publication`.
    pub inline fn isPlain(self: *const Cache, code: *const Header, publication: u64) bool {
        return self.plain_publication == publication and self.plain.len != 0 and self.plain[place(code, plain_capacity)] == code;
    }

    /// Notes that `code` has nothing to flatten in `publication`.
    pub fn notePlain(self: *Cache, allocator: std.mem.Allocator, code: *const Header, publication: u64) error{OutOfMemory}!void {
        try stack_summary.ensurePlaces(?*const Header, allocator, &self.plain, plain_capacity, null);
        if (self.plain_publication != publication) {
            @memset(self.plain, null);
            self.plain_publication = publication;
        }
        self.plain[place(code, plain_capacity)] = code;
    }

    /// The place the record made from `code` holds in the table, or the
    /// first empty one on its probe: null only when the table is full of
    /// other lists. Where a list lands depends on its address, so a collision
    /// moves it along rather than refusing it, and what the table admits
    /// depends on the count of lists alone.
    fn entryFor(entries: []?*Flattened, code: *const Header) ?*?*Flattened {
        var index = place(code, capacity);
        for (0..capacity) |_| {
            const entry = &entries[index];
            const held = entry.* orelse return entry;
            if (held.original == code) return entry;
            index = (index + 1) & (capacity - 1);
        }
        return null;
    }

    /// What the fiber made of `code` at `site` in `publication`: null when
    /// it has not looked, or made nothing of it there.
    pub inline fn find(self: *const Cache, code: *const Header, site: machine.ExecutionSite, publication: u64) ?*Flattened {
        if (self.publication != publication or self.entries.len == 0) return null;
        const flattened = (entryFor(self.entries, code) orelse return null).* orelse return null;
        if (flattened.scope != site.scope) return null;
        return flattened;
    }

    /// The record that owns the flattened list `code`, if it is one. The
    /// search is over the table's places and the waiting chain, both bounded.
    pub inline fn record(self: *Cache, code: *const Header) ?*Flattened {
        if (self.last) |flattened| if (flattened.code == code) return flattened;
        const found = self.search(code);
        if (found != null) self.last = found;
        return found;
    }

    fn search(self: *Cache, code: *const Header) ?*Flattened {
        const slot = &self.by_code[place(code, capacity)];
        if (slot.*) |flattened| if (flattened.code == code) return flattened;
        for (self.entries) |entry| if (entry) |flattened| if (flattened.code == code) {
            slot.* = flattened;
            return flattened;
        };
        var waiting = self.waiting;
        while (waiting) |flattened| : (waiting = flattened.retired) if (flattened.code == code) {
            slot.* = flattened;
            return flattened;
        };
        return null;
    }

    /// `record` for a caller that may not write: it reads the same places and
    /// remembers nothing.
    pub fn recordOf(self: *const Cache, code: *const Header) ?*const Flattened {
        if (self.by_code[place(code, capacity)]) |flattened| if (flattened.code == code) return flattened;
        for (self.entries) |entry| if (entry) |flattened| if (flattened.code == code) return flattened;
        var waiting = self.waiting;
        while (waiting) |flattened| : (waiting = flattened.retired) if (flattened.code == code) return flattened;
        return null;
    }

    /// Whether the table can take a record for `code` in `publication`, with
    /// the fiber's evaluations at `height`. It cannot when another list has
    /// the place, or when moving to a new publication would set more records
    /// waiting than the chain may hold.
    pub fn admits(
        self: *Cache,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        code: *const Header,
        publication: u64,
        height: usize,
    ) error{OutOfMemory}!bool {
        try stack_summary.ensurePlaces(?*Flattened, allocator, &self.entries, capacity, null);
        self.sweep(allocator, releases, height);
        if (self.publication != publication) {
            var staying: usize = 0;
            for (self.entries) |entry| if (entry) |flattened| {
                if (height >= flattened.lowest) staying += 1;
            };
            if (staying > max_waiting - self.waiting_count) return false;
            for (self.entries) |*entry| self.vacate(entry);
            self.sweep(allocator, releases, height);
            self.publication = publication;
        }
        const entry = entryFor(self.entries, code) orelse return false;
        return entry.* == null;
    }

    /// Records `made`, which the table then owns. The caller has asked
    /// `admits` for the list it was made from, in its publication.
    pub fn remember(self: *Cache, made: *Flattened) void {
        std.debug.assert(self.publication == made.publication);
        const entry = entryFor(self.entries, made.original).?;
        std.debug.assert(entry.* == null);
        self.by_code[place(made.code, capacity)] = made;
        entry.* = made;
    }

    /// Empties a place, putting its record on the waiting chain.
    fn vacate(self: *Cache, entry: *?*Flattened) void {
        const flattened = entry.* orelse return;
        flattened.retired = self.waiting;
        self.waiting = flattened;
        self.waiting_count += 1;
        entry.* = null;
    }

    /// Retires every waiting record the fiber, now at `height`, has come
    /// back beneath. The chain is bounded, so the walk is.
    pub fn sweep(self: *Cache, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain, height: usize) void {
        var link = &self.waiting;
        while (link.*) |flattened| {
            if (height >= flattened.lowest) {
                link = &flattened.retired;
                continue;
            }
            link.* = flattened.retired;
            self.waiting_count -= 1;
            const slot = &self.by_code[place(flattened.code, capacity)];
            if (slot.* == flattened) slot.* = null;
            if (self.last == flattened) self.last = null;
            flattened.destroy(allocator, releases);
        }
    }

    /// Releases everything. The fiber's evaluations are gone by now, so no
    /// record is still running. The table holds at most `capacity` records
    /// and the chain at most `max_waiting`.
    pub fn deinit(self: *Cache, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        for (self.entries) |*entry| self.vacate(entry);
        while (self.waiting) |flattened| {
            self.waiting = flattened.retired;
            flattened.destroy(allocator, releases);
        }
        if (self.entries.len != 0) allocator.free(self.entries);
        if (self.plain.len != 0) allocator.free(self.plain);
        self.* = .{};
    }
};

/// A list longer than this runs as written, so looking at a list is bounded
/// by a constant rather than by the program.
const max_forms = stack_summary.read_bounds.max_forms;
/// The most forms a flattened list holds.
const max_flat = 512;
/// The most phrases one list has flattened in it.
const max_guards = 64;
/// How far a rewrite descends through quotation literals.
const max_depth = 8;
/// Forms one rewrite may visit across the quotations it descends into.
const max_visited = stack_summary.read_bounds.max_visited;

/// The flattened form of `code` run at `site`, or null when it runs as
/// written: nothing in it is a combinator applied to quotation literals, it
/// is past a bound, or core is still being built. The answer is remembered
/// either way.
pub inline fn of(fiber: *Fiber, site: machine.ExecutionSite, code: *Header) error{OutOfMemory}!?*Flattened {
    const length = code.length();
    if (length < 2 or length > max_forms) return null;
    // A list built as the program runs is a new list each time, which the
    // table could only look at and forget.
    if (!heap.readFromSource(code)) return null;
    const publication = fiber.currentPublication();
    if (fiber.flattened.isPlain(code, publication)) return null;
    if (fiber.flattened.find(code, site, publication)) |flattened| return flattened;
    return make(fiber, site, code, publication);
}

/// Looks at a list the table has no answer for, and records the answer.
noinline fn make(fiber: *Fiber, site: machine.ExecutionSite, code: *Header, publication: u64) error{OutOfMemory}!?*Flattened {
    // Core's directory changes without a publication while it is built, and
    // a publication is all that outdates a flattened list.
    if (fiber.inherited.phase == .bootstrap) return null;
    // A list the table has no room for runs as written, and is not looked
    // at again in this publication.
    if (!try fiber.flattened.admits(fiber.allocator, fiber.releases, code, publication, fiber.height())) {
        try fiber.flattened.notePlain(fiber.allocator, code, publication);
        return null;
    }
    var rewrite: Rewrite = .{ .fiber = fiber };
    defer rewrite.deinit();
    const whole = try rewrite.body(code, &.{}, site, 0, .{ .continues = false, .tail = true, .word = no_word });
    // Words resolved under different publications say nothing together, and
    // the table has moved on from the publication it admitted this list in.
    if (fiber.currentPublication() != publication) return null;
    if (!whole or rewrite.guard_count == 0) {
        try fiber.flattened.notePlain(fiber.allocator, code, publication);
        return null;
    }
    const flattened = try rewrite.finish(code, site, publication);
    // Resolving words may have taken the table to another publication.
    if (!try fiber.flattened.admits(fiber.allocator, fiber.releases, code, publication, fiber.height())) {
        flattened.destroy(fiber.allocator, fiber.releases);
        return null;
    }
    fiber.flattened.remember(flattened);
    return flattened;
}

/// What a quotation a phrase applies consumes and leaves: its remembered
/// summary, or a read under a rewrite's own bounds when there is none, which
/// a quotation longer than a summary is kept for needs.
fn counted(fiber: *Fiber, scope: env.ScopeId, quotation: *Header) error{OutOfMemory}!?stack_summary.Summary {
    if (try stack_summary.of(fiber, scope, quotation)) |summary| return summary;
    return stack_summary.read(fiber, scope, quotation);
}

/// One rewrite in progress: the forms of the flattened list so far, where
/// each came from, and the tables of the phrases flattened into it.
const Rewrite = struct {
    fiber: *Fiber,
    // SAFETY: only the first `count` entries are read.
    forms: [max_flat]Value = undefined,
    // SAFETY: only the first `count` entries are read.
    origins: [max_flat]Origin = undefined,
    count: usize = 0,
    // SAFETY: only the first `guard_count` entries are read.
    guards: [max_guards]Guard = undefined,
    guard_count: usize = 0,
    // SAFETY: only the first `operand_count` entries are read.
    operands: [max_operands]Value = undefined,
    operand_count: usize = 0,
    // SAFETY: only the first `chain_count` entries of each are read.
    chain: [max_inlined]Inlined = undefined,
    /// The bodies of the inlined words, each held from the moment it is
    /// entered: the fiber's resolution of the word is all that otherwise
    /// keeps it, and resolving the body's own words may let that go.
    // SAFETY: as `chain`.
    bodies: [max_inlined]*Header = undefined,
    chain_count: usize = 0,
    /// The bodies being inlined now, outermost first: a word that reaches
    /// itself is called, not inlined again.
    // SAFETY: only the first `inlining_count` entries are read.
    inlining: [max_depth + 1]*Header = undefined,
    inlining_count: usize = 0,
    visited: usize = 0,

    const Value = value.Value;
    const max_operands = 128;
    const max_inlined = 16;
    /// Pushing forms one phrase can be waiting on.
    const max_pending = 16;

    const Mark = struct { count: usize, guard_count: usize, operand_count: usize, chain_count: usize };

    fn mark(self: *const Rewrite) Mark {
        return .{ .count = self.count, .guard_count = self.guard_count, .operand_count = self.operand_count, .chain_count = self.chain_count };
    }

    fn rewind(self: *Rewrite, to: Mark) void {
        self.count = to.count;
        self.guard_count = to.guard_count;
        self.operand_count = to.operand_count;
        for (self.bodies[to.chain_count..self.chain_count]) |held| self.fiber.releases.releaseHeader(held);
        self.chain_count = to.chain_count;
    }

    /// Lets go of the inlined bodies a rewrite still holds: all of them,
    /// unless `finish` handed them to a record.
    fn deinit(self: *Rewrite) void {
        for (self.bodies[0..self.chain_count]) |held| self.fiber.releases.releaseHeader(held);
        self.chain_count = 0;
    }

    /// Appends one form. False when the flattened list is full.
    fn emit(self: *Rewrite, form: Value, origin: Origin) bool {
        if (self.count == max_flat) return false;
        self.forms[self.count] = form;
        self.origins[self.count] = origin;
        self.count += 1;
        return true;
    }

    /// Appends a lowered operation the rewrite inserts for the phrase whose
    /// word stands at `at`.
    fn operation(self: *Rewrite, name: u32, operand: u32, at: Origin) bool {
        return self.emit(.{ .symbol = .{ .name = name, .slot = env.localOperandSlot(operand) } }, at);
    }

    /// What a list being appended stands in.
    const Within = struct {
        /// A list of the same word, which it was applied from, has forms
        /// after the application.
        continues: bool,
        /// Its last form is in tail position of the whole list, through
        /// applications and calls only: a tail application there is owed
        /// the evaluation's tail authority.
        tail: bool,
        /// The innermost inlined word it runs in.
        word: u16,

        fn origin(self: Within, code: *Header, index: usize, length: usize) Origin {
            return .{ .code = code, .index = @intCast(index), .continues = self.continues or index + 1 < length, .word = self.word };
        }
    };

    /// A form that pushes a quotation literal, not yet appended: the next
    /// word may apply it.
    const Item = struct { form: Value, origin: Origin, literal: *Header };

    const Pending = struct {
        // SAFETY: only the first `count` entries are read.
        items: [max_pending]Item = undefined,
        count: usize = 0,
    };

    /// The locals a list has bound, as far as they are known to be
    /// quotation literals. Stored as the runtime stores them, the top value
    /// first, so a read counts back from the end.
    const Locals = struct {
        const capacity = 16;
        held: [capacity]?*Header = @splat(null),
        bound: usize = 0,

        fn bind(self: *Locals, count: usize, top: []const ?*Header) void {
            for (0..count) |taken| {
                const slot = self.bound + taken;
                if (slot < capacity) self.held[slot] = if (taken < top.len) top[top.len - 1 - taken] else null;
            }
            self.bound += count;
        }

        fn read(self: *const Locals, index: usize) ?*Header {
            if (index >= self.bound) return null;
            const slot = self.bound - 1 - index;
            return if (slot < capacity) self.held[slot] else null;
        }

        fn drop(self: *Locals, count: usize) void {
            self.bound -= @min(count, self.bound);
        }

        /// Forgets what every local holds. A read counts back from the
        /// newest binding, so code that might leave a local of its own bound
        /// changes which one a read means.
        fn forget(self: *Locals) void {
            self.held = @splat(null);
        }
    };

    /// Appends the forms of `code` as it runs at `site`, each phrase in it
    /// flattened where it can be. `prefix` holds pushing forms that precede
    /// it: the arguments of the call a word's body is inlined at. False when
    /// a bound was reached, which leaves the forms appended so far for the
    /// caller to discard.
    fn body(self: *Rewrite, code: *Header, prefix: []const Item, site: machine.ExecutionSite, depth: usize, within: Within) error{OutOfMemory}!bool {
        const length: usize = @intCast(code.length());
        self.visited += length;
        if (depth > max_depth or self.visited > max_visited) return false;
        const whole: Value = .{ .list = code };
        const words = self.fiber.environment.localsWords();
        var pending: Pending = .{};
        for (prefix) |item| {
            pending.items[pending.count] = item;
            pending.count += 1;
        }
        var locals: Locals = .{};
        // The literals just appended, which a binding that follows at once
        // takes: nothing has run since they were pushed.
        var top: [max_pending]?*Header = @splat(null);
        var top_count: usize = 0;
        for (0..length) |index| {
            const form = list.atUnchecked(whole, index);
            const origin = within.origin(code, index, length);
            // Only a literal that reaches its word directly is expanded:
            // anything between would have seen it as a value.
            const pushed: ?*Header = switch (form) {
                .list => |literal| literal,
                .symbol => |reference| pushed: {
                    if (env.isQuoted(reference.slot) or reference.name != words.get) break :pushed null;
                    const operand = env.localOperand(reference.slot) orelse break :pushed null;
                    break :pushed locals.read(operand);
                },
                else => null,
            };
            if (pushed) |literal| {
                if (pending.count == max_pending and !self.flush(&pending, &top, &top_count)) return false;
                pending.items[pending.count] = .{ .form = form, .origin = origin, .literal = literal };
                pending.count += 1;
                continue;
            }
            const called = form == .symbol and !env.isQuoted(form.symbol.slot) and env.localOperand(form.symbol.slot) == null;
            if (called and pending.count != 0) {
                if (try self.phrase(&pending, form.symbol, origin, site, depth, within, index + 1 == length)) |neutral| {
                    if (!neutral) locals.forget();
                    top_count = 0;
                    continue;
                }
            }
            if (!self.flush(&pending, &top, &top_count)) return false;
            if (form == .symbol and !env.isQuoted(form.symbol.slot)) if (env.localOperand(form.symbol.slot)) |operand| {
                if (form.symbol.name == words.load) locals.bind(operand, top[0..top_count]);
                if (form.symbol.name == words.drop) locals.drop(operand);
            };
            // A word without a summary may leave a local bound.
            if (called and locals.bound != 0 and !try stack_summary.wordHasSummary(self.fiber, site.scope, form.symbol)) locals.forget();
            top_count = 0;
            if (!self.emit(form, origin)) return false;
        }
        return self.flush(&pending, &top, &top_count);
    }

    /// Appends the pending forms as values like any other, and remembers
    /// which literals they left on top.
    fn flush(self: *Rewrite, pending: *Pending, top: *[max_pending]?*Header, top_count: *usize) bool {
        for (pending.items[0..pending.count], 0..) |item, index| {
            if (!self.emit(item.form, item.origin)) return false;
            top[index] = item.literal;
        }
        top_count.* = pending.count;
        pending.count = 0;
        return true;
    }

    const Shape = union(enum) {
        apply,
        dip,
        above,
        below,
        /// This many quotations, each a form of its own.
        cleave: usize,
        spread: usize,
        /// One literal list of quotations.
        cleave_list,
        spread_list,
    };

    /// Flattens the phrase of `word`, which stands after the pending forms:
    /// appends the pending forms it does not apply, then its guard and
    /// expansion, and empties `pending`. Null when the phrase stays as
    /// written, with nothing appended and `pending` as it was. Otherwise
    /// whether the phrase is known to leave no local bound.
    fn phrase(
        self: *Rewrite,
        pending: *Pending,
        word: value.Symbol,
        at: Origin,
        site: machine.ExecutionSite,
        depth: usize,
        within: Within,
        ends_list: bool,
    ) error{OutOfMemory}!?bool {
        const last = within.tail and ends_list;
        const shape: Shape = switch (try self.fiber.summaryTarget(word, site.scope)) {
            .none => return null,
            .source => |source| return self.inline_(pending, word, at, site, depth, last, source),
            .builtin => |builtin| switch (combinators.flow(builtin.primitive)) {
                .apply => .apply,
                .dip => .dip,
                .cleave => |count| .{ .cleave = count },
                .spread => |count| .{ .spread = count },
                .measured => |placement| switch (placement) {
                    .above => Shape.above,
                    .below => Shape.below,
                },
                .branch => return null,
                .declared => if (combinators.listSharing(builtin.primitive)) |sharing| switch (sharing) {
                    .cleave => Shape.cleave_list,
                    .spread => Shape.spread_list,
                } else return null,
            },
        };
        // The forms that push the phrase's operands: its quotations, or the
        // one list of them.
        const operand_forms: usize = switch (shape) {
            .apply, .dip, .above, .below, .cleave_list, .spread_list => 1,
            .cleave, .spread => |count| count,
        };
        if (pending.count < operand_forms) return null;
        const start = self.mark();
        const kept = pending.count - operand_forms;
        const applied = pending.items[kept..pending.count];
        const words = self.fiber.environment.localsWords();
        // A quotation with a summary leaves no local bound. `dip` holds its
        // protected value in a local across its quotation, so it needs that;
        // a cleave or spread has it of every quotation already.
        // A measured word needs what its quotation consumes, which a summary
        // says before the quotation runs.
        const applied_summary: ?stack_summary.Summary = switch (shape) {
            .apply, .dip, .above, .below => try counted(self.fiber, site.scope, applied[0].literal),
            .cleave, .spread, .cleave_list, .spread_list => null,
        };
        const neutral = switch (shape) {
            .apply, .dip, .above, .below => applied_summary != null,
            .cleave, .spread, .cleave_list, .spread_list => true,
        };
        if (shape != .apply and !neutral) return null;
        // A quotation applied as a value binds its locals as no word's body,
        // and one short of values fails as that. Run in place it would be
        // part of whatever body the list is, so the guard must keep it from
        // ever being short: by its summary, or not at all.
        const binds = switch (shape) {
            .apply, .dip => bindsLocals(self.fiber, applied[0].literal),
            .above, .below, .cleave, .spread, .cleave_list, .spread_list => false,
        };
        if (binds and applied_summary == null) return null;
        const bound_inputs: usize = if (binds) applied_summary.?.consumed else 0;
        const expanded = expanded: {
            for (pending.items[0..kept]) |item| {
                if (!self.emit(item.form, item.origin)) break :expanded false;
            }
            const row = self.guard(at, applied) orelse break :expanded false;
            const after_guard = self.count;
            const inside: Within = .{ .continues = at.continues, .tail = false, .word = within.word };
            const needed: usize = switch (shape) {
                .apply => apply: {
                    if (!try self.body(applied[0].literal, &.{}, site, depth + 1, .{ .continues = at.continues, .tail = last, .word = within.word })) break :expanded false;
                    break :apply bound_inputs;
                },
                // Bind the protected value, run the quotation beneath where
                // it stood, and put it back.
                .dip => dip: {
                    if (!self.operation(words.load, 1, at)) break :expanded false;
                    if (!try self.body(applied[0].literal, &.{}, site, depth + 1, inside)) break :expanded false;
                    if (!self.operation(words.get, 0, at)) break :expanded false;
                    if (!self.operation(words.drop, 1, at)) break :expanded false;
                    break :dip 1 + bound_inputs;
                },
                // Bind what the quotation consumes, run it over a copy, and
                // put the originals back above its results or below them.
                // The count is the summary's, so the publication is checked
                // once the quotation has run, as a cleave checks it.
                .above, .below => measured: {
                    const consumed = applied_summary.?.consumed;
                    if (consumed != 0 and !self.operation(words.load, consumed, at)) break :expanded false;
                    if (shape == .below) for (0..consumed) |local| {
                        if (!self.operation(words.get, @intCast(local), at)) break :expanded false;
                    };
                    for (0..consumed) |local| {
                        if (!self.operation(words.get, @intCast(local), at)) break :expanded false;
                    }
                    if (!try self.body(applied[0].literal, &.{}, site, depth + 1, inside)) break :expanded false;
                    if (!self.operation(words.recheck, 0, at)) break :expanded false;
                    if (shape == .above) for (0..consumed) |local| {
                        if (!self.operation(words.get, @intCast(local), at)) break :expanded false;
                    };
                    if (consumed != 0 and !self.operation(words.drop, consumed, at)) break :expanded false;
                    break :measured consumed;
                },
                .cleave, .spread, .cleave_list, .spread_list => counted: {
                    var quotations: Quotations = .{};
                    switch (shape) {
                        .cleave, .spread => for (applied) |item| quotations.add(item.literal),
                        .cleave_list, .spread_list => {
                            const held: Value = .{ .list = applied[0].literal };
                            const count: usize = @intCast(held.list.length());
                            if (count == 0 or count > combinators.max_counted) break :expanded false;
                            for (0..count) |index| switch (list.atUnchecked(held, index)) {
                                .list => |quotation| quotations.add(quotation),
                                else => break :expanded false,
                            };
                        },
                        .apply, .dip, .above, .below => unreachable,
                    }
                    for (quotations.items[0..quotations.count], 0..) |quotation, index| {
                        const summary = try counted(self.fiber, site.scope, quotation) orelse break :expanded false;
                        quotations.consumed[index] = summary.consumed;
                        quotations.produced[index] = summary.produced;
                    }
                    break :counted switch (shape) {
                        .cleave, .cleave_list => try self.cleave(&quotations, site, depth, at, inside),
                        .spread, .spread_list => try self.spread(&quotations, site, depth, at, inside),
                        .apply, .dip, .above, .below => unreachable,
                    } orelse break :expanded false;
                },
            };
            self.guards[row].needed = @intCast(needed);
            self.guards[row].tail = shape == .apply and last;
            self.guards[row].skip = @intCast(self.count - after_guard);
            self.guards[row].word = word;
            break :expanded true;
        };
        if (!expanded) {
            // Past a bound: the phrase stays as written.
            self.rewind(start);
            return null;
        }
        pending.count = 0;
        return neutral;
    }

    /// Whether a list binds locals itself, as distinct from the quotations
    /// in it.
    fn bindsLocals(fiber: *Fiber, code: *Header) bool {
        // A list too long to look at is taken to bind.
        if (code.length() > max_forms) return true;
        const load = fiber.environment.localsWords().load;
        const whole: Value = .{ .list = code };
        for (0..@intCast(code.length())) |index| switch (list.atUnchecked(whole, index)) {
            .symbol => |reference| if (reference.name == load and !env.isQuoted(reference.slot) and env.localOperand(reference.slot) != null) return true,
            else => {},
        };
        return false;
    }

    /// Appends a guard for the phrase whose word stands at `at`, whose
    /// operands `applied` pushes. Returns its row, to be filled in once the
    /// expansion is known, or null past a bound.
    fn guard(self: *Rewrite, at: Origin, applied: []const Item) ?usize {
        if (self.guard_count == max_guards or applied.len > max_operands - self.operand_count) return null;
        const row = self.guard_count;
        self.guard_count += 1;
        // SAFETY: the caller fills in the rest before the row is used.
        self.guards[row] = .{
            .needed = 0,
            .tail = false,
            .skip = 0,
            .operands_start = @intCast(self.operand_count),
            .operands_len = @intCast(applied.len),
            .word = undefined,
        };
        for (applied) |item| {
            self.operands[self.operand_count] = item.form;
            self.operand_count += 1;
        }
        if (!self.operation(self.fiber.environment.localsWords().guard, @intCast(row), at)) return null;
        return row;
    }

    /// Puts a source word's body in place of a call to it, with the pending
    /// forms as the arguments it starts on. The call must be one nothing can
    /// tell from its body run in place: the body runs where the caller does,
    /// the word is reported as itself, it does not reach itself, and its
    /// only binding of locals opens it, where the guard can stand for the
    /// word's own check of its arity.
    fn inline_(
        self: *Rewrite,
        pending: *Pending,
        word: value.Symbol,
        at: Origin,
        site: machine.ExecutionSite,
        depth: usize,
        last: bool,
        source: machine.SummaryTarget.Source,
    ) error{OutOfMemory}!?bool {
        if (source.home) |home| if (home.scope != site.scope) return null;
        if (source.attribution != .own) return null;
        // A qualified word may have to be loaded where it is called.
        if (std.mem.indexOfScalar(u8, intern.get(word.name), '.') != null) return null;
        const length: usize = @intCast(source.code.length());
        if (length == 0 or length > max_forms) return null;
        if (self.chain_count == max_inlined or self.inlining_count == self.inlining.len) return null;
        for (self.inlining[0..self.inlining_count]) |running| if (running == source.code) return null;
        const words = self.fiber.environment.localsWords();
        const whole: Value = .{ .list = source.code };
        var opening: usize = 0;
        for (0..length) |index| switch (list.atUnchecked(whole, index)) {
            .symbol => |reference| if (!env.isQuoted(reference.slot) and reference.name == words.load) {
                const operand = env.localOperand(reference.slot) orelse continue;
                if (index != 0) return null;
                opening = operand;
            },
            else => {},
        };
        const start = self.mark();
        const arguments = pending.items[0..pending.count];
        const entered = self.chain_count;
        const expanded = expanded: {
            const row = self.guard(at, arguments) orelse break :expanded false;
            const after_guard = self.count;
            self.chain[entered] = .{
                .word = source.trace_word,
                .attribution = source.attribution,
                .code = at.code,
                .index = at.index,
                .outer = at.word,
                .call_continues = at.continues,
            };
            heap.incRef(source.code);
            self.bodies[entered] = source.code;
            self.chain_count += 1;
            self.inlining[self.inlining_count] = source.code;
            self.inlining_count += 1;
            defer self.inlining_count -= 1;
            if (!try self.body(source.code, arguments, site, depth + 1, .{ .continues = false, .tail = last, .word = @intCast(entered) })) break :expanded false;
            // The arguments are pushed inside the expansion, so the opening
            // binding needs beneath the guard only what they do not supply.
            self.guards[row].needed = @intCast(opening -| arguments.len);
            self.guards[row].tail = last;
            self.guards[row].skip = @intCast(self.count - after_guard);
            self.guards[row].word = word;
            break :expanded true;
        };
        if (!expanded) {
            self.rewind(start);
            return null;
        }
        pending.count = 0;
        // Whether the word leaves a local bound is its summary's to say.
        return try stack_summary.wordHasSummary(self.fiber, site.scope, word);
    }

    /// The quotations of a cleave or spread, with what each consumes and
    /// leaves by its summary.
    const Quotations = struct {
        // SAFETY: only the first `count` of each are read.
        items: [combinators.max_counted]*Header = undefined,
        // SAFETY: as `items`.
        consumed: [combinators.max_counted]u32 = undefined,
        // SAFETY: as `items`.
        produced: [combinators.max_counted]u32 = undefined,
        count: usize = 0,

        fn add(self: *Quotations, quotation: *Header) void {
            self.items[self.count] = quotation;
            self.count += 1;
        }
    };

    /// A cleave: bind the most any quotation consumes, then for each
    /// quotation push its own inputs from the locals, run it where they
    /// stand, and check the publication. Returns the values bound, or null
    /// past a bound.
    fn cleave(self: *Rewrite, quotations: *const Quotations, site: machine.ExecutionSite, depth: usize, at: Origin, inside: Within) error{OutOfMemory}!?usize {
        const words = self.fiber.environment.localsWords();
        var bound: u32 = 0;
        for (quotations.consumed[0..quotations.count]) |consumed| bound = @max(bound, consumed);
        if (bound != 0 and !self.operation(words.load, bound, at)) return null;
        for (quotations.items[0..quotations.count], quotations.consumed[0..quotations.count]) |quotation, consumed| {
            // Local 0 is the deepest value bound, so a quotation's inputs,
            // the top `consumed` of them, are the highest indices.
            for (bound - consumed..bound) |local| {
                if (!self.operation(words.get, @intCast(local), at)) return null;
            }
            if (!try self.body(quotation, &.{}, site, depth + 1, inside)) return null;
            if (!self.operation(words.recheck, 0, at)) return null;
        }
        if (bound != 0 and !self.operation(words.drop, bound, at)) return null;
        return bound;
    }

    /// A spread: the last quotation runs first, on the top of the stack.
    /// Before each earlier one, the results so far are bound out of its way;
    /// at the end they are pushed back in the quotations' order. Returns the
    /// values the quotations consume together, or null past a bound.
    fn spread(self: *Rewrite, quotations: *const Quotations, site: machine.ExecutionSite, depth: usize, at: Origin, inside: Within) error{OutOfMemory}!?usize {
        const words = self.fiber.environment.localsWords();
        var needed: usize = 0;
        var stashed: u32 = 0;
        var index = quotations.count;
        while (index != 0) {
            index -= 1;
            needed += quotations.consumed[index];
            if (!try self.body(quotations.items[index], &.{}, site, depth + 1, inside)) return null;
            if (!self.operation(words.recheck, 0, at)) return null;
            if (index != 0 and quotations.produced[index] != 0) {
                if (!self.operation(words.load, quotations.produced[index], at)) return null;
                stashed += quotations.produced[index];
            }
        }
        // The stash bound last, the second quotation's results, holds the
        // lowest indices, deepest value first.
        for (0..stashed) |local| {
            if (!self.operation(words.get, @intCast(local), at)) return null;
        }
        if (stashed != 0 and !self.operation(words.drop, stashed, at)) return null;
        return needed;
    }

    /// Builds the record: the flattened list, holding every value in it, and
    /// the tables beside it.
    fn finish(self: *Rewrite, original: *Header, site: machine.ExecutionSite, publication: u64) error{OutOfMemory}!*Flattened {
        const allocator = self.fiber.allocator;
        const origins = try allocator.dupe(Origin, self.origins[0..self.count]);
        errdefer allocator.free(origins);
        const guards = try allocator.dupe(Guard, self.guards[0..self.guard_count]);
        errdefer allocator.free(guards);
        const operands = try allocator.dupe(Value, self.operands[0..self.operand_count]);
        errdefer allocator.free(operands);
        const chain = try allocator.dupe(Inlined, self.chain[0..self.chain_count]);
        errdefer allocator.free(chain);
        const bodies = try allocator.dupe(*Header, self.bodies[0..self.chain_count]);
        errdefer allocator.free(bodies);
        const record = try allocator.create(Flattened);
        errdefer allocator.destroy(record);
        var builder = try heap.ListBuilder(.generic_spine).initCode(allocator, self.count, self.count, .none);
        for (self.forms[0..self.count], builder.items()) |form, *slot| {
            heap.retainValue(form);
            slot.* = form;
        }
        heap.incRef(original);
        // The record takes over the holds on the inlined bodies.
        self.chain_count = 0;
        record.* = .{
            .code = builder.finish(),
            .original = original,
            .origins = origins,
            .guards = guards,
            .operands = operands,
            .chain = chain,
            .bodies = bodies,
            .publication = publication,
            .scope = site.scope,
        };
        return record;
    }
};
