//! Host-side oracles and input validation for the random modules.
//!
//! Deterministic language behavior lives in `test/stdlib-tests/random.ecl`.
//! This check records independent Zig oracle vectors. Entropy is exercised
//! through the CLI acceptance suite.
const std = @import("std");

test "random: the mixer matches the published splitmix64 vectors" {
    var mixer: std.Random.SplitMix64 = .init(0);
    try std.testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), mixer.next());
    try std.testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), mixer.next());
    try std.testing.expectEqual(@as(u64, 0x06C45D188009454F), mixer.next());
}
