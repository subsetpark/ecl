//! Persistent calculator session with transactional stack units.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const native_module = @import("native_module.zig");
const machine = @import("machine.zig");
const prims = @import("prims.zig");
const prelude = @import("prelude.zig");
const idioms = @import("idioms.zig");
const printer = @import("print.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");
const reflection = @import("reflection.zig");
const scheduler_api = @import("scheduler.zig");
const console_api = @import("console.zig");
const pkg_lock = @import("pkg_lock.zig");
const session_options = @import("session_options");
const stdlib = @import("stdlib.zig");
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

/// Deterministic HTTPS verification inputs. `ca_file` is borrowed on input;
/// the Session copies it and owns the copy for the lifetime of every Unit.
pub const TlsTrustOverride = struct {
    ca_file: []const u8,
    now: std.Io.Timestamp,
};

/// The host services a Session inherits from its process. Grouping them
/// nominally keeps adding one — an environment snapshot, a standard-input
/// mode — from turning `init` into a positional checklist whose arguments
/// only differ by type.
pub const Host = struct {
    io: std.Io,
    output: *std.Io.Writer,
    diagnostics: *std.Io.Writer,
    tls_trust: ?TlsTrustOverride = null,
    ecl_path: ?[]const u8 = null,
    /// Borrowed directory from which project discovery begins. Null disables
    /// ambient project metadata reads for library Sessions.
    project_start: ?[]const u8 = null,
    /// Borrowed name/value pairs; the Session owns its own copy.
    environ: []const machine.Environ.Entry = &.{},
    /// Whether the process has already claimed stdin as the program source.
    standard_input: machine.StandardInput.Availability = .data,
};

const CompletionBacking = struct {
    allocator: std.mem.Allocator,
    candidates: [][]const u8,
    bytes: []u8,
};

/// Owned rendered completion candidates. Candidate slices borrow from this
/// result and remain valid independently of the Session until `deinit`.
pub const CompletionSet = enum(usize) {
    consumed = 0,
    empty = 1,
    _,

    fn fromBacking(owned: *CompletionBacking) CompletionSet {
        return @enumFromInt(@intFromPtr(owned));
    }
    fn backing(self: CompletionSet) *CompletionBacking {
        std.debug.assert(self != .consumed and self != .empty);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn items(self: CompletionSet) []const []const u8 {
        std.debug.assert(self != .consumed);
        return if (self == .empty) &.{} else self.backing().candidates;
    }
    pub fn deinit(self: *CompletionSet) void {
        if (self.* == .consumed) return;
        if (self.* != .empty) {
            const owned = self.backing();
            const allocator = owned.allocator;
            allocator.free(owned.bytes);
            allocator.free(owned.candidates);
            allocator.destroy(owned);
        }
        self.* = .consumed;
    }
};

const RenderedTextBacking = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
};

