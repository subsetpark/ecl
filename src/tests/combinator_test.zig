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
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    switch (try runtime.runUnit("<combinator-setup>", setup)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    runtime.setIdiomMode(mode);
    runtime.requestCancellation();
    const failure = switch (try runtime.runUnit("<combinator-cancel>", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, .{
        .name = source,
        .source = source,
        .kind = "cancelled",
        .message = "unit cancelled",
    });
    try std.testing.expect(runtime.lastPolls() >= 1);
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
}

test "combinators: isolated iteration broadcast reduction and infra" {
    try support.expectStacks(&.{
        .{ .name = "each", .source = "[1 2 3] (dup *) each", .expected = "[1 4 9]" },
        .{ .name = "each dict values", .source = "{'a 1 'b 2} (1 +) each", .expected = "{'a 2 'b 3}" },
        .{ .name = "each empty dict", .source = "{} (missing) each", .expected = "{}" },
        .{ .name = "for dict values", .source = "{'a 1 'b 2} (1 + pop) for 42", .expected = "42" },
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
        .{ .name = "unfold predicate bool", .source = "0 (pop 'no) () unfold", .kind = "type", .word = "unfold" },
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
        .{ .name = "dict each no result", .source = "{'a 10} (pop) each", .kind = "contract", .word = "each" },
        .{ .name = "for result", .source = "[10] (dup) for", .kind = "contract", .word = "for" },
        .{ .name = "dict for result", .source = "{'a 10} (dup) for", .kind = "contract", .word = "for" },
        .{
            .name = "dict for follows insertion order",
            .source = "{'first 10 'second 20} (dup 20 = (pop 1) (pop) if) for",
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
        .{ .name = "source and builtin", .source = "(dup *) 'sq def [1 2 3 4 5] (sq 1 +) each", .expected = "[2 5 10 17 26]" },
        .{ .name = "zip-with fold scan", .source = "[1 2] [3 4] (+ 1 +) zip-with [1 2 3] 0 (+) fold [1 2 3] 0 (+) scan", .expected = "[5 7] 6 [1 3 6]" },
        .{ .name = "for and infra", .source = "(dup *) 'sq def [1 2 3] (sq pop) for [1 2 3] (sq swap sq) infra", .expected = "[1 9 4]" },
        // The binding a call keeps is the one in effect when the call began.
        .{ .name = "next call", .source = "(1) 'k def [1 2] (pop k) each (2) 'k def [1 2] (pop k) each", .expected = "[1 1] [2 2]" },
        .{ .name = "next infra call", .source = "(1) 'k def [1 2] (pop k) infra (2) 'k def [1 2] (pop k) infra", .expected = "[1 1] [1 2]" },
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
        .{ .name = "failure after kept bindings", .source = "(dup *) 'sq def [1 2 'x] (sq 1 +) each", .kind = "type", .word = "*" },
        .{ .name = "for failure after kept bindings", .source = "(dup *) 'sq def [1 2 'x] (sq pop) for", .kind = "type", .word = "*" },
        // An application whose operands the kept match does not admit declines
        // to the generic definition, which reports its own error.
        .{ .name = "kept match declined", .source = "[[1 2 3] [] [4]] ((+) fold1) each", .kind = "domain", .word = "first" },
    });
}

test "combinators: definitions inside an application are refused" {
    // Applications run at their caller's level but are not roots, so nothing
    // they do can add a name for later code to resolve.
    try support.expectErrors(&.{
        .{
            .name = "each scope",
            .source = "[1 2 3] (dup 'k set k *) each",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "zip-with scope",
            .source = "[1] [2] (pop dup 'k set k pop) zip-with",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "for scope",
            .source = "[1] (dup 'k set pop) for",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "fold scope",
            .source = "[1] 0 (+ dup 'k set) fold",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "scan scope",
            .source = "[1] 0 (+ dup 'k set) scan",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "infra scope",
            .source = "[1] (dup 'k set) infra",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "stencil scope",
            .source = "[1] 1 (dup 'k set) stencil",
            .kind = "domain",
            .word = "def",
        },
        .{
            .name = "unfold scope",
            .source = "0 (dup 'k set pop 0) () unfold",
            .kind = "domain",
            .word = "def",
        },
        .{ .name = "attempt", .source = "[] (1 'k set) @attempt 'err at raise", .kind = "domain", .word = "def" },
        .{ .name = "task", .source = "[] (1 'k set) @spawn task.await 'err at raise", .kind = "domain", .word = "def" },
        .{ .name = "undef", .source = "1 'k set [1] ('k undef) each", .kind = "domain", .word = "undef" },
        .{ .name = "import", .source = "[1] ('result ('ok) import) each", .kind = "domain", .word = "import" },
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
            .name = "cond stack rollback preserves environment effects",
            .source = "[(1 'guard-effect set 0) () (guard-effect)] cond",
            .expected = "1",
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
        .{
            .name = "while stack rollback preserves environment effects",
            .source = "0 (1 'while-guard-effect set 0) () while while-guard-effect",
            .expected = "0 1",
        },
        .{ .name = "case", .source = "3 [1 (10) 3 (30) (90)] case", .expected = "30" },
        .{ .name = "case else", .source = "2 [1 (10) 3 (30) (90)] case", .expected = "90" },
        .{ .name = "case else only", .source = "2 [(90)] case", .expected = "90" },
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
            .source = "[] ([(1 'k set 1) (10) 20] cond) @attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "case prevalidation precedes actions",
            .source = "[] (1 [1 (7 'k set) 2 20 (30)] case) @attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
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
        .{
            .name = "predicate environment effects survive restoration",
            .source = "0 (7 'linrec-effect set 1) (pop linrec-effect) () () linrec",
            .expected = "7",
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
        "0 (\"guard\" io.print 7 'linrec-io-effect set 1) " ++
            "(pop linrec-io-effect) (missing-pre) (missing-post) linrec",
        "7",
    );
    try std.testing.expectEqualStrings("guard\n", output.written());
}

test "linrec: quotations keep source scope module home and within authority" {
    try support.expectStacks(&.{
        .{
            .name = "all four escaped quotations stay source sealed",
            .source = "[] ((dup 0 =) 'terminal? defp (pop 10) 'base-op defp " ++
                "(dup 1 -) 'pre-op defp (+) 'post-op defp " ++
                "((terminal?)) 'predicate def ((base-op)) 'base def " ++
                "((pre-op)) 'pre def ((post-op)) 'post def) 'linrec-quotes @defm " ++
                "(pop 1) 'terminal? def (pop 999) 'base-op def " ++
                "(pop 0) 'pre-op def (pop pop 999) 'post-op def " ++
                "2 linrec-quotes.predicate linrec-quotes.base " ++
                "linrec-quotes.pre linrec-quotes.post linrec",
            .expected = "13",
        },
        .{
            .name = "cross-module quotations remain inside one caller effect boundary",
            .source = "[] (((dup 0 =)) 'predicate def ((pop 10)) 'base def " ++
                "((dup 1 -)) 'pre def ((+)) 'post def) 'linrec-source @defm " ++
                "[] ((n -- result) (linrec-source.predicate linrec-source.base " ++
                "linrec-source.pre linrec-source.post linrec) 'run def) " ++
                "'linrec-runner @defm 2 linrec-runner.run",
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
        "[] (((dup 0 =)) 'predicate def (()) 'base def ((1 -)) 'pre def " ++
            "((dup)) 'post def) 'linrec-source @defm",
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
        "[] ((n -- result) (linrec-source.predicate linrec-source.base " ++
            "linrec-source.pre linrec-source.post linrec) 'run def) " ++
            "'linrec-runner @defm",
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
        "'trace ['linrec-runner.run]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.bytes(),
        "'source \"linrec-runner.ecl\"",
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

test "linrec: empty post retains explicit depth frames and cancellation reaches guard restore" {
    var depth_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&depth_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var depth_runtime = try session.Session.init(depth_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer depth_runtime.deinit();
    try expectStack(
        &depth_runtime,
        "10000 (dup 0 =) () (1 -) () linrec",
        "0",
    );
    try std.testing.expect(depth_runtime.lastMaxFrames() >= 10_000);

    try support.expectStack(
        "[] (200 (dup 100 = dup (task.cancel-self) () if pop dup 0 =) " ++
            "(pop) (1 -) () linrec) @spawn task.await 'err at 'kind at",
        "'cancelled",
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
        .{ .name = "bi", .source = "3 4 (+) (*) bi", .expected = "28" },
        .{ .name = "bi2", .source = "3 4 (+) (*) bi2", .expected = "7 12" },
        .{ .name = "tri", .source = "3 (1 +) (2 *) (3 -) tri", .expected = "4 6 0" },
        .{ .name = "tri2", .source = "3 4 (+) (*) (-) tri2", .expected = "7 12 -1" },
        .{ .name = "dip inside times", .source = "5 2 (9 (1 +) dip pop) times", .expected = "7" },
        .{ .name = "locals body under dip", .source = "10 20 (|lo hi| hi lo - lo +) call", .expected = "20" },
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
    try std.testing.expect(runtime.lastMaxFrames() <= 2);
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
    try source.appendSlice(std.testing.allocator, "[] (");
    for (0..506) |_| try source.appendSlice(std.testing.allocator, "0 pop ");
    try source.appendSlice(
        std.testing.allocator,
        "0 {'a 1} {'a 2} (pop pop task.cancel-self) dict.merge-with pop pop) " ++
            "@spawn task.await 'err at 'kind at",
    );
    try std.testing.expect((try runtime.runUnit("<driver-cancel>", source.items)) == .ok);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("'cancelled", display.bytes());
}

test "empty inline iterations remain cancellable and bounded-frame" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    runtime.requestCancellation();
    const failure = switch (try runtime.runUnit("<combinator-cancel>", "70000 () times")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, .{
        .name = "cancelled times",
        .source = "70000 () times",
        .kind = "cancelled",
        // Observed where the empty iterations exhaust their fuel, which names
        // no word: the loop is between applications, not inside one.
        .message = "unit cancelled",
    });
    try std.testing.expect(runtime.lastPolls() >= 1);
    try std.testing.expect(runtime.lastMaxFrames() <= 2);
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
        .{ .name = "vector seed survives", .source = "[0.0 0.0] 'seed set [[1.0 2.0] [3.0 4.0]] seed (+) fold seed", .expected = "[4.0 6.0] [0.0 0.0]" },
        .{ .name = "scan keeps every accumulator", .source = "[[1.0 2.0] [3.0 4.0] [5.0 6.0]] [0.0 0.0] (+) scan", .expected = "([1.0 2.0]\n [4.0 6.0]\n [9.0 12.0])" },
        .{ .name = "rows survive", .source = "[[1 2] [3 4] [5 6]] dup (+) fold1 pop", .expected = "([1 2]\n [3 4]\n [5 6])" },
        // Roots without a flat leaf keep the generic route.
        .{ .name = "nested rows", .source = "[[[1 2] [3 4]] [[5 6] [7 8]] [[1 1] [1 1]]] (+) fold1", .expected = "([7 9]\n [11 13])" },
        .{ .name = "dict rows", .source = "[{'a 1} {'a 2} {'a 3}] (+) fold1", .expected = "{'a 6}" },
    });
}

test "combinators: body words resolve as in the caller" {
    // A body word carries the stamp of the root that read it, so it resolves
    // exactly as it would in the caller, and a redefinition between
    // applications reaches the next one.
    try support.expectStacks(&.{
        .{ .name = "plain body", .source = "[1 2 3] (dup *) each", .expected = "[1 4 9]" },
        .{ .name = "nested application", .source = "[1 2 3] ((1 +) call dup *) each", .expected = "[4 9 16]" },
        .{ .name = "locals body", .source = "[1 2 3] (|x| x x *) each", .expected = "[1 4 9]" },
        .{ .name = "redefinition between applications", .source = "(dup *) 'sq def [1 2 3] (sq) each (pop 7) 'sq def [1 2 3] (sq) each", .expected = "[1 4 9] [7 7 7]" },
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

test "locals: the reserved backend words behave and blame as before" {
    // The reader lowers `|a b|` into single-form locals operations named
    // `_ll`, `_gl`, and `_dl`. The names stay reserved from every publication,
    // and are not words a program can write: only the lowering produces the
    // operations. Values, nesting, sharing a body between applications, and
    // the blamed word on failure are what a program can observe.
    try support.expectStacks(&.{
        .{ .name = "read twice", .source = "[1 2 3] (|x| x x *) each", .expected = "[1 4 9]" },
        .{ .name = "two names", .source = "3 4 (|a b| b a -) call", .expected = "1" },
        .{ .name = "three names", .source = "1 2 3 (|a b c| c b a) call", .expected = "3 2 1" },
        .{ .name = "definition applied per element", .source = "(|x| x 1 +) 'inc def [1 2] (inc) each", .expected = "[2 3]" },
        .{ .name = "sequential applications", .source = "1 (|x| x) call 2 (|y| y) call +", .expected = "3" },
        .{ .name = "locals under zip-with", .source = "[1 2] [10 20] (|x y| y x -) zip-with", .expected = "[9 18]" },
        .{ .name = "a list is one value", .source = "[] (|x| x) call", .expected = "()" },
    });
    // Every read shares one word name; its index is what it says. Quotations
    // that read different locals are different values and different keys.
    try support.expectStacks(&.{
        .{ .name = "different reads do not match", .source = "(|a b| a) (|a b| b) match?", .expected = "0" },
        .{ .name = "different bind counts do not match", .source = "(|a| a) (|a b| a) match?", .expected = "0" },
        .{ .name = "identical locals quotations match", .source = "(|a b| a) (|a b| a) match?", .expected = "1" },
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
            .source = "(|x| x) 'f def f",
            .kind = "underflow",
            .word = "f",
            .message = "f needs 1 stack value, but found 0",
        },
        .{
            .name = "a prelude binder blames the prelude word",
            .source = "1 at-or",
            .kind = "underflow",
            .word = "at-or",
            .message = "at-or needs 3 stack values, but found 1",
        },
        .{
            .name = "an anonymous binder blames the binding",
            .source = "(|x| x) call",
            .kind = "underflow",
            .message = "local binding needs 1 stack value, but found 0",
        },
        .{
            .name = "a binder applied through a word is still anonymous",
            .source = "1 (|a b| a b) dip",
            .kind = "underflow",
            .message = "local binding needs 2 stack values, but found 0",
        },
        .{ .name = "the backend names stay reserved", .source = "(|x| x) '_gl def", .kind = "domain", .word = "def" },
        .{ .name = "nor can they be unset", .source = "'_ll unset", .kind = "domain", .word = "undef" },
        .{ .name = "the names are not words a program can write", .source = "0 _gl", .kind = "undefined-word", .word = "_gl" },
    });
    // The failing word appears once, and an anonymous binding names none.
    try support.expectStacks(&.{
        .{
            .name = "the owner is traced once",
            .source = "(|x| x) 'f def ([] (f 1) @attempt 'err at 'trace at) 'g def g",
            .expected = "['f 'g]",
        },
        .{
            .name = "an anonymous binding has no word",
            .source = "[] ((|x| x) call) @attempt 'err at 'word dict.has?",
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
    try expectCancelledAfterSetup("70000 range", "sort", .automatic);
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
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    var generic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&generic_heap);
    var runtime_inputs7 = try runtime_fixture.Fixture.init();
    defer runtime_inputs7.deinit();
    var generic = try session.Session.init(generic_heap.allocator(), &.{}, runtime_inputs7.inputs(.{}), .default, .evaluate);
    defer generic.deinit();
    generic.setIdiomMode(.generic_only);
    try expectStack(&generic, "[1 2 3] (neg) each", "[-1 -2 -3]");
    try std.testing.expectEqual(@as(u64, 0), generic.lastIdiomHits());

    try expectStack(&automatic, "pop [3 1 2] sort", "[1 2 3]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&automatic, "pop -2 abs", "2");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&automatic, "pop [1 2 3] reverse", "[3 2 1]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    // Constant and partial-capture spellings of `match? each` produce their
    // boolean mask in one bounded driver. Structured elements still compare
    // as whole values rather than inheriting `in?`'s recursive pervasion.
    try expectStack(&automatic, "pop [1 2 1] (1 match?) each", "[1 0 1]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(
        &automatic,
        "pop [1 1.0 [2] {'a 3} 'x] [2] (match?) partial each",
        "[0 0 1 0 0]",
    );
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&generic, "pop [1 2 1] (1 match?) each", "[1 0 1]");
    try std.testing.expectEqual(@as(u64, 0), generic.lastIdiomHits());

    try expectStack(
        &generic,
        "pop [1 1.0 [2] {'a 3} 'x] [2] (match?) partial each",
        "[0 0 1 0 0]",
    );
    try std.testing.expectEqual(@as(u64, 0), generic.lastIdiomHits());

    // The trusted `find` body keeps a declarative match-mask fallback, while
    // direct recognition compares only until the first hit and never builds
    // that mask. Empty, structured, and miss cases share the length sentinel.
    try expectStack(&automatic, "pop [1 2 1] 2 find", "1");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());
    try expectStack(&automatic, "pop [[1] [2]] [2] find", "1");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());
    try expectStack(&automatic, "pop [] [2] find", "0");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&generic, "pop [1 2 1] 2 find", "1");
    try std.testing.expectEqual(@as(u64, 0), generic.lastIdiomHits());
    try expectStack(&generic, "pop [[1] [2]] [2] find", "1");
    try std.testing.expectEqual(@as(u64, 0), generic.lastIdiomHits());
    try expectStack(&generic, "pop [] [2] find", "0");
    try std.testing.expectEqual(@as(u64, 0), generic.lastIdiomHits());

    // `partial` prefixes a non-word constant as itself, so it reaches the same
    // constant-operand kernels a bare constant does, in both operand orders.
    // A wrapper spelled by hand is not a constant: it falls through to the
    // generic path, where `first` is instead recognized once per element.
    try expectStack(&automatic, "pop [1 2 3] 3 (+) partial each", "[4 5 6]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&automatic, "pop [1 2 3] 3 (swap -) partial each", "[2 1 0]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&automatic, "pop [1 2 3] ((3 4) first +) each", "[4 5 6]");
    try std.testing.expectEqual(@as(u64, 3), automatic.lastIdiomHits());

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
    try std.testing.expectEqual(@as(u64, 0), fallback.lastIdiomHits());

    var executable_form_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&executable_form_heap);
    var runtime_inputs9 = try runtime_fixture.Fixture.init();
    defer runtime_inputs9.deinit();
    var executable_form = try session.Session.init(executable_form_heap.allocator(), &.{}, runtime_inputs9.inputs(.{}), .default, .evaluate);
    defer executable_form.deinit();
    // No single entry matches `(dup *)`; it compiles as a scalar program.
    try expectStack(&executable_form, "[1 2 3] (dup *) each", "[1 4 9]");
    try std.testing.expectEqual(@as(u64, 1), executable_form.lastIdiomHits());
}

test "idioms: a standard-library definition recognizes through its registration" {
    // Embedded source constructs an anonymous image and registers it in a
    // separate step, so recognition must be recorded while the image is still
    // a value. Losing it leaves `str.format` correct and ~75x slower.
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(&runtime, "[1 \"b\"] \"x{}y{}\" str.format", "\"x1yb\"");
    try std.testing.expectEqual(@as(u64, 1), runtime.lastIdiomHits());
}

// Two separate reasons recognition must not fire, kept together because both
// are about a rebound name and only one is about late binding.
//
// The first two cases are late binding proper: the rebound word is reached
// through a quotation, which resolves where its invoker runs, so the session
// definition really is what executes and a recognizer that assumed the core
// body would be wrong.
//
// The last three rebind a prelude word's *dependency* — `neg`'s `*`, `sort`'s
// `grade` — and are now the opposite lesson. A prelude definition resolves
// against core alone, so the session rebinding cannot reach inside it and the
// prelude behavior is what executes. Recognition stays off in these cases too,
// which is why the hit counts are unchanged, but it is no longer *late
// binding* that keeps it off.
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
        "[] ((pop pop 42) '+ def ((+)) 'q def) 'm @defm [1 2 3] 0 m.q fold",
        "42",
    );
    try std.testing.expectEqual(@as(u64, 0), runtime.lastIdiomHits());

    // The mirror: a quotation written where it is applied still recognizes, so
    // the gate is not simply switching recognition off for module code.
    var native_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&native_heap);
    var runtime_inputs11 = try runtime_fixture.Fixture.init();
    defer runtime_inputs11.deinit();
    var native = try session.Session.init(native_heap.allocator(), &.{}, runtime_inputs11.inputs(.{}), .default, .evaluate);
    defer native.deinit();
    try expectStack(&native, "[1 2 3] 0 (+) fold", "6");
    try std.testing.expect(native.lastIdiomHits() > 0);

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
        "[] (((+)) 'q def) 'a @defm " ++
            "[] ((pop pop 42) '+ def (|l q| l 0 q fold) 'run def) 'b @defm " ++
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
    try expectStack(&runtime, "(pop pop 42) '+ def [1 2 3] 0 (+) fold", "42");
    try std.testing.expectEqual(@as(u64, 0), runtime.lastIdiomHits());

    var rebound_source_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_source_heap);
    var runtime_inputs14 = try runtime_fixture.Fixture.init();
    defer runtime_inputs14.deinit();
    var rebound_source = try session.Session.init(rebound_source_heap.allocator(), &.{}, runtime_inputs14.inputs(.{}), .default, .evaluate);
    defer rebound_source.deinit();
    try expectStack(&rebound_source, "(pop 42) 'neg def [1 2] (neg) each", "[42 42]");
    try std.testing.expectEqual(@as(u64, 0), rebound_source.lastIdiomHits());

    var rebound_match_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_match_heap);
    var runtime_inputs15 = try runtime_fixture.Fixture.init();
    defer runtime_inputs15.deinit();
    var rebound_match = try session.Session.init(rebound_match_heap.allocator(), &.{}, runtime_inputs15.inputs(.{}), .default, .evaluate);
    defer rebound_match.deinit();
    try expectStack(
        &rebound_match,
        "(pop pop 42) 'match? def [1 2] (1 match?) each",
        "[42 42]",
    );
    try std.testing.expectEqual(@as(u64, 0), rebound_match.lastIdiomHits());

    // A word inside a one-element quotation is subject to the same binding
    // guard as a bare pattern word. This replacement has the exact `find`
    // shape, but its quoted `match?` resolves to the session definition, so
    // the recognizer must fall back and preserve that definition's result.
    var rebound_quoted_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_quoted_heap);
    var runtime_inputs16 = try runtime_fixture.Fixture.init();
    defer runtime_inputs16.deinit();
    var rebound_quoted = try session.Session.init(rebound_quoted_heap.allocator(), &.{}, runtime_inputs16.inputs(.{}), .default, .evaluate);
    defer rebound_quoted.deinit();
    try expectStack(
        &rebound_quoted,
        "(pop pop 42) 'match? def " ++
            "((match?) partial each first-where) 'find def [1 2] 2 find",
        "0",
    );

    var rebound_dependency_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_dependency_heap);
    var runtime_inputs17 = try runtime_fixture.Fixture.init();
    defer runtime_inputs17.deinit();
    var rebound_dependency = try session.Session.init(rebound_dependency_heap.allocator(), &.{}, runtime_inputs17.inputs(.{}), .default, .evaluate);
    defer rebound_dependency.deinit();
    // `neg` is `(-1 *)` in the prelude, so its `*` retains core resolution:
    // the result is unchanged and recognition, decided at the freeze edge,
    // stays on.
    try expectStack(&rebound_dependency, "(pop pop 42) '* def 2 neg", "-2");

    var direct_sort_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&direct_sort_heap);
    var runtime_inputs18 = try runtime_fixture.Fixture.init();
    defer runtime_inputs18.deinit();
    var direct_sort = try session.Session.init(direct_sort_heap.allocator(), &.{}, runtime_inputs18.inputs(.{}), .default, .evaluate);
    defer direct_sort.deinit();
    // Likewise `sort` reaches the prelude `grade`, session or module alike.
    try expectStack(&direct_sort, "(pop [0]) 'grade def [3 1 2] sort", "[1 2 3]");

    var used_sort_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&used_sort_heap);
    var runtime_inputs19 = try runtime_fixture.Fixture.init();
    defer runtime_inputs19.deinit();
    var used_sort = try session.Session.init(used_sort_heap.allocator(), &.{}, runtime_inputs19.inputs(.{}), .default, .evaluate);
    defer used_sort.deinit();
    try expectStack(
        &used_sort,
        "[] ((a -- b) (pop [0]) 'grade def) 'm @defm 'm ('grade) import [3 1 2] sort",
        "[1 2 3]",
    );

    var between_applications_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&between_applications_heap);
    var runtime_inputs20 = try runtime_fixture.Fixture.init();
    defer runtime_inputs20.deinit();
    var between_applications = try session.Session.init(between_applications_heap.allocator(), &.{}, runtime_inputs20.inputs(.{}), .default, .evaluate);
    defer between_applications.deinit();
    try expectStack(
        &between_applications,
        "[1 2] (dup 1 = ([] ((a -- b) (pop 42) 'f def) 'm @defm) () if m.f) each",
        "[42 42]",
    );
    try std.testing.expectEqual(@as(u64, 0), between_applications.lastIdiomHits());
}

