//! Executable proofs for sequence, search, and shape kernels.
const std = @import("std");
const session = @import("session.zig");
const heap = @import("heap.zig");
const helper = @import("kernel_test_support.zig");

test "sequence: len shape and ragged shape errors" {
    try helper.expectStack(std.testing.allocator, "[[1 2] [3 4]] dup len swap shape", "2 [2 2]");
    try helper.expectError(
        std.testing.allocator,
        "[[1 2] [3]] shape",
        &.{"'kind 'shape"},
    );
}

test "sequence: at gathers list string and dict indices" {
    try helper.expectStack(
        std.testing.allocator,
        "[10 20 30] [2 0] at \"abc\" [2 0] at {'a 7} 'a at",
        "[30 10] \"ca\" 7",
    );
}

test "sequence: where in and find validate and search" {
    try helper.expectStack(
        std.testing.allocator,
        "[1 0 1 0] where [2 4] [1 2 3] in [2 3 2] 2 find [2 3] 9 find",
        "[0 2] [1 0] 0 2",
    );
    try helper.expectError(std.testing.allocator, "[1 1.5] where", &.{ "'kind 'type", "'index 1" });
    try helper.expectError(std.testing.allocator, "[1 -1] where", &.{ "'kind 'domain", "'index 1" });
}

test "sequence: take cycles and where replicates" {
    try helper.expectStack(
        std.testing.allocator,
        "[1 2 3] 2 take [1 2 3] 3 take [1 2] 5 take [1 2] -5 take [] 0 take [2 0 3] where",
        "[1 2] [1 2 3] [1 2 1 2 1] [2 1 2 1 2] () [0 0 2 2 2]",
    );
    try helper.expectError(std.testing.allocator, "[] 1 take", &.{"'kind 'domain"});
}

test "sequence: first rest take drop reverse and range preserve representation" {
    try helper.expectStack(
        std.testing.allocator,
        "\"abc\" first \"abc\" rest [1 2 3] -2 take [1 2 3] -1 drop \"abc\" reverse 4 range",
        "\\a \"bc\" [2 3] [1 2] \"cba\" [0 1 2 3]",
    );
}

test "sequence: zero-length string results remain strings" {
    try helper.expectStack(
        std.testing.allocator,
        "\"a\" rest \"\" reverse \"a\" 1 drop \"abc\" 0 take \"\" \"\" cat \"\" [] cat",
        "\"\" \"\" \"\" \"\" \"\" \"\"",
    );
    try helper.expectStack(std.testing.allocator, "\"a\" rest \",\" split", "(\"\")");
}

test "sequence: raze and cat specialize their outputs" {
    try helper.expectStack(
        std.testing.allocator,
        "[[1 2] [3]] raze [1 2] [3 4] cat \"ab\" \"cd\" cat",
        "[1 2 3] [1 2 3 4] \"abcd\"",
    );
}

test "sequence: flip and reshape obey rectangular row-major semantics" {
    try helper.expectStack(
        std.testing.allocator,
        "[[1 2] [3 4]] flip [1 2 3] [2 3] reshape [1 2] flip [] [2 0] reshape shape",
        "([1 3] [2 4]) ([1 2 3] [1 2 3]) [1 2] [2 0]",
    );
    try helper.expectError(
        std.testing.allocator,
        "[] [0 3] reshape",
        &.{ "'kind 'shape", "'index 0", "cannot retain axes" },
    );
    try helper.expectError(
        std.testing.allocator,
        "[[] []] flip",
        &.{ "'kind 'shape", "cannot retain trailing axes" },
    );
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const outcome = try runtime.runUnit(
        "<allocation>",
        "[[1 2] [3 4]] flip pop [1 2 3] [2 3] reshape pop " ++
            "[[1 2] [3]] raze pop [1 2] 5 take pop [2 0 3] where",
    );
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "sequence: allocation failures release every intermediate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
