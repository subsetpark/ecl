//! Capability-gated TCP listeners and connections over Session-granted
//! address and port pairs.
//!
//! `listen` validates its configuration, asks the Session's network owner for
//! a bound socket, and returns an opaque port value whose socket belongs to
//! the calling unit's task scope. `accept` parks until a peer connects and
//! returns a connection port owned by the accepting unit's scope. `read` and
//! `write` move exact bytes through the connection's bounded rings, parking on
//! readiness through the same scheduler drivers `proc` uses. `close` is the
//! idempotent transition scope closure performs: immediate for a listener,
//! after queued bytes are delivered for a connection. Framing, deadlines, and
//! TLS belong to protocol modules above this one.

const std = @import("std");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const kernel_storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const net_port = @import("../net_port.zig");
const value = @import("../value.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Value = value.Value;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "accept",
        .doc = "( listener -- connection ) Park until a peer connects and a live-connection slot is free, " ++
            "then return the connection as a port owned by the accepting unit's task scope, not the listener's.\n\n" ++
            "A connection is taken from the kernel backlog only while an accept is outstanding, so an idle program " ++
            "applies no backpressure beyond the backlog, and at the host's live-connection maximum the accept keeps " ++
            "waiting until a connection closes. A connection, process port, or non-port is 'type.\n\n" ++
            "Failures are 'io carrying the listener's 'address and 'port and one 'reason: 'closed when the listener " ++
            "was closed while the accept waited, 'resources when descriptors or buffers ran out, and 'io for any other " ++
            "host failure. Cancelling the parked unit fails only that unit 'cancelled; a connection the host had " ++
            "already handed to it is closed.",
        .primitive = accept,
    },
    .{
        .name = "close",
        .doc = "( port -- ) Close a listener or a connection. Idempotent, and the same transition scope closure performs.\n\n" ++
            "A listener closes at once: every accept parked on it fails 'io 'closed, connections it already accepted " ++
            "stay open, and its address and port may be bound again immediately. A connection first delivers the " ++
            "bytes already queued by write, then shuts the socket down; later reads and writes on it fail 'io 'closed. " ++
            "Closing a connection parks until those bytes reach the kernel or the connection fails, so a unit may " ++
            "close and end at once without its own scope closure discarding them; cancelling the parked close " ++
            "abandons what is still queued. A process port or non-port is 'type.",
        .primitive = close,
    },
    .{
        .name = "listen",
        .doc = "( config -- listener ) Bind and listen on a host-granted TCP address and return the listener as a port " ++
            "owned by the calling unit's task scope. The socket is listening before the value is returned.\n\n" ++
            "The configuration is a dict with exactly these keys:\n" ++
            "- 'address: a string holding an IPv4 or IPv6 literal such as \"127.0.0.1\" or \"::1\"; names are never resolved.\n" ++
            "- 'port: an int in 0...65535; 0 requests an ephemeral port, which local-address reports.\n\n" ++
            "A non-dict configuration is 'type; a missing, unknown, or repeated key is 'domain; a non-string 'address " ++
            "or non-int 'port is 'type; a port outside the range or a literal that does not parse is 'domain with " ++
            "'reason 'invalid. Authority is checked next, before the host is reached: 'domain with 'reason " ++
            "'unavailable when the Session has no listen grant, 'denied when no grant entry admits the address and " ++
            "port (a grant entry with port 0 admits only port 0), and 'limit at the host's listener maximum. A host " ++
            "bind or listen failure is 'io with 'reason 'in-use, 'unavailable (the address is not local), " ++
            "'resources, 'unsupported, or 'io. Every failure carries the requested 'address and 'port.",
        .primitive = listen,
    },
    .{
        .name = "local-address",
        .doc = "( port -- address ) Return the local end of a listener or connection as {'address string 'port int}.\n\n" ++
            "For a listener bound with port 0 this is the ephemeral port the kernel assigned; for a connection " ++
            "accepted on a wildcard listener it is the address the connection was actually reached on. A closed " ++
            "listener or connection is 'io with 'reason 'closed carrying the recorded local address; a process port " ++
            "or non-port is 'type.",
        .primitive = localAddress,
    },
    .{
        .name = "peer-address",
        .doc = "( connection -- address ) Return the peer's end of a connection as {'address string 'port int}.\n\n" ++
            "A closed connection is 'io with 'reason 'closed carrying the peer's address; a listener, process port, " ++
            "or non-port is 'type.",
        .primitive = peerAddress,
    },
    .{
        .name = "read",
        .doc = "( connection max -- bytes ) Read at most max bytes from a connection, parking until data arrives, and " ++
            "return them as an exact byte list of ints in 0...255.\n\n" ++
            "Each call returns at most max and at most the host receive capacity bytes, so a message may take several " ++
            "reads. [] is returned only at stable end of stream, and again on every later read. Decode text with " ++
            "chars. max must be an int greater than zero (otherwise 'type or 'domain); a non-connection is 'type; a " ++
            "second read while one is pending on the same connection is 'contract.\n\n" ++
            "Failures are 'io carrying the peer's 'address and 'port and one 'reason: 'closed after the connection " ++
            "was closed by close or by its scope, 'reset when the peer has gone, and 'io for any other host failure. " ++
            "Cancelling the parked unit fails only that unit 'cancelled; bytes the peer already sent stay available " ++
            "to the next read.",
        .primitive = read,
    },
    .{
        .name = "write",
        .doc = "( connection bytes -- ) Queue an exact byte list for the peer, parking while the host send capacity is " ++
            "full or an earlier write on the connection is still queued.\n\n" ++
            "bytes is a list of ints in 0...255; encode a string with bytes first. Writes on one connection are " ++
            "delivered in arrival order and each call's bytes stay contiguous. The word returns once the bytes are " ++
            "queued, not once the peer has read them; close delivers whatever is still queued. A non-list is 'type " ++
            "and an element outside 0...255 is 'domain.\n\n" ++
            "Failures are 'io carrying the peer's 'address and 'port and one 'reason: 'closed after the connection " ++
            "was closed locally, 'reset when the peer has closed or reset, and 'io for any other host failure.",
        .primitive = write,
    },
};

