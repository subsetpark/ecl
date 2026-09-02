//! Immutable project-lock snapshots consumed by runtime module loading.
//!
//! Synchronization owns network and mutation. This module owns only one
//! Session-scoped read of local project metadata and a bounded observation
//! cursor over the validated selections.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const reader = @import("reader.zig");
const dict = @import("dict.zig");
const storage = @import("kernel_storage.zig");
const intern = @import("intern.zig");
const project = @import("project.zig");
const pkg_catalog = @import("pkg_catalog.zig");
const modules = @import("modules.zig");

const Value = value.Value;
const max_lock_bytes = 16 * 1024 * 1024;

/// Environment values already captured by the Session host boundary. Empty
/// values are absent and never name the working directory.
pub const CacheInputs = struct {
    ecl_cache: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

const Entry = struct {
    name: []u8,
    version: []u8,
    store_dir: ?[]u8,
    requires: []pkg_catalog.PackageId = &.{},

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.store_dir) |path| allocator.free(path);
        if (self.requires.len != 0) allocator.free(self.requires);
        self.* = undefined;
    }
};

const State = union(enum) {
    valid: struct {
        entries: []Entry,
        catalog: pkg_catalog.Catalog,
        committed: []std.atomic.Value(bool),
        root_id: pkg_catalog.PackageId,
    },
    invalid: []u8,
};

const Backing = struct {
    host: *const heap.HostCleanup,
    state: State,
};
comptime {
    heap.requireSingleHostCapability(Backing);
}

/// Opaque, immutable capability. Only Session can obtain one from discovery;
/// Units can borrow it for lookup but cannot construct, retarget, or mutate it.
pub const ProjectLock = opaque {
    pub fn discover(
        host: *const heap.HostCleanup,
        io: std.Io,
        start: []const u8,
        cache: CacheInputs,
    ) error{OutOfMemory}!?*ProjectLock {
        const allocator = host.allocator();
        return switch (try project.Root.discover(allocator, io, start)) {
            .absent => null,
            .invalid => |failure| result: {
                defer failure.deinit();
                const lock_path = std.fs.path.join(
                    allocator,
                    &.{ failure.projectRoot(), "ecl.lock" },
                ) catch return error.OutOfMemory;
                defer allocator.free(lock_path);
                break :result try invalidSnapshot(
                    host,
                    "invalid project lock `{s}`: {s}",
                    .{ lock_path, failure.message() },
                );
            },
            .found => |root| result: {
                defer root.deinit();
                break :result try discoverLock(host, io, root.path(), cache);
            },
        };
    }

    pub fn lookupCursor(
        self: *const ProjectLock,
        consumer: ?pkg_catalog.PackageId,
        module_name: []const u8,
    ) LookupCursor {
        return .{ .lock = backingConst(self), .consumer = consumer, .module_name = module_name };
    }

    pub fn rootPackage(self: *const ProjectLock) ?pkg_catalog.PackageId {
        return switch (backingConst(self).state) {
            .valid => |valid| valid.root_id,
            .invalid => null,
        };
    }

    /// Enumerate only modules exported by the root package. The cursor
    /// processes one catalog entry per advance; callers may poll or cancel
    /// between entries instead of hiding a project-sized traversal in one
    /// host operation.
    pub fn rootModuleCursor(self: *const ProjectLock) RootModuleCursor {
        return .{ .lock = backingConst(self) };
    }

    pub fn artifactCommitted(
        self: *const ProjectLock,
        artifact: pkg_catalog.ArtifactId,
    ) bool {
        return switch (backingConst(self).state) {
            .valid => |valid| valid.committed[@intFromEnum(artifact)].load(.acquire),
            .invalid => false,
        };
    }

    /// Publish one artifact's registrations. The commit authority is minted
    /// only by the loading lease that guarded the artifact's verification, so
    /// this immutable observation capability cannot be turned into a way to
    /// make an unverified artifact visible.
    pub fn commitArtifact(
        self: *const ProjectLock,
        commit: modules.ArtifactCommit,
    ) void {
        switch (backingConst(self).state) {
            .valid => |valid| valid.committed[@intFromEnum(commit.artifact())].store(true, .release),
            .invalid => unreachable,
        }
    }

    pub fn artifactModules(
        self: *const ProjectLock,
        artifact: pkg_catalog.ArtifactId,
    ) []const intern.ModuleName {
        return switch (backingConst(self).state) {
            .valid => |valid| valid.catalog.artifact(artifact).modules,
            .invalid => &.{},
        };
    }

    pub fn artifactPackage(
        self: *const ProjectLock,
        artifact: pkg_catalog.ArtifactId,
    ) pkg_catalog.PackageId {
        return switch (backingConst(self).state) {
            .valid => |valid| valid.catalog.artifact(artifact).package,
            .invalid => unreachable,
        };
    }

    pub fn artifactDeclares(
        self: *const ProjectLock,
        artifact: pkg_catalog.ArtifactId,
        name: intern.ModuleName,
    ) bool {
        for (self.artifactModules(artifact)) |declared| if (declared == name) return true;
        return false;
    }

    pub fn packageDeclares(
        self: *const ProjectLock,
        package: pkg_catalog.PackageId,
        name: intern.ModuleName,
    ) bool {
        return switch (backingConst(self).state) {
            .valid => |valid| if (valid.catalog.find(intern.get(intern.moduleId(name)))) |module|
                valid.catalog.artifact(module.artifact).package == package
            else
                false,
            .invalid => false,
        };
    }

    pub fn deinit(self: *ProjectLock) void {
        const owned = backing(self);
        const allocator = owned.host.allocator();
        switch (owned.state) {
            .valid => |*valid| {
                for (valid.entries) |*entry| entry.deinit(allocator);
                allocator.free(valid.entries);
                valid.catalog.deinit();
                allocator.free(valid.committed);
            },
            .invalid => |message| allocator.free(message),
        }
        allocator.destroy(owned);
    }
};

