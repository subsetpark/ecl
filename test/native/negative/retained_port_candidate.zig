const ecl = @import("ecl-native");
comptime {
    _ = ecl.Reschedule(struct {
        pub const State = struct { candidate: ?ecl.Candidate = null };
        pub fn init() State {
            return .{};
        }
        pub fn deinit(_: *State) void {}
    });
}
