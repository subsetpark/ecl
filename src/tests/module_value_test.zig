//! Post-terminal Step 15: anonymous module values.
//!
//! `@module` is `(body -- module)` and constructs an anonymous immutable
//! module image; `register` gives an image a canonical name and owns that
//! registration's durable live state; `@defm` is exactly their composition.
//! Every test here pins one publicly observable clause of that contract
//! through the ordinary `Session` interface — no accessor exposes
//! `ModuleImage`, `RegistrationHome`, `ModuleSlot`, `Environment`, or any
//! registry internal.
const std = @import("std");
const formatter = @import("../formatter.zig");
const session = @import("../session.zig");
const stdlib = @import("../stdlib.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("module-value-test.ecl", source)) {
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
    const failure = switch (try runtime.runUnit("module-value-test.ecl", source)) {
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

/// The rendered failure of one source, so two spellings can be compared as
/// whole error values rather than through a hand-listed set of needles.
fn renderFailure(
    runtime: *session.Session,
    buffer: *std.ArrayList(u8),
    source: []const u8,
) ![]const u8 {
    const failure = switch (try runtime.runUnit("module-value-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    buffer.clearRetainingCapacity();
    try buffer.appendSlice(std.testing.allocator, rendered.bytes());
    return buffer.items;
}

test "module values: @module constructs an anonymous value without registering a name" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // One value, opaque, of type 'module.
    try expectStack(&runtime, "(1 'x set) @module", "<module>");
    try expectStack(&runtime, "(1 'x set) @module type", "'module");

    // Construction publishes nothing: the body's own names stay inside the
    // image rather than leaking into the caller's environment.
    try expectErrorContains(&runtime, "x", &.{ "'kind 'undefined-word", "'name 'x" });

    // Nor does it claim a registry name. The same retained image becomes
    // reachable under a canonical name only once `register` says so.
    try expectOk(&runtime, "((7) 'v def) @module 'image set");
    try expectErrorContains(&runtime, "later.v", &.{ "'kind 'undefined-word", "'name 'later.v" });
    try expectOk(&runtime, "image 'later register");
    try expectStack(&runtime, "later.v", "7");
}

test "module values: type display identity and capability boundaries are opaque" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // Identity is the image, not its content: one construction duplicated
    // matches itself, and two constructions of the same body never match.
    try expectStack(&runtime, "(1) @module dup match?", "1");
    try expectStack(&runtime, "(1) @module (1) @module match?", "0");

    // Structural equality of a container carrying the value agrees, and never
    // traverses into the image's environment or state template.
    try expectStack(&runtime, "(1) @module dup () cons swap () cons match?", "1");
    try expectStack(&runtime, "(1) @module () cons (1) @module () cons match?", "0");

    // The printed marker carries no address, name, or state, and it is not
    // readable source.
    try expectStack(&runtime, "(1) @module str", "\"<module>\"");
    try expectErrorContains(&runtime, "\"<module>\" parse", &.{
        "'kind 'parse",
        "runtime-only",
    });

    // Serialization refuses the capability with its ordinary total error.
    try expectErrorContains(&runtime, "(1) @module json.emit", &.{
        "'kind 'type",
        "'word 'json.emit",
    });

    // Native scalar and view conversion reject module capabilities too; that
    // boundary is proven against the loaded sample module in
    // `src/tests/native_test.zig`, which owns the fixture.
}

test "module registration: one image registered twice owns independent durable state" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "(0 ((1 + dup without) within) 'bump def) @module dup 'left register 'right register",
    );
    try expectEmptyStack(&runtime);

    // Shared immutable code, independent durable stacks.
    try expectStack(&runtime, "left.bump left.bump right.bump", "1 2 1");

    // Removing one registration retires only that slot.
    try expectOk(&runtime, "'left unmodule");
    try expectStack(&runtime, "right.bump", "2");
    try expectErrorContains(&runtime, "left.bump", &.{ "'kind 'undefined-word", "'name 'left.bump" });

    // And reloading one does not disturb the other's state.
    try expectOk(&runtime, "(0 ((100 + dup without) within) 'bump def) @module 'right register");
    try expectStack(&runtime, "right.bump", "102");
}

test "module registration: reload preserves slot state and discards the image template" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    try expectOk(&runtime, "(0 ((1 + dup without) within) 'bump def) 'counter @defm");
    try expectStack(&runtime, "counter.bump counter.bump", "1 2");

    // Replacement installs new code over the state the slot already owns, and
    // this image's own template is not consulted for that slot.
    try expectOk(&runtime, "(99 ((10 + dup without) within) 'bump def) @module 'counter register");
    try expectStack(&runtime, "counter.bump", "12");

    // The template is the image's property, not the slot's: the same image
    // still seeds a *fresh* registration from 99.
    try expectOk(&runtime, "(99 ((10 + dup without) within) 'bump def) @module 'fresh register");
    try expectStack(&runtime, "fresh.bump", "109");
}

