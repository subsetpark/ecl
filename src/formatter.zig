//! Lossless source parsing and width-aware document rendering for `ecl fmt`.
//!
//! Formatting is a cursor: every pass that grows with the source — scanning,
//! parsing, indexing each sequence, laying out documentation, and rendering —
//! keeps its next position in owned state and charges one unit of the
//! caller's budget per codepoint, part, or document node. Storage that grows
//! with the source is sized before it is filled, so no step relocates
//! partially built output.
const std = @import("std");
const heap = @import("heap.zig");
const lexer = @import("lexer.zig");
const poll = @import("poll.zig");
const reader = @import("reader.zig");
const value = @import("value.zig");
const doc_text = @import("doc.zig");
pub const max_width: usize = 100;
pub const Error = error{ OutOfMemory, InvalidUtf8, InvalidSource };
const max_syntax_depth: usize = 10_000;
const none: usize = std.math.maxInt(usize);

// --- Syntax -----------------------------------------------------------------

const Trivia = struct {
    kind: enum { space, comment },
    bytes: []const u8,
    /// Line breaks in a space run, counted while it was scanned.
    breaks: usize = 0,
};
const Part = union(enum) {
    trivia: Trivia,
    form: *Form,
};
/// The neighbours each part's layout consults, indexed once per sequence so
/// no part's decision rescans a run of trivia.
const Neighbours = struct {
    previous: []usize,
    next: []usize,
    /// For an ordinary comment, the definition or registration it documents.
    attached: []usize,
};
const Sequence = struct {
    parts: []Part,
    definitions: bool = true,
    neighbours: Neighbours = .{ .previous = &.{}, .next = &.{}, .attached = &.{} },
};
/// Facts about a delimited form's direct contents, gathered as they are read.
const Marks = struct {
    forms: usize = 0,
    colon: ?usize = null,
    separator: ?usize = null,
    repeated: bool = false,
    comment: bool = false,
    last: ?*Form = null,
};
const Delimited = struct {
    open: []const u8,
    close: []const u8,
    contents: Sequence,
    marks: Marks = .{},
};
const Atom = struct {
    bytes: []const u8,
    /// Reads as a valid bare symbol.
    word: bool = false,
    /// Spells a quoted symbol, `` `name ``.
    quoted_symbol: bool = false,
    /// Reads as an integer or float literal.
    number: bool = false,
};
const FormKind = union(enum) { atom: Atom, string: []const u8, delimited: Delimited };
const Form = struct {
    kind: FormKind,
    /// A delimited form's layout and its contents' document, computed once,
    /// children before parents.
    layout: ?*const Doc = null,
    nested: ?NestedDoc = null,
    /// The documented-definition layout, when this form annotates the next.
    annotated: ?*const Doc = null,
};

fn decodeAt(source: []const u8, index: usize) Error!struct { codepoint: u21, len: usize } {
    const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return error.InvalidUtf8;
    if (index + length > source.len) return error.InvalidUtf8;
    const codepoint = std.unicode.utf8Decode(source[index..][0..length]) catch return error.InvalidUtf8;
    return .{ .codepoint = codepoint, .len = length };
}

/// Lexical events in source order, one codepoint or delimiter per unit.
const Scanner = struct {
    source: []const u8,
    index: usize = 0,
    token: ?Token = null,

    const Token = struct {
        kind: enum { space, comment, atom, string },
        start: usize,
        breaks: usize = 0,
        quoted: bool = false,
        escaped: bool = false,
        after_return: bool = false,
    };
    const Event = union(enum) { open: usize, close: usize, trivia: Trivia, atom: []const u8, string: []const u8 };
    const Step = union(enum) { more, event: Event, end };

    fn step(self: *Scanner) Error!Step {
        if (self.token) |*token| {
            const event = try self.continueToken(token) orelse return .more;
            self.token = null;
            return .{ .event = event };
        }
        if (self.index == self.source.len) return .end;
        const start = self.index;
        const byte = self.source[start];
        if (isClose(byte)) {
            self.index += 1;
            return .{ .event = .{ .close = start } };
        }
        if (byte == '(' or byte == '[' or byte == '{') {
            self.index += 1;
            return .{ .event = .{ .open = start } };
        }
        if (byte == ',' or lexer.isWhitespace((try decodeAt(self.source, start)).codepoint)) {
            self.token = .{ .kind = .space, .start = start };
            return .more;
        }
        if (byte == '#') {
            self.token = .{ .kind = .comment, .start = start };
            return .more;
        }
        if (byte == '"') {
            self.index += 1;
            self.token = .{ .kind = .string, .start = start };
            return .more;
        }
        if (byte == ';' or byte == '|') {
            self.index += 1;
            return .{ .event = .{ .atom = self.source[start..self.index] } };
        }
        if (byte == '`') self.index += 1;
        if (byte == '\\') {
            self.index += 1;
            if (self.index < self.source.len) {
                const next = try decodeAt(self.source, self.index);
                if (lexer.isTokenBoundary(next.codepoint) or next.codepoint == ';' or next.codepoint == '|' or
                    next.codepoint == '\'' or next.codepoint == '`' or next.codepoint == '\\')
                {
                    self.index += next.len;
                    return .{ .event = .{ .atom = self.source[start..self.index] } };
                }
            }
        }
        self.token = .{ .kind = .atom, .start = start };
        return .more;
    }

    fn continueToken(self: *Scanner, token: *Token) Error!?Event {
        const source = self.source;
        switch (token.kind) {
            .space => {
                if (self.index < source.len) {
                    if (source[self.index] == ',') {
                        self.index += 1;
                        token.after_return = false;
                        return null;
                    }
                    const next = try decodeAt(source, self.index);
                    if (lexer.isWhitespace(next.codepoint)) {
                        // `\r\n` is one break.
                        if (isLineBreak(next.codepoint) and !(next.codepoint == '\n' and token.after_return))
                            token.breaks += 1;
                        token.after_return = next.codepoint == '\r';
                        self.index += next.len;
                        return null;
                    }
                }
                return .{ .trivia = .{ .kind = .space, .bytes = source[token.start..self.index], .breaks = token.breaks } };
            },
            .comment => {
                if (self.index < source.len and source[self.index] != '\n') {
                    self.index += 1;
                    return null;
                }
                return .{ .trivia = .{ .kind = .comment, .bytes = source[token.start..self.index] } };
            },
            .string => {
                if (self.index == source.len) return error.InvalidSource;
                if (token.escaped) {
                    self.index += (try decodeAt(source, self.index)).len;
                    token.escaped = false;
                    return null;
                }
                switch (source[self.index]) {
                    '\\' => {
                        self.index += 1;
                        token.escaped = true;
                    },
                    '"' => {
                        self.index += 1;
                        return .{ .string = source[token.start..self.index] };
                    },
                    else => self.index += (try decodeAt(source, self.index)).len,
                }
                return null;
            },
            .atom => {
                // A `'...'` segment keeps its delimiters and whitespace.
                if (token.quoted) {
                    if (self.index == source.len) return try finishAtom(source, token.start, self.index);
                    if (source[self.index] == '\'') token.quoted = false;
                    self.index += 1;
                    return null;
                }
                if (self.index == source.len) return try finishAtom(source, token.start, self.index);
                if (source[self.index] == '\'') {
                    token.quoted = true;
                    self.index += 1;
                    return null;
                }
                const next = try decodeAt(source, self.index);
                if (lexer.isTokenBoundary(next.codepoint) or next.codepoint == ';' or next.codepoint == '|')
                    return try finishAtom(source, token.start, self.index);
                self.index += next.len;
                return null;
            },
        }
    }

    fn finishAtom(source: []const u8, start: usize, end: usize) Error!Event {
        if (end == start) return error.InvalidSource;
        return .{ .atom = source[start..end] };
    }
};

