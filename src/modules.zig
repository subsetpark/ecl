//! Per-session module registry with typed names and atomic generation publication.
const std = @import("std");
const module_search = @import("module_search.zig");
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

    fn init(allocator: std.mem.Allocator) TestCatalog {
        return .{ .allocator = allocator };
    }

    const DeclareError = error{ OutOfMemory, DuplicateTest };
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

/// One module: the directory its definitions live in, and the scope of the
/// name it was built for with the provenance it registers under. The name is
/// fixed before the body runs. While the constructing body runs, definitions
/// and imports are staged; sealing turns the staged names into an immutable
/// directory. An image owns one reference to each of its definitions. The
/// directories that map it and its construction own the image; a replaced
/// image retires with the last directory that maps it.
const ModuleImage = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    /// Names introduced by the construction body, not yet visible to anyone.
    staging: poll.ChunkStack(StagedName),
    staged_count: usize = 0,
    /// The directory, built from the staged names as the image is sealed;
    /// null until then.
    names: ?env.NameMap = null,
    /// What code of this generation runs as. The scope is the one of the
    /// module's name, which the `Env` owns and every generation shares.
    home: ModuleRoot,
    tests: TestCatalog,
    /// The module's documentation as written, one reference owned by the
    /// image. A generation carries its own: reload replaces the text with the
    /// code, and nothing carries it from one generation to the next.
    doc: ?*env.DocumentationString = null,
    refs: std.atomic.Value(u32) = .init(1),
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: union(enum) {
        live,
        tests: TestCatalog.TeardownCursor,
        staging,
        names: env.NameMap.RawEntryCursor,
    } = .live,

    fn create(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        module: env.ModuleIdentity,
        provenance: RegistrationProvenance,
    ) error{OutOfMemory}!*ModuleImage {
        const result = try allocator.create(ModuleImage);
        result.* = .{
            .allocator = allocator,
            .releases = releases,
            .staging = .init(allocator),
            .home = .{ .scope = module.id, .module = module.name, .provenance = provenance },
            .tests = .init(allocator),
        };
        return result;
    }

    fn retain(self: *ModuleImage) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    fn release(self: *ModuleImage) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
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

    fn moduleName(self: *const ModuleImage) intern.ModuleName {
        return self.home.name();
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
                self.retirement_state = .staging;
                return false;
            },
            .staging => {
                if (self.staging.pop()) |staged| {
                    // Constant work: a definition nothing else holds
                    // retires as its own owner.
                    staged.entry.release(releases);
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
                    entry.value.release(releases);
                    return false;
                },
                .complete => self.names.?.deinit(),
            },
        }
        if (self.doc) |doc| releases.releaseHeader(env.documentationHeader(doc));
        allocator.destroy(self);
        return true;
    }
};

/// One name a construction body introduced, owned by its image until sealing.
const StagedName = struct {
    name: intern.BindingName,
    entry: env.Entry,
};

/// What a unit may register, one word: anything, for an embedded library
/// load; only its declarations, for a found file's load; and any name not
/// reserved for the standard library, for other code. A fiber holds the
/// value of the unit it is running, and an image records the one it was
/// registered under.
///
/// A found file is its address, which is never zero or one.
pub const RegistrationProvenance = enum(u64) {
    ordinary = 0,
    standard_library = 1,
    _,

    pub const Kind = union(enum) {
        ordinary,
        standard_library,
        source: *const module_search.Source,
    };

    pub fn source(found: *const module_search.Source) RegistrationProvenance {
        return @fromBackingInt(@intFromPtr(found));
    }

    pub fn kind(self: RegistrationProvenance) Kind {
        return switch (self) {
            .ordinary => .ordinary,
            .standard_library => .standard_library,
            _ => .{ .source = @ptrFromInt(@as(usize, @intCast(@backingInt(self)))) },
        };
    }

    /// The found file this provenance is, if it is one.
    pub fn foundSource(self: RegistrationProvenance) ?*const module_search.Source {
        return switch (self.kind()) {
            .source => |found| found,
            .ordinary, .standard_library => null,
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
    entries: env.NameMap.RawEntryCursor,
    pub fn advance(self: *ModulePublicNameCursor) ModulePublicNameProgress {
        return switch (self.entries.advance()) {
            .pending => .pending,
            .complete => .complete,
            .item => |entry| if (entryIsPublic(entry.value))
                .{ .item = intern.bindingId(entry.key) }
            else
                .pending,
        };
    }
};

/// One immutable snapshot of the registry: its module names and
/// for the Session's public registry the top-level name directory. A binding
/// captures one snapshot and resolves every name against it across scheduler
/// turns, so it never mixes publication states. A directory owns one
/// reference to every image and counted definition it maps; a retired
/// directory releases them as bounded work before it frees itself.
/// One registry snapshot. Each map is persistent: an edit shares every node
/// it does not change with the snapshot it was made from, so a successor
/// costs the depth of the edited map, not its size.
const Directory = struct {
    const ModuleMap = poll.PersistentMap(intern.ModuleName, *ModuleImage, struct {
        pub fn retain(image: *ModuleImage) void {
            image.retain();
        }
        pub fn release(image: *ModuleImage, releases: *heap.ReleaseDomain) void {
            _ = releases;
            image.release();
        }
    });
    const NameMap = poll.PersistentMap(intern.BindingName, env.Entry, struct {
        pub fn retain(entry: env.Entry) void {
            entry.retain();
        }
        pub fn release(entry: env.Entry, releases: *heap.ReleaseDomain) void {
            entry.release(releases);
        }
    });

    modules: ModuleMap = .{},
    names: NameMap = .{},
    previous: ?*Directory = null,
    retirement: heap.ReleaseDomain.Retirement = .{},

    /// Releases one reference to each map's root, whose nodes retire as
    /// their own owners once no snapshot shares them, then hands the next
    /// older directory to the release domain. Constant work.
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Directory,
    ) bool {
        const previous = self.previous;
        self.modules.release(releases);
        self.names.release(releases);
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
            directory.modules.release(releases);
            directory.names.release(releases);
            allocator.destroy(directory);
        }
    }
};
const DirectoryPublisher = snapshot_api.Publisher(Directory);

