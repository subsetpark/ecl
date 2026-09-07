//! Native controller ownership, bounded streams, and scheduler readiness.
const std = @import("std");
const abi = @import("native-abi");
const external = @import("external.zig");
const heap = @import("heap.zig");
const native = @import("native_module.zig");
const scheduler = @import("scheduler.zig");
const controllers = @import("port_controller.zig");
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

const Resource = transfers.Resource(Cell, OwnerState, OwnerState.allocator, OwnerState.reserveLive, OwnerState.releaseLive);

const OwnerState = struct {
    host: *const heap.HostCleanup,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    closing: bool = false,
    live: u32 = 0,
    identity: u64 = 1,
    executor: *controllers.Owner,

    fn allocator(self: *OwnerState) std.mem.Allocator {
        return self.host.allocator();
    }
    fn reserveLive(self: *OwnerState) error{ Closed, Limit }!void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.closing) return error.Closed;
        if (self.live == self.limits.max_live_ports) return error.Limit;
        self.live += 1;
    }
    fn releaseLive(self: *OwnerState) void {
        lock(&self.mutex);
        self.live -= 1;
        unlock(&self.mutex);
    }
};

pub const Owner = opaque {
    fn state(self: *Owner) *OwnerState {
        return @ptrCast(@alignCast(self));
    }
    pub fn init(host: *const heap.HostCleanup, limits: Limits) error{ OutOfMemory, InvalidLimits }!*Owner {
        try limits.validate();
        const state_value = try host.allocator().create(OwnerState);
        errdefer host.allocator().destroy(state_value);
        state_value.* = .{ .host = host, .limits = limits, .executor = try controllers.Owner.init(host.allocator(), @as(usize, limits.max_live_ports) * @min(limits.max_operations, abi.max_port_lanes) + 1) };
        return ownerFromState(state_value);
    }
    pub fn access(self: *Owner) *Access {
        return @ptrCast(self);
    }
    pub fn closeCreation(self: *Owner) void {
        const state_value = self.state();
        lock(&state_value.mutex);
        state_value.closing = true;
        unlock(&state_value.mutex);
    }
    pub fn deinit(self: *Owner) void {
        const state_value = self.state();
        self.closeCreation();
        state_value.executor.deinit();
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
        const cell = try Resource.create(owner, .{ instance, kind }, Cell.initializeAllocation);
        lock(&owner.mutex);
        const identity = owner.identity;
        owner.identity +%= 1;
        unlock(&owner.mutex);
        const item = heap.createPort(Cell, cell.allocator, identity, cell) catch |err| {
            cell.releasePort();
            return err;
        };
        errdefer heap.hostDomain(owner.host).releaseValue(item);
        return self.publish(cell, item, scope);
    }
    fn publish(_: *Access, cell: *Cell, item: Value, scope: *scheduler.TaskScope) CreateError!Value {
        cell.controllers.start(.{scope}, Cell.prepareStartup, Cell.run, Cell.abortStartup) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeClosing => error.ScopeClosing,
            error.Io, error.Closed => error.Io,
        };
        return item;
    }
};

const ControllerGroup = controllers.Group(Cell, void, .{
    .retain = Cell.retainReadiness,
    .retireLocked = Cell.retireExecutionLocked,
    .ownership = Cell.transferOwnership,
    .release = Cell.releasePort,
});

const Operations = controllers.Lane(Operation, .operation, .{
    .deinit = Operation.deinit,
    .runnable = Operation.runnable,
    .execute = Operation.execute,
    .notifyOperation = Operation.notifyLocked,
    .completeResource = Operation.completeResourceLocked,
    .cancelPolicy = Operation.cancelPolicy,
    .cancelResource = Operation.cancelResourceLocked,
});

