//! Small source-defined vocabulary available before the full M6 prelude.

const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const env = @import("env.zig");

const Value = value.Value;

pub fn install(core: *env.Env) error{OutOfMemory}!void {
    const allocator = core.core.allocator;
    const empty = try list.fromValuesGeneric(allocator, &.{});
    defer heap.releaseValue(allocator, empty);
    const cons: Value = .{ .word = try intern.intern("cons") };

    try installWord(core, "wrap", &.{ empty, cons });
    try installWord(core, "pair", &.{ empty, cons, cons });
}

fn installWord(
    core: *env.Env,
    name: []const u8,
    forms: []const Value,
) error{OutOfMemory}!void {
    const body = try list.fromValuesGeneric(core.core.allocator, forms);
    defer heap.releaseValue(core.core.allocator, body);
    try core.installCore(try intern.intern(name), .{ .word = body.list });
}
