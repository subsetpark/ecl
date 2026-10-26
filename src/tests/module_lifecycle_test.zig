//! Module lifecycle: optional source annotations, construction seeds,
//! namespaced lookup, the `core` qualifier, `execute`, auto-loading, hot
//! reload, and the `unmodule` removal typestate, including removal racing
//! calls and the memory bound across construct/remove churn. Tests carrying
//! the `concurrency: ` prefix enter `test-workers` (1 and 8) and `test-tsan`
//! through build-file name routing; the rest run in the ordinary suite.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
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
        "[1 2 3 4 5 6 7 8] [] (race.answer) @each",
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
            .data = "{'format 1 'local \"root\" 'scopes {\"root\" {'root \".\" 'visible [] 'sources [] 'artifacts [{'path \"race.ecl\" 'kind 'ecl 'exports [\"race\"]}]}}}",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/race.ecl",
            .data = "[] ((pop 42) 'answer def) 'race @defm\n",
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
/// session stack persists across units, so every assertion here starts from
/// an empty stack and leaves one behind.
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
    try expectOk(&runtime, "[] (" ++
        "(1 +) 'bare def " ++
        "( n -- n ) (2 *) 'effected def " ++
        "( : \"Subtract three.\" ) (3 -) 'documented def " ++
        "( n -- n : \"Divide by four.\" ) (4 div) 'complete def " ++
        "(dup +) 'hidden defp " ++
        "(hidden 1 +) 'via-private def" ++
        ") 'forms @defm");
    try expectStack(
        &runtime,
        "10 forms.bare 10 forms.effected 10 forms.documented 12 forms.complete 10 forms.via-private",
        "11 20 7 3 21",
    );
    // Reflection preserves exactly which annotation portions were supplied;
    // documentation is also available separately through `doc`.
    try expectOk(&runtime, "'forms.bare see 'forms.effected see " ++
        "'forms.documented see 'forms.complete see");
    try std.testing.expectEqualStrings(
        "(1 +)\n" ++
            "(n -- n) (2 *)\n" ++
            "(: \"Subtract three.\") (3 -)\n" ++
            "(n -- n : \"Divide by four.\") (4 div)\n",
        output.written(),
    );
    try expectStack(&runtime, "'forms.documented doc", "\"Subtract three.\"");
    try expectErrorContains(&runtime, "'forms.bare doc", &.{ "'kind 'domain", "documentation" });
    // A supplied effect stays a live cross-home contract; omitting one adds
    // no inferred check, so a word leaving two values crosses unimpeded.
    try expectErrorContains(
        &runtime,
        "[] (( -- n ) (1 2) 'two def) 'liar @defm liar.two",
        &.{ "'kind 'contract", "'word 'liar.two", "declared (0 -- 1)" },
    );
    try expectStack(&runtime, "[] ((1 2) 'two def) 'quiet @defm quiet.two", "1 2");
    // Malformed recognized annotations remain 'domain in a module root.
    try expectErrorContains(
        &runtime,
        "[] (( : ) (3) 'bad def) 'broken @defm",
        &.{ "'kind 'domain", "malformed definition annotation" },
    );
}

test "definitions: set and setp publish exact literal captures without synthesized metadata" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{ .output = &output.writer }), .default, .evaluate);
    defer runtime.deinit();
    // The equivalence is exact in the body and in the absent metadata: both
    // spellings expose the same literal-capture body.
    try expectStack(
        &runtime,
        "42 'answer set 42 literal 'spelled def answer spelled match?",
        "1",
    );
    try expectOk(&runtime, "'answer see 'spelled see 'answer which");
    try std.testing.expectEqualStrings(
        "[42]\n" ++
            "[42]\n" ++
            "answer -> answer def public\n",
        output.written(),
    );
    try expectErrorContains(&runtime, "'answer doc", &.{ "'kind 'domain", "documentation" });
    // `setp` carries the same simplification into a module root, where the
    // published constant needs no effect declaration to register.
    try expectOk(&runtime, "[] (7 'x set 8 'h setp (h) 'peek def) 'm @defm");
    try expectStack(&runtime, "m.x m.peek", "7 8");
    output.clearRetainingCapacity();
    try expectOk(&runtime, "'m.x see");
    try std.testing.expectEqualStrings("[7]\n", output.written());
}

