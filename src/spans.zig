//! Session-lifetime ownership for reader provenance tables.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");
const poll = @import("poll.zig");
pub const LocatedSpan = struct {
    source_name: []const u8,
    span: lexer.Span,
};
const Entry = struct {
    root: value.Value,
    spans: reader.SpanTable,
    source_name: []u8,
    fn deinit(
        self: *Entry,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
    ) void {
        var spans_cursor = reader.SpanTable.RetireCursor.init(&self.spans);
        while (spans_cursor.advance(releases) == .pending) {}
        releases.releaseValue(self.root);
        allocator.free(self.source_name);
        self.* = undefined;
    }
};
/// Span tables retain their source code roots. Besides keeping definitions'
/// provenance alive, this prevents a freed header address from being reused
/// while a stale identity key remains in the archive.
const SpanArchiveState = struct {
    host: *const heap.HostCleanup,
    mutex: std.Io.Mutex = .init,
    entries: poll.ChunkList(Entry),
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
        backing.* = .{
            .host = host,
            .entries = .init(owner_allocator),
        };
        return @enumFromInt(@intFromPtr(backing));
    }

    fn allocator(self: *const SpanArchive) std.mem.Allocator {
        return self.privateState().host.allocator();
    }

    fn releaseDomain(self: *const SpanArchive) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }
    pub fn deinit(self: *SpanArchive) void {
        const backing = self.privateState();
        const owner_allocator = backing.host.allocator();
        std.Io.Threaded.mutexLock(&backing.mutex);
        var entries = backing.entries.iterator();
        while (entries.next()) |entry| @constCast(entry).deinit(self.allocator(), self.releaseDomain());
        backing.entries.retire(self.releaseDomain());
        std.Io.Threaded.mutexUnlock(&backing.mutex);
        backing.host.drain();
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }
    /// Moves `parsed`'s provenance and source name into the archive and takes
    /// ownership of `root`. The caller still owns both on allocation failure.
    pub fn absorb(
        self: *SpanArchive,
        parsed: *reader.Parsed,
        root: value.Value,
    ) error{OutOfMemory}!void {
        var cursor = self.absorbCursor(parsed, root);
        defer cursor.deinit();
        while (try cursor.advance() == .pending) {}
    }
    pub const AbsorbProgress = enum { pending, complete };
    pub const AbsorbCursor = struct {
        archive: *SpanArchive,
        parsed: *reader.Parsed,
        root: value.Value,
        writer: reader.SpanTable.PutCursor,
        phase: enum { spans, publish, complete } = .spans,

        pub fn init(archive: *SpanArchive, parsed: *reader.Parsed, root: value.Value) AbsorbCursor {
            std.debug.assert(root == .list);
            return .{
                .archive = archive,
                .parsed = parsed,
                .root = root,
                .writer = .init(&parsed.spans, archive.allocator(), root.list, parsed.spans.top),
            };
        }
        pub fn deinit(self: *AbsorbCursor) void {
            if (self.phase == .spans) self.writer.deinit();
            self.* = undefined;
        }
        pub fn advance(self: *AbsorbCursor) error{OutOfMemory}!AbsorbProgress {
            return switch (self.phase) {
                .spans => switch (try self.writer.advance()) {
                    .pending => .pending,
                    .complete => result: {
                        self.writer.deinit();
                        if (self.parsed.spans.top.len != 0)
                            self.archive.allocator().free(self.parsed.spans.top);
                        self.parsed.spans.top = &.{};
                        self.phase = .publish;
                        break :result .pending;
                    },
                },
                .publish => result: {
                    const backing = self.archive.privateState();
                    std.Io.Threaded.mutexLock(&backing.mutex);
                    defer std.Io.Threaded.mutexUnlock(&backing.mutex);
                    try backing.entries.append(.{
                        .root = self.root,
                        .spans = self.parsed.spans,
                        .source_name = self.parsed.source_name,
                    });
                    self.parsed.spans = .init(self.archive.allocator());
                    self.parsed.source_name = &.{};
                    self.phase = .complete;
                    break :result .complete;
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
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |found| return found,
        };
    }
    pub const LocateProgress = union(enum) { pending, complete: ?LocatedSpan };
    pub const LocateCursor = struct {
        entries: poll.ChunkList(Entry).ReverseIterator,
        header: *value.ListHandle,
        index: usize,
        active: ?struct {
            entry: *const Entry,
            lookup: reader.SpanTable.LookupCursor,
        } = null,

        pub fn advance(self: *LocateCursor) LocateProgress {
            if (self.active) |*active| return switch (active.lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_spans| result: {
                    if (maybe_spans) |found| {
                        if (self.index >= found.len) return .{ .complete = null };
                        return .{ .complete = .{
                            .source_name = active.entry.source_name,
                            .span = found[self.index],
                        } };
                    }
                    self.active = null;
                    break :result .pending;
                },
            };
            const entry = self.entries.next() orelse return .{ .complete = null };
            if (entry.spans.lookupCursor(@constCast(self.header))) |lookup|
                self.active = .{ .entry = entry, .lookup = lookup };
            return .pending;
        }
    };
    pub fn locateCursor(
        self: *const SpanArchive,
        header: *value.ListHandle,
        index: usize,
    ) LocateCursor {
        const backing = self.privateState();
        std.Io.Threaded.mutexLock(&backing.mutex);
        defer std.Io.Threaded.mutexUnlock(&backing.mutex);
        return .{ .entries = backing.entries.reverseIterator(), .header = header, .index = index };
    }
};
comptime {
    heap.requireOpaqueHostRoot(SpanArchive, SpanArchiveState);
}
test "span archive owns roots and moved provenance" {
    const allocator = std.testing.allocator;
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    var diag: lexer.Diag = .{};
    const result = try reader.read(host.cleanup(), "fixture.ecl", "(1 missing)", &diag);
    var parsed = result.complete;
    const nested = parsed.values()[0].list;
    const root = try list.fromValuesGeneric(allocator, parsed.values());
    const root_header = root.list;
    var archive = try SpanArchive.init(host.cleanup());
    defer archive.deinit();
    try archive.absorb(parsed.borrow(), root);
    parsed.deinit();
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 1 }, archive.locate(root_header, 0).?.span);
    const location = archive.locate(nested, 1).?;
    try std.testing.expectEqualStrings("fixture.ecl", location.source_name);
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 4 }, location.span);
}
