const std = @import("std");
const value = @import("../value.zig");
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
        const source = try list.fromValuesGeneric(allocator, &.{.{ .word = marker }});
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

test "env: new names and use edits bump shape and deep lookup is ordered" {
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
    _ = try scope.publishModule(first, binding.module(effect.effect, .public));
    try std.testing.expectEqual(@as(u64, 1), environment.generation());
    _ = try scope.publishModule(second, binding.module(effect.effect, .public));
    try std.testing.expectEqual(@as(u64, 2), environment.generation());
    try scope.moveUseToTop(@enumFromInt(8));
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try scope.moveUseToTop(@enumFromInt(8));
    try std.testing.expectEqual(@as(u64, 3), environment.generation());
    try scope.moveUseToTop(@enumFromInt(9));
    try scope.moveUseToTop(@enumFromInt(8));
    var shape = environment.acquireShape();
    defer shape.deinit();
    try std.testing.expectEqualSlices(
        intern.ModuleName,
        &.{ @enumFromInt(9), @enumFromInt(8) },
        shape.useOrder(),
    );
    const names = try environment.namesOwned(std.testing.allocator);
    defer std.testing.allocator.free(names);
    std.mem.sort(u32, names, {}, std.sort.asc(u32));
    var expected = [_]u32{ intern.namespaceId(first), intern.namespaceId(second) };
    std.mem.sort(u32, &expected, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &expected, names);
    scope.freezeModule();
    try std.testing.expectError(
        error.Frozen,
        scope.publishModule(first, binding.module(effect.effect, .public)),
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

test "scope: isolated @attempt and child use do not leak" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectErrorContains(&runtime, "(1 'k set) @attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectErrorContains(&runtime, "((1 'k set missing) @attempt pop) @attempt pop k", &.{ "'kind 'undefined-word", "'word 'k" });
    try expectOk(&runtime, "(7 'x set) 'm @defm");
    try expectErrorContains(&runtime, "('m use x) @attempt pop x", &.{ "'kind 'undefined-word", "'word 'x" });
}

test "module: privacy module-body contract top-level private and qualified trace" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @defm m.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "m.s", &.{ "'kind 'undefined-word", "'word 'm.s" });
    try expectOk(&runtime, "((41) ( -- n ) 'g defp (g 1 +) ( -- n ) 'f def) 'private-word @defm private-word.f");
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "private-word.g", &.{ "'kind 'undefined-word", "'word 'private-word.g" });
    try expectErrorContains(&runtime, "1 'x setp", &.{ "'kind 'domain", "defp/setp" });
    // A body that leaves values behind registers: they become the slot's
    // durable stack, not bindings, so no name appears for them.
    try expectOk(&runtime, "(1) 'bad @defm");
    try expectErrorContains(&runtime, "bad.x", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "((1 'hidden set) @attempt pop) 'temporary @defm");
    try expectErrorContains(&runtime, "temporary.hidden", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "((missing) ( -- n ) 'boom def) 'trace-module @defm");
    try expectErrorContains(&runtime, "trace-module.boom", &.{ "'word 'missing", "'trace ['missing 'trace-module.boom]" });
    try expectOk(&runtime, "((dup 0 > (1 - f 1 +) (pop missing) if) ( n -- n ) 'f def) 'recursive @defm");
    try expectErrorContains(&runtime, "2 recursive.f", &.{"'trace ['missing 'recursive.f 'recursive.f 'recursive.f]"});
}

test "modules: removal strips aliases and leaves no half-removed entry" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "((1) 'x def) 'a @defm ((2) 'x def) 'b @defm " ++
        "'short 'a alias 'a use short.x a.x x");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try expectOk(&runtime, "'a unmodule");
    // The canonical name and every alias targeting it go in one publish.
    try expectErrorContains(&runtime, "a.x", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "short.x", &.{"'kind 'undefined-word"});
    try expectErrorContains(&runtime, "'short use", &.{"'kind 'undefined-word"});
    // Enumeration never shows a half-removed entry, and unrelated modules
    // and their aliases are untouched.
    try expectOk(&runtime, "'other 'b alias other.x b.x");
    // Re-aliasing a removed name is a missing-module error as before.
    try expectErrorContains(&runtime, "'again 'a alias", &.{"'kind 'undefined-word"});
}

