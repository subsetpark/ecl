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
pub const Config = union(enum) {
    default,
    cooperative,
    worker_pool: usize,

    fn schedulerConfig(self: Config) scheduler_api.Config {
        return switch (self) {
            .default => .{ .worker_pool = default_worker_count },
            .cooperative => .cooperative,
            .worker_pool => |count| .{ .worker_pool = count },
        };
    }
};
pub const default_worker_count: usize = session_options.default_worker_count;
const SessionCore = struct {
    module_access_seal: u8 = 0,
    host_owner: *heap.HostOwner,
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
    root_scope: ?*env.Scope = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    requested_exit: ?u8 = null,
    last_max_frames: usize = 0,
    last_polls: u64 = 0,
    idiom_mode: machine.IdiomMode = .automatic,
    last_idiom_hits: u64 = 0,

    fn moduleAccess(self: *const SessionCore) *const modules.ExecutionAccess {
        return @ptrCast(&self.module_access_seal);
    }

    fn allocator(self: *const SessionCore) std.mem.Allocator {
        return self.host_owner.cleanup().allocator();
    }

    fn releaseDomain(self: *const SessionCore) *heap.ReleaseDomain {
        return self.host_owner.domain();
    }
};
comptime {
    heap.requireSingleHostOwner(SessionCore);
}
const OpaqueSessionCore = opaque {};

