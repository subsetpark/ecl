const std = @import("std");
const support = @import("kernel_test_support.zig");
const prelude = @import("../prelude.zig");
const prims = @import("../prims.zig");
const env = @import("../env.zig");
const modules = @import("../modules.zig");
const spans = @import("../spans.zig");
const intern = @import("../intern.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");

test "embedded prelude exposes source bodies and derived dataflow" {
    try support.expectStacks(&.{
        .{
            .name = "source bodies",
            .source = "'wrap body 'literal body 'partial body 'pair body 'sort body 'pack body",
            .expected = "(() cons) (wrap (first) cons) (swap literal swap compose) (() cons cons) (dup grade at) (() swap (cons) times)",
        },
        .{ .name = "pack", .source = "1 2 3 4 4 pack", .expected = "[1 2 3 4]" },
        .{
            .name = "migrated stack and quotation words",
            .source = "1 2 over (1) (2) compose call 4 7 (1 +) dip 42 str",
            .expected = "1 2 1 1 2 5 7 \"42\"",
        },
        .{
            .name = "migrated numeric words",
            .source = "7 3 mod -2 neg -2 abs 2 3 <> 2 2 <> 2 3 <= 3 2 <= " ++
                "3 2 >= 2 3 >= 1 0 and 1 0 or",
            .expected = "1 2 2 1 0 1 0 1 0 0 1",
        },
        .{
            .name = "migrated sequence and dictionary words",
            .source = "[1 2 3] first [1 2 3] rest [1 2 3] reverse " ++
                "[1 2 1 3 2] distinct {'a 1 'b 2} vals",
            .expected = "1 [2 3] [3 2 1] [1 2 3] [1 2]",
        },
        .{ .name = "partition", .source = "[1 2 3 4] (2 >) partition", .expected = "[3 4] [1 2]" },
        .{ .name = "aggregates", .source = "[3 1 2] min-of [3 1 2] max-of [1 2 3] sum [1 2 3] prod", .expected = "1 3 6 6" },
        .{
            .name = "at-or",
            .source = "{'a 1} 'a 9 at-or {'a 1} 'b 9 at-or {'a foo} 'a 9 at-or {} 'a (bar) first at-or",
            .expected = "1 9 foo bar",
        },
        .{ .name = "find", .source = "[2 3 2] 3 find [2 3 2] 9 find (foo) dup first find", .expected = "1 3 0" },
        .{
            .name = "at-path",
            .source = "[[10 20] [30 40]] [1 0] at-path " ++
                "{'users ({'name \"Ada\"} {'name \"Lin\"})} ['users 1 'name] at-path " ++
                "42 [] at-path",
            .expected = "30 \"Lin\" 42",
        },
        .{
            .name = "literal values",
            .source = "(foo) first literal call 42 literal call [1 2] literal call",
            .expected = "foo 42 [1 2]",
        },
        .{
            .name = "literal representation",
            .source = "(foo) first literal dup type",
            .expected = "((foo) first) 'list",
        },
        .{
            .name = "partial application",
            .source = "3 (2 *) partial call (foo) first (type) partial call",
            .expected = "6 'word",
        },
        .{
            .name = "quotation with initial values",
            .source = "[2 3] (+) with call (type) first 7 2 pack (pop type) with call",
            .expected = "5 'word",
        },
        .{
            .name = "seeded attempts tasks and modules",
            .source = "[] (42) with @attempt [2 3] (+) with @attempt " ++
                "[2 3] (+) with @spawn await [2 0] (/) with @attempt result.ok? " ++
                "[2 3] (+) with @attempt [2 3] (+) with @spawn await match? " ++
                "[4 5] (+ 'sum set) with 'seeded @defm seeded.sum",
            .expected = "{'ok [42]} {'ok [5]} {'ok [5]} 0 1 9",
        },
        .{ .name = "results", .source = "(2 3 +) @attempt result.ok? (2 3 +) @attempt result.or-raise (missing) @attempt 9 result.or-else", .expected = "1 [5] 9" },
        .{
            .name = "cleaves",
            .source = "1 2 nip 3 (1 +) keep 3 (1 +) (2 *) bi 3 (1 +) (2 *) (1 -) tri " ++
                "2 3 (+) (*) bi2 2 3 (1 +) both",
            .expected = "2 4 3 4 6 4 6 2 5 6 3 4",
        },
        .{
            .name = "derived control and scalar",
            .source = "1 (7) when 0 (8) when 0 (9) unless 1 (10) unless " ++
                "3 [1 (10) 3 (30) (90)] case (foo) first [foo (70) (90)] case " ++
                "-5 signum 0 signum 3 signum 5 1 4 clamp",
            .expected = "7 9 30 70 -1 0 1 4",
        },
        .{
            .name = "sequence construction",
            .source = "[1 2 3] last 7 wrap 7 8 pair 1 2 3 3 pack [1 2] 3 append " ++
                "[1 2 3] uncons [1 2 3] unappend [] empty? [1] empty? " ++
                "[1 2] [3 4] zip [3 1 2] sort",
            .expected = "                                                ([1 3]\n" ++
                "3 [7] [7 8] [1 2 3] [1 2 3] 1 [2 3] [1 2] 3 1 0  [2 4]) [1 2 3]",
        },
        .{
            .name = "selection and aggregation",
            .source = "{'a 1 'b 2} pairs [1 2 3 4] (2 >) filter [0 0 1] (0 >) any? " ++
                "[1 1 0] (0 >) all? [1 2 3] mean",
            .expected = "(('a 1) ('b 2)) [3 4] 1 0 2.0",
        },
        .{
            .name = "exact dictionary keys",
            .source = "{'a 1 'b 2} ['b 'a] keys-exactly? " ++
                "{'a 1} ['a 'b] keys-exactly? {'a 1 'b 2} ['a] keys-exactly? " ++
                "{'a 1 'b 2} ['a 'a] keys-exactly?",
            .expected = "1 0 0 0",
        },
        .{
            .name = "lexicographic comparison",
            .source = "[1 2] [1 3] (cmp) lex-cmp [1 3] [1 2] (cmp) lex-cmp " ++
                "[1] [1 0] (cmp) lex-cmp [1 0] [1] (cmp) lex-cmp [] [] (cmp) lex-cmp",
            .expected = "-1 1 -1 1 0",
        },
        .{
            .name = "lexicographic comparison stops at the first difference",
            .source = "0 'lex-calls set [1 2 3] [9 0 0] " ++
                "(lex-calls 1 + 'lex-calls set cmp) lex-cmp lex-calls",
            .expected = "-1 1",
        },
        .{
            .name = "cyclic rotation",
            .source = "[10 20 30 40] 1 rotate [10 20 30 40] -1 rotate " ++
                "[10 20 30 40] 6 rotate [] 3 rotate \"hello\" 2 rotate [1 2 3] 0 rotate",
            .expected = "[20 30 40 10] [40 10 20 30] [30 40 10 20] () \"llohe\" [1 2 3]",
        },
        .{
            .name = "derived adverb combinators",
            .source = "\"abcdef\" 3 windows [12 13 11 17 14] 10 (-) each-prior " ++
                "[] 9 (+) each-prior [1 2 3] (+) fold1 [7] (+) fold1 " ++
                "[1 2 3] (+) scan1 [7] (+) scan1 1 5 (2 *) iterations 1 0 (2 *) iterations",
            .expected = "(\"abc\" \"bcd\" \"cde\" \"def\") [2 1 -2 6 -3] () 6 7 [1 3 6] [7] [1 2 4 8 16 32] [1]",
        },
        .{
            .name = "state iteration combinators",
            .source = "3 (0 >) (1 -) while-values 100 (2 div) converges " ++
                "100 (2 div) converge 0 (1 + 3 mod) converges 1 (0 +) converges",
            .expected = "[3 2 1 0] [100 50 25 12 6 3 1 0] 0 [0 1 2] [1]",
        },
    });
}

