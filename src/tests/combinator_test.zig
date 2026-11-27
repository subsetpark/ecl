const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");
const machine = @import("../machine.zig");
const support = @import("kernel_test_support.zig");

fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    switch (try runtime.runUnit("<combinator-test>", source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer runtime.release(failure);
            return error.TestUnexpectedResult;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
}

fn expectCancelledAfterSetup(
    setup: []const u8,
    source: []const u8,
    mode: machine.IdiomMode,
) !void {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .cooperative, .evaluate);
    defer runtime.deinit();
    switch (try runtime.runUnit("<combinator-setup>", setup)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    runtime.setIdiomMode(mode);
    const victim = try std.mem.concat(std.testing.allocator, u8, &.{ "cancel-input ", source });
    defer std.testing.allocator.free(victim);
    switch (try runtime.runUnit("<combinator-setup>", "`cancel-input set")) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try runtime_fixture.expectCancelledAcrossTurns(&runtime, victim);
}

test "combinators: isolated iteration broadcast reduction and infra" {
    try support.expectStacks(&.{
        .{ .name = "each", .source = "[1 2 3] (dup *) each", .expected = "[1 4 9]" },
        .{ .name = "each dict values", .source = "{a 1 b 2} (1 +) each", .expected = "{a 2 b 3}" },
        .{ .name = "each empty dict", .source = "{} (missing) each", .expected = "{}" },
        .{ .name = "for dict values", .source = "{a 1 b 2} (1 + pop) for 42", .expected = "42" },
        .{ .name = "for empty dict", .source = "{} (missing) for 42", .expected = "42" },
        .{ .name = "zip-with right broadcast", .source = "[1 2 3] 10 (pair) zip-with", .expected = "([1 10]\n [2 10]\n [3 10])" },
        .{ .name = "zip-with left broadcast", .source = "10 [1 2 3] (pair) zip-with", .expected = "([10 1]\n [10 2]\n [10 3])" },
        .{ .name = "fold", .source = "[1 2 3] 0 (+) fold", .expected = "6" },
        .{ .name = "scan", .source = "[1 2 3] 0 (+) scan", .expected = "[1 3 6]" },
        .{ .name = "infra", .source = "7 [1 2 3] (dup) infra", .expected = "7 [1 2 3 3]" },
        .{ .name = "empty each", .source = "() (dup) each", .expected = "()" },
        .{ .name = "empty scan", .source = "() 0 (+) scan", .expected = "()" },
        .{ .name = "empty zip-with lists", .source = "[] [] (+) zip-with", .expected = "()" },
        .{ .name = "empty zip-with right broadcast", .source = "[] 10 (+) zip-with", .expected = "()" },
        .{ .name = "empty zip-with left broadcast", .source = "10 [] (+) zip-with", .expected = "()" },
        .{ .name = "empty string zip-with", .source = "\"\" 10 (+) zip-with", .expected = "()" },
    });
}

test "combinators: update applies isolated quotations through pervasive selectors" {
    try support.expectStacks(&.{
        .{
            .name = "pervasive selector",
            .source = "[10 20 30 40] [1 3] (2 *) update",
            .expected = "[10 40 30 80]",
        },
        .{
            .name = "nested selector and repeated positions",
            .source = "[10 20] [[1] 1] (1 +) update",
            .expected = "[10 22]",
        },
        .{
            .name = "whole-value dictionary key",
            .source = "{[1 2] 9} [1 2] (1 +) update",
            .expected = "{[1 2] 10}",
        },
        .{
            .name = "empty selector does not apply quotation",
            .source = "[1 2] [] (missing) update",
            .expected = "[1 2]",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "all selector leaves validate before application",
            .source = "[1 2] [0 2] (missing) update",
            .kind = "domain",
            .word = "update",
        },
        .{
            .name = "quotation returns exactly one value",
            .source = "[1] 0 (dup) update",
            .kind = "contract",
            .word = "update",
        },
    });
}

test "combinators: stencil and unfold isolate applications and preserve order" {
    try support.expectStacks(&.{
        .{
            .name = "string windows",
            .source = "\"abcdef\" 3 () stencil",
            .expected = "(\"abc\" \"bcd\" \"cde\" \"def\")",
        },
        .{
            .name = "stencil application",
            .source = "[1 2 3 4] 2 (sum) stencil",
            .expected = "[3 5 7]",
        },
        .{
            .name = "stencil wider than input does not apply quotation",
            .source = "[1] 2 (missing) stencil",
            .expected = "()",
        },
        .{
            .name = "unfold outputs current states",
            .source = "3 (0 >) (dup 1 - swap) unfold",
            .expected = "0 [3 2 1]",
        },
        .{
            .name = "unfold empty output",
            .source = "0 (0 >) (dup 1 - swap) unfold",
            .expected = "0 ()",
        },
        .{
            .name = "unfold retains heap states and items",
            .source = "[1 2 3] (len 0 >) (uncons swap) unfold",
            .expected = "[] [1 2 3]",
        },
    });
    try support.expectErrors(&.{
        .{ .name = "stencil no result", .source = "[1 2] 2 (pop) stencil", .kind = "contract", .word = "stencil" },
        .{ .name = "stencil extra result", .source = "[1 2] 2 (dup) stencil", .kind = "contract", .word = "stencil" },
        .{ .name = "stencil zero width", .source = "[1] 0 () stencil", .kind = "domain", .word = "stencil" },
        .{ .name = "stencil input type", .source = "1 1 () stencil", .kind = "type", .word = "stencil" },
        .{ .name = "unfold predicate result", .source = "0 (dup) () unfold", .kind = "contract", .word = "unfold" },
        .{ .name = "unfold predicate bool", .source = "0 (pop `no) () unfold", .kind = "type", .word = "unfold" },
        .{ .name = "unfold step no result", .source = "0 (pop 1) (pop) unfold", .kind = "contract", .word = "unfold" },
        .{ .name = "unfold step extra result", .source = "0 (pop 1) (dup dup) unfold", .kind = "contract", .word = "unfold" },
    });
}

test "combinators: contracts and conformability are structural errors" {
    try support.expectErrors(&.{
        .{
            .name = "each effect",
            .source = "[10 20] (dup) each",
            .kind = "contract",
            .word = "each",
            .data = &.{
                .{ .name = "index", .expected = .{ .int = 0 } },
                .{ .name = "seeded", .expected = .{ .int = 1 } },
                .{ .name = "observed", .expected = .{ .int = 2 } },
            },
        },
        .{ .name = "each no result", .source = "[10] (pop) each", .kind = "contract", .word = "each" },
        .{ .name = "dict each no result", .source = "{a 10} (pop) each", .kind = "contract", .word = "each" },
        .{ .name = "for result", .source = "[10] (dup) for", .kind = "contract", .word = "for" },
        .{ .name = "dict for result", .source = "{a 10} (dup) for", .kind = "contract", .word = "for" },
        .{
            .name = "dict for follows insertion order",
            .source = "{first 10 second 20} (dup 20 = (pop 1) (pop) if) for",
            .kind = "contract",
            .word = "for",
            .data = &.{
                .{ .name = "index", .expected = .{ .int = 1 } },
                .{ .name = "seeded", .expected = .{ .int = 1 } },
                .{ .name = "observed", .expected = .{ .int = 1 } },
            },
        },
        .{ .name = "fold extra result", .source = "[10] 0 (dup) fold", .kind = "contract", .word = "fold" },
        .{ .name = "scan extra result", .source = "[10] 0 (dup) scan", .kind = "contract", .word = "scan" },
        .{
            .name = "fold1 counts from the original list",
            .source = "[10 20 30] (dup 20 = (pop pop 1 2) (+) if) fold1",
            .kind = "contract",
            .word = "fold1",
            .data = &.{
                .{ .name = "index", .expected = .{ .int = 1 } },
                .{ .name = "seeded", .expected = .{ .int = 2 } },
                .{ .name = "observed", .expected = .{ .int = 2 } },
            },
        },
        .{ .name = "fold1 empty", .source = "[] (pop pop 1) fold1", .kind = "domain", .word = "fold1" },
        .{ .name = "fold1 non-list", .source = "5 (+) fold1", .kind = "type", .word = "fold1" },
        .{ .name = "lex-cmp-with extra result", .source = "[[1]] [[2]] (dup) lex-cmp-with", .kind = "contract", .word = "lex-cmp-with" },
        .{ .name = "lex-cmp-with non-int order", .source = "[[1]] [[2]] (pop pop `x) lex-cmp-with", .kind = "type", .word = "lex-cmp-with" },
        .{ .name = "lex-cmp-with non-list", .source = "[1] 2 (cmp) lex-cmp-with", .kind = "type", .word = "lex-cmp-with" },
        .{ .name = "dip non-quotation", .source = "1 2 3 dip", .kind = "type", .word = "dip" },
        .{ .name = "zip-with atoms", .source = "1 2 (+) zip-with", .kind = "type", .word = "zip-with" },
        .{
            .name = "zip-with lengths",
            .source = "[1] [2 3] (+) zip-with",
            .kind = "conform",
            .word = "zip-with",
            .data = &.{
                .{ .name = "left", .expected = .{ .int = 1 } },
                .{ .name = "right", .expected = .{ .int = 2 } },
            },
        },
    });
}

test "measured: above and below restore what the quotation consumed" {
    try support.expectStacks(&.{
        .{ .name = "above restores consumed inputs above the results", .source = "1 2 (+) above 1 (dup) above", .expected = "3 1 2 1 1 1" },
        .{ .name = "below restores them beneath", .source = "1 2 (+) below 1 2 (swap) below", .expected = "1 2 3 1 2 2 1" },
        .{ .name = "every result survives", .source = "1 2 (+ 10 20) below 1 2 (+ 10 20) above", .expected = "1 2 3 10 20 3 10 20 1 2" },
        .{ .name = "a quotation that consumes nothing", .source = "(7) above 1 (8) below", .expected = "7 1 8" },
        .{ .name = "consumption is what the words required", .source = "1 2 (over pop) below 1 2 3 (2 (pop) times) above", .expected = "1 2 1 2 1 2 3" },
        .{
            .name = "dip produces what it protects",
            .source = "1 2 3 ((+) dip) below 1 2 3 ((+) dip) above 0 1 2 3 (((+) dip) dip) below 1 2 3 ((+) dip pop) below",
            .expected = "1 2 3 3 3 3 3 1 2 3 0 1 2 3 1 2 3 1 2 3 3",
        },
        .{ .name = "dip behaves as the shuffle it replaces", .source = "1 2 ((dup) dip) above 1 2 (over swap) above 1 2 ((dup) dip) (over swap) bi", .expected = "1 1 2 1 2 1 1 2 1 2 1 1 2 1 1 2" },
        .{ .name = "a dip selects beneath a cleave", .source = "1 2 3 ((swap nip) dip) (+ +) bi", .expected = "1 3 6" },
        .{ .name = "dip-n produces what it protects", .source = "1 2 3 ((+) dip 5 (2 *) 2 dip-n) below", .expected = "1 2 3 6 3 5" },
        .{ .name = "a nested restore is a product", .source = "5 ((1 +) below) below 1 2 ((+) above) above 1 2 ((+) above) below", .expected = "5 5 6 3 1 2 1 2 1 2 3 1 2" },
        .{
            .name = "guards do not consume what a test admitted",
            .source = "5 ([(0 <) (pop 1) (pop 2)] cond) below 5 ((0 >) (1 -) while) below " ++
                "1 2 3 ((dup 2 =) (pop 100) (1 -) (+) linrec) below " ++
                "5 ([(0 <) (1) (2)] cond) below 5 ((0 <) (1 -) while) below 5 ([(0 <) (1) (2)] cond) above",
            .expected = "5 2 5 0 1 2 3 102 5 2 5 2 5",
        },
        .{ .name = "a cleave inside a floor consumes what its quotations did", .source = "1 2 3 ([(+) (pop)] cleave) below 1 2 3 ([(pop) (7)] cleave) above", .expected = "1 2 3 5 1 2 7 3" },
        .{ .name = "a test that leaves nothing reads beneath", .source = "0 5 [(pop) (1) (2)] cond 0 5 (pop) (1 -) while", .expected = "0 5 2 0 5" },
        .{
            .name = "a declared-effect module word counts inputs beneath the floor",
            .source = "((a -- b) (1 +) `inc def (a b -- c) (+) `add def (a -- bool) (0 <) `below0 def) `m @defm " ++
                "5 (m.inc) below 1 2 (m.add) below 1 2 (m.add) above 1 2 3 ((m.inc) dip) below",
            .expected = "5 6 1 2 3 3 1 2 1 2 3 3 3",
        },
        .{
            .name = "a cond test that is a declared-effect module word reads beneath the floor",
            .source = "((a -- bool) (0 <) `below0 def) `m @defm 5 [(m.below0) (1) (2)] cond 3 ([(m.below0) (1) (2)] cond) below",
            .expected = "5 2 3 2",
        },
        .{ .name = "locals bind across the floor", .source = "1 2 3 (|a b| a b +) below 1 2 3 (|a b| a b +) above", .expected = "1 2 3 5 1 5 2 3" },
        .{ .name = "a word's own substack is a hard floor", .source = "1 ((pop) @attempt) below result.ok?", .expected = "1 0" },
        .{ .name = "admitting and restoring are bounded work", .source = "20000 (1) times (10000 (pop) times) above 20000 pack len", .expected = "20000" },
        .{ .name = "rotating beneath the region is bounded work", .source = "20000 (1) times (10000 (pop) times 5) below 20001 pack dup len swap last", .expected = "20001 5" },
        .{ .name = "sweeping returned originals is bounded work", .source = "20000 (1) times ((10000 (pop) times 0) (pop) while 7) below 20001 pack dup len swap last", .expected = "20001 7" },
        .{ .name = "a guard's restore is bounded work", .source = "20000 (1) times (10000 (pop) times 0) (pop) while 20000 pack len 20000 (1) times [(10000 (pop) times 0) (pop) (pop)] cond 19999 pack len", .expected = "20000 19999" },
        .{ .name = "originals and results outgrow their inline slots", .source = "1 2 3 4 5 6 [(+ + + + +) (1 2 3 4 5 6)] cleave 1 2 3 4 5 6 (+ + + + +) above", .expected = "21 1 2 3 4 5 6 21 1 2 3 4 5 6" },
        .{ .name = "a cleave resumes after a suspended restore", .source = "70000 (1) times [(70000 (pop) times) (7)] cleave", .expected = "7" },
        .{ .name = "a cleave resumes after a suspended drop and push", .source = "70000 (1) times [(70000 (pop) times 8)] cleave", .expected = "8" },
        .{ .name = "a cleave's collect and drop are bounded work", .source = "20000 (1) times [(10000 (pop) times 7) ()] cleave 10001 pack dup len swap last", .expected = "10001 7" },
        .{ .name = "linrec runs in constant space", .source = "100000 (dup 0 =) (pop) (1 -) () linrec 20000 (dup 0 =) (pop 0) (1 -) (1 +) linrec", .expected = "20000" },
    });
    try support.expectErrors(&.{
        .{ .name = "an isolated application beneath admits nothing", .source = "3 [1 2] ((+) each) below", .kind = "underflow", .word = "+" },
        .{ .name = "the stack bottom admits nothing", .source = "(pop) below", .kind = "underflow", .word = "pop" },
        .{ .name = "above non-quotation", .source = "1 above", .kind = "type", .word = "above" },
        .{ .name = "below non-quotation", .source = "1 below", .kind = "type", .word = "below" },
    });
}

// A cleave whose quotations have exact stack summaries runs them in place;
// one with a guard, branches that disagree, or a quotation taken from a
// local runs over the soft floor. Both must leave the same stack, so the
// cases pair or mix them.
test "cleave: summarized and measured quotations agree" {
    try support.expectStacks(&.{
        .{ .name = "builtins against locals", .source = "1 2 (+) (-) bi 1 2 (|a b| a b +) (|a b| a b -) bi", .expected = "3 -1 3 -1" },
        .{ .name = "a dip against locals", .source = "1 2 3 ((+) dip) (+ +) bi 1 2 3 (|a b c| a b + c) (+ +) bi", .expected = "3 3 6 3 3 6" },
        .{ .name = "locals that are bound and unused, repeated, or implicit", .source = "1 2 (|a b|) (id) bi 1 2 (|a| a a) (.x .y +) bi", .expected = "2 2 2 3" },
        .{ .name = "a quotation applied from a local", .source = "1 (2 +) (|q| 1 q apply) (pop) bi", .expected = "1 3" },
        .{ .name = "a quotation that binds its own locals inside one that does", .source = "1 2 (|a| (|b| b 1 +) apply a) (id) bi", .expected = "2 2 2" },
        .{ .name = "a session word written with locals", .source = "(|a b| a b +) `ladd def (|x| x x ladd) `dbl def 5 (dbl) (dbl dbl) bi", .expected = "10 20" },
        .{ .name = "branches that agree and branches that do not", .source = "1 2 (dup 0 > (10 +) (20 +) if) (id) bi 1 2 (dup 0 > (10 +) (pop pop 5) if) (id) bi", .expected = "1 12 2 1 12 2" },
        .{ .name = "measured words inside a quotation", .source = "1 2 ((+) above) ((+) below) bi", .expected = "3 1 2 1 2 3" },
        .{ .name = "a nested cleave", .source = "1 2 ((+) (-) bi *) (pop) bi", .expected = "-3" },
        .{ .name = "a prelude word's body", .source = "1 2 ((dup *) both) (+) bi", .expected = "1 4 3" },
        .{ .name = "three quotations", .source = "[1 2 3] (last) (first) (len) tri", .expected = "3 1 3" },
        .{ .name = "inside a measured word", .source = "5 ((1 +) (2 *) bi) below 5 ((1 +) (2 *) bi) above", .expected = "5 6 10 6 10 5" },
        .{ .name = "a list of eight quotations", .source = "1 2 3 4 5 6 7 8 9 (+) (-) (*) (pop) (dup) (swap) (over) (nip) 8 pack cleave", .expected = "1 2 3 4 5 6 7 17 -1 72 9 9 9 8 8 9 8 9" },
        .{ .name = "a list of nine quotations", .source = "1 2 (+) (-) (*) (pop) (dup) (swap) (over) (nip) (id) 9 pack cleave", .expected = "3 -1 2 2 2 2 1 1 2 1 2 2" },
        .{ .name = "a redefined word is read as redefined", .source = "(x y -- z) (pop pop 9) `over def 1 2 (over) (+) bi", .expected = "9 3" },
        .{ .name = "a quotation that consumes more than one inline slot", .source = "1 2 3 4 5 6 (+ + + + +) (id) bi", .expected = "21 6" },
        .{ .name = "a guard inside a quotation", .source = "1 2 ((0 >) (1 -) while) (id) bi", .expected = "1 0 2" },
        .{ .name = "a session word, with and without a declared effect", .source = "(1 +) `inc def (x -- y) (2 +) `inc2 def 5 (inc) (inc2 inc) bi", .expected = "6 8" },
        .{ .name = "a session word through another", .source = "(+) `add def (add add) `add3 def 1 2 3 (add3) (add) bi", .expected = "6 5" },
        .{ .name = "a redefinition is read on the next call", .source = "(1 +) `f def 5 (f) (id) bi (dup) `f def 5 (f) (id) bi (pop) `f def 5 6 (f) (id) bi", .expected = "6 5 5 5 5 5 6" },
        .{ .name = "a redefined callee changes its caller", .source = "(1 +) `inc def (inc inc) `twice def 5 (twice) (id) bi (pop pop 0) `inc def 1 2 3 (twice) (id) bi", .expected = "7 5 0 3" },
        .{ .name = "a definition changed by an earlier quotation", .source = "(id) `f def 1 2 (((pop pop) `f def) @attempt pop) (f) bi", .expected = "" },
        .{ .name = "a module documentation quotation consumed by @defm", .source = "((: \"doc\") () `m @defm) () bi", .expected = "" },
        .{ .name = "locals bound twice, then partly dropped", .source = "((1) (2 3)) (|a|) 1 take cat (|b| b apply) -1 drop cat (|a b|) 1 drop cat `f def (f) () bi", .expected = "1" },
        .{ .name = "a definition replaced through a quotation-taking word", .source = "(id) `f def 1 ([0] (pop (1 (id) times) `f def) for) (f) bi", .expected = "1" },
        .{ .name = "a definition changed in the first of three quotations", .source = "(id) `f def 5 6 (((pop) `f def) @attempt pop) (f) (f) tri", .expected = "5" },
        .{ .name = "a body that leaves a local bound", .source = "((pop)) (|b|) 1 take cat `leak def (()) (|a| leak a apply) cat `f def 42 (f) () bi", .expected = "" },
        .{ .name = "a word that reaches itself", .source = "(dup 0 > (1 - down) () if) `down def 3 (down) (id) bi", .expected = "0 3" },
        .{ .name = "one quotation applied again after its word is redefined", .source = "(1 +) `f def 5 6 2 ((f) (id) bi (dup) `f def) times", .expected = "5 7 6 6 6" },
        .{ .name = "more nested cleaves than a fiber keeps in place", .source = "1 (((((id) (id) bi pop) (id) bi pop) (id) bi pop) (id) bi pop) (id) bi", .expected = "1 1" },
        .{ .name = "a quotation with no summary applied again", .source = "1 2 2 (1 2 (+) (dup 0 > (pop) (dup) if) bi pop) times", .expected = "1 2" },
        .{ .name = "a session word with a combinator in its body", .source = "((+) dip) `under def 1 2 3 (under) (+ +) bi", .expected = "3 3 6" },
        .{
            .name = "module words, across the boundary and within it",
            .source = "((x -- y) (1 +) `inc def (x -- y) (inc inc) `inc2 def (x -- a b) ((inc) (inc2) bi) `pair def) `m @defm " ++
                "5 (m.inc) (m.inc2) bi 5 m.pair",
            .expected = "6 7 6 7",
        },
    });
    try support.expectErrors(&.{
        .{ .name = "inputs out of reach fail where the word runs", .source = "1 2 (+) (pop pop pop) bi", .kind = "underflow", .word = "pop" },
        .{ .name = "a failure inside a summarized quotation", .source = "1 2 (+) (len) bi", .kind = "type", .word = "len" },
        .{ .name = "a module word that breaks its declared effect", .source = "((x -- y) (pop) `wrong def) `m @defm 1 2 (m.wrong) (id) bi", .kind = "contract", .word = "m.wrong" },
        .{ .name = "a word undefined when its caller runs", .source = "(nope) `bad def 1 (bad) (id) bi", .kind = "undefined-word", .word = "nope" },
    });
}

// Each case runs once with quotations that have stack summaries and once
// with a guard in one of them, which runs over the soft floor.
test "spread: each quotation takes its own inputs, last to first" {
    try support.expectStacks(&.{
        .{ .name = "inputs in order, results in order", .source = "1 2 3 [(+) (dup)] spread 1 2 3 [(+) ([(0 <) (dup) (dup)] cond)] spread", .expected = "3 3 3 3 3 3" },
        .{ .name = "one input each", .source = "10 20 30 [(1 +) (2 +) (3 +)] spread 10 20 30 [(1 +) ([(0 <) (2 +) (2 +)] cond) (3 +)] spread", .expected = "11 22 33 11 22 33" },
        .{ .name = "a quotation that consumes nothing takes nothing", .source = "9 1 2 3 [(7) (+) (8 9)] spread", .expected = "9 1 7 5 8 9" },
        .{ .name = "a value a guard read is consumed", .source = "9 1 2 3 [(7) (+) ([(0 <) (8 9) (8 9)] cond)] spread", .expected = "9 7 3 8 9" },
        .{ .name = "quotations that leave nothing", .source = "1 2 3 [(pop) (pop)] spread 1 2 3 [([(0 <) (pop) (pop)] cond) (pop)] spread", .expected = "1 1" },
        .{ .name = "several results each", .source = "1 2 3 4 [(swap) (swap)] spread 1 2 3 4 [([(0 <) (swap) (swap)] cond) (swap)] spread", .expected = "2 1 4 3 2 1 4 3" },
        .{ .name = "empty quotations and an empty list", .source = "1 2 [() ()] spread 3 [] spread", .expected = "1 2 3" },
        .{ .name = "locals", .source = "1 2 3 [(|a b| a b +) (|c| c c)] spread", .expected = "3 3 3" },
        .{ .name = "more quotations than have counted slots", .source = "1 2 3 4 5 6 7 8 9 [(1 +) (1 +) (1 +) (1 +) (1 +) (1 +) (1 +) (1 +) (1 +)] spread", .expected = "2 3 4 5 6 7 8 9 10" },
        .{
            .name = "inside a measured word",
            .source = "5 6 ([(1 +) (2 +)] spread) below 5 6 ([(1 +) (2 +)] spread) above " ++
                "5 6 ([(1 +) ([(0 <) (2 +) (2 +)] cond)] spread) above",
            .expected = "5 6 6 8 6 8 5 6 6 8 5 6",
        },
        .{ .name = "bracket is the two-quotation spread", .source = "1 2 3 (+) (dup) bracket 1 2 3 (+) ([(0 <) (dup) (dup)] cond) bracket", .expected = "3 3 3 3 3 3" },
        .{ .name = "a bracket inside a summarized quotation", .source = "1 2 3 ((+) (dup) bracket) (id) bi", .expected = "3 3 3 3" },
        .{ .name = "collecting and letting go are bounded work", .source = "20000 (1) times [(10000 (pop) times 7) (5000 (pop) times 8)] spread 5002 pack dup len swap -2 take", .expected = "5002 [7 8]" },
    });
    try support.expectErrors(&.{
        .{ .name = "inputs out of reach fail in the quotation that lacks them", .source = "1 2 [(+) (+)] spread", .kind = "underflow", .word = "+" },
        .{ .name = "the last quotation runs first", .source = "1 2 [(len) (first)] spread", .kind = "type", .word = "first" },
        .{ .name = "the last quotation runs first over the floor", .source = "1 2 [(len) ([(0 <) (first) (first)] cond)] spread", .kind = "type", .word = "first" },
        .{ .name = "a list holding a non-quotation", .source = "1 2 3 [(+) 5] spread", .kind = "type", .word = "spread" },
        .{ .name = "a non-list", .source = "1 2 3 5 spread", .kind = "type", .word = "spread" },
        .{ .name = "bracket runs its second quotation first", .source = "1 2 (len) (first) bracket", .kind = "type", .word = "first" },
        .{ .name = "bracket non-quotation", .source = "1 2 (+) 5 bracket", .kind = "type", .word = "bracket" },
    });
}

test "selectors: id and retain keep values by position" {
    try support.expectStacks(&.{
        .{ .name = "id returns its input", .source = "1 id 2 (id) above", .expected = "1 2 2" },
        .{ .name = "id selects beneath a cleave", .source = "1 2 (pop id) (id) bi", .expected = "1 2" },
        .{ .name = "retain keeps by count, deepest first", .source = "`x `y `z [1 0 2] retain", .expected = "x z z" },
        .{ .name = "retain consumes as many values as it has counts", .source = "9 1 2 [0 1] retain 5 [] retain", .expected = "9 2 5" },
        .{ .name = "retain selects beneath a cleave", .source = "1 2 3 ([1 0 1] retain) (+ +) bi", .expected = "1 3 6" },
        .{ .name = "retain past one turn's budget, by count and by mask", .source = "7 [70000] retain 70000 range 2 mod retain 35000 pack sum", .expected = "245000" },
        .{ .name = "retain over a mixed list of counts", .source = "`x `y (2 1) retain", .expected = "x x y" },
    });
    try support.expectErrors(&.{
        .{ .name = "retain negative count", .source = "1 2 [1 -1] retain", .kind = "domain", .word = "retain" },
        .{ .name = "retain a non-int count, leaving the stack", .source = "1 2 (1 `a) retain", .kind = "type", .word = "retain" },
        .{ .name = "retain more counts than values", .source = "1 [1 1] retain", .kind = "underflow", .word = "retain" },
        .{ .name = "retain non-list counts", .source = "1 `a retain", .kind = "type", .word = "retain" },
    });
}

test "combinators: dip-n protects a counted prefix" {
    try support.expectStacks(&.{
        .{ .name = "counted dips", .source = "1 2 3 (10 +) 2 dip-n 1 2 3 (1 +) 0 dip-n 1 2 3 (7) 3 dip-n", .expected = "11 2 3 1 2 4 7 1 2 3" },
        .{ .name = "beneath a soft floor", .source = "1 2 3 ((10 *) 2 dip-n) below 0 1 2 3 ((+) 2 dip-n) below", .expected = "1 2 3 10 2 3 0 1 2 3 1 2 3" },
        .{ .name = "a symbol stays a value", .source = "0 `m 1 (2 +) 2 dip-n", .expected = "2 m 1" },
        .{ .name = "a large count is bounded work", .source = "20000 (1) times (2) 20000 dip-n 20001 pack len", .expected = "20001" },
    });
    try support.expectErrors(&.{
        .{ .name = "dip-n count beyond the stack underflows before allocating", .source = "() 9000000000 dip-n", .kind = "underflow", .word = "dip-n" },
        .{ .name = "dip-n count beyond a short stack beneath a floor", .source = "1 (() 3 dip-n) below", .kind = "underflow", .word = "dip-n" },
        .{ .name = "dip-n non-int count", .source = "(+) `x dip-n", .kind = "type", .word = "dip-n" },
        .{ .name = "dip-n negative count", .source = "(+) -1 dip-n", .kind = "domain", .word = "dip-n" },
        .{ .name = "dip-n non-quotation", .source = "1 2 dip-n", .kind = "type", .word = "dip-n" },
        .{ .name = "dip-n short stack", .source = "1 2 (+) 3 dip-n", .kind = "underflow", .word = "dip-n" },
    });
}

test "combinators: dip fold1 and lex-cmp-with run any quotation" {
    // Quotations no recognizer takes: nested lists, a user word, and a
    // comparator that reads past its first difference only when told to.
    try support.expectStacks(&.{
        .{ .name = "dip restores the protected value", .source = "1 5 9 (+) dip [] 9 (len) dip", .expected = "6 9 0 9" },
        .{ .name = "fold1 singleton", .source = "[[1 2]] (pop pop 0) fold1", .expected = "[1 2]" },
        .{ .name = "fold1 nested rows", .source = "[[1] [2] [3]] (cat) fold1", .expected = "[1 2 3]" },
        .{
            .name = "lex-cmp-with stops at the first nonzero order",
            .source = "[[1] [2]] [[1] [3] [0]] (cmp) lex-cmp-with [[1]] [[1] [2]] (cmp) lex-cmp-with " ++
                "[[2]] [[1]] (cmp) lex-cmp-with",
            .expected = "-1 -1 1",
        },
    });
}

/// A body of 1,200 forms, deep enough for plan entries two node levels below
/// the root.
const deep_plan_source = source: {
    @setEvalBranchQuota(10_000);
    var text: []const u8 = "[1] (";
    for (0..600) |_| text = text ++ "1 + ";
    break :source text ++ ") each";
};

test "combinators: finite iterations keep their words' bindings and still check each application" {
    // A call decides each word's binding, and the idiom match of a phrase a
    // word offers, at that word's first execution and reuses them for the
    // rest of the call. What depends on an application's operands is still
    // decided per application.
    try support.expectStacks(&.{
        .{ .name = "source and builtin", .source = "(dup *) `sq def [1 2 3 4 5] (sq 1 +) each", .expected = "[2 5 10 17 26]" },
        .{ .name = "zip-with fold scan", .source = "[1 2] [3 4] (+ 1 +) zip-with [1 2 3] 0 (+) fold [1 2 3] 0 (+) scan", .expected = "[5 7] 6 [1 3 6]" },
        .{ .name = "for and infra", .source = "(dup *) `sq def [1 2 3] (sq pop) for [1 2 3] (sq swap sq) infra", .expected = "[1 9 4]" },
        // The binding a call keeps is the one in effect when the call began.
        .{ .name = "next apply", .source = "(1) `k def [1 2] (pop k) each (2) `k def [1 2] (pop k) each", .expected = "[1 1] [2 2]" },
        .{ .name = "next infra apply", .source = "(1) `k def [1 2] (pop k) infra (2) `k def [1 2] (pop k) infra", .expected = "[1 1] [1 2]" },
        // A kept match still meets each row's operand classes.
        .{ .name = "kept match across classes", .source = "[[1 2 3] [4.5 5.5] [7]] ((+) fold1) each", .expected = "(6 10.0 7)" },
        // A body longer than one page of plan entries is planned throughout.
        .{ .name = "long body", .source = "[1 2] (1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + ) each", .expected = "[21 22]" },
        .{ .name = "deep body", .source = deep_plan_source, .expected = "[601]" },
        // A word `execute` dispatches runs at `execute`'s position and takes
        // none of its plan entry.
        .{ .name = "dispatched word", .source = "[1 2 3] (dup (+) first execute) each", .expected = "[2 4 6]" },
        // A different phrase offered at the same word is matched afresh.
        .{ .name = "fresh phrase", .source = "[[1 2 3] [2 3 4]] [(+) (*)] (fold1) zip-with", .expected = "[6 24]" },
    });
    try support.expectErrors(&.{
        // A call that fails after keeping bindings releases them with the call.
        .{ .name = "failure after kept bindings", .source = "(dup *) `sq def [1 2 x] (sq 1 +) each", .kind = "type", .word = "*" },
        .{ .name = "for failure after kept bindings", .source = "(dup *) `sq def [1 2 x] (sq pop) for", .kind = "type", .word = "*" },
        // An application whose operands the kept match does not admit declines
        // to the generic path, which reports its own error.
        .{ .name = "kept match declined", .source = "[[1 2 3] [] [4]] ((+) fold1) each", .kind = "domain", .word = "fold1" },
    });
}

test "combinators: every application keeps its caller's right to define" {
    // Whether a word may define does not depend on which combinator reached
    // it: each body below defines into the session, and later code sees it.
    try support.expectStacks(&.{
        .{ .name = "each", .source = "[1 2 3] (dup `k set) each pop k", .expected = "3" },
        .{ .name = "zip-with", .source = "[1] [2] (pop dup `k set) zip-with pop k", .expected = "1" },
        .{ .name = "for", .source = "[1 2 3] (`k set) for k", .expected = "3" },
        .{ .name = "fold", .source = "[1] 0 (+ dup `k set) fold pop k", .expected = "1" },
        .{ .name = "scan", .source = "[1] 0 (+ dup `k set) scan pop k", .expected = "1" },
        .{ .name = "infra", .source = "[1] (dup `k set) infra pop k", .expected = "1" },
        .{ .name = "stencil", .source = "[1] 1 (dup `k set) stencil pop k", .expected = "[1]" },
        .{ .name = "unfold", .source = "0 (7 `k set pop 0) () unfold k", .expected = "0 () 7" },
        .{ .name = "import", .source = "[1] (`result (ok) import pop) for (1) result.ok", .expected = "{ok [1]}" },
        // A definition is an environment effect: it survives the failure of
        // the @attempt that made it, as IO does.
        .{ .name = "attempt success", .source = "(1 `k set) @attempt pop k", .expected = "1" },
        .{ .name = "attempt failure", .source = "(1 `k set missing) @attempt pop k", .expected = "1" },
        // Redefinition inside a body reaches the next element.
        .{ .name = "redefinition reaches the next element", .source = "(1) `f def [1 2 3] (pop f (2) `f def) each", .expected = "[1 2 2]" },
    });
    try support.expectErrors(&.{
        // A task runs in its spawner's root without owning it.
        .{ .name = "task", .source = "(1 `k set) @spawn task.await `err at raise", .kind = "domain", .word = "def" },
        .{ .name = "task import", .source = "(`result (ok) import) @spawn task.await `err at raise", .kind = "domain", .word = "import" },
        .{ .name = "task inside each", .source = "[1] (pop (1 `k set) @spawn task.await `err at raise) each", .kind = "domain", .word = "def" },
    });
}

test "inline times checkpointed guards and case prevalidate and select" {
    try support.expectStacks(&.{
        .{ .name = "times", .source = "0 3 (1 +) times", .expected = "3" },
        .{ .name = "cond false", .source = "[(0) (111) (222)] cond", .expected = "222" },
        .{ .name = "cond true", .source = "[(1) (111) (222)] cond", .expected = "111" },
        .{ .name = "cond else no-op", .source = "7 [()] cond", .expected = "7" },
        .{
            .name = "cond tests share their entry checkpoint",
            .source = "10 [(1 + 0) () (dup 11 =) () (999)] cond",
            .expected = "10 999",
        },
        .{
            .name = "cond permits destructive tests and restores before the action",
            .source = "10 20 [(pop 10 =) (30) (40)] cond",
            .expected = "10 20 30",
        },
        .{
            .name = "cond ignores test values below its top boolean",
            .source = "[(111 0) () (222)] cond",
            .expected = "222",
        },
        .{
            .name = "while restores each test checkpoint",
            .source = "0 (1 + dup 3 <) (10 +) while",
            .expected = "10",
        },
        .{
            .name = "while permits destructive tests and advances from body results",
            .source = "0 3 (pop 3 <) (swap 1 + swap) while",
            .expected = "3 3",
        },
        .{
            .name = "while false test restores the iteration checkpoint",
            .source = "10 (1 + 0) (999) while",
            .expected = "10",
        },
        .{
            .name = "while checkpoint follows a growing stack",
            .source = "0 (dup 3 <) (dup 1 +) while",
            .expected = "0 1 2 3",
        },
        .{
            .name = "while checkpoint follows a shrinking stack",
            .source = "1 2 3 4 (dup 1 >) (pop) while",
            .expected = "1",
        },
        .{ .name = "case", .source = "3 [1 (10) 3 (30) (90)] case", .expected = "30" },
        .{ .name = "case else", .source = "2 [1 (10) 3 (30) (90)] case", .expected = "2 90" },
        .{ .name = "case else only", .source = "2 [(90)] case", .expected = "2 90" },
        .{ .name = "case inert key", .source = "(missing) [(missing) (7) (9)] case", .expected = "7" },
        .{ .name = "case inert word subject", .source = "(foo) first [foo (7) (9)] case", .expected = "7" },
        .{ .name = "case first duplicate", .source = "1 [1 (10) 1 (20) (30)] case", .expected = "10" },
    });
    try support.expectErrors(&.{
        .{ .name = "cond shape", .source = "[] cond", .kind = "shape", .word = "cond" },
        .{ .name = "cond even", .source = "[() ()] cond", .kind = "shape", .word = "cond" },
        .{ .name = "cond type", .source = "[() 1 ()] cond", .kind = "type", .word = "cond" },
        .{ .name = "while test leaves no boolean", .source = "42 (pop) () while", .kind = "underflow", .word = "while" },
        .{ .name = "cond test leaves no boolean", .source = "42 [(pop) () ()] cond", .kind = "underflow", .word = "cond" },
        .{ .name = "case prevalidation", .source = "1 [1 (10) 2 20 (30)] case", .kind = "type", .word = "len" },
        .{
            .name = "cond prevalidation precedes effects",
            .source = "([(1 `k set 1) (10) 20] cond) @attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "case prevalidation precedes actions",
            .source = "(1 [1 (7 `k set) 2 20 (30)] case) @attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
    });
}

test "measured quotations keep their caller's right to define" {
    // A measured application restores the stack, not the environment: a
    // definition made by a measured body, kept or discarded, survives.
    try support.expectStacks(&.{
        .{ .name = "cond test", .source = "[(1 `guard-effect set 0) () (guard-effect)] cond", .expected = "1" },
        .{ .name = "while condition", .source = "0 (1 `while-guard-effect set 0) () while while-guard-effect", .expected = "0 1" },
        .{ .name = "linrec predicate", .source = "0 (7 `linrec-effect set 1) (pop linrec-effect) () () linrec", .expected = "7" },
        .{ .name = "above", .source = "((1) `measured-above def) above measured-above", .expected = "1" },
        .{ .name = "cleave", .source = "[((1) `measured-cleave def)] cleave measured-cleave", .expected = "1" },
        .{ .name = "bi binds one body to two names", .source = "(7) (`bi-left def) (`bi-right def) bi bi-left bi-right", .expected = "7 7" },
    });
}

test "linrec: terminal selection recursive descent and guard restoration are inline" {
    try support.expectStacks(&.{
        .{
            .name = "terminal base skips recursive quotations",
            .source = "7 (dup 7 =) (pop 99) (missing-pre) (missing-post) linrec",
            .expected = "99",
        },
        .{
            .name = "factorial has pre and post work",
            .source = "5 (dup 0 =) (pop 1) (dup 1 -) (*) linrec",
            .expected = "120",
        },
        .{
            .name = "destructive predicate restores the complete checkpoint",
            .source = "10 20 (pop 10 =) (30) (missing-pre) (missing-post) linrec",
            .expected = "10 20 30",
        },
        .{
            .name = "predicate values below the boolean are discarded",
            .source = "8 (111 1) (1 +) (missing-pre) (missing-post) linrec",
            .expected = "9",
        },
    });
    try support.expectErrors(&.{
        .{ .name = "predicate type", .source = "0 1 () () () linrec", .kind = "type", .word = "linrec" },
        .{ .name = "base type", .source = "0 () 1 () () linrec", .kind = "type", .word = "linrec" },
        .{ .name = "pre type", .source = "0 () () 1 () linrec", .kind = "type", .word = "linrec" },
        .{ .name = "post type", .source = "0 () () () 1 linrec", .kind = "type", .word = "linrec" },
        .{ .name = "missing parameter", .source = "() () () linrec", .kind = "underflow", .word = "linrec" },
        .{ .name = "predicate leaves no boolean", .source = "0 (pop) () () () linrec", .kind = "underflow", .word = "linrec" },
        .{ .name = "predicate non-boolean", .source = "0 (pop 2) () () () linrec", .kind = "type", .word = "linrec" },
    });
}

test "linrec: predicate IO effects survive checkpoint restoration" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(
        &runtime,
        "0 (\"guard\" io.print 1) (pop 7) (missing-pre) (missing-post) linrec",
        "7",
    );
    try std.testing.expectEqualStrings("guard\n", output.written());
}

test "linrec: quotations keep source scope module home and within authority" {
    try support.expectStacks(&.{
        .{
            .name = "all four escaped quotations stay source sealed",
            .source = "((dup 0 =) `terminal? defp (pop 10) `base-op defp " ++
                "(dup 1 -) `pre-op defp (+) `post-op defp " ++
                "((terminal?)) `predicate def ((base-op)) `base def " ++
                "((pre-op)) `pre def ((post-op)) `post def) `linrec-quotes @defm " ++
                "(pop 1) `terminal? def (pop 999) `base-op def " ++
                "(pop 0) `pre-op def (pop pop 999) `post-op def " ++
                "2 linrec-quotes.predicate linrec-quotes.base " ++
                "linrec-quotes.pre linrec-quotes.post linrec",
            .expected = "13",
        },
        .{
            .name = "cross-module quotations remain inside one caller effect boundary",
            .source = "(((dup 0 =)) `predicate def ((pop 10)) `base def " ++
                "((dup 1 -)) `pre def ((+)) `post def) `linrec-source @defm " ++
                "((n -- result) (linrec-source.predicate linrec-source.base " ++
                "linrec-source.pre linrec-source.post linrec) `run def) " ++
                "`linrec-runner @defm 2 linrec-runner.run",
            .expected = "13",
        },
    });
}

test "linrec: cross-module descent preserves the enclosing effect boundary and trace" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    switch (try runtime.runUnit(
        "linrec-source.ecl",
        "(((dup 0 =)) `predicate def (()) `base def ((1 -)) `pre def " ++
            "((dup)) `post def) `linrec-source @defm",
    )) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    switch (try runtime.runUnit(
        "linrec-runner.ecl",
        "((n -- result) (linrec-source.predicate linrec-source.base " ++
            "linrec-source.pre linrec-source.post linrec) `run def) " ++
            "`linrec-runner @defm",
    )) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    const failure = switch (try runtime.runUnit("linrec-call.ecl", "1 linrec-runner.run")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, .{
        .name = "cross-module post effect",
        .source = "1 linrec-runner.run",
        .kind = "contract",
        .word = "linrec-runner.run",
        .data = &.{
            .{ .name = "seeded", .expected = .{ .int = 1 } },
            .{ .name = "observed", .expected = .{ .int = 2 } },
        },
    });
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.bytes(),
        "trace (`linrec-runner.run)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.bytes(),
        "source \"linrec-runner.ecl\"",
    ) != null);
}

