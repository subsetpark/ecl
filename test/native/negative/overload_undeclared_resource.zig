const ecl = @import("ecl-native");
const P = ecl.Port(.{ .controller = struct {
    pub const name = "resource";
    pub const State = struct { value: u8 = 0 };
    pub const operations = .{ .value = .{ .doc = "Read value.", .handler = read, .lane = .operation, .endpoints = .{} } };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
    fn read(_: *State, _: *ecl.Controller) void {}
} });
comptime {
    _ = ecl.module(.{ .name = "probe", .doc = "Probe.", .words = .{ecl.overload("read", "Read a resource.", .{.{ P, .value }})} }).descriptor();
}
