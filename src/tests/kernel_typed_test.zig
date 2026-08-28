//! Proof surface for the monomorphic flat-leaf kernel migration (Step 14).
//!
//! Every test here is stubbed by the migration's first patch and implemented by
//! exactly one later patch, named in its `// PENDING: Patch N` comment. A stub
//! that outlives its named patch is an unfinished migration, not a passing
//! suite.
//!
//! These cases follow the `kernel_test_support.zig` conventions: whole-session
//! behavioral cases on the traceless `test_heap.SessionHeap`, source strings
//! only, no representation accessors and no inspection of implementation
//! source. Typed-versus-generic parity reaches the generic reference through
//! `list.fromValuesGeneric`, which builds a real generic-representation input
//! and so exercises production semantics rather than a second kernel.
const std = @import("std");
const kernels = @import("../kernels.zig");
const flat = @import("../kernel_flat.zig");
const session = @import("../session.zig");
const list = @import("../list.zig");
const printer = @import("../print.zig");
const value = @import("../value.zig");
const intern = @import("../intern.zig");

const allocator = std.testing.allocator;

/// Renders one case's whole observable outcome: the stack as printed, or the
/// error dict as printed. Comparing these strings compares values,
/// representations, brackets, string forms, float bits, error kinds, messages,
/// and failing indexes in one shot — which is exactly the parity clause 7 asks
/// for, without any accessor into the representation itself.
fn outcome(runtime: *session.Session, inputs: []const value.Value, source: []const u8) ![]u8 {
    for (inputs) |item| try runtime.pushOwned(item);
    const rendered = switch (try runtime.runUnit("<typed-kernel-test>", source)) {
        .ok => blk: {
            var display = try runtime.stackDisplay();
            defer display.deinit();
            break :blk try allocator.dupe(u8, display.bytes());
        },
        .err => |failure| blk: {
            defer runtime.release(failure);
            break :blk try printer.toOwnedString(allocator, failure);
        },
        .incomplete => return error.TestUnexpectedResult,
    };
    errdefer allocator.free(rendered);
    try clearStack(runtime);
    return rendered;
}

/// A failing unit rolls its stack back to entry state, which still holds the
/// pushed inputs, so every case ends by draining whatever is left.
fn clearStack(runtime: *session.Session) !void {
    while (runtime.stackItems().len != 0) {
        switch (try runtime.runUnit("<typed-kernel-cleanup>", "pop")) {
            .ok => {},
            .err => |failure| {
                runtime.release(failure);
                return error.TestUnexpectedResult;
            },
            .incomplete => return error.TestUnexpectedResult,
        }
    }
}

/// The same values reached two ways: as the specialized leaf a typed loop
/// dispatches on, and as a generic spine, which is the production generic route
/// clause 8 requires the reference to come from.
const Representation = enum { specialized, generic };

/// Values handed to a session must come from that session's allocator: its
/// release domain frees them. Every case therefore builds its inputs with the
/// same allocator the session was created on.
fn buildIntsOn(
    session_allocator: std.mem.Allocator,
    representation: Representation,
    numbers: []const i64,
) !value.Value {
    if (representation == .specialized) return list.fromI64Slice(session_allocator, numbers);
    var boxed = try allocator.alloc(value.Value, numbers.len);
    defer allocator.free(boxed);
    for (numbers, 0..) |number, index| boxed[index] = .{ .int = number };
    return list.fromValuesGeneric(session_allocator, boxed);
}

fn buildInts(representation: Representation, numbers: []const i64) !value.Value {
    return buildIntsOn(allocator, representation, numbers);
}

fn buildFloats(representation: Representation, numbers: []const f64) !value.Value {
    if (representation == .specialized) return list.fromF64Slice(allocator, numbers);
    var boxed = try allocator.alloc(value.Value, numbers.len);
    defer allocator.free(boxed);
    for (numbers, 0..) |number, index| boxed[index] = .{ .float = number };
    return list.fromValuesGeneric(allocator, boxed);
}

fn buildCodepoints(representation: Representation, codepoints: []const u32) !value.Value {
    if (representation == .specialized) return list.fromCodepoints(allocator, codepoints);
    var boxed = try allocator.alloc(value.Value, codepoints.len);
    defer allocator.free(boxed);
    for (codepoints, 0..) |codepoint, index| boxed[index] = .{ .char = @intCast(codepoint) };
    return list.fromValuesGeneric(allocator, boxed);
}

