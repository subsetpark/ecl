//! Lossless source parsing and width-aware document rendering for `ecl fmt`.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const reader = @import("reader.zig");
const doc_text = @import("doc.zig");
const Value = value.Value;
pub const max_width: usize = 100;
pub const Error = error{ OutOfMemory, InvalidUtf8, InvalidSource };
const max_syntax_depth: usize = 10_000;
const Trivia = struct { kind: enum { space, comment }, bytes: []const u8 };
const Part = union(enum) {
    trivia: Trivia,
    form: *Form,
};
const Sequence = struct { parts: []Part, definitions: bool = true };
const Delimited = struct { open: []const u8, close: []const u8, contents: Sequence };
const FormKind = union(enum) { atom: []const u8, string: []const u8, delimited: Delimited };
const Form = struct { kind: FormKind, layout: ?*const Doc = null };
const Syntax = struct { root: Sequence, containers: []*Form };
const ParseContext = struct {
    expected: ?u8,
    open_start: usize = 0,
    parts: std.ArrayList(Part) = .empty,
};
const SyntaxParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,
    fn parse(self: *SyntaxParser) Error!Syntax {
        var contexts: std.ArrayList(ParseContext) = .empty;
        defer contexts.deinit(self.allocator);
        var containers: std.ArrayList(*Form) = .empty;
        defer containers.deinit(self.allocator);
        try contexts.append(self.allocator, .{ .expected = null });
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (isClose(byte)) {
                if (contexts.items.len == 1 or byte != contexts.items[contexts.items.len - 1].expected.?) {
                    return error.InvalidSource;
                }
                const close_start = self.index;
                self.index += 1;
                const closed = contexts.pop().?;
                const syntax_form = try self.allocator.create(Form);
                syntax_form.* = .{ .kind = .{ .delimited = .{
                    .open = self.source[closed.open_start .. closed.open_start + 1],
                    .close = self.source[close_start .. close_start + 1],
                    .contents = .{ .parts = try self.allocator.dupe(Part, closed.parts.items) },
                } } };
                if (closed.expected == '}') syntax_form.kind.delimited.contents.definitions = false;
                try contexts.items[contexts.items.len - 1].parts.append(
                    self.allocator,
                    .{ .form = syntax_form },
                );
                try containers.append(self.allocator, syntax_form);
                continue;
            }
            if (triviaEnd(self.source, self.index)) |end| {
                try contexts.items[contexts.items.len - 1].parts.append(self.allocator, .{ .trivia = .{
                    .kind = .space,
                    .bytes = self.source[self.index..end],
                } });
                self.index = end;
                continue;
            }
            if (byte == '#') {
                const end = std.mem.indexOfScalarPos(u8, self.source, self.index, '\n') orelse
                    self.source.len;
                try contexts.items[contexts.items.len - 1].parts.append(self.allocator, .{ .trivia = .{
                    .kind = .comment,
                    .bytes = self.source[self.index..end],
                } });
                self.index = end;
                continue;
            }
            const close: ?u8 = switch (byte) {
                '(' => ')',
                '[' => ']',
                '{' => '}',
                else => null,
            };
            if (close) |delimiter| {
                if (contexts.items.len > max_syntax_depth) return error.InvalidSource;
                const start = self.index;
                self.index += 1;
                try contexts.append(self.allocator, .{
                    .expected = delimiter,
                    .open_start = start,
                });
                continue;
            }
            const start = self.index;
            self.index = if (byte == '"')
                try stringEnd(self.source, start)
            else
                atomEnd(self.source, start);
            if (self.index == start) return error.InvalidSource;
            const syntax_form = try self.allocator.create(Form);
            syntax_form.* = .{ .kind = if (byte == '"')
                .{ .string = self.source[start..self.index] }
            else
                .{ .atom = self.source[start..self.index] } };
            try contexts.items[contexts.items.len - 1].parts.append(
                self.allocator,
                .{ .form = syntax_form },
            );
        }
        if (contexts.items.len != 1) return error.InvalidSource;
        return .{
            .root = .{ .parts = try self.allocator.dupe(Part, contexts.items[0].parts.items) },
            .containers = try self.allocator.dupe(*Form, containers.items),
        };
    }
};
const Mode = enum { flat, broken };
const Fill = struct { words: []const []const u8, final_reserve: usize };
const Doc = union(enum) {
    empty,
    text: []const u8,
    concat: []const *const Doc,
    softline,
    hardline,
    group: *const Doc,
    aligned: *const Doc,
    fill_sep: Fill,
    docline: usize,
};
const DocBuilder = struct {
    allocator: std.mem.Allocator,
    fn node(self: *DocBuilder, item: Doc) Error!*const Doc {
        const result = try self.allocator.create(Doc);
        result.* = item;
        return result;
    }
    fn empty(self: *DocBuilder) Error!*const Doc {
        return self.node(.empty);
    }
    fn text(self: *DocBuilder, bytes: []const u8) Error!*const Doc {
        if (bytes.len == 0) return self.empty();
        return self.node(.{ .text = bytes });
    }
    fn concat(self: *DocBuilder, items: []const *const Doc) Error!*const Doc {
        if (items.len == 0) return self.empty();
        if (items.len == 1) return items[0];
        return self.node(.{ .concat = try self.allocator.dupe(*const Doc, items) });
    }
    fn join(self: *DocBuilder, separator: *const Doc, items: []const *const Doc) Error!*const Doc {
        if (items.len == 0) return self.empty();
        const joined = try self.allocator.alloc(*const Doc, items.len * 2 - 1);
        for (items, 0..) |item, index| {
            joined[index * 2] = item;
            if (index + 1 < items.len) joined[index * 2 + 1] = separator;
        }
        return self.concat(joined);
    }
    fn softline(self: *DocBuilder) Error!*const Doc {
        return self.node(.softline);
    }
    fn hardline(self: *DocBuilder) Error!*const Doc {
        return self.node(.hardline);
    }
    fn group(self: *DocBuilder, item: *const Doc) Error!*const Doc {
        return self.node(.{ .group = item });
    }
    fn aligned(self: *DocBuilder, item: *const Doc) Error!*const Doc {
        return self.node(.{ .aligned = item });
    }
};
const Frame = struct { doc: *const Doc, indent: usize, mode: Mode };
const max_probe_steps = max_width * 16 + 256;
const Probe = union(enum) {
    frame: Frame,
    concat: struct { items: []const *const Doc, index: usize, mode: Mode },
    fill: struct { words: []const []const u8, index: usize },
};
const ProbeStack = struct {
    items: [max_probe_steps]Probe,
    len: usize = 0,
    fn push(self: *ProbeStack, item: Probe) bool {
        if (self.len == self.items.len) return false;
        self.items[self.len] = item;
        self.len += 1;
        return true;
    }
    fn pop(self: *ProbeStack) ?Probe {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items[self.len];
    }
};
const Renderer = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    column: usize = 0,
    pending_indent: usize = 0,
    fn deinit(self: *Renderer) void {
        self.output.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }
    fn render(self: *Renderer, root: *const Doc) Error![]u8 {
        try self.stack.append(self.allocator, .{ .doc = root, .indent = 0, .mode = .broken });
        while (self.stack.pop()) |frame| switch (frame.doc.*) {
            .empty => {},
            .text => |bytes| try self.writeText(bytes),
            .concat => |items| {
                var index = items.len;
                while (index > 0) {
                    index -= 1;
                    try self.stack.append(self.allocator, .{
                        .doc = items[index],
                        .indent = frame.indent,
                        .mode = frame.mode,
                    });
                }
            },
            .softline => if (frame.mode == .flat)
                try self.writeSpace()
            else
                try self.lineBreak(frame.indent),
            .hardline => try self.lineBreak(frame.indent),
            .aligned => |item| try self.stack.append(self.allocator, .{
                .doc = item,
                .indent = self.column,
                .mode = frame.mode,
            }),
            .group => |item| {
                const mode: Mode = if (frame.mode == .flat or
                    self.fits(max_width -| self.column, item)) .flat else .broken;
                try self.stack.append(self.allocator, .{
                    .doc = item,
                    .indent = frame.indent,
                    .mode = mode,
                });
            },
            .fill_sep => |fill| try self.renderFill(fill, frame),
            .docline => |count| if (frame.mode == .flat) {
                for (0..count) |_| try self.writeText("\\n");
            } else {
                for (0..count) |_| try self.lineBreak(frame.indent);
            },
        };
        return self.output.toOwnedSlice(self.allocator);
    }
    fn fits(self: *Renderer, available: usize, candidate: *const Doc) bool {
        // SAFETY: ProbeStack reads only initialized slots below `len`.
        var commands: ProbeStack = .{ .items = undefined };
        _ = commands.push(.{ .frame = .{ .doc = candidate, .indent = 0, .mode = .flat } });
        var pending = self.stack.items.len;
        var remaining = available;
        var steps: usize = 0;
        while (true) {
            const command = commands.pop() orelse blk: {
                if (pending == 0) return true;
                pending -= 1;
                break :blk Probe{ .frame = self.stack.items[pending] };
            };
            steps += 1;
            if (steps > max_probe_steps) return false;
            switch (command) {
                .concat => |cursor| {
                    if (cursor.index == cursor.items.len) continue;
                    if (!commands.push(.{ .concat = .{
                        .items = cursor.items,
                        .index = cursor.index + 1,
                        .mode = cursor.mode,
                    } }) or !commands.push(.{ .frame = .{
                        .doc = cursor.items[cursor.index],
                        .indent = 0,
                        .mode = cursor.mode,
                    } })) return false;
                    continue;
                },
                .fill => |cursor| {
                    if (cursor.index == cursor.words.len) continue;
                    const separator: usize = @intFromBool(cursor.index > 0);
                    const width = flatWidthLimited(cursor.words[cursor.index], remaining -| separator) orelse
                        return false;
                    if (separator + width > remaining) return false;
                    remaining -= separator + width;
                    if (!commands.push(.{ .fill = .{
                        .words = cursor.words,
                        .index = cursor.index + 1,
                    } })) return false;
                    continue;
                },
                .frame => |frame| switch (frame.doc.*) {
                    .empty => {},
                    .text => |bytes| {
                        const width = flatWidthLimited(bytes, remaining) orelse return frame.mode == .broken;
                        if (width > remaining) return false;
                        remaining -= width;
                    },
                    .concat => |items| {
                        if (!commands.push(.{ .concat = .{ .items = items, .index = 0, .mode = frame.mode } })) return false;
                    },
                    .softline => if (frame.mode == .flat) {
                        if (remaining == 0) return false;
                        remaining -= 1;
                    } else return true,
                    .hardline => return frame.mode == .broken,
                    .group, .aligned => |item| if (!commands.push(.{ .frame = .{
                        .doc = item,
                        .indent = 0,
                        .mode = if (frame.mode == .flat) .flat else .broken,
                    } })) return false,
                    .fill_sep => |fill| {
                        if (frame.mode == .broken) return true;
                        if (!commands.push(.{ .fill = .{ .words = fill.words, .index = 0 } })) return false;
                    },
                    .docline => |count| if (frame.mode == .flat) {
                        if (count > remaining / 2) return false;
                        remaining -= count * 2;
                    } else return true,
                },
            }
        }
    }
    fn renderFill(self: *Renderer, fill: Fill, frame: Frame) Error!void {
        for (fill.words, 0..) |word, index| {
            const reserve = if (index + 1 == fill.words.len) fill.final_reserve else 0;
            if (index > 0 and frame.mode == .broken and
                self.column + 1 + displayWidth(word) + reserve > max_width)
            {
                try self.lineBreak(frame.indent);
            } else if (index > 0) try self.writeSpace();
            try self.writeText(word);
        }
    }
    fn writeText(self: *Renderer, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        try self.materializeIndent();
        try self.output.appendSlice(self.allocator, bytes);
        var index: usize = 0;
        while (index < bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
            const codepoint = std.unicode.utf8Decode(bytes[index..][0..@min(length, bytes.len - index)]) catch 0;
            index += @min(length, bytes.len - index);
            self.column = if (isLineBreak(codepoint)) 0 else self.column + 1;
        }
    }
    fn writeSpace(self: *Renderer) Error!void {
        try self.materializeIndent();
        try self.output.append(self.allocator, ' ');
        self.column += 1;
    }
    fn lineBreak(self: *Renderer, indent: usize) Error!void {
        try self.output.append(self.allocator, '\n');
        self.column = indent;
        self.pending_indent = indent;
    }
    fn materializeIndent(self: *Renderer) Error!void {
        for (0..self.pending_indent) |_| try self.output.append(self.allocator, ' ');
        self.pending_indent = 0;
    }
};
const Annotation = struct {
    forms: []*Form,
    colon: usize,
    separator: ?usize,
    document: *Form,
    open: []const u8,
    close: []const u8,
};
const NestedDoc = struct { doc: *const Doc, has_content: bool, trailing_comment: bool };
const Formatter = struct {
    host: *const heap.HostCleanup,
    docs: DocBuilder,

    fn allocator(self: *const Formatter) std.mem.Allocator {
        return self.host.allocator();
    }

    fn root(self: *Formatter, sequence: Sequence) Error!*const Doc {
        var output: std.ArrayList(*const Doc) = .empty;
        var line: std.ArrayList(*const Doc) = .empty;
        defer output.deinit(self.allocator());
        defer line.deinit(self.allocator());
        var have_content = false;
        var previous_comment = false;
        var pending_definition: ?usize = null;
        var newlines: usize = 0;
        for (sequence.parts, 0..) |part, part_index| switch (part) {
            .trivia => |trivia| switch (trivia.kind) {
                .space => newlines += lineBreakCount(trivia.bytes),
                .comment => {
                    if (existingDefinitionHeader(sequence, part_index, trivia.bytes)) |header| {
                        if (have_content) try self.rootBreak(&output, &line, 2);
                        try line.append(self.allocator(), try self.definitionHeader(header.name));
                        have_content = true;
                        previous_comment = true;
                        pending_definition = header.part;
                        newlines = 0;
                        continue;
                    }
                    if (attachedDefinitionAfterComment(sequence, part_index)) |header| {
                        if (pending_definition != header.part) {
                            if (have_content) try self.rootBreak(&output, &line, 2);
                            try line.append(self.allocator(), try self.definitionHeader(header.name));
                            have_content = true;
                            previous_comment = true;
                            pending_definition = header.part;
                            newlines = 0;
                        }
                    }
                    if (have_content) {
                        if (previous_comment or newlines > 0) {
                            try self.rootBreak(&output, &line, @min(@max(newlines, 1), 2));
                        } else try line.append(self.allocator(), try self.docs.text(" "));
                    }
                    try line.append(self.allocator(), try self.docs.text(trivia.bytes));
                    have_content = true;
                    previous_comment = true;
                    newlines = 0;
                },
            },
            .form => {
                var fill_pair = false;
                const name = if (pending_definition == part_index) null else definitionName(sequence, part_index);
                if (name) |definition_name| {
                    if (have_content) try self.rootBreak(&output, &line, 2);
                    try line.append(self.allocator(), try self.definitionHeader(definition_name));
                    try self.rootBreak(&output, &line, 1);
                } else if (have_content) {
                    if (previous_comment or newlines > 0) {
                        try self.rootBreak(&output, &line, @min(@max(newlines, 1), 2));
                    } else {
                        try line.append(self.allocator(), try self.docs.softline());
                        fill_pair = true;
                    }
                }
                try line.append(self.allocator(), try self.form(sequence, part_index));
                if (fill_pair) {
                    const start = line.items.len - 3;
                    const pair = try self.docs.group(try self.docs.concat(line.items[start..]));
                    line.shrinkRetainingCapacity(start);
                    try line.append(self.allocator(), pair);
                }
                have_content = true;
                previous_comment = false;
                pending_definition = null;
                newlines = 0;
            },
        };
        try self.flushRootLine(&output, &line);
        if (have_content) try output.append(self.allocator(), try self.docs.hardline());
        return self.docs.concat(output.items);
    }
    fn rootBreak(
        self: *Formatter,
        output: *std.ArrayList(*const Doc),
        line: *std.ArrayList(*const Doc),
        count: usize,
    ) Error!void {
        try self.flushRootLine(output, line);
        for (0..count) |_| try output.append(self.allocator(), try self.docs.hardline());
    }
    fn flushRootLine(
        self: *Formatter,
        output: *std.ArrayList(*const Doc),
        line: *std.ArrayList(*const Doc),
    ) Error!void {
        if (line.items.len == 0) return;
        try output.append(self.allocator(), try self.docs.concat(line.items));
        line.clearRetainingCapacity();
    }
    fn form(self: *Formatter, parent: Sequence, part_index: usize) Error!*const Doc {
        const form_item = parent.parts[part_index].form;
        if (try self.annotation(parent, part_index, form_item)) |annotation_info| {
            return self.formatAnnotation(annotation_info);
        }
        return switch (form_item.kind) {
            .atom => |bytes| self.docs.text(bytes),
            .string => |bytes| self.docs.text(bytes),
            .delimited => form_item.layout.?,
        };
    }
    fn definitionHeader(self: *Formatter, name: []const u8) Error!*const Doc {
        return self.docs.concat(&.{ try self.docs.text("### def "), try self.docs.text(name) });
    }
    fn prepare(self: *Formatter, syntax: Syntax) Error!void {
        for (syntax.containers) |form_item| {
            form_item.layout = try self.formatDelimited(form_item.kind.delimited);
        }
    }
    fn formatDelimited(self: *Formatter, delimited: Delimited) Error!*const Doc {
        const nested_doc = try self.nested(delimited.contents);
        if (!nested_doc.has_content) {
            return self.docs.concat(&.{ try self.docs.text(delimited.open), try self.docs.text(delimited.close) });
        }
        var pieces: std.ArrayList(*const Doc) = .empty;
        defer pieces.deinit(self.allocator());
        try pieces.append(self.allocator(), try self.docs.text(delimited.open));
        try pieces.append(self.allocator(), try self.docs.aligned(nested_doc.doc));
        if (nested_doc.trailing_comment) try pieces.append(self.allocator(), try self.docs.hardline());
        try pieces.append(self.allocator(), try self.docs.text(delimited.close));
        return self.docs.group(try self.docs.aligned(try self.docs.concat(pieces.items)));
    }
    fn nested(self: *Formatter, sequence: Sequence) Error!NestedDoc {
        var output: std.ArrayList(*const Doc) = .empty;
        defer output.deinit(self.allocator());
        const binder = binderBounds(sequence);
        var have_content = false;
        var previous_comment = false;
        var previous_form: ?usize = null;
        var pending_definition: ?usize = null;
        var newlines: usize = 0;
        for (sequence.parts, 0..) |part, part_index| switch (part) {
            .trivia => |trivia| switch (trivia.kind) {
                .space => newlines += lineBreakCount(trivia.bytes),
                .comment => {
                    if (existingDefinitionHeader(sequence, part_index, trivia.bytes)) |header| {
                        try self.appendHardlines(&output, if (have_content) 2 else 1);
                        try output.append(self.allocator(), try self.definitionHeader(header.name));
                        have_content = true;
                        previous_comment = true;
                        pending_definition = header.part;
                        newlines = 0;
                        continue;
                    }
                    if (attachedDefinitionAfterComment(sequence, part_index)) |header| {
                        if (pending_definition != header.part) {
                            try self.appendHardlines(&output, if (have_content) 2 else 1);
                            try output.append(self.allocator(), try self.definitionHeader(header.name));
                            have_content = true;
                            previous_comment = true;
                            pending_definition = header.part;
                            newlines = 0;
                        }
                    }
                    if (have_content) {
                        if (previous_comment or newlines > 0) {
                            try self.appendHardlines(&output, @min(@max(newlines, 1), 2));
                        } else try output.append(self.allocator(), try self.docs.text(" "));
                    }
                    try output.append(self.allocator(), try self.docs.text(trivia.bytes));
                    have_content = true;
                    previous_comment = true;
                    newlines = 0;
                },
            },
            .form => {
                var fill_pair = false;
                const name = if (pending_definition == part_index) null else definitionName(sequence, part_index);
                if (name) |definition_name| {
                    if (!have_content) try self.appendHardlines(&output, 1) else try self.appendHardlines(&output, 2);
                    try output.append(self.allocator(), try self.definitionHeader(definition_name));
                    try output.append(self.allocator(), try self.docs.hardline());
                } else if (have_content) {
                    if (previous_comment) {
                        try self.appendHardlines(&output, @min(@max(newlines, 1), 2));
                    } else if (!tightBinderGap(binder, previous_form, part_index)) {
                        if (newlines > 0) {
                            try self.appendHardlines(&output, @min(newlines, 2));
                        } else {
                            try output.append(self.allocator(), try self.docs.softline());
                            fill_pair = true;
                        }
                    }
                } else if (newlines > 0) {
                    try self.appendHardlines(&output, @min(newlines, 2));
                }
                if (binder) |bounds| {
                    if (part_index == bounds.open) {
                        try output.append(self.allocator(), try self.formatBinder(sequence, bounds));
                    } else if (part_index > bounds.close) {
                        try output.append(self.allocator(), try self.form(sequence, part_index));
                    }
                } else try output.append(self.allocator(), try self.form(sequence, part_index));
                if (fill_pair) {
                    const start = output.items.len - 3;
                    const pair = try self.docs.group(try self.docs.concat(output.items[start..]));
                    output.shrinkRetainingCapacity(start);
                    try output.append(self.allocator(), pair);
                }
                have_content = true;
                previous_comment = false;
                previous_form = part_index;
                pending_definition = null;
                newlines = 0;
            },
        };
        if (newlines > 0) try self.appendHardlines(&output, @min(newlines, 2));
        return .{
            .doc = try self.docs.concat(output.items),
            .has_content = have_content or output.items.len > 0,
            .trailing_comment = previous_comment and newlines == 0,
        };
    }
    fn appendHardlines(self: *Formatter, output: *std.ArrayList(*const Doc), count: usize) Error!void {
        for (0..count) |_| try output.append(self.allocator(), try self.docs.hardline());
    }
    fn formatBinder(self: *Formatter, sequence: Sequence, bounds: BinderBounds) Error!*const Doc {
        var names: std.ArrayList(*const Doc) = .empty;
        defer names.deinit(self.allocator());
        for (sequence.parts[bounds.open + 1 .. bounds.close]) |part| switch (part) {
            .trivia => {},
            .form => |form_item| try names.append(
                self.allocator(),
                try self.docs.text(form_item.kind.atom),
            ),
        };
        const body = try self.docs.aligned(try self.docs.join(try self.docs.softline(), names.items));
        return self.docs.group(try self.docs.concat(&.{
            try self.docs.text("|"), body, try self.docs.text("|"),
        }));
    }
    fn annotation(
        self: *Formatter,
        parent: Sequence,
        part_index: usize,
        form_item: *Form,
    ) Error!?Annotation {
        if (!definitionFollows(parent, part_index)) return null;
        const delimited = switch (form_item.kind) {
            .delimited => |item| item,
            else => return null,
        };
        if (!std.mem.eql(u8, delimited.open, "(") and
            !std.mem.eql(u8, delimited.open, "[")) return null;
        var count: usize = 0;
        for (delimited.contents.parts) |part| switch (part) {
            .form => count += 1,
            .trivia => |trivia| if (trivia.kind == .comment) return null,
        };
        const forms = try self.allocator().alloc(*Form, count);
        var next: usize = 0;
        for (delimited.contents.parts) |part| switch (part) {
            .form => |item| {
                forms[next] = item;
                next += 1;
            },
            .trivia => {},
        };
        var colon: ?usize = null;
        var separator: ?usize = null;
        for (forms, 0..) |item, index| {
            const bytes = wordBytes(item) orelse continue;
            if (std.mem.eql(u8, bytes, ":")) {
                if (colon != null) return null;
                colon = index;
            } else if (std.mem.eql(u8, bytes, "--")) {
                if (separator != null) return null;
                separator = index;
            }
        }
        const colon_index = colon orelse return null;
        if (separator) |index| if (index > colon_index) return null;
        if (separator == null and colon_index != 0) return null;
        if (forms.len != colon_index + 2 or forms[colon_index + 1].kind != .string) return null;
        for (forms[0..colon_index]) |item| _ = wordBytes(item) orelse return null;
        return .{
            .forms = forms,
            .colon = colon_index,
            .separator = separator,
            .document = forms[colon_index + 1],
            .open = delimited.open,
            .close = delimited.close,
        };
    }
    fn formatAnnotation(self: *Formatter, annotation_info: Annotation) Error!*const Doc {
        const token = annotation_info.document.kind.string;
        var document = heap.OwnedValue.init(
            heap.hostDomain(self.host),
            try decodeAndNormalize(self.host, token),
        );
        defer document.deinit();
        const quoted = try self.quotedDocument(document.borrow());
        if (annotation_info.separator == null) {
            return self.docs.group(try self.docs.aligned(try self.docs.concat(&.{
                try self.docs.text(annotation_info.open),
                try self.docs.text(": "),
                quoted,
                try self.docs.text(annotation_info.close),
            })));
        }
        const header_items = try self.allocator().alloc(*const Doc, annotation_info.colon + 1);
        for (annotation_info.forms[0 .. annotation_info.colon + 1], 0..) |item, index| {
            header_items[index] = try self.docs.text(wordBytes(item).?);
        }
        const header = try self.docs.group(try self.docs.join(
            try self.docs.softline(),
            header_items,
        ));
        const inside = try self.docs.aligned(try self.docs.concat(&.{
            header, try self.docs.softline(), quoted,
        }));
        return self.docs.group(try self.docs.aligned(try self.docs.concat(&.{
            try self.docs.text(annotation_info.open),
            inside,
            try self.docs.text(annotation_info.close),
        })));
    }
    fn quotedDocument(self: *Formatter, document: Value) Error!*const Doc {
        const content = try self.documentContent(document);
        return self.docs.concat(&.{
            try self.docs.text("\""), try self.docs.aligned(content), try self.docs.text("\""),
        });
    }
    fn documentContent(self: *Formatter, document: Value) Error!*const Doc {
        const count: usize = @intCast(document.list.length());
        var output: std.ArrayList(*const Doc) = .empty;
        defer output.deinit(self.allocator());
        var start: usize = 0;
        while (start < count) {
            var end = start;
            while (end < count and charAt(document, end) != '\n') end += 1;
            try output.append(self.allocator(), try self.documentLine(
                document,
                start,
                end,
                if (end == count) 2 else 0,
            ));
            if (end == count) break;
            var breaks: usize = 0;
            while (end < count and charAt(document, end) == '\n') : (end += 1) breaks += 1;
            try output.append(self.allocator(), try self.docs.node(.{ .docline = breaks }));
            start = end;
        }
        return self.docs.concat(output.items);
    }
    fn documentLine(
        self: *Formatter,
        document: Value,
        start: usize,
        end: usize,
        reserve: usize,
    ) Error!*const Doc {
        const bullet = start < end and charAt(document, start) == '-' and
            (start + 1 == end or charAt(document, start + 1) == ' ');
        const word_start = start + @as(usize, if (bullet and start + 1 < end) 2 else 0);
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.allocator());
        var cursor = word_start;
        while (cursor < end) {
            while (cursor < end and charAt(document, cursor) == ' ') cursor += 1;
            if (cursor == end) break;
            var word_end = cursor;
            while (word_end < end and charAt(document, word_end) != ' ') word_end += 1;
            try words.append(self.allocator(), try escapedWord(self.allocator(), document, cursor, word_end));
            cursor = word_end;
        }
        const fill = try self.docs.node(.{ .fill_sep = .{
            .words = try self.allocator().dupe([]const u8, words.items),
            .final_reserve = reserve,
        } });
        if (!bullet) return fill;
        if (words.items.len == 0) return self.docs.text("-");
        return self.docs.concat(&.{ try self.docs.text("- "), try self.docs.aligned(fill) });
    }
};
/// Parses source without evaluating it, formats its CST, and returns owned UTF-8.
pub fn format(allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    var validation_host = heap.HostOwner.init(allocator);
    defer validation_host.cleanup().drain();
    try validateSource(validation_host.cleanup(), source);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var formatting_host = heap.HostOwner.init(arena);
    defer formatting_host.cleanup().drain();
    var parser = SyntaxParser{ .allocator = arena, .source = source };
    const syntax = try parser.parse();
    var formatter = Formatter{
        .host = formatting_host.cleanup(),
        .docs = .{ .allocator = arena },
    };
    try formatter.prepare(syntax);
    const document = try formatter.root(syntax.root);
    var renderer = Renderer{ .allocator = allocator };
    defer renderer.deinit();
    return renderer.render(document);
}
fn validateSource(host: *const heap.HostCleanup, source: []const u8) Error!void {
    var diag: reader.Diag = .{};
    const result = reader.read(host, "<fmt>", source, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => return error.InvalidSource,
    };
    var parsed = switch (result) {
        .complete => |complete| complete,
        .incomplete => return error.InvalidSource,
    };
    parsed.deinit();
}
fn definitionFollows(sequence: Sequence, current: usize) bool {
    if (!sequence.definitions) return false;
    var stage: usize = 0;
    for (sequence.parts[current + 1 ..]) |part| switch (part) {
        .trivia => {},
        .form => |form_item| {
            const bytes = switch (form_item.kind) {
                .atom => |atom| atom,
                else => return false,
            };
            if (stage == 0) {
                if (bytes.len < 2 or bytes[0] != '\'' or !lexer.validSymbol(bytes[1..])) return false;
                stage = 1;
            } else return std.mem.eql(u8, bytes, "def") or std.mem.eql(u8, bytes, "defp");
        },
    };
    return false;
}
fn definitionName(sequence: Sequence, start: usize) ?[]const u8 {
    const body = sequence.parts[start].form;
    if (!isListForm(body) or isAnnotationCandidate(body)) return null;
    const following = nextFormPart(sequence, start) orelse return null;
    const anchor = if (isAnnotationCandidate(sequence.parts[following].form)) following else start;
    if (!definitionFollows(sequence, anchor)) return null;
    const quoted = sequence.parts[nextFormPart(sequence, anchor).?].form.kind.atom;
    return quoted[1..];
}
fn nextFormPart(sequence: Sequence, after: usize) ?usize {
    for (sequence.parts[after + 1 ..], after + 1..) |part, index| switch (part) {
        .form => return index,
        .trivia => {},
    };
    return null;
}
fn isListForm(form_item: *const Form) bool {
    return switch (form_item.kind) {
        .delimited => |item| item.open[0] != '{',
        .string => true,
        else => false,
    };
}
fn isAnnotationCandidate(form_item: *const Form) bool {
    const contents = switch (form_item.kind) {
        .delimited => |item| if (item.open[0] != '{') item.contents else return false,
        else => return false,
    };
    for (contents.parts) |part| if (part == .form) {
        const bytes = wordBytes(part.form) orelse continue;
        if (std.mem.eql(u8, bytes, "--") or std.mem.eql(u8, bytes, ":")) return true;
    };
    return false;
}
const HeaderTarget = struct { part: usize, name: []const u8 };
fn existingDefinitionHeader(sequence: Sequence, index: usize, bytes: []const u8) ?HeaderTarget {
    if (!std.mem.startsWith(u8, bytes, "# def ") and
        !std.mem.startsWith(u8, bytes, "### def ")) return null;
    const part = nextFormPart(sequence, index) orelse return null;
    return .{ .part = part, .name = definitionName(sequence, part) orelse return null };
}
fn attachedDefinitionAfterComment(sequence: Sequence, index: usize) ?HeaderTarget {
    const first = switch (sequence.parts[index]) {
        .trivia => |trivia| trivia,
        .form => return null,
    };
    if (first.kind != .comment or !ordinaryDefinitionComment(first.bytes)) return null;
    var newlines: usize = 0;
    for (sequence.parts[index + 1 ..], index + 1..) |part, part_index| switch (part) {
        .trivia => |trivia| switch (trivia.kind) {
            .space => {
                newlines += lineBreakCount(trivia.bytes);
                if (newlines > 1) return null;
            },
            .comment => {
                if (!ordinaryDefinitionComment(trivia.bytes) or
                    existingDefinitionHeader(sequence, part_index, trivia.bytes) != null or
                    newlines != 1)
                    return null;
                newlines = 0;
            },
        },
        .form => {
            if (newlines != 1) return null;
            return .{ .part = part_index, .name = definitionName(sequence, part_index) orelse return null };
        },
    };
    return null;
}
fn ordinaryDefinitionComment(bytes: []const u8) bool {
    return bytes.len > 0 and bytes[0] == '#' and (bytes.len == 1 or bytes[1] != '#');
}
const BinderBounds = struct { open: usize, close: usize };
fn binderBounds(sequence: Sequence) ?BinderBounds {
    var open: ?usize = null;
    var names: usize = 0;
    for (sequence.parts, 0..) |part, index| switch (part) {
        .trivia => |trivia| if (trivia.kind == .comment and open != null) return null,
        .form => |form_item| {
            const bytes = switch (form_item.kind) {
                .atom => |atom| atom,
                else => return null,
            };
            if (open == null) {
                if (!std.mem.eql(u8, bytes, "|")) return null;
                open = index;
            } else if (std.mem.eql(u8, bytes, "|")) {
                return if (names > 0) .{ .open = open.?, .close = index } else null;
            } else names += 1;
        },
    };
    return null;
}
fn tightBinderGap(bounds: ?BinderBounds, previous: ?usize, current: usize) bool {
    const binder = bounds orelse return false;
    const prior = previous orelse return false;
    return prior >= binder.open and current <= binder.close;
}
fn wordBytes(form_item: *const Form) ?[]const u8 {
    const bytes = switch (form_item.kind) {
        .atom => |atom| atom,
        else => return null,
    };
    return switch (lexer.classify(bytes)) {
        .word => if (lexer.validSymbol(bytes)) bytes else null,
        else => null,
    };
}
fn decodeAndNormalize(
    host: *const heap.HostCleanup,
    token: []const u8,
) Error!Value {
    const allocator = host.allocator();
    var diag: reader.Diag = .{};
    const result = reader.read(host, "<fmt-doc>", token, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => return error.InvalidSource,
    };
    var parsed = switch (result) {
        .complete => |complete| complete,
        .incomplete => return error.InvalidSource,
    };
    defer parsed.deinit();
    if (parsed.values().len != 1 or !parsed.values()[0].isString()) return error.InvalidSource;
    return doc_text.normalize(allocator, parsed.values()[0]);
}
fn escapedWord(
    allocator: std.mem.Allocator,
    document: Value,
    start: usize,
    end: usize,
) Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (start..end) |index| {
        const codepoint = charAt(document, index);
        switch (codepoint) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            '\t' => try output.appendSlice(allocator, "\\t"),
            0...8, 10...0x1f, 0x7f...0x9f => {
                var buffer: [16]u8 = undefined;
                const escaped = std.fmt.bufPrint(&buffer, "\\u{{{x}}}", .{codepoint}) catch
                    @panic("formatter escape buffer is too small");
                try output.appendSlice(allocator, escaped);
            },
            else => {
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch
                    return error.InvalidSource;
                try output.appendSlice(allocator, encoded[0..length]);
            },
        }
    }
    return output.toOwnedSlice(allocator);
}
fn charAt(document: Value, index: usize) u32 {
    return list.atUnchecked(document, index).char;
}
fn triviaEnd(source: []const u8, start: usize) ?usize {
    var index = start;
    while (index < source.len) {
        if (source[index] == ',') {
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch
            @panic("formatter received invalid UTF-8 after validation");
        const codepoint = std.unicode.utf8Decode(source[index..][0..length]) catch
            @panic("formatter received invalid UTF-8 after validation");
        if (!lexer.isWhitespace(codepoint)) break;
        index += length;
    }
    return if (index == start) null else index;
}
fn atomEnd(source: []const u8, start: usize) usize {
    if (source[start] == ';' or source[start] == '|') return start + 1;
    var index = start + @as(usize, @intFromBool(source[start] == '\'' or source[start] == '\\'));
    if (source[start] == '\\' and index < source.len) {
        const next_length = std.unicode.utf8ByteSequenceLength(source[index]) catch
            @panic("formatter received invalid UTF-8 after validation");
        const next = std.unicode.utf8Decode(source[index..][0..next_length]) catch
            @panic("formatter received invalid UTF-8 after validation");
        if (lexer.isTokenBoundary(next) or next == ';' or next == '|' or next == '\'' or next == '\\') {
            return index + next_length;
        }
    }
    while (index < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch
            @panic("formatter received invalid UTF-8 after validation");
        const codepoint = std.unicode.utf8Decode(source[index..][0..length]) catch
            @panic("formatter received invalid UTF-8 after validation");
        if (lexer.isTokenBoundary(codepoint) or codepoint == ';' or codepoint == '|') break;
        index += length;
    }
    return index;
}
fn stringEnd(source: []const u8, start: usize) Error!usize {
    var index = start + 1;
    while (index < source.len) {
        if (source[index] == '\\') {
            index += 1;
            if (index == source.len) return error.InvalidSource;
            const length = std.unicode.utf8ByteSequenceLength(source[index]) catch
                @panic("formatter received invalid UTF-8 after validation");
            index += length;
        } else if (source[index] == '"') {
            return index + 1;
        } else {
            const length = std.unicode.utf8ByteSequenceLength(source[index]) catch
                @panic("formatter received invalid UTF-8 after validation");
            index += length;
        }
    }
    return error.InvalidSource;
}
fn lineBreakCount(bytes: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
            @panic("formatter received invalid UTF-8 after validation");
        const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch
            @panic("formatter received invalid UTF-8 after validation");
        if (isLineBreak(codepoint)) {
            count += 1;
            if (codepoint == '\r' and index + length < bytes.len and bytes[index + length] == '\n') index += 1;
        }
        index += length;
    }
    return count;
}
fn flatWidth(bytes: []const u8) ?usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return null;
        const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch return null;
        if (isLineBreak(codepoint)) return null;
        width += 1;
        index += length;
    }
    return width;
}
fn flatWidthLimited(bytes: []const u8, limit: usize) ?usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return null;
        const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch return null;
        if (isLineBreak(codepoint)) return null;
        width += 1;
        if (width > limit) return width;
        index += length;
    }
    return width;
}
fn displayWidth(bytes: []const u8) usize {
    return flatWidth(bytes) orelse max_width + 1;
}
fn isLineBreak(codepoint: u21) bool {
    return switch (codepoint) {
        '\n', '\r', 0x0085, 0x2028, 0x2029 => true,
        else => false,
    };
}
fn isClose(byte: u8) bool {
    return byte == ')' or byte == ']' or byte == '}';
}
