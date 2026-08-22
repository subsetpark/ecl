//! Public behavior of the builtin archive module.
//!
//! Fixtures are exact hexadecimal program inputs. Tests pass only source text
//! to Sessions, so the traceless SessionHeap remains the appropriate allocator.
const std = @import("std");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");
const fixtures = @import("archive_fixture_options");

const allocator = std.testing.allocator;

const Fixture = enum {
    empty,
    valid,
    pax,
    gnu_long_name,
    absolute_path,
    parent_path,
    symlink,
    hardlink,
    char_device,
    block_device,
    fifo,
    duplicate,
    oversized,
    malformed_tar,
    malformed_pax,
    malformed,

    fn encoded(comptime self: Fixture) []const u8 {
        return switch (self) {
            .empty => fixtures.empty,
            .valid => fixtures.valid,
            .pax => fixtures.pax,
            .gnu_long_name => fixtures.gnu_long_name,
            .absolute_path => fixtures.absolute_path,
            .parent_path => fixtures.parent_path,
            .symlink => fixtures.symlink,
            .hardlink => fixtures.hardlink,
            .char_device => fixtures.char_device,
            .block_device => fixtures.block_device,
            .fifo => fixtures.fifo,
            .duplicate => fixtures.duplicate,
            .oversized => fixtures.oversized,
            .malformed_tar => fixtures.malformed_tar,
            .malformed_pax => fixtures.malformed_pax,
            .malformed => fixtures.malformed,
        };
    }
};

fn decodeHex(comptime fixture: Fixture) ![]u8 {
    const encoded = fixture.encoded();
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var high: ?u8 = null;
    for (encoded) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        const nibble = std.fmt.charToDigit(byte, 16) catch return error.InvalidFixture;
        if (high) |first| {
            try bytes.append(allocator, first << 4 | nibble);
            high = null;
        } else high = nibble;
    }
    if (high != null) return error.InvalidFixture;
    return bytes.toOwnedSlice(allocator);
}

fn appendString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '\\' or byte == '"') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

