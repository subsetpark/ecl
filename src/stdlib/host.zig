//! Read-only host process metadata for ordinary applications.
const std = @import("std");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const machine = @import("../machine.zig");
const process = @import("../process_port.zig");
const storage = @import("../kernel_storage.zig");

pub const words = [_]env.BuiltinWord{
    .{ .name = "cwd", .effect = "-- path", .doc = "Return the Session's absolute startup directory as UTF-8 text.", .primitive = cwd },
    .{ .name = "executable", .effect = "-- path", .doc = "Return the operating system's absolute path to the current executable as UTF-8 text; report io if unavailable.", .primitive = executable },
};

const Query = enum { cwd, executable };
fn cwd(evaluator: *machine.Machine) machine.MachineError!void {
    return begin(evaluator, .cwd);
}
fn executable(evaluator: *machine.Machine) machine.MachineError!void {
    return begin(evaluator, .executable);
}
fn begin(evaluator: *machine.Machine, query: Query) machine.MachineError!void {
    const owned = try evaluator.allocator().create(Metadata);
    owned.* = .{ .query = query };
    evaluator.adoptDriver(owned);
}
const Metadata = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    query: Query,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    state: union(enum) { query, text: storage.Utf8Materializer, complete } = .query,

    pub fn deinit(self: *@This(), releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        if (self.state == .text) self.state.text.retire(releases);
    }
    pub fn advance(evaluator: *machine.Machine, self: *@This()) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .query) {
            const runtime = evaluator.unit.inherited.runtime();
            const bytes = switch (self.query) {
                .cwd => process.startupDirectory(runtime.process_access),
                .executable => path: {
                    const length = std.process.executablePath(runtime.host_io, &self.buffer) catch
                        return evaluator.fail(.io, "cannot determine current executable path");
                    break :path self.buffer[0..length];
                },
            };
            self.state = .{ .text = .init(evaluator.allocator(), bytes) };
        }
        return switch (self.state.text.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return evaluator.fail(.io, "host process path is not UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |result| done: {
                self.state.text.deinit();
                self.state = .complete;
                break :done .{ .output = result };
            },
        };
    }
};
