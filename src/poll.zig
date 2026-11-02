//! Fixed-storage cursors for resumable, non-relocating traversals.
const std = @import("std");
const heap = @import("heap.zig");

/// The common result of polling a finite cursor. `void` results carry no
/// payload, so completion remains an ordinary enum value.
pub fn Progress(comptime T: type) type {
    return if (T == void)
        enum { pending, complete }
    else
        union(enum) { pending, complete: T };
}

/// The common result of polling a stream: completion and production of one
/// item are distinct states.
pub fn StreamProgress(comptime T: type) type {
    return union(enum) { pending, complete, item: T };
}

/// A shared, decrementing allowance for one scheduler step's work. Every part
/// of a resumable traversal — element rewriting, hashing, index copying, and
/// each nested cursor — draws from the same budget, so no phase can start an
/// independent unbounded pass inside a step that has already spent its slice.
///
/// A cursor that takes a `*WorkBudget` rather than a count cannot be given one
/// budget per phase by accident: there is nothing to pass but the caller's.
pub const WorkBudget = struct {
    remaining: usize,

    pub fn init(units: usize) WorkBudget {
        std.debug.assert(units != 0);
        return .{ .remaining = units };
    }

    pub fn exhausted(self: *const WorkBudget) bool {
        return self.remaining == 0;
    }

    /// Charges one unit, or reports that the step is over.
    pub fn spend(self: *WorkBudget) bool {
        if (self.remaining == 0) return false;
        self.remaining -= 1;
        return true;
    }

    /// For a transition its caller already paid one unit for: at least one of
    /// `remaining` items, and as many more as this budget can pay for.
    pub fn chunk(self: *WorkBudget, remaining: usize) usize {
        return @min(remaining, 1) + self.take(remaining -| 1);
    }

    /// Charges the largest slice of `wanted` this budget can still pay for.
    pub fn take(self: *WorkBudget, wanted: usize) usize {
        const granted = @min(wanted, self.remaining);
        self.remaining -= granted;
        return granted;
    }
};

/// The allowance for work no unit owns: a blocking constructor or setup path
/// that runs on its caller's thread and drives a cursor to completion. Its
/// inputs must be bounded by that caller. A unit's user-sized work draws on
/// the unit's own budget instead.
pub fn unbounded() WorkBudget {
    return .{ .remaining = std.math.maxInt(usize) };
}

/// One unit of a budgeted cursor, as one transition of a single-step cursor
/// whose caller charges one unit per call. This is the only budget a
/// production caller may create outside an owner's allowance.
pub fn advanceOne(cursor: anytype) AdvanceResult(@TypeOf(cursor)) {
    var work: WorkBudget = .{ .remaining = 1 };
    return cursor.advance(&work);
}

fn AdvanceResult(comptime Pointer: type) type {
    const Cursor = @typeInfo(Pointer).pointer.child;
    return @typeInfo(@TypeOf(Cursor.advance)).@"fn".return_type.?;
}

/// Test-only budgets and drivers that exercise a cursor's resumption at a
/// chosen grain. They exist only in test builds, so production code cannot
/// use them to mint an allowance of its own.
pub const testing = if (@import("builtin").is_test) struct {
    pub fn budget(units: usize) WorkBudget {
        return .{ .remaining = units };
    }

    /// Advances a cursor against a private allowance of `units`.
    pub fn advanceWithin(cursor: anytype, units: usize) AdvanceResult(@TypeOf(cursor)) {
        var work: WorkBudget = .{ .remaining = units };
        return cursor.advance(&work);
    }

    /// Drive a fallible cursor to completion, lending it a fresh allowance of
    /// `units` on each advance. For callers that exercise a cursor's resumption at
    /// a small grain; a shared finite budget would stall once spent.
    pub fn driveInSlices(comptime T: type, cursor: anytype, units: usize) !T {
        while (true) {
            var work: WorkBudget = .{ .remaining = units };
            switch (try cursor.advance(&work)) {
                .pending => {},
                .complete => |result| return result,
            }
        }
    }
} else struct {};

/// Drive a non-failing finite cursor to its observable result.
pub fn drive(comptime T: type, cursor: anytype, args: anytype) T {
    const Cursor = @TypeOf(cursor.*);
    while (true) switch (@call(.auto, Cursor.advance, .{cursor} ++ args)) {
        .pending => {},
        .complete => |result| return result,
    };
}

/// Drive a fallible finite cursor to its observable result.
pub fn driveFallible(comptime T: type, cursor: anytype, args: anytype) !T {
    const Cursor = @TypeOf(cursor.*);
    while (true) switch (try @call(.auto, Cursor.advance, .{cursor} ++ args)) {
        .pending => {},
        .complete => |result| return result,
    };
}

pub fn driveVoid(cursor: anytype, args: anytype) void {
    const Cursor = @TypeOf(cursor.*);
    while (@call(.auto, Cursor.advance, .{cursor} ++ args) == .pending) {}
}