test "linrec: failures in every quotation roll back the enclosing unit" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(&runtime, "77", "77");

    const cases = [_]support.ErrorCase{
        .{ .name = "predicate", .source = "1 (missing-predicate) () () () linrec", .kind = "undefined-word", .word = "missing-predicate" },
        .{ .name = "base", .source = "0 (dup 0 =) (missing-base) () () linrec", .kind = "undefined-word", .word = "missing-base" },
        .{ .name = "pre", .source = "1 (dup 0 =) () (missing-pre) () linrec", .kind = "undefined-word", .word = "missing-pre" },
        .{ .name = "post", .source = "1 (dup 0 =) () (1 -) (missing-post) linrec", .kind = "undefined-word", .word = "missing-post" },
    };
    for (cases) |case| {
        const failure = switch (try runtime.runUnit(case.name, case.source)) {
            .err => |item| item,
            .ok, .incomplete => return error.TestUnexpectedResult,
        };
        defer runtime.release(failure);
        try support.expectLanguageError(failure, case);
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings("77", display.bytes());
    }
}

test "linrec: depth is a count under one frame and cancellation reaches guard restore" {
    // Every level applies the same quotations: the pending `post`
    // applications are a count, so depth costs no frames.
    for ([_][]const u8{ "10000", "20000" }) |depth| {
        var depth_heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&depth_heap);
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var depth_runtime = try session.Session.init(depth_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
        defer depth_runtime.deinit();
        var source: [64]u8 = undefined;
        try expectStack(
            &depth_runtime,
            try std.fmt.bufPrint(&source, "{s} (dup 0 =) () (1 -) (1 +) linrec", .{depth}),
            depth,
        );
    }

    try support.expectStack(
        "(200 (dup 100 = dup (task.cancel-self) () if pop dup 0 =) " ++
            "(pop) (1 -) () linrec) @spawn task.await `err at `kind at",
        "cancelled",
    );
}

