//! Module tests whose allocator is load-bearing.
//!
//! Everything here either builds a value on the host and publishes it into a
//! session — where the value and the session must agree on their allocator, or
//! teardown aborts in `heap.destroyObject` far from the line at fault — or owns a
//! counting allocator to state a memory bound. Both needs pin the file to
//! `std.testing.allocator` and to `DebugAllocator{ .enable_memory_limit }`.
//!
//! Module behavior that only runs source through a session lives in
//! `module_source_test.zig`, on the traceless session heap. Keeping the two
//! apart is what stops a tracing allocator from being charged to assertions
//! that never read a stack trace.
const runtime_fixture = @import("runtime_fixture.zig");
const test_heap = @import("test_heap.zig");
const std = @import("std");
const value = @import("../value.zig");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const modules = @import("../modules.zig");
const session = @import("../session.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    const outcome = try runtime.runUnit("module-test.ecl", source);
    switch (outcome) {
        .ok => {},
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.debug.print("unexpected ecl error: {s}\n", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
        .incomplete => return error.UnexpectedIncomplete,
    }
}

fn expectErrorContains(
    runtime: *session.Session,
    source: []const u8,
    needles: []const []const u8,
) !void {
    const outcome = try runtime.runUnit("module-test.ecl", source);
    const failure = switch (outcome) {
        .err => |item| item,
        .ok => return error.ExpectedLanguageError,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), needle) != null);
}

fn errorField(allocator: std.mem.Allocator, error_value: value.Value, name: []const u8) !?value.Value {
    return dict.testing.symbolField(allocator, error_value, try intern.intern(name));
}

test "session: transferred quotation provenance is absent from another archive" {
    const allocator = std.testing.allocator;
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var source_session = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer source_session.deinit();
    var runtime_inputs1 = try runtime_fixture.Fixture.init();
    defer runtime_inputs1.deinit();
    var destination_session = try session.Session.init(allocator, &.{}, runtime_inputs1.inputs(.{}), .default, .evaluate);
    defer destination_session.deinit();

    try expectOk(&source_session, "(1)");
    try expectOk(&destination_session, "[0] 0");
    try destination_session.pushBorrowed(source_session.stackItems()[0]);
    const outcome = try destination_session.runUnit("destination.ecl", "fold");
    const failure = switch (outcome) {
        .err => |item| item,
        .ok => return error.ExpectedLanguageError,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer destination_session.release(failure);
    const data = (try errorField(allocator, failure, "data")).?;
    inline for ([_][]const u8{ "source", "line", "col" }) |name|
        try std.testing.expect((try errorField(allocator, data, name)) == null);
}

/// Host-level publication helpers. The tests below measure generation
/// bumping, snapshot reclamation, and name enumeration, where a binding's
/// payload is incidental — one constant body and one effect serve every
/// publication. The caller owns what it builds and releases it once the
/// publication, which retains whatever it stores, has been made.
const TestBinding = struct {
    body: value.Value,

    fn init(allocator: std.mem.Allocator) !TestBinding {
        return .{ .body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }}) };
    }
    fn release(self: TestBinding, releases: *heap.ReleaseDomain) void {
        releases.releaseValue(self.body);
    }
    fn module(
        self: TestBinding,
        effect: env.ValidatedEffect,
        visibility: env.Visibility,
    ) env.ModulePublication {
        return .{ .word = .{
            .body = env.quotation(self.body.list).?,
            .visibility = visibility,
            .effect = effect,
        } };
    }
};

