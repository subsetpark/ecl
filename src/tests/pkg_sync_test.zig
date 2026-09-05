//! Public package-store and synchronization behavior over the hermetic HTTPS fixture.
//!
//! Package words act through the Session's package authority: a
//! package-command Session names the shared `'cache` and project `'vendor`
//! stores as host directories and the `'project` filesystem root, so no test
//! source contains an absolute path. Ordinary Sessions receive no package
//! authority and are proven to fail closed.
const std = @import("std");
const pkg_fixture = @import("pkg_fixture_options");
const archive_fixtures = @import("archive_fixture_options");
const package_authority = @import("../package_authority.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;
const valid_cert_time = std.Io.Timestamp.fromNanoseconds(
    @as(i96, 1_788_220_800) * std.time.ns_per_s,
);
const fixture_a_key = "a-1.0.0-1f9aefdfdd91996e4f2f80b7f89f1ac3d8907616b74f1cf55a1a48042556738a";
const fixture_a_hash = "sha256-1f9aefdfdd91996e4f2f80b7f89f1ac3d8907616b74f1cf55a1a48042556738a";
const placeholder_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "pkg store: inspect returns exact root manifest" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    const source = try packageSource(fixture.port, "/pkg/bad-1.0.0.tgz", "bad", .inspect, null);
    defer allocator.free(source);
    var host = try PackageHost.init(.{ .tls = true });
    defer host.deinit();
    try host.expectStack(
        source,
        "\"{'format 1 'name \\\"bad\\\" 'version \\\"1.0.0\\\" 'exports " ++
            "{\\\"bad\\\" [\\\"**/*\\\"]} 'requires {}}\\n\"",
    );
}

test "pkg store: rejects invalid source package layouts before publication" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    const cases = [_]struct { endpoint: []const u8, message: []const u8 }{
        .{ .endpoint = "/pkg/foo-1.0.0-native.tgz", .message = "foo.eclmod" },
        .{ .endpoint = "/pkg/foo-1.0.0-missing-manifest.tgz", .message = "no root ecl.pkg" },
        .{ .endpoint = "/pkg/foo-1.0.0-invalid-manifest.tgz", .message = "not valid UTF-8" },
        .{ .endpoint = "/pkg/foo-1.0.0-reserved-seal.tgz", .message = ".ecl-package.tgz" },
    };
    var host = try PackageHost.init(.{ .tls = true });
    defer host.deinit();
    for (cases) |case| {
        const source = try packageSource(fixture.port, case.endpoint, "foo", .inspect, null);
        defer allocator.free(source);
        try host.expectError(source, .{
            .name = case.endpoint,
            .source = source,
            .kind = "domain",
            .word = "pkg.store.inspect",
            .message_contains = case.message,
        });
    }
}

test "pkg store: package export globs admit nested source artifacts" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const key = "foo-1.0.0-" ++ placeholder_hex;
    const source = try packageSource(fixture.port, "/pkg/foo-1.0.0-nested.tgz", "foo", .install, key);
    defer allocator.free(source);
    try host.expectStack(source, "(\"ecl.pkg\" \"nested/foo.ecl\")");
}

test "pkg store: atomically installs one valid source package" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const key = "bad-1.0.0-" ++ placeholder_hex;
    const source = try packageSource(fixture.port, "/pkg/bad-1.0.0.tgz", "bad", .install, key);
    defer allocator.free(source);
    try host.expectStack(source, "(\"bad.ecl\" \"ecl.pkg\")");
    const manifest = try host.scratch.directory.dir.readFileAlloc(
        std.testing.io,
        "cache/" ++ key ++ "/ecl.pkg",
        allocator,
        .unlimited,
    );
    defer allocator.free(manifest);
    try std.testing.expectEqualStrings(
        "{'format 1 'name \"bad\" 'version \"1.0.0\" 'exports {\"bad\" [\"**/*\"]} 'requires {}}\n",
        manifest,
    );
    const seal = try host.scratch.directory.dir.readFileAlloc(
        std.testing.io,
        "cache/" ++ key ++ "/.ecl-package.tgz",
        allocator,
        .unlimited,
    );
    defer allocator.free(seal);
    const expected_seal = try decodeFixtureBytes(fixture.bad_archive_hex);
    defer allocator.free(expected_seal);
    try std.testing.expectEqualSlices(u8, expected_seal, seal);
    try host.expectStack("'cache \"" ++ key ++ "\" pkg.store.present? 'cache \"" ++ key ++ "\" pkg.store.manifest", "1 " ++
        "\"{'format 1 'name \\\"bad\\\" 'version \\\"1.0.0\\\" 'exports {\\\"bad\\\" [\\\"**/*\\\"]} 'requires {}}\\n\"");
}

