//! Resumable ordering for directory listings.
//!
//! A listing may hold up to the configured entry limit, and a full sort over
//! it is user-sized work. This cursor is the only way scheduler drivers order
//! entries: pointer collection and a bottom-up merge sort both advance one
//! bounded quantum at a time, and the sorted slice is reachable only from the
//! completed typestate. No general sort routine is callable from a driver.

const std = @import("std");
const poll = @import("poll.zig");

pub const Progress = enum { pending, complete };

/// Orders pointers to the items of a `poll.ChunkList(T)` by `lessThan`.
pub fn Orderer(comptime T: type, comptime lessThan: fn (*const T, *const T) bool) type {
    return struct {
        const Self = @This();
        const List = poll.ChunkList(T);

        const Phase = union(enum) {
            collect: List.Iterator,
            merge: Merge,
            complete,
        };
        /// One bottom-up merge pass: runs of `width` items from `source` are
        /// merged pairwise into `target`; the buffers swap roles per pass.
        const Merge = struct {
            width: usize,
            run_start: usize = 0,
            left: usize = 0,
            right: usize = 0,
            out: usize = 0,
            source_is_items: bool = true,
        };

        allocator: std.mem.Allocator,
        items: []*const T,
        scratch: []*const T,
        collected: usize = 0,
        phase: Phase,

        /// Allocates exact-size storage for `list.count` pointers; collection
        /// and ordering happen in later steps.
        pub fn init(allocator: std.mem.Allocator, list: *const List) error{OutOfMemory}!Self {
            const items = try allocator.alloc(*const T, list.count);
            errdefer allocator.free(items);
            const scratch = try allocator.alloc(*const T, list.count);
            return .{
                .allocator = allocator,
                .items = items,
                .scratch = scratch,
                .phase = .{ .collect = list.iterator() },
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.allocator.free(self.scratch);
            self.* = undefined;
        }

        /// Performs at most `budget` pointer copies or merge steps.
        pub fn advance(self: *Self, budget: usize) Progress {
            std.debug.assert(budget != 0);
            var remaining = budget;
            while (remaining != 0) : (remaining -= 1) {
                switch (self.phase) {
                    .collect => |*iterator| {
                        const item = iterator.next() orelse {
                            std.debug.assert(self.collected == self.items.len);
                            self.phase = if (self.items.len < 2) .complete else .{ .merge = .{ .width = 1 } };
                            continue;
                        };
                        self.items[self.collected] = item;
                        self.collected += 1;
                    },
                    .merge => |*merge| if (self.mergeStep(merge)) {
                        self.phase = .complete;
                        return .complete;
                    },
                    .complete => return .complete,
                }
            }
            return if (self.phase == .complete) .complete else .pending;
        }

        /// One element moved (or one run boundary crossed). Returns true when
        /// the final pass has finished and `items` holds the ordered result.
        fn mergeStep(self: *Self, merge: *Merge) bool {
            const count = self.items.len;
            const source = if (merge.source_is_items) self.items else self.scratch;
            const target = if (merge.source_is_items) self.scratch else self.items;
            if (merge.run_start >= count) {
                // Pass complete: the target now holds runs of twice the width.
                merge.source_is_items = !merge.source_is_items;
                merge.width *= 2;
                merge.run_start = 0;
                merge.left = 0;
                merge.right = 0;
                merge.out = 0;
                if (merge.width >= count) {
                    // The result lives in whichever buffer the last pass wrote.
                    // Swapping the two descriptors is O(1); copying 100,000
                    // pointers here would be one user-sized step.
                    if (!merge.source_is_items) std.mem.swap([]*const T, &self.items, &self.scratch);
                    return true;
                }
                return false;
            }
            const mid = @min(merge.run_start + merge.width, count);
            const end = @min(merge.run_start + 2 * merge.width, count);
            if (merge.out == merge.run_start) {
                merge.left = merge.run_start;
                merge.right = mid;
            }
            if (merge.left < mid and (merge.right >= end or !lessThan(source[merge.right], source[merge.left]))) {
                target[merge.out] = source[merge.left];
                merge.left += 1;
            } else if (merge.right < end) {
                target[merge.out] = source[merge.right];
                merge.right += 1;
            }
            merge.out += 1;
            if (merge.out == end) merge.run_start = end;
            return false;
        }

        /// Consumes the completed cursor and returns the ordered pointers as
        /// an owned slice; the scratch buffer is released.
        pub fn take(self: *Self) []*const T {
            std.debug.assert(self.phase == .complete);
            const result = self.items;
            self.allocator.free(self.scratch);
            // SAFETY: ownership of `items` moved to the caller and `scratch`
            // is freed; poisoning prevents a second `take` or `deinit`.
            self.* = undefined;
            return result;
        }
    };
}

const Named = struct { name: []const u8 };

fn namedLess(left: *const Named, right: *const Named) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn expectOrdered(comptime count: usize, seed: u64) !void {
    const allocator = std.testing.allocator;
    var names: [count][8]u8 = undefined;
    var list = poll.ChunkList(Named).init(allocator);
    defer list.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    for (&names) |*name| {
        for (name) |*byte| byte.* = 'a' + prng.random().uintLessThan(u8, 26);
        try list.append(.{ .name = name });
    }
    var orderer = try Orderer(Named, namedLess).init(allocator, &list);
    var steps: usize = 0;
    while (orderer.advance(64) == .pending) steps += 1;
    // Collection alone needs more than a dozen quanta at these sizes, so a
    // single-step completion would be a bounded-work regression.
    try std.testing.expect(steps > 15);
    const sorted = orderer.take();
    defer allocator.free(sorted);
    try std.testing.expectEqual(names.len, sorted.len);
    for (sorted[1..], 0..) |item, index| {
        try std.testing.expect(std.mem.order(u8, sorted[index].name, item.name) != .gt);
    }
    // Every input appears exactly once.
    var seen = [_]bool{false} ** names.len;
    for (sorted) |item| {
        const index = (@intFromPtr(item.name.ptr) - @intFromPtr(&names)) / names[0].len;
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |present| try std.testing.expect(present);
}

test "directory ordering is resumable and matches a reference sort" {
    const allocator = std.testing.allocator;
    // 1000 entries take an even number of merge passes and finish in `items`;
    // 1500 take an odd number and finish in `scratch`, so both buffer
    // outcomes reach `take` without a copy.
    try expectOrdered(1000, 7);
    try expectOrdered(1500, 11);
    var names: [4][8]u8 = .{ "dddddddd".*, "aaaaaaaa".*, "cccccccc".*, "bbbbbbbb".* };

    for ([_]usize{ 0, 1, 2, 3 }) |count| {
        var small = poll.ChunkList(Named).init(allocator);
        defer small.deinit();
        for (names[0..count]) |*name| try small.append(.{ .name = name });
        var small_orderer = try Orderer(Named, namedLess).init(allocator, &small);
        while (small_orderer.advance(1) == .pending) {}
        const ordered = small_orderer.take();
        defer allocator.free(ordered);
        try std.testing.expectEqual(count, ordered.len);
        if (ordered.len > 1) for (ordered[1..], 0..) |item, index| {
            try std.testing.expect(std.mem.order(u8, ordered[index].name, item.name) != .gt);
        };
    }
}
