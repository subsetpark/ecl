//! Proof surface for the monomorphic flat-leaf kernel migration (Step 14).
//!
//! Every test here is stubbed by the migration's first patch and implemented by
//! exactly one later patch, named in its `// PENDING: Patch N` comment. A stub
//! that outlives its named patch leaves the migration unfinished even when the
//! suite passes.
//!
//! These cases follow the `kernel_test_support.zig` conventions: whole-session
//! behavioral cases on the traceless `test_heap.SessionHeap`, source strings
//! only, no representation accessors and no inspection of implementation
//! source. Typed-versus-generic parity reaches the generic reference through
//! `list.fromValuesGeneric`, which builds a real generic-representation input
//! and so exercises production semantics rather than a second kernel.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const kernels = @import("../kernels.zig");
const flat = @import("../kernel_flat.zig");
const session = @import("../session.zig");
const list = @import("../list.zig");
const printer = @import("../print.zig");
const value = @import("../value.zig");
const intern = @import("../intern.zig");

const allocator = std.testing.allocator;

test "typed kernels: transitioning reduction seeds use bounded typed passes" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;
    for ([_]usize{ quantum - 1, quantum, quantum + 1, quantum * 2 + 1 }) |length| {
        const numbers = try allocator.alloc(f64, length);
        defer allocator.free(numbers);
        @memset(numbers, 1.0);
        for ([_][]const u8{ "sum", "0 (+) fold", "0 (+) scan last" }) |source| {
            try runtime.pushOwned(try list.fromF64Slice(allocator, numbers));
            switch (try runtime.runUnit("<transitioning-reduction>", source)) {
                .ok => {},
                .err => |failure| {
                    runtime.release(failure);
                    return error.TestUnexpectedResult;
                },
                .incomplete => return error.TestUnexpectedResult,
            }
            const items = runtime.stackItems();
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expect(items[0] == .float);
            try std.testing.expectEqual(@as(f64, @floatFromInt(length)), items[0].float);
            // Observe before cleanup starts another Unit. The lower bound
            // protects polling; the upper bound catches generic per-element
            // dispatch even though it computes the same answer.
            const polls = runtime.lastPolls();
            try std.testing.expect(polls >= length / quantum);
            try std.testing.expect(polls <= length / quantum + 16);
            try clearStack(&runtime);
        }
    }
    try expectFaultRetainsInput(&runtime, try buildFloats(.specialized, &.{std.math.inf(f64)}), "0 (*) scan");
    try expectFaultRetainsInput(&runtime, try buildFloats(.specialized, &.{ std.math.inf(f64), -std.math.inf(f64) }), "0 (+) scan");
}

test "typed kernels: block-checked float reductions report the scalar route's fault" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const inf = std.math.inf(f64);
    // Each placement lands a fault or a legitimate infinity in a different
    // block: the first, a middle one, and the last element.
    const Plant = struct { values: []const f64 };
    const plants = [_]Plant{
        .{ .values = &.{ 1.0e308, 1.0e308 } },
        .{ .values = &.{inf} },
        .{ .values = &.{ inf, -inf } },
        .{ .values = &.{ 0.0, inf } },
        .{ .values = &.{ 1.0e200, 1.0e200 } },
    };
    const length = 1500;
    var numbers: [length]f64 = undefined;
    for (plants) |plant| for ([_]usize{ 0, 700, length - plant.values.len }) |at| {
        for (&numbers, 0..) |*number, index| number.* = 0.25 + @as(f64, @floatFromInt(index % 7));
        @memcpy(numbers[at..][0..plant.values.len], plant.values);
        for ([_][]const u8{ "0.0 (+) fold", "(+) fold1", "0.0 (-) fold", "1.0 (*) fold", "0.0 (+) scan", "0.0 (-) scan" }) |source|
            try expectParity(&runtime, .{ .floats = &numbers }, source);
    };
}

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

