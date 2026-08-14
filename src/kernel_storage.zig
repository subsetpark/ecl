//! Poll-aware construction, lookup, and update for kernel-owned traversals.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");

const Value = value.Value;
const Header = value.Header;

const ProfileKind = enum { empty, int, float, char, symbol, mixed };
const Profile = struct { kind: ProfileKind, max_codepoint: u32 = 0 };

pub const MaterializeResult = union(enum) {
    pending,
    complete: Value,
};

pub const Utf8MaterializeResult = union(enum) { pending, complete: Value };

/// Exact-size resumable UTF-8 decoding. The first pass fixes both codepoint
/// count and leaf width; the second fills the published representation.
pub const Utf8Materializer = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    phase: enum { scan, fill, complete } = .scan,
    byte_index: usize = 0,
    value_index: usize = 0,
    count: usize = 0,
    max_codepoint: u32 = 0,
    header: ?*heap.InitializingHeader = null,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) Utf8Materializer {
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn deinit(self: *Utf8Materializer) void {
        if (self.header) |header| heap.decRef(self.allocator, heap.publish(header));
        self.* = undefined;
    }

    pub fn advance(
        self: *Utf8Materializer,
        budget: usize,
    ) (error{OutOfMemory} || error{InvalidUtf8})!Utf8MaterializeResult {
        std.debug.assert(budget != 0 and self.phase != .complete);
        var remaining = budget;
        while (remaining != 0) {
            switch (self.phase) {
                .scan => {
                    if (self.byte_index == self.bytes.len) {
                        try self.beginFill();
                        continue;
                    }
                    const codepoint = try decodeUtf8Codepoint(self.bytes, &self.byte_index);
                    self.max_codepoint = @max(self.max_codepoint, codepoint);
                    self.count = std.math.add(usize, self.count, 1) catch return error.OutOfMemory;
                    remaining -= 1;
                },
                .fill => {
                    if (self.byte_index == self.bytes.len) return self.finish();
                    const codepoint = try decodeUtf8Codepoint(self.bytes, &self.byte_index);
                    switch (heap.publish(self.header.?).kind()) {
                        .leaf_char1 => heap.initChars8(self.header.?)[self.value_index] = @intCast(codepoint),
                        .leaf_char2 => heap.initChars16(self.header.?)[self.value_index] = @intCast(codepoint),
                        .leaf_char4 => heap.initChars32(self.header.?)[self.value_index] = codepoint,
                        else => unreachable,
                    }
                    self.value_index += 1;
                    remaining -= 1;
                },
                .complete => unreachable,
            }
        }
        if (self.phase == .scan and self.byte_index == self.bytes.len) try self.beginFill();
        if (self.phase == .fill and self.byte_index == self.bytes.len) return self.finish();
        return .pending;
    }

    fn beginFill(self: *Utf8Materializer) error{OutOfMemory}!void {
        const kind: value.HeapKind = if (self.max_codepoint <= std.math.maxInt(u8))
            .leaf_char1
        else if (self.max_codepoint <= std.math.maxInt(u16))
            .leaf_char2
        else
            .leaf_char4;
        self.header = try heap.allocHeader(self.allocator, kind, self.count, initialCapacity(self.count));
        self.phase = .fill;
        self.byte_index = 0;
    }

    fn finish(self: *Utf8Materializer) Utf8MaterializeResult {
        const header = self.header.?;
        self.header = null;
        self.phase = .complete;
        return .{ .complete = .{ .list = heap.publish(header) } };
    }
};

pub const ByteStringMaterializer = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: ?*heap.InitializingHeader = null,
    index: usize = 0,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) ByteStringMaterializer {
        return .{ .allocator = allocator, .bytes = bytes };
    }
    pub fn deinit(self: *ByteStringMaterializer) void {
        if (self.header) |header| heap.decRef(self.allocator, heap.publish(header));
        self.* = undefined;
    }
    pub fn advance(self: *ByteStringMaterializer, budget: usize) error{OutOfMemory}!Utf8MaterializeResult {
        std.debug.assert(budget != 0 and !self.complete);
        if (self.header == null) self.header = try heap.allocHeader(
            self.allocator,
            .leaf_char1,
            self.bytes.len,
            initialCapacity(self.bytes.len),
        );
        const end = @min(self.index + budget, self.bytes.len);
        @memcpy(heap.initChars8(self.header.?)[self.index..end], self.bytes[self.index..end]);
        self.index = end;
        if (self.index != self.bytes.len) return .pending;
        const header = self.header.?;
        self.header = null;
        self.complete = true;
        return .{ .complete = .{ .list = heap.publish(header) } };
    }
};

