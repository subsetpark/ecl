const std = @import("std");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
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

fn commitEmptyModule(registry: *modules.Registry, name: intern.NamespaceName) !void {
    var candidate = try registry.createCandidate(name);
    defer candidate.deinit();
    _ = try registry.commit(&candidate);
}

test "env: new names and use edits bump shape and deep lookup is ordered" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = env.Environment.init(std.testing.allocator, releases);
    defer env.testing.deinitEnvironment(&environment);
    const home = try intern.trustedNamespace("environment-test-home");
    var scope = env.Scope.moduleRoot(std.testing.allocator, &environment, home);
    defer env.testing.deinitScope(&scope, releases);
    const first = try intern.trustedNamespace("first-env-name");
    const second = try intern.trustedNamespace("second-env-name");
    _ = try scope.publishModule(first, .{ .value = .{ .item = .{ .int = 1 }, .visibility = .public } });
    try std.testing.expectEqual(@as(u64, 1), environment.generation());
    _ = try scope.publishModule(second, .{ .value = .{ .item = .{ .int = 2 }, .visibility = .public } });
    try std.testing.expectEqual(@as(u64, 2), environment.generation());
    try scope.moveUseToTop(8);
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try scope.moveUseToTop(8);
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try scope.moveUseToTop(9);
    try scope.moveUseToTop(8);
    var shape = environment.acquireShape();
    defer shape.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 9, 8 }, shape.useOrder());
    const names = try environment.namesOwned(std.testing.allocator);
    defer std.testing.allocator.free(names);
    std.mem.sort(u32, names, {}, std.sort.asc(u32));
    var expected = [_]u32{ intern.namespaceId(first), intern.namespaceId(second) };
    std.mem.sort(u32, &expected, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &expected, names);
    scope.freezeModule();
    try std.testing.expectError(
        error.Frozen,
        scope.publishModule(first, .{ .value = .{ .item = .{ .int = 3 }, .visibility = .public } }),
    );
}

test "binding: set installs and replaces values while let is absent" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "1 'x set x 2 'x set x");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
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
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "'private-word ((41) ( -- n ) 'g defp (g 1 +) ( -- n ) 'f def) module private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
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
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "'a 'b alias", &.{"'kind 'domain"});
    try expectOk(&runtime, "'short 'b alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[3].int);
    try expectErrorContains(&runtime, "'future 'a alias 'future (3 'x set) module", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'dotted.name 'a alias", &.{"'kind 'domain"});
}

test "module: provisional tasks keep rollback generations alive until quiescence" {
    var runtime = try session.Session.initWithConfig(
        std.testing.allocator,
        &.{},
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "('bad (((1) () while) spawn pop missing) module) attempt pop");
}

test "module: hot reload commit failure and whole-body pinning" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "'m (1 'x setp " ++
        "('m (2 'x setp (x) ( -- n ) 'get def) module x) ( -- n ) 'probe def " ++
        "(x) ( -- n ) 'get def) module m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "'m (3 'x setp missing) module", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "m.get");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "'kept ((9) ( -- n ) 'get def) module missing", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "kept.get");
    try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[3].int);
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
    const shallow_frames = runtime.lastMaxFrames();
    try expectOk(&runtime, "20000 m.countdown");
    try std.testing.expectEqual(shallow_frames, runtime.lastMaxFrames());
    try expectErrorContains(&runtime, "'lies ((dup +) ( a -- b c ) 'f def) module 1 lies.f", &.{ "'kind 'contract", "'word 'lies.f" });
    try expectErrorContains(&runtime, "'needs ((dup) ( a -- a a ) 'f def) module needs.f", &.{ "'kind 'contract", "seeded 0" });
    try expectErrorContains(&runtime, "'throws ((missing) ( -- n ) 'f def) module throws.f", &.{ "'kind 'undefined-word", "'word 'missing" });
    try expectOk(&runtime, "(dup +) 'session-double def 4 session-double");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[runtime.stackItems().len - 1].int);
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
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
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
    try runtime.define(long_name, .{ .value = .{ .int = 1 } });
    _ = try runtime.registerNativeModule(module_name, &.{.{ .value = .{
        .name = long_name,
        .item = .{ .int = 2 },
    } }});
    runtime.requestCancellation();
    const failure = (try runtime.runUnit("shadow-poll.ecl", "'wide use")).err;
    defer heap.testing.releaseValue(allocator, failure);
    const rendered = try printer.toOwnedString(allocator, failure);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unit cancelled") != null);
    try std.testing.expect(runtime.lastPolls() >= 1);
    try std.testing.expect(diagnostics.written().len < machine.kernel_poll_quantum);

    var name_runtime = try session.Session.init(allocator, &.{});
    defer name_runtime.deinit();
    try name_runtime.pushOwned(.{ .symbol = intern.namespaceId(long_name) });
    try name_runtime.pushOwned(try list.fromValuesGeneric(allocator, &.{}));
    name_runtime.requestCancellation();
    try expectErrorContains(&name_runtime, "module", &.{"unit cancelled"});
    try std.testing.expect(name_runtime.lastPolls() >= 1);
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

