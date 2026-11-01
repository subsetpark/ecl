const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const intern = @import("../intern.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("definition-test.ecl", source)) {
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

fn expectErrorContains(runtime: *session.Session, source: []const u8, text: []const u8) !void {
    const failure = switch (try runtime.runUnit("definition-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), text) != null);
}

test "bound call sites keep their targets across rebinding and core shadowing" {
    try support.expectStack(
        "1 `cached-value set (cached-value) `probe def " ++
            "probe probe 2 `cached-value set probe cached-value " ++
            "(4 dup +) `core-probe def core-probe core-probe " ++
            "(10) `dup def core-probe dup",
        "1 1 1 2 8 8 8 10",
    );
}

test "plain call sites remain correct after observation pool and cache churn" {
    try support.expectStack(
        "1 `outside set (outside) `probe def probe probe probe " ++
            "3 (" ++ support.repeated("outside pop ", 32) ++ ") times " ++
            "2 `outside set probe",
        "1 1 1 1",
    );
}

test "definition annotations support all top-level forms and dynamic data" {
    try support.expectStack(
        "(1) `plain def " ++
            "(-- out) (2) `effect-only def " ++
            "(: \"Documented.\") (3) `doc-only def " ++
            "(x -- y : \"Square a numeric value.\") (dup *) `square def " ++
            "(: \"Built as data.\") `annotation set " ++
            "annotation (5) `dynamic def " ++
            "plain effect-only doc-only 4 square dynamic " ++
            "`doc-only doc `square doc `dynamic doc",
        "1 2 3 16 5 \"Documented.\" \"Square a numeric value.\" \"Built as data.\"",
    );
    try support.expectErrors(&.{
        .{ .name = "no documentation", .source = "(-- x) (1) `x def `x doc", .kind = "domain", .word = "doc" },
        .{ .name = "missing binding", .source = "`absent doc", .kind = "undefined-word", .word = "absent" },
    });
    try support.expectStack(
        "(a -- b c : \"Reflective only.\") (dup +) `top-level-lie def 4 top-level-lie",
        "8",
    );
}

test "every primitive exposes meaningful reflective documentation" {
    const names = [_][]const u8{
        "dup",        "swap",        "pop",          "over",           "rollup",         "rolldown",
        "cons",       "compose",     "match?",       "type",           "parse",          "chars",
        "bytes",      "symbol",      "intern",       "int",            "float",          "char",
        "@attempt",   "raise",       "args",         "exit",           "dip",            "call",
        "if",         "while",       "times",        "cond",           "each",           "zip-with",
        "for",        "fold",        "scan",         "stencil",        "unfold",         "infra",
        "def",        "set",         "defp",         "setp",           "test",           "tests",
        "@test",      "effect",      "exports",      "doc",            "which",          "see",
        "@defm",      "import",      "alias",        "words",          "load",           "@spawn",
        "task.await", "task.cancel", "task.pending", "task.await-any", "task.await-for", "@each",
        "+",          "-",           "*",            "/",              "div",            "mod",
        "pow",        "atan2",       "min",          "max",            "=",              "<>",
        "<",          ">",           "<=",           ">=",             "and",            "or",
        "neg",        "abs",         "sqrt",         "floor",          "ceil",           "round",
        "exp",        "log",         "sin",          "cos",            "not",            "at",
        "where",      "first-where", "in?",          "raze",           "cat",            "take",
        "drop",       "reverse",     "first",        "rest",           "range",          "shape",
        "len",        "flip",        "reshape",      "cmp",            "grade",          "distinct",
        "group",      "put",         "update",       "del",            "split",          "join",
        "str",        "band",        "bor",          "bxor",           "bsl",            "bsr",
        "bnot",       "stack",       "cut",          "+%",             "-%",             "*%",
    };
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer expected.deinit();
    try source.writer.writeAll(
        "`over doc \"Copy the value beneath the top of the stack onto the top.\" match? ",
    );
    try expected.writer.writeByte('1');
    for (names) |name| {
        try source.writer.print("`{s} doc len 0 > ", .{name});
        try expected.writer.writeAll(" 1");
    }

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, source.written());
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected.written(), display.bytes());
    try expectOk(&runtime, "`over see `call see");
    try std.testing.expectEqualStrings(
        "(x y -- x y x : \"Copy the value beneath the top of the stack onto the top.\") (swap dup (swap) dip)\n" ++
            "(quotation -- ... :\n \"*Inline.* Run a quotation on the current stack. A data list pushes its elements.\") <primitive>\n",
        output.written(),
    );
}

test "which reports effect metadata without expanding documentation" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "(x -- y : \"Not part of concise which output.\") (dup *) `square def `square which");
    try std.testing.expectEqualStrings("square -> square def public (x -- y)\n", output.written());
}

