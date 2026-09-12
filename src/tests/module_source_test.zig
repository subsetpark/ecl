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
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const intern = @import("../intern.zig");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");

const standalone_map =
    \\{'format 1 'local "local" 'scopes {
    \\ "local" {'root "." 'visible ["direct"] 'sources ["local/*.ecl"] 'artifacts []}
    \\ "direct" {'root "." 'visible ["indirect"] 'sources [] 'artifacts [
    \\   {'path "direct.ecl" 'kind 'ecl 'exports ["direct" "sibling"]}]}
    \\ "indirect" {'root "." 'visible [] 'sources [] 'artifacts [
    \\   {'path "indirect.ecl" 'kind 'ecl 'exports ["indirect"]}]}}}
;

test "loader: standalone maps capture local discovery and enforce direct lexical visibility" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    const dir = inputs.temporary.dir;
    try dir.createDir(std.testing.io, "local", .default_dir);
    try dir.writeFile(std.testing.io, .{ .sub_path = "ecl.modules", .data = standalone_map });
    try dir.writeFile(std.testing.io, .{ .sub_path = "local/one.ecl", .data = "[] ((10) 'answer def) 'localmod @defm" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "direct.ecl", .data = "[] ((indirect.answer) 'answer def) 'direct @defm [] ((7) 'answer def) 'sibling @defm" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "indirect.ecl", .data = "[] ((42) 'answer def) 'indirect @defm" });
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .cooperative, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "localmod.answer direct.answer sibling.answer");
    try std.testing.expectEqual(@as(i64, 10), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "indirect.answer", &.{"does not require it"});
    // An already committed source is not executed again, even after removal.
    try dir.deleteFile(std.testing.io, "direct.ecl");
    try expectOk(&runtime, "direct.answer sibling.answer");
    try dir.writeFile(std.testing.io, .{ .sub_path = "local/two.ecl", .data = "[] ((20) 'answer def) 'newlocal @defm" });
    try expectErrorContains(&runtime, "newlocal.answer", &.{"not exported"});
    var next = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .cooperative, .evaluate);
    defer next.deinit();
    try expectOk(&next, "newlocal.answer");
    try std.testing.expectEqual(@as(i64, 20), next.stackItems()[0].int);
}

test "loader: map references relocate and malformed nearest maps fail closed" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    const dir = inputs.temporary.dir;
    try dir.createDir(std.testing.io, "local", .default_dir);
    try dir.createDir(std.testing.io, "maps", .default_dir);
    const complete = "{'format 1 'local \"root\" 'scopes {\"root\" {'root \"..\" 'visible [] 'sources [\"local/*.ecl\"] 'artifacts []}}}";
    try dir.writeFile(std.testing.io, .{ .sub_path = "maps/complete", .data = complete });
    try dir.writeFile(std.testing.io, .{ .sub_path = "ecl.modules", .data = "{'format 1 'map \"maps/complete\"}" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "local/entry.ecl", .data = "[] ((3) 'answer def) 'mapped @defm" });
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .cooperative, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "mapped.answer");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try dir.writeFile(std.testing.io, .{ .sub_path = "ecl.modules", .data = "broken" });
    try std.testing.expectError(error.InvalidHostConfig, session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .cooperative, .evaluate));
    var explicit = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{ .module_map = "maps/complete" }), .cooperative, .evaluate);
    defer explicit.deinit();
    try expectOk(&explicit, "mapped.answer");
    try dir.writeFile(std.testing.io, .{ .sub_path = "maps/chained", .data = "{'format 1 'map \"complete\"}" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "maps/complete", .data = "{'format 1 'map \"chained\"}" });
    try std.testing.expectError(error.InvalidHostConfig, session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{ .module_map = "maps/complete" }), .cooperative, .evaluate));
}

test "loader: map validation and snapshot construction clean up every allocation failure" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    try inputs.temporary.dir.createDir(std.testing.io, "local", .default_dir);
    try inputs.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "local/one.ecl", .data = "[] () 'localmod @defm" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ inputs.cwd, "ecl.modules" });
    defer std.testing.allocator.free(path);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, filename: []const u8, cwd: []const u8) !void {
            var owner = @import("../heap.zig").HostOwner.init(allocator);
            defer owner.cleanup().drain();
            const map = try @import("../module_map.zig").validate(owner.cleanup(), std.testing.io, standalone_map, filename, true);
            defer map.deinit();
            const snapshot = try @import("../pkg_lock.zig").ProjectLock.fromMap(owner.cleanup(), map, cwd);
            defer snapshot.deinit();
            var lookup = snapshot.lookupCursor(snapshot.rootPackage(), "direct");
            defer lookup.deinit();
            while (true) switch (lookup.advance()) {
                .pending => {},
                .complete => |outcome| {
                    try std.testing.expect(outcome == .matched);
                    break;
                },
            };
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ path, inputs.cwd });
}

test "loader: maps load native artifacts through concurrent public requests" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    const native_root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, @import("native_fixture_options").directory, std.testing.allocator);
    defer std.testing.allocator.free(native_root);
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{'format 1 'local \"local\" 'scopes {{" ++
            "\"local\" {{'root \".\" 'visible [\"native\"] 'sources [] 'artifacts []}} " ++
            "\"native\" {{'root \"{s}\" 'visible [] 'sources [] 'artifacts [" ++
            "{{'path \"sample.eclmod\" 'kind 'native 'exports [\"sample\"]}}]}}}}}}",
        .{native_root},
    );
    defer std.testing.allocator.free(source);
    try inputs.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "ecl.modules", .data = source });
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .{ .worker_pool = 4 }, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (40 sample.increment) @spawn [] (41 sample.increment) @spawn task.await 'ok at pop task.await 'ok at pop 9 sample.increment");
    try std.testing.expectEqual(@as(i64, 10), runtime.stackItems()[0].int);
}

const CatalogIoObservation = struct {
    var catalog_reads: usize = 0;
    var source_reads: usize = 0;
    var dependency_walks: usize = 0;

    fn openFile(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        if (std.mem.endsWith(u8, path, ".ecl-package.catalog")) catalog_reads += 1;
        if (std.mem.endsWith(u8, path, ".ecl")) source_reads += 1;
        return std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
    }
    fn openDir(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
        if (options.iterate and std.mem.indexOf(u8, path, "/cache/") != null) dependency_walks += 1;
        return std.testing.io.vtable.dirOpenDir(userdata, dir, path, options);
    }
};

test "loader: startup reads dependency metadata and first use opens the source" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("dep", "1.0.0", hash_a);
    try fixture.writeStoreModule("dep", "1.0.0", hash_a, "dep", 42);
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenFile = CatalogIoObservation.openFile;
    vtable.dirOpenDir = CatalogIoObservation.openDir;
    const observed: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    CatalogIoObservation.catalog_reads = 0;
    CatalogIoObservation.source_reads = 0;
    CatalogIoObservation.dependency_walks = 0;
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{
        .io = observed,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .cooperative, .evaluate);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), CatalogIoObservation.catalog_reads);
    try std.testing.expectEqual(@as(usize, 0), CatalogIoObservation.source_reads);
    try std.testing.expectEqual(@as(usize, 0), CatalogIoObservation.dependency_walks);
    try expectOk(&runtime, "dep.answer");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try std.testing.expect(CatalogIoObservation.source_reads > 0);
}