test "session completion: core names are available before the first unit" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    var candidates = try runtime.completionCandidates("sq");
    defer candidates.deinit();
    try expectSortedUnique(candidates.items());
    try std.testing.expectEqual(@as(usize, 1), candidates.items().len);
    try std.testing.expectEqualStrings("sqrt", candidates.items()[0]);
}

test "session completion: live and registered names are sorted unique" {
    const missing_prefix = "completion-prefix-that-must-not-be-interned-47f19";
    try expectInternMissing(missing_prefix);
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    try expectOk(
        &runtime,
        "'completion-module (1 'hidden setp 2 'public set) module " ++
            "'completion-module use 'cm 'completion-module alias " ++
            "3 'repl-live set",
    );
    var all = try runtime.completionCandidates("");
    defer all.deinit();
    try expectSortedUnique(all.items());
    try std.testing.expect(containsCandidate(all.items(), "repl-live"));
    try std.testing.expect(containsCandidate(all.items(), "sqrt"));
    try std.testing.expect(containsCandidate(all.items(), "public"));
    try std.testing.expect(containsCandidate(all.items(), "completion-module"));
    try std.testing.expect(containsCandidate(all.items(), "cm"));
    try std.testing.expect(!containsCandidate(all.items(), "hidden"));

    var missing = try runtime.completionCandidates(missing_prefix);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.items().len);
    try expectInternMissing(missing_prefix);

    var surviving = try runtime.completionCandidates("repl-live");
    runtime.deinit();
    defer surviving.deinit();
    try std.testing.expectEqualStrings("repl-live", surviving.items()[0]);
}

test "session completion: dotted aliases expose only public exports" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(
        &runtime,
        "'completion-module (1 'old-public set 2 'private-name setp) module " ++
            "'cm 'completion-module alias " ++
            "'completion-module (3 'new-public set 4 'new-private setp) module",
    );
    var canonical = try runtime.completionCandidates("completion-module.");
    defer canonical.deinit();
    try expectSortedUnique(canonical.items());
    try std.testing.expectEqual(@as(usize, 1), canonical.items().len);
    try std.testing.expectEqualStrings("completion-module.new-public", canonical.items()[0]);

    var alias = try runtime.completionCandidates("cm.");
    defer alias.deinit();
    try std.testing.expectEqual(@as(usize, 1), alias.items().len);
    try std.testing.expectEqualStrings("cm.new-public", alias.items()[0]);

    var invalid = try runtime.completionCandidates("cm.new.");
    defer invalid.deinit();
    try std.testing.expectEqual(@as(usize, 0), invalid.items().len);
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
    try words_runtime.define(first, .{ .value = .{ .int = 1 } });
    try words_runtime.define(second, .{ .value = .{ .int = 2 } });
    words_runtime.requestCancellation();
    const words_failure = (try words_runtime.runUnit("reflection-poll.ecl", "words")).err;
    defer heap.testing.releaseValue(allocator, words_failure);
    const words_rendered = try printer.toOwnedString(allocator, words_failure);
    defer allocator.free(words_rendered);
    try std.testing.expect(std.mem.indexOf(u8, words_rendered, "unit cancelled") != null);
    try std.testing.expect(words_runtime.lastPolls() >= 1);

    var which_output = std.Io.Writer.Allocating.init(allocator);
    defer which_output.deinit();
    var which_runtime = try session.Session.initWithOutput(allocator, &.{}, &which_output.writer);
    defer which_runtime.deinit();
    try which_runtime.define(first, .{ .value = .{ .int = 1 } });
    try which_runtime.pushOwned(.{ .symbol = intern.namespaceId(first) });
    which_runtime.requestCancellation();
    const which_failure = (try which_runtime.runUnit("reflection-poll.ecl", "which")).err;
    defer heap.testing.releaseValue(allocator, which_failure);
    const which_rendered = try printer.toOwnedString(allocator, which_failure);
    defer allocator.free(which_rendered);
    try std.testing.expect(std.mem.indexOf(u8, which_rendered, "unit cancelled") != null);
    try std.testing.expect(which_runtime.lastPolls() >= 1);
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
    try qualified_runtime.pushOwned(.{ .symbol = qualified });
    qualified_runtime.requestCancellation();
    const qualified_failure = (try qualified_runtime.runUnit("reflection-poll.ecl", "which")).err;
    defer heap.testing.releaseValue(allocator, qualified_failure);
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
    try expectErrorContains(&no_output, "'dup body", &.{"'kind 'type"});
    try expectErrorContains(&no_output, "'missing which", &.{"'kind 'undefined-word"});
}