test "module names: branded factories enforce the reader symbol grammar" {
    // A binding name is any symbol spelling: a segment free of `'` and
    // control characters. A module name is also a path and registry
    // component, so it keeps the bare-segment grammar.
    const spelling_only = [_][]const u8{
        "bad name",
        "bad,name",
        "bad(name",
        "bad[name",
        "bad{name",
        "bad\"name",
        "bad#name",
        "bad\\name",
        "bad;name",
        "bad|name",
        "bad\u{00a0}name",
        "bad\u{2000}name",
        "bad\u{3000}name",
    };
    for (spelling_only) |spelling| {
        _ = try intern.internNamespace(spelling);
        try std.testing.expectError(error.InvalidName, intern.internModuleName(spelling));
    }
    const invalid_segments = [_][]const u8{
        "bad'name",
        "bad\tname",
        &.{ 0xff, 'x' },
        &.{ 0xe2, 0x82 },
    };
    for (invalid_segments) |spelling| {
        try std.testing.expectError(error.InvalidName, intern.internNamespace(spelling));
        try std.testing.expectError(error.InvalidName, intern.internModuleName(spelling));
    }
    try std.testing.expectError(error.InvalidName, intern.internNamespace("dotted.name"));
    try std.testing.expectError(error.InvalidName, intern.internModuleName("good.--"));
    try std.testing.expectError(error.InvalidName, intern.internModuleName("good.:"));

    _ = try intern.internNamespace("valid-name");
    _ = try intern.internNamespace("lambda-λ");
    _ = try intern.internModuleName("valid.module-name");
}

test "module names: a long qualified spelling is decided in bounded steps as it is interned" {
    const allocator = std.testing.allocator;
    const prefix = try allocator.alloc(u8, 70_000);
    defer allocator.free(prefix);
    @memset(prefix, 'u');
    try expectInternMissing(prefix);

    const qualified_bytes = try allocator.alloc(u8, prefix.len + ".missing".len);
    defer allocator.free(qualified_bytes);
    @memcpy(qualified_bytes[0..prefix.len], prefix);
    @memcpy(qualified_bytes[prefix.len..], ".missing");

    var cursor = intern.insertionCursor(qualified_bytes);
    var pending: usize = 0;
    const qualified = while (true) switch (try cursor.advance()) {
        .pending => pending += 1,
        .complete => |id| break id,
    };
    // Every pass over the spelling is taken in steps: finding it, storing
    // it, and deciding its module part.
    try std.testing.expect(pending > 3 * 256);
    const parts = intern.spelling(qualified).qualified;
    try std.testing.expectEqualStrings(prefix, intern.get(intern.moduleId(parts.module)));
    try std.testing.expectEqualStrings("missing", intern.get(intern.bindingId(parts.binding)));
    try std.testing.expectEqual(intern.Spelling.plain, intern.spelling(intern.moduleId(parts.module)));
}

test "module names: a spelling is one kind of word, and so is each of its parts" {
    try std.testing.expectEqual(intern.Spelling.plain, intern.spelling(try intern.intern("spelled-plain")));
    try std.testing.expectEqualStrings(
        "spelled-core",
        intern.get(intern.bindingId(intern.spelling(try intern.intern("core.spelled-core")).core)),
    );
    const nested = intern.spelling(try intern.intern("spelled.a.b.word")).qualified;
    try std.testing.expectEqualStrings("spelled.a.b", intern.get(intern.moduleId(nested.module)));
    try std.testing.expectEqualStrings("word", intern.get(intern.bindingId(nested.binding)));
    // The module part is a spelling too, decided before the whole.
    const outer = intern.spelling(intern.moduleId(nested.module)).qualified;
    try std.testing.expectEqualStrings("spelled.a", intern.get(intern.moduleId(outer.module)));
    try std.testing.expectEqualStrings("b", intern.get(intern.bindingId(outer.binding)));
    // `core` qualifies one segment; a longer name under it is a module's.
    const under_core = intern.spelling(try intern.intern("core.spelled.word")).qualified;
    try std.testing.expectEqualStrings("core.spelled", intern.get(intern.moduleId(under_core.module)));
    for ([_][]const u8{ ".spelled", "spelled.", "spelled..word", "spelled.:.word", "spelled.--" }) |bytes|
        try std.testing.expectEqual(intern.Spelling.malformed, intern.spelling(try intern.intern(bytes)));
}

