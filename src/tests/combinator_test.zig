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
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
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
        .{ .name = "for result", .source = "[10] (dup) for", .kind = "contract", .word = "for" },
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

test "combinators: child scopes are fresh and discarded" {
    try support.expectErrors(&.{
        .{
            .name = "each scope",
            .source = "[1 2 3] (dup 'k set k *) each pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "zip-with scope",
            .source = "[1] [2] (pop dup 'k set k pop) zip-with pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "for scope",
            .source = "[1] (dup 'k set pop) for k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "fold scope",
            .source = "[1] 0 (+ dup 'k set) fold pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "scan scope",
            .source = "[1] 0 (+ dup 'k set) scan pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "infra scope",
            .source = "[1] (dup 'k set) infra pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "stencil scope",
            .source = "[1] 1 (dup 'k set) stencil pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "unfold scope",
            .source = "0 (dup 'k set pop 0) () unfold pop pop k",
            .kind = "undefined-word",
            .word = "k",
        },
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
            .source = "([(1 'k set 1) (10) 20] cond) @attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "case prevalidation precedes actions",
            .source = "(1 [1 (7 'k set) 2 20 (30)] case) @attempt pop k",
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
    var runtime = try session.Session.initWithHost(runtime_heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
    });
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
            .source = "((dup 0 =) 'terminal? defp (pop 10) 'base-op defp " ++
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
            .name = "same-home recursive descent retains private within authority",
            .source = "[2] ((dup 0 =) 'terminal? defp " ++
                "(((terminal?) (pop 10) (dup 1 -) (+) linrec without) within) " ++
                "'run def) seed 'linrec-state @defm linrec-state.run",
            .expected = "13",
        },
        .{
            .name = "cross-module quotations remain inside one caller effect boundary",
            .source = "(((dup 0 =)) 'predicate def ((pop 10)) 'base def " ++
                "((dup 1 -)) 'pre def ((+)) 'post def) 'linrec-source @defm " ++
                "((n -- result) (linrec-source.predicate linrec-source.base " ++
                "linrec-source.pre linrec-source.post linrec) 'run def) " ++
                "'linrec-runner @defm 2 linrec-runner.run",
            .expected = "13",
        },
    });
}

test "linrec: cross-module descent preserves the enclosing effect boundary and trace" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    switch (try runtime.runUnit(
        "linrec-source.ecl",
        "(((dup 0 =)) 'predicate def (()) 'base def ((1 -)) 'pre def " ++
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
        "((n -- result) (linrec-source.predicate linrec-source.base " ++
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
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
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

test "linrec: deep recursion uses explicit frames and cancellation reaches guard restore" {
    var depth_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&depth_heap);
    var depth_runtime = try session.Session.init(depth_heap.allocator(), &.{});
    defer depth_runtime.deinit();
    try expectStack(
        &depth_runtime,
        "10000 (dup 0 =) () (1 -) () linrec",
        "0",
    );
    try std.testing.expect(depth_runtime.lastMaxFrames() >= 10_000);

    try support.expectStack(
        "(200 (dup 100 = dup (victim cancel) () if pop dup 0 =) " ++
            "(pop) (1 -) () linrec) @spawn dup 'victim set await 'err at 'kind at",
        "'cancelled",
    );
}

test "nested in-place applications finish in one unwind" {
    // Each finished application continuation records one accounted native
    // step, and the machine loop consumes one per pass: an inner application
    // completing inside an outer one has to end the pass rather than resume
    // the next continuation. `dip` recognition made the shape ordinary, since
    // `bi` and `tri` apply a quotation beneath one.
    try support.expectStacks(&.{
        .{ .name = "nested times", .source = "1 2 (1 (10 *) times) times", .expected = "100" },
        .{ .name = "nested dip", .source = "1 (2 (3 (4 5 +) dip) dip) dip", .expected = "9 3 2 1" },
        .{ .name = "bi", .source = "3 4 (+) (*) bi", .expected = "28" },
        .{ .name = "bi2", .source = "3 4 (+) (*) bi2", .expected = "7 12" },
        .{ .name = "tri", .source = "3 (1 +) (2 *) (3 -) tri", .expected = "4 6 0" },
        .{ .name = "dip inside times", .source = "5 2 (9 (1 +) dip pop) times", .expected = "7" },
        .{ .name = "binder body under dip", .source = "10 20 (|lo hi| hi lo - lo +) call", .expected = "20" },
    });
}

test "empty inline iterations remain cancellable and bounded-frame" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
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
        .word = "times",
        .message = "unit cancelled",
    });
    try std.testing.expect(runtime.lastPolls() >= 1);
    try std.testing.expect(runtime.lastMaxFrames() <= 2);
}

