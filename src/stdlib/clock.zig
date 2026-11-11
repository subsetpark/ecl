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

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const Value = value.Value;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Scheduler-backed time. `now`, `elapsed`, and `sleep` read the one monotonic clock the
    \\Session's scheduler owns, so a program's instants, its sleeps, and every `task.await-for`
    \\deadline agree on the current time. `unix` reads the process realtime clock, which is always
    \\available to CLI programs.
    \\
    \\Every quantity is a whole number of milliseconds. A monotonic instant is the one-key
    \\dictionary `{monotonic ms}` counting from Session construction; a wall timestamp is `{unix
    \\ms}` counting from 1970-01-01T00:00:00Z. The tag is the clock domain: an instant handed to a
    \\`time` word, or a timestamp handed to `elapsed`, is `` `type ``. Monotonic instants are not
    \\portable across Sessions and carry no date; wall time may jump and is not suitable for
    \\scheduling.
;

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
fn tagged(fiber: *Fiber, domain: Domain, milliseconds: i64) error{OutOfMemory}!Value {
    const key = try intern.intern(@tagName(domain));
    return dict.fromUniquePairs(fiber.allocator, fiber.releases, &.{
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

fn now(fiber: *Fiber) MachineError!void {
    const instant = fiber.scheduler.?.monotonicMilliseconds();
    try fiber.pushOwned(try tagged(fiber, .monotonic, instant));
}

fn elapsed(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const start = (try untag(.monotonic, item.borrow())) orelse
        return fiber.typeError("a {monotonic milliseconds} instant from clock.now");
    const current = fiber.scheduler.?.monotonicMilliseconds();
    const delta = std.math.sub(i64, current, start) catch
        return fiber.fail(.overflow, "clock.elapsed left the millisecond range");
    try fiber.pushOwned(.{ .int = delta });
}

fn unix(fiber: *Fiber) MachineError!void {
    const milliseconds: i64 = switch (fiber.inherited.runtime().wall_clock) {
        .host => |io| std.math.cast(i64, @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms)) orelse
            return fiber.fail(.overflow, "clock.unix left the millisecond range"),
        .fixed => |timestamp| timestamp,
        .anchored => |base| std.math.add(i64, base, fiber.scheduler.?.monotonicMilliseconds()) catch
            return fiber.fail(.overflow, "clock.unix left the millisecond range"),
    };
    try fiber.pushOwned(try tagged(fiber, .unix, milliseconds));
}

fn sleep(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    if (item.borrow() != .int) return fiber.typeError("an integer millisecond duration");
    if (item.borrow().int < 0) return fiber.fail(.domain, "clock.sleep duration must be nonnegative");
    const duration: u63 = @intCast(item.borrow().int);
    // The clock only moves forward, so a deadline the clock cannot reach now
    // cannot be reached at registration either; refuse it before parking.
    fiber.scheduler.?.checkDeadline(duration) catch
        return fiber.fail(.overflow, "clock.sleep deadline lies beyond the clock's range");
    // The deadline itself is captured by the scheduler at registration, after
    // this primitive returns, and a zero duration is already expired there:
    // the fiber parks and is woken on the next scheduler turn without a timer.
    try fiber.park(.{ .sleep = duration });
}
