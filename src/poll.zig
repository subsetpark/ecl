//! Type-erased safe point for deep value traversals.
const std = @import("std");

pub const Error = error{ OutOfMemory, Ecl };
pub const Poller = struct {
    context: *anyopaque,
    poll_fn: *const fn (*anyopaque) Error!void,
    pub fn poll(self: Poller) Error!void {
        try self.poll_fn(self.context);
    }
    pub fn charge(self: Poller, amount: usize) Error!void {
        for (0..amount) |_| try self.poll();
    }
};

/// A LIFO worklist whose fixed-size chunks are linked rather than relocated.
/// Growing it never copies the accumulated traversal state.
pub fn ChunkStack(comptime T: type) type {
    return struct {
        const Self = @This();
        const chunk_len = 256;
        const Chunk = struct {
            previous: ?*Chunk,
            len: usize,
            items: [chunk_len]T,
        };

        allocator: std.mem.Allocator,
        top: ?*Chunk = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            while (self.top) |chunk| {
                self.top = chunk.previous;
                self.allocator.destroy(chunk);
            }
        }

        pub fn push(self: *Self, item: T) error{OutOfMemory}!void {
            if (self.top == null or self.top.?.len == chunk_len) {
                const chunk = try self.allocator.create(Chunk);
                // SAFETY: only slots below `len` are read, and `push` writes
                // each such slot before incrementing `len`.
                chunk.* = .{ .previous = self.top, .len = 0, .items = undefined };
                self.top = chunk;
            }
            const chunk = self.top.?;
            chunk.items[chunk.len] = item;
            chunk.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            const chunk = self.top orelse return null;
            if (chunk.len == 0) return null;
            chunk.len -= 1;
            const result = chunk.items[chunk.len];
            if (chunk.len == 0 and chunk.previous != null) {
                self.top = chunk.previous;
                self.allocator.destroy(chunk);
            }
            return result;
        }
    };
}

fn chunkStackAllocationProbe(allocator: std.mem.Allocator) !void {
    var stack = ChunkStack(usize).init(allocator);
    defer stack.deinit();
    for (0..600) |item| try stack.push(item);
    var expected: usize = 600;
    while (stack.pop()) |item| {
        expected -= 1;
        try std.testing.expectEqual(expected, item);
    }
    try std.testing.expectEqual(@as(usize, 0), expected);
}

test "chunk stacks grow without relocating prior actions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        chunkStackAllocationProbe,
        .{},
    );
}
