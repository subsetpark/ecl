//! Explicit host scripting capabilities in `io`, plus global `getenv`.
//!
//! Every case drives a whole Session over source strings only, so the
//! traceless session heap is the right allocator (see `test_heap.zig`). The
//! host services these words need — an `std.Io`, an environment snapshot, a
//! standard-input mode — arrive through `session.Host`, not a test-only
//! accessor.
const std = @import("std");
const machine = @import("../machine.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;

const Case = struct {
    source: []const u8,
    environ: []const machine.Environ.Entry = &.{},
    standard_input: machine.StandardInput.Availability = .data,
};

/// One host-connected session for one case. Sessions are per-case so no
/// assertion depends on the residue of the previous one.
fn expectStack(case: Case, expected: []const u8) !void {
    return expectStackWithOutput(case, expected, null);
}

fn expectStackWithOutput(case: Case, expected: []const u8, expected_output: ?[]const u8) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .environ = case.environ,
        .standard_input = case.standard_input,
    });
    defer runtime.deinit();
    switch (try runtime.runUnit("<hostio-test>", case.source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.log.err("unexpected language error: {s}", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
    if (expected_output) |wanted| {
        try std.testing.expectEqualStrings(wanted, output.written());
    }
}

fn expectError(case: Case, expected: support.ErrorCase) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .environ = case.environ,
        .standard_input = case.standard_input,
    });
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<hostio-test>", case.source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

/// A temporary directory plus the source text that names files inside it.
const Scratch = struct {
    directory: std.testing.TmpDir,
    /// `realPathFileAlloc` returns a sentinel slice; keeping the sentinel in
    /// the field type is what makes the matching free the right size.
    path: [:0]u8,

    fn init() !Scratch {
        var directory = std.testing.tmpDir(.{});
        const path = directory.dir.realPathFileAlloc(std.testing.io, ".", allocator) catch |err| {
            directory.cleanup();
            return err;
        };
        return .{ .directory = directory, .path = path };
    }
    fn deinit(self: *Scratch) void {
        allocator.free(self.path);
        self.directory.cleanup();
    }
    fn write(self: *Scratch, name: []const u8, data: []const u8) !void {
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    }
    /// Renders `template` with each `{s}` replaced by a source-escaped path
    /// to `name` inside the scratch directory.
    fn source(self: *Scratch, comptime template: []const u8, name: []const u8) ![]u8 {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        for (self.path) |byte| {
            if (byte == '\\' or byte == '"') try joined.append(allocator, '\\');
            try joined.append(allocator, byte);
        }
        try joined.append(allocator, std.fs.path.sep);
        try joined.appendSlice(allocator, name);
        const placeholders = comptime std.mem.count(u8, template, "{s}");
        const arguments = .{joined.items} ** placeholders;
        return std.fmt.allocPrint(allocator, template, arguments);
    }
};

test "hostio: slurp reads a UTF-8 file" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("greeting.txt", "héllo\nworld\n");
    try scratch.write("raw.bin", "\xff\xfe");

    const read = try scratch.source("\"{s}\" io.slurp dup len swap", "greeting.txt");
    defer allocator.free(read);
    try expectStack(.{ .source = read }, "12 \"héllo\\nworld\\n\"");

    const empty = try scratch.source("\"{s}\" io.slurp", "empty.txt");
    defer allocator.free(empty);
    try scratch.write("empty.txt", "");
    try expectStack(.{ .source = empty }, "\"\"");

    const invalid = try scratch.source("\"{s}\" io.slurp", "raw.bin");
    defer allocator.free(invalid);
    try expectError(.{ .source = invalid }, .{
        .name = "invalid encoding",
        .source = invalid,
        .kind = "io",
        .word = "io.slurp",
        .message = "file is not valid UTF-8",
    });
}

test "hostio: slurp missing file is io with path data" {
    var scratch = try Scratch.init();
    defer scratch.deinit();

    const missing = try scratch.source("\"{s}\" io.slurp", "absent.txt");
    defer allocator.free(missing);
    try expectError(.{ .source = missing }, .{
        .name = "missing file",
        .source = missing,
        .kind = "io",
        .word = "io.slurp",
        .message_contains = "FileNotFound",
        .data = &.{.{ .name = "path", .expected = .{ .string = missing[1 .. missing.len - 10] } }},
    });

    try expectError(.{ .source = "42 io.slurp" }, .{
        .name = "non-string path",
        .source = "42 io.slurp",
        .kind = "type",
        .word = "io.slurp",
    });
}