pub fn driveVoidFallible(cursor: anytype, args: anytype) !void {
    const Cursor = @TypeOf(cursor.*);
    while (try @call(.auto, Cursor.advance, .{cursor} ++ args) == .pending) {}
}

/// Bottom-up stable merge sort whose comparisons and copying are both
/// resumable. `Comparator` supplies `Context`, `Cursor`, `Error`, `init`,
/// `advance`, and `deinit`; `advance` returns
/// `Error!Progress(std.math.Order)`. A failed comparison ends the sort with
/// its cursor still held, so the caller can name the pair that failed;
/// `deinit` releases it with everything else.
pub fn MergeSortCursor(comptime T: type, comptime Comparator: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        scratch: []T,
        context: Comparator.Context,
        width: usize = 1,
        start: usize = 0,
        middle: usize = 0,
        end: usize = 0,
        left: usize = 0,
        right: usize = 0,
        output: usize = 0,
        run_ready: bool = false,
        source_scratch: bool = false,
        comparator: ?Comparator.Cursor = null,
        copy_index: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            items: []T,
            context: Comparator.Context,
        ) error{OutOfMemory}!Self {
            return .{
                .allocator = allocator,
                .items = items,
                .scratch = try allocator.alloc(T, items.len),
                .context = context,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.comparator) |*comparator| Comparator.deinit(comparator);
            self.allocator.free(self.scratch);
            self.* = undefined;
        }

        /// The comparison in progress, which is the failed one after `advance`
        /// returns an error.
        pub fn comparing(self: *const Self) ?*const Comparator.Cursor {
            return if (self.comparator) |*comparator| comparator else null;
        }

        /// Each merge step draws one unit, spent before its comparison so a
        /// completed comparison is never lost to an exhausted allowance; the
        /// comparator draws its own work from the same budget.
        pub fn advance(self: *Self, work: *WorkBudget) Comparator.Error!Progress(void) {
            while (true) {
                if (self.width >= self.items.len) {
                    if (!self.source_scratch) return .complete;
                    const end = self.copy_index + work.take(self.items.len - self.copy_index);
                    @memcpy(self.items[self.copy_index..end], self.scratch[self.copy_index..end]);
                    self.copy_index = end;
                    return if (self.copy_index == self.items.len) .complete else .pending;
                }
                if (!self.run_ready) {
                    if (self.start == self.items.len) {
                        self.source_scratch = !self.source_scratch;
                        self.start = 0;
                        self.width = if (self.width > self.items.len / 2)
                            self.items.len
                        else
                            self.width * 2;
                        continue;
                    }
                    self.middle = self.start + @min(self.width, self.items.len - self.start);
                    self.end = self.middle + @min(self.width, self.items.len - self.middle);
                    self.left = self.start;
                    self.right = self.middle;
                    self.output = self.start;
                    self.run_ready = true;
                }
                if (self.output == self.end) {
                    self.start = self.end;
                    self.run_ready = false;
                    continue;
                }
                const source = if (self.source_scratch) self.scratch else self.items;
                var choose_left = self.right == self.end;
                if (!choose_left and self.left != self.middle) {
                    if (self.comparator == null) {
                        if (!work.spend()) return .pending;
                        self.comparator = Comparator.init(
                            self.context,
                            source[self.left],
                            source[self.right],
                        );
                    }
                    switch (try Comparator.advance(&self.comparator.?, work)) {
                        .pending => return .pending,
                        .complete => |ordering| {
                            Comparator.deinit(&self.comparator.?);
                            self.comparator = null;
                            choose_left = ordering != .gt;
                        },
                    }
                } else if (!work.spend()) return .pending;
                const destination = if (self.source_scratch) self.items else self.scratch;
                destination[self.output] = if (choose_left) source[self.left] else source[self.right];
                if (choose_left) self.left += 1 else self.right += 1;
                self.output += 1;
            }
        }
    };
}