/// A checked fault leaves a value the caller still holds exactly as it was. Such
/// a value is shared, so it is never adopted as an output: only a solely owned
/// intermediate is written in place, and a fault releases it.
fn expectFaultRetainsInput(runtime: *session.Session, input: value.Value, source: []const u8) !void {
    const expected_stack = try printer.toOwnedString(allocator, input);
    defer allocator.free(expected_stack);

    try runtime.pushOwned(input);
    switch (try runtime.runUnit("<typed-kernel-rollback-test>", source)) {
        .ok, .incomplete => return error.TestUnexpectedResult,
        .err => |failure| runtime.release(failure),
    }

    const retained = runtime.stackItems();
    try std.testing.expectEqual(@as(usize, 1), retained.len);
    const actual_stack = try printer.toOwnedString(allocator, retained[0]);
    defer allocator.free(actual_stack);
    try std.testing.expectEqualStrings(expected_stack, actual_stack);
    try clearStack(runtime);
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

fn buildBytes(representation: Representation, numbers: []const u8) !value.Value {
    if (representation == .specialized) return list.fromU8Slice(allocator, numbers);
    var boxed = try allocator.alloc(value.Value, numbers.len);
    defer allocator.free(boxed);
    for (numbers, 0..) |number, index| boxed[index] = .{ .int = number };
    return list.fromValuesGeneric(allocator, boxed);
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

// A symbol list has one representation, the generic spine, so both
// representations build the same list.
fn buildSymbols(representation: Representation, symbols: []const u32) !value.Value {
    _ = representation;
    var boxed = try allocator.alloc(value.Value, symbols.len);
    defer allocator.free(boxed);
    for (symbols, 0..) |symbol, index| boxed[index] = .{ .symbol = .{ .name = symbol } };
    return list.fromValuesGeneric(allocator, boxed);
}

const Inputs = union(enum) {
    ints: []const i64,
    bytes: []const u8,
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
            .bytes => |numbers| {
                buffer[0] = try buildBytes(representation, numbers);
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
        "and", "or",  "band", "bor", "bxor", "bsl", "bsr", "+%",
        "-%",  "*%",
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
        // Typed rows of a spine run inside the list frame; a row longer than
        // the quantum must suspend there and resume through the frame stack.
        try expectParity(&runtime, .{ .ints = numbers }, "dup pair 1 +");
        try expectParity(&runtime, .{ .ints = numbers }, "dup pair neg");
    }

    // Character elements are their codepoints to every typed loop, and no
    // result is a char. These cases force all source widths and both
    // operand orders, against the generic route.
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
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
        "first-where",
        "dup len range at",
        "dup len wrap reshape",
        // Rank-two reshape: typed rows, cycling, and columns that span a block.
        "[3 5] reshape",
        "[2 7] reshape",
        "2 over len pair reshape",
        "dup len 1 pair reshape",
        // Transposing rows of one representation, including rows spanning a block.
        "[3 5] reshape flip",
        "2 over len pair reshape flip",
        "dup len 1 pair reshape flip",
        // Pieces of a leaf. Starts that leave no piece empty: an empty piece keeps
        // its operand's representation, which prints differently (see above).
        "0 wrap cut",
        "dup len 1 - wrap cut",
        "3 chunk",
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
        .{ .inputs = .{ .symbols = &symbol_values }, .present = "`membership-alpha swap in?", .absent = "`membership-missing swap in?" },
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
    try expectParity(&runtime, .{ .symbols = &symbol_values }, "dup 1 `membership-missing put swap pop");
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

    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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

// Typed copies write each granted range straight into the result, so a range
// that ends mid-shape — inside the left operand of a concatenation, partway
// round a cycle, or across a gather block holding a bad index — must resume
// exactly where the previous step stopped.
test "typed kernels: copy shapes resume across budget boundaries and report the first bad gather index" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    for ([_]usize{ quantum - 1, quantum + 1, quantum * 2 + 3 }) |length| {
        const numbers = try allocator.alloc(i64, length);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @intCast(index * 7 + 1000);
        for ([_][]const u8{
            "dup cat 0 (+) fold",
            "dup 3 take swap cat 0 (+) fold",
            "dup 3 take cat 0 (+) fold",
            "reverse 0 (+) fold",
            "dup len 3 * 1 + take 0 (+) fold",
            "5 drop -70000 take 0 (+) fold",
            "dup len range reverse at 0 (+) fold",
            "dup len range dup len 1 - -1 put at",
            "dup len range dup 300 over len put at",
            "dup len range dup 1 -1 put dup len 1 - over len put at",
        }) |source| {
            try expectParity(&runtime, .{ .ints = numbers }, source);
        }
    }
}

// `raze` copies same-class leaf children straight into a typed result, widening
// narrower children, and keeps the profiled route for everything else; a child
// longer than one step's budget resumes inside the child.
test "typed kernels: raze of leaf children matches the profiled route across classes and budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    for ([_]usize{ 3, quantum + 1 }) |length| {
        const numbers = try allocator.alloc(i64, length);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @intCast(index * 7 + 1000);
        for ([_][]const u8{
            "dup reverse pair raze 0 (+) fold",
            "dup 3 take swap pair raze 0 (+) fold",
            "[1 2] swap pair raze 0 (+) fold",
            "dup 0 take pair raze",
            "dup 2.5 + pair raze 0 (+) fold",
            "3 take 1 pair raze",
        }) |source| {
            try expectParity(&runtime, .{ .ints = numbers }, source);
        }
    }
    const ascii = [_]u32{ 'a', 'b', 'a' };
    try expectParity(&runtime, .{ .codepoints = &ascii }, "\"λ🙂\" pair raze");
    try expectParity(&runtime, .{ .codepoints = &ascii }, "dup pair raze");
    try expectParity(&runtime, .{ .floats = &.{ 1.5, 2.5 } }, "dup pair raze");
}

