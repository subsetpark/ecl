const std = @import("std");
const ecl = @import("ecl-native");

fn increment(call: *ecl.Call("n -- result")) ecl.CallbackResult {
    const input = call.input(0).int() orelse return call.fail(.type, "increment expects an integer");
    return call.complete(.{ecl.Scalar.int(input + 1)});
}

fn discard(call: *ecl.Call("value --")) ecl.CallbackResult {
    return call.complete(.{});
}

fn split(call: *ecl.Call("value -- left right")) ecl.CallbackResult {
    return call.complete(.{ try call.forward(0), try call.forward(0) });
}

fn forward(call: *ecl.Call("value -- result")) ecl.CallbackResult {
    return call.complete(.{try call.forward(0)});
}

fn failUser(call: *ecl.Call("--")) ecl.CallbackResult {
    return call.fail(.user, "sample native failure");
}

fn failKind(call: *ecl.Call("kind --")) ecl.CallbackResult {
    const code = call.input(0).int() orelse return call.fail(.type, "fail-kind expects an integer");
    const kind: ecl.ErrorKind = switch (code) {
        0 => .type,
        1 => .shape,
        2 => .conform,
        3 => .overflow,
        4 => .domain,
        5 => .parse,
        6 => .io,
        7 => .user,
        else => return call.fail(.domain, "fail-kind expects 0 through 7"),
    };
    return call.fail(kind, "selected native failure");
}

fn makeChar(call: *ecl.Call("codepoint -- result")) ecl.CallbackResult {
    const input = call.input(0).int() orelse
        return call.fail(.type, "make-char expects an integer");
    if (input < 0 or input > std.math.maxInt(u32))
        return call.fail(.domain, "make-char expects an unsigned 32-bit integer");
    return call.complete(.{ecl.Scalar.char(@intCast(input))});
}