/// One running turn as a reader of the registry's directories. It holds no
/// snapshot: while it lives, no directory superseded since it began, and so
/// no image or definition one owns, is reclaimed.
pub const TurnLease = struct {
    registry: *Registry,
    reader: DirectoryPublisher.Reader,

    pub fn deinit(self: TurnLease) void {
        if (self.registry.privateState().directories.leave(self.reader)) self.registry.retireSuperseded();
    }
};

/// The session's top-level names in one snapshot, one per step.
pub const SessionNameCursor = Directory.NameMap.RawEntryCursor;

/// One captured registry snapshot: what a resolution reads session names and
/// module names from, and what a registry cursor holds while it reads a
/// directory. Holding it keeps the snapshot, and so every image and
/// definition the snapshot maps, from being reclaimed.
pub const View = struct {
    registry: *const Registry,
    lease: DirectoryPublisher.Lease,

    pub fn deinit(self: *View) void {
        const registry = @constCast(self.registry);
        if (self.lease.deinit()) registry.retireSuperseded();
        self.* = undefined;
    }

    /// The snapshot held: null before the registry's first publication.
    fn directory(self: *const View) ?*const Directory {
        return self.lease.snapshot;
    }

    /// One session top-level name in this snapshot, borrowed while the view
    /// is held. Constant work.
    pub fn sessionFind(self: *const View, name: intern.BindingName) ?env.Entry {
        const current = self.directory() orelse return null;
        return current.names.find(name);
    }

    /// The registration a module name selects in this snapshot, read in
    /// bounded steps while the view is held.
    pub fn moduleCursor(self: *const View, name: intern.ModuleName) ModuleCursor {
        return .{ .state = if (self.directory()) |current|
            .{ .module = current.modules.rawLookup(name) }
        else
            .absent };
    }

    /// The registration a module name selects in this snapshot. Constant
    /// work.
    pub fn moduleFind(self: *const View, name: intern.ModuleName) ?Generation {
        const current = self.directory() orelse return null;
        return .of(current.modules.find(name) orelse return null);
    }

    /// The session's top-level names in this snapshot.
    pub fn sessionEntries(self: *const View) ?SessionNameCursor {
        const current = self.directory() orelse return null;
        return current.names.rawEntries();
    }
};

const TestAuthorityState = struct {
    // Keep the opaque registry value itself. The caller's movable enum wrapper
    // has no stable address.
    // Session construction moves that wrapper into its core after minting this
    // seal; the backing identity remains stable.
    registry: Registry,
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
    pub fn discoveryCursor(self: *const TestObservationAccess) Registry.TestDiscoveryCursor {
        return .init(&self.state().registry);
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
    ) Registry.TestLookupCursor {
        return .init(&self.state().registry, module_name, test_name);
    }
};

pub const ModuleRoot = env.ModuleRoot;

/// The module a definition belongs to, or null for a core or session
/// definition.
pub inline fn definitionModule(definition: *const env.Definition) ?ModuleRoot {
    return switch (definition.root) {
        .core, .session => null,
        .module => |module| module.home,
    };
}

