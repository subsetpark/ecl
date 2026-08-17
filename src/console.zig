//! The terminal boundary: geometry, row planning, escaping, and serialized
//! whole writes. Everything an interpreter must know about a terminal to put
//! text on one lives here, and nothing above this file may write to one.
const std = @import("std");
const builtin = @import("builtin");

/// Prompts are interpreter-authored, so they are named rather than passed as
/// runtime bytes a caller could fill with anything.
pub const Prompt = enum {
    primary,
    continuation,

    pub fn text(self: Prompt) []const u8 {
        return switch (self) {
            .primary => "ecl> ",
            .continuation => ".. ",
        };
    }
};

/// Terminal effects the editor may request, named rather than spelled as
/// control bytes, so no caller can compose a sequence of its own.
pub const TerminalAction = enum {
    bell,
    newline,
    clear_screen,

    fn text(self: TerminalAction) []const u8 {
        return switch (self) {
            .bell => "\x07",
            .newline => "\r\n",
            .clear_screen => "\x1b[H\x1b[2J",
        };
    }
};

/// A measured row width. Minted only by `geometry`, so a caller cannot invent
/// one, and single-row drawing is reachable only from a value of this type.
pub const Columns = enum(u16) {
    _,

    /// Cells usable for buffer text after the prompt, keeping one spare column
    /// so a full row cannot itself trigger a wrap.
    fn available(self: Columns, prompt: Prompt) ?usize {
        const columns = @intFromEnum(self);
        const reserved = prompt.text().len + 1;
        return if (columns <= reserved) null else columns - reserved;
    }
};

/// A row that could not be measured is a distinct state, not a number. There
/// is no fallback width: guessing eighty columns on a narrower terminal wraps
/// the row and moves the cursor the redraw places by rewriting its prefix, so
/// an unmeasurable terminal selects the canonical line reader instead.
pub const Geometry = union(enum) {
    known: Columns,
    unavailable,
};

/// Text either side of the cursor. Splitting at the cursor is what makes the
/// pair a single fact: every value of this type describes a cursor that lies
/// between two byte runs, so no offset travels beside the bytes it indexes and
/// none can fail to correspond to them.
pub const DisplayView = struct {
    before: []const u8,
    after: []const u8,
};

