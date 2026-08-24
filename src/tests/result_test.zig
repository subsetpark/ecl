//! The embedded `result` module over the core {'ok values} / {'err error}
//! representation `attempt` already produces.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "result: constructors and observations follow the tagged shape" {
    try support.expectStacks(&.{
        .{
            .name = "construction",
            .source = "[1 2] result.ok {'kind 'io} result.err",
            .expected = "            {\n" ++
                "              'err {'kind 'io}\n" ++
                "{'ok [1 2]} }",
        },
        .{
            // A success payload is a stack, so an empty one is legal and a
            // single value still arrives as a one-element list.
            .name = "success payloads are stacks",
            .source = "[] result.ok [7] result.ok",
            .expected = "{'ok ()} {'ok [7]}",
        },
        .{
            .name = "observations",
            .source = "[1] result.ok result.ok? [1] result.ok result.err? " ++
                "{'kind 'io} result.err result.ok? {'kind 'io} result.err result.err?",
            .expected = "1 0 0 1",
        },
        .{
            // The representation is exactly what `attempt` produces, so the
            // two vocabularies compose without conversion.
            .name = "attempt results are ordinary results",
            .source = "(2 3 +) @attempt result.ok? (missing) @attempt result.err?",
            .expected = "1 1",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "ok requires a list",
            .source = "7 result.ok",
            .kind = "type",
            .message_contains = "result.ok expects a list",
        },
        .{
            .name = "err requires a dict",
            .source = "7 result.err",
            .kind = "type",
            .message_contains = "result.err expects an error dict",
        },
        .{
            .name = "err requires the error schema",
            .source = "{'kind 7} result.err",
            .kind = "type",
            .message_contains = "result.err expects an error dict",
        },
    });
}

test "result: and-then composes success stacks and short-circuits errors" {
    try support.expectStacks(&.{
        .{
            .name = "the success stack is seeded",
            .source = "[2 3] result.ok (+) result.and-then",
            .expected = "{'ok [5]}",
        },
        .{
            .name = "an empty stack seeds nothing",
            .source = "[] result.ok (42) result.and-then",
            .expected = "{'ok [42]}",
        },
        .{
            .name = "an existing error is returned unchanged",
            .source = "{'kind 'io 'msg \"boom\"} result.err (+) result.and-then",
            .expected = "{\n  'err {'kind 'io 'msg \"boom\"}\n}",
        },
        .{
            .name = "a failing continuation becomes the new error",
            .source = "[2 0] result.ok (/) result.and-then result.err?",
            .expected = "1",
        },
        .{
            .name = "chains compose",
            .source = "[2 3] result.ok (+) result.and-then (10 *) result.and-then",
            .expected = "{'ok [50]}",
        },
        .{
            .name = "map-err rewrites only failures",
            .source = "{'kind 'io} result.err (pop {'kind 'domain}) result.map-err " ++
                "[1] result.ok (pop {'kind 'domain}) result.map-err",
            .expected = "{\n" ++
                "  'err {'kind 'domain}\n" ++
                "}                      {'ok [1]}",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "map-err enforces its quotation shape",
            .source = "{'kind 'io} result.err (pop) result.map-err",
            .kind = "contract",
            .message_contains = "( error -- error )",
        },
        .{
            .name = "map-err requires an error dict",
            .source = "{'kind 'io} result.err (pop 7) result.map-err",
            .kind = "type",
            .message_contains = "must produce an error dict",
        },
    });
}

test "result: recover-kinds recovers matched kinds and leaves others unchanged" {
    try support.expectStacks(&.{
        .{
            .name = "broad recovery seeds the error dict",
            .source = "{'kind 'io 'msg \"x\"} result.err ('kind at wrap) result.recover",
            .expected = "{\n  'ok (['io])\n}",
        },
        .{
            .name = "recover leaves a success alone",
            .source = "[1] result.ok ((9)) result.recover",
            .expected = "{'ok [1]}",
        },
        .{
            .name = "a matched kind recovers",
            .source = "{'kind 'io} result.err ['io 'timeout] (pop 99 wrap) result.recover-kinds",
            .expected = "{\n  'ok ([99])\n}",
        },
        .{
            .name = "an unmatched kind is unchanged",
            .source = "{'kind 'type} result.err ['io] (pop 99 wrap) result.recover-kinds",
            .expected = "{\n  'err {'kind 'type}\n}",
        },
        .{
            .name = "a success is unchanged",
            .source = "[5] result.ok ['io] (pop 99 wrap) result.recover-kinds",
            .expected = "{'ok [5]}",
        },
        .{
            .name = "an empty kind list recovers nothing",
            .source = "{'kind 'io} result.err [] (pop 99 wrap) result.recover-kinds",
            .expected = "{\n  'err {'kind 'io}\n}",
        },
        .{
            .name = "a failing recovery quotation becomes the new error",
            .source = "{'kind 'io} result.err (pop missing) result.recover result.err?",
            .expected = "1",
        },
        .{
            .name = "either eliminates both branches",
            .source = "[7] result.ok (first) (pop 0) result.either " ++
                "{'kind 'io} result.err (first) ('kind at) result.either",
            .expected = "7 'io",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "recover-kinds requires symbols",
            .source = "{'kind 'io} result.err [\"io\"] (pop) result.recover-kinds",
            .kind = "type",
            .message_contains = "list of kind symbols",
        },
    });
}

