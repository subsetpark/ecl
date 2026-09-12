//! Scope-owned filesystem handles share one fixed-size closure protocol.
//! Directory operations acquire independent descriptors before leaving the
//! lifetime lock; lock handles remain nominally distinct from directory roots.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const transfers = @import("port_transfer.zig");
const resource = @import("port_resource.zig");
const Identity = @import("module_bindings.zig").Identity;
const Value = @import("value.zig").Value;

fn Handle(comptime Object: type) type {
    return struct {
        const Cell = @This();
        const Active = struct { object: Object, access: *external.FilesystemAccess, leases: usize = 0 };
        issuer: *Identity,
        allocator: std.mem.Allocator,
        io: std.Io,
        refs: std.atomic.Value(usize) = .init(1),
        mutex: std.Io.Mutex = .init,
        ownership: external.Ownership = .provisional,
        phase: union(enum) { open: Active, closing: Active, retiring: Active, closed },
        retirement: heap.ReleaseDomain.Retirement = .{},
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
            const active = self.phase.open;
            self.phase = .{ .closing = active };
            const access = self.beginRetirementLocked();
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (access) |authority| @import("filesystem_port.zig").retireHandle(authority, self, &self.retirement);
        }
        fn beginRetirementLocked(self: *Cell) ?*external.FilesystemAccess {
            if (self.phase != .closing or self.phase.closing.leases != 0) return null;
            const active = self.phase.closing;
            self.phase = .{ .retiring = active };
            self.retainReadiness();
            return active.access;
        }
        fn releaseLease(self: *Cell) void {
            std.Io.Threaded.mutexLock(&self.mutex);
            switch (self.phase) {
                .open => |*active| active.leases -= 1,
                .closing => |*active| active.leases -= 1,
                .retiring, .closed => unreachable,
            }
            const access = self.beginRetirementLocked();
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (access) |authority| @import("filesystem_port.zig").retireHandle(authority, self, &self.retirement);
        }
        pub fn advanceRetirement(_: *heap.ReleaseDomain, _: std.mem.Allocator, self: *Cell) bool {
            self.phase.retiring.object.close(self.io);
            std.Io.Threaded.mutexLock(&self.mutex);
            self.phase = .closed;
            var detached = self.ownership.release();
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            detached.detachAll();
            self.releaseReadiness();
            return true;
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
}
const DirectoryCell = Handle(std.Io.Dir);

/// Consumes the directory on success and failure. The issuer survives escaped
/// closed language values; operational scope membership ends only after close.
pub fn adopt(access: *external.FilesystemAccess, scope: *scheduler.TaskScope, dir: std.Io.Dir) error{ OutOfMemory, ScopeClosing }!Value {
    return adoptHandle(std.Io.Dir, access, scope, dir);
}

pub fn adoptLock(access: *external.FilesystemAccess, scope: *scheduler.TaskScope, file: std.Io.File) error{ OutOfMemory, ScopeClosing }!Value {
    return adoptHandle(std.Io.File, access, scope, file);
}

fn adoptHandle(comptime Object: type, access: *external.FilesystemAccess, scope: *scheduler.TaskScope, dir: Object) error{ OutOfMemory, ScopeClosing }!Value {
    const issuer = @import("filesystem_port.zig").resourceIssuer(access);
    const io = @import("filesystem_port.zig").hostIo(access);
    const ResourceCell = Handle(Object);
    const cell = issuer.allocator().create(ResourceCell) catch |err| {
        dir.close(io);
        return err;
    };
    issuer.retain();
    cell.* = .{ .issuer = issuer, .allocator = issuer.allocator(), .io = io, .phase = .{ .open = .{ .object = dir, .access = access } } };
    transfers.publishScope(ResourceCell, cell, scope, ResourceCell.owner) catch |err| {
        cell.resourceClose();
        cell.releasePort();
        return err;
    };
    return resource.Resource.create(ResourceCell, .direct, issuer.next(), cell) catch |err| {
        cell.resourceClose();
        cell.releasePort();
        return err;
    };
}

pub fn isDirectory(item: Value) bool {
    return resource.Resource.project(DirectoryCell, item) != null;
}

const LeaseState = struct { origin: *DirectoryCell, io: std.Io, dir: std.Io.Dir };
pub const Lease = opaque {
    fn state(self: *Lease) *LeaseState {
        return @ptrCast(@alignCast(self));
    }
    pub fn dir(self: *Lease) std.Io.Dir {
        return self.state().dir;
    }
    pub fn deinit(self: *Lease) void {
        const owned = self.state();
        const origin = owned.origin;
        owned.dir.close(owned.io);
        origin.releaseLease();
        origin.resourceAllocator().destroy(owned);
        origin.releaseReadiness();
    }
};

pub fn acquire(item: Value) error{ OutOfMemory, Closed, Io }!*Lease {
    const cell = resource.Resource.project(DirectoryCell, item) orelse return error.Closed;
    const owned = try cell.issuer.allocator().create(LeaseState);
    errdefer cell.issuer.allocator().destroy(owned);
    std.Io.Threaded.mutexLock(&cell.mutex);
    defer std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (cell.phase != .open) return error.Closed;
    const dir = cell.phase.open.object.openDir(cell.io, ".", .{ .iterate = true }) catch return error.Io;
    cell.retainReadiness();
    cell.phase.open.leases += 1;
    owned.* = .{ .origin = cell, .io = cell.io, .dir = dir };
    return @ptrCast(owned);
}