test "nested in-place applications finish in one unwind" {
    // An inner application completing inside an outer one resumes the outer
    // continuation in the same unwind; each finished continuation spends
    // dispatch fuel, so the unwind is bounded like a run of forms. `dip`
    // recognition made the shape ordinary, since `bi` and `tri` apply a
    // quotation beneath one.
    try support.expectStacks(&.{
        .{ .name = "nested times", .source = "1 2 (1 (10 *) times) times", .expected = "100" },
        .{ .name = "nested dip", .source = "1 (2 (3 (4 5 +) dip) dip) dip", .expected = "9 3 2 1" },
        .{ .name = "bi", .source = "3 4 (+) (*) bi", .expected = "7 12" },
        .{ .name = "tri", .source = "3 (1 +) (2 *) (3 -) tri", .expected = "4 6 0" },
        .{ .name = "dip inside times", .source = "5 2 (9 (1 +) dip pop) times", .expected = "7" },
        .{ .name = "locals body under dip", .source = "10 20 (|lo hi| hi lo - lo +) apply", .expected = "20" },
    });
}

test "application continuations spend fuel rather than scheduler slices" {
    // A finished continuation charges the same fuel a fetched form does. An
    // empty body dispatches no form, so its iterations reach the exhaustion
    // safe point only through that charge: one poll per fuel quantum, not one
    // per iteration, and never zero.
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const iterations = 100_000;
    switch (try runtime.runUnit("<continuation-fuel>", "100000 () times")) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    const polls = runtime.lastPolls();
    try std.testing.expect(polls >= iterations / 4096);
    try std.testing.expect(polls <= iterations / 256);
}

