//! Executable proofs for sequence, search, and shape kernels.
const std = @import("std");
const helper = @import("kernel_test_support.zig");
const session = @import("../session.zig");

fn expectDisplay(source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var original = try session.Session.init(allocator, &.{});
    defer original.deinit();
    try runDisplaySource(&original, "<display-source>", source);
    var rendered = try original.stackDisplay();
    defer rendered.deinit();
    try std.testing.expectEqualStrings(expected, rendered.bytes());
}

/// Reparse proof for a display that is also valid source. Row breaks inside
/// one value keep its delimiters, so a lone value reads back unchanged; a
/// stack of several does not, because the display pastes its items side by
/// side and a reader sees one row at a time. SPEC.md grants the display no
/// round-trip guarantee, so only single-value cases belong here.
fn expectRoundTripDisplay(source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var original = try session.Session.init(allocator, &.{});
    defer original.deinit();
    try runDisplaySource(&original, "<display-source>", source);
    var rendered = try original.stackDisplay();
    defer rendered.deinit();
    try std.testing.expectEqualStrings(expected, rendered.bytes());

    var reread = try session.Session.init(allocator, &.{});
    defer reread.deinit();
    try runDisplaySource(&reread, "<display-output>", rendered.bytes());
    var repeated = try reread.stackDisplay();
    defer repeated.deinit();
    try std.testing.expectEqualStrings(rendered.bytes(), repeated.bytes());
}

fn runDisplaySource(
    runtime: *session.Session,
    name: []const u8,
    source: []const u8,
) !void {
    switch (try runtime.runUnit(name, source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
    }
}

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
        "[10 20 30] [2 0] at \"abc\" [2 0] at {'a 7} 'a at " ++
            "[0 127 128 255] [3 1] at",
        "[30 10] \"ca\" 7 [255 127]",
    );
}

test "sequence: where, in?, and find validate and search" {
    try helper.expectStack(
        "[1 0 1 0] where [2 4] [1 2 3] in? [2 3 2] 2 find [2 3] 9 find " ++
            "{'a 1} [{'a 1} {'b 2}] in? {'z 1} [{'a 1} {'b 2}] in?",
        "[0 2] [1 0] 0 2 1 0",
    );
    try helper.expectStack("[[1] [2]] [0] in?", "([0]\n [0])");
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
        "[[1 2] [3]] raze [1 2] [3 4] cat \"ab\" \"cd\" cat " ++
            "[0 255] [256] cat [0 255] 1 256 put",
        "[1 2 3] [1 2 3 4] \"abcd\" [0 255 256] [0 256]",
    );
}

test "sequence: flip and reshape obey rectangular row-major semantics" {
    try expectDisplay(
        "[[1 2] [3 4]] flip [1 2 3] [2 3] reshape [1 2] flip [] [2 0] reshape shape",
        "([1 3]  ([1 2 3]\n [2 4])  [1 2 3]) [1 2] [2 0]",
    );
    try expectRoundTripDisplay(
        "[0 1 2 3 4 5 6 7 8 9] [2 3 4] reshape",
        "(([0 1 2 3]\n  [4 5 6 7]\n  [8 9 0 1])\n" ++
            " ([2 3 4 5]\n  [6 7 8 9]\n  [0 1 2 3]))",
    );
    try helper.expectStack(
        "[0 1 2 3 4 5] [2 3] reshape str",
        "\"([0 1 2] [3 4 5])\"",
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

test "sequence: display indentation follows output columns and strings are not matrix rows" {
    try expectRoundTripDisplay(
        "(5 ([1 2] [3 4]))",
        "(5 ([1 2]\n    [3 4]))",
    );
    try expectRoundTripDisplay(
        "(\"a\" \"b\") (\"a\" \"bb\")",
        "(\"a\" \"b\") (\"a\" \"bb\")",
    );
}

test "sequence: display expands structural dictionaries and str stays canonical" {
    try expectRoundTripDisplay("{'type 'empty}", "{'type 'empty}");
    try expectRoundTripDisplay(
        "{'type 'concat 'left {'type 'empty} 'right {'type 'epsilon}}",
        "{\n" ++
            "  'type 'concat\n" ++
            "  'left {'type 'empty}\n" ++
            "  'right {'type 'epsilon}\n" ++
            "}",
    );
    try expectRoundTripDisplay(
        "{'node {'type 'concat 'left {'type 'empty} 'right {'type 'epsilon}}}",
        "{\n" ++
            "  'node {\n" ++
            "    'type 'concat\n" ++
            "    'left {'type 'empty}\n" ++
            "    'right {'type 'epsilon}\n" ++
            "  }\n" ++
            "}",
    );
    try expectRoundTripDisplay(
        "{'matrix ((1 2) (3 4))}",
        "{\n" ++
            "  'matrix ([1 2]\n" ++
            "           [3 4])\n" ++
            "}",
    );
    try helper.expectStack(
        "{'type 'concat 'left {'type 'empty} 'right {'type 'epsilon}} str",
        "\"{'type 'concat 'left {'type 'empty} 'right {'type 'epsilon}}\"",
    );
}
