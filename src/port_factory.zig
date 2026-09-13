//! Registered resource opening through nominal, issuer-owned capabilities.
const heap = @import("heap.zig");
const native = @import("native_port.zig");
const scheduler = @import("scheduler.zig");
const external = @import("external.zig");
const message = @import("port_message.zig");
const Value = @import("value.zig").Value;
pub const Failure = @import("port_error_data.zig").Observation;

pub const Context = struct { scope: *scheduler.TaskScope };
pub const Start = union(enum) { resource: Value, opening: *Opening, failed: Failure };
pub const Progress = union(enum) { yielded, pending: external.ReadinessSource, resource: Value, failed: Failure };

pub const Factory = opaque {
    fn capability(self: *Factory) *native.RegisteredCapability {
        return @ptrCast(self);
    }
    /// Success consumes the registration reference; failure retains it.
    /// The registration itself stores the issuer and immutable descriptor index.
    pub fn create(identity: u64, registration: *native.RegisteredCapability) error{OutOfMemory}!Value {
        return heap.createBorrowedPort(Factory, .factory, registration.allocator(), identity, @ptrCast(registration));
    }
    pub fn messageLimits(self: *Factory) message.Limits {
        return self.capability().messageLimits();
    }
    pub fn fromValue(item: Value) ?*Factory {
        if (item != .port) return null;
        return heap.portPayload(Factory, .factory, item.port);
    }
    /// Borrows configuration and factory through the returned opening's lifetime.
    pub fn open(self: *Factory, context: Context, config: *const message.Validated) error{OutOfMemory}!Start {
        return self.capability().openResource(context, config);
    }
    pub fn releasePort(self: *Factory) void {
        self.capability().releasePort();
    }
};

/// Owns rejected-opening diagnostic work; release transfers it to retirement.
pub const Opening = opaque {
    pub fn advance(self: *Opening, quantum: usize) error{OutOfMemory}!Progress {
        return native.advanceOpening(self, quantum);
    }
    pub fn release(self: *Opening) void {
        native.retireOpening(self);
    }
};
