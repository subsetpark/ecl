// zlint-disable homeless-try -- zlint 0.9.1 does not resolve the SDK's aliased error unions; Zig validates every callback signature.
//! Bundled TCP service implemented entirely through the public native SDK.
const std = @import("std");
const builtin = @import("builtin");
const ecl = @import("ecl-native");
const posix = std.posix;
const Address = std.Io.net.IpAddress;
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
    max_live_listeners: usize = 16,
    kernel_backlog: u31 = 128,
    max_live_connections: usize = 64,
    receive_capacity: usize = 64 * 1024,
    send_capacity: usize = 64 * 1024,
    pub fn validate(self: Limits) error{InvalidConfig}!void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.InvalidConfig;
        if (self.max_live_listeners == 0 or self.kernel_backlog == 0 or self.max_live_connections == 0 or self.receive_capacity == 0 or self.send_capacity == 0) return error.InvalidConfig;
        const count = std.math.add(usize, self.max_live_listeners, self.max_live_connections) catch return error.InvalidConfig;
        const slots = std.math.mul(usize, count, 5) catch return error.InvalidConfig;
        _ = std.math.add(usize, slots, 1) catch return error.InvalidConfig;
    }
    pub fn encode(self: Limits) [40]u8 {
        // SAFETY: every byte is filled by the five fixed-width fields below.
        var result: [40]u8 = undefined;
        for ([_]usize{ self.max_live_listeners, self.kernel_backlog, self.max_live_connections, self.receive_capacity, self.send_capacity }, 0..) |value, index|
            std.mem.writeInt(u64, result[index * 8 ..][0..8], value, .little);
        return result;
    }
    fn decode(bytes: []const u8) error{Failed}!Limits {
        if (bytes.len == 0) return .{};
        if (bytes.len != 40) return error.Failed;
        // SAFETY: the complete field array is decoded before construction.
        var fields: [5]usize = undefined;
        for (&fields, 0..) |*value, index| value.* = std.math.cast(usize, std.mem.readInt(u64, bytes[index * 8 ..][0..8], .little)) orelse return error.Failed;
        const result: Limits = .{ .max_live_listeners = fields[0], .kernel_backlog = std.math.cast(u31, fields[1]) orelse return error.Failed, .max_live_connections = fields[2], .receive_capacity = fields[3], .send_capacity = fields[4] };
        result.validate() catch return error.Failed;
        return result;
    }
};
const Service = ecl.Instance(struct {
    pub const State = struct {
        limits: Limits = .{},
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        listeners: usize = 0,
        connections: usize = 0,
        fn reserveListener(self: *State) bool {
            lock(&self.mutex);
            defer unlock(&self.mutex);
            if (self.listeners == self.limits.max_live_listeners) return false;
            self.listeners += 1;
            return true;
        }
        fn releaseListener(self: *State) void {
            lock(&self.mutex);
            defer unlock(&self.mutex);
            self.listeners -= 1;
        }
        fn releaseConnection(self: *State) void {
            lock(&self.mutex);
            defer unlock(&self.mutex);
            self.connections -= 1;
            self.changed.broadcast(io());
        }
        fn wake(self: *State) void {
            lock(&self.mutex);
            defer unlock(&self.mutex);
            self.changed.broadcast(io());
        }
    };
    pub fn init() State {
        return .{};
    }
    pub fn initialize(state: *State, context: *ecl.InstanceContext) ecl.InstanceResult {
        if (!context.consume()) return .pending;
        state.limits = try Limits.decode(context.configuration());
        try context.configureEndpoint(Connection, .input, state.limits.receive_capacity);
        try context.configureEndpoint(Connection, .output, state.limits.send_capacity);
        return .complete;
    }
    pub fn retire(_: *State, _: *ecl.InstanceContext) bool {
        return true;
    }
});
const Wake = struct {
    descriptors: [2]posix.fd_t,
    fn create() error{Io}!Wake {
        const descriptors = std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch return error.Io;
        return .{ .descriptors = descriptors };
    }
    fn signal(self: *const Wake) void {
        const byte = [_]u8{0};
        while (true) switch (posix.errno(posix.system.write(self.descriptors[1], &byte, 1))) {
            .INTR => continue,
            else => return,
        };
    }
    fn drain(self: *const Wake) void {
        // SAFETY: read only writes this scratch buffer; its contents are discarded.
        var bytes: [64]u8 = undefined;
        while (true) {
            const count = posix.system.read(self.descriptors[0], &bytes, bytes.len);
            if (count <= 0 or count < bytes.len) return;
        }
    }
    fn close(self: *const Wake) void {
        for (self.descriptors) |fd| std.Io.Threaded.closeFd(fd);
    }
};
const Socket = struct {
    fd: posix.fd_t,
    fn close(self: Socket) void {
        std.Io.Threaded.closeFd(self.fd);
    }
};
const Accepted = struct {
    socket: Socket,
    service: *Service.State,
    local: Address,
    peer: Address,
    fn close(self: Accepted) void {
        self.socket.close();
        self.service.releaseConnection();
    }
};
const Listening = struct { socket: Socket, wake: Wake, service: *Service.State, local: Address };
const Listener = ecl.Port(.{ .controller = struct {
    pub const name = "listener";
    pub const CapacityFailure = ListenCapacityFailure;
    pub const Lane = enum { accept, control };
    pub const cancellation = ecl.PortCancellation.acknowledge;
    pub const State = struct {
        mutex: std.Io.Mutex = .init,
        listener: ?Listening = null,
        accepted: ?Accepted = null,
        accept_cancelled: std.atomic.Value(bool) = .init(false),
    };
    pub const operations = .{
        .accept = .{ .doc = "Accept an independently owned connection; request [].", .handler = accept, .lane = .accept, .endpoints = .{} },
        .local_address = .{ .visibility = .private, .doc = "Read the listener endpoint; request [].", .handler = localAddress, .lane = .control, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, context: *ecl.Controller) void {
        const address = switch (parseInput(context)) {
            .address => |address| address,
            .failure => |failure| return reportListenFailure(context, failure),
        };
        const service = context.instance(Service).?;
        if (!service.reserveListener()) return listenFailure(context, .domain, "host listener limit reached", "limit");
        const socket = listen(address, service.limits.kernel_backlog) catch |err| {
            service.releaseListener();
            return listenFailure(context, .io, switch (err) {
                error.AddressInUse => "address already in use",
                error.AddressUnavailable => "address is not available on this host",
                error.Unsupported => "host does not support listening on this address family or protocol",
                error.Resources => "host lacks resources to listen",
                else => "could not listen",
            }, switch (err) {
                error.AddressInUse => "in-use",
                error.AddressUnavailable => "unavailable",
                error.Unsupported => "unsupported",
                error.Resources => "resources",
                else => "io",
            });
        };
        const wake = Wake.create() catch {
            socket.socket.close();
            service.releaseListener();
            return listenFailure(context, .io, "could not listen", "io");
        };
        lock(&state.mutex);
        state.listener = .{ .socket = socket.socket, .local = socket.address, .wake = wake, .service = service };
        unlock(&state.mutex);
    }
    pub fn cancel(state: *State) void {
        state.accept_cancelled.store(true, .release);
        lock(&state.mutex);
        defer unlock(&state.mutex);
        if (state.listener) |listener| {
            listener.wake.signal();
            listener.service.wake();
        }
    }
    pub fn cancelOperation(state: *State, selected: Lane) void {
        if (selected == .accept) cancel(state);
    }
    pub fn shutdown(_: *State, _: *ecl.Shutdown) void {}
    pub fn deinit(state: *State) void {
        if (state.accepted) |accepted| accepted.close();
        if (state.listener) |listener| {
            listener.socket.close();
            listener.wake.close();
            listener.service.releaseListener();
        }
        state.listener = null;
        state.accepted = null;
    }
    fn accept(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
        defer _ = context.acknowledgeCancellation();
        try emptyRequest(context);
        state.accept_cancelled.store(false, .release);
        if (context.cancelled()) return error.Cancelled;
        const listener = state.listener.?;
        while (!context.cancelled()) {
            lock(&listener.service.mutex);
            while (listener.service.connections == listener.service.limits.max_live_connections and !state.accept_cancelled.load(.acquire))
                listener.service.changed.waitUncancelable(io(), &listener.service.mutex);
            unlock(&listener.service.mutex);
            if (context.cancelled()) return error.Cancelled;
            var fds = [_]posix.pollfd{ .{ .fd = listener.socket.fd, .events = posix.POLL.IN, .revents = 0 }, .{ .fd = listener.wake.descriptors[0], .events = posix.POLL.IN, .revents = 0 } };
            _ = posix.poll(&fds, -1) catch return fail(context, .io, "listener polling failed");
            if (context.cancelled()) return error.Cancelled;
            if (fds[1].revents != 0) listener.wake.drain();
            if (fds[0].revents == 0) continue;
            lock(&listener.service.mutex);
            if (listener.service.connections == listener.service.limits.max_live_connections) {
                unlock(&listener.service.mutex);
                continue;
            }
            listener.service.connections += 1;
            unlock(&listener.service.mutex);
            const accepted = acceptSocket(listener) catch |err| {
                listener.service.releaseConnection();
                if (err == error.Pending) continue;
                return fail(context, .io, "network accept failed");
            };
            lock(&state.mutex);
            state.accepted = accepted;
            unlock(&state.mutex);
            defer {
                lock(&state.mutex);
                const abandoned = state.accepted;
                state.accepted = null;
                unlock(&state.mutex);
                if (abandoned) |owned| owned.close();
            }
            const builder = context.builder();
            try builder.list(0);
            try builder.child(Connection, .independent);
            try builder.result();
            return;
        }
        return error.Cancelled;
    }
    fn localAddress(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
        defer _ = context.acknowledgeCancellation();
        try emptyRequest(context);
        try addressResult(context, state.listener.?.local);
    }
} });
const Connection = ecl.Port(.{
    .controller = struct {
        pub const name = "connection";
        pub const Lane = enum { accept, control };
        pub const cancellation = ecl.PortCancellation.acknowledge;
        pub const State = struct {
            mutex: std.Io.Mutex = .init,
            backend: ?struct { accepted: Accepted, wake: Wake } = null,
            write_finished: std.Io.Event = .unset,
            transport_failed: std.atomic.Value(bool) = .init(false),
        };
        pub const endpoints = .{
            .input = ecl.declarations.Endpoint{ .doc = "Select the readable connection byte stream.", .transport = .bytes, .direction = .output, .owner = .resource },
            .output = ecl.declarations.Endpoint{ .doc = "Select the writable connection byte stream.", .transport = .bytes, .direction = .input, .owner = .resource },
        };
        pub const activities = .{
            .reader = .{ .handler = read, .endpoints = .{.input} },
            .writer = .{ .handler = write, .endpoints = .{.output} },
        };
        pub const operations = .{
            .local_address = .{ .visibility = .private, .doc = "Read the connection local endpoint; request [].", .handler = localAddress, .lane = .control, .endpoints = .{} },
            .peer_address = .{ .name = "peer-address", .doc = "Read the connection peer endpoint; request [].", .handler = peerAddress, .lane = .control, .endpoints = .{} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, context: *ecl.Controller) void {
            const parent = context.initializationParent(Listener) orelse return context.fail(.contract, "connection requires an accepted socket");
            lock(&parent.mutex);
            const accepted = parent.accepted;
            parent.accepted = null;
            unlock(&parent.mutex);
            const owned = accepted orelse return context.fail(.contract, "accepted socket was already consumed");
            const wake = Wake.create() catch {
                owned.close();
                return context.fail(.io, "could not create connection wake descriptor");
            };
            lock(&state.mutex);
            state.backend = .{ .accepted = owned, .wake = wake };
            unlock(&state.mutex);
        }
        pub fn cancel(state: *State) void {
            lock(&state.mutex);
            defer unlock(&state.mutex);
            if (state.backend) |backend| backend.wake.signal();
        }
        pub fn cancelOperation(_: *State, _: Lane) void {}
        pub fn deinit(state: *State) void {
            if (state.backend) |backend| {
                backend.accepted.close();
                backend.wake.close();
            }
            state.backend = null;
        }
        pub fn shutdown(state: *State, context: *ecl.Shutdown) void {
            context.finishInput(Connection, .output) catch return;
            state.write_finished.waitUncancelable(io());
        }
        fn read(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            const backend = state.backend.?;
            const output = try context.endpoint(Connection, .input);
            // SAFETY: only the prefix returned by the successful stream read is used.
            var buffer: [64 * 1024]u8 = undefined;
            const capacity = @min(buffer.len, backend.accepted.service.limits.receive_capacity);
            while (!context.cancelled()) {
                const count = posix.system.recv(backend.accepted.socket.fd, &buffer, capacity, 0);
                switch (posix.errno(count)) {
                    .SUCCESS => {
                        if (count == 0) return;
                        try output.write(buffer[0..@intCast(count)]);
                    },
                    .INTR => continue,
                    .AGAIN => try waitSocket(backend.accepted.socket.fd, backend.wake, posix.POLL.IN, context),
                    else => {
                        state.transport_failed.store(true, .release);
                        context.failStreams(.io, if (posix.errno(count) == .CONNRESET) "connection reset by peer" else "connection transport failed");
                        return;
                    },
                }
            }
        }
        fn write(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            defer state.write_finished.set(io());
            writeAll(state, context) catch |err| {
                state.transport_failed.store(true, .release);
                context.failStreams(.io, "connection write failed");
                return err;
            };
        }
        fn writeAll(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            const backend = state.backend.?;
            const input = try context.endpoint(Connection, .output);
            // SAFETY: only the prefix returned by the successful stream read is used.
            var buffer: [64 * 1024]u8 = undefined;
            while (try input.read(buffer[0..@min(buffer.len, backend.accepted.service.limits.send_capacity)])) |count| {
                var index: usize = 0;
                while (index != count) {
                    if (context.cancelled()) return error.Cancelled;
                    const flags: u32 = if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;
                    const written = posix.system.send(backend.accepted.socket.fd, buffer[index..count].ptr, count - index, flags);
                    switch (posix.errno(written)) {
                        .SUCCESS => {
                            if (written == 0) return error.Failed;
                            index += @intCast(written);
                        },
                        .INTR => continue,
                        .AGAIN => try waitSocket(backend.accepted.socket.fd, backend.wake, posix.POLL.OUT, context),
                        else => {
                            context.fail(.io, "connection write failed");
                            return error.Failed;
                        },
                    }
                }
            }
            while (true) switch (posix.errno(posix.system.shutdown(backend.accepted.socket.fd, posix.SHUT.WR))) {
                .SUCCESS, .NOTCONN => return,
                .INTR => continue,
                else => return error.Failed,
            };
        }
        fn localAddress(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            defer _ = context.acknowledgeCancellation();
            try emptyRequest(context);
            if (state.transport_failed.load(.acquire)) return fail(context, .io, "network operation failed");
            try addressResult(context, state.backend.?.accepted.local);
        }
        fn peerAddress(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            defer _ = context.acknowledgeCancellation();
            try emptyRequest(context);
            if (state.transport_failed.load(.acquire)) return fail(context, .io, "network operation failed");
            try addressResult(context, state.backend.?.accepted.peer);
        }
    },
});
fn fail(context: *ecl.Controller, kind: ecl.ErrorKind, message: []const u8) ecl.ControllerError {
    context.fail(kind, message);
    return error.Failed;
}
fn listenFailure(context: *ecl.Controller, kind: ecl.ErrorKind, message: []const u8, reason: []const u8) void {
    const builder = context.errorData();
    for (0..2) |index| {
        builder.input(&.{index * 2}) catch return;
        builder.input(&.{index * 2 + 1}) catch return;
    }
    builder.symbol("reason") catch return;
    builder.symbol(reason) catch return;
    builder.dictionary(3) catch return;
    builder.seal() catch return;
    context.fail(kind, message);
}
fn emptyRequest(context: *ecl.Controller) ecl.ControllerError!void {
    const input = context.input(&.{}).?;
    if (input.kind() != .list or input.length().? != 0) return fail(context, .domain, "network operations require an empty request list");
}
const ListenDiagnostic = struct { kind: ecl.ErrorKind, message: []const u8, reason: ?[]const u8 = null };
const ParsedListen = union(enum) { address: Address, failure: ListenDiagnostic };
fn reportListenFailure(context: *ecl.Controller, diagnostic: ListenDiagnostic) void {
    if (diagnostic.reason) |reason| listenFailure(context, diagnostic.kind, diagnostic.message, reason) else context.fail(diagnostic.kind, diagnostic.message);
}
fn parseInput(context: anytype) ParsedListen {
    const input = context.input(&.{}).?;
    if (input.kind() != .dict) return .{ .failure = .{ .kind = .type, .message = "expected a listen configuration dict" } };
    if (input.length().? != 2) return .{ .failure = .{ .kind = .domain, .message = "net.listen configuration needs exactly 'address and 'port" } };
    var address_index: ?u64 = null;
    var port_index: ?u64 = null;
    for (0..2) |index| {
        const key = context.input(&.{index * 2}).?.symbol() orelse return .{ .failure = .{ .kind = .domain, .message = "net.listen configuration accepts only 'address and 'port" } };
        if (std.mem.eql(u8, key, "address")) address_index = index * 2 + 1 else if (std.mem.eql(u8, key, "port")) port_index = index * 2 + 1 else return .{ .failure = .{ .kind = .domain, .message = "net.listen configuration accepts only 'address and 'port" } };
    }
    const address = address_index orelse return .{ .failure = .{ .kind = .domain, .message = "net.listen configuration is missing 'address" } };
    const port_path = port_index orelse return .{ .failure = .{ .kind = .domain, .message = "net.listen configuration is missing 'port" } };
    if (!context.input(&.{address}).?.isString()) return .{ .failure = .{ .kind = .type, .message = "expected a string 'address" } };
    const length = context.input(&.{address}).?.length().?;
    const port = context.input(&.{port_path}).?.int() orelse return .{ .failure = .{ .kind = .type, .message = "expected an integer 'port" } };
    if (port < 0 or port > 65535) return .{ .failure = .{ .kind = .domain, .message = "net.listen 'port must lie in 0...65535", .reason = "invalid" } };
    // SAFETY: used tracks precisely the initialized UTF-8 prefix.
    var buffer: [64]u8 = undefined;
    var used: usize = 0;
    for (0..length) |index| {
        const scalar = context.input(&.{ address, index }).?.char() orelse return .{ .failure = .{ .kind = .type, .message = "expected a string 'address" } };
        // SAFETY: utf8Encode initializes the returned prefix before copying.
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch return .{ .failure = .{ .kind = .domain, .message = "net.listen 'address is not an IP literal", .reason = "invalid" } };
        if (count > buffer.len - used) return .{ .failure = .{ .kind = .domain, .message = "net.listen 'address is not an IP literal", .reason = "invalid" } };
        @memcpy(buffer[used..][0..count], encoded[0..count]);
        used += count;
    }
    const parsed = Address.parse(buffer[0..used], @intCast(port)) catch return .{ .failure = .{ .kind = .domain, .message = "net.listen 'address is not an IP literal", .reason = "invalid" } };
    return .{ .address = switch (parsed) {
        .ip4 => parsed,
        .ip6 => |address6| Address.fromIp6(address6),
    } };
}
fn addressResult(context: *ecl.Controller, address: Address) ecl.ControllerError!void {
    // SAFETY: the writer exposes only bytes it has initialized.
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    switch (address) {
        .ip4 => |v4| writer.print("{d}.{d}.{d}.{d}", .{ v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3] }) catch unreachable,
        .ip6 => |v6| {
            const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = v6.bytes, .interface_name = null };
            writer.print("{f}", .{unresolved}) catch unreachable;
        },
    }
    const text = writer.buffered();
    const builder = context.builder();
    try builder.symbol("address");
    for (text) |byte| try builder.char(byte);
    try builder.list(@intCast(text.len));
    try builder.symbol("port");
    try builder.int(address.getPort());
    try builder.dictionary(2);
    try builder.result();
}
fn waitSocket(fd: posix.fd_t, wake: Wake, events: i16, context: *ecl.Activity) ecl.ControllerError!void {
    var fds = [_]posix.pollfd{ .{ .fd = fd, .events = events, .revents = 0 }, .{ .fd = wake.descriptors[0], .events = posix.POLL.IN, .revents = 0 } };
    _ = posix.poll(&fds, -1) catch {
        context.fail(.io, "connection polling failed");
        return error.Failed;
    };
    if (context.cancelled()) return error.Cancelled;
}
fn nonblocking(fd: posix.fd_t) error{Io}!void {
    const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags) != .SUCCESS) return error.Io;
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock)) != .SUCCESS) return error.Io;
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) return error.Io;
}
fn listen(address: Address, backlog: u31) error{ Io, Unsupported, AddressInUse, AddressUnavailable, Resources }!struct { socket: Socket, address: Address } {
    const flags: u32 = posix.SOCK.STREAM | if (builtin.os.tag == .linux) posix.SOCK.CLOEXEC else 0;
    const rc = posix.system.socket(std.Io.Threaded.posixAddressFamily(&address), flags, 0);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .AFNOSUPPORT, .PROTONOSUPPORT, .PROTOTYPE, .INVAL => return error.Unsupported,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.Resources,
        else => return error.Io,
    }
    const socket: Socket = .{ .fd = @intCast(rc) };
    errdefer socket.close();
    try nonblocking(socket.fd);
    const enabled: c_int = 1;
    if (posix.system.setsockopt(socket.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enabled, @sizeOf(c_int)) != 0) return error.Io;
    // SAFETY: address conversion or a successful socket call fills storage before use.
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var length = std.Io.Threaded.addressToPosix(&address, &storage);
    switch (posix.errno(posix.system.bind(socket.fd, &storage.any, length))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.Unsupported,
        .NOBUFS, .NOMEM => return error.Resources,
        else => return error.Io,
    }
    while (true) switch (posix.errno(posix.system.listen(socket.fd, backlog))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.Io,
    };
    if (posix.system.getsockname(socket.fd, &storage.any, &length) != 0) return error.Io;
    return .{ .socket = socket, .address = std.Io.Threaded.addressFromPosix(&storage) };
}
fn acceptSocket(listener: Listening) error{ Pending, Resources, Io }!Accepted {
    // SAFETY: address conversion or a successful socket call fills storage before use.
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    const rc = if (builtin.os.tag == .linux) posix.system.accept4(listener.socket.fd, &storage.any, &length, posix.SOCK.CLOEXEC) else posix.system.accept(listener.socket.fd, &storage.any, &length);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .INTR, .CONNABORTED => return error.Pending,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.Resources,
        else => return error.Io,
    }
    const socket: Socket = .{ .fd = @intCast(rc) };
    errdefer socket.close();
    try nonblocking(socket.fd);
    if (@hasDecl(posix.SO, "NOSIGPIPE")) {
        const enabled: c_int = 1;
        if (posix.system.setsockopt(socket.fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) return error.Io;
    }
    const peer = std.Io.Threaded.addressFromPosix(&storage);
    length = @sizeOf(std.Io.Threaded.PosixAddress);
    if (posix.system.getsockname(socket.fd, &storage.any, &length) != 0) return error.Io;
    return .{ .socket = socket, .service = listener.service, .local = std.Io.Threaded.addressFromPosix(&storage), .peer = peer };
}
pub const Extension = ecl.module(.{
    .linkage = .static,
    .name = "net.core",
    .doc = "TCP listeners and independently owned connections.",
    .instance = Service,
    .ports = .{ Listener, Connection },
    .words = .{ ecl.factory("listener", "Bind a TCP listener.", Listener), ecl.overload("local-address", "Read a listener or connection endpoint; request [].", .{ .{ Listener, .local_address }, .{ Connection, .local_address } }) },
});

