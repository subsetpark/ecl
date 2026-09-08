//! Borrowed resource lifecycle capabilities. The caller pins the originating
//! port value for the complete borrow; dispatch never grants backend authority
//! through an erased pointer or a language-supplied discriminator.
const heap = @import("heap.zig");
const external = @import("external.zig");
const native = @import("native_port.zig");
const net = @import("net_port.zig");
const process = @import("process_port.zig");
const Value = @import("value.zig").Value;

pub const Shutdown = union(enum) { pending, ready, unsupported, failed: native.Failure };

pub const Resource = union(enum) {
    native: *native.Cell,
    listener: *net.ListenerCell,
    connection: *net.ConnectionCell,
    process: *process.ProcessCell,

    pub fn fromValue(item: Value) ?Resource {
        if (item != .port) return null;
        if (heap.portPayload(native.Cell, .resource, item.port)) |cell| return .{ .native = cell };
        if (heap.portPayload(net.ListenerCell, .resource, item.port)) |cell| return .{ .listener = cell };
        if (heap.portPayload(net.ConnectionCell, .resource, item.port)) |cell| return .{ .connection = cell };
        if (heap.portPayload(process.ProcessCell, .resource, item.port)) |cell| return .{ .process = cell };
        return null;
    }

    pub fn close(self: Resource) void {
        switch (self) {
            inline .native, .listener => |cell| cell.close(),
            .connection => |cell| cell.abort(),
            .process => |cell| cell.kill(),
        }
    }

    /// Readiness means cleanup has joined, independently of byte drainage,
    /// output EOF, or the terminal result of an operation.
    pub fn joined(self: Resource) bool {
        return switch (self) {
            .native => |cell| cell.joined(),
            .listener => |cell| cell.drained(),
            .connection => |cell| cell.joined(),
            .process => |cell| cell.termination() != null,
        };
    }

    pub fn source(self: Resource) external.ReadinessSource {
        return switch (self) {
            .native => |cell| cell.source(1),
            .listener => |cell| cell.drainSource(),
            .connection => |cell| cell.joinSource(),
            .process => |cell| cell.waitSource(),
        };
    }

    pub fn shutdown(self: Resource) Shutdown {
        switch (self) {
            .native => |cell| return switch (cell.shutdown()) {
                .pending => .pending,
                .ready => .ready,
                .unsupported => .unsupported,
                .failed => |failure| .{ .failed = failure },
            },
            inline .listener, .connection => |cell| cell.close(),
            .process => |cell| cell.terminate(),
        }
        return if (self.joined()) .ready else .pending;
    }
};
