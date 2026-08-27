//! Public package-store and synchronization behavior over the hermetic HTTPS fixture.
//!
//! Patch 2 registers the complete proof surface before production symbols
//! exist. Each skipped case is activated by the patch that implements the
//! behavior named in its title.
const std = @import("std");
const pkg_fixture = @import("pkg_fixture_options");
const archive_fixtures = @import("archive_fixture_options");
const machine = @import("../machine.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;
const valid_cert_time = std.Io.Timestamp.fromNanoseconds(
    @as(i96, 1_788_220_800) * std.time.ns_per_s,
);

test "pkg store: inspect returns exact root manifest" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    const source = try packageSource(fixture.port, "/pkg/bad-1.0.0.tgz", "bad", .inspect, null);
    defer allocator.free(source);
    try expectHostStack(
        source,
        "\"{'format 1 'name \\\"bad\\\" 'version \\\"1.0.0\\\" 'requires {}}\\n\"",
        true,
    );
}

test "pkg store: rejects invalid source package layouts before publication" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    const cases = [_]struct { endpoint: []const u8, message: []const u8 }{
        .{ .endpoint = "/pkg/foo-1.0.0-prefix.tgz", .message = "bar.ecl" },
        .{ .endpoint = "/pkg/foo-1.0.0-nested.tgz", .message = "nested/foo.ecl" },
        .{ .endpoint = "/pkg/foo-1.0.0-native.tgz", .message = "foo.eclmod" },
        .{ .endpoint = "/pkg/foo-1.0.0-missing-manifest.tgz", .message = "no root ecl.pkg" },
        .{ .endpoint = "/pkg/foo-1.0.0-invalid-manifest.tgz", .message = "not valid UTF-8" },
        .{ .endpoint = "/pkg/foo-1.0.0-reserved-seal.tgz", .message = ".ecl-package.tgz" },
    };
    for (cases) |case| {
        const source = try packageSource(fixture.port, case.endpoint, "foo", .inspect, null);
        defer allocator.free(source);
        try expectHostError(source, .{
            .name = case.endpoint,
            .source = source,
            .kind = "domain",
            .word = "pkg.store.inspect",
            .message_contains = case.message,
        }, true);
    }
}

test "pkg store: atomically installs one valid source package" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const destination = try scratch.pathFor("cache/pkg/bad-entry");
    defer allocator.free(destination);
    const source = try packageSource(fixture.port, "/pkg/bad-1.0.0.tgz", "bad", .install, destination);
    defer allocator.free(source);
    try expectHostStack(source, "(\"bad.ecl\" \"ecl.pkg\")", true);
    const manifest = try scratch.directory.dir.readFileAlloc(
        std.testing.io,
        "cache/pkg/bad-entry/ecl.pkg",
        allocator,
        .unlimited,
    );
    defer allocator.free(manifest);
    try std.testing.expectEqualStrings("{'format 1 'name \"bad\" 'version \"1.0.0\" 'requires {}}\n", manifest);
    const seal = try scratch.directory.dir.readFileAlloc(
        std.testing.io,
        "cache/pkg/bad-entry/.ecl-package.tgz",
        allocator,
        .unlimited,
    );
    defer allocator.free(seal);
    const expected_seal = try decodeFixtureBytes(fixture.bad_archive_hex);
    defer allocator.free(expected_seal);
    try std.testing.expectEqualSlices(u8, expected_seal, seal);
    const present_source = try onePathSource(destination, " pkg.store.present?");
    defer allocator.free(present_source);
    try expectHostStack(present_source, "1", false);
}

test "pkg store: existing immutable entry wins concurrent install" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const destination = try scratch.pathFor("cache/pkg/racing-entry");
    defer allocator.free(destination);
    const source = try fixtureInstallSource(destination);
    defer allocator.free(source);
    var successes: std.atomic.Value(u32) = .init(0);
    var io_failures: std.atomic.Value(u32) = .init(0);
    var unexpected: std.atomic.Value(bool) = .init(false);
    var result = ConcurrentResult{
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
    const present_source = try onePathSource(destination, " pkg.store.present?");
    defer allocator.free(present_source);
    try expectHostStack(present_source, "1", false);
}

