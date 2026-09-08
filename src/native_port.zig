//! Native controller ownership, bounded streams, and scheduler readiness.
const std = @import("std");
const abi = @import("native-abi");
const external = @import("external.zig");
const heap = @import("heap.zig");
const native = @import("native_module.zig");
const scheduler = @import("scheduler.zig");
const controllers = @import("port_controller.zig");
const transfers = @import("port_transfer.zig");
const Value = @import("value.zig").Value;
const list = @import("list.zig");
const descriptor = @import("native_descriptor.zig");
const port_message = @import("port_message.zig");
const byte_transport = @import("port_bytes.zig");
const message_builder = @import("port_builder.zig");
const message_transport = @import("port_messages.zig");
const ResourcePublication = @import("port_resource.zig").Publication;

const RegisteredState = struct {
    instance: *native.ModuleInstance,
    definition: u32,
};

/// A registered capability pins its issuing module instance. Its descriptor
/// index is sealed at module publication and cannot be supplied by ECL code.
pub const RegisteredCapability = opaque {
    fn state(self: *RegisteredCapability) *RegisteredState {
        return @ptrCast(@alignCast(self));
    }
    pub fn instance(self: *RegisteredCapability) *native.ModuleInstance {
        return self.state().instance;
    }
    pub fn definition(self: *RegisteredCapability) descriptor.PortCapability {
        const owned = self.state();
        return owned.instance.definition(owned.definition).body.port;
    }
    pub fn releasePort(self: *RegisteredCapability) void {
        const owned = self.state();
        const issuer = owned.instance;
        issuer.portAccess().state().allocator().destroy(owned);
        issuer.releasePin();
    }
};

pub fn registeredCapability(item: Value, comptime role: @import("value.zig").PortVariant) ?*RegisteredCapability {
    if (item != .port) return null;
    return heap.portPayload(RegisteredCapability, role, item.port);
}

/// Module publication owns the returned reference on success. Failure retains
/// the caller's module pin and publishes no partially initialized capability.
pub fn sealCapability(instance: *native.ModuleInstance, index: u32) error{OutOfMemory}!Value {
    const owner = instance.portAccess().state();
    const owned = try owner.allocator().create(RegisteredState);
    errdefer owner.allocator().destroy(owned);
    owned.* = .{ .instance = instance, .definition = index };
    lock(&owner.mutex);
    const identity = owner.identity;
    owner.identity +%= 1;
    unlock(&owner.mutex);
    const capability: *RegisteredCapability = @ptrCast(owned);
    const result = switch (instance.definition(index).body.port) {
        .factory => try heap.createBorrowedPort(RegisteredCapability, .factory, owner.allocator(), identity, capability),
        .operation => try heap.createBorrowedPort(RegisteredCapability, .operation_selector, owner.allocator(), identity, capability),
        .endpoint => try heap.createBorrowedPort(RegisteredCapability, .endpoint_selector, owner.allocator(), identity, capability),
    };
    instance.retain();
    return result;
}

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
    message_capacity: u32 = 16,
    message_queue_bytes: u32 = 1024 * 1024,

    pub fn validate(self: Limits) error{InvalidLimits}!void {
        if (self.max_live_ports == 0 or self.max_live_ports > 4096 or
            self.max_operations == 0 or self.max_operations > 256 or
            self.ring_capacity == 0 or self.ring_capacity > 16 * 1024 * 1024 or
            self.message_capacity == 0 or self.message_capacity > 16 or self.message_queue_bytes == 0)
            return error.InvalidLimits;
    }
};

pub const Failure = @import("port_failure.zig").Failure(abi.ErrorKindWire);

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
        state_value.* = .{ .host = host, .limits = limits, .executor = try controllers.Owner.init(host.allocator(), @as(usize, limits.max_live_ports) * (@min(limits.max_operations, abi.max_port_lanes) + 1) + 1) };
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
    /// Borrows validated configuration on either outcome; a created cell owns
    /// its independent retained reference before any controller starts.
    pub fn createConfigured(self: *Access, instance: *native.ModuleInstance, kind: u32, scope: *scheduler.TaskScope, config: *const port_message.Validated) CreateError!Value {
        const owner = self.state();
        if (instance.validated().port(kind).?.lane_count > owner.limits.max_operations) return error.InsufficientLanes;
        const cell = try Resource.create(owner, .{ instance, kind, config, scope.scheduler }, Cell.initializeAllocation);
        lock(&owner.mutex);
        const identity = owner.identity;
        owner.identity +%= 1;
        unlock(&owner.mutex);
        const item = heap.createOwnedPort(Cell, .resource, cell.allocator, identity, cell) catch |err| {
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
    .release = Cell.releaseReadiness,
    .retireAfterUnlock = Cell.retireDependency,
});

const Operations = controllers.Lane(Operation, .operation, .{
    .deinit = Operation.deinit,
    .runnable = Operation.runnable,
    .execute = Operation.execute,
    .notifyOperation = Operation.notifyLocked,
    .completeResource = Operation.completeResourceLocked,
    .retireOperation = Operation.settleScope,
    .cancelPolicy = Operation.cancelPolicy,
    .cancelResource = Operation.cancelResourceLocked,
});

