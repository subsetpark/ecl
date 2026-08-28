const std = @import("std");
const heap = @import("ecl-heap");

const Payload = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    pub fn retire(_: *Payload, _: std.mem.Allocator) void {}
};

const Owner = heap.Owned(Payload);

export fn contract() usize {
    return @sizeOf(Owner);
}
