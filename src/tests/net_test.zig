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

// Connection words. PENDING: Patch 4 of gameplans/net-connections.json
// implements each test below against the public Session with a Zig-side
// `Peer` thread (connect, scripted write/read/close, optional SO_LINGER zero).

// PENDING: Patch 4. Oracle: a Zig `Peer` thread connects to the listener's port after `net.accept` has parked; the stack then shows a `'port` value and the peer's write is read in full.
test "net: accept parks until a peer connects and yields a connection port" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: policy `receive_capacity = 4`; the peer writes eight bytes and closes; two reads of at most eight return four bytes each, `2 net.read` returns two, and reads after EOF return `[]`.
test "net: read returns exact bytes bounded by max and the receive capacity and an empty list at EOF" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: policy `send_capacity = 4`; `[1 2 3 4 5 6 7 8] net.write` completes and the peer, reading until EOF, observes exactly those bytes in order.
test "net: write delivers exact bytes in order under bounded send pressure" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: `peer-address` equals the address and port the peer bound; `local-address 'port at` equals the listener's port.
test "net: peer-address and local-address describe both ends of a connection" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: a child unit accepts and returns the connection; after `await` the peer observes EOF and `net.read` on the retained value is `'io` `'closed`.
test "net: a connection belongs to the accepting unit's scope and closes with it" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: `[111 107] net.write net.close net.close`; the peer reads exactly `ok` then EOF.
test "net: close flushes queued bytes before the peer observes EOF and is idempotent" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: a parked `accept` child fails `'io` `'closed` after `net.close` on the listener; a connection accepted earlier still reads and writes.
test "net: closing a listener wakes parked acceptors with io closed and leaves accepted connections open" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: a child parks in `net.read`; the parent's `net.read` on the same connection fails `'contract`.
test "net: overlapping reads on one connection are a contract failure" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: the peer closes with `SO_LINGER` zero; the next `net.write` or `net.read` fails `'io` with `'reason` `'reset` and the peer's `'address` and `'port`.
test "net: a peer reset is an io failure carrying the peer address and reason" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: policy `max_live_connections = 1`; the second `accept` fails `'domain` `'limit` synchronously; after `net.close` a third accept succeeds.
test "net: the live-connection quota refuses accept with domain limit and is released on close" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: a cancelled accept child reports `'cancelled` and a later `accept` succeeds; a cancelled read child reports `'cancelled` and a later `read` returns the bytes the peer sent meanwhile.
test "net: cancelling a parked accept or read leaves the listener and connection usable" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: `net.read`, `net.write`, `net.peer-address` on a listener and `net.accept` on a connection or process port fail `'type`.
test "net: connection words reject listeners, process ports, and non-ports with type" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: `.{ .worker_pool = 4 }`; three child units each accept one connection; every peer observes EOF once the children finish.
test "net: concurrent connections under the worker pool close with their scopes" {
    return error.SkipZigTest;
}

// PENDING: Patch 4. Oracle: `doc` is non-empty for the four new words and `import` binds them.
test "net: connection words cold-load through the builtin manifest and are documented" {
    return error.SkipZigTest;
}
