//! Cross-layer reader properties and canonical fixture parity.

const std = @import("std");
const minish = @import("minish");
const heap = @import("../heap.zig");
const equal = @import("../equal.zig");
const printer = @import("../print.zig");
const lexer = @import("../lexer.zig");
const reader = @import("../reader.zig");
const testgen = @import("testgen.zig");

fn retireReadCursor(cursor: *reader.ReadCursor, releases: *heap.ReleaseDomain) void {
    while (!cursor.advanceRetirement()) _ = releases.advance(256);
}

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

fn expectReadNeedsSteps(source: []const u8, minimum: usize) !void {
    var diag: lexer.Diag = .{};
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var cursor = reader.ReadCursor.init(std.testing.allocator, releases, "<reader-yield>", source, &diag);
    defer retireReadCursor(&cursor, releases);
    for (0..minimum) |_| try std.testing.expect((try cursor.advance()) == .pending);
    while (true) switch (try cursor.advance()) {
        .pending => {},
        .complete => |result| {
            var parsed = switch (result) {
                .complete => |complete| complete,
                .incomplete => return error.TestUnexpectedResult,
            };
            var retirement = reader.Parsed.RetireCursor.init(&parsed);
            while (!retirement.advance()) {}
            return;
        },
    };
}

fn expectRoundTrip(original: testgen.Value) !void {
    const allocator = std.testing.allocator;
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    const source = try printer.toOwnedString(allocator, original);
    defer allocator.free(source);
    var diag: lexer.Diag = .{};
    var parsed = switch (try reader.read(host.cleanup(), "<round-trip>", source, &diag)) {
        .complete => |complete| complete,
        .incomplete => return error.TestUnexpectedResult,
    };
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.values().len);
    try std.testing.expect(equal.match(original, parsed.values()[0]));
    try std.testing.expectEqual(equal.hash(original), equal.hash(parsed.values()[0]));
}

fn dictFreeRoundTrip(recipe: testgen.ValueRecipe) !void {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const original = try testgen.valueFromRecipe(
        allocator,
        cleanup.domain(),
        recipe,
        4,
        .excluded,
        0x00,
    );
    defer cleanup.releaseValue(original);
    try expectRoundTrip(original);
}

test "parse-print identity for arbitrary dict-free values shrinks structurally" {
    try minish.check(std.testing.allocator, testgen.value_recipe_generator, dictFreeRoundTrip, .{
        .num_runs = 1000,
        .seed = 0xecc0_1001,
        .max_shrink_attempts = 512,
    });
}

fn dictRoundTrip(recipe: testgen.ValueRecipe) !void {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const original = try testgen.dictFromRecipe(allocator, cleanup.domain(), recipe, 3, 0x5d);
    defer cleanup.releaseValue(original);
    try expectRoundTrip(original);
}

test "parse-print identity for arbitrary dict values shrinks structurally" {
    try minish.check(std.testing.allocator, testgen.value_recipe_generator, dictRoundTrip, .{
        .num_runs = 500,
        .seed = 0xecc0_1002,
        .max_shrink_attempts = 512,
    });
}

test "reader fixtures remain byte-for-byte anchors" {
    const allocator = std.testing.allocator;
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
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
            .expected = &.{"([] cons dup 0 at swap dup 0 at swap pop *)"},
        },
        // The environment retires at the last local read, so a body form that
        // still precedes one runs under `dip` while everything after it is
        // ordinary code.
        .{
            .source = "(|x| x 1 + x *)",
            .expected = &.{"([] cons dup 0 at swap [1] dip (+) dip dup 0 at swap pop *)"},
        },
        .{
            .source = "(|x y| 1 2)",
            .expected = &.{"([] cons cons pop 1 2)"},
        },
    };
    for (fixtures) |fixture| {
        var diag: lexer.Diag = .{};
        var parsed = switch (try reader.read(host.cleanup(), "test", fixture.source, &diag)) {
            .complete => |complete| complete,
            .incomplete => return error.TestUnexpectedResult,
        };
        defer parsed.deinit();
        try std.testing.expectEqual(fixture.expected.len, parsed.values().len);
        for (parsed.values(), fixture.expected) |form, expected| {
            const rendered = try printer.toOwnedString(allocator, form);
            defer allocator.free(rendered);
            try std.testing.expectEqualStrings(expected, rendered);
        }
    }

    var diag: lexer.Diag = .{};
    try std.testing.expect((try reader.read(host.cleanup(), "<repl>", "1 (2", &diag)) == .incomplete);
    try std.testing.expectError(error.Parse, reader.read(host.cleanup(), "test", "[1 2)", &diag));
    try std.testing.expectError(error.Parse, reader.read(host.cleanup(), "test", "(|x| (x))", &diag));
    try std.testing.expectError(
        error.Parse,
        reader.read(host.cleanup(), "test", "9223372036854775808", &diag),
    );
}

