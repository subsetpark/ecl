const ecl = @import("ecl-native");
comptime {
    _ = ecl.Port(struct {
        pub const name = "invalid";
        pub const State = u32;
        pub const cancellation: ecl.PortCancellation = .acknowledge;
        pub fn init() State {
            return 0;
        }
        pub fn open(_: *State, _: *ecl.Controller) void {}
        pub fn run(_: *State, _: u32, _: *ecl.Controller) void {}
        pub fn cancel(_: *State) void {}
        pub fn deinit(_: *State) void {}
    });
}
