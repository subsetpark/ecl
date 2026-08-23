//! Canonical, representation-exposing value rendering.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const poll_api = @import("poll.zig");

pub const Value = value.Value;

const RenderStyle = enum { canonical, display };
const display_list_limit: u64 = 256;

const DisplayScan = struct {
    collection: Value,
    indent: usize,
    phase: enum { matrix, matrix_group } = .matrix,
    outer_index: usize = 0,
    inner_index: usize = 0,
    columns: u64 = 0,
};

const Action = union(enum) {
    render: struct { item: Value, indent: usize },
    sequence: struct {
        collection: Value,
        index: usize,
        indent: usize,
        multiline: bool,
    },
    dictionary: struct {
        header: *value.DictHandle,
        index: usize,
        key: bool,
        indent: usize,
        multiline: bool,
    },
    string: struct { collection: Value, index: usize },
    bytes: struct { source: []const u8, index: usize },
    display_scan: DisplayScan,
    spaces: usize,
};

pub const RenderProgress = poll_api.Progress(void);

/// Owned rendering state. Each transition writes only a scalar rendering, one
/// collection edge, one codepoint, or at most 256 identifier/indent bytes.
pub const RenderCursor = struct {
    actions: poll_api.ChunkStack(Action),
    style: RenderStyle,
    column: usize = 0,

    pub fn init(allocator: std.mem.Allocator, item: Value) error{OutOfMemory}!RenderCursor {
        return initWithStyle(allocator, item, .canonical, 0);
    }

    fn initWithStyle(
        allocator: std.mem.Allocator,
        item: Value,
        style: RenderStyle,
        initial_column: usize,
    ) error{OutOfMemory}!RenderCursor {
        var actions = poll_api.ChunkStack(Action).init(allocator);
        errdefer actions.deinit();
        try actions.push(.{ .render = .{ .item = item, .indent = initial_column } });
        return .{ .actions = actions, .style = style, .column = initial_column };
    }

    pub fn deinit(self: *RenderCursor) void {
        self.actions.deinit();
        self.* = undefined;
    }

    pub fn advance(
        self: *RenderCursor,
        writer: *std.Io.Writer,
        budget: usize,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!RenderProgress {
        std.debug.assert(budget != 0);
        for (0..budget) |_| {
            const action = self.actions.pop() orelse return .complete;
            try self.renderAction(action, writer);
            if (self.actions.isEmpty()) return .complete;
        }
        return .pending;
    }

    fn renderAction(
        self: *RenderCursor,
        action: Action,
        writer: *std.Io.Writer,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!void {
        switch (action) {
            .render => |render| switch (render.item) {
                .int => |number| try self.writeFmt(writer, "{d}", .{number}),
                .float => |number| try writeFloat(self, number, writer),
                .char => |codepoint| try writeChar(self, codepoint, writer),
                .symbol => |id| {
                    try self.writeByte(writer, '\'');
                    try self.pushBytes(intern.get(id));
                },
                .word => |id| try self.pushBytes(intern.get(id)),
                .list => |header| switch (header.kind()) {
                    .leaf_char1, .leaf_char2, .leaf_char4 => {
                        if (self.style == .display and header.length() > display_list_limit) {
                            try self.writeFmt(writer, "\"<{d}-characters-elided>\"", .{header.length()});
                            return;
                        }
                        try self.writeByte(writer, '"');
                        if (header.length() == 0) try self.writeByte(writer, '"') else try self.actions.push(.{ .string = .{ .collection = render.item, .index = 0 } });
                    },
                    .generic_spine => if (self.style == .display) {
                        if (header.length() > display_list_limit) {
                            try self.writeFmt(writer, "(<{d}-values-elided>)", .{header.length()});
                            return;
                        }
                        try self.actions.push(.{ .display_scan = .{
                            .collection = render.item,
                            .indent = self.column + 1,
                        } });
                    } else {
                        try self.writeByte(writer, '(');
                        try self.pushSequence(render.item, render.indent + 1, false);
                    },
                    .leaf_u8, .leaf_i64, .leaf_f64, .leaf_symbol => {
                        if (self.style == .display and header.length() > display_list_limit) {
                            try self.writeFmt(writer, "[<{d}-values-elided>]", .{header.length()});
                            return;
                        }
                        try self.writeByte(writer, '[');
                        try self.pushSequence(render.item, render.indent + 1, false);
                    },
                    .dict, .task, .module, .reserved_mask => unreachable,
                },
                .dict => |header| {
                    try self.writeByte(writer, '{');
                    try self.actions.push(.{ .dictionary = .{
                        .header = header,
                        .index = 0,
                        .key = true,
                        .indent = render.indent,
                        .multiline = self.style == .display and displayDictionaryMultiline(header),
                    } });
                },
                .task => |header| try self.writeFmt(writer, "<task:{d}>", .{heap.taskStorage(header).identity}),
                // An anonymous image has no name and no stable display
                // number to report, so the marker carries identity nowhere:
                // `match?` is the only identity observation.
                .module => try self.pushBytes("<module>"),
            },
            .sequence => |continuation| {
                const count: usize = @intCast(continuation.collection.list.length());
                if (continuation.index == count) {
                    try self.writeByte(writer, if (continuation.collection.list.kind() == .generic_spine) ')' else ']');
                    return;
                }
                const indent = continuation.index > 0 and continuation.multiline;
                if (continuation.index > 0)
                    try self.writeByte(writer, if (indent) '\n' else ' ');
                try self.actions.push(.{ .sequence = .{
                    .collection = continuation.collection,
                    .index = continuation.index + 1,
                    .indent = continuation.indent,
                    .multiline = continuation.multiline,
                } });
                try self.actions.push(.{ .render = .{
                    .item = list.atUnchecked(continuation.collection, continuation.index),
                    .indent = continuation.indent,
                } });
                if (indent and continuation.indent != 0)
                    try self.actions.push(.{ .spaces = continuation.indent });
            },
            .dictionary => |continuation| {
                const count: usize = @intCast(continuation.header.length());
                if (continuation.multiline) {
                    if (continuation.index == count) {
                        try self.writeByte(writer, '\n');
                        try self.pushBytes("}");
                        if (continuation.indent != 0)
                            try self.actions.push(.{ .spaces = continuation.indent });
                        return;
                    }
                    if (continuation.key) {
                        try self.writeByte(writer, '\n');
                        try self.actions.push(.{ .dictionary = .{
                            .header = continuation.header,
                            .index = continuation.index,
                            .key = false,
                            .indent = continuation.indent,
                            .multiline = true,
                        } });
                        try self.actions.push(.{ .render = .{
                            .item = dict.keyAt(continuation.header, continuation.index),
                            .indent = continuation.indent + 2,
                        } });
                        try self.actions.push(.{ .spaces = continuation.indent + 2 });
                        return;
                    }
                    try self.writeByte(writer, ' ');
                    try self.actions.push(.{ .dictionary = .{
                        .header = continuation.header,
                        .index = continuation.index + 1,
                        .key = true,
                        .indent = continuation.indent,
                        .multiline = true,
                    } });
                    try self.actions.push(.{ .render = .{
                        .item = dict.valueAt(continuation.header, continuation.index),
                        .indent = continuation.indent + 2,
                    } });
                    return;
                }
                if (continuation.index == count) {
                    try self.writeByte(writer, '}');
                    return;
                }
                if (!continuation.key or continuation.index > 0) try self.writeByte(writer, ' ');
                const child = if (continuation.key)
                    dict.keyAt(continuation.header, continuation.index)
                else
                    dict.valueAt(continuation.header, continuation.index);
                try self.actions.push(.{ .dictionary = .{
                    .header = continuation.header,
                    .index = continuation.index + @intFromBool(!continuation.key),
                    .key = !continuation.key,
                    .indent = continuation.indent,
                    .multiline = false,
                } });
                try self.actions.push(.{ .render = .{
                    .item = child,
                    .indent = continuation.indent,
                } });
            },
            .string => |continuation| {
                try writeStringCodepoint(
                    self,
                    list.atUnchecked(continuation.collection, continuation.index).char,
                    writer,
                );
                const next = continuation.index + 1;
                if (next == continuation.collection.list.length()) {
                    try self.writeByte(writer, '"');
                } else {
                    try self.actions.push(.{ .string = .{
                        .collection = continuation.collection,
                        .index = next,
                    } });
                }
            },
            .bytes => |continuation| {
                const end = @min(continuation.index + 256, continuation.source.len);
                try self.writeAll(writer, continuation.source[continuation.index..end]);
                if (end != continuation.source.len) {
                    try self.actions.push(.{ .bytes = .{ .source = continuation.source, .index = end } });
                }
            },
            .display_scan => |scan| try self.scanDisplaySequence(scan, writer),
            .spaces => |remaining| {
                const padding = [_]u8{' '} ** 256;
                const count = @min(remaining, padding.len);
                try self.writeAll(writer, padding[0..count]);
                if (count != remaining) try self.actions.push(.{ .spaces = remaining - count });
            },
        }
    }

    fn scanDisplaySequence(
        self: *RenderCursor,
        scan: DisplayScan,
        writer: *std.Io.Writer,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!void {
        const count: usize = @intCast(scan.collection.list.length());
        switch (scan.phase) {
            .matrix => {
                if (scan.outer_index == count) {
                    try self.finishDisplaySequence(scan, count != 0, writer);
                    return;
                }
                const row = list.atUnchecked(scan.collection, scan.outer_index);
                if (!isFlatRow(row) or
                    (scan.outer_index != 0 and row.list.length() != scan.columns))
                {
                    try self.actions.push(.{ .display_scan = .{
                        .collection = scan.collection,
                        .indent = scan.indent,
                        .phase = .matrix_group,
                    } });
                    return;
                }
                var next = scan;
                next.outer_index += 1;
                if (scan.outer_index == 0) next.columns = row.list.length();
                try self.actions.push(.{ .display_scan = next });
            },
            .matrix_group => {
                if (scan.outer_index == count) {
                    try self.finishDisplaySequence(scan, count != 0, writer);
                    return;
                }
                const matrix = list.atUnchecked(scan.collection, scan.outer_index);
                if (matrix != .list or
                    matrix.list.kind() != .generic_spine or
                    matrix.list.length() == 0)
                {
                    try self.finishDisplaySequence(scan, false, writer);
                    return;
                }
                const row_count: usize = @intCast(matrix.list.length());
                const row = list.atUnchecked(matrix, scan.inner_index);
                if (!isFlatRow(row) or
                    (scan.inner_index != 0 and row.list.length() != scan.columns))
                {
                    try self.finishDisplaySequence(scan, false, writer);
                    return;
                }
                var next = scan;
                next.inner_index += 1;
                if (scan.inner_index == 0) next.columns = row.list.length();
                if (next.inner_index == row_count) {
                    next.outer_index += 1;
                    next.inner_index = 0;
                    next.columns = 0;
                }
                try self.actions.push(.{ .display_scan = next });
            },
        }
    }

    fn finishDisplaySequence(
        self: *RenderCursor,
        scan: DisplayScan,
        multiline: bool,
        writer: *std.Io.Writer,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!void {
        try self.writeByte(writer, '(');
        try self.pushSequence(scan.collection, scan.indent, multiline);
    }

    fn pushSequence(
        self: *RenderCursor,
        collection: Value,
        indent: usize,
        multiline: bool,
    ) error{OutOfMemory}!void {
        try self.actions.push(.{ .sequence = .{
            .collection = collection,
            .index = 0,
            .indent = indent,
            .multiline = multiline,
        } });
    }

    fn pushBytes(self: *RenderCursor, bytes: []const u8) error{OutOfMemory}!void {
        if (bytes.len != 0) try self.actions.push(.{ .bytes = .{ .source = bytes, .index = 0 } });
    }

    fn writeByte(
        self: *RenderCursor,
        writer: *std.Io.Writer,
        byte: u8,
    ) std.Io.Writer.Error!void {
        try writer.writeByte(byte);
        self.column = if (byte == '\n') 0 else self.column + 1;
    }

    fn writeAll(
        self: *RenderCursor,
        writer: *std.Io.Writer,
        bytes: []const u8,
    ) std.Io.Writer.Error!void {
        try writer.writeAll(bytes);
        if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |last_newline|
            self.column = bytes.len - last_newline - 1
        else
            self.column += bytes.len;
    }

    fn writeFmt(
        self: *RenderCursor,
        writer: *std.Io.Writer,
        comptime format: []const u8,
        args: anytype,
    ) std.Io.Writer.Error!void {
        var buffer: [128]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&buffer);
        fixed.print(format, args) catch unreachable;
        try self.writeAll(writer, fixed.buffered());
    }
};

pub const OwnedStringProgress = poll_api.Progress([]u8);

/// Exact-size two-pass rendering state for scheduler drivers. No growable
/// writer is used in the cancellable path.
pub const OwnedStringCursor = struct {
    allocator: std.mem.Allocator,
    item: Value,
    cursor: RenderCursor,
    style: RenderStyle,
    initial_column: usize,
    phase: enum { count, fill, complete } = .count,
    byte_count: usize = 0,
    output: ?[]u8 = null,
    written: usize = 0,

    pub fn init(allocator: std.mem.Allocator, item: Value) error{OutOfMemory}!OwnedStringCursor {
        return initWithStyle(allocator, item, .canonical, 0);
    }

    pub fn initDisplay(allocator: std.mem.Allocator, item: Value) error{OutOfMemory}!OwnedStringCursor {
        return initWithStyle(allocator, item, .display, 0);
    }

    pub fn initDisplayAtColumn(
        allocator: std.mem.Allocator,
        item: Value,
        initial_column: usize,
    ) error{OutOfMemory}!OwnedStringCursor {
        return initWithStyle(allocator, item, .display, initial_column);
    }

    fn initWithStyle(
        allocator: std.mem.Allocator,
        item: Value,
        style: RenderStyle,
        initial_column: usize,
    ) error{OutOfMemory}!OwnedStringCursor {
        return .{
            .allocator = allocator,
            .item = item,
            .cursor = try RenderCursor.initWithStyle(allocator, item, style, initial_column),
            .style = style,
            .initial_column = initial_column,
        };
    }

    pub fn deinit(self: *OwnedStringCursor) void {
        self.cursor.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.* = undefined;
    }

    pub fn advance(
        self: *OwnedStringCursor,
        budget: usize,
    ) error{OutOfMemory}!OwnedStringProgress {
        std.debug.assert(budget != 0 and self.phase != .complete);
        switch (self.phase) {
            .count => {
                var buffer: [256]u8 = undefined;
                var counter = std.Io.Writer.Discarding.init(&buffer);
                const progress = self.cursor.advance(&counter.writer, budget) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
                const produced = std.math.cast(usize, counter.fullCount()) orelse
                    return error.OutOfMemory;
                self.byte_count = std.math.add(usize, self.byte_count, produced) catch
                    return error.OutOfMemory;
                if (progress == .pending) return .pending;
                var fill_cursor = try RenderCursor.initWithStyle(
                    self.allocator,
                    self.item,
                    self.style,
                    self.initial_column,
                );
                errdefer fill_cursor.deinit();
                const output = try self.allocator.alloc(u8, self.byte_count);
                self.cursor.deinit();
                self.cursor = fill_cursor;
                self.output = output;
                self.phase = .fill;
                return .pending;
            },
            .fill => {
                var fixed = std.Io.Writer.fixed(self.output.?[self.written..]);
                const progress = self.cursor.advance(&fixed, budget) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
                self.written += fixed.buffered().len;
                if (progress == .pending) return .pending;
                std.debug.assert(self.written == self.output.?.len);
                const result = self.output.?;
                self.output = null;
                self.phase = .complete;
                return .{ .complete = result };
            },
            .complete => unreachable,
        }
    }
};

/// One rendered stack item, described as the rectangle of rows it occupies.
/// `next_byte` is layout-cursor state: blocks are consumed top to bottom while
/// the stack itself remains ordered left to right.
pub const DisplayBlock = struct {
    text: []u8,
    width: usize,
    rows: usize,
    next_byte: usize = 0,
};

pub const DisplayMeasureProgress = poll_api.Progress(DisplayBlock);

/// Bounded measurement of one rendered display value.
pub const DisplayMeasureCursor = struct {
    text: []u8,
    index: usize = 0,
    row_start: usize = 0,
    width: usize = 0,
    rows: usize = 1,

    pub fn init(text: []u8) DisplayMeasureCursor {
        return .{ .text = text };
    }

    pub fn advance(
        self: *DisplayMeasureCursor,
        budget: usize,
    ) error{OutOfMemory}!DisplayMeasureProgress {
        std.debug.assert(budget != 0);
        const end = @min(self.index +| budget, self.text.len);
        while (self.index != end) : (self.index += 1) {
            if (self.text[self.index] != '\n') continue;
            self.width = @max(self.width, self.index - self.row_start);
            self.row_start = self.index + 1;
            self.rows = std.math.add(usize, self.rows, 1) catch return error.OutOfMemory;
        }
        if (self.index != self.text.len) return .pending;
        self.width = @max(self.width, self.text.len - self.row_start);
        return .{ .complete = .{
            .text = self.text,
            .width = self.width,
            .rows = self.rows,
        } };
    }
};

pub const StackLayoutProgress = poll_api.Progress(void);

/// Paste display blocks side by side, aligned on their bottom row. Each
/// transition examines or emits at most 256 bytes, so runtime words can drive
/// the same layout cooperatively while blocking observers may drive it to
/// completion.
pub const StackLayoutCursor = struct {
    blocks: []DisplayBlock,
    phase: enum { height, row_start, block, scan_row, spaces, bytes, complete } = .height,
    tallest: usize = 0,
    height_index: usize = 0,
    row_index: usize = 0,
    block_index: usize = 0,
    pending_spaces: usize = 0,
    row_start_byte: usize = 0,
    scan_index: usize = 0,
    row_end_byte: usize = 0,
    emit_index: usize = 0,

    pub fn init(blocks: []DisplayBlock) StackLayoutCursor {
        return .{ .blocks = blocks };
    }

    pub fn advance(
        self: *StackLayoutCursor,
        writer: *std.Io.Writer,
        budget: usize,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!StackLayoutProgress {
        std.debug.assert(budget != 0 and self.phase != .complete);
        for (0..budget) |_| {
            switch (self.phase) {
                .height => {
                    if (self.height_index == self.blocks.len) {
                        if (self.tallest == 0) {
                            self.phase = .complete;
                            return .complete;
                        }
                        self.phase = .row_start;
                        continue;
                    }
                    self.tallest = @max(self.tallest, self.blocks[self.height_index].rows);
                    self.height_index += 1;
                },
                .row_start => {
                    if (self.row_index != 0) try writer.writeByte('\n');
                    self.block_index = 0;
                    self.pending_spaces = 0;
                    self.phase = .block;
                },
                .block => {
                    if (self.block_index == self.blocks.len) {
                        self.row_index += 1;
                        if (self.row_index == self.tallest) {
                            self.phase = .complete;
                            return .complete;
                        }
                        self.phase = .row_start;
                        continue;
                    }
                    if (self.block_index != 0)
                        self.pending_spaces = std.math.add(usize, self.pending_spaces, 1) catch
                            return error.OutOfMemory;
                    const block = &self.blocks[self.block_index];
                    if (self.row_index < self.tallest - block.rows) {
                        self.pending_spaces = std.math.add(usize, self.pending_spaces, block.width) catch
                            return error.OutOfMemory;
                        self.block_index += 1;
                        continue;
                    }
                    self.row_start_byte = block.next_byte;
                    self.scan_index = block.next_byte;
                    self.phase = .scan_row;
                },
                .scan_row => {
                    const block = &self.blocks[self.block_index];
                    const scan_end = @min(self.scan_index +| 256, block.text.len);
                    if (std.mem.indexOfScalar(u8, block.text[self.scan_index..scan_end], '\n')) |relative| {
                        self.finishRow(block, self.scan_index + relative, true) catch
                            return error.OutOfMemory;
                        continue;
                    }
                    self.scan_index = scan_end;
                    if (scan_end == block.text.len)
                        self.finishRow(block, scan_end, false) catch return error.OutOfMemory;
                },
                .spaces => {
                    const padding = [_]u8{' '} ** 256;
                    const count = @min(self.pending_spaces, padding.len);
                    try writer.writeAll(padding[0..count]);
                    self.pending_spaces -= count;
                    if (self.pending_spaces == 0) self.phase = .bytes;
                },
                .bytes => {
                    const count = @min(self.row_end_byte - self.emit_index, 256);
                    try writer.writeAll(self.blocks[self.block_index].text[self.emit_index..][0..count]);
                    self.emit_index += count;
                    if (self.emit_index == self.row_end_byte) {
                        const block = self.blocks[self.block_index];
                        self.pending_spaces = std.math.add(
                            usize,
                            self.pending_spaces,
                            block.width - (self.row_end_byte - self.row_start_byte),
                        ) catch return error.OutOfMemory;
                        self.block_index += 1;
                        self.phase = .block;
                    }
                },
                .complete => unreachable,
            }
        }
        return .pending;
    }

    fn finishRow(
        self: *StackLayoutCursor,
        block: *DisplayBlock,
        end: usize,
        has_newline: bool,
    ) error{OutOfMemory}!void {
        block.next_byte = end + @intFromBool(has_newline);
        self.row_end_byte = end;
        if (end == self.row_start_byte) {
            self.pending_spaces = std.math.add(usize, self.pending_spaces, block.width) catch
                return error.OutOfMemory;
            self.block_index += 1;
            self.phase = .block;
            return;
        }
        self.emit_index = self.row_start_byte;
        self.phase = if (self.pending_spaces == 0) .bytes else .spaces;
    }
};

pub fn measureDisplayBlock(text: []u8) error{OutOfMemory}!DisplayBlock {
    var cursor = DisplayMeasureCursor.init(text);
    return poll_api.driveFallible(DisplayBlock, &cursor, .{1024});
}

pub fn toOwnedStackDisplayString(
    allocator: std.mem.Allocator,
    blocks: []DisplayBlock,
) error{OutOfMemory}![]u8 {
    var count_buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&count_buffer);
    var count_cursor = StackLayoutCursor.init(blocks);
    while (true) switch (count_cursor.advance(&counter.writer, 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
    }) {
        .pending => {},
        .complete => break,
    };
    const byte_count = std.math.cast(usize, counter.fullCount()) orelse
        return error.OutOfMemory;
    for (blocks) |*block| block.next_byte = 0;

    const output = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(output);
    var fixed = std.Io.Writer.fixed(output);
    var fill_cursor = StackLayoutCursor.init(blocks);
    while (true) switch (fill_cursor.advance(&fixed, 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => unreachable,
    }) {
        .pending => {},
        .complete => {
            std.debug.assert(fixed.buffered().len == output.len);
            return output;
        },
    };
}

pub fn print(item: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    printWithAllocator(std.heap.smp_allocator, item, writer) catch |err| switch (err) {
        error.OutOfMemory => return error.WriteFailed,
        error.WriteFailed => return error.WriteFailed,
    };
}

pub fn printWithAllocator(
    allocator: std.mem.Allocator,
    item: Value,
    writer: *std.Io.Writer,
) (error{OutOfMemory} || std.Io.Writer.Error)!void {
    var cursor = try RenderCursor.init(allocator, item);
    defer cursor.deinit();
    return poll_api.driveVoidFallible(&cursor, .{ writer, 1024 });
}

pub fn toOwnedString(
    allocator: std.mem.Allocator,
    item: Value,
) error{OutOfMemory}![]u8 {
    var cursor = try OwnedStringCursor.init(allocator, item);
    defer cursor.deinit();
    return poll_api.driveFallible([]u8, &cursor, .{1024});
}

pub fn toOwnedDisplayString(
    allocator: std.mem.Allocator,
    item: Value,
) error{OutOfMemory}![]u8 {
    var cursor = try OwnedStringCursor.initDisplay(allocator, item);
    defer cursor.deinit();
    return poll_api.driveFallible([]u8, &cursor, .{1024});
}

/// Display dictionaries stay compact when they are small scalar records.
/// Larger records, and records containing structural values, break one pair
/// per line. The bounded size test means this decision never hides a
/// user-sized traversal inside one rendering transition.
fn displayDictionaryMultiline(header: *value.DictHandle) bool {
    const count: usize = @intCast(header.length());
    if (count > 3) return true;
    for (0..count) |index| {
        if (isDisplayStructure(dict.keyAt(header, index)) or
            isDisplayStructure(dict.valueAt(header, index))) return true;
    }
    return false;
}

fn isDisplayStructure(item: Value) bool {
    return switch (item) {
        .dict => true,
        .list => displayListIsMatrix(item),
        .int, .float, .char, .symbol, .word, .task, .module => false,
    };
}

/// Match the first matrix case recognized by `DisplayScan`. The display limit
/// is also the scan bound, so deciding a dictionary layout remains one fixed
/// amount of work even when a list is user-sized.
fn displayListIsMatrix(item: Value) bool {
    if (item.list.kind() != .generic_spine or
        item.list.length() == 0 or
        item.list.length() > display_list_limit) return false;
    var columns: u64 = 0;
    for (0..@as(usize, @intCast(item.list.length()))) |index| {
        const row = list.atUnchecked(item, index);
        if (!isFlatRow(row) or (index != 0 and row.list.length() != columns))
            return false;
        if (index == 0) columns = row.list.length();
    }
    return true;
}

fn isFlatRow(item: Value) bool {
    if (item != .list) return false;
    return switch (item.list.kind()) {
        .leaf_u8, .leaf_i64, .leaf_f64, .leaf_symbol => true,
        .leaf_char1, .leaf_char2, .leaf_char4, .generic_spine, .dict, .task, .module, .reserved_mask => false,
    };
}

fn writeFloat(cursor: *RenderCursor, number: f64, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.math.isNan(number)) return cursor.writeAll(writer, "nan");
    if (std.math.isInf(number)) {
        return cursor.writeAll(writer, if (number < 0) "-inf" else "inf");
    }
    var buffer: [128]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    fixed.print("{}", .{number}) catch unreachable;
    const rendered = fixed.buffered();
    try cursor.writeAll(writer, rendered);
    if (std.mem.indexOfAny(u8, rendered, ".eE") == null) try cursor.writeAll(writer, ".0");
}

fn writeChar(cursor: *RenderCursor, codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try cursor.writeByte(writer, '\\');
    switch (codepoint) {
        ' ' => return cursor.writeAll(writer, "space"),
        '\t' => return cursor.writeAll(writer, "tab"),
        '\n' => return cursor.writeAll(writer, "newline"),
        else => {},
    }
    if (isControl(codepoint) or codepoint == '\\' or codepoint == '\'' or codepoint == '"') {
        return cursor.writeFmt(writer, "u{{{x}}}", .{codepoint});
    }
    return writeCodepoint(cursor, codepoint, writer);
}

fn writeStringCodepoint(cursor: *RenderCursor, codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (codepoint) {
        '\\' => try cursor.writeAll(writer, "\\\\"),
        '"' => try cursor.writeAll(writer, "\\\""),
        '\n' => try cursor.writeAll(writer, "\\n"),
        '\t' => try cursor.writeAll(writer, "\\t"),
        else => if (isControl(codepoint) or !isScalar(codepoint)) {
            try cursor.writeFmt(writer, "\\u{{{x}}}", .{codepoint});
        } else {
            try writeCodepoint(cursor, codepoint, writer);
        },
    }
}

fn writeCodepoint(cursor: *RenderCursor, codepoint: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const scalar = value.unicodeScalar(codepoint) orelse
        return cursor.writeFmt(writer, "u{{{x}}}", .{codepoint});
    var encoded: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(scalar, &encoded) catch
        @panic("validated Unicode scalar failed UTF-8 encoding");
    try cursor.writeAll(writer, encoded[0..count]);
}

fn isControl(codepoint: u32) bool {
    return codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f);
}

fn isScalar(codepoint: u32) bool {
    return value.unicodeScalar(codepoint) != null;
}

fn expectPrint(expected: []const u8, item: Value) !void {
    const actual = try toOwnedString(std.testing.allocator, item);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "canonical printer renders the public value syntax" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const plus = try intern.intern("+");
    const sym = try intern.intern("sym");
    try expectPrint("2.0", .{ .float = 2.0 });
    try expectPrint("-0.0", .{ .float = -0.0 });
    try expectPrint("0.125", .{ .float = 0.125 });
    try expectPrint("inf", .{ .float = std.math.inf(f64) });
    try expectPrint("-inf", .{ .float = -std.math.inf(f64) });
    try expectPrint("'sym", .{ .symbol = sym });
    try expectPrint("sym", .{ .word = sym });

    const integers = try list.fromValues(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer cleanup.releaseValue(integers);
    try expectPrint("[1 2]", integers);
    const quotation = try list.fromValues(allocator, &.{ .{ .int = 1 }, .{ .word = plus } });
    defer cleanup.releaseValue(quotation);
    try expectPrint("(1 +)", quotation);
    const singleton = try list.fromValues(allocator, &.{.{ .int = 3 }});
    defer cleanup.releaseValue(singleton);
    const nested = try list.fromValues(allocator, &.{ integers, singleton });
    defer cleanup.releaseValue(nested);
    try expectPrint("([1 2] [3])", nested);
    const string = try list.fromValues(allocator, &.{ .{ .char = 'a' }, .{ .char = 'b' } });
    defer cleanup.releaseValue(string);
    try expectPrint("\"ab\"", string);
    const empty_string = try list.fromCodepoints(allocator, &.{});
    defer cleanup.releaseValue(empty_string);
    try expectPrint("\"\"", empty_string);

    const a = try intern.intern("a");
    const dictionary = try dict.fromPairs(allocator, cleanup.domain(), &.{.{ .{ .symbol = a }, .{ .int = 1 } }});
    defer cleanup.releaseValue(dictionary);
    try expectPrint("{'a 1}", dictionary);
}

test "char and string escapes follow the grammar" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    try expectPrint("\\space", .{ .char = ' ' });
    try expectPrint("\\tab", .{ .char = '\t' });
    try expectPrint("\\newline", .{ .char = '\n' });
    try expectPrint("\\u{5c}", .{ .char = '\\' });
    const string = try list.fromValues(allocator, &.{
        .{ .char = '"' },
        .{ .char = '\n' },
        .{ .char = '\\' },
    });
    defer cleanup.releaseValue(string);
    try expectPrint("\"\\\"\\n\\\\\"", string);
}

test "display rendering elides huge leaves without changing canonical strings" {
    const allocator = std.testing.allocator;
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();

    var integers: [display_list_limit + 1]i64 = undefined;
    for (&integers, 0..) |*item, index| item.* = @intCast(index);
    const leaf = try list.fromI64Slice(allocator, &integers);
    defer cleanup.releaseValue(leaf);

    const displayed = try toOwnedDisplayString(allocator, leaf);
    defer allocator.free(displayed);
    try std.testing.expectEqualStrings("[<257-values-elided>]", displayed);

    const canonical = try toOwnedString(allocator, leaf);
    defer allocator.free(canonical);
    try std.testing.expect(std.mem.startsWith(u8, canonical, "[0 1 2"));
    try std.testing.expect(std.mem.endsWith(u8, canonical, "255 256]"));

    var codepoints: [display_list_limit + 1]u32 = @splat('x');
    const string = try list.fromCodepoints(allocator, &codepoints);
    defer cleanup.releaseValue(string);
    const displayed_string = try toOwnedDisplayString(allocator, string);
    defer allocator.free(displayed_string);
    try std.testing.expectEqualStrings("\"<257-characters-elided>\"", displayed_string);
    const canonical_string = try toOwnedString(allocator, string);
    defer allocator.free(canonical_string);
    try std.testing.expectEqual(@as(usize, codepoints.len + 2), canonical_string.len);
}

test "deep rendering uses an explicit worklist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    var current = Value{ .int = 1 };
    for (0..100_000) |_| {
        const next = try list.fromValuesGeneric(allocator, &.{current});
        if (current.heapHeader()) |_| cleanup.releaseValue(current);
        current = next;
    }
    defer cleanup.releaseValue(current);
    const rendered = try toOwnedString(allocator, current);
    defer allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 200_001), rendered.len);
    try std.testing.expectEqual(@as(u8, '('), rendered[0]);
    try std.testing.expectEqual(@as(u8, ')'), rendered[rendered.len - 1]);
}
