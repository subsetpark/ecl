const ecl = @import("ecl-native");
const P = ecl.Port(struct {
    pub const name = "direction";
    pub const State = u8;
    pub const endpoints = .{
        .output = ecl.declarations.Endpoint{ .doc = "Byte output.", .transport = .bytes, .direction = .output },
    };
    pub const operations = .{};
    pub fn init() State {
        return 0;
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
});
export fn probe(controller: *ecl.Controller) void {
    const output = controller.endpoint(P, .output) catch return;
    _ = @typeInfo(@TypeOf(output)).pointer.child.read;
}