test "pkg sync: concurrent immutable publication treats the installed destination as success" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const destination = try scratch.pathFor("cache/pkg/racing-sync-entry");
    defer allocator.free(destination);
    const source = try fixtureSyncInstallSource(destination);
    defer allocator.free(source);
    var successes: std.atomic.Value(u32) = .init(0);
    var io_failures: std.atomic.Value(u32) = .init(0);
    var unexpected: std.atomic.Value(bool) = .init(false);
    var result = ConcurrentResult{
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
    const present_source = try onePathSource(destination, " pkg.store.present?");
    defer allocator.free(present_source);
    try expectHostStack(present_source, "1", false);
}

test "pkg sync: immutable publication accepts preflight winners but no other install failure" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const destination = try scratch.pathFor("cache/pkg/existing-sync-entry");
    defer allocator.free(destination);
    const installed = try fixtureInstallSource(destination);
    defer allocator.free(installed);
    try expectHostStack(installed, "(\"a.ecl\" \"ecl.pkg\")", false);

    const confirmed = try fixtureSyncInstallSource(destination);
    defer allocator.free(confirmed);
    try expectHostStack(confirmed, "", false);

    try scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "cache/pkg/not-a-directory",
        .data = "occupied",
    });
    const occupied_destination = try scratch.pathFor("cache/pkg/not-a-directory");
    defer allocator.free(occupied_destination);
    const occupied = try fixtureSyncInstallSource(occupied_destination);
    defer allocator.free(occupied);
    try expectHostError(occupied, .{
        .name = "non-directory destination",
        .source = occupied,
        .kind = "io",
        .word = "pkg.store.install",
        .message_contains = "archive destination already exists",
    }, false);

    var malformed = std.Io.Writer.Allocating.init(allocator);
    defer malformed.deinit();
    try malformed.writer.writeAll("[1] \"a\" ");
    try appendString(&malformed.writer, destination);
    try malformed.writer.writeAll(" pkg.sync.install-immutable");
    try expectHostError(malformed.written(), .{
        .name = "non-racing install error",
        .source = malformed.written(),
        .kind = "domain",
        .word = "pkg.store.install",
    }, false);
}

fn fixtureInstallSource(destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" ");
    try appendString(&source.writer, destination);
    try source.writer.writeAll(" pkg.store.install");
    return allocator.dupe(u8, source.written());
}

fn fixtureSyncInstallSource(destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" ");
    try appendString(&source.writer, destination);
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
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(std.testing.io, "directory", .default_dir);
    try scratch.directory.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "not a directory" });
    try scratch.directory.dir.symLink(std.testing.io, "directory", "link", .{});
    const absent = try scratch.pathFor("absent");
    defer allocator.free(absent);
    const directory = try scratch.pathFor("directory");
    defer allocator.free(directory);
    const file = try scratch.pathFor("file");
    defer allocator.free(file);
    const link = try scratch.pathFor("link");
    defer allocator.free(link);
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, absent);
    try source.writer.writeAll(" pkg.store.present? ");
    try appendString(&source.writer, directory);
    try source.writer.writeAll(" pkg.store.present?");
    try expectHostStack(source.written(), "0 1", false);
    for ([_][]const u8{ file, link }) |invalid| {
        const invalid_source = try onePathSource(invalid, " pkg.store.present?");
        defer allocator.free(invalid_source);
        try expectHostError(invalid_source, .{
            .name = "invalid store node",
            .source = invalid_source,
            .kind = "io",
            .word = "pkg.store.present?",
            .message_contains = "not a real directory",
        }, false);
    }
}

