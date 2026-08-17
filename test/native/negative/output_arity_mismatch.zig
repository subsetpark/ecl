const ecl = @import("ecl-native");
fn bad(call: *ecl.Call("-- output")) ecl.CallbackResult {
    return call.complete(.{});
}
pub const Invalid = ecl.module(.{
    .name = "invalid",
    .doc = "Invalid module.",
    .words = .{ecl.word("bad", "Invalid callback.", bad)},
});
comptime {
    _ = Invalid;
}