fn buildSymbols(representation: Representation, symbols: []const u32) !value.Value {
    if (representation == .specialized) return list.fromSymbolIds(allocator, symbols);
    var boxed = try allocator.alloc(value.Value, symbols.len);
    defer allocator.free(boxed);
    for (symbols, 0..) |symbol, index| boxed[index] = .{ .symbol = symbol };
    return list.fromValuesGeneric(allocator, boxed);
}

const Inputs = union(enum) {
    ints: []const i64,
    floats: []const f64,
    codepoints: []const u32,
    symbols: []const u32,
    int_pair: struct { left: []const i64, right: []const i64 },
    float_pair: struct { left: []const f64, right: []const f64 },
    mixed_pair: struct { left: []const i64, right: []const f64 },
    codepoint_pair: struct { left: []const u32, right: []const u32 },
    codepoint_int_pair: struct { left: []const u32, right: []const i64 },

    fn build(
        self: Inputs,
        runtime: *session.Session,
        representation: Representation,
        buffer: []value.Value,
    ) ![]const value.Value {
        switch (self) {
            .ints => |numbers| {
                buffer[0] = try buildInts(representation, numbers);
                return buffer[0..1];
            },
            .floats => |numbers| {
                buffer[0] = try buildFloats(representation, numbers);
                return buffer[0..1];
            },
            .codepoints => |codepoints| {
                buffer[0] = try buildCodepoints(representation, codepoints);
                return buffer[0..1];
            },
            .symbols => |symbols| {
                buffer[0] = try buildSymbols(representation, symbols);
                return buffer[0..1];
            },
            .int_pair => |pair| {
                buffer[0] = try buildInts(representation, pair.left);
                errdefer runtime.release(buffer[0]);
                buffer[1] = try buildInts(representation, pair.right);
                return buffer[0..2];
            },
            .float_pair => |pair| {
                buffer[0] = try buildFloats(representation, pair.left);
                errdefer runtime.release(buffer[0]);
                buffer[1] = try buildFloats(representation, pair.right);
                return buffer[0..2];
            },
            .mixed_pair => |pair| {
                buffer[0] = try buildInts(representation, pair.left);
                errdefer runtime.release(buffer[0]);
                buffer[1] = try buildFloats(representation, pair.right);
                return buffer[0..2];
            },
            .codepoint_pair => |pair| {
                buffer[0] = try buildCodepoints(representation, pair.left);
                errdefer runtime.release(buffer[0]);
                buffer[1] = try buildCodepoints(representation, pair.right);
                return buffer[0..2];
            },
            .codepoint_int_pair => |pair| {
                buffer[0] = try buildCodepoints(representation, pair.left);
                errdefer runtime.release(buffer[0]);
                buffer[1] = try buildInts(representation, pair.right);
                return buffer[0..2];
            },
        }
    }
};

/// An empty result keeps its operand's representation, and printing shows that
/// choice as brackets: an empty typed leaf renders `[]`, an empty spine `()`.
/// The two operands of a parity case are the same values in different
/// representations, so an empty result legitimately renders differently for a
/// reason that has nothing to do with which route ran. This collapses exactly
/// that one case — a whole rendered outcome that is nothing but an empty list —
/// and leaves every other difference failing.
fn normalizeEmpty(text: []const u8) []const u8 {
    if (std.mem.eql(u8, text, "[]") or std.mem.eql(u8, text, "()")) return "<empty list>";
    return text;
}

/// Runs one expression against both representations of the same values and
/// requires the rendered outcomes to be identical.
fn expectParity(runtime: *session.Session, inputs: Inputs, source: []const u8) !void {
    var buffer: [2]value.Value = undefined;
    const specialized = try inputs.build(runtime, .specialized, &buffer);
    const typed_text = try outcome(runtime, specialized, source);
    defer allocator.free(typed_text);
    const boxed = try inputs.build(runtime, .generic, &buffer);
    const generic_text = try outcome(runtime, boxed, source);
    defer allocator.free(generic_text);
    std.testing.expectEqualStrings(
        normalizeEmpty(generic_text),
        normalizeEmpty(typed_text),
    ) catch |err| {
        std.log.err("typed and generic routes disagree for `{s}`", .{source});
        return err;
    };
}

