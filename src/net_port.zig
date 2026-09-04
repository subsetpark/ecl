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
//! backlog only while an ECL `accept` is outstanding and a live-connection
//! slot is free. The slot is acquired at `accept4` time, under the listener
//! mutex; while the quota is full the acceptor stops polling the listening
//! socket and waits on its wake pipe alone, which every connection release
//! signals, so a waiting accept holds no slot and the connection stays in the
//! kernel backlog until one frees. Each accepted socket is
//! a `ConnectionCell` owned by the accepting unit's scope, with bounded
//! receive and send rings serviced by exactly one controller thread that
//! polls a non-blocking socket and a wake pipe; that thread alone owns the
//! descriptor, the quota slot, and the scope membership until it publishes
//! the terminal state. Closing is one idempotent transition shared by the
//! `close` word and scope cancellation.

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

/// Every way `beginAccept` can fail before anything parks. The connection
/// quota is not among them: a full quota parks the accept rather than failing
/// it.
pub const AcceptError = error{ OutOfMemory, Closed, Io };

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
    failed: Failure,
};

pub const WriteProgress = union(enum) {
    pending,
    written: usize,
    failed: Failure,
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
///
/// Lock order: the acceptor registry mutex is a leaf. It is taken while
/// holding a listener mutex (`beginAccept` registers under it) and while
/// holding a connection cell mutex (`finalizeLocked` releases the reservation
/// under it), and nothing is taken while it is held: `releaseConnection` only
/// writes wake bytes. No path takes a listener mutex while holding a
/// connection cell mutex.
pub const NetOwner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    policy: OwnedPolicy,
    live: std.atomic.Value(usize) = .init(0),
    live_connections: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),
    /// Guards the intrusive list of listeners whose acceptor thread is
    /// running. A cell joins when its thread is spawned and leaves as the
    /// first act of that thread's exit, so `ListenerCell.close`, which waits
    /// for the thread to exit before closing the wake pipe, never leaves a
    /// registered cell whose pipe is gone.
    acceptors_mutex: std.Io.Mutex = .init,
    acceptors_first: ?*ListenerCell = null,

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
        std.debug.assert(self.acceptors_first == null);
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

    /// Free one live-connection slot and wake every running acceptor so one
    /// that stopped polling its listening socket at the quota rechecks. The
    /// counter is decremented before any pipe is written, so an acceptor that
    /// fails its acquire either sees this decrement or has a wake byte queued
    /// for it; the byte persists until drained, so the race is lossless.
    /// Callers hold a connection cell mutex (`finalizeLocked`), a listener
    /// mutex (`acceptOneLocked`'s failure arms), or nothing (`endAccept`'s
    /// orphan): this takes only the registry mutex, so no order is violated.
    fn releaseConnection(self: *NetOwner) void {
        releaseCounter(&self.live_connections);
        std.Io.Threaded.mutexLock(&self.acceptors_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.acceptors_mutex);
        var cell = self.acceptors_first;
        while (cell) |current| : (cell = current.acceptor_next) {
            signalPipe(current.acceptor.wake.?[1]);
        }
    }

    /// Called by `beginAccept` under the listener mutex once its acceptor
    /// thread exists; the cell's wake pipe is set for as long as it is listed.
    fn registerAcceptor(self: *NetOwner, cell: *ListenerCell) void {
        std.Io.Threaded.mutexLock(&self.acceptors_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.acceptors_mutex);
        std.debug.assert(cell.acceptor_prev == null and cell.acceptor_next == null);
        std.debug.assert(self.acceptors_first != cell);
        cell.acceptor_next = self.acceptors_first;
        if (self.acceptors_first) |first| first.acceptor_prev = cell;
        self.acceptors_first = cell;
    }

    /// Called by the acceptor thread as the first act of leaving its role,
    /// before any lock the exit protocol takes.
    fn unregisterAcceptor(self: *NetOwner, cell: *ListenerCell) void {
        std.Io.Threaded.mutexLock(&self.acceptors_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.acceptors_mutex);
        std.debug.assert(self.acceptors_first == cell or cell.acceptor_prev != null);
        if (cell.acceptor_prev) |previous| previous.acceptor_next = cell.acceptor_next else self.acceptors_first = cell.acceptor_next;
        if (cell.acceptor_next) |next| next.acceptor_prev = cell.acceptor_prev;
        cell.acceptor_prev = null;
        cell.acceptor_next = null;
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

        var server = try bindListening(normalized, self.policy.limits.kernel_backlog);
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

/// Open, bind, and listen on one address with `SO_REUSEADDR` and nothing
/// else. A connection this program closed first leaves its port in TIME_WAIT
/// for a minute, and without address reuse a restarted program finds its own
/// port "in use"; `std.Io.net.IpAddress.listen` would set `SO_REUSEPORT` as
/// well, which lets a second live listener bind the same address and port,
/// so the socket is opened here. Every failure closes the descriptor.
fn bindListening(address: IpAddress, backlog: u31) ListenError!std.Io.net.Server {
    const family = std.Io.Threaded.posixAddressFamily(&address);
    const flags: u32 = posix.SOCK.STREAM | if (builtin.os.tag == .linux) posix.SOCK.CLOEXEC else 0;
    const rc = posix.system.socket(family, flags, 0);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .AFNOSUPPORT, .PROTONOSUPPORT, .PROTOTYPE, .INVAL => return error.Unsupported,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.Resources,
        else => return error.Io,
    }
    var socket: OwnedSocket = .{ .fd = @intCast(rc) };
    errdefer socket.close();
    const fd = socket.fd.?;
    if (builtin.os.tag != .linux) try setCloexec(fd);
    const enabled: c_int = 1;
    if (posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enabled, @sizeOf(c_int)) != 0)
        return error.Io;
    // SAFETY: `addressToPosix` writes the bytes `bind` reads, and `getsockname`
    // overwrites them before `addressFromPosix` reads them back.
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var length = std.Io.Threaded.addressToPosix(&address, &storage);
    switch (posix.errno(posix.system.bind(fd, &storage.any, length))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.Unsupported,
        .NOBUFS, .NOMEM => return error.Resources,
        else => return error.Io,
    }
    while (true) {
        switch (posix.errno(posix.system.listen(fd, backlog))) {
            .SUCCESS => break,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            else => return error.Io,
        }
    }
    if (posix.system.getsockname(fd, &storage.any, &length) != 0) return error.Io;
    socket.fd = null;
    return .{
        .socket = .{ .handle = fd, .address = std.Io.Threaded.addressFromPosix(&storage) },
        .options = {},
    };
}