pub const RootModuleProgress = union(enum) {
    pending,
    item: intern.ModuleName,
    complete,
    invalid: []const u8,
};

pub const RootModuleCursor = struct {
    lock: *const Backing,
    module_index: usize = 0,
    complete: bool = false,

    pub fn advance(self: *RootModuleCursor) RootModuleProgress {
        std.debug.assert(!self.complete);
        const valid = switch (self.lock.state) {
            .invalid => |message| {
                self.complete = true;
                return .{ .invalid = message };
            },
            .valid => |valid| valid,
        };
        if (self.module_index == valid.catalog.modules.len) {
            self.complete = true;
            return .complete;
        }
        const module = valid.catalog.modules[self.module_index];
        self.module_index += 1;
        const artifact = valid.catalog.artifact(module.artifact);
        if (artifact.package != valid.root_id) return .pending;
        return .{ .item = module.name };
    }

    pub fn deinit(self: *RootModuleCursor) void {
        self.* = undefined;
    }
};

pub const Match = struct {
    package: []const u8,
    store_dir: []const u8,
    relative_path: []const u8,
    package_id: pkg_catalog.PackageId,
    artifact_id: pkg_catalog.ArtifactId,
};

pub const LookupOutcome = union(enum) {
    unmatched,
    matched: Match,
    hidden: struct {
        owner: []const u8,
        consumer: []const u8,
    },
    invalid: []const u8,
};

pub const LookupProgress = union(enum) {
    pending,
    complete: LookupOutcome,
};

/// Processes at most one catalog entry per advance. AutoLoadDriver owns this
/// cursor across yields and applies its ordinary kernel poll budget.
pub const LookupCursor = struct {
    lock: *const Backing,
    consumer: ?pkg_catalog.PackageId,
    module_name: []const u8,
    module_index: usize = 0,
    complete: bool = false,

    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    pub fn advance(self: *LookupCursor) LookupProgress {
        std.debug.assert(!self.complete);
        const valid = switch (self.lock.state) {
            .invalid => |message| {
                self.complete = true;
                return .{ .complete = .{ .invalid = message } };
            },
            .valid => |valid| valid,
        };
        if (self.module_index == valid.catalog.modules.len) {
            self.complete = true;
            return .{ .complete = .unmatched };
        }
        const module = valid.catalog.modules[self.module_index];
        self.module_index += 1;
        if (std.mem.eql(u8, intern.get(intern.moduleId(module.name)), self.module_name)) {
            const artifact = valid.catalog.artifact(module.artifact);
            const package = valid.entries[@intFromEnum(artifact.package)];
            self.complete = true;
            const consumer = if (self.consumer) |consumer_id|
                &valid.entries[@intFromEnum(consumer_id)]
            else
                null;
            var visible = false;
            if (consumer) |entry| {
                for (entry.requires) |allowed| visible = visible or allowed == artifact.package;
            }
            if (!visible) return .{ .complete = .{ .hidden = .{
                .owner = package.name,
                .consumer = if (consumer) |entry| entry.name else "intrinsic context",
            } } };
            return .{ .complete = .{ .matched = .{
                .package = package.name,
                .store_dir = package.store_dir.?,
                .relative_path = artifact.relative_path,
                .package_id = artifact.package,
                .artifact_id = module.artifact,
            } } };
        }
        return .pending;
    }

    pub fn deinit(self: *LookupCursor) void {
        self.* = undefined;
    }
};