/// Resumable equivalent of the language's text convention: valid UTF-8 is
/// decoded to scalars, while opaque host bytes map one-to-one to characters.
pub const TextMaterializer = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    utf8: ?Utf8Materializer,
    raw: ?ByteStringMaterializer = null,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) TextMaterializer {
        return .{ .allocator = allocator, .bytes = bytes, .utf8 = .init(allocator, bytes) };
    }
    pub fn deinit(self: *TextMaterializer) void {
        if (self.utf8) |*materializer| materializer.deinit();
        if (self.raw) |*materializer| materializer.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *TextMaterializer, budget: usize) error{OutOfMemory}!Utf8MaterializeResult {
        if (self.utf8) |*materializer| {
            return materializer.advance(budget) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidUtf8 => result: {
                    materializer.deinit();
                    self.utf8 = null;
                    self.raw = .init(self.allocator, self.bytes);
                    break :result .pending;
                },
            };
        }
        return self.raw.?.advance(budget);
    }
};

pub const StringEncodeResult = union(enum) { pending, complete: []u8 };

/// Exact-size resumable encoding for language strings. The first pass counts
/// bytes and validates scalars; the second writes one codepoint per step.
pub const StringEncoder = struct {
    allocator: std.mem.Allocator,
    string: Value,
    phase: enum { count, fill, complete } = .count,
    index: usize = 0,
    byte_count: usize = 0,
    output: ?[]u8 = null,
    written: usize = 0,

    pub fn init(allocator: std.mem.Allocator, string: Value) StringEncoder {
        std.debug.assert(string.isString());
        return .{ .allocator = allocator, .string = string };
    }

    pub fn deinit(self: *StringEncoder) void {
        if (self.output) |output| self.allocator.free(output);
        self.* = undefined;
    }

    pub fn advance(
        self: *StringEncoder,
        budget: usize,
    ) (error{OutOfMemory} || error{InvalidCodepoint})!StringEncodeResult {
        std.debug.assert(budget != 0 and self.phase != .complete);
        const count: usize = @intCast(self.string.list.length());
        var remaining = budget;
        while (remaining != 0 and self.index != count) : (remaining -= 1) {
            const codepoint = list.atUnchecked(self.string, self.index).char;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch
                return error.InvalidCodepoint;
            switch (self.phase) {
                .count => self.byte_count = std.math.add(usize, self.byte_count, encoded_len) catch
                    return error.OutOfMemory,
                .fill => {
                    @memcpy(self.output.?[self.written..][0..encoded_len], encoded[0..encoded_len]);
                    self.written += encoded_len;
                },
                .complete => unreachable,
            }
            self.index += 1;
        }
        if (self.index != count) return .pending;
        switch (self.phase) {
            .count => {
                self.output = try self.allocator.alloc(u8, self.byte_count);
                self.phase = .fill;
                self.index = 0;
                return .pending;
            },
            .fill => {
                std.debug.assert(self.written == self.output.?.len);
                const output = self.output.?;
                self.output = null;
                self.phase = .complete;
                return .{ .complete = output };
            },
            .complete => unreachable,
        }
    }
};

pub const I64MaterializeResult = union(enum) { pending, complete: Value };

