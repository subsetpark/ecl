//! Scope-owned TCP listeners and connections behind opaque ECL port values.
//!
//! A `NetPolicy` names the address and port pairs a Session may bind once, at
//! construction. `NetOwner` copies it, keeps the live-listener and
//! live-connection quotas, and is the only factory for `ListenerCell`: a bound
//! socket whose lifetime belongs to the creating unit's task scope, never to
//! the language value reference count. Bind is four bounded syscalls on the
//! worker (socket, bind, listen, getsockname). Accepting starts one detached
//! acceptor thread per listener on the first `accept`; it waits in `poll` on
//! the listening socket and a wake pipe and takes a connection from the kernel
//! backlog only while an ECL `accept` is outstanding. Each accepted socket is
//! a `ConnectionCell` owned by the accepting unit's scope, with bounded
//! receive and send rings serviced by a reader and a writer thread, exactly
//! the process-port controller model. Closing is one idempotent transition
//! shared by the `close` word and scope cancellation.

const std = @import("std");
const builtin = @import("builtin");
const external = @import("external.zig");
const heap = @import("heap.zig");
const scheduler_api = @import("scheduler.zig");
const value = @import("value.zig");

const posix = std.posix;
const Value = value.Value;
pub const IpAddress = std.Io.net.IpAddress;

fn blockingIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

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
    max_live_connections: usize = 64,
    receive_capacity: usize = 64 * 1024,
    send_capacity: usize = 64 * 1024,
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

/// Every way `beginAccept` can fail before anything parks.
pub const AcceptError = error{ OutOfMemory, Closed, LiveLimit, Io };

pub const AcceptProgress = union(enum) {
    pending,
    accepted: Value,
    closed,
    scope_closing,
    resources,
    io,
};

pub const ReadProgress = union(enum) {
    pending,
    data: usize,
    eof,
    closed,
    reset,
    io,
};