fn backing(self: *ProjectLock) *Backing {
    return @ptrCast(@alignCast(self));
}

fn backingConst(self: *const ProjectLock) *const Backing {
    return @ptrCast(@alignCast(self));
}

fn projectLock(owned: *Backing) *ProjectLock {
    return @ptrCast(@alignCast(owned));
}

fn discoverLock(
    host: *const heap.HostCleanup,
    io: std.Io,
    project_root: []const u8,
    cache: CacheInputs,
) error{OutOfMemory}!?*ProjectLock {
    const allocator = host.allocator();
    const lock_path = std.fs.path.join(allocator, &.{ project_root, "ecl.lock" }) catch
        return error.OutOfMemory;
    defer allocator.free(lock_path);
    const lock_info = std.Io.Dir.cwd().statFile(
        io,
        lock_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return try invalidSnapshot(
            host,
            "cannot inspect project lock `{s}`: {s}",
            .{ lock_path, @errorName(err) },
        ),
    };
    if (lock_info.kind != .file) return try invalidSnapshot(
        host,
        "project lock `{s}` is not a regular file",
        .{lock_path},
    );
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        lock_path,
        allocator,
        .limited(max_lock_bytes),
    ) catch |err| return try invalidSnapshot(
        host,
        "cannot read project lock `{s}`: {s}",
        .{ lock_path, @errorName(err) },
    );
    defer allocator.free(source);

    var diag: reader.Diag = .{};
    const read_result = reader.read(host, lock_path, source, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => return try invalidSnapshot(
            host,
            "invalid project lock `{s}`: {s}",
            .{ lock_path, diag.text() },
        ),
    };
    return switch (read_result) {
        .incomplete => |incomplete| invalidSnapshot(
            host,
            "invalid project lock `{s}`: {s}",
            .{ lock_path, incomplete.message },
        ),
        .complete => |complete| result: {
            var parsed = complete;
            defer parsed.deinit();
            if (parsed.values().len != 1) break :result try invalidSnapshot(
                host,
                "invalid project lock `{s}`: expected exactly one form",
                .{lock_path},
            );
            const dependencies = validateLock(host, parsed.values()[0], project_root, cache) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => break :result try invalidSnapshot(
                    host,
                    "invalid project lock `{s}`: format-1 validation failed",
                    .{lock_path},
                ),
            };
            const dependency_count = dependencies.len;
            const entries = allocator.realloc(dependencies, dependency_count + 1) catch |err| {
                deinitEntries(allocator, dependencies);
                return err;
            };
            var initialized_entries = dependency_count;
            errdefer {
                for (entries[0..initialized_entries]) |*entry| entry.deinit(allocator);
                allocator.free(entries);
            }
            const top = asDict(parsed.values()[0]) catch @panic("validated lock lost its dictionary shape");
            const root_name = ownedUtf8(
                allocator,
                field(top, "root") catch @panic("validated lock lost its root field"),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => unreachable,
            };
            const root_version = allocator.dupe(u8, "") catch |err| {
                allocator.free(root_name);
                return err;
            };
            const root_dir = allocator.dupe(u8, project_root) catch |err| {
                allocator.free(root_version);
                allocator.free(root_name);
                return err;
            };
            entries[dependency_count] = .{
                .name = root_name,
                .version = root_version,
                .store_dir = root_dir,
            };
            initialized_entries += 1;
            fillVisibility(
                allocator,
                parsed.values()[0],
                entries,
                dependency_count,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => {
                    const failure = try invalidSnapshot(
                        host,
                        "invalid project lock `{s}`: requirement visibility validation failed",
                        .{lock_path},
                    );
                    deinitEntries(allocator, entries);
                    break :result failure;
                },
            };

            const package_inputs = try allocator.alloc(pkg_catalog.PackageInput, entries.len);
            defer allocator.free(package_inputs);
            for (entries, 0..) |entry, index| {
                const store_dir = entry.store_dir orelse {
                    const failure = try invalidSnapshot(
                        host,
                        "locked package `{s}` has no package store; set ECL_CACHE, XDG_CACHE_HOME, or HOME before running `ecl pkg sync`",
                        .{entry.name},
                    );
                    deinitEntries(allocator, entries);
                    break :result failure;
                };
                if (index != entries.len - 1) {
                    const info = std.Io.Dir.cwd().statFile(
                        io,
                        store_dir,
                        .{ .follow_symlinks = false },
                    ) catch |err| {
                        const failure = try invalidSnapshot(
                            host,
                            "locked package `{s}` is missing from the package store ({s}); run `ecl pkg sync`",
                            .{ entry.name, @errorName(err) },
                        );
                        deinitEntries(allocator, entries);
                        break :result failure;
                    };
                    if (info.kind != .directory) {
                        const failure = try invalidSnapshot(
                            host,
                            "locked package `{s}` is not a real package-store directory; run `ecl pkg sync`",
                            .{entry.name},
                        );
                        deinitEntries(allocator, entries);
                        break :result failure;
                    }
                }
                package_inputs[index] = .{
                    .id = @enumFromInt(@as(u32, @intCast(index))),
                    .name = entry.name,
                    .version = entry.version,
                    .root_dir = store_dir,
                };
            }
            var catalog_diagnostic: ?[]u8 = null;
            const catalog = pkg_catalog.build(host, io, package_inputs, &catalog_diagnostic) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => {
                    defer if (catalog_diagnostic) |message| allocator.free(message);
                    const failure = try invalidSnapshot(
                        host,
                        "invalid package catalog: {s}",
                        .{catalog_diagnostic orelse "validation failed"},
                    );
                    deinitEntries(allocator, entries);
                    break :result failure;
                },
            };
            errdefer {
                var cleanup = catalog;
                cleanup.deinit();
            }
            const committed = try allocator.alloc(std.atomic.Value(bool), catalog.artifacts.len);
            errdefer allocator.free(committed);
            for (committed) |*state| state.* = .init(false);
            const owned = try allocator.create(Backing);
            owned.* = .{ .host = host, .state = .{ .valid = .{
                .entries = entries,
                .catalog = catalog,
                .committed = committed,
                .root_id = @enumFromInt(@as(u32, @intCast(entries.len - 1))),
            } } };
            break :result projectLock(owned);
        },
    };
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn fillVisibility(
    allocator: std.mem.Allocator,
    item: Value,
    entries: []Entry,
    root_index: usize,
) ValidationError!void {
    const top = try asDict(item);
    const requires = try asDict(try field(top, "requires"));
    const root_name = entries[root_index].name;
    const requirer_count: usize = @intCast(requires.length());
    for (0..requirer_count) |requirer_index| {
        const requirer_name = try ownedUtf8(allocator, dict.keyAt(requires, requirer_index));
        defer allocator.free(requirer_name);
        const entry_index = if (std.mem.eql(u8, requirer_name, root_name))
            root_index
        else
            findEntryIndex(entries[0..root_index], requirer_name) orelse return error.Invalid;
        if (entries[entry_index].requires.len != 0) return error.Invalid;
        const edges = try asDict(dict.valueAt(requires, requirer_index));
        const edge_count: usize = @intCast(edges.length());
        const visible = try allocator.alloc(pkg_catalog.PackageId, edge_count + 1);
        errdefer allocator.free(visible);
        visible[0] = @enumFromInt(@as(u32, @intCast(entry_index)));
        var built: usize = 1;
        for (0..edge_count) |edge_index| {
            const edge = try exactFields(
                dict.valueAt(edges, edge_index),
                &.{ "package", "version" },
            );
            const required_name = try ownedUtf8(allocator, try field(edge, "package"));
            defer allocator.free(required_name);
            const required_index = findEntryIndex(entries[0..root_index], required_name) orelse
                return error.Invalid;
            const required_id: pkg_catalog.PackageId = @enumFromInt(
                @as(u32, @intCast(required_index)),
            );
            for (visible[0..built]) |prior| if (prior == required_id) return error.Invalid;
            visible[built] = required_id;
            built += 1;
        }
        entries[entry_index].requires = visible;
    }
    // A selected package that requires nothing may be omitted from `requires`
    // entirely: `pkg.lock.validate` accepts such a lock and `pkg.lock.write`
    // emits one, so rejecting it here would make a canonically written lock
    // unopenable. Absence is the empty edge set, which leaves the package
    // visible only to itself.
    for (entries, 0..) |*entry, index| {
        if (entry.requires.len != 0) continue;
        const visible = try allocator.alloc(pkg_catalog.PackageId, 1);
        visible[0] = @enumFromInt(@as(u32, @intCast(index)));
        entry.requires = visible;
    }
}

