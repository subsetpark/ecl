//! Native controller ownership, bounded streams, and scheduler readiness.
const std = @import("std");
const abi = @import("native-abi");
const external = @import("external.zig");
const heap = @import("heap.zig");
const native = @import("native_module.zig");
const scheduler = @import("scheduler.zig");
const transfers = @import("port_transfer.zig");
const Ring = @import("byte_ring.zig").Ring;
const Value = @import("value.zig").Value;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn lock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexLock(mutex);
}
fn unlock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexUnlock(mutex);
}

pub const Limits = struct {
    max_live_ports: u32 = 64,
    max_operations: u32 = 16,
    ring_capacity: u32 = 64 * 1024,

    pub fn validate(self: Limits) error{InvalidLimits}!void {
        if (self.max_live_ports == 0 or self.max_live_ports > 4096 or
            self.max_operations == 0 or self.max_operations > 256 or
            self.ring_capacity == 0 or self.ring_capacity > 16 * 1024 * 1024)
            return error.InvalidLimits;
    }
};

pub const Failure = struct {
    kind: abi.ErrorKindWire,
    message: [abi.max_error_message_bytes]u8 = .{0} ** abi.max_error_message_bytes,
    len: u32,

    pub fn init(kind: abi.ErrorKindWire, message: []const u8) Failure {
        var result: Failure = .{ .kind = kind, .len = @intCast(@min(message.len, abi.max_error_message_bytes)) };
        @memcpy(result.message[0..result.len], message[0..result.len]);
        return result;
    }
};

const OwnerState = struct {
    host: *const heap.HostCleanup,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    closing: bool = false,
    live: u32 = 0,
    identity: u64 = 1,
    reaper: ?std.Thread = null,
    first: ?*Cell = null,
    last: ?*Cell = null,

    fn releaseLive(self: *OwnerState) void {
        lock(&self.mutex);
        self.live -= 1;
        self.changed.broadcast(io());
        unlock(&self.mutex);
    }
    fn enqueue(self: *OwnerState, cell: *Cell) void {
        lock(&self.mutex);
        if (self.last) |last| last.retired_next = cell else self.first = cell;
        self.last = cell;
        self.changed.broadcast(io());
        unlock(&self.mutex);
    }
    fn reap(self: *OwnerState) void {
        while (true) {
            lock(&self.mutex);
            while (self.first == null and !(self.closing and self.live == 0))
                self.changed.waitUncancelable(io(), &self.mutex);
            const cell = self.first orelse {
                unlock(&self.mutex);
                return;
            };
            self.first = cell.retired_next;
            if (self.first == null) self.last = null;
            unlock(&self.mutex);
            // The enqueued controller still owns this reference. Joining it
            // precedes every scope release and every native-image release.
            cell.controller.running.join();
            self.releaseLive();
            lock(&cell.mutex);
            cell.controller = .joined;
            cell.phase = .joined;
            var detached = cell.ownership.release();
            cell.waits.notifyLocked(cell);
            unlock(&cell.mutex);
            detached.detachAll();
            cell.releasePort();
        }
    }
};

pub const Owner = opaque {
    fn state(self: *Owner) *OwnerState {
        return @ptrCast(@alignCast(self));
    }
    pub fn init(host: *const heap.HostCleanup, limits: Limits) error{ OutOfMemory, InvalidLimits }!*Owner {
        try limits.validate();
        const state_value = try host.allocator().create(OwnerState);
        state_value.* = .{ .host = host, .limits = limits };
        return ownerFromState(state_value);
    }
    pub fn access(self: *Owner) *Access {
        return @ptrCast(self);
    }
    pub fn closeCreation(self: *Owner) void {
        const state_value = self.state();
        lock(&state_value.mutex);
        state_value.closing = true;
        state_value.changed.broadcast(io());
        unlock(&state_value.mutex);
    }
    pub fn deinit(self: *Owner) void {
        const state_value = self.state();
        self.closeCreation();
        if (state_value.reaper) |thread| thread.join();
        state_value.host.allocator().destroy(state_value);
    }
};
fn ownerFromState(state: *OwnerState) *Owner {
    return @ptrCast(state);
}

