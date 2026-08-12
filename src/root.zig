//! ecl's value core and reader: tagged values, ownership, interning,
//! containers, structural identity, canonical rendering, and source forms.

const std = @import("std");

pub const version = "0.1.0";
pub const value = @import("value.zig");
pub const heap = @import("heap.zig");
pub const intern = @import("intern.zig");
pub const list = @import("list.zig");
pub const equal = @import("equal.zig");
pub const dict = @import("dict.zig");
pub const print = @import("print.zig");
pub const lexer = @import("lexer.zig");
pub const binder = @import("binder.zig");
pub const reader = @import("reader.zig");
pub const spans = @import("spans.zig");
pub const env = @import("env.zig");
pub const machine = @import("machine.zig");
pub const prims = @import("prims.zig");
pub const session = @import("session.zig");

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
    _ = lexer;
    _ = binder;
    _ = reader;
    _ = spans;
    _ = env;
    _ = machine;
    _ = prims;
    _ = session;
    _ = @import("value_test.zig");
    _ = @import("reader_test.zig");
    _ = @import("machine_test.zig");
}
