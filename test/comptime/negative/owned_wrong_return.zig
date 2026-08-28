const heap = @import("ecl-heap");

const Payload = struct {
    pub fn deinit(_: *Payload) bool {
        return false;
    }
};

const Owner = heap.Owned(Payload);

export fn contract() usize {
    return @sizeOf(Owner);
}
