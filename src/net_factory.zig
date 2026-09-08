//! Bounded literal parsing and service admission for the registered listener.
const std = @import("std");
const values = @import("value.zig");
const Value = values.Value;
const dict = @import("dict.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const net = @import("net_port.zig");
const external = @import("external.zig");
const factories = @import("port_factory.zig");
const Failure = factories.Failure;

fn failed(kind: @import("machine.zig").ErrorKind, text: []const u8, address: Value, port: Value, reason: []const u8) error{OutOfMemory}!factories.Start {
    var failure = Failure.init(kind, text);
    failure.details = .{
        .{ .symbol = try intern.intern("address"), .value = address },
        .{ .symbol = try intern.intern("port"), .value = port },
        .{ .symbol = try intern.intern("reason"), .value = .{ .symbol = try intern.intern(reason) } },
    };
    return .{ .failed = failure };
}

pub fn open(access: ?*external.NetAccess, context: factories.Context, input: Value) error{OutOfMemory}!factories.Start {
    if (input != .dict) return .{ .failed = Failure.init(.type, "expected a listen configuration dict") };
    if (input.dict.length() != 2) return .{ .failed = Failure.init(.domain, "net.listen configuration needs exactly 'address and 'port") };
    const address_key = try intern.intern("address");
    const port_key = try intern.intern("port");
    var address_value: ?Value = null;
    var port_value: ?Value = null;
    for (0..2) |index| {
        const key = dict.keyAt(input.dict, index);
        const item = dict.valueAt(input.dict, index);
        if (key == .symbol and key.symbol == address_key) address_value = item else if (key == .symbol and key.symbol == port_key) port_value = item else return .{ .failed = Failure.init(.domain, "net.listen configuration accepts only 'address and 'port") };
    }
    const address = address_value orelse return .{ .failed = Failure.init(.domain, "net.listen configuration is missing 'address") };
    const port = port_value orelse return .{ .failed = Failure.init(.domain, "net.listen configuration is missing 'port") };
    if (!address.isString()) return .{ .failed = Failure.init(.type, "expected a string 'address") };
    if (port != .int) return .{ .failed = Failure.init(.type, "expected an integer 'port") };
    if (port.int < 0 or port.int > 65535) return failed(.domain, "net.listen 'port must lie in 0...65535", address, port, "invalid");
    var buffer: [64]u8 = undefined;
    var used: usize = 0;
    // The fixed literal limit bounds this loop independently of input size.
    var index: usize = 0;
    while (index < address.list.length()) : (index += 1) {
        const scalar = values.unicodeScalar(list.atUnchecked(address, index).char) orelse
            return failed(.domain, "net.listen 'address is not an IP literal", address, port, "invalid");
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch
            return failed(.domain, "net.listen 'address is not an IP literal", address, port, "invalid");
        if (used + count > buffer.len) return failed(.domain, "net.listen 'address is not an IP literal", address, port, "invalid");
        @memcpy(buffer[used..][0..count], encoded[0..count]);
        used += count;
    }
    const parsed = net.parseLiteral(buffer[0..used], @intCast(port.int)) catch
        return failed(.domain, "net.listen 'address is not an IP literal", address, port, "invalid");
    const granted = access orelse return failed(.domain, "listening is unavailable in this session", address, port, "unavailable");
    const resource = net.listenFromUnit(granted, context.scope.scheduler, context.scope, parsed) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Denied => failed(.domain, "net.listen address and port are denied by host policy", address, port, "denied"),
        error.LiveLimit => failed(.domain, "host listener limit reached", address, port, "limit"),
        error.Unsupported => failed(.io, "host does not support listening on this address family or protocol", address, port, "unsupported"),
        error.ScopeClosing => .{ .failed = Failure.init(.cancelled, "listener scope is closing") },
        error.Cancelled => .{ .failed = Failure.init(.cancelled, "net.listen was cancelled") },
        error.AddressInUse => failed(.io, "address already in use", address, port, "in-use"),
        error.AddressUnavailable => failed(.io, "address is not available on this host", address, port, "unavailable"),
        error.Resources => failed(.io, "host lacks resources to listen", address, port, "resources"),
        error.Io => failed(.io, "could not listen", address, port, "io"),
    };
    return .{ .resource = resource };
}
