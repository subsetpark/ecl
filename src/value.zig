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
    module,
};

/// The representation tag is a construction-time fact. Extending this enum is
/// a design event: all dispatch sites switch exhaustively over these members.
pub const HeapKind = enum(u8) {
    generic_spine,
    leaf_u8,
    leaf_i64,
    leaf_f64,
    leaf_char1,
    leaf_char2,
    leaf_char4,
    leaf_symbol,
    dict,
    task,
    module,
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

/// Public values carry kind-specific handles.  The three pointer types have
/// the same representation, but cannot be interchanged without returning to
/// heap.zig, which is the sole issuer and eraser of these capabilities.
pub const ListHandle = opaque {
    pub fn kind(self: *ListHandle) HeapKind {
        return @import("heap.zig").listKind(self);
    }

    pub fn length(self: *ListHandle) u64 {
        return @import("heap.zig").listLength(self);
    }
};

pub const DictHandle = opaque {
    pub fn length(self: *DictHandle) u64 {
        return @import("heap.zig").dictLength(self);
    }
};

pub const TaskHandle = opaque {};

/// An immutable module image. The handle carries identity only: its content,
/// lifetime, and registration semantics belong to modules.zig, and the heap
/// knows nothing about them beyond a release callback.
pub const ModuleHandle = opaque {};

/// Kept beside Header so equality can inspect dicts without importing the
/// operations layer and creating a module cycle.
pub const DictPayload = struct {
    keys: *ListHandle,
    vals: *ListHandle,
    hashes: *ListHandle,
};

pub const Value = union(Tag) {
    int: i64,
    float: f64,
    char: u32,
    symbol: u32,
    word: u32,
    list: *ListHandle,
    dict: *DictHandle,
    task: *TaskHandle,
    module: *ModuleHandle,

    pub fn tag(self: Value) Tag {
        return std.meta.activeTag(self);
    }

    pub fn heapHeader(self: Value) ?*Header {
        return switch (self) {
            .int, .float, .char, .symbol, .word => null,
            .list => |header| @import("heap.zig").headerFromList(header),
            .dict => |header| @import("heap.zig").headerFromDict(header),
            .task => |header| @import("heap.zig").headerFromTask(header),
            .module => |header| @import("heap.zig").headerFromModule(header),
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
            .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .module, .reserved_mask => false,
        };
    }
};

/// Validate and narrow the integer representation shared by every character
/// producer to the Unicode scalar domain accepted by UTF-8.
pub fn unicodeScalar(codepoint: u64) ?u21 {
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return null;
    return @intCast(codepoint);
}

comptime {
    if (@sizeOf(Value) != 16) @compileError("Value must remain exactly 16 bytes");
    if (@typeInfo(HeapKind).@"enum".fields.len != 12)
        @compileError("HeapKind dispatch count changed; update every exhaustive representation switch");
}
