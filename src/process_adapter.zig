//! Value parsing for the registered process factory. The opening owns flat,
//! exact-capacity storage and borrows the validated request until retirement.
const std = @import("std");
const Value = @import("value.zig").Value;
const values = @import("value.zig");
const dict = @import("dict.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const external = @import("external.zig");
const process = @import("process_port.zig");
const factories = @import("port_factory.zig");
const message = @import("port_message.zig");
const Failure = factories.Failure;
const bindings = @import("module_bindings.zig");
const endpoints = @import("port_endpoint.zig");
const bytes = @import("port_bytes.zig");
const exchanges = @import("port_exchange.zig");

pub const registration = bindings.Registration.create(Binding);

const Binding = struct {
    instance: *bindings.Identity,
    access: *external.ProcessAccess,
    pub const definitions: []const bindings.Definition = &.{
        .{ .name = "process", .doc = "Create a process using the Session runtime.", .effect = "-- factory" },
        .{ .name = "stdin", .doc = process.DeclaredEndpoints.get(.stdin).doc, .effect = "-- selector" },
        .{ .name = "stdout", .doc = process.DeclaredEndpoints.get(.stdout).doc, .effect = "-- selector" },
        .{ .name = "stderr", .doc = process.DeclaredEndpoints.get(.stderr).doc, .effect = "-- selector" },
        .{ .name = "wait", .doc = process.DeclaredOperations.get(.wait).doc, .effect = "-- operation" },
        .{ .name = "terminate", .doc = process.DeclaredOperations.get(.terminate).doc, .effect = "-- operation" },
        .{ .name = "kill", .doc = process.DeclaredOperations.get(.kill).doc, .effect = "-- operation" },
        .{ .name = "capture-limits", .doc = process.DeclaredOperations.get(.capture_limits).doc, .effect = "-- operation" },
    };
    pub fn bind(memory: std.mem.Allocator, inherited: *const @import("machine.zig").InheritedContext) error{OutOfMemory}!*bindings.Publication {
        _ = memory;
        const instance = process.registeredInstance(inherited.runtime().process_access);
        instance.retain();
        errdefer instance.release();
        const owned = try instance.allocator().create(Binding);
        errdefer instance.allocator().destroy(owned);
        owned.* = .{ .instance = instance, .access = inherited.runtime().process_access };
        return bindings.Publication.create(Binding, owned);
    }
    pub fn allocator(self: *Binding) std.mem.Allocator {
        return self.instance.allocator();
    }
    pub fn release(self: *Binding) void {
        const memory = self.allocator();
        self.instance.release();
        memory.destroy(self);
    }
    pub fn seal(self: *Binding, index: usize) error{OutOfMemory}!Value {
        const owned = try self.allocator().create(RegisteredCapability);
        errdefer self.allocator().destroy(owned);
        owned.* = .{ .issuer = self.instance, .body = switch (index) {
            0 => .{ .factory = self.access },
            1 => .{ .endpoint = .stdin },
            2 => .{ .endpoint = .stdout },
            3 => .{ .endpoint = .stderr },
            4 => .{ .operation = .wait },
            5 => .{ .operation = .terminate },
            6 => .{ .operation = .kill },
            7 => .{ .operation = .capture_limits },
            else => unreachable,
        } };
        const item = switch (owned.body) {
            .factory => try factories.Factory.create(RegisteredCapability, self.instance.next(), owned),
            .endpoint => try endpoints.Selector.create(RegisteredCapability, self.instance.next(), owned),
            .operation => try exchanges.Selector.create(RegisteredCapability, self.instance.next(), owned),
        };
        self.instance.retain();
        return item;
    }
};

const EndpointKind = process.DeclaredEndpoints.Name;
const RegisteredCapability = struct {
    issuer: *bindings.Identity,
    body: union(enum) { factory: *external.ProcessAccess, endpoint: EndpointKind, operation: process.RegisteredOperation },
    pub fn instance(self: *RegisteredCapability) *bindings.Identity {
        return self.issuer;
    }
    pub fn allocator(self: *RegisteredCapability) std.mem.Allocator {
        return self.issuer.allocator();
    }
    pub fn acceptsOperation(self: *RegisteredCapability, source: Value) bool {
        const service = process.serviceFromValue(source) orelse return false;
        return process.serviceInstance(service) == self.issuer;
    }
    pub fn beginOperation(self: *RegisteredCapability, source: Value, scope: *@import("scheduler.zig").TaskScope, request: *const message.Validated) exchanges.AdmitError!exchanges.Admission {
        const service = process.serviceFromValue(source) orelse return error.WrongKind;
        if (process.serviceInstance(service) != self.issuer) return error.WrongKind;
        return service.admitOnLane(self.body.operation, scope, request);
    }
    pub fn openResource(self: *RegisteredCapability, context: factories.Context, config: *const message.Validated) error{OutOfMemory}!factories.Start {
        return open(self.allocator(), self.body.factory, context, config);
    }
    pub fn borrowEndpoint(self: *RegisteredCapability, source: Value) endpoints.BorrowError!Value {
        return borrowRegisteredEndpoint(source, self);
    }
    pub fn releasePort(self: *RegisteredCapability) void {
        const issuer = self.issuer;
        issuer.allocator().destroy(self);
        issuer.release();
    }
};

pub fn open(allocator: std.mem.Allocator, access: *external.ProcessAccess, context: factories.Context, config: *const message.Validated) error{OutOfMemory}!factories.Start {
    if (config.value() != .dict) return .{ .failed = Failure.init(.type, "expected a process specification dict") };
    const granted = access;
    const owned = try allocator.create(Parser);
    errdefer allocator.destroy(owned);
    const blob = try allocator.alloc(u8, config.footprint().bytes);
    errdefer allocator.free(blob);
    owned.* = .{ .memory = allocator, .access = granted, .context = context, .config = config.value(), .blob = blob, .keys = .{
        try intern.intern("executable"), try intern.intern("cwd"), try intern.intern("args"), try intern.intern("env"),
    } };
    return .{ .opening = try factories.Opening.create(Parser, owned) };
}

const Parser = struct {
    const Target = enum { executable, cwd, argument, env_name, env_value };
    const Text = struct { source: Value, target: Target, index: usize = 0, start: usize };
    refs: std.atomic.Value(usize) = .init(1),
    memory: std.mem.Allocator,
    access: *external.ProcessAccess,
    context: factories.Context,
    config: Value,
    keys: [4]u32,
    blob: []u8,
    used: usize = 0,
    field: usize = 0,
    index: usize = 0,
    collection: Value = .{ .int = 0 },
    phase: union(enum) { fields, arguments, environment, text: Text, launch } = .fields,
    executable: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    args: ?[][]const u8 = null,
    environment: ?[]process.EnvironmentEntry = null,
    env_name: []const u8 = &.{},

    pub fn allocator(self: *Parser) std.mem.Allocator {
        return self.memory;
    }
    pub fn release(self: *Parser) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const memory = self.memory;
        memory.free(self.blob);
        if (self.args) |args| memory.free(args);
        if (self.environment) |entries| memory.free(entries);
        memory.destroy(self);
    }
    pub fn processSpec(self: *Parser) process.ProcessSpec {
        return .{ .executable = self.executable.?, .cwd = self.cwd, .args = if (self.args) |args| args else &.{}, .environment = if (self.environment) |entries| entries else &.{} };
    }
    fn beginText(self: *Parser, source: Value, target: Target) bool {
        if (!source.isString()) return false;
        self.phase = .{ .text = .{ .source = source, .target = target, .start = self.used } };
        return true;
    }
    pub fn advance(self: *Parser, quantum: usize) error{OutOfMemory}!factories.Progress {
        var remaining = quantum;
        while (remaining != 0) : (remaining -= 1) switch (self.phase) {
            .fields => {
                if (self.field == self.config.dict.length()) {
                    if (self.executable == null) return .{ .failed = Failure.init(.domain, "process spec requires 'executable") };
                    self.phase = .launch;
                    continue;
                }
                const key = dict.keyAt(self.config.dict, self.field);
                const item = dict.valueAt(self.config.dict, self.field);
                if (key != .symbol) return .{ .failed = Failure.init(.type, "expected symbol process specification keys") };
                if (key.symbol == self.keys[0] or key.symbol == self.keys[1]) {
                    if (!self.beginText(item, if (key.symbol == self.keys[0]) .executable else .cwd))
                        return .{ .failed = Failure.init(.type, "process string fields must contain strings") };
                } else if (key.symbol == self.keys[2]) {
                    if (item != .list) return .{ .failed = Failure.init(.type, "'args must be a list of strings") };
                    self.args = try self.memory.alloc([]const u8, @intCast(item.list.length()));
                    self.collection = item;
                    self.index = 0;
                    self.phase = .arguments;
                } else if (key.symbol == self.keys[3]) {
                    if (item != .dict) return .{ .failed = Failure.init(.type, "'env must be a string-to-string dict") };
                    self.environment = try self.memory.alloc(process.EnvironmentEntry, @intCast(item.dict.length()));
                    self.collection = item;
                    self.index = 0;
                    self.phase = .environment;
                } else return .{ .failed = Failure.init(.domain, "unknown process specification field") };
            },
            .arguments, .environment => {
                const count = if (self.phase == .arguments) self.args.?.len else self.environment.?.len;
                if (self.index == count) {
                    self.field += 1;
                    self.phase = .fields;
                    continue;
                }
                const source = if (self.phase == .arguments) list.atUnchecked(self.collection, self.index) else dict.keyAt(self.collection.dict, self.index);
                if (!self.beginText(source, if (self.phase == .arguments) .argument else .env_name))
                    return .{ .failed = Failure.init(.type, "process string fields must contain strings") };
            },
            .text => |*text| {
                if (text.index != text.source.list.length()) {
                    const scalar = values.unicodeScalar(list.atUnchecked(text.source, text.index).char) orelse
                        return .{ .failed = Failure.init(.domain, "process string contains an invalid Unicode scalar") };
                    var encoded: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(scalar, &encoded) catch
                        return .{ .failed = Failure.init(.domain, "process string contains an invalid Unicode scalar") };
                    @memcpy(self.blob[self.used..][0..count], encoded[0..count]);
                    self.used += count;
                    text.index += 1;
                    continue;
                }
                const slice = self.blob[text.start..self.used];
                switch (text.target) {
                    .executable, .cwd => |target| {
                        if (target == .executable) self.executable = slice else self.cwd = slice;
                        self.field += 1;
                        self.phase = .fields;
                    },
                    .argument => {
                        self.args.?[self.index] = slice;
                        self.index += 1;
                        self.phase = .arguments;
                    },
                    .env_name => {
                        self.env_name = slice;
                        if (!self.beginText(dict.valueAt(self.collection.dict, self.index), .env_value))
                            return .{ .failed = Failure.init(.type, "process string fields must contain strings") };
                    },
                    .env_value => {
                        self.environment.?[self.index] = .{ .name = self.env_name, .value = slice };
                        self.index += 1;
                        self.phase = .environment;
                    },
                }
            },
            .launch => {
                _ = self.refs.fetchAdd(1, .monotonic);
                const prepared = process.PreparedSpec.create(Parser, self) catch |err| {
                    self.release();
                    return err;
                };
                const resource = process.openPrepared(self.access, self.context.scope, prepared) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Unsupported => .{ .failed = Failure.init(.domain, "process ports are unsupported on this target") },
                    error.InvalidSpec => .{ .failed = Failure.init(.domain, "invalid process specification") },
                    error.LiveLimit => .{ .failed = Failure.init(.domain, "host process-port limit reached") },
                    error.ScopeClosing => .{ .failed = Failure.init(.cancelled, "process scope is closing") },
                    error.Io => .{ .failed = Failure.init(.io, "could not spawn process") },
                };
                self.config = .{ .int = 0 };
                self.collection = .{ .int = 0 };
                return .{ .resource = resource };
            },
        };
        return .yielded;
    }
};

