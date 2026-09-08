//! Bounded structured-value validation for port requests, messages, and results.
//! An immutable root pins the complete traversal. Validation never executes
//! words, follows a port payload, or transfers a resource's scope ownership.
const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");
const Value = value.Value;

pub const Limits = struct {
    bytes: usize = 64 * 1024,
    nodes: usize = 4096,
    capabilities: usize = 16,
};

/// Scalars are charged by their portable representation, independently of
/// heap packing: eight bytes per number, UTF-8 bytes per character or symbol.
/// Every occurrence is a node, including containers and repeated references;
/// every port occurrence is an attachment. Container metadata is node-bounded.
pub const Footprint = struct {
    bytes: usize = 0,
    nodes: usize = 0,
    capabilities: usize = 0,
};

pub const ValidationError = error{ OutOfMemory, InvalidValue, Overflow };
const Frame = union(enum) {
    item: Value,
    sequence: struct { item: Value, next: usize, count: usize },
};
const State = struct {
    allocator: std.mem.Allocator,
    root: Value,
    limits: Limits,
    footprint: Footprint = .{},
    frames: poll.ChunkStack(Frame),
    phase: union(enum) { validating, ready, failed: ValidationError } = .validating,

    fn charge(total: *usize, amount: usize, limit: usize) error{Overflow}!void {
        if (amount > limit - total.*) return error.Overflow;
        total.* += amount;
    }

    fn visit(self: *State, item: Value) ValidationError!void {
        try charge(&self.footprint.nodes, 1, self.limits.nodes);
        switch (item) {
            .int, .float => try charge(&self.footprint.bytes, 8, self.limits.bytes),
            .char => |codepoint| {
                const scalar = value.unicodeScalar(codepoint) orelse return error.InvalidValue;
                try charge(&self.footprint.bytes, std.unicode.utf8CodepointSequenceLength(scalar) catch return error.InvalidValue, self.limits.bytes);
            },
            .symbol => |id| try charge(&self.footprint.bytes, intern.get(id).len, self.limits.bytes),
            .port => try charge(&self.footprint.capabilities, 1, self.limits.capabilities),
            .word, .task, .module => return error.InvalidValue,
            .list, .dict => {
                const count: usize = if (item == .list) @intCast(item.list.length()) else std.math.mul(usize, @intCast(item.dict.length()), 2) catch return error.Overflow;
                // Reject a wide aggregate before constructing traversal work.
                if (count > self.limits.nodes - self.footprint.nodes) return error.Overflow;
                if (count != 0) try self.frames.push(.{ .sequence = .{ .item = item, .next = 0, .count = count } });
            },
        }
    }

    fn advance(self: *State, budget: *poll.WorkBudget) ValidationError!poll.Progress(void) {
        while (budget.spend()) {
            const frame = self.frames.pop() orelse {
                self.phase = .ready;
                return .complete;
            };
            switch (frame) {
                .item => |item| try self.visit(item),
                .sequence => |sequence| {
                    const item = if (sequence.item == .list)
                        list.atUnchecked(sequence.item, sequence.next)
                    else if (sequence.next % 2 == 0)
                        dict.keyAt(sequence.item.dict, sequence.next / 2)
                    else
                        dict.valueAt(sequence.item.dict, sequence.next / 2);
                    if (sequence.next + 1 < sequence.count) try self.frames.push(.{ .sequence = .{
                        .item = sequence.item,
                        .next = sequence.next + 1,
                        .count = sequence.count,
                    } });
                    try self.visit(item);
                },
            }
        }
        return .pending;
    }
};