// Values, representations, exact error dicts with their failing index, and float
// bits, over every installed numeric, comparison, logical, and bitwise
// operation. The whole operation set runs at the small sizes; the sizes around
// the kernel quantum run on representative operations, because the generic
// reference route boxes every element and a full cross product at 65k elements
// would trade minutes of suite time for no additional distinct path.
test "typed differential: numeric logical and bitwise pervasion parity across sizes scalars mixed leaves and fault blocks" {
    // One session for the whole matrix, on `std.testing.allocator`: these cases
    // hand the session host-built values, so the session and the values must
    // share one allocator or the release domain frees across heaps. That is the
    // policy in `test_heap.zig`, and the reason this file does not use the
    // traceless session heap the source-only kernel suites use.
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    const small = [_]i64{ 7, -3, 2, 0, 5 };
    const singleton = [_]i64{4};
    const empty: [0]i64 = .{};
    const reals = [_]f64{ 1.5, -0.0, 2.25, 0.5, -3.75 };
    const right_ints = [_]i64{ 2, 3, -1, 4, 2 };
    const right_reals = [_]f64{ 2.0, 0.5, -1.25, 4.0, 2.5 };

    // Every binary word the numeric family installs or lends to the prelude,
    // spelled as it appears in source.
    const binary_words = [_][]const u8{
        "+",   "-",   "*",    "/",   "div",  "mod", "pow", "atan2",
        "min", "max", "=",    "<>",  "<",    ">",   "<=",  ">=",
        "and", "or",  "band", "bor", "bxor", "bsl", "bsr",
    };
    const unary_words = [_][]const u8{
        "neg", "abs", "sqrt", "floor", "ceil", "round", "exp", "log", "sin", "cos", "not", "bnot",
    };

    inline for (unary_words) |word| {
        try expectParity(&runtime, .{ .ints = &small }, word);
        try expectParity(&runtime, .{ .ints = &singleton }, word);
        try expectParity(&runtime, .{ .ints = &empty }, word);
        try expectParity(&runtime, .{ .floats = &reals }, word);
        // Reached through each, which is the recognized idiom over the same loop.
        try expectParity(&runtime, .{ .ints = &small }, "(" ++ word ++ ") each");
    }

    inline for (binary_words) |word| {
        // leaf x leaf, both representations of both operands.
        try expectParity(&runtime, .{ .int_pair = .{ .left = &small, .right = &right_ints } }, word);
        // Mixed numeric widths.
        try expectParity(&runtime, .{ .mixed_pair = .{ .left = &small, .right = &right_reals } }, word);
        // Scalar right and scalar left, with no materialized broadcast.
        try expectParity(&runtime, .{ .ints = &small }, "3 " ++ word);
        try expectParity(&runtime, .{ .ints = &small }, "3 swap " ++ word);
        // Length 1 and length 0.
        try expectParity(&runtime, .{ .ints = &singleton }, "3 " ++ word);
        try expectParity(&runtime, .{ .ints = &empty }, "3 " ++ word);
        // Self-aliased operands.
        try expectParity(&runtime, .{ .ints = &small }, "dup " ++ word);
        // Float leaves on both sides.
        try expectParity(&runtime, .{ .floats = &reals }, "1.5 " ++ word);
        // The recognized idioms over the same loop entries.
        try expectParity(&runtime, .{ .ints = &small }, "(3 " ++ word ++ ") each");
        try expectParity(&runtime, .{ .int_pair = .{ .left = &small, .right = &right_ints } }, "(" ++ word ++ ") zip-with");
    }

    // Ragged leaf encounters: a spine whose elements are leaves of different
    // lengths conforms elementwise or fails, identically on both routes.
    try expectParity(&runtime, .{ .ints = &small }, "[[1 2] [3]] swap 1 + pop 1 +");

    // Sizes around the kernel quantum, on representative operations.
    const boundary_sizes = [_]usize{
        flat.block_size - 1,
        flat.block_size,
        flat.block_size + 1,
        kernels.support.poll_quantum - 1,
        kernels.support.poll_quantum,
        kernels.support.poll_quantum + 1,
    };
    for (boundary_sizes) |size| {
        const numbers = try allocator.alloc(i64, size);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @intCast(index % 97);
        try expectParity(&runtime, .{ .ints = numbers }, "1 +");
        try expectParity(&runtime, .{ .ints = numbers }, "neg");
        try expectParity(&runtime, .{ .ints = numbers }, "dup <");
    }

    // Character-element pervasion has two typed result shapes: fixed i64 for
    // subtraction/comparison, and a profiling/fill pass for character results.
    // These cases force all source widths, both operand orders, width crossings
    // in both directions, and first-element rejection for invalid words.
    const ascii_chars = [_]u32{ 'a', 0xff, 'z' };
    const bmp_chars = [_]u32{ 0x100, 0x03bb, 0xffff };
    const astral_chars = [_]u32{ 0x10000, 0x1f642, 0x10fffe };
    for ([_]Inputs{
        .{ .codepoints = &ascii_chars },
        .{ .codepoints = &bmp_chars },
        .{ .codepoints = &astral_chars },
    }) |inputs| {
        try expectParity(&runtime, inputs, "1 +");
        try expectParity(&runtime, inputs, "1 swap +");
        try expectParity(&runtime, inputs, "1 -");
        try expectParity(&runtime, inputs, "\\a <");
        try expectParity(&runtime, inputs, "neg");
        try expectParity(&runtime, inputs, "1.0 +");
        try expectParity(&runtime, inputs, "(1 +) each");
    }
    try expectParity(&runtime, .{ .codepoints = &.{0xff} }, "1 +");
    try expectParity(&runtime, .{ .codepoints = &.{0x100} }, "1 -");
    try expectParity(&runtime, .{ .codepoints = &.{0xffff} }, "1 +");
    try expectParity(&runtime, .{ .codepoints = &.{0x10000} }, "1 -");
    try expectParity(&runtime, .{ .codepoint_pair = .{
        .left = &.{ 'a', 0x03bb, 0x1f642 },
        .right = &.{ 'b', 0x03b2, 0x1f600 },
    } }, "-");
    try expectParity(&runtime, .{ .codepoint_pair = .{
        .left = &.{ 'a', 0x03bb, 0x1f642 },
        .right = &.{ 'b', 0x03b2, 0x1f600 },
    } }, "<");
    try expectParity(&runtime, .{ .codepoint_pair = .{
        .left = &.{ 'a', 0x03bb, 0x1f642 },
        .right = &.{ 'b', 0x03b2, 0x1f600 },
    } }, "min");
    try expectParity(&runtime, .{ .codepoint_int_pair = .{
        .left = &.{ 0xff, 0xffff, 0x1f642 },
        .right = &.{ 1, 1, -1 },
    } }, "+");

    for ([_]usize{
        flat.block_size - 1,
        flat.block_size,
        flat.block_size + 1,
        kernels.support.poll_quantum - 1,
        kernels.support.poll_quantum,
        kernels.support.poll_quantum + 1,
    }) |size| {
        const codepoints = try allocator.alloc(u32, size);
        defer allocator.free(codepoints);
        for (codepoints, 0..) |*item, index| item.* = @intCast('a' + index % 20);
        try expectParity(&runtime, .{ .codepoints = codepoints }, "1 +");
        try expectParity(&runtime, .{ .codepoints = codepoints }, "\\m <");
    }
}