test "module: qualified use alias ordering idempotence and collisions" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(1 'x set) 'a @defm (2 'x set) 'b @defm " ++
        "'a use 'b use x 'a use x 'short 'a alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "'a 'b alias", &.{"'kind 'domain"});
    try expectOk(&runtime, "'short 'b alias short.x");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[3].int);
    try expectErrorContains(&runtime, "'future 'a alias (3 'x set) 'future @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "'dotted.name 'a alias", &.{"'kind 'domain"});
}

test "module: provisional tasks keep rollback generations alive until quiescence" {
    var runtime = try session.Session.initWithConfig(
        std.testing.allocator,
        &.{},
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "((((1) () while) @spawn pop missing) 'bad @defm) @attempt pop");
}

test "module: hot reload commit failure and whole-body pinning" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(1 'x setp " ++
        "((2 'x setp (x) ( -- n ) 'get def) 'm @defm x) ( -- n ) 'probe def " ++
        "(x) ( -- n ) 'get def) 'm @defm m.probe m.get");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "(3 'x setp missing) 'm @defm", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "m.get");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[2].int);
    try expectErrorContains(&runtime, "((9) ( -- n ) 'get def) 'kept @defm missing", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "kept.get");
    try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[3].int);
}

test "module: effect shape cross-home contract and same-home TCO" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // A module word may omit its annotation entirely; only a malformed
    // recognized annotation is 'domain.
    try expectOk(&runtime, "((dup) 'f def) 'fine @defm");
    try expectErrorContains(&runtime, "((dup) (a -- b -- c) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectErrorContains(&runtime, "((dup) (a 1 -- b) 'f def) 'bad @defm", &.{"'kind 'domain"});
    try expectOk(&runtime, "((dup 0 > (1 - countdown) (pop) if) ( n -- ) 'countdown def) 'm @defm");
    try expectOk(&runtime, "20 m.countdown");
    const shallow_frames = runtime.lastMaxFrames();
    try expectOk(&runtime, "20000 m.countdown");
    try std.testing.expectEqual(shallow_frames, runtime.lastMaxFrames());
    try expectErrorContains(&runtime, "((dup +) ( a -- b c ) 'f def) 'lies @defm 1 lies.f", &.{ "'kind 'contract", "'word 'lies.f" });
    try expectErrorContains(&runtime, "((dup) ( a -- a a ) 'f def) 'needs @defm needs.f", &.{ "'kind 'contract", "seeded 0" });
    try expectErrorContains(&runtime, "((missing) ( -- n ) 'f def) 'throws @defm throws.f", &.{ "'kind 'undefined-word", "'word 'missing" });
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
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "1 'mean set 2 'count set (3 'mean set 4 'count set 5 'other set) 'stats @defm 'stats use mean count");
    try std.testing.expectEqualStrings(
        "session `count` shadows `stats.count`\n" ++
            "session `mean` shadows `stats.mean`\n",
        diagnostics.written(),
    );
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[1].int);
    const notice_len = diagnostics.written().len;
    try expectOk(&runtime, "('stats use other pop) @attempt pop ('stats use (other) ( -- n ) 'get def) 'consumer @defm consumer.get pop");
    try std.testing.expectEqual(notice_len, diagnostics.written().len);

    var output_buffer: [64]u8 = undefined;
    var fixed_output = std.Io.Writer.fixed(&output_buffer);
    var no_diagnostic_space: [0]u8 = .{};
    var broken_diagnostics = std.Io.Writer.fixed(&no_diagnostic_space);
    var broken = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &fixed_output,
            .diagnostics = &broken_diagnostics,
            .ecl_path = null,
        },
    );
    defer broken.deinit();
    try expectErrorContains(&broken, "1 'x set (2 'x set 3 'y set) 'm @defm 'm use", &.{"'kind 'io"});
    try expectErrorContains(&broken, "y", &.{"'kind 'undefined-word"});
}

