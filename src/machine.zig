//! Defunctionalized CEK evaluator, boundary unwinding, and error dicts.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const native_call = @import("native_call.zig");
const native_module = @import("native_module.zig");
const reader = @import("reader.zig");
const reader_cursor = @import("reader_cursor.zig");
const poll_api = @import("poll.zig");
const reflection = @import("reflection.zig");
const kernel_storage = @import("kernel_storage.zig");
const console_api = @import("console.zig");
const task_join_core = @import("task_join_core.zig");
const resolution_core = @import("resolution_core.zig");
pub const Value = value.Value;
pub const Header = value.ListHandle;
pub const MachineError = error{ OutOfMemory, Ecl };
const no_word = std.math.maxInt(u32);
const max_frame_count = std.math.maxInt(u32);
const FrameIndex = enum(u32) { _ };
const fuel_quantum: u32 = 1024;
pub const kernel_poll_quantum: u32 = 65_536;
pub const IdiomMode = enum { automatic, generic_only };
pub const ErrorKind = enum {
    underflow,
    undefined_word,
    type,
    shape,
    conform,
    overflow,
    domain,
    contract,
    parse,
    io,
    cancelled,
    timeout,
    user,
    /// The spec closes this set, so `else` cannot silently absorb a new kind.
    /// A hyphenated addition would still need its own arm.
    pub fn symbol(self: ErrorKind) []const u8 {
        return switch (self) {
            .undefined_word => "undefined-word",
            else => @tagName(self),
        };
    }
};
const ErrorSite = struct {
    code: *Header,
    index: u32,
};
const ErrorDataKey = enum {
    needed,
    available,
    name,
    path,
    seeded,
    observed,
    expected,
    index,
    left,
    right,
};
const ErrorData = struct {
    key: ErrorDataKey,
    value: Value,
};
const empty_error_data = ErrorData{ .key = .needed, .value = .{ .int = 0 } };
/// Zig errors carry no payload. The unit owns this allocation-free payload
/// until an unwind materializes the language dict.
pub const EclErr = struct {
    kind: ErrorKind,
    message: [512]u8 = [_]u8{0} ** 512,
    message_len: usize = 0,
    word: ?u32 = null,
    trace_parent: ?u32 = null,
    site: ?ErrorSite = null,
    data: [5]ErrorData = .{empty_error_data} ** 5,
    data_len: usize = 0,
    raised: ?Value = null,
    source: [384]u8 = [_]u8{0} ** 384,
    source_len: usize = 0,
    source_line: u32 = 0,
    source_col: u32 = 0,
    pub fn init(kind: ErrorKind, message: []const u8) EclErr {
        var result = EclErr{ .kind = kind };
        result.setMessage(message);
        return result;
    }
    pub fn initFmt(
        kind: ErrorKind,
        comptime format: []const u8,
        args: anytype,
    ) EclErr {
        var result = EclErr{ .kind = kind };
        result.setMessageFmt(format, args);
        return result;
    }
    pub fn text(self: *const EclErr) []const u8 {
        return self.message[0..self.message_len];
    }
    fn addData(self: *EclErr, key: ErrorDataKey, item: Value) void {
        std.debug.assert(self.data_len < self.data.len);
        heap.retainValue(item);
        self.data[self.data_len] = .{ .key = key, .value = item };
        self.data_len += 1;
    }
    fn setMessage(self: *EclErr, message: []const u8) void {
        const fallback = "language error (diagnostic too long)";
        const selected = if (message.len <= self.message.len) message else fallback;
        @memcpy(self.message[0..selected.len], selected);
        self.message_len = selected.len;
    }
    fn setMessageFmt(
        self: *EclErr,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const rendered = std.fmt.bufPrint(&self.message, format, args) catch {
            self.setMessage("language error (diagnostic too long)");
            return;
        };
        self.message_len = rendered.len;
    }
    pub fn retire(self: *EclErr, releases: *heap.ReleaseDomain) void {
        for (self.data[0..self.data_len]) |entry| releases.releaseValue(entry.value);
        if (self.raised) |raised| releases.releaseValue(raised);
    }
    pub fn setLocation(self: *EclErr, source_name: []const u8, span: @import("lexer.zig").Span) void {
        const selected = source_name[0..@min(source_name.len, self.source.len)];
        @memcpy(self.source[0..selected.len], selected);
        self.source_len = selected.len;
        self.source_line = span.line;
        self.source_col = span.col;
    }
};

const ErrorValueProgress = poll_api.Progress(Value);
const OrdinaryErrorCursor = struct {
    allocator: std.mem.Allocator,
    failure: *EclErr,
    trace_ids: []const u32,
    location: ?spans.LocatedSpan,
    names: [9]u32 = .{0} ** 9,
    name_index: usize = 0,
    inserter: ?intern.InternInsertionCursor = null,
    message_builder: ?kernel_storage.TextMaterializer = null,
    message_value: ?Value = null,
    trace_items: ?[]Value = null,
    trace_index: usize = 0,
    trace_builder: ?kernel_storage.ValueMaterializer = null,
    trace_value: ?Value = null,
    data_pairs: [8]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }} ** 8,
    data_index: usize = 0,
    data_inserter: ?intern.InternInsertionCursor = null,
    source_builder: ?kernel_storage.TextMaterializer = null,
    source_value: ?Value = null,
    data_builder: ?kernel_storage.DictMaterializer = null,
    data_value: ?Value = null,
    outer_pairs: [5]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }} ** 5,
    outer_builder: ?kernel_storage.DictMaterializer = null,
    phase: enum { names, message, trace_allocate, trace_copy, trace_build, data, source, data_build, outer, complete } = .names,

    fn init(
        allocator: std.mem.Allocator,
        failure: *EclErr,
        trace_ids: []const u32,
        location: ?spans.LocatedSpan,
    ) OrdinaryErrorCursor {
        return .{
            .allocator = allocator,
            .failure = failure,
            .trace_ids = trace_ids,
            .location = if (failure.source_len > 0) .{
                .source_name = failure.source[0..failure.source_len],
                .span = .{ .line = failure.source_line, .col = failure.source_col },
            } else location,
        };
    }
    fn retire(self: *OrdinaryErrorCursor, releases: *heap.ReleaseDomain) void {
        if (self.message_builder) |*builder| builder.retire(releases);
        if (self.trace_builder) |*builder| builder.retire(releases);
        if (self.source_builder) |*builder| builder.retire(releases);
        if (self.data_builder) |*builder| builder.retire(releases);
        if (self.outer_builder) |*builder| builder.retire(releases);
        if (self.message_value) |item| releases.releaseValue(item);
        if (self.trace_value) |item| releases.releaseValue(item);
        if (self.source_value) |item| releases.releaseValue(item);
        if (self.data_value) |item| releases.releaseValue(item);
        if (self.trace_items) |items| self.allocator.free(items);
    }
    fn nameBytes(self: *const OrdinaryErrorCursor) []const u8 {
        return switch (self.name_index) {
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
    fn advanceNames(self: *OrdinaryErrorCursor) error{OutOfMemory}!ErrorValueProgress {
        if (self.name_index == self.names.len) {
            self.message_builder = .init(self.allocator, self.failure.text());
            self.phase = .message;
            return .pending;
        }
        if (self.inserter == null) self.inserter = intern.insertionCursor(self.nameBytes());
        return switch (try self.inserter.?.advance()) {
            .pending => .pending,
            .complete => |id| result: {
                self.names[self.name_index] = id;
                self.name_index += 1;
                self.inserter = null;
                break :result .pending;
            },
        };
    }
    fn advanceData(self: *OrdinaryErrorCursor) error{OutOfMemory}!ErrorValueProgress {
        if (self.data_index != self.failure.data_len) {
            const entry = self.failure.data[self.data_index];
            if (self.data_inserter == null)
                self.data_inserter = intern.insertionCursor(@tagName(entry.key));
            return switch (try self.data_inserter.?.advance()) {
                .pending => .pending,
                .complete => |key| result: {
                    self.data_pairs[self.data_index] = .{ .{ .symbol = key }, entry.value };
                    self.data_index += 1;
                    self.data_inserter = null;
                    break :result .pending;
                },
            };
        }
        if (self.location) |located| {
            self.source_builder = .init(self.allocator, located.source_name);
            self.phase = .source;
        } else {
            self.data_builder = try .init(self.allocator, self.data_pairs[0..self.data_index], false);
            self.phase = .data_build;
        }
        return .pending;
    }
    fn beginOuter(self: *OrdinaryErrorCursor) error{OutOfMemory}!void {
        var count: usize = 0;
        self.outer_pairs[count] = .{ .{ .symbol = self.names[1] }, .{ .symbol = self.names[0] } };
        count += 1;
        self.outer_pairs[count] = .{ .{ .symbol = self.names[2] }, self.message_value.? };
        count += 1;
        if (self.failure.word) |word| {
            self.outer_pairs[count] = .{ .{ .symbol = self.names[3] }, .{ .symbol = word } };
            count += 1;
        }
        self.outer_pairs[count] = .{ .{ .symbol = self.names[4] }, self.trace_value.? };
        count += 1;
        self.outer_pairs[count] = .{ .{ .symbol = self.names[5] }, self.data_value.? };
        count += 1;
        self.outer_builder = try .init(self.allocator, self.outer_pairs[0..count], false);
        self.phase = .outer;
    }
    pub fn advance(self: *OrdinaryErrorCursor) error{OutOfMemory}!ErrorValueProgress {
        return switch (self.phase) {
            .names => try self.advanceNames(),
            .message => switch (try self.message_builder.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.message_builder.?.deinit();
                    self.message_builder = null;
                    self.message_value = item;
                    self.phase = .trace_allocate;
                    break :result .pending;
                },
            },
            .trace_allocate => result: {
                self.trace_items = try self.allocator.alloc(Value, self.trace_ids.len);
                self.phase = .trace_copy;
                break :result .pending;
            },
            .trace_copy => result: {
                if (self.trace_index != self.trace_ids.len) {
                    self.trace_items.?[self.trace_index] = .{ .symbol = self.trace_ids[self.trace_index] };
                    self.trace_index += 1;
                } else {
                    self.trace_builder = .init(self.allocator, self.trace_items.?);
                    self.phase = .trace_build;
                }
                break :result .pending;
            },
            .trace_build => switch (try self.trace_builder.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.trace_builder.?.deinit();
                    self.trace_builder = null;
                    self.trace_value = item;
                    self.phase = .data;
                    break :result .pending;
                },
            },
            .data => try self.advanceData(),
            .source => switch (try self.source_builder.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.source_builder.?.deinit();
                    self.source_builder = null;
                    self.source_value = item;
                    const located = self.location.?;
                    self.data_pairs[self.data_index] = .{ .{ .symbol = self.names[6] }, item };
                    self.data_index += 1;
                    self.data_pairs[self.data_index] = .{ .{ .symbol = self.names[7] }, .{ .int = located.span.line } };
                    self.data_index += 1;
                    self.data_pairs[self.data_index] = .{ .{ .symbol = self.names[8] }, .{ .int = located.span.col } };
                    self.data_index += 1;
                    self.data_builder = try .init(self.allocator, self.data_pairs[0..self.data_index], false);
                    self.phase = .data_build;
                    break :result .pending;
                },
            },
            .data_build => switch (try self.data_builder.?.advance(1)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    self.data_builder.?.deinit();
                    self.data_builder = null;
                    self.data_value = item;
                    try self.beginOuter();
                    break :result .pending;
                },
            },
            .outer => switch (try self.outer_builder.?.advance(1)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    self.outer_builder.?.deinit();
                    self.outer_builder = null;
                    self.phase = .complete;
                    break :result .{ .complete = item };
                },
            },
            .complete => unreachable,
        };
    }
};

const RaisedErrorCursor = struct {
    allocator: std.mem.Allocator,
    failure: *EclErr,
    trace_ids: []const u32,
    location: ?spans.LocatedSpan,
    names: [8]u32 = .{0} ** 8,
    name_index: usize = 0,
    inserter: ?intern.InternInsertionCursor = null,
    fields: [5]?Value = .{null} ** 5,
    field_index: usize = 0,
    finder: ?kernel_storage.DictFindCursor = null,
    message_bytes: [512]u8 = .{0} ** 512,
    message_len: usize = 0,
    message_builder: ?kernel_storage.TextMaterializer = null,
    message_value: ?Value = null,
    trace_items: ?[]Value = null,
    trace_index: usize = 0,
    trace_builder: ?kernel_storage.ValueMaterializer = null,
    trace_value: ?Value = null,
    data_fields: [3]?Value = .{null} ** 3,
    data_field_index: usize = 0,
    data_finder: ?kernel_storage.DictFindCursor = null,
    data_pairs: ?[]dict.Pair = null,
    data_copy_index: usize = 0,
    add_source: bool = false,
    add_line: bool = false,
    add_col: bool = false,
    source_builder: ?kernel_storage.TextMaterializer = null,
    source_value: ?Value = null,
    data_builder: ?kernel_storage.DictMaterializer = null,
    data_value: ?Value = null,
    outer_pairs: ?[]dict.Pair = null,
    outer_copy_index: usize = 0,
    outer_builder: ?kernel_storage.DictMaterializer = null,
    phase: enum {
        names,
        fields,
        message,
        trace_allocate,
        trace_copy,
        trace_build,
        data_fields,
        data_allocate,
        data_copy,
        source,
        data_build,
        outer_allocate,
        outer_copy,
        outer_build,
        complete,
    } = .names,

    fn init(
        allocator: std.mem.Allocator,
        failure: *EclErr,
        trace_ids: []const u32,
        location: ?spans.LocatedSpan,
    ) RaisedErrorCursor {
        return .{
            .allocator = allocator,
            .failure = failure,
            .trace_ids = trace_ids,
            .location = if (failure.source_len > 0) .{
                .source_name = failure.source[0..failure.source_len],
                .span = .{ .line = failure.source_line, .col = failure.source_col },
            } else location,
        };
    }
    fn retire(self: *RaisedErrorCursor, releases: *heap.ReleaseDomain) void {
        if (self.finder) |*finder| finder.deinit();
        if (self.data_finder) |*finder| finder.deinit();
        if (self.message_builder) |*builder| builder.retire(releases);
        if (self.trace_builder) |*builder| builder.retire(releases);
        if (self.source_builder) |*builder| builder.retire(releases);
        if (self.data_builder) |*builder| builder.retire(releases);
        if (self.outer_builder) |*builder| builder.retire(releases);
        if (self.message_value) |item| releases.releaseValue(item);
        if (self.trace_value) |item| releases.releaseValue(item);
        if (self.source_value) |item| releases.releaseValue(item);
        if (self.data_value) |item| releases.releaseValue(item);
        if (self.trace_items) |items| self.allocator.free(items);
        if (self.data_pairs) |pairs| self.allocator.free(pairs);
        if (self.outer_pairs) |pairs| self.allocator.free(pairs);
    }
    fn nameBytes(self: *const RaisedErrorCursor) []const u8 {
        const names = [_][]const u8{ "kind", "msg", "word", "trace", "data", "source", "line", "col" };
        return names[self.name_index];
    }
    fn beginOptionalValues(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        if (self.fields[1] == null) {
            const kind = self.fields[0].?.symbol;
            const message = std.fmt.bufPrint(&self.message_bytes, "raised '{s}", .{intern.get(kind)}) catch
                "raised user error";
            self.message_len = message.len;
            if (message.ptr != self.message_bytes[0..].ptr)
                @memcpy(self.message_bytes[0..message.len], message);
            self.message_builder = .init(self.allocator, self.message_bytes[0..self.message_len]);
            self.phase = .message;
        } else if (self.fields[3] == null) {
            self.phase = .trace_allocate;
        } else {
            self.phase = .data_fields;
        }
    }
    fn beginData(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        const old_data = self.fields[4];
        if (old_data == null or self.location != null and
            !(self.data_fields[0] != null and self.data_fields[1] != null and self.data_fields[2] != null))
        {
            const old_count: usize = if (old_data) |item| @intCast(item.dict.length()) else 0;
            self.add_source = self.location != null and self.data_fields[0] == null;
            self.add_line = self.location != null and self.data_fields[1] == null;
            self.add_col = self.location != null and self.data_fields[2] == null;
            const count = old_count + @as(usize, @intFromBool(self.add_source)) +
                @as(usize, @intFromBool(self.add_line)) +
                @as(usize, @intFromBool(self.add_col));
            self.data_pairs = try self.allocator.alloc(dict.Pair, count);
            self.phase = .data_copy;
        } else self.phase = .outer_allocate;
    }
    fn appendDataContext(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        var index = self.data_copy_index;
        const located = self.location.?;
        if (self.add_source) {
            if (self.source_value == null) {
                self.source_builder = .init(self.allocator, located.source_name);
                self.phase = .source;
                return;
            }
            self.data_pairs.?[index] = .{ .{ .symbol = self.names[5] }, self.source_value.? };
            index += 1;
        }
        if (self.add_line) {
            self.data_pairs.?[index] = .{ .{ .symbol = self.names[6] }, .{ .int = located.span.line } };
            index += 1;
        }
        if (self.add_col) {
            self.data_pairs.?[index] = .{ .{ .symbol = self.names[7] }, .{ .int = located.span.col } };
            index += 1;
        }
        self.data_builder = try .init(self.allocator, self.data_pairs.?[0..index], false);
        self.phase = .data_build;
    }
    fn beginOuter(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        const raised = self.failure.raised.?;
        const old_count: usize = @intCast(raised.dict.length());
        const extra = @as(usize, @intFromBool(self.fields[1] == null)) +
            @as(usize, @intFromBool(self.fields[2] == null and self.failure.word != null)) +
            @as(usize, @intFromBool(self.fields[3] == null)) +
            @as(usize, @intFromBool(self.fields[4] == null));
        self.outer_pairs = try self.allocator.alloc(dict.Pair, old_count + extra);
        self.phase = .outer_copy;
    }
    fn appendOuter(self: *RaisedErrorCursor) error{OutOfMemory}!void {
        var index = self.outer_copy_index;
        if (self.fields[1] == null) {
            self.outer_pairs.?[index] = .{ .{ .symbol = self.names[1] }, self.message_value.? };
            index += 1;
        }
        if (self.fields[2] == null) if (self.failure.word) |word| {
            self.outer_pairs.?[index] = .{ .{ .symbol = self.names[2] }, .{ .symbol = word } };
            index += 1;
        };
        if (self.fields[3] == null) {
            self.outer_pairs.?[index] = .{ .{ .symbol = self.names[3] }, self.trace_value.? };
            index += 1;
        }
        if (self.fields[4] == null) {
            self.outer_pairs.?[index] = .{ .{ .symbol = self.names[4] }, self.data_value.? };
            index += 1;
        }
        self.outer_builder = try .init(self.allocator, self.outer_pairs.?[0..index], false);
        self.phase = .outer_build;
    }
    pub fn advance(self: *RaisedErrorCursor) error{OutOfMemory}!ErrorValueProgress {
        const raised = self.failure.raised.?;
        return switch (self.phase) {
            .names => result: {
                if (self.name_index == self.names.len) {
                    self.phase = .fields;
                    break :result .pending;
                }
                if (self.inserter == null) self.inserter = intern.insertionCursor(self.nameBytes());
                switch (try self.inserter.?.advance()) {
                    .pending => {},
                    .complete => |id| {
                        self.names[self.name_index] = id;
                        self.name_index += 1;
                        self.inserter = null;
                    },
                }
                break :result .pending;
            },
            .fields => result: {
                if (self.finder) |*finder| switch (try finder.advance(1)) {
                    .pending => break :result .pending,
                    .complete => |found| {
                        finder.deinit();
                        self.finder = null;
                        self.fields[self.field_index] = found;
                        self.field_index += 1;
                        break :result .pending;
                    },
                };
                if (self.field_index == self.fields.len) {
                    try self.beginOptionalValues();
                } else self.finder = .initHeader(
                    self.allocator,
                    raised.dict,
                    .{ .symbol = self.names[self.field_index] },
                );
                break :result .pending;
            },
            .message => switch (try self.message_builder.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.message_builder.?.deinit();
                    self.message_builder = null;
                    self.message_value = item;
                    self.phase = if (self.fields[3] == null) .trace_allocate else .data_fields;
                    break :result .pending;
                },
            },
            .trace_allocate => result: {
                self.trace_items = try self.allocator.alloc(Value, self.trace_ids.len);
                self.phase = .trace_copy;
                break :result .pending;
            },
            .trace_copy => result: {
                if (self.trace_index != self.trace_ids.len) {
                    self.trace_items.?[self.trace_index] = .{ .symbol = self.trace_ids[self.trace_index] };
                    self.trace_index += 1;
                } else {
                    self.trace_builder = .init(self.allocator, self.trace_items.?);
                    self.phase = .trace_build;
                }
                break :result .pending;
            },
            .trace_build => switch (try self.trace_builder.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.trace_builder.?.deinit();
                    self.trace_builder = null;
                    self.trace_value = item;
                    self.phase = .data_fields;
                    break :result .pending;
                },
            },
            .data_fields => result: {
                const old_data = self.fields[4];
                if (old_data == null or self.location == null) {
                    try self.beginData();
                    break :result .pending;
                }
                if (self.data_finder) |*finder| switch (try finder.advance(1)) {
                    .pending => break :result .pending,
                    .complete => |found| {
                        finder.deinit();
                        self.data_finder = null;
                        self.data_fields[self.data_field_index] = found;
                        self.data_field_index += 1;
                        break :result .pending;
                    },
                };
                if (self.data_field_index == self.data_fields.len) {
                    try self.beginData();
                } else self.data_finder = .initHeader(
                    self.allocator,
                    old_data.?.dict,
                    .{ .symbol = self.names[5 + self.data_field_index] },
                );
                break :result .pending;
            },
            .data_allocate => unreachable,
            .data_copy => result: {
                const old_data = self.fields[4];
                const old_count: usize = if (old_data) |item| @intCast(item.dict.length()) else 0;
                if (self.data_copy_index != old_count) {
                    self.data_pairs.?[self.data_copy_index] = .{
                        dict.keyAt(old_data.?.dict, self.data_copy_index),
                        dict.valueAt(old_data.?.dict, self.data_copy_index),
                    };
                    self.data_copy_index += 1;
                } else try self.appendDataContext();
                break :result .pending;
            },
            .source => switch (try self.source_builder.?.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    self.source_builder.?.deinit();
                    self.source_builder = null;
                    self.source_value = item;
                    try self.appendDataContext();
                    break :result .pending;
                },
            },
            .data_build => switch (try self.data_builder.?.advance(1)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    self.data_builder.?.deinit();
                    self.data_builder = null;
                    self.data_value = item;
                    self.phase = .outer_allocate;
                    break :result .pending;
                },
            },
            .outer_allocate => result: {
                try self.beginOuter();
                break :result .pending;
            },
            .outer_copy => result: {
                const old_count: usize = @intCast(raised.dict.length());
                if (self.outer_copy_index != old_count) {
                    const key = dict.keyAt(raised.dict, self.outer_copy_index);
                    const old_value = dict.valueAt(raised.dict, self.outer_copy_index);
                    self.outer_pairs.?[self.outer_copy_index] = .{
                        key,
                        if (key == .symbol and key.symbol == self.names[4] and self.data_value != null)
                            self.data_value.?
                        else
                            old_value,
                    };
                    self.outer_copy_index += 1;
                } else try self.appendOuter();
                break :result .pending;
            },
            .outer_build => switch (try self.outer_builder.?.advance(1)) {
                .pending => .pending,
                .duplicate_key => unreachable,
                .complete => |item| result: {
                    self.outer_builder.?.deinit();
                    self.outer_builder = null;
                    self.phase = .complete;
                    break :result .{ .complete = item };
                },
            },
            .complete => unreachable,
        };
    }
};