fn nativeAnswer(evaluator: *machine.NativeMachine) error{OutOfMemory}!env.PrimitiveOutcome {
    try evaluator.pushOwned(.{ .int = 42 });
    return .ok;
}

fn nativeAnswerReloaded(evaluator: *machine.NativeMachine) error{OutOfMemory}!env.PrimitiveOutcome {
    try evaluator.pushOwned(.{ .int = 43 });
    return .ok;
}

fn nativeFailure(_: *machine.NativeMachine) env.PrimitiveResult {
    return .{ .failure = machine.EclErr.init(.domain, "native failure payload") };
}

fn nativeMachineSurface(evaluator: *machine.NativeMachine) env.PrimitiveResult {
    const allocator = evaluator.allocator();
    evaluator.require(2) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => unreachable,
    };
    if (evaluator.depth() != 2) {
        return .{ .failure = machine.EclErr.init(.domain, "native depth mismatch") };
    }
    const top = evaluator.peekBorrowed(0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => unreachable,
    };
    const bottom = evaluator.peekBorrowed(1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => unreachable,
    };
    if (top != .int or top.int != 20 or bottom != .int or bottom.int != 10) {
        return .{ .failure = machine.EclErr.init(.domain, "native peek mismatch") };
    }
    try evaluator.pushBorrowed(bottom);
    evaluator.discard(2) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => unreachable,
    };
    const result = try list.fromValues(allocator, &.{.{ .int = 30 }});
    try evaluator.pushOwned(result);
    return .ok;
}

test "public native machine exposes a complete semantic stack capability" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const separator = try intern.intern("--");
    const a = try intern.intern("a");
    const b = try intern.intern("b");
    const result_name = try intern.intern("result");
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .word = a },
        .{ .word = b },
        .{ .word = separator },
        .{ .word = a },
        .{ .word = result_name },
    });
    defer heap.testing.releaseValue(allocator, effect_value);
    const effect = env.ValidatedEffect.parse(effect_value.list, separator).?;
    _ = try runtime.registerNativeModule(
        try intern.trustedNamespace("native-surface"),
        &.{.{ .primitive = .{
            .name = try intern.trustedNamespace("exercise"),
            .callback = nativeMachineSurface,
            .effect = effect,
            .doc = "Exercise the complete native stack capability.",
        } }},
    );

    try expectOk(&runtime, "10 20 native-surface.exercise");
    try std.testing.expectEqual(@as(usize, 2), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 30), (try list.at(runtime.stackItems()[1], 0)).int);
}

test "public native failures carry their payload atomically" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const separator = try intern.intern("--");
    const effect_value = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .word = separator }});
    defer heap.testing.releaseValue(std.testing.allocator, effect_value);
    const effect = (env.ValidatedEffect.parse(effect_value.list, separator)).?;
    _ = try runtime.registerNativeModule(
        try intern.trustedNamespace("failing-native"),
        &.{.{ .primitive = .{
            .name = try intern.trustedNamespace("fail"),
            .callback = nativeFailure,
            .effect = effect,
            .doc = "Return a native language failure.",
        } }},
    );
    try expectErrorContains(&runtime, "failing-native.fail", &.{
        "'kind 'domain",
        "native failure payload",
        "'word 'failing-native.fail",
    });
}

