//! Public Session coverage for the `http.server.@serve` server module.
//!
//! Every case runs source text through a Session whose Host grants exact
//! loopback binds on `127.0.0.1` port 0, and observes the other end of the
//! wire through a Zig-side `Peer` thread: it connects to the bound port,
//! writes its request bytes verbatim, and reads until EOF into a 4 KiB buffer,
//! so the oracle is the exact byte sequence the server put on the socket.
//! Peers synchronize by bytes on the socket, never by sleeping. Every Session
//! runs under a manual scheduler clock, so the read-deadline case advances
//! the clock itself once the reader's timer is registered instead of waiting
//! on host time.
//!
//! `@serve` blocks until cancelled, and `requestCancellation` cannot wake a
//! parked root unit, so each serving program runs on a `Runner` thread while
//! the test thread drives peers and finally sends the request whose handler
//! ends the server: `/stop` cancels the serving task, `/close-listener` closes
//! the listener. The Session is touched by one thread at a time. Sessions run
//! only source strings, so the traceless session heap is the right allocator
//! (see `test_heap.zig`). No wall-clock sleeps, no ambient network, no fixture
//! process.
const std = @import("std");
const net_port = @import("../net_port.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;
const IpAddress = std.Io.net.IpAddress;
const posix = std.posix;
const Policy = net_port.NetPolicy;

const loopback_ephemeral: Policy = .{ .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} } };

/// One Session plus the writers it borrows. Open it in place and never move
/// it afterwards: the Session holds pointers into this struct.
const Runtime = struct {
    heap: test_heap.SessionHeap = .init,
    output_buffer: [256]u8 = @splat(0),
    diagnostics_buffer: [256]u8 = @splat(0),
    output: ?std.Io.Writer.Discarding = null,
    diagnostics: ?std.Io.Writer.Discarding = null,
    session: session.Session = .consumed,

    fn open(self: *Runtime, policy: Policy, config: session.Config) !void {
        self.output = std.Io.Writer.Discarding.init(&self.output_buffer);
        self.diagnostics = std.Io.Writer.Discarding.init(&self.diagnostics_buffer);
        self.session = try session.Session.initWithHostConfig(self.heap.allocator(), &.{}, .{
            .io = io,
            .output = &self.output.?.writer,
            .diagnostics = &self.diagnostics.?.writer,
            .net_policy = policy,
            .clock = .{ .monotonic = .manual },
        }, config);
    }

    fn close(self: *Runtime) void {
        self.session.deinit();
        test_heap.retire(&self.heap);
    }

    fn run(self: *Runtime, program: []const u8) !void {
        switch (try self.session.runUnit("<http-server-test>", program)) {
            .ok => {},
            .incomplete => return error.UnexpectedIncomplete,
            .err => |failure| {
                defer self.session.release(failure);
                var rendered = try self.session.renderValue(failure);
                defer rendered.deinit();
                std.log.err("unexpected http server error: {s}", .{rendered.bytes()});
                return error.UnexpectedLanguageError;
            },
        }
    }

    fn expectDisplay(self: *Runtime, expected: []const u8) !void {
        var display = try self.session.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }

    /// Bind an ephemeral listener under `name` and return its port.
    fn listen(self: *Runtime, name: []const u8) !u16 {
        const program = try std.fmt.allocPrint(
            allocator,
            "{{'address \"127.0.0.1\" 'port 0}} net.listen '{s} set {s} net.local-address 'port at",
            .{ name, name },
        );
        defer allocator.free(program);
        try self.run(program);
        var display = try self.session.stackDisplay();
        defer display.deinit();
        const port = try std.fmt.parseInt(u16, std.mem.trim(u8, display.bytes(), " \n"), 10);
        try std.testing.expect(port != 0);
        try self.run("pop");
        return port;
    }
};

/// Runs one program on its own thread so the test thread can drive peers
/// while the serving unit is parked.
const Runner = struct {
    runtime: *Runtime,
    program: []const u8,
    thread: ?std.Thread = null,
    failure: ?anyerror = null,
    /// Set once the program has returned, so a teardown path can tell a
    /// server that is still serving from one that already ended.
    done: std.atomic.Value(bool) = .init(false),

    fn start(self: *Runner) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Runner) void {
        self.runtime.run(self.program) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn join(self: *Runner) !void {
        const thread = self.thread orelse return;
        self.thread = null;
        thread.join();
        if (self.failure) |failure| return failure;
    }
};

