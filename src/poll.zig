//! Type-erased safe point for deep value traversals.
const std = @import("std");

pub const Error = error{ OutOfMemory, Ecl };
pub const Poller = struct {
    context: *anyopaque,
    poll_fn: *const fn (*anyopaque) Error!void,
    pub fn poll(self: Poller) Error!void {
        try self.poll_fn(self.context);
    }
};

var noop_context: u8 = 0;
fn noopPoll(_: *anyopaque) Error!void {}

/// Mandatory traversal capability for work over user-sized inputs. Even an
/// intentionally non-cancellable caller receives a real context backed by the
/// no-op implementation, so low-level traversal APIs never encode polling as
/// an optional convention.
pub const WorkContext = struct {
    poller: Poller,

    pub fn init(active: Poller) WorkContext {
        return .{ .poller = active };
    }
    pub fn unlimited() WorkContext {
        return .{ .poller = .{ .context = &noop_context, .poll_fn = noopPoll } };
    }
    pub fn step(self: WorkContext) Error!void {
        try self.poller.poll();
    }
    pub fn asPoller(self: WorkContext) Poller {
        return self.poller;
    }
    pub fn indices(self: WorkContext, start: usize, end: usize) IndexCursor {
        return .{ .work = self, .index = start, .end = end };
    }
    pub fn reverseIndices(self: WorkContext, start: usize, end: usize) ReverseIndexCursor {
        return .{ .work = self, .start = start, .index = end };
    }
    pub fn cursor(self: WorkContext, comptime T: type, items: []const T) SliceCursor(T) {
        return .{ .items = items, .indices = self.indices(0, items.len) };
    }
    pub fn chunks(self: WorkContext, bytes: []const u8) ByteChunks {
        return .{ .work = self, .bytes = bytes };
    }
};

pub const IndexCursor = struct {
    work: WorkContext,
    index: usize,
    end: usize,
    pub fn next(self: *IndexCursor) Error!?usize {
        if (self.index == self.end) return null;
        try self.work.step();
        defer self.index += 1;
        return self.index;
    }
    pub fn skip(self: *IndexCursor, count: usize) void {
        self.index = @min(self.index + count, self.end);
    }
};

pub const ReverseIndexCursor = struct {
    work: WorkContext,
    start: usize,
    index: usize,
    pub fn next(self: *ReverseIndexCursor) Error!?usize {
        if (self.index == self.start) return null;
        try self.work.step();
        self.index -= 1;
        return self.index;
    }
};

pub fn SliceCursor(comptime T: type) type {
    return struct {
        items: []const T,
        indices: IndexCursor,
        pub fn next(self: *@This()) Error!?T {
            const index = try self.indices.next() orelse return null;
            return self.items[index];
        }
    };
}

/// Returns at most 256 bytes, charging every byte before exposing the chunk.
/// Bulk standard-library work is therefore both pre-charged and hard-bounded.
pub const ByteChunks = struct {
    const max_len = 256;
    work: WorkContext,
    bytes: []const u8,
    index: usize = 0,
    pub fn next(self: *ByteChunks) Error!?[]const u8 {
        if (self.index == self.bytes.len) return null;
        const end = @min(self.index + max_len, self.bytes.len);
        var charges = self.work.indices(self.index, end);
        while (try charges.next()) |_| {}
        defer self.index = end;
        return self.bytes[self.index..end];
    }
};

