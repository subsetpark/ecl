//! Closed installer for all M5 kernel families.
const env = @import("env.zig");
pub const support = @import("kernel_support.zig");
pub const storage = @import("kernel_storage.zig");
pub const numeric = @import("kernel_numeric.zig");
pub const sequence = @import("kernel_sequence.zig");
pub const order = @import("kernel_order.zig");
pub const dict_text = @import("kernel_dict_text.zig");
pub const Registry = struct {
    pub const entries = @import("idioms.zig").registry;
};

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    try numeric.install(core);
    try sequence.install(core);
    try order.install(core);
    try dict_text.install(core);
}
