//! Public Session coverage for the `net` listener capability.
//!
//! Every case runs source text through a Session whose Host either omits the
//! network grant or names exact loopback binds, and observes effects through
//! the public runtime plus a Zig-side loopback probe: a connect that succeeds
//! while the socket is bound and is refused once it closes. Sessions run only
//! source strings, so the traceless session heap is the right allocator (see
//! `test_heap.zig`). No wall-clock sleeps, no ambient network; the one fixture
//! is the process executable, used only to produce a foreign port value.
const std = @import("std");
const fixture = @import("process_fixture_options");
const net_port = @import("../net_port.zig");
const process = @import("../process_port.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;
const IpAddress = std.Io.net.IpAddress;
const Policy = net_port.NetPolicy;

const loopback_ephemeral: Policy = .{ .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} } };
const unrestricted: Policy = .{ .binds = .unrestricted };
const listen_ephemeral = "{'address \"127.0.0.1\" 'port 0} net.listen";

const Grants = struct {
    net: ?Policy = null,
    process: ?process.ProcessPolicy = null,
};

/// One Session plus the writers it borrows. Open it in place and never move
/// it afterwards: the Session holds pointers into this struct.
const Runtime = struct {
    heap: test_heap.SessionHeap = .init,
    output_buffer: [256]u8 = @splat(0),
    diagnostics_buffer: [256]u8 = @splat(0),
    output: ?std.Io.Writer.Discarding = null,
    diagnostics: ?std.Io.Writer.Discarding = null,
    session: session.Session = .consumed,

    fn open(self: *Runtime, grants: Grants, config: session.Config) !void {
        self.output = std.Io.Writer.Discarding.init(&self.output_buffer);
        self.diagnostics = std.Io.Writer.Discarding.init(&self.diagnostics_buffer);
        self.session = try session.Session.initWithHostConfig(self.heap.allocator(), &.{}, .{
            .io = io,
            .output = &self.output.?.writer,
            .diagnostics = &self.diagnostics.?.writer,
            .net_policy = grants.net,
            .process_policy = grants.process,
        }, config);
    }

    fn close(self: *Runtime) void {
        self.session.deinit();
        test_heap.retire(&self.heap);
    }

    fn run(self: *Runtime, program: []const u8) !void {
        switch (try self.session.runUnit("<net-test>", program)) {
            .ok => {},
            .incomplete => return error.UnexpectedIncomplete,
            .err => |failure| {
                defer self.session.release(failure);
                var rendered = try self.session.renderValue(failure);
                defer rendered.deinit();
                std.log.err("unexpected net error: {s}", .{rendered.bytes()});
                return error.UnexpectedLanguageError;
            },
        }
    }

    fn runError(self: *Runtime, program: []const u8, expected: support.ErrorCase) !void {
        const failure = switch (try self.session.runUnit("<net-test>", program)) {
            .ok, .incomplete => return error.ExpectedLanguageError,
            .err => |item| item,
        };
        defer self.session.release(failure);
        try support.expectLanguageError(failure, expected);
    }

    fn expectDisplay(self: *Runtime, expected: []const u8) !void {
        var display = try self.session.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }

    /// Every `'port N` in the current stack display, in order.
    fn ports(self: *Runtime, storage: []u16) ![]u16 {
        var display = try self.session.stackDisplay();
        defer display.deinit();
        return portsIn(display.bytes(), storage);
    }
};

fn portsIn(text: []const u8, storage: []u16) ![]u16 {
    var count: usize = 0;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "'port ")) |start| {
        rest = rest[start + "'port ".len ..];
        // The type symbol `'port` also matches; only a digit run is a port.
        const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
        if (end == 0) continue;
        if (count == storage.len) return error.TooManyPorts;
        storage[count] = try std.fmt.parseInt(u16, rest[0..end], 10);
        count += 1;
    }
    return storage[0..count];
}

fn expectStack(grants: Grants, program: []const u8, expected: []const u8) !void {
    var runtime: Runtime = .{};
    try runtime.open(grants, .cooperative);
    defer runtime.close();
    try runtime.run(program);
    try runtime.expectDisplay(expected);
}

fn expectError(grants: Grants, program: []const u8, expected: support.ErrorCase) !void {
    var runtime: Runtime = .{};
    try runtime.open(grants, .cooperative);
    defer runtime.close();
    try runtime.runError(program, expected);
}

const Probe = enum { accepted, refused };

