const std = @import("std");
const cli = @import("cli_test_support.zig");
const ohsnap = @import("ohsnap");
const build_options = @import("reference_options");

const allocator = std.testing.allocator;

const Case = struct {
    name: []const u8,
    source: []const u8,
};

const cases = [_]Case{
    .{ .name = "str", .source = "['a 1] str" },
    .{ .name = "+", .source = "[1 2] 3 +" },
    .{ .name = "-", .source = "\\c \\a -" },
    .{ .name = "*", .source = "[[1 2] [3]] 10 *" },
    .{ .name = "/", .source = "1 0 /" },
    .{ .name = "div", .source = "7 3 div" },
    .{ .name = "mod", .source = "7 3 mod" },
    .{ .name = "pow", .source = "2 3 pow" },
    .{ .name = "min", .source = "2 3.0 min" },
    .{ .name = "max", .source = "2 3.0 max" },
    .{ .name = "=", .source = "[1 2] [1 3] =" },
    .{ .name = "<>", .source = "[1 2] [1 3] <>" },
    .{ .name = "<", .source = "[1 2] 2 <" },
    .{ .name = ">", .source = "[1 2] 2 >" },
    .{ .name = "<=", .source = "[1 2] 2 <=" },
    .{ .name = ">=", .source = "[1 2] 2 >=" },
    .{ .name = "and", .source = "[0 1] 1 and" },
    .{ .name = "or", .source = "[0 1] 0 or" },
    .{ .name = "neg", .source = "[1 -2] neg" },
    .{ .name = "abs", .source = "[-1 2] abs" },
    .{ .name = "sqrt", .source = "[4 9] sqrt" },
    .{ .name = "floor", .source = "[1.9 -1.1] floor" },
    .{ .name = "ceil", .source = "[1.1 -1.9] ceil" },
    .{ .name = "round", .source = "[1.4 1.6] round" },
    .{ .name = "not", .source = "[0 1] not" },
    .{ .name = "len", .source = "\"aé\" len" },
    .{ .name = "shape", .source = "[[1 2] [3]] shape" },
    .{ .name = "first", .source = "\"ab\" first" },
    .{ .name = "rest", .source = "\"abc\" rest \"a\" rest" },
    .{ .name = "take", .source = "[1 2 3] -2 take \"abc\" 0 take" },
    .{ .name = "drop", .source = "[1 2 3] -1 drop \"a\" 1 drop" },
    .{ .name = "at", .source = "[10 20 30] [2 0] at" },
    .{ .name = "where", .source = "[1 0 1] where" },
    .{ .name = "in", .source = "[2 4] [1 2 3] in" },
    .{ .name = "find", .source = "[2 3 2] 3 find" },
    .{ .name = "raze", .source = "[[1 2] [3]] raze" },
    .{ .name = "cat", .source = "\"ab\" \"cd\" cat \"\" \"\" cat" },
    .{ .name = "reverse", .source = "\"abc\" reverse \"\" reverse" },
    .{ .name = "range", .source = "5 range" },
    .{ .name = "grade", .source = "[2 1 2 1] grade" },
    .{ .name = "sort", .source = "[2 1 2 1] sort" },
    .{ .name = "distinct", .source = "[2 1 2 1] distinct" },
    .{ .name = "keys", .source = "{'a 1 'b 2} keys" },
    .{ .name = "vals", .source = "{'a 1 'b 2} vals" },
    .{ .name = "put", .source = "{'a 1} 'b 2 put" },
    .{ .name = "del", .source = "{'a 1 'b 2} 'a del" },
    .{ .name = "merge", .source = "{'a 1 'b 2} {'b 20 'c 3} merge" },
    .{ .name = "has?", .source = "{\"ab\" 9} \"ab\" has? {[1 2] 9} [1 2] has?" },
    .{ .name = "split", .source = "\"a—b—\" \"—\" split first" },
    .{ .name = "join", .source = "[\"a\" 2] \"-\" join" },
    .{ .name = "format", .source = "[3.14 2] \"pi={} n={}\" format" },
    .{ .name = "parse", .source = "\"42\" parse first" },
    .{ .name = "each", .source = "[1 2 3] (dup *) each" },
    .{ .name = "zip-with", .source = "[1 2] [3 4] (+) zip-with" },
    .{ .name = "for", .source = "[1 2] (pp) for" },
    .{ .name = "fold", .source = "[1 2 3] 0 (+) fold" },
    .{ .name = "scan", .source = "[1 2 3] 0 (+) scan" },
    .{ .name = "nip", .source = "1 2 nip" },
    .{ .name = "when", .source = "1 (7) when" },
    .{ .name = "wrap", .source = "1 wrap" },
    .{ .name = "pair", .source = "1 2 pair" },
    .{ .name = "last", .source = "[1 2 3] last" },
    .{ .name = "sum", .source = "[1 2 3] sum" },
    .{ .name = "prod", .source = "[1 2 3] prod" },
    .{ .name = "mean", .source = "[1 2 3] mean" },
    .{ .name = "print", .source = "\"hi\" print" },
    .{ .name = "inspect", .source = "7 inspect" },
    .{ .name = "keep", .source = "2 (1 +) keep" },
    .{ .name = "bi", .source = "2 (1 +) (3 *) bi" },
    .{ .name = "tri", .source = "2 (1 +) (3 *) (4 -) tri" },
    .{ .name = "fail", .source = "\"bad\" fail" },
    .{ .name = "ok?", .source = "(2 3 +) attempt ok?" },
    .{ .name = "or-raise", .source = "(2 3 +) attempt or-raise" },
    .{ .name = "or-else", .source = "(2 3 +) attempt 9 or-else" },
};