test "idioms: an offered phrase answered from the call-site cache sees a redefinition" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // One `(+)`, offered three times in one unit: the later checks are cache
    // hits. Redefining `+` must still reach the next application, while the
    // prelude's `sum`, written in core, keeps core `+`.
    try expectStack(
        &runtime,
        "((+) fold1) 'f def [1 2] f [3 4] f [5 6] f [1 2 3] sum " ++
            "(pop pop 42) '+ def [7 8] f [1 2 3] sum",
        "3 7 11 6 42 6",
    );
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

// A unit observes the bindings that existed when it was created, plus its own
// definitions. Each task below waits before reading the word, so it would see
// the parent's later definition if lookup crossed units; under the rule its
// result does not depend on scheduling.
test "bindings: a task keeps the bindings that existed when it was spawned" {
    try expectFreshStack("(1) 'f def [] (20 clock.sleep f) @spawn (2) 'f def task.await", "{'ok [1]}");
    // Through a caller: the task's `f` still reaches the `g` of its creation.
    try expectFreshStack("(1) 'g def (g) 'f def [] (20 clock.sleep f) @spawn (2) 'g def task.await", "{'ok [1]}");
    // Shadowing a core word after the spawn does not reach the task.
    try expectFreshStack("[] (20 clock.sleep 1 2 +) @spawn (pop pop 42) '+ def task.await", "{'ok [3]}");
    // Removing the name after the spawn does not either.
    try expectFreshStack("(1) 'f def [] (20 clock.sleep f) @spawn 'f undef task.await", "{'ok [1]}");
    // Several replacements and a removal after the spawn: only the first
    // binding is kept for the task.
    try expectFreshStack("(1) 'f def [] (20 clock.sleep f) @spawn (2) 'f def (3) 'f def 'f undef (4) 'f def task.await", "{'ok [1]}");
    // A name first defined after the spawn is undefined in the task.
    try expectFreshStack("[] (20 clock.sleep g) @spawn (5) 'g def task.await 'err at 'kind at", "'undefined-word");
    // Two tasks pinned together: the later one ends first, and the earlier
    // one still observes the binding they shared.
    try expectFreshStack(
        "(1) 'f def [] (40 clock.sleep f) @spawn [] (20 clock.sleep f) @spawn (2) 'f def task.await swap task.await",
        "{'ok [1]} {'ok [1]}",
    );
    // Pinned apart: each keeps its own binding, whichever ends first.
    try expectFreshStack(
        "(1) 'f def [] (40 clock.sleep f) @spawn (2) 'f def [] (20 clock.sleep f) @spawn (3) 'f def task.await swap task.await",
        "{'ok [2]} {'ok [1]}",
    );
}

