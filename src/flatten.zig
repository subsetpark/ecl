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
const combinators = @import("combinators.zig");
const WordResolutions = @import("word_resolutions.zig").WordResolutions;

const Header = value.ListHandle;
const Fiber = machine.Fiber;

/// Where one form of a flattened list was written: the quotation and its
/// position there. A form the rewrite inserted has the position of the
/// combinator whose phrase it belongs to.
pub const Origin = struct {
    code: *Header,
    index: u32,
    /// The rewrite put this form here; no one wrote it.
    inserted: bool = false,
    /// Some list this form was written in has forms after it: its own, or
    /// one whose combinator applied the quotation it is in. When none does,
    /// the evaluations that would have run those lists are exhausted here.
    continues: bool,
};

/// What the guard at the start of a flattened phrase protects, and what to
/// run in the phrase's place when it does not hold.
pub const Guard = struct {
    /// Values the expansion takes for itself, which must be in reach.
    needed: u16,
    /// The phrase is an application in tail position, which the original
    /// would have given the evaluation's tail authority.
    tail: bool,
    /// The forms of the expansion, which follow the guard.
    skip: u32,
    /// The forms that push the phrase's operands, as written.
    operands: *Header,
    operands_start: u32,
    operands_len: u32,
    /// The combinator occurrence, as written.
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
    /// The publication it was built in.
    publication: u64,
    /// The next record waiting for its code to be let go.
    retired: ?*Flattened = null,

    pub fn create(
        allocator: std.mem.Allocator,
        code: *Header,
        original: *Header,
        origins: []Origin,
        guards: []Guard,
        publication: u64,
    ) error{OutOfMemory}!*Flattened {
        const record = try allocator.create(Flattened);
        heap.incRef(original);
        record.* = .{
            .code = code,
            .original = original,
            .origins = origins,
            .guards = guards,
            .publication = publication,
        };
        return record;
    }

    fn destroy(self: *Flattened, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        releases.releaseHeader(self.code);
        releases.releaseHeader(self.original);
        self.owner.release(releases);
        allocator.free(self.origins);
        allocator.free(self.guards);
        allocator.destroy(self);
    }

    /// Keeps what an evaluation of the original holds, the first time one is
    /// asked for: a word's body keeps its definition.
    pub fn hold(self: *Flattened, owner: env.Owner) void {
        if (self.owner != .static or owner == .static) return;
        owner.retain();
        self.owner = owner;
    }

    /// Whether anything but this record still holds the flattened code.
    fn running(self: *const Flattened) bool {
        return heap.heldElsewhere(self.code);
    }
};

