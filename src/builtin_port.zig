//! Registered capabilities for typed, in-process resource backends. A library
//! instance owns identity independently of its host service's operational life.
const std = @import("std");
const Value = @import("value.zig").Value;
const process = @import("process_port.zig");
const endpoints = @import("port_endpoint.zig");
const bytes = @import("port_bytes.zig");
const factories = @import("port_factory.zig");
const external = @import("external.zig");

pub const Library = enum { network, process };
const Grant = union(Library) { network: ?*external.NetAccess, process: ?*external.ProcessAccess };
pub const Registration = struct {
    declarations: []const Definition,
    bind: *const fn (std.mem.Allocator, *const @import("machine.zig").InheritedContext) error{OutOfMemory}!*Publication,
};

pub fn registration(comptime library: Library) Registration {
    for (definitions(library)) |definition| {
        if (definition.body.library() != library) @compileError("registered capability belongs to another library");
    }
    const Binding = struct {
        fn bind(allocator: std.mem.Allocator, inherited: *const @import("machine.zig").InheritedContext) error{OutOfMemory}!*Publication {
            const grant: Grant = switch (library) {
                .network => .{ .network = inherited.net_access },
                .process => .{ .process = inherited.process_access },
            };
            const existing: ?*Instance = switch (grant) {
                .network => |access| if (access) |given| @import("net_port.zig").registeredInstance(given) else null,
                .process => |access| if (access) |given| process.registeredInstance(given) else null,
            };
            const instance = existing orelse try Instance.create(allocator, library);
            if (existing != null) instance.retain();
            errdefer instance.release();
            const owned = try allocator.create(PublicationState);
            owned.* = .{ .allocator = allocator, .instance = instance, .grant = grant };
            return @ptrCast(owned);
        }
    };
    return .{ .declarations = definitions(library), .bind = Binding.bind };
}

const PublicationState = struct {
    allocator: std.mem.Allocator,
    instance: *Instance,
    grant: Grant,
    refs: std.atomic.Value(usize) = .init(1),
};

/// Module publication binds service authority once. Language capabilities pin
/// the issuer, while their grant borrows remain enclosed by Session shutdown.
pub const Publication = opaque {
    fn state(self: *Publication) *PublicationState {
        return @ptrCast(@alignCast(self));
    }
    pub fn retain(self: *Publication) void {
        _ = self.state().refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Publication) void {
        const owned = self.state();
        if (owned.refs.fetchSub(1, .acq_rel) != 1) return;
        owned.instance.release();
        owned.allocator.destroy(owned);
    }
    pub fn declarations(self: *Publication) []const Definition {
        return self.state().instance.declarations();
    }
    pub fn seal(self: *Publication, index: usize) error{OutOfMemory}!Value {
        return self.state().instance.seal(index, self.state().grant);
    }
};
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
    fn seal(self: *Instance, index: usize, grant: Grant) error{OutOfMemory}!Value {
        const allocator = self.state().allocator;
        const owned = try allocator.create(RegisteredState);
        errdefer allocator.destroy(owned);
        owned.* = .{ .instance = self, .definition = self.declarations()[index].body, .grant = grant };
        const identity = self.state().next_identity.fetchAdd(1, .monotonic);
        const result = switch (owned.definition) {
            .factory => try factories.Factory.create(RegisteredCapability, identity, owned.capability()),
            .endpoint => try endpoints.Selector.create(RegisteredCapability, identity, owned.capability()),
        };
        self.retain();
        return result;
    }
};

const RegisteredState = struct {
    instance: *Instance,
    definition: Body,
    grant: Grant,
    fn capability(self: *RegisteredState) *RegisteredCapability {
        return @ptrCast(self);
    }
};

pub const RegisteredCapability = opaque {
    fn state(self: *RegisteredCapability) *RegisteredState {
        return @ptrCast(@alignCast(self));
    }
    pub fn instance(self: *RegisteredCapability) *Instance {
        return self.state().instance;
    }
    pub fn allocator(self: *RegisteredCapability) std.mem.Allocator {
        return self.instance().state().allocator;
    }
    pub fn definition(self: *RegisteredCapability) Body {
        return self.state().definition;
    }
    pub fn openResource(self: *RegisteredCapability, context: factories.Context, config: *const @import("port_message.zig").Validated) error{OutOfMemory}!factories.Start {
        return switch (self.definition().factory) {
            .listener => @import("net_factory.zig").open(self.state().grant.network, context, config.value()),
            .process => @import("process_factory.zig").open(self.allocator(), self.state().grant.process, context, config),
        };
    }
    pub fn borrowEndpoint(self: *RegisteredCapability, source: Value) endpoints.BorrowError!Value {
        return borrowRegisteredEndpoint(source, self);
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
    pub const Permit = process.WritePermit;
    pub fn allocator(self: *Endpoint) std.mem.Allocator {
        return self.state().cell.allocator;
    }
    fn state(self: *Endpoint) *EndpointState {
        return @ptrCast(@alignCast(self));
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
    pub fn beginRead(self: *Endpoint) error{Busy}!void {
        const stream = self.reader().?;
        stream.cell.beginRead(stream.stream) catch return error.Busy;
    }
    pub fn endRead(self: *Endpoint) void {
        const stream = self.reader().?;
        stream.cell.endRead(stream.stream);
    }
    pub fn readCapacity(self: *Endpoint) usize {
        const stream = self.reader().?;
        return stream.cell.readCapacity(stream.stream);
    }
    pub fn read(self: *Endpoint, destination: []u8) bytes.Read {
        const stream = self.reader().?;
        return switch (stream.cell.read(stream.stream, destination)) {
            .pending => .pending,
            .eof => .eof,
            .data => |count| .{ .data = count },
            .io => .{ .failed = bytes.Failure.init(.io, "process output failed") },
        };
    }
    pub fn readSource(self: *Endpoint) @import("external.zig").ReadinessSource {
        const stream = self.reader().?;
        return stream.cell.readSource(stream.stream);
    }
    pub fn beginWrite(self: *Endpoint) error{ OutOfMemory, Finished }!*Permit {
        return self.writer().?.beginWrite() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Closed => error.Finished,
        };
    }
    pub fn writeBytes(permit: *Permit, source: []const u8) bytes.Write {
        return switch (permit.write(source)) {
            .pending => .pending,
            .written => |count| .{ .written = count },
            .io => .{ .failed = bytes.Failure.init(.io, "process stdin is closed") },
        };
    }
    pub fn finish(self: *Endpoint) void {
        self.writer().?.closeInput();
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
fn borrowRegisteredEndpoint(parent: Value, selector: *RegisteredCapability) error{ OutOfMemory, WrongKind }!Value {
    const cell = process.fromValue(parent) orelse return error.WrongKind;
    if (cell.instance != selector.instance()) return error.WrongKind;
    const owned = try cell.allocator.create(EndpointState);
    errdefer cell.allocator.destroy(owned);
    owned.* = .{ .cell = cell, .kind = selector.definition().endpoint };
    const identity = cell.instance.state().next_identity.fetchAdd(1, .monotonic);
    const result = switch (owned.kind) {
        .stdin => try endpoints.Endpoint.create(Endpoint, .writer, identity, owned.capability()),
        .stdout, .stderr => try endpoints.Endpoint.create(Endpoint, .reader, identity, owned.capability()),
    };
    cell.retainReadiness();
    return result;
}
