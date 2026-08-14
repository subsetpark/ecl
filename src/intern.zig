//! Append-only string interning with fixed buckets, locked writes, and lock-free reads.
//!
//! Interned strings are process-lifetime atoms. Code that interns unbounded
//! external input can grow this table without bound; bucket chains never rehash.

const std = @import("std");
const poll = @import("poll.zig");

const entries_per_segment = 256;
const byte_segment_size = 64 * 1024;
const max_segments = 4096;
const bucket_count = 16 * 1024;
const no_entry = std.math.maxInt(u32);

/// Nominal identifier accepted at namespace-publication boundaries. Raw
/// intern ids remain useful for resolution, but cannot be passed to a binder,
/// module registry, or environment writer without validation.
pub const NamespaceName = enum(u32) { _ };

pub fn namespaceId(name: NamespaceName) u32 {
    return @intFromEnum(name);
}

pub const NameError = poll.Error || error{InvalidName};

pub fn namespaceName(id: u32, work: poll.WorkContext) NameError!NamespaceName {
    const bytes = process_table.getBytes(id) orelse return error.InvalidName;
    if (bytes.len == 0 or isReservedBytes(bytes)) return error.InvalidName;
    var cursor = work.cursor(u8, bytes);
    while (try cursor.next()) |byte| if (byte == '.') return error.InvalidName;
    return @enumFromInt(id);
}

pub fn internNamespace(bytes: []const u8) error{ OutOfMemory, InvalidName }!NamespaceName {
    const id = try intern(bytes);
    return namespaceName(id, .unlimited()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidName => error.InvalidName,
        error.Ecl => unreachable,
    };
}

pub fn trustedNamespace(bytes: []const u8) error{OutOfMemory}!NamespaceName {
    return internNamespace(bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidName => unreachable,
    };
}

const Entry = struct {
    hash: u64,
    byte_segment: u32,
    offset: u32,
    len: u32,
    next: u32,
};

const EntrySegment = struct {
    entries: [entries_per_segment]Entry,
};

const ByteSegment = struct {
    bytes: []u8,
    used: usize = 0,
};

const AtomicEntrySegment = std.atomic.Value(?*EntrySegment);
const AtomicByteSegment = std.atomic.Value(?*ByteSegment);

