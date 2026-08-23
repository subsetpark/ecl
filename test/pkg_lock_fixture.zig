//! Explicit local project/store fixture for built-binary lock-tier acceptance.
const std = @import("std");

pub const package_hash = "sha256-385df64d4c1510e029721e8c3f880b91ac879cca636beba399f87f85fa385e7a";

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.testing.TmpDir,
    root: [:0]u8,
    cache: []u8,
    search: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, install: bool) !Fixture {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const root = try directory.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(root);
        try directory.dir.createDir(io, "project", .default_dir);
        try directory.dir.createDir(io, "project/nested", .default_dir);
        try directory.dir.createDir(io, "cache", .default_dir);
        try directory.dir.createDir(io, "path", .default_dir);
        try directory.dir.writeFile(io, .{
            .sub_path = "project/ecl.pkg",
            .data = "{'format 1 'name \"root\" 'version \"0.1.0\" 'requires {\"smoke\" {'version \"1.0.0\" 'url \"https://127.0.0.1:1/unreachable.tgz\" 'hash \"" ++ package_hash ++ "\"}}}\n",
        });
        try directory.dir.writeFile(io, .{
            .sub_path = "project/ecl.lock",
            .data = "{'format 1\n 'root \"root\"\n 'packages\n {\"smoke\" {'version \"1.0.0\" 'url \"https://127.0.0.1:1/unreachable.tgz\" 'hash \"" ++ package_hash ++ "\"}}\n 'requires\n {\"root\" {\"smoke\" \"1.0.0\"}}}\n",
        });
        if (install) {
            try directory.dir.createDir(
                io,
                "cache/smoke-1.0.0-" ++ package_hash[7..],
                .default_dir,
            );
            try directory.dir.writeFile(io, .{
                .sub_path = "cache/smoke-1.0.0-" ++ package_hash[7..] ++ "/smoke.ecl",
                .data = "((42) 'answer def) 'smoke @defm\n",
            });
            try directory.dir.writeFile(io, .{
                .sub_path = "cache/smoke-1.0.0-" ++ package_hash[7..] ++ "/ecl.pkg",
                .data = "{'format 1 'name \"smoke\" 'version \"1.0.0\" 'requires {}}\n",
            });
            try directory.dir.writeFile(io, .{
                .sub_path = "cache/smoke-1.0.0-" ++ package_hash[7..] ++ "/.ecl-package.tgz",
                .data = "sealed fixture\n",
            });
        }
        try directory.dir.writeFile(io, .{
            .sub_path = "path/smoke.ecl",
            .data = "((99) 'answer def) 'smoke @defm\n",
        });
        const cache = try std.fs.path.join(allocator, &.{ root, "cache" });
        errdefer allocator.free(cache);
        const search = try std.fs.path.join(allocator, &.{ root, "path" });
        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .root = root,
            .cache = cache,
            .search = search,
        };
    }

    pub fn openNested(self: *Fixture) !std.Io.Dir {
        return self.directory.dir.openDir(self.io, "project/nested", .{});
    }

    pub fn deinit(self: *Fixture) void {
        self.allocator.free(self.search);
        self.allocator.free(self.cache);
        self.allocator.free(self.root);
        self.directory.cleanup();
        self.* = undefined;
    }
};