/// Opaque owned rendering. Bytes remain valid independently of the Session
/// until `deinit`, while the allocator and reclamation root stay private.
pub const RenderedText = enum(usize) {
    consumed = 0,
    empty = 1,
    _,

    fn fromOwned(allocator: std.mem.Allocator, owned_bytes: []u8) error{OutOfMemory}!RenderedText {
        if (owned_bytes.len == 0) {
            allocator.free(owned_bytes);
            return .empty;
        }
        const owned = allocator.create(RenderedTextBacking) catch |err| {
            allocator.free(owned_bytes);
            return err;
        };
        owned.* = .{ .allocator = allocator, .bytes = owned_bytes };
        return @enumFromInt(@intFromPtr(owned));
    }
    fn backing(self: RenderedText) *RenderedTextBacking {
        std.debug.assert(self != .consumed and self != .empty);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn bytes(self: RenderedText) []const u8 {
        std.debug.assert(self != .consumed);
        return if (self == .empty) "" else self.backing().bytes;
    }
    pub fn deinit(self: *RenderedText) void {
        if (self.* == .consumed) return;
        if (self.* != .empty) {
            const owned = self.backing();
            const allocator = owned.allocator;
            allocator.free(owned.bytes);
            allocator.destroy(owned);
        }
        self.* = .consumed;
    }
};

fn renderDisplayBlocks(
    allocator: std.mem.Allocator,
    items: []const Value,
) error{OutOfMemory}!std.ArrayList(printer.DisplayBlock) {
    var blocks: std.ArrayList(printer.DisplayBlock) = .empty;
    errdefer releaseDisplayBlocks(allocator, &blocks);
    try blocks.ensureTotalCapacityPrecise(allocator, items.len);
    for (items) |item| {
        const text = try printer.toOwnedDisplayString(allocator, item);
        errdefer allocator.free(text);
        blocks.appendAssumeCapacity(try printer.measureDisplayBlock(text));
    }
    return blocks;
}

fn releaseDisplayBlocks(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(printer.DisplayBlock),
) void {
    for (blocks.items) |block| allocator.free(block.text);
    blocks.deinit(allocator);
}

/// One owned copy of the host environment. Names and values live in a single
/// byte block so teardown is two frees regardless of how large the
/// environment was.
const EnvironSnapshot = struct {
    entries: []machine.Environ.Entry,
    bytes: ?[]u8,

    fn capture(
        allocator: std.mem.Allocator,
        source: []const machine.Environ.Entry,
    ) error{OutOfMemory}!EnvironSnapshot {
        if (source.len == 0) return .{ .entries = &.{}, .bytes = null };
        var total: usize = 0;
        for (source) |entry| {
            total = std.math.add(usize, total, entry.name.len) catch return error.OutOfMemory;
            total = std.math.add(usize, total, entry.value.len) catch return error.OutOfMemory;
        }
        const bytes = try allocator.alloc(u8, total);
        errdefer allocator.free(bytes);
        const entries = try allocator.alloc(machine.Environ.Entry, source.len);
        var offset: usize = 0;
        for (source, entries) |entry, *copy| {
            const name_end = offset + entry.name.len;
            @memcpy(bytes[offset..name_end], entry.name);
            const value_end = name_end + entry.value.len;
            @memcpy(bytes[name_end..value_end], entry.value);
            copy.* = .{
                .name = bytes[offset..name_end],
                .value = bytes[name_end..value_end],
            };
            offset = value_end;
        }
        return .{ .entries = entries, .bytes = bytes };
    }
    fn deinit(self: *EnvironSnapshot, allocator: std.mem.Allocator) void {
        if (self.bytes) |bytes| allocator.free(bytes);
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = undefined;
    }
};

const SessionCore = struct {
    module_access_seal: u8 = 0,
    host_owner: *heap.HostOwner,
    environment: env.Env,
    registry: modules.Registry,
    test_authority: ?modules.TestAuthority,
    native_owner: *native_module.Owner,
    stack: std.ArrayList(Value) = .empty,
    archive_owner: spans.SpanArchiveOwner,
    archive: spans.SpanArchive,
    output: ?*std.Io.Writer,
    diagnostics: ?*std.Io.Writer,
    host_io: ?std.Io,
    tls_trust: ?machine.TlsTrust,
    ecl_path: ?[]u8,
    project_lock: ?*pkg_lock.ProjectLock,
    root_preload: RootPreloadState = .idle,
    environ: machine.Environ,
    environ_bytes: ?[]u8,
    standard_input: machine.StandardInput,
    arguments: Value,
    console: console_api.Console,
    scheduler: scheduler_api.Scheduler,
    root_tasks: scheduler_api.TaskScope,
    root_scope: ?*env.Scope = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    requested_exit: ?u8 = null,
    last_max_frames: usize = 0,
    last_polls: u64 = 0,
    last_root_execution_metrics: if (machine.root_execution_metrics_enabled) machine.RootExecutionMetrics else void = if (machine.root_execution_metrics_enabled) .{} else {},
    idiom_mode: machine.IdiomMode = .automatic,
    native_diagnostics: bool = false,
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
const RootPreloadState = union(enum) {
    idle,
    cursor: pkg_lock.RootModuleCursor,
    complete,
};

pub const RootPreloadProgress = union(enum) {
    pending,
    complete,
    no_project,
    invalid: []const u8,
    err: Value,
};

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
        return initFull(allocator, arguments, null, null, .default, .application);
    }
    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, config, .application);
    }
    /// The output writer must outlive the session.
    pub fn initWithOutput(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: *std.Io.Writer,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, null, .default, .application);
    }
    /// Every writer and slice in `host` must outlive the session; the
    /// environment snapshot is copied.
    pub fn initWithHost(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        host: Host,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, host.output, host, .default, .application);
    }
    pub fn initWithHostConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        host: Host,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, host.output, host, config, .application);
    }

    /// Create the closed execution domain used by `ecl test` and trusted host
    /// test harnesses. Ordinary constructors never mint test capabilities.
    pub fn initTestWithHostConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        host: Host,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, host.output, host, config, .testing);
    }

    pub fn initTest(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, .default, .testing);
    }

    const ExecutionDomain = enum { application, testing };
    fn initFull(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: ?*std.Io.Writer,
        host: ?Host,
        config: Config,
        domain: ExecutionDomain,
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
        var environment = try env.Env.init(host_owner);
        errdefer environment.deinit();
        var building = environment.beginCoreBuild();
        try prims.install(&building);
        try building.installSeed("seed");
        var registry = try modules.Registry.init(host_owner.cleanup());
        errdefer registry.deinit();
        var test_authority = if (domain == .testing)
            @as(?modules.TestAuthority, try registry.createTestAuthority())
        else
            null;
        errdefer if (test_authority) |*authority| authority.deinit();
        const native_owner = try native_module.Owner.init(host_owner.cleanup());
        errdefer native_owner.closeCalls().settle().deinit();
        // A Session builds exactly one archive on its own reclamation root, so
        // the provenance owner is always free here; treating the refusal as an
        // allocation failure keeps the public Session error set unchanged.
        var archive_owner = spans.SpanArchiveOwner.init(host_owner) catch |err| switch (err) {
            error.OutOfMemory, error.CodeProvenanceTaken => return error.OutOfMemory,
        };
        errdefer archive_owner.deinit();
        const archive = archive_owner.view();
        var bootstrap_cancelled: std.atomic.Value(bool) = .init(false);
        prelude.install(host_owner.cleanup(), &building, &registry, &archive_owner, &bootstrap_cancelled) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPrelude => @panic("embedded prelude is invalid"),
        };
        const owned_ecl_path = if (host) |services|
            if (services.ecl_path) |path| try allocator.dupe(u8, path) else null
        else
            null;
        errdefer if (owned_ecl_path) |path| allocator.free(path);
        const owned_tls_trust: ?machine.TlsTrust = if (host) |services|
            if (services.tls_trust) |trust| .{
                .ca_file = try allocator.dupe(u8, trust.ca_file),
                .now = trust.now,
            } else null
        else
            null;
        errdefer if (owned_tls_trust) |trust| allocator.free(trust.ca_file);
        const owned_project_lock = if (host) |services|
            if (services.project_start) |start| try pkg_lock.ProjectLock.discover(
                host_owner.cleanup(),
                services.io,
                start,
                .{
                    .ecl_cache = environValue(services.environ, "ECL_CACHE"),
                    .xdg_cache_home = environValue(services.environ, "XDG_CACHE_HOME"),
                    .home = environValue(services.environ, "HOME"),
                },
            ) else null
        else
            null;
        errdefer if (owned_project_lock) |project_lock| project_lock.deinit();
        var snapshot = try EnvironSnapshot.capture(
            allocator,
            if (host) |services| services.environ else &.{},
        );
        errdefer snapshot.deinit(allocator);
        var argv = heap.OwnedValue.init(
            release_domain,
            try argumentsValue(allocator, release_domain, arguments),
        );
        errdefer argv.deinit();
        const core = try allocator.create(SessionCore);
        errdefer allocator.destroy(core);
        const scheduler = try scheduler_api.Scheduler.init(host_owner.cleanup(), scheduler_config);
        const root_tasks = scheduler_api.TaskScope.init(scheduler.worker());
        core.* = .{
            .host_owner = host_owner,
            .environment = environment,
            .registry = registry,
            .test_authority = test_authority,
            .native_owner = native_owner,
            .archive_owner = archive_owner,
            .archive = archive,
            .output = output,
            .diagnostics = if (host) |services| services.diagnostics else null,
            .host_io = if (host) |services| services.io else null,
            .tls_trust = owned_tls_trust,
            .ecl_path = owned_ecl_path,
            .project_lock = owned_project_lock,
            .environ = .{ .entries = snapshot.entries },
            .environ_bytes = snapshot.bytes,
            .standard_input = .init(
                if (host) |services| services.standard_input else .program_source,
            ),
            .arguments = argv.take(),
            .console = console_api.Console.init(
                output,
                if (host) |services| services.diagnostics else null,
            ),
            .scheduler = scheduler,
            .root_tasks = root_tasks,
        };
        core.scheduler.attachRetirement();
        test_authority = null;
        return @enumFromInt(@intFromPtr(core));
    }
    pub fn deinit(self: *Session) void {
        const core = self.coreState();
        const allocator = core.allocator();
        const host = core.host_owner.cleanup();
        const closing_native_owner = core.native_owner.closeCalls();
        core.scheduler.deinit(&core.root_tasks);
        if (core.root_scope) |root_scope| root_scope.retire();
        for (core.stack.items) |item| core.releaseDomain().releaseValue(item);
        core.stack.deinit(core.allocator());
        core.releaseDomain().releaseValue(core.arguments);
        if (core.ecl_path) |path| core.allocator().free(path);
        if (core.tls_trust) |trust| core.allocator().free(trust.ca_file);
        if (core.project_lock) |project_lock| project_lock.deinit();
        var snapshot = EnvironSnapshot{
            .entries = @constCast(core.environ.entries),
            .bytes = core.environ_bytes,
        };
        snapshot.deinit(core.allocator());
        if (core.test_authority) |*authority| authority.deinit();
        core.registry.deinit();
        core.archive_owner.deinit();
        // Registry teardown retires images, and an image clears its Env-owned
        // scope-label cell as it goes. Drain that work before the Env releases
        // the cells, so no deferred image release ever touches freed memory.
        host.drain();
        core.environment.deinit();
        // Environment and registry retirement own native image pins. Drain
        // them while the issuing Owner is still alive, then let that host-only
        // authority tear down descriptors/images and drain their ECL values.
        host.drain();
        const settled_native_owner = closing_native_owner.settle();
        host.drain();
        settled_native_owner.deinit();
        // Last, and only here. A parked anchor is named by a scope cell that
        // holds no reference to it, so it stays valid until execution has
        // provably stopped -- which `scheduler.deinit` at the top of this
        // function guarantees, ahead of every teardown below it.
        host.reclaimTombstones(modules.destroyParkedAnchor);
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
        var checkpoint = try heap.OwnedValueBuffer.init(core.releaseDomain(), core.stack.items.len);
        defer checkpoint.deinit();
        for (core.stack.items) |item| checkpoint.appendBorrowed(item);
        var unit = initRootUnit(core);
        core.stack = .empty;
        defer finishRootUnit(core, &unit);
        machine.initializeSource(&unit, source_name, source) catch {
            restoreCheckpoint(&unit, checkpoint.values());
            return error.OutOfMemory;
        };
        core.scheduler.runInitializedRoot(&unit) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint.values());
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint.values());
                return .{ .err = unit.takeError().? };
            },
        };
        if (unit.takeSourceIncomplete()) |incomplete|
            return .{ .incomplete = incomplete };
        return .ok;
    }

    fn initRootUnit(core: *SessionCore) machine.Unit {
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
        unit.inherited = .{
            .registry = &core.registry,
            .test_observation = if (core.test_authority) |authority| authority.observation() else null,
            .test_execution = if (core.test_authority) |authority| authority.execution() else null,
            .native_loader = core.native_owner.loader(),
            .native_diagnostics = core.native_diagnostics,
            .diagnostics = core.diagnostics,
            .console = &core.console,
            .host_io = core.host_io,
            .tls_trust = core.tls_trust,
            .ecl_path = core.ecl_path,
            .project_lock = core.project_lock,
            .environ = &core.environ,
            .standard_input = &core.standard_input,
            .idiom_mode = core.idiom_mode,
            .phrase_recognizer = idioms.tryApply,
        };
        unit.scheduler = core.scheduler.worker();
        unit.task_scope = &core.root_tasks;
        unit.is_root_unit = true;
        unit.execution_scope = core.root_scope.?;
        return unit;
    }

    fn finishRootUnit(core: *SessionCore, unit: *machine.Unit) void {
        core.stack = unit.takeStack();
        core.last_max_frames = unit.max_frames;
        core.last_polls = unit.polls;
        if (comptime machine.root_execution_metrics_enabled)
            core.last_root_execution_metrics = unit.root_execution_metrics;
        core.requested_exit = unit.exitStatus();
        core.last_idiom_hits = unit.idiom_hits;
        unit.deinit();
    }

    /// Resolve one already validated module name through the ordinary loader
    /// without invoking an export. Errors stay reified so the CLI can report
    /// the same language diagnostic an ordinary qualified lookup would.
    pub fn loadModule(
        self: *Session,
        name: intern.ModuleName,
    ) error{OutOfMemory}!UnitOutcome {
        const core = self.coreState();
        var acquisition = core.registry.acquireCursor(name);
        defer acquisition.deinit();
        if (poll.drive(?modules.GenerationLease, &acquisition, .{})) |generation| {
            var lease = generation;
            lease.deinit();
            return .ok;
        }
        if (core.root_scope == null)
            core.root_scope = try core.environment.createSessionRoot(core.allocator());
        var root = heap.OwnedValue.init(
            core.releaseDomain(),
            try list.fromValuesGeneric(core.allocator(), &.{}),
        );
        defer root.deinit();
        var checkpoint = try heap.OwnedValueBuffer.init(core.releaseDomain(), core.stack.items.len);
        defer checkpoint.deinit();
        for (core.stack.items) |item| checkpoint.appendBorrowed(item);
        var unit = initRootUnit(core);
        core.stack = .empty;
        defer finishRootUnit(core, &unit);
        try machine.initialize(&unit, root.borrow().list, .empty);
        var evaluator = machine.Machine{ .unit = &unit };
        evaluator.loadModuleOnly(name) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint.values());
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint.values());
                return .{ .err = unit.takeError().? };
            },
        };
        core.scheduler.runInitializedRoot(&unit) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint.values());
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint.values());
                return .{ .err = unit.takeError().? };
            },
        };
        restoreCheckpoint(&unit, checkpoint.values());
        return .ok;
    }

    /// Advance root-project preload by at most one catalog observation and one
    /// ordinary module load. Cursor authority remains inside SessionCore, so a
    /// host cannot retain a ProjectLock borrow past Session teardown.
    pub fn advanceRootPreload(self: *Session) error{OutOfMemory}!RootPreloadProgress {
        const core = self.coreState();
        if (core.root_preload == .idle) {
            const project_lock = core.project_lock orelse {
                core.root_preload = .complete;
                return .no_project;
            };
            core.root_preload = .{ .cursor = project_lock.rootModuleCursor() };
        }
        return switch (core.root_preload) {
            .idle => unreachable,
            .complete => .complete,
            .cursor => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => result: {
                    cursor.deinit();
                    core.root_preload = .complete;
                    break :result .complete;
                },
                .invalid => |message| result: {
                    cursor.deinit();
                    core.root_preload = .complete;
                    break :result .{ .invalid = message };
                },
                .item => |module_name| switch (try self.loadModule(module_name)) {
                    .ok => .pending,
                    .err => |failure| .{ .err = failure },
                    .incomplete => .{ .invalid = "root project module loader returned incomplete source" },
                },
            },
        };
    }

    /// Completion intentionally suppresses loader failures, but it still uses
    /// the same public module-load path so there is one ownership contract for
    /// the produced error value.
    fn loadModuleForObservation(
        self: *Session,
        namespace: []const u8,
    ) error{OutOfMemory}!bool {
        const name = intern.internModuleName(namespace) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => return false,
        };
        return switch (try self.loadModule(name)) {
            .ok => true,
            .incomplete => false,
            .err => |failure| result: {
                self.release(failure);
                break :result false;
            },
        };
    }
    pub fn stackDisplay(self: *const Session) error{OutOfMemory}!RenderedText {
        const core = self.coreState();
        const allocator = core.allocator();
        var blocks = try renderDisplayBlocks(allocator, core.stack.items);
        defer releaseDisplayBlocks(allocator, &blocks);
        return .fromOwned(allocator, try printer.toOwnedStackDisplayString(allocator, blocks.items));
    }
    pub fn renderValue(self: *const Session, item: Value) error{OutOfMemory}!RenderedText {
        const allocator = self.coreState().allocator();
        return .fromOwned(allocator, try printer.toOwnedString(allocator, item));
    }
    /// Runs one blocking observation turn without exposing environment,
    /// registry, or reclamation authority. The rendered result owns no lease
    /// and can therefore outlive this Session.
    pub fn completionCandidates(
        self: *Session,
        prefix: []const u8,
    ) error{OutOfMemory}!CompletionSet {
        const dot = lastDot(prefix);
        if (dot) |separator| {
            if (separator == 0) return .empty;
            if (!try self.loadModuleForObservation(prefix[0..separator])) return .empty;
        }
        const core = self.coreState();
        var turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer turn.deinit();
        var found = poll.ChunkList(u32).init(core.allocator());
        defer found.retire(core.releaseDomain());

        if (dot) |separator| {
            const namespace_bytes = prefix[0..separator];
            const word_prefix = prefix[separator + 1 ..];
            // Observation has already resolved the cold module through the
            // ordinary loader, so completion sees one authoritative published
            // generation regardless of transport or prior execution.
            if (lookupInterned(namespace_bytes)) |namespace_id| {
                if (intern.moduleName(namespace_id) catch null) |module_name| {
                    var acquisition = core.registry.acquireCursor(module_name);
                    defer acquisition.deinit();
                    if (poll.drive(?modules.GenerationLease, &acquisition, .{})) |generation| {
                        var generation_lease = generation;
                        defer generation_lease.deinit();
                        var names = generation_lease.publicNameCursor();
                        defer names.deinit();
                        while (true) switch (names.advance()) {
                            .pending => {},
                            .complete => break,
                            .item => |name| if (std.mem.startsWith(
                                u8,
                                intern.get(name),
                                word_prefix,
                            )) try found.append(name),
                        };
                        return materializeCompletion(core.allocator(), &found, namespace_bytes);
                    }
                }
            }
            return .empty;
        }

        const root: reflection.VisibleNameRoot = if (core.root_scope) |scope|
            .{ .scope = scope }
        else
            .{ .environment = core.environment.sessionView() };
        var visible = reflection.VisibleNameCursor.init(
            root,
            core.environment.coreView(),
        );
        defer visible.deinit();
        while (true) switch (visible.advance()) {
            .pending => {},
            .complete => break,
            .item => |name| if (std.mem.startsWith(u8, intern.get(name), prefix))
                try found.append(name),
        };
        // An embedded module resolves on first mention, so it is a real
        // completion before anything has loaded it. The registry knows only
        // the ones already published, which made the stdlib appear to exist
        // only after you had already typed its name in full once.
        const embedded = stdlib.names();
        var embedded_ids: [embedded.len]?u32 = @splat(null);
        for (embedded, &embedded_ids) |name, *slot| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            slot.* = intern.intern(name) catch null;
        }
        var namespaces = core.registry.namespaceCursor();
        defer namespaces.deinit();
        while (true) switch (namespaces.advance()) {
            .pending => {},
            .complete => break,
            .item => |name| {
                const id = name;
                // A registered stdlib name is offered once, by the registry.
                for (&embedded_ids) |*slot| {
                    if (slot.* == id) slot.* = null;
                }
                if (std.mem.startsWith(u8, intern.get(id), prefix)) try found.append(id);
            },
        };
        for (embedded_ids) |slot| if (slot) |id| try found.append(id);
        return materializeCompletion(core.allocator(), &found, null);
    }
    pub fn writeOutput(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeOutput(bytes, false);
    }
    /// Capabilities the REPL editor is given. It never receives the Session,
    /// the console, a writer, or a byte slice it could turn into a control
    /// sequence; the operations it can perform are the ones on these types.
    ///
    /// Both are rooted in the heap-stable core rather than in this handle,
    /// which is explicitly movable. A capability that captured the handle's
    /// address would dangle the moment the Session value was moved.
    pub fn editorTerminal(self: *const Session) EditorTerminal {
        return @enumFromInt(@intFromEnum(self.*));
    }
    pub fn completionObserve(self: *const Session) CompletionObserve {
        return @enumFromInt(@intFromEnum(self.*));
    }
    /// Releases a value returned by this Session into its reclamation domain.
    /// The value must not be used afterward; traversal remains scheduler-owned.
    pub fn release(self: *Session, item: Value) void {
        self.coreState().releaseDomain().releaseValue(item);
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
    pub fn setNativeDiagnostics(self: *Session, enabled: bool) void {
        self.coreState().native_diagnostics = enabled;
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
        return self.coreState().console.writeOutput(bytes, true);
    }
    pub fn writeDiagnostics(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeDiagnostics(bytes, false);
    }
    pub fn writeDiagnosticsLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeDiagnostics(bytes, true);
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

/// Observation surface present only in a separately compiled counter artifact.
/// Ordinary runtime and test modules receive an empty namespace, not a
/// representation-inspection method on Session.
pub const RootExecutionObservation = if (machine.root_execution_metrics_enabled) struct {
    pub fn last(runtime: *const Session) machine.RootExecutionMetrics {
        return runtime.coreState().last_root_execution_metrics;
    }
} else struct {};

/// Terminal authority for the line editor: prompts, named effects, candidate
/// lists, and — only where the row can actually be measured — single-row
/// redraw. There is no operation that emits program output or accepts
/// caller-supplied control bytes, so their absence is a fact about the type
/// rather than a rule someone has to remember.
///
/// The payload is the heap-stable core, which is what makes the capability
/// outlive moves of the Session handle that minted it.
pub const EditorTerminal = enum(usize) {
    _,

    fn owner(self: EditorTerminal) Session {
        return @enumFromInt(@intFromEnum(self));
    }
    /// Single-row editing needs a measured row. Null means the caller must use
    /// the canonical reader; no width is ever invented on its behalf.
    pub fn row(self: EditorTerminal) ?RowTerminal {
        return switch (console_api.geometry()) {
            .known => |columns| .{ .terminal = self, .columns = columns },
            .unavailable => null,
        };
    }
    pub fn writePrompt(self: EditorTerminal, prompt: console_api.Prompt) error{WriteFailed}!void {
        var session = self.owner();
        return session.coreState().console.writePrompt(prompt);
    }
    pub fn signal(self: EditorTerminal, action: console_api.TerminalAction) error{WriteFailed}!void {
        var session = self.owner();
        return session.coreState().console.signal(action);
    }
    pub fn writeCandidates(
        self: EditorTerminal,
        candidates: []const []const u8,
    ) error{WriteFailed}!void {
        var session = self.owner();
        return session.coreState().console.writeCandidates(candidates);
    }
};

/// Row drawing, reachable only from a measured row width.
pub const RowTerminal = struct {
    terminal: EditorTerminal,
    columns: console_api.Columns,

    pub fn redraw(
        self: RowTerminal,
        prompt: console_api.Prompt,
        view: console_api.DisplayView,
    ) error{WriteFailed}!void {
        var session = self.terminal.owner();
        return session.coreState().console.redraw(self.columns, prompt, view);
    }
};

/// Name observation for completion. It can render matching names and nothing
/// else: no environment, registry, intern, or reclamation authority.
pub const CompletionObserve = enum(usize) {
    _,

    pub fn candidates(
        self: CompletionObserve,
        prefix: []const u8,
    ) error{OutOfMemory}!CompletionSet {
        var session: Session = @enumFromInt(@intFromEnum(self));
        return session.completionCandidates(prefix);
    }
};

const SessionAuthorityPosition = enum { parameter, result };

fn sessionTypeExposesAuthority(
    comptime T: type,
    comptime depth: u8,
    comptime position: SessionAuthorityPosition,
) bool {
    if (T == env.BindingLease or T == modules.GenerationLease) return true;
    if (position == .result and
        (T == std.mem.Allocator or
            T == std.Io or
            T == std.Io.Writer or
            T == SessionCore or
            T == OpaqueSessionCore or
            T == heap.HostOwner or
            T == heap.ReleaseDomain or
            T == env.Env or
            T == env.EnvironmentView or
            T == modules.Registry or
            T == machine.Unit or
            T == scheduler_api.Scheduler or
            T == console_api.Console))
        return true;
    if (depth == 0) return false;
    return switch (@typeInfo(T)) {
        .optional => |optional| sessionTypeExposesAuthority(optional.child, depth - 1, position),
        .pointer => |pointer| sessionTypeExposesAuthority(pointer.child, depth - 1, position),
        .array => |array| sessionTypeExposesAuthority(array.child, depth - 1, position),
        .vector => |vector| sessionTypeExposesAuthority(vector.child, depth - 1, position),
        .error_union => |error_union| sessionTypeExposesAuthority(error_union.payload, depth - 1, position),
        .@"struct" => |structure| exposed: {
            inline for (structure.fields) |field|
                if (sessionTypeExposesAuthority(field.type, depth - 1, position)) break :exposed true;
            break :exposed false;
        },
        .@"union" => |union_info| exposed: {
            inline for (union_info.fields) |field|
                if (sessionTypeExposesAuthority(field.type, depth - 1, position)) break :exposed true;
            break :exposed false;
        },
        else => false,
    };
}

fn environValue(entries: []const machine.Environ.Entry, name: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

comptime {
    @setEvalBranchQuota(4_000);
    for (std.meta.declarations(Session)) |declaration| {
        const declaration_info = @typeInfo(@TypeOf(@field(Session, declaration.name)));
        if (declaration_info != .@"fn") continue;
        const function = declaration_info.@"fn";
        for (function.params) |parameter| {
            const parameter_type = parameter.type orelse continue;
            if (sessionTypeExposesAuthority(parameter_type, 8, .parameter))
                @compileError("public Session parameter exposes owner authority: " ++ declaration.name);
        }
        const return_type = function.return_type orelse continue;
        if (sessionTypeExposesAuthority(return_type, 8, .result))
            @compileError("public Session return exposes owner authority: " ++ declaration.name);
    }
}

fn lastDot(bytes: []const u8) ?usize {
    var cursor = intern.lastDotCursor(bytes);
    return poll.drive(?usize, &cursor, .{});
}

fn lookupInterned(bytes: []const u8) ?u32 {
    var cursor = intern.lookupCursor(bytes);
    return poll.drive(?u32, &cursor, .{});
}

fn materializeCompletion(
    allocator: std.mem.Allocator,
    found: *poll.ChunkList(u32),
    qualifier: ?[]const u8,
) error{OutOfMemory}!CompletionSet {
    if (found.count == 0) return .empty;
    var cursor = try reflection.SortedUniqueNameCursor.init(allocator, found);
    defer cursor.deinit();
    var sorted = try poll.driveFallible(
        reflection.SortedUniqueNames,
        &cursor,
        .{256},
    );
    defer sorted.deinit(allocator);
    const names = sorted.items();

    var byte_count: usize = 0;
    for (names) |name| {
        byte_count = std.math.add(usize, byte_count, intern.get(name).len) catch
            return error.OutOfMemory;
        if (qualifier) |namespace| {
            byte_count = std.math.add(usize, byte_count, namespace.len + 1) catch
                return error.OutOfMemory;
        }
    }
    const backing = try allocator.create(CompletionBacking);
    errdefer allocator.destroy(backing);
    const candidates = try allocator.alloc([]const u8, names.len);
    errdefer allocator.free(candidates);
    const bytes = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(bytes);
    var written: usize = 0;
    for (names, 0..) |name, candidate_index| {
        const start = written;
        if (qualifier) |namespace| {
            @memcpy(bytes[written..][0..namespace.len], namespace);
            written += namespace.len;
            bytes[written] = '.';
            written += 1;
        }
        const atom = intern.get(name);
        @memcpy(bytes[written..][0..atom.len], atom);
        written += atom.len;
        candidates[candidate_index] = bytes[start..written];
    }
    backing.* = .{ .allocator = allocator, .candidates = candidates, .bytes = bytes };
    return .fromBacking(backing);
}

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
    var display = try session.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("7", display.bytes());
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
test "parse diagnostics preserve source names beyond the inline error budget" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    const source_name = [_]u8{'p'} ** 512;
    const error_value = switch (try session.runUnit(&source_name, "1 ]")) {
        .err => |failure| failure,
        .ok, .incomplete => return error.ExpectedParseFailure,
    };
    defer session.release(error_value);
    const dict = @import("dict.zig");
    const data_key = try intern.intern("data");
    const data_value = (try dict.symbolField(allocator, error_value, data_key)).?;
    const source_key = try intern.intern("source");
    const source_value = (try dict.symbolField(
        allocator,
        data_value,
        source_key,
    )).?;
    const rendered = try printer.toOwnedString(allocator, source_value);
    defer allocator.free(rendered);
    const expected = try std.fmt.allocPrint(allocator, "\"{s}\"", .{source_name});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, rendered);
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
