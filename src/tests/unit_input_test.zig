//! Public behavior of fixed-arity unit inputs and explicit unit seeding.
//!
//! Every unit constructor consumes a seed-values list followed by its exact
//! body. Keeping the two operands apart is what lets `@module` and `@defm`
//! answer the one attribution question they must: did the reader write this
//! exact body?
//!
//! Every test here goes through the ordinary `Session` interface. Nothing
//! inspects interpreter representation.
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

test "unit inputs: every constructor requires separate seed and body lists" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectErrorContains(&runtime, "(1) @attempt", &.{"'underflow"});
    try expectErrorContains(&runtime, "[1] 3 @attempt", &.{"'type"});
    try expectErrorContains(&runtime, "3 (1) @attempt", &.{"'type"});
    try expectErrorContains(&runtime, "[1] 3 @module", &.{"'type"});
    try expectErrorContains(&runtime, "3 (1) 'm @defm", &.{"'type"});
    try expectErrorContains(&runtime, "[1] 3 @spawn", &.{"'type"});
    try expectErrorContains(&runtime, "[1] [] 3 @each", &.{"'type"});
}

test "unit inputs: seeds reach every unit constructor in list order" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectStack(&runtime, "[10 3] (-) @attempt", "{'ok [7]}");
    try expectStack(&runtime, "[10 3] (-) @spawn await", "{'ok [7]}");
    // The element stays deepest in each child stack, beneath the shared seeds.
    try expectStack(&runtime, "[1 2] [10] (-) @each", "[-9 -8]");
    try expectStack(&runtime, "[4 5] (+ 'sum set) @module 'summed register summed.sum", "9");
    try expectStack(&runtime, "[4 5] (+ 'sum set) 'added @defm added.sum", "9");
    // An empty seed list is the unseeded case spelled out.
    try expectStack(&runtime, "[] (7) @attempt", "{'ok [7]}");
    try expectStack(&runtime, "[] () @attempt", "{'ok ()}");
}

test "unit inputs: isolation underflow names only the explicit values operand" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectStack(
        &runtime,
        "9 [1] (+) @attempt nip 'err at dup 'data at 'isolation at swap 'msg at",
        "@attempt \"+ needs 2 stack values, but found 1; the substack is isolated from " ++
            "the caller's stack — pass initial values in the constructor's values operand: " ++
            "`values (q) @attempt`\"",
    );
}

test "unit inputs: every constructor diagnoses its own values operand" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectErrorContains(&runtime, "9 [] (1 +) @module", &.{
        "'isolation @module",
        "constructor's values operand",
        "`values (body) @module`",
    });
    try expectErrorContains(&runtime, "9 [] (1 +) 'missing @defm", &.{
        "'isolation @defm",
        "constructor's values operand",
        "`values (body) 'name @defm`",
    });
    try expectErrorContains(&runtime, "[] (1 +) @spawn await 'err at raise", &.{
        "'isolation @spawn",
        "constructor's values operand",
        "`values (q) @spawn`",
    });
    try expectErrorContains(&runtime, "[1] [] (+) @each", &.{
        "'isolation @each",
        "constructor's values operand",
        "`list values (q) @each`",
    });
}

test "unit inputs: large seeds and bodies preserve order and postconditions" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // 512 seeds arrive in list order, so folding pairwise from the top still
    // reaches the deepest one.
    try expectStack(&runtime, "512 range (511 (+) times) @attempt 'ok at", "[130816]");
    // Seeds the body consumes, in order, with the construction's own
    // postcondition still enforced on what it leaves behind.
    try expectStack(
        &runtime,
        "[1 2] (+ ( -- n ) ((dup without) within) 'go def) 'sized @defm sized.go",
        "3",
    );
    // One seed list initializes a whole fan-out identically.
    try expectStack(&runtime, "64 range [1] (+) @each len", "64");
    // More seeds than one scheduler step materializes, so the list order has to
    // survive the slice boundary: popping all but the deepest leaves the first
    // element of the seed list.
    try expectStack(&runtime, "300 range (299 (pop) times) @attempt 'ok at", "[0]");
    // And a child's element stays deepest beneath 300 seeds delivered across
    // several of its own slices.
    try expectStack(&runtime, "[7] 300 range (300 (pop) times) @each", "[7]");
}

test "unit inputs: a construction body the reader wrote names its image" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // Top level, and through every container the reader built.
    try expectStack(
        &runtime,
        "[] ((99) 'k defp {'a (k)} 'd setp ( -- n ) (d 'a at call) 'go def) 'literal-body @defm literal-body.go",
        "99",
    );
    try expectStack(
        &runtime,
        "[] ((99) 'k defp [(k)] 'l setp ( -- n ) (l first call) 'go def) 'listed @defm listed.go",
        "99",
    );
    // A stored reader body and a literal reader body stamp identically.
    try expectOk(&runtime, "((2 *) 'double def ( -- n ) (4 double) 'go def) 'raw-body set");
    try expectStack(&runtime, "[] raw-body 'from-raw @defm from-raw.go", "8");
    try expectStack(&runtime, "[] raw-body 'from-second @defm from-second.go", "8");
    // And the original stays reusable after both.
    try expectStack(&runtime, "[] raw-body 'again @defm again.go", "8");
}

