//! Inert module-map validation and local source discovery. No package policy.
const std = @import("std");
const heap = @import("heap.zig");
const reader = @import("reader.zig");
const data = @import("inert_data.zig");
const dict = @import("dict.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const Value = @import("value.zig").Value;

pub const Error = error{ Invalid, OutOfMemory };
pub const ScopeId = enum(u32) { _ };
pub const ArtifactId = enum(u32) { _ };
pub const Kind = enum { ecl, native };
pub const Scope = struct {
    name: []const u8,
    root: []const u8,
    visible: []const ScopeId,
    fn deinit(self: Scope, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root);
        allocator.free(self.visible);
    }
};
pub const Artifact = struct {
    scope: ScopeId,
    path: []const u8,
    kind: Kind,
    exports: []const intern.ModuleName,
    fn deinit(self: Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.exports);
    }
};
const Backing = struct {
    allocator: std.mem.Allocator,
    local: ScopeId,
    scopes: std.ArrayList(Scope) = .empty,
    artifacts: std.ArrayList(Artifact) = .empty,
    source_bytes: usize = 0,
};

/// Only validation can mint a map. Metadata borrows last until deinit; the
/// caller owns the returned map on success and nothing on failure.
pub const Validated = opaque {
    fn fromBacking(owned: *Backing) *Validated {
        return @ptrCast(owned);
    }
    fn backing(self: *const Validated) *Backing {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn scopes(self: *const Validated) []const Scope {
        return self.backing().scopes.items;
    }
    pub fn artifacts(self: *const Validated) []const Artifact {
        return self.backing().artifacts.items;
    }
    pub fn local(self: *const Validated) ScopeId {
        return self.backing().local;
    }
    pub fn deinit(self: *Validated) void {
        const owned = self.backing();
        for (owned.scopes.items) |scope| scope.deinit(owned.allocator);
        for (owned.artifacts.items) |artifact| artifact.deinit(owned.allocator);
        owned.scopes.deinit(owned.allocator);
        owned.artifacts.deinit(owned.allocator);
        owned.allocator.destroy(owned);
    }
};

/// Find only the nearest map. Any error other than absence fails closed.
/// The returned path belongs to the caller, including explicit relative paths
/// resolved against the supplied startup directory.
pub fn discover(allocator: std.mem.Allocator, io: std.Io, start: []const u8, explicit: ?[]const u8) Error!?[]u8 {
    if (explicit) |path| return try std.fs.path.resolve(allocator, &.{ start, path });
    var directory = start;
    while (true) {
        const path = try std.fs.path.join(allocator, &.{ directory, "ecl.modules" });
        const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
            allocator.free(path);
            if (err != error.FileNotFound) return error.Invalid;
            const parent = std.fs.path.dirname(directory) orelse return null;
            if (std.mem.eql(u8, parent, directory)) return null;
            directory = parent;
            continue;
        };
        if (stat.kind != .file) {
            allocator.free(path);
            return error.Invalid;
        }
        return path;
    }
}

pub fn load(host: *const heap.HostCleanup, io: std.Io, path: []const u8) Error!*Validated {
    return loadFile(host, io, path, true);
}

fn loadFile(host: *const heap.HostCleanup, io: std.Io, path: []const u8, allow_reference: bool) Error!*Validated {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, host.allocator(), .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    };
    defer host.allocator().free(bytes);
    return validate(host, io, bytes, path, allow_reference);
}

