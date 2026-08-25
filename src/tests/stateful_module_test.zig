//! The Milestone 11 suite: modules as ECL's durable-state layer.
//!
//! Every test here pins one observable contract from the milestone's
//! Definition of Done — optional source annotations, the construction stack
//! that becomes durable slot state, namespaced lookup, the `within`/`without`
//! transaction boundary, the hot-reload barrier, and the
//! `unmodule` removal typestate. Tests carrying the `concurrency: ` prefix
//! enter `test-workers` (1 and 8) and `test-tsan` through build-file name
//! routing; the rest run in the ordinary suite.
const std = @import("std");
const session = @import("../session.zig");
const machine = @import("../machine.zig");

test "concurrency: lock-tier auto-loads converge through one loading lease" {
    var fixture = try ConcurrentLockFixture.init();
    defer fixture.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    const environ = [_]machine.Environ.Entry{.{ .name = "ECL_CACHE", .value = fixture.cache }};
    var runtime = try session.Session.initWithHostConfig(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .project_start = fixture.nested,
            .environ = &environ,
        },
        .{ .worker_pool = 8 },
    );
    defer runtime.deinit();
    try expectStack(
        &runtime,
        "[1 2 3 4 5 6 7 8] (race.answer) @each",
        "[42 42 42 42 42 42 42 42]",
    );
}

const concurrent_hash = "sha256-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

const ConcurrentLockFixture = struct {
    directory: std.testing.TmpDir,
    root: [:0]u8,
    nested: []u8,
    cache: []u8,

    fn init() !ConcurrentLockFixture {
        const allocator = std.testing.allocator;
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const root = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(root);
        try directory.dir.createDir(std.testing.io, "project", .default_dir);
        try directory.dir.createDir(std.testing.io, "project/nested", .default_dir);
        try directory.dir.createDir(std.testing.io, "cache", .default_dir);
        try directory.dir.createDir(
            std.testing.io,
            "cache/race-1.0.0-" ++ concurrent_hash[7..],
            .default_dir,
        );
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/ecl.pkg",
            .data = "{'format 1 'name \"root\" 'version \"0.1.0\" 'requires {}}\n",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "project/ecl.lock",
            .data = "{'format 1\n 'root \"root\"\n 'packages\n {\"race\" {'version \"1.0.0\" 'url \"https://example.invalid/race.tgz\" 'hash \"" ++ concurrent_hash ++ "\"}}\n 'requires\n {\"root\" {\"race\" \"1.0.0\"}}}\n",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "cache/race-1.0.0-" ++ concurrent_hash[7..] ++ "/race.ecl",
            .data = "((pop 42) 'answer def) 'race @defm\n",
        });
        const nested = try std.fs.path.join(allocator, &.{ root, "project", "nested" });
        errdefer allocator.free(nested);
        const cache = try std.fs.path.join(allocator, &.{ root, "cache" });
        return .{ .directory = directory, .root = root, .nested = nested, .cache = cache };
    }

    fn deinit(self: *ConcurrentLockFixture) void {
        const allocator = std.testing.allocator;
        allocator.free(self.cache);
        allocator.free(self.nested);
        allocator.free(self.root);
        self.directory.cleanup();
    }
};

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("stateful-module-test.ecl", source)) {
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
    const failure = switch (try runtime.runUnit("stateful-module-test.ecl", source)) {
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
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    // All four forms register, publicly and privately, and each word runs.
    try expectOk(&runtime, "(" ++
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
    // Reflection preserves exactly which portions were supplied: an absent
    // effect prints no effect, an absent document has none to report.
    try expectOk(&runtime, "'forms.bare see 'forms.effected see " ++
        "'forms.documented see 'forms.complete see");
    try std.testing.expectEqualStrings(
        "### def forms.bare\n" ++
            "(1 +) 'forms.bare def\n" ++
            "### def forms.effected\n" ++
            "(n -- n) (2 *) 'forms.effected def\n" ++
            "### def forms.documented\n" ++
            "(: \"Subtract three.\") (3 -) 'forms.documented def\n" ++
            "### def forms.complete\n" ++
            "(n -- n : \"Divide by four.\") (4 div) 'forms.complete def\n",
        output.written(),
    );
    try expectStack(&runtime, "'forms.documented doc", "\"Subtract three.\"");
    try expectErrorContains(&runtime, "'forms.bare doc", &.{ "'kind 'domain", "documentation" });
    // A supplied effect stays a live cross-home contract; omitting one adds
    // no inferred check, so a word leaving two values crosses unimpeded.
    try expectErrorContains(
        &runtime,
        "(( -- n ) (1 2) 'two def) 'liar @defm liar.two",
        &.{ "'kind 'contract", "'word 'liar.two", "declared (0 -- 1)" },
    );
    try expectStack(&runtime, "((1 2) 'two def) 'quiet @defm quiet.two", "1 2");
    // Malformed recognized annotations remain 'domain in a module root.
    try expectErrorContains(
        &runtime,
        "(( : ) (3) 'bad def) 'broken @defm",
        &.{ "'kind 'domain", "malformed definition annotation" },
    );
}

test "definitions: set and setp publish exact literal captures without synthesized metadata" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    // The equivalence is exact in the body and in the absent metadata: both
    // spellings reflect as the same unannotated public def.
    try expectStack(
        &runtime,
        "42 'answer set 42 literal 'spelled def answer spelled match?",
        "1",
    );
    try expectOk(&runtime, "'answer see 'spelled see 'answer which");
    try std.testing.expectEqualStrings(
        "### def answer\n" ++
            "([42] first) 'answer def\n" ++
            "### def spelled\n" ++
            "([42] first) 'spelled def\n" ++
            "answer -> answer def public\n",
        output.written(),
    );
    try expectErrorContains(&runtime, "'answer doc", &.{ "'kind 'domain", "documentation" });
    // `setp` carries the same simplification into a module root, where the
    // published constant needs no effect declaration to register.
    try expectOk(&runtime, "(7 'x set 8 'h setp (h) 'peek def) 'm @defm");
    try expectStack(&runtime, "m.x m.peek", "7 8");
    output.clearRetainingCapacity();
    try expectOk(&runtime, "'m.x see");
    try std.testing.expectEqualStrings("### def m.x\n([7] first) 'm.x def\n", output.written());
}

test "modules: a nonempty construction stack becomes the durable initial stack once per slot" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.init(allocator, &.{});
        defer runtime.deinit();
        // The residual construction window is captured rather than rejected,
        // and it leaves the caller's stack: the values moved into the slot.
        try expectStack(&runtime, "(0 (1 +) 'bump def) 'counter @defm", "");
        // Re-registration builds a fresh proposal and discards it: only the
        // code generation advances, which reflection reports.
        try expectStack(&runtime, "(100 (2 +) 'bump def) 'counter @defm", "");
        // Independently registered names own independent slots even when
        // their bodies come from the same quotation.
        try expectStack(&runtime, "(7) 'left @defm (7) 'right @defm", "");
        // A body may still leave nothing behind; neither shape is an error.
        try expectStack(&runtime, "((1) 'one def) 'stateless @defm stateless.one", "1");
    }
    try std.testing.expect(counting.deinit() == .ok);
}