test "effect returns a binding's declared effect, or () when it declares none" {
    // `bare` is defined first: a list left by an earlier `effect` would be
    // taken as its optional annotation.
    try support.expectStack(
        "(1) `bare def " ++
            "(x -- y : \"Square.\") (dup *) `square def " ++
            "(--) (1 pop) `quiet def " ++
            "`+ effect `dict.get effect `archive.sha256 effect " ++
            "`square effect `quiet effect `bare effect `def effect",
        "(x y -- z) (dict key default -- value) (bytes -- lowercase-hex) (x -- y) (--) () ()",
    );
}

test "exports lists a module's public words and stdlib the embedded modules" {
    try support.expectStack(
        "`archive exports " ++
            "`core exports (`effect match?) any? " ++
            "[] ((1) `shown def (2) `hidden defp) `m @defm `m exports " ++
            "stdlib (`dict match?) any?",
        "(next-member open-tgz read-member sha256 unpack-tgz) 1 (shown) 1",
    );
    try support.expectErrors(&.{
        .{ .name = "unknown module", .source = "`no-such-module exports", .kind = "undefined-word", .word = "exports" },
        .{ .name = "invalid module name", .source = "`... exports", .kind = "domain", .word = "exports" },
    });
}

test "invocation effects: which reports public task word contracts" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "`task.await which `task.cancel which `task.pending which `task.await-any which `task.await-for which");
    try std.testing.expectEqualStrings(
        "task.await -> task.await primitive public generation 1 (task -- result)\n" ++
            "task.cancel -> task.cancel primitive public generation 1 (task --)\n" ++
            "task.pending -> task.pending primitive public generation 1 (-- tasks)\n" ++
            "task.await-any -> task.await-any primitive public generation 1 (tasks -- index result)\n" ++
            "task.await-for -> task.await-for primitive public generation 1 (task milliseconds -- result)\n",
        output.written(),
    );
}

test "invocation effects: task completion precedes caller continuation" {
    try support.expectStack(
        "task.pending pop " ++
            "[] (7) @spawn dup task.await pop 0 task.await-for pop " ++
            "[] (8) @spawn dup pair task.await-any pop pop " ++
            "[] ((1) () while) @spawn dup task.cancel task.await pop " ++
            "[] (( -- result ) ([] (9) @spawn task.await) `wait def) `nested @defm " ++
            "nested.wait pop 42",
        "42",
    );
    try support.expectErrors(&.{
        // A standard-library word has no boundary effect check: too few
        // values are the builtin's own underflow.
        .{ .name = "entry underflow", .source = "task.await", .kind = "underflow", .word = "task.await" },
        .{ .name = "primitive failure", .source = "3 task.await", .kind = "type", .word = "task.await" },
        .{ .name = "driver failure", .source = "[3] task.await-any", .kind = "type", .word = "task.await-any" },
    });
}

test "module annotations retain contracts documentation qualification and shadowing" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (" ++
        "(-- n : \"Public module word.\") (1) `public def " ++
        "(-- n : \"Private module word.\") (2) `private defp " ++
        "(-- text : \"Expose private documentation.\") (`private doc) `private-doc def" ++
        ") `m @defm " ++
        "`m (public) import `public doc \"Public module word.\" match? " ++
        "m.private-doc \"Private module word.\" match? " ++
        "(-- n : \"Session shadow.\") (9) `public def " ++
        "`public doc \"Session shadow.\" match? " ++
        "`m.public doc \"Public module word.\" match?");
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("1 1 1 1", display.bytes());
    try expectErrorContains(&runtime, "`m.private doc", "kind undefined-word");
    // A documentation-only module word is one of the four legal forms, and
    // its documentation is what reflection reports.
    try expectOk(&runtime, "[] ((: \"Documentation only.\") (1) `f def) `docs @defm " ++
        "`docs.f doc \"Documentation only.\" match? pop");
    try expectErrorContains(&runtime, "[] ((a -- b c : \"An intentionally false contract.\") (dup +) `f def) `lies @defm 1 lies.f", "kind contract");
}

test "multiline documentation is normalized and see prints annotation and canonical body" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "(x -- y : \"Square a numeric value.\") (dup *) `square def " ++
        "(: \"Only docs.\") (42) `answer def " ++
        "(: \"  First line wraps\n    softly.\n\n  - One\n    continues\n  - Two.\") (1) `multiline def " ++
        "`multiline doc \"First line wraps softly.\n\n- One continues\n- Two.\" match? " ++
        "`square see `answer see `multiline see");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    // `see` writes documentation as prose: its paragraph and item breaks are
    // real line breaks, not the `\n` the canonical string rendering spells.
    try std.testing.expectEqualStrings(
        "(x -- y : \"Square a numeric value.\") (dup *)\n" ++
            "(: \"Only docs.\") (42)\n" ++
            "(:\n \"First line wraps softly.\n\n- One continues\n- Two.\") (1)\n",
        output.written(),
    );
}

