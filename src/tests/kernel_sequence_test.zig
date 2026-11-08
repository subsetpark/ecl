//! Executable proofs for sequence, search, and shape kernels.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const helper = @import("kernel_test_support.zig");
const session = @import("../session.zig");

fn expectDisplay(source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var original = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
    var runtime_inputs1 = try runtime_fixture.Fixture.init();
    defer runtime_inputs1.deinit();
    var original = try session.Session.init(allocator, &.{}, runtime_inputs1.inputs(.{}), .default, .evaluate);
    defer original.deinit();
    try runDisplaySource(&original, "<display-source>", source);
    var rendered = try original.stackDisplay();
    defer rendered.deinit();
    try std.testing.expectEqualStrings(expected, rendered.bytes());

    var runtime_inputs2 = try runtime_fixture.Fixture.init();
    defer runtime_inputs2.deinit();
    var reread = try session.Session.init(allocator, &.{}, runtime_inputs2.inputs(.{}), .default, .evaluate);
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
    try helper.expectStack(
        "[[1 2] [3 4]] dup len swap shape [] empty? [1] empty?",
        "2 [2 2] 1 0",
    );
    try helper.expectError(.{
        .name = "len rejects dictionaries",
        .source = "{a 1} len",
        .kind = "type",
        .word = "len",
    });
    try helper.expectError(.{
        .name = "ragged shape",
        .source = "[[1 2] [3]] shape",
        .kind = "shape",
        .word = "shape",
    });
}

test "sequence: at gathers list string and dict indices" {
    try helper.expectStack(
        "[10 20 30] [2 0] at \"abc\" [2 0] at {a 7} `a at " ++
            "[0 127 128 255] [3 1] at",
        "[30 10] \"ca\" 7 [255 127]",
    );
}

test "sequence: flat generic gathers preserve whole cells repeats and narrowing" {
    try helper.expectStack(
        "[\"λ😀\" [1 2] {a 3} 7] [2 0 1 0] at " ++
            "[\"unused\" 7 9] [2 1 2] at " ++
            "[\"unused\"] \"aλ\" cat [2 1] at " ++
            "[\"x\" [1]] [] at " ++
            "[\"x\" [1]] [0] 513 take at len",
        "({a 3} \"λ😀\" [1 2] \"λ😀\") [9 7 9] \"λa\" () 513",
    );
    try helper.expectErrors(&.{
        .{ .name = "generic gather negative", .source = "[\"x\" [1]] [0 -1] at", .kind = "domain", .word = "at", .message = "at index is negative" },
        .{ .name = "generic gather bounds", .source = "[\"x\" [1]] [1 2] at", .kind = "domain", .word = "at", .message = "at index is out of bounds" },
    });
}

test "sequence: fold and fold1 boolean and numeric results" {
    try helper.expectStack(
        "[1 0 1] 1 (and) fold [0 0 1] 0 (or) fold " ++
            "[1 0 1] (and) fold1 [0 0 1] (or) fold1 " ++
            "[1 2 3] (+) fold1 [5] (or) fold1 [] 7 (and) fold " ++
            "[10 3 2] (-) fold1",
        "0 1 0 1 6 5 7 5",
    );
    try helper.expectErrors(&.{
        .{ .name = "empty fold1", .source = "[] (or) fold1", .kind = "domain" },
        .{ .name = "and validates later values", .source = "[0 2] 1 (and) fold", .kind = "type", .word = "and" },
        .{ .name = "or validates later values", .source = "[1 2] (or) fold1", .kind = "type", .word = "or" },
    });
}

