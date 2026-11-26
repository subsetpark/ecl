//! Flattened code lists, observed through a Session: what they compute, how
//! they fail, and where they report it. Every program runs its phrases
//! inside a quotation or a word, since only a list a fiber enters is
//! flattened. Expected values were taken from a build that does not flatten.
const std = @import("std");
const runtime_fixture = @import("runtime_fixture.zig");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");
const printer = @import("../print.zig");
const support = @import("kernel_test_support.zig");

const Failure = struct { source: []const u8, expected: []const u8 };

/// Runs each program in a Session of its own and compares the whole failure
/// it ends in, so the word, the position, the trace and the sites are all
/// held to what the unflattened program reports.
fn expectFailures(cases: []const Failure) !void {
    const allocator = std.testing.allocator;
    for (cases) |case| {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var inputs = try runtime_fixture.Fixture.init();
        defer inputs.deinit();
        var runtime = try session.Session.init(heap.allocator(), &.{}, inputs.inputs(.{}), .default, .evaluate);
        defer runtime.deinit();
        const failure = switch (try runtime.runUnit("<command>", case.source)) {
            .err => |item| item,
            .ok, .incomplete => {
                std.log.err("expected a failure from: {s}", .{case.source});
                return error.TestUnexpectedResult;
            },
        };
        defer runtime.release(failure);
        const rendered = try printer.toOwnedString(allocator, failure);
        defer allocator.free(rendered);
        std.testing.expectEqualStrings(case.expected, rendered) catch |err| {
            std.log.err("failure differs for: {s}", .{case.source});
            return err;
        };
    }
}

test "flatten: apply and dip over literals compute what the words do" {
    try support.expectStacks(&.{
        .{ .name = "(3 (1 +) apply) apply", .source = "(3 (1 +) apply) apply", .expected = "4" },
        .{ .name = "2 (3 4 (1 +) dip) times", .source = "2 (3 4 (1 +) dip) times", .expected = "4 4 4 4" },
        .{ .name = "(1 ((2 (3 +) apply) apply) dip) apply", .source = "(1 ((2 (3 +) apply) apply) dip) apply", .expected = "5 1" },
        .{ .name = "(1 2 (swap) apply (pop) dip) apply", .source = "(1 2 (swap) apply (pop) dip) apply", .expected = "1" },
        .{ .name = "((1 2) apply (3) dip) apply", .source = "((1 2) apply (3) dip) apply", .expected = "1 3 2" },
        .{ .name = "(1 [2 3] apply) apply", .source = "(1 [2 3] apply) apply", .expected = "1 2 3" },
        .{ .name = "(1 2 (|a b| a b +) apply) apply", .source = "(1 2 (|a b| a b +) apply) apply", .expected = "3" },
        .{ .name = "(1 2 3 (|a b| a b -) dip) apply", .source = "(1 2 3 (|a b| a b -) dip) apply", .expected = "-1 3" },
        .{ .name = "(() apply 1 () dip) apply", .source = "(() apply 1 () dip) apply", .expected = "1" },
        .{ .name = "(5 6 (dup 0 > (1 -) (1 +) if) dip) apply", .source = "(5 6 (dup 0 > (1 -) (1 +) if) dip) apply", .expected = "4 6" },
        .{ .name = "(1 2 (+) (apply) apply) apply", .source = "(1 2 (+) (apply) apply) apply", .expected = "3" },
        .{ .name = "(3 4 ((1 +) apply) dip) `w def w w", .source = "(3 4 ((1 +) apply) dip) `w def w w", .expected = "4 4 4 4" },
        .{ .name = "([1 2 3] (dup (1 +) dip +) each) apply", .source = "([1 2 3] (dup (1 +) dip +) each) apply", .expected = "[3 5 7]" },
        .{ .name = "(1 (2 (3 (4 (5 +) apply +) apply +) apply +) apply) apply", .source = "(1 (2 (3 (4 (5 +) apply +) apply +) apply +) apply) apply", .expected = "15" },
        .{ .name = "(5 ((1 +) apply) below 6 ((1 +) dip) above) apply", .source = "(5 ((1 +) apply) below 6 ((1 +) dip) above) apply", .expected = "5 7 6 6 6" },
    });
}

