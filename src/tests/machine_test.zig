//! Cross-layer frame-machine proofs owned by M3's final patch.

const std = @import("std");
const session = @import("../session.zig");
const test_heap = @import("test_heap.zig");
const value = @import("../value.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const printer = @import("../print.zig");

const Value = value.Value;

fn field(allocator: std.mem.Allocator, dictionary: Value, name: []const u8) !Value {
    const key = try intern.intern(name);
    return (try dict.symbolField(allocator, dictionary, key)).?;
}

fn execute(runtime: *session.Session, source: []const u8) !?Value {
    return switch (try runtime.runUnit("fixture.ecl", source)) {
        .ok => null,
        .incomplete => error.TestUnexpectedResult,
        .err => |failure| failure,
    };
}

fn errorKind(allocator: std.mem.Allocator, error_value: Value) ![]const u8 {
    return intern.get((try field(allocator, error_value, "kind")).symbol);
}

test "twenty-thousand-deep named recursion remains flat" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    const source =
        "(dup 0 > (1 - countdown) (pop) if) 'countdown def " ++
        "20000 countdown";
    try std.testing.expect((try runtime.runUnit("countdown.ecl", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 0), runtime.stackItems().len);
    try std.testing.expect(runtime.lastMaxFrames() <= 1);
}

test "machine: boundary truncation is exact through nested attempts" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    const source = "7 (8 (pop) @attempt pop pop missing) @attempt";
    try std.testing.expect((try runtime.runUnit("boundaries.ecl", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 2), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    const outer_error = try field(
        allocator,
        runtime.stackItems()[1],
        "err",
    );
    const kind = try field(allocator, outer_error, "kind");
    try std.testing.expectEqualStrings("undefined-word", intern.get(kind.symbol));
}

test "errors: contract depths are relative to the isolated substack" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    const source = "7 8 ((1 2) () while) @attempt";
    try std.testing.expect((try runtime.runUnit("contract.ecl", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    const contract_error = try field(
        allocator,
        runtime.stackItems()[2],
        "err",
    );
    const kind = try field(allocator, contract_error, "kind");
    try std.testing.expectEqualStrings("contract", intern.get(kind.symbol));
    const data = try field(allocator, contract_error, "data");
    try std.testing.expectEqual(@as(i64, 0), (try field(allocator, data, "seeded")).int);
    try std.testing.expectEqual(@as(i64, 2), (try field(allocator, data, "observed")).int);
}

test "errors: lazy trace is innermost-first and retains recursive activations" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    const source =
        "(dup 0 > (1 - f pop) (pop missing) if) 'f def 1 f";
    const failure = (try runtime.runUnit("recursive.ecl", source)).err;
    defer runtime.release(failure);
    const trace = try field(allocator, failure, "trace");
    try std.testing.expectEqual(@as(u64, 3), trace.list.length());
    try std.testing.expectEqualStrings("missing", intern.get(list.atUnchecked(trace, 0).symbol));
    try std.testing.expectEqualStrings("f", intern.get(list.atUnchecked(trace, 1).symbol));
    try std.testing.expectEqualStrings("f", intern.get(list.atUnchecked(trace, 2).symbol));
}

test "errors: tail-position application continuations retain their enclosing word" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    const failure = (try runtime.runUnit(
        "application-trace.ecl",
        "((missing) () while) 'f def f",
    )).err;
    defer runtime.release(failure);
    const trace = try field(allocator, failure, "trace");
    try std.testing.expectEqual(@as(u64, 2), trace.list.length());
    try std.testing.expectEqualStrings("missing", intern.get(list.atUnchecked(trace, 0).symbol));
    try std.testing.expectEqualStrings("f", intern.get(list.atUnchecked(trace, 1).symbol));

    const callback_failure = (try runtime.runUnit(
        "application-callback-trace.ecl",
        "((2) () while) 'g def g",
    )).err;
    defer runtime.release(callback_failure);
    const callback_trace = try field(allocator, callback_failure, "trace");
    try std.testing.expectEqual(@as(u64, 2), callback_trace.list.length());
    try std.testing.expectEqualStrings("while", intern.get(list.atUnchecked(callback_trace, 0).symbol));
    try std.testing.expectEqualStrings("g", intern.get(list.atUnchecked(callback_trace, 1).symbol));

    const contract_failure = (try runtime.runUnit(
        "application-contract-trace.ecl",
        "([1] (dup) each) 'h def h",
    )).err;
    defer runtime.release(contract_failure);
    const contract_trace = try field(allocator, contract_failure, "trace");
    try std.testing.expectEqual(@as(u64, 2), contract_trace.list.length());
    try std.testing.expectEqualStrings("each", intern.get(list.atUnchecked(contract_trace, 0).symbol));
    try std.testing.expectEqualStrings("h", intern.get(list.atUnchecked(contract_trace, 1).symbol));
}

test "machine_test: late binding redefinition heals existing callers" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "(1 +) 'step def (step) 'caller def 2 caller",
    )) == .ok);
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "pop (10 +) 'step def 2 caller",
    )) == .ok);
    try std.testing.expectEqual(@as(i64, 12), runtime.stackItems()[0].int);
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "pop 40 'step set caller",
    )) == .ok);
    try std.testing.expectEqual(@as(i64, 40), runtime.stackItems()[0].int);
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "pop (1 +) 'quoted set quoted",
    )) == .ok);
    try std.testing.expect(runtime.stackItems()[0] == .list);
}

