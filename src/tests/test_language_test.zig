//! Public Session-level behavior for first-class module tests.
const std = @import("std");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    const outcome = try runtime.runUnit("<test>", source);
    switch (outcome) {
        .ok => {},
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.debug.print("unexpected ECL failure: {s}\n", .{rendered.bytes()});
            return error.UnexpectedEclFailure;
        },
        .incomplete => return error.UnexpectedIncompleteSource,
    }
}

fn expectErr(runtime: *session.Session, source: []const u8) !void {
    const outcome = try runtime.runUnit("<test>", source);
    switch (outcome) {
        .err => |failure| runtime.release(failure),
        .ok => return error.ExpectedEclFailure,
        .incomplete => return error.UnexpectedIncompleteSource,
    }
}

fn expectErrContains(runtime: *session.Session, source: []const u8, needle: []const u8) !void {
    const outcome = try runtime.runUnit("<test>", source);
    switch (outcome) {
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), needle) != null);
        },
        .ok => return error.ExpectedEclFailure,
        .incomplete => return error.UnexpectedIncompleteSource,
    }
}

test "testing: declaration is legal only at a module construction root" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectErr(&runtime, "(1) 'outside test");
    try expectErr(&runtime, "[] (((1) 'nested test) call) 'nested.module @defm");
    try expectOk(&runtime, "[] ((1) 'direct test) 'direct.module @defm");
}

test "testing: test names are absent from application resolution and module invocation" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] ((1) 'same def (2) 'same test (3) 'hidden test) @module " ++
            "dup 'visibility register " ++
            "visibility.same 1 = {'kind 'user} assert",
    );
    try expectErr(&runtime, "visibility.hidden");
    try expectErr(&runtime, "dup 'hidden invoke");
}

test "testing: test mode discovers canonical registrations without aliases" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initTest(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] ((1) 'z test (2) 'a test) 'suite.two @defm " ++
            "[] ((3) 'only test) @module dup 'suite.one register 'suite.copy register " ++
            "'short 'suite.one alias " ++
            "tests dup len 4 = {'kind 'user} assert " ++
            "first dup 'module at 'suite.copy match? {'kind 'user} assert " ++
            "'name at 'only match? {'kind 'user} assert",
    );
}

test "testing: application sessions reject test discovery and execution" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectErr(&runtime, "tests");
    try expectErr(&runtime, "{'module 'm 'name 'x} @test");
}

test "testing: application sessions validate and discard test declarations" {
    var application_backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&application_backing);
    var application = try session.Session.init(application_backing.allocator(), &.{});
    defer application.deinit();

    // Application construction still validates declaration placement and
    // shape, but catalog-only uniqueness has no observable application
    // meaning and incurs no retained entry or name-index work.
    try expectOk(
        &application,
        "[] ((1) 'same test (2) 'same test (42) 'answer def) 'discarded @defm " ++
            "discarded.answer 42 = {'kind 'user} assert",
    );

    var test_backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&test_backing);
    var testing = try session.Session.initTest(test_backing.allocator(), &.{});
    defer testing.deinit();
    try expectErr(&testing, "[] ((1) 'same test (2) 'same test) 'duplicate @defm");
}

test "testing: test execution reaches private definitions and reifies its isolated stack" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initTest(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] ((42) 'secret defp (stack len secret) 'private test) 'suite @defm " ++
            "99 tests first @test " ++
            "dup 'ok dict.has? {'kind 'user} assert " ++
            "'ok at [0 42] match? {'kind 'user} assert " ++
            "99 = {'kind 'user} assert",
    );
}

test "testing: test executions share durable module state" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initTest(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] (0 ((1 + dup without) within) 'first test " ++
            "((dup without) within) 'second test) 'stateful @defm " ++
            "tests first @test 'ok at first 1 = {'kind 'user} assert " ++
            "tests 1 at @test 'ok at first 1 = {'kind 'user} assert",
    );
}

test "testing: reload and removal replace the discoverable test catalog coherently" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initTest(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] ((1) 'old test) 'changing @defm " ++
            "tests first 'stale set " ++
            "[] ((2) 'new test) 'changing @defm " ++
            "tests dup len 1 = {'kind 'user} assert " ++
            "first 'name at 'new match? {'kind 'user} assert " ++
            "stale @test 'err dict.has? {'kind 'user} assert " ++
            "'changing unmodule tests len 0 = {'kind 'user} assert",
    );
}

test "testing: test discovery exposes metadata but not executable bodies" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initTest(backing.allocator(), &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] ((x -- y : \"Documented test.\") (dup) 'metadata test) 'catalog @defm " ++
            "tests first " ++
            "dup 'module dict.has? {'kind 'user} assert " ++
            "dup 'name dict.has? {'kind 'user} assert " ++
            "dup 'effect dict.has? {'kind 'user} assert " ++
            "dup 'doc dict.has? {'kind 'user} assert " ++
            "dup 'body dict.has? not {'kind 'user} assert " ++
            "dict.size 4 = {'kind 'user} assert",
    );
}

test "testing: large test catalogs remain cancellable" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.initTest(backing.allocator(), &.{});
    defer runtime.deinit();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "[] (");
    for (0..300) |index| {
        const declaration = try std.fmt.allocPrint(
            std.testing.allocator,
            "(1) 'case-{d} test ",
            .{index},
        );
        defer std.testing.allocator.free(declaration);
        try source.appendSlice(std.testing.allocator, declaration);
    }
    try source.appendSlice(std.testing.allocator, ") 'large.catalog @defm");
    try expectOk(&runtime, source.items);

    runtime.requestCancellation();
    try expectErrContains(&runtime, "tests", "unit cancelled");
    try std.testing.expect(runtime.lastPolls() >= 1);
    runtime.clearCancellation();
    try expectOk(&runtime, "tests len 300 = {'kind 'user} assert");
    try std.testing.expect(runtime.lastPolls() > 1);
}
