const std = @import("std");
const session = @import("session.zig");
const machine = @import("machine.zig");
const heap = @import("heap.zig");
const support = @import("kernel_test_support.zig");

const allocator = std.testing.allocator;

fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    switch (try runtime.runUnit("<combinator-test>", source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer heap.releaseValue(allocator, failure);
            return error.TestUnexpectedResult;
        },
    }
    const display = try runtime.stackDisplay();
    defer allocator.free(display);
    try std.testing.expectEqualStrings(expected, display);
}

fn expectCancelledAfterSetup(
    setup: []const u8,
    source: []const u8,
    mode: machine.IdiomMode,
) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    switch (try runtime.runUnit("<combinator-setup>", setup)) {
        .ok => {},
        .err => |failure| {
            heap.releaseValue(allocator, failure);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), runtime.stack.items.len);
    runtime.idiom_mode = mode;
    runtime.cancelled.store(true, .release);
    const failure = switch (try runtime.runUnit("<combinator-cancel>", source)) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer heap.releaseValue(allocator, failure);
    try support.expectLanguageError(failure, .{
        .name = source,
        .source = source,
        .kind = "user",
        .message = "unit cancelled",
    });
    try std.testing.expect(runtime.last_polls >= 1);
    try std.testing.expectEqual(@as(usize, 1), runtime.stack.items.len);
}

test "combinators: isolated iteration broadcast reduction and infra" {
    try support.expectStacks(&.{
        .{ .name = "each", .source = "[1 2 3] (dup *) each", .expected = "[1 4 9]" },
        .{ .name = "each2 right broadcast", .source = "[1 2 3] 10 (pair) each2", .expected = "([1 10] [2 10] [3 10])" },
        .{ .name = "each2 left broadcast", .source = "10 [1 2 3] (pair) each2", .expected = "([10 1] [10 2] [10 3])" },
        .{ .name = "fold", .source = "[1 2 3] 0 (+) fold", .expected = "6" },
        .{ .name = "scan", .source = "[1 2 3] 0 (+) scan", .expected = "[1 3 6]" },
        .{ .name = "infra", .source = "7 [1 2 3] (dup) infra", .expected = "7 [1 2 3 3]" },
        .{ .name = "empty each", .source = "() (dup) each", .expected = "()" },
        .{ .name = "empty scan", .source = "() 0 (+) scan", .expected = "()" },
        .{ .name = "empty each2 lists", .source = "[] [] (+) each2", .expected = "()" },
        .{ .name = "empty each2 right broadcast", .source = "[] 10 (+) each2", .expected = "()" },
        .{ .name = "empty each2 left broadcast", .source = "10 [] (+) each2", .expected = "()" },
        .{ .name = "empty string each2", .source = "\"\" 10 (+) each2", .expected = "()" },
    });
}

test "combinators: contracts and conformability are structural errors" {
    try support.expectErrors(&.{
        .{
            .name = "each effect",
            .source = "[10 20] (dup) each",
            .kind = "contract",
            .word = "each",
            .data = &.{
                .{ .name = "index", .expected = .{ .int = 0 } },
                .{ .name = "seeded", .expected = .{ .int = 1 } },
                .{ .name = "observed", .expected = .{ .int = 2 } },
            },
        },
        .{ .name = "each no result", .source = "[10] (pop) each", .kind = "contract", .word = "each" },
        .{ .name = "for result", .source = "[10] (dup) for", .kind = "contract", .word = "for" },
        .{ .name = "fold extra result", .source = "[10] 0 (dup) fold", .kind = "contract", .word = "fold" },
        .{ .name = "scan extra result", .source = "[10] 0 (dup) scan", .kind = "contract", .word = "scan" },
        .{ .name = "each2 atoms", .source = "1 2 (+) each2", .kind = "type", .word = "each2" },
        .{
            .name = "each2 lengths",
            .source = "[1] [2 3] (+) each2",
            .kind = "conform",
            .word = "each2",
            .data = &.{
                .{ .name = "left", .expected = .{ .int = 1 } },
                .{ .name = "right", .expected = .{ .int = 2 } },
            },
        },
    });
}

test "combinators: child scopes are fresh and discarded" {
    try support.expectErrors(&.{
        .{
            .name = "each scope",
            .source = "[1 2 3] (dup 'k set k *) each pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "each2 scope",
            .source = "[1] [2] (pop dup 'k set k pop) each2 pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "for scope",
            .source = "[1] (dup 'k set pop) for k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "fold scope",
            .source = "[1] 0 (+ dup 'k set) fold pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "scan scope",
            .source = "[1] 0 (+ dup 'k set) scan pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "infra scope",
            .source = "[1] (dup 'k set) infra pop k",
            .kind = "undefined-word",
            .word = "k",
        },
    });
}