test "module registration: @defm is construction followed by registration" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    var left: std.ArrayList(u8) = .empty;
    defer left.deinit(std.testing.allocator);
    var right: std.ArrayList(u8) = .empty;
    defer right.deinit(std.testing.allocator);

    // Ordinary bodies: same definitions, same durable state, same stack.
    try expectOk(&runtime, "(0 ((1 + dup without) within) 'bump def) 'combined @defm");
    try expectOk(&runtime, "(0 ((1 + dup without) within) 'bump def) @module 'composed register");
    try expectEmptyStack(&runtime);
    try expectStack(&runtime, "combined.bump composed.bump", "1 1");

    // A `with`-seeded construction stack behaves identically under both
    // spellings, including as the registration's initial durable state.
    try expectOk(&runtime, "[4 5] (+ 'sum set) with 'seeded-combined @defm");
    try expectOk(&runtime, "[4 5] (+ 'sum set) with @module 'seeded-composed register");
    try expectStack(&runtime, "seeded-combined.sum seeded-composed.sum", "9 9");

    // A failing body produces the same error and registers nothing either way.
    // Only the reported word differs, because the program wrote a different
    // word; the kind, message, and trace tail are the same.
    const combined_failure = try renderFailure(
        &runtime,
        &left,
        "((1 0 /) call ((2) 'v def)) 'ghost-combined @defm",
    );
    try std.testing.expect(std.mem.indexOf(u8, combined_failure, "'kind 'domain") != null);
    const composed_failure = try renderFailure(
        &runtime,
        &right,
        "((1 0 /) call ((2) 'v def)) @module 'ghost-composed register",
    );
    try std.testing.expectEqualStrings(combined_failure, composed_failure);
    try expectEmptyStack(&runtime);
    try expectErrorContains(&runtime, "ghost-combined.v", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "ghost-composed.v", &.{"'kind 'undefined-word"});

    // An invalid name fails after the body has run in both spellings, so the
    // composition does not silently skip a body the two words would execute.
    try expectErrorContains(&runtime, "((1) 'v def) '-- @defm", &.{
        "'kind 'domain",
        "valid module name",
    });
    try expectEmptyStack(&runtime);
    try expectErrorContains(&runtime, "((1) 'v def) @module '-- register", &.{
        "'kind 'domain",
        "valid module name",
    });
    try expectEmptyStack(&runtime);

    // An alias collision is the same refusal in both spellings.
    try expectOk(&runtime, "((1) 'v def) 'aliased @defm 'short 'aliased alias");
    try expectErrorContains(&runtime, "((2) 'v def) 'short @defm", &.{
        "'kind 'domain",
        "collides with an alias",
    });
    try expectErrorContains(&runtime, "((2) 'v def) @module 'short register", &.{
        "'kind 'domain",
        "collides with an alias",
    });
    try expectEmptyStack(&runtime);
    try expectStack(&runtime, "aliased.v", "1");

    // Re-registration from inside a state application is refused identically:
    // the initiating unit already holds one slot's turn.
    try expectOk(&runtime, "((0) 'v def) 'reloaded @defm");
    try expectErrorContains(
        &runtime,
        "(0 ((((1) 'v def) 'reloaded @defm) within) 'go def) 'host-combined @defm host-combined.go",
        &.{ "'kind 'domain", "inside a state application" },
    );
    try expectErrorContains(
        &runtime,
        "(0 ((((1) 'v def) @module 'reloaded register) within) 'go def) " ++
            "'host-composed @defm host-composed.go",
        &.{ "'kind 'domain", "inside a state application" },
    );
    try expectStack(&runtime, "reloaded.v", "0");
}