const Script = union(enum) {
    /// Connect, write the bytes, then read until EOF.
    send: []const u8,
    /// Connect and close at once, sending nothing.
    connect_then_close,
};

const Observed = struct {
    received: [4096]u8 = @splat(0),
    received_len: usize = 0,
    eof: bool = false,
    local_port: u16 = 0,
    failure: ?anyerror = null,

    fn bytes(self: *const Observed) []const u8 {
        return self.received[0..self.received_len];
    }

    /// The status line without its CR LF, or everything when there is none.
    fn statusLine(self: *const Observed) []const u8 {
        const text = self.bytes();
        const end = std.mem.indexOf(u8, text, "\r\n") orelse return text;
        return text[0..end];
    }

    /// Everything after the head terminator, or the empty string.
    fn body(self: *const Observed) []const u8 {
        const text = self.bytes();
        const start = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return "";
        return text[start + 4 ..];
    }

    fn hasHeaderLine(self: *const Observed, line: []const u8) bool {
        const text = self.bytes();
        const head_end = std.mem.indexOf(u8, text, "\r\n\r\n") orelse text.len;
        var lines = std.mem.splitSequence(u8, text[0..head_end], "\r\n");
        while (lines.next()) |candidate| {
            if (std.mem.eql(u8, candidate, line)) return true;
        }
        return false;
    }
};

