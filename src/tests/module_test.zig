const std = @import("std");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const modules = @import("../modules.zig");
const poll = @import("../poll.zig");
const printer = @import("../print.zig");
const session = @import("../session.zig");

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

fn cancelLoading(_: *anyopaque) poll.Error!void {
    return error.Ecl;
}

fn finishLoadingWithCleanup(loading: *modules.LoadingLease, work: poll.WorkContext) poll.Error!void {
    defer loading.deinit();
    try loading.finish(work);
}

test "registry: cancelled loading removal retains cleanup ownership" {
    var registry = modules.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const name = try intern.intern("cancelled-loading");
    var loading = (try registry.beginLoading(name, .unlimited())).?;
    var context: u8 = 0;
    try std.testing.expectError(error.Ecl, finishLoadingWithCleanup(&loading, .init(.{
        .context = &context,
        .poll_fn = cancelLoading,
    })));
    var retry = (try registry.beginLoading(name, .unlimited())).?;
    defer retry.deinit();
}

test "env: new names and use edits bump shape and deep lookup is ordered" {
    var environment = env.Environment.init(std.testing.allocator);
    defer environment.deinit();
    const home = try intern.trustedNamespace("environment-test-home");
    var scope = env.Scope.moduleRoot(std.testing.allocator, &environment, home);
    defer scope.deinit();
    const first = try intern.trustedNamespace("first-env-name");
    const second = try intern.trustedNamespace("second-env-name");
    _ = try scope.publishModule(first, .{ .value = .{ .item = .{ .int = 1 }, .visibility = .public } }, .unlimited());
    try std.testing.expectEqual(@as(u64, 1), environment.generation());
    _ = try scope.publishModule(second, .{ .value = .{ .item = .{ .int = 2 }, .visibility = .public } }, .unlimited());
    try std.testing.expectEqual(@as(u64, 2), environment.generation());
    try scope.moveUseToTop(8, .unlimited());
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try scope.moveUseToTop(8, .unlimited());
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try scope.moveUseToTop(9, .unlimited());
    try scope.moveUseToTop(8, .unlimited());
    try std.testing.expectEqualSlices(u32, &.{ 9, 8 }, environment.useOrder());
    const names = try environment.namesOwned(std.testing.allocator, .unlimited());
    defer std.testing.allocator.free(names);
    std.mem.sort(u32, names, {}, std.sort.asc(u32));
    var expected = [_]u32{ intern.namespaceId(first), intern.namespaceId(second) };
    std.mem.sort(u32, &expected, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &expected, names);
    scope.freezeModule();
    try std.testing.expectError(
        error.Frozen,
        scope.publishModule(first, .{ .value = .{ .item = .{ .int = 3 }, .visibility = .public } }, .unlimited()),
    );
}

test "binding: set installs and replaces values while let is absent" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "1 'x set x 2 'x set x");
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[1].int);
    try expectErrorContains(&runtime, "3 'y let", &.{ "'kind 'undefined-word", "'word 'let" });
    try expectErrorContains(&runtime, "3 'bad def", &.{ "'kind 'type", "use set for values" });
}

