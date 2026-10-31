//! Common exchange observation and cleanup, independent of native invocations.
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const machine = @import("../machine.zig");
const Value = @import("../value.zig").Value;
const list = @import("../list.zig");
const std = @import("std");
const message = @import("../port_message.zig");
const scheduler = @import("../scheduler.zig");
const bytes = @import("../port_bytes.zig");
const transfer = @import("../port_transfer.zig");
const messages = @import("../port_messages.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const Resource = @import("../port_resource.zig").Resource;
const factories = @import("../port_factory.zig");
const endpoints = @import("../port_endpoint.zig");
const exchanges = @import("../port_exchange.zig");

pub const words = [_]env.BuiltinWord{
    .{ .name = "open", .effect = "factory config -- resource", .doc = "Initialize a registered resource in the calling scope.", .primitive = open },
    .{ .name = "begin", .effect = "resource operation request -- exchange", .doc = "Admit an operation with bounded structured parameters.", .primitive = begin },
    .{ .name = "endpoint", .effect = "source selector -- endpoint", .doc = "Borrow an attenuated endpoint supported by its source.", .primitive = endpoint },
    .{ .name = "send", .effect = "sender message --", .doc = "Atomically enqueue one bounded structured message, including an empty value.", .primitive = send },
    .{ .name = "receive", .effect = "receiver -- event", .doc = "Receive {kind message value value} or {kind eof}; one receiver may wait.", .primitive = receive },
    .{ .name = "finish", .effect = "sender --", .doc = "Finish a message sender after admitted sends, so its receiver sees {kind eof}. Idempotent. Byte endpoints finish with fd.finish.", .primitive = finish },
    .{ .name = "cancel", .effect = "exchange --", .doc = "Request cancellation. Completion remains observable.", .primitive = cancel },
    .{ .name = "shutdown", .effect = "resource --", .doc = "Perform registered graceful shutdown and join cleanup. Unsupported resources raise `domain.", .primitive = shutdown },
    .{ .name = "close", .effect = "resource-or-exchange --", .doc = "Abort and join cleanup. Idempotent.", .primitive = close },
    .{ .name = "await", .effect = "exchange --", .doc = "Observe completion without consuming the result or draining output.", .primitive = awaitExchange },
    .{ .name = "result", .effect = "exchange -- value", .doc = "Wait and claim a result once; a later claim raises `contract.", .primitive = result },
};

fn endpoint(evaluator: *machine.Unit) machine.MachineError!void {
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

/// The byte-stream primitives are published as `fd.core`; `port` keeps the
/// resource and exchange words. They live here because they share the
/// endpoint and transfer machinery with the message words.
pub fn read(evaluator: *machine.Unit) machine.MachineError!void {
    var maximum = try evaluator.popValue();
    defer maximum.deinit();
    if (maximum.borrow() != .int) return evaluator.typeError("a positive byte count");
    if (maximum.borrow().int <= 0) return evaluator.fail(.domain, "fd.read count must be positive");
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const backend = ReadBackend.fromValue(item.borrow()) orelse return evaluator.typeError("a readable byte endpoint");
    backend.beginRead() catch return evaluator.fail(.contract, "endpoint already has a pending reader");
    errdefer backend.endRead();
    const buffer = try evaluator.allocator.alloc(u8, @min(@as(usize, @intCast(maximum.borrow().int)), backend.readCapacity()));
    errdefer evaluator.allocator.free(buffer);
    const driver = try evaluator.allocator.create(ReadDriver);
    driver.* = .{ .allocator = evaluator.allocator, .port = item.take(), .backend = backend, .buffer = buffer };
    evaluator.adoptDriver(driver);
}

/// `fd.read-line`: the bytes through the next newline, read a transport
/// chunk at a time into the endpoint's read-ahead; what follows the newline
/// stays there for the next read. At EOF the rest of the stream is the line,
/// so `[]` means EOF and only EOF.
pub fn readLine(evaluator: *machine.Unit) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const backend = ReadBackend.fromValue(item.borrow()) orelse return evaluator.typeError("a readable byte endpoint");
    backend.beginRead() catch return evaluator.fail(.contract, "endpoint already has a pending reader");
    errdefer backend.endRead();
    const driver = try evaluator.allocator.create(LineReadDriver);
    driver.* = .{ .allocator = evaluator.allocator, .port = item.take(), .backend = backend };
    evaluator.adoptDriver(driver);
}

const LineReadDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    /// One transport read per step: a pipe hands over what it has, a file
    /// this much.
    const chunk: usize = 64 * 1024;
    allocator: std.mem.Allocator,
    port: Value,
    backend: ReadBackend,
    scanned: usize = 0,
    state: union(enum) {
        reading,
        materializing: struct { line: []u8, materializer: list.ByteListMaterializer },
        complete,
    } = .reading,

    pub fn deinit(self: *LineReadDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .materializing => |*building| {
                building.materializer.retire(releases);
                allocator.free(building.line);
            },
            .reading, .complete => {},
        }
        self.backend.endRead();
        releases.releaseValue(self.port);
    }

    fn take(self: *LineReadDriver, count: usize) error{OutOfMemory}!void {
        const line = try self.allocator.dupe(u8, self.backend.reader.buffered()[0..count]);
        self.backend.reader.consume(count);
        self.state = .{ .materializing = .{ .line = line, .materializer = .init(self.allocator, line) } };
    }

    pub fn advance(evaluator: *machine.Unit, self: *LineReadDriver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (self.state == .reading) {
            const waiting = self.backend.reader.buffered();
            if (std.mem.indexOfScalarPos(u8, waiting, self.scanned, '\n')) |newline| {
                try self.take(newline + 1);
                break;
            }
            self.scanned = waiting.len;
            switch (try self.backend.fill(evaluator, @min(chunk, self.backend.readCapacity()))) {
                .pending => {
                    try evaluator.park(.{ .external = self.backend.readSource() });
                    return .{ .yielded = .park };
                },
                .eof => {
                    try self.take(waiting.len);
                    break;
                },
                .data => |count| if (work.take(count) < count or work.exhausted()) return .stepped,
            }
        }
        return switch (try self.state.materializing.materializer.advance(work)) {
            .pending => .stepped,
            .complete => |line| complete: {
                self.state.materializing.materializer.deinit();
                self.allocator.free(self.state.materializing.line);
                self.state = .complete;
                break :complete .{ .output = line };
            },
        };
    }
};

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
    pub fn read(self: ReadBackend, evaluator: *machine.Unit, buffer: []u8) machine.MachineError!transfer.ReadProgress {
        return switch (self.reader.read(buffer)) {
            .pending => .pending,
            .eof => .eof,
            .data => |count| .{ .data = count },
            .failed => |failure| transportFailure(evaluator, failure),
        };
    }
    fn fill(self: ReadBackend, evaluator: *machine.Unit, max: usize) machine.MachineError!transfer.ReadProgress {
        return switch (try self.reader.fill(max)) {
            .pending => .pending,
            .eof => .eof,
            .data => |count| .{ .data = count },
            .failed => |failure| transportFailure(evaluator, failure),
        };
    }
};