pub fn geometry() Geometry {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return .unavailable;
    // SAFETY: ioctl initializes the complete winsize before the success branch
    // reads it, and `ioctl` is declared variadically as libc declares it.
    var size: std.posix.winsize = undefined;
    const handle = std.Io.File.stdout().handle;
    if (builtin.os.tag == .linux) {
        const result = std.os.linux.ioctl(handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
        if (std.os.linux.errno(result) != .SUCCESS) return .unavailable;
    } else if (std.c.ioctl(handle, std.posix.T.IOCGWINSZ, &size) != 0) return .unavailable;
    return if (size.col == 0) .unavailable else .{ .known = @enumFromInt(size.col) };
}

/// Narrow a view to what fits one row, trimming each side away from the
/// cursor. Sizing uses `boundedCells` and no unit is ever forced in when it
/// does not fit, so a drawn row cannot wrap; that matters because the redraw
/// places the cursor by rewriting the text before it, and a wrapped row would
/// put that text on a different line.
pub fn planWindow(columns: Columns, prompt: Prompt, view: DisplayView) DisplayView {
    const available = columns.available(prompt) orelse
        return .{ .before = "", .after = "" };
    var start = view.before.len;
    var budget: usize = 0;
    var scalars: usize = 0;
    while (start != 0 and scalars != available) : (scalars += 1) {
        const length = scalarLenBefore(view.before, start);
        const cost = boundedCells(view.before[start - length ..][0..length]);
        if (budget + cost > available) break;
        budget += cost;
        start -= length;
    }
    var end: usize = 0;
    scalars = 0;
    while (end != view.after.len and scalars != available) : (scalars += 1) {
        const length = scalarLenAt(view.after, end);
        const cost = boundedCells(view.after[end..][0..length]);
        if (budget + cost > available) break;
        budget += cost;
        end += length;
    }
    return .{ .before = view.before[start..], .after = view.after[0..end] };
}

/// An upper bound on the cells `bytes` occupy, used wherever being wrong would
/// break the drawing. Escapes are exact, printable ASCII is exact, and every
/// other scalar is charged two cells because no terminal renders one wider.
pub fn boundedCells(bytes: []const u8) usize {
    var index: usize = 0;
    var total: usize = 0;
    while (index != bytes.len) {
        const unit = unitAt(bytes, index);
        total += if (unit.escape)
            escape_cells * unit.len
        else if (bytes[index] < 0x7f)
            1
        else
            // Every remaining scalar is charged the widest a terminal renders
            // one. Over-charging shows less text; under-charging wraps the row
            // and moves the cursor, so the bound only errs in the safe
            // direction. This is why there is no width table to be wrong.
            2;
        index += unit.len;
    }
    return total;
}

/// Byte length of the scalar starting at `index`, or one for a byte that
/// begins no scalar. Editing and display share this partition deliberately:
/// if they disagreed, a cursor could land inside a drawn unit.
pub fn scalarLenAt(bytes: []const u8, index: usize) usize {
    if (index == bytes.len) return 0;
    return unitAt(bytes, index).len;
}

/// Byte length of the scalar ending at `index`. A multi-byte length is
/// accepted only when the forward partition at its start yields exactly that
/// unit, so both directions agree on every boundary they share.
pub fn scalarLenBefore(bytes: []const u8, index: usize) usize {
    var length = @min(@as(usize, 4), index);
    while (length != 0) : (length -= 1) {
        const unit = unitAt(bytes, index - length);
        if (unit.decoded and unit.len == length) return length;
    }
    return @min(@as(usize, 1), index);
}

const escape_cells: usize = "\\xff".len;

/// One unit of terminal output: a scalar the terminal can render as a glyph,
/// or bytes shown as `\xNN` because emitting them would hand the terminal a
/// command. Malformed, truncated, C0, DEL, and C1 sequences all escape. C1 is
/// the reason decodability cannot be the test: U+0080-U+009F is well-formed
/// two-byte UTF-8 that a terminal in UTF-8 mode may still act on.
const Unit = struct { len: usize, decoded: bool, escape: bool };
const escaped_byte: Unit = .{ .len = 1, .decoded = false, .escape = true };

fn unitAt(bytes: []const u8, index: usize) Unit {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return escaped_byte;
    if (bytes.len - index < length) return escaped_byte;
    const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch return escaped_byte;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f))
        return .{ .len = length, .decoded = true, .escape = true };
    return .{ .len = length, .decoded = true, .escape = false };
}