const ErrorValueCursor = union(enum) {
    ordinary: OrdinaryErrorCursor,
    raised: RaisedErrorCursor,
    fn init(
        allocator: std.mem.Allocator,
        failure: *EclErr,
        trace_ids: []const u32,
        location: ?spans.LocatedSpan,
    ) ErrorValueCursor {
        return if (failure.raised == null)
            .{ .ordinary = .init(allocator, failure, trace_ids, location) }
        else
            .{ .raised = .init(allocator, failure, trace_ids, location) };
    }
    fn retire(self: *ErrorValueCursor, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            inline else => |*cursor| cursor.retire(releases),
        }
    }
    pub fn advance(self: *ErrorValueCursor) error{OutOfMemory}!ErrorValueProgress {
        return switch (self.*) {
            inline else => |*cursor| cursor.advance(),
        };
    }
};
pub fn errorValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    failure: *EclErr,
    trace_ids: []const u32,
    location: ?spans.LocatedSpan,
) error{OutOfMemory}!Value {
    var cursor = ErrorValueCursor.init(allocator, failure, trace_ids, location);
    defer cursor.retire(releases);
    return poll_api.driveFallible(Value, &cursor, .{});
}
pub fn stringValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    bytes: []const u8,
) error{OutOfMemory}!Value {
    var materializer = kernel_storage.TextMaterializer.init(allocator, bytes);
    defer materializer.retire(releases);
    return poll_api.driveFallible(Value, &materializer, .{kernel_poll_quantum});
}
const Eval = struct {
    code: *Header,
    ip: u32,
    scope: *env.Scope,
    home: ?*modules.ModuleHome,
    traced_word: u32,
};
/// One tagged owner of everything a `within` transaction needs: the private
/// draft of the home slot's durable stack (the unit window above
/// `draft_base`), the pending outputs `without` moved outward, the slot turn
/// that serializes it, and the publication transition itself. Only
/// `beginWithin` constructs one, and it is consumed exactly once — by
/// publication on success, or by retirement on every failure.
pub const StateApplication = struct {
    unit: *Unit,
    turn: modules.StateTurn,
    outputs: std.ArrayList(Value) = .empty,
    draft_base: u32 = 0,

    fn retire(
        self: *StateApplication,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.unit.state_application == self) self.unit.state_application = null;
        for (self.outputs.items) |item| releases.releaseValue(item);
        self.outputs.deinit(allocator);
        self.turn.release();
        allocator.destroy(self);
    }
};

/// Unique ownership of one in-flight state application, in the same shape
/// as `modules.OwnedCandidate`. Every transfer is a move, so the boundary
/// frame and the driver that built it can never both retire the same
/// transaction — the failure that a shared raw pointer invites.
const OwnedApplication = enum(usize) {
    consumed = 0,
    _,

    fn init(application: *StateApplication) OwnedApplication {
        return @enumFromInt(@intFromPtr(application));
    }
    fn borrow(self: OwnedApplication) *StateApplication {
        std.debug.assert(self != .consumed);
        return @ptrFromInt(@intFromEnum(self));
    }
    fn move(self: *OwnedApplication) OwnedApplication {
        const result = self.*;
        std.debug.assert(result != .consumed);
        self.* = .consumed;
        return result;
    }
    pub fn retire(
        self: *OwnedApplication,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.* == .consumed) return;
        const application = self.borrow();
        self.* = .consumed;
        application.retire(releases, allocator);
    }
};

const BoundaryMode = union(enum) {
    attempt: *env.Scope,
    module: modules.OwnedCandidate,
    state: OwnedApplication,
};
const Boundary = struct {
    mode: BoundaryMode,
    stack_base: u32,
    previous_base: u32,
    previous_boundary: ?FrameIndex,
    word: u32,
    fn deinit(
        self: Boundary,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.mode) {
            .module => |candidate_value| {
                var candidate = candidate_value;
                candidate.deinit();
            },
            .attempt => |scope| {
                scope.retire();
            },
            .state => |owned| {
                var application = owned;
                application.retire(releases, allocator);
            },
        }
    }
};
pub const EffectCheck = struct {
    expected_depth: u32,
    entry_depth: u32,
    inputs: u32,
    outputs: u32,
    word: u32,
};
pub const StackWindow = enum(u32) {
    _,

    fn init(depth: usize, seeded: u32) ?StackWindow {
        if (depth < seeded) return null;
        return @enumFromInt(@as(u32, @intCast(depth - seeded)));
    }
    pub fn base(self: StackWindow) u32 {
        return @intFromEnum(self);
    }
    pub fn observed(self: StackWindow, depth: usize) ?usize {
        const start: usize = self.base();
        if (depth < start) return null;
        return depth - start;
    }
};
pub const ApplicationStep = struct {
    quotation: *Header,
    seeded: u32,
};
pub const IsolatedApplication = struct {
    quotation: *Header,
    context: *anyopaque,
    resume_fn: *const fn (*Machine, *anyopaque, StackWindow) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    parent_scope: *env.Scope,
    home: ?*modules.ModuleHome,
    seeded: u32,
};

fn ApplicationAdapters(comptime Driver: type) type {
    return struct {
        fn run(
            evaluator: *Machine,
            raw: *anyopaque,
            window: StackWindow,
        ) MachineError!?ApplicationStep {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            return Driver.resumeApplication(evaluator, driver, window);
        }

        fn deinit(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.destroyDriver(releases, allocator, driver);
        }
    };
}

pub fn typedApplication(
    driver: anytype,
    quotation: *Header,
    parent_scope: *env.Scope,
    home: ?*modules.ModuleHome,
    seeded: u32,
) IsolatedApplication {
    const Context = @TypeOf(driver);
    const pointer = switch (@typeInfo(Context)) {
        .pointer => |info| info,
        else => @compileError("application driver must be a pointer"),
    };
    if (pointer.size != .one) @compileError("application driver must be a single-item pointer");
    const Driver = pointer.child;
    const adapters = ApplicationAdapters(Driver);
    return .{
        .quotation = quotation,
        .context = @ptrCast(driver),
        .resume_fn = adapters.run,
        .deinit_fn = adapters.deinit,
        .parent_scope = parent_scope,
        .home = home,
        .seeded = seeded,
    };
}
const ApplicationMode = union(enum) {
    in_place: StackWindow,
    isolated: struct {
        child: *env.Scope,
        previous_base: StackWindow,
    },
};
const ApplicationFrame = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Machine, *anyopaque, StackWindow) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    parent_scope: *env.Scope,
    home: ?*modules.ModuleHome,
    mode: ApplicationMode,
    traced_word: u32,
    fn deinit(self: ApplicationFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self.mode) {
            .in_place => {},
            .isolated => |isolated| {
                isolated.child.retire();
            },
        }
        self.deinit_fn(releases, allocator, self.context);
    }
};
pub const Frame = union(enum(u8)) {
    eval: Eval,
    effect_check: EffectCheck,
    application: ApplicationFrame,
    use_after_load: struct {
        loading: modules.LoadingLease,
        scope: *env.Scope,
        name: intern.ModuleName,
        path: Value,
    },
    boundary: Boundary,
    fn deinit(self: Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self) {
            .eval => |frame| releases.releaseHeader(frame.code),
            .effect_check => {},
            .application => |frame| frame.deinit(releases, allocator),
            .use_after_load => |frame| {
                var loading = frame.loading;
                loading.deinit();
                releases.releaseValue(frame.path);
            },
            .boundary => |boundary| boundary.deinit(releases, allocator),
        }
    }
};
/// A linear frame-construction capability. `appendFrame` consumes it only
/// after ArrayList growth succeeds; on failure the caller still owns exactly
/// one capability whose deinit releases the frame cargo.
const OwnedFrame = struct {
    frame: ?Frame,

    fn init(frame: Frame) OwnedFrame {
        return .{ .frame = frame };
    }

    fn deinit(
        self: *OwnedFrame,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.frame) |frame| frame.deinit(releases, allocator);
        self.frame = null;
    }

    fn take(self: *OwnedFrame) Frame {
        const frame = self.frame.?;
        self.frame = null;
        return frame;
    }
};
comptime {
    // The tagged application mode and immutable driver identity are worth the
    // extra words: invalid correlated continuation states are unrepresentable.
    if (@sizeOf(Frame) > 80) @compileError("machine frames must remain at most 80 bytes");
}
pub const IdiomRequest = union(enum) {
    direct: struct { body: *Header, word: u32 },
    each,
    zip_with,
    fold,
    scan,
};
pub const IdiomFallback = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (*Machine, ?*anyopaque) MachineError!void,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, ?*anyopaque) void,
    pub fn run(self: IdiomFallback, evaluator: *Machine) MachineError!void {
        return self.run_fn(evaluator, self.context);
    }
    pub fn deinit(self: IdiomFallback, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, self.context);
    }
};

/// Configuration and semantic services inherited by every spawned Unit.
/// Keeping this as one value makes addition of a new inherited service an
/// atomic parent-to-child copy instead of a scheduler-site field checklist.
pub const InheritedContext = struct {
    registry: ?*modules.Registry = null,
    native_loader: ?*native_module.Loader = null,
    native_diagnostics: bool = false,
    diagnostics: ?*std.Io.Writer = null,
    console: ?*console_api.Console = null,
    host_io: ?std.Io = null,
    ecl_path: ?[]const u8 = null,
    idiom_mode: IdiomMode = .automatic,
    phrase_recognizer: ?PhraseRecognizer = null,
};

fn IdiomFallbackAdapters(comptime Driver: type) type {
    return struct {
        fn run(evaluator: *Machine, raw: ?*anyopaque) MachineError!void {
            const driver: *Driver = @ptrCast(@alignCast(raw.?));
            return Driver.run(evaluator, driver);
        }

        fn deinit(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: ?*anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw.?));
            heap.destroyDriver(releases, allocator, driver);
        }
    };
}

pub fn typedIdiomFallback(driver: anytype) IdiomFallback {
    const Context = @TypeOf(driver);
    const pointer = switch (@typeInfo(Context)) {
        .pointer => |info| info,
        else => @compileError("idiom fallback driver must be a pointer"),
    };
    if (pointer.size != .one) @compileError("idiom fallback driver must be a single-item pointer");
    const Driver = pointer.child;
    const adapters = IdiomFallbackAdapters(Driver);
    return .{
        .context = @ptrCast(driver),
        .run_fn = adapters.run,
        .deinit_fn = adapters.deinit,
    };
}
pub const PhraseRecognizer = *const fn (*Machine, IdiomRequest, IdiomFallback) MachineError!void;

pub const ParkRequest = union(enum) {
    task: Value,
    any: Value,
    deadline: struct { task: Value, milliseconds: i64 },
    close_scope: u8,
    join: struct {
        tasks: Value,
        index: u32,
        cancel_from: ?u32 = null,
    },

    /// The one value graph owned by every parking request that carries one.
    /// Scheduler setup, abandonment, and ordinary deinit all use this mapping.
    pub fn ownedValue(self: ParkRequest) ?Value {
        return switch (self) {
            .task, .any => |item| item,
            .deadline => |deadline| deadline.task,
            .join => |join| join.tasks,
            .close_scope => null,
        };
    }

    pub fn taskCount(self: ParkRequest) usize {
        return switch (self) {
            .task, .deadline, .join => 1,
            .any => |tasks| @intCast(tasks.list.length()),
            .close_scope => 0,
        };
    }

    pub fn taskAt(self: ParkRequest, index: usize) Value {
        return switch (self) {
            .task => |task| single: {
                std.debug.assert(index == 0);
                break :single task;
            },
            .deadline => |deadline| single: {
                std.debug.assert(index == 0);
                break :single deadline.task;
            },
            .any => |tasks| list.atUnchecked(tasks, index),
            .join => |join| single: {
                std.debug.assert(index == 0);
                break :single list.atUnchecked(join.tasks, join.index);
            },
            .close_scope => unreachable,
        };
    }

    pub fn deinit(self: ParkRequest, releases: *heap.ReleaseDomain) void {
        if (self.ownedValue()) |item| releases.releaseValue(item);
    }
};

pub const ParkResume = union(enum) {
    outcome: Value,
    indexed: struct { index: u32, outcome: Value },
    timeout,
    cancelled,
    io,
    out_of_memory,
    scope_closed: u8,

    pub fn ownedValue(self: ParkResume) ?Value {
        return switch (self) {
            .outcome => |outcome| outcome,
            .indexed => |indexed| indexed.outcome,
            .timeout, .cancelled, .io, .out_of_memory, .scope_closed => null,
        };
    }

    fn deinit(self: ParkResume, releases: *heap.ReleaseDomain) void {
        if (self.ownedValue()) |item| releases.releaseValue(item);
    }
};

pub const TaskJoinState = struct {
    tasks: Value,
    results: heap.OwnedValueBuffer,
    policy: task_join_core.Join,
    ok_id: u32,
    err_id: u32,
    raised: ?Value = null,
};

const TaskJoinTeardown = struct {
    tasks: Value,
    results: ?heap.OwnedValueBuffer,
    raised: ?Value,
    extra: ?Value,
    phase: enum { extra, tasks, results, raised, complete } = .extra,

    const Advance = struct { complete: bool, consumed: usize };

    fn init(join: TaskJoinState, extra: ?Value) TaskJoinTeardown {
        return .{
            .tasks = join.tasks,
            .results = join.results,
            .raised = join.raised,
            .extra = extra,
        };
    }

    fn inputOnly(tasks: Value) TaskJoinTeardown {
        return .{
            .tasks = tasks,
            .results = null,
            .raised = null,
            .extra = null,
        };
    }

    pub fn advance(self: *TaskJoinTeardown, releases: *heap.ReleaseDomain, budget: usize) Advance {
        var consumed: usize = 0;
        while (consumed != budget) {
            switch (self.phase) {
                .extra => {
                    self.phase = .tasks;
                    if (self.extra) |item| {
                        self.extra = null;
                        releases.releaseValue(item);
                        consumed += 1;
                    }
                },
                .tasks => {
                    self.phase = .results;
                    releases.releaseValue(self.tasks);
                    consumed += 1;
                },
                .results => {
                    if (self.results) |*results| results.deinit();
                    self.results = null;
                    self.phase = .raised;
                    consumed += 1;
                },
                .raised => {
                    self.phase = .complete;
                    if (self.raised) |raised| {
                        self.raised = null;
                        releases.releaseValue(raised);
                        consumed += 1;
                    }
                },
                .complete => return .{ .complete = true, .consumed = consumed },
            }
        }
        return .{ .complete = self.phase == .complete, .consumed = consumed };
    }
};

const TaskJoinCleanupDisposition = enum {
    continue_evaluation,
    out_of_memory,
};

/// The payload and the action to take after releasing it are one state. This
/// prevents cleanup from completing after its former OOM flag was lost,
/// duplicated, or observed independently.
const TaskJoinCleanup = union(enum) {
    continue_evaluation: TaskJoinTeardown,
    out_of_memory: TaskJoinTeardown,

    fn init(
        teardown: TaskJoinTeardown,
        after: TaskJoinCleanupDisposition,
    ) TaskJoinCleanup {
        return switch (after) {
            .continue_evaluation => .{ .continue_evaluation = teardown },
            .out_of_memory => .{ .out_of_memory = teardown },
        };
    }

    pub fn advance(self: *TaskJoinCleanup, releases: *heap.ReleaseDomain, budget: usize) TaskJoinTeardown.Advance {
        return switch (self.*) {
            inline else => |*teardown| teardown.advance(releases, budget),
        };
    }

    fn disposition(self: TaskJoinCleanup) TaskJoinCleanupDisposition {
        return switch (self) {
            .continue_evaluation => .continue_evaluation,
            .out_of_memory => .out_of_memory,
        };
    }
};

/// A driver transfers an owned result through this completion state. The
/// evaluator destroys the driver before committing that value to the stack,
/// so stack-growth failure always has exactly one resumable owner.
pub const WorkProgress = union(enum) {
    completed,
    output: Value,
    yielded,
    detached,
    failed,
};
pub const CleanupProgress = struct { complete: bool, consumed: usize };

/// A validated capability for a fixed number of non-fallible stack commits.
/// The expected length makes stale copies fail before they can transfer a
/// value twice.
pub const StackReservation = struct {
    unit: *Unit,
    next_len: usize,
    remaining: usize,

    fn init(unit: *Unit, count: usize) StackReservation {
        std.debug.assert(unit.stack.capacity - unit.stack.items.len >= count);
        return .{ .unit = unit, .next_len = unit.stack.items.len, .remaining = count };
    }

    pub fn pushOwned(self: *StackReservation, item: Value) void {
        std.debug.assert(self.remaining != 0);
        std.debug.assert(self.unit.stack.items.len == self.next_len);
        self.unit.stack.appendAssumeCapacity(item);
        self.next_len += 1;
        self.remaining -= 1;
    }

    pub fn pushBorrowed(self: *StackReservation, item: Value) void {
        heap.retainValue(item);
        self.pushOwned(item);
    }

    pub fn complete(self: *const StackReservation) bool {
        return self.remaining == 0;
    }
};

/// Validated exact replacement of the current operand suffix. Capacity is
/// secured before this capability is returned; `commitOwned` is the only
/// splice that releases the inputs and transfers the completed outputs.
pub const StackReplacement = struct {
    unit: *Unit,
    base: usize,
    input_count: usize,
    output_count: usize,

    pub fn commitOwned(self: *StackReplacement, outputs: []const Value) void {
        std.debug.assert(outputs.len == self.output_count);
        std.debug.assert(self.unit.stack.items.len == self.base + self.input_count);
        for (self.unit.stack.items[self.base..]) |item| self.unit.releases.releaseValue(item);
        self.unit.stack.items.len = self.base;
        for (outputs) |item| self.unit.stack.appendAssumeCapacity(item);
    }
};

const TaskJoinCleanupProgress = struct {
    complete: bool,
    consumed: usize,
    disposition: ?TaskJoinCleanupDisposition = null,
};

/// Type-erased owned continuation for native work that must return to the
/// scheduler between bounded slices.
pub const WorkDriver = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Machine, *anyopaque) MachineError!WorkProgress,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ?ErrorSite,
    trace_parent: ?u32 = null,

    pub fn advance(self: WorkDriver, evaluator: *Machine) MachineError!WorkProgress {
        return self.resume_fn(evaluator, self.context);
    }

    fn deinit(self: WorkDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, self.context);
    }
};

/// The scheduler-visible native continuation owned by a unit.  A task join
/// carries its wait request or delivered result in the same variant, so the
/// evaluator cannot represent an unrelated driver, park, and join at once.
pub const NativeContinuation = union(enum) {
    idle,
    yielded,
    work: WorkDriver,
    park_request: ParkRequest,
    park_resume: ParkResume,
    task_join: TaskJoinState,
    task_join_request: struct { join: TaskJoinState, request: ParkRequest },
    task_join_resume: struct { join: TaskJoinState, result: ParkResume },
    task_join_cleanup: TaskJoinCleanup,
    work_join_cleanup: struct { driver: WorkDriver, cleanup: TaskJoinCleanup },
};