test "pkg store: ordinary Sessions have no package authority" {
    const programs = [_]struct { source: []const u8, word: []const u8 }{
        .{ .source = "'cache \"" ++ fixture_a_key ++ "\" pkg.store.present?", .word = "pkg.store.present?" },
        .{ .source = "'cache \"" ++ fixture_a_key ++ "\" pkg.store.manifest", .word = "pkg.store.manifest" },
        .{ .source = "'cache \"" ++ fixture_a_key ++ "\" \"a\" \"" ++ fixture_a_hash ++ "\" pkg.store.verify", .word = "pkg.store.verify" },
        .{ .source = "'cache \"" ++ fixture_a_key ++ "\" \"a\" \"" ++ fixture_a_hash ++ "\" pkg.store.read-seal", .word = "pkg.store.read-seal" },
        .{ .source = "[] pkg.store.gc", .word = "pkg.store.gc" },
        .{ .source = "[1] \"a\" 'cache \"" ++ fixture_a_key ++ "\" pkg.store.install", .word = "pkg.store.install" },
    };
    for (programs) |case| {
        try support.expectError(.{
            .name = case.word,
            .source = case.source,
            .kind = "domain",
            .word = case.word,
            .message_contains = "authority is unavailable",
        });
    }
    // A package Session without the named store still refuses; a bad store
    // symbol or a non-canonical key never reaches the host.
    var host = try PackageHost.init(.{});
    defer host.deinit();
    try host.expectError("'cache \"" ++ fixture_a_key ++ "\" pkg.store.present?", .{
        .name = "absent cache store",
        .source = "'cache \"" ++ fixture_a_key ++ "\" pkg.store.present?",
        .kind = "io",
        .word = "pkg.store.present?",
        .message_contains = "ECL_CACHE",
    });
    try host.expectError("'elsewhere \"" ++ fixture_a_key ++ "\" pkg.store.present?", .{
        .name = "unknown store",
        .source = "'elsewhere \"" ++ fixture_a_key ++ "\" pkg.store.present?",
        .kind = "domain",
        .word = "pkg.store.present?",
        .message_contains = "'cache or 'vendor",
    });
    var cached = try PackageHost.init(.{ .cache = true });
    defer cached.deinit();
    try cached.expectError("'cache \"../escape\" pkg.store.present?", .{
        .name = "non-canonical key",
        .source = "'cache \"../escape\" pkg.store.present?",
        .kind = "domain",
        .word = "pkg.store.present?",
        .message_contains = "canonical",
    });
    try cached.expectError("'cache \"../escape\" pkg.store.manifest", .{
        .name = "non-canonical manifest key",
        .source = "'cache \"../escape\" pkg.store.manifest",
        .kind = "domain",
        .word = "pkg.store.manifest",
        .message_contains = "canonical",
    });
}

test "pkg store: a project-controlled vendor symlink is refused at Session construction" {
    var host = try PackageHost.init(.{ .cache = true, .vendor = true });
    defer host.deinit();
    try host.scratch.directory.dir.createDir(std.testing.io, "elsewhere", .default_dir);
    try host.scratch.directory.dir.symLink(std.testing.io, "../elsewhere", "project/vendor", .{});
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    try std.testing.expectError(error.InvalidHostPolicy, host.openSession(heap.allocator()));
    // The synchronize and verify shapes open a present vendor store too, and
    // refuse the link the same way; nothing was created behind it.
    var sync_host = try PackageHost.initAt(host.scratch, .{ .cache = true });
    defer sync_host.deinit();
    try std.testing.expectError(error.InvalidHostPolicy, sync_host.openSession(heap.allocator()));
    var listing = try host.scratch.directory.dir.openDir(std.testing.io, "elsewhere", .{ .iterate = true });
    defer listing.close(std.testing.io);
    var iterator = listing.iterate();
    try std.testing.expect((try iterator.next(std.testing.io)) == null);
}

test "pkg store: existing immutable entry wins concurrent install" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(std.testing.io, "cache", .default_dir);
    const source = try fixtureInstallSource(fixture_a_key);
    defer allocator.free(source);
    var successes: std.atomic.Value(u32) = .init(0);
    var io_failures: std.atomic.Value(u32) = .init(0);
    var unexpected: std.atomic.Value(bool) = .init(false);
    var result = ConcurrentResult{
        .scratch = &scratch,
        .source = source,
        .successes = &successes,
        .io_failures = &io_failures,
        .unexpected = &unexpected,
    };
    const first = try std.Thread.spawn(.{}, concurrentInstall, .{&result});
    const second = try std.Thread.spawn(.{}, concurrentInstall, .{&result});
    first.join();
    second.join();
    try std.testing.expect(!unexpected.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), successes.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), io_failures.load(.acquire));
    var host = try PackageHost.initAt(&scratch, .{ .cache = true });
    defer host.deinit();
    try host.expectStack("'cache \"" ++ fixture_a_key ++ "\" pkg.store.present?", "1");
}

