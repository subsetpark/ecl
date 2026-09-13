const ecl = @import("ecl-native");
export fn invoke(context: *ecl.Finalizer) void {
    _ = context.initializationResource(void, &.{}, .resource);
}