/// Movable opaque handle for heap-stable runtime state. Mutable environment
/// and registry authority stays behind this handle so every publication turn
/// is coupled to retirement settlement.
pub const Session = enum(usize) {
    consumed = 0,
    _,

    const BlockingMutationTurn = struct {
        scheduler: *scheduler_api.Scheduler,

        fn deinit(self: *BlockingMutationTurn) void {
            self.scheduler.settleRootRetirement();
            self.* = undefined;
        }
    };

    fn coreState(self: *const Session) *SessionCore {
        std.debug.assert(self.* != .consumed);
        const erased: *OpaqueSessionCore = @ptrFromInt(@intFromEnum(self.*));
        return @ptrCast(@alignCast(erased));
    }
    pub fn init(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, null, null, .default);
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
        return initFull(allocator, arguments, output, null, null, null, .default);
    }
    pub fn initWithHost(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        io: std.Io,
        output: *std.Io.Writer,
        diagnostics: *std.Io.Writer,
        ecl_path: ?[]const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, diagnostics, io, ecl_path, .default);
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
        const scheduler_config = config.schedulerConfig();
        scheduler_config.validate() catch return error.OutOfMemory;
        const host_owner = try allocator.create(heap.HostOwner);
        host_owner.* = .init(allocator);
        const release_domain = host_owner.domain();
        errdefer {
            host_owner.cleanup().drain();
            allocator.destroy(host_owner);
        }
        var environment = try env.Env.init(host_owner.cleanup());
        errdefer environment.deinit();
        var building = environment.beginCoreBuild();
        try prims.install(&building);
        var registry = try modules.Registry.init(host_owner.cleanup());
        errdefer registry.deinit();
        var archive = try spans.SpanArchive.init(host_owner.cleanup());
        errdefer archive.deinit();
        var bootstrap_cancelled: std.atomic.Value(bool) = .init(false);
        prelude.install(host_owner.cleanup(), &building, &registry, &archive, &bootstrap_cancelled) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPrelude => @panic("embedded prelude is invalid"),
        };
        const owned_ecl_path = if (ecl_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_ecl_path) |path| allocator.free(path);
        var argv = heap.OwnedValue.init(
            release_domain,
            try argumentsValue(allocator, release_domain, arguments),
        );
        errdefer argv.deinit();
        const core = try allocator.create(SessionCore);
        errdefer allocator.destroy(core);
        const scheduler = try scheduler_api.Scheduler.init(host_owner.cleanup(), scheduler_config);
        core.* = .{
            .host_owner = host_owner,
            .environment = environment,
            .registry = registry,
            .archive = archive,
            .output = output,
            .diagnostics = diagnostics,
            .host_io = host_io,
            .ecl_path = owned_ecl_path,
            .arguments = argv.take(),
            .console = console_api.Console.init(output, diagnostics),
            .scheduler = scheduler,
            .root_tasks = undefined,
        };
        core.root_tasks = scheduler_api.TaskScope.init(core.scheduler.worker());
        core.scheduler.attachRetirement();
        return @enumFromInt(@intFromPtr(core));
    }
    pub fn deinit(self: *Session) void {
        const core = self.coreState();
        const allocator = core.allocator();
        const host = core.host_owner.cleanup();
        core.scheduler.deinit(&core.root_tasks);
        if (core.root_scope) |root_scope| root_scope.retire();
        for (core.stack.items) |item| core.releaseDomain().releaseValue(item);
        core.stack.deinit(core.allocator());
        core.releaseDomain().releaseValue(core.arguments);
        if (core.ecl_path) |path| core.allocator().free(path);
        core.registry.deinit();
        core.environment.deinit();
        core.archive.deinit();
        host.drain();
        allocator.destroy(core.host_owner);
        allocator.destroy(core);
        self.* = .consumed;
    }
    pub fn runUnit(
        self: *Session,
        source_name: []const u8,
        source: []const u8,
    ) error{OutOfMemory}!UnitOutcome {
        const core = self.coreState();
        var mutation_turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer mutation_turn.deinit();
        if (core.root_scope == null)
            core.root_scope = try core.environment.createSessionRoot(core.allocator());
        var diag: reader.Diag = .{};
        const read_result = reader.read(core.host_owner.cleanup(), source_name, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => {
                var parse_error = machine.EclErr.init(.parse, diag.text());
                defer parse_error.retire(core.releaseDomain());
                const location = spans.LocatedSpan{
                    .source_name = source_name,
                    .span = diag.span,
                };
                return .{ .err = try machine.errorValue(
                    core.allocator(),
                    core.releaseDomain(),
                    &parse_error,
                    &.{},
                    location,
                ) };
            },
        };
        switch (read_result) {
            .incomplete => |incomplete| return .{ .incomplete = incomplete },
            .complete => |complete| {
                var parsed = complete;
                defer parsed.deinit();
                return self.executeParsed(parsed.borrow());
            },
        }
    }
    fn executeParsed(
        self: *Session,
        parsed: *reader.Parsed,
    ) error{OutOfMemory}!UnitOutcome {
        const core = self.coreState();
        var root = heap.OwnedValue.init(
            core.releaseDomain(),
            try list.fromValuesGeneric(core.allocator(), parsed.values()),
        );
        defer root.deinit();
        const root_header = root.borrow().list;
        try core.archive.absorb(parsed, root.borrow());
        _ = root.take();
        var checkpoint = try heap.OwnedValueBuffer.init(core.releaseDomain(), core.stack.items.len);
        defer checkpoint.deinit();
        for (core.stack.items) |item| checkpoint.appendBorrowed(item);
        var unit = machine.Unit.init(
            core.allocator(),
            core.releaseDomain(),
            core.moduleAccess(),
            core.stack,
            &core.environment,
            &core.archive,
            core.output,
            core.arguments,
            &core.cancelled,
        );
        unit.registry = &core.registry;
        unit.diagnostics = core.diagnostics;
        unit.host_io = core.host_io;
        unit.ecl_path = core.ecl_path;
        unit.idiom_mode = core.idiom_mode;
        unit.phrase_recognizer = idioms.tryApply;
        unit.console = &core.console;
        unit.scheduler = core.scheduler.worker();
        unit.task_scope = &core.root_tasks;
        unit.is_root_unit = true;
        unit.execution_scope = core.root_scope.?;
        core.stack = .empty;
        defer {
            core.stack = unit.takeStack();
            core.last_max_frames = unit.max_frames;
            core.last_polls = unit.polls;
            core.requested_exit = unit.exit_status;
            core.last_idiom_hits = unit.idiom_hits;
            unit.deinit();
        }
        core.scheduler.runRoot(&unit, root_header) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint.values());
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint.values());
                return .{ .err = unit.takeError().? };
            },
        };
        return .ok;
    }
    pub fn stackDisplay(self: *const Session) error{OutOfMemory}![]u8 {
        const core = self.coreState();
        var allocating = std.Io.Writer.Allocating.init(core.allocator());
        defer allocating.deinit();
        for (self.coreState().stack.items, 0..) |item, index| {
            if (index > 0) allocating.writer.writeByte(' ') catch return error.OutOfMemory;
            printer.printWithAllocator(core.allocator(), item, &allocating.writer) catch
                return error.OutOfMemory;
        }
        return allocating.toOwnedSlice();
    }
    pub fn writeOutput(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.coreState().console.lockOutput() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    /// Releases a value returned by this Session into its reclamation domain.
    /// The value must not be used afterward; traversal remains scheduler-owned.
    pub fn release(self: *Session, item: Value) void {
        self.coreState().releaseDomain().releaseValue(item);
    }
    pub fn hostAllocator(self: *const Session) std.mem.Allocator {
        return self.coreState().allocator();
    }
    pub fn stackItems(self: *const Session) []const Value {
        return self.coreState().stack.items;
    }
    pub fn pushBorrowed(self: *Session, item: Value) error{OutOfMemory}!void {
        const core = self.coreState();
        heap.retainValue(item);
        core.stack.append(core.allocator(), item) catch |err| {
            core.releaseDomain().releaseValue(item);
            return err;
        };
    }
    pub fn pushOwned(self: *Session, item: Value) error{OutOfMemory}!void {
        const core = self.coreState();
        core.stack.append(core.allocator(), item) catch |err| {
            core.releaseDomain().releaseValue(item);
            return err;
        };
    }
    pub fn requestCancellation(self: *Session) void {
        self.coreState().cancelled.store(true, .release);
    }
    pub fn clearCancellation(self: *Session) void {
        self.coreState().cancelled.store(false, .release);
    }
    pub fn setIdiomMode(self: *Session, mode: machine.IdiomMode) void {
        self.coreState().idiom_mode = mode;
    }
    pub fn requestedExit(self: *const Session) ?u8 {
        return self.coreState().requested_exit;
    }
    pub fn lastMaxFrames(self: *const Session) usize {
        return self.coreState().last_max_frames;
    }
    pub fn lastPolls(self: *const Session) u64 {
        return self.coreState().last_polls;
    }
    pub fn lastIdiomHits(self: *const Session) u64 {
        return self.coreState().last_idiom_hits;
    }
    pub fn writeOutputLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.coreState().console.lockOutput() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.writeByte('\n') catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    pub fn writeDiagnostics(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.coreState().console.lockDiagnostics() orelse return error.WriteFailed;
        defer lease.deinit();
        lease.writer.writeAll(bytes) catch return error.WriteFailed;
        lease.writer.flush() catch return error.WriteFailed;
    }
    pub fn writeDiagnosticsLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        var lease = self.coreState().console.lockDiagnostics() orelse return error.WriteFailed;
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
        const core = self.coreState();
        var mutation_turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer mutation_turn.deinit();
        return core.registry.registerNative(name, definitions);
    }
    pub fn define(
        self: *Session,
        name: intern.NamespaceName,
        publication: env.TopPublication,
    ) error{OutOfMemory}!void {
        const core = self.coreState();
        var mutation_turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer mutation_turn.deinit();
        return core.environment.define(name, publication);
    }
    pub fn schedulerWorkerThreadCount(self: *const Session) usize {
        return self.coreState().scheduler.workerThreadCount();
    }
    pub fn schedulerTimerThreadCount(self: *const Session) usize {
        return self.coreState().scheduler.timerThreadCount();
    }
    pub fn schedulerTimerEntryCount(self: *Session) usize {
        return self.coreState().scheduler.timerEntryCount();
    }
};
fn restoreCheckpoint(unit: *machine.Unit, checkpoint: []const Value) void {
    unit.restoreStackBorrowedAssumeCapacity(checkpoint);
}
fn argumentsValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    arguments: []const []const u8,
) error{OutOfMemory}!Value {
    const items = try allocator.alloc(Value, arguments.len);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |item| releases.releaseValue(item);
    for (arguments) |argument| {
        items[initialized] = try machine.stringValue(allocator, releases, argument);
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
    session.release(failed);
    try std.testing.expectEqual(@as(usize, 1), session.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), session.stackItems()[0].int);
    const consumed = (try session.runUnit("<test>", "pop missing")).err;
    session.release(consumed);
    try std.testing.expectEqual(@as(usize, 1), session.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), session.stackItems()[0].int);
    try std.testing.expect((try session.runUnit("<test>", "double")) == .ok);
    try std.testing.expectEqual(@as(i64, 20), session.stackItems()[0].int);
}
test "parse diagnostics become parse error dicts" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    const error_value = (try session.runUnit("broken.ecl", "1 ]")).err;
    defer session.release(error_value);
    try std.testing.expectEqualStrings("parse", try dictSymbol(allocator, error_value, "kind"));
}
test "source-defined failures retain provenance after their unit" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("defs.ecl", "(1 0 /) 'boom def")) == .ok);
    const error_value = (try session.runUnit("call.ecl", "boom")).err;
    defer session.release(error_value);
    const rendered = try printer.toOwnedString(allocator, error_value);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"defs.ecl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'word '/") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'trace ['/ 'boom]") != null);
    const runtime_error = (try session.runUnit(
        "assembled.ecl",
        "1 0 (/) cons cons call",
    )).err;
    defer session.release(runtime_error);
    const runtime_rendered = try printer.toOwnedString(allocator, runtime_error);
    defer allocator.free(runtime_rendered);
    try std.testing.expect(std.mem.indexOf(u8, runtime_rendered, "'source") == null);
}
