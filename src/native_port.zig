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
const diagnostics = @import("port_error_data.zig");
const results = @import("port_result.zig");
const exchanges = @import("port_exchange.zig");
const factories = @import("port_factory.zig");
const resource_api = @import("port_resource.zig");
const endpoint_api = @import("port_endpoint.zig");

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
    pub fn allocator(self: *RegisteredCapability) std.mem.Allocator {
        return self.instance().portAccess().state().allocator();
    }
    pub fn messageLimits(self: *RegisteredCapability) port_message.Limits {
        return self.instance().portAccess().state().limits.message_limits;
    }
    pub fn definition(self: *RegisteredCapability) descriptor.PortCapability {
        const owned = self.state();
        return owned.instance.definition(owned.definition).body.port;
    }
    pub fn borrowEndpoint(self: *RegisteredCapability, source: Value) endpoint_api.BorrowError!Value {
        return borrowRegisteredEndpoint(source, self);
    }
    pub fn acceptsOperation(self: *RegisteredCapability, source: Value) bool {
        for (self.definition().operation) |operation| if (fromValue(source, self.instance(), operation.resource) != null) return true;
        return false;
    }
    pub fn beginOperation(self: *RegisteredCapability, source: Value, scope: *scheduler.TaskScope, request: *const port_message.Validated) exchanges.AdmitError!exchanges.Admission {
        for (self.definition().operation) |operation| {
            const cell = fromValue(source, self.instance(), operation.resource) orelse continue;
            return cell.admitOnLane(.{ .code = operation.code, .lane = operation.lane, .endpoints = operation.endpoints, .mode = operation.mode }, scope, request);
        }
        return error.WrongKind;
    }
    pub fn openResource(self: *RegisteredCapability, opening: factories.Context, config: *const port_message.Validated) error{OutOfMemory}!factories.Start {
        const issuer = self.instance();
        const resource = issuer.portAccess().createConfigured(issuer, self.definition().factory, opening.scope, config) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Limit => if (issuer.validated().port(self.definition().factory).?.capacity_failure != null)
                .{ .opening = try RejectedOpening.create(issuer, self.definition().factory, config) }
            else
                .{ .failed = factories.Failure.init(.domain, "port resource capacity is exhausted") },
            error.InsufficientLanes => .{ .failed = factories.Failure.init(.domain, "port resource capacity is exhausted") },
            error.Closed, error.Io => .{ .failed = factories.Failure.init(.io, "port resource creation failed") },
            error.ScopeClosing => .{ .failed = factories.Failure.init(.cancelled, "port scope is closing") },
        };
        return .{ .resource = resource };
    }
    pub fn releasePort(self: *RegisteredCapability) void {
        const owned = self.state();
        const issuer = owned.instance;
        issuer.portAccess().state().allocator().destroy(owned);
        issuer.releasePin();
    }
};

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
        .factory => try factories.Factory.create(RegisteredCapability, identity, capability),
        .operation => try exchanges.Selector.create(RegisteredCapability, identity, capability),
        .endpoint => try endpoint_api.Selector.create(RegisteredCapability, identity, capability),
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
    max_live_ports: ?usize = 64,
    max_operations: u32 = 16,
    ring_capacity: usize = 64 * 1024,
    message_capacity: u32 = 16,
    message_queue_bytes: u32 = 1024 * 1024,
    message_limits: port_message.Limits = .{},
    builder_slots: usize = 4096,

    /// Shared extension capacity keeps its existing bounded admission policy.
    pub fn validate(self: Limits) error{InvalidLimits}!void {
        try self.validateInstance();
        const count = self.max_live_ports orelse return error.InvalidLimits;
        if (count > 4096 or self.ring_capacity > 16 * 1024 * 1024) return error.InvalidLimits;
    }
    /// A host may grant a service independent capacity. Unlimited resource
    /// counts additionally require a cooperative-only validated descriptor.
    pub fn validateInstance(self: Limits) error{InvalidLimits}!void {
        if ((if (self.max_live_ports) |count| count == 0 else false) or
            self.max_operations == 0 or self.max_operations > 256 or
            self.ring_capacity == 0 or self.message_capacity == 0 or
            self.message_capacity > 16 or self.message_queue_bytes == 0 or
            self.message_limits.bytes == 0 or self.message_limits.nodes == 0 or
            self.builder_slots == 0 or self.builder_slots > self.message_limits.nodes) return error.InvalidLimits;
    }
};

pub const Failure = @import("port_failure.zig").Failure(abi.ErrorKindWire);

fn semanticFailure(failure: Failure) byte_transport.Failure {
    return switch (failure) {
        .out_of_memory => .out_of_memory,
        .report => |report| byte_transport.Failure.init(descriptor.mapErrorKind(report.kind) orelse .io, report.message[0..report.len]),
    };
}

const Resource = transfers.Resource(Cell, OwnerState, OwnerState.allocator, OwnerState.reserveLive, OwnerState.releaseLive);

