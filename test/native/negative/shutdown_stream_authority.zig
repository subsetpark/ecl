const ecl = @import("ecl-native");
export fn invoke(context: *ecl.Shutdown) void {
    _ = context.endpoint();
}
