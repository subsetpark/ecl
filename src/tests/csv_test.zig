//! The first-party native `csv` module: RFC 4180 over the public SDK
//! callback protocol, published from the embedded manifest through the
//! static-native transport.
const support = @import("kernel_test_support.zig");

test "csv: parse preserves fields, widths, and quoting per RFC 4180" {
    try support.expectStacks(&.{
        .{
            .name = "records and fields",
            .source = "\"a,b,c\" csv.parse",
            .expected = "((\"a\" \"b\" \"c\"))",
        },
        .{
            // Both record endings are accepted; the policy fixes only what
            // emission produces.
            .name = "LF and CRLF both end records",
            .source = "\"a,b\\nc,d\" csv.parse \"a,b\\u{D}\\nc,d\\u{D}\\n\" csv.parse match?",
            .expected = "1",
        },
        .{
            .name = "quoted commas newlines and doubled quotes",
            .source = "\"\\\"a,b\\\",c\" csv.parse " ++
                "\"\\\"a\\nb\\\",c\" csv.parse " ++
                "\"\\\"a\\\"\\\"b\\\",c\" csv.parse",
            .expected = "((\"a,b\" \"c\")) ((\"a\\nb\" \"c\")) ((\"a\\\"b\" \"c\"))",
        },
        .{
            // Empty fields keep their position, and record widths are
            // preserved rather than normalized.
            .name = "empty fields and ragged widths are preserved",
            .source = "\"a,,c\" csv.parse first len " ++
                "\"a,b,c\\nd\" csv.parse (len) each " ++
                "\",\" csv.parse first (len) each",
            .expected = "3 [3 1] [0 0]",
        },
        .{
            .name = "empty input is an empty record list",
            .source = "\"\" csv.parse len",
            .expected = "0",
        },
        .{
            // A trailing terminator closes the last record; it does not open
            // an empty one.
            .name = "trailing terminators do not invent records",
            .source = "\"a\" csv.parse len \"a\\n\" csv.parse len " ++
                "\"a\\n\\n\" csv.parse len \"\\n\" csv.parse len",
            .expected = "1 1 2 1",
        },
        .{
            // No header interpretation, no delimiter sniffing, no scalar
            // inference: every field is the text that was there.
            .name = "text is preserved without inference",
            .source = "\"name,age\\nAda,36\" csv.parse " ++
                "\"01,002\" csv.parse first first " ++
                "\"a;b\" csv.parse first len",
            .expected = "((\"name\" \"age\") (\"Ada\" \"36\")) \"01\" 1",
        },
    });
}

test "csv: emit produces canonical CRLF output quoting exactly as required" {
    try support.expectStacks(&.{
        .{
            .name = "canonical output is CRLF terminated",
            .source = "\"a,b,c\" csv.parse csv.emit",
            .expected = "\"a,b,c\\u{d}\\n\"",
        },
        .{
            // Exactly the fields that need quoting get it.
            .name = "quoting is required-only",
            .source = "\"\\\"a,b\\\",c\" csv.parse csv.emit " ++
                "\"\\\"a\\\"\\\"b\\\",c\" csv.parse csv.emit " ++
                "\"\\\"a\\nb\\\",c\" csv.parse csv.emit",
            .expected = "\"\\\"a,b\\\",c\\u{d}\\n\" " ++
                "\"\\\"a\\\"\\\"b\\\",c\\u{d}\\n\" " ++
                "\"\\\"a\\nb\\\",c\\u{d}\\n\"",
        },
        .{
            .name = "empty rows emit the empty string",
            .source = "\"\" csv.parse csv.emit len",
            .expected = "0",
        },
        .{
            // The round trip is the contract, in both directions.
            .name = "canonical text round-trips byte-identically",
            .source = "\"a,b\\u{D}\\nc,d\\u{D}\\n\" dup csv.parse csv.emit match? " ++
                "\"\\\"a\\\"\\\"b\\\",\\\"c,d\\\"\\u{D}\\n\" dup csv.parse csv.emit match? " ++
                "\"a,,c\\u{D}\\n\" dup csv.parse csv.emit match?",
            .expected = "1 1 1",
        },
        .{
            // Larger than one 65,536-unit scheduler quantum, so the parse and
            // the emit both cross yields and resume mid-record.
            .name = "input beyond one budget quantum resumes correctly",
            .source = "'str ('repeat) import \"ab,cd\\u{D}\\n\" 12000 repeat dup csv.parse csv.emit match?",
            .expected = "1",
        },
        .{
            .name = "quoted fields beyond one quantum resume correctly",
            .source = "'str ('repeat) import \"\\\"a\\\"\\\"b\\\",\\\"c,d\\\"\\u{D}\\n\" 8000 repeat " ++
                "dup csv.parse csv.emit match?",
            .expected = "1",
        },
    });
}

test "csv: malformed quoting is parse and invalid rows are type or shape" {
    try support.expectErrors(&.{
        .{
            .name = "unclosed quoted field",
            .source = "\"\\\"unclosed\" csv.parse",
            .kind = "parse",
            .word = "csv.parse",
            .message_contains = "malformed quoting",
        },
        .{
            .name = "a quote inside a bare field",
            .source = "\"a\\\"b\" csv.parse",
            .kind = "parse",
            .word = "csv.parse",
        },
        .{
            .name = "text after a closing quote",
            .source = "\"\\\"a\\\"b\" csv.parse",
            .kind = "parse",
            .word = "csv.parse",
        },
        .{
            .name = "parse rejects a non-string",
            .source = "5 csv.parse",
            .kind = "type",
            .word = "csv.parse",
        },
        .{
            .name = "emit rejects a non-list",
            .source = "5 csv.emit",
            .kind = "type",
            .word = "csv.emit",
        },
        .{
            .name = "emit rejects a non-list record",
            .source = "5 1 pack csv.emit",
            .kind = "type",
            .word = "csv.emit",
            .message_contains = "every record to be a list",
        },
        .{
            .name = "emit rejects a numeric cell",
            .source = "(5) 1 pack csv.emit",
            .kind = "type",
            .word = "csv.emit",
            .message_contains = "every field to be a string",
        },
        .{
            .name = "emit rejects a zero-field record",
            .source = "[] 1 pack csv.emit",
            .kind = "shape",
            .word = "csv.emit",
            .message_contains = "no fields",
        },
    });
}

test "csv: the module resolves and documents itself like every other" {
    // `which`/`see` reflection over native origins is covered by
    // `native_test`; this suite has no console to render into.
    try support.expectStacks(&.{
        .{
            .name = "documentation reaches native words",
            .source = "'csv.parse doc len 0 > 'csv.emit doc len 0 >",
            .expected = "1 1",
        },
    });
}