fn WorkDriverAdapters(comptime Driver: type) type {
    return struct {
        pub fn advance(evaluator: *Machine, raw: *anyopaque) MachineError!WorkProgress {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            return Driver.advance(evaluator, driver);
        }

        fn deinit(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.destroyDriver(releases, allocator, driver);
        }
    };
}

comptime {
    if (@sizeOf(WorkDriver) > 80) @compileError("WorkDriver exceeds its fixed frame budget");
}

pub const Unit = struct {
    const LifetimeGuard = struct {
        const State = union(enum) {
            active: std.ArrayList(modules.GenerationPin),
            scope: struct {
                cursor: ?env.Scope.EmbeddedTeardownCursor = null,
                generation_pins: std.ArrayList(modules.GenerationPin),
            },
            pins: std.ArrayList(modules.GenerationPin),
            complete,
        };
        // Child scopes retain this address, so it must never move while the
        // unit is alive. Teardown state moves around it instead.
        root_scope: env.Scope,
        state: State,

        fn init(allocator: std.mem.Allocator, environment: *env.Env) LifetimeGuard {
            return .{
                .root_scope = environment.sessionRoot(allocator),
                .state = .{ .active = .empty },
            };
        }

        fn replaceRoot(self: *LifetimeGuard, root: env.Scope) void {
            std.debug.assert(self.state == .active);
            self.root_scope.releaseTrivial();
            self.root_scope = root;
        }

        fn pin(
            self: *LifetimeGuard,
            allocator: std.mem.Allocator,
            generation: *modules.ModuleHome,
            access: *const modules.ExecutionAccess,
        ) error{OutOfMemory}!void {
            const pins = &self.state.active;
            for (pins.items) |pinned| if (pinned.matches(generation, access)) return;
            var owned_pin = generation.pin(access);
            errdefer owned_pin.deinit();
            try pins.append(allocator, owned_pin);
        }

        fn rootScope(self: *LifetimeGuard) *env.Scope {
            std.debug.assert(self.state == .active);
            return &self.root_scope;
        }

        fn advanceTeardown(
            self: *LifetimeGuard,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) bool {
            return switch (self.state) {
                .active => |pins| result: {
                    self.state = .{ .scope = .{
                        .generation_pins = pins,
                    } };
                    break :result false;
                },
                .scope => |*scope| result: {
                    _ = releases;
                    if (scope.cursor == null)
                        scope.cursor = .init(&self.root_scope);
                    if (!scope.cursor.?.advance()) break :result false;
                    const pins = scope.generation_pins;
                    self.state = .{ .pins = pins };
                    break :result false;
                },
                .pins => |*pins| if (pins.pop()) |pin_value| result: {
                    var owned_pin = pin_value;
                    owned_pin.deinit();
                    break :result false;
                } else result: {
                    pins.deinit(allocator);
                    self.state = .complete;
                    break :result true;
                },
                .complete => true,
            };
        }

        fn deinit(
            self: *LifetimeGuard,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            while (!self.advanceTeardown(releases, allocator)) {}
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    module_access: *const modules.ExecutionAccess,
    frames: std.ArrayList(Frame) = .empty,
    stack: std.ArrayList(Value),
    environment: *env.Env,
    inherited: InheritedContext = .{},
    lifetime: LifetimeGuard,
    archive: *spans.SpanArchive,
    output: ?*std.Io.Writer,
    arguments: Value,
    cancelled: *const std.atomic.Value(bool),
    fuel: u32 = fuel_quantum,
    kernel_fuel: u32 = kernel_poll_quantum,
    polls: u64 = 0,
    max_frames: usize = 0,
    entry_base: usize,
    stack_base: usize,
    boundary_index: ?FrameIndex = null,
    pending: ?EclErr = null,
    last_error: ?Value = null,
    exit_status: ?u8 = null,
    idiom_hits: u64 = 0,
    scheduler: ?*const anyopaque = null,
    task_scope: ?*anyopaque = null,
    is_root_unit: bool = true,
    execution_scope: ?*env.Scope = null,
    native: NativeContinuation = .idle,
    /// The one state application this unit may own. `within` refuses to
    /// nest, so a single slot is exhaustive, and every parking, publication,
    /// and `without` authority question reduces to this field.
    state_application: ?*StateApplication = null,
    /// The unit's single right to hold a slot's turn. `within`, reload, and
    /// removal all spend it, so a second acquisition is not a guard anyone
    /// has to remember — there is nothing left to spend.
    turn_authority: modules.TurnAuthority = .available,
    current: ?Eval = null,
    active_index: u32 = 0,
    active_word: u32 = no_word,
    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        module_access: *const modules.ExecutionAccess,
        stack: std.ArrayList(Value),
        environment: *env.Env,
        archive: *spans.SpanArchive,
        output: ?*std.Io.Writer,
        arguments: Value,
        cancelled: *const std.atomic.Value(bool),
    ) Unit {
        return .{
            .allocator = allocator,
            .releases = releases,
            .module_access = module_access,
            .stack = stack,
            .environment = environment,
            .lifetime = .init(allocator, environment),
            .archive = archive,
            .output = output,
            .arguments = arguments,
            .cancelled = cancelled,
            .entry_base = stack.items.len,
            .stack_base = 0,
        };
    }

    /// Transfers the top operand out of the unit without interpreting stack
    /// boundaries. Scheduler teardown uses this after evaluation has stopped.
    pub fn takeStackOwned(self: *Unit) ?Value {
        return self.stack.pop();
    }

    pub fn replaceRootScope(self: *Unit, root: env.Scope) void {
        self.lifetime.replaceRoot(root);
    }

    fn rootScope(self: *Unit) *env.Scope {
        return self.lifetime.rootScope();
    }

    /// Replaces a stopped root unit's operands from a stable borrowed
    /// checkpoint. Capacity was reserved by the checkpoint source.
    pub fn restoreStackBorrowedAssumeCapacity(self: *Unit, checkpoint: []const Value) void {
        for (self.stack.items) |item| self.releases.releaseValue(item);
        self.stack.clearRetainingCapacity();
        std.debug.assert(self.stack.capacity >= checkpoint.len);
        var reservation = StackReservation.init(self, checkpoint.len);
        for (checkpoint) |item| reservation.pushBorrowed(item);
        std.debug.assert(reservation.complete());
    }
    pub fn takeStack(self: *Unit) std.ArrayList(Value) {
        const result = self.stack;
        self.stack = .empty;
        return result;
    }
    pub fn takeError(self: *Unit) ?Value {
        const result = self.last_error;
        self.last_error = null;
        return result;
    }
    pub fn hasParkRequest(self: *const Unit) bool {
        return self.native == .park_request or self.native == .task_join_request;
    }
    pub fn parkRequest(self: *const Unit) ?ParkRequest {
        return switch (self.native) {
            .park_request => |request| request,
            .task_join_request => |state| state.request,
            else => null,
        };
    }
    pub fn takeParkRequest(self: *Unit) ?ParkRequest {
        return switch (self.native) {
            .park_request => |request| result: {
                self.native = .idle;
                break :result request;
            },
            .task_join_request => |state| result: {
                self.native = .{ .task_join = state.join };
                break :result state.request;
            },
            else => null,
        };
    }
    fn installParkRequest(self: *Unit, request: ParkRequest) void {
        self.native = switch (self.native) {
            .idle => .{ .park_request = request },
            .task_join => |join| .{ .task_join_request = .{ .join = join, .request = request } },
            else => unreachable,
        };
    }
    pub fn installParkResume(self: *Unit, result: ParkResume) void {
        self.native = switch (self.native) {
            .idle => .{ .park_resume = result },
            .task_join => |join| .{ .task_join_resume = .{ .join = join, .result = result } },
            else => unreachable,
        };
    }
    const ParkDelivery = struct { result: ParkResume, task_join: bool };
    fn takeParkResume(self: *Unit) ?ParkDelivery {
        return switch (self.native) {
            .park_resume => |result| delivery: {
                self.native = .idle;
                break :delivery .{ .result = result, .task_join = false };
            },
            .task_join_resume => |state| delivery: {
                self.native = .{ .task_join = state.join };
                break :delivery .{ .result = state.result, .task_join = true };
            },
            else => null,
        };
    }
    fn taskJoin(self: *Unit) ?*TaskJoinState {
        return switch (self.native) {
            .task_join => |*join| join,
            else => null,
        };
    }
    fn installTaskJoin(self: *Unit, join: TaskJoinState) void {
        std.debug.assert(self.native == .idle);
        self.native = .{ .task_join = join };
    }
    fn takeTaskJoin(self: *Unit) ?TaskJoinState {
        return switch (self.native) {
            .task_join => |join| result: {
                self.native = .idle;
                break :result join;
            },
            else => null,
        };
    }
    pub fn hasTaskJoinWork(self: *const Unit) bool {
        return switch (self.native) {
            .task_join, .task_join_request, .task_join_resume, .task_join_cleanup, .work_join_cleanup => true,
            else => false,
        };
    }
    pub fn workDriver(self: *Unit) ?*WorkDriver {
        return switch (self.native) {
            .work => |*driver| driver,
            .work_join_cleanup => |*state| &state.driver,
            else => null,
        };
    }
    pub fn takeWorkDriver(self: *Unit) ?WorkDriver {
        return switch (self.native) {
            .work => |driver| result: {
                self.native = .idle;
                break :result driver;
            },
            .work_join_cleanup => |state| result: {
                self.native = .{ .task_join_cleanup = state.cleanup };
                break :result state.driver;
            },
            else => null,
        };
    }
    pub fn hasWorkDriver(self: *const Unit) bool {
        return self.native == .work or self.native == .work_join_cleanup;
    }
    fn installTaskJoinCleanup(self: *Unit, cleanup: TaskJoinCleanup) void {
        self.native = switch (self.native) {
            .idle => .{ .task_join_cleanup = cleanup },
            .work => |driver| .{ .work_join_cleanup = .{
                .driver = driver,
                .cleanup = cleanup,
            } },
            else => unreachable,
        };
    }
    fn advanceTaskJoinCleanup(self: *Unit, budget: usize) TaskJoinCleanupProgress {
        const cleanup = switch (self.native) {
            .task_join_cleanup => |*pending| pending,
            else => return .{ .complete = true, .consumed = 0 },
        };
        const progress = cleanup.advance(self.releases, budget);
        if (!progress.complete) return .{ .complete = false, .consumed = progress.consumed };
        const disposition = cleanup.disposition();
        self.native = .idle;
        return .{
            .complete = true,
            .consumed = progress.consumed,
            .disposition = disposition,
        };
    }
    /// Terminal cleanup consumes a deferred OOM instead of delivering it back
    /// into an evaluator that is already being abandoned.
    pub fn advanceAbandonedTaskJoinCleanup(self: *Unit, budget: usize) CleanupProgress {
        switch (self.native) {
            .task_join => |join| self.native = .{ .task_join_cleanup = .init(
                .init(join, null),
                .continue_evaluation,
            ) },
            .task_join_request => |state| {
                state.request.deinit(self.releases);
                self.native = .{ .task_join_cleanup = .init(
                    .init(state.join, null),
                    .continue_evaluation,
                ) };
            },
            .task_join_resume => |state| {
                state.result.deinit(self.releases);
                self.native = .{ .task_join_cleanup = .init(
                    .init(state.join, null),
                    .continue_evaluation,
                ) };
            },
            .work_join_cleanup => {},
            else => {},
        }
        const progress = self.advanceTaskJoinCleanup(budget);
        return .{ .complete = progress.complete, .consumed = progress.consumed };
    }

    /// Scheduler-owned teardown of all user-sized evaluator cargo. Each unit
    /// of budget retires at most one continuation, operand, native owner, or
    /// generation pin. Array storage is released by `deinit` after this cursor
    /// reports complete.
    pub fn advanceSchedulerTeardown(self: *Unit, budget: usize) CleanupProgress {
        std.debug.assert(budget != 0);
        var consumed: usize = 0;
        while (consumed != budget) {
            if (self.native == .work_join_cleanup) {
                const driver = self.takeWorkDriver().?;
                driver.deinit(self.releases, self.allocator);
                consumed += 1;
                continue;
            }
            if (self.hasTaskJoinWork()) {
                const progress = self.advanceAbandonedTaskJoinCleanup(budget - consumed);
                consumed += @max(progress.consumed, 1);
                if (!progress.complete) return .{ .complete = false, .consumed = consumed };
                continue;
            }
            switch (self.native) {
                .work => {
                    const driver = self.takeWorkDriver().?;
                    driver.deinit(self.releases, self.allocator);
                    consumed += 1;
                    continue;
                },
                .park_request => |request| {
                    self.native = .idle;
                    request.deinit(self.releases);
                    consumed += 1;
                    continue;
                },
                .park_resume => |result| {
                    self.native = .idle;
                    result.deinit(self.releases);
                    consumed += 1;
                    continue;
                },
                .yielded => {
                    self.native = .idle;
                    consumed += 1;
                    continue;
                },
                .idle => {},
                .task_join, .task_join_request, .task_join_resume, .task_join_cleanup, .work_join_cleanup => unreachable,
            }
            if (self.current) |current| {
                self.current = null;
                self.releases.releaseHeader(current.code);
                consumed += 1;
                continue;
            }
            if (self.frames.pop()) |frame| {
                frame.deinit(self.releases, self.allocator);
                consumed += 1;
                continue;
            }
            if (self.stack.pop()) |item| {
                self.releases.releaseValue(item);
                consumed += 1;
                continue;
            }
            if (self.pending) |*pending| {
                pending.retire(self.releases);
                self.pending = null;
                consumed += 1;
                continue;
            }
            if (self.last_error) |item| {
                self.releases.releaseValue(item);
                self.last_error = null;
                consumed += 1;
                continue;
            }
            if (!self.lifetime.advanceTeardown(self.releases, self.allocator)) {
                consumed += 1;
                continue;
            }
            self.boundary_index = null;
            self.stack_base = 0;
            return .{ .complete = true, .consumed = consumed };
        }
        return .{ .complete = false, .consumed = consumed };
    }
    pub fn inAttempt(self: *const Unit) bool {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = self.frames.items[@intFromEnum(frame_index)].boundary;
            if (boundary.mode == .attempt) return true;
            index = boundary.previous_boundary;
        }
        return false;
    }
    pub fn pinGeneration(self: *Unit, generation: *modules.ModuleHome) error{OutOfMemory}!void {
        try self.lifetime.pin(self.allocator, generation, self.module_access);
    }
    pub fn deinit(self: *Unit) void {
        if (self.current) |current| self.releases.releaseHeader(current.code);
        for (self.frames.items) |frame| frame.deinit(self.releases, self.allocator);
        self.frames.deinit(self.allocator);
        for (self.stack.items) |item| self.releases.releaseValue(item);
        self.stack.deinit(self.allocator);
        if (self.pending) |*pending| pending.retire(self.releases);
        if (self.last_error) |item| self.releases.releaseValue(item);
        switch (self.native) {
            .idle, .yielded => {},
            .work => |driver| driver.deinit(self.releases, self.allocator),
            .park_request => |request| request.deinit(self.releases),
            .park_resume => |result| result.deinit(self.releases),
            .task_join, .task_join_request, .task_join_resume, .task_join_cleanup, .work_join_cleanup => @panic("task join must be retired resumably before unit teardown"),
        }
        self.lifetime.deinit(self.releases, self.allocator);
        self.* = undefined;
    }
};
pub const Machine = struct {
    unit: *Unit,
    pub fn allocator(self: *const Machine) std.mem.Allocator {
        return self.unit.allocator;
    }
    pub fn releaseDomain(self: *const Machine) *heap.ReleaseDomain {
        return self.unit.releases;
    }
    pub fn beginNativeTiming(self: *const Machine) ?i128 {
        if (!self.unit.inherited.native_diagnostics) return null;
        const io = self.unit.inherited.host_io orelse return null;
        return std.Io.Clock.awake.now(io).nanoseconds;
    }

    fn settleAdvisoryDiagnostic(result: error{WriteFailed}!void) void {
        if (result) |_| {} else |err| switch (err) {
            error.WriteFailed => {},
        }
    }

    /// Native code cannot be preempted. This optional observation reports a
    /// long slice after it returns; it provides no sandboxing or instruction
    /// reduction, and the default path does not sample the clock at all.
    pub fn finishNativeTiming(
        self: *Machine,
        instance: *native_module.ModuleInstance,
        started: ?i128,
    ) void {
        const start = started orelse return;
        const io = self.unit.inherited.host_io orelse return;
        const end = std.Io.Clock.awake.now(io).nanoseconds;
        const elapsed: u64 = @intCast(@max(end - start, 0));
        if (!instance.recordDuration(elapsed)) return;
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "native module `{s}` returned after an over-quantum slice ({d} ns)\n",
            .{ intern.get(intern.moduleId(instance.name())), elapsed },
        ) catch return;
        if (self.unit.inherited.console) |console| {
            settleAdvisoryDiagnostic(console.writeDiagnostics(line, false));
        } else if (self.unit.inherited.diagnostics) |diagnostics| {
            settleAdvisoryDiagnostic(diagnostics.writeAll(line));
            settleAdvisoryDiagnostic(diagnostics.flush());
        }
    }
    pub fn currentEnv(self: *const Machine) *env.Env {
        return self.unit.environment;
    }
    pub fn currentScope(self: *const Machine) *env.Scope {
        return self.unit.current.?.scope;
    }
    pub fn currentHome(self: *const Machine) ?*modules.ModuleHome {
        return self.unit.current.?.home;
    }
    fn installDriver(self: *Machine, context: anytype) void {
        const Context = @TypeOf(context);
        const pointer = switch (@typeInfo(Context)) {
            .pointer => |info| info,
            else => @compileError("work driver context must be a pointer"),
        };
        if (pointer.size != .one) @compileError("work driver context must be a single-item pointer");
        const Driver = pointer.child;
        const adapters = WorkDriverAdapters(Driver);
        // A final application step may replace its scheduler-yield marker
        // with bounded native materialization; that driver supplies its own
        // scheduler slices, so the marker is consumed by this transition.
        const installed = WorkDriver{
            .context = @ptrCast(context),
            .resume_fn = adapters.advance,
            .deinit_fn = adapters.deinit,
            .site = if (self.unit.current) |current| .{
                .code = current.code,
                .index = self.unit.active_index,
            } else null,
        };
        self.unit.native = switch (self.unit.native) {
            .idle, .yielded => .{ .work = installed },
            .task_join_cleanup => |cleanup| .{ .work_join_cleanup = .{
                .driver = installed,
                .cleanup = cleanup,
            } },
            else => unreachable,
        };
    }
    /// Consumes a fully initialized, heap-allocated continuation whose type
    /// explicitly requires address-stable construction. Ordinary drivers use
    /// `startDriver`, which owns allocation failure as well as installation.
    pub fn adoptDriver(self: *Machine, context: anytype) void {
        const Driver = @typeInfo(@TypeOf(context)).pointer.child;
        if (!@hasDecl(Driver, "address_stable_driver"))
            @compileError("adoptDriver requires an address-stable driver declaration");
        _ = comptime heap.validateDriverOwnership(Driver);
        self.installDriver(context);
    }
    /// Allocate and install a continuation as one ownership transfer. Driver
    /// values accepted here opt into field-derived ownership, so allocation
    /// failure retires the still-uninstalled value without a bespoke cleanup
    /// path.
    pub fn startDriver(self: *Machine, initial: anytype) error{OutOfMemory}!void {
        const Driver = @TypeOf(initial);
        switch (comptime heap.validateDriverOwnership(Driver)) {
            .fields, .bounded_retirement => {},
            .self_owned => @compileError("self-owned drivers require address-stable construction"),
        }
        var pending = initial;
        const driver = self.unit.allocator.create(Driver) catch |err| {
            heap.deinitUninstalledDriver(self.unit.releases, self.unit.allocator, &pending);
            return err;
        };
        driver.* = pending;
        self.installDriver(driver);
    }
    /// Consumes the currently installed erased continuation without invoking
    /// its destructor. Self-replacing drivers use this before destroying their
    /// concrete state and installing the typed successor.
    pub fn detachWorkDriver(self: *Machine, context: anytype) void {
        const driver = self.unit.takeWorkDriver().?;
        std.debug.assert(driver.context == @as(*anyopaque, @ptrCast(context)));
    }
    /// Marks a preserved native continuation boundary as scheduler-visible.
    /// Application state already owns its next position, so no native stack
    /// survives the return.
    pub fn yieldNativeStep(self: *Machine) MachineError!void {
        try self.pollKernel();
        std.debug.assert(self.unit.native == .idle);
        self.unit.native = .yielded;
    }
    pub fn useOrLoad(self: *Machine, name: intern.ModuleName) MachineError!void {
        try self.startDriver(UseDriver.init(self, self.currentScope(), name, true));
    }
    fn autoLoadModule(self: *Machine, name: intern.ModuleName) MachineError!void {
        const registry = self.unit.inherited.registry orelse return self.undefinedModule(intern.moduleId(name));
        try self.startDriver(AutoLoadDriver{
            .name = name,
            .cursor = registry.beginLoadingCursor(name),
        });
    }
    const AutoLoadDriver = struct {
        const FileKind = enum { source, native };
        const FilenameTarget = enum { component_start, candidate };

        name: intern.ModuleName,
        cursor: modules.Registry.BeginLoadingCursor,
        loading: ?heap.Owned(modules.LoadingLease) = null,
        filename: ?heap.Owned([]u8) = null,
        filename_index: usize = 0,
        file_kind: FileKind = .source,
        filename_target: FilenameTarget = .component_start,
        search_index: usize = 0,
        component_start: usize = 0,
        component_end: usize = 0,
        candidate: ?heap.Owned([]u8) = null,
        candidate_index: usize = 0,
        separator: bool = false,
        path_materializer: ?heap.Owned(kernel_storage.Utf8Materializer) = null,
        path_value: ?heap.Owned(Value) = null,
        access_error: ?[]const u8 = null,
        phase: enum { begin, filename, component_start, component_end, candidate, access, path_value, transfer } = .begin,

        fn resetCandidate(self: *AutoLoadDriver, evaluator: *Machine) void {
            if (self.candidate) |*candidate| candidate.deinit(
                evaluator.releaseDomain(),
                evaluator.allocator(),
            );
            self.candidate = null;
            self.candidate_index = 0;
            self.separator = false;
            self.access_error = null;
        }
        fn beginFilename(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            kind: FileKind,
            target: FilenameTarget,
        ) error{OutOfMemory}!void {
            if (self.filename) |*filename| filename.deinit(
                evaluator.releaseDomain(),
                evaluator.allocator(),
            );
            self.filename = null;
            self.filename_index = 0;
            self.file_kind = kind;
            self.filename_target = target;
            const module_name = intern.get(intern.moduleId(self.name));
            const extension = switch (kind) {
                .source => ".ecl",
                .native => ".eclmod",
            };
            const length = std.math.add(usize, module_name.len, extension.len) catch
                return error.OutOfMemory;
            self.filename = .init(try evaluator.unit.allocator.alloc(u8, length));
            self.phase = .filename;
        }
        fn beginCandidate(self: *AutoLoadDriver, evaluator: *Machine) error{OutOfMemory}!void {
            const search = evaluator.unit.inherited.ecl_path.?;
            const directory = search[self.component_start..self.component_end];
            self.separator = directory.len != 0 and !std.fs.path.isSep(directory[directory.len - 1]);
            var length = std.math.add(usize, directory.len, self.filename.?.borrow().len) catch
                return error.OutOfMemory;
            if (self.separator) length = std.math.add(usize, length, 1) catch
                return error.OutOfMemory;
            self.candidate = .init(try evaluator.unit.allocator.alloc(u8, length));
            self.phase = .candidate;
        }
        pub fn advance(evaluator: *Machine, self: *AutoLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            var budget: usize = kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.phase) {
                .begin => switch (try self.cursor.advance()) {
                    .pending => {},
                    .complete => |maybe_loading| {
                        self.loading = .init(maybe_loading orelse return evaluator.failFmt(
                            .domain,
                            "recursive auto-load of module `{s}`",
                            .{intern.get(intern.moduleId(self.name))},
                        ));
                        if (evaluator.unit.inherited.host_io == null or evaluator.unit.inherited.ecl_path == null)
                            return evaluator.undefinedModule(intern.moduleId(self.name));
                        try self.beginFilename(evaluator, .source, .component_start);
                    },
                },
                .filename => {
                    const module_name = intern.get(intern.moduleId(self.name));
                    const extension = switch (self.file_kind) {
                        .source => ".ecl",
                        .native => ".eclmod",
                    };
                    if (self.filename_index != self.filename.?.borrow().len) {
                        self.filename.?.borrow()[self.filename_index] = if (self.filename_index < module_name.len)
                            module_name[self.filename_index]
                        else
                            extension[self.filename_index - module_name.len];
                        self.filename_index += 1;
                    } else switch (self.filename_target) {
                        .component_start => self.phase = .component_start,
                        .candidate => try self.beginCandidate(evaluator),
                    }
                },
                .component_start => {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    if (self.search_index == search.len) return evaluator.undefinedModule(intern.moduleId(self.name));
                    if (search[self.search_index] == std.fs.path.delimiter) {
                        self.search_index += 1;
                    } else {
                        self.component_start = self.search_index;
                        self.phase = .component_end;
                    }
                },
                .component_end => {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    if (self.search_index == search.len or
                        search[self.search_index] == std.fs.path.delimiter)
                    {
                        self.component_end = self.search_index;
                        if (self.search_index != search.len) self.search_index += 1;
                        try self.beginCandidate(evaluator);
                    } else self.search_index += 1;
                },
                .candidate => {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    const directory = search[self.component_start..self.component_end];
                    if (self.candidate_index != self.candidate.?.borrow().len) {
                        self.candidate.?.borrow()[self.candidate_index] = if (self.candidate_index < directory.len)
                            directory[self.candidate_index]
                        else if (self.separator and self.candidate_index == directory.len)
                            std.fs.path.sep
                        else
                            self.filename.?.borrow()[self.candidate_index - directory.len - @intFromBool(self.separator)];
                        self.candidate_index += 1;
                    } else self.phase = .access;
                },
                .access => {
                    std.Io.Dir.cwd().access(
                        evaluator.unit.inherited.host_io.?,
                        self.candidate.?.borrow(),
                        .{ .read = true },
                    ) catch |err| switch (err) {
                        error.FileNotFound => {
                            self.resetCandidate(evaluator);
                            if (self.file_kind == .source) {
                                try self.beginFilename(evaluator, .native, .candidate);
                            } else {
                                try self.beginFilename(evaluator, .source, .component_start);
                            }
                            continue;
                        },
                        else => self.access_error = @errorName(err),
                    };
                    self.path_materializer = .init(.init(
                        evaluator.unit.allocator,
                        self.candidate.?.borrow(),
                    ));
                    self.phase = .path_value;
                },
                .path_value => switch (self.path_materializer.?.borrowMut().advance(1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return evaluator.fail(.io, "module path is not valid UTF-8"),
                }) {
                    .pending => {},
                    .complete => |path_value| {
                        self.path_materializer.?.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        self.path_materializer = null;
                        self.path_value = .init(path_value);
                        if (self.access_error) |name| {
                            const failure = evaluator.failFmt(
                                .io,
                                "cannot access module file `{s}`: {s}",
                                .{ self.candidate.?.borrow(), name },
                            );
                            evaluator.unit.pending.?.addData(.path, path_value);
                            return failure;
                        }
                        self.phase = .transfer;
                    },
                },
                .transfer => {
                    if (self.file_kind == .native) return self.transferNative(evaluator);
                    const candidate = self.candidate.?.take();
                    const completion: SourceCompletion = .{ .use = .{
                        .name = self.name,
                        .loading = self.loading.?.borrowMut().move(),
                        .path = self.path_value.?.take(),
                    } };
                    self.candidate = null;
                    self.loading = null;
                    self.path_value = null;
                    evaluator.detachWorkDriver(self);
                    heap.destroyDriver(evaluator.releaseDomain(), evaluator.unit.allocator, self);
                    try evaluator.fileSourceOwned(candidate, null, completion);
                    return .detached;
                },
            };
            return .yielded;
        }
        fn transferNative(self: *AutoLoadDriver, evaluator: *Machine) MachineError!WorkProgress {
            const loader_authority = evaluator.unit.inherited.native_loader orelse
                return evaluator.fail(.io, "native module loader is unavailable");
            const start = try loader_authority.startDynamic(
                self.name,
                self.candidate.?.borrow(),
            );
            const loader = switch (start) {
                .failure => |failure| {
                    const failed = evaluator.fail(.io, failure.text());
                    evaluator.unit.pending.?.addData(.path, self.path_value.?.borrow());
                    return failed;
                },
                .loading => |loading| loading,
            };
            const next = NativeLoadDriver{
                .name = self.name,
                .loader = .init(loader),
                .loading = .init(self.loading.?.take()),
                .path = .init(self.path_value.?.take()),
            };
            evaluator.detachWorkDriver(self);
            heap.destroyDriver(evaluator.releaseDomain(), evaluator.unit.allocator, self);
            try evaluator.startDriver(next);
            return .detached;
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    const NativeLoadDriver = struct {
        name: intern.ModuleName,
        loader: heap.Owned(native_module.LoadCursor),
        loading: heap.Owned(modules.LoadingLease),
        path: heap.Owned(Value),
        instance: ?heap.Owned(*native_module.ModuleInstance) = null,
        publication: ?heap.Owned(modules.Registry.NativeCandidateCursor) = null,
        candidate: ?heap.Owned(modules.OwnedCandidate) = null,
        commit: ?heap.Owned(modules.Registry.CommitCursor) = null,
        phase: enum { validate, definitions, commit } = .validate,

        fn failLoad(self: *NativeLoadDriver, evaluator: *Machine, message: []const u8) MachineError {
            const failure = evaluator.fail(.io, message);
            evaluator.unit.pending.?.addData(.path, self.path.borrow());
            return failure;
        }

        pub fn advance(evaluator: *Machine, self: *NativeLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            switch (self.phase) {
                .validate => switch (try self.loader.borrowMut().advance(kernel_poll_quantum)) {
                    .pending => return .yielded,
                    .failure => |failure| return self.failLoad(evaluator, failure.text()),
                    .loaded => |instance| {
                        self.instance = .init(instance);
                        self.publication = .init(try .init(
                            evaluator.unit.inherited.registry.?,
                            instance,
                        ));
                        self.phase = .definitions;
                        return .yielded;
                    },
                },
                .definitions => switch (try self.publication.?.borrowMut().advance()) {
                    .pending => return .yielded,
                    .complete => |candidate| {
                        self.publication.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.publication = null;
                        self.candidate = .init(candidate);
                        self.commit = .init(evaluator.unit.inherited.registry.?.commitCursor(
                            self.candidate.?.borrowMut(),
                            &evaluator.unit.turn_authority,
                        ));
                        self.phase = .commit;
                        return .yielded;
                    },
                },
                .commit => switch (self.commit.?.borrowMut().advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return evaluator.failFmt(
                        .io,
                        "cannot publish native module `{s}`: {s}",
                        .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
                    ),
                }) {
                    .pending => return .yielded,
                    .complete => {
                        self.commit.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.commit = null;
                        var next = UseDriver.init(evaluator, evaluator.currentScope(), self.name, false);
                        next.after_load = .init(.{
                            .loading = self.loading.take(),
                            .path = self.path.take(),
                        });
                        evaluator.detachWorkDriver(self);
                        heap.destroyDriver(evaluator.releaseDomain(), evaluator.unit.allocator, self);
                        try evaluator.startDriver(next);
                        return .detached;
                    },
                },
            }
        }

        pub const ownership: heap.DriverOwnership = .fields;
    };
    const UseDriver = struct {
        const Phase = enum { canonical, acquire, exports, materialize, sort, check, render, write, move };
        const AfterLoad = struct {
            loading: modules.LoadingLease,
            path: Value,

            pub fn retire(self: *AfterLoad, releases: *heap.ReleaseDomain) void {
                self.loading.deinit();
                releases.releaseValue(self.path);
            }
        };
        allocator: std.mem.Allocator,
        scope: *env.Scope,
        name: intern.ModuleName,
        allow_load: bool,
        phase: Phase = .canonical,
        canonical: ?heap.Owned(modules.Registry.CanonicalCursor) = null,
        canonical_name: ?intern.ModuleName = null,
        acquisition: ?heap.Owned(modules.Registry.AcquireCursor) = null,
        generation: ?heap.Owned(modules.GenerationLease) = null,
        exports: ?heap.Owned(modules.ModuleGeneration.PublicNameCursor) = null,
        found: heap.Owned(poll_api.ChunkList(u32)),
        names: ?heap.Owned([]u32) = null,
        found_iterator: ?poll_api.ChunkList(u32).Iterator = null,
        materialize_index: usize = 0,
        sorter: ?heap.Owned(reflection.NameSortCursor) = null,
        check_index: usize = 0,
        check_lookup: ?heap.Owned(env.DirectLookupCursor) = null,
        actions: heap.Owned(reflection.ActionPlan),
        rendered: ?heap.Owned([]u8) = null,
        mover: ?heap.Owned(env.Environment.MoveUseCursor) = null,
        after_load: ?heap.Owned(AfterLoad) = null,

        fn init(
            evaluator: *Machine,
            scope: *env.Scope,
            name: intern.ModuleName,
            allow_load: bool,
        ) UseDriver {
            return .{
                .allocator = evaluator.unit.allocator,
                .scope = scope,
                .name = name,
                .allow_load = allow_load,
                .canonical = if (evaluator.unit.inherited.registry) |registry|
                    .init(registry.canonicalCursor(name))
                else
                    null,
                .found = .init(.init(evaluator.unit.allocator)),
                .actions = .init(.init(evaluator.unit.allocator)),
            };
        }
        fn diagnosticsAvailable(self: *UseDriver, evaluator: *Machine) bool {
            _ = self;
            return if (evaluator.unit.inherited.console) |console|
                console.diagnostics != null
            else
                evaluator.unit.inherited.diagnostics != null;
        }
        fn beginMove(self: *UseDriver) error{OutOfMemory}!void {
            self.mover = .init(try self.scope.moveUseCursor(self.canonical_name.?));
            self.phase = .move;
        }
        fn appendNotice(self: *UseDriver, module_name: intern.ModuleName, name: u32) error{OutOfMemory}!void {
            for ([_]reflection.Action{
                .{ .bytes = "session `" },
                .{ .name = name },
                .{ .bytes = "` shadows `" },
                .{ .name = intern.moduleId(module_name) },
                .{ .bytes = "." },
                .{ .name = name },
                .{ .bytes = "`\n" },
            }) |action| try self.actions.borrowMut().add(action);
        }
        fn missing(self: *UseDriver, evaluator: *Machine) MachineError!WorkProgress {
            const name = self.name;
            const allow_load = self.allow_load;
            const path = if (self.after_load) |*after_owner| retained: {
                const after = after_owner.borrow();
                heap.retainValue(after.path);
                break :retained after.path;
            } else null;
            defer if (path) |item| evaluator.releaseDomain().releaseValue(item);
            evaluator.detachWorkDriver(self);
            heap.destroyDriver(evaluator.releaseDomain(), evaluator.unit.allocator, self);
            if (allow_load) {
                try evaluator.autoLoadModule(name);
            } else {
                const failure = evaluator.undefinedModule(intern.moduleId(name));
                if (path) |item| evaluator.unit.pending.?.addData(.path, item);
                return failure;
            }
            return .detached;
        }
        pub fn advance(evaluator: *Machine, self: *UseDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            var budget: usize = kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.phase) {
                .canonical => {
                    const cursor = if (self.canonical) |*owned|
                        owned
                    else
                        return self.missing(evaluator);
                    switch (cursor.borrowMut().advance()) {
                        .pending => {},
                        .complete => |maybe_name| {
                            self.canonical_name = maybe_name orelse return self.missing(evaluator);
                            cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                            self.canonical = null;
                            if (self.scope.kind() == .session and self.diagnosticsAvailable(evaluator)) {
                                self.acquisition = .init(
                                    evaluator.unit.inherited.registry.?.acquireCursor(self.canonical_name.?),
                                );
                                self.phase = .acquire;
                            } else try self.beginMove();
                        },
                    }
                },
                .acquire => switch (self.acquisition.?.borrowMut().advance()) {
                    .pending => {},
                    .complete => |maybe_generation| {
                        self.acquisition.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.acquisition = null;
                        // Canonicalization and acquisition read two directory
                        // snapshots, so a removal can land between them: the
                        // name resolved a moment ago and is gone now, which
                        // is the ordinary undefined outcome, not a hole.
                        self.generation = .init(maybe_generation orelse return self.missing(evaluator));
                        self.exports = .init(self.generation.?.borrow().publicNameCursor());
                        self.phase = .exports;
                    },
                },
                .exports => switch (self.exports.?.borrowMut().advance()) {
                    .pending => {},
                    .item => |name| try self.found.borrowMut().append(name),
                    .complete => {
                        self.exports.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.exports = null;
                        self.names = .init(try self.allocator.alloc(u32, self.found.borrow().count));
                        self.found_iterator = self.found.borrow().iterator();
                        self.phase = .materialize;
                    },
                },
                .materialize => if (self.found_iterator.?.next()) |name| {
                    self.names.?.borrow()[self.materialize_index] = name.*;
                    self.materialize_index += 1;
                } else {
                    self.sorter = .init(try .init(self.allocator, self.names.?.borrow()));
                    self.phase = .sort;
                },
                .sort => if (self.sorter.?.borrowMut().advance(1) == .complete) {
                    self.sorter.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.sorter = null;
                    self.phase = .check;
                },
                .check => {
                    if (self.check_lookup) |*lookup| switch (lookup.borrowMut().advance()) {
                        .pending => continue,
                        .complete => |maybe_lease| {
                            lookup.deinit(evaluator.releaseDomain(), evaluator.allocator());
                            self.check_lookup = null;
                            if (maybe_lease) |loaded| {
                                var lease = loaded;
                                defer lease.deinit();
                                try self.appendNotice(
                                    self.generation.?.borrow().name(),
                                    self.names.?.borrow()[self.check_index],
                                );
                            }
                            self.check_index += 1;
                            continue;
                        },
                    };
                    if (self.check_index != self.names.?.borrow().len) {
                        self.check_lookup = .init(self.scope.environmentOrNull().?.directLookupCursor(
                            self.names.?.borrow()[self.check_index],
                        ));
                    } else if (self.actions.borrow().count() == 0) {
                        try self.beginMove();
                    } else {
                        self.actions.borrowMut().seal();
                        self.phase = .render;
                    }
                },
                .render => switch (try self.actions.borrowMut().advance(1)) {
                    .pending => {},
                    .complete => |bytes| {
                        self.rendered = .init(bytes);
                        self.phase = .write;
                    },
                },
                .write => {
                    if (evaluator.unit.inherited.console) |console| {
                        console.writeDiagnostics(self.rendered.?.borrow(), false) catch
                            return evaluator.fail(.io, "standard error write failed");
                        try self.beginMove();
                        return .yielded;
                    }
                    const output = evaluator.unit.inherited.diagnostics.?;
                    output.writeAll(self.rendered.?.borrow()) catch return evaluator.fail(.io, "standard error write failed");
                    output.flush() catch return evaluator.fail(.io, "standard error flush failed");
                    try self.beginMove();
                },
                .move => switch (self.mover.?.borrowMut().advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Frozen => return evaluator.fail(.domain, "registered module environments are immutable"),
                }) {
                    .pending => {},
                    .complete => {
                        if (self.after_load) |*after_owner| {
                            var after = after_owner.take();
                            after.loading.finish();
                            evaluator.releaseDomain().releaseValue(after.path);
                            self.after_load = null;
                        }
                        return .completed;
                    },
                },
            };
            return .yielded;
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    /// Consumes `source` on success and failure.
    pub fn parseSourceOwned(self: *Machine, source: []u8) MachineError!void {
        const source_name = self.unit.allocator.dupe(u8, "<parse>") catch |err| {
            self.unit.allocator.free(source);
            return err;
        };
        try self.startDriver(SourceDriver{
            .allocator = self.unit.allocator,
            .source_name = .init(source_name),
            .source = .init(source),
            .completion = .init(.push),
        });
    }
    const SourceCompletion = union(enum) {
        push,
        call,
        use: struct {
            name: intern.ModuleName,
            loading: ?modules.LoadingLease,
            path: ?Value,
        },

        pub fn deinit(self: *SourceCompletion, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .push, .call => {},
                .use => |*use| {
                    if (use.loading) |*loading| loading.deinit();
                    if (use.path) |path| releases.releaseValue(path);
                },
            }
            self.* = undefined;
        }
    };
    fn sourceOwned(
        self: *Machine,
        source_name: []u8,
        source: []u8,
        completion: SourceCompletion,
    ) error{OutOfMemory}!void {
        try self.startDriver(SourceDriver{
            .allocator = self.unit.allocator,
            .source_name = .init(source_name),
            .source = .init(source),
            .completion = .init(completion),
        });
    }
    const SourceDriver = struct {
        retirement: heap.ReleaseDomain.Retirement = .{},
        allocator: std.mem.Allocator,
        source_name: heap.Owned([]u8),
        source: heap.Owned([]u8),
        completion: heap.Owned(SourceCompletion),
        diag: reader.Diag = .{},
        reader_state: ?reader_cursor.ReadCursor = null,
        parsed: ?reader.Parsed = null,
        materializer: ?kernel_storage.GenericValueMaterializer = null,
        root: ?Value = null,
        root_header: ?*Header = null,
        absorber: ?spans.SpanArchive.AbsorbCursor = null,
        phase: enum { read, retire_reader, materialize, absorb, activate } = .read,
        parsed_retirement: ?reader.Parsed.RetireCursor = null,
        retirement_phase: enum { prepare, reader, parsed, storage } = .prepare,

        pub fn advance(evaluator: *Machine, self: *SourceDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            var budget: usize = kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.phase) {
                .read => {
                    if (self.reader_state == null) self.reader_state = reader_cursor.ReadCursor.init(
                        self.allocator,
                        evaluator.releaseDomain(),
                        self.source_name.borrow(),
                        self.source.borrow(),
                        &self.diag,
                    );
                    switch (self.reader_state.?.advance() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Parse => {
                            const failure = evaluator.fail(.parse, self.diag.text());
                            evaluator.unit.pending.?.setLocation(self.source_name.borrow(), self.diag.span);
                            return failure;
                        },
                    }) {
                        .pending => {},
                        .complete => |read_result| {
                            self.parsed = switch (read_result) {
                                .complete => |parsed| parsed,
                                .incomplete => |value_incomplete| {
                                    const failure = evaluator.fail(.parse, value_incomplete.message);
                                    evaluator.unit.pending.?.setLocation(self.source_name.borrow(), value_incomplete.span);
                                    return failure;
                                },
                            };
                            self.phase = .retire_reader;
                        },
                    }
                },
                .retire_reader => {
                    if (!self.reader_state.?.advanceRetirement()) continue;
                    self.reader_state = null;
                    self.materializer = .init(self.allocator, self.parsed.?.values());
                    self.phase = .materialize;
                },
                .materialize => switch (try self.materializer.?.advance(1)) {
                    .pending => {},
                    .complete => |root| {
                        self.materializer.?.deinit();
                        self.materializer = null;
                        self.root = root;
                        self.root_header = root.list;
                        self.absorber = evaluator.unit.archive.absorbCursor(&self.parsed.?, root);
                        self.phase = .absorb;
                    },
                },
                .absorb => switch (try self.absorber.?.advance()) {
                    .pending => {},
                    .complete => {
                        self.absorber.?.deinit();
                        self.absorber = null;
                        self.root = null;
                        self.phase = .activate;
                    },
                },
                .activate => {
                    switch (self.completion.borrowMut().*) {
                        .push => try evaluator.pushBorrowed(.{ .list = self.root_header.? }),
                        .call => {
                            heap.incRef(self.root_header.?);
                            try evaluator.callOwned(self.root_header.?);
                        },
                        .use => |*use| {
                            const scope = evaluator.unit.current.?.scope;
                            const home = evaluator.unit.current.?.home;
                            heap.incRef(self.root_header.?);
                            _ = evaluator.suspendCurrent() catch {
                                evaluator.releaseDomain().releaseHeader(self.root_header.?);
                                return error.OutOfMemory;
                            };
                            var continuation = OwnedFrame.init(.{ .use_after_load = .{
                                .loading = use.loading.?.move(),
                                .scope = scope,
                                .name = use.name,
                                .path = use.path.?,
                            } });
                            defer continuation.deinit(evaluator.releaseDomain(), self.allocator);
                            use.loading = null;
                            use.path = null;
                            evaluator.appendFrame(&continuation) catch {
                                evaluator.releaseDomain().releaseHeader(self.root_header.?);
                                return error.OutOfMemory;
                            };
                            evaluator.unit.current = .{
                                .code = self.root_header.?,
                                .ip = 0,
                                .scope = scope,
                                .home = home,
                                .traced_word = no_word,
                            };
                        },
                    }
                    return .completed;
                },
            };
            return .yielded;
        }
        pub fn advanceRetirement(
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
            self: *SourceDriver,
        ) bool {
            return switch (self.retirement_phase) {
                .prepare => result: {
                    if (self.absorber) |*absorber| absorber.deinit();
                    self.absorber = null;
                    if (self.materializer) |*materializer| materializer.retire(releases);
                    self.materializer = null;
                    if (self.root) |root| releases.releaseValue(root);
                    self.root = null;
                    self.completion.deinit(releases, storage_allocator);
                    self.retirement_phase = .reader;
                    break :result false;
                },
                .reader => if (self.reader_state) |*state| result: {
                    if (!state.advanceRetirement()) break :result false;
                    self.reader_state = null;
                    self.retirement_phase = .parsed;
                    break :result false;
                } else result: {
                    self.retirement_phase = .parsed;
                    break :result false;
                },
                .parsed => if (self.parsed) |*parsed| result: {
                    if (self.parsed_retirement == null)
                        self.parsed_retirement = .init(parsed);
                    if (!self.parsed_retirement.?.advance()) break :result false;
                    self.parsed_retirement = null;
                    self.parsed = null;
                    self.retirement_phase = .storage;
                    break :result false;
                } else result: {
                    self.retirement_phase = .storage;
                    break :result false;
                },
                .storage => {
                    self.source.deinit(releases, storage_allocator);
                    self.source_name.deinit(releases, storage_allocator);
                    storage_allocator.destroy(self);
                    return true;
                },
            };
        }
        pub const ownership: heap.DriverOwnership = .bounded_retirement;
    };
    pub fn loadFileOwned(self: *Machine, path: []u8, path_value: Value) MachineError!void {
        return self.fileSourceOwned(path, path_value, .call);
    }
    fn fileSourceOwned(
        self: *Machine,
        path: []u8,
        path_value: ?Value,
        completion: SourceCompletion,
    ) MachineError!void {
        if (self.unit.inherited.host_io == null) {
            const failure = self.fail(.io, "filesystem access is unavailable");
            if (path_value) |item| {
                self.unit.pending.?.addData(.path, item);
            } else switch (completion) {
                .use => |use| if (use.path) |item| self.unit.pending.?.addData(.path, item),
                .push, .call => {},
            }
            self.unit.allocator.free(path);
            if (path_value) |item| self.releaseDomain().releaseValue(item);
            var completion_cleanup = completion;
            completion_cleanup.deinit(self.releaseDomain());
            return failure;
        }
        try self.startDriver(FileSourceDriver{
            .allocator = self.unit.allocator,
            .path = .init(path),
            .path_value = if (path_value) |item| .init(item) else null,
            .completion = .init(completion),
        });
    }
    const OpenFile = struct {
        io: std.Io,
        file: std.Io.File,

        pub fn deinit(self: *OpenFile) void {
            self.file.close(self.io);
        }
    };
    const FileSourceDriver = struct {
        allocator: std.mem.Allocator,
        path: heap.Owned([]u8),
        path_value: ?heap.Owned(Value),
        completion: heap.Owned(SourceCompletion),
        open_file: ?heap.Owned(OpenFile) = null,
        file_reader: ?std.Io.File.Reader = null,
        source: ?heap.Owned([]u8) = null,
        offset: usize = 0,
        phase: enum { open, size, read, transfer } = .open,

        fn diagnosticPath(self: *FileSourceDriver) ?Value {
            if (self.path_value) |*item| return item.borrow();
            return switch (self.completion.borrow()) {
                .use => |use| use.path,
                .push, .call => null,
            };
        }
        fn failIo(self: *FileSourceDriver, evaluator: *Machine, message: []const u8) MachineError {
            const failure = evaluator.fail(.io, message);
            if (self.diagnosticPath()) |item| evaluator.unit.pending.?.addData(.path, item);
            return failure;
        }
        pub fn advance(evaluator: *Machine, self: *FileSourceDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            const io = evaluator.unit.inherited.host_io.?;
            switch (self.phase) {
                .open => {
                    const file = std.Io.Dir.cwd().openFile(io, self.path.borrow(), .{}) catch |err| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ self.path.borrow(), @errorName(err) },
                        );
                        if (self.diagnosticPath()) |item| evaluator.unit.pending.?.addData(.path, item);
                        return failure;
                    };
                    self.open_file = .init(.{ .io = io, .file = file });
                    self.phase = .size;
                    return .yielded;
                },
                .size => {
                    const opened = self.open_file.?.borrow();
                    const stat = opened.file.stat(opened.io) catch |err| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ self.path.borrow(), @errorName(err) },
                        );
                        if (self.diagnosticPath()) |item| evaluator.unit.pending.?.addData(.path, item);
                        return failure;
                    };
                    if (stat.size > std.math.maxInt(usize))
                        return self.failIo(evaluator, "source file is too large");
                    self.source = .init(try self.allocator.alloc(u8, @intCast(stat.size)));
                    self.file_reader = opened.file.reader(opened.io, &.{});
                    self.phase = .read;
                    return .yielded;
                },
                .read => {
                    if (self.offset != self.source.?.borrow().len) {
                        const end = @min(self.offset + kernel_poll_quantum, self.source.?.borrow().len);
                        const amount = self.file_reader.?.interface.readSliceShort(
                            self.source.?.borrow()[self.offset..end],
                        ) catch {
                            const name = if (self.file_reader.?.err) |err| @errorName(err) else "ReadFailed";
                            const failure = evaluator.failFmt(
                                .io,
                                "cannot read `{s}`: {s}",
                                .{ self.path.borrow(), name },
                            );
                            if (self.diagnosticPath()) |item| evaluator.unit.pending.?.addData(.path, item);
                            return failure;
                        };
                        if (amount == 0) return self.failIo(evaluator, "source file changed while being read");
                        self.offset += amount;
                        return .yielded;
                    }
                    self.file_reader = null;
                    self.open_file.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.open_file = null;
                    self.phase = .transfer;
                    return .yielded;
                },
                .transfer => {
                    const path = self.path.take();
                    const source = self.source.?.take();
                    const completion = self.completion.take();
                    self.source = null;
                    if (self.path_value) |*item| item.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    self.path_value = null;
                    evaluator.detachWorkDriver(self);
                    heap.destroyDriver(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                        self,
                    );
                    try evaluator.sourceOwned(path, source, completion);
                    return .detached;
                },
            }
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    pub fn undefinedModule(self: *Machine, name: u32) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined module `{s}`", .{intern.get(name)});
        self.unit.pending.?.addData(.name, .{ .symbol = name });
        return failure;
    }
    pub fn undefinedName(self: *Machine, name: u32) MachineError {
        self.unit.active_word = name;
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(name)});
        self.unit.pending.?.addData(.name, .{ .symbol = name });
        return failure;
    }
    pub fn available(self: *const Machine) usize {
        return self.unit.stack.items.len - self.unit.stack_base;
    }
    pub fn require(self: *Machine, count: usize) MachineError!void {
        if (self.available() >= count) return;
        const failure = self.failFmt(
            .underflow,
            "{s} needs {d} stack value{s}, but found {d}",
            .{
                self.activeWordName(),
                count,
                if (count == 1) "" else "s",
                self.available(),
            },
        );
        self.unit.pending.?.addData(.needed, .{ .int = @intCast(count) });
        self.unit.pending.?.addData(.available, .{ .int = @intCast(self.available()) });
        return failure;
    }
    pub fn popValue(self: *Machine) MachineError!heap.OwnedValue {
        try self.require(1);
        return .init(self.releaseDomain(), self.unit.takeStackOwned().?);
    }
    fn popChecked(
        self: *Machine,
        comptime expected: []const u8,
        comptime accepts: fn (Value) bool,
    ) MachineError!heap.OwnedValue {
        var item = try self.popValue();
        errdefer item.deinit();
        if (!accepts(item.borrow())) return self.typeError(expected);
        return item;
    }
    pub fn popList(self: *Machine) MachineError!heap.OwnedValue {
        return self.popChecked("a list", struct {
            fn accepts(item: Value) bool {
                return item == .list;
            }
        }.accepts);
    }
    pub fn popDict(self: *Machine) MachineError!heap.OwnedValue {
        return self.popChecked("a dict", struct {
            fn accepts(item: Value) bool {
                return item == .dict;
            }
        }.accepts);
    }
    pub fn popQuotation(self: *Machine) MachineError!heap.OwnedValue {
        return self.popChecked("a quotation/list", struct {
            fn accepts(item: Value) bool {
                return item == .list;
            }
        }.accepts);
    }
    pub fn popString(self: *Machine) MachineError!heap.OwnedValue {
        return self.popChecked("a string", struct {
            fn accepts(item: Value) bool {
                return item.isString();
            }
        }.accepts);
    }
    pub fn popSymbol(self: *Machine) MachineError!u32 {
        var item = try self.popValue();
        defer item.deinit();
        return switch (item.borrow()) {
            .symbol => |name| name,
            else => self.typeError("a symbol name"),
        };
    }
    pub fn discard(self: *Machine, count: usize) void {
        std.debug.assert(self.available() >= count);
        for (0..count) |_| self.releaseDomain().releaseValue(self.unit.takeStackOwned().?);
    }
    pub fn reserveStack(self: *Machine, count: usize) error{OutOfMemory}!StackReservation {
        try self.unit.stack.ensureUnusedCapacity(self.unit.allocator, count);
        return .init(self.unit, count);
    }
    pub fn reserveStackReplacement(
        self: *Machine,
        input_count: usize,
        output_count: usize,
    ) error{OutOfMemory}!StackReplacement {
        std.debug.assert(self.available() >= input_count);
        const base = self.unit.stack.items.len - input_count;
        try self.unit.stack.ensureTotalCapacity(self.unit.allocator, base + output_count);
        return .{
            .unit = self.unit,
            .base = base,
            .input_count = input_count,
            .output_count = output_count,
        };
    }
    pub fn nativeInputBorrowed(self: *const Machine, input_count: usize, index: usize) Value {
        std.debug.assert(index < input_count and self.available() >= input_count);
        return self.unit.stack.items[self.unit.stack.items.len - input_count + index];
    }
    /// Consumes `item`. The stack owns it on success; the release domain owns
    /// its constant-time retirement if stack growth fails.
    pub fn pushOwned(self: *Machine, item: Value) error{OutOfMemory}!void {
        self.unit.stack.append(self.unit.allocator, item) catch {
            self.unit.releases.releaseValue(item);
            return error.OutOfMemory;
        };
    }
    pub fn pushBorrowed(self: *Machine, item: Value) error{OutOfMemory}!void {
        heap.retainValue(item);
        return self.pushOwned(item);
    }
    pub fn activeWordId(self: *const Machine) u32 {
        return self.unit.active_word;
    }
    pub fn setActiveWord(self: *Machine, word: u32) void {
        self.unit.active_word = word;
    }
    pub fn setFailureSite(self: *Machine, code: *Header, index: u32) void {
        if (self.unit.pending) |*pending| pending.site = .{ .code = code, .index = index };
    }
    pub fn setWorkDriverSite(self: *Machine, code: *Header, index: u32) void {
        if (self.unit.workDriver()) |driver| driver.site = .{ .code = code, .index = index };
    }
    pub fn setWorkDriverTraceParent(self: *Machine, word: u32) void {
        if (self.unit.workDriver()) |driver| driver.trace_parent = word;
    }

    /// The single parking choke point. A parked unit would hold its slot's
    /// turn across an unbounded wait, so a state application refuses to park
    /// here — before any wait — rather than in each parking word, which is
    /// what makes the prohibition total as new parking words are added.
    pub fn park(self: *Machine, request: ParkRequest) MachineError!void {
        if (self.unit.state_application != null) {
            request.deinit(self.releaseDomain());
            return self.fail(.domain, "a within application cannot park");
        }
        self.unit.installParkRequest(request);
    }

    pub fn beginTaskJoinOwned(
        self: *Machine,
        tasks: Value,
    ) MachineError!void {
        std.debug.assert(tasks == .list);
        if (self.unit.state_application != null) {
            self.releaseDomain().releaseValue(tasks);
            return self.fail(.domain, "a within application cannot park");
        }
        std.debug.assert(self.unit.native == .idle);
        const ok_id = intern.intern("ok") catch {
            self.beginTaskJoinInputCleanup(tasks, .out_of_memory);
            return;
        };
        const err_id = intern.intern("err") catch {
            self.beginTaskJoinInputCleanup(tasks, .out_of_memory);
            return;
        };
        const count: usize = @intCast(tasks.list.length());
        const results = heap.OwnedValueBuffer.init(self.unit.releases, count) catch {
            self.beginTaskJoinInputCleanup(tasks, .out_of_memory);
            return;
        };
        const started = task_join_core.start(@intCast(count));
        self.unit.installTaskJoin(.{
            .tasks = tasks,
            .results = results,
            .policy = started.next,
            .ok_id = ok_id,
            .err_id = err_id,
        });
        switch (started.command.next) {
            .request => |index| requestTaskJoin(self, index, null),
            .finish => try finishTaskJoin(self),
        }
    }
    fn beginTaskJoinInputCleanup(
        self: *Machine,
        tasks: Value,
        disposition: TaskJoinCleanupDisposition,
    ) void {
        std.debug.assert(self.unit.native == .idle);
        self.unit.installTaskJoinCleanup(.init(.inputOnly(tasks), disposition));
    }
    pub fn commitDirectIdiomTrace(self: *Machine) u32 {
        const parent = self.unit.active_word;
        if (self.unit.current.?.ip >= self.unit.current.?.code.length()) self.unit.current.?.traced_word = no_word;
        return parent;
    }
    pub fn setFailureTraceParent(self: *Machine, word: u32) void {
        if (self.unit.pending) |*pending| pending.trace_parent = word;
    }
    pub fn takePrimitiveFailure(self: *Machine) ?EclErr {
        const failure = self.unit.pending;
        self.unit.pending = null;
        return failure;
    }
    fn installPrimitiveFailure(self: *Machine, failure_value: EclErr) MachineError {
        std.debug.assert(self.unit.pending == null);
        self.unit.pending = failure_value;
        if (self.unit.pending.?.word == null and self.unit.active_word != no_word) {
            self.unit.pending.?.word = self.unit.active_word;
        }
        return error.Ecl;
    }
    pub fn continueWithIdiom(self: *Machine, request: IdiomRequest, fallback: IdiomFallback) MachineError!void {
        if (self.unit.inherited.phrase_recognizer) |recognize| return recognize(self, request, fallback);
        defer fallback.deinit(self.releaseDomain(), self.unit.allocator);
        return fallback.run(self);
    }
    pub fn activeWordName(self: *const Machine) []const u8 {
        return if (self.unit.active_word == no_word) "evaluation" else intern.get(self.unit.active_word);
    }
    pub fn fail(self: *Machine, kind: ErrorKind, message: []const u8) MachineError {
        std.debug.assert(self.unit.pending == null);
        self.unit.pending = EclErr.init(kind, message);
        if (self.unit.active_word != no_word) self.unit.pending.?.word = self.unit.active_word;
        return error.Ecl;
    }
    pub fn failFmt(
        self: *Machine,
        kind: ErrorKind,
        comptime format: []const u8,
        args: anytype,
    ) MachineError {
        std.debug.assert(self.unit.pending == null);
        self.unit.pending = EclErr.initFmt(kind, format, args);
        if (self.unit.active_word != no_word) self.unit.pending.?.word = self.unit.active_word;
        return error.Ecl;
    }
    pub fn typeError(self: *Machine, expected: []const u8) MachineError {
        return self.failFmt(
            .type,
            "{s} expected {s}",
            .{ self.activeWordName(), expected },
        );
    }
    /// Raises a language error at a zero-based logical data index. Kernels
    /// call this only after locating the first failing element.
    pub fn failAtIndex(
        self: *Machine,
        kind: ErrorKind,
        message: []const u8,
        index: usize,
    ) MachineError {
        const failure = self.fail(kind, message);
        self.unit.pending.?.addData(.index, .{ .int = @intCast(index) });
        return failure;
    }
    /// Reports the two leading-axis lengths that failed to conform.
    pub fn conformError(self: *Machine, left: usize, right: usize) MachineError {
        const failure = self.failFmt(
            .conform,
            "{s} cannot conform leading axes {d} and {d}",
            .{ self.activeWordName(), left, right },
        );
        self.unit.pending.?.addData(.left, .{ .int = @intCast(left) });
        self.unit.pending.?.addData(.right, .{ .int = @intCast(right) });
        return failure;
    }
    pub fn applicationContractError(
        self: *Machine,
        expected: Value,
        seeded: usize,
        observed: usize,
        index: ?usize,
    ) MachineError {
        const failure = if (index) |element_index|
            self.failFmt(
                .contract,
                "{s} quotation at element {d} violated its stack effect; seeded {d}, observed {d}",
                .{ self.activeWordName(), element_index, seeded, observed },
            )
        else
            self.failFmt(
                .contract,
                "{s} quotation violated its stack effect; seeded {d}, observed {d}",
                .{ self.activeWordName(), seeded, observed },
            );
        self.unit.pending.?.addData(.expected, expected);
        self.unit.pending.?.addData(.seeded, .{ .int = @intCast(seeded) });
        self.unit.pending.?.addData(.observed, .{ .int = @intCast(observed) });
        if (index) |element_index| {
            self.unit.pending.?.addData(.index, .{ .int = @intCast(element_index) });
        }
        return failure;
    }
    /// Kernel safe point. A flat loop calls this between bounded chunks;
    /// kernels never create threads or make scheduling decisions themselves.
    pub fn pollKernel(self: *Machine) MachineError!void {
        self.unit.polls += 1;
        if (self.unit.cancelled.load(.acquire)) {
            return self.fail(.cancelled, "unit cancelled");
        }
    }
    /// Charges logical kernel work against one unit-wide budget. Keeping the
    /// remainder on Unit means ragged recursion and consecutive short loops
    /// cannot evade the 65,536-element cancellation bound by resetting a
    /// local index. Calls are bounded to one quantum; a block that reaches
    /// the boundary polls before executing and is charged to the fresh
    /// interval in full.
    pub fn advanceKernel(self: *Machine, amount: usize) MachineError!void {
        _ = try self.chargeKernel(amount);
    }
    fn chargeKernel(self: *Machine, amount: usize) MachineError!bool {
        std.debug.assert(amount <= kernel_poll_quantum);
        if (amount == 0) return false;
        var reached_boundary = false;
        if (amount >= self.unit.kernel_fuel) {
            try self.pollKernel();
            self.unit.kernel_fuel = kernel_poll_quantum;
            reached_boundary = true;
        }
        self.unit.kernel_fuel -= @intCast(amount);
        return reached_boundary;
    }
    /// Consumes a quotation header and applies it inline.
    pub fn callOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        const scope = self.unit.current.?.scope;
        const home = self.unit.current.?.home;
        const inherited_trace = self.suspendCurrent() catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.unit.current = .{
            .code = quotation,
            .ip = 0,
            .scope = scope,
            .home = home,
            .traced_word = inherited_trace,
        };
    }
    /// Starts one quotation application behind a base-index stack barrier.
    /// `application.context` is consumed on every path. Its callback either
    /// returns null (finished) or transfers that same ownership into the next
    /// application.
    pub fn beginIsolatedApplication(
        self: *Machine,
        application: IsolatedApplication,
    ) MachineError!void {
        return self.beginApplication(application, .isolated, null);
    }
    /// The inline counterpart keeps the current stack and scope visible with the same bounded,
    /// defunctionalized continuation representation.
    pub fn beginInlineApplication(
        self: *Machine,
        application: IsolatedApplication,
    ) MachineError!void {
        return self.beginApplication(application, .in_place, null);
    }
    const ApplicationLaunch = enum { in_place, isolated };
    fn beginApplication(
        self: *Machine,
        application: IsolatedApplication,
        launch: ApplicationLaunch,
        inherited: ?u32,
    ) MachineError!void {
        self.require(application.seeded) catch |err| {
            application.deinit_fn(self.releaseDomain(), self.unit.allocator, application.context);
            return err;
        };
        const base = StackWindow.init(self.unit.stack.items.len, application.seeded) orelse unreachable;
        var child: ?*env.Scope = null;
        if (launch == .isolated) {
            child = env.Scope.createLazy(self.unit.allocator, application.parent_scope) catch {
                application.deinit_fn(self.releaseDomain(), self.unit.allocator, application.context);
                return error.OutOfMemory;
            };
        }
        var inherited_trace = inherited orelse no_word;
        if (self.unit.current != null) {
            std.debug.assert(inherited == null);
            inherited_trace = self.suspendCurrent() catch {
                if (child) |scope| {
                    scope.retire();
                }
                application.deinit_fn(self.releaseDomain(), self.unit.allocator, application.context);
                return error.OutOfMemory;
            };
        }
        var continuation = OwnedFrame.init(.{ .application = .{
            .context = application.context,
            .resume_fn = application.resume_fn,
            .deinit_fn = application.deinit_fn,
            .parent_scope = application.parent_scope,
            .home = application.home,
            .mode = switch (launch) {
                .in_place => .{ .in_place = base },
                .isolated => .{ .isolated = .{
                    .child = child.?,
                    .previous_base = @enumFromInt(@as(u32, @intCast(self.unit.stack_base))),
                } },
            },
            .traced_word = inherited_trace,
        } });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        try self.appendFrame(&continuation);
        if (launch == .isolated) self.unit.stack_base = base.base();
        heap.incRef(application.quotation);
        self.unit.current = .{
            .code = application.quotation,
            .ip = 0,
            .scope = child orelse application.parent_scope,
            .home = application.home,
            .traced_word = inherited_trace,
        };
    }
    pub fn attemptOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        return self.beginAttemptOwned(quotation);
    }
    pub fn moduleOwned(
        self: *Machine,
        name: intern.ModuleName,
        quotation: *Header,
    ) MachineError!void {
        const registry = self.unit.inherited.registry orelse {
            self.releaseDomain().releaseHeader(quotation);
            return self.fail(.domain, "module registry is unavailable");
        };
        const word = self.unit.active_word;
        var candidate = registry.createCandidate(name) catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        errdefer candidate.deinit();
        const home = candidate.executionHome(self.unit.module_access);
        const generation_scope = candidate.executionScope(self.unit.module_access);
        _ = self.suspendCurrent() catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= max_frame_count) {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        }
        const index: FrameIndex = @enumFromInt(@as(u32, @intCast(self.unit.frames.items.len)));
        var continuation = OwnedFrame.init(.{ .boundary = .{
            .mode = .{ .module = candidate.move() },
            .stack_base = @intCast(self.unit.stack.items.len),
            .previous_base = @intCast(self.unit.stack_base),
            .previous_boundary = self.unit.boundary_index,
            .word = word,
        } });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        self.appendFrame(&continuation) catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.unit.boundary_index = index;
        self.unit.stack_base = self.unit.stack.items.len;
        self.unit.current = .{
            .code = quotation,
            .ip = 0,
            .scope = generation_scope,
            .home = home,
            .traced_word = no_word,
        };
    }
    pub fn executeWord(self: *Machine, word: u32) MachineError!void {
        self.unit.active_word = word;
        try self.startDriver(DispatchDriver{ .resolution = .init(.init(self, word)) });
    }
    /// Opens one state application against the invoking word's home slot.
    /// Authority comes from the definition-site home, never from a value, so
    /// extracting the body and redefining it elsewhere loses it. Every
    /// prohibited shape — no home, an uncommitted registration root, and any
    /// nesting including a second module's slot — is rejected here, before a
    /// turn is requested and therefore before any wait.
    pub fn beginWithin(self: *Machine, quotation: *Header) MachineError!void {
        // Safety here is the unit's turn authority, which `request` below
        // spends and cannot spend twice. This branch only chooses the more
        // specific message for the two shapes a reader will recognize.
        if (self.unit.state_application) |active| {
            self.releaseDomain().releaseHeader(quotation);
            const home = self.currentHome();
            const same = if (home) |resolved|
                active.turn.sameSlot(resolved, self.unit.module_access)
            else
                false;
            return self.fail(.domain, if (same)
                "within cannot nest inside another within application"
            else
                "within cannot open a second module's state application");
        }
        const home = self.currentHome() orelse {
            self.releaseDomain().releaseHeader(quotation);
            return self.fail(.domain, "within is legal only in code homed in a module");
        };
        var slot_lifetime = modules.retainHomeSlot(home, self.unit.module_access) orelse {
            self.releaseDomain().releaseHeader(quotation);
            return self.fail(.domain, "within is legal only in a published module word");
        };
        if (!modules.homeIsCurrent(home, self.unit.module_access)) {
            slot_lifetime.deinit();
            self.releaseDomain().releaseHeader(quotation);
            return self.fail(.domain, "a replaced module generation cannot publish state");
        }
        const application = self.unit.allocator.create(StateApplication) catch {
            slot_lifetime.deinit();
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        application.* = .{
            .unit = self.unit,
            .turn = .init(slot_lifetime, &self.unit.turn_authority),
        };
        application.turn.request() catch |err| {
            application.turn.release();
            self.unit.allocator.destroy(application);
            self.releaseDomain().releaseHeader(quotation);
            return switch (err) {
                // The unit's turn authority is already spent — by a nested
                // application, a draft on another module, or a reload or
                // removal still holding its barrier.
                error.StateApplicationActive => self.fail(
                    .domain,
                    "within cannot open a second module state application",
                ),
                error.ModuleRemoved => self.fail(
                    .domain,
                    "a removed module cannot publish state",
                ),
            };
        };
        // Both owned fields are disposed if installation fails, so neither
        // the queued turn nor the quotation outlives this call.
        return self.startDriver(StateAcquireDriver{
            .application = .init(.init(application)),
            .quotation = .init(quotation),
        });
    }

    /// Moves the draft's top value onto the pending output sequence. Nothing
    /// reaches the caller until publication, so a failure after this point
    /// still delivers nothing.
    pub fn moveWithout(self: *Machine) MachineError!void {
        const application = self.unit.state_application orelse return self.fail(
            .domain,
            "without is legal only inside a within application",
        );
        try self.require(1);
        var item = heap.OwnedValue.init(self.releaseDomain(), self.unit.takeStackOwned().?);
        errdefer item.deinit();
        try application.outputs.append(self.unit.allocator, item.borrow());
        _ = item.take();
    }

    /// Consumes both `application` and `quotation`: the caller has already
    /// dropped its own reference, so every exit here retires them exactly
    /// once — the boundary frame owns the application once it is appended,
    /// and the earlier failures retire it directly.
    fn enterStateApplication(
        self: *Machine,
        owned_application: OwnedApplication,
        quotation: *Header,
    ) MachineError!void {
        var owned = owned_application;
        const application = owned.borrow();
        const word = self.unit.active_word;
        const home = self.currentHome().?;
        const scope = home.scope(self.unit.module_access);
        _ = self.suspendCurrent() catch {
            self.releaseDomain().releaseHeader(quotation);
            owned.retire(self.releaseDomain(), self.unit.allocator);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= max_frame_count) {
            self.releaseDomain().releaseHeader(quotation);
            owned.retire(self.releaseDomain(), self.unit.allocator);
            return error.OutOfMemory;
        }
        const index: FrameIndex = @enumFromInt(@as(u32, @intCast(self.unit.frames.items.len)));
        var continuation = OwnedFrame.init(.{ .boundary = .{
            .mode = .{ .state = owned.move() },
            .stack_base = application.draft_base,
            .previous_base = @intCast(self.unit.stack_base),
            .previous_boundary = self.unit.boundary_index,
            .word = word,
        } });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        self.appendFrame(&continuation) catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.unit.boundary_index = index;
        self.unit.stack_base = application.draft_base;
        self.unit.state_application = application;
        self.unit.current = .{
            .code = quotation,
            .ip = 0,
            .scope = scope,
            .home = home,
            .traced_word = no_word,
        };
    }

    pub fn raiseOwned(self: *Machine, raised: Value) MachineError {
        std.debug.assert(self.unit.pending == null);
        self.unit.pending = EclErr.init(.user, "raised error");
        if (self.unit.active_word != no_word) self.unit.pending.?.word = self.unit.active_word;
        self.unit.pending.?.raised = raised;
        return error.Ecl;
    }
    fn beginAttemptOwned(
        self: *Machine,
        quotation: *Header,
    ) error{OutOfMemory}!void {
        const parent_scope = self.unit.current.?.scope;
        const home = self.unit.current.?.home;
        const word = self.unit.active_word;
        const child = env.Scope.createLazy(self.unit.allocator, parent_scope) catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        _ = self.suspendCurrent() catch {
            child.retire();
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= max_frame_count) {
            child.retire();
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        }
        const index: FrameIndex = @enumFromInt(@as(u32, @intCast(self.unit.frames.items.len)));
        var continuation = OwnedFrame.init(.{ .boundary = .{
            .mode = .{ .attempt = child },
            .stack_base = @intCast(self.unit.stack.items.len),
            .previous_base = @intCast(self.unit.stack_base),
            .previous_boundary = self.unit.boundary_index,
            .word = word,
        } });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        self.appendFrame(&continuation) catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.unit.boundary_index = index;
        self.unit.stack_base = self.unit.stack.items.len;
        self.unit.current = .{
            .code = quotation,
            .ip = 0,
            .scope = child,
            .home = home,
            .traced_word = no_word,
        };
    }
    fn appendFrame(self: *Machine, owned: *OwnedFrame) error{OutOfMemory}!void {
        try self.unit.frames.append(self.unit.allocator, owned.frame.?);
        _ = owned.take();
        self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
    }
    /// Suspends a non-tail continuation. An exhausted anonymous quotation
    /// inherits its named trace owner so inline control does not erase the
    /// activation that selected it.
    fn suspendCurrent(self: *Machine) error{OutOfMemory}!u32 {
        const current = self.unit.current.?;
        const inherited_trace = if (current.ip >= current.code.length())
            current.traced_word
        else
            no_word;
        if (current.ip < current.code.length()) {
            try self.unit.frames.append(self.unit.allocator, .{ .eval = current });
            self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
        } else {
            self.releaseDomain().releaseHeader(current.code);
        }
        self.unit.current = null;
        return inherited_trace;
    }
};

