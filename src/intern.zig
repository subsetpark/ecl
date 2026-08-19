//! Append-only string interning with fixed buckets, locked writes, and lock-free reads.
//!
//! Interned strings are process-lifetime atoms. Code that interns unbounded
//! external input can grow this table without bound; bucket chains never rehash.

const std = @import("std");
const poll = @import("poll.zig");
const lexer = @import("lexer.zig");

const entries_per_segment = 256;
const byte_segment_size = 64 * 1024;
const max_segments = 4096;
const bucket_count = 16 * 1024;
const no_entry = std.math.maxInt(u32);

/// Nominal identifier accepted at namespace-publication boundaries. Raw
/// intern ids remain useful for resolution, but cannot be passed to a binder,
/// module registry, or environment writer without validation.
pub const BindingName = enum(u32) { _ };
pub const NamespaceName = BindingName;
pub const ModuleName = enum(u32) { _ };
pub const QualifiedName = enum(u64) { _ };

const dotted_module_mask: u32 = @as(u32, 1) << 31;
comptime {
    if (max_segments * entries_per_segment >= dotted_module_mask)
        @compileError("intern ids overlap ModuleName brand metadata");
}

pub fn namespaceId(name: NamespaceName) u32 {
    return @intFromEnum(name);
}

pub fn bindingId(name: BindingName) u32 {
    return @intFromEnum(name);
}

pub fn moduleId(name: ModuleName) u32 {
    return @intFromEnum(name) & ~dotted_module_mask;
}

pub fn moduleNameFromBinding(name: BindingName) ModuleName {
    return @enumFromInt(bindingId(name));
}

pub fn moduleBindingName(name: ModuleName) ?BindingName {
    if (@intFromEnum(name) & dotted_module_mask != 0) return null;
    return @enumFromInt(moduleId(name));
}

pub fn qualifiedName(module: ModuleName, binding: BindingName) QualifiedName {
    return @enumFromInt((@as(u64, @intFromEnum(module)) << 32) | bindingId(binding));
}

pub fn qualifiedModule(name: QualifiedName) ModuleName {
    return @enumFromInt(@as(u32, @truncate(@intFromEnum(name) >> 32)));
}

pub fn qualifiedBinding(name: QualifiedName) BindingName {
    return @enumFromInt(@as(u32, @truncate(@intFromEnum(name))));
}

pub const NameError = error{InvalidName};

pub fn namespaceName(id: u32) NameError!NamespaceName {
    _ = process_table.getBytes(id) orelse return error.InvalidName;
    var cursor = NamespaceCursor.init(id);
    return poll.drive(?NamespaceName, &cursor, .{}) orelse error.InvalidName;
}

pub fn internNamespace(bytes: []const u8) error{ OutOfMemory, InvalidName }!NamespaceName {
    const id = try intern(bytes);
    return namespaceName(id);
}

pub fn moduleName(id: u32) NameError!ModuleName {
    _ = process_table.getBytes(id) orelse return error.InvalidName;
    var cursor = ModuleNameCursor.init(id);
    return poll.drive(?ModuleName, &cursor, .{}) orelse error.InvalidName;
}

