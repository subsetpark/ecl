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
    roots: [1]@import("../filesystem_port.zig").Root,

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
        inline for (std.meta.fields(Options)) |field| {
            if (@field(overrides, field.name)) |value| @field(result, field.name) = value;
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
    environ: ?@FieldType(session.RuntimeInputs, "environ") = null,
    standard_input: ?@FieldType(session.RuntimeInputs, "standard_input") = null,
    initial_cwd: ?@FieldType(session.RuntimeInputs, "initial_cwd") = null,
    process_limits: ?@FieldType(session.RuntimeInputs, "process_limits") = null,
    filesystem: ?@FieldType(session.RuntimeInputs, "filesystem") = null,
    http_limits: ?@FieldType(session.RuntimeInputs, "http_limits") = null,
    net_limits: ?@FieldType(session.RuntimeInputs, "net_limits") = null,
    native_port_limits: ?@FieldType(session.RuntimeInputs, "native_port_limits") = null,
    clock: ?@FieldType(session.RuntimeInputs, "clock") = null,
};