test "modules: *module* reports the active canonical registration" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    // Identity belongs to the registration the caller reached: two
    // registrations of the same body report their own names.
    try expectStack(
        &runtime,
        "[] ((*module*) 'name def) 'left @defm [] ((*module*) 'name def) 'right @defm " ++
            "left.name right.name",
        "'left 'right",
    );
    // Aliases select their target registration and therefore report its
    // canonical name rather than the spelling used at the call site.
    try expectStack(&runtime, "'short 'left alias short.name", "'left");

    // The root has no home and therefore no module name to manufacture.
    try expectErrorContains(&runtime, "*module*", &.{
        "'kind 'domain",
        "registered module",
    });
    // A construction body already knows the name it is being built under:
    // `*module*` answers, and the value it leaves is what the body refuses.
    try expectErrorContains(&runtime, "[] (*module*) 'building @defm", &.{
        "'kind 'domain",
        "left 1 value",
    });
    try expectOk(&runtime, "[] ((*module*) 'name set) 'escaped @defm");
    try expectErrorContains(&runtime, "escaped.name call", &.{
        "'kind 'domain",
        "registered module",
    });
}

test "modules: explicit seeds initialize the @defm construction stack in order" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // The explicit seed list initializes the isolated body in list order, so the body observes
    // the list's first element deepest. Consuming them proves the order without
    // needing to read the durable stack back.
    try expectStack(
        &runtime,
        "[10 3] (div 'quotient set) 'divide @defm divide.quotient",
        "3",
    );
    // Whatever the body leaves behind is refused: a module keeps no state,
    // and nothing it leaves ever reaches the caller.
    try expectErrorContains(&runtime, "[1 2 3] (+ swap 9) 'residue @defm", &.{ "'kind 'domain", "left 3 values" });
    try expectErrorContains(&runtime, "[4 5] () 'untouched @defm", &.{ "'kind 'domain", "left 2 values" });
    // The seeded values are gone from the caller's stack in every case.
    try expectStack(&runtime, "[6 7] (+ 'sum set) 'consumed @defm consumed.sum", "13");
}

test "modules: dotted names qualify dynamically and split executable words at the final dot" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] ((1) 'utils def) 'base @defm");
    try expectOk(&runtime, "[] ((41) 'f def (42) 'g def) 'base.utils @defm");
    try expectStack(&runtime, "base.utils base.utils.f", "1 41");
    try expectStack(&runtime, "'base.utils 'f qualify dup type swap execute", "'word 41");
    try expectStack(&runtime, "'base.utils 1 ('f) ('g) if qualify execute", "41");
    try expectOk(&runtime, "'utils 'base.utils alias");
    try expectStack(&runtime, "utils.g", "42");
    try expectOk(&runtime, "'base.utils ('g) import");
    try expectStack(&runtime, "g", "42");
    try expectOk(&runtime, "[] ((43) 'f def) 'base.utils @defm");
    try expectStack(&runtime, "base.utils.f 'base.utils 'f qualify execute", "43 43");
    try expectOk(&runtime, "'utils unmodule");
    try expectErrorContains(&runtime, "base.utils.f", &.{ "'kind 'undefined-word", "base.utils.f" });
    try expectErrorContains(&runtime, "utils.f", &.{ "'kind 'undefined-word", "utils.f" });
    try expectOk(&runtime, "[] ((44) 'f def) 'base.utils @defm");
    try expectStack(&runtime, "base.utils.f", "44");
}

