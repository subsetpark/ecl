const std = @import("std");
const build_options = @import("oracle_options");

const allocator = std.testing.allocator;
const io = std.testing.io;

const Case = struct {
    word: []const u8,
    source: []const u8,
};

// Zig-only post-freeze vocabulary is intentionally outside this differential:
// cmp, flip, reshape, group, type, to-dict, exp, log, sin, cos, atan2, plus
// list put, count-vector where, and cycling take beyond the shared overlap.

const shared_words = [_][]const u8{
    "str",   "+",      "-",       "*",     "/",     "div",   "mod",
    "pow",   "min",    "max",     "=",     "<>",    "<",     ">",
    "<=",    ">=",     "and",     "or",    "neg",   "abs",   "sqrt",
    "floor", "ceil",   "round",   "not",   "len",   "shape", "first",
    "rest",  "take",   "drop",    "at",    "where", "in",    "find",
    "raze",  "cat",    "reverse", "range", "grade", "sort",  "distinct",
    "keys",  "vals",   "put",     "del",   "merge", "has?",  "split",
    "join",  "format",
};

const cases = [_]Case{
    .{ .word = "str", .source = "['a 1] str" },
    .{ .word = "+", .source = "[1 2] 3 +" },
    .{ .word = "-", .source = "\\c \\a -" },
    .{ .word = "*", .source = "[[1 2] [3]] 10 *" },
    .{ .word = "/", .source = "1 0 /" },
    .{ .word = "div", .source = "7 3 div" },
    .{ .word = "mod", .source = "7 3 mod" },
    .{ .word = "pow", .source = "2 3 pow" },
    .{ .word = "min", .source = "2 3.0 min" },
    .{ .word = "max", .source = "2 3.0 max" },
    .{ .word = "=", .source = "[1 2] [1 3] =" },
    .{ .word = "<>", .source = "[1 2] [1 3] <>" },
    .{ .word = "<", .source = "[1 2] 2 <" },
    .{ .word = ">", .source = "[1 2] 2 >" },
    .{ .word = "<=", .source = "[1 2] 2 <=" },
    .{ .word = ">=", .source = "[1 2] 2 >=" },
    .{ .word = "and", .source = "[0 1] 1 and" },
    .{ .word = "or", .source = "[0 1] 0 or" },
    .{ .word = "neg", .source = "[1 -2] neg" },
    .{ .word = "abs", .source = "[-1 2] abs" },
    .{ .word = "sqrt", .source = "[4 9] sqrt" },
    .{ .word = "floor", .source = "[1.9 -1.1] floor" },
    .{ .word = "ceil", .source = "[1.1 -1.9] ceil" },
    .{ .word = "round", .source = "[1.4 1.6] round" },
    .{ .word = "not", .source = "[0 1] not" },
    .{ .word = "len", .source = "\"aé\" len" },
    .{ .word = "shape", .source = "[[1 2] [3]] shape" },
    .{ .word = "first", .source = "\"ab\" first" },
    .{ .word = "rest", .source = "\"abc\" rest \"a\" rest" },
    .{ .word = "take", .source = "[1 2 3] -2 take \"abc\" 0 take" },
    .{ .word = "drop", .source = "[1 2 3] -1 drop \"a\" 1 drop" },
    .{ .word = "at", .source = "[10 20 30] [2 0] at" },
    .{ .word = "where", .source = "[1 0 1] where" },
    .{ .word = "in", .source = "[2 4] [1 2 3] in" },
    .{ .word = "find", .source = "[2 3 2] 3 find" },
    .{ .word = "raze", .source = "[[1 2] [3]] raze" },
    .{ .word = "cat", .source = "\"ab\" \"cd\" cat \"\" \"\" cat" },
    .{ .word = "reverse", .source = "\"abc\" reverse \"\" reverse" },
    .{ .word = "range", .source = "5 range" },
    .{ .word = "grade", .source = "[2 1 2 1] grade" },
    .{ .word = "sort", .source = "[2 1 2 1] sort" },
    .{ .word = "distinct", .source = "[2 1 2 1] distinct" },
    .{ .word = "keys", .source = "{'a 1 'b 2} keys" },
    .{ .word = "vals", .source = "{'a 1 'b 2} vals" },
    .{ .word = "put", .source = "{'a 1} 'b 2 put" },
    .{ .word = "del", .source = "{'a 1 'b 2} 'a del" },
    .{ .word = "merge", .source = "{'a 1 'b 2} {'b 20 'c 3} merge" },
    .{ .word = "has?", .source = "{\"ab\" 9} \"ab\" has? {[1 2] 9} [1 2] has?" },
    // The PoC has a representation-only String element kind that the real
    // unified-list model deliberately lacks; observe split through a member.
    .{ .word = "split", .source = "\"a—b—\" \"—\" split first" },
    .{ .word = "join", .source = "[\"a\" 2] \"-\" join" },
    .{ .word = "format", .source = "[3.14 2] \"pi={} n={}\" format" },
};