/// Longest IP literal this module accepts; the longest valid text form of an
/// IPv4-mapped IPv6 address is 45 bytes.
const max_address_bytes = 64;

const Keys = struct {
    address: u32,
    port: u32,

    fn init() error{OutOfMemory}!Keys {
        return .{
            .address = try intern.intern("address"),
            .port = try intern.intern("port"),
        };
    }
};

const Config = struct {
    /// Borrowed from the configuration dict, which outlives every use.
    address_value: Value,
    port_value: Value,
    address_bytes: [max_address_bytes]u8,
    address_len: usize,
    port: u16,

    fn address(self: *const Config) []const u8 {
        return self.address_bytes[0..self.address_len];
    }
};

const Reason = enum {
    unavailable,
    denied,
    limit,
    unsupported,
    invalid,
    @"in-use",
    resources,
    io,
    closed,
    reset,
};

fn failNet(
    evaluator: *Machine,
    kind: machine.ErrorKind,
    message: []const u8,
    address: Value,
    port: Value,
    reason: Reason,
) MachineError {
    const symbol = intern.intern(@tagName(reason)) catch return error.OutOfMemory;
    const failure = evaluator.fail(kind, message);
    evaluator.addErrorNet(address, port, .{ .symbol = symbol });
    return failure;
}

