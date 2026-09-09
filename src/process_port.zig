//! Scope-owned POSIX subprocess controller behind opaque ECL port values.
//!
//! Blocking kernel pipe and wait operations run only on host-owned controller
//! threads. Scheduler workers interact through bounded queues and the generic
//! readiness capabilities in `external.zig`; live-process ownership belongs to
//! a TaskScope membership, never to the language value reference count.

const std = @import("std");
const builtin = @import("builtin");
const external = @import("external.zig");
const controllers = @import("port_controller.zig");
const transfers = @import("port_transfer.zig");
const heap = @import("heap.zig");
const scheduler_api = @import("scheduler.zig");
const value = @import("value.zig");

const Value = value.Value;

fn blockingIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const EnvironmentEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const ExecutablePolicy = union(enum) {
    exact: []const []const u8,
    unrestricted,
};

/// Borrowed host policy. `ProcessOwner.init` validates and copies every slice.
pub const ProcessPolicy = struct {
    executables: ExecutablePolicy,
    initial_cwd: ?[]const u8 = null,
    cwd_root: ?[]const u8 = null,
    inherit_environment: bool = false,
    max_live_ports: usize = 32,
    stdin_capacity: usize = 64 * 1024,
    stdout_capacity: usize = 64 * 1024,
    stderr_capacity: usize = 64 * 1024,
    max_stdout_capture: usize = 8 * 1024 * 1024,
    max_stderr_capture: usize = 8 * 1024 * 1024,

    pub fn unrestricted() ProcessPolicy {
        return .{ .executables = .unrestricted };
    }
};

pub const ProcessSpec = struct {
    executable: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    environment: []const EnvironmentEntry = &.{},
};

pub const Termination = union(enum) {
    exited: u8,
    signaled: u32,
    stopped: u32,
    unknown: u32,
};

pub const Stream = enum { stdout, stderr };

pub const ReadProgress = union(enum) {
    pending,
    data: usize,
    eof,
    io,
};

pub const WriteProgress = union(enum) {
    pending,
    written: usize,
    io,
};

pub const SpawnError = error{
    OutOfMemory,
    Unsupported,
    Denied,
    InvalidSpec,
    LiveLimit,
    ScopeClosing,
    Io,
};
pub const PolicyError = error{ OutOfMemory, InvalidPolicy };

const OwnedPolicy = struct {
    executables: union(enum) {
        exact: [][]u8,
        unrestricted,
    },
    cwd_root: ?[]u8,
    initial_cwd: ?[]u8,
    max_live_ports: usize,
    stdin_capacity: usize,
    stdout_capacity: usize,
    stderr_capacity: usize,
    max_stdout_capture: usize,
    max_stderr_capture: usize,

    fn init(allocator: std.mem.Allocator, policy: ProcessPolicy) PolicyError!OwnedPolicy {
        if (policy.max_live_ports == 0 or policy.stdin_capacity == 0 or
            policy.stdout_capacity == 0 or policy.stderr_capacity == 0 or
            policy.max_stdout_capture == 0 or policy.max_stderr_capture == 0)
            return error.InvalidPolicy;
        if (policy.cwd_root) |root| if (!cleanAbsolutePath(root)) return error.InvalidPolicy;
        if (policy.initial_cwd) |cwd| if (!cleanAbsolutePath(cwd)) return error.InvalidPolicy;
        if (policy.cwd_root) |root| if (policy.initial_cwd) |cwd|
            if (!pathWithin(root, cwd)) return error.InvalidPolicy;
        switch (policy.executables) {
            .exact => |paths| for (paths) |path| {
                if (!cleanAbsolutePath(path)) return error.InvalidPolicy;
            },
            .unrestricted => {},
        }
        var result: OwnedPolicy = .{
            .executables = .unrestricted,
            .cwd_root = null,
            .initial_cwd = null,
            .max_live_ports = policy.max_live_ports,
            .stdin_capacity = policy.stdin_capacity,
            .stdout_capacity = policy.stdout_capacity,
            .stderr_capacity = policy.stderr_capacity,
            .max_stdout_capture = policy.max_stdout_capture,
            .max_stderr_capture = policy.max_stderr_capture,
        };
        errdefer result.deinit(allocator);
        result.executables = switch (policy.executables) {
            .unrestricted => .unrestricted,
            .exact => |paths| exact: {
                const copies = try allocator.alloc([]u8, paths.len);
                var initialized: usize = 0;
                errdefer {
                    for (copies[0..initialized]) |path| allocator.free(path);
                    allocator.free(copies);
                }
                for (paths, copies) |path, *copy| {
                    copy.* = try allocator.dupe(u8, path);
                    initialized += 1;
                }
                break :exact .{ .exact = copies };
            },
        };
        if (policy.cwd_root) |root| result.cwd_root = try allocator.dupe(u8, root);
        if (policy.initial_cwd) |cwd| result.initial_cwd = try allocator.dupe(u8, cwd);
        return result;
    }

    fn deinit(self: *OwnedPolicy, allocator: std.mem.Allocator) void {
        switch (self.executables) {
            .exact => |paths| {
                for (paths) |path| allocator.free(path);
                allocator.free(paths);
            },
            .unrestricted => {},
        }
        if (self.cwd_root) |root| allocator.free(root);
        if (self.initial_cwd) |cwd| allocator.free(cwd);
        self.* = undefined;
    }

    fn allowsExecutable(self: *const OwnedPolicy, executable: []const u8) bool {
        return switch (self.executables) {
            .unrestricted => true,
            .exact => |paths| for (paths) |allowed| {
                if (std.mem.eql(u8, executable, allowed)) break true;
            } else false,
        };
    }
};

