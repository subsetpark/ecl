const ecl = @import("ecl-native");
const Instance = ecl.Instance(struct {
    pub const State = u32;
    pub fn init() State {
        return 0;
    }
    pub fn initialize(_: *State) ecl.InstanceResult {
        return .complete;
    }
    pub fn retire(_: *State, _: *ecl.InstanceContext) bool {
        return true;
    }
});
comptime {
    _ = ecl.module(.{ .name = "invalid", .doc = "Invalid lifecycle.", .instance = Instance });
}
