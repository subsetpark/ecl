//! Module lifecycle: optional source annotations, construction seeds,
//! namespaced lookup, the `core` qualifier, `execute`, auto-loading, hot
//! reload, including reload racing calls and the memory bound across
//! construct/reload churn. Tests carrying
//! the `concurrency: ` prefix enter `test-workers` (1 and 8) and `test-tsan`
//! through build-file name routing; the rest run in the ordinary suite.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const test_heap = @import("test_heap.zig");
const session = @import("../session.zig");

test "concurrency: map artifact auto-loads converge through one loading lease" {
    var fixture = try ConcurrentMapFixture.init();
    defer fixture.deinit();
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
        .initial_cwd = fixture.nested,
    }), .{ .worker_pool = 8 }, .evaluate);
    defer runtime.deinit();
    try expectStack(
        &runtime,
        "[1 2 3 4 5 6 7 8] (race.answer) @each",
        "[42 42 42 42 42 42 42 42]",
    );
}

const ConcurrentMapFixture = struct {
    directory: std.testing.TmpDir,
    root: [:0]u8,
    nested: []u8,

    fn init() !ConcurrentMapFixture {
        const allocator = std.testing.allocator;
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const root = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(root);
        try directory.dir.createDir(std.testing.io, "project", .default_dir);
        try directory.dir.createDir(std.testing.io, "project/nested", .default_dir);
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/ecl.modules",
            .data = "{format 1 local \"root\" scopes {\"root\" {root \".\" visible [] sources [] artifacts [{path \"race.ecl\" kind ecl exports [\"race\"]}]}}}",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/race.ecl",
            .data = "((pop 42) `answer def) `race @defm\n",
        });
        const nested = try std.fs.path.join(allocator, &.{ root, "project", "nested" });
        errdefer allocator.free(nested);
        return .{ .directory = directory, .root = root, .nested = nested };
    }

    fn deinit(self: *ConcurrentMapFixture) void {
        const allocator = std.testing.allocator;
        allocator.free(self.nested);
        allocator.free(self.root);
        self.directory.cleanup();
    }
};

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("module-lifecycle-test.ecl", source)) {
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

fn expectErrorContains(runtime: *session.Session, source: []const u8, needles: []const []const u8) !void {
    const failure = switch (try runtime.runUnit("module-lifecycle-test.ecl", source)) {
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

/// Run one source and assert the values it left, then drain them: the
/// session stack persists across submissions, so every assertion here starts
/// from an empty stack and leaves one behind.
fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    try expectOk(runtime, source);
    {
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings(expected, display.bytes());
    }
    while (runtime.stackItems().len != 0) try expectOk(runtime, "pop");
}

test "definitions: module def and defp accept all four annotation forms" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // All four forms register, publicly and privately, and each word runs.
    try expectOk(&runtime, "(" ++
        "(1 +) `bare def " ++
        "( n -- n ) (2 *) `effected def " ++
        "( : \"Subtract three.\" ) (3 -) `documented def " ++
        "( n -- n : \"Divide by four.\" ) (4 div) `complete def " ++
        "(dup +) `hidden defp " ++
        "(hidden 1 +) `via-private def" ++
        ") `forms @defm");
    try expectStack(
        &runtime,
        "10 forms.bare 10 forms.effected 10 forms.documented 12 forms.complete 10 forms.via-private",
        "11 20 7 3 21",
    );
    // Reflection preserves exactly which annotation portions were supplied;
    // documentation is also available separately through `doc`.
    try expectOk(&runtime, "`forms.bare see `forms.effected see " ++
        "`forms.documented see `forms.complete see");
    try std.testing.expectEqualStrings(
        "(1 +)\n" ++
            "(n -- n) (2 *)\n" ++
            "(: \"Subtract three.\") (3 -)\n" ++
            "(n -- n : \"Divide by four.\") (4 div)\n",
        output.written(),
    );
    try expectStack(&runtime, "`forms.documented doc", "\"Subtract three.\"");
    try expectErrorContains(&runtime, "`forms.bare doc", &.{ "kind domain", "documentation" });
    // A supplied effect stays a live cross-home contract; omitting one adds
    // no inferred check, so a word leaving two values crosses unimpeded.
    try expectErrorContains(
        &runtime,
        "(( -- n ) (1 2) `two def) `liar @defm liar.two",
        &.{ "kind contract", "word liar.two", "declared (0 -- 1)" },
    );
    try expectStack(&runtime, "((1 2) `two def) `quiet @defm quiet.two", "1 2");
    // Malformed recognized annotations remain 'domain in a module root.
    try expectErrorContains(
        &runtime,
        "(( : ) (3) `bad def) `broken @defm",
        &.{ "kind domain", "malformed definition annotation" },
    );
}

test "definitions: set and setp publish exact captures without synthesized metadata" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // The equivalence is exact in the body and in the absent metadata: both
    // spellings expose the same capture body.
    try expectStack(
        &runtime,
        "42 `answer set 42 wrap `spelled def answer spelled match?",
        "1",
    );
    try expectOk(&runtime, "`answer see `spelled see `answer which");
    try std.testing.expectEqualStrings(
        "[42]\n" ++
            "[42]\n" ++
            "answer -> answer def public\n",
        output.written(),
    );
    try expectErrorContains(&runtime, "`answer doc", &.{ "kind domain", "documentation" });
    // `setp` carries the same simplification into a module root, where the
    // published constant needs no effect declaration to register.
    try expectOk(&runtime, "(7 `x set 8 `h setp (h) `peek def) `m @defm");
    try expectStack(&runtime, "m.x m.peek", "7 8");
    output.clearRetainingCapacity();
    try expectOk(&runtime, "`m.x see");
    try std.testing.expectEqualStrings("[7]\n", output.written());
}