/// `failNet` for a host address: renders the literal into a fresh string
/// value that lives only as long as the failure construction needs it.
fn failAddress(
    evaluator: *Machine,
    kind: machine.ErrorKind,
    message: []const u8,
    address: net_port.IpAddress,
    reason: Reason,
) MachineError {
    var buffer: [max_address_bytes]u8 = undefined;
    const text = formatAddress(address, &buffer);
    const address_value = try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), text);
    defer evaluator.releaseDomain().releaseValue(address_value);
    return failNet(evaluator, kind, message, address_value, .{ .int = address.getPort() }, reason);
}

/// Validate `{'address string 'port int}` in full before any authority check.
fn readConfig(evaluator: *Machine, item: Value) MachineError!Config {
    if (item != .dict) return evaluator.typeError("a listen configuration dict");
    const keys = try Keys.init();
    const header = item.dict;
    if (header.length() != 2)
        return evaluator.fail(.domain, "net.listen configuration needs exactly 'address and 'port");
    var address_value: ?Value = null;
    var port_value: ?Value = null;
    var index: usize = 0;
    while (index < 2) : (index += 1) {
        const key = dict.keyAt(header, index);
        const field = dict.valueAt(header, index);
        if (key == .symbol and key.symbol == keys.address) {
            address_value = field;
        } else if (key == .symbol and key.symbol == keys.port) {
            port_value = field;
        } else {
            return evaluator.fail(.domain, "net.listen configuration accepts only 'address and 'port");
        }
    }
    const address = address_value orelse
        return evaluator.fail(.domain, "net.listen configuration is missing 'address");
    const port = port_value orelse
        return evaluator.fail(.domain, "net.listen configuration is missing 'port");
    if (!address.isString()) return evaluator.typeError("a string 'address");
    if (port != .int) return evaluator.typeError("an integer 'port");
    if (port.int < 0 or port.int > std.math.maxInt(u16))
        return failNet(evaluator, .domain, "net.listen 'port must lie in 0...65535", address, port, .invalid);
    var config: Config = .{
        .address_value = address,
        .port_value = port,
        // SAFETY: the encoding loop below writes every byte up to
        // `address_len` before any read, and nothing reads beyond it.
        .address_bytes = undefined,
        .address_len = 0,
        .port = @intCast(port.int),
    };
    const count: usize = @intCast(address.list.length());
    var char_index: usize = 0;
    while (char_index < count) : (char_index += 1) {
        const codepoint = list.atUnchecked(address, char_index).char;
        const scalar = value.unicodeScalar(codepoint) orelse
            return failNet(evaluator, .domain, "net.listen 'address is not an IP literal", address, port, .invalid);
        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(scalar, &encoded) catch
            return failNet(evaluator, .domain, "net.listen 'address is not an IP literal", address, port, .invalid);
        if (config.address_len + encoded_len > max_address_bytes)
            return failNet(evaluator, .domain, "net.listen 'address is not an IP literal", address, port, .invalid);
        @memcpy(config.address_bytes[config.address_len..][0..encoded_len], encoded[0..encoded_len]);
        config.address_len += encoded_len;
    }
    return config;
}

fn listen(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const config = try readConfig(evaluator, item.borrow());
    const parsed = net_port.parseLiteral(config.address(), config.port) catch
        return failNet(evaluator, .domain, "net.listen 'address is not an IP literal", config.address_value, config.port_value, .invalid);
    const access = evaluator.unit.inherited.net_access orelse
        return failNet(evaluator, .domain, "listening is unavailable in this session", config.address_value, config.port_value, .unavailable);
    const port = net_port.listenFromUnit(
        access,
        evaluator.unit.scheduler.?,
        evaluator.unit.task_scope.?,
        parsed,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Denied => failNet(evaluator, .domain, "net.listen address and port are denied by host policy", config.address_value, config.port_value, .denied),
        error.LiveLimit => failNet(evaluator, .domain, "host listener limit reached", config.address_value, config.port_value, .limit),
        error.Unsupported => failNet(evaluator, .io, "host does not support listening on this address family or protocol", config.address_value, config.port_value, .unsupported),
        error.ScopeClosing => evaluator.fail(.cancelled, "listener scope is closing"),
        error.Cancelled => evaluator.fail(.cancelled, "net.listen was cancelled"),
        error.AddressInUse => failNet(evaluator, .io, "address already in use", config.address_value, config.port_value, .@"in-use"),
        error.AddressUnavailable => failNet(evaluator, .io, "address is not available on this host", config.address_value, config.port_value, .unavailable),
        error.Resources => failNet(evaluator, .io, "host lacks resources to listen", config.address_value, config.port_value, .resources),
        error.Io => failNet(evaluator, .io, "could not listen", config.address_value, config.port_value, .io),
    };
    evaluator.pushOwned(port) catch |err| {
        evaluator.releaseDomain().releaseValue(port);
        return err;
    };
}

