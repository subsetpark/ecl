//! The host kernel behind the `error` module, which imports it.
//! `valid?` reports the same error-dict schema `raise` enforces, so the two
//! cannot disagree about what an error is.
const env = @import("../env.zig");
const prims = @import("../prims.zig");

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Host kernel behind the `error` module: the error-dict schema `raise` enforces.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "valid?",
        .effect = "value -- bool",
        .doc = "Return 1 when a value satisfies the error dictionary schema `raise` enforces: a required symbol `` `kind `` and well-typed optional `` `msg ``, `` `word ``, `` `trace ``, and `` `data `` fields. Extra fields are allowed.",
        .primitive = prims.errorValid,
    },
};