/// Connect to the loopback port from outside the Session. A bound listener
/// completes the handshake into its backlog; a closed one refuses. Loopback
/// answers synchronously either way. No deadline is set because Zig 0.16's
/// threaded backend panics on `ConnectOptions.timeout` (`TODO implement
/// netConnectIpPosix with timeout`); revisit when std implements it.
fn probe(port: u16) !Probe {
    const address: IpAddress = .{ .ip4 = .loopback(port) };
    const stream = IpAddress.connect(&address, io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => return .refused,
        else => return err,
    };
    stream.close(io);
    return .accepted;
}

fn reason(name: []const u8) support.DataField {
    return .{ .name = "reason", .expected = .{ .symbol = name } };
}

fn addressData(address: []const u8, port: i64) [2]support.DataField {
    return .{
        .{ .name = "address", .expected = .{ .string = address } },
        .{ .name = "port", .expected = .{ .int = port } },
    };
}

fn processFixturePath() ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, fixture.process_exe, allocator);
}

test "net: a Session without a listen policy denies listen before the host is reached" {
    const data = addressData("127.0.0.1", 0);
    try expectError(.{}, listen_ephemeral, .{
        .name = "no policy",
        .source = listen_ephemeral,
        .kind = "domain",
        .word = "net.listen",
        .message_contains = "unavailable",
        .data = &.{ reason("unavailable"), data[0], data[1] },
    });
}

test "net: policy validation is a distinct Session construction failure" {
    const invalid = [_]Policy{
        .{ .binds = .{ .exact = &.{.{ .address = "localhost", .port = 0 }} } },
        .{ .binds = .{ .exact = &.{
            .{ .address = "127.0.0.1", .port = 0 },
            .{ .address = "::ffff:127.0.0.1", .port = 0 },
        } } },
        .{ .binds = .unrestricted, .limits = .{ .max_live_listeners = 0 } },
    };
    for (invalid) |policy| {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.Discarding.init(&output_buffer);
        try std.testing.expectError(error.InvalidHostPolicy, session.Session.initWithHost(heap.allocator(), &.{}, .{
            .io = io,
            .output = &output.writer,
            .diagnostics = &output.writer,
            .net_policy = policy,
        }));
    }
    // The copied policy outlives the borrowed inputs it was built from.
    const address = try allocator.dupe(u8, "127.0.0.1");
    const binds = try allocator.alloc(net_port.Bind, 1);
    binds[0] = .{ .address = address, .port = 0 };
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = .{ .binds = .{ .exact = binds } } }, .cooperative);
    defer runtime.close();
    allocator.free(binds);
    allocator.free(address);
    try runtime.run(listen_ephemeral ++ " net.local-address");
    var storage: [1]u16 = undefined;
    const ports = try runtime.ports(&storage);
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expect(ports[0] != 0);
}

test "net: grants are exact and port zero permits only ephemeral binds" {
    const grants: Grants = .{ .net = loopback_ephemeral };
    const fixed = "{'address \"127.0.0.1\" 'port 8080} net.listen";
    const fixed_data = addressData("127.0.0.1", 8080);
    try expectError(grants, fixed, .{
        .name = "wrong port",
        .source = fixed,
        .kind = "domain",
        .word = "net.listen",
        .data = &.{ reason("denied"), fixed_data[0], fixed_data[1] },
    });
    const other_family = "{'address \"::1\" 'port 0} net.listen";
    try expectError(grants, other_family, .{
        .name = "other family",
        .source = other_family,
        .kind = "domain",
        .word = "net.listen",
        .data = &.{reason("denied")},
    });
    // An IPv4-mapped literal normalizes onto the IPv4 grant and binds IPv4.
    var runtime: Runtime = .{};
    try runtime.open(grants, .cooperative);
    defer runtime.close();
    try runtime.run("{'address \"::ffff:127.0.0.1\" 'port 0} net.listen net.local-address 'address at");
    try runtime.expectDisplay("\"127.0.0.1\"");
}

test "net: listen binds an ephemeral loopback port and local-address reports it" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    try runtime.run(listen_ephemeral ++ " dup type swap net.local-address");
    var display = try runtime.session.stackDisplay();
    defer display.deinit();
    try std.testing.expect(std.mem.startsWith(u8, display.bytes(), "'port {'address \"127.0.0.1\" 'port "));
    var storage: [1]u16 = undefined;
    const ports = try portsIn(display.bytes(), &storage);
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expect(ports[0] != 0);
    try std.testing.expectEqual(Probe.accepted, try probe(ports[0]));
}

