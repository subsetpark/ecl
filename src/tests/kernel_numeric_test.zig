//! Executable proofs for numeric dispatch, pervasion, faults, and ownership.
const std = @import("std");
const session = @import("../session.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const helper = @import("kernel_test_support.zig");

test "numeric: scalar leaf and mixed numeric semantics match" {
    try helper.expectStack(
        "[1 2 3] 0.5 + 9007199254740993 9007199254740992.0 = \\a 1 +",
        "[1.5 2.5 3.5] 0 \\b",
    );
    try helper.expectError(.{
        .name = "symbols are not numeric leaves",
        .source = "'not-a-number 1 +",
        .kind = "type",
        .word = "+",
    });
}

test "numeric: empty leaves bypass scalar signature selection" {
    try helper.expectStack("\"\" \"\" + \"\" neg", "() ()");
}

test "numeric: transcendental non-finite edges" {
    try helper.expectStacks(&.{
        .{
            .name = "transcendental identities",
            .source = "0 exp 1 log 0 sin 0 cos 0 0 atan2",
            .expected = "1.0 0.0 0.0 1.0 0.0",
        },
        .{
            .name = "accepted nonfinite operands",
            .source = "inf log -inf exp",
            .expected = "inf 0.0",
        },
        .{
            .name = "transcendental leaf pervasion",
            .source = "[0 0] exp [0 0] [1 1] atan2",
            .expected = "[1.0 1.0] [0.0 0.0]",
        },
    });
    try helper.expectErrors(&.{
        .{ .name = "log zero overflows", .source = "0 log", .kind = "overflow", .word = "log" },
        .{ .name = "log negative is outside the domain", .source = "-1 log", .kind = "domain", .word = "log" },
        .{ .name = "sin infinity is outside the domain", .source = "inf sin", .kind = "domain", .word = "sin" },
        .{ .name = "finite exp cannot produce infinity", .source = "1000 exp", .kind = "overflow", .word = "exp" },
        .{
            .name = "pervasive log reports the failing index",
            .source = "[1 -1] log",
            .kind = "domain",
            .word = "log",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
    });
}

test "numeric: ragged broadcast dict alignment and representation parity" {
    try helper.expectStack("[[1 2] [3]] 10 *", "([10 20] [30])");
    try helper.expectStack("[[1 2] [3 4]] 1 +", "([2 3]\n [4 5])");
    try helper.expectStack("[\"az\" \"λ🙂\"] 1 +", "(\"b{\" \"μ🙃\")");
    try helper.expectStack(
        "{'a 1 'b 2} {'b 10 'c 30} + {'a 1} [10 20] +",
        "{'a 1 'b 12 'c 30} {'a [11 21]}",
    );
    try helper.expectError(.{
        .name = "a fault in a nested typed leaf reports its inner index",
        .source = "[[1 2] [3 9223372036854775807]] 1 +",
        .kind = "overflow",
        .word = "+",
        .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
    });
}

test "numeric: fault blocks report first index before aliased stores" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit("<test>", "9223372036854775806")) == .ok);
    const failure = (try runtime.runUnit("<test>", "[1 2] +")).err;
    defer runtime.release(failure);
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 9223372036854775806), runtime.stackItems()[0].int);
    try helper.expectLanguageError(failure, .{
        .name = "aliased block failure",
        .source = "[1 2] +",
        .kind = "overflow",
        .word = "+",
        .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
    });
    try helper.expectErrors(&.{
        .{
            .name = "first element fails",
            .source = "9223372036854775807 [1] +",
            .kind = "overflow",
            .word = "+",
            .data = &.{.{ .name = "index", .expected = .{ .int = 0 } }},
        },
        .{
            .name = "second fault block reports its first failure",
            .source = "9223372036854775552 300 range +",
            .kind = "overflow",
            .word = "+",
            .data = &.{.{ .name = "index", .expected = .{ .int = 256 } }},
        },
    });
}

