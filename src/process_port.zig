//! Scope-owned POSIX subprocess controller behind opaque ECL port values.
//!
//! Blocking kernel pipe and wait operations run only on detached controller
//! threads. Scheduler workers interact through bounded queues and the generic
//! readiness capabilities in `external.zig`; live-process ownership belongs to
//! a TaskScope membership, never to the language value reference count.

const std = @import("std");
const builtin = @import("builtin");
const external = @import("external.zig");
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
    allocator: std.mem.Allocator,
    io: std.Io,
    policy: OwnedPolicy,
    environment: OwnedEnvironment,
    live: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        policy: ProcessPolicy,
        environment: []const EnvironmentEntry,
    ) PolicyError!ProcessOwner {
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
        const owned_environment = try OwnedEnvironment.init(
            allocator,
            policy.inherit_environment,
            environment,
        );
        return .{
            .allocator = allocator,
            .io = io,
            .policy = owned_policy,
            .environment = owned_environment,
        };
    }

    pub fn deinit(self: *ProcessOwner) void {
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
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
        spec: ProcessSpec,
    ) SpawnError!Value {
        if (comptime !backendSupported()) return error.Unsupported;
        try self.validateSpec(spec);
        if (!self.reserveLive()) return error.LiveLimit;
        var live_reserved = true;
        errdefer if (live_reserved) self.releaseLive();

        var environment = std.process.Environ.Map.init(self.allocator);
        defer environment.deinit();
        for (self.environment.entries) |entry| environment.put(entry.name, entry.value) catch
            return error.OutOfMemory;
        for (spec.environment) |entry| environment.put(entry.name, entry.value) catch
            return error.OutOfMemory;

        const argv = try self.allocator.alloc([]const u8, spec.args.len + 1);
        defer self.allocator.free(argv);
        argv[0] = spec.executable;
        @memcpy(argv[1..], spec.args);

        var child: ?std.process.Child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (spec.cwd orelse self.policy.initial_cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = &environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch return error.Io;
        errdefer if (child) |*owned_child| killChildGroup(owned_child, self.io);

        const cell = ProcessCell.create(
            self,
            child.?,
            self.next_identity.fetchAdd(1, .monotonic),
        ) catch return error.OutOfMemory;
        child = null;
        var initial_owned = true;
        errdefer if (initial_owned) cell.releasePort();
        live_reserved = false;
        var supervisor_lease = cell.controllers.initialLease();
        var supervisor_lease_owned = true;
        errdefer if (supervisor_lease_owned) {
            cell.failBeforeStart();
            supervisor_lease.release();
        };

        const member = external.scopeMember(ProcessCell, cell);
        const membership = scheduler.attachExternal(scope, member) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return error.ScopeClosing,
        };
        cell.controllers.membership = membership;

        cell.start(supervisor_lease) catch return error.Io;
        supervisor_lease_owned = false;

        const port = heap.createPort(ProcessCell, self.allocator, cell.identity, cell) catch {
            cell.kill();
            return error.OutOfMemory;
        };
        initial_owned = false;
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

fn ownerFromAccess(access_value: *external.ProcessAccess) *ProcessOwner {
    return @ptrCast(@alignCast(access_value));
}

pub fn spawnFromUnit(
    access_value: *external.ProcessAccess,
    scheduler_erased: *const anyopaque,
    scope_erased: *anyopaque,
    spec: ProcessSpec,
) SpawnError!Value {
    const runtime_scheduler: *const scheduler_api.WorkerScheduler = @ptrCast(@alignCast(scheduler_erased));
    const scope: *scheduler_api.TaskScope = @ptrCast(@alignCast(scope_erased));
    return ownerFromAccess(access_value).spawn(runtime_scheduler, scope, spec);
}

pub fn stdoutCaptureLimit(access_value: *external.ProcessAccess) usize {
    return ownerFromAccess(access_value).stdoutCaptureLimit();
}

pub fn stderrCaptureLimit(access_value: *external.ProcessAccess) usize {
    return ownerFromAccess(access_value).stderrCaptureLimit();
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

const Ring = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,

    fn free(self: *const Ring) usize {
        return self.bytes.len - self.len;
    }

    fn push(self: *Ring, source: []const u8) void {
        std.debug.assert(source.len <= self.free());
        const tail = (self.head + self.len) % self.bytes.len;
        const first = @min(source.len, self.bytes.len - tail);
        @memcpy(self.bytes[tail..][0..first], source[0..first]);
        @memcpy(self.bytes[0 .. source.len - first], source[first..]);
        self.len += source.len;
    }

    fn pop(self: *Ring, destination: []u8) usize {
        const count = @min(destination.len, self.len);
        const first = @min(count, self.bytes.len - self.head);
        @memcpy(destination[0..first], self.bytes[self.head..][0..first]);
        @memcpy(destination[first..count], self.bytes[0 .. count - first]);
        self.head = (self.head + count) % self.bytes.len;
        self.len -= count;
        return count;
    }
};

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

const WriteNode = struct {
    cell: *ProcessCell,
    previous: ?*WriteNode = null,
    next: ?*WriteNode = null,
    linked: bool = true,
    active: bool = false,
};

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

pub const InputTerminal = enum {
    pending,
    closed_cleanly,
    broken,
};

/// Controller leases cover detached threads only. Retirement closes lease
/// creation; the supervisor waits for every other controller before its final
/// lease detaches membership. Port/readiness refs use the independent cell
/// refcount.
const ControllerGroup = struct {
    leases: std.atomic.Value(usize) = .init(0),
    membership: ?external.ScopeMembership = null,
    cell: *ProcessCell,

    fn initialLease(self: *ControllerGroup) ControllerLease {
        const cell = self.cell;
        cell.retainRef();
        if (self.leases.fetchAdd(1, .monotonic) != 0)
            @panic("initial controller lease already issued");
        return .{ .group = self, .cell = cell };
    }

    fn tryLease(self: *ControllerGroup) ?ControllerLease {
        const cell = self.cell;
        std.Io.Threaded.mutexLock(&cell.mutex);
        defer std.Io.Threaded.mutexUnlock(&cell.mutex);
        if (cell.group_state == .retired) return null;
        cell.retainRef();
        const old = self.leases.fetchAdd(1, .monotonic);
        if (old == 0 or old == std.math.maxInt(usize)) @panic("invalid controller lease count");
        return .{ .group = self, .cell = cell };
    }

    fn release(self: *ControllerGroup) ?external.ScopeMembership {
        const old = self.leases.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) {
            if (old == 2) {
                const cell = self.cell;
                std.Io.Threaded.mutexLock(&cell.mutex);
                cell.changed.broadcast(blockingIo());
                std.Io.Threaded.mutexUnlock(&cell.mutex);
            }
            return null;
        }
        _ = self.leases.load(.acquire);
        return self.cell.takeRetiredMembership(self);
    }
};

