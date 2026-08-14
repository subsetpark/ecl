//! Canonical prose normalization for reflective definition documentation.
const std = @import("std");
const value = @import("value.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const poll = @import("poll.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;

const Line = struct {
    start: usize,
    end: usize,
    leading: usize,
    blank: bool,
};

const Kind = enum { prose, bullet };

const Sink = struct {
    output: ?[]u32,
    len: usize = 0,

    fn append(self: *Sink, codepoint: u32) error{OutOfMemory}!void {
        if (self.output) |items| items[self.len] = codepoint;
        self.len = std.math.add(usize, self.len, 1) catch return error.OutOfMemory;
    }
};

/// Returns a newly owned canonical string. Physical prose wrapping and source
/// indentation do not survive; paragraph and Markdown-bullet structure does.
pub fn normalize(
    allocator: std.mem.Allocator,
    document: Value,
    poller: poll.Poller,
) poll.Error!Value {
    std.debug.assert(document.isString());
    const work = poll.WorkContext.init(poller);
    const line_count = try countLines(document, work);
    const lines = try allocator.alloc(Line, line_count);
    defer allocator.free(lines);
    try collectLines(document, lines, work);

    const bounds = try contentBounds(lines, work);
    if (bounds.start == bounds.end) return storage.fromCodepoints(allocator, &.{}, poller);
    const margin = try commonMargin(lines, bounds.start, bounds.end, work);

    var measured: Sink = .{ .output = null };
    try render(document, lines[bounds.start..bounds.end], margin, &measured, work);
    const codepoints = try allocator.alloc(u32, measured.len);
    defer allocator.free(codepoints);
    var written: Sink = .{ .output = codepoints };
    try render(document, lines[bounds.start..bounds.end], margin, &written, work);
    std.debug.assert(written.len == codepoints.len);
    return storage.fromCodepoints(allocator, codepoints, poller);
}

fn countLines(document: Value, work: poll.WorkContext) poll.Error!usize {
    const count: usize = @intCast(document.list.length());
    var lines: usize = 1;
    var indices = work.indices(0, count);
    while (try indices.next()) |index| {
        const codepoint = at(document, index);
        if (isLineBreak(codepoint)) {
            lines = std.math.add(usize, lines, 1) catch return error.OutOfMemory;
            if (codepoint == '\r' and index + 1 < count and at(document, index + 1) == '\n') {
                indices.skip(1);
            }
        }
    }
    return lines;
}

fn collectLines(document: Value, lines: []Line, work: poll.WorkContext) poll.Error!void {
    const count: usize = @intCast(document.list.length());
    var line_index: usize = 0;
    var start: usize = 0;
    var indices = work.indices(0, count);
    while (try indices.next()) |index| {
        const codepoint = at(document, index);
        if (!isLineBreak(codepoint)) continue;
        lines[line_index] = try inspectLine(document, start, index, work);
        line_index += 1;
        if (codepoint == '\r' and index + 1 < count and at(document, index + 1) == '\n') {
            indices.skip(1);
        }
        start = indices.index;
    }
    lines[line_index] = try inspectLine(document, start, count, work);
    std.debug.assert(line_index + 1 == lines.len);
}

fn inspectLine(document: Value, start: usize, raw_end: usize, work: poll.WorkContext) poll.Error!Line {
    var leading = start;
    var forward = work.indices(start, raw_end);
    while (try forward.next()) |index| {
        if (!isHorizontal(at(document, index))) break;
        leading = index + 1;
    }
    var end = raw_end;
    var reverse = work.reverseIndices(leading, raw_end);
    while (try reverse.next()) |index| {
        if (!isHorizontal(at(document, index))) break;
        end = index;
    }
    return .{
        .start = start,
        .end = end,
        .leading = leading - start,
        .blank = leading == raw_end,
    };
}

fn contentBounds(lines: []const Line, work: poll.WorkContext) poll.Error!struct { start: usize, end: usize } {
    var start: usize = 0;
    var forward = work.indices(0, lines.len);
    while (try forward.next()) |index| {
        if (!lines[index].blank) break;
        start = index + 1;
    }
    var end = lines.len;
    var reverse = work.reverseIndices(start, lines.len);
    while (try reverse.next()) |index| {
        if (!lines[index].blank) break;
        end = index;
    }
    return .{ .start = start, .end = end };
}

fn commonMargin(lines: []const Line, start: usize, end: usize, work: poll.WorkContext) poll.Error!usize {
    var margin: ?usize = null;
    var indices = work.indices(start, end);
    while (try indices.next()) |index| {
        if (lines[index].blank or index == 0) continue;
        margin = @min(margin orelse lines[index].leading, lines[index].leading);
    }
    return margin orelse 0;
}

fn render(
    document: Value,
    lines: []const Line,
    margin: usize,
    sink: *Sink,
    work: poll.WorkContext,
) poll.Error!void {
    var emitted = false;
    var pending_blank = false;
    var previous: Kind = .prose;
    var line_indices = work.indices(0, lines.len);
    while (try line_indices.next()) |relative_index| {
        const line = lines[relative_index];
        if (line.blank) {
            if (emitted) pending_blank = true;
            continue;
        }
        const raw_index = relative_index;
        const removed = if (raw_index == 0 and line.start == 0)
            line.leading
        else
            @min(line.leading, margin);
        const start = line.start + removed;
        const remaining_indent = line.leading - removed;
        const content_start = line.start + line.leading;
        const bullet = isBullet(document, content_start, line.end);
        const current: Kind = if (bullet) .bullet else if (previous == .bullet and remaining_indent > 0)
            .bullet
        else
            .prose;
        if (emitted) {
            if (pending_blank) {
                try sink.append('\n');
                try sink.append('\n');
            } else if (bullet or (previous == .bullet and current == .prose)) {
                try sink.append('\n');
            } else {
                try sink.append(' ');
            }
        }
        if (bullet) {
            try sink.append('-');
            var item_start = content_start + 1;
            var item_indices = work.indices(item_start, line.end);
            while (try item_indices.next()) |index| {
                if (!isHorizontal(at(document, index))) break;
                item_start = index + 1;
            }
            if (item_start < line.end) {
                try sink.append(' ');
                try appendCollapsed(document, item_start, line.end, sink, work);
            }
        } else {
            try appendCollapsed(document, @max(start, content_start), line.end, sink, work);
        }
        emitted = true;
        pending_blank = false;
        previous = current;
    }
}

fn appendCollapsed(
    document: Value,
    start: usize,
    end: usize,
    sink: *Sink,
    work: poll.WorkContext,
) poll.Error!void {
    var pending_space = false;
    var indices = work.indices(start, end);
    while (try indices.next()) |index| {
        const codepoint = at(document, index);
        if (isHorizontal(codepoint)) {
            pending_space = sink.len > 0;
            continue;
        }
        if (pending_space) try sink.append(' ');
        try sink.append(codepoint);
        pending_space = false;
    }
}

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
