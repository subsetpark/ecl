//! Canonical prose normalization for reflective definition documentation.
//!
//! Prose paragraphs fold into one line and bullets into one line each. A
//! paragraph with no bullets whose lines do not all start at one column is
//! laid out by hand, such as an example, and keeps its lines and their
//! indentation past the margin. A first line beside the opening quote has no
//! column of its own and does not count.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const poll = @import("poll.zig");

const Value = value.Value;

const Line = struct {
    start: usize,
    end: usize,
    leading: usize,
    blank: bool,
    /// Set on a paragraph's first line when the paragraph keeps its lines.
    verbatim: bool = false,
};

const Kind = enum { prose, bullet };

pub const NormalizeProgress = poll.Progress(Value);

pub fn normalize(
    allocator: std.mem.Allocator,
    document: Value,
) error{OutOfMemory}!Value {
    var cursor = try NormalizeCursor.init(allocator, document);
    defer cursor.deinit();
    var work = poll.unbounded();
    return poll.driveFallible(Value, &cursor, .{&work});
}

/// The codepoints normalization reads: a string value, or text a caller has
/// already decoded.
pub const Text = union(enum) {
    string: Value,
    codepoints: []const u32,

    fn len(self: Text) usize {
        return switch (self) {
            .string => |item| @intCast(item.list.length()),
            .codepoints => |items| items.len,
        };
    }
    fn at(self: Text, index: usize) u32 {
        return switch (self) {
            .string => |item| list.atUnchecked(item, index).char,
            .codepoints => |items| items[index],
        };
    }
};

/// Normalization as a string value: the codepoint normalization, then one
/// polled materialization of its result.
pub const NormalizeCursor = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    normalizer: CodepointNormalizer,
    output: ?[]u32 = null,
    materializer: ?list.CodepointMaterializer = null,

    pub fn init(allocator: std.mem.Allocator, document: Value) error{OutOfMemory}!NormalizeCursor {
        std.debug.assert(document.isString());
        return .{ .normalizer = try .init(allocator, .{ .string = document }) };
    }

    pub fn deinit(self: *NormalizeCursor) void {
        if (self.materializer) |*materializer| materializer.deinit();
        if (self.output) |output| self.normalizer.allocator.free(output);
        self.normalizer.deinit();
        self.* = undefined;
    }

    pub fn retire(self: *NormalizeCursor, releases: *heap.ReleaseDomain) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        if (self.output) |output| self.normalizer.allocator.free(output);
        self.normalizer.deinit();
    }

    pub fn advance(self: *NormalizeCursor, work: *poll.WorkBudget) error{OutOfMemory}!NormalizeProgress {
        if (self.materializer == null) switch (try self.normalizer.advance(work)) {
            .pending => return .pending,
            .complete => |output| {
                self.output = output;
                self.materializer = .init(self.normalizer.allocator, output);
            },
        };
        return switch (try self.materializer.?.advance(work)) {
            .pending => .pending,
            .complete => |result| .{ .complete = result },
        };
    }
};