test "module: long definition names stay within the cancellation bound" {
    const allocator = std.testing.allocator;
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 's');
    const long_name = try intern.internNamespace(name_bytes);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var name_runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .cooperative, .evaluate);
    defer name_runtime.deinit();
    try name_runtime.pushOwned(try list.fromValuesGeneric(allocator, &.{}));
    try name_runtime.pushOwned(try list.fromValuesGeneric(allocator, &.{}));
    try name_runtime.pushOwned(.{ .symbol = .{ .name = intern.namespaceId(long_name) } });
    try expectOk(&name_runtime, "`long-name set `second set `first set");
    try runtime_fixture.expectCancelledAcrossTurns(&name_runtime, "first second long-name @defm");
}

test "reflection: words is sorted unique and private-safe" {
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
        .ecl_path = null,
    }), .default, .evaluate);
    defer runtime.deinit();
    try expectOk(&runtime, "(1 `hidden setp 2 `zebra set 3 `alpha set) `m @defm " ++
        "`m (alpha zebra) import 4 `zebra set words");
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha").? < std.mem.indexOf(u8, rendered, "zebra").?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "zebra"));
}

fn expectInternMissing(bytes: []const u8) !void {
    var lookup = intern.lookupCursor(bytes);
    while (true) switch (lookup.advance()) {
        .pending => {},
        .complete => |found| {
            try std.testing.expectEqual(@as(?u32, null), found);
            return;
        },
    };
}

test "reflection remains cancellable across sorting and identifier output" {
    const allocator = std.testing.allocator;
    const first_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(first_bytes);
    @memset(first_bytes, 'q');
    first_bytes[first_bytes.len - 1] = 'a';
    const second_bytes = try allocator.dupe(u8, first_bytes);
    defer allocator.free(second_bytes);
    second_bytes[second_bytes.len - 1] = 'b';
    var discard_buffer: [256]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buffer);
    var runtime_inputs5 = try runtime_fixture.Fixture.init();
    defer runtime_inputs5.deinit();
    var words_runtime = try session.Session.init(allocator, &.{}, runtime_inputs5.inputs(.{ .output = &discarding.writer }), .cooperative, .evaluate);
    defer words_runtime.deinit();
    const define_both = try std.fmt.allocPrint(allocator, "(1) `{s} def (1) `{s} def", .{ first_bytes, second_bytes });
    defer allocator.free(define_both);
    try expectOk(&words_runtime, define_both);
    try runtime_fixture.expectCancelledAcrossTurns(&words_runtime, "words");
}

test "reflection failures are total" {
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();
    try expectErrorContains(&runtime, "5 see", &.{"kind type"});
    try expectErrorContains(&runtime, "`missing see", &.{"kind undefined-word"});
}

/// Redefines one top-level name once per count, from a word that recurses
/// through an inline `if` so each definition lands at root level.
const redefinition_churn = "(dup 0 = (pop) ((1) `churned def 1 - churn) if) `churn def";

/// Every fiber retains a fixed amount of source provenance, so the batches are
/// one fiber each and differ only in their count: a small batch fixes the
/// per-fiber cost, and a large one must not retain anything per redefinition.
/// The retained provenance accumulates in storage that grows by amortized
/// doubling, and which fiber pays for a doubling shifts with unrelated session
/// state. Each size therefore runs twice and keeps its smaller growth: a
/// doubling lands in at most one of the pair, while retention per
/// redefinition would show in both.
fn expectChurnBounded(runtime: *session.Session, counting: anytype, large: usize, settle: ?[]const u8) !void {
    var buffer: [32]u8 = undefined;
    const large_churn = try std.fmt.bufPrint(&buffer, "{d} churn", .{large});
    try expectOk(runtime, redefinition_churn);
    try expectOk(runtime, "64 churn");
    if (settle) |unit| try expectOk(runtime, unit);
    var small_growth: usize = std.math.maxInt(usize);
    var large_growth: usize = std.math.maxInt(usize);
    for (0..2) |_| {
        const before_small = counting.total_requested_bytes;
        try expectOk(runtime, "64 churn");
        if (settle) |unit| try expectOk(runtime, unit);
        const after_small = counting.total_requested_bytes;
        try expectOk(runtime, large_churn);
        if (settle) |unit| try expectOk(runtime, unit);
        const after_large = counting.total_requested_bytes;
        small_growth = @min(small_growth, after_small -| before_small);
        large_growth = @min(large_growth, after_large -| after_small);
    }
    std.testing.expect(large_growth <= small_growth + 4096) catch |err| {
        std.debug.print("redefinition churn: small_growth={d} large_growth={d}\n", .{ small_growth, large_growth });
        return err;
    };
}