test "pkg sync: concurrent immutable publication treats the installed destination as success" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(std.testing.io, "cache", .default_dir);
    const source = try fixtureSyncInstallSource(fixture_a_key);
    defer allocator.free(source);
    var successes: std.atomic.Value(u32) = .init(0);
    var io_failures: std.atomic.Value(u32) = .init(0);
    var unexpected: std.atomic.Value(bool) = .init(false);
    var result = ConcurrentResult{
        .scratch = &scratch,
        .source = source,
        .successes = &successes,
        .io_failures = &io_failures,
        .unexpected = &unexpected,
    };
    const first = try std.Thread.spawn(.{}, concurrentInstall, .{&result});
    const second = try std.Thread.spawn(.{}, concurrentInstall, .{&result});
    first.join();
    second.join();
    try std.testing.expect(!unexpected.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), successes.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), io_failures.load(.acquire));
    var host = try PackageHost.initAt(&scratch, .{ .cache = true });
    defer host.deinit();
    try host.expectStack("'cache \"" ++ fixture_a_key ++ "\" pkg.store.present?", "1");
}

test "pkg sync: immutable publication accepts preflight winners but no other install failure" {
    var host = try PackageHost.init(.{ .cache = true });
    defer host.deinit();
    const installed = try fixtureInstallSource(fixture_a_key);
    defer allocator.free(installed);
    try host.expectStack(installed, "(\"a.ecl\" \"ecl.pkg\")");

    const confirmed = try fixtureSyncInstallSource(fixture_a_key);
    defer allocator.free(confirmed);
    try host.expectStack(confirmed, "");

    const occupied_key = "occupied-1.0.0-" ++ placeholder_hex;
    try host.scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "cache/" ++ occupied_key,
        .data = "occupied",
    });
    const occupied = try fixtureSyncInstallSource(occupied_key);
    defer allocator.free(occupied);
    try host.expectError(occupied, .{
        .name = "non-directory destination",
        .source = occupied,
        .kind = "io",
        .word = "pkg.store.install",
        .message_contains = "archive destination already exists",
    });

    const malformed = "[1] \"a\" 'cache \"" ++ fixture_a_key ++ "\" pkg.sync.install-immutable";
    try host.expectError(malformed, .{
        .name = "non-racing install error",
        .source = malformed,
        .kind = "domain",
        .word = "pkg.store.install",
    });
}

fn fixtureInstallSource(key: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" 'cache ");
    try appendString(&source.writer, key);
    try source.writer.writeAll(" pkg.store.install");
    return allocator.dupe(u8, source.written());
}

fn fixtureSyncInstallSource(key: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" 'cache ");
    try appendString(&source.writer, key);
    try source.writer.writeAll(" pkg.sync.install-immutable");
    return allocator.dupe(u8, source.written());
}

fn appendFixtureBytes(writer: *std.Io.Writer, encoded: []const u8) !void {
    try writer.writeByte('[');
    var high: ?u8 = null;
    var index: usize = 0;
    for (encoded) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        const nibble = try std.fmt.charToDigit(byte, 16);
        if (high) |first| {
            if (index != 0) try writer.writeByte(' ');
            try writer.print("{d}", .{first << 4 | nibble});
            high = null;
            index += 1;
        } else high = nibble;
    }
    if (high != null) return error.InvalidFixture;
    try writer.writeByte(']');
}

fn decodeFixtureBytes(encoded: []const u8) ![]u8 {
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    var high: ?u8 = null;
    for (encoded) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        const nibble = try std.fmt.charToDigit(byte, 16);
        if (high) |first| {
            try bytes.writer.writeByte(first << 4 | nibble);
            high = null;
        } else high = nibble;
    }
    if (high != null) return error.InvalidFixture;
    return allocator.dupe(u8, bytes.written());
}

