//! What a quotation does to the stack, read from its words before it runs:
//! how many values it takes from beneath and how many it leaves. A summary
//! exists only when every word's effect is exact, so whatever acts on one may
//! skip the dynamic accounting that would have found the same counts.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const lower = @import("lower.zig");
const prims = @import("prims.zig");

const Header = value.ListHandle;
const Fiber = machine.Fiber;

pub const Summary = lower.Counts;

/// A quotation longer than this is not summarized.
const max_forms = 16;
/// A word body longer than this has no summary.
const max_body_forms = 64;
/// Forms one walk may visit across the quotations and word bodies it
/// descends into, which bounds the walk by a constant rather than by the
/// program. A walk that runs out records nothing, so a later one resumes
/// from the bodies this one finished.
const max_visited = 128;
/// How far a walk descends through nested quotations and word bodies.
const max_depth = 8;
/// The most a summary may consume or leave.
const max_values = 32;

/// The summary of a quotation about to run at `site`, or null when any word
/// leaves the counts to run time: a word that does not resolve, a native
/// word, a word behind a checked module boundary, a builtin whose
/// effect holds a row and has no rule here, or a combinator whose quotation
/// is not a literal.
///
/// A word's body is summarized once per definition, and a quotation's answer
/// is remembered by the fiber; either lasts until a publication, so a
/// redefinition is read as redefined.
pub fn of(fiber: *Fiber, site: machine.ExecutionSite, quotation: *Header) error{OutOfMemory}!?Summary {
    if (quotation.length() > max_forms) return null;
    const publication = fiber.currentPublication();
    if (fiber.summaries.find(quotation, site, publication)) |known| return known.summary;
    var visited: usize = 0;
    const summary: ?Summary = switch (try summarize(Kept, fiber, &visited, quotation, site, 0)) {
        .exact => |summary| summary,
        .none => null,
        // A later walk resumes from the bodies this one finished, so the
        // answer is not yet known.
        .exhausted => return null,
    };
    // Words read under different publications say nothing together.
    if (fiber.currentPublication() != publication) return null;
    try fiber.summaries.remember(fiber.allocator, fiber.releases, quotation, site, publication, summary);
    return summary;
}

/// The summary of a quotation literal about to run at `site`, read under the
/// caller's bounds and not remembered: for a reader that looks at a list
/// once and may look at longer quotations than a summary is kept for. A word's
/// body is read as `of` reads it.
pub fn read(
    fiber: *Fiber,
    site: machine.ExecutionSite,
    quotation: *Header,
    comptime bounds: struct { max_forms: usize, max_visited: usize },
) error{OutOfMemory}!?Summary {
    if (quotation.length() > bounds.max_forms) return null;
    const publication = fiber.currentPublication();
    var visited: usize = 0;
    const Reader = Counting(.{
        .capacity = 2 * max_values + 1,
        .max_operand_forms = bounds.max_forms,
        .max_visited = bounds.max_visited,
        .max_depth = max_depth,
        .branches = true,
    });
    const summary: Summary = switch (try summarize(Reader, fiber, &visited, quotation, site, 0)) {
        .exact => |summary| summary,
        .none, .exhausted => return null,
    };
    // Words read under different publications say nothing together.
    if (fiber.currentPublication() != publication) return null;
    return summary;
}

/// Whether `word`, run at `site`, has a summary. A word that has one moves
/// only the values its counts say, and leaves no local bound.
pub fn wordHasSummary(fiber: *Fiber, site: machine.ExecutionSite, word: value.Symbol) error{OutOfMemory}!bool {
    var visited: usize = 0;
    return switch (try fiber.summaryTarget(word, site)) {
        .none => false,
        .source => |source| try body(fiber, &visited, source) == .exact,
        .builtin => |builtin| !prims.unsummarizable(builtin.primitive) and
            lower.exact(builtin.effect) != null and !lower.takesQuotation(builtin.effect.?),
    };
}

/// The failure of a word that was running its quotations by their summaries
/// when a publication changed what those summaries rested on.
pub fn failDefinitionsChanged(fiber: *Fiber) machine.MachineError {
    return fiber.fail(.domain, "definitions changed while a quotation was running by its stack summary");
}