test "registry: native primitives expose ordinary reflective metadata" {
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
    defer heap.testing.releaseValue(allocator, effect_value);
    const effect = (env.ValidatedEffect.parse(effect_value.list, separator)).?;
    const module_name = try intern.trustedNamespace("native");
    const answer_name = try intern.trustedNamespace("answer");
    try std.testing.expectEqual(@as(u64, 1), try runtime.registerNativeModule(module_name, &.{.{
        .primitive = .{
            .name = answer_name,
            .callback = nativeAnswer,
            .effect = effect,
            .doc = "Return the native\nanswer.",
        },
    }}));
    try expectOk(&runtime, "native.answer 'native use answer 'n 'native alias n.answer " ++
        "'native.answer doc \"Return the native answer.\" match " ++
        "'native.answer which 'native.answer see");
    for (runtime.stackItems()[0..3]) |item| try std.testing.expectEqual(@as(i64, 42), item.int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[3].int);
    try std.testing.expectEqualStrings(
        "native.answer -> native.answer primitive public generation 1 (-- n)\n" ++
            "<primitive> (-- n : \"Return the native answer.\") 'native.answer def\n",
        output.written(),
    );
    try std.testing.expectEqual(@as(u64, 2), try runtime.registerNativeModule(module_name, &.{.{
        .primitive = .{
            .name = answer_name,
            .callback = nativeAnswerReloaded,
            .effect = effect,
            .doc = "Return the reloaded native answer.",
        },
    }}));
    try expectOk(&runtime, "native.answer answer n.answer " ++
        "'native.answer doc \"Return the reloaded native answer.\" match");
    for (runtime.stackItems()[4..7]) |item| try std.testing.expectEqual(@as(i64, 43), item.int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[7].int);
    try std.testing.expectError(
        error.InvalidName,
        intern.internNamespace("invalid.module"),
    );
    const invalid_effect = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.testing.releaseValue(allocator, invalid_effect);
    try std.testing.expect((env.ValidatedEffect.parse(
        invalid_effect.list,
        separator,
    )) == null);
    try std.testing.expectError(error.InvalidDefinition, runtime.registerNativeModule(
        try intern.trustedNamespace("undocumented-native"),
        &.{.{ .primitive = .{
            .name = answer_name,
            .callback = nativeAnswer,
            .effect = effect,
            .doc = " \n ",
        } }},
    ));
}

const EnvThreadContext = struct {
    scope: *env.Scope,
    environment: env.EnvironmentView,
    failed: *std.atomic.Value(bool),
    name: intern.NamespaceName,
};

fn envWorker(context: EnvThreadContext) void {
    for (0..100) |index| {
        _ = context.scope.publishTop(
            context.name,
            .{ .value = .{ .int = @intCast(index) } },
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

const ReclamationRaceContext = struct {
    scope: *env.Scope,
    environment: env.EnvironmentView,
    releases: *heap.ReleaseDomain,
    name: intern.NamespaceName,
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
            if (old.binding.value.int != 0) context.failed.store(true, .release);
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
            if (observed.binding.value.int != 0) context.failed.store(true, .release);
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
                if (observed.binding.value.int != 0) context.failed.store(true, .release);
                observed.deinit();
                break;
            },
        };
        std.Thread.yield() catch @panic("snapshot reader yield failed");
    }
    context.reader_done.store(true, .release);
}