// The same parity discipline over the sequence operations that cross the typed
// seam: exact-size copies, the cyclic copy, the reversed copy, concatenation,
// the typed gather, and the index vector `where` builds. Operations whose
// registry row still reads generic are covered too — parity has to hold for the
// boxed route as well, and these cases are what will catch a later migration
// that changes an answer.
test "typed differential: sequence order text and random operation parity across sizes and representations" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    // Length zero is covered separately below: an empty leaf and an empty spine
    // are the same value with different printed brackets, and every operation
    // here preserves its operand's representation when the result is empty, so
    // the two inputs render differently for reasons that predate the migration.
    const sizes = [_]usize{ 1, 2, 3, flat.block_size - 1, flat.block_size, flat.block_size + 1 };
    const sources = [_][]const u8{
        // Exact-size and range copies.
        "reverse",
        "2 take",
        "-2 take",
        "7 take",
        "2 drop",
        "-2 drop",
        "rest",
        "dup cat",
        "dup 1 + cat",
        // Typed gather and the index vector `where` produces.
        "dup where at",
        "where",
        "dup len range at",
        "dup len wrap reshape",
        // Same-kind list put. `dup` forces the allocating copy path and keeps
        // the original live so copy-on-write is observable.
        "dup 0 9 put swap pop",
        // Still-generic neighbours, pinned so a later migration cannot drift.
        "dup in?",
        "distinct",
        "grade",
        "group dict.keys",
        "0 (+) fold",
        "raze",
        "len",
        "shape",
    };
    for (sizes) |size| {
        const numbers = try allocator.alloc(i64, size);
        defer allocator.free(numbers);
        // Repeats and zeroes on purpose: `where` needs counts, `distinct` and
        // `group` need collisions, and `at` needs in-range indices.
        for (numbers, 0..) |*item, index| item.* = @intCast(index % 3);
        for (sources) |source| {
            try expectParity(&runtime, .{ .ints = numbers }, source);
        }

        const reals = try allocator.alloc(f64, size);
        defer allocator.free(reals);
        for (reals, 0..) |*item, index| item.* = @as(f64, @floatFromInt(index % 3)) + 0.5;
        for ([_][]const u8{ "reverse", "2 take", "rest", "dup cat", "grade", "distinct" }) |source| {
            try expectParity(&runtime, .{ .floats = reals }, source);
        }
    }

    // Membership is a typed scan in both of its flat shapes: a scalar needle
    // is stride zero and a flat needle list writes an i64 mask directly. Every
    // leaf representation gets needle-in, needle-out, and list-needle parity;
    // the three character arrays force the char1/char2/char4 readers.
    const ascii = [_]u32{ 'a', 'b', 'a' };
    const bmp = [_]u32{ 0x03bb, 0x754c, 0x03bb };
    const astral = [_]u32{ 0x1f642, 0x1f680, 0x1f642 };
    const alpha = try intern.intern("membership-alpha");
    const beta = try intern.intern("membership-beta");
    const symbol_values = [_]u32{ alpha, beta, alpha };
    const membership_cases = [_]struct { inputs: Inputs, present: []const u8, absent: []const u8 }{
        .{ .inputs = .{ .ints = &.{ 1, 2, 1 } }, .present = "1 swap in?", .absent = "9 swap in?" },
        .{ .inputs = .{ .floats = &.{ 1.5, 2.5, 1.5 } }, .present = "1.5 swap in?", .absent = "9.5 swap in?" },
        .{ .inputs = .{ .codepoints = &ascii }, .present = "\\a swap in?", .absent = "\\z swap in?" },
        .{ .inputs = .{ .codepoints = &bmp }, .present = "\\λ swap in?", .absent = "\\β swap in?" },
        .{ .inputs = .{ .codepoints = &astral }, .present = "\\🙂 swap in?", .absent = "\\😀 swap in?" },
        .{ .inputs = .{ .symbols = &symbol_values }, .present = "'membership-alpha swap in?", .absent = "'membership-missing swap in?" },
    };
    for (membership_cases) |case| {
        try expectParity(&runtime, case.inputs, case.present);
        try expectParity(&runtime, case.inputs, case.absent);
        try expectParity(&runtime, case.inputs, "dup in?");
        try expectParity(&runtime, case.inputs, "5 wrap reshape");
        try expectParity(&runtime, case.inputs, "group dict.keys");
        try expectParity(&runtime, case.inputs, "distinct");
    }
    for ([_]Inputs{
        .{ .ints = &.{ 2, 1, 2 } },
        .{ .floats = &.{ 2.5, 1.5, 2.5 } },
        .{ .codepoints = &ascii },
        .{ .codepoints = &bmp },
        .{ .codepoints = &astral },
    }) |inputs| {
        try expectParity(&runtime, inputs, "grade");
        try expectParity(&runtime, inputs, "sort");
    }
    try expectParity(&runtime, .{ .symbols = &symbol_values }, "grade");

    // Same-width replacement crosses the typed put seam for every leaf kind.
    // The duplicated input forces a copy and leaves the original unchanged;
    // the non-duplicated integer case also reaches the unique-adoption store.
    try expectParity(&runtime, .{ .ints = &.{ 1, 2, 3 } }, "1 9 put");
    try expectParity(&runtime, .{ .ints = &.{ 1, 2, 3 } }, "dup 1 9 put swap pop");
    try expectParity(&runtime, .{ .floats = &.{ 1.5, 2.5, 3.5 } }, "dup 1 9.5 put swap pop");
    try expectParity(&runtime, .{ .codepoints = &ascii }, "dup 1 \\z put swap pop");
    try expectParity(&runtime, .{ .codepoints = &bmp }, "dup 1 \\β put swap pop");
    try expectParity(&runtime, .{ .codepoints = &astral }, "dup 1 \\😀 put swap pop");
    try expectParity(&runtime, .{ .symbols = &symbol_values }, "dup 1 'membership-missing put swap pop");
    // A changed value class or wider character deliberately returns to the
    // profiling path so the result can widen rather than corrupt a leaf.
    try expectParity(&runtime, .{ .ints = &.{ 1, 2, 3 } }, "1 9.5 put");
    try expectParity(&runtime, .{ .codepoints = &ascii }, "1 \\λ put");

    // Mixed numeric identity uses the exact shared rule in both directions;
    // it must not round the integer through f64.
    try expectParity(&runtime, .{ .ints = &.{ 1, 2, 3 } }, "2.0 swap in?");
    try expectParity(&runtime, .{ .floats = &.{ 1.0, 2.0, 3.0 } }, "2 swap in?");
    try expectParity(&runtime, .{ .ints = &.{9_007_199_254_740_993} }, "9007199254740992.0 swap in?");

    // The scalar scan crosses each kernel-quantum edge without an O(n^2)
    // list needle. Staging-block edges are already exercised by `dup in?` in
    // the size matrix above.
    for ([_]usize{
        kernels.support.poll_quantum - 1,
        kernels.support.poll_quantum,
        kernels.support.poll_quantum + 1,
    }) |size| {
        const numbers = try allocator.alloc(i64, size);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @intCast(index % 97);
        try expectParity(&runtime, .{ .ints = numbers }, "98 swap in?");
        try expectParity(&runtime, .{ .ints = numbers }, "dup 0 98 put swap pop");
        try expectParity(&runtime, .{ .ints = numbers }, "dup len wrap reshape");
        try expectParity(&runtime, .{ .ints = numbers }, "grade");

        @memset(numbers, 1);
        try expectParity(&runtime, .{ .ints = numbers }, "group dict.keys");
        try expectParity(&runtime, .{ .ints = numbers }, "distinct");
    }

    // Random draws are a known-width producer: seeded output must be identical
    // to the sequence this word has always produced, including the zero-length
    // case whose empty representation the value layer chose long ago.
    const draws = [_][]const u8{
        "[3 1] 5 6 rand.ints",
        "[3 1] 0 6 rand.ints",
        "[3 1] 1 2 rand.ints",
        "[7 9] 300 1000 rand.ints 0 (+) fold",
        "[7 9] 300 1000 rand.ints distinct len",
    };
    for (draws) |source| {
        const rendered = try outcome(&runtime, &.{}, source);
        defer allocator.free(rendered);
        try std.testing.expect(rendered.len != 0);
    }
    const seeded = try outcome(&runtime, &.{}, "[3 1] 5 6 rand.ints");
    defer allocator.free(seeded);
    try std.testing.expectEqualStrings("[3 6] [3 3 5 0 1]", seeded);

    // The empty case, stated rather than skipped: an empty result keeps its
    // operand's representation, so an empty typed leaf renders as `[]` and an
    // empty spine as `()`. Both routes agree about the value; the brackets
    // report which representation the operand had.
    const typed_empty = try buildInts(.specialized, &.{});
    const typed_text = try outcome(&runtime, &.{typed_empty}, "reverse");
    defer allocator.free(typed_text);
    try std.testing.expectEqualStrings("[]", typed_text);
    const boxed_empty = try buildInts(.generic, &.{});
    const boxed_text = try outcome(&runtime, &.{boxed_empty}, "reverse");
    defer allocator.free(boxed_text);
    try std.testing.expectEqualStrings("()", boxed_text);
}

