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

const LiveReservation = transfers.Reservation(OwnerState, OwnerState.releaseLive);

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
            cell.reservation.release();
            lock(&cell.mutex);
            cell.controller = .joined;
            cell.phase = .joined;
            cell.waits.notifyLocked(cell);
            transfers.completeControllerLocked(Cell, cell, &cell.ownership, Cell.releasePort);
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

pub const CreateError = error{ OutOfMemory, Closed, Limit, InsufficientLanes, Io, ScopeClosing };
pub const Access = opaque {
    fn state(self: *Access) *OwnerState {
        return @ptrCast(@alignCast(self));
    }
    /// Success consumes the initial cell reference into the heap value.
    /// Failure cancels/detaches every provisional resource; no backend code
    /// runs until heap storage, scope membership, and controller ownership exist.
    pub fn create(self: *Access, instance: *native.ModuleInstance, kind: u32, scope: *scheduler.TaskScope) CreateError!Value {
        const owner = self.state();
        if (instance.validated().port(kind).?.lane_count > owner.limits.max_operations) return error.InsufficientLanes;
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
        var reservation = LiveReservation.adoptReserved(owner);
        errdefer reservation.release();
        const cell = try Cell.allocate(&reservation, instance, kind);
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

const Operations = transfers.ControllerLane(Operation);

pub const Cell = struct {
    allocator: std.mem.Allocator,
    owner: *OwnerState,
    reservation: LiveReservation,
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
    lanes: [abi.max_port_lanes]Operations = .{Operations{}} ** abi.max_port_lanes,
    retired_next: ?*Cell = null,

    fn allocate(reservation: *LiveReservation, instance: *native.ModuleInstance, kind: u32) error{OutOfMemory}!*Cell {
        const owner = reservation.owner();
        const allocator = owner.host.allocator();
        const definition = instance.validated().port(kind).?;
        const state = try allocator.alignedAlloc(u8, .@"64", definition.state_size);
        errdefer allocator.free(state);
        const cell = try allocator.create(Cell);
        cell.* = .{ .allocator = allocator, .owner = owner, .reservation = reservation.take(), .instance = instance, .kind = kind, .definition = definition, .backend = state };
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
        var reservation = self.reservation.take();
        self.instance.releasePin();
        self.allocator.free(self.backend);
        self.allocator.destroy(self);
        reservation.release();
    }
    pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Cell).register(self, key, target);
    }
    pub fn readyLocked(self: *Cell, key: u64) bool {
        return switch (key) {
            0 => self.phase != .reserved and self.phase != .initializing,
            1 => self.phase == .joined,
            else => self.closed.load(.acquire) or key - 2 >= self.definition.lane_count or
                self.lanes[key - 2].count < self.laneCapacity(@intCast(key - 2)),
        };
    }
    pub fn wakeReasonLocked(_: *Cell, _: u64) external.Wake {
        return .ready;
    }
    fn laneCapacity(self: *Cell, lane: u32) u32 {
        const total = self.owner.limits.max_operations;
        const lanes = self.definition.lane_count;
        return total / lanes + @as(u32, @intFromBool(lane < total % lanes));
    }
    pub fn admissionSource(self: *Cell, code: u32) external.ReadinessSource {
        return self.source(2 + @as(u64, self.definition.select_lane.?(code)));
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
        defer unlock(&self.mutex);
        self.closeLocked();
    }
    fn closeLocked(self: *Cell) void {
        if (self.closed.swap(true, .acq_rel)) return;
        const notify_backend = self.phase == .initializing or self.phase == .open;
        self.phase = .closing;
        // Total admission, across every lane, is capped at 256.
        for (self.lanes[0..self.definition.lane_count]) |*lane| {
            var ticket = lane.front();
            while (ticket) |current| : (ticket = current.successor()) current.owner().markCancelled();
        }
        if (notify_backend) self.definition.cancel.?(self.backend.ptr);
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
    }
    fn run(self: *Cell) void {
        lock(&self.mutex);
        self.definition.init_state.?(self.backend.ptr);
        const initialize = !self.closed.load(.acquire);
        if (initialize) self.phase = .initializing;
        unlock(&self.mutex);
        var controller_context: ControllerContext = .{ .cell = self, .operation = null };
        if (initialize) self.definition.initialize.?(self.backend.ptr, &controller_table, &controller_context);
        var threads: [abi.max_port_lanes - 1]?std.Thread = .{null} ** (abi.max_port_lanes - 1);
        lock(&self.mutex);
        if (self.initialization_failure != null) self.closed.store(true, .release);
        if (!self.closed.load(.acquire)) {
            for (1..self.definition.lane_count) |lane| {
                threads[lane - 1] = std.Thread.spawn(.{}, Cell.runLane, .{ self, lane }) catch {
                    self.initialization_failure = Failure.init(.io, "cannot start native controller lane");
                    self.closeLocked();
                    break;
                };
            }
        }
        self.phase = if (self.closed.load(.acquire)) .closing else .open;
        self.waits.notifyLocked(self);
        unlock(&self.mutex);
        self.runLane(0);
        for (threads) |thread| if (thread) |running| running.join();
        // Every operation executor and cancellation notification has finished.
        // The root controller owns cleanup; its reaper joins it before detach.
        lock(&self.mutex);
        unlock(&self.mutex);
        self.definition.cleanup.?(self.backend.ptr);
        lock(&self.mutex);
        self.phase = .cleaned;
        unlock(&self.mutex);
        self.owner.enqueue(self);
    }
    fn runLane(self: *Cell, index: usize) void {
        const lane = &self.lanes[index];
        var controller_context: ControllerContext = .{ .cell = self, .operation = null };
        while (true) {
            lock(&self.mutex);
            while (lane.empty() and !self.closed.load(.acquire)) self.changed.waitUncancelable(io(), &self.mutex);
            const ticket = lane.front() orelse {
                unlock(&self.mutex);
                return;
            };
            const op = ticket.owner();
            lock(&op.mutex);
            const execute = !self.closed.load(.acquire) and op.phase == .queued;
            if (execute) op.phase = .active;
            unlock(&op.mutex);
            unlock(&self.mutex);
            controller_context.operation = op;
            if (execute) self.definition.execute.?(self.backend.ptr, op.code, &controller_table, &controller_context);
            lock(&self.mutex);
            lock(&op.mutex);
            const unacknowledged = op.phase == .cancelling;
            unlock(&op.mutex);
            if (execute and unacknowledged) self.closeLocked();
            _ = lane.remove(ticket);
            op.finish();
            self.waits.notifyLocked(self);
            unlock(&self.mutex);
            op.releaseReadiness();
        }
    }
    pub fn admit(self: *Cell, code: u32) error{OutOfMemory}!union(enum) { pending, closed, invalid_operation, operation: *Operation } {
        const lane = self.definition.select_lane.?(code);
        lock(&self.mutex);
        const closed = self.closed.load(.acquire);
        const invalid = lane >= self.definition.lane_count;
        const full = !invalid and self.lanes[lane].count == self.laneCapacity(lane);
        unlock(&self.mutex);
        if (closed) return .closed;
        if (invalid) return .invalid_operation;
        if (full) return .pending;
        const op = try Operation.create(self, code, lane);
        lock(&self.mutex);
        if (self.closed.load(.acquire) or self.lanes[lane].count == self.laneCapacity(lane)) {
            const now_closed = self.closed.load(.acquire);
            unlock(&self.mutex);
            op.releaseReadiness();
            return if (now_closed) .closed else .pending;
        }
        op.retainReadiness();
        self.lanes[lane].append(op.ticket);
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

const OperationPhase = enum {
    queued,
    active,
    cancelling,
    reusable,
    cancelled,
    done,

    fn isCancelled(self: OperationPhase) bool {
        return switch (self) {
            .cancelling, .reusable, .cancelled => true,
            .queued, .active, .done => false,
        };
    }
};

pub const Operation = struct {
    allocator: std.mem.Allocator,
    cell: *Cell,
    code: u32,
    lane: u32,
    ticket: *Operations.Ticket,
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Operation) = .{},
    request: Ring,
    response: Ring,
    request_finished: bool = false,
    phase: OperationPhase = .queued,
    failure: ?Failure = null,

    fn create(cell: *Cell, code: u32, lane: u32) error{OutOfMemory}!*Operation {
        const allocator = cell.allocator;
        const request = try allocator.alloc(u8, cell.owner.limits.ring_capacity);
        errdefer allocator.free(request);
        const response = try allocator.alloc(u8, cell.owner.limits.ring_capacity);
        errdefer allocator.free(response);
        const op = try allocator.create(Operation);
        errdefer allocator.destroy(op);
        const ticket = try Operations.Ticket.create(allocator, op);
        op.* = .{ .allocator = allocator, .cell = cell, .code = code, .lane = lane, .ticket = ticket, .request = .{ .bytes = request }, .response = .{ .bytes = response } };
        cell.retainReadiness();
        return op;
    }
    pub fn retainReadiness(self: *Operation) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Operation) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.ticket.destroy(self.allocator);
        self.allocator.free(self.request.bytes);
        self.allocator.free(self.response.bytes);
        self.cell.releasePort();
        self.allocator.destroy(self);
    }
    pub fn registerReadiness(self: *Operation, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Operation).register(self, key, target);
    }
    pub fn readyLocked(self: *Operation, key: u64) bool {
        return self.phase == .done or self.phase.isCancelled() or
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
        self.phase = .cancelling;
        self.notifyLocked();
        unlock(&self.mutex);
    }
    fn finish(self: *Operation) void {
        lock(&self.mutex);
        self.phase = switch (self.phase) {
            .active, .done => .done,
            .queued, .cancelling, .reusable, .cancelled => .cancelled,
        };
        self.notifyLocked();
        unlock(&self.mutex);
    }
    pub fn cancel(self: *Operation) void {
        const cell = self.cell;
        lock(&cell.mutex);
        const lane = &cell.lanes[self.lane];
        lock(&self.mutex);
        const phase = self.phase;
        unlock(&self.mutex);
        if (phase == .active) {
            switch (cell.definition.cancellation) {
                .close_resource => cell.closeLocked(),
                .acknowledge => {
                    self.markCancelled();
                    cell.definition.cancel_operation.?(cell.backend.ptr, self.lane);
                },
                _ => unreachable,
            }
            unlock(&cell.mutex);
            return;
        }
        const queued = phase == .queued;
        if (queued) {
            _ = lane.remove(self.ticket);
            self.markCancelled();
            self.finish();
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
            .cancelling, .reusable, .cancelled => .{ .failed = Failure.init(.io, "native port operation was cancelled") },
        };
    }
    pub fn write(self: *Operation, bytes: []const u8) ?usize {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.phase.isCancelled() or self.phase == .done or self.request_finished) return null;
        const count = @min(bytes.len, self.request.free());
        self.request.push(bytes[0..count]);
        self.notifyLocked();
        return count;
    }
    pub fn read(self: *Operation, bytes: []u8) ?usize {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.phase.isCancelled()) return null;
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
    while (!op.phase.isCancelled() and op.request.len == 0 and !op.request_finished) op.changed.waitUncancelable(io(), &op.mutex);
    if (op.phase.isCancelled()) return 0;
    const count = op.request.pop(bytes[0..@min(length, 64 * 1024)]);
    op.notifyLocked();
    return @intCast(count);
}
fn controllerWrite(raw: *anyopaque, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const op = context(raw).operation orelse return 0;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    while (!op.phase.isCancelled() and op.response.free() == 0) op.changed.waitUncancelable(io(), &op.mutex);
    if (op.phase.isCancelled()) return 0;
    const count = @min(@min(length, 64 * 1024), op.response.free());
    op.response.push(bytes[0..count]);
    op.notifyLocked();
    return @intCast(count);
}
fn controllerCancelled(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.cell.closed.load(.acquire)) return true;
    const op = ctx.operation orelse return false;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    return op.phase.isCancelled();
}
fn controllerAcknowledge(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.cell.closed.load(.acquire) or ctx.cell.definition.cancellation != .acknowledge) return false;
    const op = ctx.operation orelse return false;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    if (op.phase != .cancelling) return false;
    op.phase = .reusable;
    return true;
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
const controller_table: abi.ControllerTable = .{ .read = controllerRead, .write = controllerWrite, .cancelled = controllerCancelled, .acknowledge_cancellation = controllerAcknowledge, .fail = controllerFail };

pub fn fromValue(value: Value, instance: *native.ModuleInstance, kind: u32) ?*Cell {
    const handle = switch (value) {
        .port => |port| port,
        else => return null,
    };
    const cell = heap.portPayload(Cell, handle) orelse return null;
    return if (cell.instance == instance and cell.kind == kind) cell else null;
}
