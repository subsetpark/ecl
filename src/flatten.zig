//! A code list rewritten so that the quotation literals its combinators apply
//! run in place. A fiber flattens a list the first time it runs it at a site
//! and remembers the result for one publication. The flattened list is what
//! the machine then runs; this record says where each of its forms came from
//! and what each of its guards protects, so nothing a program observes
//! depends on which list ran.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const WordResolutions = @import("word_resolutions.zig").WordResolutions;

const Header = value.ListHandle;
const Fiber = machine.Fiber;

/// Where one form of a flattened list was written: the quotation and its
/// position there. A form the rewrite inserted has the position of the
/// combinator whose phrase it belongs to.
pub const Origin = struct {
    code: *Header,
    index: u32,
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

/// The flattened form of `code` run at `site`, or null when it runs as
/// written.
pub fn of(fiber: *Fiber, site: machine.ExecutionSite, code: *Header) error{OutOfMemory}!?*Flattened {
    _ = fiber;
    _ = site;
    _ = code;
    return null;
}