pub const WriteProgress = union(enum) {
    pending,
    written: usize,
    closed,
    reset,
    io,
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
        if (policy.limits.max_live_listeners == 0 or policy.limits.kernel_backlog == 0 or
            policy.limits.max_live_connections == 0 or policy.limits.receive_capacity == 0 or
            policy.limits.send_capacity == 0)
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
    live_connections: std.atomic.Value(usize) = .init(0),
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
        std.debug.assert(self.live_connections.load(.acquire) == 0);
        self.policy.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn access(self: *NetOwner) *external.NetAccess {
        return @ptrCast(self);
    }

    fn reserveCounter(counter: *std.atomic.Value(usize), limit: usize) bool {
        var observed = counter.load(.acquire);
        while (observed < limit) {
            if (counter.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual|
                observed = actual
            else
                return true;
        }
        return false;
    }

    fn releaseCounter(counter: *std.atomic.Value(usize)) void {
        const old = counter.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
    }

    fn reserveLive(self: *NetOwner) bool {
        return reserveCounter(&self.live, self.policy.limits.max_live_listeners);
    }

    fn releaseLive(self: *NetOwner) void {
        releaseCounter(&self.live);
    }

    fn reserveConnection(self: *NetOwner) bool {
        return reserveCounter(&self.live_connections, self.policy.limits.max_live_connections);
    }

    fn releaseConnection(self: *NetOwner) void {
        releaseCounter(&self.live_connections);
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

/// Bounded byte queue shared by the connection's rings. Identical in contract
/// to the process port's ring; duplicated rather than exported so the two
/// controllers stay independently reviewable.
const Ring = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,

    fn free(self: *const Ring) usize {
        return self.bytes.len - self.len;
    }

    fn push(self: *Ring, source: []const u8) void {
        std.debug.assert(source.len <= self.free());
        const tail = (self.head + self.len) % self.bytes.len;
        const first = @min(source.len, self.bytes.len - tail);
        @memcpy(self.bytes[tail..][0..first], source[0..first]);
        @memcpy(self.bytes[0 .. source.len - first], source[first..]);
        self.len += source.len;
    }

    fn pop(self: *Ring, destination: []u8) usize {
        const count = @min(destination.len, self.len);
        const first = @min(count, self.bytes.len - self.head);
        @memcpy(destination[0..first], self.bytes[self.head..][0..first]);
        @memcpy(destination[first..count], self.bytes[0 .. count - first]);
        self.head = (self.head + count) % self.bytes.len;
        self.len -= count;
        return count;
    }

    fn discard(self: *Ring) void {
        self.head = 0;
        self.len = 0;
    }
};

/// A keyed list of registered readiness waits over one cell type. The cell
/// supplies `mutex`, `waits`, `retainRef`, `releaseRef`, `readyLocked(key)`,
/// and `wakeReasonLocked(key)`. Targets stay retained until their
/// registration is consumed, so waking under the cell lock closes the only
/// cancellation/use-after-free race.
fn WaitList(comptime Cell: type) type {
    return struct {
        const Self = @This();

        pub const Wait = struct {
            allocator: std.mem.Allocator,
            cell: *Cell,
            key: u64,
            target: external.WakeTarget,
            previous: ?*Wait = null,
            next: ?*Wait = null,
            linked: std.atomic.Value(bool) = .init(false),

            pub fn cancelReadiness(self: *Wait) void {
                const cell = self.cell;
                if (self.linked.load(.acquire)) {
                    std.Io.Threaded.mutexLock(&cell.mutex);
                    if (self.linked.load(.monotonic)) cell.waits.unlinkLocked(self);
                    std.Io.Threaded.mutexUnlock(&cell.mutex);
                }
                self.target.release();
                cell.releaseRef();
                self.allocator.destroy(self);
            }
        };

        first: ?*Wait = null,
        last: ?*Wait = null,

        fn register(
            cell: *Cell,
            key: u64,
            target: external.WakeTarget,
        ) external.RegisterError!external.RegisterResult {
            const wait = try cell.allocator.create(Wait);
            errdefer cell.allocator.destroy(wait);
            wait.* = .{
                .allocator = cell.allocator,
                .cell = cell,
                .key = key,
                .target = target,
            };
            std.Io.Threaded.mutexLock(&cell.mutex);
            if (cell.readyLocked(key)) {
                const reason = cell.wakeReasonLocked(key);
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                cell.allocator.destroy(wait);
                return .{ .ready = reason };
            }
            target.retain();
            cell.retainRef();
            cell.waits.linkLocked(wait);
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            return .{ .registered = external.readinessRegistration(Wait, wait) };
        }

        fn linkLocked(self: *Self, wait: *Wait) void {
            std.debug.assert(!wait.linked.load(.monotonic));
            if (self.last) |last| {
                last.next = wait;
                wait.previous = last;
            } else self.first = wait;
            self.last = wait;
            wait.linked.store(true, .release);
        }

        fn unlinkLocked(self: *Self, wait: *Wait) void {
            std.debug.assert(wait.linked.load(.monotonic));
            if (wait.previous) |previous| previous.next = wait.next else self.first = wait.next;
            if (wait.next) |next| next.previous = wait.previous else self.last = wait.previous;
            wait.previous = null;
            wait.next = null;
            wait.linked.store(false, .release);
        }

        /// Called with the cell lock held.
        fn notifyLocked(self: *Self, cell: *Cell) void {
            var wait = self.first;
            while (wait) |candidate| {
                const next = candidate.next;
                if (cell.readyLocked(candidate.key)) {
                    self.unlinkLocked(candidate);
                    candidate.target.wake(cell.wakeReasonLocked(candidate.key));
                }
                wait = next;
            }
        }
    };
}

/// One outstanding `accept`. The word-side driver owns the slot between
/// `beginAccept` and `endAccept`; the acceptor thread fills the first unfilled
/// slot in FIFO order, so the acceptor never holds more sockets than there are
/// outstanding accepts.
pub const AcceptSlot = struct {
    previous: ?*AcceptSlot = null,
    next: ?*AcceptSlot = null,
    linked: bool = true,
    reservation_held: bool = true,
    outcome: union(enum) {
        unfilled,
        socket: struct { fd: posix.fd_t, peer: IpAddress },
        taken,
        resources,
        io,
        closed,
    } = .unfilled,
};

/// One bound-or-closed socket. The reference count is shared by the port
/// value, the scope member, registered waits, and the acceptor thread; the
/// socket and quota slot are released by the first `close`, whoever calls it.
pub const ListenerCell = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *NetOwner,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    state: State,
    membership: ?external.ScopeMembership = null,
    /// Set when `close` ran before `attach` stored the membership token, so
    /// `attach` detaches at once instead of leaving the scope waiting.
    detach_on_attach: bool = false,
    waits: WaitList(ListenerCell) = .{},
    slots_first: ?*AcceptSlot = null,
    slots_last: ?*AcceptSlot = null,
    demand: usize = 0,
    acceptor: Acceptor = .{},

    const State = union(enum) {
        bound: struct {
            server: std.Io.net.Server,
            address: IpAddress,
        },
        /// Retains the address that was bound so a failure after closure can
        /// still name it.
        closed: IpAddress,
    };

    const Acceptor = struct {
        running: bool = false,
        /// Set by `close` so a running acceptor exits after its next wake.
        stop: bool = false,
        wake: ?[2]posix.fd_t = null,
    };

    const Waits = WaitList(ListenerCell);

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
        std.debug.assert(self.slots_first == null and self.waits.first == null);
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

    pub fn retainReadiness(self: *ListenerCell) void {
        self.retainRef();
    }

    pub fn releaseReadiness(self: *ListenerCell) void {
        self.releaseRef();
    }

    pub fn registerReadiness(
        self: *ListenerCell,
        key: u64,
        target: external.WakeTarget,
    ) external.RegisterError!external.RegisterResult {
        return Waits.register(self, key, target);
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
    /// Idempotent: a closed cell stays closed and nothing runs twice. When an
    /// acceptor thread is running, wake it and wait for it to leave `poll`
    /// first; that wait is bounded by one thread returning from a `poll` the
    /// wake byte has already satisfied, and it keeps close synchronous so the
    /// address may be bound again the moment this returns.
    pub fn close(self: *ListenerCell) void {
        var membership: ?external.ScopeMembership = null;
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.state) {
            .bound => |bound| {
                if (self.acceptor.running) {
                    self.acceptor.stop = true;
                    if (self.acceptor.wake) |wake| {
                        const byte = [_]u8{0};
                        _ = posix.system.write(wake[1], &byte, 1);
                    }
                    self.changed.broadcast(blockingIo());
                    while (self.acceptor.running)
                        self.changed.waitUncancelable(blockingIo(), &self.mutex);
                }
                if (self.acceptor.wake) |wake| {
                    std.Io.Threaded.closeFd(wake[0]);
                    std.Io.Threaded.closeFd(wake[1]);
                    self.acceptor.wake = null;
                }
                var server = bound.server;
                server.deinit(self.io);
                self.state = .{ .closed = bound.address };
                self.owner.releaseLive();
                var slot = self.slots_first;
                while (slot) |current| : (slot = current.next) {
                    if (current.outcome == .unfilled) current.outcome = .closed;
                }
                self.waits.notifyLocked(self);
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

    fn readyLocked(self: *ListenerCell, key: u64) bool {
        _ = self;
        const slot: *const AcceptSlot = @ptrFromInt(key);
        return slot.outcome != .unfilled;
    }

    fn wakeReasonLocked(self: *ListenerCell, key: u64) external.Wake {
        _ = self;
        _ = key;
        return .ready;
    }

    /// Reserve one live-connection slot, link an accept slot, and start the
    /// acceptor thread if it is not running. Fails before anything parks.
    pub fn beginAccept(self: *ListenerCell) AcceptError!*AcceptSlot {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const bound = switch (self.state) {
            .bound => |*bound| bound,
            .closed => return error.Closed,
        };
        if (!self.owner.reserveConnection()) return error.LiveLimit;
        errdefer self.owner.releaseConnection();
        const slot = try self.allocator.create(AcceptSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{};
        if (!self.acceptor.running) {
            if (self.acceptor.wake == null) {
                self.acceptor.wake = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.Io;
            }
            setNonBlocking(bound.server.socket.handle) catch return error.Io;
            self.retainRef();
            self.acceptor.running = true;
            self.acceptor.stop = false;
            const thread = std.Thread.spawn(.{}, acceptorThreadMain, .{self}) catch {
                self.acceptor.running = false;
                self.releaseRef();
                return error.Io;
            };
            thread.detach();
        }
        if (self.slots_last) |last| {
            last.next = slot;
            slot.previous = last;
        } else self.slots_first = slot;
        self.slots_last = slot;
        self.demand += 1;
        self.changed.broadcast(blockingIo());
        return slot;
    }

    pub fn acceptSource(self: *ListenerCell, slot: *AcceptSlot) external.ReadinessSource {
        return external.readinessSource(ListenerCell, self, @intFromPtr(slot));
    }

    /// Take the socket filled into this slot, build the connection cell
    /// attached to `scope`, and publish its port. A filled slot yields a
    /// connection even after the listener closed: the accepted socket is
    /// independent of the listening one.
    pub fn pollAccept(
        self: *ListenerCell,
        slot: *AcceptSlot,
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
    ) error{OutOfMemory}!AcceptProgress {
        std.Io.Threaded.mutexLock(&self.mutex);
        const accepted, const local = switch (slot.outcome) {
            .unfilled => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .pending;
            },
            .closed => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .closed;
            },
            .resources => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .resources;
            },
            .io, .taken => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .io;
            },
            .socket => |socket| taken: {
                slot.outcome = .taken;
                std.debug.assert(slot.reservation_held);
                slot.reservation_held = false;
                break :taken .{ socket, self.recordedAddressLocked() };
            },
        };
        std.Io.Threaded.mutexUnlock(&self.mutex);
        // From here the reservation and the descriptor belong to the
        // connection being built; every failure releases both exactly once.
        return ConnectionCell.publish(self.owner, accepted.fd, accepted.peer, local, scheduler, scope);
    }

    fn recordedAddressLocked(self: *ListenerCell) IpAddress {
        return switch (self.state) {
            .bound => |bound| bound.address,
            .closed => |address| address,
        };
    }

    /// Release the slot and its reservation; a filled, untaken socket is
    /// closed here, which is how a cancelled accept never leaks a connection.
    pub fn endAccept(self: *ListenerCell, slot: *AcceptSlot) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(slot.linked);
        if (slot.previous) |previous| previous.next = slot.next else self.slots_first = slot.next;
        if (slot.next) |next| next.previous = slot.previous else self.slots_last = slot.previous;
        slot.linked = false;
        std.debug.assert(self.demand != 0);
        self.demand -= 1;
        const orphan: ?posix.fd_t = switch (slot.outcome) {
            .socket => |socket| socket.fd,
            else => null,
        };
        if (slot.reservation_held) self.owner.releaseConnection();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (orphan) |fd| std.Io.Threaded.closeFd(fd);
        self.allocator.destroy(slot);
    }

    fn firstUnfilledLocked(self: *ListenerCell) ?*AcceptSlot {
        var slot = self.slots_first;
        while (slot) |current| : (slot = current.next) {
            if (current.outcome == .unfilled) return current;
        }
        return null;
    }

    fn acceptorMain(self: *ListenerCell) void {
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (!self.acceptor.stop and self.state == .bound and self.firstUnfilledLocked() == null)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            if (self.acceptor.stop or self.state != .bound) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break;
            }
            const listen_fd = self.state.bound.server.socket.handle;
            const wake_fd = self.acceptor.wake.?[0];
            std.Io.Threaded.mutexUnlock(&self.mutex);

            var fds = [_]posix.pollfd{
                .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch {
                self.fillFirstUnfilled(.io);
                break;
            };
            if (fds[1].revents != 0) break;
            if (fds[0].revents == 0) continue;

            // SAFETY: accept writes the peer address into `storage` before it is
            // read, and nothing reads it on any failure path.
            var storage: std.Io.Threaded.PosixAddress = undefined;
            var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
            const rc = if (builtin.os.tag == .linux)
                posix.system.accept4(listen_fd, &storage.any, &length, posix.SOCK.CLOEXEC)
            else
                posix.system.accept(listen_fd, &storage.any, &length);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const fd: posix.fd_t = @intCast(rc);
                    if (builtin.os.tag != .linux) setCloexec(fd) catch {
                        std.Io.Threaded.closeFd(fd);
                        self.fillFirstUnfilled(.io);
                        continue;
                    };
                    setBlocking(fd) catch {
                        std.Io.Threaded.closeFd(fd);
                        self.fillFirstUnfilled(.io);
                        continue;
                    };
                    const peer = std.Io.Threaded.addressFromPosix(&storage);
                    std.Io.Threaded.mutexLock(&self.mutex);
                    if (self.firstUnfilledLocked()) |slot| {
                        slot.outcome = .{ .socket = .{ .fd = fd, .peer = peer } };
                        self.waits.notifyLocked(self);
                        std.Io.Threaded.mutexUnlock(&self.mutex);
                    } else {
                        // Every acceptor was cancelled between poll and
                        // accept; the connection has no owner.
                        std.Io.Threaded.mutexUnlock(&self.mutex);
                        std.Io.Threaded.closeFd(fd);
                    }
                },
                .AGAIN, .INTR, .CONNABORTED => continue,
                .MFILE, .NFILE, .NOBUFS, .NOMEM => self.fillFirstUnfilled(.resources),
                else => self.fillFirstUnfilled(.io),
            }
        }
        std.Io.Threaded.mutexLock(&self.mutex);
        self.acceptor.running = false;
        self.changed.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.releaseRef();
    }

    fn fillFirstUnfilled(self: *ListenerCell, failure: enum { resources, io }) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const slot = self.firstUnfilledLocked() orelse return;
        slot.outcome = switch (failure) {
            .resources => .resources,
            .io => .io,
        };
        self.waits.notifyLocked(self);
    }
};