/// Bounded byte queue for the connection's rings. Identical in contract to
/// the process port's ring, plus a peek/consume pair so the controller can
/// hand the kernel a contiguous chunk and retire only what was written.
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

    /// The longest contiguous run of queued bytes starting at the head.
    fn peek(self: *const Ring) []const u8 {
        const first = @min(self.len, self.bytes.len - self.head);
        return self.bytes[self.head..][0..first];
    }

    fn consume(self: *Ring, count: usize) void {
        std.debug.assert(count <= self.len);
        self.head = (self.head + count) % self.bytes.len;
        self.len -= count;
    }

    fn discard(self: *Ring) void {
        self.head = 0;
        self.len = 0;
    }
};

/// A keyed list of registered readiness waits over one cell type. The cell
/// supplies `mutex`, `waits`, `retainRef`, `releaseRef`, and
/// `readyLocked(key)`. Targets stay retained until their registration is
/// consumed, so waking under the cell lock closes the only
/// cancellation/use-after-free race. Every wake is `.ready`: a socket failure
/// is a change in the cell's observable state that the driver polls, not a
/// failure of the wait mechanism.
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
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                cell.allocator.destroy(wait);
                return .{ .ready = .ready };
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

        /// Called with the cell lock held. The wake happens while the wait
        /// is still linked: a concurrent `cancelReadiness` then sees `linked`
        /// and must take this mutex before it can destroy the wait, so the
        /// target cannot be freed out from under the call. Delivery never
        /// cancels the registration on the waking thread, so holding the lock
        /// across the wake cannot deadlock.
        fn notifyLocked(self: *Self, cell: *Cell) void {
            var wait = self.first;
            while (wait) |candidate| {
                const next = candidate.next;
                if (cell.readyLocked(candidate.key)) {
                    candidate.target.wake(.ready);
                    self.unlinkLocked(candidate);
                }
                wait = next;
            }
        }
    };
}

/// A descriptor that is closed exactly once. Nothing else in this file calls
/// `closeFd` on a connection socket.
const OwnedSocket = struct {
    fd: ?posix.fd_t,

    fn close(self: *OwnedSocket) void {
        const fd = self.fd orelse return;
        self.fd = null;
        std.Io.Threaded.closeFd(fd);
    }
};

/// One live-connection quota slot, released exactly once. Nothing else in
/// this file decrements the connection counter.
const ConnectionReservation = struct {
    owner: ?*NetOwner,

    fn acquire(owner: *NetOwner) ?ConnectionReservation {
        if (!owner.reserveConnection()) return null;
        return .{ .owner = owner };
    }

    fn release(self: *ConnectionReservation) void {
        const owner = self.owner orelse return;
        self.owner = null;
        owner.releaseConnection();
    }

    fn take(self: *ConnectionReservation) ConnectionReservation {
        const moved = self.*;
        self.owner = null;
        return moved;
    }
};

/// Both ends of a connection, captured at acceptance: the peer from `accept`
/// and the local end from `getsockname`, so a wildcard listener's connection
/// still reports the address it is actually reachable on.
const Endpoints = struct {
    local: IpAddress,
    peer: IpAddress,
};

/// An accepted socket together with the authority it carries. Moving it into
/// a connection transfers both; dropping it releases both.
const AcceptedSocket = struct {
    socket: OwnedSocket,
    reservation: ConnectionReservation,
    endpoints: Endpoints,

    fn deinit(self: *AcceptedSocket) void {
        self.socket.close();
        self.reservation.release();
    }
};

const AcceptFailure = enum { resources, io };