test "combinators: loops guards reductions and result materialization stay cancellable" {
    try expectCancelledAfterSetup("70001 range (pop ()) each", "cond", .automatic);
    try expectCancelledAfterSetup("70000 range", "(dup pop) each", .generic_only);
    try expectCancelledAfterSetup("70000 range", "sort", .automatic);
    try expectCancelledAfterSetup("70000 range -1 =", "first-where", .automatic);
    try expectCancelledAfterSetup("70000 range", "-1 find", .automatic);
    try expectCancelledAfterSetup("70000 range", "0 (+) fold", .automatic);
    // The idiom loop consumes fewer than one kernel quantum; its second
    // traversal, result specialization, is what crosses the poll boundary.
    try expectCancelledAfterSetup("40000 range", "(1 +) each", .automatic);
    try expectCancelledAfterSetup("70000 range", "2 () stencil", .automatic);
    try expectCancelledAfterSetup("0", "(pop 1) (1 + dup) unfold", .automatic);
}

test "idioms: automatic hits and forced generic preserves behavior" {
    var automatic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&automatic_heap);
    var automatic = try session.Session.init(automatic_heap.allocator(), &.{});
    defer automatic.deinit();
    try expectStack(&automatic, "[1 2 3] (neg) each", "[-1 -2 -3]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    var generic_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&generic_heap);
    var generic = try session.Session.init(generic_heap.allocator(), &.{});
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

    // The literal-capture shape `((v) first)` that `partial` builds reaches
    // the same constant-operand kernels a bare constant does, in both operand
    // orders. A wrapper that is not a one-element list is not a capture: it
    // falls through to the generic path, where `first` is instead recognized
    // once per element.
    try expectStack(&automatic, "pop [1 2 3] 3 (+) partial each", "[4 5 6]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&automatic, "pop [1 2 3] 3 (swap -) partial each", "[2 1 0]");
    try std.testing.expectEqual(@as(u64, 1), automatic.lastIdiomHits());

    try expectStack(&automatic, "pop [1 2 3] ((3 4) first +) each", "[4 5 6]");
    try std.testing.expectEqual(@as(u64, 3), automatic.lastIdiomHits());

    var fallback_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&fallback_heap);
    var fallback = try session.Session.init(fallback_heap.allocator(), &.{});
    defer fallback.deinit();
    const failure = switch (try fallback.runUnit("<idiom-fallback>", "1 (neg) each")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer fallback.release(failure);
    try std.testing.expectEqual(@as(u64, 0), fallback.lastIdiomHits());

    var executable_form_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&executable_form_heap);
    var executable_form = try session.Session.init(executable_form_heap.allocator(), &.{});
    defer executable_form.deinit();
    try expectStack(&executable_form, "[1 2 3] (dup *) each", "[1 4 9]");
    try std.testing.expectEqual(@as(u64, 0), executable_form.lastIdiomHits());
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
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();

    // A module shadows `+` and hands out a quotation over it. Applied under
    // `fold` from the session, the quotation's words are stamped with the
    // module's image, which is on no chain the recognizer is about to resolve
    // in -- so recognition must stand down and let dispatch honor the stamp.
    // Recognizing it substituted the core builtin and returned 6.
    try expectStack(
        &runtime,
        "((pop pop 42) '+ def ((+)) 'q def) 'm @defm [1 2 3] 0 m.q fold",
        "42",
    );
    try std.testing.expectEqual(@as(u64, 0), runtime.lastIdiomHits());

    // The mirror: a quotation written where it is applied still recognizes, so
    // the gate is not simply switching recognition off for module code.
    var native_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&native_heap);
    var native = try session.Session.init(native_heap.allocator(), &.{});
    defer native.deinit();
    try expectStack(&native, "[1 2 3] 0 (+) fold", "6");
    try std.testing.expect(native.lastIdiomHits() > 0);

    // And a quotation stamped in one module applied inside another resolves in
    // the chain it was written in, not the one shadowing around it.
    var across_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&across_heap);
    var across = try session.Session.init(across_heap.allocator(), &.{});
    defer across.deinit();
    try expectStack(
        &across,
        "(((+)) 'q def) 'a @defm " ++
            "((pop pop 42) '+ def (|l q| l 0 q fold) 'run def) 'b @defm " ++
            "[1 2 3] a.q b.run",
        "6",
    );
}