const ControllerLease = struct {
    group: ?*ControllerGroup,
    cell: ?*ProcessCell,

    fn release(self: *ControllerLease) void {
        const group = self.group orelse return;
        const cell = self.cell orelse @panic("controller lease lost its cell reference");
        self.group = null;
        self.cell = null;
        const membership = group.release();
        cell.releaseRef();
        if (membership) |token| detachMembership(token);
    }
};

pub const WritePermit = opaque {};

pub const RunEdge = enum {
    stdout_terminal,
    stderr_terminal,
    input_terminal,
    io_failure,
    reaped,
};

pub const RunCursor = opaque {};

const RunObservation = struct {
    permit: ?*WritePermit = null,
    observed: std.EnumSet(RunEdge) = .initEmpty(),
    active: bool = false,
};

pub const RunPoll = struct {
    edges: std.EnumSet(RunEdge),
    input: InputTerminal,
    termination: ?Termination,
};

fn writeNode(permit: *WritePermit) *WriteNode {
    return @ptrCast(@alignCast(permit));
}

fn writePermit(node: *WriteNode) *WritePermit {
    return @ptrCast(@alignCast(node));
}

const readiness_stdout: u64 = 1;
const readiness_stderr: u64 = 2;
const readiness_terminal: u64 = 3;
const readiness_run_tag: u64 = 4;
const readiness_pointer_mask: u64 = ~@as(u64, 7);