/// One outstanding `accept`. The word-side driver owns the slot between
/// `beginAccept` and `endAccept`; the acceptor thread fills the first waiting
/// slot in FIFO order, under the listener mutex, so a cancelled accept can
/// never leave a taken socket with no owner and the acceptor never holds more
/// sockets than there are outstanding accepts. A waiting slot holds no quota
/// slot: the reservation is acquired with the socket and travels inside the
/// `ready` state.
pub const AcceptSlot = struct {
    previous: ?*AcceptSlot = null,
    next: ?*AcceptSlot = null,
    linked: bool = true,
    state: State = .waiting,

    const State = union(enum) {
        waiting,
        ready: AcceptedSocket,
        failed: AcceptFailure,
        taken,
        closed,
    };
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
    ownership: external.Ownership = .none,
    /// Set when `close` ran before `attach` stored the membership token, so
    /// `attach` detaches at once instead of leaving the scope waiting.
    detach_on_attach: bool = false,
    waits: WaitList(ListenerCell) = .{},
    slots_first: ?*AcceptSlot = null,
    slots_last: ?*AcceptSlot = null,
    demand: usize = 0,
    acceptor: Acceptor = .{},
    /// Membership in the owner's running-acceptor registry; guarded by
    /// `NetOwner.acceptors_mutex`, never by this cell's mutex.
    acceptor_prev: ?*ListenerCell = null,
    acceptor_next: ?*ListenerCell = null,

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
        /// Set by the acceptor when a slot acquire failed at the quota: it
        /// polls only the wake pipe until a connection release wakes it, and
        /// the connection it saw stays in the kernel backlog.
        quota_blocked: bool = false,
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
        std.debug.assert(self.ownership == .none);
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

    /// Attach this listener to `to_erased` while leaving its current
    /// membership in place, so a caller moving several ports can still back
    /// out. `from_erased` must be the scope that owns the listener now.
    pub fn prepareScopeTransfer(
        self: *ListenerCell,
        from_erased: *anyopaque,
        to_erased: *anyopaque,
    ) heap.PortTransferError!void {
        const destination: *scheduler_api.TaskScope = @ptrCast(@alignCast(to_erased));
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.ownership) {
            .none => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return error.Closed;
            },
            .transferring => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return error.Busy;
            },
            .owned => |current| if (current.owningScope() != from_erased) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return error.NotOwner;
            },
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);

        // `attachExternal` allocates and takes the destination scope's lock,
        // so it runs outside this cell's lock: the cancellation walk takes a
        // scope lock before a member's, and the reverse order would close a
        // cycle between them.
        const member = external.scopeMember(ListenerCell, self);
        var token = destination.scheduler.attachExternal(destination, member) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeClosing => error.ScopeClosing,
        };

        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.ownership != .owned) {
            // Closed while the destination was being attached. Hand the new
            // membership straight back rather than leaving the destination
            // scope holding a member nothing will ever detach.
            std.Io.Threaded.mutexUnlock(&self.mutex);
            token.detach();
            return error.Closed;
        }
        self.ownership.beginTransfer(token);
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Make a prepared transfer permanent: the destination scope owns the
    /// listener and the origin scope no longer does.
    pub fn commitScopeTransfer(self: *ListenerCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        var detached = self.ownership.commitTransfer();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        detached.detachAll();
    }

    /// Undo a prepared transfer, leaving the origin scope as the owner.
    pub fn abortScopeTransfer(self: *ListenerCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        var detached = self.ownership.abortTransfer();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        detached.detachAll();
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
        std.debug.assert(self.ownership == .none);
        self.ownership = .{ .owned = membership };
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Close the socket, release the quota slot, and detach from the scope.
    /// Idempotent: a closed cell stays closed and nothing runs twice. When an
    /// acceptor thread is running, wake it and wait for it to leave `poll`
    /// first; that wait is bounded by one thread returning from a `poll` the
    /// wake byte has already satisfied, and it keeps close synchronous so the
    /// address may be bound again the moment this returns.
    pub fn close(self: *ListenerCell) void {
        var detached: external.Ownership.Detached = .{};
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.state) {
            .bound => |bound| {
                if (self.acceptor.running) {
                    self.acceptor.stop = true;
                    if (self.acceptor.wake) |wake| signalPipe(wake[1]);
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
                    if (current.state == .waiting) current.state = .closed;
                }
                self.waits.notifyLocked(self);
                if (self.ownership.live()) {
                    detached = self.ownership.release();
                } else {
                    self.detach_on_attach = true;
                }
            },
            .closed => {},
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        detached.detachAll();
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
        return slot.state != .waiting;
    }

    /// Link an accept slot and start the acceptor thread if it is not
    /// running. Fails before anything parks. No quota slot is taken here:
    /// the acceptor acquires one with the socket.
    pub fn beginAccept(self: *ListenerCell) AcceptError!*AcceptSlot {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const bound = switch (self.state) {
            .bound => |*bound| bound,
            .closed => return error.Closed,
        };
        const slot = try self.allocator.create(AcceptSlot);
        errdefer self.allocator.destroy(slot);
        if (!self.acceptor.running) {
            if (self.acceptor.wake == null) {
                self.acceptor.wake = std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch return error.Io;
            }
            setBlockingMode(bound.server.socket.handle, .non_blocking) catch return error.Io;
            self.retainRef();
            self.acceptor.running = true;
            self.acceptor.stop = false;
            self.acceptor.quota_blocked = false;
            const thread = std.Thread.spawn(.{}, acceptorThreadMain, .{self}) catch {
                self.acceptor.running = false;
                self.releaseRef();
                return error.Io;
            };
            thread.detach();
            // The thread cannot reach `exitAcceptor` before this: its first
            // act is to take the mutex this call still holds.
            self.owner.registerAcceptor(self);
        }
        slot.* = .{};
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
    /// attached to `scope`, and publish its port. A ready slot yields a
    /// connection even after the listener closed: the accepted socket is
    /// independent of the listening one.
    pub fn pollAccept(
        self: *ListenerCell,
        slot: *AcceptSlot,
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
    ) error{OutOfMemory}!AcceptProgress {
        std.Io.Threaded.mutexLock(&self.mutex);
        const accepted = switch (slot.state) {
            .waiting => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .pending;
            },
            .closed => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .closed;
            },
            .failed => |failure| {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return switch (failure) {
                    .resources => .resources,
                    .io => .io,
                };
            },
            .taken => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return .io;
            },
            .ready => |ready| taken: {
                slot.state = .taken;
                break :taken ready;
            },
        };
        std.Io.Threaded.mutexUnlock(&self.mutex);
        // The descriptor and the reservation now belong to the connection
        // being published; every failure inside releases both exactly once.
        return ConnectionCell.publish(self.owner, accepted, scheduler, scope);
    }

    /// Release the slot and whatever it still holds: a ready slot closes its
    /// socket and releases its reservation; a waiting, failed, closed, or
    /// taken slot owns nothing.
    pub fn endAccept(self: *ListenerCell, slot: *AcceptSlot) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(slot.linked);
        if (slot.previous) |previous| previous.next = slot.next else self.slots_first = slot.next;
        if (slot.next) |next| next.previous = slot.previous else self.slots_last = slot.previous;
        slot.linked = false;
        std.debug.assert(self.demand != 0);
        self.demand -= 1;
        var orphan: ?AcceptedSocket = null;
        switch (slot.state) {
            .ready => |ready| orphan = ready,
            .waiting, .failed, .closed, .taken => {},
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (orphan) |*accepted| accepted.deinit();
        self.allocator.destroy(slot);
    }

    fn firstWaitingLocked(self: *ListenerCell) ?*AcceptSlot {
        var slot = self.slots_first;
        while (slot) |current| : (slot = current.next) {
            if (current.state == .waiting) return current;
        }
        return null;
    }

    /// Serve accepts until stopped. While a slot waits, poll the listening
    /// socket for readability and the wake pipe; while quota-blocked, poll the
    /// wake pipe alone so a connection in the backlog does not spin the
    /// thread. A wake byte means drain and recheck: exit if `close` asked for
    /// a stop, otherwise clear the block and look at the socket again.
    fn acceptorMain(self: *ListenerCell) void {
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (!self.acceptor.stop and self.state == .bound and self.firstWaitingLocked() == null)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            if (self.acceptor.stop or self.state != .bound) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break;
            }
            const listen_fd = self.state.bound.server.socket.handle;
            const wake_fd = self.acceptor.wake.?[0];
            const listen_events: i16 = if (self.acceptor.quota_blocked) 0 else posix.POLL.IN;
            std.Io.Threaded.mutexUnlock(&self.mutex);

            var fds = [_]posix.pollfd{
                .{ .fd = listen_fd, .events = listen_events, .revents = 0 },
                .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch return self.exitAcceptor(.io);
            if (fds[1].revents != 0) {
                drainPipe(wake_fd);
                std.Io.Threaded.mutexLock(&self.mutex);
                const stop = self.acceptor.stop;
                self.acceptor.quota_blocked = false;
                std.Io.Threaded.mutexUnlock(&self.mutex);
                if (stop) break;
                continue;
            }
            if (fds[0].revents == 0) continue;
            self.acceptOneLocked();
        }
        self.exitAcceptor(null);
    }

    /// Leave the acceptor role. The registry entry goes first, so no
    /// connection release writes to a wake pipe `close` is about to close
    /// once `running` clears. The thread's reference goes next: the scope
    /// member still pins the cell, so this cannot destroy it, and the closer
    /// that detaches the member afterwards performs the last release before
    /// scope quiescence is published. A host failure is published and
    /// `running` cleared under one lock hold, so a `beginAccept` that arrives
    /// next either sees the failure on its own slot or starts a fresh thread;
    /// it can never append a slot no thread will ever serve.
    fn exitAcceptor(self: *ListenerCell, failure: ?AcceptFailure) void {
        self.owner.unregisterAcceptor(self);
        self.releaseRef();
        std.Io.Threaded.mutexLock(&self.mutex);
        if (failure) |reason| {
            var slot = self.slots_first;
            while (slot) |current| : (slot = current.next) {
                if (current.state == .waiting) current.state = .{ .failed = reason };
            }
            self.waits.notifyLocked(self);
        }
        self.acceptor.running = false;
        self.changed.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Accept one connection into the first waiting slot, or accept nothing.
    /// The syscall runs under the listener mutex so `endAccept` cannot remove
    /// the last slot between the readiness report and the accept: either the
    /// cancellation wins and the connection stays in the kernel backlog for
    /// the next accept, or the accept wins and the socket belongs to that
    /// slot. The live-connection slot is acquired here, just before the
    /// syscall: when none is free the acceptor marks itself quota-blocked and
    /// takes nothing, so the connection stays in the backlog until a release
    /// wakes it. The listening socket is non-blocking, so the locked syscall
    /// is bounded.
    fn acceptOneLocked(self: *ListenerCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const slot = self.firstWaitingLocked() orelse return;
        const listen_fd = switch (self.state) {
            .bound => |bound| bound.server.socket.handle,
            .closed => return,
        };
        var reservation = ConnectionReservation.acquire(self.owner) orelse {
            self.acceptor.quota_blocked = true;
            return;
        };
        // Released on every path that does not move it into the slot; the
        // move empties it, so the release is then a no-op.
        defer reservation.release();
        // SAFETY: accept writes the peer address into `storage` before it is
        // read, and nothing reads it on any failure path.
        var storage: std.Io.Threaded.PosixAddress = undefined;
        var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
        const rc = if (builtin.os.tag == .linux)
            posix.system.accept4(listen_fd, &storage.any, &length, posix.SOCK.CLOEXEC)
        else
            posix.system.accept(listen_fd, &storage.any, &length);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR, .CONNABORTED => return,
            .MFILE, .NFILE, .NOBUFS, .NOMEM => return self.failSlotLocked(slot, .resources),
            else => return self.failSlotLocked(slot, .io),
        }
        var socket: OwnedSocket = .{ .fd = @intCast(rc) };
        const peer = std.Io.Threaded.addressFromPosix(&storage);
        const local = prepareAccepted(socket.fd.?) catch {
            socket.close();
            return self.failSlotLocked(slot, .io);
        };
        slot.state = .{ .ready = .{
            .socket = socket,
            .reservation = reservation.take(),
            .endpoints = .{ .local = local, .peer = peer },
        } };
        self.waits.notifyLocked(self);
    }

    fn failSlotLocked(self: *ListenerCell, slot: *AcceptSlot, failure: AcceptFailure) void {
        slot.state = .{ .failed = failure };
        self.waits.notifyLocked(self);
    }
};

