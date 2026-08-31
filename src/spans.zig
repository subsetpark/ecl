//! Session-lifetime ownership and direct lookup for reader provenance tables.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");
const poll = @import("poll.zig");
const dict = @import("dict.zig");

pub const LocatedSpan = struct {
    source_name: []const u8,
    span: lexer.Span,
};

const Entry = struct {
    previous: ?*Entry = null,
    next: ?*Entry = null,
    root: value.Value,
    spans: reader.SpanTable,
    source_name: []u8,
    source: reader.SourceSlice,

    fn deinit(
        self: *Entry,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
    ) void {
        var spans_cursor = reader.SpanTable.RetireCursor.init(&self.spans);
        while (spans_cursor.advance(releases) == .pending) {}
        releases.releaseValue(self.root);
        allocator.free(self.source_name);
        self.source.deinit();
        self.* = undefined;
    }
};

const IndexedSpan = struct {
    archive_entry: *const Entry,
    token_entry: *const reader.SpanTable.Entry,
    source_entry: ?*const reader.SpanTable.Entry,
    container_entry: ?*const reader.SpanTable.Entry,
};

/// A three-level direct directory keyed by the 24 provenance bits in a heap
/// header. Each publication allocates at most the fixed pages its exact ID
/// range touches; lookup is three array reads, independent of source history
/// and pointer-hash collisions.
const HeaderIndex = struct {
    const radix = 256;
    const Leaf = struct {
        headers: [radix]?*value.ListHandle = @splat(null),
        entries: [radix]IndexedSpan,
        /// Intrusive free list over recycled identities. Retirement is
        /// allocation-free by construction — it runs on release-domain workers,
        /// where a failed allocation has no caller to report to — so the link
        /// lives in the page the identity already occupies rather than in a
        /// side container.
        free_next: [radix]u32 = @splat(0),
    };
    const Branch = struct { leaves: [radix]?*Leaf = @splat(null) };

    branches: [radix]?*Branch = @splat(null),
    next_identity: u32 = 1,
    /// Head of the recycled-identity list, or zero. Identities are pushed only
    /// once their header is destroyed and its slot cleared, so nothing live can
    /// present a recycled number: the ABA case needs a header that no longer
    /// exists.
    free_head: u32 = 0,

    fn coordinates(identity: heap.CodeIdentity) struct { usize, usize, usize } {
        const raw = @intFromEnum(identity);
        std.debug.assert(raw != 0 and raw <= heap.max_code_identity);
        return .{
            @intCast((raw >> 16) & 0xff),
            @intCast((raw >> 8) & 0xff),
            @intCast(raw & 0xff),
        };
    }

    /// The identity a claim would take next, without taking it. Backing pages
    /// are prepared for this candidate before anything is committed, so a
    /// rollback never depends on a page that a failure prevented from existing.
    fn candidate(self: *const HeaderIndex) error{OutOfMemory}!heap.CodeIdentity {
        if (self.free_head != 0) return @enumFromInt(self.free_head);
        if (self.next_identity > heap.max_code_identity) return error.OutOfMemory;
        return @enumFromInt(self.next_identity);
    }

    /// Takes `wanted` if it is still what `candidate` would return. A racing
    /// claim makes this false, and the owning cursor yields before asking on a
    /// later advance — losing consumes no identity.
    fn claim(self: *HeaderIndex, wanted: heap.CodeIdentity) bool {
        const raw = @intFromEnum(wanted);
        if (self.free_head == raw) {
            // Recycled: its page exists by construction, because a slot reaches
            // the free list only after having been installed.
            const branch_index, const leaf_index, const entry_index = coordinates(wanted);
            const leaf = self.branches[branch_index].?.leaves[leaf_index].?;
            std.debug.assert(leaf.headers[entry_index] == null);
            self.free_head = leaf.free_next[entry_index];
            leaf.free_next[entry_index] = 0;
            return true;
        }
        if (self.free_head == 0 and self.next_identity == raw) {
            self.next_identity = raw + 1;
            return true;
        }
        return false;
    }

    /// Offers a claimed but uninstalled identity for reuse. Its page exists —
    /// `candidate` prepared one before the claim — so the free list can always
    /// take it, with no range arithmetic and no dependence on the frontier.
    fn unclaim(self: *HeaderIndex, identity: heap.CodeIdentity) void {
        const branch_index, const leaf_index, const entry_index = coordinates(identity);
        const leaf = self.branches[branch_index].?.leaves[leaf_index].?;
        std.debug.assert(leaf.headers[entry_index] == null);
        leaf.free_next[entry_index] = self.free_head;
        self.free_head = @intFromEnum(identity);
    }

    /// Clears one destroyed header's slot and offers its identity for reuse.
    /// The exact-header check is what makes this safe against a slot that was
    /// already replaced or never installed.
    fn release(self: *HeaderIndex, identity: heap.CodeIdentity, header: *value.ListHandle) void {
        const branch_index, const leaf_index, const entry_index = coordinates(identity);
        const branch = self.branches[branch_index] orelse return;
        const leaf = branch.leaves[leaf_index] orelse return;
        if (leaf.headers[entry_index] != header) return;
        leaf.headers[entry_index] = null;
        // SAFETY: a null header makes its parallel entry unreachable, and the
        // slot is initialized again by `set` before that header is republished.
        leaf.entries[entry_index] = undefined;
        leaf.free_next[entry_index] = self.free_head;
        self.free_head = @intFromEnum(identity);
    }

    fn set(
        self: *HeaderIndex,
        identity: heap.CodeIdentity,
        header: *value.ListHandle,
        indexed: IndexedSpan,
    ) void {
        const branch_index, const leaf_index, const entry_index = coordinates(identity);
        const leaf = self.branches[branch_index].?.leaves[leaf_index].?;
        std.debug.assert(leaf.headers[entry_index] == null or leaf.headers[entry_index] == header);
        leaf.entries[entry_index] = indexed;
        leaf.headers[entry_index] = header;
    }

    fn get(
        self: *const HeaderIndex,
        identity: heap.CodeIdentity,
        header: *value.ListHandle,
    ) ?IndexedSpan {
        const branch_index, const leaf_index, const entry_index = coordinates(identity);
        const branch = self.branches[branch_index] orelse return null;
        const leaf = branch.leaves[leaf_index] orelse return null;
        if (leaf.headers[entry_index] != header) return null;
        return leaf.entries[entry_index];
    }

    fn deinit(self: *HeaderIndex, allocator: std.mem.Allocator) void {
        for (&self.branches) |*maybe_branch| if (maybe_branch.*) |branch| {
            for (&branch.leaves) |*maybe_leaf| if (maybe_leaf.*) |leaf|
                allocator.destroy(leaf);
            allocator.destroy(branch);
        };
        self.* = .{};
    }
};

/// Span tables retain their source code roots. Besides keeping definitions'
/// identity alive, this keeps every header's direct identity valid for the
/// complete lifetime of its directory entry.
const SpanArchiveOwnerState = struct {
    host_owner: *heap.HostOwner,
    /// The receipt belongs to the host-side owner, never to the worker runtime
    /// that the archive view can reach.
    code_retirement: heap.HostOwner.CodeRetirementRegistration = .released,
    runtime: *SpanArchiveState,
};