test "modules: *module* reports the running module's name" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // Two modules built from the same body report their own names.
    try expectStack(
        &runtime,
        "((*module*) `name def) `left @defm ((*module*) `name def) `right @defm " ++
            "left.name right.name",
        "left right",
    );
    // An alias resolves to its module, so the call reports that module's
    // name rather than the spelling used at the call site.
    try expectStack(&runtime, "`short `left alias short.name", "left");

    // The root has no home and therefore no module name to manufacture.
    try expectErrorContains(&runtime, "*module*", &.{
        "kind domain",
        "registered module",
    });
    // A construction body already knows the name it is being built under:
    // `*module*` answers, and the value it leaves is what the body refuses.
    try expectErrorContains(&runtime, "(*module*) `building @defm", &.{
        "kind domain",
        "left 1 value",
    });
    try expectOk(&runtime, "((*module*) `name set) `escaped @defm");
    try expectErrorContains(&runtime, "escaped.name call", &.{
        "kind domain",
        "registered module",
    });
}

test "modules: a qualified call reaches the reloaded module" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // `via` resolves `m.x` each time it runs, so a reload reaches it as it
    // reaches an explicit lookup.
    try expectOk(&runtime, "((1) `x def) `m @defm (m.x) `via def");
    try expectStack(&runtime, "via", "1");
    try expectStack(&runtime, "((2) `x def) `m @defm via m.x", "2 2");
    try expectStack(&runtime, "((3) `x def) `m @defm via `m.x execute", "3 3");
}

test "modules: dotted names qualify dynamically and split executable words at the final dot" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "((1) `utils def) `base @defm");
    try expectOk(&runtime, "((41) `f def (42) `g def) `base.utils @defm");
    try expectStack(&runtime, "base.utils base.utils.f", "1 41");
    try expectStack(&runtime, "`base.utils `f qualify dup type swap execute", "symbol 41");
    try expectStack(&runtime, "`base.utils 1 (`f) (`g) if qualify execute", "41");
    try expectOk(&runtime, "`utils `base.utils alias");
    try expectStack(&runtime, "utils.g", "42");
    try expectOk(&runtime, "`base.utils (g) import");
    try expectStack(&runtime, "g", "42");
    try expectOk(&runtime, "((43) `f def) `base.utils @defm");
    try expectStack(&runtime, "base.utils.f `base.utils `f qualify execute", "43 43");
    try expectOk(&runtime, "((44) `f def) `base.utils @defm");
    try expectStack(&runtime, "base.utils.f", "44");
}