test "pkg store: present distinguishes absent directory and invalid node" {
    var host = try PackageHost.init(.{ .cache = true });
    defer host.deinit();
    const directory_key = "dir-1.0.0-" ++ placeholder_hex;
    const file_key = "file-1.0.0-" ++ placeholder_hex;
    const link_key = "link-1.0.0-" ++ placeholder_hex;
    const absent_key = "absent-1.0.0-" ++ placeholder_hex;
    try host.scratch.directory.dir.createDir(std.testing.io, "cache/" ++ directory_key, .default_dir);
    try host.scratch.directory.dir.writeFile(std.testing.io, .{ .sub_path = "cache/" ++ file_key, .data = "not a directory" });
    try host.scratch.directory.dir.symLink(std.testing.io, directory_key, "cache/" ++ link_key, .{});
    try host.expectStack(
        "'cache \"" ++ absent_key ++ "\" pkg.store.present? 'cache \"" ++ directory_key ++ "\" pkg.store.present?",
        "0 1",
    );
    for ([_][]const u8{ file_key, link_key }) |invalid| {
        const invalid_source = try std.fmt.allocPrint(allocator, "'cache \"{s}\" pkg.store.present?", .{invalid});
        defer allocator.free(invalid_source);
        try host.expectError(invalid_source, .{
            .name = "invalid store node",
            .source = invalid_source,
            .kind = "io",
            .word = "pkg.store.present?",
            .message_contains = "not a real directory",
        });
    }
    // The manifest reader never follows a link at the entry or file level.
    const manifest_source = "'cache \"" ++ link_key ++ "\" pkg.store.manifest";
    try host.expectError(manifest_source, .{
        .name = "manifest through link",
        .source = manifest_source,
        .kind = "io",
        .word = "pkg.store.manifest",
    });
}

test "pkg sync: project file publication creates then strictly replaces beneath the project root" {
    var host = try PackageHost.init(.{});
    defer host.deinit();
    try host.expectStack("\"first\\n\" \"ecl.lock\" pkg.sync.write-project-file 'project \"ecl.lock\" fs.read-text", "\"first\\n\"");
    try host.expectStack("\"second\\n\" \"ecl.lock\" pkg.sync.write-project-file 'project \"ecl.lock\" fs.read-text", "\"second\\n\"");
    const replaced = try host.scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("second\n", replaced);

    try host.scratch.directory.dir.createDir(std.testing.io, "project/other.data", .default_dir);
    const non_regular = "\"unused\\n\" \"other.data\" pkg.sync.write-project-file";
    try host.expectError(non_regular, .{
        .name = "non-regular target",
        .source = non_regular,
        .kind = "io",
        .word = "fs.replace-text",
        .data = &.{
            .{ .name = "path", .expected = .{ .string = "other.data" } },
            .{ .name = "reason", .expected = .{ .symbol = "not-regular" } },
        },
    });

    // Cancellation before commit preserves the prior bytes.
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var runtime = try host.openSession(heap.allocator());
    defer runtime.deinit();
    switch (try runtime.runUnit("<pkg-store-warm>", "1 pop")) {
        .ok => {},
        .incomplete, .err => return error.UnexpectedWarmupResult,
    }
    runtime.requestCancellation();
    const cancelled = "\"must-not-publish\\n\" \"ecl.lock\" pkg.sync.write-project-file";
    const failure = switch (try runtime.runUnit("<pkg-store-cancel>", cancelled)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedCancellation,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, .{
        .name = "cancelled lock replacement",
        .source = cancelled,
        .kind = "cancelled",
    });
    const preserved = try host.scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("second\n", preserved);
}

test "pkg sync: explicit project root selects store mode without ambient discovery" {
    var host = try PackageHost.init(.{ .cache = true });
    defer host.deinit();
    try host.scratch.directory.dir.createDir(std.testing.io, "ambient", .default_dir);
    const ambient_manifest = "{'format 1 'name \"ambient\" 'version \"0.1.0\" 'exports {} 'requires {}}\n";
    const target_manifest = "{'format 1 'name \"target\" 'version \"0.1.0\" 'exports {} 'requires {}}\n";
    try host.scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "ambient/ecl.pkg",
        .data = ambient_manifest,
    });
    try host.scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "ambient/ecl.lock",
        .data = "{'format 1 'root \"ambient\" 'store 'vendor 'packages {} 'requires {\"ambient\" {}}}\n",
    });
    try host.scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "project/ecl.pkg",
        .data = target_manifest,
    });
    try host.scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "project/ecl.lock",
        .data = "{'format 1 'root \"target\" 'packages {} 'requires {\"target\" {}}}\n",
    });
    const ambient = try host.scratch.pathFor("ambient");
    defer allocator.free(ambient);
    host.project_start = ambient;
    const source = try syncSource(target_manifest, " 'store dict.has?");
    defer allocator.free(source);
    try host.expectStack(source, "0");
}

test "pkg sync: requirement derives the exact archive hash after identity validation" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeAll("\"bad\" \"1.0.0\" ");
    try source.writer.print("\"https://127.0.0.1:{d}/pkg/bad-1.0.0.tgz\" ", .{fixture.port});
    try source.writer.writeAll("pkg.sync.requirement dup 'version at swap 'hash at");
    var expected = std.Io.Writer.Allocating.init(allocator);
    defer expected.deinit();
    try expected.writer.print("\"1.0.0\" \"{s}\"", .{fixture.hash_mismatch_actual_hash});
    var host = try PackageHost.init(.{ .tls = true });
    defer host.deinit();
    try host.expectStack(source.written(), expected.written());
}