const SpanArchiveState = struct {
    release_domain: *heap.ReleaseDomain,
    identity_issuer: *heap.CodeIdentityIssuer,
    mutex: std.Io.Mutex = .init,
    first: ?*Entry = null,
    last: ?*Entry = null,
    index: HeaderIndex = .{},
    /// One identity, held until it is committed to an exact header or given
    /// back. Abandoning it is the default: the destructor returns it, so no
    /// path out of a publication can consume identity capacity without
    /// installing something.
    const IdentityTransaction = struct {
        const AliasPublication = enum { published, refused };

        state: *SpanArchiveState,
        held: ?heap.CodeIdentity,

        fn publishAlias(
            self: *IdentityTransaction,
            rewritten: *value.ListHandle,
            existing: IndexedSpan,
        ) AliasPublication {
            if (!self.state.aliasIndexed(self.held.?, rewritten, existing))
                return .refused;
            self.held = null;
            return .published;
        }

        fn publishSpan(
            self: *IdentityTransaction,
            archive_entry: *Entry,
            span_entry: *const reader.SpanTable.Entry,
        ) void {
            if (self.state.commitSpan(self.held.?, archive_entry, span_entry))
                self.held = null;
        }

        fn deinit(self: *IdentityTransaction) void {
            if (self.held) |unused| {
                std.Io.Threaded.mutexLock(&self.state.mutex);
                defer std.Io.Threaded.mutexUnlock(&self.state.mutex);
                self.state.index.unclaim(unused);
            }
            self.held = null;
        }
    };

    /// Acquires one identity whose directory page already exists. Preparation
    /// happens before the claim and mutates nothing on failure, so a failure
    /// here leaves the identity space exactly as it found it — there is no
    /// reserved suffix to lose and no page-dependent rollback. Exactly one
    /// claim is attempted; a racing loss is `null`, never a local retry loop.
    fn beginIdentity(
        self: *SpanArchiveState,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!?IdentityTransaction {
        const wanted = wanted: {
            std.Io.Threaded.mutexLock(&self.mutex);
            defer std.Io.Threaded.mutexUnlock(&self.mutex);
            break :wanted try self.index.candidate();
        };
        try self.ensureIndexSlot(allocator, wanted);
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (!self.index.claim(wanted)) return null;
        return .{ .state = self, .held = wanted };
    }

    /// Installs fixed index pages without allocating while the publication
    /// mutex is held. Concurrent absorbers may race to prepare the same page;
    /// the loser destroys its unused candidate after the lock is released.
    fn ensureIndexSlot(
        self: *SpanArchiveState,
        allocator: std.mem.Allocator,
        identity: heap.CodeIdentity,
    ) error{OutOfMemory}!void {
        const branch_index, const leaf_index, _ = HeaderIndex.coordinates(identity);
        var need_branch = false;
        var need_leaf = false;
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.index.branches[branch_index]) |branch| {
            need_leaf = branch.leaves[leaf_index] == null;
        } else {
            need_branch = true;
            need_leaf = true;
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (!need_leaf) return;

        var branch_candidate: ?*HeaderIndex.Branch = null;
        defer if (branch_candidate) |candidate| allocator.destroy(candidate);
        if (need_branch) {
            const candidate = try allocator.create(HeaderIndex.Branch);
            candidate.* = .{};
            branch_candidate = candidate;
        }
        var leaf_candidate: ?*HeaderIndex.Leaf = try allocator.create(HeaderIndex.Leaf);
        // SAFETY: a null header makes its parallel entry unreachable, and set
        // initializes the entry before publishing that exact header.
        leaf_candidate.?.* = .{ .entries = undefined };
        defer if (leaf_candidate) |candidate| allocator.destroy(candidate);

        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.index.branches[branch_index] == null) {
            self.index.branches[branch_index] = branch_candidate.?;
            branch_candidate = null;
        }
        const branch = self.index.branches[branch_index].?;
        if (branch.leaves[leaf_index] == null) {
            branch.leaves[leaf_index] = leaf_candidate.?;
            leaf_candidate = null;
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn publish(self: *SpanArchiveState, entry: *Entry) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        entry.previous = self.last;
        if (self.last) |last| last.next = entry else self.first = entry;
        self.last = entry;
    }

    /// The release domain's O(1) notice that one indexed header is gone. A
    /// foreign namespace is ignored: a header another archive read is none of
    /// this one's business, and its identity means nothing here.
    pub fn retireCodeIdentity(
        self: *SpanArchiveState,
        namespace: heap.CodeProvenanceNamespace,
        identity: heap.CodeIdentity,
        header: *value.ListHandle,
    ) void {
        if (namespace != self.identity_issuer.constructionNamespace()) return;
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        self.index.release(identity, header);
    }

    fn indexed(self: *SpanArchiveState, header: *value.ListHandle) ?IndexedSpan {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const identity = heap.codeIdentity(self.identity_issuer, header) orelse return null;
        return self.index.get(identity, header);
    }

    /// Registers `rewritten` under a fresh identity carrying `original`'s span
    /// record, so a code value that was rebuilt keeps reporting the source it
    /// was read from. The span entries are archive-owned and shared rather than
    /// copied; only the identity is new, which keeps the index's one-header-per
    /// -identity invariant intact.
    fn aliasIndexed(
        self: *SpanArchiveState,
        identity: heap.CodeIdentity,
        rewritten: *value.ListHandle,
        existing: IndexedSpan,
    ) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (heap.assignCodeIdentity(self.identity_issuer, rewritten, identity) != .assigned)
            return false;
        self.index.set(identity, rewritten, existing);
        return true;
    }

    /// Validation precedes identity reservation and every header/index write.
    /// Existing identities are accepted only when this exact archive already
    /// indexes the exact header under that identity.
    fn validateAbsorptionHeader(
        self: *SpanArchiveState,
        header: *value.ListHandle,
    ) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (heap.inspectCodeIdentity(self.identity_issuer, header)) {
            .unassigned => true,
            .assigned => |identity| self.index.get(identity, header) != null,
            .foreign_namespace => false,
        };
    }

    /// Commits one already-validated span in O(1) under the publication lock.
    /// Assignment and exact-header membership become visible atomically to
    /// other absorbers and diagnostic readers.
    fn commitSpan(
        self: *SpanArchiveState,
        identity: heap.CodeIdentity,
        archive_entry: *const Entry,
        span_entry: *const reader.SpanTable.Entry,
    ) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        switch (heap.inspectCodeIdentity(self.identity_issuer, span_entry.header)) {
            .foreign_namespace => @panic("validated provenance namespace changed before commit"),
            .assigned => |existing_identity| {
                const existing = self.index.get(existing_identity, span_entry.header) orelse
                    @panic("validated provenance membership changed before commit");
                var updated = existing;
                updated.archive_entry = archive_entry;
                updated.token_entry = span_entry;
                if (span_entry.source_range != null) updated.source_entry = span_entry;
                if (span_entry.container_span != null) updated.container_entry = span_entry;
                self.index.set(existing_identity, span_entry.header, updated);
                return false;
            },
            .unassigned => {},
        }
        if (heap.assignCodeIdentity(
            self.identity_issuer,
            span_entry.header,
            identity,
        ) != .assigned) @panic("validated provenance assignment changed before commit");
        self.index.set(identity, span_entry.header, .{
            .archive_entry = archive_entry,
            .token_entry = span_entry,
            .source_entry = if (span_entry.source_range != null) span_entry else null,
            .container_entry = if (span_entry.container_span != null) span_entry else null,
        });
        return true;
    }
};

/// Host-side ownership of one archive. Only this capability can register the
/// retirement callback or tear the archive down; execution receives the
/// separate `SpanArchive` view below.
pub const SpanArchiveOwner = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const SpanArchiveOwner) *SpanArchiveOwnerState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    /// One reclamation root has one code provenance owner: a second archive on
    /// the same host is refused rather than silently replacing the first.
    pub const InitError = error{ OutOfMemory, CodeProvenanceTaken };

    pub fn init(host_owner: *heap.HostOwner) InitError!SpanArchiveOwner {
        const owner_allocator = host_owner.domain().allocator;
        const backing = try owner_allocator.create(SpanArchiveOwnerState);
        errdefer owner_allocator.destroy(backing);
        const runtime = try owner_allocator.create(SpanArchiveState);
        errdefer owner_allocator.destroy(runtime);
        const identity_issuer = try heap.CodeIdentityIssuer.init(owner_allocator);
        errdefer identity_issuer.deinit();
        runtime.* = .{
            .release_domain = host_owner.domain(),
            .identity_issuer = identity_issuer,
        };
        backing.* = .{
            .host_owner = host_owner,
            .runtime = runtime,
        };
        backing.code_retirement = host_owner.attachCodeRetirement(runtime) orelse
            return error.CodeProvenanceTaken;
        return @enumFromInt(@intFromPtr(backing));
    }

    pub fn view(self: *const SpanArchiveOwner) SpanArchive {
        return @enumFromInt(@intFromPtr(self.privateState().runtime));
    }

    /// Host-driven synchronous reading returns a host-owned parsed value whose
    /// blocking teardown needs the same cleanup authority as this owner.
    pub fn read(
        self: *const SpanArchiveOwner,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
        word_scope: u32,
    ) reader.Error!reader.ReadResult {
        const backing = self.privateState();
        return reader.readCode(
            backing.host_owner.cleanup(),
            source_name,
            source,
            diag,
            backing.runtime.identity_issuer.constructionNamespace(),
            word_scope,
        );
    }

    pub fn deinit(self: *SpanArchiveOwner) void {
        const backing = self.privateState();
        const owner_allocator = backing.host_owner.domain().allocator;
        const runtime = backing.runtime;
        // Nothing may reach the directory once it is being torn down; whatever
        // retires from here on keeps its slot, which is about to be freed with
        // the rest of the pages.
        backing.host_owner.detachCodeRetirement(&backing.code_retirement);
        std.Io.Threaded.mutexLock(&runtime.mutex);
        var current = runtime.first;
        runtime.first = null;
        runtime.last = null;
        var index = runtime.index;
        runtime.index = .{};
        std.Io.Threaded.mutexUnlock(&runtime.mutex);
        const releases = backing.host_owner.domain();
        while (current) |entry| {
            current = entry.next;
            entry.deinit(owner_allocator, releases);
            owner_allocator.destroy(entry);
        }
        index.deinit(owner_allocator);
        backing.host_owner.cleanup().drain();
        runtime.identity_issuer.deinit();
        owner_allocator.destroy(runtime);
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }
};

