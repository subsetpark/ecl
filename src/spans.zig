//! Session-lifetime ownership and direct lookup for reader provenance tables.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");
const poll = @import("poll.zig");
const storage = @import("kernel_storage.zig");

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
    };
    const Branch = struct { leaves: [radix]?*Leaf = @splat(null) };

    branches: [radix]?*Branch = @splat(null),
    next_identity: u32 = 1,

    fn coordinates(identity: heap.CodeIdentity) struct { usize, usize, usize } {
        const raw = @intFromEnum(identity);
        std.debug.assert(raw != 0 and raw <= heap.max_code_identity);
        return .{
            @intCast((raw >> 16) & 0xff),
            @intCast((raw >> 8) & 0xff),
            @intCast(raw & 0xff),
        };
    }

    fn reserve(self: *HeaderIndex, count: usize) error{OutOfMemory}!u32 {
        const end = @as(u64, self.next_identity) + count;
        if (end > @as(u64, heap.max_code_identity) + 1) return error.OutOfMemory;
        const first = self.next_identity;
        self.next_identity = @intCast(end);
        return first;
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
const SpanArchiveState = struct {
    host: *const heap.HostCleanup,
    identity_issuer: *heap.CodeIdentityIssuer,
    mutex: std.Io.Mutex = .init,
    first: ?*Entry = null,
    last: ?*Entry = null,
    index: HeaderIndex = .{},

    fn reserveIdentities(self: *SpanArchiveState, count: usize) error{OutOfMemory}!u32 {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.index.reserve(count);
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
    ) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (heap.assignCodeIdentity(self.identity_issuer, rewritten, identity) != .assigned) return;
        self.index.set(identity, rewritten, existing);
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

pub const SpanArchive = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const SpanArchive) *SpanArchiveState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    pub fn init(host: *const heap.HostCleanup) error{OutOfMemory}!SpanArchive {
        const owner_allocator = host.allocator();
        const backing = try owner_allocator.create(SpanArchiveState);
        errdefer owner_allocator.destroy(backing);
        backing.* = .{
            .host = host,
            .identity_issuer = try .init(owner_allocator),
        };
        return @enumFromInt(@intFromPtr(backing));
    }

    fn allocator(self: *const SpanArchive) std.mem.Allocator {
        return self.privateState().host.allocator();
    }

    fn releaseDomain(self: *const SpanArchive) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    /// The construction namespace a rewritten code value must be built in so
    /// it stays archive-bound: a stamped construction body is still this
    /// archive's code, just re-scoped.
    pub fn provenanceNamespaceOf(self: *const SpanArchive) heap.CodeProvenanceNamespace {
        return self.privateState().identity_issuer.constructionNamespace();
    }

    fn provenanceNamespace(self: *const SpanArchive) heap.CodeProvenanceNamespace {
        return self.privateState().identity_issuer.constructionNamespace();
    }

    /// Carries `original`'s source spans onto `rewritten`, a code value rebuilt
    /// from it. Rewriting a body — which is how `@module` and `@defm` re-scope
    /// a construction body's words — produces a new header, and the index is
    /// keyed by header, so without this an error raised inside a module body
    /// would report no source at all. A value with no spans to carry is a
    /// no-op rather than an error.
    pub fn aliasSpans(
        self: *SpanArchive,
        original: *value.ListHandle,
        rewritten: *value.ListHandle,
    ) error{OutOfMemory}!void {
        const backing = self.privateState();
        const existing = backing.indexed(original) orelse return;
        const raw = try backing.reserveIdentities(1);
        const identity: heap.CodeIdentity = @enumFromInt(raw);
        try backing.ensureIndexSlot(self.allocator(), identity);
        backing.aliasIndexed(identity, rewritten, existing);
    }

    /// The stable identity this archive assigned to one reader-built code
    /// value, or null for a value built at run time or read elsewhere. The
    /// opaque issuer never leaves the archive; only the identity does, so a
    /// sibling consumer can key its own table on it.
    pub fn identityOf(
        self: *const SpanArchive,
        header: *value.ListHandle,
    ) ?heap.CodeIdentity {
        return heap.codeIdentity(self.privateState().identity_issuer, header);
    }

    /// Reader-built lists receive this archive's namespace while still under
    /// their construction capabilities. The opaque assignment issuer never
    /// leaves the archive.
    pub fn read(
        self: *const SpanArchive,
        source_name: []const u8,
        source: []const u8,
        diag: *reader.Diag,
        word_scope: u32,
    ) reader.Error!reader.ReadResult {
        const backing = self.privateState();
        return reader.readCode(
            backing.host,
            source_name,
            source,
            diag,
            backing.identity_issuer.constructionNamespace(),
            word_scope,
        );
    }

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

    pub fn codeRoot(
        self: *const SpanArchive,
        values: []const value.Value,
    ) error{OutOfMemory}!value.Value {
        return list.fromValuesGenericCode(self.allocator(), values, self.provenanceNamespace());
    }

    pub fn rootMaterializer(
        self: *const SpanArchive,
        values: []const value.Value,
    ) storage.GenericValueMaterializer {
        return .initCode(self.allocator(), values, self.provenanceNamespace());
    }

    pub fn deinit(self: *SpanArchive) void {
        const backing = self.privateState();
        const owner_allocator = backing.host.allocator();
        std.Io.Threaded.mutexLock(&backing.mutex);
        var current = backing.first;
        backing.first = null;
        backing.last = null;
        var index = backing.index;
        backing.index = .{};
        std.Io.Threaded.mutexUnlock(&backing.mutex);
        while (current) |entry| {
            current = entry.next;
            entry.deinit(owner_allocator, self.releaseDomain());
            owner_allocator.destroy(entry);
        }
        index.deinit(owner_allocator);
        backing.host.drain();
        backing.identity_issuer.deinit();
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }

    /// Moves `parsed`'s provenance and source name into the archive and takes
    /// ownership of `root`. The caller still owns both on every failure.
    pub const AbsorbError = error{ OutOfMemory, InvalidProvenance };
    pub fn absorb(
        self: *SpanArchive,
        parsed: *reader.Parsed,
        root: value.Value,
    ) AbsorbError!void {
        var cursor = self.absorbCursor(parsed, root);
        while (cursor.advance() catch |err| {
            std.debug.assert(cursor.deinit() == .caller_owned);
            return err;
        } == .pending) {}
        std.debug.assert(cursor.deinit() == .archive_owned);
    }

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
        next_identity: u32 = 0,
        phase: enum { spans, entry, validate, reserve, index, adopt, assign, complete } = .spans,

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
                    const backing = self.archive.privateState();
                    self.next_identity = try backing.reserveIdentities(self.parsed.spans.entries.count);
                    self.index_entries = self.parsed.spans.entries.iterator();
                    self.phase = .index;
                    break :result .pending;
                },
                .index => result: {
                    const span_entry = self.index_entries.?.next() orelse {
                        self.index_entries = self.parsed.spans.entries.iterator();
                        self.next_identity -= @intCast(self.parsed.spans.entries.count);
                        self.phase = .adopt;
                        break :result .pending;
                    };
                    _ = span_entry;
                    const identity: heap.CodeIdentity = @enumFromInt(self.next_identity);
                    try self.archive.privateState().ensureIndexSlot(self.archive.allocator(), identity);
                    self.next_identity += 1;
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
                    const span_entry = self.index_entries.?.next() orelse {
                        self.phase = .complete;
                        break :result .complete;
                    };
                    const backing = self.archive.privateState();
                    const identity: heap.CodeIdentity = @enumFromInt(self.next_identity);
                    if (backing.commitSpan(
                        identity,
                        self.artifacts.archive,
                        span_entry,
                    )) self.next_identity += 1;
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

comptime {
    heap.requireOpaqueHostRoot(SpanArchive, SpanArchiveState);
}
