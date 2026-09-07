//! Common exchange observation and cleanup, independent of native invocations.
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const machine = @import("../machine.zig");
const native = @import("../native_port.zig");
const Value = @import("../value.zig").Value;
const std = @import("std");
const message = @import("../port_message.zig");
const poll = @import("../poll.zig");
const scheduler = @import("../scheduler.zig");

pub const words = [_]env.BuiltinWord{
    .{ .name = "open", .doc = "( factory config -- resource ) Initialize a registered resource in the calling scope.", .primitive = open },
    .{ .name = "begin", .doc = "( resource operation request -- exchange ) Admit a registered operation with bounded structured parameters.", .primitive = begin },
    .{ .name = "cancel", .effect = "exchange --", .doc = "Request exchange cancellation. Completion remains observable.", .primitive = cancel },
    .{ .name = "close", .doc = "( port -- ) Abort a resource or exchange and join its cleanup. Idempotent.", .primitive = close },
    .{ .name = "await", .doc = "( exchange -- ) Observe successful exchange completion or its terminal failure without draining output.", .primitive = awaitExchange },
    .{ .name = "result", .doc = "( exchange -- value ) Wait and claim an exchange result exactly once. Later claims raise 'contract.", .primitive = result },
};

fn open(evaluator: *machine.Machine) machine.MachineError!void {
    try startRequest(evaluator, .factory);
}

fn begin(evaluator: *machine.Machine) machine.MachineError!void {
    try startRequest(evaluator, .operation_selector);
}

fn startRequest(evaluator: *machine.Machine, comptime role: @import("../value.zig").PortVariant) machine.MachineError!void {
    var input = try evaluator.popValue();
    defer input.deinit();
    var capability = try evaluator.popValue();
    defer capability.deinit();
    const registered = native.registeredCapability(capability.borrow(), role) orelse return evaluator.typeError(if (role == .factory) "a factory" else "an operation selector");
    var resource: ?heap.OwnedValue = if (role == .operation_selector) try evaluator.popValue() else null;
    defer if (resource) |*owned| owned.deinit();
    if (resource) |owned| {
        _ = native.fromValue(owned.borrow(), registered.instance(), registered.definition().resource()) orelse
            return evaluator.typeError("a resource of the selector's issuing kind");
    }
    const driver = try evaluator.allocator().create(Request);
    errdefer evaluator.allocator().destroy(driver);
    const validated = try message.Message.create(evaluator.allocator(), input.borrow(), .{});
    driver.* = .{
        .capability = capability.take(),
        .resource = if (resource) |*owned| owned.take() else null,
        .message = validated,
    };
    evaluator.adoptDriver(driver);
}

const Request = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    capability: Value,
    resource: ?Value,
    message: *message.Message,
    state: union(enum) { validating, ready, opening: Value, consumed } = .validating,

    pub fn deinit(self: *Request, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        switch (self.state) {
            .opening => |item| {
                heap.portPayload(native.Cell, .resource, item.port).?.close();
                releases.releaseValue(item);
            },
            .validating, .ready, .consumed => {},
        }
        self.message.retire(releases);
        releases.releaseValue(self.capability);
        if (self.resource) |item| releases.releaseValue(item);
    }

    pub fn advance(evaluator: *machine.Machine, self: *Request) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .validating) {
            var budget = poll.WorkBudget.init(machine.kernel_poll_quantum);
            const progress = self.message.advance(&budget) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidValue => evaluator.fail(.type, "port messages cannot contain executable words, tasks, or modules"),
                error.Overflow => evaluator.fail(.overflow, "port message exceeds its structured value limits"),
            };
            if (progress == .pending) return .yielded;
            self.state = .ready;
        }
        if (self.state == .opening) {
            const item = self.state.opening;
            const cell = heap.portPayload(native.Cell, .resource, item.port).?;
            switch (cell.initialized()) {
                .pending => {
                    try evaluator.park(.{ .external = cell.source(0) });
                    return .yielded;
                },
                .failed => |failure| return fail(evaluator, failure),
                .ready => {
                    const output = try evaluator.reserveStack(1);
                    self.state = .consumed;
                    return output.output(item);
                },
            }
        }
        const scope: *scheduler.TaskScope = @ptrCast(@alignCast(evaluator.unit.task_scope orelse return evaluator.fail(.cancelled, "port scope is closing")));
        if (self.resource) |item| {
            const capability = native.registeredCapability(self.capability, .operation_selector).?;
            const operation = capability.definition().operation;
            const cell = native.fromValue(item, capability.instance(), operation.resource).?;
            const output = try evaluator.reserveStack(1);
            switch (cell.admitOnLane(operation.code, operation.lane, operation.endpoints, scope, self.message.validated().?) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ScopeClosing => evaluator.fail(.cancelled, "port scope is closing"),
            }) {
                .operation => |exchange| {
                    self.state = .consumed;
                    return output.output(exchange);
                },
                .pending => try evaluator.park(.{ .external = cell.source(2 + @as(u64, operation.lane)) }),
                .closed => return evaluator.fail(.io, "resource is closed"),
                .invalid_operation => return evaluator.fail(.domain, "operation lane is unavailable"),
            }
        } else {
            const capability = native.registeredCapability(self.capability, .factory).?;
            const instance = capability.instance();
            const item = instance.portAccess().createConfigured(instance, capability.definition().factory, scope, self.message.validated().?) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Limit, error.InsufficientLanes => evaluator.fail(.domain, "port resource capacity is exhausted"),
                error.Closed, error.Io => evaluator.fail(.io, "port resource creation failed"),
                error.ScopeClosing => evaluator.fail(.cancelled, "port scope is closing"),
            };
            self.state = .{ .opening = item };
        }
        return .yielded;
    }
};

