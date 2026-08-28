const heap = @import("ecl-heap");

const Payload = struct {
    pub fn retire(_: *Payload, _: *heap.ReleaseDomain) void {}
    pub fn deinit(_: *Payload) void {}
};

const Owner = heap.Owned(Payload);

export fn contract() usize {
    return @sizeOf(Owner);
}
