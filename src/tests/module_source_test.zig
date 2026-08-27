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

test "loader: locked project resolves full module names through the longest package prefix" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeTwoPackageLock("foo", "1.0.0", hash_a, "foo.bar", "2.0.0", hash_b);
    try fixture.writeStoreModule("foo", "1.0.0", hash_a, "foo.bar.baz", 1);
    try fixture.writeStoreModule("foo.bar", "2.0.0", hash_b, "foo.bar.baz", 2);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .environ = &environ,
    });
    defer runtime.deinit();
    try expectOk(&runtime, "foo.bar.baz.answer");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
}

test "loader: embedded modules precede lock and unmatched names continue to ECL PATH" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeTwoPackageLock("result", "1.0.0", hash_a, "foo", "1.0.0", hash_b);
    try fixture.writeStoreModule("result", "1.0.0", hash_a, "result", 999);
    try fixture.writeStoreWord("foo", "1.0.0", hash_b, "foo", "bar", 42);
    try fixture.writeCurrentWord("foo", "bar", 9);
    try fixture.writeCurrentWord("site-local", "answer", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        // Make the project-start directory an explicit path candidate too:
        // the lock must still own foo.bar while an unmatched local name loads.
        .ecl_path = fixture.nested,
        .environ = &environ,
    });
    defer runtime.deinit();
    try expectOk(&runtime, "[1] result.ok foo.bar site-local.answer");
    try std.testing.expect(runtime.stackItems()[0] == .dict);
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[2].int);
}

test "loader: absent marker or lock preserves ECL PATH behavior" {
    var fixture = try LockFixture.initWithoutMarker();
    defer fixture.deinit();
    try fixture.writePathModule("legacy", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .ecl_path = fixture.search,
    });
    defer runtime.deinit();
    try expectOk(&runtime, "legacy.answer");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
}

test "loader: project discovery walks upward and snapshots one sibling lock" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("snap", "1.0.0", hash_a);
    try fixture.writeStoreModule("snap", "1.0.0", hash_a, "snap", 1);
    try fixture.writeStoreModule("snap", "2.0.0", hash_b, "snap", 2);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .environ = &environ,
    });
    defer runtime.deinit();
    try fixture.writeOnePackageLock("snap", "2.0.0", hash_b);
    try expectOk(&runtime, "snap.answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
}

test "loader: malformed lock is authoritative after embedded resolution" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.write("project/ecl.lock", "{'format 99}\n");
    try fixture.writePathModule("local", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .ecl_path = fixture.search,
    });
    defer runtime.deinit();
    try expectOk(&runtime, "[1] result.ok pop");
    try expectErrorContains(&runtime, "local.answer", &.{ "'kind 'io", "invalid project lock" });
}

test "loader: invalid project marker is reported as invalid project lock discovery" {
    var fixture = try LockFixture.initWithoutMarker();
    defer fixture.deinit();
    try fixture.directory.dir.createDir(std.testing.io, "project/ecl.pkg", .default_dir);
    try fixture.writePathModule("local", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const lock_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "project", "ecl.lock" },
    );
    defer std.testing.allocator.free(lock_path);
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .ecl_path = fixture.search,
    });
    defer runtime.deinit();
    try expectErrorContains(&runtime, "local.answer", &.{
        "'kind 'io",
        "invalid project lock",
        lock_path,
        "project marker",
    });
}

test "loader: a cache lock without cache environment gives actionable store selection" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("missing", "1.0.0", hash_a);
    try fixture.writePathModule("missing", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .ecl_path = fixture.search,
        .environ = &.{},
    });
    defer runtime.deinit();
    try expectErrorContains(&runtime, "missing.answer", &.{
        "'kind 'io",
        "missing",
        "ECL_CACHE",
        "XDG_CACHE_HOME",
        "HOME",
    });
}