// `distinct` hashes in one pass under the leaf's own equality: first
// occurrences in input order, zeros of either sign meeting at the first one
// seen, and a pass longer than one step's budget resuming mid-table.
test "typed kernels: hashed distinct keeps first occurrences under leaf equality across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    // The generic reference compares pairwise, so the long input keeps few
    // distinct values and the many-valued input stays short.
    const length = quantum * 2 + 5;
    const numbers = try allocator.alloc(i64, length);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @as(i64, @intCast((index * 7919) % 301)) - 150;
    try expectParity(&runtime, .{ .ints = numbers }, "distinct");
    for (numbers[0..5000], 0..) |*item, index| item.* = @intCast((index * 7919) % 5003);
    try expectParity(&runtime, .{ .ints = numbers[0..5000] }, "distinct");
    try expectParity(&runtime, .{ .floats = &.{ 1.5, -0.0, 0.0, 1.5, 2.5, 0.0 } }, "distinct");
    try expectParity(&runtime, .{ .floats = &.{ 0.0, -0.0 } }, "distinct");
}

// Typed `grade` sorts (key, position) pairs: insertion-sorted runs, then merge
// passes that resume mid-merge across budget boundaries. Heavy duplicates
// make stability observable in the permutation itself.
test "typed kernels: grade and sort keep the stable permutation across runs merges and budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    for ([_]usize{ 15, 16, 17, 33, quantum * 2 + 3 }) |length| {
        const numbers = try allocator.alloc(i64, length);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @as(i64, @intCast((index * 7919) % 1009)) - 500;
        try expectParity(&runtime, .{ .ints = numbers }, "grade dup len range * 0 (+) fold");
        try expectParity(&runtime, .{ .ints = numbers }, "sort 1 drop 0 (+) fold");
        try expectParity(&runtime, .{ .ints = numbers }, "reverse grade 25 take");
    }
    try expectParity(&runtime, .{ .floats = &.{ 0.0, -0.0, 0.0, -1.5, -0.0 } }, "grade");
    try expectParity(&runtime, .{ .floats = &.{ 0.0, -0.0, 0.0, -1.5, -0.0 } }, "sort");
}

// A recognized `each` or `zip-with` over a boxed spine arms one cursor per
// element and runs elements until the step's budget is spent, so a spine
// longer than the budget resumes between elements and inside a nested row.
test "typed kernels: recognized each over a boxed spine resumes between elements across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const numbers = try allocator.alloc(i64, quantum * 2 + 3);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @intCast(index % 1000);
    for ([_][]const u8{
        "(1 +) each 0 (+) fold",
        "(neg) each 0 (+) fold",
        "(2 swap -) each 0 (+) fold",
        "dup (*) zip-with 0 (+) fold",
        "dup len 1 - 9223372036854775807 put (1 +) each",
        "(pop [1 2]) each (1 +) each raze 0 (+) fold",
    }) |source| {
        try expectParity(&runtime, .{ .ints = numbers }, source);
    }
}

// Leaf-needle membership tables the distinct needles, scans the haystack once
// (stopping when every needle is found), and writes the mask from the table.
// Each phase crosses a budget boundary here; the reference route compares
// pairwise, so one side of each case stays short.
test "typed kernels: tabled membership matches the pairwise route across numeric classes and budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const numbers = try allocator.alloc(i64, quantum * 2 + 3);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @as(i64, @intCast((index * 7919) % 101)) - 50;
    for ([_][]const u8{
        "[3 -7 200 3] in? 0 (+) fold",
        "[3.0 -7.5 0.0] in? 0 (+) fold",
        "dup 25 take 1 + swap in?",
    }) |source| {
        try expectParity(&runtime, .{ .ints = numbers }, source);
    }
    for (numbers, 0..) |*item, index| item.* = @intCast(index);
    try expectParity(&runtime, .{ .ints = numbers }, "[5 70000 140000 131074] swap in?");
    try expectParity(&runtime, .{ .ints = numbers }, "[0 1 2] swap in?");
    try expectParity(&runtime, .{ .floats = &.{ -0.0, 2.0, 2.5 } }, "[0 2 3] in?");
    try expectParity(&runtime, .{ .floats = &.{ -0.0, 2.0, 2.5 } }, "[0 2 3] swap in?");
}

// A typed leaf groups by its elements' match keys in one bulk pass; offsets,
// cursors, and the scatter run in granted ranges for every input. Both cross
// a budget boundary here, with many groups and with zeros of either sign.
test "typed kernels: typed group matches the boxed route across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const numbers = try allocator.alloc(i64, quantum * 2 + 3);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @as(i64, @intCast((index * 7919) % 70001)) - 35000;
    try expectParity(&runtime, .{ .ints = numbers }, "group dict.size");
    try expectParity(&runtime, .{ .ints = numbers }, "group dict.vals (len) each 0 (+) fold");
    try expectParity(&runtime, .{ .ints = numbers }, "group dict.keys 40 take");
    try expectParity(&runtime, .{ .ints = numbers }, "group 3 at");
    try expectParity(&runtime, .{ .floats = &.{ 0.0, -0.0, 1.5, 0.0, -0.0 } }, "group");
}