test "early prelude installs source-defined wrap and pair" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "1 wrap 2 3 pair 'wrap body 'pair body",
    )) == .ok);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("[1] [2 3] (() cons) (() cons cons)", display.bytes());
}

test "provisional scalar primitives enforce the non-finite regime" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();

    const overflow = (try execute(&runtime, "9223372036854775806 2 +")).?;
    defer runtime.release(overflow);
    try std.testing.expectEqualStrings("overflow", try errorKind(allocator, overflow));
    try std.testing.expect((try execute(&runtime, "inf 1 +")) == null);
    try std.testing.expect(std.math.isPositiveInf(runtime.stackItems()[0].float));
    const domain = (try execute(&runtime, "inf inf -")).?;
    defer runtime.release(domain);
    try std.testing.expectEqualStrings("domain", try errorKind(allocator, domain));
}

test "division and comparison remain exact across 2^53" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try execute(&runtime, "1 2 /")) == null);
    try std.testing.expectEqual(@as(f64, 0.5), runtime.stackItems()[0].float);
    try std.testing.expect((try execute(&runtime, "9007199254740993 9007199254740992.0 >")) == null);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);
}

test "attempt reifies failure and def rejects scalar bodies" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try execute(&runtime, "7 (1 0 /) @attempt")) == null);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    const err_key = try intern.intern("err");
    try std.testing.expect((try dict.symbolField(
        allocator,
        runtime.stackItems()[1],
        err_key,
    )) != null);
    try std.testing.expect((try execute(&runtime, "pop (pop) @attempt")) == null);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    const isolated_error = (try dict.symbolField(
        allocator,
        runtime.stackItems()[1],
        err_key,
    )).?;
    try std.testing.expectEqualStrings("underflow", try errorKind(allocator, isolated_error));
    try std.testing.expect((try execute(&runtime, "(2 3 +) @attempt")) == null);
    const ok_key = try intern.intern("ok");
    const ok_results = (try dict.symbolField(
        allocator,
        runtime.stackItems()[2],
        ok_key,
    )).?;
    try std.testing.expectEqual(@as(i64, 5), list.atUnchecked(ok_results, 0).int);
    const failure = (try execute(&runtime, "1 'x def")).?;
    defer runtime.release(failure);
    try std.testing.expectEqualStrings("type", try errorKind(allocator, failure));
}