pub const CodepointMaterializer = struct {
    allocator: std.mem.Allocator,
    source: []const u32,
    phase: enum { profile, fill, complete } = .profile,
    index: usize = 0,
    max_codepoint: u32 = 0,
    header: ?*heap.InitializingHeader = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u32) CodepointMaterializer {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *CodepointMaterializer) void {
        if (self.header) |header| heap.decRef(self.allocator, heap.publish(header));
        self.* = undefined;
    }

    pub fn advance(self: *CodepointMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(budget != 0 and self.phase != .complete);
        var remaining = budget;
        while (remaining != 0) switch (self.phase) {
            .profile => {
                if (self.index == self.source.len) {
                    const kind: value.HeapKind = if (self.max_codepoint <= std.math.maxInt(u8))
                        .leaf_char1
                    else if (self.max_codepoint <= std.math.maxInt(u16))
                        .leaf_char2
                    else
                        .leaf_char4;
                    self.header = try heap.allocHeader(
                        self.allocator,
                        kind,
                        self.source.len,
                        initialCapacity(self.source.len),
                    );
                    self.phase = .fill;
                    self.index = 0;
                    continue;
                }
                self.max_codepoint = @max(self.max_codepoint, self.source[self.index]);
                self.index += 1;
                remaining -= 1;
            },
            .fill => {
                if (self.index == self.source.len) return self.finish();
                const codepoint = self.source[self.index];
                switch (heap.publish(self.header.?).kind()) {
                    .leaf_char1 => heap.initChars8(self.header.?)[self.index] = @intCast(codepoint),
                    .leaf_char2 => heap.initChars16(self.header.?)[self.index] = @intCast(codepoint),
                    .leaf_char4 => heap.initChars32(self.header.?)[self.index] = codepoint,
                    else => unreachable,
                }
                self.index += 1;
                remaining -= 1;
            },
            .complete => unreachable,
        };
        if (self.phase == .fill and self.index == self.source.len) return self.finish();
        return .pending;
    }

    fn finish(self: *CodepointMaterializer) MaterializeResult {
        const header = self.header.?;
        self.header = null;
        self.phase = .complete;
        return .{ .complete = .{ .list = heap.publish(header) } };
    }
};

pub const I64Materializer = struct {
    allocator: std.mem.Allocator,
    source: []const i64,
    header: ?*heap.InitializingHeader = null,
    index: usize = 0,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const i64) I64Materializer {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *I64Materializer) void {
        if (self.header) |header| heap.decRef(self.allocator, heap.publish(header));
        self.* = undefined;
    }

    pub fn advance(self: *I64Materializer, budget: usize) error{OutOfMemory}!I64MaterializeResult {
        std.debug.assert(budget != 0 and !self.complete);
        if (self.header == null) self.header = try heap.allocHeader(
            self.allocator,
            .leaf_i64,
            self.source.len,
            initialCapacity(self.source.len),
        );
        const end = @min(self.index + budget, self.source.len);
        @memcpy(heap.initI64s(self.header.?)[self.index..end], self.source[self.index..end]);
        self.index = end;
        if (self.index != self.source.len) return .pending;
        const header = self.header.?;
        self.header = null;
        self.complete = true;
        return .{ .complete = .{ .list = heap.publish(header) } };
    }
};

pub const DictMaterializeProgress = union(enum) {
    pending,
    complete: Value,
    duplicate_key,
};

