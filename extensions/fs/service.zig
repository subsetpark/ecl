//! Immutable root configuration and native filesystem admission ownership.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
pub const Limits = fs.Limits;
pub const Root = fs.Root;
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Configuration = struct {
    roots: []const Root = &.{},
    limits: Limits = .{},
    /// Host-side encoding captures the ambient cwd only for the default root.
    /// The registered eager instance opens all supplied paths exactly once.
    pub fn encode(self: Configuration, allocator: std.mem.Allocator, host_io: std.Io) error{ OutOfMemory, InvalidConfig }![]u8 {
        try fs.validateLimits(self.limits);
        if (!fs.backendSupported()) return error.InvalidConfig;
        const cwd = if (self.roots.len == 0) std.process.currentPathAlloc(host_io, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidConfig,
        } else null;
        defer if (cwd) |path| allocator.free(path);
        const roots = if (cwd) |path| &[_]Root{.{ .name = "cwd", .absolute_path = path }} else self.roots;
        var length: usize = 72;
        for (roots, 0..) |root, index| {
            if (!fs.validRootName(root.name) or !std.fs.path.isAbsolute(root.absolute_path) or std.mem.indexOfScalar(u8, root.absolute_path, 0) != null) return error.InvalidConfig;
            for (roots[0..index]) |previous| if (std.mem.eql(u8, previous.name, root.name)) return error.InvalidConfig;
            length = std.math.add(usize, length, 16) catch return error.InvalidConfig;
            length = std.math.add(usize, length, root.name.len) catch return error.InvalidConfig;
            length = std.math.add(usize, length, root.absolute_path.len) catch return error.InvalidConfig;
        }
        const encoded = try allocator.alloc(u8, length);
        for ([_]u64{ 2, self.limits.max_transfer_bytes, self.limits.max_directory_entries, self.limits.max_directory_name_bytes, self.limits.max_live_operations, self.limits.max_symlink_expansions, self.limits.max_resolved_path_bytes, self.limits.max_stream_transfer_bytes, roots.len }, 0..) |field, index|
            std.mem.writeInt(u64, encoded[index * 8 ..][0..8], field, .little);
        var offset: usize = 72;
        for (roots) |root| {
            std.mem.writeInt(u64, encoded[offset..][0..8], root.name.len, .little);
            std.mem.writeInt(u64, encoded[offset + 8 ..][0..8], root.absolute_path.len, .little);
            offset += 16;
            @memcpy(encoded[offset..][0..root.name.len], root.name);
            offset += root.name.len;
            @memcpy(encoded[offset..][0..root.absolute_path.len], root.absolute_path);
            offset += root.absolute_path.len;
        }
        return encoded;
    }
};
const OwnedRoot = struct { name: []const u8, dir: std.Io.Dir };
const Candidate = struct { name: []const u8, path: []const u8 };
pub const Service = ecl.Instance(struct {
    pub const State = struct {
        memory: ?*const ecl.NativeMemory = null,
        storage: ?[]u8 = null,
        roots: ?[]OwnedRoot = null,
        initialized: usize = 0,
        limits: Limits = .{},
        mutex: std.Io.Mutex = .init,
        live: usize = 0,
        offset: usize = 72,
        phase: union(enum) {
            start,
            copying: usize,
            header,
            root,
            name: struct { candidate: Candidate, index: usize = 0 },
            path: struct { candidate: Candidate, index: usize = 0 },
            duplicates: struct { candidate: Candidate, prior: usize = 0, offset: usize = 0 },
            opening: Candidate,
            ready,
        } = .start,
        pub fn allocator(self: *State) std.mem.Allocator {
            return self.memory.?.allocator();
        }
        /// A successful reservation owns one reference and one active operation.
        pub fn reserve(self: *State) error{OutOfMemory}!?*Ticket {
            std.Io.Threaded.mutexLock(&self.mutex);
            if (self.live == self.limits.max_live_operations) {
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return null;
            }
            self.live += 1;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            const ticket = self.allocator().create(Ticket) catch |err| {
                self.releaseSlot();
                return err;
            };
            ticket.* = .{ .service = self };
            return ticket;
        }
        fn releaseSlot(self: *State) void {
            std.Io.Threaded.mutexLock(&self.mutex);
            self.live -= 1;
            std.Io.Threaded.mutexUnlock(&self.mutex);
        }
    };
    pub fn init() State {
        return .{};
    }
    pub fn initialize(state: *State, ctx: *ecl.InstanceContext) ecl.InstanceResult {
        while (ctx.consume()) switch (state.phase) {
            .start => {
                state.memory = ctx.memory();
                state.storage = try state.allocator().alloc(u8, ctx.configuration().len);
                state.phase = .{ .copying = 0 };
            },
            .copying => |offset| {
                const source = ctx.configuration();
                const count = @min(256, source.len - offset);
                @memcpy(state.storage.?[offset..][0..count], source[offset..][0..count]);
                state.phase = if (offset + count == source.len) .header else .{ .copying = offset + count };
            },
            .header => {
                const bytes = state.storage.?;
                if (bytes.len < 72 or read(bytes, 0) != 2 or !fs.backendSupported()) return error.Failed;
                state.limits = .{
                    .max_transfer_bytes = read(bytes, 8),
                    .max_directory_entries = try size(bytes, 16),
                    .max_directory_name_bytes = try size(bytes, 24),
                    .max_live_operations = try size(bytes, 32),
                    .max_symlink_expansions = try size(bytes, 40),
                    .max_resolved_path_bytes = try size(bytes, 48),
                    .max_stream_transfer_bytes = read(bytes, 56),
                };
                fs.validateLimits(state.limits) catch return error.Failed;
                const count = try size(bytes, 64);
                if (count == 0 or count > (bytes.len - 72) / 16) return error.Failed;
                state.roots = try state.allocator().alloc(OwnedRoot, count);
                state.phase = .root;
            },
            .root => {
                const bytes = state.storage.?;
                if (state.initialized == state.roots.?.len) {
                    if (state.offset != bytes.len) return error.Failed;
                    state.phase = .ready;
                    continue;
                }
                if (bytes.len - state.offset < 16) return error.Failed;
                const name_length = try size(bytes, state.offset);
                const path_length = try size(bytes, state.offset + 8);
                state.offset += 16;
                if (name_length == 0 or name_length > bytes.len - state.offset) return error.Failed;
                const name = bytes[state.offset..][0..name_length];
                state.offset += name_length;
                if (path_length == 0 or path_length > bytes.len - state.offset) return error.Failed;
                const path = bytes[state.offset..][0..path_length];
                state.offset += path_length;
                if (!std.fs.path.isAbsolute(path)) return error.Failed;
                state.phase = .{ .name = .{ .candidate = .{ .name = name, .path = path } } };
            },
            .name => |*checking| {
                const name = checking.candidate.name;
                var remaining: usize = 256;
                while (checking.index < name.len and remaining != 0) : (remaining -= 1) {
                    const byte = name[checking.index];
                    if (byte <= ' ' or byte == 0x7f or std.mem.indexOfScalar(u8, "()[]{}\"'#", byte) != null) return error.Failed;
                    const count = std.unicode.utf8ByteSequenceLength(byte) catch return error.Failed;
                    if (count > name.len - checking.index) return error.Failed;
                    _ = std.unicode.utf8Decode(name[checking.index..][0..count]) catch return error.Failed;
                    checking.index += count;
                }
                if (checking.index == name.len) {
                    const candidate = checking.candidate;
                    state.phase = .{ .path = .{ .candidate = candidate } };
                }
            },
            .path => |*checking| {
                const path = checking.candidate.path;
                const end = @min(checking.index + 256, path.len);
                if (std.mem.indexOfScalar(u8, path[checking.index..end], 0) != null) return error.Failed;
                checking.index = end;
                if (end == path.len) {
                    const candidate = checking.candidate;
                    state.phase = .{ .duplicates = .{ .candidate = candidate } };
                }
            },
            .duplicates => |*checking| {
                if (checking.prior == state.initialized) {
                    const candidate = checking.candidate;
                    state.phase = .{ .opening = candidate };
                    continue;
                }
                const name = checking.candidate.name;
                const prior = state.roots.?[checking.prior].name;
                const end = @min(checking.offset + 256, name.len);
                if (name.len != prior.len or !std.mem.eql(u8, name[checking.offset..end], prior[checking.offset..end])) {
                    checking.prior += 1;
                    checking.offset = 0;
                } else if (end == name.len) return error.Failed else checking.offset = end;
            },
            .opening => |candidate| {
                const dir = std.Io.Dir.cwd().openDir(io(), candidate.path, .{ .iterate = true }) catch return error.Failed;
                state.roots.?[state.initialized] = .{ .name = candidate.name, .dir = dir };
                state.initialized += 1;
                state.phase = .root;
            },
            .ready => return .complete,
        };
        return .pending;
    }
    pub fn retire(state: *State, ctx: *ecl.InstanceContext) bool {
        while (state.initialized != 0 and ctx.consume()) {
            state.initialized -= 1;
            state.roots.?[state.initialized].dir.close(io());
        }
        if (state.initialized != 0 or !ctx.consume()) return false;
        if (state.roots) |roots| state.allocator().free(roots);
        if (state.storage) |bytes| state.allocator().free(bytes);
        state.roots = null;
        state.storage = null;
        return true;
    }
});
fn read(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}
fn size(bytes: []const u8, offset: usize) error{Failed}!usize {
    return std.math.cast(usize, read(bytes, offset)) orelse error.Failed;
}

/// Extension-owned admission shared by an explicit reserved root and its
/// descendants. At most one operation uses a reservation at a time.
pub const Ticket = struct {
    service: *Service.State,
    refs: std.atomic.Value(usize) = .init(1),
    active: std.atomic.Value(bool) = .init(true),
    pub fn retain(self: *Ticket) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn acquire(self: *Ticket) bool {
        return !self.active.swap(true, .acq_rel);
    }
    pub fn finish(self: *Ticket) void {
        self.active.store(false, .release);
    }
    pub fn release(self: *Ticket) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const service = self.service;
        service.releaseSlot();
        service.allocator().destroy(self);
    }
};
