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
        errdefer if (child) |*owned_child| owned_child.kill(self.io);

        const cell = ProcessCell.create(
            self,
            child.?,
            self.next_identity.fetchAdd(1, .monotonic),
        ) catch return error.OutOfMemory;
        child = null;
        var initial_owned = true;
        errdefer if (initial_owned) cell.releasePort();
        live_reserved = false;
        var started = false;
        errdefer if (!started) cell.failBeforeStart();

        const member = external.scopeMember(ProcessCell, cell);
        const membership = scheduler.attachExternal(scope, member) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return error.ScopeClosing,
        };
        cell.controllers.membership = membership;

        cell.start() catch return error.Io;
        started = true;

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

/// Controller leases cover detached threads only. The embedded group owns the
/// scope membership until its last lease is released; port/readiness refs use
/// the independent ProcessCell refcount.
const ControllerGroup = struct {
    leases: std.atomic.Value(usize) = .init(1),
    membership: ?external.ScopeMembership = null,

    fn initialLease(self: *ControllerGroup) ControllerLease {
        return .{ .group = self };
    }

    fn tryLease(self: *ControllerGroup) ?ControllerLease {
        var observed = self.leases.load(.acquire);
        while (observed != 0) {
            if (observed == std.math.maxInt(usize)) @panic("controller lease overflow");
            if (self.leases.cmpxchgWeak(observed, observed + 1, .acquire, .acquire)) |actual| {
                observed = actual;
            } else return .{ .group = self };
        }
        return null;
    }

    fn release(self: *ControllerGroup) void {
        const old = self.leases.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.leases.load(.acquire);
        const membership = self.membership;
        self.membership = null;
        if (membership) |token| detachMembership(token);
    }
};

const ControllerLease = struct {
    group: ?*ControllerGroup,

    fn release(self: *ControllerLease) void {
        const group = self.group orelse return;
        self.group = null;
        group.release();
    }
};

