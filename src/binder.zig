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
    locals_init: LocalMap.InitCursor,
    locals: ?LocalMap = null,
    local_indices: []?usize,
    walk: poll.ChunkStack(WalkFrame),
    phase: enum { locals_init, names, body, live, words, size, output, complete } = .locals_init,
    name_index: usize = 0,
    body_index: usize = 0,
    byte_index: usize = 0,
    classifier: ?lexer.ClassifyCursor = null,
    symbol: ?lexer.SymbolCursor = null,
    inserter: ?intern.InternInsertionCursor = null,
    putter: ?LocalMap.PutCursor = null,
    lookup: ?LocalMap.RawLookupCursor = null,
    lookup_kind: enum { top, nested } = .top,
    nested_active: bool = false,
    words: [3]u32 = .{0} ** 3,
    word_index: usize = 0,
    output_count: usize = 4,
    output: ?[]SpannedValue = null,
    output_values: ?heap.OwnedValueBuffer = null,
    output_index: usize = 0,
    emit_body_index: usize = 0,
    emit_step: usize = 0,
    epilogue_step: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        names: []const Name,
        body: []const SpannedValue,
        binder_span: Span,
        diag: *Diag,
    ) error{OutOfMemory}!LowerCursor {
        return .{
            .allocator = allocator,
            .releases = releases,
            .names = names,
            .body = body,
            .binder_span = binder_span,
            .diag = diag,
            .locals_init = LocalMap.initCursor(allocator, names.len),
            .local_indices = try allocator.alloc(?usize, body.len),
            .walk = .init(allocator),
        };
    }

    pub fn deinit(self: *LowerCursor) void {
        self.locals_init.deinit();
        if (self.locals) |*locals| locals.deinit();
        if (self.output_values) |*values| values.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.allocator.free(self.local_indices);
        self.walk.deinit();
        self.* = undefined;
    }

    fn failName(self: *LowerCursor, name: Name) error{Parse} {
        self.diag.setFmt(name.span, "invalid binder name `{s}`", .{name.bytes});
        return error.Parse;
    }

    fn resetName(self: *LowerCursor) void {
        self.classifier = null;
        self.symbol = null;
        self.inserter = null;
        self.putter = null;
        self.byte_index = 0;
        self.name_index += 1;
    }

    fn advanceName(self: *LowerCursor) (error{ OutOfMemory, Parse })!LowerProgress {
        if (self.name_index == self.names.len) {
            self.phase = .body;
            return .pending;
        }
        const name = self.names[self.name_index];
        if (self.classifier == null) self.classifier = .init(name.bytes);
        if (self.symbol == null) return switch (self.classifier.?.advance()) {
            .pending => .pending,
            .complete => |classification| result: {
                if (classification != .word) return self.failName(name);
                self.symbol = .init(name.bytes);
                break :result .pending;
            },
        };
        if (self.byte_index == 0) return switch (self.symbol.?.advance()) {
            .pending => .pending,
            .complete => |valid| result: {
                if (!valid or intern.isReservedWordBytes(name.bytes)) return self.failName(name);
                self.byte_index = 1;
                break :result .pending;
            },
        };
        if (self.byte_index <= name.bytes.len + 1) {
            const index = self.byte_index - 1;
            self.byte_index += 1;
            if (index != name.bytes.len) {
                if (name.bytes[index] == '.') return self.failName(name);
                return .pending;
            }
            self.inserter = intern.insertionCursor(name.bytes);
            return .pending;
        }
        if (self.putter == null) return switch (try self.inserter.?.advance()) {
            .pending => .pending,
            .complete => |id| result: {
                self.putter = self.locals.?.putCursor(@enumFromInt(id), self.name_index);
                break :result .pending;
            },
        };
        return switch (self.putter.?.advance()) {
            .pending => .pending,
            .complete => |inserted| result: {
                if (!inserted) {
                    self.diag.setFmt(name.span, "duplicate binder name `{s}`", .{name.bytes});
                    return error.Parse;
                }
                self.resetName();
                break :result .pending;
            },
        };
    }

    fn advanceBody(self: *LowerCursor) (error{ OutOfMemory, Parse })!LowerProgress {
        if (self.lookup) |*lookup| return switch (lookup.advance()) {
            .pending => .pending,
            .complete => |found| result: {
                const kind = self.lookup_kind;
                const matched_id = if (kind == .nested and found != null)
                    self.walk.topPtr().?.item.word
                else
                    0;
                self.lookup = null;
                if (kind == .top) {
                    self.local_indices[self.body_index] = found;
                    self.body_index += 1;
                } else {
                    _ = self.walk.pop().?;
                    if (found != null) {
                        self.diag.setFmt(
                            self.body[self.body_index].span,
                            "local `{s}` crosses a quotation boundary; capture it explicitly with `partial`",
                            .{intern.get(matched_id)},
                        );
                        return error.Parse;
                    }
                }
                break :result .pending;
            },
        };
        if (!self.walk.isEmpty()) {
            const frame = self.walk.topPtr().?;
            return switch (frame.item) {
                .word => |id| result: {
                    self.lookup_kind = .nested;
                    self.lookup = self.locals.?.rawLookup(@enumFromInt(id));
                    break :result .pending;
                },
                .list => result: {
                    if (frame.next_child == null) {
                        frame.next_child = @intCast(frame.item.list.length());
                        break :result .pending;
                    }
                    if (frame.next_child.? == 0) {
                        _ = self.walk.pop().?;
                        break :result .pending;
                    }
                    frame.next_child.? -= 1;
                    try self.walk.push(.{ .item = list.atUnchecked(frame.item, frame.next_child.?) });
                    break :result .pending;
                },
                // A dict literal is inert like every other container, so a
                // local named inside one would silently become an ordinary
                // word-shaped key or value. Walking keys and values makes
                // that the same diagnosed mistake it is everywhere else.
                .dict => |header| result: {
                    if (frame.next_child == null) {
                        const entries: usize = @intCast(dict.keysOf(header).list.length());
                        frame.next_child = entries * 2;
                        break :result .pending;
                    }
                    if (frame.next_child.? == 0) {
                        _ = self.walk.pop().?;
                        break :result .pending;
                    }
                    frame.next_child.? -= 1;
                    const child = frame.next_child.?;
                    const entry = child / 2;
                    try self.walk.push(.{ .item = if (child % 2 == 0)
                        dict.keyAt(header, entry)
                    else
                        dict.valueAt(header, entry) });
                    break :result .pending;
                },
                .int, .float, .char, .symbol, .task, .module => result: {
                    _ = self.walk.pop().?;
                    break :result .pending;
                },
            };
        }
        if (self.nested_active) {
            self.nested_active = false;
            self.body_index += 1;
            return .pending;
        }
        if (self.body_index == self.body.len) {
            self.body_index = 0;
            self.phase = .live;
            return .pending;
        }
        return switch (self.body[self.body_index].value) {
            .word => |id| result: {
                self.lookup_kind = .top;
                self.lookup = self.locals.?.rawLookup(@enumFromInt(id));
                break :result .pending;
            },
            .list => |header| result: {
                self.local_indices[self.body_index] = null;
                try self.walk.push(.{ .item = .{ .list = header } });
                self.nested_active = true;
                break :result .pending;
            },
            .dict => |header| result: {
                self.local_indices[self.body_index] = null;
                try self.walk.push(.{ .item = .{ .dict = header } });
                self.nested_active = true;
                break :result .pending;
            },
            .int, .float, .char, .symbol, .task, .module => result: {
                self.local_indices[self.body_index] = null;
                self.body_index += 1;
                break :result .pending;
            },
        };
    }

    fn append(self: *LowerCursor, form: SpannedValue) void {
        self.output.?[self.output_index] = form;
        self.output_values.?.appendOwned(form.value);
        self.output_index += 1;
    }

    fn atom(self: *LowerCursor, item: Value) void {
        self.append(.{ .value = item, .span = self.binder_span });
    }

    fn advanceOutput(self: *LowerCursor) (error{OutOfMemory})!LowerProgress {
        if (self.emit_body_index == self.body.len) {
            // `drop-locals` is the body's last act rather than something
            // threaded through it: the names never sat on the operand stack,
            // so nothing between here and the binder had to see past them.
            switch (self.epilogue_step) {
                0 => {
                    self.atom(.{ .int = @intCast(self.names.len) });
                    self.epilogue_step = 1;
                    return .pending;
                },
                1 => {
                    self.atom(.{ .word = self.words[2] });
                    self.epilogue_step = 2;
                    return .pending;
                },
                else => {},
            }
            const output = self.output.?;
            self.output = null;
            const values = self.output_values.?.take();
            self.output_values = null;
            self.phase = .complete;
            return .{ .complete = .{ .forms = output, .values = values } };
        }
        if (self.local_indices[self.emit_body_index]) |index| {
            if (self.emit_step == 0) {
                self.atom(.{ .int = @intCast(index) });
                self.emit_step = 1;
                return .pending;
            }
            self.atom(.{ .word = self.words[1] });
            self.emit_step = 0;
            self.emit_body_index += 1;
            return .pending;
        }
        // Every form that is not a local read is emitted exactly as written.
        const form = self.body[self.emit_body_index];
        heap.retainValue(form.value);
        self.append(form);
        self.emit_body_index += 1;
        return .pending;
    }

    pub fn advance(self: *LowerCursor) (error{ OutOfMemory, Parse })!LowerProgress {
        return switch (self.phase) {
            .locals_init => switch (try self.locals_init.advance()) {
                .pending => .pending,
                .complete => |locals| result: {
                    self.locals = locals;
                    if (self.names.len == 0) {
                        self.diag.set(self.binder_span, "a binder must contain at least one name");
                        return error.Parse;
                    }
                    self.phase = .names;
                    break :result .pending;
                },
            },
            .names => try self.advanceName(),
            .body => try self.advanceBody(),
            .live => result: {
                self.body_index = 0;
                self.phase = .words;
                break :result .pending;
            },
            .words => result: {
                const names = [_][]const u8{ "_ll", "_gl", "_dl" };
                if (self.inserter == null) self.inserter = intern.insertionCursor(names[self.word_index]);
                switch (try self.inserter.?.advance()) {
                    .pending => {},
                    .complete => |id| {
                        self.words[self.word_index] = id;
                        self.word_index += 1;
                        self.inserter = null;
                        if (self.word_index == names.len) self.phase = .size;
                    },
                }
                break :result .pending;
            },
            .size => result: {
                if (self.body_index != self.body.len) {
                    const additional: usize = if (self.local_indices[self.body_index] != null) 2 else 1;
                    self.output_count = std.math.add(usize, self.output_count, additional) catch
                        return error.OutOfMemory;
                    self.body_index += 1;
                    break :result .pending;
                }
                self.output = try self.allocator.alloc(SpannedValue, self.output_count);
                self.output_values = try .init(self.releases, self.output_count);
                self.name_index = 0;
                self.phase = .output;
                break :result .pending;
            },
            .output => result: {
                switch (self.name_index) {
                    0 => {
                        self.atom(.{ .int = @intCast(self.names.len) });
                        self.name_index = 1;
                        break :result .pending;
                    },
                    1 => {
                        self.atom(.{ .word = self.words[0] });
                        self.name_index = 2;
                        break :result .pending;
                    },
                    else => {},
                }
                break :result try self.advanceOutput();
            },
            .complete => unreachable,
        };
    }
};

/// Borrows `body` and returns a newly-owned slice whose heap values each own
/// one reference. The caller frees the slice and releases those values.
pub fn lower(
    host: *const heap.HostCleanup,
    names: []const Name,
    body: []const SpannedValue,
    binder_span: Span,
    diag: *Diag,
) Error![]SpannedValue {
    const allocator = host.allocator();
    const releases = heap.hostDomain(host);
    defer host.drain();
    var cursor = try LowerCursor.init(allocator, releases, names, body, binder_span, diag);
    defer cursor.deinit();
    const completed = try poll.driveFallible(Lowered, &cursor, .{});
    for (completed.forms) |form| heap.retainValue(form.value);
    var values = completed.values;
    values.deinit();
    return completed.forms;
}