test "all embedded vocabulary entries expose bodies and nonempty documentation" {
    const names = [_][]const u8{
        "compose",      "first",     "wrap",          "literal", "dip",      "over",
        "partial",      "with",      "mod",           "neg",     "abs",      "<>",
        "<=",           ">=",        "and",           "or",      "nip",      "keep",
        "bi",           "tri",       "bi2",           "both",    "when",     "unless",
        "case",         "signum",    "clamp",         "last",    "pair",     "pack",
        "append",       "rest",      "reverse",       "uncons",  "unappend", "empty?",
        "zip",          "lex-cmp",   "min-of",        "max-of",  "sort",     "distinct",
        "at-path",      "vals",      "keys-exactly?", "at-or",   "pairs",    "filter",
        "partition",    "any?",      "all?",          "sum",     "prod",     "mean",
        "fail",         "find",      "await-all",     "set",     "setp",     "assert",
        "rotate",       "windows",   "each-prior",    "fold1",   "scan1",    "iterations",
        "while-values", "converges", "converge",
    };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'{s} body type '{s} doc len 0 >",
            .{ name, name },
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "'list 1");
    }
}

fn expectInvalidPrelude(source: []const u8) !void {
    const allocator = std.testing.allocator;
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer environment.deinit();
    var building = environment.beginCoreBuild();
    try prims.install(&building);
    var registry = try modules.Registry.init(host.cleanup());
    defer registry.deinit();
    var archive = try spans.SpanArchive.init(host.cleanup());
    defer archive.deinit();
    var cancelled: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.InvalidPrelude, prelude.installSource(
        host.cleanup(),
        &building,
        &registry,
        &archive,
        &cancelled,
        "invalid-prelude.ecl",
        source,
    ));
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 1 }});
    defer heap.hostDomain(host.cleanup()).releaseValue(body);
    try building.installCore(
        try intern.internNamespace("still-writable"),
        .{ .word = env.quotation(body.list).? },
    );
}