test "net: a bind conflict is an io failure carrying the address, port, and reason" {
    const held: IpAddress = .{ .ip4 = .loopback(0) };
    var server = try IpAddress.listen(&held, io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    const program = try std.fmt.allocPrint(allocator, "{{'address \"127.0.0.1\" 'port {d}}} net.listen", .{port});
    defer allocator.free(program);
    const data = addressData("127.0.0.1", port);
    try expectError(.{ .net = .{ .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = port }} } } }, program, .{
        .name = "in use",
        .source = program,
        .kind = "io",
        .word = "net.listen",
        .data = &.{ reason("in-use"), data[0], data[1] },
    });
}

test "net: a port left in TIME_WAIT by a closed connection can be bound again at once" {
    // A server that closes a connection first leaves its port in TIME_WAIT;
    // without address reuse the next listen on that port fails for up to a
    // minute, which is how a restarted program finds its own port "in use".
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = unrestricted }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("l net.accept 'c set c [111 107] net.write c net.close l net.close");
    try expectPeerBytes(peer.join(), "ok");
    const program = try std.fmt.allocPrint(
        allocator,
        "{{'address \"127.0.0.1\" 'port {d}}} net.listen net.local-address 'port at",
        .{port},
    );
    defer allocator.free(program);
    try runtime.run(program);
    var expected: [8]u8 = undefined;
    try runtime.expectDisplay(try std.fmt.bufPrint(&expected, "{d}", .{port}));
}

test "net: config validation rejects malformed dictionaries before authority checks" {
    // No policy: a malformed config must fail on its own terms, never as
    // `'unavailable`.
    const cases = [_]struct { source: []const u8, kind: []const u8 }{
        .{ .source = "1 net.listen", .kind = "type" },
        .{ .source = "{} net.listen", .kind = "domain" },
        .{ .source = "{'address 1 'port 0} net.listen", .kind = "type" },
        .{ .source = "{'address \"127.0.0.1\" 'port \"0\"} net.listen", .kind = "type" },
        .{ .source = "{'address \"127.0.0.1\" 'port 65536} net.listen", .kind = "domain" },
        .{ .source = "{'address \"localhost\" 'port 0} net.listen", .kind = "domain" },
        .{ .source = "{'address \"127.0.0.1\" 'port 0 'extra 1} net.listen", .kind = "domain" },
        .{ .source = "{'address \"127.0.0.1\" 'extra 1} net.listen", .kind = "domain" },
    };
    for (cases) |case| {
        try expectError(.{}, case.source, .{
            .name = case.source,
            .source = case.source,
            .kind = case.kind,
            .word = "net.listen",
        });
    }
    try expectError(.{}, "{'address \"localhost\" 'port 0} net.listen", .{
        .name = "not a literal",
        .source = "{'address \"localhost\" 'port 0} net.listen",
        .kind = "domain",
        .word = "net.listen",
        .data = &.{reason("invalid")},
    });
}

test "net: listeners are opaque port values distinct from process ports" {
    const fixture_path = try processFixturePath();
    defer allocator.free(fixture_path);
    const grants: Grants = .{
        .net = loopback_ephemeral,
        .process = .{ .executables = .{ .exact = &.{fixture_path} } },
    };
    try expectStack(grants, listen_ephemeral ++ " dup type swap dup match?", "'port 1");
    try expectError(grants, listen_ephemeral ++ " proc.wait", .{
        .name = "proc word on a listener",
        .source = listen_ephemeral,
        .kind = "type",
        .word = "proc.wait",
    });
    const spawn = try std.fmt.allocPrint(
        allocator,
        "'proc ('spawn) import {{'executable \"{s}\" 'args (\"exit\" \"0\")}} spawn",
        .{fixture_path},
    );
    defer allocator.free(spawn);
    for ([_][]const u8{ "net.local-address", "net.close" }) |word| {
        const program = try std.fmt.allocPrint(allocator, "{s} {s}", .{ spawn, word });
        defer allocator.free(program);
        try expectError(grants, program, .{
            .name = word,
            .source = program,
            .kind = "type",
            .word = word,
        });
    }
}

