const std = @import("std");
const env = @import("env.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const modules = @import("modules.zig");
const printer = @import("print.zig");
const session = @import("session.zig");

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    const outcome = try runtime.runUnit("module-test.ecl", source);
    switch (outcome) {
        .ok => {},
        .err => |failure| {
            defer heap.releaseValue(runtime.allocator, failure);
            const rendered = try printer.toOwnedString(runtime.allocator, failure);
            defer runtime.allocator.free(rendered);
            std.debug.print("unexpected ecl error: {s}\n", .{rendered});
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
    defer heap.releaseValue(runtime.allocator, failure);
    const rendered = try printer.toOwnedString(runtime.allocator, failure);
    defer runtime.allocator.free(rendered);
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
}

test "env: new names and use edits bump shape and deep lookup is ordered" {
    var environment = env.Environment.init(std.testing.allocator);
    defer environment.deinit();
    _ = try environment.bind(1, .{ .value = .{ .int = 1 } });
    try std.testing.expectEqual(@as(u64, 1), environment.generation());
    _ = try environment.bind(2, .{ .value = .{ .int = 2 } });
    try std.testing.expectEqual(@as(u64, 2), environment.generation());
    try environment.moveUseToTop(8);
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try environment.moveUseToTop(8);
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try environment.moveUseToTop(9);
    try environment.moveUseToTop(8);
    try std.testing.expectEqualSlices(u32, &.{ 9, 8 }, environment.useOrder());
    const names = try environment.namesOwned(std.testing.allocator);
    defer std.testing.allocator.free(names);
    std.mem.sort(u32, names, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, names);
    environment.freeze();
    try std.testing.expectError(error.Frozen, environment.bind(3, .{ .value = .{ .int = 3 } }));
}

test "scope: isolated attempt dict and child use do not leak" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectErrorContains(&runtime, "(1 'k let) attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "((1 'k let missing) attempt pop) attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "(1 'k let 'v 2) dict-of pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "((1 'k let 'v) dict-of) attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectOk(&runtime, "'m (7 'x let) module");
    try expectErrorContains(&runtime, "('m use x) attempt pop x", &.{ "'kind 'undefined-word", "'word 'x" });
}

test "module: privacy module-body contract top-level private and qualified trace" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (40 's letp (s 2 +) ( -- n ) 'f def) module m.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stack.items[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "'private-word ((41) ( -- n ) 'g defp (g 1 +) ( -- n ) 'f def) module private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stack.items[1].int);
    try expectErrorContains(&runtime, "private-word.g", &.{ "'kind 'undefined-word", "'word 'private-word.g" });
    try expectErrorContains(&runtime, "1 'x letp", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'bad (1) module", &.{ "'kind 'contract", "observed 1" });
    try expectErrorContains(&runtime, "bad.x", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'temporary ((1 'hidden let) attempt pop) module");
    try expectErrorContains(&runtime, "temporary.hidden", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'trace-module ((missing) ( -- n ) 'boom def) module");
    try expectErrorContains(&runtime, "trace-module.boom", &.{ "'word 'missing", "'trace ['missing 'trace-module.boom]" });
    try expectOk(&runtime, "'recursive ((dup 0 > (1 - f 1 +) (pop missing) if) ( n -- n ) 'f def) module");
    try expectErrorContains(&runtime, "2 recursive.f", &.{"'trace ['missing 'recursive.f 'recursive.f 'recursive.f]"});
}

test "module: qualified use alias ordering idempotence and collisions" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'a (1 'x let) module 'b (2 'x let) module " ++
        "'a use 'b use x 'a use x 'short 'a alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[2].int);
    try expectErrorContains(&runtime, "'a 'b alias", &.{"'kind 'domain"});
    try expectOk(&runtime, "'short 'b alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[3].int);
    try expectErrorContains(&runtime, "'future 'a alias 'future (3 'x let) module", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'dotted.name 'a alias", &.{"'kind 'domain"});
}

test "module: hot reload commit failure and whole-body pinning" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (1 'x letp " ++
        "('m (2 'x letp (x) ( -- n ) 'get def) module x) ( -- n ) 'probe def " ++
        "(x) ( -- n ) 'get def) module m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[1].int);
    try expectErrorContains(&runtime, "'m (3 'x letp missing) module", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "m.get");
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[2].int);
    try expectErrorContains(&runtime, "'kept ((9) ( -- n ) 'get def) module missing", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "kept.get");
    try std.testing.expectEqual(@as(i64, 9), runtime.stack.items[3].int);
}

test "module: effect shape cross-home contract and same-home TCO" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectErrorContains(&runtime, "'bad ((dup) 'f def) module", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'bad ((dup) (a -- b -- c) 'f def) module", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'bad ((dup) (a 1 -- b) 'f def) module", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'bad ((dup) (a b) 'f def) module", &.{"'kind 'domain"});
    try expectOk(&runtime, "'m ((dup 0 > (1 - countdown) (pop) if) ( n -- ) 'countdown def) module");
    try expectOk(&runtime, "20 m.countdown");
    const shallow_frames = runtime.last_max_frames;
    try expectOk(&runtime, "20000 m.countdown");
    try std.testing.expectEqual(shallow_frames, runtime.last_max_frames);
    try expectErrorContains(&runtime, "'lies ((dup +) ( a -- b c ) 'f def) module 1 lies.f", &.{ "'kind 'contract", "'word 'lies.f" });
    try expectErrorContains(&runtime, "'needs ((dup) ( a -- a a ) 'f def) module needs.f", &.{ "'kind 'contract", "seeded 0" });
    try expectErrorContains(&runtime, "'throws ((missing) ( -- n ) 'f def) module throws.f", &.{ "'kind 'undefined-word", "'word 'missing" });
    try expectOk(&runtime, "(dup +) 'session-double def 4 session-double");
    try std.testing.expectEqual(@as(i64, 8), runtime.stack.items[runtime.stack.items.len - 1].int);
}

test "module: use shadow notices are exact and non-blocking" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        null,
    );
    defer runtime.deinit();
    try expectOk(&runtime, "1 'mean let 2 'count let 'stats (3 'mean let 4 'count let 5 'other let) module 'stats use mean count");
    try std.testing.expectEqualStrings(
        "session `count` shadows `stats.count`\n" ++
            "session `mean` shadows `stats.mean`\n",
        diagnostics.written(),
    );
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[1].int);
    const notice_len = diagnostics.written().len;
    try expectOk(&runtime, "('stats use other pop) attempt pop 'consumer ('stats use (other) ( -- n ) 'get def) module consumer.get pop");
    try std.testing.expectEqual(notice_len, diagnostics.written().len);

    var output_buffer: [64]u8 = undefined;
    var fixed_output = std.Io.Writer.fixed(&output_buffer);
    var no_diagnostic_space: [0]u8 = .{};
    var broken_diagnostics = std.Io.Writer.fixed(&no_diagnostic_space);
    var broken = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &fixed_output,
        &broken_diagnostics,
        null,
    );
    defer broken.deinit();
    try expectErrorContains(&broken, "1 'x let 'm (2 'x let 3 'y let) module 'm use", &.{"'kind 'io"});
    try expectErrorContains(&broken, "y", &.{"'kind 'undefined-word"});
}

