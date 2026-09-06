// zlint-disable homeless-try -- Zig validates the SDK callback error unions.
const std = @import("std");
const ecl = @import("ecl-native");
var cleaned: std.atomic.Value(u32) = .init(0);

fn Spec(comptime label: []const u8) type {
    return struct {
        pub const name = label;
        pub const State = struct { total: u8 = 0 };
        pub fn init() State {
            return .{};
        }
        pub fn open(_: *State, _: *ecl.Controller) void {}
        pub fn run(state: *State, code: u32, controller: *ecl.Controller) void {
            if (code == 2) {
                controller.fail(.domain, "deliberate operation failure");
                return;
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
            if (code == 1) _ = controller.write(&.{state.total});
        }
        pub fn cancel(_: *State) void {}
        pub fn deinit(_: *State) void {
            _ = cleaned.fetchAdd(1, .release);
        }
    };
}
const Counter = ecl.Port(Spec("counter"));
const Other = ecl.Port(Spec("other"));
const Continuation = struct {
    pub const State = struct { admitted: bool = false, finished: bool = false, sent: u64 = 0, received: u64 = 0, sum: i64 = 0 };
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
// Sends repeated bytes while draining the response. The scalar result makes
// large streaming tests independent of aggregate builder storage.
fn exchange(call: *ecl.Call("port code count -- checksum"), schedule: *Schedule, port: *Counter) ecl.CallbackResult {
    const code = call.input(1).int() orelse return call.fail(.type, "expected opcode");
    const count = call.input(2).int() orelse return call.fail(.type, "expected count");
    if (code < 0 or code > 2 or count < 0) return call.fail(.domain, "invalid operation");
    const state = schedule.state();
    if (!state.admitted) switch (try port.begin(0, try call.forward(0), @intCast(code))) {
        .ready => state.admitted = true,
        .pending => {
            _ = try port.wait(0, .{});
            return .yield;
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
        const expected: u64 = if (code == 0) @intCast(count) else if (code == 1) 1 else 0;
        if (state.finished and state.received == expected) switch (try port.result(0)) {
            .ready => return call.complete(.{ecl.Scalar.int(state.sum)}),
            .pending => {},
            else => return .fail,
        };
        if (!progress) {
            _ = try port.wait(0, .{ .writable = !state.finished });
            return .yield;
        }
    }
    return schedule.yield();
}
pub const Extension = ecl.module(.{
    .name = @import("port_fixture_options").module_name,
    .doc = "Hermetic native port controller fixture.",
    .ports = .{ Counter, Other },
    .words = .{
        ecl.word("new", "Create a counter port.", create),
        ecl.word("close", "Join port cleanup.", close),
        ecl.word("other-check", "Require the other kind.", checkOther),
        ecl.word("cleaned", "Observe completed cleanup.", cleanupCount),
        ecl.word("exchange", "Stream repeated bytes and return a checksum.", exchange),
    },
});
comptime {
    _ = Extension;
}
