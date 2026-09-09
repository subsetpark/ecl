//! The internal builtin-backed `http` module over std.http.Client.
//!
//! Validation and refused-connection cases run everywhere. Server-backed cases
//! spawn the loopback fixture and skip — never silently pass — if the build did
//! not provide it.
const runtime_fixture = @import("runtime_fixture.zig");
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .tls_trust = .{ .ca_file = borrowed_path, .now = now },
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .tls_trust = .{ .ca_file = pkg_fixture.ca_file, .now = now },
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
    }), .default, .evaluate);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(heap.allocator(), &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
    }), .default, .evaluate);
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
            // Port 1 is privileged and unbound, so refusal fails immediately.
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
}

fn runHttp(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    switch (try runtime.runUnit("<http-bounds>", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.log.err("HTTP test failed: {s}", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
    switch (try runtime.runUnit("<clear>", "stack len (pop) times")) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
}

test "http: transfer limits reject complete and chunked bodies without partial responses" {
    var server = Fixture.start(39550) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.stop();
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{
        .http_limits = .{ .decoded_bytes = 5, .encoded_bytes = 5, .live_requests = 1 },
    }), .cooperative, .evaluate);
    defer runtime.deinit();
    const success = try std.fmt.allocPrint(allocator, "{{'target \"http://127.0.0.1:{d}/size/5\"}} http.get 'body at", .{server.port});
    defer allocator.free(success);
    const failure = try std.fmt.allocPrint(allocator, "[] ({{'target \"http://127.0.0.1:{d}/size/6\"}} http.get) @attempt 'err at 'kind at", .{server.port});
    defer allocator.free(failure);
    const chunked = try std.fmt.allocPrint(allocator, "{{'target \"http://127.0.0.1:{d}/chunked\"}} http.get 'body at", .{server.port});
    defer allocator.free(chunked);
    for (0..3) |_| {
        try runHttp(&runtime, success, "\"aaaaa\"");
        try runHttp(&runtime, failure, "'overflow");
        try runHttp(&runtime, chunked, "\"hello\"");
    }
}

test "http: preparation limits count UTF-8 bytes and repeated header occurrences" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{
        .http_limits = .{ .target_bytes = 3, .outbound_bytes = 2, .header_fields = 2 },
    }), .cooperative, .evaluate);
    defer runtime.deinit();
    // Invalid URLs at the byte limit reach transport and fail as io; a fourth
    // UTF-8 byte is rejected by the counting pass before an exchange starts.
    try runHttp(&runtime, "[] ({'target \"éa\"} http.get) @attempt 'err at 'kind at", "'io");
    try runHttp(&runtime, "[] ({'target \"éé\"} http.get) @attempt 'err at 'kind at", "'overflow");
    try runHttp(&runtime, "[] ({'target \"x\" 'body [1 2]} http.post) @attempt 'err at 'kind at", "'io");
    try runHttp(&runtime, "[] ({'target \"x\" 'body [1 2 3]} http.post) @attempt 'err at 'kind at", "'overflow");
    try runHttp(&runtime, "[] ({'target \"x\" 'headers {\"a\" (\"1\" \"2\")}} http.get) @attempt 'err at 'kind at", "'io");
    try runHttp(&runtime, "[] ({'target \"x\" 'headers {\"a\" (\"1\" \"2\" \"3\")}} http.get) @attempt 'err at 'kind at", "'overflow");
}

test "http: redirect bodies share the cumulative transfer budget" {
    var server = Fixture.start(39560) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.stop();
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{
        .http_limits = .{ .encoded_bytes = 15, .decoded_bytes = 15 },
    }), .cooperative, .evaluate);
    defer runtime.deinit();
    const source = try std.fmt.allocPrint(allocator, "[] ({{'target \"http://127.0.0.1:{d}/redirect-body\"}} http.get) @attempt 'err at 'kind at", .{server.port});
    defer allocator.free(source);
    try runHttp(&runtime, source, "'overflow");
}