fn reclamationWriter(context: ReclamationRaceContext) void {
    yieldUntilPhase(context.phase, 1);
    for (0..512) |index| context.scope.moveUseToTop(if (index & 1 == 0) 8 else 9) catch {
        context.failed.store(true, .release);
        context.phase.store(2, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.phase.store(2, .release);
    yieldUntilPhase(context.phase, 3);
    yieldUntilPhase(context.phase, 4);
    context.scope.moveUseToTop(8) catch {
        context.failed.store(true, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.phase.store(5, .release);
    while (!context.reader_loop_started.load(.acquire))
        std.Thread.yield() catch @panic("snapshot writer yield failed");
    for (513..4096) |index| context.scope.moveUseToTop(if (index & 1 == 0) 8 else 9) catch {
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
    const context = EnvThreadContext{
        .scope = &scope,
        .environment = container.sessionView(),
        .failed = &failed,
        .name = try intern.trustedNamespace("concurrent-env-name"),
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, envWorker, .{context});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), container.sessionView().generation());
}

test "env: concurrent readers writers and retirement reclaim production snapshots" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var container = try env.Env.init(host.cleanup());
    defer container.deinit();
    var scope = container.sessionRoot(std.testing.allocator);
    defer env.testing.deinitScope(&scope, releases);
    const name = try intern.trustedNamespace("concurrent-reclamation");
    _ = try scope.publishTop(name, .{ .value = .{ .int = 0 } });
    try scope.moveUseToTop(8);
    try scope.moveUseToTop(9);
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
    try std.testing.expectEqual(@as(i64, 0), current.binding.value.int);
}

test "environment and registry retirement stays bounded after a delayed reader drains" {
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
        var registry = try modules.Registry.init(host.cleanup());
        defer registry.deinit();

        const binding_name = try intern.trustedNamespace("bounded-binding");
        const module_name = try intern.trustedNamespace("bounded-module");
        const alternate_module = try intern.trustedNamespace("bounded-module-alternate");
        const alias_name = try intern.trustedNamespace("bounded-module-alias");
        _ = try scope.publishTop(binding_name, .{ .value = .{ .int = 0 } });
        try scope.moveUseToTop(8);

        // One public shape lease deliberately delays reclamation while a long
        // publication history accumulates. Releasing it must transfer the
        // whole history to bounded retirement work rather than freeing it on
        // the reader's stack.
        var delayed = environment.sessionView().acquireShape();
        for (0..512) |index| try scope.moveUseToTop(if (index & 1 == 0) 9 else 8);
        delayed.deinit();
        host.cleanup().drain();

        // Hold a production AcquireCursor's real Directory lease while both
        // alias replacement and distinct-module publication build a retired
        // directory history. Releasing the cursor must only detach and enqueue
        // that history; the shared domain reclaims it one record per turn.
        try commitEmptyModule(&registry, module_name);
        try commitEmptyModule(&registry, alternate_module);
        try registry.alias(alias_name, module_name);
        var delayed_directory = registry.acquireCursor(intern.namespaceId(module_name));
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
            try commitEmptyModule(&registry, try intern.trustedNamespace(spelling));
        }
        delayed_directory.deinit();
        host.cleanup().drain();

        for (0..128) |index| {
            _ = try scope.publishTop(binding_name, .{ .value = .{ .int = @intCast(index) } });
            try scope.moveUseToTop(if (index & 1 == 0) 9 else 8);
            try commitEmptyModule(&registry, module_name);
            try registry.alias(
                alias_name,
                if (index & 1 == 0) module_name else alternate_module,
            );
            _ = releases.advance(256);
        }
        host.cleanup().drain();
        const warmed_live_bytes = counting.total_requested_bytes;

        for (0..2048) |index| {
            _ = try scope.publishTop(binding_name, .{ .value = .{ .int = @intCast(index) } });
            try scope.moveUseToTop(if (index & 1 == 0) 9 else 8);
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

test "session: cold native registration settles generation retirement every turn" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
        defer runtime.deinit();
        const module_name = try intern.trustedNamespace("cold-native-retirement");
        for (0..64) |_| _ = try runtime.registerNativeModule(module_name, &.{});
        const warmed_live_bytes = counting.total_requested_bytes;
        for (0..1024) |_| _ = try runtime.registerNativeModule(module_name, &.{});
        try std.testing.expect(counting.total_requested_bytes <= warmed_live_bytes + 4096);
        try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "session: public definition mutation settles retirement every turn" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
        defer runtime.deinit();
        const name = try intern.trustedNamespace("public-mutation-retirement");
        for (0..64) |index| try runtime.define(
            name,
            .{ .value = .{ .int = @intCast(index) } },
        );
        const warmed_live_bytes = counting.total_requested_bytes;
        for (0..1024) |index| try runtime.define(
            name,
            .{ .value = .{ .int = @intCast(index) } },
        );
        try std.testing.expect(counting.total_requested_bytes <= warmed_live_bytes + 4096);
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
        try expectOk(&runtime, "((1) () while) spawn");
        const name = try intern.trustedNamespace("busy-worker-retirement");
        for (0..64) |index| try runtime.define(name, .{ .value = .{ .int = @intCast(index) } });
        const warmed_live_bytes = counting.total_requested_bytes;
        for (0..4096) |index| try runtime.define(name, .{ .value = .{ .int = @intCast(index) } });
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
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .word = separator }});
    defer heap.testing.releaseValue(std.testing.allocator, body);
    const document = try list.fromCodepoints(std.testing.allocator, &.{ 'd', 'o', 'c' });
    defer heap.testing.releaseValue(std.testing.allocator, document);
    const effect = (env.ValidatedEffect.parse(body.list, separator)).?;
    const name = try intern.trustedNamespace("leased-metadata");
    _ = try scope.publishTop(name, .{ .word = .{
        .body = env.quotation(body.list).?,
        .effect = effect,
        .doc = env.documentation(document.list).?,
    } });
    var old = (environment.sessionView().resolveDirect(intern.namespaceId(name))).?;
    _ = try scope.publishTop(name, .{ .value = .{ .int = 9 } });
    _ = releases.advance(1);
    try std.testing.expectEqual(@as(u32, 3), heap.refCount(body.list));
    old.deinit();
    host.cleanup().drain();
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
    _ = context.registry.commit(&candidate) catch return false;
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
        if (lease.generationNumber() == 0) context.failed.store(true, .release);
        lease.deinit();
    }
}

