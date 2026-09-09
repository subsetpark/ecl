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
    pub fn definition(self: *RegisteredCapability) descriptor.PortCapability {
        const owned = self.state();
        return owned.instance.definition(owned.definition).body.port;
    }
    pub fn borrowEndpoint(self: *RegisteredCapability, source: Value) endpoint_api.BorrowError!Value {
        return borrowRegisteredEndpoint(source, self);
    }
    pub fn acceptsOperation(self: *RegisteredCapability, source: Value) bool {
        return fromValue(source, self.instance(), self.definition().operation.resource) != null;
    }
    pub fn beginOperation(self: *RegisteredCapability, source: Value, scope: *scheduler.TaskScope, request: *const port_message.Validated) exchanges.AdmitError!exchanges.Admission {
        const operation = self.definition().operation;
        const cell = fromValue(source, self.instance(), operation.resource) orelse return error.WrongKind;
        return cell.admitOnLane(.{ .code = operation.code, .lane = operation.lane, .endpoints = operation.endpoints }, scope, request);
    }
    pub fn openResource(self: *RegisteredCapability, opening: factories.Context, config: *const port_message.Validated) error{OutOfMemory}!factories.Start {
        const issuer = self.instance();
        const resource = issuer.portAccess().createConfigured(issuer, self.definition().factory, opening.scope, config) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Limit, error.InsufficientLanes => .{ .failed = factories.Failure.init(.domain, "port resource capacity is exhausted") },
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

fn semanticFailure(failure: Failure) byte_transport.Failure {
    return switch (failure) {
        .out_of_memory => .out_of_memory,
        .report => |report| byte_transport.Failure.init(descriptor.mapErrorKind(report.kind) orelse .io, report.message[0..report.len]),
    };
}

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
    pub const Request = struct { code: u32, lane: u32, endpoints: u64 };
    owner: *OwnerState,
    instance: *native.ModuleInstance,
    kind: u32,
    definition: abi.PortDefinition,
    backend: []align(64) u8,
    configuration: ?Value = null,
    message_budget: *message_transport.Budget,
    resource_pipes: [64]?Protocol.Transport = .{null} ** 64,
    pub fn allocator(self: *const ResourceAdapter) std.mem.Allocator {
        return self.owner.host.allocator();
    }
    pub fn executor(self: *const ResourceAdapter) *controllers.Executor {
        return self.owner.executor.access();
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
        return OperationAdapter.prepare(cell, selected.code, selected.lane, selected.endpoints, request, lane);
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
        self.definition.init_state.?(self.backend.ptr);
    }
    pub fn initializeBackend(self: *ResourceAdapter, cell: *Cell) void {
        var ctx: ControllerContext = .{ .cell = cell, .invocation = .initialize };
        defer ctx.deinit();
        self.definition.initialize.?(self.backend.ptr, &controller_table, &ctx);
    }
    pub fn cancel(self: *ResourceAdapter) void {
        self.definition.cancel.?(self.backend.ptr);
    }
    pub fn failTransport(self: *ResourceAdapter) void {
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.fail(.init(.io, "native resource is closed"), true);
    }
    pub fn abortTransport(self: *ResourceAdapter) void {
        for (self.resource_pipes) |pipe| if (pipe) |transport| transport.abort();
    }
    pub fn cleanup(self: *ResourceAdapter) void {
        self.definition.cleanup.?(self.backend.ptr);
    }
    pub fn shutdown(self: *ResourceAdapter, cell: *Cell) ?byte_transport.Failure {
        var ctx: ControllerContext = .{ .cell = cell, .invocation = .{ .shutdown = null } };
        defer ctx.deinit();
        self.definition.shutdown.?(self.backend.ptr, &controller_table, &ctx);
        return if (ctx.invocation.shutdown) |failure| semanticFailure(failure) else null;
    }
    fn initializeAllocation(cell: *Cell, owner: *OwnerState, instance: *native.ModuleInstance, kind: u32, config: *const port_message.Validated, worker: *const scheduler.WorkerScheduler) error{ OutOfMemory, InvalidLimits }!void {
        const memory = owner.host.allocator();
        const definition = instance.validated().port(kind).?;
        const state = try memory.alignedAlloc(u8, .@"64", definition.state_size);
        errdefer memory.free(state);
        const message_budget = try message_transport.Budget.create(owner.host, owner.limits.message_queue_bytes);
        errdefer message_budget.release();
        try cell.initialize(.{ .owner = owner, .instance = instance, .kind = kind, .definition = definition, .backend = state, .message_budget = message_budget }, worker, definition.lane_count, owner.limits.max_operations, definition.shutdown != null);
        errdefer cell.controllers.deinit();
        errdefer for (cell.adapter.resource_pipes) |pipe| if (pipe) |transport| transport.release();
        for (&cell.adapter.resource_pipes, 0..) |*slot, index| {
            const endpoint = instance.validated().endpoint(kind, @intCast(index), .resource) orelse continue;
            const transport = try Protocol.Transport.create(cell, switch (endpoint.transport) {
                .bytes => .bytes,
                .messages => .messages,
            });
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
        fn create(cell: *Cell, kind: enum { bytes, messages }) error{OutOfMemory}!Transport {
            // Construct a complete transport before publishing its variant in
            // an owning slot. Fallible arm initializers can otherwise expose
            // a tag whose payload was never initialized during rollback.
            switch (kind) {
                .bytes => {
                    const pair = byte_transport.create(cell.adapter.owner.host, cell.adapter.owner.limits.ring_capacity) catch |err| return switch (err) {
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
    }
    pub fn retireValue(self: *OperationAdapter, item: Value) void {
        heap.hostDomain(self.cell.adapter.owner.host).releaseValue(item);
    }
    pub fn retainResource(self: *OperationAdapter) void {
        self.cell.retainReadiness();
    }
    pub fn deinit(self: *OperationAdapter) void {
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
    pub fn prepare(cell: *Cell, code: u32, lane: u32, endpoints: u64, parameters: *const port_message.Validated, queue: *Operation.Lane) error{OutOfMemory}!*Operation.Prepared {
        var protocol = try Protocol.init(cell, endpoints, parameters);
        errdefer protocol.deinit(cell);
        const terminal_value = try results.Result.create(cell.adapter.owner.host);
        errdefer terminal_value.release();
        return Operation.prepare(.{ .cell = cell, .code = code, .lane = lane, .protocol = protocol, .endpoints = endpoints }, terminal_value, queue);
    }
    pub fn runnable(self: *OperationAdapter) bool {
        return !self.cell.closed.load(.acquire);
    }
    pub fn execute(self: *OperationAdapter, operation: *Operation, running: *controllers.Running) void {
        var ctx: ControllerContext = .{ .cell = self.cell, .invocation = .{ .operation = .{ .value = operation, .running = running } } };
        defer ctx.deinit();
        self.cell.adapter.definition.execute.?(self.cell.adapter.backend.ptr, self.code, &controller_table, &ctx);
    }
    pub fn completeResourceLocked(self: *OperationAdapter, outcome: controllers.Completion) void {
        if (outcome == .close_resource or (self.failure != null and self.failure.?.disposition == .resource)) self.cell.closeLocked();
        self.cell.waits.notifyLocked(self.cell);
    }
    pub fn cancelPolicy(self: *OperationAdapter) controllers.CallbackCancellation {
        return switch (self.cell.adapter.definition.cancellation) {
            .close_resource => .close_resource,
            .acknowledge => .acknowledge,
            _ => unreachable,
        };
    }
    pub fn cancelResourceLocked(self: *OperationAdapter, action: controllers.CancelAction) void {
        const cell = self.cell;
        switch (action) {
            .close_resource => cell.closeLocked(),
            .interrupt => cell.adapter.definition.cancel_operation.?(cell.adapter.backend.ptr, self.lane),
            .retired => {
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
        const parent = self.cell;
        const owner = parent.adapter.owner;
        const provisional = try operation.childGroup();
        const dependent: ?Cell.Parent = if (dependency == .dependent) .{ .cell = parent, .group = try parent.childGroup() } else null;
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
    if (parent.adapter.instance != cell.adapter.instance or parent.adapter.definition.identity != identity) return null;
    // Membership remains attached until child cleanup and controller join.
    // The parent joins it before destroying the borrowed native state.
    return parent.adapter.backend.ptr;
}

fn controllerInput(raw: *anyopaque, path: [*]const u64, depth: u32, output: *abi.ValueView) callconv(.c) bool {
    if (depth > abi.max_read_path_depth or output.size != @sizeOf(abi.ValueView)) return false;
    const ctx = context(raw);
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
        if (err == error.Cancelled) return .invalid;
        if (ctx.builder) |builder| builder.invalidate();
        recordControllerFailure(ctx, switch (err) {
            error.Cancelled => unreachable,
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
        const builder = try message_builder.Builder.create(ctx.cell.adapter.owner.host, ctx.invocation.operation.running);
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
                op.adapter.protocol.parameters;
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
            const identity = request.kind_identity orelse return error.InvalidValue;
            const dependency: abi.ChildDependency = @enumFromInt(request.count);
            switch (dependency) {
                .independent, .dependent => {},
                _ => return error.InvalidState,
            }
            var index: u32 = 0;
            const kind = while (ctx.cell.adapter.instance.validated().port(index)) |definition| : (index += 1) {
                if (definition.identity == identity) break index;
            } else return error.InvalidState;
            const child = op.adapter.stageChild(op, kind, configuration, dependency) catch |err| {
                recordControllerFailure(ctx, switch (err) {
                    error.OutOfMemory => .out_of_memory,
                    error.Limit => .init(.overflow, "native child resource limit exceeded"),
                    error.Closed, error.ScopeClosing => .init(.io, "native child owner is closing"),
                    error.InsufficientLanes => .init(.domain, "native child requires more controller lanes"),
                    error.Io => .init(.io, "native child initialization failed"),
                });
                return if (err == error.OutOfMemory) .out_of_memory else .invalid;
            };
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
            try builder.finish();

            const validated = builder.validated() orelse return error.InvalidState;
            const item = try message_transport.Envelope.create(ctx.cell.adapter.owner.host, validated);
            if (!op.terminal_result.replace(item)) {
                item.release();
                return .invalid;
            }
            try builder.consume();
            return .ok;
        },
        _ => return error.InvalidState,
    }

    return .ok;
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
    if (ctx.cell.adapter.definition.identity != identity or index >= 64) return false;
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
    if (ctx.cell.closed.load(.acquire) or ctx.cell.adapter.definition.cancellation != .acknowledge) return false;
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
            ctx.cell.failInitialization(semanticFailure(failure));
        },
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
const controller_table: abi.ControllerTable = .{ .resolve_endpoint = controllerResolveEndpoint, .read_bytes = controllerReadBytes, .write_bytes = controllerWriteBytes, .receive_event = controllerReceiveEvent, .fail_resource = controllerFailResource, .parent_state = controllerParent, .discard_message = controllerDiscardMessage, .build_message = controllerBuildMessage, .fail_allocation = controllerFailAllocation, .received_message = controllerReceivedMessage, .forward_message = controllerForwardMessage, .result_message = controllerResultMessage, .input = controllerInput, .finish_endpoint = controllerFinishEndpoint, .cancelled = controllerCancelled, .acknowledge_cancellation = controllerAcknowledge, .fail = controllerFail };

pub fn fromValue(value: Value, instance: *native.ModuleInstance, kind: u32) ?*Cell {
    const handle = switch (value) {
        .port => |port| port,
        else => return null,
    };
    const cell = resource_api.Resource.project(Cell, .{ .port = handle }) orelse return null;
    return if (cell.adapter.instance == instance and cell.adapter.kind == kind) cell else null;
}
