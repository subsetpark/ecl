const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const printer = @import("print.zig");
const session = @import("session.zig");
const support = @import("kernel_test_support.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("definition-test.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer heap.releaseValue(runtime.allocator, failure);
            const rendered = try printer.toOwnedString(runtime.allocator, failure);
            defer runtime.allocator.free(rendered);
            std.log.err("unexpected language error: {s}", .{rendered});
            return error.UnexpectedLanguageError;
        },
    }
}

fn expectErrorContains(runtime: *session.Session, source: []const u8, text: []const u8) !void {
    const failure = switch (try runtime.runUnit("definition-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer heap.releaseValue(runtime.allocator, failure);
    const rendered = try printer.toOwnedString(runtime.allocator, failure);
    defer runtime.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, text) != null);
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
    try expectOk(&runtime, "'m (" ++
        "(1) (-- n : \"Public module word.\") 'public def " ++
        "(2) (-- n : \"Private module word.\") 'private defp " ++
        "('private doc) (-- text : \"Expose private documentation.\") 'private-doc def" ++
        ") module " ++
        "'m use 'public doc \"Public module word.\" match " ++
        "m.private-doc \"Private module word.\" match " ++
        "(9) (-- n : \"Session shadow.\") 'public def " ++
        "'public doc \"Session shadow.\" match " ++
        "'m.public doc \"Public module word.\" match");
    const display = try runtime.stackDisplay();
    defer runtime.allocator.free(display);
    try std.testing.expectEqualStrings("1 1 1 1", display);
    try expectErrorContains(&runtime, "'m.private doc", "'kind 'undefined-word");
    try expectErrorContains(&runtime, "'bad ((1) (: \"Documentation only.\") 'f def) module", "'kind 'domain");
    try expectErrorContains(&runtime, "'lies ((dup +) (a -- b c : \"An intentionally false contract.\") 'f def) module 1 lies.f", "'kind 'contract");
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
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[0].int);
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
    const display = try reread.stackDisplay();
    defer reread.allocator.free(display);
    try std.testing.expectEqualStrings("16 1 42 1", display);
}

test "redefinition and set clear metadata while old leases remain valid" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(1) (-- n : \"Old metadata.\") 'lease-target def");
    const id = try intern.intern("lease-target");
    var old = (try runtime.environment.session.resolveDirect(id, .unlimited())).?;
    defer old.deinit(runtime.allocator);
    try std.testing.expect(old.effect != null and old.doc != null);
    const old_body = old.binding.word;
    const old_effect = old.effect.?.quotation;
    const old_doc = old.doc.?;

    try expectOk(&runtime, "(2) 'lease-target def");
    var current = (try runtime.environment.session.resolveDirect(id, .unlimited())).?;
    defer current.deinit(runtime.allocator);
    try std.testing.expect(current.effect == null and current.doc == null);
    try std.testing.expectEqual(old_body, old.binding.word);
    try std.testing.expectEqual(old_effect, old.effect.?.quotation);
    try std.testing.expectEqual(old_doc, old.doc.?);
    try expectErrorContains(&runtime, "'lease-target doc", "'kind 'domain");

    try expectOk(&runtime, "(3) (-- n : \"Temporary.\") 'set-target def 9 'set-target set");
    const set_id = try intern.intern("set-target");
    var replaced = (try runtime.environment.session.resolveDirect(set_id, .unlimited())).?;
    defer replaced.deinit(runtime.allocator);
    try std.testing.expect(replaced.binding == .value);
    try std.testing.expect(replaced.effect == null and replaced.doc == null);
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
            "'m ((-- :) 'private-markers setp " ++
            "(private-markers) (-- value : \"Return private marker data.\") 'get def) module m.get",
        "(-- :) '-- ': (-- :) (-- :)",
    );
}