test "loader: catalog exports resolve with non-lexical IDs and reversed persisted exports" {
    // Force fresh discovery's lexical order and persisted metadata order to
    // disagree with their respective intern-ID orders before opening a Session.
    _ = try intern.internModuleName("root.order-z");
    _ = try intern.internModuleName("root.order-a");
    _ = try intern.internModuleName("dep.order-a");
    _ = try intern.internModuleName("dep.order-z");
    inline for ([_]bool{ false, true }) |persisted| {
        var fixture = try LockFixture.init();
        defer fixture.deinit();
        const source = if (persisted)
            "[] ((11) 'answer def) 'dep.order-a @defm [] ((22) 'answer def) 'dep.order-z @defm"
        else
            "[] ((11) 'answer def) 'root.order-a @defm [] ((22) 'answer def) 'root.order-z @defm";
        if (persisted) {
            try fixture.writeOnePackageLock("dep", "1.0.0", hash_a);
            try fixture.writeStoreArtifact("dep", "1.0.0", hash_a, "order.ecl", "\"dep.order-z\" \"dep.order-a\"", source, .{});
        } else {
            try fixture.write("project/ecl.lock", "{'format 2 'root \"root\" 'packages {} 'requires {\"root\" {}}}");
            try fixture.write("project/ecl.pkg", "{'format 2 'name \"root\" 'version \"0.1.0\" " ++
                "'sources [\"*.ecl\"] 'exports [\"root.order-a\" \"root.order-z\"] 'requires {}}");
            try fixture.write("project/order.ecl", source);
        }
        var backing: test_heap.SessionHeap = .init;
        defer test_heap.retire(&backing);
        var inputs = try runtime_fixture.Fixture.init();
        defer inputs.deinit();
        const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
        var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{
            .initial_cwd = fixture.nested,
            .environ = &environ,
        }), .cooperative, .evaluate);
        defer runtime.deinit();
        try expectOk(&runtime, if (persisted) "dep.order-a.answer dep.order-z.answer" else "root.order-a.answer root.order-z.answer");
        try std.testing.expectEqual(@as(i64, 11), runtime.stackItems()[0].int);
        try std.testing.expectEqual(@as(i64, 22), runtime.stackItems()[1].int);
    }
}

test "loader: invalid dependency catalogs fail closed with sync diagnostics" {
    const invalid = [_]?[]const u8{
        null,                                                                                                                                                 "not inert metadata",                                                                                                         "{'format 2 'name \"dep\" 'version \"1.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources []}",
        "{'format 1 'name \"other\" 'version \"1.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources []}",                                                              "{'format 1 'name \"dep\" 'version \"2.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources []}",                                        "{'format 1 'name \"dep\" 'version \"1.0.0\" 'hash \"" ++ hash_b ++ "\" 'sources []}",
        "{'format 1 'name \"dep\" 'version \"1.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources [{'path \"../dep.ecl\" 'exports [\"dep\"]}]}",                       "{'format 1 'name \"dep\" 'version \"1.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources [{'path \"/dep.ecl\" 'exports [\"dep\"]}]}", "{'format 1 'name \"dep\" 'version \"1.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources [{'path \"dep.ecl\" 'exports [\"dep\" \"dep\"]}]}",
        "{'format 1 'name \"dep\" 'version \"1.0.0\" 'hash \"" ++ hash_a ++ "\" 'sources [{'path \"dep.ecl\" 'exports []} {'path \"dep.ecl\" 'exports []}]}",
    };
    for (invalid) |metadata| {
        var fixture = try LockFixture.init();
        defer fixture.deinit();
        try fixture.writeOnePackageLock("dep", "1.0.0", hash_a);
        try fixture.writeStoreModule("dep", "1.0.0", hash_a, "dep", 42);
        const path = "cache/dep-1.0.0-" ++ hash_a[7..] ++ "/.ecl-package.catalog";
        if (metadata) |text| try fixture.write(path, text) else try fixture.directory.dir.deleteFile(std.testing.io, path);
        var backing: test_heap.SessionHeap = .init;
        defer test_heap.retire(&backing);
        var inputs = try runtime_fixture.Fixture.init();
        defer inputs.deinit();
        const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
        var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{
            .initial_cwd = fixture.nested,
            .environ = &environ,
        }), .cooperative, .evaluate);
        defer runtime.deinit();
        try expectErrorContains(&runtime, "dep.answer", &.{ "dep", "catalog", "ecl pkg sync" });
        if (metadata) |text| {
            const unchanged = try fixture.directory.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
            defer std.testing.allocator.free(unchanged);
            try std.testing.expectEqualStrings(text, unchanged);
        } else try std.testing.expectError(error.FileNotFound, fixture.directory.dir.statFile(std.testing.io, path, .{}));
    }
}

test "loader: local file additions and edits are discovered without sync" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.write("project/ecl.lock", "{'format 2 'root \"root\" 'packages {} 'requires {\"root\" {}}}\n");
    for ([_]bool{ false, true }) |edited| {
        try fixture.write("project/ecl.pkg", if (edited)
            "{'format 2 'name \"root\" 'version \"0.1.0\" 'sources [\"*.ecl\"] 'exports [\"root.one\" \"root.two\"] 'requires {}}\n"
        else
            "{'format 2 'name \"root\" 'version \"0.1.0\" 'sources [\"*.ecl\"] 'exports [\"root.one\"] 'requires {}}\n");
        try fixture.write("project/one.ecl", if (edited) "[] ((2) 'answer def) 'root.one @defm\n" else "[] ((1) 'answer def) 'root.one @defm\n");
        if (edited) try fixture.write("project/two.ecl", "[] ((3) 'answer def) 'root.two @defm\n");
        var backing: test_heap.SessionHeap = .init;
        defer test_heap.retire(&backing);
        var inputs = try runtime_fixture.Fixture.init();
        defer inputs.deinit();
        var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{ .initial_cwd = fixture.nested }), .cooperative, .evaluate);
        defer runtime.deinit();
        try expectOk(&runtime, "root.one.answer");
        try std.testing.expectEqual(@as(i64, if (edited) 2 else 1), runtime.stackItems()[0].int);
        if (edited) {
            try expectOk(&runtime, "root.two.answer");
            try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[1].int);
        }
    }
}

test "loader: private modules belong to their defining file independent of load order" {
    for ([_]bool{ false, true }) |bar_first| {
        var fixture = try LockFixture.init();
        defer fixture.deinit();
        try fixture.write("project/ecl.pkg", "{'format 2 'name \"root\" 'version \"0.1.0\" " ++
            "'sources [\"*.ecl\"] 'exports [\"root.foo\" \"root.bar\" \"root.other\"] 'requires {}}\n");
        try fixture.write("project/ecl.lock", "{'format 2 'root \"root\" 'packages {} 'requires {\"root\" {}}}\n");
        try fixture.write("project/foo.ecl", "[] ((99) 'answer def) 'root.foo.hidden @defm\n" ++
            "[] ((baz.answer) 'answer def (call) 'apply def " ++
            "(root.foo.hidden.answer) 'own def) 'root.foo @defm\n");
        try fixture.write("project/bar.ecl", "[] ((42) 'answer def) @module 'baz register\n" ++
            "[] ('baz ('answer) import " ++
            "((baz.answer)) 'quoted def " ++
            "(root.foo.answer) 'foreign def " ++
            "([] ((9) 'answer def) @module 'baz register) 'replace def) 'root.bar @defm\n");
        try fixture.write("project/other.ecl", "[] ((7) 'answer def) 'baz @defm\n" ++
            "[] ((baz.answer) 'answer def) 'root.other @defm\n");

        var backing: test_heap.SessionHeap = .init;
        defer test_heap.retire(&backing);
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .initial_cwd = fixture.nested,
        }), .default, .evaluate);
        defer runtime.deinit();

        if (bar_first) try expectOk(&runtime, "root.bar.answer pop");
        try expectErrorContains(&runtime, "root.foo.answer", &.{"not exported by the active project"});
        try expectOk(&runtime, "root.bar.answer root.other.answer root.bar.quoted root.foo.apply");
        try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
        try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
        try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[2].int);
        try expectErrorContains(&runtime, "root.bar.foreign", &.{"not exported by the active project"});
        try expectErrorContains(&runtime, "baz.answer", &.{"not exported by the active project"});
        try expectErrorContains(&runtime, "'baz ('answer) import", &.{"not exported by the active project"});
        try expectErrorContains(&runtime, "root.foo.hidden.answer", &.{"not exported by the active project"});
        try expectOk(&runtime, "root.foo.own 99 = {'kind 'user} assert");
        try expectOk(&runtime, "root.bar.replace root.bar.answer root.other.answer");
        try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[3].int);
        try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[4].int);
    }
}

