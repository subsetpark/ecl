//! The embedded `table` module over validated ordinary column dicts.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "table: constructors validate the column convention" {
    try support.expectStacks(&.{
        .{
            // A table is an ordinary dict, and core reflection says so.
            .name = "representation honesty",
            .source = "{\"a\" [1 2] \"b\" [3 4]} dup type swap dup table.valid? swap keys",
            .expected = "'dict 1 (\"a\" \"b\")",
        },
        .{
            .name = "valid? recognizes exactly the convention",
            .source = "{\"a\" [1 2] \"b\" [3 4]} table.valid? " ++
                "{\"a\" [1 2] \"b\" [3]} table.valid? " ++
                "{} table.valid? 5 table.valid? " ++
                "{\"a\" 5} table.valid? {\"\" [1]} table.valid?",
            .expected = "1 0 0 0 0 0",
        },
        .{
            .name = "from-columns and from-rows agree",
            .source = "{\"a\" [1 2] \"b\" [3 4]} table.from-columns " ++
                "[\"a\" \"b\"] [[1 3] [2 4]] table.from-rows match?",
            .expected = "1",
        },
        .{
            // An empty row list is a known zero-row schema, not an error.
            .name = "zero-row schemas are constructible",
            .source = "[\"a\" \"b\"] [] table.from-rows dup table.valid? swap table.height",
            .expected = "1 0",
        },
        .{
            .name = "from-header-rows reads its names off the first row",
            .source = "[[\"a\" \"b\"] [1 2] [3 4]] table.from-header-rows " ++
                "[[\"a\" \"b\"]] table.from-header-rows table.height",
            .expected = "{\"a\" [1 3] \"b\" [2 4]} 0",
        },
        .{
            // First-record insertion order fixes the schema; later records may
            // list their keys in any order.
            .name = "from-records tolerates key order but not key sets",
            .source = "{\"a\" 1 \"b\" 2} {\"b\" 4 \"a\" 3} 2 pack table.from-records",
            .expected = "{\"a\" [1 3] \"b\" [2 4]}",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "a zero-column candidate is shape",
            .source = "{} table.from-columns",
            .kind = "shape",
            .message_contains = "at least one column",
        },
        .{
            .name = "a non-dict candidate is type",
            .source = "5 table.from-columns",
            .kind = "type",
            .message_contains = "must be a dict",
        },
        .{
            .name = "unequal column lengths are shape",
            .source = "{\"a\" [1 2] \"b\" [3]} table.from-columns",
            .kind = "shape",
            .message_contains = "one length",
        },
        .{
            .name = "duplicate names are domain",
            .source = "[\"a\" \"a\"] [] table.from-rows",
            .kind = "domain",
            .message_contains = "duplicate",
        },
        .{
            .name = "an empty name is domain",
            .source = "[\"\"] [] table.from-rows",
            .kind = "domain",
            .message_contains = "must not be empty",
        },
        .{
            .name = "a wrong-width row is shape",
            .source = "[\"a\" \"b\"] [[1]] table.from-rows",
            .kind = "shape",
            .message_contains = "one cell per column",
        },
        .{
            .name = "an empty record list carries no schema",
            .source = "[] table.from-records",
            .kind = "shape",
            .message_contains = "cannot infer a schema",
        },
        .{
            .name = "records disagreeing on keys are domain",
            .source = "{\"a\" 1} {\"a\" 2 \"b\" 3} 2 pack table.from-records",
            .kind = "domain",
            .message_contains = "exactly the first record's keys",
        },
    });
}

test "table: conversions round-trip populated and zero-row schemas" {
    try support.expectStacks(&.{
        .{
            .name = "names and rows round-trip",
            .source = "{\"a\" [1 2] \"b\" [3 4]} dup dup table.names swap table.rows " ++
                "table.from-rows match?",
            .expected = "1",
        },
        .{
            .name = "rows and records read in schema order",
            .source = "{\"a\" [1 2] \"b\" [3 4]} table.rows " ++
                "{\"a\" [1 2] \"b\" [3 4]} table.records",
            .expected = "([1 3]\n [2 4]) ({\"a\" 1 \"b\" 3} {\"a\" 2 \"b\" 4})",
        },
        .{
            // header-rows is the schema-preserving CSV shape, zero rows
            // included; plain rows cannot carry a schema when empty.
            .name = "header-rows preserves a zero-row schema",
            .source = "[\"a\" \"b\"] [] table.from-rows table.header-rows " ++
                "[\"a\" \"b\"] [] table.from-rows table.rows len",
            .expected = "((\"a\" \"b\")) 0",
        },
        .{
            .name = "header-rows round-trips through from-header-rows",
            .source = "{\"a\" [1 2] \"b\" [3 4]} dup table.header-rows " ++
                "table.from-header-rows match? " ++
                "[\"a\" \"b\"] [] table.from-rows dup table.header-rows " ++
                "table.from-header-rows match?",
            .expected = "1 1",
        },
        .{
            .name = "records round-trip when populated",
            .source = "{\"a\" [1 2] \"b\" [3 4]} dup table.records table.from-records match?",
            .expected = "1",
        },
        .{
            .name = "empty records are explicitly schema-less",
            .source = "[\"a\"] [] table.from-rows table.records len",
            .expected = "0",
        },
    });
}