fn acceptorThreadMain(cell: *ListenerCell) void {
    cell.acceptorMain();
}

fn setNonBlocking(fd: posix.fd_t) error{Io}!void {
    return setBlockingMode(fd, .non_blocking);
}

/// BSD kernels hand an accepted socket the listening socket's O_NONBLOCK, and
/// the controller threads rely on blocking reads and writes, so every accepted
/// descriptor is switched back explicitly.
fn setBlocking(fd: posix.fd_t) error{Io}!void {
    return setBlockingMode(fd, .blocking);
}

fn setBlockingMode(fd: posix.fd_t, mode: enum { blocking, non_blocking }) error{Io}!void {
    const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags) != .SUCCESS) return error.Io;
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    const current: u32 = @intCast(flags);
    const updated: usize = switch (mode) {
        .blocking => current & ~nonblock,
        .non_blocking => current | nonblock,
    };
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, updated)) != .SUCCESS) return error.Io;
}

fn setCloexec(fd: posix.fd_t) error{Io}!void {
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS)
        return error.Io;
}

const WriteNode = struct {
    cell: *ConnectionCell,
    previous: ?*WriteNode = null,
    next: ?*WriteNode = null,
    linked: bool = true,
    active: bool = false,
};

pub const WritePermit = opaque {};