test "registry: concurrent commits are linearized without lost names" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var registry = try modules.Registry.init(host.cleanup());
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
    try std.testing.expectEqual(@as(u64, 200), lease.generationNumber());
    for (0..4) |index| {
        var disjoint = registry.acquire(intern.namespaceId(context.disjoint[index])).?;
        defer disjoint.deinit();
        try std.testing.expectEqual(@as(u64, 50), disjoint.generationNumber());
    }
}

test "registry: old generation leases survive reload and reclaim after release" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var registry = try modules.Registry.init(host.cleanup());
    defer registry.deinit();
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .int = 7 }});
    defer heap.testing.releaseValue(std.testing.allocator, body);
    const module_name = try intern.trustedNamespace("leased-generation");
    const value_name = try intern.trustedNamespace("leased-value");
    var first = try registry.createCandidate(module_name);
    defer first.deinit();
    _ = try first.publishDefinition(value_name, .{ .value = .{
        .item = body,
        .visibility = .public,
    } });
    _ = try registry.commit(&first);
    var old = registry.acquire(intern.namespaceId(module_name)).?;
    var second = try registry.createCandidate(module_name);
    defer second.deinit();
    _ = try registry.commit(&second);
    try std.testing.expectEqual(@as(u64, 1), old.generationNumber());
    try std.testing.expectEqual(@as(u32, 2), heap.refCount(body.list));
    old.deinit();
    host.cleanup().drain();
    try std.testing.expectEqual(@as(u32, 1), heap.refCount(body.list));
}

test "registry: generation cursors independently pin their snapshot" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var registry = try modules.Registry.init(host.cleanup());
    defer registry.deinit();
    const module_name = try intern.trustedNamespace("cursor-pinned-generation");
    const value_name = try intern.trustedNamespace("cursor-pinned-value");
    var first = try registry.createCandidate(module_name);
    defer first.deinit();
    _ = try first.publishDefinition(value_name, .{ .value = .{
        .item = .{ .int = 41 },
        .visibility = .public,
    } });
    _ = try registry.commit(&first);

    var lease = registry.acquire(intern.namespaceId(module_name)).?;
    var lookup = lease.resolveCursor(intern.namespaceId(value_name), true);
    var names = lease.publicNameCursor();
    lease.deinit();
    var second = try registry.createCandidate(module_name);
    defer second.deinit();
    _ = try registry.commit(&second);
    for (0..64) |_| _ = releases.advance(1);

    const old = while (true) switch (lookup.advance()) {
        .pending => {},
        .complete => |resolved| break resolved.?,
    };
    var old_binding = old;
    defer old_binding.deinit();
    try std.testing.expectEqual(@as(i64, 41), old_binding.binding.value.int);
    const old_name = while (true) switch (names.advance()) {
        .pending => {},
        .complete => return error.TestUnexpectedResult,
        .name => |name| break name,
    };
    try std.testing.expectEqual(intern.namespaceId(value_name), old_name);
    lookup.deinit();
    names.deinit();
    host.cleanup().drain();
}

