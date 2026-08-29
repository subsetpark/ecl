const std = @import("std");
const formatter = @import("../formatter.zig");
const doc_text = @import("../doc.zig");
const heap = @import("../heap.zig");
const printer = @import("../print.zig");
const reader = @import("../reader.zig");
const equal = @import("../equal.zig");
const support = @import("kernel_test_support.zig");

const allocator = std.testing.allocator;

test "documentation normalization folds physical prose lines" {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    var diag: reader.Diag = .{};
    var parsed = switch (try reader.read(host.cleanup(), "doc.ecl", "\"a\n    b\n\n    - one\n      more\"", &diag)) {
        .complete => |complete| complete,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer parsed.deinit();
    const normalized = try doc_text.normalize(allocator, parsed.values()[0]);
    defer host.domain().releaseValue(normalized);
    const rendered = try printer.toOwnedString(allocator, normalized);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("\"a b\\n\\n- one more\"", rendered);
}

fn expectFormat(source: []const u8, expected: []const u8) !void {
    const formatted = try formatter.format(allocator, source);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    const repeated = try formatter.format(allocator, formatted);
    defer allocator.free(repeated);
    try std.testing.expectEqualStrings(formatted, repeated);
}

fn expectParseEquivalent(source: []const u8) !void {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    const formatted = try formatter.format(allocator, source);
    defer allocator.free(formatted);
    var original_diag: reader.Diag = .{};
    var formatted_diag: reader.Diag = .{};
    var original = switch (try reader.read(host.cleanup(), "original.ecl", source, &original_diag)) {
        .complete => |parsed| parsed,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer original.deinit();
    var reparsed = switch (try reader.read(host.cleanup(), "formatted.ecl", formatted, &formatted_diag)) {
        .complete => |parsed| parsed,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer reparsed.deinit();
    try std.testing.expectEqual(original.values().len, reparsed.values().len);
    for (original.values(), reparsed.values()) |before, after| {
        try std.testing.expect(try equal.matchWithAllocator(allocator, before, after));
    }
}

test "formatter keeps a fitting module registration tail together" {
    const source = "((1) 'x def) 'stats @defm\n";
    try expectFormat(
        source,
        "### module stats\n(\n ### def x\n (1) 'x def) 'stats @defm\n",
    );
    try expectParseEquivalent(source);

    const long_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const long_source = try std.fmt.allocPrint(allocator, "((1) 'x def) '{s} @defm\n", .{long_name});
    defer allocator.free(long_source);
    const long_expected = try std.fmt.allocPrint(
        allocator,
        "### module {s}\n(\n ### def x\n (1) 'x def)\n'{s} @defm\n",
        .{ long_name, long_name },
    );
    defer allocator.free(long_expected);
    try expectFormat(long_source, long_expected);
}

test "formatter applies uniform aligned structural layout" {
    try expectFormat(
        "(alpha beta gamma)",
        "(alpha beta gamma)\n",
    );
    try expectFormat(
        "(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb " ++
            "(cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc " ++
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd))",
        "(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
            " (cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n" ++
            "  dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd))\n",
    );
    try expectFormat("(alpha beta\ngamma delta)", "(alpha beta\n gamma delta)\n");
    try expectFormat("(\n foo\n)", "(\n foo\n)\n");
    try expectFormat("(| x y | x y)", "(|x y| x y)\n");
}

test "multiline modules break only their local top-level run" {
    const source = "((1) 'x def) @module dup 'stats register wrap";
    try expectFormat(
        source,
        "(\n ### def x\n (1) 'x def) @module dup 'stats register wrap\n",
    );
    try expectParseEquivalent(source);

    const trailing_break = "((1) 'x def\n) @module dup 'stats register wrap";
    try expectFormat(
        trailing_break,
        "(\n ### def x\n (1) 'x def\n) @module dup 'stats register wrap\n",
    );
    try expectParseEquivalent(trailing_break);
}

test "long top-level runs pack locally to the configured width" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    for (0..60) |index| {
        if (index > 0) try source.append(allocator, ' ');
        const token = try std.fmt.allocPrint(allocator, "{d}", .{index});
        defer allocator.free(token);
        try source.appendSlice(allocator, token);
    }
    const formatted = try formatter.format(allocator, source.items);
    defer allocator.free(formatted);
    var saw_packed_continuation = false;
    var lines = std.mem.tokenizeScalar(u8, formatted, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= formatter.max_width);
        if (std.mem.count(u8, line, " ") > 1) saw_packed_continuation = true;
    }
    try std.testing.expect(saw_packed_continuation);
}