const OwnedEnvironment = struct {
    entries: []EnvironmentEntry,

    fn init(
        allocator: std.mem.Allocator,
        inherit: bool,
        source: []const EnvironmentEntry,
    ) PolicyError!OwnedEnvironment {
        if (!inherit or source.len == 0) return .{ .entries = &.{} };
        for (source) |entry| if (!std.process.Environ.Map.validateKeyForPut(entry.name) or
            std.mem.indexOfScalar(u8, entry.value, 0) != null)
            return error.InvalidPolicy;
        const entries = try allocator.alloc(EnvironmentEntry, source.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.value);
            }
            allocator.free(entries);
        }
        for (source, entries) |entry, *copy| {
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            const entry_value = try allocator.dupe(u8, entry.value);
            copy.* = .{ .name = name, .value = entry_value };
            initialized += 1;
        }
        return .{ .entries = entries };
    }

    fn deinit(self: *OwnedEnvironment, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Session-owned authority and immutable ambient inputs. Units never receive
/// this owner directly; Patch 4 installs a narrow opaque access facade.
pub const ProcessOwner = struct {
    host: *const heap.HostCleanup,
    service_live: std.atomic.Value(usize) = .init(0),
    instance: *@import("module_bindings.zig").Identity,
    allocator: std.mem.Allocator,
    io: std.Io,
    policy: OwnedPolicy,
    environment: OwnedEnvironment,
    executor: *controllers.Owner,
    live: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),

    pub fn init(
        host: *const heap.HostCleanup,
        io: std.Io,
        policy: ProcessPolicy,
        environment: []const EnvironmentEntry,
    ) PolicyError!ProcessOwner {
        const allocator = host.allocator();
        // Backend jobs plus the shared wait, control, and shutdown lanes.
        const jobs = std.math.mul(usize, policy.max_live_ports, 9) catch return error.InvalidPolicy;
        const capacity = std.math.add(usize, jobs, 1) catch return error.InvalidPolicy;
        var effective_policy = policy;
        const captured_cwd = if (policy.initial_cwd == null)
            std.process.currentPathAlloc(io, allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidPolicy,
            }
        else
            null;
        defer if (captured_cwd) |cwd| allocator.free(cwd);
        if (captured_cwd) |cwd| effective_policy.initial_cwd = cwd;
        var owned_policy = try OwnedPolicy.init(allocator, effective_policy);
        errdefer owned_policy.deinit(allocator);
        var owned_environment = try OwnedEnvironment.init(
            allocator,
            policy.inherit_environment,
            environment,
        );
        errdefer owned_environment.deinit(allocator);
        const instance = try @import("module_bindings.zig").Identity.create(allocator);
        errdefer instance.release();
        return .{
            .host = host,
            .instance = instance,
            .allocator = allocator,
            .io = io,
            .executor = try controllers.Owner.init(allocator, capacity),
            .policy = owned_policy,
            .environment = owned_environment,
        };
    }

    pub fn deinit(self: *ProcessOwner) void {
        self.executor.deinit();
        self.instance.release();
        std.debug.assert(self.live.load(.acquire) == 0);
        self.environment.deinit(self.allocator);
        self.policy.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn stdoutCaptureLimit(self: *const ProcessOwner) usize {
        return self.policy.max_stdout_capture;
    }

    pub fn access(self: *ProcessOwner) *external.ProcessAccess {
        return @ptrCast(self);
    }

    pub fn stderrCaptureLimit(self: *const ProcessOwner) usize {
        return self.policy.max_stderr_capture;
    }

    fn resourceAllocator(self: *ProcessOwner) std.mem.Allocator {
        return self.allocator;
    }
    fn reserveService(self: *ProcessOwner) error{LiveLimit}!void {
        var observed = self.service_live.load(.acquire);
        while (observed < self.policy.max_live_ports) {
            if (self.service_live.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual| observed = actual else return;
        }
        return error.LiveLimit;
    }
    fn releaseService(self: *ProcessOwner) void {
        _ = self.service_live.fetchSub(1, .acq_rel);
    }
    fn reserveResource(self: *ProcessOwner) error{LiveLimit}!void {
        if (!self.reserveLive()) return error.LiveLimit;
    }
    fn reserveLive(self: *ProcessOwner) bool {
        var observed = self.live.load(.acquire);
        while (observed < self.policy.max_live_ports) {
            if (self.live.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual|
                observed = actual
            else
                return true;
        }
        return false;
    }

    fn releaseLive(self: *ProcessOwner) void {
        const old = self.live.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
    }

    pub fn spawn(
        self: *ProcessOwner,
        _: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
        spec: ProcessSpec,
    ) SpawnError!Value {
        if (comptime !backendSupported()) return error.Unsupported;
        try self.validateSpec(spec);
        self.executor.access().prepare() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Closed => error.Io,
        };
        const cell = try Resource.create(self, .{spec}, ProcessCell.initializeAllocation);
        errdefer cell.releasePort();
        cell.controllers.start(.{scope}, ProcessCell.prepareStartup, supervisorThreadMain, ProcessCell.failBeforeStart) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeClosing => error.ScopeClosing,
            error.Io, error.Closed => error.Io,
        };

        const port = @import("port_resource.zig").Resource.create(ProcessCell, .direct, cell.identity, cell) catch {
            cell.kill();
            return error.OutOfMemory;
        };
        return port;
    }

    fn validateSpec(self: *const ProcessOwner, spec: ProcessSpec) SpawnError!void {
        if (spec.executable.len == 0 or !std.fs.path.isAbsolute(spec.executable) or
            std.mem.indexOfScalar(u8, spec.executable, 0) != null)
            return error.InvalidSpec;
        if (!self.policy.allowsExecutable(spec.executable)) return error.Denied;
        for (spec.args) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null)
            return error.InvalidSpec;
        for (spec.environment) |entry| {
            if (!std.process.Environ.Map.validateKeyForPut(entry.name) or
                std.mem.indexOfScalar(u8, entry.value, 0) != null)
                return error.InvalidSpec;
        }
        if (spec.cwd) |cwd| {
            if (!cleanAbsolutePath(cwd))
                return error.InvalidSpec;
            if (self.policy.cwd_root) |root| if (!pathWithin(root, cwd)) return error.Denied;
        }
    }
};

/// The factory owns live capacity with the cell allocation through rollback
/// or terminal retirement. Backend code never receives a quota token.
const Resource = transfers.Resource(ProcessCell, ProcessOwner, ProcessOwner.resourceAllocator, ProcessOwner.reserveResource, ProcessOwner.releaseLive);

fn ownerFromAccess(access_value: *external.ProcessAccess) *ProcessOwner {
    return @ptrCast(@alignCast(access_value));
}

/// Borrow the library identity already owned by the Session's process service.
pub fn registeredInstance(access_value: *external.ProcessAccess) *@import("module_bindings.zig").Identity {
    return ownerFromAccess(access_value).instance;
}

fn pathWithin(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    if (root.len != 0 and std.fs.path.isSep(root[root.len - 1])) return true;
    return std.fs.path.isSep(candidate[root.len]);
}

fn cleanAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or !std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, 0) != null)
        return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component|
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

pub fn backendSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

const wait_api = struct {
    extern "c" fn waitid(
        id_type: c_int,
        id: c_uint,
        info: *std.c.siginfo_t,
        options: c_int,
    ) c_int;
};

fn observeLeaderTermination(group: *OwnedGroup) error{Io}!void {
    const pid_selector: c_int = switch (builtin.os.tag) {
        .freebsd, .dragonfly => 0,
        .openbsd => 2,
        .linux, .macos, .netbsd => 1,
        else => unreachable,
    };
    const options: c_int = switch (builtin.os.tag) {
        .linux => std.os.linux.W.EXITED | std.os.linux.W.NOWAIT,
        .macos => 0x00000004 | 0x00000020,
        .openbsd => 0x04 | 0x10,
        .freebsd, .netbsd, .dragonfly => std.c.W.EXITED | std.c.W.NOWAIT,
        else => unreachable,
    };
    // SAFETY: waitid initializes this output buffer, and its contents are not
    // inspected before or after the call.
    var info: std.c.siginfo_t = undefined;
    while (true) {
        const result = wait_api.waitid(pid_selector, @intCast(group.child.id.?), &info, options);
        if (result == 0) return;
        switch (std.posix.errno(result)) {
            .INTR => continue,
            else => return error.Io,
        }
    }
}

const Ring = @import("byte_ring.zig").Ring;

const ProcessPhase = union(enum) {
    constructing,
    running,
    closing: enum { terminate, kill },
    terminal: Termination,
    reaped: Termination,
};

const EscalationId = enum(u64) { _ };

const OwnedGroup = struct {
    child: std.process.Child,
    pgid: std.posix.pid_t,
    leader_observed: bool = false,

    const SignalResult = enum { sent, absent, denied };

    fn send(self: *OwnedGroup, signal_value: std.posix.SIG) error{Io}!SignalResult {
        std.posix.kill(-self.pgid, signal_value) catch |err| {
            return switch (err) {
                error.ProcessNotFound => .absent,
                error.PermissionDenied => .denied,
                else => error.Io,
            };
        };
        return .sent;
    }
};