test "net: scope closure releases the socket even while a listener value is retained" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = unrestricted }, .cooperative);
    defer runtime.close();
    try runtime.run("[] (" ++ listen_ephemeral ++ " dup net.local-address) @spawn await 'ok at");
    var storage: [1]u16 = undefined;
    const ports = try runtime.ports(&storage);
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    const port = ports[0];
    try std.testing.expect(port != 0);
    try std.testing.expectEqual(Probe.refused, try probe(port));
    const data = addressData("127.0.0.1", port);
    try runtime.runError("first net.local-address", .{
        .name = "closed listener",
        .source = "first net.local-address",
        .kind = "io",
        .word = "net.local-address",
        .data = &.{ reason("closed"), data[0], data[1] },
    });
    const rebind = try std.fmt.allocPrint(allocator, "{{'address \"127.0.0.1\" 'port {d}}} net.listen net.local-address", .{port});
    defer allocator.free(rebind);
    try runtime.run(rebind);
    var rebound: [2]u16 = undefined;
    const after = try runtime.ports(&rebound);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expectEqual(port, after[0]);
    try std.testing.expectEqual(Probe.accepted, try probe(port));
}

test "net: the live-listener quota is released when a scope closes" {
    const one: Policy = .{
        .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} },
        .limits = .{ .max_live_listeners = 1 },
    };
    const second = listen_ephemeral ++ " 'first set " ++ listen_ephemeral;
    const data = addressData("127.0.0.1", 0);
    try expectError(.{ .net = one }, second, .{
        .name = "over quota",
        .source = second,
        .kind = "domain",
        .word = "net.listen",
        .data = &.{ reason("limit"), data[0], data[1] },
    });
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = one }, .cooperative);
    defer runtime.close();
    try runtime.run("[] (" ++ listen_ephemeral ++ ") @spawn await pop " ++ listen_ephemeral ++ " net.local-address 'address at");
    try runtime.expectDisplay("\"127.0.0.1\"");
}

test "net: close releases the socket immediately and is idempotent" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = unrestricted }, .cooperative);
    defer runtime.close();
    try runtime.run(listen_ephemeral ++ " dup net.local-address swap dup net.close dup net.close");
    var storage: [1]u16 = undefined;
    const ports = try runtime.ports(&storage);
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    const port = ports[0];
    try std.testing.expectEqual(Probe.refused, try probe(port));
    const data = addressData("127.0.0.1", port);
    try runtime.runError("net.local-address", .{
        .name = "closed listener",
        .source = "net.local-address",
        .kind = "io",
        .word = "net.local-address",
        .data = &.{ reason("closed"), data[0], data[1] },
    });
    const rebind = try std.fmt.allocPrint(allocator, "pop {{'address \"127.0.0.1\" 'port {d}}} net.listen net.local-address", .{port});
    defer allocator.free(rebind);
    try runtime.run(rebind);
    var rebound: [2]u16 = undefined;
    const after = try runtime.ports(&rebound);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expectEqual(port, after[1]);
    try std.testing.expectEqual(Probe.accepted, try probe(port));
}

test "net: concurrent listens under the worker pool close with their scopes" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .{ .worker_pool = 4 });
    defer runtime.close();
    const child = "[] (" ++ listen_ephemeral ++ " net.local-address) @spawn";
    try runtime.run("[] (" ++ child ++ " " ++ child ++ " await swap await) @spawn " ++ child ++ " await swap await");
    var storage: [3]u16 = undefined;
    const ports = try runtime.ports(&storage);
    try std.testing.expectEqual(@as(usize, 3), ports.len);
    for (ports) |port| {
        try std.testing.expect(port != 0);
        try std.testing.expectEqual(Probe.refused, try probe(port));
    }
}

test "net: words cold-load through the builtin manifest and are documented" {
    try support.expectStack(
        "'net.listen doc len 0 > 'net.local-address doc len 0 > 'net.close doc len 0 >",
        "1 1 1",
    );
    try support.expectStack("'net ('listen 'local-address 'close) import 1", "1");
}

// Connection words. Every case drives the public Session and observes the
// other end through a `Peer`: a Zig thread that connects to the listener's
// port and runs one closed script. Synchronization is by bytes on the socket,
// never by sleeping: a peer that must act after the server has reached a
// point waits for a sync byte the program writes.

const posix = std.posix;

const Script = union(enum) {
    /// Connect, then read until EOF.
    read_until_eof,
    /// Connect, write the bytes, then read until EOF.
    write_then_read_until_eof: []const u8,
    /// Connect, write the bytes, then close at once so the server sees EOF.
    write_then_close: []const u8,
    /// Connect and close at once, sending nothing.
    connect_then_close,
    /// Connect, wait for one sync byte, write the bytes, then read until EOF.
    sync_then_write: []const u8,
    /// Connect, wait for one sync byte, then close with SO_LINGER zero so the
    /// server observes a reset.
    sync_then_reset,
};