test "loader: catalog cold-loads multiple full module names from an unrelated artifact name" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("stats", "1.0.0", hash_a);
    try fixture.writeStoreArtifact(
        "stats",
        "1.0.0",
        hash_a,
        "unrelated.ecl",
        "\"stats.regressions\" \"stats.distributions\"",
        "[] (({d}) 'answer def) 'stats.regressions @defm\n" ++
            "[] (({d}) 'answer def) 'stats.distributions @defm\n",
        .{ 1, 2 },
    );

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "stats.regressions.answer stats.distributions.answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
}

test "loader: the root package exports local source through the same catalog" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.write(
        "project/ecl.pkg",
        "{'format 2 'name \"root\" 'version \"0.1.0\" " ++
            "'sources [\"src/**/*\"] 'exports [\"root.local\"] 'requires {}}\n",
    );
    try fixture.write(
        "project/ecl.lock",
        "{'format 2 'root \"root\" 'packages {} 'requires {\"root\" {}}}\n",
    );
    try fixture.directory.dir.createDir(std.testing.io, "project/src", .default_dir);
    try fixture.write(
        "project/src/unrelated.ecl",
        "[] ((17) 'answer def) 'root.local @defm\n",
    );

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
    }), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(&runtime, "root.local.answer");
    try std.testing.expectEqual(@as(i64, 17), runtime.stackItems()[0].int);
}

test "loader: a root-defined module reaches its declared direct dependency" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.write(
        "project/ecl.pkg",
        "{'format 2 'name \"root\" 'version \"0.1.0\" " ++
            "'sources [\"src/**/*\"] 'exports [\"root.local\"] 'requires " ++
            "{\"dep\" {'package \"dep\" 'version \"1.0.0\" " ++
            "'source {'kind 'archive 'url \"https://example.invalid/dep.tgz\"} 'hash \"" ++ hash_a ++ "\"}}}\n",
    );
    try fixture.writeOnePackageLock("dep", "1.0.0", hash_a);
    try fixture.writeStoreModule("dep", "1.0.0", hash_a, "dep", 5);
    try fixture.directory.dir.createDir(std.testing.io, "project/src", .default_dir);
    try fixture.write(
        "project/src/unrelated.ecl",
        "[] ((dep.answer) 'answer def) 'root.local @defm\n",
    );

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(&runtime, "root.local.answer");
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[0].int);
}

test "loader: both manifest validators reject drive-prefixed source globs" {
    const pkg_catalog = @import("../pkg_catalog.zig");
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var owner = @import("../heap.zig").HostOwner.init(allocator);
    defer owner.cleanup().drain();
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{}), .cooperative, .evaluate);
    defer runtime.deinit();
    const cases = [_]struct { glob: []const u8, valid: bool }{
        .{ .glob = "C:/src/**/*.ecl", .valid = false },
        .{ .glob = "C:src/**/*.ecl", .valid = false },
        .{ .glob = "c:/src/**/*.ecl", .valid = false },
        .{ .glob = "z:src/**/*.ecl", .valid = false },
        .{ .glob = "C:", .valid = false },
        .{ .glob = "src/**/*.ecl", .valid = true },
        .{ .glob = "*.ecl", .valid = true },
        .{ .glob = "C", .valid = true },
        .{ .glob = "src/C:part/*.ecl", .valid = true },
        .{ .glob = "CC:src/**/*.ecl", .valid = true },
    };
    for (cases) |case| {
        const manifest = try std.fmt.allocPrint(allocator, "{{'format 2 'name \"dep\" 'version \"1.0.0\" 'sources [\"{s}\"] 'exports [] 'requires {{}}}}", .{case.glob});
        defer allocator.free(manifest);
        try directory.dir.writeFile(std.testing.io, .{ .sub_path = "ecl.pkg", .data = manifest });
        const source = try std.fmt.allocPrint(allocator, "{s} pkg.manifest.validate pop", .{manifest});
        defer allocator.free(source);
        if (case.valid) try expectOk(&runtime, source) else try expectErrorContains(&runtime, source, &.{"portable glob strings"});
        var diagnostic: ?[]u8 = null;
        defer if (diagnostic) |message| allocator.free(message);
        const result = pkg_catalog.build(owner.cleanup(), std.testing.io, &.{.{
            .id = @enumFromInt(0),
            .name = "dep",
            .version = "1.0.0",
            .root_dir = ".",
            .base_dir = directory.dir,
        }}, &diagnostic);
        if (case.valid) {
            var catalog = try result;
            defer catalog.deinit();
        } else {
            try std.testing.expectError(error.Invalid, result);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.?, "sources contains an invalid entry") != null);
        }
    }
}

test "loader: catalog discovery holds a manifest to the whole public contract" {
    // `pkg.store.install` seals a staged package against this boundary rather
    // than against `pkg.manifest.validate`, so anything the public validator
    // rejects has to fail here too. Each case below is one such rejection.
    const cases = [_]struct { requires: []const u8, needle: []const u8 }{
        .{
            .requires = "{\"dep\" {'package \"dep\" 'version \"1.0.0\" " ++
                "'source {'kind 'archive 'url \"http://e.com/d.tgz\"} 'hash \"" ++ hash_a ++ "\"}}",
            .needle = "has an invalid source",
        },
        .{
            .requires = "{\"dep\" {'package \"dep\" 'version \"1.0.0\"}}",
            .needle = "does not have the exact keys",
        },
        .{
            .requires = "{\"dep\" {'package \"dep\" 'version \"one\" " ++
                "'source {'kind 'archive 'url \"https://e.com/d.tgz\"} 'hash \"" ++ hash_a ++ "\"}}",
            .needle = "has a non-semver version",
        },
        .{
            .requires = "{\"dep\" {'package \"root.sub\" 'version \"1.0.0\" " ++
                "'source {'kind 'archive 'url \"https://e.com/d.tgz\"} 'hash \"" ++ hash_a ++ "\"}}",
            .needle = "one name owns the other",
        },
        .{
            .requires = "{\"one\" {'package \"dep\" 'version \"1.0.0\" " ++
                "'source {'kind 'archive 'url \"https://e.com/d.tgz\"} 'hash \"" ++ hash_a ++ "\"} " ++
                "\"two\" {'package \"dep\" 'version \"1.0.0\" " ++
                "'source {'kind 'archive 'url \"https://e.com/d.tgz\"} 'hash \"" ++ hash_a ++ "\"}}",
            .needle = "under more than one alias",
        },
        .{
            .requires = "((\"pwned\" 'cwd \"pkg-pwned\" fs.create-text))",
            .needle = "requires must be a dict",
        },
    };
    for (cases) |case| {
        var fixture = try LockFixture.init();
        defer fixture.deinit();
        const manifest = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 2 'name \"root\" 'version \"0.1.0\" " ++
                "'sources [\"src/**/*\"] 'exports [\"root.local\"] 'requires {s}}}\n",
            .{case.requires},
        );
        defer std.testing.allocator.free(manifest);
        try fixture.write("project/ecl.pkg", manifest);
        try fixture.write(
            "project/ecl.lock",
            "{'format 2 'root \"root\" 'packages {} 'requires {\"root\" {}}}\n",
        );
        try fixture.directory.dir.createDir(std.testing.io, "project/src", .default_dir);
        try fixture.write("project/src/a.ecl", "[] ((1) 'answer def) 'root.local @defm\n");

        var backing: test_heap.SessionHeap = .init;
        defer test_heap.retire(&backing);
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .initial_cwd = fixture.nested,
        }), .default, .evaluate);
        defer runtime.deinit();

        try expectErrorContains(
            &runtime,
            "root.local.answer",
            &.{ "invalid package catalog", case.needle },
        );
    }
}

