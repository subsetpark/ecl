const ecl = @import("ecl-native");
fn observe(call: *ecl.Call("value -- bool")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(@intFromBool(call.inputIsResource(struct {}, 0)))});
}
const Extension = ecl.module(.{ .linkage = .dynamic, .name = "bad", .doc = "Invalid resource observation.", .words = .{ecl.word("observe", "Observe an undeclared resource kind.", observe)} });
comptime {
    _ = Extension;
}
