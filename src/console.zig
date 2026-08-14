//! Session-owned serialization for complete logical console writes.
const std = @import("std");

pub const Console = struct {
    output: ?*std.Io.Writer,
    diagnostics: ?*std.Io.Writer,
    output_mutex: std.Io.Mutex = .init,
    diagnostics_mutex: std.Io.Mutex = .init,

    pub fn init(output: ?*std.Io.Writer, diagnostics: ?*std.Io.Writer) Console {
        return .{ .output = output, .diagnostics = diagnostics };
    }

    pub fn lockOutput(self: *Console) ?OutputLease {
        const writer = self.output orelse return null;
        std.Io.Threaded.mutexLock(&self.output_mutex);
        return .{ .mutex = &self.output_mutex, .writer = writer };
    }

    pub fn lockDiagnostics(self: *Console) ?DiagnosticsLease {
        const writer = self.diagnostics orelse return null;
        std.Io.Threaded.mutexLock(&self.diagnostics_mutex);
        return .{ .mutex = &self.diagnostics_mutex, .writer = writer };
    }
};

pub const OutputLease = struct {
    mutex: *std.Io.Mutex,
    writer: *std.Io.Writer,

    pub fn deinit(self: *OutputLease) void {
        std.Io.Threaded.mutexUnlock(self.mutex);
        self.* = undefined;
    }
};

pub const DiagnosticsLease = struct {
    mutex: *std.Io.Mutex,
    writer: *std.Io.Writer,

    pub fn deinit(self: *DiagnosticsLease) void {
        std.Io.Threaded.mutexUnlock(self.mutex);
        self.* = undefined;
    }
};

test "console leases serialize a complete writer use" {
    var bytes: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var console = Console.init(&writer, null);
    var lease = console.lockOutput().?;
    defer lease.deinit();
    try lease.writer.writeAll("whole");
    try std.testing.expectEqualStrings("whole", writer.buffered());
}
