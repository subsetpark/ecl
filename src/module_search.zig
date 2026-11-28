//! Module search: the source files the search path supplies. Each entry is
//! a directory scanned recursively, skipping dot-directories; every `.ecl`
//! file is parsed without running it, and its literal top-level module
//! declarations are the modules it may register. Nothing here loads a
//! module.
const std = @import("std");
const heap = @import("heap.zig");
const reader = @import("reader.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");

/// Bounds on one scan. Passing one fails the lookup that started the scan,
/// and every later one, with the reason.
pub const max_file_bytes = 16 * 1024 * 1024;
pub const max_source_bytes = 64 * 1024 * 1024;
pub const max_files = 4096;
pub const max_exports = 65_536;
pub const max_entries = 1_000_000;

/// A file's index in its catalog, which a Session publishes once.
pub const FileId = enum(u32) { _ };

const File = struct {
    /// The entry joined with the path beneath it.
    path: []u8,
    /// The search-path entry the file was found under; zero is the project
    /// root.
    entry: u32,
    /// Sorted by id.
    exports: []intern.ModuleName,
    /// Whether a load of the file completed, after which it is never loaded
    /// again by a lookup or by `ecl test`.
    loaded: std.atomic.Value(bool) = .init(false),
    id: FileId = @fromBackingInt(0),

    fn deinit(self: *File, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.exports);
    }
};

/// One file the search found: what it may register, and where it is.
pub const Source = opaque {
    fn file(self: *const Source) *File {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn path(self: *const Source) []const u8 {
        return self.file().path;
    }
    pub fn id(self: *const Source) FileId {
        return self.file().id;
    }
    pub fn declared(self: *const Source) []const intern.ModuleName {
        return self.file().exports;
    }
    pub fn loaded(self: *const Source) bool {
        return self.file().loaded.load(.acquire);
    }
    /// Whether the file declares `name`. Exports are capped, so this takes
    /// at most 17 comparisons.
    pub fn exports(self: *const Source, name: intern.ModuleName) bool {
        const names = self.file().exports;
        var low: usize = 0;
        var high: usize = names.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (names[middle] == name) return true;
            if (@backingInt(names[middle]) < @backingInt(name)) low = middle + 1 else high = middle;
        }
        return false;
    }
};

/// What a name finds: no file, one, or the first two of several that
/// declare it.
pub const Found = union(enum) {
    none,
    file: *const Source,
    duplicate: [2]*const Source,
};

/// The result of one scan, immutable once published.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    files: []File,
    /// Why the scan stopped, when it passed a bound.
    failure: ?[]u8 = null,

    fn deinit(self: *Catalog) void {
        for (self.files) |*item| item.deinit(self.allocator);
        self.allocator.free(self.files);
        if (self.failure) |text| self.allocator.free(text);
        self.allocator.destroy(self);
    }

    pub fn source(self: *const Catalog, id: FileId) *const Source {
        return @ptrCast(&self.files[@backingInt(id)]);
    }

    /// The files declaring `name`. Bounded by the export cap.
    pub fn find(self: *const Catalog, name: intern.ModuleName) Found {
        var first: ?*const Source = null;
        for (self.files) |*item| {
            const found: *const Source = @ptrCast(item);
            if (!found.exports(name)) continue;
            if (first) |prior| return .{ .duplicate = .{ prior, found } };
            first = found;
        }
        return if (first) |only| .{ .file = only } else .none;
    }

    /// Records that a file's load completed. Only a loading lease keyed to
    /// the file mints the authority.
    pub fn markLoaded(self: *const Catalog, commit: @import("modules.zig").ArtifactCommit) void {
        self.files[@backingInt(commit.artifact())].loaded.store(true, .release);
    }

    /// The project root's own files that declare a module, in path order:
    /// what `ecl test` loads. Tests are declared only in module bodies, and
    /// a file that declares no module is a script, which is never run.
    pub fn projectSources(self: *const Catalog) ProjectSourceCursor {
        return .{ .catalog = self };
    }
};

pub const ProjectSourceProgress = union(enum) { pending, item: *const Source, complete };
pub const ProjectSourceCursor = struct {
    catalog: *const Catalog,
    index: usize = 0,
    pub fn advance(self: *ProjectSourceCursor) ProjectSourceProgress {
        if (self.index == self.catalog.files.len) return .complete;
        const item = &self.catalog.files[self.index];
        self.index += 1;
        if (item.entry != 0 or item.exports.len == 0) return .pending;
        return .{ .item = @ptrCast(item) };
    }
};

