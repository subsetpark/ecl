//! Behavioral tests of word resolution: a word occurrence denotes a scope
//! and a name fixed where it is written, and reads that scope's current
//! definition when it is reached. Every case runs through a public Session
//! and hands it nothing but source strings, so the traceless session heap
//! serves.
const std = @import("std");
const runtime_fixture = @import("runtime_fixture.zig");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("word-cells-test.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.log.err("unexpected language error: {s}", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
}

/// Runs `source`, expects the stack it leaves to display as `expected`, and
/// empties the stack.
fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    try expectOk(runtime, source);
    {
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }
    while (runtime.stackItems().len != 0) try expectOk(runtime, "pop");
}

fn expectErrorContains(runtime: *session.Session, source: []const u8, fragments: []const []const u8) !void {
    const failure = switch (try runtime.runUnit("word-cells-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    for (fragments) |fragment| {
        if (std.mem.indexOf(u8, rendered.bytes(), fragment) == null) {
            std.log.err("expected `{s}` in: {s}", .{ fragment, rendered.bytes() });
            return error.TestUnexpectedResult;
        }
    }
}

test "word cells: a session definition may refer to a word defined later" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // Each definition is its own unit, so the first is published while the
    // word its body calls has no definition.
    try expectOk(&runtime, "(later 1 +) `early def");
    try expectOk(&runtime, "(2) `later def");
    try expectStack(&runtime, "early", "3");
    // Two session words may call each other.
    try expectOk(&runtime, "(dup 0 = (pop 1) (1 - odd?) if) `even? def");
    try expectOk(&runtime, "(dup 0 = (pop 0) (1 - even?) if) `odd? def");
    try expectStack(&runtime, "4 even? 3 even?", "1 0");
}

test "word cells: an unresolved word in a body fails where it is reached" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // The definitions publish, in the session and in a module.
    try expectOk(&runtime, "(\"ran\" io.print missing) `f def");
    try expectOk(&runtime, "((\"ran\" io.print missing) `g def) `m @defm");
    try std.testing.expectEqualStrings("", output.written());
    // The failure is the call's: the forms before the word have run, and the
    // trace holds the caller's activation.
    try expectErrorContains(&runtime, "f", &.{ "kind undefined-word", "word missing", "trace (`missing `f)", "scope session" });
    try std.testing.expectEqualStrings("ran\n", output.written());
    try expectErrorContains(&runtime, "m.g", &.{ "kind undefined-word", "word missing", "trace (`missing `m.g)", "scope module" });
    try std.testing.expectEqualStrings("ran\nran\n", output.written());
    // A branch that is not taken never reaches its word.
    try expectOk(&runtime, "(1 (2) (missing) if) `h def");
    try expectStack(&runtime, "h", "2");
}

test "word cells: an import of a missing attribute fails where the word is reached" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // The import publishes a name the module lacks, a private one, and one
    // of a module that is registered nowhere.
    try expectOk(&runtime, "(1 `one set 2 `hidden setp) `m @defm");
    try expectOk(&runtime, "`m (one missing hidden) import `nowhere (lost) import");
    try expectStack(&runtime, "one", "1");
    try expectErrorContains(&runtime, "missing", &.{ "kind undefined-word", "word missing" });
    try expectErrorContains(&runtime, "hidden", &.{ "kind undefined-word", "word hidden" });
    try expectErrorContains(&runtime, "lost", &.{ "kind undefined-word", "word lost" });
    // In a module too: the body registers, and the failure is the call's.
    try expectOk(&runtime, "(`m (missing) importp (\"ran\" io.print missing) `f def) `user @defm");
    try std.testing.expectEqualStrings("", output.written());
    try expectErrorContains(&runtime, "user.f", &.{ "kind undefined-word", "word missing", "trace (`missing `user.f)" });
    try std.testing.expectEqualStrings("ran\n", output.written());
    // The name follows its module: a registration that adds the attribute
    // gives the imported word a definition.
    try expectOk(&runtime, "(1 `one set 3 `missing set) `m @defm");
    try expectStack(&runtime, "missing", "3");
}

test "word cells: two modules may import from each other" {
    // Each order of first use loads the pair from the other end.
    for ([_][2][]const u8{ .{ "left.total right.total", "11 111" }, .{ "right.total left.total", "111 11" } }) |order| {
        var inputs = try runtime_fixture.Fixture.init();
        defer inputs.deinit();
        try inputs.temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "left.ecl",
            .data = "(`right (ten) import (1) `one def (one ten +) `total def) `left @defm\n",
        });
        try inputs.temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "right.ecl",
            .data = "(`left (one) import (10) `ten def (ten one + 100 +) `total def) `right @defm\n",
        });
        var backing: test_heap.SessionHeap = .init;
        defer test_heap.retire(&backing);
        var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .cooperative, .evaluate);
        defer runtime.deinit();
        try expectStack(&runtime, order[0], order[1]);
    }
}

