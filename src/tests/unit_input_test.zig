//! Public behavior of unit constructor inputs.
//!
//! A constructed unit starts on an empty stack, `@give`'s ports, or `@each`'s
//! element, and a caller that wants values builds them into the body. `@defm`
//! re-homes every word of the body it is handed, however it was built.
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

test "unit inputs: every constructor checks its operands" {
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

test "unit inputs: initial values reach every unit constructor in list order" {
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

test "unit inputs: isolation underflow says how to pass initial values" {
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

test "unit inputs: every constructor diagnoses its own boundary" {
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

test "unit inputs: large bodies preserve order and postconditions" {
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

test "unit inputs: a construction body names its image" {
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

test "unit inputs: a runtime-built body is module text too" {
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

test "unit inputs: one reader body serves two images independently" {
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

test "unit inputs: a nested construction inside a stamped body still names its own image" {
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
