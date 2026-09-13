//! Native chunk storage with bounded, allocation-free retirement.
const std = @import("std");

pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();
        const Chunk = struct { previous: ?*Chunk, items: [64]T, used: usize = 0 };
        allocator: std.mem.Allocator,
        last: ?*Chunk = null,
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn push(self: *Self, item: T) error{OutOfMemory}!void {
            if (self.last == null or self.last.?.used == 64) {
                const chunk = try self.allocator.create(Chunk);
                // SAFETY: used starts at zero; push initializes every occupied slot.
                chunk.* = .{ .previous = self.last, .items = undefined };
                self.last = chunk;
            }
            const last = self.last.?;
            last.items[last.used] = item;
            last.used += 1;
        }
        pub fn pop(self: *Self) ?T {
            const last = self.last orelse return null;
            last.used -= 1;
            const item = last.items[last.used];
            if (last.used == 0) {
                self.last = last.previous;
                self.allocator.destroy(last);
            }
            return item;
        }
        pub fn topPtr(self: *Self) ?*T {
            const last = self.last orelse return null;
            return &last.items[last.used - 1];
        }
        pub fn isEmpty(self: *Self) bool {
            return self.last == null;
        }
    };
}
