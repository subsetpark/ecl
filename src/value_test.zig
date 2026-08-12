//! Seeded cross-module properties for the complete value layer.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const equal = @import("equal.zig");
const dict = @import("dict.zig");
const printer = @import("print.zig");
const testgen = @import("testgen.zig");

const Value = value.Value;

test "seeded arbitrary values lock equality, hash, and print laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0001);
    const random = prng.random();
    for (0..1000) |_| {
        const a = try testgen.generateValue(allocator, random, 4, .allowed);
        defer heap.releaseValue(allocator, a);
        const b = try testgen.generateValue(allocator, random, 4, .allowed);
        defer heap.releaseValue(allocator, b);
        try std.testing.expect(equal.match(a, a));
        try std.testing.expectEqual(equal.match(a, b), equal.match(b, a));
        if (equal.match(a, b)) try std.testing.expectEqual(equal.hash(a), equal.hash(b));

        const first = try printer.toOwnedString(allocator, a);
        defer allocator.free(first);
        const second = try printer.toOwnedString(allocator, a);
        defer allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}

test "seeded specialization and cross-representation laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0002);
    const random = prng.random();
    for (0..1000) |_| {
        const count = random.intRangeAtMost(usize, 1, 8);
        const items = try allocator.alloc(Value, count);
        defer allocator.free(items);
        const use_chars = random.boolean();
        for (items) |*item| item.* = if (use_chars)
            .{ .char = testgen.randomCodepoint(random) }
        else
            .{ .int = random.intRangeAtMost(i64, -1000, 1000) };

        const leaf = try list.fromValues(allocator, items);
        defer heap.releaseValue(allocator, leaf);
        const spine = try list.fromValuesGeneric(allocator, items);
        defer heap.releaseValue(allocator, spine);
        if (use_chars) {
            try std.testing.expect(leaf.isString());
        } else {
            try std.testing.expectEqual(value.HeapKind.leaf_i64, leaf.list.kind());
        }
        for (items, 0..) |expected, index| {
            try std.testing.expectEqual(expected, try list.at(leaf, index));
        }
        try std.testing.expect(equal.match(leaf, spine));
        try std.testing.expectEqual(equal.hash(leaf), equal.hash(spine));
    }
}

test "seeded numeric and dict ordering laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0003);
    const random = prng.random();
    for (0..1000) |_| {
        const integer = random.intRangeAtMost(i32, -1_000_000, 1_000_000);
        const int_value = Value{ .int = integer };
        const float_value = Value{ .float = @floatFromInt(integer) };
        try std.testing.expect(equal.match(int_value, float_value));
        try std.testing.expectEqual(equal.hash(int_value), equal.hash(float_value));

        const pairs = [_]dict.Pair{
            .{ .{ .int = 1 }, .{ .char = testgen.randomCodepoint(random) } },
            .{ .{ .int = 2 }, .{ .int = integer } },
            .{ .{ .int = 3 }, .{ .word = try testgen.randomInternedId(random) } },
        };
        const reversed = [_]dict.Pair{ pairs[2], pairs[1], pairs[0] };
        const first = try dict.fromPairs(allocator, &pairs);
        defer heap.releaseValue(allocator, first);
        const second = try dict.fromPairs(allocator, &reversed);
        defer heap.releaseValue(allocator, second);
        try std.testing.expect(equal.match(first, second));
        try std.testing.expectEqual(equal.hash(first), equal.hash(second));
    }
}

test "seeded append sharing laws" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xecc0_0004);
    const random = prng.random();
    for (0..1000) |_| {
        const original = try list.fromValues(allocator, &.{
            .{ .int = random.int(i32) },
            .{ .int = random.int(i32) },
        });
        defer heap.releaseValue(allocator, original);
        const unique = try list.append(allocator, original, .{ .int = random.int(i32) });
        try std.testing.expectEqual(original.list, unique.list);

        heap.incRef(original.list);
        defer heap.decRef(allocator, original.list);
        const copied = try list.append(allocator, original, .{ .int = random.int(i32) });
        defer heap.releaseValue(allocator, copied);
        try std.testing.expect(original.list != copied.list);
        try std.testing.expectEqual(@as(usize, 3), try list.len(original));
        try std.testing.expectEqual(@as(usize, 4), try list.len(copied));
    }
}

fn countLines(source: []const u8) usize {
    var lines: usize = 0;
    for (source) |byte| lines += @intFromBool(byte == '\n');
    if (source.len > 0 and source[source.len - 1] != '\n') lines += 1;
    return lines;
}

/// Interpreter lines only: every top-level `test` block is skipped wherever it
/// sits. `zig fmt` is a blocking gate, so a top-level block always closes with
/// `}` in column zero -- brace counting would misread the ecl source literals
/// inside test bodies.
fn countCoreLines(source: []const u8) usize {
    var lines: usize = 0;
    var rest = source;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..end];
        rest = rest[@min(end + 1, rest.len)..];
        if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "test {")) {
            while (rest.len > 0) {
                const stop = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                const inner = rest[0..stop];
                rest = rest[@min(stop + 1, rest.len)..];
                if (std.mem.eql(u8, inner, "}")) break;
            }
            if (std.mem.startsWith(u8, rest, "\n")) rest = rest[1..];
            continue;
        }
        lines += 1;
    }
    return lines;
}

test "components stay inside the decision-23 line budgets" {
    const Component = struct {
        name: []const u8,
        budget: usize,
        sources: []const []const u8,
    };
    const components = [_]Component{
        .{ .name = "values+RC", .budget = 1950, .sources = &.{
            @embedFile("value.zig"),  @embedFile("heap.zig"),
            @embedFile("intern.zig"), @embedFile("list.zig"),
            @embedFile("equal.zig"),  @embedFile("dict.zig"),
            @embedFile("print.zig"),
        } },
        .{ .name = "reader", .budget = 1250, .sources = &.{
            @embedFile("lexer.zig"), @embedFile("binder.zig"), @embedFile("reader.zig"),
        } },
        .{ .name = "machine", .budget = 2300, .sources = &.{
            @embedFile("env.zig"),     @embedFile("machine.zig"),
            @embedFile("spans.zig"),   @embedFile("prims.zig"),
            @embedFile("session.zig"), @embedFile("main.zig"),
            @embedFile("root.zig"),
        } },
    };
    // Test-only sources are excluded from core entirely; test blocks inside
    // interpreter sources are excluded by countCoreLines.
    const test_sources = [_][]const u8{
        @embedFile("testgen.zig"),      @embedFile("reader_test.zig"),
        @embedFile("machine_test.zig"), @embedFile("value_test.zig"),
    };

    var core_lines: usize = 0;
    inline for (components) |component| {
        var component_lines: usize = 0;
        inline for (component.sources) |source| component_lines += countCoreLines(source);
        std.log.info("{s}: {d}/{d} core lines", .{ component.name, component_lines, component.budget });
        core_lines += component_lines;
        try std.testing.expect(component_lines <= component.budget);
    }
    var test_lines: usize = 0;
    inline for (components) |component| {
        inline for (component.sources) |source| test_lines += countLines(source) - countCoreLines(source);
    }
    inline for (test_sources) |source| test_lines += countLines(source);
    std.log.info(
        "line budget: {d}/9500 core, {d} test lines, {d} total",
        .{ core_lines, test_lines, core_lines + test_lines },
    );
    try std.testing.expect(core_lines <= 9500);
}
