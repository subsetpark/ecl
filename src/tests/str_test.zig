//! The embedded `str` module: text operations and prelude-derived string words.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "str: case operations are ASCII-only per the character ruling" {
    try support.expectStacks(&.{
        .{
            .name = "ASCII letters fold both ways",
            .source = "\"hello\" str.upper \"HELLO\" str.lower",
            .expected = "\"HELLO\" \"hello\"",
        },
        .{
            // Non-ASCII scalars pass through untouched rather than being
            // folded by a locale nobody chose.
            .name = "non-ASCII scalars are untouched",
            .source = "\"HeLLo, Wörld! 123\" str.upper \"HeLLo, Wörld! 123\" str.lower",
            .expected = "\"HELLO, WöRLD! 123\" \"hello, wörld! 123\"",
        },
        .{
            // Codepoint count is preserved, which is the whole point of
            // refusing case mappings that change length.
            .name = "length is preserved",
            .source = "\"HeLLo, Wörld!\" dup len swap str.upper len =",
            .expected = "1",
        },
        .{
            .name = "case folding is idempotent",
            .source = "\"MiXeD\" str.upper dup str.upper match? " ++
                "\"MiXeD\" str.lower dup str.lower match?",
            .expected = "1 1",
        },
        .{
            .name = "non-letters near the letter ranges are untouched",
            .source = "\"@[`{\" str.upper \"@[`{\" str.lower",
            .expected = "\"@[`{\" \"@[`{\"",
        },
    });
}

test "str: trimming removes exactly the ASCII whitespace scalars" {
    try support.expectStacks(&.{
        .{
            .name = "both ends",
            .source = "\"  hi  \" str.trim \"  hi  \" str.trim-left \"  hi  \" str.trim-right",
            .expected = "\"hi\" \"hi  \" \"  hi\"",
        },
        .{
            .name = "every ASCII whitespace scalar counts",
            .source = "\" \\t\\n\\u{B}\\u{C}\\u{D}hi\\t \" str.trim",
            .expected = "\"hi\"",
        },
        .{
            .name = "an all-whitespace string trims to empty",
            .source = "\"   \" str.trim len \"\" str.trim len",
            .expected = "0 0",
        },
        .{
            .name = "interior whitespace is preserved",
            .source = "\"  a b  \" str.trim",
            .expected = "\"a b\"",
        },
        .{
            .name = "trimming is idempotent",
            .source = "\"  hi  \" str.trim dup str.trim match?",
            .expected = "1",
        },
    });
}

test "str: prefix suffix and search words agree on their edge cases" {
    try support.expectStacks(&.{
        .{
            .name = "starts and ends",
            .source = "\"hello\" \"he\" str.starts? \"hello\" \"lo\" str.ends? " ++
                "\"hello\" \"lo\" str.starts? \"hello\" \"he\" str.ends?",
            .expected = "1 1 0 0",
        },
        .{
            // A needle longer than the haystack must answer 0, not cycle the
            // haystack to reach the needle's length.
            .name = "an over-long needle is not a match",
            .source = "\"hello\" \"hello!\" str.starts? \"hello\" \"!hello\" str.ends? " ++
                "\"\" \"x\" str.starts? \"\" \"x\" str.ends?",
            .expected = "0 0 0 0",
        },
        .{
            .name = "the empty needle and the whole string both match",
            .source = "\"hello\" \"\" str.starts? \"hello\" \"\" str.ends? " ++
                "\"hello\" \"hello\" str.starts? \"\" \"\" str.starts?",
            .expected = "1 1 1 1",
        },
        .{
            .name = "contains and index-of",
            .source = "\"hello\" \"ell\" str.contains? \"hello\" \"zz\" str.contains? " ++
                "\"hello\" \"l\" str.index-of \"hello\" \"hello\" str.index-of",
            .expected = "1 0 2 0",
        },
        .{
            .name = "the empty needle occurs at index zero",
            .source = "\"a\" \"\" str.contains? \"\" \"\" str.contains? " ++
                "\"a\" \"\" str.index-of \"\" \"\" str.index-of",
            .expected = "1 1 0 0",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "index-of is domain when absent",
            .source = "\"hello\" \"zz\" str.index-of",
            .kind = "domain",
            .message_contains = "no occurrence",
        },
    });
}