const HttpRunner = struct {
    runtime: *session.Session,
    source: []const u8,
    expected: []const u8,
    failure: ?anyerror = null,
    fn run(self: *@This()) void {
        runHttp(self.runtime, self.source, self.expected) catch |err| {
            self.failure = err;
        };
    }
};

test "http: manual deadlines and task cancellation interrupt blocked response sockets" {
    for ([_]session.Config{ .cooperative, .{ .worker_pool = 1 } }) |config| {
        for ([_][]const u8{ "/stall-head", "/stall-body" }) |path| {
            inline for ([_]bool{ false, true }) |cancel| {
                var server = Fixture.start(39570) catch |err| switch (err) {
                    error.FileNotFound => return error.SkipZigTest,
                    else => return err,
                };
                defer server.stop();
                var inputs = try runtime_fixture.Fixture.init();
                defer inputs.deinit();
                var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{
                    .clock = .{ .monotonic = .manual },
                    .http_limits = .{ .live_requests = 1 },
                }), config, .evaluate);
                defer runtime.deinit();
                const template = if (cancel)
                    "[] ({{'target \"http://127.0.0.1:{d}{s}\"}} http.get) @spawn 'request set " ++
                        "1 clock.sleep request dup task.cancel task.await 'err at 'kind at"
                else
                    "[] ({{'target \"http://127.0.0.1:{d}{s}\"}} http.get) @attempt 'err at 'kind at";
                const source = try std.fmt.allocPrint(allocator, template, .{ server.port, path });
                defer allocator.free(source);
                var runner: HttpRunner = .{ .runtime = &runtime, .source = source, .expected = if (cancel) "'cancelled" else "'timeout" };
                const thread = try std.Thread.spawn(.{}, HttpRunner.run, .{&runner});
                // A wire-stage handshake proves cancellation reaches a real
                // blocked socket, rather than cancelling before startup.
                var buffer: [64]u8 = undefined;
                var reader = server.child.stdout.?.reader(std.testing.io, &buffer);
                const stage = try reader.interface.takeDelimiterExclusive('\n');
                try std.testing.expectEqualStrings("stage", stage);
                waitForHttpTimers(&runtime, if (cancel) 2 else 1);
                try runtime.advanceManualClock(if (cancel) 1 else 30_000);
                thread.join();
                if (runner.failure) |failure| return failure;
                const recovery = try std.fmt.allocPrint(allocator, "{{'target \"http://127.0.0.1:{d}/hello\"}} http.get 'status at", .{server.port});
                defer allocator.free(recovery);
                try runHttp(&runtime, recovery, "200");
            }
        }
    }
}

test "http: compressed and repeated response header limits are enforced before normalization" {
    var server = Fixture.start(39590) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.stop();
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    const Case = struct { path: []const u8, limits: @import("../http_service.zig").Limits, expected: []const u8 };
    const cases = [_]Case{
        .{ .path = "/gzip", .limits = .{ .encoded_bytes = 23, .decoded_bytes = 5 }, .expected = "'ok" },
        .{ .path = "/gzip", .limits = .{ .encoded_bytes = 22 }, .expected = "'overflow" },
        .{ .path = "/gzip", .limits = .{ .decoded_bytes = 4 }, .expected = "'overflow" },
        .{ .path = "/headers/2", .limits = .{ .header_fields = 2, .header_bytes = 12 }, .expected = "'ok" },
        .{ .path = "/headers/3", .limits = .{ .header_fields = 2 }, .expected = "'overflow" },
        .{ .path = "/headers/2", .limits = .{ .header_bytes = 11 }, .expected = "'overflow" },
        .{ .path = "/gzip", .limits = .{ .scratch_bytes = 1 }, .expected = "'overflow" },
    };
    for (cases) |case| {
        var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{ .http_limits = case.limits }), .cooperative, .evaluate);
        defer runtime.deinit();
        const source = try std.fmt.allocPrint(allocator, "[] ({{'target \"http://127.0.0.1:{d}{s}\"}} http.get) @attempt dup 'err dict.has? ( 'err at 'kind at ) (pop 'ok) if", .{ server.port, case.path });
        defer allocator.free(source);
        try runHttp(&runtime, source, case.expected);
    }
}