/// A Session's search path and the one catalog scanned from it. Fibers
/// borrow both for the Session's life.
pub const Search = struct {
    host: *const heap.HostCleanup,
    io: std.Io,
    entries: [][]u8,
    catalog: std.atomic.Value(?*Catalog) = .init(null),

    /// The project root is `root` when given, and otherwise the nearest
    /// ancestor of `start` holding `ecl.pkg`, or `start` itself. The path
    /// is the root, its `.ecl/packages`, then each `ECL_PATH` entry.
    pub fn init(host: *const heap.HostCleanup, io: std.Io, start: []const u8, root: ?[]const u8, ecl_path: ?[]const u8) error{OutOfMemory}!*Search {
        const allocator = host.allocator();
        var entries: std.ArrayList([]u8) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry);
            entries.deinit(allocator);
        }
        const project = if (root) |explicit| try allocator.dupe(u8, explicit) else try projectRoot(allocator, io, start);
        entries.append(allocator, project) catch |err| {
            allocator.free(project);
            return err;
        };
        const packages = try std.fs.path.join(allocator, &.{ project, ".ecl", "packages" });
        entries.append(allocator, packages) catch |err| {
            allocator.free(packages);
            return err;
        };
        if (ecl_path) |list| {
            var parts = std.mem.splitScalar(u8, list, std.fs.path.delimiter);
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                // The real path, so a file the project root also reaches has
                // one spelling; an entry that cannot be resolved is kept as
                // given, and supplies nothing.
                var real: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const resolved = if (std.Io.Dir.cwd().realPathFile(io, part, &real)) |length| real[0..length] else |_| part;
                const owned = try allocator.dupe(u8, resolved);
                entries.append(allocator, owned) catch |err| {
                    allocator.free(owned);
                    return err;
                };
            }
        }
        const result = try allocator.create(Search);
        result.* = .{ .host = host, .io = io, .entries = entries.toOwnedSlice(allocator) catch |err| {
            allocator.destroy(result);
            return err;
        } };
        return result;
    }

    fn projectRoot(allocator: std.mem.Allocator, io: std.Io, start: []const u8) error{OutOfMemory}![]u8 {
        var directory = start;
        while (true) {
            const manifest = try std.fs.path.join(allocator, &.{ directory, "ecl.pkg" });
            defer allocator.free(manifest);
            if (std.Io.Dir.cwd().statFile(io, manifest, .{})) |stat| {
                if (stat.kind == .file) return allocator.dupe(u8, directory);
            } else |_| {}
            const parent = std.fs.path.dirname(directory) orelse break;
            if (std.mem.eql(u8, parent, directory)) break;
            directory = parent;
        }
        return allocator.dupe(u8, start);
    }

    pub fn deinit(self: *Search) void {
        const allocator = self.host.allocator();
        if (self.catalog.load(.acquire)) |catalog| catalog.deinit();
        for (self.entries) |entry| allocator.free(entry);
        allocator.free(self.entries);
        allocator.destroy(self);
    }

    /// The published catalog, or null before the first scan completes.
    pub fn current(self: *const Search) ?*const Catalog {
        return self.catalog.load(.acquire);
    }

    /// Publishes a completed scan unless another completed first, and
    /// returns the one published. Consumes `built`.
    pub fn publish(self: *Search, built: *Catalog) *const Catalog {
        if (self.catalog.cmpxchgStrong(null, built, .acq_rel, .acquire)) |winner| {
            built.deinit();
            return winner.?;
        }
        return built;
    }

    pub fn scan(self: *const Search) ScanCursor {
        return .{ .search = self };
    }
};

