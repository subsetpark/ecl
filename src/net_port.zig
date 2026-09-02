//! Scope-owned TCP listeners behind opaque ECL port values.
//!
//! A `NetPolicy` names the address and port pairs a Session may bind once, at
//! construction. `NetOwner` copies it, keeps the live-listener quota, and is
//! the only factory for `ListenerCell`: a bound socket whose lifetime belongs
//! to the creating unit's task scope, never to the language value reference
//! count. Bind is four bounded syscalls on the worker (socket, bind, listen,
//! getsockname) and nothing here parks or spawns a thread; accept belongs to
//! a later serving word. Closing is one idempotent transition shared by the
//! `close` word and scope cancellation.

const std = @import("std");
const builtin = @import("builtin");
const external = @import("external.zig");
const heap = @import("heap.zig");
const scheduler_api = @import("scheduler.zig");
const value = @import("value.zig");

const Value = value.Value;
pub const IpAddress = std.Io.net.IpAddress;

/// One borrowed grant entry: an IP literal and a port. Port 0 admits only
/// ephemeral requests.
pub const Bind = struct {
    address: []const u8,
    port: u16,
};

pub const BindPolicy = union(enum) {
    exact: []const Bind,
    unrestricted,
};

pub const Limits = struct {
    max_live_listeners: usize = 16,
    kernel_backlog: u31 = 128,
};

/// Borrowed host policy. Every entry is parsed and copied during Session
/// construction; the strings are never consulted again.
pub const NetPolicy = struct {
    binds: BindPolicy,
    limits: Limits = .{},
};

pub const PolicyError = error{ OutOfMemory, InvalidPolicy };

/// Every way `listen` can fail, already mapped from the host error set at this
/// boundary so the module above branches on closed names.
/// `Unsupported` is a host refusal of a valid, authorized request (an address
/// family or protocol the running kernel lacks); an unsupported build target
/// is rejected earlier, by `NetOwner.init`, so no owner exists there.
pub const ListenError = error{
    OutOfMemory,
    Denied,
    LiveLimit,
    ScopeClosing,
    Unsupported,
    AddressInUse,
    AddressUnavailable,
    Resources,
    Cancelled,
    Io,
};

pub fn backendSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

/// Fold an IPv4-mapped IPv6 address into its IPv4 form so `::ffff:127.0.0.1`
/// and `127.0.0.1` are one grant.
pub fn normalize(address: IpAddress) IpAddress {
    return switch (address) {
        .ip4 => address,
        .ip6 => |ip6| IpAddress.fromIp6(ip6),
    };
}

/// Parse a literal (no DNS, no interface scope) and normalize it.
pub fn parseLiteral(text: []const u8, port: u16) error{InvalidAddress}!IpAddress {
    const parsed = IpAddress.parse(text, port) catch return error.InvalidAddress;
    return normalize(parsed);
}

const OwnedPolicy = struct {
    binds: union(enum) {
        exact: []IpAddress,
        unrestricted,
    },
    limits: Limits,

    fn init(allocator: std.mem.Allocator, policy: NetPolicy) PolicyError!OwnedPolicy {
        if (comptime !backendSupported()) return error.InvalidPolicy;
        if (policy.limits.max_live_listeners == 0 or policy.limits.kernel_backlog == 0)
            return error.InvalidPolicy;
        switch (policy.binds) {
            .unrestricted => return .{ .binds = .unrestricted, .limits = policy.limits },
            .exact => |binds| {
                const entries = try allocator.alloc(IpAddress, binds.len);
                errdefer allocator.free(entries);
                for (binds, entries, 0..) |bind, *entry, index| {
                    entry.* = parseLiteral(bind.address, bind.port) catch return error.InvalidPolicy;
                    for (entries[0..index]) |prior| {
                        if (prior.eql(entry)) return error.InvalidPolicy;
                    }
                }
                return .{ .binds = .{ .exact = entries }, .limits = policy.limits };
            },
        }
    }

    fn deinit(self: *OwnedPolicy, allocator: std.mem.Allocator) void {
        switch (self.binds) {
            .exact => |entries| allocator.free(entries),
            .unrestricted => {},
        }
        self.* = undefined;
    }

    /// Exact match on normalized family, bytes, and port: a port-0 entry
    /// admits only a port-0 request.
    fn allows(self: *const OwnedPolicy, address: IpAddress) bool {
        return switch (self.binds) {
            .unrestricted => true,
            .exact => |entries| for (entries) |entry| {
                if (entry.eql(&address)) break true;
            } else false,
        };
    }
};