const Observed = struct {
    received: [64]u8 = @splat(0),
    received_len: usize = 0,
    eof: bool = false,
    local_port: u16 = 0,
    failure: ?anyerror = null,

    fn bytes(self: *const Observed) []const u8 {
        return self.received[0..self.received_len];
    }
};

const Peer = struct {
    thread: ?std.Thread = null,
    port: u16,
    script: Script,
    observed: Observed = .{},

    fn start(port: u16, script: Script) !*Peer {
        const peer = try allocator.create(Peer);
        peer.* = .{ .port = port, .script = script };
        peer.thread = try std.Thread.spawn(.{}, run, .{peer});
        return peer;
    }

    fn join(self: *Peer) Observed {
        self.thread.?.join();
        const observed = self.observed;
        allocator.destroy(self);
        return observed;
    }

    fn run(self: *Peer) void {
        self.observed = execute(self.port, self.script) catch |err| .{ .failure = err };
    }

    fn execute(port: u16, script: Script) !Observed {
        var observed: Observed = .{};
        const address: IpAddress = .{ .ip4 = .loopback(port) };
        const stream = IpAddress.connect(&address, io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => return observed,
            else => return err,
        };
        var closed = false;
        defer if (!closed) stream.close(io);
        // SAFETY: getsockname fills `storage` before it is read; on failure the
        // local port simply stays zero.
        var storage: std.Io.Threaded.PosixAddress = undefined;
        var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
        if (posix.system.getsockname(stream.socket.handle, &storage.any, &length) == 0)
            observed.local_port = std.Io.Threaded.addressFromPosix(&storage).getPort();
        var read_buffer: [64]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &.{});
        switch (script) {
            .read_until_eof => {},
            .write_then_read_until_eof => |payload| {
                try writer.interface.writeAll(payload);
                try writer.interface.flush();
            },
            .write_then_close => |payload| {
                try writer.interface.writeAll(payload);
                try writer.interface.flush();
                stream.close(io);
                closed = true;
                observed.eof = true;
                return observed;
            },
            .connect_then_close => {
                stream.close(io);
                closed = true;
                observed.eof = true;
                return observed;
            },
            .sync_then_write => |payload| {
                _ = try reader.interface.takeByte();
                try writer.interface.writeAll(payload);
                try writer.interface.flush();
            },
            .sync_then_reset => {
                _ = try reader.interface.takeByte();
                const hard: posix.linger = .{ .onoff = 1, .linger = 0 };
                try posix.setsockopt(stream.socket.handle, posix.SOL.SOCKET, posix.SO.LINGER, std.mem.asBytes(&hard));
                stream.close(io);
                closed = true;
                return observed;
            },
        }
        while (true) {
            const count = reader.interface.readSliceShort(observed.received[observed.received_len..]) catch |err| {
                // A reset or any other read failure is not an orderly close.
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

fn expectPeerBytes(observed: Observed, expected: []const u8) !void {
    if (observed.failure) |failure| return failure;
    try std.testing.expect(observed.eof);
    try std.testing.expectEqualSlices(u8, expected, observed.bytes());
}

/// Bind an ephemeral listener under `grants`, run `program` with `l` bound to
/// it, and return the port so peers can connect.
fn listenerPort(runtime: *Runtime) !u16 {
    try runtime.run(listen_ephemeral ++ " 'l set l net.local-address 'port at");
    var display = try runtime.session.stackDisplay();
    defer display.deinit();
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, display.bytes(), " \n"), 10);
    try std.testing.expect(port != 0);
    try runtime.run("pop");
    return port;
}

test "net: accept parks until a peer connects and yields a connection port" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    // The peer connects before any accept is outstanding: the handshake
    // completes into the kernel backlog and waits there.
    const early = try Peer.start(port, .{ .write_then_read_until_eof = "hello" });
    try runtime.run("l net.accept 'c set c type c 5 net.read c net.close");
    try runtime.expectDisplay("'port [104 101 108 108 111]");
    try expectPeerBytes(early.join(), "");
    // A second accept parks with nothing queued until a peer arrives.
    const late = try Peer.start(port, .{ .write_then_read_until_eof = "x" });
    try runtime.run("pop pop l net.accept 'd set d 1 net.read d net.close");
    try runtime.expectDisplay("[120]");
    try expectPeerBytes(late.join(), "");
}

