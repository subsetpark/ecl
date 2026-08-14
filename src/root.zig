//! ecl's value, reader, frame-machine, environment, and module surfaces,
//! including the public library aggregation and cross-layer test root.
pub const version = "0.1.0";
pub const value = @import("value.zig");
pub const poll = @import("poll.zig");
pub const heap = @import("heap.zig");
pub const intern = @import("intern.zig");
pub const list = @import("list.zig");
pub const equal = @import("equal.zig");
pub const dict = @import("dict.zig");
pub const print = @import("print.zig");
pub const lexer = @import("lexer.zig");
pub const binder = @import("binder.zig");
pub const reader = @import("reader.zig");
pub const formatter = @import("formatter.zig");
pub const spans = @import("spans.zig");
pub const env = @import("env.zig");
pub const modules = @import("modules.zig");
pub const machine = @import("machine.zig");
pub const prims = @import("prims.zig");
pub const combinators = @import("combinators.zig");
pub const idioms = @import("idioms.zig");
pub const prelude = @import("prelude.zig");
pub const kernels = @import("kernels.zig");
pub const session = @import("session.zig");
test "value-core smoke test uses the leak-detecting allocator" {
    const std = @import("std");
    const bytes = try std.testing.allocator.dupe(u8, version);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(version, bytes);
}
test {
    _ = value;
    _ = poll;
    _ = heap;
    _ = intern;
    _ = list;
    _ = equal;
    _ = dict;
    _ = print;
    _ = lexer;
    _ = binder;
    _ = reader;
    _ = formatter;
    _ = spans;
    _ = env;
    _ = modules;
    _ = machine;
    _ = prims;
    _ = combinators;
    _ = idioms;
    _ = prelude;
    _ = kernels;
    _ = session;
    _ = @import("value_test.zig");
    _ = @import("reader_test.zig");
    _ = @import("machine_test.zig");
    _ = @import("module_test.zig");
    _ = @import("kernel_numeric_test.zig");
    _ = @import("kernel_sequence_test.zig");
    _ = @import("kernel_order_test.zig");
    _ = @import("kernel_dict_text_test.zig");
    _ = @import("combinator_test.zig");
    _ = @import("prelude_test.zig");
    _ = @import("definition_test.zig");
    _ = @import("formatter_test.zig");
}