/// A validator owns an additional reference to the root on successful create.
/// Failure leaves the input unchanged. Only a successful complete traversal
/// grants a readable message; neither metadata nor validation can be forged.
/// The input and storage must belong to the same heap, whose release domain
/// must outlive this handle. Retire it on every terminal path.
pub const Message = opaque {
    fn state(self: *Message) *State {
        return @ptrCast(@alignCast(self));
    }

    pub fn create(allocator: std.mem.Allocator, input: Value, limits: Limits) error{OutOfMemory}!*Message {
        const state_value = try allocator.create(State);
        errdefer allocator.destroy(state_value);
        var frames = poll.ChunkStack(Frame).init(allocator);
        try frames.push(.{ .item = input });
        heap.retainValue(input);
        state_value.* = .{ .allocator = allocator, .root = input, .limits = limits, .frames = frames };
        return @ptrCast(state_value);
    }

    /// Failure is sticky. Retrying cannot skip the rejected item or obtain a
    /// partially validated message. A zero remaining budget makes no progress.
    pub fn advance(self: *Message, budget: *poll.WorkBudget) ValidationError!poll.Progress(void) {
        const state_value = self.state();
        switch (state_value.phase) {
            .ready => return .complete,
            .failed => |failure| return failure,
            .validating => {},
        }
        return state_value.advance(budget) catch |err| {
            state_value.phase = .{ .failed = err };
            return err;
        };
    }

    /// Borrow valid only until this message is retired. No scope publication
    /// or independent resource ownership is implied by retaining the value.
    pub fn view(self: *Message) ?Value {
        return if (self.state().phase == .ready) self.state().root else null;
    }

    pub fn validated(self: *Message) ?*const Validated {
        return if (self.state().phase == .ready) @ptrCast(self) else null;
    }

    pub fn footprint(self: *Message) ?Footprint {
        return if (self.state().phase == .ready) self.state().footprint else null;
    }

    /// Consumes the handle. Graph and traversal reclamation are enqueued;
    /// this call performs no input-sized walk, including after failed validation.
    pub fn retire(self: *Message, releases: *heap.ReleaseDomain) void {
        const state_value = self.state();
        state_value.frames.retire(releases);
        releases.releaseValue(state_value.root);
        state_value.allocator.destroy(state_value);
    }
};

/// Borrowed proof of a complete bounded validation, valid while Message owns
/// the immutable root. Consumers retain the root before that owner retires.
pub const Validated = opaque {
    pub fn footprint(self: *const Validated) Footprint {
        const state: *const State = @ptrCast(@alignCast(self));
        return state.footprint;
    }
    pub fn value(self: *const Validated) Value {
        const state: *const State = @ptrCast(@alignCast(self));
        return state.root;
    }
};

fn validate(message: *Message) ValidationError!void {
    while (true) {
        var budget = poll.WorkBudget.init(1);
        if (try message.advance(&budget) == .complete) return;
    }
}

test "port message: validation is bounded and pins the immutable input" {
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    const input = try list.fromValues(std.testing.allocator, &.{ .{ .int = 42 }, .{ .char = 0x1f600 }, .{ .float = 0.5 } });
    const message = try Message.create(std.testing.allocator, input, .{});
    cleanup.releaseValue(input);
    defer message.retire(cleanup.domain());
    var budget = poll.WorkBudget.init(1);
    try std.testing.expectEqual(poll.Progress(void).pending, try message.advance(&budget));
    try std.testing.expect(message.view() == null);
    try validate(message);
    try std.testing.expectEqual(Footprint{ .nodes = 4, .bytes = 20 }, message.footprint().?);
    try std.testing.expectEqual(@as(i64, 42), list.atUnchecked(message.view().?, 0).int);
}

test "port message: words are rejected recursively and failure is sticky" {
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    const words = try list.fromValues(std.testing.allocator, &.{.{ .word = .{ .name = try intern.intern("dup") } }});
    defer cleanup.releaseValue(words);
    const input = try dict.fromUniquePairs(std.testing.allocator, cleanup.domain(), &.{.{ .{ .symbol = try intern.intern("key") }, words }});
    defer cleanup.releaseValue(input);
    const message = try Message.create(std.testing.allocator, input, .{});
    defer message.retire(cleanup.domain());
    try std.testing.expectError(error.InvalidValue, validate(message));
    try std.testing.expectError(error.InvalidValue, validate(message));
    try std.testing.expect(message.view() == null);
}