/// Resumable dictionary construction. Hashing, optional duplicate checking,
/// and each exact-size child materialization preserve their own cursors.
pub const DictMaterializer = struct {
    allocator: std.mem.Allocator,
    pairs: []const dict.Pair,
    check_duplicates: bool,
    keys: []Value,
    vals: []Value,
    hashes: []i64,
    phase: enum { hash, duplicate, keys, vals, hashes, finish, complete } = .hash,
    index: usize = 0,
    candidate: usize = 0,
    hash_cursor: ?equal.HashCursor = null,
    match_cursor: ?equal.MatchCursor = null,
    keys_materializer: ?ValueMaterializer = null,
    vals_materializer: ?ValueMaterializer = null,
    hashes_materializer: ?I64Materializer = null,
    keys_value: ?Value = null,
    vals_value: ?Value = null,
    hashes_value: ?Value = null,

    pub fn init(
        allocator: std.mem.Allocator,
        pairs: []const dict.Pair,
        check_duplicates: bool,
    ) error{OutOfMemory}!DictMaterializer {
        if (pairs.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        const keys = try allocator.alloc(Value, pairs.len);
        errdefer allocator.free(keys);
        const vals = try allocator.alloc(Value, pairs.len);
        errdefer allocator.free(vals);
        const hashes = try allocator.alloc(i64, pairs.len);
        return .{
            .allocator = allocator,
            .pairs = pairs,
            .check_duplicates = check_duplicates,
            .keys = keys,
            .vals = vals,
            .hashes = hashes,
        };
    }

    pub fn deinit(self: *DictMaterializer) void {
        if (self.hash_cursor) |*cursor| cursor.deinit();
        if (self.match_cursor) |*cursor| cursor.deinit();
        if (self.keys_materializer) |*materializer| materializer.deinit();
        if (self.vals_materializer) |*materializer| materializer.deinit();
        if (self.hashes_materializer) |*materializer| materializer.deinit();
        if (self.keys_value) |item| heap.releaseValue(self.allocator, item);
        if (self.vals_value) |item| heap.releaseValue(self.allocator, item);
        if (self.hashes_value) |item| heap.releaseValue(self.allocator, item);
        self.allocator.free(self.keys);
        self.allocator.free(self.vals);
        self.allocator.free(self.hashes);
        self.* = undefined;
    }

    pub fn advance(
        self: *DictMaterializer,
        budget: usize,
    ) error{OutOfMemory}!DictMaterializeProgress {
        std.debug.assert(budget != 0 and self.phase != .complete);
        while (true) switch (self.phase) {
            .hash => {
                if (self.index == self.pairs.len) {
                    self.keys_materializer = .init(self.allocator, self.keys);
                    self.phase = .keys;
                    continue;
                }
                if (self.hash_cursor == null)
                    self.hash_cursor = try .init(self.allocator, self.pairs[self.index][0]);
                switch (try self.hash_cursor.?.advance(budget)) {
                    .pending => return .pending,
                    .complete => |computed| {
                        self.hash_cursor.?.deinit();
                        self.hash_cursor = null;
                        self.keys[self.index] = self.pairs[self.index][0];
                        self.vals[self.index] = self.pairs[self.index][1];
                        self.hashes[self.index] = @bitCast(computed);
                        if (self.check_duplicates and self.index != 0) {
                            self.candidate = 0;
                            self.phase = .duplicate;
                        } else self.index += 1;
                        return .pending;
                    },
                }
            },
            .duplicate => {
                var remaining = budget;
                while (remaining != 0 and self.candidate != self.index) {
                    if (self.hashes[self.candidate] != self.hashes[self.index]) {
                        self.candidate += 1;
                        remaining -= 1;
                        continue;
                    }
                    if (self.match_cursor == null) self.match_cursor = try .init(
                        self.allocator,
                        self.keys[self.candidate],
                        self.keys[self.index],
                    );
                    switch (try self.match_cursor.?.advance(remaining)) {
                        .pending => return .pending,
                        .complete => |matches| {
                            self.match_cursor.?.deinit();
                            self.match_cursor = null;
                            if (matches) return .duplicate_key;
                            self.candidate += 1;
                            return .pending;
                        },
                    }
                }
                if (self.candidate != self.index) return .pending;
                self.index += 1;
                self.phase = .hash;
                return .pending;
            },
            .keys => switch (try self.keys_materializer.?.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.keys_value = item;
                    self.vals_materializer = .init(self.allocator, self.vals);
                    self.phase = .vals;
                    return .pending;
                },
            },
            .vals => switch (try self.vals_materializer.?.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.vals_value = item;
                    self.hashes_materializer = .init(self.allocator, self.hashes);
                    self.phase = .hashes;
                    return .pending;
                },
            },
            .hashes => switch (try self.hashes_materializer.?.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.hashes_value = item;
                    self.phase = .finish;
                    continue;
                },
            },
            .finish => {
                const header = try heap.allocHeader(
                    self.allocator,
                    .dict,
                    self.pairs.len,
                    self.pairs.len,
                );
                heap.initDictStorage(header).* = .{
                    .payload = .{
                        .keys = self.keys_value.?.list,
                        .vals = self.vals_value.?.list,
                        .hashes = self.hashes_value.?.list,
                    },
                    .initialized = true,
                };
                self.keys_value = null;
                self.vals_value = null;
                self.hashes_value = null;
                self.phase = .complete;
                return .{ .complete = .{ .dict = heap.publish(header) } };
            },
            .complete => unreachable,
        };
    }
};

pub const DictFindProgress = union(enum) { pending, complete: ?Value };