fn listenerCell(evaluator: *Machine, item: Value) MachineError!*net_port.ListenerCell {
    return net_port.fromValue(item) orelse evaluator.typeError("a network listener");
}

fn connectionCell(evaluator: *Machine, item: Value) MachineError!*net_port.ConnectionCell {
    return net_port.connectionFromValue(item) orelse evaluator.typeError("a network connection");
}

/// Render the address text without its port: dotted quad for IPv4, RFC 5952
/// text without brackets for IPv6.
fn formatAddress(address: net_port.IpAddress, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    switch (address) {
        .ip4 => |ip4| writer.print("{d}.{d}.{d}.{d}", .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] }) catch unreachable,
        .ip6 => |ip6| {
            const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = ip6.bytes, .interface_name = null };
            writer.print("{f}", .{unresolved}) catch unreachable;
        },
    }
    return writer.buffered();
}

fn pushAddress(evaluator: *Machine, address: net_port.IpAddress) MachineError!void {
    const keys = try Keys.init();
    var buffer: [max_address_bytes]u8 = undefined;
    const text = formatAddress(address, &buffer);
    const address_value = try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), text);
    // The materializer retains every pair value it keeps, so this reference is
    // ours to release whether or not the dict is built.
    defer evaluator.releaseDomain().releaseValue(address_value);
    const result = try dict.fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{
        .{ .{ .symbol = keys.address }, address_value },
        .{ .{ .symbol = keys.port }, .{ .int = address.getPort() } },
    });
    evaluator.pushOwned(result) catch |err| {
        evaluator.releaseDomain().releaseValue(result);
        return err;
    };
}

/// One locked observation of a connection endpoint: the address is pushed
/// while the connection is live and attached to the `'closed` failure once it
/// is not, so a closed `local-address` names the local end and a closed
/// `peer-address` names the peer.
fn pushEndpoint(evaluator: *Machine, cell: *net_port.ConnectionCell, kind: net_port.EndpointKind) MachineError!void {
    return switch (cell.observeEndpoint(kind)) {
        .available => |address| pushAddress(evaluator, address),
        .closed => |address| failAddress(evaluator, .io, "connection is closed", address, .closed),
    };
}

fn localAddress(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (net_port.fromValue(item.borrow())) |cell| {
        const bound = cell.localAddress() orelse
            return failAddress(evaluator, .io, "listener is closed", cell.recordedAddress(), .closed);
        return pushAddress(evaluator, bound);
    }
    if (net_port.connectionFromValue(item.borrow())) |cell| return pushEndpoint(evaluator, cell, .local);
    return evaluator.typeError("a network listener or connection");
}

fn peerAddress(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const cell = try connectionCell(evaluator, item.borrow());
    return pushEndpoint(evaluator, cell, .peer);
}

/// A read or write can no longer proceed; the failure names the peer.
fn failConnection(evaluator: *Machine, cell: *net_port.ConnectionCell, failure: net_port.Failure) MachineError {
    const peer = switch (cell.observeEndpoint(.peer)) {
        .available, .closed => |address| address,
    };
    return switch (failure) {
        .closed => failAddress(evaluator, .io, "connection is closed", peer, .closed),
        .reset => failAddress(evaluator, .io, "connection reset by peer", peer, .reset),
        .io => failAddress(evaluator, .io, "connection failed", peer, .io),
    };
}