fn acceptorThreadMain(cell: *ListenerCell) void {
    cell.acceptorMain();
}

/// Make an accepted descriptor close-on-exec and non-blocking (BSD kernels
/// inherit the listener's flags, Linux does not; both are set explicitly) and
/// read back its local endpoint.
fn prepareAccepted(fd: posix.fd_t) error{Io}!IpAddress {
    if (builtin.os.tag != .linux) try setCloexec(fd);
    try setBlockingMode(fd, .non_blocking);
    // A write to a peer that has gone away must surface as EPIPE for the
    // controller to map, never as SIGPIPE delivered to an embedding host that
    // kept the default disposition. Platforms without MSG_NOSIGNAL offer the
    // socket-level switch instead; `sendFlags` covers the rest.
    if (@hasDecl(posix.SO, "NOSIGPIPE")) {
        const enabled: c_int = 1;
        if (posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0)
            return error.Io;
    }
    // SAFETY: getsockname fills `storage` before it is read; a failure
    // returns before any read.
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    if (posix.system.getsockname(fd, &storage.any, &length) != 0) return error.Io;
    return std.Io.Threaded.addressFromPosix(&storage);
}

/// Flags for every controller send: suppress SIGPIPE where the kernel offers
/// a per-call switch.
const send_flags: u32 = if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;

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

/// Wake a controller blocked in `poll`. The pipe is non-blocking; a full pipe
/// already carries a pending wake, so `EAGAIN` needs nothing, but a write
/// interrupted before the byte landed must be retried or the close and
/// cancellation paths that rely on this wake would wait forever.
fn signalPipe(write_end: posix.fd_t) void {
    const byte = [_]u8{0};
    while (true) {
        const rc = posix.system.write(write_end, &byte, 1);
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => return,
        }
    }
}

