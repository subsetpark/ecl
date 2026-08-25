//! Module tests whose allocator is load-bearing.
//!
//! Everything here either builds a value on the host and publishes it into a
//! session — where the value and the session must agree on their allocator, or
//! teardown aborts in `heap.freePayload` far from the line at fault — or owns a
//! counting allocator to state a memory bound. Both needs pin the file to
//! `std.testing.allocator` and to `DebugAllocator{ .enable_memory_limit }`.
//!
//! Module behavior that only runs source through a session lives in
//! `module_source_test.zig`, on the traceless session heap. Keeping the two
//! apart is what stops a tracing allocator from being charged to assertions
//! that never read a stack trace.
const std = @import("std");
const value = @import("../value.zig");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const modules = @import("../modules.zig");
const printer = @import("../print.zig");
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
    return dict.symbolField(allocator, error_value, try intern.intern(name));
}

test "session: transferred quotation provenance is absent from another archive" {
    const allocator = std.testing.allocator;
    var source_session = try session.Session.init(allocator, &.{});
    defer source_session.deinit();
    var destination_session = try session.Session.init(allocator, &.{});
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
    fn top(self: TestBinding) env.TopPublication {
        return .{ .word = .{ .body = env.quotation(self.body.list).? } };
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

const TestEffect = struct {
    source: value.Value,
    effect: env.ValidatedEffect,

    fn init(allocator: std.mem.Allocator) !TestEffect {
        const marker = try intern.intern("--");
        const source = try list.fromValuesGeneric(allocator, &.{.{ .word = .{ .name = marker } }});
        return .{ .source = source, .effect = env.ValidatedEffect.parse(source.list, marker).? };
    }
    fn release(self: TestEffect, releases: *heap.ReleaseDomain) void {
        releases.releaseValue(self.source);
    }
};

fn commitEmptyModule(registry: *modules.Registry, name: intern.ModuleName) !void {
    var candidate = try registry.createImage();
    defer candidate.deinit();
    var sealed = candidate.seal();
    defer sealed.deinit();
    _ = try registry.register(sealed.ref(), name);
}

test "module names: branded factories enforce the reader symbol grammar" {
    const invalid_segments = [_][]const u8{
        "bad name",
        "bad,name",
        "bad(name",
        "bad[name",
        "bad{name",
        "bad\"name",
        "bad#name",
        "bad'name",
        "bad\\name",
        "bad;name",
        "bad|name",
        "bad\u{00a0}name",
        "bad\u{2000}name",
        "bad\u{3000}name",
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

test "env: new names bump the shape generation and rebinding does not" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = env.Environment.init(std.testing.allocator, releases);
    defer env.testing.deinitEnvironment(&environment);
    var scope = env.Scope.moduleRoot(std.testing.allocator, &environment);
    defer env.testing.deinitScope(&scope, releases);
    const first = try intern.internNamespace("first-env-name");
    const second = try intern.internNamespace("second-env-name");
    const binding = try TestBinding.init(std.testing.allocator);
    defer binding.release(releases);
    const effect = try TestEffect.init(std.testing.allocator);
    defer effect.release(releases);
    _ = try scope.publisher().module.publish(first, binding.module(effect.effect, .public));
    try std.testing.expectEqual(@as(u64, 1), environment.shapeGeneration());
    _ = try scope.publisher().module.publish(second, binding.module(effect.effect, .public));
    try std.testing.expectEqual(@as(u64, 2), environment.shapeGeneration());
    // Creating a name publishes a shape; rebinding one replaces its cell in
    // place and publishes none. That asymmetry is why this counter is named
    // for shapes rather than for mutation: it is not a "did anything change"
    // signal and nothing may read it as one.
    _ = try scope.publisher().module.publish(first, binding.module(effect.effect, .public));
    try std.testing.expectEqual(@as(u64, 2), environment.shapeGeneration());
    const names = try environment.namesOwned(std.testing.allocator);
    defer std.testing.allocator.free(names);
    std.mem.sort(u32, names, {}, std.sort.asc(u32));
    var expected = [_]u32{ intern.namespaceId(first), intern.namespaceId(second) };
    std.mem.sort(u32, &expected, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &expected, names);
    scope.publisher().module.freeze();
    try std.testing.expectError(
        error.Frozen,
        scope.publisher().module.publish(first, binding.module(effect.effect, .public)),
    );
}

test "module: long definition names stay within the cancellation bound" {
    const allocator = std.testing.allocator;
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 's');
    const long_name = try intern.internNamespace(name_bytes);
    var name_runtime = try session.Session.init(allocator, &.{});
    defer name_runtime.deinit();
    try name_runtime.pushOwned(.{ .symbol = intern.namespaceId(long_name) });
    try name_runtime.pushOwned(try list.fromValuesGeneric(allocator, &.{}));
    name_runtime.requestCancellation();
    try expectErrorContains(&name_runtime, "@defm", &.{"unit cancelled"});
    try std.testing.expect(name_runtime.lastPolls() >= 1);
}

test "reflection: words is sorted unique and private-safe" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "(1 'hidden setp 2 'zebra set 3 'alpha set) 'm @defm " ++
        "'m.alpha 'alpha import 'm.zebra 'zebra import 4 'zebra set words");
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha").? < std.mem.indexOf(u8, rendered, "zebra").?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "zebra"));
}

