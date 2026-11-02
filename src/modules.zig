//! Per-session module registry with typed names and atomic generation publication.
const std = @import("std");
const map_state = @import("module_snapshot.zig");
const builtin = @import("builtin");
const env = @import("env.zig");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const native_module = @import("native_module.zig");
const poll = @import("poll.zig");
const snapshot_api = @import("snapshot.zig");
const list = @import("list.zig");
const kernel_storage = @import("kernel_storage.zig");
const poll_api = @import("poll.zig");

/// Immutable metadata for one first-class module test. The executable body is
/// deliberately absent from this public projection: discovery may expose
/// annotations, but only the protected invocation path can recover the
/// quotation.
pub const ModuleTestMetadata = struct {
    name: intern.BindingName,
    effect: ?env.ValidatedEffect,
    doc: ?*env.DocumentationString,
};

const TestCatalog = struct {
    const Entry = struct {
        name: intern.BindingName,
        body: *env.Quotation,
        effect: ?env.ValidatedEffect,
        doc: ?*env.DocumentationString,
        next: ?*Entry = null,

        fn retain(self: Entry) void {
            heap.incRef(env.quotationHeader(self.body));
            if (self.effect) |effect| effect.retain();
            if (self.doc) |doc| heap.incRef(env.documentationHeader(doc));
        }

        fn retire(self: Entry, releases: *heap.ReleaseDomain) void {
            releases.releaseHeader(env.quotationHeader(self.body));
            if (self.effect) |effect| effect.retire(releases);
            if (self.doc) |doc| releases.releaseHeader(env.documentationHeader(doc));
        }

        fn metadata(self: Entry) ModuleTestMetadata {
            return .{ .name = self.name, .effect = self.effect, .doc = self.doc };
        }
    };

    const Link = union(enum) {
        entry: *Entry,
        branch: *Branch,
    };

    /// A fixed-depth crit-bit index over nominal 32-bit binding IDs. Branch
    /// masks strictly decrease on every path, so declaration and lookup each
    /// take at most 32 resumable steps without resizing or rehashing storage.
    const Branch = struct {
        mask: u32,
        children: [2]?Link,
        next_all: ?*Branch,
    };

    allocator: std.mem.Allocator,
    root: ?Link = null,
    entries_head: ?*Entry = null,
    entries_tail: ?*Entry = null,
    branches: ?*Branch = null,
    frozen: bool = false,

    fn init(allocator: std.mem.Allocator) TestCatalog {
        return .{ .allocator = allocator };
    }

    fn freeze(self: *TestCatalog) void {
        self.frozen = true;
    }

    const DeclareError = error{ OutOfMemory, DuplicateTest, Frozen };
    const DeclareProgress = poll.Progress(void);
    const DeclareCursor = struct {
        catalog: *TestCatalog,
        candidate: Entry,
        state: union(enum) {
            lookup: ?Link,
            insertion: struct {
                link: *?Link,
                mask: u32,
            },
            commit: struct {
                link: *?Link,
                mask: ?u32,
            },
        },
        complete: bool = false,

        fn advance(self: *DeclareCursor) DeclareError!DeclareProgress {
            std.debug.assert(!self.complete);
            if (self.catalog.frozen) return error.Frozen;
            return switch (self.state) {
                .lookup => |maybe_link| result: {
                    const link = maybe_link orelse {
                        self.state = .{ .commit = .{
                            .link = &self.catalog.root,
                            .mask = null,
                        } };
                        break :result .pending;
                    };
                    switch (link) {
                        .branch => |branch| {
                            self.state = .{ .lookup = branch.children[
                                direction(
                                    self.candidate.name,
                                    branch.mask,
                                )
                            ] };
                            break :result .pending;
                        },
                        .entry => |entry| {
                            if (entry.name == self.candidate.name)
                                return error.DuplicateTest;
                            const difference = rawName(entry.name) ^ rawName(self.candidate.name);
                            self.state = .{ .insertion = .{
                                .link = &self.catalog.root,
                                .mask = std.math.floorPowerOfTwo(u32, difference),
                            } };
                            break :result .pending;
                        },
                    }
                },
                .insertion => |insertion| result: {
                    const link = insertion.link.* orelse unreachable;
                    if (link == .branch and link.branch.mask > insertion.mask) {
                        self.state = .{ .insertion = .{
                            .link = &link.branch.children[
                                direction(
                                    self.candidate.name,
                                    link.branch.mask,
                                )
                            ],
                            .mask = insertion.mask,
                        } };
                        break :result .pending;
                    }
                    self.state = .{ .commit = .{
                        .link = insertion.link,
                        .mask = insertion.mask,
                    } };
                    break :result .pending;
                },
                .commit => |commit| result: {
                    const entry = try self.catalog.allocator.create(Entry);
                    errdefer self.catalog.allocator.destroy(entry);
                    entry.* = self.candidate;
                    if (commit.mask) |mask| {
                        const branch = try self.catalog.allocator.create(Branch);
                        const existing = commit.link.* orelse unreachable;
                        const new_direction = direction(entry.name, mask);
                        branch.* = .{
                            .mask = mask,
                            .children = @splat(null),
                            .next_all = self.catalog.branches,
                        };
                        branch.children[new_direction] = .{ .entry = entry };
                        branch.children[1 - new_direction] = existing;
                        commit.link.* = .{ .branch = branch };
                        self.catalog.branches = branch;
                    } else {
                        std.debug.assert(commit.link.* == null);
                        commit.link.* = .{ .entry = entry };
                    }
                    entry.retain();
                    if (self.catalog.entries_tail) |tail|
                        tail.next = entry
                    else
                        self.catalog.entries_head = entry;
                    self.catalog.entries_tail = entry;
                    self.complete = true;
                    break :result .complete;
                },
            };
        }
    };

    fn rawName(name: intern.BindingName) u32 {
        return @backingInt(name);
    }

    fn direction(name: intern.BindingName, mask: u32) usize {
        return @intFromBool(rawName(name) & mask != 0);
    }

    fn declareCursor(
        self: *TestCatalog,
        name: intern.BindingName,
        body: *env.Quotation,
        effect: ?env.ValidatedEffect,
        doc: ?*env.DocumentationString,
    ) DeclareCursor {
        return .{
            .catalog = self,
            .candidate = .{
                .name = name,
                .body = body,
                .effect = effect,
                .doc = doc,
            },
            .state = .{ .lookup = self.root },
        };
    }

    const NameProgress = poll.StreamProgress(ModuleTestMetadata);
    const NameCursor = struct {
        next: ?*const Entry,

        fn advance(self: *NameCursor) NameProgress {
            const entry = self.next orelse return .complete;
            self.next = entry.next;
            return .{ .item = entry.metadata() };
        }
    };

    const LookupProgress = poll.Progress(?*env.Quotation);
    const LookupCursor = struct {
        current: ?Link,
        name: intern.BindingName,

        fn advance(self: *LookupCursor) LookupProgress {
            const link = self.current orelse return .{ .complete = null };
            return switch (link) {
                .branch => |branch| pending: {
                    self.current = branch.children[direction(self.name, branch.mask)];
                    break :pending .pending;
                },
                .entry => |entry| .{ .complete = if (entry.name == self.name)
                    entry.body
                else
                    null },
            };
        }
    };

    const TeardownCursor = struct {
        catalog: *TestCatalog,
        branches: ?*Branch,
        entries: ?*Entry,

        fn init(catalog: *TestCatalog) TeardownCursor {
            return .{
                .catalog = catalog,
                .branches = catalog.branches,
                .entries = catalog.entries_head,
            };
        }

        fn advance(self: *TeardownCursor, releases: *heap.ReleaseDomain) bool {
            if (self.branches) |branch| {
                self.branches = branch.next_all;
                self.catalog.allocator.destroy(branch);
                return false;
            }
            if (self.entries) |entry| {
                self.entries = entry.next;
                entry.retire(releases);
                self.catalog.allocator.destroy(entry);
                return false;
            }
            self.catalog.root = null;
            self.catalog.entries_head = null;
            self.catalog.entries_tail = null;
            self.catalog.branches = null;
            return true;
        }
    };
};

/// Bounded declaration work returned only for the candidate image currently
/// owned by a module construction boundary.
pub const TestDeclarationCursor = struct {
    state: union(enum) {
        discard,
        catalog: TestCatalog.DeclareCursor,
        complete,
    },

    pub const Progress = poll.Progress(void);
    pub const Error = TestCatalog.DeclareError;

    pub fn discard() TestDeclarationCursor {
        return .{ .state = .discard };
    }

    pub fn advance(self: *TestDeclarationCursor) Error!Progress {
        return switch (self.state) {
            .discard => result: {
                self.state = .complete;
                break :result .complete;
            },
            .catalog => |*cursor| cursor.advance(),
            .complete => unreachable,
        };
    }
};

/// Acquires one reference on a refcounted module owner, but only if a
/// reference already exists.
///
/// A scope cell names its owner without holding it, so a borrow that has just
/// read the cell may be racing that owner's last `release`. An unconditional
/// `fetchAdd` there asserts in a safe build and resurrects a destroyed object
/// in ReleaseFast. Failure leaves the count untouched, which is the load-
/// bearing half: a `fetchAdd` followed by a correction would publish a
/// transient nonzero value that a concurrent `release` could read as a live
/// owner.
fn tryAcquire(refs: *std.atomic.Value(u32)) bool {
    var observed = refs.load(.acquire);
    while (observed != 0) {
        std.debug.assert(observed != std.math.maxInt(u32));
        observed = refs.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire) orelse
            return true;
    }
    return false;
}

test "modules: a conditional acquire refuses a dead owner and never disturbs its count" {
    var live: std.atomic.Value(u32) = .init(1);
    try std.testing.expect(tryAcquire(&live));
    try std.testing.expectEqual(@as(u32, 2), live.load(.acquire));
    try std.testing.expect(tryAcquire(&live));
    try std.testing.expectEqual(@as(u32, 3), live.load(.acquire));

    // Zero is the point of no return: `release` has already cleared the label
    // cell and handed the owner to its release domain, so an acquire that
    // succeeded here would resurrect it.
    var dead: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(!tryAcquire(&dead));
    try std.testing.expectEqual(@as(u32, 0), dead.load(.acquire));
    try std.testing.expect(!tryAcquire(&dead));
    try std.testing.expectEqual(@as(u32, 0), dead.load(.acquire));
}

/// One image's authoritative reference count, allocated with the image and
/// outliving it whenever a scope cell still names it.
///
/// Allocated at the image's birth so a refcount never has to
/// migrate mid-life without briefly existing twice, and two counts have a
/// window in which they disagree. One count, one retain/release path.
///
/// `image` dangles once the image has been destroyed. That is sound rather than
/// merely tolerated: it is read only after a successful `tryAcquire`, which
/// cannot succeed at zero, and zero is reached before the image is destroyed.
///
/// Only the anchor is parked at retirement, never the image. Parking the image
/// struct in place was implemented and measured against the retention soaks:
/// 394 bytes per stamped reload, large_growth=629952 against a bound of 226876
/// — 25x over. An anchor is cell-order instead, which those soaks tolerate.
const RefAnchor = struct {
    refs: std.atomic.Value(u32) = .init(1),
    park: Park,

    /// The image pointer and the parked-list link share one word, because a
    /// dead anchor's image pointer is never read again.
    ///
    /// The proof is structural: `image` is read only after a successful CAS
    /// off a nonzero count; `refs == 0` is permanent once reached; and `next` is
    /// stored on the release path strictly after zero. So a `tryRetain` racing
    /// the overlay fails its CAS and touches nothing else.
    ///
    /// The overlay is what brings the anchor to 16 bytes. It was measured
    /// against the retention soaks, which allow roughly 32 bytes per stamped
    /// reload: parking the whole `ModuleImage` in place cost 394 bytes and
    /// failed by 14212, and a 32-byte anchor would have cleared the bound by
    /// only 636 bytes against ~111KB of small-phase noise, which is how an
    /// invariant becomes a flaky test and then a weakened one.
    /// `extern` so it carries no safety tag. A plain untagged union is 16
    /// bytes in Debug and ReleaseSafe because Zig adds one, which alone would
    /// blow the 16-byte anchor budget, as direct measurement confirms. Both members are
    /// plain pointers, so extern layout is exact and the link is the node: a
    /// `TombstoneNode` is nothing but its `next`, so a pointer to this union
    /// *is* a pointer to the node.
    const Park = extern union {
        image: *ModuleImage,
        next: ?*heap.ReleaseDomain.TombstoneNode,
    };

    fn tryRetain(self: *RefAnchor) bool {
        return tryAcquire(&self.refs);
    }
};