test "scope: isolated attempt and child use do not leak" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectErrorContains(&runtime, "(1 'k set) attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "((1 'k set missing) attempt pop) attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectOk(&runtime, "'m (7 'x set) module");
    try expectErrorContains(&runtime, "('m use x) attempt pop x", &.{ "'kind 'undefined-word", "'word 'x" });
}

test "module: privacy module-body contract top-level private and qualified trace" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (40 's setp (s 2 +) ( -- n ) 'f def) module m.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stack.items[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "'private-word ((41) ( -- n ) 'g defp (g 1 +) ( -- n ) 'f def) module private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stack.items[1].int);
    try expectErrorContains(&runtime, "private-word.g", &.{ "'kind 'undefined-word", "'word 'private-word.g" });
    try expectErrorContains(&runtime, "1 'x setp", &.{ "'kind 'domain", "defp/setp" });
    try expectErrorContains(&runtime, "'bad (1) module", &.{ "'kind 'contract", "observed 1" });
    try expectErrorContains(&runtime, "bad.x", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'temporary ((1 'hidden set) attempt pop) module");
    try expectErrorContains(&runtime, "temporary.hidden", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'trace-module ((missing) ( -- n ) 'boom def) module");
    try expectErrorContains(&runtime, "trace-module.boom", &.{ "'word 'missing", "'trace ['missing 'trace-module.boom]" });
    try expectOk(&runtime, "'recursive ((dup 0 > (1 - f 1 +) (pop missing) if) ( n -- n ) 'f def) module");
    try expectErrorContains(&runtime, "2 recursive.f", &.{"'trace ['missing 'recursive.f 'recursive.f 'recursive.f]"});
}

test "module: qualified use alias ordering idempotence and collisions" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'a (1 'x set) module 'b (2 'x set) module " ++
        "'a use 'b use x 'a use x 'short 'a alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[2].int);
    try expectErrorContains(&runtime, "'a 'b alias", &.{"'kind 'domain"});
    try expectOk(&runtime, "'short 'b alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[3].int);
    try expectErrorContains(&runtime, "'future 'a alias 'future (3 'x set) module", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'dotted.name 'a alias", &.{"'kind 'domain"});
}

test "module: hot reload commit failure and whole-body pinning" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (1 'x setp " ++
        "('m (2 'x setp (x) ( -- n ) 'get def) module x) ( -- n ) 'probe def " ++
        "(x) ( -- n ) 'get def) module m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stack.items[1].int);
    try expectErrorContains(&runtime, "'m (3 'x setp missing) module", &.{"'kind 'undefined-word"});
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
    try expectOk(&runtime, "1 'mean set 2 'count set 'stats (3 'mean set 4 'count set 5 'other set) module 'stats use mean count");
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
    try expectErrorContains(&broken, "1 'x set 'm (2 'x set 3 'y set) module 'm use", &.{"'kind 'io"});
    try expectErrorContains(&broken, "y", &.{"'kind 'undefined-word"});
}

test "module: use shadow notices stay within the cancellation bound" {
    const allocator = std.testing.allocator;
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 's');
    const long_name = try intern.internNamespace(name_bytes);
    const module_name = try intern.trustedNamespace("wide");
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
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
    try runtime.environment.define(long_name, .{ .value = .{ .int = 1 } });
    _ = try runtime.registerNativeModule(module_name, &.{.{ .value = .{
        .name = long_name,
        .item = .{ .int = 2 },
    } }});
    runtime.cancelled.store(true, .release);
    const failure = (try runtime.runUnit("shadow-poll.ecl", "'wide use")).err;
    defer heap.releaseValue(allocator, failure);
    const rendered = try printer.toOwnedString(allocator, failure);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unit cancelled") != null);
    try std.testing.expect(runtime.last_polls >= 1);
    try std.testing.expect(diagnostics.written().len < machine.kernel_poll_quantum);

    var name_runtime = try session.Session.init(allocator, &.{});
    defer name_runtime.deinit();
    try name_runtime.stack.append(allocator, .{ .symbol = intern.namespaceId(long_name) });
    try name_runtime.stack.append(allocator, try list.fromValuesGeneric(allocator, &.{}));
    name_runtime.cancelled.store(true, .release);
    try expectErrorContains(&name_runtime, "module", &.{"unit cancelled"});
    try std.testing.expect(name_runtime.last_polls >= 1);
    try std.testing.expect(name_runtime.registry.acquire(intern.namespaceId(long_name)) == null);
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
    try expectOk(&runtime, "'m (40 's setp (s 2 +) ( -- n ) 'f def) module 'm use " ++
        "'m.f see 9 'f set 'f which 'f see words");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(s 2 +) (-- n) 'm.f def") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "f -> f set public; shadows m.f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "9 'f set") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " s ") == null);
    try expectErrorContains(&runtime, "'m.f body call", &.{ "'kind 'undefined-word", "'word 's" });
}