const HttpsFixture = struct {
    child: std.process.Child,
    port: u16,
    root_manifest: []u8,
    bad_archive_hex: []u8,
    hash_mismatch_actual_hash: []u8,
    hash_mismatch_manifest: []u8,
    prefix_violation_manifest: []u8,
    identity_mismatch_manifest: []u8,
    non_success_manifest: []u8,

    fn start() !HttpsFixture {
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{
                "python3",
                pkg_fixture.server_script,
                "--cert",
                pkg_fixture.server_cert,
                "--key",
                pkg_fixture.server_key,
            },
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(std.testing.io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = child.stdout.?.reader(std.testing.io, &buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        var announcement = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer announcement.deinit();
        const port_value = announcement.value.object.get("port") orelse return error.FixtureHandshakeFailed;
        if (port_value != .integer) return error.FixtureHandshakeFailed;
        const root_manifest = try announcementString(announcement.value, "root_manifest");
        errdefer allocator.free(root_manifest);
        const bad_archive_hex = try announcementString(announcement.value, "bad_archive_hex");
        errdefer allocator.free(bad_archive_hex);
        const hash_mismatch_actual_hash = try announcementString(announcement.value, "hash_mismatch_actual_hash");
        errdefer allocator.free(hash_mismatch_actual_hash);
        const hash_mismatch_manifest = try announcementString(announcement.value, "hash_mismatch_manifest");
        errdefer allocator.free(hash_mismatch_manifest);
        const prefix_violation_manifest = try announcementString(announcement.value, "prefix_violation_manifest");
        errdefer allocator.free(prefix_violation_manifest);
        const identity_mismatch_manifest = try announcementString(announcement.value, "identity_mismatch_manifest");
        errdefer allocator.free(identity_mismatch_manifest);
        const non_success_manifest = try announcementString(announcement.value, "non_success_manifest");
        errdefer allocator.free(non_success_manifest);
        return .{
            .child = child,
            .port = std.math.cast(u16, port_value.integer) orelse return error.FixtureHandshakeFailed,
            .root_manifest = root_manifest,
            .bad_archive_hex = bad_archive_hex,
            .hash_mismatch_actual_hash = hash_mismatch_actual_hash,
            .hash_mismatch_manifest = hash_mismatch_manifest,
            .prefix_violation_manifest = prefix_violation_manifest,
            .identity_mismatch_manifest = identity_mismatch_manifest,
            .non_success_manifest = non_success_manifest,
        };
    }

    fn stop(self: *HttpsFixture) void {
        self.child.kill(std.testing.io);
        allocator.free(self.root_manifest);
        allocator.free(self.bad_archive_hex);
        allocator.free(self.hash_mismatch_actual_hash);
        allocator.free(self.hash_mismatch_manifest);
        allocator.free(self.prefix_violation_manifest);
        allocator.free(self.identity_mismatch_manifest);
        allocator.free(self.non_success_manifest);
    }
};

fn announcementString(announcement: std.json.Value, name: []const u8) ![]u8 {
    const item = announcement.object.get(name) orelse return error.FixtureHandshakeFailed;
    if (item != .string) return error.FixtureHandshakeFailed;
    return allocator.dupe(u8, item.string);
}

const Scratch = struct {
    directory: std.testing.TmpDir,
    path: [:0]u8,

    fn init() !Scratch {
        var directory = std.testing.tmpDir(.{});
        const path = directory.dir.realPathFileAlloc(std.testing.io, ".", allocator) catch |err| {
            directory.cleanup();
            return err;
        };
        return .{ .directory = directory, .path = path };
    }

    fn deinit(self: *Scratch) void {
        allocator.free(self.path);
        self.directory.cleanup();
    }

    fn pathFor(self: *Scratch, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ self.path, std.fs.path.sep, name });
    }
};

const HostOptions = struct {
    tls: bool = false,
    /// Name `<scratch>/cache` as the shared cache store, creating it.
    cache: bool = false,
    /// Grant the `vendor` command shape, which creates the vendor store.
    vendor: bool = false,
};

