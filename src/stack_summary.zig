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
const WordResolutions = @import("word_resolutions.zig").WordResolutions;

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
/// A word's body is summarized once per resolution of the word and recorded
/// with it, and a quotation's answer is remembered by the fiber, so either
/// lasts until a publication and a redefinition is read as redefined.
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
        .source => |source| try body(fiber, &visited, word, site, source) == .exact,
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
/// One entry per place and a fixed number of places: a quotation that lands
/// on an occupied place replaces what was there, so the fiber holds at most
/// `capacity` quotations it would otherwise have let go, and every operation
/// is bounded by that constant.
pub const Cache = struct {
    const capacity = 64;
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
        const entry = &self.entries[place(quotation)];
        if (entry.quotation != quotation or entry.scope != site.scope.serial or
            entry.provenance != WordResolutions.provenanceKey(site.registration_provenance)) return null;
        return .{ .summary = if (entry.exact) .{ .consumed = entry.consumed, .produced = entry.produced } else null };
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
        const entry = &self.entries[place(quotation)];
        if (entry.quotation) |held| releases.releaseHeader(held);
        heap.incRef(quotation);
        entry.* = .{
            .quotation = quotation,
            .scope = site.scope.serial,
            .provenance = WordResolutions.provenanceKey(site.registration_provenance),
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

/// The summary of a source word's body, read from the word's remembered
/// resolution or walked and recorded there.
fn body(
    fiber: *Fiber,
    visited: *usize,
    word: value.Symbol,
    site: machine.ExecutionSite,
    source: @FieldType(machine.SummaryTarget, "source"),
) error{OutOfMemory}!Result {
    switch (source.summary) {
        .exact => |counts| return .{ .exact = .{ .consumed = counts.consumed, .produced = counts.produced } },
        .none, .reading => return .none,
        .unread => {},
    }
    if (source.code.length() > max_body_forms) {
        fiber.recordSummary(word, site, source.definition, .none);
        return .none;
    }
    // The walk resolves more words, which may let go of this one's
    // definition, so the body is held across it.
    heap.incRef(source.code);
    defer fiber.releases.releaseHeader(source.code);
    fiber.recordSummary(word, site, source.definition, .reading);
    // A walk that fails leaves the body unread, not mid-read forever.
    errdefer fiber.recordSummary(word, site, source.definition, .unread);
    const result = try summarize(Kept, fiber, visited, source.code, source.site, 1);
    fiber.recordSummary(word, site, source.definition, switch (result) {
        .exact => |summary| .{ .exact = .{ .consumed = @intCast(summary.consumed), .produced = @intCast(summary.produced) } },
        .none => .none,
        .exhausted => .unread,
    });
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
            word: value.Symbol,
            site: machine.ExecutionSite,
            target: @FieldType(machine.SummaryTarget, "source"),
        ) (lower.Stop || error{OutOfMemory})!Summary {
            return switch (try body(fiber, visited, word, site, target)) {
                .exact => |summary| summary,
                .none => error.Unread,
                .exhausted => error.Exhausted,
            };
        }
    };
}