test "loader: missing locked store entry names package and pkg sync without path fallback" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("missing", "1.0.0", hash_a);
    try fixture.writePathModule("missing", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .ecl_path = fixture.search,
        .environ = &environ,
    });
    defer runtime.deinit();
    try expectErrorContains(&runtime, "missing.answer", &.{ "'kind 'io", "missing", "ecl pkg sync" });
}

test "loader: matched package never falls through for a missing module" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("partial", "1.0.0", hash_a);
    try fixture.createStore("partial", "1.0.0", hash_a);
    try fixture.writePathModule("partial.child", 7);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.initWithHost(backing.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .project_start = fixture.nested,
        .ecl_path = fixture.search,
        .environ = &environ,
    });
    defer runtime.deinit();
    try expectErrorContains(
        &runtime,
        "partial.child.answer",
        &.{ "'kind 'undefined-word", "partial.child", "partial" },
    );
}

const sessionHostEntry = @import("../machine.zig").Environ.Entry;
const hash_a = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "sha256-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const LockFixture = struct {
    directory: std.testing.TmpDir,
    root: [:0]u8,
    nested: []u8,
    cache: []u8,
    search: []u8,

    fn init() !LockFixture {
        return initMarker(true);
    }

    fn initWithoutMarker() !LockFixture {
        return initMarker(false);
    }

    fn initMarker(marker: bool) !LockFixture {
        const allocator = std.testing.allocator;
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const root = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(root);
        try directory.dir.createDir(std.testing.io, "project", .default_dir);
        try directory.dir.createDir(std.testing.io, "project/nested", .default_dir);
        try directory.dir.createDir(std.testing.io, "cache", .default_dir);
        try directory.dir.createDir(std.testing.io, "path", .default_dir);
        if (marker) try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/ecl.pkg",
            .data = "{'format 1 'name \"root\" 'version \"0.1.0\" 'requires {}}\n",
        });
        const nested = try std.fs.path.join(allocator, &.{ root, "project", "nested" });
        errdefer allocator.free(nested);
        const cache = try std.fs.path.join(allocator, &.{ root, "cache" });
        errdefer allocator.free(cache);
        const search = try std.fs.path.join(allocator, &.{ root, "path" });
        return .{ .directory = directory, .root = root, .nested = nested, .cache = cache, .search = search };
    }

    fn deinit(self: *LockFixture) void {
        const allocator = std.testing.allocator;
        allocator.free(self.search);
        allocator.free(self.cache);
        allocator.free(self.nested);
        allocator.free(self.root);
        self.directory.cleanup();
    }

    fn write(self: *LockFixture, path: []const u8, data: []const u8) !void {
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn writeOnePackageLock(
        self: *LockFixture,
        package: []const u8,
        version: []const u8,
        hash: []const u8,
    ) !void {
        const text = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 1\n 'root \"root\"\n 'packages\n {{\"{s}\" {{'version \"{s}\" 'url \"https://example.invalid/{s}.tgz\" 'hash \"{s}\"}}}}\n 'requires\n {{\"root\" {{\"{s}\" \"{s}\"}}}}}}\n",
            .{ package, version, package, hash, package, version },
        );
        defer std.testing.allocator.free(text);
        try self.write("project/ecl.lock", text);
    }

    fn writeTwoPackageLock(
        self: *LockFixture,
        first: []const u8,
        first_version: []const u8,
        first_hash: []const u8,
        second: []const u8,
        second_version: []const u8,
        second_hash: []const u8,
    ) !void {
        const text = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 1\n 'root \"root\"\n 'packages\n {{\"{s}\" {{'version \"{s}\" 'url \"https://example.invalid/{s}.tgz\" 'hash \"{s}\"}} \"{s}\" {{'version \"{s}\" 'url \"https://example.invalid/{s}.tgz\" 'hash \"{s}\"}}}}\n 'requires\n {{\"root\" {{\"{s}\" \"{s}\" \"{s}\" \"{s}\"}}}}}}\n",
            .{ first, first_version, first, first_hash, second, second_version, second, second_hash, first, first_version, second, second_version },
        );
        defer std.testing.allocator.free(text);
        try self.write("project/ecl.lock", text);
    }

    fn createStore(
        self: *LockFixture,
        package: []const u8,
        version: []const u8,
        hash: []const u8,
    ) !void {
        const path = try std.fmt.allocPrint(
            std.testing.allocator,
            "cache/{s}-{s}-{s}",
            .{ package, version, hash[7..] },
        );
        defer std.testing.allocator.free(path);
        self.directory.dir.createDir(std.testing.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    fn writeStoreModule(
        self: *LockFixture,
        package: []const u8,
        version: []const u8,
        hash: []const u8,
        module_name: []const u8,
        answer: i64,
    ) !void {
        try self.writeStoreWord(package, version, hash, module_name, "answer", answer);
    }

    fn writeStoreWord(
        self: *LockFixture,
        package: []const u8,
        version: []const u8,
        hash: []const u8,
        module_name: []const u8,
        word_name: []const u8,
        answer: i64,
    ) !void {
        try self.createStore(package, version, hash);
        const path = try std.fmt.allocPrint(
            std.testing.allocator,
            "cache/{s}-{s}-{s}/{s}.ecl",
            .{ package, version, hash[7..], module_name },
        );
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "(({d}) '{s} def) '{s} @defm\n",
            .{ answer, word_name, module_name },
        );
        defer std.testing.allocator.free(source);
        try self.write(path, source);
    }

    fn writePathModule(self: *LockFixture, module_name: []const u8, answer: i64) !void {
        try self.writePathWord(module_name, "answer", answer);
    }

    fn writePathWord(
        self: *LockFixture,
        module_name: []const u8,
        word_name: []const u8,
        answer: i64,
    ) !void {
        const path = try std.fmt.allocPrint(std.testing.allocator, "path/{s}.ecl", .{module_name});
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "(({d}) '{s} def) '{s} @defm\n",
            .{ answer, word_name, module_name },
        );
        defer std.testing.allocator.free(source);
        try self.write(path, source);
    }

    fn writeCurrentWord(
        self: *LockFixture,
        module_name: []const u8,
        word_name: []const u8,
        answer: i64,
    ) !void {
        const path = try std.fmt.allocPrint(
            std.testing.allocator,
            "project/nested/{s}.ecl",
            .{module_name},
        );
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "(({d}) '{s} def) '{s} @defm\n",
            .{ answer, word_name, module_name },
        );
        defer std.testing.allocator.free(source);
        try self.write(path, source);
    }
};

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
    try expectOk(&runtime, "(40 's setp ( -- n ) (s 2 +) 'f def) 'm @defm m.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "(( -- n ) (41) 'g defp ( -- n ) (g 1 +) 'f def) 'private-word @defm private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "private-word.g", &.{ "'kind 'undefined-word", "'word 'private-word.g" });
    try expectErrorContains(&runtime, "1 'x setp", &.{ "'kind 'domain", "defp/setp" });
    // A body that leaves values behind registers: they become the slot's
    // durable stack, not bindings, so no name appears for them.
    try expectOk(&runtime, "(1) 'bad @defm");
    try expectErrorContains(&runtime, "bad.x", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "((1 'hidden set) @attempt pop) 'temporary @defm");
    try expectErrorContains(&runtime, "temporary.hidden", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "(( -- n ) (missing) 'boom def) 'trace-module @defm");
    try expectErrorContains(&runtime, "trace-module.boom", &.{ "'word 'missing", "'trace ['missing 'trace-module.boom]" });
    try expectOk(&runtime, "(( n -- n ) (dup 0 > (1 - f 1 +) (pop missing) if) 'f def) 'recursive @defm");
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
        "( -- n ) ((2 'x setp ( -- n ) (x) 'get def) 'm @defm x) 'probe def " ++
        "( -- n ) (x) 'get def) 'm @defm m.probe m.get");
    // `probe` reloads its own module and then reads `x`. A module-written word
    // anchors to the generation its activation entered, so the read lands in
    // the image `probe` itself was written in; code on the stack is never
    // re-pointed under itself. The fresh `m.get` afterwards follows the name to
    // the generation that replaced it.
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "(3 'x setp missing) 'm @defm", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "m.get");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "(( -- n ) (9) 'get def) 'kept @defm missing", &.{"'kind 'undefined-word"});
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
    try expectErrorContains(&runtime, "((a -- b -- c) (dup) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "((a 1 -- b) (dup) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectOk(&runtime, "(( n -- ) (dup 0 > (1 - countdown) (pop) if) 'countdown def) 'm @defm");
    try expectOk(&runtime, "20 m.countdown");
    const shallow_frames = runtime.lastMaxFrames();
    try expectOk(&runtime, "20000 m.countdown");
    try std.testing.expectEqual(shallow_frames, runtime.lastMaxFrames());
    try expectErrorContains(&runtime, "(( a -- b c ) (dup +) 'f def) 'lies @defm 1 lies.f", &.{ "'kind 'contract", "'word 'lies.f" });
    try expectErrorContains(&runtime, "(( a -- a a ) (dup) 'f def) 'needs @defm needs.f", &.{ "'kind 'contract", "seeded 0" });
    try expectErrorContains(&runtime, "(( -- n ) (missing) 'f def) 'throws @defm throws.f", &.{ "'kind 'undefined-word", "'word 'missing" });
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
    try expectOk(&runtime, "(3 'mean set ( -- n : \"Count.\") (4) 'count def 5 'other set) 'stats @defm " ++
        "1 'mean set 'stats.mean 'mean import mean 'stats.count 'count import count " ++
        "'count doc \"Count.\" match? 'count see");
    try std.testing.expectEqualStrings("", diagnostics.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- n : \"Count.\") (stats.count) 'count def") != null);
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 4), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
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

