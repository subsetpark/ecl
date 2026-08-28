const std = @import("std");
const poll = @import("ecl-poll");

const Spec = struct {
    pub const Source = u8;
    pub const Builder = struct {};
    pub const Context = void;
    pub const Result = u8;

    pub fn begin(_: std.mem.Allocator, _: []const Source, _: Context) error{OutOfMemory}!Builder {
        return .{};
    }

    pub fn fill(_: *const Builder, _: []const Source, _: *usize, _: usize) void {}
};

const Materializer = poll.ExactMaterializer(Spec);

export fn contract() usize {
    return @sizeOf(Materializer);
}