test "net: read returns exact bytes bounded by max and the receive capacity and an empty list at EOF" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = .{
        .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} },
        .limits = .{ .receive_capacity = 4 },
    } }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .{ .write_then_close = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } });
    try runtime.run("l net.accept 'c set c 8 net.read dup len 4 <= swap 2 (c 8 net.read cat) times c 8 net.read c 8 net.read");
    try runtime.expectDisplay("1 [1 2 3 4 5 6 7 8] [] []");
    try runtime.run("pop pop pop pop c 2 net.read");
    try runtime.expectDisplay("[]");
    try runtime.run("pop c net.close");
    try expectPeerBytes(peer.join(), "");
    // The count is validated before the connection's state is consulted.
    try runtime.runError("c 0 net.read", .{
        .name = "zero count",
        .source = "c 0 net.read",
        .kind = "domain",
        .word = "net.read",
    });
}

test "net: write delivers exact bytes in order under bounded send pressure" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = .{
        .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} },
        .limits = .{ .send_capacity = 4 },
    } }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("l net.accept 'c set c [1 2 3 4 5 6 7 8] net.write c [9 10] net.write c net.close");
    try expectPeerBytes(peer.join(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    const second = try Peer.start(port, .read_until_eof);
    try runtime.run("l net.accept 'd set " ++
        "[] (d [256] net.write) @attempt 'err at 'kind at " ++
        "[] (d \"text\" net.write) @attempt 'err at 'kind at " ++
        "[] (d 1 net.write) @attempt 'err at 'kind at " ++
        "d [7] net.write d net.close");
    try runtime.expectDisplay("'domain 'domain 'type");
    try expectPeerBytes(second.join(), &.{7});
}

test "net: peer-address and local-address describe both ends of a connection" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("l net.accept 'c set c net.peer-address c net.local-address 'port at c net.close");
    var display = try runtime.session.stackDisplay();
    defer display.deinit();
    const observed = peer.join();
    try expectPeerBytes(observed, "");
    var expected_buffer: [96]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{'address \"127.0.0.1\" 'port {d}}} {d}", .{ observed.local_port, port });
    try std.testing.expectEqualStrings(expected, display.bytes());
    const closed_data = addressData("127.0.0.1", observed.local_port);
    try runtime.runError("c net.peer-address", .{
        .name = "closed connection",
        .source = "c net.peer-address",
        .kind = "io",
        .word = "net.peer-address",
        .data = &.{ reason("closed"), closed_data[0], closed_data[1] },
    });
    // The closed local-address names the local end, never the peer.
    const local_data = addressData("127.0.0.1", port);
    try runtime.runError("c net.local-address", .{
        .name = "closed connection local end",
        .source = "c net.local-address",
        .kind = "io",
        .word = "net.local-address",
        .data = &.{ reason("closed"), local_data[0], local_data[1] },
    });
}

test "net: a connection on a wildcard listener reports the endpoint it was reached on" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = .{ .binds = .{ .exact = &.{.{ .address = "0.0.0.0", .port = 0 }} } } }, .cooperative);
    defer runtime.close();
    try runtime.run("{'address \"0.0.0.0\" 'port 0} net.listen 'l set l net.local-address 'port at");
    var display = try runtime.session.stackDisplay();
    defer display.deinit();
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, display.bytes(), " \n"), 10);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("pop l net.accept 'c set c net.local-address 'address at c net.close");
    try runtime.expectDisplay("\"127.0.0.1\"");
    try expectPeerBytes(peer.join(), "");
}

test "net: a peer that closes at once yields a connection at EOF" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .connect_then_close);
    try expectPeerBytes(peer.join(), "");
    try runtime.run("l net.accept 'c set c 4 net.read c 4 net.read c net.peer-address 'address at c net.close");
    try runtime.expectDisplay("[] [] \"127.0.0.1\"");
}

test "net: a connection belongs to the accepting unit's scope and closes with it" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("[] (l net.accept) @spawn await 'ok at first 'c set c type");
    try runtime.expectDisplay("'port");
    try expectPeerBytes(peer.join(), "");
    try runtime.runError("c 4 net.read", .{
        .name = "connection swept by its scope",
        .source = "c 4 net.read",
        .kind = "io",
        .word = "net.read",
        .data = &.{reason("closed")},
    });
    try runtime.runError("c [1] net.write", .{
        .name = "write after scope closure",
        .source = "c [1] net.write",
        .kind = "io",
        .word = "net.write",
        .data = &.{reason("closed")},
    });
}

