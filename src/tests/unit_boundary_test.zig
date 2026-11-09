//! Public behavior of unit constructor boundaries.
//!
//! A constructed unit starts on an empty stack, except that a `@give` child
//! starts on the ports it was given. A caller that wants a unit to start on
//! values builds them into the body, and underflow against the boundary says
//! so.
//!
//! Every test here goes through the ordinary `Session` interface. Nothing
//! inspects interpreter representation.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const session = @import("../session.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("unit-input-test.ecl", source)) {
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
}

/// Run one source, assert the values it left, then drain them: the session
/// stack persists across submissions, so every case starts and ends empty.
fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    try expectOk(runtime, source);
    {
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }
    while (runtime.stackItems().len != 0) try expectOk(runtime, "pop");
}

fn expectErrorContains(
    runtime: *session.Session,
    source: []const u8,
    needles: []const []const u8,
) !void {
    const failure = switch (try runtime.runUnit("unit-input-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    for (needles) |needle| std.testing.expect(
        std.mem.indexOf(u8, rendered.bytes(), needle) != null,
    ) catch |failed| {
        std.log.err("error {s} lacked {s}", .{ rendered.bytes(), needle });
        return failed;
    };
    while (runtime.stackItems().len != 0) try expectOk(runtime, "pop");
}

test "unit boundaries: every constructor checks its operands" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectErrorContains(&runtime, "@attempt", &.{"underflow"});
    try expectErrorContains(&runtime, "3 @attempt", &.{"type"});
    try expectErrorContains(&runtime, "`m @defm", &.{"underflow"});
    try expectErrorContains(&runtime, "3 `m @defm", &.{"type"});
    try expectErrorContains(&runtime, "3 @load", &.{"type"});
    try expectErrorContains(&runtime, "3 @spawn", &.{"type"});
    try expectErrorContains(&runtime, "[1] 3 @each", &.{"type"});
    try expectErrorContains(&runtime, "[] 3 @give", &.{"type"});
}

test "unit boundaries: initial values reach every unit constructor in list order" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectStack(&runtime, "(10 3 -) @attempt", "{ok [7]}");
    try expectStack(&runtime, "(10 3 -) @spawn task.await", "{ok [7]}");
    try expectStack(&runtime, "10 3 pair (-) cat @attempt", "{ok [7]}");
    // The element is deepest in each child stack, beneath what the body pushes.
    try expectStack(&runtime, "[1 2] (10 -) @each", "[-9 -8]");
    // The given ports are the child's whole initial stack.
    try expectStack(&runtime, "[] (stack) @give task.await", "{ok (())}");
    try expectStack(&runtime, "(7) @attempt", "{ok [7]}");
    try expectStack(&runtime, "() @attempt", "{ok ()}");
}

test "unit boundaries: isolation underflow says how to pass initial values" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectStack(
        &runtime,
        "9 (1 +) @attempt nip `err at dup `data at `isolation at swap `msg at",
        "@attempt \"+ needs 2 stack values, but found 1; the substack is isolated from " ++
            "the caller's stack — build initial values into the quotation: `values (q) cat @attempt`\"",
    );
}

test "unit boundaries: every constructor diagnoses its own boundary" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectErrorContains(&runtime, "9 (1 +) `missing @defm", &.{
        "isolation @defm",
        "a module body starts on an empty stack",
        "trace (`+)",
    });
    try expectErrorContains(&runtime, "(1 +) @spawn task.await `err at raise", &.{
        "isolation @spawn",
        "`values (q) cat @spawn`\"",
    });
    // `@each` is prelude code over `@spawn`, which owns each child's floor.
    try expectErrorContains(&runtime, "[1] (+) @each", &.{
        "isolation @spawn",
        "`values (q) cat @spawn`",
        "trace (`+)",
    });
}

test "unit boundaries: large bodies preserve order and postconditions" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // 512 values built into a body arrive in list order, so folding pairwise
    // from the top still reaches the deepest one.
    try expectStack(&runtime, "512 range (511 (+) times) cat @attempt `ok at", "[130816]");
    // One body initializes a whole fan-out identically.
    try expectStack(&runtime, "64 range (1 +) @each len", "64");
    // More values than one scheduler step copies, so the list order has to
    // survive the slice boundary: popping all but the deepest leaves the first
    // element of the list.
    try expectStack(&runtime, "300 range (299 (pop) times) cat @attempt `ok at", "[0]");
    // And a child's element stays deepest beneath the 300 values its body
    // pushes.
    try expectStack(&runtime, "[7] 300 range (300 (pop) times) cat @each", "[7]");
}
