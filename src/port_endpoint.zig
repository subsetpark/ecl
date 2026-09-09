//! The registered endpoint boundary. Backend types occur only at registration;
//! consumers hold directional capabilities and never dispatch on their source.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const bytes = @import("port_bytes.zig");
const messages = @import("port_messages.zig");
const Value = @import("value.zig").Value;

pub const Direction = enum { reader, writer, sender, receiver };
pub const BorrowError = error{ OutOfMemory, WrongKind, Unsupported };

const SelectorState = struct {
    allocator: std.mem.Allocator,
    payload: *anyopaque,
    borrow: *const fn (*anyopaque, Value) BorrowError!Value,
    release: *const fn (*anyopaque) void,
};

pub const Selector = opaque {
    fn state(self: *Selector) *SelectorState {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes the adapter reference. Failure leaves it owned by the
    /// caller. The adapter validates issuing identity before lending an endpoint.
    pub fn create(comptime Adapter: type, identity: u64, adapter: *Adapter) error{OutOfMemory}!Value {
        const allocator = adapter.allocator();
        const Bridge = struct {
            fn borrow(raw: *anyopaque, source: Value) BorrowError!Value {
                const typed: *Adapter = @ptrCast(@alignCast(raw));
                return typed.borrowEndpoint(source);
            }
            fn release(raw: *anyopaque) void {
                const typed: *Adapter = @ptrCast(@alignCast(raw));
                typed.releasePort();
            }
        };
        const owned = try allocator.create(SelectorState);
        errdefer allocator.destroy(owned);
        owned.* = .{ .allocator = allocator, .payload = adapter, .borrow = Bridge.borrow, .release = Bridge.release };
        return heap.createBorrowedPort(Selector, .endpoint_selector, allocator, identity, @ptrCast(owned));
    }
    pub fn fromValue(item: Value) ?*Selector {
        if (item != .port) return null;
        return heap.portPayload(Selector, .endpoint_selector, item.port);
    }
    pub fn borrow(self: *Selector, source: Value) BorrowError!Value {
        return self.state().borrow(self.state().payload, source);
    }
    pub fn releasePort(self: *Selector) void {
        const owned = self.state();
        owned.release(owned.payload);
        owned.allocator.destroy(owned);
    }
};

const ReaderTable = struct {
    begin: *const fn (*anyopaque) error{Busy}!void,
    end: *const fn (*anyopaque) void,
    capacity: *const fn (*anyopaque) usize,
    read: *const fn (*anyopaque, []u8) bytes.Read,
    source: *const fn (*anyopaque) external.ReadinessSource,
};
const WriterTable = struct {
    begin: *const fn (*anyopaque, std.mem.Allocator) error{ OutOfMemory, Finished }!*WritePermit,
    finish: *const fn (*anyopaque) void,
};
const State = struct {
    allocator: std.mem.Allocator,
    payload: *anyopaque,
    release: *const fn (*anyopaque) void,
    direction: union(Direction) {
        reader: *const ReaderTable,
        writer: *const WriterTable,
        sender: *messages.Queue,
        receiver: *messages.Queue,
    },
};

pub const Endpoint = opaque {
    fn state(self: *Endpoint) *State {
        return @ptrCast(@alignCast(self));
    }
    /// Consumes one adapter reference only on success. The adapter pins its
    /// transport for the endpoint lifetime without acquiring scope ownership.
    pub fn create(comptime Adapter: type, comptime direction: Direction, identity: u64, adapter: *Adapter) error{OutOfMemory}!Value {
        const allocator = adapter.allocator();
        const Bridge = struct {
            fn typed(raw: *anyopaque) *Adapter {
                return @ptrCast(@alignCast(raw));
            }
            fn release(raw: *anyopaque) void {
                typed(raw).releasePort();
            }
            fn beginRead(raw: *anyopaque) error{Busy}!void {
                return typed(raw).beginRead();
            }
            fn endRead(raw: *anyopaque) void {
                typed(raw).endRead();
            }
            fn capacity(raw: *anyopaque) usize {
                return typed(raw).readCapacity();
            }
            fn read(raw: *anyopaque, destination: []u8) bytes.Read {
                return typed(raw).read(destination);
            }
            fn source(raw: *anyopaque) external.ReadinessSource {
                return typed(raw).readSource();
            }
            fn beginWrite(raw: *anyopaque, memory: std.mem.Allocator) error{ OutOfMemory, Finished }!*WritePermit {
                // Prepare erased permit storage before admitting a backend turn.
                // Failure consumes neither a turn nor an adapter reference.
                const permit = try memory.create(PermitState);
                errdefer memory.destroy(permit);
                const backend = try typed(raw).beginWrite();
                permit.* = .{ .allocator = memory, .payload = backend, .table = &PermitBridge(Adapter).table };
                return @ptrCast(permit);
            }
            fn finish(raw: *anyopaque) void {
                typed(raw).finish();
            }
            const reader: ReaderTable = .{ .begin = beginRead, .end = endRead, .capacity = capacity, .read = read, .source = source };
            const writer: WriterTable = .{ .begin = beginWrite, .finish = finish };
        };
        const owned = try allocator.create(State);
        errdefer allocator.destroy(owned);
        owned.* = .{ .allocator = allocator, .payload = adapter, .release = Bridge.release, .direction = switch (direction) {
            .reader => .{ .reader = &Bridge.reader },
            .writer => .{ .writer = &Bridge.writer },
            .sender => .{ .sender = adapter.sender().? },
            .receiver => .{ .receiver = adapter.receiver().? },
        } };
        return heap.createBorrowedPort(Endpoint, .endpoint, allocator, identity, @ptrCast(owned));
    }
    pub fn fromValue(item: Value) ?*Endpoint {
        if (item != .port) return null;
        return heap.portPayload(Endpoint, .endpoint, item.port);
    }
    pub fn reader(self: *Endpoint) ?*Reader {
        return if (self.state().direction == .reader) @ptrCast(self) else null;
    }
    pub fn writer(self: *Endpoint) ?*Writer {
        return if (self.state().direction == .writer) @ptrCast(self) else null;
    }
    pub fn sender(self: *Endpoint) ?*messages.Queue {
        return switch (self.state().direction) {
            .sender => |queue| queue,
            .reader, .writer, .receiver => null,
        };
    }
    pub fn receiver(self: *Endpoint) ?*messages.Queue {
        return switch (self.state().direction) {
            .receiver => |queue| queue,
            .reader, .writer, .sender => null,
        };
    }
    pub fn releasePort(self: *Endpoint) void {
        const owned = self.state();
        owned.release(owned.payload);
        owned.allocator.destroy(owned);
    }
};

/// A borrow bounded by its originating endpoint value. Exclusion is shared
/// with all other views of the same underlying transport.
pub const Reader = opaque {
    fn state(self: *Reader) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn beginRead(self: *Reader) error{Busy}!void {
        return self.state().direction.reader.begin(self.state().payload);
    }
    pub fn endRead(self: *Reader) void {
        self.state().direction.reader.end(self.state().payload);
    }
    pub fn readCapacity(self: *Reader) usize {
        return self.state().direction.reader.capacity(self.state().payload);
    }
    pub fn read(self: *Reader, destination: []u8) bytes.Read {
        return self.state().direction.reader.read(self.state().payload, destination);
    }
    pub fn readSource(self: *Reader) external.ReadinessSource {
        return self.state().direction.reader.source(self.state().payload);
    }
};

pub const Writer = opaque {
    fn state(self: *Writer) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn beginWrite(self: *Writer) error{ OutOfMemory, Finished }!*WritePermit {
        return self.state().direction.writer.begin(self.state().payload, self.state().allocator);
    }
    pub fn finish(self: *Writer) void {
        self.state().direction.writer.finish(self.state().payload);
    }
};

const PermitTable = struct {
    write: *const fn (*anyopaque, []const u8) bytes.Write,
    source: *const fn (*anyopaque) external.ReadinessSource,
    finish: *const fn (*anyopaque) void,
    cancel: *const fn (*anyopaque) void,
};
const PermitState = struct { allocator: std.mem.Allocator, payload: *anyopaque, table: *const PermitTable };
fn PermitBridge(comptime Adapter: type) type {
    return struct {
        fn typed(raw: *anyopaque) *Adapter.Permit {
            return @ptrCast(@alignCast(raw));
        }
        fn write(raw: *anyopaque, source_bytes: []const u8) bytes.Write {
            return Adapter.writeBytes(typed(raw), source_bytes);
        }
        fn source(raw: *anyopaque) external.ReadinessSource {
            return typed(raw).source();
        }
        fn finish(raw: *anyopaque) void {
            typed(raw).finish();
        }
        fn cancel(raw: *anyopaque) void {
            typed(raw).cancel();
        }
        const table: PermitTable = .{ .write = write, .source = source, .finish = finish, .cancel = cancel };
    };
}

/// Owns one complete write turn and its resource pin. Finish and cancellation
/// each consume this capability, including its independent wrapper storage.
pub const WritePermit = opaque {
    fn state(self: *WritePermit) *PermitState {
        return @ptrCast(@alignCast(self));
    }
    pub fn write(self: *WritePermit, source_bytes: []const u8) bytes.Write {
        return self.state().table.write(self.state().payload, source_bytes);
    }
    pub fn source(self: *WritePermit) external.ReadinessSource {
        return self.state().table.source(self.state().payload);
    }
    pub fn finish(self: *WritePermit) void {
        const owned = self.state();
        owned.table.finish(owned.payload);
        owned.allocator.destroy(owned);
    }
    pub fn cancel(self: *WritePermit) void {
        const owned = self.state();
        owned.table.cancel(owned.payload);
        owned.allocator.destroy(owned);
    }
};