test "modules: core qualifier reaches shadowed core words and is never a registration" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectStack(&runtime, "1 core.dup", "1 1");
    try expectOk(&runtime, "(2 *) 'dup def");
    try expectStack(&runtime, "3 dup 3 core.dup", "6 3 3");
    try expectStack(&runtime, "'core 'dup qualify 4 swap execute", "4 4");
    // A module whose own export shadows a core word reaches the original
    // through the qualifier, which is the case the standard library needs.
    try expectOk(&runtime, "[] ((pop 'shadowed) 'where def ([0 1 1] core.where) 'indices def) 'shadow.host @defm");
    try expectStack(&runtime, "shadow.host.indices", "[1 2]");
    try expectStack(&runtime, "7 shadow.host.where", "'shadowed");
    try expectErrorContains(&runtime, "core.no-such-binding", &.{ "'kind 'undefined-word", "'scope 'core" });
    // Core is a scope, not a registration: nothing may publish under its name
    // as a module or an alias, and it is not a module to
    // alias, import from, or remove.
    try expectErrorContains(&runtime, "[] () 'core @defm", &.{ "'kind 'domain", "reserved for the core qualifier" });
    try expectErrorContains(&runtime, "'core 'shadow.host alias", &.{ "'kind 'domain", "reserved for the core qualifier" });
    try expectErrorContains(&runtime, "'short 'core alias", &.{ "'kind 'undefined-word", "undefined module `core`" });
    try expectErrorContains(&runtime, "'core ('dup) import", &.{ "'kind 'undefined-word", "'scope 'qualified" });
    try expectErrorContains(&runtime, "'core unmodule", &.{ "'kind 'undefined-word", "undefined word `core`" });
    // The reservation is the whole name, not a segment: a dotted name under it
    // registers, resolves, and qualifies like any other module.
    try expectOk(&runtime, "[] ((1) 'f def) 'core.utils @defm");
    try expectStack(&runtime, "core.utils.f 'core.utils 'f qualify execute", "1 1");
    try expectStack(&runtime, "1 core.dup", "1 1");
}

test "modules: execute preserves ordinary dispatch home contracts and errors" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "[] ((3) 'secret defp (secret 4 +) 'f def) 'private.home @defm");
    try expectStack(&runtime, "'private.home 'f qualify execute", "7");
    try expectOk(&runtime, "[] ((5) 'five def (1 +) 'inc def) 'other.home @defm");
    try expectStack(
        &runtime,
        "'other.home 'five qualify execute 'other.home 'inc qualify execute",
        "6",
    );
    try expectStack(&runtime, "3 (dup) first execute", "3 3");
    try expectErrorContains(&runtime, "'missing.home 'f qualify execute", &.{
        "'kind 'undefined-word",
        "missing.home.f",
    });
    try expectOk(&runtime, "(n -- n) (1 +) 'annotated def");
    try expectErrorContains(&runtime, "(annotated) first execute", &.{ "'kind 'underflow", "annotated" });
}

