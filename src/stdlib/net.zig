//! Capability-gated TCP listeners over Session-granted address and port pairs.
//!
//! `listen` validates its configuration, asks the Session's network owner for
//! a bound socket, and returns an opaque port value whose socket belongs to
//! the calling unit's task scope. `local-address` reads the bound address
//! back, which is the whole readiness protocol for an ephemeral bind. `close`
//! is the same idempotent transition scope closure performs. Nothing here
//! accepts, reads, or writes; those belong to protocol words above this one.

const std = @import("std");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const net_port = @import("../net_port.zig");
const value = @import("../value.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Value = value.Value;

pub const words = [_]env.BuiltinWord{
    .{ .name = "close", .doc = "( listener -- ) Close a listener's socket now; idempotent, and scope closure does the same.", .primitive = close },
    .{ .name = "listen", .doc = "( config -- listener ) Bind and listen on a host-granted TCP address.", .primitive = listen },
    .{ .name = "local-address", .doc = "( listener -- address ) Report the bound address and port as {'address string 'port int}.", .primitive = localAddress },
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

fn localAddress(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const cell = try listenerCell(evaluator, item.borrow());
    var buffer: [max_address_bytes]u8 = undefined;
    const bound = cell.localAddress() orelse {
        const recorded = cell.recordedAddress();
        const text = formatAddress(recorded, &buffer);
        const address_value = try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), text);
        defer evaluator.releaseDomain().releaseValue(address_value);
        return failNet(evaluator, .io, "listener is closed", address_value, .{ .int = recorded.getPort() }, .closed);
    };
    const keys = try Keys.init();
    const text = formatAddress(bound, &buffer);
    const address_value = try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), text);
    // The materializer retains every pair value it keeps, so this reference is
    // ours to release whether or not the dict is built.
    defer evaluator.releaseDomain().releaseValue(address_value);
    const result = try dict.fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{
        .{ .{ .symbol = keys.address }, address_value },
        .{ .{ .symbol = keys.port }, .{ .int = bound.getPort() } },
    });
    evaluator.pushOwned(result) catch |err| {
        evaluator.releaseDomain().releaseValue(result);
        return err;
    };
}

fn close(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const cell = try listenerCell(evaluator, item.borrow());
    cell.close();
}