/// One package-command host over a scratch directory: `<scratch>/project` is
/// the `'project` filesystem root, `<scratch>/cache` the optional shared
/// cache, and `<scratch>/project/vendor` the optional vendor store.
const PackageHost = struct {
    scratch: *Scratch,
    /// Heap-allocated so the borrowed `scratch` pointer stays valid when the
    /// host is returned by value.
    owned_scratch: ?*Scratch,
    options: HostOptions,
    project: []u8,
    project_handle: std.Io.Dir,
    cache: []u8,
    output: *DiscardingOutput,
    project_start: ?[]const u8 = null,

    fn init(options: HostOptions) !PackageHost {
        const owned = try allocator.create(Scratch);
        errdefer allocator.destroy(owned);
        owned.* = try Scratch.init();
        errdefer owned.deinit();
        var host = try initAt(owned, options);
        host.owned_scratch = owned;
        return host;
    }

    fn initAt(scratch: *Scratch, options: HostOptions) !PackageHost {
        scratch.directory.dir.createDir(std.testing.io, "project", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        // Tests seed store entries before the first Session opens the
        // store, so the cache directory exists from construction on.
        if (options.cache) scratch.directory.dir.createDir(std.testing.io, "cache", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const project = try scratch.pathFor("project");
        errdefer allocator.free(project);
        const cache = try scratch.pathFor("cache");
        errdefer allocator.free(cache);
        const output = try DiscardingOutput.create();
        errdefer allocator.destroy(output);
        const project_handle = try scratch.directory.dir.openDir(std.testing.io, "project", .{});
        return .{
            .scratch = scratch,
            .owned_scratch = null,
            .options = options,
            .project = project,
            .project_handle = project_handle,
            .cache = cache,
            .output = output,
        };
    }

    fn deinit(self: *PackageHost) void {
        self.project_handle.close(std.testing.io);
        allocator.destroy(self.output);
        allocator.free(self.cache);
        allocator.free(self.project);
        if (self.owned_scratch) |owned| {
            owned.deinit();
            allocator.destroy(owned);
        }
    }

    fn cachePath(self: *const PackageHost) []const u8 {
        return self.cache;
    }

    fn openSession(self: *const PackageHost, heap_allocator: std.mem.Allocator) !session.Session {
        return openSessionWithConfig(self, heap_allocator, .cooperative);
    }

    fn openSessionWithConfig(self: *const PackageHost, heap_allocator: std.mem.Allocator, config: session.Config) !session.Session {
        return session.Session.initPackageCommand(heap_allocator, &.{}, .{
            .io = std.testing.io,
            .output = self.output.writer(),
            .diagnostics = self.output.writer(),
            .tls_trust = if (self.options.tls) .{ .ca_file = pkg_fixture.ca_file, .now = valid_cert_time } else null,
            .project_start = self.project_start,
            .filesystem_policy = .{ .roots = &.{.{
                .name = "project",
                .absolute_path = self.project,
                .permissions = .{ .read_data = true, .inspect = true, .create = true, .replace = true },
            }} },
        }, config, self.grant());
    }

    /// The command shape the options describe: the vendor command when
    /// requested, otherwise synchronization (cache created when named) or
    /// project-only inspection.
    fn grant(self: *const PackageHost) package_authority.PackageGrant {
        const cache: ?[]const u8 = if (self.options.cache) self.cache else null;
        if (self.options.vendor) return .{ .vendor = .{ .cache = cache, .project = self.project_handle } };
        if (self.options.cache) return .{ .synchronize = .{ .cache = cache, .project = self.project_handle } };
        return .inspect;
    }

    fn expectStack(self: *const PackageHost, source: []const u8, expected: []const u8) !void {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var runtime = try self.openSession(heap.allocator());
        defer runtime.deinit();
        switch (try runtime.runUnit("<pkg-store-test>", source)) {
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
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }

    fn expectError(self: *const PackageHost, source: []const u8, expected: support.ErrorCase) !void {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var runtime = try self.openSession(heap.allocator());
        defer runtime.deinit();
        const failure = switch (try runtime.runUnit("<pkg-store-test>", source)) {
            .ok, .incomplete => return error.ExpectedLanguageError,
            .err => |item| item,
        };
        defer runtime.release(failure);
        try support.expectLanguageError(failure, expected);
    }
};

/// Session output is irrelevant to every case here. Each host owns one
/// heap-allocated discarding writer: the writer borrows its buffer, so it
/// needs a stable address, and the concurrent-install cases run two hosts
/// on separate threads at once.
const DiscardingOutput = struct {
    buffer: [256]u8,
    sink: std.Io.Writer.Discarding,

    fn create() !*DiscardingOutput {
        const output = try allocator.create(DiscardingOutput);
        output.sink = std.Io.Writer.Discarding.init(&output.buffer);
        return output;
    }

    fn writer(self: *DiscardingOutput) *std.Io.Writer {
        return &self.sink.writer;
    }
};

const PackageOperation = enum { inspect, install };

fn packageSource(
    port: u16,
    endpoint: []const u8,
    package: []const u8,
    operation: PackageOperation,
    key: ?[]const u8,
) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.print(
        "{{'target \"https://127.0.0.1:{d}{s}\"}} http.get-bytes 'body at ",
        .{ port, endpoint },
    );
    try appendString(&source.writer, package);
    switch (operation) {
        .inspect => try source.writer.writeAll(" pkg.store.inspect"),
        .install => {
            try source.writer.writeAll(" 'cache ");
            try appendString(&source.writer, key.?);
            try source.writer.writeAll(" pkg.store.install");
        },
    }
    return allocator.dupe(u8, source.written());
}

fn appendString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '\\', '"' => {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        },
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

const ConcurrentResult = struct {
    scratch: *Scratch,
    source: []const u8,
    successes: *std.atomic.Value(u32),
    io_failures: *std.atomic.Value(u32),
    unexpected: *std.atomic.Value(bool),
};

fn concurrentInstall(result: *ConcurrentResult) void {
    var heap: test_heap.SessionHeap = .init;
    var host = PackageHost.initAt(result.scratch, .{ .cache = true }) catch {
        result.unexpected.store(true, .release);
        test_heap.retire(&heap);
        return;
    };
    defer host.deinit();
    var runtime = host.openSession(heap.allocator()) catch {
        result.unexpected.store(true, .release);
        test_heap.retire(&heap);
        return;
    };
    const outcome = runtime.runUnit("<pkg-store-race>", result.source) catch {
        result.unexpected.store(true, .release);
        runtime.deinit();
        test_heap.retire(&heap);
        return;
    };
    switch (outcome) {
        .ok => _ = result.successes.fetchAdd(1, .monotonic),
        .incomplete => result.unexpected.store(true, .release),
        .err => |failure| {
            support.expectLanguageError(failure, .{
                .name = "concurrent install loser",
                .source = result.source,
                .kind = "io",
                .word = "pkg.store.install",
            }) catch result.unexpected.store(true, .release);
            runtime.release(failure);
            _ = result.io_failures.fetchAdd(1, .monotonic);
        },
    }
    runtime.deinit();
    test_heap.retire(&heap);
}

fn syncSource(manifest: []const u8, suffix: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, manifest);
    try source.writer.writeAll(" pkg.manifest.read pkg.sync.run");
    try source.writer.writeAll(suffix);
    return allocator.dupe(u8, source.written());
}

fn canonicalLockSource(lock: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, lock);
    try source.writer.writeAll(" dup pkg.lock.read pkg.lock.write match?");
    return allocator.dupe(u8, source.written());
}