// Two halves. The planner is exercised directly with budgets smaller than the
// input, which is the ceil(n / budget) claim in its purest form. The session
// half counts kernel safe points for a real operation of three quanta: chunked
// loops reach them a handful of times, while a per-element loop reaches one per
// element, so the bound below separates the two by four orders of magnitude
// rather than by a tuned constant.
test "typed kernels: a flat operation of length n needs at most ceil(n over budget) plus a constant number of advances" {
    for ([_]usize{ 1, 7, 64, 1000 }) |budget| {
        const length: usize = 10_000;
        var index: usize = 0;
        var advances: usize = 0;
        while (flat.planRange(index, length, budget, flat.block_size)) |plan| : (advances += 1) {
            try std.testing.expect(plan.len() != 0);
            try std.testing.expect(plan.len() <= @max(@min(budget, flat.block_size), 1));
            try std.testing.expectEqual(index, plan.start);
            index = plan.end;
        }
        const per_advance = @max(@min(budget, flat.block_size), 1);
        try std.testing.expectEqual((length + per_advance - 1) / per_advance, advances);
    }

    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;
    const length = quantum * 3;
    const numbers = try allocator.alloc(i64, length);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @intCast(index % 61);

    const bound = length / quantum + 8;
    const cases = [_][]const u8{
        // The direct word, the recognized each idiom, and the recognized
        // zip-with idiom all enter the same chunked loop.
        "1 +",
        "neg",
        "(1 +) each",
        "dup (+) zip-with",
    };
    for (cases) |source| {
        const input = try buildInts(.specialized, numbers);
        const rendered = try outcome(&runtime, &.{input}, source);
        defer allocator.free(rendered);
        std.testing.expect(runtime.lastPolls() <= bound) catch |err| {
            std.log.err(
                "`{s}` over {d} elements reached {d} kernel safe points; bounded work allows {d}",
                .{ source, length, runtime.lastPolls(), bound },
            );
            return err;
        };
    }
}