test "numeric: conform and depth diagnostics are bounded" {
    try helper.expectError(.{
        .name = "nonconforming leading axes",
        .source = "[1 2] [3] +",
        .kind = "conform",
        .word = "+",
        .data = &.{
            .{ .name = "left", .expected = .{ .int = 2 } },
            .{ .name = "right", .expected = .{ .int = 1 } },
        },
    });
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..257) |_| try source.append(std.testing.allocator, '[');
    try source.append(std.testing.allocator, '1');
    for (0..257) |_| try source.append(std.testing.allocator, ']');
    try source.appendSlice(std.testing.allocator, " 1 +");
    try helper.expectError(.{
        .name = "pervasion depth guard",
        .source = source.items,
        .kind = "domain",
        .word = "+",
        .message_contains = "exceeds 256 levels",
    });
}

test "numeric: long leaves poll at bounded chunks" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit("<test>", "70000 range 1 + len")) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 2);
    try std.testing.expectEqual(@as(i64, 70_000), runtime.stackItems()[0].int);
}

test "numeric: result materialization remains cancellable" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const integers = try allocator.alloc(i64, 70_000);
    defer allocator.free(integers);
    for (integers, 0..) |*integer, index| integer.* = @intCast(index);
    const input = try list.fromI64Slice(allocator, integers);
    defer cleanup.releaseValue(input);

    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try runtime.pushBorrowed(input);
    try std.testing.expect((try runtime.runUnit("<test>", "1 + pop")) == .ok);
    // One poll comes from computation; profiling and copying the result
    // each contribute another full traversal.
    try std.testing.expect(runtime.lastPolls() >= 3);
}

test "numeric: short kernel loops share the unit poll budget" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "40000 range pop 40000 range pop",
    )) == .ok);
    try std.testing.expect(runtime.lastPolls() >= 1);
}

test "kernel: bitwise words are pattern words over the integer bit pattern" {
    try helper.expectStacks(&.{
        .{
            .name = "the three total pattern words",
            .source = "12 10 band 12 10 bor 12 10 bxor",
            .expected = "8 14 6",
        },
        .{
            .name = "pattern laws",
            .source = "5 bnot bnot 7 7 bxor 0 bnot -1 bnot",
            .expected = "5 0 -1 0",
        },
        .{
            // Shifts move bits, so `bsl` truncates off the top instead of
            // raising the overflow every arithmetic word raises.
            .name = "shifts move bits rather than scaling",
            .source = "1 4 bsl 9223372036854775807 1 bsl -8 1 bsl",
            .expected = "16 -2 -16",
        },
        .{
            // `bsr` is logical: it fills zeros, so a negative pattern becomes
            // a large positive one rather than staying negative.
            .name = "right shift fills zeros from the top",
            .source = "-1 1 bsr 16 4 bsr 5 0 bsl",
            .expected = "9223372036854775807 1 5",
        },
        .{
            .name = "shifts round-trip inside the pattern width",
            .source = "6 3 bsl 3 bsr",
            .expected = "6",
        },
        .{
            .name = "pervasion and dict alignment come from the shared cursor",
            .source = "[1 2 4] 1 bsl [12 10] bnot {'a 6 'b 3} 1 band",
            .expected = "[2 4 8] [-13 -11] {'a 0 'b 1}",
        },
    });
    try helper.expectErrors(&.{
        .{
            .name = "bitwise words are int-only",
            .source = "1.5 1 band",
            .kind = "type",
            .word = "band",
        },
        .{
            .name = "characters are not patterns",
            .source = "\\a bnot",
            .kind = "type",
            .word = "bnot",
        },
        .{
            .name = "a shift count above the width is domain",
            .source = "1 64 bsl",
            .kind = "domain",
            .word = "bsl",
        },
        .{
            .name = "a negative shift count is domain",
            .source = "1 -1 bsr",
            .kind = "domain",
            .word = "bsr",
        },
        .{
            // A failing element is identified exactly as overflow is.
            .name = "a failing shift reports its index",
            .source = "1 [1 64] bsl",
            .kind = "domain",
            .word = "bsl",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
    });
}
