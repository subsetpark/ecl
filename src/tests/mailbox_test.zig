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
    return openPool(inputs, 1);
}

fn openPool(inputs: *runtime_fixture.Fixture, workers: usize) !session.Session {
    return session.Session.init(allocator, &.{}, inputs.inputs(.{}), .{ .worker_pool = workers }, .evaluate);
}

test "mailbox: addresses name a task mailbox and are opaque" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    // Two addresses of one task name one mailbox; two tasks' addresses never do.
    try expectStack(&runtime, "[] (1) @spawn dup task.address swap task.address match?", "1");
    try expectStack(&runtime, "[] (1) @spawn task.address [] (1) @spawn task.address match?", "0");
    try expectStack(&runtime, "[] (1) @spawn task.address type", "address");
    // The address survives the task: it is derived after the result is in.
    try expectStack(&runtime, "[] (1) @spawn dup task.await pop task.address type", "address");
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
    try expectStack(&runtime, "[] (task.self) @spawn task.await `ok at first type", "address");
    // A task's self is its own address, not its parent's or its child's.
    try expectStack(&runtime, "[] (task.self) @spawn dup task.address swap task.await `ok at first match?", "1");
    try expectStack(
        &runtime,
        "[] ([] (task.self) @spawn task.await `ok at first) @spawn dup task.address swap task.await `ok at first match?",
        "0",
    );
}

test "mailbox: send and receive round trip in order" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    try expectStack(
        &runtime,
        "[] (3 (task.receive) times 3 pack) @spawn dup task.address 1 over task.send 2 over task.send 3 swap task.send task.await `ok at first",
        "[1 2 3]",
    );
    // A flat list of any length is checked in one step and arrives whole.
    try expectStack(
        &runtime,
        "[] (task.receive len) @spawn dup task.address 1000000 range swap task.send task.await",
        "{ok [1000000]}",
    );
    // An address is an ordinary value to send, including inside a dict.
    try expectStack(&runtime, "[] (task.receive type) @spawn dup task.address dup task.send task.await", "{ok (address)}");
    try expectStack(
        &runtime,
        "[] (task.receive `reply at type) @spawn dup task.address dup {} `reply rolldown put swap task.send task.await",
        "{ok (address)}",
    );
}

test "mailbox: send refuses handles, non-addresses, and closed mailboxes" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    try expectError(&runtime, "[] (task.receive) @spawn `receiver set receiver dup task.address task.send", .{ .name = "handle", .source = "", .kind = "type" });
    try expectError(&runtime, "{} `h receiver put receiver task.address task.send", .{ .name = "nested handle", .source = "", .kind = "type" });
    try expectError(&runtime, "receiver 1 pack receiver task.address task.send", .{ .name = "handle in a list", .source = "", .kind = "type" });
    try expectStack(&runtime, "receiver task.cancel receiver task.await `err at `kind at", "cancelled");
    try expectError(&runtime, "1 receiver task.send", .{ .name = "not an address", .source = "", .kind = "type" });
    try expectError(&runtime, "[] (1) @spawn dup task.await pop task.address 1 swap task.send", .{
        .name = "closed",
        .source = "",
        .kind = "io",
        .data = &.{.{ .name = "reason", .expected = .{ .symbol = "closed" } }},
    });
    try expectError(&runtime, "task.receive", .{ .name = "root receive", .source = "", .kind = "domain" });
    try expectError(&runtime, "5 task.receive-for", .{ .name = "root receive-for", .source = "", .kind = "domain" });
}

fn pressureCase(workers: usize) !void {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openPool(&inputs, workers);
    defer runtime.deinit();
    // The receiver is asleep while forty messages arrive, so the sender
    // parks at the sixteenth and resumes as the receiver drains.
    try expectStack(
        &runtime,
        "[] (20 clock.sleep 40 (task.receive) times 40 pack) @spawn dup task.address `box set " ++
            "0 40 (dup box task.send 1 +) times pop task.await `ok at first 40 range match?",
        "1",
    );
    // A sender parked on a full mailbox fails once its receiver is cancelled.
    try expectStack(
        &runtime,
        "[] (100000 clock.sleep) @spawn dup task.address `sink set [] (17 (0 sink task.send) times) @spawn " ++
            "5 clock.sleep swap task.cancel task.await `err at `kind at",
        "io",
    );
}

test "mailbox: pressure parks the sender and drains in order under one and eight workers" {
    try pressureCase(1);
    try pressureCase(8);
}

test "mailbox: receive-for returns the message or a timeout value" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    try expectStack(&runtime, "[] (20 task.receive-for) @spawn task.await `ok at first `err at `kind at", "timeout");
    try expectStack(&runtime, "[] (1000 task.receive-for) @spawn dup task.address 7 swap task.send task.await `ok at first", "{ok 7}");
    try expectStack(&runtime, "[] (-1 task.receive-for) @spawn task.await `err at `kind at", "domain");
    try expectStack(&runtime, "[] (`x task.receive-for) @spawn task.await `err at `kind at", "type");
}

test "mailbox: a composed request and reply round trip through a helper task" {
    var inputs = try runtime_fixture.Fixture.init();
    defer inputs.deinit();
    var runtime = try openSession(&inputs);
    defer runtime.deinit();
    // The caller spawns a helper whose address travels as 'from and whose
    // result is the reply; the only bound is task.await-for.
    try expectStack(
        &runtime,
        "(|a v| [] (task.receive) @spawn dup task.address {} `value v put `from rolldown put a task.send task.await `ok at first) `ask def " ++
            "[] (task.receive dup `from at swap `value at 1 + swap task.send) @spawn task.address 41 ask",
        "42",
    );
    try expectStack(
        &runtime,
        "(|a v ms| [] (task.receive) @spawn dup task.address {} `value v put `from rolldown put a task.send dup ms task.await-for swap task.cancel) `ask-for def " ++
            "[] (task.receive pop 100000 clock.sleep) @spawn dup task.address 41 20 ask-for `err at `kind at swap task.cancel",
        "timeout",
    );
}
