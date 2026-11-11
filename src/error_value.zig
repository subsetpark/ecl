//! Resumable materialization of a pending failure into its language error
//! value: the ordinary error dict and the raised-value form.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const poll_api = @import("poll.zig");
const kernel_storage = @import("kernel_storage.zig");
const machine = @import("machine.zig");
const Value = value.Value;
const EclErr = machine.EclErr;

const ErrorValueProgress = poll_api.Progress(Value);
const OrdinaryErrorCursor = struct {
    const BaseValues = struct {
        message: Value,
        trace: Value,

        fn retire(self: *BaseValues, releases: *heap.ReleaseDomain) void {
            releases.releaseValue(self.trace);
            releases.releaseValue(self.message);
        }
    };
    const CompletedValues = struct {
        base: BaseValues,
        source: ?Value,
        data: Value,

        fn retire(self: *CompletedValues, releases: *heap.ReleaseDomain) void {
            releases.releaseValue(self.data);
            if (self.source) |source| releases.releaseValue(source);
            self.base.retire(releases);
        }
    };
    const State = union(enum) {
        names: usize,
        name_insert: struct {
            index: usize,
            cursor: intern.InternInsertionCursor,
        },
        message: kernel_storage.TextMaterializer,
        trace_allocate: Value,
        trace_copy: struct {
            message: Value,
            items: []Value,
            index: usize,
        },
        trace_build: struct {
            message: Value,
            items: []Value,
            builder: list.ValueMaterializer,
        },
        data: struct {
            base: BaseValues,
            index: usize,
        },
        data_insert: struct {
            base: BaseValues,
            index: usize,
            cursor: intern.InternInsertionCursor,
        },
        source: struct {
            base: BaseValues,
            index: usize,
            builder: kernel_storage.TextMaterializer,
        },
        data_prepare: struct {
            base: BaseValues,
            index: usize,
            source: ?Value,
        },
        data_build: struct {
            base: BaseValues,
            source: ?Value,
            builder: dict.Materializer,
        },
        outer_prepare: CompletedValues,
        outer: struct {
            values: CompletedValues,
            builder: dict.Materializer,
        },
        complete: CompletedValues,

        fn retire(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .names, .name_insert => {},
                .message => |*builder| builder.retire(releases),
                .trace_allocate => |message| releases.releaseValue(message),
                .trace_copy => |*trace| {
                    allocator.free(trace.items);
                    releases.releaseValue(trace.message);
                },
                .trace_build => |*trace| {
                    trace.builder.retire(releases);
                    allocator.free(trace.items);
                    releases.releaseValue(trace.message);
                },
                .data => |*data| data.base.retire(releases),
                .data_insert => |*data| data.base.retire(releases),
                .source => |*source| {
                    source.builder.retire(releases);
                    source.base.retire(releases);
                },
                .data_prepare => |*data| {
                    if (data.source) |source| releases.releaseValue(source);
                    data.base.retire(releases);
                },
                .data_build => |*data| {
                    data.builder.retire(releases);
                    if (data.source) |source| releases.releaseValue(source);
                    data.base.retire(releases);
                },
                .outer_prepare, .complete => |*values| values.retire(releases),
                .outer => |*outer| {
                    outer.builder.retire(releases);
                    outer.values.retire(releases);
                },
            }
        }
    };

    allocator: std.mem.Allocator,
    failure: *EclErr,
    resolved: ResolvedTrace,
    location: ?spans.LocatedSpan,
    names: [9]u32 = @splat(0),
    // Every recorded datum plus the three location fields.
    data_pairs: [9]dict.Pair = @splat(.{ .{ .int = 0 }, .{ .int = 0 } }),
    outer_pairs: [5]dict.Pair = @splat(.{ .{ .int = 0 }, .{ .int = 0 } }),
    state: State = .{ .names = 0 },

    fn init(
        allocator: std.mem.Allocator,
        failure: *EclErr,
        resolved: ResolvedTrace,
        location: ?spans.LocatedSpan,
    ) OrdinaryErrorCursor {
        return .{
            .allocator = allocator,
            .failure = failure,
            .resolved = resolved,
            .location = location,
        };
    }
    fn retire(self: *OrdinaryErrorCursor, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases, self.allocator);
    }
    fn nameBytes(self: *const OrdinaryErrorCursor, index: usize) []const u8 {
        return switch (index) {
            0 => self.failure.kind.symbol(),
            1 => "kind",
            2 => "msg",
            3 => "word",
            4 => "trace",
            5 => "data",
            6 => "source",
            7 => "line",
            8 => "col",
            else => unreachable,
        };
    }
    fn beginOuter(
        self: *OrdinaryErrorCursor,
        values: *CompletedValues,
    ) error{OutOfMemory}!void {
        var count: usize = 0;
        self.outer_pairs[count] = .{ .{ .symbol = .{ .name = self.names[1] } }, .{ .symbol = .{ .name = self.names[0] } } };
        count += 1;
        self.outer_pairs[count] = .{ .{ .symbol = .{ .name = self.names[2] } }, values.base.message };
        count += 1;
        if (self.resolved.word) |word| {
            self.outer_pairs[count] = .{ .{ .symbol = .{ .name = self.names[3] } }, .{ .symbol = .{ .name = word } } };
            count += 1;
        }
        self.outer_pairs[count] = .{ .{ .symbol = .{ .name = self.names[4] } }, values.base.trace };
        count += 1;
        self.outer_pairs[count] = .{ .{ .symbol = .{ .name = self.names[5] } }, values.data };
        count += 1;
        const builder = try dict.Materializer.init(
            self.allocator,
            self.outer_pairs[0..count],
            false,
        );
        const moved = values.*;
        self.state = .{ .outer = .{
            .values = moved,
            .builder = builder,
        } };
    }
    /// Own transitions draw one unit each; the value builders draw on the
    /// same allowance themselves, so a hand-off is not charged twice.
    fn advance(self: *OrdinaryErrorCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
        while (true) {
            const delegating = switch (self.state) {
                .message, .trace_build, .source, .data_build, .outer => true,
                else => false,
            };
            if (!delegating and !work.spend()) return .pending;
            const progress = try self.step(work);
            if (progress != .pending) return progress;
            if (delegating and work.exhausted()) return .pending;
        }
    }
    fn step(self: *OrdinaryErrorCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
        return switch (self.state) {
            .names => |index| result: {
                if (index == self.names.len) {
                    self.state = .{ .message = .init(self.allocator, self.failure.text()) };
                } else self.state = .{ .name_insert = .{
                    .index = index,
                    .cursor = intern.insertionCursor(self.nameBytes(index)),
                } };
                break :result .pending;
            },
            .name_insert => |*insertion| switch (try insertion.cursor.advance()) {
                .pending => .pending,
                .complete => |id| result: {
                    self.names[insertion.index] = id;
                    self.state = .{ .names = insertion.index + 1 };
                    break :result .pending;
                },
            },
            .message => |*builder| switch (try builder.advance(work)) {
                .pending => .pending,
                .complete => |item| result: {
                    builder.deinit();
                    self.state = .{ .trace_allocate = item };
                    break :result .pending;
                },
            },
            .trace_allocate => |message| result: {
                const items = try self.allocator.alloc(Value, self.resolved.trace.len);
                self.state = .{ .trace_copy = .{
                    .message = message,
                    .items = items,
                    .index = 0,
                } };
                break :result .pending;
            },
            .trace_copy => |*trace| result: {
                if (trace.index != self.resolved.trace.len) {
                    trace.items[trace.index] = value.datum(.{ .symbol = .{ .name = self.resolved.trace[trace.index] } });
                    trace.index += 1;
                } else {
                    const next = @FieldType(State, "trace_build"){
                        .message = trace.message,
                        .items = trace.items,
                        .builder = .init(self.allocator, trace.items),
                    };
                    self.state = .{ .trace_build = next };
                }
                break :result .pending;
            },
            .trace_build => |*trace| switch (try trace.builder.advance(work)) {
                .pending => .pending,
                .complete => |item| result: {
                    const message = trace.message;
                    const items = trace.items;
                    trace.builder.deinit();
                    self.allocator.free(items);
                    self.state = .{ .data = .{
                        .base = .{ .message = message, .trace = item },
                        .index = 0,
                    } };
                    break :result .pending;
                },
            },
            .data => |*data| result: {
                if (data.index != self.failure.data_len) {
                    self.state = .{ .data_insert = .{
                        .base = data.base,
                        .index = data.index,
                        .cursor = intern.insertionCursor(switch (self.failure.data[data.index].key) {
                            .builtin => |key| @tagName(key),
                            .symbol => |symbol| intern.get(symbol),
                        }),
                    } };
                } else if (self.location) |located| {
                    self.state = .{ .source = .{
                        .base = data.base,
                        .index = data.index,
                        .builder = .init(self.allocator, located.source_name),
                    } };
                } else self.state = .{ .data_prepare = .{
                    .base = data.base,
                    .index = data.index,
                    .source = null,
                } };
                break :result .pending;
            },
            .data_insert => |*insertion| switch (try insertion.cursor.advance()) {
                .pending => .pending,
                .complete => |key| result: {
                    const entry = self.failure.data[insertion.index];
                    self.data_pairs[insertion.index] = .{ .{ .symbol = .{ .name = key } }, entry.value };
                    self.state = .{ .data = .{
                        .base = insertion.base,
                        .index = insertion.index + 1,
                    } };
                    break :result .pending;
                },
            },
            .source => |*source| switch (try source.builder.advance(work)) {
                .pending => .pending,
                .complete => |item| result: {
                    const base = source.base;
                    const source_index = source.index;
                    source.builder.deinit();
                    const located = self.location.?;
                    var index = source_index;
                    self.data_pairs[index] = .{ .{ .symbol = .{ .name = self.names[6] } }, item };
                    index += 1;
                    self.data_pairs[index] = .{ .{ .symbol = .{ .name = self.names[7] } }, .{ .int = located.span.line } };
                    index += 1;
                    self.data_pairs[index] = .{ .{ .symbol = .{ .name = self.names[8] } }, .{ .int = located.span.col } };
                    index += 1;
                    self.state = .{ .data_prepare = .{
                        .base = base,
                        .index = index,
                        .source = item,
                    } };
                    break :result .pending;
                },
            },
            .data_prepare => |*data| result: {
                const builder = try dict.Materializer.init(
                    self.allocator,
                    self.data_pairs[0..data.index],
                    false,
                );
                self.state = .{ .data_build = .{
                    .base = data.base,
                    .source = data.source,
                    .builder = builder,
                } };
                break :result .pending;
            },
            .data_build => |*data| switch (try data.builder.advance(work)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    const base = data.base;
                    const source = data.source;
                    data.builder.deinit();
                    self.state = .{ .outer_prepare = .{
                        .base = base,
                        .source = source,
                        .data = item,
                    } };
                    break :result .pending;
                },
            },
            .outer_prepare => |*values| result: {
                try self.beginOuter(values);
                break :result .pending;
            },
            .outer => |*outer| switch (try outer.builder.advance(work)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    const values = outer.values;
                    outer.builder.deinit();
                    self.state = .{ .complete = values };
                    break :result .{ .complete = item };
                },
            },
            .complete => unreachable,
        };
    }
};

