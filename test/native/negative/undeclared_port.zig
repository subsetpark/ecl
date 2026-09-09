const ecl = @import("ecl-native");
const P = ecl.Port(struct {
    pub const name = "counter";
    pub const State = u32;
    pub fn init() State {
        return 0;
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
});
comptime {
    _ = ecl.module(.{ .name = "invalid", .doc = "Undeclared port.", .words = .{ecl.factory("invalid", "Undeclared resource factory.", P)} });
}
