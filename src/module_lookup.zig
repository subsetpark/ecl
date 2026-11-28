//! Named module observation: the embedded library a module name is reserved
//! for, and a registry lookup that holds the view it reads.
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const modules = @import("modules.zig");
const poll_api = @import("poll.zig");
const stdlib = @import("stdlib.zig");

/// The embedded standard-library module `name`, which a named module lookup
/// consults before the registry.
pub fn embeddedLibrary(name: intern.ModuleName) ?stdlib.Entry {
    return stdlib.find(intern.get(intern.moduleId(name)));
}

/// A named module lookup that holds the view it reads, for a primitive that
/// has no resolution's view to borrow.
pub const HeldModuleLookup = struct {
    view: modules.View,
    cursor: modules.ModuleCursor,
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    /// The registration found is borrowed from `view`, which the caller may
    /// take before releasing the rest.
    pub fn advance(self: *HeldModuleLookup) poll_api.Progress(?modules.Generation) {
        return self.cursor.advance();
    }

    pub fn deinit(self: *HeldModuleLookup) void {
        self.view.deinit();
        self.* = undefined;
    }
};
