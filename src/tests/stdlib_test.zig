//! Embedded-stdlib resolution: import-miss and qualified-miss auto-load,
//! precedence against `ECL_PATH`, and lazy-registration convergence.
//!
//! These cases pass only source strings to a Session, so they run on the
//! traceless session heap (see `test_heap.zig`). The point of most of them is
//! what the Session is *not* given: no host IO and no search path.
const std = @import("std");
const session = @import("../session.zig");
const stdlib = @import("../stdlib.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("<stdlib-test>", source)) {
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

fn expectDisplay(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    try expectOk(runtime, source);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
}

test "stdlib: embedded module resolves via import with no ECL_PATH" {
    // A bare Session has no host IO and no search path at all, so nothing
    // here could reach a file even if one existed.
    const exports = [_][]const u8{
        "dict.from-pairs",   "error.new",         "result.ok",
        "str.upper",         "io.print",          "csv.parse",
        "json.parse",        "table.valid?",      "http.get-bytes",
        "archive.sha256",    "pkg.store.inspect", "rng.float",
        "rand.float",        "pkg.version.less?", "pkg.name.valid?",
        "pkg.data.read-one", "pkg.manifest.read", "pkg.lock.read",
        "pkg.mvs.resolve",   "pkg.sync.run",      "pkg.cli.init",
        "test.default.run",
    };
    for (stdlib.names(), exports) |name, qualified| {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var runtime = try session.Session.init(heap.allocator(), &.{});
        defer runtime.deinit();
        try std.testing.expect(std.mem.startsWith(u8, qualified, name));
        const source = try std.fmt.allocPrint(
            allocator,
            "'{s} ('{s}) import",
            .{ name, qualified[name.len + 1 ..] },
        );
        defer allocator.free(source);
        try expectOk(&runtime, source);
    }
    try support.expectStack("'result ('ok) import [1 2] ok", "{'ok [1 2]}");
}

test "stdlib: every pkg.store capability is documented and reflectable" {
    try support.expectStack(
        "'pkg.store.inspect doc len 0 > " ++
            "'pkg.store.install doc len 0 > " ++
            "'pkg.store.present? doc len 0 > " ++
            "'pkg.store.verify doc len 0 > " ++
            "'pkg.store.read-seal doc len 0 > " ++
            "'pkg.store.write-lock doc len 0 > " ++
            "'pkg.store.write-new doc len 0 > " ++
            "'pkg.store.gc doc len 0 >",
        "1 1 1 1 1 1 1 1",
    );
}

test "stdlib: qualified reference auto-loads an unregistered module" {
    // No import, no registration, no path: the first mention of the dotted
    // name is what loads the module.
    try support.expectStack("[1 2] result.ok", "{'ok [1 2]}");
    // The reference is retried in place, so a value produced before it and a
    // word applied after it both see the ordinary stack.
    try support.expectStack("7 [1 2] result.ok 'ok at len", "7 2");
    // The retry costs one bounded search and then reads as an undefined word.
    try support.expectErrors(&.{
        .{
            .name = "unknown module",
            .source = "nosuch-module.word",
            .kind = "undefined-word",
            .word = "nosuch-module.word",
        },
        .{
            .name = "known module without the export",
            .source = "result.nope",
            .kind = "undefined-word",
            .word = "result.nope",
        },
    });
}

test "stdlib: dynamic qualified execution auto-loads every embedded transport" {
    try support.expectStacks(&.{
        .{
            .name = "embedded ECL source",
            .source = "[1] 'result 'ok qualify execute",
            .expected = "{'ok [1]}",
        },
        .{
            .name = "embedded builtin table",
            .source = "\"[1]\" 'json 'parse qualify execute",
            .expected = "[1]",
        },
        .{
            .name = "embedded native descriptor",
            .source = "\"a,b\" 'csv 'parse qualify execute",
            .expected = "((\"a\" \"b\"))",
        },
    });
    try support.expectError(.{
        .name = "cold dynamic miss retains the requested word",
        .source = "'result 'nope qualify execute",
        .kind = "undefined-word",
        .word = "result.nope",
    });
}

test "stdlib: qualified reflection auto-loads every module transport" {
    try support.expectStack("'str.upper doc len 0 > 'io.pp doc len 0 >", "1 1");

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var runtime = try session.Session.initWithOutput(heap.allocator(), &.{}, &output.writer);
    defer runtime.deinit();
    try expectOk(&runtime, "'csv.parse which 'result.ok see");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "csv.parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(dup type 'list match?") != null);
}

