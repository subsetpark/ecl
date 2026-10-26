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
    port,
    address,
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
    port,
    address,
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

/// Runtime capability roles share the language's opaque `'port` type. Only
/// resources and exchanges own scope membership; the other roles share use.
pub const PortVariant = enum {
    factory,
    operation_selector,
    endpoint_selector,
    resource,
    exchange,
    endpoint,
};

/// An identity-bearing port capability. Its role, backend payload, and
/// lifecycle remain inside the runtime; language code receives no descriptor
/// or PID.
pub const PortHandle = opaque {};

/// A task mailbox's name. It reaches the mailbox and nothing else, which is
/// what lets an address be sent where a task handle cannot.
pub const AddressHandle = opaque {};

/// Kept beside Header so equality can inspect dicts without importing the
/// operations layer and creating a module cycle.
pub const DictPayload = struct {
    keys: *ListHandle,
    vals: *ListHandle,
    hashes: *ListHandle,
};

/// A word occurrence: its interned name, and its name's slot in the root its
/// text was written in. The slot rides here rather than on the enclosing
/// quotation because a word is the unit that resolves — which is what makes
/// splicing work, since `cat` copies `Value`s and each token keeps the slot it
/// was linked to. It costs nothing: `Value` is pinned at 16 bytes and the
/// `word` variant used four of its eight payload bytes.
pub const WordRef = struct {
    name: u32,
    /// `env.SlotId` as a bare integer, kept untyped here so `value.zig` stays
    /// free of any dependency on the environment. Zero is a word linked to
    /// nothing, which only the locals backend's reserved words are.
    slot: u32 = 0,
};

/// How a producer of word occurrences links each one to its name's slot in
/// the root it writes into. Carried by value through the reader so that
/// neither the reader nor `value.zig` depends on the environment. The
/// context is two opaque words the link function alone interprets.
pub const WordLinker = struct {
    context: [2]usize = .{ 0, 0 },
    link_fn: ?*const fn (context: [2]usize, name: u32) error{OutOfMemory}!u32 = null,

    /// Links nothing: every word it produces carries slot zero.
    pub const unlinked: WordLinker = .{};

    pub fn link(self: WordLinker, name: u32) error{OutOfMemory}!u32 {
        const function = self.link_fn orelse return 0;
        return function(self.context, name);
    }
};

pub const Value = union(Tag) {
    int: i64,
    float: f64,
    char: u32,
    symbol: u32,
    word: WordRef,
    list: *ListHandle,
    dict: *DictHandle,
    task: *TaskHandle,
    port: *PortHandle,
    address: *AddressHandle,

    pub fn tag(self: Value) Tag {
        return std.meta.activeTag(self);
    }

    pub fn heapHeader(self: Value) ?*Header {
        return switch (self) {
            .int, .float, .char, .symbol, .word => null,
            .list => |header| @import("heap.zig").headerFromList(header),
            .dict => |header| @import("heap.zig").headerFromDict(header),
            .task => |header| @import("heap.zig").headerFromTask(header),
            .port => |header| @import("heap.zig").headerFromPort(header),
            .address => |header| @import("heap.zig").headerFromAddress(header),
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
            .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_symbol, .dict, .task, .port, .address, .reserved_mask => false,
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
    if (@typeInfo(HeapKind).@"enum".field_names.len != 13)
        @compileError("HeapKind dispatch count changed; update every exhaustive representation switch");
}
