//! Executable proofs for numeric dispatch, pervasion, faults, and ownership.
const std = @import("std");
const value = @import("value.zig");
const numeric = @import("kernel_numeric.zig");
const session = @import("session.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const helper = @import("kernel_test_support.zig");

test "numeric: comptime matrix is total over supported signatures and dispatches once" {
    try std.testing.expect(numeric.matrixEntryForTest(.add, .leaf_i64, .leaf_f64));
    try std.testing.expect(numeric.matrixEntryForTest(.sub, .leaf_char1, .leaf_char4));
    try std.testing.expect(!numeric.matrixEntryForTest(.add, .leaf_symbol, .leaf_i64));
    try std.testing.expect(!numeric.matrixEntryForTest(.int_div, .leaf_f64, .leaf_i64));
}

test "numeric: scalar leaf and mixed numeric semantics match" {
    try helper.expectStack(
        std.testing.allocator,
        "[1 2 3] 0.5 + 9007199254740993 9007199254740992.0 = \\a 1 +",
        "[1.5 2.5 3.5] 0 \\b",
    );
}

test "numeric: empty leaves bypass scalar signature selection" {
    try helper.expectStack(std.testing.allocator, "\"\" \"\" + \"\" neg", "() ()");
}

test "numeric: transcendental d.22 edges" {
    try helper.expectStack(
        std.testing.allocator,
        "0 exp 1 log 0 sin 0 cos 0 0 atan2 inf log -inf exp " ++
            "[0 0] exp [0 0] [1 1] atan2",
        "1.0 0.0 0.0 1.0 0.0 inf 0.0 [1.0 1.0] [0.0 0.0]",
    );
    try helper.expectError(std.testing.allocator, "0 log", &.{"'kind 'overflow"});
    try helper.expectError(std.testing.allocator, "-1 log", &.{"'kind 'domain"});
    try helper.expectError(std.testing.allocator, "inf sin", &.{"'kind 'domain"});
    try helper.expectError(std.testing.allocator, "1000 exp", &.{"'kind 'overflow"});
    try helper.expectError(std.testing.allocator, "[1 -1] log", &.{ "'kind 'domain", "'index 1" });
}

test "numeric: ragged broadcast dict alignment and representation parity" {
    try helper.expectStack(std.testing.allocator, "[[1 2] [3]] 10 *", "([10 20] [30])");
    try helper.expectStack(
        std.testing.allocator,
        "{'a 1 'b 2} {'b 10 'c 30} + {'a 1} [10 20] +",
        "{'a 1 'b 12 'c 30} {'a [11 21]}",
    );
}

test "numeric: fault blocks report first index before aliased stores" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit("<test>", "9223372036854775806")) == .ok);
    const failure = (try runtime.runUnit("<test>", "[1 2] +")).err;
    defer heap.releaseValue(allocator, failure);
    try std.testing.expectEqual(@as(usize, 1), runtime.stack.items.len);
    try std.testing.expectEqual(@as(i64, 9223372036854775806), runtime.stack.items[0].int);
    const rendered = try @import("print.zig").toOwnedString(allocator, failure);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'kind 'overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'index 1") != null);
    try helper.expectError(allocator, "9223372036854775807 [1] +", &.{"'index 0"});
    try helper.expectError(
        allocator,
        "9223372036854775552 300 range +",
        &.{ "'kind 'overflow", "'index 256" },
    );
}

test "numeric: conform and depth diagnostics are bounded" {
    try helper.expectError(
        std.testing.allocator,
        "[1 2] [3] +",
        &.{ "'kind 'conform", "'left 2", "'right 1" },
    );
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..257) |_| try source.append(std.testing.allocator, '[');
    try source.append(std.testing.allocator, '1');
    for (0..257) |_| try source.append(std.testing.allocator, ']');
    try source.appendSlice(std.testing.allocator, " 1 +");
    try helper.expectError(
        std.testing.allocator,
        source.items,
        &.{ "'kind 'domain", "exceeds 256 levels" },
    );
}

test "numeric: long leaves poll at bounded chunks" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit("<test>", "70000 range 1 + len")) == .ok);
    try std.testing.expect(runtime.last_polls >= 2);
    try std.testing.expectEqual(@as(i64, 70_000), runtime.stack.items[0].int);
}

test "numeric: result materialization remains cancellable" {
    const allocator = std.testing.allocator;
    const integers = try allocator.alloc(i64, 70_000);
    defer allocator.free(integers);
    for (integers, 0..) |*integer, index| integer.* = @intCast(index);
    const input = try list.fromI64Slice(allocator, integers);
    defer heap.releaseValue(allocator, input);

    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    heap.retainValue(input);
    runtime.stack.append(allocator, input) catch |err| {
        heap.releaseValue(allocator, input);
        return err;
    };
    try std.testing.expect((try runtime.runUnit("<test>", "1 + pop")) == .ok);
    // One poll comes from computation; profiling and copying the result
    // each contribute another full traversal.
    try std.testing.expect(runtime.last_polls >= 3);
}

test "numeric: short kernel loops share the unit poll budget" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "40000 range pop 40000 range pop",
    )) == .ok);
    try std.testing.expect(runtime.last_polls >= 1);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const outcome = try runtime.runUnit(
        "<allocation>",
        "[[1 2] [3]] 10 * pop [0 1] exp pop [0 1] [1 1] atan2",
    );
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "numeric: allocation failures release every operand and result" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "numeric test module references the frozen value tags" {
    try std.testing.expectEqual(@as(usize, 9), @typeInfo(value.HeapKind).@"enum".fields.len);
}
