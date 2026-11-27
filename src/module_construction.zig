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
    const scope = try fiber.environment.moduleScope(name);
    var candidate = try registry.createImage(scope, fiber.current.?.site.registration_provenance);
    errdefer candidate.deinit();
    if (doc) |document| candidate.document(document);
    // Every word in the body refers to the module by name. A specialized
    // leaf holds no symbol and no container, so it opens the boundary
    // unchanged in this step; any other body is re-scoped, which is
    // user-sized and therefore ordinary resumable scheduler work: the driver
    // holds the candidate image and the source body until the copy is
    // finished and the boundary can open.
    if (body.borrow().kind() != .generic_spine)
        return via.openImageBoundary(&candidate, word, body.take());
    var cursor = heap.Owned(spans.SpanArchive.RescopeCursor).init(
        try fiber.archive.rescopeCursor(body.take(), fiber.rootLinker(scope.id, candidate.provenance())),
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

/// Begins sealing the module whose construction boundary is the top frame,
/// once its body has run: the boundary closes and hands its image to the
/// sealing driver. A module body defines words and keeps no state, so a
/// residual operand window is refused before anything is sealed.
pub fn startSeal(via: *Construction) MachineError!void {
    var image = try via.closeBoundary();
    const group = image.groupCursor();
    try via.startDriver(ModuleSealDriver{ .image = .init(image.move()), .phase = .init(.{ .group = group }) });
}

/// Turns a module's staged names into its directory, warns of the core words
/// the directory shadows, and hands the sealed image to registration. The
/// image owns every staged definition, so a failure leaves nothing for this
/// driver to release but the image.
const ModuleSealDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    // Fields are released last to first: the phase borrows the image.
    image: heap.Owned(modules.OwnedImage),
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
                    self.phase.borrowMut().* = .{ .shadows = self.image.borrowMut().entries() };
                },
            },
            .shadows => |*entries| switch (entries.advance()) {
                .pending => {},
                .item => |entry| {
                    const owned = self.image.borrowMut();
                    // Shadowing in a shipped module is deliberate.
                    if (owned.provenance() != .standard_library)
                        fiber.warnCoreShadowing(entry.key, owned.moduleName());
                },
                .complete => {
                    var built = self.image.take();
                    fiber.retireDriver(self);
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