/// Copyable execution/observation facade. It can read, absorb, locate, and
/// re-scope, but has no registration, detachment, drain, or destruction API.
pub const SpanArchive = enum(usize) {
    invalid = 0,
    _,

    fn privateState(self: *const SpanArchive) *SpanArchiveState {
        std.debug.assert(self.* != .invalid);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    fn allocator(self: *const SpanArchive) std.mem.Allocator {
        return self.privateState().release_domain.allocator;
    }

    fn releaseDomain(self: *const SpanArchive) *heap.ReleaseDomain {
        return self.privateState().release_domain;
    }

    fn provenanceNamespace(self: *const SpanArchive) heap.CodeProvenanceNamespace {
        return self.privateState().identity_issuer.constructionNamespace();
    }

    const AdmittedConstructionBacking = struct {
        archive: SpanArchive,
        source: heap.Owned(*value.ListHandle),
        projection: IndexedSpan,
    };

    /// A consuming, exact-root admission. Its opaque backing owns the source
    /// body and fixes both the archive and source projection; the only
    /// operation consumes it into the archive's own bounded rewrite, so no
    /// caller can pair admission with another archive or destination header.
    pub const AdmittedConstructionBody = opaque {
        pub fn begin(
            self: *AdmittedConstructionBody,
            scope: u32,
        ) RescopeCursor {
            const backing = admittedConstructionBacking(self);
            const archive = backing.archive;
            const source = backing.source.take();
            const projection = backing.projection;
            archive.allocator().destroy(backing);
            return .{
                .archive = archive,
                .source = .init(source),
                .root_projection = projection,
                .scope = scope,
            };
        }

        pub fn deinit(self: *AdmittedConstructionBody) void {
            const backing = admittedConstructionBacking(self);
            const archive = backing.archive;
            backing.source.deinit(archive.releaseDomain(), archive.allocator());
            archive.allocator().destroy(backing);
        }
    };

    fn admittedConstructionBacking(
        admitted: *AdmittedConstructionBody,
    ) *AdmittedConstructionBacking {
        return @ptrCast(@alignCast(admitted));
    }

    /// Records that `rewritten` is a re-scoped copy of admitted reader text:
    /// it inherits the source's span projections, so an error raised inside a
    /// module body still reports where it was read from, and it inherits the
    /// source's reader-text lineage, so a construction nested inside an
    /// already-re-scoped body can be admitted in turn.
    ///
    /// Private, and takes the admission result rather than a portable proof.
    /// Admission happened when the cursor was created, so there is no lookup
    /// left to fail here and no caller-chosen destination to attest: the only
    /// caller is `RescopeCursor`, and the header is the one it just built.
    fn publishLineage(
        self: *SpanArchive,
        existing: IndexedSpan,
        rewritten: *value.ListHandle,
    ) error{OutOfMemory}!enum { pending, published, refused } {
        const backing = self.privateState();
        var transaction = (try backing.beginIdentity(self.allocator())) orelse return .pending;
        defer transaction.deinit();
        return switch (transaction.publishAlias(rewritten, existing)) {
            .published => .published,
            .refused => .refused,
        };
    }

    /// The one semantic attribution decision: does this exact root carry
    /// reader-text lineage in this archive?
    fn admitRoot(self: *const SpanArchive, header: *value.ListHandle) ?IndexedSpan {
        return self.privateState().indexed(header);
    }

    /// Diagnostic projection for a descendant of an already-admitted reader
    /// subtree. This is not another semantic gate: a missing projection is an
    /// invariant failure reported by the cursor, never permission to share the
    /// descendant unchanged.
    fn projectDescendant(self: *const SpanArchive, header: *value.ListHandle) ?IndexedSpan {
        return self.privateState().indexed(header);
    }

    /// What a unit constructor does with the body it was handed.
    pub const PreparedConstructionBody = union(enum) {
        /// No reader-text lineage, or nothing in this representation that a
        /// re-scope could change. The caller runs the body exactly as it is and
        /// keeps the reference it already holds.
        unchanged: heap.Owned(*value.ListHandle),
        /// Admitted and bound to this exact root/archive, but awaiting the
        /// target image's lazily minted scope id.
        admitted: *AdmittedConstructionBody,
    };

    /// The single attribution operation. The archive performs admission
    /// internally and hands back either the unchanged owner or an opaque root
    /// bound to this archive and awaiting its target scope. The predicate and
    /// its application therefore cannot disagree, and no proof crosses the API
    /// to be replayed against a different archive.
    pub fn prepareConstructionBody(
        self: *SpanArchive,
        body: *heap.Owned(*value.ListHandle),
    ) error{OutOfMemory}!PreparedConstructionBody {
        // A specialized leaf holds no word and no container, so re-scoping it
        // could not change anything even if it were admitted.
        if (body.borrow().kind() != .generic_spine)
            return .{ .unchanged = .init(body.take()) };
        const projection = self.admitRoot(body.borrow()) orelse
            return .{ .unchanged = .init(body.take()) };
        const backing = try self.allocator().create(AdmittedConstructionBacking);
        backing.* = .{
            .archive = self.*,
            .source = .init(body.take()),
            .projection = projection,
        };
        return .{ .admitted = @ptrCast(backing) };
    }

    pub const RescopeProgress = poll.Progress(*value.ListHandle);

    /// A resumable, non-recursive re-scoping of one admitted body: a copy of
    /// the same reader text with `scope` on every word occurrence in its
    /// reader-built subtree.
    ///
    /// Two properties are structural rather than reviewed. The frame stack is
    /// the recursion, so depth costs no native stack; and every frame owns its
    /// destination builder from the first element, so there is no bulk
    /// finalizer — publishing a finished container is O(1). Both traversal and
    /// a dict's index copy draw from one caller-supplied `WorkBudget`, so a
    /// step cannot spend its slice and then start a second pass.
    pub const RescopeCursor = struct {
        /// One in-progress code container. `builder`'s length *is* the
        /// initialized prefix: retiring it releases exactly the elements
        /// written so far, so abandonment needs no separate bookkeeping.
        const CodeFrame = struct {
            source: *value.ListHandle,
            lineage: IndexedSpan,
            output: union(enum) {
                building: heap.ListBuilder(.generic_spine),
                ready_to_publish: *value.ListHandle,
            },
            position: usize = 0,
        };

        /// One in-progress dict container.
        ///
        /// Re-scoping changes only a word's resolution metadata, and neither
        /// equality nor hashing looks at it, so the copy's hashes are the
        /// source's hashes: the header is shared and nothing is rehashed or
        /// compared. A keys or vals list that is not a generic spine cannot
        /// hold a word or a container either, so it is shared too and its half
        /// of the traversal has nothing to write.
        const DictFrame = struct {
            source: *value.DictHandle,
            keys: ?heap.ListBuilder(.generic_spine),
            vals: ?heap.ListBuilder(.generic_spine),
            /// The source's lookup index, copied a budgeted slice at a time.
            index: ?[]u32 = null,
            copied: usize = 0,
            position: usize = 0,
            stage: enum { entries, index, publish } = .entries,
        };

        const Frame = union(enum) {
            code: CodeFrame,
            dictionary: DictFrame,

            fn retire(self: *Frame, scratch: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
                switch (self.*) {
                    .code => |*frame| switch (frame.output) {
                        .building => |*builder| builder.retirePartial(releases),
                        .ready_to_publish => |header| releases.releaseHeader(header),
                    },
                    .dictionary => |*frame| {
                        if (frame.keys) |*builder| builder.retirePartial(releases);
                        if (frame.vals) |*builder| builder.retirePartial(releases);
                        if (frame.index) |owned| scratch.free(owned);
                    },
                }
            }
        };

        archive: SpanArchive,
        source: heap.Owned(*value.ListHandle),
        root_projection: IndexedSpan,
        scope: u32,
        frames: std.ArrayList(Frame) = .empty,
        started: bool = false,

        /// Abandons an unfinished re-scope. Every element any frame wrote goes
        /// back through the release domain, and the sources are untouched.
        pub fn deinit(self: *RescopeCursor) void {
            const scratch = self.archive.allocator();
            const releases = self.archive.releaseDomain();
            for (self.frames.items) |*frame| frame.retire(scratch, releases);
            self.frames.deinit(scratch);
            self.source.deinit(releases, scratch);
            self.* = undefined;
        }

        pub fn advance(
            self: *RescopeCursor,
            work: *poll.WorkBudget,
        ) error{ OutOfMemory, InvalidProvenance }!RescopeProgress {
            const scratch = self.archive.allocator();
            if (!self.started) {
                try self.pushCode(self.source.borrow(), self.root_projection);
                self.started = true;
            }
            // Each step charges the budget for exactly the work it does, so a
            // budget of one unit performs one element — and an index slice gets
            // the whole remaining allowance rather than what is left after the
            // loop has already spent it.
            while (!work.exhausted()) {
                const top = &self.frames.items[self.frames.items.len - 1];
                const finished = switch (top.*) {
                    .code => |*frame| try self.stepCode(frame, work),
                    .dictionary => |*frame| try self.stepDictionary(frame, work),
                } orelse continue;
                self.frames.items.len -= 1;
                if (self.frames.items.len == 0) {
                    std.debug.assert(finished == .list);
                    // Left in a finished state rather than invalidated, so an
                    // owner still holding the cursor disposes of it exactly as
                    // it would have on cancellation.
                    self.frames.deinit(scratch);
                    self.frames = .empty;
                    return .{ .complete = finished.list };
                }
                self.place(&self.frames.items[self.frames.items.len - 1], finished);
            }
            return .pending;
        }

        /// One element of a code container, or its O(1) publication.
        fn stepCode(
            self: *RescopeCursor,
            frame: *CodeFrame,
            work: *poll.WorkBudget,
        ) error{ OutOfMemory, InvalidProvenance }!?value.Value {
            const count: usize = @intCast(frame.source.length());
            if (frame.position != count) {
                charge(work);
                const item = list.atUnchecked(.{ .list = frame.source }, frame.position);
                if (try self.rewrite(item)) |rewritten| {
                    appendOwned(&frame.output.building, rewritten);
                    frame.position += 1;
                }
                return null;
            }
            charge(work);
            if (frame.output == .building) {
                const rewritten = frame.output.building.finish();
                frame.output = .{ .ready_to_publish = rewritten };
            }
            const rewritten = frame.output.ready_to_publish;
            switch (try self.archive.publishLineage(frame.lineage, rewritten)) {
                .pending => return null,
                .published => {},
                .refused => return error.InvalidProvenance,
            }
            return .{ .list = rewritten };
        }

        /// One key, one value, one slice of the index, or the O(1) publication.
        fn stepDictionary(
            self: *RescopeCursor,
            frame: *DictFrame,
            work: *poll.WorkBudget,
        ) error{ OutOfMemory, InvalidProvenance }!?value.Value {
            const scratch = self.archive.allocator();
            const entries: usize = @intCast(frame.source.length());
            switch (frame.stage) {
                .entries => {
                    if (frame.position == entries * 2) {
                        frame.stage = .index;
                        return null;
                    }
                    charge(work);
                    const entry = frame.position / 2;
                    const on_key = frame.position % 2 == 0;
                    const builder = if (on_key) &frame.keys else &frame.vals;
                    if (builder.* == null) {
                        // A shared half has nothing to write; the position still
                        // costs a unit, so skipping cannot outrun the budget.
                        frame.position += 1;
                        return null;
                    }
                    const item = if (on_key)
                        dict.keyAt(frame.source, entry)
                    else
                        dict.valueAt(frame.source, entry);
                    if (try self.rewrite(item)) |rewritten| {
                        appendOwned(&builder.*.?, rewritten);
                        frame.position += 1;
                    }
                    return null;
                },
                .index => {
                    const source_index = heap.dictStorageConst(frame.source).index() orelse {
                        frame.stage = .publish;
                        return null;
                    };
                    if (frame.index == null) frame.index = try scratch.alloc(u32, source_index.len);
                    const granted = work.take(source_index.len - frame.copied);
                    const end = frame.copied + granted;
                    @memcpy(frame.index.?[frame.copied..end], source_index[frame.copied..end]);
                    frame.copied = end;
                    if (frame.copied == source_index.len) frame.stage = .publish;
                    return null;
                },
                .publish => {
                    charge(work);
                    const payload = heap.dictStorageConst(frame.source).payload();
                    var builder = try heap.DictBuilder.init(scratch, entries);
                    // Past this point nothing can fail, so the shared headers
                    // are retained here rather than at push time: abandonment
                    // before publication has nothing extra to release.
                    const keys = if (frame.keys) |*owned| owned.finish() else share: {
                        heap.incRef(payload.keys);
                        break :share payload.keys;
                    };
                    const vals = if (frame.vals) |*owned| owned.finish() else share: {
                        heap.incRef(payload.vals);
                        break :share payload.vals;
                    };
                    heap.incRef(payload.hashes);
                    const index = frame.index;
                    frame.index = null;
                    return .{ .dict = builder.finish(
                        .{ .keys = keys, .vals = vals, .hashes = payload.hashes },
                        index,
                    ) };
                },
            }
        }

        /// The rewritten form of one element, or null when a nested container
        /// was pushed instead and the parent must wait for it.
        fn rewrite(
            self: *RescopeCursor,
            item: value.Value,
        ) error{ OutOfMemory, InvalidProvenance }!?value.Value {
            shared: switch (item) {
                // The one rewrite: a word occurrence inside this body's text
                // names the image the body is becoming.
                .word => |reference| return .{
                    .word = .{ .name = reference.name, .scope = self.scope },
                },
                .list => |nested| {
                    if (nested.kind() != .generic_spine) break :shared;
                    const projection = self.archive.projectDescendant(nested) orelse
                        return error.InvalidProvenance;
                    try self.pushCode(nested, projection);
                    return null;
                },
                .dict => |nested| {
                    // A dict inside admitted text is text too, which is what makes
                    // `{'a (k)} 'd setp` behave like `[(k)] 'd setp`. When
                    // neither half can hold a word there is nothing to copy.
                    const payload = heap.dictStorageConst(nested).payload();
                    const rewrite_keys = payload.keys.kind() == .generic_spine;
                    const rewrite_vals = payload.vals.kind() == .generic_spine;
                    if (!rewrite_keys and !rewrite_vals) break :shared;
                    try self.pushDictionary(nested, rewrite_keys, rewrite_vals);
                    return null;
                },
                else => {},
            }
            heap.retainValue(item);
            return item;
        }

        fn place(self: *RescopeCursor, parent: *Frame, item: value.Value) void {
            _ = self;
            switch (parent.*) {
                .code => |*frame| {
                    appendOwned(&frame.output.building, item);
                    frame.position += 1;
                },
                .dictionary => |*frame| {
                    const builder = if (frame.position % 2 == 0) &frame.keys else &frame.vals;
                    appendOwned(&builder.*.?, item);
                    frame.position += 1;
                },
            }
        }

        fn pushCode(
            self: *RescopeCursor,
            source: *value.ListHandle,
            lineage: IndexedSpan,
        ) error{OutOfMemory}!void {
            const scratch = self.archive.allocator();
            var builder = try heap.ListBuilder(.generic_spine).initCode(
                scratch,
                0,
                @intCast(source.length()),
                self.archive.provenanceNamespace(),
            );
            errdefer builder.retirePartial(self.archive.releaseDomain());
            try self.frames.append(scratch, .{ .code = .{
                .source = source,
                .lineage = lineage,
                .output = .{ .building = builder },
            } });
        }

        fn pushDictionary(
            self: *RescopeCursor,
            source: *value.DictHandle,
            rewrite_keys: bool,
            rewrite_vals: bool,
        ) error{OutOfMemory}!void {
            const scratch = self.archive.allocator();
            const entries: usize = @intCast(source.length());
            var keys: ?heap.ListBuilder(.generic_spine) = if (rewrite_keys)
                try .init(scratch, 0, entries)
            else
                null;
            errdefer if (keys) |*builder| builder.retirePartial(self.archive.releaseDomain());
            var vals: ?heap.ListBuilder(.generic_spine) = if (rewrite_vals)
                try .init(scratch, 0, entries)
            else
                null;
            errdefer if (vals) |*builder| builder.retirePartial(self.archive.releaseDomain());
            try self.frames.append(scratch, .{ .dictionary = .{
                .source = source,
                .keys = keys,
                .vals = vals,
            } });
        }
    };

    /// Reader-built lists receive this archive's namespace while still under
    /// their construction capabilities. The opaque assignment issuer never
    /// leaves the archive. Worker callers retain this cursor and advance it in
    /// bounded slices; synchronous host reading belongs to `SpanArchiveOwner`.
    pub fn readCursor(
        self: *const SpanArchive,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
        word_scope: u32,
    ) reader.ReadCursor {
        return .initCode(
            self.allocator(),
            self.releaseDomain(),
            source_name,
            source,
            diag,
            self.provenanceNamespace(),
            word_scope,
        );
    }

    pub fn rootMaterializer(
        self: *const SpanArchive,
        values: []const value.Value,
    ) list.GenericValueMaterializer {
        return .initCode(self.allocator(), values, self.provenanceNamespace());
    }

    /// Moves `parsed`'s provenance and source name into the archive and takes
    /// ownership of `root` at the cursor's explicit adoption transition.
    pub const AbsorbError = error{ OutOfMemory, InvalidProvenance };
    pub const AbsorbProgress = poll.Progress(void);
    pub const AbsorbCursor = struct {
        pub const ArtifactOwnership = enum { caller_owned, archive_owned };
        const Artifacts = union(enum) {
            caller: struct {
                root: value.Value,
                pending_entry: ?*Entry = null,
            },
            archive: *Entry,
        };

        archive: *SpanArchive,
        parsed: *reader.Parsed,
        artifacts: Artifacts,
        writer: reader.SpanTable.PutCursor,
        index_entries: ?reader.SpanTable.EntryList.Iterator = null,
        pending_identity_entry: ?*const reader.SpanTable.Entry = null,
        phase: enum { spans, entry, validate, reserve, adopt, assign, complete } = .spans,

        pub fn init(
            archive: *SpanArchive,
            parsed: *reader.Parsed,
            root: value.Value,
        ) AbsorbCursor {
            std.debug.assert(root == .list);
            return .{
                .archive = archive,
                .parsed = parsed,
                .artifacts = .{ .caller = .{ .root = root } },
                .writer = .init(&parsed.spans, archive.allocator(), root.list, parsed.spans.top),
            };
        }

        /// Ends the cursor and reports the root/provenance ownership state.
        /// Before adoption the caller still owns both inputs; after adoption
        /// the archive keeps their stable storage even if indexing was partial.
        pub fn deinit(self: *AbsorbCursor) ArtifactOwnership {
            if (self.phase == .spans) self.writer.deinit();
            const ownership: ArtifactOwnership = switch (self.artifacts) {
                .caller => |caller| result: {
                    if (caller.pending_entry) |entry| self.archive.allocator().destroy(entry);
                    break :result .caller_owned;
                },
                .archive => .archive_owned,
            };
            self.* = undefined;
            return ownership;
        }

        pub fn advance(self: *AbsorbCursor) AbsorbError!AbsorbProgress {
            return switch (self.phase) {
                .spans => switch (try self.writer.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.writer.deinit();
                        if (self.parsed.spans.top.len != 0)
                            self.archive.allocator().free(self.parsed.spans.top);
                        self.parsed.spans.top = &.{};
                        self.phase = .entry;
                        break :result .pending;
                    },
                },
                .entry => result: {
                    const caller = &self.artifacts.caller;
                    const entry = try self.archive.allocator().create(Entry);
                    entry.* = .{
                        .root = caller.root,
                        .spans = self.parsed.spans,
                        .source_name = self.parsed.source_name,
                        .source = self.parsed.source.?,
                    };
                    caller.pending_entry = entry;
                    self.index_entries = self.parsed.spans.entries.iterator();
                    self.phase = .validate;
                    break :result .pending;
                },
                .validate => result: {
                    const span_entry = self.index_entries.?.next() orelse {
                        self.index_entries = null;
                        self.phase = .reserve;
                        break :result .pending;
                    };
                    if (!self.archive.privateState().validateAbsorptionHeader(span_entry.header))
                        return error.InvalidProvenance;
                    break :result .pending;
                },
                .reserve => result: {
                    // Nothing is reserved ahead any more: each entry that needs
                    // an identity takes exactly one, at the moment it commits.
                    // A range reserved here would be lost to a failure later, to
                    // cancellation, and to every entry that turns out to be
                    // indexed already.
                    self.index_entries = self.parsed.spans.entries.iterator();
                    self.phase = .adopt;
                    break :result .pending;
                },
                .adopt => result: {
                    const entry = self.artifacts.caller.pending_entry.?;
                    self.archive.privateState().publish(entry);
                    self.artifacts = .{ .archive = entry };
                    self.parsed.spans = .init(self.archive.allocator());
                    self.parsed.source_name = &.{};
                    self.parsed.source = null;
                    self.phase = .assign;
                    break :result .pending;
                },
                .assign => result: {
                    if (self.pending_identity_entry == null) {
                        self.pending_identity_entry = self.index_entries.?.next() orelse {
                            self.phase = .complete;
                            break :result .complete;
                        };
                    }
                    const backing = self.archive.privateState();
                    var transaction = (try backing.beginIdentity(self.archive.allocator())) orelse
                        break :result .pending;
                    defer transaction.deinit();
                    // A header this archive already indexes needs no identity,
                    // and the transaction gives the unused one straight back.
                    transaction.publishSpan(
                        self.artifacts.archive,
                        self.pending_identity_entry.?,
                    );
                    self.pending_identity_entry = null;
                    break :result .pending;
                },
                .complete => unreachable,
            };
        }
    };

    pub fn absorbCursor(
        self: *SpanArchive,
        parsed: *reader.Parsed,
        root: value.Value,
    ) AbsorbCursor {
        return .init(self, parsed, root);
    }

    /// The complete bounded source-ingestion pipeline. It borrows the input
    /// bytes for its lifetime and owns every reader, materialization, and
    /// absorption artifact until the archive adopts the finished root. Both
    /// synchronous bootstrap and scheduler drivers advance this same cursor.
    pub const SourceIngestResult = union(enum) {
        complete: *value.ListHandle,
        incomplete: reader.Incomplete,
    };
    pub const SourceIngestProgress = poll.Progress(SourceIngestResult);
    pub const SourceIngestError = error{ OutOfMemory, Parse, InvalidProvenance };
    const SourceIngestBacking = struct {
        const ReadOutcome = union(enum) {
            parsed: reader.Parsed,
            incomplete: reader.Incomplete,
        };
        const Materializing = struct {
            parsed: reader.Parsed,
            materializer: list.GenericValueMaterializer,
        };
        const Absorbing = struct {
            parsed: reader.Parsed,
            root: value.Value,
            absorber: AbsorbCursor,
        };
        const RetirementOutcome = union(enum) {
            publish: *value.ListHandle,
            abandon,
        };
        const ParsedRetirement = union(enum) {
            ready: reader.Parsed,
            active: struct {
                parsed: reader.Parsed,
                cursor: reader.Parsed.RetireCursor,
            },

            fn advance(self: *ParsedRetirement) bool {
                return switch (self.*) {
                    .ready => |parsed| result: {
                        // SAFETY: the cursor is initialized immediately after
                        // its address-stable parsed owner is installed.
                        self.* = .{ .active = .{
                            .parsed = parsed,
                            .cursor = undefined,
                        } };
                        self.active.cursor = .init(&self.active.parsed);
                        break :result false;
                    },
                    .active => |*active| active.cursor.advance(),
                };
            }
        };
        const State = union(enum) {
            reading: *reader.ReadCursor,
            retiring_reader: struct {
                cursor: *reader.ReadCursor,
                outcome: ReadOutcome,
            },
            materializing: Materializing,
            absorbing: Absorbing,
            releasing_root: struct {
                parsed: reader.Parsed,
                root: value.Value,
            },
            retiring_parsed: struct {
                retirement: ParsedRetirement,
                outcome: RetirementOutcome,
            },
            complete: SourceIngestResult,
            retired,
        };

        archive: *SpanArchive,
        state: State,

        pub fn init(
            archive: *SpanArchive,
            source_name: []const u8,
            source: []const u8,
            diag: *reader.Diag,
            word_scope: u32,
        ) error{OutOfMemory}!SourceIngestBacking {
            const cursor = try archive.allocator().create(reader.ReadCursor);
            cursor.* = archive.readCursor(source_name, source, diag, word_scope);
            return .{
                .archive = archive,
                .state = .{ .reading = cursor },
            };
        }

        fn retireParsed(
            self: *SourceIngestBacking,
            parsed: reader.Parsed,
            outcome: RetirementOutcome,
        ) void {
            self.state = .{ .retiring_parsed = .{
                .retirement = .{ .ready = parsed },
                .outcome = outcome,
            } };
        }

        /// Performs one bounded ingestion operation. Completion means the
        /// archive owns the returned root and all temporary parsed ownership
        /// has already entered bounded retirement.
        fn advance(self: *SourceIngestBacking) SourceIngestError!SourceIngestProgress {
            return switch (self.state) {
                .reading => |cursor| switch (try cursor.advance()) {
                    .pending => .pending,
                    .complete => |read_result| result: {
                        self.state = .{ .retiring_reader = .{
                            .cursor = cursor,
                            .outcome = switch (read_result) {
                                .complete => |parsed| .{ .parsed = parsed },
                                .incomplete => |incomplete| .{ .incomplete = incomplete },
                            },
                        } };
                        break :result .pending;
                    },
                },
                .retiring_reader => |*retiring| result: {
                    if (!retiring.cursor.advanceRetirement()) break :result .pending;
                    self.archive.allocator().destroy(retiring.cursor);
                    switch (retiring.outcome) {
                        .parsed => |parsed| self.state = .{ .materializing = .{
                            .materializer = self.archive.rootMaterializer(parsed.values()),
                            .parsed = parsed,
                        } },
                        .incomplete => |incomplete| {
                            const completed: SourceIngestResult = .{ .incomplete = incomplete };
                            self.state = .{ .complete = completed };
                            break :result .{ .complete = completed };
                        },
                    }
                    break :result .pending;
                },
                .materializing => |*materializing| switch (try materializing.materializer.advance(1)) {
                    .pending => .pending,
                    .complete => |root| result: {
                        materializing.materializer.deinit();
                        const parsed = materializing.parsed;
                        // SAFETY: the absorber is initialized immediately
                        // after its address-stable parsed owner is installed.
                        self.state = .{ .absorbing = .{
                            .parsed = parsed,
                            .root = root,
                            .absorber = undefined,
                        } };
                        self.state.absorbing.absorber = self.archive.absorbCursor(
                            &self.state.absorbing.parsed,
                            root,
                        );
                        break :result .pending;
                    },
                },
                .absorbing => |*absorbing| switch (try absorbing.absorber.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        std.debug.assert(absorbing.absorber.deinit() == .archive_owned);
                        const parsed = absorbing.parsed;
                        const root_header = absorbing.root.list;
                        self.retireParsed(parsed, .{ .publish = root_header });
                        break :result .pending;
                    },
                },
                .retiring_parsed => |*retiring| result: {
                    if (!retiring.retirement.advance()) break :result .pending;
                    const root_header = switch (retiring.outcome) {
                        .publish => |header| header,
                        .abandon => unreachable,
                    };
                    const completed: SourceIngestResult = .{ .complete = root_header };
                    self.state = .{ .complete = completed };
                    break :result .{ .complete = completed };
                },
                .releasing_root, .complete, .retired => unreachable,
            };
        }

        /// Bounded abandonment. The absorber is the ownership authority: an
        /// error after adoption clears the local root before any local release,
        /// while an earlier error leaves that release with this cursor.
        fn advanceRetirement(self: *SourceIngestBacking) bool {
            return switch (self.state) {
                .reading => |cursor| result: {
                    if (!cursor.advanceRetirement()) break :result false;
                    self.archive.allocator().destroy(cursor);
                    self.state = .retired;
                    break :result false;
                },
                .retiring_reader => |*retiring| result: {
                    if (!retiring.cursor.advanceRetirement()) break :result false;
                    self.archive.allocator().destroy(retiring.cursor);
                    switch (retiring.outcome) {
                        .parsed => |parsed| self.retireParsed(parsed, .abandon),
                        .incomplete => self.state = .retired,
                    }
                    break :result false;
                },
                .materializing => |*materializing| result: {
                    materializing.materializer.retire(self.archive.releaseDomain());
                    const parsed = materializing.parsed;
                    self.retireParsed(parsed, .abandon);
                    break :result false;
                },
                .absorbing => |*absorbing| result: {
                    const ownership = absorbing.absorber.deinit();
                    const parsed = absorbing.parsed;
                    const root = absorbing.root;
                    switch (ownership) {
                        .caller_owned => self.state = .{ .releasing_root = .{
                            .parsed = parsed,
                            .root = root,
                        } },
                        .archive_owned => self.retireParsed(parsed, .abandon),
                    }
                    break :result false;
                },
                .releasing_root => |releasing| result: {
                    self.archive.releaseDomain().releaseValue(releasing.root);
                    self.retireParsed(releasing.parsed, .abandon);
                    break :result false;
                },
                .retiring_parsed => |*retiring| result: {
                    if (!retiring.retirement.advance()) break :result false;
                    self.state = .retired;
                    break :result false;
                },
                .complete => result: {
                    self.state = .retired;
                    break :result false;
                },
                .retired => true,
            };
        }
    };

    /// Movable ownership handle for heap-stable ingestion state. `take` is the
    /// only relocation operation: it consumes the old handle so cursor backing
    /// still has one destroyer while internal cursors safely borrow it.
    pub const SourceIngestCursor = enum(usize) {
        consumed = 0,
        _,

        fn fromBacking(owned: *SourceIngestBacking) SourceIngestCursor {
            return @enumFromInt(@intFromPtr(owned));
        }
        fn backing(self: *const SourceIngestCursor) *SourceIngestBacking {
            std.debug.assert(self.* != .consumed);
            return @ptrFromInt(@intFromEnum(self.*));
        }
        pub fn take(self: *SourceIngestCursor) SourceIngestCursor {
            const moved = self.*;
            std.debug.assert(moved != .consumed);
            self.* = .consumed;
            return moved;
        }
        pub fn advance(self: *SourceIngestCursor) SourceIngestError!SourceIngestProgress {
            const state = self.backing();
            const progress = try state.advance();
            if (progress == .complete) {
                const storage_allocator = state.archive.allocator();
                storage_allocator.destroy(state);
                self.* = .consumed;
            }
            return progress;
        }
        pub fn advanceRetirement(self: *SourceIngestCursor) bool {
            if (self.* == .consumed) return true;
            const state = self.backing();
            if (!state.advanceRetirement()) return false;
            const storage_allocator = state.archive.allocator();
            storage_allocator.destroy(state);
            self.* = .consumed;
            return true;
        }
    };

    pub fn sourceIngestCursor(
        self: *SpanArchive,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
        word_scope: u32,
    ) error{OutOfMemory}!SourceIngestCursor {
        const backing = try self.allocator().create(SourceIngestBacking);
        errdefer self.allocator().destroy(backing);
        backing.* = try .init(self, source_name, source, diag, word_scope);
        return .fromBacking(backing);
    }

    pub fn locate(
        self: *const SpanArchive,
        header: *value.ListHandle,
        index: usize,
    ) ?LocatedSpan {
        var cursor = self.locateCursor(header, index);
        return poll.drive(?LocatedSpan, &cursor, .{});
    }

    pub const LocateProgress = poll.Progress(?LocatedSpan);
    pub const LocateCursor = struct {
        result: ?LocatedSpan,

        pub fn advance(self: *LocateCursor) LocateProgress {
            return .{ .complete = self.result };
        }
    };

    pub fn locateCursor(
        self: *const SpanArchive,
        header: *value.ListHandle,
        index: usize,
    ) LocateCursor {
        const indexed = self.privateState().indexed(header) orelse return .{ .result = null };
        if (index >= indexed.token_entry.spans.len) return .{ .result = null };
        return .{ .result = .{
            .source_name = indexed.archive_entry.source_name,
            .span = indexed.token_entry.spans[index],
        } };
    }

    pub fn locateQuotationCursor(
        self: *const SpanArchive,
        header: *value.ListHandle,
    ) LocateCursor {
        const indexed = self.privateState().indexed(header) orelse return .{ .result = null };
        const span_entry = indexed.container_entry orelse return .{ .result = null };
        const span = span_entry.container_span.?;
        return .{ .result = .{
            .source_name = indexed.archive_entry.source_name,
            .span = span,
        } };
    }

    pub const SourceProgress = poll.Progress(?reader.SourceSlice);
    pub const SourceCursor = struct {
        source: ?reader.SourceSlice,

        pub fn advance(self: *SourceCursor) SourceProgress {
            const source = self.source orelse return .{ .complete = null };
            source.retain();
            self.source = null;
            return .{ .complete = source };
        }
    };

    pub fn sourceCursor(self: *const SpanArchive, header: *value.ListHandle) SourceCursor {
        const indexed = self.privateState().indexed(header) orelse return .{ .source = null };
        const span_entry = indexed.source_entry orelse return .{ .source = null };
        const range = span_entry.source_range.?;
        return .{ .source = indexed.archive_entry.source.slice(range.start, range.end) };
    }
};

