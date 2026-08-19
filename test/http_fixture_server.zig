//! Loopback HTTP fixture for the `http` module's tests.
//!
//! The 0.16 `std.Io` network API exposes no way to read back an ephemeral
//! port, so this takes a starting port, walks upward until one binds, and
//! prints `port <n>` as its readiness handshake — the same sentinel pattern
//! `test/repl.exp` uses. It serves 127.0.0.1 only and runs until killed.
const std = @import("std");

const attempts: u16 = 64;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    const start = try std.fmt.parseInt(u16, arguments[1], 10);

    // SAFETY: assigned by the bind loop below before any use.
    var server: std.Io.net.Server = undefined;
    var port = start;
    while (true) {
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch
            return error.BadAddress;
        server = std.Io.net.IpAddress.listen(&address, init.io, .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse => {
                if (port - start + 1 == attempts) return error.NoFreePort;
                port += 1;
                continue;
            },
            else => return err,
        };
        break;
    }
    defer server.deinit(init.io);

    var announcement: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&announcement, "port {d}\n", .{port});
    var out_buffer: [64]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    try out.interface.writeAll(line);
    try out.interface.flush();

    while (true) {
        const stream = server.accept(init.io) catch continue;
        defer stream.close(init.io);
        var in_buffer: [8192]u8 = undefined;
        var response_buffer: [8192]u8 = undefined;
        var reader = stream.reader(init.io, &in_buffer);
        var writer = stream.writer(init.io, &response_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch continue;
        serve(&request, init.arena.allocator()) catch continue;
    }
}

fn serve(request: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/hello")) {
        return request.respond("hello, world\n", .{
            .extra_headers = &.{.{ .name = "x-fixture", .value = "hello" }},
        });
    }
    if (std.mem.eql(u8, target, "/duplicate")) {
        return request.respond("repeated headers\n", .{
            .extra_headers = &.{
                .{ .name = "X-Repeated", .value = "first" },
                .{ .name = "x-repeated", .value = "last" },
            },
        });
    }
    if (std.mem.eql(u8, target, "/echo")) {
        // Echo the request body and one caller header, so a POST test can see
        // that both actually crossed the wire.
        // Headers must be read before the body reader is initialized; doing
        // it the other way round trips the same head-invalidation assertion
        // the client side documents.
        var echoed: []const u8 = "";
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-probe")) echoed = header.value;
        }
        var body_buffer: [8192]u8 = undefined;
        const reader = request.readerExpectNone(&body_buffer);
        const body = try reader.allocRemaining(allocator, .limited(1 << 20));
        const payload = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ echoed, body });
        return request.respond(payload, .{
            .extra_headers = &.{.{ .name = "x-fixture", .value = "echo" }},
        });
    }
    return request.respond("not found\n", .{ .status = .not_found });
}
