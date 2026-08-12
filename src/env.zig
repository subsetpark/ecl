//! Minimal M3 core/session environment and the M4 replacement seam.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const machine = @import("machine.zig");

pub const Primitive = *const fn (*machine.Machine) machine.MachineError!void;

pub const Binding = union(enum) {
    word: *value.Header,
    value: value.Value,
    primitive: Primitive,

    fn retain(self: Binding) void {
        switch (self) {
            .word => |header| heap.incRef(header),
            .value => |item| heap.retainValue(item),
            .primitive => {},
        }
    }

    fn release(self: Binding, allocator: std.mem.Allocator) void {
        switch (self) {
            .word => |header| heap.decRef(allocator, header),
            .value => |item| heap.releaseValue(allocator, item),
            .primitive => {},
        }
    }
};

/// M3 has a frozen core plus one mutable session table. M4 replaces the
/// session interior with chained cells/generations while preserving lookup's
/// late-bound contract and this binding shape.
pub const Env = struct {
    allocator: std.mem.Allocator,
    core: std.AutoHashMapUnmanaged(u32, Binding) = .empty,
    session: std.AutoHashMapUnmanaged(u32, Binding) = .empty,
    core_sealed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Env) void {
        releaseTable(self.allocator, &self.session);
        releaseTable(self.allocator, &self.core);
        self.* = undefined;
    }

    /// Every execution performs this lookup afresh; resolutions are never
    /// cached, so redefining a dependency heals callers immediately.
    pub fn lookup(self: *const Env, id: u32) ?Binding {
        return self.session.get(id) orelse self.core.get(id);
    }

    /// Retains `binding`; the caller's ownership is unchanged.
    pub fn define(
        self: *Env,
        id: u32,
        binding: Binding,
    ) error{OutOfMemory}!void {
        const slot = try self.session.getOrPut(self.allocator, id);
        binding.retain();
        if (slot.found_existing) slot.value_ptr.*.release(self.allocator);
        slot.value_ptr.* = binding;
    }

    /// Core installation is legal only before `sealCore`.
    pub fn installCore(
        self: *Env,
        id: u32,
        binding: Binding,
    ) error{OutOfMemory}!void {
        std.debug.assert(!self.core_sealed);
        const slot = try self.core.getOrPut(self.allocator, id);
        binding.retain();
        if (slot.found_existing) slot.value_ptr.*.release(self.allocator);
        slot.value_ptr.* = binding;
    }

    pub fn sealCore(self: *Env) void {
        self.core_sealed = true;
    }

    pub fn sessionCount(self: *const Env) usize {
        return self.session.count();
    }
};

fn releaseTable(
    allocator: std.mem.Allocator,
    table: *std.AutoHashMapUnmanaged(u32, Binding),
) void {
    var values = table.valueIterator();
    while (values.next()) |binding| binding.*.release(allocator);
    table.deinit(allocator);
}

fn definitionFailureProbe(allocator: std.mem.Allocator) !void {
    var environment = Env.init(allocator);
    defer environment.deinit();
    const body = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(allocator, body);
    try environment.define(1, .{ .word = body.list });
    try environment.define(1, .{ .value = .{ .int = 9 } });
}

test "environment lookup and redefine are late-bound" {
    const allocator = std.testing.allocator;
    var environment = Env.init(allocator);
    defer environment.deinit();
    try environment.installCore(1, .{ .value = .{ .int = 1 } });
    environment.sealCore();
    try std.testing.expectEqual(@as(i64, 1), environment.lookup(1).?.value.int);
    try environment.define(1, .{ .value = .{ .int = 2 } });
    try std.testing.expectEqual(@as(i64, 2), environment.lookup(1).?.value.int);
    try std.testing.expect(environment.lookup(99) == null);
}

test "environment displaced bindings release retained values" {
    const allocator = std.testing.allocator;
    var environment = Env.init(allocator);
    defer environment.deinit();
    const first = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, first);
    const second = try @import("list.zig").fromValuesGeneric(allocator, &.{.{ .int = 2 }});
    defer heap.releaseValue(allocator, second);
    try environment.define(1, .{ .word = first.list });
    try environment.define(1, .{ .word = second.list });
    try std.testing.expectEqual(second.list, environment.lookup(1).?.word);
}

test "environment definition propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        definitionFailureProbe,
        .{},
    );
}