/// One published registration of a module, borrowed: valid while the view
/// it was found in is held, and within the turn that found it. The raw image
/// is never exposed.
pub const Generation = enum(usize) {
    _,

    fn of(published: *ModuleImage) Generation {
        return @fromBackingInt(@intCast(@intFromPtr(published)));
    }
    fn image(self: Generation) *ModuleImage {
        return @ptrFromInt(@backingInt(self));
    }
    pub fn name(self: Generation) intern.ModuleName {
        return self.image().moduleName();
    }
    pub fn provenance(self: Generation) RegistrationProvenance {
        return self.image().home.provenance;
    }
    /// The generation's documentation as written.
    pub fn documentation(self: Generation) ?*env.DocumentationString {
        return self.image().doc;
    }
    /// One name in this generation's directory, private ones included.
    /// Visibility is the caller's to check: an export lookup refuses private
    /// entries, and a word written in the module may use them.
    pub fn lookupCursor(self: Generation, binding: intern.BindingName) env.NameMap.RawLookupCursor {
        return self.image().names.?.rawLookup(binding);
    }
    pub fn publicNameCursor(self: Generation) ModulePublicNameCursor {
        return .{ .entries = self.entries() };
    }
    /// Every name of the generation's directory, private ones included.
    pub fn entries(self: Generation) env.NameMap.RawEntryCursor {
        return self.image().names.?.rawEntries();
    }
    fn testNameCursor(self: Generation) TestCatalog.NameCursor {
        return .{ .next = self.image().tests.entries_head };
    }
    fn testLookupCursor(
        self: Generation,
        test_name: intern.BindingName,
    ) TestCatalog.LookupCursor {
        return .{
            .current = self.image().tests.root,
            .name = test_name,
        };
    }
};

/// The registration a module name selects in one view, read in bounded steps.
/// It borrows the view it was made from, which its holder keeps.
pub const ModuleCursor = struct {
    state: union(enum) {
        absent,
        module: Directory.ModuleMap.RawLookupCursor,
        complete,
    },

    pub const Progress = poll.Progress(?Generation);

    pub fn advance(self: *ModuleCursor) Progress {
        switch (self.state) {
            .absent => {
                self.state = .complete;
                return .{ .complete = null };
            },
            .module => |*lookup| switch (lookup.advance()) {
                .pending => return .pending,
                .complete => |found| {
                    self.state = .complete;
                    return .{ .complete = if (found) |image| .of(image) else null };
                },
            },
            .complete => unreachable,
        }
    }
};

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
    /// What the construction body, and code of the module once registered,
    /// runs as.
    pub fn root(self: *const OwnedImage) ModuleRoot {
        return self.borrow().home;
    }
    pub fn moduleName(self: *const OwnedImage) intern.ModuleName {
        return self.borrow().moduleName();
    }
    pub fn provenance(self: *const OwnedImage) RegistrationProvenance {
        return self.borrow().home.provenance;
    }
    /// Records the module's documentation, retaining it; the caller keeps its
    /// own reference. Each construction documents its image at most once,
    /// before publication.
    pub fn document(self: *const OwnedImage, doc: *env.DocumentationString) void {
        const image = self.borrow();
        std.debug.assert(image.doc == null);
        heap.incRef(env.documentationHeader(doc));
        image.doc = doc;
    }
    /// Stages one definition. The publication's values are retained by the
    /// staged definition; the caller keeps its own.
    pub fn stageDefinition(
        self: *const OwnedImage,
        name: intern.BindingName,
        publication: env.ModulePublication,
    ) error{OutOfMemory}!void {
        const image = self.borrow();
        const home: env.DefinitionRoot = .{ .module = .{ .home = image.home, .name = name } };
        const created: env.Entry = .{ .definition = switch (publication) {
            .word => |word| try env.Definition.createSource(image.allocator, env.quotationHeader(word.body), .{
                .visibility = word.visibility,
                .effect = word.effect,
                .doc = word.doc,
                .source = word.source,
                .root = home,
                .attribution = word.attribution,
            }),
            .native => |native| try env.Definition.create(image.allocator, .{ .native = native.callable }, .{
                .effect = native.effect,
                .doc = native.doc,
                .root = home,
            }),
            .builtin => |primitive| try env.Definition.create(image.allocator, .{ .builtin = primitive.primitive }, .{
                .effect = primitive.effect,
                .doc = primitive.doc,
                .root = home,
            }),
        } };
        image.stage(name, created) catch |err| {
            created.release(image.releases);
            return err;
        };
    }
    /// Stages one name alias.
    pub fn stageAlias(self: *const OwnedImage, name: intern.BindingName, alias: env.Alias) error{OutOfMemory}!void {
        return self.borrow().stage(name, .{ .alias = alias });
    }
    /// Turns the staged names into the image's directory. Each name may be
    /// introduced once: a duplicate fails construction.
    pub fn groupCursor(self: *const OwnedImage) GroupCursor {
        return .{ .image = self.borrow() };
    }
    /// The directory's entries, for advisory checks before sealing. Valid
    /// once the group cursor has completed.
    pub fn entries(self: *const OwnedImage) env.NameMap.RawEntryCursor {
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
    /// Seals a host-built module in one call: a builtin- or native-backed
    /// module, whose size is fixed by a compiled-in or validated descriptor.
    pub fn sealLiteralGroup(self: *OwnedImage) GroupCursor.Error!SealedImage {
        var group = self.groupCursor();
        defer group.deinit();
        while (true) switch (try group.advance()) {
            .pending => {},
            .complete => break,
        };
        return self.seal();
    }
    /// Ends construction once the staged names are the directory. Consuming
    /// this capability is the one transition after which nothing can mutate
    /// the image, so it can be registered or handed to a program.
    pub fn seal(self: *OwnedImage) SealedImage {
        const image = self.borrow();
        std.debug.assert(image.names != null and image.staging.isEmpty());
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
        // Rollback drops the construction owner's reference.
        self.borrow().release();
        self.* = .consumed;
    }
};