test "see retains source locals while execution uses their lowered body" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();

    // Define and reflect in separate units: the binding, rather than the
    // already-retired input turn, owns the shared source slice.
    try expectOk(&runtime, "(n -- n : \"Increment.\") (|x| x 1 +) `inc def");
    try expectOk(&runtime, "`inc see");
    try std.testing.expectEqualStrings(
        "(n -- n : \"Increment.\") (|x| x 1 +)\n",
        output.written(),
    );
}

test "redefinition and set replace behavior and clear metadata" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "(-- n : \"Old metadata.\") (1) `lease-target def");
    try expectOk(&runtime, "(2) `lease-target def");
    try expectOk(&runtime, "lease-target 2 match?");
    try expectErrorContains(&runtime, "`lease-target doc", "kind domain");

    try expectOk(&runtime, "(-- n : \"Temporary.\") (3) `set-target def 9 `set-target set");
    try expectOk(&runtime, "set-target 9 match?");
    try expectErrorContains(&runtime, "`set-target doc", "kind domain");
}

test "recognized malformed annotations are domain errors" {
    try support.expectErrors(&.{
        .{ .name = "duplicate separator", .source = "(a -- b -- c) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "duplicate colon", .source = "(: \"a\" : \"b\") (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "separator after colon", .source = "(: \"a\" -- b) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "nonword input", .source = "(1 -- b) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "nonword output", .source = "(a -- 1) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "colon not first without effect", .source = "(a : \"doc\") (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "missing doc", .source = "(:) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "nonstring doc", .source = "(: 1) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "extra doc", .source = "(: \"a\" \"b\") (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "combined missing doc", .source = "(a -- b :) (1) `x def", .kind = "domain", .word = "def" },
        .{ .name = "combined extra doc", .source = "(a -- b : \"a\" \"b\") (1) `x def", .kind = "domain", .word = "def" },
    });
}

test "nested and quoted markers remain body data" {
    try support.expectStack(
        "((-- :) `-- `:) `inert def inert " ++
            "(-- :) `markers set markers " ++
            "[] ((-- :) `private-markers setp " ++
            "(-- value : \"Return private marker data.\") (private-markers) `get def) `m @defm m.get",
        "(-- :) -- : (-- :) (-- :)",
    );
}

test "reserved namespace names reject every binding surface but remain readable" {
    try support.expectErrors(&.{
        .{ .name = "definition", .source = "(1) `-- def", .kind = "domain", .word = "def" },
        // set is prelude sugar, so the reserved-name check raises from the
        // def it calls, with set as the trace parent.
        .{ .name = "value", .source = "1 `: set", .kind = "domain", .word = "def" },
        .{ .name = "local separator", .source = "1 (|--| --)", .kind = "parse" },
        .{ .name = "local colon", .source = "1 (|:| :)", .kind = "parse" },
        // @defm validates its name before the body runs.
        .{ .name = "@defm", .source = "[] () `-- @defm", .kind = "domain", .word = "@defm" },
        .{ .name = "alias", .source = "[] () `m @defm `-- `m alias", .kind = "domain", .word = "alias" },
        // The exact name `core` is the core qualifier, so neither publication
        // surface may claim it; `core.utils` remains an ordinary module name.
        .{ .name = "@defm core", .source = "[] () `core @defm", .kind = "domain", .word = "@defm" },
        .{ .name = "alias core", .source = "[] () `m @defm `core `m alias", .kind = "domain", .word = "alias" },
        .{ .name = "public export", .source = "[] ((-- x) (1) `-- def) `m @defm", .kind = "domain", .word = "def" },
        .{ .name = "private value", .source = "[] (1 `: setp) `m @defm", .kind = "domain", .word = "defp" },
        .{ .name = "unset is not a word", .source = "`x unset", .kind = "undefined-word", .word = "unset" },
        .{ .name = "undef is not a word", .source = "`x undef", .kind = "undefined-word", .word = "undef" },
        .{ .name = "undefm is not a word", .source = "`m undefm", .kind = "undefined-word", .word = "undefm" },
        .{ .name = "bare reserved word is readable", .source = "--", .kind = "undefined-word", .word = "--" },
    });
    try support.expectStack("`-- `: (-- :) `x:y", "-- : (-- :) x:y");
    try support.expectStack("(1) `name--part def (2) `name:part def name--part name:part", "1 2");

    try std.testing.expectError(
        error.InvalidName,
        intern.namespaceName(try intern.intern("--")),
    );
    try std.testing.expectError(
        error.InvalidName,
        intern.namespaceName(try intern.intern(":")),
    );
}

test "long annotation traversal and reflection observe cancellation" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var runtime_inputs8 = try runtime_fixture.Fixture.init();
    defer runtime_inputs8.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs8.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const marker = try intern.intern("--");
    const name = try intern.intern("value");
    const items = try allocator.alloc(value.Value, 70_000);
    defer allocator.free(items);
    @memset(items, .{ .symbol = .{ .name = name } });
    items[0] = .{ .symbol = .{ .name = marker } };
    const annotation = try list.fromValuesGeneric(allocator, items);
    try runtime.pushOwned(annotation);
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try runtime.pushOwned(body);
    runtime.requestCancellation();
    try expectErrorContains(&runtime, "`cancelled-definition def", "unit cancelled");
    try std.testing.expect(runtime.lastPolls() >= 1);
    runtime.clearCancellation();
    try expectErrorContains(&runtime, "cancelled-definition", "kind undefined-word");

    var runtime_inputs9 = try runtime_fixture.Fixture.init();
    defer runtime_inputs9.deinit();
    var doc_runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs9.inputs(.{}), .default, .evaluate);
    defer doc_runtime.deinit();
    const doc_codepoints = try allocator.alloc(u32, 70_000);
    defer allocator.free(doc_codepoints);
    @memset(doc_codepoints, 'd');
    const cancellable_doc = try list.fromCodepoints(allocator, doc_codepoints);
    defer cleanup.releaseValue(cancellable_doc);
    const doc_annotation = try list.fromValuesGeneric(allocator, &.{
        .{ .symbol = .{ .name = try intern.intern(":") } },
        cancellable_doc,
    });
    try doc_runtime.pushOwned(doc_annotation);
    const doc_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try doc_runtime.pushOwned(doc_body);
    doc_runtime.requestCancellation();
    try expectErrorContains(&doc_runtime, "`cancelled-doc def", "unit cancelled");
    try std.testing.expect(doc_runtime.lastPolls() >= 1);
    doc_runtime.clearCancellation();
    try expectErrorContains(&doc_runtime, "cancelled-doc", "kind undefined-word");

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var runtime_inputs10 = try runtime_fixture.Fixture.init();
    defer runtime_inputs10.deinit();
    var reflection_runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs10.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer reflection_runtime.deinit();
    const long_doc = try allocator.alloc(u8, 70_000);
    defer allocator.free(long_doc);
    @memset(long_doc, 'd');
    const long_definition = try std.fmt.allocPrint(allocator, "(: \"{s}\") (1) `long-doc def", .{long_doc});
    defer allocator.free(long_definition);
    try expectOk(&reflection_runtime, long_definition);
    reflection_runtime.requestCancellation();
    try expectErrorContains(&reflection_runtime, "`long-doc see", "unit cancelled");
    try std.testing.expect(reflection_runtime.lastPolls() >= 1);

    var runtime_inputs11 = try runtime_fixture.Fixture.init();
    defer runtime_inputs11.deinit();
    var name_runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs11.inputs(.{}), .default, .evaluate);
    defer name_runtime.deinit();
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 'n');
    const long_name = try intern.intern(name_bytes);
    try name_runtime.pushOwned(try list.fromValuesGeneric(allocator, &.{}));
    try name_runtime.pushOwned(.{ .symbol = .{ .name = long_name } });
    name_runtime.requestCancellation();
    try expectErrorContains(&name_runtime, "def", "unit cancelled");
    try std.testing.expect(name_runtime.lastPolls() >= 1);
    name_runtime.clearCancellation();
    const lookup_source = try std.fmt.allocPrint(allocator, "`{s} doc", .{name_bytes});
    defer allocator.free(lookup_source);
    try expectErrorContains(&name_runtime, lookup_source, "kind undefined-word");
}

// ── Milestone 10 (one-definition-merge) ──────────────────────────────────────
// The merge makes `v 'name set` observationally `v literal wrap 'name def`:
// bindings have one kind, bare reference always applies a stored body, and
// a "value" is a word whose body is the literal capture: `(v)`, or
// `(`v)` for a word `v`. Since M11 made source annotations optional
// everywhere, the sugar synthesizes no metadata at all and the equivalence is
// exact.

test "definitions: set publishes a literal-capture word with no synthesized metadata" {
    // A constant is a word whose body is the literal capture, so referencing
    // it applies that body and pushes exactly the captured value. The capture
    // is inert for every kind of value: a quotation is pushed rather than run,
    // and a bare word stays data rather than resolving.
    try support.expectStack("3 `x set x", "3");
    try support.expectStack("(dup *) `q set q", "(dup *)");
    try support.expectStack("(dup) first `w set w", "dup");
    try support.expectStack("{a 1} `d set d", "{a 1}");
    // Rebinding replaces the whole snapshot, capture and all.
    try support.expectStack("3 `x set 4 `x set x", "4");
}

test "definitions: which reports a def while see prints the set capture body" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // Reflection reports what is stored: one kind, and no metadata, because
    // the sugar supplies none. `which` reports the public def while `see`
    // prints only its stored literal-capture body.
    try expectOk(&runtime, "3 `x set `x which `x see");
    try std.testing.expectEqualStrings(
        "x -> x def public\n" ++
            "[3]\n",
        output.written(),
    );
}