/// Validate one complete document, resolving paths against its filename.
/// References resolve exactly once. Source discovery parses but never executes.
pub fn validate(host: *const heap.HostCleanup, io: std.Io, bytes: []const u8, path: []const u8, allow_reference: bool) Error!*Validated {
    if (bytes.len > 16 * 1024 * 1024) return error.Invalid;
    const allocator = host.allocator();
    var diag: reader.Diag = .{};
    var parsed = switch (reader.read(host, path, bytes, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    }) {
        .complete => |complete| complete,
        .incomplete => return error.Invalid,
    };
    defer parsed.deinit();
    if (parsed.values().len != 1) return error.Invalid;
    const item = parsed.values()[0];
    const top = try data.asDict(item);
    const version = try data.field(top, "format");
    if (version != .int or version.int != 1) return error.Invalid;
    const directory = std.fs.path.dirname(path) orelse return error.Invalid;
    if (top.length() == 2) {
        if (!allow_reference) return error.Invalid;
        _ = try data.exactFields(item, &.{ "format", "map" });
        const reference = try ownedText(allocator, try data.field(top, "map"));
        defer allocator.free(reference);
        const target = try std.fs.path.resolve(allocator, &.{ directory, reference });
        defer allocator.free(target);
        return loadFile(host, io, target, false);
    }
    _ = try data.exactFields(item, &.{ "format", "local", "scopes" });
    const definitions = try data.asDict(try data.field(top, "scopes"));
    if (definitions.length() == 0 or definitions.length() > 4096) return error.Invalid;
    const owned = try allocator.create(Backing);
    owned.* = .{ .allocator = allocator, .local = undefined };
    const result = Validated.fromBacking(owned);
    errdefer result.deinit();
    for (0..@intCast(definitions.length())) |index| {
        const name = try ownedText(allocator, dict.keyAt(definitions, index));
        errdefer allocator.free(name);
        for (owned.scopes.items) |scope| if (std.mem.eql(u8, name, scope.name)) return error.Invalid;
        const definition = try data.exactFields(dict.valueAt(definitions, index), &.{ "root", "visible", "sources", "artifacts" });
        const root_text = try ownedText(allocator, try data.field(definition, "root"));
        defer allocator.free(root_text);
        const root = try std.fs.path.resolve(allocator, &.{ directory, root_text });
        errdefer allocator.free(root);
        try owned.scopes.append(allocator, .{ .name = name, .root = root, .visible = &.{} });
    }
    const local_name = try ownedText(allocator, try data.field(top, "local"));
    defer allocator.free(local_name);
    owned.local = findScope(owned, local_name) orelse return error.Invalid;
    for (owned.scopes.items, 0..) |*scope, index| {
        const id: ScopeId = @enumFromInt(@as(u32, @intCast(index)));
        const definition = try data.asDict(dict.valueAt(definitions, index));
        const visibility = try sequence(try data.field(definition, "visible"));
        const visible = try allocator.alloc(ScopeId, visibility.list.length() + 1);
        errdefer allocator.free(visible);
        visible[0] = id;
        for (1..visible.len) |edge| {
            const name = try ownedText(allocator, list.atUnchecked(visibility, edge - 1));
            defer allocator.free(name);
            visible[edge] = findScope(owned, name) orelse return error.Invalid;
            for (visible[0..edge]) |prior| if (prior == visible[edge]) return error.Invalid;
        }
        scope.visible = visible;
        // Transfer the visibility buffer before fallible artifact validation.
        // Its cleanup is thereafter owned by the validated-map backing.
    }
    for (owned.scopes.items, 0..) |scope, index| {
        const id: ScopeId = @enumFromInt(@as(u32, @intCast(index)));
        const definition = try data.asDict(dict.valueAt(definitions, index));
        const artifacts = try sequence(try data.field(definition, "artifacts"));
        for (0..@intCast(artifacts.list.length())) |artifact_index| {
            const record = try data.exactFields(list.atUnchecked(artifacts, artifact_index), &.{ "path", "kind", "exports" });
            const artifact_path = try ownedText(allocator, try data.field(record, "path"));
            defer allocator.free(artifact_path);
            if (!safePath(artifact_path)) return error.Invalid;
            const kind_value = try data.field(record, "kind");
            if (kind_value != .symbol) return error.Invalid;
            const kind = std.meta.stringToEnum(Kind, intern.get(kind_value.symbol)) orelse return error.Invalid;
            const exports = try sequence(try data.field(record, "exports"));
            if (kind == .native and exports.list.length() != 1) return error.Invalid;
            const names = try allocator.alloc(intern.ModuleName, @intCast(exports.list.length()));
            defer allocator.free(names);
            for (names, 0..) |*name, name_index| {
                const spelling = try ownedText(allocator, list.atUnchecked(exports, name_index));
                defer allocator.free(spelling);
                name.* = intern.internModuleName(spelling) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidName => return error.Invalid,
                };
            }
            try addArtifact(owned, id, artifact_path, kind, names);
        }
        const patterns = try sequence(try data.field(definition, "sources"));
        if (patterns.list.length() == 0) continue;
        var globs: std.ArrayList([]u8) = .empty;
        defer {
            for (globs.items) |glob| allocator.free(glob);
            globs.deinit(allocator);
        }
        for (0..@intCast(patterns.list.length())) |pattern_index| {
            const glob = try ownedText(allocator, list.atUnchecked(patterns, pattern_index));
            errdefer allocator.free(glob);
            if (!validGlob(glob)) return error.Invalid;
            try globs.append(allocator, glob);
        }
        var root = std.Io.Dir.cwd().openDir(io, scope.root, .{ .iterate = true }) catch return error.Invalid;
        defer root.close(io);
        var walker = root.walk(allocator) catch return error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Invalid,
        }) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ecl")) continue;
            var selected = false;
            for (globs.items) |glob| selected = selected or globMatches(glob, entry.path);
            if (!selected) continue;
            if (!safePath(entry.path)) return error.Invalid;
            const source = root.readFileAlloc(io, entry.path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Invalid,
            };
            defer allocator.free(source);
            owned.source_bytes += source.len;
            if (owned.source_bytes > 64 * 1024 * 1024) return error.Invalid;
            var source_diag: reader.Diag = .{};
            var forms = switch (reader.read(host, entry.path, source, &source_diag) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Invalid,
            }) {
                .complete => |complete| complete,
                .incomplete => return error.Invalid,
            };
            defer forms.deinit();
            var names: std.ArrayList(intern.ModuleName) = .empty;
            defer names.deinit(allocator);
            var scanner: reader.DeclarationScan = .{};
            for (forms.values()) |form| if (scanner.feed(form)) |symbol| {
                const name = intern.moduleName(symbol) catch return error.Invalid;
                try names.append(allocator, name);
            };
            try addArtifact(owned, id, entry.path, .ecl, names.items);
        }
    }
    std.mem.sort(Artifact, owned.artifacts.items, {}, struct {
        fn less(_: void, a: Artifact, b: Artifact) bool {
            if (a.scope != b.scope) return @intFromEnum(a.scope) < @intFromEnum(b.scope);
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    return result;
}

fn addArtifact(owned: *Backing, scope: ScopeId, path: []const u8, kind: Kind, names: []const intern.ModuleName) Error!void {
    if (owned.artifacts.items.len == 4096) return error.Invalid;
    var count = names.len;
    for (names, 0..) |name, index| for (names[0..index]) |prior| {
        if (prior == name) return error.Invalid;
    };
    for (owned.artifacts.items) |prior| {
        count += prior.exports.len;
        if (std.mem.eql(u8, owned.scopes.items[@intFromEnum(prior.scope)].root, owned.scopes.items[@intFromEnum(scope)].root) and
            std.mem.eql(u8, prior.path, path)) return error.Invalid;
        for (names) |name| for (prior.exports) |existing| {
            if (name == existing) return error.Invalid;
        };
    }
    if (count > 65_536) return error.Invalid;
    const owned_path = try owned.allocator.dupe(u8, path);
    errdefer owned.allocator.free(owned_path);
    const exports = try owned.allocator.dupe(intern.ModuleName, names);
    errdefer owned.allocator.free(exports);
    std.mem.sort(intern.ModuleName, exports, {}, struct {
        fn less(_: void, a: intern.ModuleName, b: intern.ModuleName) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.less);
    try owned.artifacts.append(owned.allocator, .{ .scope = scope, .path = owned_path, .kind = kind, .exports = exports });
}

fn findScope(owned: *const Backing, name: []const u8) ?ScopeId {
    for (owned.scopes.items, 0..) |scope, index| if (std.mem.eql(u8, scope.name, name)) return @enumFromInt(@as(u32, @intCast(index)));
    return null;
}
fn ownedText(allocator: std.mem.Allocator, item: Value) Error![]u8 {
    const bytes = try data.ownedUtf8(allocator, item);
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > 4096) return error.Invalid;
    for (bytes) |byte| if (byte < 32 or byte == 127) return error.Invalid;
    return bytes;
}
fn sequence(item: Value) Error!Value {
    if (item != .list or item.list.length() > 65_536) return error.Invalid;
    return item;
}
fn safePath(path: []const u8) bool {
    if (!validGlob(path)) return false;
    for (path) |byte| if (byte == '*' or byte == '?' or byte == ':') return false;
    return true;
}

pub fn validGlob(glob: []const u8) bool {
    if (glob.len == 0 or glob[0] == '/' or std.mem.indexOfScalar(u8, glob, '\\') != null)
        return false;
    if (glob.len >= 2 and std.ascii.isAlphabetic(glob[0]) and glob[1] == ':') return false;
    var segments = std.mem.splitScalar(u8, glob, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return false;
        if (std.mem.indexOf(u8, segment, "**") != null and !std.mem.eql(u8, segment, "**"))
            return false;
    }
    return true;
}

pub fn globMatches(glob: []const u8, path: []const u8) bool {
    return matchSegments(glob, 0, path, 0);
}

fn matchSegments(glob: []const u8, glob_start: usize, path: []const u8, path_start: usize) bool {
    const glob_end = std.mem.indexOfScalarPos(u8, glob, glob_start, '/') orelse glob.len;
    const path_end = std.mem.indexOfScalarPos(u8, path, path_start, '/') orelse path.len;
    const glob_segment = glob[glob_start..glob_end];
    if (std.mem.eql(u8, glob_segment, "**")) {
        if (glob_end == glob.len) return true;
        const next_glob = glob_end + 1;
        var next_path = path_start;
        while (true) {
            if (matchSegments(glob, next_glob, path, next_path)) return true;
            const slash = std.mem.indexOfScalarPos(u8, path, next_path, '/') orelse return false;
            next_path = slash + 1;
        }
    }
    if (!matchSegment(glob_segment, path[path_start..path_end])) return false;
    if (glob_end == glob.len or path_end == path.len)
        return glob_end == glob.len and path_end == path.len;
    return matchSegments(glob, glob_end + 1, path, path_end + 1);
}

fn matchSegment(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star: ?usize = null;
    var star_text: usize = 0;
    while (text_index < text.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index]))
        {
            pattern_index += 1;
            text_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star = pattern_index;
            pattern_index += 1;
            star_text = text_index;
        } else if (star) |star_index| {
            pattern_index = star_index + 1;
            star_text += 1;
            text_index = star_text;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}