/// What a fiber has made of the code lists it ran, all in one publication.
///
/// One entry per place and a fixed number of places, as the stack summary
/// table has: a list that lands on an occupied place replaces what was
/// there. A replaced or outdated record whose code an evaluation still runs
/// waits on a chain until that code is let go, so the chain is no longer than
/// the evaluations the fiber has suspended, and each step retires a bounded
/// number of records.
pub const Cache = struct {
    const capacity = 64;
    /// Waiting records one step looks at.
    const sweep_step = 4;

    const Entry = struct {
        /// Null for an empty place. Held, so the address stays this list's.
        code: ?*Header = null,
        scope: u64 = 0,
        provenance: u64 = 0,
        /// Null when the list was looked at and has nothing to flatten.
        record: ?*Flattened = null,
    };

    pub const Known = struct { flattened: ?*Flattened };

    entries: []Entry = &.{},
    /// The publication every present entry was made in.
    publication: u64 = 0,
    /// The record last asked for by its flattened code: an evaluation asks
    /// at each guard, and one evaluation's guards ask for the same record.
    last: ?*Flattened = null,
    waiting: ?*Flattened = null,

    fn place(code: *const Header) usize {
        return @intCast((@as(u64, @intFromPtr(code)) >> 4) *% 0x9E3779B97F4A7C15 >> (64 - std.math.log2(capacity)));
    }

    /// What the fiber made of `code` at `site` in `publication`, if it has
    /// looked.
    pub inline fn find(self: *const Cache, code: *const Header, site: machine.ExecutionSite, publication: u64) ?Known {
        if (self.publication != publication or self.entries.len == 0) return null;
        const entry = &self.entries[place(code)];
        if (entry.code != code or entry.scope != site.scope.serial or
            entry.provenance != WordResolutions.provenanceKey(site.registration_provenance)) return null;
        return .{ .flattened = entry.record };
    }

    /// The record that owns the flattened list `code`, if it is one. The
    /// search is over the table's places and the waiting chain, both bounded.
    pub fn record(self: *Cache, code: *const Header) ?*Flattened {
        if (self.last) |flattened| if (flattened.code == code) return flattened;
        for (self.entries) |entry| if (entry.record) |flattened| if (flattened.code == code) {
            self.last = flattened;
            return flattened;
        };
        var waiting = self.waiting;
        while (waiting) |flattened| : (waiting = flattened.retired) if (flattened.code == code) {
            self.last = flattened;
            return flattened;
        };
        return null;
    }

    /// `record` for a caller that may not write: it reads the same places and
    /// remembers nothing.
    pub fn recordOf(self: *const Cache, code: *const Header) ?*const Flattened {
        if (self.last) |flattened| if (flattened.code == code) return flattened;
        for (self.entries) |entry| if (entry.record) |flattened| if (flattened.code == code) return flattened;
        var waiting = self.waiting;
        while (waiting) |flattened| : (waiting = flattened.retired) if (flattened.code == code) return flattened;
        return null;
    }

    /// Records what the fiber made of `code`: a record, which the table then
    /// owns, or null for nothing to flatten. On failure the caller still
    /// owns the record.
    pub fn remember(
        self: *Cache,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        code: *Header,
        site: machine.ExecutionSite,
        publication: u64,
        made: ?*Flattened,
    ) error{OutOfMemory}!void {
        if (self.entries.len == 0) {
            const entries = try allocator.alloc(Entry, capacity);
            @memset(entries, .{});
            self.entries = entries;
        }
        if (self.publication != publication) {
            for (self.entries) |*entry| self.vacate(releases, entry);
            self.publication = publication;
        }
        self.sweep(allocator, releases, sweep_step);
        const entry = &self.entries[place(code)];
        self.vacate(releases, entry);
        heap.incRef(code);
        entry.* = .{
            .code = code,
            .scope = site.scope.serial,
            .provenance = WordResolutions.provenanceKey(site.registration_provenance),
            .record = made,
        };
    }

    /// Empties a place, putting its record on the waiting chain.
    fn vacate(self: *Cache, releases: *heap.ReleaseDomain, entry: *Entry) void {
        const held = entry.code orelse return;
        releases.releaseHeader(held);
        if (entry.record) |flattened| {
            flattened.retired = self.waiting;
            self.waiting = flattened;
        }
        entry.* = .{};
    }

    /// Retires waiting records whose code nothing else holds, looking at no
    /// more than `limit`.
    fn sweep(self: *Cache, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain, limit: usize) void {
        var link = &self.waiting;
        var looked: usize = 0;
        while (link.*) |flattened| : (looked += 1) {
            if (looked == limit) return;
            if (flattened.running()) {
                link = &flattened.retired;
                continue;
            }
            link.* = flattened.retired;
            if (self.last == flattened) self.last = null;
            flattened.destroy(allocator, releases);
        }
    }

    /// Releases everything. The fiber's evaluations are gone by now, so no
    /// record is still running. The table holds at most `capacity` records
    /// and the chain no more than the fiber had evaluations.
    pub fn deinit(self: *Cache, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        for (self.entries) |*entry| self.vacate(releases, entry);
        while (self.waiting) |flattened| {
            self.waiting = flattened.retired;
            flattened.destroy(allocator, releases);
        }
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = .{};
    }
};

/// A list longer than this runs as written, so looking at a list is bounded
/// by a constant rather than by the program.
const max_forms = 128;
/// The most forms a flattened list holds.
const max_flat = 512;
/// The most phrases one list has flattened in it.
const max_guards = 64;
/// How far a rewrite descends through quotation literals.
const max_depth = 8;
/// Forms one rewrite may visit across the quotations it descends into.
const max_visited = 1024;