pub fn write(evaluator: *machine.Unit) machine.MachineError!void {
    var input = try evaluator.popValue();
    errdefer input.deinit();
    if (input.borrow() != .list) return evaluator.typeError("a byte list");
    if (input.borrow().list.length() > 0 and input.borrow().isString())
        return evaluator.typeError("a byte list; encode text with io.write");
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const capability = endpoints.Endpoint.fromValue(item.borrow()) orelse return evaluator.typeError("a writable byte endpoint");
    const writer = capability.writer() orelse return evaluator.typeError("a writable byte endpoint");
    const permit = writer.beginWrite() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Finished => evaluator.fail(.io, "endpoint input is finished"),
    };
    errdefer permit.cancel();
    const driver = try evaluator.allocator.create(WriteDriver);
    driver.* = .init(evaluator.allocator, item.take(), input.take(), .{}, permit);
    evaluator.adoptDriver(driver);
}

const WriteDriver = transfer.WriteDriver(WriteBackend);
const WriteBackend = struct {
    pub const WritePermit = *endpoints.WritePermit;
    pub const invalid_byte_message = "fd.write contains a value outside 0...255";
    pub fn write(_: WriteBackend, evaluator: *machine.Unit, permit: WritePermit, buffer: []const u8) machine.MachineError!transfer.WriteProgress {
        return switch (permit.write(buffer)) {
            .pending => .pending,
            .written => |count| .{ .written = count },
            .failed => |failure| transportFailure(evaluator, failure),
        };
    }
};

pub fn finish(evaluator: *machine.Unit) machine.MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const capability = endpoints.Endpoint.fromValue(item.borrow()) orelse return evaluator.typeError("a writable endpoint");
    if (capability.writer()) |writer| writer.finish() else if (capability.sender()) |queue| queue.finish() else return evaluator.typeError("a writable endpoint");
}

