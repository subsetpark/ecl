//! Scheduler-backed clock words.
//!
//! `now`, `elapsed`, and `sleep` read the one monotonic clock the scheduler
//! owns, so a program's instants, its sleeps, and every `task.await-for` deadline
//! agree on what time it is — including under a host-driven manual clock.
//! `unix` reads realtime; fixed and anchored clocks are internal test inputs.
//! Instants are `{'monotonic ms}` and wall timestamps are `{'unix ms}`; the
//! pure conversions over the latter live in the ECL `time` module.
const std = @import("std");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");
const value = @import("../value.zig");

const Unit = machine.Unit;
const MachineError = machine.MachineError;
const Value = value.Value;

pub const words = [_]env.BuiltinWord{
    .{ .name = "elapsed", .effect = "instant -- milliseconds", .doc = "Monotonic milliseconds from an instant produced by `now` to the present. Anything but `{monotonic int}` is `` `type ``.", .primitive = elapsed },
    .{ .name = "now", .effect = "-- instant", .doc = "Read the monotonic clock as `{monotonic ms}`. Successive reads never decrease. The first read of a fresh Session is close to `{monotonic 0}`.", .primitive = now },
    .{ .name = "sleep", .effect = "milliseconds --", .doc = "Park the calling unit until the monotonic clock has advanced by a nonnegative int duration, then continue with nothing pushed. The unit holds no worker while parked; runnable work proceeds on a one-worker pool. The deadline is captured once, before any timer state is created, and a duration of `0` is already expired at that point: the unit yields to the scheduler and resumes on its next turn without starting the timer thread. Cancellation before or after registration wakes the unit with `` `cancelled `` and retires its timer entry. A negative duration is `` `domain ``, a non-int is `` `type ``, and a duration whose deadline lies beyond any instant the clock can report is `` `overflow ``; all three fail before anything is registered.", .primitive = sleep },
    .{ .name = "unix", .effect = "-- timestamp", .doc = "Read the process realtime clock as `{unix ms}`. Convert with the `time` module. Wall time can jump and must not be used for scheduling deadlines.", .primitive = unix },
};

/// The two clock domains a tagged value can name. The tag is the dictionary's
/// only key, so the two never compare equal and neither passes for the other.
const Domain = enum { unix, monotonic };

/// Build `{'<domain> milliseconds}`.
fn tagged(evaluator: *Unit, domain: Domain, milliseconds: i64) error{OutOfMemory}!Value {
    const key = try intern.intern(@tagName(domain));
    return dict.fromUniquePairs(evaluator.allocator, evaluator.releases, &.{
        .{ .{ .symbol = .{ .name = key } }, .{ .int = milliseconds } },
    });
}

/// Read `{'<domain> milliseconds}`. Anything else, including a well-formed
/// value from the other domain, is null; callers turn that into `'type`.
fn untag(domain: Domain, item: Value) error{OutOfMemory}!?i64 {
    if (item != .dict) return null;
    const header = item.dict;
    if (header.length() != 1) return null;
    const key = dict.keyAt(header, 0);
    if (key != .symbol or key.symbol.name != try intern.intern(@tagName(domain))) return null;
    const payload = dict.valueAt(header, 0);
    if (payload != .int) return null;
    return payload.int;
}

fn now(evaluator: *Unit) MachineError!void {
    const instant = evaluator.scheduler.?.monotonicMilliseconds();
    try evaluator.pushOwned(try tagged(evaluator, .monotonic, instant));
}

fn elapsed(evaluator: *Unit) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const start = (try untag(.monotonic, item.borrow())) orelse
        return evaluator.typeError("a {monotonic milliseconds} instant from clock.now");
    const current = evaluator.scheduler.?.monotonicMilliseconds();
    const delta = std.math.sub(i64, current, start) catch
        return evaluator.fail(.overflow, "clock.elapsed left the millisecond range");
    try evaluator.pushOwned(.{ .int = delta });
}

fn unix(evaluator: *Unit) MachineError!void {
    const milliseconds: i64 = switch (evaluator.inherited.runtime().wall_clock) {
        .host => |io| std.math.cast(i64, @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms)) orelse
            return evaluator.fail(.overflow, "clock.unix left the millisecond range"),
        .fixed => |timestamp| timestamp,
        .anchored => |base| std.math.add(i64, base, evaluator.scheduler.?.monotonicMilliseconds()) catch
            return evaluator.fail(.overflow, "clock.unix left the millisecond range"),
    };
    try evaluator.pushOwned(try tagged(evaluator, .unix, milliseconds));
}

fn sleep(evaluator: *Unit) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (item.borrow() != .int) return evaluator.typeError("an integer millisecond duration");
    if (item.borrow().int < 0) return evaluator.fail(.domain, "clock.sleep duration must be nonnegative");
    const duration: u63 = @intCast(item.borrow().int);
    // The clock only moves forward, so a deadline the clock cannot reach now
    // cannot be reached at registration either; refuse it before parking.
    evaluator.scheduler.?.checkDeadline(duration) catch
        return evaluator.fail(.overflow, "clock.sleep deadline lies beyond the clock's range");
    // The deadline itself is captured by the scheduler at registration, after
    // this primitive returns, and a zero duration is already expired there:
    // the unit parks and is woken on the next scheduler turn without a timer.
    try evaluator.park(.{ .sleep = duration });
}
