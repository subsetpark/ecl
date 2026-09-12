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
const Stage = @import("directory_stage.zig").Stage;
const fs = @import("filesystem_port.zig");
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
        phase: union(enum) { open: Active, sealing: Active, closing: Active, retiring: Active, closed },
        children: union(enum) { none, open: *scheduler.ExternalGroup, closed: *scheduler.ExternalGroup } = .none,
        dependency: union(enum) { independent, attached: struct { group: *scheduler.ExternalGroup, membership: external.ScopeMembership }, retired } = .independent,
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
            const authorized = if (scope) |token| self.ownership.authorizesCancellation(token) or
                (self.dependency == .attached and self.dependency.attached.membership.authorizesCancellation(token)) else true;
            const active = switch (self.phase) {
                .open, .sealing => |active| active,
                else => {
                    std.Io.Threaded.mutexUnlock(&self.mutex);
                    return;
                },
            };
            if (!authorized) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return;
            }
            self.phase = .{ .closing = active };
            const group = self.closingGroupLocked();
            const access = self.beginRetirementLocked();
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (group) |g| {
                g.close();
                g.release();
            }
            if (access) |authority| fs.retireHandle(authority, self, &self.retirement);
        }
        fn closingGroupLocked(self: *Cell) ?*scheduler.ExternalGroup {
            if (self.children != .open) return null;
            const group = self.children.open;
            group.retain();
            return group;
        }
        pub fn childrenClosed(self: *Cell) void {
            std.Io.Threaded.mutexLock(&self.mutex);
            const completed = self.children.open;
            self.children = .{ .closed = completed };
            const access = self.beginRetirementLocked();
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (access) |authority| fs.retireHandle(authority, self, &self.retirement);
        }
        fn childGroup(self: *Cell, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing }!*scheduler.ExternalGroup {
            const candidate = try scheduler.ExternalGroup.create(scope.scheduler, Cell, self);
            std.Io.Threaded.mutexLock(&self.mutex);
            if (self.phase != .open) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                candidate.release();
                return error.ScopeClosing;
            }
            const chosen = if (self.children == .open) self.children.open else candidate;
            self.children = .{ .open = chosen };
            chosen.retain();
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (chosen != candidate) candidate.release();
            return chosen;
        }
        fn attachDependency(self: *Cell, group: *scheduler.ExternalGroup) error{ OutOfMemory, ScopeClosing }!void {
            const Publication = struct {
                cell: *Cell,
                group: *scheduler.ExternalGroup,
                pub fn lock(p: *@This()) void {
                    std.Io.Threaded.mutexLock(&p.cell.mutex);
                }
                pub fn unlock(p: *@This()) void {
                    std.Io.Threaded.mutexUnlock(&p.cell.mutex);
                }
                pub fn validate(p: *@This()) bool {
                    return p.cell.phase == .open and p.cell.dependency == .independent;
                }
                pub fn publish(p: *@This(), tokens: [16]?external.ScopeMembership) void {
                    p.group.retain();
                    p.cell.dependency = .{ .attached = .{ .group = p.group, .membership = tokens[0].? } };
                }
            };
            var publication: Publication = .{ .cell = self, .group = group };
            var incoming: [16]?external.ScopeMember = @splat(null);
            incoming[0] = external.scopeMember(Cell, self);
            if (!try group.publish(incoming, &publication)) return error.ScopeClosing;
        }
        fn beginRetirementLocked(self: *Cell) ?*external.FilesystemAccess {
            if (self.phase != .closing or self.phase.closing.leases != 0 or self.children == .open) return null;
            const active = self.phase.closing;
            self.phase = .{ .retiring = active };
            self.retainReadiness();
            return active.access;
        }
        fn releaseLease(self: *Cell) void {
            std.Io.Threaded.mutexLock(&self.mutex);
            switch (self.phase) {
                .open, .sealing => |*active| active.leases -= 1,
                .closing => |*active| active.leases -= 1,
                .retiring, .closed => unreachable,
            }
            const access = self.beginRetirementLocked();
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (access) |authority| @import("filesystem_port.zig").retireHandle(authority, self, &self.retirement);
        }
        pub fn advanceRetirement(_: *heap.ReleaseDomain, _: std.mem.Allocator, self: *Cell) bool {
            if (Object == *Stage) {
                if (!self.phase.retiring.object.cleanupStep()) return false;
            } else self.phase.retiring.object.close(self.io);
            std.Io.Threaded.mutexLock(&self.mutex);
            self.phase = .closed;
            var detached = self.ownership.release();
            var dependency = self.dependency;
            self.dependency = .retired;
            const children = self.children;
            self.children = .none;
            self.waits.notifyLocked(self);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            detached.detachAll();
            if (dependency == .attached) {
                dependency.attached.membership.detach();
                dependency.attached.group.release();
            }
            if (children == .closed) children.closed.release();
            self.releaseReadiness();
            return true;
        }
        pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
            return external.WaitList(Cell).register(self, key, target);
        }
        pub fn readyLocked(self: *Cell, key: u64) bool {
            return self.phase == .closed or (key == 1 and self.phase == .sealing and self.phase.sealing.leases == 0 and self.children != .open);
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
const StageCell = Handle(*Stage);

/// Consumes the directory on success and failure. The issuer survives escaped
/// closed language values; operational scope membership ends only after close.
pub fn adopt(access: *external.FilesystemAccess, scope: *scheduler.TaskScope, dir: std.Io.Dir) error{ OutOfMemory, ScopeClosing }!Value {
    return adoptHandle(std.Io.Dir, access, scope, dir, null);
}

pub fn adoptLock(access: *external.FilesystemAccess, scope: *scheduler.TaskScope, file: std.Io.File) error{ OutOfMemory, ScopeClosing }!Value {
    return adoptHandle(std.Io.File, access, scope, file, null);
}

fn adoptHandle(comptime Object: type, access: *external.FilesystemAccess, scope: *scheduler.TaskScope, dir: Object, dependent: ?*scheduler.ExternalGroup) error{ OutOfMemory, ScopeClosing }!Value {
    const issuer = @import("filesystem_port.zig").resourceIssuer(access);
    const io = @import("filesystem_port.zig").hostIo(access);
    const ResourceCell = Handle(Object);
    const cell = issuer.allocator().create(ResourceCell) catch |err| {
        if (Object == *Stage) dir.retire() else dir.close(io);
        return err;
    };
    issuer.retain();
    cell.* = .{ .issuer = issuer, .allocator = issuer.allocator(), .io = io, .phase = .{ .open = .{ .object = dir, .access = access } } };
    transfers.publishScope(ResourceCell, cell, scope, ResourceCell.owner) catch |err| {
        cell.resourceClose();
        cell.releasePort();
        return err;
    };
    if (dependent) |group| cell.attachDependency(group) catch |err| {
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
    return resource.Resource.project(DirectoryCell, item) != null or isStage(item);
}

pub fn isStage(item: Value) bool {
    return resource.Resource.project(StageCell, item) != null;
}

/// Consumes the private stage on either outcome.
pub fn adoptStage(access: *external.FilesystemAccess, scope: *scheduler.TaskScope, stage: *Stage, parent: Value) error{ OutOfMemory, ScopeClosing }!Value {
    const group = dependentGroup(parent, scope) catch |err| {
        stage.retire();
        return err;
    };
    defer if (group) |g| g.release();
    return adoptHandle(*Stage, access, scope, stage, group);
}

/// Consumes dir on either outcome. Descendants of staging share its permanent
/// dependency group even if their task ownership is transferred.
pub fn adoptChild(access: *external.FilesystemAccess, scope: *scheduler.TaskScope, dir: std.Io.Dir, parent: Value) error{ OutOfMemory, ScopeClosing }!Value {
    const group = dependentGroup(parent, scope) catch |err| {
        dir.close(fs.hostIo(access));
        return err;
    };
    defer if (group) |g| g.release();
    return adoptHandle(std.Io.Dir, access, scope, dir, group);
}
fn dependentGroup(parent: Value, scope: *scheduler.TaskScope) error{ OutOfMemory, ScopeClosing }!?*scheduler.ExternalGroup {
    if (resource.Resource.project(StageCell, parent)) |stage| return try stage.childGroup(scope);
    const cell = resource.Resource.project(DirectoryCell, parent) orelse return null;
    std.Io.Threaded.mutexLock(&cell.mutex);
    defer std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (cell.phase != .open) return error.ScopeClosing;
    if (cell.dependency == .attached) {
        cell.dependency.attached.group.retain();
        return cell.dependency.attached.group;
    }
    return null;
}

pub const Commit = union(enum) { pending: external.ReadinessSource, failed: fs.Reason, committed, closed };
/// Seals admission before waiting. Failure retains a sealed private stage;
/// closing that value joins rollback. Success cannot subsequently roll back.
pub fn commit(item: Value) Commit {
    const cell = resource.Resource.project(StageCell, item) orelse return .closed;
    std.Io.Threaded.mutexLock(&cell.mutex);
    if (cell.phase == .open) {
        const active = cell.phase.open;
        cell.phase = .{ .sealing = active };
    }
    if (cell.phase != .sealing) {
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        return .closed;
    }
    if (cell.phase.sealing.leases != 0 or cell.children == .open) {
        const group = cell.closingGroupLocked();
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        if (group) |g| {
            g.close();
            g.release();
        }
        return .{ .pending = external.readinessSource(StageCell, cell, 1) };
    }
    // This fixed namespace operation is serialized with cancellation.
    const failure = cell.phase.sealing.object.commit();
    std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (failure) |reason| return .{ .failed = reason };
    cell.resourceClose();
    return .committed;
}

const Origin = union(enum) { directory: *DirectoryCell, stage: *StageCell };
const LeaseState = struct { origin: Origin, io: std.Io, dir: std.Io.Dir };
pub const Lease = opaque {
    fn state(self: *Lease) *LeaseState {
        return @ptrCast(@alignCast(self));
    }
    pub fn dir(self: *Lease) std.Io.Dir {
        return self.state().dir;
    }
    pub fn deinit(self: *Lease) void {
        const owned = self.state();
        owned.dir.close(owned.io);
        switch (owned.origin) {
            inline else => |origin| {
                origin.releaseLease();
                origin.resourceAllocator().destroy(owned);
                origin.releaseReadiness();
            },
        }
    }
};
pub fn acquire(item: Value) error{ OutOfMemory, Closed, Io }!*Lease {
    if (resource.Resource.project(DirectoryCell, item)) |cell| return acquireCell(DirectoryCell, cell, .{ .directory = cell });
    if (resource.Resource.project(StageCell, item)) |cell| return acquireCell(StageCell, cell, .{ .stage = cell });
    return error.Closed;
}
fn acquireCell(comptime Cell: type, cell: *Cell, origin: Origin) error{ OutOfMemory, Closed, Io }!*Lease {
    const owned = try cell.issuer.allocator().create(LeaseState);
    errdefer cell.issuer.allocator().destroy(owned);
    std.Io.Threaded.mutexLock(&cell.mutex);
    defer std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (cell.phase != .open) return error.Closed;
    const root = if (Cell == StageCell) cell.phase.open.object.directory() else cell.phase.open.object;
    const dir = root.openDir(cell.io, ".", .{ .iterate = true }) catch return error.Io;
    cell.retainReadiness();
    cell.phase.open.leases += 1;
    owned.* = .{ .origin = origin, .io = cell.io, .dir = dir };
    return @ptrCast(owned);
}
