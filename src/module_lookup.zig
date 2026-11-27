//! Named module observation: which registry, catalog, and embedded library a
//! module name is looked up in, and in what order.
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const modules = @import("modules.zig");
const native_module = @import("native_module.zig");
const poll_api = @import("poll.zig");
const stdlib = @import("stdlib.zig");
const map_state = @import("module_snapshot.zig");

/// The libraries a named module lookup consults before the registry.
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

/// A named module lookup, as the source `context`, in one view. It borrows
/// the view, which its holder keeps for the lookup's life and passes to each
/// step; the registration it finds is borrowed from that view.
pub const ModuleLookupCursor = struct {
    libraries: EmbeddedLibraries,
    project: ?*const map_state.Snapshot,
    context: modules.RegistrationProvenance,
    name: intern.ModuleName,
    state: union(enum) {
        catalog: map_state.LookupCursor,
        public: modules.ModuleCursor,
        complete,
    },
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    pub fn init(view: *const modules.View, project: ?*const map_state.Snapshot, libraries: EmbeddedLibraries, context: modules.RegistrationProvenance, name: intern.ModuleName) ModuleLookupCursor {
        var result: ModuleLookupCursor = .{ .libraries = libraries, .project = project, .context = context, .name = name, .state = .complete };
        if (project) |snapshot| {
            if (libraries.find(name) == null and
                !(if (context.sourceScope()) |source| source.exports(name) else false))
            {
                result.state = .{ .catalog = snapshot.lookupCursor(context.scopeId(), intern.get(intern.moduleId(name))) };
                return result;
            }
        }
        result.state = .{ .public = view.moduleCursor(name) };
        return result;
    }

    pub fn advance(self: *ModuleLookupCursor, view: *const modules.View) poll_api.Progress(?modules.Generation) {
        return switch (self.state) {
            .catalog => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |outcome| result: {
                    cursor.deinit();
                    self.state = .complete;
                    if (outcome == .matched and self.project.?.artifactCommitted(outcome.matched.artifact_id)) {
                        self.state = .{ .public = view.moduleCursor(self.name) };
                        break :result .pending;
                    }
                    break :result .{ .complete = null };
                },
            },
            .public => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |generation| result: {
                    self.state = .complete;
                    break :result .{ .complete = generation };
                },
            },
            .complete => unreachable,
        };
    }

    pub fn deinit(self: *ModuleLookupCursor) void {
        switch (self.state) {
            .catalog => |*cursor| cursor.deinit(),
            .public, .complete => {},
        }
        self.* = undefined;
    }
};

/// A named module lookup that holds the view it reads, for a primitive that
/// has no resolution's view to borrow.
pub const HeldModuleLookup = struct {
    view: modules.View,
    cursor: ModuleLookupCursor,
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    /// The registration found is borrowed from `view`, which the caller may
    /// take before releasing the rest.
    pub fn advance(self: *HeldModuleLookup) poll_api.Progress(?modules.Generation) {
        return self.cursor.advance(&self.view);
    }

    pub fn deinit(self: *HeldModuleLookup) void {
        self.cursor.deinit();
        self.view.deinit();
        self.* = undefined;
    }
};