test "definitions: set distinguishes binding annotations from captured data" {
    // The guarantee is now mechanical rather than a mode test: the sugar
    // wraps its value before def sees it, so a captured marker list is
    // always nested one level down, and nested markers are inert.
    try support.expectStack("(-- :) `markers set markers", "(-- :)");
    try support.expectStack("(: \"doc\") `ann set ann", "(: \"doc\")");
    try support.expectStack("(a -- b) `eff set eff", "(a -- b)");
    try support.expectStack(
        "(: \"Documented constant.\") 7 `answer set answer `answer doc",
        "7 \"Documented constant.\"",
    );
    try support.expectStack(
        "(: \"Binding documentation.\") (: \"Captured data.\") `annotated-data set " ++
            "annotated-data `annotated-data doc",
        "(: \"Captured data.\") \"Binding documentation.\"",
    );
    // The captured annotation remains ordinary data and never becomes the
    // binding's own documentation or effect.
    try support.expectErrors(&.{
        .{ .name = "captured doc is not documentation", .source = "(: \"doc\") `ann set `ann doc", .kind = "domain", .word = "doc" },
    });
}

test "definitions: top-level setp fails through defp's module-root check" {
    // Privacy is still checked dynamically against the unit's current scope;
    // the sugar just relocates the raiser to the primitive it calls.
    try support.expectErrors(&.{
        .{
            .name = "top-level setp",
            .source = "1 `x setp",
            .kind = "domain",
            .word = "defp",
            .message = "defp/setp are legal only in a module root",
        },
        .{
            // An application is not a root even inside a module body, so
            // nothing defines there, privately or otherwise.
            .name = "setp inside an application",
            .source = "[] ([1] (pop 1 `x setp) each) `m @defm",
            .kind = "domain",
            .word = "defp",
        },
    });
}

