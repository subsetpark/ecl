//! Canonical prose normalization for reflective definition documentation.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;

const Line = struct {
    start: usize,
    end: usize,
    leading: usize,
    blank: bool,
};

const Kind = enum { prose, bullet };

pub const NormalizeProgress = union(enum) { pending, complete: Value };

pub fn normalize(
    allocator: std.mem.Allocator,
    document: Value,
) error{OutOfMemory}!Value {
    var cursor = try NormalizeCursor.init(allocator, document);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(1024)) {
        .pending => {},
        .complete => |result| return result,
    };
}

/// Resumable two-pass documentation normalization. Line discovery, margin
/// selection, collapsed rendering, and exact string materialization all keep
/// their next position in this owned state.
pub const NormalizeCursor = struct {
    allocator: std.mem.Allocator,
    document: Value,
    lines: []Line,
    line_count: usize = 0,
    phase: enum { scan, bounds, render_count, render_fill, materialize } = .scan,
    source_index: usize = 0,
    line_start: usize = 0,
    leading: usize = 0,
    seen_content: bool = false,
    last_content_end: usize = 0,
    bounds_index: usize = 0,
    content_start: usize = 0,
    content_end: usize = 0,
    margin: ?usize = null,
    render_line: usize = 0,
    render_mode: enum { idle, bullet_trim, content } = .idle,
    render_index: usize = 0,
    render_end: usize = 0,
    pending_space: bool = false,
    emitted: bool = false,
    pending_blank: bool = false,
    previous: Kind = .prose,
    current: Kind = .prose,
    queue: [3]u32 = .{0} ** 3,
    queue_index: usize = 0,
    queue_len: usize = 0,
    output_count: usize = 0,
    output: ?[]u32 = null,
    output_index: usize = 0,
    materializer: ?storage.CodepointMaterializer = null,

    pub fn init(allocator: std.mem.Allocator, document: Value) error{OutOfMemory}!NormalizeCursor {
        std.debug.assert(document.isString());
        const count: usize = @intCast(document.list.length());
        return .{
            .allocator = allocator,
            .document = document,
            .lines = try allocator.alloc(Line, count + 1),
        };
    }

    pub fn deinit(self: *NormalizeCursor) void {
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn retire(self: *NormalizeCursor, releases: *heap.ReleaseDomain) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        if (self.output) |output| self.allocator.free(output);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn advance(self: *NormalizeCursor, budget: usize) error{OutOfMemory}!NormalizeProgress {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) switch (self.phase) {
            .scan => self.scanOne(),
            .bounds => self.boundOne(),
            .render_count, .render_fill => try self.renderOne(),
            .materialize => return switch (try self.materializer.?.advance(remaining)) {
                .pending => .pending,
                .complete => |result| .{ .complete = result },
            },
        };
        return .pending;
    }

    fn scanOne(self: *NormalizeCursor) void {
        const count: usize = @intCast(self.document.list.length());
        if (self.source_index == count) {
            self.finishLine(count);
            self.phase = .bounds;
            return;
        }
        const codepoint = at(self.document, self.source_index);
        if (isLineBreak(codepoint)) {
            const raw_end = self.source_index;
            self.source_index += if (codepoint == '\r' and self.source_index + 1 < count and
                at(self.document, self.source_index + 1) == '\n') 2 else 1;
            self.finishLine(raw_end);
            self.line_start = self.source_index;
            self.leading = 0;
            self.seen_content = false;
            self.last_content_end = self.source_index;
        } else {
            if (isHorizontal(codepoint)) {
                if (!self.seen_content) self.leading += 1;
            } else {
                self.seen_content = true;
                self.last_content_end = self.source_index + 1;
            }
            self.source_index += 1;
        }
    }

    fn finishLine(self: *NormalizeCursor, raw_end: usize) void {
        self.lines[self.line_count] = .{
            .start = self.line_start,
            .end = if (self.seen_content) self.last_content_end else raw_end,
            .leading = self.leading,
            .blank = !self.seen_content,
        };
        self.line_count += 1;
    }

    fn boundOne(self: *NormalizeCursor) void {
        if (self.bounds_index == self.line_count) {
            self.content_end = self.bounds_index;
            while (self.content_end > self.content_start and self.lines[self.content_end - 1].blank)
                self.content_end -= 1;
            self.resetRender();
            self.phase = .render_count;
            return;
        }
        const line = self.lines[self.bounds_index];
        if (!line.blank) {
            if (self.bounds_index != 0)
                self.margin = @min(self.margin orelse line.leading, line.leading);
        } else if (self.content_start == self.bounds_index) {
            self.content_start += 1;
        }
        self.bounds_index += 1;
    }

    fn resetRender(self: *NormalizeCursor) void {
        self.render_line = self.content_start;
        self.render_mode = .idle;
        self.pending_space = false;
        self.emitted = false;
        self.pending_blank = false;
        self.previous = .prose;
        self.queue_index = 0;
        self.queue_len = 0;
    }

    fn emit(self: *NormalizeCursor, codepoint: u32) error{OutOfMemory}!void {
        if (self.output) |output| output[self.output_index] = codepoint;
        self.output_index = std.math.add(usize, self.output_index, 1) catch return error.OutOfMemory;
    }

    fn enqueue(self: *NormalizeCursor, items: []const u32) void {
        std.debug.assert(self.queue_len == self.queue_index and items.len <= self.queue.len);
        @memcpy(self.queue[0..items.len], items);
        self.queue_index = 0;
        self.queue_len = items.len;
    }

    fn finishRenderedLine(self: *NormalizeCursor) void {
        self.emitted = true;
        self.pending_blank = false;
        self.previous = self.current;
        self.render_line += 1;
        self.render_mode = .idle;
        self.pending_space = false;
    }

    fn renderOne(self: *NormalizeCursor) error{OutOfMemory}!void {
        if (self.queue_index != self.queue_len) {
            try self.emit(self.queue[self.queue_index]);
            self.queue_index += 1;
            return;
        }
        if (self.render_mode == .bullet_trim) {
            if (self.render_index == self.render_end) {
                self.finishRenderedLine();
            } else if (isHorizontal(at(self.document, self.render_index))) {
                self.render_index += 1;
            } else {
                self.render_mode = .content;
                self.enqueue(&.{' '});
            }
            return;
        }
        if (self.render_mode == .content) {
            if (self.render_index == self.render_end) {
                self.finishRenderedLine();
                return;
            }
            const codepoint = at(self.document, self.render_index);
            self.render_index += 1;
            if (isHorizontal(codepoint)) {
                self.pending_space = self.output_index > 0;
            } else {
                if (self.pending_space) self.enqueue(&.{ ' ', codepoint }) else self.enqueue(&.{codepoint});
                self.pending_space = false;
            }
            return;
        }
        if (self.render_line == self.content_end) {
            if (self.phase == .render_count) {
                self.output_count = self.output_index;
                self.output = try self.allocator.alloc(u32, self.output_count);
                self.output_index = 0;
                self.resetRender();
                self.phase = .render_fill;
            } else {
                std.debug.assert(self.output_index == self.output_count);
                self.materializer = .init(self.allocator, self.output.?);
                self.phase = .materialize;
            }
            return;
        }
        const line = self.lines[self.render_line];
        if (line.blank) {
            if (self.emitted) self.pending_blank = true;
            self.render_line += 1;
            return;
        }
        const removed = if (self.render_line == 0 and line.start == 0)
            line.leading
        else
            @min(line.leading, self.margin orelse 0);
        const start = line.start + removed;
        const remaining_indent = line.leading - removed;
        const item_start = line.start + line.leading;
        const bullet = isBullet(self.document, item_start, line.end);
        self.current = if (bullet) .bullet else if (self.previous == .bullet and remaining_indent > 0)
            .bullet
        else
            .prose;
        if (self.emitted) {
            if (self.pending_blank)
                self.enqueue(&.{ '\n', '\n' })
            else if (bullet or (self.previous == .bullet and self.current == .prose))
                self.enqueue(&.{'\n'})
            else
                self.enqueue(&.{' '});
        }
        self.render_end = line.end;
        if (bullet) {
            if (self.queue_len == self.queue_index) self.enqueue(&.{'-'}) else {
                self.queue[self.queue_len] = '-';
                self.queue_len += 1;
            }
            self.render_index = item_start + 1;
            self.render_mode = .bullet_trim;
        } else {
            self.render_index = @max(start, item_start);
            self.render_mode = .content;
        }
    }
};

fn isBullet(document: Value, start: usize, end: usize) bool {
    return start < end and at(document, start) == '-' and
        (start + 1 == end or isHorizontal(at(document, start + 1)));
}

fn at(document: Value, index: usize) u32 {
    return list.atUnchecked(document, index).char;
}

fn isHorizontal(codepoint: u32) bool {
    return lexer.isWhitespace(@intCast(codepoint)) and !isLineBreak(codepoint);
}

fn isLineBreak(codepoint: u32) bool {
    return switch (codepoint) {
        '\n', '\r', 0x0085, 0x2028, 0x2029 => true,
        else => false,
    };
}
