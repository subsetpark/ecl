const ecl = @import("ecl-native");
export fn invoke(context: *ecl.RejectedOpen) void {
    _ = context.errorData().child();
}