test "definitions: data-combinator applications resolve their words across elements" {
    try support.expectStacks(&.{
        // A source word and a builtin, across more applications than it takes
        // the call-site cache to warm.
        .{ .name = "source and builtin", .source = "(dup *) `sq def [1 2 3 4 5] (sq 1 +) each", .expected = "[2 5 10 17 26]" },
        // The binding a call keeps is the one in effect when the call began.
        .{ .name = "next call", .source = "(1) `k def [1 2] (pop k) each (2) `k def [1 2] (pop k) each", .expected = "[1 1] [2 2]" },
    });
    // A call that fails after keeping bindings releases them with the call.
    try support.expectError(.{
        .name = "failure after kept bindings",
        .source = "(dup *) `sq def [1 2 x] (sq 1 +) each",
        .kind = "type",
    });
}

test "definitions: def inside a word body writes the caller's scope" {
    // The invariant licensing prelude placement of set/setp: a word whose
    // body calls def publishes into the *unit's current scope*, never the
    // executing frame's resolution environment (core is frozen after prelude
    // installation).

    // At top level the definition lands in the session environment and
    // outlives the helper that made it.
    try support.expectStack(
        "( -- ) ((-- n) (1) `made-here def) `maker def maker made-here",
        "1",
    );

    // Inside a module body it lands in the module root — which is exactly
    // how the core words set and setp publish module constants, including
    // the privacy distinction. Module bodies resolve against the module's
    // own chain, so only core words (not session helpers) can be used here.
    try support.expectStack("[] (7 `x set 8 `h setp (-- n) (h) `peek def) `m @defm m.x m.peek", "7 8");
    try support.expectErrors(&.{
        .{ .name = "private stays private", .source = "[] (8 `h setp) `m @defm m.h", .kind = "undefined-word", .word = "m.h" },
    });

    // The same word called inside an application is refused: an
    // application is not a root, so there is nowhere for the name to land.
    try support.expectErrors(&.{
        .{
            .name = "inside an application",
            .source = "( -- ) ((-- n) (1) `scoped def) `h def [1] (pop h) each",
            .kind = "domain",
            .word = "def",
        },
    });
}

