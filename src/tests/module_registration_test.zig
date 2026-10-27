//! Module registration through `@defm`, the single module constructor.
//!
//! `@defm` validates its name, runs the body in a fresh unit, and publishes the
//! resulting image as the registration's new generation. Every test here pins
//! one publicly observable clause of that contract through the ordinary
//! `Session` interface — no accessor exposes `ModuleImage`,
//! `ModuleHome`, `Environment`, or any registry internal.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const formatter = @import("../formatter.zig");
const session = @import("../session.zig");
const stdlib = @import("../stdlib.zig");
const support = @import("kernel_test_support.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("module-registration-test.ecl", source)) {
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

fn expectErrorContains(
    runtime: *session.Session,
    source: []const u8,
    needles: []const []const u8,
) !void {
    const failure = switch (try runtime.runUnit("module-registration-test.ecl", source)) {
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
}

/// Run one source and assert the values it left, then drain them: the session
/// stack persists across units, so every assertion starts from an empty stack
/// and leaves one behind.
fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    try expectOk(runtime, source);
    {
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }
    while (runtime.stackItems().len != 0) try expectOk(runtime, "pop");
}

fn expectEmptyStack(runtime: *session.Session) !void {
    try std.testing.expectEqual(@as(usize, 0), runtime.stackItems().len);
}

test "module registration: @defm validates its name before running the body" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // Each name that can never be published is refused before the body runs:
    // the body's own failure, which would be `'user`, never appears.
    try expectErrorContains(&runtime, "[] (\"ran\" fail) `core @defm", &.{
        "kind domain",
        "reserved for the core qualifier",
        "word @defm",
    });
    try expectErrorContains(&runtime, "[] (\"ran\" fail) `-- @defm", &.{
        "kind domain",
        "valid module name",
    });
    try expectErrorContains(&runtime, "[] (\"ran\" fail) `dict @defm", &.{
        "kind domain",
        "reserved for the standard library",
    });
    try expectErrorContains(&runtime, "`wrong [] (\"ran\" fail) @defm", &.{
        "kind type",
        "word @defm",
    });
    try expectEmptyStack(&runtime);

    // With a valid name the body runs, and its failure is the construction's.
    try expectErrorContains(&runtime, "[] (\"ran\" fail ((2) `v def)) `ghost @defm", &.{
        "kind user",
        "\"ran\"",
    });
    try expectEmptyStack(&runtime);
    try expectErrorContains(&runtime, "ghost.v", &.{"kind undefined-word"});

    // A registry change during construction can still refuse publication after
    // the body ran; the previous registration is untouched.
    try expectOk(&runtime, "[] ((1) `v def) `aliased @defm `short `aliased alias");
    try expectErrorContains(&runtime, "[] ((2) `v def) `short @defm", &.{
        "kind domain",
        "collides with an alias",
    });
    try expectEmptyStack(&runtime);
    try expectStack(&runtime, "aliased.v", "1");
}

test "module registration: nested definitions and reloads publish through the registry" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // A body may define another module; both are registrations, not values.
    try expectStack(&runtime, "[] ([] ((2) `x def) `inner @defm (inner.x) `get def) `outer @defm outer.get", "2");
    try expectStack(&runtime, "inner.x", "2");

    // Re-definition publishes new code under the same name.
    try expectStack(&runtime, "[] ((1) `x def) `m @defm [] ((2) `x def) `m @defm m.x", "2");

    // Seeded values are the body's entry stack, which the body consumes.
    try expectStack(&runtime, "[4 5] (+ `sum set) `seeded @defm seeded.sum", "9");
}

test "module registration: a construction body must leave its stack empty" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // A module body defines words and keeps no state: anything left on its
    // stack is refused at completion and nothing is registered.
    try expectErrorContains(&runtime, "[] (1 (2) `x def) `m @defm", &.{ "kind domain", "word @defm", "left 1 value" });
    try expectEmptyStack(&runtime);
    try expectErrorContains(&runtime, "m.x", &.{"kind undefined-word"});
    try expectErrorContains(&runtime, "[] (7) `left @defm", &.{ "kind domain", "left 1 value" });
    try expectErrorContains(&runtime, "[1 2] () `two @defm", &.{ "kind domain", "left 2 values" });
    // A body that consumes its seeds publishes as before.
    try expectStack(&runtime, "[4 5] (+ pop (1) `one def) `ok @defm ok.one", "1");
}

