//! ecl's value core: tagged values, heap ownership, interning, containers,
//! structural identity, and canonical rendering.

const std = @import("std");

pub const version = "0.1.0";
pub const value = @import("value.zig");
pub const heap = @import("heap.zig");
pub const intern = @import("intern.zig");
pub const list = @import("list.zig");
pub const equal = @import("equal.zig");
pub const dict = @import("dict.zig");
pub const print = @import("print.zig");

test "value-core smoke test uses the leak-detecting allocator" {
    const bytes = try std.testing.allocator.dupe(u8, version);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(version, bytes);
}

test {
    _ = value;
    _ = heap;
    _ = intern;
    _ = list;
    _ = equal;
    _ = dict;
    _ = print;
    _ = @import("value_test.zig");
}