test "idioms: a rebound name keeps recognition off" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "(pop pop 42) '+ def [1 2 3] 0 (+) fold", "42");
    try std.testing.expectEqual(@as(u64, 0), runtime.lastIdiomHits());

    var rebound_source_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_source_heap);
    var rebound_source = try session.Session.init(rebound_source_heap.allocator(), &.{});
    defer rebound_source.deinit();
    try expectStack(&rebound_source, "(pop 42) 'neg def [1 2] (neg) each", "[42 42]");
    try std.testing.expectEqual(@as(u64, 0), rebound_source.lastIdiomHits());

    var rebound_match_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_match_heap);
    var rebound_match = try session.Session.init(rebound_match_heap.allocator(), &.{});
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
    var rebound_quoted = try session.Session.init(rebound_quoted_heap.allocator(), &.{});
    defer rebound_quoted.deinit();
    try expectStack(
        &rebound_quoted,
        "(pop pop 42) 'match? def " ++
            "((match?) partial each first-where) 'find def [1 2] 2 find",
        "0",
    );

    var rebound_dependency_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&rebound_dependency_heap);
    var rebound_dependency = try session.Session.init(rebound_dependency_heap.allocator(), &.{});
    defer rebound_dependency.deinit();
    // `neg` is `(-1 *)` in the prelude, so its `*` is core's, not this one.
    try expectStack(&rebound_dependency, "(pop pop 42) '* def 2 neg", "-2");
    try std.testing.expectEqual(@as(u64, 0), rebound_dependency.lastIdiomHits());

    var direct_sort_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&direct_sort_heap);
    var direct_sort = try session.Session.init(direct_sort_heap.allocator(), &.{});
    defer direct_sort.deinit();
    // Likewise `sort` reaches the prelude `grade`, session or module alike.
    try expectStack(&direct_sort, "(pop [0]) 'grade def [3 1 2] sort", "[1 2 3]");
    try std.testing.expectEqual(@as(u64, 0), direct_sort.lastIdiomHits());

    var used_sort_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&used_sort_heap);
    var used_sort = try session.Session.init(used_sort_heap.allocator(), &.{});
    defer used_sort.deinit();
    try expectStack(
        &used_sort,
        "((a -- b) (pop [0]) 'grade def) 'm @defm 'm ('grade) import [3 1 2] sort",
        "[1 2 3]",
    );
    try std.testing.expectEqual(@as(u64, 0), used_sort.lastIdiomHits());

    var between_applications_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&between_applications_heap);
    var between_applications = try session.Session.init(between_applications_heap.allocator(), &.{});
    defer between_applications.deinit();
    try expectStack(
        &between_applications,
        "[1 2] (dup 1 = (((a -- b) (pop 42) 'f def) 'm @defm) () if m.f) each",
        "[42 42]",
    );
    try std.testing.expectEqual(@as(u64, 0), between_applications.lastIdiomHits());
}
