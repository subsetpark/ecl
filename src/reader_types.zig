//! Reader result, diagnostic, and provenance ownership types.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const lexer = @import("lexer.zig");
const poll = @import("poll.zig");

pub const Value = value.Value;
pub const Header = value.ListHandle;
pub const Span = lexer.Span;
pub const Diag = lexer.Diag;
pub const Error = error{ OutOfMemory, Parse };

pub const Incomplete = struct {
    message: []const u8,
    span: Span,
};

/// Provenance is keyed by the identity of reader-built code lists. Runtime-
/// built or CoW-copied lists are naturally absent.
pub const SpanTable = struct {
    const bucket_count = 4096;
    pub const Entry = struct {
        header: *Header,
        spans: []Span,
        next_bucket: ?*Entry = null,
    };
    pub const EntryList = poll.ChunkList(Entry);
    entries: EntryList,
    buckets: []?*Entry = &.{},
    top: []Span = &.{},

    pub fn init(allocator: std.mem.Allocator) SpanTable {
        return .{ .entries = .init(allocator) };
    }
    pub const RetireProgress = enum { pending, complete };
    pub const RetireCursor = struct {
        table: *SpanTable,
        entries: EntryList.Iterator,
        phase: enum { entries, storage, complete } = .entries,

        pub fn init(table: *SpanTable) RetireCursor {
            return .{ .table = table, .entries = table.entries.iterator() };
        }

        pub fn advance(self: *RetireCursor, releases: *heap.ReleaseDomain) RetireProgress {
            return switch (self.phase) {
                .entries => if (self.entries.next()) |entry| result: {
                    if (entry.spans.len > 0) self.table.entries.allocator.free(entry.spans);
                    break :result .pending;
                } else result: {
                    self.table.entries.retire(releases);
                    self.phase = .storage;
                    break :result .pending;
                },
                .storage => result: {
                    const allocator = self.table.entries.allocator;
                    if (self.table.buckets.len > 0) allocator.free(self.table.buckets);
                    if (self.table.top.len > 0) allocator.free(self.table.top);
                    self.table.* = .init(allocator);
                    self.phase = .complete;
                    break :result .complete;
                },
                .complete => unreachable,
            };
        }
    };
    fn bucket(header: *const Header) usize {
        const address = @intFromPtr(header) >> 4;
        return address & (bucket_count - 1);
    }

    pub const LookupProgress = union(enum) { pending, complete: ?[]const Span };
    pub const LookupCursor = struct {
        header: *Header,
        entry: ?*Entry,
        pub fn advance(self: *LookupCursor) LookupProgress {
            const current = self.entry orelse return .{ .complete = null };
            if (current.header == self.header) return .{ .complete = current.spans };
            self.entry = current.next_bucket;
            return .pending;
        }
    };
    pub fn lookupCursor(self: *const SpanTable, header: *Header) ?LookupCursor {
        if (self.buckets.len == 0) return null;
        return .{ .header = header, .entry = self.buckets[bucket(header)] };
    }

    pub const PutProgress = enum { pending, complete };
    pub const PutCursor = struct {
        table: *SpanTable,
        allocator: std.mem.Allocator,
        header: *Header,
        source: []const Span,
        uniform: ?Span,
        owned: ?[]Span = null,
        index: usize = 0,
        initializing_buckets: bool = false,
        phase: enum { allocate, copy, buckets, insert, complete } = .allocate,

        pub fn init(
            table: *SpanTable,
            allocator: std.mem.Allocator,
            header: *Header,
            source: []const Span,
        ) PutCursor {
            return .{ .table = table, .allocator = allocator, .header = header, .source = source, .uniform = null };
        }
        pub fn initUniform(
            table: *SpanTable,
            allocator: std.mem.Allocator,
            header: *Header,
            span: Span,
        ) PutCursor {
            return .{
                .table = table,
                .allocator = allocator,
                .header = header,
                .source = &.{},
                .uniform = span,
            };
        }
        pub fn deinit(self: *PutCursor) void {
            if (self.owned) |owned| if (owned.len != 0) self.allocator.free(owned);
            self.* = undefined;
        }
        pub fn advance(self: *PutCursor) error{OutOfMemory}!PutProgress {
            return switch (self.phase) {
                .allocate => result: {
                    const count = if (self.uniform != null)
                        @as(usize, @intCast(self.header.length()))
                    else
                        self.source.len;
                    self.owned = if (count == 0) &.{} else try self.allocator.alloc(Span, count);
                    self.phase = .copy;
                    break :result .pending;
                },
                .copy => result: {
                    if (self.index != self.owned.?.len) {
                        self.owned.?[self.index] = self.uniform orelse self.source[self.index];
                        self.index += 1;
                    } else {
                        self.index = 0;
                        self.phase = .buckets;
                    }
                    break :result .pending;
                },
                .buckets => result: {
                    if (self.table.buckets.len == 0) {
                        self.table.buckets = try self.allocator.alloc(?*Entry, bucket_count);
                        self.initializing_buckets = true;
                    }
                    if (!self.initializing_buckets) {
                        self.phase = .insert;
                    } else if (self.index != self.table.buckets.len) {
                        self.table.buckets[self.index] = null;
                        self.index += 1;
                    } else self.phase = .insert;
                    break :result .pending;
                },
                .insert => result: {
                    const bucket_index = bucket(self.header);
                    const entry = try self.table.entries.appendPtr(.{
                        .header = self.header,
                        .spans = self.owned.?,
                        .next_bucket = self.table.buckets[bucket_index],
                    });
                    self.table.buckets[bucket_index] = entry;
                    self.owned = null;
                    self.phase = .complete;
                    break :result .complete;
                },
                .complete => unreachable,
            };
        }
    };
};

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    forms: heap.OwnedValueBuffer,
    releases: *heap.ReleaseDomain,
    spans: SpanTable,
    source_name: []u8,

    pub fn values(self: *const Parsed) []const Value {
        return self.forms.values();
    }

    pub const RetireCursor = struct {
        parsed: *Parsed,
        spans: SpanTable.RetireCursor,
        phase: enum { spans, forms, source_name, complete } = .spans,

        pub fn init(parsed: *Parsed) RetireCursor {
            return .{ .parsed = parsed, .spans = .init(&parsed.spans) };
        }

        pub fn advance(self: *RetireCursor) bool {
            return switch (self.phase) {
                .spans => switch (self.spans.advance(self.releaseDomain())) {
                    .pending => false,
                    .complete => result: {
                        self.phase = .forms;
                        break :result false;
                    },
                },
                .forms => result: {
                    self.parsed.forms.deinit();
                    self.phase = .source_name;
                    break :result false;
                },
                .source_name => result: {
                    self.parsed.allocator.free(self.parsed.source_name);
                    self.parsed.source_name = &.{};
                    self.phase = .complete;
                    break :result false;
                },
                .complete => true,
            };
        }

        fn releaseDomain(self: *const RetireCursor) *heap.ReleaseDomain {
            return self.parsed.releases;
        }
    };
};

/// Parsed result driven synchronously by an explicit host. The issuing cleanup
/// capability is captured at construction, so teardown cannot be paired with
/// another reclamation domain.
pub const HostParsed = struct {
    parsed: Parsed,
    host: *const heap.HostCleanup,

    pub fn values(self: *const HostParsed) []const Value {
        return self.parsed.values();
    }

    pub fn borrow(self: *HostParsed) *Parsed {
        return &self.parsed;
    }

    pub fn deinit(self: *HostParsed) void {
        var cursor = Parsed.RetireCursor.init(&self.parsed);
        while (!cursor.advance()) _ = self.parsed.releases.advance(256);
        self.host.drain();
        self.* = undefined;
    }
};

pub const ReadResult = union(enum) {
    complete: Parsed,
    incomplete: Incomplete,
};

pub const HostReadResult = union(enum) {
    complete: HostParsed,
    incomplete: Incomplete,
};