test "modules: with-seeded @defm seeds the construction stack in order" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // `with` seeds the isolated body in list order, so the body observes the
    // list's first element deepest. Consuming them proves the order without
    // needing to read the durable stack back.
    try expectStack(
        &runtime,
        "[10 3] (div 'quotient set) with 'divide @defm divide.quotient",
        "3",
    );
    // The body may consume some, reorder, and extend: whatever remains is
    // the slot's durable stack and never reaches the caller.
    try expectStack(&runtime, "[1 2 3] (+ swap 9) with 'residue @defm", "");
    // Seeds that the body leaves untouched are legal too.
    try expectStack(&runtime, "[4 5] () with 'untouched @defm", "");
    // The seeded values are gone from the caller's stack in every case.
    try expectStack(&runtime, "[6 7] (+ 'sum set) with 'consumed @defm consumed.sum", "13");
}

test "modules: dotted names qualify dynamically and split executable words at the final dot" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "((1) 'utils def) 'core @defm");
    try expectOk(&runtime, "((41) 'f def (42) 'g def) 'core.utils @defm");
    try expectStack(&runtime, "core.utils core.utils.f", "1 41");
    try expectStack(&runtime, "'core.utils 'f qualify dup type swap execute", "'word 41");
    try expectStack(&runtime, "'core.utils 1 ('f) ('g) if qualify execute", "41");
    try expectOk(&runtime, "'utils 'core.utils alias");
    try expectStack(&runtime, "utils.g", "42");
    try expectOk(&runtime, "'core.utils.g 'g import");
    try expectStack(&runtime, "g", "42");
    try expectOk(&runtime, "((43) 'f def) 'core.utils @defm");
    try expectStack(&runtime, "core.utils.f 'core.utils 'f qualify execute", "43 43");
    try expectOk(&runtime, "'utils unmodule");
    try expectErrorContains(&runtime, "core.utils.f", &.{ "'kind 'undefined-word", "core.utils.f" });
    try expectErrorContains(&runtime, "utils.f", &.{ "'kind 'undefined-word", "utils.f" });
    try expectOk(&runtime, "((44) 'f def) 'core.utils @defm");
    try expectStack(&runtime, "core.utils.f", "44");
}

