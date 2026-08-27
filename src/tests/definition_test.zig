const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
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

test "definition annotations support all top-level forms and dynamic data" {
    try support.expectStack(
        "(1) 'plain def " ++
            "(-- out) (2) 'effect-only def " ++
            "(: \"Documented.\") (3) 'doc-only def " ++
            "(x -- y : \"Square a numeric value.\") (dup *) 'square def " ++
            "(: \"Built as data.\") 'annotation set " ++
            "annotation (5) 'dynamic def " ++
            "plain effect-only doc-only 4 square dynamic " ++
            "'doc-only doc 'square doc 'dynamic doc",
        "1 2 3 16 5 \"Documented.\" \"Square a numeric value.\" \"Built as data.\"",
    );
    try support.expectErrors(&.{
        .{ .name = "no documentation", .source = "(-- x) (1) 'x def 'x doc", .kind = "domain", .word = "doc" },
        .{ .name = "missing binding", .source = "'absent doc", .kind = "undefined-word", .word = "absent" },
    });
    try support.expectStack(
        "(a -- b c : \"Reflective only.\") (dup +) 'top-level-lie def 4 top-level-lie",
        "8",
    );
}

test "every primitive exposes meaningful reflective documentation" {
    const names = [_][]const u8{
        "dup",    "swap",      "pop",       "over",      "cons",        "compose",
        "match?", "type",      "parse",     "parse-int", "parse-float", "@attempt",
        "raise",  "args",      "exit",      "dip",       "call",        "if",
        "while",  "times",     "cond",      "each",      "zip-with",    "for",
        "fold",   "scan",      "stencil",   "unfold",    "infra",       "def",
        "set",    "defp",      "setp",      "unset",     "undef",       "doc",
        "which",  "see",       "@module",   "@defm",     "register",    "import",
        "alias",  "words",     "load",      "@spawn",    "await",       "cancel",
        "tasks",  "await-any", "await-for", "@each",     "+",           "-",
        "*",      "/",         "div",       "mod",       "pow",         "atan2",
        "min",    "max",       "=",         "<>",        "<",           ">",
        "<=",     ">=",        "and",       "or",        "neg",         "abs",
        "sqrt",   "floor",     "ceil",      "round",     "exp",         "log",
        "sin",    "cos",       "not",       "at",        "where",       "in?",
        "raze",   "cat",       "take",      "drop",      "reverse",     "first",
        "rest",   "range",     "shape",     "len",       "flip",        "reshape",
        "cmp",    "grade",     "distinct",  "group",     "put",         "del",
        "split",  "join",      "str",       "band",      "bor",         "bxor",
        "bsl",    "bsr",       "bnot",
    };
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer expected.deinit();
    try source.writer.writeAll(
        "'over doc \"Copy the value beneath the top of the stack onto the top.\" match? ",
    );
    try expected.writer.writeByte('1');
    for (names) |name| {
        try source.writer.print("'{s} doc len 0 > ", .{name});
        try expected.writer.writeAll(" 1");
    }

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, source.written());
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected.written(), display.bytes());
    try expectOk(&runtime, "'over see 'call see");
    try std.testing.expectEqualStrings(
        "### def over\n" ++
            "(x y -- x y x : \"Copy the value beneath the top of the stack onto the top.\") (swap dup (swap) dip)\n" ++
            "'over\n" ++
            "def\n" ++
            "(quotation -- ... : \"Run a quotation on the current stack.\") <primitive> 'call def\n",
        output.written(),
    );
}

test "which reports effect metadata without expanding documentation" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, "(x -- y : \"Not part of concise which output.\") (dup *) 'square def 'square which");
    try std.testing.expectEqualStrings("square -> square def public (x -- y)\n", output.written());
}