fn containsCandidate(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

fn expectSortedUnique(items: []const []const u8) !void {
    for (items[1..], items[0..items.len -| 1]) |current, previous| {
        try std.testing.expect(std.mem.order(u8, previous, current) == .lt);
    }
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
    const first = try intern.internNamespace(first_bytes);
    const second = try intern.internNamespace(second_bytes);

    var discard_buffer: [256]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buffer);
    var words_runtime = try session.Session.initWithOutput(allocator, &.{}, &discarding.writer);
    defer words_runtime.deinit();
    const binding = try TestBinding.init(allocator);
    defer words_runtime.release(binding.body);
    try words_runtime.define(first, binding.top());
    try words_runtime.define(second, binding.top());
    words_runtime.requestCancellation();
    const words_failure = (try words_runtime.runUnit("reflection-poll.ecl", "words")).err;
    defer words_runtime.release(words_failure);
    const words_rendered = try printer.toOwnedString(allocator, words_failure);
    defer allocator.free(words_rendered);
    try std.testing.expect(std.mem.indexOf(u8, words_rendered, "unit cancelled") != null);
    try std.testing.expect(words_runtime.lastPolls() >= 1);

    var which_output = std.Io.Writer.Allocating.init(allocator);
    defer which_output.deinit();
    var which_runtime = try session.Session.initWithOutput(allocator, &.{}, &which_output.writer);
    defer which_runtime.deinit();
    try which_runtime.define(first, binding.top());
    try which_runtime.pushOwned(.{ .symbol = intern.namespaceId(first) });
    which_runtime.requestCancellation();
    const which_failure = (try which_runtime.runUnit("reflection-poll.ecl", "which")).err;
    defer which_runtime.release(which_failure);
    const which_rendered = try printer.toOwnedString(allocator, which_failure);
    defer allocator.free(which_rendered);
    try std.testing.expect(std.mem.indexOf(u8, which_rendered, "unit cancelled") != null);
    try std.testing.expect(which_runtime.lastPolls() >= 1);
    try std.testing.expectEqual(@as(usize, 0), which_output.written().len);

    const qualified_bytes = try allocator.alloc(u8, "poll-module.".len + first_bytes.len);
    defer allocator.free(qualified_bytes);
    @memcpy(qualified_bytes[0.."poll-module.".len], "poll-module.");
    @memcpy(qualified_bytes["poll-module.".len..], first_bytes);
    const qualified = try intern.intern(qualified_bytes);
    var qualified_output = std.Io.Writer.Allocating.init(allocator);
    defer qualified_output.deinit();
    var qualified_runtime = try session.Session.initWithOutput(allocator, &.{}, &qualified_output.writer);
    defer qualified_runtime.deinit();
    const module_source = try std.fmt.allocPrint(
        allocator,
        "(1 '{s} set) 'poll-module @defm",
        .{first_bytes},
    );
    defer allocator.free(module_source);
    try expectOk(&qualified_runtime, module_source);
    try qualified_runtime.pushOwned(.{ .symbol = qualified });
    qualified_runtime.requestCancellation();
    const qualified_failure = (try qualified_runtime.runUnit("reflection-poll.ecl", "which")).err;
    defer qualified_runtime.release(qualified_failure);
    const qualified_rendered = try printer.toOwnedString(allocator, qualified_failure);
    defer allocator.free(qualified_rendered);
    try std.testing.expect(std.mem.indexOf(u8, qualified_rendered, "unit cancelled") != null);
    try std.testing.expect(qualified_runtime.lastPolls() >= 1);
    try std.testing.expectEqual(@as(usize, 0), qualified_output.written().len);
}

test "reflection failures are total" {
    var no_output = try session.Session.init(std.testing.allocator, &.{});
    defer no_output.deinit();
    try expectErrorContains(&no_output, "words", &.{"'kind 'io"});
    try expectErrorContains(&no_output, "'missing which", &.{"'kind 'undefined-word"});
}

