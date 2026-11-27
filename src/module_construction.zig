//! Module construction: re-scoping a `@defm` body, sealing the image it
//! stages, and publishing it.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const Header = value.ListHandle;
const Fiber = machine.Fiber;
const Construction = machine.Construction;
const MachineError = machine.MachineError;
const WorkProgress = machine.WorkProgress;

/// Opens a construction boundary for `@defm`. The name has already been
/// validated; the body evaluates against a fresh image, and completion
/// publishes that image under the name. The image retains `doc`; the caller
/// keeps its own reference. Consumes `body_header` on success and failure.
pub fn begin(
    via: *Construction,
    name: intern.ModuleName,
    body_header: *Header,
    doc: ?*env.DocumentationString,
) MachineError!void {
    const fiber = via.fiber();
    var body = heap.Owned(*Header).init(body_header);
    defer body.deinit(fiber.releases, fiber.allocator);
    const registry = fiber.inherited.registry;
    const word = fiber.active_word;
    var candidate = try registry.createImage(name, fiber.current.?.site.registration_provenance);
    errdefer candidate.deinit();
    if (doc) |document| candidate.document(document);
    // Every word in the body refers to the image. A specialized leaf holds no
    // symbol and no container, so it opens the boundary unchanged in this
    // step; any other body is re-scoped, which is user-sized and therefore
    // ordinary resumable scheduler work: the driver holds the candidate
    // image and the source body until the copy is finished and the
    // boundary can open.
    if (body.borrow().kind() != .generic_spine)
        return via.openImageBoundary(&candidate, word, body.take());
    const home = candidate.executionHome(fiber.module_access);
    const image_cell = try fiber.environment.scopeCell(
        home.scope(fiber.module_access),
        modules.anchorHandle(home, fiber.module_access),
    );
    var cursor = heap.Owned(spans.SpanArchive.RescopeCursor).init(
        try fiber.archive.rescopeCursor(body.take(), fiber.environment.linker(image_cell.id)),
    );
    defer cursor.deinit(fiber.releases, fiber.allocator);
    try via.startDriver(ConstructionDriver{
        .state = .init(.{ .rescope = .{
            .image = .init(candidate.move()),
            .cursor = .init(cursor.take()),
        } }),
        .word = word,
    });
}

/// Drives one registry publication, mapping its refusals to language errors.
fn advanceRegistration(
    fiber: *Fiber,
    cursor: *modules.Registry.RegistrationCursor,
) MachineError!WorkProgress {
    return switch (cursor.advance() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReservedName => return fiber.fail(.domain, "module name `core` is reserved for the core qualifier"),
    }) {
        .pending => .stepped,
        .complete => .completed,
    };
}

/// The user-sized half of opening a module construction: re-scoping its
/// body.
///
/// It is proportional to what the program wrote, so it may not run to
/// completion inside one scheduler step. The candidate image and the source
/// body are held here meanwhile, so abandoning the fiber at any point releases
/// both through field ownership and publishes nothing.
const ConstructionDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .fields;
    const State = union(enum) {
        /// The re-scoping pass owns its source body, and the candidate image
        /// waits for the copy it will run.
        rescope: struct {
            image: heap.Owned(modules.OwnedImage),
            cursor: heap.Owned(spans.SpanArchive.RescopeCursor),
        },
        /// The boundary exists; completion is polled in the next step.
        opened,

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .rescope => |*rescope| {
                    rescope.cursor.deinit(releases, allocator);
                    rescope.image.deinit(releases, allocator);
                },
                .opened => {},
            }
            self.* = undefined;
        }
    };

    state: heap.Owned(State),
    /// The word that opened the construction, captured because the boundary is
    /// opened in a later step than the one that dispatched it.
    word: intern.TraceWord,

    pub fn advance(via: *Construction, self: *ConstructionDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        switch (self.state.borrowMut().*) {
            .rescope => |*rescope| {
                const progress = try rescope.cursor.borrowMut().advance(fiber.workBudget());
                const copy = switch (progress) {
                    .pending => return .stepped,
                    .complete => |header| header,
                };
                rescope.cursor.deinit(fiber.releases, fiber.allocator);
                // The open consumes the copy on success and failure alike, and
                // the image only once the boundary owns it; on failure the
                // image stays here for the state's own release.
                try via.openImageBoundary(rescope.image.borrowMut(), self.word, copy);
                rescope.image.deinit(fiber.releases, fiber.allocator);
                self.state.borrowMut().* = .opened;
                return .stepped;
            },
            .opened => {
                try fiber.pollCancellableCompletion();
                return .completed;
            },
        }
    }
};

/// Begins sealing the module whose construction boundary is the top frame. A
/// module body defines words and keeps no state, so a residual operand window
/// is refused before anything is sealed.
pub fn startSeal(via: *Construction) MachineError!void {
    const image = try via.beginSeal();
    try via.startDriver(ModuleSealDriver{ .phase = .init(.{ .group = image.groupCursor() }) });
}

/// Turns a module's staged names into its directory, warns of the core words
/// the directory shadows, and hands the sealed image to registration. The
/// image under construction owns every staged definition, so a failure leaves
/// nothing for this driver to release.
const ModuleSealDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    phase: heap.Owned(Phase),

    const Phase = union(enum) {
        group: modules.GroupCursor,
        shadows: env.NameMap.RawEntryCursor,

        pub fn deinit(self: *Phase) void {
            switch (self.*) {
                .group => |*cursor| cursor.deinit(),
                .shadows => {},
            }
            self.* = undefined;
        }
    };

    pub fn advance(via: *Construction, self: *ModuleSealDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        const work = fiber.workBudget();
        while (work.spend()) switch (self.phase.borrowMut().*) {
            .group => |*cursor| switch (cursor.advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Duplicate => return fiber.failFmt(
                    .domain,
                    "the name `{s}` is introduced more than once in this module",
                    .{intern.get(intern.bindingId(cursor.duplicate.?))},
                ),
            }) {
                .pending => {},
                .complete => {
                    cursor.deinit();
                    self.phase.borrowMut().* = .{ .shadows = via.image().entries() };
                },
            },
            .shadows => |*entries| switch (entries.advance()) {
                .pending => {},
                .item => |entry| {
                    const owned = via.image();
                    // Shadowing in a shipped module is deliberate, and a
                    // module alias is not a word, so it shadows nothing.
                    if (owned.provenance() != .standard_library and entry.value != .module)
                        fiber.warnCoreShadowing(entry.key, owned.moduleName());
                },
                .complete => {
                    fiber.retireDriver(self);
                    var built = via.closeBoundary();
                    var sealed = heap.Owned(modules.SealedImage).init(built.seal());
                    errdefer sealed.deinit(fiber.releases, fiber.allocator);
                    const driver = try fiber.allocator.create(ModuleCompletionDriver);
                    // The cursor owns the sealed image from here; nothing can fail after.
                    driver.* = .{
                        .cursor = .init(fiber.inherited.registry.registrationCursor(sealed.take())),
                    };
                    via.adoptDriver(driver);
                    return .detached;
                },
            },
        };
        return .stepped;
    }
};

/// Publishes a sealed image through the registry as resumable work.
const ModuleCompletionDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .fields;
    cursor: heap.Owned(modules.Registry.RegistrationCursor),

    pub fn advance(fiber: *Fiber, self: *ModuleCompletionDriver) MachineError!WorkProgress {
        return advanceRegistration(fiber, self.cursor.borrowMut());
    }
};
