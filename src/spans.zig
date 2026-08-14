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
    entries: poll.ChunkList(Entry),
    pub fn init(allocator: std.mem.Allocator) SpanArchive {
        return .{ .allocator = allocator, .entries = .init(allocator) };
    }
    pub fn deinit(self: *SpanArchive) void {
        var entries = self.entries.iterator();
        while (entries.next()) |entry| @constCast(entry).deinit(self.allocator);
        self.entries.deinit();
        self.* = undefined;
    }
    /// Moves `parsed`'s provenance and source name into the archive and takes
    /// ownership of `root`. The caller still owns both on allocation failure.
    pub fn absorb(
        self: *SpanArchive,
        parsed: *reader.Parsed,
        root: value.Value,
        work: poll.WorkContext,
    ) poll.Error!void {
        std.debug.assert(root == .list);
        const top = parsed.spans.top;
        try parsed.spans.putOwned(root.list, top, work);
        parsed.spans.top = &.{};
        try self.entries.append(.{
            .root = root,
            .spans = parsed.spans,
            .source_name = parsed.source_name,
        });
        parsed.spans = .init(self.allocator);
        parsed.source_name = &.{};
    }
    pub fn locate(
        self: *const SpanArchive,
        header: *const value.Header,
        index: usize,
    ) ?LocatedSpan {
        return self.locateWork(header, index, .unlimited()) catch unreachable;
    }
    pub fn locateWork(
        self: *const SpanArchive,
        header: *const value.Header,
        index: usize,
        work: poll.WorkContext,
    ) poll.Error!?LocatedSpan {
        var entries = self.entries.reverseWorkIterator(work);
        while (try entries.next()) |entry| {
            const found = try entry.spans.forList(@constCast(header), work) orelse continue;
            if (index >= found.len) return null;
            return .{ .source_name = entry.source_name, .span = found[index] };
        }
        return null;
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
    try archive.absorb(&parsed, root, .unlimited());
    parsed.deinit();
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 1 }, archive.locate(root_header, 0).?.span);
    const location = archive.locate(nested, 1).?;
    try std.testing.expectEqualStrings("fixture.ecl", location.source_name);
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 4 }, location.span);
}