test "loader: a lock may omit a requirer entry for a package that requires nothing" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    // `pkg.lock.validate` accepts, and `pkg.lock.write` emits, a lock whose
    // `requires` names only the requirers that have edges. Opening one must
    // succeed: a canonically written lock is never unopenable.
    try fixture.write(
        "project/ecl.lock",
        "{'format 2 'root \"root\" 'packages " ++
            "{\"dep\" {'version \"1.0.0\" 'source {'kind 'archive 'url \"https://example.invalid/dep.tgz\"} " ++
            "'hash \"" ++ hash_a ++ "\"}} " ++
            "'requires {\"root\" {\"dep\" {'package \"dep\" 'version \"1.0.0\"}}}}\n",
    );
    try fixture.writeStoreModule("dep", "1.0.0", hash_a, "dep", 5);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(&runtime, "dep.answer");
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[0].int);
}

test "loader: embedded modules precede lock and a manifested project is hermetic" {
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        // Make the project-start directory an explicit path candidate too:
        // the lock must still own foo.bar while an unmatched local name loads.
        .ecl_path = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[1] result.ok foo.bar");
    try std.testing.expect(runtime.stackItems()[0] == .dict);
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try expectErrorContains(
        &runtime,
        "site-local.answer",
        &.{ "'kind 'undefined-word", "not exported by the active project" },
    );
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .ecl_path = fixture.search,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "legacy.answer");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
}

test "loader: direct requires mask both cold and already-loaded transitive modules" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeTransitiveLock();
    try fixture.writeStoreArtifact(
        "alpha",
        "1.0.0",
        hash_a,
        "implementation.ecl",
        "\"alpha\"",
        "[] ((beta.answer) 'through def) 'alpha @defm\n",
        .{},
    );
    try fixture.writeStoreModule("beta", "1.0.0", hash_b, "beta", 22);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(&runtime, "alpha.through");
    try std.testing.expectEqual(@as(i64, 22), runtime.stackItems()[0].int);
    try expectErrorContains(
        &runtime,
        "beta.answer",
        &.{ "'kind 'undefined-word", "root", "does not require it" },
    );
}

test "loader: one quotation rechecks authorization in each package context" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeAuthorizationLock();
    try fixture.writeStoreArtifact(
        "alpha",
        "1.0.0",
        hash_a,
        "alpha.ecl",
        "\"alpha\"",
        "secret.answer pop [] ((2 swap times pop pop) 'run def) 'alpha @defm\n",
        .{},
    );
    try fixture.writeStoreArtifact(
        "beta",
        "1.0.0",
        hash_b,
        "beta.ecl",
        "\"beta\"",
        "[] ((2 swap times pop pop) 'run def) 'beta @defm\n",
        .{},
    );
    try fixture.writeStoreModule("secret", "1.0.0", hash_c, "secret", 42);

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "(secret.answer) dup alpha.run wrap (beta.run) @attempt " ++
            "'err at 'kind at",
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqualStrings(
        "undefined-word",
        intern.get(runtime.stackItems()[0].symbol),
    );
}

