//! Host-side oracles and capability boundaries for the random modules.
//!
//! Deterministic language behavior lives in `test/stdlib-tests/random.ecl`.
//! These checks remain here because one compares against an independent Zig
//! implementation and the other requires a Session without host authority.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "random: the mixer matches the published splitmix64 vectors" {
    var mixer: std.Random.SplitMix64 = .init(0);
    try std.testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), mixer.next());
    try std.testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), mixer.next());
    try std.testing.expectEqual(@as(u64, 0x06C45D188009454F), mixer.next());
}

test "random: entropy is unavailable without the host capability" {
    try support.expectErrors(&.{.{
        .name = "no host entropy",
        .source = "rand.entropy",
        .kind = "io",
        .word = "rand.entropy",
        .message = "entropy is unavailable",
    }});
}
