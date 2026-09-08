//! Borrowed resource lifecycle capabilities. The caller pins the originating
//! port value for the complete borrow; dispatch never grants backend authority
//! through an erased pointer or a language-supplied discriminator.
const std = @import("std");
const scheduler = @import("scheduler.zig");
const heap = @import("heap.zig");
const external = @import("external.zig");
const native = @import("native_port.zig");
const net = @import("net_port.zig");
const process = @import("process_port.zig");
const Value = @import("value.zig").Value;

pub const Shutdown = union(enum) { pending, ready, unsupported, failed: native.Failure };

pub const Resource = union(enum) {
    native: *native.Cell,
    listener: *net.ListenerCell,
    connection: *net.ConnectionCell,
    process: *process.ProcessCell,

    pub fn fromValue(item: Value) ?Resource {
        if (item != .port) return null;
        if (heap.portPayload(native.Cell, .resource, item.port)) |cell| return .{ .native = cell };
        if (heap.portPayload(net.ListenerCell, .resource, item.port)) |cell| return .{ .listener = cell };
        if (heap.portPayload(net.ConnectionCell, .resource, item.port)) |cell| return .{ .connection = cell };
        if (heap.portPayload(process.ProcessCell, .resource, item.port)) |cell| return .{ .process = cell };
        return null;
    }

    pub fn close(self: Resource) void {
        switch (self) {
            inline .native, .listener => |cell| cell.close(),
            .connection => |cell| cell.abort(),
            .process => |cell| cell.kill(),
        }
    }

    /// Readiness means cleanup has joined, independently of byte drainage,
    /// output EOF, or the terminal result of an operation.
    pub fn joined(self: Resource) bool {
        return switch (self) {
            .native => |cell| cell.joined(),
            .listener => |cell| cell.drained(),
            .connection => |cell| cell.joined(),
            .process => |cell| cell.termination() != null,
        };
    }

    pub fn source(self: Resource) external.ReadinessSource {
        return switch (self) {
            .native => |cell| cell.source(1),
            .listener => |cell| cell.drainSource(),
            .connection => |cell| cell.joinSource(),
            .process => |cell| cell.waitSource(),
        };
    }

    pub fn shutdown(self: Resource) Shutdown {
        switch (self) {
            .native => |cell| return switch (cell.shutdown()) {
                .pending => .pending,
                .ready => .ready,
                .unsupported => .unsupported,
                .failed => |failure| .{ .failed = failure },
            },
            inline .listener, .connection => |cell| cell.close(),
            .process => |cell| cell.terminate(),
        }
        return if (self.joined()) .ready else .pending;
    }
};

/// Only backend variants capable of staging children grant provisional
/// publication authority. Directly scope-published built-ins have no such
/// authority; retaining them in a message shares their use unchanged.
const ProvisionalResource = union(enum) {
    native: *native.Cell,

    fn fromHandle(handle: *heap.PortHandle) ?ProvisionalResource {
        const resource = Resource.fromValue(.{ .port = handle }) orelse return null;
        return switch (resource) {
            .native => |cell| .{ .native = cell },
            .listener, .connection, .process => null,
        };
    }
    fn identity(self: ProvisionalResource) usize {
        return switch (self) {
            inline else => |cell| @intFromPtr(cell),
        };
    }
    fn mutex(self: ProvisionalResource) *std.Io.Mutex {
        return switch (self) {
            inline else => |cell| &cell.mutex,
        };
    }
    fn groupLocked(self: ProvisionalResource) ?*scheduler.ExternalGroup {
        return switch (self) {
            inline else => |cell| switch (cell.publication) {
                .published => null,
                .provisional => |group| group,
            },
        };
    }
    fn ownershipLocked(self: ProvisionalResource) *external.Ownership {
        return switch (self) {
            inline else => |cell| &cell.ownership,
        };
    }
    fn markPublishedLocked(self: ProvisionalResource) void {
        switch (self) {
            inline else => |cell| cell.publication = .published,
        }
    }
    fn member(self: ProvisionalResource) external.ScopeMember {
        return switch (self) {
            inline else => |cell| external.scopeMember(@TypeOf(cell.*), cell),
        };
    }
    fn retainReadiness(self: ProvisionalResource) void {
        switch (self) {
            inline else => |cell| cell.retainReadiness(),
        }
    }
    fn releaseReadiness(self: ProvisionalResource) void {
        switch (self) {
            inline else => |cell| cell.releaseReadiness(),
        }
    }
};