/// Builds an image's directory from its staged names in bounded steps, one
/// name per step, refusing a name staged twice. The partial directory belongs
/// to the image from the first step, so abandoning the cursor leaves nothing
/// for it to release but the entry it holds.
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
        // A pending insertion holds its entry until it lands in the directory.
        if (self.put) |pending| pending.value.release(self.image.releases);
        if (self.lookup) |pending| pending.staged.entry.release(self.image.releases);
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
                        staged.entry.release(image.releases);
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
    /// The sealed directory's entries, for advisory checks before registration.
    pub fn entries(self: *const SealedImage) env.NameMap.RawEntryCursor {
        return self.borrow().names.?.rawEntries();
    }
    pub fn moduleName(self: *const SealedImage) intern.ModuleName {
        return self.borrow().moduleName();
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
    /// The exact name `core` is the core qualifier, never a registration.
    ReservedName,
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
    artifact: module_search.FileId,

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
    key: LoadingKey,
    owner: std.atomic.Value(usize),
    next: ?*LoadingNode,
};

/// The authority to record a found file as loaded. Only
/// `LoadingLease.artifactCommit` mints one, and only from a live lease keyed
/// to that file, so no file is recorded loaded whose declarations nobody
/// verified.
pub const ArtifactCommit = enum(u32) {
    _,

    fn init(published: module_search.FileId) ArtifactCommit {
        return @fromBackingInt(@intCast(@backingInt(published)));
    }
    pub fn artifact(self: ArtifactCommit) module_search.FileId {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }
};

