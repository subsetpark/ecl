//! Executable proofs for immutable dict and Unicode text kernels.
const std = @import("std");
const session = @import("../session.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");
const helper = @import("kernel_test_support.zig");

test "dict-text: polymorphic collection updates preserve ownership" {
    try helper.expectStack(
        "{'a 1} 'b 2 put {'a 1 'b 2} 'a del [1 2 3] 1 9 put [1 2 3] 1 del",
        "{'a 1 'b 2} {'b 2} [1 9 3] [1 3]",
    );
}

test "dict-text: to-dict and polymorphic list updates" {
    try helper.expectStack(
        "1 type 1.0 type \\a type 'a type (missing) first type [] type {} type " ++
            "['a 1] str " ++
            "['a 'b] [1 2] to-dict [1 2 3] 1 9 put [1 2 3] dup 1 9 put swap " ++
            "[1 2 3] 1 del \"abc\" 0 del",
        "'int 'float 'char 'symbol 'word 'list 'dict " ++
            "\"('a 1)\" " ++
            "{'a 1 'b 2} [1 9 3] [1 9 3] [1 2 3] [1 3] \"bc\"",
    );
    try helper.expectErrors(&.{
        .{
            .name = "to-dict requires conforming lists",
            .source = "['a] [1 2] to-dict",
            .kind = "shape",
            .word = "to-dict",
        },
        .{
            .name = "to-dict requires distinct keys",
            .source = "['a 'a] [1 2] to-dict",
            .kind = "domain",
            .word = "to-dict",
        },
        .{
            .name = "put index must be in bounds",
            .source = "[1 2] 2 9 put",
            .kind = "domain",
            .word = "put",
        },
        .{
            .name = "put index must be nonnegative",
            .source = "[1 2] -1 9 put",
            .kind = "domain",
            .word = "put",
        },
        .{
            .name = "put index must be an integer",
            .source = "[1 2] 'a 9 put",
            .kind = "type",
            .word = "put",
        },
        .{
            .name = "del index must be in bounds",
            .source = "[1 2] 2 del",
            .kind = "domain",
            .word = "del",
        },
        .{
            .name = "del index must be nonnegative",
            .source = "[1 2] -1 del",
            .kind = "domain",
            .word = "del",
        },
        .{
            .name = "del index must be an integer",
            .source = "[1 2] 'a del",
            .kind = "type",
            .word = "del",
        },
    });
    try helper.expectStack(
        "[\\a] [1] cat 1 \\b put [\\a] [1] cat dup 1 \\b put swap",
        "\"ab\" \"ab\" (\\a 1)",
    );
}

test "dict-text: dict-of converts one flat list without evaluation" {
    try helper.expectStack(
        "'total 3 4 + pair dict-of",
        "{'total 7}",
    );
    try helper.expectStack("[plus +] dict-of", "{plus +}");
    try helper.expectErrors(&.{
        .{
            .name = "dict-of requires an even item count",
            .source = "[1] dict-of",
            .kind = "contract",
            .word = "dict-of",
        },
        .{
            .name = "dict-of rejects numerically duplicate keys",
            .source = "[1 one 1.0 two] dict-of",
            .kind = "domain",
            .word = "dict-of",
        },
        .{
            .name = "dict-of requires a list",
            .source = "1 dict-of",
            .kind = "type",
            .word = "dict-of",
        },
    });
}

test "dict-text: split handles codepoints substrings and empty separators" {
    try helper.expectStack(
        "\"a—b—\" \"—\" split \"ab\" \"\" split " ++
            "\"\" \"\" split \"a🙂λ\" \"\" split " ++
            "\"abc\" \"🙂\" split \"a🙂b\" \"-\" split \"🙂a🙂\" \"🙂\" split",
        "(\"a\" \"b\" \"\") (\"a\" \"b\") () (\"a\" \"🙂\" \"λ\") " ++
            "(\"abc\") (\"a🙂b\") (\"\" \"a\" \"\")",
    );
}

test "dict-text: join requires strings and chooses narrow char width" {
    try helper.expectStack(
        "[\"a\" \"b\"] \"—\" join [\"a\" \"λ\" \"🙂\"] \"\" join " ++
            "[\"a\"] \"🙂\" join [] \"🙂\" join",
        "\"a—b\" \"aλ🙂\" \"a\" \"\"",
    );
    try helper.expectError(.{
        .name = "join reports the non-string member",
        .source = "[\"a\" 2] \"-\" join",
        .kind = "type",
        .word = "join",
        .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
    });
}

test "dict-text: format splices strings and canonically renders other values" {
    try helper.expectStack(
        "[\"Ada\" 2] \"name={} n={} {{ok}}\" format " ++
            "\"foo\" str wrap \"source={}\" format " ++
            "[\"\"] \"a{}b\" format",
        "\"name=Ada n=2 {ok}\" \"source=\\\"foo\\\"\" \"ab\"",
    );
    try helper.expectErrors(&.{
        .{
            .name = "format requires one value per placeholder",
            .source = "[1] \"{} {}\" format",
            .kind = "contract",
            .word = "format",
        },
        .{
            .name = "format rejects an unmatched brace",
            .source = "[] \"{\" format",
            .kind = "domain",
            .word = "format",
        },
    });
}

test "dict-text: large updates yield through the public runtime" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    const integers = try allocator.alloc(i64, 70_000);
    defer allocator.free(integers);
    for (integers, 0..) |*integer, index| integer.* = @intCast(index);
    const sequence = try list.fromI64Slice(allocator, integers);
    defer cleanup.releaseValue(sequence);
    try runtime.pushBorrowed(sequence);
    try std.testing.expect((try runtime.runUnit("<test>", "69999 1 put pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    try runtime.pushBorrowed(sequence);
    try std.testing.expect((try runtime.runUnit("<test>", "69999 del pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    const pairs = try allocator.alloc(dict.Pair, 70_000);
    defer allocator.free(pairs);
    for (pairs, 0..) |*pair, index| pair.* = .{
        .{ .int = @intCast(index) },
        .{ .int = @intCast(index) },
    };
    const dictionary = try dict.fromUniquePairs(allocator, cleanup.domain(), pairs);
    defer cleanup.releaseValue(dictionary);

    try runtime.pushBorrowed(dictionary);
    try std.testing.expect((try runtime.runUnit("<test>", "70000 1 put pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    try runtime.pushBorrowed(dictionary);
    try std.testing.expect((try runtime.runUnit("<test>", "69999 del pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    try runtime.pushBorrowed(dictionary);
    try std.testing.expect((try runtime.runUnit("<test>", "{70000 1} dict.merge pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);
}