test "nested application unwind polls before completion" {
    const depth = 1100;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, "1 (");
    try source.appendSlice(std.testing.allocator, "0");
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, ") dip ");

    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    switch (try runtime.runUnit("<nested-application-fuel>", source.items)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try std.testing.expect(runtime.lastPolls() >= 3);
    try std.testing.expectEqual(@as(usize, depth + 1), runtime.stackItems().len);
}

test "cancellation retires continuation-installed work before failure unwind" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    // The conflict quotation cancels its own task as its final form. The
    // padding leaves exactly one fuel charge for the merge continuation,
    // which installs its materialization driver before cancellation is polled.
    try source.appendSlice(std.testing.allocator, "(");
    for (0..506) |_| try source.appendSlice(std.testing.allocator, "0 pop ");
    try source.appendSlice(
        std.testing.allocator,
        "0 {a 1} {a 2} (pop pop task.cancel-self) dict.merge-with pop pop) " ++
            "@spawn task.await `err at `kind at",
    );
    try std.testing.expect((try runtime.runUnit("<driver-cancel>", source.items)) == .ok);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("cancelled", display.bytes());
}

test "empty inline iterations remain cancellable and bounded-frame" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .cooperative, .evaluate);
    defer runtime.deinit();
    try runtime_fixture.expectCancelledAcrossTurns(&runtime, "70000 () times");
}

