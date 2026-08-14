//! Cross-layer reader properties and Rust-oracle fixture parity.

const std = @import("std");
const heap = @import("heap.zig");
const equal = @import("equal.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");
const poll = @import("poll.zig");
const testgen = @import("testgen.zig");

const PollStop = struct {
    calls: usize = 0,
    fail_at: usize,

    fn tick(raw: *anyopaque) poll.Error!void {
        const self: *PollStop = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.Ecl;
    }

    fn poller(self: *PollStop) poll.Poller {
        return .{ .context = self, .poll_fn = tick };
    }
};

fn repeatedSource(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    item: []const u8,
    count: usize,
    suffix: []const u8,
) ![]u8 {
    const repeated = try std.math.mul(usize, item.len, count);
    const length = try std.math.add(usize, prefix.len, try std.math.add(usize, repeated, suffix.len));
    const source = try allocator.alloc(u8, length);
    var cursor: usize = 0;
    @memcpy(source[cursor..][0..prefix.len], prefix);
    cursor += prefix.len;
    for (0..count) |_| {
        @memcpy(source[cursor..][0..item.len], item);
        cursor += item.len;
    }
    @memcpy(source[cursor..][0..suffix.len], suffix);
    return source;
}

fn expectReadCancelled(source: []const u8) !void {
    return expectReadCancelledAt(source, 65_536);
}

fn expectReadCancelledAt(source: []const u8, fail_at: usize) !void {
    var stop = PollStop{ .fail_at = fail_at };
    var diag: lexer.Diag = .{};
    try std.testing.expectError(error.Ecl, reader.readPolling(
        std.testing.allocator,
        "<reader-cancel>",
        source,
        &diag,
        poll.WorkContext.init(stop.poller()),
    ));
    try std.testing.expectEqual(stop.fail_at, stop.calls);
}

fn expectLateReadCancellation(source: []const u8) !void {
    var counter = PollStop{ .fail_at = std.math.maxInt(usize) };
    var diag: lexer.Diag = .{};
    var parsed = switch (try reader.readPolling(
        std.testing.allocator,
        "<reader-late-cancel>",
        source,
        &diag,
        poll.WorkContext.init(counter.poller()),
    )) {
        .complete => |complete| complete,
        .incomplete => return error.TestUnexpectedResult,
    };
    parsed.deinit();
    try std.testing.expect(counter.calls > 65_536);
    try expectReadCancelledAt(source, counter.calls - 1);
}

test "parse-print identity for seeded dict-free values" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_1001);
    const random = prng.random();
    for (0..1000) |_| {
        const original = try testgen.generateValue(allocator, random, 4, .excluded);
        defer heap.releaseValue(allocator, original);
        const source = try printer.toOwnedString(allocator, original);
        defer allocator.free(source);
        var diag: lexer.Diag = .{};
        var parsed = switch (try reader.read(allocator, "<round-trip>", source, &diag)) {
            .complete => |complete| complete,
            .incomplete => return error.TestUnexpectedResult,
        };
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.forms.len);
        try std.testing.expect(equal.match(original, parsed.forms[0]));
        try std.testing.expectEqual(equal.hash(original), equal.hash(parsed.forms[0]));
    }
}

test "parse-print identity for seeded dict values" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_1002);
    const random = prng.random();
    for (0..500) |_| {
        const count = random.uintLessThan(usize, 5);
        const pairs = try allocator.alloc(dict.Pair, count);
        defer allocator.free(pairs);
        var initialized: usize = 0;
        defer for (pairs[0..initialized]) |pair| {
            heap.releaseValue(allocator, pair[0]);
            heap.releaseValue(allocator, pair[1]);
        };
        const base = random.intRangeAtMost(i64, -1_000_000, 1_000_000);
        for (pairs, 0..) |*pair, index| {
            pair[0] = .{ .int = base + @as(i64, @intCast(index)) };
            pair[1] = try testgen.generateValue(allocator, random, 3, .allowed);
            initialized += 1;
        }
        const original = try dict.fromPairs(allocator, pairs);
        defer heap.releaseValue(allocator, original);
        const source = try printer.toOwnedString(allocator, original);
        defer allocator.free(source);
        var diag: lexer.Diag = .{};
        var parsed = switch (try reader.read(allocator, "<dict-shape>", source, &diag)) {
            .complete => |complete| complete,
            .incomplete => return error.TestUnexpectedResult,
        };
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.forms.len);
        try std.testing.expect(equal.match(original, parsed.forms[0]));
        try std.testing.expectEqual(equal.hash(original), equal.hash(parsed.forms[0]));
    }
}

