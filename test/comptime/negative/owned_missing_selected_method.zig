const heap = @import("ecl-heap");

const Payload = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    pub fn deinit(_: *Payload) void {}
};

const Owner = heap.Owned(Payload);

export fn contract() usize {
    return @sizeOf(Owner);
}
