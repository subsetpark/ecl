//! Poll-aware construction, lookup, and update for kernel-owned traversals.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const poll = @import("poll.zig");

const Value = value.Value;
const Header = value.DictHandle;

const ProfileKind = enum { empty, int, float, char, symbol, mixed };
const Profile = struct { kind: ProfileKind, max_codepoint: u32 = 0 };

pub const MaterializeResult = poll.Progress(Value);

pub const Utf8MaterializeResult = poll.Progress(Value);

/// Exact-size resumable UTF-8 decoding. The first pass fixes both codepoint
/// count and leaf width; the second fills the published representation.
pub const Utf8Materializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    bytes: []const u8,
    phase: enum { scan, fill, complete } = .scan,
    byte_index: usize = 0,
    value_index: usize = 0,
    count: usize = 0,
    max_codepoint: u32 = 0,
    builder: ?heap.AnyListBuilder = null,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) Utf8Materializer {
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn deinit(self: *Utf8Materializer) void {
        std.debug.assert(self.builder == null);
        self.* = undefined;
    }
    pub fn retire(self: *Utf8Materializer, releases: *heap.ReleaseDomain) void {
        if (self.builder) |*builder| builder.retirePartial(releases);
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
                    self.builder.?.writeCodepoint(self.value_index, codepoint);
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
        self.builder = try .init(self.allocator, kind, self.count, initialCapacity(self.count));
        self.phase = .fill;
        self.byte_index = 0;
    }

    fn finish(self: *Utf8Materializer) Utf8MaterializeResult {
        const header = self.builder.?.finish();
        self.builder = null;
        self.phase = .complete;
        return .{ .complete = .{ .list = header } };
    }
};

fn ChunkedMaterializer(
    comptime Source: type,
    comptime Builder: type,
    comptime Context: type,
    comptime Ops: type,
) type {
    return struct {
        const Self = @This();
        pub const owned_disposal: heap.OwnedDisposal = .retire;
        allocator: std.mem.Allocator,
        source: []const Source,
        context: Context,
        builder: ?Builder = null,
        index: usize = 0,
        complete: bool = false,

        pub fn init(allocator: std.mem.Allocator, source: []const Source, context: Context) Self {
            return .{ .allocator = allocator, .source = source, .context = context };
        }
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.builder == null);
            self.* = undefined;
        }
        pub fn retire(self: *Self, releases: *heap.ReleaseDomain) void {
            if (self.builder) |*builder| builder.retirePartial(releases);
        }
        pub fn advance(self: *Self, budget: usize) error{OutOfMemory}!MaterializeResult {
            std.debug.assert(budget != 0 and !self.complete);
            if (self.builder == null)
                self.builder = try Ops.begin(self.allocator, self.source, self.context);
            const end = @min(self.index + budget, self.source.len);
            Ops.fill(&self.builder.?, self.source, &self.index, end);
            if (self.index != self.source.len) return .pending;
            const result = Ops.finish(&self.builder.?);
            self.builder = null;
            self.complete = true;
            return .{ .complete = result };
        }
    };
}

const ByteStringOps = struct {
    fn begin(
        allocator: std.mem.Allocator,
        source: []const u8,
        _: void,
    ) error{OutOfMemory}!heap.ListBuilder(.leaf_char1) {
        return .init(allocator, source.len, initialCapacity(source.len));
    }
    fn fill(
        builder: *heap.ListBuilder(.leaf_char1),
        source: []const u8,
        index: *usize,
        end: usize,
    ) void {
        @memcpy(builder.items()[index.*..end], source[index.*..end]);
        index.* = end;
    }
    fn finish(builder: *heap.ListBuilder(.leaf_char1)) Value {
        return .{ .list = builder.finish() };
    }
};

const ByteStringChunked = ChunkedMaterializer(
    u8,
    heap.ListBuilder(.leaf_char1),
    void,
    ByteStringOps,
);
pub const ByteStringMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    inner: ByteStringChunked,
    pub fn init(allocator: std.mem.Allocator, source: []const u8) ByteStringMaterializer {
        return .{ .inner = .init(allocator, source, {}) };
    }
    pub fn deinit(self: *ByteStringMaterializer) void {
        self.inner.deinit();
        self.* = undefined;
    }
    pub fn retire(self: *ByteStringMaterializer, releases: *heap.ReleaseDomain) void {
        self.inner.retire(releases);
    }
    pub fn advance(self: *ByteStringMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        return self.inner.advance(budget);
    }
};

