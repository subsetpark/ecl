const poll = @import("ecl-poll");

const Cursor = struct {
    pub fn advance(_: *Cursor) poll.Progress(u16) {
        return .{ .complete = 0 };
    }
};

export fn contract() u8 {
    var cursor = Cursor{};
    return poll.drive(u8, &cursor, .{});
}
