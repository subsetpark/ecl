//! Explicit-state pseudorandom draws and the host entropy capability.
const env = @import("../env.zig");
const random = @import("../kernel_random.zig");

pub const words = [_]env.BuiltinWord{
    .{
        .name = "int",
        .effect = "state bound -- state result",
        .doc = "Draw one unbiased uniform int in `[0, bound)`. A bound below 1 is `` `domain ``.",
        .primitive = random.intForModule,
    },
    .{
        .name = "ints",
        .effect = "state count bound -- state results",
        .doc = "Draw `count` uniform ints in `[0, bound)`, advancing the state by `count`. Each element is addressed by its own counter position, so materialization order cannot change the list.",
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
        .doc = "Draw `count` distinct ints in `[0, pool)` without replacement, advancing the state by `count`. Work and memory follow `count`, never `pool`. A negative count or pool, or a count above the pool, is `` `domain ``; a non-int count or pool is `` `type ``.",
        .primitive = random.dealForModule,
    },
    .{
        .name = "shuffle",
        .effect = "state values -- state values",
        .doc = "Return a uniformly selected permutation of a list, advancing the state by the list's length. Any element kind is permuted and the list keeps its representation. A non-list is `` `type ``.",
        .primitive = random.shuffleForModule,
    },
    .{
        .name = "entropy",
        .effect = "-- key",
        .doc = "Read one int from the host CSPRNG. This is the language's only nondeterministic word, requires host IO, and is `` `io `` without it.",
        .primitive = random.entropyForModule,
    },
};