test "reader yields inside lexical binder span and top-form traversals" {
    const allocator = std.testing.allocator;
    const comment = try repeatedSource(allocator, "#", "a", 40_000, "");
    defer allocator.free(comment);
    try expectReadNeedsSteps(comment, 1024);

    const token = try repeatedSource(allocator, "", "a", 40_000, "");
    defer allocator.free(token);
    try expectReadNeedsSteps(token, 1024);

    const string = try repeatedSource(allocator, "\"", "a", 40_000, "\"");
    defer allocator.free(string);
    try expectReadNeedsSteps(string, 1024);

    // Validation plus tokenization stays below one quantum; lowering the
    // large binder body is the traversal that crosses it.
    const binder_source = try repeatedSource(allocator, "(|x| ", "1 ", 14_000, ")");
    defer allocator.free(binder_source);
    try expectReadNeedsSteps(binder_source, 65_536);

    // The first copy into list storage stays below the boundary; copying its
    // element spans is what consumes the remainder.
    const span_source = try repeatedSource(allocator, "[", "1 ", 11_000, "]");
    defer allocator.free(span_source);
    try expectReadNeedsSteps(span_source, 65_536);

    // With no containing list, the final forms/spans handoff crosses the
    // boundary after validation and tokenization complete.
    const forms_source = try repeatedSource(allocator, "", "1 ", 14_000, "");
    defer allocator.free(forms_source);
    try expectReadNeedsSteps(forms_source, 65_536);

    // Lexing and span publication alone stay below one quantum. The
    // specialization/profile and storage copies must supply the safe point.
    const constructed_string = try repeatedSource(allocator, "\"", "a", 15_000, "\"");
    defer allocator.free(constructed_string);
    try expectReadNeedsSteps(constructed_string, 65_536);

    const constructed_list = try repeatedSource(allocator, "[", "1 ", 10_000, "]");
    defer allocator.free(constructed_list);
    try expectReadNeedsSteps(constructed_list, 65_536);

    // The string itself materializes below the boundary; structurally
    // hashing it as a dictionary key crosses the remaining poll budget.
    const hashed_key = try repeatedSource(allocator, "{\"", "a", 12_000, "\" 1}");
    defer allocator.free(hashed_key);
    try expectReadNeedsSteps(hashed_key, 65_536);
}

test "reader bounds long classification and post-growth materialization" {
    const allocator = std.testing.allocator;
    const atom = try repeatedSource(allocator, "", "a", 70_000, "");
    defer allocator.free(atom);
    try expectReadNeedsSteps(atom, 170_000);

    const quoted = try repeatedSource(allocator, "'", "a", 70_000, "");
    defer allocator.free(quoted);
    try expectReadNeedsSteps(quoted, 170_000);

    const forms = try repeatedSource(allocator, "", "1 ", 65_537, "");
    defer allocator.free(forms);
    try expectReadNeedsSteps(forms, 65_536);

    const string = try repeatedSource(allocator, "\"", "a", 65_537, "\"");
    defer allocator.free(string);
    try expectReadNeedsSteps(string, 65_536);

    const binder_output = try repeatedSource(allocator, "(|x| ", "1 ", 32_769, ")");
    defer allocator.free(binder_output);
    try expectReadNeedsSteps(binder_output, 65_536);

    const task_marker = try repeatedSource(allocator, "<task:", "0", 70_000, ">");
    defer allocator.free(task_marker);
    var diag: lexer.Diag = .{};
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var cursor = reader.ReadCursor.init(allocator, releases, "<task-marker>", task_marker, &diag);
    defer retireReadCursor(&cursor, releases);
    for (0..task_marker.len * 2) |_| try std.testing.expect((try cursor.advance()) == .pending);
    var rejected = false;
    while (!rejected) {
        const progress = cursor.advance() catch |err| {
            try std.testing.expectEqual(error.Parse, err);
            rejected = true;
            continue;
        };
        if (progress == .complete) return error.TestExpectedError;
    }
}

fn readFailureProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    var diag: lexer.Diag = .{};
    var parsed = switch (try reader.read(
        host.cleanup(),
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
