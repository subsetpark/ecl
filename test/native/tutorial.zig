//! A complete port extension: one result operation and one byte stream.
const std = @import("std");
const ecl = @import("ecl-native");

const Counter = ecl.Port(struct {
    pub const name = "counter";
    pub const State = struct { total: i64 = 0 };
    pub const endpoints = .{
        .input = ecl.declarations.Endpoint{ .doc = "Write bytes to echo.", .transport = .bytes, .direction = .input },
        .output = ecl.declarations.Endpoint{ .doc = "Read echoed bytes.", .transport = .bytes, .direction = .output },
    };
    pub const operations = .{
        .increment = .{ .doc = "Add an integer and return the total.", .handler = increment, .lane = .operation, .endpoints = .{} },
        .echo = .{ .doc = "Echo bytes until input finishes.", .handler = echo, .lane = .operation, .endpoints = .{ .input, .output } },
    };

    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, controller: *ecl.Controller) void {
        const config = controller.input(&.{}) orelse return controller.fail(.domain, "configuration must be []");
        if (config.kind() != .list or config.length() != 0) controller.fail(.domain, "configuration must be []");
    }
    // Host transport waits are interrupted by the runtime. There are no
    // additional backend waits or allocations to cancel or destroy here.
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}

    fn increment(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const request = controller.input(&.{}) orelse return error.InvalidValue;
        const amount = request.int() orelse return controller.fail(.type, "increment expects an integer");
        state.total = std.math.add(i64, state.total, amount) catch return controller.fail(.overflow, "counter overflow");
        const builder = controller.builder();
        try builder.int(state.total);
        try builder.result();
    }

    fn echo(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const input = try controller.endpoint(Counter, .input);
        const output = try controller.endpoint(Counter, .output);
        var bytes: [256]u8 = undefined;
        while (try input.read(&bytes)) |count| try output.write(bytes[0..count]);
        try output.finish();
    }
});

comptime {
    _ = ecl.module(.{
        .name = "tutorial",
        .doc = "A small stateful port extension.",
        .ports = .{Counter},
        .words = .{ecl.factory("counter", "Create a counter; configuration [].", Counter)},
    });
}