pub const Cell = struct {
    allocator: std.mem.Allocator,
    owner: *OwnerState,
    instance: *native.ModuleInstance,
    kind: u32,
    definition: abi.PortDefinition,
    backend: []align(64) u8,
    controllers: *ControllerGroup,
    refs: std.atomic.Value(u32) = .init(1),
    closed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Cell) = .{},
    ownership: external.Ownership = .provisional,
    phase: enum { reserved, initializing, open, closing, cleaned, joined } = .reserved,
    initialization_failure: ?Failure = null,
    lanes: [abi.max_port_lanes]Operations,

    fn initializeAllocation(cell: *Cell, owner: *OwnerState, instance: *native.ModuleInstance, kind: u32) error{OutOfMemory}!void {
        const allocator = owner.host.allocator();
        const definition = instance.validated().port(kind).?;
        const state = try allocator.alignedAlloc(u8, .@"64", definition.state_size);
        errdefer allocator.free(state);
        const group = try ControllerGroup.init(allocator, owner.executor.access(), cell);
        cell.* = .{ .allocator = allocator, .owner = owner, .instance = instance, .kind = kind, .definition = definition, .backend = state, .controllers = group, .lanes = .{Operations.init(&cell.mutex)} ** abi.max_port_lanes };
        instance.retain();
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
        self.controllers.deinit();
        Resource.destroy(self);
    }
    pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Cell).register(self, key, target);
    }
    pub fn readyLocked(self: *Cell, key: u64) bool {
        return switch (key) {
            0 => self.phase != .reserved and self.phase != .initializing,
            1 => self.phase == .joined,
            else => self.closed.load(.acquire) or key - 2 >= self.definition.lane_count or
                self.lanes[key - 2].hasCapacity(self.laneCapacity(@intCast(key - 2))),
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
    fn run(execution: *controllers.Execution, self: *Cell) void {
        lock(&self.mutex);
        self.definition.init_state.?(self.backend.ptr);
        const initialize = !self.closed.load(.acquire);
        if (initialize) self.phase = .initializing;
        unlock(&self.mutex);
        var controller_context: ControllerContext = .{ .cell = self, .operation = null };
        if (initialize) self.definition.initialize.?(self.backend.ptr, &controller_table, &controller_context);
        lock(&self.mutex);
        if (self.initialization_failure != null) self.closed.store(true, .release);
        const lane_count = if (self.closed.load(.acquire)) 1 else self.definition.lane_count;
        unlock(&self.mutex);
        execution.runLanes(lane_count, self, Cell.runLane, Cell.failLaneStartup, Cell.publishInitialization);
        // Every operation executor and cancellation notification has finished.
        // The root controller owns cleanup; its reaper joins it before detach.
        lock(&self.mutex);
        unlock(&self.mutex);
        self.definition.cleanup.?(self.backend.ptr);
        lock(&self.mutex);
        self.phase = .cleaned;
        unlock(&self.mutex);
    }
    fn failLaneStartup(self: *Cell) void {
        lock(&self.mutex);
        self.initialization_failure = Failure.init(.io, "cannot start native controller lane");
        self.closeLocked();
        unlock(&self.mutex);
    }
    fn publishInitialization(self: *Cell) void {
        lock(&self.mutex);
        self.phase = if (self.closed.load(.acquire)) .closing else .open;
        self.waits.notifyLocked(self);
        unlock(&self.mutex);
    }
    fn prepareStartup(cell: *Cell, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing }!void {
        try transfers.publishScope(Cell, cell, scope, Cell.transferOwnership);
    }
    fn abortStartup(cell: *Cell) void {
        cell.closed.store(true, .release);
    }
    fn retireExecutionLocked(cell: *Cell, _: controllers.Outcome(void)) void {
        Resource.retire(cell);
        cell.phase = .joined;
        cell.waits.notifyLocked(cell);
    }
    fn runLane(self: *Cell, index: usize) void {
        const lane = &self.lanes[index];
        while (true) {
            lock(&self.mutex);
            while (lane.empty() and !self.closed.load(.acquire)) self.changed.waitUncancelable(io(), &self.mutex);
            const finished = lane.empty();
            unlock(&self.mutex);
            if (finished) return;
            _ = lane.runNext();
        }
    }
    pub fn admit(self: *Cell, code: u32) error{OutOfMemory}!union(enum) { pending, closed, invalid_operation, operation: *Operation } {
        const lane = self.definition.select_lane.?(code);
        lock(&self.mutex);
        const closed = self.closed.load(.acquire);
        const invalid = lane >= self.definition.lane_count;
        const full = !invalid and !self.lanes[lane].hasCapacity(self.laneCapacity(lane));
        unlock(&self.mutex);
        if (closed) return .closed;
        if (invalid) return .invalid_operation;
        if (full) return .pending;
        const op = Operation.create(self, code, lane) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Closed => .closed,
            error.Full => .pending,
        };
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
    lane: u32,
    ticket: *Operations.Ticket,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Operation) = .{},
    request: Ring,
    response: Ring,
    request_finished: bool = false,
    failure: ?Failure = null,

    fn create(cell: *Cell, code: u32, lane: u32) error{ OutOfMemory, Closed, Full }!*Operation {
        const allocator = cell.allocator;
        const request = try allocator.alloc(u8, cell.owner.limits.ring_capacity);
        errdefer allocator.free(request);
        const response = try allocator.alloc(u8, cell.owner.limits.ring_capacity);
        errdefer allocator.free(response);
        lock(&cell.mutex);
        defer unlock(&cell.mutex);
        if (cell.closed.load(.acquire)) return error.Closed;
        const ticket = try cell.lanes[lane].admit(allocator, cell.laneCapacity(lane), .{ cell, code, lane, request, response }, initialize) orelse return error.Full;
        cell.changed.broadcast(io());
        return ticket.owner();
    }
    fn initialize(op: *Operation, ticket: *Operations.Ticket, cell: *Cell, code: u32, lane: u32, request: []u8, response: []u8) void {
        op.* = .{ .allocator = cell.allocator, .cell = cell, .code = code, .lane = lane, .ticket = ticket, .request = .{ .bytes = request }, .response = .{ .bytes = response } };
        cell.retainReadiness();
    }
    fn runnable(self: *Operation) bool {
        return !self.cell.closed.load(.acquire);
    }
    fn execute(self: *Operation, running: *controllers.Running) void {
        var ctx: ControllerContext = .{ .cell = self.cell, .operation = self, .running = running };
        self.cell.definition.execute.?(self.cell.backend.ptr, self.code, &controller_table, &ctx);
    }
    fn completeResourceLocked(self: *Operation, completion: controllers.Completion) void {
        if (completion == .close_resource) self.cell.closeLocked();
        self.cell.waits.notifyLocked(self.cell);
    }
    fn cancelPolicy(self: *Operation) controllers.CallbackCancellation {
        return switch (self.cell.definition.cancellation) {
            .close_resource => .close_resource,
            .acknowledge => .acknowledge,
            _ => unreachable,
        };
    }
    fn cancelResourceLocked(self: *Operation, action: controllers.CancelAction) void {
        const cell = self.cell;
        switch (action) {
            .close_resource => cell.closeLocked(),
            .interrupt => cell.definition.cancel_operation.?(cell.backend.ptr, self.lane),
            .retired => cell.waits.notifyLocked(cell),
            .settled => {},
        }
    }
    pub fn retainReadiness(self: *Operation) void {
        self.ticket.retain();
    }
    pub fn releaseReadiness(self: *Operation) void {
        self.ticket.release();
    }
    fn deinit(self: *Operation) void {
        self.allocator.free(self.request.bytes);
        self.allocator.free(self.response.bytes);
        self.cell.releasePort();
    }
    pub fn registerReadiness(self: *Operation, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Operation).register(self, key, target);
    }
    pub fn readyLocked(self: *Operation, key: u64) bool {
        return self.ticket.status() == .done or self.ticket.isCancelled() or
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
        self.ticket.requestCancellation();
        self.notifyLocked();
        unlock(&self.mutex);
    }
    pub fn cancel(self: *Operation) void {
        self.ticket.cancel();
    }
    pub fn result(self: *Operation) union(enum) { pending, ready, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return switch (self.ticket.status()) {
            .queued, .active => .pending,
            .done => if (self.failure) |failure| .{ .failed = failure } else .ready,
            .cancelling, .reusable, .cancelled => .{ .failed = Failure.init(.io, "native port operation was cancelled") },
        };
    }
    pub fn write(self: *Operation, bytes: []const u8) ?usize {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.ticket.isCancelled() or self.ticket.status() == .done or self.request_finished) return null;
        const count = @min(bytes.len, self.request.free());
        self.request.push(bytes[0..count]);
        self.notifyLocked();
        return count;
    }
    pub fn read(self: *Operation, bytes: []u8) ?usize {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.ticket.isCancelled()) return null;
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

