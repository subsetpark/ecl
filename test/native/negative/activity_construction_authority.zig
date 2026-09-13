const ecl = @import("ecl-native");
export fn invoke(context: *ecl.Activity) void {
    _ = context.builder();
}