// `reduce-groups` over typed numeric values and typed index groups reduces in
// granted runs. A group longer than one step's budget resumes mid-group, and a
// bad index after an overflowing element still reports the overflow first.
test "typed kernels: typed reduce-groups matches the boxed route across budget boundaries and fault order" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const numbers = try allocator.alloc(i64, quantum * 2 + 3);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @as(i64, @intCast((index * 7919) % 1001)) - 500;
    for ([_][]const u8{
        "dup 7 mod group dict.vals `sum reduce-groups",
        "dup 7 mod group dict.vals `count reduce-groups",
        "dup 7 mod group dict.vals `min reduce-groups",
        "dup 7 mod group dict.vals `max reduce-groups",
        "dup len range 1 wrap `sum reduce-groups",
        "dup len range 5 + 1 wrap `count reduce-groups",
    }) |source| {
        try expectParity(&runtime, .{ .ints = numbers }, source);
    }
    try expectParity(&runtime, .{ .ints = &.{ 9223372036854775807, 1 } }, "[[0 1 5]] `sum reduce-groups");
    try expectParity(&runtime, .{ .ints = &.{ 9223372036854775807, 1 } }, "[[0 5 1]] `sum reduce-groups");
    try expectParity(&runtime, .{ .floats = &.{ 0.0, -0.0, 2.5 } }, "[[0 1] [1 0] [2 2]] `min reduce-groups");
    try expectParity(&runtime, .{ .floats = &.{ 0.0, -0.0, 2.5 } }, "[[0 1 2] []] `sum reduce-groups");
}

// Typed `del` marks a mask from a typed index leaf, checking each granted run
// of indices at once, and compacts the kept elements; one scalar position
// copies the two slices around it. Both cross a budget boundary here.
test "typed kernels: typed del matches the boxed route across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const numbers = try allocator.alloc(i64, quantum * 2 + 3);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @intCast(index * 7 + 1000);
    for ([_][]const u8{
        "dup len 2 / floor range 2 * del 0 (+) fold",
        "dup len 1 - del 0 (+) fold",
        "70000 del 0 (+) fold",
        "0 del 0 (+) fold",
        "dup len range dup reverse cat del len",
        "[5 5 70000 3] del 0 (+) fold",
        "dup len range dup len 1 - -1 put del",
        "dup len range dup 1 over len put del",
    }) |source| {
        try expectParity(&runtime, .{ .ints = numbers }, source);
    }
}

// A typed stencil input copies each window's slice into a window of its own
// representation in granted runs, so a window wider than one step's budget
// resumes mid-window.
test "typed kernels: typed stencil windows match the profiled route across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const numbers = try allocator.alloc(i64, quantum + 5);
    defer allocator.free(numbers);
    for (numbers, 0..) |*item, index| item.* = @intCast(index * 7 + 1000);
    try expectParity(&runtime, .{ .ints = numbers }, "65537 (sum) stencil");
    try expectParity(&runtime, .{ .ints = numbers }, "65540 (dup len swap last pair) stencil");
    try expectParity(&runtime, .{ .ints = numbers[0..9] }, "3 () stencil");
    try expectParity(&runtime, .{ .floats = &.{ 1.5, -0.0, 2.5 } }, "2 () stencil");
}

// `split` searches a granted run of start positions per transition, sized by
// the separator's length, so a long text with sparse or long separators
// resumes mid-search; leftmost non-overlapping matches are unchanged.
test "typed kernels: split finds leftmost separators across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // Expected outputs are the per-codepoint scan's, recorded before the
    // search changed; split has no boxed route to compare against.
    for ([_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "\"x\" 70000 str.repeat \",\" cat \"y\" 70000 str.repeat cat \",\" split (len) each", .expected = "[70000 70000]" },
        .{ .source = "\"ab\" 40000 str.repeat \"abx\" cat dup cat \"abx\" split (len) each", .expected = "[80000 80000 0]" },
        .{ .source = "\"aaa\" 30000 str.repeat \"aa\" split len", .expected = "45001" },
        .{ .source = "\"λ,\" 40000 str.repeat \",\" split len", .expected = "40001" },
        .{ .source = "\"x\" 70000 str.repeat \"x\" 69000 str.repeat split (len) each", .expected = "[0 1000]" },
    }) |case| {
        const rendered = try outcome(&runtime, &.{}, case.source);
        defer allocator.free(rendered);
        std.testing.expectEqualStrings(case.expected, std.mem.trimEnd(u8, rendered, "\n")) catch |err| {
            std.log.err("split case `{s}`", .{case.source});
            return err;
        };
        try clearStack(&runtime);
    }
}