/// Closing a connection promises that the bytes already queued reach the peer,
/// so the close is not finished until the send ring has drained. Parking here
/// is what makes that promise true when the closing unit ends immediately
/// afterwards, as a unit given a connection normally does: without the wait,
/// the unit's scope closure would abort the socket and discard the queue.
const CloseDriver = struct {
    pub const address_stable_driver = {};
    /// Field ownership rather than self-owned construction: `startDriver`
    /// retires a still-uninstalled driver's fields when its allocation fails,
    /// so closing a connection needs no bespoke cleanup path of its own.
    pub const ownership: heap.DriverOwnership = .fields;
    connection: heap.Owned(Value),
    cell: *net_port.ConnectionCell,
    requested: bool = false,

    pub fn advance(evaluator: *Machine, self: *CloseDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (!self.requested) {
            self.requested = true;
            self.cell.close();
        }
        if (self.cell.drained()) return .completed;
        try evaluator.park(.{ .external = self.cell.drainSource() });
        return .yielded;
    }
};

fn close(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    if (net_port.fromValue(item.borrow())) |cell| {
        cell.close();
        item.deinit();
        return;
    }
    if (net_port.connectionFromValue(item.borrow())) |cell| {
        return evaluator.startDriver(CloseDriver{
            .connection = .init(item.take()),
            .cell = cell,
        });
    }
    return evaluator.typeError("a network listener or connection");
}

fn accept(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const cell = try listenerCell(evaluator, item.borrow());
    const slot = cell.beginAccept() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Closed => failAddress(evaluator, .io, "listener is closed", cell.recordedAddress(), .closed),
        error.Io => failAddress(evaluator, .io, "host lacks resources to accept", cell.recordedAddress(), .resources),
    };
    errdefer cell.endAccept(slot);
    const driver = try evaluator.allocator().create(AcceptDriver);
    driver.* = .{
        .listener = item.take(),
        .cell = cell,
        .slot = slot,
    };
    evaluator.adoptDriver(driver);
}

const AcceptDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    listener: Value,
    cell: *net_port.ListenerCell,
    slot: ?*net_port.AcceptSlot,

    pub fn deinit(self: *AcceptDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.slot) |slot| self.cell.endAccept(slot);
        releases.releaseValue(self.listener);
    }

    pub fn advance(evaluator: *Machine, self: *AcceptDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const slot = self.slot.?;
        const progress = try net_port.pollAcceptFromUnit(
            self.cell,
            slot,
            evaluator.unit.scheduler.?,
            evaluator.unit.task_scope.?,
        );
        return switch (progress) {
            .pending => parked: {
                try evaluator.park(.{ .external = self.cell.acceptSource(slot) });
                break :parked .yielded;
            },
            .accepted => |port| .{ .output = port },
            .closed => failAddress(evaluator, .io, "listener is closed", self.cell.recordedAddress(), .closed),
            .scope_closing => evaluator.fail(.cancelled, "accepting scope is closing"),
            .resources => failAddress(evaluator, .io, "host lacks resources to accept", self.cell.recordedAddress(), .resources),
            .io => failAddress(evaluator, .io, "could not accept", self.cell.recordedAddress(), .io),
        };
    }
};