/// Resumable two-pass documentation normalization to codepoints. Line
/// discovery, margin selection, collapsed rendering, and the exact output
/// fill all keep their next position in this owned state.
pub const CodepointNormalizer = struct {
    allocator: std.mem.Allocator,
    text: Text,
    lines: []Line,
    line_count: usize = 0,
    phase: enum { scan, bounds, classify, render_count, render_fill, complete } = .scan,
    source_index: usize = 0,
    line_start: usize = 0,
    leading: usize = 0,
    seen_content: bool = false,
    last_content_end: usize = 0,
    bounds_index: usize = 0,
    content_start: usize = 0,
    content_end: usize = 0,
    margin: ?usize = null,
    classify_index: usize = 0,
    paragraph_first: ?usize = null,
    paragraph_column: ?usize = null,
    paragraph_ragged: bool = false,
    paragraph_bulleted: bool = false,
    render_line: usize = 0,
    render_mode: enum { idle, bullet_trim, content, verbatim_pad, verbatim } = .idle,
    render_index: usize = 0,
    render_end: usize = 0,
    render_pad: usize = 0,
    paragraph_start: bool = true,
    in_verbatim: bool = false,
    pending_space: bool = false,
    emitted: bool = false,
    pending_blank: bool = false,
    previous: Kind = .prose,
    current: Kind = .prose,
    queue: [3]u32 = @splat(0),
    queue_index: usize = 0,
    queue_len: usize = 0,
    output_count: usize = 0,
    output: ?[]u32 = null,
    output_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, text: Text) error{OutOfMemory}!CodepointNormalizer {
        return .{
            .allocator = allocator,
            .text = text,
            .lines = try allocator.alloc(Line, text.len() + 1),
        };
    }

    /// Frees the cursor's state, and its output unless `advance` returned it.
    pub fn deinit(self: *CodepointNormalizer) void {
        if (self.output) |output| self.allocator.free(output);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    /// The normalized codepoints, owned by the caller, once done.
    pub fn advance(self: *CodepointNormalizer, work: *poll.WorkBudget) error{OutOfMemory}!poll.Progress([]u32) {
        while (true) {
            if (self.phase == .complete) {
                const output = self.output.?;
                self.output = null;
                return .{ .complete = output };
            }
            if (!work.spend()) return .pending;
            switch (self.phase) {
                .scan => self.scanOne(),
                .bounds => self.boundOne(),
                .classify => self.classifyOne(),
                .render_count, .render_fill => try self.renderOne(),
                .complete => unreachable,
            }
        }
    }

    fn scanOne(self: *CodepointNormalizer) void {
        const count = self.text.len();
        if (self.source_index == count) {
            self.finishLine(count);
            self.phase = .bounds;
            return;
        }
        const codepoint = self.text.at(self.source_index);
        if (isLineBreak(codepoint)) {
            const raw_end = self.source_index;
            self.source_index += if (codepoint == '\r' and self.source_index + 1 < count and
                self.text.at(self.source_index + 1) == '\n') 2 else 1;
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

    fn finishLine(self: *CodepointNormalizer, raw_end: usize) void {
        self.lines[self.line_count] = .{
            .start = self.line_start,
            .end = if (self.seen_content) self.last_content_end else raw_end,
            .leading = self.leading,
            .blank = !self.seen_content,
        };
        self.line_count += 1;
    }

    fn boundOne(self: *CodepointNormalizer) void {
        if (self.bounds_index == self.line_count) {
            self.content_end = self.bounds_index;
            while (self.content_end > self.content_start and self.lines[self.content_end - 1].blank)
                self.content_end -= 1;
            self.classify_index = self.content_start;
            self.phase = .classify;
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

    fn classifyOne(self: *CodepointNormalizer) void {
        if (self.classify_index == self.content_end) {
            self.closeParagraph();
            self.resetRender();
            self.phase = .render_count;
            return;
        }
        const index = self.classify_index;
        self.classify_index += 1;
        const line = self.lines[index];
        if (line.blank) return self.closeParagraph();
        if (self.paragraph_first == null) {
            self.paragraph_first = index;
            self.paragraph_column = null;
            self.paragraph_ragged = false;
            self.paragraph_bulleted = false;
        }
        if (isBullet(self.text, line.start + line.leading, line.end))
            self.paragraph_bulleted = true;
        if (index == 0 and line.start == 0) return;
        if (self.paragraph_column) |column| {
            if (column != line.leading) self.paragraph_ragged = true;
        } else self.paragraph_column = line.leading;
    }

    fn closeParagraph(self: *CodepointNormalizer) void {
        const first = self.paragraph_first orelse return;
        self.lines[first].verbatim = self.paragraph_ragged and !self.paragraph_bulleted;
        self.paragraph_first = null;
    }

    /// Indentation a line keeps past the margin. The first line, when it opens
    /// the string, sits beside the quote and keeps none.
    fn remainingIndent(self: *const CodepointNormalizer, index: usize) usize {
        const line = self.lines[index];
        const removed = if (index == 0 and line.start == 0)
            line.leading
        else
            @min(line.leading, self.margin orelse 0);
        return line.leading - removed;
    }

    fn resetRender(self: *CodepointNormalizer) void {
        self.render_line = self.content_start;
        self.render_mode = .idle;
        self.paragraph_start = true;
        self.in_verbatim = false;
        self.pending_space = false;
        self.emitted = false;
        self.pending_blank = false;
        self.previous = .prose;
        self.queue_index = 0;
        self.queue_len = 0;
    }

    fn emit(self: *CodepointNormalizer, codepoint: u32) error{OutOfMemory}!void {
        if (self.output) |output| output[self.output_index] = codepoint;
        self.output_index = std.math.add(usize, self.output_index, 1) catch return error.OutOfMemory;
    }

    fn enqueue(self: *CodepointNormalizer, items: []const u32) void {
        std.debug.assert(self.queue_len == self.queue_index and items.len <= self.queue.len);
        @memcpy(self.queue[0..items.len], items);
        self.queue_index = 0;
        self.queue_len = items.len;
    }

    fn finishRenderedLine(self: *CodepointNormalizer) void {
        self.emitted = true;
        self.pending_blank = false;
        self.previous = self.current;
        self.render_line += 1;
        self.render_mode = .idle;
        self.pending_space = false;
    }

    fn renderOne(self: *CodepointNormalizer) error{OutOfMemory}!void {
        if (self.queue_index != self.queue_len) {
            try self.emit(self.queue[self.queue_index]);
            self.queue_index += 1;
            return;
        }
        if (self.render_mode == .bullet_trim) {
            if (self.render_index == self.render_end) {
                self.finishRenderedLine();
            } else if (isHorizontal(self.text.at(self.render_index))) {
                self.render_index += 1;
            } else {
                self.render_mode = .content;
                self.enqueue(&.{' '});
            }
            return;
        }
        if (self.render_mode == .verbatim_pad) {
            if (self.render_pad == 0) {
                self.render_mode = .verbatim;
            } else {
                self.render_pad -= 1;
                try self.emit(' ');
            }
            return;
        }
        if (self.render_mode == .verbatim) {
            if (self.render_index == self.render_end) {
                self.finishRenderedLine();
            } else {
                try self.emit(self.text.at(self.render_index));
                self.render_index += 1;
            }
            return;
        }
        if (self.render_mode == .content) {
            if (self.render_index == self.render_end) {
                self.finishRenderedLine();
                return;
            }
            const codepoint = self.text.at(self.render_index);
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
                self.phase = .complete;
            }
            return;
        }
        const line = self.lines[self.render_line];
        if (line.blank) {
            if (self.emitted) self.pending_blank = true;
            self.paragraph_start = true;
            self.render_line += 1;
            return;
        }
        if (self.paragraph_start) {
            self.in_verbatim = line.verbatim;
            self.paragraph_start = false;
        }
        const remaining_indent = self.remainingIndent(self.render_line);
        const start = line.start + line.leading - remaining_indent;
        const item_start = line.start + line.leading;
        if (self.in_verbatim) {
            self.current = .prose;
            if (self.emitted) {
                if (self.pending_blank) self.enqueue(&.{ '\n', '\n' }) else self.enqueue(&.{'\n'});
            }
            self.render_end = line.end;
            self.render_index = item_start;
            self.render_pad = remaining_indent;
            self.render_mode = .verbatim_pad;
            return;
        }
        const bullet = isBullet(self.text, item_start, line.end);
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

fn isBullet(text: Text, start: usize, end: usize) bool {
    return start < end and text.at(start) == '-' and
        (start + 1 == end or isHorizontal(text.at(start + 1)));
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
