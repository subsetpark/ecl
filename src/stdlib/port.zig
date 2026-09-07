//! Common exchange observation and cleanup, independent of native invocations.
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const machine = @import("../machine.zig");
const native = @import("../native_port.zig");
const Value = @import("../value.zig").Value;

pub const words = [_]env.BuiltinWord{
    .{ .name = "cancel", .effect = "exchange --", .doc = "Request exchange cancellation. Completion remains observable.", .primitive = cancel },
    .{ .name = "close", .doc = "( port -- ) Abort a resource or exchange and join its cleanup. Idempotent.", .primitive = close },
    .{ .name = "await", .doc = "( exchange -- ) Observe successful exchange completion or its terminal failure without draining output.", .primitive = awaitExchange },
    .{ .name = "result", .doc = "( exchange -- value ) Wait and claim an exchange result exactly once. Later claims raise 'contract.", .primitive = result },
};

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