test "broken nested runs refill each continuation line" {
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const c = "cccccccccccccccccccc";
    const d = "dddddddddddddddddddd";
    try expectFormat(
        "(" ++ a ++ " " ++ b ++ " " ++ c ++ " " ++ d ++ ")",
        "(" ++ a ++ " " ++ b ++ "\n " ++ c ++ " " ++ d ++ ")\n",
    );
}

test "comments break only their local structural run" {
    const source = "(dup type 'list match? (# nested comment\n dup len dup 0 > swap 2 mod 1 = and) if)";
    try expectFormat(
        source,
        "(dup type 'list match?\n" ++
            " (# nested comment\n" ++
            "  dup len dup 0 > swap 2 mod 1 = and)\n" ++
            " if)\n",
    );
    try expectParseEquivalent(source);
}

test "formatter preserves comments and atomic literal contents" {
    const source =
        "# heading with  two spaces\n" ++
        "(foo # trailing exactly\n" ++
        " bar \"raw\n  string\" \\space)\n";
    try expectFormat(
        source,
        "# heading with  two spaces\n" ++
            "(foo # trailing exactly\n" ++
            " bar\n" ++
            " \"raw\n  string\"\n" ++
            " \\space)\n",
    );
    try expectParseEquivalent(source);
}

test "formatter owns canonical definition section comments" {
    const source =
        "# ordinary lead\n" ++
        "# defp stale-public\n" ++
        "# public details\n" ++
        "(-- n)\n(1)\n'public def\n\n\n" ++
        "# def stale-private\n" ++
        "[-- n]\n(2)\n'private defp\n" ++
        "# def stale-constant\n" ++
        "\"secret\" 'constant setp\n" ++
        "42 'answer set\n" ++
        "### overview\n" ++
        "\"ab\" 'letters def\n";
    try expectFormat(
        source,
        "# ordinary lead\n\n" ++
            "### def public\n" ++
            "# public details\n" ++
            "(-- n)\n(1)\n'public def\n\n" ++
            "### defp private\n" ++
            "[-- n]\n(2)\n'private defp\n" ++
            "\n### defp constant\n" ++
            "\"secret\" 'constant setp\n" ++
            "\n### def answer\n" ++
            "42 'answer set\n" ++
            "### overview\n\n" ++
            "### def letters\n" ++
            "\"ab\" 'letters def\n",
    );
    try expectParseEquivalent(source);

    const nested =
        "(\n" ++
        "(-- n)\n(1)\n'visible def\n" ++
        "# note\n# def stale\n# hidden details\n" ++
        "(-- n)\n(2)\n'hidden defp\n" ++
        ") 'm @defm\n";
    try expectFormat(
        nested,
        "### module m\n" ++
            "(\n" ++
            " ### def visible\n" ++
            " (-- n)\n (1)\n 'visible def\n # note\n\n" ++
            " ### defp hidden\n" ++
            " # hidden details\n" ++
            " (-- n)\n (2)\n 'hidden defp\n) 'm @defm\n",
    );
    try expectParseEquivalent(nested);

    const nested_synthesized =
        "(\n" ++
        "# attached inside the module\n" ++
        "(-- n)\n(3)\n'generated def\n" ++
        ") 'm @defm\n";
    try expectFormat(
        nested_synthesized,
        "### module m\n" ++
            "(\n" ++
            " ### def generated\n" ++
            " # attached inside the module\n" ++
            " (-- n)\n (3)\n 'generated def\n" ++
            ") 'm @defm\n",
    );
    try expectParseEquivalent(nested_synthesized);

    const synthesized =
        "# attached details\n" ++
        "# remain with the definition\n" ++
        "(-- n)\n(3)\n'generated def\n";
    try expectFormat(
        synthesized,
        "### def generated\n" ++
            "# attached details\n" ++
            "# remain with the definition\n" ++
            "(-- n)\n(3)\n'generated def\n",
    );
    try expectParseEquivalent(synthesized);

    const duplicated_between_annotation_and_body =
        "### def generated\n" ++
        "(-- n)\n" ++
        "### def generated\n" ++
        "(3)\n" ++
        "'generated def\n";
    try expectFormat(
        duplicated_between_annotation_and_body,
        "### def generated\n" ++
            "(-- n)\n" ++
            "(3)\n" ++
            "'generated def\n",
    );
    try expectParseEquivalent(duplicated_between_annotation_and_body);

    const inert_dict = "{(-- n) (1) 'not-a-definition def}";
    try expectFormat(inert_dict, inert_dict ++ "\n");
    try expectParseEquivalent(inert_dict);
}

