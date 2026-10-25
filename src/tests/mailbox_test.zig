//! Task mailboxes as a program observes them: the `'address` value kind and
//! the words that mint one. Every case runs whole source through a public
//! Session and compares the printed stack or the printed error.
const runtime_fixture = @import("runtime_fixture.zig");
const std = @import("std");
const session = @import("../session.zig");
const printer = @import("../print.zig");
const support = @import("kernel_test_support.zig");

const allocator = std.testing.allocator;

fn expectStack(runtime: *session.Session, source: []const u8, expected: []const u8) !void {
    switch (try runtime.runUnit("<mailbox-test>", source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer runtime.release(failure);
            const rendered = try printer.toOwnedString(allocator, failure);
            defer allocator.free(rendered);
            std.debug.print("unexpected failure for `{s}`: {s}\n", .{ source, rendered });
            return error.TestUnexpectedResult;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
    try clearStack(runtime);
}

fn expectError(runtime: *session.Session, source: []const u8, expected: support.ErrorCase) !void {
    const failure = switch (try runtime.runUnit("<mailbox-test>", source)) {
        .ok => {
            std.debug.print("expected `{s}` to fail\n", .{source});
            try clearStack(runtime);
            return error.TestUnexpectedResult;
        },
        .incomplete => return error.TestUnexpectedResult,
        .err => |item| item,
    };
    defer runtime.release(failure);
    try support.expectLanguageError(failure, expected);
}

fn clearStack(runtime: *session.Session) !void {
    switch (try runtime.runUnit("<mailbox-test>", "stack len (pop) times")) {
        .ok => {},
        .incomplete, .err => return error.TestUnexpectedResult,
    }
}

fn openSession(inputs: *runtime_fixture.Fixture) !session.Session {
    return session.Session.init(allocator, &.{}, inputs.inputs(.{}), .{ .worker_pool = 1 }, .evaluate);
}

test "mailbox: addresses name a task mailbox and are opaque" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    // Two addresses of one task name one mailbox; two tasks' addresses never do.
    try expectStack(&runtime, "[] (1) @spawn dup task.address swap task.address match?", "1");
    try expectStack(&runtime, "[] (1) @spawn task.address [] (1) @spawn task.address match?", "0");
    try expectStack(&runtime, "[] (1) @spawn task.address type", "'address");
    // The address survives the task: it is derived after the result is in.
    try expectStack(&runtime, "[] (1) @spawn dup task.await pop task.address type", "'address");
    // An address prints as an unreadable marker carrying the task's number.
    try expectStack(&runtime, "[] (1) @spawn dup task.address str 9 take swap str 6 take", "\"<address:\" \"<task:\"");
    try expectStack(&runtime, "[] (1) @spawn dup task.address str 9 drop swap str 6 drop match?", "1");
    try expectError(&runtime, "\"<address:1>\" parse", .{ .name = "address marker", .source = "", .kind = "parse" });
    try expectError(&runtime, "[] (1) @spawn task.address json.emit", .{ .name = "address json", .source = "", .kind = "type" });
    try expectError(&runtime, "1 task.address", .{ .name = "address of int", .source = "", .kind = "type" });
}

test "mailbox: task.self is the executing task and is refused at the root" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    try expectError(&runtime, "task.self", .{ .name = "self at root", .source = "", .kind = "domain" });
    try expectStack(&runtime, "[] (task.self) @spawn task.await 'ok at first type", "'address");
    // A task's self is its own address, not its parent's or its child's.
    try expectStack(&runtime, "[] (task.self) @spawn dup task.address swap task.await 'ok at first match?", "1");
    try expectStack(
        &runtime,
        "[] ([] (task.self) @spawn task.await 'ok at first) @spawn dup task.address swap task.await 'ok at first match?",
        "0",
    );
}