/// Charges one unit for a transition the enclosing loop has already confirmed
/// the budget can pay for. Separate from the assert so the charge is never a
/// side effect inside one.
fn charge(work: *poll.WorkBudget) void {
    const paid = work.spend();
    std.debug.assert(paid);
}

/// Writes one element into a builder whose length is its initialized prefix,
/// so the builder's own retirement releases exactly what was written.
fn appendOwned(builder: *heap.ListBuilder(.generic_spine), item: value.Value) void {
    const written = builder.len();
    std.debug.assert(written < builder.capacity());
    builder.items()[written] = item;
    builder.setLen(written + 1);
}

comptime {
    heap.requireOpaqueHostOwnerRoot(SpanArchiveOwner, SpanArchiveOwnerState);
    heap.requireOpaqueWorkerFacade(SpanArchive, SpanArchiveState);
}

/// One archive with its own reclamation root, so a test can hold two at once
/// and ask each view about the other's headers. The owner stays address-stable
/// for the complete lifetime of the view it issued.
const ArchiveFixture = struct {
    owner: heap.HostOwner,
    archive_owner: SpanArchiveOwner,
    archive: SpanArchive,

    fn init(self: *ArchiveFixture, allocator: std.mem.Allocator) !void {
        self.* = .{
            .owner = .init(allocator),
            .archive_owner = .consumed,
            .archive = .invalid,
        };
        self.archive_owner = try SpanArchiveOwner.init(&self.owner);
        self.archive = self.archive_owner.view();
    }

    fn deinit(self: *ArchiveFixture) void {
        self.archive_owner.deinit();
        self.owner.cleanup().drain();
    }

    /// Reads one source and absorbs it, returning the archive-owned root.
    fn absorbSource(self: *ArchiveFixture, source: []const u8) !*value.ListHandle {
        var diag: reader.Diag = .{};
        var ingestion = try self.archive.sourceIngestCursor(
            "spans-test.ecl",
            source,
            &diag,
            0,
        );
        defer {
            while (!ingestion.advanceRetirement())
                _ = self.owner.domain().advance(256);
        }
        while (true) switch (try ingestion.advance()) {
            .pending => _ = self.owner.domain().advance(256),
            .complete => |result| return switch (result) {
                .complete => |header| header,
                .incomplete => error.UnexpectedIncomplete,
            },
        };
    }

    /// A code value in this archive's construction namespace that the reader
    /// never produced, which is what every generic reconstruction is.
    fn rebuilt(self: *ArchiveFixture) !heap.OwnedValue {
        var materializer = self.archive.rootMaterializer(&.{.{ .int = 1 }});
        const root = try poll.driveFallible(value.Value, &materializer, .{1});
        materializer.deinit();
        return .init(heap.hostDomain(self.owner.cleanup()), root);
    }
};