/// One scripted client on its own thread. `flushed` is set once the request
/// bytes have left the socket, so a test can order a later peer after it.
const Peer = struct {
    thread: ?std.Thread = null,
    port: u16,
    script: Script,
    flushed: std.Io.Event = .unset,
    observed: Observed = .{},

    fn start(port: u16, script: Script) !*Peer {
        const peer = try allocator.create(Peer);
        peer.* = .{ .port = port, .script = script };
        peer.thread = try std.Thread.spawn(.{}, run, .{peer});
        return peer;
    }

    fn waitFlushed(self: *Peer) void {
        self.flushed.wait(io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    fn join(self: *Peer) Observed {
        self.thread.?.join();
        const observed = self.observed;
        allocator.destroy(self);
        return observed;
    }

    fn run(self: *Peer) void {
        self.observed = self.execute() catch |err| .{ .failure = err };
        self.flushed.set(io);
    }

    fn execute(self: *Peer) !Observed {
        var observed: Observed = .{};
        const address: IpAddress = .{ .ip4 = .loopback(self.port) };
        const stream = try IpAddress.connect(&address, io, .{ .mode = .stream });
        var closed = false;
        defer if (!closed) stream.close(io);
        // SAFETY: getsockname fills `storage` before it is read; on failure the
        // local port simply stays zero.
        var storage: std.Io.Threaded.PosixAddress = undefined;
        var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
        if (posix.system.getsockname(stream.socket.handle, &storage.any, &length) == 0)
            observed.local_port = std.Io.Threaded.addressFromPosix(&storage).getPort();
        var read_buffer: [512]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &.{});
        switch (self.script) {
            .send => |payload| {
                try writer.interface.writeAll(payload);
                try writer.interface.flush();
                self.flushed.set(io);
            },
            .connect_then_close => {
                stream.close(io);
                closed = true;
                observed.eof = true;
                self.flushed.set(io);
                return observed;
            },
        }
        while (true) {
            const count = reader.interface.readSliceShort(observed.received[observed.received_len..]) catch |err| {
                observed.failure = err;
                return observed;
            };
            if (count == 0) {
                observed.eof = true;
                return observed;
            }
            observed.received_len += count;
            if (observed.received_len == observed.received.len) return observed;
        }
    }
};

fn expectResponse(observed: Observed, expected: []const u8) !void {
    if (observed.failure) |failure| return failure;
    try std.testing.expect(observed.eof);
    try std.testing.expectEqualStrings(expected, observed.bytes());
}

fn expectStatus(observed: Observed, status_line: []const u8) !void {
    if (observed.failure) |failure| return failure;
    try std.testing.expect(observed.eof);
    try std.testing.expectEqualStrings(status_line, observed.statusLine());
    try std.testing.expect(observed.hasHeaderLine("Connection: close"));
}

fn expectSilentClose(observed: Observed) !void {
    if (observed.failure) |failure| return failure;
    try std.testing.expect(observed.eof);
    try std.testing.expectEqualStrings("", observed.bytes());
}

/// Send one request and wait for its complete response.
fn exchange(port: u16, request: []const u8) !Observed {
    const peer = try Peer.start(port, .{ .send = request });
    return peer.join();
}

/// Wait until the scheduler holds exactly `count` timer entries. Progress
/// depends only on the serving unit registering its deadline, never on host
/// time; the bound turns a deadline that is never registered into a diagnosed
/// failure instead of a hang.
fn awaitTimerEntries(runtime: *Runtime, count: usize) void {
    const max_polls: usize = 20_000;
    var polls: usize = 0;
    while (runtime.session.schedulerTimerEntryCount() != count) : (polls += 1) {
        if (polls == max_polls) std.debug.panic(
            "timer entries never reached {d}; observed {d}",
            .{ count, runtime.session.schedulerTimerEntryCount() },
        );
        std.Thread.yield() catch @panic("test yield failed");
        const pause: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(1), .clock = .awake };
        pause.sleep(io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
}

const ok_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
const ok_row = "\"/ok\" (pop {'status 200 'headers {} 'body \"ok\"}) ";
const not_found_default = "(pop http.server.not-found)";
const close_listener_request = "GET /close-listener HTTP/1.1\r\n\r\n";

/// A serving unit under `srv`: `prelude` runs first (a gate task, say), the
/// handler is a `case` over the path whose rows end with two that stop the
/// server, and the root parks in `srv await` leaving the failure kind and
/// reason on the stack.
const Server = struct {
    runtime: *Runtime,
    port: u16,
    program: []u8,
    runner: Runner,

    /// Heap-allocated so the runner thread's pointer to `runner` stays valid;
    /// `finish` or `abandon` frees it.
    fn start(runtime: *Runtime, port: u16, prelude: []const u8, config: []const u8, rows: []const u8, default_row: []const u8) !*Server {
        const program = try std.fmt.allocPrint(
            allocator,
            "{s} [] (l {s} (dup 'path at [{s}" ++
                "\"/close-listener\" (pop l net.close 204 http.server.empty) " ++
                "\"/stop\" (pop srv cancel 204 http.server.empty) " ++
                "{s}] case) http.server.@serve) @spawn 'srv set " ++
                "srv await 'err at dup 'kind at swap 'data {{}} at-or 'reason 'none at-or",
            .{ prelude, config, rows, default_row },
        );
        errdefer allocator.free(program);
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);
        server.* = .{ .runtime = runtime, .port = port, .program = program, .runner = .{ .runtime = runtime, .program = program } };
        try server.runner.start();
        return server;
    }

    fn destroy(self: *Server) void {
        allocator.free(self.program);
        allocator.destroy(self);
    }

    /// Close the listener through a request and expect the serving unit to
    /// have failed `'io 'closed`.
    fn finish(self: *Server) !void {
        defer self.destroy();
        _ = try exchange(self.port, close_listener_request);
        try self.runner.join();
        try self.runtime.expectDisplay("'io 'closed");
    }

    /// Best-effort teardown after a failed assertion so the runner thread
    /// never outlives the Session.
    fn abandon(self: *Server) void {
        defer self.destroy();
        // A server that already ended has nobody accepting, so a request to
        // it would never see EOF; only a live one needs closing.
        if (!self.runner.done.load(.acquire)) _ = exchange(self.port, close_listener_request) catch |err| {
            std.log.err("abandoned server could not be closed: {t}", .{err});
        };
        self.runner.join() catch |err| {
            std.log.err("abandoned server did not stop cleanly: {t}", .{err});
        };
    }

    /// Join a server that ended on its own (its handler cancelled it).
    fn joinEnded(self: *Server) !void {
        defer self.destroy();
        try self.runner.join();
    }
};

test "http server: a request is materialized with method target path query lowercased list headers body and peer" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}",
        // Body: the request without its peer; header x-peer: the peer text.
        "\"/a/b\" (dup 'peer at swap 'peer del str {'status 200 'headers {} 'body \"\"} 'body rolldown put " ++
            "swap wrap \"x-peer\" swap pair dict.from-flat 'headers swap put) ", not_found_default);
    errdefer server.abandon();
    const observed = try exchange(port, "GET /a/b?x=1&y=2 HTTP/1.1\r\nHost: h\r\nX-Multi: one\r\nX-Multi: two\r\nContent-Length: 3\r\n\r\nabc");
    try expectStatus(observed, "HTTP/1.1 200 OK");
    try std.testing.expectEqualStrings(
        "{'method \"GET\" 'target \"/a/b?x=1&y=2\" 'path \"/a/b\" 'query \"x=1&y=2\" " ++
            "'headers {\"host\" (\"h\") \"x-multi\" (\"one\" \"two\") \"content-length\" (\"3\")} 'body [97 98 99]}",
        observed.body(),
    );
    var peer_line: [64]u8 = undefined;
    const expected_peer = try std.fmt.bufPrint(&peer_line, "x-peer: 127.0.0.1:{d}", .{observed.local_port});
    try std.testing.expect(observed.hasHeaderLine(expected_peer));
    try server.finish();
}