test "definitions: body is not a word and one binding kind needs no extraction" {
    // Nothing lifts a published body out of the home it resolves against, so
    // a label can never be re-sited and a private cannot be reached by
    // dissecting a public.
    try support.expectErrors(&.{
        .{ .name = "set-bound", .source = "3 `x set `x body", .kind = "undefined-word", .word = "body" },
        .{ .name = "def-bound", .source = "(1) `f def `f body", .kind = "undefined-word", .word = "body" },
        .{ .name = "builtin", .source = "`def body", .kind = "undefined-word", .word = "body" },
    });
    // The invariant `body` used to observe is unchanged and still observable.
    // `see` renders only the stored body, so a constant is visibly a word whose
    // body is the literal capture, and a definition visibly is not.
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "3 `x set `x see (dup *) `sq def `sq see");
    try std.testing.expectEqualStrings(
        "[3]\n" ++
            "(dup *)\n",
        output.written(),
    );
}

test "seedless unit constructors start on an empty stack" {
    try support.expectStacks(&.{
        .{ .name = "@attempt!", .source = "9 (stack len) @attempt! `ok at", .expected = "9 [0]" },
        .{ .name = "@attempt! failure", .source = "(1 `x raise) @attempt! `err at `kind at", .expected = "type" },
        .{ .name = "@spawn!", .source = "9 (stack len) @spawn! task.await `ok at", .expected = "9 [0]" },
        .{ .name = "@each!", .source = "9 (1 2 3) (stack len nip 10 *) @each!", .expected = "9 [10 10 10]" },
        .{ .name = "@defm!", .source = "9 (stack len `depth set) `m @defm! m.depth", .expected = "9 0" },
    });
    try support.expectErrors(&.{
        .{ .name = "@attempt! underflow", .source = "@attempt!", .kind = "underflow", .word = "@attempt!" },
        .{ .name = "@attempt! body type", .source = "1 @attempt!", .kind = "type", .word = "@attempt!" },
        .{ .name = "@spawn! underflow", .source = "@spawn!", .kind = "underflow", .word = "@spawn!" },
        .{ .name = "@give! underflow", .source = "() @give!", .kind = "underflow", .word = "@give!" },
        .{ .name = "@defm! underflow", .source = "`m @defm!", .kind = "underflow", .word = "@defm!" },
        .{ .name = "@defm! name domain", .source = "() `core @defm!", .kind = "domain", .word = "@defm!" },
        .{ .name = "@spawn! in construction", .source = "((1) @spawn! pop) `m @defm!", .kind = "domain", .word = "@spawn!" },
        .{ .name = "@attempt! isolation", .source = "1 (pop) @attempt! `err at raise", .kind = "underflow", .word = "pop" },
    });
}

test "quotes: one quoted occurrence that pushes its symbol" {
    try support.expectStacks(&.{
        // As data a quote is its symbol: one element, equal to the bare one.
        .{ .name = "shape", .source = "(`a) len [`a `b] len", .expected = "1 2" },
        .{ .name = "equality", .source = "[`a `b] [a b] match? (`a) first (a) first match?", .expected = "1 1" },
        .{ .name = "push", .source = "`a type (`a) call (a) first match?", .expected = "symbol 1" },
        // The quote prints as itself and reads back as the same occurrence.
        .{ .name = "printing", .source = "(`a b `'c d') str", .expected = "\"(`a b `'c d')\"" },
        .{ .name = "round trip", .source = "(`a b) str parse first first wrap call", .expected = "a" },
        // The mark travels with the occurrence; `execute` runs the word.
        .{ .name = "extracted occurrence", .source = "(`a) first wrap call 1 2 (`swap) first execute", .expected = "a 2 1" },
        // A quote in a locals body is the symbol, not the local.
        .{ .name = "locals", .source = "5 (|x| `x x) call", .expected = "x 5" },
        .{ .name = "module body", .source = "[] ((|a| `a) `w def) `quoting @defm 5 quoting.w", .expected = "a" },
        // A quoted operation pushes its symbol; no idiom takes it as the word.
        .{ .name = "no idiom", .source = "[1 2] (pop `+) each", .expected = "(+ +)" },
    });
    try support.expectErrors(&.{
        .{ .name = "dict entry", .source = "{`a 1}", .kind = "parse" },
    });
}

