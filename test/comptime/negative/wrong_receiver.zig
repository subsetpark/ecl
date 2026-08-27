const poll = @import("ecl-poll");

const Cursor = struct {
    pub fn advance(_: *const Cursor) poll.Progress(u8) {
        return .{ .complete = 0 };
    }
};

export fn contract() u8 {
    var cursor = Cursor{};
    return poll.drive(u8, &cursor, .{});
}
