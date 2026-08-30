//! The embedded `dict` module: immutable dictionary operations.
const support = @import("kernel_test_support.zig");

test "dict module: observations preserve insertion order" {
    try support.expectStack(
        "{'a 1 'b 2} dict.keys {'a 1 'b 2} dict.size {'a 1 'b 2} dict.vals {'a 1 'b 2} dict.pairs " ++
            "{'a 1} 'a dict.has? {'a 1} 'b dict.has? " ++
            "{'a 1 'b 2} ['b 'a] dict.keys-exactly? " ++
            "{'a 1} ['a 'b] dict.keys-exactly?",
        "['a 'b] 2 [1 2] (('a 1) ('b 2)) 1 0 1 0",
    );
}

test "dict module: has is whole-value key membership" {
    try support.expectStack(
        "{\"ab\" 9} \"ab\" dict.has? {[1 2] 9} [1 2] dict.has? " ++
            "{missing 9} (missing) first dict.has? {{'a 1} 9} {'a 1} dict.has? " ++
            "{1 9} 1.0 dict.has? {\"ab\" 9} \"a\" dict.has?",
        "1 1 1 1 1 0",
    );
    try support.expectError(.{
        .name = "has requires a dictionary",
        .source = "[] 'a dict.has?",
        .kind = "type",
        .word = "dict.has?",
    });
}

test "dict module: at confirms and gathers requested whole-value keys" {
    try support.expectStacks(&.{
        .{
            .name = "requested order and duplicates",
            .source = "{'a 1 'b 2 'c 3} ['c 'a 'c] dict.at",
            .expected = "[3 1 3]",
        },
        .{
            .name = "structural keys remain atomic",
            .source = "{[1 2] 9 'a 1} [[1 2] 'a] dict.at",
            .expected = "[9 1]",
        },
        .{
            .name = "empty request",
            .source = "{'a 1} [] dict.at",
            .expected = "()",
        },
        .{
            .name = "core at still accepts one structural key",
            .source = "{[1 2] 9} [1 2] at",
            .expected = "9",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "missing requested key",
            .source = "{'a 1} ['a 'missing] dict.at",
            .kind = "domain",
            .message_contains = "could not find the dict key",
            .word = "at",
        },
        .{
            .name = "keys must be a list",
            .source = "{'a 1} 'a dict.at",
            .kind = "type",
            .word = "dict.at",
        },
        .{
            .name = "source must be a dictionary",
            .source = "[] [] dict.at",
            .kind = "type",
            .word = "dict.at",
        },
    });
}

test "dict module: update transforms requested whole-value keys without reordering" {
    try support.expectStack(
        "{'a 1 'b 2 'c 3} ['b 'a] (10 *) dict.update " ++
            "{[1 2] 9 'a 1} [[1 2] 'a] (1 +) dict.update " ++
            "{'a 1} ['a 'a] (1 +) dict.update " ++
            "{'a 1} [] (missing) dict.update",
        "{'a 10 'b 20 'c 3} {[1 2] 10 'a 2} {'a 3} {'a 1}",
    );
    try support.expectErrors(&.{
        .{
            .name = "missing update key",
            .source = "{'a 1} ['a 'b] (10 *) dict.update",
            .kind = "domain",
            .word = "dict.update",
        },
        .{
            .name = "update keys must be a list",
            .source = "{'a 1} 'a (10 *) dict.update",
            .kind = "type",
            .word = "dict.update",
        },
        .{
            .name = "update quotation must return one value",
            .source = "{'a 1} ['a] (dup) dict.update",
            .kind = "contract",
            .word = "dict.update",
        },
    });
}

test "dict module: construction accepts pairs and repeated values" {
    try support.expectStacks(&.{
        .{
            .name = "pairs round trip",
            .source = "[['a 1] ['b 2]] dict.from-pairs dup dict.pairs dict.from-pairs match?",
            .expected = "1",
        },
        .{
            .name = "one value for distinct keys",
            .source = "['a 'b 'c] 0 dict.from-keys",
            .expected = "{'a 0 'b 0 'c 0}",
        },
        .{
            .name = "empty constructions",
            .source = "[] dict.from-pairs [] 0 dict.from-keys",
            .expected = "{} {}",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "from-pairs requires pairs",
            .source = "[['a 1] ['b]] dict.from-pairs",
            .kind = "shape",
            .message_contains = "two-element pairs",
        },
        .{
            .name = "from-pairs rejects duplicate keys",
            .source = "[['a 1] ['a 2]] dict.from-pairs",
            .kind = "domain",
            .word = "dict.from-flat",
        },
    });
}