test "reserved namespace names reject every binding surface but remain readable" {
    try support.expectErrors(&.{
        .{ .name = "definition", .source = "(1) '-- def", .kind = "domain", .word = "def" },
        .{ .name = "value", .source = "1 ': set", .kind = "domain", .word = "set" },
        .{ .name = "local separator", .source = "1 (|--| --)", .kind = "parse" },
        .{ .name = "local colon", .source = "1 (|:| :)", .kind = "parse" },
        .{ .name = "module", .source = "'-- () module", .kind = "domain", .word = "module" },
        .{ .name = "alias", .source = "'m () module '-- 'm alias", .kind = "domain", .word = "alias" },
        .{ .name = "public export", .source = "'m ((1) (-- x) '-- def) module", .kind = "domain", .word = "def" },
        .{ .name = "private value", .source = "'m (1 ': setp) module", .kind = "domain", .word = "setp" },
        .{ .name = "bare reserved word is readable", .source = "--", .kind = "undefined-word", .word = "--" },
    });
    try support.expectStack("'-- ': (-- :) 'x:y", "'-- ': (-- :) 'x:y");
    try support.expectStack("(1) 'name--part def (2) 'name:part def name--part name:part", "1 2");

    try std.testing.expectError(
        error.InvalidName,
        intern.namespaceName(try intern.intern("--"), .unlimited()),
    );
    try std.testing.expectError(
        error.InvalidName,
        intern.namespaceName(try intern.intern(":"), .unlimited()),
    );
}

test "long annotation traversal and reflection observe cancellation" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try runtime.stack.append(allocator, body);
    const marker = try intern.intern("--");
    const name = try intern.intern("value");
    const items = try allocator.alloc(value.Value, 70_000);
    defer allocator.free(items);
    @memset(items, .{ .word = name });
    items[0] = .{ .word = marker };
    const annotation = try list.fromValuesGeneric(allocator, items);
    try runtime.stack.append(allocator, annotation);
    runtime.cancelled.store(true, .release);
    try expectErrorContains(&runtime, "'cancelled-definition def", "unit cancelled");
    try std.testing.expect(runtime.last_polls >= 1);
    try std.testing.expect(try runtime.environment.session.resolveDirect(
        try intern.intern("cancelled-definition"),
        .unlimited(),
    ) == null);

    var doc_runtime = try session.Session.init(allocator, &.{});
    defer doc_runtime.deinit();
    const doc_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    try doc_runtime.stack.append(allocator, doc_body);
    const doc_codepoints = try allocator.alloc(u32, 70_000);
    defer allocator.free(doc_codepoints);
    @memset(doc_codepoints, 'd');
    const cancellable_doc = try list.fromCodepoints(allocator, doc_codepoints);
    defer heap.releaseValue(allocator, cancellable_doc);
    const doc_annotation = try list.fromValuesGeneric(allocator, &.{
        .{ .word = try intern.intern(":") },
        cancellable_doc,
    });
    try doc_runtime.stack.append(allocator, doc_annotation);
    doc_runtime.cancelled.store(true, .release);
    try expectErrorContains(&doc_runtime, "'cancelled-doc def", "unit cancelled");
    try std.testing.expect(doc_runtime.last_polls >= 1);
    try std.testing.expect(try doc_runtime.environment.session.resolveDirect(
        try intern.intern("cancelled-doc"),
        .unlimited(),
    ) == null);

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var reflection_runtime = try session.Session.initWithOutput(allocator, &.{}, &output.writer);
    defer reflection_runtime.deinit();
    const long_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, long_body);
    const codepoints = try allocator.alloc(u32, 70_000);
    defer allocator.free(codepoints);
    @memset(codepoints, 'd');
    const long_doc = try list.fromCodepoints(allocator, codepoints);
    defer heap.releaseValue(allocator, long_doc);
    const long_id = try intern.intern("long-doc");
    try reflection_runtime.environment.define(
        try intern.namespaceName(long_id, .unlimited()),
        .{ .word = .{
            .body = env.quotation(long_body.list).?,
            .doc = env.documentation(long_doc.list).?,
        } },
    );
    reflection_runtime.cancelled.store(true, .release);
    try expectErrorContains(&reflection_runtime, "'long-doc see", "unit cancelled");
    try std.testing.expect(reflection_runtime.last_polls >= 1);

    var name_runtime = try session.Session.init(allocator, &.{});
    defer name_runtime.deinit();
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 'n');
    const long_name = try intern.intern(name_bytes);
    try name_runtime.stack.append(allocator, try list.fromValuesGeneric(allocator, &.{}));
    try name_runtime.stack.append(allocator, .{ .symbol = long_name });
    name_runtime.cancelled.store(true, .release);
    try expectErrorContains(&name_runtime, "def", "unit cancelled");
    try std.testing.expect(name_runtime.last_polls >= 1);
    try std.testing.expect(try name_runtime.environment.session.resolveDirect(long_name, .unlimited()) == null);
}
