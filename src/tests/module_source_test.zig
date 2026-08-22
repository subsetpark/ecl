//! Module behavior driven entirely through session source.
//!
//! These tests hand a `Session` nothing but source strings, so they take the
//! traceless session heap from `test_heap.zig` rather than
//! `std.testing.allocator`: leak and invalid-free detection without a stack
//! trace on every allocation. That is not a cosmetic choice. The same-home TCO
//! walk below drives twenty thousand activations, and tracing every allocation
//! along the way cost 15.4s against 4.2s untraced — most of this file's former
//! runtime, spent recording provenance no assertion here reads.
//!
//! Its sibling `module_test.zig` keeps the tests whose allocator is
//! load-bearing: the ones that build a value on the host and publish it into a
//! session, where value and session must agree, and the ones that own a
//! counting allocator to state a memory bound.
const std = @import("std");
const intern = @import("../intern.zig");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    const outcome = try runtime.runUnit("module-source-test.ecl", source);
    switch (outcome) {
        .ok => {},
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.debug.print("unexpected ecl error: {s}\n", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
        .incomplete => return error.UnexpectedIncomplete,
    }
}

fn containsCandidate(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

/// Reflective name listings are sorted and duplicate-free wherever they are
/// observed, so both module suites state it the same way.
fn expectSortedUnique(items: []const []const u8) !void {
    for (items[1..], items[0..items.len -| 1]) |current, previous| {
        try std.testing.expect(std.mem.order(u8, previous, current) == .lt);
    }
}

/// Observation must not intern a name it merely looked for.
fn expectInternMissing(bytes: []const u8) !void {
    var lookup = intern.lookupCursor(bytes);
    while (true) switch (lookup.advance()) {
        .pending => {},
        .complete => |found| {
            try std.testing.expectEqual(@as(?u32, null), found);
            return;
        },
    };
}

fn expectErrorContains(
    runtime: *session.Session,
    source: []const u8,
    needles: []const []const u8,
) !void {
    const outcome = try runtime.runUnit("module-source-test.ecl", source);
    const failure = switch (outcome) {
        .err => |item| item,
        .ok => return error.ExpectedLanguageError,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), needle) != null);
}

test "binding: set installs and replaces values while let is absent" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "1 'x set x 2 'x set x");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "3 'y let", &.{ "'kind 'undefined-word", "'word 'let" });
    try expectErrorContains(&runtime, "3 'bad def", &.{ "'kind 'type", "use set for values" });
}

test "scope: isolated @attempt and child import do not leak" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectErrorContains(&runtime, "(1 'k set) @attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "((1 'k set missing) @attempt pop) @attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectOk(&runtime, "(7 'x set) 'm @defm");
    try expectErrorContains(&runtime, "('m.x 'x import x) @attempt pop x", &.{ "'kind 'undefined-word", "'word 'x" });
}

test "module: privacy module-body contract top-level private and qualified trace" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @defm m.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "((41) ( -- n ) 'g defp (g 1 +) ( -- n ) 'f def) 'private-word @defm private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "private-word.g", &.{ "'kind 'undefined-word", "'word 'private-word.g" });
    try expectErrorContains(&runtime, "1 'x setp", &.{ "'kind 'domain", "defp/setp" });
    // A body that leaves values behind registers: they become the slot's
    // durable stack, not bindings, so no name appears for them.
    try expectOk(&runtime, "(1) 'bad @defm");
    try expectErrorContains(&runtime, "bad.x", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "((1 'hidden set) @attempt pop) 'temporary @defm");
    try expectErrorContains(&runtime, "temporary.hidden", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "((missing) ( -- n ) 'boom def) 'trace-module @defm");
    try expectErrorContains(&runtime, "trace-module.boom", &.{ "'word 'missing", "'trace ['missing 'trace-module.boom]" });
    try expectOk(&runtime, "((dup 0 > (1 - f 1 +) (pop missing) if) ( n -- n ) 'f def) 'recursive @defm");
    try expectErrorContains(&runtime, "2 recursive.f", &.{"'trace ['missing 'recursive.f 'recursive.f 'recursive.f]"});
}

test "modules: removal strips aliases and leaves no half-removed entry" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "((1) 'x def) 'a @defm ((2) 'x def) 'b @defm " ++
        "'short 'a alias 'a.x 'x import short.x a.x x");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try expectOk(&runtime, "'a unmodule");
    // The canonical name and every alias targeting it go in one publish.
    try expectErrorContains(&runtime, "a.x", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "short.x", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "'short.x 'x import", &.{"'kind 'undefined-word"});
    // Enumeration never shows a half-removed entry, and unrelated modules
    // and their aliases are untouched.
    try expectOk(&runtime, "'other 'b alias other.x b.x");
    // Re-aliasing a removed name is a missing-module error as before.
    try expectErrorContains(&runtime, "'again 'a alias", &.{"'kind 'undefined-word"});
}