test "loader: a failing multi-module artifact publishes no usable module" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("broken", "1.0.0", hash_a);
    try fixture.writeStoreArtifact(
        "broken",
        "1.0.0",
        hash_a,
        "many.ecl",
        "\"broken.first\" \"broken.second\"",
        "[] ((1) 'answer def) 'broken.first @defm\n" ++
            "missing-during-artifact-load\n" ++
            "[] ((2) 'answer def) 'broken.second @defm\n",
        .{},
    );

    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
    defer runtime.deinit();

    try expectErrorContains(&runtime, "broken.first.answer", &.{"missing-during-artifact-load"});
    // The first @defm ran before the failure, but the artifact commit did not.
    // A second request must retry and fail at the artifact; the partial
    // registry generation never becomes a usable module.
    try expectErrorContains(&runtime, "broken.first.answer", &.{"missing-during-artifact-load"});
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .environ = &environ,
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .ecl_path = fixture.search,
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .ecl_path = fixture.search,
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .ecl_path = fixture.search,
        .environ = &.{},
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .ecl_path = fixture.search,
        .environ = &environ,
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .initial_cwd = fixture.nested,
        .ecl_path = fixture.search,
        .environ = &environ,
    }), .default, .evaluate);
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
const hash_c = "sha256-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

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
            .data = "{'format 2 'name \"root\" 'version \"0.1.0\" 'sources [] 'exports [] 'requires {}}\n",
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
            "{{'format 2\n 'root \"root\"\n 'packages\n {{\"{s}\" {{'version \"{s}\" 'source {{'kind 'archive 'url \"https://example.invalid/{s}.tgz\"}} 'hash \"{s}\"}}}}\n 'requires\n {{\"{s}\" {{}} \"root\" {{\"{s}\" {{'package \"{s}\" 'version \"{s}\"}}}}}}}}\n",
            .{ package, version, package, hash, package, package, package, version },
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
            "{{'format 2\n 'root \"root\"\n 'packages\n {{\"{s}\" {{'version \"{s}\" 'source {{'kind 'archive 'url \"https://example.invalid/{s}.tgz\"}} 'hash \"{s}\"}} \"{s}\" {{'version \"{s}\" 'source {{'kind 'archive 'url \"https://example.invalid/{s}.tgz\"}} 'hash \"{s}\"}}}}\n 'requires\n {{\"{s}\" {{}} \"{s}\" {{}} \"root\" {{\"{s}\" {{'package \"{s}\" 'version \"{s}\"}} \"{s}\" {{'package \"{s}\" 'version \"{s}\"}}}}}}}}\n",
            .{ first, first_version, first, first_hash, second, second_version, second, second_hash, first, second, first, first, first_version, second, second, second_version },
        );
        defer std.testing.allocator.free(text);
        try self.write("project/ecl.lock", text);
    }

    fn writeTransitiveLock(self: *LockFixture) !void {
        const text = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 2\n 'root \"root\"\n 'packages\n " ++
                "{{\"alpha\" {{'version \"1.0.0\" 'source {{'kind 'archive 'url \"https://example.invalid/alpha.tgz\"}} 'hash \"{s}\"}} " ++
                "\"beta\" {{'version \"1.0.0\" 'source {{'kind 'archive 'url \"https://example.invalid/beta.tgz\"}} 'hash \"{s}\"}}}}\n " ++
                "'requires\n {{\"alpha\" {{\"beta\" {{'package \"beta\" 'version \"1.0.0\"}}}} " ++
                "\"beta\" {{}} \"root\" {{\"alpha\" {{'package \"alpha\" 'version \"1.0.0\"}}}}}}}}\n",
            .{ hash_a, hash_b },
        );
        defer std.testing.allocator.free(text);
        try self.write("project/ecl.lock", text);
    }

    fn writeAuthorizationLock(self: *LockFixture) !void {
        const text = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 2\n 'root \"root\"\n 'packages\n " ++
                "{{\"alpha\" {{'version \"1.0.0\" 'source {{'kind 'archive 'url \"https://example.invalid/alpha.tgz\"}} 'hash \"{s}\"}} " ++
                "\"beta\" {{'version \"1.0.0\" 'source {{'kind 'archive 'url \"https://example.invalid/beta.tgz\"}} 'hash \"{s}\"}} " ++
                "\"secret\" {{'version \"1.0.0\" 'source {{'kind 'archive 'url \"https://example.invalid/secret.tgz\"}} 'hash \"{s}\"}}}}\n " ++
                "'requires\n {{\"alpha\" {{\"secret\" {{'package \"secret\" 'version \"1.0.0\"}}}} " ++
                "\"beta\" {{}} \"secret\" {{}} \"root\" " ++
                "{{\"alpha\" {{'package \"alpha\" 'version \"1.0.0\"}} " ++
                "\"beta\" {{'package \"beta\" 'version \"1.0.0\"}}}}}}}}\n",
            .{ hash_a, hash_b, hash_c },
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
        const manifest_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}/ecl.pkg",
            .{path},
        );
        defer std.testing.allocator.free(manifest_path);
        const manifest = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 2 'name \"{s}\" 'version \"{s}\" 'sources [] 'exports [] 'requires {{}}}}\n",
            .{ package, version },
        );
        defer std.testing.allocator.free(manifest);
        try self.write(manifest_path, manifest);
        try self.writeCatalog(package, version, hash, "");
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

    fn writeStoreArtifact(
        self: *LockFixture,
        package: []const u8,
        version: []const u8,
        hash: []const u8,
        relative_path: []const u8,
        exports: []const u8,
        comptime source_format: []const u8,
        args: anytype,
    ) !void {
        try self.createStore(package, version, hash);
        const path = try std.fmt.allocPrint(
            std.testing.allocator,
            "cache/{s}-{s}-{s}/{s}",
            .{ package, version, hash[7..], relative_path },
        );
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(std.testing.allocator, source_format, args);
        defer std.testing.allocator.free(source);
        try self.write(path, source);
        const manifest_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "cache/{s}-{s}-{s}/ecl.pkg",
            .{ package, version, hash[7..] },
        );
        defer std.testing.allocator.free(manifest_path);
        const manifest = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 2 'name \"{s}\" 'version \"{s}\" 'sources [\"**/*\"] 'exports [{s}] 'requires {{}}}}\n",
            .{ package, version, exports },
        );
        defer std.testing.allocator.free(manifest);
        try self.write(manifest_path, manifest);
        const records = try std.fmt.allocPrint(std.testing.allocator, "{{'path \"{s}\" 'exports [{s}]}}", .{ relative_path, exports });
        defer std.testing.allocator.free(records);
        try self.writeCatalog(package, version, hash, records);
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
            "[] (({d}) '{s} def) '{s} @defm\n",
            .{ answer, word_name, module_name },
        );
        defer std.testing.allocator.free(source);
        try self.write(path, source);
        const manifest_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "cache/{s}-{s}-{s}/ecl.pkg",
            .{ package, version, hash[7..] },
        );
        defer std.testing.allocator.free(manifest_path);
        const manifest = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{'format 2 'name \"{s}\" 'version \"{s}\" 'sources [\"**/*\"] 'exports [\"{s}\"] 'requires {{}}}}\n",
            .{ package, version, module_name },
        );
        defer std.testing.allocator.free(manifest);
        try self.write(manifest_path, manifest);
        const records = try std.fmt.allocPrint(std.testing.allocator, "{{'path \"{s}.ecl\" 'exports [\"{s}\"]}}", .{ module_name, module_name });
        defer std.testing.allocator.free(records);
        try self.writeCatalog(package, version, hash, records);
    }

    fn writeCatalog(self: *LockFixture, package: []const u8, version: []const u8, hash: []const u8, records: []const u8) !void {
        const path = try std.fmt.allocPrint(std.testing.allocator, "cache/{s}-{s}-{s}/.ecl-package.catalog", .{ package, version, hash[7..] });
        defer std.testing.allocator.free(path);
        const text = try std.fmt.allocPrint(std.testing.allocator, "{{'format 1 'name \"{s}\" 'version \"{s}\" 'hash \"{s}\" 'sources [{s}]}}\n", .{ package, version, hash, records });
        defer std.testing.allocator.free(text);
        try self.write(path, text);
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
            "[] (({d}) '{s} def) '{s} @defm\n",
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
            "[] (({d}) '{s} def) '{s} @defm\n",
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectErrorContains(&runtime, "[] (1 'k set) @attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "[] ([] (1 'k set missing) @attempt pop) @attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectOk(&runtime, "[] (7 'x set) 'm @defm");
    try expectErrorContains(&runtime, "[] ('m ('x) import x) @attempt pop x", &.{ "'kind 'undefined-word", "'word 'x" });
}

test "module: privacy module-body contract top-level private and qualified trace" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (40 's setp ( -- n ) (s 2 +) 'f def) 'm @defm m.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "[] (( -- n ) (41) 'g defp ( -- n ) (g 1 +) 'f def) 'private-word @defm private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "private-word.g", &.{ "'kind 'undefined-word", "'word 'private-word.g" });
    try expectErrorContains(&runtime, "1 'x setp", &.{ "'kind 'domain", "defp/setp" });
    // A body that leaves values behind registers: they become the slot's
    // durable stack. They create no bindings, so no name appears for them.
    try expectOk(&runtime, "[] (1) 'bad @defm");
    try expectErrorContains(&runtime, "bad.x", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "[] ([] (1 'hidden set) @attempt pop) 'temporary @defm");
    try expectErrorContains(&runtime, "temporary.hidden", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "[] (( -- n ) (missing) 'boom def) 'trace-module @defm");
    try expectErrorContains(&runtime, "trace-module.boom", &.{ "'word 'missing", "'trace ['missing 'trace-module.boom]" });
    try expectOk(&runtime, "[] (( n -- n ) (dup 0 > (1 - f 1 +) (pop missing) if) 'f def) 'recursive @defm");
    try expectErrorContains(&runtime, "2 recursive.f", &.{"'trace ['missing 'recursive.f 'recursive.f 'recursive.f]"});
}

test "modules: removal strips aliases and leaves no half-removed entry" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] ((1) 'x def) 'a @defm [] ((2) 'x def) 'b @defm " ++
        "'short 'a alias 'a ('x) import short.x a.x x");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try expectOk(&runtime, "'a unmodule");
    // The canonical name and every alias targeting it go in one publish.
    try expectErrorContains(&runtime, "a.x", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "short.x", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "'short ('x) import", &.{"'kind 'undefined-word"});
    // Enumeration never shows a half-removed entry, and unrelated modules
    // and their aliases are untouched.
    try expectOk(&runtime, "'other 'b alias other.x b.x");
    // Re-aliasing a removed name is a missing-module error as before.
    try expectErrorContains(&runtime, "'again 'a alias", &.{"'kind 'undefined-word"});
}

