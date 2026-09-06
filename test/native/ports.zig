// zlint-disable homeless-try -- Zig validates the SDK callback error unions.
const std = @import("std");
const ecl = @import("ecl-native");
var cleaned: std.atomic.Value(u32) = .init(0);
var entered: std.atomic.Value(u32) = .init(0);
var admitted: std.atomic.Value(u32) = .init(0);
var waiting: std.atomic.Value(u32) = .init(0);
var fail_open: std.atomic.Value(bool) = .init(false);
var block_open: std.atomic.Value(bool) = .init(false);
var gate_mutex: std.Io.Mutex = .init;
var gate_changed: std.Io.Condition = .init;
var permits: u32 = 0;
fn fixtureIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn awaitGate(cancelled: *std.atomic.Value(bool)) void {
    std.Io.Threaded.mutexLock(&gate_mutex);
    defer std.Io.Threaded.mutexUnlock(&gate_mutex);
    _ = entered.fetchAdd(1, .release);
    while (permits == 0 and !cancelled.load(.acquire)) gate_changed.waitUncancelable(fixtureIo(), &gate_mutex);
    if (!cancelled.load(.acquire)) permits -= 1;
}

fn Spec(comptime label: []const u8) type {
    return struct {
        pub const name = label;
        pub const State = struct { total: u8 = 0, cancelled: std.atomic.Value(bool) = .init(false) };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, controller: *ecl.Controller) void {
            if (block_open.swap(false, .acq_rel)) awaitGate(&state.cancelled);
            if (fail_open.swap(false, .acq_rel)) controller.fail(.domain, "deliberate initialization failure");
        }
        pub fn run(state: *State, code: u32, controller: *ecl.Controller) void {
            if (code == 4) {
                controller.fail(.io, ("x" ** 4095) ++ "€");
                return;
            }
            if (code == 2) {
                controller.fail(.domain, "deliberate operation failure");
                return;
            }
            if (code == 3) {
                awaitGate(&state.cancelled);
                if (controller.cancelled()) return;
                state.total +%= 1;
            }
            var bytes: [64]u8 = undefined;
            while (true) {
                const count = controller.read(&bytes);
                if (count == 0) break;
                for (bytes[0..count]) |byte| state.total +%= byte;
                if (code == 0) {
                    var sent: usize = 0;
                    while (sent < count) {
                        const written = controller.write(bytes[sent..count]);
                        if (written == 0) return;
                        sent += written;
                    }
                }
            }
            if (code == 1 or code == 3) _ = controller.write(&.{state.total});
        }
        pub fn cancel(state: *State) void {
            std.Io.Threaded.mutexLock(&gate_mutex);
            state.cancelled.store(true, .release);
            gate_changed.broadcast(fixtureIo());
            std.Io.Threaded.mutexUnlock(&gate_mutex);
        }
        pub fn deinit(_: *State) void {
            _ = cleaned.fetchAdd(1, .release);
        }
    };
}
const Counter = ecl.Port(Spec("counter"));
const Other = ecl.Port(Spec("other"));
fn DuplexSpec(comptime acknowledge: bool) type {
    return struct {
        const Base = Spec("lane");
        pub const name = if (acknowledge) "duplex" else "unacknowledged";
        pub const Lane = enum { receive, send };
        pub const cancellation: ecl.PortCancellation = .acknowledge;
        pub const State = struct { lanes: [2]Base.State = .{Base.State{}} ** 2 };
        pub fn init() State {
            return .{};
        }
        pub fn lane(code: u32) Lane {
            return if (code == 1 or code == 5) .send else .receive;
        }
        pub fn open(_: *State, _: *ecl.Controller) void {}
        pub fn run(state: *State, code: u32, controller: *ecl.Controller) void {
            const current = &state.lanes[@intFromEnum(lane(code))];
            Base.run(current, if (code == 5) 3 else code, controller);
            if (acknowledge and controller.cancelled()) {
                current.cancelled.store(false, .release);
                _ = controller.acknowledgeCancellation();
            }
        }
        pub fn cancelOperation(state: *State, selected: Lane) void {
            Base.cancel(&state.lanes[@intFromEnum(selected)]);
        }
        pub fn cancel(state: *State) void {
            for (&state.lanes) |*current| Base.cancel(current);
        }
        pub fn deinit(_: *State) void {
            _ = cleaned.fetchAdd(1, .release);
        }
    };
}
const Duplex = ecl.Port(DuplexSpec(true));
const Unacknowledged = ecl.Port(DuplexSpec(false));