test "module: import inside a module body binds module-locally" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // `import` used to reach for top-level publication unconditionally, so a
    // module root aborted the process on an `unreachable` inside the scope's
    // publication method. It now takes the same module sink `def` takes there.
    try expectOk(&runtime, "((1) 'x def) 'src @defm ('src.x 'y import) 'holder @defm holder.y");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    // The binding landed in the image, not in the session that ran `@defm`.
    try expectErrorContains(&runtime, "y", &.{ "'kind 'undefined-word", "'word 'y" });
}

test "scope: a binding resolves in the scope it was defined in, child scopes included" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // Both definitions land in the `@attempt` child, so the second resolves
    // the first. Reading the unit root instead left siblings invisible to each
    // other, which was the last exception to "resolves where it was defined".
    try expectOk(&runtime, "((1) 'helper def (helper) 'caller def caller) @attempt 'ok at first");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    // A child definition is still dynamic: it does not outlive its boundary.
    try expectErrorContains(&runtime, "helper", &.{ "'kind 'undefined-word", "'word 'helper" });
}

test "scope: an undefined word names the chain it searched" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    try expectErrorContains(&runtime, "nope", &.{"'scope 'session"});
    // A module cannot see the session, and says so rather than leaving the
    // reader to work out why a name they just defined is missing.
    try expectErrorContains(&runtime, "(1) 'base def ((base) 'r def) 'm @defm m.r", &.{
        "'scope 'module",
        "'word 'base",
    });
    // A dotted reference searched the registry, not any lexical chain.
    try expectErrorContains(&runtime, "((7) 'answer def) 'named @defm named.nope", &.{"'scope 'qualified"});
    try expectErrorContains(&runtime, "no.such.word", &.{"'scope 'qualified"});
    // A missing export of a module *value* is not a scope miss at all.
    try expectErrorContains(&runtime, "((7) 'answer def) @module 'nope invoke", &.{"'scope 'module-value"});
}