test "oracle: every shared M5 word has a differential case" {
    try std.testing.expectEqual(shared_words.len, cases.len);
    for (shared_words) |word| {
        var count: usize = 0;
        for (cases) |case| count += @intFromBool(std.mem.eql(u8, word, case.word));
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "oracle: Zig and Rust agree on shared M5 success and error semantics" {
    for (cases) |case| {
        const zig_result = try run(build_options.zig_exe, case.source);
        defer allocator.free(zig_result.stdout);
        defer allocator.free(zig_result.stderr);
        const rust_result = try run(build_options.rust_exe, case.source);
        defer allocator.free(rust_result.stdout);
        defer allocator.free(rust_result.stderr);
        const zig_exit = try exitCode(zig_result.term);
        const rust_exit = try exitCode(rust_result.term);
        if (zig_exit != rust_exit) {
            std.log.err(
                "oracle exit mismatch for {s}: Zig {d} ({s}), Rust {d} ({s})",
                .{ case.word, zig_exit, zig_result.stderr, rust_exit, rust_result.stderr },
            );
            return error.TestExpectedEqual;
        }
        if (zig_exit == 0) {
            if (!std.mem.eql(u8, zig_result.stdout, rust_result.stdout)) {
                std.log.err(
                    "oracle stdout mismatch for {s}: Zig {s}, Rust {s}",
                    .{ case.word, zig_result.stdout, rust_result.stdout },
                );
                return error.TestExpectedEqual;
            }
            try std.testing.expectEqualStrings("", zig_result.stderr);
            try std.testing.expectEqualStrings("", rust_result.stderr);
        } else {
            try expectSemanticError(case.word, zig_result.stderr, rust_result.stderr);
        }
    }
}

fn run(executable: []const u8, source: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{ .argv = &.{ executable, "-e", source } });
}

fn exitCode(term: std.process.Child.Term) !u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => error.UnexpectedTermination,
    };
}

fn expectSemanticError(word: []const u8, zig_stderr: []const u8, rust_stderr: []const u8) !void {
    const zig_kind = field(zig_stderr, "'kind '") orelse return missingField(word, "kind", zig_stderr);
    const rust_kind = field(rust_stderr, "'kind '") orelse return missingField(word, "kind", rust_stderr);
    try std.testing.expectEqualStrings(rust_kind, zig_kind);
    const zig_word = field(zig_stderr, "'word '");
    const rust_word = field(rust_stderr, "'word '");
    if (zig_word == null or rust_word == null) {
        if (zig_word != null or rust_word != null) return error.TestExpectedEqual;
    } else {
        try std.testing.expectEqualStrings(rust_word.?, zig_word.?);
    }
}

fn field(stderr: []const u8, marker: []const u8) ?[]const u8 {
    const marker_index = std.mem.indexOf(u8, stderr, marker) orelse return null;
    const start = marker_index + marker.len;
    var end = start;
    while (end < stderr.len and stderr[end] != ' ' and stderr[end] != '}' and
        stderr[end] != ']' and stderr[end] != '\n') : (end += 1)
    {}
    return stderr[start..end];
}

fn missingField(word: []const u8, name: []const u8, stderr: []const u8) anyerror {
    std.log.err("oracle {s} error lacks {s}: {s}", .{ word, name, stderr });
    return error.TestUnexpectedResult;
}
