//! Executable proofs for immutable dict and Unicode text kernels.
const std = @import("std");
const value = @import("value.zig");
const session = @import("session.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const poll = @import("poll.zig");
const storage = @import("kernel_storage.zig");
const helper = @import("kernel_test_support.zig");

test "dict-text: dict operations preserve order ownership and right wins" {
    try helper.expectStack(
        std.testing.allocator,
        "{'a 1 'b 2} keys {'a 1} 'b 2 put {'a 1 'b 2} 'a del " ++
            "{'a 1 'b 2} {'b 20 'c 3} merge {'a 1} 'a has?",
        "['a 'b] {'a 1 'b 2} {'b 2} {'a 1 'b 20 'c 3} 1",
    );
}

test "dict-text: has is key membership for every inert structural value" {
    try helper.expectStack(
        std.testing.allocator,
        "{\"ab\" 9} \"ab\" has? {[1 2] 9} [1 2] has? " ++
            "{missing 9} (missing) first has? {{'a 1} 9} {'a 1} has? " ++
            "{1 9} 1.0 has? {\"ab\" 9} \"a\" has?",
        "1 1 1 1 1 0",
    );
    try helper.expectError(std.testing.allocator, "[] 'a has?", &.{"'kind 'type"});
}

test "dict-text: to-dict and list put" {
    try helper.expectStack(
        std.testing.allocator,
        "1 type 1.0 type \\a type 'a type (missing) first type [] type {} type " ++
            "['a 1] str " ++
            "['a 'b] [1 2] to-dict [1 2 3] 1 9 put [1 2 3] dup 1 9 put swap",
        "'int 'float 'char 'symbol 'word 'list 'dict " ++
            "\"('a 1)\" " ++
            "{'a 1 'b 2} [1 9 3] [1 9 3] [1 2 3]",
    );
    try helper.expectError(std.testing.allocator, "['a] [1 2] to-dict", &.{"'kind 'shape"});
    try helper.expectError(std.testing.allocator, "['a 'a] [1 2] to-dict", &.{"'kind 'domain"});
    try helper.expectError(std.testing.allocator, "[1 2] 2 9 put", &.{"'kind 'domain"});
    try helper.expectError(std.testing.allocator, "[1 2] -1 9 put", &.{"'kind 'domain"});
    try helper.expectError(std.testing.allocator, "[1 2] 'a 9 put", &.{"'kind 'type"});
    try helper.expectStack(
        std.testing.allocator,
        "[\\a] [1] cat 1 \\b put [\\a] [1] cat dup 1 \\b put swap",
        "\"ab\" \"ab\" (\\a 1)",
    );
}

test "dict-text: dict-of converts one flat list without evaluation" {
    try helper.expectStack(
        std.testing.allocator,
        "'total 3 4 + pair dict-of",
        "{'total 7}",
    );
    try helper.expectStack(std.testing.allocator, "[plus +] dict-of", "{plus +}");
    try helper.expectError(std.testing.allocator, "[1] dict-of", &.{"'kind 'contract"});
    try helper.expectError(std.testing.allocator, "[1 one 1.0 two] dict-of", &.{"'kind 'domain"});
    try helper.expectError(std.testing.allocator, "1 dict-of", &.{"'kind 'type"});
}

test "dict-text: split handles codepoints substrings and empty separators" {
    try helper.expectStack(
        std.testing.allocator,
        "\"a—b—\" \"—\" split \"ab\" \"\" split",
        "(\"a\" \"b\" \"\") (\"\" \"a\" \"b\" \"\")",
    );
}

test "dict-text: join requires strings and chooses narrow char width" {
    try helper.expectStack(std.testing.allocator, "[\"a\" \"b\"] \"—\" join", "\"a—b\"");
    try helper.expectError(std.testing.allocator, "[\"a\" 2] \"-\" join", &.{ "'kind 'type", "'index 1" });
}

test "dict-text: format enforces braces placeholders and canonical values" {
    try helper.expectStack(
        std.testing.allocator,
        "[3.14 2] \"pi={} n={} {{ok}}\" format",
        "\"pi=3.14 n=2 {ok}\"",
    );
    try helper.expectError(std.testing.allocator, "[1] \"{} {}\" format", &.{"'kind 'contract"});
    try helper.expectError(std.testing.allocator, "[] \"{\" format", &.{"'kind 'domain"});
}

test "dict-text: update traversals charge polls while copying" {
    const allocator = std.testing.allocator;

    var small_pairs: [20]dict.Pair = undefined;
    for (&small_pairs, 0..) |*pair, index| pair.* = .{
        .{ .int = @intCast(index) },
        .{ .int = @intCast(index) },
    };
    const small = try dict.fromUniquePairs(allocator, &small_pairs);
    defer heap.releaseValue(allocator, small);
    const Counter = struct {
        calls: usize = 0,

        fn tick(raw: *anyopaque) poll.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    var counter: Counter = .{};
    _ = try storage.get(allocator, small, .{ .int = 19 }, .{
        .context = &counter,
        .poll_fn = Counter.tick,
    });
    const Mutator = struct {
        source: value.Value,
        mutate_at: usize,
        calls: usize = 0,

        fn tick(raw: *anyopaque) poll.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls != self.mutate_at) return;
            const values = heap.dictStorage(self.source.dict).payload.?.vals;
            heap.items(i64, values)[0] = 999;
        }
    };
    var mutator = Mutator{ .source = small, .mutate_at = counter.calls + 2 };
    const updated = try storage.put(allocator, small, .{ .int = 19 }, .{ .int = 190 }, .{
        .context = &mutator,
        .poll_fn = Mutator.tick,
    });
    try std.testing.expectEqual(small.dict, updated.dict);
    try std.testing.expectEqual(@as(i64, 0), (try dict.get(updated, .{ .int = 0 })).?.int);

    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();

    const integers = try allocator.alloc(i64, 70_000);
    defer allocator.free(integers);
    for (integers, 0..) |*integer, index| integer.* = @intCast(index);
    const sequence = try list.fromI64Slice(allocator, integers);
    defer heap.releaseValue(allocator, sequence);
    heap.retainValue(sequence);
    runtime.stack.append(allocator, sequence) catch |err| {
        heap.releaseValue(allocator, sequence);
        return err;
    };
    try std.testing.expect((try runtime.runUnit("<test>", "69999 1 put pop")) == .ok);
    try std.testing.expect(runtime.last_polls >= 1);

    const pairs = try allocator.alloc(dict.Pair, 70_000);
    defer allocator.free(pairs);
    for (pairs, 0..) |*pair, index| pair.* = .{
        .{ .int = @intCast(index) },
        .{ .int = @intCast(index) },
    };
    var ignored: u8 = 0;
    const NoPoll = struct {
        fn tick(_: *anyopaque) poll.Error!void {}
    };
    const dictionary = try storage.fromUniquePairs(allocator, pairs, .{
        .context = &ignored,
        .poll_fn = NoPoll.tick,
    });
    defer heap.releaseValue(allocator, dictionary);

    heap.retainValue(dictionary);
    runtime.stack.append(allocator, dictionary) catch |err| {
        heap.releaseValue(allocator, dictionary);
        return err;
    };
    try std.testing.expect((try runtime.runUnit("<test>", "70000 1 put pop")) == .ok);
    try std.testing.expect(runtime.last_polls >= 1);

    heap.retainValue(dictionary);
    runtime.stack.append(allocator, dictionary) catch |err| {
        heap.releaseValue(allocator, dictionary);
        return err;
    };
    try std.testing.expect((try runtime.runUnit("<test>", "69999 del pop")) == .ok);
    try std.testing.expect(runtime.last_polls >= 1);

    heap.retainValue(dictionary);
    runtime.stack.append(allocator, dictionary) catch |err| {
        heap.releaseValue(allocator, dictionary);
        return err;
    };
    try std.testing.expect((try runtime.runUnit("<test>", "{70000 1} merge pop")) == .ok);
    try std.testing.expect(runtime.last_polls >= 1);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const outcome = try runtime.runUnit(
        "<allocation>",
        "{'a 1} 'b 2 put keys pop [\"a\" \"b\"] \"—\" join \"—\" split pop " ++
            "['a 'b] [1 2] to-dict keys pop ['c 3] dict-of keys pop [1 2 3] 1 9 put pop " ++
            "\"ab\" reverse 0 \\λ put pop ['a 1] str [1] \"{}\" format",
    );
    if (outcome == .err) heap.releaseValue(allocator, outcome.err);
}

test "dict-text: allocation failures release updates and text scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
