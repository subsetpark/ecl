const ecl = @import("ecl-native");
comptime {
    _ = ecl.module(.{ .name = "a..b", .doc = "Invalid empty name component." });
}