pub const Cell = struct {
    pub const Admission = union(enum) { pending, closed, invalid_operation, operation: Value };
    allocator: std.mem.Allocator,
    owner: *OwnerState,
    scheduler: *const scheduler.WorkerScheduler,
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
    publication: union(enum) { published, provisional: *scheduler.ExternalGroup } = .published,
    dependency: union(enum) {
        independent,
        attached: struct { parent: *Cell, membership: external.ScopeMembership },
        retired,
    } = .independent,
    children: ?*scheduler.ExternalGroup = null,
    phase: enum { reserved, initializing, open, closing, cleaned, joined } = .reserved,
    initialization_failure: ?Failure = null,
    shutdown_state: union(enum) { idle, requested, running, completed: ?Failure, aborted } = .idle,
    configuration: ?Value = null,
    message_budget: *message_transport.Budget,
    resource_pipes: [64]?Protocol.Transport = .{null} ** 64,
    lanes: [abi.max_port_lanes]Operations,

    fn initializeAllocation(cell: *Cell, owner: *OwnerState, instance: *native.ModuleInstance, kind: u32, config: *const port_message.Validated, worker: *const scheduler.WorkerScheduler) error{OutOfMemory}!void {
        const allocator = owner.host.allocator();
        const definition = instance.validated().port(kind).?;
        const state = try allocator.alignedAlloc(u8, .@"64", definition.state_size);
        errdefer allocator.free(state);
        const group = try ControllerGroup.init(allocator, owner.executor.access(), cell);
        errdefer group.deinit();
        const message_budget = try message_transport.Budget.create(owner.host, owner.limits.message_queue_bytes);
        errdefer message_budget.release();
        cell.* = .{ .allocator = allocator, .owner = owner, .scheduler = worker, .instance = instance, .kind = kind, .definition = definition, .backend = state, .controllers = group, .message_budget = message_budget, .lanes = .{Operations.init(&cell.mutex)} ** abi.max_port_lanes };
        errdefer for (cell.resource_pipes) |pipe| if (pipe) |transport| transport.release();
        for (&cell.resource_pipes, 0..) |*slot, index| {
            const endpoint = instance.validated().endpoint(kind, @intCast(index), .resource) orelse continue;
            const transport = try Protocol.Transport.create(cell, switch (endpoint.transport) {
                .bytes => .bytes,
                .messages => .messages,
            });
            slot.* = transport;
        }
        cell.configuration = config.value();
        heap.retainValue(config.value());
        instance.retain();
    }
    pub fn retainReadiness(self: *Cell) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Cell) void {
        self.release();
    }
    pub fn retainExternalMember(self: *Cell) void {
        self.retainReadiness();
    }
    pub fn releaseExternalMember(self: *Cell) void {
        self.release();
    }
    pub fn cancelExternalMember(self: *Cell, scope: *external.ScopeIdentity) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        const dependent = switch (self.dependency) {
            .attached => |attachment| attachment.membership.authorizesCancellation(scope),
            .independent, .retired => false,
        };
        if (self.ownership.authorizesCancellation(scope) or dependent) self.closeLocked();
    }
    pub fn releasePort(self: *Cell) void {
        lock(&self.mutex);
        if (self.publication == .provisional) self.closeLocked();
        unlock(&self.mutex);
        self.release();
    }
    fn release(self: *Cell) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.publication == .provisional) self.publication.provisional.release();
        if (self.children) |children| children.release();
        if (self.configuration) |config| heap.hostDomain(self.owner.host).releaseValue(config);
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.release();
        self.message_budget.release();
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
            else => self.closed.load(.acquire) or self.shutdown_state != .idle or key - 2 >= self.definition.lane_count or
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
    pub fn shutdown(self: *Cell) union(enum) { pending, ready, unsupported, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.definition.shutdown == null) return .unsupported;
        switch (self.shutdown_state) {
            .idle => {
                if (self.closed.load(.acquire)) {
                    self.shutdown_state = .aborted;
                } else {
                    self.shutdown_state = .requested;
                    self.changed.broadcast(io());
                    self.waits.notifyLocked(self);
                }
            },
            .requested, .running, .completed, .aborted => {},
        }
        if (self.phase != .joined) return .pending;
        return switch (self.shutdown_state) {
            .completed => |failure| if (failure) |value| .{ .failed = value } else .ready,
            .idle, .requested, .running, .aborted => .{ .failed = Failure.init(.io, "resource closed before graceful shutdown completed") },
        };
    }
    fn closeLocked(self: *Cell) void {
        if (self.closed.swap(true, .acq_rel)) return;
        const notify_backend = self.phase == .initializing or self.phase == .open;
        self.phase = .closing;
        if (self.children) |children| children.close();
        // Total admission, across every lane, is capped at 256.
        for (self.lanes[0..self.definition.lane_count]) |*lane| {
            var ticket = lane.front();
            while (ticket) |current| : (ticket = current.successor()) current.owner().markCancelled();
        }
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.fail(.init(.io, "native resource is closed"), true);
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
        var controller_context: ControllerContext = .{ .cell = self, .invocation = .initialize };
        if (initialize) self.definition.initialize.?(self.backend.ptr, &controller_table, &controller_context);
        controller_context.deinit();
        lock(&self.mutex);
        if (self.initialization_failure != null) self.closed.store(true, .release);
        const lane_count = if (self.closed.load(.acquire)) 1 else self.definition.lane_count + @as(u32, @intFromBool(self.definition.shutdown != null));
        unlock(&self.mutex);
        execution.runLanes(lane_count, self, Cell.runLane, Cell.failLaneStartup, Cell.publishInitialization);
        // Every operation executor and cancellation notification has finished.
        // The root controller owns cleanup; its reaper joins it before detach.
        lock(&self.mutex);
        unlock(&self.mutex);
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.abort();
        if (self.children) |children| {
            children.close();
            children.join(execution);
        }
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
        self.changed.broadcast(io());
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
        cell.changed.broadcast(io());
    }
    fn retireDependency(self: *Cell) void {
        lock(&self.mutex);
        var token: ?external.ScopeMembership = switch (self.dependency) {
            .attached => |attachment| attachment.membership,
            .independent, .retired => null,
        };
        self.dependency = .retired;
        unlock(&self.mutex);
        if (token) |*membership| membership.detach();
    }
    pub fn childrenClosed(_: *Cell) void {}
    fn childGroup(self: *Cell) error{ OutOfMemory, Closed }!*scheduler.ExternalGroup {
        lock(&self.mutex);
        const existing = self.children;
        unlock(&self.mutex);
        if (existing) |group| return group;
        const candidate = try scheduler.ExternalGroup.create(self.scheduler, Cell, self);
        lock(&self.mutex);
        const closed = self.closed.load(.acquire);
        if (!closed and self.children == null) {
            self.children = candidate;
            unlock(&self.mutex);
            return candidate;
        }
        const selected = self.children;
        unlock(&self.mutex);
        candidate.release();
        return selected orelse error.Closed;
    }
    const Parent = struct { cell: *Cell, group: *scheduler.ExternalGroup };
    fn prepareChildStartup(self: *Cell, provisional: *scheduler.ExternalGroup, dependent: ?Parent) error{ OutOfMemory, ScopeClosing }!void {
        const Publication = struct {
            cell: *Cell,
            parent: ?*Cell,
            pub fn lock(item: *@This()) void {
                std.Io.Threaded.mutexLock(&item.cell.mutex);
            }
            pub fn unlock(item: *@This()) void {
                std.Io.Threaded.mutexUnlock(&item.cell.mutex);
            }
            pub fn validate(item: *@This()) bool {
                return !item.cell.closed.load(.acquire) and
                    (if (item.parent != null) item.cell.dependency == .independent else item.cell.ownership == .provisional);
            }
            pub fn publish(item: *@This(), tokens: [16]?external.ScopeMembership) void {
                if (item.parent) |parent| {
                    item.cell.dependency = .{ .attached = .{ .parent = parent, .membership = tokens[0].? } };
                } else item.cell.ownership = .{ .owned = tokens[0].? };
            }
        };
        var publication: Publication = .{ .cell = self, .parent = null };
        var incoming: [16]?external.ScopeMember = .{null} ** 16;
        incoming[0] = external.scopeMember(Cell, self);
        if (!try provisional.publish(incoming, &publication)) return error.ScopeClosing;
        if (dependent) |parent| {
            publication.parent = parent.cell;
            incoming = .{null} ** 16;
            incoming[0] = external.scopeMember(Cell, self);
            if (!try parent.group.publish(incoming, &publication)) return error.ScopeClosing;
        }
    }
    fn runShutdown(self: *Cell) void {
        lock(&self.mutex);
        while (self.shutdown_state == .idle and !self.closed.load(.acquire))
            self.changed.waitUncancelable(io(), &self.mutex);
        if (self.closed.load(.acquire)) {
            self.shutdown_state = .aborted;
            unlock(&self.mutex);
            return;
        }
        self.shutdown_state = .running;
        unlock(&self.mutex);
        var ctx: ControllerContext = .{ .cell = self, .invocation = .{ .shutdown = null } };
        defer ctx.deinit();
        self.definition.shutdown.?(self.backend.ptr, &controller_table, &ctx);
        lock(&self.mutex);
        self.shutdown_state = if (self.closed.load(.acquire)) .aborted else .{ .completed = ctx.invocation.shutdown };
        self.closeLocked();
        unlock(&self.mutex);
    }
    fn runLane(self: *Cell, index: usize) void {
        if (index == self.definition.lane_count) return self.runShutdown();
        const lane = &self.lanes[index];
        while (true) {
            lock(&self.mutex);
            while (!lane.dispatchable() and !self.closed.load(.acquire)) self.changed.waitUncancelable(io(), &self.mutex);
            const finished = lane.empty();
            unlock(&self.mutex);
            if (finished) return;
            _ = lane.runNext();
        }
    }
    pub fn admitOnLane(self: *Cell, code: u32, lane: u32, endpoints: u64, scope: *scheduler.TaskScope, request: *const port_message.Validated) error{ OutOfMemory, ScopeClosing }!Admission {
        lock(&self.mutex);
        const closed = self.closed.load(.acquire) or self.shutdown_state != .idle;
        const invalid = lane >= self.definition.lane_count;
        const full = !invalid and !self.lanes[lane].hasCapacity(self.laneCapacity(lane));
        unlock(&self.mutex);
        if (closed) return .closed;
        if (invalid) return .invalid_operation;
        if (full) return .pending;
        const op = Operation.create(self, code, lane, endpoints, request) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Closed => .closed,
            error.Full => .pending,
        };
        lock(&self.owner.mutex);
        const identity = self.owner.identity;
        self.owner.identity +%= 1;
        unlock(&self.owner.mutex);
        const item = heap.createOwnedPort(Operation, .exchange, self.allocator, identity, op) catch |err| {
            op.close();
            op.releaseReadiness();
            return err;
        };
        errdefer {
            op.close();
            heap.hostDomain(self.owner.host).releaseValue(item);
        }
        try transfers.publishScope(Operation, op, scope, Operation.transferOwnership);
        lock(&self.mutex);
        lock(&op.mutex);
        if (op.ownership.live()) _ = op.ticket.publish();
        unlock(&op.mutex);
        self.changed.broadcast(io());
        unlock(&self.mutex);
        return .{ .operation = item };
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

