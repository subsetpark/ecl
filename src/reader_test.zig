//! Cross-layer reader properties and Rust-oracle fixture parity.

const std = @import("std");
const heap = @import("heap.zig");
const equal = @import("equal.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");
const testgen = @import("testgen.zig");

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
