//! Kind conversions: `chars`, `bytes`, `symbol`, `intern`, `int`, `float`,
//! and `char`, plus the interning invariant they exist to protect. Every case
//! runs whole source strings through a public Session and compares the
//! printed stack or the printed error, so nothing here depends on how a
//! string or byte list happens to be stored.
const std = @import("std");
const session = @import("../session.zig");
const printer = @import("../print.zig");

const allocator = std.testing.allocator;

fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    switch (try runtime.runUnit("<conversion-test>", source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer runtime.release(failure);
            const rendered = try printer.toOwnedString(allocator, failure);
            defer allocator.free(rendered);
            std.debug.print("unexpected failure for `{s}`: {s}\n", .{ source, rendered });
            return error.TestUnexpectedResult;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
    try clearStack(runtime);
}

fn expectError(runtime: *session.Session, source: []const u8, fragments: []const []const u8) !void {
    switch (try runtime.runUnit("<conversion-test>", source)) {
        .ok => {
            std.debug.print("expected `{s}` to fail\n", .{source});
            try clearStack(runtime);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer runtime.release(failure);
            const rendered = try printer.toOwnedString(allocator, failure);
            defer allocator.free(rendered);
            for (fragments) |fragment| {
                if (std.mem.indexOf(u8, rendered, fragment) == null) {
                    std.debug.print("`{s}` failed with {s}\nmissing fragment: {s}\n", .{ source, rendered, fragment });
                    return error.TestUnexpectedResult;
                }
            }
        },
    }
    try clearStack(runtime);
}

fn clearStack(runtime: *session.Session) !void {
    while (runtime.stackItems().len != 0) {
        switch (try runtime.runUnit("<conversion-clear>", "pop")) {
            .ok => {},
            .err => |failure| {
                runtime.release(failure);
                return error.TestUnexpectedResult;
            },
            .incomplete => return error.TestUnexpectedResult,
        }
    }
}

test "conversion: chars yields text content for every documented source kind" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "\"hi\" chars", "\"hi\"");
    try expectStack(&runtime, "\"\" chars", "\"\"");
    try expectStack(&runtime, "'foo.bar chars", "\"foo.bar\"");
    try expectStack(&runtime, "(dup) first chars", "\"dup\"");
    try expectStack(&runtime, "\\λ chars", "\"λ\"");
    try expectStack(&runtime, "[104 195 169] chars", "\"hé\"");
    // Idempotent on its own output, and the inverse of `bytes`.
    try expectStack(&runtime, "\"aλ\" bytes chars", "\"aλ\"");
    try expectStack(&runtime, "'sym chars chars", "\"sym\"");
    // `str` is representation; `chars` is content.
    try expectStack(&runtime, "'foo str 'foo chars", "\"'foo\" \"foo\"");
}

test "conversion: chars rejects non-UTF-8 bytes with a reason and other kinds by type" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectError(&runtime, "[255] chars", &.{ "'kind 'domain", "'reason 'invalid-utf8" });
    try expectError(&runtime, "[195] chars", &.{ "'kind 'domain", "'reason 'invalid-utf8" });
    try expectError(&runtime, "[1 \"x\"] chars", &.{"'kind 'type"});
    try expectError(&runtime, "[256] chars", &.{"'kind 'type"});
    try expectError(&runtime, "[-1] chars", &.{"'kind 'type"});
    try expectError(&runtime, "5 chars", &.{"'kind 'type"});
    try expectError(&runtime, "{} chars", &.{"'kind 'type"});
    // A failed conversion is transactional: the operand is still there.
    try expectStack(&runtime, "1 [255] (chars) @attempt result.err? pop", "1");
}

test "conversion: bytes encodes strings and passes byte lists through" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "\"hé\" bytes", "[104 195 169]");
    try expectStack(&runtime, "\"\" bytes len", "0");
    try expectStack(&runtime, "[104 105] bytes", "[104 105]");
    try expectStack(&runtime, "[104 105] bytes bytes chars", "\"hi\"");
    try expectStack(&runtime, "\"λ\" bytes len", "2");
    try expectError(&runtime, "[300] bytes", &.{"'kind 'type"});
    try expectError(&runtime, "[1 'a] bytes", &.{"'kind 'type"});
    try expectError(&runtime, "'sym bytes", &.{"'kind 'type"});
    try expectError(&runtime, "7 bytes", &.{"'kind 'type"});
}

test "conversion: symbol is lookup-only and intern is the one word that creates" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "'x symbol", "'x");
    try expectStack(&runtime, "(dup) first symbol", "'dup");
    // Reading this very source interned `already-here`, so lookup succeeds.
    try expectStack(&runtime, "'already-here pop \"already-here\" symbol", "'already-here");
    try expectStack(&runtime, "\"dup\" symbol 'dup match?", "1");
    // A spelling no source has read is absent until `intern` creates it.
    try expectError(&runtime, "\"conversion-test-fresh-4d1e\" symbol", &.{ "'kind 'domain", "not interned" });
    try expectStack(&runtime, "\"conversion-test-fresh-4d1e\" intern type", "'symbol");
    try expectStack(&runtime, "\"conversion-test-fresh-4d1e\" symbol chars", "\"conversion-test-fresh-4d1e\"");
    try expectStack(&runtime, "\"conversion-test-fresh-4d1e\" intern \"conversion-test-fresh-4d1e\" symbol match?", "1");
    // Both words accept the whole quoted-symbol grammar and nothing else.
    try expectStack(&runtime, "\"a.b\" intern \"42\" intern \"--\" intern", "'a.b '42 '--");
    try expectError(&runtime, "\"\" symbol", &.{ "'kind 'domain", "valid symbol spelling" });
    try expectError(&runtime, "\"a b\" intern", &.{ "'kind 'domain", "valid symbol spelling" });
    try expectError(&runtime, "\"'quoted\" intern", &.{ "'kind 'domain", "valid symbol spelling" });
    try expectError(&runtime, "\"a..b\" intern", &.{ "'kind 'domain", "valid symbol spelling" });
    try expectError(&runtime, "\"trailing.\" intern", &.{ "'kind 'domain", "valid symbol spelling" });
    try expectError(&runtime, "42 symbol", &.{"'kind 'type"});
    try expectError(&runtime, "[1 2] intern", &.{"'kind 'type"});
}