// A fault in the first, a middle, or the final block reports the first failing
// logical index with the scalar path's kind, message, and data — proven by
// comparing the whole rendered error dict against the generic route, and by
// pinning the index itself so a route that reported a block-local position
// would fail here rather than merely differ.
test "typed kernels: fault blocks report the first logical index and validate aliased blocks before stores" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    const length = flat.block_size * 3 + 5;
    const positions = [_]usize{ 0, 1, flat.block_size - 1, flat.block_size, flat.block_size + 7, length - 1 };
    for (positions) |position| {
        const numbers = try allocator.alloc(i64, length);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @intCast(index % 11);
        // One overflowing element, everything else well inside the domain.
        numbers[position] = std.math.maxInt(i64);

        try expectParity(&runtime, .{ .ints = numbers }, "1 +");
        try expectParity(&runtime, .{ .ints = numbers }, "neg pop 1 +");

        const input = try buildInts(.specialized, numbers);
        const rendered = try outcome(&runtime, &.{input}, "1 +");
        defer allocator.free(rendered);
        var expected_index: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&expected_index, "'index {d}", .{position});
        std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null) catch |err| {
            std.log.err("fault at {d} reported: {s}", .{ position, rendered });
            return err;
        };
        try std.testing.expect(std.mem.indexOf(u8, rendered, "'kind 'overflow") != null);
    }

    // A type fault: every element faults, and the first index is still the one
    // reported.
    const chars = try allocator.alloc(value.Value, 4);
    defer allocator.free(chars);
    for (chars, 0..) |*item, index| item.* = .{ .char = @intCast('a' + index) };
    const string = try list.fromValues(allocator, chars);
    const rendered = try outcome(&runtime, &.{string}, "1 band");
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'kind 'type") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'index 0") != null);
}

