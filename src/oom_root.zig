//! Entry point for the deliberately exhaustive full-session OOM gate.

test {
    _ = @import("tests/oom_test.zig");
}
