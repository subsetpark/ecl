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

/// Starts the failure driver over the fiber's pending failure. The failure
/// stays pending when this fails.
pub fn start(via: *Unwinding) error{OutOfMemory}!void {
    const evaluator = via.fiber();
    const capacity = std.math.add(usize, evaluator.frames.items.len, 3) catch
        return error.OutOfMemory;
    const trace = try evaluator.allocator.alloc(intern.TraceWord, capacity);
    errdefer evaluator.allocator.free(trace);
    const resolved = try evaluator.allocator.alloc(u32, capacity);
    errdefer evaluator.allocator.free(resolved);
    const driver = try evaluator.allocator.create(FailureDriver);
    driver.* = .{
        .allocator = evaluator.allocator,
        .failure = via.takeFailure(),
        .trace = trace,
        .resolved = resolved,
        .state = .{ .trace = evaluator.frames.items.len },
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
                .value => |*cursor| cursor.retire(releases),
                .unwinding => |unwinding| releases.releaseValue(unwinding.error_value),
                .outcome_name => |outcome| releases.releaseValue(outcome.error_value),
                .outcome_prepare => |item| releases.releaseValue(item),
                .outcome => |*outcome| {
                    outcome.builder.retire(releases);
                    releases.releaseValue(outcome.error_value);
                },
                .caught => |item| releases.releaseValue(item),
                .trace, .spell, .locate, .failed => {},
            }
        }
    };

    allocator: std.mem.Allocator,
    failure: EclErr,
    /// The activation chain, innermost first. Entries are trace words rather
    /// than atoms because a module-local word's spelling depends on the
    /// registration it ran under; `resolved` holds the interned spellings.
    trace: []intern.TraceWord,
    resolved: []u32,
    trace_count: usize = 0,
    outcome_pair: [1]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }},
    state: State,

    fn appendInitial(self: *FailureDriver, via: *Unwinding) void {
        if (self.failure.word) |word| self.appendTrace(word);
        if (self.failure.trace_parent) |word| self.appendTrace(word);
        if (via.currentTrace()) |word| self.appendTrace(word);
    }
    fn appendTrace(self: *FailureDriver, word: intern.TraceWord) void {
        self.trace[self.trace_count] = word;
        self.trace_count += 1;
    }
    pub fn deinit(
        self: *FailureDriver,
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
    ) void {
        self.state.deinit(releases);
        self.failure.retire(releases);
        storage_allocator.free(self.trace);
        storage_allocator.free(self.resolved);
    }
    fn beginLocation(self: *FailureDriver, via: *Unwinding) void {
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
                },
                location,
            ),
        };
    }
    /// Draws on the fiber's budget, but yields rather than stepping when it is
    /// spent: a stepped driver's charge can observe cancellation, and an
    /// unwind already in progress must not start another failure.
    pub fn advance(via: *Unwinding, self: *FailureDriver) MachineError!WorkProgress {
        const evaluator = via.fiber();
        const work = evaluator.workBudget();
        while (switch (self.state) {
            .value, .outcome => !work.exhausted(),
            else => work.spend(),
        }) switch (self.state) {
            .trace => |*frame_index| {
                if (frame_index.* == 0) {
                    self.state = .{ .spell = 0 };
                    continue;
                }
                frame_index.* -= 1;
                if (via.frameTrace(frame_index.*)) |word| self.appendTrace(word);
            },
            // Qualifying a module-local word interns its spelling. Failures
            // are rare, so this is the one place that cost is paid.
            .spell => |resolve_index| {
                if (resolve_index == self.trace_count) {
                    self.beginLocation(via);
                    continue;
                }
                const cursor = try intern.TraceWordCursor.init(
                    self.allocator,
                    self.trace[resolve_index],
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
            .locate => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |location| self.beginValue(location),
            },
            .value => |*cursor| switch (try cursor.advance(work)) {
                .pending => return .{ .yielded = .settle },
                .complete => |item| {
                    cursor.retire(evaluator.releases);
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