pub const RunStatus = enum { completed, yielded, parked };

pub const InitialStack = union(enum) {
    empty,
    /// The caller keeps its reference through initialization; the Unit
    /// retains an independent stack-owned reference before returning.
    borrowed_seed: Value,
};

pub fn initialize(unit: *Unit, code: *Header, initial_stack: InitialStack) error{OutOfMemory}!void {
    std.debug.assert(unit.frames.items.len == 0);
    std.debug.assert(unit.pending == null and unit.last_error == null);
    std.debug.assert(unit.current == null);
    switch (initial_stack) {
        .empty => {},
        .borrowed_seed => |seed| {
            try unit.stack.append(unit.allocator, seed);
            heap.retainValue(seed);
        },
    }
    heap.incRef(code);
    unit.current = .{
        .code = code,
        .ip = 0,
        .scope = unit.execution_scope orelse unit.rootScope(),
        .home = null,
        .traced_word = no_word,
    };
}

pub fn runSlice(unit: *Unit) MachineError!RunStatus {
    var evaluator = Machine{ .unit = unit };
    return loop(&evaluator) catch |err| switch (err) {
        error.Ecl => return error.Ecl,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Makes the next evaluator entry observe cancellation before executing a
/// ready unit's first form.
pub fn armCancellationBeforeDispatch(unit: *Unit) void {
    unit.fuel = 0;
}

pub fn run(unit: *Unit, code: *Header) MachineError!void {
    try initialize(unit, code, .empty);
    while (true) {
        const status = try runSlice(unit);
        _ = unit.releases.advance(kernel_poll_quantum);
        switch (status) {
            .completed => return,
            .yielded => {},
            .parked => unreachable,
        }
    }
}

fn loop(self: *Machine) MachineError!RunStatus {
    while (true) {
        if (self.unit.native == .task_join_cleanup) {
            const cleanup = self.unit.advanceTaskJoinCleanup(kernel_poll_quantum);
            if (!cleanup.complete) return .yielded;
            if (cleanup.disposition.? == .out_of_memory) return error.OutOfMemory;
            continue;
        }
        if (self.unit.native == .park_resume or self.unit.native == .task_join_resume) {
            resumePark(self) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    try startFailure(self);
                    continue;
                },
            };
        }
        if (self.unit.hasParkRequest()) return .parked;
        if (self.unit.workDriver()) |driver_ptr| {
            const driver = driver_ptr.*;
            const progress = driver.advance(self) catch |err| {
                if (err == error.Ecl and self.unit.pending.?.site == null) {
                    self.unit.pending.?.site = driver.site;
                }
                if (err == error.Ecl and self.unit.pending.?.trace_parent == null) {
                    self.unit.pending.?.trace_parent = driver.trace_parent;
                }
                clearWorkDriver(self.unit);
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Ecl => {
                        try startFailure(self);
                        continue;
                    },
                }
            };
            switch (progress) {
                .yielded => return .yielded,
                .completed => {
                    clearWorkDriver(self.unit);
                    continue;
                },
                .output => |item| {
                    clearWorkDriver(self.unit);
                    try self.pushOwned(item);
                    continue;
                },
                // The driver destroyed and detached itself before invoking a
                // continuation which may have installed its successor.
                .detached => continue,
                .failed => {
                    clearWorkDriver(self.unit);
                    if (self.unit.native == .task_join_cleanup) {
                        const cleanup = self.unit.advanceTaskJoinCleanup(kernel_poll_quantum);
                        std.debug.assert(cleanup.complete);
                        std.debug.assert(cleanup.disposition.? == .continue_evaluation);
                    }
                    return error.Ecl;
                },
            }
        }
        if (self.unit.exit_status != null) {
            return .completed;
        }
        if (self.unit.current == null) {
            const resumed = resumeFrames(self) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    try startFailure(self);
                    continue;
                },
            };
            if (!resumed) return .completed;
            // A frame continuation may replace its native-stack tail with an
            // owned driver. Let that driver run before dispatching the parent
            // Eval which resumeFrames may also have restored.
            if (self.unit.hasWorkDriver()) continue;
            if (self.unit.native == .yielded) {
                self.unit.native = .idle;
                return .yielded;
            }
        }
        const current = &self.unit.current.?;
        if (current.ip >= current.code.length()) {
            self.releaseDomain().releaseHeader(current.code);
            self.unit.current = null;
            continue;
        }
        if (self.unit.fuel == 0) {
            self.unit.polls += 1;
            self.unit.fuel = fuel_quantum;
            if (self.unit.cancelled.load(.acquire)) {
                self.unit.active_word = no_word;
                self.unit.pending = EclErr.init(.cancelled, "unit cancelled");
                try startFailure(self);
                continue;
            }
            return .yielded;
        }
        poll(self) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                try startFailure(self);
                continue;
            },
        };
        self.unit.active_index = current.ip;
        const form = list.atUnchecked(.{ .list = current.code }, current.ip);
        current.ip += 1;
        dispatch(self, form) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                if (self.unit.pending.?.site == null and self.unit.current != null) {
                    self.unit.pending.?.site = .{
                        .code = self.unit.current.?.code,
                        .index = self.unit.active_index,
                    };
                }
                try startFailure(self);
                continue;
            },
        };
    }
}

