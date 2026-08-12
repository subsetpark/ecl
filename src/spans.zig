//! Session-lifetime ownership for reader provenance tables.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");

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
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) SpanArchive {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpanArchive) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Moves `parsed`'s provenance and source name into the archive and takes
    /// ownership of `root`. The caller still owns both on allocation failure.
    pub fn absorb(
        self: *SpanArchive,
        parsed: *reader.Parsed,
        root: value.Value,
    ) error{OutOfMemory}!void {
        std.debug.assert(root == .list);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);

        const top = parsed.spans.top;
        try parsed.spans.lists.put(self.allocator, root.list, top);
        parsed.spans.top = &.{};
        self.entries.appendAssumeCapacity(.{
            .root = root,
            .spans = parsed.spans,
            .source_name = parsed.source_name,
        });
        parsed.spans = .{};
        parsed.source_name = &.{};
    }

    pub fn locate(
        self: *const SpanArchive,
        header: *const value.Header,
        index: usize,
    ) ?LocatedSpan {
        var entry_index = self.entries.items.len;
        while (entry_index > 0) {
            entry_index -= 1;
            const entry = &self.entries.items[entry_index];
            const found = entry.spans.forList(@constCast(header)) orelse continue;
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
    try archive.absorb(&parsed, root);
    parsed.deinit();

    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 1 }, archive.locate(root_header, 0).?.span);
    const location = archive.locate(nested, 1).?;
    try std.testing.expectEqualStrings("fixture.ecl", location.source_name);
    try std.testing.expectEqual(lexer.Span{ .line = 1, .col = 4 }, location.span);
}
