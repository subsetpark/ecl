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

test "word cells: a quotation applied in another source reaches a module only its own source may see" {
    // PENDING: Patch 6
    // Under a module map, a source that may see module `m` passes a quotation
    // with a dotted `m.` word to code of a source that may not. Expect the
    // quotation to run `m`'s word there.
    return error.SkipZigTest;
}

test "word cells: a quotation applied in another source does not gain the modules that source may see" {
    // PENDING: Patch 6
    // A source that may not see module `m` passes a quotation with a dotted
    // `m.` word to code of a source that may. Expect `undefined-word` when
    // the quotation is applied.
    return error.SkipZigTest;
}

test "word cells: a qualified symbol built at run time resolves as the code that built it" {
    // PENDING: Patch 6
    // Code of one source builds a dotted symbol with `symbol` and hands it to
    // another source to `execute`. Expect the module visibility of the source
    // that built it.
    return error.SkipZigTest;
}

test "word cells: a session import resolves as the source of the word that uses it" {
    // PENDING: Patch 6
    // Two sources write into the session root with different module
    // visibility, and one imports a module word. Expect a use of the imported
    // word to resolve under the visibility of the source the use is written
    // in.
    return error.SkipZigTest;
}

test "word cells: exports resolves its module as the source of its operand" {
    // PENDING: Patch 6
    // A source that may see module `m` passes the symbol `m` to code of a
    // source that may not, which calls `exports` on it. Expect `m`'s exports.
    return error.SkipZigTest;
}

test "word cells: a reload reaches a plain word of the module that has already run" {
    // PENDING: Patch 7
    // A module word calls a helper of its module by its plain name and has
    // run once. Reload the module with a different helper. Expect code of the
    // earlier registration that is still reachable to run the new helper.
    return error.SkipZigTest;
}

test "word cells: a quotation that escaped a module resolves in the module's current registration" {
    // PENDING: Patch 7
    // A module word returns a quotation that calls a private word of the
    // module. Reload the module, then apply the quotation. Expect the private
    // word of the current registration.
    return error.SkipZigTest;
}

test "word cells: reloading a module under running tasks keeps live memory bounded" {
    // PENDING: Patch 10
    // Tasks run a module's words while the module is reloaded many times.
    // Expect requested memory, once the tasks' turns end and retirement
    // settles, bounded independently of the number of reloads.
    return error.SkipZigTest;
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