test "strings: plain text and escapes read the same however long the run" {
    // 148 plain characters, past the tokenizer's 64-byte run and the reader's
    // 16-byte scan lanes.
    const long = "abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz0123456789 ";
    try support.expectStacks(&.{
        .{ .name = "empty", .source = "\"\" len", .expected = "0" },
        .{ .name = "long plain", .source = "\"" ++ long ++ "\" len", .expected = "148" },
        // An escape or a non-ASCII character late in a long run takes the
        // codepoint route from the start.
        .{ .name = "late escape", .source = "\"" ++ long ++ "\\n\" len", .expected = "149" },
        .{ .name = "late quote escape", .source = "\"" ++ long ++ "\\\"\" last", .expected = "\\u{22}" },
        .{ .name = "late non-ASCII", .source = "\"" ++ long ++ "\u{e9}\" last", .expected = "\\\u{e9}" },
        .{ .name = "multiple lines", .source = "\"one\ntwo\" len", .expected = "7" },
        .{ .name = "same value", .source = "\"plain\" \"pl\\u{61}in\" match?", .expected = "1" },
    });
    // Positions after a long string are counted per character.
    try support.expectErrors(&.{.{
        .name = "position after a long string",
        .source = "\"" ++ long ++ "\" nope",
        .kind = "undefined-word",
        .word = "nope",
        .data = &.{.{ .name = "col", .expected = .{ .int = 152 } }},
    }});
}

test "reuse: a result never overwrites a value still observed" {
    // Results take over an operand's buffer only when the call holds every
    // reference to it and the kernel's loop permits it at every position the
    // list occupies. Each case keeps or shares the operand; expected values
    // are master's, before reuse was generalized.
    try support.expectStacks(&.{
        .{ .name = "same list twice, also bound", .source = "[1 2 3] `x set x x + x", .expected = "[2 4 6] [1 2 3]" },
        .{ .name = "same list twice, also on the stack", .source = "5 range dup dup + +", .expected = "[0 3 6 9 12]" },
        .{ .name = "right operand kept", .source = "5 range dup 3 + swap", .expected = "[3 4 5 6 7] [0 1 2 3 4]" },
        // A gather over its own indices would read sources it already
        // stored over; the reversed list makes every read cross a store.
        .{ .name = "gather from its own indices", .source = "3 range reverse dup at", .expected = "[0 1 2]" },
        .{ .name = "put into kept list", .source = "5 range dup 2 99 put swap", .expected = "[0 1 99 3 4] [0 1 2 3 4]" },
        // One list as collection, indices, and replacement: a scatter over
        // itself would read replacements it already stored over.
        .{ .name = "vector put from itself", .source = "5 range reverse dup dup put", .expected = "[0 1 2 3 4]" },
        .{ .name = "drop of kept list", .source = "10 range dup 3 drop swap", .expected = "[3 4 5 6 7 8 9] [0 1 2 3 4 5 6 7 8 9]" },
        .{ .name = "cat with itself", .source = "5 range dup cat", .expected = "[0 1 2 3 4 0 1 2 3 4]" },
        .{ .name = "scan of kept list", .source = "10 range dup 0 (+) scan swap", .expected = "[0 1 3 6 10 15 21 28 36 45] [0 1 2 3 4 5 6 7 8 9]" },
        .{ .name = "row fold of kept list", .source = "12 range dup [3 4] reshape sum swap len", .expected = "[12 15 18 21] 12" },
        .{ .name = "del of kept list", .source = "5 range dup 2 del swap", .expected = "[0 1 3 4] [0 1 2 3 4]" },
        // Owned outright, the same operations still compute correctly.
        .{ .name = "owned drop", .source = "1000 range 500 drop sum", .expected = "374750" },
        .{ .name = "owned cat", .source = "1000 range dup 500 drop cat len", .expected = "1500" },
        .{ .name = "owned put", .source = "5 range 2 99 put", .expected = "[0 1 99 3 4]" },
    });
}

// Construction-time binding. A quotation's words carry the root they were
// written in; binding resolves its top-level unquoted words there once, and
// the executable it produces never retargets.

test "binding: top-level source defines then uses, and a definition body cannot forward-reference" {
    try support.expectStack("(1) `foo def foo", "1");
    try support.expectErrors(&.{
        .{ .name = "forward reference", .source = "(later) `early def", .kind = "undefined-word", .word = "later" },
    });
}