test "table: transformations preserve schema and order per policy" {
    try support.expectStacks(&.{
        .{
            .name = "names column and height",
            .source = "{\"a\" [1 2] \"b\" [3 4]} table.names " ++
                "{\"a\" [1 2] \"b\" [3 4]} \"b\" table.column " ++
                "{\"a\" [1 2]} table.height",
            .expected = "(\"a\" \"b\") [3 4] 2",
        },
        .{
            // Casting is the only scalar coercion, and it is requested by name.
            .name = "cast coerces exactly the named columns",
            .source = "{\"a\" [\"1\" \"2\"] \"b\" [\"5\" \"6\"]} {\"a\" (parse-int)} table.cast",
            .expected = "{\"a\" [1 2] \"b\" (\"5\" \"6\")}",
        },
        .{
            .name = "select keeps the argument order",
            .source = "{\"a\" [1 2] \"b\" [3 4] \"c\" [5 6]} [\"c\" \"a\"] table.select",
            .expected = "{\"c\" [5 6] \"a\" [1 2]}",
        },
        .{
            .name = "rename preserves column order",
            .source = "{\"a\" [1 2] \"b\" [3 4]} {\"a\" \"x\"} table.rename",
            .expected = "{\"x\" [1 2] \"b\" [3 4]}",
        },
        .{
            .name = "with-column replaces in place and appends at the end",
            .source = "{\"a\" [1 2]} \"a\" [7 8] table.with-column " ++
                "{\"a\" [1 2]} \"c\" [7 8] table.with-column",
            .expected = "{\"a\" [7 8]} {\"a\" [1 2] \"c\" [7 8]}",
        },
        .{
            .name = "where keeps exactly the masked rows",
            .source = "{\"a\" [1 2 3] \"b\" [4 5 6]} [1 0 1] table.where " ++
                "{\"a\" [1 2 3]} [0 0 0] table.where table.height",
            .expected = "{\"a\" [1 3] \"b\" [4 6]} 0",
        },
    });
}

test "table: invalid candidates fail with the frozen error kinds" {
    try support.expectStacks(&.{
        .{
            // A core dict operation may produce an invalid candidate; nothing
            // repairs or reclassifies it.
            .name = "core put can forge a candidate",
            .source = "{\"a\" [1 2]} \"b\" [9] put dup table.valid? swap type",
            .expected = "0 'dict",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "the next boundary rejects a forged candidate",
            .source = "{\"a\" [1 2]} \"b\" [9] put wrap (table.rows) with @attempt result.or-raise",
            .kind = "shape",
            .message_contains = "one length",
        },
        .{
            .name = "column requires an existing name",
            .source = "{\"a\" [1 2]} \"z\" table.column",
            .kind = "domain",
            .message_contains = "existing column name",
        },
        .{
            .name = "cast requires existing names",
            .source = "{\"a\" [1 2]} {\"z\" (str)} table.cast",
            .kind = "domain",
            .message_contains = "existing column names",
        },
        .{
            .name = "cast requires quotations",
            .source = "{\"a\" [1 2]} {\"a\" 5} table.cast",
            .kind = "type",
            .message_contains = "quotation for every named column",
        },
        .{
            .name = "select rejects duplicates",
            .source = "{\"a\" [1 2]} [\"a\" \"a\"] table.select",
            .kind = "domain",
            .message_contains = "duplicate",
        },
        .{
            .name = "select rejects an empty name list",
            .source = "{\"a\" [1 2]} [] table.select",
            .kind = "shape",
            .message_contains = "at least one column",
        },
        .{
            .name = "rename rejects collisions",
            .source = "{\"a\" [1 2] \"b\" [3 4]} {\"a\" \"b\"} table.rename",
            .kind = "domain",
            .message_contains = "collide",
        },
        .{
            .name = "rename rejects a missing source",
            .source = "{\"a\" [1 2]} {\"z\" \"x\"} table.rename",
            .kind = "domain",
            .message_contains = "existing column names",
        },
        .{
            .name = "with-column requires the exact row count",
            .source = "{\"a\" [1 2]} \"c\" [7] table.with-column",
            .kind = "shape",
            .message_contains = "row count",
        },
        .{
            .name = "where requires the exact mask length",
            .source = "{\"a\" [1 2 3]} [1 0] table.where",
            .kind = "shape",
            .message_contains = "row count",
        },
        .{
            .name = "where rejects a non-boolean mask",
            .source = "{\"a\" [1 2 3]} [1 0 2] table.where",
            .kind = "type",
            .message_contains = "only 0 and 1",
        },
    });
}