test "reflection: which and see expose home shadow and effect" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        null,
    );
    defer runtime.deinit();
    try expectOk(&runtime, "'m (40 's letp (s 2 +) ( -- n ) 'f def) module 'm use " ++
        "'m.f see 9 'f let 'f which words");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(s 2 +) (-- n) 'm.f def") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "f -> f let public; shadows m.f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " s ") == null);
    try expectErrorContains(&runtime, "'m.f body call", &.{ "'kind 'undefined-word", "'word 's" });
}

test "reflection: body extraction loses home context" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (40 's letp (s 2 +) ( -- n ) 'f def) module");
    try expectErrorContains(&runtime, "'m.f body call", &.{ "'kind 'undefined-word", "'word 's" });
}

test "reflection: words is sorted unique and private-safe" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        null,
    );
    defer runtime.deinit();
    try expectOk(&runtime, "'m (1 'hidden letp 2 'zebra let 3 'alpha let) module 'm use 4 'zebra let words");
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha").? < std.mem.indexOf(u8, rendered, "zebra").?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "zebra"));
}

fn reflectionAllocationProbe(allocator: std.mem.Allocator) !void {
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    var runtime = try session.Session.initWithHost(
        allocator,
        &.{},
        std.testing.io,
        &output,
        &diagnostics,
        null,
    );
    defer runtime.deinit();
    const outcome = try runtime.runUnit(
        "reflection-allocation.ecl",
        "'m ((1) ( -- n ) 'f def) module 'm use 'm.f body pop words 'f which 'm.f see",
    );
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "reflection failures and allocation cleanup are total" {
    var no_output = try session.Session.init(std.testing.allocator, &.{});
    defer no_output.deinit();
    try expectErrorContains(&no_output, "words", &.{"'kind 'io"});
    try expectErrorContains(&no_output, "'dup body", &.{"'kind 'type"});
    try expectErrorContains(&no_output, "'missing which", &.{"'kind 'undefined-word"});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, reflectionAllocationProbe, .{});
}

