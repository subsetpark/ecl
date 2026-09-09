const ecl = @import("ecl-native");
comptime {
    const Endpoints = ecl.declarations.Endpoints(.{
        .events = ecl.declarations.Endpoint{ .doc = "Resource events.", .transport = .messages, .direction = .output, .owner = .resource },
    });
    _ = ecl.declarations.Operations(enum { operation }, Endpoints, .{
        .watch = .{ .doc = "Watch events.", .handler = run, .lane = .operation, .endpoints = .{.events} },
    });
}
fn run() void {}
