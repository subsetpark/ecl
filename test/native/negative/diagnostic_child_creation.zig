const ecl = @import("ecl-native");
export fn invoke(context: *ecl.Controller) void {
    _ = context.errorData().child();
}