fn drainPipe(read_end: posix.fd_t) void {
    var sink: [64]u8 = undefined;
    while (true) {
        const rc = posix.system.read(read_end, &sink, sink.len);
        if (posix.errno(rc) != .SUCCESS or rc == 0) return;
        if (@as(usize, @intCast(rc)) < sink.len) return;
    }
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
/// Waits for the send ring to empty, so `close` can promise that the bytes it
/// was asked to deliver have actually left for the peer.
const readiness_drain: u64 = 2;

/// Why a connection can no longer carry bytes in a direction.
pub const Failure = enum { closed, reset, io };

pub const EndpointKind = enum { local, peer };

pub const EndpointObservation = union(enum) {
    available: IpAddress,
    closed: IpAddress,
};

/// One accepted TCP connection with exactly one controller thread. The
/// controller owns the descriptor, the quota reservation, and the scope
/// membership token from the moment it starts until it publishes `terminal`;
/// scheduler workers touch only the rings, the flags, and the wait list. A
/// non-blocking socket and a wake pipe let one `poll` serve both directions,
/// so there is no second thread to race the first one's cleanup.
pub const ConnectionCell = struct {
    allocator: std.mem.Allocator,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    lifecycle: Lifecycle = .prepared,
    socket: OwnedSocket,
    reservation: ConnectionReservation,
    endpoints: Endpoints,
    wake: [2]posix.fd_t,
    receive: Ring,
    send: Ring,
    reader_active: bool = false,
    /// The peer has finished sending; queued bytes remain readable.
    peer_eof: bool = false,
    /// The socket failed; set once, never cleared.
    failure: ?Failure = null,
    write_first: ?*WriteNode = null,
    write_last: ?*WriteNode = null,
    waits: WaitList(ConnectionCell) = .{},
    ownership: external.Ownership = .none,

    const Lifecycle = union(enum) {
        /// Allocated; no thread exists. The scope may already hold the member
        /// (attachment and the start decision happen under one lock hold).
        prepared,
        /// The controller thread owns the socket.
        running,
        /// A stop was requested; the controller finishes and finalizes.
        stopping: StopReason,
        /// The descriptor is closed and the reservation released.
        terminal: StopReason,
    };

    const StopReason = enum {
        /// `close`: deliver queued bytes, then shut down.
        close,
        /// Scope cancellation or a publication failure: discard and shut down.
        abort,
        /// The socket failed; `failure` names why, and reads and writes
        /// report that reason rather than `closed`.
        failed,
    };

    const Waits = WaitList(ConnectionCell);

    /// Build the cell, attach it to the accepting scope, start the controller,
    /// and publish the port, in that order, so no thread exists before the
    /// scope can wait for it. Owns `accepted` on every path.
    fn publish(
        owner: *NetOwner,
        accepted: AcceptedSocket,
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
    ) error{OutOfMemory}!AcceptProgress {
        const cell = prepare(owner, accepted) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Resources => return .resources,
        };
        const member = external.scopeMember(ConnectionCell, cell);
        const membership = scheduler.attachExternal(scope, member) catch |err| {
            cell.retireUnstarted(.abort);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ScopeClosing => .scope_closing,
            };
        };
        std.Io.Threaded.mutexLock(&cell.mutex);
        cell.ownership = .{ .owned = membership };
        // The scope may have started cancelling between the attach and this
        // lock; then no thread starts and the cell retires here, so the scope
        // never waits on a controller that does not exist.
        if (cell.lifecycle == .stopping) {
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            cell.retireUnstarted(.abort);
            return .scope_closing;
        }
        std.debug.assert(cell.lifecycle == .prepared);
        // Start under the lock: a cancellation from here on sees `running`
        // and signals the controller through the wake pipe.
        cell.retainRef();
        cell.lifecycle = .running;
        const spawned = std.Thread.spawn(.{}, controllerThreadMain, .{cell}) catch null;
        if (spawned) |thread| {
            thread.detach();
            std.Io.Threaded.mutexUnlock(&cell.mutex);
        } else {
            cell.lifecycle = .prepared;
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            cell.releaseRef();
            cell.retireUnstarted(.abort);
            return .resources;
        }
        const port = heap.createPort(ConnectionCell, owner.allocator, cell.identity, cell) catch {
            cell.abort();
            cell.releaseRef();
            return error.OutOfMemory;
        };
        return .{ .accepted = port };
    }

    fn prepare(owner: *NetOwner, accepted_value: AcceptedSocket) error{ OutOfMemory, Resources }!*ConnectionCell {
        var accepted = accepted_value;
        errdefer accepted.deinit();
        const cell = try owner.allocator.create(ConnectionCell);
        errdefer owner.allocator.destroy(cell);
        const receive = try owner.allocator.alloc(u8, owner.policy.limits.receive_capacity);
        errdefer owner.allocator.free(receive);
        const send = try owner.allocator.alloc(u8, owner.policy.limits.send_capacity);
        errdefer owner.allocator.free(send);
        const wake = std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch return error.Resources;
        cell.* = .{
            .allocator = owner.allocator,
            .identity = owner.next_identity.fetchAdd(1, .monotonic),
            .socket = accepted.socket,
            .reservation = accepted.reservation,
            .endpoints = accepted.endpoints,
            .wake = wake,
            .receive = .{ .bytes = receive },
            .send = .{ .bytes = send },
        };
        return cell;
    }

    /// Finish a cell whose controller never started: close everything,
    /// publish `terminal`, detach any membership, and drop the initial
    /// reference.
    fn retireUnstarted(self: *ConnectionCell, reason: StopReason) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(self.lifecycle != .running);
        var detached = self.finalizeLocked(reason);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        // Same order as the controller: the publisher's reference goes first
        // while the member (if any) still pins the cell.
        self.releaseRef();
        detached.detachAll();
    }

    /// Close the descriptor and the wake pipe, release the reservation,
    /// publish `terminal`, wake every waiter, and hand back the membership
    /// token for the caller to detach outside the lock. Runs exactly once.
    fn finalizeLocked(self: *ConnectionCell, reason: StopReason) external.Ownership.Detached {
        std.debug.assert(self.lifecycle != .terminal);
        self.socket.close();
        self.reservation.release();
        std.Io.Threaded.closeFd(self.wake[0]);
        std.Io.Threaded.closeFd(self.wake[1]);
        self.lifecycle = .{ .terminal = reason };
        self.waits.notifyLocked(self);
        // A connection that dies mid-transfer detaches the destination too:
        // that membership never became authoritative.
        return self.ownership.release();
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
        std.debug.assert(self.lifecycle == .terminal);
        std.debug.assert(self.ownership == .none);
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

    /// Scope closure: discard queued output and shut the socket down now.
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

    /// Queued bytes first; then the reason nothing more can arrive; then EOF;
    /// otherwise pending. Local closure outranks a later peer failure.
    pub fn read(self: *ConnectionCell, destination: []u8) ReadProgress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.receive.len != 0) {
            const was_full = self.receive.free() == 0;
            const count = self.receive.pop(destination);
            if (was_full) self.signalLocked();
            return .{ .data = count };
        }
        if (self.failureLocked()) |failure| return .{ .failed = failure };
        if (self.peer_eof) return .eof;
        return .pending;
    }

    pub fn readSource(self: *ConnectionCell) external.ReadinessSource {
        return external.readinessSource(ConnectionCell, self, readiness_read);
    }

    /// Nothing more will reach the peer: the queue is empty, the controller
    /// has finished, or the socket failed and discarded what was queued.
    fn drainedLocked(self: *const ConnectionCell) bool {
        if (self.send.len == 0) return true;
        return switch (self.lifecycle) {
            .prepared, .running, .stopping => self.failure != null,
            .terminal => true,
        };
    }

    /// Whether every queued byte has been handed to the kernel.
    pub fn drained(self: *ConnectionCell) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.drainedLocked();
    }

    pub fn drainSource(self: *ConnectionCell) external.ReadinessSource {
        return external.readinessSource(ConnectionCell, self, readiness_drain);
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
        if (self.failureLocked()) |failure| return .{ .failed = failure };
        if (!node.active or self.send.free() == 0) return .pending;
        const count = @min(bytes.len, self.send.free());
        self.send.push(bytes[0..count]);
        self.signalLocked();
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

    /// Graceful close: refuse new writes, let the controller deliver queued
    /// bytes, then shut the socket down. Idempotent. Queued input is dropped
    /// because no read can observe it after this transition.
    pub fn close(self: *ConnectionCell) void {
        self.requestStop(.close);
    }

    /// Attach this connection to `to_erased` while leaving its current
    /// membership in place. `from_erased` must be the scope that owns it now.
    pub fn prepareScopeTransfer(
        self: *ConnectionCell,
        from_erased: *anyopaque,
        to_erased: *anyopaque,
    ) heap.PortTransferError!void {
        const destination: *scheduler_api.TaskScope = @ptrCast(@alignCast(to_erased));
        std.Io.Threaded.mutexLock(&self.mutex);
        const live = switch (self.lifecycle) {
            .prepared, .running => true,
            .stopping, .terminal => false,
        };
        if (!live) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return error.Closed;
        }
        switch (self.ownership) {
            .none => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return error.Closed;
            },
            .transferring => {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return error.Busy;
            },
            .owned => |current| if (current.owningScope() != from_erased) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return error.NotOwner;
            },
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);

        // Outside this cell's lock: the cancellation walk takes a scope lock
        // before a member's, so attaching under the cell lock would close a
        // cycle between the two.
        const member = external.scopeMember(ConnectionCell, self);
        var token = destination.scheduler.attachExternal(destination, member) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScopeClosing => error.ScopeClosing,
        };

        std.Io.Threaded.mutexLock(&self.mutex);
        const still_live = switch (self.lifecycle) {
            .prepared, .running => self.ownership == .owned,
            .stopping, .terminal => false,
        };
        if (!still_live) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            token.detach();
            return error.Closed;
        }
        self.ownership.beginTransfer(token);
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Make a prepared transfer permanent.
    pub fn commitScopeTransfer(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        var detached = self.ownership.commitTransfer();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        detached.detachAll();
    }

    /// Undo a prepared transfer, leaving the origin scope as the owner.
    pub fn abortScopeTransfer(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        var detached = self.ownership.abortTransfer();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        detached.detachAll();
    }

    fn abort(self: *ConnectionCell) void {
        self.requestStop(.abort);
    }

    fn requestStop(self: *ConnectionCell, reason: StopReason) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        switch (self.lifecycle) {
            // No controller exists yet: the publisher, which is about to take
            // this lock, observes `stopping` and retires the cell itself.
            .prepared => self.lifecycle = .{ .stopping = reason },
            .running => {
                self.lifecycle = .{ .stopping = reason };
                self.receive.discard();
                if (reason == .abort) self.send.discard();
                self.signalLocked();
                self.waits.notifyLocked(self);
            },
            .stopping => |current| if (reason == .abort and current == .close) {
                self.lifecycle = .{ .stopping = .abort };
                self.send.discard();
                self.signalLocked();
                self.waits.notifyLocked(self);
            },
            .terminal => {},
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn signalLocked(self: *ConnectionCell) void {
        if (self.lifecycle == .running or self.lifecycle == .stopping) signalPipe(self.wake[1]);
    }

    /// Why no more bytes can move, or null while the connection is live.
    fn failureLocked(self: *const ConnectionCell) ?Failure {
        switch (self.lifecycle) {
            .stopping, .terminal => |reason| switch (reason) {
                .close, .abort => return .closed,
                .failed => return self.failure orelse .io,
            },
            .prepared, .running => {},
        }
        return self.failure;
    }

    pub fn observeEndpoint(self: *ConnectionCell, kind: EndpointKind) EndpointObservation {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const address = switch (kind) {
            .local => self.endpoints.local,
            .peer => self.endpoints.peer,
        };
        return if (self.failureLocked() == null) .{ .available = address } else .{ .closed = address };
    }

    fn readyLocked(self: *ConnectionCell, key: u64) bool {
        if (key == readiness_read)
            return self.receive.len != 0 or self.peer_eof or self.failureLocked() != null;
        if (key == readiness_drain) return self.drainedLocked();
        const node: *const WriteNode = @ptrFromInt(key);
        return !node.linked or (node.active and self.send.free() != 0) or self.failureLocked() != null;
    }

    fn noteFailureLocked(self: *ConnectionCell, code: posix.E) void {
        if (self.failure != null) return;
        self.failure = switch (code) {
            .CONNRESET, .PIPE, .NOTCONN => .reset,
            else => .io,
        };
        self.send.discard();
        self.waits.notifyLocked(self);
    }

    const Interest = struct { read: bool, write: bool, finalize: ?StopReason };

    fn interestLocked(self: *ConnectionCell) Interest {
        return switch (self.lifecycle) {
            .running => if (self.failure != null)
                .{ .read = false, .write = false, .finalize = .failed }
            else
                .{ .read = !self.peer_eof and self.receive.free() != 0, .write = self.send.len != 0, .finalize = null },
            .stopping => |reason| switch (reason) {
                .abort, .failed => .{ .read = false, .write = false, .finalize = reason },
                .close => if (self.send.len == 0 or self.failure != null)
                    .{ .read = false, .write = false, .finalize = .close }
                else
                    .{ .read = false, .write = true, .finalize = null },
            },
            .prepared, .terminal => unreachable,
        };
    }

    fn controllerMain(self: *ConnectionCell) void {
        var block: [4096]u8 = undefined;
        const finalize_reason: StopReason = loop: while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            const interest = self.interestLocked();
            const socket_fd = self.socket.fd.?;
            const wake_fd = self.wake[0];
            const read_capacity = @min(block.len, self.receive.free());
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (interest.finalize) |reason| break :loop reason;

            var events: i16 = 0;
            if (interest.read) events |= posix.POLL.IN;
            if (interest.write) events |= posix.POLL.OUT;
            var fds = [_]posix.pollfd{
                .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (events != 0) socket_fd else -1, .events = events, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch {
                std.Io.Threaded.mutexLock(&self.mutex);
                self.noteFailureLocked(.IO);
                std.Io.Threaded.mutexUnlock(&self.mutex);
                continue;
            };
            if (fds[0].revents != 0) drainPipe(wake_fd);
            const revents = fds[1].revents;
            if (revents == 0) continue;
            const exceptional = revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0;
            if (interest.read and (revents & posix.POLL.IN != 0 or exceptional)) {
                const rc = posix.system.read(socket_fd, &block, read_capacity);
                std.Io.Threaded.mutexLock(&self.mutex);
                switch (posix.errno(rc)) {
                    .SUCCESS => if (rc == 0) {
                        self.peer_eof = true;
                        self.waits.notifyLocked(self);
                    } else {
                        if (self.lifecycle == .running) self.receive.push(block[0..@intCast(rc)]);
                        self.waits.notifyLocked(self);
                    },
                    .AGAIN, .INTR => {},
                    else => |code| self.noteFailureLocked(code),
                }
                std.Io.Threaded.mutexUnlock(&self.mutex);
            }
            if (interest.write and (revents & posix.POLL.OUT != 0 or exceptional)) {
                // The lock is held across the syscall: the socket is
                // non-blocking so the write is bounded, and a stop request
                // that discards the ring cannot slip between peek and consume.
                std.Io.Threaded.mutexLock(&self.mutex);
                const chunk = self.send.peek();
                if (chunk.len != 0) {
                    const rc = posix.system.send(socket_fd, chunk.ptr, chunk.len, send_flags);
                    switch (posix.errno(rc)) {
                        .SUCCESS => {
                            self.send.consume(@intCast(rc));
                            self.waits.notifyLocked(self);
                        },
                        .AGAIN, .INTR => {},
                        else => |code| self.noteFailureLocked(code),
                    }
                }
                std.Io.Threaded.mutexUnlock(&self.mutex);
            }
        };
        // Shut down before closing so the peer observes an orderly FIN (or
        // RST for an abort with unread data) rather than a silent vanish.
        _ = posix.system.shutdown(self.socket.fd.?, posix.SHUT.RDWR);
        std.Io.Threaded.mutexLock(&self.mutex);
        var detached = self.finalizeLocked(finalize_reason);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        // Drop the thread's reference while the scope member still pins the
        // cell, then detach: the member's release is the last one and it
        // happens before the scope publishes quiescence, so teardown and the
        // allocation sweep never observe a cell the thread has yet to drop.
        self.releaseRef();
        detached.detachAll();
    }
};