test "pkg store: atomic lock replacement preserves prior bytes on failure" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.writeFile(std.testing.io, .{ .sub_path = "ecl.lock", .data = "prior\n" });
    const lock_path = try scratch.pathFor("ecl.lock");
    defer allocator.free(lock_path);
    const success = try lockSource("replacement\n", lock_path);
    defer allocator.free(success);
    try expectHostStack(success, "", false);
    const replaced = try scratch.directory.dir.readFileAlloc(std.testing.io, "ecl.lock", allocator, .unlimited);
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("replacement\n", replaced);

    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
    }, .cooperative);
    defer runtime.deinit();
    switch (try runtime.runUnit("<pkg-store-warm>", "1 pop")) {
        .ok => {},
        .incomplete, .err => return error.UnexpectedWarmupResult,
    }
    runtime.requestCancellation();
    const cancelled = try lockSource("must-not-publish\n", lock_path);
    defer allocator.free(cancelled);
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
    const preserved = try scratch.directory.dir.readFileAlloc(std.testing.io, "ecl.lock", allocator, .unlimited);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("replacement\n", preserved);
}

test "pkg store: atomic new-file publication names and preserves its actual target" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const manifest_path = try scratch.pathFor("custom.data");
    defer allocator.free(manifest_path);
    const initial = try newFileSource("first\n", manifest_path);
    defer allocator.free(initial);
    try expectHostStack(initial, "", false);

    const racing = try newFileSource("second\n", manifest_path);
    defer allocator.free(racing);
    try expectHostError(racing, .{
        .name = "existing manifest wins atomic create",
        .source = racing,
        .kind = "io",
        .word = "pkg.store.write-new",
        .message_contains = "custom.data",
    }, false);
    const preserved = try scratch.directory.dir.readFileAlloc(
        std.testing.io,
        "custom.data",
        allocator,
        .unlimited,
    );
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("first\n", preserved);

    try scratch.directory.dir.createDir(std.testing.io, "other.data", .default_dir);
    const directory_path = try scratch.pathFor("other.data");
    defer allocator.free(directory_path);
    const non_regular = try newFileSource("unused\n", directory_path);
    defer allocator.free(non_regular);
    try expectHostError(non_regular, .{
        .name = "non-regular target names the supplied project file",
        .source = non_regular,
        .kind = "io",
        .word = "pkg.store.write-new",
        .message_contains = "other.data",
    }, false);
}

test "pkg sync: explicit project root, not ambient discovery, selects store mode" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(std.testing.io, "ambient", .default_dir);
    try scratch.directory.dir.createDir(std.testing.io, "target", .default_dir);
    try scratch.directory.dir.createDir(std.testing.io, "cache", .default_dir);
    const ambient_manifest = "{'format 1 'name \"ambient\" 'version \"0.1.0\" 'requires {}}\n";
    const target_manifest = "{'format 1 'name \"target\" 'version \"0.1.0\" 'requires {}}\n";
    try scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "ambient/ecl.pkg",
        .data = ambient_manifest,
    });
    try scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "ambient/ecl.lock",
        .data = "{'format 1 'root \"ambient\" 'store 'vendor 'packages {} 'requires {\"ambient\" {}}}\n",
    });
    try scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "target/ecl.pkg",
        .data = target_manifest,
    });
    try scratch.directory.dir.writeFile(std.testing.io, .{
        .sub_path = "target/ecl.lock",
        .data = "{'format 1 'root \"target\" 'packages {} 'requires {\"target\" {}}}\n",
    });
    const ambient = try scratch.pathFor("ambient");
    defer allocator.free(ambient);
    const target = try scratch.pathFor("target");
    defer allocator.free(target);
    const cache = try scratch.pathFor("cache");
    defer allocator.free(cache);
    const source = try syncSource(target_manifest, target, " 'store dict.has?");
    defer allocator.free(source);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = cache }};
    try expectHostStackEnvironProject(source, "0", false, environ, ambient);
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
    try expectHostStack(source.written(), expected.written(), true);
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

const PackageOperation = enum { inspect, install };