/// A fixed ownership snapshot for an atomic message/result claim. Snapshot
/// pins and replaced memberships retire only after all publication locks are
/// released. A changed snapshot is rejected; it never grants stale authority.
const PublicationState = struct {
    const Entry = struct {
        cell: ProvisionalResource,
        group: *scheduler.ExternalGroup,
        membership: bool,
        detached: external.Ownership.Detached = .{},
    };
    host: *const heap.HostCleanup,
    entries: [16]?Entry = .{null} ** 16,
    groups: [16]?*scheduler.ExternalGroup = .{null} ** 16,
    count: usize = 0,
    group_count: usize = 0,
    published: bool = false,

    fn capability(self: *PublicationState) *Publication {
        return @ptrCast(self);
    }

    fn init(host: *const heap.HostCleanup, attachments: []const ?*heap.PortHandle) error{Overflow}!PublicationState {
        var result: PublicationState = .{ .host = host };
        errdefer result.releasePins();
        for (attachments) |attachment| {
            const cell = ProvisionalResource.fromHandle(attachment orelse continue) orelse continue;
            var duplicate = false;
            for (result.entries[0..result.count]) |entry| if (entry.?.cell.identity() == cell.identity()) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            std.Io.Threaded.mutexLock(cell.mutex());
            if (cell.groupLocked() == null) {
                std.Io.Threaded.mutexUnlock(cell.mutex());
                continue;
            }
            if (result.count == result.entries.len) {
                std.Io.Threaded.mutexUnlock(cell.mutex());
                return error.Overflow;
            }
            const group = cell.groupLocked().?;
            const membership = cell.ownershipLocked().* == .owned;
            cell.retainReadiness();
            group.retain();
            std.Io.Threaded.mutexUnlock(cell.mutex());
            var index = result.count;
            while (index != 0 and result.entries[index - 1].?.cell.identity() > cell.identity()) : (index -= 1)
                result.entries[index] = result.entries[index - 1];
            result.entries[index] = .{ .cell = cell, .group = group, .membership = membership };
            result.count += 1;
            var group_index: usize = 0;
            while (group_index < result.group_count and @intFromPtr(result.groups[group_index].?) < @intFromPtr(group)) : (group_index += 1) {}
            if (group_index < result.group_count and result.groups[group_index].? == group) continue;
            var move = result.group_count;
            while (move > group_index) : (move -= 1) result.groups[move] = result.groups[move - 1];
            result.groups[group_index] = group;
            result.group_count += 1;
        }
        return result;
    }
    pub fn members(self: *@This()) [16]?external.ScopeMember {
        var result: [16]?external.ScopeMember = .{null} ** 16;
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.?.membership) result[index] = entry.?.cell.member();
        }
        return result;
    }
    pub fn lock(self: *@This()) void {
        for (self.groups[0..self.group_count]) |group| group.?.lockPublication();
        for (self.entries[0..self.count]) |entry| std.Io.Threaded.mutexLock(entry.?.cell.mutex());
    }
    pub fn unlock(self: *@This()) void {
        var index = self.count;
        while (index != 0) {
            index -= 1;
            std.Io.Threaded.mutexUnlock(self.entries[index].?.cell.mutex());
        }
        index = self.group_count;
        while (index != 0) {
            index -= 1;
            self.groups[index].?.unlockPublication();
        }
    }
    pub fn validate(self: *@This()) bool {
        for (self.groups[0..self.group_count]) |group| if (!group.?.acceptsPublicationLocked()) return false;
        for (self.entries[0..self.count]) |entry| {
            const item = entry.?;
            if (item.cell.groupLocked() != item.group) return false;
            if (item.membership) {
                if (item.cell.ownershipLocked().* != .owned or !item.group.ownsMembership(item.cell.ownershipLocked().owned)) return false;
            } else if (item.cell.ownershipLocked().* != .none) return false;
        }
        return true;
    }
    pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
        for (self.entries[0..self.count], 0..) |*entry, index| {
            const item = &entry.*.?;
            if (item.membership) {
                item.detached = item.cell.ownershipLocked().release();
                item.cell.ownershipLocked().* = .{ .owned = tokens[index].? };
            }
            item.cell.markPublishedLocked();
        }
        self.published = true;
    }
    fn releasePins(self: *@This()) void {
        for (self.entries[0..self.count]) |*entry| {
            const item = &entry.*.?;
            item.detached.detachAll();
            if (self.published) item.group.release();
            item.group.release();
            item.cell.releaseReadiness();
        }
    }
};

pub const Publication = opaque {
    fn state(self: *@This()) *PublicationState {
        return @ptrCast(@alignCast(self));
    }
    pub fn init(host: *const heap.HostCleanup, attachments: []const ?*heap.PortHandle) error{ OutOfMemory, Overflow }!?*Publication {
        var snapshot = try PublicationState.init(host, attachments);
        errdefer snapshot.releasePins();
        if (snapshot.count == 0) return null;
        const owned = try host.allocator().create(PublicationState);
        owned.* = snapshot;
        return owned.capability();
    }
    pub fn members(self: *@This()) [16]?external.ScopeMember {
        return self.state().members();
    }
    pub fn lock(self: *@This()) void {
        self.state().lock();
    }
    pub fn unlock(self: *@This()) void {
        self.state().unlock();
    }
    pub fn validate(self: *@This()) bool {
        return self.state().validate();
    }
    pub fn publish(self: *@This(), tokens: [16]?external.ScopeMembership) void {
        self.state().publish(tokens);
    }
    pub fn deinit(self: *@This()) void {
        const owned = self.state();
        owned.releasePins();
        owned.host.allocator().destroy(owned);
    }
};
