//! Scheduler-backed clock words.
//!
//! `now`, `elapsed`, and `sleep` read the one monotonic clock the scheduler
//! owns, so a program's instants, its sleeps, and every `await-for` deadline
//! agree on what time it is — including under a host-driven manual clock.
//! `unix` is the separate wall-clock grant: absent unless the Session host
//! supplied one, and never implied by host I/O or TLS verification time.
//! Instants are `{'monotonic ms}` and wall timestamps are `{'unix ms}`; the
//! pure conversions over the latter live in `time`.
const std = @import("std");
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");
const scheduler_api = @import("../scheduler.zig");
const time = @import("time.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    .{ .name = "elapsed", .doc = "( instant -- milliseconds ) Return the monotonic milliseconds since an instant from `now`.", .primitive = elapsed },
    .{ .name = "now", .doc = "( -- instant ) Read the monotonic clock as {'monotonic milliseconds} since the Session started.", .primitive = now },
    .{ .name = "sleep", .doc = "( milliseconds -- ) Park the calling unit for a nonnegative duration without holding a worker; cancellable.", .primitive = sleep },
    .{ .name = "unix", .doc = "( -- timestamp ) Read the host-granted wall clock as {'unix milliseconds}.", .primitive = unix },
};

fn scheduler(evaluator: *Machine) *const scheduler_api.WorkerScheduler {
    return @ptrCast(@alignCast(evaluator.unit.scheduler.?));
}

fn now(evaluator: *Machine) MachineError!void {
    const instant = scheduler(evaluator).monotonicMilliseconds();
    try evaluator.pushOwned(try time.tagged(evaluator, .monotonic, instant));
}

fn elapsed(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const start = (try time.untag(.monotonic, item.borrow())) orelse
        return evaluator.typeError("a {'monotonic milliseconds} instant from clock.now");
    const current = scheduler(evaluator).monotonicMilliseconds();
    const delta = std.math.sub(i64, current, start) catch
        return evaluator.fail(.overflow, "clock.elapsed left the millisecond range");
    try evaluator.pushOwned(.{ .int = delta });
}

fn unix(evaluator: *Machine) MachineError!void {
    const milliseconds: i64 = switch (evaluator.unit.inherited.wall_clock) {
        .absent => {
            const reason = try intern.intern("unavailable");
            const failure = evaluator.fail(.domain, "clock.unix has no wall-clock authority in this session");
            evaluator.addErrorReason(.{ .symbol = reason });
            return failure;
        },
        .host => |io| std.math.cast(i64, @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms)) orelse
            return evaluator.fail(.overflow, "clock.unix left the millisecond range"),
        .fixed => |timestamp| timestamp,
        .anchored => |base| std.math.add(i64, base, scheduler(evaluator).monotonicMilliseconds()) catch
            return evaluator.fail(.overflow, "clock.unix left the millisecond range"),
    };
    try evaluator.pushOwned(try time.tagged(evaluator, .unix, milliseconds));
}

fn sleep(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (item.borrow() != .int) return evaluator.typeError("an integer millisecond duration");
    if (item.borrow().int < 0) return evaluator.fail(.domain, "clock.sleep duration must be nonnegative");
    const duration: u63 = @intCast(item.borrow().int);
    // The clock only moves forward, so a deadline the clock cannot reach now
    // cannot be reached at registration either; refuse it before parking.
    scheduler(evaluator).checkDeadline(duration) catch
        return evaluator.fail(.overflow, "clock.sleep deadline lies beyond the clock's range");
    // The deadline itself is captured by the scheduler at registration, after
    // this primitive returns, and a zero duration is already expired there:
    // the unit parks and is woken on the next scheduler turn without a timer.
    try evaluator.park(.{ .sleep = duration });
}