test "word cells: a reload reaches a plain word of the module that has already run" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // `run` calls its module's `step`, applies its caller's quotation, and
    // calls `step` again.
    try expectOk(&runtime, "((1) `step def (|q| step q apply step) `run def) `looper @defm");
    try expectStack(&runtime, "() looper.run", "1 1");
    // The quotation reloads the module while `run` is running: the second
    // call reads the module as registered then. The reload drops `run`
    // itself, which the activation running it outlives.
    try expectStack(&runtime, "(((2) `step def) `looper @defm) looper.run", "1 2");
    // A word of the module that loops calling a helper reaches each
    // registration made between its calls.
    try expectOk(&runtime, "((10 +) `bump def ((apply 1 bump) each) `sweep def) `looper @defm");
    try expectStack(
        &runtime,
        "[() (((20 +) `bump def) `looper @defm) (((30 +) `bump def) `looper @defm)] looper.sweep",
        "[11 21 31]",
    );
}

test "word cells: a quotation that escaped a module resolves in the module's current registration" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // The session has no `secret`, and the module's is private: only the
    // quotation's own root reaches it.
    try expectOk(&runtime, "((1) `secret defp ((secret)) `handle def) `vault @defm vault.handle `held set");
    try expectStack(&runtime, "held apply", "1");
    try expectOk(&runtime, "((2) `secret defp) `vault @defm");
    try expectStack(&runtime, "held apply", "2");
    // A symbol the module's code builds at run time is written in the module
    // too, so it follows the module the same way.
    try expectOk(&runtime, "((3) `secret defp (\"secret\" intern) `spell def) `vault @defm vault.spell `built set");
    try expectStack(&runtime, "built execute", "3");
    try expectOk(&runtime, "((4) `secret defp) `vault @defm");
    try expectStack(&runtime, "built execute held apply", "4 4");
}

test "word cells: reloading a module under running tasks keeps live memory bounded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(counting.allocator(), &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 2 }, .evaluate);
        defer runtime.deinit();
        // Two tasks loop on a module's words for as long as the root reloads
        // the module, so every reload replaces code that is running. Each
        // batch is one root fiber and two tasks, which end before it does:
        // the batches differ only in how many reloads they make.
        const reload = "((1) `step def ((step) () while) `forever def) `looped @defm";
        const tasks = "(looped.forever) @spawn (looped.forever) @spawn ";
        const stop = " dup task.cancel task.await pop dup task.cancel task.await pop";
        const small = tasks ++ "[1] 16 take (pop " ++ reload ++ ") for" ++ stop;
        const large = tasks ++ "[1] 256 take (pop " ++ reload ++ ") for" ++ stop;
        try expectOk(&runtime, reload);
        // The larger batch has more replaced code alive at once, and storage
        // sized by that peak stays: warm with it.
        try expectStack(&runtime, large, "");
        // Storage that grows by doubling may land in either batch; a pair of
        // rounds keeps the smaller growth of each, and retention per reload
        // would show in both.
        var small_growth: usize = std.math.maxInt(usize);
        var large_growth: usize = std.math.maxInt(usize);
        for (0..2) |_| {
            const before_small = counting.total_requested_bytes;
            try expectStack(&runtime, small, "");
            const after_small = counting.total_requested_bytes;
            try expectStack(&runtime, large, "");
            const after_large = counting.total_requested_bytes;
            small_growth = @min(small_growth, after_small -| before_small);
            large_growth = @min(large_growth, after_large -| after_small);
        }
        // How far reclamation lags behind the tasks sets the peak of live
        // code lists, and the span archive's index grows one leaf at a time
        // with that peak, in whichever batch reaches it. One leaf is allowed;
        // retention per reload over 240 more reloads would exceed it.
        std.testing.expect(large_growth <= small_growth + 16384) catch |err| {
            std.debug.print("module reload under tasks: small_growth={d} large_growth={d}\n", .{ small_growth, large_growth });
            return err;
        };
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "word cells: a reload reaches a dotted name that has already run" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "((1) `value def) `dotted @defm");
    // One session word reaches the module by a dotted name on both sides of
    // its caller's quotation.
    try expectOk(&runtime, "(|q| dotted.value q apply dotted.value) `around def");
    try expectStack(&runtime, "() around", "1 1");
    try expectStack(&runtime, "(((2) `value def) `dotted @defm) around", "1 2");
    try expectStack(&runtime, "() around", "2 2");
    // One occurrence, reached again after each registration made between
    // its runs.
    try expectStack(
        &runtime,
        "[() (((3) `value def) `dotted @defm) (((4) `value def) `dotted @defm)] (apply dotted.value) each",
        "[2 3 4]",
    );
    // An imported name follows the module the same way.
    try expectOk(&runtime, "`dotted (value) import");
    try expectStack(
        &runtime,
        "[() (((5) `value def) `dotted @defm) (((6) `value def) `dotted @defm)] (apply value) each",
        "[4 5 6]",
    );
    // A registration that drops the word leaves nothing to run.
    try expectOk(&runtime, "(dotted.value) `again def again pop");
    try expectOk(&runtime, "((7) `other def) `dotted @defm");
    try expectErrorContains(&runtime, "again", &.{ "kind undefined-word", "word dotted.value" });
}