const Protocol = struct {
    parameters: Value,
    pipes: [64]?Transport = .{null} ** 64,

    const Transport = union(enum) {
        bytes: byte_transport.Pair,
        messages: message_transport.Pair,
        fn create(cell: *Cell, kind: enum { bytes, messages }) error{OutOfMemory}!Transport {
            // Construct a complete transport before publishing its variant in
            // an owning slot. Fallible arm initializers can otherwise expose
            // a tag whose payload was never initialized during rollback.
            switch (kind) {
                .bytes => {
                    const pair = byte_transport.create(cell.owner.host, cell.owner.limits.ring_capacity) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.InvalidCapacity => unreachable,
                    };
                    return .{ .bytes = pair };
                },
                .messages => {
                    const pair = message_transport.Queue.create(cell.message_budget, cell.owner.limits.message_capacity) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.InvalidCapacity => unreachable,
                    };
                    return .{ .messages = pair };
                },
            }
        }
        fn release(self: Transport) void {
            switch (self) {
                .bytes => |pair| pair.pipe.release(),
                .messages => |pair| pair.queue.release(),
            }
        }
        fn abort(self: Transport) void {
            switch (self) {
                .bytes => |pair| pair.pipe.fail(.init(.io, "native resource is closed"), true),
                .messages => |pair| pair.queue.abort(),
            }
        }
        fn interrupt(self: Transport) void {
            switch (self) {
                .bytes => |pair| pair.pipe.interrupt(),
                .messages => |pair| pair.queue.interrupt(),
            }
        }
        fn fail(self: Transport, failure: byte_transport.Failure, discard: bool) void {
            switch (self) {
                .bytes => |pair| pair.pipe.fail(failure, discard),
                .messages => |pair| pair.queue.fail(failure),
            }
        }
        fn finish(self: Transport) void {
            switch (self) {
                .bytes => |pair| pair.pipe.finish(),
                .messages => |pair| pair.queue.finish(),
            }
        }
    };

    fn init(cell: *Cell, endpoints: u64, parameters: *const port_message.Validated) error{OutOfMemory}!Protocol {
        heap.retainValue(parameters.value());
        var result: Protocol = .{ .parameters = parameters.value() };
        errdefer result.deinit(cell);
        for (&result.pipes, 0..) |*pipe, index| {
            const id: u6 = @intCast(index);
            if (endpoints & (@as(u64, 1) << id) == 0) continue;
            const definition = cell.instance.validated().endpoint(cell.kind, id, .exchange).?;
            const transport = try Transport.create(cell, switch (definition.transport) {
                .bytes => .bytes,
                .messages => .messages,
            });
            pipe.* = transport;
        }
        return result;
    }
    fn deinit(self: *Protocol, cell: *Cell) void {
        for (self.pipes) |pipe| if (pipe) |pair| pair.release();
        heap.hostDomain(cell.owner.host).releaseValue(self.parameters);
    }
};