test "str: replace repeat and padding build strings by explicit width" {
    try support.expectStacks(&.{
        .{
            .name = "replace every occurrence",
            .source = "\"a-b-c\" \"-\" \"+\" str.replace \"a-b\" \"-\" \"\" str.replace " ++
                "\"abc\" \"z\" \"!\" str.replace \"ab\" \"\" \"-\" str.replace",
            .expected = "\"a+b+c\" \"ab\" \"abc\" \"a-b\"",
        },
        .{
            .name = "repeat concatenates copies",
            .source = "\"ab\" 3 str.repeat \"ab\" 1 str.repeat \"ab\" 0 str.repeat len " ++
                "\"\" 3 str.repeat len",
            .expected = "\"ababab\" \"ab\" 0 0",
        },
        .{
            .name = "padding reaches a width and never truncates",
            .source = "\"7\" 3 str.pad-left \"7\" 3 str.pad-right " ++
                "\"abcd\" 3 str.pad-left \"abcd\" 3 str.pad-right \"\" 2 str.pad-left",
            .expected = "\"  7\" \"7  \" \"abcd\" \"abcd\" \"  \"",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "repeat rejects a negative count",
            .source = "\"ab\" -1 str.repeat",
            .kind = "domain",
            .message_contains = "nonnegative count",
        },
    });
}

test "str: exported words validate complete arguments before running kernels" {
    try support.expectErrors(&.{
        .{
            .name = "upper names its string contract",
            .source = "5 str.upper",
            .kind = "type",
            .message = "str.upper expects a string",
        },
        .{
            .name = "lower rejects a mixed character vector",
            .source = "[\\a 1] str.lower",
            .kind = "type",
            .message = "str.lower expects a string",
        },
        .{
            .name = "trim-left names its string contract",
            .source = "5 str.trim-left",
            .kind = "type",
            .message = "str.trim-left expects a string",
        },
        .{
            .name = "trim-right names its string contract",
            .source = "5 str.trim-right",
            .kind = "type",
            .message = "str.trim-right expects a string",
        },
        .{
            .name = "trim validates at its own public boundary",
            .source = "5 str.trim",
            .kind = "type",
            .message = "str.trim expects a string",
        },
        .{
            .name = "starts validates its prefix",
            .source = "\"abc\" 5 str.starts?",
            .kind = "type",
            .message = "str.starts? expects a string and a string prefix",
        },
        .{
            .name = "ends validates its string",
            .source = "5 \"c\" str.ends?",
            .kind = "type",
            .message = "str.ends? expects a string and a string suffix",
        },
        .{
            .name = "contains validates its needle",
            .source = "\"abc\" 5 str.contains?",
            .kind = "type",
            .message = "str.contains? expects a string and a string needle",
        },
        .{
            .name = "index-of validates its string",
            .source = "5 \"a\" str.index-of",
            .kind = "type",
            .message = "str.index-of expects a string and a string needle",
        },
        .{
            .name = "replace validates its replacement",
            .source = "\"a\" \"a\" 5 str.replace",
            .kind = "type",
            .message = "str.replace expects string, needle, and replacement strings",
        },
        .{
            .name = "repeat validates its string",
            .source = "5 2 str.repeat",
            .kind = "type",
            .message = "str.repeat expects a string and an integer count",
        },
        .{
            .name = "repeat validates its count",
            .source = "\"a\" 2.5 str.repeat",
            .kind = "type",
            .message = "str.repeat expects a string and an integer count",
        },
        .{
            .name = "pad-left validates its width",
            .source = "\"a\" 2.5 str.pad-left",
            .kind = "type",
            .message = "str.pad-left expects a string and an integer width",
        },
        .{
            .name = "pad-right validates its string",
            .source = "5 2 str.pad-right",
            .kind = "type",
            .message = "str.pad-right expects a string and an integer width",
        },
    });
}

test "str: every exported word has nonempty documentation" {
    const names = [_][]const u8{
        "upper",   "lower",    "trim",      "trim-left", "trim-right",
        "starts?", "ends?",    "contains?", "index-of",  "replace",
        "repeat",  "pad-left", "pad-right",
    };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'str.{s} body type 'str.{s} doc len 0 >",
            .{ name, name },
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "'list 1");
    }
}