test "unit inputs: seeds are never traversed or stamped" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // A caller-authored behavior is a seed and keeps the caller's scope.
    try expectStack(
        &runtime,
        "10 'k set [(k *)] ('scale def ( -- n ) (4 scale) 'go def) 'scaled @defm scaled.go",
        "40",
    );
    // A reader-built dict seed keeps it too, container and all.
    try expectStack(
        &runtime,
        "3 'k set [{'a (k)}] ('deps set ( -- n ) (deps 'a at call) 'go def) 'dictseed @defm dictseed.go",
        "3",
    );
    // A seed the body never consumes is left on the construction stack as the
    // image's initial state, unchanged — and it is still the caller's text, so
    // running it back at the session resolves `k` there.
    try expectStack(
        &runtime,
        "7 'k set [(k)] (((dup without) within) 'peek def) 'inert @defm inert.peek call",
        "7",
    );
}

test "unit inputs: a runtime-built body acquires no attribution" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // cat, compose, and raze all produce runtime-built values, and a reader
    // witness carried by a nested fragment grants no admission through one.
    try expectStack(&runtime, "7 'k set [] ((k) 'geta) (def) cat 'catted @defm catted.geta", "7");
    try expectStack(&runtime, "7 'k set [] ((k) 'getb) (def) compose 'composed @defm composed.getb", "7");
    try expectStack(&runtime, "7 'k set [] [((k) 'getc) (def)] raze 'razed @defm razed.getc", "7");
    // Supplying explicit seeds changes the initial stack and nothing else.
    try expectStack(&runtime, "7 'k set [] ((k) 'getd) (def) cat 'seeded @defm seeded.getd", "7");
    // `with` is ordinary composition, so its flattened result is runtime-built
    // too: the superseded spelling still runs and takes no attribution.
    try expectStack(
        &runtime,
        "5 'k set [] [(k *)] ('scale def ( -- n ) (4 scale) 'go def) with @module type",
        "'module",
    );
    try expectErrorContains(
        &runtime,
        "5 'k set [] [(k *)] ('scale def ( -- n ) (4 scale) 'go def) with 'flat @defm flat.go",
        &.{ "'undefined-word", "scale" },
    );

    // Rejected roots must also avoid the stable image ScopeId used only to
    // label rewritten occurrences. Construct, execute, register, replace, and
    // retire runtime-built bodies in one Unit so the measurement excludes
    // per-source archive retention; ten times the cycles must not retain ten
    // times the settled memory.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    {
        var measured = try session.Session.initWithConfig(
            counting.allocator(),
            &.{},
            .cooperative,
        );
        defer measured.deinit();
        const cycle = "[] ((1) 'x def) () cat @module " ++
            "dup 'runtime-built register " ++
            "dup 'runtime-built register " ++
            "runtime-built.x pop 'runtime-built unmodule pop";
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
        try std.testing.expect(large_growth <= small_growth * 2 + 4096);
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "unit inputs: one reader body serves two images independently" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "(( -- n ) (state) 'read def ((dup without) within) 'state def) 'shared set",
    );
    try expectOk(&runtime, "[10] shared 'left @defm");
    try expectOk(&runtime, "[100] shared 'right @defm");
    // Each image stamped its own copy, so each reads its own durable state.
    try expectStack(&runtime, "left.read", "10");
    try expectStack(&runtime, "right.read", "100");
    // The original body is unchanged and still constructs.
    try expectStack(&runtime, "[7] shared 'third @defm third.read", "7");
}

test "unit inputs: a nested construction inside a stamped body still names its own image" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // The inner `@defm` is handed the outer stamp's copy of its body. A
    // re-scoped copy of reader text is still reader text, so the inner
    // construction re-scopes it against the inner image rather than leaving it
    // pointing at the enclosing one.
    try expectStack(
        &runtime,
        "[] ((1) 'x defp ( -- n ) ([] ((2) 'x defp ( -- n ) (x) 'get def) @module 'get invoke) 'outer def) " ++
            "'nest @defm nest.outer",
        "2",
    );
    // A body with many occurrences is copied whole, every one of them naming
    // the image. (That the copy is *sliced* is a cursor-level property, proved
    // in `spans.zig` by advancing one element at a time.)
    try expectStack(
        &runtime,
        "[] ((1) 'x defp ( -- n ) (x x x x x x x x x x x x x x x x x x x x pop pop pop pop " ++
            "pop pop pop pop pop pop pop pop pop pop pop pop pop pop pop) 'go def) " ++
            "'wide @defm wide.go",
        "1",
    );
    // And a nested construction with explicit empty seeds behaves the same way.
    try expectStack(
        &runtime,
        "[] ((1) 'x defp ( -- n ) ([] ((2) 'x defp ( -- n ) (x) 'get def) @module 'get invoke) 'outer def) " ++
            "'nest-seeded @defm nest-seeded.outer",
        "2",
    );
}
