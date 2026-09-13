//! Registered exchange observation and admission, independent of adapters.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const message = @import("port_message.zig");
const results = @import("port_result.zig");
const Value = @import("value.zig").Value;

pub const Interest = enum { completion, cleanup };
pub const Admission = union(enum) { exchange: Value, pending: external.ReadinessSource, closed, unsupported };
pub const AdmitError = error{ OutOfMemory, ScopeClosing, WrongKind };

const RegisteredCapability = @import("native_port.zig").RegisteredCapability;
pub const Selector = opaque {
    fn capability(self: *Selector) *RegisteredCapability {
        return @ptrCast(self);
    }
    /// Success consumes the registration reference; failure retains it.
    pub fn create(identity: u64, registration: *RegisteredCapability) error{OutOfMemory}!Value {
        return heap.createBorrowedPort(Selector, .operation_selector, registration.allocator(), identity, @ptrCast(registration));
    }
    pub fn fromValue(item: Value) ?*Selector {
        if (item != .port) return null;
        return heap.portPayload(Selector, .operation_selector, item.port);
    }
    pub fn messageLimits(self: *Selector) message.Limits {
        return self.capability().messageLimits();
    }
    pub fn accepts(self: *Selector, source: Value) bool {
        return self.capability().acceptsOperation(source);
    }
    pub fn begin(self: *Selector, source: Value, scope: *scheduler.TaskScope, request: *const message.Validated) AdmitError!Admission {
        return self.capability().beginOperation(source, scope, request);
    }
    pub fn releasePort(self: *Selector) void {
        self.capability().releasePort();
    }
};

const Table = struct {
    close: *const fn (*anyopaque) void,
    cancel: *const fn (*anyopaque) void,
    closed: *const fn (*anyopaque) bool,
    source: *const fn (*anyopaque, Interest) external.ReadinessSource,
    release: *const fn (*anyopaque) void,
    prepare: *const fn (*anyopaque, *anyopaque, *anyopaque) heap.PortTransferError!void,
    commit: *const fn (*anyopaque) void,
    abort: *const fn (*anyopaque) void,
};
const State = struct {
    allocator: std.mem.Allocator,
    payload: *anyopaque,
    type_id: *const u8,
    result: *results.Result,
    table: *const Table,
};
fn Bridge(comptime Adapter: type) type {
    return struct {
        var identity: u8 = 0;
        fn typed(raw: *anyopaque) *Adapter {
            return @ptrCast(@alignCast(raw));
        }
        fn close(raw: *anyopaque) void {
            typed(raw).close();
        }
        fn cancel(raw: *anyopaque) void {
            typed(raw).cancel();
        }
        fn closed(raw: *anyopaque) bool {
            return typed(raw).closed();
        }
        fn source(raw: *anyopaque, interest: Interest) external.ReadinessSource {
            return typed(raw).exchangeSource(interest);
        }
        fn release(raw: *anyopaque) void {
            typed(raw).releasePort();
        }
        fn prepare(raw: *anyopaque, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
            return typed(raw).prepareScopeTransfer(from, to);
        }
        fn commit(raw: *anyopaque) void {
            typed(raw).commitScopeTransfer();
        }
        fn abort(raw: *anyopaque) void {
            typed(raw).abortScopeTransfer();
        }
        const table: Table = .{ .close = close, .cancel = cancel, .closed = closed, .source = source, .release = release, .prepare = prepare, .commit = commit, .abort = abort };
    };
}

pub const Exchange = opaque {
    fn state(self: *Exchange) *State {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes one adapter reference, which pins the common result
    /// owner. Failure retains it without publishing an exchange capability.
    pub fn create(comptime Adapter: type, identity: u64, adapter: *Adapter) error{OutOfMemory}!Value {
        const allocator = adapter.exchangeAllocator();
        const owned = try allocator.create(State);
        errdefer allocator.destroy(owned);
        owned.* = .{ .allocator = allocator, .payload = adapter, .type_id = &Bridge(Adapter).identity, .result = adapter.exchangeResult(), .table = &Bridge(Adapter).table };
        return heap.createOwnedPort(Exchange, .exchange, allocator, identity, @ptrCast(owned));
    }
    pub fn fromValue(item: Value) ?*Exchange {
        if (item != .port) return null;
        return heap.portPayload(Exchange, .exchange, item.port);
    }
    pub fn project(comptime Adapter: type, item: Value) ?*Adapter {
        const self = fromValue(item) orelse return null;
        if (self.state().type_id != &Bridge(Adapter).identity) return null;
        return @ptrCast(@alignCast(self.state().payload));
    }
    pub fn completion(self: *Exchange) results.Completion {
        return self.state().result.completion();
    }
    pub fn claimResult(self: *Exchange, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing, Overflow }!results.Claim {
        return self.state().result.claim(scope);
    }
    pub fn close(self: *Exchange) void {
        self.state().table.close(self.state().payload);
    }
    pub fn cancel(self: *Exchange) void {
        self.state().table.cancel(self.state().payload);
    }
    pub fn closed(self: *Exchange) bool {
        return self.state().table.closed(self.state().payload);
    }
    pub fn source(self: *Exchange, interest: Interest) external.ReadinessSource {
        return self.state().table.source(self.state().payload, interest);
    }
    pub fn prepareScopeTransfer(self: *Exchange, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return self.state().table.prepare(self.state().payload, from, to);
    }
    pub fn commitScopeTransfer(self: *Exchange) void {
        self.state().table.commit(self.state().payload);
    }
    pub fn abortScopeTransfer(self: *Exchange) void {
        self.state().table.abort(self.state().payload);
    }
    pub fn releasePort(self: *Exchange) void {
        const owned = self.state();
        owned.table.release(owned.payload);
        owned.allocator.destroy(owned);
    }
};