pub const CreateError = error{ OutOfMemory, Closed, Limit, Io, ScopeClosing };
pub const Access = opaque {
    fn state(self: *Access) *OwnerState {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes the initial cell reference into the heap value.
    /// Failure cancels/detaches every provisional resource; no backend code
    /// runs until heap storage, scope membership, and controller ownership exist.
    pub fn create(self: *Access, instance: *native.ModuleInstance, kind: u32, scope: *scheduler.TaskScope) CreateError!Value {
        const owner = self.state();
        lock(&owner.mutex);
        if (owner.closing) {
            unlock(&owner.mutex);
            return error.Closed;
        }
        if (owner.live == owner.limits.max_live_ports) {
            unlock(&owner.mutex);
            return error.Limit;
        }
        if (owner.reaper == null) owner.reaper = std.Thread.spawn(.{}, OwnerState.reap, .{owner}) catch {
            unlock(&owner.mutex);
            return error.Io;
        };
        owner.live += 1;
        const identity = owner.identity;
        owner.identity +%= 1;
        unlock(&owner.mutex);
        errdefer owner.releaseLive();
        const cell = try Cell.allocate(owner, instance, kind);
        const item = heap.createPort(Cell, cell.allocator, identity, cell) catch |err| {
            cell.releasePort();
            return err;
        };
        errdefer heap.hostDomain(owner.host).releaseValue(item);
        return self.publish(cell, item, scope);
    }
    fn publish(_: *Access, cell: *Cell, item: Value, scope: *scheduler.TaskScope) CreateError!Value {
        try transfers.publishScope(Cell, cell, scope, Cell.transferOwnership);
        lock(&cell.mutex);
        cell.retainReadiness();
        const thread = std.Thread.spawn(.{}, Cell.run, .{cell}) catch {
            var detached = cell.ownership.release();
            cell.phase = .joined;
            cell.controller = .joined;
            unlock(&cell.mutex);
            detached.detachAll();
            cell.releasePort();
            return error.Io;
        };
        cell.controller = .{ .running = thread };
        unlock(&cell.mutex);
        return item;
    }
};

pub const Cell = struct {
    allocator: std.mem.Allocator,
    owner: *OwnerState,
    instance: *native.ModuleInstance,
    kind: u32,
    definition: abi.PortDefinition,
    backend: []align(64) u8,
    refs: std.atomic.Value(u32) = .init(1),
    closed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Cell) = .{},
    ownership: external.Ownership = .provisional,
    phase: enum { reserved, initializing, open, closing, cleaned, joined } = .reserved,
    controller: union(enum) { unstarted, running: std.Thread, joined } = .unstarted,
    initialization_failure: ?Failure = null,
    first: ?*Operation = null,
    last: ?*Operation = null,
    active: ?*Operation = null,
    admitted: u32 = 0,
    retired_next: ?*Cell = null,

    fn allocate(owner: *OwnerState, instance: *native.ModuleInstance, kind: u32) error{OutOfMemory}!*Cell {
        const allocator = owner.host.allocator();
        const definition = instance.validated().port(kind).?;
        const state = try allocator.alignedAlloc(u8, .@"64", definition.state_size);
        errdefer allocator.free(state);
        const cell = try allocator.create(Cell);
        cell.* = .{ .allocator = allocator, .owner = owner, .instance = instance, .kind = kind, .definition = definition, .backend = state };
        instance.retain();
        return cell;
    }
    pub fn retainReadiness(self: *Cell) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Cell) void {
        self.releasePort();
    }
    pub fn retainExternalMember(self: *Cell) void {
        self.retainReadiness();
    }
    pub fn releaseExternalMember(self: *Cell) void {
        self.releasePort();
    }
    pub fn cancelExternalMember(self: *Cell) void {
        self.close();
    }
    pub fn releasePort(self: *Cell) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.instance.releasePin();
        self.allocator.free(self.backend);
        self.allocator.destroy(self);
    }
    pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Cell).register(self, key, target);
    }
    pub fn readyLocked(self: *Cell, key: u64) bool {
        return switch (key) {
            0 => self.phase != .reserved and self.phase != .initializing,
            1 => self.phase == .joined,
            2 => self.closed.load(.acquire) or self.admitted < self.owner.limits.max_operations,
            else => true,
        };
    }
    pub fn wakeReasonLocked(_: *Cell, _: u64) external.Wake {
        return .ready;
    }
    pub fn source(self: *Cell, key: u64) external.ReadinessSource {
        return external.readinessSource(Cell, self, key);
    }
    pub fn initialized(self: *Cell) union(enum) { pending, ready, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return switch (self.phase) {
            .reserved, .initializing => .pending,
            .open => .ready,
            .closing, .cleaned, .joined => .{ .failed = self.initialization_failure orelse Failure.init(.io, "native port is closed") },
        };
    }
    pub fn joined(self: *Cell) bool {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return self.phase == .joined;
    }
    pub fn close(self: *Cell) void {
        lock(&self.mutex);
        if (self.closed.swap(true, .acq_rel)) {
            unlock(&self.mutex);
            return;
        }
        const notify_backend = self.phase == .initializing or self.phase == .open;
        self.phase = .closing;
        if (self.active) |op| op.markCancelled();
        // Admission is capped at 256, so cancellation never traverses an
        // unbounded task or value graph on the caller's thread.
        var pending = self.first;
        while (pending) |op| {
            op.markCancelled();
            pending = op.next;
        }
        if (notify_backend) self.definition.cancel.?(self.backend.ptr);
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
        unlock(&self.mutex);
    }
    fn run(self: *Cell) void {
        lock(&self.mutex);
        self.definition.init_state.?(self.backend.ptr);
        const initialize = !self.closed.load(.acquire);
        if (initialize) self.phase = .initializing;
        unlock(&self.mutex);
        var controller_context: ControllerContext = .{ .cell = self, .operation = null };
        if (initialize) self.definition.initialize.?(self.backend.ptr, &controller_table, &controller_context);
        lock(&self.mutex);
        if (self.initialization_failure != null) self.closed.store(true, .release);
        self.phase = if (self.closed.load(.acquire)) .closing else .open;
        self.waits.notifyLocked(self);
        unlock(&self.mutex);
        while (true) {
            lock(&self.mutex);
            while (self.first == null and !self.closed.load(.acquire)) self.changed.waitUncancelable(io(), &self.mutex);
            const op = self.first orelse {
                unlock(&self.mutex);
                break;
            };
            self.unlinkLocked(op);
            self.active = op;
            lock(&op.mutex);
            const execute = !self.closed.load(.acquire) and op.phase == .queued;
            if (execute) op.phase = .active;
            unlock(&op.mutex);
            unlock(&self.mutex);
            controller_context.operation = op;
            if (execute) self.definition.execute.?(self.backend.ptr, op.code, &controller_table, &controller_context);
            lock(&self.mutex);
            self.active = null;
            self.admitted -= 1;
            op.finish();
            self.waits.notifyLocked(self);
            unlock(&self.mutex);
            op.releaseReadiness();
        }
        // Close's notification callback has returned before this lock can be
        // acquired. Future closes see `closed` and cannot enter backend code.
        lock(&self.mutex);
        unlock(&self.mutex);
        self.definition.cleanup.?(self.backend.ptr);
        lock(&self.mutex);
        self.phase = .cleaned;
        unlock(&self.mutex);
        self.owner.enqueue(self);
    }
    fn unlinkLocked(self: *Cell, op: *Operation) void {
        if (op.previous) |previous| previous.next = op.next else self.first = op.next;
        if (op.next) |next| next.previous = op.previous else self.last = op.previous;
        op.previous = null;
        op.next = null;
    }
    pub fn admit(self: *Cell, code: u32) error{OutOfMemory}!union(enum) { pending, closed, operation: *Operation } {
        lock(&self.mutex);
        const closed = self.closed.load(.acquire);
        const full = self.admitted == self.owner.limits.max_operations;
        unlock(&self.mutex);
        if (closed) return .closed;
        if (full) return .pending;
        const op = try Operation.create(self, code);
        lock(&self.mutex);
        if (self.closed.load(.acquire) or self.admitted == self.owner.limits.max_operations) {
            const now_closed = self.closed.load(.acquire);
            unlock(&self.mutex);
            op.releaseReadiness();
            return if (now_closed) .closed else .pending;
        }
        op.retainReadiness();
        op.previous = self.last;
        if (self.last) |last| last.next = op else self.first = op;
        self.last = op;
        self.admitted += 1;
        self.changed.broadcast(io());
        unlock(&self.mutex);
        return .{ .operation = op };
    }
    const Transfer = transfers.ScopeTransfer(Cell, transferOwnership, transferLive);
    fn transferOwnership(self: *Cell) *external.Ownership {
        return &self.ownership;
    }
    fn transferLive(self: *Cell) bool {
        return !self.closed.load(.acquire);
    }
    pub fn prepareScopeTransfer(self: *Cell, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return Transfer.prepare(self, from, to);
    }
    pub fn commitScopeTransfer(self: *Cell) void {
        Transfer.commit(self);
    }
    pub fn abortScopeTransfer(self: *Cell) void {
        Transfer.abort(self);
    }
};