// `where` validates typed counts a block at a time and rescans only a failing
// block, so a bad count in the first, a middle, or the last block — or past a
// budget boundary — must report the generic route's kind, message, and index.
// Runs longer than one step's budget resume inside the run, and a long mask
// stays within bounded safe points.
test "typed kernels: where reports the first bad count and resumes runs across budget boundaries" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const length = quantum + flat.block_size + 3;
    const numbers = try allocator.alloc(i64, length);
    defer allocator.free(numbers);
    for ([_]usize{ 0, flat.block_size - 1, flat.block_size, flat.block_size + 1, quantum - 1, quantum, length - 1 }) |bad| {
        for (numbers, 0..) |*item, index| item.* = @intCast(index % 2);
        numbers[bad] = -1;
        try expectParity(&runtime, .{ .ints = numbers }, "where len");
        // A count too large to sum in a block takes the exact rescan, which
        // still reaches the negative count after it.
        if (bad == 0) continue;
        numbers[bad / 2] = std.math.maxInt(i64);
        try expectParity(&runtime, .{ .ints = numbers }, "where len");
    }

    for ([_][]const i64{
        &.{ 0, quantum * 2 + 5, 1 },
        &.{ quantum - 1, 0, 0, 2, quantum + 1 },
        &.{ 1, 0, 0, 0 },
        &.{ 0, 0, 0 },
    }) |counts| {
        try expectParity(&runtime, .{ .ints = counts }, "where");
    }

    for (numbers, 0..) |*item, index| item.* = @intCast(index % 3 % 2);
    const input = try buildInts(.specialized, numbers);
    const rendered = try outcome(&runtime, &.{input}, "where len");
    defer allocator.free(rendered);
    try std.testing.expect(runtime.lastPolls() <= 2 * length / quantum + 8);
}

// A mask of byte or int counts fills without testing for repetition, a vector
// group and a short tail at a time, and stops once the result is full, so
// trailing zeros past a budget boundary are never read. A count above one in
// the last block leaves the mask fill for the general one.
test "typed kernels: where fills byte and int masks across budgets" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    const length = quantum * 2 + flat.block_size + 5;
    const ints = try allocator.alloc(i64, length);
    defer allocator.free(ints);
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    for ([_]struct { modulus: usize, last_ones: usize }{
        .{ .modulus = 2, .last_ones = length },
        .{ .modulus = 3, .last_ones = length },
        .{ .modulus = 7, .last_ones = quantum + 1 },
        .{ .modulus = 1, .last_ones = 0 },
    }) |shape| {
        for (ints, bytes, 0..) |*int, *byte, index| {
            const one = shape.modulus != 1 and index < shape.last_ones and index % shape.modulus == 0;
            int.* = @intFromBool(one);
            byte.* = @intFromBool(one);
        }
        for ([_][]const u8{ "where", "where len", "where reverse 3 take" }) |source| {
            try expectParity(&runtime, .{ .ints = ints }, source);
            try expectParity(&runtime, .{ .bytes = bytes }, source);
        }
    }
    ints[length - 1] = 3;
    bytes[length - 1] = 3;
    try expectParity(&runtime, .{ .ints = ints }, "where len");
    try expectParity(&runtime, .{ .bytes = bytes }, "where len");
    for ([_]usize{ 0, flat.block_size - 1, quantum, length - 1 }) |bad| {
        @memset(ints, 1);
        ints[bad] = -2;
        try expectParity(&runtime, .{ .ints = ints }, "where len");
    }
}

// `not`, `and`, and `or` run vector lanes whose fault mask is the scalar
// `boolean` test, so a count outside 0 and 1 in a full vector, a tail, or a
// later block reports the scalar route's index, fresh or adopted.
test "typed kernels: boolean vectors fault where the scalar route does" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    const length = flat.block_size * 2 + 3;
    const left = try allocator.alloc(i64, length);
    defer allocator.free(left);
    const right = try allocator.alloc(i64, length);
    defer allocator.free(right);
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    for ([_]?usize{ null, 0, 5, flat.block_size, length - 1 }) |bad| {
        for (left, right, bytes, 0..) |*a, *b, *byte, index| {
            a.* = @intCast(index % 2);
            b.* = @intCast(index / 3 % 2);
            byte.* = @intCast(index % 3 % 2);
        }
        if (bad) |position| {
            left[position] = if (position % 2 == 0) -1 else 2;
            bytes[position] = 2;
        }
        try expectParity(&runtime, .{ .ints = left }, "not");
        try expectParity(&runtime, .{ .ints = left }, "not 0 (+) fold");
        try expectParity(&runtime, .{ .bytes = bytes }, "not");
        inline for ([_][]const u8{ "and", "or" }) |word| {
            try expectParity(&runtime, .{ .int_pair = .{ .left = left, .right = right } }, word);
            try expectParity(&runtime, .{ .int_pair = .{ .left = right, .right = left } }, word);
            try expectParity(&runtime, .{ .ints = left }, "1 " ++ word);
            try expectParity(&runtime, .{ .ints = left }, "0 swap " ++ word);
        }
    }
}