fn fail(evaluator: *machine.Machine, failure: native.Failure) machine.MachineError {
    return evaluator.fail(@import("../native_descriptor.zig").mapErrorKind(failure.kind) orelse .io, failure.message[0..failure.len]);
}

fn cancel(evaluator: *machine.Machine) machine.MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const exchange = native.exchangeFromValue(item.borrow()) orelse return evaluator.typeError("an exchange");
    exchange.cancel();
}

fn close(evaluator: *machine.Machine) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const target: Target = if (native.exchangeFromValue(item.borrow())) |exchange|
        .{ .exchange = exchange }
    else if (item.borrow() == .port) resource: {
        const resource = heap.portPayload(native.Cell, .resource, item.borrow().port) orelse return evaluator.typeError("a resource or exchange");
        break :resource .{ .resource = resource };
    } else return evaluator.typeError("a resource or exchange");
    try evaluator.startDriver(Observe{
        .owner = .init(item.take()),
        .target = target,
        .mode = .close,
    });
}

fn awaitExchange(evaluator: *machine.Machine) machine.MachineError!void {
    return observe(evaluator, .observe);
}

fn result(evaluator: *machine.Machine) machine.MachineError!void {
    return observe(evaluator, .claim);
}

fn observe(evaluator: *machine.Machine, mode: Observe.Mode) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const exchange = native.exchangeFromValue(item.borrow()) orelse return evaluator.typeError("an exchange");
    try evaluator.startDriver(Observe{
        .owner = .init(item.take()),
        .target = .{ .exchange = exchange },
        .mode = mode,
    });
}

const Target = union(enum) { resource: *native.Cell, exchange: *native.Operation };
const Observe = struct {
    const Mode = enum { observe, close, claim };
    pub const ownership: heap.DriverOwnership = .fields;
    owner: heap.Owned(Value),
    target: Target,
    mode: Mode,

    pub fn advance(evaluator: *machine.Machine, self: *Observe) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.target) {
            .resource => |resource| {
                resource.close();
                if (resource.joined()) return .completed;
                try evaluator.park(.{ .external = resource.source(1) });
            },
            .exchange => |exchange| {
                if (self.mode == .close) {
                    exchange.close();
                    if (exchange.closed()) return .completed;
                    try evaluator.park(.{ .external = exchange.source(4) });
                } else if (self.mode == .claim) {
                    const output = try evaluator.reserveStack(1);
                    switch (exchange.claimResult()) {
                        .pending => try evaluator.park(.{ .external = exchange.source(8) }),
                        .value => |item| return output.output(item),
                        .claimed => return evaluator.fail(.contract, "exchange result has already been claimed"),
                        .cancelled => return evaluator.fail(.cancelled, "exchange was cancelled"),
                        .failed => |failure| return evaluator.fail(@import("../native_descriptor.zig").mapErrorKind(failure.kind) orelse .io, failure.message[0..failure.len]),
                    }
                } else switch (exchange.completion()) {
                    .pending => try evaluator.park(.{ .external = exchange.source(8) }),
                    .ready => return .completed,
                    .cancelled => return evaluator.fail(.cancelled, "exchange was cancelled"),
                    .failed => |failure| return evaluator.fail(@import("../native_descriptor.zig").mapErrorKind(failure.kind) orelse .io, failure.message[0..failure.len]),
                }
            },
        }
        return .yielded;
    }
};
