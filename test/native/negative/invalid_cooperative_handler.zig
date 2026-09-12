const ecl = @import("ecl-native");
comptime {
    _ = ecl.Port(.{ .cooperative = struct {
        pub const name = "invalid";
        pub const State = struct { value: u8 = 0 };
        pub const operations = .{};
        pub fn init() State {
            return .{};
        }
        pub fn open(_: *State, _: *ecl.Controller) void {}
        pub fn retireOperation(_: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            return .completed;
        }
        pub fn retire(_: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            return .completed;
        }
    } });
}
