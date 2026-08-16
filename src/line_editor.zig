//! Dependency-free scalar-safe line editing and bounded physical-line history.
const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const reader = @import("reader.zig");
const session = @import("session.zig");
const text_buffer = @import("text_buffer.zig");

pub const max_line_bytes: usize = 1024 * 1024;
pub const max_history_entries: usize = 100;
const max_history_bytes: usize = max_line_bytes * max_history_entries + max_history_entries;
const history_warning = "ecl: history is unavailable; continuing without persistence";
const raw_supported = builtin.os.tag == .linux or builtin.os.tag == .macos;

const OwnedLineBacking = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
};

/// Nominal line ownership returned by `Editor.readLine`. `bytes` borrows until
/// deinit and no editor or terminal resource is retained by the result.
pub const OwnedLine = enum(usize) {
    consumed = 0,
    _,

    fn init(owned: *OwnedLineBacking) OwnedLine {
        return @enumFromInt(@intFromPtr(owned));
    }
    fn backing(self: OwnedLine) *OwnedLineBacking {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn bytes(self: OwnedLine) []const u8 {
        return self.backing().bytes;
    }
    pub fn deinit(self: *OwnedLine) void {
        if (self.* == .consumed) return;
        const owned = self.backing();
        const allocator = owned.allocator;
        allocator.free(owned.bytes);
        allocator.destroy(owned);
        self.* = .consumed;
    }
};

pub const EditError = error{ OutOfMemory, LineTooLong };
const EditBufferBacking = struct {
    text: text_buffer.TextBuffer,
    cursor: usize = 0,
};

/// The editable line. The representation is an opaque handle rather than a
/// struct with a private field type, because Zig's inferred struct literals
/// let external code build the latter directly and hand itself a cursor that
/// no splice ever produced.
pub const EditBuffer = enum(usize) {
    _,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!EditBuffer {
        const backing = try allocator.create(EditBufferBacking);
        backing.* = .{ .text = .init(allocator) };
        return @enumFromInt(@intFromPtr(backing));
    }
    fn state(self: EditBuffer) *EditBufferBacking {
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn deinit(self: *EditBuffer) void {
        const owned = self.state();
        const allocator = owned.text.allocator;
        owned.text.deinit();
        allocator.destroy(owned);
        self.* = undefined;
    }
    pub fn bytes(self: EditBuffer) []const u8 {
        return self.state().text.items();
    }
    pub fn cursorIndex(self: EditBuffer) usize {
        return self.state().cursor;
    }
    /// The buffer as text either side of the cursor. This is the only place
    /// both facts are known, so it is the only place a view is minted; nothing
    /// downstream receives an offset it could pair with the wrong bytes.
    pub fn displayView(self: EditBuffer) console.DisplayView {
        const owned = self.state();
        return .{
            .before = owned.text.items()[0..owned.cursor],
            .after = owned.text.items()[owned.cursor..],
        };
    }
    pub fn set(self: EditBuffer, source: []const u8) EditError!void {
        return self.splice(0, self.state().text.len(), &.{source});
    }
    pub fn insert(self: EditBuffer, source: []const u8) EditError!void {
        const cursor = self.state().cursor;
        return self.splice(cursor, cursor, &.{source});
    }
    pub fn moveLeft(self: EditBuffer) void {
        const owned = self.state();
        owned.cursor -= console.scalarLenBefore(owned.text.items(), owned.cursor);
    }
    pub fn moveRight(self: EditBuffer) void {
        const owned = self.state();
        owned.cursor += console.scalarLenAt(owned.text.items(), owned.cursor);
    }
    pub fn moveHome(self: EditBuffer) void {
        self.state().cursor = 0;
    }
    pub fn moveEnd(self: EditBuffer) void {
        const owned = self.state();
        owned.cursor = owned.text.len();
    }
    pub fn backspace(self: EditBuffer) void {
        const owned = self.state();
        if (owned.cursor == 0) return;
        self.remove(owned.cursor - console.scalarLenBefore(owned.text.items(), owned.cursor), owned.cursor);
    }
    pub fn delete(self: EditBuffer) void {
        const owned = self.state();
        if (owned.cursor == owned.text.len()) return;
        self.remove(owned.cursor, owned.cursor + console.scalarLenAt(owned.text.items(), owned.cursor));
    }
    pub fn clear(self: EditBuffer) void {
        self.remove(0, self.state().text.len());
    }
    pub fn killToEnd(self: EditBuffer) void {
        self.remove(self.state().cursor, self.state().text.len());
    }
    pub fn deleteWord(self: EditBuffer) void {
        const owned = self.state();
        var start = owned.cursor;
        while (start != 0) {
            const previous = start - console.scalarLenBefore(owned.text.items(), start);
            if (!std.ascii.isWhitespace(owned.text.items()[previous])) break;
            start = previous;
        }
        while (start != 0) {
            const previous = start - console.scalarLenBefore(owned.text.items(), start);
            if (std.ascii.isWhitespace(owned.text.items()[previous])) break;
            start = previous;
        }
        self.remove(start, owned.cursor);
    }
    pub fn transpose(self: EditBuffer) void {
        const owned = self.state();
        if (owned.text.len() < 2 or owned.cursor == 0) return;
        const right_start = if (owned.cursor == owned.text.len())
            owned.cursor - console.scalarLenBefore(owned.text.items(), owned.cursor)
        else
            owned.cursor;
        if (right_start == 0) return;
        const left_start = right_start - console.scalarLenBefore(owned.text.items(), right_start);
        const right_end = right_start + console.scalarLenAt(owned.text.items(), right_start);
        // Two scalars never exceed the inline replacement, so a transpose is a
        // splice like every other byte change rather than an in-place shuffle
        // that has to re-establish the cursor invariant on its own.
        // Two scalars swapped is one splice of the same range, and the
        // storage owns both sources before it writes, so they can simply be
        // the bytes being replaced in the other order.
        self.splice(left_start, right_end, &.{
            owned.text.items()[right_start..right_end],
            owned.text.items()[left_start..right_start],
        }) catch unreachable;
    }
    pub fn takeOwned(self: EditBuffer) error{OutOfMemory}!OwnedLine {
        const owned = self.state();
        const allocator = owned.text.allocator;
        const line_backing = try allocator.create(OwnedLineBacking);
        errdefer allocator.destroy(line_backing);
        const owned_bytes = try owned.text.takeOwned();
        line_backing.* = .{ .allocator = allocator, .bytes = owned_bytes };
        owned.cursor = 0;
        return .init(line_backing);
    }
    fn remove(self: EditBuffer, start: usize, end: usize) void {
        // Deletion never grows the buffer, so the shared splice cannot fail.
        self.splice(start, end, &.{}) catch unreachable;
    }
    /// The only operation that changes bytes, and the only place the line
    /// limit is decided. Validation belongs here rather than at the call
    /// sites because whether a replacement fits depends on the range it
    /// replaces: checking earlier rejects overwriting a full buffer with a
    /// single byte.
    ///
    /// The storage owns every source before it writes, so `sources` may be
    /// slices of the very bytes being replaced. The cursor is then re-derived
    /// from the result rather than computed, because a replacement can form a
    /// scalar across either seam — inserting a lead byte in front of a
    /// stranded continuation byte is the short example — and arithmetic would
    /// land inside it.
    fn splice(
        self: EditBuffer,
        start: usize,
        end: usize,
        sources: []const []const u8,
    ) EditError!void {
        const owned = self.state();
        var total: usize = 0;
        for (sources) |source| total += source.len;
        const remaining = owned.text.len() - (end - start);
        if (total > max_line_bytes - remaining) return error.LineTooLong;
        try owned.text.splice(start, end, sources);
        owned.cursor = scalarAligned(owned.text.items(), start + total);
    }
};

/// Snap `position` forward out of the interior of a scalar. A scalar is at
/// most four bytes and starts at a lead byte, so at most three probes decide
/// it, and no two decodable scalars can both contain the position.
fn scalarAligned(bytes: []const u8, position: usize) usize {
    var back: usize = 1;
    while (back != 4 and back <= position) : (back += 1) {
        const length = console.scalarLenAt(bytes, position - back);
        if (length > back) return position - back + length;
    }
    return position;
}

fn clearEntries(allocator: std.mem.Allocator, entries: *std.ArrayList([]u8)) void {
    for (entries.items) |entry| allocator.free(entry);
    entries.deinit(allocator);
    entries.* = .empty;
}

fn validHistoryLine(line: []const u8) bool {
    return line.len != 0 and
        line.len <= max_line_bytes and
        std.unicode.utf8ValidateSlice(line) and
        std.mem.indexOfAny(u8, line, "\r\n") == null;
}

fn appendHistory(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList([]u8),
    line: []const u8,
) error{OutOfMemory}!void {
    if (line.len == 0) return;
    if (entries.items.len != 0 and std.mem.eql(u8, entries.items[entries.items.len - 1], line)) return;
    const copy = try allocator.dupe(u8, line);
    errdefer allocator.free(copy);
    try entries.append(allocator, copy);
    if (entries.items.len > max_history_entries) {
        allocator.free(entries.items[0]);
        std.mem.copyForwards([]u8, entries.items, entries.items[1..]);
        entries.shrinkRetainingCapacity(max_history_entries);
    }
}

const InvalidHistory = error{InvalidHistory};
fn parseHistory(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    entries: *std.ArrayList([]u8),
) (error{OutOfMemory} || InvalidHistory)!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidHistory;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len > max_line_bytes or std.mem.indexOfScalar(u8, line, '\r') != null)
            return error.InvalidHistory;
        try appendHistory(allocator, entries, line);
    }
}

