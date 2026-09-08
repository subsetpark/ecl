//! Registered capabilities for typed, in-process resource backends. A library
//! instance owns identity independently of its host service's operational life.
const std = @import("std");
const heap = @import("heap.zig");
const Value = @import("value.zig").Value;

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
    factory: FactoryKind,
};

const network_definitions = [_]Definition{
    .{ .name = "listener", .doc = "Create a TCP listener using the Session's listen grant.", .factory = .listener },
};

const process_definitions = [_]Definition{
    .{ .name = "process", .doc = "Create a process using the Session's executable grant.", .factory = .process },
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
        const owned = try allocator.create(FactoryState);
        errdefer allocator.destroy(owned);
        owned.* = .{ .instance = self, .kind = self.declarations()[index].factory };
        const identity = self.state().next_identity.fetchAdd(1, .monotonic);
        const result = try heap.createBorrowedPort(Factory, .factory, allocator, identity, owned.capability());
        self.retain();
        return result;
    }
};

const FactoryState = struct {
    instance: *Instance,
    kind: FactoryKind,
    fn capability(self: *FactoryState) *Factory {
        return @ptrCast(self);
    }
};

pub const Factory = opaque {
    fn state(self: *Factory) *FactoryState {
        return @ptrCast(@alignCast(self));
    }
    pub fn fromValue(item: Value) ?*Factory {
        if (item != .port) return null;
        return heap.portPayload(Factory, .factory, item.port);
    }
    pub fn instance(self: *Factory) *Instance {
        return self.state().instance;
    }
    pub fn kind(self: *Factory) FactoryKind {
        return self.state().kind;
    }
    pub fn releasePort(self: *Factory) void {
        const owned = self.state();
        const issuer = owned.instance;
        issuer.state().allocator.destroy(owned);
        issuer.release();
    }
};