comptime {
    if (@sizeOf(RefAnchor) > 16)
        @compileError("RefAnchor exceeds the parked-anchor budget the retention soaks impose");
}

/// The opaque handle a scope cell stores to name this image's anchor.
///
/// The cell must name the *anchor* and not the home: a home is embedded in the
/// image, and the anchor is precisely the thing that outlives it. So
/// `ModuleHome.tryPin` cannot serve a cell-originated borrow, and
/// `tryPinAnchor` below is its counterpart for one.
pub fn anchorHandle(home: *const ModuleHome, _: *const ExecutionAccess) *env.ImageAnchor {
    return anchorHandleInternal(home);
}

fn anchorHandleInternal(home: *const ModuleHome) *env.ImageAnchor {
    return @ptrCast(home.image().anchor);
}

fn tryPinAnchorInternal(owner: *env.ImageAnchor) ?GenerationPin {
    const anchor: *RefAnchor = @ptrCast(@alignCast(owner));
    if (!anchor.tryRetain()) return null;
    // Only now is the image pointer readable: before the CAS succeeded this
    // word may have been the parked-list link instead.
    return .initRetained(anchor.park.image);
}

/// Acquires one reference through a scope cell's owner handle, or null when the
/// image has reached its last release.
///
/// Split from `tryPinAnchorInternal` for the same reason `pin` is split from
/// `pinInternal`: the audit rejects one function that both holds a capability
/// token and casts a pointer.
pub fn tryPinAnchor(owner: *env.ImageAnchor, _: *const ExecutionAccess) ?GenerationPin {
    return tryPinAnchorInternal(owner);
}

/// The single destructor `ReleaseDomain.reclaimTombstones` is given.
///
/// A parked anchor is the only thing this module ever parks. A second parked
/// type must take its own list head rather than turn the node into a
/// discriminated one -- the node is a bare link precisely because the soak
/// budget has no room for discrimination.
pub fn destroyParkedAnchor(
    allocator: std.mem.Allocator,
    node: *heap.ReleaseDomain.TombstoneNode,
) void {
    // The link is the union's first and only field, so the union starts where
    // the node does. Plain casts, no capability token.
    const park: *RefAnchor.Park = @ptrCast(node);
    const anchor: *RefAnchor = @fieldParentPtr("park", park);
    allocator.destroy(anchor);
}

/// One module: the directory its definitions live in, the module-root scope
/// its text was written in, and the registry identity it was built for. The
/// name is fixed before the body runs; the generation number is assigned when
/// the registry publishes it. While the constructing body runs, definitions
/// and imports are staged; sealing turns the staged group into an immutable
/// directory whose bodies are bound against the complete group. A published
/// image belongs to its registry's history until Session teardown, so code
/// bound to it and words written in it never outlive it.
const ModuleImage = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    name: intern.ModuleName,
    provenance: RegistrationProvenance,
    /// Zero until published; reload assigns the prior generation plus one.
    generation: u64 = 0,
    /// Set once the registry has published the image. Before then only its
    /// constructor may resolve against its directory.
    published: std.atomic.Value(bool) = .init(false),
    /// The next older image in its registry's history.
    history_next: ?*ModuleImage = null,
    /// Names introduced by the construction body, not yet visible to anyone.
    staging: poll.ChunkStack(StagedName),
    staged_count: usize = 0,
    /// The sealed directory; null until the group is sealed.
    names: ?env.NameMap = null,
    scope: env.Scope,
    tests: TestCatalog,
    /// The authoritative count lives in this separately owned cell, so it can outlive this
    /// struct for the images a scope cell names.
    anchor: *RefAnchor,
    /// Whether ECL source was ever stamped against this image, recorded where
    /// `release` takes the label cell. Only a stamped image is named by a cell
    /// that holds no reference, so only a stamped image's anchor is parked.
    minted_cell: bool = false,
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: union(enum) {
        live,
        tests: TestCatalog.TeardownCursor,
        scope: env.Scope.EmbeddedTeardownCursor,
        staging,
        names: env.NameMap.RawEntryCursor,
    } = .live,

    fn create(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        name: intern.ModuleName,
        provenance: RegistrationProvenance,
    ) error{OutOfMemory}!*ModuleImage {
        // No scope cell is minted here. An image needs one only if ECL source
        // is stamped against it, which `moduleOwned` arranges lazily.
        const result = try allocator.create(ModuleImage);
        const anchor = allocator.create(RefAnchor) catch |err| {
            allocator.destroy(result);
            return err;
        };
        anchor.* = .{ .park = .{ .image = result } };
        result.* = .{
            .allocator = allocator,
            .releases = releases,
            .name = name,
            .provenance = provenance,
            .staging = .init(allocator),
            .scope = env.Scope.moduleRoot(allocator),
            .tests = .init(allocator),
            .anchor = anchor,
        };
        return result;
    }

    fn retain(self: *ModuleImage) void {
        const old = self.anchor.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    /// Reachable only from a caller that already holds this image alive.
    fn tryRetain(self: *ModuleImage) bool {
        return self.anchor.tryRetain();
    }

    fn release(self: *ModuleImage) void {
        const old = self.anchor.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.anchor.refs.load(.acquire);
        // Before any teardown step, so a quotation labelled with this image
        // reads a definite `retired` and never a scope under teardown.
        if (self.scope.label_cell.swap(null, .acq_rel)) |cell| {
            cell.retire();
            self.minted_cell = true;
        }
        self.retirement_state = .{ .tests = .init(&self.tests) };
        self.releases.retire(self, &self.retirement);
    }

    /// Stages one name. Ownership of `entry` passes to the image on success
    /// and stays with the caller on failure.
    fn stage(self: *ModuleImage, name: intern.BindingName, entry: env.Entry) error{OutOfMemory}!void {
        std.debug.assert(self.names == null);
        try self.staging.push(.{ .name = name, .entry = entry });
        self.staged_count += 1;
    }

    /// Whether a word written in this image may resolve against its
    /// directory now: once published, or by the construction sealing it.
    fn directory(self: *const ModuleImage) ?*const env.NameMap {
        if (!self.published.load(.acquire)) return null;
        return &(self.names orelse return null);
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *ModuleImage,
    ) bool {
        switch (self.retirement_state) {
            .live => unreachable,
            .tests => |*tests| {
                if (!tests.advance(releases)) return false;
                self.retirement_state = .{ .scope = .init(&self.scope) };
                return false;
            },
            .scope => |*scope| {
                if (!scope.advance()) return false;
                self.retirement_state = .staging;
                return false;
            },
            .staging => {
                if (self.staging.pop()) |staged| {
                    retireEntry(staged.entry, releases);
                    return false;
                }
                self.staging.deinit();
                if (self.names) |*names| {
                    self.retirement_state = .{ .names = names.rawEntries() };
                    return false;
                }
            },
            .names => |*entries| switch (entries.advance()) {
                .pending => return false,
                .item => |entry| {
                    retireEntry(entry.value, releases);
                    return false;
                },
                .complete => self.names.?.deinit(),
            },
        }
        const anchor = self.anchor;
        const stamped = self.minted_cell;
        allocator.destroy(self);
        if (!stamped) {
            allocator.destroy(anchor);
            return true;
        }
        // A cell outlives this image and names its anchor without holding a
        // reference: `refs` stays readable at zero, so a borrow that reaches
        // this anchor fails its acquire rather than faulting.
        anchor.park = .{ .next = null };
        releases.parkTombstone(@ptrCast(&anchor.park));
        return true;
    }

    fn retireEntry(entry: env.Entry, releases: *heap.ReleaseDomain) void {
        switch (entry) {
            .definition => |definition| definition.retireStatic(releases),
            .alias => {},
        }
    }
};

/// One name a construction body introduced, owned by its image until sealing.
const StagedName = struct {
    name: intern.BindingName,
    entry: env.Entry,
};

/// Nominal publication provenance. Embedded definitions retain their trusted
/// origin. Cataloged code carries its defining-file capability, which also
/// identifies its resolution scope and direct visibility. Interactive root code has
/// local-scope visibility without access to any file's private namespace.
pub const RegistrationProvenance = union(enum) {
    ordinary,
    standard_library,
    root_scope: map_state.ScopeId,
    source: *const map_state.SourceScope,

    pub fn scopeId(self: RegistrationProvenance) ?map_state.ScopeId {
        return switch (self) {
            .root_scope => |id| id,
            .source => |source| source.scopeId(),
            .ordinary, .standard_library => null,
        };
    }

    pub fn sourceScope(self: RegistrationProvenance) ?*const map_state.SourceScope {
        return switch (self) {
            .source => |source| source,
            else => null,
        };
    }

    /// The provenance of a quotation this code applies as a value (`call`,
    /// `@attempt`, a combinator). The value may have come from any caller, so
    /// embedded trust stays with embedded code and never passes to it.
    pub fn applied(self: RegistrationProvenance) RegistrationProvenance {
        return switch (self) {
            .standard_library => .ordinary,
            .ordinary, .root_scope, .source => self,
        };
    }
};

pub const ModuleLookupProgress = poll.Progress(?env.Entry);
/// One name in a published image's directory, under a pin that keeps the image
/// alive across a resumable lookup. Visibility is the caller's to check: an
/// export lookup refuses private entries, and a word written in the image may
/// use them.
pub const ModuleNameLookupCursor = struct {
    lookup: ?env.NameMap.RawLookupCursor,
    pin: GenerationPin,

    pub fn deinit(self: *ModuleNameLookupCursor) void {
        self.pin.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *ModuleNameLookupCursor) ModuleLookupProgress {
        const lookup = &(self.lookup orelse return .{ .complete = null });
        return switch (lookup.advance()) {
            .pending => .pending,
            .complete => |found| .{ .complete = found },
        };
    }
};

/// Whether an entry is part of its module's public face.
pub fn entryIsPublic(entry: env.Entry) bool {
    return switch (entry) {
        .definition => |definition| definition.visibility == .public,
        .alias => |alias| alias.visibility == .public,
    };
}

pub const ModulePublicNameProgress = poll.StreamProgress(u32);
pub const ModulePublicNameCursor = struct {
    entries: ?env.NameMap.RawEntryCursor,
    pin: GenerationPin,
    pub fn deinit(self: *ModulePublicNameCursor) void {
        self.pin.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *ModulePublicNameCursor) ModulePublicNameProgress {
        const entries = &(self.entries orelse return .complete);
        return switch (entries.advance()) {
            .pending => .pending,
            .complete => .complete,
            .item => |entry| if (entryIsPublic(entry.value))
                .{ .item = intern.bindingId(entry.key) }
            else
                .pending,
        };
    }
};
fn publicNameCursorFor(image: *ModuleImage) ModulePublicNameCursor {
    return .{
        .entries = if (image.names) |*names| names.rawEntries() else null,
        .pin = ModuleHome.init(image).pinInternal(),
    };
}

/// One immutable snapshot of the registry: its module names, its aliases, and
/// for the Session's public registry the top-level name directory. A binding
/// captures one snapshot and resolves every name against it across scheduler
/// turns, so it never mixes publication states. A directory owns one
/// reference to every image and counted definition it maps; a retired
/// directory releases them as bounded work before it frees itself.
const Directory = struct {
    const ModuleMap = poll.FixedMap(intern.ModuleName, *ModuleImage);
    const AliasMap = poll.FixedMap(intern.BindingName, intern.ModuleName);

    modules: ModuleMap,
    aliases: AliasMap,
    names: env.NameMap,
    previous: ?*Directory,
    retirement: heap.ReleaseDomain.Retirement = .{},
    /// The entry walk a retirement is partway through.
    releasing: union(enum) {
        start,
        modules: ModuleMap.RawEntryCursor,
        names: env.NameMap.RawEntryCursor,
    } = .start,

    /// Releases one entry per step, then frees the maps and hands the next
    /// older directory to the release domain. A discarded edit candidate
    /// takes the same path with no `previous`, so abandoning a registry edit
    /// never releases a user-sized map in one call.
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Directory,
    ) bool {
        switch (self.releasing) {
            .start => {
                self.releasing = .{ .modules = self.modules.rawEntries() };
                return false;
            },
            .modules => |*entries| switch (entries.advance()) {
                .pending => return false,
                .item => |entry| {
                    entry.value.release();
                    return false;
                },
                .complete => {
                    self.releasing = .{ .names = self.names.rawEntries() };
                    return false;
                },
            },
            .names => |*entries| switch (entries.advance()) {
                .pending => return false,
                .item => |entry| {
                    entry.value.release(releases);
                    return false;
                },
                .complete => {},
            },
        }
        const previous = self.previous;
        self.modules.deinit();
        self.aliases.deinit();
        self.names.deinit();
        allocator.destroy(self);
        if (previous) |next| releases.retire(next, &next.retirement);
        return true;
    }

    /// Session teardown walks the chain synchronously: execution has already
    /// stopped, and the host drains every retirement this starts.
    fn destroyChain(first: ?*Directory, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        var cursor = first;
        while (cursor) |directory| {
            cursor = directory.previous;
            var entries = directory.modules.rawEntries();
            while (true) switch (entries.advance()) {
                .pending => {},
                .item => |entry| entry.value.release(),
                .complete => break,
            };
            var names = directory.names.rawEntries();
            while (true) switch (names.advance()) {
                .pending => {},
                .item => |entry| entry.value.release(releases),
                .complete => break,
            };
            directory.modules.deinit();
            directory.aliases.deinit();
            directory.names.deinit();
            allocator.destroy(directory);
        }
    }
};
const DirectoryPublisher = snapshot_api.Publisher(Directory);