test "net: close flushes queued bytes before the peer observes EOF and is idempotent" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("l net.accept 'c set c [111 107] net.write c net.close c net.close 1");
    try runtime.expectDisplay("1");
    try expectPeerBytes(peer.join(), "ok");
}

test "net: closing a listener wakes parked acceptors with io closed and leaves accepted connections open" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .{ .write_then_read_until_eof = "in" });
    try runtime.run("l net.accept 'c set [] (l net.accept) @spawn 'waiting set 0 clock.sleep l net.close waiting await 'err at 'kind at");
    try runtime.expectDisplay("'io");
    try runtime.run("pop c 2 net.read c [111 117 116] net.write c net.close");
    try runtime.expectDisplay("[105 110]");
    try expectPeerBytes(peer.join(), "out");
    const data = addressData("127.0.0.1", port);
    try runtime.runError("l net.accept", .{
        .name = "accept on a closed listener",
        .source = "l net.accept",
        .kind = "io",
        .word = "net.accept",
        .data = &.{ reason("closed"), data[0], data[1] },
    });
}

test "net: overlapping reads on one connection are a contract failure" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .{ .sync_then_write = "ab" });
    // The child parks in its read first; the parent yields once so that is
    // certain, then its own read finds the reader slot taken.
    try runtime.run("l net.accept 'c set [] (c 2 net.read) @spawn 'reader set 0 clock.sleep " ++
        "[] (c 2 net.read) @attempt 'err at 'kind at " ++
        "c [1] net.write reader await 'ok at first c net.close");
    try runtime.expectDisplay("'contract [97 98]");
    // The peer consumed the sync byte before writing; nothing else reached it.
    try expectPeerBytes(peer.join(), "");
}

test "net: a peer reset is an io failure carrying the peer address and reason" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .sync_then_reset);
    try runtime.run("l net.accept 'c set c net.peer-address 'port at c [1] net.write");
    var display = try runtime.session.stackDisplay();
    defer display.deinit();
    const peer_port = try std.fmt.parseInt(u16, std.mem.trim(u8, display.bytes(), " \n"), 10);
    const observed = peer.join();
    if (observed.failure) |failure| return failure;
    try std.testing.expectEqual(observed.local_port, peer_port);
    const data = addressData("127.0.0.1", peer_port);
    try runtime.runError("c 16 net.read", .{
        .name = "read after reset",
        .source = "c 16 net.read",
        .kind = "io",
        .word = "net.read",
        .data = &.{ reason("reset"), data[0], data[1] },
    });
    // A connection the peer tore down is terminal: its endpoints are no
    // longer observable as live addresses.
    try runtime.runError("c net.peer-address", .{
        .name = "peer-address after reset",
        .source = "c net.peer-address",
        .kind = "io",
        .word = "net.peer-address",
        .data = &.{ reason("closed"), data[0], data[1] },
    });
}

test "net: accept parks at the live-connection quota and proceeds when a connection closes" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = .{
        .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} },
        .limits = .{ .max_live_connections = 1 },
    } }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const first = try Peer.start(port, .read_until_eof);
    // One connection fills the quota; a child's accept parks behind it. The
    // child reads and closes inside its own scope, which owns the connection.
    try runtime.run("l net.accept 'c set [] (l net.accept dup 1 net.read swap net.close) @spawn 'waiting set 0 clock.sleep");
    // A second peer completes its handshake into the kernel backlog. The
    // parked accept neither fails with the limit nor proceeds.
    const second = try Peer.start(port, .{ .write_then_read_until_eof = "x" });
    try runtime.run("waiting 0 await-for 'err at 'kind at");
    try runtime.expectDisplay("'timeout");
    // Closing the first connection frees the slot; the child's accept yields
    // the queued peer and reads what it wrote.
    try runtime.run("pop c net.close waiting await 'ok at first");
    try runtime.expectDisplay("[120]");
    try expectPeerBytes(first.join(), "");
    try expectPeerBytes(second.join(), "");
}

