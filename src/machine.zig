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
const native_abi = @import("native-abi");
const reader = @import("reader.zig");
const reader_cursor = @import("reader_cursor.zig");
const poll_api = @import("poll.zig");
const stdlib = @import("stdlib.zig");
const kernel_storage = @import("kernel_storage.zig");
const console_api = @import("console.zig");
const task_join_core = @import("task_join_core.zig");
const resolution_core = @import("resolution_core.zig");
const pkg_lock = @import("pkg_lock.zig");
pub const Value = value.Value;
pub const Header = value.ListHandle;
pub const MachineError = error{ OutOfMemory, Ecl };
/// The absence of a named activation. A trace word is either a plain atom or
/// a module-local name qualified by the registration it was reached through,
/// so `none` is the one value that spells neither.
const no_word: intern.TraceWord = .none;
const max_frame_count = std.math.maxInt(u32);
const FrameIndex = enum(u32) { _ };
const EffectCheckIndex = enum(u32) { _ };
const ApplicationFrameIndex = enum(u32) { _ };
const ApplicationProvenanceNonce = enum(u32) { _ };
var next_application_provenance_nonce: std.atomic.Value(u64) = .init(1);
const fuel_quantum: u32 = 1024;
pub const kernel_poll_quantum: u32 = 65_536;
/// Elements of a construction body re-scoped, and seed values materialized,
/// per scheduler step. Deliberately the same small scale as
/// `par_each_work_quantum` rather than the kernel quantum: both of these are
/// bounded traversals whose whole purpose is to keep a user-sized construction
/// off one step, and a 65,536-element slice is not a bound anyone would feel.
pub const construction_work_quantum: usize = 256;
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
const OwnedCode = struct {
    header: ?*Header,

    fn retain(header: *Header) OwnedCode {
        heap.incRef(header);
        return .{ .header = header };
    }
    fn initOwned(header: *Header) OwnedCode {
        return .{ .header = header };
    }
    fn borrow(self: *const OwnedCode) *Header {
        return self.header.?;
    }
    fn take(self: *OwnedCode) *Header {
        const header = self.header.?;
        self.header = null;
        return header;
    }
    fn replaceBorrowed(self: *OwnedCode, releases: *heap.ReleaseDomain, header: *Header) void {
        heap.incRef(header);
        releases.releaseHeader(self.header.?);
        self.header = header;
    }
    fn deinit(self: *OwnedCode, releases: *heap.ReleaseDomain) void {
        if (self.header) |header| releases.releaseHeader(header);
        self.header = null;
    }
};
/// An optional dynamically selected quotation owned by exactly one
/// application frame. The driver continues to own the original quotation;
/// this field is populated only by moving an existing Eval-owned reference.
const ApplicationSelection = struct {
    /// Borrowed from the newest dynamically applied Eval until that Eval
    /// completes; pointer identity lets older suspended selections recognize
    /// that they are stale without a counter or another owned reference.
    latest: ?*Header = null,
    owned: ?*Header = null,

    fn selectBorrowed(self: *ApplicationSelection, code: *Header) void {
        self.latest = code;
    }

    /// Moves an Eval-owned reference into the application frame. Releasing a
    /// prior selection here is the release it would otherwise have received
    /// when its Eval completed, so selection tracking adds no reference-count
    /// operations to a successful application.
    fn completeOwned(
        self: *ApplicationSelection,
        releases: *heap.ReleaseDomain,
        code: *Header,
    ) void {
        if (self.latest != code) {
            releases.releaseHeader(code);
            return;
        }
        if (self.owned) |previous| releases.releaseHeader(previous);
        self.owned = code;
    }
    fn takeFailureSite(self: *ApplicationSelection, fallback: *Header) OwnedCode {
        if (self.takeSelected()) |selected| return selected;
        return .retain(fallback);
    }
    fn takeSelected(self: *ApplicationSelection) ?OwnedCode {
        const selected = self.owned orelse return null;
        self.owned = null;
        return .initOwned(selected);
    }
    fn deinit(self: *ApplicationSelection, releases: *heap.ReleaseDomain) void {
        if (self.owned) |selected| releases.releaseHeader(selected);
        self.* = .{};
    }
};
/// Opaque callback capability for consuming the candidate of exactly the
/// application that just completed. Generic drivers can return it to the
/// machine on a contract failure but cannot construct or retarget it.
pub const ApplicationContractSite = opaque {};
pub const ApplicationDepths = struct {
    seeded: usize,
    expected: usize,
    observed: usize,
};
const FailureSite = union(enum) {
    token: ErrorSite,
    contract_quotation: OwnedCode,

    fn deinit(self: *FailureSite, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .token => {},
            .contract_quotation => |*candidate| candidate.deinit(releases),
        }
        self.* = undefined;
    }
};
pub const UnitConstructor = enum { spawn, each };