fn clearWorkDriver(unit: *Unit) void {
    const driver = unit.takeWorkDriver() orelse return;
    driver.deinit(unit.releases, unit.allocator);
}

fn resumePark(self: *Machine) MachineError!void {
    const delivery = self.unit.takeParkResume().?;
    const park_result = delivery.result;
    switch (park_result) {
        .outcome => |outcome| if (delivery.task_join)
            try resumeTaskJoin(self, outcome)
        else
            try self.pushOwned(outcome),
        .indexed => |indexed| {
            var window = self.reserveStack(2) catch {
                self.unit.releases.releaseValue(indexed.outcome);
                return error.OutOfMemory;
            };
            window.pushOwned(.{ .int = indexed.index });
            window.pushOwned(indexed.outcome);
        },
        .timeout => {
            var timeout = EclErr.init(.timeout, "task wait timed out");
            defer timeout.retire(self.releaseDomain());
            const failure = try errorValue(
                self.unit.allocator,
                self.releaseDomain(),
                &timeout,
                &.{},
                null,
            );
            try self.pushOwned(try outcomeDict(
                self.unit.allocator,
                self.releaseDomain(),
                "err",
                failure,
            ));
        },
        .cancelled => {
            abandonTaskJoin(self);
            return self.fail(.cancelled, "unit cancelled while awaiting a task");
        },
        .io => {
            abandonTaskJoin(self);
            return self.fail(.io, "could not start the scheduler timer thread");
        },
        .out_of_memory => if (delivery.task_join)
            try resumeTaskJoinOutOfMemory(self)
        else
            return error.OutOfMemory,
        .scope_closed => |status| self.unit.exit_status = status,
    }
}