pub const Operation = struct {
    const ControllerFailure = struct {
        value: Failure,
        disposition: enum { operation, resource },
    };
    allocator: std.mem.Allocator,
    cell: *Cell,
    code: u32,
    lane: u32,
    ticket: *Operations.Ticket,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Operation) = .{},
    protocol: Protocol,
    failure: ?ControllerFailure = null,
    // Transport borrows this monotonic interrupt latch while the controller
    // runs. The ticket remains the authority for terminal cancellation state.
    transport_cancelled: std.atomic.Value(bool) = .init(false),
    ownership: external.Ownership = .provisional,
    children: ?*scheduler.ExternalGroup = null,
    lifetime: enum { open, closing, closed } = .open,
    terminal_result: union(enum) { available: *message_transport.Envelope, claimed, discarded },
    endpoints: u64,

    fn create(cell: *Cell, code: u32, lane: u32, endpoints: u64, parameters: *const port_message.Validated) error{ OutOfMemory, Closed, Full }!*Operation {
        const allocator = cell.allocator;
        var protocol = try Protocol.init(cell, endpoints, parameters);
        errdefer protocol.deinit(cell);
        const terminal_value = try message_transport.Envelope.empty(cell.owner.host);
        errdefer terminal_value.release();
        const prepared = try cell.lanes[lane].prepare(allocator);
        errdefer prepared.discard();
        lock(&cell.mutex);
        defer unlock(&cell.mutex);
        if (cell.closed.load(.acquire) or cell.shutdown_state != .idle) return error.Closed;
        const ticket = prepared.admit(cell.laneCapacity(lane), .{ cell, code, lane, protocol, terminal_value, endpoints }, initialize) orelse return error.Full;
        cell.changed.broadcast(io());
        return ticket.owner();
    }
    fn initialize(op: *Operation, ticket: *Operations.Ticket, cell: *Cell, code: u32, lane: u32, protocol: Protocol, terminal_value: *message_transport.Envelope, endpoints: u64) void {
        op.* = .{ .allocator = cell.allocator, .cell = cell, .code = code, .lane = lane, .ticket = ticket, .protocol = protocol, .terminal_result = .{ .available = terminal_value }, .endpoints = endpoints };
        cell.retainReadiness();
    }
    fn runnable(self: *Operation) bool {
        return !self.cell.closed.load(.acquire);
    }
    fn execute(self: *Operation, running: *controllers.Running) void {
        var ctx: ControllerContext = .{ .cell = self.cell, .invocation = .{ .operation = .{ .value = self, .running = running } } };
        defer ctx.deinit();
        self.cell.definition.execute.?(self.cell.backend.ptr, self.code, &controller_table, &ctx);
    }
    fn completeResourceLocked(self: *Operation, outcome: controllers.Completion) void {
        if (outcome == .close_resource or (self.failure != null and self.failure.?.disposition == .resource)) self.cell.closeLocked();
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
            .retired => {
                cell.changed.broadcast(io());
                cell.waits.notifyLocked(cell);
            },
            .settled => {},
        }
    }
    pub fn retainReadiness(self: *Operation) void {
        self.ticket.retain();
    }
    pub fn releaseReadiness(self: *Operation) void {
        self.ticket.release();
    }
    pub fn releasePort(self: *Operation) void {
        self.releaseReadiness();
    }
    pub fn retainExternalMember(self: *Operation) void {
        self.retainReadiness();
    }
    pub fn releaseExternalMember(self: *Operation) void {
        self.releaseReadiness();
    }
    pub fn cancelExternalMember(self: *Operation, scope: *external.ScopeIdentity) void {
        lock(&self.mutex);
        const authorized = self.ownership.authorizesCancellation(scope);
        if (authorized and self.lifetime == .open) self.lifetime = .closing;
        unlock(&self.mutex);
        if (authorized) self.close();
    }
    /// Abort transport and retain scope membership until callback return. The
    /// lane's post-return hook settles membership outside both lifetime locks.
    pub fn close(self: *Operation) void {
        lock(&self.mutex);
        if (self.lifetime == .open) self.lifetime = .closing;
        unlock(&self.mutex);
        self.cancel();
        self.settleScope();
    }
    fn settleScope(self: *Operation) void {
        lock(&self.mutex);
        var detached: external.Ownership.Detached = .{};
        var discarded: ?*message_transport.Envelope = null;
        const terminal = switch (self.ticket.status()) {
            .done, .cancelled => true,
            .preparing, .queued, .active, .cancelling, .reusable => false,
        };
        const aborting = terminal and self.lifetime != .open;
        const children = if (aborting) self.children else null;
        if (aborting) {
            self.lifetime = .closing;
            if (self.terminal_result == .available) {
                discarded = self.terminal_result.available;
                self.terminal_result = .discarded;
            }
            self.notifyLocked();
        }
        unlock(&self.mutex);
        if (aborting) {
            for (self.protocol.pipes) |transport| if (transport) |pair| switch (pair) {
                .messages => |channel| channel.queue.abort(),
                .bytes => {},
            };
        }
        if (discarded) |item| item.release();
        if (children) |group| group.close();
        if (aborting and (children == null or children.?.closed())) {
            lock(&self.mutex);
            self.lifetime = .closed;
            detached = self.ownership.release();
            self.notifyLocked();
            unlock(&self.mutex);
        }
        detached.detachAll();
    }
    pub fn childrenClosed(self: *Operation) void {
        self.settleScope();
    }
    fn childGroup(self: *Operation) error{ OutOfMemory, Closed }!*scheduler.ExternalGroup {
        lock(&self.mutex);
        const existing = self.children;
        unlock(&self.mutex);
        if (existing) |group| return group;
        const candidate = try scheduler.ExternalGroup.create(self.cell.scheduler, Operation, self);
        lock(&self.mutex);
        const unavailable = self.lifetime != .open or self.ticket.isCancelled();
        if (!unavailable and self.children == null) {
            self.children = candidate;
            unlock(&self.mutex);
            return candidate;
        }
        const selected = self.children;
        unlock(&self.mutex);
        candidate.release();
        return selected orelse error.Closed;
    }
    fn stageChild(self: *Operation, kind: u32, configuration: *const port_message.Validated, dependency: abi.ChildDependency) CreateError!Value {
        const parent = self.cell;
        const owner = parent.owner;
        if (parent.instance.validated().port(kind).?.lane_count > owner.limits.max_operations) return error.InsufficientLanes;
        const provisional = try self.childGroup();
        const dependent: ?Cell.Parent = if (dependency == .dependent) .{ .cell = parent, .group = try parent.childGroup() } else null;
        const cell = try Resource.create(owner, .{ parent.instance, kind, configuration, parent.scheduler }, Cell.initializeAllocation);
        provisional.retain();
        cell.publication = .{ .provisional = provisional };
        std.Io.Threaded.mutexLock(&owner.mutex);
        const identity = owner.identity;
        owner.identity +%= 1;
        std.Io.Threaded.mutexUnlock(&owner.mutex);
        const item = heap.createOwnedPort(Cell, .resource, cell.allocator, identity, cell) catch |err| {
            cell.releasePort();
            return err;
        };
        errdefer heap.hostDomain(owner.host).releaseValue(item);
        cell.controllers.start(.{ provisional, dependent }, Cell.prepareChildStartup, Cell.run, Cell.abortStartup) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeClosing => error.ScopeClosing,
            error.Io, error.Closed => error.Io,
        };
        std.Io.Threaded.mutexLock(&cell.mutex);
        defer std.Io.Threaded.mutexUnlock(&cell.mutex);
        while (cell.phase == .reserved or cell.phase == .initializing) cell.changed.waitUncancelable(io(), &cell.mutex);
        if (cell.initialization_failure) |failure| if (failure == .out_of_memory) return error.OutOfMemory;
        if (cell.phase != .open or cell.initialization_failure != null) return error.Io;
        return item;
    }
    const Transfer = transfers.ScopeTransfer(Operation, transferOwnership, transferLive);
    fn transferOwnership(self: *Operation) *external.Ownership {
        return &self.ownership;
    }
    fn transferLive(self: *Operation) bool {
        return self.lifetime == .open;
    }
    pub fn prepareScopeTransfer(self: *Operation, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return Transfer.prepare(self, from, to);
    }
    pub fn commitScopeTransfer(self: *Operation) void {
        Transfer.commit(self);
    }
    pub fn abortScopeTransfer(self: *Operation) void {
        Transfer.abort(self);
    }
    pub fn closed(self: *Operation) bool {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return self.lifetime == .closed;
    }
    fn deinit(self: *Operation) void {
        if (self.children) |children| children.release();
        self.protocol.deinit(self.cell);
        switch (self.terminal_result) {
            .available => |item| item.release(),
            .claimed, .discarded => {},
        }
        self.cell.releaseReadiness();
    }
    pub fn registerReadiness(self: *Operation, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Operation).register(self, key, target);
    }
    pub fn readyLocked(self: *Operation, key: u64) bool {
        if (key == 4) return self.lifetime == .closed;
        if (key == 8) return self.ticket.status() == .done or self.ticket.status() == .cancelled;
        return self.ticket.status() == .done or self.ticket.isCancelled();
    }
    pub fn wakeReasonLocked(_: *Operation, _: u64) external.Wake {
        return .ready;
    }
    pub fn source(self: *Operation, interests: u32) external.ReadinessSource {
        return external.readinessSource(Operation, self, interests);
    }
    fn notifyLocked(self: *Operation) void {
        if (self.ticket.isCancelled()) {
            self.transport_cancelled.store(true, .release);
            if (self.children) |children| children.close();
            for (self.cell.resource_pipes) |pipe| if (pipe) |transport| transport.interrupt();
        }
        if (self.ticket.isCancelled() or self.ticket.status() == .done) {
            for (self.protocol.pipes, 0..) |pipe, index| if (pipe) |pair| {
                const endpoint = self.cell.instance.validated().endpoint(self.cell.kind, @intCast(index), .exchange).?;
                if (self.ticket.isCancelled()) {
                    pair.fail(byte_transport.Failure.init(.cancelled, "exchange was cancelled"), false);
                } else if (endpoint.direction == .input) {
                    pair.fail(byte_transport.Failure.init(.io, "exchange input consumer completed"), true);
                } else if (self.failure) |failure| {
                    pair.fail(switch (failure.value) {
                        .out_of_memory => .out_of_memory,
                        .report => |report| byte_transport.Failure.init(descriptor.mapErrorKind(report.kind) orelse .io, report.message[0..report.len]),
                    }, false);
                } else pair.finish();
            };
        }
        self.changed.broadcast(io());
        self.waits.notifyLocked(self);
    }
    fn markCancelled(self: *Operation) void {
        lock(&self.mutex);
        // The resource's lane list contains only outstanding exchanges.
        // Abort their ownership explicitly; a completed exchange has its own
        // scope lifetime and must not infer abortion from resource closure.
        if (self.lifetime == .open) self.lifetime = .closing;
        self.ticket.requestCancellation();
        self.notifyLocked();
        unlock(&self.mutex);
    }
    pub fn cancel(self: *Operation) void {
        self.ticket.cancel();
    }
    pub fn completion(self: *Operation) union(enum) { pending, ready, cancelled, failed: Failure } {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        return switch (self.ticket.status()) {
            .preparing, .queued, .active, .cancelling, .reusable => .pending,
            .done => if (self.failure) |failure| .{ .failed = failure.value } else .ready,
            .cancelled => .cancelled,
        };
    }
    /// The caller reserves its output capacity before entering this consuming
    /// transition. Success moves the result; every other outcome retains it.
    const Claim = union(enum) { pending, claimed, value: Value, cancelled, failed: Failure };
    pub fn claimResult(self: *Operation, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing, Overflow }!Claim {
        lock(&self.mutex);
        const view = if (self.terminal_result == .available) self.terminal_result.available.borrow() else null;
        unlock(&self.mutex);
        defer if (view) |item| item.release();
        const handoff = try ResourcePublication.init(self.cell.owner.host, if (view) |item| item.attachments() else &.{});
        defer if (handoff) |publication| publication.deinit();
        var publication: ResultPublication = .{ .operation = self, .view = view, .handoff = handoff };
        _ = try scope.scheduler.publishExternalBatch(scope, if (handoff) |children| children.members() else .{null} ** 16, &publication);
        if (publication.consumed) |item| item.release();
        return publication.result;
    }
    const ResultPublication = struct {
        operation: *Operation,
        view: ?*message_transport.View,
        handoff: ?*ResourcePublication,
        consumed: ?*message_transport.Envelope = null,
        result: Claim = .pending,
        pub fn lock(self: *@This()) void {
            std.Io.Threaded.mutexLock(&self.operation.mutex);
            if (self.handoff) |handoff| handoff.lock();
        }
        pub fn unlock(self: *@This()) void {
            if (self.handoff) |handoff| handoff.unlock();
            std.Io.Threaded.mutexUnlock(&self.operation.mutex);
        }
        pub fn validate(self: *@This()) bool {
            const op = self.operation;
            switch (op.ticket.status()) {
                .preparing, .queued, .active, .cancelling, .reusable => return false,
                .cancelled => {
                    self.result = .cancelled;
                    return false;
                },
                .done => {},
            }
            self.result = if (op.failure) |failure| .{ .failed = failure.value } else switch (op.terminal_result) {
                .claimed => .claimed,
                .discarded => .{ .failed = Failure.init(.io, "exchange result was discarded by close") },
                .available => |item| available: {
                    if (self.view == null or !self.view.?.observes(item)) break :available .pending;
                    if (self.handoff) |handoff| if (!handoff.validate()) break :available .pending;
                    break :available .{ .value = item.value() };
                },
            };
            return self.result == .value;
        }
        pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
            if (self.handoff) |handoff| handoff.publish(tokens);
            const item = self.operation.terminal_result.available;
            heap.retainValue(item.value());
            self.consumed = item;
            self.operation.terminal_result = .claimed;
        }
    };
};