fn nativeAnswer(evaluator: *machine.Machine) machine.MachineError!void {
    try evaluator.pushOwned(.{ .int = 42 });
}

fn nativeAnswerReloaded(evaluator: *machine.Machine) machine.MachineError!void {
    try evaluator.pushOwned(.{ .int = 43 });
}

test "registry: native modules share ordinary generations and effects" {
    const allocator = std.testing.allocator;
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        null,
    );
    defer runtime.deinit();
    const separator = try intern.intern("--");
    const output_name = try intern.intern("n");
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .word = separator },
        .{ .word = output_name },
    });
    defer heap.releaseValue(allocator, effect_value);
    const module_name = try intern.intern("native");
    const answer_name = try intern.intern("answer");
    try std.testing.expectEqual(@as(u64, 1), try runtime.registerNativeModule(module_name, &.{.{
        .name = answer_name,
        .binding = .{ .primitive = nativeAnswer },
        .effect = .{ .quotation = effect_value.list, .inputs = 0, .outputs = 1 },
    }}));
    try expectOk(&runtime, "native.answer 'native use answer 'n 'native alias n.answer 'native.answer which 'native.answer see");
    for (runtime.stack.items) |item| try std.testing.expectEqual(@as(i64, 42), item.int);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "native.answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- n)") != null);
    try std.testing.expectEqual(@as(u64, 2), try runtime.registerNativeModule(module_name, &.{.{
        .name = answer_name,
        .binding = .{ .primitive = nativeAnswerReloaded },
        .effect = .{ .quotation = effect_value.list, .inputs = 0, .outputs = 1 },
    }}));
    try expectOk(&runtime, "native.answer answer n.answer");
    for (runtime.stack.items[3..]) |item| try std.testing.expectEqual(@as(i64, 43), item.int);
    try std.testing.expectError(error.InvalidDefinition, runtime.registerNativeModule(
        try intern.intern("invalid.module"),
        &.{.{
            .name = answer_name,
            .binding = .{ .primitive = nativeAnswer },
            .effect = .{ .quotation = effect_value.list, .inputs = 0, .outputs = 1 },
        }},
    ));
    try std.testing.expectError(error.InvalidDefinition, runtime.registerNativeModule(
        try intern.intern("invalid-effect"),
        &.{.{
            .name = answer_name,
            .binding = .{ .primitive = nativeAnswer },
            .effect = .{ .quotation = effect_value.list, .inputs = 1, .outputs = 0 },
        }},
    ));
}

const EnvThreadContext = struct {
    environment: *env.Environment,
    failed: *std.atomic.Value(bool),
};

fn envWorker(context: EnvThreadContext) void {
    for (0..100) |index| {
        _ = context.environment.bind(7, .{ .value = .{ .int = @intCast(index) } }) catch {
            context.failed.store(true, .release);
            return;
        };
        var lease = context.environment.resolveDirect(7) orelse {
            context.failed.store(true, .release);
            return;
        };
        lease.deinit(std.testing.allocator);
    }
}

// Lease safety rests on superseded shapes/directories being retained until
// teardown (no hazard pointers on the read path). Bounded reclamation is a
// recorded v1 obligation: ARCHITECTURE.md §Environments, workstream M7/M10.
test "env: concurrent cell publication is lease-safe and TSan-clean" {
    var environment = env.Environment.init(std.testing.allocator);
    defer environment.deinit();
    var failed = std.atomic.Value(bool).init(false);
    const context = EnvThreadContext{ .environment = &environment, .failed = &failed };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, envWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), environment.generation());
}