test "bindings: a task spawned after a definition observes it" {
    try expectFreshStack("(1) 'f def (2) 'f def [] (f) @spawn task.await", "{'ok [2]}");
    try expectFreshStack("(1) 'f def 'f undef [] (f) @spawn task.await 'err at 'kind at", "'undefined-word");
    // The defining unit itself sees its definitions as it makes them.
    try expectFreshStack("(1) 'f def f (2) 'f def f", "1 2");
}

test "task.cancel-self requests cancellation of the current task" {
    // Outside a task there is nothing to cancel, including in an `@attempt`
    // of the root unit, which shares its scope.
    try expectFreshStack("[] (task.cancel-self) @attempt 'err at 'kind at", "'domain");
    // A request: the task runs on to its next safe point, where it observes it.
    try expectFreshStack("[] (task.cancel-self 0 100000 (1 +) times) @spawn task.await 'err at 'kind at", "'cancelled");
}

test "bindings: a unit's cached resolutions follow its own definitions" {
    try expectFreshStack("(1 +) 'inc def 5 inc inc (10 +) 'inc def inc", "17");
    try expectFreshStack("(1 +) 'inc def 0 3 (inc) times (10 +) 'inc def 3 (inc) times", "33");
    // Shadowing a core word after using it, and removing the shadow.
    try expectFreshStack("1 2 + (pop pop 42) '+ def 1 2 + '+ undef 1 2 +", "3 42 3");
}

test "while restores a checkpoint deeper than one turn's budget" {
    // 100,000 operands exceed a turn's 65,536 units, so capture and restore
    // suspend under a driver; a condition that consumes the stack still
    // leaves it as it found it.
    try expectFreshStack(
        "[] (100000 (7) times 0 (dup 3 < swap pop) (1 +) while stack len) @spawn task.await 'ok at last",
        "100001",
    );
}

test "while abandons a checkpoint deeper than one turn's budget" {
    // A failing condition abandons the loop with 100,001 operands saved; the
    // checkpoint goes to the release domain whole, and nothing leaks.
    try expectFreshStack(
        "[] (100000 (7) times 0 (dup 'x +) () while) @spawn task.await 'err at 'kind at",
        "'type",
    );
}