/// The flattened form of `code` run at `site`, or null when it runs as
/// written: nothing in it is a combinator applied to quotation literals, it
/// is past a bound, or core is still being built. The answer is remembered
/// either way.
pub inline fn of(fiber: *Fiber, site: machine.ExecutionSite, code: *Header) error{OutOfMemory}!?*Flattened {
    const length = code.length();
    if (length < 2 or length > max_forms) return null;
    const publication = fiber.currentPublication();
    if (fiber.flattened.find(code, site, publication)) |known| return known.flattened;
    return make(fiber, site, code, publication);
}

/// Looks at a list the table has no answer for, and records the answer.
noinline fn make(fiber: *Fiber, site: machine.ExecutionSite, code: *Header, publication: u64) error{OutOfMemory}!?*Flattened {
    // Core's directory changes without a publication while it is built, and
    // a publication is all that outdates a flattened list.
    if (fiber.inherited.phase == .bootstrap) return null;
    var rewrite: Rewrite = .{ .fiber = fiber };
    const whole = try rewrite.body(code, site, 0, .{ .continues = false, .tail = true });
    const made: ?*Flattened = if (whole and rewrite.guard_count != 0)
        try rewrite.finish(code, publication)
    else
        null;
    // Words resolved under different publications say nothing together.
    if (fiber.currentPublication() != publication) {
        if (made) |flattened| flattened.destroy(fiber.allocator, fiber.releases);
        return null;
    }
    fiber.flattened.remember(fiber.allocator, fiber.releases, code, site, publication, made) catch |err| {
        if (made) |flattened| flattened.destroy(fiber.allocator, fiber.releases);
        return err;
    };
    return made;
}

