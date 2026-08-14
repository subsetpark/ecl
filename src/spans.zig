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
    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.spans.deinit(allocator);
        heap.releaseValue(allocator, self.root);
        allocator.free(self.source_name);
        self.* = undefined;
    }
};
/// Span tables retain their source code roots. Besides keeping definitions'
/// provenance alive, this prevents a freed header address from being reused
/// while a stale identity key remains in the archive.
pub const SpanArchive = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: poll.ChunkList(Entry),
    pub fn init(allocator: std.mem.Allocator) SpanArchive {
        return .{ .allocator = allocator, .entries = .init(allocator) };
    }
    pub fn deinit(self: *SpanArchive) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        var entries = self.entries.iterator();
        while (entries.next()) |entry| @constCast(entry).deinit(self.allocator);
        self.entries.deinit();
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.* = undefined;
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
                .writer = .init(&parsed.spans, archive.allocator, root.list, parsed.spans.top),
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
                            self.archive.allocator.free(self.parsed.spans.top);
                        self.parsed.spans.top = &.{};
                        self.phase = .publish;
                        break :result .pending;
                    },
                },
                .publish => result: {
                    std.Io.Threaded.mutexLock(&self.archive.mutex);
                    defer std.Io.Threaded.mutexUnlock(&self.archive.mutex);
                    try self.archive.entries.append(.{
                        .root = self.root,
                        .spans = self.parsed.spans,
                        .source_name = self.parsed.source_name,
                    });
                    self.parsed.spans = .init(self.archive.allocator);
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
        header: *const value.Header,
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
        header: *const value.Header,
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
        header: *const value.Header,
        index: usize,
    ) LocateCursor {
        std.Io.Threaded.mutexLock(&@constCast(self).mutex);
        defer std.Io.Threaded.mutexUnlock(&@constCast(self).mutex);
        return .{ .entries = self.entries.reverseIterator(), .header = header, .index = index };
    }
};
test "span archive owns roots and moved provenance" {
    const allocator = std.testing.allocator;
    var diag: lexer.Diag = .{};
    const result = try reader.read(allocator, "fixture.ecl", "(1 missing)", &diag);
    var parsed = result.complete;
    const nested = parsed.forms[0].list;
    const root = try list.fromValuesGeneric(allocator, parsed.forms);
    const root_header = root.list;
    var archive = SpanArchive.init(allocator);
    defer archive.deinit();
    try archive.absorb(&parsed, root);
    parsed.deinit();
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 1 }, archive.locate(root_header, 0).?.span);
    const location = archive.locate(nested, 1).?;
    try std.testing.expectEqualStrings("fixture.ecl", location.source_name);
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 4 }, location.span);
}
