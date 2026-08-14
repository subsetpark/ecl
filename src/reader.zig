//! Public reader facade over the single resumable implementation.
const std = @import("std");
const types = @import("reader_types.zig");
const implementation = @import("reader_cursor.zig");

pub const Value = types.Value;
pub const Header = types.Header;
pub const Span = types.Span;
pub const Diag = types.Diag;
pub const Error = types.Error;
pub const Incomplete = types.Incomplete;
pub const SpanTable = types.SpanTable;
pub const Parsed = types.Parsed;
pub const ReadResult = types.ReadResult;
pub const ReadCursor = implementation.ReadCursor;
pub const ReadProgress = implementation.ReadProgress;

/// Synchronous hosts drive the same explicit continuation to completion.
/// Scheduler callers retain the cursor and advance it in bounded slices.
pub fn read(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    diag: *Diag,
) Error!ReadResult {
    return implementation.read(allocator, source_name, source, diag);
}