test "inline times cond and case prevalidate and select" {
    try support.expectStacks(&.{
        .{ .name = "times", .source = "0 3 (1 +) times", .expected = "3" },
        .{ .name = "cond false", .source = "[(0) (111) (222)] cond", .expected = "222" },
        .{ .name = "cond true", .source = "[(1) (111) (222)] cond", .expected = "111" },
        .{ .name = "cond else no-op", .source = "7 [()] cond", .expected = "7" },
        .{ .name = "case", .source = "3 [1 (10) 3 (30) (90)] case", .expected = "30" },
        .{ .name = "case inert key", .source = "(missing) [(missing) (7) (9)] case", .expected = "7" },
        .{ .name = "case inert word subject", .source = "(foo) first [foo (7) (9)] case", .expected = "7" },
        .{ .name = "case first duplicate", .source = "1 [1 (10) 1 (20) (30)] case", .expected = "10" },
    });
    try support.expectErrors(&.{
        .{ .name = "cond shape", .source = "[] cond", .kind = "shape", .word = "cond" },
        .{ .name = "cond even", .source = "[() ()] cond", .kind = "shape", .word = "cond" },
        .{ .name = "cond type", .source = "[() 1 ()] cond", .kind = "type", .word = "cond" },
        .{ .name = "while consumes ambient stack", .source = "42 (pop) () while", .kind = "contract", .word = "while" },
        .{ .name = "cond consumes ambient stack", .source = "42 [(pop) () ()] cond", .kind = "contract", .word = "cond" },
        .{ .name = "case prevalidation", .source = "1 [1 (10) 2 20 (30)] case", .kind = "type", .word = "len" },
        .{
            .name = "cond prevalidation precedes effects",
            .source = "([(1 'k set 1) (10) 20] cond) attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
        .{
            .name = "case prevalidation precedes actions",
            .source = "(1 [1 (7 'k set) 2 20 (30)] case) attempt pop k",
            .kind = "undefined-word",
            .word = "k",
        },
    });
}

test "empty inline iterations remain cancellable and bounded-frame" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    runtime.cancelled.store(true, .release);
    const failure = switch (try runtime.runUnit("<combinator-cancel>", "70000 () times")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer heap.releaseValue(allocator, failure);
    try support.expectLanguageError(failure, .{
        .name = "cancelled times",
        .source = "70000 () times",
        .kind = "user",
        .word = "times",
        .message = "unit cancelled",
    });
    try std.testing.expect(runtime.last_polls >= 1);
    try std.testing.expect(runtime.last_max_frames <= 2);
}

test "combinators: loops guards reductions and result materialization stay cancellable" {
    try expectCancelledAfterSetup("70001 range (pop ()) each", "cond", .automatic);
    try expectCancelledAfterSetup("70000 range", "(dup pop) each", .generic_only);
    try expectCancelledAfterSetup("70000 range", "sort", .automatic);
    try expectCancelledAfterSetup("70000 range", "0 (+) fold", .automatic);
    // The idiom loop consumes fewer than one kernel quantum; its second
    // traversal, result specialization, is what crosses the poll boundary.
    try expectCancelledAfterSetup("40000 range", "(1 +) each", .automatic);
}

test "idioms: automatic hits and forced generic preserves behavior" {
    var automatic = try session.Session.init(allocator, &.{});
    defer automatic.deinit();
    try expectStack(&automatic, "[1 2 3] (neg) each", "[-1 -2 -3]");
    try std.testing.expectEqual(@as(u64, 1), automatic.last_idiom_hits);

    var generic = try session.Session.init(allocator, &.{});
    defer generic.deinit();
    generic.idiom_mode = .generic_only;
    try expectStack(&generic, "[1 2 3] (neg) each", "[-1 -2 -3]");
    try std.testing.expectEqual(@as(u64, 0), generic.last_idiom_hits);

    try expectStack(&automatic, "pop [3 1 2] sort", "[1 2 3]");
    try std.testing.expectEqual(@as(u64, 1), automatic.last_idiom_hits);

    var fallback = try session.Session.init(allocator, &.{});
    defer fallback.deinit();
    const failure = switch (try fallback.runUnit("<idiom-fallback>", "1 (neg) each")) {
        .err => |item| item,
        .ok, .incomplete => return error.TestUnexpectedResult,
    };
    defer heap.releaseValue(allocator, failure);
    try std.testing.expectEqual(@as(u64, 0), fallback.last_idiom_hits);

    var executable_form = try session.Session.init(allocator, &.{});
    defer executable_form.deinit();
    try expectStack(&executable_form, "[1 2 3] (dup *) each", "[1 4 9]");
    try std.testing.expectEqual(@as(u64, 0), executable_form.last_idiom_hits);
}

test "idioms: late binding defeats recognition" {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    try expectStack(&runtime, "(pop pop 42) '+ def [1 2 3] 0 (+) fold", "42");
    try std.testing.expectEqual(@as(u64, 0), runtime.last_idiom_hits);

    var direct_sort = try session.Session.init(allocator, &.{});
    defer direct_sort.deinit();
    try expectStack(&direct_sort, "(pop [0]) 'grade def [3 1 2] sort", "[3]");
    try std.testing.expectEqual(@as(u64, 0), direct_sort.last_idiom_hits);

    var used_sort = try session.Session.init(allocator, &.{});
    defer used_sort.deinit();
    try expectStack(
        &used_sort,
        "'m ((pop [0]) (a -- b) 'grade def) module 'm use [3 1 2] sort",
        "[3]",
    );
    try std.testing.expectEqual(@as(u64, 0), used_sort.last_idiom_hits);

    var between_applications = try session.Session.init(allocator, &.{});
    defer between_applications.deinit();
    try expectStack(
        &between_applications,
        "[1 2] (dup 1 = ('m ((pop 42) (a -- b) 'f def) module) () if m.f) each",
        "[42 42]",
    );
    try std.testing.expectEqual(@as(u64, 0), between_applications.last_idiom_hits);
}