/// What a fiber has read of the quotations it applied, all in one
/// publication: a quotation applied again at the same site is answered
/// without a walk. An entry holds its quotation, so the address it is found
/// by stays that quotation's.
///
/// A fixed number of places, and a quotation is looked for in the `reach`
/// places from its own, so quotations that share a place each keep an entry
/// and two of them applied in one loop do not walk afresh on every turn. One
/// that finds all of those taken replaces the first, so the fiber holds at
/// most `capacity` quotations it would otherwise have let go, and every
/// operation is bounded by `reach`.
pub const Cache = struct {
    const capacity = 128;
    const reach = 8;
    const Entry = struct {
        /// Null for an empty place.
        quotation: ?*Header = null,
        /// The root the quotation ran in, which decides whether a module
        /// word it calls is behind a checked boundary. Held by serial, not
        /// address: a scope released unpublished frees its address for the
        /// next one, and the entry holds no reference to keep it.
        scope: u64 = 0,
        provenance: u64 = 0,
        exact: bool = false,
        consumed: u8 = 0,
        produced: u8 = 0,
    };

    pub const Known = struct { summary: ?Summary };

    entries: []Entry = &.{},
    /// The publication every present entry was read in.
    publication: u64 = 0,

    fn place(quotation: *const Header) usize {
        return @intCast((@as(u64, @intFromPtr(quotation)) >> 4) *% 0x9E3779B97F4A7C15 >> (64 - std.math.log2(capacity)));
    }

    /// What was read of `quotation` at `site` in `publication`, if anything.
    pub inline fn find(self: *const Cache, quotation: *const Header, site: machine.ExecutionSite, publication: u64) ?Known {
        if (self.publication != publication or self.entries.len == 0) return null;
        const entry = self.entryFor(quotation, site) orelse return null;
        if (entry.quotation == null) return null;
        return .{ .summary = if (entry.exact) .{ .consumed = entry.consumed, .produced = entry.produced } else null };
    }

    /// The entry holding `quotation` at `site`, or the first empty one in
    /// reach of its place; null when every place in reach holds another.
    /// Entries leave only all together, so an empty place ends the search.
    inline fn entryFor(self: *const Cache, quotation: *const Header, site: machine.ExecutionSite) ?*Entry {
        var index = place(quotation);
        for (0..reach) |_| {
            const entry = &self.entries[index];
            if (entry.quotation == null) return entry;
            if (entry.quotation == quotation and entry.scope == site.scope.serial and
                entry.provenance == @backingInt(site.registration_provenance.sourceId())) return entry;
            index = (index + 1) & (capacity - 1);
        }
        return null;
    }

    /// Records what a walk in `publication` found, null for no summary.
    pub fn remember(
        self: *Cache,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        quotation: *Header,
        site: machine.ExecutionSite,
        publication: u64,
        summary: ?Summary,
    ) error{OutOfMemory}!void {
        if (self.entries.len == 0) {
            const entries = try allocator.alloc(Entry, capacity);
            @memset(entries, .{});
            self.entries = entries;
        }
        if (self.publication != publication) {
            self.clear(releases);
            self.publication = publication;
        }
        const entry = self.entryFor(quotation, site) orelse &self.entries[place(quotation)];
        if (entry.quotation) |held| releases.releaseHeader(held);
        heap.incRef(quotation);
        entry.* = .{
            .quotation = quotation,
            .scope = site.scope.serial,
            .provenance = @backingInt(site.registration_provenance.sourceId()),
            .exact = summary != null,
            .consumed = if (summary) |found| @intCast(found.consumed) else 0,
            .produced = if (summary) |found| @intCast(found.produced) else 0,
        };
    }

    fn clear(self: *Cache, releases: *heap.ReleaseDomain) void {
        for (self.entries) |*entry| if (entry.quotation) |held| {
            releases.releaseHeader(held);
            entry.quotation = null;
        };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        self.clear(releases);
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = .{};
    }
};

/// What is known of a source definition's stack summary.
const BodySummary = union(enum) {
    unread,
    /// A walk of the body is in progress: a word that reaches itself has no
    /// summary.
    reading,
    none,
    exact: struct { consumed: u8, produced: u8 },
};

/// What a fiber has read of the bodies of the source words its summaries
/// called, all in one publication. A body's summary depends on what the
/// body's own words denote, which no reader can see change without a
/// publication, and on the root the body runs in, which decides whether a
/// module word it calls is behind a checked boundary.
///
/// An entry is found by its definition's address and holds no reference.
/// Invariant: an entry found under the publication value it was recorded
/// under is of the definition asked about. The recording turn kept its
/// definition alive, so another definition took the address only after the
/// record, and a reader can see it only in a publication, which advances the
/// value before its first visible store: whoever reads the later definition
/// from a cell or a directory then reads a later value.
///
/// One entry per place and a fixed number of places, so every operation is
/// bounded by that constant. A body that lands on an occupied place replaces
/// what was there, a walk in progress included: such a walk is then bounded
/// by the forms it may visit, as every walk is.
pub const Bodies = struct {
    const capacity = 64;
    const Entry = struct {
        /// Null for an empty place.
        definition: ?*const env.Definition = null,
        /// The root the body ran in, by serial as `Cache` holds it.
        scope: u64 = 0,
        summary: BodySummary = .unread,
    };

    entries: []Entry = &.{},
    /// The publication every present entry was read in.
    publication: u64 = 0,

    fn place(definition: *const env.Definition) usize {
        return @intCast((@as(u64, @intFromPtr(definition)) >> 4) *% 0x9E3779B97F4A7C15 >> (64 - std.math.log2(capacity)));
    }

    fn find(self: *const Bodies, definition: *const env.Definition, scope: u64, publication: u64) BodySummary {
        if (self.publication != publication or self.entries.len == 0) return .unread;
        const entry = &self.entries[place(definition)];
        return if (entry.definition == definition and entry.scope == scope) entry.summary else .unread;
    }

    /// Records what is known of `definition`'s body, run in the root
    /// `scope`, in `publication`.
    fn record(
        self: *Bodies,
        allocator: std.mem.Allocator,
        definition: *const env.Definition,
        scope: u64,
        publication: u64,
        summary: BodySummary,
    ) error{OutOfMemory}!void {
        if (self.entries.len == 0) {
            const entries = try allocator.alloc(Entry, capacity);
            @memset(entries, .{});
            self.entries = entries;
        }
        if (self.publication != publication) {
            @memset(self.entries, .{});
            self.publication = publication;
        }
        self.entries[place(definition)] = .{ .definition = definition, .scope = scope, .summary = summary };
    }

    /// Leaves `definition`'s body, run in `scope`, unread.
    fn forget(self: *Bodies, definition: *const env.Definition, scope: u64) void {
        if (self.entries.len == 0) return;
        const entry = &self.entries[place(definition)];
        if (entry.definition == definition and entry.scope == scope) entry.* = .{};
    }

    pub fn deinit(self: *Bodies, allocator: std.mem.Allocator) void {
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = .{};
    }
};

