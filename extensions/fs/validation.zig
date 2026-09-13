//! Bounded value validation before resource-message marshalling.
const std = @import("std");
const ecl = @import("ecl-native");
pub fn isString(call: *ecl.Call("value -- bool")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(@intFromBool(call.input(0).isString()))});
}
const Scan = ecl.Reschedule(struct {
    pub const State = struct { index: u64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn deinit(_: *State) void {}
});
pub fn byteErrorIndex(call: *ecl.Call("values -- index"), schedule: *Scan) ecl.CallbackResult {
    const state = schedule.state();
    const cursor = call.listCursor(0, state.index) orelse return call.fail(.type, "expected a byte list to write");
    while (true) switch (cursor.next()) {
        .item => |item| {
            const number = item.int() orelse return call.complete(.{ecl.Scalar.int(@intCast(state.index))});
            if (number < 0 or number > 255) return call.complete(.{ecl.Scalar.int(@intCast(state.index))});
            state.index += 1;
        },
        .end => return call.complete(.{ecl.Scalar.int(std.math.cast(i64, state.index) orelse std.math.maxInt(i64))}),
        .yield_required => return schedule.yield(),
        .invalid => return call.fail(.contract, "filesystem byte validation cursor became invalid"),
    };
}