/// The first parse pass: how many parts each sequence holds, in the order the
/// sequences open, so the second pass allocates each exactly once.
const Measure = struct {
    scanner: Scanner,
    counts: poll.ChunkList(usize),
    stack: std.ArrayList(Open) = .empty,
    containers: usize = 0,

    const Open = struct { count: *usize, expected: u8 };

    fn init(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Measure {
        var self: Measure = .{ .scanner = .{ .source = source }, .counts = .init(arena) };
        // The stack is bounded by the nesting limit.
        try self.stack.append(arena, .{ .count = try self.counts.appendPtr(0), .expected = 0 });
        return self;
    }

    /// Whether the pass is complete.
    fn step(self: *Measure, arena: std.mem.Allocator) Error!bool {
        const event = switch (try self.scanner.step()) {
            .more => return false,
            .end => {
                if (self.stack.items.len != 1) return error.InvalidSource;
                return true;
            },
            .event => |event| event,
        };
        const top = self.stack.items[self.stack.items.len - 1];
        switch (event) {
            .trivia, .atom, .string => top.count.* += 1,
            .open => |index| {
                if (self.stack.items.len > max_syntax_depth) return error.InvalidSource;
                top.count.* += 1;
                try self.stack.append(arena, .{
                    .count = try self.counts.appendPtr(0),
                    .expected = closingDelimiter(self.scanner.source[index]),
                });
            },
            .close => |index| {
                if (self.stack.items.len == 1 or self.scanner.source[index] != top.expected)
                    return error.InvalidSource;
                _ = self.stack.pop();
                self.containers += 1;
            },
        }
        return false;
    }
};

/// What an atom reads as, decided one codepoint per unit.
const AtomFacts = struct {
    form: *Form,
    stage: union(enum) {
        classify: lexer.ClassifyCursor,
        word: lexer.SymbolCursor,
        quoted: lexer.SymbolCursor,
    },

    fn init(form: *Form) AtomFacts {
        return .{ .form = form, .stage = .{ .classify = .init(form.kind.atom.bytes) } };
    }

    /// Whether the facts are complete.
    fn step(self: *AtomFacts) bool {
        const atom = &self.form.kind.atom;
        switch (self.stage) {
            .classify => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |classification| switch (classification) {
                    .int, .float => {
                        atom.number = true;
                        return self.startQuoted();
                    },
                    .symbol => self.stage = .{ .word = .init(atom.bytes) },
                    .out_of_range => return self.startQuoted(),
                },
            },
            .word => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |valid| {
                    atom.word = valid;
                    return self.startQuoted();
                },
            },
            .quoted => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |valid| {
                    atom.quoted_symbol = valid;
                    return true;
                },
            },
        }
        return false;
    }

    fn startQuoted(self: *AtomFacts) bool {
        const bytes = self.form.kind.atom.bytes;
        if (bytes.len < 2 or bytes[0] != '`') return true;
        self.stage = .{ .quoted = .initSource(bytes[1..]) };
        return false;
    }
};

/// The second parse pass: the same events, filling exactly sized sequences.
const Build = struct {
    scanner: Scanner,
    counts: poll.ChunkList(usize).Iterator,
    stack: std.ArrayList(Context) = .empty,
    containers: []*Form,
    container_count: usize = 0,
    facts: ?AtomFacts = null,
    root: *Sequence,

    const Context = struct { form: ?*Form, sequence: *Sequence, len: usize = 0 };

    fn init(arena: std.mem.Allocator, measure: *const Measure) Error!Build {
        var counts = measure.counts.iterator();
        const root = try arena.create(Sequence);
        root.* = .{ .parts = try arena.alloc(Part, counts.next().?.*) };
        var self: Build = .{
            .scanner = .{ .source = measure.scanner.source },
            .counts = counts,
            .containers = try arena.alloc(*Form, measure.containers),
            .root = root,
        };
        try self.stack.append(arena, .{ .form = null, .sequence = root });
        return self;
    }

    fn append(self: *Build, part: Part) void {
        const context = &self.stack.items[self.stack.items.len - 1];
        context.sequence.parts[context.len] = part;
        context.len += 1;
    }

    /// Records a finished form in its parent's marks.
    fn mark(self: *Build, form: *Form) void {
        const parent = self.stack.items[self.stack.items.len - 1].form orelse return;
        const marks = &parent.kind.delimited.marks;
        const ordinal = marks.forms;
        marks.forms += 1;
        marks.last = form;
        const bytes = wordBytes(form) orelse return;
        const slot = if (std.mem.eql(u8, bytes, ":"))
            &marks.colon
        else if (std.mem.eql(u8, bytes, "--"))
            &marks.separator
        else
            return;
        if (slot.* != null) marks.repeated = true else slot.* = ordinal;
    }

    /// Whether the pass is complete.
    fn step(self: *Build, arena: std.mem.Allocator) Error!bool {
        if (self.facts) |*facts| {
            if (facts.step()) {
                self.mark(facts.form);
                self.facts = null;
            }
            return false;
        }
        const event = switch (try self.scanner.step()) {
            .more => return false,
            .end => return true,
            .event => |event| event,
        };
        const source = self.scanner.source;
        switch (event) {
            .trivia => |trivia| {
                if (trivia.kind == .comment) {
                    if (self.stack.items[self.stack.items.len - 1].form) |parent|
                        parent.kind.delimited.marks.comment = true;
                }
                self.append(.{ .trivia = trivia });
            },
            .atom => |bytes| {
                const form = try arena.create(Form);
                form.* = .{ .kind = .{ .atom = .{ .bytes = bytes } } };
                self.append(.{ .form = form });
                self.facts = .init(form);
            },
            .string => |bytes| {
                const form = try arena.create(Form);
                form.* = .{ .kind = .{ .string = bytes } };
                self.append(.{ .form = form });
                self.mark(form);
            },
            .open => |index| {
                const sequence: Sequence = .{
                    .parts = try arena.alloc(Part, self.counts.next().?.*),
                    .definitions = source[index] != '{',
                };
                const form = try arena.create(Form);
                form.* = .{ .kind = .{ .delimited = .{
                    .open = source[index .. index + 1],
                    .close = switch (source[index]) {
                        '(' => ")",
                        '[' => "]",
                        else => "}",
                    },
                    .contents = sequence,
                } } };
                self.append(.{ .form = form });
                self.mark(form);
                try self.stack.append(arena, .{ .form = form, .sequence = &form.kind.delimited.contents });
            },
            .close => {
                const closed = self.stack.pop().?;
                std.debug.assert(closed.len == closed.sequence.parts.len);
                self.containers[self.container_count] = closed.form.?;
                self.container_count += 1;
            },
        }
        return false;
    }
};

// --- Documents --------------------------------------------------------------