test "dict module: update-or distinguishes existing keys from defaults" {
    try support.expectStack(
        "{'a 2} 'a 9 (10 *) dict.update-or {'a 2} 'b 9 (missing) dict.update-or",
        "{'a 20} {'a 2 'b 9}",
    );
}

test "dict module: map and map-values preserve keys" {
    try support.expectStacks(&.{
        .{
            .name = "map observes keys and values",
            .source = "{'a 1 'b 2 'c 3} (nip 10 *) dict.map",
            .expected = "{'a 10 'b 20 'c 30}",
        },
        .{
            .name = "empty map does not call its quotation",
            .source = "{} (missing) dict.map",
            .expected = "{}",
        },
        .{
            .name = "map can combine each key and value",
            .source = "{'a 1 'b 2} (pair) dict.map",
            .expected = "{'a ('a 1) 'b ('b 2)}",
        },
        .{
            .name = "map-values receives only values",
            .source = "{'a 1 'b 2} (str) dict.map-values",
            .expected = "{'a \"1\" 'b \"2\"}",
        },
    });
}

test "dict module: predicates and key selection preserve dictionary order" {
    try support.expectStacks(&.{
        .{
            .name = "filter and reject receive key and value",
            .source = "{'a 1 'b 2 'c 3} (nip 2 >) dict.filter " ++
                "{'a 1 'b 2 'c 3} (nip 2 >) dict.reject",
            .expected = "{'c 3} {'a 1 'b 2}",
        },
        .{
            .name = "take follows dictionary order and ignores missing keys",
            .source = "{'a 1 'b 2 'c 3} ['c 'missing 'a] dict.take",
            .expected = "{'a 1 'c 3}",
        },
        .{
            .name = "drop ignores missing keys",
            .source = "{'a 1 'b 2 'c 3} ['b 'missing] dict.drop",
            .expected = "{'a 1 'c 3}",
        },
        .{
            .name = "split returns selected then rejected",
            .source = "{'a 1 'b 2 'c 3} ['c 'a] dict.split",
            .expected = "{'a 1 'c 3} {'b 2}",
        },
    });
}

test "dict module: merge operations preserve stable order and resolve collisions" {
    try support.expectStacks(&.{
        .{
            .name = "right-biased merge",
            .source = "{'a 1 'b 2} {'b 20 'c 30} dict.merge",
            .expected = "{'a 1 'b 20 'c 30}",
        },
        .{
            .name = "merge-with sees key left and right",
            .source = "{'a 1 'b 2} {'b 20 'c 30 'a 10} " ++
                "(|key left right| key pop left right +) dict.merge-with",
            .expected = "{'a 11 'b 22 'c 30}",
        },
        .{
            .name = "merge-with does not call the resolver for new keys",
            .source = "{} {'a 1} (missing) dict.merge-with",
            .expected = "{'a 1}",
        },
    });
    try support.expectError(.{
        .name = "merge-with resolver must return one value",
        .source = "{'a 1} {'a 2} (pop pop pop) dict.merge-with",
        .kind = "contract",
        .word = "dict.merge-with",
    });
}

test "dict module: every public operation carries reflective documentation" {
    try support.expectStack(
        "['dict.keys 'dict.size 'dict.vals 'dict.pairs 'dict.has? 'dict.at 'dict.merge 'dict.from-flat " ++
            "'dict.from-lists 'dict.from-pairs 'dict.from-keys 'dict.keys-exactly? " ++
            "'dict.update 'dict.update-or 'dict.map " ++
            "'dict.map-values 'dict.filter 'dict.reject 'dict.take 'dict.drop 'dict.split " ++
            "'dict.merge-with] (doc len 0 >) all?",
        "1",
    );
}