fn requestCountSource(port: u16) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.print(
        "{{'target \"https://127.0.0.1:{d}/__counts\"}} http.get 'body at json.parse ",
        .{port},
    );
    for ([_][]const u8{
        "/pkg/a-1.0.0.tgz",
        "/pkg/b-1.0.0.tgz",
        "/pkg/c-1.2.0.tgz",
        "/pkg/c-1.5.0.tgz",
    }) |endpoint| {
        try source.writer.writeAll("dup ");
        try appendString(&source.writer, endpoint);
        try source.writer.writeAll(" at swap ");
    }
    try source.writer.writeAll("pop");
    return allocator.dupe(u8, source.written());
}

fn expectStoreEntries(path: []const u8, prefixes: []const []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var found = try allocator.alloc(bool, prefixes.len);
    defer allocator.free(found);
    @memset(found, false);
    var count: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        try std.testing.expect(entry.kind == .directory);
        var matched = false;
        for (prefixes, 0..) |prefix, index| {
            if (std.mem.startsWith(u8, entry.name, prefix)) {
                try std.testing.expect(!found[index]);
                found[index] = true;
                matched = true;
            }
        }
        try std.testing.expect(matched);
    }
    try std.testing.expectEqual(prefixes.len, count);
    for (found) |present| try std.testing.expect(present);
}

/// A failed synchronization leaves the prior lock and an empty cache: the
/// package Session opens the cache directory up front, so emptiness rather
/// than absence is the observable invariant.
const FailurePaths = struct {
    host: *PackageHost,

    fn init(host: *PackageHost) !FailurePaths {
        try host.scratch.directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/ecl.lock",
            .data = "prior lock bytes\n",
        });
        return .{ .host = host };
    }

    fn expectUnchanged(self: FailurePaths) !void {
        const lock = try self.host.scratch.directory.dir.readFileAlloc(
            std.testing.io,
            "project/ecl.lock",
            allocator,
            .unlimited,
        );
        defer allocator.free(lock);
        try std.testing.expectEqualStrings("prior lock bytes\n", lock);
        try expectStoreEntries(self.host.cachePath(), &.{});
    }
};

test "pkg sync: resolves transitive MVS and writes canonical lock" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const source = try syncSource(
        fixture.root_manifest,
        " dup 'packages at dict.keys sort swap ['packages \"c\" 'version] at-path",
    );
    defer allocator.free(source);
    try host.expectStack(source, "(\"a\" \"b\" \"c\") \"1.5.0\"");

    const lock = try host.scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(lock);
    const canonical = try canonicalLockSource(lock);
    defer allocator.free(canonical);
    try host.expectStack(canonical, "1");
    try expectStoreEntries(host.cachePath(), &.{ "a-1.0.0-", "b-1.0.0-", "c-1.5.0-" });
}