const OneBuild = struct {
    pub const State = struct { appended: bool };
    pub fn init() State {
        return .{ .appended = false };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const OneBuildSchedule = ecl.Reschedule(OneBuild);

fn singleton(
    call: *ecl.Call("value -- result"),
    build: *ecl.BuildValues,
    schedule: *OneBuildSchedule,
) ecl.CallbackResult {
    if (!schedule.state().appended) {
        const item = try call.forward(0);
        switch (try build.appendList(0, 1, item)) {
            .appended => schedule.state().appended = true,
            .yield_required => return schedule.yield(),
            .invalid => return call.fail(.domain, "singleton builder was rejected"),
        }
    }
    const result = switch (try build.finishList(0, 1)) {
        .candidate => |candidate| candidate,
        .yield_required => return schedule.yield(),
        .invalid => return call.fail(.domain, "singleton builder was rejected"),
    };
    return call.complete(.{result});
}

fn pairDict(
    call: *ecl.Call("key value -- result"),
    build: *ecl.BuildValues,
    schedule: *OneBuildSchedule,
) ecl.CallbackResult {
    if (!schedule.state().appended) {
        const key = try call.forward(0);
        const item = try call.forward(1);
        switch (try build.appendDict(0, 1, key, item)) {
            .appended => schedule.state().appended = true,
            .yield_required => return schedule.yield(),
            .invalid => return call.fail(.domain, "pair-dict builder was rejected"),
        }
    }
    const result = switch (try build.finishDict(0, 1)) {
        .candidate => |candidate| candidate,
        .yield_required => return schedule.yield(),
        .invalid => return call.fail(.domain, "pair-dict builder was rejected"),
    };
    return call.complete(.{result});
}

const ScanWork = struct {
    pub const State = struct { next: u64, total: i64 };
    pub fn init() State {
        return .{ .next = 0, .total = 0 };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const ScanSchedule = ecl.Reschedule(ScanWork);

fn sumList(
    call: *ecl.Call("values -- result"),
    schedule: *ScanSchedule,
) ecl.CallbackResult {
    const state = schedule.state();
    const cursor = call.listCursor(0, state.next) orelse
        return call.fail(.type, "sum-list expects a list");
    while (true) switch (cursor.next()) {
        .item => |item| {
            const number = item.int() orelse
                return call.fail(.type, "sum-list expects integer items");
            state.next += 1;
            state.total = std.math.add(i64, state.total, number) catch
                return call.fail(.overflow, "sum-list overflowed");
        },
        .end => return call.complete(.{ecl.Scalar.int(state.total)}),
        .yield_required => return schedule.yield(),
        .invalid => return call.fail(.shape, "sum-list cursor became invalid"),
    };
}

fn sumDict(
    call: *ecl.Call("values -- result"),
    schedule: *ScanSchedule,
) ecl.CallbackResult {
    const state = schedule.state();
    const cursor = call.dictCursor(0, state.next) orelse
        return call.fail(.type, "sum-dict expects a dictionary");
    while (true) switch (cursor.next()) {
        .item => |item| {
            if (item.key.kind() == .dict or item.key.kind() == .list)
                return call.fail(.type, "sum-dict expects scalar keys");
            const number = item.value.int() orelse
                return call.fail(.type, "sum-dict expects integer values");
            state.next += 1;
            state.total = std.math.add(i64, state.total, number) catch
                return call.fail(.overflow, "sum-dict overflowed");
        },
        .end => return call.complete(.{ecl.Scalar.int(state.total)}),
        .yield_required => return schedule.yield(),
        .invalid => return call.fail(.shape, "sum-dict cursor became invalid"),
    };
}

fn noncooperative(call: *ecl.Call("-- result")) ecl.CallbackResult {
    var delay = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    while (std.c.nanosleep(&delay, &delay) != 0) {}
    return call.complete(.{ecl.Scalar.int(42)});
}

const LongWork = struct {
    pub const State = struct { remaining: u32 };
    pub fn init() State {
        return .{ .remaining = 200_000 };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const LongSchedule = ecl.Reschedule(LongWork);

fn cooperative(
    call: *ecl.Call("-- result"),
    schedule: *LongSchedule,
) ecl.CallbackResult {
    const state = schedule.state();
    while (state.remaining != 0) {
        if (!schedule.consume(1)) return schedule.yield();
        state.remaining -= 1;
    }
    return call.complete(.{ecl.Scalar.int(42)});
}

const TwoSlices = struct {
    pub const State = struct { yielded: bool };
    pub fn init() State {
        return .{ .yielded = false };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const TwoSliceSchedule = ecl.Reschedule(TwoSlices);

fn draftFail(
    call: *ecl.Call("value -- result"),
    schedule: *TwoSliceSchedule,
) ecl.CallbackResult {
    _ = try call.forward(0);
    if (!schedule.state().yielded) {
        schedule.state().yielded = true;
        return schedule.yield();
    }
    return call.fail(.user, "draft candidates retired");
}

fn yieldForever(
    call: *ecl.Call("value -- result"),
    schedule: *TwoSliceSchedule,
) ecl.CallbackResult {
    _ = try call.forward(0);
    return schedule.yield();
}

fn builderBudget(
    call: *ecl.Call("-- result"),
    build: *ecl.BuildValues,
    schedule: *TwoSliceSchedule,
) ecl.CallbackResult {
    if (!schedule.state().yielded) {
        if (!schedule.consume(65_534)) unreachable;
        const item = try build.scalar(ecl.Scalar.int(1));
        switch (try build.appendList(0, 1, item)) {
            .appended => {},
            .yield_required, .invalid => unreachable,
        }
        schedule.state().yielded = true;
        return switch (try build.finishList(0, 1)) {
            .yield_required => schedule.yield(),
            .candidate => call.fail(.user, "aggregate materialization ignored the exhausted turn"),
            .invalid => call.fail(.domain, "aggregate builder was rejected"),
        };
    }
    return switch (try build.finishList(0, 1)) {
        .candidate => call.complete(.{ecl.Scalar.int(42)}),
        .yield_required => schedule.yield(),
        .invalid => call.fail(.domain, "aggregate builder was rejected"),
    };
}

const AggregateWork = struct {
    pub const State = struct { next: u64 };
    pub fn init() State {
        return .{ .next = 0 };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const AggregateSchedule = ecl.Reschedule(AggregateWork);

fn largeList(
    call: *ecl.Call("count -- result"),
    build: *ecl.BuildValues,
    schedule: *AggregateSchedule,
) ecl.CallbackResult {
    const count_value = call.input(0).int() orelse
        return call.fail(.type, "large-list expects a nonnegative integer");
    if (count_value < 0) return call.fail(.domain, "large-list expects a nonnegative integer");
    const count: u64 = @intCast(count_value);
    const state = schedule.state();
    while (state.next != count) {
        const item = try build.scalar(ecl.Scalar.int(@intCast(state.next)));
        switch (try build.appendList(0, count, item)) {
            .appended => state.next += 1,
            .yield_required => return schedule.yield(),
            .invalid => return call.fail(.domain, "large-list builder was rejected"),
        }
    }
    return switch (try build.finishList(0, count)) {
        .candidate => |candidate| call.complete(.{candidate}),
        .yield_required => schedule.yield(),
        .invalid => call.fail(.domain, "large-list builder was rejected"),
    };
}

fn largeDict(
    call: *ecl.Call("count -- result"),
    build: *ecl.BuildValues,
    schedule: *AggregateSchedule,
) ecl.CallbackResult {
    const count_value = call.input(0).int() orelse
        return call.fail(.type, "large-dict expects a nonnegative integer");
    if (count_value < 0) return call.fail(.domain, "large-dict expects a nonnegative integer");
    const count: u64 = @intCast(count_value);
    const state = schedule.state();
    while (state.next != count) {
        const key = try build.scalar(ecl.Scalar.int(@intCast(state.next)));
        const item = try build.scalar(ecl.Scalar.int(@intCast(state.next + 1)));
        switch (try build.appendDict(0, count, key, item)) {
            .appended => state.next += 1,
            .yield_required => return schedule.yield(),
            .invalid => return call.fail(.domain, "large-dict builder was rejected"),
        }
    }
    return switch (try build.finishDict(0, count)) {
        .candidate => |candidate| call.complete(.{candidate}),
        .yield_required => schedule.yield(),
        .invalid => call.fail(.domain, "large-dict builder was rejected"),
    };
}

fn duplicateDict(
    call: *ecl.Call("-- result"),
    build: *ecl.BuildValues,
    schedule: *AggregateSchedule,
) ecl.CallbackResult {
    const state = schedule.state();
    while (state.next != 2) {
        const key = try build.scalar(ecl.Scalar.int(1));
        const item = try build.scalar(ecl.Scalar.int(@intCast(state.next)));
        switch (try build.appendDict(0, 2, key, item)) {
            .appended => state.next += 1,
            .yield_required => return schedule.yield(),
            .invalid => return call.fail(.domain, "duplicate-dict append was rejected"),
        }
    }
    return switch (try build.finishDict(0, 2)) {
        .candidate => |candidate| call.complete(.{candidate}),
        .yield_required => schedule.yield(),
        .invalid => call.fail(.domain, "duplicate dictionary key"),
    };
}

pub const Extension = ecl.module(.{
    .name = "sample",
    .doc = "Sample extension used by ecl's native acceptance suite.",
    .words = .{
        ecl.word("increment", "Increment an integer.", increment),
        ecl.word("discard", "Discard one value.", discard),
        ecl.word("split", "Return one input twice.", split),
        ecl.word("forward", "Forward an input unchanged.", forward),
        ecl.word("fail-user", "Raise the user error kind.", failUser),
        ecl.word("fail-kind", "Raise one of the eight author-owned error kinds.", failKind),
        ecl.word("make-char", "Construct a character through the SDK scalar boundary.", makeChar),
        ecl.word("singleton", "Build a singleton list.", singleton),
        ecl.word("pair-dict", "Build a one-entry dictionary.", pairDict),
        ecl.word("sum-list", "Sum an integer list through a metered cursor.", sumList),
        ecl.word("sum-dict", "Sum integer dictionary values through a metered cursor.", sumDict),
        ecl.word("cooperative", "Complete after several scheduler quanta.", cooperative),
        ecl.word("draft-fail", "Yield with drafts and then fail.", draftFail),
        ecl.word("yield-forever", "Yield until the calling task is cancelled.", yieldForever),
        ecl.word("builder-budget", "Prove aggregate builders charge the native budget.", builderBudget),
        ecl.word("large-list", "Build a list across multiple scheduler turns.", largeList),
        ecl.word("large-dict", "Build a dictionary across multiple scheduler turns.", largeDict),
        ecl.word("duplicate-dict", "Report duplicate dictionary keys without trapping.", duplicateDict),
        ecl.word("noncooperative", "Demonstrate the opt-in native overrun diagnostic.", noncooperative),
    },
});

comptime {
    _ = Extension;
}