test "session: public definition mutation settles retirement every turn" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .cooperative, .evaluate);
        defer runtime.deinit();
        // A replaced top-level definition nothing still holds is reclaimed,
        // so redefining one name settles to bounded live memory.
        try expectChurnBounded(&runtime, &counting, 1024, null);
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "acceptance: redefinition soak keeps live memory bounded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .cooperative, .evaluate);
        defer runtime.deinit();
        const soak = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            "test/acceptance/retention-soak.ecl",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(soak);

        // The fixture consumes its count and leaves the operand stack empty.
        // Warm both publication paths before measuring their settled live
        // memory. Increasing the update history by 64x must not retain a
        // corresponding chain of binding snapshots or module generations.
        try expectOk(&runtime, "16");
        try expectOk(&runtime, soak);
        const warmed_live_bytes = counting.total_requested_bytes;

        try expectOk(&runtime, "16");
        try expectOk(&runtime, soak);
        const after_small = counting.total_requested_bytes;

        try expectOk(&runtime, "1024");
        try expectOk(&runtime, soak);
        const after_large = counting.total_requested_bytes;

        const small_growth = after_small -| warmed_live_bytes;
        const large_growth = after_large -| after_small;
        try std.testing.expect(large_growth <= small_growth * 2 + 4096);
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "session: mutation settlement is independent of a busy sole worker" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = test_heap.stack_trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var runtime_inputs = try runtime_fixture.Fixture.init();
        defer runtime_inputs.deinit();
        var runtime = try session.Session.init(allocator, &.{}, runtime_inputs.inputs(.{}), .{ .worker_pool = 1 }, .evaluate);
        defer runtime.deinit();
        try expectOk(&runtime, "((1) () while) @spawn");
        // The spinner never stops. Its running turn is a reader, so what a
        // churn supersedes during that turn waits for the turn to end. Each
        // measurement therefore follows a unit that awaits two tasks: the
        // sole worker reaches them only by ending the spinner's turn, and
        // pays the retirement that turn's end released on its way. The unit
        // publishes nothing.
        const worker_turns = "(1) @spawn task.await pop (1) @spawn task.await pop";
        try expectChurnBounded(&runtime, &counting, 4096, worker_turns);
        try expectOk(&runtime, "dup task.cancel task.await pop");
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

const registry_workers = 4;
const registry_commits_per_worker = 50;

const RegistryThreadContext = struct {
    registry: *modules.Registry,
    environment: *env.Env,
    failed: *std.atomic.Value(bool),
    shared: intern.ModuleName,
    /// One fresh module name per commit, so a lost update loses a name.
    distinct: *const [registry_workers][registry_commits_per_worker]intern.ModuleName,
};

fn commitCandidate(context: RegistryThreadContext, name: intern.ModuleName) bool {
    const scope = context.environment.moduleScope(name) catch return false;
    var candidate = context.registry.createImage(scope, .ordinary) catch return false;
    defer candidate.deinit();
    var sealed = candidate.sealLiteralGroup() catch return false;
    defer sealed.deinit();
    modules.testing.register(context.registry, &sealed) catch return false;
    return true;
}

fn registryWorker(context: RegistryThreadContext, worker_id: usize) void {
    for (context.distinct[worker_id]) |name| {
        if (!commitCandidate(context, context.shared) or !commitCandidate(context, name)) {
            context.failed.store(true, .release);
            return;
        }
        if (!modules.testing.registered(context.registry, context.shared)) {
            context.failed.store(true, .release);
            return;
        }
    }
}