pub const History = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8,
    entries_storage: std.ArrayList([]u8) = .empty,
    persistence_failed: bool = false,
    warning_emitted: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: ?[]const u8,
    ) error{OutOfMemory}!History {
        var result = History{
            .allocator = allocator,
            .io = io,
            .path = if (path) |value| try allocator.dupe(u8, value) else null,
        };
        errdefer result.deinit();
        if (result.path) |history_path| result.load(history_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => {},
            else => result.persistence_failed = true,
        };
        return result;
    }
    pub fn deinit(self: *History) void {
        clearEntries(self.allocator, &self.entries_storage);
        if (self.path) |path| self.allocator.free(path);
        self.* = undefined;
    }
    pub fn entries(self: *const History) []const []const u8 {
        return self.entries_storage.items;
    }
    pub fn record(self: *History, line: []const u8) error{OutOfMemory}!void {
        if (!validHistoryLine(line)) return;
        try appendHistory(self.allocator, &self.entries_storage, line);
        const history_path = self.path orelse return;
        self.persist(history_path, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => self.persistence_failed = true,
        };
    }
    pub fn takeWarning(self: *History) ?[]const u8 {
        if (!self.persistence_failed or self.warning_emitted) return null;
        self.warning_emitted = true;
        return history_warning;
    }
    fn openParent(self: *History, history_path: []const u8) !std.Io.Dir {
        const parent = std.Io.Dir.path.dirname(history_path) orelse ".";
        return if (std.Io.Dir.path.isAbsolute(parent))
            std.Io.Dir.openDirAbsolute(self.io, parent, .{})
        else
            std.Io.Dir.cwd().openDir(self.io, parent, .{});
    }
    fn load(self: *History, history_path: []const u8) !void {
        var directory = try self.openParent(history_path);
        defer directory.close(self.io);
        try loadFromDirectory(
            self.allocator,
            self.io,
            directory,
            std.Io.Dir.path.basename(history_path),
            &self.entries_storage,
        );
    }
    fn persist(self: *History, history_path: []const u8, line: []const u8) !void {
        var directory = try self.openParent(history_path);
        defer directory.close(self.io);
        const basename = std.Io.Dir.path.basename(history_path);
        const lock_name = try std.mem.concat(self.allocator, u8, &.{ basename, ".lock" });
        defer self.allocator.free(lock_name);
        const permissions: std.Io.File.Permissions = if (comptime std.Io.File.Permissions.has_executable_bit)
            .fromMode(0o600)
        else
            .default_file;
        const lock = try directory.createFile(self.io, lock_name, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .permissions = permissions,
        });
        defer lock.close(self.io);
        var merged: std.ArrayList([]u8) = .empty;
        defer clearEntries(self.allocator, &merged);
        loadFromDirectory(self.allocator, self.io, directory, basename, &merged) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try appendHistory(self.allocator, &merged, line);
        var atomic = try directory.createFileAtomic(self.io, basename, .{
            .permissions = permissions,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        var output_buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &output_buffer);
        for (merged.items) |entry| {
            try writer.interface.writeAll(entry);
            try writer.interface.writeByte('\n');
        }
        try writer.interface.flush();
        try atomic.replace(self.io);
        clearEntries(self.allocator, &self.entries_storage);
        self.entries_storage = merged;
        merged = .empty;
    }
};