test "module: qualified import replacement and alias collisions" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(1 'x set) 'a @defm (2 'x set) 'b @defm " ++
        "'a.x 'x import 'b.x 'x import x 'a.x 'x import x 'short 'a alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "'a 'b alias", &.{"'kind 'domain"});
    try expectOk(&runtime, "'short 'b alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[3].int);
    try expectErrorContains(&runtime, "'future 'a alias (3 'x set) 'future @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'dotted.name 'a alias", &.{"'kind 'domain"});
}

test "module: provisional tasks keep rollback generations alive until quiescence" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initWithConfig(
        backing.allocator(),
        &.{},
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "((((1) () while) @spawn pop missing) 'bad @defm) @attempt pop");
}

test "module: hot reload commit failure and whole-body pinning" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(1 'x setp " ++
        "((2 'x setp (x) ( -- n ) 'get def) 'm @defm x) ( -- n ) 'probe def " ++
        "(x) ( -- n ) 'get def) 'm @defm m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "(3 'x setp missing) 'm @defm", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "m.get");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "((9) ( -- n ) 'get def) 'kept @defm missing", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "kept.get");
    try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[3].int);
}

test "module: effect shape cross-home contract and same-home TCO" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // A module word may omit its annotation entirely; only a malformed
    // recognized annotation is 'domain.
    try expectOk(&runtime, "((dup) 'f def) 'fine @defm");
    try expectErrorContains(&runtime, "((dup) (a -- b -- c) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "((dup) (a 1 -- b) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectOk(&runtime, "((dup 0 > (1 - countdown) (pop) if) ( n -- ) 'countdown def) 'm @defm");
    try expectOk(&runtime, "20 m.countdown");
    const shallow_frames = runtime.lastMaxFrames();
    try expectOk(&runtime, "20000 m.countdown");
    try std.testing.expectEqual(shallow_frames, runtime.lastMaxFrames());
    try expectErrorContains(&runtime, "((dup +) ( a -- b c ) 'f def) 'lies @defm 1 lies.f", &.{ "'kind 'contract", "'word 'lies.f" });
    try expectErrorContains(&runtime, "((dup) ( a -- a a ) 'f def) 'needs @defm needs.f", &.{ "'kind 'contract", "seeded 0" });
    try expectErrorContains(&runtime, "((missing) ( -- n ) 'f def) 'throws @defm throws.f", &.{ "'kind 'undefined-word", "'word 'missing" });
    try expectOk(&runtime, "(dup +) 'session-double def 4 session-double");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[runtime.stackItems().len - 1].int);
}

test "module: import explicitly replaces one binding and preserves metadata" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        backing.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "(3 'mean set (4) ( -- n : \"Count.\") 'count def 5 'other set) 'stats @defm " ++
        "1 'mean set 'stats.mean 'mean import mean 'stats.count 'count import count " ++
        "'count doc \"Count.\" match? 'count body (stats.count) match? 'count see");
    try std.testing.expectEqualStrings("", diagnostics.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(stats.count) (-- n : \"Count.\") 'count def") != null);
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 4), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[3].int);
    try expectErrorContains(&runtime, "'count 'stats.count import", &.{
        "'kind 'domain",
        "import binding must be unqualified",
    });
    try expectErrorContains(&runtime, "'stats 'local import", &.{
        "'kind 'domain",
        "import original must be a qualified word",
    });
    try expectErrorContains(&runtime, "'result use", &.{
        "'kind 'undefined-word",
        "'word 'use",
    });
}

test "reflection: which and see expose home shadow and effect" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        backing.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @defm 'm.f 'f import " ++
        "'m.f see 9 'f set 'f which 'f see words");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(s 2 +) (-- n) 'm.f def") != null);
    // One binding kind: a session constant reports as a public def with no
    // metadata, because the sugar supplies none, and `see` prints the stored
    // literal capture rather than reconstructing the `set` spelling.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "f -> f def public") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "shadows m.f") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([9] first) 'f def") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " s ") == null);
    try expectErrorContains(&runtime, "'m.f body call", &.{ "'kind 'undefined-word", "'word 's" });
}

test "reflection: body extraction loses home context" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @defm");
    try expectErrorContains(&runtime, "'m.f body call", &.{ "'kind 'undefined-word", "'word 's" });
}

test "session completion: core names are available before the first unit" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    var candidates = try runtime.completionCandidates("sq");
    defer candidates.deinit();
    try expectSortedUnique(candidates.items());
    try std.testing.expectEqual(@as(usize, 1), candidates.items().len);
    try std.testing.expectEqualStrings("sqrt", candidates.items()[0]);
}

