const ecl = @import("ecl-native");
const Resource = ecl.Port(.{ .controller = struct {
    pub const name = "probe";
    pub const State = struct { byte: u8 = 0 };
    pub const endpoints = .{ .data = ecl.declarations.Endpoint{ .doc = "Direction probe.", .transport = .bytes, .direction = .output, .owner = .resource } };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
} });
export fn reject(ctx: *ecl.Activity) void {
    ctx.finishInput(Resource, .data) catch return;
}