fn packageSource(
    port: u16,
    endpoint: []const u8,
    package: []const u8,
    operation: PackageOperation,
    destination: ?[]const u8,
) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.print("\"https://127.0.0.1:{d}{s}\" {{}} http.get-bytes 'body at ", .{ port, endpoint });
    try appendString(&source.writer, package);
    switch (operation) {
        .inspect => try source.writer.writeAll(" pkg.store.inspect"),
        .install => {
            try source.writer.writeByte(' ');
            try appendString(&source.writer, destination.?);
            try source.writer.writeAll(" pkg.store.install");
        },
    }
    return allocator.dupe(u8, source.written());
}

fn onePathSource(path: []const u8, suffix: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, path);
    try source.writer.writeAll(suffix);
    return allocator.dupe(u8, source.written());
}

fn lockSource(text: []const u8, path: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, text);
    try source.writer.writeByte(' ');
    try appendString(&source.writer, path);
    try source.writer.writeAll(" pkg.store.write-lock");
    return allocator.dupe(u8, source.written());
}

fn newFileSource(text: []const u8, path: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, text);
    try source.writer.writeByte(' ');
    try appendString(&source.writer, path);
    try source.writer.writeAll(" pkg.store.write-new");
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

fn expectHostStack(source: []const u8, expected: []const u8, tls: bool) !void {
    return expectHostStackEnviron(source, expected, tls, &.{});
}

fn expectHostStackEnviron(
    source: []const u8,
    expected: []const u8,
    tls: bool,
    environ: []const machine.Environ.Entry,
) !void {
    return expectHostStackEnvironProject(source, expected, tls, environ, null);
}

fn expectHostStackEnvironProject(
    source: []const u8,
    expected: []const u8,
    tls: bool,
    environ: []const machine.Environ.Entry,
    project_start: ?[]const u8,
) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .tls_trust = if (tls) .{ .ca_file = pkg_fixture.ca_file, .now = valid_cert_time } else null,
        .environ = environ,
        .project_start = project_start,
    }, .cooperative);
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

fn expectHostError(source: []const u8, expected: support.ErrorCase, tls: bool) !void {
    return expectHostErrorEnviron(source, expected, tls, &.{});
}

fn expectHostErrorEnviron(
    source: []const u8,
    expected: support.ErrorCase,
    tls: bool,
    environ: []const machine.Environ.Entry,
) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .tls_trust = if (tls) .{ .ca_file = pkg_fixture.ca_file, .now = valid_cert_time } else null,
        .environ = environ,
    }, .cooperative);
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<pkg-store-test>", source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

const ConcurrentResult = struct {
    source: []const u8,
    successes: *std.atomic.Value(u32),
    io_failures: *std.atomic.Value(u32),
    unexpected: *std.atomic.Value(bool),
};

fn concurrentInstall(result: *ConcurrentResult) void {
    var heap: test_heap.SessionHeap = .init;
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
    }, .cooperative) catch {
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

fn syncSource(manifest: []const u8, project: []const u8, suffix: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendString(&source.writer, manifest);
    try source.writer.writeAll(" pkg.manifest.read ");
    try appendString(&source.writer, project);
    try source.writer.writeAll(" pkg.sync.run");
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
        "\"https://127.0.0.1:{d}/__counts\" {{}} http.get 'body at json.parse ",
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

fn expectPathAbsent(path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.ExpectedPathAbsent;
}

const FailurePaths = struct {
    scratch: *Scratch,
    cache: []u8,
    project: []u8,

    fn init(scratch: *Scratch) !FailurePaths {
        try scratch.directory.dir.createDir(std.testing.io, "project", .default_dir);
        try scratch.directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/ecl.lock",
            .data = "prior lock bytes\n",
        });
        const cache = try scratch.pathFor("cache");
        errdefer allocator.free(cache);
        const project = try scratch.pathFor("project");
        return .{ .scratch = scratch, .cache = cache, .project = project };
    }

    fn deinit(self: FailurePaths) void {
        allocator.free(self.cache);
        allocator.free(self.project);
    }

    fn expectUnchanged(self: FailurePaths) !void {
        const lock = try self.scratch.directory.dir.readFileAlloc(
            std.testing.io,
            "project/ecl.lock",
            allocator,
            .unlimited,
        );
        defer allocator.free(lock);
        try std.testing.expectEqualStrings("prior lock bytes\n", lock);
        try expectPathAbsent(self.cache);
    }
};