test "combinators: vector reductions reuse only accumulators they own" {
    try support.expectStacks(&.{
        // Later steps take over the previous accumulator's buffer, including
        // an integer buffer retagged in place as floats.
        .{ .name = "float rows", .source = "[[1.0 2.0] [3.0 4.0] [5.0 6.0]] (+) fold1", .expected = "[9.0 12.0]" },
        .{ .name = "integer accumulator retagged as floats", .source = "[[1 2] [3 4] [0.5 0.5] [1 1]] (+) fold1", .expected = "[5.5 7.5]" },
        .{ .name = "scalar accumulator meeting a row", .source = "[1 2 [3]] (+) fold1", .expected = "[6]" },
        // A seed is the caller's and a scan accumulator is a published
        // element; neither may be written in place.
        .{ .name = "vector seed survives", .source = "[0.0 0.0] `seed set [[1.0 2.0] [3.0 4.0]] seed (+) fold seed", .expected = "[4.0 6.0] [0.0 0.0]" },
        .{ .name = "scan keeps every accumulator", .source = "[[1.0 2.0] [3.0 4.0] [5.0 6.0]] [0.0 0.0] (+) scan", .expected = "([1.0 2.0]\n [4.0 6.0]\n [9.0 12.0])" },
        .{ .name = "rows survive", .source = "[[1 2] [3 4] [5 6]] dup (+) fold1 pop", .expected = "([1 2]\n [3 4]\n [5 6])" },
        // Roots without a flat leaf keep the generic route.
        .{ .name = "nested rows", .source = "[[[1 2] [3 4]] [[5 6] [7 8]] [[1 1] [1 1]]] (+) fold1", .expected = "([7 9]\n [11 13])" },
        .{ .name = "dict rows", .source = "[{a 1} {a 2} {a 3}] (+) fold1", .expected = "{a 6}" },
    });
}