const EnvThreadContext = struct {
    scope: *env.Scope,
    environment: env.EnvironmentView,
    failed: *std.atomic.Value(bool),
    name: intern.NamespaceName,
    publication: env.TopPublication,
};

fn envWorker(context: EnvThreadContext) void {
    for (0..100) |_| {
        _ = context.scope.publisher().top.publish(
            context.name,
            context.publication,
        ) catch {
            context.failed.store(true, .release);
            return;
        };
        var lease = (context.environment.resolveDirect(
            intern.namespaceId(context.name),
        )) orelse {
            context.failed.store(true, .release);
            return;
        };
        lease.deinit();
    }
}

/// Distinct interned names for shape-history churn. Creating a name is the
/// only production path that publishes a new environment shape — rebinding an
/// existing name replaces its cell in place — so a shape-history property has
/// to walk a pool of fresh names. That is why the churn counts here are
/// smaller than the retired `use`-order edits they replace: each new name
/// republishes a cloned name map, making the pass quadratic in publications
/// where a use edit was linear.
const NamePool = struct {
    allocator: std.mem.Allocator,
    names: []intern.NamespaceName,

    fn init(
        allocator: std.mem.Allocator,
        prefix: []const u8,
        count: usize,
    ) !NamePool {
        const names = try allocator.alloc(intern.NamespaceName, count);
        errdefer allocator.free(names);
        var buffer: [96]u8 = undefined;
        for (names, 0..) |*slot, index| {
            const spelling = try std.fmt.bufPrint(&buffer, "{s}-{d}", .{ prefix, index });
            slot.* = try intern.internNamespace(spelling);
        }
        return .{ .allocator = allocator, .names = names };
    }

    fn deinit(self: NamePool) void {
        self.allocator.free(self.names);
    }
};

const ReclamationRaceContext = struct {
    scope: *env.Scope,
    environment: env.EnvironmentView,
    releases: *heap.ReleaseDomain,
    name: intern.NamespaceName,
    churn: []const intern.NamespaceName,
    publication: env.TopPublication,
    phase: *std.atomic.Value(u8),
    writer_done: *std.atomic.Value(bool),
    reader_loop_started: *std.atomic.Value(bool),
    reader_done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
};

fn yieldUntilPhase(phase: *const std.atomic.Value(u8), minimum: u8) void {
    while (phase.load(.acquire) < minimum)
        std.Thread.yield() catch @panic("snapshot race yield failed");
}

fn reclamationReader(context: ReclamationRaceContext) void {
    var lookup = context.environment.directLookupCursor(intern.namespaceId(context.name));
    context.phase.store(1, .release);
    yieldUntilPhase(context.phase, 2);
    while (true) switch (lookup.advance()) {
        .pending => {},
        .complete => |maybe_old| {
            var old = maybe_old orelse {
                context.failed.store(true, .release);
                break;
            };
            // Identity of the resolved body is the reader-visible fact: a
            // torn or stale snapshot would not carry the published quotation.
            if (old.binding != .word or old.binding.word != context.publication.word.body)
                context.failed.store(true, .release);
            old.deinit();
            break;
        },
    };
    // Publication cannot hand the old shape chain to reclamation while this
    // production cursor still owns the Publisher lease. Its final release is
    // the event that makes retirement visible to the domain.
    if (context.releases.hasPending()) context.failed.store(true, .release);
    lookup.deinit();
    if (!context.releases.hasPending()) context.failed.store(true, .release);
    context.phase.store(3, .release);

    // Acquire the next production snapshot before the second publication.
    // The writer then supersedes it and the reclaimer takes a real bounded
    // turn while this exact lease is still active. This orders all three
    // participants without replacing their production operations with test
    // hooks.
    var raced = context.environment.directLookupCursor(intern.namespaceId(context.name));
    context.phase.store(4, .release);
    yieldUntilPhase(context.phase, 6);
    while (true) switch (raced.advance()) {
        .pending => {},
        .complete => |maybe_value| {
            var observed = maybe_value orelse {
                context.failed.store(true, .release);
                break;
            };
            if (observed.binding != .word or observed.binding.word != context.publication.word.body)
                context.failed.store(true, .release);
            observed.deinit();
            break;
        },
    };
    raced.deinit();

    context.reader_loop_started.store(true, .release);
    for (0..1024) |_| {
        var current = context.environment.directLookupCursor(intern.namespaceId(context.name));
        defer current.deinit();
        while (true) switch (current.advance()) {
            .pending => {},
            .complete => |maybe_value| {
                var observed = maybe_value orelse {
                    context.failed.store(true, .release);
                    break;
                };
                if (observed.binding != .word or observed.binding.word != context.publication.word.body)
                    context.failed.store(true, .release);
                observed.deinit();
                break;
            },
        };
        std.Thread.yield() catch @panic("snapshot reader yield failed");
    }
    context.reader_done.store(true, .release);
}