const DirectoryLease = struct {
    registry: *const Registry,
    lease: DirectoryPublisher.Lease,
    directory: ?*const Directory,

    fn clone(self: *const DirectoryLease) DirectoryLease {
        return .{ .registry = self.registry, .lease = self.lease.clone(), .directory = self.directory };
    }

    fn deinit(self: *DirectoryLease) void {
        const registry = @constCast(self.registry);
        if (self.lease.deinit()) {
            registry.lockBlocking();
            const retired = registry.detachRetiredDirectories();
            registry.unlock();
            if (retired) |first| registry.releaseDomain().retire(first, &first.retirement);
        }
        self.* = undefined;
    }
};

/// One captured registry snapshot: what a binding or explicit lookup resolves
/// session names and qualified module names against. Holding it retains the
/// snapshot, not the definitions bound through it.
pub const View = struct {
    directory: DirectoryLease,
    /// The publication identity read before the snapshot was captured.
    publication: u64,

    pub fn deinit(self: *View) void {
        self.directory.deinit();
        self.* = undefined;
    }

    /// A second hold on the same snapshot.
    pub fn clone(self: *const View) View {
        return .{ .directory = self.directory.clone(), .publication = self.publication };
    }

    /// One session top-level name in this snapshot.
    pub fn sessionLookup(self: *const View, name: intern.BindingName) ?env.NameMap.RawLookupCursor {
        const current = self.directory.directory orelse return null;
        return current.names.rawLookup(name);
    }

    /// The image a module name or module alias selects in this snapshot.
    pub fn acquireCursor(self: *const View, name: intern.ModuleName) Registry.AcquireCursor {
        return Registry.AcquireCursor.initIn(self.directory.clone(), name);
    }

    /// The session's top-level names in this snapshot.
    pub fn sessionEntries(self: *const View) ?env.NameMap.RawEntryCursor {
        const current = self.directory.directory orelse return null;
        return current.names.rawEntries();
    }
};

/// Session-owned authority required to turn observation state into frame
/// execution state. Session and Unit storage own the seal; registered native
/// callbacks never receive it.
pub const ExecutionAccess = opaque {};

const TestAuthorityState = struct {
    // Keep the opaque registry value itself. The caller's movable enum wrapper
    // has no stable address.
    // Session construction moves that wrapper into its core after minting this
    // seal; the backing identity remains stable.
    registry: Registry,
    project: ?*const map_state.Snapshot,
};

/// Session-owned capability seal for the closed test execution domain. A
/// normal Session never allocates one. The two projections are nominally
/// distinct so metadata observation cannot be upgraded into execution.
pub const TestAuthority = enum(usize) {
    consumed = 0,
    _,

    fn init(backing: *TestAuthorityState) TestAuthority {
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }
    fn state(self: TestAuthority) *TestAuthorityState {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@backingInt(self));
    }
    pub fn observation(self: TestAuthority) *const TestObservationAccess {
        return @ptrCast(self.state());
    }
    pub fn execution(self: TestAuthority) *const TestExecutionAccess {
        return @ptrCast(self.state());
    }
    pub fn deinit(self: *TestAuthority) void {
        if (self.* == .consumed) return;
        const owned = self.state();
        const allocator = owned.registry.allocator();
        allocator.destroy(owned);
        self.* = .consumed;
    }
};