test "pkg sync: resolves transitive MVS and writes canonical lock" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(std.testing.io, "project", .default_dir);
    const cache = try scratch.pathFor("cache");
    defer allocator.free(cache);
    const project = try scratch.pathFor("project");
    defer allocator.free(project);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = cache }};
    const source = try syncSource(
        fixture.root_manifest,
        project,
        " dup 'packages at dict.keys sort swap ['packages \"c\" 'version] at-path",
    );
    defer allocator.free(source);
    try expectHostStackEnviron(source, "(\"a\" \"b\" \"c\") \"1.5.0\"", true, environ);

    const lock = try scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(lock);
    const canonical = try canonicalLockSource(lock);
    defer allocator.free(canonical);
    try expectHostStack(canonical, "1", false);
    try expectStoreEntries(cache, &.{ "a-1.0.0-", "b-1.0.0-", "c-1.5.0-" });
}

test "pkg sync: deleting lock reproduces identical bytes without refetching present entries" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(std.testing.io, "project", .default_dir);
    const cache = try scratch.pathFor("cache");
    defer allocator.free(cache);
    const project = try scratch.pathFor("project");
    defer allocator.free(project);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = cache }};
    const source = try syncSource(fixture.root_manifest, project, " pop");
    defer allocator.free(source);
    try expectHostStackEnviron(source, "", true, environ);
    const first = try scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(first);
    try scratch.directory.dir.deleteFile(std.testing.io, "project/ecl.lock");
    try expectHostStackEnviron(source, "", true, environ);
    const second = try scratch.directory.dir.readFileAlloc(std.testing.io, "project/ecl.lock", allocator, .unlimited);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    const counts = try requestCountSource(fixture.port);
    defer allocator.free(counts);
    try expectHostStack(counts, "2 2 2 2", true);
}

test "pkg sync: hash mismatch names package and hashes without store or lock" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const paths = try FailurePaths.init(&scratch);
    defer paths.deinit();
    const source = try syncSource(fixture.hash_mismatch_manifest, paths.project, "");
    defer allocator.free(source);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = paths.cache }};
    try expectHostErrorEnviron(source, .{
        .name = "hash mismatch",
        .source = source,
        .kind = "domain",
        .message_contains = "hash does not match",
        .data = &.{
            .{ .name = "package", .expected = .{ .string = "bad" } },
            .{ .name = "declared-hash", .expected = .{ .string = "sha256-0000000000000000000000000000000000000000000000000000000000000000" } },
            .{ .name = "actual-hash", .expected = .{ .string = fixture.hash_mismatch_actual_hash } },
        },
    }, true, environ);
    try paths.expectUnchanged();
}

test "pkg sync: prefix violation names offender without retained entry" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const paths = try FailurePaths.init(&scratch);
    defer paths.deinit();
    const source = try syncSource(fixture.prefix_violation_manifest, paths.project, "");
    defer allocator.free(source);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = paths.cache }};
    try expectHostErrorEnviron(source, .{
        .name = "prefix violation",
        .source = source,
        .kind = "domain",
        .message_contains = "package `foo`, member `bar.ecl`",
        .data = &.{.{ .name = "package", .expected = .{ .string = "foo" } }},
    }, true, environ);
    try paths.expectUnchanged();
}

test "pkg sync: manifest identity mismatch retains no entry or lock" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const paths = try FailurePaths.init(&scratch);
    defer paths.deinit();
    const source = try syncSource(fixture.identity_mismatch_manifest, paths.project, "");
    defer allocator.free(source);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = paths.cache }};
    try expectHostErrorEnviron(source, .{
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
    }, true, environ);
    try paths.expectUnchanged();
}