const GroupState = union(enum) {
    running: *OwnedGroup,
    grace: struct {
        group: *OwnedGroup,
        escalation: EscalationId,
    },
    kill_issued: *OwnedGroup,
    retired: Termination,
};

const Writers = controllers.Lane(ProcessCell, .writer, .{ .retain = ProcessCell.retainRef, .release = ProcessCell.releaseRef, .write = ProcessCell.writeTurnLocked, .notify = ProcessCell.notifyWritersLocked, .source = ProcessCell.writerSource });

const InputState = enum {
    open,
    closing,
    closed_cleanly,
    broken,

    fn terminal(self: InputState) bool {
        return switch (self) {
            .open, .closing => false,
            .closed_cleanly, .broken => true,
        };
    }
};

const ControllerGroup = controllers.Group(ProcessCell, void, .{ .retain = ProcessCell.retainRef, .retireLocked = ProcessCell.retireExecutionLocked, .ownership = processOwnership, .release = ProcessCell.releaseRef });

const ProcessTransfer = transfers.ScopeTransfer(ProcessCell, processOwnership, processLive);
fn processOwnership(cell: *ProcessCell) *external.Ownership {
    return &cell.ownership;
}
fn processLive(cell: *ProcessCell) bool {
    return cell.group_state != .retired;
}

pub const WritePermit = Writers.Writer;

const readiness_stdout: u64 = 1;
const readiness_stderr: u64 = 2;
const readiness_terminal: u64 = 3;

