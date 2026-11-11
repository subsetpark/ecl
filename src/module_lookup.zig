//! Named module observation: which registry, catalog, and embedded library a
//! module name is looked up in, and in what order.
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const modules = @import("modules.zig");
const native_module = @import("native_module.zig");
const poll_api = @import("poll.zig");
const stdlib = @import("stdlib.zig");
const map_state = @import("module_snapshot.zig");

/// One visibility boundary for named module observation. Private registrations
/// are searched only in the lexical source; public lookup never searches other
/// files' private registries, regardless of their load state.
pub const EmbeddedLibraries = union(enum) {
    bundled,
    registered: *native_module.Loader,
    pub fn find(self: EmbeddedLibraries, name: intern.ModuleName) ?stdlib.Entry {
        if (stdlib.find(intern.get(intern.moduleId(name)))) |entry| return entry;
        switch (self) {
            .bundled => {},
            .registered => |loader| if (loader.registeredDescriptor(name)) |descriptor| return .{ .native = descriptor },
        }
        return null;
    }
};

pub const ModuleLookupCursor = struct {
    registry: *modules.Registry,
    /// The captured view public lookups read, when the lookup belongs to one
    /// binding; a fresh snapshot otherwise.
    view: ?modules.View = null,
    libraries: EmbeddedLibraries,
    project: ?*const map_state.Snapshot,
    context: modules.RegistrationProvenance,
    name: intern.ModuleName,
    state: union(enum) {
        private: modules.Registry.AcquireCursor,
        catalog: map_state.LookupCursor,
        public: modules.Registry.AcquireCursor,
        complete,
    },
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    pub fn init(registry: *modules.Registry, project: ?*const map_state.Snapshot, libraries: EmbeddedLibraries, context: modules.RegistrationProvenance, name: intern.ModuleName) ModuleLookupCursor {
        var result: ModuleLookupCursor = .{ .registry = registry, .libraries = libraries, .project = project, .context = context, .name = name, .state = .complete };
        if (context.sourceScope()) |local| result.state = .{ .private = local.registry().acquireCursor(name) } else result.beginPublic();
        return result;
    }

    /// A lookup whose public registry reads come from `view`.
    pub fn initIn(view: *const modules.View, registry: *modules.Registry, project: ?*const map_state.Snapshot, libraries: EmbeddedLibraries, context: modules.RegistrationProvenance, name: intern.ModuleName) ModuleLookupCursor {
        var result: ModuleLookupCursor = .{ .registry = registry, .view = view.clone(), .libraries = libraries, .project = project, .context = context, .name = name, .state = .complete };
        if (context.sourceScope()) |local| result.state = .{ .private = local.registry().acquireCursor(name) } else result.beginPublic();
        return result;
    }

    fn publicCursor(self: *const ModuleLookupCursor) modules.Registry.AcquireCursor {
        if (self.view) |*captured| return captured.acquireCursor(self.name);
        return self.registry.acquireCursor(self.name);
    }

    fn beginPublic(self: *ModuleLookupCursor) void {
        if (self.project) |project| {
            if (self.libraries.find(self.name) == null and
                !(if (self.context.sourceScope()) |source| source.exports(self.name) else false))
            {
                self.state = .{ .catalog = project.lookupCursor(self.context.scopeId(), intern.get(intern.moduleId(self.name))) };
                return;
            }
        }
        self.state = .{ .public = self.publicCursor() };
    }

    pub fn advance(self: *ModuleLookupCursor) poll_api.Progress(?modules.GenerationLease) {
        return switch (self.state) {
            .private => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |generation| result: {
                    cursor.deinit();
                    self.state = .complete;
                    if (generation) |lease| break :result .{ .complete = lease };
                    self.beginPublic();
                    break :result .pending;
                },
            },
            .catalog => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |outcome| result: {
                    cursor.deinit();
                    self.state = .complete;
                    if (outcome == .matched and self.project.?.artifactCommitted(outcome.matched.artifact_id)) {
                        self.state = .{ .public = self.publicCursor() };
                        break :result .pending;
                    }
                    break :result .{ .complete = null };
                },
            },
            .public => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |generation| result: {
                    cursor.deinit();
                    self.state = .complete;
                    break :result .{ .complete = generation };
                },
            },
            .complete => unreachable,
        };
    }

    pub fn deinit(self: *ModuleLookupCursor) void {
        switch (self.state) {
            .private, .public => |*cursor| cursor.deinit(),
            .catalog => |*cursor| cursor.deinit(),
            .complete => {},
        }
        if (self.view) |*captured| captured.deinit();
        self.* = undefined;
    }
};