test "env: a replaced interior remains valid only through its binding lease" {
    var environment = env.Environment.init(std.testing.allocator);
    defer environment.deinit();
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(std.testing.allocator, body);
    _ = try environment.bindDetailed(1, .{
        .binding = .{ .word = body.list },
        .doc = body.list,
        .compiled = body.list,
    });
    var old = environment.resolveDirect(1).?;
    _ = try environment.bind(1, .{ .value = .{ .int = 9 } });
    try std.testing.expectEqual(@as(u32, 4), body.list.rc.load(.acquire));
    old.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), body.list.rc.load(.acquire));
}

const RegistryThreadContext = struct {
    registry: *modules.Registry,
    failed: *std.atomic.Value(bool),
};

fn commitCandidate(context: RegistryThreadContext, name: u32) bool {
    const candidate = context.registry.createCandidate(name) catch return false;
    _ = context.registry.commit(candidate) catch {
        candidate.destroy();
        return false;
    };
    return true;
}

fn registryWorker(context: RegistryThreadContext, worker_id: u32) void {
    for (0..50) |_| {
        if (!commitCandidate(context, 9) or !commitCandidate(context, 10 + worker_id)) {
            context.failed.store(true, .release);
            return;
        }
        var lease = context.registry.acquire(9) orelse {
            context.failed.store(true, .release);
            return;
        };
        if (lease.generation.generation == 0) context.failed.store(true, .release);
        lease.deinit();
    }
}

test "registry: concurrent commits are linearized without lost names" {
    var registry = modules.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var failed = std.atomic.Value(bool).init(false);
    const context = RegistryThreadContext{ .registry = &registry, .failed = &failed };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, registryWorker, .{ context, @as(u32, @intCast(index)) });
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    var lease = registry.acquire(9).?;
    defer lease.deinit();
    try std.testing.expectEqual(@as(u64, 200), lease.generation.generation);
    for (0..4) |index| {
        var disjoint = registry.acquire(10 + @as(u32, @intCast(index))).?;
        defer disjoint.deinit();
        try std.testing.expectEqual(@as(u64, 50), disjoint.generation.generation);
    }
}

test "registry: old generation leases survive reload and reclaim after release" {
    var registry = modules.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(std.testing.allocator, body);
    const first = try registry.createCandidate(1);
    _ = try first.environment.bind(2, .{ .word = body.list });
    _ = try registry.commit(first);
    var old = registry.acquire(1).?;
    const second = try registry.createCandidate(1);
    _ = try registry.commit(second);
    try std.testing.expectEqual(@as(u64, 1), old.generation.generation);
    try std.testing.expectEqual(@as(u32, 2), body.list.rc.load(.acquire));
    old.deinit();
    try std.testing.expectEqual(@as(u32, 1), body.list.rc.load(.acquire));
}

test "loader: load is one unit and preserves file provenance" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        null,
    );
    defer runtime.deinit();
    try expectOk(&runtime, "10");
    try expectErrorContains(&runtime, "\"test/acceptance/load-rollback.ecl\" load", &.{ "'kind 'undefined-word", "'word 'missing" });
    try std.testing.expectEqual(@as(usize, 1), runtime.stack.items.len);
    try std.testing.expectEqual(@as(i64, 10), runtime.stack.items[0].int);
    try std.testing.expectEqualStrings("side", output.written());
    try expectOk(&runtime, "persist");
    try std.testing.expectEqual(@as(i64, 7), runtime.stack.items[1].int);
    try expectOk(&runtime, "loaded.answer");
    try std.testing.expectEqual(@as(i64, 8), runtime.stack.items[2].int);
    try expectOk(&runtime, "(\"test/acceptance/load-stack.ecl\" load) attempt pop");
    try expectOk(&runtime, "\"test/acceptance/load-provenance.ecl\" load");
    try expectErrorContains(&runtime, "loaded-boom", &.{ "'word 'missing", "'source \"test/acceptance/load-provenance.ecl\"" });
    try expectOk(&runtime, "\"test/acceptance/load-stack.ecl\" load");
    try std.testing.expectEqual(@as(i64, 42), runtime.stack.items[3].int);
    try std.testing.expectEqualStrings("side", output.written());
}

