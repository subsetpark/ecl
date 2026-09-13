//! Private directory publication and bounded, allocation-free rollback.
const std = @import("std");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
pub const Directory = struct {
    allocator: std.mem.Allocator,
    parent: std.Io.Dir,
    destination: []u8,
    name: [24]u8,
    phase: union(enum) { private: fs.TreeRemoval, published: std.Io.Dir },
    pub fn create(allocator: std.mem.Allocator, parent: std.Io.Dir, destination: []const u8) !Directory {
        if (destination.len == 0 or destination.len > std.Io.Dir.max_name_bytes or std.mem.indexOfScalar(u8, destination, '/') != null) return error.InvalidPath;
        const target = try allocator.dupe(u8, destination);
        errdefer allocator.free(target);
        const copy = try parent.openDir(service.io(), ".", .{});
        errdefer copy.close(service.io());
        // SAFETY: stagingDirectoryName initializes all bytes before use.
        var name: [24]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 4) : (attempts += 1) {
            _ = fs.stagingDirectoryName(service.io(), &name);
            copy.createDir(service.io(), &name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            break;
        }
        if (attempts == 4) return error.PathAlreadyExists;
        errdefer copy.deleteDir(service.io(), &name) catch |err| std.log.err("directory staging rollback: {s}", .{@errorName(err)});
        const dir = try copy.openDir(service.io(), &name, .{ .iterate = true, .follow_symlinks = false });
        return .{ .allocator = allocator, .parent = copy, .destination = target, .name = name, .phase = .{ .private = .init(service.io(), dir) } };
    }
    pub fn directory(self: *Directory) std.Io.Dir {
        return switch (self.phase) {
            .private => |*tree| tree.root,
            .published => |dir| dir,
        };
    }
    /// The resource's sealing finalizer supplies commit authority only after
    /// all admitted operations, descendants and root leases have settled.
    pub fn commit(self: *Directory) ?fs.Reason {
        const dir = switch (self.phase) {
            .private => |*tree| tree.root,
            .published => return null,
        };
        fs.renameNoReplace(service.io(), self.parent, &self.name, self.parent, self.destination) catch |err| return fs.reasonForError(err);
        self.phase = .{ .published = dir };
        return null;
    }
    /// Consumes this storage only when true. A pending step retains the entire
    /// private tree and requires no allocation or controller startup.
    pub fn retire(self: *Directory) bool {
        switch (self.phase) {
            .published => |dir| dir.close(service.io()),
            .private => |*tree| {
                switch (tree.step()) {
                    .pending => return false,
                    .failed => |reason| std.log.err("directory staging cleanup: {s}", .{reason.message()}),
                    .complete => self.parent.deleteDir(service.io(), &self.name) catch |err| switch (err) {
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
        self.parent.close(service.io());
        self.allocator.free(self.destination);
        return true;
    }
};