test "module: qualified import replacement and alias collisions" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (1 'x set) 'a @defm [] (2 'x set) 'b @defm " ++
        "'a ('x) import 'b ('x) import x 'a ('x) import x 'short 'a alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "'a 'b alias", &.{"'kind 'domain"});
    try expectOk(&runtime, "'short 'b alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[3].int);
    try expectErrorContains(&runtime, "'future 'a alias [] (3 'x set) 'future @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'dotted.name 'a alias", &.{"'kind 'domain"});
}

test "module: qualified call sites heal generations and bypass aliases" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "[] ((1) 'v def) 'cache-heal @defm (cache-heal.v) 'probe def probe " ++
            "[] ((2) 'v def) 'cache-heal @defm probe " ++
            "[] ((10) 'v def) 'alias-a @defm [] ((20) 'v def) 'alias-b @defm " ++
            "'short 'alias-a alias (short.v) 'alias-probe def alias-probe " ++
            "'short 'alias-b alias alias-probe " ++
            "[] ((3) 'v def) 'removed-cache @defm (removed-cache.v) 'removed-probe def " ++
            "removed-probe 'removed-cache unmodule [] (removed-probe) @attempt 'err at 'kind at",
    );
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("1 2 10 20 3 'undefined-word", display.bytes());
}

test "module: provisional tasks keep rollback generations alive until quiescence" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 1 }, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] ([] ([] ((1) () while) @spawn pop missing) 'bad @defm) @attempt pop");
}

test "module: hot reload commit failure and whole-body pinning" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (1 'x setp " ++
        "( -- n ) ([] (2 'x setp ( -- n ) (x) 'get def) 'm @defm x) 'probe def " ++
        "( -- n ) (x) 'get def) 'm @defm m.probe m.get");
    // `probe` reloads its own module and then reads `x`. A module-written word
    // anchors to the generation its activation entered, so the read lands in
    // the image `probe` itself was written in; code on the stack is never
    // re-pointed under itself. The fresh `m.get` afterwards follows the name to
    // the generation that replaced it.
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "[] (3 'x setp missing) 'm @defm", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "m.get");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "[] (( -- n ) (9) 'get def) 'kept @defm missing", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "kept.get");
    try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[3].int);
}

test "module: effect shape cross-home contract and same-home TCO" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // A module word may omit its annotation entirely; only a malformed
    // recognized annotation is 'domain.
    try expectOk(&runtime, "[] ((dup) 'f def) 'fine @defm");
    try expectErrorContains(&runtime, "[] ((a -- b -- c) (dup) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "[] ((a 1 -- b) (dup) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectOk(&runtime, "[] (( n -- ) (dup 0 > (1 - countdown) (pop) if) 'countdown def) 'm @defm");
    try expectOk(&runtime, "20 m.countdown");
    const shallow_frames = runtime.lastMaxFrames();
    try expectOk(&runtime, "20000 m.countdown");
    try std.testing.expectEqual(shallow_frames, runtime.lastMaxFrames());
    try expectErrorContains(&runtime, "[] (( a -- b c ) (dup +) 'f def) 'lies @defm 1 lies.f", &.{ "'kind 'contract", "'word 'lies.f" });
    try expectErrorContains(&runtime, "[] (( a -- a a ) (dup) 'f def) 'needs @defm needs.f", &.{ "'kind 'contract", "seeded 0" });
    try expectErrorContains(&runtime, "[] (( -- n ) (missing) 'f def) 'throws @defm throws.f", &.{ "'kind 'undefined-word", "'word 'missing" });
    try expectOk(&runtime, "(dup +) 'session-double def 4 session-double");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[runtime.stackItems().len - 1].int);
}

test "module: import explicitly replaces requested bindings and preserves metadata" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = null,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (3 'mean set ( -- n : \"Count.\") (4) 'count def 5 'other set) 'stats @defm " ++
        "1 'mean set 'stats ('mean 'count) import mean count " ++
        "'count doc \"Count.\" match? 'count see");
    try std.testing.expectEqualStrings("", diagnostics.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(stats.count)\n") != null);
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 4), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "'stats ('stats.count) import", &.{
        "'kind 'domain",
        "import attributes must be unqualified",
    });
    try expectErrorContains(&runtime, "'result use", &.{
        "'kind 'undefined-word",
        "'word 'use",
    });
}

test "module: import validates requested public attributes before publishing" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(&runtime, "[] (1 'one set 2 'two set 3 'hidden setp 4 'fresh set) 'batch @defm " ++
        "'batch ('one 'two) import one two");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);

    try expectErrorContains(&runtime, "'batch ('fresh 'missing) import", &.{
        "'kind 'undefined-word",
        "'name 'batch.missing",
    });
    try expectErrorContains(&runtime, "fresh", &.{ "'kind 'undefined-word", "'word 'fresh" });
    try expectErrorContains(&runtime, "'batch ('hidden) import", &.{
        "'kind 'undefined-word",
        "'name 'batch.hidden",
    });
    try expectErrorContains(&runtime, "'batch (one) import", &.{"'kind 'type"});
}

test "module: import inside a module body binds module-locally" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // `import` used to reach for top-level publication unconditionally, so a
    // module root aborted the process on an `unreachable` inside the scope's
    // publication method. It now takes the same module sink `def` takes there.
    try expectOk(&runtime, "[] ((1) 'x def) 'src @defm [] ('src ('x) import) 'holder @defm holder.x");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    // The binding landed exclusively in the image built by `@defm`.
    try expectErrorContains(&runtime, "x", &.{ "'kind 'undefined-word", "'word 'x" });
}

test "scope: a binding resolves in the scope it was defined in, child scopes included" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // Both definitions land in the `@attempt` child, so the second resolves
    // the first. Reading the unit root instead left siblings invisible to each
    // other, which was the last exception to "resolves where it was defined".
    try expectOk(&runtime, "[] ((1) 'helper def (helper) 'caller def caller) @attempt 'ok at first");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    // A child definition is still dynamic: it does not outlive its boundary.
    try expectErrorContains(&runtime, "helper", &.{ "'kind 'undefined-word", "'word 'helper" });
}

test "scope: an undefined word names the chain it searched" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectErrorContains(&runtime, "nope", &.{"'scope 'session"});
    // A module cannot see the session, and says so rather than leaving the
    // reader to work out why a name they just defined is missing.
    try expectErrorContains(&runtime, "(1) 'base def [] ((base) 'r def) 'm @defm m.r", &.{
        "'scope 'module",
        "'word 'base",
    });
    // A dotted reference searched only the registry.
    try expectErrorContains(&runtime, "[] ((7) 'answer def) 'named @defm named.nope", &.{"'scope 'qualified"});
    try expectErrorContains(&runtime, "no.such.word", &.{"'scope 'qualified"});
    // A missing export of a module *value* is not a scope miss at all.
    try expectErrorContains(&runtime, "[] ((7) 'answer def) @module 'nope invoke", &.{"'scope 'module-value"});
}

test "module: a construction sees only its parameters its own definitions and core" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // A module body's chain is its own definitions then core. A session name
    // is not in it, however recently it was defined.
    try expectOk(&runtime, "(1) 'base def");
    try expectErrorContains(&runtime, "[] ((base) 'read def) 'unparameterized @defm unparameterized.read", &.{
        "'kind 'undefined-word",
        "'word 'base",
    });
    // Parameterization is the way in, and it is the ordinary seeding
    // composition rather than a construction-specific mechanism.
    try expectOk(&runtime, "[41] ('base set ( -- n ) (base 1 +) 'go def) 'seeded @defm seeded.go");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    // Core stays reachable, so a module needs no parameter for `+`.
    try expectOk(&runtime, "[] ((2 3 +) 'go def) 'core-only @defm core-only.go");
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[1].int);
    // This is about the module's own chain only. A homeless word the module
    // calls — a primitive or an embedded prelude definition — still resolves
    // against the lexical chain it was defined in.
}