fn reclamationWriter(context: ReclamationRaceContext) void {
    const first_batch = context.churn.len / 2;
    yieldUntilPhase(context.phase, 1);
    for (context.churn[0..first_batch]) |name| _ = context.scope.publisher().top.publish(
        name,
        context.publication,
    ) catch {
        context.failed.store(true, .release);
        context.phase.store(2, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.phase.store(2, .release);
    yieldUntilPhase(context.phase, 3);
    yieldUntilPhase(context.phase, 4);
    _ = context.scope.publisher().top.publish(
        context.churn[first_batch],
        context.publication,
    ) catch {
        context.failed.store(true, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.phase.store(5, .release);
    while (!context.reader_loop_started.load(.acquire))
        std.Thread.yield() catch @panic("snapshot writer yield failed");
    for (context.churn[first_batch + 1 ..]) |name| _ = context.scope.publisher().top.publish(
        name,
        context.publication,
    ) catch {
        context.failed.store(true, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.writer_done.store(true, .release);
}

fn reclamationWorker(context: ReclamationRaceContext) void {
    yieldUntilPhase(context.phase, 5);
    _ = context.releases.advance(1);
    context.phase.store(6, .release);
    while (!context.writer_done.load(.acquire) or
        !context.reader_done.load(.acquire) or
        context.releases.hasPending())
    {
        _ = context.releases.advance(1);
        std.Thread.yield() catch @panic("snapshot reclaimer yield failed");
    }
}

test "env: concurrent cell publication is lease-safe and TSan-clean" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var container = try env.Env.init(host.cleanup());
    defer container.deinit();
    var scope = container.sessionRoot(std.testing.allocator);
    defer env.testing.deinitScope(&scope, releases);
    var failed = std.atomic.Value(bool).init(false);
    const binding = try TestBinding.init(std.testing.allocator);
    defer binding.release(releases);
    const context = EnvThreadContext{
        .scope = &scope,
        .environment = container.sessionView(),
        .failed = &failed,
        .publication = binding.top(),
        .name = try intern.internNamespace("concurrent-env-name"),
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, envWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    // Four threads race to bind the same name: exactly one creates it, and
    // the three that lose rebind the cell without publishing a shape.
    try std.testing.expectEqual(@as(u64, 1), container.sessionView().shapeGeneration());
}

test "env: concurrent readers writers and retirement reclaim production snapshots" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var container = try env.Env.init(host.cleanup());
    defer container.deinit();
    var scope = container.sessionRoot(std.testing.allocator);
    defer env.testing.deinitScope(&scope, releases);
    const name = try intern.internNamespace("concurrent-reclamation");
    const binding = try TestBinding.init(std.testing.allocator);
    defer binding.release(releases);
    _ = try scope.publisher().top.publish(name, binding.top());
    const churn = try NamePool.init(std.testing.allocator, "reclamation-churn", 256);
    defer churn.deinit();
    host.cleanup().drain();
    var phase: std.atomic.Value(u8) = .init(0);
    var writer_done: std.atomic.Value(bool) = .init(false);
    var reader_loop_started: std.atomic.Value(bool) = .init(false);
    var reader_done: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);
    const context = ReclamationRaceContext{
        .scope = &scope,
        .environment = container.sessionView(),
        .releases = releases,
        .name = name,
        .churn = churn.names,
        .publication = binding.top(),
        .phase = &phase,
        .writer_done = &writer_done,
        .reader_loop_started = &reader_loop_started,
        .reader_done = &reader_done,
        .failed = &failed,
    };
    const reader_thread = try std.Thread.spawn(.{}, reclamationReader, .{context});
    const writer_thread = try std.Thread.spawn(.{}, reclamationWriter, .{context});
    const reclaimer_thread = try std.Thread.spawn(.{}, reclamationWorker, .{context});
    reader_thread.join();
    writer_thread.join();
    reclaimer_thread.join();
    try std.testing.expect(!failed.load(.acquire));
    var current = container.sessionView().resolveDirect(intern.namespaceId(name)).?;
    defer current.deinit();
    try std.testing.expectEqual(env.quotation(binding.body.list).?, current.binding.word);
}

// PENDING: scope cells are keyed to the *image* that published a generation,
// and a name-keyed cell is the fix. Two consequences are asserted below and
// fail today; neither is a coding slip, and neither is fixed by weakening what
// they assert:
//
//   * Boundedness. Every published generation adds a cell, and those cells must
//     outlive their images because a word carries a bare id and takes no
//     reference, so nothing can tell when a generation's cell has no surviving
//     words. Thousands of re-registrations therefore grow live memory. One cell
//     per *name*, re-pointed on each generation, removes the growth entirely.
//
//   * Double registration. One image registered under two names has one cell,
//     and whichever registration commits first claims it; retiring that name
//     strands the other. A name-keyed cell gives each name its own, and an
//     image that was never registered keeps its own.
//
// Tracked as the `name-keyed-scope-cells` follow-up. Do not relax the bounds
// below to make these pass: they encode the guarantee the follow-up must meet.
const name_keyed_cells_pending = true;

test "environment and registry retirement stays bounded after a delayed reader drains" {
    if (name_keyed_cells_pending) return error.SkipZigTest;
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        defer host.cleanup().drain();
        var environment = try env.Env.init(host.cleanup());
        defer environment.deinit();
        var scope = environment.sessionRoot(allocator);
        defer env.testing.deinitScope(&scope, releases);
        var registry = try modules.Registry.init(host.cleanup(), environment);
        defer registry.deinit();

        const binding_name = try intern.internNamespace("bounded-binding");
        const module_name = try intern.internModuleName("bounded-module");
        const alternate_module = try intern.internModuleName("bounded-module-alternate");
        const alias_name = try intern.internNamespace("bounded-module-alias");
        const binding = try TestBinding.init(allocator);
        defer binding.release(releases);
        _ = try scope.publisher().top.publish(binding_name, binding.top());

        // One public shape lease deliberately delays reclamation while a long
        // shape history accumulates. Releasing it must transfer the whole
        // history to bounded retirement work rather than freeing it on the
        // reader's stack. The names are distinct because that is the only
        // production path that publishes a shape.
        const shape_churn = try NamePool.init(allocator, "bounded-shape-churn", 256);
        defer shape_churn.deinit();
        var delayed = environment.sessionView().acquireShape();
        for (shape_churn.names) |churn_name| _ = try scope.publisher().top.publish(churn_name, binding.top());
        delayed.deinit();
        host.cleanup().drain();

        // Hold a production AcquireCursor's real Directory lease while both
        // alias replacement and distinct-module publication build a retired
        // directory history. Releasing the cursor must only detach and enqueue
        // that history; the shared domain reclaims it one record per turn.
        try commitEmptyModule(&registry, module_name);
        try commitEmptyModule(&registry, alternate_module);
        try registry.alias(alias_name, module_name);
        var delayed_directory = registry.acquireCursor(module_name);
        for (0..512) |index| try registry.alias(
            alias_name,
            if (index & 1 == 0) alternate_module else module_name,
        );
        var distinct_name_buffer: [64]u8 = undefined;
        for (0..64) |index| {
            const spelling = try std.fmt.bufPrint(
                &distinct_name_buffer,
                "bounded-distinct-module-{d}",
                .{index},
            );
            try commitEmptyModule(&registry, try intern.internModuleName(spelling));
        }
        delayed_directory.deinit();
        host.cleanup().drain();

        for (0..128) |index| {
            _ = try scope.publisher().top.publish(binding_name, binding.top());
            try commitEmptyModule(&registry, module_name);
            try registry.alias(
                alias_name,
                if (index & 1 == 0) module_name else alternate_module,
            );
            _ = releases.advance(256);
        }
        host.cleanup().drain();
        const warmed_live_bytes = counting.total_requested_bytes;

        // Rebinding, re-registration, and alias replacement only: this batch
        // states a bound, and creating names would grow live state instead.
        for (0..2048) |index| {
            _ = try scope.publisher().top.publish(binding_name, binding.top());
            try commitEmptyModule(&registry, module_name);
            try registry.alias(
                alias_name,
                if (index & 1 == 0) module_name else alternate_module,
            );
            _ = releases.advance(256);
        }
        host.cleanup().drain();
        try std.testing.expect(counting.total_requested_bytes <= warmed_live_bytes + 4096);
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "session: public definition mutation settles retirement every turn" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
        defer runtime.deinit();
        const name = try intern.internNamespace("public-mutation-retirement");
        const binding = try TestBinding.init(allocator);
        defer runtime.release(binding.body);
        for (0..64) |_| try runtime.define(name, binding.top());
        const warmed_live_bytes = counting.total_requested_bytes;
        for (0..1024) |_| try runtime.define(name, binding.top());
        try std.testing.expect(counting.total_requested_bytes <= warmed_live_bytes + 4096);
        try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "acceptance: definition and module re-registration soak keeps live memory bounded" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
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
        try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "session: mutation settlement is independent of a busy sole worker" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .{ .worker_pool = 1 });
        defer runtime.deinit();
        try expectOk(&runtime, "((1) () while) @spawn");
        const name = try intern.internNamespace("busy-worker-retirement");
        const binding = try TestBinding.init(allocator);
        defer runtime.release(binding.body);
        for (0..64) |_| try runtime.define(name, binding.top());
        const warmed_live_bytes = counting.total_requested_bytes;
        for (0..4096) |_| try runtime.define(name, binding.top());
        try std.testing.expect(counting.total_requested_bytes <= warmed_live_bytes + 4096);
        try std.testing.expectEqual(@as(usize, 1), runtime.schedulerWorkerThreadCount());
        try expectOk(&runtime, "dup cancel await pop");
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "env: a replaced interior remains valid only through its binding lease" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer environment.deinit();
    var scope = environment.sessionRoot(std.testing.allocator);
    defer env.testing.deinitScope(&scope, releases);
    const separator = try intern.intern("--");
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .word = .{ .name = separator } }});
    defer releases.releaseValue(body);
    const document = try list.fromCodepoints(std.testing.allocator, &.{ 'd', 'o', 'c' });
    defer releases.releaseValue(document);
    const effect = (env.ValidatedEffect.parse(body.list, separator)).?;
    const name = try intern.internNamespace("leased-metadata");
    _ = try scope.publisher().top.publish(name, .{ .word = .{
        .body = env.quotation(body.list).?,
        .effect = effect,
        .doc = env.documentation(document.list).?,
    } });
    var old = (environment.sessionView().resolveDirect(intern.namespaceId(name))).?;
    // The replacement deliberately shares nothing with the original body, so
    // the old lease is the only thing still holding it.
    const replacement = try TestBinding.init(std.testing.allocator);
    defer replacement.release(releases);
    _ = try scope.publisher().top.publish(name, replacement.top());
    _ = releases.advance(1);
    try std.testing.expectEqual(@as(u32, 3), heap.refCount(body.list));
    old.deinit();
    host.cleanup().drain();
    try std.testing.expectEqual(@as(u32, 1), heap.refCount(body.list));
}

