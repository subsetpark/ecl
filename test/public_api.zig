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

    _ = process;
    _ = filesystem;
    _ = net;
    _ = config;
    _ = clock;
}
