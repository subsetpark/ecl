//! Package-root entrypoint for the build-only source architecture audit.
const std = @import("std");
const audit = @import("tools/source_audit.zig");

pub fn main(init: std.process.Init) !void {
    return audit.main(init);
}