test "result: all returns leftmost error or ordered success stacks" {
    try support.expectStacks(&.{
        .{
            .name = "every success collects stacks in order",
            .source = "[1 2] result.ok [3] result.ok [] result.ok 3 pack result.all",
            .expected = "{'ok ([1 2] [3] ())}",
        },
        .{
            .name = "the leftmost error is returned unchanged",
            .source = "[1] result.ok {'kind 'io} result.err [2] result.ok " ++
                "{'kind 'type} result.err 4 pack result.all",
            .expected = "{\n  'err {'kind 'io}\n}",
        },
        .{
            .name = "an empty list succeeds with no stacks",
            .source = "[] result.all",
            .expected = "{'ok ()}",
        },
        .{
            .name = "partition preserves order on both sides",
            .source = "[1] result.ok {'kind 'io} result.err [2 3] result.ok " ++
                "{'kind 'type} result.err 4 pack result.partition",
            .expected = "([1] [2 3]) ({'kind 'io} {'kind 'type})",
        },
        .{
            .name = "partition of an empty list is two empty lists",
            .source = "[] result.partition",
            .expected = "() ()",
        },
        .{
            .name = "partition never re-raises",
            .source = "{'kind 'io} result.err 1 pack result.partition len swap len",
            .expected = "1 0",
        },
    });
}

test "result: malformed results are rejected before quotations run" {
    // Every case supplies a quotation that would fail loudly if it ran, so a
    // 'type failure naming the shape is proof the check came first.
    try support.expectErrors(&.{
        .{
            .name = "not a dict",
            .source = "7 (missing) result.and-then",
            .kind = "type",
            .message_contains = "must be a dict tagged",
        },
        .{
            .name = "no tag",
            .source = "{'nope [1]} (missing) result.and-then",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "both tags",
            .source = "{'ok [1] 'err {'kind 'io}} (missing) result.and-then",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "ok payload is not a list",
            .source = "{'ok 5} (missing) result.and-then",
            .kind = "type",
            .message_contains = "list of success values",
        },
        .{
            .name = "err payload is not a dict",
            .source = "{'err 5} (missing) result.and-then",
            .kind = "type",
            .message_contains = "must carry an error dict",
        },
        .{
            .name = "observations reject malformed input too",
            .source = "7 result.ok?",
            .kind = "type",
            .message_contains = "must be a dict tagged",
        },
        .{
            .name = "err observation rejects malformed input",
            .source = "7 result.err?",
            .kind = "type",
            .message_contains = "must be a dict tagged",
        },
        .{
            .name = "or-raise rejects malformed input",
            .source = "{'nope 1} result.or-raise",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "or-else rejects malformed input",
            .source = "{'nope 1} 9 result.or-else",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "map-err rejects before mapping",
            .source = "{'nope 1} (missing) result.map-err",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "recover rejects before recovering",
            .source = "{'ok 5} (missing) result.recover",
            .kind = "type",
            .message_contains = "list of success values",
        },
        .{
            .name = "recover-kinds rejects before matching",
            .source = "{'nope 1} ['io] (missing) result.recover-kinds",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "either rejects before eliminating",
            .source = "{'nope 1} (missing) (missing) result.either",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
        .{
            .name = "all rejects a non-list",
            .source = "7 result.all",
            .kind = "type",
            .message_contains = "expected a list of results",
        },
        .{
            .name = "all rejects a malformed member",
            .source = "{'ok 5} 1 pack result.all",
            .kind = "type",
            .message_contains = "list of success values",
        },
        .{
            .name = "partition rejects a malformed member",
            .source = "{'nope 1} 1 pack result.partition",
            .kind = "type",
            .message_contains = "exactly one of 'ok or 'err",
        },
    });
}

test "result: every exported word carries documentation" {
    const names = [_][]const u8{
        "ok",      "err",      "ok?",       "err?",    "or-raise",
        "or-else", "and-then", "map-err",   "recover", "recover-kinds",
        "either",  "all",      "partition",
    };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'result.{s} doc len 0 >",
            .{name},
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "1");
    }
}