test "hostio: spit writes and slurp round-trips" {
    var scratch = try Scratch.init();
    defer scratch.deinit();

    // Truncate-and-replace: the shorter second write leaves no tail behind.
    const round_trip = try scratch.source(
        "\"first\\ntext\" \"{s}\" io.spit \"{s}\" io.slurp \"2nd\" \"{s}\" io.spit \"{s}\" io.slurp",
        "out.txt",
    );
    defer allocator.free(round_trip);
    try expectStack(.{ .source = round_trip }, "\"first\\ntext\" \"2nd\"");

    const unwritable = try scratch.source("\"x\" \"{s}\" io.spit", "no-such-dir/out.txt");
    defer allocator.free(unwritable);
    try expectError(.{ .source = unwritable }, .{
        .name = "unwritable path",
        .source = unwritable,
        .kind = "io",
        .word = "io.spit",
        .message_contains = "cannot write",
    });

    try expectError(.{ .source = "42 \"p\" io.spit" }, .{
        .name = "non-string contents",
        .source = "42 \"p\" io.spit",
        .kind = "type",
        .word = "io.spit",
    });
    try expectError(.{ .source = "\"x\" 42 io.spit" }, .{
        .name = "non-string path",
        .source = "\"x\" 42 io.spit",
        .kind = "type",
        .word = "io.spit",
    });
}

test "hostio: getenv returns the snapshot value and unset is an error" {
    const environ: []const machine.Environ.Entry = &.{
        .{ .name = "ECL_TEST_ONE", .value = "first" },
        .{ .name = "ECL_TEST_TWO", .value = "" },
    };
    try expectStack(
        .{ .source = "\"ECL_TEST_ONE\" getenv \"ECL_TEST_TWO\" getenv", .environ = environ },
        "\"first\" \"\"",
    );
    try expectError(.{ .source = "\"ECL_TEST_ABSENT\" getenv", .environ = environ }, .{
        .name = "unset variable",
        .source = "\"ECL_TEST_ABSENT\" getenv",
        .kind = "io",
        .word = "getenv",
        .data = &.{.{ .name = "name", .expected = .{ .string = "ECL_TEST_ABSENT" } }},
    });
    // Absence is absence: defaulting is the caller's explicit idiom.
    try expectStack(.{
        .source = "(\"ECL_TEST_ABSENT\" getenv) @attempt \"fallback\" result.or-else",
        .environ = environ,
    }, "\"fallback\"");
    try expectError(.{ .source = "42 getenv", .environ = environ }, .{
        .name = "non-string name",
        .source = "42 getenv",
        .kind = "type",
        .word = "getenv",
    });
    // A session with no snapshot has no variables, not empty ones.
    try expectError(.{ .source = "\"ECL_TEST_ONE\" getenv" }, .{
        .name = "no snapshot",
        .source = "\"ECL_TEST_ONE\" getenv",
        .kind = "io",
        .word = "getenv",
    });
}

test "hostio: lines splits slurped text" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("rows.txt", "a\nbb\n\nccc");

    const split = try scratch.source("\"{s}\" io.lines", "rows.txt");
    defer allocator.free(split);
    try expectStack(.{ .source = split }, "(\"a\" \"bb\" \"\" \"ccc\")");

    const missing = try scratch.source("\"{s}\" io.lines", "absent.txt");
    defer allocator.free(missing);
    try expectError(.{ .source = missing }, .{
        .name = "lines propagates slurp failure",
        .source = missing,
        .kind = "io",
        .word = "io.slurp",
    });
}

test "hostio: stdin reads piped data and errors when stdin is the source" {
    // The mode gate is a Session capability, so it is observable without a
    // child process: a session whose stdin is the program source refuses the
    // read outright. `test/e2e.zig` covers the real piped-data case.
    try expectError(.{ .source = "io.stdin", .standard_input = .program_source }, .{
        .name = "stdin is the program source",
        .source = "io.stdin",
        .kind = "io",
        .word = "io.stdin",
        .message = "stdin is the program source",
    });
    // Reading the real stream needs a real pipe, so the piped-data case and
    // the once-only claim are proven against the binary in `test/e2e.zig`
    // rather than by making this suite depend on the test runner's stdin.
}

test "hostio: inspect preserves its value" {
    try expectStack(.{ .source = "7 io.inspect" }, "7");
}

test "hostio: debug prints a label and preserves its value" {
    try expectStackWithOutput(.{ .source = "[1 2] \"value\" io.debug" }, "[1 2]", "value: [1 2]\n");
}

test "hostio: stack prints the visible operand window without changing it" {
    try expectStackWithOutput(
        .{ .source = "1 [2 3] io.stack" },
        "1 [2 3]",
        "[0] 1\n[1] [2 3]\n",
    );
    try expectStackWithOutput(.{ .source = "io.stack" }, "", "");
    try expectStackWithOutput(
        .{ .source = "1 ((1 2) (3 4)) io.stack" },
        "  ([1 2]\n1  [3 4])",
        "[0] 1\n[1] ([1 2]\n     [3 4])\n",
    );
    try expectStackWithOutput(
        .{ .source = "{'type 'concat 'left {'type 'empty} 'right {'type 'epsilon}} io.stack" },
        "{\n  'type 'concat\n  'left {'type 'empty}\n  'right {'type 'epsilon}\n}",
        "[0] {\n      'type 'concat\n      'left {'type 'empty}\n      'right {'type 'epsilon}\n    }\n",
    );
    try expectStackWithOutput(
        .{ .source = "[3] 10 (io.stack +) fold" },
        "13",
        "[0] 10\n[1] 3\n",
    );
}
