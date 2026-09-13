//! Session-owned module-map metadata and lexical artifact publication state.
//! No project manifests, package identities, locks, stores, or fetching policy.
const std = @import("std");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const modules = @import("modules.zig");
const module_map = @import("module_map.zig");
pub const ScopeId = module_map.ScopeId;
pub const ArtifactId = module_map.ArtifactId;

const Backing = struct {
    host: *const heap.HostCleanup,
    map: *module_map.Validated,
    sources: []SourceState,
    start_dir: []u8,
};
const SourceState = struct {
    owner: *Backing,
    artifact: ArtifactId,
    absolute_path: []u8,
    private_registry: modules.Registry,
    committed: std.atomic.Value(bool) = .init(false),
};
comptime {
    heap.requireSingleHostCapability(Backing);
}

/// Lexical file identity. Private registrations remain owned by this artifact.
pub const SourceScope = opaque {
    fn state(self: *const SourceScope) *SourceState {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn scopeId(self: *const SourceScope) ScopeId {
        const source = self.state();
        return source.owner.map.artifacts()[@intFromEnum(source.artifact)].scope;
    }
    pub fn location(self: *const SourceScope) Match {
        const source = self.state();
        const artifact = source.owner.map.artifacts()[@intFromEnum(source.artifact)];
        const scope = source.owner.map.scopes()[@intFromEnum(artifact.scope)];
        return .{ .scope_name = scope.name, .root = scope.root, .relative_path = artifact.path, .scope_id = artifact.scope, .artifact_id = source.artifact, .kind = artifact.kind };
    }
    pub fn registry(self: *const SourceScope) *modules.Registry {
        return &self.state().private_registry;
    }
    pub fn exports(self: *const SourceScope, name: intern.ModuleName) bool {
        const source = self.state();
        const names = source.owner.map.artifacts()[@intFromEnum(source.artifact)].exports;
        var low: usize = 0;
        var high: usize = names.len;
        // Validation caps exports at 65,536; membership takes at most 17 comparisons.
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (names[middle] == name) return true;
            if (@intFromEnum(names[middle]) < @intFromEnum(name)) low = middle + 1 else high = middle;
        }
        return false;
    }
};

