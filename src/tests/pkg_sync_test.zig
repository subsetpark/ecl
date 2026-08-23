//! Public package-store and synchronization behavior over the hermetic HTTPS fixture.
//!
//! Patch 2 registers the complete proof surface before production symbols
//! exist. Each skipped case is activated by the patch that implements the
//! behavior named in its title.
const std = @import("std");
const pkg_fixture = @import("pkg_fixture_options");
const archive_fixtures = @import("archive_fixture_options");
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

fn fixtureInstallSource(destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" ");
    try appendString(&source.writer, destination);
    try source.writer.writeAll(" pkg.store.install");
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

const HttpsFixture = struct {
    child: std.process.Child,
    port: u16,

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
        return .{
            .child = child,
            .port = std.math.cast(u16, port_value.integer) orelse return error.FixtureHandshakeFailed,
        };
    }

    fn stop(self: *HttpsFixture) void {
        self.child.kill(std.testing.io);
    }
};

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

test "pkg sync: resolves transitive MVS and writes canonical lock" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: deleting lock reproduces identical bytes without refetching present entries" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: hash mismatch names package and hashes without store or lock" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: prefix violation names offender without retained entry" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: manifest identity mismatch retains no entry or lock" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: non-success HTTP names package URL and status" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}

test "pkg sync: cache precedence selects ECL CACHE then XDG then HOME" {
    // PENDING: Patch 5.
    return error.SkipZigTest;
}
