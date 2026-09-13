const ecl = @import("ecl-native");
export fn invoke(context: *ecl.Cooperative) void {
    _ = context.errorData().child();
}