test "binding: existing code keeps its targets while later binding sees replacements" {
    try support.expectStacks(&.{
        .{ .name = "plain", .source = "(1) `foo def (foo) `bar def (2) `foo def bar foo", .expected = "1 2" },
        .{
            .name = "qualified",
            .source = "[] ((1) `x def) `a @defm (a.x) `old def [] ((2) `x def) `a @defm old a.x",
            .expected = "1 2",
        },
        // A nested quotation is data until it is applied, so it binds against
        // whatever is current when it runs.
        .{ .name = "nested data", .source = "(1) `x def ((x)) `later def (2) `x def later call", .expected = "2" },
        // Any publication invalidates a reused anonymous binding.
        .{ .name = "reuse", .source = "(x) `q set (1) `x def q call (2) `x def q call", .expected = "1 2" },
    });
}

test "binding: one quotation value bound twice stays unchanged and independent" {
    try support.expectStacks(&.{
        .{
            .name = "shared body",
            .source = "(pop pop 42) dup `derive-epsilon def `derive-empty def 1 2 derive-epsilon 3 4 derive-empty",
            .expected = "42 42",
        },
        .{
            .name = "independent targets",
            .source = "(1) `x def (x) dup `p def (2) `x def `q def p q",
            .expected = "1 2",
        },
    });
}

test "binding: a quotation that cannot bind runs none of its forms" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "\"warm\" io.print");
    try expectErrorContains(&runtime, "(\"ran\" io.print missing) call", "word missing");
    try std.testing.expectEqualStrings("warm\n", output.written());
    // Unexecuted nested data is not rejected for naming nothing.
    try expectOk(&runtime, "((missing)) `f def f len 1 = {kind user} assert");
    try expectErrorContains(&runtime, "f call", "word missing");
}

test "binding: words resolve in the root they were written in" {
    try support.expectStacks(&.{
        // A caller's quotation keeps its own meaning inside a module wrapper.
        .{
            .name = "wrapper",
            .source = "[] ((|q| q call) `apply def) `w @defm (5) `five def (five) w.apply",
            .expected = "5",
        },
        // Equal quotations from different roots bind differently, and reuse
        // never conflates them.
        .{
            .name = "equal data",
            .source = "[] ((7) `k defp ((k)) `q def) `m @defm (1) `k def " ++
                "m.q (k) match? [1 2] (pop m.q call (k) call +) each",
            .expected = "1 [8 8]",
        },
        // `execute` and reflection resolve the supplied symbol in its own root;
        // equality and printing ignore that root.
        .{
            .name = "explicit lookup",
            .source = "[] (( -- n ) (7) `k defp (`k) `sym def) `m @defm (1) `k def " ++
                "m.sym execute k m.sym effect `k effect m.sym `k match? m.sym",
            .expected = "7 1 (-- n) () 1 k",
        },
    });
}

test "binding: imports are name aliases followed at every binding" {
    try support.expectStacks(&.{
        .{
            .name = "alias",
            .source = "[] ((1) `x def) `a @defm `a (x) import (x) `via def [] ((2) `x def) `a @defm via x",
            .expected = "1 2",
        },
        .{
            .name = "re-export",
            .source = "[] ((1) `x def) `a @defm [] (`a (x) import) `b @defm b.x [] ((2) `x def) `a @defm b.x",
            .expected = "1 2",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "alias cycle",
            .source = "[] ((1) `x def) `a @defm [] (`a (x) import) `b @defm [] (`b (x) import) `a @defm b.x",
            .kind = "domain",
            .message_contains = "never reach a definition",
        },
    });
}

test "binding: a module binds as one group when it is sealed" {
    try support.expectStacks(&.{
        .{
            .name = "forward and mutual",
            .source = "[] (( n -- b ) (dup 0 = (pop 1) (1 - odd?) if) `even? def " ++
                "( n -- b ) (dup 0 = (pop 0) (1 - even?) if) `odd? def) `parity @defm 4 parity.even? 3 parity.even?",
            .expected = "1 0",
        },
        .{
            .name = "self-qualified",
            .source = "[] (( -- n ) (self-named.base 1 +) `next def ( -- n ) (41) `base def) `self-named @defm self-named.next",
            .expected = "42",
        },
    });
    try support.expectErrors(&.{
        .{ .name = "duplicate definition", .source = "[] ((1) `x def (2) `x def) `twice @defm", .kind = "domain", .message_contains = "more than once" },
        .{
            .name = "definition and import",
            .source = "[] ((1) `x def) `src @defm [] ((1) `x def `src (x) import) `clash @defm",
            .kind = "domain",
            .message_contains = "more than once",
        },
        // Staged definitions cannot run before the module is sealed.
        .{ .name = "staged", .source = "[] ((1) `x def x pop) `early @defm", .kind = "undefined-word", .word = "x" },
        .{ .name = "failed seal publishes nothing", .source = "[] ([] ((missing) `x def) `bad @defm) @attempt pop bad.x", .kind = "undefined-word" },
    });
}