test "port message: node and text budgets include repeated occurrences" {
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    const symbol: Value = .{ .symbol = try intern.intern("abcd") };
    const input = try list.fromValues(std.testing.allocator, &.{ symbol, symbol });
    defer cleanup.releaseValue(input);
    for ([_]Limits{ .{ .nodes = 2 }, .{ .bytes = 7 } }) |limits| {
        const message = try Message.create(std.testing.allocator, input, limits);
        defer message.retire(cleanup.domain());
        try std.testing.expectError(error.Overflow, validate(message));
    }
    const message = try Message.create(std.testing.allocator, input, .{ .nodes = 3, .bytes = 8 });
    defer message.retire(cleanup.domain());
    try validate(message);
    try std.testing.expectEqual(Footprint{ .nodes = 3, .bytes = 8 }, message.footprint().?);
}

test "port message: empty containers are values and capabilities count per attachment" {
    const Capability = struct {
        releases: usize = 0,
        pub fn releasePort(self: *@This()) void {
            self.releases += 1;
        }
    };
    var capability: Capability = .{};
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    const port = try heap.createBorrowedPort(Capability, .endpoint, std.testing.allocator, 1, &capability);
    const attachments = [_]Value{port} ** 17;
    const input = try list.fromValues(std.testing.allocator, &attachments);
    cleanup.releaseValue(port);
    defer cleanup.releaseValue(input);
    const rejected = try Message.create(std.testing.allocator, input, .{});
    defer rejected.retire(cleanup.domain());
    try std.testing.expectError(error.Overflow, validate(rejected));
    const accepted = try Message.create(std.testing.allocator, input, .{ .capabilities = 17 });
    defer accepted.retire(cleanup.domain());
    try validate(accepted);
    try std.testing.expectEqual(Footprint{ .nodes = 18, .capabilities = 17 }, accepted.footprint().?);
    try std.testing.expectEqual(port.port, list.atUnchecked(accepted.view().?, 0).port);

    const empty = try list.fromValues(std.testing.allocator, &.{});
    defer cleanup.releaseValue(empty);
    const empty_message = try Message.create(std.testing.allocator, empty, .{ .nodes = 1, .bytes = 0, .capabilities = 0 });
    defer empty_message.retire(cleanup.domain());
    try validate(empty_message);
    try std.testing.expectEqual(Footprint{ .nodes = 1 }, empty_message.footprint().?);
}

test "port message: cancelled deep validation retires multiple traversal chunks" {
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    var input: Value = .{ .int = 1 };
    defer cleanup.releaseValue(input);
    for (0..300) |_| {
        const parent = try list.fromValues(std.testing.allocator, &.{ input, .{ .int = 0 } });
        cleanup.releaseValue(input);
        input = parent;
    }
    const message = try Message.create(std.testing.allocator, input, .{});
    defer message.retire(cleanup.domain());
    var budget = poll.WorkBudget.init(280);
    try std.testing.expectEqual(poll.Progress(void).pending, try message.advance(&budget));
    try std.testing.expect(message.view() == null);
}

fn messageFailureProbe(allocator: std.mem.Allocator) !void {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const child = try list.fromValues(allocator, &.{.{ .int = 1 }});
    defer cleanup.releaseValue(child);
    const input = try list.fromValues(allocator, &.{ child, child });
    defer cleanup.releaseValue(input);
    const message = try Message.create(allocator, input, .{});
    defer message.retire(cleanup.domain());
    try validate(message);
    try std.testing.expectEqual(Footprint{ .nodes = 5, .bytes = 16 }, message.footprint().?);
}

test "port message: allocation failure preserves input and retires traversal" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, messageFailureProbe, .{});
}
