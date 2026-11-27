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
/// intern ids remain useful for resolution, but cannot be passed to a definition
/// writer, module registry, or environment writer without validation.
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
    return @backingInt(name);
}

pub fn bindingId(name: BindingName) u32 {
    return @backingInt(name);
}

pub fn moduleId(name: ModuleName) u32 {
    return @backingInt(name) & ~dotted_module_mask;
}

pub fn qualifiedName(module: ModuleName, binding: BindingName) QualifiedName {
    return @fromBackingInt(@intCast((@as(u64, @backingInt(module)) << 32) | bindingId(binding)));
}

pub fn qualifiedModule(name: QualifiedName) ModuleName {
    return @fromBackingInt(@intCast(@as(u32, @truncate(@backingInt(name) >> 32))));
}

pub fn qualifiedBinding(name: QualifiedName) BindingName {
    return @fromBackingInt(@intCast(@as(u32, @truncate(@backingInt(name)))));
}

/// A word as a diagnostic reports it.
///
/// A plain atom is its own spelling. A module-local binding is the pair of its
/// image's module name and its own local name; the qualified spelling is never
/// interned. Deferring qualification to whoever renders it keeps the interning
/// cost off every module-word invocation.
pub const TraceWord = enum(u64) {
    none = (@as(u64, no_trace_module) << 32) | no_trace_atom,
    _,

    /// Neither value is a reachable id: module brands stay below bit 31 plus
    /// the dotted mask, and the entry space cannot reach this many atoms.
    const no_trace_module: u32 = 0xffff_ffff;
    const no_trace_atom: u32 = 0xffff_ffff;

    pub fn plain(id: u32) TraceWord {
        return @fromBackingInt(@intCast((@as(u64, no_trace_module) << 32) | id));
    }

    pub fn moduleLocal(module: ModuleName, local: BindingName) TraceWord {
        std.debug.assert(@backingInt(module) != no_trace_module);
        return @fromBackingInt(@intCast((@as(u64, @backingInt(module)) << 32) | bindingId(local)));
    }

    /// The unqualified atom. For a module-local word this is the definition's
    /// own name, which is what recognition and idiom matching compare.
    pub fn atom(self: TraceWord) u32 {
        return @truncate(@backingInt(self));
    }

    pub fn qualified(self: TraceWord) ?QualifiedName {
        const module: u32 = @truncate(@backingInt(self) >> 32);
        if (module == no_trace_module) return null;
        return @fromBackingInt(@intCast(@backingInt(self)));
    }

    /// The module part of a qualified spelling, or null when the word is a
    /// plain atom.
    pub fn modulePrefix(self: TraceWord) ?[]const u8 {
        const name = self.qualified() orelse return null;
        return get(moduleId(qualifiedModule(name)));
    }

    /// Bytes marking an elided rendering. A bracket is a reader delimiter, so
    /// no single word can contain this and an elided spelling can never be
    /// read as a shorter name that exists.
    const elision = "[...]";

    /// Writes the spelling a program would have to type.
    ///
    /// A name too long for the caller's scratch is elided from the left rather
    /// than replaced by its unqualified atom: substituting the atom would make
    /// a diagnostic message cite a *different* word than the same failure's
    /// `word` field reports, and two modules may define the same local name.
    pub fn render(self: TraceWord, buffer: []u8) []const u8 {
        std.debug.assert(self != .none);
        const local = get(self.atom());
        const prefix = self.modulePrefix() orelse return local;
        if (prefix.len + 1 + local.len <= buffer.len) {
            @memcpy(buffer[0..prefix.len], prefix);
            buffer[prefix.len] = '.';
            @memcpy(buffer[prefix.len + 1 ..][0..local.len], local);
            return buffer[0 .. prefix.len + 1 + local.len];
        }
        // Keep the definition's own name and as much of the module's as
        // fits, so the rendering still points at one binding.
        if (elision.len + 1 + local.len > buffer.len) return elision;
        const room = buffer.len - elision.len - 1 - local.len;
        @memcpy(buffer[0..elision.len], elision);
        @memcpy(buffer[elision.len..][0..room], prefix[prefix.len - room ..]);
        buffer[elision.len + room] = '.';
        @memcpy(buffer[elision.len + room + 1 ..][0..local.len], local);
        return buffer[0 .. elision.len + room + 1 + local.len];
    }
};

/// The scratch a diagnostic borrows to spell one qualified word. It matches the
/// diagnostic message budget in `machine.EclErr`, so every name a message can
/// carry at all renders in full; beyond that the message itself collapses to
/// its own too-long fallback.
pub const trace_word_bytes = 512;