test "module registration: invocation context comes from the registration" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();

    try expectOk(&runtime, "(" ++
        "0 ((1 + dup without) within) 'tick defp " ++
        "(tick) 'bump def " ++
        "('bump which) 'report def " ++
        "( -- n ) (1 2) 'liar def " ++
        "(liar) 'same-home def" ++
        ") @module dup 'left register 'right register");
    try expectEmptyStack(&runtime);

    // A private word reached through a public one sees the state of the
    // registration the call entered through, not of the last one registered.
    try expectStack(&runtime, "left.bump left.bump right.bump", "1 2 1");

    // Reflection reports the invoking registration's spelling and generation.
    try expectOk(&runtime, "right.report left.report");
    try std.testing.expectEqualStrings(
        "bump -> right.bump def public generation 1\n" ++
            "bump -> left.bump def public generation 1\n",
        output.written(),
    );

    // A declared effect is a cross-home contract, and its diagnostic names the
    // registration that was called.
    try expectErrorContains(&runtime, "right.liar", &.{ "'kind 'contract", "'word 'right.liar" });
    try expectErrorContains(&runtime, "left.liar", &.{ "'kind 'contract", "'word 'left.liar" });

    // The same call from inside the image is same-home, so no contract check
    // applies and both registrations agree.
    try expectStack(&runtime, "left.same-home", "1 2");
    try expectStack(&runtime, "right.same-home", "1 2");
}

test "module registration: a diagnostic spells the same word its failure reports" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // A module-local word has no interned qualified spelling, so a message
    // renders one into a scratch buffer while the `word` field is interned
    // separately. The two must never name *different* words: for an image
    // registered under several names, the unqualified atom alone would not say
    // which registration failed. A name long enough to exhaust the scratch is
    // the case that used to substitute it.
    const long = "m" ** 330;
    const source = "(( -- n ) (1 2) 'two def) '" ++ long ++ " @defm " ++ long ++ ".two";
    const failure = switch (try runtime.runUnit("module-value-test.ecl", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.ExpectedLanguageError,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    const qualified = long ++ ".two";
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), "'word '" ++ qualified) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), "\"" ++ qualified ++ " declared") != null);
    // And the unqualified atom never stands in for it.
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), "\"two declared") == null);
}

test "module registration: failures leave prior registrations atomic and ownership total" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    // A failing construction body publishes neither a value nor a name.
    try expectErrorContains(&runtime, "((1 0 /) call) @module", &.{"'kind 'domain"});
    try expectEmptyStack(&runtime);

    // A failing registration leaves the prior directory entry, generation, and
    // durable state exactly as they were, and consumes the module reference it
    // was handed.
    try expectOk(&runtime, "(0 ((1 + dup without) within) 'bump def) 'kept @defm");
    try expectStack(&runtime, "kept.bump", "1");
    try expectOk(&runtime, "'kept-alias 'kept alias");
    try expectErrorContains(&runtime, "((2) 'bump def) @module 'kept-alias register", &.{
        "'kind 'domain",
        "collides with an alias",
    });
    try expectEmptyStack(&runtime);
    try expectStack(&runtime, "kept.bump", "2");

    // The retained image survives a failed registration and is still usable.
    try expectOk(&runtime, "((5) 'v def) @module 'retained set");
    try expectErrorContains(&runtime, "retained 'kept-alias register", &.{
        "'kind 'domain",
        "collides with an alias",
    });
    try expectOk(&runtime, "retained 'accepted register");
    try expectStack(&runtime, "accepted.v", "5");

    // A non-module operand is a type error, not a registry mutation.
    try expectErrorContains(&runtime, "1 'rejected register", &.{ "'kind 'type", "'word 'register" });
    try expectEmptyStack(&runtime);
    try expectErrorContains(&runtime, "rejected.v", &.{"'kind 'undefined-word"});
}

test "module values: invoke calls a public export of a nameless image" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // An image reached as a value supports exactly one operation, because it
    // has no name for anything else to key on.
    try expectStack(&runtime, "((7) 'answer def) @module 'answer invoke", "7");
    // A public reaches its own privates, on the same terms as a registered
    // call: the home is the image either way.
    try expectStack(&runtime, "((41) 'secret defp (secret 1 +) 'go def) @module 'go invoke", "42");
    // Lookup is public-only, so a private is as absent as a missing name.
    try expectErrorContains(&runtime, "((7) 'hidden defp) @module 'hidden invoke", &.{
        "'kind 'undefined-word",
        "'word 'hidden",
    });
    try expectErrorContains(&runtime, "((7) 'answer def) @module 'nope invoke", &.{
        "'kind 'undefined-word",
        "'word 'nope",
    });
    try expectErrorContains(&runtime, "1 'answer invoke", &.{ "'kind 'type", "'word 'invoke" });
    try expectErrorContains(&runtime, "((7) 'answer def) @module 'not.unqualified invoke", &.{
        "'kind 'domain",
        "unqualified binding name",
    });
}

