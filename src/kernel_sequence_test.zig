//! Executable proofs for sequence, search, and shape kernels.
const helper = @import("kernel_test_support.zig");

test "sequence: len shape and ragged shape errors" {
    try helper.expectStack("[[1 2] [3 4]] dup len swap shape", "2 [2 2]");
    try helper.expectError(.{
        .name = "ragged shape",
        .source = "[[1 2] [3]] shape",
        .kind = "shape",
        .word = "shape",
    });
}

test "sequence: at gathers list string and dict indices" {
    try helper.expectStack(
        "[10 20 30] [2 0] at \"abc\" [2 0] at {'a 7} 'a at",
        "[30 10] \"ca\" 7",
    );
}

test "sequence: where in and find validate and search" {
    try helper.expectStack(
        "[1 0 1 0] where [2 4] [1 2 3] in [2 3 2] 2 find [2 3] 9 find",
        "[0 2] [1 0] 0 2",
    );
    try helper.expectErrors(&.{
        .{
            .name = "where rejects non-integer counts",
            .source = "[1 1.5] where",
            .kind = "type",
            .word = "where",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
        .{
            .name = "where rejects negative counts",
            .source = "[1 -1] where",
            .kind = "domain",
            .word = "where",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
    });
}

test "sequence: take cycles and where replicates" {
    try helper.expectStack(
        "[1 2 3] 2 take [1 2 3] 3 take [1 2] 5 take [1 2] -5 take [] 0 take [2 0 3] where",
        "[1 2] [1 2 3] [1 2 1 2 1] [2 1 2 1 2] () [0 0 2 2 2]",
    );
    try helper.expectError(.{
        .name = "nonzero take from empty list",
        .source = "[] 1 take",
        .kind = "domain",
        .word = "take",
    });
}

test "sequence: first rest take drop reverse and range preserve representation" {
    try helper.expectStack(
        "\"abc\" first \"abc\" rest [1 2 3] -2 take [1 2 3] -1 drop \"abc\" reverse 4 range",
        "\\a \"bc\" [2 3] [1 2] \"cba\" [0 1 2 3]",
    );
}

test "sequence: zero-length string results remain strings" {
    try helper.expectStack(
        "\"a\" rest \"\" reverse \"a\" 1 drop \"abc\" 0 take \"\" \"\" cat \"\" [] cat",
        "\"\" \"\" \"\" \"\" \"\" \"\"",
    );
    try helper.expectStack("\"a\" rest \",\" split", "(\"\")");
}

test "sequence: raze and cat specialize their outputs" {
    try helper.expectStack(
        "[[1 2] [3]] raze [1 2] [3 4] cat \"ab\" \"cd\" cat",
        "[1 2 3] [1 2 3 4] \"abcd\"",
    );
}

test "sequence: flip and reshape obey rectangular row-major semantics" {
    try helper.expectStack(
        "[[1 2] [3 4]] flip [1 2 3] [2 3] reshape [1 2] flip [] [2 0] reshape shape",
        "([1 3] [2 4]) ([1 2 3] [1 2 3]) [1 2] [2 0]",
    );
    try helper.expectErrors(&.{
        .{
            .name = "reshape cannot hide a later axis behind zero",
            .source = "[] [0 3] reshape",
            .kind = "shape",
            .word = "reshape",
            .data = &.{.{ .name = "index", .expected = .{ .int = 0 } }},
            .message_contains = "cannot retain axes",
        },
        .{
            .name = "flip cannot hide trailing axes",
            .source = "[[] []] flip",
            .kind = "shape",
            .word = "flip",
            .message_contains = "cannot retain trailing axes",
        },
    });
}
