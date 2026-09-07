const std = @import("std");
const ecl = @import("ecl");

test "public API: Session evaluates a unit" {
    var runtime = try ecl.Session.init(std.testing.allocator, &.{});
    defer runtime.deinit();

    switch (try runtime.runUnit("<public-api-test>", "2 3 +")) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
    const items = runtime.stackItems();
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i64, 5), items[0].int);
}

test "public API: host policies are constructible through the facade" {
    const process: ecl.ProcessPolicy = .{ .executables = .unrestricted };
    const filesystem: ecl.FilesystemPolicy = .{ .roots = &.{} };
    const net: ecl.NetPolicy = .{ .binds = .unrestricted };
    const config: ecl.SessionConfig = .cooperative;
    const clock: ecl.ClockPolicy = .{ .monotonic = .manual, .wall = .{ .fixed = 0 } };
    const native_ports: ecl.NativePortLimits = .{ .max_live_ports = 2, .max_operations = 1, .ring_capacity = 8 };
    try native_ports.validate();

    _ = process;
    _ = filesystem;
    _ = net;
    _ = config;
    _ = clock;
}

test "public API: invalid native port limits fail Session initialization" {
    var output = std.Io.Writer.Discarding.init(&.{});
    var diagnostics = std.Io.Writer.Discarding.init(&.{});
    const invalid = [_]ecl.NativePortLimits{
        .{ .max_live_ports = 0 }, .{ .max_live_ports = 4097 },
        .{ .max_operations = 0 }, .{ .max_operations = 257 },
        .{ .ring_capacity = 0 },  .{ .ring_capacity = 16 * 1024 * 1024 + 1 },
    };
    for (invalid) |limits| try std.testing.expectError(error.InvalidHostPolicy, ecl.Session.initWithHost(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .native_port_limits = limits,
    }));
}