test "module values: a nameless image is stateless and traces its bare local" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // No registration means no slot, so `within` is refused exactly as it is
    // for a construction root. State belongs to a registration.
    try expectErrorContains(&runtime, "(0 ((1 + dup without) within) 'bump def) @module 'bump invoke", &.{
        "'kind 'domain",
        "within is legal only in a published module word",
    });
    // The same image registered has a slot and the same word works.
    try expectStack(&runtime, "(0 ((1 + dup without) within) 'bump def) @module 'counter register counter.bump", "1");
    // A nameless image has no canonical spelling, so a failure inside it
    // traces the bare local name rather than borrowing one it does not have.
    try expectErrorContains(&runtime, "((missing) 'boom def) @module 'boom invoke", &.{
        "'trace ['missing 'boom]",
    });
    try expectErrorContains(&runtime, "((missing) 'boom def) 'named @defm named.boom", &.{
        "'trace ['missing 'named.boom]",
    });
}

test "module values: a construction can be parameterized by another module" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // The dependency crosses the boundary as an ordinary seeded value and is
    // called through its handle, so which implementation is used is the
    // caller's decision rather than a global registry fact.
    try expectStack(
        &runtime,
        "((2 *) 'scale def) @module wrap ('dep set (4 dep 'scale invoke) 'go def) with 'doubling @defm doubling.go",
        "8",
    );
    try expectStack(
        &runtime,
        "((10 *) 'scale def) @module wrap ('dep set (4 dep 'scale invoke) 'go def) with 'tenfold @defm tenfold.go",
        "40",
    );
    // Two images exporting the same name coexist, which a registry keyed by
    // name cannot represent.
    try expectStack(&runtime, "doubling.go tenfold.go", "8 40");
}

test "module loader: observation and dispatch require the requested registration" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = "test/acceptance/modules",
    });
    defer runtime.deinit();

    // Literal and dynamically qualified dispatch both auto-load with no prior
    // import, and neither cares which spelling the file used to register the
    // requested name.
    try expectStack(&runtime, "'stats 'answer qualify execute", "42");
    try expectStack(&runtime, "register-style.answer", "7");

    // `import` reaches the same registration through the same path.
    try expectStack(&runtime, "'register-style.answer 'answer import answer", "7");

    // A file that constructs an anonymous image but registers nothing still
    // fails with the existing total loader error.
    try expectErrorContains(&runtime, "image-only.answer", &.{
        "'kind 'io",
        "registered nothing under that name",
        "'path \"test/acceptance/modules/image-only.ecl\"",
    });
    try expectErrorContains(&runtime, "'image-only.answer 'answer import", &.{
        "'kind 'io",
        "registered nothing under that name",
        "'path \"test/acceptance/modules/image-only.ecl\"",
    });

    // Observation is registration-driven because it is *symbol*-driven:
    // `which`, `see`, and `doc` all consume a name, and a name is exactly what
    // a registration is. Invocation also accepts a module value — see
    // `module values: invoke calls a public export of a nameless image` — and
    // that path has no name for these words to take. `see` renders the stored
    // body, which is how one binding kind stays observable without any
    // operation that lifts a body out of its home.
    output.clearRetainingCapacity();
    try expectOk(&runtime, "'register-style.answer see");
    try std.testing.expectEqualStrings(
        "### def register-style.answer\n([7] first) 'register-style.answer def\n",
        output.written(),
    );
}