test "table: group-by and aggregate follow the frozen policy" {
    try support.expectStacks(&.{
        .{
            // Keys appear in first-occurrence order; indices stay ascending.
            .name = "grouping is insertion-ordered and stable",
            .source = "{\"r\" [\"e\" \"w\" \"e\" \"n\"] \"v\" [1 2 3 4]} [\"r\"] table.group-by",
            .expected = "{\"e\" [0 2] \"w\" [1] \"n\" [3]}",
        },
        .{
            .name = "no names means one global group keyed by the empty list",
            .source = "{\"r\" [\"e\" \"w\"] \"v\" [1 2]} [] table.group-by",
            .expected = "{() [0 1]}",
        },
        .{
            .name = "several names make composite structural keys",
            .source = "{\"r\" [\"e\" \"w\" \"e\"] \"s\" [\"a\" \"a\" \"b\"] \"v\" [1 2 3]} " ++
                "[\"r\" \"s\"] table.group-by",
            .expected = "{(\"e\" \"a\") [0] (\"w\" \"a\") [1] (\"e\" \"b\") [2]}",
        },
        .{
            .name = "aggregate returns key columns then aggregate columns",
            .source = "{\"r\" [\"e\" \"w\" \"e\"] \"v\" [10 20 30]} [\"r\"] " ++
                "[[\"total\" \"v\" (sum)] [\"n\" \"v\" (len)]] table.aggregate",
            .expected = "{\"r\" (\"e\" \"w\") \"total\" [40 20] \"n\" [2 1]}",
        },
        .{
            .name = "aggregating without keys folds one global group",
            .source = "{\"r\" [\"e\" \"w\" \"e\"] \"v\" [10 20 30]} [] " ++
                "[[\"total\" \"v\" (sum)]] table.aggregate",
            .expected = "{\"total\" [60]}",
        },
        .{
            // With keys a zero-row table has zero result rows; without keys it
            // has one group whose quotations receive empty columns.
            .name = "zero-row tables aggregate per the policy",
            .source = "[\"r\" \"v\"] [] table.from-rows [\"r\"] [[\"t\" \"v\" (sum)]] table.aggregate " ++
                "[\"r\" \"v\"] [] table.from-rows [] [[\"t\" \"v\" (sum)]] table.aggregate",
            .expected = "{\"r\" () \"t\" ()} {\"t\" [0]}",
        },
        .{
            .name = "keys alone are a legal aggregation",
            .source = "{\"r\" [\"e\" \"w\" \"e\"] \"v\" [1 2 3]} [\"r\"] [] table.aggregate",
            .expected = "{\"r\" (\"e\" \"w\")}",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "group-by requires existing names",
            .source = "{\"a\" [1]} [\"z\"] table.group-by",
            .kind = "domain",
            .message_contains = "existing column names",
        },
        .{
            .name = "aggregate needs at least one key or output",
            .source = "{\"a\" [1]} [] [] table.aggregate",
            .kind = "domain",
            .message_contains = "at least one key or aggregate output",
        },
        .{
            .name = "an output may not collide with a key",
            .source = "{\"r\" [\"e\"] \"v\" [1]} [\"r\"] [[\"r\" \"v\" (sum)]] table.aggregate",
            .kind = "domain",
            .message_contains = "must not collide",
        },
        .{
            .name = "aggregate requires an existing input column",
            .source = "{\"r\" [\"e\"] \"v\" [1]} [\"r\"] [[\"t\" \"zz\" (sum)]] table.aggregate",
            .kind = "domain",
            .message_contains = "existing input column",
        },
        .{
            .name = "a malformed specification is type",
            .source = "{\"r\" [\"e\"] \"v\" [1]} [\"r\"] [[\"t\" \"v\"]] table.aggregate",
            .kind = "type",
            .message_contains = "[output-name input-name quotation]",
        },
        .{
            // The quotation is applied through `each`, so a wrong output
            // arity is the ordinary contract failure.
            .name = "a quotation of the wrong shape is contract",
            .source = "{\"r\" [\"e\"] \"v\" [1]} [\"r\"] [[\"t\" \"v\" (dup)]] table.aggregate",
            .kind = "contract",
            .word = "each",
        },
    });
}