test "net: cancelling a parked accept or read leaves the listener and connection usable" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    // The cancelled accept had the acceptor waiting in poll; the connection
    // that arrives afterwards must stay in the kernel backlog, unreset, until
    // the next accept takes it.
    try runtime.run("[] (l net.accept) @spawn 'waiting set 0 clock.sleep waiting dup cancel await 'err at 'kind at");
    try runtime.expectDisplay("'cancelled");
    const early = try Peer.start(port, .{ .write_then_read_until_eof = "q" });
    try runtime.run("pop l net.accept 'e set e 1 net.read e net.close");
    try runtime.expectDisplay("[113]");
    try expectPeerBytes(early.join(), "");
    const peer = try Peer.start(port, .{ .sync_then_write = "abcd" });
    try runtime.run("pop l net.accept 'c set [] (c 4 net.read) @spawn 0 clock.sleep dup cancel await 'err at 'kind at");
    try runtime.expectDisplay("'cancelled");
    try runtime.run("pop c [1] net.write c 4 net.read c net.close");
    try runtime.expectDisplay("[97 98 99 100]");
    try expectPeerBytes(peer.join(), "");
}

test "net: connection words reject listeners, process ports, and non-ports with type" {
    const fixture_path = try processFixturePath();
    defer allocator.free(fixture_path);
    const grants: Grants = .{
        .net = loopback_ephemeral,
        .process = .{ .executables = .{ .exact = &.{fixture_path} } },
    };
    for ([_][]const u8{ "l 4 net.read", "l [1] net.write", "l net.peer-address" }) |source| {
        const program = try std.fmt.allocPrint(allocator, "{s} 'l set {s}", .{ listen_ephemeral, source });
        defer allocator.free(program);
        try expectError(grants, program, .{ .name = source, .source = program, .kind = "type" });
    }
    const spawn = try std.fmt.allocPrint(
        allocator,
        "'proc ('spawn) import {{'executable \"{s}\" 'args (\"exit\" \"0\")}} spawn",
        .{fixture_path},
    );
    defer allocator.free(spawn);
    for ([_][]const u8{ "net.accept", "net.peer-address", "4 net.read" }) |word| {
        const program = try std.fmt.allocPrint(allocator, "{s} {s}", .{ spawn, word });
        defer allocator.free(program);
        try expectError(grants, program, .{ .name = word, .source = program, .kind = "type" });
    }
    try expectError(grants, "1 net.accept", .{ .name = "int", .source = "1 net.accept", .kind = "type", .word = "net.accept" });
    var runtime: Runtime = .{};
    try runtime.open(grants, .cooperative);
    defer runtime.close();
    const port = try listenerPort(&runtime);
    const peer = try Peer.start(port, .read_until_eof);
    try runtime.run("l net.accept 'c set");
    try runtime.runError("c net.accept", .{ .name = "accept on a connection", .source = "c net.accept", .kind = "type", .word = "net.accept" });
    try runtime.run("c net.close");
    try expectPeerBytes(peer.join(), "");
}

test "net: concurrent connections under the worker pool close with their scopes" {
    var runtime: Runtime = .{};
    try runtime.open(.{ .net = loopback_ephemeral }, .{ .worker_pool = 4 });
    defer runtime.close();
    const port = try listenerPort(&runtime);
    var peers: [3]*Peer = undefined;
    for (&peers, 0..) |*peer, index| {
        const payload: []const u8 = switch (index) {
            0 => "a",
            1 => "b",
            else => "c",
        };
        peer.* = try Peer.start(port, .{ .write_then_read_until_eof = payload });
    }
    // Each child keeps its connection on its own stack: a shared `set` name
    // would race across workers and hand one child another's connection.
    const child = "[] (l net.accept 1 net.read) @spawn";
    try runtime.run(child ++ " " ++ child ++ " " ++ child ++ " 't3 set 't2 set 't1 set " ++
        "t1 await 'ok at first t2 await 'ok at first t3 await 'ok at first cat cat");
    var display = try runtime.session.stackDisplay();
    defer display.deinit();
    var total: usize = 0;
    for ([_][]const u8{ "97", "98", "99" }) |byte| {
        if (std.mem.indexOf(u8, display.bytes(), byte) != null) total += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), total);
    for (&peers) |peer| try expectPeerBytes(peer.*.join(), "");
}

test "net: connection words cold-load through the builtin manifest and are documented" {
    try support.expectStack(
        "'net.accept doc len 0 > 'net.read doc len 0 > 'net.write doc len 0 > 'net.peer-address doc len 0 >",
        "1 1 1 1",
    );
    try support.expectStack("'net ('accept 'read 'write 'peer-address) import 1", "1");
}
