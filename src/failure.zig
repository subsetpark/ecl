//! Turning a pending failure into its language value: the activation trace,
//! its spellings and source location, the error value, and the `'err` outcome
//! a catching boundary receives. The machine does the unwinding itself.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const error_values = @import("error_value.zig");
const machine = @import("machine.zig");
const Value = value.Value;
const Unwinding = machine.Unwinding;
const EclErr = machine.EclErr;
const MachineError = machine.MachineError;
const WorkProgress = machine.WorkProgress;
const ErrorValueCursor = error_values.ErrorValueCursor;
const SitesCursor = error_values.SitesCursor;
const TraceEntry = machine.TraceEntry;

/// Starts the failure driver over the fiber's pending failure. The failure
/// stays pending when this fails.
pub fn start(via: *Unwinding) error{OutOfMemory}!void {
    const fiber = via.fiber();
    const capacity = std.math.add(usize, fiber.frames.items.len, 3) catch
        return error.OutOfMemory;
    const trace = try fiber.allocator.alloc(TraceEntry, capacity);
    errdefer fiber.allocator.free(trace);
    const resolved = try fiber.allocator.alloc(u32, capacity);
    errdefer fiber.allocator.free(resolved);
    const located = try fiber.allocator.alloc(?spans.LocatedSpan, capacity);
    errdefer fiber.allocator.free(located);
    const driver = try fiber.allocator.create(FailureDriver);
    driver.* = .{
        .allocator = fiber.allocator,
        .failure = via.takeFailure(),
        .trace = trace,
        .resolved = resolved,
        .located = located,
        .state = .{ .trace = fiber.frames.items.len },
    };
    driver.appendInitial(via);
    via.adoptDriver(driver);
}

const FailureDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    const State = union(enum) {
        trace: usize,
        spell: usize,
        resolve: struct { index: usize, cursor: intern.TraceWordCursor },
        /// Finds each trace entry's call site in the archive.
        locate_sites: usize,
        sites: SitesCursor,
        locate: spans.SpanArchive.LocateCursor,
        value: ErrorValueCursor,
        /// The machine unwinds to the boundary that catches the value, or to
        /// the fiber's entry.
        unwinding: struct { error_value: Value, cursor: machine.Unwind },
        outcome_name: struct { error_value: Value, cursor: intern.InternInsertionCursor },
        outcome_prepare: Value,
        outcome: struct {
            error_value: Value,
            builder: dict.Materializer,
        },
        caught: Value,
        failed,

        fn deinit(self: *State, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .resolve => |*resolve| resolve.cursor.deinit(),
                .sites => |*cursor| cursor.retire(),
                .value => |*cursor| cursor.retire(releases),
                .unwinding => |unwinding| releases.releaseValue(unwinding.error_value),
                .outcome_name => |outcome| releases.releaseValue(outcome.error_value),
                .outcome_prepare => |item| releases.releaseValue(item),
                .outcome => |*outcome| {
                    outcome.builder.retire(releases);
                    releases.releaseValue(outcome.error_value);
                },
                .caught => |item| releases.releaseValue(item),
                .trace, .spell, .locate_sites, .locate, .failed => {},
            }
        }
    };

    allocator: std.mem.Allocator,
    failure: EclErr,
    /// The activation chain, innermost first. Entries carry trace words
    /// rather than atoms because a module-local word's spelling depends on
    /// the registration it ran under; `resolved` holds the interned
    /// spellings. Each entry's call site borrows code the fiber's frames keep
    /// alive until the unwind, which starts only once the value is built.
    trace: []TraceEntry,
    resolved: []u32,
    /// Each entry's call site in source, where the archive knows it.
    located: []?spans.LocatedSpan,
    trace_count: usize = 0,
    /// The trace entry whose call site the failure is reported at, or null for
    /// the failing token itself; built by `attribute` while sites are located.
    attributed: ?usize = null,
    attribution_closed: bool = false,
    /// The `sites` list, owned until the error value has been built.
    sites: ?Value = null,
    outcome_pair: [1]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }},
    state: State,

    fn appendInitial(self: *FailureDriver, via: *Unwinding) void {
        // The failing word was called at the failing token.
        if (self.failure.word) |word| self.appendTrace(.{
            .word = word,
            // A word reported at its caller has no known call site here, and
            // the failing token is inside its body.
            .site = if (self.failure.word_attribution == .caller) null else if (self.failure.site) |site| switch (site) {
                .token => |token| token,
                .contract_quotation, .explicit_location => null,
            } else null,
            .attribution = self.failure.word_attribution,
        });
        if (self.failure.trace_parent) |word| self.appendTrace(.{
            .word = word,
            .site = null,
            .attribution = self.failure.trace_parent_attribution,
        });
        if (via.currentTrace()) |entry| self.appendTrace(entry);
    }
    fn appendTrace(self: *FailureDriver, entry: TraceEntry) void {
        self.trace[self.trace_count] = entry;
        self.trace_count += 1;
    }
    /// Extends the attribution walk over entry `index`, called once per entry
    /// in trace order as its call site is located, so the walk is charged with
    /// the locating. A failure inside a helper word is the failure of the code
    /// that called it, so the report moves out through each enclosing helper to
    /// the first activation that is not one. The failing word's own entry is
    /// the failing token, unless that word is itself a helper reported at its
    /// caller. An unknown call site ends the walk but keeps the attribution:
    /// the report omits a position rather than citing the helper body.
    fn attribute(self: *FailureDriver, index: usize) void {
        if (self.attribution_closed) return;
        const first = @intFromBool(self.failure.word != null and self.failure.word_attribution != .caller);
        if (index < first) return;
        if (self.trace[index].attribution != .caller) {
            self.attribution_closed = true;
            return;
        }
        self.attributed = index;
        if (self.located[index] == null) self.attribution_closed = true;
    }
    pub fn deinit(
        self: *FailureDriver,
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
    ) void {
        self.state.deinit(releases);
        self.failure.retire(releases);
        if (self.sites) |sites| releases.releaseValue(sites);
        storage_allocator.free(self.trace);
        storage_allocator.free(self.resolved);
        storage_allocator.free(self.located);
    }
    fn beginLocation(self: *FailureDriver, via: *Unwinding) void {
        if (self.attributed) |index| return self.beginValue(self.located[index]);
        switch (via.locate(&self.failure)) {
            .locating => |cursor| self.state = .{ .locate = cursor },
            .located => |location| self.beginValue(location),
        }
    }
    fn beginValue(self: *FailureDriver, location: ?spans.LocatedSpan) void {
        self.state = .{
            .value = .init(
                self.allocator,
                &self.failure,
                // `appendInitial` puts the failing word first when there is one,
                // so its spelling is the first resolved entry.
                .{
                    .word = if (self.failure.word != null) self.resolved[0] else null,
                    .trace = self.resolved[0..self.trace_count],
                    .sites = self.sites,
                },
                location,
            ),
        };
    }
    /// An unwind in progress must not start another failure.
    pub const cancellation: machine.DriverCancellation = .own;

    /// Draws on the fiber's budget, but yields rather than stepping when it is
    /// spent: a stepped driver's charge can observe cancellation, and an
    /// unwind already in progress must not start another failure.
    pub fn advance(via: *Unwinding, self: *FailureDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        const work = fiber.workBudget();
        while (switch (self.state) {
            .sites, .value, .outcome => !work.exhausted(),
            else => work.spend(),
        }) switch (self.state) {
            .trace => |*frame_index| {
                if (frame_index.* == 0) {
                    self.state = .{ .spell = 0 };
                    continue;
                }
                frame_index.* -= 1;
                if (via.frameTrace(frame_index.*)) |entry| self.appendTrace(entry);
            },
            // Qualifying a module-local word interns its spelling. Failures
            // are rare, so this is the one place that cost is paid.
            .spell => |resolve_index| {
                if (resolve_index == self.trace_count) {
                    self.state = .{ .locate_sites = 0 };
                    continue;
                }
                const cursor = try intern.TraceWordCursor.init(
                    self.allocator,
                    self.trace[resolve_index].word,
                );
                self.state = .{ .resolve = .{
                    .index = resolve_index,
                    .cursor = cursor,
                } };
            },
            .resolve => |*resolve| switch (try resolve.cursor.advance()) {
                .pending => {},
                .complete => |id| {
                    const index = resolve.index;
                    resolve.cursor.deinit();
                    self.resolved[index] = id;
                    self.state = .{ .spell = index + 1 };
                },
            },
            .locate_sites => |*index| {
                if (index.* == self.trace_count) {
                    self.state = .{ .sites = .init(
                        self.allocator,
                        fiber.releases,
                        self.located[0..self.trace_count],
                    ) };
                    continue;
                }
                self.located[index.*] = if (self.trace[index.*].site) |site| located: {
                    var cursor = via.locateSite(site);
                    break :located switch (cursor.advance()) {
                        .pending => unreachable,
                        .complete => |location| location,
                    };
                } else null;
                self.attribute(index.*);
                index.* += 1;
            },
            .sites => |*cursor| switch (try cursor.advance(work)) {
                .pending => return .{ .yielded = .settle },
                .complete => |sites| {
                    cursor.retire();
                    self.sites = sites;
                    self.beginLocation(via);
                },
            },
            .locate => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |location| self.beginValue(location),
            },
            .value => |*cursor| switch (try cursor.advance(work)) {
                .pending => return .{ .yielded = .settle },
                .complete => |item| {
                    cursor.retire(fiber.releases);
                    self.state = .{ .unwinding = .{
                        .error_value = item,
                        .cursor = via.beginUnwind(),
                    } };
                },
            },
            .unwinding => |*unwinding| switch (unwinding.cursor.advance(via)) {
                .pending => {},
                .uncaught => {
                    via.finishFailed(unwinding.error_value);
                    self.state = .failed;
                },
                .caught => self.state = .{ .outcome_name = .{
                    .error_value = unwinding.error_value,
                    .cursor = intern.insertionCursor("err"),
                } },
            },
            .outcome_name => |*outcome| switch (try outcome.cursor.advance()) {
                .pending => {},
                .complete => |key| {
                    const error_value = outcome.error_value;
                    self.outcome_pair[0] = .{ .{ .symbol = .{ .name = key } }, error_value };
                    self.state = .{ .outcome_prepare = error_value };
                },
            },
            .outcome_prepare => |error_value| {
                const builder = try dict.Materializer.init(
                    self.allocator,
                    &self.outcome_pair,
                    false,
                );
                self.state = .{ .outcome = .{
                    .error_value = error_value,
                    .builder = builder,
                } };
            },
            .outcome => |*outcome_state| switch (try outcome_state.builder.advance(work)) {
                .pending => return .{ .yielded = .settle },
                .duplicate_key => unreachable,
                .complete => |outcome| {
                    const error_value = outcome_state.error_value;
                    outcome_state.builder.deinit();
                    self.state = .{ .caught = error_value };
                    via.finishCaught();
                    return .{ .output = outcome };
                },
            },
            .caught => unreachable,
            .failed => return .failed,
        };
        return .{ .yielded = .settle };
    }
};