pub const Console = struct {
    output: ?*std.Io.Writer,
    diagnostics: ?*std.Io.Writer,
    output_mutex: std.Io.Mutex = .init,
    diagnostics_mutex: std.Io.Mutex = .init,

    pub fn init(output: ?*std.Io.Writer, diagnostics: ?*std.Io.Writer) Console {
        return .{ .output = output, .diagnostics = diagnostics };
    }

    pub fn writeOutput(self: *Console, bytes: []const u8, newline: bool) error{WriteFailed}!void {
        const writer = self.output orelse return error.WriteFailed;
        std.Io.Threaded.mutexLock(&self.output_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.output_mutex);
        writer.writeAll(bytes) catch return error.WriteFailed;
        if (newline) writer.writeByte('\n') catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;
    }

    pub fn writeDiagnostics(self: *Console, bytes: []const u8, newline: bool) error{WriteFailed}!void {
        const writer = self.diagnostics orelse return error.WriteFailed;
        std.Io.Threaded.mutexLock(&self.diagnostics_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.diagnostics_mutex);
        writer.writeAll(bytes) catch return error.WriteFailed;
        if (newline) writer.writeByte('\n') catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;
    }

    /// A named terminal effect. There is no operation that takes control
    /// bytes, so no caller can compose a sequence of its own.
    pub fn signal(self: *Console, action: TerminalAction) error{WriteFailed}!void {
        return self.writeOutput(action.text(), false);
    }

    pub fn writePrompt(self: *Console, prompt: Prompt) error{WriteFailed}!void {
        return self.writeOutput(prompt.text(), false);
    }

    /// Redraw one prompt row from raw buffer bytes. This picks the window,
    /// escapes it, and places the cursor; callers supply text and a cursor
    /// offset and learn nothing about terminals.
    ///
    /// The row is written in full, erased to its end, and then its prefix is
    /// written again, so the terminal computes the cursor column itself. That
    /// is only sound while the row cannot wrap, which `planWindow` guarantees
    /// by sizing with an upper bound on every unit's width.
    pub fn redraw(
        self: *Console,
        columns: Columns,
        prompt: Prompt,
        view: DisplayView,
    ) error{WriteFailed}!void {
        const window = planWindow(columns, prompt, view);
        const before = window.before;
        const after = window.after;
        const writer = self.output orelse return error.WriteFailed;
        std.Io.Threaded.mutexLock(&self.output_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.output_mutex);
        writer.writeByte('\r') catch return error.WriteFailed;
        writer.writeAll(prompt.text()) catch return error.WriteFailed;
        try writeDisplay(writer, before);
        try writeDisplay(writer, after);
        writer.writeAll("\x1b[0K") catch return error.WriteFailed;
        writer.writeByte('\r') catch return error.WriteFailed;
        writer.writeAll(prompt.text()) catch return error.WriteFailed;
        try writeDisplay(writer, before);
        writer.flush() catch return error.WriteFailed;
    }

    pub fn writeCandidates(self: *Console, candidates: []const []const u8) error{WriteFailed}!void {
        const writer = self.output orelse return error.WriteFailed;
        std.Io.Threaded.mutexLock(&self.output_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.output_mutex);
        writer.writeAll("\r\n") catch return error.WriteFailed;
        for (candidates, 0..) |candidate, index| {
            if (index != 0) writer.writeAll("  ") catch return error.WriteFailed;
            try writeDisplay(writer, candidate);
        }
        writer.writeAll("\r\n") catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;
    }
};

fn writeDisplay(writer: *std.Io.Writer, bytes: []const u8) error{WriteFailed}!void {
    var index: usize = 0;
    while (index != bytes.len) {
        const unit = unitAt(bytes, index);
        if (unit.escape) {
            for (bytes[index..][0..unit.len]) |byte|
                writer.print("\\x{x:0>2}", .{byte}) catch return error.WriteFailed;
        } else {
            writer.writeAll(bytes[index..][0..unit.len]) catch return error.WriteFailed;
        }
        index += unit.len;
    }
}

test "console serializes a complete writer use" {
    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var console = Console.init(&writer, null);
    try console.writeOutput("whole", false);
    try console.redraw(@enumFromInt(40), .primary, .{ .before = "ab", .after = "c" });
    try console.writeCandidates(&.{ "one", "two" });
    try std.testing.expectEqualStrings(
        "whole\recl> abc\x1b[0K\recl> ab\r\none  two\r\n",
        writer.buffered(),
    );
}

test "console escapes every byte a terminal would act on" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var console = Console.init(&writer, null);
    // C0 before the cursor, a malformed byte after it, and C1 inside a
    // candidate name all reach the same escaping policy.
    try console.redraw(@enumFromInt(40), .continuation, .{ .before = "\x1b[2J", .after = "\xff" });
    try console.writeCandidates(&.{ "\u{9b}2J", "plain" });
    try std.testing.expectEqualStrings(
        "\r.. \\x1b[2J\\xff\x1b[0K\r.. \\x1b[2J\r\n\\xc2\\x9b2J  plain\r\n",
        writer.buffered(),
    );
}
