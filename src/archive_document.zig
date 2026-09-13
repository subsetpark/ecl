//! Scope-owned inspection of a fully validated tar document. Cursor operations
//! copy bounded output before unlocking; closure retires member storage in steps.
const std = @import("std");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const scheduler = @import("scheduler.zig");
const external = @import("external.zig");
const resource = @import("port_resource.zig");
const transfers = @import("port_transfer.zig");
const Identity = @import("module_bindings.zig").Identity;
const Value = @import("value.zig").Value;

pub const path_limit = 4096;
pub const read_limit = 65536;
pub const Kind = enum { file, directory };
pub const Member = struct { path: []u8, kind: Kind, data_offset: usize, size: usize };
pub const Members = poll.ChunkList(Member);
pub const Metadata = struct { length: usize, kind: Kind, size: usize };
const Document = struct {
    cleanup: *scheduler.ResourceCleanup,
    tar: []u8,
    members: Members,
    iterator: Members.Iterator,
    current: ?Member = null,
    position: usize = 0,
};
const Cell = struct {
    issuer: *Identity,
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    ownership: external.Ownership = .provisional,
    phase: union(enum) { unpublished, open: Document, retiring: struct { document: Document, iterator: Members.Iterator }, closed } = .unpublished,
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
        return self.allocator;
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
        const document = self.phase.open;
        self.phase = .{ .retiring = .{ .document = document, .iterator = document.members.iterator() } };
        self.retainReadiness();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        document.cleanup.retire(self, &self.retirement);
    }
    pub fn advanceRetirement(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *Cell) bool {
        const retiring = &self.phase.retiring;
        if (retiring.iterator.next()) |member| {
            allocator.free(member.path);
            return false;
        }
        retiring.document.members.retire(releases);
        allocator.free(retiring.document.tar);
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

/// The shared parser supplies validated, same-Session storage. Success consumes
/// tar and members atomically with scope publication; every failure retains both.
pub fn adopt(scope: *scheduler.TaskScope, tar: []u8, members: Members) error{ OutOfMemory, ScopeClosing }!Value {
    const cleanup = scope.scheduler.resourceCleanup();
    const issuer = try Identity.create(cleanup.allocator());
    const cell = cleanup.allocator().create(Cell) catch |err| {
        issuer.release();
        return err;
    };
    cell.* = .{ .issuer = issuer, .allocator = cleanup.allocator() };
    const item = resource.Resource.create(Cell, .direct, issuer.next(), cell) catch |err| {
        cell.releasePort();
        return err;
    };
    errdefer cleanup.releaseValue(item);
    const Publication = struct {
        cell: *Cell,
        document: Document,
        pub fn lock(p: *@This()) void {
            std.Io.Threaded.mutexLock(&p.cell.mutex);
        }
        pub fn unlock(p: *@This()) void {
            std.Io.Threaded.mutexUnlock(&p.cell.mutex);
        }
        pub fn validate(p: *@This()) bool {
            return p.cell.phase == .unpublished;
        }
        pub fn publish(p: *@This(), tokens: [16]?external.ScopeMembership) void {
            p.cell.phase = .{ .open = p.document };
            p.cell.ownership = .{ .owned = tokens[0].? };
        }
    };
    var publication: Publication = .{ .cell = cell, .document = .{ .cleanup = cleanup, .tar = tar, .members = members, .iterator = members.iterator() } };
    var incoming: [16]?external.ScopeMember = @splat(null);
    incoming[0] = external.scopeMember(Cell, cell);
    if (!try scope.scheduler.publishExternalBatch(scope, incoming, &publication)) return error.ScopeClosing;
    return item;
}

pub fn isArchive(item: Value) bool {
    return resource.Resource.project(Cell, item) != null;
}
pub fn next(item: Value, path: *[path_limit]u8) error{ Closed, Invalid }!?Metadata {
    const cell = resource.Resource.project(Cell, item) orelse return error.Closed;
    std.Io.Threaded.mutexLock(&cell.mutex);
    defer std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (cell.phase != .open) return error.Closed;
    const document = &cell.phase.open;
    const member = document.iterator.next() orelse {
        document.current = null;
        return null;
    };
    if (member.path.len > path.len or member.data_offset > document.tar.len or member.size > document.tar.len - member.data_offset) return error.Invalid;
    @memcpy(path[0..member.path.len], member.path);
    document.current = member.*;
    document.position = 0;
    return .{ .length = member.path.len, .kind = member.kind, .size = member.size };
}
pub fn read(item: Value, output: []u8) error{Closed}!usize {
    const cell = resource.Resource.project(Cell, item) orelse return error.Closed;
    std.Io.Threaded.mutexLock(&cell.mutex);
    defer std.Io.Threaded.mutexUnlock(&cell.mutex);
    if (cell.phase != .open) return error.Closed;
    const document = &cell.phase.open;
    const member = document.current orelse return 0;
    const count = @min(@min(output.len, read_limit), member.size - document.position);
    const offset = member.data_offset + document.position;
    @memcpy(output[0..count], document.tar[offset..][0..count]);
    document.position += count;
    return count;
}