fn drive(fixture: *ArchiveFixture, cursor: *SpanArchive.RescopeCursor) !*value.ListHandle {
    _ = fixture;
    while (true) {
        var work: poll.WorkBudget = .init(4);
        switch (try cursor.advance(&work)) {
            .pending => {},
            .complete => |header| return header,
        }
    }
}

fn prepareForTest(
    fixture: *ArchiveFixture,
    header: *value.ListHandle,
) !SpanArchive.PreparedConstructionBody {
    heap.incRef(header);
    var body = heap.Owned(*value.ListHandle).init(header);
    errdefer body.deinit(heap.hostDomain(fixture.owner.cleanup()), fixture.archive.allocator());
    return fixture.archive.prepareConstructionBody(&body);
}

fn admittedForTest(
    fixture: *ArchiveFixture,
    header: *value.ListHandle,
    scope: u32,
) !SpanArchive.RescopeCursor {
    const prepared = try prepareForTest(fixture, header);
    return switch (prepared) {
        .admitted => |admitted| admitted.begin(scope),
        .unchanged => |owned| {
            var body = owned;
            body.deinit(heap.hostDomain(fixture.owner.cleanup()), fixture.archive.allocator());
            return error.ExpectedAdmission;
        },
    };
}

fn sourceIngestAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    var archive_owner = try SpanArchiveOwner.init(&host);
    defer archive_owner.deinit();
    var archive = archive_owner.view();
    var diag: reader.Diag = .{};
    var ingestion = try archive.sourceIngestCursor(
        "spans-ingest-oom.ecl",
        "(1) 'one def",
        &diag,
        0,
    );
    defer {
        while (!ingestion.advanceRetirement())
            _ = host.domain().advance(256);
    }
    while (true) switch (try ingestion.advance()) {
        .pending => _ = host.domain().advance(256),
        .complete => |result| switch (result) {
            .complete => return,
            .incomplete => return error.UnexpectedIncomplete,
        },
    };
}