pub const Operation = struct {
    allocator: std.mem.Allocator,
    cell: *Cell,
    code: u32,
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Operation) = .{},
    request: Ring,
    response: Ring,
    request_finished: bool = false,
    phase: enum { queued, active, done, cancelled } = .queued,
    failure: ?Failure = null,
    previous: ?*Operation = null,
    next: ?*Operation = null,

    fn create(cell: *Cell, code: u32) error{OutOfMemory}!*Operation {
        const allocator = cell.allocator;
        const request = try allocator.alloc(u8, cell.owner.limits.ring_capacity);
        errdefer allocator.free(request);
        const response = try allocator.alloc(u8, cell.owner.limits.ring_capacity);
        errdefer allocator.free(response);
        const op = try allocator.create(Operation);
        op.* = .{ .allocator = allocator, .cell = cell, .code = code, .request = .{ .bytes = request }, .response = .{ .bytes = response } };
        cell.retainReadiness();
        return op;
    }
    pub fn retainReadiness(self: *Operation) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Operation) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.allocator.free(self.request.bytes);
        self.allocator.free(self.response.bytes);
        self.cell.releasePort();
        self.allocator.destroy(self);
    }
    pub fn registerReadiness(self: *Operation, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Operation).register(self, key, target);
    }
    pub fn readyLocked(self: *Operation, key: u64) bool {
        return self.phase == .done or self.phase == .cancelled or
            (key & 1 != 0 and self.response.len != 0) or
            (key & 2 != 0 and !self.request_finished and self.request.free() != 0);
    }
    pub fn wakeReasonLocked(_: *Operation, _: u64) external.Wake {
        return .ready;
    }
    pub fn source(self: *Operation, interests: u32) external.ReadinessSource {
        return external.readinessSource(Operation, self, interests);
    }
    fn notifyLocked(self: *Operation) void {
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
    }
    fn markCancelled(self: *Operation) void {
        lock(&self.mutex);
        self.phase = .cancelled;
        self.notifyLocked();
        unlock(&self.mutex);
    }
    fn finish(self: *Operation) void {
        lock(&self.mutex);
        if (self.phase != .cancelled) self.phase = .done;
        self.notifyLocked();
        unlock(&self.mutex);
    }
    pub fn cancel(self: *Operation) void {
        const cell = self.cell;
        lock(&cell.mutex);
        if (cell.active == self) {
            unlock(&cell.mutex);
            cell.close();
            return;
        }
        lock(&self.mutex);
        const queued = self.phase == .queued;
        unlock(&self.mutex);
        if (queued) {
            cell.unlinkLocked(self);
            cell.admitted -= 1;
            self.markCancelled();
            cell.waits.notifyLocked(cell);
        }
        unlock(&cell.mutex);
        if (queued) self.releaseReadiness();
    }
    pub fn result(self: *Operation) union(enum) { pending, ready, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return switch (self.phase) {
            .queued, .active => .pending,
            .done => if (self.failure) |failure| .{ .failed = failure } else .ready,
            .cancelled => .{ .failed = Failure.init(.io, "native port operation was cancelled") },
        };
    }
    pub fn write(self: *Operation, bytes: []const u8) ?usize {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.phase == .cancelled or self.phase == .done or self.request_finished) return null;
        const count = @min(bytes.len, self.request.free());
        self.request.push(bytes[0..count]);
        self.notifyLocked();
        return count;
    }
    pub fn read(self: *Operation, bytes: []u8) ?usize {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.phase == .cancelled) return null;
        const count = self.response.pop(bytes);
        self.notifyLocked();
        return count;
    }
    pub fn finishRequest(self: *Operation) void {
        lock(&self.mutex);
        self.request_finished = true;
        self.notifyLocked();
        unlock(&self.mutex);
    }
};