test "formatter reflows only structurally recognized documentation" {
    const source =
        "### def explain\n" ++
        "(value -- value : \"This documentation contains enough ordinary prose to exceed the configured " ++
        "width and therefore needs to flow across several lines at clean word boundaries.\")\n" ++
        "(dup)\n" ++
        "'explain def\n";
    const expected =
        "### def explain\n" ++
        "(value -- value :\n" ++
        " \"This documentation contains enough ordinary prose to exceed the configured width and therefore\n" ++
        "  needs to flow across several lines at clean word boundaries.\")\n" ++
        "(dup)\n" ++
        "'explain def\n";
    try expectFormat(source, expected);

    const square_source =
        "[value -- value : \"This square-delimited annotation contains enough ordinary prose to exceed " ++
        "the configured width and must retain its original delimiters when reflowed.\"]\n" ++
        "(dup)\n" ++
        "'square-doc def\n";
    const square_expected =
        "### def square-doc\n" ++
        "[value -- value :\n" ++
        " \"This square-delimited annotation contains enough ordinary prose to exceed the configured width and\n" ++
        "  must retain its original delimiters when reflowed.\"]\n" ++
        "(dup)\n" ++
        "'square-doc def\n";
    try expectFormat(square_source, square_expected);

    const ordinary = "(\"This ordinary string is deliberately kept byte-for-byte, even when it is much longer " ++
        "than the target formatting width and contains   repeated spaces.\")";
    try expectFormat(ordinary, ordinary ++ "\n");
}

test "doc-only prose keeps its prefix and preserves paragraphs and bullets" {
    const source =
        "(: \"  First prose line that continues softly across\n" ++
        "      physical source lines and is long enough to need canonical wrapping in the formatter output.\n\n" ++
        "      - One bullet whose continuation is also folded into the same logical bullet item.\n" ++
        "        More words for that item.\n" ++
        "      - Two.\")\n" ++
        "(1)\n" ++
        "'documented def\n";
    const formatted = try formatter.format(allocator, source);
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.startsWith(u8, formatted, "### def documented\n(: \"First prose line"));
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\n    - One bullet") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\n    - Two.\")") != null);
    var lines = std.mem.splitScalar(u8, formatted, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= formatter.max_width);
    }
    const repeated = try formatter.format(allocator, formatted);
    defer allocator.free(repeated);
    try std.testing.expectEqualStrings(formatted, repeated);

    const executable = try std.fmt.allocPrint(allocator, "{s} 'documented doc", .{formatted});
    defer allocator.free(executable);
    try support.expectStack(
        executable,
        "\"First prose line that continues softly across physical source lines and is long enough to need " ++
            "canonical wrapping in the formatter output.\\n\\n- One bullet whose continuation is also folded " ++
            "into the same logical bullet item. More words for that item.\\n- Two.\"",
    );
}