test "typed kernels: explicit vector cores preserve lanes tails broadcasts aliases and first faults" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    const length = flat.block_size * 2 + 3;
    const left = try allocator.alloc(i64, length);
    defer allocator.free(left);
    const right = try allocator.alloc(i64, length);
    defer allocator.free(right);
    const left_real = try allocator.alloc(f64, length);
    defer allocator.free(left_real);
    const right_real = try allocator.alloc(f64, length);
    defer allocator.free(right_real);
    for (left, right, left_real, right_real, 0..) |*a, *b, *af, *bf, index| {
        a.* = @as(i64, @intCast(index % 31)) - 15;
        b.* = 7 - @as(i64, @intCast(index % 19));
        af.* = @as(f64, @floatFromInt(a.*)) + 0.25;
        bf.* = @as(f64, @floatFromInt(b.*)) - 0.5;
    }

    // Full vectors plus a short tail, every operand shape, and every explicit
    // infallible vector family.
    inline for ([_][]const u8{ "=", "<>", "<", ">", "<=", ">=", "min", "max", "band", "bor", "bxor" }) |word| {
        try expectParity(&runtime, .{ .int_pair = .{ .left = left, .right = right } }, word);
        try expectParity(&runtime, .{ .ints = left }, "3 " ++ word);
        try expectParity(&runtime, .{ .ints = left }, "3 swap " ++ word);
    }
    try expectParity(&runtime, .{ .ints = left }, "bnot");
    inline for ([_][]const u8{ "=", "<>", "<", ">", "<=", ">=", "min", "max" }) |word| {
        try expectParity(&runtime, .{ .float_pair = .{ .left = left_real, .right = right_real } }, word);
        try expectParity(&runtime, .{ .floats = left_real }, "3.5 " ++ word);
        try expectParity(&runtime, .{ .floats = left_real }, "3.5 swap " ++ word);
    }

    // Selection must return the left operand on a tie, including the exact
    // sign bit of floating zero.
    try expectParity(&runtime, .{ .floats = &.{ -0.0, 0.0, -0.0 } }, "0.0 min");
    try expectParity(&runtime, .{ .floats = &.{ -0.0, 0.0, -0.0 } }, "0.0 max");

    // Checked vector arithmetic publishes no part of a faulted block. The
    // unique leaf/scalar shape aliases the output buffer, making corruption
    // observable when the generic replay compares the complete outcome.
    inline for ([_]struct { word: []const u8, dangerous: i64 }{
        .{ .word = "+", .dangerous = std.math.maxInt(i64) },
        .{ .word = "-", .dangerous = std.math.minInt(i64) },
        .{ .word = "*", .dangerous = std.math.maxInt(i64) },
    }) |case| {
        for ([_]usize{ 0, 1, flat.block_size - 1, flat.block_size, length - 1 }) |position| {
            @memset(left, 2);
            left[position] = case.dangerous;
            try expectParity(&runtime, .{ .ints = left }, "2 " ++ case.word);
        }
    }

    // NaN is not comparable in the scalar authority. A vector fault mask must
    // therefore replay and report the first NaN's logical index.
    @memset(left_real, 1.5);
    const nan_position = flat.block_size + 1;
    left_real[nan_position] = std.math.nan(f64);
    inline for ([_][]const u8{ "<", "min" }) |word| {
        try expectParity(&runtime, .{ .floats = left_real }, "2.0 " ++ word);
        const input = try buildFloats(.specialized, left_real);
        const rendered = try outcome(&runtime, &.{input}, "2.0 " ++ word);
        defer allocator.free(rendered);
        var expected_index: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&expected_index, "'index {d}", .{nan_position});
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "'kind 'type") != null);
    }
}