test "module registration: invocation context comes from the registration" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();

    // Two registrations with identical bodies: the registration the call
    // entered through supplies the reported spelling.
    const body = "[] (" ++
        "(1) `tick defp " ++
        "(tick) `bump def " ++
        "(`bump which) `report def " ++
        "( -- n ) (1 2) `liar def " ++
        "(liar) `same-home def" ++
        ") ";
    try expectOk(&runtime, body ++ "`left @defm " ++ body ++ "`right @defm");
    try expectEmptyStack(&runtime);

    // A private word reached through a public one resolves in either
    // registration, regardless of which was registered last.
    try expectStack(&runtime, "left.bump left.bump right.bump", "1 1 1");

    // Reflection reports the invoking registration's spelling and generation.
    try expectOk(&runtime, "right.report left.report");
    try std.testing.expectEqualStrings(
        "bump -> right.bump def public generation 1\n" ++
            "bump -> left.bump def public generation 1\n",
        output.written(),
    );

    // A declared effect is a cross-home contract, and its diagnostic names the
    // registration that was called.
    try expectErrorContains(&runtime, "right.liar", &.{ "kind contract", "word right.liar" });
    try expectErrorContains(&runtime, "left.liar", &.{ "kind contract", "word left.liar" });

    // The same call from inside the image is same-home, so no contract check
    // applies and both registrations agree.
    try expectStack(&runtime, "left.same-home", "1 2");
    try expectStack(&runtime, "right.same-home", "1 2");
}

test "module registration: a diagnostic spells the same word its failure reports" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // A module-local word has no interned qualified spelling, so a message
    // renders one into a scratch buffer while the `word` field is interned
    // separately. The two must never name *different* words: for an image
    // registered under several names, the unqualified atom alone would not say
    // which registration failed. A name long enough to exhaust the scratch is
    // the case that used to substitute it.
    const long = &@as([330]u8, @splat('m'));
    const source = "[] (( -- n ) (1 2) `two def) `" ++ long ++ " @defm " ++ long ++ ".two";
    const failure = switch (try runtime.runUnit("module-registration-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    const qualified = long ++ ".two";
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), "word " ++ qualified) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), "\"" ++ qualified ++ " declared") != null);
    // And the unqualified atom never stands in for it.
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), "\"two declared") == null);
}

test "module registration: failures leave prior registrations atomic" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // A failing construction body publishes no name.
    try expectErrorContains(&runtime, "[] ((1 0 div) call ((2) `v def)) `broken @defm", &.{"kind domain"});
    try expectEmptyStack(&runtime);
    try expectErrorContains(&runtime, "broken.v", &.{"kind undefined-word"});

    // A refused publication leaves the prior directory entry, generation, and
    // durable state exactly as they were.
    try expectOk(&runtime, "[] ((1) `bump def) `kept @defm");
    try expectStack(&runtime, "kept.bump", "1");
    try expectOk(&runtime, "`kept-alias `kept alias");
    try expectErrorContains(&runtime, "[] ((2) `bump def) `kept-alias @defm", &.{
        "kind domain",
        "collides with an alias",
    });
    try expectEmptyStack(&runtime);
    try expectStack(&runtime, "kept.bump", "1");
}

test "module loader: observation and dispatch require the requested registration" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = "test/acceptance/modules",
    }), .default, .evaluate);
    defer runtime.deinit();

    // Literal and dynamically qualified dispatch both auto-load with no prior
    // import.
    try expectStack(&runtime, "`stats `answer qualify execute", "42");
    try expectStack(&runtime, "stats.answer", "42");

    // `import` reaches the same registration through the same path.
    try expectStack(&runtime, "`stats (answer) import answer", "42");

    // A file that registers nothing fails with the total loader error.
    try expectErrorContains(&runtime, "orphan.answer", &.{
        "kind io",
        "registered nothing under that name",
        "path \"test/acceptance/modules/orphan.ecl\"",
    });

    // Observation is registration-driven because it is *symbol*-driven:
    // `which`, `see`, and `doc` all consume a name, and a name is exactly what
    // a registration is. `see` renders the stored
    // body, which is how one binding kind stays observable without any
    // operation that lifts a body out of its home.
    output.clearRetainingCapacity();
    try expectOk(&runtime, "`stats.answer see");
    try std.testing.expectEqualStrings("[42]\n", output.written());
}

test "module registration: reuse reload removal and delayed calls reclaim boundedly" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .cooperative, .evaluate);
        defer runtime.deinit();

        // Two registrations, a reload of one while a delayed call holds the
        // superseded generation, then removal of both names. Every call runs in
        // a child unit: a unit pins each generation it dispatches through until
        // it ends, and with one image per definition the root's own pins would
        // be measured instead of reclamation. The repetition
        // lives inside one unit, so the measurement sees image and
        // registration retention rather than the per-unit source provenance
        // every session accumulates.
        const cycle = "[] ((1) `bump def) `reuse-left @defm " ++
            "[] ((1) `bump def) `reuse-right @defm " ++
            "[] (reuse-left.bump) @spawn " ++
            "[] ((1) `bump def) `reuse-left @defm " ++
            "task.await pop [] (reuse-right.bump) @spawn task.await pop " ++
            "`reuse-left undefm `reuse-right undefm";
        // Both batches are one unit each and differ only in the cycle count,
        // so their fixed per-unit costs cancel and the only variable is how
        // many define/reload/remove cycles ran. Ten times the
        // cycles must not cost ten times the settled memory.
        const small = "[1] 20 take (pop " ++ cycle ++ ") for";
        const large = "[1] 200 take (pop " ++ cycle ++ ") for";
        try expectOk(&runtime, small);
        const before_small = counting.total_requested_bytes;
        try expectOk(&runtime, small);
        const after_small = counting.total_requested_bytes;
        try expectOk(&runtime, large);
        const after_large = counting.total_requested_bytes;
        const small_growth = after_small -| before_small;
        const large_growth = after_large -| after_small;
        try std.testing.expect(large_growth <= small_growth * 2 + 4096);
        try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