test "http server: string and byte-list bodies are written with content-length and connection close" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", "\"/s\" (pop {'status 200 'headers {} 'body \"ok\"}) " ++
        "\"/b\" (pop {'status 200 'headers {} 'body [111 107]}) ", not_found_default);
    errdefer server.abandon();
    try expectResponse(try exchange(port, "GET /s HTTP/1.1\r\n\r\n"), ok_response);
    try expectResponse(try exchange(port, "GET /b HTTP/1.1\r\n\r\n"), ok_response);
    try server.finish();
}

test "http server: repeated response headers are written once per value" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", "\"/c\" (pop {'status 200 'headers {\"Set-Cookie\" (\"a=1\" \"b=2\")} 'body \"\"}) ", not_found_default);
    errdefer server.abandon();
    try expectResponse(
        try exchange(port, "GET /c HTTP/1.1\r\n\r\n"),
        "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    try server.finish();
}

test "http server: a content-length body is delivered as an exact byte list including binary octets" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", "\"/\" ('body at str {'status 200 'headers {} 'body \"\"} 'body rolldown put) ", not_found_default);
    errdefer server.abandon();
    const observed = try exchange(port, "POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\n" ++ [_]u8{ 0, 255, 10, 13 });
    try expectStatus(observed, "HTTP/1.1 200 OK");
    try std.testing.expectEqualStrings("[0 255 10 13]", observed.body());
    try server.finish();
}

test "http server: malformed request lines and headers are answered 400 and closed" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    // The default row answers 200 too, so a 400 proves the handler never ran.
    const server = try Server.start(&runtime, port, "", "{}", ok_row, "(pop {'status 200 'headers {} 'body \"ok\"})");
    errdefer server.abandon();
    try expectStatus(try exchange(port, "GARBAGE\r\n\r\n"), "HTTP/1.1 400 Bad Request");
    try expectStatus(try exchange(port, "GET / HTTP/1.1\r\nNoColon\r\n\r\n"), "HTTP/1.1 400 Bad Request");
    try expectStatus(try exchange(port, "GET /  HTTP/1.1\r\n\r\n"), "HTTP/1.1 400 Bad Request");
    try expectStatus(try exchange(port, "GET / HTTP/1.1\r\n folded: x\r\n\r\n"), "HTTP/1.1 400 Bad Request");
    try expectStatus(try exchange(port, "GET / HTTP/1.1\r\nContent-Length: x\r\n\r\n"), "HTTP/1.1 400 Bad Request");
    try expectStatus(try exchange(port, "GET / HTTP/1.1\r\nX: \xff\r\n\r\n"), "HTTP/1.1 400 Bad Request");
    try expectResponse(try exchange(port, "GET /ok HTTP/1.1\r\n\r\n"), ok_response);
    try server.finish();
}

test "http server: chunked requests are answered 411 and unsupported versions 505 while HTTP/1.0 is answered and closed" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", ok_row, not_found_default);
    errdefer server.abandon();
    try expectStatus(try exchange(port, "POST /ok HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), "HTTP/1.1 411 Length Required");
    try expectStatus(try exchange(port, "GET /ok HTTP/2.0\r\n\r\n"), "HTTP/1.1 505 HTTP Version Not Supported");
    try expectResponse(try exchange(port, "GET /ok HTTP/1.0\r\n\r\n"), ok_response);
    try server.finish();
}

test "http server: header and body limits are answered 431 and 413" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{'max-header-bytes 64 'max-body-bytes 4}", ok_row, not_found_default);
    errdefer server.abandon();
    const long_head = "GET /ok HTTP/1.1\r\nX: " ++ ("a" ** 100) ++ "\r\n\r\n";
    try expectStatus(try exchange(port, long_head), "HTTP/1.1 431 Request Header Fields Too Large");
    try expectStatus(try exchange(port, "POST /ok HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"), "HTTP/1.1 413 Content Too Large");
    try expectResponse(try exchange(port, "POST /ok HTTP/1.1\r\nContent-Length: 4\r\n\r\nfour"), ok_response);
    try server.finish();
}

