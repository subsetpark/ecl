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

pub const Discovery = union(enum) {
    absent,
    found: *Root,
    invalid: []u8,
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
                    "cannot inspect project marker `{s}`: {s}",
                    .{ manifest_path, @errorName(err) },
                ),
            };
            if (manifest_info) |info| {
                if (info.kind != .file) return invalid(
                    allocator,
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

fn invalid(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!Discovery {
    return .{ .invalid = std.fmt.allocPrint(allocator, format, args) catch return error.OutOfMemory };
}