pub const LoadingLease = enum(usize) {
    finished = 0,
    _,

    fn init(loading: *LoadingNode) LoadingLease {
        return @fromBackingInt(@intCast(@intFromPtr(loading)));
    }
    /// Trade a live file lease for the authority to record the file loaded.
    /// The lease is not released here: the record must be visible before the
    /// lease frees, or a contender would find the file unloaded and load it
    /// again. `deinit` follows on the same step.
    pub fn artifactCommit(self: *LoadingLease) ArtifactCommit {
        return switch (self.node().key) {
            .artifact => |artifact| .init(artifact),
            .module => @panic("a module loading lease cannot record a file loaded"),
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
    /// Frees the name for the next loader. Nothing for a lease already
    /// finished or moved from.
    pub fn deinit(self: *LoadingLease) void {
        if (self.* == .finished) return;
        self.node().owner.store(free_loading_owner, .release);
        self.* = .finished;
    }
};
const RegistryState = struct {
    host: *const heap.HostCleanup,
    writer: std.Io.Mutex = .init,
    directories: DirectoryPublisher,
    /// The word cells that answer from this registry's directories. Every
    /// store into one is made with `writer` held.
    cells: env.CellPublisher,
    /// How many registrations are between emptying the cells a registration
    /// can change and committing. While any is, no resolution fills a cell.
    /// Read and written with `writer` held.
    fills_closed: u32 = 0,
    loading: std.atomic.Value(?*LoadingNode) = .init(null),
    /// The Session's publication counter. Every edit to the registry
    /// advances it; it holds no snapshot and only keys reuse.
    publications: std.atomic.Value(u64) = .init(1),
};

pub const Registry = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Registry) *RegistryState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@backingInt(self.*));
    }

    /// A Session's registry, which owns the Session's publication counter
    /// and is the one writer of its `Env`'s word cells.
    pub fn init(host: *const heap.HostCleanup, cells: env.CellPublisher) error{OutOfMemory}!Registry {
        const backing = try host.allocator().create(RegistryState);
        backing.* = .{ .host = host, .directories = .init(null), .cells = cells };
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }

    /// The Session's publication identity now, for keying what fibers
    /// remember. It advances before a publication's first store a reader can
    /// see and again after its last, both under the writer lock. So what a
    /// reader records under a value read while no publication was in
    /// progress is outdated before the next one shows, and a reader that
    /// sees a definition a publication made readable reads a later value
    /// than any read before that definition existed.
    pub fn currentPublication(self: *const Registry) u64 {
        return self.privateState().publications.load(.acquire);
    }

    /// Whether a publication has made some of its stores and not yet all of
    /// them. The counter is odd between publications and even inside one.
    /// What a reader takes from a cell while this holds may sit beside a
    /// cell the same publication has yet to store, so the two say nothing
    /// together, and nothing read then may be remembered under the
    /// counter's value: that value does not change again until the
    /// publication's last store.
    pub fn publishing(self: *const Registry) bool {
        return self.privateState().publications.load(.acquire) & 1 == 0;
    }

    /// Mint the capability seal owned by a test-mode Session. Its backing
    /// carries the registry rather than accepting one alongside the access
    /// token, so cross-Session authority substitution is unrepresentable.
    pub fn createTestAuthority(self: *Registry) error{OutOfMemory}!TestAuthority {
        const state = try self.allocator().create(TestAuthorityState);
        state.* = .{ .registry = self.* };
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
        Directory.destroyChain(backing.directories.takeDraining(), self.allocator(), self.releaseDomain());
        Directory.destroyChain(backing.directories.currentOwned(), self.allocator(), self.releaseDomain());
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

    pub const NamespaceProgress = poll.StreamProgress(u32);
    /// Snapshot-owning enumeration of module names. The directory
    /// representation remains private and the lease survives until the cursor
    /// is explicitly released, including when iteration is abandoned early.
    pub const NamespaceCursor = struct {
        view: View,
        modules: ?Directory.ModuleMap.RawEntryCursor = null,

        pub fn deinit(self: *NamespaceCursor) void {
            self.view.deinit();
            self.* = undefined;
        }

        pub fn advance(self: *NamespaceCursor) NamespaceProgress {
            const entries = &(self.modules orelse return .complete);
            return switch (entries.advance()) {
                .pending => .pending,
                .item => |entry| .{ .item = intern.moduleId(entry.key) },
                .complete => complete: {
                    self.modules = null;
                    break :complete .complete;
                },
            };
        }
    };

    pub fn namespaceCursor(self: *const Registry) NamespaceCursor {
        const captured = self.view();
        return .{
            .view = captured,
            .modules = if (captured.directory()) |current| current.modules.rawEntries() else null,
        };
    }

    pub const DiscoveredTest = struct {
        module: intern.ModuleName,
        metadata: ModuleTestMetadata,
    };
    pub const TestDiscoveryProgress = poll.StreamProgress(DiscoveredTest);

    /// Discovery over one directory snapshot, visiting each module once. The
    /// view the cursor owns keeps every generation whose catalog it reads.
    pub const TestDiscoveryCursor = struct {
        view: View,
        modules: ?Directory.ModuleMap.RawEntryCursor,
        current_module: ?intern.ModuleName = null,
        names: ?TestCatalog.NameCursor = null,
        complete: bool = false,

        fn init(registry: *Registry) TestDiscoveryCursor {
            const captured = registry.view();
            return .{
                .view = captured,
                .modules = if (captured.directory()) |current| current.modules.rawEntries() else null,
            };
        }

        pub fn deinit(self: *TestDiscoveryCursor) void {
            self.view.deinit();
            self.* = undefined;
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
                    self.current_module = entry.key;
                    self.names = Generation.of(entry.value).testNameCursor();
                    break :result .pending;
                },
            };
        }
    };

    /// A test found in the current registration: the module it runs as
    /// and its body, borrowed from the lookup's view.
    pub const TestInvocation = struct {
        root: ModuleRoot,
        body: *env.Quotation,

        pub fn quotation(self: TestInvocation) *value.ListHandle {
            return env.quotationHeader(self.body);
        }
    };

    pub const TestLookupProgress = poll.Progress(?TestInvocation);
    pub const TestLookupCursor = struct {
        view: View,
        module_name: intern.ModuleName,
        test_name: intern.BindingName,
        state: State,

        const State = union(enum) {
            absent,
            module: Directory.ModuleMap.RawLookupCursor,
            catalog: struct {
                generation: Generation,
                cursor: TestCatalog.LookupCursor,
            },
            complete,
        };

        fn init(
            registry: *Registry,
            module_name: intern.ModuleName,
            test_name: intern.BindingName,
        ) TestLookupCursor {
            const captured = registry.view();
            return .{
                .view = captured,
                .module_name = module_name,
                .test_name = test_name,
                .state = if (captured.directory()) |current|
                    .{ .module = current.modules.rawLookup(module_name) }
                else
                    .absent,
            };
        }

        pub fn deinit(self: *TestLookupCursor) void {
            self.view.deinit();
            self.* = undefined;
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
                        const found: Generation = .of(image orelse {
                            self.state = .complete;
                            break :result .{ .complete = null };
                        });
                        self.state = .{ .catalog = .{
                            .generation = found,
                            .cursor = found.testLookupCursor(self.test_name),
                        } };
                        break :result .pending;
                    },
                },
                .catalog => |*catalog| switch (catalog.cursor.advance()) {
                    .pending => .pending,
                    .complete => |body| result: {
                        const root = catalog.generation.image().home;
                        self.state = .complete;
                        break :result .{ .complete = if (body) |quotation|
                            .{ .root = root, .body = quotation }
                        else
                            null };
                    },
                },
                .complete => unreachable,
            };
        }
    };

    /// Records that the word of cell `id` resolved to `definition` in
    /// `resolved`, unless that is no longer what it resolves to: a later
    /// directory is current, or a registration is emptying cells. A refusal
    /// is no failure; the word resolves by lookup until a fill lands.
    /// Constant work under the writer lock.
    pub fn fillCell(self: *Registry, resolved: *const View, id: env.CellId, definition: *env.Definition) void {
        const backing = self.privateState();
        self.lockBlocking();
        defer self.unlock();
        if (backing.fills_closed == 0 and backing.directories.isCurrent(resolved.directory()))
            backing.cells.fill(id, definition);
    }

    /// The reader a turn is, for the turn's length.
    pub fn enterTurn(self: *Registry) TurnLease {
        return .{ .registry = self, .reader = self.privateState().directories.enter() };
    }

    /// What a reader that emptied its epoch owes: rotate under the writer
    /// lock and retire what the rotation released after it.
    fn retireSuperseded(self: *Registry) void {
        self.lockBlocking();
        const released = self.rotateDirectories();
        self.unlock();
        released.retire(self.releaseDomain());
    }

    /// The directory chains at most two rotations release.
    const Superseded = struct {
        chains: [2]?*Directory = .{ null, null },

        fn retire(self: Superseded, releases: *heap.ReleaseDomain) void {
            for (self.chains) |chain| if (chain) |first| releases.retire(first, &first.retirement);
        }
    };

    /// Under the writer lock, constant work: rotates the publisher's epochs
    /// while one has no reader and something superseded waits. The
    /// directories behind the current one are those superseded since the
    /// last flip. Two rotations release everything when no reader remains.
    fn rotateDirectories(self: *Registry) Superseded {
        const directories = &self.privateState().directories;
        var released: Superseded = .{};
        for (&released.chains) |*chain| {
            const current = directories.currentOwned() orelse break;
            if (current.previous == null and !directories.draining()) break;
            if (!directories.mayRotate()) break;
            chain.* = directories.rotate(current.previous);
            current.previous = null;
        }
        return released;
    }

    /// A fresh image for the module whose name's scope is `scope`. The
    /// caller has validated the name; the registry checks it again at
    /// publication, which is the boundary that owns registry names.
    pub fn createImage(
        self: *Registry,
        module: env.ModuleIdentity,
        provenance: RegistrationProvenance,
    ) error{OutOfMemory}!OwnedImage {
        return .init(try ModuleImage.create(self.allocator(), self.releaseDomain(), module, provenance));
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
            module: env.ModuleIdentity,
            provenance: RegistrationProvenance,
            instance: *native_module.ModuleInstance,
        ) error{OutOfMemory}!NativeCandidateCursor {
            const candidate = try registry.createImage(module, provenance);
            // The descriptor's module documentation was validated with it.
            candidate.document(instance.validated().documentation());
            return .{
                .registry = registry,
                .instance = instance,
                .candidate = candidate,
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
            scope: env.ModuleIdentity,
            provenance: RegistrationProvenance,
            module: env.BuiltinModule,
        ) error{OutOfMemory}!BuiltinCandidateCursor {
            var result: BuiltinCandidateCursor = .{
                .allocator = registry.allocator(),
                .releases = registry.releaseDomain(),
                .words = module.words,
                .candidate = try registry.createImage(scope, provenance),
            };
            errdefer result.deinit();
            const document = try result.buildDocumentation(module.doc);
            defer result.releases.releaseHeader(env.documentationHeader(document));
            result.candidate.?.document(document);
            return result;
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
            var work = poll.unbounded();
            const text = try poll.driveFallible(value.Value, &materializer, .{&work});
            return env.documentation(text.list) orelse {
                self.releases.releaseValue(text);
                return error.OutOfMemory;
            };
        }

        fn buildEffect(
            self: *BuiltinCandidateCursor,
            source: []const u8,
        ) error{OutOfMemory}!env.ValidatedEffect {
            const owned = try env.builtinEffectValue(self.allocator, self.releases, source);
            return env.ValidatedEffect.parse(owned.list) orelse {
                self.releases.releaseValue(owned);
                return error.OutOfMemory;
            };
        }
    };

    pub const CommitProgress = poll.Progress(void);
    /// Whether a top-level publication introduced its name or replaced an
    /// earlier binding of it.
    pub const DefineOutcome = enum { introduced, replaced };
    pub const DefineProgress = poll.Progress(DefineOutcome);

    const EditKind = enum { register, define };

    /// The one registry mutation. Capture the current directory, build a
    /// successor with the edit applied, and publish the successor under the
    /// writer lock if the captured one is still current; otherwise discard
    /// the candidate and start over. A racing edit of any kind is therefore
    /// observed as exactly one restart, never as a half-applied entry or a
    /// lost update. Registration and a top-level definition differ only in
    /// which entry changes and in what they do to the word cells, so each is
    /// this cursor specialized at compile time.
    ///
    /// The edit keeps the word cells true to the directory it publishes. A
    /// definition changes what one session name resolves to, so it empties
    /// that name's cells, publishes, and stores them, in one critical
    /// section. A registration can change what any name outside core
    /// resolves to, so before it commits it closes fills and empties those
    /// cells, a fixed number per step; fills stay closed until it commits or
    /// is abandoned, so no cell holds an answer read from the directory it
    /// replaces.
    ///
    /// The build is one bounded step: a persistent map's edit costs its
    /// depth, and the candidate shares every unchanged node with the snapshot. Both outcomes retire the candidate
    /// through `Directory.advanceRetirement`: publication chains it in front
    /// of the snapshot, and discard retires it alone.
    fn EditCursor(comptime kind: EditKind) type {
        return struct {
            const Self = @This();
            pub const Error = switch (kind) {
                .register => CommitError,
                .define => error{OutOfMemory},
            };
            pub const Progress = switch (kind) {
                .register => CommitProgress,
                .define => DefineProgress,
            };
            const Request = switch (kind) {
                .register => SealedImage,
                // The cursor owns one reference to a counted entry until it
                // is released; the published directory takes its own.
                .define => struct { name: intern.BindingName, entry: env.Entry },
            };

            const Build = struct {
                /// The snapshot the candidate was built from.
                view: View,
                candidate: *Directory,
            };
            const State = union(enum) {
                /// The next cell a registration has yet to empty.
                emptying: u32,
                snapshot,
                commit: Build,
                complete,
            };
            /// Cells emptied in one step, under the writer lock.
            const cells_per_step = 128;

            registry: *Registry,
            request: Request,
            state: State = switch (kind) {
                .register => .{ .emptying = 1 },
                .define => .snapshot,
            },
            /// Whether this registration holds fills closed.
            closed_fills: bool = false,

            pub fn deinit(self: *Self) void {
                switch (kind) {
                    .register => self.request.deinit(),
                    .define => self.request.entry.release(self.registry.releaseDomain()),
                }
                switch (self.state) {
                    .emptying, .snapshot, .complete => {},
                    .commit => |*build| self.discard(build),
                }
                if (self.closed_fills) {
                    self.registry.lockBlocking();
                    self.registry.privateState().fills_closed -= 1;
                    self.registry.unlock();
                }
                self.* = undefined;
            }

            fn discard(self: *Self, build: *Build) void {
                build.candidate.previous = null;
                self.registry.releaseDomain().retire(build.candidate, &build.candidate.retirement);
                build.view.deinit();
            }

            /// The top-level name a define edit publishes.
            pub fn definedName(self: *const Self) intern.BindingName {
                comptime std.debug.assert(kind == .define);
                return self.request.name;
            }

            pub fn advance(self: *Self) Error!Progress {
                switch (self.state) {
                    .emptying => |from| {
                        const backing = self.registry.privateState();
                        self.registry.lockBlocking();
                        if (!self.closed_fills) {
                            backing.fills_closed += 1;
                            self.closed_fills = true;
                        }
                        const next = backing.cells.emptyRegistered(from, cells_per_step);
                        self.registry.unlock();
                        self.state = if (next) |cell| .{ .emptying = cell } else .snapshot;
                        return .pending;
                    },
                    .snapshot => return self.beginSnapshot(),
                    .commit => |*build| {
                        self.registry.lockBlocking();
                        if (!self.registry.privateState().directories.isCurrent(build.view.directory())) {
                            self.registry.unlock();
                            var stale = build.*;
                            self.state = .snapshot;
                            self.discard(&stale);
                            return .pending;
                        }
                        // Read from the snapshot this edit replaces, which is
                        // current under the lock.
                        const defined = switch (kind) {
                            .define => if (build.view.directory()) |old|
                                if (old.names.find(self.request.name) == null) DefineOutcome.introduced else DefineOutcome.replaced
                            else
                                DefineOutcome.introduced,
                            .register => {},
                        };
                        build.candidate.previous = @constCast(build.view.directory());
                        const backing = self.registry.privateState();
                        _ = backing.publications.fetchAdd(1, .acq_rel);
                        // The name's cells are empty across the publication,
                        // so a reader finds the old answer, then a lookup's,
                        // then the new one, and never one beside a directory
                        // that says otherwise.
                        if (kind == .define) backing.cells.define(self.request.name, null);
                        backing.directories.publish(build.candidate);
                        switch (kind) {
                            // A definition is what the name's cells answer
                            // now; an import is followed by lookup.
                            .define => switch (self.request.entry) {
                                .definition => |definition| backing.cells.define(self.request.name, definition),
                                .alias => {},
                            },
                            // Nothing was filled since the cells were
                            // emptied: a restart keeps fills closed.
                            .register => {
                                backing.fills_closed -= 1;
                                self.closed_fills = false;
                            },
                        }
                        _ = backing.publications.fetchAdd(1, .acq_rel);
                        // A writer rotates too, so reclamation advances
                        // while readers overlap without end.
                        const released = self.registry.rotateDirectories();
                        self.registry.unlock();
                        released.retire(self.registry.releaseDomain());
                        var published = build.*;
                        self.state = .complete;
                        published.view.deinit();
                        return switch (kind) {
                            .register => .complete,
                            .define => .{ .complete = defined },
                        };
                    },
                    .complete => unreachable,
                }
            }

            fn beginSnapshot(self: *Self) Error!Progress {
                switch (kind) {
                    .register => if (intern.isReservedRegistryBytes(intern.get(intern.moduleId(self.request.borrow().moduleName()))))
                        return error.ReservedName,
                    .define => {},
                }
                var captured = self.registry.view();
                const candidate = self.buildCandidate(captured.directory()) catch |err| {
                    captured.deinit();
                    return err;
                };
                self.state = .{ .commit = .{ .view = captured, .candidate = candidate } };
                return .pending;
            }

            /// The successor directory: the snapshot's maps with this edit's
            /// one entry changed. Bounded by the maps' depth.
            fn buildCandidate(self: *Self, snapshot: ?*const Directory) error{OutOfMemory}!*Directory {
                const releases = self.registry.releaseDomain();
                // Read the maps alone: `previous` is rewritten under the writer
                // lock when readers quiesce, so copying the whole snapshot
                // would race with that detach.
                const empty: Directory = .{};
                const source = snapshot orelse &empty;
                const old = .{
                    .modules = source.modules,
                    .names = source.names,
                };
                var modules = switch (kind) {
                    .register => register: {
                        const image = self.request.borrow();
                        break :register try old.modules.put(releases, image.moduleName(), image);
                    },
                    .define => old.modules.retain(),
                };
                errdefer modules.release(releases);
                var names = switch (kind) {
                    .define => try old.names.put(releases, self.request.name, self.request.entry),
                    .register => old.names.retain(),
                };
                errdefer names.release(releases);
                const candidate = try releases.allocator.create(Directory);
                candidate.* = .{ .modules = modules, .names = names };
                return candidate;
            }
        };
    }

    pub const RegistrationCursor = EditCursor(.register);
    pub const DefineCursor = EditCursor(.define);

    pub fn registrationCursor(self: *Registry, image: SealedImage) RegistrationCursor {
        return .{ .registry = self, .request = image };
    }
    /// Publishes one top-level name. The cursor takes the caller's reference
    /// to a counted entry.
    pub fn defineCursor(self: *Registry, name: intern.BindingName, entry: env.Entry) DefineCursor {
        return .{ .registry = self, .request = .{ .name = name, .entry = entry } };
    }

    /// The registration a module name selects in a snapshot this cursor
    /// captures and holds, for a holder that has no view of its own.
    pub const AcquireCursor = struct {
        view: View,
        cursor: ModuleCursor,

        pub fn deinit(self: *AcquireCursor) void {
            self.view.deinit();
            self.* = undefined;
        }
        /// The registration found is borrowed from this cursor's view.
        pub fn advance(self: *AcquireCursor) ModuleCursor.Progress {
            return self.cursor.advance();
        }
    };
    pub fn acquireCursor(self: *const Registry, name: intern.ModuleName) AcquireCursor {
        const captured = self.view();
        return .{ .view = captured, .cursor = captured.moduleCursor(name) };
    }

    /// Captures the current snapshot as one coherent view.
    pub fn view(self: *const Registry) View {
        return .{ .registry = self, .lease = self.privateState().directories.acquire() };
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
        artifact: module_search.FileId,
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
    /// Whether `name` is registered now.
    pub fn registered(registry: *const Registry, name: intern.ModuleName) bool {
        var cursor = registry.acquireCursor(name);
        defer cursor.deinit();
        return poll.drive(?Generation, &cursor, .{}) != null;
    }

    pub fn register(registry: *Registry, image: *SealedImage) CommitError!void {
        var cursor = registry.registrationCursor(image.move());
        defer cursor.deinit();
        return poll.driveVoidFallible(&cursor, .{});
    }
} else struct {};