test "raise preserves valid user dicts and validates optional fields" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    const raised = (try execute(&runtime, "{'kind 'custom 'msg \"hello\"} raise")).?;
    defer runtime.release(raised);
    const rendered = try printer.toOwnedString(allocator, raised);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'custom 'msg \"hello\" 'word 'raise 'trace ['raise] " ++
            "'data {'source \"fixture.ecl\" 'line 1 'col 30}}",
        rendered,
    );

    const defaulted = (try execute(&runtime, "{'kind 'custom} raise")).?;
    defer runtime.release(defaulted);
    const defaulted_rendered = try printer.toOwnedString(allocator, defaulted);
    defer allocator.free(defaulted_rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'custom 'msg \"raised 'custom\" 'word 'raise 'trace ['raise] " ++
            "'data {'source \"fixture.ecl\" 'line 1 'col 17}}",
        defaulted_rendered,
    );

    const merged = (try execute(&runtime, "{'kind 'custom 'data {'detail 7}} raise")).?;
    defer runtime.release(merged);
    try std.testing.expectEqualStrings(
        "raise",
        intern.get((try field(allocator, merged, "word")).symbol),
    );
    const merged_trace = try field(allocator, merged, "trace");
    try std.testing.expectEqual(@as(u64, 1), merged_trace.list.length());
    try std.testing.expectEqualStrings(
        "raise",
        intern.get(list.atUnchecked(merged_trace, 0).symbol),
    );
    const merged_data = try field(allocator, merged, "data");
    try std.testing.expectEqual(@as(i64, 7), (try field(allocator, merged_data, "detail")).int);
    _ = try field(allocator, merged_data, "source");
    _ = try field(allocator, merged_data, "line");
    _ = try field(allocator, merged_data, "col");

    const complete = (try execute(
        &runtime,
        "{'kind 'custom 'msg \"old\" 'word 'origin 'trace ['origin] " ++
            "'data {'source \"old.ecl\" 'line 9 'col 8} 'detail 7} raise",
    )).?;
    defer runtime.release(complete);
    const complete_rendered = try printer.toOwnedString(allocator, complete);
    defer allocator.free(complete_rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'custom 'msg \"old\" 'word 'origin 'trace ['origin] " ++
            "'data {'source \"old.ecl\" 'line 9 'col 8} 'detail 7}",
        complete_rendered,
    );

    const malformed = (try execute(&runtime, "{'kind 1} raise")).?;
    defer runtime.release(malformed);
    try std.testing.expectEqualStrings("type", try errorKind(allocator, malformed));
}

test "over compose and at have exact stack effects" {
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();

    try std.testing.expect((try execute(&runtime, "1 2 over")) == null);
    try std.testing.expectEqualSlices(
        Value,
        &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 1 } },
        runtime.stackItems(),
    );
    try std.testing.expect((try execute(&runtime, "pop pop pop (1 2) (3 4) compose")) == null);
    const composed = runtime.stackItems()[0];
    try std.testing.expect(composed == .list);
    try std.testing.expectEqual(@as(i64, 1), list.atUnchecked(composed, 0).int);
    try std.testing.expectEqual(@as(i64, 2), list.atUnchecked(composed, 1).int);
    try std.testing.expectEqual(@as(i64, 3), list.atUnchecked(composed, 2).int);
    try std.testing.expectEqual(@as(i64, 4), list.atUnchecked(composed, 3).int);
    try std.testing.expect((try execute(&runtime, "pop [10 20] 1 at")) == null);
    try std.testing.expectEqual(@as(i64, 20), runtime.stackItems()[0].int);
}

test "io.pp and io.prin write through and writer failures become io errors" {
    const allocator = std.testing.allocator;
    var captured: std.Io.Writer.Allocating = .init(allocator);
    defer captured.deinit();
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.initWithOutput(runtime_heap.allocator(), &.{}, &captured.writer);
    defer runtime.deinit();
    try std.testing.expect((try execute(&runtime, "\"hi\" io.prin 'visible io.pp")) == null);
    try std.testing.expectEqualStrings("hi'visible\n", captured.written());

    var failing: std.Io.Writer = .failing;
    var broken_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&broken_heap);
    var broken = try session.Session.initWithOutput(broken_heap.allocator(), &.{}, &failing);
    defer broken.deinit();
    const failure = (try execute(&broken, "'broken io.pp")).?;
    defer broken.release(failure);
    try std.testing.expectEqualStrings("io", try errorKind(allocator, failure));
}

