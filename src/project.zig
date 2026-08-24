//! Nominal discovery of the nearest ECL project root.
//!
//! Session startup and the package CLI share this one first-marker walk. The
//! handle exposes only the discovered path as metadata and carries no file or
//! mutation authority.
const std = @import("std");

const Backing = struct {
    allocator: std.mem.Allocator,
    path: []u8,
};

const InvalidBacking = struct {
    allocator: std.mem.Allocator,
    project_root: []u8,
    message: []u8,
};

pub const Discovery = union(enum) {
    absent,
    found: *Root,
    invalid: *InvalidDiscovery,
};

/// Owned description of a failed candidate project root. Consumers derive
/// their own sibling paths from `projectRoot`; discovery does not guess which
/// project artifact they intended to open.
pub const InvalidDiscovery = opaque {
    pub fn projectRoot(self: *const InvalidDiscovery) []const u8 {
        return invalidBackingConst(self).project_root;
    }

    pub fn message(self: *const InvalidDiscovery) []const u8 {
        return invalidBackingConst(self).message;
    }

    pub fn deinit(self: *InvalidDiscovery) void {
        const owned = invalidBacking(self);
        const allocator = owned.allocator;
        allocator.free(owned.message);
        allocator.free(owned.project_root);
        allocator.destroy(owned);
    }
};

pub const Root = opaque {
    pub fn discover(
        allocator: std.mem.Allocator,
        io: std.Io,
        start: []const u8,
    ) error{OutOfMemory}!Discovery {
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(io, start, allocator) catch |err|
            return invalid(
                allocator,
                start,
                "cannot resolve project start `{s}`: {s}",
                .{ start, @errorName(err) },
            );
        defer allocator.free(absolute);

        var current: []const u8 = absolute;
        while (true) {
            const manifest_path = std.fs.path.join(allocator, &.{ current, "ecl.pkg" }) catch
                return error.OutOfMemory;
            defer allocator.free(manifest_path);
            const manifest_info = std.Io.Dir.cwd().statFile(
                io,
                manifest_path,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return invalid(
                    allocator,
                    current,
                    "cannot inspect project marker `{s}`: {s}",
                    .{ manifest_path, @errorName(err) },
                ),
            };
            if (manifest_info) |info| {
                if (info.kind != .file) return invalid(
                    allocator,
                    current,
                    "project marker `{s}` is not a regular file",
                    .{manifest_path},
                );
                const owned = try allocator.create(Backing);
                errdefer allocator.destroy(owned);
                owned.* = .{
                    .allocator = allocator,
                    .path = try allocator.dupe(u8, current),
                };
                return .{ .found = root(owned) };
            }

            const parent = std.fs.path.dirname(current) orelse return .absent;
            if (std.mem.eql(u8, parent, current)) return .absent;
            current = parent;
        }
    }

    pub fn path(self: *const Root) []const u8 {
        return backingConst(self).path;
    }

    pub fn deinit(self: *Root) void {
        const owned = backing(self);
        const allocator = owned.allocator;
        allocator.free(owned.path);
        allocator.destroy(owned);
    }
};

fn backing(self: *Root) *Backing {
    return @ptrCast(@alignCast(self));
}

fn backingConst(self: *const Root) *const Backing {
    return @ptrCast(@alignCast(self));
}

fn root(owned: *Backing) *Root {
    return @ptrCast(@alignCast(owned));
}

fn invalidBacking(self: *InvalidDiscovery) *InvalidBacking {
    return @ptrCast(@alignCast(self));
}

fn invalidBackingConst(self: *const InvalidDiscovery) *const InvalidBacking {
    return @ptrCast(@alignCast(self));
}

fn invalidDiscovery(owned: *InvalidBacking) *InvalidDiscovery {
    return @ptrCast(@alignCast(owned));
}

fn invalid(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!Discovery {
    const owned = try allocator.create(InvalidBacking);
    errdefer allocator.destroy(owned);
    const root_path = try allocator.dupe(u8, project_root);
    errdefer allocator.free(root_path);
    const message = std.fmt.allocPrint(allocator, format, args) catch return error.OutOfMemory;
    owned.* = .{
        .allocator = allocator,
        .project_root = root_path,
        .message = message,
    };
    return .{ .invalid = invalidDiscovery(owned) };
}
