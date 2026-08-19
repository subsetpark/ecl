//! The internal `json` module: RFC 8259 over `std.json`, published as a
//! builtin-backed module.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "json: canonical corpus round-trips byte-identically" {
    try support.expectStacks(&.{
        .{
            .name = "scalars and aggregates",
            .source = "\"1\" json.parse \"3.5\" json.parse \"[1,2,3]\" json.parse " ++
                "\"{\\\"a\\\":1}\" json.parse",
            .expected = "1 3.5 [1 2 3] {\"a\" 1}",
        },
        .{
            // Integral in-range numbers become ints; anything else is a float.
            .name = "the number policy",
            .source = "\"1\" json.parse type \"3.5\" json.parse type " ++
                "\"1e3\" json.parse type \"9223372036854775808\" json.parse type " ++
                "\"-9223372036854775808\" json.parse type",
            .expected = "'int 'float 'float 'float 'int",
        },
        .{
            .name = "nested corpora round-trip",
            .source = "\"{\\\"a\\\":1,\\\"b\\\":[2,3],\\\"c\\\":null}\" dup json.parse json.emit match " ++
                "\"[1,2,[3,{\\\"x\\\":true}]]\" dup json.parse json.emit match " ++
                "\"{\\\"nested\\\":{\\\"deep\\\":[1,{\\\"x\\\":null}]}}\" dup json.parse json.emit match",
            .expected = "1 1 1",
        },
        .{
            .name = "escapes and empty aggregates round-trip",
            .source = "\"\\\"a\\\\nb\\\\\\\"c\\\"\" dup json.parse json.emit match " ++
                "\"[]\" dup json.parse json.emit match " ++
                "\"{}\" dup json.parse json.emit match " ++
                "\"\\\"\\\"\" dup json.parse json.emit match",
            .expected = "1 1 1 1",
        },
        .{
            .name = "emission renders each kind",
            .source = "1 json.emit 3.5 json.emit \"hi\" json.emit [1 2 3] json.emit {'a 1} json.emit",
            .expected = "\"1\" \"3.5\" \"\\\"hi\\\"\" \"[1,2,3]\" \"{\\\"a\\\":1}\"",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "empty input is not a document",
            .source = "\"\" json.parse",
            .kind = "parse",
            .word = "json.parse",
        },
        .{
            .name = "trailing content is rejected",
            .source = "\"1 2\" json.parse",
            .kind = "parse",
            .word = "json.parse",
        },
        .{
            .name = "malformed input is rejected",
            .source = "\"{\\\"a\\\":}\" json.parse",
            .kind = "parse",
            .word = "json.parse",
        },
    });
}

test "json: null maps to the symbol null in both directions" {
    try support.expectStacks(&.{
        .{
            // Data, not language nil: the absence doctrine is untouched.
            .name = "null is an ordinary symbol",
            .source = "\"null\" json.parse \"null\" json.parse type 'null json.emit",
            .expected = "'null 'symbol \"null\"",
        },
        .{
            // true and false follow the same rule, because ECL booleans are
            // the ints 0 and 1 and that mapping is not reversible.
            .name = "the other two literals are symbols too",
            .source = "\"[true,false,null]\" json.parse " ++
                "\"[true,false,null]\" dup json.parse json.emit match",
            .expected = "['true 'false 'null] 1",
        },
        .{
            .name = "a null inside an array stays ordinary data",
            .source = "\"[1,null]\" json.parse dup 1 at type swap len",
            .expected = "'symbol 2",
        },
    });
}

test "json: non-string dict keys refuse to emit as type" {
    try support.expectErrors(&.{
        .{
            .name = "an integer key",
            .source = "{1 2} json.emit",
            .kind = "type",
            .word = "json.emit",
            .message_contains = "string or symbol dictionary keys",
        },
        .{
            .name = "a list key",
            .source = "{} [1] 2 put json.emit",
            .kind = "type",
            .word = "json.emit",
            .message_contains = "string or symbol dictionary keys",
        },
        .{
            .name = "a symbol with no JSON form",
            .source = "'foo json.emit",
            .kind = "type",
            .word = "json.emit",
            .message_contains = "cannot represent the symbol",
        },
        .{
            .name = "a bare character",
            .source = "\"a\" first json.emit",
            .kind = "type",
            .word = "json.emit",
        },
    });
}

test "json: every exported word carries documentation" {
    for ([_][]const u8{ "parse", "emit" }) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'json use 'json.{s} doc len 0 >",
            .{name},
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "1");
    }
}