fn writeNode(permit: *WritePermit) *WriteNode {
    return @ptrCast(@alignCast(permit));
}

fn writePermit(node: *WriteNode) *WritePermit {
    return @ptrCast(@alignCast(node));
}

const readiness_read: u64 = 1;

/// One accepted TCP connection. Phases are exhaustive: `open` accepts reads
/// and writes; `closing` refuses new writes while the writer drains queued
/// bytes and then shuts the socket down; `closed` is published by the final
/// controller lease after the descriptor is closed and the quota released.
pub const ConnectionCell = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *NetOwner,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    phase: Phase = .open,
    socket: posix.fd_t,
    peer: IpAddress,
    local: IpAddress,
    receive: Ring,
    send: Ring,
    reader_active: bool = false,
    reader_done: bool = false,
    writer_done: bool = false,
    /// Set by `close` and `abort`: the program or its scope ended the
    /// connection, so later reads and writes report `closed` rather than
    /// whatever the peer did afterwards.
    closed_locally: bool = false,
    discard_receive: bool = false,
    peer_reset: bool = false,
    io_failed: bool = false,
    shutdown_issued: bool = false,
    write_first: ?*WriteNode = null,
    write_last: ?*WriteNode = null,
    waits: WaitList(ConnectionCell) = .{},
    leases: usize = 0,
    membership: ?external.ScopeMembership = null,

    const Phase = enum { open, closing, closed };
    const Waits = WaitList(ConnectionCell);

    /// Build the cell around an accepted descriptor, start both controller
    /// threads, attach to the accepting scope, and publish the port. Owns the
    /// descriptor and the caller's connection reservation on every path.
    fn publish(
        owner: *NetOwner,
        fd: posix.fd_t,
        peer: IpAddress,
        local: IpAddress,
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
    ) error{OutOfMemory}!AcceptProgress {
        const cell = create(owner, fd, peer, local) catch |err| {
            std.Io.Threaded.closeFd(fd);
            owner.releaseConnection();
            return err;
        };
        // The reader lease is taken before the thread exists so a spawn
        // failure has nothing to unwind but the lease itself.
        if (!cell.startThread(readerThreadMain)) {
            cell.retireWithoutThreads();
            return .resources;
        }
        if (!cell.startThread(writerThreadMain)) {
            cell.abort();
            cell.releaseRef();
            return .resources;
        }
        const member = external.scopeMember(ConnectionCell, cell);
        const membership = scheduler.attachExternal(scope, member) catch |err| {
            cell.abort();
            cell.releaseRef();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ScopeClosing => .scope_closing,
            };
        };
        std.Io.Threaded.mutexLock(&cell.mutex);
        cell.membership = membership;
        const already_final = cell.leases == 0;
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        if (already_final) cell.detachMembershipNow();
        const port = heap.createPort(ConnectionCell, owner.allocator, cell.identity, cell) catch {
            cell.abort();
            cell.releaseRef();
            return error.OutOfMemory;
        };
        return .{ .accepted = port };
    }

    fn create(owner: *NetOwner, fd: posix.fd_t, peer: IpAddress, local: IpAddress) error{OutOfMemory}!*ConnectionCell {
        const cell = try owner.allocator.create(ConnectionCell);
        errdefer owner.allocator.destroy(cell);
        const receive = try owner.allocator.alloc(u8, owner.policy.limits.receive_capacity);
        errdefer owner.allocator.free(receive);
        const send = try owner.allocator.alloc(u8, owner.policy.limits.send_capacity);
        cell.* = .{
            .allocator = owner.allocator,
            .io = owner.io,
            .owner = owner,
            .identity = owner.next_identity.fetchAdd(1, .monotonic),
            .socket = fd,
            .peer = peer,
            .local = local,
            .receive = .{ .bytes = receive },
            .send = .{ .bytes = send },
        };
        return cell;
    }

    /// Reclaim a cell no thread ever ran: close the descriptor, release the
    /// reservation, and drop the initial reference.
    fn retireWithoutThreads(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(self.leases == 0 and self.phase == .open);
        std.Io.Threaded.closeFd(self.socket);
        self.owner.releaseConnection();
        self.phase = .closed;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.releaseRef();
    }

    fn startThread(self: *ConnectionCell, comptime function: anytype) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        self.leases += 1;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.retainRef();
        const thread = std.Thread.spawn(.{}, function, .{self}) catch {
            std.Io.Threaded.mutexLock(&self.mutex);
            self.leases -= 1;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            self.releaseRef();
            return false;
        };
        thread.detach();
        return true;
    }

    fn retainRef(self: *ConnectionCell) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(usize));
    }

    fn releaseRef(self: *ConnectionCell) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        std.debug.assert(self.phase == .closed);
        std.debug.assert(self.membership == null);
        std.debug.assert(self.waits.first == null and self.write_first == null);
        self.allocator.free(self.receive.bytes);
        self.allocator.free(self.send.bytes);
        self.allocator.destroy(self);
    }

    pub fn releasePort(self: *ConnectionCell) void {
        self.releaseRef();
    }

    pub fn retainExternalMember(self: *ConnectionCell) void {
        self.retainRef();
    }

    pub fn releaseExternalMember(self: *ConnectionCell) void {
        self.releaseRef();
    }

    /// Scope closure: discard queued output, shut the socket down now so
    /// both threads return, and let the final lease publish `closed`.
    pub fn cancelExternalMember(self: *ConnectionCell) void {
        self.abort();
    }

    pub fn retainReadiness(self: *ConnectionCell) void {
        self.retainRef();
    }

    pub fn releaseReadiness(self: *ConnectionCell) void {
        self.releaseRef();
    }

    pub fn registerReadiness(
        self: *ConnectionCell,
        key: u64,
        target: external.WakeTarget,
    ) external.RegisterError!external.RegisterResult {
        return Waits.register(self, key, target);
    }

    pub fn beginRead(self: *ConnectionCell) error{ReaderActive}!void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.reader_active) return error.ReaderActive;
        self.reader_active = true;
    }

    pub fn endRead(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        self.reader_active = false;
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    pub fn readCapacity(self: *const ConnectionCell) usize {
        return self.receive.bytes.len;
    }

    pub fn read(self: *ConnectionCell, destination: []u8) ReadProgress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.receive.len != 0) {
            const count = self.receive.pop(destination);
            self.changed.broadcast(blockingIo());
            return .{ .data = count };
        }
        if (self.closed_locally) return .closed;
        if (self.peer_reset) return .reset;
        if (self.io_failed) return .io;
        if (self.reader_done) return .eof;
        if (self.phase != .open) return .closed;
        return .pending;
    }

    pub fn readSource(self: *ConnectionCell) external.ReadinessSource {
        return external.readinessSource(ConnectionCell, self, readiness_read);
    }

    pub fn beginWrite(self: *ConnectionCell) error{OutOfMemory}!*WritePermit {
        const node = try self.allocator.create(WriteNode);
        node.* = .{ .cell = self };
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.write_last) |last| {
            last.next = node;
            node.previous = last;
        } else {
            self.write_first = node;
            node.active = true;
        }
        self.write_last = node;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        return writePermit(node);
    }

    pub fn write(self: *ConnectionCell, permit: *WritePermit, bytes: []const u8) WriteProgress {
        const node = writeNode(permit);
        std.debug.assert(node.cell == self and node.linked);
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.closed_locally) return .closed;
        if (self.peer_reset) return .reset;
        if (self.io_failed) return .io;
        if (self.phase != .open) return .closed;
        if (!node.active or self.send.free() == 0) return .pending;
        const count = @min(bytes.len, self.send.free());
        self.send.push(bytes[0..count]);
        self.changed.broadcast(blockingIo());
        return .{ .written = count };
    }

    pub fn writeSource(self: *ConnectionCell, permit: *WritePermit) external.ReadinessSource {
        return external.readinessSource(ConnectionCell, self, @intFromPtr(writeNode(permit)));
    }

    pub fn finishWrite(self: *ConnectionCell, permit: *WritePermit) void {
        self.retireWrite(writeNode(permit));
    }

    pub fn abandonWrite(self: *ConnectionCell, permit: *WritePermit) void {
        self.retireWrite(writeNode(permit));
    }

    fn retireWrite(self: *ConnectionCell, node: *WriteNode) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (node.linked) {
            const was_active = node.active;
            if (node.previous) |previous| previous.next = node.next else self.write_first = node.next;
            if (node.next) |next| {
                next.previous = node.previous;
                if (was_active) next.active = true;
            } else self.write_last = node.previous;
            node.linked = false;
            node.previous = null;
            node.next = null;
            self.waits.notifyLocked(self);
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.allocator.destroy(node);
    }

    /// Graceful close: refuse new writes, drain queued bytes, then shut the
    /// socket down. Idempotent. Queued input is discarded because no read can
    /// observe it after this transition.
    pub fn close(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.phase == .open) {
            self.phase = .closing;
            self.closed_locally = true;
            self.discard_receive = true;
            self.receive.discard();
            // With no writer left to drain the ring, nothing else would ever
            // shut the socket down and release a blocked reader.
            if (self.writer_done) self.shutdownLocked();
            self.changed.broadcast(blockingIo());
            self.waits.notifyLocked(self);
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn abort(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.phase != .closed) {
            if (self.phase == .open) self.phase = .closing;
            self.closed_locally = true;
            self.discard_receive = true;
            self.receive.discard();
            self.send.discard();
            self.shutdownLocked();
            self.changed.broadcast(blockingIo());
            self.waits.notifyLocked(self);
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn shutdownLocked(self: *ConnectionCell) void {
        if (self.shutdown_issued or self.phase == .closed) return;
        self.shutdown_issued = true;
        _ = posix.system.shutdown(self.socket, posix.SHUT.RDWR);
    }

    pub fn peerAddress(self: *ConnectionCell) ?IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return if (self.closed_locally) null else self.peer;
    }

    pub fn localAddress(self: *ConnectionCell) ?IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return if (self.closed_locally) null else self.local;
    }

    /// The peer this connection was accepted from, open or closed.
    pub fn recordedPeer(self: *ConnectionCell) IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.peer;
    }

    fn readyLocked(self: *ConnectionCell, key: u64) bool {
        if (key == readiness_read)
            return self.receive.len != 0 or self.reader_done or self.peer_reset or
                self.io_failed or self.phase != .open;
        const node: *const WriteNode = @ptrFromInt(key);
        return !node.linked or (node.active and self.send.free() != 0) or
            self.phase != .open or self.peer_reset or self.io_failed;
    }

    fn wakeReasonLocked(self: *ConnectionCell, key: u64) external.Wake {
        _ = key;
        return if (self.io_failed) .io else .ready;
    }

    fn noteFailureLocked(self: *ConnectionCell, err: anyerror) void {
        switch (err) {
            error.ConnectionResetByPeer, error.SocketUnconnected, error.ConnectionRefused => self.peer_reset = true,
            else => self.io_failed = true,
        }
    }

    fn readerMain(self: *ConnectionCell) void {
        var block: [4096]u8 = undefined;
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (self.receive.free() == 0 and !self.discard_receive)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            const discarding = self.discard_receive;
            const capacity = if (discarding) block.len else @min(block.len, self.receive.free());
            std.Io.Threaded.mutexUnlock(&self.mutex);
            var chunks = [_][]u8{block[0..capacity]};
            const count = self.io.vtable.netRead(self.io.userdata, self.socket, &chunks) catch |err| {
                std.Io.Threaded.mutexLock(&self.mutex);
                self.noteFailureLocked(err);
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break;
            };
            if (count == 0) break;
            std.Io.Threaded.mutexLock(&self.mutex);
            if (!self.discard_receive) self.receive.push(block[0..count]);
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
        }
        std.Io.Threaded.mutexLock(&self.mutex);
        self.reader_done = true;
        self.changed.broadcast(blockingIo());
        self.waits.notifyLocked(self);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.releaseLease();
    }

    fn writerMain(self: *ConnectionCell) void {
        var block: [4096]u8 = undefined;
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (self.send.len == 0 and self.phase == .open and !self.peer_reset and !self.io_failed)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            if (self.send.len == 0 or self.peer_reset or self.io_failed) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break;
            }
            const count = self.send.pop(&block);
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            var written: usize = 0;
            const failed = while (written != count) {
                const empty: []const u8 = &.{};
                written += self.io.vtable.netWrite(self.io.userdata, self.socket, block[written..count], &.{empty}, 0) catch |err| {
                    std.Io.Threaded.mutexLock(&self.mutex);
                    self.noteFailureLocked(err);
                    self.send.discard();
                    self.waits.notifyLocked(self);
                    std.Io.Threaded.mutexUnlock(&self.mutex);
                    break true;
                };
            } else false;
            if (failed) break;
        }
        std.Io.Threaded.mutexLock(&self.mutex);
        // Draining finished (or can never finish): shut the socket down so
        // the reader observes EOF and the peer sees the close.
        if (self.phase != .open) self.shutdownLocked();
        self.writer_done = true;
        self.changed.broadcast(blockingIo());
        self.waits.notifyLocked(self);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.releaseLease();
    }

    /// Drop one controller lease. The final lease closes the descriptor,
    /// releases the connection reservation, publishes `closed`, and detaches
    /// scope membership, in that order, so scope quiescence cannot overtake
    /// either thread.
    fn releaseLease(self: *ConnectionCell) void {
        var membership: ?external.ScopeMembership = null;
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(self.leases != 0);
        self.leases -= 1;
        const final = self.leases == 0;
        if (final) {
            std.Io.Threaded.closeFd(self.socket);
            self.owner.releaseConnection();
            self.phase = .closed;
            self.waits.notifyLocked(self);
            membership = self.membership;
            self.membership = null;
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (membership) |token| {
            var owned = token;
            owned.detach();
        }
        self.releaseRef();
    }

    /// Both threads finished before `publish` stored the membership token;
    /// detach it now so the scope never waits on a cell that is already closed.
    fn detachMembershipNow(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        const membership = self.membership;
        self.membership = null;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (membership) |token| {
            var owned = token;
            owned.detach();
        }
    }
};