const RaisedErrorCursor = struct {
    /// Replacement fields are independently optional because a raised dict
    /// may already supply any subset of them. Their presence is semantic
    /// input-dependent state independently of the execution phase.
    const BuiltValues = struct {
        message: ?Value = null,
        trace: ?Value = null,
        source: ?Value = null,
        data: ?Value = null,

        fn retire(self: *BuiltValues, releases: *heap.ReleaseDomain) void {
            if (self.data) |item| releases.releaseValue(item);
            if (self.source) |item| releases.releaseValue(item);
            if (self.trace) |item| releases.releaseValue(item);
            if (self.message) |item| releases.releaseValue(item);
        }
    };
    const DataAdditions = packed struct {
        source: bool,
        line: bool,
        col: bool,
    };
    const State = union(enum) {
        names: usize,
        name_insert: struct { index: usize, cursor: intern.InternInsertionCursor },
        fields: usize,
        field_find: struct { index: usize, cursor: dict.FindCursor },
        message: kernel_storage.TextMaterializer,
        trace_allocate,
        trace_copy: struct { items: []Value, index: usize },
        trace_build: struct {
            items: []Value,
            builder: list.ValueMaterializer,
        },
        data_fields: usize,
        data_field_find: struct { index: usize, cursor: dict.FindCursor },
        data_copy: struct {
            pairs: []dict.Pair,
            index: usize,
            additions: DataAdditions,
        },
        source: struct {
            pairs: []dict.Pair,
            index: usize,
            additions: DataAdditions,
            builder: kernel_storage.TextMaterializer,
        },
        data_build: struct {
            pairs: []dict.Pair,
            builder: dict.Materializer,
        },
        outer_allocate,
        outer_copy: struct { pairs: []dict.Pair, index: usize },
        outer_build: struct {
            pairs: []dict.Pair,
            builder: dict.Materializer,
        },
        complete,

        fn retire(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .field_find => |*find| find.cursor.deinit(),
                .data_field_find => |*find| find.cursor.deinit(),
                .message => |*builder| builder.retire(releases),
                .trace_copy => |trace| allocator.free(trace.items),
                .trace_build => |*trace| {
                    trace.builder.retire(releases);
                    allocator.free(trace.items);
                },
                .data_copy => |data| allocator.free(data.pairs),
                .source => |*source| {
                    source.builder.retire(releases);
                    allocator.free(source.pairs);
                },
                .data_build => |*data| {
                    data.builder.retire(releases);
                    allocator.free(data.pairs);
                },
                .outer_copy => |outer| allocator.free(outer.pairs),
                .outer_build => |*outer| {
                    outer.builder.retire(releases);
                    allocator.free(outer.pairs);
                },
                .names,
                .name_insert,
                .fields,
                .trace_allocate,
                .data_fields,
                .outer_allocate,
                .complete,
                => {},
            }
        }
    };

    allocator: std.mem.Allocator,
    failure: *EclErr,
    resolved: ResolvedTrace,
    location: ?spans.LocatedSpan,
    names: [8]u32 = @splat(0),
    fields: [5]?Value = @splat(null),
    message_bytes: [512]u8 = @splat(0),
    data_fields: [3]?Value = @splat(null),
    built: BuiltValues = .{},
    state: State = .{ .names = 0 },

    fn init(
        allocator: std.mem.Allocator,
        failure: *EclErr,
        resolved: ResolvedTrace,
        location: ?spans.LocatedSpan,
    ) RaisedErrorCursor {
        return .{
            .allocator = allocator,
            .failure = failure,
            .resolved = resolved,
            .location = location,
        };
    }
    fn retire(self: *RaisedErrorCursor, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases, self.allocator);
        self.built.retire(releases);
    }
    fn nameBytes(index: usize) []const u8 {
        const names = [_][]const u8{ "kind", "msg", "word", "trace", "data", "source", "line", "col" };
        return names[index];
    }
    fn beginOptionalValues(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        if (self.fields[1] == null) {
            const kind = self.fields[0].?.symbol.name;
            const message = std.fmt.bufPrint(&self.message_bytes, "raised {s}", .{intern.get(kind)}) catch
                "raised user error";
            if (message.ptr != self.message_bytes[0..].ptr)
                @memcpy(self.message_bytes[0..message.len], message);
            self.state = .{ .message = .init(self.allocator, self.message_bytes[0..message.len]) };
        } else if (self.fields[3] == null) {
            self.state = .trace_allocate;
        } else {
            self.state = .{ .data_fields = 0 };
        }
    }
    fn beginData(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        const old_data = self.fields[4];
        if (old_data == null or self.location != null and
            !(self.data_fields[0] != null and self.data_fields[1] != null and self.data_fields[2] != null))
        {
            const old_count: usize = if (old_data) |item| @intCast(item.dict.length()) else 0;
            const additions = DataAdditions{
                .source = self.location != null and self.data_fields[0] == null,
                .line = self.location != null and self.data_fields[1] == null,
                .col = self.location != null and self.data_fields[2] == null,
            };
            const count = old_count + @as(usize, @intFromBool(additions.source)) +
                @as(usize, @intFromBool(additions.line)) +
                @as(usize, @intFromBool(additions.col));
            const pairs = try self.allocator.alloc(dict.Pair, count);
            self.state = .{ .data_copy = .{
                .pairs = pairs,
                .index = 0,
                .additions = additions,
            } };
        } else self.state = .outer_allocate;
    }
    fn appendDataContext(
        self: *RaisedErrorCursor,
        data: *@FieldType(State, "data_copy"),
    ) error{OutOfMemory}!void {
        var index = data.index;
        if (data.additions.source) {
            const located = self.location.?;
            if (self.built.source == null) {
                self.state = .{ .source = .{
                    .pairs = data.pairs,
                    .index = index,
                    .additions = data.additions,
                    .builder = .init(self.allocator, located.source_name),
                } };
                return;
            }
            data.pairs[index] = .{ .{ .symbol = .{ .name = self.names[5] } }, self.built.source.? };
            index += 1;
        }
        if (data.additions.line) {
            const located = self.location.?;
            data.pairs[index] = .{ .{ .symbol = .{ .name = self.names[6] } }, .{ .int = located.span.line } };
            index += 1;
        }
        if (data.additions.col) {
            const located = self.location.?;
            data.pairs[index] = .{ .{ .symbol = .{ .name = self.names[7] } }, .{ .int = located.span.col } };
            index += 1;
        }
        const builder = try dict.Materializer.init(
            self.allocator,
            data.pairs[0..index],
            false,
        );
        self.state = .{ .data_build = .{
            .pairs = data.pairs,
            .builder = builder,
        } };
    }
    fn beginOuter(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        const raised = self.failure.raised.?;
        const old_count: usize = @intCast(raised.dict.length());
        const extra = @as(usize, @intFromBool(self.fields[1] == null)) +
            @as(usize, @intFromBool(self.fields[2] == null and self.resolved.word != null)) +
            @as(usize, @intFromBool(self.fields[3] == null)) +
            @as(usize, @intFromBool(self.fields[4] == null));
        const pairs = try self.allocator.alloc(dict.Pair, old_count + extra);
        self.state = .{ .outer_copy = .{ .pairs = pairs, .index = 0 } };
    }
    fn appendOuter(
        self: *RaisedErrorCursor,
        outer: *@FieldType(State, "outer_copy"),
    ) error{OutOfMemory}!void {
        var index = outer.index;
        if (self.fields[1] == null) {
            outer.pairs[index] = .{ .{ .symbol = .{ .name = self.names[1] } }, self.built.message.? };
            index += 1;
        }
        if (self.fields[2] == null) if (self.resolved.word) |word| {
            outer.pairs[index] = .{ .{ .symbol = .{ .name = self.names[2] } }, .{ .symbol = .{ .name = word } } };
            index += 1;
        };
        if (self.fields[3] == null) {
            outer.pairs[index] = .{ .{ .symbol = .{ .name = self.names[3] } }, self.built.trace.? };
            index += 1;
        }
        if (self.fields[4] == null) {
            outer.pairs[index] = .{ .{ .symbol = .{ .name = self.names[4] } }, self.built.data.? };
            index += 1;
        }
        const builder = try dict.Materializer.init(
            self.allocator,
            outer.pairs[0..index],
            false,
        );
        self.state = .{ .outer_build = .{
            .pairs = outer.pairs,
            .builder = builder,
        } };
    }
    /// Own transitions draw one unit each; the value builders draw on the
    /// same allowance themselves, so a hand-off is not charged twice.
    fn advance(self: *RaisedErrorCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
        while (true) {
            const delegating = switch (self.state) {
                .field_find, .message, .trace_build, .data_field_find, .source, .data_build, .outer_build => true,
                else => false,
            };
            if (!delegating and !work.spend()) return .pending;
            const progress = try self.step(work);
            if (progress != .pending) return progress;
            if (delegating and work.exhausted()) return .pending;
        }
    }
    fn step(self: *RaisedErrorCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
        const raised = self.failure.raised.?;
        return switch (self.state) {
            .names => |index| result: {
                self.state = if (index == self.names.len)
                    .{ .fields = 0 }
                else
                    .{ .name_insert = .{
                        .index = index,
                        .cursor = intern.insertionCursor(nameBytes(index)),
                    } };
                break :result .pending;
            },
            .name_insert => |*insertion| switch (try insertion.cursor.advance()) {
                .pending => .pending,
                .complete => |id| result: {
                    self.names[insertion.index] = id;
                    self.state = .{ .names = insertion.index + 1 };
                    break :result .pending;
                },
            },
            .fields => |index| result: {
                if (index == self.fields.len) {
                    try self.beginOptionalValues();
                } else self.state = .{ .field_find = .{
                    .index = index,
                    .cursor = .initHeader(
                        self.allocator,
                        raised.dict,
                        .{ .symbol = .{ .name = self.names[index] } },
                    ),
                } };
                break :result .pending;
            },
            .field_find => |*find| switch (try find.cursor.advance(work)) {
                .pending => .pending,
                .complete => |found| result: {
                    const index = find.index;
                    find.cursor.deinit();
                    self.fields[index] = found;
                    self.state = .{ .fields = index + 1 };
                    break :result .pending;
                },
            },
            .message => |*builder| switch (try builder.advance(work)) {
                .pending => .pending,
                .complete => |item| result: {
                    builder.deinit();
                    self.built.message = item;
                    self.state = if (self.fields[3] == null)
                        .trace_allocate
                    else
                        .{ .data_fields = 0 };
                    break :result .pending;
                },
            },
            .trace_allocate => result: {
                const items = try self.allocator.alloc(Value, self.resolved.trace.len);
                self.state = .{ .trace_copy = .{ .items = items, .index = 0 } };
                break :result .pending;
            },
            .trace_copy => |*trace| result: {
                if (trace.index != self.resolved.trace.len) {
                    trace.items[trace.index] = value.datum(.{ .symbol = .{ .name = self.resolved.trace[trace.index] } });
                    trace.index += 1;
                } else {
                    self.state = .{ .trace_build = .{
                        .items = trace.items,
                        .builder = .init(self.allocator, trace.items),
                    } };
                }
                break :result .pending;
            },
            .trace_build => |*trace| switch (try trace.builder.advance(work)) {
                .pending => .pending,
                .complete => |item| result: {
                    const items = trace.items;
                    trace.builder.deinit();
                    self.allocator.free(items);
                    self.built.trace = item;
                    self.state = .{ .data_fields = 0 };
                    break :result .pending;
                },
            },
            .data_fields => |index| result: {
                const old_data = self.fields[4];
                if (old_data == null or self.location == null) {
                    try self.beginData();
                    break :result .pending;
                }
                if (index == self.data_fields.len) {
                    try self.beginData();
                } else self.state = .{ .data_field_find = .{
                    .index = index,
                    .cursor = .initHeader(
                        self.allocator,
                        old_data.?.dict,
                        .{ .symbol = .{ .name = self.names[5 + index] } },
                    ),
                } };
                break :result .pending;
            },
            .data_field_find => |*find| switch (try find.cursor.advance(work)) {
                .pending => .pending,
                .complete => |found| result: {
                    const index = find.index;
                    find.cursor.deinit();
                    self.data_fields[index] = found;
                    self.state = .{ .data_fields = index + 1 };
                    break :result .pending;
                },
            },
            .data_copy => |*data| result: {
                const old_data = self.fields[4];
                const old_count: usize = if (old_data) |item| @intCast(item.dict.length()) else 0;
                if (data.index != old_count) {
                    data.pairs[data.index] = .{
                        dict.keyAt(old_data.?.dict, data.index),
                        dict.valueAt(old_data.?.dict, data.index),
                    };
                    data.index += 1;
                } else try self.appendDataContext(data);
                break :result .pending;
            },
            .source => |*source| switch (try source.builder.advance(work)) {
                .pending => .pending,
                .complete => |item| result: {
                    const pairs = source.pairs;
                    const index = source.index;
                    const additions = source.additions;
                    source.builder.deinit();
                    self.built.source = item;
                    self.state = .{ .data_copy = .{
                        .pairs = pairs,
                        .index = index,
                        .additions = additions,
                    } };
                    break :result .pending;
                },
            },
            .data_build => |*data| switch (try data.builder.advance(work)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    const pairs = data.pairs;
                    data.builder.deinit();
                    self.allocator.free(pairs);
                    self.built.data = item;
                    self.state = .outer_allocate;
                    break :result .pending;
                },
            },
            .outer_allocate => result: {
                try self.beginOuter();
                break :result .pending;
            },
            .outer_copy => |*outer| result: {
                const old_count: usize = @intCast(raised.dict.length());
                if (outer.index != old_count) {
                    const key = dict.keyAt(raised.dict, outer.index);
                    const old_value = dict.valueAt(raised.dict, outer.index);
                    outer.pairs[outer.index] = .{
                        key,
                        if (key == .symbol and key.symbol.name == self.names[4] and self.built.data != null)
                            self.built.data.?
                        else
                            old_value,
                    };
                    outer.index += 1;
                } else try self.appendOuter(outer);
                break :result .pending;
            },
            .outer_build => |*outer| switch (try outer.builder.advance(work)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    const pairs = outer.pairs;
                    outer.builder.deinit();
                    self.allocator.free(pairs);
                    self.state = .complete;
                    break :result .{ .complete = item };
                },
            },
            .complete => unreachable,
        };
    }
};

pub const ErrorValueCursor = union(enum) {
    ordinary: OrdinaryErrorCursor,
    raised: RaisedErrorCursor,
    pub fn init(
        allocator: std.mem.Allocator,
        failure: *EclErr,
        resolved: ResolvedTrace,
        location: ?spans.LocatedSpan,
    ) ErrorValueCursor {
        return if (failure.raised == null)
            .{ .ordinary = .init(allocator, failure, resolved, location) }
        else
            .{ .raised = .init(allocator, failure, resolved, location) };
    }
    pub fn retire(self: *ErrorValueCursor, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            inline else => |*cursor| cursor.retire(releases),
        }
    }
    pub fn advance(self: *ErrorValueCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
        return switch (self.*) {
            inline else => |*cursor| cursor.advance(work),
        };
    }
};
/// The spellings a failure value needs, already interned. Qualifying a
/// module-local trace word allocates, so it happens in the resumable failure
/// driver rather than inside the value builder.
pub const ResolvedTrace = struct {
    word: ?u32 = null,
    trace: []const u32 = &.{},
};
