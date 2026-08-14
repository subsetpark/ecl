const std = @import("std");
const formatter = @import("formatter.zig");
const doc_text = @import("doc.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const poll = @import("poll.zig");
const printer = @import("print.zig");
const reader = @import("reader.zig");
const equal = @import("equal.zig");
const support = @import("kernel_test_support.zig");

const allocator = std.testing.allocator;

fn noPoll(_: *anyopaque) poll.Error!void {}
const PollStop = struct {
    calls: usize = 0,
    fail_at: usize,
    fn tick(raw: *anyopaque) poll.Error!void {
        const self: *PollStop = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.Ecl;
    }
    fn poller(self: *PollStop) poll.Poller {
        return .{ .context = self, .poll_fn = tick };
    }
};

test "documentation normalization folds physical prose lines" {
    var diag: reader.Diag = .{};
    var parsed = switch (try reader.read(allocator, "doc.ecl", "\"a\n    b\n\n    - one\n      more\"", &diag)) {
        .complete => |complete| complete,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer parsed.deinit();
    var context: u8 = 0;
    const normalized = try doc_text.normalize(allocator, parsed.forms[0], .{
        .context = &context,
        .poll_fn = noPoll,
    });
    defer heap.releaseValue(allocator, normalized);
    const rendered = try printer.toOwnedString(allocator, normalized);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("\"a b\\n\\n- one more\"", rendered);
}

test "documentation normalization polls every indentation and blank-line pass" {
    const padded = try allocator.alloc(u32, 70_001);
    defer allocator.free(padded);
    @memset(padded, ' ');
    padded[35_000] = 'x';
    const padded_line = try list.fromCodepoints(allocator, padded);
    defer heap.releaseValue(allocator, padded_line);
    // countLines and collectLines finish first; this stop lands in the
    // trailing indentation scan after the leading scan has also completed.
    var indentation_stop = PollStop{ .fail_at = 200_000 };
    try std.testing.expectError(
        error.Ecl,
        doc_text.normalize(allocator, padded_line, indentation_stop.poller()),
    );
    try std.testing.expectEqual(indentation_stop.fail_at, indentation_stop.calls);

    const breaks = try allocator.alloc(u32, 70_000);
    defer allocator.free(breaks);
    @memset(breaks, '\n');
    const blank_lines = try list.fromCodepoints(allocator, breaks);
    defer heap.releaseValue(allocator, blank_lines);
    var bounds_stop = PollStop{ .fail_at = 180_000 };
    try std.testing.expectError(
        error.Ecl,
        doc_text.normalize(allocator, blank_lines, bounds_stop.poller()),
    );
    try std.testing.expectEqual(bounds_stop.fail_at, bounds_stop.calls);
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
    const formatted = try formatter.format(allocator, source);
    defer allocator.free(formatted);
    var original_diag: reader.Diag = .{};
    var formatted_diag: reader.Diag = .{};
    var original = switch (try reader.read(allocator, "original.ecl", source, &original_diag)) {
        .complete => |parsed| parsed,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer original.deinit();
    var reparsed = switch (try reader.read(allocator, "formatted.ecl", formatted, &formatted_diag)) {
        .complete => |parsed| parsed,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer reparsed.deinit();
    try std.testing.expectEqual(original.forms.len, reparsed.forms.len);
    for (original.forms, reparsed.forms) |before, after| {
        try std.testing.expect(try equal.matchWithAllocator(allocator, before, after));
    }
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
    try expectFormat("(\n foo\n)", "(\n foo\n )\n");
    try expectFormat("(| x y | x y)", "(|x y| x y)\n");
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

test "comments break only their local structural run" {
    const source = "(dup type 'list match (# nested comment\n dup len dup 0 > swap 2 mod 1 = and) if)";
    try expectFormat(
        source,
        "(dup type 'list match\n" ++
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
        "# def stale\n" ++
        "# public details\n" ++
        "(1)\n(-- n)\n'public def\n\n\n" ++
        "# def stale-private\n" ++
        "(2)\n[-- n]\n'private defp\n" ++
        "### overview\n" ++
        "\"ab\" 'letters def\n";
    try expectFormat(
        source,
        "# ordinary lead\n\n" ++
            "### def public\n" ++
            "# public details\n" ++
            "(1)\n(-- n)\n'public def\n\n" ++
            "### def private\n" ++
            "(2)\n[-- n]\n'private defp\n" ++
            "### overview\n\n" ++
            "### def letters\n" ++
            "\"ab\" 'letters def\n",
    );
    try expectParseEquivalent(source);

    const nested =
        "'m (\n" ++
        "(1)\n(-- n)\n'visible def\n" ++
        "# note\n# def stale\n# hidden details\n" ++
        "(2)\n(-- n)\n'hidden defp\n" ++
        ") module\n";
    try expectFormat(
        nested,
        "'m\n" ++
            "(\n" ++
            " ### def visible\n" ++
            " (1)\n (-- n)\n 'visible def\n # note\n\n" ++
            " ### def hidden\n" ++
            " # hidden details\n" ++
            " (2)\n (-- n)\n 'hidden defp\n )\n" ++
            "module\n",
    );
    try expectParseEquivalent(nested);

    const nested_synthesized =
        "'m (\n" ++
        "# attached inside the module\n" ++
        "(3)\n(-- n)\n'generated def\n" ++
        ") module\n";
    try expectFormat(
        nested_synthesized,
        "'m\n" ++
            "(\n" ++
            " ### def generated\n" ++
            " # attached inside the module\n" ++
            " (3)\n (-- n)\n 'generated def\n" ++
            " )\n" ++
            "module\n",
    );
    try expectParseEquivalent(nested_synthesized);

    const synthesized =
        "# attached details\n" ++
        "# remain with the definition\n" ++
        "(3)\n(-- n)\n'generated def\n";
    try expectFormat(
        synthesized,
        "### def generated\n" ++
            "# attached details\n" ++
            "# remain with the definition\n" ++
            "(3)\n(-- n)\n'generated def\n",
    );
    try expectParseEquivalent(synthesized);

    const inert_dict = "{(1) (-- n) 'not-a-definition def}";
    try expectFormat(inert_dict, inert_dict ++ "\n");
    try expectParseEquivalent(inert_dict);
}

test "formatter reflows only structurally recognized documentation" {
    const source =
        "### def explain\n" ++
        "(dup)\n" ++
        "(value -- value : \"This documentation contains enough ordinary prose to exceed the configured " ++
        "width and therefore needs to flow across several lines at clean word boundaries.\")\n" ++
        "'explain def\n";
    const expected =
        "### def explain\n" ++
        "(dup)\n" ++
        "(value -- value :\n" ++
        " \"This documentation contains enough ordinary prose to exceed the configured width and therefore\n" ++
        "  needs to flow across several lines at clean word boundaries.\")\n" ++
        "'explain def\n";
    try expectFormat(source, expected);

    const square_source =
        "(dup)\n" ++
        "[value -- value : \"This square-delimited annotation contains enough ordinary prose to exceed " ++
        "the configured width and must retain its original delimiters when reflowed.\"]\n" ++
        "'square-doc def\n";
    const square_expected =
        "### def square-doc\n" ++
        "(dup)\n" ++
        "[value -- value :\n" ++
        " \"This square-delimited annotation contains enough ordinary prose to exceed the configured width and\n" ++
        "  must retain its original delimiters when reflowed.\"]\n" ++
        "'square-doc def\n";
    try expectFormat(square_source, square_expected);

    const ordinary = "(\"This ordinary string is deliberately kept byte-for-byte, even when it is much longer " ++
        "than the target formatting width and contains   repeated spaces.\")";
    try expectFormat(ordinary, ordinary ++ "\n");
}

test "doc-only prose keeps its prefix and preserves paragraphs and bullets" {
    const source =
        "(1)\n" ++
        "(: \"  First prose line that continues softly across\n" ++
        "      physical source lines and is long enough to need canonical wrapping in the formatter output.\n\n" ++
        "      - One bullet whose continuation is also folded into the same logical bullet item.\n" ++
        "        More words for that item.\n" ++
        "      - Two.\")\n" ++
        "'documented def\n";
    const formatted = try formatter.format(allocator, source);
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.startsWith(u8, formatted, "### def documented\n(1)\n(: \"First prose line"));
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
        "(dup) (value -- value : \"Documentation that exercises normalized prose.\") 'x def",
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