test "module: a construction sees only its parameters its own definitions and core" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // A module body's chain is its own definitions then core. A session name
    // is not in it, however recently it was defined.
    try expectOk(&runtime, "(1) 'base def");
    try expectErrorContains(&runtime, "((base) 'read def) 'unparameterized @defm unparameterized.read", &.{
        "'kind 'undefined-word",
        "'word 'base",
    });
    // Parameterization is the way in, and it is the ordinary seeding
    // composition rather than a construction-specific mechanism.
    try expectOk(&runtime, "[41] ('base set ( -- n ) (base 1 +) 'go def) seed 'seeded @defm seeded.go");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    // Core stays reachable, so a module needs no parameter for `+`.
    try expectOk(&runtime, "((2 3 +) 'go def) 'core-only @defm core-only.go");
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[1].int);
    // This is about the module's own chain only. A homeless word the module
    // calls — a primitive or an embedded prelude definition — still resolves
    // against the lexical chain it was defined in.
}

test "module: a parameterized behavior dependency is a quotation the caller wrote" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // Behavior arrives as a quotation the caller writes, which is the functor
    // discipline: the caller writes the structure it hands in. There is no way
    // to hand over an existing word, because nothing extracts a published
    // body — to share a word, both parties call a module.
    try expectOk(&runtime, "[(dup +)] ('double def ( -- n ) (4 double) 'go def) seed 'w @defm w.go");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[0].int);
    // Nothing later can reach it: the image holds the quotation it was handed,
    // and a session name of the same spelling is not in its chain.
    try expectOk(&runtime, "(99) 'double def w.go");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[1].int);
    // Purity is the unit-constructor boundary, not transitivity: `@defm` runs
    // the construction body in the image's chain whatever scope its text was
    // written in, so a bare `k` inside the body is undefined however recently
    // the session defined one.
    try expectOk(&runtime, "((k *) 'scale def) 'body-dep @defm");
    try expectErrorContains(&runtime, "body-dep.scale", &.{
        "'kind 'undefined-word",
        "'word 'k",
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
    try expectOk(&runtime, "(40 's setp ( -- n ) (s 2 +) 'f def) 'm @defm 'm.f 'f import " ++
        "'m.f see 9 'f set 'f which 'f see words");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- n) (s 2 +) 'm.f def") != null);
    // One binding kind: a session constant reports as a public def with no
    // metadata, because the sugar supplies none, and `see` prints the stored
    // literal capture rather than reconstructing the `set` spelling.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "f -> f def public") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "shadows m.f") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([9] first) 'f def") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " s ") == null);
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
    try expectOk(&runtime, "(7 'x set 8 'h setp (-- n) (h) 'peek def) 'm @defm");
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
    try expectOk(&runtime, "(7 'x set 8 'h setp (-- n) (h) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x 'm.x 'x import x m.peek");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[2].int);
    // The frame is a real contract for `(-- value)` declarations: a module
    // word declaring it and leaving two values is a contract violation.
    try expectErrorContains(
        &runtime,
        "((-- value) (1 2) 'two def) 'liar @defm liar.two",
        // Seeded/observed are absolute stack depths, so assert the parts that
        // do not depend on what this session left on the stack.
        &.{ "'kind 'contract", "'word 'liar.two", "declared (0 -- 1)" },
    );
}