/// Session-owned authority. Units never receive this owner; they receive the
/// opaque `external.NetAccess` and `listenFromUnit`.
pub const NetOwner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    policy: OwnedPolicy,
    live: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, policy: NetPolicy) PolicyError!NetOwner {
        return .{
            .allocator = allocator,
            .io = io,
            .policy = try OwnedPolicy.init(allocator, policy),
        };
    }

    pub fn deinit(self: *NetOwner) void {
        std.debug.assert(self.live.load(.acquire) == 0);
        self.policy.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn access(self: *NetOwner) *external.NetAccess {
        return @ptrCast(self);
    }

    fn reserveLive(self: *NetOwner) bool {
        var observed = self.live.load(.acquire);
        while (observed < self.policy.limits.max_live_listeners) {
            if (self.live.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual|
                observed = actual
            else
                return true;
        }
        return false;
    }

    fn releaseLive(self: *NetOwner) void {
        const old = self.live.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
    }

    /// Bind and listen, attach the socket to `scope`, then publish the port.
    /// `address` is the caller's parsed literal; it is normalized here.
    pub fn listen(
        self: *NetOwner,
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
        address: IpAddress,
    ) ListenError!Value {
        const normalized = normalize(address);
        if (!self.policy.allows(normalized)) return error.Denied;
        if (!self.reserveLive()) return error.LiveLimit;
        var reservation_owned = true;
        errdefer if (reservation_owned) self.releaseLive();

        var server = IpAddress.listen(&normalized, self.io, .{
            .kernel_backlog = self.policy.limits.kernel_backlog,
            .reuse_address = false,
        }) catch |err| return mapListenError(err);
        errdefer if (reservation_owned) server.deinit(self.io);

        const cell = try self.allocator.create(ListenerCell);
        cell.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .owner = self,
            .identity = self.next_identity.fetchAdd(1, .monotonic),
            .state = .{ .bound = .{ .server = server, .address = server.socket.address } },
        };
        // From here the cell owns the socket and the reservation; every
        // failure path closes through the one transition and drops the
        // initial reference.
        reservation_owned = false;
        errdefer {
            cell.close();
            cell.releaseRef();
        }

        const member = external.scopeMember(ListenerCell, cell);
        const membership = scheduler.attachExternal(scope, member) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return error.ScopeClosing,
        };
        cell.attach(membership);

        return heap.createPort(ListenerCell, self.allocator, cell.identity, cell) catch
            return error.OutOfMemory;
    }
};

fn mapListenError(err: IpAddress.ListenError) ListenError {
    return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AddressUnavailable => error.AddressUnavailable,
        error.NetworkDown,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => error.Resources,
        error.AddressFamilyUnsupported,
        error.ProtocolUnsupportedBySystem,
        error.ProtocolUnsupportedByAddressFamily,
        error.SocketModeUnsupported,
        error.OptionUnsupported,
        => error.Unsupported,
        error.Canceled => error.Cancelled,
        error.Unexpected => error.Io,
    };
}