/// Resumable structural dictionary lookup. Stored hashes eliminate most key
/// comparisons; a matching candidate embeds the owned equality cursor.
pub const DictFindCursor = struct {
    allocator: std.mem.Allocator,
    header: *Header,
    key: Value,
    key_hash: ?u64 = null,
    hash_cursor: ?equal.HashCursor = null,
    match_cursor: ?equal.MatchCursor = null,
    candidate: usize = 0,

    pub fn init(allocator: std.mem.Allocator, dictionary: Value, key: Value) error{NotADict}!DictFindCursor {
        if (dictionary != .dict) return error.NotADict;
        return initHeader(allocator, dictionary.dict, key);
    }

    pub fn initHeader(allocator: std.mem.Allocator, header: *Header, key: Value) DictFindCursor {
        std.debug.assert(header.kind() == .dict);
        return .{ .allocator = allocator, .header = header, .key = key };
    }

    pub fn deinit(self: *DictFindCursor) void {
        if (self.hash_cursor) |*cursor| cursor.deinit();
        if (self.match_cursor) |*cursor| cursor.deinit();
        self.* = undefined;
    }

    pub fn foundIndex(self: *const DictFindCursor) ?usize {
        return if (self.candidate < @as(usize, @intCast(self.header.length()))) self.candidate else null;
    }

    pub fn advance(self: *DictFindCursor, budget: usize) error{OutOfMemory}!DictFindProgress {
        std.debug.assert(budget != 0);
        if (self.key_hash == null) {
            if (self.hash_cursor == null) self.hash_cursor = try .init(self.allocator, self.key);
            switch (try self.hash_cursor.?.advance(budget)) {
                .pending => return .pending,
                .complete => |computed| {
                    self.hash_cursor.?.deinit();
                    self.hash_cursor = null;
                    self.key_hash = computed;
                    return .pending;
                },
            }
        }
        const count: usize = @intCast(self.header.length());
        var remaining = budget;
        while (remaining != 0 and self.candidate != count) {
            const stored = dict.hashAt(self.header, self.candidate);
            if (stored != self.key_hash.?) {
                self.candidate += 1;
                remaining -= 1;
                continue;
            }
            if (self.match_cursor == null) self.match_cursor = try .init(
                self.allocator,
                dict.keyAt(self.header, self.candidate),
                self.key,
            );
            switch (try self.match_cursor.?.advance(remaining)) {
                .pending => return .pending,
                .complete => |matches| {
                    self.match_cursor.?.deinit();
                    self.match_cursor = null;
                    if (matches) return .{ .complete = dict.valueAt(self.header, self.candidate) };
                    self.candidate += 1;
                    return .pending;
                },
            }
        }
        return if (self.candidate == count) .{ .complete = null } else .pending;
    }
};