// `put` with a flat typed index vector into a typed leaf validates every index
// before its first store, copies a shared collection and reuses a unique one.
// Parity against the boxed collection covers atoms, conforming replacements
// of the same and of the byte representation, repeated indices, every
// fallback that widens the result, and a bad index in the first, a middle, or
// the last block of a collection longer than one step's budget.
test "typed kernels: vector put matches the pervasive route across blocks reuse and fallbacks" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    const quantum = kernels.support.poll_quantum;

    for ([_]usize{ 3, flat.block_size + 1, quantum + 3 }) |length| {
        const numbers = try allocator.alloc(i64, length);
        defer allocator.free(numbers);
        for (numbers, 0..) |*item, index| item.* = @intCast(index * 7 + 1000);
        for ([_][]const u8{
            "dup len 2 / floor range 2 * 7 put 0 (+) fold",
            "dup dup len 2 / floor range 2 * 7 put swap pop 0 (+) fold",
            "dup len range dup 3 * over len mod put 0 (+) fold",
            "dup len range dup reverse put 0 (+) fold",
            "[0 0 1] [5 6 7] put 3 take",
            "[0 1] [5 6.5] put 3 take",
            "[0 2] 2.5 put 3 take",
            "[0 1] [5 6 7] put",
            "dup len range 1 put 0 (+) fold",
            "[0 -1] 5 put",
            "dup len range dup len 2 / floor -1 put 5 put",
            "dup len range dup len 1 - -1 put 5 put",
            "dup len range dup 1 over len put 5 put",
        }) |source| {
            try expectParity(&runtime, .{ .ints = numbers }, source);
        }
    }
    try expectParity(&runtime, .{ .floats = &.{ 1.5, 2.5, 3.5 } }, "[2 0] 9.5 put");
    try expectParity(&runtime, .{ .floats = &.{ 1.5, 2.5, 3.5 } }, "[2 0] 9 put");
}

// A fault in the first, a middle, or the final block reports the first failing
// logical index with the scalar path's kind, message, and data — proven by
// comparing the whole rendered error dict against the generic route, and by
// pinning the index itself so a route that reported a block-local position
// would fail here rather than merely differ.
test "typed kernels: fault blocks report the first logical index and validate aliased blocks before stores" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
        const needle = try std.fmt.bufPrint(&expected_index, "index {d}", .{position});
        std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null) catch |err| {
            std.log.err("fault at {d} reported: {s}", .{ position, rendered });
            return err;
        };
        try std.testing.expect(std.mem.indexOf(u8, rendered, "kind overflow") != null);
    }

    // A type fault: every element faults, and the first index is still the one
    // reported.
    const floats = try allocator.alloc(value.Value, 4);
    defer allocator.free(floats);
    for (floats, 0..) |*item, index| item.* = .{ .float = @floatFromInt(index) };
    const reals = try list.fromValues(allocator, floats);
    const rendered = try outcome(&runtime, &.{reals}, "1 band");
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "kind type") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "index 0") != null);
}

test "typed kernels: explicit vector cores preserve lanes tails broadcasts aliases and first faults" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
    inline for ([_][]const u8{ "=", "<>", "<", ">", "<=", ">=", "min", "max", "band", "bor", "bxor", "+%", "-%", "*%" }) |word| {
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
            for (left, 0..) |*item, index| item.* = @as(i64, @intCast(index)) - @as(i64, @intCast(length / 2));
            left[position] = case.dangerous;
            try expectParity(&runtime, .{ .ints = left }, "2 " ++ case.word);
            const input = try buildInts(.specialized, left);
            try expectFaultRetainsInput(&runtime, input, "2 " ++ case.word);
        }
    }

    // No operand is NaN, so float comparison and selection are infallible:
    // infinities and signed zeros among ordinary lanes order exactly as the
    // scalar authority orders them.
    @memset(left_real, 1.5);
    left_real[flat.block_size + 1] = std.math.inf(f64);
    left_real[flat.block_size + 3] = -std.math.inf(f64);
    left_real[2] = -0.0;
    inline for ([_][]const u8{ "<", "=", "min", "max" }) |word| {
        try expectParity(&runtime, .{ .floats = left_real }, "2.0 " ++ word);
        try expectParity(&runtime, .{ .floats = left_real }, "0.0 " ++ word);
    }
}

/// Runs `source` over `inputs` and asserts the language error names `kind` at
/// logical `index`. Parity with the generic route proves the whole outcome;
/// this pins the one fact parity cannot, that the case faulted at all.
fn expectFaultAt(
    runtime: *session.Session,
    inputs: []const value.Value,
    source: []const u8,
    kind: []const u8,
    index: usize,
) !void {
    const rendered = try outcome(runtime, inputs, source);
    defer allocator.free(rendered);
    var kind_buffer: [64]u8 = undefined;
    var index_buffer: [64]u8 = undefined;
    const kind_needle = try std.fmt.bufPrint(&kind_buffer, "kind {s} ", .{kind});
    const index_needle = try std.fmt.bufPrint(&index_buffer, "index {d} ", .{index});
    std.testing.expect(std.mem.indexOf(u8, rendered, kind_needle) != null and
        std.mem.indexOf(u8, rendered, index_needle) != null) catch |err| {
        std.log.err("`{s}` rendered {s}; wanted kind {s} at index {d}", .{ source, rendered, kind, index });
        return err;
    };
}

