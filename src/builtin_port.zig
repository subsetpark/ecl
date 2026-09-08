//! Registered capabilities for typed, in-process resource backends. A library
//! instance owns identity independently of its host service's operational life.
const std = @import("std");
const heap = @import("heap.zig");
const Value = @import("value.zig").Value;
const process = @import("process_port.zig");

pub const Library = enum { network, process };
pub const FactoryKind = enum {
    listener,
    process,

    pub fn library(self: FactoryKind) Library {
        return switch (self) {
            .listener => .network,
            .process => .process,
        };
    }
};
pub const Definition = struct {
    name: []const u8,
    doc: []const u8,
    body: Body,
};

pub const EndpointKind = enum {
    stdin,
    stdout,
    stderr,

    pub fn library(self: EndpointKind) Library {
        return switch (self) {
            .stdin, .stdout, .stderr => .process,
        };
    }
};

pub const Body = union(enum) {
    factory: FactoryKind,
    endpoint: EndpointKind,

    pub fn library(self: Body) Library {
        return switch (self) {
            inline else => |kind| kind.library(),
        };
    }
    pub fn effect(self: Body) []const u8 {
        return switch (self) {
            .factory => "-- factory",
            .endpoint => "-- selector",
        };
    }
};

const network_definitions = [_]Definition{
    .{ .name = "listener", .doc = "Create a TCP listener using the Session's listen grant.", .body = .{ .factory = .listener } },
};

const process_definitions = [_]Definition{
    .{ .name = "process", .doc = "Create a process using the Session's executable grant.", .body = .{ .factory = .process } },
    .{ .name = "stdin", .doc = "Select the process's writable standard input.", .body = .{ .endpoint = .stdin } },
    .{ .name = "stdout", .doc = "Select the process's readable standard output.", .body = .{ .endpoint = .stdout } },
    .{ .name = "stderr", .doc = "Select the process's readable diagnostics.", .body = .{ .endpoint = .stderr } },
};

pub fn definitions(library: Library) []const Definition {
    return switch (library) {
        .network => &network_definitions,
        .process => &process_definitions,
    };
}

const InstanceState = struct {
    allocator: std.mem.Allocator,
    library: Library,
    refs: std.atomic.Value(usize) = .init(1),
    next_identity: std.atomic.Value(u64) = .init(1),
    fn capability(self: *InstanceState) *Instance {
        return @ptrCast(self);
    }
};

/// A host service owns one instance. Published bindings and retained selectors
/// pin that instance; closing a service never recycles its issuing identity.
pub const Instance = opaque {
    fn state(self: *Instance) *InstanceState {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(allocator: std.mem.Allocator, library: Library) error{OutOfMemory}!*Instance {
        const owned = try allocator.create(InstanceState);
        owned.* = .{ .allocator = allocator, .library = library };
        return owned.capability();
    }
    pub fn retain(self: *Instance) void {
        _ = self.state().refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Instance) void {
        const owned = self.state();
        if (owned.refs.fetchSub(1, .acq_rel) == 1) owned.allocator.destroy(owned);
    }
    pub fn declarations(self: *Instance) []const Definition {
        return definitions(self.state().library);
    }
    /// Borrows the instance on both outcomes. Success owns a separate pin and
    /// the returned heap reference; failure publishes no capability.
    pub fn seal(self: *Instance, index: usize) error{OutOfMemory}!Value {
        const allocator = self.state().allocator;
        const owned = try allocator.create(RegisteredState);
        errdefer allocator.destroy(owned);
        owned.* = .{ .instance = self, .definition = self.declarations()[index].body };
        const identity = self.state().next_identity.fetchAdd(1, .monotonic);
        const result = switch (owned.definition) {
            .factory => try heap.createBorrowedPort(RegisteredCapability, .factory, allocator, identity, owned.capability()),
            .endpoint => try heap.createBorrowedPort(RegisteredCapability, .endpoint_selector, allocator, identity, owned.capability()),
        };
        self.retain();
        return result;
    }
};

const RegisteredState = struct {
    instance: *Instance,
    definition: Body,
    fn capability(self: *RegisteredState) *RegisteredCapability {
        return @ptrCast(self);
    }
};

pub const RegisteredCapability = opaque {
    fn state(self: *RegisteredCapability) *RegisteredState {
        return @ptrCast(@alignCast(self));
    }
    pub fn fromValue(item: Value, comptime role: @import("value.zig").PortVariant) ?*RegisteredCapability {
        if (item != .port) return null;
        return heap.portPayload(RegisteredCapability, role, item.port);
    }
    pub fn instance(self: *RegisteredCapability) *Instance {
        return self.state().instance;
    }
    pub fn definition(self: *RegisteredCapability) Body {
        return self.state().definition;
    }
    pub fn releasePort(self: *RegisteredCapability) void {
        const owned = self.state();
        const issuer = owned.instance;
        issuer.state().allocator.destroy(owned);
        issuer.release();
    }
};

const EndpointState = struct {
    cell: *process.ProcessCell,
    kind: EndpointKind,
    fn capability(self: *EndpointState) *Endpoint {
        return @ptrCast(self);
    }
};

pub const ProcessReader = struct { cell: *process.ProcessCell, stream: process.Stream };

/// An attenuated borrow pins resource metadata, without owning its scope or
/// keeping its backend open. Reader exclusion and write ordering belong to
/// the resource's transports and are shared with the domain words.
pub const Endpoint = opaque {
    fn state(self: *Endpoint) *EndpointState {
        return @ptrCast(@alignCast(self));
    }
    pub fn fromValue(item: Value) ?*Endpoint {
        if (item != .port) return null;
        return heap.portPayload(Endpoint, .endpoint, item.port);
    }
    pub fn reader(self: *Endpoint) ?ProcessReader {
        const owned = self.state();
        return switch (owned.kind) {
            .stdin => null,
            .stdout => .{ .cell = owned.cell, .stream = .stdout },
            .stderr => .{ .cell = owned.cell, .stream = .stderr },
        };
    }
    pub fn writer(self: *Endpoint) ?*process.ProcessCell {
        const owned = self.state();
        return switch (owned.kind) {
            .stdin => owned.cell,
            .stdout, .stderr => null,
        };
    }
    pub fn releasePort(self: *Endpoint) void {
        const owned = self.state();
        const cell = owned.cell;
        cell.allocator.destroy(owned);
        cell.releaseReadiness();
    }
};

/// Borrows both arguments. Success owns one resource pin and one endpoint
/// value; failure neither changes scope ownership nor retains a partial pin.
pub fn borrowEndpoint(parent: Value, selector: *RegisteredCapability) error{ OutOfMemory, WrongKind }!Value {
    const cell = process.fromValue(parent) orelse return error.WrongKind;
    if (cell.instance != selector.instance()) return error.WrongKind;
    const owned = try cell.allocator.create(EndpointState);
    errdefer cell.allocator.destroy(owned);
    owned.* = .{ .cell = cell, .kind = selector.definition().endpoint };
    const identity = cell.instance.state().next_identity.fetchAdd(1, .monotonic);
    const result = try heap.createBorrowedPort(Endpoint, .endpoint, cell.allocator, identity, owned.capability());
    cell.retainReadiness();
    return result;
}