fn createDuplex(call: *ecl.Call("-- port"), _: *Schedule, port: *Duplex) ecl.CallbackResult {
    return createPort(call, port);
}
fn createUnacknowledged(call: *ecl.Call("-- port"), _: *Schedule, port: *Unacknowledged) ecl.CallbackResult {
    return createPort(call, port);
}
fn createPort(call: *ecl.Call("-- port"), port: anytype) ecl.CallbackResult {
    return switch (try port.create(0)) {
        .candidate => |candidate| call.complete(.{candidate}),
        .pending => blk: {
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        else => .fail,
    };
}
fn closeDuplex(call: *ecl.Call("port --"), _: *Schedule, port: *Duplex) ecl.CallbackResult {
    return closePort(call, port);
}
fn closeUnacknowledged(call: *ecl.Call("port --"), _: *Schedule, port: *Unacknowledged) ecl.CallbackResult {
    return closePort(call, port);
}
fn closePort(call: *ecl.Call("port --"), port: anytype) ecl.CallbackResult {
    return switch (try port.close(0, try call.forward(0))) {
        .ready => call.complete(.{}),
        .pending => blk: {
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        else => .fail,
    };
}
fn exchangeDuplex(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: *Duplex) ecl.CallbackResult {
    return exchangeBody(call, schedule, port, true);
}
fn exchangeUnacknowledged(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: *Unacknowledged) ecl.CallbackResult {
    return exchangeBody(call, schedule, port, true);
}

const Continuation = struct {
    pub const State = struct { admitted: bool = false, admission_wait: bool = false, finished: bool = false, terminal_wait: bool = false, sent: u64 = 0, received: u64 = 0, sum: i64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn deinit(_: *State) void {}
};
const Schedule = ecl.Reschedule(Continuation);
fn create(call: *ecl.Call("-- port"), _: *Schedule, port: *Counter) ecl.CallbackResult {
    return switch (try port.create(0)) {
        .candidate => |candidate| call.complete(.{candidate}),
        .pending => blk: {
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        else => .fail,
    };
}
fn createOther(call: *ecl.Call("-- port"), _: *Schedule, port: *Other) ecl.CallbackResult {
    return switch (try port.create(0)) {
        .candidate => |candidate| call.complete(.{candidate}),
        .pending => blk: {
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        else => .fail,
    };
}
// Always register exactly one readiness wait, after initialization is ready.
// This also gives allocation sweeps stable ordinals independent of controller
// scheduling, while exercising completion before registration.
fn createReadyWait(call: *ecl.Call("-- port"), schedule: *Schedule, port: *Counter) ecl.CallbackResult {
    return createReadyWaitBody(call, schedule, port);
}
fn createDuplexReadyWait(call: *ecl.Call("-- port"), schedule: *Schedule, port: *Duplex) ecl.CallbackResult {
    return createReadyWaitBody(call, schedule, port);
}
fn createReadyWaitBody(call: *ecl.Call("-- port"), schedule: *Schedule, port: anytype) ecl.CallbackResult {
    return switch (try port.create(0)) {
        .candidate => |candidate| blk: {
            if (schedule.state().terminal_wait) break :blk call.complete(.{candidate});
            schedule.state().terminal_wait = true;
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        .pending => schedule.yield(),
        else => .fail,
    };
}
fn close(call: *ecl.Call("port --"), _: *Schedule, port: *Counter) ecl.CallbackResult {
    return switch (try port.close(0, try call.forward(0))) {
        .ready => call.complete(.{}),
        .pending => blk: {
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        else => .fail,
    };
}
fn checkOther(call: *ecl.Call("port --"), _: *Schedule, port: *Other) ecl.CallbackResult {
    return switch (try port.check(try call.forward(0))) {
        .ready => call.complete(.{}),
        .pending => .yield,
        else => .fail,
    };
}
fn cleanupCount(call: *ecl.Call("-- n")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(cleaned.load(.acquire))});
}
fn failLong(call: *ecl.Call("--")) ecl.CallbackResult {
    return call.fail(.io, ("x" ** 4095) ++ "€");
}
fn unblock(call: *ecl.Call("--")) ecl.CallbackResult {
    std.Io.Threaded.mutexLock(&gate_mutex);
    permits += 1;
    gate_changed.broadcast(fixtureIo());
    std.Io.Threaded.mutexUnlock(&gate_mutex);
    return call.complete(.{});
}
fn reset(call: *ecl.Call("--")) ecl.CallbackResult {
    cleaned.store(0, .release);
    entered.store(0, .release);
    admitted.store(0, .release);
    waiting.store(0, .release);
    fail_open.store(false, .release);
    block_open.store(false, .release);
    std.Io.Threaded.mutexLock(&gate_mutex);
    permits = 0;
    std.Io.Threaded.mutexUnlock(&gate_mutex);
    return call.complete(.{});
}
fn failNext(call: *ecl.Call("--")) ecl.CallbackResult {
    fail_open.store(true, .release);
    return call.complete(.{});
}
fn blockNext(call: *ecl.Call("--")) ecl.CallbackResult {
    block_open.store(true, .release);
    return call.complete(.{});
}
fn awaitCounter(comptime counter: *std.atomic.Value(u32)) type {
    return struct {
        fn run(call: *ecl.Call("n --"), schedule: *Schedule) ecl.CallbackResult {
            const n = call.input(0).int() orelse return call.fail(.type, "expected counter target");
            if (n < 0) return call.fail(.domain, "negative counter target");
            if (counter.load(.acquire) >= n) return call.complete(.{});
            return schedule.yield();
        }
    };
}
fn createFailure(call: *ecl.Call("--"), _: *Schedule, port: *Counter) ecl.CallbackResult {
    return switch (try port.create(0)) {
        .candidate => call.fail(.user, "deliberate publication rollback"),
        .pending => blk: {
            _ = try port.wait(0, .{});
            break :blk .yield;
        },
        else => .fail,
    };
}
fn pair(call: *ecl.Call("-- left right"), _: *Schedule, port: *Counter) ecl.CallbackResult {
    var candidates: [2]ecl.Candidate = undefined;
    for (&candidates, 0..) |*candidate, index| switch (try port.create(@intCast(index))) {
        .candidate => |item| candidate.* = item,
        .pending => {
            _ = try port.wait(@intCast(index), .{});
            return .yield;
        },
        else => return .fail,
    };
    return call.complete(.{ candidates[0], candidates[1] });
}
// Sends repeated bytes while draining the response. The scalar result makes
// large streaming tests independent of aggregate builder storage.
fn exchange(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: *Counter) ecl.CallbackResult {
    return exchangeBody(call, schedule, port, true);
}
fn exchangeDuplexReadyWait(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: *Duplex) ecl.CallbackResult {
    return exchangeBody(call, schedule, port, false);
}
fn exchangeReadyWait(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: *Counter) ecl.CallbackResult {
    return exchangeBody(call, schedule, port, false);
}
fn exchangeBody(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: anytype, comptime park_pending: bool) ecl.CallbackResult {
    const code = call.input(1).int() orelse return call.fail(.type, "expected opcode");
    const count = call.input(2).int() orelse return call.fail(.type, "expected count");
    if (code < 0 or code > 5 or count < 0) return call.fail(.domain, "invalid operation");
    const state = schedule.state();
    if (!state.admitted) switch (try port.begin(0, try call.forward(0), @intCast(code))) {
        .ready => {
            state.admitted = true;
            _ = admitted.fetchAdd(1, .release);
        },
        .pending => {
            if (!state.admission_wait) {
                state.admission_wait = true;
                _ = waiting.fetchAdd(1, .release);
            }
            if (park_pending) {
                _ = try port.wait(0, .{});
                return .yield;
            }
            return schedule.yield();
        },
        else => return .fail,
    };
    while (schedule.consume(1)) {
        var progress = false;
        if (state.sent < count) {
            const bytes = [_]u8{1} ** 64;
            switch (try port.write(0, bytes[0..@intCast(@min(64, @as(u64, @intCast(count)) - state.sent))])) {
                .bytes => |n| {
                    state.sent += n;
                    progress = n != 0;
                },
                .pending => {},
                else => return .fail,
            }
        } else if (!state.finished) switch (try port.finishRequest(0)) {
            .ready => {
                state.finished = true;
                progress = true;
            },
            .pending => {},
            else => return .fail,
        };
        var bytes: [64]u8 = undefined;
        switch (try port.read(0, &bytes)) {
            .bytes => |n| {
                for (bytes[0..n]) |byte| state.sum += byte;
                state.received += n;
                progress = progress or n != 0;
            },
            .pending => {},
            else => return .fail,
        }
        const expected: u64 = if (code == 0) @intCast(count) else if (code == 1 or code == 3 or code == 5) 1 else 0;
        if (state.finished and state.received == expected) switch (try port.result(0)) {
            .ready => {
                if (!park_pending and !state.terminal_wait) {
                    state.terminal_wait = true;
                    _ = try port.wait(0, .{ .readable = false, .writable = false });
                    return .yield;
                }
                return call.complete(.{ecl.Scalar.int(state.sum)});
            },
            .pending => {},
            else => return .fail,
        };
        if (!progress) {
            if (park_pending) {
                _ = try port.wait(0, .{ .writable = !state.finished });
                return .yield;
            }
            return schedule.yield();
        }
    }
    return schedule.yield();
}
pub const Extension = ecl.module(.{
    .name = @import("port_fixture_options").module_name,
    .doc = "Hermetic native port controller fixture.",
    .ports = .{ Counter, Other, Duplex, Unacknowledged },
    .words = .{
        ecl.word("duplex-new-ready-wait", "Create lanes with deterministic wait allocation.", createDuplexReadyWait),
        ecl.word("duplex-exchange-ready-wait", "Exercise deterministic lane admission and wait allocation.", exchangeDuplexReadyWait),
        ecl.word("duplex-new", "Create a port with independently progressing lanes.", createDuplex),
        ecl.word("duplex-exchange", "Exchange on an operation-selected lane.", exchangeDuplex),
        ecl.word("duplex-close", "Join every lane and cleanup.", closeDuplex),
        ecl.word("unacknowledged-new", "Create a port that declines cancellation recovery.", createUnacknowledged),
        ecl.word("unacknowledged-exchange", "Exchange without acknowledging cancellation.", exchangeUnacknowledged),
        ecl.word("unacknowledged-close", "Join unrecoverable cancellation cleanup.", closeUnacknowledged),
        ecl.word("new", "Create a counter port.", create),
        ecl.word("other-new", "Create the other declared port kind.", createOther),
        ecl.word("new-ready-wait", "Observe initialization completed before wait registration.", createReadyWait),
        ecl.word("new-fail", "Fail before publication commits.", createFailure),
        ecl.word("pair", "Create two ports transactionally.", pair),
        ecl.word("fail-next", "Fail the next initialization.", failNext),
        ecl.word("block-next", "Block the next initialization.", blockNext),
        ecl.word("unblock", "Release one blocked controller.", unblock),
        ecl.word("reset", "Reset observations between isolated fixture runs.", reset),
        ecl.word("await-blocked", "Wait for controller gate entries.", awaitCounter(&entered).run),
        ecl.word("await-admitted", "Wait for operation admissions.", awaitCounter(&admitted).run),
        ecl.word("await-waiting", "Wait for admission pressure.", awaitCounter(&waiting).run),
        ecl.word("await-cleaned", "Wait for cleanup callbacks.", awaitCounter(&cleaned).run),
        ecl.word("close", "Join port cleanup.", close),
        ecl.word("other-check", "Require the other kind.", checkOther),
        ecl.word("cleaned", "Observe completed cleanup.", cleanupCount),
        ecl.word("fail-long", "Report a bounded UTF-8 word error.", failLong),
        ecl.word("exchange", "Stream repeated bytes and return a checksum.", exchange),
        ecl.word("exchange-ready-wait", "Observe operation completion before wait registration.", exchangeReadyWait),
    },
});
comptime {
    _ = Extension;
}
