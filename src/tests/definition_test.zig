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
            "(2) (-- out) 'effect-only def " ++
            "(3) (: \"Documented.\") 'doc-only def " ++
            "(dup *) (x -- y : \"Square a numeric value.\") 'square def " ++
            "(: \"Built as data.\") 'annotation set " ++
            "(5) annotation 'dynamic def " ++
            "plain effect-only doc-only 4 square dynamic " ++
            "'doc-only doc 'square doc 'dynamic doc 'square body",
        "1 2 3 16 5 \"Documented.\" \"Square a numeric value.\" \"Built as data.\" (dup *)",
    );
    try support.expectErrors(&.{
        .{ .name = "no documentation", .source = "(1) (-- x) 'x def 'x doc", .kind = "domain", .word = "doc" },
        .{ .name = "missing binding", .source = "'absent doc", .kind = "undefined-word", .word = "absent" },
    });
    try support.expectStack(
        "(dup +) (a -- b c : \"Reflective only.\") 'top-level-lie def 4 top-level-lie",
        "8",
    );
}

test "every primitive exposes meaningful reflective documentation" {
    const names = [_][]const u8{
        "dup",       "swap",       "pop",     "over",  "cons",      "compose",
        "match",     "type",       "str",     "parse", "dict-of",   "@attempt",
        "raise",     "pp",         "prin",    "args",  "exit",      "dip",
        "call",      "if",         "while",   "times", "cond",      "each",
        "zip-with",  "for",        "fold",    "scan",  "infra",     "def",
        "set",       "defp",       "setp",    "body",  "doc",       "which",
        "see",       "@module",    "use",     "alias", "words",     "load",
        "@spawn",    "await",      "cancel",  "tasks", "await-any", "await-for",
        "@each",     "+",          "-",       "*",     "/",         "div",
        "mod",       "pow",        "atan2",   "min",   "max",       "=",
        "<>",        "<",          ">",       "<=",    ">=",        "and",
        "or",        "neg",        "abs",     "sqrt",  "floor",     "ceil",
        "round",     "exp",        "log",     "sin",   "cos",       "not",
        "at",        "where",      "in",      "raze",  "cat",       "take",
        "drop",      "reverse",    "first",   "rest",  "range",     "shape",
        "len",       "flip",       "reshape", "cmp",   "grade",     "distinct",
        "group",     "keys",       "vals",    "put",   "to-dict",   "del",
        "merge",     "has?",       "split",   "join",  "format",    "band",
        "bor",       "bxor",       "bsl",     "bsr",   "bnot",      "rand-int",
        "rand-ints", "rand-float", "entropy",
    };
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer expected.deinit();
    try source.writer.writeAll(
        "'over doc \"Copy the value beneath the top of the stack onto the top.\" match ",
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
        "(swap dup (swap) dip) (x y -- x y x : \"Copy the value beneath the top of the stack onto the top.\") 'over def\n" ++
            "<primitive> (quotation -- ... : \"Run a quotation on the current stack.\") 'call def\n",
        output.written(),
    );
}

test "which reports effect metadata without expanding documentation" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, "(dup *) (x -- y : \"Not part of concise which output.\") 'square def 'square which");
    try std.testing.expectEqualStrings("square -> square def public (x -- y)\n", output.written());
}

test "module annotations retain contracts documentation qualification and shadowing" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(" ++
        "(1) (-- n : \"Public module word.\") 'public def " ++
        "(2) (-- n : \"Private module word.\") 'private defp " ++
        "('private doc) (-- text : \"Expose private documentation.\") 'private-doc def" ++
        ") 'm @module " ++
        "'m use 'public doc \"Public module word.\" match " ++
        "m.private-doc \"Private module word.\" match " ++
        "(9) (-- n : \"Session shadow.\") 'public def " ++
        "'public doc \"Session shadow.\" match " ++
        "'m.public doc \"Public module word.\" match");
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("1 1 1 1", display.bytes());
    try expectErrorContains(&runtime, "'m.private doc", "'kind 'undefined-word");
    // A documentation-only module word is one of the four legal forms, and
    // its documentation is what reflection reports.
    try expectOk(&runtime, "((1) (: \"Documentation only.\") 'f def) 'docs @module " ++
        "'docs.f doc \"Documentation only.\" match pop");
    try expectErrorContains(&runtime, "((dup +) (a -- b c : \"An intentionally false contract.\") 'f def) 'lies @module 1 lies.f", "'kind 'contract");
}

