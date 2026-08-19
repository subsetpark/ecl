//! Embedded-stdlib resolution: use-miss and qualified-miss auto-load,
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

test "stdlib: embedded module resolves via use with no ECL_PATH" {
    // A bare Session has no host IO and no search path at all, so nothing
    // here could reach a file even if one existed.
    for (stdlib.names()) |name| {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var runtime = try session.Session.init(heap.allocator(), &.{});
        defer runtime.deinit();
        const source = try std.fmt.allocPrint(allocator, "'{s} use", .{name});
        defer allocator.free(source);
        try expectOk(&runtime, source);
    }
    try support.expectStack("'result use [1 2] ok", "{'ok [1 2]}");
}

test "stdlib: qualified reference auto-loads an unregistered module" {
    // No `use`, no registration, no path: the first mention of the dotted
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

test "stdlib: embedded resolution precedence against ECL_PATH follows the ruling" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    // A path module that would shadow a stdlib name, and one that would not.
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "result.ecl",
        .data = "((999) 'ok def) 'result @module",
    });
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "site-local.ecl",
        .data = "((7) 'answer def) 'site-local @module",
    });
    const search = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(search);

    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = search,
    });
    defer runtime.deinit();

    // The embedded module wins for both spellings of the miss.
    try expectDisplay(&runtime, "[1 2] result.ok", "{'ok [1 2]}");
    try expectDisplay(&runtime, "'result use [3] ok", "{'ok [1 2]} {'ok [3]}");
    // The same search path still serves a name the stdlib does not claim, so
    // this is precedence rather than ECL_PATH being ignored.
    try expectDisplay(&runtime, "site-local.answer", "{'ok [1 2]} {'ok [3]} 7");
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
                "([1] result.ok) ('result use [2] ok) 2 pack (@spawn) each await-all",
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
    // stdlib name used to appear as a completion only after a `use` or a
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
    try expectOk(&runtime, "'rng use");
    var warm = try runtime.completionCandidates("rng");
    defer warm.deinit();
    var occurrences: usize = 0;
    for (warm.items()) |candidate| {
        if (std.mem.eql(u8, candidate, "rng")) occurrences += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), occurrences);
}
