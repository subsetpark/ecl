//! Public behavior of unit plans and explicit unit seeding.
//!
//! `seed` seals a values list and a construction body into one immutable
//! `'unit-plan`; every unit constructor takes either a bare quotation, which
//! seeds nothing, or a plan, which names its seeds and its body separately.
//! Keeping the two apart is what lets `@module` and `@defm` answer the one
//! attribution question they must: did the reader write this exact body?
//!
//! Every test here goes through the ordinary `Session` interface. Nothing
//! inspects a plan's representation, because nothing can: a plan exposes no
//! synthetic body, no environment, and no field but through `unseed`.
const std = @import("std");
const session = @import("../session.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("unit-plan-test.ecl", source)) {
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
/// stack persists across units, so every case starts and ends empty.
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
    const failure = switch (try runtime.runUnit("unit-plan-test.ecl", source)) {
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

test "unit plans: a plan is an opaque first-class value" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectStack(&runtime, "[1 2] (3) seed type", "'unit-plan");
    try expectStack(&runtime, "[1 2] (3) seed", "<unit-plan>");
    // Identity, not structure: one plan duplicated matches itself and two
    // seals of the same pair never do.
    try expectStack(&runtime, "[1 2] (3) seed dup match?", "1");
    try expectStack(&runtime, "[1 2] (3) seed [1 2] (3) seed match?", "0");
    // Ordinary stack movement and storage, and nothing more: a plan is not a
    // list, so no aggregate operation reaches it.
    try expectStack(&runtime, "[1 2] (3) seed 'p set p type", "'unit-plan");
    try expectErrorContains(&runtime, "[1 2] (3) seed len", &.{"'type"});
    try expectErrorContains(&runtime, "[1 2] (3) seed 0 at", &.{"'type"});
    try expectErrorContains(&runtime, "[1 2] (3) seed call", &.{"'type"});
    try expectErrorContains(&runtime, "[1 2] (3) seed (4) cat", &.{"'type"});
}

test "unit plans: seed and unseed round-trip the exact two values" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectStack(&runtime, "[1 2] (3 4) seed unseed", "[1 2] [3 4]");
    // The exact values, not copies of them: each half matches what went in.
    try expectStack(&runtime, "[1 2] dup (3) seed unseed pop match?", "1");
    try expectStack(&runtime, "(3) dup [] swap seed unseed swap pop match?", "1");
    // Empty halves are ordinary inputs.
    try expectStack(&runtime, "[] () seed unseed", "() ()");
    // Unpack, transform, and reseal is the escape hatch, and it composes.
    try expectStack(&runtime, "[1] (2) seed unseed seed unseed", "[1] [2]");
}

test "unit plans: seed and unseed report the ordinary type errors" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectErrorContains(&runtime, "[1 2] 3 seed", &.{ "'type", "seed" });
    try expectErrorContains(&runtime, "3 (1) seed", &.{ "'type", "seed" });
    try expectErrorContains(&runtime, "(1) seed", &.{"'underflow"});
    try expectErrorContains(&runtime, "3 unseed", &.{ "'type", "unseed" });
    try expectErrorContains(&runtime, "(1) unseed", &.{ "'type", "unseed" });
    try expectErrorContains(&runtime, "[1] unseed", &.{ "'type", "unseed" });
    // A constructor's input is a quotation or a plan and nothing else.
    try expectErrorContains(&runtime, "3 @attempt", &.{"'type"});
    try expectErrorContains(&runtime, "3 @module", &.{"'type"});
    try expectErrorContains(&runtime, "3 'm @defm", &.{"'type"});
    try expectErrorContains(&runtime, "3 @spawn", &.{"'type"});
    try expectErrorContains(&runtime, "[1] 3 @each", &.{"'type"});
}

test "unit plans: a plan seeds every unit constructor in list order" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectStack(&runtime, "[10 3] (-) seed @attempt", "{'ok [7]}");
    try expectStack(&runtime, "[10 3] (-) seed @spawn await", "{'ok [7]}");
    // The element stays deepest in each child stack, beneath the shared seeds.
    try expectStack(&runtime, "[1 2] [10] (-) seed @each", "[-9 -8]");
    try expectStack(&runtime, "[4 5] (+ 'sum set) seed @module 'summed register summed.sum", "9");
    try expectStack(&runtime, "[4 5] (+ 'sum set) seed 'added @defm added.sum", "9");
    // An empty seed list is the unseeded case spelled out.
    try expectStack(&runtime, "[] (7) seed @attempt", "{'ok [7]}");
    try expectStack(&runtime, "[] () seed @attempt", "{'ok ()}");
    // A bare quotation still seeds nothing at all.
    try expectStack(&runtime, "(7) @attempt", "{'ok [7]}");
    try expectStack(&runtime, "9 (1 +) @attempt nip 'err at 'kind at", "'underflow");
}

test "unit plans: the seeding remedy an isolation underflow names is seed" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectStack(
        &runtime,
        "1 (1 +) @attempt nip 'err at dup 'data at 'isolation at swap 'msg at",
        "@attempt \"+ needs 2 stack values, but found 1; the substack is isolated from " ++
            "the caller's stack — seed it with `values (q) seed @attempt` or capture with `partial`\"",
    );
}