test "module annotations retain contracts documentation qualification and shadowing" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(" ++
        "(-- n : \"Public module word.\") (1) 'public def " ++
        "(-- n : \"Private module word.\") (2) 'private defp " ++
        "(-- text : \"Expose private documentation.\") ('private doc) 'private-doc def" ++
        ") 'm @defm " ++
        "'m.public 'public import 'public doc \"Public module word.\" match? " ++
        "m.private-doc \"Private module word.\" match? " ++
        "(-- n : \"Session shadow.\") (9) 'public def " ++
        "'public doc \"Session shadow.\" match? " ++
        "'m.public doc \"Public module word.\" match?");
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("1 1 1 1", display.bytes());
    try expectErrorContains(&runtime, "'m.private doc", "'kind 'undefined-word");
    // A documentation-only module word is one of the four legal forms, and
    // its documentation is what reflection reports.
    try expectOk(&runtime, "((: \"Documentation only.\") (1) 'f def) 'docs @defm " ++
        "'docs.f doc \"Documentation only.\" match? pop");
    try expectErrorContains(&runtime, "((a -- b c : \"An intentionally false contract.\") (dup +) 'f def) 'lies @defm 1 lies.f", "'kind 'contract");
}

test "multiline documentation is normalized and see is canonical and re-readable" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, "(x -- y : \"Square a numeric value.\") (dup *) 'square def " ++
        "(: \"Only docs.\") (42) 'answer def " ++
        "(: \"  First line wraps\n    softly.\n\n  - One\n    continues\n  - Two.\") (1) 'multiline def " ++
        "'multiline doc \"First line wraps softly.\n\n- One continues\n- Two.\" match? " ++
        "'square see 'answer see");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqualStrings(
        "### def square\n" ++
            "(x -- y : \"Square a numeric value.\") (dup *) 'square def\n" ++
            "### def answer\n" ++
            "(: \"Only docs.\") (42) 'answer def\n",
        output.written(),
    );

    var reread = try session.Session.init(std.testing.allocator, &.{});
    defer reread.deinit();
    try expectOk(&reread, output.written());
    try expectOk(&reread, "4 square 'square doc \"Square a numeric value.\" match? " ++
        "answer 'answer doc \"Only docs.\" match?");
    var display = try reread.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("16 1 42 1", display.bytes());
}

test "see retains source binders while execution uses their lowered body" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();

    // Define and reflect in separate units: the binding, rather than the
    // already-retired input turn, owns the shared source slice.
    try expectOk(&runtime, "(n -- n : \"Increment.\") (|x| x 1 +) 'inc def");
    try expectOk(&runtime, "'inc see");
    try std.testing.expectEqualStrings(
        "### def inc\n(n -- n : \"Increment.\") (|x| x 1 +) 'inc def\n",
        output.written(),
    );

    // The reflected definition is ordinary source: rereading it lowers the
    // binder again, and both copies execute identically.
    var reread = try session.Session.init(std.testing.allocator, &.{});
    defer reread.deinit();
    try expectOk(&reread, output.written());
    try expectOk(&reread, "41 inc");
    var display = try reread.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("42", display.bytes());
}

test "redefinition and set replace behavior and clear metadata" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(-- n : \"Old metadata.\") (1) 'lease-target def");
    try expectOk(&runtime, "(2) 'lease-target def");
    try expectOk(&runtime, "lease-target 2 match?");
    try expectErrorContains(&runtime, "'lease-target doc", "'kind 'domain");

    try expectOk(&runtime, "(-- n : \"Temporary.\") (3) 'set-target def 9 'set-target set");
    try expectOk(&runtime, "set-target 9 match?");
    try expectErrorContains(&runtime, "'set-target doc", "'kind 'domain");
}

test "unset and undef equivalently remove only the current scope binding" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectOk(&runtime, "1 'removed-by-unset set 'removed-by-unset unset");
    try expectErrorContains(&runtime, "removed-by-unset", "'kind 'undefined-word");
    try expectOk(&runtime, "2 'removed-by-undef set 'removed-by-undef undef");
    try expectErrorContains(&runtime, "removed-by-undef", "'kind 'undefined-word");

    // Missing direct bindings are idempotent no-ops. In particular, neither
    // spelling can mutate the immutable core environment.
    try expectOk(&runtime, "'never-bound unset 'never-bound undef");
    try expectOk(&runtime, "9 'dup set 'dup undef 4 dup");
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("4 4", display.bytes());

    // A removed name can be published again, and module construction applies
    // the same operation to public and private bindings.
    try expectOk(&runtime, "3 'again set 'again unset 5 'again set again");
    try expectOk(&runtime, "(1 'public set 2 'private setp 'public unset 'private undef " ++
        "(-- n) (7) 'kept def) 'unbound @defm unbound.kept");
    try expectErrorContains(&runtime, "unbound.public", "'kind 'undefined-word");
    try expectErrorContains(&runtime, "unbound.private", "'kind 'undefined-word");
}