const OwnerState = struct {
    fn builderLimits(self: *const OwnerState) message_builder.Limits {
        return .{ .message = self.limits.message_limits, .stack_slots = self.limits.builder_slots };
    }

    host: *const heap.HostCleanup,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    closing: std.atomic.Value(bool) = .init(false),
    root_admission: ?*const std.atomic.Value(bool) = null,
    live: usize = 0,
    identity: u64 = 1,
    execution: union(enum) { controller: *controllers.Owner, cooperative },

    fn allocator(self: *OwnerState) std.mem.Allocator {
        return self.host.allocator();
    }
    fn reserveLive(self: *OwnerState) error{ Closed, Limit }!void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.closing.load(.acquire) or
            (if (self.root_admission) |root| root.load(.acquire) else false)) return error.Closed;
        if (self.live == (self.limits.max_live_ports orelse std.math.maxInt(usize))) return error.Limit;
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
        return initialize(host, limits, .controller);
    }
    fn initialize(host: *const heap.HostCleanup, limits: Limits, mode: std.meta.Tag(@FieldType(OwnerState, "execution"))) error{ OutOfMemory, InvalidLimits }!*Owner {
        const state_value = try host.allocator().create(OwnerState);
        errdefer host.allocator().destroy(state_value);
        const execution: @FieldType(OwnerState, "execution") = switch (mode) {
            .cooperative => .cooperative,
            .controller => allocation: {
                const count = limits.max_live_ports orelse return error.InvalidLimits;
                const per_resource: usize = @min(limits.max_operations, abi.max_port_lanes) + 1 + @import("port-declarations").max_activities;
                const slots = std.math.mul(usize, count, per_resource) catch return error.InvalidLimits;
                const capacity = std.math.add(usize, slots, 1) catch return error.InvalidLimits;
                const executor = try controllers.Owner.init(host.allocator(), capacity);
                break :allocation .{ .controller = executor };
            },
        };
        state_value.* = .{ .host = host, .limits = limits, .execution = execution };
        return ownerFromState(state_value);
    }
    pub fn ringCapacityLimit(self: *Owner) usize {
        return self.state().limits.ring_capacity;
    }
    pub fn access(self: *Owner) *Access {
        return @ptrCast(self);
    }
    /// The parent closes admission for every instance. The returned owner
    /// must be joined and destroyed before its parent owner is destroyed.
    pub fn initInstance(self: *Owner, limits: Limits, validated: *const descriptor.ValidatedDescriptor) error{ OutOfMemory, InvalidLimits }!*Owner {
        try limits.validateInstance();
        var kind: u32 = 0;
        const mode: std.meta.Tag(@FieldType(OwnerState, "execution")) = scan: {
            while (validated.port(kind)) |definition| : (kind += 1) {
                if (definition.execution == .controller) break :scan .controller;
            }
            break :scan .cooperative;
        };
        const instance = try initialize(self.state().host, limits, mode);
        instance.state().root_admission = self.state().root_admission orelse &self.state().closing;
        return instance;
    }
    pub fn closeCreation(self: *Owner) void {
        const state_value = self.state();
        lock(&state_value.mutex);
        state_value.closing.store(true, .release);
        unlock(&state_value.mutex);
    }
    pub fn deinit(self: *Owner) void {
        const state_value = self.state();
        self.closeCreation();
        switch (state_value.execution) {
            .controller => |executor| executor.deinit(),
            .cooperative => {},
        }
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
        const cell = Resource.create(owner, .{ instance, kind, config, scope.scheduler }, ResourceAdapter.initializeAllocation) catch |err| return switch (err) {
            error.InvalidLimits => error.InsufficientLanes,
            else => |failure| failure,
        };
        lock(&owner.mutex);
        const identity = owner.identity;
        owner.identity +%= 1;
        unlock(&owner.mutex);
        const item = resource_api.Resource.create(Cell, .staged, identity, cell) catch |err| {
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

pub const Cell = @import("port_service.zig").Resource(ResourceAdapter);
const ResourceAdapter = struct {
    pub const Exchange = @import("port_operation.zig").Exchange(OperationAdapter);
    pub const Request = struct { code: u32, lane: u32, endpoints: u64, mode: @import("port_operation.zig").Mode };
    owner: *OwnerState,
    instance: *native.ModuleInstance,
    kind: u32,
    definition: descriptor.PortDefinition,
    backend: []align(64) u8,
    configuration: ?Value = null,
    initialization_context: ?*ControllerContext = null,
    message_budget: *message_transport.Budget,
    resource_pipes: [64]?Protocol.Transport = .{null} ** 64,
    pub fn allocator(self: *const ResourceAdapter) std.mem.Allocator {
        return self.owner.host.allocator();
    }
    pub fn executor(self: *const ResourceAdapter) *controllers.Executor {
        return switch (self.owner.execution) {
            .controller => |owner| owner.access(),
            .cooperative => unreachable,
        };
    }
    pub fn nextIdentity(self: *ResourceAdapter) u64 {
        lock(&self.owner.mutex);
        defer unlock(&self.owner.mutex);
        const identity = self.owner.identity;
        self.owner.identity +%= 1;
        return identity;
    }
    pub fn operationLane(_: *ResourceAdapter, selected: Request) u32 {
        return selected.lane;
    }
    pub fn prepareOperation(_: *ResourceAdapter, cell: *Cell, selected: Request, request: *const port_message.Validated, lane: *Operation.Lane) error{OutOfMemory}!*Operation.Prepared {
        return OperationAdapter.prepare(cell, selected.code, selected.lane, selected.endpoints, selected.mode, request, lane);
    }
    pub fn retire(_: *ResourceAdapter, cell: *Cell) void {
        Resource.retire(cell);
    }
    pub fn destroy(self: *ResourceAdapter, cell: *Cell) void {
        if (self.configuration) |config| heap.hostDomain(self.owner.host).releaseValue(config);
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.release();
        self.message_budget.release();
        self.instance.releasePin();
        cell.allocator.free(self.backend);
        Resource.destroy(cell);
    }
    pub fn initState(self: *ResourceAdapter) void {
        self.definition.wire.init_state.?(self.backend.ptr);
    }
    pub fn initializeBackend(self: *ResourceAdapter, cell: *Cell) void {
        var ctx: ControllerContext = .{ .cell = cell, .invocation = .initialize };
        defer ctx.deinit();
        self.definition.wire.initialize.?(self.backend.ptr, &controller_table, &ctx);
    }
    pub fn runActivity(self: *ResourceAdapter, cell: *Cell, index: u32) void {
        const activity = self.definition.execution.controller.activities[index].?;
        var ctx: ControllerContext = .{ .cell = cell, .invocation = .{ .activity = .{ .index = index } } };
        defer ctx.deinit();
        activity.execute(self.backend.ptr, &controller_table, &ctx);
        for (self.resource_pipes, 0..) |transport, endpoint_index| {
            if (activity.endpoints & (@as(u64, 1) << @as(u6, @intCast(endpoint_index))) == 0) continue;
            const pair = transport.?;
            const endpoint = self.instance.validated().endpoint(self.kind, @intCast(endpoint_index), .resource).?;
            if (ctx.invocation.activity.failure) |failure| pair.fail(semanticFailure(failure), endpoint.direction == .input) else if (endpoint.direction == .input) pair.fail(.init(.io, "native input consumer completed"), true) else pair.finish();
        }
    }
    pub fn advanceInitialize(self: *ResourceAdapter, cell: *Cell) scheduler.Cooperative.Progress {
        if (self.initialization_context == null) {
            const ctx = self.allocator().create(ControllerContext) catch {
                cell.failInitialization(.out_of_memory);
                return .completed;
            };
            ctx.* = .{ .cell = cell, .invocation = .initialize, .cooperative = .{} };
            self.initialization_context = ctx;
        }
        const ctx = self.initialization_context.?;
        ctx.cooperative = .{};
        const progress = cooperativeProgress(ctx, self.definition.execution.cooperative.initialize(self.backend.ptr, &cooperative_table, ctx));
        if (progress == .completed) {
            if (ctx.builder == .cooperative and ctx.builder.cooperative.phase != .idle)
                recordControllerFailure(ctx, .init(.contract, "initializer completed unfinished construction"));
            self.retireInitializationContext();
        }
        return progress;
    }
    fn retireInitializationContext(self: *ResourceAdapter) void {
        if (self.initialization_context) |ctx| {
            self.initialization_context = null;
            ctx.deinit();
            self.allocator().destroy(ctx);
        }
    }
    pub fn advanceCleanup(self: *ResourceAdapter, cell: *Cell) scheduler.Cooperative.Progress {
        self.retireInitializationContext();
        var ctx: ControllerContext = .{ .cell = cell, .invocation = .cleanup, .cooperative = .{} };
        defer ctx.deinit();
        return cooperativeProgress(&ctx, self.definition.execution.cooperative.retire(self.backend.ptr, &cooperative_table, &ctx));
    }
    pub fn cancel(self: *ResourceAdapter) void {
        switch (self.definition.execution) {
            .controller => self.definition.wire.cancel.?(self.backend.ptr),
            .cooperative => {},
        }
    }
    pub fn failTransport(self: *ResourceAdapter) void {
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.fail(.init(.io, "native resource is closed"), true);
    }
    pub fn abortTransport(self: *ResourceAdapter) void {
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.abort();
    }
    pub fn cleanup(self: *ResourceAdapter) void {
        self.definition.wire.cleanup.?(self.backend.ptr);
    }
    pub fn shutdown(self: *ResourceAdapter, cell: *Cell) ?byte_transport.Failure {
        var ctx: ControllerContext = .{ .cell = cell, .invocation = .{ .shutdown = null } };
        defer ctx.deinit();
        self.definition.wire.shutdown.?(self.backend.ptr, &controller_table, &ctx);
        return if (ctx.invocation.shutdown) |failure| semanticFailure(failure) else null;
    }
    fn initializeAllocation(cell: *Cell, owner: *OwnerState, instance: *native.ModuleInstance, kind: u32, config: *const port_message.Validated, worker: *const scheduler.WorkerScheduler) error{ OutOfMemory, InvalidLimits, Io }!void {
        const memory = owner.host.allocator();
        const definition = instance.validated().port(kind).?;
        const state = try memory.alignedAlloc(u8, .@"64", definition.wire.state_size);
        errdefer memory.free(state);
        const message_budget = try message_transport.Budget.create(owner.host, owner.limits.message_queue_bytes);
        errdefer message_budget.release();
        const adapter: ResourceAdapter = .{ .owner = owner, .instance = instance, .kind = kind, .definition = definition, .backend = state, .message_budget = message_budget };
        switch (definition.execution) {
            .controller => try cell.initialize(adapter, worker, definition.wire.lane_count, owner.limits.max_operations, definition.wire.shutdown != null, definition.execution.controller.activityCount()),
            .cooperative => try cell.initializeCooperative(adapter, worker, definition.wire.lane_count, owner.limits.max_operations),
        }
        errdefer cell.controllers.deinit();
        errdefer for (cell.adapter.resource_pipes) |pipe| if (pipe) |transport| transport.release();
        for (&cell.adapter.resource_pipes, 0..) |*slot, index| {
            const endpoint = instance.validated().endpoint(kind, @intCast(index), .resource) orelse continue;
            const transport = try Protocol.Transport.create(cell, .resource, @intCast(index), endpoint.transport);
            slot.* = transport;
        }
        cell.adapter.configuration = config.value();
        heap.retainValue(config.value());
        instance.retain();
    }
};

const Protocol = struct {
    parameters: Value,
    pipes: [64]?Transport = .{null} ** 64,

    const Transport = union(enum) {
        bytes: byte_transport.Pair,
        messages: message_transport.Pair,
        fn create(cell: *Cell, endpoint_owner: enum { resource, exchange }, endpoint: u6, kind: @import("port-declarations").Transport) error{OutOfMemory}!Transport {
            // Construct a complete transport before publishing its variant in
            // an owning slot. Fallible arm initializers can otherwise expose
            // a tag whose payload was never initialized during rollback.
            switch (kind) {
                .bytes => {
                    const pair = byte_transport.create(cell.adapter.owner.host, (if (endpoint_owner == .resource) cell.adapter.instance.endpointCapacity(cell.adapter.kind, endpoint) else cell.adapter.owner.limits.ring_capacity)) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.InvalidCapacity => unreachable,
                    };
                    return .{ .bytes = pair };
                },
                .messages => {
                    const pair = message_transport.Queue.create(cell.adapter.message_budget, cell.adapter.owner.limits.message_capacity) catch |err| return switch (err) {
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
            const definition = cell.adapter.instance.validated().endpoint(cell.adapter.kind, id, .exchange).?;
            const transport = try Transport.create(cell, .exchange, id, definition.transport);
            pipe.* = transport;
        }
        return result;
    }
    fn deinit(self: *Protocol, cell: *Cell) void {
        for (self.pipes) |pipe| if (pipe) |pair| pair.release();
        heap.hostDomain(cell.adapter.owner.host).releaseValue(self.parameters);
    }
};

pub const Operation = @import("port_operation.zig").Exchange(OperationAdapter);
const OperationAdapter = struct {
    const ControllerFailure = struct { value: Failure, disposition: enum { operation, resource } };
    cell: *Cell,
    code: u32,
    lane: u32,
    protocol: Protocol,
    failure: ?ControllerFailure = null,
    endpoints: u64,
    continuation: ?*CooperativeInvocation = null,
    pub fn allocator(self: *const OperationAdapter) std.mem.Allocator {
        return self.cell.allocator;
    }
    pub fn scheduler(self: *OperationAdapter) *const @import("scheduler.zig").WorkerScheduler {
        return self.cell.scheduler;
    }
    pub fn resourceMutex(self: *OperationAdapter) *std.Io.Mutex {
        return &self.cell.mutex;
    }
    pub fn admittedLocked(self: *OperationAdapter) void {
        self.cell.changed.broadcast(io());
        self.cell.controllers.wake();
    }
    pub fn retireValue(self: *OperationAdapter, item: Value) void {
        heap.hostDomain(self.cell.adapter.owner.host).releaseValue(item);
    }
    pub fn retainResource(self: *OperationAdapter) void {
        self.cell.retainReadiness();
    }
    pub fn deinit(self: *OperationAdapter) void {
        if (self.continuation) |continuation| {
            continuation.deinit();
            self.allocator().destroy(continuation);
        }
        self.protocol.deinit(self.cell);
        self.cell.releaseReadiness();
    }
    pub fn terminal(self: *OperationAdapter) results.Terminal {
        return if (self.failure) |failure| .{ .failed = semanticFailure(failure.value) } else .success;
    }
    pub fn abortTransport(self: *OperationAdapter) void {
        for (self.protocol.pipes) |transport| if (transport) |pair| switch (pair) {
            .messages => |channel| channel.queue.abort(),
            .bytes => {},
        };
    }
    pub fn prepare(cell: *Cell, code: u32, lane: u32, endpoints: u64, mode: @import("port_operation.zig").Mode, parameters: *const port_message.Validated, queue: *Operation.Lane) error{OutOfMemory}!*Operation.Prepared {
        var protocol = try Protocol.init(cell, endpoints, parameters);
        errdefer protocol.deinit(cell);
        const terminal_value = try results.Result.create(cell.adapter.owner.host);
        errdefer terminal_value.release();
        const continuation = switch (cell.adapter.definition.execution) {
            .controller => null,
            .cooperative => blk: {
                const owned = try cell.allocator.create(CooperativeInvocation);
                owned.* = .{};
                break :blk owned;
            },
        };
        errdefer if (continuation) |owned| cell.allocator.destroy(owned);
        return Operation.prepare(.{ .cell = cell, .code = code, .lane = lane, .protocol = protocol, .endpoints = endpoints, .continuation = continuation }, terminal_value, queue, mode);
    }
    pub fn runnable(self: *OperationAdapter) bool {
        return !self.cell.closed.load(.acquire);
    }
    pub fn execute(self: *OperationAdapter, operation: *Operation, running: *controllers.Running) void {
        var ctx: ControllerContext = .{ .cell = self.cell, .invocation = .{ .operation = .{ .value = operation, .running = running } } };
        defer ctx.deinit();
        self.cell.adapter.definition.wire.execute.?(self.cell.adapter.backend.ptr, self.code, &controller_table, &ctx);
    }
    pub fn advanceCooperative(self: *OperationAdapter, operation: *Operation, running: *controllers.Running) controllers.Progress {
        return self.continuation.?.advance(self, operation, running);
    }
    pub fn completeResourceLocked(self: *OperationAdapter, outcome: controllers.Completion) void {
        if (outcome == .close_resource or (self.failure != null and self.failure.?.disposition == .resource)) self.cell.closeLocked();
        self.cell.waits.notifyLocked(self.cell);
    }
    pub fn cancelPolicy(self: *OperationAdapter) controllers.CallbackCancellation {
        return switch (self.cell.adapter.definition.wire.cancellation) {
            .close_resource => .close_resource,
            .acknowledge => .acknowledge,
            _ => unreachable,
        };
    }
    pub fn cancelResourceLocked(self: *OperationAdapter, action: controllers.CancelAction) void {
        const cell = self.cell;
        switch (action) {
            .close_resource => cell.closeLocked(),
            .interrupt => switch (cell.adapter.definition.execution) {
                .controller => cell.adapter.definition.wire.cancel_operation.?(cell.adapter.backend.ptr, self.lane),
                .cooperative => cell.controllers.wake(),
            },
            .retired => {
                cell.controllers.wake();
                cell.changed.broadcast(io());
                cell.waits.notifyLocked(cell);
            },
            .settled => {},
        }
    }
    pub fn notifyTransport(self: *OperationAdapter, operation: *Operation) void {
        if (operation.ticket.isCancelled()) {
            for (self.cell.adapter.resource_pipes) |pipe| if (pipe) |transport| transport.interrupt();
        }
        if (operation.ticket.isCancelled() or operation.ticket.status() == .done) {
            for (self.protocol.pipes, 0..) |pipe, index| if (pipe) |pair| {
                const endpoint = self.cell.adapter.instance.validated().endpoint(self.cell.adapter.kind, @intCast(index), .exchange).?;
                if (operation.ticket.isCancelled()) {
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
    }
    fn stageChild(self: *OperationAdapter, operation: *Operation, kind: u32, configuration: *const port_message.Validated, dependency: abi.ChildDependency) CreateError!Value {
        const item = try self.startChild(operation, kind, configuration, dependency, .controller);
        errdefer heap.hostDomain(self.cell.adapter.owner.host).releaseValue(item);
        const cell = resource_api.Resource.project(Cell, item).?;
        std.Io.Threaded.mutexLock(&cell.mutex);
        defer std.Io.Threaded.mutexUnlock(&cell.mutex);
        while (cell.phase == .reserved or cell.phase == .initializing) cell.changed.waitUncancelable(io(), &cell.mutex);
        if (cell.initialization_failure) |failure| if (failure == .out_of_memory) return error.OutOfMemory;
        if (cell.phase != .open or cell.initialization_failure != null) return error.Io;
        return item;
    }
    const ChildMode = enum { controller, cooperative };
    fn StartedChild(comptime mode: ChildMode) type {
        return if (mode == .controller) Value else struct { value: Value, readiness: external.RegisterResult };
    }
    fn startChild(self: *OperationAdapter, operation: *Operation, kind: u32, configuration: *const port_message.Validated, dependency: abi.ChildDependency, comptime mode: ChildMode) CreateError!StartedChild(mode) {
        const parent = self.cell;
        const owner = parent.adapter.owner;
        const provisional = try operation.childGroup();
        const dependent: ?Cell.Parent = .{ .cell = parent, .group = try parent.childGroup(), .lifetime = switch (dependency) {
            .dependent => .resource,
            .independent => .initialization,
            _ => unreachable,
        } };
        const cell = Resource.create(owner, .{ parent.adapter.instance, kind, configuration, parent.scheduler }, ResourceAdapter.initializeAllocation) catch |err| return switch (err) {
            error.InvalidLimits => error.InsufficientLanes,
            else => |failure| failure,
        };
        cell.publication = resource_api.PublicationAuthority.create(cell.allocator, provisional) catch |err| {
            cell.releasePort();
            return err;
        };
        std.Io.Threaded.mutexLock(&owner.mutex);
        const identity = owner.identity;
        owner.identity +%= 1;
        std.Io.Threaded.mutexUnlock(&owner.mutex);
        const item = resource_api.Resource.create(Cell, .staged, identity, cell) catch |err| {
            cell.releasePort();
            return err;
        };
        errdefer heap.hostDomain(owner.host).releaseValue(item);
        const waiting = if (mode == .cooperative) try cell.prepareInitializationWait(external.wakeTarget(ChildWake, ChildWake.borrow(operation))) else {};
        errdefer if (mode == .cooperative) waiting.discard();
        cell.controllers.start(.{ provisional, dependent }, Cell.prepareChildStartup, Cell.run, Cell.abortStartup) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeClosing => error.ScopeClosing,
            error.Io, error.Closed => error.Io,
        };
        return if (mode == .controller) item else .{ .value = item, .readiness = waiting.register() };
    }
};

/// A child readiness notification can only schedule its parent invocation;
/// cancellation of the registration joins callbacks before releasing that pin.
const ChildWake = opaque {
    fn borrow(owned: *Operation) *ChildWake {
        return @ptrCast(owned);
    }
    fn operation(self: *ChildWake) *Operation {
        return @ptrCast(@alignCast(self));
    }
    pub fn retainExternalWake(self: *ChildWake) void {
        self.operation().retainReadiness();
    }
    pub fn releaseExternalWake(self: *ChildWake) void {
        self.operation().releaseReadiness();
    }
    pub fn wakeExternal(self: *ChildWake, _: external.Wake) void {
        self.operation().adapter.cell.controllers.wake();
    }
};

pub fn exchangeFromValue(item: Value) ?*Operation {
    return exchanges.Exchange.project(Operation, item);
}

const EndpointParent = union(enum) {
    resource: *Cell,
    exchange: *Operation,
    fn cell(self: EndpointParent) *Cell {
        return switch (self) {
            .resource => |resource| resource,
            .exchange => |operation| operation.adapter.cell,
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
            .resource => |resource| resource.adapter.resource_pipes[index],
            .exchange => |operation| if (operation.adapter.endpoints & (@as(u64, 1) << @as(u6, @intCast(index))) != 0) operation.adapter.protocol.pipes[index] else null,
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
    pub const Permit = byte_transport.WritePermit;
    pub fn allocator(self: *Endpoint) std.mem.Allocator {
        return self.state().parent.cell().adapter.owner.allocator();
    }
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
    pub fn beginRead(self: *Endpoint) error{Busy}!void {
        self.reader().?.beginRead() catch return error.Busy;
    }
    pub fn endRead(self: *Endpoint) void {
        self.reader().?.endRead();
    }
    pub fn readCapacity(self: *Endpoint) usize {
        return self.reader().?.readCapacity();
    }
    pub fn read(self: *Endpoint, destination: []u8) byte_transport.Read {
        return self.reader().?.read(destination);
    }
    pub fn readSource(self: *Endpoint) external.ReadinessSource {
        return self.reader().?.readSource();
    }
    pub fn beginWrite(self: *Endpoint) error{ OutOfMemory, Finished }!*Permit {
        return self.writer().?.beginWrite();
    }
    pub fn writeBytes(permit: *Permit, source: []const u8) byte_transport.Write {
        return permit.write(source);
    }
    pub fn finish(self: *Endpoint) void {
        self.writer().?.finish();
    }
    pub fn releasePort(self: *Endpoint) void {
        const owned = self.state();
        const parent = owned.parent;
        const owner = parent.cell().adapter.owner;
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

/// Failure leaves both inputs owned by their caller. Success retains the
/// source identity and publishes an attenuated borrow, never another owner.
fn borrowRegisteredEndpoint(parent: Value, selector: *RegisteredCapability) error{ OutOfMemory, WrongKind, Unsupported }!Value {
    const spec = switch (selector.definition()) {
        .endpoint => |endpoint| endpoint,
        else => return error.WrongKind,
    };
    const source: EndpointParent = switch (spec.owner) {
        .resource => .{ .resource = resource_api.Resource.project(Cell, parent) orelse return error.WrongKind },
        .exchange => .{ .exchange = exchangeFromValue(parent) orelse return error.WrongKind },
    };
    const cell = source.cell();
    if (cell.adapter.instance != selector.instance() or cell.adapter.kind != spec.resource) return error.WrongKind;
    return createEndpoint(source, spec);
}

fn createEndpoint(source: EndpointParent, spec: descriptor.EndpointDefinition) error{ OutOfMemory, Unsupported }!Value {
    const pair = source.transport(spec.id) orelse return error.Unsupported;
    const owner = source.cell().adapter.owner;
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
    const result = switch (owned.loan) {
        inline else => |_, direction| try endpoint_api.Endpoint.create(Endpoint, @field(endpoint_api.Direction, @tagName(direction)), identity, @ptrCast(owned)),
    };
    source.retain();
    return result;
}

const ControllerContext = struct {
    cell: *Cell,
    invocation: union(enum) { initialize, operation: struct { value: *Operation, running: ?*controllers.Running }, activity: struct { index: u32, failure: ?Failure = null }, shutdown: ?Failure, cleanup },
    received: ?*message_transport.Envelope = null,
    builder: union(enum) {
        none,
        controller: *message_builder.Builder,
        cooperative: CooperativeConstruction,
    } = .none,
    cooperative: ?struct { budget: u32 = 256, wait: union(enum) { none, timer: scheduler.Deadline, readiness } = .none } = null,
    symbol_bytes: [256]u8 = @splat(0),
    fn cancellation(self: *ControllerContext) *const std.atomic.Value(bool) {
        return if (self.operation()) |op| &op.transport_cancelled else &self.cell.closed;
    }
    fn deinit(self: *ControllerContext) void {
        if (self.received) |item| item.release();
        self.received = null;
        switch (self.builder) {
            .none => {},
            .controller => |builder| builder.retire(),
            .cooperative => |*builder| builder.retire(self.cell.adapter.owner.host),
        }
        self.builder = .none;
    }
    fn operation(self: *ControllerContext) ?*Operation {
        return switch (self.invocation) {
            .operation => |active| active.value,
            .initialize, .activity, .shutdown, .cleanup => null,
        };
    }
};

const ChildRequest = struct { kind: u32, dependency: abi.ChildDependency };
const CooperativeConstruction = struct {
    value: *message_builder.ResumableBuilder,
    phase: union(enum) { idle, working, result, error_data, child_configuration: ChildRequest, child: OperationAdapter.StartedChild(.cooperative) } = .idle,
    fn retire(self: *CooperativeConstruction, host: *const heap.HostCleanup) void {
        if (self.phase == .child) {
            switch (self.phase.child.readiness) {
                .ready => {},
                .registered => |*registration| registration.cancel(),
            }
            heap.hostDomain(host).releaseValue(self.phase.child.value);
        }
        self.value.retire();
    }
};

fn childRequest(ctx: *ControllerContext, request: *const abi.MessageBuildRequest) message_builder.Error!ChildRequest {
    const identity = request.kind_identity orelse return error.InvalidValue;
    const dependency: abi.ChildDependency = @enumFromInt(request.count);
    switch (dependency) {
        .independent, .dependent => {},
        _ => return error.InvalidState,
    }
    var index: u32 = 0;
    while (ctx.cell.adapter.instance.validated().port(index)) |definition| : (index += 1) {
        if (definition.wire.identity == identity) return .{ .kind = index, .dependency = dependency };
    }
    return error.InvalidState;
}

fn childCreationFailure(ctx: *ControllerContext, err: CreateError) abi.HostStatus {
    recordControllerFailure(ctx, switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Limit => .init(.overflow, "native child resource limit exceeded"),
        error.Closed, error.ScopeClosing => .init(.io, "native child owner is closing"),
        error.InsufficientLanes => .init(.domain, "native child requires more controller lanes"),
        error.Io => .init(.io, "native child initialization failed"),
    });
    return if (err == error.OutOfMemory) .out_of_memory else .invalid;
}
fn context(raw: *anyopaque) *ControllerContext {
    return @ptrCast(@alignCast(raw));
}
fn controllerParent(raw: *anyopaque, identity: *const anyopaque) callconv(.c) ?*anyopaque {
    const cell = context(raw).cell;
    lock(&cell.mutex);
    defer unlock(&cell.mutex);
    const parent = switch (cell.dependency) {
        .attached => |attachment| attachment.parent,
        .independent, .initializing, .retired => return null,
    };
    if (parent.adapter.instance != cell.adapter.instance or parent.adapter.definition.wire.identity != identity) return null;
    // Membership remains attached until child cleanup and controller join.
    // The parent joins it before destroying the borrowed native state.
    return parent.adapter.backend.ptr;
}

fn controllerInitializationParent(raw: *anyopaque, identity: *const anyopaque) callconv(.c) ?*anyopaque {
    const ctx = context(raw);
    if (ctx.invocation != .initialize) return null;
    const cell = ctx.cell;
    lock(&cell.mutex);
    defer unlock(&cell.mutex);
    const parent = switch (cell.dependency) {
        .attached, .initializing => |attachment| attachment.parent,
        .independent, .retired => return null,
    };
    if (parent.adapter.instance != cell.adapter.instance or parent.adapter.definition.wire.identity != identity) return null;
    return parent.adapter.backend.ptr;
}

fn controllerInstance(raw: *anyopaque, identity: *const anyopaque) callconv(.c) ?*anyopaque {
    return context(raw).cell.adapter.instance.instanceState(identity);
}

fn controllerInput(raw: *anyopaque, path: [*]const u64, depth: u32, output: *abi.ValueView) callconv(.c) bool {
    if (depth > abi.max_read_path_depth or output.size != @sizeOf(abi.ValueView)) return false;
    const ctx = context(raw);
    if (ctx.invocation == .activity) return false;
    const root: ?Value = if (ctx.operation()) |operation| operation.adapter.protocol.parameters else ctx.cell.adapter.configuration;
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
        .list => |header| .{ .kind = .list, .aggregate_len = header.length(), .text = if (item.isString()) .string else .none },
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
    return buildMessage(ctx, request) catch |err| constructionFailure(ctx, err);
}
fn constructionFailure(ctx: *ControllerContext, err: message_builder.Error) abi.HostStatus {
    if (err == error.Cancelled) return .invalid;
    switch (ctx.builder) {
        .none => {},
        .controller => |builder| builder.invalidate(),
        .cooperative => |builder| builder.value.invalidate(),
    }
    recordControllerFailure(ctx, switch (err) {
        error.Cancelled => unreachable,
        error.OutOfMemory => .out_of_memory,
        error.Overflow => .init(.overflow, "native message exceeds its structured value or queue limits"),
        error.InvalidValue => .init(.type, "native message contains an invalid structured value"),
        error.DuplicateKey => .init(.domain, "native message dictionary contains duplicate keys"),
        error.InvalidState => .init(.domain, "invalid native message construction or endpoint"),
    });
    return if (err == error.OutOfMemory) .out_of_memory else .invalid;
}
fn buildMessage(ctx: *ControllerContext, request: *const abi.MessageBuildRequest) message_builder.Error!abi.HostStatus {
    if (request.size != @sizeOf(abi.MessageBuildRequest)) return error.InvalidState;
    const op = ctx.operation();
    if (op == null and ctx.invocation != .initialize) return error.InvalidState;
    if (controllerCancelled(ctx)) return .invalid;
    if (ctx.builder == .none) {
        const builder = if (op != null)
            try message_builder.Builder.createConfigured(ctx.cell.adapter.owner.host, ctx.invocation.operation.running.?, ctx.cell.adapter.owner.builderLimits())
        else
            try message_builder.Builder.createInitializingConfigured(ctx.cell.adapter.owner.host, &ctx.cell.closed, ctx.cell.adapter.owner.builderLimits());
        ctx.builder = .{ .controller = builder };
    }
    const builder = ctx.builder.controller;
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
            else if (op) |operation| operation.adapter.protocol.parameters else (ctx.cell.adapter.configuration orelse return error.InvalidState);
            try builder.copy(valueAtPath(root, path) orelse return error.InvalidValue);
        },
        .reply_endpoint => {
            if (request.endpoint >= 64) return error.InvalidState;
            const parent = controllerEndpointParent(ctx, request.owner) orelse return error.InvalidState;
            const spec = ctx.cell.adapter.instance.validated().endpoint(ctx.cell.adapter.kind, @intCast(request.endpoint), switch (parent) {
                .resource => .resource,
                .exchange => .exchange,
            }) orelse return error.InvalidState;
            if (spec.transport != .messages or spec.direction != .input) return error.InvalidState;
            const reply = createEndpoint(parent, spec) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Unsupported => error.InvalidState,
            };
            defer heap.hostDomain(ctx.cell.adapter.owner.host).releaseValue(reply);
            try builder.copy(reply);
        },
        .child => {
            try builder.prepareChild();

            const configuration = builder.childConfiguration() orelse return error.InvalidState;
            const selected = try childRequest(ctx, request);
            const child = (op orelse return error.InvalidState).adapter.stageChild(op.?, selected.kind, configuration, selected.dependency) catch |err| return childCreationFailure(ctx, err);
            defer heap.hostDomain(ctx.cell.adapter.owner.host).releaseValue(child);
            try builder.replaceChild(child);
        },
        .list => try builder.list(request.count),
        .dictionary => try builder.dictionary(request.count),
        .clear => try builder.clear(),
        .send => {
            try builder.finish();

            const validated = builder.validated() orelse return error.InvalidState;
            const pair = controllerQueue(ctx, request.owner, request.endpoint, .output) orelse return error.InvalidState;
            if (validated.footprint().bytes > ctx.cell.adapter.owner.limits.message_queue_bytes) return error.Overflow;
            const item = try message_transport.Envelope.create(ctx.cell.adapter.owner.host, validated);
            if (!pair.controller.send(item, ctx.cancellation())) {
                item.release();
                return .invalid;
            }
            try builder.consume();
            return .ok;
        },
        .result => {
            if (op == null) return error.InvalidState;
            try builder.finish();

            const validated = builder.validated() orelse return error.InvalidState;
            const item = try message_transport.Envelope.create(ctx.cell.adapter.owner.host, validated);
            if (!(op orelse return error.InvalidState).terminal_result.replace(item)) {
                item.release();
                return .invalid;
            }
            try builder.consume();
            return .ok;
        },
        .error_data => {
            try builder.finish();
            try publishErrorData(ctx, builder.validated() orelse return error.InvalidState);
            try builder.consume();
        },
        .advance => return error.InvalidState,
        _ => return error.InvalidState,
    }

    return .ok;
}
fn publishErrorData(ctx: *ControllerContext, validated: *const port_message.Validated) message_builder.Error!void {
    const item = try diagnostics.Owned.create(ctx.cell.adapter.owner.host, validated);
    const accepted = if (ctx.operation()) |op| op.terminal_result.replaceDetails(item) else ctx.cell.replaceInitializationDetails(item);
    if (!accepted) {
        item.release();
        return error.InvalidState;
    }
}
fn controllerCancelled(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    const op = ctx.operation() orelse return ctx.cell.closed.load(.acquire);
    lock(&op.mutex);
    defer unlock(&op.mutex);
    return op.ticket.isCancelled() or (!op.ticket.committed() and ctx.cell.closed.load(.acquire));
}

fn controllerEndpointParent(ctx: *ControllerContext, owner: abi.EndpointOwner) ?EndpointParent {
    return switch (owner) {
        .resource => .{ .resource = ctx.cell },
        .exchange => .{ .exchange = ctx.operation() orelse return null },
        _ => null,
    };
}
fn permitsActivityEndpoint(ctx: *ControllerContext, owner: abi.EndpointOwner, index: u32) bool {
    if (ctx.invocation != .activity) {
        if (owner == .resource and index < 64 and ctx.cell.adapter.definition.execution == .controller) {
            for (ctx.cell.adapter.definition.execution.controller.activities) |entry| if (entry) |activity| {
                if (activity.endpoints & (@as(u64, 1) << @as(u6, @intCast(index))) != 0) return false;
            };
        }
        return true;
    }
    if (index >= 64 or owner != .resource) return false;
    const activity = ctx.cell.adapter.definition.execution.controller.activities[ctx.invocation.activity.index].?;
    return activity.endpoints & (@as(u64, 1) << @as(u6, @intCast(index))) != 0;
}

fn controllerPipe(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, direction: enum { input, output }) ?byte_transport.Pair {
    if (!permitsActivityEndpoint(context(raw), owner, index)) return null;
    const source = controllerEndpointParent(context(raw), owner) orelse return null;
    const cell = source.cell();
    if (index >= 64) return null;
    const endpoint = cell.adapter.instance.validated().endpoint(cell.adapter.kind, @intCast(index), switch (source) {
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

fn controllerResolveEndpoint(raw: *anyopaque, identity: *const anyopaque, owner: abi.EndpointOwner, index: u32, transport: abi.EndpointTransport, direction: abi.EndpointDirection) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.cell.adapter.definition.wire.identity != identity or index >= 64) return false;
    if (!permitsActivityEndpoint(ctx, owner, index)) return false;
    const parent = controllerEndpointParent(ctx, owner) orelse return false;
    const spec = ctx.cell.adapter.instance.validated().endpoint(ctx.cell.adapter.kind, @intCast(index), switch (owner) {
        .resource => .resource,
        .exchange => .exchange,
        _ => return false,
    }) orelse return false;
    return @intFromEnum(spec.transport) == @intFromEnum(transport) and
        @intFromEnum(spec.direction) == @intFromEnum(direction) and parent.transport(index) != null;
}

fn controllerTransportFailure(ctx: *ControllerContext, failure: byte_transport.Failure) abi.ControllerStatus {
    const translated: Failure = switch (failure) {
        .out_of_memory => .out_of_memory,
        .report => |report| .init(switch (report.kind) {
            .type => .type,
            .shape => .shape,
            .conform => .conform,
            .overflow => .overflow,
            .domain => .domain,
            .parse => .parse,
            .io => .io,
            .user => .user,
            .contract => .contract,
            else => .io,
        }, report.message[0..report.len]),
    };
    recordControllerFailure(ctx, translated);
    return if (translated == .out_of_memory) .out_of_memory else .failed;
}

fn controllerReadBytes(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, bytes: [*]u8, length: u32) callconv(.c) abi.ControllerRead {
    if (length == 0) return .{ .status = .invalid };
    const pair = controllerPipe(raw, owner, index, .input) orelse return .{ .status = .invalid };
    pair.pipe.beginRead() catch return .{ .status = controllerTransportFailure(context(raw), .init(.contract, "byte endpoint already has a pending reader")) };
    defer pair.pipe.endRead();
    return switch (pair.controller.readChunk(bytes[0..length], context(raw).cancellation())) {
        .data => |count| .{ .status = .ok, .count = @intCast(count) },
        .eof => .{ .status = .eof },
        .cancelled => .{ .status = .cancelled },
        .failed => |failure| .{ .status = controllerTransportFailure(context(raw), failure) },
    };
}

fn controllerWriteBytes(raw: *anyopaque, owner: abi.EndpointOwner, index: u32, bytes: [*]const u8, length: u64) callconv(.c) abi.ControllerStatus {
    const pair = controllerPipe(raw, owner, index, .output) orelse return .invalid;
    return switch (pair.controller.writeAll(bytes[0..@intCast(length)], context(raw).cancellation())) {
        .complete => .ok,
        .cancelled => .cancelled,
        .out_of_memory => controllerTransportFailure(context(raw), .out_of_memory),
        .failed => |failure| controllerTransportFailure(context(raw), failure),
    };
}

fn controllerReceiveEvent(raw: *anyopaque, owner: abi.EndpointOwner, index: u32) callconv(.c) abi.ControllerStatus {
    const ctx = context(raw);
    if (ctx.received != null) return .invalid;
    const pair = controllerQueue(raw, owner, index, .input) orelse return .invalid;
    pair.queue.beginRead() catch return controllerTransportFailure(ctx, .init(.contract, "message endpoint already has a pending receiver"));
    defer pair.queue.endRead();
    switch (pair.controller.receiveMessage(ctx.cancellation())) {
        .message => |item| {
            ctx.received = item;
            return .ok;
        },
        .eof => return .eof,
        .cancelled => return .cancelled,
        .failed => |failure| return controllerTransportFailure(ctx, failure),
    }
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
    if (!permitsActivityEndpoint(context(raw), owner, index)) return null;
    const source = controllerEndpointParent(context(raw), owner) orelse return null;
    const cell = source.cell();
    if (index >= 64) return null;
    const endpoint = cell.adapter.instance.validated().endpoint(cell.adapter.kind, @intCast(index), switch (source) {
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
    if (!op.terminal_result.replace(item)) return false;
    ctx.received = null;
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
    if (ctx.cell.closed.load(.acquire) or ctx.cell.adapter.definition.wire.cancellation != .acknowledge) return false;
    const op = ctx.operation() orelse return false;
    lock(&op.mutex);
    defer unlock(&op.mutex);
    const running = ctx.invocation.operation.running.?;
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
fn controllerFailStreams(raw: *anyopaque, kind: abi.ErrorKindWire, bytes: [*]const u8, length: u32) callconv(.c) void {
    const ctx = context(raw);
    if (ctx.invocation != .activity) return;
    const failure = semanticFailure(reportedFailure(kind, bytes[0..length]));
    for (ctx.cell.adapter.resource_pipes, 0..) |pipe, index| if (pipe) |transport| {
        const endpoint = ctx.cell.adapter.instance.validated().endpoint(ctx.cell.adapter.kind, @intCast(index), .resource).?;
        transport.fail(failure, endpoint.direction == .input);
    };
}
fn controllerFailResource(raw: *anyopaque, kind: abi.ErrorKindWire, bytes: [*]const u8, length: u32) callconv(.c) void {
    const ctx = context(raw);
    const failure = reportedFailure(kind, bytes[0..length]);
    if (ctx.operation()) |op| {
        recordOperationFailure(op, .{ .value = failure, .disposition = .resource });
    } else {
        recordControllerFailure(ctx, failure);
        if (ctx.invocation == .activity) ctx.cell.close();
    }
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
        .initialize, .cleanup => {
            ctx.cell.failInitialization(semanticFailure(failure));
        },
        .activity => storeControllerFailure(&ctx.invocation.activity.failure, failure),
        .shutdown => storeControllerFailure(&ctx.invocation.shutdown, failure),
        .operation => unreachable,
    }
}
fn recordOperationFailure(op: *Operation, failure: OperationAdapter.ControllerFailure) void {
    lock(&op.mutex);
    defer unlock(&op.mutex);
    if (op.adapter.failure) |*prior| {
        if (failure.value == .out_of_memory) prior.value = failure.value;
        if (failure.disposition == .resource) prior.disposition = .resource;
    } else op.adapter.failure = failure;
}
fn storeControllerFailure(destination: *?Failure, failure: Failure) void {
    // Preserve the originating failure during controller unwind. Allocation
    // exhaustion takes precedence and cannot be masked by a later report.
    if (destination.* != null and failure != .out_of_memory) return;
    destination.* = failure;
}
fn controllerFinishInput(raw: *anyopaque, identity: *const anyopaque, index: u32) callconv(.c) bool {
    const ctx = context(raw);
    if ((ctx.invocation != .shutdown and ctx.invocation != .activity) or ctx.cell.adapter.definition.wire.identity != identity or index >= 64 or controllerCancelled(raw)) return false;
    const endpoint = ctx.cell.adapter.instance.validated().endpoint(ctx.cell.adapter.kind, @intCast(index), .resource) orelse return false;
    if (endpoint.transport != .bytes or endpoint.direction != .input) return false;
    const transport = ctx.cell.adapter.resource_pipes[index] orelse return false;
    transport.finish();
    return true;
}

fn controllerStopOutput(raw: *anyopaque, identity: *const anyopaque, index: u32) callconv(.c) bool {
    const ctx = context(raw);
    if (ctx.invocation != .activity or ctx.cell.adapter.definition.wire.identity != identity or index >= 64 or controllerCancelled(raw)) return false;
    const endpoint = ctx.cell.adapter.instance.validated().endpoint(ctx.cell.adapter.kind, @intCast(index), .resource) orelse return false;
    if (endpoint.transport != .bytes or endpoint.direction != .output) return false;
    const transport = ctx.cell.adapter.resource_pipes[index] orelse return false;
    switch (transport) {
        .bytes => |pair| pair.pipe.stopProduction(),
        .messages => return false,
    }
    return true;
}

const controller_table: abi.ControllerTable = .{ .stop_output = controllerStopOutput, .fail_streams = controllerFailStreams, .finish_input = controllerFinishInput, .instance_state = controllerInstance, .initialization_parent = controllerInitializationParent, .resolve_endpoint = controllerResolveEndpoint, .read_bytes = controllerReadBytes, .write_bytes = controllerWriteBytes, .receive_event = controllerReceiveEvent, .fail_resource = controllerFailResource, .parent_state = controllerParent, .discard_message = controllerDiscardMessage, .build_message = controllerBuildMessage, .fail_allocation = controllerFailAllocation, .received_message = controllerReceivedMessage, .forward_message = controllerForwardMessage, .result_message = controllerResultMessage, .input = controllerInput, .finish_endpoint = controllerFinishEndpoint, .cancelled = controllerCancelled, .acknowledge_cancellation = controllerAcknowledge, .fail = controllerFail };

pub fn fromValue(value: Value, instance: *native.ModuleInstance, kind: u32) ?*Cell {
    const handle = switch (value) {
        .port => |port| port,
        else => return null,
    };
    const cell = resource_api.Resource.project(Cell, .{ .port = handle }) orelse return null;
    return if (cell.adapter.instance == instance and cell.adapter.kind == kind) cell else null;
}

fn cooperativeStatus(status: abi.HostStatus) abi.CooperativeBuildStatus {
    return switch (status) {
        .ok => .ok,
        .out_of_memory => .out_of_memory,
        .invalid => .invalid,
        .yield_required => .yield_required,
        _ => .invalid,
    };
}
fn cooperativeBuildMessage(raw: *anyopaque, request: *const abi.MessageBuildRequest) callconv(.c) abi.CooperativeBuildStatus {
    const ctx = context(raw);
    return buildCooperative(ctx, request) catch |err| cooperativeStatus(constructionFailure(ctx, err));
}
fn buildCooperative(ctx: *ControllerContext, request: *const abi.MessageBuildRequest) message_builder.Error!abi.CooperativeBuildStatus {
    if (request.size != @sizeOf(abi.MessageBuildRequest)) return error.InvalidState;
    const operation = ctx.operation();
    if (operation == null and ctx.invocation != .initialize) return error.InvalidState;
    if (controllerCancelled(ctx)) return error.Cancelled;
    if (ctx.operation()) |op| {
        if (!op.terminal_result.mutable()) return error.InvalidState;
        if (op.mode == .finalizer and request.action == .child) return error.InvalidState;
    }
    if (ctx.builder == .none) {
        // Allocate before publishing the union tag: result-location semantics
        // may otherwise expose a partial payload to the failure unwinder.
        const owned = try message_builder.ResumableBuilder.createConfigured(ctx.cell.adapter.owner.host, ctx.cancellation(), ctx.cell.adapter.owner.builderLimits());
        ctx.builder = .{ .cooperative = .{ .value = owned } };
    }
    const building = &ctx.builder.cooperative;
    const builder = building.value;
    if (request.action == .advance) {
        if (building.phase == .idle) return .ok;
        if (building.phase == .child) {
            const child = &building.phase.child;
            const cell = resource_api.Resource.project(Cell, child.value).?;
            switch (cell.initialized()) {
                .pending => {
                    ctx.cooperative.?.wait = .readiness;
                    return .parked;
                },
                .failed => |failure| {
                    cell.close();
                    return cooperativeStatus(childCreationFailure(ctx, if (failure == .out_of_memory) error.OutOfMemory else error.Io));
                },
                .ready => {},
            }
            try builder.replaceChild(child.value);
            switch (child.readiness) {
                .ready => {},
                .registered => |*registration| registration.cancel(),
            }
            heap.hostDomain(ctx.cell.adapter.owner.host).releaseValue(child.value);
            building.phase = .idle;
            return .ok;
        }
        if (try builder.advance() == .pending) return .yield_required;
        if (building.phase == .child_configuration) {
            const selected = building.phase.child_configuration;
            const child = (operation orelse return error.InvalidState).adapter.startChild(operation.?, selected.kind, builder.childConfiguration() orelse return error.InvalidState, selected.dependency, .cooperative) catch |err| return cooperativeStatus(childCreationFailure(ctx, err));
            building.phase = .{ .child = child };
            return .yield_required;
        }
        if (building.phase == .result) {
            const item = try message_transport.Envelope.create(ctx.cell.adapter.owner.host, builder.validated() orelse return error.InvalidState);
            if (!operation.?.terminal_result.replace(item)) {
                item.release();
                return error.InvalidState;
            }
            try builder.consume();
        }
        if (building.phase == .error_data) {
            try publishErrorData(ctx, builder.validated() orelse return error.InvalidState);
            try builder.consume();
        }
        building.phase = .idle;
        return .ok;
    }
    if (building.phase != .idle) return error.InvalidState;
    switch (request.action) {
        .scalar => {
            if (request.scalar.size != @sizeOf(abi.Scalar)) return error.InvalidState;
            const scalar = request.scalar;
            switch (scalar.kind) {
                .int => try builder.int(@bitCast(scalar.bits)),
                .float => try builder.float(@bitCast(scalar.bits)),
                .char => try builder.char(scalar.bits),
                .symbol => {
                    if (scalar.bytes_len > ctx.symbol_bytes.len) return error.Overflow;
                    const size: usize = @intCast(scalar.bytes_len);
                    const bytes = if (size == 0) "" else (scalar.bytes_ptr orelse return error.InvalidValue)[0..size];
                    @memcpy(ctx.symbol_bytes[0..size], bytes);
                    try builder.symbol(ctx.symbol_bytes[0..size]);
                    building.phase = .working;
                },
                .word, .list, .dict, .port => return error.InvalidValue,
                _ => return error.InvalidValue,
            }
        },
        .copy_input => {
            if (request.depth > abi.max_read_path_depth) return error.InvalidValue;
            const path: []const u64 = if (request.depth == 0) &.{} else (request.path orelse return error.InvalidValue)[0..request.depth];
            const input = valueAtPath(if (operation) |op| op.adapter.protocol.parameters else (ctx.cell.adapter.configuration orelse return error.InvalidState), path) orelse return error.InvalidValue;
            try builder.copy(input);
            building.phase = .working;
        },
        .list => {
            try builder.list(request.count);
            building.phase = .working;
        },
        .dictionary => {
            try builder.dictionary(request.count);
            building.phase = .working;
        },
        .result => {
            if (operation == null) return error.InvalidState;
            try builder.finish();
            building.phase = .result;
        },
        .error_data => {
            try builder.finish();
            building.phase = .error_data;
        },
        .clear => {
            try builder.clear();
            building.phase = .working;
        },
        .child => {
            const selected = try childRequest(ctx, request);
            try builder.prepareChild();
            building.phase = .{ .child_configuration = selected };
        },
        .copy_received, .send, .reply_endpoint, .advance => return error.InvalidState,
        _ => return error.InvalidState,
    }
    return .ok;
}
fn cooperativeConsume(raw: *anyopaque, units: u32) callconv(.c) bool {
    if (context(raw).cooperative) |*work| {
        if (units == 0 or units > work.budget) return false;
        work.budget -= units;
        return true;
    }
    return false;
}
fn cooperativePark(raw: *anyopaque, milliseconds: u64) callconv(.c) bool {
    const ctx = context(raw);
    if (milliseconds > std.math.maxInt(u63)) return false;
    if (ctx.cooperative) |*work| {
        const deadline = ctx.cell.scheduler.deadlineAfter(@intCast(milliseconds)) catch {
            recordControllerFailure(ctx, .init(.overflow, "cooperative timer deadline overflow"));
            return false;
        };
        work.wait = .{ .timer = deadline };
        return true;
    }
    return false;
}
fn cooperativeProgress(ctx: *ControllerContext, progress: abi.CooperativeProgress) scheduler.Cooperative.Progress {
    return switch (progress) {
        .completed => .completed,
        .yielded => .yielded,
        .parked => if (controllerCancelled(ctx)) .yielded else switch (ctx.cooperative.?.wait) {
            .timer => |deadline| .{ .parked = deadline },
            .readiness => .waiting,
            .none => blk: {
                recordControllerFailure(ctx, .init(.contract, "cooperative callback parked without a registered wait"));
                break :blk .completed;
            },
        },
        _ => blk: {
            recordControllerFailure(ctx, .init(.contract, "invalid cooperative callback progress"));
            break :blk .completed;
        },
    };
}
fn cooperativeBeginCommit(raw: *anyopaque) callconv(.c) bool {
    const ctx = context(raw);
    const op = ctx.operation() orelse return false;
    if (op.mode != .finalizer) return false;
    lock(&op.mutex);
    const failed = op.adapter.failure != null;
    unlock(&op.mutex);
    if (failed) return false;
    if (ctx.builder == .cooperative and ctx.builder.cooperative.phase != .idle) return false;
    const running = ctx.invocation.operation.running orelse return false;
    if (!op.terminal_result.freeze()) return false;
    return running.beginCommit();
}

const cooperative_table: abi.CooperativeTable = .{
    .begin_commit = cooperativeBeginCommit,
    .instance_state = controllerInstance,
    .initialization_parent = controllerInitializationParent,
    .parent_state = controllerParent,
    .input = controllerInput,
    .build_message = cooperativeBuildMessage,
    .fail_allocation = controllerFailAllocation,
    .cancelled = controllerCancelled,
    .fail = controllerFail,
    .consume = cooperativeConsume,
    .park = cooperativePark,
};

const CooperativeInvocation = struct {
    context: union(enum) { reserved, live: ControllerContext } = .reserved,
    phase: enum { callback, publishing, retiring, finished } = .callback,
    fn deinit(self: *CooperativeInvocation) void {
        switch (self.context) {
            .reserved => {},
            .live => |*ctx| ctx.deinit(),
        }
    }
    fn advance(self: *CooperativeInvocation, adapter: *OperationAdapter, operation: *Operation, running: *controllers.Running) controllers.Progress {
        if (self.context == .reserved) self.context = .{ .live = .{
            .cell = adapter.cell,
            .invocation = .{ .operation = .{ .value = operation, .running = null } },
            .cooperative = .{},
        } };
        const ctx = &self.context.live;
        ctx.invocation.operation.running = running;
        defer ctx.invocation.operation.running = null;
        ctx.cooperative = .{};
        if (running.cancelled() and self.phase != .finished) self.phase = .retiring;
        const callbacks = adapter.cell.adapter.definition.execution.cooperative;
        switch (self.phase) {
            .callback => {
                const progress = cooperativeProgress(ctx, callbacks.execute(adapter.cell.adapter.backend.ptr, adapter.code, &cooperative_table, ctx));
                lock(&operation.mutex);
                const failed = adapter.failure != null;
                const committed = operation.ticket.committed();
                unlock(&operation.mutex);
                if (failed or progress == .completed) {
                    if (!failed and operation.mode == .finalizer and !committed)
                        recordControllerFailure(ctx, .init(.contract, "finalizer completed without committing"));
                    self.phase = .retiring;
                    if (!failed and ctx.builder == .cooperative) switch (ctx.builder.cooperative.phase) {
                        .idle => {},
                        .result => self.phase = .publishing,
                        .working, .error_data, .child_configuration, .child => recordControllerFailure(ctx, .init(.contract, "cooperative callback completed unfinished construction")),
                    };
                    return .yielded;
                }
                return operationProgress(progress);
            },
            .publishing => {
                const status = cooperativeBuildMessage(ctx, &.{ .action = .advance });
                if (status == .yield_required) return .yielded;
                self.phase = .retiring;
                return .yielded;
            },
            .retiring => {
                const progress = cooperativeProgress(ctx, callbacks.retire_operation(adapter.cell.adapter.backend.ptr, &cooperative_table, ctx));
                if (progress != .completed) return operationProgress(progress);
                ctx.deinit();
                self.phase = .finished;
                lock(&operation.mutex);
                _ = running.acknowledgeCancellation();
                unlock(&operation.mutex);
                return .completed;
            },
            .finished => unreachable,
        }
    }
    fn operationProgress(progress: scheduler.Cooperative.Progress) controllers.Progress {
        return switch (progress) {
            .yielded => .yielded,
            .parked => |deadline| .{ .parked = deadline },
            .completed => .completed,
            .waiting => .waiting,
        };
    }
};

/// A failed admission owns only diagnostic work. It cannot consume a resource
/// permit or start a controller. Its issuing instance owns all allocation and
/// retirement authority, including cancellation before an error is published.
const RejectedOpening = struct {
    instance: *native.ModuleInstance,
    definition: descriptor.CapacityFailureDefinition,
    input_value: Value,
    builder: ?*message_builder.ResumableBuilder = null,
    details: ?*diagnostics.Owned = null,
    failure: ?Failure = null,
    phase: union(enum) { reporting: []align(64) u8, settling: []align(64) u8, ready, retiring: ?[]align(64) u8 },
    construction: enum { idle, working, sealing } = .idle,
    closed: std.atomic.Value(bool) = .init(false),
    budget: u32 = 256,
    symbol_bytes: [256]u8 = @splat(0),
    retirement: heap.ReleaseDomain.Retirement = .{},

    fn host(self: *RejectedOpening) *const heap.HostCleanup {
        return self.instance.portAccess().state().host;
    }
    pub fn allocator(self: *RejectedOpening) std.mem.Allocator {
        return self.host().allocator();
    }
    fn create(instance: *native.ModuleInstance, kind: u32, configuration: *const port_message.Validated) error{OutOfMemory}!*factories.Opening {
        const definition = instance.validated().port(kind).?.capacity_failure.?;
        const memory = instance.portAccess().state().allocator();
        const owned = try memory.create(RejectedOpening);
        errdefer memory.destroy(owned);
        const backend = try memory.alignedAlloc(u8, .@"64", definition.state_size);
        errdefer memory.free(backend);
        owned.* = .{ .instance = instance, .definition = definition, .phase = .{ .reporting = backend }, .input_value = configuration.value() };
        const opening = try factories.Opening.create(RejectedOpening, owned);
        instance.retain();
        heap.retainValue(owned.input_value);
        definition.init_state(backend.ptr);
        return opening;
    }
    pub fn advance(self: *RejectedOpening, quantum: usize) error{OutOfMemory}!factories.Progress {
        self.budget = @intCast(@min(quantum, 256));
        switch (self.phase) {
            .reporting => |backend| {
                const progress = self.definition.step(backend.ptr, &table, self);
                switch (progress) {
                    .completed, .yielded => {},
                    else => fail(self, .contract, "invalid rejected opening progress".ptr, "invalid rejected opening progress".len),
                }
                if (progress != .yielded or self.failure != null) self.phase = .{ .settling = backend };
                return .yielded;
            },
            .settling => |backend| {
                if (!self.definition.retire(backend.ptr, &table, self)) return .yielded;
                self.retireConstruction();
                self.allocator().free(backend);
                self.phase = .ready;
            },
            .ready => {},
            .retiring => unreachable,
        }
        return .{ .failed = .{
            .report = semanticFailure(self.failure orelse .init(.domain, "port resource capacity is exhausted")),
            .diagnostics = if (self.details) |details| details.view() else null,
        } };
    }
    pub fn release(self: *RejectedOpening) void {
        self.closed.store(true, .release);
        const remaining: ?[]align(64) u8 = switch (self.phase) {
            .reporting, .settling => |backend| backend,
            .ready => null,
            .retiring => unreachable,
        };
        self.phase = .{ .retiring = remaining };
        heap.hostDomain(self.host()).retire(self, &self.retirement);
    }
    fn retireConstruction(self: *RejectedOpening) void {
        if (self.builder) |builder| builder.retire();
        self.builder = null;
    }
    pub fn advanceRetirement(releases: *heap.ReleaseDomain, _: std.mem.Allocator, self: *RejectedOpening) bool {
        self.budget = 256;
        if (self.phase.retiring) |backend| {
            if (!self.definition.retire(backend.ptr, &table, self)) return false;
            self.allocator().free(backend);
        }
        const memory = self.allocator();
        self.retireConstruction();
        if (self.details) |details| details.release();
        releases.releaseValue(self.input_value);
        self.instance.releasePin();
        memory.destroy(self);
        return true;
    }
    fn state(raw: *anyopaque) *RejectedOpening {
        return @ptrCast(@alignCast(raw));
    }
    fn instanceState(raw: *anyopaque, identity: *const anyopaque) callconv(.c) ?*anyopaque {
        return state(raw).instance.instanceState(identity);
    }
    fn noParent(_: *anyopaque, _: *const anyopaque) callconv(.c) ?*anyopaque {
        return null;
    }
    fn input(raw: *anyopaque, path: [*]const u64, depth: u32, output: *abi.ValueView) callconv(.c) bool {
        return viewMessage(state(raw).input_value, path, depth, output);
    }
    fn cancelled(raw: *anyopaque) callconv(.c) bool {
        return state(raw).closed.load(.acquire);
    }
    fn fail(raw: *anyopaque, kind: abi.ErrorKindWire, text: [*]const u8, length: u32) callconv(.c) void {
        storeControllerFailure(&state(raw).failure, reportedFailure(kind, text[0..length]));
    }
    fn failAllocation(raw: *anyopaque) callconv(.c) void {
        storeControllerFailure(&state(raw).failure, .out_of_memory);
    }
    fn consume(raw: *anyopaque, amount: u32) callconv(.c) bool {
        const self = state(raw);
        if (amount > self.budget) return false;
        self.budget -= amount;
        return true;
    }
    fn noPark(_: *anyopaque, _: u64) callconv(.c) bool {
        return false;
    }
    fn noCommit(_: *anyopaque) callconv(.c) bool {
        return false;
    }
    fn build(raw: *anyopaque, request: *const abi.MessageBuildRequest) callconv(.c) abi.CooperativeBuildStatus {
        const self = state(raw);
        return self.buildDiagnostic(request) catch |err| {
            if (err == error.Cancelled) return .invalid;
            if (self.builder) |builder| builder.invalidate();
            storeControllerFailure(&self.failure, switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.Overflow => .init(.overflow, "opening diagnostic exceeds message limits"),
                error.InvalidValue => .init(.type, "invalid opening diagnostic value"),
                error.DuplicateKey => .init(.domain, "duplicate opening diagnostic key"),
                error.InvalidState => .init(.contract, "invalid opening diagnostic construction"),
                error.Cancelled => unreachable,
            });
            return if (err == error.OutOfMemory) .out_of_memory else .invalid;
        };
    }
    fn buildDiagnostic(self: *RejectedOpening, request: *const abi.MessageBuildRequest) message_builder.Error!abi.CooperativeBuildStatus {
        if (self.closed.load(.acquire)) return error.Cancelled;
        if (self.phase != .reporting or request.size != @sizeOf(abi.MessageBuildRequest)) return error.InvalidState;
        if (self.builder == null) self.builder = try message_builder.ResumableBuilder.createConfigured(self.host(), &self.closed, self.instance.portAccess().state().builderLimits());
        const builder = self.builder.?;
        if (request.action == .advance) {
            if (self.construction == .idle) return .ok;
            if (try builder.advance() == .pending) return .yield_required;
            if (self.construction == .sealing) {
                const incoming = try diagnostics.Owned.create(self.host(), builder.validated() orelse return error.InvalidState);
                const previous = self.details;
                self.details = incoming;
                if (previous) |details| details.release();
                try builder.consume();
            }
            self.construction = .idle;
            return .ok;
        }
        if (self.construction != .idle) return error.InvalidState;
        switch (request.action) {
            .scalar => {
                if (request.scalar.size != @sizeOf(abi.Scalar)) return error.InvalidState;
                const scalar = request.scalar;
                switch (scalar.kind) {
                    .int => try builder.int(@bitCast(scalar.bits)),
                    .float => try builder.float(@bitCast(scalar.bits)),
                    .char => try builder.char(scalar.bits),
                    .symbol => {
                        if (scalar.bytes_len > self.symbol_bytes.len) return error.Overflow;
                        const length: usize = @intCast(scalar.bytes_len);
                        const bytes = if (length == 0) "" else (scalar.bytes_ptr orelse return error.InvalidValue)[0..length];
                        @memcpy(self.symbol_bytes[0..length], bytes);
                        try builder.symbol(self.symbol_bytes[0..length]);
                        self.construction = .working;
                    },
                    else => return error.InvalidValue,
                }
            },
            .copy_input => {
                if (request.depth > abi.max_read_path_depth) return error.InvalidValue;
                const path: []const u64 = if (request.depth == 0) &.{} else (request.path orelse return error.InvalidValue)[0..request.depth];
                try builder.copy(valueAtPath(self.input_value, path) orelse return error.InvalidValue);
                self.construction = .working;
            },
            .list => {
                try builder.list(request.count);
                self.construction = .working;
            },
            .dictionary => {
                try builder.dictionary(request.count);
                self.construction = .working;
            },
            .clear => {
                try builder.clear();
                self.construction = .working;
            },
            .error_data => {
                try builder.finish();
                self.construction = .sealing;
            },
            else => return error.InvalidState,
        }
        return .ok;
    }
    const table: abi.CooperativeTable = .{
        .instance_state = instanceState,
        .initialization_parent = noParent,
        .parent_state = noParent,
        .input = input,
        .build_message = build,
        .fail_allocation = failAllocation,
        .cancelled = cancelled,
        .fail = fail,
        .consume = consume,
        .park = noPark,
        .begin_commit = noCommit,
    };
};