test "unit plans: a large seed list and a large body preserve order and postconditions" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // 512 seeds arrive in list order, so folding pairwise from the top still
    // reaches the deepest one.
    try expectStack(&runtime, "512 range (511 (+) times) seed @attempt 'ok at", "[130816]");
    // Seeds the body consumes, in order, with the construction's own
    // postcondition still enforced on what it leaves behind.
    try expectStack(
        &runtime,
        "[1 2] (+ ( -- n ) ((dup without) within) 'go def) seed 'sized @defm sized.go",
        "3",
    );
    // One plan seeds a whole fan-out identically.
    try expectStack(&runtime, "64 range [1] (+) seed @each len", "64");
    // More seeds than one scheduler step materializes, so the list order has to
    // survive the slice boundary: popping all but the deepest leaves the first
    // element of the seed list.
    try expectStack(&runtime, "300 range (299 (pop) times) seed @attempt 'ok at", "[0]");
    // And a child's element stays deepest beneath 300 seeds delivered across
    // several of its own slices.
    try expectStack(&runtime, "[7] 300 range (300 (pop) times) seed @each", "[7]");
}

test "unit plans: a construction body the reader wrote names its image" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // Top level, and through every container the reader built.
    try expectStack(
        &runtime,
        "((99) 'k defp {'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'literal-body @defm literal-body.go",
        "99",
    );
    try expectStack(
        &runtime,
        "((99) 'k defp [(k)] 'l setp ( -- n ) (l first call) 'go def) 'listed @defm listed.go",
        "99",
    );
    // A raw reader body and the same body in a plan stamp identically.
    try expectOk(&runtime, "((2 *) 'double def ( -- n ) (4 double) 'go def) 'raw-body set");
    try expectStack(&runtime, "raw-body 'from-raw @defm from-raw.go", "8");
    try expectStack(&runtime, "[] raw-body seed 'from-plan @defm from-plan.go", "8");
    // And the original stays reusable after both.
    try expectStack(&runtime, "raw-body 'again @defm again.go", "8");
}

test "unit plans: seeds are never traversed or stamped" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // A caller-authored behavior is a seed and keeps the caller's scope.
    try expectStack(
        &runtime,
        "10 'k set [(k *)] ('scale def ( -- n ) (4 scale) 'go def) seed 'scaled @defm scaled.go",
        "40",
    );
    // A reader-built dict seed keeps it too, container and all.
    try expectStack(
        &runtime,
        "3 'k set [{'a (k)}] ('deps set ( -- n ) (deps 'a at call) 'go def) seed 'dictseed @defm dictseed.go",
        "3",
    );
    // A seed the body never consumes is left on the construction stack as the
    // image's initial state, unchanged — and it is still the caller's text, so
    // running it back at the session resolves `k` there.
    try expectStack(
        &runtime,
        "7 'k set [(k)] (((dup without) within) 'peek def) seed 'inert @defm inert.peek call",
        "7",
    );
}

test "unit plans: a runtime-built body acquires no attribution" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // cat, compose, and raze all produce runtime-built values, and a reader
    // witness carried by a nested fragment grants no admission through one.
    try expectStack(&runtime, "7 'k set ((k) 'geta) (def) cat 'catted @defm catted.geta", "7");
    try expectStack(&runtime, "7 'k set ((k) 'getb) (def) compose 'composed @defm composed.getb", "7");
    try expectStack(&runtime, "7 'k set [((k) 'getc) (def)] raze 'razed @defm razed.getc", "7");
    // Wrapping the same runtime-built body in a plan changes its initial stack
    // and nothing else.
    try expectStack(&runtime, "7 'k set [] ((k) 'getd) (def) cat seed 'planned @defm planned.getd", "7");
    // `with` is ordinary composition, so its flattened result is runtime-built
    // too: the superseded spelling still runs and takes no attribution.
    try expectStack(
        &runtime,
        "5 'k set [(k *)] ('scale def ( -- n ) (4 scale) 'go def) with @module type",
        "'module",
    );
    try expectErrorContains(
        &runtime,
        "5 'k set [(k *)] ('scale def ( -- n ) (4 scale) 'go def) with 'flat @defm flat.go",
        &.{ "'undefined-word", "scale" },
    );
}

test "unit plans: one reader body serves two images independently" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "(( -- n ) (state) 'read def ((dup without) within) 'state def) 'shared set",
    );
    try expectOk(&runtime, "[10] shared seed 'left @defm");
    try expectOk(&runtime, "[100] shared seed 'right @defm");
    // Each image stamped its own copy, so each reads its own durable state.
    try expectStack(&runtime, "left.read", "10");
    try expectStack(&runtime, "right.read", "100");
    // The original body is unchanged and still constructs.
    try expectStack(&runtime, "[7] shared seed 'third @defm third.read", "7");
}

test "unit plans: a nested construction inside a stamped body still names its own image" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // The inner `@defm` is handed the outer stamp's copy of its body. A
    // re-scoped copy of reader text is still reader text, so the inner
    // construction re-scopes it against the inner image rather than leaving it
    // pointing at the enclosing one.
    try expectStack(
        &runtime,
        "((1) 'x defp ( -- n ) (((2) 'x defp ( -- n ) (x) 'get def) @module 'get invoke) 'outer def) " ++
            "'nest @defm nest.outer",
        "2",
    );
    // A body with many occurrences is copied whole, every one of them naming
    // the image. (That the copy is *sliced* is a cursor-level property, proved
    // in `spans.zig` by advancing one element at a time.)
    try expectStack(
        &runtime,
        "((1) 'x defp ( -- n ) (x x x x x x x x x x x x x x x x x x x x pop pop pop pop " ++
            "pop pop pop pop pop pop pop pop pop pop pop pop pop pop pop) 'go def) " ++
            "'wide @defm wide.go",
        "1",
    );
    // And a seeded nested construction behaves the same way.
    try expectStack(
        &runtime,
        "((1) 'x defp ( -- n ) ([] ((2) 'x defp ( -- n ) (x) 'get def) seed @module 'get invoke) 'outer def) " ++
            "'nest-seeded @defm nest-seeded.outer",
        "2",
    );
}