pub const TraceWordProgress = poll.Progress(u32);
/// Interns the spelling of a trace word. Only surfaces that must produce a
/// symbol *value* pay this; byte sinks render through `TraceWord.render`.
pub const TraceWordCursor = struct {
    plain_atom: ?u32,
    qualifier: ?QualifiedCursor = null,

    pub fn init(allocator: std.mem.Allocator, word: TraceWord) error{OutOfMemory}!TraceWordCursor {
        const name = word.qualified() orelse return .{ .plain_atom = word.atom() };
        return .{ .plain_atom = null, .qualifier = try QualifiedCursor.init(allocator, name) };
    }

    pub fn deinit(self: *TraceWordCursor) void {
        if (self.qualifier) |*cursor| cursor.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *TraceWordCursor) error{OutOfMemory}!TraceWordProgress {
        if (self.plain_atom) |id| return .{ .complete = id };
        return switch (try self.qualifier.?.advance()) {
            .pending => .pending,
            .complete => |id| .{ .complete = id },
        };
    }
};

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

/// Core installation only. See `NamespaceCursor.reserved_ok`.
pub fn internReservedNamespace(bytes: []const u8) error{ OutOfMemory, InvalidName }!NamespaceName {
    const id = try intern(bytes);
    _ = process_table.getBytes(id) orelse return error.InvalidName;
    var cursor = NamespaceCursor.initReserved(id);
    return poll.drive(?NamespaceName, &cursor, .{}) orelse error.InvalidName;
}

pub fn moduleName(id: u32) NameError!ModuleName {
    _ = process_table.getBytes(id) orelse return error.InvalidName;
    var cursor = ModuleNameCursor.init(id);
    return poll.drive(?ModuleName, &cursor, .{}) orelse error.InvalidName;
}

pub fn internModuleName(bytes: []const u8) error{ OutOfMemory, InvalidName }!ModuleName {
    return moduleName(try intern(bytes));
}

const Entry = struct {
    hash: u64,
    byte_segment: u32,
    offset: u32,
    len: u32,
    next: u32,
    /// What the spelling is as a word: zero until decided, then a
    /// `Spelling` tag plus one, never changed again. Stored under the
    /// table's mutex after `module` and `binding`, so the release store
    /// publishes them to whoever loads a nonzero tag.
    decided: std.atomic.Value(u8) = .init(0),
    module: u32 = 0,
    binding: u32 = 0,
};

/// What a spelling is as a word, a function of its bytes alone, decided once
/// as the spelling is interned and before its id is returned.
pub const Spelling = union(enum) {
    /// No dot: a binding name looked up in the word's root.
    plain,
    /// `core.` and one segment: that binding of core.
    core: BindingName,
    /// A valid module name, a dot, and a valid binding name.
    qualified: struct { module: ModuleName, binding: BindingName },
    /// Dotted, and none of the above.
    malformed,
};

