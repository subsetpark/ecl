//! Poll-aware ordering and output for interned reflection names.
const std = @import("std");
const intern = @import("intern.zig");
const poll = @import("poll.zig");
pub fn sortNames(names: []u32, poller: poll.Poller) poll.Error!void {
    if (names.len < 2) return;
    var start = names.len / 2;
    while (start > 0) {
        start -= 1;
        try siftDown(names, start, names.len, poller);
    }
    var end = names.len;
    while (end > 1) {
        end -= 1;
        try poller.poll();
        std.mem.swap(u32, &names[0], &names[end]);
        try siftDown(names, 0, end, poller);
    }
}
fn siftDown(names: []u32, start: usize, end: usize, poller: poll.Poller) poll.Error!void {
    var root = start;
    while (root * 2 + 1 < end) {
        const child = root * 2 + 1;
        const selected = if (child + 1 < end and
            try compareNames(names[child], names[child + 1], poller) == .lt)
            child + 1
        else
            child;
        if (try compareNames(names[root], names[selected], poller) != .lt) return;
        try poller.poll();
        std.mem.swap(u32, &names[root], &names[selected]);
        root = selected;
    }
}
fn compareNames(left: u32, right: u32, poller: poll.Poller) poll.Error!std.math.Order {
    if (left == right) {
        try poller.poll();
        return .eq;
    }
    const left_bytes = intern.get(left);
    const right_bytes = intern.get(right);
    for (0..@min(left_bytes.len, right_bytes.len)) |index| {
        try poller.poll();
        if (left_bytes[index] < right_bytes[index]) return .lt;
        if (left_bytes[index] > right_bytes[index]) return .gt;
    }
    try poller.poll();
    return std.math.order(left_bytes.len, right_bytes.len);
}
pub fn writeBytes(
    writer: *std.Io.Writer,
    bytes: []const u8,
    poller: poll.Poller,
) (poll.Error || std.Io.Writer.Error)!void {
    var chunks = poll.WorkContext.init(poller).chunks(bytes);
    while (try chunks.next()) |chunk| try writer.writeAll(chunk);
}
