//! Public behavior of module construction bodies.
//!
//! `@defm` re-homes every word of the body it is handed, however the body was
//! built, through every nested list and dict.
//!
//! Every test here goes through the ordinary `Session` interface. Nothing
//! inspects interpreter representation.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const test_heap = @import("test_heap.zig");
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

test "module bodies: a construction body names its image" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // Top level, and through every container the reader built.
    try expectStack(
        &runtime,
        "((99) `k defp {a (k)} `d setp ( -- n ) (d `a at call) `go def) `literal-body @defm literal-body.go",
        "99",
    );
    try expectStack(
        &runtime,
        "((99) `k defp [(k)] `l setp ( -- n ) (l first call) `go def) `listed @defm listed.go",
        "99",
    );
    // A stored reader body and a literal reader body stamp identically.
    try expectOk(&runtime, "((2 *) `double def ( -- n ) (4 double) `go def) `raw-body set");
    try expectStack(&runtime, "raw-body `from-raw @defm from-raw.go", "8");
    try expectStack(&runtime, "raw-body `from-second @defm from-second.go", "8");
    // And the original stays reusable after both.
    try expectStack(&runtime, "raw-body `again @defm again.go", "8");
}

test "module bodies: a runtime-built body is module text too" {
    var runtime_inputs7 = try runtime_fixture.Fixture.init();
    defer runtime_inputs7.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs7.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // cat and raze both produce runtime-built values, and every word in the
    // body they build names the module: a caller's `k` is not reached.
    try expectErrorContains(&runtime, "7 `k set ((k) `geta) (def) cat `catted @defm catted.geta", &.{ "undefined-word", "scope module" });
    try expectErrorContains(&runtime, "7 `k set [((k) `getc) (def)] raze `razed @defm razed.getc", &.{ "undefined-word", "scope module" });
    // A module whose runtime-built body defines what it uses works as a
    // literal one does.
    try expectStack(&runtime, "((7) `k def) (( -- n ) (k) `geta def) cat `built @defm built.geta", "7");
    try expectStack(&runtime, "[(k *)] (`scale def (5) `k def ( -- n ) (4 scale) `go def) cat `flat @defm flat.go", "20");

    // Define, execute, and replace runtime-built bodies in one Fiber so the
    // measurement excludes per-source archive retention. A Session keeps
    // every published image, so memory grows with the registrations made; it
    // must grow no faster than they do.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    {
        var runtime_inputs8 = try runtime_fixture.Fixture.init();
        defer runtime_inputs8.deinit();
        var measured = try session.Session.init(counting.allocator(), &.{}, runtime_inputs8.inputs(.{}), .cooperative, .evaluate);
        defer measured.deinit();
        const cycle = "((1) `x def) () cat `runtime-built @defm " ++
            "((1) `x def) () cat `runtime-built @defm " ++
            "`runtime-built.x execute pop";
        const small = "[1] 20 take (pop " ++ cycle ++ ") for";
        const large = "[1] 200 take (pop " ++ cycle ++ ") for";
        try expectStack(&measured, small, "");
        const before_small = counting.total_requested_bytes;
        try expectStack(&measured, small, "");
        const after_small = counting.total_requested_bytes;
        try expectStack(&measured, large, "");
        const after_large = counting.total_requested_bytes;
        const small_growth = after_small -| before_small;
        const large_growth = after_large -| after_small;
        try std.testing.expect(large_growth <= small_growth * 10 * 2 + 4096);
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "module bodies: one reader body serves two images independently" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "(*module* `state setp ( -- n ) (state) `read def) `shared set",
    );
    try expectOk(&runtime, "shared `left @defm");
    try expectOk(&runtime, "shared `right @defm");
    // Each image stamped its own copy, so each reads its own state.
    try expectStack(&runtime, "left.read", "left");
    try expectStack(&runtime, "right.read", "right");
    // The original body is unchanged and still constructs.
    try expectStack(&runtime, "shared `third @defm third.read", "third");
}

test "module bodies: a nested construction inside a stamped body still names its own image" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // The inner `@defm` is handed the outer stamp's copy of its body. A
    // re-scoped copy of reader text is still reader text, so the inner
    // construction re-scopes it against the inner image rather than leaving it
    // pointing at the enclosing one.
    try expectStack(
        &runtime,
        "((1) `x defp ( -- n ) (((2) `x defp ( -- n ) (x) `get def) `nest-inner @defm `nest-inner.get execute) " ++
            "`outer def) `nest @defm nest.outer",
        "2",
    );
    // A body with many occurrences is copied whole, every one of them naming
    // the image. (That the copy is *sliced* is a cursor-level property, proved
    // in `spans.zig` by advancing one element at a time.)
    try expectStack(
        &runtime,
        "((1) `x defp ( -- n ) (x x x x x x x x x x x x x x x x x x x x pop pop pop pop " ++
            "pop pop pop pop pop pop pop pop pop pop pop pop pop pop pop) `go def) " ++
            "`wide @defm wide.go",
        "1",
    );
}
