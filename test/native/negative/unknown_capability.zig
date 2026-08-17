const ecl = @import("ecl-native");
fn bad(_: *ecl.Call("--"), _: *const u8) ecl.CallbackResult {
    return .fail;
}
const Invalid = ecl.word("bad", "Invalid callback.", bad);
comptime {
    _ = Invalid;
}
