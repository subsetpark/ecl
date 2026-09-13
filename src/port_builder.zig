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

pub const Error = error{ OutOfMemory, InvalidState, InvalidValue, Overflow, DuplicateKey, Cancelled };
pub const Limits = struct { message: message.Limits = .{}, stack_slots: usize = 4096 };
pub const max_byte_chunk = 64 * 1024;
pub const max_symbol_chunk = 256;
const quantum = 64;
const Dictionary = struct {
    start: usize,
    keys: []Value,
    vals: []Value,
    phase: union(enum) { split: usize, materializing: dict.Materializer },
};
const Phase = union(enum) {
    idle,
    symbol: struct { bytes: []const u8, owned: bool = false, index: usize = 0, cursor: ?intern.InternInsertionCursor = null },
    symbol_staging: struct { bytes: []u8, filled: usize = 0 },
    byte_list: struct { bytes: []u8, materializer: list.ByteListMaterializer },
    validating: struct { message: *message.Message, purpose: enum { append, finish, child } },
    list: struct { start: usize, materializer: list.ValueMaterializer },
    dictionary: Dictionary,
    retiring: struct { next: usize, end: usize },
    ready: *message.Message,
    child_configuration: *message.Message,
    failed,
};
const State = struct {
    host: *const heap.HostCleanup,
    cancellation: union(enum) { controller: *@import("port_controller.zig").Running, cooperative: *const std.atomic.Value(bool) },
    stack: heap.OwnedValueBuffer,
    depth: usize = 0,
    footprint: message.Footprint = .{},
    limits: Limits,
    phase: Phase = .idle,

    fn cancelled(self: *State) bool {
        return switch (self.cancellation) {
            .controller => |running| running.cancelled(),
            .cooperative => |flag| flag.load(.acquire),
        };
    }
    fn requireIdle(self: *State) Error!void {
        if (self.cancelled()) return error.Cancelled;
        if (self.phase != .idle) return error.InvalidState;
    }
    fn charge(self: *State, footprint: message.Footprint) Error!void {
        if (footprint.nodes > self.limits.message.nodes - self.footprint.nodes or
            footprint.bytes > self.limits.message.bytes - self.footprint.bytes or
            footprint.capabilities > self.limits.message.capabilities - self.footprint.capabilities) return error.Overflow;
        self.footprint.nodes += footprint.nodes;
        self.footprint.bytes += footprint.bytes;
        self.footprint.capabilities += footprint.capabilities;
    }
    fn requireSlot(self: *State) Error!void {
        if (self.depth == self.stack.capacity()) return error.Overflow;
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
            .idle, .retiring, .failed => {},
            .symbol => |symbol| if (symbol.owned) self.host.allocator().free(symbol.bytes),
            .symbol_staging => |staging| self.host.allocator().free(staging.bytes),
            .byte_list => |*building| {
                building.materializer.retire(releases);
                self.host.allocator().free(building.bytes);
            },
            .validating => |validation| validation.message.retire(releases),
            .ready, .child_configuration => |ready| ready.retire(releases),
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
            .idle, .ready, .child_configuration, .symbol_staging => return .complete,
            .failed => return error.InvalidState,
            .symbol => |*symbol| {
                if (symbol.cursor) |*cursor| switch (try cursor.advance()) {
                    .pending => return .pending,
                    .complete => |id| {
                        self.pushOwned(.{ .symbol = id });
                        if (symbol.owned) self.host.allocator().free(symbol.bytes);
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
            .byte_list => |*building| switch (try building.materializer.advance(quantum)) {
                .pending => return .pending,
                .complete => |item| {
                    building.materializer.deinit();
                    self.host.allocator().free(building.bytes);
                    self.pushOwned(item);
                    self.phase = .idle;
                    return .complete;
                },
            },
            .validating => |validation| {
                var budget = poll.WorkBudget.init(quantum);
                if (try validation.message.advance(&budget) == .pending) return .pending;
                if (validation.purpose == .finish) {
                    self.phase = .{ .ready = validation.message };
                } else if (validation.purpose == .child) {
                    self.phase = .{ .child_configuration = validation.message };
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
    pub fn create(host: *const heap.HostCleanup, running: *@import("port_controller.zig").Running) error{OutOfMemory}!*Builder {
        return createConfigured(host, running, .{});
    }
    pub fn createInitializing(host: *const heap.HostCleanup, closed: *const std.atomic.Value(bool)) error{OutOfMemory}!*Builder {
        return createInitializingConfigured(host, closed, .{});
    }
    pub fn createConfigured(host: *const heap.HostCleanup, running: *@import("port_controller.zig").Running, grant: Limits) error{OutOfMemory}!*Builder {
        return createWithCancellation(host, .{ .controller = running }, grant);
    }
    pub fn createInitializingConfigured(host: *const heap.HostCleanup, closed: *const std.atomic.Value(bool), grant: Limits) error{OutOfMemory}!*Builder {
        return createWithCancellation(host, .{ .cooperative = closed }, grant);
    }
    fn createWithCancellation(host: *const heap.HostCleanup, cancellation: @FieldType(State, "cancellation"), grant: Limits) error{OutOfMemory}!*Builder {
        const state_value = try host.allocator().create(State);
        errdefer host.allocator().destroy(state_value);
        const stack = try heap.OwnedValueBuffer.init(heap.hostDomain(host), grant.stack_slots);
        state_value.* = .{ .host = host, .cancellation = cancellation, .stack = stack, .limits = grant };
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
        try self.state().requireSlot();
        try self.state().charge(.{ .nodes = 1, .bytes = 8 });
        self.state().pushOwned(.{ .int = item });
    }
    pub fn float(self: *Builder, item: f64) Error!void {
        try self.state().requireIdle();
        try self.state().requireSlot();
        try self.state().charge(.{ .nodes = 1, .bytes = 8 });
        self.state().pushOwned(.{ .float = item });
    }
    pub fn char(self: *Builder, item: u64) Error!void {
        try self.state().requireIdle();
        try self.state().requireSlot();
        const codepoint = values.unicodeScalar(item) orelse return error.InvalidValue;
        try self.state().charge(.{ .nodes = 1, .bytes = std.unicode.utf8CodepointSequenceLength(codepoint) catch return error.InvalidValue });
        self.state().pushOwned(.{ .char = codepoint });
    }
    /// Borrows text only for this call; construction finishes before returning.
    pub fn symbol(self: *Builder, bytes: []const u8) Error!void {
        try self.beginSymbol(bytes);
        try self.drive();
    }
    fn beginSymbol(self: *Builder, bytes: []const u8) Error!void {
        try self.state().requireIdle();
        try self.state().requireSlot();
        try self.state().charge(.{ .nodes = 1, .bytes = bytes.len });
        self.state().phase = .{ .symbol = .{ .bytes = bytes } };
    }
    /// Copies at most one bounded byte chunk before returning; materialization
    /// owns that copy until completion or joined retirement.
    pub fn byteList(self: *Builder, source: []const u8) Error!void {
        try self.beginBytes(source);
        try self.drive();
    }
    fn beginBytes(self: *Builder, source: []const u8) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        try owned.requireSlot();
        if (source.len > max_byte_chunk) return error.Overflow;
        try owned.charge(.{ .nodes = source.len + 1, .bytes = source.len * 8 });
        const copied = try owned.host.allocator().dupe(u8, source);
        owned.phase = .{ .byte_list = .{ .bytes = copied, .materializer = .init(owned.host.allocator(), copied) } };
    }
    /// Reserve one symbol without borrowing native storage across callbacks.
    /// Only bounded chunks, completion, or clear are admitted until it settles.
    pub fn beginSymbolChunks(self: *Builder, byte_count: usize) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        try owned.requireSlot();
        try owned.charge(.{ .nodes = 1, .bytes = byte_count });
        const buffer = try owned.host.allocator().alloc(u8, byte_count);
        owned.phase = .{ .symbol_staging = .{ .bytes = buffer } };
    }
    pub fn symbolChunk(self: *Builder, source: []const u8) Error!void {
        const owned = self.state();
        if (owned.cancelled()) return error.Cancelled;
        if (owned.phase != .symbol_staging) return error.InvalidState;
        const staging = &owned.phase.symbol_staging;
        if (source.len > max_symbol_chunk or source.len > staging.bytes.len - staging.filled) return error.Overflow;
        @memcpy(staging.bytes[staging.filled..][0..source.len], source);
        staging.filled += source.len;
    }
    pub fn endSymbol(self: *Builder) Error!void {
        try self.beginEndSymbol();
        try self.drive();
    }
    fn beginEndSymbol(self: *Builder) Error!void {
        const owned = self.state();
        if (owned.cancelled()) return error.Cancelled;
        if (owned.phase != .symbol_staging) return error.InvalidState;
        const staging = owned.phase.symbol_staging;
        if (staging.filled != staging.bytes.len) return error.InvalidValue;
        owned.phase = .{ .symbol = .{ .bytes = staging.bytes, .owned = true } };
    }
    /// Borrows input on either outcome. Success retains its validated value.
    pub fn copy(self: *Builder, input: Value) Error!void {
        try self.beginCopy(input);
        try self.drive();
    }
    fn beginCopy(self: *Builder, input: Value) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        try owned.requireSlot();
        const validating = try message.Message.create(owned.host.allocator(), input, owned.limits.message);
        owned.phase = .{ .validating = .{ .message = validating, .purpose = .append } };
    }
    /// Replace the last count completed values with one list, preserving order.
    pub fn list(self: *Builder, count: usize) Error!void {
        try self.beginList(count);
        try self.drive();
    }
    fn beginList(self: *Builder, count: usize) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        if (count > owned.depth) return error.InvalidState;
        if (count == 0) try owned.requireSlot();
        try owned.charge(.{ .nodes = 1 });
        const start = owned.depth - count;
        owned.phase = .{ .list = .{ .start = start, .materializer = .init(owned.host.allocator(), owned.stack.values()[start..owned.depth]) } };
    }
    /// Replace the last count key/value pairs with a dictionary. Duplicate keys
    /// are rejected before returning; neither partial aggregates nor words escape.
    pub fn dictionary(self: *Builder, count: usize) Error!void {
        try self.beginDictionary(count);
        try self.drive();
    }
    fn beginDictionary(self: *Builder, count: usize) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        if (count > owned.depth / 2) return error.InvalidState;
        if (count == 0) try owned.requireSlot();
        try owned.charge(.{ .nodes = 1 });
        const buffers = allocation: {
            const keys = try owned.host.allocator().alloc(Value, count);
            errdefer owned.host.allocator().free(keys);
            const vals = try owned.host.allocator().alloc(Value, count);
            break :allocation .{ .keys = keys, .vals = vals };
        };
        owned.phase = .{ .dictionary = .{ .start = owned.depth - count * 2, .keys = buffers.keys, .vals = buffers.vals, .phase = .{ .split = 0 } } };
    }
    pub fn finish(self: *Builder) Error!void {
        try self.beginFinish();
        try self.drive();
    }
    fn beginFinish(self: *Builder) Error!void {
        const owned = self.state();
        if (owned.phase == .ready) return;
        try owned.requireIdle();
        if (owned.depth != 1) return error.InvalidState;
        const validating = try message.Message.create(owned.host.allocator(), owned.stack.values()[0], owned.limits.message);
        owned.phase = .{ .validating = .{ .message = validating, .purpose = .finish } };
    }
    /// Seal only the top value as a child configuration. Earlier completed
    /// values stay owned by the builder, allowing atomic multi-child results.
    pub fn prepareChild(self: *Builder) Error!void {
        try self.beginPrepareChild();
        try self.drive();
    }
    fn beginPrepareChild(self: *Builder) Error!void {
        const owned = self.state();
        try owned.requireIdle();
        if (owned.depth == 0) return error.InvalidState;
        const validating = try message.Message.create(owned.host.allocator(), owned.stack.values()[owned.depth - 1], owned.limits.message);
        owned.phase = .{ .validating = .{ .message = validating, .purpose = .child } };
    }
    pub fn childConfiguration(self: *Builder) ?*const message.Validated {
        const owned = self.state();
        return if (owned.phase == .child_configuration) owned.phase.child_configuration.validated() else null;
    }
    /// Success replaces the configuration with a retained child. Failure
    /// leaves both arguments owned by their callers; no allocation follows
    /// the consuming transition.
    pub fn replaceChild(self: *Builder, child: Value) Error!void {
        const owned = self.state();
        if (owned.phase != .child_configuration) return error.InvalidState;
        if (child != .port or heap.portVariant(child.port) != .resource) return error.InvalidValue;
        const configuration = owned.phase.child_configuration;
        const footprint = configuration.footprint().?;
        const next: message.Footprint = .{
            .nodes = owned.footprint.nodes - footprint.nodes + 1,
            .bytes = owned.footprint.bytes - footprint.bytes,
            .capabilities = owned.footprint.capabilities - footprint.capabilities + 1,
        };
        if (next.nodes > owned.limits.message.nodes or next.capabilities > owned.limits.message.capabilities) return error.Overflow;
        heap.retainValue(child);
        owned.footprint = next;
        configuration.retire(heap.hostDomain(owned.host));
        owned.stack.replaceOwned(owned.depth - 1, child);
        owned.phase = .idle;
    }
    fn advance(self: *Builder) Error!poll.Progress(void) {
        return self.state().advance() catch |err| {
            self.state().releasePhase();
            return err;
        };
    }
    /// Construction is internally resumable, but only a live controller can
    /// own this facade and drive it to completion.
    fn drive(self: *Builder) Error!void {
        while (true) {
            if (self.state().cancelled()) return error.Cancelled;
            if (try self.advance() == .complete) return;
        }
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
    pub fn clear(self: *Builder) Error!void {
        try self.beginClear();
        try self.drive();
    }
    fn beginClear(self: *Builder) Error!void {
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

/// A persistent construction owner with no synchronous drive operation. Each
/// aggregate method begins work; advance performs one bounded materialization
/// step. Its cancellation borrow belongs to the operation that owns this builder.
pub const ResumableBuilder = opaque {
    fn capability(owned: *Builder) *ResumableBuilder {
        return @ptrCast(owned);
    }
    fn builder(self: *ResumableBuilder) *Builder {
        return @ptrCast(self);
    }
    pub fn create(host: *const heap.HostCleanup, cancellation: *const std.atomic.Value(bool)) error{OutOfMemory}!*ResumableBuilder {
        return createConfigured(host, cancellation, .{});
    }
    pub fn createConfigured(host: *const heap.HostCleanup, cancellation: *const std.atomic.Value(bool), grant: Limits) error{OutOfMemory}!*ResumableBuilder {
        return ResumableBuilder.capability(try Builder.createWithCancellation(host, .{ .cooperative = cancellation }, grant));
    }
    pub fn retire(self: *ResumableBuilder) void {
        self.builder().retire();
    }
    pub fn int(self: *ResumableBuilder, item: i64) Error!void {
        return self.builder().int(item);
    }
    pub fn float(self: *ResumableBuilder, item: f64) Error!void {
        return self.builder().float(item);
    }
    pub fn char(self: *ResumableBuilder, item: u64) Error!void {
        return self.builder().char(item);
    }
    /// Borrows bytes through completion of advance or retirement.
    pub fn symbol(self: *ResumableBuilder, bytes: []const u8) Error!void {
        return self.builder().beginSymbol(bytes);
    }
    pub fn byteList(self: *ResumableBuilder, source: []const u8) Error!void {
        return self.builder().beginBytes(source);
    }
    pub fn beginSymbolChunks(self: *ResumableBuilder, byte_count: usize) Error!void {
        return self.builder().beginSymbolChunks(byte_count);
    }
    pub fn symbolChunk(self: *ResumableBuilder, source: []const u8) Error!void {
        return self.builder().symbolChunk(source);
    }
    pub fn endSymbol(self: *ResumableBuilder) Error!void {
        return self.builder().beginEndSymbol();
    }
    pub fn copy(self: *ResumableBuilder, input: Value) Error!void {
        return self.builder().beginCopy(input);
    }
    pub fn list(self: *ResumableBuilder, count: usize) Error!void {
        return self.builder().beginList(count);
    }
    pub fn dictionary(self: *ResumableBuilder, count: usize) Error!void {
        return self.builder().beginDictionary(count);
    }
    pub fn finish(self: *ResumableBuilder) Error!void {
        return self.builder().beginFinish();
    }
    pub fn prepareChild(self: *ResumableBuilder) Error!void {
        return self.builder().beginPrepareChild();
    }
    pub fn childConfiguration(self: *ResumableBuilder) ?*const message.Validated {
        return self.builder().childConfiguration();
    }
    pub fn replaceChild(self: *ResumableBuilder, child: Value) Error!void {
        return self.builder().replaceChild(child);
    }
    pub fn advance(self: *ResumableBuilder) Error!poll.Progress(void) {
        if (self.builder().state().cancelled()) return error.Cancelled;
        return self.builder().advance();
    }
    pub fn validated(self: *ResumableBuilder) ?*const message.Validated {
        return self.builder().validated();
    }
    pub fn consume(self: *ResumableBuilder) Error!void {
        return self.builder().consume();
    }
    pub fn clear(self: *ResumableBuilder) Error!void {
        return self.builder().beginClear();
    }
    pub fn invalidate(self: *ResumableBuilder) void {
        self.builder().invalidate();
    }
};