const RegistryThreadContext = struct {
    registry: *modules.Registry,
    failed: *std.atomic.Value(bool),
    shared: intern.ModuleName,
    disjoint: [4]intern.ModuleName,
};

fn commitCandidate(context: RegistryThreadContext, name: intern.ModuleName) bool {
    var candidate = context.registry.createImage() catch return false;
    defer candidate.deinit();
    var sealed = candidate.seal();
    defer sealed.deinit();
    _ = context.registry.register(sealed.ref(), name) catch return false;
    return true;
}

fn registryWorker(context: RegistryThreadContext, worker_id: u32) void {
    for (0..50) |_| {
        if (!commitCandidate(context, context.shared) or
            !commitCandidate(context, context.disjoint[worker_id]))
        {
            context.failed.store(true, .release);
            return;
        }
        var lease = modules.testing.acquire(context.registry, context.shared) orelse {
            context.failed.store(true, .release);
            return;
        };
        if (lease.generationNumber() == 0) context.failed.store(true, .release);
        lease.deinit();
    }
}

test "registry: concurrent commits are linearized without lost names" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer {
        // Images clear their Env-owned scope-label cell as they
        // retire, so that work must drain before the Env frees them.
        host.cleanup().drain();
        environment.deinit();
    }
    var registry = try modules.Registry.init(host.cleanup(), environment);
    defer registry.deinit();
    var failed = std.atomic.Value(bool).init(false);
    const context = RegistryThreadContext{
        .registry = &registry,
        .failed = &failed,
        .shared = try intern.internModuleName("shared-module"),
        .disjoint = .{
            try intern.internModuleName("worker-module-0"),
            try intern.internModuleName("worker-module-1"),
            try intern.internModuleName("worker-module-2"),
            try intern.internModuleName("worker-module-3"),
        },
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, registryWorker, .{ context, @as(u32, @intCast(index)) });
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    var lease = modules.testing.acquire(&registry, context.shared).?;
    defer lease.deinit();
    try std.testing.expectEqual(@as(u64, 200), lease.generationNumber());
    for (0..4) |index| {
        var disjoint = modules.testing.acquire(&registry, context.disjoint[index]).?;
        defer disjoint.deinit();
        try std.testing.expectEqual(@as(u64, 50), disjoint.generationNumber());
    }
}