const ControllerContext = struct { cell: *Cell, operation: ?*Operation };
fn context(raw: *anyopaque) *ControllerContext {
    return @ptrCast(@alignCast(raw));
}
fn controllerRead(raw: *anyopaque, bytes: [*]u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const op = context(raw).operation orelse return 0;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    while (op.phase != .cancelled and op.request.len == 0 and !op.request_finished) op.changed.waitUncancelable(io(), &op.mutex);
    if (op.phase == .cancelled) return 0;
    const count = op.request.pop(bytes[0..@min(length, 64 * 1024)]);
    op.notifyLocked();
    return @intCast(count);
}
fn controllerWrite(raw: *anyopaque, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const op = context(raw).operation orelse return 0;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    while (op.phase != .cancelled and op.response.free() == 0) op.changed.waitUncancelable(io(), &op.mutex);
    if (op.phase == .cancelled) return 0;
    const count = @min(@min(length, 64 * 1024), op.response.free());
    op.response.push(bytes[0..count]);
    op.notifyLocked();
    return @intCast(count);
}
fn controllerCancelled(raw: *anyopaque) callconv(.c) bool {
    return context(raw).cell.closed.load(.acquire);
}
fn controllerFail(raw: *anyopaque, kind: abi.ErrorKindWire, bytes: [*]const u8, length: u32) callconv(.c) void {
    const ctx = context(raw);
    const valid_kind: abi.ErrorKindWire = switch (kind) {
        .type, .shape, .conform, .overflow, .domain, .parse, .io, .user => kind,
        _ => .io,
    };
    const failure = Failure.init(valid_kind, bytes[0..@min(length, abi.max_error_message_bytes)]);
    if (ctx.operation) |op| {
        lock(&op.mutex);
        op.failure = failure;
        unlock(&op.mutex);
    } else {
        lock(&ctx.cell.mutex);
        ctx.cell.initialization_failure = failure;
        unlock(&ctx.cell.mutex);
    }
}
const controller_table: abi.ControllerTable = .{ .read = controllerRead, .write = controllerWrite, .cancelled = controllerCancelled, .fail = controllerFail };

pub fn fromValue(value: Value, instance: *native.ModuleInstance, kind: u32) ?*Cell {
    const handle = switch (value) {
        .port => |port| port,
        else => return null,
    };
    const cell = heap.portPayload(Cell, handle) orelse return null;
    return if (cell.instance == instance and cell.kind == kind) cell else null;
}