test "spans: source ingestion propagates every allocation failure across adoption" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        sourceIngestAllocationProbe,
        .{},
    );
}

test "spans: public source ingestion handle relocates between advances" {
    var fixture: ArchiveFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var diag: reader.Diag = .{};
    var ingestion = try fixture.archive.sourceIngestCursor(
        "spans-relocated-ingest.ecl",
        "(1) 'one def",
        &diag,
        0,
    );
    var live = true;
    defer {
        if (live) while (true) {
            ingestion = ingestion.take();
            if (ingestion.advanceRetirement()) break;
            _ = fixture.owner.domain().advance(256);
        };
    }

    var advances: usize = 0;
    const root = while (true) : (advances += 1) {
        ingestion = ingestion.take();
        switch (try ingestion.advance()) {
            .pending => _ = fixture.owner.domain().advance(256),
            .complete => |result| switch (result) {
                .complete => |header| break header,
                .incomplete => return error.UnexpectedIncomplete,
            },
        }
    };
    live = false;

    var abandoned = try fixture.archive.sourceIngestCursor(
        "spans-relocated-abandon.ecl",
        "(2) 'two def",
        &diag,
        0,
    );
    var abandoned_live = true;
    defer {
        if (abandoned_live) while (true) {
            abandoned = abandoned.take();
            if (abandoned.advanceRetirement()) break;
            _ = fixture.owner.domain().advance(256);
        };
    }
    abandoned = abandoned.take();
    try std.testing.expect((try abandoned.advance()) == .pending);
    while (true) {
        abandoned = abandoned.take();
        if (abandoned.advanceRetirement()) break;
        _ = fixture.owner.domain().advance(256);
    }
    abandoned_live = false;
    try std.testing.expect(advances != 0);
    const prepared = try prepareForTest(&fixture, root);
    try std.testing.expect(prepared == .admitted);
    prepared.admitted.deinit();
}