// Formatter output is a documented artifact contract, so the navigation
// header is asserted as output rather than by reading the formatter's source.
// The runtime claim below is registration behaviour: every embedded module must
// actually register its own canonical name. The
// *spelling* has no runtime consequence and is therefore build tooling's job —
// `zig build check-ecl` reads each standard module's parsed top-level forms and
// requires the terminal one to be the word `@defm`.
test "module sources: formatter and standard modules use @defm" {
    // A registration earns a navigation header.
    const registration = try formatter.format(std.testing.allocator, "[] ((1) `x def) `stats @defm\n");
    defer std.testing.allocator.free(registration);
    try std.testing.expectEqualStrings(
        "### module stats\n[] (\n    ### def x\n    (1) `x def) `stats @defm\n",
        registration,
    );
    const seeded = try formatter.format(
        std.testing.allocator,
        "[[0]] ((1 +) `tick def) `counter @defm\n",
    );
    defer std.testing.allocator.free(seeded);
    try std.testing.expectEqualStrings(
        "### module counter\n[[0]] (\n       ### def tick\n       (1 +) `tick def) `counter @defm\n",
        seeded,
    );

    // Every embedded standard module is registration-driven, enumerated from
    // the manifest rather than by hand so a new module is covered the day it
    // ships. A module whose source registered nothing under its own name would
    // make `import` report that it registered nothing under the requested name.
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    for (stdlib.names(), support.stdlib_exports) |name, qualified| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "`{s} ({s}) import",
            .{ name, qualified[name.len + 1 ..] },
        );
        defer std.testing.allocator.free(source);
        expectOk(&runtime, source) catch |failed| {
            std.log.err("embedded module {s} did not register its own name", .{name});
            return failed;
        };
    }
    // And their words run, one per source-transport module.
    try expectStack(&runtime, "`io error.new error.valid?", "1");
    try expectStack(&runtime, "[1] result.ok result.ok?", "1");
    try expectStack(&runtime, "\"ab\" str.upper", "\"AB\"");
    try expectStack(&runtime, "[\"n\"] [[1] [2]] table.from-rows table.height", "2");
    try expectStack(&runtime, "[7 0] 6 rand.int nip type", "int");
}

test "module values: a pushed quotation resolves in the image it was written in" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // `(k)` is written inside the module, so it resolves in that image's chain
    // rather than wherever the caller applies it. The session has no `k` at
    // all, which is what makes the label load-bearing here.
    try expectOk(&runtime, "[] ((1) `k def ((k)) `q def) `holding @defm holding.q `held set");
    try expectStack(&runtime, "held call", "1");
}

test "module values: an escaped quotation names the image it was written in" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // A word written in a module body names that image. A quotation that
    // escaped it goes on meaning what it meant, for as long as anything still
    // holds the image -- redefinition reaches only future calls; existing code
    // retains its meaning.
    try expectOk(&runtime, "[] ((1) `k def ((k)) `q def) `held-name @defm held-name.q `held set");
    try expectStack(&runtime, "held call", "1");

    // Replacing the name publishes a new image. Fresh calls through the name
    // get the new code, which is the whole of what the REPL needs.
    try expectOk(&runtime, "[] ((2) `k def ((k)) `q def) `held-name @defm");
    try expectStack(&runtime, "held-name.q call", "2");

    // The quotation held from the replaced generation is not re-pointed to the
    // new image. Once nothing holds the old one, applying it says so rather
    // than silently changing meaning.
    try expectErrorContains(&runtime, "held call", &.{ "kind domain", "retired" });

    // Removal ends it the same way.
    try expectOk(&runtime, "[] ((1) `k def ((k)) `q def) `going @defm going.q `escaped set");
    try expectStack(&runtime, "escaped call", "1");
    try expectOk(&runtime, "`going undefm");
    try expectErrorContains(&runtime, "escaped call", &.{ "kind domain", "retired" });
}

test "module values: an escaped locals body rejects a retired scope through its words" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    try expectOk(&runtime, "[] ((1 +) `inc def ((|x| x inc)) `q def ((|x| x)) `r def) `lowered-owner @defm " ++
        "lowered-owner.q `held set lowered-owner.r `plain set");
    try expectStack(&runtime, "7 held call", "8");
    try expectOk(&runtime, "[] ((0) `q def) `lowered-owner @defm");
    // The body's own word names the retired image.
    try expectErrorContains(&runtime, "7 held call", &.{ "kind domain", "retired" });
    // Locals alone name nothing in the image.
    try expectStack(&runtime, "7 plain call", "7");
}