pub const TestObservationAccess = opaque {
    fn state(self: *const TestObservationAccess) *TestAuthorityState {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn discoveryCursor(self: *const TestObservationAccess) TestSessionDiscoveryCursor {
        const owner = self.state();
        return .{
            .project = owner.project,
            .roots = if (owner.project) |project| project.localSourceCursor() else null,
            .current = .init(&owner.registry),
        };
    }
};

pub const TestExecutionAccess = opaque {
    fn state(self: *const TestExecutionAccess) *TestAuthorityState {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn lookupCursor(
        self: *const TestExecutionAccess,
        module_name: intern.ModuleName,
        test_name: intern.BindingName,
        source: ?map_state.ArtifactId,
    ) ?Registry.TestLookupCursor {
        const owner = self.state();
        if (source) |id| {
            const project = owner.project orelse return null;
            const scope = project.localSource(id) orelse return null;
            if (!project.artifactCommitted(id)) return null;
            return .init(scope.registry(), module_name, test_name);
        }
        return .init(&owner.registry, module_name, test_name);
    }
};

/// Enumerates the public registry and each committed root source's private
/// registry while retaining every active snapshot lease.
pub const TestSessionDiscoveryCursor = struct {
    project: ?*const map_state.Snapshot,
    roots: ?map_state.LocalSourceCursor,
    current: ?Registry.TestDiscoveryCursor,
    source: ?map_state.ArtifactId = null,

    pub fn deinit(self: *TestSessionDiscoveryCursor) void {
        if (self.current) |*current| current.deinit();
        if (self.roots) |*roots| roots.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *TestSessionDiscoveryCursor) Registry.TestDiscoveryProgress {
        if (self.current) |*current| switch (current.advance()) {
            .pending => return .pending,
            .item => |item| return .{ .item = .{ .module = item.module, .metadata = item.metadata, .source = self.source } },
            .complete => {
                current.deinit();
                self.current = null;
                return .pending;
            },
        };
        if (self.roots) |*roots| switch (roots.advance()) {
            .pending => return .pending,
            .item => |source| {
                const id = source.location().artifact_id;
                if (self.project.?.artifactCommitted(id)) {
                    self.current = .init(source.registry());
                    self.source = id;
                }
                return .pending;
            },
            .complete => {
                roots.deinit();
                self.roots = null;
            },
        };
        return .complete;
    }
};

/// The identity executing frames run under: the image whose code is running,
/// which fixes private lookup, same-home dispatch, and diagnostic spelling.
/// Observation leases never expose this pointer; only code holding the
/// Session's execution authority can obtain its scope or another pin.
pub const ModuleHome = opaque {
    fn init(target: *ModuleImage) *ModuleHome {
        return @ptrCast(target);
    }
    fn image(self: *const ModuleHome) *ModuleImage {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn scope(self: *const ModuleHome, _: *const ExecutionAccess) *env.Scope {
        return &self.image().scope;
    }
    /// The canonical name this code was built for, fixed before its body ran.
    pub fn name(self: *const ModuleHome) intern.ModuleName {
        return self.image().name;
    }
    /// Zero while the image is still under construction.
    pub fn generationNumber(self: *const ModuleHome) u64 {
        return self.image().generation;
    }
    pub fn registrationProvenance(self: *const ModuleHome) RegistrationProvenance {
        return self.image().provenance;
    }
    fn pinInternal(self: *const ModuleHome) GenerationPin {
        self.image().retain();
        return .initRetained(self.image());
    }
    pub fn pin(self: *const ModuleHome, _: *const ExecutionAccess) GenerationPin {
        return self.pinInternal();
    }
    /// One name in the image's published directory, or null while the image
    /// is unpublished: a word written in an image under construction sees
    /// none of its staged names. The caller holds the image alive.
    pub fn lookupCursor(self: *const ModuleHome, binding: intern.BindingName) ?env.NameMap.RawLookupCursor {
        const names = self.image().directory() orelse return null;
        return names.rawLookup(binding);
    }
    /// The image's published names, or null while it is unpublished.
    pub fn publishedEntries(self: *const ModuleHome) ?env.NameMap.RawEntryCursor {
        const names = self.image().directory() orelse return null;
        return names.rawEntries();
    }
    /// Whether the registry has published this image.
    pub fn isPublished(self: *const ModuleHome) bool {
        return self.image().published.load(.acquire);
    }
};

/// The home a definition belongs to, or null for a core or session definition.
pub fn definitionHome(definition: *const env.Definition) ?*ModuleHome {
    const handle = definition.home orelse return null;
    return @ptrCast(handle);
}

/// An owned execution reference to one image. The raw image is never exposed,
/// so a pin can only be consumed by `deinit` and cannot invoke retirement
/// directly.
pub const GenerationPin = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(retained: *ModuleImage) GenerationPin {
        return @fromBackingInt(@intCast(@intFromPtr(retained)));
    }
    fn image(self: GenerationPin) *ModuleImage {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@backingInt(self));
    }
    fn homeInternal(self: GenerationPin) *ModuleHome {
        return .init(self.image());
    }
    /// Split from `homeInternal` because the audit rejects one function that
    /// both holds a capability token and casts a pointer.
    pub fn home(self: GenerationPin, _: *const ExecutionAccess) *ModuleHome {
        return self.homeInternal();
    }
    pub fn deinit(self: *GenerationPin) void {
        if (self.* == .consumed) return;
        self.image().release();
        self.* = .consumed;
    }
    /// Whether two pins hold the same owner. Exposes nothing: a pin is already
    /// an opaque integer, and this only compares two of them. It exists so a
    /// pin adopted from a borrow can be deduplicated against pins already held
    /// without anyone learning what it points at.
    pub fn sameOwner(self: GenerationPin, other: GenerationPin) bool {
        return @backingInt(self) == @backingInt(other);
    }

    pub fn matches(
        self: GenerationPin,
        expected_home: *const ModuleHome,
        _: *const ExecutionAccess,
    ) bool {
        return self.homeInternal() == expected_home;
    }
};

/// The home of the image a module-root scope belongs to, or null for any other
/// scope.
///
/// The cast is sound because `env.Scope.moduleRoot` has exactly one caller —
/// `ModuleImage.create` — so every module-root scope is an image's own embedded
/// `scope` field. Re-verified when this was written; a second caller would
/// falsify it, which is why the check belongs in review and not only here.
///
/// Takes no `ExecutionAccess`: the token gates `ModuleHome`'s methods while the
/// pointer alone grants nothing, and the audit rejects one function that both holds a token and
/// casts a pointer.
pub fn homeForModuleRootScope(scope: *env.Scope) ?*ModuleHome {
    if (!scope.isModuleRoot()) return null;
    const image: *ModuleImage = @fieldParentPtr("scope", scope);
    return ModuleHome.init(image);
}

test "modules: an image's home is reachable from its own root scope" {
    var host = heap.HostOwner.init(std.testing.allocator);
    const releases = host.domain();
    defer host.cleanup().drain();

    var container = try env.Env.init(&host);
    defer container.deinit();

    const image = try ModuleImage.create(std.testing.allocator, releases, try intern.internModuleName("image-probe"), .ordinary);
    defer image.release();

    const recovered = homeForModuleRootScope(&image.scope) orelse
        return error.ExpectedImageHome;
    try std.testing.expectEqual(ModuleHome.init(image), recovered);
    try std.testing.expectEqual(image.name, recovered.name());

    var session_scope = container.sessionRoot(std.testing.allocator);
    defer env.testing.deinitScope(&session_scope, releases);
    try std.testing.expectEqual(
        @as(?*ModuleHome, null),
        homeForModuleRootScope(&session_scope),
    );
}

test "modules: a stamped retired image leaves one anchor and an unstamped one leaves nothing" {
    // Registry-level rather than Session-level, and every sample is taken after
    // an explicit drain to quiescence. A Session-level version of this measured
    // 52KB per cycle against an expected 40 bytes: it was sampling deferred
    // retirement backlog rather than settled memory. Absolute settled-memory bounds
    // are only assertable where the drains are controllable.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = @import("alloc_options").trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        var container = try env.Env.init(&host);

        const rounds = 64;

        // An image nothing ever stamped is destroyed in full, anchor included.
        host.cleanup().drain();
        const unstamped_base = counting.total_requested_bytes;
        for (0..rounds) |_| {
            const image = try ModuleImage.create(allocator, releases, try intern.internModuleName("image-probe"), .ordinary);
            image.release();
            host.cleanup().drain();
        }
        try std.testing.expectEqual(
            @as(usize, 0),
            counting.total_requested_bytes -| unstamped_base,
        );

        // A stamped image mints its cell exactly as `moduleOwned` does, and
        // leaves precisely that cell plus its parked anchor behind.
        const stamped_base = counting.total_requested_bytes;
        for (0..rounds) |_| {
            const image = try ModuleImage.create(allocator, releases, try intern.internModuleName("image-probe"), .ordinary);
            _ = try container.scopeIdForOwned(&image.scope, @ptrCast(image.anchor));
            image.release();
            host.cleanup().drain();
        }
        const stamped_growth = counting.total_requested_bytes -| stamped_base;
        const per_cycle = @sizeOf(RefAnchor) + @sizeOf(env.ScopeCell);
        // Directory pages are installed in blocks, so they are slack above the
        // per-cycle floor rather than part of it. The floor is the assertion
        // that matters: reintroducing in-place header parking would put
        // @sizeOf(ModuleImage) per cycle here instead of an anchor.
        try std.testing.expect(stamped_growth >= rounds * per_cycle);
        try std.testing.expect(stamped_growth <= rounds * per_cycle + 8192);

        container.deinit();
        host.cleanup().reclaimTombstones(destroyParkedAnchor);
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "modules: a borrow holds an image's contents across a full drain" {
    // The necessity half of the borrow's gate, and deliberately deterministic.
    //
    // The stochastic version -- racing a resolver against an image's last
    // release from ECL -- cannot discriminate, because four separate mechanisms
    // already narrow the window to instruction scale that no ECL-level yield can
    // land inside: a superseded directory keeps its entries until its last reader
    // leaves, the resolution walk's counted lookup cursor
    // together with the environment teardown wait covers the lookup, and
    // `scheduleWord`'s pin covers the frame. So the borrow's necessity is stated
    // here as an API fact instead, where the drop can be constructed exactly and
    // the verdict is the same on every run.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = @import("alloc_options").trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        var container = try env.Env.init(&host);

        const image = try ModuleImage.create(allocator, releases, try intern.internModuleName("image-probe"), .ordinary);
        const owner: *env.ImageAnchor = @ptrCast(image.anchor);
        _ = try container.scopeIdForOwned(&image.scope, owner);
        const cell = try container.scopeCell(&image.scope, owner);

        // Exercise the real primitive directly.
        var borrowed = tryPinAnchorInternal(owner) orelse
            return error.ExpectedLiveBorrow;

        const before_drop = counting.total_requested_bytes;
        // The last reference anything outside the borrow holds.
        image.release();
        host.cleanup().drain();

        // Nothing was reclaimed: the borrow is what holds the contents. Remove
        // the acquire from `executeWord`, or take it after the walk instead of
        // before, and this is the assertion that fails -- on every run.
        //
        // Verified by building the misplaced-pin variant: with the acquire
        // removed the tier does not pass, though it *hangs* rather than failing
        // here, because the later `deinit` releases a count already at zero.
        // A regression must surface as a timeout before any assertion fires.
        try std.testing.expectEqual(before_drop, counting.total_requested_bytes);
        // And the scope is still reachable through its proof arm, which is what
        // resolution does with it.
        try std.testing.expectEqual(
            @as(?*env.Scope, &image.scope),
            cell.scopeUnder(.fresh_pin),
        );
        try std.testing.expectEqual(
            ModuleHome.init(image),
            homeForModuleRootScope(&image.scope),
        );

        borrowed.deinit();
        host.cleanup().drain();

        // Now the contents are gone, and a borrow attempted after the fact fails
        // its acquire rather than resurrecting anything.
        try std.testing.expect(counting.total_requested_bytes < before_drop);
        try std.testing.expectEqual(
            @as(?GenerationPin, null),
            tryPinAnchorInternal(owner),
        );

        container.deinit();
        host.cleanup().reclaimTombstones(destroyParkedAnchor);
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "modules: the same drop with no borrow reclaims the contents" {
    // The strawman the stochastic tests could not express: identical to the test
    // above except that no borrow is taken. If the contents survived here too,
    // the borrow above would be proving nothing about the borrow.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = @import("alloc_options").trace_frames }) = .init;
    const allocator = counting.allocator();
    {
        var host = heap.HostOwner.init(allocator);
        const releases = host.domain();
        var container = try env.Env.init(&host);

        const image = try ModuleImage.create(allocator, releases, try intern.internModuleName("image-probe"), .ordinary);
        const owner: *env.ImageAnchor = @ptrCast(image.anchor);
        _ = try container.scopeIdForOwned(&image.scope, owner);

        const before_drop = counting.total_requested_bytes;
        image.release();
        host.cleanup().drain();

        try std.testing.expect(counting.total_requested_bytes < before_drop);
        // The anchor outlived the image, so the failed acquire is a verdict
        // rather than a fault: this read is exactly what a stale word does.
        try std.testing.expectEqual(
            @as(?GenerationPin, null),
            tryPinAnchorInternal(owner),
        );

        container.deinit();
        host.cleanup().reclaimTombstones(destroyParkedAnchor);
        host.cleanup().drain();
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

/// Opaque observation capability owning one reference to a published image.
pub const GenerationLease = enum(usize) {
    consumed = 0,
    _,

    fn initRetained(retained: *ModuleImage) GenerationLease {
        return @fromBackingInt(@intCast(@intFromPtr(retained)));
    }
    fn image(self: GenerationLease) *ModuleImage {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@backingInt(self));
    }
    pub fn generationNumber(self: GenerationLease) u64 {
        return self.image().generation;
    }
    pub fn name(self: GenerationLease) intern.ModuleName {
        return self.image().name;
    }
    pub fn provenance(self: GenerationLease) RegistrationProvenance {
        return self.image().provenance;
    }
    /// One name in this published generation's directory.
    pub fn lookupCursor(self: GenerationLease, binding: intern.BindingName) ModuleNameLookupCursor {
        const retained = self.image();
        return .{
            .lookup = if (retained.directory()) |names| names.rawLookup(binding) else null,
            .pin = ModuleHome.init(retained).pinInternal(),
        };
    }
    pub fn publicNameCursor(self: GenerationLease) ModulePublicNameCursor {
        return publicNameCursorFor(self.image());
    }
    fn testNameCursor(self: GenerationLease) TestCatalog.NameCursor {
        return .{ .next = self.image().tests.entries_head };
    }
    fn testLookupCursor(
        self: GenerationLease,
        test_name: intern.BindingName,
    ) TestCatalog.LookupCursor {
        return .{
            .current = self.image().tests.root,
            .name = test_name,
        };
    }
    /// Session-gated transfer from observation to execution. The raw image
    /// stays hidden on both sides, which is why an activation's home can only
    /// come from the registry lease it was resolved through.
    pub fn enterExecution(
        self: *GenerationLease,
        _: *const ExecutionAccess,
    ) GenerationPin {
        const retained = self.image();
        self.* = .consumed;
        return .initRetained(retained);
    }
    pub fn deinit(self: *GenerationLease) void {
        if (self.* == .consumed) return;
        self.image().release();
        self.* = .consumed;
    }
};

/// A borrowed reference to one immutable image, valid for the call it is passed
/// Unique ownership of an image that no registration holds yet. Every exit
/// either seals it into a `SealedImage` or releases it.
pub const OwnedImage = enum(usize) {
    consumed = 0,
    _,

    fn init(target: *ModuleImage) OwnedImage {
        return @fromBackingInt(@intCast(@intFromPtr(target)));
    }
    fn borrow(self: *const OwnedImage) *ModuleImage {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@backingInt(self.*));
    }
    pub fn executionHome(
        self: *const OwnedImage,
        _: *const ExecutionAccess,
    ) *ModuleHome {
        return .init(self.borrow());
    }
    pub fn moduleName(self: *const OwnedImage) intern.ModuleName {
        return self.borrow().name;
    }
    pub fn provenance(self: *const OwnedImage) RegistrationProvenance {
        return self.borrow().provenance;
    }
    /// Stages one definition of the construction group. The publication's
    /// values are retained by the staged definition; the caller keeps its own.
    pub fn stageDefinition(
        self: *const OwnedImage,
        name: intern.BindingName,
        publication: env.ModulePublication,
    ) error{OutOfMemory}!void {
        const image = self.borrow();
        const origin: env.BindingOrigin = .{ .module_local = .{ .trace_word = name } };
        const handle: *anyopaque = @ptrCast(image);
        const created = switch (publication) {
            .word => |word| try env.Definition.reserve(image.allocator, .static, env.quotationHeader(word.body), .{
                .visibility = word.visibility,
                .origin = origin,
                .effect = word.effect,
                .doc = word.doc,
                .source = word.source,
                .root = .image,
                .home = handle,
            }),
            .native => |native| try env.Definition.create(image.allocator, .static, .{ .native = native.callable }, .{
                .visibility = native.visibility,
                .origin = origin,
                .effect = native.effect,
                .doc = native.doc,
                .root = .image,
                .home = handle,
            }),
            .builtin => |primitive| try env.Definition.create(image.allocator, .static, .{ .builtin = primitive.primitive }, .{
                .visibility = primitive.visibility,
                .origin = origin,
                .effect = primitive.effect,
                .doc = primitive.doc,
                .root = .image,
                .home = handle,
            }),
        };
        image.stage(name, .{ .definition = created }) catch |err| {
            created.retireStatic(image.releases);
            return err;
        };
    }
    /// Stages one name alias of the construction group.
    pub fn stageAlias(self: *const OwnedImage, name: intern.BindingName, alias: env.Alias) error{OutOfMemory}!void {
        return self.borrow().stage(name, .{ .alias = alias });
    }
    /// Turns the staged names into the image's directory. Each name may be
    /// introduced once: a duplicate fails construction.
    pub fn groupCursor(self: *const OwnedImage) GroupCursor {
        return .{ .image = self.borrow() };
    }
    /// The group's directory, for binding its own bodies. Valid once the
    /// group cursor has completed.
    pub fn groupDirectory(self: *const OwnedImage) *const env.NameMap {
        return &self.borrow().names.?;
    }
    /// The group's entries, for binding each reserved body in turn.
    pub fn groupEntries(self: *const OwnedImage) env.NameMap.RawEntryCursor {
        return self.borrow().names.?.rawEntries();
    }
    pub fn testDeclarationCursor(
        self: *const OwnedImage,
        name: intern.BindingName,
        body: *env.Quotation,
        effect: ?env.ValidatedEffect,
        doc: ?*env.DocumentationString,
    ) TestDeclarationCursor {
        return .{ .state = .{ .catalog = self.borrow().tests.declareCursor(
            name,
            body,
            effect,
            doc,
        ) } };
    }
    pub const LiteralSealError = error{ OutOfMemory, Duplicate, UnboundWord };

    /// Seals a group whose bodies execute no words: builtin- and native-backed
    /// modules, whose definitions are host callbacks and literal-only bodies.
    /// Their size is fixed by a compiled-in or validated descriptor.
    pub fn sealLiteralGroup(self: *OwnedImage) LiteralSealError!SealedImage {
        const image = self.borrow();
        var group = self.groupCursor();
        defer group.deinit();
        while (true) switch (try group.advance()) {
            .pending => {},
            .complete => break,
        };
        var entries = self.groupEntries();
        while (true) switch (entries.advance()) {
            .pending => {},
            .complete => break,
            .item => |entry| switch (entry.value) {
                .definition => |definition| if (definition.isReserved()) try definition.sealLiteral(image.releases),
                .alias => {},
            },
        };
        return self.seal();
    }
    /// Ends construction once every body of the group is bound. Consuming
    /// this capability is the one transition after which nothing can mutate
    /// the image, so it can be registered or handed to a program.
    pub fn seal(self: *OwnedImage) SealedImage {
        const image = self.borrow();
        std.debug.assert(image.names != null and image.staging.isEmpty());
        image.tests.freeze();
        self.* = .consumed;
        return .init(image);
    }
    pub fn move(self: *OwnedImage) OwnedImage {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn deinit(self: *OwnedImage) void {
        if (self.* == .consumed) return;
        // Rollback drops the construction owner's reference; an activation
        // still pinning the image keeps it alive until it unwinds.
        self.borrow().release();
        self.* = .consumed;
    }
};

/// Builds an image's directory from its staged names in bounded steps. The
/// partial directory belongs to the image from the first step, so abandoning
/// the cursor leaves nothing for it to release.
pub const GroupCursor = struct {
    image: *ModuleImage,
    init: ?env.NameMap.InitCursor = null,
    put: ?env.NameMap.PutCursor = null,
    lookup: ?struct { staged: StagedName, cursor: env.NameMap.RawLookupCursor } = null,
    /// The name a failed construction introduced twice.
    duplicate: ?intern.BindingName = null,

    pub const Error = error{ OutOfMemory, Duplicate };

    pub fn deinit(self: *GroupCursor) void {
        if (self.init) |*cursor| cursor.deinit();
        if (self.lookup) |pending| ModuleImage.retireEntry(pending.staged.entry, self.image.releases);
        self.* = undefined;
    }

    pub fn advance(self: *GroupCursor) Error!poll.Progress(void) {
        const image = self.image;
        if (image.names == null) {
            if (self.init == null) self.init = env.NameMap.initCursor(image.allocator, image.staged_count);
            const cursor = &self.init.?;
            switch (try cursor.advance()) {
                .pending => {},
                .complete => |map| {
                    self.init = null;
                    image.names = map;
                },
            }
            return .pending;
        }
        if (self.put) |*put| {
            switch (put.advance()) {
                .pending => {},
                .complete => self.put = null,
            }
            return .pending;
        }
        if (self.lookup) |*pending| {
            switch (pending.cursor.advance()) {
                .pending => {},
                .complete => |existing| {
                    const staged = pending.staged;
                    self.lookup = null;
                    if (existing != null) {
                        ModuleImage.retireEntry(staged.entry, image.releases);
                        self.duplicate = staged.name;
                        return error.Duplicate;
                    }
                    self.put = image.names.?.putCursor(staged.name, staged.entry);
                },
            }
            return .pending;
        }
        const staged = image.staging.pop() orelse return .complete;
        image.staged_count -= 1;
        self.lookup = .{ .staged = staged, .cursor = image.names.?.rawLookup(staged.name) };
        return .pending;
    }
};

/// Unique ownership of a finished image. It has no mutation surface at all:
/// the only things left to do with an image are move it into a registration
/// cursor or release it.
pub const SealedImage = enum(usize) {
    consumed = 0,
    _,

    fn init(target: *ModuleImage) SealedImage {
        return @fromBackingInt(@intCast(@intFromPtr(target)));
    }
    fn borrow(self: *const SealedImage) *ModuleImage {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@backingInt(self.*));
    }
    pub fn move(self: *SealedImage) SealedImage {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn deinit(self: *SealedImage) void {
        if (self.* == .consumed) return;
        self.borrow().release();
        self.* = .consumed;
    }
};

pub const CommitError = error{
    OutOfMemory,
    NameConflict,
    /// The exact name `core` is the core qualifier, never a registration.
    ReservedName,
};
pub const AliasError = error{
    OutOfMemory,
    NameConflict,
    /// The exact name `core` is the core qualifier, never an alias.
    ReservedName,
    MissingModule,
};

/// Identifies who holds a loading lease. A second request from the same
/// owner is a genuine cycle; one from a different owner is ordinary
/// contention, which must wait rather than fail. Storing the owner *as* the
/// lease slot makes the two states one atomic read: there is no window where
/// a node is held by nobody in particular.
pub const LoadingOwner = enum(usize) {
    _,

    pub fn of(holder: *const anyopaque) LoadingOwner {
        return @fromBackingInt(@intCast(@intFromPtr(holder)));
    }
    fn token(self: LoadingOwner) usize {
        const raw = @backingInt(self);
        std.debug.assert(raw != free_loading_owner);
        return raw;
    }
};
const free_loading_owner: usize = 0;

const LoadingKey = union(enum) {
    module: intern.ModuleName,
    artifact: map_state.ArtifactId,

    fn eql(left: LoadingKey, right: LoadingKey) bool {
        return switch (left) {
            .module => |name| right == .module and right.module == name,
            .artifact => |artifact| right == .artifact and right.artifact == artifact,
        };
    }
};

/// What a request for a loading lease produced.
pub const LoadingOutcome = union(enum) {
    /// The caller owns the load and must release the lease.
    granted: LoadingLease,
    /// This owner already holds a lease on the name.
    cycle,
    /// Another owner holds it; the caller must wait and re-resolve.
    contended,
};

const LoadingNode = struct {
    registry: *Registry,
    key: LoadingKey,
    owner: std.atomic.Value(usize),
    next: ?*LoadingNode,
};
/// The authority to make one artifact's registrations visible. Only
/// `LoadingLease.artifactCommit` mints one, and only from a live lease keyed
/// to that artifact, so a holder of the project lock cannot publish an
/// artifact whose declarations nobody verified. An `ArtifactId` names an
/// artifact; this names the right to publish it.
pub const ArtifactCommit = enum(u32) {
    _,

    fn init(published: map_state.ArtifactId) ArtifactCommit {
        return @fromBackingInt(@intCast(@backingInt(published)));
    }
    pub fn artifact(self: ArtifactCommit) map_state.ArtifactId {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }
};

pub const LoadingLease = enum(usize) {
    finished = 0,
    _,

    fn init(loading: *LoadingNode) LoadingLease {
        return @fromBackingInt(@intCast(@intFromPtr(loading)));
    }
    /// Trade a live artifact lease for the authority to publish that
    /// artifact. The lease is not released here: publication must become
    /// visible before the lease frees, or a contender would find the artifact
    /// uncommitted and reload it. `finish` follows on the same step.
    pub fn artifactCommit(self: *LoadingLease) ArtifactCommit {
        return switch (self.node().key) {
            .artifact => |artifact| .init(artifact),
            .module => @panic("a module loading lease cannot publish an artifact"),
        };
    }
    fn node(self: LoadingLease) *LoadingNode {
        std.debug.assert(self != .finished);
        return @ptrFromInt(@backingInt(self));
    }
    pub fn move(self: *LoadingLease) LoadingLease {
        const result = self.*;
        std.debug.assert(result != .finished);
        self.* = .finished;
        return result;
    }
    pub fn finish(self: *LoadingLease) void {
        const loading = self.node();
        loading.owner.store(free_loading_owner, .release);
        self.* = .finished;
    }
    pub fn deinit(self: *LoadingLease) void {
        if (self.* == .finished) return;
        const loading = self.node();
        loading.owner.store(free_loading_owner, .release);
        self.* = .finished;
    }
};
const RegistryState = struct {
    host: *const heap.HostCleanup,
    writer: std.Io.Mutex = .init,
    directories: DirectoryPublisher,
    /// Every image this registry has published, newest first. Each holds one
    /// reference until teardown, so code bound to a replaced image and words
    /// written in it keep their meaning for the Session's life.
    history: ?*ModuleImage = null,
    loading: std.atomic.Value(?*LoadingNode) = .init(null),
    /// The Session's publication counter, owned by its main registry and
    /// borrowed by each source-private one. Every edit to any registry of
    /// the Session advances it; it holds no snapshot and only keys reuse.
    publications: std.atomic.Value(u64) = .init(1),
    clock: *std.atomic.Value(u64),
};

pub const Registry = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Registry) *RegistryState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@backingInt(self.*));
    }

    /// A Session's main registry, which owns the Session's publication counter.
    pub fn init(host: *const heap.HostCleanup) error{OutOfMemory}!Registry {
        const backing = try host.allocator().create(RegistryState);
        // SAFETY: the counter lives in this backing; it is pointed at next.
        backing.* = .{ .host = host, .directories = .init(null), .clock = undefined };
        backing.clock = &backing.publications;
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }

    /// A source-private registry of the Session `main` belongs to. It shares
    /// `main`'s publication counter and must be torn down before `main`.
    pub fn initPrivate(host: *const heap.HostCleanup, main: *const Registry) error{OutOfMemory}!Registry {
        const backing = try host.allocator().create(RegistryState);
        backing.* = .{ .host = host, .directories = .init(null), .clock = main.privateState().clock };
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }

    /// The Session's publication identity now, for keying a reusable binding.
    pub fn currentPublication(self: *const Registry) u64 {
        return self.privateState().clock.load(.acquire);
    }

    /// Mint the capability seal owned by a test-mode Session. Its backing
    /// carries the registry rather than accepting one alongside the access
    /// token, so cross-Session authority substitution is unrepresentable.
    pub fn createTestAuthority(self: *Registry, project: ?*const map_state.Snapshot) error{OutOfMemory}!TestAuthority {
        const state = try self.allocator().create(TestAuthorityState);
        state.* = .{ .registry = self.*, .project = project };
        return .init(state);
    }

    fn allocator(self: *const Registry) std.mem.Allocator {
        return self.privateState().host.allocator();
    }

    fn releaseDomain(self: *const Registry) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    pub fn deinit(self: *Registry) void {
        const backing = self.privateState();
        const owner_allocator = backing.host.allocator();
        std.debug.assert(backing.directories.quiescent());
        Directory.destroyChain(backing.directories.currentOwned(), self.allocator(), self.releaseDomain());
        var history = backing.history;
        while (history) |image| {
            history = image.history_next;
            image.release();
        }
        var loading = backing.loading.load(.acquire);
        while (loading) |node| {
            loading = node.next;
            self.allocator().destroy(node);
        }
        backing.host.drain();
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }

    fn lockBlocking(self: *Registry) void {
        std.Io.Threaded.mutexLockUncancelable(&self.privateState().writer);
    }

    fn unlock(self: *Registry) void {
        std.Io.Threaded.mutexUnlock(&self.privateState().writer);
    }

    fn acquireDirectory(self: *const Registry) DirectoryLease {
        const lease = self.privateState().directories.acquire();
        return .{
            .registry = self,
            .directory = lease.snapshot,
            .lease = lease,
        };
    }

    pub const NamespaceProgress = poll.StreamProgress(u32);
    /// Snapshot-owning enumeration of canonical module and alias names. The
    /// directory representation remains private and the lease survives until
    /// the cursor is explicitly released, including when iteration is
    /// abandoned early.
    pub const NamespaceCursor = struct {
        directory: DirectoryLease,
        phase: enum { modules, aliases, complete } = .modules,
        modules: ?Directory.ModuleMap.RawEntryCursor = null,
        aliases: ?Directory.AliasMap.RawEntryCursor = null,

        pub fn deinit(self: *NamespaceCursor) void {
            self.directory.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NamespaceCursor) NamespaceProgress {
            while (true) switch (self.phase) {
                .modules => {
                    const entries = &(self.modules orelse {
                        self.phase = .aliases;
                        continue;
                    });
                    switch (entries.advance()) {
                        .pending => return .pending,
                        .item => |entry| return .{ .item = intern.moduleId(entry.key) },
                        .complete => {
                            self.modules = null;
                            self.phase = .aliases;
                        },
                    }
                },
                .aliases => {
                    const entries = &(self.aliases orelse {
                        self.phase = .complete;
                        return .complete;
                    });
                    switch (entries.advance()) {
                        .pending => return .pending,
                        .item => |entry| return .{ .item = intern.bindingId(entry.key) },
                        .complete => {
                            self.aliases = null;
                            self.phase = .complete;
                            return .complete;
                        },
                    }
                },
                .complete => return .complete,
            };
        }
    };

    pub fn namespaceCursor(self: *const Registry) NamespaceCursor {
        const directory = self.acquireDirectory();
        return .{
            .directory = directory,
            .modules = if (directory.directory) |current| current.modules.rawEntries() else null,
            .aliases = if (directory.directory) |current| current.aliases.rawEntries() else null,
        };
    }

    pub const DiscoveredTest = struct {
        module: intern.ModuleName,
        source: ?map_state.ArtifactId = null,
        metadata: ModuleTestMetadata,
    };
    pub const TestDiscoveryProgress = poll.StreamProgress(DiscoveredTest);

    /// Canonical-only discovery over one directory snapshot. The cursor owns
    /// both the directory lease and each generation lease for the complete
    /// time it borrows that generation's catalog.
    pub const TestDiscoveryCursor = struct {
        registry: *Registry,
        directory: DirectoryLease,
        modules: ?Directory.ModuleMap.RawEntryCursor,
        current_module: ?intern.ModuleName = null,
        current_generation: ?GenerationLease = null,
        names: ?TestCatalog.NameCursor = null,
        complete: bool = false,

        fn init(registry: *Registry) TestDiscoveryCursor {
            const directory = registry.acquireDirectory();
            return .{
                .registry = registry,
                .directory = directory,
                .modules = if (directory.directory) |current| current.modules.rawEntries() else null,
            };
        }

        pub fn deinit(self: *TestDiscoveryCursor) void {
            if (self.current_generation) |*generation| generation.deinit();
            self.directory.deinit();
            self.* = undefined;
        }

        fn beginGeneration(
            self: *TestDiscoveryCursor,
            module_name: intern.ModuleName,
            generation: GenerationLease,
        ) void {
            self.current_module = module_name;
            self.current_generation = generation;
            self.names = generation.testNameCursor();
        }

        pub fn advance(self: *TestDiscoveryCursor) TestDiscoveryProgress {
            std.debug.assert(!self.complete);
            if (self.names) |*names| switch (names.advance()) {
                .pending => return .pending,
                .item => |metadata| return .{ .item = .{
                    .module = self.current_module.?,
                    .metadata = metadata,
                } },
                .complete => {
                    self.names = null;
                    self.current_generation.?.deinit();
                    self.current_generation = null;
                    self.current_module = null;
                    return .pending;
                },
            };
            const entries = &(self.modules orelse {
                self.complete = true;
                return .complete;
            });
            return switch (entries.advance()) {
                .pending => .pending,
                .complete => result: {
                    self.modules = null;
                    self.complete = true;
                    break :result .complete;
                },
                .item => |entry| result: {
                    entry.value.retain();
                    self.beginGeneration(entry.key, GenerationLease.initRetained(entry.value));
                    break :result .pending;
                },
            };
        }
    };

    pub const TestInvocation = struct {
        generation: GenerationLease,
        body: *env.Quotation,

        pub fn enter(
            self: *TestInvocation,
            access: *const ExecutionAccess,
        ) TestExecutionTarget {
            const body = self.body;
            return .{
                .generation = self.generation.enterExecution(access),
                .body = body,
            };
        }
        pub fn deinit(self: *TestInvocation) void {
            self.generation.deinit();
            self.* = undefined;
        }
    };

    pub const TestExecutionTarget = struct {
        generation: GenerationPin,
        body: *env.Quotation,

        pub fn quotation(self: *const TestExecutionTarget) *value.ListHandle {
            return env.quotationHeader(self.body);
        }
        pub fn home(
            self: *const TestExecutionTarget,
            access: *const ExecutionAccess,
        ) *ModuleHome {
            return self.generation.home(access);
        }
        pub fn deinit(self: *TestExecutionTarget) void {
            self.generation.deinit();
            self.* = undefined;
        }
    };

    pub const TestLookupProgress = poll.Progress(?TestInvocation);
    pub const TestLookupCursor = struct {
        registry: *Registry,
        directory: DirectoryLease,
        module_name: intern.ModuleName,
        test_name: intern.BindingName,
        state: State,

        const State = union(enum) {
            absent,
            module: Directory.ModuleMap.RawLookupCursor,
            catalog: struct {
                lease: GenerationLease,
                cursor: TestCatalog.LookupCursor,
            },
            complete,
        };

        fn init(
            registry: *Registry,
            module_name: intern.ModuleName,
            test_name: intern.BindingName,
        ) TestLookupCursor {
            const directory = registry.acquireDirectory();
            return .{
                .registry = registry,
                .directory = directory,
                .module_name = module_name,
                .test_name = test_name,
                .state = if (directory.directory) |current|
                    .{ .module = current.modules.rawLookup(module_name) }
                else
                    .absent,
            };
        }

        pub fn deinit(self: *TestLookupCursor) void {
            switch (self.state) {
                .catalog => |*catalog| catalog.lease.deinit(),
                .absent, .module, .complete => {},
            }
            self.directory.deinit();
            self.* = undefined;
        }

        fn beginCatalog(self: *TestLookupCursor, lease: GenerationLease) void {
            self.state = .{ .catalog = .{
                .lease = lease,
                .cursor = lease.testLookupCursor(self.test_name),
            } };
        }

        pub fn advance(self: *TestLookupCursor) TestLookupProgress {
            return switch (self.state) {
                .absent => result: {
                    self.state = .complete;
                    break :result .{ .complete = null };
                },
                .module => |*lookup| switch (lookup.advance()) {
                    .pending => .pending,
                    .complete => |image| result: {
                        const found = image orelse {
                            self.state = .complete;
                            break :result .{ .complete = null };
                        };
                        found.retain();
                        self.beginCatalog(GenerationLease.initRetained(found));
                        break :result .pending;
                    },
                },
                .catalog => |*catalog| switch (catalog.cursor.advance()) {
                    .pending => .pending,
                    .complete => |body| result: {
                        if (body) |quotation| {
                            const lease = catalog.lease;
                            self.state = .complete;
                            break :result .{ .complete = .{
                                .generation = lease,
                                .body = quotation,
                            } };
                        }
                        catalog.lease.deinit();
                        self.state = .complete;
                        break :result .{ .complete = null };
                    },
                },
                .complete => unreachable,
            };
        }
    };

    fn detachRetiredDirectories(self: *Registry) ?*Directory {
        if (!self.privateState().directories.quiescent()) return null;
        const current = self.privateState().directories.currentOwned() orelse return null;
        const retired = current.previous;
        current.previous = null;
        return retired;
    }

    /// A fresh image for `name`. The caller has validated the name; the
    /// registry checks it again at publication, which is the boundary that
    /// owns registry names.
    pub fn createImage(
        self: *Registry,
        name: intern.ModuleName,
        provenance: RegistrationProvenance,
    ) error{OutOfMemory}!OwnedImage {
        return .init(try ModuleImage.create(self.allocator(), self.releaseDomain(), name, provenance));
    }

    pub const NativeCandidateProgress = poll.Progress(OwnedImage);

    /// The single bounded native-definition publication path used by dynamic
    /// loading and static transport verification. Each turn installs at most
    /// one validated definition into the unpublished generation.
    pub const NativeCandidateCursor = struct {
        registry: *Registry,
        instance: *native_module.ModuleInstance,
        candidate: ?OwnedImage,
        definition_index: usize = 0,

        pub fn init(
            registry: *Registry,
            name: intern.ModuleName,
            provenance: RegistrationProvenance,
            instance: *native_module.ModuleInstance,
        ) error{OutOfMemory}!NativeCandidateCursor {
            return .{
                .registry = registry,
                .instance = instance,
                .candidate = try registry.createImage(name, provenance),
            };
        }

        pub fn deinit(self: *NativeCandidateCursor) void {
            if (self.candidate) |*candidate| candidate.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NativeCandidateCursor) error{OutOfMemory}!NativeCandidateProgress {
            const definitions = self.instance.validated().definitions();
            if (self.definition_index == definitions.len) {
                const completed = self.candidate.?.move();
                self.candidate = null;
                return .{ .complete = completed };
            }
            const definition = definitions[self.definition_index];
            const releases = self.registry.releaseDomain();
            var body: ?value.Value = null;
            defer if (body) |owned| releases.releaseValue(owned);
            const publication: env.ModulePublication = switch (definition.body) {
                .call => .{ .native = .{
                    .callable = .{
                        .instance = self.instance,
                        .definition = @intCast(self.definition_index),
                    },
                    .visibility = .public,
                    .effect = definition.effect,
                    .doc = definition.doc,
                } },
                .port => cap: {
                    const capability = try @import("native_port.zig").sealCapability(self.instance, @intCast(self.definition_index));
                    defer releases.releaseValue(capability);
                    body = try list.fromValues(self.registry.allocator(), &.{capability});
                    break :cap .{ .word = .{
                        .body = env.quotation(body.?.list).?,
                        .visibility = .public,
                        .effect = definition.effect,
                        .doc = definition.doc,
                    } };
                },
            };
            try self.candidate.?.stageDefinition(definition.name, publication);
            self.definition_index += 1;
            return .pending;
        }
    };

    pub const BuiltinCandidateProgress = poll.Progress(OwnedImage);

    /// Publication path for builtin-backed modules. One step installs one
    /// word, so a module with many words is as bounded as a native one; the
    /// effect and documentation values are built from the compiled-in text
    /// whose size is fixed at compile time.
    pub const BuiltinCandidateCursor = struct {
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        words: []const env.BuiltinWord,
        candidate: ?OwnedImage,
        word_index: usize = 0,

        pub fn init(
            registry: *Registry,
            name: intern.ModuleName,
            provenance: RegistrationProvenance,
            words: []const env.BuiltinWord,
        ) error{OutOfMemory}!BuiltinCandidateCursor {
            return .{
                .allocator = registry.allocator(),
                .releases = registry.releaseDomain(),
                .words = words,
                .candidate = try registry.createImage(name, provenance),
            };
        }

        pub fn deinit(self: *BuiltinCandidateCursor) void {
            if (self.candidate) |*candidate| candidate.deinit();
            self.* = undefined;
        }

        pub const Error = error{ OutOfMemory, InvalidName };

        pub fn advance(self: *BuiltinCandidateCursor) Error!BuiltinCandidateProgress {
            if (self.word_index == self.words.len) {
                const completed = self.candidate.?.move();
                self.candidate = null;
                return .{ .complete = completed };
            }
            const word = self.words[self.word_index];
            // Publication retains what it is handed, so this cursor releases
            // its own reference on every path.
            const document = try self.buildDocumentation(word.doc);
            defer self.releases.releaseHeader(env.documentationHeader(document));
            const effect = if (word.effect) |source| try self.buildEffect(source) else null;
            defer if (effect) |built| built.retire(self.releases);
            try self.candidate.?.stageDefinition(
                try intern.internNamespace(word.name),
                .{ .builtin = .{
                    .primitive = word.primitive,
                    .visibility = .public,
                    .effect = effect,
                    .doc = document,
                } },
            );
            self.word_index += 1;
            return .pending;
        }

        /// Compiled-in documentation is authored already normalized, so the
        /// text becomes a string value directly.
        fn buildDocumentation(
            self: *BuiltinCandidateCursor,
            source: []const u8,
        ) error{OutOfMemory}!*env.DocumentationString {
            var materializer = kernel_storage.TextMaterializer.init(self.allocator, source);
            defer materializer.retire(self.releases);
            var work = poll_api.unbounded();
            const text = try poll_api.driveFallible(value.Value, &materializer, .{&work});
            return env.documentation(text.list) orelse {
                self.releases.releaseValue(text);
                return error.OutOfMemory;
            };
        }

        fn buildEffect(
            self: *BuiltinCandidateCursor,
            source: []const u8,
        ) error{OutOfMemory}!env.ValidatedEffect {
            var tokens: [env.max_builtin_effect_tokens]value.Value = undefined;
            var count: usize = 0;
            var iterator = std.mem.tokenizeAny(u8, source, " \t");
            while (iterator.next()) |token| {
                if (count == tokens.len) return error.OutOfMemory;
                tokens[count] = .{ .symbol = .{ .name = try intern.intern(token) } };
                count += 1;
            }
            const owned = try list.fromValuesGeneric(self.allocator, tokens[0..count]);
            return env.ValidatedEffect.parse(owned.list, try intern.intern("--")) orelse {
                self.releases.releaseValue(owned);
                return error.OutOfMemory;
            };
        }
    };

    pub const CommitProgress = union(enum) { pending, complete: u64 };
    pub const AliasProgress = poll.Progress(void);
    pub const DefineProgress = poll.Progress(void);

    const EditKind = enum { register, alias, define };

    /// The one registry mutation. Snapshot the current directory, validate the
    /// request against it, build a successor with the edit applied, and publish
    /// the successor under the writer lock if the snapshot is still current;
    /// otherwise discard the candidate and start over. A racing edit of any
    /// kind is therefore observed as exactly one restart, never as a
    /// half-applied entry or a lost update. Registration, aliasing, and a
    /// top-level definition differ only in validation and in which entries
    /// change, so each is this cursor specialized at compile time.
    ///
    /// The candidate owns one reference per image and counted definition it
    /// copies, taken as the copy proceeds. Both outcomes retire it through
    /// `Directory.advanceRetirement`: publication chains it in front of the
    /// snapshot, and discard retires it alone, so neither path releases a
    /// user-sized map in one step.
    fn EditCursor(comptime kind: EditKind) type {
        return struct {
            const Self = @This();
            pub const Error = switch (kind) {
                .register => CommitError,
                .alias => AliasError,
                .define => error{OutOfMemory},
            };
            pub const Progress = switch (kind) {
                .register => CommitProgress,
                .alias => AliasProgress,
                .define => DefineProgress,
            };
            const Request = switch (kind) {
                .register => SealedImage,
                .alias => struct { short: intern.BindingName, target: intern.ModuleName },
                // The cursor owns one reference to a counted entry until it
                // is released; the published directory takes its own.
                .define => struct { name: intern.BindingName, entry: env.Entry },
            };
            const ModuleLookup = Directory.ModuleMap.RawLookupCursor;
            const AliasLookup = Directory.AliasMap.RawLookupCursor;

            /// What validation establishes: the canonical name the edit is
            /// about and, for a reload, the entry it replaces.
            const Target = struct {
                canonical: intern.ModuleName,
                prior: ?*ModuleImage,
            };
            const Validation = switch (kind) {
                .register => union(enum) {
                    /// The short form must not already be an alias.
                    alias_free: AliasLookup,
                    /// The generation a reload replaces, if any.
                    prior: ModuleLookup,
                },
                .alias => union(enum) {
                    /// The short form must not be a module name.
                    short_free: ModuleLookup,
                    target_module: ModuleLookup,
                    target_alias: AliasLookup,
                    /// An alias that already names its target is a no-op.
                    same_alias: struct { canonical: intern.ModuleName, lookup: AliasLookup },
                },
                .define => void,
            };
            const Maps = struct {
                modules: ?Directory.ModuleMap = null,
                aliases: ?Directory.AliasMap = null,
                names: ?env.NameMap = null,

                fn deinit(self: *Maps) void {
                    if (self.modules) |*map| map.deinit();
                    if (self.aliases) |*map| map.deinit();
                    if (self.names) |*map| map.deinit();
                    self.* = .{};
                }
            };
            const Build = struct {
                directory: DirectoryLease,
                target: Target,
                candidate: *Directory,
            };
            const State = union(enum) {
                snapshot,
                validate: struct { directory: DirectoryLease, step: Validation },
                init_maps: struct {
                    directory: DirectoryLease,
                    target: Target,
                    maps: Maps,
                    phase: enum { modules, aliases, names },
                    cursor: ?InitCursor = null,
                },
                copy_modules: struct {
                    build: Build,
                    entries: Directory.ModuleMap.RawEntryCursor,
                    insertion: ?Directory.ModuleMap.PutCursor = null,
                },
                put_module: struct { build: Build, cursor: Directory.ModuleMap.PutCursor },
                copy_aliases: struct {
                    build: Build,
                    entries: Directory.AliasMap.RawEntryCursor,
                    insertion: ?Directory.AliasMap.PutCursor = null,
                },
                put_alias: struct { build: Build, cursor: Directory.AliasMap.PutCursor },
                copy_names: struct {
                    build: Build,
                    entries: env.NameMap.RawEntryCursor,
                    insertion: ?env.NameMap.PutCursor = null,
                },
                put_name: struct { build: Build, cursor: env.NameMap.PutCursor },
                commit: Build,
                complete,
            };
            const InitCursor = union(enum) {
                modules: Directory.ModuleMap.InitCursor,
                aliases: Directory.AliasMap.InitCursor,
                names: env.NameMap.InitCursor,

                fn deinit(self: *InitCursor) void {
                    switch (self.*) {
                        inline else => |*cursor| cursor.deinit(),
                    }
                }
            };

            registry: *Registry,
            request: Request,
            state: State = .snapshot,

            pub fn deinit(self: *Self) void {
                switch (kind) {
                    .register => self.request.deinit(),
                    .define => self.request.entry.release(self.registry.releaseDomain()),
                    .alias => {},
                }
                switch (self.state) {
                    .snapshot, .complete => {},
                    .validate => |*state| state.directory.deinit(),
                    .init_maps => |*state| {
                        if (state.cursor) |*cursor| cursor.deinit();
                        state.maps.deinit();
                        state.directory.deinit();
                    },
                    .copy_modules => |*state| self.discard(&state.build),
                    .put_module => |*state| self.discard(&state.build),
                    .copy_aliases => |*state| self.discard(&state.build),
                    .put_alias => |*state| self.discard(&state.build),
                    .copy_names => |*state| self.discard(&state.build),
                    .put_name => |*state| self.discard(&state.build),
                    .commit => |*build| self.discard(build),
                }
                self.* = undefined;
            }

            fn discard(self: *Self, build: *Build) void {
                build.candidate.previous = null;
                self.registry.releaseDomain().retire(build.candidate, &build.candidate.retirement);
                build.directory.deinit();
            }

            fn requestedName(self: *const Self) intern.ModuleName {
                return switch (kind) {
                    .register => self.request.borrow().name,
                    .alias => self.request.target,
                    .define => unreachable,
                };
            }

            pub fn advance(self: *Self) Error!Progress {
                switch (self.state) {
                    .snapshot => return self.beginSnapshot(),
                    .validate => |*state| return self.validate(state),
                    .init_maps => |*state| try self.advanceInit(state),
                    .copy_modules => |*state| {
                        if (state.insertion) |*insertion| switch (insertion.advance()) {
                            .pending => return .pending,
                            .complete => {
                                state.insertion = null;
                                return .pending;
                            },
                        };
                        switch (state.entries.advance()) {
                            .pending => {},
                            .item => |entry| {
                                const replaced = switch (kind) {
                                    .register => entry.key == state.build.target.canonical,
                                    .alias, .define => false,
                                };
                                if (!replaced) {
                                    entry.value.retain();
                                    state.insertion = state.build.candidate.modules.putCursor(entry.key, entry.value);
                                }
                            },
                            .complete => self.enterPutModule(state.build),
                        }
                    },
                    .put_module => |*state| switch (state.cursor.advance()) {
                        .pending => {},
                        .complete => self.enterCopyAliases(state.build),
                    },
                    .copy_aliases => |*state| {
                        if (state.insertion) |*insertion| switch (insertion.advance()) {
                            .pending => return .pending,
                            .complete => {
                                state.insertion = null;
                                return .pending;
                            },
                        };
                        switch (state.entries.advance()) {
                            .pending => {},
                            .item => |entry| {
                                state.insertion = state.build.candidate.aliases.putCursor(entry.key, entry.value);
                            },
                            .complete => self.enterPutAlias(state.build),
                        }
                    },
                    .put_alias => |*state| switch (state.cursor.advance()) {
                        .pending => {},
                        .complete => self.enterCopyNames(state.build),
                    },
                    .copy_names => |*state| {
                        if (state.insertion) |*insertion| switch (insertion.advance()) {
                            .pending => return .pending,
                            .complete => {
                                state.insertion = null;
                                return .pending;
                            },
                        };
                        switch (state.entries.advance()) {
                            .pending => {},
                            .item => |entry| {
                                const replaced = kind == .define and entry.key == self.request.name;
                                if (!replaced) {
                                    entry.value.retain();
                                    state.insertion = state.build.candidate.names.putCursor(entry.key, entry.value);
                                }
                            },
                            .complete => self.enterPutName(state.build),
                        }
                    },
                    .put_name => |*state| switch (state.cursor.advance()) {
                        .pending => {},
                        .complete => self.state = .{ .commit = state.build },
                    },
                    .commit => |*build| {
                        self.registry.lockBlocking();
                        if (!self.registry.privateState().directories.isCurrent(build.directory.directory)) {
                            self.registry.unlock();
                            var stale = build.*;
                            self.state = .snapshot;
                            self.discard(&stale);
                            return .pending;
                        }
                        const outcome = self.apply(build.target);
                        build.candidate.previous = @constCast(build.directory.directory);
                        self.registry.privateState().directories.publish(build.candidate);
                        _ = self.registry.privateState().clock.fetchAdd(1, .acq_rel);
                        self.registry.unlock();
                        var published = build.*;
                        self.state = .complete;
                        published.directory.deinit();
                        return switch (kind) {
                            .register => .{ .complete = outcome },
                            .alias, .define => .complete,
                        };
                    },
                    .complete => unreachable,
                }
                return .pending;
            }

            fn beginSnapshot(self: *Self) Error!Progress {
                switch (kind) {
                    .register => if (intern.isReservedRegistryBytes(intern.get(intern.moduleId(self.request.borrow().name))))
                        return error.ReservedName,
                    .alias => if (intern.isReservedRegistryBytes(intern.get(intern.bindingId(self.request.short))))
                        return error.ReservedName,
                    .define => {},
                }
                var directory = self.registry.acquireDirectory();
                const old = directory.directory orelse {
                    switch (kind) {
                        .register => {
                            self.beginBuild(directory, .{ .canonical = self.requestedName(), .prior = null });
                            return .pending;
                        },
                        .define => {
                            // SAFETY: a top-level definition edits no module
                            // entry, so its target's canonical name is never read.
                            self.beginBuild(directory, .{ .canonical = undefined, .prior = null });
                            return .pending;
                        },
                        .alias => {
                            directory.deinit();
                            return error.MissingModule;
                        },
                    }
                };
                const step: Validation = switch (kind) {
                    .register => if (intern.moduleBindingName(self.requestedName())) |short|
                        .{ .alias_free = old.aliases.rawLookup(short) }
                    else
                        .{ .prior = old.modules.rawLookup(self.requestedName()) },
                    .alias => .{ .short_free = old.modules.rawLookup(intern.moduleNameFromBinding(self.request.short)) },
                    .define => {
                        // SAFETY: as above; a definition edits no module entry.
                        self.beginBuild(directory, .{ .canonical = undefined, .prior = null });
                        return .pending;
                    },
                };
                self.state = .{ .validate = .{ .directory = directory, .step = step } };
                return .pending;
            }

            /// A refusal leaves the lease in place for `deinit`; no caller
            /// advances a cursor past an error.
            fn validate(self: *Self, state: *@FieldType(State, "validate")) Error!Progress {
                const old = state.directory.directory.?;
                switch (kind) {
                    .register => switch (state.step) {
                        .alias_free => |*lookup| switch (lookup.advance()) {
                            .pending => {},
                            .complete => |existing| {
                                if (existing != null) return error.NameConflict;
                                state.step = .{ .prior = old.modules.rawLookup(self.requestedName()) };
                            },
                        },
                        .prior => |*lookup| switch (lookup.advance()) {
                            .pending => {},
                            .complete => |prior| self.beginBuild(
                                state.directory,
                                .{ .canonical = self.requestedName(), .prior = prior },
                            ),
                        },
                    },
                    .alias => switch (state.step) {
                        .short_free => |*lookup| switch (lookup.advance()) {
                            .pending => {},
                            .complete => |found| {
                                if (found != null) return error.NameConflict;
                                state.step = .{ .target_module = old.modules.rawLookup(self.request.target) };
                            },
                        },
                        .target_module => |*lookup| switch (lookup.advance()) {
                            .pending => {},
                            .complete => |found| {
                                if (found != null) {
                                    state.step = .{ .same_alias = .{
                                        .canonical = self.request.target,
                                        .lookup = old.aliases.rawLookup(self.request.short),
                                    } };
                                } else if (intern.moduleBindingName(self.request.target)) |short| {
                                    state.step = .{ .target_alias = old.aliases.rawLookup(short) };
                                } else return error.MissingModule;
                            },
                        },
                        .target_alias => |*lookup| switch (lookup.advance()) {
                            .pending => {},
                            .complete => |canonical| {
                                const target = canonical orelse return error.MissingModule;
                                state.step = .{ .same_alias = .{
                                    .canonical = target,
                                    .lookup = old.aliases.rawLookup(self.request.short),
                                } };
                            },
                        },
                        .same_alias => |*same| switch (same.lookup.advance()) {
                            .pending => {},
                            .complete => |existing| {
                                if (existing != null and existing.? == same.canonical) {
                                    var directory = state.directory;
                                    self.state = .complete;
                                    directory.deinit();
                                    return .complete;
                                }
                                self.beginBuild(state.directory, .{ .canonical = same.canonical, .prior = null });
                            },
                        },
                    },
                    .define => unreachable,
                }
                return .pending;
            }

            fn beginBuild(self: *Self, directory: DirectoryLease, target: Target) void {
                self.state = .{ .init_maps = .{
                    .directory = directory,
                    .target = target,
                    .maps = .{},
                    .phase = .modules,
                } };
            }

            fn advanceInit(self: *Self, state: *@FieldType(State, "init_maps")) error{OutOfMemory}!void {
                const old = state.directory.directory;
                const map_allocator = self.registry.allocator();
                if (state.cursor == null) state.cursor = switch (state.phase) {
                    .modules => .{ .modules = Directory.ModuleMap.initCursor(
                        map_allocator,
                        (if (old) |current| current.modules.count() else 0) + @intFromBool(kind == .register),
                    ) },
                    .aliases => .{ .aliases = Directory.AliasMap.initCursor(
                        map_allocator,
                        (if (old) |current| current.aliases.count() else 0) + @intFromBool(kind == .alias),
                    ) },
                    .names => .{ .names = env.NameMap.initCursor(
                        map_allocator,
                        (if (old) |current| current.names.count() else 0) + @intFromBool(kind == .define),
                    ) },
                };
                switch (state.cursor.?) {
                    .modules => |*cursor| switch (try cursor.advance()) {
                        .pending => return,
                        .complete => |map| {
                            state.maps.modules = map;
                            state.phase = .aliases;
                        },
                    },
                    .aliases => |*cursor| switch (try cursor.advance()) {
                        .pending => return,
                        .complete => |map| {
                            state.maps.aliases = map;
                            state.phase = .names;
                        },
                    },
                    .names => |*cursor| switch (try cursor.advance()) {
                        .pending => return,
                        .complete => |map| {
                            state.maps.names = map;
                            state.cursor = null;
                            return self.finishInit(state);
                        },
                    },
                }
                state.cursor = null;
            }

            fn finishInit(self: *Self, state: *@FieldType(State, "init_maps")) error{OutOfMemory}!void {
                const candidate = try self.registry.allocator().create(Directory);
                candidate.* = .{
                    .modules = state.maps.modules.?,
                    .aliases = state.maps.aliases.?,
                    .names = state.maps.names.?,
                    .previous = null,
                };
                state.maps = .{};
                const build = Build{
                    .directory = state.directory,
                    .target = state.target,
                    .candidate = candidate,
                };
                if (build.directory.directory) |old| {
                    self.state = .{ .copy_modules = .{
                        .build = build,
                        .entries = old.modules.rawEntries(),
                    } };
                } else self.enterPutModule(build);
            }

            fn enterPutModule(self: *Self, build: Build) void {
                if (kind == .register) {
                    const image = self.request.borrow();
                    image.retain();
                    self.state = .{ .put_module = .{
                        .build = build,
                        .cursor = build.candidate.modules.putCursor(build.target.canonical, image),
                    } };
                } else self.enterCopyAliases(build);
            }

            fn enterCopyAliases(self: *Self, build: Build) void {
                if (build.directory.directory) |old| {
                    self.state = .{ .copy_aliases = .{
                        .build = build,
                        .entries = old.aliases.rawEntries(),
                    } };
                } else self.enterPutAlias(build);
            }

            fn enterPutAlias(self: *Self, build: Build) void {
                if (kind == .alias) {
                    self.state = .{ .put_alias = .{
                        .build = build,
                        .cursor = build.candidate.aliases.putCursor(self.request.short, build.target.canonical),
                    } };
                } else self.enterCopyNames(build);
            }

            fn enterCopyNames(self: *Self, build: Build) void {
                if (build.directory.directory) |old| {
                    self.state = .{ .copy_names = .{
                        .build = build,
                        .entries = old.names.rawEntries(),
                    } };
                } else self.enterPutName(build);
            }

            fn enterPutName(self: *Self, build: Build) void {
                if (kind == .define) {
                    self.request.entry.retain();
                    self.state = .{ .put_name = .{
                        .build = build,
                        .cursor = build.candidate.names.putCursor(self.request.name, self.request.entry),
                    } };
                } else self.state = .{ .commit = build };
            }

            /// The edit's effect on the images themselves, applied under the
            /// writer lock just before the candidate becomes current: a
            /// published image learns its generation number and joins the
            /// registry's history, which keeps it until teardown.
            fn apply(self: *Self, target: Target) switch (kind) {
                .register => u64,
                .alias, .define => void,
            } {
                switch (kind) {
                    .register => {
                        const image = self.request.borrow();
                        image.generation = if (target.prior) |prior| prior.generation + 1 else 1;
                        image.retain();
                        const state = self.registry.privateState();
                        image.history_next = state.history;
                        state.history = image;
                        image.published.store(true, .release);
                        return image.generation;
                    },
                    .alias, .define => {},
                }
            }
        };
    }

    pub const RegistrationCursor = EditCursor(.register);
    pub const AliasCursor = EditCursor(.alias);
    pub const DefineCursor = EditCursor(.define);

    pub fn registrationCursor(self: *Registry, image: SealedImage) RegistrationCursor {
        return .{ .registry = self, .request = image };
    }
    pub fn aliasCursor(self: *Registry, short: intern.BindingName, target: intern.ModuleName) AliasCursor {
        return .{ .registry = self, .request = .{ .short = short, .target = target } };
    }
    /// Publishes one top-level name. The cursor takes the caller's reference
    /// to a counted entry.
    pub fn defineCursor(self: *Registry, name: intern.BindingName, entry: env.Entry) DefineCursor {
        return .{ .registry = self, .request = .{ .name = name, .entry = entry } };
    }

    pub const AcquireProgress = poll.Progress(?GenerationLease);
    /// Resolution of a canonical name or an alias to an observation lease on
    /// its current generation. The directory lease held across the lookup is
    /// what makes the retain safe: the directory owns the entry until the
    /// lease is released.
    pub const AcquireCursor = struct {
        directory: DirectoryLease,
        name: intern.ModuleName,
        state: State,

        const State = union(enum) {
            absent,
            module: Directory.ModuleMap.RawLookupCursor,
            alias: Directory.AliasMap.RawLookupCursor,
            canonical_module: Directory.ModuleMap.RawLookupCursor,
            complete,
        };

        fn initIn(directory: DirectoryLease, name: intern.ModuleName) AcquireCursor {
            return .{
                .directory = directory,
                .name = name,
                .state = if (directory.directory) |current|
                    .{ .module = current.modules.rawLookup(name) }
                else
                    .absent,
            };
        }

        pub fn deinit(self: *AcquireCursor) void {
            self.directory.deinit();
            self.* = undefined;
        }
        fn found(self: *AcquireCursor, image: *ModuleImage) AcquireProgress {
            image.retain();
            self.state = .complete;
            return .{ .complete = GenerationLease.initRetained(image) };
        }
        pub fn advance(self: *AcquireCursor) AcquireProgress {
            while (true) switch (self.state) {
                .absent => {
                    self.state = .complete;
                    return .{ .complete = null };
                },
                .module => |*lookup| switch (lookup.advance()) {
                    .pending => return .pending,
                    .complete => |image| if (image) |present| {
                        return self.found(present);
                    } else if (intern.moduleBindingName(self.name)) |alias_name| {
                        self.state = .{ .alias = self.directory.directory.?.aliases.rawLookup(alias_name) };
                    } else {
                        self.state = .complete;
                        return .{ .complete = null };
                    },
                },
                .alias => |*lookup| switch (lookup.advance()) {
                    .pending => return .pending,
                    .complete => |canonical_name| if (canonical_name) |canonical| {
                        self.state = .{ .canonical_module = self.directory.directory.?.modules.rawLookup(canonical) };
                    } else {
                        self.state = .complete;
                        return .{ .complete = null };
                    },
                },
                .canonical_module => |*lookup| switch (lookup.advance()) {
                    .pending => return .pending,
                    .complete => |image| return self.found(image orelse unreachable),
                },
                .complete => unreachable,
            };
        }
    };
    pub fn acquireCursor(self: *const Registry, name: intern.ModuleName) AcquireCursor {
        return .initIn(self.acquireDirectory(), name);
    }

    /// Captures the current snapshot as one coherent view.
    pub fn view(self: *const Registry) View {
        const publication = self.currentPublication();
        return .{ .directory = self.acquireDirectory(), .publication = publication };
    }

    pub const BeginLoadingProgress = poll.Progress(LoadingOutcome);
    pub const BeginLoadingCursor = struct {
        registry: *Registry,
        key: LoadingKey,
        owner: LoadingOwner,
        state: State,

        const Scan = struct {
            observed_head: ?*LoadingNode,
            cursor: ?*LoadingNode,
        };
        const State = union(enum) {
            scan: Scan,
            reserve: ?*LoadingNode,
            scan_reserved: struct {
                scan: Scan,
                reservation: *LoadingNode,
            },
            commit: struct {
                observed_head: ?*LoadingNode,
                reservation: *LoadingNode,
            },
            complete,
        };

        pub fn deinit(self: *BeginLoadingCursor) void {
            switch (self.state) {
                .scan_reserved => |reserved| self.registry.allocator().destroy(reserved.reservation),
                .commit => |commit| self.registry.allocator().destroy(commit.reservation),
                .scan, .reserve, .complete => {},
            }
            self.* = undefined;
        }

        fn completeExisting(
            self: *BeginLoadingCursor,
            reservation: ?*LoadingNode,
            result: LoadingOutcome,
        ) BeginLoadingProgress {
            if (reservation) |node| self.registry.allocator().destroy(node);
            self.state = .complete;
            return .{ .complete = result };
        }

        fn inspectNode(
            self: *BeginLoadingCursor,
            node: *LoadingNode,
            reservation: ?*LoadingNode,
        ) ?BeginLoadingProgress {
            if (!node.key.eql(self.key)) return null;
            const held = node.owner.cmpxchgStrong(
                free_loading_owner,
                self.owner.token(),
                .acq_rel,
                .acquire,
            ) orelse return self.completeExisting(reservation, .{ .granted = .init(node) });
            if (held == self.owner.token())
                return self.completeExisting(reservation, .cycle);
            return self.completeExisting(reservation, .contended);
        }

        pub fn advance(self: *BeginLoadingCursor) error{OutOfMemory}!BeginLoadingProgress {
            return switch (self.state) {
                .scan => |*scan| result: {
                    const node = scan.cursor orelse {
                        const observed_head = scan.observed_head;
                        self.state = .{ .reserve = observed_head };
                        break :result .pending;
                    };
                    scan.cursor = node.next;
                    if (self.inspectNode(node, null)) |complete| break :result complete;
                    break :result .pending;
                },
                .reserve => |observed_head| result: {
                    const reservation = try self.registry.allocator().create(LoadingNode);
                    self.state = .{ .commit = .{
                        .observed_head = observed_head,
                        .reservation = reservation,
                    } };
                    break :result .pending;
                },
                .scan_reserved => |*reserved| result: {
                    const node = reserved.scan.cursor orelse {
                        const observed_head = reserved.scan.observed_head;
                        const reservation = reserved.reservation;
                        self.state = .{ .commit = .{
                            .observed_head = observed_head,
                            .reservation = reservation,
                        } };
                        break :result .pending;
                    };
                    reserved.scan.cursor = node.next;
                    if (self.inspectNode(node, reserved.reservation)) |complete|
                        break :result complete;
                    break :result .pending;
                },
                .commit => |commit| result: {
                    self.registry.lockBlocking();
                    defer self.registry.unlock();
                    const current = self.registry.privateState().loading.load(.acquire);
                    if (current != commit.observed_head) {
                        self.state = .{ .scan_reserved = .{
                            .scan = .{ .observed_head = current, .cursor = current },
                            .reservation = commit.reservation,
                        } };
                        break :result .pending;
                    }
                    const node = commit.reservation;
                    node.* = .{
                        .registry = self.registry,
                        .key = self.key,
                        .owner = .init(self.owner.token()),
                        .next = current,
                    };
                    self.registry.privateState().loading.store(node, .release);
                    self.state = .complete;
                    break :result .{ .complete = .{ .granted = .init(node) } };
                },
                .complete => unreachable,
            };
        }
    };
    pub fn beginLoadingCursor(
        self: *Registry,
        name: intern.ModuleName,
        owner: LoadingOwner,
    ) BeginLoadingCursor {
        const head = self.privateState().loading.load(.acquire);
        return .{
            .registry = self,
            .key = .{ .module = name },
            .owner = owner,
            .state = .{ .scan = .{ .observed_head = head, .cursor = head } },
        };
    }

    pub fn beginArtifactLoadingCursor(
        self: *Registry,
        artifact: map_state.ArtifactId,
        owner: LoadingOwner,
    ) BeginLoadingCursor {
        const head = self.privateState().loading.load(.acquire);
        return .{
            .registry = self,
            .key = .{ .artifact = artifact },
            .owner = owner,
            .state = .{ .scan = .{ .observed_head = head, .cursor = head } },
        };
    }
};
comptime {
    heap.requireOpaqueHostRoot(Registry, RegistryState);
}

/// Blocking drives for tests. Production acquires a generation through the
/// resumable cursor, so a blocking wrapper in the production surface would be
/// an operation nothing calls — and one that lets a test skip the very
/// resumability it should be exercising.
pub const testing = if (builtin.is_test) struct {
    pub fn acquire(registry: *const Registry, name: intern.ModuleName) ?GenerationLease {
        var cursor = registry.acquireCursor(name);
        defer cursor.deinit();
        return poll.drive(?GenerationLease, &cursor, .{});
    }

    pub fn register(registry: *Registry, image: *SealedImage) CommitError!u64 {
        var cursor = registry.registrationCursor(image.move());
        defer cursor.deinit();
        while (true) switch (try cursor.advance()) {
            .pending => {},
            .complete => |generation| return generation,
        };
    }

    pub fn alias(
        registry: *Registry,
        short: intern.BindingName,
        target: intern.ModuleName,
    ) AliasError!void {
        var cursor = registry.aliasCursor(short, target);
        defer cursor.deinit();
        return poll.driveVoidFallible(&cursor, .{});
    }
} else struct {};