test "combinators: body words resolve as in the caller" {
    // A body word carries the stamp of the root that read it, so it resolves
    // exactly as it would in the caller, and a redefinition between
    // applications reaches the next one.
    try support.expectStacks(&.{
        .{ .name = "plain body", .source = "[1 2 3] (dup *) each", .expected = "[1 4 9]" },
        .{ .name = "nested application", .source = "[1 2 3] ((1 +) apply dup *) each", .expected = "[4 9 16]" },
        .{ .name = "locals body", .source = "[1 2 3] (|x| x x *) each", .expected = "[1 4 9]" },
        .{ .name = "redefinition between applications", .source = "(dup *) `sq def [1 2 3] (sq) each (pop 7) `sq def [1 2 3] (sq) each", .expected = "[1 4 9] [7 7 7]" },
    });
}

test "combinators: cached body words spend no kernel polls per element" {
    // Each word dispatched through the resolution driver polls once. A body
    // whose words hit the call-site cache polls only at its continuation, so
    // the count stays near one per element rather than one per word.
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const count = 4096;
    switch (try runtime.runUnit("<cached-body>", "4096 range 0.0 * 1.0 + (dup * 1 +) each len")) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try std.testing.expect(runtime.lastPolls() <= count + count / 64 + 64);
}

test "programs: a body of combinators over literal quotations or of locals runs as the words would" {
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .source = "[1 2 3] ((1 +) apply) each", .expected = "[2 3 4]" },
        .{ .source = "[1 2 3] ((1 +) (2 *) bi +) each", .expected = "[4 7 10]" },
        .{ .source = "[1 2 3] ((1 +) (2 *) (neg) tri + +) each", .expected = "[3 5 7]" },
        .{ .source = "[1 2 3] (2 (1 +) dip *) each", .expected = "[4 6 8]" },
        .{ .source = "[1 2 3] (2 (+) below + +) each", .expected = "[6 8 10]" },
        .{ .source = "[1 2 3] (2 (-) above - -) each", .expected = "[0 0 0]" },
        .{ .source = "[1 2 3] (3 (1 +) (2 *) bracket -) each", .expected = "[-4 -3 -2]" },
        .{ .source = "[1 2 3] (2 ((+) (-) bi) (*) bi + +) each", .expected = "[4 8 12]" },
        .{ .source = "[1 2 3] (2 (over) (swap) bi + + + +) each", .expected = "[7 10 13]" },
        .{ .source = "[1 2 3] (|a| a 1 + a 2 * +) each", .expected = "[4 7 10]" },
        .{ .source = "[1 2 3] (|a| a (|b| b b *) apply a +) each", .expected = "[2 6 12]" },
        .{ .source = "[1 2 3] ((|a| a 1 +) (|b| b 2 *) bi -) each", .expected = "[0 -1 -2]" },
        .{ .source = "[1 2 3] [4 5 6] ((+) (-) bi *) zip-with", .expected = "[-15 -21 -27]" },
        .{ .source = "[1 2 3] 0 (|sum x| sum x x * +) fold", .expected = "14" },
        .{ .source = "[1 2 3] ((max) (min) bi -) fold1", .expected = "2" },
        .{ .source = "[1 2 3] 0 ((+) apply) scan", .expected = "[1 3 6]" },
        // A literal that stack words copied is still a literal.
        .{ .source = "[1 2 3] ((1 +) dup bi +) each", .expected = "[4 6 8]" },
        // Bodies no program holds: a branch, a word that is no program
        // word, and a quotation that is the element, not a literal.
        .{ .source = "[1 2 3] (2 (pop id) (+) bi -) each", .expected = "[-2 -2 -2]" },
        .{ .source = "[(1 +) (2 *)] (5 swap apply) each", .expected = "[6 10]" },
        .{ .source = "[1 2 3] (dup 2 > (10 +) (20 +) if) each", .expected = "[21 22 13]" },
    };
    var automatic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&automatic_heap);
    var automatic_inputs = try runtime_fixture.Fixture.init();
    defer automatic_inputs.deinit();
    var automatic = try session.Session.init(automatic_heap.allocator(), &.{}, automatic_inputs.inputs(.{}), .default, .evaluate);
    defer automatic.deinit();
    var generic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&generic_heap);
    var generic_inputs = try runtime_fixture.Fixture.init();
    defer generic_inputs.deinit();
    var generic = try session.Session.init(generic_heap.allocator(), &.{}, generic_inputs.inputs(.{}), .default, .evaluate);
    defer generic.deinit();
    generic.setIdiomMode(.generic_only);
    try expectStack(&automatic, "0", "0");
    try expectStack(&generic, "0", "0");
    var buffer: [256]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "pop {s}", .{case.source});
        try expectStack(&automatic, source, case.expected);
        try expectStack(&generic, source, case.expected);
    }
    try support.expectErrors(&.{
        .{ .name = "a fault in an applied quotation", .source = "[4 0 2] ((8 swap div) apply) each", .kind = "domain", .word = "div" },
        .{ .name = "a fault in a cleave's second quotation", .source = "[4 0 2] ((1 +) (8 swap div) bi +) each", .kind = "domain", .word = "div" },
        .{ .name = "a fault in a body with locals", .source = "[4 0 2] (|a| 8 a div) each", .kind = "domain", .word = "div" },
        .{ .name = "a body that reaches beneath its element", .source = "[4 0 2] ((+) (-) bi *) each", .kind = "underflow", .word = "+" },
    });
}