test "http server: the read deadline answers 408 and closes" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{'read-timeout-ms 20}", ok_row, not_found_default);
    errdefer server.abandon();
    // The peer never finishes its head. Once the connection child has
    // registered the reader's deadline, the clock moves past it.
    const stalled = try Peer.start(port, .{ .send = "GET /ok HTTP/1.1\r\nHost:" });
    stalled.waitFlushed();
    awaitTimerEntries(&runtime, 1);
    try runtime.session.advanceManualClock(20);
    try expectStatus(stalled.join(), "HTTP/1.1 408 Request Timeout");
    try expectResponse(try exchange(port, "GET /ok HTTP/1.1\r\n\r\n"), ok_response);
    try server.finish();
}

const gate_prelude = "[] (l2 net.accept) @spawn 'gate set";
const gate_rows =
    "\"/slow\" (pop gate await pop {'status 200 'headers {} 'body \"slow\"}) " ++
    "\"/probe\" (pop gate 0 await-for 'ok dict.has? (\"terminal\") (\"active\") if {'status 200 'headers {} 'body \"\"} 'body rolldown put) ";

test "http server: max-in-flight stops accepting until a request completes" {
    // One acceptor: the probe waits in the backlog behind the slow request and
    // runs only after the gate released it, so it finds the gate terminal.
    {
        var runtime: Runtime = .{};
        try runtime.open(loopback_ephemeral, .cooperative);
        defer runtime.close();
        const port = try runtime.listen("l");
        const gate_port = try runtime.listen("l2");
        const server = try Server.start(&runtime, port, gate_prelude, "{'max-in-flight 1}", gate_rows, not_found_default);
        errdefer server.abandon();
        const slow = try Peer.start(port, .{ .send = "GET /slow HTTP/1.1\r\n\r\n" });
        slow.waitFlushed();
        const probe = try Peer.start(port, .{ .send = "GET /probe HTTP/1.1\r\n\r\n" });
        probe.waitFlushed();
        const release = try Peer.start(gate_port, .connect_then_close);
        try expectSilentClose(release.join());
        const slow_seen = slow.join();
        try expectStatus(slow_seen, "HTTP/1.1 200 OK");
        try std.testing.expectEqualStrings("slow", slow_seen.body());
        const probe_seen = probe.join();
        try expectStatus(probe_seen, "HTTP/1.1 200 OK");
        try std.testing.expectEqualStrings("terminal", probe_seen.body());
        try server.finish();
    }
    // Two acceptors: the probe is answered while the slow request still
    // holds the other one and the gate is still active.
    {
        var runtime: Runtime = .{};
        try runtime.open(loopback_ephemeral, .cooperative);
        defer runtime.close();
        const port = try runtime.listen("l");
        const gate_port = try runtime.listen("l2");
        const server = try Server.start(&runtime, port, gate_prelude, "{'max-in-flight 2}", gate_rows, not_found_default);
        errdefer server.abandon();
        const slow = try Peer.start(port, .{ .send = "GET /slow HTTP/1.1\r\n\r\n" });
        slow.waitFlushed();
        const probe_seen = try exchange(port, "GET /probe HTTP/1.1\r\n\r\n");
        try expectStatus(probe_seen, "HTTP/1.1 200 OK");
        try std.testing.expectEqualStrings("active", probe_seen.body());
        const release = try Peer.start(gate_port, .connect_then_close);
        try expectSilentClose(release.join());
        const slow_seen = slow.join();
        try expectStatus(slow_seen, "HTTP/1.1 200 OK");
        try std.testing.expectEqualStrings("slow", slow_seen.body());
        try server.finish();
    }
}

test "http server: handler failures extra results malformed responses and reserved headers are answered 500 while the server stays live" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    // The hook itself fails on every report; the server must contain that too.
    const server = try Server.start(&runtime, port, "", "{'on-failure (pop {'kind 'hook-failed} raise)}", "\"/raise\" (pop {'kind 'boom} raise) " ++
        "\"/extra\" (pop 1 2) " ++
        "\"/malformed\" (pop 7) " ++
        "\"/reserved\" (pop {'status 200 'headers {\"content-length\" \"1\"} 'body \"x\"}) " ++
        ok_row, not_found_default);
    errdefer server.abandon();
    for ([_][]const u8{ "/raise", "/extra", "/malformed", "/reserved" }) |path| {
        const request = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\n\r\n", .{path});
        defer allocator.free(request);
        try expectStatus(try exchange(port, request), "HTTP/1.1 500 Internal Server Error");
    }
    try expectResponse(try exchange(port, "GET /ok HTTP/1.1\r\n\r\n"), ok_response);
    try server.finish();
}