test "multiline documentation is normalized and see is canonical and re-readable" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, "(dup *) (x -- y : \"Square a numeric value.\") 'square def " ++
        "(42) (: \"Only docs.\") 'answer def " ++
        "(1) (: \"  First line wraps\n    softly.\n\n  - One\n    continues\n  - Two.\") 'multiline def " ++
        "'multiline doc \"First line wraps softly.\n\n- One continues\n- Two.\" match " ++
        "'square see 'answer see");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqualStrings(
        "(dup *) (x -- y : \"Square a numeric value.\") 'square def\n" ++
            "[42] (: \"Only docs.\") 'answer def\n",
        output.written(),
    );

    var reread = try session.Session.init(std.testing.allocator, &.{});
    defer reread.deinit();
    try expectOk(&reread, output.written());
    try expectOk(&reread, "4 square 'square doc \"Square a numeric value.\" match " ++
        "answer 'answer doc \"Only docs.\" match");
    var display = try reread.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("16 1 42 1", display.bytes());
}

test "redefinition and set replace behavior and clear metadata" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(1) (-- n : \"Old metadata.\") 'lease-target def");
    try expectOk(&runtime, "(2) 'lease-target def");
    try expectOk(&runtime, "lease-target 2 match");
    try expectErrorContains(&runtime, "'lease-target doc", "'kind 'domain");

    try expectOk(&runtime, "(3) (-- n : \"Temporary.\") 'set-target def 9 'set-target set");
    try expectOk(&runtime, "set-target 9 match");
    try expectErrorContains(&runtime, "'set-target doc", "'kind 'domain");
}

