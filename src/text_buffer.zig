//! Byte storage whose single mutation always owns its input.
//!
//! The edit buffer and the pending unit both hand out a slice of the bytes
//! they hold and both grow those bytes, so a caller can pass a borrow of the
//! storage straight back into a mutation and have it freed mid-copy. That
//! defect appeared independently in both, which is the signature of a missing
//! shared primitive rather than two separate mistakes. Containers that store
//! bytes are built on this, so there is one place that can get it wrong.
const std = @import("std");

/// Concatenations at or below this need no allocation: a keystroke, a scalar,
/// a transposed pair, a line's trailing newline.
const inline_capacity = 16;

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    storage: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) TextBuffer {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *TextBuffer) void {
        self.storage.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn items(self: *const TextBuffer) []const u8 {
        return self.storage.items;
    }
    pub fn len(self: *const TextBuffer) usize {
        return self.storage.items.len;
    }
    /// Replace `items()[start..end]` with the concatenation of `sources`.
    ///
    /// Every source is copied before the storage is touched, so a source may
    /// be a slice of the very bytes being replaced. Capacity for the result is
    /// reserved before anything is written, so a failure leaves the buffer
    /// exactly as it was rather than half-updated.
    pub fn splice(
        self: *TextBuffer,
        start: usize,
        end: usize,
        sources: []const []const u8,
    ) error{OutOfMemory}!void {
        var total: usize = 0;
        for (sources) |source| total += source.len;
        var inline_storage: [inline_capacity]u8 = undefined;
        const staged = if (total <= inline_capacity)
            inline_storage[0..total]
        else
            try self.allocator.alloc(u8, total);
        defer if (total > inline_capacity) self.allocator.free(staged);
        var offset: usize = 0;
        for (sources) |source| {
            @memcpy(staged[offset..][0..source.len], source);
            offset += source.len;
        }
        try self.storage.ensureTotalCapacity(
            self.allocator,
            self.storage.items.len - (end - start) + total,
        );
        self.storage.replaceRangeAssumeCapacity(start, end - start, staged);
    }
    pub fn takeOwned(self: *TextBuffer) error{OutOfMemory}![]u8 {
        return self.storage.toOwnedSlice(self.allocator);
    }
};

test "text buffer splices sources that alias its own storage" {
    var text = TextBuffer.init(std.testing.allocator);
    defer text.deinit();
    try text.splice(0, 0, &.{ "abc", "de" });
    try std.testing.expectEqualStrings("abcde", text.items());

    // Appending the buffer to itself repeatedly forces reallocation while the
    // source is a slice of the storage being grown.
    for (0..12) |_| try text.splice(text.len(), text.len(), &.{text.items()});
    try std.testing.expectEqual(@as(usize, 5 * 4096), text.len());
    for (text.items(), 0..) |byte, index| try std.testing.expectEqual("abcde"[index % 5], byte);

    // A source may also alias the range it replaces, in either order.
    try text.splice(0, text.len(), &.{ text.items()[3..5], text.items()[0..3] });
    try std.testing.expectEqualStrings("deabc", text.items());
}