test "module generation retirement waits for descendant scope propagation" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        defer host.cleanup().drain();
        const generation = try modules.ModuleGeneration.create(
            allocator,
            releases,
            try intern.trustedNamespace("descendant-retirement"),
        );
        const child = try env.Scope.createLazy(allocator, &generation.scope);
        _ = try child.publishTop(
            try intern.trustedNamespace("descendant-local"),
            .{ .value = .{ .int = 1 } },
        );
        // The generation owner may retire first, but its embedded scope must
        // keep both its storage and environment until the child finishes its
        // own multi-turn environment teardown and propagates the parent drop.
        generation.release();
        for (0..16) |_| _ = releases.advance(1);
        try std.testing.expect(releases.hasPending());
        const grandchild = try env.Scope.createLazy(allocator, child);
        const grandchild_name = try intern.trustedNamespace("grandchild-after-retirement");
        _ = try grandchild.publishTop(grandchild_name, .{ .value = .{ .int = 43 } });
        var grandchild_value = grandchild.environmentOrNull().?.resolveDirect(
            intern.namespaceId(grandchild_name),
        ).?;
        try std.testing.expectEqual(@as(i64, 43), grandchild_value.binding.value.int);
        grandchild_value.deinit();
        grandchild.retire();
        child.retire();
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
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
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), runtime.stackItems()[0].int);
    try std.testing.expectEqualStrings("side", output.written());
    try expectOk(&runtime, "persist");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try expectOk(&runtime, "loaded.answer");
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[2].int);
    try expectOk(&runtime, "(\"test/acceptance/load-stack.ecl\" load) attempt pop");
    try expectOk(&runtime, "\"test/acceptance/load-provenance.ecl\" load");
    try expectErrorContains(&runtime, "loaded-boom", &.{ "'word 'missing", "'source \"test/acceptance/load-provenance.ecl\"" });
    try expectOk(&runtime, "\"test/acceptance/load-stack.ecl\" load");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[3].int);
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
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "answer", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'stats use answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);

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
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var environment = try env.Env.init(host.cleanup());
    defer environment.deinit();
    var scope = environment.sessionRoot(allocator);
    defer env.testing.deinitScope(&scope, releases);
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.testing.releaseValue(allocator, body);
    const first = try intern.trustedNamespace("allocation-first");
    const second = try intern.trustedNamespace("allocation-second");
    const after_uses = try intern.trustedNamespace("allocation-after-uses");
    _ = try scope.publishTop(first, .{ .word = .{
        .body = env.quotation(body.list).?,
    } });
    var lease = (environment.sessionView().resolveDirect(intern.namespaceId(first))).?;
    defer lease.deinit();
    _ = try scope.publishTop(first, .{ .value = .{ .int = 2 } });
    _ = try scope.publishTop(second, .{ .value = .{ .int = 3 } });
    try scope.moveUseToTop(8);
    try scope.moveUseToTop(9);
    _ = try scope.publishTop(after_uses, .{ .value = .{ .int = 4 } });
    const names = try environment.sessionView().namesOwned(allocator);
    allocator.free(names);
}

fn registryAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    var registry = try modules.Registry.init(host.cleanup());
    defer registry.deinit();
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .word = try intern.intern("--") },
        .{ .word = try intern.intern("n") },
    });
    defer heap.testing.releaseValue(allocator, effect_value);
    const separator = try intern.intern("--");
    const effect = (env.ValidatedEffect.parse(effect_value.list, separator)).?;
    const document_value = try list.fromCodepoints(allocator, &.{ 'N', 'a', 't', 'i', 'v', 'e', '.' });
    defer heap.testing.releaseValue(allocator, document_value);
    const document = env.documentation(document_value.list).?;
    const first_name = try intern.trustedNamespace("allocation-module");
    const alias_name = try intern.trustedNamespace("allocation-alias");
    const second_name = try intern.trustedNamespace("allocation-native");
    const word_name = try intern.trustedNamespace("answer");
    var first = try registry.createCandidate(first_name);
    defer first.deinit();
    _ = try first.publishDefinition(word_name, .{ .primitive = .{
        .callback = nativeAnswer,
        .visibility = .public,
        .effect = effect,
        .doc = document,
    } });
    _ = try registry.commit(&first);
    try registry.alias(alias_name, first_name);
    var lease = registry.acquire(intern.namespaceId(alias_name)).?;
    defer lease.deinit();
    var second = try registry.createCandidate(first_name);
    defer second.deinit();
    _ = try second.publishDefinition(word_name, .{ .primitive = .{
        .callback = nativeAnswer,
        .visibility = .public,
        .effect = effect,
        .doc = document,
    } });
    _ = try registry.commit(&second);
    _ = try registry.registerNative(second_name, &.{.{ .primitive = .{
        .name = word_name,
        .callback = nativeAnswer,
        .effect = effect,
        .doc = "Native allocation probe.",
    } }});
}

test "environment and registry APIs propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, environmentAllocationProbe, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registryAllocationProbe, .{});
}