fn resumeTaskJoin(self: *Machine, outcome: Value) MachineError!void {
    defer self.releaseDomain().releaseValue(outcome);
    const join = self.unit.taskJoin().?;
    const key = dict.keyAt(outcome.dict, 0);
    const payload = dict.valueAt(outcome.dict, 0);
    if (key.symbol == join.err_id) return advanceTaskJoin(self, .raised, payload);
    std.debug.assert(key.symbol == join.ok_id);
    if (payload != .list or payload.list.length() != 1)
        return advanceTaskJoin(self, .contract, null);
    return advanceTaskJoin(self, .success, list.atUnchecked(payload, 0));
}

fn resumeTaskJoinOutOfMemory(self: *Machine) MachineError!void {
    return advanceTaskJoin(self, .out_of_memory, null);
}

fn advanceTaskJoin(
    self: *Machine,
    event: task_join_core.Event,
    payload: ?Value,
) MachineError!void {
    const join = self.unit.taskJoin().?;
    const decision = task_join_core.decide(join.policy, event) catch
        @panic("invalid task join transition");
    join.policy = decision.next;
    if (decision.command.store_result) |result_index| {
        const result = payload.?;
        std.debug.assert(result_index == join.results.len());
        join.results.appendBorrowed(result);
    }
    if (decision.command.record_failure) |failure| switch (failure) {
        .raised => {
            const raised = payload.?;
            heap.retainValue(raised);
            join.raised = raised;
        },
        .contract, .out_of_memory => {},
    };
    switch (decision.command.next) {
        .request => |index| requestTaskJoin(self, index, decision.command.cancel_from),
        .finish => try finishTaskJoin(self),
    }
}

fn requestTaskJoin(self: *Machine, index: u32, cancel_from: ?u32) void {
    const join = self.unit.taskJoin().?;
    heap.retainValue(join.tasks);
    self.unit.installParkRequest(.{ .join = .{
        .tasks = join.tasks,
        .index = index,
        .cancel_from = cancel_from,
    } });
}

fn finishTaskJoin(self: *Machine) MachineError!void {
    var join = self.unit.takeTaskJoin().?;
    const summary = join.policy.complete;
    if (summary.failure) |failure| switch (failure) {
        .raised => {
            const raised = join.raised.?;
            join.raised = null;
            beginTaskJoinTeardown(self.unit, join, null, .continue_evaluation);
            return self.raiseOwned(raised);
        },
        .contract => |index| {
            beginTaskJoinTeardown(self.unit, join, null, .continue_evaluation);
            return self.failAtIndex(
                .contract,
                "par-each child must leave exactly one result",
                index,
            );
        },
        .out_of_memory => {
            beginTaskJoinTeardown(self.unit, join, null, .out_of_memory);
            return;
        },
    };
    std.debug.assert(summary.successes == join.results.len());
    const state = self.unit.allocator.create(JoinMaterializeDriver) catch {
        beginTaskJoinTeardown(self.unit, join, null, .out_of_memory);
        return;
    };
    state.* = .{
        .join = join,
        .materializer = kernel_storage.ValueMaterializer.init(
            self.unit.allocator,
            join.results.values(),
        ),
    };
    self.adoptDriver(state);
}

const JoinMaterializeDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    join: ?TaskJoinState,
    materializer: kernel_storage.ValueMaterializer,

    fn beginTeardown(
        self: *JoinMaterializeDriver,
        evaluator: *Machine,
        extra: ?Value,
        disposition: TaskJoinCleanupDisposition,
    ) void {
        const partial = self.materializer.takePartial();
        std.debug.assert(extra == null or partial == null);
        beginTaskJoinTeardown(
            evaluator.unit,
            self.join.?,
            extra orelse partial,
            disposition,
        );
        self.join = null;
    }

    pub fn advance(
        evaluator: *Machine,
        self: *JoinMaterializeDriver,
    ) MachineError!WorkProgress {
        evaluator.pollKernel() catch |err| {
            self.beginTeardown(evaluator, null, .continue_evaluation);
            return err;
        };
        const materialized = self.materializer.advance(kernel_poll_quantum) catch {
            self.beginTeardown(evaluator, null, .out_of_memory);
            return .completed;
        };
        return switch (materialized) {
            .pending => .yielded,
            .complete => |result| completed: {
                self.beginTeardown(evaluator, null, .continue_evaluation);
                break :completed .{ .output = result };
            },
        };
    }

    pub fn deinit(
        self: *JoinMaterializeDriver,
        releases: *heap.ReleaseDomain,
        _: std.mem.Allocator,
    ) void {
        self.materializer.retire(releases);
        std.debug.assert(self.join == null);
    }
};

fn abandonTaskJoin(self: *Machine) void {
    const join = self.unit.takeTaskJoin() orelse return;
    beginTaskJoinTeardown(self.unit, join, null, .continue_evaluation);
}
fn beginTaskJoinTeardown(
    unit: *Unit,
    join: TaskJoinState,
    extra: ?Value,
    disposition: TaskJoinCleanupDisposition,
) void {
    unit.installTaskJoinCleanup(.init(.init(join, extra), disposition));
}
fn poll(self: *Machine) MachineError!void {
    self.unit.fuel -= 1;
}
fn dispatch(self: *Machine, form: Value) MachineError!void {
    const word = switch (form) {
        .word => |id| id,
        .int, .float, .char, .symbol, .list, .dict, .task => return self.pushBorrowed(form),
    };
    try self.executeWord(word);
}
const DispatchDriver = struct {
    resolution: heap.Owned(ResolutionCursor),

    pub fn advance(self_machine: *Machine, self: *DispatchDriver) MachineError!WorkProgress {
        try self_machine.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.resolution.borrowMut().advance()) {
            .pending => {},
            .complete => |maybe_resolved| {
                self.resolution.deinit(self_machine.releaseDomain(), self_machine.allocator());
                const allocator = self_machine.unit.allocator;
                self_machine.detachWorkDriver(self);
                heap.destroyDriver(self_machine.releaseDomain(), allocator, self);
                var resolved = maybe_resolved orelse {
                    const word = self_machine.unit.active_word;
                    const failure = self_machine.failFmt(
                        .undefined_word,
                        "undefined word `{s}`",
                        .{intern.get(word)},
                    );
                    self_machine.unit.pending.?.addData(.name, .{ .symbol = word });
                    return failure;
                };
                defer resolved.deinit(allocator);
                try executeResolved(self_machine, &resolved);
                return .detached;
            },
        };
        return .yielded;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn executeResolved(self: *Machine, resolved: *Resolution) MachineError!void {
    self.unit.active_word = resolved.trace_word;
    const cross_home = resolved.home != null and resolved.home != self.unit.current.?.home;
    const cross_home_effect = if (cross_home) resolved.lease.effect else null;
    const check: ?EffectCheck = if (cross_home) switch (resolved.lease.binding) {
        .builtin, .native => try prepareEffectCheck(self, cross_home_effect, resolved.trace_word),
        .word => null,
    } else null;
    switch (resolved.lease.binding) {
        .word => |body| {
            const body_header = env.quotationHeader(body);
            if (resolved.origin == .core) {
                const fallback = try self.unit.allocator.create(DirectWordFallback);
                heap.incRef(body_header);
                fallback.* = .{ .body = .init(body_header), .word = resolved.trace_word };
                return self.continueWithIdiom(
                    .{ .direct = .{ .body = body_header, .word = resolved.trace_word } },
                    typedIdiomFallback(fallback),
                );
            }
            try scheduleWord(
                self,
                body_header,
                resolved.trace_word,
                resolved.home,
                cross_home_effect,
            );
        },
        .builtin => |primitive| {
            primitive(self) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    const failure_value = self.takePrimitiveFailure() orelse
                        EclErr.init(.domain, "builtin primitive returned error.Ecl without a failure payload");
                    return self.installPrimitiveFailure(failure_value);
                },
            };
            if (self.takePrimitiveFailure()) |failure_value| {
                return self.installPrimitiveFailure(failure_value);
            }
            if (check) |effect_check| try finishEffectCheck(self, effect_check);
        },
        .native => |callable| {
            try native_call.begin(self, callable, check);
        },
    }
}

const DirectWordFallback = struct {
    body: heap.Owned(*Header),
    word: u32,
    pub fn run(evaluator: *Machine, self: *DirectWordFallback) MachineError!void {
        return scheduleWord(evaluator, self.body.borrow(), self.word, null, null);
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

pub const ResolutionOrigin = resolution_core.Origin;
pub const Resolution = struct {
    lease: env.BindingLease,
    execution_generation: ?modules.ExecutionGeneration,
    home: ?*modules.ModuleHome,
    trace_word: u32,
    origin: ResolutionOrigin,
    pub fn deinit(self: *Resolution, _: std.mem.Allocator) void {
        self.lease.deinit();
        if (self.execution_generation) |*generation| generation.deinit();
        self.* = undefined;
    }
};

pub const ResolutionProgress = poll_api.Progress(?Resolution);
pub const ResolutionCursor = struct {
    const Phase = enum {
        dot,
        prefix,
        prefix_validate,
        export_name,
        export_validate,
        qualified_acquire,
        qualified_export,
        scope,
        direct,
        uses,
        used_acquire,
        used_export,
        core,
        complete,
    };
    allocator: std.mem.Allocator,
    registry: ?*modules.Registry,
    module_access: *const modules.ExecutionAccess,
    core: env.EnvironmentView,
    current_home: ?*modules.ModuleHome,
    word: u32,
    spelling: []const u8,
    phase: Phase = .dot,
    dot: intern.LastDotCursor,
    dot_index: usize = 0,
    atom_lookup: ?intern.InternLookupCursor = null,
    qualified_name: ?intern.QualifiedName = null,
    prefix: ?intern.ModuleName = null,
    export_name: ?intern.BindingName = null,
    module_validation: ?intern.ModuleNameCursor = null,
    binding_validation: ?intern.NamespaceCursor = null,
    scope: ?*env.Scope,
    direct: ?env.DirectLookupCursor = null,
    use_shape: ?env.ShapeLease = null,
    use_ordinal: usize = 0,
    acquisition: ?modules.Registry.AcquireCursor = null,
    generation: ?modules.GenerationLease = null,
    export_lookup: ?modules.ModuleGeneration.ResolveCursor = null,

    pub fn init(evaluator: *Machine, word: u32) ResolutionCursor {
        const spelling = intern.get(word);
        return .{
            .allocator = evaluator.unit.allocator,
            .registry = evaluator.unit.inherited.registry,
            .module_access = evaluator.unit.module_access,
            .core = evaluator.unit.environment.coreView(),
            .current_home = evaluator.unit.current.?.home,
            .word = word,
            .spelling = spelling,
            .dot = intern.lastDotCursor(spelling),
            .scope = evaluator.unit.current.?.scope,
        };
    }

    pub fn deinit(self: *ResolutionCursor) void {
        if (self.direct) |*cursor| cursor.deinit();
        if (self.use_shape) |*shape| shape.deinit();
        if (self.acquisition) |*cursor| cursor.deinit();
        if (self.export_lookup) |*cursor| cursor.deinit();
        if (self.generation) |*lease| lease.deinit();
        self.* = undefined;
    }

    fn directResult(self: *ResolutionCursor, lease: env.BindingLease) Resolution {
        const home = if (lease.home() != null and self.current_home != null and
            intern.moduleId(lease.home().?) == intern.moduleId(self.current_home.?.name()))
            self.current_home
        else
            null;
        return .{
            .lease = lease,
            .execution_generation = null,
            .home = home,
            .trace_word = if (home != null) lease.traceWord().? else self.word,
            .origin = if (home != null) .module else .direct,
        };
    }

    fn generationResult(
        self: *ResolutionCursor,
        lease: env.BindingLease,
        origin: ResolutionOrigin,
    ) Resolution {
        var generation_lease = self.generation.?;
        self.generation = null;
        const execution_generation = generation_lease.enterExecution(self.module_access);
        return .{
            .lease = lease,
            .execution_generation = execution_generation,
            .home = execution_generation.home(self.module_access),
            .trace_word = lease.traceWord().?,
            .origin = origin,
        };
    }

    pub fn advance(self: *ResolutionCursor) ResolutionProgress {
        return switch (self.phase) {
            .dot => switch (self.dot.advance()) {
                .pending => .pending,
                .complete => |maybe_dot| result: {
                    if (maybe_dot) |dot_index| {
                        if (dot_index == 0 or dot_index + 1 == self.spelling.len or self.registry == null) {
                            self.phase = .complete;
                            break :result .{ .complete = null };
                        }
                        self.dot_index = dot_index;
                        self.atom_lookup = intern.lookupCursor(self.spelling[0..dot_index]);
                        self.phase = .prefix;
                    } else self.phase = .scope;
                    break :result .pending;
                },
            },
            .prefix => switch (self.atom_lookup.?.advance()) {
                .pending => .pending,
                .complete => |maybe_prefix| result: {
                    const prefix = maybe_prefix orelse {
                        self.phase = .complete;
                        break :result .{ .complete = null };
                    };
                    self.module_validation = .init(prefix);
                    self.phase = .prefix_validate;
                    break :result .pending;
                },
            },
            .prefix_validate => switch (self.module_validation.?.advance()) {
                .pending => .pending,
                .complete => |maybe_module| result: {
                    self.prefix = maybe_module orelse {
                        self.phase = .complete;
                        break :result .{ .complete = null };
                    };
                    self.module_validation = null;
                    self.atom_lookup = intern.lookupCursor(self.spelling[self.dot_index + 1 ..]);
                    self.phase = .export_name;
                    break :result .pending;
                },
            },
            .export_name => switch (self.atom_lookup.?.advance()) {
                .pending => .pending,
                .complete => |maybe_export| result: {
                    const export_name = maybe_export orelse {
                        self.phase = .complete;
                        break :result .{ .complete = null };
                    };
                    self.binding_validation = .init(export_name);
                    self.phase = .export_validate;
                    break :result .pending;
                },
            },
            .export_validate => switch (self.binding_validation.?.advance()) {
                .pending => .pending,
                .complete => |maybe_binding| result: {
                    self.export_name = maybe_binding orelse {
                        self.phase = .complete;
                        break :result .{ .complete = null };
                    };
                    self.binding_validation = null;
                    self.qualified_name = intern.qualifiedName(self.prefix.?, self.export_name.?);
                    self.acquisition = self.registry.?.acquireCursor(
                        intern.qualifiedModule(self.qualified_name.?),
                    );
                    self.phase = .qualified_acquire;
                    break :result .pending;
                },
            },
            .qualified_acquire => switch (self.acquisition.?.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| result: {
                    self.acquisition.?.deinit();
                    self.acquisition = null;
                    self.generation = maybe_generation;
                    const generation = if (self.generation) |lease|
                        lease
                    else {
                        self.phase = .complete;
                        break :result .{ .complete = null };
                    };
                    self.export_lookup = generation.resolveCursor(
                        intern.bindingId(intern.qualifiedBinding(self.qualified_name.?)),
                        true,
                    );
                    self.phase = .qualified_export;
                    break :result .pending;
                },
            },
            .qualified_export => switch (self.export_lookup.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.export_lookup.?.deinit();
                    self.export_lookup = null;
                    const lease = maybe_lease orelse {
                        self.generation.?.deinit();
                        self.generation = null;
                        self.phase = .complete;
                        break :result .{ .complete = null };
                    };
                    self.phase = .complete;
                    break :result .{ .complete = self.generationResult(lease, .module) };
                },
            },
            .scope => result: {
                const current = self.scope orelse {
                    self.direct = self.core.directLookupCursor(self.word);
                    self.phase = .core;
                    break :result .pending;
                };
                self.scope = current.parent;
                if (current.environmentOrNull()) |environment| {
                    self.direct = environment.directLookupCursor(self.word);
                    self.phase = .direct;
                }
                break :result .pending;
            },
            .direct => switch (self.direct.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    const environment = self.direct.?.shape.environment;
                    self.direct.?.deinit();
                    self.direct = null;
                    if (maybe_lease) |lease| {
                        self.phase = .complete;
                        break :result .{ .complete = self.directResult(lease) };
                    }
                    if (self.registry != null) {
                        self.use_shape = environment.acquireShape();
                        self.use_ordinal = 0;
                        self.phase = .uses;
                    } else self.phase = .scope;
                    break :result .pending;
                },
            },
            .uses => result: {
                const uses = self.use_shape.?.useOrder();
                const index = resolution_core.usedIndex(uses.len, self.use_ordinal) orelse {
                    self.use_shape.?.deinit();
                    self.use_shape = null;
                    self.phase = .scope;
                    break :result .pending;
                };
                self.use_ordinal += 1;
                self.acquisition = self.registry.?.acquireCursor(uses[index]);
                self.phase = .used_acquire;
                break :result .pending;
            },
            .used_acquire => switch (self.acquisition.?.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| result: {
                    self.acquisition.?.deinit();
                    self.acquisition = null;
                    self.generation = maybe_generation;
                    if (self.generation) |generation| {
                        self.export_lookup = generation.resolveCursor(self.word, true);
                        self.phase = .used_export;
                    } else self.phase = .uses;
                    break :result .pending;
                },
            },
            .used_export => switch (self.export_lookup.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.export_lookup.?.deinit();
                    self.export_lookup = null;
                    if (maybe_lease) |lease| {
                        self.phase = .complete;
                        break :result .{ .complete = self.generationResult(lease, .used) };
                    }
                    self.generation.?.deinit();
                    self.generation = null;
                    self.phase = .uses;
                    break :result .pending;
                },
            },
            .core => switch (self.direct.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.direct.?.deinit();
                    self.direct = null;
                    self.phase = .complete;
                    var lease = maybe_lease orelse break :result .{ .complete = null };
                    if (lease.visibility == .private) {
                        lease.deinit();
                        break :result .{ .complete = null };
                    }
                    break :result .{ .complete = .{
                        .lease = lease,
                        .execution_generation = null,
                        .home = null,
                        .trace_word = self.word,
                        .origin = .core,
                    } };
                },
            },
            .complete => unreachable,
        };
    }
};

pub const ShadowProgress = poll_api.Progress([]u32);
pub const ShadowCursor = struct {
    const Phase = enum { dot, scope, direct, uses, acquire, export_name, core, materialize, complete };
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    registry: ?*modules.Registry,
    core: env.EnvironmentView,
    word: u32,
    phase: Phase = .dot,
    dot: intern.DotCursor,
    scope: ?*env.Scope,
    direct: ?env.DirectLookupCursor = null,
    use_shape: ?env.ShapeLease = null,
    use_ordinal: usize = 0,
    acquisition: ?modules.Registry.AcquireCursor = null,
    generation: ?modules.GenerationLease = null,
    export_lookup: ?modules.ModuleGeneration.ResolveCursor = null,
    search: resolution_core.Search = .searching,
    found: poll_api.ChunkList(u32),
    output: ?[]u32 = null,
    iterator: ?poll_api.ChunkList(u32).Iterator = null,
    output_index: usize = 0,

    pub fn init(evaluator: *Machine, word: u32) ShadowCursor {
        return .{
            .allocator = evaluator.unit.allocator,
            .releases = evaluator.releaseDomain(),
            .registry = evaluator.unit.inherited.registry,
            .core = evaluator.unit.environment.coreView(),
            .word = word,
            .dot = intern.dotCursor(intern.get(word)),
            .scope = evaluator.unit.current.?.scope,
            .found = .init(evaluator.unit.allocator),
        };
    }
    pub fn deinit(self: *ShadowCursor) void {
        if (self.direct) |*cursor| cursor.deinit();
        if (self.use_shape) |*shape| shape.deinit();
        if (self.acquisition) |*cursor| cursor.deinit();
        if (self.export_lookup) |*cursor| cursor.deinit();
        if (self.generation) |*lease| lease.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.found.retire(self.releases);
        self.* = undefined;
    }
    fn record(self: *ShadowCursor, trace_word: u32, origin: ResolutionOrigin) error{OutOfMemory}!void {
        const decision = resolution_core.consider(self.search, .{ .trace_word = trace_word, .origin = origin });
        self.search = decision.next;
        switch (decision.command) {
            .winner => {},
            .shadow => |shadow| try self.found.append(shadow.trace_word),
        }
    }
    pub fn advance(self: *ShadowCursor) error{OutOfMemory}!ShadowProgress {
        return switch (self.phase) {
            .dot => switch (self.dot.advance()) {
                .pending => .pending,
                .complete => |maybe_dot| result: {
                    if (maybe_dot != null) {
                        self.output = try self.allocator.alloc(u32, 0);
                        self.phase = .complete;
                        break :result .{ .complete = self.takeOutput() };
                    }
                    self.phase = .scope;
                    break :result .pending;
                },
            },
            .scope => result: {
                const current = self.scope orelse {
                    self.direct = self.core.directLookupCursor(self.word);
                    self.phase = .core;
                    break :result .pending;
                };
                self.scope = current.parent;
                if (current.environmentOrNull()) |environment| {
                    self.direct = environment.directLookupCursor(self.word);
                    self.phase = .direct;
                }
                break :result .pending;
            },
            .direct => switch (self.direct.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    const environment = self.direct.?.shape.environment;
                    self.direct.?.deinit();
                    self.direct = null;
                    if (maybe_lease) |loaded| {
                        var lease = loaded;
                        defer lease.deinit();
                        try self.record(
                            lease.traceWord() orelse self.word,
                            if (lease.home() != null) .module else .direct,
                        );
                    }
                    if (self.registry != null) {
                        self.use_shape = environment.acquireShape();
                        self.use_ordinal = 0;
                        self.phase = .uses;
                    } else self.phase = .scope;
                    break :result .pending;
                },
            },
            .uses => result: {
                const uses = self.use_shape.?.useOrder();
                const index = resolution_core.usedIndex(uses.len, self.use_ordinal) orelse {
                    self.use_shape.?.deinit();
                    self.use_shape = null;
                    self.phase = .scope;
                    break :result .pending;
                };
                self.use_ordinal += 1;
                self.acquisition = self.registry.?.acquireCursor(uses[index]);
                self.phase = .acquire;
                break :result .pending;
            },
            .acquire => switch (self.acquisition.?.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| result: {
                    self.acquisition.?.deinit();
                    self.acquisition = null;
                    self.generation = maybe_generation;
                    if (self.generation) |generation| {
                        self.export_lookup = generation.resolveCursor(self.word, true);
                        self.phase = .export_name;
                    } else self.phase = .uses;
                    break :result .pending;
                },
            },
            .export_name => switch (self.export_lookup.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.export_lookup.?.deinit();
                    self.export_lookup = null;
                    if (maybe_lease) |loaded| {
                        var lease = loaded;
                        defer lease.deinit();
                        try self.record(lease.traceWord().?, .used);
                    }
                    self.generation.?.deinit();
                    self.generation = null;
                    self.phase = .uses;
                    break :result .pending;
                },
            },
            .core => switch (self.direct.?.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.direct.?.deinit();
                    self.direct = null;
                    if (maybe_lease) |loaded| {
                        var lease = loaded;
                        defer lease.deinit();
                        if (lease.visibility == .public) try self.record(self.word, .core);
                    }
                    self.output = try self.allocator.alloc(u32, self.found.count);
                    self.iterator = self.found.iterator();
                    self.phase = .materialize;
                    break :result .pending;
                },
            },
            .materialize => if (self.iterator.?.next()) |name| result: {
                self.output.?[self.output_index] = name.*;
                self.output_index += 1;
                break :result .pending;
            } else result: {
                self.phase = .complete;
                break :result .{ .complete = self.takeOutput() };
            },
            .complete => unreachable,
        };
    }
    fn takeOutput(self: *ShadowCursor) []u32 {
        const result = self.output.?;
        self.output = null;
        return result;
    }
};