const ReadyWait = struct {
    allocator: std.mem.Allocator,
    cell: *ProcessCell,
    key: u64,
    target: external.WakeTarget,
    previous: ?*ReadyWait = null,
    next: ?*ReadyWait = null,
    linked: std.atomic.Value(bool) = .init(false),

    pub fn cancelReadiness(self: *ReadyWait) void {
        const cell = self.cell;
        if (self.linked.load(.acquire)) {
            std.Io.Threaded.mutexLock(&cell.mutex);
            if (self.linked.load(.monotonic)) cell.unlinkReadyLocked(self);
            std.Io.Threaded.mutexUnlock(&cell.mutex);
        }
        self.target.release();
        cell.releaseRef();
        self.allocator.destroy(self);
    }
};

pub const ProcessCell = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *ProcessOwner,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    phase: ProcessPhase = .constructing,
    group_state: GroupState,
    next_escalation: u64 = 1,
    controllers: ControllerGroup,
    stdin: Ring,
    stdout: Ring,
    stderr: Ring,
    input: InputState = .open,
    stdin_done: bool = false,
    stdout_done: bool = false,
    stderr_done: bool = false,
    io_failed: bool = false,
    discard_outputs: bool = false,
    stdout_reader_active: bool = false,
    stderr_reader_active: bool = false,
    write_first: ?*WriteNode = null,
    write_last: ?*WriteNode = null,
    ready_first: ?*ReadyWait = null,
    ready_last: ?*ReadyWait = null,
    timeout_done: std.Io.Event = .unset,
    timed_out: bool = false,
    run_observation: RunObservation = .{},

    fn create(
        owner: *ProcessOwner,
        child: std.process.Child,
        identity: u64,
    ) error{OutOfMemory}!*ProcessCell {
        const group = try owner.allocator.create(OwnedGroup);
        errdefer owner.allocator.destroy(group);
        group.* = .{ .child = child, .pgid = child.id.? };
        const cell = try owner.allocator.create(ProcessCell);
        errdefer owner.allocator.destroy(cell);
        const stdin = try owner.allocator.alloc(u8, owner.policy.stdin_capacity);
        errdefer owner.allocator.free(stdin);
        const stdout = try owner.allocator.alloc(u8, owner.policy.stdout_capacity);
        errdefer owner.allocator.free(stdout);
        const stderr = try owner.allocator.alloc(u8, owner.policy.stderr_capacity);
        cell.* = .{
            .allocator = owner.allocator,
            .io = owner.io,
            .owner = owner,
            .identity = identity,
            .group_state = .{ .running = group },
            .controllers = .{ .cell = cell },
            .stdin = .{ .bytes = stdin },
            .stdout = .{ .bytes = stdout },
            .stderr = .{ .bytes = stderr },
        };
        return cell;
    }

    fn start(self: *ProcessCell, lease: ControllerLease) error{Io}!void {
        self.phase = .running;
        const thread = std.Thread.spawn(.{}, supervisorThreadMain, .{ self, lease }) catch return error.Io;
        thread.detach();
    }

    fn failBeforeStart(self: *ProcessCell) void {
        self.kill();
        const group = switch (self.group_state) {
            .running => |group| group,
            .grace => |grace| grace.group,
            .kill_issued => |group| group,
            .retired => unreachable,
        };
        group.child.kill(self.io);
        self.phase = .{ .reaped = .{ .unknown = 0 } };
        self.group_state = .{ .retired = .{ .unknown = 0 } };
        self.allocator.destroy(group);
        self.owner.releaseLive();
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
        std.debug.assert(self.ready_first == null and self.write_first == null);
        self.allocator.free(self.stdin.bytes);
        self.allocator.free(self.stdout.bytes);
        self.allocator.free(self.stderr.bytes);
        self.allocator.destroy(self);
    }

    fn takeRetiredMembership(
        self: *ProcessCell,
        controllers: *ControllerGroup,
    ) ?external.ScopeMembership {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.group_state != .retired) @panic("process scope detached before group retirement");
        const membership = controllers.membership;
        controllers.membership = null;
        return membership;
    }

    fn waitForOtherControllers(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        while (self.controllers.leases.load(.acquire) != 1)
            self.changed.waitUncancelable(blockingIo(), &self.mutex);
    }

    pub fn releasePort(self: *ProcessCell) void {
        self.releaseRef();
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

    pub fn cancelExternalMember(self: *ProcessCell) void {
        var lease = self.controllers.tryLease() orelse return;
        const escalation = self.beginGrace(true);
        if (escalation) |id| {
            self.startEscalation(id, lease);
        } else lease.release();
    }

    fn startEscalation(
        self: *ProcessCell,
        escalation: EscalationId,
        lease_value: ControllerLease,
    ) void {
        var lease = lease_value;
        const thread = std.Thread.spawn(.{}, escalationMain, .{ self, escalation, lease }) catch {
            self.escalateKill(escalation);
            lease.release();
            return;
        };
        thread.detach();
    }

    pub fn registerReadiness(
        self: *ProcessCell,
        key: u64,
        target: external.WakeTarget,
    ) external.RegisterError!external.RegisterResult {
        const wait = try self.allocator.create(ReadyWait);
        errdefer self.allocator.destroy(wait);
        wait.* = .{
            .allocator = self.allocator,
            .cell = self,
            .key = key,
            .target = target,
        };
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.readyLocked(key)) {
            const reason = self.wakeReasonLocked(key);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            self.allocator.destroy(wait);
            return .{ .ready = reason };
        }
        target.retain();
        self.retainRef();
        self.linkReadyLocked(wait);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        return .{ .registered = external.readinessRegistration(ReadyWait, wait) };
    }

    pub fn beginWrite(self: *ProcessCell) error{OutOfMemory}!*WritePermit {
        const node = try self.allocator.create(WriteNode);
        node.* = .{ .cell = self };
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.write_last) |last| {
            last.next = node;
            node.previous = last;
        } else {
            self.write_first = node;
            node.active = true;
        }
        self.write_last = node;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        return writePermit(node);
    }

    pub fn write(
        self: *ProcessCell,
        permit: *WritePermit,
        bytes: []const u8,
    ) WriteProgress {
        const node = writeNode(permit);
        std.debug.assert(node.cell == self and node.linked);
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.input != .open or self.io_failed) return .io;
        if (!node.active or self.stdin.free() == 0) return .pending;
        const count = @min(bytes.len, self.stdin.free());
        self.stdin.push(bytes[0..count]);
        self.changed.broadcast(blockingIo());
        return .{ .written = count };
    }

    pub fn writeSource(self: *ProcessCell, permit: *WritePermit) external.ReadinessSource {
        return external.readinessSource(ProcessCell, self, @intFromPtr(writeNode(permit)));
    }

    pub fn beginRun(self: *ProcessCell) *RunCursor {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.run_observation.active) @panic("process already has an active run cursor");
        self.run_observation = .{ .active = true };
        return @ptrCast(&self.run_observation);
    }

    pub fn endRun(self: *ProcessCell, cursor: *RunCursor) void {
        const observation = self.runObservation(cursor);
        std.Io.Threaded.mutexLock(&self.mutex);
        observation.* = .{};
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Atomically consumes every run-terminal edge currently visible.
    pub fn pollRun(
        self: *ProcessCell,
        cursor: *RunCursor,
    ) RunPoll {
        const observation = self.runObservation(cursor);
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const edges = self.runEdgesLocked();
        const new_edges = edges.differenceWith(observation.observed);
        observation.observed = observation.observed.unionWith(edges);
        return .{
            .edges = new_edges,
            .input = switch (self.input) {
                .open, .closing => .pending,
                .closed_cleanly => .closed_cleanly,
                .broken => .broken,
            },
            .termination = switch (self.phase) {
                .reaped => |result| result,
                .constructing, .running, .closing, .terminal => null,
            },
        };
    }

    pub fn runSource(
        self: *ProcessCell,
        cursor: *RunCursor,
        permit: ?*WritePermit,
    ) external.ReadinessSource {
        const observation = self.runObservation(cursor);
        std.Io.Threaded.mutexLock(&self.mutex);
        observation.permit = permit;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        const pointer: u64 = @intFromPtr(observation);
        std.debug.assert(pointer & ~readiness_pointer_mask == 0);
        return external.readinessSource(ProcessCell, self, pointer | readiness_run_tag);
    }

    fn runObservation(self: *ProcessCell, cursor: *RunCursor) *RunObservation {
        const observation: *RunObservation = @ptrCast(@alignCast(cursor));
        if (observation != &self.run_observation or !observation.active)
            @panic("run cursor belongs to another process");
        return observation;
    }

    pub fn finishWrite(self: *ProcessCell, permit: *WritePermit) void {
        self.retireWrite(writeNode(permit));
    }

    pub fn abandonWrite(self: *ProcessCell, permit: *WritePermit) void {
        self.retireWrite(writeNode(permit));
    }

    fn retireWrite(self: *ProcessCell, node: *WriteNode) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (node.linked) {
            const was_active = node.active;
            if (node.previous) |previous| previous.next = node.next else self.write_first = node.next;
            if (node.next) |next| {
                next.previous = node.previous;
                if (was_active) next.active = true;
            } else self.write_last = node.previous;
            node.linked = false;
            node.previous = null;
            node.next = null;
            self.notifyReadyLocked();
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.allocator.destroy(node);
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
        const ring, const done = switch (stream) {
            .stdout => .{ &self.stdout, self.stdout_done },
            .stderr => .{ &self.stderr, self.stderr_done },
        };
        if (ring.len != 0) {
            const count = ring.pop(destination);
            self.changed.broadcast(blockingIo());
            return .{ .data = count };
        }
        if (done) return if (self.io_failed) .io else .eof;
        return .pending;
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

    pub fn inputTerminal(self: *ProcessCell) InputTerminal {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.input) {
            .open, .closing => .pending,
            .closed_cleanly => .closed_cleanly,
            .broken => .broken,
        };
    }

    pub fn terminate(self: *ProcessCell) void {
        var lease = self.controllers.tryLease() orelse return;
        const escalation = self.beginGrace(true);
        if (escalation) |id| {
            self.startEscalation(id, lease);
        } else lease.release();
    }

    pub fn kill(self: *ProcessCell) void {
        self.issueKill(null);
    }

    pub fn armTimeout(self: *ProcessCell, milliseconds: u64) error{Io}!void {
        if (milliseconds == 0) {
            std.Io.Threaded.mutexLock(&self.mutex);
            switch (self.phase) {
                .constructing, .running => self.timed_out = true,
                .closing, .terminal, .reaped => {},
            }
            const expired = self.timed_out;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (expired) self.kill();
            return;
        }
        var lease = self.controllers.tryLease() orelse return;
        const thread = std.Thread.spawn(.{}, timeoutThreadMain, .{ self, milliseconds, lease }) catch {
            lease.release();
            return error.Io;
        };
        thread.detach();
    }

    pub fn timedOut(self: *ProcessCell) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.timed_out;
    }

    fn beginGrace(self: *ProcessCell, close_process: bool) ?EscalationId {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
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
        var lease = self.controllers.tryLease() orelse return;
        const escalation = self.beginGrace(false);
        if (escalation) |id| {
            self.startEscalation(id, lease);
        } else lease.release();
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
        self.notifyReadyLocked();
    }

    fn recordIoFailure(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        self.io_failed = true;
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn readyLocked(self: *ProcessCell, key: u64) bool {
        if (key & ~readiness_pointer_mask == readiness_run_tag) {
            const pointer = key & readiness_pointer_mask;
            const observation: *const RunObservation = @ptrFromInt(pointer);
            const write_ready = if (observation.permit) |permit| ready: {
                const node = writeNode(permit);
                break :ready !node.linked or node.active or self.input != .open or self.io_failed;
            } else false;
            return self.stdout.len != 0 or self.stderr.len != 0 or write_ready or
                !self.runEdgesLocked().subsetOf(observation.observed);
        }
        return switch (key) {
            readiness_stdout => self.stdout.len != 0 or self.stdout_done,
            readiness_stderr => self.stderr.len != 0 or self.stderr_done,
            readiness_terminal => self.phase == .reaped,
            else => {
                const node: *WriteNode = @ptrFromInt(key);
                return !node.linked or node.active or self.input != .open or self.io_failed;
            },
        };
    }

    fn wakeReasonLocked(self: *ProcessCell, key: u64) external.Wake {
        if (key & ~readiness_pointer_mask == readiness_run_tag) return .ready;
        return if (self.io_failed) .io else .ready;
    }

    fn runEdgesLocked(self: *ProcessCell) std.EnumSet(RunEdge) {
        var edges: std.EnumSet(RunEdge) = .initEmpty();
        inline for (std.enums.values(RunEdge)) |edge| {
            const present = switch (edge) {
                .stdout_terminal => self.stdout_done and self.stdout.len == 0,
                .stderr_terminal => self.stderr_done and self.stderr.len == 0,
                .input_terminal => self.input.terminal(),
                .io_failure => self.io_failed,
                .reaped => self.phase == .reaped,
            };
            if (present) edges.insert(edge);
        }
        return edges;
    }

    fn linkReadyLocked(self: *ProcessCell, wait: *ReadyWait) void {
        std.debug.assert(!wait.linked.load(.monotonic));
        if (self.ready_last) |last| {
            last.next = wait;
            wait.previous = last;
        } else self.ready_first = wait;
        self.ready_last = wait;
        wait.linked.store(true, .release);
    }

    fn unlinkReadyLocked(self: *ProcessCell, wait: *ReadyWait) void {
        std.debug.assert(wait.linked.load(.monotonic));
        if (wait.previous) |previous| previous.next = wait.next else self.ready_first = wait.next;
        if (wait.next) |next| next.previous = wait.previous else self.ready_last = wait.previous;
        wait.previous = null;
        wait.next = null;
        wait.linked.store(false, .release);
    }

    /// Called with the cell lock held. Targets remain retained until their
    /// registration is consumed, so waking under this lock closes the only
    /// cancellation/use-after-free race without borrowing backend state back
    /// through the callback.
    fn notifyReadyLocked(self: *ProcessCell) void {
        var wait = self.ready_first;
        while (wait) |candidate| {
            const next = candidate.next;
            if (self.readyLocked(candidate.key)) {
                self.unlinkReadyLocked(candidate);
                candidate.target.wake(self.wakeReasonLocked(candidate.key));
            }
            wait = next;
        }
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
        while (!self.stdin_done or !self.stdout_done or !self.stderr_done)
            self.changed.waitUncancelable(blockingIo(), &self.mutex);
        self.phase = .{ .reaped = translated };
        self.group_state = .{ .retired = translated };
        self.timeout_done.set(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);

        self.allocator.destroy(group);
        self.waitForOtherControllers();
        self.owner.releaseLive();
    }

    const IoThread = enum { stdin, stdout, stderr };

    fn startIoThread(
        self: *ProcessCell,
        comptime function: anytype,
        file: std.Io.File,
        kind: IoThread,
    ) error{Io}!void {
        _ = kind;
        var lease = self.controllers.tryLease().?;
        const thread = std.Thread.spawn(.{}, function, .{ self, file, lease }) catch {
            lease.release();
            return error.Io;
        };
        thread.detach();
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
            .stdout => self.stdout_done = true,
            .stderr => self.stderr_done = true,
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
        switch (stream) {
            .stdout => self.stdout_done = true,
            .stderr => self.stderr_done = true,
        }
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }
};

