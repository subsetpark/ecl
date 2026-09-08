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
const bytes = @import("../port_bytes.zig");
const transfer = @import("../port_transfer.zig");
const messages = @import("../port_messages.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const Resource = @import("../port_resource.zig").Resource;
const builtin = @import("../builtin_port.zig");
const endpoints = @import("../port_endpoint.zig");

pub const words = [_]env.BuiltinWord{
    .{ .name = "open", .doc = "( factory config -- resource ) Initialize a registered resource in the calling scope.", .primitive = open },
    .{ .name = "begin", .doc = "( resource operation request -- exchange ) Admit a registered operation with bounded structured parameters.", .primitive = begin },
    .{ .name = "endpoint", .effect = "source selector -- endpoint", .doc = "Obtain an attenuated endpoint capability supported by its source.", .primitive = endpoint },
    .{ .name = "read", .doc = "( readable max -- bytes ) Read a positive byte chunk, or [] at stable EOF.", .primitive = read },
    .{ .name = "write", .doc = "( writable bytes -- ) Accept a complete byte list in FIFO order under bounded pressure.", .primitive = write },
    .{ .name = "send", .doc = "( sender message -- ) Atomically enqueue a bounded structured message.", .primitive = send },
    .{ .name = "receive", .doc = "( receiver -- event ) Receive one whole message or an EOF event.", .primitive = receive },
    .{ .name = "finish", .effect = "writable --", .doc = "Finish input after previously accepted data. Idempotent.", .primitive = finish },
    .{ .name = "cancel", .effect = "exchange --", .doc = "Request exchange cancellation. Completion remains observable.", .primitive = cancel },
    .{ .name = "shutdown", .doc = "( resource -- ) Perform registered graceful shutdown and join cleanup.", .primitive = shutdown },
    .{ .name = "close", .doc = "( port -- ) Abort a resource or exchange and join its cleanup. Idempotent.", .primitive = close },
    .{ .name = "await", .doc = "( exchange -- ) Observe successful exchange completion or its terminal failure without draining output.", .primitive = awaitExchange },
    .{ .name = "result", .doc = "( exchange -- value ) Wait and claim an exchange result exactly once. Later claims raise 'contract.", .primitive = result },
};

fn endpoint(evaluator: *machine.Machine) machine.MachineError!void {
    var selector = try evaluator.popValue();
    defer selector.deinit();
    var source = try evaluator.popValue();
    defer source.deinit();
    const capability = endpoints.Selector.fromValue(selector.borrow()) orelse return evaluator.typeError("an endpoint selector");
    const item = capability.borrow(source.borrow()) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.WrongKind => evaluator.typeError("a source of the endpoint selector's issuing kind"),
        error.Unsupported => evaluator.fail(.domain, "source does not support this endpoint"),
    };
    try evaluator.pushOwned(item);
}

fn read(evaluator: *machine.Machine) machine.MachineError!void {
    var maximum = try evaluator.popValue();
    defer maximum.deinit();
    if (maximum.borrow() != .int) return evaluator.typeError("a positive byte count");
    if (maximum.borrow().int <= 0) return evaluator.fail(.domain, "port.read count must be positive");
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const backend = ReadBackend.fromValue(item.borrow()) orelse return evaluator.typeError("a readable byte endpoint");
    backend.beginRead() catch return evaluator.fail(.contract, "endpoint already has a pending reader");
    errdefer backend.endRead();
    const buffer = try evaluator.allocator().alloc(u8, @min(@as(usize, @intCast(maximum.borrow().int)), backend.readCapacity()));
    errdefer evaluator.allocator().free(buffer);
    const driver = try evaluator.allocator().create(ReadDriver);
    driver.* = .{ .allocator = evaluator.allocator(), .port = item.take(), .backend = backend, .buffer = buffer };
    evaluator.adoptDriver(driver);
}

const ReadDriver = transfer.ReadDriver(ReadBackend);
const ReadBackend = struct {
    reader: *endpoints.Reader,

    fn fromValue(item: Value) ?ReadBackend {
        const capability = endpoints.Endpoint.fromValue(item) orelse return null;
        return .{ .reader = capability.reader() orelse return null };
    }
    fn beginRead(self: ReadBackend) error{Busy}!void {
        return self.reader.beginRead();
    }
    fn readCapacity(self: ReadBackend) usize {
        return self.reader.readCapacity();
    }
    pub fn endRead(self: ReadBackend) void {
        self.reader.endRead();
    }
    pub fn readSource(self: ReadBackend) @import("../external.zig").ReadinessSource {
        return self.reader.readSource();
    }
    pub fn read(self: ReadBackend, evaluator: *machine.Machine, buffer: []u8) machine.MachineError!transfer.ReadProgress {
        return switch (self.reader.read(buffer)) {
            .pending => .pending,
            .eof => .eof,
            .data => |count| .{ .data = count },
            .failed => |failure| transportFailure(evaluator, failure),
        };
    }
};