test "module: a module literal reaches its own private through a combinator" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // `(pop secret)` is written inside the module body, so it resolves in the
    // image whichever activation hands it to `each`.
    try expectOk(&runtime, "((41) 'secret defp ([1] (pop secret) each first) 'go def) 'm @defm m.go");
    try std.testing.expectEqual(@as(i64, 41), runtime.stackItems()[0].int);
    // A session name of the same spelling does not perturb it.
    try expectOk(&runtime, "(99) 'secret def m.go");
    try std.testing.expectEqual(@as(i64, 41), runtime.stackItems()[1].int);
}

test "module: a module word runs a caller's quotation in the caller's chain" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // The caller wrote `(bump)`, so `bump` resolves in the caller even though
    // the activation applying it belongs to the module.
    try expectOk(&runtime, "((|q| 2 q call) 'apply def) 'm @defm (1 +) 'bump def (bump) m.apply");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    // The stdlib higher-order words are the same case, and the second of
    // ticket ecl#4's two reproductions.
    try expectOk(&runtime, "[1] result.ok (bump) result.and-then pop");
}

test "module: a quotation parameter carries the caller's scope" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // The caller wrote `(k *)`, so its own references are the caller's and the
    // module needs no parameter for them. `def`-ing it makes the binding
    // module-local without re-siting what it refers to.
    try expectOk(&runtime, "(10) 'k def " ++
        "[(k *)] ('scale def ( -- n ) (4 scale) 'go def) seed 'caller-dep @defm caller-dep.go");
    try std.testing.expectEqual(@as(i64, 40), runtime.stackItems()[0].int);
}