test "reader fixtures remain byte-for-byte anchors" {
    const allocator = std.testing.allocator;
    const Fixture = struct { source: []const u8, expected: []const []const u8 };
    const fixtures = [_]Fixture{
        .{
            .source = "1, -2 0x10 3.5 2e3 # hi\n [\\a 'x \"ok\"]",
            .expected = &.{ "1", "-2", "16", "3.5", "2000.0", "(\\a 'x \"ok\")" },
        },
        .{
            .source = "{'answer (40 2 +) plus +}",
            .expected = &.{"{'answer (40 2 +) plus +}"},
        },
        .{
            .source = "(|x| x x *)",
            .expected = &.{"([] cons dup 0 at swap dup 0 at swap (*) dip pop)"},
        },
    };
    for (fixtures) |fixture| {
        var diag: lexer.Diag = .{};
        var parsed = switch (try reader.read(allocator, "test", fixture.source, &diag)) {
            .complete => |complete| complete,
            .incomplete => return error.TestUnexpectedResult,
        };
        defer parsed.deinit();
        try std.testing.expectEqual(fixture.expected.len, parsed.forms.len);
        for (parsed.forms, fixture.expected) |form, expected| {
            const rendered = try printer.toOwnedString(allocator, form);
            defer allocator.free(rendered);
            try std.testing.expectEqualStrings(expected, rendered);
        }
    }

    var diag: lexer.Diag = .{};
    try std.testing.expect((try reader.read(allocator, "<repl>", "1 (2", &diag)) == .incomplete);
    try std.testing.expectError(error.Parse, reader.read(allocator, "test", "[1 2)", &diag));
    try std.testing.expectError(error.Parse, reader.read(allocator, "test", "(|x| (x))", &diag));
    try std.testing.expectError(
        error.Parse,
        reader.read(allocator, "test", "9223372036854775808", &diag),
    );
}

test "polling reader cancels inside lexical binder span and top-form traversals" {
    const allocator = std.testing.allocator;
    const comment = try repeatedSource(allocator, "#", "a", 40_000, "");
    defer allocator.free(comment);
    try expectReadCancelled(comment);

    const token = try repeatedSource(allocator, "", "a", 40_000, "");
    defer allocator.free(token);
    try expectReadCancelled(token);

    const string = try repeatedSource(allocator, "\"", "a", 40_000, "\"");
    defer allocator.free(string);
    try expectReadCancelled(string);

    // Validation plus tokenization stays below one quantum; lowering the
    // large binder body is the traversal that crosses it.
    const binder_source = try repeatedSource(allocator, "(|x| ", "1 ", 14_000, ")");
    defer allocator.free(binder_source);
    try expectReadCancelled(binder_source);

    // The first copy into list storage stays below the boundary; copying its
    // element spans is what consumes the remainder.
    const span_source = try repeatedSource(allocator, "[", "1 ", 11_000, "]");
    defer allocator.free(span_source);
    try expectReadCancelled(span_source);

    // With no containing list, the final forms/spans handoff crosses the
    // boundary after validation and tokenization complete.
    const forms_source = try repeatedSource(allocator, "", "1 ", 14_000, "");
    defer allocator.free(forms_source);
    try expectReadCancelled(forms_source);

    // Lexing and span publication alone stay below one quantum. The
    // specialization/profile and storage copies must supply the safe point.
    const constructed_string = try repeatedSource(allocator, "\"", "a", 15_000, "\"");
    defer allocator.free(constructed_string);
    try expectReadCancelled(constructed_string);

    const constructed_list = try repeatedSource(allocator, "[", "1 ", 10_000, "]");
    defer allocator.free(constructed_list);
    try expectReadCancelled(constructed_list);

    // The string itself materializes below the boundary; structurally
    // hashing it as a dictionary key crosses the remaining poll budget.
    const hashed_key = try repeatedSource(allocator, "{\"", "a", 12_000, "\" 1}");
    defer allocator.free(hashed_key);
    try expectReadCancelled(hashed_key);
}

test "polling reader bounds long classification and post-growth materialization" {
    const allocator = std.testing.allocator;
    const atom = try repeatedSource(allocator, "", "a", 70_000, "");
    defer allocator.free(atom);
    try expectReadCancelledAt(atom, 170_000);

    const quoted = try repeatedSource(allocator, "'", "a", 70_000, "");
    defer allocator.free(quoted);
    try expectReadCancelledAt(quoted, 170_000);

    const forms = try repeatedSource(allocator, "", "1 ", 65_537, "");
    defer allocator.free(forms);
    try expectLateReadCancellation(forms);

    const string = try repeatedSource(allocator, "\"", "a", 65_537, "\"");
    defer allocator.free(string);
    try expectLateReadCancellation(string);

    const binder_output = try repeatedSource(allocator, "(|x| ", "1 ", 32_769, ")");
    defer allocator.free(binder_output);
    try expectLateReadCancellation(binder_output);
}

fn readFailureProbe(allocator: std.mem.Allocator) !void {
    var diag: lexer.Diag = .{};
    var parsed = switch (try reader.read(
        allocator,
        "oom.ecl",
        "1 -2 0x10 3.5 2e3 [\\a 'x \"ok\\u{3bb}\"] " ++
            "{'answer [40 2 +]} (|x y| x y +)",
        &diag,
    )) {
        .complete => |complete| complete,
        .incomplete => return error.TestUnexpectedResult,
    };
    parsed.deinit();
}

test "full read path propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readFailureProbe,
        .{},
    );
}