test "typed kernels: checked float vector arithmetic matches the scalar fault contract" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    const length = flat.block_size * 2 + 3;
    const left = try allocator.alloc(f64, length);
    defer allocator.free(left);
    const right = try allocator.alloc(f64, length);
    defer allocator.free(right);
    for (left, right, 0..) |*a, *b, index| {
        a.* = @as(f64, @floatFromInt(@as(i64, @intCast(index % 31)) - 15)) + 0.25;
        b.* = @as(f64, @floatFromInt(7 - @as(i64, @intCast(index % 19)))) - 0.5;
    }

    // Full vectors, the tail, both broadcast directions, and self-aliasing, with
    // exact float bits compared against the generic route.
    inline for ([_][]const u8{ "+", "-", "*", "/" }) |word| {
        try expectParity(&runtime, .{ .float_pair = .{ .left = left, .right = right } }, word);
        try expectParity(&runtime, .{ .floats = left }, "3.5 " ++ word);
        try expectParity(&runtime, .{ .floats = left }, "3.5 swap " ++ word);
        try expectParity(&runtime, .{ .floats = right }, "dup " ++ word);
    }

    // Signed zero survives every vector operation bit for bit.
    const zeroes = [_]f64{ -0.0, 0.0, -0.0, 0.0, -0.0 };
    try expectParity(&runtime, .{ .floats = &zeroes }, "-1.0 *");
    try expectParity(&runtime, .{ .floats = &zeroes }, "0.0 +");
    try expectParity(&runtime, .{ .floats = &zeroes }, "-0.0 +");
    try expectParity(&runtime, .{ .floats = &zeroes }, "-0.0 -");
    try expectParity(&runtime, .{ .floats = &zeroes }, "-1.0 /");

    // One exceptional lane among ordinary ones. `kind == null` is a case the
    // scalar authority accepts: an infinity, whether propagated from an operand
    // or produced by overflow or division by zero, is a value, and the vector
    // mask must not flag it. Only a NaN result faults.
    const inf = std.math.inf(f64);
    const Case = struct { special: f64, source: []const u8, kind: ?[]const u8 };
    const cases = [_]Case{
        .{ .special = inf, .source = "2.0 +", .kind = null },
        .{ .special = -inf, .source = "2.0 *", .kind = null },
        .{ .special = inf, .source = "2.0 swap /", .kind = null },
        .{ .special = inf, .source = "inf -", .kind = "domain" },
        .{ .special = 0.0, .source = "inf *", .kind = "domain" },
        .{ .special = 1.0e308, .source = "1.0e308 +", .kind = null },
        .{ .special = -1.0e308, .source = "1.0e308 swap -", .kind = null },
        .{ .special = 1.0e308, .source = "10.0 *", .kind = null },
        .{ .special = 1.0e-308, .source = "1.0e308 swap /", .kind = null },
        .{ .special = 0.0, .source = "1.0 swap /", .kind = null },
        .{ .special = -0.0, .source = "1.0 swap /", .kind = null },
        .{ .special = 0.0, .source = "0.0 swap /", .kind = "domain" },
        .{ .special = -0.0, .source = "0.0 swap /", .kind = "domain" },
        .{ .special = inf, .source = "inf swap /", .kind = "domain" },
    };
    for (cases) |case| {
        for ([_]usize{ 0, 1, flat.block_size - 1, flat.block_size, length - 1 }) |position| {
            @memset(left, 1.5);
            left[position] = case.special;
            // A later exceptional lane in the same block must not displace the
            // first one's report.
            if (position + 2 < length) left[position + 2] = case.special;
            try expectParity(&runtime, .{ .floats = left }, case.source);
            const kind = case.kind orelse continue;
            try expectFaultAt(&runtime, &.{try buildFloats(.specialized, left)}, case.source, kind, position);
            try expectFaultRetainsInput(&runtime, try buildFloats(.specialized, left), case.source);
        }
    }

    // An infinity in a block does not fault, so a NaN later in the same block
    // must still be the one reported: `inf * 1` is a value, `inf * 0` is not.
    // The last pair sits wholly in the final scalar tail.
    for ([_][2]usize{
        .{ 0, 9 },
        .{ 1, flat.block_size - 1 },
        .{ flat.block_size, flat.block_size + 4 },
        .{ flat.block_size * 2, length - 1 },
    }) |positions| {
        @memset(left, 1.5);
        @memset(right, 2.0);
        left[positions[0]] = inf;
        right[positions[0]] = 1.0;
        left[positions[1]] = inf;
        right[positions[1]] = 0.0;
        try expectParity(&runtime, .{ .float_pair = .{ .left = left, .right = right } }, "*");
        try expectFaultAt(
            &runtime,
            &.{ try buildFloats(.specialized, left), try buildFloats(.specialized, right) },
            "*",
            "domain",
            positions[1],
        );
    }

    // A zero divisor broadcast from the right is a signed infinity in every
    // lane, bit for bit as the scalar divides.
    @memset(left, 1.5);
    left[1] = -1.5;
    inline for ([_][]const u8{ "0.0 /", "-0.0 /" }) |source| {
        try expectParity(&runtime, .{ .floats = left }, source);
    }

    // An infinite dividend over a signed zero is an infinity, not a fault.
    for ([_]f64{ 0.0, -0.0 }) |zero| {
        for ([_]usize{ 0, 1, flat.block_size, length - 1 }) |position| {
            @memset(left, 1.5);
            @memset(right, 2.0);
            left[position] = std.math.copysign(inf, zero);
            right[position] = zero;
            try expectParity(&runtime, .{ .float_pair = .{ .left = left, .right = right } }, "/");
        }
    }

    // Leaf by leaf: the fault lane comes from the right operand, an infinity
    // meeting its negation.
    @memset(left, inf);
    for ([_]usize{ 0, flat.block_size, length - 1 }) |position| {
        @memset(right, 1.0);
        right[position] = -inf;
        try expectParity(&runtime, .{ .float_pair = .{ .left = left, .right = right } }, "+");
        try expectFaultAt(
            &runtime,
            &.{ try buildFloats(.specialized, left), try buildFloats(.specialized, right) },
            "+",
            "domain",
            position,
        );
    }
}

