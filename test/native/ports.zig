// zlint-disable homeless-try -- Zig validates the SDK callback error unions.
const std = @import("std");
const ecl = @import("ecl-native");
var shutdowns: std.atomic.Value(u32) = .init(0);
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
        pub const Lane = enum(u64) { receive, send };
        pub const cancellation: ecl.PortCancellation = .acknowledge;
        pub const State = struct { lanes: [2]Base.State = .{Base.State{}} ** 2 };
        pub fn init() State {
            return .{};
        }
        pub fn lane(code: u32) Lane {
            return if (code == 1 or code == 5) .send else .receive;
        }
        pub fn open(state: *State, controller: *ecl.Controller) void {
            const config = controller.input(&.{}) orelse return controller.fail(.domain, "missing configuration");
            if (config.int()) |number| {
                if (number == 255) return controller.failOutOfMemory();
                if (number < 0 or number > 255) return controller.fail(.domain, "invalid counter configuration");
                for (&state.lanes) |*current| current.total = @intCast(number);
            } else if (config.length() != 0) controller.fail(.domain, "expected an initial counter or empty configuration");
        }
        pub fn run(state: *State, code: u32, controller: *ecl.Controller) void {
            const current = &state.lanes[@intFromEnum(lane(code))];
            if (code >= 18 and code <= 28) {
                defer if (acknowledge and controller.cancelled()) {
                    current.cancelled.store(false, .release);
                    _ = controller.acknowledgeCancellation();
                };
                if (code == 23) {
                    _ = entered.fetchAdd(1, .release);
                    while (controller.receiveResourceMessage(3)) if (!controller.forwardResourceMessage(4)) return;
                    if (!controller.cancelled()) _ = controller.finishResourceOutput(4);
                    return;
                }
                if (code == 24) {
                    _ = entered.fetchAdd(1, .release);
                    var bytes: [8]u8 = undefined;
                    while (true) {
                        const count = controller.readResourceFrom(0, &bytes);
                        if (count == 0) break;
                        var sent: usize = 0;
                        while (sent < count) {
                            const wrote = controller.writeResourceTo(1, bytes[sent..count]);
                            if (wrote == 0) return;
                            sent += wrote;
                        }
                    }
                    if (!controller.cancelled()) _ = controller.finishResourceOutput(1);
                    return;
                }
                const builder = controller.builder();
                if (code == 26) {
                    for (1..3) |id| {
                        if (!builder.symbol("id") or !builder.int(@intCast(id)) or !builder.symbol("reply") or
                            !builder.replyEndpoint(3) or !builder.dictionary(2) or !builder.send(4)) return;
                        if (id == 1 and (!builder.symbol("notification") or !builder.int(7) or !builder.dictionary(1) or !builder.send(4))) return;
                    }
                    for (0..2) |index| {
                        if (!controller.receiveMessage(3)) return;
                        const id = (controller.received(&.{0}) orelse return).int() orelse return;
                        const value = (controller.received(&.{1}) orelse return).int() orelse return;
                        if (id != 2 - @as(i64, @intCast(index)) or value != id * 10)
                            return controller.fail(.domain, "RPC reply correlation failed");
                        if (!controller.forwardMessage(4)) return;
                    }
                    _ = builder.int(42) and builder.result();
                    return;
                }
                if (code == 27) {
                    _ = builder.replyEndpoint(4);
                    return;
                }
                if (code == 28) {
                    _ = builder.replyEndpoint(3) and builder.result();
                    return;
                }
                if (code == 25) {
                    _ = builder.int(42) and builder.sendResource(4);
                    return;
                }
                if (code == 18) {
                    for (0..8) |index| if (!builder.int(@intCast(index)) or !builder.send(4)) return;
                    return;
                }
                if (code == 19) {
                    if (!builder.symbol("payload") or !builder.float(0.5) or !builder.char(0x03bb) or
                        !builder.int(42) or !builder.symbol("tag") or !builder.input(&.{0}) or
                        !builder.list(5) or !builder.dictionary(1) or !builder.result()) return;
                    return;
                }
                if (code == 20) {
                    if (!builder.symbol("key") or !builder.int(1) or !builder.symbol("key") or !builder.int(2)) return;
                    _ = builder.dictionary(2);
                    return;
                }
                if (code == 21) {
                    if (!builder.symbol("x" ** (64 * 1024))) return;
                    _ = builder.int(1);
                    _ = builder.send(4); // Failed construction cannot publish a partial root.
                    return;
                }
                if (!controller.receiveMessage(3)) return;
                if (!builder.symbol("discarded") or !builder.clear() or !builder.symbol("copy") or
                    !builder.received(&.{0}) or !builder.dictionary(1) or !builder.send(4) or
                    !builder.list(0) or !builder.send(4) or !builder.dictionary(0) or !builder.result()) return;
                return;
            }
            if (code >= 14 and code <= 16) {
                defer if (acknowledge and controller.cancelled()) {
                    current.cancelled.store(false, .release);
                    _ = controller.acknowledgeCancellation();
                };
                while (controller.receiveMessage(3)) {
                    if (controller.received(&.{}) == null) return controller.fail(.domain, "missing received message view");
                    if (code == 15) {
                        if (!controller.resultMessage()) controller.fail(.domain, "result publication failed");
                        return;
                    }
                    if (!controller.forwardMessage(4)) return;
                    if (code == 16) return controller.fail(.domain, "failure after buffered message");
                }
                return;
            }
            if (code == 17) {
                controller.failOutOfMemory();
                controller.fail(.domain, "must not mask allocation exhaustion");
                return;
            }
            if (code == 8) return;
            if (code == 10 or code == 11) {
                _ = controller.writeTo(1, &.{ 4, 5, 6 });
                if (code == 11) _ = controller.finishOutput(1);
                controller.fail(.domain, "failure after buffered output");
                return;
            }
            if (code == 12) {
                var buffer: [64]u8 = undefined;
                while (true) {
                    const count = controller.readFrom(0, &buffer);
                    if (count == 0) return;
                    var sent: usize = 0;
                    while (sent < count) {
                        const n = controller.writeTo(1, buffer[sent..count]);
                        if (n == 0) return;
                        sent += n;
                    }
                    for (buffer[0..count]) |*byte| byte.* ^= 255;
                    sent = 0;
                    while (sent < count) {
                        const n = controller.writeTo(2, buffer[sent..count]);
                        if (n == 0) return;
                        sent += n;
                    }
                }
            }
            if (code == 13) {
                var byte: [1]u8 = undefined;
                if (controller.readFrom(0, &byte) != 0) _ = controller.writeTo(1, &byte);
                return;
            }
            if (code == 6) {
                if (current.total != 7 or !checkParameters(controller)) controller.fail(.domain, "structured parameters were not preserved");
                return;
            }
            Base.run(current, if (code == 5) 3 else code, controller);
            if (acknowledge and controller.cancelled()) {
                current.cancelled.store(false, .release);
                _ = controller.acknowledgeCancellation();
            }
        }
        pub fn shutdown(state: *State, controller: *ecl.Controller) void {
            _ = shutdowns.fetchAdd(1, .release);
            const config = (controller.input(&.{}) orelse return).int() orelse 0;
            if (config == 252) return controller.failOutOfMemory();
            if (config == 254) return controller.fail(.domain, "deliberate shutdown failure");
            if (config == 253) awaitGate(&state.lanes[0].cancelled);
            // Completing the graceful callback permits the runtime to close
            // remaining exchanges and join their cancellation return.
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
fn checkParameters(controller: *ecl.Controller) bool {
    if ((controller.input(&.{}) orelse return false).length() != 7) return false;
    if ((controller.input(&.{0}) orelse return false).int() != 42) return false;
    if ((controller.input(&.{1}) orelse return false).float() != 0.5) return false;
    if ((controller.input(&.{2}) orelse return false).char() != 'a') return false;
    if (!std.mem.eql(u8, (controller.input(&.{3}) orelse return false).symbol() orelse return false, "tag")) return false;
    if ((controller.input(&.{ 4, 0 }) orelse return false).int() != 7) return false;
    if (!std.mem.eql(u8, (controller.input(&.{ 5, 0 }) orelse return false).symbol() orelse return false, "key")) return false;
    if ((controller.input(&.{ 5, 1 }) orelse return false).int() != 9) return false;
    if ((controller.input(&.{6}) orelse return false).kind() != .port) return false;
    return controller.input(&.{7}) == null;
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
fn startExchange(call: *ecl.Call("port code -- exchange"), _: *Schedule, port: *Duplex) ecl.CallbackResult {
    const code = call.input(1).int() orelse return call.fail(.type, "expected operation code");
    if (code < 0 or code > 5) return call.fail(.domain, "unknown operation");
    switch (try port.begin(0, try call.forward(0), @intCast(code))) {
        .pending => {
            _ = try port.wait(0, .{});
            return .yield;
        },
        .ready => {},
        else => return .fail,
    }
    _ = try port.finishRequest(0);
    return switch (try port.exportExchange(0)) {
        .candidate => |exchange_value| call.complete(.{exchange_value}),
        .pending => .yield,
        else => .fail,
    };
}
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
fn shutdownCount(call: *ecl.Call("-- n")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(shutdowns.load(.acquire))});
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
    shutdowns.store(0, .release);
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
pub const Extension = extension: {
    @setEvalBranchQuota(20_000);
    break :extension ecl.module(.{
        .name = @import("port_fixture_options").module_name,
        .doc = "Hermetic native port controller fixture.",
        .ports = .{ Counter, Other, Duplex, Unacknowledged },
        .words = .{
            ecl.factory("factory", "Create an independently scheduled duplex resource.", Duplex),
            ecl.operation("echo", "Echo accepted input bytes.", Duplex, 0, .receive, 3),
            ecl.operation("checksum", "Sum accepted input bytes.", Duplex, 1, .send, 3),
            ecl.operation("failure", "Fail with a deterministic terminal error.", Duplex, 2, .receive, 0),
            ecl.operation("inspect", "Validate structured parameters without additional streaming.", Duplex, 6, .receive, 0),
            ecl.operation("allocation-failure", "Report asynchronous allocation exhaustion.", Duplex, 17, .receive, 26),
            ecl.operation("noop", "Complete without additional streaming.", Duplex, 8, .receive, 0),
            ecl.operation("buffered-failure", "Fail after accepting output bytes.", Duplex, 10, .receive, 2),
            ecl.operation("finished-failure", "Fail after finishing the output endpoint.", Duplex, 11, .receive, 2),
            ecl.operation("pipeline", "Stream input, output, and independent diagnostics.", Duplex, 12, .receive, 7),
            ecl.operation("early-exit", "Stop consuming input after one byte.", Duplex, 13, .receive, 3),
            ecl.operation("resource-messages", "Forward through resource-owned message channels.", Duplex, 23, .receive, 0),
            ecl.operation("resource-bytes", "Forward through resource-owned byte streams.", Duplex, 24, .receive, 0),
            ecl.operation("resource-notify", "Produce a resource event independently of exchange output.", Duplex, 25, .receive, 0),
            ecl.operation("rpc", "Request ECL replies through opaque sender endpoints.", Duplex, 26, .receive, 24),
            ecl.operation("invalid-reply", "Reject reply authority for an output endpoint.", Duplex, 27, .receive, 16),
            ecl.operation("reply-result", "Return a retained endpoint after completion.", Duplex, 28, .receive, 8),
            ecl.operation("events", "Produce unsolicited structured events under pressure.", Duplex, 18, .receive, 16),
            ecl.operation("build-result", "Construct a nested structured result with a capability.", Duplex, 19, .receive, 0),
            ecl.operation("duplicate-result", "Reject duplicate structured keys.", Duplex, 20, .receive, 0),
            ecl.operation("oversize-event", "Reject oversize construction before output.", Duplex, 21, .receive, 16),
            ecl.operation("build-received", "Copy received values and construct empty aggregates.", Duplex, 22, .receive, 24),
            ecl.operation("messages", "Forward complete structured messages.", Duplex, 14, .receive, 24),
            ecl.operation("message-result", "Return one structured message as the terminal result.", Duplex, 15, .receive, 8),
            ecl.operation("message-failure", "Fail after accepting one output message.", Duplex, 16, .receive, 24),
            ecl.operation("blocked", "Wait for an explicit controller gate.", Duplex, 3, .receive, 3),
            ecl.endpoint("resource-input", "Resource byte input.", Duplex, .{ .id = 0, .transport = .bytes, .direction = .input, .owner = .resource }),
            ecl.endpoint("resource-output", "Resource byte output.", Duplex, .{ .id = 1, .transport = .bytes, .direction = .output, .owner = .resource }),
            ecl.endpoint("resource-sender", "Resource structured input.", Duplex, .{ .id = 3, .transport = .messages, .direction = .input, .owner = .resource }),
            ecl.endpoint("resource-receiver", "Resource structured output.", Duplex, .{ .id = 4, .transport = .messages, .direction = .output, .owner = .resource }),
            ecl.endpoint("input", "Exchange byte input.", Duplex, .{ .id = 0, .transport = .bytes, .direction = .input }),
            ecl.endpoint("output", "Exchange byte output.", Duplex, .{ .id = 1, .transport = .bytes, .direction = .output }),
            ecl.endpoint("diagnostics", "Independent pipeline diagnostic bytes.", Duplex, .{ .id = 2, .transport = .bytes, .direction = .output }),
            ecl.endpoint("sender", "Structured message input.", Duplex, .{ .id = 3, .transport = .messages, .direction = .input }),
            ecl.endpoint("receiver", "Structured message output.", Duplex, .{ .id = 4, .transport = .messages, .direction = .output }),
            ecl.word("duplex-new-ready-wait", "Create lanes with deterministic wait allocation.", createDuplexReadyWait),
            ecl.word("duplex-exchange-ready-wait", "Exercise deterministic lane admission and wait allocation.", exchangeDuplexReadyWait),
            ecl.word("duplex-new", "Create a port with independently progressing lanes.", createDuplex),
            ecl.word("duplex-exchange", "Exchange on an operation-selected lane.", exchangeDuplex),
            ecl.word("duplex-close", "Join every lane and cleanup.", closeDuplex),
            ecl.word("unacknowledged-new", "Create a port that declines cancellation recovery.", createUnacknowledged),
            ecl.word("unacknowledged-exchange", "Exchange without acknowledging cancellation.", exchangeUnacknowledged),
            ecl.word("unacknowledged-close", "Join unrecoverable cancellation cleanup.", closeUnacknowledged),
            ecl.word("new", "Create a counter port.", create),
            ecl.word("start", "Return a scope-owned duplex exchange independently of its native call.", startExchange),
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
            ecl.word("shutdowns", "Observe graceful callbacks.", shutdownCount),
            ecl.word("cleaned", "Observe completed cleanup.", cleanupCount),
            ecl.word("fail-long", "Report a bounded UTF-8 word error.", failLong),
            ecl.word("exchange", "Stream repeated bytes and return a checksum.", exchange),
            ecl.word("exchange-ready-wait", "Observe operation completion before wait registration.", exchangeReadyWait),
        },
    });
};
comptime {
    _ = Extension;
}