/// Resumable equivalent of the language's text convention: valid UTF-8 is
/// decoded to scalars, while opaque host bytes map one-to-one to characters.
pub const TextMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: union(enum) {
        utf8: Utf8Materializer,
        raw: ByteStringMaterializer,
    },

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) TextMaterializer {
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .state = .{ .utf8 = .init(allocator, bytes) },
        };
    }
    pub fn deinit(self: *TextMaterializer) void {
        switch (self.state) {
            inline else => |*materializer| materializer.deinit(),
        }
        self.* = undefined;
    }
    pub fn retire(self: *TextMaterializer, releases: *heap.ReleaseDomain) void {
        switch (self.state) {
            inline else => |*materializer| materializer.retire(releases),
        }
    }
    pub fn advance(self: *TextMaterializer, budget: usize) error{OutOfMemory}!Utf8MaterializeResult {
        return switch (self.state) {
            .utf8 => |*materializer| materializer.advance(budget) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidUtf8 => result: {
                    materializer.deinit();
                    self.state = .{ .raw = .init(self.allocator, self.bytes) };
                    break :result .pending;
                },
            },
            .raw => |*materializer| materializer.advance(budget),
        };
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
            const encoded_len = std.unicode.utf8Encode(
                value.unicodeScalar(codepoint) orelse return error.InvalidCodepoint,
                &encoded,
            ) catch
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

pub const I64MaterializeResult = MaterializeResult;

const CodepointOps = struct {
    fn begin(
        allocator: std.mem.Allocator,
        source: []const u32,
        kind: value.HeapKind,
    ) error{OutOfMemory}!heap.AnyListBuilder {
        return .init(allocator, kind, source.len, initialCapacity(source.len));
    }
    fn fill(
        builder: *heap.AnyListBuilder,
        source: []const u32,
        index: *usize,
        end: usize,
    ) void {
        while (index.* != end) : (index.* += 1)
            builder.writeCodepoint(index.*, source[index.*]);
    }
    fn finish(builder: *heap.AnyListBuilder) Value {
        return .{ .list = builder.finish() };
    }
};
const CodepointFill = ChunkedMaterializer(
    u32,
    heap.AnyListBuilder,
    value.HeapKind,
    CodepointOps,
);

pub const CodepointMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    source: []const u32,
    phase: enum { profile, fill, complete } = .profile,
    index: usize = 0,
    max_codepoint: u32 = 0,
    fill: ?CodepointFill = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u32) CodepointMaterializer {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *CodepointMaterializer) void {
        std.debug.assert(self.fill == null);
        self.* = undefined;
    }
    pub fn retire(self: *CodepointMaterializer, releases: *heap.ReleaseDomain) void {
        if (self.fill) |*fill| fill.retire(releases);
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
                    self.fill = .init(self.allocator, self.source, kind);
                    self.phase = .fill;
                    continue;
                }
                self.max_codepoint = @max(self.max_codepoint, self.source[self.index]);
                self.index += 1;
                remaining -= 1;
            },
            .fill => return switch (try self.fill.?.advance(remaining)) {
                .pending => .pending,
                .complete => |result| completed: {
                    self.fill.?.deinit();
                    self.fill = null;
                    self.phase = .complete;
                    break :completed .{ .complete = result };
                },
            },
            .complete => unreachable,
        };
        return .pending;
    }
};

