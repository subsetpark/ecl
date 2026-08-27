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

    /// Charges the largest slice of `wanted` this budget can still pay for.
    pub fn take(self: *WorkBudget, wanted: usize) usize {
        const granted = @min(wanted, self.remaining);
        self.remaining -= granted;
        return granted;
    }
};

/// Validate the finite-cursor protocol at the generic driver that consumes it.
/// This is deliberately structural rather than a global cursor registry: each
/// call supplies the exact result and argument tuple its boundary requires.
fn validateFiniteCursor(
    comptime boundary: []const u8,
    comptime T: type,
    comptime Cursor: type,
    comptime Args: type,
    comptime fallible: bool,
) void {
    const args = switch (@typeInfo(Args)) {
        .@"struct" => |info| info,
        else => @compileError(boundary ++ ": arguments must be supplied as a concrete tuple"),
    };
    if (!args.is_tuple)
        @compileError(boundary ++ ": arguments must be supplied as a concrete tuple");
    switch (@typeInfo(Cursor)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => @compileError(boundary ++ ": cursor must be a container type with an advance declaration"),
    }
    if (!@hasDecl(Cursor, "advance"))
        @compileError(boundary ++ ": cursor must declare advance");
    const advance = switch (@typeInfo(@TypeOf(Cursor.advance))) {
        .@"fn" => |info| info,
        else => @compileError(boundary ++ ": cursor advance must be a function"),
    };
    if (advance.is_generic or advance.is_var_args)
        @compileError(boundary ++ ": cursor advance must be non-generic and non-variadic");
    if (advance.params.len != args.fields.len + 1)
        @compileError(boundary ++ ": cursor advance parameter count must match the supplied argument tuple");
    if (advance.params[0].type == null or advance.params[0].type.? != *Cursor)
        @compileError(boundary ++ ": cursor advance receiver must be *Cursor");
    inline for (advance.params[1..], 1..) |parameter, index| {
        if (parameter.is_generic or parameter.type == null)
            @compileError(boundary ++ ": cursor advance parameter " ++
                std.fmt.comptimePrint("{d}", .{index}) ++ " must have a concrete type");
    }
    const actual = advance.return_type orelse
        @compileError(boundary ++ ": cursor advance must have a concrete return type");
    const Expected = Progress(T);
    if (fallible) {
        const payload = switch (@typeInfo(actual)) {
            .error_union => |info| info.payload,
            else => @compileError(boundary ++
                ": cursor advance must return an error union with payload poll.Progress(T)"),
        };
        if (payload != Expected)
            @compileError(boundary ++
                ": cursor advance must return an error union with payload poll.Progress(T)");
    } else if (actual != Expected) {
        @compileError(boundary ++ ": cursor advance must return poll.Progress(T)");
    }
}

fn validateMergeSortComparator(comptime T: type, comptime Comparator: type) void {
    const boundary = "poll.MergeSortCursor";
    if (@typeInfo(Comparator) != .@"struct")
        @compileError(boundary ++ ": comparator must be a struct spec");
    if (!@hasDecl(Comparator, "Context"))
        @compileError(boundary ++ ": comparator must declare Context");
    if (!@hasDecl(Comparator, "Cursor"))
        @compileError(boundary ++ ": comparator must declare Cursor");
    if (@TypeOf(Comparator.Context) != type)
        @compileError(boundary ++ ": comparator Context must be a type");
    if (@TypeOf(Comparator.Cursor) != type)
        @compileError(boundary ++ ": comparator Cursor must be a type");
    const Context = Comparator.Context;
    const Cursor = Comparator.Cursor;
    if (!@hasDecl(Comparator, "init"))
        @compileError(boundary ++ ": comparator must declare init");
    const init = switch (@typeInfo(@TypeOf(Comparator.init))) {
        .@"fn" => |info| info,
        else => @compileError(boundary ++ ": comparator init must be a function"),
    };
    if (init.is_generic or init.is_var_args or init.params.len != 3 or
        init.params[0].type == null or init.params[0].type.? != Context or
        init.params[1].type == null or init.params[1].type.? != T or
        init.params[2].type == null or init.params[2].type.? != T or
        init.return_type == null or init.return_type.? != Cursor)
    {
        @compileError(boundary ++ ": comparator init must have signature fn (Context, T, T) Cursor");
    }
    if (!@hasDecl(Comparator, "advance"))
        @compileError(boundary ++ ": comparator must declare advance");
    const advance = switch (@typeInfo(@TypeOf(Comparator.advance))) {
        .@"fn" => |info| info,
        else => @compileError(boundary ++ ": comparator advance must be a function"),
    };
    if (advance.is_generic or advance.is_var_args or advance.params.len != 2 or
        advance.params[0].type == null or advance.params[0].type.? != *Cursor or
        advance.params[1].type == null or advance.params[1].type.? != usize or
        advance.return_type == null or advance.return_type.? != Progress(std.math.Order))
    {
        @compileError(boundary ++
            ": comparator advance must have signature fn (*Cursor, usize) poll.Progress(std.math.Order)");
    }
}