fn readerThreadMain(cell: *ConnectionCell) void {
    cell.readerMain();
}

fn writerThreadMain(cell: *ConnectionCell) void {
    cell.writerMain();
}

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

/// `ListenerCell.pollAccept` for callers holding the unit's type-erased
/// scheduler and scope pointers.
pub fn pollAcceptFromUnit(
    cell: *ListenerCell,
    slot: *AcceptSlot,
    scheduler_erased: *const anyopaque,
    scope_erased: *anyopaque,
) error{OutOfMemory}!AcceptProgress {
    const runtime_scheduler: *const scheduler_api.WorkerScheduler = @ptrCast(@alignCast(scheduler_erased));
    const scope: *scheduler_api.TaskScope = @ptrCast(@alignCast(scope_erased));
    return cell.pollAccept(slot, runtime_scheduler, scope);
}

/// Typed projection of a port value; null for any other port kind or value.
pub fn fromValue(port: Value) ?*ListenerCell {
    if (port != .port) return null;
    return heap.portPayload(ListenerCell, port.port);
}

/// Typed projection of a connection port; null for a listener, a process
/// port, or any other value.
pub fn connectionFromValue(port: Value) ?*ConnectionCell {
    if (port != .port) return null;
    return heap.portPayload(ConnectionCell, port.port);
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
        .{ .binds = .unrestricted, .limits = .{ .max_live_connections = 0 } },
        .{ .binds = .unrestricted, .limits = .{ .receive_capacity = 0 } },
        .{ .binds = .unrestricted, .limits = .{ .send_capacity = 0 } },
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

/// A wake target for the unit tests: one event set on wake.
const TestTarget = struct {
    event: std.Io.Event = .unset,
    refs: std.atomic.Value(usize) = .init(0),

    pub fn retainExternalWake(self: *TestTarget) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseExternalWake(self: *TestTarget) void {
        _ = self.refs.fetchSub(1, .release);
    }
    pub fn wakeExternal(self: *TestTarget, _: external.Wake) void {
        self.event.set(std.testing.io);
    }
};

fn awaitSource(source_value: external.ReadinessSource, target: *TestTarget) !void {
    var source = source_value;
    defer source.deinit();
    switch (try source.register(external.wakeTarget(TestTarget, target))) {
        .ready => {},
        .registered => |registered| {
            target.event.waitUncancelable(std.testing.io);
            var owned = registered;
            owned.cancel();
        },
    }
    target.event.reset();
}

const LoopbackHarness = struct {
    host: heap.HostOwner,
    runtime_scheduler: scheduler_api.Scheduler,
    root_scope: scheduler_api.TaskScope,
    owner: NetOwner,

    fn init(self: *LoopbackHarness, allocator: std.mem.Allocator, limits: Limits) !void {
        self.host = heap.HostOwner.init(allocator);
        self.runtime_scheduler = try scheduler_api.Scheduler.init(self.host.cleanup(), .cooperative, .host);
        self.runtime_scheduler.attachRetirement();
        self.root_scope = scheduler_api.TaskScope.init(self.runtime_scheduler.worker());
        self.owner = try NetOwner.init(allocator, std.testing.io, .{ .binds = .unrestricted, .limits = limits });
    }

    fn deinit(self: *LoopbackHarness) void {
        self.runtime_scheduler.deinit(&self.root_scope);
        self.owner.deinit();
        self.host.cleanup().drain();
    }
};

fn connectLoopback(port: u16) !std.Io.net.Stream {
    const address: IpAddress = .{ .ip4 = .loopback(port) };
    return IpAddress.connect(&address, std.testing.io, .{ .mode = .stream });
}

test "accepted connections exchange exact bytes, close gracefully, and release their reservation" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{ .receive_capacity = 8, .send_capacity = 8 });
    defer harness.deinit();
    const listener_port = try harness.owner.listen(harness.runtime_scheduler.worker(), &harness.root_scope, .{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const port = listener.localAddress().?.getPort();

    const slot = try listener.beginAccept();
    const peer = try connectLoopback(port);
    var target: TestTarget = .{};
    try awaitSource(listener.acceptSource(slot), &target);
    const connection_port = switch (try listener.pollAccept(slot, harness.runtime_scheduler.worker(), &harness.root_scope)) {
        .accepted => |port_value| port_value,
        else => return error.UnexpectedAcceptOutcome,
    };
    listener.endAccept(slot);
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;
    try std.testing.expect(fromValue(connection_port) == null);
    try std.testing.expectEqual(@as(usize, 1), harness.owner.live_connections.load(.acquire));

    var peer_writer = peer.writer(std.testing.io, &.{});
    try peer_writer.interface.writeAll("abcdefghij");
    var received: [10]u8 = undefined;
    var filled: usize = 0;
    try connection.beginRead();
    while (filled != received.len) {
        switch (connection.read(received[filled..])) {
            .data => |count| filled += count,
            .pending => try awaitSource(connection.readSource(), &target),
            else => return error.UnexpectedReadOutcome,
        }
    }
    connection.endRead();
    try std.testing.expectEqualStrings("abcdefghij", &received);

    const permit = try connection.beginWrite();
    const outgoing = "0123456789ab";
    var offset: usize = 0;
    while (offset != outgoing.len) {
        switch (connection.write(permit, outgoing[offset..])) {
            .written => |count| offset += count,
            .pending => try awaitSource(connection.writeSource(permit), &target),
            else => return error.UnexpectedWriteOutcome,
        }
    }
    connection.finishWrite(permit);
    connection.close();
    connection.close();
    var peer_buffer: [64]u8 = undefined;
    var peer_reader = peer.reader(std.testing.io, &peer_buffer);
    var echoed: [outgoing.len]u8 = undefined;
    try peer_reader.interface.readSliceAll(&echoed);
    try std.testing.expectEqualStrings(outgoing, &echoed);
    try std.testing.expectError(error.EndOfStream, peer_reader.interface.takeByte());
    peer.close(std.testing.io);

    // The final lease publishes closed and releases the reservation.
    var settled = false;
    var spins: usize = 0;
    while (!settled and spins < 10_000) : (spins += 1) {
        settled = harness.owner.live_connections.load(.acquire) == 0;
        if (!settled) std.Thread.yield() catch {};
    }
    try std.testing.expect(settled);
    try std.testing.expect(connection.peerAddress() == null);
    try std.testing.expectEqual(ReadProgress.closed, connection.read(&received));
}

test "an accept cancelled after a peer connected closes the orphan and the listener closes synchronously" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const listener_port = try harness.owner.listen(harness.runtime_scheduler.worker(), &harness.root_scope, .{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const port = listener.localAddress().?.getPort();

    const slot = try listener.beginAccept();
    const peer = try connectLoopback(port);
    var target: TestTarget = .{};
    try awaitSource(listener.acceptSource(slot), &target);
    listener.endAccept(slot);
    var peer_buffer: [8]u8 = undefined;
    var peer_reader = peer.reader(std.testing.io, &peer_buffer);
    try std.testing.expectError(error.EndOfStream, peer_reader.interface.takeByte());
    peer.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), harness.owner.live_connections.load(.acquire));

    // A second accept parks; closing the listener marks its slot closed and
    // returns only after the acceptor left poll and the socket is closed.
    const parked = try listener.beginAccept();
    listener.close();
    try std.testing.expectEqual(AcceptProgress.closed, try listener.pollAccept(parked, harness.runtime_scheduler.worker(), &harness.root_scope));
    listener.endAccept(parked);
    try std.testing.expectError(error.Closed, listener.beginAccept());
    try std.testing.expectError(error.ConnectionRefused, connectLoopback(port));
    try std.testing.expectEqual(@as(usize, 0), harness.owner.live_connections.load(.acquire));
}