fn write(evaluator: *machine.Machine) machine.MachineError!void {
    var input = try evaluator.popValue();
    errdefer input.deinit();
    if (input.borrow() != .list) return evaluator.typeError("a byte list");
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const capability = endpoints.Endpoint.fromValue(item.borrow()) orelse return evaluator.typeError("a writable byte endpoint");
    const writer = capability.writer() orelse return evaluator.typeError("a writable byte endpoint");
    const permit = writer.beginWrite() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Finished => evaluator.fail(.io, "endpoint input is finished"),
    };
    errdefer permit.cancel();
    const driver = try evaluator.allocator().create(WriteDriver);
    driver.* = .init(evaluator.allocator(), item.take(), input.take(), .{}, permit);
    evaluator.adoptDriver(driver);
}

const WriteDriver = transfer.WriteDriver(WriteBackend);
const WriteBackend = struct {
    pub const WritePermit = *endpoints.WritePermit;
    pub const invalid_byte_message = "port.write contains a value outside 0...255";
    pub fn write(_: WriteBackend, evaluator: *machine.Machine, permit: WritePermit, buffer: []const u8) machine.MachineError!transfer.WriteProgress {
        return switch (permit.write(buffer)) {
            .pending => .pending,
            .written => |count| .{ .written = count },
            .failed => |failure| transportFailure(evaluator, failure),
        };
    }
};

fn finish(evaluator: *machine.Machine) machine.MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const capability = endpoints.Endpoint.fromValue(item.borrow()) orelse return evaluator.typeError("a writable endpoint");
    if (capability.writer()) |writer| writer.finish() else if (capability.sender()) |queue| queue.finish() else return evaluator.typeError("a writable endpoint");
}

fn send(evaluator: *machine.Machine) machine.MachineError!void {
    var input = try evaluator.popValue();
    defer input.deinit();
    var endpoint_value = try evaluator.popValue();
    defer endpoint_value.deinit();
    const capability = endpoints.Endpoint.fromValue(endpoint_value.borrow()) orelse return evaluator.typeError("a message sender");
    const queue = capability.sender() orelse return evaluator.typeError("a message sender");
    const driver = try evaluator.allocator().create(SendDriver);
    errdefer evaluator.allocator().destroy(driver);
    const validating = try message.Message.create(evaluator.allocator(), input.borrow(), .{});
    driver.* = .{ .endpoint = endpoint_value.take(), .queue = queue, .state = .{ .validating = validating } };
    evaluator.adoptDriver(driver);
}

const SendDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    endpoint: Value,
    queue: *messages.Queue,
    state: union(enum) { validating: *message.Message, ready: *messages.Envelope, consumed },

    pub fn deinit(self: *SendDriver, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        switch (self.state) {
            .validating => |input| input.retire(releases),
            .ready => |input| input.release(),
            .consumed => {},
        }
        releases.releaseValue(self.endpoint);
    }
    pub fn advance(evaluator: *machine.Machine, self: *SendDriver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .validating) {
            const input = self.state.validating;
            var budget = poll.WorkBudget.init(machine.kernel_poll_quantum);
            const progress = input.advance(&budget) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidValue => evaluator.typeError("a structured message without executable words, tasks, or modules"),
                error.Overflow => evaluator.fail(.overflow, "port message exceeds its structured value limits"),
            };
            if (progress == .pending) return .yielded;
            const envelope = try self.queue.envelope(input.validated().?);
            self.state = .{ .ready = envelope };
            input.retire(evaluator.releaseDomain());
        }
        switch (self.queue.send(self.state.ready)) {
            .accepted => {
                self.state = .consumed;
                return .completed;
            },
            .pending => |source| try evaluator.park(.{ .external = source }),
            .overflow => return evaluator.fail(.overflow, "message exceeds the resource queue byte budget"),
            .failed => |failure| return transportFailure(evaluator, failure),
        }
        return .yielded;
    }
};

fn receive(evaluator: *machine.Machine) machine.MachineError!void {
    var endpoint_value = try evaluator.popValue();
    defer endpoint_value.deinit();
    const capability = endpoints.Endpoint.fromValue(endpoint_value.borrow()) orelse return evaluator.typeError("a message receiver");
    const queue = capability.receiver() orelse return evaluator.typeError("a message receiver");
    queue.beginRead() catch return evaluator.fail(.contract, "endpoint already has a pending receiver");
    errdefer queue.endRead();
    const driver = try evaluator.allocator().create(ReceiveDriver);
    driver.* = .{ .endpoint = endpoint_value.take(), .queue = queue };
    evaluator.adoptDriver(driver);
}

const ReceiveDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    endpoint: Value,
    queue: *messages.Queue,
    pub fn deinit(self: *ReceiveDriver, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        self.queue.endRead();
        releases.releaseValue(self.endpoint);
    }
    pub fn advance(evaluator: *machine.Machine, self: *ReceiveDriver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.queue.peek()) {
            .pending => try evaluator.park(.{ .external = self.queue.source() }),
            .failed => |failure| return transportFailure(evaluator, failure),
            .eof => {
                const output = try evaluator.reserveStack(1);
                return output.output(try dict.fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{.{ .{ .symbol = try intern.intern("kind") }, .{ .symbol = try intern.intern("eof") } }}));
            },
            .message => |input| {
                defer input.release();
                const scope = try callingScope(evaluator);
                const output = try evaluator.reserveStack(1);
                const event = try dict.fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{
                    .{ .{ .symbol = try intern.intern("kind") }, .{ .symbol = try intern.intern("message") } },
                    .{ .{ .symbol = try intern.intern("value") }, input.value() },
                });
                const accepted = self.queue.claim(input, scope) catch |err| {
                    evaluator.releaseDomain().releaseValue(event);
                    return publicationFailure(evaluator, err);
                };
                if (!accepted) {
                    evaluator.releaseDomain().releaseValue(event);
                    return .yielded;
                }
                return output.output(event);
            },
        }
        return .yielded;
    }
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
    const registered = native.registeredCapability(capability.borrow(), role);
    const builtin_factory = if (role == .factory) builtin.RegisteredCapability.fromValue(capability.borrow(), .factory) else null;
    if (registered == null and builtin_factory == null)
        return evaluator.typeError(if (role == .factory) "a factory" else "an operation selector");
    var resource: ?heap.OwnedValue = if (role == .operation_selector) try evaluator.popValue() else null;
    defer if (resource) |*owned| owned.deinit();
    if (resource) |owned| {
        _ = native.fromValue(owned.borrow(), registered.?.instance(), registered.?.definition().resource()) orelse
            return evaluator.typeError("a resource of the selector's issuing kind");
    }
    const driver = try evaluator.allocator().create(Request);
    errdefer evaluator.allocator().destroy(driver);
    const validated = try message.Message.create(evaluator.allocator(), input.borrow(), .{});
    driver.* = .{
        .capability = capability.take(),
        .kind = if (resource) |*owned|
            .{ .operation = .{ .resource = owned.take(), .selector = registered.? } }
        else if (builtin_factory) |factory|
            .{ .builtin_factory = factory }
        else
            .{ .native_factory = registered.? },
        .message = validated,
    };
    evaluator.adoptDriver(driver);
}

const Request = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    capability: Value,
    kind: union(enum) {
        native_factory: *native.RegisteredCapability,
        builtin_factory: *builtin.RegisteredCapability,
        operation: struct { resource: Value, selector: *native.RegisteredCapability },
    },
    message: *message.Message,
    state: union(enum) { validating, ready, opening: Value, consumed } = .validating,

    pub fn deinit(self: *Request, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        switch (self.state) {
            .opening => |item| {
                Resource.fromValue(item).?.close();
                releases.releaseValue(item);
            },
            .validating, .ready, .consumed => {},
        }
        self.message.retire(releases);
        releases.releaseValue(self.capability);
        switch (self.kind) {
            .operation => |operation| releases.releaseValue(operation.resource),
            .native_factory, .builtin_factory => {},
        }
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
            const resource = Resource.fromValue(item).?;
            switch (resource.initialization()) {
                .pending => |source| {
                    try evaluator.park(.{ .external = source });
                    return .yielded;
                },
                .failed => |failure| return transportFailure(evaluator, failure),
                .ready => {
                    const output = try evaluator.reserveStack(1);
                    self.state = .consumed;
                    return output.output(item);
                },
            }
        }
        const scope = try callingScope(evaluator);
        switch (self.kind) {
            .operation => |request| {
                const capability = request.selector;
                const operation = capability.definition().operation;
                const cell = native.fromValue(request.resource, capability.instance(), operation.resource).?;
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
            },
            .native_factory => |capability| {
                const instance = capability.instance();
                const item = instance.portAccess().createConfigured(instance, capability.definition().factory, scope, self.message.validated().?) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Limit, error.InsufficientLanes => evaluator.fail(.domain, "port resource capacity is exhausted"),
                    error.Closed, error.Io => evaluator.fail(.io, "port resource creation failed"),
                    error.ScopeClosing => evaluator.fail(.cancelled, "port scope is closing"),
                };
                self.state = .{ .opening = item };
            },
            .builtin_factory => |factory| {
                switch (factory.definition().factory) {
                    .listener => {
                        const output = try evaluator.reserveStack(1);
                        const item = try @import("net.zig").openRegistered(evaluator, self.message.validated().?.value(), factory.instance());
                        self.state = .consumed;
                        return output.output(item);
                    },
                    .process => {
                        const next = try @import("proc.zig").prepareRegistered(evaluator, self.message.validated().?.value(), factory.instance());
                        evaluator.retireDriver(self);
                        next.install(evaluator);
                        return .detached;
                    },
                }
            },
        }
        return .yielded;
    }
};

