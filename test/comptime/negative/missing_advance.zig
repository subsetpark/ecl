const poll = @import("ecl-poll");

const Cursor = struct {};

export fn contract() u8 {
    var cursor = Cursor{};
    return poll.drive(u8, &cursor, .{});
}
