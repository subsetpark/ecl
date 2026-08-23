//! The embedded `error` module for constructing and inspecting ordinary error
//! dictionaries without invoking control effects.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "error: constructors preserve the documented dictionary representation" {
    try support.expectStacks(&.{
        .{
            .name = "kind only",
            .source = "'domain error.new",
            .expected = "{'kind 'domain}",
        },
        .{
            .name = "message and data",
            .source = "'custom error.new \"broken\" error.with-message " ++
                "{'detail 7} error.with-data",
            .expected = "{\n  'kind 'custom\n  'msg \"broken\"\n  'data {'detail 7}\n}",
        },
    });
}

test "error: validation recognizes the same typed fields as raise" {
    try support.expectStack(
        "{'kind 'io 'msg \"x\" 'word 'read 'trace ['outer 'inner] " ++
            "'data {'path \"p\"}} error.valid? " ++
            "{'kind 'io 'msg 7} error.valid? {'msg \"missing kind\"} error.valid? " ++
            "7 error.valid? (missing) @attempt 'err at error.valid? " ++
            "{'kind 'custom 'extra 1} error.valid?",
        "1 0 0 0 1 1",
    );
}

test "error: kind predicates validate their inputs" {
    try support.expectStacks(&.{
        .{
            .name = "kind equality",
            .source = "'io error.new 'io error.kind? 'io error.new 'type error.kind?",
            .expected = "1 0",
        },
        .{
            .name = "kind membership",
            .source = "'timeout error.new ['io 'timeout] error.kind-in? " ++
                "'domain error.new ['io 'timeout] error.kind-in?",
            .expected = "1 0",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "new requires a symbol",
            .source = "7 error.new",
            .kind = "type",
            .message_contains = "kind symbol",
        },
        .{
            .name = "message requires text",
            .source = "'io error.new 7 error.with-message",
            .kind = "type",
            .message_contains = "string message",
        },
        .{
            .name = "data requires a dict",
            .source = "'io error.new 7 error.with-data",
            .kind = "type",
            .message_contains = "data dict",
        },
        .{
            .name = "kind list requires symbols",
            .source = "'io error.new ['io 7] error.kind-in?",
            .kind = "type",
            .message_contains = "list of kind symbols",
        },
    });
}

test "error: every exported word carries documentation" {
    const names = [_][]const u8{ "new", "with-message", "with-data", "valid?", "kind?", "kind-in?" };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'error.{s} body type 'error.{s} doc len 0 >",
            .{ name, name },
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "'list 1");
    }
}