fn timeoutThreadMain(cell: *ProcessCell, milliseconds: u64, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    };
    cell.timeout_done.waitTimeout(cell.io, .{ .duration = duration }) catch |err| switch (err) {
        error.Timeout => {
            std.Io.Threaded.mutexLock(&cell.mutex);
            switch (cell.phase) {
                .constructing, .running => cell.timed_out = true,
                .closing, .terminal, .reaped => {},
            }
            const expired = cell.timed_out;
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            if (expired) cell.kill();
        },
        error.Canceled => {},
    };
}

fn escalationMain(
    cell: *ProcessCell,
    escalation: EscalationId,
    lease_value: ControllerLease,
) void {
    var lease = lease_value;
    defer lease.release();
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(250),
        .clock = .awake,
    };
    duration.sleep(cell.io) catch |err| switch (err) {
        error.Canceled => {},
    };
    cell.escalateKill(escalation);
}

fn detachMembership(membership: external.ScopeMembership) void {
    var owned = membership;
    owned.detach();
}

fn supervisorThreadMain(cell: *ProcessCell, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    cell.supervisorMain();
}

fn stdinThreadMain(cell: *ProcessCell, file: std.Io.File, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    cell.stdinMain(file);
}

fn stdoutThreadMain(cell: *ProcessCell, file: std.Io.File, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    cell.stdoutMain(file);
}