pub const WritePermit = opaque {};

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
    child: ?std.process.Child,
    pgid: std.posix.pid_t,
    phase: ProcessPhase = .constructing,
    controllers: ControllerGroup = .{},
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

    fn create(
        owner: *ProcessOwner,
        child: std.process.Child,
        identity: u64,
    ) error{OutOfMemory}!*ProcessCell {
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
            .child = child,
            .pgid = child.id.?,
            .stdin = .{ .bytes = stdin },
            .stdout = .{ .bytes = stdout },
            .stderr = .{ .bytes = stderr },
        };
        return cell;
    }

    fn start(self: *ProcessCell) error{Io}!void {
        self.phase = .running;
        self.retainRef();
        const lease = self.controllers.initialLease();
        const thread = std.Thread.spawn(.{}, supervisorThreadMain, .{ self, lease }) catch {
            self.releaseRef();
            return error.Io;
        };
        thread.detach();
    }

    fn failBeforeStart(self: *ProcessCell) void {
        var child = self.child.?;
        self.child = null;
        child.kill(self.io);
        self.phase = .{ .reaped = .{ .unknown = 0 } };
        self.owner.releaseLive();
        self.controllers.release();
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
        if (!self.beginScopeCancellation()) {
            lease.release();
            return;
        }
        self.retainRef();
        const thread = std.Thread.spawn(.{}, escalationMain, .{ self, lease }) catch {
            self.escalateKill();
            self.releaseRef();
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
            const reason = if (self.io_failed) external.Wake.io else .ready;
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

    /// Readiness for `proc.run`, which must drain both output streams while it
    /// feeds stdin. The tagged write node makes that compound predicate one
    /// scheduler registration without introducing an unbounded polling loop.
    pub fn runSource(self: *ProcessCell, permit: ?*WritePermit) external.ReadinessSource {
        const pointer: u64 = if (permit) |active| @intFromPtr(writeNode(active)) else 0;
        std.debug.assert(pointer & ~readiness_pointer_mask == 0);
        return external.readinessSource(ProcessCell, self, pointer | readiness_run_tag);
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
        self.signal(.TERM, .terminate);
    }

    pub fn kill(self: *ProcessCell) void {
        self.signal(.KILL, .kill);
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
        self.retainRef();
        const thread = std.Thread.spawn(.{}, timeoutThreadMain, .{ self, milliseconds, lease }) catch {
            self.releaseRef();
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

    fn signal(self: *ProcessCell, signal_value: std.posix.SIG, reason: @FieldType(ProcessPhase, "closing")) void {
        var should_signal = false;
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.phase) {
            .constructing, .running => {
                self.phase = .{ .closing = reason };
                should_signal = true;
            },
            .closing => |closing| if (closing == .terminate and reason == .kill) {
                self.phase = .{ .closing = .kill };
                should_signal = true;
            },
            .terminal, .reaped => {},
        }
        if (self.input == .open) self.input = .closing;
        self.discard_outputs = true;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (should_signal) self.signalGroup(signal_value);
    }

    fn beginScopeCancellation(self: *ProcessCell) bool {
        var should_signal = false;
        var should_escalate = false;
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.phase) {
            .constructing, .running => {
                self.phase = .{ .closing = .terminate };
                should_signal = true;
                should_escalate = true;
            },
            .closing => |closing| should_escalate = closing == .terminate,
            .terminal, .reaped => {},
        }
        if (self.input == .open) self.input = .closing;
        self.discard_outputs = true;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (should_signal) self.signalGroup(.TERM);
        return should_escalate;
    }

    fn escalateKill(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.phase == .closing and self.phase.closing == .terminate)
            self.phase = .{ .closing = .kill };
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.signalGroup(.KILL);
    }

    fn signalGroup(self: *ProcessCell, signal_value: std.posix.SIG) void {
        std.posix.kill(-self.pgid, signal_value) catch |err| switch (err) {
            error.ProcessNotFound => {},
            error.PermissionDenied => self.recordSignalFailure(),
            else => self.recordSignalFailure(),
        };
    }

    fn recordSignalFailure(self: *ProcessCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        self.io_failed = true;
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn readyLocked(self: *ProcessCell, key: u64) bool {
        if (key & ~readiness_pointer_mask == readiness_run_tag) {
            const pointer = key & readiness_pointer_mask;
            const write_ready = if (pointer != 0) ready: {
                const node: *WriteNode = @ptrFromInt(pointer);
                break :ready !node.linked or node.active or self.input != .open or self.io_failed;
            } else false;
            return self.stdout.len != 0 or self.stderr.len != 0 or
                self.stdout_done or self.stderr_done or self.phase == .reaped or
                self.input.terminal() or write_ready;
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
                candidate.target.wake(if (self.io_failed) .io else .ready);
            }
            wait = next;
        }
    }

    fn supervisorMain(self: *ProcessCell) void {
        var child = self.child.?;
        self.child = null;
        const stdin_file = child.stdin.?;
        const stdout_file = child.stdout.?;
        const stderr_file = child.stderr.?;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;

        self.startIoThread(stdinThreadMain, stdin_file, .stdin) catch self.failIoThread(stdin_file, .stdin);
        self.startIoThread(stdoutThreadMain, stdout_file, .stdout) catch self.failIoThread(stdout_file, .stdout);
        self.startIoThread(stderrThreadMain, stderr_file, .stderr) catch self.failIoThread(stderr_file, .stderr);

        const translated: Termination = translated: {
            const term = child.wait(self.io) catch {
                child.kill(self.io);
                std.Io.Threaded.mutexLock(&self.mutex);
                self.io_failed = true;
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break :translated .{ .unknown = 0 };
            };
            break :translated translateTerm(term);
        };

        std.Io.Threaded.mutexLock(&self.mutex);
        self.phase = .{ .terminal = translated };
        if (self.input == .open) self.input = .closing;
        self.changed.broadcast(blockingIo());
        self.notifyReadyLocked();
        while (!self.stdin_done or !self.stdout_done or !self.stderr_done)
            self.changed.waitUncancelable(blockingIo(), &self.mutex);
        self.phase = .{ .reaped = translated };
        self.timeout_done.set(blockingIo());
        self.notifyReadyLocked();
        std.Io.Threaded.mutexUnlock(&self.mutex);

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
        self.retainRef();
        const thread = std.Thread.spawn(.{}, function, .{ self, file, lease }) catch {
            self.releaseRef();
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
    defer cell.releaseRef();
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

fn escalationMain(cell: *ProcessCell, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    defer cell.releaseRef();
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(250),
        .clock = .awake,
    };
    duration.sleep(cell.io) catch |err| switch (err) {
        error.Canceled => {},
    };
    cell.escalateKill();
}

fn detachMembership(membership: external.ScopeMembership) void {
    var owned = membership;
    owned.detach();
}

fn supervisorThreadMain(cell: *ProcessCell, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    defer cell.releaseRef();
    cell.supervisorMain();
}

fn stdinThreadMain(cell: *ProcessCell, file: std.Io.File, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    defer cell.releaseRef();
    cell.stdinMain(file);
}

fn stdoutThreadMain(cell: *ProcessCell, file: std.Io.File, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    defer cell.releaseRef();
    cell.stdoutMain(file);
}

fn stderrThreadMain(cell: *ProcessCell, file: std.Io.File, lease_value: ControllerLease) void {
    var lease = lease_value;
    defer lease.release();
    defer cell.releaseRef();
    cell.stderrMain(file);
}

fn writeFileAll(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    var written: usize = 0;
    while (written != bytes.len)
        written += try std.Io.File.writeStreaming(file, io, &.{}, &.{bytes[written..]}, 1);
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