/// One bound-or-closed socket. The reference count is shared by the port
/// value and the scope member; the socket and quota slot are released by the
/// first `close`, whoever calls it.
pub const ListenerCell = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *NetOwner,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    state: State,
    membership: ?external.ScopeMembership = null,
    /// Set when `close` ran before `attach` stored the membership token, so
    /// `attach` detaches at once instead of leaving the scope waiting.
    detach_on_attach: bool = false,

    const State = union(enum) {
        bound: struct {
            server: std.Io.net.Server,
            address: IpAddress,
        },
        /// Retains the address that was bound so a failure after closure can
        /// still name it.
        closed: IpAddress,
    };

    fn retainRef(self: *ListenerCell) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(usize));
    }

    fn releaseRef(self: *ListenerCell) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        std.debug.assert(self.state == .closed);
        std.debug.assert(self.membership == null);
        self.allocator.destroy(self);
    }

    pub fn releasePort(self: *ListenerCell) void {
        self.releaseRef();
    }

    pub fn retainExternalMember(self: *ListenerCell) void {
        self.retainRef();
    }

    pub fn releaseExternalMember(self: *ListenerCell) void {
        self.releaseRef();
    }

    pub fn cancelExternalMember(self: *ListenerCell) void {
        self.close();
    }

    fn attach(self: *ListenerCell, membership: external.ScopeMembership) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.detach_on_attach) {
            self.detach_on_attach = false;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            var owned = membership;
            owned.detach();
            return;
        }
        std.debug.assert(self.membership == null);
        self.membership = membership;
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Close the socket, release the quota slot, and detach from the scope.
    /// Idempotent: a closed cell stays closed and nothing runs twice.
    pub fn close(self: *ListenerCell) void {
        var membership: ?external.ScopeMembership = null;
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.state) {
            .bound => |bound| {
                var server = bound.server;
                server.deinit(self.io);
                self.state = .{ .closed = bound.address };
                self.owner.releaseLive();
                if (self.membership) |token| {
                    membership = token;
                    self.membership = null;
                } else {
                    self.detach_on_attach = true;
                }
            },
            .closed => {},
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (membership) |token| {
            var owned = token;
            owned.detach();
        }
    }

    /// The bound address, or null once closed.
    pub fn localAddress(self: *ListenerCell) ?IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.state) {
            .bound => |bound| bound.address,
            .closed => null,
        };
    }

    /// The address this listener bound, whether or not it is still bound.
    pub fn recordedAddress(self: *ListenerCell) IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.state) {
            .bound => |bound| bound.address,
            .closed => |address| address,
        };
    }
};

pub fn listenFromUnit(
    access_value: *external.NetAccess,
    scheduler_erased: *const anyopaque,
    scope_erased: *anyopaque,
    address: IpAddress,
) ListenError!Value {
    const runtime_scheduler: *const scheduler_api.WorkerScheduler = @ptrCast(@alignCast(scheduler_erased));
    const scope: *scheduler_api.TaskScope = @ptrCast(@alignCast(scope_erased));
    return ownerFromAccess(access_value).listen(runtime_scheduler, scope, address);
}

/// Typed projection of a port value; null for any other port kind or value.
pub fn fromValue(port: Value) ?*ListenerCell {
    if (port != .port) return null;
    return heap.portPayload(ListenerCell, port.port);
}

fn ownerFromAccess(access_value: *external.NetAccess) *NetOwner {
    return @ptrCast(@alignCast(access_value));
}

test "net policy rejects unparseable, duplicate, and zero-limit grants" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const invalid = [_]NetPolicy{
        .{ .binds = .{ .exact = &.{.{ .address = "localhost", .port = 0 }} } },
        .{ .binds = .{ .exact = &.{.{ .address = "fe80::1%lo0", .port = 0 }} } },
        .{ .binds = .{ .exact = &.{
            .{ .address = "127.0.0.1", .port = 0 },
            .{ .address = "::ffff:127.0.0.1", .port = 0 },
        } } },
        .{ .binds = .unrestricted, .limits = .{ .max_live_listeners = 0 } },
        .{ .binds = .unrestricted, .limits = .{ .kernel_backlog = 0 } },
    };
    for (invalid) |policy| {
        try std.testing.expectError(error.InvalidPolicy, NetOwner.init(allocator, io, policy));
    }
}

test "net policy admits exact normalized binds and treats port zero as ephemeral only" {
    var owner = try NetOwner.init(std.testing.allocator, std.testing.io, .{ .binds = .{ .exact = &.{
        .{ .address = "127.0.0.1", .port = 0 },
        .{ .address = "::1", .port = 4000 },
    } } });
    defer owner.deinit();
    try std.testing.expect(owner.policy.allows(try parseLiteral("127.0.0.1", 0)));
    try std.testing.expect(owner.policy.allows(try parseLiteral("::ffff:127.0.0.1", 0)));
    try std.testing.expect(!owner.policy.allows(try parseLiteral("127.0.0.1", 8080)));
    try std.testing.expect(!owner.policy.allows(try parseLiteral("::1", 0)));
    try std.testing.expect(owner.policy.allows(try parseLiteral("::1", 4000)));
    try std.testing.expect(!owner.policy.allows(try parseLiteral("127.0.0.2", 0)));
    var unrestricted = try NetOwner.init(std.testing.allocator, std.testing.io, .{ .binds = .unrestricted });
    defer unrestricted.deinit();
    try std.testing.expect(unrestricted.policy.allows(try parseLiteral("10.0.0.1", 1)));
}
