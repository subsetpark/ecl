const ecl = @import("ecl-native");
fn first(_: *ecl.Call("--")) ecl.CallbackResult {
    return .fail;
}
fn second(_: *ecl.Call("--")) ecl.CallbackResult {
    return .fail;
}
const Invalid = ecl.module(.{
    .name = "invalid",
    .doc = "Invalid module.",
    .words = .{
        ecl.word("same", "First word.", first),
        ecl.word("same", "Second word.", second),
    },
});
comptime {
    _ = Invalid;
}