const I64Ops = struct {
    fn begin(
        allocator: std.mem.Allocator,
        source: []const i64,
        _: void,
    ) error{OutOfMemory}!heap.ListBuilder(.leaf_i64) {
        return .init(allocator, source.len, initialCapacity(source.len));
    }
    fn fill(
        builder: *heap.ListBuilder(.leaf_i64),
        source: []const i64,
        index: *usize,
        end: usize,
    ) void {
        @memcpy(builder.items()[index.*..end], source[index.*..end]);
        index.* = end;
    }
    fn finish(builder: *heap.ListBuilder(.leaf_i64)) Value {
        return .{ .list = builder.finish() };
    }
};
const I64Chunked = ChunkedMaterializer(i64, heap.ListBuilder(.leaf_i64), void, I64Ops);
pub const I64Materializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    inner: I64Chunked,
    pub fn init(allocator: std.mem.Allocator, source: []const i64) I64Materializer {
        return .{ .inner = .init(allocator, source, {}) };
    }
    pub fn deinit(self: *I64Materializer) void {
        self.inner.deinit();
        self.* = undefined;
    }
    pub fn retire(self: *I64Materializer, releases: *heap.ReleaseDomain) void {
        self.inner.retire(releases);
    }
    pub fn advance(self: *I64Materializer, budget: usize) error{OutOfMemory}!I64MaterializeResult {
        return self.inner.advance(budget);
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
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    const State = union(enum) {
        table_init: usize,
        hash: struct {
            index: usize = 0,
            cursor: ?equal.HashCursor = null,
        },
        duplicate: struct {
            index: usize,
            slot: usize,
            cursor: ?equal.MatchCursor = null,
        },
        keys: ValueMaterializer,
        vals: struct { keys: Value, materializer: ValueMaterializer },
        hashes: struct { keys: Value, vals: Value, materializer: I64Materializer },
        finish: struct { keys: Value, vals: Value, hashes: Value },
        complete,
    };

    allocator: std.mem.Allocator,
    source_keys: []const Value,
    source_vals: []const Value,
    check_duplicates: bool,
    keys: []Value,
    vals: []Value,
    hashes: []i64,
    table: ?[]u32,
    state: State,

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
        errdefer allocator.free(hashes);
        const table = try allocateDictIndex(allocator, pairs.len, check_duplicates);
        for (pairs, 0..) |pair, index| {
            keys[index] = pair[0];
            vals[index] = pair[1];
        }
        return initOwned(allocator, keys, vals, hashes, table, check_duplicates);
    }

    pub fn initSlices(
        allocator: std.mem.Allocator,
        source_keys: []const Value,
        source_vals: []const Value,
        check_duplicates: bool,
    ) error{OutOfMemory}!DictMaterializer {
        if (source_keys.len != source_vals.len or source_keys.len >= std.math.maxInt(u32))
            return error.OutOfMemory;
        const keys = try allocator.alloc(Value, source_keys.len);
        errdefer allocator.free(keys);
        const vals = try allocator.alloc(Value, source_vals.len);
        errdefer allocator.free(vals);
        const hashes = try allocator.alloc(i64, source_keys.len);
        errdefer allocator.free(hashes);
        const table = try allocateDictIndex(allocator, source_keys.len, check_duplicates);
        @memcpy(keys, source_keys);
        @memcpy(vals, source_vals);
        return initOwned(allocator, keys, vals, hashes, table, check_duplicates);
    }

    fn initOwned(
        allocator: std.mem.Allocator,
        keys: []Value,
        vals: []Value,
        hashes: []i64,
        table: ?[]u32,
        check_duplicates: bool,
    ) DictMaterializer {
        return .{
            .allocator = allocator,
            .source_keys = keys,
            .source_vals = vals,
            .check_duplicates = check_duplicates,
            .keys = keys,
            .vals = vals,
            .hashes = hashes,
            .table = table,
            .state = if (table != null) .{ .table_init = 0 } else .{ .hash = .{} },
        };
    }

    pub fn deinit(self: *DictMaterializer) void {
        std.debug.assert(self.state == .complete);
        self.allocator.free(self.keys);
        self.allocator.free(self.vals);
        self.allocator.free(self.hashes);
        if (self.table) |table| self.allocator.free(table);
    }
    pub fn retire(self: *DictMaterializer, releases: *heap.ReleaseDomain) void {
        switch (self.state) {
            .table_init => {},
            .hash => |*state| if (state.cursor) |*cursor| cursor.deinit(),
            .duplicate => |*state| if (state.cursor) |*cursor| cursor.deinit(),
            .keys => |*materializer| materializer.retire(releases),
            .vals => |*state| {
                state.materializer.retire(releases);
                releases.releaseValue(state.keys);
            },
            .hashes => |*state| {
                state.materializer.retire(releases);
                releases.releaseValue(state.keys);
                releases.releaseValue(state.vals);
            },
            .finish => |state| {
                releases.releaseValue(state.keys);
                releases.releaseValue(state.vals);
                releases.releaseValue(state.hashes);
            },
            .complete => {},
        }
        self.allocator.free(self.keys);
        self.allocator.free(self.vals);
        self.allocator.free(self.hashes);
        if (self.table) |table| self.allocator.free(table);
    }

    pub fn advance(
        self: *DictMaterializer,
        budget: usize,
    ) error{OutOfMemory}!DictMaterializeProgress {
        std.debug.assert(budget != 0 and self.state != .complete);
        while (true) switch (self.state) {
            .table_init => |*index| {
                const table = self.table.?;
                const end = @min(index.* + budget, table.len);
                @memset(table[index.*..end], 0);
                index.* = end;
                if (index.* != table.len) return .pending;
                self.state = .{ .hash = .{} };
                return .pending;
            },
            .hash => |*state| {
                if (state.index == self.source_keys.len) {
                    self.state = .{ .keys = .init(self.allocator, self.keys) };
                    continue;
                }
                if (state.cursor == null)
                    state.cursor = try .init(self.allocator, self.source_keys[state.index]);
                switch (try state.cursor.?.advance(budget)) {
                    .pending => return .pending,
                    .complete => |computed| {
                        state.cursor.?.deinit();
                        state.cursor = null;
                        self.hashes[state.index] = @bitCast(computed);
                        if (self.table) |table|
                            self.state = .{ .duplicate = .{
                                .index = state.index,
                                .slot = @as(usize, @intCast(computed & (table.len - 1))),
                            } }
                        else
                            state.index += 1;
                        return .pending;
                    },
                }
            },
            .duplicate => |*state| {
                var remaining = budget;
                const table = self.table.?;
                while (remaining != 0) {
                    const encoded = table[state.slot];
                    if (encoded == 0) {
                        table[state.slot] = @intCast(state.index + 1);
                        self.state = .{ .hash = .{ .index = state.index + 1 } };
                        return .pending;
                    }
                    const candidate = encoded - 1;
                    if (!self.check_duplicates or self.hashes[candidate] != self.hashes[state.index]) {
                        state.slot = (state.slot + 1) & (table.len - 1);
                        remaining -= 1;
                        continue;
                    }
                    if (state.cursor == null) state.cursor = try .init(
                        self.allocator,
                        self.keys[candidate],
                        self.keys[state.index],
                    );
                    switch (try state.cursor.?.advance(remaining)) {
                        .pending => return .pending,
                        .complete => |matches| {
                            state.cursor.?.deinit();
                            state.cursor = null;
                            if (matches) return .duplicate_key;
                            state.slot = (state.slot + 1) & (table.len - 1);
                            return .pending;
                        },
                    }
                }
                return .pending;
            },
            .keys => |*materializer| switch (try materializer.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.state = .{ .vals = .{
                        .keys = item,
                        .materializer = .init(self.allocator, self.vals),
                    } };
                    return .pending;
                },
            },
            .vals => |*state| switch (try state.materializer.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.state = .{ .hashes = .{
                        .keys = state.keys,
                        .vals = item,
                        .materializer = .init(self.allocator, self.hashes),
                    } };
                    return .pending;
                },
            },
            .hashes => |*state| switch (try state.materializer.advance(budget)) {
                .pending => return .pending,
                .complete => |item| {
                    self.state = .{ .finish = .{
                        .keys = state.keys,
                        .vals = state.vals,
                        .hashes = item,
                    } };
                    continue;
                },
            },
            .finish => |state| {
                var builder = try heap.DictBuilder.init(self.allocator, self.source_keys.len);
                const header = builder.finish(.{
                    .keys = state.keys.list,
                    .vals = state.vals.list,
                    .hashes = state.hashes.list,
                }, self.table);
                self.table = null;
                self.state = .complete;
                return .{ .complete = .{ .dict = header } };
            },
            .complete => unreachable,
        };
    }
};

