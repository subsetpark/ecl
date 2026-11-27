//! Isolated inputs for a complete Session. Construct in place and keep alive
//! until every Session borrowing inputs has been torn down. Fixture allocation
//! is separate from the Session allocator so OOM probes measure runtime work.
const std = @import("std");
const session = @import("../session.zig");

pub const Fixture = struct {
    temporary: std.testing.TmpDir,
    cwd: [:0]u8,
    output: std.Io.Writer.Discarding = .init(&.{}),
    diagnostics: std.Io.Writer.Discarding = .init(&.{}),
    roots: [1]@import("../session.zig").Filesystem.Root,

    pub fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const cwd = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .temporary = temporary, .cwd = cwd, .roots = .{.{ .name = "cwd", .absolute_path = cwd }} };
    }

    pub fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.cwd);
        self.temporary.cleanup();
        self.* = undefined;
    }

    pub fn inputs(self: *Fixture, overrides: Options) session.RuntimeInputs {
        var result: session.RuntimeInputs = .{
            .io = std.testing.io,
            .output = &self.output.writer,
            .diagnostics = &self.diagnostics.writer,
            .initial_cwd = self.cwd,
            .environ = &.{},
            .standard_input = .program_source,
            .filesystem = .{ .roots = &self.roots },
            .clock = .{ .wall = .{ .fixed = 0 } },
        };
        inline for (@typeInfo(Options).@"struct".field_names) |field_name| {
            if (@field(overrides, field_name)) |value| @field(result, field_name) = value;
        }
        return result;
    }
};

pub const Options = struct {
    io: ?@FieldType(session.RuntimeInputs, "io") = null,
    output: ?@FieldType(session.RuntimeInputs, "output") = null,
    diagnostics: ?@FieldType(session.RuntimeInputs, "diagnostics") = null,
    tls_trust: ?@FieldType(session.RuntimeInputs, "tls_trust") = null,
    ecl_path: ?@FieldType(session.RuntimeInputs, "ecl_path") = null,
    module_map: ?@FieldType(session.RuntimeInputs, "module_map") = null,
    environ: ?@FieldType(session.RuntimeInputs, "environ") = null,
    standard_input: ?@FieldType(session.RuntimeInputs, "standard_input") = null,
    initial_cwd: ?@FieldType(session.RuntimeInputs, "initial_cwd") = null,
    process_limits: ?@FieldType(session.RuntimeInputs, "process_limits") = null,
    filesystem: ?@FieldType(session.RuntimeInputs, "filesystem") = null,
    http_limits: ?@FieldType(session.RuntimeInputs, "http_limits") = null,
    net_limits: ?@FieldType(session.RuntimeInputs, "net_limits") = null,
    native_port_limits: ?@FieldType(session.RuntimeInputs, "native_port_limits") = null,
    native_instances: ?@FieldType(session.RuntimeInputs, "native_instances") = null,
    clock: ?@FieldType(session.RuntimeInputs, "clock") = null,
};

/// Runs `source` in one task while a second task cancels it, and expects the
/// first to end cancelled. The Session must be cooperative: the second task
/// then runs only once the first has given up its turn, so a `source` that
/// finished within one turn ends `ok` and fails here.
pub fn expectCancelledAcrossTurns(runtime: *session.Session, source: []const u8) !void {
    const program = try std.mem.concat(std.testing.allocator, u8, &.{
        "(",
        source,
        ") @spawn `cancel-victim set (cancel-victim task.cancel) @spawn task.await pop " ++
            "cancel-victim task.await dup `err has? (`err at `kind at) () if",
    });
    defer std.testing.allocator.free(program);
    switch (try runtime.runUnit("<cancel-across-turns>", program)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            runtime.release(failure);
            return error.TestUnexpectedResult;
        },
    }
    var ending = try runtime.stackDisplay();
    defer ending.deinit();
    if (!std.mem.endsWith(u8, ending.bytes(), "cancelled")) {
        const shown = ending.bytes();
        std.log.err("ended without cancellation: {s}", .{shown[shown.len -| 300..]});
        return error.TestUnexpectedResult;
    }
    if (try runtime.runUnit("<cancel-across-turns>", "pop") != .ok) return error.TestUnexpectedResult;
}
