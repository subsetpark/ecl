const ecl = @import("ecl-native");
const P = ecl.Port(.{ .controller = struct {
    pub const name = "invalid";
    pub const State = u8;
    pub const endpoints = .{ .input = ecl.declarations.Endpoint{ .doc = "Input.", .transport = .bytes, .direction = .input, .owner = .resource } };
    pub const activities = .{
        .first = .{ .handler = run, .endpoints = .{.input} },
        .second = .{ .handler = run, .endpoints = .{.input} },
    };
    pub fn init() State {
        return 0;
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
    fn run(_: *State, _: *ecl.Activity) void {}
} });
comptime {
    _ = P.definition();
}