test "module: use shadow notices stay within the cancellation bound" {
    const allocator = std.testing.allocator;
    const name_bytes = try allocator.alloc(u8, 70_000);
    defer allocator.free(name_bytes);
    @memset(name_bytes, 's');
    const long_name = try intern.internNamespace(name_bytes);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics = std.Io.Writer.Allocating.init(allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHost(
        allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    const binding = try TestBinding.init(allocator);
    defer runtime.release(binding.body);
    try runtime.define(long_name, binding.top());
    const module_source = try std.fmt.allocPrint(allocator, "(2 '{s} set) 'wide @defm", .{name_bytes});
    defer allocator.free(module_source);
    try expectOk(&runtime, module_source);
    runtime.requestCancellation();
    const failure = (try runtime.runUnit("shadow-poll.ecl", "'wide use")).err;
    defer runtime.release(failure);
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
    try expectErrorContains(&name_runtime, "@defm", &.{"unit cancelled"});
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
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @defm 'm use " ++
        "'m.f see 9 'f set 'f which 'f see words");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(s 2 +) (-- n) 'm.f def") != null);
    // One binding kind: a session constant reports as a public def with no
    // metadata, because the sugar supplies none, and `see` prints the stored
    // literal capture rather than reconstructing the `set` spelling.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "f -> f def public; shadows m.f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([9] first) 'f def") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), " s ") == null);
    try expectErrorContains(&runtime, "'m.f body call", &.{ "'kind 'undefined-word", "'word 's" });
}

test "reflection: body extraction loses home context" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    try expectOk(&runtime, "(40 's setp (s 2 +) ( -- n ) 'f def) 'm @defm");
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
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "(1 'hidden setp 2 'zebra set 3 'alpha set) 'm @defm 'm use 4 'zebra set words");
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
        "(1 'hidden setp 2 'public set) 'completion-module @defm " ++
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
        "(1 'old-public set 2 'private-name setp) 'completion-module @defm " ++
            "'cm 'completion-module alias " ++
            "(3 'new-public set 4 'new-private setp) 'completion-module @defm",
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
    try expectErrorContains(&no_output, "'dup body", &.{"'kind 'type"});
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
        _ = context.scope.publishTop(
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

const ReclamationRaceContext = struct {
    scope: *env.Scope,
    environment: env.EnvironmentView,
    releases: *heap.ReleaseDomain,
    name: intern.NamespaceName,
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
    yieldUntilPhase(context.phase, 1);
    for (0..512) |index| context.scope.moveUseToTop(@enumFromInt(@as(u32, if (index & 1 == 0) 8 else 9))) catch {
        context.failed.store(true, .release);
        context.phase.store(2, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.phase.store(2, .release);
    yieldUntilPhase(context.phase, 3);
    yieldUntilPhase(context.phase, 4);
    context.scope.moveUseToTop(@enumFromInt(8)) catch {
        context.failed.store(true, .release);
        context.writer_done.store(true, .release);
        return;
    };
    context.phase.store(5, .release);
    while (!context.reader_loop_started.load(.acquire))
        std.Thread.yield() catch @panic("snapshot writer yield failed");
    for (513..4096) |index| context.scope.moveUseToTop(@enumFromInt(@as(u32, if (index & 1 == 0) 8 else 9))) catch {
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
    const name = try intern.internNamespace("concurrent-reclamation");
    const binding = try TestBinding.init(std.testing.allocator);
    defer binding.release(releases);
    _ = try scope.publishTop(name, binding.top());
    try scope.moveUseToTop(@enumFromInt(8));
    try scope.moveUseToTop(@enumFromInt(9));
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

        const binding_name = try intern.internNamespace("bounded-binding");
        const module_name = try intern.internModuleName("bounded-module");
        const alternate_module = try intern.internModuleName("bounded-module-alternate");
        const alias_name = try intern.internNamespace("bounded-module-alias");
        const binding = try TestBinding.init(allocator);
        defer binding.release(releases);
        _ = try scope.publishTop(binding_name, binding.top());
        try scope.moveUseToTop(@enumFromInt(8));

        // One public shape lease deliberately delays reclamation while a long
        // publication history accumulates. Releasing it must transfer the
        // whole history to bounded retirement work rather than freeing it on
        // the reader's stack.
        var delayed = environment.sessionView().acquireShape();
        for (0..512) |index| try scope.moveUseToTop(@enumFromInt(@as(u32, if (index & 1 == 0) 9 else 8)));
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
            _ = try scope.publishTop(binding_name, binding.top());
            try scope.moveUseToTop(@enumFromInt(@as(u32, if (index & 1 == 0) 9 else 8)));
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
            _ = try scope.publishTop(binding_name, binding.top());
            try scope.moveUseToTop(@enumFromInt(@as(u32, if (index & 1 == 0) 9 else 8)));
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
    const body = try list.fromValuesGeneric(std.testing.allocator, &.{.{ .word = separator }});
    defer releases.releaseValue(body);
    const document = try list.fromCodepoints(std.testing.allocator, &.{ 'd', 'o', 'c' });
    defer releases.releaseValue(document);
    const effect = (env.ValidatedEffect.parse(body.list, separator)).?;
    const name = try intern.internNamespace("leased-metadata");
    _ = try scope.publishTop(name, .{ .word = .{
        .body = env.quotation(body.list).?,
        .effect = effect,
        .doc = env.documentation(document.list).?,
    } });
    var old = (environment.sessionView().resolveDirect(intern.namespaceId(name))).?;
    // The replacement deliberately shares nothing with the original body, so
    // the old lease is the only thing still holding it.
    const replacement = try TestBinding.init(std.testing.allocator);
    defer replacement.release(releases);
    _ = try scope.publishTop(name, replacement.top());
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
        var lease = context.registry.acquire(context.shared) orelse {
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
    var lease = registry.acquire(context.shared).?;
    defer lease.deinit();
    try std.testing.expectEqual(@as(u64, 200), lease.generationNumber());
    for (0..4) |index| {
        var disjoint = registry.acquire(context.disjoint[index]).?;
        defer disjoint.deinit();
        try std.testing.expectEqual(@as(u64, 50), disjoint.generationNumber());
    }
}

test "registry: old generation leases survive reload and reclaim after release" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var registry = try modules.Registry.init(host.cleanup());
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
    var old = registry.acquire(module_name).?;
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
    var registry = try modules.Registry.init(host.cleanup());
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

    var lease = registry.acquire(module_name).?;
    var lookup = lease.resolveCursor(intern.namespaceId(value_name), true);
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

test "module image retirement waits for descendant scope propagation" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const allocator = counting.allocator();
    {
        var runtime = try session.Session.initWithConfig(allocator, &.{}, .cooperative);
        defer runtime.deinit();
        // The body spawns a task whose `@attempt` opens a lazy child scope of
        // the image's module root, and leaves that task on the construction
        // stack, where it becomes part of the image's initial-state template.
        // Dropping the image therefore releases an owner whose descendant
        // scope is still propagating its own multi-turn teardown. If the
        // embedded scope or its environment were destroyed before that
        // propagation finished, this aborts inside the allocator rather than
        // failing an assertion — which is why the shape is driven through the
        // ordinary words instead of a handcrafted seam.
        const cycle = "(1 'x setp ((x) @attempt) @spawn) @module pop";
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
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = null,
        },
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
    try expectOk(&runtime, "(\"test/acceptance/load-stack.ecl\" load) @attempt pop");
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
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = search,
        },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "('attempted use answer) @attempt pop attempted.answer");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try expectErrorContains(&runtime, "answer", &.{"'kind 'undefined-word"});
    try expectOk(&runtime, "'stats use answer");
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);

    var no_path = try session.Session.initWithHost(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = "",
        },
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
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = "test/acceptance/modules",
        },
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
    defer releases.releaseValue(body);
    const first = try intern.internNamespace("allocation-first");
    const second = try intern.internNamespace("allocation-second");
    const after_uses = try intern.internNamespace("allocation-after-uses");
    _ = try scope.publishTop(first, .{ .word = .{
        .body = env.quotation(body.list).?,
    } });
    var lease = (environment.sessionView().resolveDirect(intern.namespaceId(first))).?;
    defer lease.deinit();
    _ = try scope.publishTop(first, .{ .word = .{ .body = env.quotation(body.list).? } });
    _ = try scope.publishTop(second, .{ .word = .{ .body = env.quotation(body.list).? } });
    try scope.moveUseToTop(@enumFromInt(8));
    try scope.moveUseToTop(@enumFromInt(9));
    _ = try scope.publishTop(after_uses, .{ .word = .{ .body = env.quotation(body.list).? } });
    const names = try environment.sessionView().namesOwned(allocator);
    allocator.free(names);
}