pub const ProcessCell = struct {
    pub fn resourceInitialization(_: *ProcessCell) @import("port_resource.zig").Initialization {
        return .ready;
    }
    pub fn resourceAllocator(self: *ProcessCell) std.mem.Allocator {
        return self.allocator;
    }
    pub fn resourceClose(self: *ProcessCell) void {
        self.kill();
    }
    pub fn resourceJoined(self: *ProcessCell) bool {
        return self.termination() != null;
    }
    pub fn resourceSource(self: *ProcessCell) external.ReadinessSource {
        return self.waitSource();
    }
    pub fn resourceShutdown(self: *ProcessCell) @import("port_resource.zig").Shutdown {
        self.terminate();
        return if (self.termination() != null) .ready else .pending;
    }
    instance: *@import("module_bindings.zig").Identity,
    allocator: std.mem.Allocator,
    io: std.Io,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    phase: ProcessPhase = .constructing,
    group_state: GroupState,
    next_escalation: u64 = 1,
    controllers: *ControllerGroup,
    ownership: external.Ownership = .provisional,
    stdin: Ring,
    stdout: Ring,
    stderr: Ring,
    input: InputState = .open,
    stdin_done: bool = false,
    stdout_phase: @import("port_bytes.zig").StreamPhase(void) = .open,
    stderr_phase: @import("port_bytes.zig").StreamPhase(void) = .open,
    io_failed: bool = false,
    discard_outputs: bool = false,
    stdout_reader_active: bool = false,
    stderr_reader_active: bool = false,
    writers: Writers,
    waits: external.WaitList(ProcessCell) = .{},

    fn initializeAllocation(cell: *ProcessCell, owner: *ProcessOwner, spec: ProcessSpec) SpawnError!void {
        var environment = std.process.Environ.Map.init(owner.allocator);
        defer environment.deinit();
        for (owner.environment.entries) |entry| environment.put(entry.name, entry.value) catch
            return error.OutOfMemory;
        for (spec.environment) |entry| environment.put(entry.name, entry.value) catch
            return error.OutOfMemory;
        const argv = try owner.allocator.alloc([]const u8, spec.args.len + 1);
        defer owner.allocator.free(argv);
        argv[0] = spec.executable;
        @memcpy(argv[1..], spec.args);
        var child = std.process.spawn(owner.io, .{
            .argv = argv,
            .cwd = if (spec.cwd orelse owner.policy.initial_cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = &environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch return error.Io;
        errdefer killChildGroup(&child, owner.io);
        const group = try owner.allocator.create(OwnedGroup);
        errdefer owner.allocator.destroy(group);
        group.* = .{ .child = child, .pgid = child.id.? };
        const stdin = try owner.allocator.alloc(u8, owner.policy.stdin_capacity);
        errdefer owner.allocator.free(stdin);
        const stdout = try owner.allocator.alloc(u8, owner.policy.stdout_capacity);
        errdefer owner.allocator.free(stdout);
        const stderr = try owner.allocator.alloc(u8, owner.policy.stderr_capacity);
        errdefer owner.allocator.free(stderr);
        const execution_group = try ControllerGroup.init(owner.allocator, owner.executor.access(), cell);
        cell.* = .{
            .instance = owner.instance,
            .allocator = owner.allocator,
            .io = owner.io,
            .identity = owner.next_identity.fetchAdd(1, .monotonic),
            .group_state = .{ .running = group },
            .controllers = execution_group,
            .writers = Writers.init(&cell.mutex),
            .stdin = .{ .bytes = stdin },
            .stdout = .{ .bytes = stdout },
            .stderr = .{ .bytes = stderr },
        };
        owner.instance.retain();
    }

    fn prepareStartup(self: *ProcessCell, scope: *scheduler_api.TaskScope) error{ OutOfMemory, ScopeClosing }!void {
        try transfers.publishScope(ProcessCell, self, scope, processOwnership);
        // The scope member is linked before the supervisor exists, so a
        // cancellation walk may already have moved the phase to `closing` and
        // signalled the group. Take the lock and leave that transition in
        // place: an unconditional write here would lose it and leave the cell
        // claiming to run a process that is already being torn down. The lock
        // is released before the thread starts, so the supervisor observes
        // whichever phase won rather than waiting on this one.
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.phase) {
            .constructing => self.phase = .running,
            .running, .closing, .terminal, .reaped => {},
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn prepareGroupStartup(self: *ProcessCell, group: *scheduler_api.ExternalGroup) error{ OutOfMemory, ScopeClosing }!void {
        try transfers.publishGroup(ProcessCell, self, group, processOwnership);
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.phase == .constructing) self.phase = .running;
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn joinBackend(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        while (self.phase != .reaped) self.changed.waitUncancelable(blockingIo(), &self.mutex);
    }
    fn failBeforeStart(self: *ProcessCell) void {
        self.kill();
        std.Io.Threaded.mutexLock(&self.mutex);
        const group = switch (self.group_state) {
            .running => |group| group,
            .grace => |grace| grace.group,
            .kill_issued => |group| group,
            .retired => unreachable,
        };
        std.Io.Threaded.mutexUnlock(&self.mutex);
        group.child.kill(self.io);
        std.Io.Threaded.mutexLock(&self.mutex);
        self.group_state = .{ .retired = .{ .unknown = 0 } };
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.allocator.destroy(group);
    }

    fn retainRef(self: *ProcessCell) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(usize));
    }

    fn releaseRef(self: *ProcessCell) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        std.debug.assert(self.phase == .reaped);
        std.debug.assert(self.waits.first == null and self.writers.empty());
        self.allocator.free(self.stdin.bytes);
        self.allocator.free(self.stdout.bytes);
        self.allocator.free(self.stderr.bytes);
        self.controllers.deinit();
        self.instance.release();
        Resource.destroy(self);
    }

    fn retireExecutionLocked(self: *ProcessCell, _: controllers.Outcome(void)) void {
        Resource.retire(self);
        self.phase = .{ .reaped = self.group_state.retired };
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
    }

    pub fn releasePort(self: *ProcessCell) void {
        self.releaseRef();
    }

    pub fn prepareScopeTransfer(
        self: *ProcessCell,
        from_erased: *anyopaque,
        to_erased: *anyopaque,
    ) heap.PortTransferError!void {
        return ProcessTransfer.prepare(self, from_erased, to_erased);
    }

    pub fn commitScopeTransfer(self: *ProcessCell) void {
        ProcessTransfer.commit(self);
    }

    pub fn abortScopeTransfer(self: *ProcessCell) void {
        ProcessTransfer.abort(self);
    }

    pub fn retainReadiness(self: *ProcessCell) void {
        self.retainRef();
    }

    pub fn releaseReadiness(self: *ProcessCell) void {
        self.releaseRef();
    }

    pub fn retainExternalMember(self: *ProcessCell) void {
        self.retainRef();
    }

    pub fn releaseExternalMember(self: *ProcessCell) void {
        self.releaseRef();
    }

    pub fn cancelExternalMember(self: *ProcessCell, scope: *external.ScopeIdentity) void {
        self.controllers.with(.{ true, @as(?*external.ScopeIdentity, scope) }, ProcessCell.startGrace);
    }

    fn startGrace(self: *ProcessCell, discard: bool, scope: ?*external.ScopeIdentity) void {
        const escalation = self.beginGrace(discard, scope) orelse return;
        self.controllers.spawn(.{escalation}, escalationMain) catch {
            self.escalateKill(escalation);
        };
    }

    pub fn registerReadiness(
        self: *ProcessCell,
        key: u64,
        target: external.WakeTarget,
    ) external.RegisterError!external.RegisterResult {
        return external.WaitList(ProcessCell).register(self, key, target);
    }

    pub fn beginWrite(self: *ProcessCell) error{ OutOfMemory, Closed }!*WritePermit {
        const prepared = try self.writers.prepare(self.allocator);
        errdefer prepared.discard();
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.input != .open or self.io_failed) return error.Closed;
        return prepared.admitWriter(self, std.math.maxInt(usize)).?;
    }
    fn writeTurnLocked(self: *ProcessCell, turn: bool, bytes: []const u8) WriteProgress {
        if (self.input != .open or self.io_failed) return .io;
        if (!turn or self.stdin.free() == 0) return .pending;
        const count = @min(bytes.len, self.stdin.free());
        self.stdin.push(bytes[0..count]);
        self.changed.broadcast(blockingIo());
        return .{ .written = count };
    }
    fn writerSource(self: *ProcessCell, key: u64) external.ReadinessSource {
        return external.readinessSource(ProcessCell, self, key);
    }
    fn notifyWritersLocked(self: *ProcessCell) void {
        self.waits.notifyLocked(self);
    }

    pub fn beginRead(self: *ProcessCell, stream: Stream) error{ReaderActive}!void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const active = switch (stream) {
            .stdout => &self.stdout_reader_active,
            .stderr => &self.stderr_reader_active,
        };
        if (active.*) return error.ReaderActive;
        active.* = true;
    }

    pub fn endRead(self: *ProcessCell, stream: Stream) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (stream) {
            .stdout => self.stdout_reader_active = false,
            .stderr => self.stderr_reader_active = false,
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    pub fn readCapacity(self: *const ProcessCell, stream: Stream) usize {
        return switch (stream) {
            .stdout => self.stdout.bytes.len,
            .stderr => self.stderr.bytes.len,
        };
    }

    pub fn read(self: *ProcessCell, stream: Stream, destination: []u8) ReadProgress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const ring, const phase = switch (stream) {
            .stdout => .{ &self.stdout, self.stdout_phase },
            .stderr => .{ &self.stderr, self.stderr_phase },
        };
        if (ring.len != 0) {
            const count = ring.pop(destination);
            self.changed.broadcast(blockingIo());
            return .{ .data = count };
        }
        return switch (phase) {
            .open, .finishing => .pending,
            .eof => .eof,
            .failed => .io,
        };
    }

    pub fn readSource(self: *ProcessCell, stream: Stream) external.ReadinessSource {
        return external.readinessSource(ProcessCell, self, switch (stream) {
            .stdout => readiness_stdout,
            .stderr => readiness_stderr,
        });
    }

    pub fn waitSource(self: *ProcessCell) external.ReadinessSource {
        return external.readinessSource(ProcessCell, self, readiness_terminal);
    }

    pub fn termination(self: *ProcessCell) ?Termination {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.phase) {
            .reaped => |term| term,
            .constructing, .running, .closing, .terminal => null,
        };
    }

    pub fn closeInput(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.input == .open) self.input = .closing;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    pub fn terminate(self: *ProcessCell) void {
        self.controllers.with(.{ true, @as(?*external.ScopeIdentity, null) }, ProcessCell.startGrace);
    }

    pub fn kill(self: *ProcessCell) void {
        self.issueKill(null);
    }

    fn beginGrace(self: *ProcessCell, close_process: bool, scope: ?*external.ScopeIdentity) ?EscalationId {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (scope) |identity| if (!self.ownership.authorizesCancellation(identity)) return null;
        if (close_process) switch (self.phase) {
            .constructing, .running => self.phase = .{ .closing = .terminate },
            .closing, .terminal, .reaped => {},
        };
        const escalation: ?EscalationId = transition: switch (self.group_state) {
            .running => |group| {
                const id: EscalationId = @enumFromInt(self.next_escalation);
                self.next_escalation +%= 1;
                if (self.next_escalation == 0) @panic("process escalation identity exhausted");
                self.group_state = .{ .grace = .{ .group = group, .escalation = id } };
                const signal_result = group.send(.TERM) catch failure: {
                    self.recordSignalFailureLocked();
                    break :failure .sent;
                };
                switch (signal_result) {
                    .sent => {},
                    .absent => {
                        self.group_state = .{ .kill_issued = group };
                        break :transition null;
                    },
                    .denied => if (group.leader_observed) {
                        // Darwin reports EPERM when the pinned zombie is the
                        // group's only remaining member. A signalable live
                        // descendant makes the same-group signal succeed.
                        self.group_state = .{ .kill_issued = group };
                        break :transition null;
                    } else self.recordSignalFailureLocked(),
                }
                break :transition id;
            },
            .grace, .kill_issued, .retired => null,
        };
        if (close_process) {
            if (self.input == .open) self.input = .closing;
            self.discard_outputs = true;
            self.changed.broadcast(blockingIo());
            self.notifyReadyLocked();
        }
        return escalation;
    }

    fn issueKill(self: *ProcessCell, escalation: ?EscalationId) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        var group_to_signal: ?*OwnedGroup = null;
        switch (self.group_state) {
            .running => |group| if (escalation == null) {
                self.group_state = .{ .kill_issued = group };
                group_to_signal = group;
            },
            .grace => |grace| if (escalation == null or escalation.? == grace.escalation) {
                self.group_state = .{ .kill_issued = grace.group };
                group_to_signal = grace.group;
            },
            .kill_issued, .retired => {},
        }
        if (group_to_signal) |group| {
            const signal_result = group.send(.KILL) catch failure: {
                self.recordSignalFailureLocked();
                break :failure .sent;
            };
            if (signal_result == .denied and !group.leader_observed)
                self.recordSignalFailureLocked();
            self.changed.broadcast(blockingIo());
        } else if (escalation != null) return;
        switch (self.phase) {
            .constructing, .running => {
                self.phase = .{ .closing = .kill };
            },
            .closing => |closing| if (closing == .terminate) {
                self.phase = .{ .closing = .kill };
            },
            .terminal, .reaped => {},
        }
        if (self.input == .open) self.input = .closing;
        self.discard_outputs = true;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
    }

    fn beginPostLeaderCleanup(self: *ProcessCell) void {
        self.controllers.with(.{ false, @as(?*external.ScopeIdentity, null) }, ProcessCell.startGrace);
    }

    fn escalateKill(self: *ProcessCell, escalation: EscalationId) void {
        self.issueKill(escalation);
    }

    fn waitForFinalGroupSignal(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        while (self.group_state == .grace)
            self.changed.waitUncancelable(blockingIo(), &self.mutex);
    }

    fn groupLocked(self: *ProcessCell) ?*OwnedGroup {
        return switch (self.group_state) {
            .running => |group| group,
            .grace => |grace| grace.group,
            .kill_issued => |group| group,
            .retired => null,
        };
    }

    fn recordSignalFailureLocked(self: *ProcessCell) void {
        self.io_failed = true;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
    }

    fn recordIoFailure(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        self.io_failed = true;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    pub fn readyLocked(self: *ProcessCell, key: u64) bool {
        return switch (key) {
            readiness_stdout => self.stdout.len != 0 or self.stdout_phase.terminal(),
            readiness_stderr => self.stderr.len != 0 or self.stderr_phase.terminal(),
            readiness_terminal => self.phase == .reaped,
            else => {
                const node: *WritePermit = @ptrFromInt(key);
                return self.writeReadyLocked(node);
            },
        };
    }

    fn writeReadyLocked(self: *ProcessCell, node: *const WritePermit) bool {
        return !node.linked() or (node.active() and self.stdin.free() != 0) or
            self.input != .open or self.io_failed;
    }

    pub fn wakeReasonLocked(self: *ProcessCell, _: u64) external.Wake {
        return if (self.io_failed) .io else .ready;
    }

    fn notifyReadyLocked(self: *ProcessCell) void {
        self.waits.notifyLocked(self);
    }

    fn supervisorMain(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        const group = self.groupLocked().?;
        const stdin_file = group.child.stdin.?;
        const stdout_file = group.child.stdout.?;
        const stderr_file = group.child.stderr.?;
        group.child.stdin = null;
        group.child.stdout = null;
        group.child.stderr = null;
        std.Io.Threaded.mutexUnlock(&self.mutex);

        self.startIoThread(stdinThreadMain, stdin_file, .stdin) catch self.failIoThread(stdin_file, .stdin);
        self.startIoThread(stdoutThreadMain, stdout_file, .stdout) catch self.failIoThread(stdout_file, .stdout);
        self.startIoThread(stderrThreadMain, stderr_file, .stderr) catch self.failIoThread(stderr_file, .stderr);

        var leader_observed = true;
        observeLeaderTermination(group) catch {
            leader_observed = false;
        };
        const translated: Termination = if (leader_observed) translated: {
            std.Io.Threaded.mutexLock(&self.mutex);
            group.leader_observed = true;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            // Keep the terminated leader waitable while the consuming group
            // transition issues its final signal. The zombie pins the numeric
            // process-group identity against reuse until the reap below.
            self.beginPostLeaderCleanup();
            self.waitForFinalGroupSignal();
            const term = group.child.wait(self.io) catch {
                self.issueKill(null);
                group.child.kill(self.io);
                self.recordIoFailure();
                break :translated .{ .unknown = 0 };
            };
            break :translated translateTerm(term);
        } else translated: {
            self.issueKill(null);
            group.child.kill(self.io);
            self.recordIoFailure();
            break :translated .{ .unknown = 0 };
        };

        std.Io.Threaded.mutexLock(&self.mutex);
        self.phase = .{ .terminal = translated };
        if (self.input == .open) self.input = .closing;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);

        std.Io.Threaded.mutexLock(&self.mutex);
        while (!self.stdin_done or !self.stdout_phase.terminal() or !self.stderr_phase.terminal())
            self.changed.waitUncancelable(blockingIo(), &self.mutex);
        self.group_state = .{ .retired = translated };
        std.Io.Threaded.mutexUnlock(&self.mutex);

        self.allocator.destroy(group);
    }

    const IoThread = enum { stdin, stdout, stderr };

    fn startIoThread(
        self: *ProcessCell,
        comptime function: anytype,
        file: std.Io.File,
        kind: IoThread,
    ) error{Io}!void {
        _ = kind;
        self.controllers.spawn(.{file}, function) catch return error.Io;
    }

    fn failIoThread(self: *ProcessCell, file: std.Io.File, kind: IoThread) void {
        file.close(self.io);
        std.Io.Threaded.mutexLock(&self.mutex);
        self.io_failed = true;
        switch (kind) {
            .stdin => {
                self.stdin_done = true;
                self.input = .broken;
            },
            .stdout => self.stdout_phase.fail({}),
            .stderr => self.stderr_phase.fail({}),
        }
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.kill();
    }

    fn stdinMain(self: *ProcessCell, file: std.Io.File) void {
        defer file.close(self.io);
        var broken = false;
        var block: [4096]u8 = undefined;
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (self.stdin.len == 0 and self.input == .open)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            if (self.stdin.len == 0 and self.input != .open) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break;
            }
            const count = self.stdin.pop(&block);
            self.notifyReadyLocked();
            std.Io.Threaded.mutexUnlock(&self.mutex);
            writeFileAll(file, self.io, block[0..count]) catch {
                broken = true;
                break;
            };
        }
        std.Io.Threaded.mutexLock(&self.mutex);
        self.input = if (broken) .broken else .closed_cleanly;
        self.stdin_done = true;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn stdoutMain(self: *ProcessCell, file: std.Io.File) void {
        self.outputMain(file, .stdout);
    }

    fn stderrMain(self: *ProcessCell, file: std.Io.File) void {
        self.outputMain(file, .stderr);
    }

    fn outputMain(self: *ProcessCell, file: std.Io.File, stream: Stream) void {
        defer file.close(self.io);
        var block: [4096]u8 = undefined;
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            const ring = switch (stream) {
                .stdout => &self.stdout,
                .stderr => &self.stderr,
            };
            while (ring.free() == 0 and !self.discard_outputs)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            const discarding = self.discard_outputs;
            const capacity = if (discarding) block.len else @min(block.len, ring.free());
            std.Io.Threaded.mutexUnlock(&self.mutex);
            const count = file.readStreaming(self.io, &.{block[0..capacity]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.Io.Threaded.mutexLock(&self.mutex);
                    self.io_failed = true;
                    std.Io.Threaded.mutexUnlock(&self.mutex);
                    break;
                },
            };
            if (count == 0) continue;
            std.Io.Threaded.mutexLock(&self.mutex);
            if (!discarding) ring.push(block[0..count]);
            self.notifyReadyLocked();
            std.Io.Threaded.mutexUnlock(&self.mutex);
        }
        std.Io.Threaded.mutexLock(&self.mutex);
        const phase = switch (stream) {
            .stdout => &self.stdout_phase,
            .stderr => &self.stderr_phase,
        };
        if (self.io_failed) phase.fail({}) else phase.complete();
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }
};