test "pkg sync: deleting lock reproduces identical bytes without refetching present entries" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const source = try syncSource(fixture.root_manifest, " pop");
    defer allocator.free(source);
    try host.expectStack(source, "");
    const first = try host.scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(first);
    try host.scratch.directory.dir.deleteFile(std.testing.io, "project/ecl.lock");
    try host.expectStack(source, "");
    const second = try host.scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    const counts = try requestCountSource(fixture.port);
    defer allocator.free(counts);
    try host.expectStack(counts, "2 2 2 2");
}

test "pkg sync: hash mismatch names package and hashes without store or lock" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const paths = try FailurePaths.init(&host);
    const source = try syncSource(fixture.hash_mismatch_manifest, "");
    defer allocator.free(source);
    try host.expectError(source, .{
        .name = "hash mismatch",
        .source = source,
        .kind = "domain",
        .message_contains = "hash does not match",
        .data = &.{
            .{ .name = "package", .expected = .{ .string = "bad" } },
            .{ .name = "declared-hash", .expected = .{ .string = "sha256-0000000000000000000000000000000000000000000000000000000000000000" } },
            .{ .name = "actual-hash", .expected = .{ .string = fixture.hash_mismatch_actual_hash } },
        },
    });
    try paths.expectUnchanged();
}

test "pkg sync: prefix violation names offender without retained entry" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const paths = try FailurePaths.init(&host);
    const source = try syncSource(fixture.prefix_violation_manifest, "");
    defer allocator.free(source);
    try host.expectError(source, .{
        .name = "prefix violation",
        .source = source,
        .kind = "domain",
        .message_contains = "outside export namespace `foo`",
        .data = &.{.{ .name = "package", .expected = .{ .string = "foo" } }},
    });
    try paths.expectUnchanged();
}

test "pkg sync: manifest identity mismatch retains no entry or lock" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const paths = try FailurePaths.init(&host);
    const source = try syncSource(fixture.identity_mismatch_manifest, "");
    defer allocator.free(source);
    try host.expectError(source, .{
        .name = "identity mismatch",
        .source = source,
        .kind = "domain",
        .message_contains = "identity does not match",
        .data = &.{
            .{ .name = "requested-name", .expected = .{ .string = "expected" } },
            .{ .name = "requested-version", .expected = .{ .string = "1.0.0" } },
            .{ .name = "actual-name", .expected = .{ .string = "actual" } },
            .{ .name = "actual-version", .expected = .{ .string = "1.0.0" } },
        },
    });
    try paths.expectUnchanged();
}

test "pkg sync: non-success HTTP names package URL and status" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const paths = try FailurePaths.init(&host);
    const source = try syncSource(fixture.non_success_manifest, "");
    defer allocator.free(source);
    const url = try std.fmt.allocPrint(allocator, "https://127.0.0.1:{d}/status/503", .{fixture.port});
    defer allocator.free(url);
    try host.expectError(source, .{
        .name = "non-success response",
        .source = source,
        .kind = "io",
        .message_contains = "non-success HTTP status",
        .data = &.{
            .{ .name = "package", .expected = .{ .string = "down" } },
            .{ .name = "url", .expected = .{ .string = url } },
            .{ .name = "status", .expected = .{ .int = 503 } },
        },
    });
    try paths.expectUnchanged();
}

test "pkg sync: verification streams every selected seal and offline sync names an absent entry" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var host = try PackageHost.init(.{ .tls = true, .cache = true });
    defer host.deinit();
    const online = try syncSource(fixture.root_manifest, " pop");
    defer allocator.free(online);
    try host.expectStack(online, "");
    const lock = try host.scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(lock);

    // Verification streams every retained seal from the cache store.
    var verify = std.Io.Writer.Allocating.init(allocator);
    defer verify.deinit();
    try appendString(&verify.writer, lock);
    try verify.writer.writeAll(" pkg.lock.read pkg.sync.verify");
    try host.expectStack(verify.written(), "3");

    // Offline discovery names the first absent exact entry by package,
    // store, and key, and opens no request.
    var offline = std.Io.Writer.Allocating.init(allocator);
    defer offline.deinit();
    try appendString(&offline.writer, fixture.root_manifest);
    try offline.writer.writeAll(" pkg.manifest.read pkg.sync.run-offline pop");
    var empty = try PackageHost.init(.{ .cache = true });
    defer empty.deinit();
    try empty.expectError(offline.written(), .{
        .name = "offline missing entry",
        .source = offline.written(),
        .kind = "io",
        .message_contains = "missing a package store entry",
        .data = &.{
            .{ .name = "package", .expected = .{ .string = "a" } },
            .{ .name = "store", .expected = .{ .symbol = "cache" } },
        },
    });
}