fn controllerThreadMain(cell: *ConnectionCell) void {
    cell.controllerMain();
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

    fn listen(self: *LoopbackHarness, address: IpAddress) !Value {
        return self.owner.listen(self.runtime_scheduler.worker(), &self.root_scope, address);
    }

    /// Accept one connection through the slot protocol, waiting on its
    /// readiness source first so the ordinals do not depend on timing.
    fn acceptOne(self: *LoopbackHarness, listener: *ListenerCell, target: *TestTarget) !Value {
        const slot = try listener.beginAccept();
        var slot_owned = true;
        defer if (slot_owned) listener.endAccept(slot);
        try awaitSource(listener.acceptSource(slot), target);
        const port = switch (try listener.pollAccept(slot, self.runtime_scheduler.worker(), &self.root_scope)) {
            .accepted => |port_value| port_value,
            else => return error.UnexpectedAcceptOutcome,
        };
        listener.endAccept(slot);
        slot_owned = false;
        return port;
    }
};

fn connectLoopback(port: u16) !std.Io.net.Stream {
    const address: IpAddress = .{ .ip4 = .loopback(port) };
    return IpAddress.connect(&address, std.testing.io, .{ .mode = .stream });
}

fn readExact(connection: *ConnectionCell, target: *TestTarget, destination: []u8) !void {
    var filled: usize = 0;
    try connection.beginRead();
    defer connection.endRead();
    while (filled != destination.len) {
        try awaitSource(connection.readSource(), target);
        switch (connection.read(destination[filled..])) {
            .data => |count| filled += count,
            else => return error.UnexpectedReadOutcome,
        }
    }
}