pub fn exchangeFromValue(item: Value) ?*Operation {
    if (item != .port) return null;
    return heap.portPayload(Operation, .exchange, item.port);
}

const EndpointParent = union(enum) {
    resource: *Cell,
    exchange: *Operation,
    fn cell(self: EndpointParent) *Cell {
        return switch (self) {
            .resource => |resource| resource,
            .exchange => |operation| operation.cell,
        };
    }
    fn retain(self: EndpointParent) void {
        switch (self) {
            .resource => |resource| resource.retainReadiness(),
            .exchange => |operation| operation.retainReadiness(),
        }
    }
    fn release(self: EndpointParent) void {
        switch (self) {
            .resource => |resource| resource.releaseReadiness(),
            .exchange => |operation| operation.releaseReadiness(),
        }
    }
    fn transport(self: EndpointParent, index: u32) ?Protocol.Transport {
        if (index >= 64) return null;
        return switch (self) {
            .resource => |resource| resource.resource_pipes[index],
            .exchange => |operation| if (operation.endpoints & (@as(u64, 1) << @as(u6, @intCast(index))) != 0) operation.protocol.pipes[index] else null,
        };
    }
};
const EndpointState = struct {
    parent: EndpointParent,
    loan: union(enum) { reader: *byte_transport.Pipe, writer: *byte_transport.Pipe, receiver: *message_transport.Queue, sender: *message_transport.Queue },
};