fn allocateDictIndex(
    allocator: std.mem.Allocator,
    count: usize,
    check_duplicates: bool,
) error{OutOfMemory}!?[]u32 {
    if (!check_duplicates and count < 16) return null;
    var table_len: usize = 32;
    const minimum = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    while (table_len < minimum)
        table_len = std.math.mul(usize, table_len, 2) catch return error.OutOfMemory;
    return try allocator.alloc(u32, table_len);
}

pub const DictFindProgress = poll.Progress(?Value);

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
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    source: []const Value,
    phase: Phase = .profile,
    index: usize = 0,
    item_profile: Profile = .{ .kind = .empty },
    builder: ?heap.AnyListBuilder = null,

    const Phase = enum { profile, fill, complete };

    pub fn init(allocator: std.mem.Allocator, source: []const Value) ValueMaterializer {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *ValueMaterializer) void {
        std.debug.assert(self.builder == null);
        self.* = undefined;
    }
    pub fn retire(self: *ValueMaterializer, releases: *heap.ReleaseDomain) void {
        if (self.builder) |*builder| builder.retirePartial(releases);
    }

    /// Transfers an incomplete destination to scheduler-owned release work.
    pub fn takePartial(self: *ValueMaterializer) ?Value {
        if (self.builder == null) return null;
        const header = self.builder.?.finish();
        self.builder = null;
        return .{ .list = header };
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
        var builder = try heap.AnyListBuilder.init(
            self.allocator,
            kind,
            self.source.len,
            initialCapacity(self.source.len),
        );
        if (kind == .generic_spine) switch (builder) {
            .generic => |*generic| generic.setLen(0),
            else => unreachable,
        };
        self.builder = builder;
        self.phase = .fill;
        self.index = 0;
    }

    fn fillOne(self: *ValueMaterializer, item: Value, index: usize) void {
        self.builder.?.writeValue(index, item);
    }

    fn finish(self: *ValueMaterializer) MaterializeResult {
        const header = self.builder.?.finish();
        self.builder = null;
        self.phase = .complete;
        return .{ .complete = .{ .list = header } };
    }
};

