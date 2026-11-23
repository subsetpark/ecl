//! Executable proofs for Unicode text kernels.
const helper = @import("kernel_test_support.zig");

test "text: split handles codepoints substrings and empty separators" {
    try helper.expectStack(
        "\"a—b—\" \"—\" str.split \"ab\" \"\" str.split " ++
            "\"\" \"\" str.split \"a🙂λ\" \"\" str.split " ++
            "\"abc\" \"🙂\" str.split \"a🙂b\" \"-\" str.split \"🙂a🙂\" \"🙂\" str.split",
        "(\"a\" \"b\" \"\") (\"a\" \"b\") () (\"a\" \"🙂\" \"λ\") " ++
            "(\"abc\") (\"a🙂b\") (\"\" \"a\" \"\")",
    );
}

test "text: narrow split counts separators across budget steps and keeps parts whole" {
    // One-byte-wide text and separator take the fused kernel. A separator
    // that straddles a step boundary is counted once, parts longer than a
    // step are copied whole, and the results match the general kernel's.
    try helper.expectStack(
        "\"x\" 65535 take \"--\" cat \"y\" cat \"--\" str.split (len) each " ++
            "\"ab--\" 80000 take \"--\" str.split dup len swap first " ++
            "\"a,b,,c\" \",\" str.split \"xyx\" \"x\" str.split \"aaa\" \"aa\" str.split \"ab\\n\" \"\\n\" str.split \"\" \",\" str.split",
        "[65535 1] 20001 \"ab\" (\"a\" \"b\" \"\" \"c\") (\"\" \"y\" \"\") (\"\" \"a\") (\"ab\" \"\") (\"\")",
    );
    // The same inputs widened past one byte go through the general kernel,
    // which must agree on the part count and on every part after the first.
    try helper.expectStack(
        "\"λ\" \"ab--\" 80000 take cat \"--\" str.split dup len swap dup 1 at swap 20000 at " ++
            "\"ab--\" 80000 take \"--\" str.split dup len swap dup 1 at swap 20000 at " ++
            "\"λxyx\" \"x\" str.split dup 1 at swap 2 at \"xyx\" \"x\" str.split dup 1 at swap 2 at",
        "20001 \"ab\" \"\" 20001 \"ab\" \"\" \"y\" \"\" \"y\" \"\"",
    );
}

test "text: join requires strings and chooses narrow char width" {
    try helper.expectStack(
        "[\"a\" \"b\"] \"—\" str.join [\"a\" \"λ\" \"🙂\"] \"\" str.join " ++
            "[\"a\"] \"🙂\" str.join [] \"🙂\" str.join",
        "\"a—b\" \"aλ🙂\" \"a\" \"\"",
    );
    try helper.expectError(.{
        .name = "join reports the non-string member",
        .source = "[\"a\" 2] \"-\" str.join",
        .kind = "type",
        .word = "str.core.join",
        .data = &.{.{ .name = "index", .expected = .{ .int = 1 } }},
    });
}

test "text: format splices strings and canonically renders other values" {
    try helper.expectStack(
        "[\"Ada\" 2] \"name={} n={} {{ok}}\" str.format " ++
            "\"foo\" str wrap \"source={}\" str.format " ++
            "[\"\"] \"a{}b\" str.format",
        "\"name=Ada n=2 {ok}\" \"source=\\\"foo\\\"\" \"ab\"",
    );
    try helper.expectErrors(&.{
        .{
            .name = "format requires one value per placeholder",
            .source = "[1] \"{} {}\" str.format",
            .kind = "contract",
            .word = "str.core.format",
        },
        .{
            .name = "format rejects an unmatched brace",
            .source = "[] \"{\" str.format",
            .kind = "domain",
            .word = "str.core.format",
        },
    });
}