fn escalationMain(
    _: *controllers.Execution,
    cell: *ProcessCell,
    escalation: EscalationId,
) void {
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(250),
        .clock = .awake,
    };
    duration.sleep(cell.io) catch |err| switch (err) {
        error.Canceled => {},
    };
    cell.escalateKill(escalation);
}

fn supervisorThreadMain(_: *controllers.Execution, cell: *ProcessCell) void {
    cell.supervisorMain();
}

fn stdinThreadMain(_: *controllers.Execution, cell: *ProcessCell, file: std.Io.File) void {
    cell.stdinMain(file);
}

fn stdoutThreadMain(_: *controllers.Execution, cell: *ProcessCell, file: std.Io.File) void {
    cell.stdoutMain(file);
}

fn stderrThreadMain(_: *controllers.Execution, cell: *ProcessCell, file: std.Io.File) void {
    cell.stderrMain(file);
}

fn writeFileAll(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    var written: usize = 0;
    while (written != bytes.len)
        written += try std.Io.File.writeStreaming(file, io, &.{}, &.{bytes[written..]}, 1);
}

fn killChildGroup(child: *std.process.Child, io: std.Io) void {
    if (child.id) |pid| std.posix.kill(-pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound, error.PermissionDenied => {},
        else => {},
    };
    child.kill(io);
}