test "modules: removed identity builtin has no reservation and names validate by category" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    for ([_][]const u8{ "[] () '.bad @defm", "[] () 'bad. @defm", "[] () 'bad..path @defm" }) |source|
        try expectErrorContains(&runtime, source, &.{"'kind 'parse"});
    try expectErrorContains(&runtime, "[] () 1 @defm", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "'x 1 import", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "1 unmodule", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "[] ((1) 'bad.name def) 'core.utils @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "1 'f qualify", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "'core.utils 1 qualify", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "'core..utils 'f qualify", &.{"'kind 'parse"});
    try expectErrorContains(&runtime, "'core.utils 'bad.name qualify", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'core.utils '-- qualify", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "1 execute", &.{"'kind 'type"});
}

const removable_module = "[] ((1) 'tick def (7) 'peek def) 'c @defm";

test "concurrency: unmodule retires a module with its names and aliases in one publish" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = workers }, .evaluate);
        defer runtime.deinit();
        try expectStack(&runtime, removable_module, "");
        try expectOk(&runtime, "'short 'c alias");
        // Calls racing removal either finish with a stable value or find
        // nothing; no schedule observes a half-removed entry.
        try expectStack(
            &runtime,
            "[1] 20 take (pop [] ([] (c.tick) @attempt pop) @spawn) each " ++
                "'c unmodule (task.await) each pop",
            "",
        );
        try expectErrorContains(&runtime, "c.peek", &.{"'kind 'undefined-word"});
        // Every alias targeting the module goes with it in the same publish.
        try expectErrorContains(&runtime, "short.peek", &.{"'kind 'undefined-word"});
        try expectErrorContains(&runtime, "'short ('peek) import", &.{"'kind 'undefined-word"});
        // Reusing the public name creates no way to refer to the removed module.
        try expectOk(&runtime, removable_module);
        try expectStack(&runtime, "'c unmodule " ++ removable_module ++ " c.tick c.peek", "1 7");
        try expectStack(&runtime, "'c unmodule", "");
        try expectErrorContains(&runtime, "c.tick", &.{"'kind 'undefined-word"});
        try expectErrorContains(&runtime, "'nowhere unmodule", &.{"'kind 'undefined-word"});
        // Re-registration racing removal of the same name: whichever edit
        // publishes second finds its snapshot stale and starts over against
        // the other's directory. Both orders leave exactly one live module.
        for (0..12) |_| {
            try expectOk(&runtime, removable_module);
            try expectStack(
                &runtime,
                "[(" ++ removable_module ++ ") ('c unmodule)] ([] swap @spawn) each " ++
                    "(task.await) each pop [] ('c unmodule) @attempt pop " ++
                    removable_module ++ " c.tick c.peek",
                "1 7",
            );
            try expectStack(&runtime, "'c unmodule", "");
        }
    }
}

const churn_cycle = "[] ((\"a module string\" [1 2 3] {'k 'v}) 'peek def) 'churn @defm " ++
    "churn.peek pop pop pop 'churn unmodule";