test "sequence: where, in?, and find validate and search" {
    try helper.expectStack(
        "[1 0 1 0] where [0 2 0] first-where [0 0] first-where [] first-where " ++
            "[1 -1] first-where [2 4] [1 2 3] in? [2 3 2] 2 find [2 3] 9 find " ++
            "[] 9 find [[1] [2]] [2] find \"abc\" \\b find " ++
            "{a 1} [{a 1} {b 2}] in? {z 1} [{a 1} {b 2}] in?",
        "[0 2] 1 2 0 0 [1 0] 0 2 0 1 1 1 0",
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
        .{
            .name = "first-where rejects non-integer observed counts",
            .source = "[0 1.5 2] first-where",
            .kind = "type",
            .word = "first-where",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
        .{
            .name = "first-where rejects negative observed counts",
            .source = "[0 -1 2] first-where",
            .kind = "domain",
            .word = "first-where",
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

test "sequence: cut splits at nondecreasing starts" {
    try helper.expectStack(
        "[0 1 2 3 4 5 6] [0 2 5] cut [0 1 2 3 4 5 6] [2 5] cut [0 1 2] [0 0 3] cut " ++
            "[1.5 2.5 3.5] [0 1] cut \"hello world\" [0 6] cut [0 1 2] [] cut " ++
            "[[1 2] 3 \"x\"] [0 1] cut",
        "([0 1] [2 3 4] [5 6]) ([2 3 4] [5 6]) ([] [0 1 2] []) ([1.5] [2.5 3.5]) " ++
            "(\"hello \" \"world\") () (([1 2]) (3 \"x\"))",
    );
    try helper.expectError(.{
        .name = "decreasing cut start",
        .source = "[0 1 2] [2 1] cut",
        .kind = "domain",
        .word = "cut",
        .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
    });
    try helper.expectError(.{
        .name = "cut start past the end",
        .source = "[0 1 2] [4] cut",
        .kind = "domain",
        .word = "cut",
        .data = &.{.{ .name = "index", .expected = .{ .int = 0 } }},
    });
    try helper.expectError(.{
        .name = "non-integer cut start",
        .source = "[0 1 2] [0.5] cut",
        .kind = "type",
        .word = "cut",
    });
    try helper.expectError(.{
        .name = "cut of a non-list",
        .source = "7 [0] cut",
        .kind = "type",
        .word = "cut",
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

test "sequence: cons cat and raze widen within one class" {
    // Bytes join ints and narrower characters join wider ones in one typed
    // result; across classes the result is generic. `cons` onto an empty list
    // makes the atom's own leaf, so a string stays a string.
    try helper.expectStack(
        "\\a \"bc\" cons \\λ \"bc\" cons \"ab\" \"😀\" cat \"λc\" \"ab\" cat " ++
            "[1 2] [300 400] cat 300 [1 2] cons 5 () cons \\a \"\" cons",
        "\"abc\" \"λbc\" \"ab😀\" \"λcab\" [1 2 300 400] [300 1 2] [5] \"a\"",
    );
    try helper.expectStack(
        "(\"ab\" \"λc\") raze ([1 2] [300]) raze ([1 2] [1.5]) raze 1.5 [1 2] cons [1 2] 3 append",
        "\"abλc\" [1 2 300] (1 2 1.5) (1.5 1 2) [1 2 3]",
    );
}

test "sequence: flip and reshape obey rectangular row-major semantics" {
    try helper.expectStack(
        "([\"a\" \"long\"] [\"bc\" \"d\"]) flip " ++
            "([\"a\" \"bc\"] [\"long\" \"d\"]) match? " ++
            "([1 [] {x 2}] [\"long\" [3 4] [[5] [6 7]]]) flip " ++
            "([1 \"long\"] [[] [3 4]] [{x 2} [[5] [6 7]]]) match? " ++
            "[\"ab\" \"cd\"] flip [\"ac\" \"bd\"] match? " ++
            "[] flip [] match? \"abc\" flip \"abc\" match? " ++
            "[1 {x 2}] flip [1 {x 2}] match?",
        "1 1 1 1 1 1",
    );
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
            .name = "flip rejects unequal row widths",
            .source = "[[1 2] [3]] flip",
            .kind = "shape",
            .word = "flip",
        },
        .{
            .name = "flip rejects scalar after row",
            .source = "[[1 2] 3] flip",
            .kind = "shape",
            .word = "flip",
        },
        .{
            .name = "flip rejects row after scalar",
            .source = "[3 [1 2]] flip",
            .kind = "shape",
            .word = "flip",
        },
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
    try expectRoundTripDisplay("{type empty}", "{type empty}");
    try expectRoundTripDisplay(
        "{type concat left {type empty} right {type epsilon}}",
        "{\n" ++
            "  type concat\n" ++
            "  left {type empty}\n" ++
            "  right {type epsilon}\n" ++
            "}",
    );
    try expectRoundTripDisplay(
        "{node {type concat left {type empty} right {type epsilon}}}",
        "{\n" ++
            "  node {\n" ++
            "    type concat\n" ++
            "    left {type empty}\n" ++
            "    right {type epsilon}\n" ++
            "  }\n" ++
            "}",
    );
    try expectRoundTripDisplay(
        "{matrix ((1 2) (3 4))}",
        "{\n" ++
            "  matrix ([1 2]\n" ++
            "          [3 4])\n" ++
            "}",
    );
    try helper.expectStack(
        "{type concat left {type empty} right {type epsilon}} str",
        "\"{type concat left {type empty} right {type epsilon}}\"",
    );
}

test "sequence: rest reverse and find" {
    try helper.expectStacks(&.{
        .{ .name = "rest", .source = "[1 2 3] rest [7] rest [0.1 -0.0 0.2] rest \"ab\" rest", .expected = "[2 3] [] [-0.0 0.2] \"b\"" },
        .{ .name = "reverse", .source = "[1 2 3] reverse [] reverse [0.1 -0.0 0.2] reverse \"ab\" reverse", .expected = "[3 2 1] () [0.2 -0.0 0.1] \"ba\"" },
        .{
            .name = "find compares whole values and answers the length on a miss",
            .source = "[1 2 1] 2 find [[1] [2]] [2] find [] [2] find [1 2] 3 find [1.0 2.0] 2.0 find [{}] {} find",
            .expected = "1 1 0 2 1 0",
        },
    });
    try helper.expectErrors(&.{
        .{ .name = "rest of empty", .source = "[] rest", .kind = "domain", .word = "rest" },
        .{ .name = "rest of an atom", .source = "1 rest", .kind = "type", .word = "rest" },
        .{ .name = "reverse of a dict", .source = "{a 1} reverse", .kind = "type", .word = "reverse" },
        .{ .name = "find in an atom", .source = "5 1 find", .kind = "type", .word = "find" },
    });
}

test "sequence: cons builds short spines in place and long ones through the copy driver" {
    try helper.expectStacks(&.{
        .{ .name = "list head onto a quotation", .source = "(1 -) (dip) cons", .expected = "((1 -) dip)" },
        .{ .name = "symbol head onto a quotation", .source = "`w (dip) cons", .expected = "(w dip)" },
        .{ .name = "list head onto an empty list", .source = "[1] () cons [1] [] cons", .expected = "([1]) ([1])" },
        .{ .name = "list head onto a typed leaf", .source = "[0] [1 2 3] cons \"ab\" \"cd\" cons", .expected = "([0] 1 2 3) (\"ab\" \\c \\d)" },
        .{ .name = "dict head keeps the tail's elements", .source = "{a 1} [[2] [3]] cons", .expected = "({a 1} [2] [3])" },
        .{ .name = "atom head onto a mixed spine", .source = "1 (x 2) cons", .expected = "(1 x 2)" },
        .{ .name = "tail at the in-place limit", .source = "[] 16 range cons len", .expected = "17" },
        .{ .name = "tail beyond the in-place limit", .source = "[] 17 range cons len [] 17 range cons first", .expected = "18 ()" },
        .{ .name = "tail stays shared", .source = "(dip) dup (1 -) swap cons swap", .expected = "((1 -) dip) (dip)" },
    });
}

test "sequence: cons call and cons dip run the quotation without building it" {
    try helper.expectStacks(&.{
        .{ .name = "cons call runs the tail with the head on the stack", .source = "5 (1 +) cons call", .expected = "6" },
        .{ .name = "cons call with a quotation head", .source = "1 2 3 (1 -) (dip) cons (dip) cons call", .expected = "0 2 3" },
        .{ .name = "cons call onto a data list pushes every element", .source = "1 [2 3] cons call", .expected = "1 2 3" },
        .{ .name = "cons call onto an empty list pushes the head", .source = "7 () cons call", .expected = "7" },
        .{ .name = "cons dip protects the value beneath the head", .source = "1 2 3 (1 -) (dip) cons dip", .expected = "0 2 3" },
        .{ .name = "cons dip with an atom head", .source = "10 20 1 (+) cons dip", .expected = "11 20" },
        .{ .name = "a symbol head still becomes a word of the program", .source = "5 `dup (1) cons call", .expected = "5 5 1" },
        .{ .name = "a symbol head under dip", .source = "8 9 `dup (+) cons dip", .expected = "16 9" },
        .{ .name = "a shadowed call runs the words as written", .source = "(pop 42) `call def 1 (2) cons call", .expected = "42" },
        .{ .name = "a definition's tail cons call", .source = "((2 *) cons call) `twice def 4 twice", .expected = "8" },
    });
    try helper.expectErrors(&.{
        .{ .name = "cons call without a list keeps cons's error", .source = "1 2 cons call", .kind = "type", .word = "cons" },
        .{ .name = "cons dip without a list keeps cons's error", .source = "1 2 3 cons dip", .kind = "type", .word = "cons" },
        .{ .name = "cons dip needs the protected value", .source = "1 (2) cons dip", .kind = "underflow", .word = "dip" },
        .{ .name = "a fault in the quotation is the quotation's own", .source = "1 (pop pop) cons call", .kind = "underflow", .word = "pop" },
    });
}

test "sequence: partial quotes a symbol head and fuses with call and dip" {
    try helper.expectStacks(&.{
        .{ .name = "atom head", .source = "3 (+) partial", .expected = "(3 +)" },
        .{ .name = "symbol head is quoted", .source = "`w () partial `w (dip) partial", .expected = "(`w) (`w dip)" },
        .{ .name = "quotation head", .source = "(1 -) (dip) partial", .expected = "((1 -) dip)" },
        .{ .name = "the built quotation pushes the symbol", .source = "`w (dup) partial call", .expected = "w w" },
        .{ .name = "partial call with a symbol head", .source = "`w (dup) partial call", .expected = "w w" },
        .{ .name = "partial call with a literal-quoted head", .source = "`w literal (dup) partial call", .expected = "w w" },
        .{ .name = "partial call with an atom head", .source = "5 (1 +) partial call", .expected = "6" },
        .{ .name = "partial dip", .source = "1 2 3 (1 -) (dip) partial dip", .expected = "0 2 3" },
        .{ .name = "partial dip with a symbol head", .source = "9 `w (dup) partial dip", .expected = "w w 9" },
        .{ .name = "a definition's tail partial call", .source = "((2 *) partial call) `twice def 4 twice", .expected = "8" },
    });
    try helper.expectErrors(&.{
        .{ .name = "partial needs a quotation", .source = "1 2 partial", .kind = "type", .word = "partial" },
        .{ .name = "partial call without a list keeps partial's error", .source = "1 2 partial call", .kind = "type", .word = "partial" },
        .{ .name = "partial dip needs the protected value", .source = "1 (2) partial dip", .kind = "underflow", .word = "dip" },
        .{ .name = "a fault in the quotation is the quotation's own", .source = "1 (pop pop) partial call", .kind = "underflow", .word = "pop" },
    });
}
