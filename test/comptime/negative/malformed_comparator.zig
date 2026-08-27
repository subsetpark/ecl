const std = @import("std");
const poll = @import("ecl-poll");

const Comparator = struct {
    pub const Context = void;
    pub const Cursor = struct {};

    pub fn init(_: Context, _: u8, _: u8) Cursor {
        return .{};
    }

    pub fn advance(_: *const Cursor, _: usize) poll.Progress(std.math.Order) {
        return .{ .complete = .eq };
    }
};

const Sort = poll.MergeSortCursor(u8, Comparator);

export fn contract() usize {
    return @sizeOf(Sort);
}