fn writeAll(connection: *ConnectionCell, target: *TestTarget, bytes: []const u8) !void {
    const permit = try connection.beginWrite();
    var permit_owned = true;
    defer if (permit_owned) connection.abandonWrite(permit);
    var offset: usize = 0;
    while (offset != bytes.len) {
        switch (connection.write(permit, bytes[offset..])) {
            .written => |count| offset += count,
            .pending => try awaitSource(connection.writeSource(permit), target),
            .failed => return error.UnexpectedWriteOutcome,
        }
    }
    connection.finishWrite(permit);
    permit_owned = false;
}

fn waitForZeroConnections(owner: *NetOwner) !void {
    var spins: usize = 0;
    while (owner.live_connections.load(.acquire) != 0) : (spins += 1) {
        if (spins == 100_000) return error.ConnectionNeverReleased;
        try std.Thread.yield();
    }
}

test "accepted connections exchange exact bytes, close gracefully, and release their reservation" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{ .receive_capacity = 8, .send_capacity = 8 });
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const port = listener.localAddress().?.getPort();

    var target: TestTarget = .{};
    const peer = try connectLoopback(port);
    const connection_port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;
    try std.testing.expect(fromValue(connection_port) == null);
    try std.testing.expectEqual(@as(usize, 1), harness.owner.live_connections.load(.acquire));
    try std.testing.expectEqual(port, connection.observeEndpoint(.local).available.getPort());

    var peer_writer = peer.writer(std.testing.io, &.{});
    try peer_writer.interface.writeAll("abcdefghij");
    var received: [10]u8 = undefined;
    try readExact(connection, &target, &received);
    try std.testing.expectEqualStrings("abcdefghij", &received);

    const outgoing = "0123456789ab";
    try writeAll(connection, &target, outgoing);
    connection.close();
    connection.close();
    var peer_buffer: [64]u8 = undefined;
    var peer_reader = peer.reader(std.testing.io, &peer_buffer);
    var echoed: [outgoing.len]u8 = undefined;
    try peer_reader.interface.readSliceAll(&echoed);
    try std.testing.expectEqualStrings(outgoing, &echoed);
    try std.testing.expectError(error.EndOfStream, peer_reader.interface.takeByte());
    peer.close(std.testing.io);

    try waitForZeroConnections(&harness.owner);
    try std.testing.expect(connection.observeEndpoint(.peer) == .closed);
    try std.testing.expectEqual(ReadProgress{ .failed = .closed }, connection.read(&received));
}