fn invalidSnapshot(
    host: *const heap.HostCleanup,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!*ProjectLock {
    const allocator = host.allocator();
    const message = std.fmt.allocPrint(allocator, format, args) catch return error.OutOfMemory;
    errdefer allocator.free(message);
    const owned = try allocator.create(Backing);
    owned.* = .{ .host = host, .state = .{ .invalid = message } };
    return projectLock(owned);
}

const ValidationError = error{ Invalid, OutOfMemory };

fn validateLock(
    host: *const heap.HostCleanup,
    item: Value,
    project_root: []const u8,
    cache: CacheInputs,
) ValidationError![]Entry {
    const allocator = host.allocator();
    const header = try asDict(item);
    const vendored = switch (header.length()) {
        4 => cache_lock: {
            _ = try exactFields(item, &.{ "format", "root", "packages", "requires" });
            break :cache_lock false;
        },
        5 => vendor_lock: {
            const top = try exactFields(item, &.{ "format", "root", "store", "packages", "requires" });
            const store = try field(top, "store");
            if (store != .symbol or !std.mem.eql(u8, intern.get(store.symbol), "vendor"))
                return error.Invalid;
            break :vendor_lock true;
        },
        else => return error.Invalid,
    };
    const top = header;
    const format = try field(top, "format");
    if (format != .int or format.int != 1) return error.Invalid;
    const root_value = try field(top, "root");
    const root = try ownedUtf8(allocator, root_value);
    defer allocator.free(root);
    if (!validPackageName(root)) return error.Invalid;

    const packages_value = try field(top, "packages");
    const packages = try asDict(packages_value);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    const store_root = if (vendored)
        @as(?[]u8, std.fs.path.join(allocator, &.{ project_root, "vendor" }) catch return error.OutOfMemory)
    else
        try cacheRoot(allocator, cache);
    defer if (store_root) |path| allocator.free(path);

    const package_count: usize = @intCast(packages.length());
    try entries.ensureTotalCapacity(allocator, package_count);
    for (0..package_count) |index| {
        const name = try ownedUtf8(allocator, dict.keyAt(packages, index));
        errdefer allocator.free(name);
        if (!validPackageName(name)) return error.Invalid;
        const selection = try exactFields(
            dict.valueAt(packages, index),
            &.{ "version", "url", "hash" },
        );
        const version = try ownedUtf8(allocator, try field(selection, "version"));
        errdefer allocator.free(version);
        if (!validVersion(version)) return error.Invalid;
        const url = try ownedUtf8(allocator, try field(selection, "url"));
        defer allocator.free(url);
        if (!validUrl(url)) return error.Invalid;
        const hash = try ownedUtf8(allocator, try field(selection, "hash"));
        defer allocator.free(hash);
        if (!validHash(hash)) return error.Invalid;
        const store_dir = if (store_root) |root_path|
            std.fmt.allocPrint(
                allocator,
                "{s}{c}{s}-{s}-{s}",
                .{ root_path, std.fs.path.sep, name, version, hash[7..] },
            ) catch return error.OutOfMemory
        else
            null;
        errdefer if (store_dir) |path| allocator.free(path);
        entries.appendAssumeCapacity(.{
            .name = name,
            .version = version,
            .store_dir = store_dir,
        });
    }

    const requires = try asDict(try field(top, "requires"));
    var found_root = false;
    const requirer_count: usize = @intCast(requires.length());
    for (0..requirer_count) |requirer_index| {
        const requirer = try ownedUtf8(allocator, dict.keyAt(requires, requirer_index));
        defer allocator.free(requirer);
        if (!validPackageName(requirer)) return error.Invalid;
        found_root = found_root or std.mem.eql(u8, requirer, root);
        const minimums = try asDict(dict.valueAt(requires, requirer_index));
        const minimum_count: usize = @intCast(minimums.length());
        for (0..minimum_count) |minimum_index| {
            const alias = try ownedUtf8(allocator, dict.keyAt(minimums, minimum_index));
            defer allocator.free(alias);
            if (!validPackageName(alias)) return error.Invalid;
            const edge = try exactFields(
                dict.valueAt(minimums, minimum_index),
                &.{ "package", "version" },
            );
            const required_name = try ownedUtf8(allocator, try field(edge, "package"));
            defer allocator.free(required_name);
            if (!validPackageName(required_name)) return error.Invalid;
            const minimum = try ownedUtf8(allocator, try field(edge, "version"));
            defer allocator.free(minimum);
            if (!validVersion(minimum)) return error.Invalid;
            const selected = findEntry(entries.items, required_name) orelse return error.Invalid;
            if (versionLess(selected.version, minimum)) return error.Invalid;
        }
    }
    if (!found_root) return error.Invalid;
    return entries.toOwnedSlice(allocator);
}

fn exactFields(item: Value, names: []const []const u8) ValidationError!*value.DictHandle {
    const header = try asDict(item);
    if (header.length() != names.len) return error.Invalid;
    for (0..names.len) |index| {
        const key = dict.keyAt(header, index);
        if (key != .symbol) return error.Invalid;
        var known = false;
        for (names) |name| known = known or std.mem.eql(u8, intern.get(key.symbol), name);
        if (!known) return error.Invalid;
    }
    for (names) |name| _ = try field(header, name);
    return header;
}

fn field(header: *value.DictHandle, name: []const u8) ValidationError!Value {
    const count: usize = @intCast(header.length());
    for (0..count) |index| {
        const key = dict.keyAt(header, index);
        if (key == .symbol and std.mem.eql(u8, intern.get(key.symbol), name))
            return dict.valueAt(header, index);
    }
    return error.Invalid;
}

fn asDict(item: Value) ValidationError!*value.DictHandle {
    return switch (item) {
        .dict => |header| header,
        else => error.Invalid,
    };
}

fn ownedUtf8(allocator: std.mem.Allocator, item: Value) ValidationError![]u8 {
    if (!item.isString()) return error.Invalid;
    var cursor = storage.ToUtf8Cursor.init(allocator, item);
    defer cursor.deinit();
    while (true) switch (cursor.advance(65_536) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCodepoint => return error.Invalid,
    }) {
        .pending => {},
        .complete => |bytes| return bytes,
    };
}

