//! Fixed-capacity byte queue shared by process pipes and sockets.
const std = @import("std");

pub const Ring = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,

    pub fn free(self: *const Ring) usize {
        return self.bytes.len - self.len;
    }

    pub fn push(self: *Ring, source: []const u8) void {
        std.debug.assert(source.len <= self.free());
        const tail = (self.head + self.len) % self.bytes.len;
        const first = @min(source.len, self.bytes.len - tail);
        @memcpy(self.bytes[tail..][0..first], source[0..first]);
        @memcpy(self.bytes[0 .. source.len - first], source[first..]);
        self.len += source.len;
    }

    pub fn pop(self: *Ring, destination: []u8) usize {
        const count = @min(destination.len, self.len);
        const first = @min(count, self.bytes.len - self.head);
        @memcpy(destination[0..first], self.bytes[self.head..][0..first]);
        @memcpy(destination[first..count], self.bytes[0 .. count - first]);
        self.head = (self.head + count) % self.bytes.len;
        self.len -= count;
        return count;
    }

    /// The longest contiguous run of queued bytes starting at the head.
    pub fn peek(self: *const Ring) []const u8 {
        const first = @min(self.len, self.bytes.len - self.head);
        return self.bytes[self.head..][0..first];
    }

    pub fn consume(self: *Ring, count: usize) void {
        std.debug.assert(count <= self.len);
        self.head = (self.head + count) % self.bytes.len;
        self.len -= count;
    }

    pub fn discard(self: *Ring) void {
        self.head = 0;
        self.len = 0;
    }
};

test "bounded ring preserves exact binary order across wrap" {
    var storage: [5]u8 = undefined;
    var ring = Ring{ .bytes = &storage };
    ring.push(&.{ 0, 255, 2, 3 });
    var first: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), ring.pop(&first));
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 2 }, &first);
    ring.push(&.{ 4, 5, 6 });
    var rest: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), ring.pop(&rest));
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, &rest);
}