fn stderrThreadMain(cell: *ProcessCell, file: std.Io.File, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
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
    return heap.portPayload(ProcessCell, port.port);
}

test "process policy rejects ambient and relative executable selection before spawn" {
    const denied = ProcessPolicy{ .executables = .{ .exact = &.{"/allowed/program"} } };
    var owner = try ProcessOwner.init(std.testing.allocator, std.testing.io, denied, &.{});
    defer owner.deinit();
    try std.testing.expectError(error.InvalidSpec, owner.validateSpec(.{ .executable = "program" }));
    try std.testing.expectError(error.Denied, owner.validateSpec(.{ .executable = "/other/program" }));
    try owner.validateSpec(.{ .executable = "/allowed/program" });
}

test "bounded ring preserves exact binary order across wrap" {
    var storage: [5]u8 = undefined;
    var ring = Ring{ .bytes = &storage };
    ring.push(&.{ 0, 255, 2, 3 });
    var first: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), ring.pop(&first));
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 2 }, &first);
    ring.push(&.{ 4, 5, 6 });
    var rest: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), ring.pop(&rest));
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, &rest);
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
    var runtime_scheduler = try scheduler_api.Scheduler.init(host.cleanup(), .cooperative);
    runtime_scheduler.attachRetirement();
    var root_scope = scheduler_api.TaskScope.init(runtime_scheduler.worker());
    defer runtime_scheduler.deinit(&root_scope);
    var owner = try ProcessOwner.init(
        std.testing.allocator,
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
    var runtime_scheduler = try scheduler_api.Scheduler.init(host.cleanup(), .cooperative);
    runtime_scheduler.attachRetirement();
    var root_scope = scheduler_api.TaskScope.init(runtime_scheduler.worker());
    var owner = try ProcessOwner.init(
        std.testing.allocator,
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
