const ecl = @import("ecl-native");
const P = ecl.Port(struct {
    pub const name = "counter";
    pub const State = u32;
    pub fn init() State {
        return 0;
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(_: *State, _: u32, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
});
fn callback(call: *ecl.Call("--"), _: *P) ecl.CallbackResult {
    return call.complete(.{});
}
comptime {
    _ = ecl.word("invalid", "Missing suspension authority.", callback);
}