/// The one host-side cache selection: `ECL_CACHE`, then `XDG_CACHE_HOME/ecl/pkg`,
/// then `HOME/.cache/ecl/pkg`; empty values are absent. Package commands and
/// runtime module loading share it so evaluated code never derives the path.
pub fn cacheRoot(allocator: std.mem.Allocator, cache: CacheInputs) error{OutOfMemory}!?[]u8 {
    if (nonEmpty(cache.ecl_cache)) |root|
        return @as(?[]u8, try allocator.dupe(u8, root));
    if (nonEmpty(cache.xdg_cache_home)) |root| return @as(
        ?[]u8,
        std.fs.path.join(allocator, &.{ root, "ecl", "pkg" }) catch return error.OutOfMemory,
    );
    if (nonEmpty(cache.home)) |root| return @as(
        ?[]u8,
        std.fs.path.join(allocator, &.{ root, ".cache", "ecl", "pkg" }) catch return error.OutOfMemory,
    );
    return null;
}

fn nonEmpty(value_bytes: ?[]const u8) ?[]const u8 {
    const bytes = value_bytes orelse return null;
    return if (bytes.len == 0) null else bytes;
}

fn findEntry(entries: []const Entry, name: []const u8) ?*const Entry {
    for (entries) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

fn findEntryIndex(entries: []const Entry, name: []const u8) ?usize {
    for (entries, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return index;
    return null;
}

/// A canonical immutable store key: `<name>-<version>-<64 lowercase hex>`.
/// The package store addresses every entry by one of these and nothing else,
/// so a key is the only path text that ever reaches a store handle.
pub fn validStoreKey(key: []const u8) bool {
    if (key.len < 67) return false;
    const hash_start = key.len - 64;
    if (key[hash_start - 1] != '-') return false;
    for (key[hash_start..]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    const prefix = key[0 .. hash_start - 1];
    for (prefix, 0..) |byte, index| {
        if (byte != '-' or index == 0 or index + 1 == prefix.len) continue;
        if (validPackageName(prefix[0..index]) and
            validVersion(prefix[index + 1 ..])) return true;
    }
    return false;
}

/// The package-name, version, hash, and URL grammar has one owner: the
/// catalog builder validates a manifest against it before a package is sealed,
/// and lock validation applies the same spellings here.
pub const validPackageName = pkg_catalog.validCanonicalName;
pub const validHash = pkg_catalog.validHash;
pub const validUrl = pkg_catalog.validUrl;
pub const validVersion = pkg_catalog.validVersion;

fn versionLess(left: []const u8, right: []const u8) bool {
    const left_hyphen = std.mem.indexOfScalar(u8, left, '-');
    const right_hyphen = std.mem.indexOfScalar(u8, right, '-');
    var left_core = std.mem.splitScalar(u8, if (left_hyphen) |index| left[0..index] else left, '.');
    var right_core = std.mem.splitScalar(u8, if (right_hyphen) |index| right[0..index] else right, '.');
    while (left_core.next()) |left_field| {
        const order = numericOrder(left_field, right_core.next().?);
        if (order != .eq) return order == .lt;
    }
    if (left_hyphen == null) return false;
    if (right_hyphen == null) return true;
    var left_ids = std.mem.splitScalar(u8, left[left_hyphen.? + 1 ..], '.');
    var right_ids = std.mem.splitScalar(u8, right[right_hyphen.? + 1 ..], '.');
    while (true) {
        const left_id = left_ids.next();
        const right_id = right_ids.next();
        if (left_id == null or right_id == null) return left_id == null and right_id != null;
        const order = identifierOrder(left_id.?, right_id.?);
        if (order != .eq) return order == .lt;
    }
}

fn numericOrder(left: []const u8, right: []const u8) std.math.Order {
    if (left.len != right.len) return std.math.order(left.len, right.len);
    return std.mem.order(u8, left, right);
}

fn identifierOrder(left: []const u8, right: []const u8) std.math.Order {
    const left_numeric = allDigits(left);
    const right_numeric = allDigits(right);
    if (left_numeric and !right_numeric) return .lt;
    if (!left_numeric and right_numeric) return .gt;
    return if (left_numeric) numericOrder(left, right) else std.mem.order(u8, left, right);
}

fn allDigits(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

test "cache root selection prefers ECL_CACHE then XDG_CACHE_HOME then HOME" {
    const allocator = std.testing.allocator;
    const direct = (try cacheRoot(allocator, .{ .ecl_cache = "/direct", .xdg_cache_home = "/xdg", .home = "/home/u" })).?;
    defer allocator.free(direct);
    try std.testing.expectEqualStrings("/direct", direct);
    const xdg = (try cacheRoot(allocator, .{ .ecl_cache = "", .xdg_cache_home = "/xdg", .home = "/home/u" })).?;
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/xdg/ecl/pkg", xdg);
    const home = (try cacheRoot(allocator, .{ .ecl_cache = "", .xdg_cache_home = "", .home = "/home/u" })).?;
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/home/u/.cache/ecl/pkg", home);
    try std.testing.expect((try cacheRoot(allocator, .{ .ecl_cache = "", .xdg_cache_home = "", .home = "" })) == null);
    try std.testing.expect((try cacheRoot(allocator, .{})) == null);
}
