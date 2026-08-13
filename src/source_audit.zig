//! Build-time source architecture and line-budget audit.
const std = @import("std");

const Component = struct {
    name: []const u8,
    budget: usize,
    sources: []const []const u8,
};

const components = [_]Component{
    .{ .name = "values+RC", .budget = 2300, .sources = &.{
        @embedFile("value.zig"),  @embedFile("heap.zig"),
        @embedFile("intern.zig"), @embedFile("list.zig"),
        @embedFile("equal.zig"),  @embedFile("dict.zig"),
        @embedFile("print.zig"),  @embedFile("poll.zig"),
    } },
    .{ .name = "reader", .budget = 1250, .sources = &.{
        @embedFile("lexer.zig"),  @embedFile("binder.zig"),
        @embedFile("reader.zig"),
    } },
    .{ .name = "machine", .budget = 2300, .sources = &.{
        @embedFile("machine.zig"), @embedFile("spans.zig"),
        @embedFile("prims.zig"),   @embedFile("main.zig"),
        @embedFile("root.zig"),
    } },
    .{ .name = "modules and registry", .budget = 1300, .sources = &.{
        @embedFile("env.zig"),          @embedFile("modules.zig"),
        @embedFile("module_prims.zig"), @embedFile("reflection.zig"),
        @embedFile("session.zig"),
    } },
    .{ .name = "bootstrap prelude", .budget = 100, .sources = &.{
        @embedFile("prelude.zig"),
    } },
};

const test_sources = [_][]const u8{
    @embedFile("testgen.zig"),             @embedFile("reader_test.zig"),
    @embedFile("machine_test.zig"),        @embedFile("module_test.zig"),
    @embedFile("value_test.zig"),          @embedFile("kernel_test_support.zig"),
    @embedFile("kernel_numeric_test.zig"), @embedFile("kernel_sequence_test.zig"),
    @embedFile("kernel_order_test.zig"),   @embedFile("kernel_dict_text_test.zig"),
};

const kernel_sources = [_][]const u8{
    @embedFile("kernel_support.zig"),   @embedFile("kernels.zig"),
    @embedFile("kernel_storage.zig"),   @embedFile("kernel_numeric.zig"),
    @embedFile("kernel_sequence.zig"),  @embedFile("kernel_order.zig"),
    @embedFile("kernel_dict_text.zig"),
};

pub fn main() !void {
    var failed = false;
    var core_lines: usize = 0;
    for (components) |component| {
        var component_lines: usize = 0;
        for (component.sources) |source| component_lines += countCoreLines(source);
        std.debug.print("{s}: {d}/{d} core lines\n", .{ component.name, component_lines, component.budget });
        core_lines += component_lines;
        failed = failed or component_lines > component.budget;
    }
    var test_lines: usize = 0;
    for (components) |component| for (component.sources) |source| {
        test_lines += countLines(source) - countCoreLines(source);
    };
    for (test_sources) |source| test_lines += countLines(source);
    std.debug.print("line budget: {d}/9500 core, {d} test lines, {d} total\n", .{
        core_lines,
        test_lines,
        core_lines + test_lines,
    });
    failed = failed or core_lines > 9500;
    var kernel_lines: usize = 0;
    for (kernel_sources) |source| kernel_lines += countCoreLines(source);
    std.debug.print("kernels: {d}/5500 production lines\n", .{kernel_lines});
    failed = failed or kernel_lines > 5500;
    failed = auditTraversalSources() or failed;
    if (failed) return error.SourceAuditFailed;
}

fn countLines(source: []const u8) usize {
    var lines: usize = 0;
    for (source) |byte| lines += @intFromBool(byte == '\n');
    return lines + @intFromBool(source.len > 0 and source[source.len - 1] != '\n');
}

fn countCoreLines(source: []const u8) usize {
    var lines: usize = 0;
    var rest = source;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..end];
        rest = rest[@min(end + 1, rest.len)..];
        if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "test {")) {
            while (rest.len > 0) {
                const stop = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                const inner = rest[0..stop];
                rest = rest[@min(stop + 1, rest.len)..];
                if (std.mem.eql(u8, inner, "}")) break;
            }
            if (std.mem.startsWith(u8, rest, "\n")) rest = rest[1..];
            continue;
        }
        lines += 1;
    }
    return lines;
}

fn auditTraversalSources() bool {
    const sources = [_][]const u8{
        @embedFile("equal.zig"),          @embedFile("print.zig"),
        @embedFile("kernel_numeric.zig"), @embedFile("kernel_sequence.zig"),
        @embedFile("kernel_order.zig"),   @embedFile("kernel_dict_text.zig"),
        @embedFile("kernel_storage.zig"), @embedFile("module_prims.zig"),
        @embedFile("reflection.zig"),
    };
    const forbidden = [_][]const u8{
        "std.ArrayList",
        "AutoHashMap",
        "std.mem.sort",
        "Writer.Allocating",
        "publicNamesOwned(self.unit.allocator, null)",
        "writeAll(intern.get",
        "print(\"{s}\"",
    };
    var failed = false;
    for (sources) |source| failed = hasForbidden("runtime traversal", source, &forbidden) or failed;
    const machine = @embedFile("machine.zig");
    const start = std.mem.indexOf(u8, machine, "    pub fn shadowTraceIdsOwned") orelse return true;
    const end = std.mem.indexOfPos(u8, machine, start, "fn scheduleWord") orelse return true;
    return hasForbidden("machine reflection", machine[start..end], &forbidden) or failed;
}

fn hasForbidden(label: []const u8, source: []const u8, forbidden: []const []const u8) bool {
    var failed = false;
    for (forbidden) |pattern| if (std.mem.indexOf(u8, source, pattern) != null) {
        std.debug.print("{s}: forbidden source pattern `{s}`\n", .{ label, pattern });
        failed = true;
    };
    return failed;
}