const EndpointState = struct {
    cell: *process.ProcessCell,
    kind: EndpointKind,
    fn capability(self: *EndpointState) *Endpoint {
        return @ptrCast(self);
    }
};

pub const ProcessReader = struct { cell: *process.ProcessCell, stream: process.Stream };

/// An attenuated borrow pins resource metadata, without owning its scope or
/// keeping its backend open. Reader exclusion and write ordering belong to
/// the resource's transports and are shared with the domain words.
pub const Endpoint = opaque {
    pub const Permit = process.WritePermit;
    pub fn allocator(self: *Endpoint) std.mem.Allocator {
        return self.state().cell.allocator;
    }
    fn state(self: *Endpoint) *EndpointState {
        return @ptrCast(@alignCast(self));
    }
    pub fn reader(self: *Endpoint) ?ProcessReader {
        const owned = self.state();
        return switch (owned.kind) {
            .stdin => null,
            .stdout => .{ .cell = owned.cell, .stream = .stdout },
            .stderr => .{ .cell = owned.cell, .stream = .stderr },
        };
    }
    pub fn writer(self: *Endpoint) ?*process.ProcessCell {
        const owned = self.state();
        return switch (owned.kind) {
            .stdin => owned.cell,
            .stdout, .stderr => null,
        };
    }
    pub fn beginRead(self: *Endpoint) error{Busy}!void {
        const stream = self.reader().?;
        stream.cell.beginRead(stream.stream) catch return error.Busy;
    }
    pub fn endRead(self: *Endpoint) void {
        const stream = self.reader().?;
        stream.cell.endRead(stream.stream);
    }
    pub fn readCapacity(self: *Endpoint) usize {
        const stream = self.reader().?;
        return stream.cell.readCapacity(stream.stream);
    }
    pub fn read(self: *Endpoint, destination: []u8) bytes.Read {
        const stream = self.reader().?;
        return switch (stream.cell.read(stream.stream, destination)) {
            .pending => .pending,
            .eof => .eof,
            .data => |count| .{ .data = count },
            .io => .{ .failed = bytes.Failure.init(.io, "process output failed") },
        };
    }
    pub fn readSource(self: *Endpoint) @import("external.zig").ReadinessSource {
        const stream = self.reader().?;
        return stream.cell.readSource(stream.stream);
    }
    pub fn beginWrite(self: *Endpoint) error{ OutOfMemory, Finished }!*Permit {
        return self.writer().?.beginWrite() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Closed => error.Finished,
        };
    }
    pub fn writeBytes(permit: *Permit, source: []const u8) bytes.Write {
        return switch (permit.write(source)) {
            .pending => .pending,
            .written => |count| .{ .written = count },
            .io => .{ .failed = bytes.Failure.init(.io, "process stdin is closed") },
        };
    }
    pub fn finish(self: *Endpoint) void {
        self.writer().?.closeInput();
    }
    pub fn releasePort(self: *Endpoint) void {
        const owned = self.state();
        const cell = owned.cell;
        cell.allocator.destroy(owned);
        cell.releaseReadiness();
    }
};

/// Borrows both arguments. Success owns one resource pin and one endpoint
/// value; failure neither changes scope ownership nor retains a partial pin.
fn borrowRegisteredEndpoint(parent: Value, selector: *RegisteredCapability) error{ OutOfMemory, WrongKind }!Value {
    const cell = process.fromValue(parent) orelse return error.WrongKind;
    if (cell.instance != selector.instance()) return error.WrongKind;
    const owned = try cell.allocator.create(EndpointState);
    errdefer cell.allocator.destroy(owned);
    owned.* = .{ .cell = cell, .kind = selector.body.endpoint };
    const identity = cell.instance.next();
    const result = switch (owned.kind) {
        .stdin => try endpoints.Endpoint.create(Endpoint, .writer, identity, owned.capability()),
        .stdout, .stderr => try endpoints.Endpoint.create(Endpoint, .reader, identity, owned.capability()),
    };
    cell.retainReadiness();
    return result;
}