/// One scan of the search path. Each advance inspects one directory entry,
/// reading and parsing at most one bounded file.
pub const ScanCursor = struct {
    search: *const Search,
    entry: u32 = 0,
    walk: ?Walk = null,
    files: std.ArrayList(File) = .empty,
    source_bytes: usize = 0,
    export_count: usize = 0,
    visited: usize = 0,

    const Walk = struct {
        directory: std.Io.Dir,
        walker: std.Io.Dir.SelectiveWalker,
    };

    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    pub fn deinit(self: *ScanCursor) void {
        const allocator = self.search.host.allocator();
        self.closeWalk();
        for (self.files.items) |*item| item.deinit(allocator);
        self.files.deinit(allocator);
        self.* = undefined;
    }

    fn io(self: *const ScanCursor) std.Io {
        return self.search.io;
    }

    fn closeWalk(self: *ScanCursor) void {
        if (self.walk) |*walk| {
            walk.walker.deinit();
            walk.directory.close(self.io());
        }
        self.walk = null;
    }

    /// Completes with a catalog its caller owns until it publishes it.
    pub fn advance(self: *ScanCursor) error{OutOfMemory}!poll.Progress(*Catalog) {
        const allocator = self.search.host.allocator();
        const host_io = self.io();
        if (self.walk == null) {
            if (self.entry == self.search.entries.len) return .{ .complete = try self.finish(null) };
            const entry = self.search.entries[self.entry];
            const directory = std.Io.Dir.cwd().openDir(host_io, entry, .{ .iterate = true }) catch {
                // An entry that is absent or not a directory supplies nothing.
                self.entry += 1;
                return .pending;
            };
            const walker = directory.walkSelectively(allocator) catch |err| {
                directory.close(host_io);
                return err;
            };
            self.walk = .{ .directory = directory, .walker = walker };
            return .pending;
        }
        const walk = &self.walk.?;
        const found = walk.walker.next(host_io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // An unreadable directory supplies nothing; the walker has
            // already left it.
            else => return .pending,
        } orelse {
            self.closeWalk();
            self.entry += 1;
            return .pending;
        };
        self.visited += 1;
        if (self.visited > max_entries)
            return .{ .complete = try self.failFmt("module search inspected more than 1000000 directory entries", .{}) };
        switch (found.kind) {
            .directory => {
                if (found.basename.len != 0 and found.basename[0] == '.') return .pending;
                walk.walker.enter(host_io, found) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
                return .pending;
            },
            .file => {},
            else => return .pending,
        }
        const name = found.path;
        if (!std.mem.endsWith(u8, name, ".ecl")) return .pending;
        const text = walk.directory.readFileAlloc(host_io, name, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return .{ .complete = try self.failFmt("module search source `{s}` exceeds 16 MiB", .{name}) },
            // A file that cannot be read declares nothing.
            else => return .pending,
        };
        defer allocator.free(text);
        self.source_bytes += text.len;
        if (self.source_bytes > max_source_bytes)
            return .{ .complete = try self.failFmt("module search sources exceed 64 MiB at `{s}`", .{name}) };
        var diag: reader.Diag = .{};
        var forms = switch (reader.read(self.search.host, name, text, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A file that does not parse declares nothing; loading it
            // reports why.
            else => return self.add(name, &.{}),
        }) {
            .complete => |complete| complete,
            .incomplete => return self.add(name, &.{}),
        };
        defer forms.deinit();
        var names: std.ArrayList(intern.ModuleName) = .empty;
        defer names.deinit(allocator);
        var scanner: reader.DeclarationScan = .{};
        for (forms.values()) |form| if (scanner.feed(form)) |symbol| {
            const module = intern.moduleName(symbol) catch continue;
            for (names.items) |prior| {
                if (prior == module) break;
            } else try names.append(allocator, module);
        };
        return self.add(name, names.items);
    }

    fn add(self: *ScanCursor, relative: []const u8, names: []const intern.ModuleName) error{OutOfMemory}!poll.Progress(*Catalog) {
        const allocator = self.search.host.allocator();
        if (self.files.items.len == max_files)
            return .{ .complete = try self.failFmt("module search found more than 4096 files at `{s}`", .{relative}) };
        self.export_count += names.len;
        if (self.export_count > max_exports)
            return .{ .complete = try self.failFmt("module search found more than 65536 module declarations at `{s}`", .{relative}) };
        const path = try std.fs.path.join(allocator, &.{ self.search.entries[self.entry], relative });
        errdefer allocator.free(path);
        // A file two entries reach, as when an entry lies beneath the project
        // root, is one file.
        for (self.files.items) |prior| if (std.mem.eql(u8, prior.path, path)) {
            allocator.free(path);
            self.export_count -= names.len;
            return .pending;
        };
        const exports = try allocator.dupe(intern.ModuleName, names);
        errdefer allocator.free(exports);
        std.mem.sort(intern.ModuleName, exports, {}, struct {
            fn less(_: void, a: intern.ModuleName, b: intern.ModuleName) bool {
                return @backingInt(a) < @backingInt(b);
            }
        }.less);
        try self.files.append(allocator, .{ .path = path, .entry = self.entry, .exports = exports });
        return .pending;
    }

    fn failFmt(self: *ScanCursor, comptime format: []const u8, args: anytype) error{OutOfMemory}!*Catalog {
        const text = try std.fmt.allocPrint(self.search.host.allocator(), format, args);
        return self.finish(text);
    }

    /// Takes the files found, ordered by entry and then path, which fixes
    /// which two files a duplicate reports. Consumes `failure`.
    fn finish(self: *ScanCursor, failure: ?[]u8) error{OutOfMemory}!*Catalog {
        const allocator = self.search.host.allocator();
        errdefer if (failure) |text| allocator.free(text);
        self.closeWalk();
        const result = try allocator.create(Catalog);
        errdefer allocator.destroy(result);
        const files = try self.files.toOwnedSlice(allocator);
        std.mem.sort(File, files, {}, struct {
            fn less(_: void, a: File, b: File) bool {
                if (a.entry != b.entry) return a.entry < b.entry;
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);
        for (files, 0..) |*item, index| item.id = @fromBackingInt(@intCast(index));
        result.* = .{ .allocator = allocator, .files = files, .failure = failure };
        return result;
    }
};

comptime {
    heap.requireSingleHostCapability(Search);
}