/// The endpoint's variant is its complete transport authority. Its retained
/// parent identity keeps the transport alive without transferring scope.
pub const Endpoint = opaque {
    fn state(self: *Endpoint) *EndpointState {
        return @ptrCast(@alignCast(self));
    }
    pub fn reader(self: *Endpoint) ?*byte_transport.Pipe {
        return switch (self.state().loan) {
            .reader => |pipe| pipe,
            .writer, .receiver, .sender => null,
        };
    }
    pub fn writer(self: *Endpoint) ?*byte_transport.Pipe {
        return switch (self.state().loan) {
            .writer => |pipe| pipe,
            .reader, .receiver, .sender => null,
        };
    }
    pub fn releasePort(self: *Endpoint) void {
        const owned = self.state();
        const parent = owned.parent;
        const owner = parent.cell().owner;
        owner.allocator().destroy(owned);
        parent.release();
    }
    pub fn receiver(self: *Endpoint) ?*message_transport.Queue {
        return switch (self.state().loan) {
            .receiver => |queue| queue,
            .reader, .writer, .sender => null,
        };
    }
    pub fn sender(self: *Endpoint) ?*message_transport.Queue {
        return switch (self.state().loan) {
            .sender => |queue| queue,
            .reader, .writer, .receiver => null,
        };
    }
};

pub fn endpointFromValue(item: Value) ?*Endpoint {
    if (item != .port) return null;
    return heap.portPayload(Endpoint, .endpoint, item.port);
}

/// Failure leaves both inputs owned by their caller. Success retains the
/// source identity and publishes an attenuated borrow, never another owner.
pub fn borrowEndpoint(parent: Value, selector: *RegisteredCapability) error{ OutOfMemory, WrongKind, Unsupported }!Value {
    const spec = switch (selector.definition()) {
        .endpoint => |endpoint| endpoint,
        else => return error.WrongKind,
    };
    const source: EndpointParent = switch (spec.owner) {
        .resource => .{ .resource = if (parent == .port) heap.portPayload(Cell, .resource, parent.port) orelse return error.WrongKind else return error.WrongKind },
        .exchange => .{ .exchange = exchangeFromValue(parent) orelse return error.WrongKind },
    };
    const cell = source.cell();
    if (cell.instance != selector.instance() or cell.kind != spec.resource) return error.WrongKind;
    return createEndpoint(source, spec);
}

fn createEndpoint(source: EndpointParent, spec: descriptor.EndpointDefinition) error{ OutOfMemory, Unsupported }!Value {
    const pair = source.transport(spec.id) orelse return error.Unsupported;
    const owner = source.cell().owner;
    const owned = try owner.allocator().create(EndpointState);
    errdefer owner.allocator().destroy(owned);
    owned.* = .{ .parent = source, .loan = switch (pair) {
        .bytes => |transport| switch (spec.direction) {
            .input => .{ .writer = transport.pipe },
            .output => .{ .reader = transport.pipe },
        },
        .messages => |transport| switch (spec.direction) {
            .input => .{ .sender = transport.queue },
            .output => .{ .receiver = transport.queue },
        },
    } };
    lock(&owner.mutex);
    const identity = owner.identity;
    owner.identity +%= 1;
    unlock(&owner.mutex);
    const result = try heap.createBorrowedPort(Endpoint, .endpoint, owner.allocator(), identity, @ptrCast(owned));
    source.retain();
    return result;
}

const ControllerContext = struct {
    cell: *Cell,
    invocation: union(enum) { initialize, operation: struct { value: *Operation, running: *controllers.Running }, shutdown: ?Failure },
    received: ?*message_transport.Envelope = null,
    builder: ?*message_builder.Builder = null,
    fn cancellation(self: *ControllerContext) *const std.atomic.Value(bool) {
        return if (self.operation()) |op| &op.transport_cancelled else &self.cell.closed;
    }
    fn deinit(self: *ControllerContext) void {
        if (self.received) |item| item.release();
        if (self.builder) |builder| builder.retire();
    }
    fn operation(self: *ControllerContext) ?*Operation {
        return switch (self.invocation) {
            .operation => |active| active.value,
            .initialize, .shutdown => null,
        };
    }
};
fn context(raw: *anyopaque) *ControllerContext {
    return @ptrCast(@alignCast(raw));
}
fn controllerParent(raw: *anyopaque, identity: *const anyopaque) callconv(.c) ?*anyopaque {
    const cell = context(raw).cell;
    lock(&cell.mutex);
    defer unlock(&cell.mutex);
    const parent = switch (cell.dependency) {
        .attached => |attachment| attachment.parent,
        .independent, .retired => return null,
    };
    if (parent.instance != cell.instance or parent.definition.identity != identity) return null;
    // Membership remains attached until child cleanup and controller join.
    // The parent joins it before destroying the borrowed native state.
    return parent.backend.ptr;
}