const ControllerContext = struct { cell: *Cell, operation: ?*Operation, running: ?*controllers.Running = null };
fn context(raw: *anyopaque) *ControllerContext {
    return @ptrCast(@alignCast(raw));
}
fn controllerRead(raw: *anyopaque, bytes: [*]u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const op = context(raw).operation orelse return 0;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    while (!op.ticket.isCancelled() and op.request.len == 0 and !op.request_finished) op.changed.waitUncancelable(io(), &op.mutex);
    if (op.ticket.isCancelled()) return 0;
    const count = op.request.pop(bytes[0..@min(length, 64 * 1024)]);
    op.notifyLocked();
    return @intCast(count);
}
fn controllerWrite(raw: *anyopaque, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const op = context(raw).operation orelse return 0;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    while (!op.ticket.isCancelled() and op.response.free() == 0) op.changed.waitUncancelable(io(), &op.mutex);
    if (op.ticket.isCancelled()) return 0;
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
    return op.ticket.isCancelled();
}
fn controllerAcknowledge(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.cell.closed.load(.acquire) or ctx.cell.definition.cancellation != .acknowledge) return false;
    const op = ctx.operation orelse return false;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    const running = ctx.running orelse return false;
    return running.acknowledgeCancellation();
}
fn boundedErrorMessage(message: []const u8) []const u8 {
    var end = @min(message.len, abi.max_error_message_bytes);
    if (end < message.len) {
        while (end != 0 and message[end] & 0xc0 == 0x80) end -= 1;
    }
    return message[0..end];
}
fn controllerFail(raw: *anyopaque, kind: abi.ErrorKindWire, bytes: [*]const u8, length: u32) callconv(.c) void {
    const ctx = context(raw);
    const valid_kind: abi.ErrorKindWire = switch (kind) {
        .type, .shape, .conform, .overflow, .domain, .parse, .io, .user => kind,
        _ => .io,
    };
    const failure = Failure.init(valid_kind, boundedErrorMessage(bytes[0..length]));
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