test "modules: execute preserves ordinary dispatch home contracts and errors" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "((3) 'secret defp (secret 4 +) 'f def) 'private.home @defm");
    try expectStack(&runtime, "'private.home 'f qualify execute", "7");
    try expectOk(&runtime, "[5] (" ++
        "((1 +) within) 'tick def ((dup without) within) 'peek def) with 'state.home @defm");
    try expectStack(
        &runtime,
        "'state.home 'tick qualify execute 'state.home 'peek qualify execute",
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
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    for ([_][]const u8{ "() '.bad @defm", "() 'bad. @defm", "() 'bad..path @defm" }) |source|
        try expectErrorContains(&runtime, source, &.{"'kind 'parse"});
    try expectErrorContains(&runtime, "() 1 @defm", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "'x 1 import", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "1 unmodule", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "((1) 'bad.name def) 'core.utils @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "1 'f qualify", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "'core.utils 1 qualify", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "'core..utils 'f qualify", &.{"'kind 'parse"});
    try expectErrorContains(&runtime, "'core.utils 'bad.name qualify", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'core.utils '-- qualify", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "1 execute", &.{"'kind 'type"});
}

const counter_module = "[0] (" ++
    "((1 +) within) 'tick def " ++
    "((dup without) within) 'peek def " ++
    "((swap + dup without) partial within) 'add def" ++
    ") with 'c @defm";

test "concurrency: within applications serialize and publish exactly the successful updates" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        try expectStack(&runtime, counter_module, "");
        // Every application observes its predecessor's published state, so
        // the final value is exactly the successful increment count.
        try expectStack(&runtime, "[1] 60 take (pop (c.tick) @spawn) each await-all pop c.peek", "60");
        // A multi-input update composed with `partial` is one transaction.
        try expectStack(&runtime, "[1] 20 take (pop (5 c.add) @spawn) each await-all pop c.peek", "160");
        // A pool checkout moves a value outward; checkin returns one. Both
        // are ordinary transactional updates on the same slot.
        try expectStack(
            &runtime,
            "[['a 'b 'c]] (((uncons swap without) within) 'checkout def " ++
                "((append) partial within) 'checkin def " ++
                "((dup len without) within) 'size def) with 'pool @defm pool.size",
            "3",
        );
        try expectStack(&runtime, "pool.checkout pool.size", "'a 2");
        try expectStack(&runtime, "'z pool.checkin pool.size", "3");
        // Several `without`s deliver in invocation order, and the values
        // that stay on the draft stay in state.
        try expectStack(
            &runtime,
            "[10 20 30] (((without without) within) 'top-two def " ++
                "((dup without) within) 'peek def) with 'ordered @defm ordered.top-two",
            "30 20",
        );
        try expectStack(&runtime, "ordered.peek", "10");
        // `with` supplies several captured inputs to one transactional
        // update, which is the multi-input counterpart of `partial`.
        try expectStack(
            &runtime,
            "[100] (([2 3] (+ + dup without) with within) 'add-both def) with 'summed @defm " ++
                "summed.add-both",
            "105",
        );
        // A stateless module keeps its ordinary caller-stack behaviour.
        try expectStack(&runtime, "((dup +) 'double def) 'plain @defm 21 plain.double", "42");
    }
}

