//! The internal builtin-backed `http` module over std.http.Client.
//!
//! Validation and refused-connection cases run everywhere. Server-backed cases
//! spawn the loopback fixture and skip — never silently pass — if the build did
//! not provide it.
const std = @import("std");
const http_fixture = @import("http_fixture_options");
const pkg_fixture = @import("pkg_fixture_options");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;

test "http: HTTPS get-bytes preserves arbitrary response octets" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();
    try expectTlsStack(
        fixture.port,
        "{{'target \"https://127.0.0.1:{d}/redirect-bytes\"}} http.get-bytes 'body at " ++
            "{{'target \"https://127.0.0.1:{d}/gzip-bytes\"}} http.get-bytes 'body at",
        "[0 1 127 128 255 195 40] [0 1 127 128 255 195 40]",
        valid_cert_time,
    );
}

test "http: custom TLS trust uses fixed verification time" {
    var fixture = try HttpsFixture.start();
    defer fixture.stop();

    // The fixture certificate is not yet valid at this instant. A failure
    // here proves Client used the supplied time rather than the wall clock.
    const source = try std.fmt.allocPrint(
        allocator,
        "{{'target \"https://127.0.0.1:{d}/bytes\"}} http.get-bytes",
        .{fixture.port},
    );
    defer allocator.free(source);
    try expectTlsIoError(source, invalid_cert_time);
}

const valid_cert_time = std.Io.Timestamp.fromNanoseconds(
    @as(i96, 1_788_220_800) * std.time.ns_per_s,
);
const invalid_cert_time = std.Io.Timestamp.fromNanoseconds(
    @as(i96, 1_756_684_800) * std.time.ns_per_s,
);

/// Python-backed HTTPS fixture used by both the exact-byte and package
/// synchronization cases. Its JSON announcement is data from the process,
/// not an ambient resource, and the child is synchronously reaped by kill.
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
        const port_value = announcement.value.object.get("port") orelse
            return error.FixtureHandshakeFailed;
        if (port_value != .integer) return error.FixtureHandshakeFailed;
        return .{
            .child = child,
            .port = std.math.cast(u16, port_value.integer) orelse
                return error.FixtureHandshakeFailed,
        };
    }

    fn stop(self: *HttpsFixture) void {
        self.child.kill(std.testing.io);
    }
};

fn expectTlsStack(
    port: u16,
    comptime template: []const u8,
    expected: []const u8,
    now: std.Io.Timestamp,
) !void {
    const source = try std.fmt.allocPrint(allocator, template, .{ port, port });
    defer allocator.free(source);
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();
    const borrowed_path = try allocator.dupe(u8, pkg_fixture.ca_file);
    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .tls_trust = .{ .ca_file = borrowed_path, .now = now },
    });
    allocator.free(borrowed_path);
    defer runtime.deinit();
    switch (try runtime.runUnit("<http-tls-test>", source)) {
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

fn expectTlsIoError(source: []const u8, now: std.Io.Timestamp) !void {
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
        .tls_trust = .{ .ca_file = pkg_fixture.ca_file, .now = now },
    });
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<http-tls-test>", source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, .{
        .name = "certificate rejected at the fixed time",
        .source = source,
        .kind = "io",
        .word = "http.get-bytes",
        .message_contains = "cannot reach",
    });
}

/// A running fixture server plus the port it actually bound.
const Fixture = struct {
    child: std.process.Child,
    port: u16,

    /// The starting port is only a hint; the server walks upward until one
    /// binds and prints the result, so concurrent runs do not collide.
    fn start(hint: u16) !Fixture {
        var hint_text: [8]u8 = undefined;
        const argument = try std.fmt.bufPrint(&hint_text, "{d}", .{hint});
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ http_fixture.server_exe, argument },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(std.testing.io);
        var buffer: [64]u8 = undefined;
        var reader = child.stdout.?.reader(std.testing.io, &buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (!std.mem.startsWith(u8, line, "port ")) return error.FixtureHandshakeFailed;
        return .{ .child = child, .port = try std.fmt.parseInt(u16, line[5..], 10) };
    }

    fn stop(self: *Fixture) void {
        self.child.kill(std.testing.io);
    }
};

fn expectStack(port: u16, comptime template: []const u8, expected: []const u8) !void {
    const source = try std.fmt.allocPrint(allocator, template, .{port});
    defer allocator.free(source);
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
    });
    defer runtime.deinit();
    switch (try runtime.runUnit("<http-test>", source)) {
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

test "http: get returns a response dict from the fixture server" {
    var fixture = Fixture.start(39411) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer fixture.stop();
    // The whole documented response contract in one shot: an int status, a
    // dict of response headers, and the body as a string.
    try expectStack(
        fixture.port,
        "\"GET\" \"http://127.0.0.1:{d}/hello\" http.request.new http.send " ++
            "dup 'status at swap dup 'body at swap 'headers at \"x-fixture\" at",
        "200 \"hello, world\\n\" \"hello\"",
    );
    // A non-2xx status returns as an ordinary value without raising an error.
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/nope\"}} http.get 'status at",
        "404",
    );
}

test "http: repeated response headers keep the last value" {
    var fixture = Fixture.start(39475) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer fixture.stop();
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/duplicate\"}} http.get " ++
            "'headers at \"x-repeated\" at",
        "\"last\"",
    );
}