pub const Table = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    buckets: [bucket_count]u32 = [_]u32{no_entry} ** bucket_count,
    count: std.atomic.Value(u32) = .init(0),
    entry_segments: [max_segments]AtomicEntrySegment =
        [_]AtomicEntrySegment{AtomicEntrySegment.init(null)} ** max_segments,
    byte_segments: [max_segments]AtomicByteSegment =
        [_]AtomicByteSegment{AtomicByteSegment.init(null)} ** max_segments,
    byte_segment_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        for (&self.entry_segments) |*slot| {
            if (slot.load(.monotonic)) |segment| self.allocator.destroy(segment);
        }
        for (&self.byte_segments) |*slot| {
            if (slot.load(.monotonic)) |segment| {
                self.allocator.free(segment.bytes);
                self.allocator.destroy(segment);
            }
        }
        self.* = undefined;
    }

    pub fn internBytes(self: *Table, bytes: []const u8) error{OutOfMemory}!u32 {
        return self.internBytesImpl(bytes, null) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Ecl => unreachable,
        };
    }

    pub fn internBytesPolling(
        self: *Table,
        bytes: []const u8,
        poller: poll.Poller,
    ) poll.Error!u32 {
        return self.internBytesImpl(bytes, poller);
    }

    fn internBytesImpl(
        self: *Table,
        bytes: []const u8,
        poller: ?poll.Poller,
    ) poll.Error!u32 {
        const hash = if (poller) |active|
            try hashBytesPolling(bytes, active)
        else
            std.hash.Wyhash.hash(0, bytes);
        // Zig 0.16's atomic mutex is tryLock-only, so M1 spins on its
        // effectively uncontended writer path. Before M7 enables parallel
        // parsing, replace this with a blocking mutex to avoid burning cores.
        while (!self.mutex.tryLock()) {
            if (poller) |active| try active.poll();
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();

        if (try self.findBytes(bytes, hash, poller)) |id| return id;
        if (bytes.len > std.math.maxInt(u32)) return error.OutOfMemory;
        const id = self.count.load(.monotonic);
        const entry_segment_index: usize = id / entries_per_segment;
        if (entry_segment_index >= max_segments) return error.OutOfMemory;
        const entry_segment = try self.ensureEntrySegment(entry_segment_index);
        const reservation = try self.reserveSpace(bytes.len);
        const destination = reservation.segment.bytes[reservation.offset..][0..bytes.len];
        if (poller) |active|
            try copyBytesPolling(destination, bytes, active)
        else
            @memcpy(destination, bytes);
        reservation.segment.used += bytes.len;
        const bucket = bucketIndex(hash);
        entry_segment.entries[id % entries_per_segment] = .{
            .hash = hash,
            .byte_segment = @intCast(reservation.segment_index),
            .offset = @intCast(reservation.offset),
            .len = @intCast(bytes.len),
            .next = self.buckets[bucket],
        };
        self.buckets[bucket] = id;
        self.count.store(id + 1, .release);
        return id;
    }

    fn findBytes(
        self: *const Table,
        bytes: []const u8,
        hash: u64,
        poller: ?poll.Poller,
    ) poll.Error!?u32 {
        var cursor = self.buckets[bucketIndex(hash)];
        while (cursor != no_entry) {
            if (poller) |active| try active.poll();
            const segment = self.entry_segments[cursor / entries_per_segment].load(.monotonic).?;
            const entry = segment.entries[cursor % entries_per_segment];
            if (entry.hash == hash and entry.len == bytes.len) {
                const stored = self.getBytes(cursor).?;
                const equal = if (poller) |active|
                    try equalBytesPolling(bytes, stored, active)
                else
                    std.mem.eql(u8, bytes, stored);
                if (equal) return cursor;
            }
            cursor = entry.next;
        }
        return null;
    }

    pub fn getBytes(self: *const Table, id: u32) ?[]const u8 {
        if (id >= self.count.load(.acquire)) return null;
        const segment_index: usize = id / entries_per_segment;
        const segment = self.entry_segments[segment_index].load(.acquire).?;
        const entry = segment.entries[id % entries_per_segment];
        const byte_segment = self.byte_segments[entry.byte_segment].load(.acquire).?;
        return byte_segment.bytes[entry.offset..][0..entry.len];
    }

    fn ensureEntrySegment(
        self: *Table,
        segment_index: usize,
    ) error{OutOfMemory}!*EntrySegment {
        if (self.entry_segments[segment_index].load(.monotonic)) |segment| return segment;
        const segment = try self.allocator.create(EntrySegment);
        // SAFETY: entries are published one at a time before count's release-store.
        segment.* = .{ .entries = undefined };
        self.entry_segments[segment_index].store(segment, .monotonic);
        return segment;
    }

    const Reservation = struct {
        segment: *ByteSegment,
        segment_index: usize,
        offset: usize,
    };

    fn reserveSpace(self: *Table, length: usize) error{OutOfMemory}!Reservation {
        var segment_index = if (self.byte_segment_count == 0)
            0
        else
            self.byte_segment_count - 1;
        const segment: *ByteSegment = blk: {
            if (self.byte_segment_count == 0 or
                self.byte_segments[segment_index].load(.monotonic).?.bytes.len -
                    self.byte_segments[segment_index].load(.monotonic).?.used < length)
            {
                if (self.byte_segment_count == max_segments) return error.OutOfMemory;
                segment_index = self.byte_segment_count;
                const created = try self.allocator.create(ByteSegment);
                errdefer self.allocator.destroy(created);
                created.* = .{
                    .bytes = try self.allocator.alloc(u8, @max(byte_segment_size, length)),
                };
                self.byte_segments[segment_index].store(created, .monotonic);
                self.byte_segment_count += 1;
                break :blk created;
            }
            break :blk self.byte_segments[segment_index].load(.monotonic).?;
        };

        return .{
            .segment = segment,
            .segment_index = segment_index,
            .offset = segment.used,
        };
    }
};

fn bucketIndex(hash: u64) usize {
    return @as(usize, @truncate(hash)) & (bucket_count - 1);
}

fn hashBytesPolling(bytes: []const u8, poller: poll.Poller) poll.Error!u64 {
    var hasher = std.hash.Wyhash.init(0);
    var chunks = poll.WorkContext.init(poller).chunks(bytes);
    while (try chunks.next()) |chunk| hasher.update(chunk);
    return hasher.final();
}

fn equalBytesPolling(left: []const u8, right: []const u8, poller: poll.Poller) poll.Error!bool {
    for (left, right) |left_byte, right_byte| {
        try poller.poll();
        if (left_byte != right_byte) return false;
    }
    return true;
}

fn copyBytesPolling(destination: []u8, source: []const u8, poller: poll.Poller) poll.Error!void {
    var chunks = poll.WorkContext.init(poller).chunks(source);
    var start: usize = 0;
    while (try chunks.next()) |chunk| : (start += chunk.len) {
        @memcpy(destination[start..][0..chunk.len], chunk);
    }
}

var process_table = Table.init(std.heap.smp_allocator);

pub fn intern(bytes: []const u8) error{OutOfMemory}!u32 {
    return process_table.internBytes(bytes);
}

pub fn dotIndexPolling(bytes: []const u8, poller: poll.Poller) poll.Error!?usize {
    for (bytes, 0..) |byte, index| {
        try poller.poll();
        if (byte == '.') return index;
    }
    return null;
}