test "flatten: a failure inside a flattened quotation reports the quotation and position" {
    try expectFailures(&.{
        .{ .source = "(1 2 (len) dip) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "(1 (len) apply 5) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 5 sites ({source \"<command>\" line 1 col 5})}}" },
        .{ .source = "((1 +) dip) apply", .expected = "{kind underflow msg \"dip needs 1 stack value, but found 0\" word dip trace (`dip) data {needed 1 available 0 source \"<command>\" line 1 col 8 sites ({source \"<command>\" line 1 col 8})}}" },
        .{ .source = "(5 (1 +) dip) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 1\" word + trace (`+) data {needed 2 available 1 source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "(1 2 (pop pop pop) apply) apply", .expected = "{kind underflow msg \"pop needs 1 stack value, but found 0\" word pop trace (`pop) data {needed 1 available 0 source \"<command>\" line 1 col 15 sites ({source \"<command>\" line 1 col 15})}}" },
        .{ .source = "(1 (2 0 div) apply) apply", .expected = "{kind domain msg \"kernel arithmetic is outside its domain\" word div trace (`div) data {source \"<command>\" line 1 col 9 sites ({source \"<command>\" line 1 col 9})}}" },
        .{ .source = "(1 (\"a\" +) dip 2) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 1\" word + trace (`+) data {needed 2 available 1 source \"<command>\" line 1 col 9 sites ({source \"<command>\" line 1 col 9})}}" },
        .{ .source = "(1 (nope) dip) apply", .expected = "{kind undefined-word msg \"undefined word `nope`\" word nope trace (`nope) data {name nope scope session source \"<command>\" line 1 col 5 sites ({source \"<command>\" line 1 col 5})}}" },
        .{ .source = "3 (1 2 3 ((len) dip) dip) times", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 12 sites ({source \"<command>\" line 1 col 12})}}" },
        .{ .source = "(1 2 (len) dip) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `w) data {source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7} {source \"<command>\" line 1 col 24})}}" },
    });
}

test "flatten: a word called from a flattened quotation records its original call site" {
    try expectFailures(&.{
        .{ .source = "(len) `g def (1 2 (g) dip) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 20})}}" },
        .{ .source = "(len) `g def (1 (g) apply 2) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 18})}}" },
        .{ .source = "(len) `g def (g) `h def (1 2 (h) dip) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 15})}}" },
        .{ .source = "(len) `g def (1 (g) apply) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 18})}}" },
        .{ .source = "(len) `g def (5 ((g) apply) ((g) dip) bi) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 19})}}" },
        .{ .source = "(len) `g def (1 2 ((g) dip 3) dip) `w def w", .expected = "{kind underflow msg \"len needs 1 stack value, but found 0\" word len trace (`len `g `w) data {needed 1 available 0 source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 21} {source \"<command>\" line 1 col 43})}}" },
    });
}

test "flatten: a redefinition during a flattened list reaches the rest of it" {
    try support.expectStacks(&.{
        .{ .name = "(1 +) `f def (5 (f) apply ((2 +) `f def) apply 5 (f) apply) apply", .source = "(1 +) `f def (5 (f) apply ((2 +) `f def) apply 5 (f) apply) apply", .expected = "6 7" },
        .{ .name = "(1 2 ((pop pop 7) `dip def) apply (3 +) dip) apply", .source = "(1 2 ((pop pop 7) `dip def) apply (3 +) dip) apply", .expected = "1 7" },
        .{ .name = "(pop pop 7) `dip def (1 2 (3 +) dip) apply", .source = "(pop pop 7) `dip def (1 2 (3 +) dip) apply", .expected = "1 7" },
        .{ .name = "(1 ((pop 9) `apply def) apply (3 +) apply) apply", .source = "(1 ((pop 9) `apply def) apply (3 +) apply) apply", .expected = "1 9" },
        .{ .name = "(1 +) `f def 2 (5 (f) apply ((2 +) `f def) apply) times", .source = "(1 +) `f def 2 (5 (f) apply ((2 +) `f def) apply) times", .expected = "6 7" },
    });
}

test "flatten: a tail apply under a contract keeps its selected quotation" {
    try expectFailures(&.{
        .{ .source = "[1 2] ((1 2) apply) each", .expected = "{kind contract msg \"each quotation at element 0 violated its stack effect; expected final depth 1 from 1 seeded value, observed 3\" word each trace (`each) data {expected (a -- b) seeded 1 observed 3 index 0 source \"<command>\" line 1 col 8 sites ({})}}" },
        .{ .source = "[1 2] (pop (1 2) apply) each", .expected = "{kind contract msg \"each quotation at element 0 violated its stack effect; expected final depth 1 from 1 seeded value, observed 2\" word each trace (`each) data {expected (a -- b) seeded 1 observed 2 index 0 source \"<command>\" line 1 col 12 sites ({})}}" },
        .{ .source = "((x -- y) ((1 2) apply) `two def) `m @defm 5 m.two", .expected = "{kind contract msg \"m.two declared (1 -- 1); seeded 1, observed 3\" word m.two trace (`m.two) data {seeded 1 observed 3 source \"<command>\" line 1 col 12 sites ({})}}" },
    });
}

test "flatten: cleaves, spreads and measured words over literals compute what the words do" {
    try support.expectStacks(&.{
        .{ .name = "(3 (1 +) (2 *) bi) apply", .source = "(3 (1 +) (2 *) bi) apply", .expected = "4 6" },
        .{ .name = "(3 4 (+) (-) bi) apply", .source = "(3 4 (+) (-) bi) apply", .expected = "7 -1" },
        .{ .name = "(3 (1 +) (2 *) (neg) tri) apply", .source = "(3 (1 +) (2 *) (neg) tri) apply", .expected = "4 6 -3" },
        .{ .name = "(3 4 (1 +) (2 *) bracket) apply", .source = "(3 4 (1 +) (2 *) bracket) apply", .expected = "4 8" },
        .{ .name = "(3 [(1 +) (2 *)] cleave) apply", .source = "(3 [(1 +) (2 *)] cleave) apply", .expected = "4 6" },
        .{ .name = "(3 4 [(1 +) (2 *)] spread) apply", .source = "(3 4 [(1 +) (2 *)] spread) apply", .expected = "4 8" },
        .{ .name = "(1 2 3 4 5 6 7 8 9 [(+) (-) (*) (pop) (dup) (swap) (over) (nip)] cleave) apply", .source = "(1 2 3 4 5 6 7 8 9 [(+) (-) (*) (pop) (dup) (swap) (over) (nip)] cleave) apply", .expected = "1 2 3 4 5 6 7 17 -1 72 9 9 9 8 8 9 8 9" },
        .{ .name = "(1 2 [(+) (-) (*) (pop) (dup) (swap) (over) (nip) (id)] cleave) apply", .source = "(1 2 [(+) (-) (*) (pop) (dup) (swap) (over) (nip) (id)] cleave) apply", .expected = "3 -1 2 2 2 2 1 1 2 1 2 2" },
        .{ .name = "(1 2 (pop id) (id) bi) apply", .source = "(1 2 (pop id) (id) bi) apply", .expected = "1 2" },
        .{ .name = "(1 2 3 ((+) dip) (+ +) bi) apply", .source = "(1 2 3 ((+) dip) (+ +) bi) apply", .expected = "3 3 6" },
        .{ .name = "(3 4 ((+) (-) bi *) (max) bi) apply", .source = "(3 4 ((+) (-) bi *) (max) bi) apply", .expected = "-7 4" },
        .{ .name = "(1 2 (over) (swap) bi) apply", .source = "(1 2 (over) (swap) bi) apply", .expected = "1 2 1 2 1" },
        .{ .name = "(1 2 (|a b| a b +) (|a b| a b -) bi) apply", .source = "(1 2 (|a b| a b +) (|a b| a b -) bi) apply", .expected = "3 -1" },
        .{ .name = "(1 2 3 (|a| a a) (|a b| b) bracket) apply", .source = "(1 2 3 (|a| a a) (|a b| b) bracket) apply", .expected = "1 1 3" },
        .{ .name = "(1 2 3 4 ((+) (-) bracket) ((*) (max) bracket) bi) apply", .source = "(1 2 3 4 ((+) (-) bracket) ((*) (max) bracket) bi) apply", .expected = "3 -1 2 4" },
        .{ .name = "(1 2 3 4 ((+) (-) bi) ((*) (max) bi) bracket) apply", .source = "(1 2 3 4 ((+) (-) bi) ((*) (max) bi) bracket) apply", .expected = "3 -1 12 4" },
        .{ .name = "(5 (1 +) (dup 0 > (pop) (dup) if) bi) apply", .source = "(5 (1 +) (dup 0 > (pop) (dup) if) bi) apply", .expected = "6" },
        .{ .name = "2 (3 (1 +) (2 *) bi + 4 5 (neg) (1 +) bracket) times", .source = "2 (3 (1 +) (2 *) bi + 4 5 (neg) (1 +) bracket) times", .expected = "10 -4 6 10 -4 6" },
        .{ .name = "(5 ((1 +) (2 *) bi) below 5 ((1 +) (2 *) bi) above) apply", .source = "(5 ((1 +) (2 *) bi) below 5 ((1 +) (2 *) bi) above) apply", .expected = "5 6 10 6 10 5" },
        .{ .name = "(1 +) `inc def (5 (inc) (inc inc) bi) `w def w w", .source = "(1 +) `inc def (5 (inc) (inc inc) bi) `w def w w", .expected = "6 7 6 7" },
        .{ .name = "(1 2 3 [] cleave 1 2 [(+)] cleave) apply", .source = "(1 2 3 [] cleave 1 2 [(+)] cleave) apply", .expected = "1 2 3 3" },
        .{ .name = "(\"abc\" (len) (reverse) bi) apply", .source = "(\"abc\" (len) (reverse) bi) apply", .expected = "3 \"cba\"" },
        .{ .name = "(3 4 (+) below 3 4 (+) above) apply", .source = "(3 4 (+) below 3 4 (+) above) apply", .expected = "3 4 7 7 3 4" },
        .{ .name = "(5 (dup *) below (1 +) above) apply", .source = "(5 (dup *) below (1 +) above) apply", .expected = "5 26 25" },
        .{ .name = "(1 2 3 (+ +) below) apply", .source = "(1 2 3 (+ +) below) apply", .expected = "1 2 3 6" },
        .{ .name = "(1 2 (pop) below 1 2 (pop) above) apply", .source = "(1 2 (pop) below 1 2 (pop) above) apply", .expected = "1 2 1 2" },
        .{ .name = "(1 2 (pop pop 7 8 9) below) apply", .source = "(1 2 (pop pop 7 8 9) below) apply", .expected = "1 2 7 8 9" },
        .{ .name = "(1 2 (swap) below (over) above) apply", .source = "(1 2 (swap) below (over) above) apply", .expected = "1 2 2 1 2 2 1" },
        .{ .name = "(1 () below () above) apply", .source = "(1 () below () above) apply", .expected = "1" },
        .{ .name = "(1 2 ((+) below) ((+) above) bi) apply", .source = "(1 2 ((+) below) ((+) above) bi) apply", .expected = "1 2 3 3 1 2" },
        .{ .name = "(1 2 3 ((+) dip 5) below) apply", .source = "(1 2 3 ((+) dip 5) below) apply", .expected = "1 2 3 3 3 5" },
        .{ .name = "(1 2 (|a b| a b + a) above) apply", .source = "(1 2 (|a b| a b + a) above) apply", .expected = "3 1 1 2" },
        .{ .name = "(5 (dup 0 > (pop) (dup) if) below) apply", .source = "(5 (dup 0 > (pop) (dup) if) below) apply", .expected = "5" },
        .{ .name = "(1 2 3 4 ((+) below) below) apply", .source = "(1 2 3 4 ((+) below) below) apply", .expected = "1 2 3 4 3 4 7" },
        .{ .name = "(1 +) `inc def 2 (5 (inc) below (inc inc) above) times", .source = "(1 +) `inc def 2 (5 (inc) below (inc inc) above) times", .expected = "5 8 6 5 8 6" },
        .{ .name = "([1 2 3] (2 (+) below + +) each) apply", .source = "([1 2 3] (2 (+) below + +) each) apply", .expected = "[6 8 10]" },
    });
}

test "flatten: a phrase short of inputs fails as the unflattened phrase does" {
    try expectFailures(&.{
        .{ .source = "(1 (+) (-) bi) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 0\" word + trace (`+) data {needed 2 available 0 source \"<command>\" line 1 col 5 sites ({source \"<command>\" line 1 col 5})}}" },
        .{ .source = "((+) (-) bi) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 0\" word + trace (`+) data {needed 2 available 0 source \"<command>\" line 1 col 3 sites ({source \"<command>\" line 1 col 3})}}" },
        .{ .source = "(1 2 (+) (pop pop pop) bi) apply", .expected = "{kind underflow msg \"pop needs 1 stack value, but found 0\" word pop trace (`pop) data {needed 1 available 0 source \"<command>\" line 1 col 19 sites ({source \"<command>\" line 1 col 19})}}" },
        .{ .source = "(1 (1 +) (2 *) bracket) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 1\" word + trace (`+) data {needed 2 available 1 source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "(1 2 (+) (len) bi) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 11 sites ({source \"<command>\" line 1 col 11})}}" },
        .{ .source = "(1 2 (len) (+) bi) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "(1 2 3 (len) (+) bracket) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 9 sites ({source \"<command>\" line 1 col 9})}}" },
        .{ .source = "(1 2 3 (+) (len) bracket) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 13 sites ({source \"<command>\" line 1 col 13})}}" },
        .{ .source = "(1 2 [(+) (len)] cleave) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 12 sites ({source \"<command>\" line 1 col 12})}}" },
        .{ .source = "(1 2 3 [(+) 5] cleave) apply", .expected = "{kind type msg \"cleave expected a list of quotations\" word cleave trace (`cleave) data {source \"<command>\" line 1 col 16 sites ({source \"<command>\" line 1 col 16})}}" },
        .{ .source = "(len) `g def (1 2 (g) (+) bi) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 20})}}" },
        .{ .source = "(len) `g def (1 2 3 (g 4) (+) bracket) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g `w) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 22} {source \"<command>\" line 1 col 47})}}" },
        .{ .source = "(1 2 (+) (1 0 div) bi) apply", .expected = "{kind domain msg \"kernel arithmetic is outside its domain\" word div trace (`div) data {source \"<command>\" line 1 col 15 sites ({source \"<command>\" line 1 col 15})}}" },
        .{ .source = "2 (1 (+) (-) bi) times", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 0\" word + trace (`+) data {needed 2 available 0 source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "((+) below) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 0\" word + trace (`+) data {needed 2 available 0 source \"<command>\" line 1 col 3 sites ({source \"<command>\" line 1 col 3})}}" },
        .{ .source = "(1 (+) above) apply", .expected = "{kind underflow msg \"+ needs 2 stack values, but found 0\" word + trace (`+) data {needed 2 available 0 source \"<command>\" line 1 col 5 sites ({source \"<command>\" line 1 col 5})}}" },
        .{ .source = "(1 2 (len) below) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "(1 2 (len +) above) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len) data {source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7})}}" },
        .{ .source = "(len) `g def (1 2 (g 3) above) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `g `w) data {source \"<command>\" line 1 col 2 sites ({source \"<command>\" line 1 col 2} {source \"<command>\" line 1 col 20} {source \"<command>\" line 1 col 39})}}" },
    });
}

test "flatten: definitions changed during a flattened cleave fail as a counted cleave does" {
    try support.expectStacks(&.{
        .{ .name = "(id) `f def (1 2 (((pop pop) `f def) @attempt pop) (f) bi) apply", .source = "(id) `f def (1 2 (((pop pop) `f def) @attempt pop) (f) bi) apply", .expected = "" },
        .{ .name = "(id) `f def (5 6 (((pop) `f def) @attempt pop) (f) (f) tri) apply", .source = "(id) `f def (5 6 (((pop) `f def) @attempt pop) (f) (f) tri) apply", .expected = "5" },
        .{ .name = "(id) `f def (1 2 3 [(f) (((pop pop) `f def) @attempt pop)] spread) apply", .source = "(id) `f def (1 2 3 [(f) (((pop pop) `f def) @attempt pop)] spread) apply", .expected = "1" },
        .{ .name = "(id) `f def (1 2 (f) (((pop pop) `f def) @attempt pop) bi) apply", .source = "(id) `f def (1 2 (f) (((pop pop) `f def) @attempt pop) bi) apply", .expected = "1 2" },
        .{ .name = "(1 +) `f def (5 (f) (id) bi (dup) `f def 5 (f) (id) bi) apply", .source = "(1 +) `f def (5 (f) (id) bi (dup) `f def 5 (f) (id) bi) apply", .expected = "6 5 5 5 5" },
        .{ .name = "(1 2 ((pop pop 7 8) `bi def) apply (+) (-) bi) apply", .source = "(1 2 ((pop pop 7 8) `bi def) apply (+) (-) bi) apply", .expected = "1 2 7 8" },
        .{ .name = "(pop pop 7) `bi def (1 2 (+) (-) bi) apply", .source = "(pop pop 7) `bi def (1 2 (+) (-) bi) apply", .expected = "1 2 7" },
    });
    try expectFailures(&.{});
}

test "flatten: a source combinator over literals computes what the word does" {
    try support.expectStacks(&.{
        .{ .name = "(3 4 (1 +) both) apply", .source = "(3 4 (1 +) both) apply", .expected = "4 5" },
        .{ .name = "(1 2 (1 +) both 3 (2 *) both) apply", .source = "(1 2 (1 +) both 3 (2 *) both) apply", .expected = "2 6 6" },
        .{ .name = "(bi +) `fork+ def (3 (1 +) (2 *) fork+) apply", .source = "(bi +) `fork+ def (3 (1 +) (2 *) fork+) apply", .expected = "10" },
        .{ .name = "(|x q| x q apply x q apply +) `twice def (3 (1 +) twice) apply", .source = "(|x q| x q apply x q apply +) `twice def (3 (1 +) twice) apply", .expected = "8" },
        .{ .name = "(apply) `run def (run) `run2 def (5 (1 +) run2) apply", .source = "(apply) `run def (run) `run2 def (5 (1 +) run2) apply", .expected = "6" },
        .{ .name = "(|q| q dip) `under def (1 2 (10 +) under) apply", .source = "(|q| q dip) `under def (1 2 (10 +) under) apply", .expected = "11 2" },
        .{ .name = "(|a b q| a q apply b q apply) `mine def 2 (1 2 (10 *) mine) times", .source = "(|a b q| a q apply b q apply) `mine def 2 (1 2 (10 *) mine) times", .expected = "10 20 10 20" },
        .{ .name = "(1 +) `inc def (bi) `b2 def (5 (inc) (inc inc) b2) apply", .source = "(1 +) `inc def (bi) `b2 def (5 (inc) (inc inc) b2) apply", .expected = "6 7" },
        .{ .name = "(x q -- y) (apply) `eff def (5 (1 +) eff) apply", .source = "(x q -- y) (apply) `eff def (5 (1 +) eff) apply", .expected = "6" },
        .{ .name = "((x q -- y) (apply) `ap def (x -- y) ((1 +) ap) `go def) `m @defm (5 m.go 5 (2 *) m.ap) apply", .source = "((x q -- y) (apply) `ap def (x -- y) ((1 +) ap) `go def) `m @defm (5 m.go 5 (2 *) m.ap) apply", .expected = "6 10" },
        .{ .name = "([1 2 3] (dup (1 +) both +) each) apply", .source = "([1 2 3] (dup (1 +) both +) each) apply", .expected = "[4 6 8]" },
        .{ .name = "(both +) `b def (3 4 (1 +) b) `w def w w", .source = "(both +) `b def (3 4 (1 +) b) `w def w w", .expected = "9 9" },
        .{ .name = "(|q| q apply) `r def (5 (1 +) r (dup) `r def 5 (1 +) r) apply", .source = "(|q| q apply) `r def (5 (1 +) r (dup) `r def 5 (1 +) r) apply", .expected = "6 5 (1 +) (1 +)" },
    });
}

test "flatten: an inlined source word keeps its trace and call site" {
    try expectFailures(&.{
        .{ .source = "(3 4 (len) both) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `both) data {source \"<command>\" line 1 col 7 sites ({source \"<command>\" line 1 col 7} {source \"<command>\" line 1 col 12})}}" },
        .{ .source = "(3 (len) both) apply", .expected = "{kind underflow msg \"both needs 3 stack values, but found 2\" word both trace (`both) data {needed 3 available 2 source \"prelude.ecl\" line 21 col 1 sites ({source \"prelude.ecl\" line 21 col 1})}}" },
        .{ .source = "(bi +) `fork+ def (3 (1 +) (len) fork+) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `fork+) data {source \"<command>\" line 1 col 29 sites ({source \"<command>\" line 1 col 29} {source \"<command>\" line 1 col 34})}}" },
        .{ .source = "(|x q| x q apply x q apply +) `twice def (twice) apply", .expected = "{kind underflow msg \"twice needs 2 stack values, but found 0\" word twice trace (`twice) data {needed 2 available 0 source \"<command>\" line 1 col 1 sites ({source \"<command>\" line 1 col 1})}}" },
        .{ .source = "(|q| 1 q apply) `one def ((len) one) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `one) data {source \"<command>\" line 1 col 28 sites ({source \"<command>\" line 1 col 28} {source \"<command>\" line 1 col 33})}}" },
        .{ .source = "(apply) `run def (run) `run2 def (5 (len) run2) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `run) data {source \"<command>\" line 1 col 38 sites ({source \"<command>\" line 1 col 38} {source \"<command>\" line 1 col 19})}}" },
        .{ .source = "(dip 1 +) `under def (1 2 (len) under 9) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `under) data {source \"<command>\" line 1 col 28 sites ({source \"<command>\" line 1 col 28} {source \"<command>\" line 1 col 33})}}" },
        .{ .source = "(|q| q apply) `r def (5 (len) r) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `r) data {source \"<command>\" line 1 col 26 sites ({source \"<command>\" line 1 col 26} {source \"<command>\" line 1 col 31})}}" },
        .{ .source = "(|q| q apply 1) `r def (5 (len) r) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `r) data {source \"<command>\" line 1 col 28 sites ({source \"<command>\" line 1 col 28} {source \"<command>\" line 1 col 33})}}" },
        .{ .source = "(|q| q apply) `r def (5 (len) r 1) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `r `w) data {source \"<command>\" line 1 col 26 sites ({source \"<command>\" line 1 col 26} {source \"<command>\" line 1 col 31} {source \"<command>\" line 1 col 43})}}" },
        .{ .source = "(|q| q apply 1) `r def (5 (len) r 2) `w def w", .expected = "{kind type msg \"len expected a list\" word len trace (`len `r `w) data {source \"<command>\" line 1 col 28 sites ({source \"<command>\" line 1 col 28} {source \"<command>\" line 1 col 33} {source \"<command>\" line 1 col 45})}}" },
        .{ .source = "(|q| q apply) `r def (|q| q r 1 +) `s def (4 (len) s) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `r `s) data {source \"<command>\" line 1 col 47 sites ({source \"<command>\" line 1 col 47} {source \"<command>\" line 1 col 29} {source \"<command>\" line 1 col 52})}}" },
        .{ .source = "(|a b q| a q apply b q apply) `mine def (1 (10 *) mine) apply", .expected = "{kind underflow msg \"mine needs 3 stack values, but found 2\" word mine trace (`mine) data {needed 3 available 2 source \"<command>\" line 1 col 1 sites ({source \"<command>\" line 1 col 1})}}" },
        .{ .source = "(apply) helper `h def (5 (len) h) apply", .expected = "{kind type msg \"len expected a list\" word len trace (`len `h) data {source \"<command>\" line 1 col 32 sites ({source \"<command>\" line 1 col 27} {source \"<command>\" line 1 col 32})}}" },
        .{ .source = "(x q -- y) (apply) `eff def ((x -- y) (5 (1 2) eff) `g def) `m @defm m.g", .expected = "{kind undefined-word msg \"undefined word `eff`\" word eff trace (`eff) data {name eff scope module source \"<command>\" line 1 col 48 sites ({source \"<command>\" line 1 col 48})}}" },
        .{ .source = "(apply) `run def [1 2] ((1 2) run) each", .expected = "{kind contract msg \"each quotation at element 0 violated its stack effect; expected final depth 1 from 1 seeded value, observed 3\" word each trace (`each) data {expected (a -- b) seeded 1 observed 3 index 0 source \"<command>\" line 1 col 25 sites ({})}}" },
        .{ .source = "(|q| q apply) `r def [1 2] ((len) r) each", .expected = "{kind type msg \"len expected a list\" word len trace (`len `r) data {source \"<command>\" line 1 col 30 sites ({source \"<command>\" line 1 col 30} {source \"<command>\" line 1 col 35})}}" },
    });
}