/// Only Session owns this capability. Cursors borrow it for their whole lifetime.
pub const Snapshot = opaque {
    fn backing(self: *const Snapshot) *Backing {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    fn fromBacking(owned: *Backing) *Snapshot {
        return @ptrCast(owned);
    }
    /// Consumes the complete validated map on success; failure leaves it with the caller.
    /// All runtime allocations derive from the Session's host cleanup owner.
    pub fn fromMap(host: *const heap.HostCleanup, map: *module_map.Validated, start: []const u8) error{OutOfMemory}!*Snapshot {
        const allocator = host.allocator();
        const owned = try allocator.create(Backing);
        errdefer allocator.destroy(owned);
        const start_dir = try allocator.dupe(u8, start);
        errdefer allocator.free(start_dir);
        const sources = try allocator.alloc(SourceState, map.artifacts().len);
        errdefer allocator.free(sources);
        var built: usize = 0;
        errdefer for (sources[0..built]) |*source| {
            source.private_registry.deinit();
            allocator.free(source.absolute_path);
        };
        for (sources, map.artifacts(), 0..) |*source, artifact, index| {
            const absolute = try std.fs.path.join(allocator, &.{ map.scopes()[@intFromEnum(artifact.scope)].root, artifact.path });
            errdefer allocator.free(absolute);
            source.* = .{ .owner = owned, .artifact = @enumFromInt(@as(u32, @intCast(index))), .absolute_path = absolute, .private_registry = try modules.Registry.init(host) };
            built += 1;
        }
        owned.* = .{ .host = host, .map = map, .sources = sources, .start_dir = start_dir };
        return fromBacking(owned);
    }
    pub fn sourceScope(self: *const Snapshot, artifact: ArtifactId) *const SourceScope {
        return @ptrCast(&self.backing().sources[@intFromEnum(artifact)]);
    }
    pub fn sourcePathCursor(self: *const Snapshot, path: []const u8) error{OutOfMemory}!SourcePathCursor {
        const owner = self.backing();
        return .{ .owner = owner, .path = try std.fs.path.resolve(owner.host.allocator(), &.{ owner.start_dir, path }) };
    }
    pub fn lookupCursor(self: *const Snapshot, consumer: ?ScopeId, name: []const u8) LookupCursor {
        return .{ .owner = self.backing(), .consumer = consumer, .module_name = name };
    }
    pub fn localScope(self: *const Snapshot) ScopeId {
        return self.backing().map.local();
    }
    pub fn localSource(self: *const Snapshot, id: ArtifactId) ?*const SourceScope {
        const owned = self.backing();
        const index = @intFromEnum(id);
        if (index >= owned.sources.len or owned.map.artifacts()[index].scope != owned.map.local()) return null;
        return @ptrCast(&owned.sources[index]);
    }
    pub fn localSourceCursor(self: *const Snapshot) LocalSourceCursor {
        return .{ .owner = self.backing() };
    }
    pub fn artifactCommitted(self: *const Snapshot, artifact: ArtifactId) bool {
        return self.backing().sources[@intFromEnum(artifact)].committed.load(.acquire);
    }
    /// Only the artifact-loading lease mints commit authority after verification.
    pub fn commitArtifact(self: *const Snapshot, commit: modules.ArtifactCommit) void {
        self.backing().sources[@intFromEnum(commit.artifact())].committed.store(true, .release);
    }
    pub fn artifactModules(self: *const Snapshot, artifact: ArtifactId) []const intern.ModuleName {
        return self.backing().map.artifacts()[@intFromEnum(artifact)].exports;
    }
    pub fn deinit(self: *Snapshot) void {
        const owned = self.backing();
        const allocator = owned.host.allocator();
        for (owned.sources) |*source| {
            source.private_registry.deinit();
            allocator.free(source.absolute_path);
        }
        allocator.free(owned.sources);
        allocator.free(owned.start_dir);
        owned.map.deinit();
        allocator.destroy(owned);
    }
};

pub const SourcePathCursor = struct {
    owner: *const Backing,
    path: []u8,
    index: usize = 0,
    pub fn advance(self: *SourcePathCursor) @import("poll.zig").Progress(?*const SourceScope) {
        if (self.index == self.owner.sources.len) return .{ .complete = null };
        const index = self.index;
        self.index += 1;
        if (std.mem.eql(u8, self.path, self.owner.sources[index].absolute_path))
            return .{ .complete = @ptrCast(&self.owner.sources[index]) };
        return .pending;
    }
    pub fn deinit(self: *SourcePathCursor) void {
        self.owner.host.allocator().free(self.path);
        self.* = undefined;
    }
};
pub const LocalSourceProgress = union(enum) { pending, item: *const SourceScope, complete };
pub const LocalSourceCursor = struct {
    owner: *const Backing,
    artifact_index: usize = 0,
    pub fn advance(self: *LocalSourceCursor) LocalSourceProgress {
        if (self.artifact_index == self.owner.sources.len) return .complete;
        const index = self.artifact_index;
        self.artifact_index += 1;
        const artifact = self.owner.map.artifacts()[index];
        if (artifact.scope != self.owner.map.local() or artifact.kind != .ecl) return .pending;
        return .{ .item = @ptrCast(&self.owner.sources[index]) };
    }
    pub fn deinit(self: *LocalSourceCursor) void {
        self.* = undefined;
    }
};
pub const Match = struct {
    scope_name: []const u8,
    root: []const u8,
    relative_path: []const u8,
    scope_id: ScopeId,
    artifact_id: ArtifactId,
    kind: module_map.Kind,
};
pub const LookupOutcome = union(enum) {
    unmatched,
    matched: Match,
    hidden: struct { owner: []const u8, consumer: []const u8 },
};
pub const LookupProgress = union(enum) { pending, complete: LookupOutcome };
/// Each advance inspects one export or one direct visibility edge.
pub const LookupCursor = struct {
    owner: *const Backing,
    consumer: ?ScopeId,
    module_name: []const u8,
    phase: union(enum) {
        finding: struct { artifact: usize = 0, export_index: usize = 0 },
        visibility: struct { artifact: ArtifactId, edge: usize = 0 },
        complete,
    } = .{ .finding = .{} },
    pub const owned_disposal: heap.OwnedDisposal = .deinit;
    pub fn advance(self: *LookupCursor) LookupProgress {
        switch (self.phase) {
            .finding => |*finding| {
                if (finding.artifact == self.owner.map.artifacts().len) {
                    self.phase = .complete;
                    return .{ .complete = .unmatched };
                }
                const artifact = self.owner.map.artifacts()[finding.artifact];
                if (finding.export_index == artifact.exports.len) {
                    finding.artifact += 1;
                    finding.export_index = 0;
                    return .pending;
                }
                const name = artifact.exports[finding.export_index];
                finding.export_index += 1;
                if (std.mem.eql(u8, intern.get(intern.moduleId(name)), self.module_name))
                    self.phase = .{ .visibility = .{ .artifact = @enumFromInt(@as(u32, @intCast(finding.artifact))) } };
                return .pending;
            },
            .visibility => |*visibility| {
                const artifact = self.owner.map.artifacts()[@intFromEnum(visibility.artifact)];
                const scope = self.owner.map.scopes()[@intFromEnum(artifact.scope)];
                const consumer = if (self.consumer) |id| self.owner.map.scopes()[@intFromEnum(id)] else null;
                if (consumer) |current| {
                    if (visibility.edge < current.visible.len) {
                        const visible = current.visible[visibility.edge] == artifact.scope;
                        visibility.edge += 1;
                        if (!visible) return .pending;
                        const source: *const SourceScope = @ptrCast(&self.owner.sources[@intFromEnum(visibility.artifact)]);
                        self.phase = .complete;
                        return .{ .complete = .{ .matched = source.location() } };
                    }
                }
                self.phase = .complete;
                return .{ .complete = .{ .hidden = .{ .owner = scope.name, .consumer = if (consumer) |current| current.name else "intrinsic context" } } };
            },
            .complete => unreachable,
        }
    }
    pub fn deinit(self: *LookupCursor) void {
        self.* = undefined;
    }
};
