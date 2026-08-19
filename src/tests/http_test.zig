//! The internal builtin-backed `http` module over std.http.Client.
//!
//! Validation and refused-connection cases run everywhere. Server-backed cases
//! spawn the loopback fixture and skip — never silently pass — if the build did
//! not provide it.
const std = @import("std");
const http_fixture = @import("http_fixture_options");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;

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
        "\"http://127.0.0.1:{d}/hello\" {{}} http.get " ++
            "dup 'status at swap dup 'body at swap 'headers at \"x-fixture\" at",
        "200 \"hello, world\\n\" \"hello\"",
    );
    // A non-2xx status is an ordinary value, not an error.
    try expectStack(
        fixture.port,
        "\"http://127.0.0.1:{d}/nope\" {{}} http.get 'status at",
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
        "\"http://127.0.0.1:{d}/duplicate\" {{}} http.get " ++
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
        "\"http://127.0.0.1:{d}/echo\" {{\"x-probe\" \"probed\"}} \"payload\" http.post " ++
            "dup 'status at swap dup 'body at swap 'headers at \"x-fixture\" at",
        "200 \"probed|payload\" \"echo\"",
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
            .source = "\"http://127.0.0.1:1/nope\" {} http.get",
            .kind = "io",
            .word = "http.get",
            .message_contains = "cannot reach",
            .data = &.{.{ .name = "path", .expected = .{ .string = "http://127.0.0.1:1/nope" } }},
        },
        .{
            .name = "a refused connection on post",
            .source = "\"http://127.0.0.1:1/nope\" {} \"body\" http.post",
            .kind = "io",
            .word = "http.post",
            .message_contains = "cannot reach",
        },
        .{
            .name = "an unparseable url",
            .source = "\"not a url\" {} http.get",
            .kind = "io",
            .word = "http.get",
            .message_contains = "InvalidUrl",
        },
        .{
            .name = "a non-string url",
            .source = "5 {} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "string url",
        },
        .{
            .name = "non-dict headers",
            .source = "\"http://x\" 5 http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "dict of request headers",
        },
        .{
            .name = "a non-string body",
            .source = "\"http://x\" {} 5 http.post",
            .kind = "type",
            .word = "http.post",
            .message_contains = "string request body",
        },
        .{
            .name = "non-string header names",
            .source = "\"http://127.0.0.1:1/x\" {5 \"v\"} http.get",
            .kind = "type",
            .word = "http.get",
            .message_contains = "header names",
        },
    }) |case| expectHostError(case.source, case) catch |err| {
        std.log.err("http case `{s}` failed", .{case.name});
        return err;
    };
    // A session with no host Io has no network at all, phrased exactly as the
    // filesystem gate is.
    try support.expectErrors(&.{.{
        .name = "absent host IO",
        .source = "\"http://127.0.0.1:1/x\" {} http.get",
        .kind = "io",
        .word = "http.get",
        .message = "network access is unavailable",
    }});
}

test "http: every exported word carries documentation" {
    for ([_][]const u8{ "get", "post" }) |name| {
        const source = try std.fmt.allocPrint(
            allocator,
            "'http use 'http.{s} doc len 0 >",
            .{name},
        );
        defer allocator.free(source);
        try support.expectStack(source, "1");
    }
}