fn registryAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    const releases = host.domain();
    defer host.cleanup().drain();
    var registry = try modules.Registry.init(host.cleanup());
    defer registry.deinit();
    const effect_value = try list.fromValuesGeneric(allocator, &.{
        .{ .word = try intern.intern("--") },
        .{ .word = try intern.intern("n") },
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
    var lease = registry.acquire(try intern.internModuleName("allocation-alias")).?;
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

test "modules: module set and setp publish unannotated constants" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var runtime = try session.Session.initWithOutput(std.testing.allocator, &.{}, &output.writer);
    defer runtime.deinit();
    // Registration succeeding is itself the proof that a module definition
    // may carry no effect at all: `set` publishes the bare literal capture,
    // so constants need no value exception and no synthesized metadata.
    try expectOk(&runtime, "(7 'x set 8 'h setp (h) (-- n) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x m.peek");
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[1].int);
    // Privacy is unchanged, and the published effect is visible to
    // reflection exactly as a hand-written one would be.
    try expectErrorContains(&runtime, "m.h", &.{ "'kind 'undefined-word", "'word 'm.h" });
    try expectOk(&runtime, "'m.x which 'm.x see");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "m.x -> m.x def public") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(-- value)") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "([7] first) 'm.x def") != null);
}

test "modules: cross-home constant references cross unchecked while declared effects still bind" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    // A constant reached across a home boundary declares no effect, so no
    // check frame is installed at all: qualified access, spliced access, and
    // module-internal access agree without one.
    try expectOk(&runtime, "(7 'x set 8 'h setp (h) (-- n) 'peek def) 'm @defm");
    try expectOk(&runtime, "m.x 'm use x m.peek");
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 8), runtime.stackItems()[2].int);
    // The frame is a real contract for `(-- value)` declarations: a module
    // word declaring it and leaving two values is a contract violation.
    try expectErrorContains(
        &runtime,
        "((1 2) (-- value) 'two def) 'liar @defm liar.two",
        // Seeded/observed are absolute stack depths, so assert the parts that
        // do not depend on what this session left on the stack.
        &.{ "'kind 'contract", "'word 'liar.two", "declared (0 -- 1)" },
    );
}