fn controllerInput(raw: *anyopaque, path: [*]const u64, depth: u32, output: *abi.ValueView) callconv(.c) bool {
    if (depth > abi.max_read_path_depth or output.size != @sizeOf(abi.ValueView)) return false;
    const ctx = context(raw);
    const root: ?Value = if (ctx.operation()) |operation| operation.protocol.parameters else ctx.cell.configuration;
    return viewMessage(root, path, depth, output);
}
fn viewMessage(root: ?Value, path: [*]const u64, depth: u32, output: *abi.ValueView) bool {
    if (depth > abi.max_read_path_depth or output.size != @sizeOf(abi.ValueView)) return false;
    var item = root orelse {
        if (depth != 0) return false;
        output.* = .{ .kind = .list };
        return true;
    };
    item = valueAtPath(item, path[0..depth]) orelse return false;
    output.* = switch (item) {
        .int => |number| .{ .kind = .int, .scalar_bits = @bitCast(number) },
        .float => |number| .{ .kind = .float, .scalar_bits = @bitCast(number) },
        .char => |codepoint| .{ .kind = .char, .scalar_bits = codepoint },
        .symbol => |id| .{ .kind = .symbol, .bytes_ptr = @import("intern.zig").get(id).ptr, .bytes_len = @import("intern.zig").get(id).len },
        .list => |header| .{ .kind = .list, .aggregate_len = header.length() },
        .dict => |header| .{ .kind = .dict, .aggregate_len = header.length() },
        .port => .{ .kind = .port },
        .word, .task, .module => return false,
    };
    return true;
}
fn valueAtPath(root: Value, path: []const u64) ?Value {
    if (path.len > abi.max_read_path_depth) return null;
    var item = root;
    for (path) |index| {
        item = switch (item) {
            .list => |header| if (index < header.length()) list.atUnchecked(item, @intCast(index)) else return null,
            .dict => |header| if (index / 2 < header.length()) (if (index % 2 == 0)
                @import("dict.zig").keyAt(header, @intCast(index / 2))
            else
                @import("dict.zig").valueAt(header, @intCast(index / 2))) else return null,
            else => return null,
        };
    }
    return item;
}
fn controllerBuildMessage(raw: *anyopaque, request: *const abi.MessageBuildRequest) callconv(.c) abi.HostStatus {
    const ctx = context(raw);
    return buildMessage(ctx, request) catch |err| {
        if (ctx.builder) |builder| builder.invalidate();
        recordControllerFailure(ctx, switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Overflow => .init(.overflow, "native message exceeds its structured value or queue limits"),
            error.InvalidValue => .init(.type, "native message contains an invalid structured value"),
            error.DuplicateKey => .init(.domain, "native message dictionary contains duplicate keys"),
            error.InvalidState => .init(.domain, "invalid native message construction or endpoint"),
        });
        return if (err == error.OutOfMemory) .out_of_memory else .invalid;
    };
}
fn buildMessage(ctx: *ControllerContext, request: *const abi.MessageBuildRequest) message_builder.Error!abi.HostStatus {
    if (request.size != @sizeOf(abi.MessageBuildRequest)) return error.InvalidState;
    const op = ctx.operation() orelse return error.InvalidState;
    if (controllerCancelled(ctx)) return .invalid;
    if (ctx.builder == null) {
        const builder = try message_builder.Builder.create(ctx.cell.owner.host);
        ctx.builder = builder;
    }
    const builder = ctx.builder.?;
    switch (request.action) {
        .scalar => {
            if (request.scalar.size != @sizeOf(abi.Scalar)) return error.InvalidState;
            const scalar = request.scalar;
            switch (scalar.kind) {
                .int => try builder.int(@bitCast(scalar.bits)),
                .float => try builder.float(@bitCast(scalar.bits)),
                .char => try builder.char(scalar.bits),
                .symbol => {
                    if (scalar.bytes_len > 64 * 1024) return error.Overflow;
                    const bytes = if (scalar.bytes_len == 0) "" else (scalar.bytes_ptr orelse return error.InvalidValue)[0..@intCast(scalar.bytes_len)];
                    try builder.symbol(bytes);
                },
                .word, .list, .dict, .port => return error.InvalidValue,
                _ => return error.InvalidValue,
            }
        },
        .copy_input, .copy_received => {
            if (request.depth > abi.max_read_path_depth) return error.InvalidValue;
            const path = if (request.depth == 0) &.{} else (request.path orelse return error.InvalidValue)[0..request.depth];
            const root = if (request.action == .copy_received)
                (ctx.received orelse return error.InvalidState).value()
            else
                op.protocol.parameters;
            try builder.copy(valueAtPath(root, path) orelse return error.InvalidValue);
        },
        .reply_endpoint => {
            if (request.endpoint >= 64) return error.InvalidState;
            const spec = ctx.cell.instance.validated().endpoint(ctx.cell.kind, @intCast(request.endpoint), .exchange) orelse return error.InvalidState;
            if (spec.transport != .messages or spec.direction != .input) return error.InvalidState;
            const reply = createEndpoint(.{ .exchange = op }, spec) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Unsupported => error.InvalidState,
            };
            defer heap.hostDomain(ctx.cell.owner.host).releaseValue(reply);
            try builder.copy(reply);
        },
        .child => {
            const configuration = builder.childConfiguration() orelse return error.InvalidState;
            const identity = request.kind_identity orelse return error.InvalidValue;
            const dependency: abi.ChildDependency = @enumFromInt(request.count);
            switch (dependency) {
                .independent, .dependent => {},
                _ => return error.InvalidState,
            }
            var index: u32 = 0;
            const kind = while (ctx.cell.instance.validated().port(index)) |definition| : (index += 1) {
                if (definition.identity == identity) break index;
            } else return error.InvalidState;
            const child = op.stageChild(kind, configuration, dependency) catch |err| {
                recordControllerFailure(ctx, switch (err) {
                    error.OutOfMemory => .out_of_memory,
                    error.Limit => .init(.overflow, "native child resource limit exceeded"),
                    error.Closed, error.ScopeClosing => .init(.io, "native child owner is closing"),
                    error.InsufficientLanes => .init(.domain, "native child requires more controller lanes"),
                    error.Io => .init(.io, "native child initialization failed"),
                });
                return if (err == error.OutOfMemory) .out_of_memory else .invalid;
            };
            defer heap.hostDomain(ctx.cell.owner.host).releaseValue(child);
            try builder.replaceChild(child);
        },
        .prepare_child => try builder.prepareChild(),
        .list => try builder.list(request.count),
        .dictionary => try builder.dictionary(request.count),
        .finish => try builder.finish(),
        .advance => {},
        .clear => builder.clear(),
        .send => {
            const validated = builder.validated() orelse return error.InvalidState;
            const pair = controllerQueue(ctx, request.owner, request.endpoint, .output) orelse return error.InvalidState;
            if (validated.footprint().bytes > ctx.cell.owner.limits.message_queue_bytes) return error.Overflow;
            const item = try message_transport.Envelope.create(ctx.cell.owner.host, validated);
            if (!pair.controller.send(item, ctx.cancellation())) {
                item.release();
                return .invalid;
            }
            try builder.consume();
            return .ok;
        },
        .result => {
            const validated = builder.validated() orelse return error.InvalidState;
            const item = try message_transport.Envelope.create(ctx.cell.owner.host, validated);
            lock(&op.mutex);
            const previous = op.terminal_result.available;
            op.terminal_result = .{ .available = item };
            unlock(&op.mutex);
            previous.release();
            try builder.consume();
            return .ok;
        },
        _ => return error.InvalidState,
    }
    return switch (try builder.advance()) {
        .pending => .yield_required,
        .complete => .ok,
    };
}
fn controllerCancelled(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.cell.closed.load(.acquire)) return true;
    const op = ctx.operation() orelse return false;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    return op.ticket.isCancelled();
}