test "reflection: body extraction loses home context" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (40 's setp (s 2 +) ( -- n ) 'f def) module");
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
    try expectOk(&runtime, "'m (1 'hidden setp 2 'zebra set 3 'alpha set) module 'm use 4 'zebra set words");
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha").? < std.mem.indexOf(u8, rendered, "zebra").?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "zebra"));
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
    try words_runtime.environment.define(first, .{ .value = .{ .int = 1 } });
    try words_runtime.environment.define(second, .{ .value = .{ .int = 2 } });
    words_runtime.cancelled.store(true, .release);
    const words_failure = (try words_runtime.runUnit("reflection-poll.ecl", "words")).err;
    defer heap.releaseValue(allocator, words_failure);
    const words_rendered = try printer.toOwnedString(allocator, words_failure);
    defer allocator.free(words_rendered);
    try std.testing.expect(std.mem.indexOf(u8, words_rendered, "unit cancelled") != null);
    try std.testing.expect(words_runtime.last_polls >= 1);

    var which_output = std.Io.Writer.Allocating.init(allocator);
    defer which_output.deinit();
    var which_runtime = try session.Session.initWithOutput(allocator, &.{}, &which_output.writer);
    defer which_runtime.deinit();
    try which_runtime.environment.define(first, .{ .value = .{ .int = 1 } });
    try which_runtime.stack.append(allocator, .{ .symbol = intern.namespaceId(first) });
    which_runtime.cancelled.store(true, .release);
    const which_failure = (try which_runtime.runUnit("reflection-poll.ecl", "which")).err;
    defer heap.releaseValue(allocator, which_failure);
    const which_rendered = try printer.toOwnedString(allocator, which_failure);
    defer allocator.free(which_rendered);
    try std.testing.expect(std.mem.indexOf(u8, which_rendered, "unit cancelled") != null);
    try std.testing.expect(which_runtime.last_polls >= 1);
    try std.testing.expectEqual(@as(usize, 0), which_output.written().len);

    const module_name = try intern.trustedNamespace("poll-module");
    const qualified_bytes = try allocator.alloc(u8, "poll-module.".len + first_bytes.len);
    defer allocator.free(qualified_bytes);
    @memcpy(qualified_bytes[0.."poll-module.".len], "poll-module.");
    @memcpy(qualified_bytes["poll-module.".len..], first_bytes);
    const qualified = try intern.intern(qualified_bytes);
    var qualified_output = std.Io.Writer.Allocating.init(allocator);
    defer qualified_output.deinit();
    var qualified_runtime = try session.Session.initWithOutput(allocator, &.{}, &qualified_output.writer);
    defer qualified_runtime.deinit();
    _ = try qualified_runtime.registerNativeModule(module_name, &.{.{ .value = .{
        .name = first,
        .item = .{ .int = 1 },
    } }});
    try qualified_runtime.stack.append(allocator, .{ .symbol = qualified });
    qualified_runtime.cancelled.store(true, .release);
    const qualified_failure = (try qualified_runtime.runUnit("reflection-poll.ecl", "which")).err;
    defer heap.releaseValue(allocator, qualified_failure);
    const qualified_rendered = try printer.toOwnedString(allocator, qualified_failure);
    defer allocator.free(qualified_rendered);
    try std.testing.expect(std.mem.indexOf(u8, qualified_rendered, "unit cancelled") != null);
    try std.testing.expect(qualified_runtime.last_polls >= 1);
    try std.testing.expectEqual(@as(usize, 0), qualified_output.written().len);
}

test "reflection failures are total" {
    var no_output = try session.Session.init(std.testing.allocator, &.{});
    defer no_output.deinit();
    try expectErrorContains(&no_output, "words", &.{"'kind 'io"});
    try expectErrorContains(&no_output, "'dup body", &.{"'kind 'type"});
    try expectErrorContains(&no_output, "'missing which", &.{"'kind 'undefined-word"});
}

fn nativeAnswer(evaluator: *machine.Machine) env.PrimitiveResult {
    try evaluator.pushOwned(.{ .int = 42 });
    return .ok;
}

fn nativeAnswerReloaded(evaluator: *machine.Machine) env.PrimitiveResult {
    try evaluator.pushOwned(.{ .int = 43 });
    return .ok;
}

fn nativeFailure(_: *machine.Machine) env.PrimitiveResult {
    return .{ .failure = machine.EclErr.init(.domain, "native failure payload") };
}