pub fn internModuleName(bytes: []const u8) error{ OutOfMemory, InvalidName }!ModuleName {
    const id = try intern(bytes);
    return moduleName(id);
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
const AtomicBucket = std.atomic.Value(u32);

pub const Table = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    buckets: [bucket_count]AtomicBucket =
        [_]AtomicBucket{AtomicBucket.init(no_entry)} ** bucket_count,
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
        var cursor = self.internCursor(bytes);
        return poll.driveFallible(u32, &cursor, .{});
    }

    pub fn getBytes(self: *const Table, id: u32) ?[]const u8 {
        if (id >= self.count.load(.acquire)) return null;
        const segment_index: usize = id / entries_per_segment;
        const segment = self.entry_segments[segment_index].load(.acquire).?;
        const entry = segment.entries[id % entries_per_segment];
        const byte_segment = self.byte_segments[entry.byte_segment].load(.acquire).?;
        return byte_segment.bytes[entry.offset..][0..entry.len];
    }

    pub const LookupProgress = poll.Progress(?u32);
    pub const LookupCursor = struct {
        table: *const Table,
        bytes: []const u8,
        hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
        hash_index: usize = 0,
        hash: ?u64 = null,
        entry_id: u32 = no_entry,
        initial_head: u32 = no_entry,
        compare_index: usize = 0,
        entry_loaded: bool = false,

        pub fn advance(self: *LookupCursor) LookupProgress {
            if (self.hash == null) {
                const end = @min(self.hash_index + 256, self.bytes.len);
                self.hasher.update(self.bytes[self.hash_index..end]);
                self.hash_index = end;
                if (end != self.bytes.len) return .pending;
                const hash = self.hasher.final();
                self.hash = hash;
                self.entry_id = self.table.buckets[bucketIndex(hash)].load(.acquire);
                self.initial_head = self.entry_id;
                return .pending;
            }
            if (self.entry_id == no_entry) return .{ .complete = null };
            const segment = self.table.entry_segments[self.entry_id / entries_per_segment].load(.acquire).?;
            const entry = segment.entries[self.entry_id % entries_per_segment];
            if (!self.entry_loaded) {
                self.entry_loaded = true;
                self.compare_index = 0;
                if (entry.hash != self.hash.? or entry.len != self.bytes.len) {
                    self.entry_id = entry.next;
                    self.entry_loaded = false;
                }
                return .pending;
            }
            const stored = self.table.getBytes(self.entry_id).?;
            const end = @min(self.compare_index + 256, self.bytes.len);
            if (!std.mem.eql(u8, self.bytes[self.compare_index..end], stored[self.compare_index..end])) {
                self.entry_id = entry.next;
                self.entry_loaded = false;
                return .pending;
            }
            self.compare_index = end;
            if (end != self.bytes.len) return .pending;
            return .{ .complete = self.entry_id };
        }
    };
    pub fn lookupCursor(self: *const Table, bytes: []const u8) LookupCursor {
        return .{ .table = self, .bytes = bytes };
    }

    pub const InternProgress = poll.Progress(u32);
    pub const InternCursor = struct {
        table: *Table,
        bytes: []const u8,
        lookup: LookupCursor,
        reservation: ?Reservation = null,
        copy_index: usize = 0,
        phase: enum { lookup, reserve, copy, recheck, commit, complete } = .lookup,

        pub fn advance(self: *InternCursor) error{OutOfMemory}!InternProgress {
            return switch (self.phase) {
                .lookup, .recheck => switch (self.lookup.advance()) {
                    .pending => .pending,
                    .complete => |maybe_id| result: {
                        if (maybe_id) |id| {
                            self.phase = .complete;
                            break :result .{ .complete = id };
                        }
                        self.phase = if (self.reservation == null) .reserve else .commit;
                        break :result .pending;
                    },
                },
                .reserve => result: {
                    if (self.bytes.len > std.math.maxInt(u32)) return error.OutOfMemory;
                    std.Io.Threaded.mutexLock(&self.table.mutex);
                    defer std.Io.Threaded.mutexUnlock(&self.table.mutex);
                    const reservation = try self.table.reserveSpace(self.bytes.len);
                    reservation.segment.used += self.bytes.len;
                    self.reservation = reservation;
                    self.phase = .copy;
                    break :result .pending;
                },
                .copy => result: {
                    const reservation = self.reservation.?;
                    const destination = reservation.segment.bytes[reservation.offset..][0..self.bytes.len];
                    const end = @min(self.copy_index + 256, self.bytes.len);
                    @memcpy(destination[self.copy_index..end], self.bytes[self.copy_index..end]);
                    self.copy_index = end;
                    if (end == self.bytes.len) {
                        self.lookup = self.table.lookupCursor(self.bytes);
                        self.phase = .recheck;
                    }
                    break :result .pending;
                },
                .commit => result: {
                    std.Io.Threaded.mutexLock(&self.table.mutex);
                    defer std.Io.Threaded.mutexUnlock(&self.table.mutex);
                    const hash = self.lookup.hash.?;
                    const bucket = bucketIndex(hash);
                    if (self.table.buckets[bucket].load(.acquire) != self.lookup.initial_head) {
                        self.lookup = self.table.lookupCursor(self.bytes);
                        self.phase = .recheck;
                        break :result .pending;
                    }
                    const id = self.table.count.load(.monotonic);
                    const segment_index: usize = id / entries_per_segment;
                    if (segment_index >= max_segments) return error.OutOfMemory;
                    const entry_segment = try self.table.ensureEntrySegment(segment_index);
                    const reservation = self.reservation.?;
                    entry_segment.entries[id % entries_per_segment] = .{
                        .hash = hash,
                        .byte_segment = @intCast(reservation.segment_index),
                        .offset = @intCast(reservation.offset),
                        .len = @intCast(self.bytes.len),
                        .next = self.table.buckets[bucket].load(.monotonic),
                    };
                    self.table.count.store(id + 1, .release);
                    self.table.buckets[bucket].store(id, .release);
                    self.phase = .complete;
                    break :result .{ .complete = id };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn internCursor(self: *Table, bytes: []const u8) InternCursor {
        return .{ .table = self, .bytes = bytes, .lookup = self.lookupCursor(bytes) };
    }

    fn ensureEntrySegment(
        self: *Table,
        segment_index: usize,
    ) error{OutOfMemory}!*EntrySegment {
        if (self.entry_segments[segment_index].load(.monotonic)) |segment| return segment;
        const segment = try self.allocator.create(EntrySegment);
        // SAFETY: entries are initialized before count publishes their IDs.
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

var process_table = Table.init(std.heap.smp_allocator);

pub fn intern(bytes: []const u8) error{OutOfMemory}!u32 {
    return process_table.internBytes(bytes);
}

pub const InternLookupCursor = Table.LookupCursor;
pub fn lookupCursor(bytes: []const u8) InternLookupCursor {
    return process_table.lookupCursor(bytes);
}

pub const InternInsertionCursor = Table.InternCursor;
pub fn insertionCursor(bytes: []const u8) InternInsertionCursor {
    return process_table.internCursor(bytes);
}

pub const QualifiedProgress = poll.Progress(u32);
pub const QualifiedCursor = struct {
    allocator: std.mem.Allocator,
    module: []const u8,
    word: []const u8,
    bytes: []u8,
    copy_index: usize = 0,
    inserter: ?InternInsertionCursor = null,
    pub fn init(
        allocator: std.mem.Allocator,
        name: QualifiedName,
    ) error{OutOfMemory}!QualifiedCursor {
        const module_name = qualifiedModule(name);
        const word = qualifiedBinding(name);
        const module = get(moduleId(module_name));
        const word_bytes = get(bindingId(word));
        const separator_end = std.math.add(usize, module.len, 1) catch return error.OutOfMemory;
        const length = std.math.add(usize, separator_end, word_bytes.len) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .module = module,
            .word = word_bytes,
            .bytes = try allocator.alloc(u8, length),
        };
    }
    pub fn deinit(self: *QualifiedCursor) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
    pub fn advance(self: *QualifiedCursor) error{OutOfMemory}!QualifiedProgress {
        if (self.inserter) |*inserter| return switch (try inserter.advance()) {
            .pending => .pending,
            .complete => |id| .{ .complete = id },
        };
        if (self.copy_index != self.bytes.len) {
            if (self.copy_index < self.module.len)
                self.bytes[self.copy_index] = self.module[self.copy_index]
            else if (self.copy_index == self.module.len)
                self.bytes[self.copy_index] = '.'
            else
                self.bytes[self.copy_index] = self.word[self.copy_index - self.module.len - 1];
            self.copy_index += 1;
            return .pending;
        }
        self.inserter = insertionCursor(self.bytes);
        return .pending;
    }
};

pub const DotProgress = poll.Progress(?usize);
pub const DotCursor = struct {
    bytes: []const u8,
    index: usize = 0,
    pub fn advance(self: *DotCursor) DotProgress {
        if (self.index == self.bytes.len) return .{ .complete = null };
        const index = self.index;
        self.index += 1;
        return if (self.bytes[index] == '.') .{ .complete = index } else .pending;
    }
};
pub fn dotCursor(bytes: []const u8) DotCursor {
    return .{ .bytes = bytes };
}

pub const LastDotCursor = struct {
    bytes: []const u8,
    index: usize = 0,
    last: ?usize = null,
    pub fn advance(self: *LastDotCursor) DotProgress {
        if (self.index == self.bytes.len) return .{ .complete = self.last };
        if (self.bytes[self.index] == '.') self.last = self.index;
        self.index += 1;
        return .pending;
    }
};
pub fn lastDotCursor(bytes: []const u8) LastDotCursor {
    return .{ .bytes = bytes };
}

pub const NamespaceProgress = poll.Progress(?NamespaceName);
pub const NamespaceCursor = struct {
    id: u32,
    bytes: []const u8,
    lexical: lexer.SymbolCursor,
    pub fn init(id: u32) NamespaceCursor {
        const bytes = get(id);
        return .{ .id = id, .bytes = bytes, .lexical = .initSegment(bytes) };
    }
    pub fn advance(self: *NamespaceCursor) NamespaceProgress {
        if (self.bytes.len == 0 or isReservedWordBytes(self.bytes))
            return .{ .complete = null };
        return switch (self.lexical.advance()) {
            .pending => .pending,
            .complete => |valid| .{ .complete = if (valid) @enumFromInt(self.id) else null },
        };
    }
};

pub const ModuleNameProgress = poll.Progress(?ModuleName);
pub const ModuleNameCursor = struct {
    id: u32,
    bytes: []const u8,
    lexical: lexer.SymbolCursor,
    index: usize = 0,
    segment_start: usize = 0,
    dotted: bool = false,
    phase: enum { lexical, segments } = .lexical,

    pub fn init(id: u32) ModuleNameCursor {
        const bytes = get(id);
        return .{ .id = id, .bytes = bytes, .lexical = .init(bytes) };
    }

    pub fn advance(self: *ModuleNameCursor) ModuleNameProgress {
        if (self.phase == .lexical) return switch (self.lexical.advance()) {
            .pending => .pending,
            .complete => |valid| if (!valid)
                .{ .complete = null }
            else result: {
                self.phase = .segments;
                break :result .pending;
            },
        };
        if (self.index == self.bytes.len) {
            const segment = self.bytes[self.segment_start..self.index];
            return .{ .complete = if (segment.len != 0 and !isReservedBytes(segment))
                @enumFromInt(self.id | if (self.dotted) dotted_module_mask else 0)
            else
                null };
        }
        const byte = self.bytes[self.index];
        if (byte == '.') {
            const segment = self.bytes[self.segment_start..self.index];
            if (segment.len == 0 or isReservedBytes(segment)) return .{ .complete = null };
            self.segment_start = self.index + 1;
            self.dotted = true;
        }
        self.index += 1;
        return .pending;
    }
};

pub fn get(id: u32) []const u8 {
    return process_table.getBytes(id) orelse unreachable;
}

pub fn isReservedBytes(name: []const u8) bool {
    return std.mem.eql(u8, name, "--") or std.mem.eql(u8, name, ":") or
        std.mem.eql(u8, name, lexer.row_token);
}

/// Every binding name the language reserves for itself.
pub fn isReservedWordBytes(name: []const u8) bool {
    return isReservedBytes(name);
}