test "programs: a combinator body spends no kernel polls per word" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const count = 4096;
    switch (try runtime.runUnit("<combinator-body>", "4096 range (|a| a (1 +) (2 *) bi +) each len")) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try std.testing.expect(runtime.lastPolls() <= count + count / 64 + 64);
}

test "slots: implicit locals bind up to the highest slot their list writes" {
    try support.expectStacks(&.{
        .{ .name = "read twice", .source = "[1 2 3] (.x .x *) each", .expected = "[1 4 9]" },
        .{ .name = "two slots", .source = "3 4 (.y .x -) apply", .expected = "1" },
        .{ .name = "three slots", .source = "1 2 3 (.z .y .x) apply", .expected = "3 2 1" },
        // The highest slot sets the count; lower ones are bound unread.
        .{ .name = "a gap binds the lower slot", .source = "1 2 (.y) apply", .expected = "2" },
        .{ .name = "a wider gap", .source = "0 1 2 3 (.z 10 *) apply", .expected = "0 30" },
        .{ .name = "a slot binder is a locals binder", .source = "(.y .x) (|x y| y x) match?", .expected = "1" },
        // A slot belongs to the innermost list that writes it.
        .{ .name = "a nested list's slots are its own", .source = "5 [1 2] (.y (.x 10 *) each .x) apply", .expected = "[10 20] 5" },
        .{ .name = "slots nest inside a locals body", .source = "1 (|a| a (.x 2 *) apply) apply", .expected = "2" },
    });
    try support.expectErrors(&.{
        .{ .name = "outside a list", .source = ".x", .kind = "parse" },
        .{ .name = "inside a dict", .source = "{.x 1}", .kind = "parse" },
        .{ .name = "beside a locals declaration", .source = "(|a| a .x)", .kind = "parse" },
        .{ .name = "as a local name", .source = "(|.x| 1)", .kind = "parse" },
        .{ .name = "quoted", .source = "(`.x)", .kind = "parse" },
        .{ .name = "underflow blames the binding", .source = "1 (.y) apply", .kind = "underflow", .message = "local binding needs 2 stack values, but found 1" },
    });
}

test "locals: the reserved backend words behave and blame as before" {
    // The reader lowers `|a b|` into single-form locals operations named
    // `_ll`, `_gl`, and `_dl`. The names stay reserved from every publication,
    // and are not words a program can write: only the lowering produces the
    // operations. Values, nesting, sharing a body between applications, and
    // the blamed word on failure are what a program can observe.
    try support.expectStacks(&.{
        .{ .name = "read twice", .source = "[1 2 3] (|x| x x *) each", .expected = "[1 4 9]" },
        .{ .name = "two names", .source = "3 4 (|a b| b a -) apply", .expected = "1" },
        .{ .name = "three names", .source = "1 2 3 (|a b c| c b a) apply", .expected = "3 2 1" },
        .{ .name = "definition applied per element", .source = "(|x| x 1 +) `inc def [1 2] (inc) each", .expected = "[2 3]" },
        .{ .name = "sequential applications", .source = "1 (|x| x) apply 2 (|y| y) apply +", .expected = "3" },
        .{ .name = "locals under zip-with", .source = "[1 2] [10 20] (|x y| y x -) zip-with", .expected = "[9 18]" },
        .{ .name = "a list is one value", .source = "[] (|x| x) apply", .expected = "()" },
    });
    // Every read shares one word name; its index is what it says. Quotations
    // that read different locals are different values and different keys.
    try support.expectStacks(&.{
        .{ .name = "different reads do not match", .source = "(|a b| a) (|a b| b) match?", .expected = "0" },
        .{ .name = "different bind counts do not match", .source = "(|a| a) (|a b| a) match?", .expected = "0" },
        .{ .name = "identical locals quotations match", .source = "(|a b| a) (|a b| a) match?", .expected = "1" },
        // A lowered operation stored as data is a quoted occurrence of the same
        // operation: it keeps its operand, matches its source, prints as the
        // quote, and pushes itself where the drop would have run.
        .{ .name = "a stored operation keeps its operand", .source = "(|x| x) last wrap", .expected = "(1 `_dl)" },
        .{ .name = "a stored operation matches its source", .source = "(|x| x) last wrap (|x| x) 2 drop match?", .expected = "1" },
        .{ .name = "a quoted drop after a final apply is not the epilogue", .source = "0 (|y| (1 (2) apply) (|x| x) last append apply) apply", .expected = "1 2 1 _dl" },
        .{
            .name = "different reads are separate keys",
            .source = "{} (|a b| a) 1 dict.put (|a b| b) 2 dict.put dup dict.keys len swap (|a b| a) at",
            .expected = "2 1",
        },
    });
    try support.expectErrors(&.{
        // A binder opening a word's body is that word's arity check, so the
        // word fails as a primitive would; any other binder fails as itself.
        .{
            .name = "a definition's binder blames the definition",
            .source = "(|x| x) `f def f",
            .kind = "underflow",
            .word = "f",
            .message = "f needs 1 stack value, but found 0",
        },
        .{
            .name = "a prelude binder blames the prelude word",
            .source = "1 both",
            .kind = "underflow",
            .word = "both",
            .message = "both needs 3 stack values, but found 1",
        },
        .{
            .name = "an anonymous binder blames the binding",
            .source = "(|x| x) apply",
            .kind = "underflow",
            .message = "local binding needs 1 stack value, but found 0",
        },
        .{
            .name = "a binder applied through a word is still anonymous",
            .source = "1 (|a b| a b) dip",
            .kind = "underflow",
            .message = "local binding needs 2 stack values, but found 0",
        },
        .{ .name = "the backend names stay reserved", .source = "(|x| x) `_gl def", .kind = "domain", .word = "def" },
        .{ .name = "the names are not words a program can write", .source = "0 _gl", .kind = "undefined-word", .word = "_gl" },
    });
    // The failing word appears once, and an anonymous binding reports none.
    try support.expectStacks(&.{
        .{
            .name = "the owner is traced once",
            .source = "(|x| x) `f def ((f 1) @attempt `err at `trace at) `g def g",
            .expected = "(`f `g)",
        },
        .{
            .name = "an anonymous binding has no word",
            .source = "((|x| x) apply) @attempt `err at `word dict.core.has?",
            .expected = "0",
        },
    });
}

test "locals: the backend words spend no kernel polls per element" {
    // A word resolved through the driver polls once. The three locals words
    // are dispatched without resolution, so a body of only locals reads polls
    // at its continuation and nowhere else.
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const count = 4096;
    switch (try runtime.runUnit("<locals-body>", "4096 range 0.0 * 1.0 + (|x| x) each len")) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try std.testing.expect(runtime.lastPolls() <= count + count / 64 + 64);
}

test "combinators: loops guards reductions and result materialization stay cancellable" {
    try expectCancelledAfterSetup("70001 range (pop ()) each", "cond", .automatic);
    try expectCancelledAfterSetup("70000 range", "(dup pop) each", .generic_only);
    try expectCancelledAfterSetup("70000 range", "dup grade at", .automatic);
    try expectCancelledAfterSetup("70000 range -1 =", "first-where", .automatic);
    try expectCancelledAfterSetup("70000 range", "-1 find", .automatic);
    try expectCancelledAfterSetup("70000 range", "0 (+) fold", .automatic);
    try expectCancelledAfterSetup("3 range (pop 70000 range 1.0 *) each", "(+) fold1", .automatic);
    // More than one kernel quantum of elements, so the idiom loop itself
    // reaches a poll; word dispatch never polls.
    try expectCancelledAfterSetup("70000 range", "(1 +) each", .automatic);
    try expectCancelledAfterSetup("70000 range", "2 () stencil", .automatic);
    try expectCancelledAfterSetup("0", "(pop 1) (1 + dup) unfold", .automatic);
}

test "idioms: automatic hits and forced generic preserves behavior" {
    var automatic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&automatic_heap);
    var runtime_inputs6 = try runtime_fixture.Fixture.init();
    defer runtime_inputs6.deinit();
    var automatic = try session.Session.init(automatic_heap.allocator(), &.{}, runtime_inputs6.inputs(.{}), .default, .evaluate);
    defer automatic.deinit();
    try expectStack(&automatic, "[1 2 3] (neg) each", "[-1 -2 -3]");

    var generic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&generic_heap);
    var runtime_inputs7 = try runtime_fixture.Fixture.init();
    defer runtime_inputs7.deinit();
    var generic = try session.Session.init(generic_heap.allocator(), &.{}, runtime_inputs7.inputs(.{}), .default, .evaluate);
    defer generic.deinit();
    generic.setIdiomMode(.generic_only);
    try expectStack(&generic, "[1 2 3] (neg) each", "[-1 -2 -3]");

    // Constant and cons-capture spellings of `match? each` produce their
    // boolean mask in one bounded driver. Structured elements still compare
    // as whole values rather than inheriting `in?`'s recursive pervasion.
    try expectStack(&automatic, "pop [1 2 1] (1 match?) each", "[1 0 1]");

    try expectStack(
        &automatic,
        "pop [1 1.0 [2] {a 3} x] [2] (match?) cons each",
        "[0 0 1 0 0]",
    );

    try expectStack(&generic, "pop [1 2 1] (1 match?) each", "[1 0 1]");

    try expectStack(
        &generic,
        "pop [1 1.0 [2] {a 3} x] [2] (match?) cons each",
        "[0 0 1 0 0]",
    );

    // `cons` prefixes a non-word constant as itself, so it reaches the same
    // constant-operand kernels a bare constant does, in both operand orders.
    // A wrapper spelled by hand is not a constant: it falls through to the
    // generic path, where `first` is a builtin and nothing fuses.
    try expectStack(&automatic, "pop [1 2 3] 3 (+) cons each", "[4 5 6]");

    try expectStack(&automatic, "pop [1 2 3] 3 (swap -) cons each", "[2 1 0]");

    try expectStack(&automatic, "pop [1 2 3] ((3 4) first +) each", "[4 5 6]");

    var fallback_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&fallback_heap);
    var runtime_inputs8 = try runtime_fixture.Fixture.init();
    defer runtime_inputs8.deinit();
    var fallback = try session.Session.init(fallback_heap.allocator(), &.{}, runtime_inputs8.inputs(.{}), .default, .evaluate);
    defer fallback.deinit();
    const failure = switch (try fallback.runUnit("<idiom-fallback>", "1 (neg) each")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer fallback.release(failure);

    var executable_form_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&executable_form_heap);
    var runtime_inputs9 = try runtime_fixture.Fixture.init();
    defer runtime_inputs9.deinit();
    var executable_form = try session.Session.init(executable_form_heap.allocator(), &.{}, runtime_inputs9.inputs(.{}), .default, .evaluate);
    defer executable_form.deinit();
    // No single entry matches `(dup *)`; it compiles as a scalar program.
    try expectStack(&executable_form, "[1 2 3] (dup *) each", "[1 4 9]");
}

