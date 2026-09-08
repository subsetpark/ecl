//! Registered resource opening. Adapters receive bounded input and execution
//! services, never an interpreter or a backend-family discriminator.
const std = @import("std");
const heap = @import("heap.zig");
const scheduler = @import("scheduler.zig");
const external = @import("external.zig");
const message = @import("port_message.zig");
const Value = @import("value.zig").Value;
const machine = @import("machine.zig");
pub const Failure = struct {
    report: @import("port_bytes.zig").Failure,
    details: [3]?machine.ErrorDetail = @splat(null),
    pub fn init(kind: machine.ErrorKind, text: []const u8) Failure {
        return .{ .report = .init(kind, text) };
    }
};

pub const Context = struct {
    scope: *scheduler.TaskScope,
};
pub const Start = union(enum) { resource: Value, opening: *Opening, failed: Failure };
pub const Progress = union(enum) { yielded, pending: external.ReadinessSource, resource: Value, failed: Failure };

const FactoryState = struct {
    allocator: std.mem.Allocator,
    adapter: *anyopaque,
    open: *const fn (*anyopaque, Context, *const message.Validated) error{OutOfMemory}!Start,
    release: *const fn (*anyopaque) void,
};
pub const Factory = opaque {
    fn state(self: *Factory) *FactoryState {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes one adapter reference; failure retains it. The
    /// published factory pins its issuer and its immutable service grants.
    pub fn create(comptime Adapter: type, identity: u64, adapter: *Adapter) error{OutOfMemory}!Value {
        const Bridge = struct {
            fn typed(raw: *anyopaque) *Adapter {
                return @ptrCast(@alignCast(raw));
            }
            fn open(raw: *anyopaque, context: Context, config: *const message.Validated) error{OutOfMemory}!Start {
                return typed(raw).openResource(context, config);
            }
            fn release(raw: *anyopaque) void {
                typed(raw).releasePort();
            }
        };
        const allocator = adapter.allocator();
        const owned = try allocator.create(FactoryState);
        errdefer allocator.destroy(owned);
        owned.* = .{ .allocator = allocator, .adapter = adapter, .open = Bridge.open, .release = Bridge.release };
        return heap.createBorrowedPort(Factory, .factory, allocator, identity, @ptrCast(owned));
    }
    pub fn fromValue(item: Value) ?*Factory {
        if (item != .port) return null;
        return heap.portPayload(Factory, .factory, item.port);
    }
    /// Borrows configuration and factory through the returned opening's
    /// lifetime. A returned resource is owned by the caller and calling scope.
    pub fn open(self: *Factory, context: Context, config: *const message.Validated) error{OutOfMemory}!Start {
        return self.state().open(self.state().adapter, context, config);
    }
    pub fn releasePort(self: *Factory) void {
        const owned = self.state();
        owned.release(owned.adapter);
        owned.allocator.destroy(owned);
    }
};

const OpeningState = struct {
    allocator: std.mem.Allocator,
    adapter: *anyopaque,
    advance: *const fn (*anyopaque, usize) error{OutOfMemory}!Progress,
    release: *const fn (*anyopaque) void,
};
pub const Opening = opaque {
    fn state(self: *Opening) *OpeningState {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes the prepared adapter; failure retains it. Releasing
    /// an opening must retire all partial work in bounded time.
    pub fn create(comptime Adapter: type, adapter: *Adapter) error{OutOfMemory}!*Opening {
        const Bridge = struct {
            fn typed(raw: *anyopaque) *Adapter {
                return @ptrCast(@alignCast(raw));
            }
            fn advance(raw: *anyopaque, quantum: usize) error{OutOfMemory}!Progress {
                return typed(raw).advance(quantum);
            }
            fn release(raw: *anyopaque) void {
                typed(raw).release();
            }
        };
        const owned = try adapter.allocator().create(OpeningState);
        owned.* = .{ .allocator = adapter.allocator(), .adapter = adapter, .advance = Bridge.advance, .release = Bridge.release };
        return @ptrCast(owned);
    }
    pub fn advance(self: *Opening, quantum: usize) error{OutOfMemory}!Progress {
        return self.state().advance(self.state().adapter, quantum);
    }
    pub fn release(self: *Opening) void {
        const owned = self.state();
        owned.release(owned.adapter);
        owned.allocator.destroy(owned);
    }
};
