const ecl = @import("ecl-native");
export fn misuse(ctx: *ecl.Cooperative) void {
    _ = ctx.preparedFailure();
}