const Mode = enum { flat, broken };
const FitScope = enum { group, local, first_line };
const Fill = struct {
    words: []const []const u8,
    /// Each word's display width, counted while it was escaped.
    widths: []const usize,
    final_reserve: usize,
};
const Doc = union(enum) {
    empty,
    text: []const u8,
    concat: []const *const Doc,
    /// One item of a sequence that grows by appending: the item, then the
    /// rest of the sequence.
    link: struct { head: *const Doc, next: ?*const Doc },
    softline,
    hardline,
    group: *const Doc,
    /// A fill decision scoped to one separator and the term after it. Unlike
    /// a structural group, this does not reserve width for later siblings.
    local_group: *const Doc,
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
    /// A fixed handful of items; a sequence that grows with the source is a
    /// `Chain`.
    fn concat(self: *DocBuilder, items: []const *const Doc) Error!*const Doc {
        if (items.len == 0) return self.empty();
        if (items.len == 1) return items[0];
        return self.node(.{ .concat = try self.allocator.dupe(*const Doc, items) });
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
    fn localGroup(self: *DocBuilder, item: *const Doc) Error!*const Doc {
        return self.node(.{ .local_group = item });
    }
    fn aligned(self: *DocBuilder, item: *const Doc) Error!*const Doc {
        return self.node(.{ .aligned = item });
    }
};
/// A document sequence built one item at a time without relocation.
const Chain = struct {
    first: ?*Doc = null,
    last: ?*Doc = null,
    len: usize = 0,

    fn append(self: *Chain, docs: *DocBuilder, item: *const Doc) Error!void {
        const link = try docs.allocator.create(Doc);
        link.* = .{ .link = .{ .head = item, .next = null } };
        if (self.last) |last| last.link.next = link else self.first = link;
        self.last = link;
        self.len += 1;
    }
    fn appendHardlines(self: *Chain, docs: *DocBuilder, count: usize) Error!void {
        for (0..count) |_| try self.append(docs, try docs.hardline());
    }
    fn doc(self: *const Chain, docs: *DocBuilder) Error!*const Doc {
        return switch (self.len) {
            0 => docs.empty(),
            1 => self.first.?.link.head,
            else => self.first.?,
        };
    }
};

// --- Rendering --------------------------------------------------------------

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
/// Renders one frame, fill word, line break, or output codepoint per unit.
const Renderer = struct {
    output: poll.ChunkList(u8),
    /// Bounded by the document's nesting, not its width: a sequence keeps
    /// one frame for its rest.
    stack: std.ArrayList(Frame) = .empty,
    column: usize = 0,
    pending_indent: usize = 0,
    /// Output in flight: indentation spaces, then text.
    spaces: usize = 0,
    text: []const u8 = "",
    fill: ?struct { fill: Fill, index: usize, frame: Frame, separated: bool } = null,
    doclines: ?struct { remaining: usize, frame: Frame } = null,

    fn init(arena: std.mem.Allocator, root: *const Doc) Error!Renderer {
        var self: Renderer = .{ .output = .init(arena) };
        try self.stack.append(arena, .{ .doc = root, .indent = 0, .mode = .broken });
        return self;
    }

    /// Whether rendering is complete.
    fn step(self: *Renderer, arena: std.mem.Allocator, work: *poll.WorkBudget) Error!bool {
        if (self.spaces != 0) {
            try self.output.append(' ');
            self.spaces -= 1;
            return false;
        }
        if (self.text.len != 0) {
            const length = @min(std.unicode.utf8ByteSequenceLength(self.text[0]) catch 1, self.text.len);
            const codepoint = std.unicode.utf8Decode(self.text[0..length]) catch 0;
            for (self.text[0..length]) |byte| try self.output.append(byte);
            self.text = self.text[length..];
            self.column = if (isLineBreak(codepoint)) 0 else self.column + 1;
            return false;
        }
        if (self.fill) |*fill| {
            if (fill.index == fill.fill.words.len) {
                self.fill = null;
                return false;
            }
            const word = fill.fill.words[fill.index];
            if (fill.index > 0 and !fill.separated) {
                fill.separated = true;
                const reserve = if (fill.index + 1 == fill.fill.words.len) fill.fill.final_reserve else 0;
                if (fill.frame.mode == .broken and
                    self.column + 1 + fill.fill.widths[fill.index] + reserve > max_width)
                {
                    try self.lineBreak(fill.frame.indent);
                } else self.writeText(" ");
                return false;
            }
            self.writeText(word);
            fill.index += 1;
            fill.separated = false;
            return false;
        }
        if (self.doclines) |*doclines| {
            if (doclines.remaining == 0) {
                self.doclines = null;
                return false;
            }
            doclines.remaining -= 1;
            if (doclines.frame.mode == .flat) self.writeText("\\n") else try self.lineBreak(doclines.frame.indent);
            return false;
        }
        const frame = self.stack.pop() orelse return true;
        switch (frame.doc.*) {
            .empty => {},
            .text => |bytes| self.writeText(bytes),
            .concat => |items| {
                var index = items.len;
                while (index > 0) {
                    index -= 1;
                    try self.stack.append(arena, .{ .doc = items[index], .indent = frame.indent, .mode = frame.mode });
                }
            },
            .link => |link| {
                if (link.next) |next| try self.stack.append(arena, .{ .doc = next, .indent = frame.indent, .mode = frame.mode });
                try self.stack.append(arena, .{ .doc = link.head, .indent = frame.indent, .mode = frame.mode });
            },
            .softline => if (frame.mode == .flat)
                self.writeText(" ")
            else
                try self.lineBreak(frame.indent),
            .hardline => try self.lineBreak(frame.indent),
            .aligned => |item| try self.stack.append(arena, .{
                .doc = item,
                .indent = self.column,
                .mode = frame.mode,
            }),
            .group, .local_group => |item| {
                const scope: FitScope = if (frame.doc.* == .group) .group else .local;
                const mode: Mode = if (frame.mode == .flat or
                    self.fits(work, max_width -| self.column, item, scope)) .flat else .broken;
                try self.stack.append(arena, .{ .doc = item, .indent = frame.indent, .mode = mode });
            },
            .fill_sep => |fill| self.fill = .{ .fill = fill, .index = 0, .frame = frame, .separated = false },
            .docline => |count| self.doclines = .{ .remaining = count, .frame = frame },
        }
        return false;
    }
    /// A probe is bounded by `max_probe_steps`; it charges the steps it took.
    fn fits(
        self: *Renderer,
        work: *poll.WorkBudget,
        available: usize,
        candidate: *const Doc,
        scope: FitScope,
    ) bool {
        var steps: usize = 0;
        defer _ = work.take(steps);
        // SAFETY: ProbeStack reads only initialized slots below `len`.
        var commands: ProbeStack = .{ .items = undefined };
        _ = commands.push(.{ .frame = .{ .doc = candidate, .indent = 0, .mode = .flat } });
        var pending = if (scope == .group) self.stack.items.len else 0;
        var remaining = available;
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
                        return scope == .first_line;
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
                        const width = flatWidthLimited(bytes, remaining) orelse
                            return scope == .first_line or frame.mode == .broken;
                        if (width > remaining) return false;
                        remaining -= width;
                    },
                    .concat => |items| {
                        if (!commands.push(.{ .concat = .{ .items = items, .index = 0, .mode = frame.mode } })) return false;
                    },
                    .link => |link| {
                        if (link.next) |next| if (!commands.push(.{ .frame = .{
                            .doc = next,
                            .indent = 0,
                            .mode = frame.mode,
                        } })) return false;
                        if (!commands.push(.{ .frame = .{
                            .doc = link.head,
                            .indent = 0,
                            .mode = frame.mode,
                        } })) return false;
                    },
                    .softline => if (frame.mode == .flat) {
                        if (remaining == 0) return false;
                        remaining -= 1;
                    } else return true,
                    .hardline => return scope == .first_line or frame.mode == .broken,
                    .group, .local_group, .aligned => |item| if (!commands.push(.{ .frame = .{
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
    /// Queues text behind any indentation a line break left pending.
    fn writeText(self: *Renderer, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.spaces = self.pending_indent;
        self.pending_indent = 0;
        self.text = bytes;
    }
    fn lineBreak(self: *Renderer, indent: usize) Error!void {
        try self.output.append('\n');
        self.column = indent;
        self.pending_indent = indent;
    }
};

// --- Layout -----------------------------------------------------------------

const NestedDoc = struct {
    doc: *const Doc,
    has_content: bool,
    trailing_hardlines: usize,
};

/// Lays out one documented definition's annotation: its effect slots, then
/// its documentation decoded, normalized, and broken into lines and words.
const AnnotationCursor = struct {
    form: *Form,
    separator: bool,
    colon: usize,
    stage: union(enum) {
        slots: struct { part: usize = 0, ordinal: usize = 0, header: Chain = .{} },
        decode: struct { header: ?*const Doc, decoder: Decoder },
        normalize: struct { header: ?*const Doc, normalizer: doc_text.CodepointNormalizer },
        content: struct { header: ?*const Doc, content: ContentCursor },
    },

    const Result = union(enum) { pending, plain, annotated: *const Doc };

    /// The cursor for `parent.parts[index]` when its shape annotates the
    /// definition or registration after it.
    fn init(parent: Sequence, index: usize) ?AnnotationCursor {
        const form = parent.parts[index].form;
        const body_index = nextFormPart(parent, index) orelse return null;
        const defines = definitionFollows(parent, body_index);
        if (!defines and moduleRegistrationShape(parent, body_index) == null) return null;
        const delimited = switch (form.kind) {
            .delimited => |item| item,
            else => return null,
        };
        if (!std.mem.eql(u8, delimited.open, "(") and !std.mem.eql(u8, delimited.open, "[")) return null;
        const marks = delimited.marks;
        if (marks.comment or marks.repeated) return null;
        const colon = marks.colon orelse return null;
        // `@defm` reads only `(: "text")` as module documentation; any other
        // list before a registration is the caller's data and stays verbatim.
        if (!defines and marks.separator != null) return null;
        if (marks.separator) |separator| if (separator > colon) return null;
        if (marks.separator == null and colon != 0) return null;
        if (marks.forms != colon + 2 or marks.last.?.kind != .string) return null;
        return .{ .form = form, .separator = marks.separator != null, .colon = colon, .stage = .{ .slots = .{} } };
    }

    fn step(self: *AnnotationCursor, arena: std.mem.Allocator, docs: *DocBuilder, work: *poll.WorkBudget) Error!Result {
        const delimited = self.form.kind.delimited;
        switch (self.stage) {
            .slots => |*slots| {
                const parts = delimited.contents.parts;
                if (slots.ordinal <= self.colon) {
                    const part = parts[slots.part];
                    slots.part += 1;
                    const item = switch (part) {
                        .trivia => return .pending,
                        .form => |item| item,
                    };
                    const slot = try effectSlot(docs, item) orelse return .plain;
                    if (self.separator) {
                        if (slots.header.len != 0) try slots.header.append(docs, try docs.softline());
                        try slots.header.append(docs, slot);
                    }
                    slots.ordinal += 1;
                    return .pending;
                }
                const header: ?*const Doc = if (self.separator) try docs.group(try slots.header.doc(docs)) else null;
                self.stage = .{ .decode = .{
                    .header = header,
                    .decoder = try .init(arena, delimited.marks.last.?.kind.string),
                } };
            },
            .decode => |*decode| if (try decode.decoder.step()) |codepoints| {
                const header = decode.header;
                self.stage = .{ .normalize = .{
                    .header = header,
                    .normalizer = try .init(arena, .{ .codepoints = codepoints }),
                } };
            },
            .normalize => |*normalize| switch (try normalize.normalizer.advance(work)) {
                .pending => {},
                .complete => |normalized| {
                    const header = normalize.header;
                    self.stage = .{ .content = .{
                        .header = header,
                        .content = try .init(arena, normalized),
                    } };
                },
            },
            .content => |*content| if (try content.content.step(arena, docs)) |body| {
                const quoted = try docs.concat(&.{ try docs.text("\""), try docs.aligned(body), try docs.text("\"") });
                const header = content.header orelse return .{ .annotated = try docs.group(try docs.aligned(try docs.concat(&.{
                    try docs.text(delimited.open),
                    try docs.text(": "),
                    quoted,
                    try docs.text(delimited.close),
                }))) };
                const inside = try docs.aligned(try docs.concat(&.{ header, try docs.softline(), quoted }));
                return .{ .annotated = try docs.group(try docs.aligned(try docs.concat(&.{
                    try docs.text(delimited.open),
                    inside,
                    try docs.text(delimited.close),
                }))) };
            },
        }
        return .pending;
    }

    /// Whether this cursor's next step hands the budget to the normalizer,
    /// which charges its own work.
    fn delegates(self: *const AnnotationCursor) bool {
        return self.stage == .normalize;
    }
};

/// Decodes a string token the scanner closed, one codepoint or escape per
/// step, into storage sized by the token.
const Decoder = struct {
    token: []const u8,
    index: usize = 1,
    output: []u32,
    len: usize = 0,

    fn init(arena: std.mem.Allocator, token: []const u8) Error!Decoder {
        return .{ .token = token, .output = try arena.alloc(u32, token.len) };
    }

    fn step(self: *Decoder) Error!?[]const u32 {
        const body_end = self.token.len - 1;
        if (self.index == body_end) return self.output[0..self.len];
        const next = try decodeAt(self.token, self.index);
        self.index += next.len;
        if (next.codepoint != '\\') return self.emit(next.codepoint);
        if (self.index == body_end) return error.InvalidSource;
        const escaped = self.token[self.index];
        self.index += 1;
        return switch (escaped) {
            '\\' => self.emit('\\'),
            '"' => self.emit('"'),
            'n' => self.emit('\n'),
            't' => self.emit('\t'),
            'u' => {
                if (self.index == body_end or self.token[self.index] != '{') return error.InvalidSource;
                self.index += 1;
                var codepoint: u32 = 0;
                var digits: usize = 0;
                while (self.index < body_end and self.token[self.index] != '}') : (self.index += 1) {
                    digits += 1;
                    if (digits > 6) return error.InvalidSource;
                    codepoint = codepoint * 16 + (std.fmt.charToDigit(self.token[self.index], 16) catch
                        return error.InvalidSource);
                }
                if (self.index == body_end or digits == 0 or value.unicodeScalar(codepoint) == null)
                    return error.InvalidSource;
                self.index += 1;
                return self.emit(codepoint);
            },
            else => error.InvalidSource,
        };
    }

    fn emit(self: *Decoder, codepoint: u32) ?[]const u32 {
        self.output[self.len] = codepoint;
        self.len += 1;
        return null;
    }
};

/// Normalized documentation as prose: one fill per paragraph line, verbatim
/// lines kept as written. One codepoint, line, or word per step.
const ContentCursor = struct {
    text: []const u32,
    lines: []DocumentLine,
    line_count: usize = 0,
    phase: union(enum) {
        lines: struct { start: usize = 0, index: usize = 0, in_breaks: bool = false, end: usize = 0 },
        scan: struct { first: usize = 0, index: usize = 0, bulleted: bool = false, indented: bool = false },
        mark: struct { first: usize, last: usize, index: usize, verbatim: bool },
        build: struct { line: usize = 0, started: bool = false, words: ?WordCursor = null },
    } = .{ .lines = .{} },
    output: Chain = .{},

    const DocumentLine = struct { start: usize, end: usize, breaks: usize, verbatim: bool = false };

    fn init(arena: std.mem.Allocator, text: []const u32) Error!ContentCursor {
        return .{ .text = text, .lines = try arena.alloc(DocumentLine, text.len + 1) };
    }

    fn step(self: *ContentCursor, arena: std.mem.Allocator, docs: *DocBuilder) Error!?*const Doc {
        const text = self.text;
        switch (self.phase) {
            .lines => |*lines| {
                if (lines.start == text.len) {
                    self.phase = .{ .scan = .{} };
                    return null;
                }
                if (!lines.in_breaks) {
                    if (lines.index < text.len and text[lines.index] != '\n') {
                        lines.index += 1;
                    } else {
                        lines.end = lines.index;
                        lines.in_breaks = true;
                    }
                    return null;
                }
                if (lines.index < text.len and text[lines.index] == '\n') {
                    lines.index += 1;
                    return null;
                }
                self.lines[self.line_count] = .{ .start = lines.start, .end = lines.end, .breaks = lines.index - lines.end };
                self.line_count += 1;
                lines.start = lines.index;
                lines.in_breaks = false;
            },
            // Normalized prose is one line per paragraph or bullet, so a
            // paragraph of several lines without bullets, or any indented
            // line, is verbatim.
            .scan => |*scan| {
                if (scan.first == self.line_count) {
                    self.phase = .{ .build = .{} };
                    return null;
                }
                const line = self.lines[scan.index];
                scan.bulleted = scan.bulleted or isDocumentBullet(text, line.start, line.end);
                scan.indented = scan.indented or (line.start < line.end and text[line.start] == ' ');
                if (scan.index + 1 < self.line_count and line.breaks == 1) {
                    scan.index += 1;
                    return null;
                }
                // Built in locals: the new phase overwrites `scan`.
                const first = scan.first;
                const last = scan.index;
                const verbatim = !scan.bulleted and (scan.indented or last > first);
                self.phase = .{ .mark = .{ .first = first, .last = last, .index = first, .verbatim = verbatim } };
            },
            .mark => |*mark| {
                self.lines[mark.index].verbatim = mark.verbatim;
                if (mark.index != mark.last) {
                    mark.index += 1;
                    return null;
                }
                const next = mark.last + 1;
                self.phase = .{ .scan = .{ .first = next, .index = next } };
            },
            .build => |*build| {
                if (!build.started) {
                    build.started = true;
                    // A verbatim first paragraph keeps its indentation only
                    // if the first line has a column of its own; beside the
                    // quote the next pass would fold it.
                    if (self.line_count > 0 and self.lines[0].verbatim)
                        try self.output.append(docs, try docs.hardline());
                    return null;
                }
                if (build.line == self.line_count) return try self.output.doc(docs);
                const line = self.lines[build.line];
                const last = build.line + 1 == self.line_count;
                if (build.words == null) build.words = try WordCursor.init(arena, text, line, if (last) 2 else 0);
                const line_doc = try build.words.?.step(docs) orelse return null;
                build.words = null;
                try self.output.append(docs, line_doc);
                build.line += 1;
                if (last) return null;
                // A verbatim line cannot be flattened into `\n` escapes.
                if (line.verbatim or self.lines[build.line].verbatim) {
                    try self.output.appendHardlines(docs, line.breaks);
                } else {
                    try self.output.append(docs, try docs.node(.{ .docline = line.breaks }));
                }
            },
        }
        return null;
    }
};

/// One documentation line escaped as source: a verbatim line whole, a prose
/// line as fill words. One codepoint per step, into storage sized by the line.
const WordCursor = struct {
    text: []const u32,
    verbatim: bool,
    bullet: bool,
    index: usize,
    end: usize,
    reserve: usize,
    bytes: []u8,
    len: usize = 0,
    word_start: ?usize = null,
    width: usize = 0,
    /// The word holds a line break, so it never shares a line.
    breaks: bool = false,
    words: [][]const u8,
    widths: []usize,
    word_count: usize = 0,

    /// The most bytes one escaped codepoint takes, `\u{9f}`.
    const max_escape = 6;

    fn init(arena: std.mem.Allocator, text: []const u32, line: ContentCursor.DocumentLine, reserve: usize) Error!WordCursor {
        const bullet = !line.verbatim and isDocumentBullet(text, line.start, line.end);
        const length = line.end - line.start;
        const word_capacity = if (line.verbatim) 0 else (length + 1) / 2;
        return .{
            .text = text,
            .verbatim = line.verbatim,
            .bullet = bullet,
            .index = line.start + @as(usize, if (bullet and line.start + 1 < line.end) 2 else 0),
            .end = line.end,
            .reserve = reserve,
            .bytes = try arena.alloc(u8, length * max_escape),
            .words = try arena.alloc([]const u8, word_capacity),
            .widths = try arena.alloc(usize, word_capacity),
        };
    }

    fn step(self: *WordCursor, docs: *DocBuilder) Error!?*const Doc {
        if (self.index == self.end) {
            if (self.verbatim) return try docs.text(self.bytes[0..self.len]);
            self.finishWord();
            const fill = try docs.node(.{ .fill_sep = .{
                .words = self.words[0..self.word_count],
                .widths = self.widths[0..self.word_count],
                .final_reserve = self.reserve,
            } });
            if (!self.bullet) return fill;
            if (self.word_count == 0) return try docs.text("-");
            return try docs.concat(&.{ try docs.text("- "), try docs.aligned(fill) });
        }
        const codepoint = self.text[self.index];
        self.index += 1;
        if (!self.verbatim and codepoint == ' ') {
            self.finishWord();
            return null;
        }
        if (self.word_start == null) {
            self.word_start = self.len;
            self.width = 0;
            self.breaks = false;
        }
        self.len += try escapeInto(self.bytes[self.len..], codepoint);
        self.width += 1;
        self.breaks = self.breaks or isLineBreak(@intCast(@min(codepoint, 0x10ffff)));
        return null;
    }

    fn finishWord(self: *WordCursor) void {
        const start = self.word_start orelse return;
        self.words[self.word_count] = self.bytes[start..self.len];
        self.widths[self.word_count] = if (self.breaks) max_width + 1 else self.width;
        self.word_count += 1;
        self.word_start = null;
    }
};

fn escapeInto(output: []u8, codepoint: u32) Error!usize {
    switch (codepoint) {
        '\\' => return copyInto(output, "\\\\"),
        '"' => return copyInto(output, "\\\""),
        '\t' => return copyInto(output, "\\t"),
        0...8, 10...0x1f, 0x7f...0x9f => {
            const escaped = std.fmt.bufPrint(output, "\\u{{{x}}}", .{codepoint}) catch
                @panic("formatter escape buffer is too small");
            return escaped.len;
        },
        else => {
            const scalar = value.unicodeScalar(codepoint) orelse return error.InvalidSource;
            return std.unicode.utf8Encode(scalar, output) catch error.InvalidSource;
        },
    }
}

fn copyInto(output: []u8, bytes: []const u8) usize {
    @memcpy(output[0..bytes.len], bytes);
    return bytes.len;
}

/// Lays out one sequence: its neighbour index, its locals, its annotations,
/// then one part per step.
const SequenceCursor = struct {
    sequence: *Sequence,
    root: bool,
    phase: enum { previous, next, attached, locals, annotate, body } = .previous,
    index: usize = 0,
    last_form: usize = none,
    locals_open: ?usize = null,
    locals_names: usize = 0,
    locals: ?LocalsBounds = null,
    annotation: ?AnnotationCursor = null,
    output: Chain = .{},
    line: Chain = .{},
    have_content: bool = false,
    previous_comment: bool = false,
    pending_definition: ?usize = null,
    skip_through: ?usize = null,
    previous_form: ?usize = null,
    newlines: usize = 0,

    fn init(arena: std.mem.Allocator, sequence: *Sequence, root: bool) Error!SequenceCursor {
        const count = sequence.parts.len;
        sequence.neighbours = .{
            .previous = try arena.alloc(usize, count),
            .next = try arena.alloc(usize, count),
            .attached = try arena.alloc(usize, count),
        };
        return .{ .sequence = sequence, .root = root };
    }

    fn delegates(self: *const SequenceCursor) bool {
        return self.phase == .annotate and self.annotation != null and self.annotation.?.delegates();
    }

    const Result = union(enum) { pending, root: *const Doc, nested: NestedDoc };

    fn step(
        self: *SequenceCursor,
        arena: std.mem.Allocator,
        docs: *DocBuilder,
        work: *poll.WorkBudget,
    ) Error!Result {
        const sequence = self.sequence.*;
        const parts = sequence.parts;
        const neighbours = sequence.neighbours;
        switch (self.phase) {
            .previous => {
                if (self.index == parts.len) {
                    self.phase = .next;
                    self.last_form = none;
                    return .pending;
                }
                neighbours.previous[self.index] = self.last_form;
                if (parts[self.index] == .form) self.last_form = self.index;
                self.index += 1;
            },
            .next => {
                if (self.index == 0) {
                    self.phase = .attached;
                    self.index = parts.len;
                    return .pending;
                }
                self.index -= 1;
                neighbours.next[self.index] = self.last_form;
                if (parts[self.index] == .form) self.last_form = self.index;
            },
            // Backward, so each comment's documented target is decided from
            // the comment after it.
            .attached => {
                if (self.index == 0) {
                    self.phase = if (self.root) .annotate else .locals;
                    return .pending;
                }
                self.index -= 1;
                neighbours.attached[self.index] = attachedTarget(sequence, self.index);
            },
            .locals => {
                if (self.locals_open == none or self.index == parts.len) {
                    self.phase = .annotate;
                    self.index = 0;
                    return .pending;
                }
                const index = self.index;
                self.index += 1;
                switch (parts[index]) {
                    .trivia => |trivia| if (trivia.kind == .comment and self.locals_open != null) {
                        self.locals_open = none;
                    },
                    .form => |form_item| {
                        const bytes = switch (form_item.kind) {
                            .atom => |atom| atom.bytes,
                            else => {
                                self.locals_open = none;
                                return .pending;
                            },
                        };
                        if (self.locals_open == null) {
                            self.locals_open = if (std.mem.eql(u8, bytes, "|")) index else none;
                        } else if (std.mem.eql(u8, bytes, "|")) {
                            if (self.locals_names > 0) self.locals = .{ .open = self.locals_open.?, .close = index };
                            self.locals_open = none;
                        } else self.locals_names += 1;
                    },
                }
            },
            .annotate => {
                if (self.annotation) |*annotation| {
                    switch (try annotation.step(arena, docs, work)) {
                        .pending => return .pending,
                        .plain => {},
                        .annotated => |layout| annotation.form.annotated = layout,
                    }
                    self.annotation = null;
                    return .pending;
                }
                if (self.index == parts.len) {
                    self.phase = .body;
                    self.index = 0;
                    return .pending;
                }
                const index = self.index;
                self.index += 1;
                if (parts[index] == .form) self.annotation = AnnotationCursor.init(sequence, index);
            },
            .body => {
                if (self.index == parts.len) return self.finish(docs);
                const index = self.index;
                self.index += 1;
                if (self.root) try self.rootPart(docs, index) else try self.nestedPart(docs, index);
            },
        }
        return .pending;
    }

    fn finish(self: *SequenceCursor, docs: *DocBuilder) Error!Result {
        if (self.root) {
            try self.flushRootLine(docs);
            if (self.have_content) try self.output.append(docs, try docs.hardline());
            return .{ .root = try self.output.doc(docs) };
        }
        const trailing_hardlines = if (self.previous_comment)
            @min(@max(self.newlines, 1), 2)
        else
            @min(self.newlines, 2);
        return .{ .nested = .{
            .doc = try self.output.doc(docs),
            .has_content = self.have_content or self.output.len > 0 or trailing_hardlines > 0,
            .trailing_hardlines = trailing_hardlines,
        } };
    }

    fn rootPart(self: *SequenceCursor, docs: *DocBuilder, part_index: usize) Error!void {
        const sequence = self.sequence.*;
        if (self.skip_through) |end| {
            if (part_index <= end) return;
            self.skip_through = null;
        }
        switch (sequence.parts[part_index]) {
            .trivia => |trivia| switch (trivia.kind) {
                .space => self.newlines += trivia.breaks,
                .comment => {
                    if (existingDefinitionHeader(sequence, part_index, trivia.bytes)) |header| {
                        if (self.pending_definition == header.part) {
                            self.newlines = 0;
                            return;
                        }
                        if (self.have_content) try self.rootBreak(docs, 2);
                        try self.line.append(docs, try definitionHeader(docs, header.name, header.declaration.?));
                        self.claim(header.part);
                        return;
                    }
                    if (existingModuleHeader(sequence, part_index, trivia.bytes)) |header| {
                        if (self.have_content) try self.rootBreak(docs, 2);
                        try self.line.append(docs, try moduleHeader(docs, header.name));
                        self.claim(header.part);
                        return;
                    }
                    if (attachedDefinitionAfterComment(sequence, part_index)) |header| {
                        if (self.pending_definition != header.part) {
                            if (self.have_content) try self.rootBreak(docs, 2);
                            try self.line.append(docs, if (header.module)
                                try moduleHeader(docs, header.name)
                            else
                                try definitionHeader(docs, header.name, header.declaration.?));
                            self.claim(header.part);
                        }
                    }
                    if (self.have_content) {
                        if (self.previous_comment or self.newlines > 0) {
                            try self.rootBreak(docs, @min(@max(self.newlines, 1), 2));
                        } else try self.line.append(docs, try docs.text(" "));
                    }
                    try self.line.append(docs, try docs.text(trivia.bytes));
                    self.have_content = true;
                    self.previous_comment = true;
                    self.newlines = 0;
                },
            },
            .form => {
                var fill_pair = false;
                const skip_header = self.pending_definition == part_index;
                const name = if (skip_header) null else definitionName(sequence, part_index);
                const registration = if (name != null)
                    null
                else
                    moduleRegistrationInfo(sequence, part_index);
                const module_name = if (skip_header)
                    null
                else if (registration) |info|
                    info.name
                else
                    null;
                if (name orelse module_name) |header_name| {
                    if (self.have_content) try self.rootBreak(docs, 2);
                    try self.line.append(docs, if (name != null)
                        try definitionHeader(docs, header_name, definitionDeclaration(sequence, part_index).?)
                    else
                        try moduleHeader(docs, header_name));
                    try self.rootBreak(docs, 1);
                } else if (self.have_content) {
                    if (self.previous_comment or self.newlines > 0) {
                        try self.rootBreak(docs, @min(@max(self.newlines, 1), 2));
                    } else fill_pair = true;
                }
                const packed_registration: ?*const Doc = if (registration) |info|
                    if (moduleRegistrationIsPackable(sequence, part_index, info))
                        try formatModuleRegistration(docs, sequence, part_index, info)
                    else
                        null
                else
                    null;
                const item = packed_registration orelse try partLayout(docs, sequence, part_index);
                try self.line.append(docs, if (fill_pair)
                    try docs.localGroup(try docs.concat(&.{ try docs.softline(), item }))
                else
                    item);
                if (packed_registration != null) self.skip_through = registration.?.terminator;
                self.have_content = true;
                self.previous_comment = false;
                if (!(skip_header and isAnnotationCandidate(sequence.parts[part_index].form) and
                    definitionInfo(sequence, part_index) != null))
                {
                    self.pending_definition = null;
                }
                self.newlines = 0;
            },
        }
    }

    fn claim(self: *SequenceCursor, part: usize) void {
        self.have_content = true;
        self.previous_comment = true;
        self.pending_definition = part;
        self.newlines = 0;
    }

    fn rootBreak(self: *SequenceCursor, docs: *DocBuilder, count: usize) Error!void {
        try self.flushRootLine(docs);
        try self.output.appendHardlines(docs, count);
    }

    fn flushRootLine(self: *SequenceCursor, docs: *DocBuilder) Error!void {
        if (self.line.len == 0) return;
        try self.output.append(docs, try self.line.doc(docs));
        self.line = .{};
    }

    fn nestedPart(self: *SequenceCursor, docs: *DocBuilder, part_index: usize) Error!void {
        const sequence = self.sequence.*;
        const output = &self.output;
        switch (sequence.parts[part_index]) {
            .trivia => |trivia| switch (trivia.kind) {
                .space => self.newlines += trivia.breaks,
                .comment => {
                    if (existingDefinitionHeader(sequence, part_index, trivia.bytes)) |header| {
                        if (self.pending_definition == header.part) {
                            self.newlines = 0;
                            return;
                        }
                        try output.appendHardlines(docs, if (self.have_content) 2 else 1);
                        try output.append(docs, try definitionHeader(docs, header.name, header.declaration.?));
                        self.claim(header.part);
                        return;
                    }
                    if (attachedDefinitionAfterComment(sequence, part_index)) |header| {
                        if (self.pending_definition != header.part) {
                            try output.appendHardlines(docs, if (self.have_content) 2 else 1);
                            try output.append(docs, try definitionHeader(docs, header.name, header.declaration.?));
                            self.claim(header.part);
                        }
                    }
                    if (self.have_content) {
                        if (self.previous_comment or self.newlines > 0) {
                            try output.appendHardlines(docs, @min(@max(self.newlines, 1), 2));
                        } else try output.append(docs, try docs.text(" "));
                    }
                    try output.append(docs, try docs.text(trivia.bytes));
                    self.have_content = true;
                    self.previous_comment = true;
                    self.newlines = 0;
                },
            },
            .form => {
                var fill_pair = false;
                const name = if (self.pending_definition == part_index) null else definitionName(sequence, part_index);
                if (name) |definition_name| {
                    try output.appendHardlines(docs, if (self.have_content) 2 else 1);
                    try output.append(docs, try definitionHeader(
                        docs,
                        definition_name,
                        definitionDeclaration(sequence, part_index).?,
                    ));
                    try output.append(docs, try docs.hardline());
                } else if (self.have_content) {
                    if (self.previous_comment) {
                        try output.appendHardlines(docs, @min(@max(self.newlines, 1), 2));
                    } else if (!tightLocalsGap(self.locals, self.previous_form, part_index)) {
                        if (self.newlines > 0) {
                            try output.appendHardlines(docs, @min(self.newlines, 2));
                        } else fill_pair = true;
                    }
                } else if (self.newlines > 0) {
                    try output.appendHardlines(docs, @min(self.newlines, 2));
                }
                const item: ?*const Doc = if (self.locals) |bounds|
                    if (part_index == bounds.open)
                        try formatLocals(docs, sequence, bounds)
                    else if (part_index > bounds.close)
                        try partLayout(docs, sequence, part_index)
                    else
                        null
                else
                    try partLayout(docs, sequence, part_index);
                if (fill_pair) {
                    const separator = try docs.softline();
                    try output.append(docs, if (item) |laid_out|
                        try docs.localGroup(try docs.concat(&.{ separator, laid_out }))
                    else
                        try docs.localGroup(separator));
                } else if (item) |laid_out| try output.append(docs, laid_out);
                self.have_content = true;
                self.previous_comment = false;
                self.previous_form = part_index;
                if (!(self.pending_definition == part_index and
                    isAnnotationCandidate(sequence.parts[part_index].form) and
                    definitionInfo(sequence, part_index) != null))
                {
                    self.pending_definition = null;
                }
                self.newlines = 0;
            },
        }
    }
};

fn partLayout(docs: *DocBuilder, parent: Sequence, part_index: usize) Error!*const Doc {
    const form_item = parent.parts[part_index].form;
    if (form_item.annotated) |layout| return layout;
    return switch (form_item.kind) {
        .atom => |atom| docs.text(atom.bytes),
        .string => |bytes| docs.text(bytes),
        .delimited => form_item.layout.?,
    };
}
fn definitionHeader(docs: *DocBuilder, name: []const u8, declaration: Declaration) Error!*const Doc {
    return docs.concat(&.{ try docs.text(declaration.header()), try docs.text(name) });
}
fn moduleHeader(docs: *DocBuilder, name: []const u8) Error!*const Doc {
    return docs.concat(&.{ try docs.text("### module "), try docs.text(name) });
}
fn formatDelimited(docs: *DocBuilder, delimited: Delimited, nested_doc: NestedDoc) Error!*const Doc {
    if (!nested_doc.has_content)
        return docs.concat(&.{ try docs.text(delimited.open), try docs.text(delimited.close) });
    // SAFETY: only the prefix counted by `count` is read.
    var pieces: [5]*const Doc = undefined;
    var count: usize = 0;
    pieces[count] = try docs.text(delimited.open);
    count += 1;
    pieces[count] = try docs.aligned(nested_doc.doc);
    count += 1;
    for (0..nested_doc.trailing_hardlines) |_| {
        pieces[count] = try docs.hardline();
        count += 1;
    }
    pieces[count] = try docs.text(delimited.close);
    count += 1;
    return docs.group(try docs.aligned(try docs.concat(pieces[0..count])));
}
/// The registration's body reuses the contents layout computed for it; only
/// the fixed operands after it are laid out here.
fn formatModuleRegistration(
    docs: *DocBuilder,
    sequence: Sequence,
    start: usize,
    registration: ModuleRegistration,
) Error!*const Doc {
    const body_form = sequence.parts[registration.body].form;
    const delimited = body_form.kind.delimited;
    const nested_doc = body_form.nested.?;

    var closing: Chain = .{};
    try closing.append(docs, try docs.text(delimited.close));
    var previous_form = registration.body;
    var index = sequence.neighbours.next[registration.body];
    while (index <= registration.terminator) : (index = sequence.neighbours.next[index]) {
        const breaks = formBreakCount(sequence, previous_form, index);
        if (breaks == 0) {
            try closing.append(docs, try docs.localGroup(try docs.concat(&.{
                try docs.softline(),
                try partLayout(docs, sequence, index),
            })));
        } else {
            try closing.appendHardlines(docs, breaks);
            try closing.append(docs, try partLayout(docs, sequence, index));
        }
        previous_form = index;
    }

    var body: Chain = .{};
    try body.append(docs, try docs.text(delimited.open));
    try body.append(docs, try docs.aligned(nested_doc.doc));
    try body.appendHardlines(docs, nested_doc.trailing_hardlines);
    try body.append(docs, try closing.doc(docs));
    const registered_body = try docs.group(try docs.aligned(try body.doc(docs)));
    // A module's documentation stands on its own line above the operands.
    if (start == registration.body) return registered_body;
    return docs.concat(&.{ try partLayout(docs, sequence, start), try docs.hardline(), registered_body });
}
fn formatLocals(docs: *DocBuilder, sequence: Sequence, bounds: LocalsBounds) Error!*const Doc {
    var names: Chain = .{};
    var index = sequence.neighbours.next[bounds.open];
    while (index < bounds.close) : (index = sequence.neighbours.next[index]) {
        if (names.len != 0) try names.append(docs, try docs.softline());
        try names.append(docs, try docs.text(sequence.parts[index].form.kind.atom.bytes));
    }
    const body = try docs.aligned(try names.doc(docs));
    return docs.group(try docs.concat(&.{ try docs.text("|"), body, try docs.text("|") }));
}
/// An effect slot's layout: a word, or a nested effect, which keeps the
/// layout of the quotation it is.
fn effectSlot(docs: *DocBuilder, item: *Form) Error!?*const Doc {
    if (wordBytes(item)) |bytes| return try docs.text(bytes);
    return switch (item.kind) {
        .delimited => |delimited| if (std.mem.eql(u8, delimited.open, "(")) item.layout.? else null,
        else => null,
    };
}

// --- The cursor -------------------------------------------------------------

/// Formats source as a resumable cursor. Every pass draws on the budget it is
/// lent: one unit per source codepoint, sequence part, documentation
/// codepoint, document node, or output codepoint. It formats any source whose
/// delimiters balance and whose strings close; `format` additionally rejects
/// source the reader would not accept.
pub const Cursor = struct {
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    allocator: std.mem.Allocator,
    /// Owns every intermediate structure; allocated so the cursor can move.
    arena: *std.heap.ArenaAllocator,
    docs: DocBuilder,
    phase: union(enum) {
        measure: Measure,
        build: Build,
        prepare: struct { root: *Sequence, containers: []*Form, index: usize, cursor: SequenceCursor },
        root: SequenceCursor,
        render: Renderer,
        materialize: struct { chunks: poll.ChunkList(u8).Iterator, output: []u8, index: usize },
    },

    pub fn init(allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Cursor {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        return .{
            .allocator = allocator,
            .arena = arena,
            .docs = .{ .allocator = arena.allocator() },
            .phase = .{ .measure = try .init(arena.allocator(), source) },
        };
    }

    pub fn deinit(self: *Cursor) void {
        if (self.phase == .materialize) self.allocator.free(self.phase.materialize.output);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// The formatted source, owned by the caller's allocator, once done.
    pub fn advance(self: *Cursor, work: *poll.WorkBudget) Error!poll.Progress([]u8) {
        const arena = self.arena.allocator();
        while (true) {
            // A nested normalizer charges its own work.
            const delegated = switch (self.phase) {
                .prepare => |*prepare| prepare.cursor.delegates(),
                .root => |*root| root.delegates(),
                else => false,
            };
            if (!delegated and !work.spend()) return .pending;
            switch (self.phase) {
                .measure => |*measure| if (try measure.step(arena)) {
                    const build = try Build.init(arena, measure);
                    self.phase = .{ .build = build };
                },
                .build => |*build| if (try build.step(arena)) {
                    try self.prepareFrom(build.root, build.containers, 0);
                },
                .prepare => |*prepare| switch (try prepare.cursor.step(arena, &self.docs, work)) {
                    .pending => {},
                    .root => unreachable,
                    .nested => |nested_doc| {
                        const container = prepare.containers[prepare.index];
                        container.nested = nested_doc;
                        container.layout = try formatDelimited(&self.docs, container.kind.delimited, nested_doc);
                        try self.prepareFrom(prepare.root, prepare.containers, prepare.index + 1);
                    },
                },
                .root => |*root| switch (try root.step(arena, &self.docs, work)) {
                    .pending => {},
                    .nested => unreachable,
                    .root => |document| self.phase = .{ .render = try .init(arena, document) },
                },
                .render => |*renderer| if (try renderer.step(arena, work)) {
                    // Read before the new phase overwrites `renderer`.
                    const chunks = renderer.output.iterator();
                    const output = try self.allocator.alloc(u8, renderer.output.count);
                    self.phase = .{ .materialize = .{ .chunks = chunks, .output = output, .index = 0 } };
                },
                .materialize => |*materialize| {
                    if (materialize.index == materialize.output.len) {
                        const output = materialize.output;
                        materialize.output = &.{};
                        return .{ .complete = output };
                    }
                    materialize.output[materialize.index] = materialize.chunks.next().?.*;
                    materialize.index += 1;
                },
            }
            // The normalizer returns early only once the budget is spent.
            if (delegated and work.exhausted()) return .pending;
        }
    }

    /// Prepares containers children first, then the root.
    fn prepareFrom(self: *Cursor, root: *Sequence, containers: []*Form, index: usize) Error!void {
        const arena = self.arena.allocator();
        if (index == containers.len) {
            self.phase = .{ .root = try .init(arena, root, true) };
            return;
        }
        self.phase = .{ .prepare = .{
            .root = root,
            .containers = containers,
            .index = index,
            .cursor = try .init(arena, &containers[index].kind.delimited.contents, false),
        } };
    }
};

/// Parses source without evaluating it, formats its CST, and returns owned
/// UTF-8. Runs on its caller's thread for host tools; a unit drives `Cursor`
/// on its own budget instead.
pub fn format(allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    var validation_host = heap.HostOwner.init(allocator);
    defer validation_host.cleanup().drain();
    try validateSource(validation_host.cleanup(), source);
    var cursor = try Cursor.init(allocator, source);
    defer cursor.deinit();
    var work = poll.unbounded();
    return poll.driveFallible([]u8, &cursor, .{&work});
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

// --- Shape predicates -------------------------------------------------------
//
// Each reads a part's neighbours through the sequence's index, so each is
// constant work.

fn nextFormPart(sequence: Sequence, after: usize) ?usize {
    const index = sequence.neighbours.next[after];
    return if (index == none) null else index;
}
fn previousFormPart(sequence: Sequence, before: usize) ?usize {
    const index = sequence.neighbours.previous[before];
    return if (index == none) null else index;
}
fn atomOf(form_item: *const Form) ?Atom {
    return switch (form_item.kind) {
        .atom => |atom| atom,
        else => null,
    };
}
fn definitionFollows(sequence: Sequence, current: usize) bool {
    if (!sequence.definitions) return false;
    const name_index = nextFormPart(sequence, current) orelse return false;
    const name = atomOf(sequence.parts[name_index].form) orelse return false;
    if (!name.quoted_symbol) return false;
    const terminator_index = nextFormPart(sequence, name_index) orelse return false;
    const terminator = atomOf(sequence.parts[terminator_index].form) orelse return false;
    return Declaration.fromWord(terminator.bytes) != null;
}
const Declaration = enum {
    def,
    defp,
    set,
    setp,
    test_decl,

    fn fromWord(word: []const u8) ?Declaration {
        if (std.mem.eql(u8, word, "def")) return .def;
        if (std.mem.eql(u8, word, "defp")) return .defp;
        if (std.mem.eql(u8, word, "set")) return .set;
        if (std.mem.eql(u8, word, "setp")) return .setp;
        if (std.mem.eql(u8, word, "test")) return .test_decl;
        return null;
    }

    fn header(self: Declaration) []const u8 {
        return switch (self) {
            .def => "### def ",
            .defp => "### defp ",
            .set => "### set ",
            .setp => "### setp ",
            .test_decl => "### test ",
        };
    }
};
const DefinitionInfo = struct {
    name: []const u8,
    declaration: Declaration,
};
fn definitionInfo(sequence: Sequence, start: usize) ?DefinitionInfo {
    const first = sequence.parts[start].form;
    if (!isAnnotationCandidate(first)) {
        if (previousFormPart(sequence, start)) |previous| {
            if (isAnnotationCandidate(sequence.parts[previous].form)) return null;
        }
    }
    const body_index = if (isAnnotationCandidate(first))
        nextFormPart(sequence, start) orelse return null
    else
        start;
    const body = sequence.parts[body_index].form;
    if (!definitionFollows(sequence, body_index)) return null;
    const quoted_index = nextFormPart(sequence, body_index).?;
    const terminator_index = nextFormPart(sequence, quoted_index).?;
    const terminator = sequence.parts[terminator_index].form.kind.atom.bytes;
    const declaration = Declaration.fromWord(terminator) orelse return null;
    const set_binding = declaration == .set or declaration == .setp;
    if (set_binding) {
        if (!isLiteralValueForm(body)) return null;
    } else if (!isListForm(body)) return null;
    const quoted = sequence.parts[quoted_index].form.kind.atom.bytes;
    return .{
        .name = quoted[1..],
        .declaration = declaration,
    };
}
fn definitionName(sequence: Sequence, start: usize) ?[]const u8 {
    return (definitionInfo(sequence, start) orelse return null).name;
}
fn definitionDeclaration(sequence: Sequence, start: usize) ?Declaration {
    return (definitionInfo(sequence, start) orelse return null).declaration;
}
fn isLiteralValueForm(form_item: *const Form) bool {
    return switch (form_item.kind) {
        .string, .delimited => true,
        .atom => |atom| (atom.bytes.len > 0 and (atom.bytes[0] == '`' or atom.bytes[0] == '\\')) or atom.number,
    };
}
/// `(body) 'name @defm`: the fixed-arity registration shape that earns a
/// navigation header, mirroring definition navigation. A computed name gets
/// no header, exactly as a definition does. A phrase using ordinary `cat`
/// composition is not constructor metadata and therefore earns no registration
/// header.
fn moduleRegistrationName(sequence: Sequence, start: usize) ?[]const u8 {
    return (moduleRegistrationInfo(sequence, start) orelse return null).name;
}
const ModuleRegistration = struct {
    name: []const u8,
    body: usize,
    terminator: usize,
};
/// A registration phrase, from a leading annotation when one documents it.
/// The annotation claims the phrase's header, so the operands after it do not.
fn moduleRegistrationInfo(sequence: Sequence, start: usize) ?ModuleRegistration {
    if (!sequence.definitions) return null;
    if (isAnnotationCandidate(sequence.parts[start].form))
        return moduleRegistrationShape(sequence, nextFormPart(sequence, start) orelse return null);
    const registration = moduleRegistrationShape(sequence, start) orelse return null;
    if (previousFormPart(sequence, start)) |previous|
        if (isAnnotationCandidate(sequence.parts[previous].form)) return null;
    return registration;
}
fn moduleRegistrationShape(sequence: Sequence, start: usize) ?ModuleRegistration {
    if (!sequence.definitions) return null;
    const head = sequence.parts[start].form;
    if (!isListForm(head) or isAnnotationCandidate(head)) return null;
    const name_index = nextFormPart(sequence, start) orelse return null;
    const name = atomOf(sequence.parts[name_index].form) orelse return null;
    if (!name.quoted_symbol) return null;
    const terminator_index = nextFormPart(sequence, name_index) orelse return null;
    const terminator = atomOf(sequence.parts[terminator_index].form) orelse return null;
    if (!std.mem.eql(u8, terminator.bytes, "@defm")) return null;
    return .{ .name = name.bytes[1..], .body = start, .terminator = terminator_index };
}
/// Packable only when no comment sits among its operands; the scan stops at
/// the first comment, and the operands are a fixed handful of forms.
fn moduleRegistrationIsPackable(
    sequence: Sequence,
    start: usize,
    registration: ModuleRegistration,
) bool {
    if (sequence.parts[registration.body].form.kind != .delimited) return false;
    for (sequence.parts[start + 1 .. registration.terminator + 1]) |part| switch (part) {
        .trivia => |trivia| if (trivia.kind == .comment) return false,
        .form => {},
    };
    return true;
}
/// Line breaks between two forms with only space between them.
fn formBreakCount(sequence: Sequence, before: usize, after: usize) usize {
    var count: usize = 0;
    for (sequence.parts[before + 1 .. after]) |part| switch (part) {
        .trivia => |trivia| {
            if (trivia.kind == .space) count = @min(count + trivia.breaks, 2);
        },
        .form => unreachable,
    };
    return count;
}
fn isListForm(form_item: *const Form) bool {
    return switch (form_item.kind) {
        .delimited => |item| item.open[0] != '{',
        .string => true,
        else => false,
    };
}
fn isAnnotationCandidate(form_item: *const Form) bool {
    const delimited = switch (form_item.kind) {
        .delimited => |item| if (item.open[0] != '{') item else return false,
        else => return false,
    };
    return delimited.marks.colon != null or delimited.marks.separator != null;
}
const HeaderTarget = struct {
    part: usize,
    name: []const u8,
    module: bool = false,
    declaration: ?Declaration = null,
};
fn existingDefinitionHeader(sequence: Sequence, index: usize, bytes: []const u8) ?HeaderTarget {
    const definition_prefix = std.mem.startsWith(u8, bytes, "# def ") or
        std.mem.startsWith(u8, bytes, "### def ") or
        std.mem.startsWith(u8, bytes, "# defp ") or
        std.mem.startsWith(u8, bytes, "### defp ") or
        std.mem.startsWith(u8, bytes, "# set ") or
        std.mem.startsWith(u8, bytes, "### set ") or
        std.mem.startsWith(u8, bytes, "# setp ") or
        std.mem.startsWith(u8, bytes, "### setp ");
    const test_prefix = std.mem.startsWith(u8, bytes, "# test ") or
        std.mem.startsWith(u8, bytes, "### test ");
    if (!definition_prefix and !test_prefix) return null;
    const next = nextFormPart(sequence, index) orelse return null;
    // The form before `next` is the last before the comment, so the form
    // after it is `next`: a header may follow its annotation.
    const part = if (definitionInfo(sequence, next) != null)
        next
    else if (previousFormPart(sequence, next)) |previous|
        if (definitionInfo(sequence, previous) != null) previous else return null
    else
        return null;
    const declaration = definitionDeclaration(sequence, part) orelse return null;
    if (test_prefix and declaration != .test_decl) return null;
    return .{
        .part = part,
        .name = definitionName(sequence, part) orelse return null,
        .declaration = declaration,
    };
}
fn existingModuleHeader(sequence: Sequence, index: usize, bytes: []const u8) ?HeaderTarget {
    if (!std.mem.startsWith(u8, bytes, "# module ") and
        !std.mem.startsWith(u8, bytes, "### module ")) return null;
    const part = nextFormPart(sequence, index) orelse return null;
    return .{ .part = part, .name = moduleRegistrationName(sequence, part) orelse return null, .module = true };
}
/// The definition or registration a run of ordinary comments documents: each
/// comment one line above the next, the last one line above the form.
/// Decided from the part after `index`, whose own target is already known.
fn attachedTarget(sequence: Sequence, index: usize) usize {
    const parts = sequence.parts;
    const first = switch (parts[index]) {
        .trivia => |trivia| trivia,
        .form => return none,
    };
    if (first.kind != .comment or !ordinaryDefinitionComment(first.bytes)) return none;
    var next = index + 1;
    if (next == parts.len) return none;
    const newlines = switch (parts[next]) {
        .trivia => |trivia| if (trivia.kind == .space) trivia.breaks else 0,
        .form => 0,
    };
    if (newlines != 1) return none;
    next += 1;
    if (next == parts.len) return none;
    return switch (parts[next]) {
        .trivia => |trivia| if (trivia.kind == .comment and ordinaryDefinitionComment(trivia.bytes) and
            existingDefinitionHeader(sequence, next, trivia.bytes) == null)
            sequence.neighbours.attached[next]
        else
            none,
        .form => if (definitionName(sequence, next) != null or moduleRegistrationName(sequence, next) != null)
            next
        else
            none,
    };
}
fn attachedDefinitionAfterComment(sequence: Sequence, index: usize) ?HeaderTarget {
    const part = sequence.neighbours.attached[index];
    if (part == none) return null;
    if (definitionName(sequence, part)) |name| return .{
        .part = part,
        .name = name,
        .declaration = definitionDeclaration(sequence, part).?,
    };
    return .{ .part = part, .name = moduleRegistrationName(sequence, part).?, .module = true };
}
fn ordinaryDefinitionComment(bytes: []const u8) bool {
    return bytes.len > 0 and bytes[0] == '#' and (bytes.len == 1 or bytes[1] != '#');
}
const LocalsBounds = struct { open: usize, close: usize };
fn tightLocalsGap(bounds: ?LocalsBounds, previous: ?usize, current: usize) bool {
    const locals = bounds orelse return false;
    const prior = previous orelse return false;
    return prior >= locals.open and current <= locals.close;
}
fn wordBytes(form_item: *const Form) ?[]const u8 {
    const atom = atomOf(form_item) orelse return null;
    return if (atom.word) atom.bytes else null;
}
fn isDocumentBullet(text: []const u32, start: usize, end: usize) bool {
    return start < end and text[start] == '-' and (start + 1 == end or text[start + 1] == ' ');
}
fn closingDelimiter(open: u8) u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => unreachable,
    };
}
fn flatWidthLimited(bytes: []const u8, limit: usize) ?usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return null;
        if (index + length > bytes.len) return null;
        const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch return null;
        if (isLineBreak(codepoint)) return null;
        width += 1;
        if (width > limit) return width;
        index += length;
    }
    return width;
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