pub fn internPolling(bytes: []const u8, poller: poll.Poller) poll.Error!u32 {
    return process_table.internBytesPolling(bytes, poller);
}

pub fn qualifiedPolling(
    allocator: std.mem.Allocator,
    module_name: u32,
    word: u32,
    poller: poll.Poller,
) poll.Error!u32 {
    const module_bytes = get(module_name);
    const word_bytes = get(word);
    const separator_end = std.math.add(usize, module_bytes.len, 1) catch return error.OutOfMemory;
    const length = std.math.add(usize, separator_end, word_bytes.len) catch return error.OutOfMemory;
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    try copyBytesPolling(bytes[0..module_bytes.len], module_bytes, poller);
    try poller.poll();
    bytes[module_bytes.len] = '.';
    try copyBytesPolling(bytes[separator_end..], word_bytes, poller);
    return internPolling(bytes, poller);
}

pub fn get(id: u32) []const u8 {
    return process_table.getBytes(id) orelse unreachable;
}

pub fn isReservedBytes(name: []const u8) bool {
    return std.mem.eql(u8, name, "--") or std.mem.eql(u8, name, ":");
}

pub fn isReservedName(id: u32) bool {
    return isReservedBytes(get(id));
}

fn allocationFailureProbe(allocator: std.mem.Allocator) !void {
    var table = Table.init(allocator);
    defer table.deinit();
    _ = try table.internBytes("alpha");
    _ = try table.internBytes("beta");
}

test "interning round-trips and is idempotent" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    const first = try table.internBytes("ecl");
    const second = try table.internBytes("ecl");
    const other = try table.internBytes("array");
    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != other);
    try std.testing.expectEqualStrings("ecl", table.getBytes(first).?);
    try std.testing.expectEqualStrings("array", table.getBytes(other).?);
}

test "polling interning stops inside hash equality and publication copy" {
    const PollStop = struct {
        calls: usize = 0,
        fail_at: usize,
        fn tick(raw: *anyopaque) poll.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == self.fail_at) return error.Ecl;
        }
        fn poller(self: *@This()) poll.Poller {
            return .{ .context = self, .poll_fn = tick };
        }
    };
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(bytes);
    @memset(bytes, 'p');
    var table = Table.init(allocator);
    defer table.deinit();

    var hash_stop = PollStop{ .fail_at = 1024 };
    try std.testing.expectError(error.Ecl, table.internBytesPolling(bytes, hash_stop.poller()));
    try std.testing.expectEqual(@as(?[]const u8, null), table.getBytes(0));

    var copy_stop = PollStop{ .fail_at = bytes.len + 128 };
    try std.testing.expectError(error.Ecl, table.internBytesPolling(bytes, copy_stop.poller()));
    try std.testing.expectEqual(@as(?[]const u8, null), table.getBytes(0));

    const id = try table.internBytes(bytes);
    try std.testing.expectEqual(@as(u32, 0), id);
    try std.testing.expectEqualSlices(u8, bytes, table.getBytes(id).?);
    try std.testing.expectEqual(id, try table.internBytes(bytes));

    var complete = PollStop{ .fail_at = std.math.maxInt(usize) };
    try std.testing.expectEqual(id, try table.internBytesPolling(bytes, complete.poller()));
    try std.testing.expect(complete.calls > bytes.len * 2);

    var equality_stop = PollStop{ .fail_at = bytes.len + 128 };
    try std.testing.expectError(error.Ecl, table.internBytesPolling(bytes, equality_stop.poller()));
    try std.testing.expectEqualSlices(u8, bytes, table.getBytes(id).?);
    try std.testing.expectEqual(id, try table.internBytes(bytes));

    const next = try table.internBytes("after-cancellation");
    try std.testing.expectEqual(id + 1, next);
    try std.testing.expectEqualStrings("after-cancellation", table.getBytes(next).?);
    try std.testing.expectEqual(next, try table.internBytes("after-cancellation"));
}

test "intern write failures are leak-free and leave no partial entries" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}

const ThreadContext = struct {
    table: *Table,
    failed: *std.atomic.Value(bool),
};

fn internWorker(context: ThreadContext) void {
    const strings = [_][]const u8{ "alpha", "beta", "gamma", "alpha" };
    for (0..100) |_| {
        for (strings) |bytes| {
            const id = context.table.internBytes(bytes) catch {
                context.failed.store(true, .release);
                return;
            };
            if (!std.mem.eql(u8, bytes, context.table.getBytes(id).?)) {
                context.failed.store(true, .release);
                return;
            }
        }
    }
}

test "concurrent interning publishes stable lock-free reads" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    var failed = std.atomic.Value(bool).init(false);
    const context = ThreadContext{ .table = &table, .failed = &failed };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, internWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), table.count.load(.acquire));
}