test "http: Session shutdown joins a request blocked in response headers" {
    var server = Fixture.start(39600) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.stop();
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{}), .{ .worker_pool = 1 }, .evaluate);
    defer runtime.deinit();
    const source = try std.fmt.allocPrint(allocator, "[] ({{'target \"http://127.0.0.1:{d}/stall-head\"}} http.get) @spawn pop", .{server.port});
    defer allocator.free(source);
    try runHttp(&runtime, source, "");
    var buffer: [64]u8 = undefined;
    var reader = server.child.stdout.?.reader(std.testing.io, &buffer);
    try std.testing.expectEqualStrings("stage", try reader.interface.takeDelimiterExclusive('\n'));
    // The Session's deferred destructor must cancel the socket and join its
    // scope-owned controller before the fixture or allocator is destroyed.
}

test "http: cancellation interrupts a completely full response transport" {
    const service = @import("../http_service.zig");
    const heap_api = @import("../heap.zig");
    const sched = @import("../scheduler.zig");
    const external = @import("../external.zig");
    const Ready = struct {
        event: std.Io.Event = .unset,
        pub fn retainExternalWake(_: *@This()) void {}
        pub fn releaseExternalWake(_: *@This()) void {}
        pub fn wakeExternal(self: *@This(), _: external.Wake) void {
            self.event.set(std.testing.io);
        }
    };
    var server = Fixture.start(39610) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.stop();
    var cleanup = heap_api.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const owner = try service.Owner.init(cleanup.capability(), std.testing.io, null, .{ .transport_bytes = 1 });
    defer owner.deinit();
    var scheduler = try sched.Scheduler.init(cleanup.capability(), .cooperative, .manual);
    var scope = sched.TaskScope.init(scheduler.worker());
    defer scheduler.deinit(&scope);
    const request = try owner.access().admit();
    defer while (!request.retire()) {
        std.Thread.yield() catch {};
    };
    var source = request.pipe().readSource();
    defer source.deinit();
    var ready: Ready = .{};
    var registration = switch (try source.register(external.wakeTarget(Ready, &ready))) {
        .ready => return error.UnexpectedReady,
        .registered => |registration| registration,
    };
    defer registration.cancel();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/size/131072", .{server.port});
    try request.start(.{ .url = url }, .GET, false, &scope);
    ready.event.waitUncancelable(std.testing.io);
    // One accepted byte fills this pipe. The producer cannot finish until the
    // evaluator reads or cancellation interrupts its transport wait.
    request.cancel();
}

test "http: a 303 redirect changes a bodyless method override to GET" {
    var server = Fixture.start(39620) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.stop();
    try expectStack(server.port, "{{'target \"http://127.0.0.1:{d}/redirect-see-other\" 'method \"DELETE\"}} http.get 'body at", "\"GET|0||\"");
}

