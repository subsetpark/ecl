const ecl = @import("ecl-native");
const fixture = @import("instance.zig");
comptime {
    @export(&fixture.Extension.entryPoint, .{ .name = ecl.abi.entry_symbol });
}