fn translateTerm(term: std.process.Child.Term) Termination {
    return switch (term) {
        .exited => |status| .{ .exited = status },
        .signal => |signal_value| .{ .signaled = @intFromEnum(signal_value) },
        .stopped => |signal_value| .{ .stopped = @intFromEnum(signal_value) },
        .unknown => |status| .{ .unknown = status },
    };
}

pub fn fromValue(port: Value) ?*ProcessCell {
    if (port != .port) return null;
    if (serviceFromValue(port)) |service| return service.adapter.backend;
    return @import("port_resource.zig").Resource.project(ProcessCell, port);
}

test "process policy rejects ambient and relative executable selection before spawn" {
    const denied = ProcessPolicy{ .executables = .{ .exact = &.{"/allowed/program"} } };
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var owner = try ProcessOwner.init(host.cleanup(), std.testing.io, denied, &.{});
    defer owner.deinit();
    try std.testing.expectError(error.InvalidSpec, owner.validateSpec(.{ .executable = "program" }));
    try std.testing.expectError(error.Denied, owner.validateSpec(.{ .executable = "/other/program" }));
    try owner.validateSpec(.{ .executable = "/allowed/program" });
}

test "process: provisional rollback retains capacity until cancellation setup retires" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        @import("process_fixture_options").process_exe,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var owner = try ProcessOwner.init(host.cleanup(), std.testing.io, .{
        .executables = .unrestricted,
        .max_live_ports = 1,
    }, &.{});
    defer owner.deinit();
    var runtime_scheduler = try scheduler_api.Scheduler.init(host.cleanup(), .cooperative, .host);
    runtime_scheduler.attachRetirement();
    var scope = scheduler_api.TaskScope.init(runtime_scheduler.worker());
    defer runtime_scheduler.deinit(&scope);

    // Exercise the production provisional factory before starting its root job.
    const cell = try Resource.create(&owner, .{ProcessSpec{ .executable = fixture_path, .args = &.{ "exit", "7" } }}, ProcessCell.initializeAllocation);
    defer cell.releasePort();
    const Probe = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        thread: ?std.Thread = null,
        fn blocked(_: *ProcessCell, self: *@This()) void {
            self.entered.set(blockingIo());
            self.release.waitUncancelable(blockingIo());
        }
        fn activity(target: *ProcessCell, self: *@This()) void {
            target.controllers.with(.{self}, blocked);
        }
        fn prepare(target: *ProcessCell, target_scope: *scheduler_api.TaskScope, self: *@This()) error{ OutOfMemory, ScopeClosing, Io }!void {
            try transfers.publishScope(ProcessCell, target, target_scope, processOwnership);
            self.thread = std.Thread.spawn(.{}, activity, .{ target, self }) catch return error.Io;
            self.entered.waitUncancelable(blockingIo());
            return error.Io;
        }
    };
    var probe: Probe = .{};
    defer {
        probe.release.set(blockingIo());
        if (probe.thread) |thread| thread.join();
    }
    try std.testing.expectError(error.Io, cell.controllers.start(.{ &scope, &probe }, Probe.prepare, supervisorThreadMain, ProcessCell.failBeforeStart));
    try std.testing.expect(cell.termination() == null);
    const spec: ProcessSpec = .{ .executable = fixture_path, .args = &.{ "exit", "7" } };
    try std.testing.expectError(error.LiveLimit, owner.spawn(runtime_scheduler.worker(), &scope, spec));
    probe.release.set(blockingIo());
    probe.thread.?.join();
    probe.thread = null;
    try std.testing.expect(cell.termination() != null);
    const next = try owner.spawn(runtime_scheduler.worker(), &scope, spec);
    host.domain().releaseValue(next);
}

test "dormant controller reaps a direct child before scope detachment" {
    const fixture_options = @import("process_fixture_options");
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        fixture_options.process_exe,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    const Target = struct {
        event: std.Io.Event = .unset,
        refs: std.atomic.Value(usize) = .init(0),

        pub fn retainExternalWake(self: *@This()) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }
        pub fn releaseExternalWake(self: *@This()) void {
            _ = self.refs.fetchSub(1, .release);
        }
        pub fn wakeExternal(self: *@This(), _: external.Wake) void {
            self.event.set(std.testing.io);
        }
    };

    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var runtime_scheduler = try scheduler_api.Scheduler.init(host.cleanup(), .cooperative, .host);
    runtime_scheduler.attachRetirement();
    var root_scope = scheduler_api.TaskScope.init(runtime_scheduler.worker());
    defer runtime_scheduler.deinit(&root_scope);
    var owner = try ProcessOwner.init(
        host.cleanup(),
        std.testing.io,
        .unrestricted(),
        &.{},
    );
    defer owner.deinit();

    const port = try owner.spawn(
        runtime_scheduler.worker(),
        &root_scope,
        .{ .executable = fixture_path, .args = &.{ "exit", "7" } },
    );
    defer host.domain().releaseValue(port);
    const process = fromValue(port).?;
    var target: Target = .{};
    var source = process.waitSource();
    defer source.deinit();
    var registration: ?external.ReadinessRegistration = null;
    switch (try source.register(external.wakeTarget(Target, &target))) {
        .ready => {},
        .registered => |registered| {
            registration = registered;
            target.event.waitUncancelable(std.testing.io);
        },
    }
    if (registration) |registered| {
        var owned = registered;
        owned.cancel();
    }
    try std.testing.expectEqual(Termination{ .exited = 7 }, process.termination().?);
    try std.testing.expectEqual(@as(usize, 0), target.refs.load(.acquire));
}

test "scope shutdown cancels a blocked controller independently of port references" {
    const fixture_options = @import("process_fixture_options");
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        fixture_options.process_exe,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var runtime_scheduler = try scheduler_api.Scheduler.init(host.cleanup(), .cooperative, .host);
    runtime_scheduler.attachRetirement();
    var root_scope = scheduler_api.TaskScope.init(runtime_scheduler.worker());
    var owner = try ProcessOwner.init(
        host.cleanup(),
        std.testing.io,
        .unrestricted(),
        &.{},
    );

    const port = try owner.spawn(
        runtime_scheduler.worker(),
        &root_scope,
        .{ .executable = fixture_path, .args = &.{"block"} },
    );
    host.domain().releaseValue(port);
    runtime_scheduler.deinit(&root_scope);
    owner.deinit();
}