test "spans: only the reader's own text is admitted" {
    var fixture: ArchiveFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    const root = try fixture.absorbSource("(1 +) 'go def");
    {
        const prepared = try prepareForTest(&fixture, root);
        try std.testing.expect(prepared == .admitted);
        prepared.admitted.deinit();
    }

    // A code value in this archive's own construction namespace that the reader
    // never produced is what every generic reconstruction is.
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    heap.incRef(rebuilt.borrow().list);
    var rebuilt_body = heap.Owned(*value.ListHandle).init(rebuilt.borrow().list);
    var rejected = try fixture.archive.prepareConstructionBody(&rebuilt_body);
    try std.testing.expect(rejected == .unchanged);
    rejected.unchanged.deinit(
        heap.hostDomain(fixture.owner.cleanup()),
        fixture.archive.allocator(),
    );
}

test "spans: one archive never admits another archive's text" {
    var reading: ArchiveFixture = undefined;
    try reading.init(std.testing.allocator);
    defer reading.deinit();
    var other: ArchiveFixture = undefined;
    try other.init(std.testing.allocator);
    defer other.deinit();

    const root = try reading.absorbSource("(1 +) 'go def");
    {
        const prepared = try prepareForTest(&reading, root);
        try std.testing.expect(prepared == .admitted);
        prepared.admitted.deinit();
    }
    // The decisive case: the *other* archive is asked to prepare the exact
    // header this one read. There is no proof to carry across, so admission is
    // its own and it declines. A foreign construction namespace yields no
    // identity, and an identity alone never grants membership, because the
    // directory is keyed by exact header.
    const foreign = try prepareForTest(&other, root);
    try std.testing.expect(foreign == .unchanged);
    var unchanged = foreign.unchanged;
    unchanged.deinit(heap.hostDomain(reading.owner.cleanup()), reading.archive.allocator());
}