/// A real cancellable I/O executor with controlled network stage boundaries.
/// The synthetic socket is used only by these overridden network callbacks.
const StageIo = struct {
    const Stage = enum { resolution, connection, tls, upload };
    threaded: std.Io.Threaded,
    table: std.Io.VTable,
    reached: std.Io.Event = .unset,
    blocked: std.Io.Event = .unset,
    stage: Stage,
    fn init(stage: Stage) StageIo {
        var threaded = std.Io.Threaded.init(allocator, .{});
        var table = threaded.io().vtable.*;
        table.netLookup = lookup;
        table.netConnectIp = connect;
        table.netRead = read;
        table.netWrite = write;
        table.netClose = close;
        return .{ .threaded = threaded, .table = table, .stage = stage };
    }
    fn io(self: *StageIo) std.Io {
        return .{ .userdata = self.threaded.io().userdata, .vtable = &self.table };
    }
    fn from(raw: ?*anyopaque) *StageIo {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(raw));
        return @fieldParentPtr("threaded", threaded);
    }
    fn block(self: *StageIo) error{Canceled}!void {
        self.reached.set(std.testing.io);
        try self.blocked.wait(self.threaded.io());
    }
    fn lookup(raw: ?*anyopaque, _: std.Io.net.HostName, queue: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
        const self = from(raw);
        defer queue.close(self.threaded.io());
        try self.block();
    }
    fn connect(raw: ?*anyopaque, address: *const std.Io.net.IpAddress, _: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
        const self = from(raw);
        if (self.stage == .connection) try self.block();
        return .{ .handle = 0, .address = address.* };
    }
    fn read(raw: ?*anyopaque, _: std.Io.net.Socket.Handle, _: [][]u8) std.Io.net.Stream.Reader.Error!usize {
        const self = from(raw);
        if (self.stage != .tls) return error.Unexpected;
        try self.block();
        return 0;
    }
    fn write(raw: ?*anyopaque, _: std.Io.net.Socket.Handle, header: []const u8, buffers: []const []const u8, splat: usize) std.Io.net.Stream.Writer.Error!usize {
        const self = from(raw);
        var count = header.len;
        var has_payload = std.mem.indexOf(u8, header, "PING") != null;
        for (buffers, 0..) |buffer, index| {
            count += buffer.len * (if (index + 1 == buffers.len) splat else 1);
            has_payload = has_payload or std.mem.indexOf(u8, buffer, "PING") != null;
        }
        if (self.stage == .upload and has_payload) try self.block();
        return count;
    }
    fn close(_: ?*anyopaque, _: []const std.Io.net.Socket.Handle) void {}
};

test "http: cancellation reaches resolution connection TLS and upload I/O tasks" {
    for ([_]StageIo.Stage{ .resolution, .connection, .tls, .upload }) |stage| {
        var controlled = StageIo.init(stage);
        defer controlled.threaded.deinit();
        var inputs = try runtime_fixture.Fixture.init();
        defer inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, inputs.inputs(.{
            .io = controlled.io(),
            .clock = .{ .monotonic = .manual },
            .tls_trust = .{ .ca_file = pkg_fixture.ca_file, .now = valid_cert_time },
        }), .{ .worker_pool = 1 }, .evaluate);
        defer runtime.deinit();
        const target = switch (stage) {
            .resolution => "http://controlled.invalid/",
            .tls => "https://127.0.0.1/",
            .connection, .upload => "http://127.0.0.1/",
        };
        const body = if (stage == .upload) "'method \"POST\" 'body [80 73 78 71]" else "";
        const source = try std.fmt.allocPrint(allocator, "[] ({{'target \"{s}\" {s}}} http.get) @spawn 'request set " ++
            "1 clock.sleep request dup task.cancel task.await 'err at 'kind at", .{ target, body });
        defer allocator.free(source);
        var runner: HttpRunner = .{ .runtime = &runtime, .source = source, .expected = "'cancelled" };
        const thread = try std.Thread.spawn(.{}, HttpRunner.run, .{&runner});
        controlled.reached.waitUncancelable(std.testing.io);
        waitForHttpTimers(&runtime, 2);
        try runtime.advanceManualClock(1);
        thread.join();
        if (runner.failure) |failure| return failure;
    }
}

fn waitForHttpTimers(runtime: *session.Session, count: usize) void {
    for (0..1_000_000) |_| {
        if (runtime.schedulerTimerEntryCount() == count) return;
        std.Thread.yield() catch @panic("HTTP timer setup yield failed");
    }
    @panic("HTTP wait timers did not register");
}
