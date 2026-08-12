//! Append-only string interning with a locked write path and lock-free reads.
//!
//! Interned strings are process-lifetime atoms. Code that interns unbounded
//! external input can therefore grow this table without bound.

const std = @import("std");

const entries_per_segment = 256;
const byte_segment_size = 64 * 1024;
const max_segments = 4096;

const Entry = struct {
    byte_segment: u32,
    offset: u32,
    len: u32,
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
    map: std.StringHashMapUnmanaged(u32) = .empty,
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
        self.map.deinit(self.allocator);
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
        // Zig 0.16's atomic mutex is tryLock-only, so M1 spins on its
        // effectively uncontended writer path. Before M7 enables parallel
        // parsing, replace this with a blocking mutex to avoid burning cores.
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();

        if (self.map.get(bytes)) |id| return id;
        if (bytes.len > std.math.maxInt(u32)) return error.OutOfMemory;

        const id = self.count.load(.monotonic);
        const entry_segment_index: usize = id / entries_per_segment;
        if (entry_segment_index >= max_segments) return error.OutOfMemory;
        const entry_segment = try self.ensureEntrySegment(entry_segment_index);
        const reservation = try self.reserveBytes(bytes);
        errdefer self.rollback(reservation);

        const stable_bytes = reservation.segment.bytes[reservation.offset .. reservation.offset + bytes.len];
        try self.map.put(self.allocator, stable_bytes, id);
        entry_segment.entries[id % entries_per_segment] = .{
            .byte_segment = @intCast(reservation.segment_index),
            .offset = @intCast(reservation.offset),
            .len = @intCast(bytes.len),
        };
        self.count.store(id + 1, .release);
        return id;
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
        previous_used: usize,
    };

    fn reserveBytes(self: *Table, bytes: []const u8) error{OutOfMemory}!Reservation {
        var segment_index = if (self.byte_segment_count == 0)
            0
        else
            self.byte_segment_count - 1;
        const segment: *ByteSegment = blk: {
            if (self.byte_segment_count == 0 or
                self.byte_segments[segment_index].load(.monotonic).?.bytes.len -
                    self.byte_segments[segment_index].load(.monotonic).?.used < bytes.len)
            {
                if (self.byte_segment_count == max_segments) return error.OutOfMemory;
                segment_index = self.byte_segment_count;
                const created = try self.allocator.create(ByteSegment);
                errdefer self.allocator.destroy(created);
                created.* = .{
                    .bytes = try self.allocator.alloc(u8, @max(byte_segment_size, bytes.len)),
                };
                self.byte_segments[segment_index].store(created, .monotonic);
                self.byte_segment_count += 1;
                break :blk created;
            }
            break :blk self.byte_segments[segment_index].load(.monotonic).?;
        };

        const previous_used = segment.used;
        @memcpy(segment.bytes[previous_used..][0..bytes.len], bytes);
        segment.used += bytes.len;
        return .{
            .segment = segment,
            .segment_index = segment_index,
            .offset = previous_used,
            .previous_used = previous_used,
        };
    }

    fn rollback(_: *Table, reservation: Reservation) void {
        reservation.segment.used = reservation.previous_used;
    }
};

var process_table = Table.init(std.heap.smp_allocator);

pub fn intern(bytes: []const u8) error{OutOfMemory}!u32 {
    return process_table.internBytes(bytes);
}

pub fn get(id: u32) []const u8 {
    return process_table.getBytes(id) orelse unreachable;
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
