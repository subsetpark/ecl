//! Scope-owned directories. Operations acquire independent descriptors before
//! leaving the lifetime lock, so resource closure cannot invalidate a resolver.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const transfers = @import("port_transfer.zig");
const resource = @import("port_resource.zig");
const Identity = @import("module_bindings.zig").Identity;
const Value = @import("value.zig").Value;

const Cell = struct {
    issuer: *Identity,
    allocator: std.mem.Allocator,
    io: std.Io,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    ownership: external.Ownership = .provisional,
    phase: union(enum) { open: std.Io.Dir, closing, closed },
    waits: external.WaitList(Cell) = .{},
    const Transfer = transfers.ScopeTransfer(Cell, owner, live);
    fn owner(self: *Cell) *external.Ownership {
        return &self.ownership;
    }
    fn live(self: *Cell) bool {
        return self.phase == .open;
    }
    pub fn resourceAllocator(self: *Cell) std.mem.Allocator {
        return self.issuer.allocator();
    }
    pub fn resourceInitialization(_: *Cell) resource.Initialization {
        return .ready;
    }
    pub fn resourceShutdown(_: *Cell) resource.Shutdown {
        return .unsupported;
    }
    pub fn resourceJoined(self: *Cell) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.phase == .closed;
    }
    pub fn resourceSource(self: *Cell) external.ReadinessSource {
        return external.readinessSource(Cell, self, 0);
    }
    pub fn retainReadiness(self: *Cell) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Cell) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const issuer = self.issuer;
        issuer.allocator().destroy(self);
        issuer.release();
    }
    pub fn retainExternalMember(self: *Cell) void {
        self.retainReadiness();
    }
    pub fn releaseExternalMember(self: *Cell) void {
        self.releaseReadiness();
    }
    pub fn releasePort(self: *Cell) void {
        self.releaseReadiness();
    }
    pub fn cancelExternalMember(self: *Cell, scope: *external.ScopeIdentity) void {
        self.close(scope);
    }
    pub fn resourceClose(self: *Cell) void {
        self.close(null);
    }
    fn close(self: *Cell, scope: ?*external.ScopeIdentity) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.phase != .open or (if (scope) |s| !self.ownership.authorizesCancellation(s) else false)) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return;
        }
        const dir = self.phase.open;
        self.phase = .closing;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        dir.close(self.io);
        std.Io.Threaded.mutexLock(&self.mutex);
        self.phase = .closed;
        var detached = self.ownership.release();
        self.waits.notifyLocked(self);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        detached.detachAll();
    }
    pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Cell).register(self, key, target);
    }
    pub fn readyLocked(self: *Cell, _: u64) bool {
        return self.phase == .closed;
    }
    pub fn wakeReasonLocked(_: *Cell, _: u64) external.Wake {
        return .ready;
    }
    pub fn prepareScopeTransfer(self: *Cell, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
        return Transfer.prepare(self, from, to);
    }
    pub fn commitScopeTransfer(self: *Cell) void {
        Transfer.commit(self);
    }
    pub fn abortScopeTransfer(self: *Cell) void {
        Transfer.abort(self);
    }
};

/// Consumes the directory on success and failure. The issuer survives escaped
/// closed language values; operational scope membership ends only after close.
pub fn adopt(issuer: *Identity, io: std.Io, scope: *scheduler.TaskScope, dir: std.Io.Dir) error{ OutOfMemory, ScopeClosing }!Value {
    const cell = issuer.allocator().create(Cell) catch |err| {
        dir.close(io);
        return err;
    };
    issuer.retain();
    cell.* = .{ .issuer = issuer, .allocator = issuer.allocator(), .io = io, .phase = .{ .open = dir } };
    transfers.publishScope(Cell, cell, scope, Cell.owner) catch |err| {
        cell.resourceClose();
        cell.releasePort();
        return err;
    };
    return resource.Resource.create(Cell, .direct, issuer.next(), cell) catch |err| {
        cell.resourceClose();
        cell.releasePort();
        return err;
    };
}

pub fn isDirectory(item: Value) bool {
    return resource.Resource.project(Cell, item) != null;
}

const LeaseState = struct { issuer: *Identity, io: std.Io, dir: std.Io.Dir };
pub const Lease = opaque {
    fn state(self: *Lease) *LeaseState {
        return @ptrCast(@alignCast(self));
    }
    pub fn dir(self: *Lease) std.Io.Dir {
        return self.state().dir;
    }
    pub fn deinit(self: *Lease) void {
        const owned = self.state();
        const issuer = owned.issuer;
        owned.dir.close(owned.io);
        issuer.allocator().destroy(owned);
        issuer.release();
    }
};

pub fn acquire(item: Value) error{ OutOfMemory, Closed, Io }!*Lease {
    const cell = resource.Resource.project(Cell, item) orelse return error.Closed;
    const owned = try cell.issuer.allocator().create(LeaseState);
    errdefer cell.issuer.allocator().destroy(owned);
    std.Io.Threaded.mutexLock(&cell.mutex);
    defer std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (cell.phase != .open) return error.Closed;
    const dir = cell.phase.open.openDir(cell.io, ".", .{ .iterate = true }) catch return error.Io;
    cell.issuer.retain();
    owned.* = .{ .issuer = cell.issuer, .io = cell.io, .dir = dir };
    return @ptrCast(owned);
}