test "promoted Zig CLI behavior matches the reference snapshot" {
    var transcript = std.Io.Writer.Allocating.init(allocator);
    defer transcript.deinit();

    for (cases) |case| {
        var result = try cli.run(&.{ build_options.zig_exe, "-e", case.source });
        defer result.deinit();
        const exit_code = switch (result.term) {
            .exited => |code| code,
            .signal, .stopped, .unknown => return error.UnexpectedTermination,
        };
        try transcript.writer.print(
            "=== {s} ===\nsource: {s}\nexit: {d}\nstdout:\n{s}stderr:\n{s}",
            .{
                case.name,
                case.source,
                exit_code,
                if (result.stdout.len == 0) "<empty>\n" else result.stdout,
                if (result.stderr.len == 0) "<empty>\n" else result.stderr,
            },
        );
    }

    try ohsnap.default.snap(@src(),
        \\=== str ===
        \\source: ['a 1] str
        \\exit: 0
        \\stdout:
        \\"('a 1)"
        \\stderr:
        \\<empty>
        \\=== + ===
        \\source: [1 2] 3 +
        \\exit: 0
        \\stdout:
        \\[4 5]
        \\stderr:
        \\<empty>
        \\=== - ===
        \\source: \c \a -
        \\exit: 0
        \\stdout:
        \\2
        \\stderr:
        \\<empty>
        \\=== * ===
        \\source: [[1 2] [3]] 10 *
        \\exit: 0
        \\stdout:
        \\([10 20] [30])
        \\stderr:
        \\<empty>
        \\=== / ===
        \\source: 1 0 /
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "kernel arithmetic is outside its domain" 'word '/ 'trace ['/] 'data {'source "<command>" 'line 1 'col 5}}
        \\=== div ===
        \\source: 7 3 div
        \\exit: 0
        \\stdout:
        \\2
        \\stderr:
        \\<empty>
        \\=== mod ===
        \\source: 7 3 mod
        \\exit: 0
        \\stdout:
        \\1
        \\stderr:
        \\<empty>
        \\=== pow ===
        \\source: 2 3 pow
        \\exit: 0
        \\stdout:
        \\8.0
        \\stderr:
        \\<empty>
        \\=== min ===
        \\source: 2 3.0 min
        \\exit: 0
        \\stdout:
        \\2
        \\stderr:
        \\<empty>
        \\=== max ===
        \\source: 2 3.0 max
        \\exit: 0
        \\stdout:
        \\3.0
        \\stderr:
        \\<empty>
        \\=== = ===
        \\source: [1 2] [1 3] =
        \\exit: 0
        \\stdout:
        \\[1 0]
        \\stderr:
        \\<empty>
        \\=== <> ===
        \\source: [1 2] [1 3] <>
        \\exit: 0
        \\stdout:
        \\[0 1]
        \\stderr:
        \\<empty>
        \\=== < ===
        \\source: [1 2] 2 <
        \\exit: 0
        \\stdout:
        \\[1 0]
        \\stderr:
        \\<empty>
        \\=== > ===
        \\source: [1 2] 2 >
        \\exit: 0
        \\stdout:
        \\[0 0]
        \\stderr:
        \\<empty>
        \\=== <= ===
        \\source: [1 2] 2 <=
        \\exit: 0
        \\stdout:
        \\[1 1]
        \\stderr:
        \\<empty>
        \\=== >= ===
        \\source: [1 2] 2 >=
        \\exit: 0
        \\stdout:
        \\[0 1]
        \\stderr:
        \\<empty>
        \\=== and ===
        \\source: [0 1] 1 and
        \\exit: 0
        \\stdout:
        \\[0 1]
        \\stderr:
        \\<empty>
        \\=== or ===
        \\source: [0 1] 0 or
        \\exit: 0
        \\stdout:
        \\[0 1]
        \\stderr:
        \\<empty>
        \\=== neg ===
        \\source: [1 -2] neg
        \\exit: 0
        \\stdout:
        \\[-1 2]
        \\stderr:
        \\<empty>
        \\=== abs ===
        \\source: [-1 2] abs
        \\exit: 0
        \\stdout:
        \\[1 2]
        \\stderr:
        \\<empty>
        \\=== sqrt ===
        \\source: [4 9] sqrt
        \\exit: 0
        \\stdout:
        \\[2.0 3.0]
        \\stderr:
        \\<empty>
        \\=== floor ===
        \\source: [1.9 -1.1] floor
        \\exit: 0
        \\stdout:
        \\[1 -2]
        \\stderr:
        \\<empty>
        \\=== ceil ===
        \\source: [1.1 -1.9] ceil
        \\exit: 0
        \\stdout:
        \\[2 -1]
        \\stderr:
        \\<empty>
        \\=== round ===
        \\source: [1.4 1.6] round
        \\exit: 0
        \\stdout:
        \\[1 2]
        \\stderr:
        \\<empty>
        \\=== not ===
        \\source: [0 1] not
        \\exit: 0
        \\stdout:
        \\[1 0]
        \\stderr:
        \\<empty>
        \\=== len ===
        \\source: "aé" len
        \\exit: 0
        \\stdout:
        \\2
        \\stderr:
        \\<empty>
        \\=== shape ===
        \\source: [[1 2] [3]] shape
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'shape 'msg "shape requires a rectangular list" 'word 'shape 'trace ['shape] 'data {'source "<command>" 'line 1 'col 13}}
        \\=== first ===
        \\source: "ab" first
        \\exit: 0
        \\stdout:
        \\\a
        \\stderr:
        \\<empty>
        \\=== rest ===
        \\source: "abc" rest "a" rest
        \\exit: 0
        \\stdout:
        \\"bc" ""
        \\stderr:
        \\<empty>
        \\=== take ===
        \\source: [1 2 3] -2 take "abc" 0 take
        \\exit: 0
        \\stdout:
        \\[2 3] ""
        \\stderr:
        \\<empty>
        \\=== drop ===
        \\source: [1 2 3] -1 drop "a" 1 drop
        \\exit: 0
        \\stdout:
        \\[1 2] ""
        \\stderr:
        \\<empty>
        \\=== at ===
        \\source: [10 20 30] [2 0] at
        \\exit: 0
        \\stdout:
        \\[30 10]
        \\stderr:
        \\<empty>
        \\=== where ===
        \\source: [1 0 1] where
        \\exit: 0
        \\stdout:
        \\[0 2]
        \\stderr:
        \\<empty>
        \\=== in ===
        \\source: [2 4] [1 2 3] in
        \\exit: 0
        \\stdout:
        \\[1 0]
        \\stderr:
        \\<empty>
        \\=== find ===
        \\source: [2 3 2] 3 find
        \\exit: 0
        \\stdout:
        \\1
        \\stderr:
        \\<empty>
        \\=== raze ===
        \\source: [[1 2] [3]] raze
        \\exit: 0
        \\stdout:
        \\[1 2 3]
        \\stderr:
        \\<empty>
        \\=== cat ===
        \\source: "ab" "cd" cat "" "" cat
        \\exit: 0
        \\stdout:
        \\"abcd" ""
        \\stderr:
        \\<empty>
        \\=== reverse ===
        \\source: "abc" reverse "" reverse
        \\exit: 0
        \\stdout:
        \\"cba" ""
        \\stderr:
        \\<empty>
        \\=== range ===
        \\source: 5 range
        \\exit: 0
        \\stdout:
        \\[0 1 2 3 4]
        \\stderr:
        \\<empty>
        \\=== grade ===
        \\source: [2 1 2 1] grade
        \\exit: 0
        \\stdout:
        \\[1 3 0 2]
        \\stderr:
        \\<empty>
        \\=== sort ===
        \\source: [2 1 2 1] sort
        \\exit: 0
        \\stdout:
        \\[1 1 2 2]
        \\stderr:
        \\<empty>
        \\=== distinct ===
        \\source: [2 1 2 1] distinct
        \\exit: 0
        \\stdout:
        \\[2 1]
        \\stderr:
        \\<empty>
        \\=== keys ===
        \\source: {'a 1 'b 2} keys
        \\exit: 0
        \\stdout:
        \\['a 'b]
        \\stderr:
        \\<empty>
        \\=== vals ===
        \\source: {'a 1 'b 2} vals
        \\exit: 0
        \\stdout:
        \\[1 2]
        \\stderr:
        \\<empty>
        \\=== put ===
        \\source: {'a 1} 'b 2 put
        \\exit: 0
        \\stdout:
        \\{'a 1 'b 2}
        \\stderr:
        \\<empty>
        \\=== del ===
        \\source: {'a 1 'b 2} 'a del
        \\exit: 0
        \\stdout:
        \\{'b 2}
        \\stderr:
        \\<empty>
        \\=== merge ===
        \\source: {'a 1 'b 2} {'b 20 'c 3} merge
        \\exit: 0
        \\stdout:
        \\{'a 1 'b 20 'c 3}
        \\stderr:
        \\<empty>
        \\=== has? ===
        \\source: {"ab" 9} "ab" has? {[1 2] 9} [1 2] has?
        \\exit: 0
        \\stdout:
        \\1 1
        \\stderr:
        \\<empty>
        \\=== split ===
        \\source: "a—b—" "—" split first
        \\exit: 0
        \\stdout:
        \\"a"
        \\stderr:
        \\<empty>
        \\=== join ===
        \\source: ["a" 2] "-" join
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'type 'msg "join expected a list of strings" 'word 'join 'trace ['join] 'data {'index 1 'source "<command>" 'line 1 'col 13}}
        \\=== format ===
        \\source: [3.14 2] "pi={} n={}" format
        \\exit: 0
        \\stdout:
        \\"pi=3.14 n=2"
        \\stderr:
        \\<empty>
        \\=== parse ===
        \\source: "42" parse first
        \\exit: 0
        \\stdout:
        \\42
        \\stderr:
        \\<empty>
        \\=== each ===
        \\source: [1 2 3] (dup *) each
        \\exit: 0
        \\stdout:
        \\[1 4 9]
        \\stderr:
        \\<empty>
        \\=== zip-with ===
        \\source: [1 2] [3 4] (+) zip-with
        \\exit: 0
        \\stdout:
        \\[4 6]
        \\stderr:
        \\<empty>
        \\=== for ===
        \\source: [1 2] (pp) for
        \\exit: 0
        \\stdout:
        \\1
        \\2
        \\stderr:
        \\<empty>
        \\=== fold ===
        \\source: [1 2 3] 0 (+) fold
        \\exit: 0
        \\stdout:
        \\6
        \\stderr:
        \\<empty>
        \\=== scan ===
        \\source: [1 2 3] 0 (+) scan
        \\exit: 0
        \\stdout:
        \\[1 3 6]
        \\stderr:
        \\<empty>
        \\=== nip ===
        \\source: 1 2 nip
        \\exit: 0
        \\stdout:
        \\2
        \\stderr:
        \\<empty>
        \\=== when ===
        \\source: 1 (7) when
        \\exit: 0
        \\stdout:
        \\7
        \\stderr:
        \\<empty>
        \\=== wrap ===
        \\source: 1 wrap
        \\exit: 0
        \\stdout:
        \\[1]
        \\stderr:
        \\<empty>
        \\=== pair ===
        \\source: 1 2 pair
        \\exit: 0
        \\stdout:
        \\[1 2]
        \\stderr:
        \\<empty>
        \\=== last ===
        \\source: [1 2 3] last
        \\exit: 0
        \\stdout:
        \\3
        \\stderr:
        \\<empty>
        \\=== sum ===
        \\source: [1 2 3] sum
        \\exit: 0
        \\stdout:
        \\6
        \\stderr:
        \\<empty>
        \\=== prod ===
        \\source: [1 2 3] prod
        \\exit: 0
        \\stdout:
        \\6
        \\stderr:
        \\<empty>
        \\=== mean ===
        \\source: [1 2 3] mean
        \\exit: 0
        \\stdout:
        \\2.0
        \\stderr:
        \\<empty>
        \\=== print ===
        \\source: "hi" print
        \\exit: 0
        \\stdout:
        \\hi
        \\stderr:
        \\<empty>
        \\=== inspect ===
        \\source: 7 inspect
        \\exit: 0
        \\stdout:
        \\7
        \\7
        \\stderr:
        \\<empty>
        \\=== keep ===
        \\source: 2 (1 +) keep
        \\exit: 0
        \\stdout:
        \\3 2
        \\stderr:
        \\<empty>
        \\=== bi ===
        \\source: 2 (1 +) (3 *) bi
        \\exit: 0
        \\stdout:
        \\3 6
        \\stderr:
        \\<empty>
        \\=== tri ===
        \\source: 2 (1 +) (3 *) (4 -) tri
        \\exit: 0
        \\stdout:
        \\3 6 -2
        \\stderr:
        \\<empty>
        \\=== fail ===
        \\source: "bad" fail
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'user 'msg "bad" 'word 'raise 'trace ['raise 'fail] 'data {'source "prelude.ecl" 'line 327 'col 47}}
        \\=== ok? ===
        \\source: (2 3 +) attempt ok?
        \\exit: 0
        \\stdout:
        \\1
        \\stderr:
        \\<empty>
        \\=== or-raise ===
        \\source: (2 3 +) attempt or-raise
        \\exit: 0
        \\stdout:
        \\[5]
        \\stderr:
        \\<empty>
        \\=== or-else ===
        \\source: (2 3 +) attempt 9 or-else
        \\exit: 0
        \\stdout:
        \\[5]
        \\stderr:
        \\<empty>
        \\
    ).diff(transcript.written(), true);
}
