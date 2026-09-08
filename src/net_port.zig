//! Scope-owned TCP listeners and connections behind opaque ECL port values.
//!
//! A `NetPolicy` names the address and port pairs a Session may bind once, at
//! construction. `NetOwner` copies it, keeps the live-listener and
//! live-connection quotas, and is the only factory for `ListenerCell`: a bound
//! socket whose lifetime belongs to the creating unit's task scope, never to
//! the language value reference count. Bind is four bounded syscalls on the
//! worker (socket, bind, listen, getsockname). Accepting starts one
//! acceptor job per listener on the first `accept`; it waits in `poll` on
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
const controllers = @import("port_controller.zig");
const transfers = @import("port_transfer.zig");
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
/// holding a connection cell mutex (terminal retirement returns capacity
/// under it), and nothing is taken while it is held: `releaseConnection` only
/// writes wake bytes. No path takes a listener mutex while holding a
/// connection cell mutex.
pub const NetOwner = struct {
    instance: *@import("module_bindings.zig").Identity,
    allocator: std.mem.Allocator,
    io: std.Io,
    policy: OwnedPolicy,
    executor: *controllers.Owner,
    live: std.atomic.Value(usize) = .init(0),
    live_connections: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),
    /// Registry borrowers may signal only the pipes owned by these records.
    /// Registration precedes spawn; rollback or joined retirement removes the
    /// record before closing its descriptors.
    acceptors_mutex: std.Io.Mutex = .init,
    acceptors_first: ?*ListenerCell.Acceptor = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, policy: NetPolicy) PolicyError!NetOwner {
        const jobs = std.math.add(usize, policy.limits.max_live_listeners, policy.limits.max_live_connections) catch return error.InvalidPolicy;
        const capacity = std.math.add(usize, jobs, 1) catch return error.InvalidPolicy;
        var owned_policy = try OwnedPolicy.init(allocator, policy);
        errdefer owned_policy.deinit(allocator);
        const instance = try @import("module_bindings.zig").Identity.create(allocator);
        errdefer instance.release();
        return .{
            .instance = instance,
            .allocator = allocator,
            .io = io,
            .policy = owned_policy,
            .executor = try controllers.Owner.init(allocator, capacity),
        };
    }

    pub fn deinit(self: *NetOwner) void {
        self.executor.deinit();
        self.instance.release();
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

    fn resourceAllocator(self: *NetOwner) std.mem.Allocator {
        return self.allocator;
    }
    fn reserveListener(self: *NetOwner) error{LiveLimit}!void {
        if (!self.reserveLive()) return error.LiveLimit;
    }
    fn reserveAccepted(self: *NetOwner) error{LiveLimit}!void {
        if (!self.reserveConnection()) return error.LiveLimit;
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
        while (cell) |current| : (cell = current.next) {
            signalPipe(current.wake[1]);
        }
    }

    fn registerAcceptor(self: *NetOwner, acceptor: *ListenerCell.Acceptor) void {
        std.Io.Threaded.mutexLock(&self.acceptors_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.acceptors_mutex);
        acceptor.next = self.acceptors_first;
        if (self.acceptors_first) |first| first.previous = acceptor;
        self.acceptors_first = acceptor;
    }

    fn unregisterAcceptor(self: *NetOwner, acceptor: *ListenerCell.Acceptor) void {
        std.Io.Threaded.mutexLock(&self.acceptors_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.acceptors_mutex);
        if (acceptor.previous) |previous| previous.next = acceptor.next else self.acceptors_first = acceptor.next;
        if (acceptor.next) |next| next.previous = acceptor.previous;
    }

    pub fn listen(
        self: *NetOwner,
        _: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
        address: IpAddress,
    ) ListenError!Value {
        const normalized = normalize(address);
        if (!self.policy.allows(normalized)) return error.Denied;
        const cell = try ListenerResource.create(self, .{normalized}, ListenerCell.initializeAllocation);
        // From here the cell owns the socket and the reservation; every
        // failure path closes through the one transition and drops the
        // initial reference.
        errdefer {
            cell.close();
            cell.releaseRef();
        }

        try transfers.publishScope(ListenerCell, cell, scope, ListenerCell.transferOwnership);

        return @import("port_resource.zig").Resource.create(ListenerCell, .direct, cell.identity, cell) catch
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
const Ring = @import("byte_ring.zig").Ring;

const WaitList = external.WaitList;

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
const AcceptedResource = transfers.Resource(AcceptedSocket, NetOwner, NetOwner.resourceAllocator, NetOwner.reserveAccepted, NetOwner.releaseConnection);
const ListenerResource = transfers.Resource(ListenerCell, NetOwner, NetOwner.resourceAllocator, NetOwner.reserveListener, NetOwner.releaseLive);

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
    endpoints: Endpoints,

    fn initializeAllocation(self: *AcceptedSocket, _: *NetOwner, listen_fd: posix.fd_t) error{ Pending, Resources, Io }!void {
        // SAFETY: accept initializes the address before it is read on success.
        var storage: std.Io.Threaded.PosixAddress = undefined;
        var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
        const rc = if (builtin.os.tag == .linux)
            posix.system.accept4(listen_fd, &storage.any, &length, posix.SOCK.CLOEXEC)
        else
            posix.system.accept(listen_fd, &storage.any, &length);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR, .CONNABORTED => return error.Pending,
            .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.Resources,
            else => return error.Io,
        }
        var socket: OwnedSocket = .{ .fd = @intCast(rc) };
        errdefer socket.close();
        const local = prepareAccepted(socket.fd.?) catch return error.Io;
        self.* = .{ .socket = socket, .endpoints = .{
            .local = local,
            .peer = std.Io.Threaded.addressFromPosix(&storage),
        } };
    }
    fn close(self: *AcceptedSocket) void {
        self.socket.close();
        AcceptedResource.retire(self);
    }
    fn deinit(self: *AcceptedSocket) void {
        self.close();
        AcceptedResource.destroy(self);
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
    state: State,

    const State = union(enum) {
        waiting: *AcceptedResource.Candidate,
        ready: *AcceptedSocket,
        failed: AcceptFailure,
        taken,
        closed,
    };
};

/// One bound-or-closed socket. The reference count is shared by the port
/// value, the scope member, registered waits, and the acceptor thread; the
/// terminal transition returns socket capacity after any acceptor joins.
pub const ListenerCell = struct {
    pub fn resourceInitialization(_: *ListenerCell) @import("port_resource.zig").Initialization {
        return .ready;
    }
    pub fn resourceAllocator(self: *ListenerCell) std.mem.Allocator {
        return self.allocator;
    }
    pub fn resourceClose(self: *ListenerCell) void {
        self.close();
    }
    pub fn resourceJoined(self: *ListenerCell) bool {
        return self.drained();
    }
    pub fn resourceSource(self: *ListenerCell) external.ReadinessSource {
        return self.drainSource();
    }
    pub fn resourceShutdown(self: *ListenerCell) @import("port_resource.zig").Shutdown {
        self.close();
        return if (self.drained()) .ready else .pending;
    }
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *NetOwner,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    state: State,
    ownership: external.Ownership = .provisional,
    waits: WaitList(ListenerCell) = .{},
    slots_first: ?*AcceptSlot = null,
    slots_last: ?*AcceptSlot = null,
    demand: usize = 0,
    const Bound = struct { server: std.Io.net.Server, address: IpAddress };
    const State = union(enum) {
        dormant: Bound,
        accepting: *Acceptor,
        closing: *Acceptor,
        closed: IpAddress,
    };

    // The job owns the bound socket, wake descriptors, and registry entry.
    // Registry borrowers can only signal its live pipe. Only joined retirement
    // removes the registration and destroys these resources.
    const Acceptor = struct {
        cell: *ListenerCell,
        bound: Bound,
        wake: [2]posix.fd_t,
        previous: ?*Acceptor = null,
        next: ?*Acceptor = null,
        quota_blocked: bool = false,

        fn start(cell: *ListenerCell, bound: Bound) AcceptError!void {
            const owned = try cell.allocator.create(Acceptor);
            errdefer cell.allocator.destroy(owned);
            const wake = std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch return error.Io;
            errdefer {
                std.Io.Threaded.closeFd(wake[0]);
                std.Io.Threaded.closeFd(wake[1]);
            }
            try setBlockingMode(bound.server.socket.handle, .non_blocking);
            owned.* = .{ .cell = cell, .bound = bound, .wake = wake };
            cell.owner.registerAcceptor(owned);
            errdefer cell.owner.unregisterAcceptor(owned);
            cell.retainRef();
            errdefer cell.releaseRef();
            cell.owner.executor.access().spawn(ListenerCell.acceptorMain, .{owned}, retireAcceptor) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Io, error.Closed => error.Io,
            };
            cell.state = .{ .accepting = owned };
        }

        fn destroy(self: *Acceptor) void {
            std.Io.Threaded.closeFd(self.wake[0]);
            std.Io.Threaded.closeFd(self.wake[1]);
            self.cell.allocator.destroy(self);
        }
    };

    const Waits = WaitList(ListenerCell);

    fn initializeAllocation(cell: *ListenerCell, owner: *NetOwner, address: IpAddress) ListenError!void {
        const server = try bindListening(address, owner.policy.limits.kernel_backlog);
        cell.* = .{
            .allocator = owner.allocator,
            .io = owner.io,
            .owner = owner,
            .identity = owner.next_identity.fetchAdd(1, .monotonic),
            .state = .{ .dormant = .{ .server = server, .address = server.socket.address } },
        };
    }

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
        ListenerResource.destroy(self);
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

    pub fn cancelExternalMember(self: *ListenerCell, scope: *external.ScopeIdentity) void {
        self.closeFromScope(scope);
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
    const Transfer = transfers.ScopeTransfer(ListenerCell, transferOwnership, transferLive);
    fn transferOwnership(self: *ListenerCell) *external.Ownership {
        return &self.ownership;
    }
    fn transferLive(self: *ListenerCell) bool {
        return (self.state == .dormant or self.state == .accepting) and self.ownership.live();
    }
    pub fn prepareScopeTransfer(self: *ListenerCell, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return Transfer.prepare(self, from, to);
    }
    pub fn commitScopeTransfer(self: *ListenerCell) void {
        Transfer.commit(self);
    }
    pub fn abortScopeTransfer(self: *ListenerCell) void {
        Transfer.abort(self);
    }

    /// Request close without waiting on a worker. Terminal readiness follows
    /// the acceptor join and socket closure, so a completed close permits rebind.
    pub fn close(self: *ListenerCell) void {
        self.closeFromScope(null);
    }

    fn closeFromScope(self: *ListenerCell, scope: ?*external.ScopeIdentity) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (scope) |identity| if (!self.ownership.authorizesCancellation(identity)) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return;
        };
        switch (self.state) {
            .dormant => |bound| {
                self.retainRef();
                self.finalizeCloseLocked(bound);
            },
            .accepting => |acceptor| {
                self.state = .{ .closing = acceptor };
                signalPipe(acceptor.wake[1]);
                self.changed.broadcast(blockingIo());
                std.Io.Threaded.mutexUnlock(&self.mutex);
            },
            .closing, .closed => std.Io.Threaded.mutexUnlock(&self.mutex),
        }
    }

    fn finalizeCloseLocked(self: *ListenerCell, bound: Bound) void {
        var server = bound.server;
        server.deinit(self.io);
        self.state = .{ .closed = bound.address };
        ListenerResource.retire(self);
        var slot = self.slots_first;
        while (slot) |current| : (slot = current.next) {
            if (current.state == .waiting) {
                current.state.waiting.deinit();
                current.state = .closed;
            }
        }
        self.waits.notifyLocked(self);
        var detached = self.ownership.release();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.releaseRef();
        detached.detachAll();
    }
    pub fn drained(self: *ListenerCell) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.state == .closed;
    }
    pub fn drainSource(self: *ListenerCell) external.ReadinessSource {
        return external.readinessSource(ListenerCell, self, 0);
    }

    /// The bound address, or null once closed.
    pub fn localAddress(self: *ListenerCell) ?IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.state) {
            .dormant => |bound| bound.address,
            .accepting => |acceptor| acceptor.bound.address,
            .closing, .closed => null,
        };
    }

    /// The address this listener bound, whether or not it is still bound.
    pub fn recordedAddress(self: *ListenerCell) IpAddress {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.state) {
            .dormant => |bound| bound.address,
            .accepting, .closing => |acceptor| acceptor.bound.address,
            .closed => |address| address,
        };
    }

    pub fn wakeReasonLocked(_: *ListenerCell, _: u64) external.Wake {
        return .ready;
    }

    pub fn readyLocked(self: *ListenerCell, key: u64) bool {
        if (key == 0) return self.state == .closed;
        const slot: *const AcceptSlot = @ptrFromInt(key);
        return slot.state != .waiting;
    }

    /// Link an accept slot and start the acceptor thread if it is not
    /// running. Fails before anything parks. No quota slot is taken here:
    /// the acceptor acquires one with the socket.
    pub fn beginAccept(self: *ListenerCell) AcceptError!*AcceptSlot {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        switch (self.state) {
            .dormant, .accepting => {},
            .closing, .closed => return error.Closed,
        }
        const slot = try self.allocator.create(AcceptSlot);
        errdefer self.allocator.destroy(slot);
        const candidate = try AcceptedResource.prepare(self.owner);
        errdefer candidate.deinit();
        if (self.state == .dormant) try Acceptor.start(self, self.state.dormant);
        slot.* = .{ .state = .{ .waiting = candidate } };
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
    /// socket and returns capacity. A waiting slot owns candidate storage;
    /// failed, closed, and taken slots own nothing.
    pub fn endAccept(self: *ListenerCell, slot: *AcceptSlot) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(slot.linked);
        if (slot.previous) |previous| previous.next = slot.next else self.slots_first = slot.next;
        if (slot.next) |next| next.previous = slot.previous else self.slots_last = slot.previous;
        slot.linked = false;
        std.debug.assert(self.demand != 0);
        self.demand -= 1;
        var orphan: ?*AcceptedSocket = null;
        switch (slot.state) {
            .ready => |ready| orphan = ready,
            .waiting => |candidate| candidate.deinit(),
            .failed, .closed, .taken => {},
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (orphan) |accepted| accepted.deinit();
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
    fn acceptorMain(_: *controllers.Execution, acceptor: *Acceptor) ?AcceptFailure {
        const self = acceptor.cell;
        while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            while (self.state == .accepting and self.firstWaitingLocked() == null)
                self.changed.waitUncancelable(blockingIo(), &self.mutex);
            if (self.state != .accepting) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                break;
            }
            const listen_fd = acceptor.bound.server.socket.handle;
            const wake_fd = acceptor.wake[0];
            const listen_events: i16 = if (acceptor.quota_blocked) 0 else posix.POLL.IN;
            std.Io.Threaded.mutexUnlock(&self.mutex);

            var fds = [_]posix.pollfd{
                .{ .fd = listen_fd, .events = listen_events, .revents = 0 },
                .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch return .io;
            if (fds[1].revents != 0) {
                drainPipe(wake_fd);
                std.Io.Threaded.mutexLock(&self.mutex);
                const stop = self.state != .accepting;
                acceptor.quota_blocked = false;
                std.Io.Threaded.mutexUnlock(&self.mutex);
                if (stop) break;
                continue;
            }
            if (fds[0].revents == 0) continue;
            self.acceptOneLocked(acceptor);
        }
        return null;
    }

    /// Joined retirement consumes the registry entry and descriptor bundle.
    fn exitAcceptor(acceptor: *Acceptor, failure: ?AcceptFailure) void {
        const self = acceptor.cell;
        self.owner.unregisterAcceptor(acceptor);
        std.Io.Threaded.mutexLock(&self.mutex);
        if (failure) |reason| {
            var slot = self.slots_first;
            while (slot) |current| : (slot = current.next) {
                if (current.state == .waiting) self.failSlotLocked(current, reason);
            }
            self.waits.notifyLocked(self);
        }
        const bound = acceptor.bound;
        acceptor.destroy();
        if (self.state == .closing) return self.finalizeCloseLocked(bound);
        self.state = .{ .dormant = bound };
        self.releaseRef();
        self.changed.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn acceptOneLocked(self: *ListenerCell, acceptor: *Acceptor) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const slot = self.firstWaitingLocked() orelse return;
        if (self.state != .accepting) return;
        const listen_fd = acceptor.bound.server.socket.handle;
        const accepted = slot.state.waiting.activate(.{listen_fd}, AcceptedSocket.initializeAllocation) catch |err| switch (err) {
            error.LiveLimit => {
                acceptor.quota_blocked = true;
                return;
            },
            error.Pending => return,
            error.Resources => return self.failSlotLocked(slot, .resources),
            error.Io => return self.failSlotLocked(slot, .io),
        };
        slot.state = .{ .ready = accepted };
        self.waits.notifyLocked(self);
    }

    fn failSlotLocked(self: *ListenerCell, slot: *AcceptSlot, failure: AcceptFailure) void {
        slot.state.waiting.deinit();
        slot.state = .{ .failed = failure };
        self.waits.notifyLocked(self);
    }
};