test "http: post sends headers and body" {
    var fixture = Fixture.start(39511) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer fixture.stop();
    // The fixture echoes one caller header and the request body, so a single
    // assertion proves both crossed the wire.
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/echo\" 'headers {{\"x-probe\" (\"probed\")}} " ++
            "'body [112 97 121 108 111 97 100]}} http.post " ++
            "dup 'status at swap dup 'body at swap 'headers at \"x-fixture\" at",
        "200 \"POST|1|probed|payload\" \"echo\"",
    );
}

test "http: request fields override get defaults and preserve repeated headers and body bytes" {
    var fixture = Fixture.start(39547) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer fixture.stop();
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/echo\" 'method \"PATCH\" " ++
            "'headers {{\"x-probe\" (\"one\" \"two\")}} 'body [112 97 121 108 111 97 100]}} " ++
            "http.get 'body at",
        "\"PATCH|2|one,two|payload\"",
    );
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/redirect-echo\" 'method \"PATCH\" 'body [112]}} " ++
            "http.get 'status at",
        "307",
    );
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/redirect-echo\" 'method \"PATCH\" 'body [112]}} " ++
            "http.get-bytes 'status at",
        "307",
    );
    try expectStack(
        fixture.port,
        "{{'target \"http://127.0.0.1:{d}/echo-bytes\" 'method \"POST\" 'body [0 1 127 128 255]}} " ++
            "http.get-bytes 'body at",
        "[0 1 127 128 255]",
    );
    try expectStack(
        fixture.port,
        "\"PATCH\" \"http://127.0.0.1:{d}/echo\" http.request.new " ++
            "\"x-probe\" \"sent\" http.request.with-header " ++
            "[115 101 110 100] http.request.with-body http.send 'body at",
        "\"PATCH|1|sent|send\"",
    );
}

/// Runs one case against a host-connected session, which the network cases
/// need and `kernel_test_support` deliberately does not provide.
fn expectHostError(source: []const u8, expected: support.ErrorCase) !void {
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
    });
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<http-test>", source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

test "http: refused connection is an io error" {
    for ([_]support.ErrorCase{
        .{
            // Port 1 is privileged and unbound, so this fails fast rather
            // than waiting on a deadline the v1 client does not have.
            .name = "a refused connection",
            .source = "{'target \"http://127.0.0.1:1/nope\"} http.get",
            .kind = "io",
            .word = "http.get",
            .message_contains = "cannot reach",
            .data = &.{.{ .name = "path", .expected = .{ .string = "http://127.0.0.1:1/nope" } }},
        },
        .{
            .name = "a refused connection on post",
            .source = "{'target \"http://127.0.0.1:1/nope\"} http.post",
            .kind = "io",
            .word = "http.post",
            .message_contains = "cannot reach",
        },
        .{
            .name = "an unparseable url",
            .source = "{'target \"not a url\"} http.get",
            .kind = "io",
            .word = "http.get",
            .message_contains = "InvalidUrl",
        },
        .{
            .name = "a non-request value",
            .source = "5 http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "request dict",
        },
        .{
            .name = "a missing target",
            .source = "{} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "'target URL",
        },
        .{
            .name = "send requires a method",
            .source = "{'target \"http://127.0.0.1:1/x\"} http.send",
            .kind = "type",
            .word = "http.send",
            .message_contains = "string 'method",
        },
        .{
            .name = "a non-string target",
            .source = "{'target 5} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "string request 'target",
        },
        .{
            .name = "non-dict headers",
            .source = "{'target \"http://x\" 'headers 5} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "'headers dict",
        },
        .{
            .name = "a non-list body",
            .source = "{'target \"http://x\" 'body \"body\"} http.post",
            .kind = "type",
            .word = "http.post",
            .message_contains = "'body byte list",
        },
        .{
            .name = "an invalid body byte",
            .source = "{'target \"http://x\" 'body [300]} http.post",
            .kind = "type",
            .word = "http.post",
            .message_contains = "integers from 0 through 255",
        },
        .{
            .name = "a body on a method that does not admit one",
            .source = "{'target \"http://x\" 'body [1]} http.get",
            .kind = "domain",
            .word = "http.get",
            .message_contains = "does not admit a body",
        },
        .{
            .name = "non-string header names",
            .source = "{'target \"http://127.0.0.1:1/x\" 'headers {5 (\"v\")}} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "header names",
        },
        .{
            .name = "non-list header values",
            .source = "{'target \"http://127.0.0.1:1/x\" 'headers {\"x\" \"v\"}} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "lists of strings",
        },
        .{
            .name = "uppercase header names",
            .source = "{'target \"http://127.0.0.1:1/x\" 'headers {\"X\" (\"v\")}} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "lowercased",
        },
        .{
            .name = "an unsupported method override",
            .source = "{'target \"http://127.0.0.1:1/x\" 'method \"BREW\"} http.get",
            .kind = "domain",
            .word = "http.get",
            .message_contains = "unsupported HTTP request method",
        },
        .{
            .name = "an unknown request field",
            .source = "{'target \"http://127.0.0.1:1/x\" 'timeout 1} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "recognized fields",
        },
    }) |case| expectHostError(case.source, case) catch |err| {
        std.log.err("http case `{s}` failed", .{case.name});
        return err;
    };
    // A session with no host Io has no network at all, phrased exactly as the
    // filesystem gate is.
    try support.expectErrors(&.{.{
        .name = "absent host IO",
        .source = "{'target \"http://127.0.0.1:1/x\"} http.get",
        .kind = "io",
        .word = "http.get",
        .message = "network access is unavailable",
    }});
}