fn send(evaluator: *machine.Unit) machine.MachineError!void {
    var input = try evaluator.popValue();
    defer input.deinit();
    var endpoint_value = try evaluator.popValue();
    defer endpoint_value.deinit();
    const capability = endpoints.Endpoint.fromValue(endpoint_value.borrow()) orelse return evaluator.typeError("a message sender");
    const queue = capability.sender() orelse return evaluator.typeError("a message sender");
    const driver = try evaluator.allocator.create(SendDriver);
    errdefer evaluator.allocator.destroy(driver);
    const validating = try message.Message.create(evaluator.allocator, input.borrow(), .{});
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
    pub fn advance(evaluator: *machine.Unit, self: *SendDriver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .validating) {
            const input = self.state.validating;
            const progress = input.advance(evaluator.workBudget()) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidValue => evaluator.typeError("a structured message without executable words, tasks, or modules"),
                error.Overflow => evaluator.fail(.overflow, "port message exceeds its structured value limits"),
            };
            if (progress == .pending) return .stepped;
            const envelope = try self.queue.envelope(input.validated().?);
            self.state = .{ .ready = envelope };
            input.retire(evaluator.releases);
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
        return evaluator.afterStep();
    }
};

fn receive(evaluator: *machine.Unit) machine.MachineError!void {
    var endpoint_value = try evaluator.popValue();
    defer endpoint_value.deinit();
    const capability = endpoints.Endpoint.fromValue(endpoint_value.borrow()) orelse return evaluator.typeError("a message receiver");
    const queue = capability.receiver() orelse return evaluator.typeError("a message receiver");
    queue.beginRead() catch return evaluator.fail(.contract, "endpoint already has a pending receiver");
    errdefer queue.endRead();
    const driver = try evaluator.allocator.create(ReceiveDriver);
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
    const Preparation = struct {
        pub const Error = machine.MachineError;
        evaluator: *machine.Unit,
        pub fn prepare(self: *@This(), value: Value) Error!Value {
            return dict.fromUniquePairs(self.evaluator.allocator, self.evaluator.releases, &.{
                .{ .{ .symbol = .{ .name = try intern.intern("kind") } }, .{ .symbol = .{ .name = try intern.intern("message") } } },
                .{ .{ .symbol = .{ .name = try intern.intern("value") } }, value },
            });
        }
        pub fn release(self: *@This(), value: Value) void {
            self.evaluator.releases.releaseValue(value);
        }
    };
    pub fn advance(evaluator: *machine.Unit, self: *ReceiveDriver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const scope = try callingScope(evaluator);
        const output = try evaluator.reserveStack(1);
        var preparation: Preparation = .{ .evaluator = evaluator };
        const delivery = self.queue.receive(scope, &preparation) catch |err| return switch (err) {
            error.ScopeClosing => publicationFailure(evaluator, error.ScopeClosing),
            error.Overflow => publicationFailure(evaluator, error.Overflow),
            else => |failure| failure,
        };
        switch (delivery) {
            .pending => try evaluator.park(.{ .external = self.queue.source() }),
            .failed => |failure| return transportFailure(evaluator, failure),
            .eof => return output.output(try dict.fromUniquePairs(evaluator.allocator, evaluator.releases, &.{.{ .{ .symbol = .{ .name = try intern.intern("kind") } }, .{ .symbol = .{ .name = try intern.intern("eof") } } }})),
            .message => |event| return output.output(event),
        }
        return evaluator.afterStep();
    }
};

fn open(evaluator: *machine.Unit) machine.MachineError!void {
    try startRequest(evaluator, .factory);
}

fn begin(evaluator: *machine.Unit) machine.MachineError!void {
    try startRequest(evaluator, .operation_selector);
}

fn startRequest(evaluator: *machine.Unit, comptime role: @import("../value.zig").PortVariant) machine.MachineError!void {
    var input = try evaluator.popValue();
    defer input.deinit();
    var capability = try evaluator.popValue();
    defer capability.deinit();
    const factory: ?*factories.Factory = if (role == .factory) factories.Factory.fromValue(capability.borrow()) else null;
    const operation_selector: ?*exchanges.Selector = if (role == .operation_selector) exchanges.Selector.fromValue(capability.borrow()) else null;
    if (factory == null and operation_selector == null)
        return evaluator.typeError(if (role == .factory) "a factory" else "an operation selector");
    var resource: ?heap.OwnedValue = if (role == .operation_selector) try evaluator.popValue() else null;
    defer if (resource) |*owned| owned.deinit();
    if (role == .operation_selector) {
        if (!operation_selector.?.accepts(resource.?.borrow())) return evaluator.typeError("a resource of the selector's issuing kind");
    }
    const driver = try evaluator.allocator.create(Request);
    errdefer evaluator.allocator.destroy(driver);
    const validated = try message.Message.create(evaluator.allocator, input.borrow(), if (role == .factory) factory.?.messageLimits() else operation_selector.?.messageLimits());
    driver.* = .{
        .capability = capability.take(),
        .kind = if (role == .operation_selector)
            .{ .operation = .{ .resource = resource.?.take(), .selector = operation_selector.? } }
        else
            .{ .factory = factory.? },
        .message = validated,
    };
    evaluator.adoptDriver(driver);
}

