//! Explicit-state pseudorandom draws and the host entropy capability.
const env = @import("../env.zig");
const random = @import("../kernel_random.zig");

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Explicit-state pseudorandom draws are pure except for `entropy`; see
    \\[Randomness](SPEC.md#randomness). The state is `[key counter]`, and every draw returns the
    \\advanced state alongside its result. An ambient generator is an agent holding that state:
    \\``[0 0] agent.start `rng set`` then `rng (5 rand.int) agent.call`.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "int",
        .effect = "state bound -- state result",
        .doc = "Draw one unbiased uniform int in `[0, bound)`.",
        .primitive = random.intForModule,
    },
    .{
        .name = "ints",
        .effect = "state count bound -- state results",
        .doc = "Draw `count` uniform ints in `[0, bound)`, advancing the state by `count`.",
        .primitive = random.intsForModule,
    },
    .{
        .name = "float",
        .effect = "state -- state result",
        .doc = "Draw one uniform float in `[0, 1)`.",
        .primitive = random.floatForModule,
    },
    .{
        .name = "deal",
        .effect = "state count pool -- state results",
        .doc = "Draw `count` distinct ints in `[0, pool)` without replacement.",
        .primitive = random.dealForModule,
    },
    .{
        .name = "shuffle",
        .effect = "state values -- state values",
        .doc = "Return a uniformly selected permutation of `values`.",
        .primitive = random.shuffleForModule,
    },
    .{
        .name = "entropy",
        .effect = "-- key",
        .doc = "Read one int from the host CSPRNG.",
        .primitive = random.entropyForModule,
    },
};