test "typed kernels: temporary bytes are bounded by output plus one kernel chunk under a DebugAllocator limit" {
    // The bound is enforced, not sampled: the session runs under a
    // `DebugAllocator` whose live-byte limit is the output buffer plus one
    // kernel chunk plus slack. An intermediate proportional to the input — the
    // sixteen bytes per boxed cell the old route staged, or a second profiling
    // pass over them — exceeds that limit and turns into a failed allocation.
    const Limited = std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = 0 });
    var limited: Limited = .init;
    defer if (limited.deinit() == .leak) std.debug.panic("memory-bound case leaked", .{});
    const limited_allocator = limited.allocator();

    var runtime = try session.Session.init(limited_allocator, &.{});
    defer runtime.deinit();

    const length: usize = 200_000;
    const element_bytes = @sizeOf(i64);
    const output_bytes = length * element_bytes;
    const chunk_bytes = kernels.support.poll_quantum * element_bytes;
    // Header objects, the parsed source, and the session's own bookkeeping ride
    // along, so the slack keeps the bound about the algorithm rather than about
    // allocator rounding.
    const slack: usize = 256 * 1024;

    const numbers = try limited_allocator.alloc(i64, length);
    defer limited_allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @intCast(index % 101);

    // `dup` keeps a second reference, so the result cannot take over the input
    // buffer: this is the allocating shape of the typed path, and the one whose
    // temporaries the bound is about.
    const cases = [_][]const u8{ "dup 1 + swap pop", "dup neg swap pop", "dup dup + swap pop" };
    for (cases) |source| {
        const input = try buildIntsOn(limited_allocator, .specialized, numbers);
        limited.requested_memory_limit = limited.total_requested_bytes + output_bytes + chunk_bytes + slack;
        const rendered = outcome(&runtime, &.{input}, source) catch |err| {
            limited.requested_memory_limit = std.math.maxInt(usize);
            std.log.err("`{s}` exceeded output plus one chunk: {s}", .{ source, @errorName(err) });
            return err;
        };
        defer allocator.free(rendered);
        limited.requested_memory_limit = std.math.maxInt(usize);
        // A failed allocation surfaces as an ecl error dict rather than a Zig
        // error, so the rendered outcome has to be the value, not a failure.
        std.testing.expect(std.mem.indexOf(u8, rendered, "'kind") == null) catch |err| {
            std.log.err("`{s}` failed under the bound: {s}", .{ source, rendered });
            return err;
        };
    }

    // The bound is tight rather than generous: half the output buffer is not
    // enough for a path that must materialize its result. A refused allocation
    // reaches the caller either as an ecl error dict or as the host allocation
    // error, depending on how far the machine got before the refusal; both
    // outcomes prove the limit bites, and neither is a success.
    const input = try buildIntsOn(limited_allocator, .specialized, numbers);
    limited.requested_memory_limit = limited.total_requested_bytes + output_bytes / 2;
    const starved = outcome(&runtime, &.{input}, "dup 1 + swap pop");
    limited.requested_memory_limit = std.math.maxInt(usize);
    if (starved) |text| {
        defer allocator.free(text);
        std.testing.expect(std.mem.indexOf(u8, text, "'kind") != null) catch |err| {
            std.log.err("a starved allocation still produced: {s}", .{text});
            return err;
        };
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