test "pkg sync: non-success HTTP names package URL and status" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const paths = try FailurePaths.init(&scratch);
    defer paths.deinit();
    const source = try syncSource(fixture.non_success_manifest, paths.project, "");
    defer allocator.free(source);
    const url = try std.fmt.allocPrint(allocator, "https://127.0.0.1:{d}/status/503", .{fixture.port});
    defer allocator.free(url);
    const environ: []const machine.Environ.Entry = &.{.{ .name = "ECL_CACHE", .value = paths.cache }};
    try expectHostErrorEnviron(source, .{
        .name = "non-success response",
        .source = source,
        .kind = "io",
        .message_contains = "non-success HTTP status",
        .data = &.{
            .{ .name = "package", .expected = .{ .string = "down" } },
            .{ .name = "url", .expected = .{ .string = url } },
            .{ .name = "status", .expected = .{ .int = 503 } },
        },
    }, true, environ);
    try paths.expectUnchanged();
}

test "pkg sync: cache precedence selects ECL CACHE then XDG then HOME" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const ecl_cache = try scratch.pathFor("ecl-cache");
    defer allocator.free(ecl_cache);
    const xdg_cache = try scratch.pathFor("xdg-cache");
    defer allocator.free(xdg_cache);
    const home = try scratch.pathFor("home");
    defer allocator.free(home);

    try scratch.directory.dir.createDir(std.testing.io, "project-ecl", .default_dir);
    const project_ecl = try scratch.pathFor("project-ecl");
    defer allocator.free(project_ecl);
    const ecl_source = try syncSource(fixture.root_manifest, project_ecl, " pop");
    defer allocator.free(ecl_source);
    const ecl_environ: []const machine.Environ.Entry = &.{
        .{ .name = "ECL_CACHE", .value = ecl_cache },
        .{ .name = "XDG_CACHE_HOME", .value = xdg_cache },
        .{ .name = "HOME", .value = home },
    };
    try expectHostStackEnviron(ecl_source, "", true, ecl_environ);
    try expectStoreEntries(ecl_cache, &.{ "a-1.0.0-", "b-1.0.0-", "c-1.5.0-" });
    try expectPathAbsent(xdg_cache);
    try expectPathAbsent(home);

    try scratch.directory.dir.createDir(std.testing.io, "project-xdg", .default_dir);
    const project_xdg = try scratch.pathFor("project-xdg");
    defer allocator.free(project_xdg);
    const xdg_source = try syncSource(fixture.root_manifest, project_xdg, " pop");
    defer allocator.free(xdg_source);
    const xdg_environ: []const machine.Environ.Entry = &.{
        .{ .name = "ECL_CACHE", .value = "" },
        .{ .name = "XDG_CACHE_HOME", .value = xdg_cache },
        .{ .name = "HOME", .value = home },
    };
    try expectHostStackEnviron(xdg_source, "", true, xdg_environ);
    const xdg_store = try std.fmt.allocPrint(allocator, "{s}/ecl/pkg", .{xdg_cache});
    defer allocator.free(xdg_store);
    try expectStoreEntries(xdg_store, &.{ "a-1.0.0-", "b-1.0.0-", "c-1.5.0-" });
    try expectPathAbsent(home);

    try scratch.directory.dir.createDir(std.testing.io, "project-home", .default_dir);
    const project_home = try scratch.pathFor("project-home");
    defer allocator.free(project_home);
    const home_source = try syncSource(fixture.root_manifest, project_home, " pop");
    defer allocator.free(home_source);
    const home_environ: []const machine.Environ.Entry = &.{
        .{ .name = "ECL_CACHE", .value = "" },
        .{ .name = "XDG_CACHE_HOME", .value = "" },
        .{ .name = "HOME", .value = home },
    };
    try expectHostStackEnviron(home_source, "", true, home_environ);
    const home_store = try std.fmt.allocPrint(allocator, "{s}/.cache/ecl/pkg", .{home});
    defer allocator.free(home_store);
    try expectStoreEntries(home_store, &.{ "a-1.0.0-", "b-1.0.0-", "c-1.5.0-" });
}