const resource_api = @import("port_resource.zig");
const port_message = @import("port_message.zig");
const results = @import("port_result.zig");
const Failure = @import("port_bytes.zig").Failure;

const SpecState = struct {
    allocator: std.mem.Allocator,
    payload: *anyopaque,
    snapshot: *const fn (*anyopaque) ProcessSpec,
    release: *const fn (*anyopaque) void,
};
/// An immutable parsed specification owns its storage across controller startup.
pub const PreparedSpec = opaque {
    fn state(self: *PreparedSpec) *SpecState {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes the producer reference; failure retains it.
    pub fn create(comptime Producer: type, producer: *Producer) error{OutOfMemory}!*PreparedSpec {
        const Bridge = struct {
            fn typed(raw: *anyopaque) *Producer {
                return @ptrCast(@alignCast(raw));
            }
            fn snapshot(raw: *anyopaque) ProcessSpec {
                return typed(raw).processSpec();
            }
            fn release(raw: *anyopaque) void {
                typed(raw).release();
            }
        };
        const owned = try producer.allocator().create(SpecState);
        owned.* = .{ .allocator = producer.allocator(), .payload = producer, .snapshot = Bridge.snapshot, .release = Bridge.release };
        return @ptrCast(owned);
    }
    fn snapshot(self: *PreparedSpec) ProcessSpec {
        return self.state().snapshot(self.state().payload);
    }
    pub fn release(self: *PreparedSpec) void {
        const owned = self.state();
        owned.release(owned.payload);
        owned.allocator.destroy(owned);
    }
};

const declarations = @import("port-declarations");
pub const DeclaredEndpoints = declarations.Endpoints(.{
    .stdin = declarations.Endpoint{ .doc = "Select the process writable standard input.", .transport = .bytes, .direction = .input, .owner = .resource },
    .stdout = declarations.Endpoint{ .doc = "Select the process readable standard output.", .transport = .bytes, .direction = .output, .owner = .resource },
    .stderr = declarations.Endpoint{ .doc = "Select the process readable diagnostics.", .transport = .bytes, .direction = .output, .owner = .resource },
});
pub const DeclaredOperations = declarations.Operations(enum { wait, control }, DeclaredEndpoints, .{
    .wait = .{ .doc = "Wait for process termination on the wait lane; request [].", .handler = OperationAdapter.execute, .lane = .wait, .endpoints = .{} },
    .terminate = .{ .doc = "Request process-group termination on the control lane; request [].", .handler = OperationAdapter.execute, .lane = .control, .endpoints = .{} },
    .kill = .{ .doc = "Force process-group termination on the control lane; request [].", .handler = OperationAdapter.execute, .lane = .control, .endpoints = .{} },
    .capture_limits = .{ .doc = "Read the process capture limits on the control lane; request [].", .handler = OperationAdapter.execute, .lane = .control, .endpoints = .{} },
});
pub const RegisteredOperation = DeclaredOperations.Name;
pub const Service = @import("port_service.zig").Resource(ServiceAdapter);
const ProcessExchange = @import("port_operation.zig").Exchange(OperationAdapter);
const ServiceStorage = transfers.Resource(Service, ProcessOwner, ProcessOwner.resourceAllocator, ProcessOwner.reserveService, ProcessOwner.releaseService);
const ServiceAdapter = struct {
    pub const Exchange = ProcessExchange;
    pub const Request = RegisteredOperation;
    owner: *ProcessOwner,
    specification: *PreparedSpec,
    backend: ?*ProcessCell = null,
    pub fn allocator(self: *const ServiceAdapter) std.mem.Allocator {
        return self.owner.allocator;
    }
    pub fn executor(self: *const ServiceAdapter) *controllers.Executor {
        return self.owner.executor.access();
    }
    pub fn nextIdentity(self: *ServiceAdapter) u64 {
        return self.owner.instance.next();
    }
    pub fn operationLane(_: *ServiceAdapter, operation: RegisteredOperation) u32 {
        return @intFromEnum(DeclaredOperations.lane(operation));
    }
    pub fn prepareOperation(_: *ServiceAdapter, cell: *Service, operation: RegisteredOperation, request: *const port_message.Validated, lane: *ProcessExchange.Lane) error{OutOfMemory}!*ProcessExchange.Prepared {
        const terminal = try results.Result.create(cell.adapter.owner.host);
        errdefer terminal.release();
        return ProcessExchange.prepare(.{ .cell = cell, .operation = operation, .valid_request = request.value() == .list and request.value().list.length() == 0 }, terminal, lane);
    }
    pub fn retire(_: *ServiceAdapter, cell: *Service) void {
        ServiceStorage.retire(cell);
    }
    pub fn destroy(self: *ServiceAdapter, cell: *Service) void {
        if (self.backend) |backend| backend.releasePort();
        self.specification.release();
        ServiceStorage.destroy(cell);
    }
    pub fn initState(_: *ServiceAdapter) void {}
    pub fn initializeBackend(self: *ServiceAdapter, cell: *Service) void {
        self.startBackend(cell) catch |err| cell.failInitialization(switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Denied, error.InvalidSpec => Failure.init(.domain, "process specification denied or invalid"),
            error.LiveLimit => Failure.init(.domain, "host process-port limit reached"),
            error.ScopeClosing => Failure.init(.cancelled, "process scope is closing"),
            error.Unsupported => Failure.init(.domain, "process ports are unsupported on this target"),
            error.Io, error.Closed => Failure.init(.io, "could not spawn process"),
        });
    }
    fn startBackend(self: *ServiceAdapter, cell: *Service) (SpawnError || error{Closed})!void {
        if (comptime !backendSupported()) return error.Unsupported;
        const spec = self.specification.snapshot();
        try self.owner.validateSpec(spec);
        const group = try cell.childGroup();
        const backend = try Resource.create(self.owner, .{spec}, ProcessCell.initializeAllocation);
        std.Io.Threaded.mutexLock(&cell.mutex);
        self.backend = backend;
        if (cell.closed.load(.acquire)) backend.kill();
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        try backend.controllers.start(.{group}, ProcessCell.prepareGroupStartup, supervisorThreadMain, ProcessCell.failBeforeStart);
    }
    pub fn cancel(self: *ServiceAdapter) void {
        if (self.backend) |backend| backend.kill();
    }
    pub fn failTransport(_: *ServiceAdapter) void {}
    pub fn abortTransport(_: *ServiceAdapter) void {}
    pub fn cleanup(_: *ServiceAdapter) void {}
    pub fn shutdown(self: *ServiceAdapter, _: *Service) ?Failure {
        if (self.backend) |backend| {
            backend.terminate();
            backend.joinBackend();
        }
        return null;
    }
    fn initializeAllocation(cell: *Service, owner: *ProcessOwner, spec: *PreparedSpec, worker: *const scheduler_api.WorkerScheduler) error{OutOfMemory}!void {
        cell.initialize(.{ .owner = owner, .specification = spec }, worker, 2, 16, true) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidLimits => unreachable,
        };
    }
};
const OperationAdapter = struct {
    cell: *Service,
    operation: RegisteredOperation,
    valid_request: bool,
    failure: ?Failure = null,
    pub fn allocator(self: *const OperationAdapter) std.mem.Allocator {
        return self.cell.allocator;
    }
    pub fn scheduler(self: *OperationAdapter) *const scheduler_api.WorkerScheduler {
        return self.cell.scheduler;
    }
    pub fn resourceMutex(self: *OperationAdapter) *std.Io.Mutex {
        return &self.cell.mutex;
    }
    pub fn admittedLocked(self: *OperationAdapter) void {
        self.cell.changed.broadcast(blockingIo());
    }
    pub fn retireValue(self: *OperationAdapter, item: Value) void {
        heap.hostDomain(self.cell.adapter.owner.host).releaseValue(item);
    }
    pub fn retainResource(self: *OperationAdapter) void {
        self.cell.retainReadiness();
    }
    pub fn deinit(self: *OperationAdapter) void {
        self.cell.releaseReadiness();
    }
    pub fn terminal(self: *OperationAdapter) results.Terminal {
        return if (self.failure) |failure| .{ .failed = failure } else .success;
    }
    pub fn runnable(self: *OperationAdapter) bool {
        return !self.cell.closed.load(.acquire);
    }
    pub fn cancelPolicy(_: *OperationAdapter) controllers.CallbackCancellation {
        return .acknowledge;
    }
    pub fn cancelResourceLocked(self: *OperationAdapter, action: controllers.CancelAction) void {
        switch (action) {
            .close_resource => self.cell.closeLocked(),
            .interrupt, .retired => {
                if (self.cell.adapter.backend) |backend| {
                    std.Io.Threaded.mutexLock(&backend.mutex);
                    backend.changed.broadcast(blockingIo());
                    std.Io.Threaded.mutexUnlock(&backend.mutex);
                }
                self.cell.changed.broadcast(blockingIo());
                self.cell.waits.notifyLocked(self.cell);
            },
            .settled => {},
        }
    }
    pub fn completeResourceLocked(self: *OperationAdapter, outcome: controllers.Completion) void {
        if (outcome == .close_resource) self.cell.closeLocked();
        self.cell.waits.notifyLocked(self.cell);
    }
    pub fn notifyTransport(_: *OperationAdapter, _: *ProcessExchange) void {}
    pub fn abortTransport(_: *OperationAdapter) void {}
    pub fn execute(self: *OperationAdapter, exchange: *ProcessExchange, running: *controllers.Running) void {
        defer {
            std.Io.Threaded.mutexLock(&exchange.mutex);
            if (exchange.ticket.isCancelled()) _ = running.acknowledgeCancellation();
            std.Io.Threaded.mutexUnlock(&exchange.mutex);
        }
        self.perform(exchange, running) catch |err| {
            std.Io.Threaded.mutexLock(&exchange.mutex);
            self.failure = switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.Overflow => Failure.init(.overflow, "process result exceeds representable limits"),
                else => Failure.init(.io, "process result construction failed"),
            };
            std.Io.Threaded.mutexUnlock(&exchange.mutex);
        };
    }
    fn perform(self: *OperationAdapter, exchange: *ProcessExchange, running: *controllers.Running) @import("port_builder.zig").Error!void {
        if (!self.valid_request) {
            std.Io.Threaded.mutexLock(&exchange.mutex);
            self.failure = Failure.init(.domain, "process operations require an empty request list");
            std.Io.Threaded.mutexUnlock(&exchange.mutex);
            return;
        }
        const backend = self.cell.adapter.backend.?;
        switch (self.operation) {
            .terminate => backend.terminate(),
            .kill => backend.kill(),
            .wait => {
                std.Io.Threaded.mutexLock(&backend.mutex);
                while (backend.phase != .reaped and !backend.io_failed and backend.input != .broken and !exchange.transport_cancelled.load(.acquire)) backend.changed.waitUncancelable(blockingIo(), &backend.mutex);
                const failed = backend.io_failed or backend.input == .broken;
                std.Io.Threaded.mutexUnlock(&backend.mutex);
                if (failed) {
                    std.Io.Threaded.mutexLock(&exchange.mutex);
                    self.failure = Failure.init(.io, "process pipe operation failed");
                    std.Io.Threaded.mutexUnlock(&exchange.mutex);
                    return;
                }
            },
            .capture_limits => {},
        }
        std.Io.Threaded.mutexLock(&exchange.mutex);
        const cancelled = exchange.ticket.isCancelled();
        if (cancelled) _ = running.acknowledgeCancellation();
        std.Io.Threaded.mutexUnlock(&exchange.mutex);
        if (cancelled or self.operation == .terminate or self.operation == .kill) return;
        const builder = try @import("port_builder.zig").Builder.create(self.cell.adapter.owner.host);
        defer builder.retire();
        if (self.operation == .wait) {
            const term = backend.termination().?;
            const info: struct { kind: []const u8, field: []const u8, number: i64 } = switch (term) {
                .exited => |code| .{ .kind = "exited", .field = "code", .number = code },
                .signaled => |signal| .{ .kind = "signaled", .field = "signal", .number = signal },
                .stopped => |signal| .{ .kind = "stopped", .field = "signal", .number = signal },
                .unknown => |status| .{ .kind = "unknown", .field = "status", .number = status },
            };
            try symbol(builder, "kind");
            try symbol(builder, info.kind);
            try symbol(builder, info.field);
            try builder.int(info.number);
        } else {
            try symbol(builder, "stdout");
            try builder.int(std.math.cast(i64, self.cell.adapter.owner.stdoutCaptureLimit()) orelse return error.Overflow);
            try symbol(builder, "stderr");
            try builder.int(std.math.cast(i64, self.cell.adapter.owner.stderrCaptureLimit()) orelse return error.Overflow);
        }
        try builder.dictionary(2);
        try settle(builder);
        try builder.finish();
        try settle(builder);
        const envelope = try @import("port_messages.zig").Envelope.create(self.cell.adapter.owner.host, builder.validated().?);
        if (!exchange.terminal_result.replace(envelope)) envelope.release();
    }
    fn settle(builder: *@import("port_builder.zig").Builder) @import("port_builder.zig").Error!void {
        while (try builder.advance() == .pending) {}
    }
    fn symbol(builder: *@import("port_builder.zig").Builder, name: []const u8) @import("port_builder.zig").Error!void {
        try builder.symbol(name);
        try settle(builder);
    }
};

/// Consumes the parsed specification on every path, including startup rollback.
pub fn openPrepared(access_value: *external.ProcessAccess, scope: *scheduler_api.TaskScope, spec: *PreparedSpec) SpawnError!Value {
    const owner = ownerFromAccess(access_value);
    const cell = prepare: {
        errdefer spec.release();
        try owner.validateSpec(spec.snapshot());
        break :prepare try ServiceStorage.create(owner, .{ spec, scope.scheduler }, ServiceAdapter.initializeAllocation);
    };
    // From this point the service owns the specification, including rollback.
    const item = resource_api.Resource.create(Service, .staged, owner.instance.next(), cell) catch |err| {
        cell.releasePort();
        return err;
    };
    errdefer heap.hostDomain(owner.host).releaseValue(item);
    cell.controllers.start(.{scope}, Service.prepareStartup, Service.run, Service.abortStartup) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ScopeClosing => error.ScopeClosing,
        error.Io, error.Closed => error.Io,
    };
    return item;
}
pub fn serviceFromValue(item: Value) ?*Service {
    return resource_api.Resource.project(Service, item);
}

pub fn serviceInstance(service: *Service) *@import("module_bindings.zig").Identity {
    return service.adapter.owner.instance;
}