test "public native failures carry their payload atomically" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const separator = try intern.intern("--");
    const effect_value = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .word = separator }});
    defer heap.releaseValue(std.testing.allocator, effect_value);
    const effect = (try env.ValidatedEffect.parse(effect_value.list, separator, .unlimited())).?;
    _ = try runtime.registerNativeModule(
        try intern.trustedNamespace("failing-native"),
        &.{.{ .primitive = .{
            .name = try intern.trustedNamespace("fail"),
            .callback = nativeFailure,
            .effect = effect,
        } }},
    );
    try expectErrorContains(&runtime, "failing-native.fail", &.{
        "'kind 'domain",
        "native failure payload",
        "'word 'failing-native.fail",
    });
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
    const effect = (try env.ValidatedEffect.parse(effect_value.list, separator, .unlimited())).?;
    const module_name = try intern.trustedNamespace("native");
    const answer_name = try intern.trustedNamespace("answer");
    try std.testing.expectEqual(@as(u64, 1), try runtime.registerNativeModule(module_name, &.{.{
        .primitive = .{ .name = answer_name, .callback = nativeAnswer, .effect = effect },
    }}));
    try expectOk(&runtime, "native.answer 'native use answer 'n 'native alias n.answer 'native.answer which 'native.answer see");
    for (runtime.stack.items) |item| try std.testing.expectEqual(@as(i64, 42), item.int);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "native.answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- n)") != null);
    try std.testing.expectEqual(@as(u64, 2), try runtime.registerNativeModule(module_name, &.{.{
        .primitive = .{ .name = answer_name, .callback = nativeAnswerReloaded, .effect = effect },
    }}));
    try expectOk(&runtime, "native.answer answer n.answer");
    for (runtime.stack.items[3..]) |item| try std.testing.expectEqual(@as(i64, 43), item.int);
    try std.testing.expectError(
        error.InvalidName,
        intern.internNamespace("invalid.module"),
    );
    const invalid_effect = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, invalid_effect);
    try std.testing.expect((try env.ValidatedEffect.parse(
        invalid_effect.list,
        separator,
        .unlimited(),
    )) == null);
}

const EnvThreadContext = struct {
    scope: *env.Scope,
    environment: *env.Environment,
    failed: *std.atomic.Value(bool),
    name: intern.NamespaceName,
};

fn envWorker(context: EnvThreadContext) void {
    for (0..100) |index| {
        _ = context.scope.publishTop(
            context.name,
            .{ .value = .{ .int = @intCast(index) } },
            .unlimited(),
        ) catch {
            context.failed.store(true, .release);
            return;
        };
        var lease = (context.environment.resolveDirect(
            intern.namespaceId(context.name),
            .unlimited(),
        ) catch unreachable) orelse {
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
    var container = env.Env.init(std.testing.allocator);
    defer container.deinit();
    var scope = container.sessionRoot(std.testing.allocator);
    defer scope.deinit();
    var failed = std.atomic.Value(bool).init(false);
    const context = EnvThreadContext{
        .scope = &scope,
        .environment = &container.session,
        .failed = &failed,
        .name = try intern.trustedNamespace("concurrent-env-name"),
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, envWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), container.session.generation());
}

test "env: a replaced interior remains valid only through its binding lease" {
    var environment = env.Env.init(std.testing.allocator);
    defer environment.deinit();
    var scope = environment.sessionRoot(std.testing.allocator);
    defer scope.deinit();
    const separator = try intern.intern("--");
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .word = separator }});
    defer heap.releaseValue(std.testing.allocator, body);
    const document = try list.fromCodepoints(std.testing.allocator, &.{ 'd', 'o', 'c' });
    defer heap.releaseValue(std.testing.allocator, document);
    const effect = (try env.ValidatedEffect.parse(body.list, separator, .unlimited())).?;
    const name = try intern.trustedNamespace("leased-metadata");
    _ = try scope.publishTop(name, .{ .word = .{
        .body = env.quotation(body.list).?,
        .effect = effect,
        .doc = env.documentation(document.list).?,
    } }, .unlimited());
    var old = (try environment.session.resolveDirect(intern.namespaceId(name), .unlimited())).?;
    _ = try scope.publishTop(name, .{ .value = .{ .int = 9 } }, .unlimited());
    try std.testing.expectEqual(@as(u32, 3), heap.refCount(body.list));
    old.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), heap.refCount(body.list));
}

const RegistryThreadContext = struct {
    registry: *modules.Registry,
    failed: *std.atomic.Value(bool),
    shared: intern.NamespaceName,
    disjoint: [4]intern.NamespaceName,
};