fn loadFromDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    basename: []const u8,
    entries: *std.ArrayList([]u8),
) !void {
    const bytes = try directory.readFileAlloc(io, basename, allocator, .limited(max_history_bytes));
    defer allocator.free(bytes);
    try parseHistory(allocator, bytes, entries);
}

pub const ReadResult = union(enum) { line: OwnedLine, cancelled, eof };
pub const ReadError = error{ OutOfMemory, ReadFailed, WriteFailed, TerminalFailure };

pub const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    history: History,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        history_path: ?[]const u8,
    ) error{OutOfMemory}!Editor {
        return .{ .allocator = allocator, .io = io, .history = try .init(allocator, io, history_path) };
    }
    pub fn deinit(self: *Editor) void {
        self.history.deinit();
        self.* = undefined;
    }
    pub fn takeHistoryWarning(self: *Editor) ?[]const u8 {
        return self.history.takeWarning();
    }
    /// `pending` is the reader's own lexical state at the end of the unit so
    /// far. The editor is handed the conclusion rather than the bytes: it
    /// cannot re-derive lexical state, and asking a question about the unit
    /// costs the current line rather than everything typed before it.
    pub fn readLine(
        self: *Editor,
        terminal: session.EditorTerminal,
        completion: session.CompletionObserve,
        prompt: console.Prompt,
        pending: reader.PendingUnit,
    ) ReadError!ReadResult {
        // Single-row editing needs a measured row and a terminal that can be
        // put into raw mode. Without either, the canonical reader is the
        // defined behaviour, not a guessed row width.
        if (comptime raw_supported) if (terminal.row()) |_| {
            var guard = RawModeGuard.enter() catch return error.TerminalFailure;
            errdefer if (guard.restore()) |_| {} else |_| {};
            var result = try self.readRaw(terminal, completion, prompt, pending);
            guard.restore() catch {
                switch (result) {
                    .line => |*line| line.deinit(),
                    .cancelled, .eof => {},
                }
                return error.TerminalFailure;
            };
            return result;
        };
        return self.readCanonical(terminal, prompt);
    }
    fn readCanonical(
        self: *Editor,
        terminal: session.EditorTerminal,
        prompt: console.Prompt,
    ) ReadError!ReadResult {
        terminal.writePrompt(prompt) catch return error.WriteFailed;
        var buffer = try EditBuffer.init(self.allocator);
        defer buffer.deinit();
        while (true) {
            const byte = try self.readByte() orelse {
                if (buffer.bytes().len == 0) return .eof;
                var line = try buffer.takeOwned();
                errdefer line.deinit();
                try self.history.record(line.bytes());
                return .{ .line = line };
            };
            if (byte == '\n') {
                var line = try buffer.takeOwned();
                errdefer line.deinit();
                try self.history.record(line.bytes());
                return .{ .line = line };
            }
            buffer.insert(&.{byte}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LineTooLong => {},
            };
        }
    }
    fn readRaw(
        self: *Editor,
        terminal: session.EditorTerminal,
        completion: session.CompletionObserve,
        prompt: console.Prompt,
        pending: reader.PendingUnit,
    ) ReadError!ReadResult {
        var buffer = try EditBuffer.init(self.allocator);
        defer buffer.deinit();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.allocator);
        var history_index: ?usize = null;
        var last_was_tab = false;
        try refresh(terminal, prompt, buffer);
        while (true) {
            const byte = try self.readByte() orelse {
                terminal.signal(.newline) catch return error.WriteFailed;
                if (buffer.bytes().len == 0) return .eof;
                return try self.finishLine(buffer);
            };
            switch (byte) {
                '\r', '\n' => {
                    terminal.signal(.newline) catch return error.WriteFailed;
                    return try self.finishLine(buffer);
                },
                1 => buffer.moveHome(),
                2 => buffer.moveLeft(),
                3 => {
                    terminal.signal(.newline) catch return error.WriteFailed;
                    return .cancelled;
                },
                4 => if (buffer.bytes().len == 0) {
                    terminal.signal(.newline) catch return error.WriteFailed;
                    return .eof;
                } else buffer.delete(),
                5 => buffer.moveEnd(),
                6 => buffer.moveRight(),
                8, 127 => buffer.backspace(),
                9 => {
                    try self.complete(terminal, completion, prompt, buffer, pending, last_was_tab);
                    last_was_tab = true;
                    continue;
                },
                11 => buffer.killToEnd(),
                12 => terminal.signal(.clear_screen) catch return error.WriteFailed,
                14 => try self.historyMove(buffer, &scratch, &history_index, false),
                16 => try self.historyMove(buffer, &scratch, &history_index, true),
                20 => buffer.transpose(),
                21 => buffer.clear(),
                23 => buffer.deleteWord(),
                27 => try self.escape(buffer, &scratch, &history_index),
                else => if (byte >= 32) try self.insertInput(terminal, buffer, byte),
            }
            last_was_tab = false;
            try refresh(terminal, prompt, buffer);
        }
    }
    fn finishLine(self: *Editor, buffer: EditBuffer) ReadError!ReadResult {
        var line = try buffer.takeOwned();
        errdefer line.deinit();
        try self.history.record(line.bytes());
        return .{ .line = line };
    }
    fn readByte(self: *Editor) ReadError!?u8 {
        var byte: [1]u8 = undefined;
        const count = std.Io.File.stdin().readStreaming(self.io, &.{&byte}) catch return error.ReadFailed;
        return if (count == 0) null else byte[0];
    }
    fn insertInput(
        self: *Editor,
        terminal: session.EditorTerminal,
        buffer: EditBuffer,
        first: u8,
    ) ReadError!void {
        var bytes: [4]u8 = undefined;
        bytes[0] = first;
        const wanted = std.unicode.utf8ByteSequenceLength(first) catch 1;
        var length: usize = 1;
        while (length < wanted) : (length += 1) {
            bytes[length] = try self.readByte() orelse break;
        }
        buffer.insert(bytes[0..length]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LineTooLong => terminal.signal(.bell) catch return error.WriteFailed,
        };
    }
    fn historyMove(
        self: *Editor,
        buffer: EditBuffer,
        scratch: *std.ArrayList(u8),
        index: *?usize,
        older: bool,
    ) ReadError!void {
        const entries = self.history.entries();
        if (entries.len == 0) return;
        if (older) {
            if (index.* == null) {
                try scratch.appendSlice(self.allocator, buffer.bytes());
                index.* = entries.len - 1;
            } else if (index.*.? != 0) index.*.? -= 1;
            buffer.set(entries[index.*.?]) catch |err| return mapEditError(err);
        } else if (index.*) |current| {
            if (current + 1 < entries.len) {
                index.* = current + 1;
                buffer.set(entries[current + 1]) catch |err| return mapEditError(err);
            } else {
                index.* = null;
                buffer.set(scratch.items) catch |err| return mapEditError(err);
                scratch.clearRetainingCapacity();
            }
        }
    }
    fn escape(
        self: *Editor,
        buffer: EditBuffer,
        scratch: *std.ArrayList(u8),
        history_index: *?usize,
    ) ReadError!void {
        const first = try self.readByte() orelse return;
        if (first != '[' and first != 'O') return;
        const key = try self.readByte() orelse return;
        switch (key) {
            'A' => try self.historyMove(buffer, scratch, history_index, true),
            'B' => try self.historyMove(buffer, scratch, history_index, false),
            'C' => buffer.moveRight(),
            'D' => buffer.moveLeft(),
            'H' => buffer.moveHome(),
            'F' => buffer.moveEnd(),
            '1', '3', '4', '7', '8' => {
                if (try self.readByte() != '~') return;
                switch (key) {
                    '1', '7' => buffer.moveHome(),
                    '3' => buffer.delete(),
                    '4', '8' => buffer.moveEnd(),
                    else => unreachable,
                }
            },
            else => {},
        }
    }
    fn complete(
        _: *Editor,
        terminal: session.EditorTerminal,
        completion: session.CompletionObserve,
        prompt: console.Prompt,
        buffer: EditBuffer,
        pending: reader.PendingUnit,
        repeated: bool,
    ) ReadError!void {
        const prefix = completionPrefix(buffer, pending) orelse return;
        var candidates = try completion.candidates(prefix);
        defer candidates.deinit();
        const items = candidates.items();
        if (items.len == 0) {
            terminal.signal(.bell) catch return error.WriteFailed;
            return;
        }
        var common = items[0].len;
        for (items[1..]) |item| {
            common = @min(common, commonPrefix(items[0], item));
        }
        while (common > prefix.len and !std.unicode.utf8ValidateSlice(items[0][0..common])) common -= 1;
        if (common > prefix.len) {
            buffer.insert(items[0][prefix.len..common]) catch |err| return mapEditError(err);
            try refresh(terminal, prompt, buffer);
            return;
        }
        if (!repeated and items.len != 1) return;
        if (items.len == 1) {
            buffer.insert(items[0][prefix.len..]) catch |err| return mapEditError(err);
            try refresh(terminal, prompt, buffer);
            return;
        }
        terminal.writeCandidates(items) catch return error.WriteFailed;
        try refresh(terminal, prompt, buffer);
    }
    /// The partial name the cursor is sitting on, or null when nothing may be
    /// completed there. The reader's own tokenizer answers, resuming from the
    /// unit's checkpoint over only the current line, so completion neither
    /// re-derives lexical state nor rescans everything typed before it.
    fn completionPrefix(buffer: EditBuffer, pending: reader.PendingUnit) ?[]const u8 {
        const cursor = buffer.cursorIndex();
        const start = switch (pending.contextAfter(buffer.bytes()[0..cursor])) {
            .inert, .boundary => return null,
            .atom => |start| start,
        };
        return if (start == cursor) null else buffer.bytes()[start..cursor];
    }
};

