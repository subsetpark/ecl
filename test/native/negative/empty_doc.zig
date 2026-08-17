const ecl = @import("ecl-native");
fn bad(_: *ecl.Call("--")) ecl.CallbackResult {
    return .fail;
}
const Invalid = ecl.word("bad", "", bad);
comptime {
    _ = Invalid;
}