test "stdlib: embedded resolution precedence against ECL_PATH follows the ruling" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    // A path module that would shadow a stdlib name, and one that would not.
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "result.ecl",
        .data = "((999) 'ok def) 'result @defm",
    });
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "site-local.ecl",
        .data = "((7) 'answer def) 'site-local @defm",
    });
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "cold-local.ecl",
        .data = "((8) 'answer def (9) 'also def) 'cold-local @defm",
    });
    const search = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(search);

    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();

    // Import precedence is proved from a cold registry, not after another
    // spelling has already selected and published the embedded module.
    {
        var imported_output = std.Io.Writer.Allocating.init(allocator);
        defer imported_output.deinit();
        var imported_diagnostics = std.Io.Writer.Allocating.init(allocator);
        defer imported_diagnostics.deinit();
        var imported = try session.Session.initWithHost(heap.allocator(), &.{}, .{
            .io = std.testing.io,
            .output = &imported_output.writer,
            .diagnostics = &imported_diagnostics.writer,
            .ecl_path = search,
        });
        defer imported.deinit();
        try expectDisplay(&imported, "'result ('ok) import [3] ok", "{'ok [3]}");
    }

    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = search,
    });
    defer runtime.deinit();

    // The embedded module also wins for a cold literal qualified reference.
    try expectDisplay(&runtime, "[1 2] result.ok", "{'ok [1 2]}");
    // Completion reaches the same ECL_PATH module before any execution or
    // reflection has registered it.
    var completed = try runtime.completionCandidates("cold-local.a");
    defer completed.deinit();
    try std.testing.expectEqual(@as(usize, 2), completed.items().len);
    try std.testing.expectEqualStrings("cold-local.also", completed.items()[0]);
    try std.testing.expectEqualStrings("cold-local.answer", completed.items()[1]);
    // The same search path still serves a name the stdlib does not claim, so
    // this is precedence rather than ECL_PATH being ignored.
    try expectDisplay(&runtime, "site-local.answer", "{'ok [1 2]} 7");
}

test "stdlib: concurrent first references converge on one published module" {
    // Both spellings of the miss race for the same lazy registration. The
    // loading lease serializes them, so every unit observes one module.
    for ([_]usize{ 1, 8 }) |workers| {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var runtime = try session.Session.initWithConfig(
            heap.allocator(),
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        try expectDisplay(
            &runtime,
            "[[1] [2] [3] [4] [5] [6] [7] [8]] (result.ok) @each " ++
                "([1] result.ok) ('result ('ok) import [2] ok) 2 pack (@spawn) each await-all",
            "({'ok [1]} {'ok [2]} {'ok [3]} {'ok [4]} " ++
                "{'ok [5]} {'ok [6]} {'ok [7]} {'ok [8]}) " ++
                "({'ok ({'ok [1]})} {'ok ({'ok [2]})})",
        );
    }
}

test "stdlib: embedded module names complete before anything has loaded them" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // The bug this pins: the registry knows only published modules, so a
    // stdlib name used to appear as a completion only after an import or a
    // qualified call had already loaded it — you had to type the name in
    // full before the editor would offer it.
    const expected = [_][]const u8{ "result", "rng" };
    var cold = try runtime.completionCandidates("r");
    defer cold.deinit();
    for (expected) |name| {
        var seen = false;
        for (cold.items()) |candidate| {
            if (std.mem.eql(u8, candidate, name)) seen = true;
        }
        if (!seen) {
            std.log.err("cold completion is missing embedded module `{s}`", .{name});
            return error.TestExpectedEqual;
        }
    }
    // Loading one must not make it appear twice.
    try expectOk(&runtime, "rng.float pop");
    var warm = try runtime.completionCandidates("rng");
    defer warm.deinit();
    var occurrences: usize = 0;
    for (warm.items()) |candidate| {
        if (std.mem.eql(u8, candidate, "rng")) occurrences += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), occurrences);
}

test "stdlib: qualified exports complete before execution for every transport" {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var runtime = try session.Session.init(heap.allocator(), &.{});
    defer runtime.deinit();

    var all = try runtime.completionCandidates("json.");
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.items().len);
    try std.testing.expectEqualStrings("json.emit", all.items()[0]);
    try std.testing.expectEqualStrings("json.parse", all.items()[1]);

    var partial = try runtime.completionCandidates("json.pa");
    defer partial.deinit();
    try std.testing.expectEqual(@as(usize, 1), partial.items().len);
    try std.testing.expectEqualStrings("json.parse", partial.items()[0]);

    var source = try runtime.completionCandidates("str.trim");
    defer source.deinit();
    try std.testing.expectEqual(@as(usize, 3), source.items().len);
    try std.testing.expectEqualStrings("str.trim", source.items()[0]);
    try std.testing.expectEqualStrings("str.trim-left", source.items()[1]);
    try std.testing.expectEqualStrings("str.trim-right", source.items()[2]);

    var native = try runtime.completionCandidates("csv.e");
    defer native.deinit();
    try std.testing.expectEqual(@as(usize, 1), native.items().len);
    try std.testing.expectEqualStrings("csv.emit", native.items()[0]);
}
