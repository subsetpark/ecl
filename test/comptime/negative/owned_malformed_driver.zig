const heap = @import("ecl-heap");

const Driver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    pub fn deinit(_: *Driver) void {}
};

const Owner = heap.Owned(*Driver);

export fn contract() usize {
    return @sizeOf(Owner);
}
