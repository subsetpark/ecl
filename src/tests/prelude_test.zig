const std = @import("std");
const support = @import("kernel_test_support.zig");
const prelude = @import("../prelude.zig");
const prims = @import("../prims.zig");
const env = @import("../env.zig");
const modules = @import("../modules.zig");
const spans = @import("../spans.zig");
const intern = @import("../intern.zig");
const heap = @import("../heap.zig");

test "embedded prelude exposes source bodies and derived dataflow" {
    try support.expectStacks(&.{
        .{
            .name = "source bodies",
            .source = "'wrap body 'literal body 'partial body 'pair body 'sort body 'pack body",
            .expected = "(() cons) (wrap (first) cons) (swap literal swap compose) (() cons cons) (dup grade at) (() swap (cons) times)",
        },
        .{ .name = "pack", .source = "1 2 3 4 4 pack", .expected = "[1 2 3 4]" },
        .{ .name = "partition", .source = "[1 2 3 4] (2 >) partition", .expected = "[3 4] [1 2]" },
        .{ .name = "aggregates", .source = "[3 1 2] min-of [3 1 2] max-of [1 2 3] sum [1 2 3] prod", .expected = "1 3 6 6" },
        .{
            .name = "at-or",
            .source = "{'a 1} 'a 9 at-or {'a 1} 'b 9 at-or {'a foo} 'a 9 at-or {} 'a (bar) first at-or",
            .expected = "1 9 foo bar",
        },
        .{ .name = "find", .source = "[2 3 2] 3 find [2 3 2] 9 find (foo) dup first find", .expected = "1 3 0" },
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
        .{ .name = "outcomes", .source = "(2 3 +) attempt ok? (2 3 +) attempt or-raise (missing) attempt 9 or-else", .expected = "1 [5] 9" },
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
            .expected = "3 [7] [7 8] [1 2 3] [1 2 3] 1 [2 3] [1 2] 3 " ++
                "1 0 ([1 3] [2 4]) [1 2 3]",
        },
        .{
            .name = "selection and aggregation",
            .source = "{'a 1 'b 2} pairs [1 2 3 4] (2 >) filter [0 0 1] (0 >) any? " ++
                "[1 1 0] (0 >) all? [1 2 3] mean",
            .expected = "(('a 1) ('b 2)) [3 4] 1 0 2.0",
        },
    });
}

test "all embedded vocabulary entries expose bodies and nonempty documentation" {
    const names = [_][]const u8{
        "nip",    "keep",     "bi",       "tri",     "bi2",       "both",
        "when",   "unless",   "case",     "signum",  "clamp",     "last",
        "wrap",   "literal",  "partial",  "pair",    "pack",      "append",
        "uncons", "unappend", "empty?",   "zip",     "min-of",    "max-of",
        "sort",   "at-or",    "pairs",    "filter",  "partition", "any?",
        "all?",   "sum",      "prod",     "mean",    "print",     "inspect",
        "fail",   "ok?",      "or-raise", "or-else", "find",
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
    try building.installCore(try intern.trustedNamespace("still-writable"), .{ .value = .{ .int = 1 } });
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
        .{ .name = "lines deferred", .source = "lines", .kind = "undefined-word", .word = "lines" },
        .{ .name = "slurp deferred", .source = "slurp", .kind = "undefined-word", .word = "slurp" },
        .{ .name = "spit deferred", .source = "spit", .kind = "undefined-word", .word = "spit" },
        .{ .name = "getenv deferred", .source = "getenv", .kind = "undefined-word", .word = "getenv" },
        .{ .name = "or-raise identity", .source = "(missing) attempt or-raise", .kind = "undefined-word", .word = "missing" },
        .{
            .name = "cons inserts executable word forms",
            .source = "(foo) first (7) cons call",
            .kind = "undefined-word",
            .word = "foo",
        },
        .{ .name = "case shape", .source = "1 [] case", .kind = "shape" },
        .{ .name = "case type", .source = "1 2 case", .kind = "type" },
        .{ .name = "at-or propagates type", .source = "1 0 9 at-or", .kind = "type", .word = "has?" },
        .{ .name = "pack negative", .source = "1 -1 pack", .kind = "domain", .word = "times" },
        .{ .name = "pack type", .source = "1 1.0 pack", .kind = "type", .word = "times" },
        .{ .name = "pack underflow", .source = "1 2 pack", .kind = "underflow", .word = "cons" },
    });
}

test "embedded definitions resolve their dependencies late" {
    try support.expectStack("(pop pop 42) 'cons def 1 wrap", "42");
}
