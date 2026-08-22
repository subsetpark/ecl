//! Counter-based random kernels, the entropy gate, and the `rng` module.
//!
//! Determinism is the whole contract here, so nothing in this suite reaches
//! the host: `entropy` is proven unavailable in-process, and the real draw is
//! exercised against the built binary in `test/e2e.zig`.
const std = @import("std");
const support = @import("kernel_test_support.zig");

test "random: the mixer matches the published splitmix64 vectors" {
    // Vigna's reference splitmix64 emits 0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4,
    // 0x06C45D188009454F for seed 0. Draw i of key 0 is the first output of the
    // sub-stream seeded at i * gamma, so drawing modulo nothing would expose the
    // raw value; these bounds pin the same bits through the public words.
    var mixer: std.Random.SplitMix64 = .init(0);
    try std.testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), mixer.next());
    try std.testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), mixer.next());
    try std.testing.expectEqual(@as(u64, 0x06C45D188009454F), mixer.next());

    // The language-level word must agree with that first output: the low two
    // decimal digits of 0xE220A8397B1DCDAF are 35.
    try support.expectStack("[0 0] 100 rand-int", "[0 1] 35");
}

test "random: identical states produce identical draws" {
    try support.expectStacks(&.{
        .{
            .name = "the same state twice",
            .source = "[0 0] 100 rand-int nip [0 0] 100 rand-int nip =",
            .expected = "1",
        },
        .{
            .name = "a different key gives a different stream",
            .source = "[0 0] 100 rand-int nip [7 0] 100 rand-int nip <>",
            .expected = "1",
        },
        .{
            // Draws are values, not effects: the state carries the position.
            .name = "the returned state advances",
            .source = "[0 0] 100 rand-int pop [0 5] 3 100 rand-ints pop",
            .expected = "[0 1] [0 8]",
        },
        .{
            .name = "an empty draw advances nothing",
            .source = "[4 9] 0 100 rand-ints",
            .expected = "[4 9] ()",
        },
    });
}

test "random: a vector draw is counter-indexed and order-independent" {
    try support.expectStacks(&.{
        .{
            // Element i of a vector equals the single draw at counter + i, so a
            // resumed or reordered fill cannot change the result.
            .name = "vector elements equal their individual draws",
            .source = "[0 0] 3 100 rand-ints nip " ++
                "[0 0] 100 rand-int nip [0 1] 100 rand-int nip [0 2] 100 rand-int nip 3 pack " ++
                "match?",
            .expected = "1",
        },
        .{
            .name = "draws stay inside the bound",
            .source = "[3 0] 200 6 rand-ints nip dup (0 <) any? swap dup (6 >=) any? swap len",
            .expected = "0 0 200",
        },
        .{
            .name = "a bound of one is the constant zero",
            .source = "[0 0] 4 1 rand-ints nip",
            .expected = "[0 0 0 0]",
        },
        .{
            .name = "floats land in the unit interval",
            .source = "[0 0] rand-float nip dup 0.0 >= swap 1.0 <",
            .expected = "1 1",
        },
    });
}

test "random: malformed states and bounds are rejected" {
    try support.expectErrors(&.{
        .{
            .name = "a non-list state",
            .source = "5 100 rand-int",
            .kind = "type",
            .word = "rand-int",
            .message_contains = "generator state",
        },
        .{
            .name = "a state of the wrong width",
            .source = "[0] 100 rand-int",
            .kind = "type",
            .word = "rand-int",
        },
        .{
            .name = "a state holding a non-integer",
            .source = "[0 1.5] 100 rand-int",
            .kind = "type",
            .word = "rand-int",
        },
        .{
            .name = "a bound of zero",
            .source = "[0 0] 0 rand-int",
            .kind = "domain",
            .word = "rand-int",
        },
        .{
            .name = "a negative bound",
            .source = "[0 0] 3 -1 rand-ints",
            .kind = "domain",
            .word = "rand-ints",
        },
        .{
            .name = "a negative count",
            .source = "[0 0] -1 100 rand-ints",
            .kind = "domain",
            .word = "rand-ints",
        },
        .{
            .name = "a non-integer bound",
            .source = "[0 0] 1.5 rand-int",
            .kind = "type",
            .word = "rand-int",
        },
    });
}

test "random: entropy is unavailable without the host capability" {
    // The in-process session has no host Io, so the gate is what keeps this
    // suite deterministic; `test/e2e.zig` proves the real draw.
    try support.expectErrors(&.{.{
        .name = "no host entropy",
        .source = "entropy",
        .kind = "io",
        .word = "entropy",
        .message = "entropy is unavailable",
    }});
}

test "random: the rng module draws from durable module state" {
    try support.expectStacks(&.{
        .{
            // The module starts from a documented constant, so a sequential
            // program is reproducible without seeding.
            .name = "the default state is fixed",
            .source = "100 rng.int 100 rng.int",
            .expected = "35 0",
        },
        .{
            .name = "seeding makes a sequence reproducible",
            .source = "42 rng.seed 100 rng.int 42 rng.seed 100 rng.int =",
            .expected = "1",
        },
        .{
            .name = "seeding with a different key changes the sequence",
            .source = "42 rng.seed 100 rng.int 43 rng.seed 100 rng.int <>",
            .expected = "1",
        },
        .{
            .name = "reseeding reproduces an ints draw",
            .source = "42 rng.seed 3 6 rng.ints 42 rng.seed 3 6 rng.ints match?",
            .expected = "1",
        },
        .{
            .name = "float lands in the unit interval",
            .source = "rng.float dup 0.0 >= swap 1.0 <",
            .expected = "1 1",
        },
    });
}

test "random: deal draws without replacement and shuffle permutes" {
    try support.expectStacks(&.{
        .{
            // Distinctness is the property that separates deal from repeated
            // independent draws.
            .name = "deal returns distinct values inside the pool",
            .source = "5 10 rng.deal dup distinct len swap dup len swap " ++
                "dup (0 <) any? swap (10 >=) any?",
            .expected = "5 5 0 0",
        },
        .{
            .name = "a full deal is a permutation",
            .source = "8 8 rng.deal sort",
            .expected = "[0 1 2 3 4 5 6 7]",
        },
        .{
            .name = "the empty deal is legal",
            .source = "0 0 rng.deal len 0 5 rng.deal len",
            .expected = "0 0",
        },
        .{
            .name = "shuffle preserves the multiset",
            .source = "[10 20 30 40] rng.shuffle sort",
            .expected = "[10 20 30 40]",
        },
    });
    try support.expectErrors(&.{
        .{
            .name = "deal cannot exceed its pool",
            .source = "11 10 rng.deal",
            .kind = "domain",
            .message_contains = "more values than the pool",
        },
        .{
            .name = "deal rejects a negative count",
            .source = "-1 10 rng.deal",
            .kind = "domain",
            .message_contains = "nonnegative count",
        },
    });
}

test "random: every rng word carries documentation" {
    const names = [_][]const u8{ "seed", "int", "ints", "float", "deal", "shuffle" };
    for (names) |name| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "'rng.{s} body type 'rng.{s} doc len 0 >",
            .{ name, name },
        );
        defer std.testing.allocator.free(source);
        try support.expectStack(source, "'list 1");
    }
}