test "module: every container the reader built inside a body is the module's text" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // Three spellings of one thing. A quotation the reader built inside the
    // body names the image whatever container holds it, so all three reach the
    // module's own private rather than the session's binding. The dict literal
    // is the one that used to disagree, because the restamp stopped at dicts.
    try expectOk(&runtime, "(10) 'k def");
    try expectOk(&runtime, "((99) 'k defp [(k)] 'd setp ( -- n ) (d first call) 'go def) 'l @defm l.go");
    try std.testing.expectEqual(@as(i64, 99), runtime.stackItems()[0].int);
    try expectOk(&runtime, "((99) 'k defp {'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'dl @defm dl.go");
    try std.testing.expectEqual(@as(i64, 99), runtime.stackItems()[1].int);
    try expectOk(&runtime, "((99) 'k defp ('a) ((k)) dict.from-lists 'd setp ( -- n ) (d 'a at call) 'go def) 'td @defm td.go");
    try std.testing.expectEqual(@as(i64, 99), runtime.stackItems()[2].int);
    // And with no private to find, the session binding is still not reachable.
    try expectErrorContains(
        &runtime,
        "({'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'leak @defm leak.go",
        &.{ "'kind 'undefined-word", "'word 'k" },
    );
}

test "module: an undefined word names the chain its own scope searched" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // The reported chain comes from the word's scope, not from the running
    // activation. A caller's quotation applied by a module word searched the
    // caller, and saying `'module` there would name the one place it did not
    // look.
    try expectOk(&runtime, "((|q| q call) 'apply def) 'm @defm");
    try expectErrorContains(&runtime, "(nope) m.apply", &.{ "'word 'nope", "'scope 'session" });
    try expectOk(&runtime, "((missing) 'f def) 'own @defm");
    try expectErrorContains(&runtime, "own.f", &.{ "'word 'missing", "'scope 'module" });
    try expectErrorContains(&runtime, "nope", &.{ "'word 'nope", "'scope 'session" });
}

test "module: a session quotation still resolves in the session" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // Unchanged by the label rule: the session wrote these, so the session is
    // where they resolve.
    try expectOk(&runtime, "(7) 'mine def [1 2] (pop mine) each first");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try expectOk(&runtime, "(pop pop 42) '+ def [1 2 3] 0 (+) fold");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
}

test "module: a body that reloads its own name keeps its entry generation" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{});
    defer runtime.deinit();
    // `probe` re-registers its own name and then reads its private `x`. Code on
    // the activation stack is never re-pointed under itself, so the read lands
    // in the generation `probe` was entered with; a fresh entry afterwards
    // follows the name to the generation that replaced it.
    try expectOk(&runtime, "(1 'x setp " ++
        "( -- n ) ((2 'x setp ( -- n ) (x) 'get def) 'm @defm x) 'probe def " ++
        "( -- n ) (x) 'get def) 'm @defm m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
}