/// Exact-capacity u32-to-index table for cancellable construction. It never
/// rehashes; initialization and every probe are charged to the supplied work.
pub const U32Index = struct {
    const Entry = struct { key: u32, value: usize };
    allocator: std.mem.Allocator,
    slots: []?Entry,

    pub fn init(
        allocator: std.mem.Allocator,
        expected: usize,
        work: WorkContext,
    ) Error!U32Index {
        const target = std.math.mul(usize, expected, 2) catch return error.OutOfMemory;
        var capacity: usize = 1;
        while (capacity < target) capacity = std.math.mul(usize, capacity, 2) catch
            return error.OutOfMemory;
        const slots = try allocator.alloc(?Entry, capacity);
        errdefer allocator.free(slots);
        var indices = work.indices(0, slots.len);
        while (try indices.next()) |index| slots[index] = null;
        return .{ .allocator = allocator, .slots = slots };
    }
    pub fn deinit(self: *U32Index) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }
    pub fn put(self: *U32Index, key: u32, value: usize, work: WorkContext) Error!bool {
        var index = slot(key, self.slots.len);
        for (0..self.slots.len) |_| {
            try work.step();
            if (self.slots[index]) |entry| {
                if (entry.key == key) return false;
            } else {
                self.slots[index] = .{ .key = key, .value = value };
                return true;
            }
            index = (index + 1) & (self.slots.len - 1);
        }
        unreachable;
    }
    pub fn get(self: *const U32Index, key: u32, work: WorkContext) Error!?usize {
        var index = slot(key, self.slots.len);
        for (0..self.slots.len) |_| {
            try work.step();
            const entry = self.slots[index] orelse return null;
            if (entry.key == key) return entry.value;
            index = (index + 1) & (self.slots.len - 1);
        }
        return null;
    }
    fn slot(key: u32, capacity: usize) usize {
        return @as(usize, key *% 0x9e37_79b9) & (capacity - 1);
    }
};

/// Exact-capacity, non-rehashing map used by runtime publication snapshots.
/// Construction, cloning, and probing all require the same work capability.
pub fn U32Map(comptime V: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { key: u32, value: V };

        allocator: std.mem.Allocator,
        slots: []?Entry,
        count_value: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            expected: usize,
            work: WorkContext,
        ) Error!Self {
            const doubled = std.math.mul(usize, @max(expected, 1), 2) catch
                return error.OutOfMemory;
            var capacity: usize = 1;
            while (capacity < doubled) {
                try work.step();
                capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
            }
            const slots = try allocator.alloc(?Entry, capacity);
            errdefer allocator.free(slots);
            var indices = work.indices(0, slots.len);
            while (try indices.next()) |index| slots[index] = null;
            return .{ .allocator = allocator, .slots = slots };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.count_value;
        }

        pub fn put(self: *Self, key: u32, value: V, work: WorkContext) Error!bool {
            var index = slot(key, self.slots.len);
            for (0..self.slots.len) |_| {
                try work.step();
                if (self.slots[index]) |*entry| {
                    if (entry.key == key) {
                        entry.value = value;
                        return false;
                    }
                } else {
                    self.slots[index] = .{ .key = key, .value = value };
                    self.count_value += 1;
                    return true;
                }
                index = (index + 1) & (self.slots.len - 1);
            }
            unreachable;
        }

        pub fn get(self: *const Self, key: u32, work: WorkContext) Error!?V {
            var index = slot(key, self.slots.len);
            for (0..self.slots.len) |_| {
                try work.step();
                const entry = self.slots[index] orelse return null;
                if (entry.key == key) return entry.value;
                index = (index + 1) & (self.slots.len - 1);
            }
            return null;
        }

        pub fn cloneGrow(self: *const Self, extra: usize, work: WorkContext) Error!Self {
            var result = try Self.init(self.allocator, self.count_value + extra, work);
            errdefer result.deinit();
            var cursor = work.cursor(?Entry, self.slots);
            while (try cursor.next()) |maybe_entry| if (maybe_entry) |entry| {
                _ = try result.put(entry.key, entry.value, work);
            };
            return result;
        }

        pub fn entries(self: *const Self, work: WorkContext) EntryCursor {
            return .{ .cursor = work.cursor(?Entry, self.slots) };
        }

        pub const EntryCursor = struct {
            cursor: SliceCursor(?Entry),
            pub fn next(self: *EntryCursor) Error!?Entry {
                while (try self.cursor.next()) |maybe_entry| {
                    if (maybe_entry) |entry| return entry;
                }
                return null;
            }
        };

        fn slot(key: u32, capacity: usize) usize {
            return @as(usize, key *% 0x9e37_79b9) & (capacity - 1);
        }
    };
}

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