/// Exact-size, resumable list construction for scheduler-owned work. The
/// caller owns `source` until completion and chooses the per-resume budget.
pub const ValueMaterializer = struct {
    allocator: std.mem.Allocator,
    source: []const Value,
    phase: Phase = .profile,
    index: usize = 0,
    item_profile: Profile = .{ .kind = .empty },
    header: ?*heap.InitializingHeader = null,

    const Phase = enum { profile, fill, complete };

    pub fn init(allocator: std.mem.Allocator, source: []const Value) ValueMaterializer {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *ValueMaterializer) void {
        if (self.header) |header| heap.decRef(self.allocator, heap.publish(header));
        self.* = undefined;
    }

    pub fn advance(self: *ValueMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(budget != 0 and self.phase != .complete);
        var remaining = budget;
        while (remaining != 0) {
            switch (self.phase) {
                .profile => {
                    if (self.index == self.source.len) {
                        try self.beginFill();
                        continue;
                    }
                    self.profileOne(self.source[self.index]);
                    self.index += 1;
                    remaining -= 1;
                    if (self.item_profile.kind == .mixed) self.index = self.source.len;
                },
                .fill => {
                    if (self.index == self.source.len) return self.finish();
                    self.fillOne(self.source[self.index], self.index);
                    self.index += 1;
                    remaining -= 1;
                },
                .complete => unreachable,
            }
        }
        if (self.phase == .profile and self.index == self.source.len) try self.beginFill();
        if (self.phase == .fill and self.index == self.source.len) return self.finish();
        return .pending;
    }

    fn profileOne(self: *ValueMaterializer, item: Value) void {
        if (self.index == 0) {
            self.item_profile = switch (item) {
                .int => .{ .kind = .int },
                .float => .{ .kind = .float },
                .char => |codepoint| .{ .kind = .char, .max_codepoint = codepoint },
                .symbol => .{ .kind = .symbol },
                .word, .list, .dict, .task => .{ .kind = .mixed },
            };
            return;
        }
        switch (self.item_profile.kind) {
            .empty => unreachable,
            .int => {
                if (item != .int) self.item_profile.kind = .mixed;
            },
            .float => {
                if (item != .float) self.item_profile.kind = .mixed;
            },
            .char => if (item == .char) {
                self.item_profile.max_codepoint = @max(self.item_profile.max_codepoint, item.char);
            } else {
                self.item_profile.kind = .mixed;
            },
            .symbol => {
                if (item != .symbol) self.item_profile.kind = .mixed;
            },
            .mixed => {},
        }
    }

    fn beginFill(self: *ValueMaterializer) error{OutOfMemory}!void {
        const kind: value.HeapKind = switch (self.item_profile.kind) {
            .empty, .mixed => .generic_spine,
            .int => .leaf_i64,
            .float => .leaf_f64,
            .char => if (self.item_profile.max_codepoint <= std.math.maxInt(u8))
                .leaf_char1
            else if (self.item_profile.max_codepoint <= std.math.maxInt(u16))
                .leaf_char2
            else
                .leaf_char4,
            .symbol => .leaf_symbol,
        };
        const header = try heap.allocHeader(
            self.allocator,
            kind,
            self.source.len,
            initialCapacity(self.source.len),
        );
        if (kind == .generic_spine) heap.setInitializingLength(header, 0);
        self.header = header;
        self.phase = .fill;
        self.index = 0;
    }

    fn fillOne(self: *ValueMaterializer, item: Value, index: usize) void {
        const header = self.header.?;
        switch (heap.publish(header).kind()) {
            .generic_spine => {
                heap.retainValue(item);
                heap.initValues(header)[index] = item;
                heap.setInitializingLength(header, index + 1);
            },
            .leaf_i64 => heap.initI64s(header)[index] = item.int,
            .leaf_f64 => heap.initF64s(header)[index] = item.float,
            .leaf_char1 => heap.initChars8(header)[index] = @intCast(item.char),
            .leaf_char2 => heap.initChars16(header)[index] = @intCast(item.char),
            .leaf_char4 => heap.initChars32(header)[index] = item.char,
            .leaf_symbol => heap.initSymbols(header)[index] = item.symbol,
            .dict, .task, .reserved_mask => unreachable,
        }
    }

    fn finish(self: *ValueMaterializer) MaterializeResult {
        const header = self.header.?;
        self.header = null;
        self.phase = .complete;
        return .{ .complete = .{ .list = heap.publish(header) } };
    }
};

/// Exact generic-spine construction for code roots and other representation-
/// sensitive lists. Unlike ValueMaterializer, this never specializes a
/// homogeneous source.
pub const GenericValueMaterializer = struct {
    allocator: std.mem.Allocator,
    source: []const Value,
    header: ?*heap.InitializingHeader = null,
    index: usize = 0,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const Value) GenericValueMaterializer {
        return .{ .allocator = allocator, .source = source };
    }
    pub fn deinit(self: *GenericValueMaterializer) void {
        if (self.header) |header| heap.decRef(self.allocator, heap.publish(header));
        self.* = undefined;
    }
    pub fn advance(self: *GenericValueMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        std.debug.assert(budget != 0 and !self.complete);
        if (self.header == null) {
            self.header = try heap.allocHeader(
                self.allocator,
                .generic_spine,
                self.source.len,
                initialCapacity(self.source.len),
            );
            heap.setInitializingLength(self.header.?, 0);
        }
        const end = @min(self.index + budget, self.source.len);
        while (self.index != end) : (self.index += 1) {
            const item = self.source[self.index];
            heap.retainValue(item);
            heap.initValues(self.header.?)[self.index] = item;
            heap.setInitializingLength(self.header.?, self.index + 1);
        }
        if (self.index != self.source.len) return .pending;
        const header = self.header.?;
        self.header = null;
        self.complete = true;
        return .{ .complete = .{ .list = heap.publish(header) } };
    }
};

