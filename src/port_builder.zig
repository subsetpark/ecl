//! Host-owned, resumable structured message construction for native controllers.
const std = @import("std");
const heap = @import("heap.zig");
const values = @import("value.zig");
const Value = values.Value;
const message = @import("port_message.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");

pub const Error = error{ OutOfMemory, InvalidState, InvalidValue, Overflow, DuplicateKey };
const limits: message.Limits = .{};
const quantum = 64;
const Dictionary = struct {
    start: usize,
    keys: []Value,
    vals: []Value,
    phase: union(enum) { split: usize, materializing: dict.Materializer },
};
const Phase = union(enum) {
    idle,
    symbol: struct { bytes: []const u8, index: usize = 0, cursor: ?intern.InternInsertionCursor = null },
    validating: struct { message: *message.Message, purpose: enum { append, finish } },
    list: struct { start: usize, materializer: list.ValueMaterializer },
    dictionary: Dictionary,
    retiring: struct { next: usize, end: usize },
    ready: *message.Message,
    failed,
};
const State = struct {
    host: *const heap.HostCleanup,
    stack: heap.OwnedValueBuffer,
    depth: usize = 0,
    footprint: message.Footprint = .{},
    phase: Phase = .idle,

    fn requireIdle(self: *State) Error!void {
        if (self.phase != .idle) return error.InvalidState;
    }
    fn charge(self: *State, footprint: message.Footprint) Error!void {
        if (footprint.nodes > limits.nodes - self.footprint.nodes or
            footprint.bytes > limits.bytes - self.footprint.bytes or
            footprint.capabilities > limits.capabilities - self.footprint.capabilities) return error.Overflow;
        self.footprint.nodes += footprint.nodes;
        self.footprint.bytes += footprint.bytes;
        self.footprint.capabilities += footprint.capabilities;
    }
    fn pushOwned(self: *State, item: Value) void {
        if (self.depth == self.stack.len()) self.stack.appendOwned(item) else self.stack.replaceOwned(self.depth, item);
        self.depth += 1;
    }
    fn finishAggregate(self: *State, start: usize, item: Value) void {
        const end = self.depth;
        self.depth = start;
        self.pushOwned(item);
        self.phase = .{ .retiring = .{ .next = @min(start + 1, end), .end = end } };
    }
    fn releasePhase(self: *State) void {
        const releases = heap.hostDomain(self.host);
        switch (self.phase) {
            .idle, .symbol, .retiring, .failed => {},
            .validating => |validation| validation.message.retire(releases),
            .ready => |ready| ready.retire(releases),
            .list => |*building| building.materializer.retire(releases),
            .dictionary => |*building| {
                switch (building.phase) {
                    .split => {},
                    .materializing => |*materializer| materializer.retire(releases),
                }
                self.host.allocator().free(building.keys);
                self.host.allocator().free(building.vals);
            },
        }
        self.phase = .failed;
    }
    fn advance(self: *State) Error!poll.Progress(void) {
        switch (self.phase) {
            .idle, .ready => return .complete,
            .failed => return error.InvalidState,
            .symbol => |*symbol| {
                if (symbol.cursor) |*cursor| switch (try cursor.advance()) {
                    .pending => return .pending,
                    .complete => |id| {
                        self.pushOwned(.{ .symbol = id });
                        self.phase = .idle;
                        return .complete;
                    },
                };
                var budget = poll.WorkBudget.init(quantum);
                while (symbol.index < symbol.bytes.len and budget.spend()) {
                    const count = std.unicode.utf8ByteSequenceLength(symbol.bytes[symbol.index]) catch return error.InvalidValue;
                    if (count > symbol.bytes.len - symbol.index) return error.InvalidValue;
                    _ = std.unicode.utf8Decode(symbol.bytes[symbol.index..][0..count]) catch return error.InvalidValue;
                    symbol.index += count;
                }
                if (symbol.index == symbol.bytes.len) symbol.cursor = intern.insertionCursor(symbol.bytes);
                return .pending;
            },
            .validating => |validation| {
                var budget = poll.WorkBudget.init(quantum);
                if (try validation.message.advance(&budget) == .pending) return .pending;
                if (validation.purpose == .finish) {
                    self.phase = .{ .ready = validation.message };
                } else {
                    try self.charge(validation.message.footprint().?);
                    const item = validation.message.view().?;
                    heap.retainValue(item);
                    self.pushOwned(item);
                    validation.message.retire(heap.hostDomain(self.host));
                    self.phase = .idle;
                }
                return .complete;
            },
            .list => |*building| switch (try building.materializer.advance(quantum)) {
                .pending => return .pending,
                .complete => |item| {
                    const start = building.start;
                    building.materializer.deinit();
                    self.finishAggregate(start, item);
                    return .pending;
                },
            },
            .dictionary => |*building| switch (building.phase) {
                .split => |index| {
                    const end = @min(index + quantum, building.keys.len);
                    const source = self.stack.values();
                    for (index..end) |i| {
                        building.keys[i] = source[building.start + 2 * i];
                        building.vals[i] = source[building.start + 2 * i + 1];
                    }
                    building.phase = .{ .split = end };
                    if (end == building.keys.len) {
                        const materializer = try dict.Materializer.initBorrowedSlices(self.host.allocator(), building.keys, building.vals, true);
                        building.phase = .{ .materializing = materializer };
                    }
                    return .pending;
                },
                .materializing => |*materializer| switch (try materializer.advance(quantum)) {
                    .pending => return .pending,
                    .duplicate_key => return error.DuplicateKey,
                    .complete => |item| {
                        const start = building.start;
                        materializer.deinit();
                        self.host.allocator().free(building.keys);
                        self.host.allocator().free(building.vals);
                        self.finishAggregate(start, item);
                        return .pending;
                    },
                },
            },
            .retiring => |*retiring| {
                const end = @min(retiring.next + quantum, retiring.end);
                for (retiring.next..end) |index| self.stack.replaceOwned(index, .{ .int = 0 });
                retiring.next = end;
                if (end == retiring.end) {
                    self.phase = .idle;
                    return .complete;
                }
                return .pending;
            },
        }
    }
};