/// An append-only sequence whose fixed-size chunks never relocate prior
/// items. Consumers materialize once into exact storage with polling.
pub fn ChunkList(comptime T: type) type {
    return struct {
        const Self = @This();
        const chunk_len = 256;
        const Chunk = struct {
            next: ?*Chunk = null,
            previous: ?*Chunk = null,
            len: usize = 0,
            items: [chunk_len]T = undefined,
        };
        pub const Iterator = struct {
            chunk: ?*const Chunk,
            index: usize = 0,
            pub fn next(self: *Iterator) ?*const T {
                const current = self.chunk orelse return null;
                if (self.index == current.len) {
                    self.chunk = current.next;
                    self.index = 0;
                    return self.next();
                }
                defer self.index += 1;
                return &current.items[self.index];
            }
        };
        pub const WorkIterator = struct {
            inner: Iterator,
            work: WorkContext,
            pub fn next(self: *WorkIterator) Error!?*const T {
                const item = self.inner.next() orelse return null;
                try self.work.step();
                return item;
            }
        };
        pub const ReverseIterator = struct {
            chunk: ?*const Chunk,
            index: usize,
            pub fn next(self: *ReverseIterator) ?*const T {
                const current = self.chunk orelse return null;
                if (self.index == 0) {
                    self.chunk = current.previous;
                    self.index = if (self.chunk) |previous| previous.len else 0;
                    return self.next();
                }
                self.index -= 1;
                return &current.items[self.index];
            }
        };
        pub const ReverseWorkIterator = struct {
            inner: ReverseIterator,
            work: WorkContext,
            pub fn next(self: *ReverseWorkIterator) Error!?*const T {
                const item = self.inner.next() orelse return null;
                try self.work.step();
                return item;
            }
        };

        allocator: std.mem.Allocator,
        first: ?*Chunk = null,
        last: ?*Chunk = null,
        count: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            var current = self.first;
            while (current) |chunk| {
                current = chunk.next;
                self.allocator.destroy(chunk);
            }
            self.* = .{ .allocator = self.allocator };
        }
        pub fn append(self: *Self, item: T) error{OutOfMemory}!void {
            _ = try self.appendPtr(item);
        }
        pub fn appendPtr(self: *Self, item: T) error{OutOfMemory}!*T {
            if (self.last == null or self.last.?.len == chunk_len) {
                const chunk = try self.allocator.create(Chunk);
                chunk.* = .{ .previous = self.last };
                if (self.last) |last| last.next = chunk else self.first = chunk;
                self.last = chunk;
            }
            const chunk = self.last.?;
            chunk.items[chunk.len] = item;
            chunk.len += 1;
            self.count += 1;
            return &chunk.items[chunk.len - 1];
        }
        pub fn lastItem(self: *const Self) ?*const T {
            const chunk = self.last orelse return null;
            return if (chunk.len == 0) null else &chunk.items[chunk.len - 1];
        }
        pub fn iterator(self: *const Self) Iterator {
            return .{ .chunk = self.first };
        }
        pub fn workIterator(self: *const Self, work: WorkContext) WorkIterator {
            return .{ .inner = self.iterator(), .work = work };
        }
        pub fn reverseIterator(self: *const Self) ReverseIterator {
            return .{ .chunk = self.last, .index = if (self.last) |last| last.len else 0 };
        }
        pub fn reverseWorkIterator(self: *const Self, work: WorkContext) ReverseWorkIterator {
            return .{ .inner = self.reverseIterator(), .work = work };
        }
        pub fn toOwnedSlice(self: *const Self, work: WorkContext) Error![]T {
            const result = try self.allocator.alloc(T, self.count);
            errdefer self.allocator.free(result);
            var iterator_state = self.workIterator(work);
            var index: usize = 0;
            while (try iterator_state.next()) |item| : (index += 1) {
                result[index] = item.*;
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