test "http server: cancellation cancels in-flight requests and leaves the caller's listener open" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    _ = try runtime.listen("l2");
    const server = try Server.start(&runtime, port, gate_prelude, "{}", gate_rows, not_found_default);
    errdefer server.abandon();
    const slow = try Peer.start(port, .{ .send = "GET /slow HTTP/1.1\r\n\r\n" });
    slow.waitFlushed();
    // Nobody releases the gate: the slow request is in flight when the stop
    // handler cancels the serving task, so both peers see EOF and no status.
    try expectSilentClose(try exchange(port, "GET /stop HTTP/1.1\r\n\r\n"));
    try expectSilentClose(slow.join());
    try server.joinEnded();
    try runtime.expectDisplay("'cancelled 'none");
    var expected: [16]u8 = undefined;
    try runtime.run("pop pop l net.local-address 'port at");
    try runtime.expectDisplay(try std.fmt.bufPrint(&expected, "{d}", .{port}));
}

test "http server: closing the listener fails the serving unit with io closed" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", ok_row, not_found_default);
    errdefer server.abandon();
    try expectResponse(try exchange(port, "GET /ok HTTP/1.1\r\n\r\n"), ok_response);
    try server.finish();
}

test "http server: a peer that connects and closes without sending is closed silently" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", ok_row, not_found_default);
    errdefer server.abandon();
    const silent = try Peer.start(port, .connect_then_close);
    try expectSilentClose(silent.join());
    try expectResponse(try exchange(port, "GET /ok HTTP/1.1\r\n\r\n"), ok_response);
    try server.finish();
}

test "http server: configuration and listener arguments are validated before serving" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .cooperative);
    defer runtime.close();
    const port = try runtime.listen("l");
    try runtime.run(
        "[] (5 {} (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l 5 (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l {'bogus 1} (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l {'max-in-flight 0} (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l {'read-timeout-ms -1} (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l {'max-in-flight \"8\"} (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l {'on-failure 5} (1) http.server.@serve) @attempt 'err at 'kind at " ++
            "[] (l {} 7 http.server.@serve) @attempt 'err at 'kind at",
    );
    try runtime.expectDisplay("'type 'type 'domain 'domain 'domain 'type 'type 'type");
    // A connection is a port too, but not a listener: the acceptor's accept
    // fails 'type and the serving unit fails with it.
    const silent = try Peer.start(port, .connect_then_close);
    try expectSilentClose(silent.join());
    try runtime.run("pop pop pop pop pop pop pop pop l net.accept 'c set [] (c {} (1) http.server.@serve) @attempt 'err at 'kind at");
    try runtime.expectDisplay("'type");
}

test "http server: concurrent requests under the worker pool are each answered exactly once" {
    var runtime: Runtime = .{};
    try runtime.open(loopback_ephemeral, .{ .worker_pool = 8 });
    defer runtime.close();
    const port = try runtime.listen("l");
    const server = try Server.start(&runtime, port, "", "{}", "", "('path at {'status 200 'headers {} 'body \"\"} 'body rolldown put)");
    errdefer server.abandon();
    var peers: [8]*Peer = undefined;
    var requests: [8][]u8 = undefined;
    var started: usize = 0;
    defer for (requests[0..started]) |request| allocator.free(request);
    for (&peers, 0..) |*slot, index| {
        requests[index] = try std.fmt.allocPrint(allocator, "GET /n/{d} HTTP/1.1\r\n\r\n", .{index});
        started += 1;
        slot.* = try Peer.start(port, .{ .send = requests[index] });
    }
    for (peers, 0..) |peer, index| {
        const observed = peer.join();
        try expectStatus(observed, "HTTP/1.1 200 OK");
        var expected: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/n/{d}", .{index}), observed.body());
    }
    try server.finish();
}

test "http server: words cold-load through the embedded manifest and are documented" {
    try support.expectStack(
        "'http.server.@serve doc len 0 > 'http.server.text doc len 0 > 'http.server.route doc len 0 > 'http.server.query doc len 0 >",
        "1 1 1 1",
    );
    try support.expectStack("'http.server ('@serve 'text 'route) import 1", "1");
}