test "registry: old generation leases survive reload and reclaim after release" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer {
        // Images clear their Env-owned scope-label cell as they
        // retire, so that work must drain before the Env frees them.
        host.cleanup().drain();
        environment.deinit();
    }
    var registry = try modules.Registry.init(host.cleanup(), environment);
    defer registry.deinit();
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 7 }});
    defer releases.releaseValue(body);
    const module_name = try intern.internModuleName("leased-generation");
    const value_name = try intern.internNamespace("leased-value");
    var first = try registry.createImage();
    defer first.deinit();
    const effect = try TestEffect.init(std.testing.allocator);
    defer effect.release(releases);
    _ = try first.publishDefinition(value_name, .{ .word = .{
        .body = env.quotation(body.list).?,
        .visibility = .public,
        .effect = effect.effect,
    } });
    var first_sealed = first.seal();
    defer first_sealed.deinit();
    _ = try registry.register(first_sealed.ref(), module_name);
    var old = modules.testing.acquire(&registry, module_name).?;
    var second = try registry.createImage();
    defer second.deinit();
    var second_sealed = second.seal();
    defer second_sealed.deinit();
    _ = try registry.register(second_sealed.ref(), module_name);
    try std.testing.expectEqual(@as(u64, 1), old.generationNumber());
    try std.testing.expectEqual(@as(u32, 2), heap.refCount(body.list));
    old.deinit();
    // Construction and registration are independent owners now, so the test's
    // own sealed-image reference is the other retainer of the definition body;
    // the superseded generation reclaims only once both are gone.
    first_sealed.deinit();
    host.cleanup().drain();
    try std.testing.expectEqual(@as(u32, 1), heap.refCount(body.list));
}

