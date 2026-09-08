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
const bindings = @import("module_bindings.zig");
const endpoints = @import("port_endpoint.zig");
const bytes = @import("port_bytes.zig");

pub const registration = bindings.Registration.create(Binding);

const Binding = struct {
    instance: *bindings.Identity,
    access: ?*external.NetAccess,
    pub const definitions: []const bindings.Definition = &.{
        .{ .name = "listener", .doc = "Create a TCP listener using the Session's listen grant.", .effect = "-- factory" },
        .{ .name = "input", .doc = "Select the connection's readable byte stream.", .effect = "-- selector" },
        .{ .name = "output", .doc = "Select the connection's writable byte stream; finish sends EOF after admitted writes.", .effect = "-- selector" },
    };
    pub fn bind(memory: std.mem.Allocator, inherited: *const @import("machine.zig").InheritedContext) error{OutOfMemory}!*bindings.Publication {
        const instance = if (inherited.net_access) |access| net.registeredInstance(access) else try bindings.Identity.create(memory);
        if (inherited.net_access != null) instance.retain();
        errdefer instance.release();
        const owned = try instance.allocator().create(Binding);
        errdefer instance.allocator().destroy(owned);
        owned.* = .{ .instance = instance, .access = inherited.net_access };
        return bindings.Publication.create(Binding, owned);
    }
    pub fn allocator(self: *Binding) std.mem.Allocator {
        return self.instance.allocator();
    }
    pub fn release(self: *Binding) void {
        const memory = self.allocator();
        self.instance.release();
        memory.destroy(self);
    }
    pub fn seal(self: *Binding, index: usize) error{OutOfMemory}!Value {
        if (index != 0) {
            const owned = try self.allocator().create(Selector);
            errdefer self.allocator().destroy(owned);
            owned.* = .{ .instance = self.instance, .direction = if (index == 1) .reader else .writer };
            const item = try endpoints.Selector.create(Selector, self.instance.next(), owned);
            self.instance.retain();
            return item;
        }
        const owned = try self.allocator().create(Factory);
        errdefer self.allocator().destroy(owned);
        owned.* = .{ .instance = self.instance, .access = self.access };
        const item = try factories.Factory.create(Factory, self.instance.next(), owned);
        self.instance.retain();
        return item;
    }
};

const Selector = struct {
    instance: *bindings.Identity,
    direction: enum { reader, writer },
    pub fn allocator(self: *Selector) std.mem.Allocator {
        return self.instance.allocator();
    }
    pub fn borrowEndpoint(self: *Selector, source: Value) endpoints.BorrowError!Value {
        const cell = net.connectionFromValue(source) orelse return error.WrongKind;
        if (cell.instance != self.instance) return error.WrongKind;
        const owned = try self.allocator().create(Endpoint);
        errdefer self.allocator().destroy(owned);
        owned.* = .{ .cell = cell };
        const item = switch (self.direction) {
            .reader => try endpoints.Endpoint.create(Endpoint, .reader, self.instance.next(), owned),
            .writer => try endpoints.Endpoint.create(Endpoint, .writer, self.instance.next(), owned),
        };
        cell.retainReadiness();
        return item;
    }
    pub fn releasePort(self: *Selector) void {
        const instance = self.instance;
        instance.allocator().destroy(self);
        instance.release();
    }
};

const Endpoint = struct {
    cell: *net.ConnectionCell,
    pub const Permit = net.WritePermit;
    pub fn allocator(self: *Endpoint) std.mem.Allocator {
        return self.cell.allocator;
    }
    pub fn beginRead(self: *Endpoint) error{Busy}!void {
        self.cell.beginRead() catch return error.Busy;
    }
    pub fn endRead(self: *Endpoint) void {
        self.cell.endRead();
    }
    pub fn readCapacity(self: *Endpoint) usize {
        return self.cell.readCapacity();
    }
    pub fn read(self: *Endpoint, destination: []u8) bytes.Read {
        return switch (self.cell.read(destination)) {
            .pending => .pending,
            .eof => .eof,
            .data => |count| .{ .data = count },
            .failed => |failure| .{ .failed = transportFailure(failure) },
        };
    }
    pub fn readSource(self: *Endpoint) external.ReadinessSource {
        return self.cell.readSource();
    }
    pub fn beginWrite(self: *Endpoint) error{ OutOfMemory, Finished }!*Permit {
        return self.cell.beginWrite() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Closed, error.Reset, error.Io => error.Finished,
        };
    }
    pub fn writeBytes(permit: *Permit, source: []const u8) bytes.Write {
        return switch (permit.write(source)) {
            .pending => .pending,
            .written => |count| .{ .written = count },
            .failed => |failure| .{ .failed = transportFailure(failure) },
        };
    }
    pub fn finish(self: *Endpoint) void {
        self.cell.finishOutput();
    }
    pub fn releasePort(self: *Endpoint) void {
        const cell = self.cell;
        cell.allocator.destroy(self);
        cell.releaseReadiness();
    }
};

fn transportFailure(failure: net.Failure) bytes.Failure {
    return .init(.io, switch (failure) {
        .closed => "connection is closed",
        .reset => "connection was reset",
        .io => "connection transport failed",
    });
}

const Factory = struct {
    instance: *bindings.Identity,
    access: ?*external.NetAccess,
    pub fn allocator(self: *Factory) std.mem.Allocator {
        return self.instance.allocator();
    }
    pub fn openResource(self: *Factory, context: factories.Context, config: *const @import("port_message.zig").Validated) error{OutOfMemory}!factories.Start {
        return open(self.access, context, config.value());
    }
    pub fn releasePort(self: *Factory) void {
        const instance = self.instance;
        instance.allocator().destroy(self);
        instance.release();
    }
};

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