test "module: a parameterized behavior dependency is a quotation the caller wrote" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // Behavior arrives as a quotation the caller writes, which is the functor
    // discipline: the caller writes the structure it hands in. There is no way
    // to hand over an existing word, because nothing extracts a published
    // body — to share a word, both parties call a module.
    try expectOk(&runtime, "[(dup +)] ('double def ( -- n ) (4 double) 'go def) 'w @defm w.go");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[0].int);
    // Nothing later can reach it: the image holds the quotation it was handed,
    // and a session name of the same spelling is not in its chain.
    try expectOk(&runtime, "(99) 'double def w.go");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[1].int);
    // Purity comes from the unit-constructor boundary itself: `@defm` runs
    // the construction body in the image's chain whatever scope its text was
    // written in, so a bare `k` inside the body is undefined however recently
    // the session defined one.
    try expectOk(&runtime, "[] ((k *) 'scale def) 'body-dep @defm");
    try expectErrorContains(&runtime, "body-dep.scale", &.{
        "'kind 'undefined-word",
        "'word 'k",
    });
}

test "reflection: which and see expose metadata while see omits the definition wrapper" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = null,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] (40 's setp ( -- n ) (s 2 +) 'f def) 'm @defm 'm ('f) import " ++
        "'m.f see 9 'f set 'f which 'f see words");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(s 2 +)\n") != null);
    // One binding kind: a session constant reports as a public def with no
    // metadata, because the sugar supplies none, and `see` prints the stored
    // literal capture rather than reconstructing the `set` spelling.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "f -> f def public") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "shadows m.f") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([9] first)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " s ") == null);
}

test "session completion: core names are available before the first unit" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    try expectOk(
        &runtime,
        "[] (1 'hidden setp 2 'public set) 'completion-module @defm " ++
            "'completion-module ('public) import 'cm 'completion-module alias " ++
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(
        &runtime,
        "[] (1 'old-public set 2 'private-name setp) 'completion-module @defm " ++
            "'cm 'completion-module alias " ++
            "[] (3 'new-public set 4 'new-private setp) 'completion-module @defm",
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = null,
    }), .default, .evaluate);
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
    try expectOk(&runtime, "[] (\"test/acceptance/load-stack.ecl\" load) @attempt pop");
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
    var runtime_inputs37 = try runtime_fixture.Fixture.init();
    defer runtime_inputs37.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs37.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = search,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] ('attempted ('answer) import answer) @attempt pop attempted.answer");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "answer", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'stats ('answer) import answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);

    var runtime_inputs38 = try runtime_fixture.Fixture.init();
    defer runtime_inputs38.deinit();
    var no_path = try session.Session.init(backing.allocator(), &.{}, runtime_inputs38.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = "",
    }), .default, .evaluate);
    defer no_path.deinit();
    try expectErrorContains(&no_path, "'stats ('answer) import", &.{ "'kind 'undefined-word", "'name 'stats.answer" });
}

test "modules: module set and setp publish unannotated constants" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // Registration succeeding is itself the proof that a module definition
    // may carry no effect at all: `set` publishes the bare literal capture,
    // so constants need no value exception and no synthesized metadata.
    try expectOk(&runtime, "[] (7 'x set 8 'h setp (-- n) (h) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x m.peek");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[1].int);
    // Privacy is unchanged; `which` owns metadata reflection and `see` owns
    // body reflection.
    try expectErrorContains(&runtime, "m.h", &.{ "'kind 'undefined-word", "'word 'm.h" });
    try expectOk(&runtime, "'m.x which 'm.x see");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "m.x -> m.x def public") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- value)") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([7] first)\n") != null);
}

test "modules: cross-home constant references cross unchecked while declared effects still bind" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // A constant reached across a home boundary declares no effect, so no
    // check frame is installed at all: qualified access, imported access, and
    // module-internal access agree without one.
    try expectOk(&runtime, "[] (7 'x set 8 'h setp (-- n) (h) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x 'm ('x) import x m.peek");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[2].int);
    // The frame is a real contract for `(-- value)` declarations: a module
    // word declaring it and leaving two values is a contract violation.
    try expectErrorContains(
        &runtime,
        "[] ((-- value) (1 2) 'two def) 'liar @defm liar.two",
        // Seeded/observed are absolute stack depths, so assert the parts that
        // do not depend on what this session left on the stack.
        &.{ "'kind 'contract", "'word 'liar.two", "declared (0 -- 1)" },
    );
}

test "module: a module literal reaches its own private through a combinator" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // `(pop secret)` is written inside the module body, so it resolves in the
    // image whichever activation hands it to `each`.
    try expectOk(&runtime, "[] ((41) 'secret defp ([1] (pop secret) each first) 'go def) 'm @defm m.go");
    try std.testing.expectEqual(@as(i64, 41), runtime.stackItems()[0].int);
    // A session name of the same spelling does not perturb it.
    try expectOk(&runtime, "(99) 'secret def m.go");
    try std.testing.expectEqual(@as(i64, 41), runtime.stackItems()[1].int);
}

test "module: a module word runs a caller's quotation in the caller's chain" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // The caller wrote `(bump)`, so `bump` resolves in the caller even though
    // the activation applying it belongs to the module.
    try expectOk(&runtime, "[] ((|q| 2 q call) 'apply def) 'm @defm (1 +) 'bump def (bump) m.apply");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    // The stdlib higher-order words are the same case, and the second of
    // ticket ecl#4's two reproductions.
    try expectOk(&runtime, "[1] result.ok (bump) result.and-then pop");
}

test "module: a quotation parameter carries the caller's scope" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // The caller wrote `(k *)`, so its own references are the caller's and the
    // module needs no parameter for them. `def`-ing it makes the binding
    // module-local without re-siting what it refers to.
    try expectOk(&runtime, "(10) 'k def " ++
        "[(k *)] ('scale def ( -- n ) (4 scale) 'go def) 'caller-dep @defm caller-dep.go");
    try std.testing.expectEqual(@as(i64, 40), runtime.stackItems()[0].int);
}

test "module: every container the reader built inside a body is the module's text" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // Three spellings of one thing. A quotation the reader built inside the
    // body names the image whatever container holds it, so all three reach the
    // module's own private rather than the session's binding. The dict literal
    // is the one that used to disagree, because the restamp stopped at dicts.
    try expectOk(&runtime, "(10) 'k def");
    try expectOk(&runtime, "[] ((99) 'k defp [(k)] 'd setp ( -- n ) (d first call) 'go def) 'l @defm l.go");
    try std.testing.expectEqual(@as(i64, 99), runtime.stackItems()[0].int);
    try expectOk(&runtime, "[] ((99) 'k defp {'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'dl @defm dl.go");
    try std.testing.expectEqual(@as(i64, 99), runtime.stackItems()[1].int);
    try expectOk(&runtime, "[] ((99) 'k defp ('a) ((k)) dict.from-lists 'd setp ( -- n ) (d 'a at call) 'go def) 'td @defm td.go");
    try std.testing.expectEqual(@as(i64, 99), runtime.stackItems()[2].int);
    // And with no private to find, the session binding is still not reachable.
    try expectErrorContains(
        &runtime,
        "[] ({'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'leak @defm leak.go",
        &.{ "'kind 'undefined-word", "'word 'k" },
    );
}

test "module: an undefined word names the chain its own scope searched" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // The reported chain comes from the word's own scope independently of the
    // running activation. A caller's quotation applied by a module word searched the
    // caller, and saying `'module` there would name the one place it did not
    // look.
    try expectOk(&runtime, "[] ((|q| q call) 'apply def) 'm @defm");
    try expectErrorContains(&runtime, "(nope) m.apply", &.{ "'word 'nope", "'scope 'session" });
    try expectOk(&runtime, "[] ((missing) 'f def) 'own @defm");
    try expectErrorContains(&runtime, "own.f", &.{ "'word 'missing", "'scope 'module" });
    try expectErrorContains(&runtime, "nope", &.{ "'word 'nope", "'scope 'session" });
}