test "concurrency: one image registered twice arbitrates two independent slots" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        // One immutable image, two registrations. Each slot owns its own
        // arbiter and durable stack, so concurrent applications through the
        // two names never serialize against each other and never share a
        // count.
        try expectStack(
            &runtime,
            "[0] (((1 + dup without) within) 'tick def " ++
                "((dup without) within) 'peek def) with @module " ++
                "dup 'shared-left register 'shared-right register",
            "",
        );
        try expectStack(
            &runtime,
            "[1] 40 take (pop (shared-left.tick) @spawn (shared-right.tick) @spawn pair) " ++
                "each raze await-all pop shared-left.peek shared-right.peek",
            "40 40",
        );
        // Reloading one registration keeps the other's state and code
        // reachable while old generations quiesce.
        try expectStack(
            &runtime,
            "[0] (((10 + dup without) within) 'tick def " ++
                "((dup without) within) 'peek def) with @module 'shared-left register",
            "",
        );
        try expectStack(&runtime, "shared-left.tick shared-right.tick", "50 41");
        // Removing one leaves the other completely intact.
        try expectOk(&runtime, "'shared-left unmodule");
        try expectStack(&runtime, "shared-right.peek", "41");
        try expectErrorContains(&runtime, "shared-left.peek", &.{"'kind 'undefined-word"});
    }
}

test "concurrency: failed within applications publish neither draft nor pending outputs" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, counter_module, "");
    try expectStack(&runtime, "c.tick c.peek", "1");
    // A quotation error publishes nothing and leaves the caller stack clean.
    try expectOk(&runtime, "[0] (((1 + missing) within) 'boom def " ++
        "((dup without missing) within) 'leaks def " ++
        "((dup without) within) 'peek def) with 'c @defm");
    try expectErrorContains(&runtime, "c.boom", &.{ "'kind 'undefined-word", "'word 'missing" });
    try expectStack(&runtime, "c.peek", "1");
    // Values already moved outward by `without` are discarded with the draft.
    try expectErrorContains(&runtime, "c.leaks", &.{"'kind 'undefined-word"});
    try expectStack(&runtime, "c.peek", "1");
    // `without` on an empty draft is 'underflow and publishes nothing.
    try expectOk(&runtime, "[0] (((without without) within) 'greedy def " ++
        "((1 +) within) 'tick def ((dup without) within) 'peek def) with 'c @defm");
    try expectErrorContains(&runtime, "c.greedy", &.{"'kind 'underflow"});
    try expectStack(&runtime, "c.peek", "1");
    // Cancellation races the application, so the tick either published in
    // full or not at all — never half. Whichever happened, the slot is
    // usable and the next application advances it by exactly one.
    try expectStack(
        &runtime,
        "(c.tick) @spawn dup cancel await pop c.peek dup 1 = swap 2 = or",
        "1",
    );
    try expectStack(&runtime, "c.peek c.tick c.peek swap -", "1");
}

test "concurrency: within rejects parking nesting and cross-module drafts as domain" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, counter_module, "");
    // Every prohibited shape fails before it can wait, and none of them
    // leaves the slot held: an ordinary update still succeeds afterwards.
    try expectOk(&runtime, "[0] (" ++
        "(((1 +) within) within) 'nested def " ++
        "((c.tick) within) 'cross def " ++
        "(((1) @spawn await pop) within) 'parked def " ++
        "(((1) @spawn 5 await-for pop) within) 'deadlined def " ++
        "([(1) (2)] (@spawn) each await-all pop) 'joined def " ++
        "(([(1)] (@spawn) each await-all pop) within) 'joined-within def " ++
        "((dup without) within) 'peek def) with 'p @defm");
    // Reloading or removing *any* module from inside a state application
    // acquires a second slot's turn, which is the same deadlock shape a
    // nested `within` is: two units each holding one slot and waiting for
    // the other's would never make progress.
    try expectOk(&runtime, "[0] ((('c unmodule) within) 'kill-other def " ++
        "((((1) 'x def) 'c @defm) within) 'reload-other def " ++
        "(('q unmodule) within) 'kill-self def " ++
        "((dup without) within) 'peek def) with 'q @defm");
    for ([_][]const u8{
        "p.nested",        "p.cross",      "p.parked",       "p.deadlined",
        "p.joined-within", "q.kill-other", "q.reload-other", "q.kill-self",
    }) |source| {
        try expectErrorContains(&runtime, source, &.{"'kind 'domain"});
    }
    try expectStack(&runtime, "q.peek", "0");
    // `within` remains implicit and quotation-only.
    try expectErrorContains(&runtime, "'h within", &.{ "'kind 'type", "quotation" });
    try expectStack(&runtime, "p.peek", "0");
    try expectStack(&runtime, "c.tick c.peek", "1");
    // Outside a state application the same parking words still work.
    try expectStack(&runtime, "p.joined", "");
    // Top-level and registration-root uses are 'domain too.
    try expectErrorContains(&runtime, "(1) within", &.{ "'kind 'domain", "homed in a module" });
    try expectErrorContains(&runtime, "without", &.{ "'kind 'domain", "within application" });
    try expectErrorContains(
        &runtime,
        "((1) within) 'root @defm",
        &.{ "'kind 'domain", "published module word" },
    );
}

