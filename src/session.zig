//! Persistent calculator session with transactional stack units.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const prims = @import("prims.zig");
const printer = @import("print.zig");

pub const Value = value.Value;

pub const UnitOutcome = union(enum) {
    ok,
    incomplete: reader.Incomplete,
    err: Value,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    environment: env.Env,
    stack: std.ArrayList(Value) = .empty,
    archive: spans.SpanArchive,
    output: ?*std.Io.Writer,
    arguments: Value,
    cancelled: std.atomic.Value(bool) = .init(false),
    requested_exit: ?u8 = null,
    last_max_frames: usize = 0,

    /// Convenience constructor for non-I/O tests. `pp`/`prin` report an
    /// ordinary `'io` error; executable sessions use `initWithOutput`.
    pub fn init(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) error{OutOfMemory}!Session {
        return initWithOptionalOutput(allocator, arguments, null);
    }

    /// Creates a session whose `pp`/`prin` effects write and flush through
    /// `output` during execution. The writer must outlive the session.
    pub fn initWithOutput(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: *std.Io.Writer,
    ) error{OutOfMemory}!Session {
        return initWithOptionalOutput(allocator, arguments, output);
    }

    fn initWithOptionalOutput(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: ?*std.Io.Writer,
    ) error{OutOfMemory}!Session {
        var environment = env.Env.init(allocator);
        errdefer environment.deinit();
        try prims.install(&environment);
        const argv = try argumentsValue(allocator, arguments);
        return .{
            .allocator = allocator,
            .environment = environment,
            .archive = spans.SpanArchive.init(allocator),
            .output = output,
            .arguments = argv,
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.stack.items) |item| heap.releaseValue(self.allocator, item);
        self.stack.deinit(self.allocator);
        heap.releaseValue(self.allocator, self.arguments);
        self.environment.deinit();
        self.archive.deinit();
        self.* = undefined;
    }

    pub fn runUnit(
        self: *Session,
        source_name: []const u8,
        source: []const u8,
    ) error{OutOfMemory}!UnitOutcome {
        var diag: reader.Diag = .{};
        const read_result = reader.read(self.allocator, source_name, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => {
                var parse_error = machine.EclErr.init(.parse, diag.text());
                defer parse_error.deinit(self.allocator);
                const location = spans.LocatedSpan{
                    .source_name = source_name,
                    .span = diag.span,
                };
                return .{ .err = try parse_error.toDict(self.allocator, &.{}, location) };
            },
        };
        switch (read_result) {
            .incomplete => |incomplete| return .{ .incomplete = incomplete },
            .complete => |complete| {
                var parsed = complete;
                defer parsed.deinit();
                return self.executeParsed(&parsed);
            },
        }
    }

    fn executeParsed(
        self: *Session,
        parsed: *reader.Parsed,
    ) error{OutOfMemory}!UnitOutcome {
        const root = try list.fromValuesGeneric(self.allocator, parsed.forms);
        var root_owned = true;
        defer if (root_owned) heap.releaseValue(self.allocator, root);
        const root_header = root.list;
        try self.archive.absorb(parsed, root);
        root_owned = false;

        // A depth alone cannot restore pre-existing cells consumed by a
        // failed unit (`10`, then `20 + missing`). Retain the immutable value
        // cells as the M3 transactional checkpoint; attempt/dict boundaries
        // still use the machine's O(1) base-index truncation.
        const checkpoint = try self.allocator.dupe(Value, self.stack.items);
        defer self.allocator.free(checkpoint);
        for (checkpoint) |item| heap.retainValue(item);
        var checkpoint_owned = true;
        defer if (checkpoint_owned) for (checkpoint) |item| heap.releaseValue(self.allocator, item);

        var unit = machine.Unit.init(
            self.allocator,
            self.stack,
            &self.environment,
            &self.archive,
            self.output,
            self.arguments,
            &self.cancelled,
        );
        self.stack = .empty;
        defer {
            self.stack = unit.takeStack();
            self.last_max_frames = unit.max_frames;
            self.requested_exit = unit.exit_status;
            unit.deinit();
        }
        machine.run(&unit, root_header) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint);
                checkpoint_owned = false;
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint);
                checkpoint_owned = false;
                return .{ .err = unit.takeError().? };
            },
        };
        return .ok;
    }

    pub fn stackDisplay(self: *const Session) error{OutOfMemory}![]u8 {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        for (self.stack.items, 0..) |item, index| {
            if (index > 0) allocating.writer.writeByte(' ') catch return error.OutOfMemory;
            printer.printWithAllocator(self.allocator, item, &allocating.writer) catch
                return error.OutOfMemory;
        }
        return allocating.toOwnedSlice();
    }
};