test "word cells: a definition replacing an import reaches a word that has already run" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "((1) `answer def) `answers @defm `answers (answer) import");
    try expectOk(&runtime, "(|q| answer q apply answer) `around def");
    try expectStack(&runtime, "() around", "1 1");
    // The definition is published while `around` is running, between its
    // two uses of the name.
    try expectStack(&runtime, "((7) `answer def) around", "1 7");
    try expectStack(&runtime, "() around", "7 7");
    // And an import replacing the definition reaches it the same way.
    try expectStack(&runtime, "(`answers (answer) import) around", "7 1");
    try expectStack(&runtime, "((8) `answer def) around ((9) `answer def) around", "1 8 8 9");
}

test "word cells: a session definition shadowing core reaches session code that ran the core word" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // `around` runs core's `neg`, its caller's quotation, and `neg` again.
    try expectOk(&runtime, "(|q| 1 neg q apply 1 neg) `around def");
    try expectStack(&runtime, "() around", "-1 -1");
    try expectStack(&runtime, "((pop 9) `neg def) around", "-1 9");
    try expectStack(&runtime, "() around 1 neg 1 core.neg", "9 9 9 -1");
    // Code written in a module keeps core's word: the session's name is not
    // in its chain.
    try expectOk(&runtime, "((1 neg) `negated def) `plain @defm");
    try expectStack(&runtime, "plain.negated ((pop 8) `neg def) around plain.negated", "-1 9 8 -1");
}

test "word cells: a reload that adds a name shadows the core word its module's code already ran" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // `run` reaches core's `neg`: its module defines none.
    try expectOk(&runtime, "((|q| 1 neg q apply 1 neg) `run def) `shadowing @defm");
    try expectStack(&runtime, "() shadowing.run", "-1 -1");
    // The reload gives the module a `neg` while `run` is running, and drops
    // `run` itself, which the activation running it outlives.
    try expectStack(&runtime, "(((pop 9) `neg def) `shadowing @defm) shadowing.run", "-1 9");
    // A reload that drops the name again uncovers core's word.
    try expectOk(&runtime, "((pop 9) `neg def (|q| 1 neg q apply 1 neg) `run def) `shadowing @defm");
    try expectStack(&runtime, "(((|q| 1 neg) `run def) `shadowing @defm) shadowing.run", "9 -1");
    // The session's own `neg` was core's throughout.
    try expectStack(&runtime, "1 neg", "-1");
}

test "word cells: redefinition under running tasks keeps live memory bounded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(counting.allocator(), &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 2 }, .evaluate);
        defer runtime.deinit();
        // Two tasks loop on a session word for as long as the root redefines
        // it, so every definition replaces one that running code has read.
        // Each batch is one root fiber and two tasks, which end before it
        // does: the batches differ only in how many definitions they make.
        const tasks = "((step) () while) @spawn ((step) () while) @spawn ";
        const stop = " dup task.cancel task.await pop dup task.cancel task.await pop";
        const small = tasks ++ "[1] 16 take (pop (1) `step def) for" ++ stop;
        const large = tasks ++ "[1] 256 take (pop (1) `step def) for" ++ stop;
        try expectOk(&runtime, "(1) `step def");
        // The larger batch has more replaced definitions alive at once, and
        // storage sized by that peak stays: warm with it.
        try expectStack(&runtime, large, "");
        // Storage that grows by doubling may land in either batch; a pair of
        // rounds keeps the smaller growth of each, and retention per
        // definition would show in both.
        var small_growth: usize = std.math.maxInt(usize);
        var large_growth: usize = std.math.maxInt(usize);
        for (0..2) |_| {
            const before_small = counting.total_requested_bytes;
            try expectStack(&runtime, small, "");
            const after_small = counting.total_requested_bytes;
            try expectStack(&runtime, large, "");
            const after_large = counting.total_requested_bytes;
            small_growth = @min(small_growth, after_small -| before_small);
            large_growth = @min(large_growth, after_large -| after_small);
        }
        std.testing.expect(large_growth <= small_growth + 4096) catch |err| {
            std.debug.print("redefinition under tasks: small_growth={d} large_growth={d}\n", .{ small_growth, large_growth });
            return err;
        };
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}