test "recognized malformed annotations are domain errors and missing bodies underflow" {
    try support.expectErrors(&.{
        .{ .name = "duplicate separator", .source = "(1) (a -- b -- c) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "duplicate colon", .source = "(1) (: \"a\" : \"b\") 'x def", .kind = "domain", .word = "def" },
        .{ .name = "separator after colon", .source = "(1) (: \"a\" -- b) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "nonword input", .source = "(1) (1 -- b) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "nonword output", .source = "(1) (a -- 1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "colon not first without effect", .source = "(1) (a : \"doc\") 'x def", .kind = "domain", .word = "def" },
        .{ .name = "missing doc", .source = "(1) (:) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "nonstring doc", .source = "(1) (: 1) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "extra doc", .source = "(1) (: \"a\" \"b\") 'x def", .kind = "domain", .word = "def" },
        .{ .name = "combined missing doc", .source = "(1) (a -- b :) 'x def", .kind = "domain", .word = "def" },
        .{ .name = "combined extra doc", .source = "(1) (a -- b : \"a\" \"b\") 'x def", .kind = "domain", .word = "def" },
        .{ .name = "doc annotation missing body", .source = "(: \"doc\") 'x def", .kind = "underflow", .word = "def" },
        .{ .name = "effect annotation missing body", .source = "(-- x) 'x def", .kind = "underflow", .word = "def" },
    });
}

test "nested and quoted markers remain body data and set never recognizes annotations" {
    try support.expectStack(
        "((-- :) '-- ':) 'inert def inert " ++
            "(-- :) 'markers set markers " ++
            "((-- :) 'private-markers setp " ++
            "(private-markers) (-- value : \"Return private marker data.\") 'get def) 'm @module m.get",
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
        .{ .name = "@module", .source = "() '-- @module", .kind = "domain", .word = "@module" },
        .{ .name = "alias", .source = "() 'm @module '-- 'm alias", .kind = "domain", .word = "alias" },
        .{ .name = "public export", .source = "((1) (-- x) '-- def) 'm @module", .kind = "domain", .word = "def" },
        .{ .name = "private value", .source = "(1 ': setp) 'm @module", .kind = "domain", .word = "defp" },
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
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try runtime.pushOwned(body);
    const marker = try intern.intern("--");
    const name = try intern.intern("value");
    const items = try allocator.alloc(value.Value, 70_000);
    defer allocator.free(items);
    @memset(items, .{ .word = name });
    items[0] = .{ .word = marker };
    const annotation = try list.fromValuesGeneric(allocator, items);
    try runtime.pushOwned(annotation);
    runtime.requestCancellation();
    try expectErrorContains(&runtime, "'cancelled-definition def", "unit cancelled");
    try std.testing.expect(runtime.lastPolls() >= 1);
    runtime.clearCancellation();
    try expectErrorContains(&runtime, "cancelled-definition", "'kind 'undefined-word");

    var doc_runtime = try session.Session.init(std.testing.allocator, &.{});
    defer doc_runtime.deinit();
    const doc_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try doc_runtime.pushOwned(doc_body);
    const doc_codepoints = try allocator.alloc(u32, 70_000);
    defer allocator.free(doc_codepoints);
    @memset(doc_codepoints, 'd');
    const cancellable_doc = try list.fromCodepoints(allocator, doc_codepoints);
    defer cleanup.releaseValue(cancellable_doc);
    const doc_annotation = try list.fromValuesGeneric(allocator, &.{
        .{ .word = try intern.intern(":") },
        cancellable_doc,
    });
    try doc_runtime.pushOwned(doc_annotation);
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
    const lookup_source = try std.fmt.allocPrint(allocator, "'{s} body", .{name_bytes});
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
    try support.expectStack("3 'x set x 'x body", "3 ([3] first)");
    try support.expectStack("(dup *) 'q set q", "(dup *)");
    try support.expectStack("(dup) first 'w set w", "dup");
    try support.expectStack("{'a 1} 'd set d", "{'a 1}");
    // Rebinding replaces the whole snapshot, capture and all.
    try support.expectStack("3 'x set 4 'x set x", "4");
}

test "definitions: body returns the capture body for set-bound names" {
    // One binding kind makes `body` total over everything published from
    // ecl: a constant has a stored body just as a definition does, and the
    // capture round-trips as ordinary data.
    try support.expectStack("3 'x set 'x body", "([3] first)");
    try support.expectStack("3 'x set 'x body call", "3");
    // Two unwrappings reach the captured value itself: the capture wrapper,
    // then the quotation that was captured.
    try support.expectStack("(swap) 'q set 'q body first first", "(swap)");
    // Host bindings still have no ecl body to return.
    try support.expectErrors(&.{
        .{ .name = "builtin", .source = "'def body", .kind = "type", .word = "body" },
        .{ .name = "missing", .source = "'absent body", .kind = "undefined-word", .word = "absent" },
    });
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
            "([3] first) 'x def\n",
        output.written(),
    );

    // The rendering is source: reading it back reproduces the binding.
    var reread = try session.Session.init(std.testing.allocator, &.{});
    defer reread.deinit();
    try expectOk(&reread, "([3] first) 'x def x 'x body");
    var display = try reread.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("3 ([3] first)", display.bytes());
}

test "definitions: set never recognizes annotations in captured data" {
    // The guarantee is now mechanical rather than a mode test: the sugar
    // wraps its value before def sees it, so a captured marker list is
    // always nested one level down, and nested markers are inert.
    try support.expectStack("(-- :) 'markers set markers", "(-- :)");
    try support.expectStack("(: \"doc\") 'ann set ann", "(: \"doc\")");
    try support.expectStack("(a -- b) 'eff set eff 'eff body", "(a -- b) (((a -- b)) first)");
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
            .source = "([1] (pop 1 'x setp) each) 'm @module",
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
        "((1) (-- n) 'made-here def) ( -- ) 'maker def maker made-here",
        "1",
    );

    // Inside a module body it lands in the module root — which is exactly
    // how the core words set and setp publish module constants, including
    // the privacy distinction. Module bodies resolve against the module's
    // own chain, so only core words (not session helpers) can be used here.
    try support.expectStack("(7 'x set 8 'h setp (h) (-- n) 'peek def) 'm @module m.x m.peek", "7 8");
    try support.expectErrors(&.{
        .{ .name = "private stays private", .source = "(8 'h setp) 'm @module m.h", .kind = "undefined-word", .word = "m.h" },
    });

    // Inside an isolated child unit it stays in that disposable scope.
    try support.expectErrors(&.{
        .{
            .name = "child scope is disposable",
            .source = "((1) (-- n) 'scoped def) ( -- ) 'h def (h) @attempt pop scoped",
            .kind = "undefined-word",
            .word = "scoped",
        },
    });
}