/// One controller owns the builder until return. No ECL allocator, mutable
/// value storage, or independently publishable value handle crosses the ABI.
pub const Builder = opaque {
    fn state(self: *Builder) *State {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(host: *const heap.HostCleanup) error{OutOfMemory}!*Builder {
        const state_value = try host.allocator().create(State);
        errdefer host.allocator().destroy(state_value);
        const stack = try heap.OwnedValueBuffer.init(heap.hostDomain(host), limits.nodes);
        state_value.* = .{ .host = host, .stack = stack };
        return capability(state_value);
    }
    pub fn retire(self: *Builder) void {
        const owned = self.state();
        owned.releasePhase();
        owned.stack.deinit();
        owned.host.allocator().destroy(owned);
    }
    /// These scalar constructors retain no caller storage.
    pub fn int(self: *Builder, item: i64) Error!void {
        try self.state().requireIdle();
        try self.state().charge(.{ .nodes = 1, .bytes = 8 });
        self.state().pushOwned(.{ .int = item });
    }
    pub fn float(self: *Builder, item: f64) Error!void {
        try self.state().requireIdle();
        try self.state().charge(.{ .nodes = 1, .bytes = 8 });
        self.state().pushOwned(.{ .float = item });
    }
    pub fn char(self: *Builder, item: u64) Error!void {
        try self.state().requireIdle();
        const codepoint = values.unicodeScalar(item) orelse return error.InvalidValue;
        try self.state().charge(.{ .nodes = 1, .bytes = std.unicode.utf8CodepointSequenceLength(codepoint) catch return error.InvalidValue });
        self.state().pushOwned(.{ .char = codepoint });
    }
    /// Borrows text until advance completes or fails, or the builder is cleared.
    pub fn symbol(self: *Builder, bytes: []const u8) Error!void {
        try self.state().requireIdle();
        try self.state().charge(.{ .nodes = 1, .bytes = bytes.len });
        self.state().phase = .{ .symbol = .{ .bytes = bytes } };
    }
    /// Borrows input on either outcome. Successful start pins it independently.
    pub fn copy(self: *Builder, input: Value) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        const validating = try message.Message.create(owned.host.allocator(), input, limits);
        owned.phase = .{ .validating = .{ .message = validating, .purpose = .append } };
    }
    /// Replace the last count completed values with one list, preserving order.
    pub fn list(self: *Builder, count: usize) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        if (count > owned.depth) return error.InvalidState;
        try owned.charge(.{ .nodes = 1 });
        const start = owned.depth - count;
        owned.phase = .{ .list = .{ .start = start, .materializer = .init(owned.host.allocator(), owned.stack.values()[start..owned.depth]) } };
    }
    /// Replace the last count key/value pairs with a dictionary. Duplicate keys
    /// are rejected during advance; neither partial aggregates nor words escape.
    pub fn dictionary(self: *Builder, count: usize) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        if (count > owned.depth / 2) return error.InvalidState;
        try owned.charge(.{ .nodes = 1 });
        const keys = try owned.host.allocator().alloc(Value, count);
        errdefer owned.host.allocator().free(keys);
        const vals = try owned.host.allocator().alloc(Value, count);
        owned.phase = .{ .dictionary = .{ .start = owned.depth - count * 2, .keys = keys, .vals = vals, .phase = .{ .split = 0 } } };
    }
    pub fn finish(self: *Builder) Error!void {
        const owned = self.state();
        if (owned.phase == .ready) return;
        try owned.requireIdle();
        if (owned.depth != 1) return error.InvalidState;
        const validating = try message.Message.create(owned.host.allocator(), owned.stack.values()[0], limits);
        owned.phase = .{ .validating = .{ .message = validating, .purpose = .finish } };
    }
    pub fn advance(self: *Builder) Error!poll.Progress(void) {
        return self.state().advance() catch |err| {
            self.state().releasePhase();
            return err;
        };
    }
    pub fn validated(self: *Builder) ?*const message.Validated {
        return if (self.state().phase == .ready) self.state().phase.ready.validated() else null;
    }
    /// Consumes the finished message after the caller retained its published
    /// root. Transport rejection must not invoke this transition.
    pub fn consume(self: *Builder) Error!void {
        const owned = self.state();
        if (owned.phase != .ready) return error.InvalidState;
        owned.phase.ready.retire(heap.hostDomain(owned.host));
        owned.stack.replaceOwned(0, .{ .int = 0 });
        owned.depth = 0;
        owned.footprint = .{};
        owned.phase = .idle;
    }
    pub fn clear(self: *Builder) void {
        const owned = self.state();
        owned.releasePhase();
        owned.phase = .{ .retiring = .{ .next = 0, .end = owned.stack.len() } };
        owned.depth = 0;
        owned.footprint = .{};
    }
    pub fn invalidate(self: *Builder) void {
        self.state().releasePhase();
    }
};
fn capability(state_value: *State) *Builder {
    return @ptrCast(state_value);
}