test "loader: ECL_PATH loads first candidate and retries use" {
    const search = try std.fmt.allocPrint(
        std.testing.allocator,
        "test/acceptance/path-first{c}test/acceptance/path-second",
        .{std.fs.path.delimiter},
    );
    defer std.testing.allocator.free(search);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        search,
    );
    defer runtime.deinit();
    try expectOk(&runtime, "('attempted use answer) attempt pop attempted.answer");
    try std.testing.expectEqual(@as(i64, 3), runtime.stack.items[0].int);
    try expectErrorContains(&runtime, "answer", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'stats use answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[1].int);

    var no_path = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        "",
    );
    defer no_path.deinit();
    try expectErrorContains(&no_path, "'stats use", &.{ "'kind 'undefined-word", "'name 'stats" });
}

fn loaderAllocationProbe(allocator: std.mem.Allocator) !void {
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [64]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    var runtime = try session.Session.initWithHost(
        allocator,
        &.{},
        std.testing.io,
        &output,
        &diagnostics,
        "test/acceptance/modules",
    );
    defer runtime.deinit();
    const outcome = try runtime.runUnit("loader-allocation.ecl", "'stats use answer");
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "loader: failures cycles and OOM are total" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        std.testing.io,
        &output.writer,
        &diagnostics.writer,
        "test/acceptance/modules",
    );
    defer runtime.deinit();
    try expectErrorContains(&runtime, "'missing-module use", &.{ "'kind 'undefined-word", "'name 'missing-module" });
    try expectErrorContains(&runtime, "'cycle use", &.{ "'kind 'domain", "recursive auto-load" });
    try expectErrorContains(&runtime, "'orphan use", &.{ "'kind 'undefined-word", "'path \"test/acceptance/modules/orphan.ecl\"" });
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loaderAllocationProbe, .{});
}

fn moduleAllocationProbe(allocator: std.mem.Allocator) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const outcome = try runtime.runUnit(
        "allocation-module.ecl",
        "'m (1 'x letp (x) ( -- n ) 'get def) module 'm use get " ++
            "'short 'm alias short.get " ++
            "'m (2 'x letp (x) ( -- n ) 'get def) module get " ++
            "('bad ((dup) 'f def) module) attempt pop",
    );
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "module execution propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, moduleAllocationProbe, .{});
}

fn environmentAllocationProbe(allocator: std.mem.Allocator) !void {
    var environment = env.Environment.init(allocator);
    defer environment.deinit();
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, body);
    _ = try environment.bind(1, .{ .word = body.list });
    var lease = environment.resolveDirect(1).?;
    defer lease.deinit(allocator);
    _ = try environment.bind(1, .{ .value = .{ .int = 2 } });
    _ = try environment.bind(2, .{ .value = .{ .int = 3 } });
    try environment.moveUseToTop(8);
    try environment.moveUseToTop(9);
    const names = try environment.namesOwned(allocator);
    allocator.free(names);
}

fn registryAllocationProbe(allocator: std.mem.Allocator) !void {
    var registry = modules.Registry.init(allocator);
    defer registry.deinit();
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .word = try intern.intern("--") },
        .{ .word = try intern.intern("n") },
    });
    defer heap.releaseValue(allocator, effect_value);
    const effect: env.Effect = .{ .quotation = effect_value.list, .inputs = 0, .outputs = 1 };
    const first = try registry.createCandidate(1);
    var first_owned = true;
    errdefer if (first_owned) first.destroy();
    _ = try first.environment.bindDetailed(2, .{ .binding = .{ .primitive = nativeAnswer }, .home = 1, .effect = effect });
    _ = try registry.commit(first);
    first_owned = false;
    try registry.alias(3, 1);
    var lease = registry.acquire(3).?;
    defer lease.deinit();
    const second = try registry.createCandidate(1);
    var second_owned = true;
    errdefer if (second_owned) second.destroy();
    _ = try second.environment.bindDetailed(2, .{ .binding = .{ .primitive = nativeAnswer }, .home = 1, .effect = effect });
    _ = try registry.commit(second);
    second_owned = false;
    _ = try registry.registerNative(4, &.{.{
        .name = 2,
        .binding = .{ .primitive = nativeAnswer },
        .effect = effect,
    }});
}

test "environment and registry APIs propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, environmentAllocationProbe, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registryAllocationProbe, .{});
}