test "conversion: data-facing words never intern their input" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    // `symbol` is the oracle: a spelling is interned exactly when lookup
    // succeeds. Feeding a spelling through JSON, CSV, and string words must
    // leave it absent; only `intern` and reading source may add it.
    try expectError(&runtime, "\"conv-json-key-91\" symbol", &.{"'kind 'domain"});
    try expectStack(&runtime, "\"{\\\"conv-json-key-91\\\": 1}\" json.parse dict.keys first", "\"conv-json-key-91\"");
    try expectError(&runtime, "\"conv-json-key-91\" symbol", &.{"'kind 'domain"});
    try expectStack(&runtime, "\"conv-csv-h1\\n1\" csv.parse first first", "\"conv-csv-h1\"");
    try expectError(&runtime, "\"conv-csv-h1\" symbol", &.{"'kind 'domain"});
    try expectStack(&runtime, "\"conv-str-92\" str.upper str.lower \"-\" split len", "3");
    try expectError(&runtime, "\"conv-str-92\" symbol", &.{"'kind 'domain"});
    try expectStack(&runtime, "\"conv-json-key-91\" intern chars", "\"conv-json-key-91\"");
}

test "conversion: int accepts ints, chars, and integer literals only" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "7 int", "7");
    try expectStack(&runtime, "\\a int", "97");
    try expectStack(&runtime, "\\λ int", "955");
    try expectStack(&runtime, "\"42\" int \"-3\" int \"0x10\" int", "42 -3 16");
    try expectStack(&runtime, "\"9223372036854775807\" int", "9223372036854775807");
    try expectError(&runtime, "\"9223372036854775808\" int", &.{"'kind 'overflow"});
    try expectError(&runtime, "\"3.5\" int", &.{ "'kind 'parse", "integer literal" });
    try expectError(&runtime, "\"1 2\" int", &.{"'kind 'parse"});
    try expectError(&runtime, "\"\" int", &.{"'kind 'parse"});
    try expectError(&runtime, "\"λ\" int", &.{"'kind 'parse"});
    try expectError(&runtime, "3.5 int", &.{ "'kind 'type", "floor, round, or ceil" });
    try expectError(&runtime, "'x int", &.{"'kind 'type"});
    try expectError(&runtime, "[1] int", &.{"'kind 'type"});
    // A char's codepoint round-trips through `char`.
    try expectStack(&runtime, "\\λ int char", "\\λ");
}

test "conversion: float accepts floats, ints, and numeric literals only" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "2.5 float", "2.5");
    try expectStack(&runtime, "3 float", "3.0");
    try expectStack(&runtime, "\"2.5e1\" float \"7\" float", "25.0 7.0");
    try expectError(&runtime, "\"abc\" float", &.{ "'kind 'parse", "numeric literal" });
    try expectError(&runtime, "\"\" float", &.{"'kind 'parse"});
    try expectError(&runtime, "\\a float", &.{"'kind 'type"});
    try expectError(&runtime, "'x float", &.{"'kind 'type"});
}

test "conversion: char accepts chars, scalar ints, and one-char strings only" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "\\a char", "\\a");
    try expectStack(&runtime, "97 char 955 char 0 char int", "\\a \\λ 0");
    try expectStack(&runtime, "1114111 char int", "1114111");
    try expectStack(&runtime, "\"λ\" char", "\\λ");
    try expectError(&runtime, "1114112 char", &.{ "'kind 'domain", "Unicode scalar" });
    try expectError(&runtime, "55296 char", &.{ "'kind 'domain", "Unicode scalar" });
    try expectError(&runtime, "57343 char", &.{ "'kind 'domain", "Unicode scalar" });
    try expectError(&runtime, "-1 char", &.{ "'kind 'domain", "Unicode scalar" });
    try expectError(&runtime, "\"\" char", &.{ "'kind 'domain", "one-char" });
    try expectError(&runtime, "\"ab\" char", &.{ "'kind 'domain", "one-char" });
    try expectError(&runtime, "2.0 char", &.{"'kind 'type"});
    try expectError(&runtime, "'x char", &.{"'kind 'type"});
    try expectError(&runtime, "[97] char", &.{"'kind 'type"});
}

test "conversion: every conversion word reports its own name and underflows cleanly" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const words = [_][]const u8{ "chars", "bytes", "symbol", "intern", "int", "float", "char" };
    for (words) |word| {
        var buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "'word '{s}", .{word});
        try expectError(&runtime, word, &.{ "'kind 'underflow", expected });
    }
}