test "spans: re-scoping produces the only header that inherits reader lineage" {
    var fixture: ArchiveFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const releases = heap.hostDomain(fixture.owner.cleanup());

    const root = try fixture.absorbSource("(1 +) 'go def");
    var cursor = heap.Owned(SpanArchive.RescopeCursor).init(
        try admittedForTest(&fixture, root, 7),
    );
    defer cursor.deinit(releases, fixture.archive.allocator());
    const copy = try drive(&fixture, cursor.borrowMut());
    cursor.deinit(releases, fixture.archive.allocator());
    defer releases.releaseHeader(copy);

    // A distinct header, and the lineage came with it: a later constructor may
    // re-stamp this exact copy to its own image, which is what a construction
    // nested inside an already-re-scoped body depends on.
    try std.testing.expect(copy != root);
    {
        const again = try prepareForTest(&fixture, copy);
        try std.testing.expect(again == .admitted);
        again.admitted.deinit();
    }
    // The source is untouched and still admissible.
    {
        const again = try prepareForTest(&fixture, root);
        try std.testing.expect(again == .admitted);
        again.admitted.deinit();
    }
    try std.testing.expectEqual(root.length(), copy.length());

    // Every word occurrence in the copy names the requested scope, and the
    // source's do not.
    var words: usize = 0;
    for (0..@as(usize, @intCast(copy.length()))) |index| {
        const item = list.atUnchecked(.{ .list = copy }, index);
        if (item != .word) continue;
        words += 1;
        try std.testing.expectEqual(@as(u32, 7), item.word.scope);
        try std.testing.expectEqual(
            @as(u32, 0),
            list.atUnchecked(.{ .list = root }, index).word.scope,
        );
    }
    try std.testing.expect(words != 0);
}

test "spans: every re-scope step is one budget unit, publication included" {
    var fixture: ArchiveFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const releases = heap.hostDomain(fixture.owner.cleanup());

    // A dict with more than `index_threshold` entries, so the copy also has an
    // index to carry: the whole point is that no single step finalizes it.
    const root = try fixture.absorbSource(
        "{'a (dup) 'b (dup) 'c (dup) 'd (dup) 'e (dup) 'f (dup) 'g (dup) 'h (dup) " ++
            "'i (dup) 'j (dup) 'k (dup) 'l (dup) 'm (dup) 'n (dup) 'o (dup) 'p (dup) " ++
            "'q (dup) 'r (dup)} 'd def",
    );
    var cursor = heap.Owned(SpanArchive.RescopeCursor).init(
        try admittedForTest(&fixture, root, 3),
    );
    defer cursor.deinit(releases, fixture.archive.allocator());

    // One unit per advance. Every transition — an element, an index slice, a
    // container's publication — costs exactly one, so the number of advances is
    // the total work and no advance hides a bulk pass.
    var steps: usize = 0;
    const copy = while (true) : (steps += 1) {
        var work: poll.WorkBudget = .init(1);
        switch (try cursor.borrowMut().advance(&work)) {
            .pending => {},
            .complete => |header| break header,
        }
    };
    cursor.deinit(releases, fixture.archive.allocator());
    defer releases.releaseHeader(copy);
    // Two top-level elements, the dict's 36 key/value positions, its index
    // slices, and one publication per container: many steps, none of them the
    // whole job.
    try std.testing.expect(steps > 36);
}

test "spans: settled lineage storage tracks only live copies" {
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    {
        var fixture: ArchiveFixture = undefined;
        try fixture.init(counting.allocator());
        defer fixture.deinit();
        const releases = heap.hostDomain(fixture.owner.cleanup());
        const root = try fixture.absorbSource("(1 +) 'go def (2 +) 'go2 def");

        // Each round re-scopes the same body and immediately drops the copy, so
        // no copy is ever live at the same time as another. Warm past the first
        // directory page, then do sixteen times as many rounds: identities are
        // recycled when their header retires, so the second batch must not add
        // a directory page per 256 rounds the way a history-proportional
        // directory would.
        for (0..64) |_| {
            var cursor = try admittedForTest(&fixture, root, 5);
            releases.releaseHeader(try drive(&fixture, &cursor));
            cursor.deinit();
            // Recycling happens at destruction, and destruction is deferred
            // retirement work: settling it is what makes the identity free.
            fixture.owner.cleanup().drain();
        }
        const warmed = counting.total_requested_bytes;
        for (0..1024) |_| {
            var cursor = try admittedForTest(&fixture, root, 5);
            releases.releaseHeader(try drive(&fixture, &cursor));
            cursor.deinit();
            fixture.owner.cleanup().drain();
        }
        try std.testing.expect(counting.total_requested_bytes <= warmed + 4096);
    }
    try std.testing.expectEqual(.ok, counting.deinit());
}

test "spans: one reclamation root has one code provenance owner" {
    var owner: heap.HostOwner = .init(std.testing.allocator);
    defer owner.cleanup().drain();
    var first = try SpanArchiveOwner.init(&owner);
    // A second archive on the same root is refused rather than replacing the
    // first's retirement hook, in every build mode.
    try std.testing.expectError(
        error.CodeProvenanceTaken,
        SpanArchiveOwner.init(&owner),
    );
    first.deinit();
    // And once the first releases its receipt the root is free again.
    var second = try SpanArchiveOwner.init(&owner);

    // A receipt names one issuance independently of owner addresses: replaying the first
    // archive's receipt cannot detach the second's registration, so the
    // surviving archive keeps recycling its slots.
    var stale: heap.HostOwner.CodeRetirementRegistration = @enumFromInt(1);
    owner.detachCodeRetirement(&stale);
    try std.testing.expectError(
        error.CodeProvenanceTaken,
        SpanArchiveOwner.init(&owner),
    );
    second.deinit();
}

test "spans: an abandoned re-scope releases its partial copy" {
    var fixture: ArchiveFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    const root = try fixture.absorbSource(
        "(1 (2 (3 dup) dup) dup) 'go def {'a (k) 'b (j)} 'd def",
    );

    // One unit of work, then abandon: the frames hold rewritten values, freshly
    // built nested headers, and a partly copied index, and every one of them
    // goes back. The test allocator reports a leak if any does not.
    for (1..24) |steps| {
        var cursor = try admittedForTest(&fixture, root, 9);
        for (0..steps) |_| {
            var work: poll.WorkBudget = .init(1);
            if (try cursor.advance(&work) == .complete) unreachable;
        }
        cursor.deinit();
    }
}