test "concurrency: a cancelled unmodule leaves nothing stranded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 2 }, .evaluate);
        defer runtime.deinit();
        // The observer detects the published close through ordinary name
        // resolution. The removal task deliberately remains cancellable
        // after `unmodule`, so cancellation is issued after that edge rather
        // than pre-armed. Each batch is one Unit and the source differs only
        // in its count, excluding per-Unit archive/task costs from the bound.
        const cancellation_cycle = "[] (8192 range 'big setp " ++
            "(1) 'alive def) 'doomed @defm" ++
            " [] (([] ('doomed.alive execute) @attempt result.ok?) () while) @spawn 'close-watcher set" ++
            " [] ('doomed unmodule (1) () while) @spawn 'removal-task set" ++
            " close-watcher task.await pop removal-task task.cancel" ++
            " removal-task task.await 'err at 'kind at 'cancelled match? pop" ++
            // A successful public mutation drives reuse settlement while the
            // Session remains live; shutdown is not the cleanup mechanism.
            " [] ((1) 'peek def) 'settler @defm" ++
            " settler.peek pop 'settler unmodule";
        const small = "2 (" ++ cancellation_cycle ++ ") times";
        const large = "8 (" ++ cancellation_cycle ++ ") times";
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
        std.testing.expect(large_growth <= small_growth * 2 + 4096) catch |err| {
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

test "concurrency: repeated construct remove cycles keep settled memory bounded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
        defer runtime.deinit();
        // Both batches run as one unit each and differ by a single source
        // character, so their fixed per-unit costs are the same and the only
        // variable is how many construct/remove cycles ran. Ten times the
        // cycles must not cost ten times the memory.
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
        // Reader-text lineage is *not* part of what this measures any more, and
        // that is deliberate. A rewritten construction body's directory slot is
        // cleared and its identity recycled when the header retires, so lineage
        // storage settles proportional to live re-scoped headers rather than to
        // identities ever issued. Measured across that change at 200 cycles:
        // 116,591 bytes before it, 97,135 after — below the 106,351 this
        // fixture cost when its body was `with`-flattened and re-scoped not at
        // all. Marginal cost from 200 to 2,000 cycles is 303 bytes, against 301
        // for the flattened body; what remains is the parked anchor and scope
        // cell per stamped retired image, which predates this feature.
        std.testing.expect(large_growth <= small_growth * 2 + 4096) catch |err| {
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

test "concurrency: applying an escaped quotation races reload and removal" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    // A quotation that escaped `racer` names the image it was written in, and
    // an application from a spawned task has no home, so nothing pins that
    // image while the words resolve. A concurrent `@defm` or `unmodule` can
    // therefore free the scope under the resolving worker.
    //
    // This test exists to catch that. It is named into the `concurrency:` tier
    // so it actually runs under ThreadSanitizer and at eight workers — it was
    // previously in neither, which is why an earlier "TSan is green" claim on
    // this branch was not evidence about this path at all. The assertions are
    // deliberately weak: failures stay inside the envelope and the runtime keeps progressing;
    // TSan and the allocator are what should speak here.
    try expectOk(&runtime, "[] ((1) 'k def ((k)) 'q def) 'racer @defm racer.q 'held set");
    try expectOk(&runtime, "[1] 24 take (pop [] ([] (held call) @attempt) @spawn) each " ++
        "[] ((2) 'k def ((k)) 'q def) 'racer @defm " ++
        "(task.await) each pop");
    // And against removal, where acquisition must fail rather than race.
    try expectOk(&runtime, "[] ((1) 'k def ((k)) 'q def) 'goner @defm goner.q 'gone set");
    try expectOk(&runtime, "[1] 24 take (pop [] ([] (gone call) @attempt) @spawn) each " ++
        "'goner unmodule (task.await) each pop");
}

// Stubs. Implemented by the patch each one names; see
// gameplans/stamped-word-image-home.json. The `concurrency:` prefix is
// load-bearing: the TSan and 8-worker tiers select on it.

test "concurrency: a resolver racing an image's last release never dereferences its scope" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 4 }, .evaluate);
        defer runtime.deinit();
        // The quotation escapes its module, so its words are stamped against an
        // image nothing holds. Tasks apply it while `unmodule` drives that image
        // to its last release underneath them.
        //
        // This is the test that separates this design from the one it replaced.
        // Pinning at the *end* of resolution leaves the window open: the borrow
        // reads the cell's scope, the last release frees the environment, and
        // the walk is already inside it. Pinning at the borrow closes it, so
        // every task either runs the old code or fails `'domain` -- never both
        // and never neither.
        try expectOk(
            &runtime,
            "[] ((1) 'k def ((k)) 'q def) 'goner @defm goner.q 'gone set",
        );
        try expectStack(
            &runtime,
            "[1] 64 take (pop [] ([] (gone call) @attempt) @spawn) each " ++
                "'goner unmodule (task.await) each pop",
            "",
        );
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "concurrency: a resolver racing environment teardown resolves without a dereference" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 4 }, .evaluate);
        defer runtime.deinit();
        // Reload rather than removal, so the *old* image's environment tears
        // down through the release domain while tasks are still applying a
        // quotation stamped against it. The domain drives teardown indirectly,
        // which is the only way the waiting state is reached.
        try expectOk(
            &runtime,
            "[] ((1) 'k def ((k)) 'q def) 'reloaded @defm reloaded.q 'held set",
        );
        try expectStack(
            &runtime,
            "[1] 64 take (pop [] ([] (held call) @attempt) @spawn) each " ++
                "[] ((2) 'k def) 'reloaded @defm (task.await) each pop",
            "",
        );
        // The replacement is what callers now reach; the escaped quotation went
        // on meaning what it meant, for as long as anything held it.
        try expectStack(&runtime, "reloaded.k", "2");
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}