// A rebound word is reached through a quotation, which resolves where its
// invoker runs, so the rebinding really is what executes and a recognizer that
// assumed the core builtin would be wrong.
test "idioms: a foreign stamp keeps recognition off" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs10 = try runtime_fixture.Fixture.init();
    defer runtime_inputs10.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs10.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // A module shadows `+` and hands out a quotation over it. Applied under
    // `fold` from the session, the quotation's words are stamped with the
    // module's image, which is on no chain the recognizer is about to resolve
    // in -- so recognition must stand down and let dispatch honor the stamp.
    // Recognizing it substituted the core builtin and returned 6.
    try expectStack(
        &runtime,
        "((pop pop 42) `+ def ((+)) `q def) `m @defm [1 2 3] 0 m.q fold",
        "42",
    );

    // The mirror: a quotation written where it is applied still recognizes, so
    // the gate is not simply switching recognition off for module code.
    var native_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&native_heap);
    var runtime_inputs11 = try runtime_fixture.Fixture.init();
    defer runtime_inputs11.deinit();
    var native = try session.Session.init(native_heap.allocator(), &.{}, runtime_inputs11.inputs(.{}), .default, .evaluate);
    defer native.deinit();
    try expectStack(&native, "[1 2 3] 0 (+) fold", "6");

    // And a quotation stamped in one module applied inside another resolves in
    // the chain it was written in independently of the surrounding shadow.
    var across_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&across_heap);
    var runtime_inputs12 = try runtime_fixture.Fixture.init();
    defer runtime_inputs12.deinit();
    var across = try session.Session.init(across_heap.allocator(), &.{}, runtime_inputs12.inputs(.{}), .default, .evaluate);
    defer across.deinit();
    try expectStack(
        &across,
        "(((+)) `q def) `a @defm " ++
            "((pop pop 42) `+ def (|l q| l 0 q fold) `run def) `b @defm " ++
            "[1 2 3] a.q b.run",
        "6",
    );
}

test "idioms: a rebound name keeps recognition off" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs13 = try runtime_fixture.Fixture.init();
    defer runtime_inputs13.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs13.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(&runtime, "(pop pop 42) `+ def [1 2 3] 0 (+) fold", "42");

    var rebound_source_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_source_heap);
    var runtime_inputs14 = try runtime_fixture.Fixture.init();
    defer runtime_inputs14.deinit();
    var rebound_source = try session.Session.init(rebound_source_heap.allocator(), &.{}, runtime_inputs14.inputs(.{}), .default, .evaluate);
    defer rebound_source.deinit();
    try expectStack(&rebound_source, "(pop 42) `neg def [1 2] (neg) each", "[42 42]");

    var rebound_match_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_match_heap);
    var runtime_inputs15 = try runtime_fixture.Fixture.init();
    defer runtime_inputs15.deinit();
    var rebound_match = try session.Session.init(rebound_match_heap.allocator(), &.{}, runtime_inputs15.inputs(.{}), .default, .evaluate);
    defer rebound_match.deinit();
    try expectStack(
        &rebound_match,
        "(pop pop 42) `match? def [1 2] (1 match?) each",
        "[42 42]",
    );

    var between_applications_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&between_applications_heap);
    var runtime_inputs20 = try runtime_fixture.Fixture.init();
    defer runtime_inputs20.deinit();
    var between_applications = try session.Session.init(between_applications_heap.allocator(), &.{}, runtime_inputs20.inputs(.{}), .default, .evaluate);
    defer between_applications.deinit();
    try expectStack(
        &between_applications,
        "[1 2] (dup 1 = (((a -- b) (pop 42) `f def) `m @defm) () if `m.f execute) each",
        "[42 42]",
    );
}

test "idioms: an offered phrase answered from the call-site cache sees a redefinition" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // One `(+)`, offered three times in one submission: the later checks are
    // cache hits. Redefining `+` must still reach the next application, while
    // the builtin `sum` keeps its own addition.
    try expectStack(
        &runtime,
        "((+) fold1) `f def [1 2] f [3 4] f [5 6] f [1 2 3] sum " ++
            "(pop pop 42) `+ def [7 8] f [1 2 3] sum",
        "3 7 11 6 42 6",
    );
}

test "idioms: a phrase matched earlier in an iteration sees a redefinition" {
    // The inner `(+)` is offered at one position once per outer element, so
    // the later offers are answered from what the iteration remembers.
    // Redefining `+` after the first must still reach the second and third.
    try expectFreshStack("[1 2 3] (pop [1 2 3] 0 (+) fold (-) `+ def) each", "[6 -6 -6]");
}

fn expectFreshStack(source: []const u8, expected: []const u8) !void {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(&runtime, source, expected);
}

// A task inherits no historical view: its body binds when it first runs,
// against the definitions current then. What a definition already bound stays
// fixed, so a task running a word reaches the targets that word was bound to
// however the parent redefines its names afterwards.
test "bindings: a running task sees definitions made after its spawn" {
    // The task resolves `f` when it reaches it, after the root redefined it.
    try expectFreshStack("(1) `f def (20 clock.sleep f) `body def (body) @spawn (2) `f def task.await", "{ok [2]}");
    // Through a caller: `f` reaches the replaced `g`.
    try expectFreshStack("(1) `g def (g) `f def (20 clock.sleep f) `body def (body) @spawn (2) `g def task.await", "{ok [2]}");
    // Shadowing a core word after the spawn reaches the session's code too.
    try expectFreshStack("(20 clock.sleep 1 2 +) `work def (work) @spawn (pop pop 42) `+ def task.await", "{ok [42]}");
    // The last of several replacements is the one reached.
    try expectFreshStack("(1) `f def (20 clock.sleep f) `body def (body) @spawn (2) `f def (3) `f def (4) `f def task.await", "{ok [4]}");
    // A task body referring to an undefined word fails before running anything.
    try expectFreshStack("(missing-word) @spawn task.await `err at `kind at", "undefined-word");
}

test "bindings: a task spawned after a definition observes it" {
    try expectFreshStack("(1) `f def (2) `f def (f) @spawn task.await", "{ok [2]}");
    // The defining unit itself sees its definitions as it makes them.
    try expectFreshStack("(1) `f def f (2) `f def f", "1 2");
}

test "task.cancel-self requests cancellation of the current task" {
    // Outside a task there is nothing to cancel, including in an `@attempt`
    // of the root unit, which shares its scope.
    try expectFreshStack("(task.cancel-self) @attempt `err at `kind at", "domain");
    // A request: the task runs on to its next safe point, where it observes it.
    try expectFreshStack("(task.cancel-self 0 100000 (1 +) times) @spawn task.await `err at `kind at", "cancelled");
}

test "bindings: a redefinition reaches the next use of a word its unit has run" {
    try expectFreshStack("(1 +) `inc def 5 inc inc (10 +) `inc def inc", "17");
    try expectFreshStack("(1 +) `inc def 0 3 (inc) times (10 +) `inc def 3 (inc) times", "33");
    // Shadowing a core word after using it; `core.+` still reaches core.
    try expectFreshStack("1 2 + (pop pop 42) `+ def 1 2 + 1 2 core.+", "3 42 3");
}

test "bindings: a word the implementation built for itself runs core's binding each time" {
    // An error's `word` is a symbol the implementation built, so it means
    // core's word whatever the session defines, the first time it runs and
    // after; a symbol the session wrote means the session's.
    try expectFreshStack(
        "(id) @attempt `err at `word at (pop 42) `id def 5 swap dup (execute) dip execute 5 `id execute",
        "5 42",
    );
}

test "while restores a checkpoint deeper than one turn's budget" {
    // 100,000 operands exceed a turn's 65,536 units, so capture and restore
    // suspend under a driver; a condition that consumes the stack still
    // leaves it as it found it.
    try expectFreshStack(
        "(100000 (7) times 0 (dup 3 < swap pop) (1 +) while stack len) @spawn task.await `ok at last",
        "100001",
    );
}

test "while abandons a checkpoint deeper than one turn's budget" {
    // A failing condition abandons the loop with 100,001 operands saved; the
    // checkpoint goes to the release domain whole, and nothing leaks.
    try expectFreshStack(
        "(100000 (7) times 0 (dup `x +) () while) @spawn task.await `err at `kind at",
        "type",
    );
}