const reload_counter = "[0] (" ++
    "((1 +) within) 'tick def " ++
    "((dup without) within) 'peek def) with 'c @defm";

test "concurrency: hot reload retains the durable stack and quiesces old generations" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        try expectStack(&runtime, reload_counter, "");
        // With no reload in flight every application publishes, so the
        // final value is exactly the increment count.
        try expectStack(&runtime, "[1] 30 take (pop (c.tick) @spawn) each await-all pop c.peek", "30");
        // Reload racing concurrent callers: each caller either takes its
        // turn before the barrier or finds its generation superseded and is
        // refused. Nothing in between: the final value is exactly the
        // retained stack plus the number that published.
        try expectStack(
            &runtime,
            "[1] 30 take (pop ((c.tick) @attempt result.ok?) @spawn) each " ++
                "[0] (((1 +) within) 'tick def ((dup without) within) 'peek def " ++
                "((dup 2 * without) within) 'doubled def) with 'c @defm " ++
                "await-all ('ok at first) each sum 30 + c.peek match?",
            "1",
        );
        // The replacement initializer is discarded and the new code is live.
        try expectStack(&runtime, "c.peek 2 * c.doubled match?", "1");
        // Failed registration changes neither behaviour nor state.
        try expectErrorContains(
            &runtime,
            "((bad -- shape -- here) (1) 'x def) 'c @defm",
            &.{"'kind 'domain"},
        );
        try expectStack(&runtime, "c.tick c.peek c.doubled swap 2 * match?", "1");
        // A generation that re-registers its own module keeps running, but
        // the representation it belongs to is no longer current, so it may
        // not publish state — the invariant the arbiter barrier exists to
        // hold. The replacement generation is unaffected.
        try expectOk(&runtime, "[5] (" ++
            "((((1 +) within) 'tick def ((dup without) within) 'peek def) 'stale @defm " ++
            "(99 +) within) 'publish-late def " ++
            "((dup without) within) 'peek def) with 'stale @defm");
        try expectErrorContains(
            &runtime,
            "stale.publish-late",
            &.{ "'kind 'domain", "a replaced module generation cannot publish state" },
        );
        try expectStack(&runtime, "stale.peek", "5");
        try expectStack(&runtime, "stale.tick stale.peek", "6");
        // Reload from module-homed code outside a state application is
        // ordinary; from inside one it is the shape whose barrier could
        // never complete, so it is refused before any wait.
        try expectOk(&runtime, "[0] (" ++
            "((((1) 'x def) 'self @defm) within) 'suicide def " ++
            "((dup without) within) 'peek def) with 'self @defm");
        try expectErrorContains(&runtime, "self.suicide", &.{ "'kind 'domain", "state application" });
        try expectStack(&runtime, "self.peek", "0");
    }
}

test "concurrency: superseded code may finish but cannot acquire new state authority" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        // `reload-me` continues in the superseded generation after replacing
        // its own code, while the replacement owns the unchanged durable state.
        try expectOk(&runtime, "[5] (" ++
            "((((dup without) within) 'peek def) 'identity @defm 7) 'reload-me def " ++
            "((dup without) within) 'peek def) with 'identity @defm");
        try expectStack(&runtime, "identity.reload-me identity.peek", "7 5");
    }
}

test "concurrency: delayed old code cannot reach a recycled replacement slot" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        // Every probe resolves old code before or during removal. Its two
        // state operation is caught so the invocation stays alive across the
        // close edge. The remover then creates an unrelated module under the
        // same allocation churn. No old `within` operation may reach it.
        try expectOk(&runtime, "[0] (" ++
            "(((1 +) within) @attempt pop) 'probe def" ++
            ") with 'old @defm");
        try expectStack(
            &runtime,
            "[1] 200 take (pop (old.probe) @spawn) each " ++
                "('old unmodule [700] (" ++
                "((1 +) within) 'tick def " ++
                "((dup without) within) 'peek def " ++
                "(99) 'marker def) with 'replacement @defm) @spawn append " ++
                "await-all pop replacement.marker replacement.tick replacement.peek",
            "99 701",
        );
    }
}