/// Drive a non-failing finite cursor to its observable result.
pub fn drive(comptime T: type, cursor: anytype, args: anytype) T {
    const Cursor = @TypeOf(cursor.*);
    comptime validateFiniteCursor("poll.drive", T, Cursor, @TypeOf(args), false);
    while (true) switch (@call(.auto, Cursor.advance, .{cursor} ++ args)) {
        .pending => {},
        .complete => |result| return result,
    };
}

/// Drive a fallible finite cursor to its observable result.
pub fn driveFallible(comptime T: type, cursor: anytype, args: anytype) !T {
    const Cursor = @TypeOf(cursor.*);
    comptime validateFiniteCursor("poll.driveFallible", T, Cursor, @TypeOf(args), true);
    while (true) switch (try @call(.auto, Cursor.advance, .{cursor} ++ args)) {
        .pending => {},
        .complete => |result| return result,
    };
}

pub fn driveVoid(cursor: anytype, args: anytype) void {
    const Cursor = @TypeOf(cursor.*);
    comptime validateFiniteCursor("poll.driveVoid", void, Cursor, @TypeOf(args), false);
    while (@call(.auto, Cursor.advance, .{cursor} ++ args) == .pending) {}
}

pub fn driveVoidFallible(cursor: anytype, args: anytype) !void {
    const Cursor = @TypeOf(cursor.*);
    comptime validateFiniteCursor("poll.driveVoidFallible", void, Cursor, @TypeOf(args), true);
    while (try @call(.auto, Cursor.advance, .{cursor} ++ args) == .pending) {}
}

/// Bottom-up stable merge sort whose comparisons and copying are both
/// resumable. `Comparator` supplies `Context`, `Cursor`, `init`, and
/// `advance`; the latter returns `Progress(std.math.Order)`.
pub fn MergeSortCursor(comptime T: type, comptime Comparator: type) type {
    comptime validateMergeSortComparator(T, Comparator);
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
            self.allocator.free(self.scratch);
            self.* = undefined;
        }

        pub fn advance(self: *Self, budget: usize) Progress(void) {
            var remaining = budget;
            while (remaining != 0) {
                if (self.width >= self.items.len) {
                    if (!self.source_scratch) return .complete;
                    const end = @min(self.copy_index + remaining, self.items.len);
                    const copied = end - self.copy_index;
                    @memcpy(self.items[self.copy_index..end], self.scratch[self.copy_index..end]);
                    self.copy_index = end;
                    if (self.copy_index == self.items.len) return .complete;
                    remaining -= copied;
                    continue;
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
                    if (self.comparator == null) self.comparator = Comparator.init(
                        self.context,
                        source[self.left],
                        source[self.right],
                    );
                    switch (Comparator.advance(&self.comparator.?, 1)) {
                        .pending => {
                            remaining -= 1;
                            continue;
                        },
                        .complete => |ordering| {
                            self.comparator = null;
                            choose_left = ordering != .gt;
                        },
                    }
                }
                const destination = if (self.source_scratch) self.items else self.scratch;
                destination[self.output] = if (choose_left) source[self.left] else source[self.right];
                if (choose_left) self.left += 1 else self.right += 1;
                self.output += 1;
                remaining -= 1;
            }
            return .pending;
        }
    };
}