fn restoreCheckpoint(unit: *machine.Unit, checkpoint: []const Value) void {
    for (unit.stack.items) |item| heap.releaseValue(unit.allocator, item);
    unit.stack.clearRetainingCapacity();
    std.debug.assert(unit.stack.capacity >= checkpoint.len);
    unit.stack.appendSliceAssumeCapacity(checkpoint);
}

fn argumentsValue(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) error{OutOfMemory}!Value {
    const items = try allocator.alloc(Value, arguments.len);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |item| heap.releaseValue(allocator, item);
    for (arguments) |argument| {
        items[initialized] = try machine.stringValue(allocator, argument);
        initialized += 1;
    }
    return list.fromValuesGeneric(allocator, items);
}

fn dictSymbol(
    allocator: std.mem.Allocator,
    dictionary: Value,
    name: []const u8,
) ![]const u8 {
    const intern = @import("intern.zig");
    const dict = @import("dict.zig");
    const key = try intern.intern(name);
    const found = (try dict.getWithAllocator(allocator, dictionary, .{ .symbol = key })).?;
    return intern.get(found.symbol);
}

test "session runs the soul test" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("<test>", "3 4 +")) == .ok);
    const display = try session.stackDisplay();
    defer allocator.free(display);
    try std.testing.expectEqualStrings("7", display);
}

test "failed units roll back stack while definitions survive" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("<test>", "10")) == .ok);
    const failed = (try session.runUnit("<test>", "(2 *) 'double def 20 + missing")).err;
    heap.releaseValue(allocator, failed);
    try std.testing.expectEqual(@as(usize, 1), session.stack.items.len);
    try std.testing.expectEqual(@as(i64, 10), session.stack.items[0].int);
    const consumed = (try session.runUnit("<test>", "pop missing")).err;
    heap.releaseValue(allocator, consumed);
    try std.testing.expectEqual(@as(usize, 1), session.stack.items.len);
    try std.testing.expectEqual(@as(i64, 10), session.stack.items[0].int);
    try std.testing.expect((try session.runUnit("<test>", "double")) == .ok);
    try std.testing.expectEqual(@as(i64, 20), session.stack.items[0].int);
}

test "parse diagnostics become parse error dicts" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    const error_value = (try session.runUnit("broken.ecl", "1 ]")).err;
    defer heap.releaseValue(allocator, error_value);
    try std.testing.expectEqualStrings("parse", try dictSymbol(allocator, error_value, "kind"));
}

test "source-defined failures retain provenance after their unit" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("defs.ecl", "(1 0 /) 'boom def")) == .ok);
    const error_value = (try session.runUnit("call.ecl", "boom")).err;
    defer heap.releaseValue(allocator, error_value);
    const rendered = try printer.toOwnedString(allocator, error_value);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"defs.ecl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'word '/") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'trace ['/ 'boom]") != null);

    const runtime_error = (try session.runUnit(
        "assembled.ecl",
        "1 0 (/) cons cons call",
    )).err;
    defer heap.releaseValue(allocator, runtime_error);
    const runtime_rendered = try printer.toOwnedString(allocator, runtime_error);
    defer allocator.free(runtime_rendered);
    try std.testing.expect(std.mem.indexOf(u8, runtime_rendered, "'source") == null);
}

fn allocationFailureProbe(allocator: std.mem.Allocator) !void {
    var session = try Session.init(allocator, &.{"argument"});
    defer session.deinit();
    const outcome = try session.runUnit(
        "allocation.ecl",
        "(3 4 +) 'sum def sum (1 0 /) attempt (5 6 +) attempt " ++
            "({'kind 'custom 'data {'detail 7}} raise) attempt args",
    );
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "session execution propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}