test "recognized malformed annotations are domain errors" {
    try support.expectErrors(&.{
        .{ .name = "duplicate separator", .source = "(a -- b -- c) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "duplicate colon", .source = "(: \"a\" : \"b\") (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "separator after colon", .source = "(: \"a\" -- b) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "nonword input", .source = "(1 -- b) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "nonword output", .source = "(a -- 1) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "colon not first without effect", .source = "(a : \"doc\") (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "missing doc", .source = "(:) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "nonstring doc", .source = "(: 1) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "extra doc", .source = "(: \"a\" \"b\") (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "combined missing doc", .source = "(a -- b :) (1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "combined extra doc", .source = "(a -- b : \"a\" \"b\") (1) 'x def", .kind = "domain", .word = "def" },
    });
}

test "nested and quoted markers remain body data" {
    try support.expectStack(
        "((-- :) '-- ':) 'inert def inert " ++
            "(-- :) 'markers set markers " ++
            "((-- :) 'private-markers setp " ++
            "(-- value : \"Return private marker data.\") (private-markers) 'get def) 'm @defm m.get",
        "(-- :) '-- ': (-- :) (-- :)",
    );
}

test "reserved namespace names reject every binding surface but remain readable" {
    try support.expectErrors(&.{
        .{ .name = "definition", .source = "(1) '-- def", .kind = "domain", .word = "def" },
        // set is prelude sugar, so the reserved-name check raises from the
        // def it calls, with set as the trace parent.
        .{ .name = "value", .source = "1 ': set", .kind = "domain", .word = "def" },
        .{ .name = "local separator", .source = "1 (|--| --)", .kind = "parse" },
        .{ .name = "local colon", .source = "1 (|:| :)", .kind = "parse" },
        .{ .name = "@defm", .source = "() '-- @defm", .kind = "domain", .word = "@defm" },
        .{ .name = "alias", .source = "() 'm @defm '-- 'm alias", .kind = "domain", .word = "alias" },
        .{ .name = "public export", .source = "((-- x) (1) '-- def) 'm @defm", .kind = "domain", .word = "def" },
        .{ .name = "private value", .source = "(1 ': setp) 'm @defm", .kind = "domain", .word = "defp" },
        .{ .name = "unset separator", .source = "'-- unset", .kind = "domain", .word = "unset" },
        .{ .name = "undef qualified", .source = "'m.x undef", .kind = "domain", .word = "undef" },
        .{ .name = "bare reserved word is readable", .source = "--", .kind = "undefined-word", .word = "--" },
    });
    try support.expectStack("'-- ': (-- :) 'x:y", "'-- ': (-- :) 'x:y");
    try support.expectStack("(1) 'name--part def (2) 'name:part def name--part name:part", "1 2");

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
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const marker = try intern.intern("--");
    const name = try intern.intern("value");
    const items = try allocator.alloc(value.Value, 70_000);
    defer allocator.free(items);
    @memset(items, .{ .word = .{ .name = name } });
    items[0] = .{ .word = .{ .name = marker } };
    const annotation = try list.fromValuesGeneric(allocator, items);
    try runtime.pushOwned(annotation);
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try runtime.pushOwned(body);
    runtime.requestCancellation();
    try expectErrorContains(&runtime, "'cancelled-definition def", "unit cancelled");
    try std.testing.expect(runtime.lastPolls() >= 1);
    runtime.clearCancellation();
    try expectErrorContains(&runtime, "cancelled-definition", "'kind 'undefined-word");

    var doc_runtime = try session.Session.init(std.testing.allocator, &.{});
    defer doc_runtime.deinit();
    const doc_codepoints = try allocator.alloc(u32, 70_000);
    defer allocator.free(doc_codepoints);
    @memset(doc_codepoints, 'd');
    const cancellable_doc = try list.fromCodepoints(allocator, doc_codepoints);
    defer cleanup.releaseValue(cancellable_doc);
    const doc_annotation = try list.fromValuesGeneric(allocator, &.{
        .{ .word = .{ .name = try intern.intern(":") } },
        cancellable_doc,
    });
    try doc_runtime.pushOwned(doc_annotation);
    const doc_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try doc_runtime.pushOwned(doc_body);
    doc_runtime.requestCancellation();
    try expectErrorContains(&doc_runtime, "'cancelled-doc def", "unit cancelled");
    try std.testing.expect(doc_runtime.lastPolls() >= 1);
    doc_runtime.clearCancellation();
    try expectErrorContains(&doc_runtime, "cancelled-doc", "'kind 'undefined-word");

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var reflection_runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer reflection_runtime.deinit();
    const long_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer cleanup.releaseValue(long_body);
    const codepoints = try allocator.alloc(u32, 70_000);
    defer allocator.free(codepoints);
    @memset(codepoints, 'd');
    const long_doc = try list.fromCodepoints(allocator, codepoints);
    defer cleanup.releaseValue(long_doc);
    const long_id = try intern.intern("long-doc");
    try reflection_runtime.define(
        try intern.namespaceName(long_id),
        .{ .word = .{
            .body = env.quotation(long_body.list).?,
            .doc = env.documentation(long_doc.list).?,
        } },
    );
    reflection_runtime.requestCancellation();
    try expectErrorContains(&reflection_runtime, "'long-doc see", "unit cancelled");
    try std.testing.expect(reflection_runtime.lastPolls() >= 1);

    var name_runtime = try session.Session.init(std.testing.allocator, &.{});
    defer name_runtime.deinit();
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 'n');
    const long_name = try intern.intern(name_bytes);
    try name_runtime.pushOwned(try list.fromValuesGeneric(allocator, &.{}));
    try name_runtime.pushOwned(.{ .symbol = long_name });
    name_runtime.requestCancellation();
    try expectErrorContains(&name_runtime, "def", "unit cancelled");
    try std.testing.expect(name_runtime.lastPolls() >= 1);
    name_runtime.clearCancellation();
    const lookup_source = try std.fmt.allocPrint(allocator, "'{s} doc", .{name_bytes});
    defer allocator.free(lookup_source);
    try expectErrorContains(&name_runtime, lookup_source, "'kind 'undefined-word");
}

// ── Milestone 10 (one-binder-merge) ──────────────────────────────────────
// The merge makes `v 'name set` observationally `v literal 'name def`:
// bindings have one kind, bare reference always applies a stored body, and
// a "value" is a word whose body is the literal capture `((v) first)`. Since
// M11 made source annotations optional everywhere, the sugar synthesizes no
// metadata at all and the equivalence is exact.

test "definitions: set publishes a literal-capture word with no synthesized metadata" {
    // A constant is a word whose body is the literal capture, so referencing
    // it applies that body and pushes exactly the captured value. The capture
    // is inert for every kind of value: a quotation is pushed rather than run,
    // and a bare word stays data rather than resolving.
    try support.expectStack("3 'x set x", "3");
    try support.expectStack("(dup *) 'q set q", "(dup *)");
    try support.expectStack("(dup) first 'w set w", "dup");
    try support.expectStack("{'a 1} 'd set d", "{'a 1}");
    // Rebinding replaces the whole snapshot, capture and all.
    try support.expectStack("3 'x set 4 'x set x", "4");
}

test "definitions: which and see render set bindings as public defs" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    // Reflection reports what is stored: one kind, and no metadata, because
    // the sugar supplies none. There is no `set` label to report, and `see`
    // does not reconstruct the `set` spelling from the capture shape.
    try expectOk(&runtime, "3 'x set 'x which 'x see");
    try std.testing.expectEqualStrings(
        "x -> x def public\n" ++
            "### def x\n" ++
            "([3] first) 'x def\n",
        output.written(),
    );

    // The rendering is source: reading it back reproduces the binding.
    var reread = try session.Session.init(std.testing.allocator, &.{});
    defer reread.deinit();
    try expectOk(&reread, "([3] first) 'x def x");
    var display = try reread.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("3", display.bytes());
}

test "definitions: set distinguishes binding annotations from captured data" {
    // The guarantee is now mechanical rather than a mode test: the sugar
    // wraps its value before def sees it, so a captured marker list is
    // always nested one level down, and nested markers are inert.
    try support.expectStack("(-- :) 'markers set markers", "(-- :)");
    try support.expectStack("(: \"doc\") 'ann set ann", "(: \"doc\")");
    try support.expectStack("(a -- b) 'eff set eff", "(a -- b)");
    try support.expectStack(
        "(: \"Documented constant.\") 7 'answer set answer 'answer doc",
        "7 \"Documented constant.\"",
    );
    try support.expectStack(
        "(: \"Binding documentation.\") (: \"Captured data.\") 'annotated-data set " ++
            "annotated-data 'annotated-data doc",
        "(: \"Captured data.\") \"Binding documentation.\"",
    );
    // The captured annotation is data, not metadata: it never becomes the
    // binding's own documentation or effect.
    try support.expectErrors(&.{
        .{ .name = "captured doc is not documentation", .source = "(: \"doc\") 'ann set 'ann doc", .kind = "domain", .word = "doc" },
    });
}

test "definitions: top-level setp fails through defp's module-root check" {
    // Privacy is still checked dynamically against the unit's current scope;
    // the sugar just relocates the raiser to the primitive it calls.
    try support.expectErrors(&.{
        .{
            .name = "top-level setp",
            .source = "1 'x setp",
            .kind = "domain",
            .word = "defp",
            .message = "defp/setp are legal only in a module root",
        },
        .{
            // An isolated child scope is not a module root either, even
            // inside a module body — the check is against the unit's current
            // scope, not the enclosing registration.
            .name = "setp inside an isolated child",
            .source = "([1] (pop 1 'x setp) each) 'm @defm",
            .kind = "domain",
            .word = "defp",
        },
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
        "( -- ) ((-- n) (1) 'made-here def) 'maker def maker made-here",
        "1",
    );

    // Inside a module body it lands in the module root — which is exactly
    // how the core words set and setp publish module constants, including
    // the privacy distinction. Module bodies resolve against the module's
    // own chain, so only core words (not session helpers) can be used here.
    try support.expectStack("(7 'x set 8 'h setp (-- n) (h) 'peek def) 'm @defm m.x m.peek", "7 8");
    try support.expectErrors(&.{
        .{ .name = "private stays private", .source = "(8 'h setp) 'm @defm m.h", .kind = "undefined-word", .word = "m.h" },
    });

    // Inside an isolated child unit it stays in that disposable scope.
    try support.expectErrors(&.{
        .{
            .name = "child scope is disposable",
            .source = "( -- ) ((-- n) (1) 'scoped def) 'h def (h) @attempt pop scoped",
            .kind = "undefined-word",
            .word = "scoped",
        },
    });
}

test "definitions: body is not a word and one binding kind needs no extraction" {
    // Nothing lifts a published body out of the home it resolves against, so
    // a label can never be re-sited and a private cannot be reached by
    // dissecting a public.
    try support.expectErrors(&.{
        .{ .name = "set-bound", .source = "3 'x set 'x body", .kind = "undefined-word", .word = "body" },
        .{ .name = "def-bound", .source = "(1) 'f def 'f body", .kind = "undefined-word", .word = "body" },
        .{ .name = "builtin", .source = "'def body", .kind = "undefined-word", .word = "body" },
    });
    // The invariant `body` used to observe is unchanged and still observable.
    // `see` renders the stored body verbatim, so a constant is visibly a word
    // whose body is the literal capture, and a definition visibly is not.
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, "3 'x set 'x see (dup *) 'sq def 'sq see");
    try std.testing.expectEqualStrings(
        "### def x\n" ++
            "([3] first) 'x def\n" ++
            "### def sq\n" ++
            "(dup *) 'sq def\n",
        output.written(),
    );
}