fn scheduleWord(
    self: *Machine,
    body: *Header,
    word: u32,
    resolved_home: ?*modules.ModuleHome,
    effect: ?env.Effect,
) MachineError!void {
    const scope = if (resolved_home) |home| home.scope(self.unit.module_access) else self.unit.current.?.scope;
    const home = resolved_home orelse self.unit.current.?.home;
    if (resolved_home) |generation| try self.unit.pinGeneration(generation);
    const check = if (effect != null) try prepareEffectCheck(self, effect, word) else null;
    _ = self.suspendCurrent() catch return error.OutOfMemory;
    if (check) |effect_check| {
        var continuation = OwnedFrame.init(.{ .effect_check = effect_check });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        try self.appendFrame(&continuation);
    }
    heap.incRef(body);
    self.unit.current = .{
        .code = body,
        .ip = 0,
        .scope = scope,
        .home = home,
        .traced_word = word,
    };
}
fn prepareEffectCheck(
    self: *Machine,
    effect: ?env.Effect,
    word: u32,
) MachineError!EffectCheck {
    const declared = effect orelse {
        self.unit.active_word = word;
        return self.fail(.domain, "module word has no effect declaration");
    };
    const available: u32 = @intCast(self.available());
    if (available < declared.inputs) {
        self.unit.active_word = word;
        const failure = self.failFmt(
            .contract,
            "{s} declared {d} input{s}, but found {d}",
            .{ self.activeWordName(), declared.inputs, if (declared.inputs == 1) "" else "s", available },
        );
        self.unit.pending.?.addData(.seeded, .{ .int = available });
        self.unit.pending.?.addData(.observed, .{ .int = available });
        return failure;
    }
    return .{
        .expected_depth = @intCast(self.unit.stack.items.len - declared.inputs + declared.outputs),
        .entry_depth = available,
        .inputs = declared.inputs,
        .outputs = declared.outputs,
        .word = word,
    };
}
fn resumeFrames(self: *Machine) MachineError!bool {
    while (self.unit.frames.pop()) |frame| switch (frame) {
        .eval => |continuation| {
            self.unit.current = continuation;
            return true;
        },
        .effect_check => |check| try finishEffectCheck(self, check),
        .application => |continuation| {
            const launch: Machine.ApplicationLaunch, const base: StackWindow = switch (continuation.mode) {
                .in_place => |window| .{ .in_place, window },
                .isolated => |isolated| blk: {
                    const window: StackWindow = @enumFromInt(@as(u32, @intCast(self.unit.stack_base)));
                    isolated.child.retire();
                    self.unit.stack_base = isolated.previous_base.base();
                    break :blk .{ .isolated, window };
                },
            };
            const next = continuation.resume_fn(
                self,
                continuation.context,
                base,
            ) catch |err| {
                if (continuation.traced_word != no_word) {
                    self.setFailureTraceParent(continuation.traced_word);
                }
                continuation.deinit_fn(self.releaseDomain(), self.unit.allocator, continuation.context);
                return err;
            };
            if (next) |step| {
                try self.beginApplication(.{
                    .quotation = step.quotation,
                    .context = continuation.context,
                    .resume_fn = continuation.resume_fn,
                    .deinit_fn = continuation.deinit_fn,
                    .parent_scope = continuation.parent_scope,
                    .home = continuation.home,
                    .seeded = step.seeded,
                }, launch, continuation.traced_word);
                return true;
            }
            continuation.deinit_fn(self.releaseDomain(), self.unit.allocator, continuation.context);
            // Native work installed by an application continuation is the
            // continuation's tail. Do not cross later continuation frames until
            // that owned work has produced its stack result.
            if (self.unit.hasWorkDriver()) return true;
        },
        .use_after_load => |continuation| {
            var loading = continuation.loading;
            defer loading.deinit();
            var path = heap.OwnedValue.init(self.releaseDomain(), continuation.path);
            defer path.deinit();
            self.unit.active_word = try intern.intern("use");
            var driver = Machine.UseDriver.init(self, continuation.scope, continuation.name, false);
            driver.after_load = .init(.{ .loading = loading.move(), .path = path.take() });
            try self.startDriver(driver);
            return true;
        },
        .boundary => |boundary| {
            std.debug.assert(@intFromEnum(self.unit.boundary_index.?) == self.unit.frames.items.len);
            self.unit.boundary_index = boundary.previous_boundary;
            self.unit.stack_base = boundary.previous_base;
            self.unit.active_word = boundary.word;
            switch (boundary.mode) {
                .attempt => {
                    defer boundary.deinit(self.releaseDomain(), self.unit.allocator);
                    try finishAttempt(self, boundary.stack_base);
                    return true;
                },
                .module => {
                    try finishModule(self, boundary);
                    if (self.unit.hasWorkDriver()) return true;
                },
                .state => {
                    try finishStateApplication(self, boundary);
                    if (self.unit.hasWorkDriver()) return true;
                },
            }
        },
    };
    return false;
}
pub fn finishEffectCheck(self: *Machine, check: EffectCheck) MachineError!void {
    const observed = self.unit.stack.items.len;
    if (observed == check.expected_depth) return;
    self.unit.active_word = check.word;
    const observed_relative = observed - self.unit.stack_base;
    const failure = self.failFmt(
        .contract,
        "{s} declared ({d} -- {d}); seeded {d}, observed {d}",
        .{ self.activeWordName(), check.inputs, check.outputs, check.entry_depth, observed_relative },
    );
    self.unit.pending.?.addData(.seeded, .{ .int = check.entry_depth });
    self.unit.pending.?.addData(.observed, .{ .int = @intCast(observed_relative) });
    return failure;
}
fn finishAttempt(self: *Machine, base: u32) MachineError!void {
    try self.startDriver(AttemptResultDriver.init(
        self.unit.allocator,
        base,
        self.unit.stack.items[base..],
    ));
}
const AttemptResultDriver = struct {
    allocator: std.mem.Allocator,
    base: usize,
    materializer: heap.Owned(kernel_storage.ValueMaterializer),
    results: ?heap.Owned(Value) = null,
    phase: enum { materialize, release, outcome } = .materialize,

    fn init(
        allocator: std.mem.Allocator,
        base: u32,
        values: []const Value,
    ) AttemptResultDriver {
        return .{
            .allocator = allocator,
            .base = base,
            .materializer = .init(.init(allocator, values)),
        };
    }
    pub fn advance(evaluator: *Machine, self: *AttemptResultDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .materialize => switch (try self.materializer.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => |results| {
                    self.results = .init(results);
                    self.phase = .release;
                    return .yielded;
                },
            },
            .release => {
                if (evaluator.unit.stack.items.len == self.base) {
                    self.phase = .outcome;
                    continue;
                }
                evaluator.releaseDomain().releaseValue(evaluator.unit.stack.pop().?);
                budget -= 1;
            },
            .outcome => {
                const results = self.results.?.take();
                self.results = null;
                const outcome = try outcomeDict(self.allocator, evaluator.releaseDomain(), "ok", results);
                return .{ .output = outcome };
            },
        };
        return .yielded;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
/// The construction body's final operand stack becomes the module's durable
/// initial state, so a non-empty residual window is captured rather than
/// rejected. Ownership moves value by value into the candidate's proposal.
fn finishModule(self: *Machine, boundary: Boundary) MachineError!void {
    var candidate = boundary.mode.module;
    defer candidate.deinit();
    const observed = self.unit.stack.items.len - boundary.stack_base;
    try candidate.reserveProposal(observed);
    const driver = try self.unit.allocator.create(ModuleCommitDriver);
    driver.* = .{
        .candidate = .init(candidate.move()),
        .cursor = null,
        .captured = observed,
    };
    self.adoptDriver(driver);
}
/// Waits for the slot's turn as ordinary resumable scheduler work, then
/// materializes the private draft: a retained copy of the durable stack in
/// the unit's own operand window behind a fresh stack barrier.
const StateAcquireDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    application: heap.Owned(OwnedApplication),
    quotation: heap.Owned(*Header),
    copied: usize = 0,
    based: bool = false,
    checked: bool = false,

    pub fn advance(evaluator: *Machine, self: *StateAcquireDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        const application = self.application.borrow().borrow();
        if (!application.turn.granted()) return .yielded;
        if (!self.checked) {
            // The turn may have been queued behind a re-registration, so the
            // currency of the invoking generation is re-established here as
            // well: old code never publishes over a newer representation.
            self.checked = true;
            const home = evaluator.unit.current.?.home.?;
            if (!modules.homeIsCurrent(home, evaluator.unit.module_access))
                return evaluator.fail(.domain, "a replaced module generation cannot publish state");
        }
        if (!self.based) {
            application.draft_base = @intCast(evaluator.unit.stack.items.len);
            self.based = true;
        }
        const durable = application.turn.stack();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0 and self.copied != durable.len) : (budget -= 1) {
            try evaluator.pushBorrowed(durable[self.copied]);
            self.copied += 1;
        }
        if (self.copied != durable.len) return .yielded;
        // One move, not a shared pointer: `enterStateApplication` owns the
        // application on every exit path from here.
        try evaluator.enterStateApplication(
            self.application.borrowMut().move(),
            self.quotation.take(),
        );
        return .completed;
    }
};

/// A durable-stack snapshot under construction or retirement. Entries are
/// scalars until they are filled, so the slice is releasable at every point
/// and a cancelled publication leaks nothing.
const OwnedValueSlice = struct {
    items: []Value = &.{},

    pub fn retire(
        self: *OwnedValueSlice,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        for (self.items) |item| releases.releaseValue(item);
        if (self.items.len != 0) allocator.free(self.items);
        self.items = &.{};
    }
    fn take(self: *OwnedValueSlice) []Value {
        const result = self.items;
        self.items = &.{};
        return result;
    }
};

/// Publishes one completed transaction: secure the exact caller window,
/// move the remaining draft into a replacement snapshot, swap it in under
/// the turn, retire the previous snapshot, then deliver the pending outputs
/// in invocation order. Nothing before the swap is observable, and nothing
/// after it can fail.
const StatePublishDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    application: heap.Owned(OwnedApplication),
    replacement: heap.Owned(OwnedValueSlice) = .init(.{}),
    retired: heap.Owned(OwnedValueSlice) = .init(.{}),
    window: ?StackReplacement = null,
    remaining: usize,
    moved: usize = 0,
    retired_index: usize = 0,
    phase: enum { reserve, move, publish, retire, deliver } = .reserve,

    pub fn advance(evaluator: *Machine, self: *StatePublishDriver) MachineError!WorkProgress {
        // Cancellation is honoured only while the transaction can still be
        // abandoned. Once the snapshot swap has happened the outputs are
        // already owed to the caller, so retirement and delivery run to
        // completion rather than reporting a failure over committed state.
        switch (self.phase) {
            .reserve, .move => try evaluator.pollKernel(),
            .publish, .retire, .deliver => evaluator.unit.polls += 1,
        }
        const application = self.application.borrow().borrow();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.phase) {
            .reserve => {
                const buffer = try application.turn.allocator().alloc(Value, self.remaining);
                @memset(buffer, .{ .int = 0 });
                self.replacement = .init(.{ .items = buffer });
                // Capacity for every output is secured before the draft is
                // drained; draining only lowers the length, so the window is
                // still guaranteed when the reservation is taken below.
                _ = try evaluator.reserveStack(application.outputs.items.len);
                self.moved = self.remaining;
                self.phase = .move;
            },
            .move => {
                if (self.moved == 0) {
                    self.phase = .publish;
                    continue;
                }
                self.moved -= 1;
                self.replacement.borrow().items[self.moved] = evaluator.unit.takeStackOwned().?;
            },
            .publish => {
                // Capacity was secured before the draft was drained, and
                // draining only lowered the length, so this cannot fail.
                self.window = try evaluator.reserveStackReplacement(
                    0,
                    application.outputs.items.len,
                );
                self.retired = .init(.{ .items = application.turn.publish(
                    self.replacement.borrowMut().take(),
                ) });
                self.retired_index = self.retired.borrow().items.len;
                self.phase = .retire;
            },
            .retire => {
                if (self.retired_index == 0) {
                    application.turn.release();
                    self.phase = .deliver;
                    continue;
                }
                self.retired_index -= 1;
                const stale = self.retired.borrow().items[self.retired_index];
                self.retired.borrow().items[self.retired_index] = .{ .int = 0 };
                evaluator.releaseDomain().releaseValue(stale);
            },
            .deliver => {
                self.window.?.commitOwned(application.outputs.items);
                application.outputs.clearRetainingCapacity();
                self.application.borrowMut().retire(
                    evaluator.releaseDomain(),
                    evaluator.unit.allocator,
                );
                return .completed;
            },
        };
        return .yielded;
    }
};

/// The residual draft is the new durable stack, and the pending outputs are
/// the caller's results. Publication is one transition: it happens once, in
/// full, or not at all.
fn finishStateApplication(self: *Machine, boundary: Boundary) MachineError!void {
    var owned = boundary.mode.state;
    self.unit.state_application = null;
    const remaining = self.unit.stack.items.len - boundary.stack_base;
    // Installation failure disposes the owned field, which retires the
    // application: publication is all-or-nothing on this path too.
    return self.startDriver(StatePublishDriver{
        .application = .init(owned.move()),
        .remaining = remaining,
    });
}

const ModuleCommitDriver = struct {
    pub const address_stable_driver = {};
    candidate: heap.Owned(modules.OwnedCandidate),
    cursor: ?heap.Owned(modules.Registry.CommitCursor),
    /// Construction-stack values still to move into the candidate proposal,
    /// counted from the top of the residual window down.
    captured: usize,
    pub fn advance(evaluator: *Machine, self: *ModuleCommitDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        if (self.cursor == null) {
            var budget: usize = kernel_poll_quantum;
            while (budget != 0 and self.captured != 0) : (budget -= 1) {
                self.captured -= 1;
                self.candidate.borrow().placeProposal(
                    self.captured,
                    evaluator.unit.takeStackOwned().?,
                );
            }
            if (self.captured != 0) return .yielded;
            self.cursor = .init(evaluator.unit.inherited.registry.?.commitCursor(
                self.candidate.borrowMut(),
                &evaluator.unit.turn_authority,
            ));
            return .yielded;
        }
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            switch (self.cursor.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NameConflict => return evaluator.fail(.domain, "module name collides with an alias"),
                error.StateApplicationActive => return evaluator.fail(
                    .domain,
                    "a module cannot be registered from inside a state application",
                ),
            }) {
                .pending => {},
                .complete => return .completed,
            }
        }
        return .yielded;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
pub fn outcomeDict(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    name: []const u8,
    payload: Value,
) error{OutOfMemory}!Value {
    defer releases.releaseValue(payload);
    const key = try intern.intern(name);
    return dict.fromUniquePairs(allocator, releases, &.{.{ .{ .symbol = key }, payload }});
}
fn startFailure(self: *Machine) error{OutOfMemory}!void {
    std.debug.assert(!self.unit.hasWorkDriver() and self.unit.pending != null);
    const capacity = std.math.add(usize, self.unit.frames.items.len, 3) catch
        return error.OutOfMemory;
    const trace = try self.unit.allocator.alloc(u32, capacity);
    errdefer self.unit.allocator.free(trace);
    const driver = try self.unit.allocator.create(FailureDriver);
    driver.* = .{
        .allocator = self.unit.allocator,
        .failure = self.unit.pending.?,
        .trace = trace,
        .frame_index = self.unit.frames.items.len,
        .boundary_index = self.unit.boundary_index,
    };
    self.unit.pending = null;
    driver.appendInitial(self);
    self.adoptDriver(driver);
}

const FailureDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    allocator: std.mem.Allocator,
    failure: EclErr,
    trace: []u32,
    trace_count: usize = 0,
    frame_index: usize,
    location_cursor: ?spans.SpanArchive.LocateCursor = null,
    location: ?spans.LocatedSpan = null,
    value_cursor: ?ErrorValueCursor = null,
    error_value: ?Value = null,
    boundary_index: ?FrameIndex,
    attempt_index: ?FrameIndex = null,
    attempt_stack_base: usize = 0,
    previous_base: usize = 0,
    previous_boundary: ?FrameIndex = null,
    outcome_inserter: ?intern.InternInsertionCursor = null,
    outcome_pair: [1]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }},
    outcome_builder: ?kernel_storage.DictMaterializer = null,
    phase: enum { trace, locate, value, nearest, current, frames, boundary, stack, outcome_name, outcome, finish } = .trace,

    fn appendInitial(self: *FailureDriver, evaluator: *Machine) void {
        if (self.failure.word) |word| self.appendTrace(word);
        if (self.failure.trace_parent) |word| self.appendTrace(word);
        if (evaluator.unit.current) |current|
            if (current.traced_word != no_word) self.appendTrace(current.traced_word);
    }
    fn appendTrace(self: *FailureDriver, word: u32) void {
        self.trace[self.trace_count] = word;
        self.trace_count += 1;
    }
    pub fn deinit(
        self: *FailureDriver,
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
    ) void {
        if (self.value_cursor) |*cursor| cursor.retire(releases);
        if (self.outcome_builder) |*builder| builder.retire(releases);
        if (self.error_value) |item| releases.releaseValue(item);
        self.failure.retire(releases);
        storage_allocator.free(self.trace);
    }
    fn beginLocation(self: *FailureDriver, evaluator: *Machine) void {
        if (self.failure.site) |site| {
            self.location_cursor = evaluator.unit.archive.locateCursor(site.code, site.index);
            self.phase = .locate;
        } else self.beginValue();
    }
    fn beginValue(self: *FailureDriver) void {
        self.value_cursor = .init(
            self.allocator,
            &self.failure,
            self.trace[0..self.trace_count],
            self.location,
        );
        self.phase = .value;
    }
    fn beginUnwind(self: *FailureDriver, evaluator: *Machine) void {
        self.phase = .current;
        if (self.attempt_index == null) {
            self.attempt_stack_base = evaluator.unit.entry_base;
            self.previous_base = 0;
            self.previous_boundary = null;
        }
    }
    pub fn advance(evaluator: *Machine, self: *FailureDriver) MachineError!WorkProgress {
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.phase) {
            .trace => {
                if (self.frame_index == 0) {
                    self.beginLocation(evaluator);
                    continue;
                }
                self.frame_index -= 1;
                switch (evaluator.unit.frames.items[self.frame_index]) {
                    .eval => |frame| if (frame.traced_word != no_word) self.appendTrace(frame.traced_word),
                    .effect_check, .application, .use_after_load, .boundary => {},
                }
            },
            .locate => switch (self.location_cursor.?.advance()) {
                .pending => {},
                .complete => |location| {
                    self.location = location;
                    self.location_cursor = null;
                    self.beginValue();
                },
            },
            .value => switch (try self.value_cursor.?.advance()) {
                .pending => {},
                .complete => |item| {
                    self.value_cursor.?.retire(evaluator.releaseDomain());
                    self.value_cursor = null;
                    self.error_value = item;
                    self.phase = .nearest;
                },
            },
            .nearest => {
                if (self.boundary_index == null) {
                    self.beginUnwind(evaluator);
                    continue;
                }
                const boundary = evaluator.unit.frames.items[@intFromEnum(self.boundary_index.?)].boundary;
                if (boundary.mode == .attempt) {
                    self.attempt_index = self.boundary_index;
                    self.attempt_stack_base = boundary.stack_base;
                    self.previous_base = boundary.previous_base;
                    self.previous_boundary = boundary.previous_boundary;
                    self.beginUnwind(evaluator);
                } else self.boundary_index = boundary.previous_boundary;
            },
            .current => {
                releaseCurrent(evaluator);
                self.phase = .frames;
            },
            .frames => {
                const target: usize = if (self.attempt_index == null)
                    0
                else
                    @as(usize, @intFromEnum(self.attempt_index.?)) + 1;
                if (evaluator.unit.frames.items.len != target) {
                    var frame = evaluator.unit.frames.pop().?;
                    frame.deinit(evaluator.releaseDomain(), self.allocator);
                } else self.phase = .boundary;
            },
            .boundary => {
                if (self.attempt_index != null) {
                    var frame = evaluator.unit.frames.pop().?;
                    frame.deinit(evaluator.releaseDomain(), self.allocator);
                }
                self.phase = .stack;
            },
            .stack => {
                const target = @min(@as(usize, self.attempt_stack_base), evaluator.unit.stack.items.len);
                if (evaluator.unit.stack.items.len != target) {
                    const item = evaluator.unit.stack.pop().?;
                    evaluator.releaseDomain().releaseValue(item);
                    continue;
                }
                evaluator.unit.stack_base = self.previous_base;
                evaluator.unit.boundary_index = self.previous_boundary;
                if (self.attempt_index == null) {
                    evaluator.unit.last_error = self.error_value.?;
                    self.error_value = null;
                    self.phase = .finish;
                } else {
                    self.outcome_inserter = intern.insertionCursor("err");
                    self.phase = .outcome_name;
                }
            },
            .outcome_name => switch (try self.outcome_inserter.?.advance()) {
                .pending => {},
                .complete => |key| {
                    self.outcome_pair[0] = .{ .{ .symbol = key }, self.error_value.? };
                    self.outcome_builder = try .init(self.allocator, &self.outcome_pair, false);
                    self.phase = .outcome;
                },
            },
            .outcome => switch (try self.outcome_builder.?.advance(1)) {
                .pending => {},
                .duplicate_key => unreachable,
                .complete => |outcome| {
                    self.outcome_builder.?.deinit();
                    self.outcome_builder = null;
                    return .{ .output = outcome };
                },
            },
            .finish => return if (self.attempt_index == null) .failed else .completed,
        };
        return .yielded;
    }
};
fn releaseCurrent(self: *Machine) void {
    if (self.unit.current) |current| self.releaseDomain().releaseHeader(current.code);
    self.unit.current = null;
}