test "modules: core qualifier reaches shadowed core words and is never a registration" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(&runtime, "1 core.dup", "1 1");
    try expectOk(&runtime, "(2 *) `dup def");
    try expectStack(&runtime, "3 dup 3 core.dup", "6 3 3");
    try expectStack(&runtime, "`core `dup qualify 4 swap execute", "4 4");
    // A module whose own export shadows a core word reaches the original
    // through the qualifier, which is the case the standard library needs.
    try expectOk(&runtime, "((pop `shadowed) `where def ([0 1 1] core.where) `indices def) `shadow.host @defm");
    try expectStack(&runtime, "shadow.host.indices", "[1 2]");
    try expectStack(&runtime, "7 shadow.host.where", "shadowed");
    try expectErrorContains(&runtime, "core.no-such-binding", &.{ "kind undefined-word", "scope core" });
    // Core is a scope, not a registration: nothing may publish under its name
    // as a module or an alias, and it is not a module to
    // alias or import from.
    try expectErrorContains(&runtime, "() `core @defm", &.{ "kind domain", "reserved for the core qualifier" });
    try expectErrorContains(&runtime, "`core `shadow.host alias", &.{ "kind domain", "reserved for the core qualifier" });
    try expectErrorContains(&runtime, "`short `core alias", &.{ "kind undefined-word", "undefined module `core`" });
    try expectErrorContains(&runtime, "`core (dup) import", &.{ "kind undefined-word", "scope qualified" });
    // The reservation is the whole name, not a segment: a dotted name under it
    // registers, resolves, and qualifies like any other module.
    try expectOk(&runtime, "((1) `f def) `core.utils @defm");
    try expectStack(&runtime, "core.utils.f `core.utils `f qualify execute", "1 1");
    try expectStack(&runtime, "1 core.dup", "1 1");
}

test "modules: execute preserves ordinary dispatch home contracts and errors" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "((3) `secret defp (secret 4 +) `f def) `private.home @defm");
    try expectStack(&runtime, "`private.home `f qualify execute", "7");
    try expectOk(&runtime, "((5) `five def (1 +) `inc def) `other.home @defm");
    try expectStack(
        &runtime,
        "`other.home `five qualify execute `other.home `inc qualify execute",
        "6",
    );
    try expectStack(&runtime, "3 (dup) first execute", "3 3");
    try expectErrorContains(&runtime, "`missing.home `f qualify execute", &.{
        "kind undefined-word",
        "missing.home.f",
    });
    try expectOk(&runtime, "(n -- n) (1 +) `annotated def");
    try expectErrorContains(&runtime, "(annotated) first execute", &.{ "kind underflow", "annotated" });
}

test "modules: removed identity builtin has no reservation and names validate by category" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    for ([_][]const u8{ "() `.bad @defm", "() `bad. @defm", "() `bad..path @defm" }) |source|
        try expectErrorContains(&runtime, source, &.{"kind parse"});
    try expectErrorContains(&runtime, "() 1 @defm", &.{"kind type"});
    try expectErrorContains(&runtime, "`x 1 import", &.{"kind type"});
    try expectErrorContains(&runtime, "((1) `bad.name def) `core.utils @defm", &.{"kind domain"});
    try expectErrorContains(&runtime, "1 `f qualify", &.{"kind type"});
    try expectErrorContains(&runtime, "`core.utils 1 qualify", &.{"kind type"});
    try expectErrorContains(&runtime, "`core..utils `f qualify", &.{"kind parse"});
    try expectErrorContains(&runtime, "`core.utils `bad.name qualify", &.{"kind domain"});
    try expectErrorContains(&runtime, "`core.utils `-- qualify", &.{"kind domain"});
    try expectErrorContains(&runtime, "1 execute", &.{"kind type"});
}

const churn_cycle = "((\"a module string\" [1 2 3] {k v}) `peek def) `churn @defm " ++
    "`churn.peek execute pop pop pop";

