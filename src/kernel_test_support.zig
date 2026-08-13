//! Shared test helpers for M5 kernel families.
const std = @import("std");
const session = @import("session.zig");
const heap = @import("heap.zig");
const printer = @import("print.zig");

pub fn expectStack(allocator: std.mem.Allocator, source: []const u8, expected: []const u8) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    switch (try runtime.runUnit("<kernel-test>", source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer heap.releaseValue(allocator, failure);
            const rendered = try printer.toOwnedString(allocator, failure);
            defer allocator.free(rendered);
            std.log.err("unexpected language error: {s}", .{rendered});
            return error.TestUnexpectedResult;
        },
    }
    const display = try runtime.stackDisplay();
    defer allocator.free(display);
    try std.testing.expectEqualStrings(expected, display);
}

pub fn expectError(
    allocator: std.mem.Allocator,
    source: []const u8,
    fragments: []const []const u8,
) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<kernel-test>", source)) {
        .ok, .incomplete => return error.TestUnexpectedResult,
        .err => |item| item,
    };
    defer heap.releaseValue(allocator, failure);
    const rendered = try printer.toOwnedString(allocator, failure);
    defer allocator.free(rendered);
    for (fragments) |fragment| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, fragment) != null);
    }
}
