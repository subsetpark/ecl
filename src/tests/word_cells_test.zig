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
            .sub_path = "ecl.modules",
            .data = "{format 1 local \"root\" scopes {\"root\" {root \".\" visible [] sources [] artifacts [" ++
                "{path \"left.ecl\" kind ecl exports [\"left\"]} " ++
                "{path \"right.ecl\" kind ecl exports [\"right\"]}]}}}",
        });
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

/// A module map in which two sources differ in what they may see: the
/// session's scope may refer to `shared` and `blind`, and `blind`'s scope to
/// nothing. `blind` imports a word of `shared` all the same, and holds words
/// that apply, build, and hand out symbols on behalf of a caller; `guest.ecl`
/// is a second file of `blind`'s scope.
const ViewFixture = struct {
    inputs: runtime_fixture.Fixture,
    backing: test_heap.SessionHeap,
    runtime: session.Session,

    fn init(self: *ViewFixture) !void {
        self.inputs = try runtime_fixture.Fixture.init();
        errdefer self.inputs.deinit();
        const dir = self.inputs.temporary.dir;
        try dir.writeFile(std.testing.io, .{
            .sub_path = "ecl.modules",
            .data = "{format 1 local \"root\" scopes {" ++
                "\"root\" {root \".\" visible [\"shared\" \"blind\"] sources [] artifacts []} " ++
                "\"shared\" {root \".\" visible [] sources [] artifacts [" ++
                "{path \"shared.ecl\" kind ecl exports [\"shared\"]}]} " ++
                "\"blind\" {root \".\" visible [] sources [] artifacts [" ++
                "{path \"blind.ecl\" kind ecl exports [\"blind\"]} " ++
                "{path \"guest.ecl\" kind ecl exports [\"guest\"]}]}}}",
        });
        try dir.writeFile(std.testing.io, .{
            .sub_path = "shared.ecl",
            .data = "(: \"Shared words.\") ((42) `answer def) `shared @defm\n",
        });
        try dir.writeFile(std.testing.io, .{
            .sub_path = "blind.ecl",
            .data = "(`shared (answer) import " ++
                "(apply) `run def " ++
                "((shared.answer)) `quotation def " ++
                "(`shared `answer qualify) `build def " ++
                "(`shared) `module-name def " ++
                "(exports) `names def " ++
                "(module-doc) `document def) `blind @defm\n",
        });
        try dir.writeFile(std.testing.io, .{ .sub_path = "guest.ecl", .data = "() `guest @defm\n" });
        self.backing = .init;
        errdefer test_heap.retire(&self.backing);
        self.runtime = try session.Session.init(self.backing.allocator(), &.{}, self.inputs.inputs(.{}), .cooperative, .evaluate);
    }

    fn deinit(self: *ViewFixture) void {
        self.runtime.deinit();
        test_heap.retire(&self.backing);
        self.inputs.deinit();
    }
};

const hidden_module: []const []const u8 = &.{ "kind undefined-word", "not visible" };

test "word cells: a quotation applied in another source reaches a module only its own source may see" {
    var fixture: ViewFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    // The quotation is written by the session, which may see `shared`, and
    // applied by a word of `blind`, which may not. The module is cold, so
    // the load is requested on the quotation's behalf too.
    try expectStack(runtime, "(shared.answer) blind.run", "42");
    try expectStack(runtime, "(shared.answer 1 +) blind.run", "43");
}

test "word cells: a quotation applied in another source does not gain the modules that source may see" {
    var fixture: ViewFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    // The quotation is written in `blind` and applied by the session.
    try expectErrorContains(runtime, "blind.quotation apply", hidden_module);
    // Visibility, not load state, decides: the session reaches the module,
    // and the quotation still does not.
    try expectStack(runtime, "shared.answer", "42");
    try expectErrorContains(runtime, "blind.quotation apply", hidden_module);
}

test "word cells: a qualified symbol built at run time resolves as the code that built it" {
    var fixture: ViewFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    // Built by the session and run by `blind`.
    try expectStack(runtime, "`shared `answer qualify (execute) blind.run", "42");
    try expectStack(runtime, "\"shared.answer\" symbol (execute) blind.run", "42");
    // Built by `blind` and run by the session.
    try expectErrorContains(runtime, "blind.build execute", hidden_module);
}

test "word cells: a session import resolves as the source of the word that uses it" {
    var fixture: ViewFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    try expectOk(runtime, "`shared (answer) import");
    // A second source writes a use of the imported word into the session
    // root: a unit read from a file of `blind`'s scope.
    switch (try runtime.runUnit("guest.ecl", "(answer) `guest-answer def")) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
    try expectStack(runtime, "answer", "42");
    try expectStack(runtime, "(answer) `own-answer def own-answer", "42");
    try expectErrorContains(runtime, "guest-answer", &.{ "kind undefined-word", "word answer" });
    // An import a module holds resolves as that module's source, whoever
    // reaches it and whether or not the module it refers to has loaded.
    try expectErrorContains(runtime, "blind.answer", hidden_module);
}

test "word cells: exports resolves its module as the source of its operand" {
    var fixture: ViewFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    // The module name is written by the session and handed to a word of
    // `blind` that asks for its exports and its documentation.
    try expectStack(runtime, "`shared blind.names", "(`answer)");
    try expectStack(runtime, "`shared blind.document", "\"Shared words.\"");
    // A name written in `blind` finds nothing, whoever asks.
    try expectErrorContains(runtime, "blind.module-name exports", hidden_module);
    try expectErrorContains(runtime, "blind.module-name module-doc", hidden_module);
    // A returned name counts as written by the code that called `exports`:
    // run as a word, it resolves in that code's root.
    try expectOk(runtime, "(7) `answer def");
    try expectStack(runtime, "`shared exports 0 at execute", "7");
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
        std.testing.expect(large_growth <= small_growth + 4096) catch |err| {
            std.debug.print("module reload under tasks: small_growth={d} large_growth={d}\n", .{ small_growth, large_growth });
            return err;
        };
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "word cells: a reload reaches a dotted name that has already run" {
    // PENDING: Patch 12
    // Session code runs a dotted module word, the module is reloaded with a
    // different definition, and the same code runs again. Expect the new
    // definition.
    return error.SkipZigTest;
}

test "word cells: a definition replacing an import reaches a word that has already run" {
    // PENDING: Patch 12
    // A session word runs an imported word, then a session definition of the
    // same name replaces the import. Expect the session word to run the new
    // definition.
    return error.SkipZigTest;
}

test "word cells: a session definition shadowing core reaches session code that ran the core word" {
    // PENDING: Patch 12
    // A session word runs a core word, then the session defines that name.
    // Expect the session word to run the session definition.
    return error.SkipZigTest;
}

test "word cells: a reload that adds a name shadows the core word its module's code already ran" {
    // PENDING: Patch 12
    // A module word runs a core word, then the module is reloaded with a
    // definition of that name. Expect the module's code to run the module's
    // definition.
    return error.SkipZigTest;
}

test "word cells: redefinition under running tasks keeps live memory bounded" {
    // PENDING: Patch 12
    // Tasks run a session word while it is redefined many times. Expect
    // requested memory, once the tasks' turns end and retirement settles,
    // bounded independently of the number of redefinitions.
    return error.SkipZigTest;
}