fn unpackSource(bytes: []const u8, destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeByte('[');
    for (bytes, 0..) |byte, index| {
        if (index != 0) try source.writer.writeByte(' ');
        try source.writer.print("{d}", .{byte});
    }
    try source.writer.writeAll("] ");
    try appendString(&source.writer, destination);
    try source.writer.writeAll(" archive.unpack-tgz");
    return allocator.dupe(u8, source.written());
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

    fn destination(self: *Scratch, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ self.path, std.fs.path.sep, name });
    }

    fn expectAbsent(self: *Scratch, name: []const u8) !void {
        self.directory.dir.access(std.testing.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return error.ExpectedAbsentPath;
    }

    fn expectEntryCount(self: *Scratch, expected: usize) !void {
        var directory = try std.Io.Dir.openDirAbsolute(std.testing.io, self.path, .{ .iterate = true });
        defer directory.close(std.testing.io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (try iterator.next(std.testing.io)) |_| count += 1;
        try std.testing.expectEqual(expected, count);
    }
};

fn expectIoStack(source: []const u8, expected: []const u8) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(
        heap.allocator(),
        &.{},
        .{ .io = std.testing.io, .output = &output.writer, .diagnostics = &diagnostics.writer },
        .cooperative,
    );
    defer runtime.deinit();
    switch (try runtime.runUnit("<archive-test>", source)) {
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

fn expectIoError(source: []const u8, expected: support.ErrorCase) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(
        heap.allocator(),
        &.{},
        .{ .io = std.testing.io, .output = &output.writer, .diagnostics = &diagnostics.writer },
        .cooperative,
    );
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<archive-test>", source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

test "archive: sha256 matches known-answer vectors and preserves high bytes" {
    try support.expectStacks(&.{
        .{
            .name = "empty vector",
            .source = "[] archive.sha256",
            .expected = "\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"",
        },
        .{
            .name = "ASCII vector",
            .source = "[97 98 99] archive.sha256",
            .expected = "\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"",
        },
        .{
            .name = "multi-block vector",
            .source = "[97 98 99 100 98 99 100 101 99 100 101 102 100 101 102 103 " ++
                "101 102 103 104 102 103 104 105 103 104 105 106 104 105 106 107 " ++
                "105 106 107 108 106 107 108 109 107 108 109 110 108 109 110 111 " ++
                "109 110 111 112 110 111 112 113] archive.sha256",
            .expected = "\"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1\"",
        },
        .{
            .name = "unsigned high bytes",
            .source = "[0 127 128 255] archive.sha256",
            .expected = "\"89273d2f70b93285bb7ddb4bcee86a5347ca7159352e3cbdd20c23e9d1e507d3\"",
        },
    });
}

test "archive: byte inputs reject wrong containers and invalid items" {
    try support.expectErrors(&.{
        .{ .name = "non-list byte input", .source = "42 archive.sha256", .kind = "type", .word = "archive.sha256" },
        .{
            .name = "negative byte",
            .source = "[0 -1] archive.sha256",
            .kind = "domain",
            .word = "archive.sha256",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
        .{
            .name = "byte above 255",
            .source = "[255 256] archive.sha256",
            .kind = "domain",
            .word = "archive.sha256",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
        .{
            .name = "non-integer list item",
            .source = "[0 1.5] archive.sha256",
            .kind = "domain",
            .word = "archive.sha256",
            .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
        },
    });
}

test "archive: unpack-tgz atomically extracts regular files and returns paths" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const bytes = try decodeHex(.valid);
    defer allocator.free(bytes);
    const destination = try scratch.destination("package");
    defer allocator.free(destination);
    const source = try unpackSource(bytes, destination);
    defer allocator.free(source);

    try expectIoStack(source, "(\"lib/main.ecl\" \"README.md\")");
    const main = try scratch.directory.dir.readFileAlloc(std.testing.io, "package/lib/main.ecl", allocator, .unlimited);
    defer allocator.free(main);
    try std.testing.expectEqualStrings("42\n", main);
    const readme = try scratch.directory.dir.readFileAlloc(std.testing.io, "package/README.md", allocator, .unlimited);
    defer allocator.free(readme);
    try std.testing.expectEqualStrings("fixture\n", readme);

    const empty_bytes = try decodeHex(.empty);
    defer allocator.free(empty_bytes);
    const empty_destination = try scratch.destination("empty");
    defer allocator.free(empty_destination);
    const empty_source = try unpackSource(empty_bytes, empty_destination);
    defer allocator.free(empty_source);
    try expectIoStack(empty_source, "()");
    var empty_directory = try scratch.directory.dir.openDir(std.testing.io, "empty", .{ .iterate = true });
    defer empty_directory.close(std.testing.io);
    var empty_iterator = empty_directory.iterate();
    try std.testing.expect((try empty_iterator.next(std.testing.io)) == null);
    try scratch.expectEntryCount(2);

    inline for (.{ Fixture.pax, .gnu_long_name }, 0..) |fixture, index| {
        const extension_bytes = try decodeHex(fixture);
        defer allocator.free(extension_bytes);
        const name = try std.fmt.allocPrint(allocator, "extension-{d}", .{index});
        defer allocator.free(name);
        const extension_destination = try scratch.destination(name);
        defer allocator.free(extension_destination);
        const extension_source = try unpackSource(extension_bytes, extension_destination);
        defer allocator.free(extension_source);
        const expected = try std.fmt.allocPrint(allocator, "(\"{s}\")", .{fixtures.long_path});
        defer allocator.free(expected);
        try expectIoStack(extension_source, expected);
        const extracted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, fixtures.long_path });
        defer allocator.free(extracted);
        const content = try scratch.directory.dir.readFileAlloc(std.testing.io, extracted, allocator, .unlimited);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("long\n", content);
    }
    try scratch.expectEntryCount(4);
}

test "archive: unpack-tgz rejects traversal malformed and over-limit archives without publication" {
    inline for (.{
        Fixture.absolute_path,
        .parent_path,
        .duplicate,
        .oversized,
        .malformed_tar,
        .malformed_pax,
        .malformed,
    }, 0..) |fixture, index| {
        var scratch = try Scratch.init();
        defer scratch.deinit();
        const bytes = try decodeHex(fixture);
        defer allocator.free(bytes);
        const name = try std.fmt.allocPrint(allocator, "rejected-{d}", .{index});
        defer allocator.free(name);
        const destination = try scratch.destination(name);
        defer allocator.free(destination);
        const source = try unpackSource(bytes, destination);
        defer allocator.free(source);
        try expectIoError(source, .{ .name = @tagName(fixture), .source = source, .kind = "domain", .word = "archive.unpack-tgz" });
        try scratch.expectAbsent(name);
        try scratch.expectEntryCount(0);
    }
}

test "archive: unpack-tgz rejects links and special nodes without publication" {
    inline for (.{ Fixture.symlink, .hardlink, .char_device, .block_device, .fifo }, 0..) |fixture, index| {
        var scratch = try Scratch.init();
        defer scratch.deinit();
        const bytes = try decodeHex(fixture);
        defer allocator.free(bytes);
        const name = try std.fmt.allocPrint(allocator, "rejected-{d}", .{index});
        defer allocator.free(name);
        const destination = try scratch.destination(name);
        defer allocator.free(destination);
        const source = try unpackSource(bytes, destination);
        defer allocator.free(source);
        try expectIoError(source, .{ .name = @tagName(fixture), .source = source, .kind = "domain", .word = "archive.unpack-tgz" });
        try scratch.expectAbsent(name);
        try scratch.expectEntryCount(0);
    }
}

const ConcurrentResult = struct {
    source: []const u8,
    successes: *std.atomic.Value(u32),
    io_failures: *std.atomic.Value(u32),
    unexpected: *std.atomic.Value(bool),
};

fn concurrentUnpack(result: *ConcurrentResult) void {
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
        return;
    };
    const outcome = runtime.runUnit("<archive-race>", result.source) catch {
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
                .name = "concurrent loser",
                .source = result.source,
                .kind = "io",
                .word = "archive.unpack-tgz",
            }) catch result.unexpected.store(true, .release);
            runtime.release(failure);
            _ = result.io_failures.fetchAdd(1, .monotonic);
        },
    }
    runtime.deinit();
    test_heap.retire(&heap);
}