fn retireAcceptor(args: struct { *ListenerCell.Acceptor }, failure: ?AcceptFailure) void {
    ListenerCell.exitAcceptor(args[0], failure);
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

const Writers = controllers.Lane(ConnectionCell, .writer, .{ .retain = ConnectionCell.retainRef, .release = ConnectionCell.releaseRef, .write = ConnectionCell.writeTurnLocked, .notify = ConnectionCell.notifyWritersLocked, .source = ConnectionCell.writerSource });

pub const WritePermit = Writers.Writer;

const readiness_read: u64 = 1;
/// Waits for the send ring to empty, so `close` can promise that the bytes it
/// was asked to deliver have actually left for the peer.
const readiness_drain: u64 = 2;
const readiness_join: u64 = 3;

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
const ConnectionGroup = controllers.Group(ConnectionCell, ConnectionCell.StopReason, .{
    .retain = ConnectionCell.retainRef,
    .retireLocked = ConnectionCell.retireExecutionLocked,
    .ownership = ConnectionCell.transferOwnership,
    .release = ConnectionCell.releaseRef,
});

pub const ConnectionCell = struct {
    pub fn resourceInitialization(_: *ConnectionCell) @import("port_resource.zig").Initialization {
        return .ready;
    }
    pub fn resourceAllocator(self: *ConnectionCell) std.mem.Allocator {
        return self.allocator;
    }
    pub fn resourceClose(self: *ConnectionCell) void {
        self.abort();
    }
    pub fn resourceJoined(self: *ConnectionCell) bool {
        return self.joined();
    }
    pub fn resourceSource(self: *ConnectionCell) external.ReadinessSource {
        return self.joinSource();
    }
    pub fn resourceShutdown(self: *ConnectionCell) @import("port_resource.zig").Shutdown {
        self.close();
        return if (self.joined()) .ready else .pending;
    }
    allocator: std.mem.Allocator,
    instance: *@import("module_bindings.zig").Identity,
    identity: u64,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    lifecycle: Lifecycle = .prepared,
    accepted: *AcceptedSocket,
    controllers: *ConnectionGroup,
    endpoints: Endpoints,
    wake: [2]posix.fd_t,
    receive: Ring,
    send: Ring,
    output: enum { open, finishing, eof } = .open,
    reader_active: bool = false,
    /// The peer has finished sending; queued bytes remain readable.
    peer_eof: bool = false,
    /// The socket failed; set once, never cleared.
    failure: ?Failure = null,
    writers: Writers,
    waits: WaitList(ConnectionCell) = .{},
    ownership: external.Ownership = .provisional,

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
        accepted: *AcceptedSocket,
        _: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
    ) error{OutOfMemory}!AcceptProgress {
        const cell = prepare(owner, accepted) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Resources => return .resources,
        };
        cell.controllers.start(.{scope}, ConnectionCell.prepareStartup, ConnectionCell.controllerMain, ConnectionCell.abortStartup) catch |err| {
            cell.releaseRef();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ScopeClosing => .scope_closing,
                error.Io, error.Closed => .resources,
            };
        };
        const port = @import("port_resource.zig").Resource.create(ConnectionCell, .direct, cell.identity, cell) catch {
            cell.abort();
            cell.releaseRef();
            return error.OutOfMemory;
        };
        return .{ .accepted = port };
    }

    fn prepare(owner: *NetOwner, accepted: *AcceptedSocket) error{ OutOfMemory, Resources }!*ConnectionCell {
        errdefer accepted.deinit();
        const cell = try owner.allocator.create(ConnectionCell);
        errdefer owner.allocator.destroy(cell);
        const receive = try owner.allocator.alloc(u8, owner.policy.limits.receive_capacity);
        errdefer owner.allocator.free(receive);
        const send = try owner.allocator.alloc(u8, owner.policy.limits.send_capacity);
        errdefer owner.allocator.free(send);
        const wake = std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch return error.Resources;
        errdefer {
            std.Io.Threaded.closeFd(wake[0]);
            std.Io.Threaded.closeFd(wake[1]);
        }
        const execution_group = try ConnectionGroup.init(owner.allocator, owner.executor.access(), cell);
        cell.* = .{
            .allocator = owner.allocator,
            .instance = owner.instance,
            .identity = owner.next_identity.fetchAdd(1, .monotonic),
            .accepted = accepted,
            .controllers = execution_group,
            .writers = Writers.init(&cell.mutex),
            .endpoints = accepted.endpoints,
            .wake = wake,
            .receive = .{ .bytes = receive },
            .send = .{ .bytes = send },
        };
        cell.instance.retain();
        return cell;
    }

    fn prepareStartup(self: *ConnectionCell, scope: *scheduler_api.TaskScope) error{ OutOfMemory, ScopeClosing }!void {
        try transfers.publishScope(ConnectionCell, self, scope, ConnectionCell.transferOwnership);
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        switch (self.lifecycle) {
            .prepared => self.lifecycle = .running,
            .stopping, .terminal => return error.ScopeClosing,
            .running => unreachable,
        }
    }
    fn abortStartup(_: *ConnectionCell) void {}

    fn retireExecutionLocked(self: *ConnectionCell, outcome: controllers.Outcome(StopReason)) void {
        const reason: StopReason = switch (outcome) {
            .aborted => .abort,
            .completed => |reason| reason,
        };
        self.accepted.close();
        std.Io.Threaded.closeFd(self.wake[0]);
        std.Io.Threaded.closeFd(self.wake[1]);
        self.lifecycle = .{ .terminal = reason };
        self.waits.notifyLocked(self);
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
        std.debug.assert(self.waits.first == null and self.writers.empty());
        self.allocator.free(self.receive.bytes);
        self.allocator.free(self.send.bytes);
        self.accepted.deinit();
        self.controllers.deinit();
        self.instance.release();
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
    pub fn cancelExternalMember(self: *ConnectionCell, scope: *external.ScopeIdentity) void {
        self.requestStop(.abort, scope);
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

    pub fn joined(self: *ConnectionCell) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.lifecycle == .terminal;
    }

    pub fn joinSource(self: *ConnectionCell) external.ReadinessSource {
        return external.readinessSource(ConnectionCell, self, readiness_join);
    }

    pub fn beginWrite(self: *ConnectionCell) error{ OutOfMemory, Closed, Reset, Io }!*WritePermit {
        const prepared = try self.writers.prepare(self.allocator);
        errdefer prepared.discard();
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.failureLocked()) |failure| return switch (failure) {
            .closed => error.Closed,
            .reset => error.Reset,
            .io => error.Io,
        };
        if (self.output != .open) return error.Closed;
        return prepared.admitWriter(self, std.math.maxInt(usize)).?;
    }
    /// Finish only the outgoing direction. Every admitted writer retains its
    /// FIFO turn; the controller sends EOF after those writers and bytes drain.
    pub fn finishOutput(self: *ConnectionCell) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.output == .open) self.output = .finishing;
        self.signalLocked();
    }
    fn writeTurnLocked(self: *ConnectionCell, turn: bool, bytes: []const u8) WriteProgress {
        if (self.failureLocked()) |failure| return .{ .failed = failure };
        if (!turn or self.send.free() == 0) return .pending;
        const count = @min(bytes.len, self.send.free());
        self.send.push(bytes[0..count]);
        self.signalLocked();
        return .{ .written = count };
    }
    fn writerSource(self: *ConnectionCell, key: u64) external.ReadinessSource {
        return external.readinessSource(ConnectionCell, self, key);
    }
    fn notifyWritersLocked(self: *ConnectionCell) void {
        self.signalLocked();
        self.waits.notifyLocked(self);
    }

    /// Graceful close: refuse new writes, let the controller deliver queued
    /// bytes, then shut the socket down. Idempotent. Queued input is dropped
    /// because no read can observe it after this transition.
    pub fn close(self: *ConnectionCell) void {
        self.requestStop(.close, null);
    }

    /// Attach this connection to `to_erased` while leaving its current
    /// membership in place. `from_erased` must be the scope that owns it now.
    const Transfer = transfers.ScopeTransfer(ConnectionCell, transferOwnership, transferLive);
    fn transferOwnership(self: *ConnectionCell) *external.Ownership {
        return &self.ownership;
    }
    fn transferLive(self: *ConnectionCell) bool {
        return switch (self.lifecycle) {
            .prepared, .running => true,
            .stopping, .terminal => false,
        };
    }
    pub fn prepareScopeTransfer(self: *ConnectionCell, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return Transfer.prepare(self, from, to);
    }
    pub fn commitScopeTransfer(self: *ConnectionCell) void {
        Transfer.commit(self);
    }
    pub fn abortScopeTransfer(self: *ConnectionCell) void {
        Transfer.abort(self);
    }

    pub fn abort(self: *ConnectionCell) void {
        self.requestStop(.abort, null);
    }

    fn requestStop(self: *ConnectionCell, reason: StopReason, scope: ?*external.ScopeIdentity) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (scope) |identity| if (!self.ownership.authorizesCancellation(identity)) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return;
        };
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

    pub fn wakeReasonLocked(_: *ConnectionCell, _: u64) external.Wake {
        return .ready;
    }

    pub fn readyLocked(self: *ConnectionCell, key: u64) bool {
        if (key == readiness_read)
            return self.receive.len != 0 or self.peer_eof or self.failureLocked() != null;
        if (key == readiness_drain) return self.drainedLocked();
        if (key == readiness_join) return self.lifecycle == .terminal;
        const node: *const WritePermit = @ptrFromInt(key);
        return !node.linked() or (node.active() and self.send.free() != 0) or self.failureLocked() != null;
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

    fn controllerMain(_: *controllers.Execution, self: *ConnectionCell) StopReason {
        var block: [4096]u8 = undefined;
        const finalize_reason: StopReason = loop: while (true) {
            std.Io.Threaded.mutexLock(&self.mutex);
            if (self.lifecycle == .running and self.output == .finishing and self.writers.empty() and self.send.len == 0 and self.failure == null) {
                const rc = posix.system.shutdown(self.accepted.socket.fd.?, posix.SHUT.WR);
                switch (posix.errno(rc)) {
                    .SUCCESS => self.output = .eof,
                    .INTR => {
                        std.Io.Threaded.mutexUnlock(&self.mutex);
                        continue;
                    },
                    else => |code| self.noteFailureLocked(code),
                }
            }
            const interest = self.interestLocked();
            const socket_fd = self.accepted.socket.fd.?;
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
        _ = posix.system.shutdown(self.accepted.socket.fd.?, posix.SHUT.RDWR);
        return finalize_reason;
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

/// Borrow the library identity already owned by the Session's network service.
pub fn registeredInstance(access_value: *external.NetAccess) *@import("module_bindings.zig").Identity {
    return ownerFromAccess(access_value).instance;
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
    return @import("port_resource.zig").Resource.project(ListenerCell, port);
}

/// Typed projection of a connection port; null for a listener, a process
/// port, or any other value.
pub fn connectionFromValue(port: Value) ?*ConnectionCell {
    if (port != .port) return null;
    return @import("port_resource.zig").Resource.project(ConnectionCell, port);
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
        errdefer self.host.cleanup().drain();
        self.runtime_scheduler = try scheduler_api.Scheduler.init(self.host.cleanup(), .cooperative, .host);
        self.runtime_scheduler.attachRetirement();
        self.root_scope = scheduler_api.TaskScope.init(self.runtime_scheduler.worker());
        errdefer self.runtime_scheduler.deinit(&self.root_scope);
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
    defer if (permit_owned) permit.cancel();
    var offset: usize = 0;
    while (offset != bytes.len) {
        switch (permit.write(bytes[offset..])) {
            .written => |count| offset += count,
            .pending => try awaitSource(permit.source(), target),
            .failed => return error.UnexpectedWriteOutcome,
        }
    }
    permit.finish();
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

test "net: cancelled accept releases its socket and listener close awaits retirement" {
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
    // becomes ready only after the acceptor joins and the socket is closed.
    const parked = try listener.beginAccept();
    defer listener.endAccept(parked);
    listener.close();
    try awaitSource(listener.drainSource(), &target);
    try std.testing.expect(listener.drained());
    try std.testing.expectEqual(AcceptProgress.closed, try listener.pollAccept(parked, harness.runtime_scheduler.worker(), &harness.root_scope));
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
/// once whether or not the source is already ready. The drain wait below is
/// the one `net.close` parks on, so its allocation is swept here; the
/// primitive's own driver is not reachable from this cell-level harness, and
/// no longer needs to be (see the note beside the connection OOM surface).
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

test "net: writer tickets cancel queued and active writers without closing the connection" {
    // SAFETY: `init` assigns every field before any use, and `deinit` runs
    // only after a successful `init`.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{ .send_capacity = 8 });
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const peer = try connectLoopback(listener.localAddress().?.getPort());
    defer peer.close(std.testing.io);
    var target: TestTarget = .{};
    const port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(port);
    const cell = connectionFromValue(port).?;
    const first = try cell.beginWrite();
    const middle = try cell.beginWrite();
    const last = try cell.beginWrite();
    try std.testing.expect(middle.write("b") == .pending);
    try std.testing.expect(last.write("c") == .pending);
    middle.cancel();
    try std.testing.expectEqual(WriteProgress{ .written = 1 }, first.write("a"));
    // Register before promotion, proving that retiring the active writer wakes
    // its surviving successor without relying on controller scheduling.
    var source = last.source();
    defer source.deinit();
    var registration = switch (try source.register(external.wakeTarget(TestTarget, &target))) {
        .registered => |registered| registered,
        .ready => return error.UnexpectedReadiness,
    };
    first.cancel();
    target.event.waitUncancelable(std.testing.io);
    registration.cancel();
    try std.testing.expectEqual(WriteProgress{ .written = 1 }, last.write("c"));
    last.finish();
    const next = try cell.beginWrite();
    try std.testing.expectEqual(WriteProgress{ .written = 1 }, next.write("d"));
    next.finish();
    cell.close();
    var buffer: [8]u8 = undefined;
    var reader = peer.reader(std.testing.io, &buffer);
    var actual: [3]u8 = undefined;
    try reader.interface.readSliceAll(&actual);
    try std.testing.expectEqualStrings("acd", &actual);
}

test "net: output finish preserves admitted writer turns and the reverse stream" {
    // SAFETY: init fills the harness before any use or destruction.
    var harness: LoopbackHarness = undefined;
    try harness.init(std.testing.allocator, .{ .send_capacity = 8, .receive_capacity = 8 });
    defer harness.deinit();
    const listener_port = try harness.listen(.{ .ip4 = .loopback(0) });
    defer harness.host.domain().releaseValue(listener_port);
    const listener = fromValue(listener_port).?;
    const peer = try connectLoopback(listener.localAddress().?.getPort());
    defer peer.close(std.testing.io);
    var target: TestTarget = .{};
    const port = try harness.acceptOne(listener, &target);
    defer harness.host.domain().releaseValue(port);
    const cell = connectionFromValue(port).?;
    var first: ?*WritePermit = try cell.beginWrite();
    defer if (first) |permit| permit.cancel();
    var second: ?*WritePermit = try cell.beginWrite();
    defer if (second) |permit| permit.cancel();
    cell.finishOutput();
    cell.finishOutput();
    try std.testing.expectError(error.Closed, cell.beginWrite());
    try std.testing.expect(second.?.write("b") == .pending);
    try std.testing.expectEqual(WriteProgress{ .written = 1 }, first.?.write("a"));
    first.?.finish();
    first = null;
    try std.testing.expectEqual(WriteProgress{ .written = 1 }, second.?.write("b"));
    second.?.finish();
    second = null;
    var buffer: [8]u8 = undefined;
    var reader = peer.reader(std.testing.io, &buffer);
    var actual: [2]u8 = undefined;
    try reader.interface.readSliceAll(&actual);
    try std.testing.expectEqualStrings("ab", &actual);
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    var writer = peer.writer(std.testing.io, &.{});
    try writer.interface.writeAll("ok");
    try writer.interface.flush();
    try readExact(cell, &target, &actual);
    try std.testing.expectEqualStrings("ok", &actual);
    cell.close();
}