test "formatter rejects invalid source without evaluating valid source" {
    try std.testing.expectError(error.InvalidUtf8, formatter.format(allocator, &.{0xff}));
    try std.testing.expectError(error.InvalidSource, formatter.format(allocator, "(unclosed"));
    try expectFormat("{'kind 'user 'msg \"not raised\"} raise", "{'kind 'user 'msg \"not raised\"} raise\n");
}

test "formatting preserves parsed structure across the ordinary grammar" {
    try expectParseEquivalent(
        "1, 2 (|x y| x y [1 {2 \\newline}] # keep this comment\n" ++
            "          (3 4)) 'quoted \"literal   bytes\"",
    );
}

fn formatterAllocationProbe(failing: std.mem.Allocator) !void {
    const output = try formatter.format(
        failing,
        "(value -- value : \"Documentation that exercises normalized prose.\") (dup) 'x def",
    );
    failing.free(output);
}

test "formatter reports every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(allocator, formatterAllocationProbe, .{});
}

test "formatter handles the reader's maximum nesting without host recursion" {
    const depth = 10_000;
    const source = try allocator.alloc(u8, depth * 2 + 1);
    defer allocator.free(source);
    @memset(source[0..depth], '(');
    source[depth] = '1';
    @memset(source[depth + 1 ..], ')');
    const formatted = try formatter.format(allocator, source);
    defer allocator.free(formatted);
    try std.testing.expectEqual(source.len + 1, formatted.len);
    try std.testing.expectEqualSlices(u8, source, formatted[0..source.len]);
    try std.testing.expectEqual(@as(u8, '\n'), formatted[formatted.len - 1]);
}

test "formatter synthesizes and normalizes module navigation headers" {
    // A registration earns a header on the same terms a definition does, and
    // the body keeps the definition headers it already earns inside.
    const registration = "((1) 'x def) 'stats @defm\n";
    const headed = "### module stats\n(\n ### def x\n (1) 'x def) 'stats @defm\n";
    try expectFormat(registration, headed);
    // A stale header is rewritten from the registration itself, never trusted.
    try expectFormat("### module wrong\n" ++ registration, headed);
    // The seeded phrase is one form, so its values list carries the header and
    // an attached comment stays below it exactly as it does for a definition.
    const seeded = "# a seeded counter\n[[0]] ((1 +) 'tick def) seed 'counter @defm\n";
    try expectFormat(
        seeded,
        "### module counter\n# a seeded counter\n[[0]]\n(\n ### def tick\n" ++
            " (1 +) 'tick def) seed 'counter @defm\n",
    );
    // `with` is ordinary composition rather than constructor metadata. Its
    // former seeded spelling therefore earns no module navigation header and
    // formats as the independent forms the program actually evaluates.
    const composed = "[1] ((1) 'x def) with 'legacy @defm\n";
    try expectFormat(
        composed,
        "[1]\n(\n ### def x\n (1) 'x def) with 'legacy @defm\n",
    );
    // A computed name gets no header, matching def's rule.
    try expectFormat(
        "((1) 'x def) chosen-name @defm\n",
        "(\n ### def x\n (1) 'x def) chosen-name @defm\n",
    );
    // Anonymous construction names nothing, so it is an ordinary expression
    // and earns no header — with or without a symbol beside it.
    try expectFormat(
        "((1) 'x def) @module\n",
        "(\n ### def x\n (1) 'x def) @module\n",
    );
    try expectFormat(
        "((1) 'x def) @module 'stats register\n",
        "(\n ### def x\n (1) 'x def) @module 'stats register\n",
    );
    // A header is synthesized and rewritten only where a registration is
    // recognized, so above an anonymous construction the text stays an
    // ordinary comment rather than becoming a navigation header the file has
    // no definition for.
    try expectFormat(
        "### module stats\n((1) 'x def) @module\n",
        "### module stats\n(\n ### def x\n (1) 'x def) @module\n",
    );
    try expectParseEquivalent(registration);
    try expectParseEquivalent(seeded);
    try expectParseEquivalent(composed);
    try expectParseEquivalent("((1) 'x def) @module 'stats register\n");
}