/// What `id` is as a word. Every id an interning cursor returned, and every
/// part of a spelling so returned, has been decided.
pub fn spelling(id: u32) Spelling {
    const found = process_table.entry(id);
    return switch (found.decided.load(.acquire)) {
        0 => unreachable,
        1 => .plain,
        2 => .{ .core = @fromBackingInt(found.binding) },
        3 => .{ .qualified = .{ .module = @fromBackingInt(found.module), .binding = @fromBackingInt(found.binding) } },
        else => .malformed,
    };
}

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
    buckets: [bucket_count]AtomicBucket = @splat(AtomicBucket.init(no_entry)),
    count: std.atomic.Value(u32) = .init(0),
    entry_segments: [max_segments]AtomicEntrySegment = @splat(AtomicEntrySegment.init(null)),
    byte_segments: [max_segments]AtomicByteSegment = @splat(AtomicByteSegment.init(null)),
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

    /// The entry `id` identifies. Everything but `decided` is immutable once
    /// the id exists.
    fn entry(self: *const Table, id: u32) *Entry {
        return &self.entry_segments[id / entries_per_segment].load(.acquire).?.entries[id % entries_per_segment];
    }

    pub fn getBytes(self: *const Table, id: u32) ?[]const u8 {
        if (id >= self.count.load(.acquire)) return null;
        const found = self.entry(id);
        const byte_segment = self.byte_segments[found.byte_segment].load(.acquire).?;
        return byte_segment.bytes[found.offset..][0..found.len];
    }

    fn isDecided(self: *const Table, id: u32) bool {
        return self.entry(id).decided.load(.acquire) != 0;
    }

    /// Records what `id` is as a word, unless another interner already has:
    /// the answer is a function of the bytes, so both would store the same.
    fn decide(self: *Table, id: u32, what: Spelling) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const found = self.entry(id);
        if (found.decided.load(.monotonic) != 0) return;
        switch (what) {
            .plain, .malformed => {},
            .core => |binding| found.binding = bindingId(binding),
            .qualified => |parts| {
                found.module = @backingInt(parts.module);
                found.binding = bindingId(parts.binding);
            },
        }
        found.decided.store(@as(u8, @backingInt(what)) + 1, .release);
    }

    pub const LookupProgress = poll.Progress(?u32);
    pub const LookupCursor = struct {
        table: *const Table,
        bytes: []const u8,
        hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
        hash_index: usize = 0,
        hash: ?u64 = null,
        /// Whether an entry not yet decided is found too.
        any: bool = false,
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
            const candidate = self.table.entry(self.entry_id);
            if (!self.entry_loaded) {
                self.entry_loaded = true;
                self.compare_index = 0;
                if (candidate.hash != self.hash.? or candidate.len != self.bytes.len) {
                    self.entry_id = candidate.next;
                    self.entry_loaded = false;
                }
                return .pending;
            }
            const stored = self.table.getBytes(self.entry_id).?;
            const end = @min(self.compare_index + 256, self.bytes.len);
            if (!std.mem.eql(u8, self.bytes[self.compare_index..end], stored[self.compare_index..end])) {
                self.entry_id = candidate.next;
                self.entry_loaded = false;
                return .pending;
            }
            self.compare_index = end;
            if (end != self.bytes.len) return .pending;
            // An entry whose interning was abandoned before its spelling was
            // decided is no symbol yet: only an interning cursor returns it.
            if (!self.any and candidate.decided.load(.acquire) == 0) return .{ .complete = null };
            return .{ .complete = self.entry_id };
        }
    };
    pub fn lookupCursor(self: *const Table, bytes: []const u8) LookupCursor {
        return .{ .table = self, .bytes = bytes };
    }

    pub const InternProgress = poll.Progress(u32);

    /// Finds or appends the entry for `bytes`, deciding nothing about it.
    const EntryCursor = struct {
        table: *Table,
        bytes: []const u8,
        lookup: LookupCursor,
        reservation: ?Reservation = null,
        copy_index: usize = 0,
        phase: enum { lookup, reserve, copy, recheck, commit, complete } = .lookup,

        fn init(table: *Table, bytes: []const u8) EntryCursor {
            return .{ .table = table, .bytes = bytes, .lookup = .{ .table = table, .bytes = bytes, .any = true } };
        }

        /// For `bytes` that are `length` bytes at `start` of entry `whole`:
        /// a new entry shares that storage instead of copying it.
        fn initPart(table: *Table, whole: u32, start: usize, length: usize) EntryCursor {
            const stored = table.entry(whole);
            var cursor = EntryCursor.init(table, table.getBytes(whole).?[start..][0..length]);
            cursor.reservation = .{
                .segment = table.byte_segments[stored.byte_segment].load(.acquire).?,
                .segment_index = stored.byte_segment,
                .offset = stored.offset + start,
            };
            return cursor;
        }

        fn advance(self: *EntryCursor) error{OutOfMemory}!InternProgress {
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
                    std.Io.Threaded.mutexLockUncancelable(&self.table.mutex);
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
                        self.lookup = .{ .table = self.table, .bytes = self.bytes, .any = true };
                        self.phase = .recheck;
                    }
                    break :result .pending;
                },
                .commit => result: {
                    std.Io.Threaded.mutexLockUncancelable(&self.table.mutex);
                    defer std.Io.Threaded.mutexUnlock(&self.table.mutex);
                    const hash = self.lookup.hash.?;
                    const bucket = bucketIndex(hash);
                    if (self.table.buckets[bucket].load(.acquire) != self.lookup.initial_head) {
                        self.lookup = .{ .table = self.table, .bytes = self.bytes, .any = true };
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

    /// Decides what entry `target` is as a word, and with it every dotted
    /// prefix of the spelling and every segment, shortest first: a spelling
    /// is decided only after its parts, so a decided spelling's parts are
    /// decided. A prefix or segment shares the target's stored bytes. A
    /// spelling of `d` dots whose prefixes are new walks its bytes `d` times.
    const SpellingCursor = struct {
        table: *Table,
        target: u32,
        bytes: []const u8,
        phase: enum { scan, extent, prefix, level, segment, module, binding } = .scan,
        index: usize = 0,
        dotted: bool = false,
        /// Where the segment being decided starts and ends.
        start: usize = 0,
        end: usize = 0,
        /// The entry of the prefix before that segment, and of the prefix
        /// it ends.
        previous: u32 = no_entry,
        current: u32 = no_entry,
        segment: u32 = no_entry,
        module: ?ModuleName = null,
        work: union(enum) {
            none,
            entry: EntryCursor,
            module: ModuleNameCursor,
            binding: NamespaceCursor,
        } = .none,

        fn init(table: *Table, target: u32) SpellingCursor {
            return .{ .table = table, .target = target, .bytes = table.getBytes(target).? };
        }

        /// Records the level's answer and moves to the next prefix.
        fn settle(self: *SpellingCursor, what: Spelling) poll.Progress(void) {
            self.table.decide(self.current, what);
            return self.next();
        }

        fn next(self: *SpellingCursor) poll.Progress(void) {
            if (self.end == self.bytes.len) return .complete;
            self.previous = self.current;
            self.start = self.end + 1;
            self.index = self.start;
            self.phase = .extent;
            return .pending;
        }

        fn advance(self: *SpellingCursor) error{OutOfMemory}!poll.Progress(void) {
            switch (self.phase) {
                // One pass settles the two common answers: no dot, and a
                // dot beside nothing.
                .scan => {
                    const stop = @min(self.index + 256, self.bytes.len);
                    for (self.bytes[self.index..stop], self.index..) |byte, at| if (byte == '.') {
                        self.dotted = true;
                        if (at == self.start or at + 1 == self.bytes.len) {
                            self.table.decide(self.target, .malformed);
                            return .complete;
                        }
                        self.start = at + 1;
                    };
                    self.index = stop;
                    if (stop != self.bytes.len) return .pending;
                    if (!self.dotted) {
                        self.table.decide(self.target, .plain);
                        return .complete;
                    }
                    self.start = 0;
                    self.index = 0;
                    self.phase = .extent;
                    return .pending;
                },
                .extent => {
                    const stop = @min(self.index + 256, self.bytes.len);
                    const dot = std.mem.indexOfScalarPos(u8, self.bytes[0..stop], self.index, '.');
                    self.index = dot orelse stop;
                    if (dot == null and stop != self.bytes.len) return .pending;
                    self.end = self.index;
                    if (self.end == self.bytes.len) {
                        self.current = self.target;
                        self.phase = .level;
                    } else {
                        self.work = .{ .entry = .initPart(self.table, self.target, 0, self.end) };
                        self.phase = .prefix;
                    }
                    return .pending;
                },
                .prefix => switch (try self.work.entry.advance()) {
                    .pending => return .pending,
                    .complete => |id| {
                        self.current = id;
                        self.phase = .level;
                        return .pending;
                    },
                },
                .level => {
                    if (self.table.isDecided(self.current)) return self.next();
                    if (self.previous == no_entry) return self.settle(.plain);
                    self.work = .{ .entry = .initPart(self.table, self.target, self.start, self.end - self.start) };
                    self.phase = .segment;
                    return .pending;
                },
                .segment => switch (try self.work.entry.advance()) {
                    .pending => return .pending,
                    .complete => |id| {
                        self.segment = id;
                        self.table.decide(id, .plain);
                        // `core` is a scope, not a registration.
                        if (isReservedRegistryBytes(self.bytes[0 .. self.start - 1]))
                            return self.settle(.{ .core = @fromBackingInt(id) });
                        self.work = .{ .module = .of(self.previous, self.bytes[0 .. self.start - 1]) };
                        self.phase = .module;
                        return .pending;
                    },
                },
                .module => switch (self.work.module.advance()) {
                    .pending => return .pending,
                    .complete => |maybe_module| {
                        self.module = maybe_module orelse return self.settle(.malformed);
                        self.work = .{ .binding = .of(self.segment, self.bytes[self.start..self.end]) };
                        self.phase = .binding;
                        return .pending;
                    },
                },
                .binding => switch (self.work.binding.advance()) {
                    .pending => return .pending,
                    .complete => |maybe_binding| {
                        const binding = maybe_binding orelse return self.settle(.malformed);
                        return self.settle(.{ .qualified = .{ .module = self.module.?, .binding = binding } });
                    },
                },
            }
        }
    };

    /// Finds or appends the entry for `bytes` and decides what it is as a
    /// word before returning its id.
    pub const InternCursor = struct {
        found: EntryCursor,
        spelling: ?SpellingCursor = null,

        pub fn advance(self: *InternCursor) error{OutOfMemory}!InternProgress {
            if (self.spelling) |*deciding| return switch (try deciding.advance()) {
                .pending => .pending,
                .complete => .{ .complete = deciding.target },
            };
            switch (try self.found.advance()) {
                .pending => {},
                .complete => |id| {
                    if (self.found.table.isDecided(id)) return .{ .complete = id };
                    self.spelling = .init(self.found.table, id);
                },
            }
            return .pending;
        }
    };
    pub fn internCursor(self: *Table, bytes: []const u8) InternCursor {
        return .{ .found = .init(self, bytes) };
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
    /// The runtime installs the words it reserves; the reservation exists to
    /// keep every other publisher off them, so core installation is the one
    /// caller that passes this.
    reserved_ok: bool = false,
    pub fn init(id: u32) NamespaceCursor {
        return of(id, get(id));
    }
    /// For entry `id` of any table, whose spelling is `bytes`.
    fn of(id: u32, bytes: []const u8) NamespaceCursor {
        return .{ .id = id, .bytes = bytes, .lexical = .initSpellingSegment(bytes) };
    }
    pub fn initReserved(id: u32) NamespaceCursor {
        var cursor = init(id);
        cursor.reserved_ok = true;
        return cursor;
    }
    pub fn advance(self: *NamespaceCursor) NamespaceProgress {
        if (self.bytes.len == 0 or (!self.reserved_ok and isReservedWordBytes(self.bytes)))
            return .{ .complete = null };
        return switch (self.lexical.advance()) {
            .pending => .pending,
            .complete => |valid| .{ .complete = if (valid) @fromBackingInt(@intCast(self.id)) else null },
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
        return of(id, get(id));
    }
    /// For entry `id` of any table, whose spelling is `bytes`.
    fn of(id: u32, bytes: []const u8) ModuleNameCursor {
        // A module name is also a registry and path component, so it keeps the
        // bare-segment grammar rather than the open spelling grammar.
        return .{ .id = id, .bytes = bytes, .lexical = .initSource(bytes) };
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
                @fromBackingInt(@intCast(self.id | if (self.dotted) dotted_module_mask else 0))
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

/// The exact spelling reserved for the core qualifier: `core.dup` reaches the
/// core scope, so no module or alias may publish under this name. It is a
/// whole-name rule, not a segment rule; `core.utils` stays an ordinary module.
pub fn isReservedRegistryBytes(name: []const u8) bool {
    return std.mem.eql(u8, name, "core");
}

pub fn isReservedBytes(name: []const u8) bool {
    return std.mem.eql(u8, name, "--") or std.mem.eql(u8, name, ":") or
        std.mem.eql(u8, name, lexer.row_token);
}

/// The locals backend's three spellings. The reader lowers `|a b|` into
/// them: load the declared names, get one by index, drop them at the end.
pub const locals_load = "_ll";
pub const locals_get = "_gl";
pub const locals_drop = "_dl";
/// The two operations only a flattened list holds: the guard at the start of
/// a flattened phrase, and the publication check after a quotation that ran
/// by its summary. No reader emits them and no flattened list is a value a
/// program can hold, so an occurrence is only ever dispatched by the operand
/// flag in its link. The names are therefore not reserved: a word a program
/// calls `_fg` is an ordinary word and never meets these.
pub const locals_guard = "_fg";
pub const locals_recheck = "_fc";

/// The locals backend's interned names. Because they are reserved from every
/// publication, in every scope they can only mean their core primitives, and
/// a dispatcher holding these ids may bind them without a lookup.
pub const LocalsWords = struct {
    load: u32,
    get: u32,
    drop: u32,
    guard: u32,
    recheck: u32,

    pub fn mint() error{OutOfMemory}!LocalsWords {
        return .{
            .load = try intern(locals_load),
            .get = try intern(locals_get),
            .drop = try intern(locals_drop),
            .guard = try intern(locals_guard),
            .recheck = try intern(locals_recheck),
        };
    }
};

/// Every binding name the language reserves for itself. The locals
/// backend is reserved because the reader emits those three words into every
/// lowered locals body: a session definition of `_gl` would otherwise
/// silently change what `|x|` means everywhere.
pub fn isReservedWordBytes(name: []const u8) bool {
    return isReservedBytes(name) or
        std.mem.eql(u8, name, locals_load) or
        std.mem.eql(u8, name, locals_get) or
        std.mem.eql(u8, name, locals_drop);
}