test "module: a session quotation still resolves in the session" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // `probe` re-registers its own name and then reads its private `x`. Code on
    // the activation stack is never re-pointed under itself, so the read lands
    // in the generation `probe` was entered with; a fresh entry afterwards
    // follows the name to the generation that replaced it.
    try expectOk(&runtime, "[] (1 'x setp " ++
        "( -- n ) ([] (2 'x setp ( -- n ) (x) 'get def) 'm @defm x) 'probe def " ++
        "( -- n ) (x) 'get def) 'm @defm m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
}

test "loader: catalog export verification resumes within its membership budget" {
    const pkg_catalog = @import("../pkg_catalog.zig");
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "modules.ecl",
        // Discovery must ignore private declarations, even when their literal
        // names would be invalid if evaluated as module registrations.
        .data = "[] () '-- @defm " ++
            "[] () 'dep.a @defm [] () 'dep.b @defm [] () 'dep.c @defm",
    });
    inline for ([_]bool{ false, true }) |missing| {
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "ecl.pkg",
            .data = "{'format 2 'name \"dep\" 'version \"1.0.0\" 'sources [\"*.ecl\"] " ++
                "'requires {} 'exports [\"dep.c\" \"dep.b\" \"dep.a\"" ++
                (if (missing) " \"dep.missing\"]}" else "]}"),
        });
        var owner = @import("../heap.zig").HostOwner.init(allocator);
        defer owner.cleanup().drain();
        var diagnostic: ?[]u8 = null;
        defer if (diagnostic) |message| allocator.free(message);
        const packages = [_]pkg_catalog.PackageInput{.{
            .id = @enumFromInt(0),
            .name = "dep",
            .version = "1.0.0",
            .root_dir = ".",
            .base_dir = directory.dir,
        }};
        // Abandon a partially indexed manifest to exercise its owned cleanup.
        {
            var abandoned = pkg_catalog.Build.init(owner.cleanup(), std.testing.io, &packages, &diagnostic);
            defer abandoned.deinit();
            try std.testing.expectEqual(.pending, try abandoned.advance(100));
            try std.testing.expectEqual(.pending, try abandoned.advance(1));
        }
        var cursor = pkg_catalog.Build.init(owner.cleanup(), std.testing.io, &packages, &diagnostic);
        defer cursor.deinit();
        // Read the manifest, then index its exports one entry at a time.
        try std.testing.expectEqual(.pending, try cursor.advance(100));
        for (0..@as(usize, if (missing) 4 else 3)) |_| {
            try std.testing.expectEqual(.pending, try cursor.advance(0));
            try std.testing.expectEqual(.pending, try cursor.advance(1));
        }
        // Finish the small directory walk and parse its artifact.
        for (0..2) |_| try std.testing.expectEqual(.pending, try cursor.advance(100));
        // Each export needs one membership check regardless of declaration
        // order. Zero budget preserves progress before and during verification.
        for (0..2) |_| {
            try std.testing.expectEqual(.pending, try cursor.advance(0));
            try std.testing.expectEqual(.pending, try cursor.advance(1));
            try std.testing.expect(diagnostic == null);
        }
        if (missing) {
            try std.testing.expectEqual(.pending, try cursor.advance(1));
            try std.testing.expectEqual(.pending, try cursor.advance(0));
            try std.testing.expect(diagnostic == null);
            try std.testing.expectError(error.Invalid, cursor.advance(1));
            try std.testing.expectEqualStrings("package dep exports undeclared module dep.missing", diagnostic.?);
        } else {
            try std.testing.expectEqual(.done, try cursor.advance(1));
            var catalog = try cursor.take();
            defer catalog.deinit();
            for ([_][]const u8{ "dep.a", "dep.b", "dep.c" }) |name|
                try std.testing.expect(catalog.find(name) != null);
        }
    }
}

test "loader: catalog membership is package-local and survives allocation failures" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    const manifest = "{'format 2 'name \"dep\" 'version \"1.0.0\" 'sources [\"*.ecl\"] " ++
        "'exports [\"dep.only\"] 'requires {}}";
    try fixture.write("project/ecl.pkg", manifest);
    try fixture.write("project/module.ecl", "[] () 'dep.only @defm");
    try fixture.write("path/ecl.pkg", manifest);
    try fixture.write("path/module.ecl", "[]");
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, directory: std.Io.Dir) !void {
            const pkg_catalog = @import("../pkg_catalog.zig");
            var owner = @import("../heap.zig").HostOwner.init(allocator);
            defer owner.cleanup().drain();
            const packages = [_]pkg_catalog.PackageInput{
                .{ .id = @enumFromInt(0), .name = "dep", .version = "1.0.0", .root_dir = "project", .base_dir = directory },
                .{ .id = @enumFromInt(1), .name = "dep", .version = "1.0.0", .root_dir = "path", .base_dir = directory },
            };
            for ([_]usize{ 1, 2 }) |count| {
                var diagnostic: ?[]u8 = null;
                defer if (diagnostic) |message| allocator.free(message);
                var catalog = pkg_catalog.build(owner.cleanup(), std.testing.io, packages[0..count], &diagnostic) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.Invalid => {
                        try std.testing.expectEqual(@as(usize, 2), count);
                        try std.testing.expectEqualStrings("package dep exports undeclared module dep.only", diagnostic.?);
                        continue;
                    },
                };
                defer catalog.deinit();
                try std.testing.expectEqual(@as(usize, 1), count);
                try std.testing.expect(catalog.find("dep.only") != null);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{fixture.directory.dir});
}

test "loader: persisted catalog assembly propagates every allocation failure" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeStoreModule("dep", "1.0.0", hash_a, "dep", 42);
    const root = try std.fs.path.join(std.testing.allocator, &.{ fixture.cache, "dep-1.0.0-" ++ hash_a[7..] });
    defer std.testing.allocator.free(root);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, path: []const u8) !void {
            var owner = @import("../heap.zig").HostOwner.init(allocator);
            defer owner.cleanup().drain();
            var diagnostic: ?[]u8 = null;
            defer if (diagnostic) |message| allocator.free(message);
            var catalog = try @import("../pkg_catalog.zig").build(owner.cleanup(), std.testing.io, &.{.{
                .id = @enumFromInt(0),
                .name = "dep",
                .version = "1.0.0",
                .root_dir = path,
                .archive_hash = hash_a,
            }}, &diagnostic);
            defer catalog.deinit();
            const module = catalog.find("dep") orelse return error.MissingExport;
            try std.testing.expectEqualStrings("dep.ecl", catalog.artifact(module.artifact).relative_path);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{root});
}

test "loader: persisted private-only sources retain file identity" {
    var fixture = try LockFixture.init();
    defer fixture.deinit();
    try fixture.writeOnePackageLock("dep", "1.0.0", hash_a);
    try fixture.writeStoreArtifact("dep", "1.0.0", hash_a, "private.ecl", "", "[] ((42) 'answer def) 'hidden @defm hidden.answer\n", .{});
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    const environ = [_]sessionHostEntry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.init(backing.allocator(), &.{}, inputs.inputs(.{ .initial_cwd = fixture.nested, .environ = &environ }), .cooperative, .evaluate);
    defer runtime.deinit();
    const source = try std.fmt.allocPrint(std.testing.allocator, "\"{s}/dep-1.0.0-{s}/private.ecl\" load", .{ fixture.cache, hash_a[7..] });
    defer std.testing.allocator.free(source);
    try expectOk(&runtime, source);
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "hidden.answer", &.{"not exported by the active project"});
}