test "registry: concurrent commits are linearized without lost names" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var environment = try env.Env.init(&host);
    defer {
        // Images retire as deferred work, which must drain before the Env
        // frees the scopes they refer to.
        host.cleanup().drain();
        environment.deinit();
    }
    var registry = try modules.Registry.init(host.cleanup(), environment.claimCells());
    defer registry.deinit();
    var distinct: [registry_workers][registry_commits_per_worker]intern.ModuleName = undefined;
    for (&distinct, 0..) |*names, worker| {
        for (names, 0..) |*name, commit| {
            var buffer: [64]u8 = undefined;
            name.* = try intern.internModuleName(try std.fmt.bufPrint(&buffer, "worker-module-{d}-{d}", .{ worker, commit }));
        }
    }
    var failed = std.atomic.Value(bool).init(false);
    const context = RegistryThreadContext{
        .registry = &registry,
        .environment = &environment,
        .failed = &failed,
        .shared = try intern.internModuleName("shared-module"),
        .distinct = &distinct,
    };
    var threads: [registry_workers]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, registryWorker, .{ context, index });
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    // Every commit published from a snapshot no other commit had replaced,
    // so every name any worker registered is still in the directory.
    for (distinct) |names| for (names) |name| {
        if (!modules.testing.registered(&registry, name)) return error.LostRegistration;
    };
}

test "loader: failures and cycles are total" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime_inputs12 = try runtime_fixture.Fixture.init();
    defer runtime_inputs12.deinit();
    var runtime = try session.Session.init(std.testing.allocator, &.{}, runtime_inputs12.inputs(.{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = "test/acceptance/modules",
    }), .default, .evaluate);
    defer runtime.deinit();
    // An import loads nothing; each failure belongs to the imported word.
    try expectErrorContains(&runtime, "`missing-module (x) import x", &.{ "kind undefined-word", "word x" });
    try expectErrorContains(&runtime, "`cycle (x) import x", &.{ "kind domain", "never reach a definition" });
    // A file whose first form calls into the module it is loading asks for
    // that load again before it has registered anything.
    try expectErrorContains(&runtime, "selfload.x", &.{ "kind domain", "recursive auto-load of `", "test/acceptance/modules/selfload.ecl`" });
    try expectErrorContains(&runtime, "`orphan (x) import x", &.{ "kind undefined-word", "word x" });
    try expectErrorContains(&runtime, "\"test/acceptance/load-parse-error.ecl\" @load", &.{ "kind parse", "source \"test/acceptance/load-parse-error.ecl\"" });
    try expectErrorContains(&runtime, "\"test/acceptance/does-not-exist.ecl\" @load", &.{ "kind io", "path \"test/acceptance/does-not-exist.ecl\"" });

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.ecl", .data = &.{ 0xff, 0xfe } });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "incomplete.ecl", .data = "[1 2" });
    inline for (.{ "invalid.ecl", "incomplete.ecl" }) |filename| {
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, filename, std.testing.allocator);
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\" @load", .{path});
        defer std.testing.allocator.free(source);
        try expectErrorContains(&runtime, source, &.{ "kind parse", path });
    }
}