/// Exact-capacity, non-rehashing map used by runtime publication snapshots
/// and binding's dependency sets. Its key is nominal in entries and cursors;
/// conversion to an integer is confined to the hash-slot adapter. An
/// `enum(usize)` key is an identity, such as an address, whose low bits carry
/// alignment rather than entropy.
pub fn FixedMap(comptime K: type, comptime V: type) type {
    const key_info = switch (@typeInfo(K)) {
        .@"enum" => |info| info,
        else => @compileError("FixedMap keys must be nominal enum(u32) or enum(usize) values"),
    };
    if (key_info.tag_type != u32 and key_info.tag_type != usize)
        @compileError("FixedMap keys must be nominal enum(u32) or enum(usize) values");
    return struct {
        const Self = @This();
        pub const Entry = struct { key: K, value: V };

        allocator: std.mem.Allocator,
        slots: []?Entry,
        count_value: usize = 0,

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.count_value;
        }

        /// The number of slots, for a bounded walk that must resume at a
        /// recorded slot.
        pub fn slotCount(self: *const Self) usize {
            return self.slots.len;
        }

        /// The entry in slot `index`, if any.
        pub fn slotEntry(self: *const Self, index: usize) ?Entry {
            return self.slots[index];
        }

        pub const RawEntryProgress = StreamProgress(Entry);
        pub const RawEntryCursor = struct {
            slots: []const ?Entry,
            index: usize = 0,
            pub fn advance(self: *RawEntryCursor) RawEntryProgress {
                if (self.index == self.slots.len) return .complete;
                const maybe_entry = self.slots[self.index];
                self.index += 1;
                return if (maybe_entry) |entry| .{ .item = entry } else .pending;
            }
        };
        pub fn rawEntries(self: *const Self) RawEntryCursor {
            return .{ .slots = self.slots };
        }

        pub const RawLookupProgress = Progress(?V);
        pub const RawLookupCursor = struct {
            map: *const Self,
            key: K,
            index: usize,
            remaining: usize,
            pub fn advance(self: *RawLookupCursor) RawLookupProgress {
                if (self.remaining == 0) return .{ .complete = null };
                const maybe_entry = self.map.slots[self.index];
                self.remaining -= 1;
                self.index = (self.index + 1) & (self.map.slots.len - 1);
                const entry = maybe_entry orelse return .{ .complete = null };
                return if (entry.key == self.key) .{ .complete = entry.value } else .pending;
            }
        };
        pub fn rawLookup(self: *const Self, key: K) RawLookupCursor {
            return .{
                .map = self,
                .key = key,
                .index = slot(key, self.slots.len),
                .remaining = self.slots.len,
            };
        }

        pub const InitProgress = Progress(Self);
        pub const InitCursor = struct {
            allocator: std.mem.Allocator,
            expected: usize,
            capacity: usize = 1,
            slots: ?[]?Entry = null,
            clear_index: usize = 0,
            pub fn deinit(self: *InitCursor) void {
                if (self.slots) |slots| self.allocator.free(slots);
                self.* = undefined;
            }
            pub fn advance(self: *InitCursor) error{OutOfMemory}!InitProgress {
                if (self.slots == null) {
                    const doubled = std.math.mul(usize, @max(self.expected, 1), 2) catch
                        return error.OutOfMemory;
                    if (self.capacity < doubled) {
                        self.capacity = std.math.mul(usize, self.capacity, 2) catch
                            return error.OutOfMemory;
                        return .pending;
                    }
                    self.slots = try self.allocator.alloc(?Entry, self.capacity);
                    return .pending;
                }
                if (self.clear_index != self.slots.?.len) {
                    self.slots.?[self.clear_index] = null;
                    self.clear_index += 1;
                    return .pending;
                }
                const slots = self.slots.?;
                self.slots = null;
                return .{ .complete = .{ .allocator = self.allocator, .slots = slots } };
            }
        };
        pub fn initCursor(allocator: std.mem.Allocator, expected: usize) InitCursor {
            return .{ .allocator = allocator, .expected = expected };
        }

        pub const PutProgress = Progress(bool);
        pub const PutCursor = struct {
            map: *Self,
            key: K,
            value: V,
            index: usize,
            remaining: usize,
            pub fn advance(self: *PutCursor) PutProgress {
                std.debug.assert(self.remaining != 0);
                if (self.map.slots[self.index]) |*entry| {
                    if (entry.key == self.key) {
                        entry.value = self.value;
                        return .{ .complete = false };
                    }
                } else {
                    self.map.slots[self.index] = .{ .key = self.key, .value = self.value };
                    self.map.count_value += 1;
                    return .{ .complete = true };
                }
                self.remaining -= 1;
                self.index = (self.index + 1) & (self.map.slots.len - 1);
                return .pending;
            }
        };
        pub fn putCursor(self: *Self, key: K, value: V) PutCursor {
            return .{
                .map = self,
                .key = key,
                .value = value,
                .index = slot(key, self.slots.len),
                .remaining = self.slots.len,
            };
        }

        fn slot(key: K, capacity: usize) usize {
            if (key_info.tag_type == usize) {
                const raw: u64 = @backingInt(key);
                return @as(usize, @truncate((raw >> 4) *% 0x9E37_79B9_7F4A_7C15 >> 32)) & (capacity - 1);
            }
            const raw: u32 = @backingInt(key);
            return @as(usize, raw *% 0x9e37_79b9) & (capacity - 1);
        }
    };
}

