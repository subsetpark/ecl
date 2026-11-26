//! What a quotation does to the stack, read from its words before it runs:
//! how many values it takes from beneath and how many it leaves. A summary
//! exists only when every word's effect is exact, so whatever acts on one may
//! skip the dynamic accounting that would have found the same counts.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const combinators = @import("combinators.zig");
const prims = @import("prims.zig");
const WordResolutions = @import("word_resolutions.zig").WordResolutions;

const Header = value.ListHandle;
const Fiber = machine.Fiber;

pub const Summary = struct {
    /// Values the quotation takes from beneath where it starts.
    consumed: u32,
    /// Values it leaves where those were.
    produced: u32,
};

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
/// The most locals one quotation or body may hold bound at once.
const max_locals = 16;

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
    var walk: Walk = .{ .fiber = fiber, .publication = publication };
    const summary: ?Summary = switch (try walk.summarize(quotation, site, 0)) {
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

/// Whether `word`, run at `site`, has a summary. A word that has one moves
/// only the values its counts say, and leaves no local bound.
pub fn wordHasSummary(fiber: *Fiber, site: machine.ExecutionSite, word: value.Symbol) error{OutOfMemory}!bool {
    var walk: Walk = .{ .fiber = fiber, .publication = fiber.currentPublication() };
    return switch (try fiber.summaryTarget(word, site)) {
        .none => false,
        .source => |source| try walk.body(word, site, source) == .exact,
        .builtin => |builtin| !prims.unsummarizable(builtin.primitive) and
            Walk.exact(builtin.effect) != null and !Walk.takesQuotation(builtin.effect.?),
    };
}

/// The failure of a cleave or spread that was running by its quotations'
/// summaries when a publication changed what those summaries rested on.
pub fn failDefinitionsChanged(fiber: *Fiber) machine.MachineError {
    return fiber.fail(.domain, "definitions changed while a cleave or spread was running");
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

const Walk = struct {
    fiber: *Fiber,
    publication: u64,
    visited: usize = 0,

    fn summarize(self: *Walk, code: *Header, site: machine.ExecutionSite, depth: usize) error{OutOfMemory}!Result {
        const length: usize = @intCast(code.length());
        if (depth > max_depth) return .exhausted;
        self.visited += length;
        if (self.visited > max_visited) return .exhausted;
        var stack: Abstract = .{};
        for (0..length) |index| {
            // Every path below that skips the fall-through check
            // (`continue`) is covered by checking before the next form.
            if (stack.reach > max_values or stack.height > max_values) return .none;
            const word = switch (list.atUnchecked(.{ .list = code }, index)) {
                .symbol => |reference| reference,
                .list => |literal| {
                    stack.push(literal);
                    continue;
                },
                else => {
                    stack.push(null);
                    continue;
                },
            };
            if (env.isQuoted(word.slot)) {
                stack.push(null);
                continue;
            }
            if (env.localOperand(word.slot)) |count_or_index| {
                if (!stack.local(self.fiber.environment.localsWords(), word.name, count_or_index)) return .none;
                continue;
            }
            const applied: Result = switch (try self.fiber.summaryTarget(word, site)) {
                .none => .none,
                .source => |source| try self.body(word, site, source),
                // An exact declared effect says everything; only a builtin
                // whose effect holds a row can have a rule of its own.
                .builtin => |builtin| if (prims.unsummarizable(builtin.primitive))
                    .none
                else if (exact(builtin.effect)) |declared|
                    (if (takesQuotation(builtin.effect.?)) Result.none else .{ .exact = declared })
                else switch (combinators.flow(builtin.primitive)) {
                    .declared => .none,
                    .apply => try self.operand(&stack, site, depth),
                    .dip => dip: {
                        const inner = try self.operand(&stack, site, depth);
                        if (inner != .exact) break :dip inner;
                        stack.pop(1);
                        stack.apply(inner.exact);
                        stack.push(null);
                        continue;
                    },
                    .branch => branch: {
                        const otherwise = try self.operand(&stack, site, depth);
                        if (otherwise != .exact) break :branch otherwise;
                        const then = try self.operand(&stack, site, depth);
                        if (then != .exact) break :branch then;
                        stack.pop(1);
                        // Which branch runs is data, so the counts are known
                        // only when the branches agree.
                        if (!std.meta.eql(then.exact, otherwise.exact)) break :branch .none;
                        break :branch then;
                    },
                    // A measured word leaves its quotation's results and the
                    // inputs it consumed.
                    .measured => measured: {
                        const inner = try self.operand(&stack, site, depth);
                        if (inner != .exact) break :measured inner;
                        break :measured .{ .exact = .{
                            .consumed = inner.exact.consumed,
                            .produced = inner.exact.produced + inner.exact.consumed,
                        } };
                    },
                    .cleave => |count| cleave: {
                        var total: Summary = .{ .consumed = 0, .produced = 0 };
                        for (0..count) |_| {
                            const inner = try self.operand(&stack, site, depth);
                            if (inner != .exact) break :cleave inner;
                            total.consumed = @max(total.consumed, inner.exact.consumed);
                            total.produced += inner.exact.produced;
                        }
                        break :cleave .{ .exact = total };
                    },
                    .spread => |count| spread: {
                        var total: Summary = .{ .consumed = 0, .produced = 0 };
                        for (0..count) |_| {
                            const inner = try self.operand(&stack, site, depth);
                            if (inner != .exact) break :spread inner;
                            total.consumed += inner.exact.consumed;
                            total.produced += inner.exact.produced;
                        }
                        break :spread .{ .exact = total };
                    },
                },
            };
            if (applied != .exact) return applied;
            stack.apply(applied.exact);
            if (stack.reach > max_values or stack.height > max_values) return .none;
        }
        if (stack.reach > max_values or stack.height > max_values) return .none;
        // A local left bound stays visible to the caller, which a summary
        // cannot describe.
        if (stack.bound != 0) return .none;
        return .{ .exact = .{ .consumed = @intCast(stack.reach), .produced = @intCast(stack.height) } };
    }

    /// The summary of a source word's body, read from the word's remembered
    /// resolution or walked and recorded there.
    fn body(
        self: *Walk,
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
            self.fiber.recordSummary(word, site, source.definition, .none);
            return .none;
        }
        // The walk resolves more words, which may let go of this one's
        // definition, so the body is held across it.
        heap.incRef(source.code);
        defer self.fiber.releases.releaseHeader(source.code);
        self.fiber.recordSummary(word, site, source.definition, .reading);
        // A walk that fails leaves the body unread, not mid-read forever.
        errdefer self.fiber.recordSummary(word, site, source.definition, .unread);
        const result = try self.summarize(source.code, source.site, 1);
        self.fiber.recordSummary(word, site, source.definition, switch (result) {
            .exact => |summary| .{ .exact = .{ .consumed = @intCast(summary.consumed), .produced = @intCast(summary.produced) } },
            .none => .none,
            .exhausted => .unread,
        });
        return result;
    }

    /// Whether a word's declared inputs include a quotation slot. Such a word
    /// runs the quotation where no walk reads it, and that code may publish a
    /// definition the summary rests on. Only the combinators with a rule of
    /// their own are walked, and they do not reach here.
    fn takesQuotation(effect: env.ValidatedEffect) bool {
        const header = effect.header();
        for (0..effect.inputs) |index| {
            if (list.atUnchecked(.{ .list = header }, index) == .list) return true;
        }
        return false;
    }

    fn exact(declared: ?env.ValidatedEffect) ?Summary {
        const effect = declared orelse return null;
        if (effect.result_depth != .exact) return null;
        return .{ .consumed = effect.inputs, .produced = effect.outputs };
    }

    /// The summary of the quotation on top of the abstract stack, which a
    /// combinator is about to take: known only when it is a literal the
    /// code pushed and nothing has moved since.
    fn operand(self: *Walk, stack: *Abstract, site: machine.ExecutionSite, depth: usize) error{OutOfMemory}!Result {
        const taken = stack.take() orelse return .none;
        if (taken.length() > max_forms) return .none;
        return self.summarize(taken, site.applied(), depth + 1);
    }
};

/// The stack as a summary sees it: how far beneath its start the code has
/// reached, how many values stand above that point, and which of those are
/// list literals the code pushed.
const Abstract = struct {
    reach: usize = 0,
    height: usize = 0,
    // SAFETY: a slot is read only below `height`, and `push` writes every
    // slot it raises `height` past.
    literals: [max_values + 1]?*Header = undefined,
    /// The locals this code has bound and not dropped. A quotation the code
    /// applies binds its own.
    bound: usize = 0,
    // SAFETY: a slot is read only below `bound`, and binding writes every
    // slot it raises `bound` past.
    locals: [max_locals]?*Header = undefined,

    /// One lowered locals operation: bind the top `operand` values, the
    /// deepest first; push local `operand`; or drop `operand` locals. False
    /// when the operation would fail where it runs, or binds more than a
    /// summary follows.
    fn local(self: *Abstract, words: intern.LocalsWords, name: u32, operand: u32) bool {
        if (name == words.load) {
            if (operand > max_locals - self.bound) return false;
            // Stored as the runtime stores them: the top value first, so
            // the deepest of the newest binding ends last and a read of
            // local `n` counts back from the end.
            for (0..operand) |index| self.locals[self.bound + index] = self.take();
            self.bound += operand;
        } else if (name == words.get) {
            if (operand >= self.bound) return false;
            self.push(self.locals[self.bound - 1 - operand]);
        } else if (name == words.drop) {
            if (operand > self.bound) return false;
            self.bound -= operand;
        } else return false;
        return true;
    }

    fn push(self: *Abstract, literal: ?*Header) void {
        if (self.height < self.literals.len) self.literals[self.height] = literal;
        self.height += 1;
    }
    fn pop(self: *Abstract, count: usize) void {
        if (count > self.height) {
            self.reach += count - self.height;
            self.height = 0;
        } else self.height -= count;
    }
    /// Pops one value, returning it when it is a known literal.
    fn take(self: *Abstract) ?*Header {
        if (self.height == 0) {
            self.reach += 1;
            return null;
        }
        self.height -= 1;
        return if (self.height < self.literals.len) self.literals[self.height] else null;
    }
    fn apply(self: *Abstract, summary: Summary) void {
        self.pop(summary.consumed);
        for (0..summary.produced) |_| self.push(null);
    }
};