pub const ToUtf8Progress = union(enum) { pending, complete: []u8 };
pub const ToUtf8Cursor = struct {
    allocator: std.mem.Allocator,
    string: Value,
    phase: enum { count, fill, complete } = .count,
    index: usize = 0,
    byte_count: usize = 0,
    bytes: ?[]u8 = null,
    output_index: usize = 0,
    pub fn init(allocator: std.mem.Allocator, string: Value) ToUtf8Cursor {
        std.debug.assert(string.isString());
        return .{ .allocator = allocator, .string = string };
    }
    pub fn deinit(self: *ToUtf8Cursor) void {
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
    pub fn advance(self: *ToUtf8Cursor, budget: usize) (error{ OutOfMemory, InvalidCodepoint })!ToUtf8Progress {
        var remaining = budget;
        const count: usize = @intCast(self.string.list.length());
        while (remaining != 0) : (remaining -= 1) switch (self.phase) {
            .count => if (self.index != count) {
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(
                    @intCast(@import("list.zig").atUnchecked(self.string, self.index).char),
                    &encoded,
                ) catch return error.InvalidCodepoint;
                self.byte_count = std.math.add(usize, self.byte_count, length) catch
                    return error.OutOfMemory;
                self.index += 1;
            } else {
                self.bytes = try self.allocator.alloc(u8, self.byte_count);
                self.index = 0;
                self.phase = .fill;
            },
            .fill => if (self.index != count) {
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(
                    @intCast(@import("list.zig").atUnchecked(self.string, self.index).char),
                    &encoded,
                ) catch return error.InvalidCodepoint;
                @memcpy(self.bytes.?[self.output_index..][0..length], encoded[0..length]);
                self.output_index += length;
                self.index += 1;
            } else {
                const result = self.bytes.?;
                self.bytes = null;
                self.phase = .complete;
                return .{ .complete = result };
            },
            .complete => unreachable,
        };
        return .pending;
    }
};

pub fn decodeUtf8Codepoint(bytes: []const u8, index: *usize) error{InvalidUtf8}!u32 {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index.*]) catch
        return error.InvalidUtf8;
    if (length > bytes.len - index.*) return error.InvalidUtf8;
    const codepoint = std.unicode.utf8Decode(bytes[index.*..][0..length]) catch
        return error.InvalidUtf8;
    index.* += length;
    return codepoint;
}

fn initialCapacity(used: usize) usize {
    var result: usize = 4;
    while (result < @max(used, 1)) result = std.math.mul(usize, result, 2) catch return used;
    return result;
}

test "list materializers expose bounded profiling and copy transitions" {
    var values_builder = ValueMaterializer.init(
        std.testing.allocator,
        &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } },
    );
    defer values_builder.deinit();
    var value_steps: usize = 0;
    const values = while (true) {
        value_steps += 1;
        switch (try values_builder.advance(1)) {
            .pending => {},
            .complete => |item| break item,
        }
    };
    defer heap.releaseValue(std.testing.allocator, values);
    try std.testing.expectEqual(@as(usize, 6), value_steps);

    var integer_builder = I64Materializer.init(std.testing.allocator, &.{ 1, 2, 3 });
    defer integer_builder.deinit();
    var integer_steps: usize = 0;
    const integers = while (true) {
        integer_steps += 1;
        switch (try integer_builder.advance(1)) {
            .pending => {},
            .complete => |item| break item,
        }
    };
    defer heap.releaseValue(std.testing.allocator, integers);
    try std.testing.expectEqual(@as(usize, 3), integer_steps);

    var text_builder = CodepointMaterializer.init(std.testing.allocator, &.{ 'a', 0x100, 0x10000 });
    defer text_builder.deinit();
    var text_steps: usize = 0;
    const text = while (true) {
        text_steps += 1;
        switch (try text_builder.advance(1)) {
            .pending => {},
            .complete => |item| break item,
        }
    };
    defer heap.releaseValue(std.testing.allocator, text);
    try std.testing.expectEqual(@as(usize, 6), text_steps);
}