const removable_module = "[0] (" ++
    "((1 +) within) 'tick def " ++
    "((dup without) within) 'peek def) with 'c @defm";

test "concurrency: unmodule closes quiesces and retires slots names and aliases" {
    for ([_]usize{ 1, 8 }) |workers| {
        var runtime = try session.Session.initWithConfig(
            std.testing.allocator,
            &.{},
            .{ .worker_pool = workers },
        );
        defer runtime.deinit();
        try expectStack(&runtime, removable_module, "");
        try expectOk(&runtime, "'short 'c alias");
        // Calls racing removal either finish with a stable value or find
        // nothing; no schedule observes a half-removed entry.
        try expectStack(
            &runtime,
            "[1] 20 take (pop ((c.tick) @attempt pop) @spawn) each " ++
                "'c unmodule await-all pop",
            "",
        );
        try expectErrorContains(&runtime, "c.peek", &.{"'kind 'undefined-word"});
        // Every alias targeting the slot goes with it in the same publish.
        try expectErrorContains(&runtime, "short.peek", &.{"'kind 'undefined-word"});
        try expectErrorContains(&runtime, "'short.peek 'peek import", &.{"'kind 'undefined-word"});
        // Reusing the public name creates no way to refer to the removed slot.
        try expectOk(&runtime, removable_module);
        try expectStack(&runtime, "'c unmodule " ++ removable_module ++ " c.tick c.peek", "1");
        try expectStack(&runtime, "'c unmodule", "");
        try expectErrorContains(&runtime, "c.tick", &.{"'kind 'undefined-word"});
        try expectErrorContains(&runtime, "'nowhere unmodule", &.{"'kind 'undefined-word"});
        // Re-registration racing removal of the same name: the commit either
        // wins the slot's turn and reloads it, or finds the slot closed and
        // starts over as a first registration. Both outcomes leave exactly
        // one live module — never a panic, and never a candidate published
        // into somebody else's slot.
        for (0..12) |_| {
            try expectOk(&runtime, removable_module);
            try expectStack(
                &runtime,
                "[(" ++ removable_module ++ ") ('c unmodule)] (@spawn) each " ++
                    "await-all pop ('c unmodule) @attempt pop " ++
                    removable_module ++ " c.tick c.peek",
                "1",
            );
            try expectStack(&runtime, "'c unmodule", "");
        }
        // Removing a module from inside its own state application is the one
        // shape whose barrier could never complete, so it is refused.
        try expectOk(&runtime, "[0] ((('self unmodule) within) 'suicide def " ++
            "((dup without) within) 'peek def) with 'self @defm");
        try expectErrorContains(&runtime, "self.suicide", &.{ "'kind 'domain", "state application" });
        try expectStack(&runtime, "self.peek", "0");
    }
}

const churn_cycle = "[\"a durable string\" [1 2 3] {'k 'v}] (" ++
    "((dup without) within) 'peek def) with 'churn @defm churn.peek pop 'churn unmodule";