/// A loopback peer for the allocation sweep: connects, writes two bytes, reads
/// two back or observes the connection end, and closes. It allocates nothing
/// through the swept allocator.
const LifecyclePeer = struct {
    thread: ?std.Thread = null,
    port: u16 = 0,

    fn start(self: *LifecyclePeer, port: u16) !void {
        self.port = port;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn join(self: *LifecyclePeer) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn run(self: *LifecyclePeer) void {
        const stream = connectLoopback(self.port) catch return;
        defer stream.close(std.testing.io);
        var writer = stream.writer(std.testing.io, &.{});
        writer.interface.writeAll("hi") catch return;
        writer.interface.flush() catch return;
        var buffer: [16]u8 = undefined;
        var reader = stream.reader(std.testing.io, &buffer);
        var reply: [2]u8 = undefined;
        reader.interface.readSliceAll(&reply) catch return;
    }
};

/// One accept, read, write, close cycle with every readiness wait registered
/// before its poll, so the allocation ordinals do not depend on whether the
/// controller thread won the race: registration allocates exactly once
/// whether or not the source is already ready.
fn connectionLifecycle(allocator: std.mem.Allocator) !void {
    var peer: LifecyclePeer = .{};
    defer peer.join();
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(allocator, .{ .receive_capacity = 8, .send_capacity = 8 });
    defer harness.deinit();
    const listener_port = try harness.owner.listen(harness.runtime_scheduler.worker(), &harness.root_scope, .{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    try peer.start(listener.localAddress().?.getPort());

    const slot = try listener.beginAccept();
    var slot_owned = true;
    defer if (slot_owned) listener.endAccept(slot);
    var target: TestTarget = .{};
    try awaitSource(listener.acceptSource(slot), &target);
    const connection_port = switch (try listener.pollAccept(slot, harness.runtime_scheduler.worker(), &harness.root_scope)) {
        .accepted => |port_value| port_value,
        else => return error.UnexpectedAcceptOutcome,
    };
    listener.endAccept(slot);
    slot_owned = false;
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;

    try connection.beginRead();
    defer connection.endRead();
    try awaitSource(connection.readSource(), &target);
    var received: [2]u8 = undefined;
    switch (connection.read(&received)) {
        .data => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => return error.UnexpectedReadOutcome,
    }
    try std.testing.expectEqualStrings("hi", &received);
    const permit = try connection.beginWrite();
    switch (connection.write(permit, "ok")) {
        .written => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => {
            connection.abandonWrite(permit);
            return error.UnexpectedWriteOutcome;
        },
    }
    connection.finishWrite(permit);
    connection.close();
}

test "connection lifecycle propagates every allocation failure without leaking a socket or slot" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, connectionLifecycle, .{});
}
