//! Explicit-state pseudorandom draws and the host entropy capability.
const env = @import("../env.zig");
const random = @import("../kernel_random.zig");

pub const words = [_]env.BuiltinWord{
    .{
        .name = "int",
        .doc = "( state bound -- state result ) Draw one uniform integer below a positive bound.",
        .primitive = random.intForModule,
    },
    .{
        .name = "ints",
        .doc = "( state count bound -- state results ) Draw uniform integers from counter-addressed state.",
        .primitive = random.intsForModule,
    },
    .{
        .name = "float",
        .doc = "( state -- state result ) Draw one uniform float in the half-open interval [0, 1).",
        .primitive = random.floatForModule,
    },
    .{
        .name = "deal",
        .doc = "( state count pool -- state results ) Draw count distinct integers below a nonnegative pool size, advancing the state by count.",
        .primitive = random.dealForModule,
    },
    .{
        .name = "shuffle",
        .doc = "( state values -- state values ) Return a uniformly selected permutation of a list, advancing the state by its length.",
        .primitive = random.shuffleForModule,
    },
    .{
        .name = "deal",
        .doc = "( state count pool -- state results ) Draw count distinct integers below a nonnegative pool size, advancing the state by count.",
        .primitive = random.dealForModule,
    },
    .{
        .name = "shuffle",
        .doc = "( state values -- state values ) Return a uniformly selected permutation of a list, advancing the state by its length.",
        .primitive = random.shuffleForModule,
    },
    .{
        .name = "entropy",
        .doc = "( -- key ) Read one nondeterministic generator key from the host CSPRNG.",
        .primitive = random.entropyForModule,
    },
};