const ListenCapacityFailure = ecl.CapacityFailure(struct {
    const Command = enum { key0, value0, key1, value1, reason_key, reason_value, dictionary, seal };
    const Construction = struct { diagnostic: ListenDiagnostic, command: Command };
    pub const State = union(enum) { parsing, issuing: Construction, advancing: Construction };
    pub fn init() State {
        return .parsing;
    }
    pub fn step(state: *State, context: *ecl.RejectedOpen) ecl.RejectionResult {
        const builder = context.errorData();
        switch (state.*) {
            .parsing => {
                const diagnostic: ListenDiagnostic = switch (parseInput(context)) {
                    .address => .{ .kind = .domain, .message = "host listener limit reached", .reason = "limit" },
                    .failure => |failure| failure,
                };
                if (diagnostic.reason == null) {
                    context.fail(diagnostic.kind, diagnostic.message);
                    return .completed;
                }
                state.* = .{ .issuing = .{ .diagnostic = diagnostic, .command = .key0 } };
            },
            .issuing => |construction| {
                switch (construction.command) {
                    .key0 => try builder.input(&.{0}),
                    .value0 => try builder.input(&.{1}),
                    .key1 => try builder.input(&.{2}),
                    .value1 => try builder.input(&.{3}),
                    .reason_key => try builder.symbol("reason"),
                    .reason_value => try builder.symbol(construction.diagnostic.reason.?),
                    .dictionary => try builder.dictionary(3),
                    .seal => try builder.seal(),
                }
                state.* = .{ .advancing = construction };
            },
            .advancing => |construction| {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                if (construction.command == .seal) {
                    context.fail(construction.diagnostic.kind, construction.diagnostic.message);
                    return .completed;
                }
                state.* = .{ .issuing = .{ .diagnostic = construction.diagnostic, .command = @enumFromInt(@intFromEnum(construction.command) + 1) } };
            },
        }
        return .yielded;
    }
    pub fn retire(_: *State, _: *ecl.RejectedOpen) bool {
        return true;
    }
});