fn read(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var maximum = try evaluator.popValue();
    defer maximum.deinit();
    if (maximum.borrow() != .int) return evaluator.typeError("a positive byte count");
    if (maximum.borrow().int <= 0 or maximum.borrow().int > std.math.maxInt(usize))
        return evaluator.fail(.domain, "net.read count must be positive");
    var connection = try evaluator.popValue();
    errdefer connection.deinit();
    const cell = try connectionCell(evaluator, connection.borrow());
    const count = @min(@as(usize, @intCast(maximum.borrow().int)), cell.readCapacity());
    cell.beginRead() catch return evaluator.fail(.contract, "connection already has a pending reader");
    errdefer cell.endRead();
    const buffer = try evaluator.allocator().alloc(u8, count);
    errdefer evaluator.allocator().free(buffer);
    const driver = try evaluator.allocator().create(ReadDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .allocator = evaluator.allocator(),
        .connection = connection.take(),
        .cell = cell,
        .buffer = buffer,
    };
    evaluator.adoptDriver(driver);
}

const ReadDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    allocator: std.mem.Allocator,
    connection: Value,
    cell: *net_port.ConnectionCell,
    buffer: []u8,
    count: ?usize = null,
    materializer: ?list.ByteListMaterializer = null,

    pub fn deinit(self: *ReadDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        self.cell.endRead();
        allocator.free(self.buffer);
        releases.releaseValue(self.connection);
    }

    pub fn advance(evaluator: *Machine, self: *ReadDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.count == null) switch (self.cell.read(self.buffer)) {
            .pending => {
                try evaluator.park(.{ .external = self.cell.readSource() });
                return .yielded;
            },
            .failed => |failure| return failConnection(evaluator, self.cell, failure),
            .eof => self.count = 0,
            .data => |count| self.count = count,
        };
        if (self.materializer == null)
            self.materializer = .init(self.allocator, self.buffer[0..self.count.?]);
        return switch (try self.materializer.?.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |item| complete: {
                self.materializer.?.deinit();
                self.materializer = null;
                break :complete .{ .output = item };
            },
        };
    }
};

fn write(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var bytes = try evaluator.popValue();
    errdefer bytes.deinit();
    if (bytes.borrow() != .list) return evaluator.typeError("a byte list");
    var connection = try evaluator.popValue();
    errdefer connection.deinit();
    const cell = try connectionCell(evaluator, connection.borrow());
    const permit = try cell.beginWrite();
    errdefer cell.abandonWrite(permit);
    const bytes_borrowed = bytes.borrow();
    const driver = try evaluator.allocator().create(WriteDriver);
    driver.* = .{
        .connection = connection.take(),
        .bytes_value = bytes.take(),
        .encoder = .init(evaluator.allocator(), bytes_borrowed),
        .cell = cell,
        .permit = permit,
    };
    evaluator.adoptDriver(driver);
}

const WriteDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    connection: Value,
    bytes_value: Value,
    encoder: ?kernel_storage.ByteVectorEncoder,
    bytes: ?kernel_storage.ByteVector = null,
    cell: *net_port.ConnectionCell,
    permit: ?*net_port.WritePermit = null,
    offset: usize = 0,

    pub fn deinit(self: *WriteDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.permit) |permit| self.cell.abandonWrite(permit);
        if (self.encoder) |*encoder| encoder.deinit();
        if (self.bytes) |*bytes| bytes.retire(releases, allocator);
        releases.releaseValue(self.bytes_value);
        releases.releaseValue(self.connection);
    }

    pub fn advance(evaluator: *Machine, self: *WriteDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.bytes == null) switch (self.encoder.?.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.fail(.domain, "net.write contains a value outside 0...255"),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                self.encoder.?.deinit();
                self.encoder = null;
                self.bytes = bytes;
            },
        };
        const source = self.bytes.?.bytes();
        if (self.offset == source.len) {
            self.cell.finishWrite(self.permit.?);
            self.permit = null;
            return .completed;
        }
        return switch (self.cell.write(self.permit.?, source[self.offset..])) {
            .written => |count| progressed: {
                self.offset += count;
                break :progressed .yielded;
            },
            .failed => |failure| failConnection(evaluator, self.cell, failure),
            .pending => parked: {
                try evaluator.park(.{ .external = self.cell.writeSource(self.permit.?) });
                break :parked .yielded;
            },
        };
    }
};