/// Exact generic-spine construction for code roots and other representation-
/// sensitive lists. Unlike ValueMaterializer, this never specializes a
/// homogeneous source.
const GenericValueOps = struct {
    fn begin(
        allocator: std.mem.Allocator,
        source: []const Value,
        _: void,
    ) error{OutOfMemory}!heap.ListBuilder(.generic_spine) {
        var builder = try heap.ListBuilder(.generic_spine).init(
            allocator,
            source.len,
            initialCapacity(source.len),
        );
        builder.setLen(0);
        return builder;
    }
    fn fill(
        builder: *heap.ListBuilder(.generic_spine),
        source: []const Value,
        index: *usize,
        end: usize,
    ) void {
        while (index.* != end) : (index.* += 1) {
            const item = source[index.*];
            heap.retainValue(item);
            builder.items()[index.*] = item;
            builder.setLen(index.* + 1);
        }
    }
    fn finish(builder: *heap.ListBuilder(.generic_spine)) Value {
        return .{ .list = builder.finish() };
    }
};
const GenericValueChunked = ChunkedMaterializer(
    Value,
    heap.ListBuilder(.generic_spine),
    void,
    GenericValueOps,
);
pub const GenericValueMaterializer = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    inner: GenericValueChunked,
    pub fn init(allocator: std.mem.Allocator, source: []const Value) GenericValueMaterializer {
        return .{ .inner = .init(allocator, source, {}) };
    }
    pub fn deinit(self: *GenericValueMaterializer) void {
        self.inner.deinit();
        self.* = undefined;
    }
    pub fn retire(self: *GenericValueMaterializer, releases: *heap.ReleaseDomain) void {
        self.inner.retire(releases);
    }
    pub fn advance(self: *GenericValueMaterializer, budget: usize) error{OutOfMemory}!MaterializeResult {
        return self.inner.advance(budget);
    }
};

pub const ToUtf8Progress = poll.Progress([]u8);
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
                const codepoint = @import("list.zig").atUnchecked(self.string, self.index).char;
                const length = std.unicode.utf8Encode(
                    value.unicodeScalar(codepoint) orelse return error.InvalidCodepoint,
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
                const codepoint = @import("list.zig").atUnchecked(self.string, self.index).char;
                const length = std.unicode.utf8Encode(
                    value.unicodeScalar(codepoint) orelse return error.InvalidCodepoint,
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
