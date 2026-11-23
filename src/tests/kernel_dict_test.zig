//! Executable proofs for immutable dict and collection-update kernels.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const session = @import("../session.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");
const helper = @import("kernel_test_support.zig");

test "dict: polymorphic collection updates preserve ownership" {
    try helper.expectStack(
        "{a 1} `b 2 put {a 1 b 2} `a del {[1 2] 9} [1 2] 10 put " ++
            "[1 2 3] 1 9 put [1 2 3] 1 del",
        "{a 1 b 2} {b 2} {[1 2] 10} [1 9 3] [1 3]",
    );
}

test "dict: put pervades over list selectors with conforming replacements" {
    try helper.expectStack(
        "[10 20 30 40] [1 3] 0 put " ++
            "[10 20 30 40] [1 3] [90 80] put " ++
            "[10 20 30 40] [[0 2] 3] [[9 8] 7] put " ++
            "[10 20] [1 1] [7 8] put " ++
            "[1 [2 3]] [1] [[9 10]] put " ++
            "[1 2] [] 9 put [1 2] [] [] put",
        "[10 0 30 0] [10 90 30 80] [9 20 8 7] [10 8] " ++
            "(1 [9 10]) [1 2] [1 2]",
    );
    try helper.expectErrors(&.{
        .{
            .name = "put replacement must conform to the selector",
            .source = "[1 2 3] [0 2] [9] put",
            .kind = "conform",
            .word = "put",
        },
        .{
            .name = "put nested replacement must conform to the nested selector",
            .source = "[1 2 3] [[0 2]] [[9]] put",
            .kind = "conform",
            .word = "put",
        },
        .{
            .name = "put selector leaves must be integer indices",
            .source = "[1 2] [0 a] 9 put",
            .kind = "type",
            .word = "put",
        },
        .{
            .name = "put selector leaves must be in bounds",
            .source = "[1 2] [0 2] 9 put",
            .kind = "domain",
            .word = "put",
        },
    });
}

test "dict: del removes original list positions through pervasive selectors" {
    try helper.expectStack(
        "[10 20 30 40 50] [3 4] del " ++
            "[10 20 30 40 50] [[4 1] 4] del " ++
            "[10 20] [] del " ++
            "{[1 2] 9 a 1} [1 2] del",
        "[10 20 30] [10 30 40] [10 20] {a 1}",
    );
    try helper.expectErrors(&.{
        .{
            .name = "del selector leaves must be integer indices",
            .source = "[1 2] [0 a] del",
            .kind = "type",
            .word = "del",
        },
        .{
            .name = "del selector leaves must be in bounds",
            .source = "[1 2] [0 2] del",
            .kind = "domain",
            .word = "del",
        },
    });
}

test "dict: dict.zip and polymorphic list updates" {
    try helper.expectStack(
        "1 type 1.0 type \\a type `a type (missing) first type [] type {} type " ++
            "[a 1] str " ++
            "[a b] [1 2] dict.zip [1 2 3] 1 9 put [1 2 3] dup 1 9 put swap " ++
            "[1 2 3] 1 del \"abc\" 0 del",
        "int float char symbol symbol list dict " ++
            "\"(a 1)\" " ++
            "{a 1 b 2} [1 9 3] [1 9 3] [1 2 3] [1 3] \"bc\"",
    );
    try helper.expectErrors(&.{
        .{
            .name = "dict.zip requires conforming lists",
            .source = "[a] [1 2] dict.zip",
            .kind = "shape",
            .word = "dict.core.zip",
        },
        .{
            .name = "dict.zip requires distinct keys",
            .source = "[a a] [1 2] dict.zip",
            .kind = "domain",
            .word = "dict.core.zip",
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
            .source = "[1 2] `a 9 put",
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
            .source = "[1 2] `a del",
            .kind = "type",
            .word = "del",
        },
    });
    try helper.expectStack(
        "[\\a] [1] cat 1 \\b put [\\a] [1] cat dup 1 \\b put swap",
        "\"ab\" \"ab\" (\\a 1)",
    );
}

test "dict: dict.from-kvs converts one flat list without evaluation" {
    try helper.expectStack(
        "`total 3 4 + pair dict.from-kvs",
        "{total 7}",
    );
    try helper.expectStack("[plus +] dict.from-kvs", "{plus +}");
    try helper.expectErrors(&.{
        .{
            .name = "dict.from-kvs requires an even item count",
            .source = "[1] dict.from-kvs",
            .kind = "contract",
            .word = "dict.core.from-kvs",
        },
        .{
            .name = "dict.from-kvs rejects numerically duplicate keys",
            .source = "[1 one 1.0 two] dict.from-kvs",
            .kind = "domain",
            .word = "dict.core.from-kvs",
        },
        .{
            .name = "dict.from-kvs requires a list",
            .source = "1 dict.from-kvs",
            .kind = "type",
            .word = "dict.core.from-kvs",
        },
    });
}

test "dict: large updates yield through the public runtime" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    const integers = try allocator.alloc(i64, 70_000);
    defer allocator.free(integers);
    for (integers, 0..) |*integer, index| integer.* = @intCast(index);
    const sequence = try list.testing.fromI64Slice(allocator, integers);
    defer cleanup.releaseValue(sequence);
    try runtime.pushBorrowed(sequence);
    try std.testing.expect((try runtime.runUnit("<test>", "69999 1 put pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    try runtime.pushBorrowed(sequence);
    try std.testing.expect((try runtime.runUnit("<test>", "69999 del pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    try runtime.pushBorrowed(sequence);
    try std.testing.expect((try runtime.runUnit("<test>", "[69998 69999] del pop")) == .ok);
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
    try std.testing.expect((try runtime.runUnit("<test>", "[69999] dict.del pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);

    try runtime.pushBorrowed(dictionary);
    try std.testing.expect((try runtime.runUnit("<test>", "{70000 1} dict.merge pop")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);
}
