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
    .{ .name = "first-where", .source = "[0 2 0] first-where" },
    .{ .name = "in?", .source = "[2 4] [1 2 3] in?" },
    .{ .name = "find", .source = "[2 3 2] 3 find" },
    .{ .name = "raze", .source = "[[1 2] [3]] raze" },
    .{ .name = "cat", .source = "\"ab\" \"cd\" cat \"\" \"\" cat" },
    .{ .name = "reverse", .source = "\"abc\" reverse \"\" reverse" },
    .{ .name = "range", .source = "5 range" },
    .{ .name = "grade", .source = "[2 1 2 1] grade" },
    .{ .name = "sort", .source = "[2 1 2 1] sort" },
    .{ .name = "distinct", .source = "[2 1 2 1] distinct" },
    .{ .name = "dict.keys", .source = "{'a 1 'b 2} dict.keys" },
    .{ .name = "dict.vals", .source = "{'a 1 'b 2} dict.vals" },
    .{ .name = "put", .source = "{'a 1} 'b 2 put" },
    .{ .name = "del", .source = "{'a 1 'b 2} 'a del" },
    .{ .name = "dict.merge", .source = "{'a 1 'b 2} {'b 20 'c 3} dict.merge" },
    .{ .name = "dict.has?", .source = "{\"ab\" 9} \"ab\" dict.has? {[1 2] 9} [1 2] dict.has?" },
    .{ .name = "split", .source = "\"a—b—\" \"—\" split first" },
    .{ .name = "join", .source = "[\"a\" 2] \"-\" join" },
    .{ .name = "str.format", .source = "[3.14 2] \"pi={} n={}\" str.format" },
    .{ .name = "parse", .source = "\"42\" parse first" },
    .{ .name = "int", .source = "\"42\" int \"a\" first int" },
    .{ .name = "float", .source = "\"3.5\" float 3 float" },
    .{ .name = "chars", .source = "'foo chars [104 195 169] chars" },
    .{ .name = "bytes", .source = "\"hé\" bytes" },
    .{ .name = "symbol", .source = "'a pop \"a\" symbol" },
    .{ .name = "char", .source = "955 char" },
    .{ .name = "core qualifier", .source = "(2 *) 'dup def 3 dup 3 core.dup" },
    .{ .name = "each", .source = "[1 2 3] (dup *) each" },
    .{ .name = "zip-with", .source = "[1 2] [3 4] (+) zip-with" },
    .{ .name = "for", .source = "[1 2] (io.pp) for" },
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
    .{ .name = "print", .source = "\"hi\" io.print" },
    .{ .name = "io.inspect", .source = "7 io.inspect" },
    .{ .name = "io.stack", .source = "1 [2 3] io.stack" },
    .{ .name = "keep", .source = "2 (1 +) keep" },
    .{ .name = "bi", .source = "2 (1 +) (3 *) bi" },
    .{ .name = "tri", .source = "2 (1 +) (3 *) (4 -) tri" },
    .{ .name = "fail", .source = "\"bad\" fail" },
    .{ .name = "result.ok?", .source = "[] (2 3 +) @attempt result.ok?" },
    .{ .name = "result.or-raise", .source = "[] (2 3 +) @attempt result.or-raise" },
    .{ .name = "result.or-else", .source = "[] (2 3 +) @attempt 9 result.or-else" },
    .{ .name = "result.either", .source = "[7] result.ok (first) (pop 0) result.either" },
    .{ .name = "result.map-err", .source = "{'kind 'io} result.err (pop {'kind 'domain}) result.map-err" },
    // The prelude no longer carries these: the envelope interpreters live in
    // the module, and the old bare spellings resolve to nothing.
    .{ .name = "bare or-raise", .source = "[] (2 3 +) @attempt or-raise" },
    .{ .name = "bare ok?", .source = "[] (2 3 +) @attempt ok?" },
    .{ .name = "gone result.case", .source = "[7] result.ok (first) (pop 0) result.case" },
    .{ .name = "set", .source = "3 'x set x" },
    .{ .name = "set quotation", .source = "(dup *) 'q set q" },
    .{ .name = "which", .source = "3 'x set 'x which" },
    .{ .name = "see", .source = "3 'x set 'x see" },
    .{ .name = "see set", .source = "'set see" },
    .{ .name = "setp", .source = "1 'x setp" },
    .{ .name = "qualify execute", .source = "[] ((41) 'f def) 'core.utils @defm 'core.utils 'f qualify execute" },
    .{ .name = "execute type", .source = "1 execute" },
    .{ .name = "doc qualify", .source = "'qualify doc" },
    .{ .name = "within top level", .source = "(1) within" },
    .{ .name = "without top level", .source = "without" },
    .{ .name = "see within", .source = "'within see" },
    .{ .name = "doc without", .source = "'without doc" },
    .{ .name = "unmodule unknown", .source = "'nowhere unmodule" },
    .{ .name = "unmodule then resolve", .source = "[] ((1) 'x def) 'gone @defm 'gone unmodule gone.x" },
    .{ .name = "doc unmodule", .source = "'unmodule doc" },
    // M12 stdlib and host scripting. Deterministic output only: no network,
    // and no environment dependence beyond an unset-variable error.
    .{ .name = "result ok", .source = "[1 2] result.ok" },
    .{ .name = "result and-then", .source = "[2 3] result.ok (+) result.and-then" },
    .{ .name = "result all", .source = "[1] result.ok {'kind 'io} result.err 2 pack result.all" },
    .{ .name = "result malformed", .source = "{'ok 5} (missing) result.and-then" },
    .{ .name = "str upper", .source = "\"héllo\" str.upper" },
    .{ .name = "str index-of missing", .source = "\"abc\" \"z\" str.index-of" },
    .{ .name = "csv parse", .source = "\"a,,c\nd\" csv.parse" },
    .{ .name = "csv emit", .source = "\"a,b\" csv.parse csv.emit" },
    .{ .name = "csv malformed", .source = "\"\\\"x\" csv.parse" },
    .{ .name = "json parse", .source = "\"{\\\"a\\\":[1,null,true]}\" json.parse" },
    .{ .name = "json emit", .source = "{'a 1} json.emit" },
    .{ .name = "json emit key", .source = "{1 2} json.emit" },
    .{ .name = "table rows", .source = "{\"a\" [1 2] \"b\" [\"x\" \"y\"]} table.rows" },
    .{ .name = "table where", .source = "{\"a\" [1 2 3]} [1 0 1] table.where" },
    .{
        .name = "table aggregate",
        .source = "{\"r\" [\"e\" \"w\" \"e\"] \"v\" [1 2 3]} [\"r\"] " ++
            "[[\"t\" \"v\" (sum)]] table.aggregate",
    },
    .{ .name = "table invalid", .source = "{\"a\" [1 2] \"b\" [3]} table.rows" },
    .{ .name = "getenv unset", .source = "\"ECL_SNAPSHOT_ABSENT\" getenv" },
    .{ .name = "read-text missing", .source = "'cwd \"no-such-file.ecl\" fs.read-text" },
    .{ .name = "http dead port", .source = "\"http://127.0.0.1:1/x\" {} http.get" },
    // Bit patterns and counter-based randomness. Every draw here is seeded, so
    // the transcript is as reproducible as the arithmetic above it.
    .{ .name = "band", .source = "[12 10] 6 band" },
    .{ .name = "bor", .source = "12 10 bor" },
    .{ .name = "bxor", .source = "12 10 bxor" },
    .{ .name = "bsl", .source = "[1 -8] 4 bsl" },
    .{ .name = "bsr", .source = "-1 1 bsr" },
    .{ .name = "bnot", .source = "[0 5] bnot" },
    .{ .name = "bsl overshift", .source = "1 64 bsl" },
    .{ .name = "rand.int", .source = "[7 0] 6 rand.int" },
    .{ .name = "rand.ints", .source = "[7 0] 4 6 rand.ints" },
    .{ .name = "rand.float", .source = "[7 0] rand.float" },
    .{ .name = "rand.int empty range", .source = "[7 0] 0 rand.int" },
    .{ .name = "rng deal", .source = "'rng ('deal) import 3 10 deal" },
    // The unit-constructor convention: the guided boundary error and the
    // seeding composition that replaced the `-with` family.
    .{ .name = "isolated substack", .source = "3 [1] (+) @attempt" },
    .{ .name = "isolated child", .source = "3 [1 2] [] (+ +) @each" },
    .{ .name = "seeded attempt", .source = "[3] (1 +) @attempt" },
    .{ .name = "seeded module", .source = "[7] ('base set) 'm @defm m.base" },
    // Anonymous construction, opaque identity, and one image under two names.
    .{ .name = "anonymous module", .source = "[] () @module type" },
    .{ .name = "module identity", .source = "[] (1) @module dup match? [] (1) @module [] (1) @module match?" },
    .{
        .name = "one image two registrations",
        .source = "[] (0 ((1 + dup without) within) 'bump def) @module " ++
            "dup 'l register 'r register l.bump l.bump r.bump",
    },
    .{ .name = "module marker is unreadable", .source = "\"<module>\" parse" },
    .{ .name = "old spelling", .source = "(1) attempt" },
    .{ .name = "row annotation", .source = "(a -- ...) (dup) 'f def 'f see" },
    .{ .name = "row after mixing", .source = "(a -- ... b) (dup) 'f def" },
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
        \\=== first-where ===
        \\source: [0 2 0] first-where
        \\exit: 0
        \\stdout:
        \\1
        \\stderr:
        \\<empty>
        \\=== in? ===
        \\source: [2 4] [1 2 3] in?
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
        \\=== dict.keys ===
        \\source: {'a 1 'b 2} dict.keys
        \\exit: 0
        \\stdout:
        \\['a 'b]
        \\stderr:
        \\<empty>
        \\=== dict.vals ===
        \\source: {'a 1 'b 2} dict.vals
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
        \\=== dict.merge ===
        \\source: {'a 1 'b 2} {'b 20 'c 3} dict.merge
        \\exit: 0
        \\stdout:
        \\{'a 1 'b 20 'c 3}
        \\stderr:
        \\<empty>
        \\=== dict.has? ===
        \\source: {"ab" 9} "ab" dict.has? {[1 2] 9} [1 2] dict.has?
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
        \\=== str.format ===
        \\source: [3.14 2] "pi={} n={}" str.format
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
        \\=== int ===
        \\source: "42" int "a" first int
        \\exit: 0
        \\stdout:
        \\42 97
        \\stderr:
        \\<empty>
        \\=== float ===
        \\source: "3.5" float 3 float
        \\exit: 0
        \\stdout:
        \\3.5 3.0
        \\stderr:
        \\<empty>
        \\=== chars ===
        \\source: 'foo chars [104 195 169] chars
        \\exit: 0
        \\stdout:
        \\"foo" "hé"
        \\stderr:
        \\<empty>
        \\=== bytes ===
        \\source: "hé" bytes
        \\exit: 0
        \\stdout:
        \\[104 195 169]
        \\stderr:
        \\<empty>
        \\=== symbol ===
        \\source: 'a pop "a" symbol
        \\exit: 0
        \\stdout:
        \\'a
        \\stderr:
        \\<empty>
        \\=== char ===
        \\source: 955 char
        \\exit: 0
        \\stdout:
        \\\λ
        \\stderr:
        \\<empty>
        \\=== core qualifier ===
        \\source: (2 *) 'dup def 3 dup 3 core.dup
        \\exit: 0
        \\stdout:
        \\6 3 3
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
        \\source: [1 2] (io.pp) for
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
        \\source: "hi" io.print
        \\exit: 0
        \\stdout:
        \\hi
        \\stderr:
        \\<empty>
        \\=== io.inspect ===
        \\source: 7 io.inspect
        \\exit: 0
        \\stdout:
        \\7
        \\7
        \\stderr:
        \\<empty>
        \\=== io.stack ===
        \\source: 1 [2 3] io.stack
        \\exit: 0
        \\stdout:
        \\[0] 1
        \\[1] [2 3]
        \\1 [2 3]
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
        \\{'kind 'user 'msg "bad" 'word 'raise 'trace ['raise 'fail] 'data {'source "prelude.ecl" 'line <^\d+$> 'col 54}}
        \\=== result.ok? ===
        \\source: [] (2 3 +) @attempt result.ok?
        \\exit: 0
        \\stdout:
        \\1
        \\stderr:
        \\<empty>
        \\=== result.or-raise ===
        \\source: [] (2 3 +) @attempt result.or-raise
        \\exit: 0
        \\stdout:
        \\[5]
        \\stderr:
        \\<empty>
        \\=== result.or-else ===
        \\source: [] (2 3 +) @attempt 9 result.or-else
        \\exit: 0
        \\stdout:
        \\[5]
        \\stderr:
        \\<empty>
        \\=== result.either ===
        \\source: [7] result.ok (first) (pop 0) result.either
        \\exit: 0
        \\stdout:
        \\7
        \\stderr:
        \\<empty>
        \\=== result.map-err ===
        \\source: {'kind 'io} result.err (pop {'kind 'domain}) result.map-err
        \\exit: 0
        \\stdout:
        \\{
        \\  'err {'kind 'domain}
        \\}
        \\stderr:
        \\<empty>
        \\=== bare or-raise ===
        \\source: [] (2 3 +) @attempt or-raise
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'undefined-word 'msg "undefined word `or-raise`" 'word 'or-raise 'trace ['or-raise] 'data {'name 'or-raise 'scope 'session 'source "<command>" 'line 1 'col 21}}
        \\=== bare ok? ===
        \\source: [] (2 3 +) @attempt ok?
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'undefined-word 'msg "undefined word `ok?`" 'word 'ok? 'trace ['ok?] 'data {'name 'ok? 'scope 'session 'source "<command>" 'line 1 'col 21}}
        \\=== gone result.case ===
        \\source: [7] result.ok (first) (pop 0) result.case
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'undefined-word 'msg "undefined word `result.case`" 'word 'result.case 'trace ['result.case] 'data {'name 'result.case 'scope 'qualified 'source "<command>" 'line 1 'col 31}}
        \\=== set ===
        \\source: 3 'x set x
        \\exit: 0
        \\stdout:
        \\3
        \\stderr:
        \\<empty>
        \\=== set quotation ===
        \\source: (dup *) 'q set q
        \\exit: 0
        \\stdout:
        \\(dup *)
        \\stderr:
        \\<empty>
        \\=== which ===
        \\source: 3 'x set 'x which
        \\exit: 0
        \\stdout:
        \\x -> x def public
        \\stderr:
        \\<empty>
        \\=== see ===
        \\source: 3 'x set 'x see
        \\exit: 0
        \\stdout:
        \\([3] first)
        \\stderr:
        \\<empty>
        \\=== see set ===
        \\source: 'set see
        \\exit: 0
        \\stdout:
        \\(:
        \\ "Bind a value as a constant word in the current scope; an optional annotation may precede the value.")
        \\(swap literal swap def)
        \\stderr:
        \\<empty>
        \\=== setp ===
        \\source: 1 'x setp
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "defp/setp are legal only in a module root" 'word 'defp 'trace ['defp 'setp] 'data {'source "prelude.ecl" 'line <^\d+$> 'col 20}}
        \\=== qualify execute ===
        \\source: [] ((41) 'f def) 'core.utils @defm 'core.utils 'f qualify execute
        \\exit: 0
        \\stdout:
        \\41
        \\stderr:
        \\<empty>
        \\=== execute type ===
        \\source: 1 execute
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'type 'msg "execute expected a word" 'word 'execute 'trace ['execute] 'data {'source "<command>" 'line 1 'col 3}}
        \\=== doc qualify ===
        \\source: 'qualify doc
        \\exit: 0
        \\stdout:
        \\"Construct an executable qualified word without reparsing source text."
        \\stderr:
        \\<empty>
        \\=== within top level ===
        \\source: (1) within
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "within is legal only in code homed in a module" 'word 'within 'trace ['within] 'data {'source "<command>" 'line 1 'col 5}}
        \\=== without top level ===
        \\source: without
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "without is legal only inside a within application" 'word 'without 'trace ['without] 'data {'source "<command>" 'line 1 'col 1}}
        \\=== see within ===
        \\source: 'within see
        \\exit: 0
        \\stdout:
        \\(quotation -- ... :
        \\ "Run a quotation against a private draft of the home module's durable stack and publish the result.")
        \\<primitive>
        \\stderr:
        \\<empty>
        \\=== doc without ===
        \\source: 'without doc
        \\exit: 0
        \\stdout:
        \\"Move the draft's top value onto the pending outputs a within application returns to its caller."
        \\stderr:
        \\<empty>
        \\=== unmodule unknown ===
        \\source: 'nowhere unmodule
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'undefined-word 'msg "undefined word `nowhere`" 'word 'nowhere 'trace ['nowhere] 'data {'name 'nowhere 'scope 'qualified 'source "<command>" 'line 1 'col 10}}
        \\=== unmodule then resolve ===
        \\source: [] ((1) 'x def) 'gone @defm 'gone unmodule gone.x
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'undefined-word 'msg "undefined word `gone.x`" 'word 'gone.x 'trace ['gone.x] 'data {'name 'gone.x 'scope 'qualified 'source "<command>" 'line 1 'col 44}}
        \\=== doc unmodule ===
        \\source: 'unmodule doc
        \\exit: 0
        \\stdout:
        \\"Close, quiesce, and retire a registered module named by a symbol."
        \\stderr:
        \\<empty>
        \\=== result ok ===
        \\source: [1 2] result.ok
        \\exit: 0
        \\stdout:
        \\{'ok [1 2]}
        \\stderr:
        \\<empty>
        \\=== result and-then ===
        \\source: [2 3] result.ok (+) result.and-then
        \\exit: 0
        \\stdout:
        \\{'ok [5]}
        \\stderr:
        \\<empty>
        \\=== result all ===
        \\source: [1] result.ok {'kind 'io} result.err 2 pack result.all
        \\exit: 0
        \\stdout:
        \\{
        \\  'err {'kind 'io}
        \\}
        \\stderr:
        \\<empty>
        \\=== result malformed ===
        \\source: {'ok 5} (missing) result.and-then
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'type 'msg "an ok result must carry a list of success values" 'word 'raise 'trace ['raise 'assert 'result.and-then] 'data {'source "prelude.ecl" 'line <^\d+$> 'col 14}}
        \\=== str upper ===
        \\source: "héllo" str.upper
        \\exit: 0
        \\stdout:
        \\"HéLLO"
        \\stderr:
        \\<empty>
        \\=== str index-of missing ===
        \\source: "abc" "z" str.index-of
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "str.index-of found no occurrence of the needle" 'word 'raise 'trace ['raise 'assert 'str.index-of] 'data {'source "prelude.ecl" 'line <^\d+$> 'col 14}}
        \\=== csv parse ===
        \\source: "a,,c
        \\d" csv.parse
        \\exit: 0
        \\stdout:
        \\(("a" () "c") ("d"))
        \\stderr:
        \\<empty>
        \\=== csv emit ===
        \\source: "a,b" csv.parse csv.emit
        \\exit: 0
        \\stdout:
        \\"a,b\u{d}\n"
        \\stderr:
        \\<empty>
        \\=== csv malformed ===
        \\source: "\"x" csv.parse
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'parse 'msg "csv.parse found malformed quoting at character 2" 'word 'csv.parse 'trace ['csv.parse] 'data {'source "<command>" 'line 1 'col 7}}
        \\=== json parse ===
        \\source: "{\"a\":[1,null,true]}" json.parse
        \\exit: 0
        \\stdout:
        \\{"a" (1 'null 'true)}
        \\stderr:
        \\<empty>
        \\=== json emit ===
        \\source: {'a 1} json.emit
        \\exit: 0
        \\stdout:
        \\"{\"a\":1}"
        \\stderr:
        \\<empty>
        \\=== json emit key ===
        \\source: {1 2} json.emit
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'type 'msg "json.emit requires string or symbol dictionary keys" 'word 'json.emit 'trace ['json.emit] 'data {'source "<command>" 'line 1 'col 7}}
        \\=== table rows ===
        \\source: {"a" [1 2] "b" ["x" "y"]} table.rows
        \\exit: 0
        \\stdout:
        \\((1 "x") (2 "y"))
        \\stderr:
        \\<empty>
        \\=== table where ===
        \\source: {"a" [1 2 3]} [1 0 1] table.where
        \\exit: 0
        \\stdout:
        \\{"a" [1 3]}
        \\stderr:
        \\<empty>
        \\=== table aggregate ===
        \\source: {"r" ["e" "w" "e"] "v" [1 2 3]} ["r"] [["t" "v" (sum)]] table.aggregate
        \\exit: 0
        \\stdout:
        \\{"r" ("e" "w") "t" [4 2]}
        \\stderr:
        \\<empty>
        \\=== table invalid ===
        \\source: {"a" [1 2] "b" [3]} table.rows
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'shape 'msg "table columns must share one length" 'word 'raise 'trace ['raise 'assert 'table.rows] 'data {'source "prelude.ecl" 'line <^\d+$> 'col 14}}
        \\=== getenv unset ===
        \\source: "ECL_SNAPSHOT_ABSENT" getenv
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'io 'msg "environment variable `ECL_SNAPSHOT_ABSENT` is not set" 'word 'getenv 'trace ['getenv] 'data {'name "ECL_SNAPSHOT_ABSENT" 'source "<command>" 'line 1 'col 23}}
        \\=== read-text missing ===
        \\source: 'cwd "no-such-file.ecl" fs.read-text
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'io 'msg "entry does not exist" 'word 'fs.read-text 'trace ['fs.read-text] 'data {'operation 'read-text 'root 'cwd 'path "no-such-file.ecl" 'reason 'not-found 'source "<command>" 'line 1 'col 25}}
        \\=== http dead port ===
        \\source: "http://127.0.0.1:1/x" {} http.get
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'io 'msg "cannot reach `http://127.0.0.1:1/x`: ConnectionRefused" 'word 'http.get 'trace ['http.get] 'data {'path "http://127.0.0.1:1/x" 'source "<command>" 'line 1 'col 27}}
        \\=== band ===
        \\source: [12 10] 6 band
        \\exit: 0
        \\stdout:
        \\[4 2]
        \\stderr:
        \\<empty>
        \\=== bor ===
        \\source: 12 10 bor
        \\exit: 0
        \\stdout:
        \\14
        \\stderr:
        \\<empty>
        \\=== bxor ===
        \\source: 12 10 bxor
        \\exit: 0
        \\stdout:
        \\6
        \\stderr:
        \\<empty>
        \\=== bsl ===
        \\source: [1 -8] 4 bsl
        \\exit: 0
        \\stdout:
        \\[16 -128]
        \\stderr:
        \\<empty>
        \\=== bsr ===
        \\source: -1 1 bsr
        \\exit: 0
        \\stdout:
        \\9223372036854775807
        \\stderr:
        \\<empty>
        \\=== bnot ===
        \\source: [0 5] bnot
        \\exit: 0
        \\stdout:
        \\[-1 -6]
        \\stderr:
        \\<empty>
        \\=== bsl overshift ===
        \\source: 1 64 bsl
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "a shift count must be from 0 to 63" 'word 'bsl 'trace ['bsl] 'data {'source "<command>" 'line 1 'col 6}}
        \\=== rand.int ===
        \\source: [7 0] 6 rand.int
        \\exit: 0
        \\stdout:
        \\[7 1] 3
        \\stderr:
        \\<empty>
        \\=== rand.ints ===
        \\source: [7 0] 4 6 rand.ints
        \\exit: 0
        \\stdout:
        \\[7 4] [3 0 0 3]
        \\stderr:
        \\<empty>
        \\=== rand.float ===
        \\source: [7 0] rand.float
        \\exit: 0
        \\stdout:
        \\[7 1] 0.3898297483912715
        \\stderr:
        \\<empty>
        \\=== rand.int empty range ===
        \\source: [7 0] 0 rand.int
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "rand.int expected a positive bound, not 0" 'word 'rand.int 'trace ['rand.int] 'data {'source "<command>" 'line 1 'col 9}}
        \\=== rng deal ===
        \\source: 'rng ('deal) import 3 10 deal
        \\exit: 0
        \\stdout:
        \\[5 0 7]
        \\stderr:
        \\<empty>
        \\=== isolated substack ===
        \\source: 3 [1] (+) @attempt
        \\exit: 0
        \\stdout:
        \\  {
        \\    'err {
        \\      'kind 'underflow
        \\      'msg "+ needs 2 stack values, but found 1; the substack is isolated from the caller's stack — pass initial values in the constructor's values operand: `values (q) @attempt`"
        \\      'word '+
        \\      'trace ['+]
        \\      'data {
        \\        'needed 2
        \\        'available 1
        \\        'isolation @attempt
        \\        'source "<command>"
        \\        'line 1
        \\        'col 8
        \\      }
        \\    }
        \\3 }
        \\stderr:
        \\<empty>
        \\=== isolated child ===
        \\source: 3 [1 2] [] (+ +) @each
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'underflow 'msg "+ needs 2 stack values, but found 1; the child unit's stack is isolated from the caller's stack — pass shared initial values in the constructor's values operand: `list values (q) @each`" 'word '+ 'trace ['+] 'data {'needed 2 'available 1 'isolation @each 'source "<command>" 'line 1 'col 13}}
        \\=== seeded attempt ===
        \\source: [3] (1 +) @attempt
        \\exit: 0
        \\stdout:
        \\{'ok [4]}
        \\stderr:
        \\<empty>
        \\=== seeded module ===
        \\source: [7] ('base set) 'm @defm m.base
        \\exit: 0
        \\stdout:
        \\7
        \\stderr:
        \\<empty>
        \\=== anonymous module ===
        \\source: [] () @module type
        \\exit: 0
        \\stdout:
        \\'module
        \\stderr:
        \\<empty>
        \\=== module identity ===
        \\source: [] (1) @module dup match? [] (1) @module [] (1) @module match?
        \\exit: 0
        \\stdout:
        \\1 0
        \\stderr:
        \\<empty>
        \\=== one image two registrations ===
        \\source: [] (0 ((1 + dup without) within) 'bump def) @module dup 'l register 'r register l.bump l.bump r.bump
        \\exit: 0
        \\stdout:
        \\1 2 1
        \\stderr:
        \\<empty>
        \\=== module marker is unreadable ===
        \\source: "<module>" parse
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'parse 'msg "module display markers are runtime-only and cannot be parsed" 'word 'parse 'trace ['parse] 'data {'source "<parse>" 'line 1 'col 1}}
        \\=== old spelling ===
        \\source: (1) attempt
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'undefined-word 'msg "undefined word `attempt`" 'word 'attempt 'trace ['attempt] 'data {'name 'attempt 'scope 'session 'source "<command>" 'line 1 'col 5}}
        \\=== row annotation ===
        \\source: (a -- ...) (dup) 'f def 'f see
        \\exit: 0
        \\stdout:
        \\(a -- ...) (dup)
        \\stderr:
        \\<empty>
        \\=== row after mixing ===
        \\source: (a -- ... b) (dup) 'f def
        \\exit: 1
        \\stdout:
        \\<empty>
        \\stderr:
        \\{'kind 'domain 'msg "malformed definition annotation" 'word 'def 'trace ['def] 'data {'source "<command>" 'line 1 'col 23}}
        \\
    ).diff(transcript.written(), true);
}