test "module registration: reuse reload removal and delayed calls reclaim boundedly" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
        defer runtime.deinit();

        // One construction, two registrations, a reload of the shared image
        // while a delayed call holds the superseded generation, then removal of
        // both names. The repetition lives inside one unit, so the measurement
        // sees image and registration retention rather than the per-unit source
        // provenance every session accumulates.
        const cycle = "(0 ((1 + dup without) within) 'bump def) @module " ++
            "dup 'reuse-left register " ++
            "dup 'reuse-right register " ++
            "(reuse-left.bump) @spawn " ++
            "swap 'reuse-left register " ++
            "await pop reuse-right.bump pop " ++
            "'reuse-left unmodule 'reuse-right unmodule";
        // Both batches are one unit each and differ only in the cycle count,
        // so their fixed per-unit costs cancel and the only variable is how
        // many construct/register/reload/remove cycles ran. Ten times the
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
// actually register its own canonical name, whichever spelling it used. The
// *spelling* has no runtime consequence and is therefore build tooling's job —
// `zig build check-ecl` reads each standard module's parsed top-level forms and
// requires the terminal one to be the word `@defm`.
test "module sources: formatter and standard modules use @defm" {
    // A registration earns a navigation header; anonymous construction, which
    // names nothing, is an ordinary expression.
    const registration = try formatter.format(std.testing.allocator, "((1) 'x def) 'stats @defm\n");
    defer std.testing.allocator.free(registration);
    try std.testing.expectEqualStrings(
        "### module stats\n(\n ### def x\n (1) 'x def) 'stats @defm\n",
        registration,
    );
    const seeded = try formatter.format(
        std.testing.allocator,
        "[[0]] ((1 +) 'tick def) with 'counter @defm\n",
    );
    defer std.testing.allocator.free(seeded);
    try std.testing.expectEqualStrings(
        "### module counter\n[[0]]\n(\n ### def tick\n (1 +) 'tick def) with 'counter @defm\n",
        seeded,
    );
    const anonymous = try formatter.format(std.testing.allocator, "((1) 'x def) @module\n");
    defer std.testing.allocator.free(anonymous);
    try std.testing.expectEqualStrings("(\n ### def x\n (1) 'x def)\n@module\n", anonymous);

    // Every embedded standard module is registration-driven, enumerated from
    // the manifest rather than by hand so a new module is covered the day it
    // ships. A module whose source ended in a bare `@module` would construct an
    // image the loader discards, and `import` would report that it registered
    // nothing under the requested name.
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const exports = [_][]const u8{
        "error.new",         "result.ok",         "str.upper",
        "io.print",          "csv.parse",         "json.parse",
        "table.valid?",      "http.get-bytes",    "archive.sha256",
        "pkg.store.inspect", "rng.float",         "pkg.version.less?",
        "pkg.name.valid?",   "pkg.data.read-one", "pkg.manifest.read",
        "pkg.lock.read",     "pkg.mvs.resolve",   "pkg.sync.run",
        "pkg.cli.init",
    };
    for (stdlib.names(), exports) |name, qualified| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "'{s} 'local import", .{qualified});
        defer std.testing.allocator.free(source);
        expectOk(&runtime, source) catch |failed| {
            std.log.err("embedded module {s} did not register its own name", .{name});
            return failed;
        };
    }
    // And their words run, one per source-transport module.
    try expectStack(&runtime, "'io error.new error.valid?", "1");
    try expectStack(&runtime, "[1] result.ok result.ok?", "1");
    try expectStack(&runtime, "\"ab\" str.upper", "\"AB\"");
    try expectStack(&runtime, "[\"n\"] [[1] [2]] table.from-rows table.height", "2");
    try expectStack(&runtime, "7 rng.seed 6 rng.int type", "'int");
    try expectStack(
        &runtime,
        "'pkg.store.inspect doc len 0 > 'pkg.store.install doc len 0 > " ++
            "'pkg.store.present? doc len 0 > 'pkg.store.verify doc len 0 > " ++
            "'pkg.store.write-lock doc len 0 >",
        "1 1 1 1 1",
    );
    try expectStack(&runtime, "\"1.2.0\" \"1.10.0\" pkg.version.less?", "1");
}

// PENDING: Patch 5 of `word-scope-identifiers` makes a word resolve at its own
// scope. Flip this to false there; every assertion guarded by it is ticket
// ecl#4's proof and fails today.
const scopes_pending = false;

test "module values: a pushed labelled quotation resolves in the image it was written in" {
    if (scopes_pending) return error.SkipZigTest;
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // `(k)` is written inside the module, so it resolves in that image's chain
    // rather than wherever the caller applies it. The session has no `k` at
    // all, which is what makes the label load-bearing here.
    try expectOk(&runtime, "((1) 'k def ((k)) 'q def) 'holding @defm holding.q 'held set");
    try expectStack(&runtime, "held call", "1");
}

test "module values: applying a quotation whose image is gone is a domain error" {
    if (scopes_pending) return error.SkipZigTest;
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // The cell a label names belongs to the image, so a quotation means what it
    // meant where it was written and stops meaning anything once that image is
    // gone. Both removal and supersession by a reload retire the image, and
    // both are a definite `'domain` rather than a silent fallback to core or to
    // the launcher — a fallback would change what the quotation's words mean.
    try expectOk(&runtime, "((1) 'k def ((k)) 'q def) 'going @defm going.q 'held set");
    try expectStack(&runtime, "held call", "1");
    try expectOk(&runtime, "'going unmodule");
    try expectErrorContains(&runtime, "held call", &.{ "'kind 'domain", "retired" });

    try expectOk(&runtime, "((1) 'k def ((k)) 'q def) 'reloaded @defm reloaded.q 'kept set");
    try expectStack(&runtime, "kept call", "1");
    try expectOk(&runtime, "((2) 'k def ((k)) 'q def) 'reloaded @defm");
    try expectErrorContains(&runtime, "kept call", &.{ "'kind 'domain", "retired" });
    // The name still works: it is the escaped value that stopped resolving, not
    // the module.
    try expectStack(&runtime, "reloaded.q call", "2");
}
