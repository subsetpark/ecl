//! Persistent calculator session with transactional stack units.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const prims = @import("prims.zig");
const prelude = @import("prelude.zig");
const idioms = @import("idioms.zig");
const printer = @import("print.zig");
const intern = @import("intern.zig");
const scheduler_api = @import("scheduler.zig");
const console_api = @import("console.zig");
const session_options = @import("session_options");
pub const Value = value.Value;
pub const UnitOutcome = union(enum) {
    ok,
    incomplete: reader.Incomplete,
    err: Value,
};
pub const Config = struct {
    worker_count: usize = default_worker_count,
};
pub const default_worker_count: usize = session_options.default_worker_count;
pub const Session = struct {
    allocator: std.mem.Allocator,
    environment: env.Env,
    registry: modules.Registry,
    stack: std.ArrayList(Value) = .empty,
    archive: spans.SpanArchive,
    output: ?*std.Io.Writer,
    diagnostics: ?*std.Io.Writer,
    host_io: ?std.Io,
    ecl_path: ?[]u8,
    arguments: Value,
    console: console_api.Console,
    scheduler: scheduler_api.Scheduler,
    root_tasks: scheduler_api.TaskScope,
    root_scope: ?env.Scope = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    requested_exit: ?u8 = null,
    last_max_frames: usize = 0,
    last_polls: u64 = 0,
    idiom_mode: machine.IdiomMode = .automatic,
    last_idiom_hits: u64 = 0,
    pub fn init(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, null, null, .{});
    }
    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, null, null, config);
    }
    /// The output writer must outlive the session.
    pub fn initWithOutput(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: *std.Io.Writer,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, null, null, null, .{});
    }
    pub fn initWithHost(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        io: std.Io,
        output: *std.Io.Writer,
        diagnostics: *std.Io.Writer,
        ecl_path: ?[]const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, diagnostics, io, ecl_path, .{});
    }
    pub fn initWithHostConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        io: std.Io,
        output: *std.Io.Writer,
        diagnostics: *std.Io.Writer,
        ecl_path: ?[]const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, diagnostics, io, ecl_path, config);
    }
    fn initFull(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: ?*std.Io.Writer,
        diagnostics: ?*std.Io.Writer,
        host_io: ?std.Io,
        ecl_path: ?[]const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        if (config.worker_count == 0) return error.OutOfMemory;
        var environment = env.Env.init(allocator);
        errdefer environment.deinit();
        var building = environment.beginCoreBuild();
        try prims.install(&building);
        var registry = modules.Registry.init(allocator);
        errdefer registry.deinit();
        var archive = spans.SpanArchive.init(allocator);
        errdefer archive.deinit();
        var bootstrap_cancelled: std.atomic.Value(bool) = .init(false);
        prelude.install(allocator, &building, &registry, &archive, &bootstrap_cancelled) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPrelude => @panic("embedded prelude is invalid"),
        };
        const owned_ecl_path = if (ecl_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_ecl_path) |path| allocator.free(path);
        const argv = try argumentsValue(allocator, arguments);
        var scheduler = scheduler_api.Scheduler.init(allocator, .{ .worker_count = config.worker_count });
        return .{
            .allocator = allocator,
            .environment = environment,
            .registry = registry,
            .archive = archive,
            .output = output,
            .diagnostics = diagnostics,
            .host_io = host_io,
            .ecl_path = owned_ecl_path,
            .arguments = argv,
            .console = console_api.Console.init(output, diagnostics),
            .scheduler = scheduler,
            .root_tasks = scheduler_api.TaskScope.init(&scheduler),
        };
    }
    pub fn deinit(self: *Session) void {
        self.root_tasks.scheduler = &self.scheduler;
        self.scheduler.deinit(&self.root_tasks);
        if (self.root_scope) |*root_scope| root_scope.deinit();
        for (self.stack.items) |item| heap.releaseValue(self.allocator, item);
        self.stack.deinit(self.allocator);
        heap.releaseValue(self.allocator, self.arguments);
        if (self.ecl_path) |path| self.allocator.free(path);
        self.registry.deinit();
        self.environment.deinit();
        self.archive.deinit();
        self.* = undefined;
    }
    pub fn runUnit(
        self: *Session,
        source_name: []const u8,
        source: []const u8,
    ) error{OutOfMemory}!UnitOutcome {
        self.root_tasks.scheduler = &self.scheduler;
        if (self.root_scope == null)
            self.root_scope = self.environment.sessionRoot(self.allocator);
        var diag: reader.Diag = .{};
        const read_result = reader.read(self.allocator, source_name, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => {
                var parse_error = machine.EclErr.init(.parse, diag.text());
                defer parse_error.deinit(self.allocator);
                const location = spans.LocatedSpan{
                    .source_name = source_name,
                    .span = diag.span,
                };
                return .{ .err = try machine.errorValue(self.allocator, &parse_error, &.{}, location) };
            },
        };
        switch (read_result) {
            .incomplete => |incomplete| return .{ .incomplete = incomplete },
            .complete => |complete| {
                var parsed = complete;
                defer parsed.deinit();
                return self.executeParsed(&parsed);
            },
        }
    }
    fn executeParsed(
        self: *Session,
        parsed: *reader.Parsed,
    ) error{OutOfMemory}!UnitOutcome {
        const root = try list.fromValuesGeneric(self.allocator, parsed.forms);
        var root_owned = true;
        defer if (root_owned) heap.releaseValue(self.allocator, root);
        const root_header = root.list;
        try self.archive.absorb(parsed, root);
        root_owned = false;
        const checkpoint = try self.allocator.dupe(Value, self.stack.items);
        defer self.allocator.free(checkpoint);
        for (checkpoint) |item| heap.retainValue(item);
        var checkpoint_owned = true;
        defer if (checkpoint_owned) for (checkpoint) |item| heap.releaseValue(self.allocator, item);
        var unit = machine.Unit.init(
            self.allocator,
            self.stack,
            &self.environment,
            &self.archive,
            self.output,
            self.arguments,
            &self.cancelled,
        );
        unit.registry = &self.registry;
        unit.diagnostics = self.diagnostics;
        unit.host_io = self.host_io;
        unit.ecl_path = self.ecl_path;
        unit.idiom_mode = self.idiom_mode;
        unit.phrase_recognizer = idioms.tryApply;
        unit.console = &self.console;
        unit.scheduler = &self.scheduler;
        unit.task_scope = &self.root_tasks;
        unit.is_root_unit = true;
        unit.execution_scope = if (self.root_scope) |*root_scope| root_scope else unreachable;
        self.stack = .empty;
        defer {
            self.stack = unit.takeStack();
            self.last_max_frames = unit.max_frames;
            self.last_polls = unit.polls;
            self.requested_exit = unit.exit_status;
            self.last_idiom_hits = unit.idiom_hits;
            unit.deinit();
        }
        self.scheduler.runRoot(&unit, root_header) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint);
                checkpoint_owned = false;
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint);
                checkpoint_owned = false;
                return .{ .err = unit.takeError().? };
            },
        };
        return .ok;
    }
    pub fn stackDisplay(self: *const Session) error{OutOfMemory}![]u8 {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        for (self.stack.items, 0..) |item, index| {
            if (index > 0) allocating.writer.writeByte(' ') catch return error.OutOfMemory;
            printer.printWithAllocator(self.allocator, item, &allocating.writer) catch
                return error.OutOfMemory;
        }
        return allocating.toOwnedSlice();
    }
    pub fn writeOutput(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.console.lockOutput() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    pub fn writeOutputLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.console.lockOutput() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.writeByte('\n') catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    pub fn writeDiagnostics(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.console.lockDiagnostics() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    pub fn writeDiagnosticsLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.console.lockDiagnostics() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.writeByte('\n') catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    pub fn registerNativeModule(
        self: *Session,
        name: intern.NamespaceName,
        definitions: []const modules.NativeDefinition,
    ) modules.RegistryError!u64 {
        return self.registry.registerNative(name, definitions);
    }
    pub fn schedulerWorkerThreadCount(self: *const Session) usize {
        return self.scheduler.workerThreadCount();
    }
    pub fn schedulerTimerThreadCount(self: *const Session) usize {
        return self.scheduler.timerThreadCount();
    }
    pub fn schedulerTimerEntryCount(self: *Session) usize {
        return self.scheduler.timerEntryCount();
    }
};
fn restoreCheckpoint(unit: *machine.Unit, checkpoint: []const Value) void {
    for (unit.stack.items) |item| heap.releaseValue(unit.allocator, item);
    unit.stack.clearRetainingCapacity();
    std.debug.assert(unit.stack.capacity >= checkpoint.len);
    unit.stack.appendSliceAssumeCapacity(checkpoint);
}
fn argumentsValue(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) error{OutOfMemory}!Value {
    const items = try allocator.alloc(Value, arguments.len);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |item| heap.releaseValue(allocator, item);
    for (arguments) |argument| {
        items[initialized] = try machine.stringValue(allocator, argument);
        initialized += 1;
    }
    return list.fromValuesGeneric(allocator, items);
}
fn dictSymbol(
    allocator: std.mem.Allocator,
    dictionary: Value,
    name: []const u8,
) ![]const u8 {
    const dict = @import("dict.zig");
    const key = try intern.intern(name);
    const found = (try dict.symbolField(allocator, dictionary, key)).?;
    return intern.get(found.symbol);
}
test "session runs the soul test" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("<test>", "3 4 +")) == .ok);
    const display = try session.stackDisplay();
    defer allocator.free(display);
    try std.testing.expectEqualStrings("7", display);
}
test "failed units roll back stack while definitions survive" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("<test>", "10")) == .ok);
    const failed = (try session.runUnit("<test>", "(2 *) 'double def 20 + missing")).err;
    heap.releaseValue(allocator, failed);
    try std.testing.expectEqual(@as(usize, 1), session.stack.items.len);
    try std.testing.expectEqual(@as(i64, 10), session.stack.items[0].int);
    const consumed = (try session.runUnit("<test>", "pop missing")).err;
    heap.releaseValue(allocator, consumed);
    try std.testing.expectEqual(@as(usize, 1), session.stack.items.len);
    try std.testing.expectEqual(@as(i64, 10), session.stack.items[0].int);
    try std.testing.expect((try session.runUnit("<test>", "double")) == .ok);
    try std.testing.expectEqual(@as(i64, 20), session.stack.items[0].int);
}
test "parse diagnostics become parse error dicts" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    const error_value = (try session.runUnit("broken.ecl", "1 ]")).err;
    defer heap.releaseValue(allocator, error_value);
    try std.testing.expectEqualStrings("parse", try dictSymbol(allocator, error_value, "kind"));
}
test "source-defined failures retain provenance after their unit" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("defs.ecl", "(1 0 /) 'boom def")) == .ok);
    const error_value = (try session.runUnit("call.ecl", "boom")).err;
    defer heap.releaseValue(allocator, error_value);
    const rendered = try printer.toOwnedString(allocator, error_value);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"defs.ecl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'word '/") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'trace ['/ 'boom]") != null);
    const runtime_error = (try session.runUnit(
        "assembled.ecl",
        "1 0 (/) cons cons call",
    )).err;
    defer heap.releaseValue(allocator, runtime_error);
    const runtime_rendered = try printer.toOwnedString(allocator, runtime_error);
    defer allocator.free(runtime_rendered);
    try std.testing.expect(std.mem.indexOf(u8, runtime_rendered, "'source") == null);
}