test "typed kernels: adopted outputs report the first fault after storing earlier vectors in place" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    const length = flat.block_size * 3 + 5;
    const fault_index = flat.block_size + 7;
    var index_text: [32]u8 = undefined;
    const index_needle = try std.fmt.bufPrint(&index_text, "index {d} ", .{fault_index});

    // `dup 0 +` makes a solely owned copy, which `swap +` takes over as its
    // output; the vectors before the overflow are stored into it first.
    const numbers = try allocator.alloc(i64, length);
    defer allocator.free(numbers);
    for (numbers, 0..) |*number, index| number.* = @intCast(index);
    numbers[fault_index] = @divTrunc(std.math.maxInt(i64), 2) + 1;
    try expectParity(&runtime, .{ .ints = numbers }, "dup 0 + swap +");
    {
        const rendered = try outcome(&runtime, &.{try buildInts(.specialized, numbers)}, "dup 0 + swap +");
        defer allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "kind overflow") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, index_needle) != null);
    }
    try expectFaultRetainsInput(&runtime, try buildInts(.specialized, numbers), "dup 0 + swap +");

    // A recognized vector fold: the second step takes over the first step's
    // result as its output. Faults land in the first vector, the second
    // element, the middle of a block, and the scalar tail. Each fault is an
    // infinity meeting its negation. In the carried case an infinity from an
    // input reaches the accumulator first: it does not fault, so its vector is
    // stored in place and the later NaN is still the one reported.
    const row_a = try allocator.alloc(f64, length);
    defer allocator.free(row_a);
    const row_b = try allocator.alloc(f64, length);
    defer allocator.free(row_b);
    const row_c = try allocator.alloc(f64, length);
    defer allocator.free(row_c);
    for ([_]usize{ 0, 1, fault_index, length - 1 }) |position| {
        for ([_]bool{ false, true }) |carried| {
            if (carried and position < 4) continue;
            for (row_a, row_b, row_c, 0..) |*a, *b, *c, index| {
                const base: f64 = @floatFromInt(index);
                a.* = base + 0.5;
                b.* = base * 2.0;
                c.* = -base;
            }
            row_a[position] = std.math.inf(f64);
            row_b[position] = 0.0;
            row_c[position] = -std.math.inf(f64);
            if (carried) row_b[2] = std.math.inf(f64);
            var rows = [_]value.Value{
                try buildFloats(.specialized, row_a),
                try buildFloats(.specialized, row_b),
                try buildFloats(.specialized, row_c),
            };
            defer for (rows) |row| runtime.release(row);
            var position_text: [32]u8 = undefined;
            const position_needle = try std.fmt.bufPrint(&position_text, "index {d} ", .{position});
            const spine = try list.fromValues(allocator, &rows);
            const rendered = try outcome(&runtime, &.{spine}, "(+) fold1");
            defer allocator.free(rendered);
            std.testing.expect(std.mem.indexOf(u8, rendered, "kind domain") != null and
                std.mem.indexOf(u8, rendered, position_needle) != null) catch |err| {
                std.log.err("fold fault at {d} (carried {}) reported: {s}", .{ position, carried, rendered });
                return err;
            };
            try expectFaultRetainsInput(&runtime, try list.fromValues(allocator, &rows), "(+) fold1");
        }
    }
}

test "typed kernels: temporary bytes are bounded by output plus one kernel chunk under a DebugAllocator limit" {
    // The session enforces the bound directly under a
    // `DebugAllocator` whose live-byte limit is the output buffer plus one
    // kernel chunk plus slack. An intermediate proportional to the input — the
    // sixteen bytes per boxed cell the old route staged, or a second profiling
    // pass over them — exceeds that limit and turns into a failed allocation.
    const Limited = std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = 0 });
    var limited: Limited = .init;
    defer if (limited.deinit() == .leak) std.debug.panic("memory-bound case leaked", .{});
    const limited_allocator = limited.allocator();

    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(limited_allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
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
        // error, so the rendered outcome must contain the value and no failure.
        std.testing.expect(std.mem.indexOf(u8, rendered, "kind") == null) catch |err| {
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
        std.testing.expect(std.mem.indexOf(u8, text, "kind") != null) catch |err| {
            std.log.err("a starved allocation still produced: {s}", .{text});
            return err;
        };
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