test "table: joins expand stably with explicit missingness" {
    try support.expectStacks(&.{
        .{
            .name = "inner join emits matches only",
            .source = "{\"id\" [1 2 3] \"v\" [\"a\" \"b\" \"c\"]} " ++
                "{\"cid\" [2 3 4] \"name\" [\"x\" \"y\" \"z\"]} " ++
                "[[\"id\" \"cid\"]] table.inner-join",
            .expected = "{\"id\" [2 3] \"v\" (\"b\" \"c\") \"name\" (\"x\" \"y\")}",
        },
        .{
            // Left-major, right-minor: left row a pairs with x then y, then
            // left row b does the same.
            .name = "duplicates expand many-to-many in stable order",
            .source = "{\"id\" [1 1] \"v\" [\"a\" \"b\"]} {\"cid\" [1 1] \"name\" [\"x\" \"y\"]} " ++
                "[[\"id\" \"cid\"]] table.inner-join",
            .expected = "{\"id\" [1 1 1 1] \"v\" (\"a\" \"a\" \"b\" \"b\") " ++
                "\"name\" (\"x\" \"y\" \"x\" \"y\")}",
        },
        .{
            .name = "no matches yields a zero-row schema",
            .source = "{\"id\" [1 2] \"v\" [\"a\" \"b\"]} {\"cid\" [9] \"name\" [\"x\"]} " ++
                "[[\"id\" \"cid\"]] table.inner-join table.height",
            .expected = "0",
        },
        .{
            .name = "composite keys join on every pair",
            .source = "{\"a\" [1] \"b\" [2] \"v\" [\"p\"]} {\"c\" [1] \"d\" [2] \"n\" [\"q\"]} " ++
                "[[\"a\" \"c\"] [\"b\" \"d\"]] table.inner-join",
            .expected = "{\n" ++
                "  \"a\" [1]\n" ++
                "  \"b\" [2]\n" ++
                "  \"v\" (\"p\")\n" ++
                "  \"n\" (\"q\")\n" ++
                "}",
        },
        .{
            // The fill is the caller's value and nothing else; a JSON 'null
            // used as a fill stays ordinary data.
            .name = "left join fills unmatched rows from the caller's dict",
            .source = "{\"id\" [1 2] \"v\" [\"a\" \"b\"]} {\"cid\" [2] \"name\" [\"y\"]} " ++
                "[[\"id\" \"cid\"]] {\"name\" 'null} table.left-join-with",
            .expected = "{\"id\" [1 2] \"v\" (\"a\" \"b\") \"name\" ('null \"y\")}",
        },
        .{
            .name = "a left join emits at least one row per left row",
            .source = "{\"id\" [1 2 3]} {\"cid\" [2 2]} [[\"id\" \"cid\"]] {} " ++
                "table.left-join-with table.height",
            .expected = "4",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "a non-key collision is domain",
            .source = "{\"id\" [1]} {\"cid\" [1] \"id\" [7]} [[\"id\" \"cid\"]] table.inner-join",
            .kind = "domain",
            .message_contains = "collide non-key column names",
        },
        .{
            .name = "an incomplete fill is domain",
            .source = "{\"id\" [1 2]} {\"cid\" [2] \"name\" [\"y\"]} [[\"id\" \"cid\"]] {} " ++
                "table.left-join-with",
            .kind = "domain",
            .message_contains = "cover every appended right column",
        },
        .{
            .name = "an excessive fill is domain",
            .source = "{\"id\" [1 2]} {\"cid\" [2] \"name\" [\"y\"]} [[\"id\" \"cid\"]] " ++
                "{\"name\" 1 \"extra\" 2} table.left-join-with",
            .kind = "domain",
            .message_contains = "exactly the appended right columns",
        },
        .{
            .name = "a join needs at least one key pair",
            .source = "{\"id\" [1]} {\"cid\" [1]} [] table.inner-join",
            .kind = "domain",
            .message_contains = "at least one key pair",
        },
        .{
            .name = "a malformed key pair is type",
            .source = "{\"id\" [1]} {\"cid\" [1]} [[\"id\"]] table.inner-join",
            .kind = "type",
            .message_contains = "[left-name right-name] pairs",
        },
        .{
            .name = "a join key must name an existing right column",
            .source = "{\"id\" [1]} {\"cid\" [1]} [[\"id\" \"zz\"]] table.inner-join",
            .kind = "domain",
            .message_contains = "existing right columns",
        },
    });
}

test "table: every exported core word has nonempty documentation" {
    const names = [_][]const u8{
        "valid?",           "names",        "height", "from-columns", "from-rows",
        "from-header-rows", "from-records", "rows",   "header-rows",  "records",
        "column",           "cast",         "select", "rename",       "with-column",
        "where",
    };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'table.{s} body type 'table.{s} doc len 0 >",
            .{ name, name },
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "'list 1");
    }
}
