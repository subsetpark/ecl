//! Cross-layer frame-machine proofs owned by M3's final patch.

const std = @import("std");
const session = @import("session.zig");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");

const Value = value.Value;

fn field(allocator: std.mem.Allocator, dictionary: Value, name: []const u8) !Value {
    const key = try intern.intern(name);
    return (try dict.symbolField(allocator, dictionary, key)).?;
}

test "twenty-thousand-deep named recursion remains flat" {
    var runtime = try session.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();
    const source =
        "(dup 0 > (1 - countdown) (pop) if) 'countdown def " ++
        "20000 countdown";
    try std.testing.expect((try runtime.runUnit("countdown.ecl", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 0), runtime.stack.items.len);
    try std.testing.expect(runtime.last_max_frames <= 1);
}

test "machine: boundary truncation is exact through nested attempts" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const source = "7 (8 (pop) attempt pop pop missing) attempt";
    try std.testing.expect((try runtime.runUnit("boundaries.ecl", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 2), runtime.stack.items.len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stack.items[0].int);
    const outer_error = try field(
        allocator,
        runtime.stack.items[1],
        "err",
    );
    const kind = try field(allocator, outer_error, "kind");
    try std.testing.expectEqualStrings("undefined-word", intern.get(kind.symbol));
}

test "errors: contract depths are relative to the isolated substack" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const source = "7 8 ((1 2) () while) attempt";
    try std.testing.expect((try runtime.runUnit("contract.ecl", source)) == .ok);
    try std.testing.expectEqual(@as(usize, 3), runtime.stack.items.len);
    const contract_error = try field(
        allocator,
        runtime.stack.items[2],
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
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const source =
        "(dup 0 > (1 - f pop) (pop missing) if) 'f def 1 f";
    const failure = (try runtime.runUnit("recursive.ecl", source)).err;
    defer heap.releaseValue(allocator, failure);
    const trace = try field(allocator, failure, "trace");
    try std.testing.expectEqual(@as(u64, 3), trace.list.len);
    try std.testing.expectEqualStrings("missing", intern.get(list.atUnchecked(trace, 0).symbol));
    try std.testing.expectEqualStrings("f", intern.get(list.atUnchecked(trace, 1).symbol));
    try std.testing.expectEqualStrings("f", intern.get(list.atUnchecked(trace, 2).symbol));
}

test "machine_test: late binding redefinition heals existing callers" {
    const allocator = std.testing.allocator;
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "(1 +) 'step def (step) 'caller def 2 caller",
    )) == .ok);
    try std.testing.expectEqual(@as(i64, 3), runtime.stack.items[0].int);
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "pop (10 +) 'step def 2 caller",
    )) == .ok);
    try std.testing.expectEqual(@as(i64, 12), runtime.stack.items[0].int);
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "pop 40 'step let caller",
    )) == .ok);
    try std.testing.expectEqual(@as(i64, 40), runtime.stack.items[0].int);
    try std.testing.expect((try runtime.runUnit(
        "<test>",
        "pop (1 +) 'quoted let quoted",
    )) == .ok);
    try std.testing.expect(runtime.stack.items[0] == .list);
}