/// Exact-capacity, non-rehashing map used by runtime publication snapshots.
/// Its key is nominal in entries and cursors; conversion to an integer is
/// confined to the hash-slot adapter.
pub fn FixedMap(comptime K: type, comptime V: type) type {
    const key_info = switch (@typeInfo(K)) {
        .@"enum" => |info| info,
        else => @compileError("FixedMap keys must be nominal enum(u32) values"),
    };
    if (key_info.tag_type != u32)
        @compileError("FixedMap keys must be nominal enum(u32) values");
    return struct {
        const Self = @This();
        const Entry = struct { key: K, value: V };

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

        pub const CloneProgress = Progress(Self);
        pub const CloneCursor = struct {
            source: *const Self,
            initializer: InitCursor,
            result: ?Self = null,
            entries: ?RawEntryCursor = null,
            insertion: ?PutCursor = null,
            pub fn deinit(self: *CloneCursor) void {
                self.initializer.deinit();
                if (self.result) |*result| result.deinit();
                self.* = undefined;
            }
            pub fn advance(self: *CloneCursor) error{OutOfMemory}!CloneProgress {
                if (self.result == null) switch (try self.initializer.advance()) {
                    .pending => return .pending,
                    .complete => |result| {
                        self.result = result;
                        self.entries = self.source.rawEntries();
                        return .pending;
                    },
                };
                if (self.insertion) |*insertion| switch (insertion.advance()) {
                    .pending => return .pending,
                    .complete => {
                        self.insertion = null;
                        return .pending;
                    },
                };
                return switch (self.entries.?.advance()) {
                    .pending => .pending,
                    .item => |entry| pending: {
                        self.insertion = self.result.?.putCursor(entry.key, entry.value);
                        break :pending .pending;
                    },
                    .complete => complete: {
                        const result = self.result.?;
                        self.result = null;
                        break :complete .{ .complete = result };
                    },
                };
            }
        };
        pub fn cloneCursor(self: *const Self, extra: usize) CloneCursor {
            return .{
                .source = self,
                .initializer = initCursor(self.allocator, self.count_value + extra),
            };
        }

        /// Clone without the entries an owner is removing. Both filters are
        /// exact matches, so a removal names either the key it retires or the
        /// value every dependent entry points at.
        pub const CloneExcludingCursor = struct {
            inner: CloneCursor,
            excluded_key: ?K,
            excluded_value: ?V,
            pub fn deinit(self: *CloneExcludingCursor) void {
                self.inner.deinit();
                self.* = undefined;
            }
            pub fn advance(self: *CloneExcludingCursor) error{OutOfMemory}!CloneProgress {
                const inner = &self.inner;
                if (inner.result == null or inner.insertion != null)
                    return inner.advance();
                return switch (inner.entries.?.advance()) {
                    .pending => .pending,
                    .item => |entry| pending: {
                        const dropped = (self.excluded_key != null and entry.key == self.excluded_key.?) or
                            (self.excluded_value != null and entry.value == self.excluded_value.?);
                        if (!dropped)
                            inner.insertion = inner.result.?.putCursor(entry.key, entry.value);
                        break :pending .pending;
                    },
                    .complete => complete: {
                        const result = inner.result.?;
                        inner.result = null;
                        break :complete .{ .complete = result };
                    },
                };
            }
        };
        pub fn cloneExcludingCursor(
            self: *const Self,
            excluded_key: ?K,
            excluded_value: ?V,
        ) CloneExcludingCursor {
            return .{
                .inner = self.cloneCursor(0),
                .excluded_key = excluded_key,
                .excluded_value = excluded_value,
            };
        }

        fn slot(key: K, capacity: usize) usize {
            const raw: u32 = @intFromEnum(key);
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
        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            if (self.top) |top| releases.retire(top, &top.retirement);
            self.top = null;
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

        /// Makes the next `additional` pushes allocation-free. A fresh chunk
        /// may leave unused tail space in the prior chunk; preserving strong
        /// ownership on multi-frame transitions matters more than packing it.
        pub fn reserve(self: *Self, additional: usize) error{OutOfMemory}!void {
            std.debug.assert(additional <= chunk_len);
            const available = if (self.top) |chunk| chunk_len - chunk.len else 0;
            if (available >= additional) return;
            const chunk = try self.allocator.create(Chunk);
            // SAFETY: slots are read only below `len`, after a later `push`
            // initializes the corresponding element.
            chunk.* = .{ .previous = self.top, .len = 0, .items = undefined };
            self.top = chunk;
        }

        /// Commits one item after `reserve`; ownership transfer cannot fail.
        pub fn pushReserved(self: *Self, item: T) void {
            const chunk = self.top.?;
            std.debug.assert(chunk.len != chunk_len);
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

        pub fn topPtr(self: *Self) ?*T {
            const chunk = self.top orelse return null;
            return if (chunk.len == 0) null else &chunk.items[chunk.len - 1];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.top == null or self.top.?.len == 0;
        }
    };
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

test "poll: finite driver observes pending and completion" {
    const Cursor = struct {
        current: u32 = 0,

        pub fn advance(self: *@This(), amount: u32) Progress(u32) {
            if (self.current == 3) return .{ .complete = self.current };
            self.current += amount;
            return .pending;
        }
    };
    var cursor = Cursor{};
    try std.testing.expectEqual(@as(u32, 3), drive(u32, &cursor, .{@as(u32, 1)}));
}

test "poll: fixed map stream observes pending items and completion" {
    const Key = enum(u32) { first = 1, second = 2 };
    const Map = FixedMap(Key, u8);
    var initializer = Map.initCursor(std.testing.allocator, 2);
    defer initializer.deinit();
    var map = try driveFallible(Map, &initializer, .{});
    defer map.deinit();

    var first = map.putCursor(.first, 10);
    try std.testing.expect(drive(bool, &first, .{}));
    var second = map.putCursor(.second, 20);
    try std.testing.expect(drive(bool, &second, .{}));

    var entries = map.rawEntries();
    var pending_count: usize = 0;
    var item_count: usize = 0;
    var value_total: usize = 0;
    while (true) switch (entries.advance()) {
        .pending => pending_count += 1,
        .item => |entry| {
            item_count += 1;
            value_total += entry.value;
        },
        .complete => break,
    };
    try std.testing.expect(pending_count != 0);
    try std.testing.expectEqual(@as(usize, 2), item_count);
    try std.testing.expectEqual(@as(usize, 30), value_total);
}

test "poll: merge sort consumes a resumable stable comparator" {
    const Item = struct { key: u8, sequence: u8 };
    const Stats = struct { initialized: usize = 0, advanced: usize = 0 };
    const Comparator = struct {
        pub const Context = *Stats;
        pub const Cursor = struct {
            stats: *Stats,
            left: Item,
            right: Item,
            pending: bool = true,
        };

        pub fn init(stats: Context, left: Item, right: Item) Cursor {
            stats.initialized += 1;
            return .{ .stats = stats, .left = left, .right = right };
        }

        pub fn advance(cursor: *Cursor, budget: usize) Progress(std.math.Order) {
            std.debug.assert(budget != 0);
            cursor.stats.advanced += 1;
            if (cursor.pending) {
                cursor.pending = false;
                return .pending;
            }
            return .{ .complete = std.math.order(cursor.left.key, cursor.right.key) };
        }
    };
    const Sort = MergeSortCursor(Item, Comparator);
    var stats = Stats{};
    var items = [_]Item{
        .{ .key = 2, .sequence = 0 },
        .{ .key = 1, .sequence = 1 },
        .{ .key = 2, .sequence = 2 },
        .{ .key = 1, .sequence = 3 },
    };
    var sort = try Sort.init(std.testing.allocator, &items, &stats);
    defer sort.deinit();
    driveVoid(&sort, .{@as(usize, 1)});

    try std.testing.expectEqualSlices(Item, &.{
        .{ .key = 1, .sequence = 1 },
        .{ .key = 1, .sequence = 3 },
        .{ .key = 2, .sequence = 0 },
        .{ .key = 2, .sequence = 2 },
    }, &items);
    try std.testing.expect(stats.initialized != 0);
    try std.testing.expectEqual(stats.initialized * 2, stats.advanced);
}
