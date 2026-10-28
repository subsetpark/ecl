//! Public reader facade over the single resumable implementation.
const types = @import("reader_types.zig");
const implementation = @import("reader_cursor.zig");
const value = @import("value.zig");

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

/// The module constructors whose operands end in a literal name.
pub fn isRegistrationWord(bytes: []const u8) bool {
    const std = @import("std");
    return std.mem.eql(u8, bytes, "@defm") or std.mem.eql(u8, bytes, "@defm!");
}

/// Inert inspection of already parsed top-level forms. Feed each form once,
/// in source order. Only a literal symbol immediately preceding `@defm` or `@defm!` is
/// discoverable; nested quotations and computed names are not declarations
/// visible to discovery. Names are returned verbatim, including duplicates:
/// namespace and export validation belong to the consumer's schema.
/// This scanner owns no values and does no evaluation or nested traversal.
pub const DeclarationScan = struct {
    /// The two forms before the current one: a registration's name arrives
    /// as the quote expansion `(name) core.first` ahead of `@defm`.
    quoted_name: ?u32 = null,
    previous_first: bool = false,

    pub fn feed(self: *DeclarationScan, form: Value) ?u32 {
        const std = @import("std");
        const intern = @import("intern.zig");
        const list = @import("list.zig");
        const declared = if (self.previous_first) self.quoted_name else null;
        const is_first = form == .symbol and std.mem.eql(u8, intern.get(form.symbol.name), "core.first");
        if (!is_first) {
            self.quoted_name = if (form == .list and form.list.length() == 1 and !form.isString()) name: {
                const element = list.atUnchecked(form, 0);
                break :name if (element == .symbol) element.symbol.name else null;
            } else null;
        }
        self.previous_first = is_first;
        if (form == .symbol and isRegistrationWord(intern.get(form.symbol.name))) return declared;
        return null;
    }
};

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
    word_linker: value.WordLinker,
) Error!ReadResult {
    return implementation.readCode(host, source_name, source, diag, provenance_namespace, word_linker);
}
