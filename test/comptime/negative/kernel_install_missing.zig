const ecl = @import("ecl");
const support = ecl.kernels.support;

const Op = enum {
    first,
    second,

    pub fn spelling(self: Op) []const u8 {
        return switch (self) {
            .first => "one",
            .second => "two",
        };
    }
};

const Entry = support.InstallationEntry(Op);
const Installation = support.ClosedInstallation(struct {
    pub const Operation = Op;
    pub const entries = [_]Entry{Entry.installed(.first)};

    pub fn bind(comptime _: Operation) ecl.env.PrimitiveImpl {
        return primitive;
    }
});

fn primitive(_: *ecl.machine.Machine) ecl.machine.MachineError!void {}

export fn contract() usize {
    return @sizeOf(Installation);
}
