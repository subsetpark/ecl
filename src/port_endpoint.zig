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

const RegisteredCapability = @import("native_port.zig").RegisteredCapability;
pub const Selector = opaque {
    fn capability(self: *Selector) *RegisteredCapability {
        return @ptrCast(self);
    }
    /// Success consumes the registration reference; failure retains it.
    pub fn create(identity: u64, registration: *RegisteredCapability) error{OutOfMemory}!Value {
        return heap.createBorrowedPort(Selector, .endpoint_selector, registration.allocator(), identity, @ptrCast(registration));
    }
    pub fn fromValue(item: Value) ?*Selector {
        if (item != .port) return null;
        return heap.portPayload(Selector, .endpoint_selector, item.port);
    }
    pub fn borrow(self: *Selector, source: Value) BorrowError!Value {
        return self.capability().borrowEndpoint(source);
    }
    pub fn releasePort(self: *Selector) void {
        self.capability().releasePort();
    }
};

const ReaderTable = struct {
    begin: *const fn (*anyopaque) error{Busy}!void,
    end: *const fn (*anyopaque) void,
    capacity: *const fn (*anyopaque) usize,
    read: *const fn (*anyopaque, []u8) bytes.Read,
    source: *const fn (*anyopaque) external.ReadinessSource,
    /// Present when the endpoint is its own resource, as a file reader is,
    /// so closing the endpoint closes it. A borrowed endpoint has none: it
    /// closes with the resource or device that issued it.
    closer: ?*const CloserTable,
};
const CloserTable = struct {
    close: *const fn (*anyopaque) void,
    joined: *const fn (*anyopaque) bool,
    source: *const fn (*anyopaque) external.ReadinessSource,
};
const WriterTable = struct {
    begin: *const fn (*anyopaque, std.mem.Allocator) error{ OutOfMemory, Finished }!*WritePermit,
    finish: *const fn (*anyopaque) void,
};
/// Bytes read from the transport ahead of what the program has consumed.
/// A line read fills it and takes one line; a plain read drains it before
/// touching the transport again. It belongs to the endpoint value, so a
/// program reading lines keeps the value it reads them through.
const Pending = struct {
    buffer: std.ArrayList(u8) = .empty,
    consumed: usize = 0,

    fn remaining(self: *const Pending) []const u8 {
        return self.buffer.items[self.consumed..];
    }
    fn consume(self: *Pending, count: usize) void {
        self.consumed += count;
        if (self.consumed == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.consumed = 0;
        }
    }
    fn compact(self: *Pending) void {
        if (self.consumed == 0) return;
        const kept = self.buffer.items.len - self.consumed;
        std.mem.copyForwards(u8, self.buffer.items[0..kept], self.buffer.items[self.consumed..]);
        self.buffer.items.len = kept;
        self.consumed = 0;
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    payload: *anyopaque,
    release: *const fn (*anyopaque) void,
    direction: union(Direction) {
        reader: struct { table: *const ReaderTable, pending: Pending = .{} },
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
            fn adapterClose(raw: *anyopaque) void {
                typed(raw).closeSource();
            }
            fn adapterCloseJoined(raw: *anyopaque) bool {
                return typed(raw).closeJoined();
            }
            fn adapterCloseReadiness(raw: *anyopaque) external.ReadinessSource {
                return typed(raw).closeReadiness();
            }
            const closer: CloserTable = .{ .close = adapterClose, .joined = adapterCloseJoined, .source = adapterCloseReadiness };
            const reader: ReaderTable = .{
                .begin = beginRead,
                .end = endRead,
                .capacity = capacity,
                .read = read,
                .source = source,
                .closer = if (@hasDecl(Adapter, "closeSource")) &closer else null,
            };
            const writer: WriterTable = .{ .begin = beginWrite, .finish = finish };
        };
        const owned = try allocator.create(State);
        errdefer allocator.destroy(owned);
        owned.* = .{ .allocator = allocator, .payload = adapter, .release = Bridge.release, .direction = switch (direction) {
            .reader => .{ .reader = .{ .table = &Bridge.reader } },
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
    /// Whether `close` reaches anything: true only for an endpoint that is
    /// its own resource.
    pub fn closable(self: *Endpoint) bool {
        return switch (self.state().direction) {
            .reader => |reader_state| reader_state.table.closer != null,
            .writer, .sender, .receiver => false,
        };
    }
    pub fn close(self: *Endpoint) void {
        const owned = self.state();
        owned.direction.reader.table.closer.?.close(owned.payload);
    }
    pub fn closeJoined(self: *Endpoint) bool {
        const owned = self.state();
        return owned.direction.reader.table.closer.?.joined(owned.payload);
    }
    pub fn closeSource(self: *Endpoint) external.ReadinessSource {
        const owned = self.state();
        return owned.direction.reader.table.closer.?.source(owned.payload);
    }
    pub fn releasePort(self: *Endpoint) void {
        const owned = self.state();
        if (owned.direction == .reader) owned.direction.reader.pending.buffer.deinit(owned.allocator);
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
    fn table(self: *Reader) *const ReaderTable {
        return self.state().direction.reader.table;
    }
    fn pending(self: *Reader) *Pending {
        return &self.state().direction.reader.pending;
    }
    pub fn beginRead(self: *Reader) error{Busy}!void {
        return self.table().begin(self.state().payload);
    }
    pub fn endRead(self: *Reader) void {
        self.table().end(self.state().payload);
    }
    pub fn readCapacity(self: *Reader) usize {
        return self.table().capacity(self.state().payload);
    }
    /// Bytes already read ahead come first; the transport is read only when
    /// none are waiting. Callers hold the read exclusion, which is what makes
    /// the pending buffer theirs.
    pub fn read(self: *Reader, destination: []u8) bytes.Read {
        const waiting = self.pending().remaining();
        if (waiting.len > 0) {
            const count = @min(waiting.len, destination.len);
            @memcpy(destination[0..count], waiting[0..count]);
            self.pending().consume(count);
            return .{ .data = count };
        }
        return self.table().read(self.state().payload, destination);
    }
    pub fn readSource(self: *Reader) external.ReadinessSource {
        return self.table().source(self.state().payload);
    }
    /// The bytes read ahead and not yet consumed.
    pub fn buffered(self: *Reader) []const u8 {
        return self.pending().remaining();
    }
    pub fn consume(self: *Reader, count: usize) void {
        self.pending().consume(count);
    }
    /// One transport read of up to `max` bytes appended to the read-ahead.
    pub fn fill(self: *Reader, max: usize) error{OutOfMemory}!bytes.Read {
        const owned = self.state();
        const waiting = self.pending();
        waiting.compact();
        try waiting.buffer.ensureUnusedCapacity(owned.allocator, max);
        const spare = waiting.buffer.unusedCapacitySlice()[0..max];
        const outcome = self.table().read(owned.payload, spare);
        if (outcome == .data) waiting.buffer.items.len += outcome.data;
        return outcome;
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