const Result = union(enum) {
    exact: Summary,
    /// Some word has no summary.
    none,
    /// The walk ran out before it could tell.
    exhausted,
};

/// The summary of `code` run at `site` with nothing known beneath it.
fn summarize(comptime Reader: type, fiber: *Fiber, visited: *usize, code: *Header, site: machine.ExecutionSite, depth: usize) error{OutOfMemory}!Result {
    var counting: Reader = .{};
    var walker: lower.Walker(Reader) = .{ .fiber = fiber, .mode = &counting, .visited = visited };
    // The values beneath, one more than a summary may consume, so a walk
    // that takes them all has gone too far.
    const floor = max_values + 1;
    @memset(walker.open(floor), .{});
    walker.run(code, site, depth) catch |err| switch (err) {
        error.Unread => return .none,
        error.Exhausted => return .exhausted,
        error.OutOfMemory => |oom| return oom,
    };
    const counts = walker.counts(floor);
    if (counts.consumed > max_values or counts.produced > max_values) return .none;
    return .{ .exact = counts };
}

/// The summary of a source word's body, read from what the fiber remembers of
/// its definition or walked and recorded there. The walk is within one turn,
/// which is what keeps the definition and its body.
fn body(
    fiber: *Fiber,
    visited: *usize,
    source: @FieldType(machine.SummaryTarget, "source"),
) error{OutOfMemory}!Result {
    const publication = fiber.currentPublication();
    const scope = source.site.scope.serial;
    switch (fiber.bodies.find(source.definition, scope, publication)) {
        .exact => |counts| return .{ .exact = .{ .consumed = counts.consumed, .produced = counts.produced } },
        .none, .reading => return .none,
        .unread => {},
    }
    if (source.code.length() > max_body_forms) {
        try fiber.bodies.record(fiber.allocator, source.definition, scope, publication, .none);
        return .none;
    }
    try fiber.bodies.record(fiber.allocator, source.definition, scope, publication, .reading);
    // A walk that fails leaves the body unread, not mid-read forever.
    errdefer fiber.bodies.forget(source.definition, scope);
    const result = try summarize(Kept, fiber, visited, source.code, source.site, 1);
    const recorded: BodySummary = switch (result) {
        .exact => |summary| .{ .exact = .{ .consumed = @intCast(summary.consumed), .produced = @intCast(summary.produced) } },
        .none => .none,
        .exhausted => .unread,
    };
    // Words read under different publications say nothing together.
    if (recorded == .unread or fiber.currentPublication() != publication)
        fiber.bodies.forget(source.definition, scope)
    else
        try fiber.bodies.record(fiber.allocator, source.definition, scope, publication, recorded);
    return result;
}

/// The reader whose answers are remembered, under the bounds of a summary.
const Kept = Counting(.{
    .capacity = 2 * max_values + 1,
    .max_operand_forms = max_forms,
    .max_visited = max_visited,
    .max_depth = max_depth,
    .branches = true,
});

/// The reader that only counts: it keeps nothing of a value. A word's body
/// is read under a summary's bounds whatever the reader's own, since its
/// answer is recorded with the word.
fn Counting(comptime bounds: lower.Policy) type {
    return struct {
        const Self = @This();
        pub const Payload = void;
        pub const policy = bounds;
        const Item = lower.Slot(void);

        pub fn constant(_: *Self, _: value.Value) ?void {}

        pub fn builtin(_: *Self, _: env.PrimitiveImpl, _: value.Symbol, _: lower.At, _: []const Item, outputs: []Item) bool {
            @memset(outputs, .{});
            return true;
        }

        pub fn source(
            _: *Self,
            fiber: *Fiber,
            visited: *usize,
            target: @FieldType(machine.SummaryTarget, "source"),
        ) (lower.Stop || error{OutOfMemory})!Summary {
            return switch (try body(fiber, visited, target)) {
                .exact => |summary| summary,
                .none => error.Unread,
                .exhausted => error.Exhausted,
            };
        }
    };
}
