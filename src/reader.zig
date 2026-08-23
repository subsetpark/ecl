//! Public reader facade over the single resumable implementation.
const types = @import("reader_types.zig");
const implementation = @import("reader_cursor.zig");

pub const Value = types.Value;
pub const Header = types.Header;
pub const Span = types.Span;
pub const Diag = types.Diag;
pub const Error = types.Error;
pub const Incomplete = types.Incomplete;
pub const SpanTable = types.SpanTable;
pub const SourceSlice = types.SourceSlice;
pub const Parsed = types.Parsed;
pub const HostParsed = types.HostParsed;
pub const ReadResult = types.HostReadResult;
pub const ReadCursor = implementation.ReadCursor;
pub const ReadProgress = implementation.ReadProgress;
pub const LexicalContext = implementation.LexicalContext;

/// Accumulated source for a partly typed unit, and the only way to ask where
/// a cursor sits inside one. Callers that need to know whether they are in a
/// string, a character literal, or a comment ask the tokenizer that decides
/// it, rather than re-deriving the answer from a second scanner.
pub const PendingUnit = implementation.PendingUnit;

/// Synchronous hosts drive the same explicit continuation to completion.
/// Scheduler callers retain the cursor and advance it in bounded slices.
pub fn read(
    host: *const @import("heap.zig").HostCleanup,
    source_name: []const u8,
    source: []const u8,
    diag: *Diag,
) Error!ReadResult {
    return implementation.read(host, source_name, source, diag);
}

pub fn readCode(
    host: *const @import("heap.zig").HostCleanup,
    source_name: []const u8,
    source: []const u8,
    diag: *Diag,
    provenance_namespace: @import("heap.zig").CodeProvenanceNamespace,
) Error!ReadResult {
    return implementation.readCode(host, source_name, source, diag, provenance_namespace);
}