test "concurrency: repeated construct reload cycles grow no faster than registrations" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
        defer runtime.deinit();
        // Both batches run as one fiber each and differ by a single source
        // character, so their fixed per-fiber costs are the same and the only
        // variable is how many construct/reload cycles ran. A Session keeps
        // every published image, so ten times the cycles may cost ten times
        // the retained images, and no more.
        const small = "[1] 20 take (pop " ++ churn_cycle ++ ") for";
        const large = "[1] 200 take (pop " ++ churn_cycle ++ ") for";
        try expectStack(&runtime, small, "");
        const before_small = counting.total_requested_bytes;
        try expectStack(&runtime, small, "");
        const after_small = counting.total_requested_bytes;
        try expectStack(&runtime, large, "");
        const after_large = counting.total_requested_bytes;
        // Both batches are sampled live, so retirement landing between two
        // reads can leave the second below the first. A smaller footprint is
        // not a regression, but unsigned subtraction turned it into an
        // integer-overflow panic rather than a verdict, which is how this
        // read as a failure on one CI run and passed on the next with the
        // same code. Saturate, and report what was seen when the bound is
        // actually exceeded so a recurrence arrives with its numbers.
        const small_growth = after_small -| before_small;
        const large_growth = after_large -| after_small;
        std.testing.expect(large_growth <= small_growth * 10 * 2 + 4096) catch |err| {
            std.debug.print(
                "settled memory: before={d} after_small={d} after_large={d} " ++
                    "small_growth={d} large_growth={d}\n",
                .{ before_small, after_small, after_large, small_growth, large_growth },
            );
            return err;
        };
    }
    try std.testing.expect(counting.deinit() == .ok);
}

test "concurrency: applying an escaped quotation races reload" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // A quotation that escaped `racer` names the image it was written in, and
    // spawned tasks bind and apply it while a concurrent `@defm` replaces that
    // image. The Session keeps the replaced image, so each task resolves the
    // escaped words against it while the registry publishes the new one.
    //
    // Named into the `concurrency:` tier so it runs under ThreadSanitizer and
    // at eight workers. The assertions are deliberately weak: failures stay
    // inside the envelope and the runtime keeps progressing; TSan and the
    // allocator are what should speak here.
    try expectOk(&runtime, "((1) `k def ((k)) `q def) `racer @defm racer.q `held set");
    try expectOk(&runtime, "[1] 24 take (pop ((held call) @attempt) @spawn) each " ++
        "((2) `k def ((k)) `q def) `racer @defm " ++
        "(task.await) each pop");
}

// The `concurrency:` prefix is load-bearing: the TSan and 8-worker tiers
// select on it.

test "concurrency: escaped quotations keep running old code across a concurrent reload" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 4 }, .evaluate);
        defer runtime.deinit();
        // The quotation escapes its module, so its words are linked to the
        // image it was written in. Tasks bind and apply it while a reload
        // replaces that image; the Session keeps the replaced image, so every
        // task runs the old code, and the allocator checks that nothing the
        // reload published or retired leaks.
        try expectOk(
            &runtime,
            "((1) `k def ((k)) `q def) `goner @defm goner.q `gone set",
        );
        try expectStack(
            &runtime,
            "[1] 64 take (pop ((gone call) @attempt) @spawn) each " ++
                "((2) `k def ((k)) `q def) `goner @defm (task.await) each pop",
            "",
        );
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "concurrency: a reload that drops a word leaves escaped quotations running old code" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 4 }, .evaluate);
        defer runtime.deinit();
        // The reload drops `q`, while tasks are still applying a quotation
        // written in the old image. The Session keeps that image, so its words
        // still resolve there.
        try expectOk(
            &runtime,
            "((1) `k def ((k)) `q def) `reloaded @defm reloaded.q `held set",
        );
        try expectStack(
            &runtime,
            "[1] 64 take (pop ((held call) @attempt) @spawn) each " ++
                "((2) `k def) `reloaded @defm (task.await) each pop",
            "",
        );
        // The replacement is what callers now reach; the escaped quotation went
        // on meaning what it meant, for as long as anything held it.
        try expectStack(&runtime, "reloaded.k", "2");
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}