test "registry: generation cursors independently pin their snapshot" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer {
        // Images clear their Env-owned scope-label cell as they
        // retire, so that work must drain before the Env frees them.
        host.cleanup().drain();
        environment.deinit();
    }
    var registry = try modules.Registry.init(host.cleanup(), environment);
    defer registry.deinit();
    const module_name = try intern.internModuleName("cursor-pinned-generation");
    const value_name = try intern.internNamespace("cursor-pinned-value");
    var first = try registry.createImage();
    defer first.deinit();
    const binding = try TestBinding.init(std.testing.allocator);
    defer binding.release(releases);
    const effect = try TestEffect.init(std.testing.allocator);
    defer effect.release(releases);
    _ = try first.publishDefinition(value_name, binding.module(effect.effect, .public));
    var first_sealed = first.seal();
    defer first_sealed.deinit();
    _ = try registry.register(first_sealed.ref(), module_name);

    var lease = modules.testing.acquire(&registry, module_name).?;
    var lookup = lease.resolveCursor(intern.namespaceId(value_name));
    var names = lease.publicNameCursor();
    lease.deinit();
    var second = try registry.createImage();
    defer second.deinit();
    var second_sealed = second.seal();
    defer second_sealed.deinit();
    _ = try registry.register(second_sealed.ref(), module_name);
    for (0..64) |_| _ = releases.advance(1);

    const old = while (true) switch (lookup.advance()) {
        .pending => {},
        .complete => |resolved| break resolved.?,
    };
    var old_binding = old;
    defer old_binding.deinit();
    try std.testing.expectEqual(env.quotation(binding.body.list).?, old_binding.binding.word);
    const old_name = while (true) switch (names.advance()) {
        .pending => {},
        .complete => return error.TestUnexpectedResult,
        .item => |name| break name,
    };
    try std.testing.expectEqual(intern.namespaceId(value_name), old_name);
    lookup.deinit();
    names.deinit();
    host.cleanup().drain();
}