fn registryAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(&host);
    defer {
        // Images retire as deferred work, which must drain before the Env
        // frees the scopes they refer to.
        host.cleanup().drain();
        environment.deinit();
    }
    var registry = try modules.Registry.init(host.cleanup(), environment.claimCells());
    defer registry.deinit();
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .symbol = .{ .name = try intern.intern("--") } },
        .{ .symbol = .{ .name = try intern.intern("n") } },
    });
    defer releases.releaseValue(effect_value);
    const effect = (env.ValidatedEffect.parse(effect_value.list)).?;
    const document_value = try list.fromCodepoints(allocator, &.{ 'N', 'a', 't', 'i', 'v', 'e', '.' });
    defer releases.releaseValue(document_value);
    const document = env.documentation(document_value.list).?;
    const first_name = try intern.internModuleName("allocation-module");
    const second_name = try intern.internModuleName("allocation-second-module");
    const word_name = try intern.internNamespace("answer");
    var first = try registry.createImage(try environment.moduleScope(first_name), .ordinary);
    defer first.deinit();
    const constant = try TestBinding.init(allocator);
    defer releases.releaseValue(constant.body);
    try first.stageDefinition(word_name, .{ .word = .{
        .body = env.quotation(constant.body.list).?,
        .visibility = .public,
        .effect = effect,
        .doc = document,
    } });
    var first_sealed = try first.sealLiteralGroup();
    defer first_sealed.deinit();
    try modules.testing.register(&registry, &first_sealed);
    // A view held across the reload keeps the first generation readable.
    var held = registry.view();
    defer held.deinit();
    _ = held.moduleFind(first_name).?;
    var second = try registry.createImage(try environment.moduleScope(first_name), .ordinary);
    defer second.deinit();
    try second.stageDefinition(word_name, .{ .word = .{
        .body = env.quotation(constant.body.list).?,
        .visibility = .public,
        .effect = effect,
        .doc = document,
    } });
    var second_sealed = try second.sealLiteralGroup();
    defer second_sealed.deinit();
    try modules.testing.register(&registry, &second_sealed);
    var third = try registry.createImage(try environment.moduleScope(second_name), .ordinary);
    defer third.deinit();
    try third.stageDefinition(word_name, constant.module(effect, .public));
    var third_sealed = try third.sealLiteralGroup();
    defer third_sealed.deinit();
    try modules.testing.register(&registry, &third_sealed);
}

test "registry APIs propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registryAllocationProbe, .{});
}

// ── Milestone 10 (one-definition-merge) ──────────────────────────────────────

test "stdlib: embedded module names are reserved whether or not they have loaded" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    const reserved = "module name `dict` is reserved for the standard library";
    // `dict` has not loaded yet: the refusal cannot depend on that.
    try expectErrorContains(&runtime, "((a b -- c) (pop pop 0) `has? def) `dict @defm", &.{reserved});
    try expectOk(&runtime, "{a 1} [a] dict.has? [1] match? {kind user msg \"dict did not load\"} assert");
    // Loaded, it is refused the same way.
    try expectErrorContains(&runtime, "() `dict @defm", &.{reserved});
    try expectErrorContains(&runtime, "((a -- b) (pop \"bogus\") `new def) `error @defm", &.{"module name `error` is reserved"});
    // So the prelude and the other embedded modules keep their meaning.
    try expectOk(&runtime, "{a 1} `a 7 dict.get 1 = {kind user msg \"dict.get lost dict\"} assert");
    try expectOk(&runtime, "(\"abc\" -1 str.repeat) @attempt `err at `kind at `domain match? " ++
        "{kind user msg \"str lost error\"} assert");
    // A dotted name under a stdlib prefix is an ordinary module.
    try expectOk(&runtime, "((1) `one def) `dict.extra @defm dict.extra.one 1 = {kind user} assert");
}

test "stdlib: a quotation a stdlib word applies does not inherit its reservation exemption" {
    var backing: test_heap.SessionHeap = .init;
    defer test_heap.retire(&backing);
    var runtime_inputs = try runtime_fixture.Fixture.init();
    defer runtime_inputs.deinit();
    var runtime = try session.Session.init(backing.allocator(), &.{}, runtime_inputs.inputs(.{}), .default, .evaluate);
    defer runtime.deinit();

    const reserved = "module name `dict` is reserved for the standard library";
    // `map` applies the caller's quotation under `@attempt`, `either`
    // inline; neither runs it as standard-library code.
    try expectOk(&runtime, "[] result.ok (() `dict @defm []) result.map `err at `kind at `domain match? " ++
        "{kind user msg \"registration escaped\"} assert");
    try expectErrorContains(&runtime, "[] result.ok (() `dict @defm) () result.either", &.{reserved});
    try expectOk(&runtime, "{a 1} `a 7 dict.get 1 = {kind user msg \"dict.get lost dict\"} assert");
}