test "a peer that closes at once yields a connection at EOF whose endpoints stay observable" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    var target: TestTarget = .{};
    const peer = try connectLoopback(listener.localAddress().?.getPort());
    peer.close(std.testing.io);
    const connection_port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;
    try connection.beginRead();
    try awaitSource(connection.readSource(), &target);
    var scratch: [4]u8 = undefined;
    try std.testing.expectEqual(ReadProgress.eof, connection.read(&scratch));
    connection.endRead();
    try std.testing.expect(connection.observeEndpoint(.peer) == .available);
    // The controller stays alive until the program closes: EOF is not
    // termination.
    try std.testing.expectEqual(@as(usize, 1), harness.owner.live_connections.load(.acquire));
    connection.close();
    try waitForZeroConnections(&harness.owner);
}

test "a wildcard listener's connection reports the endpoint it was reached on" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    var target: TestTarget = .{};
    const peer = try connectLoopback(listener.localAddress().?.getPort());
    defer peer.close(std.testing.io);
    const connection_port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;
    const local = connection.observeEndpoint(.local).available;
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &local.ip4.bytes);
    try std.testing.expectEqual(listener.localAddress().?.getPort(), local.getPort());
    connection.close();
    try waitForZeroConnections(&harness.owner);
}

test "a cancelled accept leaves a later connection in the backlog for the next accept" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const port = listener.localAddress().?.getPort();

    // Park an accept so the acceptor is in poll, then cancel it before any
    // peer exists. The acceptor must not take the connection that follows.
    const cancelled = try listener.beginAccept();
    listener.endAccept(cancelled);
    const peer = try connectLoopback(port);
    var peer_writer = peer.writer(std.testing.io, &.{});
    try peer_writer.interface.writeAll("x");
    try peer_writer.interface.flush();

    var target: TestTarget = .{};
    const connection_port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;
    var received: [1]u8 = undefined;
    try readExact(connection, &target, &received);
    try std.testing.expectEqualStrings("x", &received);
    connection.close();
    var peer_buffer: [8]u8 = undefined;
    var peer_reader = peer.reader(std.testing.io, &peer_buffer);
    try std.testing.expectError(error.EndOfStream, peer_reader.interface.takeByte());
    peer.close(std.testing.io);
    try waitForZeroConnections(&harness.owner);
}

test "an accept cancelled after a peer connected closes the orphan and the listener closes synchronously" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
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

test "an accept blocked by the quota resumes when a connection releases its slot" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{ .max_live_connections = 1 });
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const port = listener.localAddress().?.getPort();

    var target: TestTarget = .{};
    const first_peer = try connectLoopback(port);
    defer first_peer.close(std.testing.io);
    const first_port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(first_port);
    const first = connectionFromValue(first_port).?;
    try std.testing.expectEqual(@as(usize, 1), harness.owner.live_connections.load(.acquire));

    // A second peer completes its handshake into the kernel backlog. The
    // accept for it parks: the quota is full, so the acceptor takes nothing
    // and the slot stays waiting however often it is polled.
    const second_peer = try connectLoopback(port);
    defer second_peer.close(std.testing.io);
    var second_writer = second_peer.writer(std.testing.io, &.{});
    try second_writer.interface.writeAll("x");
    try second_writer.interface.flush();
    const slot = try listener.beginAccept();
    var slot_owned = true;
    defer if (slot_owned) listener.endAccept(slot);
    var spins: usize = 0;
    while (spins < 500) : (spins += 1) {
        try std.testing.expectEqual(
            AcceptProgress.pending,
            try listener.pollAccept(slot, harness.runtime_scheduler.worker(), &harness.root_scope),
        );
        try std.testing.expect(harness.owner.live_connections.load(.acquire) <= 1);
        try std.Thread.yield();
    }

    // Closing the first connection frees its slot; the release wakes the
    // acceptor, which takes the queued peer into the waiting slot.
    first.close();
    try awaitSource(listener.acceptSource(slot), &target);
    const second_port = switch (try listener.pollAccept(slot, harness.runtime_scheduler.worker(), &harness.root_scope)) {
        .accepted => |port_value| port_value,
        else => return error.UnexpectedAcceptOutcome,
    };
    defer harness.host.domain().releaseValue(second_port);
    listener.endAccept(slot);
    slot_owned = false;
    try std.testing.expectEqual(@as(usize, 1), harness.owner.live_connections.load(.acquire));
    const second = connectionFromValue(second_port).?;
    var received: [1]u8 = undefined;
    try readExact(second, &target, &received);
    try std.testing.expectEqualStrings("x", &received);
    second.close();
    try waitForZeroConnections(&harness.owner);
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

/// One accept, read, write, close, drain cycle with every readiness wait
/// registered before its poll, so the allocation ordinals do not depend on
/// whether the controller thread won the race: registration allocates exactly
/// once whether or not the source is already ready. The drain wait is what
/// `net.close` installs for a connection, so its allocation is swept here.
fn connectionLifecycle(allocator: std.mem.Allocator) !void {
    var peer: LifecyclePeer = .{};
    defer peer.join();
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(allocator, .{ .receive_capacity = 8, .send_capacity = 8 });
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    try peer.start(listener.localAddress().?.getPort());

    var target: TestTarget = .{};
    const connection_port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(connection_port);
    const connection = connectionFromValue(connection_port).?;

    var received: [2]u8 = undefined;
    try readExact(connection, &target, &received);
    try std.testing.expectEqualStrings("hi", &received);
    try writeAll(connection, &target, "ok");
    connection.close();
    // `net.close` promises the queued bytes reach the peer, which it keeps by
    // parking on this source until the ring empties. Register unconditionally
    // before the first poll, exactly as the reads and writes above do: that is
    // what makes the wait's allocation happen on every run rather than only
    // when the controller has not already drained.
    try awaitSource(connection.drainSource(), &target);
    while (!connection.drained()) try awaitSource(connection.drainSource(), &target);
}

test "connection lifecycle propagates every allocation failure without leaking a socket or slot" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, connectionLifecycle, .{});
}