const Request = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    capability: Value,
    kind: union(enum) {
        factory: *factories.Factory,
        operation: struct { resource: Value, selector: *exchanges.Selector },
    },
    message: *message.Message,
    state: union(enum) { validating, ready, preparing: *factories.Opening, opening: Value, failed_open: struct { resource: Value, failure: @import("../port_error_data.zig").Observation }, consumed } = .validating,

    pub fn deinit(self: *Request, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        const pending: ?Value = switch (self.state) {
            .opening => |item| item,
            .failed_open => |failed| failed.resource,
            .preparing, .validating, .ready, .consumed => null,
        };
        if (pending) |item| {
            Resource.fromValue(item).?.close();
            releases.releaseValue(item);
        }
        if (self.state == .preparing) self.state.preparing.release();
        self.message.retire(releases);
        releases.releaseValue(self.capability);
        switch (self.kind) {
            .operation => |operation| releases.releaseValue(operation.resource),
            .factory => {},
        }
    }

    pub fn advance(evaluator: *machine.Unit, self: *Request) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .validating) {
            const progress = self.message.advance(evaluator.workBudget()) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidValue => evaluator.fail(.type, "port messages cannot contain executable words, tasks, or modules"),
                error.Overflow => evaluator.fail(.overflow, "port message exceeds its structured value limits"),
            };
            if (progress == .pending) return .stepped;
            self.state = .ready;
        }
        if (self.state == .preparing) {
            const opening = self.state.preparing;
            switch (try opening.advance(evaluator.workBudget())) {
                .yielded => {},
                .pending => |source| try evaluator.park(.{ .external = source }),
                .failed => |failure| return factoryFailure(evaluator, failure),
                .resource => |item| {
                    self.state = .{ .opening = item };
                    opening.release();
                },
            }
            return evaluator.afterStep();
        }
        if (self.state == .failed_open) {
            const failed = self.state.failed_open;
            const resource = Resource.fromValue(failed.resource).?;
            if (!resource.joined()) {
                try evaluator.park(.{ .external = resource.source() });
                return .{ .yielded = .park };
            }
            return evaluator.failWithErrorData(failed.failure);
        }
        if (self.state == .opening) {
            const item = self.state.opening;
            const resource = Resource.fromValue(item).?;
            switch (resource.initialization()) {
                .pending => |source| {
                    try evaluator.park(.{ .external = source });
                    return .{ .yielded = .park };
                },
                .failed => |failure| {
                    resource.close();
                    self.state = .{ .failed_open = .{ .resource = item, .failure = failure } };
                    return .stepped;
                },
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
                const output = try evaluator.reserveStack(1);
                switch (request.selector.begin(request.resource, scope, self.message.validated().?) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.ScopeClosing => evaluator.fail(.cancelled, "port scope is closing"),
                    error.WrongKind => evaluator.typeError("a resource of the selector's issuing kind"),
                }) {
                    .exchange => |exchange| {
                        self.state = .consumed;
                        return output.output(exchange);
                    },
                    .pending => |source| try evaluator.park(.{ .external = source }),
                    .closed => return evaluator.fail(.io, "resource is closed"),
                    .unsupported => return evaluator.fail(.domain, "operation lane is unavailable"),
                }
            },
            .factory => |factory| switch (try factory.open(.{ .scope = scope }, self.message.validated().?)) {
                .resource => |item| self.state = .{ .opening = item },
                .opening => |opening| self.state = .{ .preparing = opening },
                .failed => |failure| return factoryFailure(evaluator, failure),
            },
        }
        return evaluator.afterStep();
    }
};