fn commitCandidate(context: RegistryThreadContext, name: intern.NamespaceName) bool {
    var candidate = context.registry.createCandidate(name) catch return false;
    defer candidate.deinit();
    _ = context.registry.commit(&candidate, .unlimited()) catch return false;
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
        var lease = context.registry.acquire(intern.namespaceId(context.shared)) orelse {
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
    const context = RegistryThreadContext{
        .registry = &registry,
        .failed = &failed,
        .shared = try intern.trustedNamespace("shared-module"),
        .disjoint = .{
            try intern.trustedNamespace("worker-module-0"),
            try intern.trustedNamespace("worker-module-1"),
            try intern.trustedNamespace("worker-module-2"),
            try intern.trustedNamespace("worker-module-3"),
        },
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, registryWorker, .{ context, @as(u32, @intCast(index)) });
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    var lease = registry.acquire(intern.namespaceId(context.shared)).?;
    defer lease.deinit();
    try std.testing.expectEqual(@as(u64, 200), lease.generation.generation);
    for (0..4) |index| {
        var disjoint = registry.acquire(intern.namespaceId(context.disjoint[index])).?;
        defer disjoint.deinit();
        try std.testing.expectEqual(@as(u64, 50), disjoint.generation.generation);
    }
}

test "registry: old generation leases survive reload and reclaim after release" {
    var registry = modules.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(std.testing.allocator, body);
    const module_name = try intern.trustedNamespace("leased-generation");
    const value_name = try intern.trustedNamespace("leased-value");
    var first = try registry.createCandidate(module_name);
    defer first.deinit();
    _ = try first.borrow().scope.publishModule(value_name, .{ .value = .{
        .item = body,
        .visibility = .public,
    } }, .unlimited());
    _ = try registry.commit(&first, .unlimited());
    var old = registry.acquire(intern.namespaceId(module_name)).?;
    var second = try registry.createCandidate(module_name);
    defer second.deinit();
    _ = try registry.commit(&second, .unlimited());
    try std.testing.expectEqual(@as(u64, 1), old.generation.generation);
    try std.testing.expectEqual(@as(u32, 2), heap.refCount(body.list));
    old.deinit();
    try std.testing.expectEqual(@as(u32, 1), heap.refCount(body.list));
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

test "loader: failures and cycles are total" {
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
}

fn environmentAllocationProbe(allocator: std.mem.Allocator) !void {
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    var scope = environment.sessionRoot(allocator);
    defer scope.deinit();
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, body);
    const first = try intern.trustedNamespace("allocation-first");
    const second = try intern.trustedNamespace("allocation-second");
    const after_uses = try intern.trustedNamespace("allocation-after-uses");
    _ = try scope.publishTop(first, .{ .word = .{
        .body = env.quotation(body.list).?,
    } }, .unlimited());
    var lease = (try environment.session.resolveDirect(intern.namespaceId(first), .unlimited())).?;
    defer lease.deinit(allocator);
    _ = try scope.publishTop(first, .{ .value = .{ .int = 2 } }, .unlimited());
    _ = try scope.publishTop(second, .{ .value = .{ .int = 3 } }, .unlimited());
    try scope.moveUseToTop(8, .unlimited());
    try scope.moveUseToTop(9, .unlimited());
    _ = try scope.publishTop(after_uses, .{ .value = .{ .int = 4 } }, .unlimited());
    const names = try environment.session.namesOwned(allocator, .unlimited());
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
    const separator = try intern.intern("--");
    const effect = (try env.ValidatedEffect.parse(effect_value.list, separator, .unlimited())).?;
    const first_name = try intern.trustedNamespace("allocation-module");
    const alias_name = try intern.trustedNamespace("allocation-alias");
    const second_name = try intern.trustedNamespace("allocation-native");
    const word_name = try intern.trustedNamespace("answer");
    var first = try registry.createCandidate(first_name);
    defer first.deinit();
    _ = try first.borrow().scope.publishModule(word_name, .{ .primitive = .{
        .callback = nativeAnswer,
        .visibility = .public,
        .effect = effect,
    } }, .unlimited());
    _ = try registry.commit(&first, .unlimited());
    try registry.alias(alias_name, first_name, .unlimited());
    var lease = registry.acquire(intern.namespaceId(alias_name)).?;
    defer lease.deinit();
    var second = try registry.createCandidate(first_name);
    defer second.deinit();
    _ = try second.borrow().scope.publishModule(word_name, .{ .primitive = .{
        .callback = nativeAnswer,
        .visibility = .public,
        .effect = effect,
    } }, .unlimited());
    _ = try registry.commit(&second, .unlimited());
    _ = try registry.registerNative(second_name, &.{.{ .primitive = .{
        .name = word_name,
        .callback = nativeAnswer,
        .effect = effect,
    } }}, .unlimited());
}

test "environment and registry APIs propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, environmentAllocationProbe, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registryAllocationProbe, .{});
}
