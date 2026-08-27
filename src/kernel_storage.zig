//! Poll-aware text conversion for kernel-owned traversals.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const poll = @import("poll.zig");

const Value = value.Value;

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

/// An exact byte view over an ordinary ECL integer list. Packed byte leaves
/// stay borrowed through a retained typed reader; equivalent list
/// representations use an owned validated copy. Consumers never branch on the
/// representation that produced the bytes.
pub const ByteVector = union(enum) {
    borrowed: heap.LeafReader(.leaf_u8),
    allocated: []u8,

    pub const owned_disposal: heap.OwnedDisposal = .retire;

    pub fn bytes(self: *const ByteVector) []const u8 {
        return switch (self.*) {
            .borrowed => |*reader| reader.slice(),
            .allocated => |bytes_value| bytes_value,
        };
    }

    pub fn retire(
        self: *ByteVector,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .borrowed => |*reader| reader.release(releases),
            .allocated => |bytes_value| allocator.free(bytes_value),
        }
        // SAFETY: retirement has released the union's active owned resource;
        // poisoning prevents an accidental second disposal through this value.
        self.* = undefined;
    }
};

pub const ByteVectorEncodeResult = poll.Progress(ByteVector);

/// Resumably validates an ordinary integer list as bytes. A packed list
/// completes without allocation; every other representation is checked and
/// copied one item per charged step.
pub const ByteVectorEncoder = struct {
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    allocator: std.mem.Allocator,
    source: Value,
    index: usize = 0,
    output: ?[]u8 = null,
    invalid_index: ?usize = null,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: Value) ByteVectorEncoder {
        std.debug.assert(source == .list);
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *ByteVectorEncoder) void {
        if (self.output) |output| self.allocator.free(output);
        self.* = undefined;
    }

    pub fn advance(
        self: *ByteVectorEncoder,
        budget: usize,
    ) (error{OutOfMemory} || error{InvalidByte})!ByteVectorEncodeResult {
        std.debug.assert(budget != 0 and !self.complete);
        if (self.source.list.kind() == .leaf_u8) {
            self.complete = true;
            return .{ .complete = .{
                .borrowed = heap.LeafReader(.leaf_u8).acquire(self.source.list),
            } };
        }
        const count: usize = @intCast(self.source.list.length());
        if (self.output == null) self.output = try self.allocator.alloc(u8, count);
        const end = @min(self.index + budget, count);
        while (self.index != end) : (self.index += 1) {
            const item = list.atUnchecked(self.source, self.index);
            if (item != .int or item.int < 0 or item.int > std.math.maxInt(u8)) {
                self.invalid_index = self.index;
                return error.InvalidByte;
            }
            self.output.?[self.index] = @intCast(item.int);
        }
        if (self.index != count) return .pending;
        const output = self.output.?;
        self.output = null;
        self.complete = true;
        return .{ .complete = .{ .allocated = output } };
    }
};

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