test "inline control and reader-lowered binders execute" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try execute(&runtime, "1 (2 +) call")) == null);
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expect((try execute(&runtime, "pop 1 9 (2 +) dip")) == null);
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[1].int);
    try std.testing.expect((try execute(&runtime, "pop pop 3 (|x| x x *) call")) == null);
    try std.testing.expectEqual(@as(i64, 9), runtime.stackItems()[0].int);
    try std.testing.expect((try execute(&runtime, "pop 3 (dup 0 >) (1 -) while pop")) == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.stackItems().len);
    const invalid_branch = (try execute(&runtime, "1 (2) 3 if")).?;
    defer runtime.release(invalid_branch);
    try std.testing.expectEqualStrings("type", try errorKind(allocator, invalid_branch));
}

test "public parse reifies forms without execution and retains provenance" {
    const allocator = std.testing.allocator;
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try execute(&runtime, "\"42 missing\" parse")) == null);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("(42 missing)", display.bytes());

    const failure = (try execute(&runtime, "pop \"(missing)\" parse first call")).?;
    defer runtime.release(failure);
    try std.testing.expectEqualStrings("undefined-word", try errorKind(allocator, failure));
    const data = try field(allocator, failure, "data");
    const source = try field(allocator, data, "source");
    const rendered_source = try printer.toOwnedString(allocator, source);
    defer allocator.free(rendered_source);
    try std.testing.expectEqualStrings("\"<parse>\"", rendered_source);
}

test "public parse maps malformed incomplete and type inputs to language errors" {
    try @import("kernel_test_support.zig").expectErrors(&.{
        .{ .name = "malformed", .source = "\"[1)\" parse", .kind = "parse", .word = "parse" },
        .{ .name = "incomplete", .source = "\"(1\" parse", .kind = "parse", .word = "parse" },
        .{ .name = "type", .source = "1 parse", .kind = "type", .word = "parse" },
    });
}

test "public parse cancellation reaches UTF-8 materialization" {
    const allocator = std.testing.allocator;
    const text_len = 40_000;
    const source = try allocator.alloc(u8, text_len + 2);
    defer allocator.free(source);
    source[0] = '"';
    @memset(source[1 .. text_len + 1], 'a');
    source[text_len + 1] = '"';

    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit("<parse-encoding-setup>", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    runtime.requestCancellation();
    const failure = switch (try runtime.runUnit("<parse-encoding-cancel>", "parse")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer runtime.release(failure);
    try std.testing.expectEqualStrings("cancelled", try errorKind(allocator, failure));
    const rendered = try printer.toOwnedString(allocator, failure);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unit cancelled") != null);
    try std.testing.expect(runtime.lastPolls() >= 1);
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(u32, text_len), runtime.stackItems()[0].list.length());
}

test "public parse cancellation reaches ignored-source scanning" {
    const allocator = std.testing.allocator;
    const comment_len = 20_000;
    const suffix = "\" parse";
    const command = try allocator.alloc(u8, 2 + comment_len + suffix.len);
    defer allocator.free(command);
    command[0] = '"';
    command[1] = '#';
    @memset(command[2 .. 2 + comment_len], 'a');
    @memcpy(command[2 + comment_len ..], suffix);
    var runtime_heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&runtime_heap);
    var runtime = try session.Session.init(runtime_heap.allocator(), &.{});
    defer runtime.deinit();
    runtime.requestCancellation();
    const failure = switch (try runtime.runUnit("<parse-cancel-test>", command)) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer runtime.release(failure);
    try std.testing.expectEqualStrings("cancelled", try errorKind(allocator, failure));
    const rendered = try printer.toOwnedString(allocator, failure);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unit cancelled") != null);
    try std.testing.expect(runtime.lastPolls() >= 1);
    try std.testing.expectEqual(@as(usize, 0), runtime.stackItems().len);
}
