//! Package-store authority minted only for package-command Sessions.
//!
//! The shared cache and the project-local vendor store are host-selected
//! directories. A package command names the stores it may touch with one
//! `PackageGrant`; the owner opens them once and retains the handles behind
//! the opaque `external.PackageAccess`. `pkg.store` words then address
//! entries by validated canonical store key, and no absolute host path is
//! ever passed through evaluated ECL. The vendor store is never named by a
//! path: it is always the fixed child `vendor` of the retained project handle,
//! opened without following a final symlink, so a repository cannot point it
//! elsewhere. Ordinary and embedded Sessions never construct this owner, so
//! their `pkg.store` words fail closed.

const std = @import("std");
const external = @import("external.zig");
const filesystem_port = @import("filesystem_port.zig");

pub const Store = enum {
    cache,
    vendor,

    pub fn symbol(self: Store) []const u8 {
        return @tagName(self);
    }
};

/// One project-command shape. Each variant names exactly the stores that
/// command may reach, so a grant cannot combine, say, vendor creation with
/// a command that has no project.
pub const PackageGrant = union(enum) {
    /// `tree` and `why`: project files only, no store.
    inspect,
    /// `gc`: the shared cache, never created.
    collect: struct { cache: ?[]const u8 },
    /// `verify`: present cache and vendor stores, read only.
    verify: struct { cache: ?[]const u8, project: std.Io.Dir },
    /// `add` and `sync`: the cache is created when absent; a present vendor
    /// store serves a vendored lock.
    synchronize: struct { cache: ?[]const u8, project: std.Io.Dir },
    /// `vendor`: the cache is read and the vendor store is created.
    vendor: struct { cache: ?[]const u8, project: std.Io.Dir },
};

pub const PolicyError = filesystem_port.PolicyError;

pub const PackageOwner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: ?std.Io.Dir,
    vendor: ?std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, grant: PackageGrant) PolicyError!PackageOwner {
        if (comptime !filesystem_port.backendSupported()) return error.InvalidPolicy;
        const cache: ?std.Io.Dir = switch (grant) {
            .inspect => null,
            .collect => |collect| try openCache(io, collect.cache, false),
            .verify => |verify| try openCache(io, verify.cache, false),
            .synchronize => |sync| try openCache(io, sync.cache, true),
            .vendor => |vendor| try openCache(io, vendor.cache, false),
        };
        errdefer if (cache) |dir| dir.close(io);
        const vendor: ?std.Io.Dir = switch (grant) {
            .inspect, .collect => null,
            .verify => |verify| try openVendor(io, verify.project, false),
            .synchronize => |sync| try openVendor(io, sync.project, false),
            .vendor => |vendor| try openVendor(io, vendor.project, true),
        };
        return .{ .allocator = allocator, .io = io, .cache = cache, .vendor = vendor };
    }

    pub fn deinit(self: *PackageOwner) void {
        if (self.cache) |dir| dir.close(self.io);
        if (self.vendor) |dir| dir.close(self.io);
        self.* = undefined;
    }

    pub fn access(self: *PackageOwner) *external.PackageAccess {
        return @ptrCast(self);
    }
};

/// The cache is a trusted host path the command line resolved to an absolute
/// directory once at startup; it may follow host symlinks exactly here.
fn openCache(io: std.Io, path: ?[]const u8, create: bool) PolicyError!?std.Io.Dir {
    const root = path orelse return null;
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null)
        return error.InvalidPolicy;
    if (create) {
        return std.Io.Dir.cwd().createDirPathOpen(io, root, .{ .open_options = .{ .iterate = true } }) catch
            return error.InvalidPolicy;
    }
    return std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return error.InvalidPolicy,
    };
}

pub const vendor_child_name = "vendor";

/// The vendor store is the fixed child of the retained project handle,
/// reached without following a final symlink. A project-controlled link at
/// that name is a policy failure, never a store elsewhere.
fn openVendor(io: std.Io, project: std.Io.Dir, create: bool) PolicyError!?std.Io.Dir {
    if (create) project.createDir(io, vendor_child_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.InvalidPolicy,
    };
    return project.openDir(io, vendor_child_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => if (create) error.InvalidPolicy else null,
        else => error.InvalidPolicy,
    };
}

fn ownerFromAccess(access_value: *external.PackageAccess) *PackageOwner {
    return @ptrCast(@alignCast(access_value));
}

/// The retained store handle, or null when the grant named no such store or
/// it does not exist.
pub fn storeDir(access_value: *external.PackageAccess, store: Store) ?std.Io.Dir {
    const owner = ownerFromAccess(access_value);
    return switch (store) {
        .cache => owner.cache,
        .vendor => owner.vendor,
    };
}

pub fn hostIo(access_value: *external.PackageAccess) std.Io {
    return ownerFromAccess(access_value).io;
}

test "package authority opens present stores, creates requested ones, and refuses a vendor symlink" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const io = std.testing.io;
    const base = try scratch.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const cache = try std.fs.path.join(std.testing.allocator, &.{ base, "cache", "pkg" });
    defer std.testing.allocator.free(cache);
    try scratch.dir.createDir(io, "project", .default_dir);
    var project = try scratch.dir.openDir(io, "project", .{});
    defer project.close(io);

    var absent = try PackageOwner.init(std.testing.allocator, io, .{ .collect = .{ .cache = cache } });
    try std.testing.expect(storeDir(absent.access(), .cache) == null);
    try std.testing.expect(storeDir(absent.access(), .vendor) == null);
    absent.deinit();

    var created = try PackageOwner.init(std.testing.allocator, io, .{ .synchronize = .{ .cache = cache, .project = project } });
    try std.testing.expect(storeDir(created.access(), .cache) != null);
    try std.testing.expect(storeDir(created.access(), .vendor) == null);
    created.deinit();
    _ = try scratch.dir.statFile(io, "cache/pkg", .{});

    var vendored = try PackageOwner.init(std.testing.allocator, io, .{ .vendor = .{ .cache = cache, .project = project } });
    try std.testing.expect(storeDir(vendored.access(), .vendor) != null);
    vendored.deinit();
    _ = try scratch.dir.statFile(io, "project/vendor", .{ .follow_symlinks = false });

    try std.testing.expectError(error.InvalidPolicy, PackageOwner.init(std.testing.allocator, io, .{
        .collect = .{ .cache = "relative/cache" },
    }));

    // A repository-controlled `vendor` symlink is refused for every grant
    // that would touch the vendor store, whether it points inside or outside
    // the project.
    try scratch.dir.createDir(io, "linked", .default_dir);
    try scratch.dir.deleteDir(io, "project/vendor");
    try scratch.dir.symLink(io, "../linked", "project/vendor", .{});
    try std.testing.expectError(error.InvalidPolicy, PackageOwner.init(std.testing.allocator, io, .{
        .vendor = .{ .cache = cache, .project = project },
    }));
    try std.testing.expectError(error.InvalidPolicy, PackageOwner.init(std.testing.allocator, io, .{
        .synchronize = .{ .cache = cache, .project = project },
    }));
    try std.testing.expectError(error.InvalidPolicy, PackageOwner.init(std.testing.allocator, io, .{
        .verify = .{ .cache = cache, .project = project },
    }));
    try std.testing.expectEqual(@as(usize, 0), countEntries(scratch.dir, "linked"));
}

fn countEntries(dir: std.Io.Dir, name: []const u8) usize {
    var directory = dir.openDir(std.testing.io, name, .{ .iterate = true }) catch return std.math.maxInt(usize);
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (iterator.next(std.testing.io) catch return std.math.maxInt(usize)) |_| count += 1;
    return count;
}
