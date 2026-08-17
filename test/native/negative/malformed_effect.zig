const ecl = @import("ecl-native");
fn bad(_: *ecl.Call("input output")) ecl.CallbackResult {
    return .fail;
}
const Invalid = ecl.word("bad", "Invalid callback.", bad);
comptime {
    _ = Invalid;
}