const ErrorDataKey = enum {
    needed,
    available,
    isolation,
    name,
    path,
    seeded,
    observed,
    expected,
    index,
    left,
    right,
    @"destination-exists",
    scope,
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
    word: ?intern.TraceWord = null,
    trace_parent: ?intern.TraceWord = null,
    site: ?FailureSite = null,
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
        if (self.site) |*site| site.deinit(releases);
        self.site = null;
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
    resolved: ResolvedTrace,
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
        resolved: ResolvedTrace,
        location: ?spans.LocatedSpan,
    ) OrdinaryErrorCursor {
        return .{
            .allocator = allocator,
            .failure = failure,
            .resolved = resolved,
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
        if (self.resolved.word) |word| {
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
                self.trace_items = try self.allocator.alloc(Value, self.resolved.trace.len);
                self.phase = .trace_copy;
                break :result .pending;
            },
            .trace_copy => result: {
                if (self.trace_index != self.resolved.trace.len) {
                    self.trace_items.?[self.trace_index] = .{ .symbol = self.resolved.trace[self.trace_index] };
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
    resolved: ResolvedTrace,
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
        resolved: ResolvedTrace,
        location: ?spans.LocatedSpan,
    ) RaisedErrorCursor {
        return .{
            .allocator = allocator,
            .failure = failure,
            .resolved = resolved,
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
            @as(usize, @intFromBool(self.fields[2] == null and self.resolved.word != null)) +
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
        if (self.fields[2] == null) if (self.resolved.word) |word| {
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
                self.trace_items = try self.allocator.alloc(Value, self.resolved.trace.len);
                self.phase = .trace_copy;
                break :result .pending;
            },
            .trace_copy => result: {
                if (self.trace_index != self.resolved.trace.len) {
                    self.trace_items.?[self.trace_index] = .{ .symbol = self.resolved.trace[self.trace_index] };
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
        resolved: ResolvedTrace,
        location: ?spans.LocatedSpan,
    ) ErrorValueCursor {
        return if (failure.raised == null)
            .{ .ordinary = .init(allocator, failure, resolved, location) }
        else
            .{ .raised = .init(allocator, failure, resolved, location) };
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
/// The spellings a failure value needs, already interned. Qualifying a
/// module-local trace word allocates, so it happens in the resumable failure
/// driver rather than inside the value builder.
pub const ResolvedTrace = struct {
    word: ?u32 = null,
    trace: []const u32 = &.{},
};
pub fn errorValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    failure: *EclErr,
    resolved: ResolvedTrace,
    location: ?spans.LocatedSpan,
) error{OutOfMemory}!Value {
    var cursor = ErrorValueCursor.init(allocator, failure, resolved, location);
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
/// What a dispatch acquired so its resolution scope stays alive while it is
/// read, if it had to acquire anything.
///
/// One union rather than two optional fields, because there is exactly one
/// release and it must be impossible to forget half of it.
pub const ScopeBorrow = union(enum) {
    /// The activation already holds this scope: it is the chain the activation
    /// is running, or an ancestor of it, which `lazy` retained on the way down.
    /// Nothing was acquired and nothing is released.
    activation_held,
    /// A module image, acquired through its anchor. Unit-lifetime, because the
    /// body keeps running against the image long after resolution ends.
    pinned: modules.GenerationPin,
    /// A scope belonging to some other unit, reached through a value -- a
    /// quotation parked in durable state, applied here. Activation-lifetime,
    /// because unlike an image pin this borrow ends when the chain walk does.
    /// That difference is why it is not held in the unit's pin set: the unit's
    /// teardown spins on its own root's refcount *before* releasing pins, so a
    /// unit-held scope borrow could wait on itself, and two units borrowing
    /// each other could wait forever. Owning it per activation makes both
    /// unrepresentable.
    retained: *env.ScopeCell,

    pub fn deinit(self: *ScopeBorrow) void {
        switch (self.*) {
            .activation_held => {},
            .pinned => |pin| {
                var owned = pin;
                owned.deinit();
            },
            .retained => |cell| cell.releaseBorrow(),
        }
        self.* = .activation_held;
    }
};

const Eval = struct {
    code: *Header,
    ip: u32,
    /// Released when this activation retires, alongside `code`. A child that
    /// inherits this activation's scope takes its own retain rather than
    /// sharing this one, so a tail call replacing the parent cannot leave the
    /// survivor holding a pointer whose retain died.
    borrowed_scope: ?*env.ScopeCell = null,
    /// Where this body's definitions land, where its references resolve, and
    /// whose privacy and durable state it runs against. One value rather than
    /// three fields, so a construction site cannot set two of them and leave
    /// the third describing different code.
    site: ExecutionSite,
    traced_word: intern.TraceWord,
    /// Nominal authority to replace one source effect check's completion
    /// provenance. A non-tail call and every application quotation receive
    /// no authority, so their internal tail calls cannot overwrite the
    /// checked activation's authored control choice.
    effect_tail: ?EffectCheckIndex = null,
    /// Authority for the current generic application's selection boundary.
    /// Iterative continuations mint a fresh boundary per element; explicitly
    /// tail-transparent control quotations inherit the enclosing boundary.
    application_tail: ?ApplicationFrameIndex = null,
    /// This Eval was entered through a dynamic `call` while in the named
    /// application. If it completes or transfers tail control, its existing
    /// code-header ownership becomes the application's selected quotation.
    application_selection: ?ApplicationFrameIndex = null,

    /// Where this body's own definitions land, and the chain it hands to any
    /// quotation it invokes on a caller's behalf.
    pub fn scope(self: Eval) *env.Scope {
        return self.site.scope;
    }
    /// Where this body's *word references* resolve.
    pub fn resolutionScope(self: Eval) ?*env.Scope {
        return self.site.resolution_scope;
    }
    /// Whether a stamp names a scope on the chain this activation already
    /// holds -- its own resolution scope or an ancestor of it.
    ///
    /// Ancestors count because `Scope.lazy` retains its parent, so the whole
    /// chain above the activation is held by the activation itself. That makes
    /// this a proof rather than an exemption, and it is what keeps the borrow
    /// count off every ordinary dispatch: only a scope reached through a value
    /// -- a quotation parked in durable state and applied here -- is foreign.
    ///
    /// Walks outward comparing never-recycled ids, dereferencing nothing this
    /// activation does not own. Same shape as the dispatch fast path and the
    /// idiom recognizer's gate.
    pub fn chainHolds(self: Eval, stamp: u32) bool {
        if (stamp == 0) return true;
        var node: ?*env.Scope = self.site.resolution_scope;
        while (node) |link| : (node = link.parent) {
            if (@intFromEnum(link.cellId()) == stamp) return true;
        }
        return false;
    }

    /// Whose privacy and durable state this body runs against.
    pub fn home(self: Eval) ?*modules.ModuleHome {
        return self.site.home;
    }
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

/// A module construction boundary. The body always produces an image; a
/// `@defm` boundary additionally carries the symbol that image is registered
/// under the instant construction succeeds, which is what makes the combined
/// word a driver composition rather than a second publication protocol.
///
/// The symbol is unvalidated on purpose. `@defm` must behave as `@module`
/// followed by `register`, and that composition evaluates the body before any
/// name is checked, so validating early would skip a body the composition runs.
const ModuleBoundary = struct {
    image: modules.OwnedImage,
    registration: ?u32,

    fn deinit(self: ModuleBoundary) void {
        var owned = self.image;
        owned.deinit();
    }
};
const BoundaryMode = union(enum) {
    attempt: *env.Scope,
    module: ModuleBoundary,
    state: OwnedApplication,
};
const Boundary = struct {
    mode: BoundaryMode,
    stack_base: u32,
    /// The locals depth on entry. `_dl` balances the normal path; a
    /// body that fails never reaches it, so unwinding restores this instead.
    locals_base: u32,
    previous_base: u32,
    previous_boundary: ?FrameIndex,
    word: intern.TraceWord,
    fn deinit(
        self: Boundary,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.mode) {
            .module => |boundary| boundary.deinit(),
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
const SourceEffectProvenance = struct {
    candidate: OwnedCode,
    frame_index: EffectCheckIndex,
    previous: ?EffectCheckIndex,
};
const EffectProvenance = union(enum) {
    none,
    source: SourceEffectProvenance,
};
pub const EffectCheck = struct {
    expected_depth: u32,
    entry_depth: u32,
    inputs: u32,
    outputs: u32,
    word: intern.TraceWord,
    /// An anonymous after row is an input-only contract: entry consumption is
    /// still verified, the post-condition compare is skipped.
    row: bool = false,
    provenance: EffectProvenance = .none,

    fn activateSource(
        self: *EffectCheck,
        body: *Header,
        frame_index: EffectCheckIndex,
        previous: ?EffectCheckIndex,
    ) void {
        std.debug.assert(self.provenance == .none);
        self.provenance = .{ .source = .{
            .candidate = .retain(body),
            .frame_index = frame_index,
            .previous = previous,
        } };
    }
    fn replaceSourceCandidate(
        self: *EffectCheck,
        releases: *heap.ReleaseDomain,
        code: *Header,
    ) void {
        switch (self.provenance) {
            .none => unreachable,
            .source => self.provenance.source.candidate.replaceBorrowed(releases, code),
        }
    }
    fn restoreActive(self: *const EffectCheck, unit: *Unit) void {
        switch (self.provenance) {
            .none => {},
            .source => |source| {
                std.debug.assert(unit.effect_check_index == source.frame_index);
                unit.effect_check_index = source.previous;
            },
        }
    }
    fn takeCandidate(self: *EffectCheck) ?OwnedCode {
        return switch (self.provenance) {
            .none => null,
            .source => .initOwned(self.provenance.source.candidate.take()),
        };
    }
    pub fn deinit(self: *EffectCheck, releases: *heap.ReleaseDomain) void {
        switch (self.provenance) {
            .none => {},
            .source => self.provenance.source.candidate.deinit(releases),
        }
        self.provenance = .none;
    }
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
/// Opaque, non-dereferenced capability for one live application frame. The
/// Machine encodes a process-unique nonce with the frame index and validates
/// both before use; ordinary callers can neither construct nor inspect it.
pub const ApplicationProvenanceTarget = opaque {};

fn mintApplicationProvenanceNonce() error{OutOfMemory}!ApplicationProvenanceNonce {
    var next = next_application_provenance_nonce.load(.monotonic);
    while (next <= std.math.maxInt(u32)) {
        if (next_application_provenance_nonce.cmpxchgWeak(
            next,
            next + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            next = observed;
        } else return @enumFromInt(@as(u32, @intCast(next)));
    }
    return error.OutOfMemory;
}

fn encodeApplicationProvenanceTarget(
    index: ApplicationFrameIndex,
    nonce: ApplicationProvenanceNonce,
) *const ApplicationProvenanceTarget {
    comptime if (@sizeOf(usize) != 8)
        @compileError("application provenance capabilities require a 64-bit target");
    const raw = (@as(usize, @intFromEnum(nonce)) << 32) |
        @as(usize, @intFromEnum(index));
    std.debug.assert(raw != 0);
    return @ptrFromInt(raw);
}

pub const ExecutionSite = struct {
    /// Where this body's own definitions land, and the chain it hands to any
    /// quotation it invokes on a caller's behalf.
    scope: *env.Scope,
    /// Where this body's *word references* resolve: the chain the binding was
    /// defined against, never whatever environment happens to be executing.
    /// For a module word that is its image. For a core or prelude definition
    /// it is core alone, which no scope denotes — core is a terminal phase
    /// rather than a link in any chain — so `null` means "go straight to
    /// core".
    resolution_scope: ?*env.Scope,
    /// Whose privacy and durable state this body runs against. Correlated
    /// with the scopes but not derivable from them: a homeless word called
    /// from module code inherits the caller's home while resolving against its
    /// own lexical chain.
    home: ?*modules.ModuleHome,
    /// The cell id of `resolution_scope`, recorded once on entry.
    ///
    /// This is the whole of the same-scope fast path: a word stamped with this
    /// id resolves in the chain this activation is already running, so it needs
    /// no directory walk, no cell, no owner, and no liveness proof -- the
    /// activation itself is the proof. `.none` when the scope has no cell or
    /// there is no resolution scope, either of which fails the compare, which
    /// is the conservative direction.
    resolution_scope_id: env.ScopeId = .none,

    fn idOf(scope: ?*env.Scope) env.ScopeId {
        return if (scope) |resolved| resolved.cellId() else .none;
    }

    /// The base case: a unit's root activation, built from nothing.
    pub fn root(unit: *Unit) ExecutionSite {
        const scope = unit.lexicalScope();
        return .{
            .scope = scope,
            .resolution_scope = scope,
            .home = null,
            .resolution_scope_id = idOf(scope),
        };
    }

    /// Code running as one module image: the image's own definitions, then
    /// core.
    pub fn image(
        home: *modules.ModuleHome,
        access: *const modules.ExecutionAccess,
    ) ExecutionSite {
        const scope = home.scope(access);
        return .{
            .scope = scope,
            .resolution_scope = scope,
            .home = home,
            .resolution_scope_id = idOf(scope),
        };
    }

    /// A nested activation continuing the same logical execution in `scope`:
    /// a dynamic `call`, an `@attempt` child, or a resumed qualified load.
    /// A quotation resolves where its invoker runs, so both scopes are the one
    /// it was handed.
    pub fn inheriting(invoker: Eval, scope: *env.Scope) ExecutionSite {
        return .resumed(scope, invoker.home());
    }

    /// An application resuming in `scope` under its launch home. The only
    /// construction where the home does not come from a running activation,
    /// because an application's scope is decided when it launches.
    pub fn resumed(scope: *env.Scope, home: ?*modules.ModuleHome) ExecutionSite {
        return .{
            .scope = scope,
            .resolution_scope = scope,
            .home = home,
            .resolution_scope_id = idOf(scope),
        };
    }
};

pub const ApplicationProvenance = union(enum) {
    boundary,
    selected_target: *const ApplicationProvenanceTarget,
};
pub const IsolatedApplication = struct {
    quotation: *Header,
    context: *anyopaque,
    resume_fn: *const fn (*Machine, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    parent_scope: *env.Scope,
    home: ?*modules.ModuleHome,
    seeded: u32,
    provenance: ApplicationProvenance,
};

fn ApplicationAdapters(comptime Driver: type) type {
    return struct {
        fn run(
            evaluator: *Machine,
            raw: *anyopaque,
            window: StackWindow,
            site: *ApplicationContractSite,
        ) MachineError!?ApplicationStep {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            return Driver.resumeApplication(evaluator, driver, window, site);
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
        .provenance = .boundary,
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
    resume_fn: *const fn (*Machine, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    parent_scope: *env.Scope,
    home: ?*modules.ModuleHome,
    mode: ApplicationMode,
    traced_word: intern.TraceWord,
    selection: ApplicationSelection,
    provenance_nonce: ?ApplicationProvenanceNonce = null,
    fn deinit(self: ApplicationFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        var selection = self.selection;
        selection.deinit(releases);
        switch (self.mode) {
            .in_place => {},
            .isolated => |isolated| {
                isolated.child.retire();
            },
        }
        self.deinit_fn(releases, allocator, self.context);
    }
};
/// The semantic operation suspended while an unavailable qualified module is
/// materialized. Direct and dynamically constructed words resume from the
/// word they requested; operand-consuming primitives that still replay their
/// source call restore those operands before selecting `.replay`.
const QualifiedLoadContinuation = union(enum) {
    replay,
    dispatch: struct {
        word: u32,
        site: ?ErrorSite,
        trace_parent: ?intern.TraceWord,
    },
    load_only,
};
const QualifiedLoadRequest = struct {
    qualified: u32,
    continuation: QualifiedLoadContinuation,
};
pub const Frame = union(enum(u8)) {
    eval: Eval,
    effect_check: EffectCheck,
    application: ApplicationFrame,
    qualified_after_load: struct {
        loading: modules.LoadingLease,
        name: intern.ModuleName,
        path: Value,
        request: QualifiedLoadRequest,
    },
    boundary: Boundary,
    fn deinit(self: Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self) {
            .eval => |frame| releases.releaseHeader(frame.code),
            .effect_check => |owned| {
                var check = owned;
                check.deinit(releases);
            },
            .application => |frame| frame.deinit(releases, allocator),
            .qualified_after_load => |frame| {
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
    // A load-return frame owns the complete qualified-operation continuation
    // across nested source execution. Keeping that tagged state in the frame
    // makes replay-vs-dispatch ownership unrepresentable rather than relying
    // on correlated Unit fields.
    if (@sizeOf(Frame) > 104) @compileError("machine frames must remain at most 104 bytes");
}
pub const IdiomRequest = union(enum) {
    direct: struct { body: *Header, word: u32 },
    each,
    zip_with,
    fold,
    scan,
};
pub const IdiomFallback = struct {
    /// What to do if recognition declines, carried by value. Recognition holds
    /// at most one fallback at a time and the only one with any state is a core
    /// word's body and trace word, so describing the decline costs no
    /// allocation. Storing it inline also removes the question a pointer
    /// raised: with every payload here, teardown always retires fields and
    /// never frees storage.
    pub const storage_len = 32;
    storage: [storage_len]u8 align(@alignOf(usize)) = @splat(0),
    run_fn: *const fn (*Machine, ?*anyopaque) MachineError!void,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, ?*anyopaque) void,
    pub fn run(self: *IdiomFallback, evaluator: *Machine) MachineError!void {
        return self.run_fn(evaluator, &self.storage);
    }
    pub fn deinit(self: *IdiomFallback, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, &self.storage);
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
    tls_trust: ?TlsTrust = null,
    ecl_path: ?[]const u8 = null,
    project_lock: ?*const pkg_lock.ProjectLock = null,
    environ: ?*const Environ = null,
    standard_input: ?*StandardInput = null,
    idiom_mode: IdiomMode = .automatic,
    phrase_recognizer: ?PhraseRecognizer = null,
};

/// Immutable HTTPS verification inputs inherited by every Unit. The CA path
/// borrows Session-owned storage, whose lifetime encloses all Units.
pub const TlsTrust = struct {
    ca_file: []const u8,
    now: std.Io.Timestamp,
};

/// One immutable snapshot of the host environment, captured once at session
/// init. `getenv` reads only this snapshot, so a session observes one
/// deterministic environment and no primitive ever races a host `setenv`.
pub const Environ = struct {
    pub const Entry = struct { name: []const u8, value: []const u8 };

    entries: []const Entry = &.{},

    /// Resumable lookup: the environment block is host-sized rather than
    /// constant, so the scan yields on the ordinary polled budget.
    pub const LookupCursor = struct {
        entries: []const Entry,
        name: []const u8,
        index: usize = 0,

        pub fn advance(self: *LookupCursor, budget: usize) poll_api.Progress(?[]const u8) {
            std.debug.assert(budget != 0);
            var remaining = budget;
            while (remaining != 0 and self.index != self.entries.len) : (remaining -= 1) {
                const entry = self.entries[self.index];
                self.index += 1;
                if (std.mem.eql(u8, entry.name, self.name)) return .{ .complete = entry.value };
            }
            if (self.index == self.entries.len) return .{ .complete = null };
            return .pending;
        }
    };

    pub fn lookupCursor(self: *const Environ, name: []const u8) LookupCursor {
        return .{ .entries = self.entries, .name = name };
    }
};

/// Whole-stream standard input. The stream is claimable exactly once per
/// session, and only in the CLI modes where stdin is not itself the program
/// source; both refusals are ordinary `'io` errors rather than a partial
/// read of a stream something else already owns.
pub const StandardInput = struct {
    pub const Availability = enum { data, program_source };
    pub const Claim = enum { granted, program_source, already_read };

    availability: Availability,
    claimed: std.atomic.Value(bool) = .init(false),

    pub fn init(availability: Availability) StandardInput {
        return .{ .availability = availability };
    }
    pub fn claim(self: *StandardInput) Claim {
        if (self.availability == .program_source) return .program_source;
        if (self.claimed.swap(true, .seq_cst)) return .already_read;
        return .granted;
    }
};

fn IdiomFallbackAdapters(comptime Payload: type) type {
    return struct {
        fn run(evaluator: *Machine, raw: ?*anyopaque) MachineError!void {
            const payload: *Payload = @ptrCast(@alignCast(raw.?));
            return Payload.run(evaluator, payload);
        }

        fn deinit(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: ?*anyopaque,
        ) void {
            const payload: *Payload = @ptrCast(@alignCast(raw.?));
            heap.deinitDriverFields(releases, allocator, payload);
        }
    };
}

/// Copies a fallback payload into the fallback itself. The payload must own its
/// fields and hold no pointer into itself, because the value moves with the
/// fallback rather than staying at one address.
pub fn typedIdiomFallback(payload: anytype) IdiomFallback {
    const Payload = @TypeOf(payload);
    if (@typeInfo(Payload) != .@"struct")
        @compileError("idiom fallback payload must be a struct value");
    if (@sizeOf(Payload) > IdiomFallback.storage_len)
        @compileError(@typeName(Payload) ++ " exceeds the inline idiom fallback storage");
    if (@alignOf(Payload) > @alignOf(usize))
        @compileError(@typeName(Payload) ++ " exceeds the inline idiom fallback alignment");
    _ = comptime heap.validateDriverOwnership(Payload);
    const adapters = IdiomFallbackAdapters(Payload);
    var result: IdiomFallback = .{
        .run_fn = adapters.run,
        .deinit_fn = adapters.deinit,
    };
    const target: *Payload = @ptrCast(@alignCast(&result.storage));
    target.* = payload;
    return result;
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
    trace_parent: ?intern.TraceWord = null,

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

        /// Teardown for a driver living in the unit's inline slot: the same
        /// field ownership, without the destroy that storage never had.
        /// Releasing the slot belongs to the caller, which knows the unit:
        /// `clearWorkDriver` frees it, and unit teardown does not bother
        /// because it invalidates the unit immediately afterward.
        fn deinitInline(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.deinitDriverFields(releases, allocator, driver);
        }
    };
}

/// Opt-in inline driver storage. A driver declares `inline_driver` to be
/// constructed in the unit's slot instead of the allocator; the declaration is
/// checked here rather than assumed, so a driver that outgrows the slot or
/// stops owning its fields fails the build instead of silently reverting to an
/// allocation.
///
/// What the compiler cannot check is the one rule that decides whether the
/// annotation helps: **declare it on short-lived drivers, never on long-lived
/// ones.** There is a single slot per unit and its holder keeps it until the
/// driver is retired, so a driver that spans an iteration would hold the slot
/// for the iteration's whole length and push every driver started inside it
/// back to the allocator. That is worse than not declaring it at all, and it
/// is invisible: the annotation still compiles, the slot is still used, and the
/// allocations simply move rather than disappear. A combinator's own iteration
/// driver is the shape to leave alone; the leaf drivers it starts per element
/// are the shape this is for.
fn inlineDriverCapable(comptime Driver: type) bool {
    if (!@hasDecl(Driver, "inline_driver")) return false;
    if (heap.validateDriverOwnership(Driver) != .fields)
        @compileError(@typeName(Driver) ++ " inline driver storage requires field ownership");
    if (@sizeOf(Driver) > Unit.driver_slot_len)
        @compileError(@typeName(Driver) ++ " exceeds the unit inline driver slot");
    if (@alignOf(Driver) > Unit.driver_slot_align)
        @compileError(@typeName(Driver) ++ " exceeds the unit inline driver alignment");
    return true;
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

        /// Takes ownership of a pin acquired elsewhere -- the borrow at
        /// dispatch. Deduplicates the same way `pin` does, releasing the
        /// incoming reference when one is already held, so adopting is
        /// idempotent per owner.
        fn adopt(
            self: *LifetimeGuard,
            allocator: std.mem.Allocator,
            owned: *modules.GenerationPin,
        ) error{OutOfMemory}!void {
            const pins = &self.state.active;
            for (pins.items) |pinned| if (pinned.sameOwner(owned.*)) {
                owned.deinit();
                return;
            };
            errdefer owned.deinit();
            try pins.append(allocator, owned.*);
            owned.* = .consumed;
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
    /// The innermost active source effect check. Effect-check frames form an
    /// intrusive chain so nested checks restore their predecessor exactly.
    effect_check_index: ?EffectCheckIndex = null,
    pending: ?EclErr = null,
    last_error: ?Value = null,
    exit_status: ?u8 = null,
    idiom_hits: u64 = 0,
    scheduler: ?*const anyopaque = null,
    task_scope: ?*anyopaque = null,
    is_root_unit: bool = true,
    /// For a child unit, the `@` word that constructed it.
    constructor: UnitConstructor = .spawn,
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
    active_word: intern.TraceWord = no_word,
    /// Scratch for spelling one qualified trace word in a diagnostic message.
    /// A module-local word's spelling depends on the invoking registration, so
    /// there is no interned string to point at. Written before it is read on
    /// every path; zeroed rather than left `undefined` so no default here can
    /// become a read of uninitialized bytes.
    word_scratch: [intern.trace_word_bytes]u8 = @splat(0),
    /// Storage for the one work driver a unit runs at a time. `installDriver`
    /// accepts a driver only from `idle` or `yielded`, so a second live driver
    /// is not representable; a driver that has detached but not yet destroyed
    /// itself can still be holding the slot when the next one starts, and that
    /// one falls back to the allocator. Correctness never depends on the slot
    /// being free — only the allocation does.
    driver_slot: [driver_slot_len]u8 align(driver_slot_align),
    driver_slot_busy: bool = false,
    /// One parked isolated application scope. A combinator retires the scope
    /// for element N and immediately builds one for element N+1 over the same
    /// parent; when the retired one never bound anything it is indistinguishable
    /// from the new one, so it is kept here instead of being freed and
    /// reallocated per element.
    spare_scope: ?*env.Scope = null,
    /// Head-binder locals. A binder's names live here for the length of the
    /// quotation body that introduced them, never on the operand stack, so a
    /// body's declared stack effect describes its operands alone and an
    /// ordinary form between two local reads needs no shuffling to see past
    /// them. Reads are top-relative: the last name a binder introduced is
    /// index 0.
    locals: std.ArrayList(Value) = .empty,
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
            // SAFETY: storage, not state. `driver_slot_busy` is the only
            // thing that says a driver lives here, and every read of the slot
            // goes through `acquireInlineDriver`, which writes the whole
            // driver before the pointer escapes.
            .driver_slot = undefined,
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

    /// The chain a homeless binding — a primitive or an embedded prelude
    /// definition — resolves against. It is the session root over core, so
    /// session-level redefinition still reaches prelude bodies while a module
    /// body executing further down the stack does not.
    pub fn lexicalScope(self: *Unit) *env.Scope {
        return self.execution_scope orelse self.rootScope();
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
                self.deinitPoppedFrame(frame);
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

    /// Adopts the reference the dispatch's borrow already acquired, rather than
    /// acquiring a second one for the same image.
    pub fn adoptGeneration(
        self: *Unit,
        owned: *modules.GenerationPin,
    ) error{OutOfMemory}!void {
        try self.lifetime.adopt(self.allocator, owned);
    }
    /// Sized to the drivers that opt in, checked by `inlineDriverCapable`.
    /// Raising it trades unit footprint, which every task pays, for covering a
    /// wider driver; measure before doing so.
    pub const driver_slot_len = 640;
    pub const driver_slot_align = 16;

    fn acquireInlineDriver(self: *Unit, comptime Driver: type) ?*Driver {
        if (self.driver_slot_busy) return null;
        self.driver_slot_busy = true;
        return @ptrCast(@alignCast(&self.driver_slot));
    }

    fn ownsInlineDriver(self: *const Unit, driver: *const anyopaque) bool {
        return @intFromPtr(driver) == @intFromPtr(&self.driver_slot);
    }

    /// Drops any parked application scope. A parked scope holds a reference on
    /// its parent, so keeping one across a scheduler turn would pin whatever
    /// that parent belongs to -- a module generation another task is waiting to
    /// see reclaimed, for instance. The parking is an optimization within one
    /// slice and must not outlive it.
    pub fn dropSpareScope(self: *Unit) void {
        if (self.spare_scope) |spare| {
            self.spare_scope = null;
            spare.retire();
        }
    }

    fn releaseInlineDriver(self: *Unit) void {
        std.debug.assert(self.driver_slot_busy);
        self.driver_slot_busy = false;
    }

    /// True while the inline slot holds a live driver. Tests assert on this:
    /// a slot that is never released is not a failure any behaviour can see,
    /// only a silent return to allocating.
    pub fn inlineDriverBusy(self: *const Unit) bool {
        return self.driver_slot_busy;
    }

    pub fn deinit(self: *Unit) void {
        if (self.current) |current| self.releases.releaseHeader(current.code);
        while (self.frames.pop()) |frame| self.deinitPoppedFrame(frame);
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
        for (self.locals.items) |item| self.releases.releaseValue(item);
        self.locals.deinit(self.allocator);
        if (self.spare_scope) |spare| spare.retire();
        self.lifetime.deinit(self.releases, self.allocator);
        self.* = undefined;
    }

    fn deinitPoppedFrame(self: *Unit, popped: Frame) void {
        var frame = popped;
        if (frame == .effect_check) frame.effect_check.restoreActive(self);
        frame.deinit(self.releases, self.allocator);
    }
};
/// One driver for a primitive that must encode a path argument to bytes before
/// it can act. Encoding and its failure are the same work whatever follows, so
/// the action is the only thing that varies; the ownership order — take the
/// path, take the value, retire, then act — is stated once here rather than
/// copied per primitive.
pub fn PathActionDriver(
    comptime action: fn (*Machine, []u8, Value) MachineError!void,
) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;
        path_value: heap.Owned(Value),
        encoder: heap.Owned(kernel_storage.ToUtf8Cursor),
        path: ?heap.Owned([]u8) = null,

        pub fn advance(evaluator: *Machine, self: *Self) MachineError!WorkProgress {
            try evaluator.pollKernel();
            if (self.path == null) switch (self.encoder.borrowMut().advance(kernel_poll_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCodepoint => return evaluator.fail(.domain, "path contains an invalid Unicode scalar"),
            }) {
                .pending => return .yielded,
                .complete => |path| self.path = .init(path),
            };
            const path = self.path.?.take();
            const path_value = self.path_value.take();
            self.path = null;
            evaluator.retireDriver(self);
            try action(evaluator, path, path_value);
            return .detached;
        }
    };
}

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
        return self.unit.current.?.scope();
    }
    pub fn sourceCursor(self: *const Machine, header: *Header) spans.SpanArchive.SourceCursor {
        return self.unit.archive.sourceCursor(header);
    }
    pub fn currentHome(self: *const Machine) ?*modules.ModuleHome {
        return self.unit.current.?.home();
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
            .deinit_fn = if (comptime inlineDriverCapable(Driver))
                (if (self.unit.ownsInlineDriver(context)) adapters.deinitInline else adapters.deinit)
            else
                adapters.deinit,
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
        if (comptime inlineDriverCapable(Driver)) {
            if (self.unit.acquireInlineDriver(Driver)) |slot| {
                slot.* = pending;
                self.installDriver(slot);
                return;
            }
        }
        const driver = self.unit.allocator.create(Driver) catch |err| {
            heap.deinitDriverFields(self.unit.releases, self.unit.allocator, &pending);
            return err;
        };
        driver.* = pending;
        self.installDriver(driver);
    }

    /// Destroy a driver that may be living in the unit's inline slot. A driver
    /// that opts into inline storage must retire itself through this rather
    /// than `heap.destroyDriver`, which would hand slot memory to the
    /// allocator.
    pub fn finishDriver(self: *Machine, driver: anytype) void {
        if (self.unit.ownsInlineDriver(driver)) {
            heap.deinitDriverFields(self.unit.releases, self.unit.allocator, driver);
            self.unit.releaseInlineDriver();
            return;
        }
        heap.destroyDriver(self.unit.releases, self.unit.allocator, driver);
    }
    /// Moves the top `count` operands into the unit's head-binder locals, the
    /// binder's first name ending on top. The operand stack is machine-owned,
    /// so the move lives here and the primitive keeps only its validation.
    pub fn bindLocals(self: *Machine, count: usize) error{OutOfMemory}!void {
        try self.unit.locals.ensureUnusedCapacity(self.unit.allocator, count);
        const base = self.unit.stack.items.len - count;
        var remaining = count;
        while (remaining != 0) {
            remaining -= 1;
            self.unit.locals.appendAssumeCapacity(self.unit.stack.items[base + remaining]);
        }
        self.unit.stack.shrinkRetainingCapacity(base);
    }

    pub fn localDepth(self: *const Machine) usize {
        return self.unit.locals.items.len;
    }

    pub fn readLocal(self: *Machine, index: usize) error{OutOfMemory}!void {
        const depth = self.unit.locals.items.len;
        try self.pushBorrowed(self.unit.locals.items[depth - 1 - index]);
    }

    pub fn unbindLocals(self: *Machine, count: usize) void {
        for (0..count) |_| {
            const item = self.unit.locals.pop().?;
            self.releaseDomain().releaseValue(item);
        }
    }

    /// Detach the installed continuation and destroy it. A driver that has
    /// finished its own work ends exactly this way, and routing every one of
    /// them through a single place is what keeps inline-slot storage from ever
    /// reaching the allocator.
    pub fn retireDriver(self: *Machine, driver: anytype) void {
        self.detachWorkDriver(driver);
        self.finishDriver(driver);
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
    /// Start the ordinary qualified-name loader without executing or importing
    /// an export. The caller supplies an initialized root and drives it through
    /// `runInitializedRoot`; reflection and completion use this same path.
    pub fn loadModuleOnly(self: *Machine, name: intern.ModuleName) MachineError!void {
        self.unit.active_word = .plain(intern.moduleId(name));
        try self.autoLoadModule(name, .{
            .qualified = intern.moduleId(name),
            .continuation = .load_only,
        });
    }

    /// A reflection primitive already consumed its symbol before discovering
    /// a cold qualified module. Restore that operand and rewind the primitive
    /// call, then use the same loader/retry protocol as executable dispatch.
    pub fn retryQualifiedOperandAfterLoad(
        self: *Machine,
        requested: u32,
        outcome: ResolutionOutcome,
    ) MachineError!WorkProgress {
        if (self.unit.current == null or self.unit.inherited.registry == null)
            return self.undefinedNameIn(requested, .qualified);
        const name = switch (outcome) {
            .unknown_module_prefix => |prefix| intern.internModuleName(prefix) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => return self.undefinedNameIn(requested, .qualified),
            },
            .unregistered_module => |name| name,
            .unresolved => |chain| return self.undefinedNameIn(requested, chain),
            .resolved => unreachable,
        };
        try self.pushBorrowed(.{ .symbol = requested });
        self.unit.current.?.ip = self.unit.active_index;
        try self.autoLoadModule(name, .{
            .qualified = requested,
            .continuation = .replay,
        });
        return .detached;
    }
    /// An import consumes two symbols before discovering a cold qualified
    /// module. Restore them in source order, rewind the primitive, and share
    /// the ordinary qualified-name auto-load/retry path.
    pub fn retryImportAfterLoad(
        self: *Machine,
        binding: u32,
        original: u32,
        outcome: ResolutionOutcome,
    ) MachineError!WorkProgress {
        if (self.unit.current == null or self.unit.inherited.registry == null)
            return self.undefinedNameIn(original, .qualified);
        const name = switch (outcome) {
            .unknown_module_prefix => |prefix| intern.internModuleName(prefix) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => return self.undefinedNameIn(original, .qualified),
            },
            .unregistered_module => |name| name,
            .unresolved => |chain| return self.undefinedNameIn(original, chain),
            .resolved => unreachable,
        };
        try self.pushBorrowed(.{ .symbol = original });
        try self.pushBorrowed(.{ .symbol = binding });
        self.unit.current.?.ip = self.unit.active_index;
        try self.autoLoadModule(name, .{
            .qualified = original,
            .continuation = .replay,
        });
        return .detached;
    }
    /// A completed auto-load registers the module before resuming the tagged
    /// qualified operation. The requested spelling also identifies a
    /// misspelled export in the final undefined-word error.
    fn autoLoadModule(
        self: *Machine,
        name: intern.ModuleName,
        request: QualifiedLoadRequest,
    ) MachineError!void {
        const registry = self.unit.inherited.registry orelse return self.undefinedModule(intern.moduleId(name));
        try self.startDriver(AutoLoadDriver{
            .name = name,
            .request = request,
            .cursor = registry.beginLoadingCursor(name, .of(self.unit)),
        });
    }
    const AutoLoadDriver = struct {
        const FileKind = enum { source, native };
        const FilenameTarget = enum { component_start, candidate, locked_candidate };

        name: intern.ModuleName,
        request: QualifiedLoadRequest,
        cursor: modules.Registry.BeginLoadingCursor,
        embedded: ?stdlib.Entry = null,
        loading: ?heap.Owned(modules.LoadingLease) = null,
        lock_lookup: ?heap.Owned(pkg_lock.LookupCursor) = null,
        locked_package: ?[]const u8 = null,
        locked_store: ?[]const u8 = null,
        locked_candidate: bool = false,
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
        registration: ?heap.Owned(modules.Registry.AcquireCursor) = null,
        phase: enum {
            begin,
            registered,
            lock_lookup,
            locked_store,
            filename,
            component_start,
            component_end,
            candidate,
            access,
            path_value,
            transfer,
        } = .begin,

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
            const directory = if (self.locked_candidate)
                self.locked_store.?
            else legacy: {
                const search = evaluator.unit.inherited.ecl_path.?;
                break :legacy search[self.component_start..self.component_end];
            };
            self.separator = directory.len != 0 and !std.fs.path.isSep(directory[directory.len - 1]);
            var length = std.math.add(usize, directory.len, self.filename.?.borrow().len) catch
                return error.OutOfMemory;
            if (self.separator) length = std.math.add(usize, length, 1) catch
                return error.OutOfMemory;
            self.candidate = .init(try evaluator.unit.allocator.alloc(u8, length));
            self.phase = .candidate;
        }
        /// Embedded modules reuse the candidate slot for their provenance
        /// name, so the existing `.path_value` phase materializes exactly the
        /// value the load continuation reports as `'path`.
        fn beginEmbedded(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            entry: stdlib.Entry,
        ) error{OutOfMemory}!void {
            const provenance = switch (entry) {
                .source => |source| source.name,
                .native, .builtin => intern.get(intern.moduleId(self.name)),
            };
            self.candidate = .init(try evaluator.unit.allocator.dupe(u8, provenance));
            self.embedded = entry;
            self.path_materializer = .init(.init(
                evaluator.unit.allocator,
                self.candidate.?.borrow(),
            ));
            self.phase = .path_value;
        }
        /// The module is already registered, so this driver publishes nothing.
        fn finishWithoutLoading(
            self: *AutoLoadDriver,
            evaluator: *Machine,
        ) MachineError!WorkProgress {
            self.loading.?.borrowMut().finish();
            return continueQualifiedRequest(evaluator, self, self.request);
        }
        fn notFound(self: *AutoLoadDriver, evaluator: *Machine) MachineError {
            return evaluator.undefinedWordIn(self.request.qualified, .qualified);
        }
        fn sourceCompletion(self: *AutoLoadDriver) SourceCompletion {
            return .{ .register = .{
                .loading = self.loading.?.borrowMut().move(),
                .name = self.name,
                .path = self.path_value.?.take(),
                .request = self.request,
            } };
        }
        pub fn advance(evaluator: *Machine, self: *AutoLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            var budget: usize = kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.phase) {
                .begin => switch (try self.cursor.advance()) {
                    .pending => {},
                    .complete => |outcome| switch (outcome) {
                        .cycle => return evaluator.failFmt(
                            .domain,
                            "recursive auto-load of module `{s}`",
                            .{intern.get(intern.moduleId(self.name))},
                        ),
                        // Another unit is loading this name. Wait for it
                        // rather than publishing a second copy; the recheck
                        // below is what makes the winner's work count.
                        .contended => {
                            self.cursor.deinit();
                            self.cursor = evaluator.unit.inherited.registry.?.beginLoadingCursor(
                                self.name,
                                .of(evaluator.unit),
                            );
                            return .yielded;
                        },
                        .granted => |lease| {
                            self.loading = .init(lease);
                            self.registration = .init(
                                evaluator.unit.inherited.registry.?.acquireCursor(self.name),
                            );
                            self.phase = .registered;
                        },
                    },
                },
                // A load that raced a winner has nothing left to publish: its
                // tagged operation resumes against the winner's module.
                .registered => switch (self.registration.?.borrowMut().advance()) {
                    .pending => {},
                    .complete => |maybe_generation| {
                        self.registration.?.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        self.registration = null;
                        if (maybe_generation) |generation| {
                            var lease = generation;
                            lease.deinit();
                            return self.finishWithoutLoading(evaluator);
                        }
                        // The embedded manifest is consulted before the
                        // search path: a stdlib name resolves with no host IO
                        // and no ECL_PATH, and no path module can shadow one.
                        if (stdlib.find(intern.get(intern.moduleId(self.name)))) |entry| {
                            try self.beginEmbedded(evaluator, entry);
                            continue;
                        }
                        if (evaluator.unit.inherited.project_lock) |project_lock| {
                            self.lock_lookup = .init(project_lock.lookupCursor(
                                intern.get(intern.moduleId(self.name)),
                            ));
                            self.phase = .lock_lookup;
                            continue;
                        }
                        if (evaluator.unit.inherited.host_io == null or evaluator.unit.inherited.ecl_path == null)
                            return self.notFound(evaluator);
                        try self.beginFilename(evaluator, .source, .component_start);
                    },
                },
                .lock_lookup => switch (self.lock_lookup.?.borrowMut().advance()) {
                    .pending => {},
                    .complete => |outcome| {
                        self.lock_lookup.?.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        self.lock_lookup = null;
                        switch (outcome) {
                            .invalid => |message| return evaluator.fail(.io, message),
                            .unmatched => {
                                if (evaluator.unit.inherited.host_io == null or
                                    evaluator.unit.inherited.ecl_path == null)
                                {
                                    return self.notFound(evaluator);
                                }
                                try self.beginFilename(evaluator, .source, .component_start);
                            },
                            .matched => |match| {
                                self.locked_package = match.package;
                                self.locked_store = match.store_dir;
                                if (match.store_dir == null) return evaluator.failFmt(
                                    .io,
                                    "locked package `{s}` has no package store; set ECL_CACHE, XDG_CACHE_HOME, or HOME before running `ecl pkg sync`",
                                    .{match.package},
                                );
                                self.phase = .locked_store;
                            },
                        }
                    },
                },
                .locked_store => {
                    const info = std.Io.Dir.cwd().statFile(
                        evaluator.unit.inherited.host_io.?,
                        self.locked_store.?,
                        .{ .follow_symlinks = false },
                    ) catch |err| switch (err) {
                        error.FileNotFound => return evaluator.failFmt(
                            .io,
                            "locked package `{s}` is missing from the package store; run `ecl pkg sync`",
                            .{self.locked_package.?},
                        ),
                        else => return evaluator.failFmt(
                            .io,
                            "cannot inspect locked package `{s}` in the package store: {s}; run `ecl pkg sync`",
                            .{ self.locked_package.?, @errorName(err) },
                        ),
                    };
                    if (info.kind != .directory) return evaluator.failFmt(
                        .io,
                        "locked package `{s}` is not a real package-store directory; run `ecl pkg sync`",
                        .{self.locked_package.?},
                    );
                    self.locked_candidate = true;
                    try self.beginFilename(evaluator, .source, .locked_candidate);
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
                        .candidate, .locked_candidate => try self.beginCandidate(evaluator),
                    }
                },
                .component_start => {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    if (self.search_index == search.len) return self.notFound(evaluator);
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
                    const directory = if (self.locked_candidate)
                        self.locked_store.?
                    else legacy: {
                        const search = evaluator.unit.inherited.ecl_path.?;
                        break :legacy search[self.component_start..self.component_end];
                    };
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
                            if (self.locked_candidate) return evaluator.failFmt(
                                .undefined_word,
                                "locked module `{s}` is absent from package `{s}`",
                                .{
                                    intern.get(intern.moduleId(self.name)),
                                    self.locked_package.?,
                                },
                            );
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
                    if (self.embedded) |entry| return self.transferEmbedded(evaluator, entry);
                    if (self.file_kind == .native) return self.transferNative(evaluator);
                    const candidate = self.candidate.?.take();
                    const completion = self.sourceCompletion();
                    self.candidate = null;
                    self.loading = null;
                    self.path_value = null;
                    evaluator.retireDriver(self);
                    try evaluator.fileSourceOwned(candidate, null, completion);
                    return .detached;
                },
            };
            return .yielded;
        }
        /// The manifest owns constant bytes, and `sourceOwned` frees what it
        /// is given, so the text is duped for the reader to consume. A linked
        /// descriptor needs no transport at all: `startStatic` publishes it
        /// through the same validate/publish/commit phases as a dynamic
        /// image, with a no-op image pin.
        fn transferEmbedded(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            entry: stdlib.Entry,
        ) MachineError!WorkProgress {
            const text = switch (entry) {
                .source => |source| try evaluator.unit.allocator.dupe(u8, source.text),
                .native => |descriptor| return self.transferStatic(evaluator, descriptor),
                .builtin => |words| return self.transferBuiltin(evaluator, words),
            };
            const source_name = self.candidate.?.take();
            const completion = self.sourceCompletion();
            self.candidate = null;
            self.loading = null;
            self.path_value = null;
            evaluator.retireDriver(self);
            try evaluator.sourceOwned(source_name, text, completion);
            return .detached;
        }
        fn transferBuiltin(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            words: []const env.BuiltinWord,
        ) MachineError!WorkProgress {
            // The candidate is created before ownership moves: struct-literal
            // fields evaluate in order, so a failure here would otherwise
            // strand the lease and path this driver had already taken.
            const publication = try modules.Registry.BuiltinCandidateCursor.init(
                evaluator.unit.inherited.registry.?,
                words,
            );
            // No errdefer: from here nothing fails until `startDriver`, which
            // disposes the whole uninstalled driver's owned fields itself.
            const next = BuiltinLoadDriver{
                .name = self.name,
                .request = self.request,
                .loading = .init(self.loading.?.take()),
                .path = .init(self.path_value.?.take()),
                .publication = .init(publication),
            };
            self.loading = null;
            self.path_value = null;
            evaluator.retireDriver(self);
            try evaluator.startDriver(next);
            return .detached;
        }
        fn transferStatic(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            descriptor: *const native_abi.Descriptor,
        ) MachineError!WorkProgress {
            const loader_authority = evaluator.unit.inherited.native_loader orelse
                return evaluator.fail(.io, "native module loader is unavailable");
            const loader = switch (loader_authority.startStatic(self.name, descriptor)) {
                .failure => |failure| {
                    const failed = evaluator.fail(.io, failure.text());
                    evaluator.unit.pending.?.addData(.path, self.path_value.?.borrow());
                    return failed;
                },
                .loading => |loading| loading,
            };
            const next = NativeLoadDriver{
                .name = self.name,
                .request = self.request,
                .loader = .init(loader),
                .loading = .init(self.loading.?.take()),
                .path = .init(self.path_value.?.take()),
            };
            self.loading = null;
            self.path_value = null;
            evaluator.retireDriver(self);
            try evaluator.startDriver(next);
            return .detached;
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
                .request = self.request,
                .loader = .init(loader),
                .loading = .init(self.loading.?.take()),
                .path = .init(self.path_value.?.take()),
            };
            evaluator.retireDriver(self);
            try evaluator.startDriver(next);
            return .detached;
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    /// Publishes a builtin-backed module through the same candidate/commit
    /// protocol as a native one; only the definition source differs.
    const BuiltinLoadDriver = struct {
        name: intern.ModuleName,
        request: QualifiedLoadRequest,
        loading: heap.Owned(modules.LoadingLease),
        path: heap.Owned(Value),
        publication: heap.Owned(modules.Registry.BuiltinCandidateCursor),
        candidate: ?heap.Owned(modules.SealedImage) = null,
        commit: ?heap.Owned(modules.Registry.RegistrationCursor) = null,

        pub fn advance(evaluator: *Machine, self: *BuiltinLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            if (self.commit == null) {
                if (self.candidate == null) {
                    switch (self.publication.borrowMut().advance() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidName => return evaluator.fail(
                            .contract,
                            "builtin module declares an invalid word name",
                        ),
                    }) {
                        .pending => return .yielded,
                        .complete => |candidate| {
                            var built = candidate;
                            self.candidate = .init(built.seal());
                            return .yielded;
                        },
                    }
                }
                self.commit = .init(evaluator.unit.inherited.registry.?.registrationCursor(
                    self.candidate.?.borrow().ref(),
                    self.name,
                    &evaluator.unit.turn_authority,
                ));
                return .yielded;
            }
            switch (self.commit.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return evaluator.failFmt(
                    .io,
                    "cannot publish builtin module `{s}`: {s}",
                    .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
                ),
            }) {
                .pending => return .yielded,
                .complete => {},
            }
            self.commit.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
            self.commit = null;
            return verifyPublishedModule(
                evaluator,
                self,
                self.name,
                &self.loading,
                &self.path,
                self.request,
            );
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    const NativeLoadDriver = struct {
        name: intern.ModuleName,
        request: QualifiedLoadRequest,
        loader: heap.Owned(native_module.LoadCursor),
        loading: heap.Owned(modules.LoadingLease),
        path: heap.Owned(Value),
        instance: ?heap.Owned(*native_module.ModuleInstance) = null,
        publication: ?heap.Owned(modules.Registry.NativeCandidateCursor) = null,
        candidate: ?heap.Owned(modules.SealedImage) = null,
        commit: ?heap.Owned(modules.Registry.RegistrationCursor) = null,
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
                        var built = candidate;
                        self.candidate = .init(built.seal());
                        self.commit = .init(evaluator.unit.inherited.registry.?.registrationCursor(
                            self.candidate.?.borrow().ref(),
                            self.name,
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
                        return verifyPublishedModule(
                            evaluator,
                            self,
                            self.name,
                            &self.loading,
                            &self.path,
                            self.request,
                        );
                    },
                },
            }
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
        /// Registration only: the source runs, then the loading lease and
        /// tagged qualified operation transfer to the return frame.
        register: struct {
            loading: ?modules.LoadingLease,
            name: intern.ModuleName,
            path: ?Value,
            request: QualifiedLoadRequest,
        },

        pub fn deinit(self: *SourceCompletion, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .push, .call => {},
                .register => |*register| {
                    if (register.loading) |*loading| loading.deinit();
                    if (register.path) |path| releases.releaseValue(path);
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
                    if (self.reader_state == null) self.reader_state = evaluator.unit.archive.readCursor(
                        self.source_name.borrow(),
                        self.source.borrow(),
                        &self.diag,
                        @intFromEnum(try evaluator.unit.environment.scopeIdFor(
                            evaluator.unit.lexicalScope(),
                        )),
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
                    self.materializer = evaluator.unit.archive.rootMaterializer(self.parsed.?.values());
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
                .absorb => switch (self.absorber.?.advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidProvenance => @panic("archive-bound source reader produced foreign provenance"),
                }) {
                    .pending => {},
                    .complete => {
                        std.debug.assert(self.absorber.?.deinit() == .archive_owned);
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
                        .register => |*register| {
                            const site = ExecutionSite.inheriting(
                                evaluator.unit.current.?,
                                evaluator.unit.current.?.scope(),
                            );
                            heap.incRef(self.root_header.?);
                            const preserves_caller = switch (register.request.continuation) {
                                .replay, .dispatch => true,
                                .load_only => false,
                            };
                            _ = (if (preserves_caller)
                                evaluator.suspendCurrentForQualifiedLoad()
                            else
                                evaluator.suspendCurrent()) catch {
                                evaluator.releaseDomain().releaseHeader(self.root_header.?);
                                return error.OutOfMemory;
                            };
                            var continuation = OwnedFrame.init(.{ .qualified_after_load = .{
                                .loading = register.loading.?.move(),
                                .name = register.name,
                                .path = register.path.?,
                                .request = register.request,
                            } });
                            defer continuation.deinit(evaluator.releaseDomain(), self.allocator);
                            register.loading = null;
                            register.path = null;
                            evaluator.appendFrame(&continuation) catch {
                                evaluator.releaseDomain().releaseHeader(self.root_header.?);
                                return error.OutOfMemory;
                            };
                            evaluator.unit.current = .{
                                .code = self.root_header.?,
                                .ip = 0,
                                .site = site,
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
                    if (self.absorber) |*absorber| {
                        if (absorber.deinit() == .archive_owned) self.root = null;
                    }
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
        return self.fileTransferOwned(path, path_value, .{ .source = .call });
    }
    /// Consumes `path`, `path_value`, and `transfer` on success and failure.
    pub fn slurpFileOwned(self: *Machine, path: []u8, path_value: Value) MachineError!void {
        return self.fileTransferOwned(path, path_value, .text);
    }
    fn fileSourceOwned(
        self: *Machine,
        path: []u8,
        path_value: ?Value,
        completion: SourceCompletion,
    ) MachineError!void {
        return self.fileTransferOwned(path, path_value, .{ .source = completion });
    }
    fn fileTransferOwned(
        self: *Machine,
        path: []u8,
        path_value: ?Value,
        transfer: FileTransfer,
    ) MachineError!void {
        if (self.unit.inherited.host_io == null) {
            const failure = self.fail(.io, "filesystem access is unavailable");
            if (path_value) |item|
                self.unit.pending.?.addData(.path, item)
            else if (transfer.diagnosticPath()) |item|
                self.unit.pending.?.addData(.path, item);
            self.unit.allocator.free(path);
            if (path_value) |item| self.releaseDomain().releaseValue(item);
            var transfer_cleanup = transfer;
            transfer_cleanup.deinit(self.releaseDomain());
            return failure;
        }
        try self.startDriver(FileSourceDriver{
            .allocator = self.unit.allocator,
            .path = .init(path),
            .path_value = if (path_value) |item| .init(item) else null,
            .transfer = .init(transfer),
        });
    }
    /// What one read file's bytes become. Both arms are ordinary results of
    /// the same open/size/read pipeline, so only the terminal handoff differs
    /// and no second file driver has to repeat the bounded read phases.
    const FileTransfer = union(enum) {
        /// Hand the bytes to the reader as source text.
        source: SourceCompletion,
        /// Materialize the bytes as one string on the operand stack.
        text,

        pub fn deinit(self: *FileTransfer, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .source => |*completion| completion.deinit(releases),
                .text => {},
            }
            self.* = undefined;
        }
        fn diagnosticPath(self: FileTransfer) ?Value {
            return switch (self) {
                .source => |completion| switch (completion) {
                    .register => |register| register.path,
                    .push, .call => null,
                },
                .text => null,
            };
        }
    };
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
        transfer: heap.Owned(FileTransfer),
        open_file: ?heap.Owned(OpenFile) = null,
        file_reader: ?std.Io.File.Reader = null,
        source: ?heap.Owned([]u8) = null,
        text: ?heap.Owned(kernel_storage.Utf8Materializer) = null,
        offset: usize = 0,
        phase: enum { open, size, read, transfer, text } = .open,

        fn diagnosticPath(self: *FileSourceDriver) ?Value {
            if (self.path_value) |*item| return item.borrow();
            return self.transfer.borrow().diagnosticPath();
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
                    switch (self.transfer.borrow()) {
                        .text => {
                            self.text = .init(.init(self.allocator, self.source.?.borrow()));
                            self.phase = .text;
                            return .yielded;
                        },
                        .source => {},
                    }
                    const path = self.path.take();
                    const source = self.source.?.take();
                    const completion = self.transfer.take().source;
                    self.source = null;
                    if (self.path_value) |*item| item.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    self.path_value = null;
                    evaluator.retireDriver(self);
                    try evaluator.sourceOwned(path, source, completion);
                    return .detached;
                },
                .text => switch (self.text.?.borrowMut().advance(kernel_poll_quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return self.failIo(evaluator, "file is not valid UTF-8"),
                }) {
                    .pending => return .yielded,
                    .complete => |text| {
                        self.text.?.borrowMut().deinit();
                        self.text = null;
                        return .{ .output = text };
                    },
                },
            }
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    /// Consumes `path`, `path_value`, and `contents` on success and failure.
    /// Truncate-and-replace with no temporary file: a failure part-way
    /// through can leave a partial file, which the caller sees as `'io`.
    pub fn writeFileOwned(
        self: *Machine,
        path: []u8,
        path_value: Value,
        contents: []u8,
    ) MachineError!void {
        if (self.unit.inherited.host_io == null) {
            const failure = self.fail(.io, "filesystem access is unavailable");
            self.unit.pending.?.addData(.path, path_value);
            self.unit.allocator.free(path);
            self.unit.allocator.free(contents);
            self.releaseDomain().releaseValue(path_value);
            return failure;
        }
        try self.startDriver(FileWriteDriver{
            .path = .init(path),
            .path_value = .init(path_value),
            .contents = .init(contents),
        });
    }
    const FileWriteDriver = struct {
        path: heap.Owned([]u8),
        path_value: heap.Owned(Value),
        contents: heap.Owned([]u8),
        open_file: ?heap.Owned(OpenFile) = null,
        offset: usize = 0,
        phase: enum { open, write } = .open,

        fn failIo(
            self: *FileWriteDriver,
            evaluator: *Machine,
            name: []const u8,
        ) MachineError {
            const failure = evaluator.failFmt(
                .io,
                "cannot write `{s}`: {s}",
                .{ self.path.borrow(), name },
            );
            evaluator.unit.pending.?.addData(.path, self.path_value.borrow());
            return failure;
        }
        pub fn advance(evaluator: *Machine, self: *FileWriteDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            const io = evaluator.unit.inherited.host_io.?;
            switch (self.phase) {
                .open => {
                    const file = std.Io.Dir.cwd().createFile(io, self.path.borrow(), .{}) catch |err|
                        return self.failIo(evaluator, @errorName(err));
                    self.open_file = .init(.{ .io = io, .file = file });
                    self.phase = .write;
                    return .yielded;
                },
                .write => {
                    const contents = self.contents.borrow();
                    if (self.offset != contents.len) {
                        const end = @min(self.offset + kernel_poll_quantum, contents.len);
                        const written = self.open_file.?.borrow().file.writeStreaming(
                            io,
                            &.{},
                            &.{contents[self.offset..end]},
                            1,
                        ) catch |err| return self.failIo(evaluator, @errorName(err));
                        self.offset += written;
                        return .yielded;
                    }
                    self.open_file.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.open_file = null;
                    return .completed;
                },
            }
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    /// Consumes nothing: the whole stream is read into one owned string.
    pub fn readStandardInputOwned(self: *Machine) MachineError!void {
        const stream = self.unit.inherited.standard_input orelse
            return self.fail(.io, "standard input is unavailable");
        if (self.unit.inherited.host_io == null)
            return self.fail(.io, "standard input is unavailable");
        switch (stream.claim()) {
            .granted => {},
            .program_source => return self.fail(.io, "stdin is the program source"),
            .already_read => return self.fail(.io, "standard input has already been read"),
        }
        try self.startDriver(StandardInputDriver{ .allocator = self.unit.allocator });
    }
    const StandardInputDriver = struct {
        retirement: heap.ReleaseDomain.Retirement = .{},
        allocator: std.mem.Allocator,
        buffer: std.ArrayList(u8) = .empty,
        reader: ?std.Io.File.Reader = null,
        // SAFETY: only ever read through the prefix a read call just filled.
        chunk: [read_chunk]u8 = undefined,
        text: ?heap.Owned(kernel_storage.Utf8Materializer) = null,
        phase: enum { read, text } = .read,

        const read_chunk: usize = 8192;

        pub fn advance(evaluator: *Machine, self: *StandardInputDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            switch (self.phase) {
                .read => {
                    if (self.reader == null)
                        self.reader = std.Io.File.stdin().reader(
                            evaluator.unit.inherited.host_io.?,
                            &.{},
                        );
                    const amount = self.reader.?.interface.readSliceShort(&self.chunk) catch {
                        const name = if (self.reader.?.err) |err| @errorName(err) else "ReadFailed";
                        return evaluator.failFmt(.io, "cannot read standard input: {s}", .{name});
                    };
                    if (amount == 0) {
                        self.reader = null;
                        self.text = .init(.init(self.allocator, self.buffer.items));
                        self.phase = .text;
                        return .yielded;
                    }
                    try self.buffer.appendSlice(self.allocator, self.chunk[0..amount]);
                    return .yielded;
                },
                .text => switch (self.text.?.borrowMut().advance(kernel_poll_quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return evaluator.fail(
                        .io,
                        "standard input is not valid UTF-8",
                    ),
                }) {
                    .pending => return .yielded,
                    .complete => |text| {
                        self.text.?.borrowMut().deinit();
                        self.text = null;
                        return .{ .output = text };
                    },
                },
            }
        }
        pub fn advanceRetirement(
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
            self: *StandardInputDriver,
        ) bool {
            if (self.text) |*text| text.deinit(releases, storage_allocator);
            self.text = null;
            self.buffer.deinit(self.allocator);
            storage_allocator.destroy(self);
            return true;
        }
        pub const ownership: heap.DriverOwnership = .bounded_retirement;
    };
    /// Records the offending path or url on the failure being raised, which is
    /// the shape every host-IO error reports. Keeps `ErrorDataKey` private
    /// while letting a builtin module attach the one datum it owns.
    pub fn addErrorPath(self: *Machine, path: Value) void {
        self.unit.pending.?.addData(.path, path);
    }
    /// Tags the one absent-only publication conflict that an immutable
    /// package caller may recover after independently confirming the winner.
    pub fn addErrorDestinationExists(self: *Machine) void {
        self.unit.pending.?.addData(.@"destination-exists", .{ .int = 1 });
    }
    /// The one absence-is-absence failure for `getenv`: an unset variable is
    /// an error carrying the requested name, never an empty string.
    pub fn unsetEnvironVariable(
        self: *Machine,
        name: []const u8,
        name_value: Value,
    ) MachineError {
        const failure = self.failFmt(.io, "environment variable `{s}` is not set", .{name});
        self.unit.pending.?.addData(.name, name_value);
        return failure;
    }
    /// Resolves one environment variable against the session snapshot.
    pub fn environLookup(self: *Machine, name: []const u8) Environ.LookupCursor {
        const entries: []const Environ.Entry =
            if (self.unit.inherited.environ) |environ| environ.entries else &.{};
        return .{ .entries = entries, .name = name };
    }
    pub fn undefinedModule(self: *Machine, name: u32) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined module `{s}`", .{intern.get(name)});
        self.unit.pending.?.addData(.name, .{ .symbol = name });
        return failure;
    }
    /// The dispatcher's miss. Every resolution miss reports the reference the
    /// program actually wrote, including a dotted one whose module never
    /// loaded.
    pub fn undefinedWord(self: *Machine, word: u32) MachineError {
        return self.undefinedWordIn(word, self.currentLookupChain());
    }
    /// The same failure, for the two callers that know the search happened
    /// somewhere other than the running activation's own chain.
    pub fn undefinedWordIn(self: *Machine, word: u32, chain: LookupChain) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(word)});
        self.unit.pending.?.addData(.name, .{ .symbol = word });
        self.addLookupChain(chain) catch return error.OutOfMemory;
        return failure;
    }
    pub fn undefinedActiveWord(self: *Machine) MachineError {
        return self.undefinedWord(self.unit.active_word.atom());
    }
    pub fn undefinedName(self: *Machine, name: u32) MachineError {
        return self.undefinedNameIn(name, self.currentLookupChain());
    }
    /// The same failure as `undefinedWordIn`, for a name that is not the word
    /// currently being traced: the active word becomes the requested name so
    /// the diagnostic reports what was asked for.
    pub fn undefinedNameIn(self: *Machine, name: u32, chain: LookupChain) MachineError {
        self.unit.active_word = .plain(name);
        return self.undefinedWordIn(name, chain);
    }
    fn addLookupChain(self: *Machine, chain: LookupChain) error{OutOfMemory}!void {
        const named = try intern.intern(chain.spelling());
        self.unit.pending.?.addData(.scope, .{ .symbol = named });
    }
    /// What the running activation would have searched, for the callers that
    /// have no word in hand — reflection, and a miss reported before a word's
    /// scope is known.
    /// The chain a lookup from the running activation searched.
    ///
    /// Derived from the resolution scope, exactly as `lookupChainFor` derives
    /// it for a stamped occurrence, because they answer the same question and
    /// must not answer it differently. This used to key on whether a home was
    /// present, which is a related fact and not the same one: `ExecutionSite`
    /// says so itself -- a homeless word called from module code inherits the
    /// caller's home while resolving against its own chain -- so a module home
    /// over a session chain reported `module` for a lookup that searched the
    /// session.
    fn currentLookupChain(self: *const Machine) LookupChain {
        const current = self.unit.current orelse return .session;
        return lookupChainFor(current.site.resolution_scope);
    }
    pub fn available(self: *const Machine) usize {
        return self.unit.stack.items.len - self.unit.stack_base;
    }
    pub fn require(self: *Machine, count: usize) MachineError!void {
        if (self.available() >= count) return;
        // Underflow against the floor of a unit constructor's substack is the
        // one underflow whose cause is invisible: the values the caller meant
        // to pass are right there and unreachable. Name the isolation and the
        // seeding remedy rather than reporting a bare shortfall.
        const isolation = self.isolationGuidance();
        const failure = if (isolation) |guidance| self.failFmt(
            .underflow,
            "{s} needs {d} stack value{s}, but found {d}; {s}",
            .{
                self.activeWordName(),
                count,
                if (count == 1) "" else "s",
                self.available(),
                guidance.advice,
            },
        ) else self.failFmt(
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
        if (isolation) |guidance| self.unit.pending.?.addData(
            .isolation,
            .{ .word = .{ .name = intern.intern(guidance.constructor) catch return failure } },
        );
        return failure;
    }
    const IsolationGuidance = struct { constructor: []const u8, advice: []const u8 };
    /// Which unit constructor, if any, owns the floor this underflow hit.
    fn isolationGuidance(self: *Machine) ?IsolationGuidance {
        if (self.unit.stack_base > 0) {
            const boundary = self.unit.boundary_index orelse return null;
            // During an unwind the index momentarily names the frame that was
            // just popped, so this is a bounds question, not an invariant.
            const index: usize = @intFromEnum(boundary);
            if (index >= self.unit.frames.items.len) return null;
            const frame = self.unit.frames.items[index];
            if (frame != .boundary) return null;
            if (frame.boundary.stack_base != self.unit.stack_base) return null;
            return switch (frame.boundary.mode) {
                .attempt => .{
                    .constructor = "@attempt",
                    .advice = "the substack is isolated from the caller's stack — " ++
                        "seed it with `values (q) seed @attempt` or capture with `partial`",
                },
                .module => |construction| if (construction.registration == null) .{
                    .constructor = "@module",
                    .advice = "the substack is isolated from the caller's stack — " ++
                        "seed it with `values (body) seed @module` or capture with `partial`",
                } else .{
                    .constructor = "@defm",
                    .advice = "the substack is isolated from the caller's stack — " ++
                        "seed it with `values (body) seed 'name @defm` or capture with `partial`",
                },
                .state => null,
            };
        }
        if (self.unit.is_root_unit) return null;
        return switch (self.unit.constructor) {
            .spawn => .{
                .constructor = "@spawn",
                .advice = "the child unit's stack is isolated from the caller's — " ++
                    "seed it with `values (q) seed @spawn` or capture with `partial`",
            },
            .each => .{
                .constructor = "@each",
                .advice = "the child unit's stack holds only its element — " ++
                    "seed it with `list values (q) seed @each` or capture with `partial`",
            },
        };
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
    /// Pops the input every unit constructor takes: a bare quotation, which
    /// seeds nothing, or a unit plan, which names its seeds and its body
    /// separately. Nothing else is accepted, and the type error is the one a
    /// constructor has always reported for a non-quotation.
    ///
    /// A plan's two fields are borrows, so each is retained here: the returned
    /// input owns both halves independently of the plan it came from, which is
    /// what lets the plan itself be released before the body starts running.
    pub fn popUnitInput(self: *Machine) MachineError!OwnedUnitInput {
        var item = try self.popValue();
        defer item.deinit();
        switch (item.borrow()) {
            .list => |quotation| {
                _ = item.take();
                return .init(self.releaseDomain(), .{ .seeds = null, .body = quotation });
            },
            .unit_plan => |plan| {
                const seeds = heap.unitPlanSeeds(plan);
                const body = heap.unitPlanBody(plan);
                heap.incRef(seeds);
                heap.incRef(body);
                return .init(self.releaseDomain(), .{ .seeds = seeds, .body = body });
            },
            else => return self.typeError("a quotation/list or unit plan"),
        }
    }
    /// Releases whichever halves of a consumed `UnitInput` a failing
    /// constructor still owns. Every constructor failure path goes through
    /// this, so the consuming contract does not depend on remembering that a
    /// seeded input has two references rather than one.
    fn releaseUnitInput(self: *Machine, input: UnitInput) void {
        if (input.seeds) |seeds| self.releaseDomain().releaseHeader(seeds);
        self.releaseDomain().releaseHeader(input.body);
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
    /// Observes one value in the currently visible operand window, bottom
    /// first. Checkpoint cursors retain the returned borrow before yielding;
    /// no raw stack storage escapes this boundary.
    pub fn visibleOperandBorrowed(self: *const Machine, index: usize) Value {
        std.debug.assert(index < self.available());
        return self.unit.stack.items[self.unit.stack_base + index];
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
    pub fn activeWordId(self: *const Machine) intern.TraceWord {
        return self.unit.active_word;
    }
    pub fn setActiveWord(self: *Machine, word: intern.TraceWord) void {
        self.unit.active_word = word;
    }
    pub fn setFailureSite(self: *Machine, code: *Header, index: u32) void {
        if (self.unit.pending) |*pending| pending.site = .{ .token = .{ .code = code, .index = index } };
    }
    pub fn setWorkDriverSite(self: *Machine, code: *Header, index: u32) void {
        if (self.unit.workDriver()) |driver| driver.site = .{ .code = code, .index = index };
    }
    pub fn setWorkDriverTraceParent(self: *Machine, word: intern.TraceWord) void {
        if (self.unit.workDriver()) |driver| driver.trace_parent = word;
    }

    /// Attributes the application the caller just began to `word`. A
    /// recognized idiom whose callback applies a quotation stands in for the
    /// source body frame that would otherwise have carried the word, so
    /// failures inside that quotation still trace through the word the caller
    /// wrote. Only the installing callback may claim an application this way:
    /// an unrelated enclosing application owns its own attribution.
    pub fn setApplicationTraceParent(self: *Machine, word: intern.TraceWord) void {
        const frame = &self.unit.frames.items[self.unit.frames.items.len - 1];
        std.debug.assert(frame.* == .application);
        frame.application.traced_word = word;
        self.unit.current.?.traced_word = word;
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
    pub fn commitDirectIdiomTrace(self: *Machine) intern.TraceWord {
        const parent = self.unit.active_word;
        if (self.unit.current.?.ip >= self.unit.current.?.code.length()) self.unit.current.?.traced_word = no_word;
        return parent;
    }
    pub fn setFailureTraceParent(self: *Machine, word: intern.TraceWord) void {
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
        var owned = fallback;
        defer owned.deinit(self.releaseDomain(), self.unit.allocator);
        return owned.run(self);
    }
    /// The active word as a diagnostic spells it. A module-local word has no
    /// single interned spelling, so the rendering borrows the unit's scratch;
    /// the returned slice is valid until the next call.
    pub fn activeWordName(self: *Machine) []const u8 {
        if (self.unit.active_word == no_word) return "evaluation";
        return self.unit.active_word.render(&self.unit.word_scratch);
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
        opaque_site: *ApplicationContractSite,
        quotation: *Header,
        expected: Value,
        depths: ApplicationDepths,
        index: ?usize,
    ) MachineError {
        const failure = if (index) |element_index|
            self.failFmt(
                .contract,
                "{s} quotation at element {d} violated its stack effect; expected final depth {d} from {d} seeded value{s}, observed {d}",
                .{
                    self.activeWordName(),
                    element_index,
                    depths.expected,
                    depths.seeded,
                    if (depths.seeded == 1) "" else "s",
                    depths.observed,
                },
            )
        else
            self.failFmt(
                .contract,
                "{s} quotation violated its stack effect; expected final depth {d} from {d} seeded value{s}, observed {d}",
                .{
                    self.activeWordName(),
                    depths.expected,
                    depths.seeded,
                    if (depths.seeded == 1) "" else "s",
                    depths.observed,
                },
            );
        self.unit.pending.?.addData(.expected, expected);
        self.unit.pending.?.addData(.seeded, .{ .int = @intCast(depths.seeded) });
        self.unit.pending.?.addData(.observed, .{ .int = @intCast(depths.observed) });
        if (index) |element_index| {
            self.unit.pending.?.addData(.index, .{ .int = @intCast(element_index) });
        }
        const site: *ApplicationSelection = @ptrCast(@alignCast(opaque_site));
        self.unit.pending.?.site = .{ .contract_quotation = site.takeFailureSite(quotation) };
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
    /// What a typed cursor may still charge before the interval ends. A loop
    /// bounds its next half-open range by this so the range it commits to is
    /// the range the budget can pay for, rather than discovering the boundary
    /// mid-chunk.
    pub fn remainingKernelFuel(self: *const Machine) usize {
        return self.unit.kernel_fuel;
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
        const effect_tail = self.replaceTailEffectCandidate(quotation);
        const application_tail = self.tailApplicationIndex();
        if (application_tail) |application_index| {
            const frame = &self.unit.frames.items[@intFromEnum(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(quotation);
        }
        const site = ExecutionSite.inheriting(self.unit.current.?, self.unit.current.?.scope());
        const inherited_trace = self.suspendCurrent() catch {
            self.releaseDomain().releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.unit.current = .{
            .code = quotation,
            .ip = 0,
            .site = site,
            .traced_word = inherited_trace,
            .effect_tail = effect_tail,
            .application_tail = application_tail,
            .application_selection = application_tail,
        };
    }

    /// A completion contract follows authored tail control, not application
    /// machinery. Generic applications deliberately do not call this helper:
    /// their continuation restarts once per element and must not add a pair of
    /// code-header atomics to that hot path.
    fn replaceTailEffectCandidate(self: *Machine, code: *Header) ?EffectCheckIndex {
        const current = self.unit.current orelse return null;
        const check_index = current.effect_tail orelse return null;
        if (!self.isSourceTailPosition(current)) return null;
        std.debug.assert(self.unit.effect_check_index == check_index);
        const frame = &self.unit.frames.items[@intFromEnum(check_index)];
        std.debug.assert(frame.* == .effect_check);
        frame.effect_check.replaceSourceCandidate(self.releaseDomain(), code);
        return check_index;
    }

    /// Propagates one application's authority through ordinary tail word
    /// dispatch without changing its selected quotation. Only a dynamic
    /// `call` marks code for ownership transfer into the candidate.
    fn tailApplicationIndex(self: *Machine) ?ApplicationFrameIndex {
        const current = self.unit.current orelse return null;
        const application_index = current.application_tail orelse return null;
        if (!self.isSourceTailPosition(current)) return null;
        return application_index;
    }

    fn validateApplicationProvenanceTarget(
        self: *Machine,
        target: *const ApplicationProvenanceTarget,
    ) ?ApplicationFrameIndex {
        const raw = @intFromPtr(target);
        const raw_index: u32 = @truncate(raw);
        const raw_nonce: u32 = @truncate(raw >> 32);
        if (raw_nonce == 0 or raw_index >= self.unit.frames.items.len) return null;
        const index: ApplicationFrameIndex = @enumFromInt(raw_index);
        const frame = &self.unit.frames.items[@intFromEnum(index)];
        if (frame.* != .application) return null;
        const nonce = frame.application.provenance_nonce orelse return null;
        if (@intFromEnum(nonce) != raw_nonce) return null;
        return index;
    }

    /// Captures the current tail-selection boundary for trusted control
    /// machinery that must suspend through bounded native work before it can
    /// launch the semantically selected quotation. The frame owns the nonce;
    /// relocation preserves it and frame retirement makes the handle stale.
    pub fn applicationProvenanceTarget(
        self: *Machine,
    ) error{OutOfMemory}!?*const ApplicationProvenanceTarget {
        const index = self.tailApplicationIndex() orelse return null;
        const frame = &self.unit.frames.items[@intFromEnum(index)];
        std.debug.assert(frame.* == .application);
        if (frame.application.provenance_nonce == null)
            frame.application.provenance_nonce = try mintApplicationProvenanceNonce();
        return encodeApplicationProvenanceTarget(index, frame.application.provenance_nonce.?);
    }

    /// Consumes an exhausted Eval. A dynamically applied quotation moves its
    /// already-owned header into the application frame; every other Eval uses
    /// the ordinary release. This delays one existing release but creates no
    /// additional retain/release pair.
    fn retireCompletedEval(self: *Machine, current: Eval) void {
        if (current.borrowed_scope) |cell| cell.releaseBorrow();
        if (current.application_selection) |application_index| {
            const frame = &self.unit.frames.items[@intFromEnum(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.completeOwned(self.releaseDomain(), current.code);
        } else {
            self.releaseDomain().releaseHeader(current.code);
        }
    }

    /// Reader-lowered binders end in `<count> _dl`. That cleanup must run
    /// after the authored final form, but it does not make a final control
    /// transfer semantically non-tail. The exact reserved epilogue is the only
    /// continuation shape granted this exception.
    fn isSourceTailPosition(self: *const Machine, current: Eval) bool {
        const length = current.code.length();
        if (current.ip == length) return true;
        if (length - current.ip != 2) return false;
        const count = list.atUnchecked(.{ .list = current.code }, current.ip);
        const drop = list.atUnchecked(.{ .list = current.code }, current.ip + 1);
        return count == .int and count.int >= 0 and
            drop == .word and std.mem.eql(u8, intern.get(drop.word.name), "_dl") and
            @as(usize, @intCast(count.int)) <= self.unit.locals.items.len;
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
    /// Hands back an isolated application scope. One that never bound and is
    /// unshared is parked for the next application over the same parent rather
    /// than retired; anything else takes the ordinary path.
    fn releaseApplicationScope(self: *Machine, scope: *env.Scope) void {
        if (self.unit.spare_scope == null and scope.parent != null and
            scope.reusableAsChildOf(scope.parent.?))
        {
            self.unit.spare_scope = scope;
            return;
        }
        scope.retire();
    }

    /// The parked scope if it belongs under `parent`, otherwise a fresh one.
    /// A parked scope that belongs elsewhere is retired rather than kept: it
    /// pins its own parent alive, and the next application is the evidence
    /// that nothing is iterating over it any more.
    fn acquireApplicationScope(self: *Machine, parent: *env.Scope) error{OutOfMemory}!*env.Scope {
        if (self.unit.spare_scope) |spare| {
            if (spare.reusableAsChildOf(parent)) {
                self.unit.spare_scope = null;
                return spare;
            }
            self.unit.spare_scope = null;
            spare.retire();
        }
        return env.Scope.createLazy(self.unit.allocator, parent);
    }

    fn beginApplication(
        self: *Machine,
        application: IsolatedApplication,
        launch: ApplicationLaunch,
        inherited: ?intern.TraceWord,
    ) MachineError!void {
        self.require(application.seeded) catch |err| {
            application.deinit_fn(self.releaseDomain(), self.unit.allocator, application.context);
            return err;
        };
        const base = StackWindow.init(self.unit.stack.items.len, application.seeded) orelse unreachable;
        const provenance_target: ?ApplicationFrameIndex = switch (application.provenance) {
            .boundary => null,
            .selected_target => |target| self.validateApplicationProvenanceTarget(target) orelse {
                application.deinit_fn(self.releaseDomain(), self.unit.allocator, application.context);
                return self.fail(.domain, "application provenance target is stale or foreign");
            },
        };
        const select_initial = application.provenance != .boundary;
        var child: ?*env.Scope = null;
        if (launch == .isolated) {
            child = self.acquireApplicationScope(application.parent_scope) catch {
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
        const application_index: ApplicationFrameIndex = @enumFromInt(@as(u32, @intCast(self.unit.frames.items.len)));
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
            .selection = .{},
        } });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        try self.appendFrame(&continuation);
        if (launch == .isolated) self.unit.stack_base = base.base();
        if (select_initial) {
            const target = provenance_target.?;
            const frame = &self.unit.frames.items[@intFromEnum(target)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(application.quotation);
        }
        heap.incRef(application.quotation);
        self.unit.current = .{
            .code = application.quotation,
            .ip = 0,
            .site = .resumed(child orelse application.parent_scope, application.home),
            .traced_word = inherited_trace,
            .application_tail = provenance_target orelse application_index,
            .application_selection = if (select_initial) provenance_target else null,
        };
    }
    pub fn attemptOwned(self: *Machine, input: UnitInput) error{OutOfMemory}!void {
        return self.beginAttemptOwned(input);
    }
    /// Publishes an already-constructed image under a validated name. The
    /// module value is consumed: the driver retains it for its whole lifetime,
    /// which is what keeps the borrowed image alive across every resumption,
    /// and releases it on every exit.
    pub fn registerModuleOwned(
        self: *Machine,
        module: Value,
        name: intern.ModuleName,
    ) MachineError!void {
        const registry = self.unit.inherited.registry orelse {
            self.releaseDomain().releaseValue(module);
            return self.fail(.domain, "module registry is unavailable");
        };
        const image = modules.imageRef(module) orelse {
            self.releaseDomain().releaseValue(module);
            return self.typeError("a module");
        };
        return self.startDriver(ModuleRegisterDriver{
            .module = .init(module),
            .cursor = .init(registry.registrationCursor(
                image,
                name,
                &self.unit.turn_authority,
            )),
        });
    }
    /// Opens a construction boundary. The body evaluates against a fresh
    /// anonymous image; `registration`, when present, is the name that image
    /// is published under the instant the body succeeds.
    pub fn moduleOwned(
        self: *Machine,
        registration: ?u32,
        input: UnitInput,
    ) MachineError!void {
        const registry = self.unit.inherited.registry orelse {
            self.releaseUnitInput(input);
            return self.fail(.domain, "module registry is unavailable");
        };
        const word = self.unit.active_word;
        var candidate = registry.createImage() catch {
            self.releaseUnitInput(input);
            return error.OutOfMemory;
        };
        errdefer candidate.deinit();
        // The construction body's words name this image and nothing else, so
        // the image gets its own scope cell. A reload builds a new image and
        // publishes it under the name; the words of the generation it replaced
        // go on naming the image they were written in, for as long as anything
        // still holds it.
        const home = candidate.executionHome(self.unit.module_access);
        const stamp_scope = self.unit.environment.scopeIdForOwned(
            home.scope(self.unit.module_access),
            modules.anchorHandle(home, self.unit.module_access),
        ) catch {
            self.releaseUnitInput(input);
            return error.OutOfMemory;
        };
        // Attribution asks one question, of the exact designated body: is it
        // does this exact body carry reader-text lineage? Admission is the
        // archive's own, so the answer arrives already applied: either a cursor
        // that will produce the re-scoped copy, or "run it unchanged", in which
        // case the body's words go on resolving in the scopes they were written
        // in. Seeds are a separate value and are never reached either way.
        //
        // Both re-scoping and seeding are user-sized, so they are ordinary
        // resumable scheduler work: the driver holds the candidate image, the
        // seeds, and the source body until the copy is finished and the
        // boundary can open. Only a body with neither to do still opens it in
        // this step, and that case copies nothing at all.
        var prepared = self.unit.archive.prepareConstructionBody(
            input.body,
            @intFromEnum(stamp_scope),
        );
        if (prepared == .unchanged and input.seeds == null) {
            const body_header = input.body;
            heap.incRef(body_header);
            self.releaseUnitInput(input);
            return self.openImageBoundary(&candidate, registration, word, body_header);
        }
        errdefer if (prepared == .rewriting) prepared.rewriting.deinit();
        try self.startDriver(ConstructionDriver{
            .target = .init(.{ .image = .{
                .candidate = candidate.move(),
                .registration = registration,
            } }),
            .rescope = switch (prepared) {
                .unchanged => null,
                .rewriting => |cursor| .init(cursor),
            },
            .source = switch (prepared) {
                .unchanged => null,
                .rewriting => .init(input.body),
            },
            .body = switch (prepared) {
                .unchanged => body: {
                    heap.incRef(input.body);
                    self.releaseDomain().releaseHeader(input.body);
                    break :body .init(input.body);
                },
                .rewriting => null,
            },
            .seeds = if (input.seeds) |seeds| .init(seeds) else null,
            .word = word,
            .phase = switch (prepared) {
                .unchanged => .open,
                .rewriting => .rescope,
            },
        });
    }
    /// Opens one construction boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure, and the image is
    /// consumed only once the boundary owns it.
    fn openImageBoundary(
        self: *Machine,
        candidate: *modules.OwnedImage,
        registration: ?u32,
        word: intern.TraceWord,
        body_header: *Header,
    ) MachineError!void {
        const home = candidate.executionHome(self.unit.module_access);
        _ = self.suspendCurrent() catch {
            self.releaseDomain().releaseHeader(body_header);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= max_frame_count) {
            self.releaseDomain().releaseHeader(body_header);
            return error.OutOfMemory;
        }
        try self.openBoundary(
            .{ .module = .{ .image = candidate.move(), .registration = registration } },
            @intCast(self.unit.stack.items.len),
            word,
            body_header,
        );
        self.unit.current = .{
            .code = body_header,
            .ip = 0,
            .site = .image(home, self.unit.module_access),
            .traced_word = no_word,
        };
    }
    /// Invokes one public export of a module value. The module reference is
    /// consumed: the driver retains it for its whole life — which is also what
    /// keeps `image` valid, since an `ImageRef` is only a borrow — and
    /// releases it on every exit. The binding symbol arrives unvalidated and
    /// the driver validates it before consulting the image, so an
    /// unqualifiable spelling fails as one rather than as a missing export.
    pub fn invokeModuleOwned(
        self: *Machine,
        module: Value,
        image: modules.ImageRef,
        binding: u32,
    ) MachineError!void {
        return self.startDriver(HandleDispatchDriver{
            .module = .init(module),
            .image = image,
            .validation = .init(binding),
        });
    }
    /// The whole of `seed`: seal the two values into one immutable plan.
    ///
    /// It lives here rather than behind a handler value because `seed` is a
    /// binding kind, not a primitive anything can be bound to. The two halves
    /// come off this unit's own stack and the binding's opaque seal derives the
    /// plan allocation from the Env's host owner, so no allocator crosses this
    /// call boundary.
    ///
    /// The two stay separate for the whole life of the plan: nothing here
    /// executes, stamps, copies, parses, or otherwise transforms either input,
    /// because the only thing a plan is for is letting a unit constructor tell
    /// a body from the values handed to it.
    fn sealUnitPlan(
        self: *Machine,
        seal: *const heap.UnitPlanSeal,
    ) MachineError!void {
        try self.require(2);
        var body = try self.popQuotation();
        errdefer body.deinit();
        var values = try self.popList();
        errdefer values.deinit();
        // `popList` and `popQuotation` established both tags, so the factory's
        // list parameters are satisfied without a second check and without
        // projecting a tag anything here has not established.
        const plan = try seal.seal(
            values.borrow().list,
            body.borrow().list,
        );
        // The plan owns both references now; the local handles hand theirs over
        // rather than releasing them.
        _ = values.take();
        _ = body.take();
        try self.pushOwned(plan);
    }
    /// Resolves a word in the scope its text was written in, which is carried
    /// by the occurrence rather than by the quotation containing it. A word
    /// with no written-in scope — anything not produced by the reader, and any
    /// word a host built — resolves in the activation's own chain, which is
    /// what a bare token has always done.
    /// The anchor of the image the running activation holds, if it holds one.
    /// A pointer compare against a cell's owner is a complete liveness proof:
    /// the activation's pin is what keeps that image alive.
    fn runningAnchor(self: *Machine) ?*anyopaque {
        const home = self.unit.current.?.home() orelse return null;
        return modules.anchorHandle(home, self.unit.module_access);
    }

    pub fn executeWord(self: *Machine, word: value.WordRef) MachineError!void {
        // Acquired only on the `fresh_pin` arm, and handed to the cursor so the
        // pin taken here is the one `scheduleWord` consumes.
        var borrow_pin: ?modules.GenerationPin = null;
        errdefer if (borrow_pin) |*owned| owned.deinit();
        // Held by the activation this dispatch enters, not by the unit: unlike
        // an image pin, a scope borrow ends when the chain walk does.
        var borrowed_cell: ?*env.ScopeCell = null;
        errdefer if (borrowed_cell) |cell| cell.releaseBorrow();

        // Is this occurrence stamped with the activation's own scope? One
        // integer compare, ahead of everything else, because straight-line code
        // resolving in its own chain is the overwhelming common case and it
        // needs no proof beyond the activation that is already running it.
        //
        // This generalizes the activation-held arm from anchors to scope ids:
        // where that compare covered a foreign word in the same image, this
        // covers the word's scope being the running one outright, so the
        // directory walk, the cell, the owner load, and `encloses` are all
        // skipped rather than merely cheapened.
        const running_site = self.unit.current.?.site;
        if (word.scope != 0 and
            @intFromEnum(running_site.resolution_scope_id) == word.scope)
        {
            self.unit.active_word = .plain(word.name);
            try self.startDriver(DispatchDriver{
                .word = word.name,
                .resolution = .init(.init(
                    self,
                    word.name,
                    running_site.resolution_scope,
                    null,
                    // The activation already holds this chain, so the fast path
                    // acquires nothing -- that is the point of it.
                    null,
                )),
            });
            return;
        }

        const written: ?*env.Scope = switch (self.unit.environment.scopeOf(@enumFromInt(word.scope))) {
            .unscoped => self.unit.current.?.resolutionScope(),
            // Core is a terminal phase that no scope denotes.
            .core => null,
            .cell => |cell| refined: {
                // Liveness before dereference, in three arms and no more. The
                // order matters: the cheap proof is tried first because a module
                // body executing its own words is the common case, and it costs
                // one pointer compare and no atomic.
                const proof: env.Liveness = if (cell.ownerHandle()) |owner| held: {
                    if (self.runningAnchor()) |running| {
                        if (running == owner) break :held .activation_held;
                    }
                    borrow_pin = modules.tryPinAnchor(owner, self.unit.module_access) orelse {
                        // The image reached its last release. Definite, never a
                        // fallback: a fallback would change what the word means.
                        self.unit.active_word = .plain(word.name);
                        return self.fail(
                            .domain,
                            "the scope this word was written in has retired",
                        );
                    };
                    break :held .fresh_pin;
                } else if (self.unit.current.?.chainHolds(word.scope)) blk: {
                    // Ours already: the activation holds this chain, so there is
                    // nothing to acquire and nothing to release.
                    break :blk .non_image;
                } else foreign: {
                    // A scope belonging to some other unit, reached through a
                    // value. Acquire-then-validate on the cell, whose memory is
                    // immortal, rather than a retain on the scope, whose memory
                    // is not -- a `fetchAdd` there would be the very
                    // retain-after-load this design exists to remove.
                    if (cell.acquire() == null) {
                        self.unit.active_word = .plain(word.name);
                        return self.fail(
                            .domain,
                            "the scope this word was written in has retired",
                        );
                    }
                    borrowed_cell = cell;
                    break :foreign .non_image;
                };

                const written_scope = cell.scopeUnder(proof) orelse {
                    self.unit.active_word = .plain(word.name);
                    return self.fail(
                        .domain,
                        "the scope this word was written in has retired",
                    );
                };
                // The word's scope is a lower bound; an activation already
                // inside a descendant of it resolves there instead.
                const running = self.unit.current.?.resolutionScope();
                break :refined if (running != null and written_scope.encloses(running.?))
                    running
                else
                    written_scope;
            },
            // A fallback here would change what the word means, so the failure
            // is definite instead. The traced word is set first: this failure
            // belongs to the word being dispatched, not to whichever word was
            // traced before it.
            .retired => {
                self.unit.active_word = .plain(word.name);
                return self.fail(
                    .domain,
                    "the scope this word was written in has retired",
                );
            },
        };
        self.unit.active_word = .plain(word.name);
        const owned_pin = borrow_pin;
        borrow_pin = null;
        const owned_cell = borrowed_cell;
        borrowed_cell = null;
        try self.startDriver(DispatchDriver{
            .word = word.name,
            .resolution = .init(.init(self, word.name, written, owned_pin, owned_cell)),
        });
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
        const site = ExecutionSite.image(self.currentHome().?, self.unit.module_access);
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
        try self.openBoundary(
            .{ .state = owned.move() },
            application.draft_base,
            word,
            quotation,
        );
        self.unit.state_application = application;
        self.unit.current = .{
            .code = quotation,
            .ip = 0,
            .site = site,
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
        input: UnitInput,
    ) error{OutOfMemory}!void {
        // An unseeded `@attempt` opens its boundary in this step and allocates
        // nothing extra; a seeded one materializes a user-sized seed list, so
        // it becomes ordinary resumable scheduler work like every other
        // user-sized traversal.
        if (input.seeds == null) return self.openAttempt(input.body);
        return self.startDriver(ConstructionDriver{
            .target = .init(.attempt),
            .rescope = null,
            .source = null,
            .body = .init(input.body),
            .seeds = .init(input.seeds.?),
            .word = self.unit.active_word,
            .phase = .open,
        });
    }
    /// Opens one `@attempt` boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure.
    fn openAttempt(self: *Machine, body: *Header) error{OutOfMemory}!void {
        const parent_scope = self.unit.current.?.scope();
        const invoker = self.unit.current.?;
        const word = self.unit.active_word;
        const child = env.Scope.createLazy(self.unit.allocator, parent_scope) catch {
            self.releaseDomain().releaseHeader(body);
            return error.OutOfMemory;
        };
        _ = self.suspendCurrent() catch {
            child.retire();
            self.releaseDomain().releaseHeader(body);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= max_frame_count) {
            child.retire();
            self.releaseDomain().releaseHeader(body);
            return error.OutOfMemory;
        }
        try self.openBoundary(
            .{ .attempt = child },
            @intCast(self.unit.stack.items.len),
            word,
            body,
        );
        self.unit.current = .{
            .code = body,
            .ip = 0,
            .site = .inheriting(invoker, child),
            .traced_word = no_word,
        };
    }
    /// Opens one stack boundary: the frame recording where to return to, and
    /// the base its operands start from. The three boundary modes — a module
    /// body, a state application, and `@attempt` — differ in what they record
    /// and what runs inside them, never in how the boundary is opened. The
    /// caller keeps the frame-count check, because what it has to release on
    /// refusal differs; past that point failure releases the body here. A
    /// plan's seeds are never handed in: they belong to the driver that
    /// materializes them after the boundary is open.
    fn openBoundary(
        self: *Machine,
        mode: BoundaryMode,
        stack_base: u32,
        word: intern.TraceWord,
        quotation: *Header,
    ) error{OutOfMemory}!void {
        const index: FrameIndex = @enumFromInt(@as(u32, @intCast(self.unit.frames.items.len)));
        var continuation = OwnedFrame.init(.{ .boundary = .{
            .mode = mode,
            .stack_base = stack_base,
            .locals_base = @intCast(self.unit.locals.items.len),
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
        self.unit.stack_base = stack_base;
    }
    fn appendFrame(self: *Machine, owned: *OwnedFrame) error{OutOfMemory}!void {
        try self.unit.frames.append(self.unit.allocator, owned.frame.?);
        _ = owned.take();
        self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
    }
    /// Suspends a non-tail continuation. An exhausted anonymous quotation
    /// inherits its named trace owner so inline control does not erase the
    /// activation that selected it.
    fn suspendCurrent(self: *Machine) error{OutOfMemory}!intern.TraceWord {
        const current = self.unit.current.?;
        const inherited_trace = if (current.ip >= current.code.length())
            current.traced_word
        else
            no_word;
        if (current.ip < current.code.length()) {
            try self.unit.frames.append(self.unit.allocator, .{ .eval = current });
            self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
        } else {
            self.retireCompletedEval(current);
        }
        self.unit.current = null;
        return inherited_trace;
    }
    /// A source-backed module load nests inside the requesting evaluation.
    /// Preserve even an exhausted caller: after publication the qualified
    /// request still needs its resolution scope, home, and continuation, and
    /// only the eventual dispatched word may consume the tail position.
    fn suspendCurrentForQualifiedLoad(self: *Machine) error{OutOfMemory}!intern.TraceWord {
        const current = self.unit.current.?;
        try self.unit.frames.append(self.unit.allocator, .{ .eval = current });
        self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
        self.unit.current = null;
        return no_word;
    }
};

pub const RunStatus = enum { completed, yielded, parked };

/// The input every unit constructor takes, with the two halves the language
/// requires it to tell apart: the construction body, and the values the new
/// unit's stack starts with. A raw quotation seeds nothing; a unit plan names
/// both. Flattening them into one quotation is exactly what makes module-text
/// attribution unanswerable, so nothing between `seed` and the boundary is
/// allowed to join them.
///
/// Both halves are owned. Every constructor consumes a `UnitInput` and
/// releases whatever it still holds on every failure path.
pub const UnitInput = struct {
    /// Absent — not an empty list — for a raw quotation, so unseeded
    /// construction stays exactly as cheap as it was.
    seeds: ?*Header,
    body: *Header,

    pub fn seedCount(self: UnitInput) usize {
        const seeds = self.seeds orelse return 0;
        return @intCast(seeds.length());
    }

    /// How the new unit's stack begins, for the constructors that hand a whole
    /// Unit to the scheduler rather than opening a boundary in this one.
    pub fn initialStack(self: UnitInput) InitialStack {
        const seeds = self.seeds orelse return .empty;
        return .{ .borrowed_seeds = seeds };
    }

    /// The same, for `@each`, whose child stack holds its element beneath the
    /// plan's shared seeds.
    pub fn initialStackWithElement(self: UnitInput, element: Value) InitialStack {
        const seeds = self.seeds orelse return .{ .borrowed_element = element };
        return .{ .borrowed_element_and_seeds = .{ .element = element, .seeds = seeds } };
    }
};

/// A popped `UnitInput` before a constructor takes it. `deinit` releases both
/// halves, so a validation failure between the pop and the constructor cannot
/// strand either one.
pub const OwnedUnitInput = struct {
    domain: *heap.ReleaseDomain,
    input: ?UnitInput,

    pub fn init(domain: *heap.ReleaseDomain, input: UnitInput) OwnedUnitInput {
        return .{ .domain = domain, .input = input };
    }

    pub fn borrow(self: *const OwnedUnitInput) UnitInput {
        return self.input.?;
    }

    pub fn take(self: *OwnedUnitInput) UnitInput {
        const input = self.input.?;
        self.input = null;
        return input;
    }

    pub fn deinit(self: *OwnedUnitInput) void {
        if (self.input) |input| {
            if (input.seeds) |seeds| self.domain.releaseHeader(seeds);
            self.domain.releaseHeader(input.body);
        }
        self.input = null;
    }
};

/// What a constructed unit's stack starts with. Every reference here is a
/// borrow the caller keeps through initialization; the Unit retains its own
/// independent stack-owned reference to each before returning.
pub const InitialStack = union(enum) {
    empty,
    /// `@each`'s per-child element and nothing else.
    borrowed_element: Value,
    /// A plan's seed values, in list order.
    borrowed_seeds: *Header,
    /// `@each` over a plan: the element deepest, the plan's shared seeds
    /// above it.
    borrowed_element_and_seeds: struct { element: Value, seeds: *Header },
};

pub fn initialize(unit: *Unit, code: *Header, initial_stack: InitialStack) error{OutOfMemory}!void {
    std.debug.assert(unit.frames.items.len == 0);
    std.debug.assert(unit.pending == null and unit.last_error == null);
    std.debug.assert(unit.current == null);
    const element: ?Value, const seeds: ?*Header = switch (initial_stack) {
        .empty => .{ null, null },
        .borrowed_element => |item| .{ item, null },
        .borrowed_seeds => |items| .{ null, items },
        .borrowed_element_and_seeds => |both| .{ both.element, both.seeds },
    };
    // One element is O(1) and goes on now, deepest. A plan's seeds are
    // user-sized, so the Unit is instead handed a driver that materializes them
    // in bounded slices: the evaluator services a driver before the
    // activation's code, so the body still starts on a fully seeded stack.
    if (element) |item| {
        try unit.stack.append(unit.allocator, item);
        heap.retainValue(item);
    }
    if (seeds) |items| {
        // The driver's field owns this reference on every exit: a failed
        // `startDriver` disposes the pending driver's fields for us.
        heap.incRef(items);
        var evaluator = Machine{ .unit = unit };
        try evaluator.startDriver(ChildSeedDriver{ .seeds = .init(items) });
    }
    heap.incRef(code);
    unit.current = .{
        .code = code,
        .ip = 0,
        .site = .root(unit),
        .traced_word = no_word,
    };
}

pub fn runSlice(unit: *Unit) MachineError!RunStatus {
    var evaluator = Machine{ .unit = unit };
    defer unit.dropSpareScope();
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
                    if (driver.site) |site| self.unit.pending.?.site = .{ .token = site };
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
            self.retireCompletedEval(current.*);
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
                    self.unit.pending.?.site = .{ .token = .{
                        .code = self.unit.current.?.code,
                        .index = self.unit.active_index,
                    } };
                }
                try startFailure(self);
                continue;
            },
        };
    }
}

fn clearWorkDriver(unit: *Unit) void {
    const driver = unit.takeWorkDriver() orelse return;
    const inline_storage = unit.ownsInlineDriver(driver.context);
    driver.deinit(unit.releases, unit.allocator);
    // A driver that finishes by handing back a result is torn down here rather
    // than retiring itself, so this is the other place the slot comes free.
    // Without it an inline driver that completed this way would hold the slot
    // for the rest of the unit's life and every later driver would allocate.
    if (inline_storage) unit.releaseInlineDriver();
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
                .{},
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
                "@each child must leave exactly one result",
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
        .word => |reference| reference,
        .int, .float, .char, .symbol, .list, .dict, .task, .module, .unit_plan => return self.pushBorrowed(form),
    };
    try self.executeWord(word);
}
const DispatchDriver = struct {
    word: u32,
    resolution: heap.Owned(ResolutionCursor),

    /// Started once per word executed, so this is the driver the inline slot
    /// exists for.
    pub const inline_driver = true;

    pub fn advance(self_machine: *Machine, self: *DispatchDriver) MachineError!WorkProgress {
        try self_machine.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.resolution.borrowMut().advance()) {
            .pending => {},
            .complete => |outcome| {
                const installed = self_machine.unit.workDriver().?;
                const request = QualifiedLoadRequest{
                    .qualified = self.word,
                    .continuation = .{ .dispatch = .{
                        .word = self.word,
                        .site = installed.site,
                        .trace_parent = installed.trace_parent,
                    } },
                };
                self.resolution.deinit(self_machine.releaseDomain(), self_machine.allocator());
                const allocator = self_machine.unit.allocator;
                self_machine.retireDriver(self);
                switch (outcome) {
                    .resolved => |resolution| {
                        var resolved = resolution;
                        defer resolved.deinit(allocator);
                        try executeResolved(self_machine, &resolved);
                        return .detached;
                    },
                    // A qualified dispatch carries its exact word and
                    // provenance through loading, including dynamic execute.
                    .unknown_module_prefix => |prefix| {
                        const name = intern.internModuleName(prefix) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.InvalidName => return self_machine.undefinedActiveWord(),
                        };
                        return continueDispatchAfterLoad(self_machine, name, request);
                    },
                    .unregistered_module => |name| return continueDispatchAfterLoad(self_machine, name, request),
                    .unresolved => |chain| return self_machine.undefinedWordIn(request.qualified, chain),
                }
            },
        };
        return .yielded;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

/// Dispatches one export of an image reached as a value.
///
/// It is a second *resolution source*, not a second dispatch path: the
/// resolved binding goes through the same `executeResolved` tail as a name-
/// dispatched word, so home, privacy, annotation checks, trace metadata,
/// builtin/native behavior, and cancellation are the tail's business exactly
/// as they always were. The one property it cannot carry is state authority,
/// because a value-reached image has no slot — an intended absence rather than
/// a loss.
const HandleDispatchDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    /// Retained for the driver's whole life, which is also what keeps `image`
    /// usable: an `ImageRef` is a borrow valid at the call that produced it,
    /// and this value is the retention behind it.
    module: heap.Owned(Value),
    image: modules.ImageRef,
    validation: intern.NamespaceCursor,
    binding: ?intern.BindingName = null,
    home: ?*modules.ModuleHome = null,
    cursor: ?heap.Owned(modules.ModuleResolveCursor) = null,

    pub fn advance(evaluator: *Machine, self: *HandleDispatchDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.binding == null) {
                switch (self.validation.advance()) {
                    .pending => continue,
                    .complete => |maybe_name| {
                        const name = maybe_name orelse return evaluator.fail(
                            .domain,
                            "invoke requires an unqualified binding name",
                        );
                        self.binding = name;
                        self.home = modules.handleHome(self.image, evaluator.unit.module_access);
                        self.cursor = .init(modules.handleResolveCursor(
                            self.image,
                            intern.bindingId(name),
                        ));
                        evaluator.setActiveWord(.plain(intern.bindingId(name)));
                        continue;
                    },
                }
            }
            switch (self.cursor.?.borrowMut().advance()) {
                .pending => continue,
                .complete => |maybe_lease| {
                    const home = self.home.?;
                    const binding = self.binding.?;
                    const allocator = evaluator.unit.allocator;
                    // Both retentions this driver holds — the resolve cursor's
                    // pin and the module value — are released just below, and
                    // `scheduleWord` does not re-pin until it runs. Without a
                    // pin across that gap the image's refcount can reach zero
                    // in between and a concurrent domain drain can retire it
                    // while `home` and its scope are still in use. The
                    // registered path is safe for the same reason in different
                    // clothing: its resolution owns a generation lease. This
                    // also covers the synchronous `builtin` and `native` arms
                    // of `executeResolved`, which never reach `scheduleWord`.
                    var image_pin = home.pin(evaluator.unit.module_access);
                    defer image_pin.deinit();
                    self.cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.cursor = null;
                    self.module.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    evaluator.retireDriver(self);
                    const lease = maybe_lease orelse
                        return evaluator.undefinedWordIn(intern.bindingId(binding), .@"module-value");
                    var resolved: Resolution = .{
                        .lease = lease,
                        // No generation: there is no registration to be a
                        // generation of.
                        .execution_generation = null,
                        .home = home,
                        // The image has no canonical name, so the trace spells
                        // the local name alone. That is what an anonymous
                        // image honestly is; borrowing the parameter's local
                        // name would read better and claim more than is true.
                        .trace_word = homeTraceWord(home, lease.traceWord() orelse binding),
                        .origin = .module,
                    };
                    defer resolved.deinit(allocator);
                    try executeResolved(evaluator, &resolved);
                    return .detached;
                },
            }
        }
        return .yielded;
    }
};

/// Carries the exact dispatch request through module loading. The caller has
/// already consumed any dynamic `execute` operand, so replaying its source
/// instruction would not be equivalent to retrying the requested word.
fn continueDispatchAfterLoad(
    self: *Machine,
    name: intern.ModuleName,
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    if (self.unit.inherited.registry == null)
        return self.undefinedWordIn(request.qualified, .qualified);
    try self.autoLoadModule(name, request);
    return .detached;
}

/// After an auto-load, the requested module must actually be registered.
/// Checking that is what bounds the operation: a source that registered
/// nothing, or a different name, fails once here instead of starting another
/// load when its tagged continuation resumes.
fn continueQualifiedRequest(
    evaluator: *Machine,
    driver: anytype,
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    return switch (request.continuation) {
        .replay, .load_only => .completed,
        .dispatch => |dispatch_request| continuation: {
            evaluator.retireDriver(driver);
            evaluator.setActiveWord(.plain(dispatch_request.word));
            try evaluator.startDriver(DispatchDriver{
                .word = dispatch_request.word,
                .resolution = .init(.initAtCurrent(evaluator, dispatch_request.word)),
            });
            if (dispatch_request.site) |site|
                evaluator.setWorkDriverSite(site.code, site.index);
            if (dispatch_request.trace_parent) |parent|
                evaluator.setWorkDriverTraceParent(parent);
            break :continuation .detached;
        },
    };
}

fn verifyPublishedModule(
    evaluator: *Machine,
    driver: anytype,
    name: intern.ModuleName,
    loading: *heap.Owned(modules.LoadingLease),
    path: *heap.Owned(Value),
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    loading.borrowMut().finish();
    const registry = evaluator.unit.inherited.registry.?;
    const next = QualifiedRegistrationDriver{
        .name = name,
        .path = .init(path.take()),
        .acquisition = .init(registry.acquireCursor(name)),
        .request = request,
    };
    evaluator.retireDriver(driver);
    try evaluator.startDriver(next);
    return .detached;
}

const QualifiedRegistrationDriver = struct {
    name: intern.ModuleName,
    path: heap.Owned(Value),
    acquisition: heap.Owned(modules.Registry.AcquireCursor),
    request: QualifiedLoadRequest,

    pub fn advance(evaluator: *Machine, self: *QualifiedRegistrationDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        switch (self.acquisition.borrowMut().advance()) {
            .pending => return .yielded,
            .complete => |maybe_generation| {
                if (maybe_generation) |generation| {
                    var lease = generation;
                    lease.deinit();
                    return continueQualifiedRequest(evaluator, self, self.request);
                }
                const failure = evaluator.failFmt(
                    .io,
                    "loading module `{s}` registered nothing under that name",
                    .{intern.get(intern.moduleId(self.name))},
                );
                evaluator.unit.pending.?.addData(.path, self.path.borrow());
                return failure;
            },
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

fn executeResolved(self: *Machine, resolved: *Resolution) MachineError!void {
    self.unit.active_word = resolved.trace_word;
    const cross_home = resolved.home != null and resolved.home != self.unit.current.?.home();
    const cross_home_effect = if (cross_home) resolved.lease.effect else null;
    var check: ?EffectCheck = if (cross_home) switch (resolved.lease.binding) {
        // A native module word always carries a declared effect, so a missing
        // one is a malformed module rather than an omission.
        .native => try prepareEffectCheck(self, cross_home_effect, resolved.trace_word),
        // A builtin module word may omit its effect exactly as a source word
        // may. One that hands its work to a scheduler driver has to: the check
        // below reads the stack the instant the primitive returns, which is
        // before any deferred output exists.
        .builtin, .seed => if (cross_home_effect == null)
            null
        else
            try prepareEffectCheck(self, cross_home_effect, resolved.trace_word),
        .word => null,
    } else null;
    defer if (check) |*owned| owned.deinit(self.releaseDomain());
    switch (resolved.lease.binding) {
        .word => |body| {
            const body_header = env.quotationHeader(body);
            if (resolved.origin == .core) {
                heap.incRef(body_header);
                const fallback: DirectWordFallback = .{
                    .body = .init(body_header),
                    .word = resolved.trace_word,
                };
                return self.continueWithIdiom(
                    // Only a core-origin word reaches recognition, and a core
                    // word's trace spelling is its own atom.
                    .{ .direct = .{ .body = body_header, .word = resolved.trace_word.atom() } },
                    typedIdiomFallback(fallback),
                );
            }
            try scheduleWord(
                self,
                body_header,
                resolved.trace_word,
                resolved.home,
                resolved.defining_scope,
                cross_home_effect,
                resolved.takeBorrowPin(),
                resolved.takeBorrowedCell(),
            );
        },
        .seed => |seal| {
            self.sealUnitPlan(seal) catch |err| switch (err) {
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
            if (check) |*effect_check| try finishEffectCheck(self, effect_check);
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
            if (check) |*effect_check| try finishEffectCheck(self, effect_check);
        },
        .native => |callable| {
            const transferred = check;
            check = null;
            try native_call.begin(self, callable, transferred);
        },
    }
}

const DirectWordFallback = struct {
    body: heap.Owned(*Header),
    word: intern.TraceWord,
    pub fn run(evaluator: *Machine, self: *DirectWordFallback) MachineError!void {
        // Only a core-origin word reaches idiom recognition, and core alone is
        // its chain, so this fallback resumes one with no scope.
        return scheduleWord(evaluator, self.body.borrow(), self.word, null, null, null, null, null);
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

pub const ResolutionOrigin = resolution_core.Origin;

/// How a module-local definition is spelled when reached through `home`. An
/// anonymous construction root has no name to qualify with, so code running
/// inside a body under construction traces by its local name alone.
fn homeTraceWord(home: *const modules.ModuleHome, local: intern.BindingName) intern.TraceWord {
    const name = home.name() orelse return .plain(intern.bindingId(local));
    return .moduleLocal(name, local);
}
/// Which chain a failed lookup searched, reported as `'scope` in an
/// undefined-word error.
/// The chain a word with `written` as its resolution scope searches. A
/// session name is invisible to a module and to a prelude word for
/// different reasons, and saying which one applied is the difference
/// between a puzzling failure and an obvious one.
///
/// It is derived from the word's own scope, not from the running
/// activation: since resolution moved onto the word, the two differ in
/// exactly the interesting cases — a caller's quotation applied by a module
/// word searches the caller, and reporting the activation's chain there
/// would name the one place the lookup did not look.
fn lookupChainFor(written: ?*env.Scope) LookupChain {
    const scope = written orelse return .core;
    return if (scope.isModuleRoot()) .module else .session;
}

pub const LookupChain = enum {
    /// The activation's own lexical chain over core.
    session,
    /// A module image's own definitions over core.
    module,
    /// Core alone, which is what a primitive or embedded prelude definition
    /// resolves against.
    core,
    /// A registered module's exports, reached through a dotted name.
    qualified,
    /// The public exports of a module reached as a value. Not a scope miss at
    /// all: the name is simply not exported by that image.
    @"module-value",

    fn spelling(self: LookupChain) []const u8 {
        return switch (self) {
            .session => "session",
            .module => "module",
            .core => "core",
            .qualified => "qualified",
            .@"module-value" => "module-value",
        };
    }
};

pub const Resolution = struct {
    lease: env.BindingLease,
    execution_generation: ?modules.ExecutionGeneration,
    home: ?*modules.ModuleHome,
    /// The reference the borrow acquired for this dispatch, moved out of the
    /// cursor. `scheduleWord` consumes it so no second pin is taken.
    borrow_pin: ?modules.GenerationPin = null,
    /// The foreign scope borrowed for this dispatch, released by the activation
    /// that reads it rather than by the unit.
    borrowed_cell: ?*env.ScopeCell = null,
    trace_word: intern.TraceWord,
    origin: ResolutionOrigin,
    /// The scope this binding was found in, which is therefore the chain its
    /// own references resolve against. Null for a core-origin binding, whose
    /// chain is core alone, and for a module-origin one, whose chain is its
    /// image. Recording it is what makes "resolves where it was defined" hold
    /// without exception: reading the unit's root instead was wrong for
    /// anything defined in a child scope, such as inside one `@attempt`.
    defining_scope: ?*env.Scope = null,
    /// Moves the borrow's reference out, so `deinit` will not release it.
    pub fn takeBorrowPin(self: *Resolution) ?modules.GenerationPin {
        const owned = self.borrow_pin;
        self.borrow_pin = null;
        return owned;
    }

    pub fn takeBorrowedCell(self: *Resolution) ?*env.ScopeCell {
        const owned = self.borrowed_cell;
        self.borrowed_cell = null;
        return owned;
    }

    pub fn deinit(self: *Resolution, _: std.mem.Allocator) void {
        self.lease.deinit();
        if (self.execution_generation) |*generation| generation.deinit();
        // Released only if the dispatch never scheduled a body; `scheduleWord`
        // consumes them otherwise.
        if (self.borrow_pin) |*pin| pin.deinit();
        if (self.borrowed_cell) |cell| cell.releaseBorrow();
        self.* = undefined;
    }
};

/// Why resolution finished. Distinguishing an unregistered module from an
/// unknown name lets every qualified-name consumer auto-load exactly once.
pub const ResolutionOutcome = union(enum) {
    /// Nothing by that name is visible, and this is the chain that was
    /// searched. The cursor knows which of its phases ran out, so it says so
    /// rather than leaving the caller to guess from the spelling.
    unresolved: LookupChain,
    /// The reference is dotted and its module prefix has never been interned,
    /// so nothing can be registered under it yet. The slice borrows the
    /// interned spelling, which outlives every cursor.
    unknown_module_prefix: []const u8,
    /// The name is a well-formed qualified reference whose module is not
    /// registered; loading that module may make it resolvable.
    unregistered_module: intern.ModuleName,
    resolved: Resolution,

    /// The binding, if resolution produced one.
    pub fn binding(self: ResolutionOutcome) ?Resolution {
        return switch (self) {
            .resolved => |resolution| resolution,
            .unresolved, .unknown_module_prefix, .unregistered_module => null,
        };
    }
};

pub const ResolutionProgress = poll_api.Progress(ResolutionOutcome);
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
        core,
        complete,
    };
    /// The phases are sequential and their cursors are mutually exclusive, so
    /// they share one payload instead of each holding a permanently reserved
    /// field. Resolving a plain word used to cost the width of every
    /// resolution path at once — dotted-name splitting, registry acquisition,
    /// and qualified export lookup — though it touches two of them.
    /// `generation` stays outside the payload because it deliberately
    /// outlives the cursor that produced it: the lease is handed to the
    /// completed resolution.
    const Work = union(enum) {
        none,
        dot: intern.LastDotCursor,
        atom: intern.InternLookupCursor,
        module_validation: intern.ModuleNameCursor,
        binding_validation: intern.NamespaceCursor,
        acquisition: modules.Registry.AcquireCursor,
        direct: env.DirectLookupCursor,
        export_lookup: modules.ModuleResolveCursor,

        /// Only the three leased cursors own anything; the interning and
        /// name-validation cursors are pure position.
        fn deinit(self: *Work) void {
            switch (self.*) {
                .acquisition => |*cursor| cursor.deinit(),
                .direct => |*cursor| cursor.deinit(),
                .export_lookup => |*cursor| cursor.deinit(),
                .none, .dot, .atom, .module_validation, .binding_validation => {},
            }
            self.* = .none;
        }
    };
    allocator: std.mem.Allocator,
    registry: ?*modules.Registry,
    module_access: *const modules.ExecutionAccess,
    core: env.EnvironmentView,
    current_home: ?*modules.ModuleHome,
    word: u32,
    spelling: []const u8,
    phase: Phase = .dot,
    work: Work,
    dot_index: usize = 0,
    qualified_name: ?intern.QualifiedName = null,
    prefix: ?intern.ModuleName = null,
    export_name: ?intern.BindingName = null,
    scope: ?*env.Scope,
    /// The chain to report when the plain walk runs out. The qualified phases
    /// report `.qualified` instead, because a dotted name never searched the
    /// activation's own chain at all.
    plain_chain: LookupChain,
    /// The scope whose environment the in-flight `.direct` lookup is reading.
    /// `scope` has already advanced to its parent by then, so the searched
    /// scope has to be kept separately to be reported.
    searched_scope: ?*env.Scope = null,
    generation: ?modules.GenerationLease = null,
    /// The reference this dispatch's borrow acquired, if it had to acquire one.
    /// It rides here so the pin taken at the borrow is the *only* one: it is
    /// moved into the resolution and consumed by `scheduleWord`, which
    /// therefore does not pin again.
    borrow_pin: ?modules.GenerationPin = null,
    /// The foreign scope this dispatch borrowed, if any. Rides here so the
    /// activation that ends up reading the scope is the one that releases it.
    borrowed_cell: ?*env.ScopeCell = null,

    /// A cursor for a name that genuinely means "whatever the running chain
    /// says": reflection like `which`, `see`, and `doc`, and the fallback paths
    /// that re-enter resolution for a word already being dispatched.
    ///
    /// Named apart from `init` because the distinction is the one this branch
    /// keeps paying for. A stamped occurrence resolves where its *text* was
    /// written, which is rarely the running chain; the seven verbatim copies
    /// this replaces were each a place where that difference was invisible, and
    /// one of them -- the idiom recognizer -- silently ran core's `+` where a
    /// module's own shadow was the answer. Reaching this from a dispatch path
    /// now means visibly discarding a `WordRef` for its bare id, which greps.
    pub fn initAtCurrent(evaluator: *Machine, word: u32) ResolutionCursor {
        return .init(evaluator, word, evaluator.unit.current.?.resolutionScope(), null, null);
    }

    pub fn init(
        evaluator: *Machine,
        word: u32,
        written: ?*env.Scope,
        borrow_pin: ?modules.GenerationPin,
        borrowed_cell: ?*env.ScopeCell,
    ) ResolutionCursor {
        const spelling = intern.get(word);
        return .{
            .borrow_pin = borrow_pin,
            .borrowed_cell = borrowed_cell,
            .allocator = evaluator.unit.allocator,
            .registry = evaluator.unit.inherited.registry,
            .module_access = evaluator.unit.module_access,
            .core = evaluator.unit.environment.coreView(),
            .current_home = evaluator.unit.current.?.home(),
            .word = word,
            .spelling = spelling,
            .work = .{ .dot = intern.lastDotCursor(spelling) },
            .scope = written,
            .plain_chain = lookupChainFor(written),
        };
    }

    pub fn deinit(self: *ResolutionCursor) void {
        self.work.deinit();
        if (self.generation) |*lease| lease.deinit();
        // Released here only when no resolution took them: a dispatch that
        // schedules a body moves them out first.
        if (self.borrow_pin) |*pin| pin.deinit();
        if (self.borrowed_cell) |cell| cell.releaseBorrow();
        self.* = undefined;
    }

    /// Hands the borrow's reference to the resolution being produced.
    fn takeBorrowPin(self: *ResolutionCursor) ?modules.GenerationPin {
        const owned = self.borrow_pin;
        self.borrow_pin = null;
        return owned;
    }

    fn takeBorrowedCell(self: *ResolutionCursor) ?*env.ScopeCell {
        const owned = self.borrowed_cell;
        self.borrowed_cell = null;
        return owned;
    }

    fn releaseGeneration(self: *ResolutionCursor) void {
        if (self.generation) |*lease| lease.deinit();
        self.generation = null;
    }

    /// The home a module-local hit executes against.
    ///
    /// It used to be the invoking home unconditionally, on the premise that such
    /// a hit "came out of the image the activation is already running, because a
    /// module body's resolution scope is rooted at that image and nothing else".
    /// Moving scope onto the word falsified that: a quotation that escaped its
    /// module carries its own image's scope, so the hit can come out of an image
    /// this activation is not running — and taking the caller's home there gave
    /// the caller's `within` slot to someone else's private code.
    ///
    /// So a *foreign* hit executes against its own image's registration-less
    /// home. No acquire happens here: the borrow in `executeWord` already proved
    /// that image live, either by holding a fresh pin or by matching the
    /// activation's own. Re-pinning would be a second reference for one
    /// dispatch, and the unconditional `pin`/`retain` must never appear here —
    /// it is a `fetchAdd` that asserts on a zero refcount and resurrects a
    /// destroyed object in ReleaseFast.
    fn homeForLocalHit(self: *ResolutionCursor) ?*modules.ModuleHome {
        const searched = self.searched_scope orelse return self.current_home;
        const image_home = modules.homeForModuleRootScope(searched) orelse
            return self.current_home;
        // A double-registered image entered through either name stays
        // non-foreign, so `within` keeps targeting the registration the call
        // actually came through.
        if (self.current_home) |running| {
            if (modules.sameImage(running, image_home, self.module_access))
                return running;
        }
        return image_home;
    }

    fn directResult(self: *ResolutionCursor, lease: env.BindingLease) Resolution {
        const local = lease.traceWord();
        const home = if (local == null) null else self.homeForLocalHit();
        return .{
            .lease = lease,
            .execution_generation = null,
            .home = home,
            .borrow_pin = self.takeBorrowPin(),
            .borrowed_cell = self.takeBorrowedCell(),
            .trace_word = if (home) |resolved| homeTraceWord(resolved, local.?) else .plain(self.word),
            .origin = if (home != null) .module else .direct,
            // A module-local hit resolves against its image, which the home
            // supplies; anything else resolves against the scope it was found
            // in.
            .defining_scope = if (home != null) null else self.searched_scope,
        };
    }

    /// A qualified reference resolved through a registered generation. It is
    /// the only path that hands a generation lease to its resolution, so the
    /// origin is always the module it named.
    fn generationResult(
        self: *ResolutionCursor,
        lease: env.BindingLease,
    ) Resolution {
        var generation_lease = self.generation.?;
        self.generation = null;
        const execution_generation = generation_lease.enterExecution(self.module_access);
        const home = execution_generation.home(self.module_access);
        return .{
            .lease = lease,
            .execution_generation = execution_generation,
            .home = home,
            .trace_word = homeTraceWord(home, lease.traceWord().?),
            .origin = .module,
        };
    }

    pub fn advance(self: *ResolutionCursor) ResolutionProgress {
        return switch (self.phase) {
            .dot => switch (self.work.dot.advance()) {
                .pending => .pending,
                .complete => |maybe_dot| result: {
                    if (maybe_dot) |dot_index| {
                        if (dot_index == 0 or dot_index + 1 == self.spelling.len or self.registry == null) {
                            self.work.deinit();
                            self.phase = .complete;
                            break :result .{ .complete = .{ .unresolved = .qualified } };
                        }
                        self.dot_index = dot_index;
                        self.work = .{ .atom = intern.lookupCursor(self.spelling[0..dot_index]) };
                        self.phase = .prefix;
                    } else {
                        self.work.deinit();
                        self.phase = .scope;
                    }
                    break :result .pending;
                },
            },
            .prefix => switch (self.work.atom.advance()) {
                .pending => .pending,
                .complete => |maybe_prefix| result: {
                    const prefix = maybe_prefix orelse {
                        self.work.deinit();
                        self.phase = .complete;
                        break :result .{ .complete = .{
                            .unknown_module_prefix = self.spelling[0..self.dot_index],
                        } };
                    };
                    self.work = .{ .module_validation = .init(prefix) };
                    self.phase = .prefix_validate;
                    break :result .pending;
                },
            },
            // The module is acquired before its export name is even looked
            // up. Only that ordering makes a qualified miss report an
            // unregistered *module*: an export atom that no source has
            // interned yet is exactly the state a first reference is in.
            .prefix_validate => switch (self.work.module_validation.advance()) {
                .pending => .pending,
                .complete => |maybe_module| result: {
                    self.prefix = maybe_module orelse {
                        self.work.deinit();
                        self.phase = .complete;
                        break :result .{ .complete = .{ .unresolved = .qualified } };
                    };
                    self.work = .{ .acquisition = self.registry.?.acquireCursor(self.prefix.?) };
                    self.phase = .qualified_acquire;
                    break :result .pending;
                },
            },
            .qualified_acquire => switch (self.work.acquisition.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| result: {
                    self.work.deinit();
                    self.generation = maybe_generation;
                    if (self.generation == null) {
                        self.phase = .complete;
                        break :result .{ .complete = .{ .unregistered_module = self.prefix.? } };
                    }
                    self.work = .{ .atom = intern.lookupCursor(self.spelling[self.dot_index + 1 ..]) };
                    self.phase = .export_name;
                    break :result .pending;
                },
            },
            .export_name => switch (self.work.atom.advance()) {
                .pending => .pending,
                .complete => |maybe_export| result: {
                    const export_name = maybe_export orelse {
                        self.work.deinit();
                        self.releaseGeneration();
                        self.phase = .complete;
                        break :result .{ .complete = .{ .unresolved = .qualified } };
                    };
                    self.work = .{ .binding_validation = .init(export_name) };
                    self.phase = .export_validate;
                    break :result .pending;
                },
            },
            .export_validate => switch (self.work.binding_validation.advance()) {
                .pending => .pending,
                .complete => |maybe_binding| result: {
                    self.export_name = maybe_binding orelse {
                        self.work.deinit();
                        self.releaseGeneration();
                        self.phase = .complete;
                        break :result .{ .complete = .{ .unresolved = .qualified } };
                    };
                    self.qualified_name = intern.qualifiedName(self.prefix.?, self.export_name.?);
                    self.work = .{ .export_lookup = self.generation.?.resolveCursor(
                        intern.bindingId(intern.qualifiedBinding(self.qualified_name.?)),
                    ) };
                    self.phase = .qualified_export;
                    break :result .pending;
                },
            },
            .qualified_export => switch (self.work.export_lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.work.deinit();
                    const lease = maybe_lease orelse {
                        self.releaseGeneration();
                        self.phase = .complete;
                        break :result .{ .complete = .{ .unresolved = .qualified } };
                    };
                    self.phase = .complete;
                    break :result .{ .complete = .{ .resolved = self.generationResult(lease) } };
                },
            },
            .scope => result: {
                const current = self.scope orelse {
                    self.work = .{ .direct = self.core.directLookupCursor(self.word) };
                    self.phase = .core;
                    break :result .pending;
                };
                self.scope = current.parent;
                if (current.environmentOrNull()) |environment| {
                    self.searched_scope = current;
                    self.work = .{ .direct = environment.directLookupCursor(self.word) };
                    self.phase = .direct;
                }
                break :result .pending;
            },
            .direct => switch (self.work.direct.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.work.deinit();
                    if (maybe_lease) |lease| {
                        self.phase = .complete;
                        break :result .{ .complete = .{ .resolved = self.directResult(lease) } };
                    }
                    self.searched_scope = null;
                    self.phase = .scope;
                    break :result .pending;
                },
            },
            .core => switch (self.work.direct.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.work.deinit();
                    self.phase = .complete;
                    var lease = maybe_lease orelse
                        break :result .{ .complete = .{ .unresolved = self.plain_chain } };
                    if (lease.visibility == .private) {
                        lease.deinit();
                        break :result .{ .complete = .{ .unresolved = self.plain_chain } };
                    }
                    break :result .{ .complete = .{ .resolved = .{
                        .lease = lease,
                        .execution_generation = null,
                        .home = null,
                        .trace_word = .plain(self.word),
                        .origin = .core,
                    } } };
                },
            },
            .complete => unreachable,
        };
    }
};

pub const ShadowProgress = poll_api.Progress([]intern.TraceWord);
pub const ShadowCursor = struct {
    const Phase = enum { dot, scope, direct, core, materialize, complete };
    /// The same reservation `ResolutionCursor.Work` removes, for the same
    /// reason: these phase cursors are mutually exclusive. The walk itself is
    /// not shared with that cursor — this one records every hit and keeps
    /// going, where resolution stops at the first and takes ownership of it.
    const Work = union(enum) {
        none,
        dot: intern.DotCursor,
        direct: env.DirectLookupCursor,

        fn deinit(self: *Work) void {
            switch (self.*) {
                .direct => |*cursor| cursor.deinit(),
                .none, .dot => {},
            }
            self.* = .none;
        }
    };
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    core: env.EnvironmentView,
    word: u32,
    phase: Phase = .dot,
    work: Work,
    scope: ?*env.Scope,
    current_home: ?*modules.ModuleHome,
    search: resolution_core.Search = .searching,
    found: poll_api.ChunkList(intern.TraceWord),
    output: ?[]intern.TraceWord = null,
    iterator: ?poll_api.ChunkList(intern.TraceWord).Iterator = null,
    output_index: usize = 0,

    pub fn init(evaluator: *Machine, word: u32) ShadowCursor {
        return .{
            .allocator = evaluator.unit.allocator,
            .releases = evaluator.releaseDomain(),
            .core = evaluator.unit.environment.coreView(),
            .current_home = evaluator.unit.current.?.home(),
            .word = word,
            .work = .{ .dot = intern.dotCursor(intern.get(word)) },
            .scope = evaluator.unit.current.?.resolutionScope(),
            .found = .init(evaluator.unit.allocator),
        };
    }
    pub fn deinit(self: *ShadowCursor) void {
        self.work.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.found.retire(self.releases);
        self.* = undefined;
    }
    fn record(
        self: *ShadowCursor,
        trace_word: intern.TraceWord,
        origin: ResolutionOrigin,
    ) error{OutOfMemory}!void {
        const decision = resolution_core.consider(self.search, .{ .trace_word = trace_word, .origin = origin });
        self.search = decision.next;
        switch (decision.command) {
            .winner => {},
            .shadow => |shadow| try self.found.append(shadow.trace_word),
        }
    }
    pub fn advance(self: *ShadowCursor) error{OutOfMemory}!ShadowProgress {
        return switch (self.phase) {
            .dot => switch (self.work.dot.advance()) {
                .pending => .pending,
                .complete => |maybe_dot| result: {
                    self.work.deinit();
                    if (maybe_dot != null) {
                        self.output = try self.allocator.alloc(intern.TraceWord, 0);
                        self.phase = .complete;
                        break :result .{ .complete = self.takeOutput() };
                    }
                    self.phase = .scope;
                    break :result .pending;
                },
            },
            .scope => result: {
                const current = self.scope orelse {
                    self.work = .{ .direct = self.core.directLookupCursor(self.word) };
                    self.phase = .core;
                    break :result .pending;
                };
                self.scope = current.parent;
                if (current.environmentOrNull()) |environment| {
                    self.work = .{ .direct = environment.directLookupCursor(self.word) };
                    self.phase = .direct;
                }
                break :result .pending;
            },
            .direct => switch (self.work.direct.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.work.deinit();
                    if (maybe_lease) |loaded| {
                        var lease = loaded;
                        defer lease.deinit();
                        // Same reasoning as `directResult`: a module-local
                        // binding reached lexically belongs to the image this
                        // activation is running, so the invoking home spells it.
                        const home = if (lease.traceWord() == null) null else self.current_home;
                        if (home) |resolved|
                            try self.record(
                                homeTraceWord(resolved, lease.traceWord().?),
                                .module,
                            )
                        else
                            try self.record(.plain(self.word), .direct);
                    }
                    self.phase = .scope;
                    break :result .pending;
                },
            },
            .core => switch (self.work.direct.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    self.work.deinit();
                    if (maybe_lease) |loaded| {
                        var lease = loaded;
                        defer lease.deinit();
                        if (lease.visibility == .public) try self.record(.plain(self.word), .core);
                    }
                    self.output = try self.allocator.alloc(intern.TraceWord, self.found.count);
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
    fn takeOutput(self: *ShadowCursor) []intern.TraceWord {
        const result = self.output.?;
        self.output = null;
        return result;
    }
};

fn scheduleWord(
    self: *Machine,
    body: *Header,
    word: intern.TraceWord,
    resolved_home: ?*modules.ModuleHome,
    defining_scope: ?*env.Scope,
    effect: ?env.Effect,
    borrow_pin: ?modules.GenerationPin,
    borrowed_cell: ?*env.ScopeCell,
) MachineError!void {
    const scope = if (resolved_home) |home|
        home.scope(self.unit.module_access)
    else
        self.unit.current.?.scope();
    const home = resolved_home orelse self.unit.current.?.home();
    // Each binding resolves against the chain it was defined in, with no
    // exception. A module word resolves against its home. Anything else
    // resolves against the scope resolution found it in, which is null for a
    // core or prelude definition — those were published against core alone,
    // so a session redefinition shadows one for session code without
    // rewriting what already-evaluated definitions mean — and is the found
    // scope itself otherwise, including a child scope such as one `@attempt`
    // opens.
    const resolution_scope: ?*env.Scope = if (resolved_home) |generation|
        generation.scope(self.unit.module_access)
    else
        defining_scope;
    // One pin per dispatch, never two. The borrow already acquired this
    // image's reference and handed it over; re-pinning here would add a second
    // pin-set walk to the hot path for a reference already held.
    if (borrow_pin) |owned| {
        var consumed = owned;
        try self.unit.adoptGeneration(&consumed);
    } else if (resolved_home) |generation| try self.unit.pinGeneration(generation);
    var check = if (effect != null) try prepareEffectCheck(self, effect, word) else null;
    var effect_tail = self.replaceTailEffectCandidate(body);
    const application_tail = self.tailApplicationIndex();
    _ = self.suspendCurrent() catch return error.OutOfMemory;
    if (check) |*effect_check| {
        const check_index: EffectCheckIndex = @enumFromInt(@as(u32, @intCast(self.unit.frames.items.len)));
        effect_check.activateSource(body, check_index, self.unit.effect_check_index);
        var continuation = OwnedFrame.init(.{ .effect_check = effect_check.* });
        defer continuation.deinit(self.releaseDomain(), self.unit.allocator);
        try self.appendFrame(&continuation);
        self.unit.effect_check_index = check_index;
        effect_tail = check_index;
    }
    heap.incRef(body);
    self.unit.current = .{
        .code = body,
        .ip = 0,
        .borrowed_scope = borrowed_cell,
        .site = .{
            .scope = scope,
            .resolution_scope = resolution_scope,
            .home = home,
            .resolution_scope_id = ExecutionSite.idOf(resolution_scope),
        },
        .traced_word = word,
        .effect_tail = effect_tail,
        .application_tail = application_tail,
    };
}
fn prepareEffectCheck(
    self: *Machine,
    effect: ?env.Effect,
    word: intern.TraceWord,
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
        .row = declared.row,
        .word = word,
    };
}
fn resumeFrames(self: *Machine) MachineError!bool {
    while (self.unit.frames.pop()) |frame| switch (frame) {
        .eval => |continuation| {
            self.unit.current = continuation;
            return true;
        },
        .effect_check => |owned| {
            var check = owned;
            defer check.deinit(self.releaseDomain());
            try finishEffectCheck(self, &check);
        },
        .application => |continuation| {
            var application_selection = continuation.selection;
            defer application_selection.deinit(self.releaseDomain());
            const launch: Machine.ApplicationLaunch, const base: StackWindow = switch (continuation.mode) {
                .in_place => |window| .{ .in_place, window },
                .isolated => |isolated| blk: {
                    const window: StackWindow = @enumFromInt(@as(u32, @intCast(self.unit.stack_base)));
                    self.releaseApplicationScope(isolated.child);
                    self.unit.stack_base = isolated.previous_base.base();
                    break :blk .{ .isolated, window };
                },
            };
            const next = continuation.resume_fn(
                self,
                continuation.context,
                base,
                @ptrCast(&application_selection),
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
                    .provenance = .boundary,
                }, launch, continuation.traced_word);
                return true;
            }
            continuation.deinit_fn(self.releaseDomain(), self.unit.allocator, continuation.context);
            // Native work installed by an application continuation is the
            // continuation's tail. Do not cross later continuation frames until
            // that owned work has produced its stack result.
            if (self.unit.hasWorkDriver()) return true;
            // The same rule holds for the bounded native step a finished
            // continuation records: the machine loop consumes exactly one per
            // pass, so a second continuation resumed here would assert against
            // a yield nobody observed. Nested in-place applications finishing
            // in one unwind are the ordinary case — `(q) dip` inside `bi`.
            if (self.unit.native == .yielded) return true;
        },
        .qualified_after_load => |continuation| {
            var loading = continuation.loading;
            defer loading.deinit();
            var path = heap.OwnedValue.init(self.releaseDomain(), continuation.path);
            defer path.deinit();
            loading.finish();
            // Source loading temporarily replaces the caller's evaluation.
            // Replay requests resume at their restored primitive operands;
            // dispatch requests resume the exact stored word without replay.
            switch (continuation.request.continuation) {
                .replay, .dispatch => {
                    const caller = self.unit.frames.pop().?;
                    self.unit.current = switch (caller) {
                        .eval => |evaluation| evaluation,
                        else => unreachable,
                    };
                },
                .load_only => {},
            }
            // The registration check bounds the retry and gives every
            // transport the same post-load handoff.
            const registry = self.unit.inherited.registry.?;
            try self.startDriver(QualifiedRegistrationDriver{
                .name = continuation.name,
                .path = .init(path.take()),
                .acquisition = .init(registry.acquireCursor(continuation.name)),
                .request = continuation.request,
            });
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
pub fn finishEffectCheck(self: *Machine, check: *EffectCheck) MachineError!void {
    check.restoreActive(self.unit);
    if (check.row) return;
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
    if (check.takeCandidate()) |candidate|
        self.unit.pending.?.site = .{ .contract_quotation = candidate };
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
    const owned = boundary.mode.module;
    var image = owned.image;
    defer image.deinit();
    const observed = self.unit.stack.items.len - boundary.stack_base;
    try image.reserveTemplate(observed);
    const driver = try self.unit.allocator.create(ModuleCompletionDriver);
    driver.* = .{
        .image = .init(image.move()),
        .validation = if (owned.registration) |symbol| .init(symbol) else null,
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
            const home = evaluator.unit.current.?.home().?;
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

/// The registry-mutation half of module publication, reached either by
/// `register` on a value or by a `@defm` boundary that has just finished
/// constructing one. Both spellings therefore share one publication protocol.
fn advanceRegistration(
    evaluator: *Machine,
    cursor: *modules.Registry.RegistrationCursor,
) MachineError!WorkProgress {
    var budget: usize = kernel_poll_quantum;
    while (budget != 0) : (budget -= 1) {
        switch (cursor.advance() catch |err| switch (err) {
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

/// Pushes up to `budget` of a plan's seeds, in list order, onto the stack they
/// seed, and reports how far it got. Capacity for each slice is secured before
/// its pushes, so a failure adds no partial value; a prefix already on the
/// stack is released by the ordinary boundary or Unit teardown, exactly as any
/// other operand would be.
fn advanceSeeds(
    unit: *Unit,
    seeds: *Header,
    from: usize,
    budget: usize,
) error{OutOfMemory}!usize {
    const count: usize = @intCast(seeds.length());
    const end = @min(from + budget, count);
    try unit.stack.ensureUnusedCapacity(unit.allocator, end - from);
    for (from..end) |index| {
        const item = list.atUnchecked(.{ .list = seeds }, index);
        unit.stack.appendAssumeCapacity(item);
        heap.retainValue(item);
    }
    return end;
}

/// What a `ConstructionDriver` opens once its body is final.
const ConstructionTarget = union(enum) {
    /// `@attempt`: a child scope on the enclosing chain, created at open time.
    attempt,
    /// `@module`/`@defm`: the candidate image and the name it registers under.
    image: struct { candidate: modules.OwnedImage, registration: ?u32 },

    pub fn deinit(self: *ConstructionTarget) void {
        switch (self.*) {
            .attempt => {},
            .image => |*owned| owned.candidate.deinit(),
        }
        self.* = .attempt;
    }
};

/// The user-sized half of opening a unit: re-scoping a witnessed construction
/// body, and materializing a plan's seeds onto the stack it seeds.
///
/// Both are proportional to what the program wrote, so neither may run to
/// completion inside one scheduler step. Everything the boundary will need is
/// held here meanwhile — the candidate image, the source body, the finished
/// copy, and the seeds — so abandoning the unit at any point releases all of it
/// through field ownership and publishes nothing.
///
/// The driver stays installed across the open phase on purpose: the evaluator
/// services a work driver before the activation's own code, so the body cannot
/// begin until the last seed is on the stack.
const ConstructionDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .fields;
    target: heap.Owned(ConstructionTarget),
    /// The re-scoping pass and the source it reads, both absent when the body
    /// is not text this archive's reader wrote.
    rescope: ?heap.Owned(spans.SpanArchive.RescopeCursor),
    source: ?heap.Owned(*Header),
    /// The body to run: the finished copy, or the input body when nothing was
    /// re-scoped. Absent only while the copy is still being built.
    body: ?heap.Owned(*Header),
    seeds: ?heap.Owned(*Header),
    /// The word that opened the construction, captured because the boundary is
    /// opened in a later step than the one that dispatched it.
    word: intern.TraceWord,
    seeded: usize = 0,
    phase: enum { rescope, open, seed } = .rescope,

    pub fn advance(evaluator: *Machine, self: *ConstructionDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        switch (self.phase) {
            .rescope => {
                var work: poll_api.WorkBudget = .init(construction_work_quantum);
                const progress = self.rescope.?.borrowMut().advance(&work) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidProvenance => @panic("archive refused its own completed re-scope publication"),
                };
                const stamped = switch (progress) {
                    .pending => return .yielded,
                    .complete => |header| header,
                };
                self.rescope.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.rescope = null;
                evaluator.releaseDomain().releaseHeader(self.source.?.take());
                self.source = null;
                self.body = .init(stamped);
                self.phase = .open;
                return .yielded;
            },
            .open => {
                // The body is consumed by the open, on success and on failure
                // alike; the seeds are not, so they stay owned here until the
                // boundary they seed exists.
                const body = self.body.?.take();
                self.body = null;
                switch (self.target.borrowMut().*) {
                    .attempt => {
                        _ = self.target.take();
                        try evaluator.openAttempt(body);
                    },
                    .image => |*owned| {
                        const registration = owned.registration;
                        var candidate = owned.candidate.move();
                        _ = self.target.take();
                        errdefer candidate.deinit();
                        try evaluator.openImageBoundary(
                            &candidate,
                            registration,
                            self.word,
                            body,
                        );
                    },
                }
                self.phase = .seed;
                return .yielded;
            },
            .seed => {
                // A construction that only had a body to re-scope reaches this
                // phase with nothing to seed, which is the whole of its work.
                const owned = self.seeds orelse return .completed;
                const seeds = owned.borrow();
                self.seeded = try advanceSeeds(
                    evaluator.unit,
                    seeds,
                    self.seeded,
                    construction_work_quantum,
                );
                if (self.seeded != @as(usize, @intCast(seeds.length()))) return .yielded;
                return .completed;
            },
        }
    }
};

/// The child half of the same rule: a fresh Unit's own first slices put its
/// plan's seeds on its stack, so a spawn never copies a user-sized seed list
/// inside the step that created it — and `@each` cannot multiply that copy by
/// the number of children it starts per turn.
const ChildSeedDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .fields;
    seeds: heap.Owned(*Header),
    seeded: usize = 0,

    pub fn advance(evaluator: *Machine, self: *ChildSeedDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        const seeds = self.seeds.borrow();
        self.seeded = try advanceSeeds(evaluator.unit, seeds, self.seeded, construction_work_quantum);
        if (self.seeded != @as(usize, @intCast(seeds.length()))) return .yielded;
        return .completed;
    }
};

const ModuleRegisterDriver = struct {
    pub const address_stable_driver = {};
    module: heap.Owned(Value),
    cursor: heap.Owned(modules.Registry.RegistrationCursor),
    pub fn advance(evaluator: *Machine, self: *ModuleRegisterDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        return advanceRegistration(evaluator, self.cursor.borrowMut());
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

/// Finishes one construction boundary: capture the residual stack as the
/// image's template, freeze the image, then either register it under the name
/// the boundary carried or hand it to the program as a value.
const ModuleCompletionDriver = struct {
    pub const address_stable_driver = {};
    image: heap.Owned(modules.OwnedImage),
    /// The same image once construction is over. Sealing consumes `image`, so
    /// no template write or definition can reach it after this point.
    sealed: ?heap.Owned(modules.SealedImage) = null,
    /// Absent for `@module`, which hands the image to the program instead.
    validation: ?intern.ModuleNameCursor,
    cursor: ?heap.Owned(modules.Registry.RegistrationCursor),
    /// Construction-stack values still to move into the image template,
    /// counted from the top of the residual window down.
    captured: usize,
    phase: enum { capture, validate, publish } = .capture,
    pub fn advance(evaluator: *Machine, self: *ModuleCompletionDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.phase) {
            .capture => {
                if (self.captured != 0) {
                    self.captured -= 1;
                    self.image.borrow().placeTemplate(
                        self.captured,
                        evaluator.unit.takeStackOwned().?,
                    );
                    continue;
                }
                self.sealed = .init(self.image.borrowMut().seal());
                if (self.validation == null) {
                    const item = try self.sealed.?.borrowMut().intoValue(evaluator.unit.allocator);
                    return .{ .output = item };
                }
                self.phase = .validate;
            },
            .validate => switch (self.validation.?.advance()) {
                .pending => {},
                .complete => |maybe_name| {
                    const name = maybe_name orelse return evaluator.fail(
                        .domain,
                        "@defm requires a valid module name",
                    );
                    self.cursor = .init(evaluator.unit.inherited.registry.?.registrationCursor(
                        self.sealed.?.borrow().ref(),
                        name,
                        &evaluator.unit.turn_authority,
                    ));
                    self.phase = .publish;
                },
            },
            .publish => return advanceRegistration(evaluator, self.cursor.?.borrowMut()),
        };
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
    const trace = try self.unit.allocator.alloc(intern.TraceWord, capacity);
    errdefer self.unit.allocator.free(trace);
    const resolved = try self.unit.allocator.alloc(u32, capacity);
    errdefer self.unit.allocator.free(resolved);
    const driver = try self.unit.allocator.create(FailureDriver);
    driver.* = .{
        .allocator = self.unit.allocator,
        .failure = self.unit.pending.?,
        .trace = trace,
        .resolved = resolved,
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
    /// The activation chain, innermost first. Entries are trace words rather
    /// than atoms because a module-local word's spelling depends on the
    /// registration it ran under; `resolved` holds the interned spellings.
    trace: []intern.TraceWord,
    resolved: []u32,
    trace_count: usize = 0,
    resolve_index: usize = 0,
    resolver: ?intern.TraceWordCursor = null,
    frame_index: usize,
    location_cursor: ?spans.SpanArchive.LocateCursor = null,
    location: ?spans.LocatedSpan = null,
    value_cursor: ?ErrorValueCursor = null,
    error_value: ?Value = null,
    boundary_index: ?FrameIndex,
    attempt_index: ?FrameIndex = null,
    attempt_stack_base: usize = 0,
    /// Where the locals stack returns to. A body that fails between
    /// `_ll` and `_dl` leaves its names behind; unwinding is
    /// the only thing that will release them.
    attempt_locals_base: usize = 0,
    previous_base: usize = 0,
    previous_boundary: ?FrameIndex = null,
    outcome_inserter: ?intern.InternInsertionCursor = null,
    outcome_pair: [1]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }},
    outcome_builder: ?kernel_storage.DictMaterializer = null,
    phase: enum { trace, spell, locate, value, nearest, current, frames, boundary, locals, stack, outcome_name, outcome, finish } = .trace,

    fn appendInitial(self: *FailureDriver, evaluator: *Machine) void {
        if (self.failure.word) |word| self.appendTrace(word);
        if (self.failure.trace_parent) |word| self.appendTrace(word);
        if (evaluator.unit.current) |current|
            if (current.traced_word != no_word) self.appendTrace(current.traced_word);
    }
    fn appendTrace(self: *FailureDriver, word: intern.TraceWord) void {
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
        if (self.resolver) |*cursor| cursor.deinit();
        self.failure.retire(releases);
        storage_allocator.free(self.trace);
        storage_allocator.free(self.resolved);
    }
    fn beginLocation(self: *FailureDriver, evaluator: *Machine) void {
        if (self.failure.site) |site| {
            self.location_cursor = switch (site) {
                .token => |token| evaluator.unit.archive.locateCursor(token.code, token.index),
                .contract_quotation => |candidate| evaluator.unit.archive.locateQuotationCursor(candidate.borrow()),
            };
            self.phase = .locate;
        } else self.beginValue();
    }
    fn beginValue(self: *FailureDriver) void {
        self.value_cursor = .init(
            self.allocator,
            &self.failure,
            // `appendInitial` puts the failing word first when there is one,
            // so its spelling is the first resolved entry.
            .{
                .word = if (self.failure.word != null) self.resolved[0] else null,
                .trace = self.resolved[0..self.trace_count],
            },
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
                    self.phase = .spell;
                    continue;
                }
                self.frame_index -= 1;
                switch (evaluator.unit.frames.items[self.frame_index]) {
                    .eval => |frame| if (frame.traced_word != no_word) self.appendTrace(frame.traced_word),
                    .effect_check, .application, .qualified_after_load, .boundary => {},
                }
            },
            // Qualifying a module-local word interns its spelling. Failures
            // are rare, so this is the one place that cost is paid.
            .spell => {
                if (self.resolve_index == self.trace_count) {
                    self.beginLocation(evaluator);
                    continue;
                }
                if (self.resolver == null)
                    self.resolver = try .init(self.allocator, self.trace[self.resolve_index]);
                switch (try self.resolver.?.advance()) {
                    .pending => {},
                    .complete => |id| {
                        self.resolver.?.deinit();
                        self.resolver = null;
                        self.resolved[self.resolve_index] = id;
                        self.resolve_index += 1;
                    },
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
                    self.attempt_locals_base = boundary.locals_base;
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
                    evaluator.unit.deinitPoppedFrame(evaluator.unit.frames.pop().?);
                } else self.phase = .boundary;
            },
            .boundary => {
                if (self.attempt_index != null) {
                    evaluator.unit.deinitPoppedFrame(evaluator.unit.frames.pop().?);
                }
                self.phase = .locals;
            },
            .locals => {
                const target = @min(self.attempt_locals_base, evaluator.unit.locals.items.len);
                if (evaluator.unit.locals.items.len != target) {
                    const item = evaluator.unit.locals.pop().?;
                    evaluator.releaseDomain().releaseValue(item);
                    continue;
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