fn fail(evaluator: *machine.Machine, failure: native.Failure) machine.MachineError {
    return switch (failure) {
        .out_of_memory => error.OutOfMemory,
        .report => |report| evaluator.fail(@import("../native_descriptor.zig").mapErrorKind(report.kind) orelse .io, report.message[0..report.len]),
    };
}
fn transportFailure(evaluator: *machine.Machine, failure: bytes.Failure) machine.MachineError {
    return switch (failure) {
        .out_of_memory => error.OutOfMemory,
        .report => |report| evaluator.fail(report.kind, report.message[0..report.len]),
    };
}

fn cancel(evaluator: *machine.Machine) machine.MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const exchange = native.exchangeFromValue(item.borrow()) orelse return evaluator.typeError("an exchange");
    exchange.cancel();
}

fn shutdown(evaluator: *machine.Machine) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const resource = Resource.fromValue(item.borrow()) orelse return evaluator.typeError("a resource");
    try evaluator.startDriver(Observe{ .owner = .init(item.take()), .target = .{ .resource = resource }, .mode = .shutdown });
}

fn close(evaluator: *machine.Machine) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const target: Target = if (native.exchangeFromValue(item.borrow())) |exchange|
        .{ .exchange = exchange }
    else if (Resource.fromValue(item.borrow())) |resource|
        .{ .resource = resource }
    else
        return evaluator.typeError("a resource or exchange");
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

const Target = union(enum) { resource: *Resource, exchange: *native.Operation };
const Observe = struct {
    const Mode = enum { observe, close, shutdown, claim };
    pub const ownership: heap.DriverOwnership = .fields;
    owner: heap.Owned(Value),
    target: Target,
    mode: Mode,

    pub fn advance(evaluator: *machine.Machine, self: *Observe) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.target) {
            .resource => |resource| {
                if (self.mode == .shutdown) {
                    switch (resource.shutdown()) {
                        .pending => {},
                        .ready => return .completed,
                        .unsupported => return evaluator.fail(.domain, "resource does not support graceful shutdown"),
                        .failed => |failure| return transportFailure(evaluator, failure),
                    }
                } else {
                    resource.close();
                    if (resource.joined()) return .completed;
                }
                try evaluator.park(.{ .external = resource.source() });
            },
            .exchange => |exchange| {
                if (self.mode == .close) {
                    exchange.close();
                    if (exchange.closed()) return .completed;
                    try evaluator.park(.{ .external = exchange.source(4) });
                } else if (self.mode == .claim) {
                    const output = try evaluator.reserveStack(1);
                    switch (exchange.claimResult(try callingScope(evaluator)) catch |err| return publicationFailure(evaluator, err)) {
                        .pending => try evaluator.park(.{ .external = exchange.source(8) }),
                        .value => |item| return output.output(item),
                        .claimed => return evaluator.fail(.contract, "exchange result has already been claimed"),
                        .cancelled => return evaluator.fail(.cancelled, "exchange was cancelled"),
                        .failed => |failure| return fail(evaluator, failure),
                    }
                } else switch (exchange.completion()) {
                    .pending => try evaluator.park(.{ .external = exchange.source(8) }),
                    .ready => return .completed,
                    .cancelled => return evaluator.fail(.cancelled, "exchange was cancelled"),
                    .failed => |failure| return fail(evaluator, failure),
                }
            },
        }
        return .yielded;
    }
};

fn callingScope(evaluator: *machine.Machine) machine.MachineError!*scheduler.TaskScope {
    return @ptrCast(@alignCast(evaluator.unit.task_scope orelse return evaluator.fail(.cancelled, "port scope is closing")));
}
fn publicationFailure(evaluator: *machine.Machine, err: error{ OutOfMemory, ScopeClosing, Overflow }) machine.MachineError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ScopeClosing => evaluator.fail(.cancelled, "port scope is closing"),
        error.Overflow => evaluator.fail(.overflow, "too many resource owners in one port publication"),
    };
}