test "concurrency: a cancelled unmodule leaves nothing stranded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(
            allocator,
            &.{},
            .{ .worker_pool = 2 },
        );
        defer runtime.deinit();
        // The observer detects the published close through ordinary name
        // resolution. The removal task deliberately remains cancellable
        // after `unmodule`, so cancellation is issued after that edge rather
        // than pre-armed. Each batch is one Unit and the source differs only
        // in its count, excluding per-Unit archive/task costs from the bound.
        const cancellation_cycle = "(8192 (0) times " ++
            "((dup without) within) 'peek def (1) 'alive def) 'doomed @defm" ++
            " ((('doomed.alive execute) @attempt result.ok?) () while) @spawn 'close-watcher set" ++
            " ('doomed unmodule (1) () while) @spawn 'removal-task set" ++
            " close-watcher await pop removal-task cancel" ++
            " removal-task await 'err at 'kind at 'cancelled match? pop" ++
            // A successful public mutation drives reuse settlement while the
            // Session remains live; shutdown is not the cleanup mechanism.
            " [1] (((dup without) within) 'peek def) with 'settler @defm" ++
            " settler.peek pop 'settler unmodule";
        const small = "[1] 2 take (pop " ++ cancellation_cycle ++ ") for";
        const large = "[1] 8 take (pop " ++ cancellation_cycle ++ ") for";
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
        var runtime = try session.Session.init(allocator, &.{});
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
    var runtime = try session.Session.init(std.testing.allocator, &.{});
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
    // deliberately weak (failures stay inside the envelope, nothing wedges);
    // TSan and the allocator are what should speak here.
    try expectOk(&runtime, "((1) 'k def ((k)) 'q def) 'racer @defm racer.q 'held set");
    try expectOk(&runtime, "[1] 24 take (pop ((held call) @attempt) @spawn) each " ++
        "((2) 'k def ((k)) 'q def) 'racer @defm " ++
        "await-all pop");
    // And against removal, where acquisition must fail rather than race.
    try expectOk(&runtime, "((1) 'k def ((k)) 'q def) 'goner @defm goner.q 'gone set");
    try expectOk(&runtime, "[1] 24 take (pop ((gone call) @attempt) @spawn) each " ++
        "'goner unmodule await-all pop");
}

// Stubs. Implemented by the patch each one names; see
// gameplans/stamped-word-image-home.json. The `concurrency:` prefix is
// load-bearing: the TSan and 8-worker tiers select on it.

test "concurrency: a resolver racing an image's last release never dereferences its scope" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(
            allocator,
            &.{},
            .{ .worker_pool = 4 },
        );
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
            "((1) 'k def ((k)) 'q def) 'goner @defm goner.q 'gone set",
        );
        try expectStack(
            &runtime,
            "[1] 64 take (pop ((gone call) @attempt) @spawn) each " ++
                "'goner unmodule await-all pop",
            "",
        );
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "concurrency: a resolver racing environment teardown resolves without a dereference" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(
            allocator,
            &.{},
            .{ .worker_pool = 4 },
        );
        defer runtime.deinit();
        // Reload rather than removal, so the *old* image's environment tears
        // down through the release domain while tasks are still applying a
        // quotation stamped against it. Teardown is driven by the domain, not by
        // a direct call, which is the only way the waiting state is reached.
        try expectOk(
            &runtime,
            "((1) 'k def ((k)) 'q def) 'reloaded @defm reloaded.q 'held set",
        );
        try expectStack(
            &runtime,
            "[1] 64 take (pop ((held call) @attempt) @spawn) each " ++
                "((2) 'k def) 'reloaded @defm await-all pop",
            "",
        );
        // The replacement is what callers now reach; the escaped quotation went
        // on meaning what it meant, for as long as anything held it.
        try expectStack(&runtime, "reloaded.k", "2");
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "concurrency: within through a foreign word is domain and writes no slot" {
    var runtime = try session.Session.initWithConfig(
        std.testing.allocator,
        &.{},
        .{ .worker_pool = 2 },
    );
    defer runtime.deinit();

    // A module hands out a quotation over a private that uses `within`. Reached
    // through that quotation the word owns no slot, so the application is
    // 'domain -- and in particular does not write the caller's, which is what it
    // did before: other's stack went to 1000 while counter's stayed at 10.
    try expectOk(
        &runtime,
        "[10] (((1 +) within) 'bump def ((bump)) 'leak def " ++
            "((dup without) within) 'peek def) with 'counter @defm",
    );
    try expectOk(
        &runtime,
        "[999] ((call) 'run def ((dup without) within) 'peek def) with 'other @defm",
    );
    try expectErrorContains(
        &runtime,
        "counter.leak other.run",
        &.{ "'kind 'domain", "'word 'within" },
    );
    try expectStack(&runtime, "counter.peek", "10");
    try expectStack(&runtime, "other.peek", "999");

    // Newly reached behavior: the call crosses into another image, so the
    // foreign word's declared effect is checked where it previously was not.
    try expectStack(
        &runtime,
        "(( -- n ) (1) 'k def ((k)) 'q def) 'honest @defm honest.q call",
        "1",
    );
    try expectErrorContains(
        &runtime,
        "(( -- n c ) (1) 'k def ((k)) 'q def) 'lying @defm lying.q call",
        &.{ "'kind 'contract", "'word 'k" },
    );
}