test "loader: failures and cycles are total" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = "test/acceptance/modules",
        },
    );
    defer runtime.deinit();
    try expectErrorContains(&runtime, "'missing-module.x 'x import", &.{ "'kind 'undefined-word", "'name 'missing-module.x" });
    try expectErrorContains(&runtime, "'cycle.x 'x import", &.{ "'kind 'domain", "recursive auto-load" });
    try expectErrorContains(&runtime, "'orphan.x 'x import", &.{
        "'kind 'io",
        "registered nothing under that name",
        "'path \"test/acceptance/modules/orphan.ecl\"",
    });
    try expectErrorContains(&runtime, "\"test/acceptance/load-parse-error.ecl\" load", &.{ "'kind 'parse", "'source \"test/acceptance/load-parse-error.ecl\"" });
    try expectErrorContains(&runtime, "\"test/acceptance/does-not-exist.ecl\" load", &.{ "'kind 'io", "'path \"test/acceptance/does-not-exist.ecl\"" });

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.ecl", .data = &.{ 0xff, 0xfe } });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "incomplete.ecl", .data = "[1 2" });
    inline for (.{ "invalid.ecl", "incomplete.ecl" }) |filename| {
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, filename, std.testing.allocator);
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\" load", .{path});
        defer std.testing.allocator.free(source);
        try expectErrorContains(&runtime, source, &.{ "'kind 'parse", path });
    }

    var no_host = try session.Session.init(std.testing.allocator, &.{});
    defer no_host.deinit();
    try expectErrorContains(&no_host, "\"test/acceptance/load-stack.ecl\" load", &.{"'kind 'io"});
}

fn environmentAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer environment.deinit();
    var scope = environment.sessionRoot(allocator);
    defer env.testing.deinitScope(&scope, releases);
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer releases.releaseValue(body);
    const first = try intern.internNamespace("allocation-first");
    const second = try intern.internNamespace("allocation-second");
    const third = try intern.internNamespace("allocation-third");
    _ = try scope.publisher().top.publish(first, .{ .word = .{
        .body = env.quotation(body.list).?,
    } });
    var lease = (environment.sessionView().resolveDirect(intern.namespaceId(first))).?;
    defer lease.deinit();
    _ = try scope.publisher().top.publish(first, .{ .word = .{ .body = env.quotation(body.list).? } });
    _ = try scope.publisher().top.publish(second, .{ .word = .{ .body = env.quotation(body.list).? } });
    _ = try scope.publisher().top.publish(third, .{ .word = .{ .body = env.quotation(body.list).? } });
    const names = try environment.sessionView().namesOwned(allocator);
    allocator.free(names);
}

fn registryAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer {
        // Images clear their Env-owned scope-label cell as they
        // retire, so that work must drain before the Env frees them.
        host.cleanup().drain();
        environment.deinit();
    }
    var registry = try modules.Registry.init(host.cleanup(), environment);
    defer registry.deinit();
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .word = .{ .name = try intern.intern("--") } },
        .{ .word = .{ .name = try intern.intern("n") } },
    });
    defer releases.releaseValue(effect_value);
    const separator = try intern.intern("--");
    const effect = (env.ValidatedEffect.parse(effect_value.list, separator)).?;
    const document_value = try list.fromCodepoints(allocator, &.{ 'N', 'a', 't', 'i', 'v', 'e', '.' });
    defer releases.releaseValue(document_value);
    const document = env.documentation(document_value.list).?;
    const first_name = try intern.internModuleName("allocation-module");
    const alias_name = try intern.internNamespace("allocation-alias");
    const second_name = try intern.internModuleName("allocation-second-module");
    const word_name = try intern.internNamespace("answer");
    var first = try registry.createImage();
    defer first.deinit();
    _ = try first.publishDefinition(word_name, .{ .word = .{
        .body = env.quotation(effect_value.list).?,
        .visibility = .public,
        .effect = effect,
        .doc = document,
    } });
    var first_sealed = first.seal();
    defer first_sealed.deinit();
    _ = try registry.register(first_sealed.ref(), first_name);
    try registry.alias(alias_name, first_name);
    var lease = modules.testing.acquire(&registry, try intern.internModuleName("allocation-alias")).?;
    defer lease.deinit();
    var second = try registry.createImage();
    defer second.deinit();
    _ = try second.publishDefinition(word_name, .{ .word = .{
        .body = env.quotation(effect_value.list).?,
        .visibility = .public,
        .effect = effect,
        .doc = document,
    } });
    var second_sealed = second.seal();
    defer second_sealed.deinit();
    _ = try registry.register(second_sealed.ref(), first_name);
    var third = try registry.createImage();
    defer third.deinit();
    const constant = try TestBinding.init(allocator);
    defer releases.releaseValue(constant.body);
    _ = try third.publishDefinition(word_name, constant.module(effect, .public));
    var third_sealed = third.seal();
    defer third_sealed.deinit();
    _ = try registry.register(third_sealed.ref(), second_name);
}

test "environment and registry APIs propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, environmentAllocationProbe, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registryAllocationProbe, .{});
}

// ── Milestone 10 (one-binder-merge) ──────────────────────────────────────