/// A LIFO worklist whose fixed-size chunks are linked rather than relocated.
/// Growing it never copies the accumulated traversal state.
pub fn ChunkStack(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const owned_disposal: heap.OwnedDisposal = .retire;
        const chunk_len = 256;
        const Chunk = struct {
            retirement: heap.ReleaseDomain.Retirement = .{},
            previous: ?*Chunk,
            len: usize,
            items: [chunk_len]T,

            pub fn advanceRetirement(
                releases: *heap.ReleaseDomain,
                allocator: std.mem.Allocator,
                self: *Chunk,
            ) bool {
                const previous = self.previous;
                allocator.destroy(self);
                if (previous) |next| releases.retire(next, &next.retirement);
                return true;
            }
        };

        allocator: std.mem.Allocator,
        // This owns only the entry. In particular it has no pointer back into
        // Self, so moving a cursor before polling cannot leave an internal
        // link aimed at the cursor's old inline storage. It is a flag beside
        // an undefined slot rather than a `union(enum) { empty, item: T }`
        // because assigning the empty variant of a union over a large `T`
        // lowers to a memset of the whole payload, on every pop.
        // SAFETY: `first` is read only while `first_full` is set, after push
        // or pushReserved initializes it.
        first: T = undefined,
        first_full: bool = false,
        top: ?*Chunk = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            while (self.top) |chunk| {
                self.top = chunk.previous;
                self.allocator.destroy(chunk);
            }
            self.first_full = false;
        }
        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            if (self.top) |top| releases.retire(top, &top.retirement);
            self.top = null;
            self.first_full = false;
        }

        pub fn push(self: *Self, item: T) error{OutOfMemory}!void {
            if (self.firstEmpty()) {
                self.first = item;
                self.first_full = true;
                return;
            }
            if (self.top == null or self.top.?.len == chunk_len) {
                try self.allocateChunk();
            }
            self.pushHeap(item);
        }

        /// Makes the next `additional` pushes allocation-free. A fresh chunk
        /// may leave unused tail space in the prior chunk; preserving strong
        /// ownership on multi-frame transitions matters more than packing it.
        pub fn reserve(self: *Self, additional: usize) error{OutOfMemory}!void {
            std.debug.assert(additional <= chunk_len);
            const inline_available: usize = if (self.firstEmpty()) 1 else 0;
            const available = inline_available + if (self.top) |chunk| chunk_len - chunk.len else 0;
            if (available >= additional) return;
            try self.allocateChunk();
        }

        /// Commits one item after `reserve`; ownership transfer cannot fail.
        pub fn pushReserved(self: *Self, item: T) void {
            if (self.firstEmpty()) {
                self.first = item;
                self.first_full = true;
                return;
            }
            self.pushHeap(item);
        }

        pub fn pop(self: *Self) ?T {
            if (self.newestNonemptyChunk()) |location| {
                const chunk = location.chunk;
                chunk.len -= 1;
                const result = chunk.items[chunk.len];
                if (chunk.len == 0) {
                    if (chunk.previous) |previous| {
                        if (location.newer) |newer|
                            newer.previous = previous
                        else
                            self.top = previous;
                        self.allocator.destroy(chunk);
                    }
                }
                return result;
            }
            if (!self.first_full) return null;
            self.first_full = false;
            return self.first;
        }

        pub fn topPtr(self: *Self) ?*T {
            if (self.newestNonemptyChunk()) |location|
                return &location.chunk.items[location.chunk.len - 1];
            return if (self.first_full) &self.first else null;
        }

        pub fn isEmpty(self: *const Self) bool {
            var chunk = self.top;
            while (chunk) |current| : (chunk = current.previous)
                if (current.len != 0) return false;
            return self.firstEmpty();
        }

        fn firstEmpty(self: *const Self) bool {
            return !self.first_full;
        }

        fn allocateChunk(self: *Self) error{OutOfMemory}!void {
            const chunk = try self.allocator.create(Chunk);
            // SAFETY: slots are read only below `len`, after push or
            // pushReserved initializes the corresponding element.
            chunk.* = .{ .previous = self.top, .len = 0, .items = undefined };
            self.top = chunk;
        }

        const ChunkLocation = struct {
            chunk: *Chunk,
            newer: ?*Chunk,
        };

        /// `reserve` may stage an empty newest chunk while older entries stay
        /// live. Logical stack access skips that reserved storage without
        /// consuming it, and remembers the newer link so an older chunk that
        /// becomes empty can still be unlinked.
        fn newestNonemptyChunk(self: *Self) ?ChunkLocation {
            var newer: ?*Chunk = null;
            var chunk = self.top;
            while (chunk) |current| : (chunk = current.previous) {
                if (current.len != 0) return .{ .chunk = current, .newer = newer };
                newer = current;
            }
            return null;
        }

        fn pushHeap(self: *Self, item: T) void {
            const chunk = self.top.?;
            std.debug.assert(chunk.len != chunk_len);
            chunk.items[chunk.len] = item;
            chunk.len += 1;
        }
    };
}

test "ChunkStack inline entry survives moves and preserves allocation failure" {
    var no_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_storage);

    var original = ChunkStack(u32).init(fixed.allocator());
    defer original.deinit();
    try original.reserve(1);
    original.pushReserved(41);

    var moved = original;
    original = ChunkStack(u32).init(fixed.allocator());
    defer moved.deinit();
    moved.topPtr().?.* += 1;
    try std.testing.expectError(error.OutOfMemory, moved.reserve(1));
    try std.testing.expectEqual(@as(?u32, 42), moved.pop());
    try std.testing.expect(moved.isEmpty());
}