fn factoryFailure(evaluator: *machine.Unit, failure: factories.Failure) machine.MachineError {
    return evaluator.failWithErrorData(failure);
}
fn transportFailure(evaluator: *machine.Unit, failure: bytes.Failure) machine.MachineError {
    return switch (failure) {
        .out_of_memory => error.OutOfMemory,
        .report => |report| evaluator.fail(report.kind, report.message[0..report.len]),
    };
}

fn cancel(evaluator: *machine.Unit) machine.MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    const exchange = exchanges.Exchange.fromValue(item.borrow()) orelse return evaluator.typeError("an exchange");
    exchange.cancel();
}

fn shutdown(evaluator: *machine.Unit) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const resource = Resource.fromValue(item.borrow()) orelse return evaluator.typeError("a resource");
    try evaluator.startDriver(Observe{ .owner = .init(item.take()), .target = .{ .resource = resource }, .mode = .shutdown });
}

fn close(evaluator: *machine.Unit) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    if (endpoints.Endpoint.fromValue(item.borrow())) |capability| {
        if (!capability.closable()) return evaluator.typeError("a resource or exchange; a borrowed endpoint closes with its source");
        try evaluator.startDriver(CloseEndpoint{ .owner = .init(item.take()), .endpoint = capability });
        return;
    }
    const target: Target = if (exchanges.Exchange.fromValue(item.borrow())) |exchange|
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

/// Closing an endpoint that is its own resource: request the close, then
/// park until its cleanup has joined, as closing the resource would.
const CloseEndpoint = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    owner: heap.Owned(Value),
    endpoint: *endpoints.Endpoint,
    requested: bool = false,

    pub fn advance(evaluator: *machine.Unit, self: *CloseEndpoint) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (!self.requested) {
            self.endpoint.close();
            self.requested = true;
        }
        if (!self.endpoint.closeJoined()) {
            try evaluator.park(.{ .external = self.endpoint.closeSource() });
            return .{ .yielded = .park };
        }
        return .completed;
    }
};

fn awaitExchange(evaluator: *machine.Unit) machine.MachineError!void {
    return observe(evaluator, .observe);
}

fn result(evaluator: *machine.Unit) machine.MachineError!void {
    return observe(evaluator, .claim);
}

fn observe(evaluator: *machine.Unit, mode: Observe.Mode) machine.MachineError!void {
    var item = try evaluator.popValue();
    errdefer item.deinit();
    const exchange = exchanges.Exchange.fromValue(item.borrow()) orelse return evaluator.typeError("an exchange");
    try evaluator.startDriver(Observe{
        .owner = .init(item.take()),
        .target = .{ .exchange = exchange },
        .mode = mode,
    });
}

const Target = union(enum) { resource: *Resource, exchange: *exchanges.Exchange };
const Observe = struct {
    const Mode = enum { observe, close, shutdown, claim };
    pub const ownership: heap.DriverOwnership = .fields;
    owner: heap.Owned(Value),
    target: Target,
    mode: Mode,

    pub fn advance(evaluator: *machine.Unit, self: *Observe) machine.MachineError!machine.WorkProgress {
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
                    try evaluator.park(.{ .external = exchange.source(.cleanup) });
                } else if (self.mode == .claim) {
                    const output = try evaluator.reserveStack(1);
                    switch (exchange.claimResult(try callingScope(evaluator)) catch |err| return publicationFailure(evaluator, err)) {
                        .pending => try evaluator.park(.{ .external = exchange.source(.completion) }),
                        .value => |item| return output.output(item),
                        .claimed => return evaluator.fail(.contract, "exchange result has already been claimed"),
                        .cancelled => return evaluator.fail(.cancelled, "exchange was cancelled"),
                        .failed => |failure| return evaluator.failWithErrorData(failure),
                    }
                } else switch (exchange.completion()) {
                    .pending => try evaluator.park(.{ .external = exchange.source(.completion) }),
                    .ready => return .completed,
                    .cancelled => return evaluator.fail(.cancelled, "exchange was cancelled"),
                    .failed => |failure| return evaluator.failWithErrorData(failure),
                }
            },
        }
        return evaluator.afterStep();
    }
};

fn callingScope(evaluator: *machine.Unit) machine.MachineError!*scheduler.TaskScope {
    return evaluator.task_scope orelse evaluator.fail(.cancelled, "port scope is closing");
}
fn publicationFailure(evaluator: *machine.Unit, err: error{ OutOfMemory, ScopeClosing, Overflow }) machine.MachineError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ScopeClosing => evaluator.fail(.cancelled, "port scope is closing"),
        error.Overflow => evaluator.fail(.overflow, "too many resource owners in one port publication"),
    };
}