test "archive: unpack-tgz preserves existing destinations and has one concurrent winner" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const bytes = try decodeHex(.valid);
    defer allocator.free(bytes);

    try scratch.directory.dir.createDir(std.testing.io, "existing", .default_dir);
    try scratch.directory.dir.writeFile(std.testing.io, .{ .sub_path = "existing/sentinel", .data = "keep" });
    const existing = try scratch.destination("existing");
    defer allocator.free(existing);
    const existing_source = try unpackSource(bytes, existing);
    defer allocator.free(existing_source);
    try expectIoError(existing_source, .{
        .name = "existing destination",
        .source = existing_source,
        .kind = "io",
        .word = "archive.unpack-tgz",
        .message_contains = "already exists",
    });
    const sentinel = try scratch.directory.dir.readFileAlloc(std.testing.io, "existing/sentinel", allocator, .unlimited);
    defer allocator.free(sentinel);
    try std.testing.expectEqualStrings("keep", sentinel);

    const destination = try scratch.destination("winner");
    defer allocator.free(destination);
    const source = try unpackSource(bytes, destination);
    defer allocator.free(source);
    var successes: std.atomic.Value(u32) = .init(0);
    var io_failures: std.atomic.Value(u32) = .init(0);
    var unexpected: std.atomic.Value(bool) = .init(false);
    var result = ConcurrentResult{ .source = source, .successes = &successes, .io_failures = &io_failures, .unexpected = &unexpected };
    const first = try std.Thread.spawn(.{}, concurrentUnpack, .{&result});
    const second = try std.Thread.spawn(.{}, concurrentUnpack, .{&result});
    first.join();
    second.join();
    try std.testing.expect(!unexpected.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), successes.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), io_failures.load(.acquire));
    try scratch.directory.dir.access(std.testing.io, "winner/lib/main.ecl", .{});
    try scratch.expectEntryCount(2);
}

test "archive: cancellation and absent host IO never publish a destination" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const bytes = try decodeHex(.valid);
    defer allocator.free(bytes);

    const cancelled_destination = try scratch.destination("cancelled");
    defer allocator.free(cancelled_destination);
    const cancelled_source = try unpackSource(bytes, cancelled_destination);
    defer allocator.free(cancelled_source);
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
    switch (try runtime.runUnit("<archive-warm>", "[] archive.sha256 pop")) {
        .ok => {},
        .incomplete, .err => return error.UnexpectedWarmupResult,
    }
    runtime.requestCancellation();
    const failure = switch (try runtime.runUnit("<archive-cancel>", cancelled_source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedCancellation,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, .{ .name = "cancelled extraction", .source = cancelled_source, .kind = "cancelled" });
    try scratch.expectAbsent("cancelled");

    const unavailable_destination = try scratch.destination("unavailable");
    defer allocator.free(unavailable_destination);
    const unavailable_source = try unpackSource(bytes, unavailable_destination);
    defer allocator.free(unavailable_source);
    try support.expectError(.{
        .name = "host IO absent",
        .source = unavailable_source,
        .kind = "io",
        .word = "archive.unpack-tgz",
        .message = "archive extraction is unavailable",
    });
    try scratch.expectAbsent("unavailable");
    try scratch.expectEntryCount(0);
}

test "archive: allocation and filesystem failures never publish a destination" {
    // Allocation failures for both drivers are exhaustively replayed by
    // oom_test; this behavioral case exercises an actual staging failure.
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const bytes = try decodeHex(.valid);
    defer allocator.free(bytes);
    const destination = try scratch.destination("missing-parent/package");
    defer allocator.free(destination);
    const source = try unpackSource(bytes, destination);
    defer allocator.free(source);
    try expectIoError(source, .{ .name = "missing destination parent", .source = source, .kind = "io", .word = "archive.unpack-tgz" });
    try scratch.expectAbsent("missing-parent");
    try scratch.expectEntryCount(0);
}

test "archive: every export is documented and cold-loads through the builtin manifest" {
    try support.expectStack("'archive.sha256 doc len 0 > 'archive.unpack-tgz doc len 0 >", "1 1");
    try support.expectStack("[97] archive.sha256 len", "64");
}
