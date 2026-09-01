//! Reader-time lowering of head binders into ordinary point-free forms.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const lexer = @import("lexer.zig");
const poll = @import("poll.zig");

pub const Value = value.Value;
pub const Span = lexer.Span;
pub const Diag = lexer.Diag;

pub const Name = struct {
    bytes: []const u8,
    span: Span,
};

pub const SpannedValue = struct {
    value: Value,
    span: Span,
};

pub const Error = error{ OutOfMemory, Parse };
const LocalName = enum(u32) { _ };
const LocalMap = poll.FixedMap(LocalName, usize);
const WalkFrame = struct {
    item: Value,
    next_child: ?usize = null,
};

pub const Lowered = struct {
    forms: []SpannedValue,
    values: heap.OwnedValueBuffer,
};
pub const LowerProgress = poll.Progress(Lowered);

/// Resumable binder validation and lowering. One call performs at most one
/// token byte, hash-table probe, nested-list edge, or output operation.
pub const LowerCursor = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    names: []const Name,
    body: []const SpannedValue,
    binder_span: Span,
    diag: *Diag,
    local_indices: []?usize,
    state: State,

    const NameWork = union(enum) {
        classify: struct { index: usize, cursor: lexer.ClassifyCursor },
        symbol: struct { index: usize, cursor: lexer.SymbolCursor },
        bytes: struct { index: usize, byte_index: usize = 0 },
        intern: struct { index: usize, cursor: intern.InternInsertionCursor },
        put: struct { index: usize, cursor: LocalMap.PutCursor },
    };
    const BodyWork = union(enum) {
        top,
        nested,
        lookup_top: LocalMap.RawLookupCursor,
        lookup_nested: struct {
            name: u32,
            cursor: LocalMap.RawLookupCursor,
        },
    };
    const Words = [3]u32;
    const Output = struct {
        words: Words,
        forms: []SpannedValue,
        values: heap.OwnedValueBuffer,
        output_index: usize = 0,
        prefix_step: usize = 0,
        body_index: usize = 0,
        body_step: usize = 0,
        epilogue_step: usize = 0,
    };
    const State = union(enum) {
        locals_init: LocalMap.InitCursor,
        names: struct { locals: LocalMap, work: NameWork },
        body: struct {
            locals: LocalMap,
            walk: poll.ChunkStack(WalkFrame),
            index: usize = 0,
            work: BodyWork = .top,
        },
        word_start: struct { words: Words = .{0} ** 3, index: usize = 0 },
        word_intern: struct {
            words: Words,
            index: usize,
            cursor: intern.InternInsertionCursor,
        },
        size: struct { words: Words, index: usize = 0, count: usize = 4 },
        allocate_output: struct { words: Words, count: usize },
        allocate_values: struct { words: Words, forms: []SpannedValue },
        output: Output,
        complete,

        fn deinit(self: *State, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .locals_init => |*cursor| cursor.deinit(),
                .names => |*names_state| names_state.locals.deinit(),
                .body => |*body_state| {
                    body_state.walk.deinit();
                    body_state.locals.deinit();
                },
                .allocate_values => |allocation| allocator.free(allocation.forms),
                .output => |*output| {
                    output.values.deinit();
                    allocator.free(output.forms);
                },
                .word_start, .word_intern, .size, .allocate_output, .complete => {},
            }
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        names: []const Name,
        body: []const SpannedValue,
        binder_span: Span,
        diag: *Diag,
    ) Error!LowerCursor {
        if (names.len == 0) {
            diag.set(binder_span, "a binder must contain at least one name");
            return error.Parse;
        }
        const local_indices = try allocator.alloc(?usize, body.len);
        return .{
            .allocator = allocator,
            .releases = releases,
            .names = names,
            .body = body,
            .binder_span = binder_span,
            .diag = diag,
            .local_indices = local_indices,
            .state = .{ .locals_init = LocalMap.initCursor(allocator, names.len) },
        };
    }

    pub fn deinit(self: *LowerCursor) void {
        self.state.deinit(self.allocator);
        self.allocator.free(self.local_indices);
        self.* = undefined;
    }

    fn failName(self: *LowerCursor, name: Name) error{Parse} {
        self.diag.setFmt(name.span, "invalid binder name `{s}`", .{name.bytes});
        return error.Parse;
    }

    fn advanceName(
        self: *LowerCursor,
        names_state: *@FieldType(State, "names"),
    ) (error{ OutOfMemory, Parse })!bool {
        switch (names_state.work) {
            .classify => |*classification| switch (classification.cursor.advance()) {
                .pending => {},
                .complete => |kind| {
                    const name = self.names[classification.index];
                    if (kind != .word) return self.failName(name);
                    names_state.work = .{ .symbol = .{
                        .index = classification.index,
                        .cursor = .init(name.bytes),
                    } };
                },
            },
            .symbol => |*symbol| switch (symbol.cursor.advance()) {
                .pending => {},
                .complete => |valid| {
                    const name = self.names[symbol.index];
                    if (!valid or intern.isReservedWordBytes(name.bytes)) return self.failName(name);
                    names_state.work = .{ .bytes = .{ .index = symbol.index } };
                },
            },
            .bytes => |*bytes| {
                const name = self.names[bytes.index];
                if (bytes.byte_index != name.bytes.len) {
                    if (name.bytes[bytes.byte_index] == '.') return self.failName(name);
                    bytes.byte_index += 1;
                } else names_state.work = .{ .intern = .{
                    .index = bytes.index,
                    .cursor = intern.insertionCursor(name.bytes),
                } };
            },
            .intern => |*insertion| switch (try insertion.cursor.advance()) {
                .pending => {},
                .complete => |id| names_state.work = .{ .put = .{
                    .index = insertion.index,
                    .cursor = names_state.locals.putCursor(@enumFromInt(id), insertion.index),
                } },
            },
            .put => |*put| switch (put.cursor.advance()) {
                .pending => {},
                .complete => |inserted| {
                    const name = self.names[put.index];
                    if (!inserted) {
                        self.diag.setFmt(name.span, "duplicate binder name `{s}`", .{name.bytes});
                        return error.Parse;
                    }
                    const next = put.index + 1;
                    if (next == self.names.len) return true;
                    names_state.work = .{ .classify = .{
                        .index = next,
                        .cursor = .init(self.names[next].bytes),
                    } };
                },
            },
        }
        return false;
    }

    fn advanceBody(
        self: *LowerCursor,
        body_state: *@FieldType(State, "body"),
    ) (error{ OutOfMemory, Parse })!bool {
        switch (body_state.work) {
            .lookup_top => |*lookup| switch (lookup.advance()) {
                .pending => return false,
                .complete => |found| {
                    self.local_indices[body_state.index] = found;
                    body_state.index += 1;
                    body_state.work = .top;
                    return false;
                },
            },
            .lookup_nested => |*lookup| switch (lookup.cursor.advance()) {
                .pending => return false,
                .complete => |found| {
                    _ = body_state.walk.pop().?;
                    if (found != null) {
                        self.diag.setFmt(
                            self.body[body_state.index].span,
                            "local `{s}` crosses a quotation boundary; use `partial` to construct a quotation that captures it",
                            .{intern.get(lookup.name)},
                        );
                        return error.Parse;
                    }
                    body_state.work = .nested;
                    return false;
                },
            },
            .nested => {},
            .top => {
                if (body_state.index == self.body.len) return true;
                return switch (self.body[body_state.index].value) {
                    .word => |id| result: {
                        body_state.work = .{ .lookup_top = body_state.locals.rawLookup(
                            @enumFromInt(id.name),
                        ) };
                        break :result false;
                    },
                    .list => |header| result: {
                        self.local_indices[body_state.index] = null;
                        try body_state.walk.push(.{ .item = .{ .list = header } });
                        body_state.work = .nested;
                        break :result false;
                    },
                    .dict => |header| result: {
                        self.local_indices[body_state.index] = null;
                        try body_state.walk.push(.{ .item = .{ .dict = header } });
                        body_state.work = .nested;
                        break :result false;
                    },
                    .int, .float, .char, .symbol, .task, .module, .port => result: {
                        self.local_indices[body_state.index] = null;
                        body_state.index += 1;
                        break :result false;
                    },
                };
            },
        }
        if (!body_state.walk.isEmpty()) {
            const frame = body_state.walk.topPtr().?;
            return switch (frame.item) {
                .word => |id| result: {
                    body_state.work = .{ .lookup_nested = .{
                        .name = id.name,
                        .cursor = body_state.locals.rawLookup(@enumFromInt(id.name)),
                    } };
                    break :result false;
                },
                .list => result: {
                    if (frame.next_child == null) {
                        frame.next_child = @intCast(frame.item.list.length());
                        break :result false;
                    }
                    if (frame.next_child.? == 0) {
                        _ = body_state.walk.pop().?;
                        break :result false;
                    }
                    frame.next_child.? -= 1;
                    try body_state.walk.push(.{ .item = list.atUnchecked(frame.item, frame.next_child.?) });
                    break :result false;
                },
                // A dict literal is inert like every other container, so a
                // local named inside one would silently become an ordinary
                // word-shaped key or value. Walking keys and values makes
                // that the same diagnosed mistake it is everywhere else.
                .dict => |header| result: {
                    if (frame.next_child == null) {
                        const entries: usize = @intCast(dict.keysOf(header).list.length());
                        frame.next_child = entries * 2;
                        break :result false;
                    }
                    if (frame.next_child.? == 0) {
                        _ = body_state.walk.pop().?;
                        break :result false;
                    }
                    frame.next_child.? -= 1;
                    const child = frame.next_child.?;
                    const entry = child / 2;
                    try body_state.walk.push(.{ .item = if (child % 2 == 0)
                        dict.keyAt(header, entry)
                    else
                        dict.valueAt(header, entry) });
                    break :result false;
                },
                .int, .float, .char, .symbol, .task, .module, .port => result: {
                    _ = body_state.walk.pop().?;
                    break :result false;
                },
            };
        }
        body_state.work = .top;
        body_state.index += 1;
        return false;
    }

    fn append(output: *Output, form: SpannedValue) void {
        output.forms[output.output_index] = form;
        output.values.appendOwned(form.value);
        output.output_index += 1;
    }

    fn atom(self: *LowerCursor, output: *Output, item: Value) void {
        append(output, .{ .value = item, .span = self.binder_span });
    }

    fn advanceOutput(self: *LowerCursor, output: *Output) LowerProgress {
        if (output.body_index == self.body.len) {
            // `drop-locals` is the body's last act rather than something
            // threaded through it: the names never sat on the operand stack,
            // so nothing between here and the binder had to see past them.
            switch (output.epilogue_step) {
                0 => {
                    self.atom(output, .{ .int = @intCast(self.names.len) });
                    output.epilogue_step = 1;
                    return .pending;
                },
                1 => {
                    self.atom(output, .{ .word = .{ .name = output.words[2] } });
                    output.epilogue_step = 2;
                    return .pending;
                },
                else => {},
            }
            const forms = output.forms;
            const values = output.values.take();
            self.state = .complete;
            return .{ .complete = .{ .forms = forms, .values = values } };
        }
        if (self.local_indices[output.body_index]) |index| {
            if (output.body_step == 0) {
                self.atom(output, .{ .int = @intCast(index) });
                output.body_step = 1;
                return .pending;
            }
            self.atom(output, .{ .word = .{ .name = output.words[1] } });
            output.body_step = 0;
            output.body_index += 1;
            return .pending;
        }
        // Every form that is not a local read is emitted exactly as written.
        const form = self.body[output.body_index];
        heap.retainValue(form.value);
        append(output, form);
        output.body_index += 1;
        return .pending;
    }

    pub fn advance(self: *LowerCursor) (error{ OutOfMemory, Parse })!LowerProgress {
        return switch (self.state) {
            .locals_init => |*cursor| switch (try cursor.advance()) {
                .pending => .pending,
                .complete => |locals| result: {
                    cursor.deinit();
                    self.state = .{ .names = .{
                        .locals = locals,
                        .work = .{ .classify = .{
                            .index = 0,
                            .cursor = .init(self.names[0].bytes),
                        } },
                    } };
                    break :result .pending;
                },
            },
            .names => |*names_state| result: {
                if (try self.advanceName(names_state)) {
                    const locals = names_state.locals;
                    self.state = .{ .body = .{
                        .locals = locals,
                        .walk = .init(self.allocator),
                    } };
                }
                break :result .pending;
            },
            .body => |*body_state| result: {
                if (try self.advanceBody(body_state)) {
                    body_state.walk.deinit();
                    body_state.locals.deinit();
                    self.state = .{ .word_start = .{} };
                }
                break :result .pending;
            },
            .word_start => |*words_state| result: {
                const names = [_][]const u8{ "_ll", "_gl", "_dl" };
                if (words_state.index == names.len) {
                    const words = words_state.words;
                    self.state = .{ .size = .{ .words = words } };
                } else {
                    const words = words_state.words;
                    const index = words_state.index;
                    self.state = .{ .word_intern = .{
                        .words = words,
                        .index = index,
                        .cursor = intern.insertionCursor(names[index]),
                    } };
                }
                break :result .pending;
            },
            .word_intern => |*word_state| result: {
                switch (try word_state.cursor.advance()) {
                    .pending => {},
                    .complete => |id| {
                        var words = word_state.words;
                        const index = word_state.index;
                        words[index] = id;
                        self.state = .{ .word_start = .{
                            .words = words,
                            .index = index + 1,
                        } };
                    },
                }
                break :result .pending;
            },
            .size => |*size| result: {
                if (size.index != self.body.len) {
                    const additional: usize = if (self.local_indices[size.index] != null) 2 else 1;
                    size.count = std.math.add(usize, size.count, additional) catch
                        return error.OutOfMemory;
                    size.index += 1;
                    break :result .pending;
                }
                const words = size.words;
                const count = size.count;
                self.state = .{ .allocate_output = .{
                    .words = words,
                    .count = count,
                } };
                break :result .pending;
            },
            .allocate_output => |allocation| result: {
                const forms = try self.allocator.alloc(SpannedValue, allocation.count);
                const words = allocation.words;
                self.state = .{ .allocate_values = .{
                    .words = words,
                    .forms = forms,
                } };
                break :result .pending;
            },
            .allocate_values => |allocation| result: {
                const values = try heap.OwnedValueBuffer.init(self.releases, allocation.forms.len);
                const words = allocation.words;
                const forms = allocation.forms;
                self.state = .{ .output = .{
                    .words = words,
                    .forms = forms,
                    .values = values,
                } };
                break :result .pending;
            },
            .output => |*output| result: {
                switch (output.prefix_step) {
                    0 => {
                        self.atom(output, .{ .int = @intCast(self.names.len) });
                        output.prefix_step = 1;
                        break :result .pending;
                    },
                    1 => {
                        self.atom(output, .{ .word = .{ .name = output.words[0] } });
                        output.prefix_step = 2;
                        break :result .pending;
                    },
                    else => {},
                }
                break :result self.advanceOutput(output);
            },
            .complete => unreachable,
        };
    }
};
