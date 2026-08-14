//! Frozen value and heap-header layouts.

const std = @import("std");

pub const Tag = enum(u8) {
    int,
    float,
    char,
    symbol,
    word,
    list,
    dict,
    task,
};

/// The representation tag is a construction-time fact. Extending this enum is
/// a design event: all dispatch sites switch exhaustively over these members.
pub const HeapKind = enum(u8) {
    generic_spine,
    leaf_i64,
    leaf_f64,
    leaf_char1,
    leaf_char2,
    leaf_char4,
    leaf_symbol,
    dict,
    task,
    reserved_mask,
};

/// The heap representation is deliberately opaque outside heap.zig. Values
/// expose only identity plus read-only metadata; construction and mutation
/// require heap-issued capabilities.
pub const Header = opaque {
    pub fn kind(self: *const Header) HeapKind {
        return @import("heap.zig").kind(self);
    }

    pub fn length(self: *const Header) u64 {
        return @import("heap.zig").length(self);
    }
};

/// Kept beside Header so equality can inspect dicts without importing the
/// operations layer and creating a module cycle.
pub const DictPayload = struct {
    keys: *Header,
    vals: *Header,
    hashes: ?*Header,
};

pub const Value = union(Tag) {
    int: i64,
    float: f64,
    char: u32,
    symbol: u32,
    word: u32,
    list: *Header,
    dict: *Header,
    task: *Header,

    pub fn tag(self: Value) Tag {
        return std.meta.activeTag(self);
    }

    pub fn heapHeader(self: Value) ?*Header {
        return switch (self) {
            .int, .float, .char, .symbol, .word => null,
            .list => |header| header,
            .dict => |header| header,
            .task => |header| header,
        };
    }

    pub fn isNumber(self: Value) bool {
        return self == .int or self == .float;
    }

    /// A string is a list whose representation is a width-tagged char leaf.
    pub fn isString(self: Value) bool {
        if (self != .list) return false;
        return switch (self.list.kind()) {
            .leaf_char1, .leaf_char2, .leaf_char4 => true,
            .generic_spine, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .reserved_mask => false,
        };
    }
};

comptime {
    if (@sizeOf(Value) != 16) @compileError("Value must remain exactly 16 bytes");
}

test "value and header layouts are frozen" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 10), @typeInfo(HeapKind).@"enum".fields.len);
}

test "atom constructors round-trip their payloads" {
    const values = [_]Value{
        .{ .int = -9 },
        .{ .float = 0.125 },
        .{ .char = 0x1f642 },
        .{ .symbol = 42 },
        .{ .word = 42 },
    };
    try std.testing.expectEqual(@as(i64, -9), values[0].int);
    try std.testing.expectEqual(@as(f64, 0.125), values[1].float);
    try std.testing.expectEqual(@as(u32, 0x1f642), values[2].char);
    try std.testing.expectEqual(@as(u32, 42), values[3].symbol);
    try std.testing.expectEqual(@as(u32, 42), values[4].word);
}