test "ChunkStack inline entry preserves deep LIFO and reserved pushes" {
    var stack = ChunkStack(usize).init(std.testing.allocator);
    defer stack.deinit();

    var next: usize = 0;
    while (next < 600) : (next += 2) {
        try stack.reserve(2);
        stack.pushReserved(next);
        stack.pushReserved(next + 1);
    }
    while (next != 0) {
        next -= 1;
        try std.testing.expectEqual(@as(?usize, next), stack.pop());
    }
    try std.testing.expect(stack.isEmpty());
}

test "ChunkStack reserve does not hide the logical top" {
    var stack = ChunkStack(usize).init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.reserve(256);

    stack.topPtr().?.* = 3;
    try std.testing.expectEqual(@as(?usize, 3), stack.pop());
    try std.testing.expectEqual(@as(?usize, 1), stack.pop());
    try std.testing.expect(stack.isEmpty());

    stack.pushReserved(4);
    stack.pushReserved(5);
    try std.testing.expectEqual(@as(?usize, 5), stack.pop());
    try std.testing.expectEqual(@as(?usize, 4), stack.pop());
    try std.testing.expect(stack.isEmpty());
}

/// An append-only sequence whose fixed-size chunks never relocate prior
/// items. Consumers materialize once into exact storage with polling.
pub fn ChunkList(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const owned_disposal: heap.OwnedDisposal = .retire;
        const chunk_len = 256;
        const Chunk = struct {
            retirement: heap.ReleaseDomain.Retirement = .{},
            next: ?*Chunk = null,
            previous: ?*Chunk = null,
            len: usize = 0,
            items: [chunk_len]T,

            pub fn advanceRetirement(
                releases: *heap.ReleaseDomain,
                allocator: std.mem.Allocator,
                self: *Chunk,
            ) bool {
                const next = self.next;
                allocator.destroy(self);
                if (next) |following| releases.retire(following, &following.retirement);
                return true;
            }
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
        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            if (self.first) |first| releases.retire(first, &first.retirement);
            self.* = .{ .allocator = self.allocator };
        }
        pub fn append(self: *Self, item: T) error{OutOfMemory}!void {
            _ = try self.appendPtr(item);
        }
        pub fn appendPtr(self: *Self, item: T) error{OutOfMemory}!*T {
            if (self.last == null or self.last.?.len == chunk_len) {
                const chunk = try self.allocator.create(Chunk);
                // SAFETY: Only slots below `len` are read, and appendPtr
                // initializes each slot before incrementing that boundary.
                chunk.* = .{ .previous = self.last, .items = undefined };
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
        pub fn reverseIterator(self: *const Self) ReverseIterator {
            return .{ .chunk = self.last, .index = if (self.last) |last| last.len else 0 };
        }
    };
}

/// An immutable map from a 32-bit name to `V`, shared between versions. `put`
/// returns a new version that copies only the nodes on its key's path, at most
/// `max_depth`, and shares every other node with the version it was made
/// from; so an edit is bounded work however large the map grows. A key is
/// its own hash: names are unique 32-bit identities, so two keys always part
/// within `max_depth` levels and no node holds colliding keys.
///
/// A version owns one reference to its root, and a node one to each child
/// and, through `Value`, to each value it holds. A node is immutable once it
/// is reachable; releasing a version's last reference to a node retires it
/// through the release domain, which releases at most `fanout` children and
/// values in one step.
///
/// `Value` supplies `retain(V)` and `release(V, *heap.ReleaseDomain)`.
pub fn PersistentMap(comptime K: type, comptime V: type, comptime Value: type) type {
    comptime {
        if (@typeInfo(K) != .@"enum" or @typeInfo(K).@"enum".tag_type != u32)
            @compileError("PersistentMap keys are 32-bit name identities");
    }
    return struct {
        const Self = @This();
        pub const Entry = struct { key: K, value: V };

        const chunk_bits = 5;
        const fanout = 1 << chunk_bits;
        pub const max_depth = (32 + chunk_bits - 1) / chunk_bits;

        root: ?*Node = null,
        count: usize = 0,

        const Slot = union { entry: Entry, child: *Node };

        const Node = struct {
            retirement: heap.ReleaseDomain.Retirement = .{},
            refs: std.atomic.Value(u32) = .init(1),
            /// The positions, of `fanout`, that hold a slot.
            occupied: u32,
            /// Of the occupied positions, those whose slot is a child node.
            branches: u32,

            fn len(self: *const Node) usize {
                return @popCount(self.occupied);
            }

            fn slots(self: *Node) []Slot {
                const base: [*]u8 = @ptrCast(self);
                const first: [*]Slot = @ptrCast(@alignCast(base + slots_offset));
                return first[0..self.len()];
            }

            fn slotsConst(self: *const Node) []const Slot {
                return @constCast(self).slots();
            }

            const slots_offset = std.mem.alignForward(usize, @sizeOf(Node), @alignOf(Slot));
            const alignment: std.mem.Alignment = .of(if (@alignOf(Node) > @alignOf(Slot)) Node else Slot);

            fn bytes(slot_count: usize) usize {
                return slots_offset + slot_count * @sizeOf(Slot);
            }

            /// A node with `occupied` and `branches` whose slots the caller
            /// fills before anything can reach it.
            fn create(allocator: std.mem.Allocator, occupied: u32, branches: u32) error{OutOfMemory}!*Node {
                const memory = try allocator.alignedAlloc(u8, alignment, bytes(@popCount(occupied)));
                const node: *Node = @ptrCast(@alignCast(memory.ptr));
                node.* = .{ .occupied = occupied, .branches = branches };
                return node;
            }

            fn destroy(self: *Node, allocator: std.mem.Allocator) void {
                const base: [*]align(alignment.toByteUnits()) u8 = @ptrCast(@alignCast(self));
                allocator.free(base[0..bytes(self.len())]);
            }

            fn retain(self: *Node) void {
                const old = self.refs.fetchAdd(1, .monotonic);
                std.debug.assert(old != 0 and old != std.math.maxInt(u32));
            }

            fn release(self: *Node, releases: *heap.ReleaseDomain) void {
                const old = self.refs.fetchSub(1, .release);
                std.debug.assert(old != 0);
                if (old != 1) return;
                _ = self.refs.load(.acquire);
                releases.retire(self, &self.retirement);
            }

            /// Constant work: at most `fanout` children and values.
            pub fn advanceRetirement(
                releases: *heap.ReleaseDomain,
                allocator: std.mem.Allocator,
                self: *Node,
            ) bool {
                for (self.slots(), 0..) |slot, index| {
                    if (self.isBranchAt(index)) slot.child.release(releases) else Value.release(slot.entry.value, releases);
                }
                self.destroy(allocator);
                return true;
            }

            /// Whether the `index`th occupied slot is a child.
            fn isBranchAt(self: *const Node, index: usize) bool {
                return self.branches & nthSetBit(self.occupied, index) != 0;
            }

            /// A second reference to every slot, for a copy that shares them.
            fn retainSlot(self: *const Node, index: usize) void {
                const slot = self.slotsConst()[index];
                if (self.isBranchAt(index)) slot.child.retain() else Value.retain(slot.entry.value);
            }
        };

        fn nthSetBit(mask: u32, index: usize) u32 {
            var remaining = mask;
            for (0..index) |_| remaining &= remaining - 1;
            return remaining & (~remaining +% 1);
        }

        fn position(key: K, depth: usize) u5 {
            return @truncate(@backingInt(key) >> @intCast(depth * chunk_bits));
        }

        fn slotIndex(occupied: u32, bit: u32) usize {
            return @popCount(occupied & (bit - 1));
        }

        /// The value at `key`, borrowed while this version is held.
        pub fn find(self: *const Self, key: K) ?V {
            var node = self.root orelse return null;
            var depth: usize = 0;
            while (true) : (depth += 1) {
                const bit = @as(u32, 1) << position(key, depth);
                if (node.occupied & bit == 0) return null;
                const slot = node.slotsConst()[slotIndex(node.occupied, bit)];
                if (node.branches & bit != 0) {
                    node = slot.child;
                    continue;
                }
                return if (slot.entry.key == key) slot.entry.value else null;
            }
        }

        /// A second reference to this version.
        pub fn retain(self: *const Self) Self {
            if (self.root) |root| root.retain();
            return self.*;
        }

        pub fn release(self: *Self, releases: *heap.ReleaseDomain) void {
            if (self.root) |root| root.release(releases);
            self.* = .{};
        }

        /// A new version with `key` bound to `value`, taking its own reference
        /// to `value`; this version is unchanged. Bounded: copies at most
        /// `max_depth` nodes of at most `fanout` slots. On failure nothing is
        /// retained.
        pub fn put(
            self: *const Self,
            allocator: std.mem.Allocator,
            releases: *heap.ReleaseDomain,
            key: K,
            value: V,
        ) error{OutOfMemory}!Self {
            var added = false;
            const root = try putIn(allocator, releases, self.root, 0, .{ .key = key, .value = value }, &added);
            return .{ .root = root, .count = self.count + @intFromBool(added) };
        }

        /// A copy of `node` with the slot at `bit` set to `replacement`, sharing
        /// every other slot. `replacement` is already owned by the caller.
        fn copyWith(
            allocator: std.mem.Allocator,
            node: ?*const Node,
            bit: u32,
            replacement: Slot,
            replacement_is_branch: bool,
        ) error{OutOfMemory}!*Node {
            const old_occupied: u32 = if (node) |old| old.occupied else 0;
            const old_branches: u32 = if (node) |old| old.branches else 0;
            const occupied = old_occupied | bit;
            const branches = if (replacement_is_branch) old_branches | bit else old_branches & ~bit;
            const copy = try Node.create(allocator, occupied, branches);
            const target = slotIndex(occupied, bit);
            const slots = copy.slots();
            var from: usize = 0;
            for (slots, 0..) |*slot, index| {
                if (index == target) {
                    slot.* = replacement;
                    if (old_occupied & bit != 0) from += 1;
                    continue;
                }
                const old = node.?;
                slot.* = old.slotsConst()[from];
                old.retainSlot(from);
                from += 1;
            }
            return copy;
        }

        fn putIn(
            allocator: std.mem.Allocator,
            releases: *heap.ReleaseDomain,
            node: ?*const Node,
            depth: usize,
            entry: Entry,
            added: *bool,
        ) error{OutOfMemory}!*Node {
            const bit = @as(u32, 1) << position(entry.key, depth);
            const existing = node orelse {
                const created = try copyWith(allocator, null, bit, .{ .entry = entry }, false);
                Value.retain(entry.value);
                added.* = true;
                return created;
            };
            if (existing.occupied & bit == 0) {
                const created = try copyWith(allocator, existing, bit, .{ .entry = entry }, false);
                Value.retain(entry.value);
                added.* = true;
                return created;
            }
            const slot = existing.slotsConst()[slotIndex(existing.occupied, bit)];
            if (existing.branches & bit != 0) {
                const child = try putIn(allocator, releases, slot.child, depth + 1, entry, added);
                return copyWith(allocator, existing, bit, .{ .child = child }, true) catch |err| {
                    child.release(releases);
                    return err;
                };
            }
            if (slot.entry.key == entry.key) {
                const created = try copyWith(allocator, existing, bit, .{ .entry = entry }, false);
                Value.retain(entry.value);
                return created;
            }
            // Two keys share this position: part them one level down.
            const child = try pair(allocator, releases, depth + 1, slot.entry, entry);
            added.* = true;
            return copyWith(allocator, existing, bit, .{ .child = child }, true) catch |err| {
                child.release(releases);
                return err;
            };
        }

        /// A node holding `kept`, which another node already holds, and the
        /// new `entry`, at the first depth their positions differ. Distinct
        /// 32-bit keys differ by `max_depth`.
        fn pair(
            allocator: std.mem.Allocator,
            releases: *heap.ReleaseDomain,
            depth: usize,
            kept: Entry,
            entry: Entry,
        ) error{OutOfMemory}!*Node {
            std.debug.assert(depth < max_depth);
            const kept_bit = @as(u32, 1) << position(kept.key, depth);
            const entry_bit = @as(u32, 1) << position(entry.key, depth);
            if (kept_bit == entry_bit) {
                const child = try pair(allocator, releases, depth + 1, kept, entry);
                const node = Node.create(allocator, kept_bit, kept_bit) catch |err| {
                    child.release(releases);
                    return err;
                };
                node.slots()[0] = .{ .child = child };
                return node;
            }
            const node = try Node.create(allocator, kept_bit | entry_bit, 0);
            const slots = node.slots();
            const kept_first = kept_bit < entry_bit;
            slots[if (kept_first) 0 else 1] = .{ .entry = kept };
            slots[if (kept_first) 1 else 0] = .{ .entry = entry };
            Value.retain(kept.value);
            Value.retain(entry.value);
            return node;
        }

        pub const RawEntryProgress = StreamProgress(Entry);
        /// Every entry of one version, one per step; the caller holds the
        /// version for the cursor's life.
        pub const RawEntryCursor = struct {
            stack: [max_depth]Frame,
            depth: usize,

            const Frame = struct { node: *const Node, index: usize };

            pub fn advance(self: *RawEntryCursor) RawEntryProgress {
                while (self.depth != 0) {
                    const frame = &self.stack[self.depth - 1];
                    const slots = frame.node.slotsConst();
                    if (frame.index == slots.len) {
                        self.depth -= 1;
                        continue;
                    }
                    const index = frame.index;
                    frame.index += 1;
                    if (frame.node.isBranchAt(index)) {
                        self.stack[self.depth] = .{ .node = slots[index].child, .index = 0 };
                        self.depth += 1;
                        continue;
                    }
                    return .{ .item = slots[index].entry };
                }
                return .complete;
            }
        };

        pub fn rawEntries(self: *const Self) RawEntryCursor {
            // SAFETY: only frames below `depth` are read, and each is written
            // before `depth` reaches past it.
            var cursor: RawEntryCursor = .{ .stack = undefined, .depth = 0 };
            if (self.root) |root| {
                cursor.stack[0] = .{ .node = root, .index = 0 };
                cursor.depth = 1;
            }
            return cursor;
        }

        pub const RawLookupProgress = Progress(?V);
        /// `find` behind the polling shape lookups share; completes on its
        /// first step.
        pub const RawLookupCursor = struct {
            map: *const Self,
            key: K,

            pub fn advance(self: *RawLookupCursor) RawLookupProgress {
                return .{ .complete = self.map.find(self.key) };
            }
        };

        pub fn rawLookup(self: *const Self, key: K) RawLookupCursor {
            return .{ .map = self, .key = key };
        }
    };
}

const PersistentMapTest = struct {
    const Key = enum(u32) { _ };
    /// A counted value: the map's references to it are what `refs` counts.
    const Cell = struct { refs: usize = 0 };
    const Map = PersistentMap(Key, *Cell, struct {
        pub fn retain(cell: *Cell) void {
            cell.refs += 1;
        }
        pub fn release(cell: *Cell, _: *heap.ReleaseDomain) void {
            cell.refs -= 1;
        }
    });

    fn drain(releases: *heap.ReleaseDomain) void {
        while (!releases.advance(64)) {}
    }

    /// Each key maps to exactly what the oracle says, and enumeration yields
    /// exactly the oracle's entries.
    fn expectMatches(map: *const Map, keys: []const u32, oracle: []const ?*Cell) !void {
        for (keys, 0..) |key, index| try std.testing.expect(std.mem.indexOfScalar(u32, keys, key).? == index);
        var expected_count: usize = 0;
        for (keys, oracle) |key, expected| {
            try std.testing.expectEqual(expected, map.find(@fromBackingInt(@intCast(key))));
            if (expected != null) expected_count += 1;
        }
        try std.testing.expectEqual(expected_count, map.count);
        var seen: usize = 0;
        var entries = map.rawEntries();
        while (true) switch (entries.advance()) {
            .pending => {},
            .item => |entry| {
                seen += 1;
                const index = std.mem.indexOfScalar(u32, keys, @backingInt(entry.key)).?;
                try std.testing.expectEqual(oracle[index].?, entry.value);
            },
            .complete => break,
        };
        try std.testing.expectEqual(expected_count, seen);
    }
};

test "PersistentMap: every version keeps its contents and releases every reference" {
    const T = PersistentMapTest;
    const allocator = std.testing.allocator;
    var releases = heap.ReleaseDomain.init(allocator);
    var prng = std.Random.DefaultPrng.init(0x169);
    const random = prng.random();

    var cells: [64]T.Cell = @splat(.{});

    // Dense small names, as interning issues them, plus keys that agree in
    // every chunk but the last, so pairs nest to the deepest level.
    var keys: [96]u32 = undefined;
    for (keys[0..48], 0..) |*key, index| key.* = @intCast(index);
    for (keys[48..80], 0..) |*key, index| key.* = @as(u32, @intCast(index + 1)) << 26 | 7;
    for (80..keys.len) |index| {
        keys[index] = random.int(u32);
        while (std.mem.indexOfScalar(u32, keys[0..index], keys[index]) != null) keys[index] = random.int(u32);
    }

    const saved = 10;
    var versions: [saved]T.Map = undefined;
    var oracles: [saved][keys.len]?*T.Cell = undefined;
    var oracle: [keys.len]?*T.Cell = @splat(null);
    var current: T.Map = .{};
    for (0..saved * 40) |step| {
        const index = random.uintLessThan(usize, keys.len);
        const cell = &cells[random.uintLessThan(usize, cells.len)];
        const next = try current.put(allocator, &releases, @fromBackingInt(@intCast(keys[index])), cell);
        current.release(&releases);
        current = next;
        oracle[index] = cell;
        if (step % 40 == 0) {
            versions[step / 40] = current.retain();
            oracles[step / 40] = oracle;
        }
    }
    try T.expectMatches(&current, &keys, &oracle);
    for (&versions, &oracles) |*version, *expected| try T.expectMatches(version, &keys, expected);

    for (&versions) |*version| version.release(&releases);
    current.release(&releases);
    T.drain(&releases);
    for (cells) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
}

test "PersistentMap: a failed put retains nothing and leaves its version whole" {
    const T = PersistentMapTest;
    var cells: [8]T.Cell = @splat(.{});
    const keys = [_]u32{ 1, 1 << 5 | 1, 1 << 10 | 1 << 5 | 1, 2 << 5 | 1, 2, 1 << 30 | 1 };
    const puts = [_]usize{ 0, 1, 2, 3, 4, 5, 0 };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var releases = heap.ReleaseDomain.init(std.testing.allocator);
        var map: T.Map = .{};
        var oracle: [keys.len]?*T.Cell = @splat(null);
        var failed = false;
        for (puts, 0..) |index, step| {
            const cell = &cells[step];
            const next = map.put(allocator, &releases, @fromBackingInt(@intCast(keys[index])), cell) catch {
                failed = true;
                break;
            };
            map.release(&releases);
            map = next;
            oracle[index] = cell;
        }
        try T.expectMatches(&map, &keys, &oracle);
        map.release(&releases);
        T.drain(&releases);
        for (cells) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
        if (!failed) break;
    }
}