fn mapEditError(err: EditError) ReadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LineTooLong => error.WriteFailed,
    };
}

fn commonPrefix(left: []const u8, right: []const u8) usize {
    const end = @min(left.len, right.len);
    var index: usize = 0;
    while (index != end and left[index] == right[index]) : (index += 1) {}
    return index;
}

/// The editor hands the terminal its raw bytes and a cursor offset. Which
/// bytes fit, how they are escaped, and where the cursor column ends up are
/// all decided on the other side of this call.
fn refresh(
    terminal: session.EditorTerminal,
    prompt: console.Prompt,
    buffer: EditBuffer,
) ReadError!void {
    const row = terminal.row() orelse return error.WriteFailed;
    row.redraw(prompt, buffer.displayView()) catch return error.WriteFailed;
}

const RawModeGuard = if (raw_supported) struct {
    saved: std.posix.termios,
    active: bool = true,

    fn enter() !@This() {
        const handle = std.Io.File.stdin().handle;
        const saved = try std.posix.tcgetattr(handle);
        var raw = saved;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(handle, .NOW, raw);
        return .{ .saved = saved };
    }
    fn restore(self: *@This()) !void {
        if (!self.active) return;
        try std.posix.tcsetattr(std.Io.File.stdin().handle, .DRAIN, self.saved);
        self.active = false;
    }
} else struct {
    fn enter() !@This() {
        return .{};
    }
    fn restore(_: *@This()) !void {}
};