test "session completion: live and registered names are sorted unique" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    const missing_prefix = "completion-prefix-that-must-not-be-interned-47f19";
    try expectInternMissing(missing_prefix);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    try expectOk(
        &runtime,
        "(1 'hidden setp 2 'public set) 'completion-module @defm " ++
            "'completion-module.public 'public import 'cm 'completion-module alias " ++
            "3 'repl-live set",
    );
    var all = try runtime.completionCandidates("");
    defer all.deinit();
    try expectSortedUnique(all.items());
    try std.testing.expect(containsCandidate(all.items(), "repl-live"));
    try std.testing.expect(containsCandidate(all.items(), "sqrt"));
    try std.testing.expect(containsCandidate(all.items(), "public"));
    try std.testing.expect(containsCandidate(all.items(), "completion-module"));
    try std.testing.expect(containsCandidate(all.items(), "cm"));
    try std.testing.expect(!containsCandidate(all.items(), "hidden"));

    var missing = try runtime.completionCandidates(missing_prefix);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.items().len);
    try expectInternMissing(missing_prefix);

    var surviving = try runtime.completionCandidates("repl-live");
    runtime.deinit();
    defer surviving.deinit();
    try std.testing.expectEqualStrings("repl-live", surviving.items()[0]);
}

test "session completion: dotted aliases expose only public exports" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectOk(
        &runtime,
        "(1 'old-public set 2 'private-name setp) 'completion-module @defm " ++
            "'cm 'completion-module alias " ++
            "(3 'new-public set 4 'new-private setp) 'completion-module @defm",
    );
    var canonical = try runtime.completionCandidates("completion-module.");
    defer canonical.deinit();
    try expectSortedUnique(canonical.items());
    try std.testing.expectEqual(@as(usize, 1), canonical.items().len);
    try std.testing.expectEqualStrings("completion-module.new-public", canonical.items()[0]);

    var alias = try runtime.completionCandidates("cm.");
    defer alias.deinit();
    try std.testing.expectEqual(@as(usize, 1), alias.items().len);
    try std.testing.expectEqualStrings("cm.new-public", alias.items()[0]);

    var invalid = try runtime.completionCandidates("cm.new.");
    defer invalid.deinit();
    try std.testing.expectEqual(@as(usize, 0), invalid.items().len);
}

test "loader: load is one unit and preserves file provenance" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        backing.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "10");
    try expectErrorContains(&runtime, "\"test/acceptance/load-rollback.ecl\" load", &.{ "'kind 'undefined-word", "'word 'missing" });
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), runtime.stackItems()[0].int);
    try std.testing.expectEqualStrings("side", output.written());
    try expectOk(&runtime, "persist");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try expectOk(&runtime, "loaded.answer");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[2].int);
    try expectOk(&runtime, "(\"test/acceptance/load-stack.ecl\" load) @attempt pop");
    try expectOk(&runtime, "\"test/acceptance/load-provenance.ecl\" load");
    try expectErrorContains(&runtime, "loaded-boom", &.{ "'word 'missing", "'source \"test/acceptance/load-provenance.ecl\"" });
    try expectOk(&runtime, "\"test/acceptance/load-stack.ecl\" load");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[3].int);
    try std.testing.expectEqualStrings("side", output.written());
}

test "loader: ECL_PATH loads first candidate and retries import" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    const search = try std.fmt.allocPrint(
        std.testing.allocator,
        "test/acceptance/path-first{c}test/acceptance/path-second",
        .{std.fs.path.delimiter},
    );
    defer std.testing.allocator.free(search);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        backing.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = search,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "('attempted.answer 'answer import answer) @attempt pop attempted.answer");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "answer", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'stats.answer 'answer import answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);

    var no_path = try session.Session.initWithHost(
        backing.allocator(),
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = "",
        },
    );
    defer no_path.deinit();
    try expectErrorContains(&no_path, "'stats.answer 'answer import", &.{ "'kind 'undefined-word", "'name 'stats.answer" });
}

test "modules: module set and setp publish unannotated constants" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(backing.allocator(), &.{}, &output.writer);
    defer runtime.deinit();
    // Registration succeeding is itself the proof that a module definition
    // may carry no effect at all: `set` publishes the bare literal capture,
    // so constants need no value exception and no synthesized metadata.
    try expectOk(&runtime, "(7 'x set 8 'h setp (h) (-- n) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x m.peek");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[1].int);
    // Privacy is unchanged, and the published effect is visible to
    // reflection exactly as a hand-written one would be.
    try expectErrorContains(&runtime, "m.h", &.{ "'kind 'undefined-word", "'word 'm.h" });
    try expectOk(&runtime, "'m.x which 'm.x see");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "m.x -> m.x def public") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- value)") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([7] first) 'm.x def") != null);
}

test "modules: cross-home constant references cross unchecked while declared effects still bind" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // A constant reached across a home boundary declares no effect, so no
    // check frame is installed at all: qualified access, imported access, and
    // module-internal access agree without one.
    try expectOk(&runtime, "(7 'x set 8 'h setp (h) (-- n) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x 'm.x 'x import x m.peek");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[2].int);
    // The frame is a real contract for `(-- value)` declarations: a module
    // word declaring it and leaving two values is a contract violation.
    try expectErrorContains(
        &runtime,
        "((1 2) (-- value) 'two def) 'liar @defm liar.two",
        // Seeded/observed are absolute stack depths, so assert the parts that
        // do not depend on what this session left on the stack.
        &.{ "'kind 'contract", "'word 'liar.two", "declared (0 -- 1)" },
    );
}