fn controllerEndpointParent(ctx: *ControllerContext, owner: abi.EndpointOwner) ?EndpointParent {
    return switch (owner) {
        .resource => .{ .resource = ctx.cell },
        .exchange => .{ .exchange = ctx.operation() orelse return null },
        _ => null,
    };
}
fn controllerPipe(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, direction: enum { input, output }) ?byte_transport.Pair {
    const source = controllerEndpointParent(context(raw), owner) orelse return null;
    const cell = source.cell();
    if (index >= 64) return null;
    const endpoint = cell.instance.validated().endpoint(cell.kind, @intCast(index), switch (source) {
        .resource => .resource,
        .exchange => .exchange,
    }) orelse return null;
    if (endpoint.transport != .bytes or switch (direction) {
        .input => endpoint.direction != .input,
        .output => endpoint.direction != .output,
    }) return null;
    const transport = source.transport(index) orelse return null;
    return switch (transport) {
        .bytes => |pair| pair,
        .messages => null,
    };
}
fn controllerReadEndpoint(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, bytes: [*]u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const pair = controllerPipe(raw, owner, index, .input) orelse {
        const text = "controller selected an unsupported byte input";
        controllerFail(raw, .domain, text.ptr, text.len);
        return 0;
    };
    pair.pipe.beginRead() catch {
        const text = "byte endpoint already has a pending reader";
        controllerFail(raw, .contract, text.ptr, text.len);
        return 0;
    };
    defer pair.pipe.endRead();
    return @intCast(pair.controller.read(bytes[0..@min(length, 64 * 1024)], context(raw).cancellation()));
}
fn controllerWriteEndpoint(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    if (length == 0) return 0;
    const pair = controllerPipe(raw, owner, index, .output) orelse {
        const text = "controller selected an unsupported byte output";
        controllerFail(raw, .domain, text.ptr, text.len);
        return 0;
    };
    return @intCast(pair.controller.write(bytes[0..@min(length, 64 * 1024)], context(raw).cancellation()));
}
fn controllerFinishEndpoint(raw: *anyopaque, owner: abi.EndpointOwner, index: u32) callconv(.c) bool {
    if (controllerQueue(raw, owner, index, .output)) |pair| {
        pair.queue.finish();
    } else {
        const pair = controllerPipe(raw, owner, index, .output) orelse return false;
        pair.pipe.finish();
    }
    return true;
}

fn controllerQueue(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, direction: enum { input, output }) ?message_transport.Pair {
    const source = controllerEndpointParent(context(raw), owner) orelse return null;
    const cell = source.cell();
    if (index >= 64) return null;
    const endpoint = cell.instance.validated().endpoint(cell.kind, @intCast(index), switch (source) {
        .resource => .resource,
        .exchange => .exchange,
    }) orelse return null;
    if (endpoint.transport != .messages or switch (direction) {
        .input => endpoint.direction != .input,
        .output => endpoint.direction != .output,
    }) return null;
    const transport = source.transport(index) orelse return null;
    return switch (transport) {
        .messages => |pair| pair,
        .bytes => null,
    };
}
fn controllerReceiveMessage(raw: *anyopaque, owner: abi.EndpointOwner, index: u32) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.received != null) return false;
    const pair = controllerQueue(raw, owner, index, .input) orelse return false;
    pair.queue.beginRead() catch {
        const text = "message endpoint already has a pending receiver";
        controllerFail(raw, .contract, text.ptr, text.len);
        return false;
    };
    defer pair.queue.endRead();
    ctx.received = pair.controller.receive(ctx.cancellation());
    return ctx.received != null;
}
fn controllerReceivedMessage(raw: *anyopaque, path: [*]const u64, depth: u32, output: *abi.ValueView) callconv(.c) bool {
    const item = context(raw).received orelse return false;
    return viewMessage(item.value(), path, depth, output);
}
fn controllerForwardMessage(raw: *anyopaque, owner: abi.EndpointOwner, index: u32) callconv(.c) bool {
    const ctx = context(raw);
    const item = ctx.received orelse return false;
    const pair = controllerQueue(raw, owner, index, .output) orelse return false;
    if (!pair.controller.send(item, ctx.cancellation())) return false;
    ctx.received = null;
    return true;
}
fn controllerResultMessage(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    const op = ctx.operation() orelse return false;
    const item = ctx.received orelse return false;
    item.releaseQueueCapacity();
    lock(&op.mutex);
    const previous = op.terminal_result.available;
    op.terminal_result = .{ .available = item };
    unlock(&op.mutex);
    ctx.received = null;
    previous.release();
    return true;
}
fn controllerDiscardMessage(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    const item = ctx.received orelse return false;
    ctx.received = null;
    item.release();
    return true;
}
fn controllerAcknowledge(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.cell.closed.load(.acquire) or ctx.cell.definition.cancellation != .acknowledge) return false;
    const op = ctx.operation() orelse return false;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    const running = ctx.invocation.operation.running;
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
    recordControllerFailure(context(raw), reportedFailure(kind, bytes[0..length]));
}
fn controllerFailResource(raw: *anyopaque, kind: abi.ErrorKindWire, bytes: [*]const u8, length: u32) callconv(.c) void {
    const ctx = context(raw);
    const failure = reportedFailure(kind, bytes[0..length]);
    if (ctx.operation()) |op| {
        recordOperationFailure(op, .{ .value = failure, .disposition = .resource });
    } else recordControllerFailure(ctx, failure);
}
fn reportedFailure(kind: abi.ErrorKindWire, bytes: []const u8) Failure {
    const valid_kind: abi.ErrorKindWire = switch (kind) {
        .type, .shape, .conform, .overflow, .domain, .parse, .io, .user, .contract => kind,
        _ => .io,
    };
    return Failure.init(valid_kind, boundedErrorMessage(bytes));
}
fn controllerFailAllocation(raw: *anyopaque) callconv(.c) void {
    recordControllerFailure(context(raw), .out_of_memory);
}
fn recordControllerFailure(ctx: *ControllerContext, failure: Failure) void {
    if (ctx.operation()) |op| {
        recordOperationFailure(op, .{ .value = failure, .disposition = .operation });
    } else switch (ctx.invocation) {
        .initialize => {
            lock(&ctx.cell.mutex);
            storeControllerFailure(&ctx.cell.initialization_failure, failure);
            unlock(&ctx.cell.mutex);
        },
        .shutdown => storeControllerFailure(&ctx.invocation.shutdown, failure),
        .operation => unreachable,
    }
}
fn recordOperationFailure(op: *Operation, failure: Operation.ControllerFailure) void {
    lock(&op.mutex);
    defer unlock(&op.mutex);
    if (op.failure) |*prior| {
        if (failure.value == .out_of_memory) prior.value = failure.value;
        if (failure.disposition == .resource) prior.disposition = .resource;
    } else op.failure = failure;
}
fn storeControllerFailure(destination: *?Failure, failure: Failure) void {
    // Preserve the originating failure during controller unwind. Allocation
    // exhaustion takes precedence and cannot be masked by a later report.
    if (destination.* != null and failure != .out_of_memory) return;
    destination.* = failure;
}
const controller_table: abi.ControllerTable = .{ .fail_resource = controllerFailResource, .parent_state = controllerParent, .discard_message = controllerDiscardMessage, .build_message = controllerBuildMessage, .fail_allocation = controllerFailAllocation, .receive_message = controllerReceiveMessage, .received_message = controllerReceivedMessage, .forward_message = controllerForwardMessage, .result_message = controllerResultMessage, .input = controllerInput, .read_endpoint = controllerReadEndpoint, .write_endpoint = controllerWriteEndpoint, .finish_endpoint = controllerFinishEndpoint, .cancelled = controllerCancelled, .acknowledge_cancellation = controllerAcknowledge, .fail = controllerFail };

pub fn fromValue(value: Value, instance: *native.ModuleInstance, kind: u32) ?*Cell {
    const handle = switch (value) {
        .port => |port| port,
        else => return null,
    };
    const cell = heap.portPayload(Cell, .resource, handle) orelse return null;
    return if (cell.instance == instance and cell.kind == kind) cell else null;
}