test "bootstrap rejects malformed failing and unbalanced source" {
    try expectInvalidPrelude("(");
    try expectInvalidPrelude("missing");
    try expectInvalidPrelude("1");
}

test "embedded definitions retain provenance and deferred words stay absent" {
    try support.expectErrors(&.{
        .{
            .name = "prelude provenance",
            .source = "\"boom\" fail",
            .kind = "user",
            .word = "raise",
            .data = &.{.{ .name = "source", .expected = .{ .string = "prelude.ecl" } }},
        },
        .{ .name = "pp moved to io", .source = "1 pp", .kind = "undefined-word", .word = "pp" },
        .{ .name = "print moved to io", .source = "\"x\" print", .kind = "undefined-word", .word = "print" },
        .{ .name = "inspect moved to io", .source = "1 inspect", .kind = "undefined-word", .word = "inspect" },
        .{ .name = "lines moved to io", .source = "\"x\" lines", .kind = "undefined-word", .word = "lines" },
        .{ .name = "prin moved to io", .source = "\"x\" prin", .kind = "undefined-word", .word = "prin" },
        .{ .name = "slurp moved to io", .source = "slurp", .kind = "undefined-word", .word = "slurp" },
        .{ .name = "spit moved to io", .source = "spit", .kind = "undefined-word", .word = "spit" },
        .{ .name = "getenv needs a name", .source = "getenv", .kind = "underflow", .word = "getenv" },
        .{
            .name = "stdin moved to io",
            .source = "stdin",
            .kind = "undefined-word",
            .word = "stdin",
        },
        .{ .name = "result.or-raise identity", .source = "(missing) @attempt result.or-raise", .kind = "undefined-word", .word = "missing" },
        .{
            .name = "cons inserts executable word forms",
            .source = "(foo) first (7) cons call",
            .kind = "undefined-word",
            .word = "foo",
        },
        .{ .name = "case shape", .source = "1 [] case", .kind = "shape" },
        .{ .name = "case type", .source = "1 2 case", .kind = "type" },
        .{ .name = "at-or propagates type", .source = "1 0 9 at-or", .kind = "type", .word = "has?" },
        .{ .name = "at-path propagates lookup failure", .source = "{'a [1]} ['a 4] at-path", .kind = "domain", .word = "at" },
        .{ .name = "pack negative", .source = "1 -1 pack", .kind = "domain", .word = "times" },
        .{ .name = "pack type", .source = "1 1.0 pack", .kind = "type", .word = "times" },
        .{ .name = "pack underflow", .source = "1 2 pack", .kind = "underflow", .word = "cons" },
    });
}

test "embedded definitions resolve their dependencies late" {
    try support.expectStack("(pop pop 42) 'cons def 1 wrap", "42");
}
