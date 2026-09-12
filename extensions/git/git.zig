//! SDK-only HTTPS snapshot port. The C backend owns its entire native graph.
const std = @import("std");
const ecl = @import("ecl-native");
const c = @cImport({
    @cInclude("snapshot.h");
});

// A library must not bootstrap Zig's host I/O runtime while reporting a fatal
// programming defect. Keep the diagnostic bounded and preserve safety aborts.
pub const panic = std.debug.FullPanic(panicNative);
fn panicNative(message: []const u8, _: ?usize) noreturn {
    _ = std.c.write(2, message.ptr, @min(message.len, 1024));
    std.c.abort();
}

const Snapshot = ecl.Port(struct {
    pub const name = "snapshot";
    pub const State = struct { cancelled: std.atomic.Value(bool) = .init(false) };
    pub const endpoints = .{
        .output = ecl.declarations.Endpoint{ .doc = "Read the deterministic gzip-compressed regular-file archive.", .transport = .bytes, .direction = .output },
    };
    pub const operations = .{
        .fetch = .{ .doc = "Fetch an HTTPS tag or full commit and stream its snapshot; return the resolved commit.", .handler = fetch, .lane = .operation, .endpoints = .{.output} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, controller: *ecl.Controller) void {
        const config = controller.input(&.{}) orelse return controller.fail(.domain, "configuration must be []");
        if (config.kind() != .list or config.length() != 0) controller.fail(.domain, "configuration must be []");
    }
    pub fn cancel(state: *State) void {
        state.cancelled.store(true, .release);
    }
    pub fn deinit(_: *State) void {}

    const Invocation = struct {
        state: *State,
        controller: *ecl.Controller,
        failure: ?ecl.ControllerError = null,
        fn from(raw: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(raw.?));
        }
        fn cancelled(raw: ?*anyopaque) callconv(.c) c_int {
            const self = from(raw);
            return @intFromBool(self.state.cancelled.load(.acquire) or self.controller.cancelled());
        }
        fn write(raw: ?*anyopaque, bytes: [*c]const u8, length: usize) callconv(.c) c_int {
            const self = from(raw);
            const output = self.controller.endpoint(Snapshot, .output) catch |err| {
                self.failure = err;
                return -1;
            };
            output.write(bytes[0..length]) catch |err| {
                self.failure = err;
                return -1;
            };
            return 0;
        }
    };

    fn text(controller: *ecl.Controller, index: u64, buffer: []u8) RequestError![*:0]const u8 {
        const value = controller.input(&.{index}) orelse return error.InvalidRequest;
        if (value.kind() != .list) return error.InvalidRequest;
        const length = value.length().?;
        if (length >= buffer.len) return error.InvalidRequest;
        var offset: usize = 0;
        for (0..@intCast(length)) |i| {
            if (controller.cancelled()) return error.Cancelled;
            const item = controller.input(&.{ index, i }) orelse return error.InvalidRequest;
            const scalar = item.char() orelse return error.InvalidRequest;
            if (scalar == 0 or offset + 4 >= buffer.len) return error.InvalidRequest;
            offset += std.unicode.utf8Encode(scalar, buffer[offset..][0..4]) catch return error.InvalidRequest;
        }
        buffer[offset] = 0;
        return @ptrCast(buffer.ptr);
    }

    const RequestError = error{ InvalidRequest, Cancelled };
    const RequestStorage = struct {
        url: [8197]u8,
        revision: [1029]u8,
        ca: [4101]u8,
        scratch: [4101]u8,
    };
    // Returned strings borrow caller-owned storage through synchronous fetch.
    // Invalid public data never becomes an SDK capability-contract failure.
    fn parseRequest(controller: *ecl.Controller, storage: *RequestStorage) RequestError!c.struct_snapshot_request {
        const input = controller.input(&.{}) orelse return error.InvalidRequest;
        if (input.kind() != .dict) return error.InvalidRequest;
        const length = input.length().?;
        var request: c.struct_snapshot_request = .{
            .url = "",
            .selector = "",
            .revision = "",
            .ca_file = "",
            .scratch = "/tmp",
            .transfer_bytes = 512 * 1024 * 1024,
            .objects = 200000,
            .files = 100000,
            .export_bytes = 1024 * 1024 * 1024,
            .memory_bytes = 3 * 1024 * 1024 * 1024,
            .timeout_ms = 180000,
        };
        var required: u3 = 0;
        for (0..@intCast(length)) |index| {
            const key = controller.input(&.{index * 2}) orelse return error.InvalidRequest;
            const field_name = key.symbol() orelse return error.InvalidRequest;
            const field = index * 2 + 1;
            // Views expire on the next lookup, so dispatch before reading values.
            if (std.mem.eql(u8, field_name, "url")) {
                request.url = try text(controller, field, &storage.url);
                required |= 1;
            } else if (std.mem.eql(u8, field_name, "revision")) {
                request.revision = try text(controller, field, &storage.revision);
                required |= 2;
            } else if (std.mem.eql(u8, field_name, "selector")) {
                const value = controller.input(&.{field}) orelse return error.InvalidRequest;
                const selector = value.symbol() orelse return error.InvalidRequest;
                request.selector = if (std.mem.eql(u8, selector, "tag")) "tag" else if (std.mem.eql(u8, selector, "commit")) "commit" else return error.InvalidRequest;
                required |= 4;
            } else if (std.mem.eql(u8, field_name, "ca-file")) {
                request.ca_file = try text(controller, field, &storage.ca);
            } else if (std.mem.eql(u8, field_name, "scratch")) {
                request.scratch = try text(controller, field, &storage.scratch);
            } else {
                const limit: *u64 = if (std.mem.eql(u8, field_name, "transfer-bytes")) &request.transfer_bytes else if (std.mem.eql(u8, field_name, "objects")) &request.objects else if (std.mem.eql(u8, field_name, "files")) &request.files else if (std.mem.eql(u8, field_name, "export-bytes")) &request.export_bytes else if (std.mem.eql(u8, field_name, "memory-bytes")) &request.memory_bytes else if (std.mem.eql(u8, field_name, "timeout-ms")) &request.timeout_ms else return error.InvalidRequest;
                const value = controller.input(&.{field}) orelse return error.InvalidRequest;
                const number = value.int() orelse return error.InvalidRequest;
                if (number <= 0) return error.InvalidRequest;
                limit.* = @intCast(number);
            }
        }
        if (required != 7 or request.url[0] == 0 or request.revision[0] == 0) return error.InvalidRequest;
        return request;
    }

    fn fetch(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        var storage: RequestStorage = undefined;
        const request = parseRequest(controller, &storage) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.InvalidRequest => return controller.fail(.domain, "invalid snapshot request: expected bounded text, tag or commit selector, and positive integer limits"),
        };
        var invocation: Invocation = .{ .state = state, .controller = controller };
        const callbacks: c.struct_snapshot_callbacks = .{ .context = &invocation, .cancelled = Invocation.cancelled, .write = Invocation.write };
        var commit: [41]u8 = undefined;
        var message: [1024]u8 = undefined;
        const result = c.git_snapshot(&request, &callbacks, &commit, &message);
        if (invocation.failure) |err| return err;
        if (controller.cancelled()) return error.Cancelled;
        if (result == 2) return error.OutOfMemory;
        if (result != 0) return controller.fail(.io, std.mem.sliceTo(&message, 0));
        const output = try controller.endpoint(Snapshot, .output);
        try output.finish();
        const builder = controller.builder();
        for (commit[0..40]) |byte| try builder.char(byte);
        try builder.list(40);
        try builder.result();
    }
});

comptime {
    _ = ecl.module(.{
        .name = "git",
        .doc = "HTTPS Git snapshots with deterministic regular-file archive streaming.",
        .ports = .{Snapshot},
        .words = .{ecl.factory("snapshot", "Create a Git snapshot resource; configuration [].", Snapshot)},
    });
}
