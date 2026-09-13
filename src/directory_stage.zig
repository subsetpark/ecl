//! Private directory publication and allocation-free rollback. All namespace
//! operations remain relative to the retained destination parent.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const fs = @import("filesystem_port.zig");
const Identity = @import("module_bindings.zig").Identity;

const State = struct {
    issuer: *Identity,
    access: *external.FilesystemAccess,
    io: std.Io,
    parent: std.Io.Dir,
    destination: []u8,
    name: [24]u8,
    phase: union(enum) { private: fs.TreeRemoval, published: std.Io.Dir },
    retirement: heap.ReleaseDomain.Retirement = .{},

    fn destroy(self: *State) void {
        const issuer = self.issuer;
        self.parent.close(self.io);
        issuer.allocator().free(self.destination);
        issuer.allocator().destroy(self);
        issuer.release();
    }

    pub fn advanceRetirement(_: *heap.ReleaseDomain, _: std.mem.Allocator, self: *State) bool {
        return fromState(self).cleanupStep();
    }
};

fn fromState(state: *State) *Stage {
    return @ptrCast(state);
}

pub const Stage = opaque {
    fn state(self: *Stage) *State {
        return @ptrCast(@alignCast(self));
    }

    /// Opens a private sibling. Failure leaves no application-visible target;
    /// success owns both directory handles and the complete publication name.
    pub fn create(access: *external.FilesystemAccess, parent: std.Io.Dir, destination: []const u8) !*Stage {
        if ((fs.classifyPath(destination) catch return error.InvalidPath) != .entry or
            std.mem.indexOfScalar(u8, destination, '/') != null or destination.len > std.Io.Dir.max_name_bytes)
            return error.InvalidPath;
        const issuer = fs.resourceIssuer(access);
        const allocator = issuer.allocator();
        const io = fs.hostIo(access);
        const owned = try allocator.create(State);
        errdefer allocator.destroy(owned);
        const target = try allocator.dupe(u8, destination);
        errdefer allocator.free(target);
        const parent_copy = try parent.openDir(io, ".", .{});
        errdefer parent_copy.close(io);
        var name: [24]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 4) : (attempts += 1) {
            _ = fs.stagingDirectoryName(io, &name);
            parent_copy.createDir(io, &name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            break;
        }
        if (attempts == 4) return error.PathAlreadyExists;
        errdefer parent_copy.deleteDir(io, &name) catch |err| std.log.err("directory staging rollback: {s}", .{@errorName(err)});
        const dir = try parent_copy.openDir(io, &name, .{ .iterate = true, .follow_symlinks = false });
        issuer.retain();
        owned.* = .{ .issuer = issuer, .access = access, .io = io, .parent = parent_copy, .destination = target, .name = name, .phase = .{ .private = .init(io, dir) } };
        return fromState(owned);
    }

    pub fn directory(self: *Stage) std.Io.Dir {
        return switch (self.state().phase) {
            .private => |*tree| tree.root,
            .published => |dir| dir,
        };
    }

    /// The owning resource must first stop admission and join its leases and
    /// dependent directories. Failure retains the unpublished directory.
    pub fn commit(self: *Stage) ?fs.Reason {
        const owned = self.state();
        const dir = switch (owned.phase) {
            .private => |*tree| tree.root,
            .published => return null,
        };
        fs.renameNoReplace(owned.io, owned.parent, &owned.name, owned.parent, owned.destination) catch |err| return fs.reasonForError(err);
        owned.phase = .{ .published = dir };
        return null;
    }

    /// Consumes the stage when complete. One bounded step; no allocation is
    /// needed even when resource publication failed because of memory pressure.
    pub fn cleanupStep(self: *Stage) bool {
        const owned = self.state();
        switch (owned.phase) {
            .published => |dir| dir.close(owned.io),
            .private => |*tree| {
                switch (tree.step()) {
                    .pending => return false,
                    .failed => |reason| std.log.err("directory staging cleanup: {s}", .{reason.message()}),
                    .complete => owned.parent.deleteDir(owned.io, &owned.name) catch |err| switch (err) {
                        error.DirNotEmpty => {
                            tree.restart();
                            return false;
                        },
                        error.FileNotFound => {},
                        else => std.log.err("directory staging cleanup: {s}", .{@errorName(err)}),
                    },
                }
                tree.deinit();
            },
        }
        owned.destroy();
        return true;
    }

    /// Consumes an unadopted stage into the issuing Session's cleanup queue.
    pub fn retire(self: *Stage) void {
        const owned = self.state();
        fs.retireHandle(owned.access, owned, &owned.retirement);
    }
};