/// One rewrite in progress: the forms of the flattened list so far, where
/// each came from, and the guards of the phrases flattened into it.
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
    visited: usize = 0,

    const Value = value.Value;
    const Mark = struct { count: usize, guard_count: usize };

    fn mark(self: *const Rewrite) Mark {
        return .{ .count = self.count, .guard_count = self.guard_count };
    }

    fn rewind(self: *Rewrite, to: Mark) void {
        self.count = to.count;
        self.guard_count = to.guard_count;
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
    /// combinator stands at `at`.
    fn operation(self: *Rewrite, name: u32, operand: u32, at: Origin) bool {
        return self.emit(
            .{ .symbol = .{ .name = name, .slot = env.localOperandSlot(operand) } },
            .{ .code = at.code, .index = at.index, .inserted = true, .continues = at.continues },
        );
    }

    /// Appends the forms of `code` as it runs at `site`, each phrase in it
    /// flattened where it can be. `within` says what `code` stands in. False
    /// when a bound was reached, which leaves the forms appended so far for
    /// the caller to discard.
    fn body(self: *Rewrite, code: *Header, site: machine.ExecutionSite, depth: usize, within: Within) error{OutOfMemory}!bool {
        const length: usize = @intCast(code.length());
        self.visited += length;
        if (depth > max_depth or self.visited > max_visited) return false;
        const whole: Value = .{ .list = code };
        var index: usize = 0;
        while (index < length) {
            const form = list.atUnchecked(whole, index);
            if (form != .list) {
                if (!self.emit(form, within.origin(code, index, length))) return false;
                index += 1;
                continue;
            }
            // A run of literals, then the word that might apply the last of
            // them. Only a literal that reaches its combinator directly is
            // expanded: anything between would have seen it as a value.
            var word_at = index;
            while (word_at < length and list.atUnchecked(whole, word_at) == .list) word_at += 1;
            if (word_at < length and try self.phrase(code, site, index, word_at, depth, within)) {
                index = word_at + 1;
                continue;
            }
            // No phrase: the literals are values like any other, and the
            // word after them is the next form.
            for (index..word_at) |position| {
                if (!self.emit(list.atUnchecked(whole, position), within.origin(code, position, length))) return false;
            }
            index = word_at;
        }
        return true;
    }

    /// What a list being appended stands in.
    const Within = struct {
        /// A list it was applied from has forms after the application.
        continues: bool,
        /// Its last form is in tail position of the whole list, through
        /// applications only: a tail application there is owed the
        /// evaluation's tail authority.
        tail: bool,

        fn origin(self: Within, code: *Header, index: usize, length: usize) Origin {
            return .{ .code = code, .index = @intCast(index), .continues = self.continues or index + 1 < length };
        }
    };

    /// Flattens the phrase whose word stands at `word_at`, after literals
    /// from `first`: appends the literals it does not apply, then its guard
    /// and expansion. False when the phrase stays as written, with nothing
    /// appended.
    fn phrase(
        self: *Rewrite,
        code: *Header,
        site: machine.ExecutionSite,
        first: usize,
        word_at: usize,
        depth: usize,
        within: Within,
    ) error{OutOfMemory}!bool {
        const whole: Value = .{ .list = code };
        const word = switch (list.atUnchecked(whole, word_at)) {
            .symbol => |reference| reference,
            else => return false,
        };
        if (env.isQuoted(word.slot) or env.localOperand(word.slot) != null) return false;
        const primitive = switch (try self.fiber.summaryTarget(word, site)) {
            .builtin => |builtin| builtin.primitive,
            .none, .source => return false,
        };
        const flow = combinators.flow(primitive);
        const quotations: usize = switch (flow) {
            .apply, .dip => 1,
            .declared, .branch, .measured, .cleave, .spread => return false,
        };
        if (word_at - first < quotations) return false;
        const start = self.mark();
        const length: usize = @intCast(code.length());
        const at = within.origin(code, word_at, length);
        const last = within.tail and word_at + 1 == length;
        const operands = word_at - quotations;
        const expanded = expanded: {
            for (first..operands) |position| {
                if (!self.emit(list.atUnchecked(whole, position), within.origin(code, position, length))) break :expanded false;
            }
            if (self.guard_count == max_guards) break :expanded false;
            const row = self.guard_count;
            self.guard_count += 1;
            if (!self.operation(self.fiber.environment.localsWords().guard, @intCast(row), at)) break :expanded false;
            const after_guard = self.count;
            const applied = list.atUnchecked(whole, operands).list;
            const words = self.fiber.environment.localsWords();
            const needed: u16 = switch (flow) {
                .apply => apply: {
                    if (!try self.body(applied, site.applied(), depth + 1, .{ .continues = at.continues, .tail = last })) break :expanded false;
                    break :apply 0;
                },
                // Bind the protected value, run the quotation beneath where
                // it stood, and put it back.
                .dip => dip: {
                    if (!self.operation(words.load, 1, at)) break :expanded false;
                    if (!try self.body(applied, site.applied(), depth + 1, .{ .continues = at.continues, .tail = false })) break :expanded false;
                    if (!self.operation(words.get, 0, at)) break :expanded false;
                    if (!self.operation(words.drop, 1, at)) break :expanded false;
                    break :dip 1;
                },
                else => unreachable,
            };
            self.guards[row] = .{
                .needed = needed,
                .tail = flow == .apply and last,
                .skip = @intCast(self.count - after_guard),
                .operands = code,
                .operands_start = @intCast(operands),
                .operands_len = @intCast(quotations),
                .word = word,
            };
            break :expanded true;
        };
        if (expanded) return true;
        // Past a bound: the phrase stays as written, and the caller appends
        // its literals and its word.
        self.rewind(start);
        return false;
    }

    /// Builds the record: the flattened list, holding every value in it, and
    /// the tables beside it.
    fn finish(self: *Rewrite, original: *Header, publication: u64) error{OutOfMemory}!*Flattened {
        const allocator = self.fiber.allocator;
        const origins = try allocator.dupe(Origin, self.origins[0..self.count]);
        errdefer allocator.free(origins);
        const guards = try allocator.dupe(Guard, self.guards[0..self.guard_count]);
        errdefer allocator.free(guards);
        var builder = try heap.ListBuilder(.generic_spine).initCode(allocator, self.count, self.count, .none);
        for (self.forms[0..self.count], builder.items()) |form, *slot| {
            heap.retainValue(form);
            slot.* = form;
        }
        const code = builder.finish();
        errdefer self.fiber.releases.releaseHeader(code);
        return Flattened.create(allocator, code, original, origins, guards, publication);
    }
};
