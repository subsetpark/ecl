//! Defunctionalized CEK evaluator, boundary unwinding, and error dicts.
const std = @import("std");
const session_options = @import("session_options");
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
const poll_api = @import("poll.zig");
const stdlib = @import("stdlib.zig");
const kernel_storage = @import("kernel_storage.zig");
const console_api = @import("console.zig");
const task_join_core = @import("task_join_core.zig");
const resolution_core = @import("resolution_core.zig");
const pkg_lock = @import("pkg_lock.zig");
const pkg_catalog = @import("pkg_catalog.zig");
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
    explicit_location: struct {
        source_name: []u8,
        span: reader.Span,
    },

    fn deinit(self: *FailureSite, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .token => {},
            .contract_quotation => |*candidate| candidate.deinit(releases),
            .explicit_location => |location| releases.allocator.free(location.source_name),
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
};

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
    names: [9]u32 = .{0} ** 9,
    data_pairs: [8]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }} ** 8,
    outer_pairs: [5]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }} ** 5,
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
        self.outer_pairs[count] = .{ .{ .symbol = self.names[1] }, .{ .symbol = self.names[0] } };
        count += 1;
        self.outer_pairs[count] = .{ .{ .symbol = self.names[2] }, values.base.message };
        count += 1;
        if (self.resolved.word) |word| {
            self.outer_pairs[count] = .{ .{ .symbol = self.names[3] }, .{ .symbol = word } };
            count += 1;
        }
        self.outer_pairs[count] = .{ .{ .symbol = self.names[4] }, values.base.trace };
        count += 1;
        self.outer_pairs[count] = .{ .{ .symbol = self.names[5] }, values.data };
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
    pub fn advance(self: *OrdinaryErrorCursor) error{OutOfMemory}!ErrorValueProgress {
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
            .message => |*builder| switch (try builder.advance(1)) {
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
                    trace.items[trace.index] = .{ .symbol = self.resolved.trace[trace.index] };
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
            .trace_build => |*trace| switch (try trace.builder.advance(1)) {
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
                        .cursor = intern.insertionCursor(@tagName(self.failure.data[data.index].key)),
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
                    self.data_pairs[insertion.index] = .{ .{ .symbol = key }, entry.value };
                    self.state = .{ .data = .{
                        .base = insertion.base,
                        .index = insertion.index + 1,
                    } };
                    break :result .pending;
                },
            },
            .source => |*source| switch (try source.builder.advance(1)) {
                .pending => .pending,
                .complete => |item| result: {
                    const base = source.base;
                    const source_index = source.index;
                    source.builder.deinit();
                    const located = self.location.?;
                    var index = source_index;
                    self.data_pairs[index] = .{ .{ .symbol = self.names[6] }, item };
                    index += 1;
                    self.data_pairs[index] = .{ .{ .symbol = self.names[7] }, .{ .int = located.span.line } };
                    index += 1;
                    self.data_pairs[index] = .{ .{ .symbol = self.names[8] }, .{ .int = located.span.col } };
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
            .data_build => |*data| switch (try data.builder.advance(1)) {
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
            .outer => |*outer| switch (try outer.builder.advance(1)) {
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
    /// input-dependent state, not an execution phase.
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
    names: [8]u32 = .{0} ** 8,
    fields: [5]?Value = .{null} ** 5,
    message_bytes: [512]u8 = .{0} ** 512,
    data_fields: [3]?Value = .{null} ** 3,
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
            const kind = self.fields[0].?.symbol;
            const message = std.fmt.bufPrint(&self.message_bytes, "raised '{s}", .{intern.get(kind)}) catch
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
            data.pairs[index] = .{ .{ .symbol = self.names[5] }, self.built.source.? };
            index += 1;
        }
        if (data.additions.line) {
            const located = self.location.?;
            data.pairs[index] = .{ .{ .symbol = self.names[6] }, .{ .int = located.span.line } };
            index += 1;
        }
        if (data.additions.col) {
            const located = self.location.?;
            data.pairs[index] = .{ .{ .symbol = self.names[7] }, .{ .int = located.span.col } };
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
            outer.pairs[index] = .{ .{ .symbol = self.names[1] }, self.built.message.? };
            index += 1;
        }
        if (self.fields[2] == null) if (self.resolved.word) |word| {
            outer.pairs[index] = .{ .{ .symbol = self.names[2] }, .{ .symbol = word } };
            index += 1;
        };
        if (self.fields[3] == null) {
            outer.pairs[index] = .{ .{ .symbol = self.names[3] }, self.built.trace.? };
            index += 1;
        }
        if (self.fields[4] == null) {
            outer.pairs[index] = .{ .{ .symbol = self.names[4] }, self.built.data.? };
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
    pub fn advance(self: *RaisedErrorCursor) error{OutOfMemory}!ErrorValueProgress {
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
                        .{ .symbol = self.names[index] },
                    ),
                } };
                break :result .pending;
            },
            .field_find => |*find| switch (try find.cursor.advance(1)) {
                .pending => .pending,
                .complete => |found| result: {
                    const index = find.index;
                    find.cursor.deinit();
                    self.fields[index] = found;
                    self.state = .{ .fields = index + 1 };
                    break :result .pending;
                },
            },
            .message => |*builder| switch (try builder.advance(1)) {
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
                    trace.items[trace.index] = .{ .symbol = self.resolved.trace[trace.index] };
                    trace.index += 1;
                } else {
                    self.state = .{ .trace_build = .{
                        .items = trace.items,
                        .builder = .init(self.allocator, trace.items),
                    } };
                }
                break :result .pending;
            },
            .trace_build => |*trace| switch (try trace.builder.advance(1)) {
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
                        .{ .symbol = self.names[5 + index] },
                    ),
                } };
                break :result .pending;
            },
            .data_field_find => |*find| switch (try find.cursor.advance(1)) {
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
            .source => |*source| switch (try source.builder.advance(1)) {
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
            .data_build => |*data| switch (try data.builder.advance(1)) {
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
                        if (key == .symbol and key.symbol == self.names[4] and self.built.data != null)
                            self.built.data.?
                        else
                            old_value,
                    };
                    outer.index += 1;
                } else try self.appendOuter(outer);
                break :result .pending;
            },
            .outer_build => |*outer| switch (try outer.builder.advance(1)) {
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
    provenance: modules.RegistrationProvenance,

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
    /// Authority carried only while evaluating an embedded source module.
    /// A named module constructed by that source moves it into the immutable
    /// registration; ordinary source always carries ordinary provenance.
    registration_provenance: modules.RegistrationProvenance = .ordinary,

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
            .registration_provenance = if (unit.inherited.project_lock) |project_lock|
                if (project_lock.rootPackage()) |root_package|
                    .{ .root_package = root_package }
                else
                    .ordinary
            else
                .ordinary,
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
            .registration_provenance = home.registrationProvenance(),
        };
    }

    /// A nested activation continuing the same logical execution in `scope`:
    /// a dynamic `call`, an `@attempt` child, or a resumed qualified load.
    /// A quotation resolves where its invoker runs, so both scopes are the one
    /// it was handed.
    pub fn inheriting(invoker: Eval, scope: *env.Scope) ExecutionSite {
        var site = resumed(scope, invoker.home());
        site.registration_provenance = invoker.site.registration_provenance;
        return site;
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
const ArtifactLoad = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    fn init(maybe_artifact: ?pkg_catalog.ArtifactId) ArtifactLoad {
        return if (maybe_artifact) |id| @enumFromInt(@intFromEnum(id)) else .none;
    }
    fn artifact(self: ArtifactLoad) ?pkg_catalog.ArtifactId {
        return if (self == .none) null else @enumFromInt(@intFromEnum(self));
    }
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
        artifact: ArtifactLoad,
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
    direct: struct {
        body: *Header,
        word: u32,
        /// The trusted source word's defining chain: null for core, the
        /// standard module image for a shipped source word.
        scope: ?*env.Scope,
    },
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
    pub const storage_len = 96;
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

/// Opt-in root-Unit counters for release-mode runtime characterization.
/// Ordinary runtime and test modules compile every recording branch away; a
/// separate benchmark module enables them so counters cannot perturb timing.
pub const RootExecutionMetrics = struct {
    logical_transitions: u64 = 0,
    driver_resumes: u64 = 0,
    application_resumes: u64 = 0,
    scheduler_handoffs: u64 = 0,
    qualified_cache_hits: u64 = 0,
    qualified_cache_misses: u64 = 0,
    qualified_cache_heals: u64 = 0,
    local_cache_hits: u64 = 0,
    local_cache_misses: u64 = 0,
};

pub const root_execution_metrics_enabled = session_options.instrument_root_execution;

pub const Unit = struct {
    const TerminalState = union(enum) {
        evaluating,
        pending: EclErr,
        unwinding,
        failed: Value,
        incomplete: reader.Incomplete,
        exit: u8,

        fn deinit(self: *TerminalState, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .pending => |*failure| failure.retire(releases),
                .failed => |item| releases.releaseValue(item),
                .evaluating, .unwinding, .incomplete, .exit => {},
            }
            self.* = .evaluating;
        }
    };

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
    root_execution_metrics: if (root_execution_metrics_enabled) RootExecutionMetrics else void = if (root_execution_metrics_enabled) .{} else {},
    module_call_sites: ModuleCallSiteCache = .{},
    max_frames: usize = 0,
    entry_base: usize,
    stack_base: usize,
    boundary_index: ?FrameIndex = null,
    /// The innermost active source effect check. Effect-check frames form an
    /// intrusive chain so nested checks restore their predecessor exactly.
    effect_check_index: ?EffectCheckIndex = null,
    terminal: TerminalState = .evaluating,
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
        return switch (self.terminal) {
            .failed => |item| result: {
                self.terminal = .evaluating;
                break :result item;
            },
            else => null,
        };
    }
    pub fn takeSourceIncomplete(self: *Unit) ?reader.Incomplete {
        return switch (self.terminal) {
            .incomplete => |value_incomplete| result: {
                self.terminal = .evaluating;
                break :result value_incomplete;
            },
            else => null,
        };
    }
    pub fn exitStatus(self: *const Unit) ?u8 {
        return switch (self.terminal) {
            .exit => |status| status,
            else => null,
        };
    }
    pub fn hasRequestedExit(self: *const Unit) bool {
        return self.terminal == .exit;
    }
    fn pendingFailureOptional(self: *Unit) ?*EclErr {
        return switch (self.terminal) {
            .pending => |*failure| failure,
            else => null,
        };
    }
    fn pendingFailure(self: *Unit) *EclErr {
        return self.pendingFailureOptional() orelse unreachable;
    }
    fn hasPendingFailure(self: *const Unit) bool {
        return self.terminal == .pending;
    }
    fn installPendingFailure(self: *Unit, failure: EclErr) void {
        std.debug.assert(self.terminal == .evaluating);
        self.terminal = .{ .pending = failure };
    }
    fn takePendingForUnwind(self: *Unit) EclErr {
        return switch (self.terminal) {
            .pending => |failure| result: {
                self.terminal = .unwinding;
                break :result failure;
            },
            else => unreachable,
        };
    }
    fn finishUnwindCaught(self: *Unit) void {
        std.debug.assert(self.terminal == .unwinding);
        self.terminal = .evaluating;
    }
    fn finishUnwindFailed(self: *Unit, error_value: Value) void {
        std.debug.assert(self.terminal == .unwinding);
        self.terminal = .{ .failed = error_value };
    }
    fn finishIncomplete(self: *Unit, value_incomplete: reader.Incomplete) void {
        std.debug.assert(self.terminal == .evaluating);
        self.terminal = .{ .incomplete = value_incomplete };
    }
    fn requestExit(self: *Unit, status: u8) void {
        std.debug.assert(self.terminal == .evaluating);
        self.terminal = .{ .exit = status };
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
            switch (self.terminal) {
                .pending, .failed => {
                    self.terminal.deinit(self.releases);
                    consumed += 1;
                    continue;
                },
                .evaluating, .unwinding, .incomplete, .exit => {},
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
        self.module_call_sites.deinit(self.releases);
        if (self.current) |current| self.releases.releaseHeader(current.code);
        while (self.frames.pop()) |frame| self.deinitPoppedFrame(frame);
        self.frames.deinit(self.allocator);
        for (self.stack.items) |item| self.releases.releaseValue(item);
        self.stack.deinit(self.allocator);
        self.terminal.deinit(self.releases);
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
    pub fn validatePackageTree(
        self: *const Machine,
        io: std.Io,
        package_name: []const u8,
        root_dir: []const u8,
        diagnostic: *?[]u8,
    ) pkg_catalog.BuildError!void {
        return self.unit.inherited.registry.?.validatePackageTree(
            io,
            package_name,
            root_dir,
            diagnostic,
        );
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
    /// The source name attached to the occurrence being dispatched. The
    /// archive owns the returned bytes for at least as long as the current
    /// code header, which the activation retains across any driver this call
    /// starts. Runtime-built code has no entry and returns null.
    pub fn activeSourceName(self: *const Machine) ?[]const u8 {
        const current = self.unit.current orelse return null;
        const located = self.unit.archive.locate(current.code, self.unit.active_index) orelse
            return null;
        return located.source_name;
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
        switch (outcome) {
            .unknown_module_prefix => |prefix| {
                try self.startDriver(QualifiedLoadPreparationDriver.init(
                    prefix,
                    .{ .qualified = requested, .continuation = .replay },
                    .{ .operand = requested },
                ));
                return .detached;
            },
            .unregistered_module => |name| {
                try self.pushBorrowed(.{ .symbol = requested });
                self.unit.current.?.ip = self.unit.active_index;
                try self.autoLoadModule(name, .{
                    .qualified = requested,
                    .continuation = .replay,
                });
                return .detached;
            },
            .unresolved => |chain| return self.undefinedNameIn(requested, chain),
            .resolved => unreachable,
        }
    }
    /// A batch import consumes its module symbol and requested-name list before
    /// discovering a cold module. Restore both operands, rewind the primitive,
    /// and share the ordinary qualified-name auto-load/retry path.
    pub fn retryImportAfterLoad(
        self: *Machine,
        module_id: u32,
        requested: Value,
        module_name: intern.ModuleName,
        requested_word: u32,
    ) MachineError!WorkProgress {
        if (self.unit.current == null or self.unit.inherited.registry == null) {
            self.releaseDomain().releaseValue(requested);
            return self.undefinedNameIn(requested_word, .qualified);
        }
        try self.restoreImportOperands(module_id, requested);
        self.unit.current.?.ip = self.unit.active_index;
        try self.autoLoadModule(module_name, .{
            .qualified = requested_word,
            .continuation = .replay,
        });
        return .detached;
    }
    /// Consumes the requested-name list on both success and allocation
    /// failure. Keeping the exact stack commit outside the driver-returning
    /// retry function preserves the WorkProgress output boundary audited for
    /// every driver.
    fn restoreImportOperands(self: *Machine, module_id: u32, requested: Value) error{OutOfMemory}!void {
        var owned = heap.Owned(Value).init(requested);
        defer owned.deinit(self.releaseDomain(), self.allocator());
        var reservation = try self.reserveStack(2);
        reservation.pushBorrowed(.{ .symbol = module_id });
        reservation.pushOwned(owned.take());
        std.debug.assert(reservation.complete());
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
            .state = .init(.{ .begin = registry.beginLoadingCursor(name, .of(self.unit)) }),
        });
    }
    fn currentPackage(self: *const Machine) ?pkg_catalog.PackageId {
        const current = self.unit.current orelse return null;
        return switch (current.site.registration_provenance) {
            .root_package, .package => |package| package,
            .ordinary, .standard_library => null,
        };
    }
    const AutoLoadDriver = struct {
        const FileKind = enum { source, native };
        const CandidateOrigin = union(enum) {
            legacy: struct {
                component_start: usize,
                component_end: usize,
                next_search: usize,
            },
            locked: struct {
                package: []const u8,
                store: []const u8,
                package_id: pkg_catalog.PackageId,
                artifact_id: pkg_catalog.ArtifactId,
            },
        };
        const FilenameTarget = union(enum) {
            component_start: usize,
            candidate: CandidateOrigin,
        };
        const FilenameState = struct {
            loading: heap.Owned(modules.LoadingLease),
            filename: heap.Owned([]u8),
            index: usize = 0,
            kind: FileKind,
            target: FilenameTarget,
        };
        const CandidateState = struct {
            loading: heap.Owned(modules.LoadingLease),
            filename: heap.Owned([]u8),
            kind: FileKind,
            origin: CandidateOrigin,
            candidate: heap.Owned([]u8),
            index: usize = 0,
            separator: bool,
        };
        const Disposition = union(enum) {
            source: struct {
                provenance: modules.RegistrationProvenance,
                artifact: ?pkg_catalog.ArtifactId,
            },
            native,
            embedded: stdlib.Entry,
            fail: []const u8,
        };
        const LockedTarget = struct {
            package: []const u8,
            store: []const u8,
            relative_path: []const u8,
            package_id: pkg_catalog.PackageId,
            artifact_id: pkg_catalog.ArtifactId,
        };
        const State = union(enum) {
            begin: modules.Registry.BeginLoadingCursor,
            registered: struct {
                loading: heap.Owned(modules.LoadingLease),
                cursor: heap.Owned(modules.Registry.AcquireCursor),
            },
            lock_lookup: struct {
                loading: heap.Owned(modules.LoadingLease),
                cursor: heap.Owned(pkg_lock.LookupCursor),
            },
            artifact_begin: struct {
                target: LockedTarget,
                cursor: modules.Registry.BeginLoadingCursor,
            },
            artifact_registered: struct {
                target: LockedTarget,
                loading: heap.Owned(modules.LoadingLease),
                cursor: heap.Owned(modules.Registry.AcquireCursor),
            },
            committed: heap.Owned(modules.Registry.AcquireCursor),
            locked_store: struct {
                loading: heap.Owned(modules.LoadingLease),
                target: LockedTarget,
            },
            filename: FilenameState,
            component_start: struct {
                loading: heap.Owned(modules.LoadingLease),
                filename: heap.Owned([]u8),
                kind: FileKind,
                search_index: usize,
            },
            component_end: struct {
                loading: heap.Owned(modules.LoadingLease),
                filename: heap.Owned([]u8),
                kind: FileKind,
                search_index: usize,
                component_start: usize,
            },
            candidate: CandidateState,
            access: CandidateState,
            path_value: struct {
                loading: heap.Owned(modules.LoadingLease),
                candidate: heap.Owned([]u8),
                materializer: heap.Owned(kernel_storage.Utf8Materializer),
                disposition: Disposition,
            },
            transfer: struct {
                loading: heap.Owned(modules.LoadingLease),
                candidate: heap.Owned([]u8),
                path: heap.Owned(Value),
                disposition: Disposition,
            },

            pub fn deinit(
                self: *State,
                releases: *heap.ReleaseDomain,
                storage_allocator: std.mem.Allocator,
            ) void {
                switch (self.*) {
                    .begin => |*cursor| cursor.deinit(),
                    .registered => |*registered| {
                        registered.cursor.deinit(releases, storage_allocator);
                        registered.loading.deinit(releases, storage_allocator);
                    },
                    .lock_lookup => |*lookup| {
                        lookup.cursor.deinit(releases, storage_allocator);
                        lookup.loading.deinit(releases, storage_allocator);
                    },
                    .artifact_begin => |*begin| begin.cursor.deinit(),
                    .artifact_registered => |*registered| {
                        registered.cursor.deinit(releases, storage_allocator);
                        registered.loading.deinit(releases, storage_allocator);
                    },
                    .committed => |*cursor| cursor.deinit(releases, storage_allocator),
                    .locked_store => |*locked| locked.loading.deinit(releases, storage_allocator),
                    .filename => |*filename| {
                        filename.filename.deinit(releases, storage_allocator);
                        filename.loading.deinit(releases, storage_allocator);
                    },
                    .component_start => |*component| {
                        component.filename.deinit(releases, storage_allocator);
                        component.loading.deinit(releases, storage_allocator);
                    },
                    .component_end => |*component| {
                        component.filename.deinit(releases, storage_allocator);
                        component.loading.deinit(releases, storage_allocator);
                    },
                    .candidate, .access => |*candidate| {
                        candidate.candidate.deinit(releases, storage_allocator);
                        candidate.filename.deinit(releases, storage_allocator);
                        candidate.loading.deinit(releases, storage_allocator);
                    },
                    .path_value => |*path| {
                        path.materializer.deinit(releases, storage_allocator);
                        path.candidate.deinit(releases, storage_allocator);
                        path.loading.deinit(releases, storage_allocator);
                    },
                    .transfer => |*transfer| {
                        transfer.path.deinit(releases, storage_allocator);
                        transfer.candidate.deinit(releases, storage_allocator);
                        transfer.loading.deinit(releases, storage_allocator);
                    },
                }
                self.* = undefined;
            }
        };

        name: intern.ModuleName,
        request: QualifiedLoadRequest,
        state: heap.Owned(State),

        fn makeFilename(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            loading: *heap.Owned(modules.LoadingLease),
            kind: FileKind,
            target: FilenameTarget,
        ) error{OutOfMemory}!FilenameState {
            const module_name = intern.get(intern.moduleId(self.name));
            const extension = switch (kind) {
                .source => ".ecl",
                .native => ".eclmod",
            };
            const length = std.math.add(usize, module_name.len, extension.len) catch
                return error.OutOfMemory;
            const filename = try evaluator.unit.allocator.alloc(u8, length);
            return .{
                .loading = .init(loading.take()),
                .filename = .init(filename),
                .kind = kind,
                .target = target,
            };
        }
        fn makeCandidate(
            evaluator: *Machine,
            loading: *heap.Owned(modules.LoadingLease),
            filename: *heap.Owned([]u8),
            kind: FileKind,
            origin: CandidateOrigin,
        ) error{OutOfMemory}!CandidateState {
            const directory = switch (origin) {
                .locked => |locked| locked.store,
                .legacy => |legacy| legacy_directory: {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    break :legacy_directory search[legacy.component_start..legacy.component_end];
                },
            };
            const separator = directory.len != 0 and !std.fs.path.isSep(directory[directory.len - 1]);
            var length = std.math.add(usize, directory.len, filename.borrow().len) catch
                return error.OutOfMemory;
            if (separator) length = std.math.add(usize, length, 1) catch
                return error.OutOfMemory;
            const candidate = try evaluator.unit.allocator.alloc(u8, length);
            return .{
                .loading = .init(loading.take()),
                .filename = .init(filename.take()),
                .kind = kind,
                .origin = origin,
                .candidate = .init(candidate),
                .separator = separator,
            };
        }
        /// Embedded modules reuse the candidate slot for their provenance
        /// name, so the existing `.path_value` phase materializes exactly the
        /// value the load continuation reports as `'path`.
        fn beginEmbedded(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            loading: *heap.Owned(modules.LoadingLease),
            entry: stdlib.Entry,
        ) error{OutOfMemory}!void {
            const provenance = switch (entry) {
                .source => |source| source.name,
                .native, .builtin => intern.get(intern.moduleId(self.name)),
            };
            var candidate = heap.Owned([]u8).init(try evaluator.unit.allocator.dupe(u8, provenance));
            const materializer = kernel_storage.Utf8Materializer.init(
                evaluator.unit.allocator,
                candidate.borrow(),
            );
            self.state.borrowMut().* = .{ .path_value = .{
                .loading = .init(loading.take()),
                .candidate = .init(candidate.take()),
                .materializer = .init(materializer),
                .disposition = .{ .embedded = entry },
            } };
        }
        /// The module is already registered, so this driver publishes nothing.
        fn finishWithoutLoading(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            loading: *heap.Owned(modules.LoadingLease),
        ) MachineError!WorkProgress {
            loading.borrowMut().finish();
            return continueQualifiedRequest(evaluator, self, self.request);
        }
        fn notFound(self: *AutoLoadDriver, evaluator: *Machine) MachineError {
            return evaluator.undefinedWordIn(self.request.qualified, .qualified);
        }
        fn sourceCompletion(
            self: *AutoLoadDriver,
            transfer: *@FieldType(State, "transfer"),
            provenance: modules.RegistrationProvenance,
            artifact: ?pkg_catalog.ArtifactId,
        ) SourceCompletion {
            return .{ .register = .{
                .loading = transfer.loading.borrowMut().move(),
                .name = self.name,
                .path = transfer.path.take(),
                .request = self.request,
                .provenance = provenance,
                .artifact = artifact,
            } };
        }
        pub fn advance(evaluator: *Machine, self: *AutoLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            var budget: usize = kernel_poll_quantum;
            work: while (budget != 0) : (budget -= 1) switch (self.state.borrowMut().*) {
                .begin => |*cursor| switch (try cursor.advance()) {
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
                            cursor.deinit();
                            self.state.borrowMut().* = .{ .begin = evaluator.unit.inherited.registry.?.beginLoadingCursor(
                                self.name,
                                .of(evaluator.unit),
                            ) };
                            return .yielded;
                        },
                        .granted => |lease| {
                            cursor.deinit();
                            if (evaluator.unit.inherited.project_lock != null and
                                stdlib.find(intern.get(intern.moduleId(self.name))) == null)
                            {
                                self.state.borrowMut().* = .{ .lock_lookup = .{
                                    .loading = .init(lease),
                                    .cursor = .init(evaluator.unit.inherited.project_lock.?.lookupCursor(
                                        evaluator.currentPackage(),
                                        intern.get(intern.moduleId(self.name)),
                                    )),
                                } };
                            } else {
                                self.state.borrowMut().* = .{ .registered = .{
                                    .loading = .init(lease),
                                    .cursor = .init(evaluator.unit.inherited.registry.?.acquireCursor(self.name)),
                                } };
                            }
                        },
                    },
                },
                // A load that raced a winner has nothing left to publish: its
                // tagged operation resumes against the winner's module.
                .registered => |*registered| switch (registered.cursor.borrowMut().advance()) {
                    .pending => {},
                    .complete => |maybe_generation| {
                        var loading = heap.Owned(modules.LoadingLease).init(registered.loading.take());
                        defer loading.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        registered.cursor.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        if (maybe_generation) |generation| {
                            var lease = generation;
                            lease.deinit();
                            return self.finishWithoutLoading(evaluator, &loading);
                        }
                        // The embedded manifest is consulted before the
                        // search path: a stdlib name resolves with no host IO
                        // and no ECL_PATH, and no path module can shadow one.
                        if (stdlib.find(intern.get(intern.moduleId(self.name)))) |entry| {
                            try self.beginEmbedded(evaluator, &loading, entry);
                            continue;
                        }
                        if (evaluator.unit.inherited.project_lock) |project_lock| {
                            self.state.borrowMut().* = .{ .lock_lookup = .{
                                .loading = .init(loading.take()),
                                .cursor = .init(project_lock.lookupCursor(
                                    evaluator.currentPackage(),
                                    intern.get(intern.moduleId(self.name)),
                                )),
                            } };
                            continue;
                        }
                        if (evaluator.unit.inherited.host_io == null or evaluator.unit.inherited.ecl_path == null)
                            return self.notFound(evaluator);
                        const filename = try self.makeFilename(
                            evaluator,
                            &loading,
                            .source,
                            .{ .component_start = 0 },
                        );
                        self.state.borrowMut().* = .{ .filename = filename };
                    },
                },
                .lock_lookup => |*lookup| switch (lookup.cursor.borrowMut().advance()) {
                    .pending => {},
                    .complete => |outcome| {
                        var loading = heap.Owned(modules.LoadingLease).init(lookup.loading.take());
                        defer loading.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        lookup.cursor.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        switch (outcome) {
                            .invalid => |message| return evaluator.fail(.io, message),
                            .unmatched => {
                                return evaluator.failFmt(
                                    .undefined_word,
                                    "module `{s}` is not exported by the active project",
                                    .{intern.get(intern.moduleId(self.name))},
                                );
                            },
                            .hidden => |hidden| {
                                return evaluator.failFmt(
                                    .undefined_word,
                                    "module `{s}` is exported by package `{s}`, but `{s}` does not require it",
                                    .{
                                        intern.get(intern.moduleId(self.name)),
                                        hidden.owner,
                                        hidden.consumer,
                                    },
                                );
                            },
                            .matched => |match| {
                                loading.borrowMut().finish();
                                const target: LockedTarget = .{
                                    .package = match.package,
                                    .store = match.store_dir,
                                    .relative_path = match.relative_path,
                                    .package_id = match.package_id,
                                    .artifact_id = match.artifact_id,
                                };
                                if (evaluator.unit.inherited.project_lock.?.artifactCommitted(match.artifact_id)) {
                                    self.state.borrowMut().* = .{ .committed = .init(
                                        evaluator.unit.inherited.registry.?.acquireCursor(self.name),
                                    ) };
                                } else {
                                    self.state.borrowMut().* = .{ .artifact_begin = .{
                                        .target = target,
                                        .cursor = evaluator.unit.inherited.registry.?.beginArtifactLoadingCursor(
                                            match.artifact_id,
                                            .of(evaluator.unit),
                                        ),
                                    } };
                                }
                            },
                        }
                    },
                },
                .artifact_begin => |*begin| switch (try begin.cursor.advance()) {
                    .pending => {},
                    .complete => |outcome| switch (outcome) {
                        .cycle => return evaluator.failFmt(
                            .domain,
                            "recursive auto-load of package artifact `{s}`",
                            .{begin.target.relative_path},
                        ),
                        .contended => {
                            const target = begin.target;
                            begin.cursor.deinit();
                            self.state.borrowMut().* = .{ .artifact_begin = .{
                                .target = target,
                                .cursor = evaluator.unit.inherited.registry.?.beginArtifactLoadingCursor(
                                    target.artifact_id,
                                    .of(evaluator.unit),
                                ),
                            } };
                            return .yielded;
                        },
                        .granted => |lease| {
                            const target = begin.target;
                            begin.cursor.deinit();
                            self.state.borrowMut().* = .{ .artifact_registered = .{
                                .target = target,
                                .loading = .init(lease),
                                .cursor = .init(evaluator.unit.inherited.registry.?.acquireCursor(self.name)),
                            } };
                        },
                    },
                },
                .artifact_registered => |*registered| switch (registered.cursor.borrowMut().advance()) {
                    .pending => {},
                    .complete => |maybe_generation| {
                        var loading = heap.Owned(modules.LoadingLease).init(registered.loading.take());
                        defer loading.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        registered.cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        if (evaluator.unit.inherited.project_lock.?.artifactCommitted(
                            registered.target.artifact_id,
                        )) {
                            if (maybe_generation) |generation| {
                                var lease = generation;
                                lease.deinit();
                                return self.finishWithoutLoading(evaluator, &loading);
                            }
                            return evaluator.failFmt(
                                .io,
                                "committed package artifact `{s}` is missing module `{s}`",
                                .{ registered.target.relative_path, intern.get(intern.moduleId(self.name)) },
                            );
                        }
                        if (maybe_generation) |generation| {
                            var partial = generation;
                            partial.deinit();
                        }
                        const target = registered.target;
                        self.state.borrowMut().* = .{ .locked_store = .{
                            .loading = .init(loading.take()),
                            .target = target,
                        } };
                    },
                },
                .committed => |*cursor| switch (cursor.borrowMut().advance()) {
                    .pending => {},
                    .complete => |maybe_generation| {
                        cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        const generation = maybe_generation orelse return evaluator.failFmt(
                            .io,
                            "a committed package artifact is missing module `{s}`",
                            .{intern.get(intern.moduleId(self.name))},
                        );
                        var lease = generation;
                        lease.deinit();
                        return continueQualifiedRequest(evaluator, self, self.request);
                    },
                },
                .locked_store => |*locked| {
                    const info = std.Io.Dir.cwd().statFile(
                        evaluator.unit.inherited.host_io.?,
                        locked.target.store,
                        .{ .follow_symlinks = false },
                    ) catch |err| switch (err) {
                        error.FileNotFound => return evaluator.failFmt(
                            .io,
                            "locked package `{s}` is missing from the package store; run `ecl pkg sync`",
                            .{locked.target.package},
                        ),
                        else => return evaluator.failFmt(
                            .io,
                            "cannot inspect locked package `{s}` in the package store: {s}; run `ecl pkg sync`",
                            .{ locked.target.package, @errorName(err) },
                        ),
                    };
                    if (info.kind != .directory) return evaluator.failFmt(
                        .io,
                        "locked package `{s}` is not a real package-store directory; run `ecl pkg sync`",
                        .{locked.target.package},
                    );
                    var loading = heap.Owned(modules.LoadingLease).init(locked.loading.take());
                    defer loading.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    const origin: CandidateOrigin = .{ .locked = .{
                        .package = locked.target.package,
                        .store = locked.target.store,
                        .package_id = locked.target.package_id,
                        .artifact_id = locked.target.artifact_id,
                    } };
                    const filename_bytes = try evaluator.unit.allocator.dupe(u8, locked.target.relative_path);
                    const filename = FilenameState{
                        .loading = .init(loading.take()),
                        .filename = .init(filename_bytes),
                        .index = filename_bytes.len,
                        .kind = .source,
                        .target = .{ .candidate = origin },
                    };
                    self.state.borrowMut().* = .{ .filename = filename };
                },
                .filename => |*filename| {
                    const module_name = intern.get(intern.moduleId(self.name));
                    const extension = switch (filename.kind) {
                        .source => ".ecl",
                        .native => ".eclmod",
                    };
                    if (filename.index != filename.filename.borrow().len) {
                        filename.filename.borrow()[filename.index] = if (filename.index < module_name.len)
                            module_name[filename.index]
                        else
                            extension[filename.index - module_name.len];
                        filename.index += 1;
                    } else switch (filename.target) {
                        .component_start => |search_index| {
                            const next = @FieldType(State, "component_start"){
                                .loading = .init(filename.loading.take()),
                                .filename = .init(filename.filename.take()),
                                .kind = filename.kind,
                                .search_index = search_index,
                            };
                            self.state.borrowMut().* = .{ .component_start = next };
                        },
                        .candidate => |origin| {
                            const candidate = try makeCandidate(
                                evaluator,
                                &filename.loading,
                                &filename.filename,
                                filename.kind,
                                origin,
                            );
                            self.state.borrowMut().* = .{ .candidate = candidate };
                        },
                    }
                },
                .component_start => |*component| {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    if (component.search_index == search.len) return self.notFound(evaluator);
                    if (search[component.search_index] == std.fs.path.delimiter) {
                        component.search_index += 1;
                    } else {
                        const next = @FieldType(State, "component_end"){
                            .loading = .init(component.loading.take()),
                            .filename = .init(component.filename.take()),
                            .kind = component.kind,
                            .search_index = component.search_index,
                            .component_start = component.search_index,
                        };
                        self.state.borrowMut().* = .{ .component_end = next };
                    }
                },
                .component_end => |*component| {
                    const search = evaluator.unit.inherited.ecl_path.?;
                    if (component.search_index == search.len or
                        search[component.search_index] == std.fs.path.delimiter)
                    {
                        const component_end = component.search_index;
                        var next_search = component.search_index;
                        if (next_search != search.len) next_search += 1;
                        const origin: CandidateOrigin = .{ .legacy = .{
                            .component_start = component.component_start,
                            .component_end = component_end,
                            .next_search = next_search,
                        } };
                        const candidate = try makeCandidate(
                            evaluator,
                            &component.loading,
                            &component.filename,
                            component.kind,
                            origin,
                        );
                        self.state.borrowMut().* = .{ .candidate = candidate };
                    } else component.search_index += 1;
                },
                .candidate => |*candidate| {
                    const directory = switch (candidate.origin) {
                        .locked => |locked| locked.store,
                        .legacy => |legacy| legacy_directory: {
                            const search = evaluator.unit.inherited.ecl_path.?;
                            break :legacy_directory search[legacy.component_start..legacy.component_end];
                        },
                    };
                    if (candidate.index != candidate.candidate.borrow().len) {
                        candidate.candidate.borrow()[candidate.index] = if (candidate.index < directory.len)
                            directory[candidate.index]
                        else if (candidate.separator and candidate.index == directory.len)
                            std.fs.path.sep
                        else
                            candidate.filename.borrow()[candidate.index - directory.len - @intFromBool(candidate.separator)];
                        candidate.index += 1;
                    } else {
                        const next = CandidateState{
                            .loading = .init(candidate.loading.take()),
                            .filename = .init(candidate.filename.take()),
                            .kind = candidate.kind,
                            .origin = candidate.origin,
                            .candidate = .init(candidate.candidate.take()),
                            .index = candidate.index,
                            .separator = candidate.separator,
                        };
                        self.state.borrowMut().* = .{ .access = next };
                    }
                },
                .access => |*access| {
                    var disposition: Disposition = switch (access.kind) {
                        .source => .{ .source = switch (access.origin) {
                            .legacy => .{ .provenance = .ordinary, .artifact = null },
                            .locked => |locked| .{
                                .provenance = .{ .package = locked.package_id },
                                .artifact = locked.artifact_id,
                            },
                        } },
                        .native => .native,
                    };
                    std.Io.Dir.cwd().access(
                        evaluator.unit.inherited.host_io.?,
                        access.candidate.borrow(),
                        .{ .read = true },
                    ) catch |err| switch (err) {
                        error.FileNotFound => {
                            const origin = access.origin;
                            switch (origin) {
                                .locked => |locked| return evaluator.failFmt(
                                    .undefined_word,
                                    "locked module `{s}` is absent from package `{s}`",
                                    .{
                                        intern.get(intern.moduleId(self.name)),
                                        locked.package,
                                    },
                                ),
                                .legacy => |legacy| {
                                    const kind: FileKind = if (access.kind == .source) .native else .source;
                                    const target: FilenameTarget = if (access.kind == .source)
                                        .{ .candidate = origin }
                                    else
                                        .{ .component_start = legacy.next_search };
                                    const filename = try self.makeFilename(
                                        evaluator,
                                        &access.loading,
                                        kind,
                                        target,
                                    );
                                    access.candidate.deinit(evaluator.releaseDomain(), evaluator.allocator());
                                    access.filename.deinit(evaluator.releaseDomain(), evaluator.allocator());
                                    self.state.borrowMut().* = .{ .filename = filename };
                                    continue :work;
                                },
                            }
                        },
                        else => disposition = .{ .fail = @errorName(err) },
                    };
                    const materializer = kernel_storage.Utf8Materializer.init(
                        evaluator.unit.allocator,
                        access.candidate.borrow(),
                    );
                    access.filename.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    const next = @FieldType(State, "path_value"){
                        .loading = .init(access.loading.take()),
                        .candidate = .init(access.candidate.take()),
                        .materializer = .init(materializer),
                        .disposition = disposition,
                    };
                    self.state.borrowMut().* = .{ .path_value = next };
                },
                .path_value => |*path| switch (path.materializer.borrowMut().advance(1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return evaluator.fail(.io, "module path is not valid UTF-8"),
                }) {
                    .pending => {},
                    .complete => |path_value| {
                        path.materializer.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        const next = @FieldType(State, "transfer"){
                            .loading = .init(path.loading.take()),
                            .candidate = .init(path.candidate.take()),
                            .path = .init(path_value),
                            .disposition = path.disposition,
                        };
                        self.state.borrowMut().* = .{ .transfer = next };
                    },
                },
                .transfer => |*transfer| switch (transfer.disposition) {
                    .fail => |name| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot access module file `{s}`: {s}",
                            .{ transfer.candidate.borrow(), name },
                        );
                        evaluator.unit.pendingFailure().addData(.path, transfer.path.borrow());
                        return failure;
                    },
                    .embedded => |entry| return self.transferEmbedded(evaluator, transfer, entry),
                    .native => return self.transferNative(evaluator, transfer),
                    .source => |source| {
                        const candidate = transfer.candidate.take();
                        const completion = self.sourceCompletion(
                            transfer,
                            source.provenance,
                            source.artifact,
                        );
                        evaluator.retireDriver(self);
                        try evaluator.fileSourceOwned(candidate, null, completion);
                        return .detached;
                    },
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
            transfer: *@FieldType(State, "transfer"),
            entry: stdlib.Entry,
        ) MachineError!WorkProgress {
            const text = switch (entry) {
                .source => |source| try evaluator.unit.allocator.dupe(u8, source.text),
                .native => |descriptor| return self.transferStatic(evaluator, transfer, descriptor),
                .builtin => |words| return self.transferBuiltin(evaluator, transfer, words),
            };
            const source_name = transfer.candidate.take();
            const completion = self.sourceCompletion(transfer, .standard_library, null);
            evaluator.retireDriver(self);
            try evaluator.sourceOwned(source_name, text, completion);
            return .detached;
        }
        fn transferBuiltin(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            transfer: *@FieldType(State, "transfer"),
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
                .loading = .init(transfer.loading.take()),
                .path = .init(transfer.path.take()),
                .publication = .init(publication),
            };
            evaluator.retireDriver(self);
            try evaluator.startDriver(next);
            return .detached;
        }
        fn transferStatic(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            transfer: *@FieldType(State, "transfer"),
            descriptor: *const native_abi.Descriptor,
        ) MachineError!WorkProgress {
            const loader_authority = evaluator.unit.inherited.native_loader orelse
                return evaluator.fail(.io, "native module loader is unavailable");
            const loader = switch (loader_authority.startStatic(self.name, descriptor)) {
                .failure => |failure| {
                    const failed = evaluator.fail(.io, failure.text());
                    evaluator.unit.pendingFailure().addData(.path, transfer.path.borrow());
                    return failed;
                },
                .loading => |loading| loading,
            };
            const next = NativeLoadDriver{
                .name = self.name,
                .request = self.request,
                .provenance = .standard_library,
                .loading = .init(transfer.loading.take()),
                .path = .init(transfer.path.take()),
                .state = .init(.{ .validate = .init(loader) }),
            };
            evaluator.retireDriver(self);
            try evaluator.startDriver(next);
            return .detached;
        }
        fn transferNative(
            self: *AutoLoadDriver,
            evaluator: *Machine,
            transfer: *@FieldType(State, "transfer"),
        ) MachineError!WorkProgress {
            const loader_authority = evaluator.unit.inherited.native_loader orelse
                return evaluator.fail(.io, "native module loader is unavailable");
            const start = try loader_authority.startDynamic(
                self.name,
                transfer.candidate.borrow(),
            );
            const loader = switch (start) {
                .failure => |failure| {
                    const failed = evaluator.fail(.io, failure.text());
                    evaluator.unit.pendingFailure().addData(.path, transfer.path.borrow());
                    return failed;
                },
                .loading => |loading| loading,
            };
            const next = NativeLoadDriver{
                .name = self.name,
                .request = self.request,
                .provenance = .ordinary,
                .loading = .init(transfer.loading.take()),
                .path = .init(transfer.path.take()),
                .state = .init(.{ .validate = .init(loader) }),
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
                    .standard_library,
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
        provenance: modules.RegistrationProvenance,
        loading: heap.Owned(modules.LoadingLease),
        path: heap.Owned(Value),
        state: heap.Owned(State),

        const State = union(enum) {
            validate: heap.Owned(native_module.LoadCursor),
            loaded: heap.Owned(*native_module.ModuleInstance),
            definitions: struct {
                instance: heap.Owned(*native_module.ModuleInstance),
                publication: heap.Owned(modules.Registry.NativeCandidateCursor),
            },
            commit: struct {
                instance: heap.Owned(*native_module.ModuleInstance),
                candidate: heap.Owned(modules.SealedImage),
                cursor: heap.Owned(modules.Registry.RegistrationCursor),
            },
            published: struct {
                instance: heap.Owned(*native_module.ModuleInstance),
                candidate: heap.Owned(modules.SealedImage),
            },

            pub fn deinit(
                self: *State,
                releases: *heap.ReleaseDomain,
                storage_allocator: std.mem.Allocator,
            ) void {
                switch (self.*) {
                    .validate => |*loader| loader.deinit(releases, storage_allocator),
                    .loaded => |*instance| instance.deinit(releases, storage_allocator),
                    .definitions => |*definitions| {
                        definitions.publication.deinit(releases, storage_allocator);
                        definitions.instance.deinit(releases, storage_allocator);
                    },
                    .commit => |*commit| {
                        commit.cursor.deinit(releases, storage_allocator);
                        commit.candidate.deinit(releases, storage_allocator);
                        commit.instance.deinit(releases, storage_allocator);
                    },
                    .published => |*published| {
                        published.candidate.deinit(releases, storage_allocator);
                        published.instance.deinit(releases, storage_allocator);
                    },
                }
                self.* = undefined;
            }
        };

        fn failLoad(self: *NativeLoadDriver, evaluator: *Machine, message: []const u8) MachineError {
            const failure = evaluator.fail(.io, message);
            evaluator.unit.pendingFailure().addData(.path, self.path.borrow());
            return failure;
        }

        pub fn advance(evaluator: *Machine, self: *NativeLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            switch (self.state.borrowMut().*) {
                .validate => |*loader| switch (try loader.borrowMut().advance(kernel_poll_quantum)) {
                    .pending => return .yielded,
                    .failure => |failure| return self.failLoad(evaluator, failure.text()),
                    .loaded => |instance| {
                        loader.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.state.borrowMut().* = .{ .loaded = .init(instance) };
                        return .yielded;
                    },
                },
                .loaded => |*instance| {
                    const publication = try modules.Registry.NativeCandidateCursor.init(
                        evaluator.unit.inherited.registry.?,
                        instance.borrow(),
                    );
                    self.state.borrowMut().* = .{ .definitions = .{
                        .instance = .init(instance.take()),
                        .publication = .init(publication),
                    } };
                    return .yielded;
                },
                .definitions => |*definitions| switch (try definitions.publication.borrowMut().advance()) {
                    .pending => return .yielded,
                    .complete => |candidate| {
                        const instance = definitions.instance.take();
                        definitions.publication.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        var built = candidate;
                        var sealed = heap.Owned(modules.SealedImage).init(built.seal());
                        const cursor = evaluator.unit.inherited.registry.?.registrationCursor(
                            sealed.borrow().ref(),
                            self.name,
                            self.provenance,
                            &evaluator.unit.turn_authority,
                        );
                        self.state.borrowMut().* = .{ .commit = .{
                            .instance = .init(instance),
                            .candidate = .init(sealed.take()),
                            .cursor = .init(cursor),
                        } };
                        return .yielded;
                    },
                },
                .commit => |*commit| switch (commit.cursor.borrowMut().advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return evaluator.failFmt(
                        .io,
                        "cannot publish native module `{s}`: {s}",
                        .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
                    ),
                }) {
                    .pending => return .yielded,
                    .complete => {
                        const next: State = .{ .published = .{
                            .instance = commit.instance,
                            .candidate = commit.candidate,
                        } };
                        var cursor = commit.cursor;
                        self.state.borrowMut().* = next;
                        cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
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
                .published => unreachable,
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
            .text = .init(.{ .owned = .{ .source_name = source_name, .source = source } }),
            .completion = .init(.push),
        });
    }
    const SourceCompletion = union(enum) {
        push,
        call,
        session,
        /// Registration only: the source runs, then the loading lease and
        /// tagged qualified operation transfer to the return frame.
        register: struct {
            loading: ?modules.LoadingLease,
            name: intern.ModuleName,
            path: ?Value,
            request: QualifiedLoadRequest,
            provenance: modules.RegistrationProvenance,
            artifact: ?pkg_catalog.ArtifactId,
        },

        pub fn deinit(self: *SourceCompletion, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .push, .call, .session => {},
                .register => |*register| {
                    if (register.loading) |*loading| loading.deinit();
                    if (register.path) |path| releases.releaseValue(path);
                },
            }
            self.* = undefined;
        }
    };
    const SourceText = union(enum) {
        borrowed: struct { source_name: []const u8, source: []const u8 },
        owned: struct { source_name: []u8, source: []u8 },

        fn sourceName(self: SourceText) []const u8 {
            return switch (self) {
                .borrowed => |text| text.source_name,
                .owned => |text| text.source_name,
            };
        }
        fn source(self: SourceText) []const u8 {
            return switch (self) {
                .borrowed => |text| text.source,
                .owned => |text| text.source,
            };
        }
        pub fn deinit(self: *SourceText, storage_allocator: std.mem.Allocator) void {
            switch (self.*) {
                .borrowed => {},
                .owned => |text| {
                    storage_allocator.free(text.source);
                    storage_allocator.free(text.source_name);
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
            .text = .init(.{ .owned = .{ .source_name = source_name, .source = source } }),
            .completion = .init(completion),
        });
    }
    fn sourceBorrowed(
        self: *Machine,
        source_name: []const u8,
        source: []const u8,
    ) error{OutOfMemory}!void {
        try self.startDriver(SourceDriver{
            .text = .init(.{ .borrowed = .{ .source_name = source_name, .source = source } }),
            .completion = .init(.session),
        });
    }
    const SourceDriver = struct {
        const State = union(enum) {
            start,
            ingesting: spans.SpanArchive.SourceIngestCursor,
            activating: *Header,
            storage,
        };

        retirement: heap.ReleaseDomain.Retirement = .{},
        text: heap.Owned(SourceText),
        completion: heap.Owned(SourceCompletion),
        diag: reader.Diag = .{},
        state: State = .start,

        pub fn advance(evaluator: *Machine, self: *SourceDriver) MachineError!WorkProgress {
            // Preserve the established pre-cancelled-unit behavior for a
            // source that fits in its first bounded slice: activate it first,
            // so evaluation can attach cancellation to the responsible word.
            // A source that needs another slice observes cancellation before
            // doing any more ingestion work.
            if (self.state != .start) try evaluator.pollKernel();
            var budget: usize = kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.state) {
                .start => self.state = .{ .ingesting = try evaluator.unit.archive.sourceIngestCursor(
                    self.text.borrow().sourceName(),
                    self.text.borrow().source(),
                    &self.diag,
                    @intFromEnum(try evaluator.unit.environment.scopeIdFor(
                        evaluator.unit.lexicalScope(),
                    )),
                ) },
                .ingesting => |*ingestion| {
                    switch (ingestion.advance() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Parse => return evaluator.failAtSource(
                            self.diag.text(),
                            self.text.borrow().sourceName(),
                            self.diag.span,
                        ),
                        error.InvalidProvenance => @panic("archive-bound source reader produced foreign provenance"),
                    }) {
                        .pending => {},
                        .complete => |result| switch (result) {
                            .complete => |root_header| self.state = .{ .activating = root_header },
                            .incomplete => |value_incomplete| switch (self.completion.borrowMut().*) {
                                .session => {
                                    evaluator.unit.finishIncomplete(value_incomplete);
                                    return .completed;
                                },
                                else => return evaluator.failAtSource(
                                    value_incomplete.message,
                                    self.text.borrow().sourceName(),
                                    value_incomplete.span,
                                ),
                            },
                        },
                    }
                },
                .activating => |root_header| {
                    switch (self.completion.borrowMut().*) {
                        .push => try evaluator.pushBorrowed(.{ .list = root_header }),
                        .call, .session => {
                            heap.incRef(root_header);
                            try evaluator.callOwned(root_header);
                        },
                        .register => |*register| {
                            var site = ExecutionSite.inheriting(
                                evaluator.unit.current.?,
                                evaluator.unit.current.?.scope(),
                            );
                            site.registration_provenance = register.provenance;
                            heap.incRef(root_header);
                            const preserves_caller = switch (register.request.continuation) {
                                .replay, .dispatch => true,
                                .load_only => false,
                            };
                            _ = (if (preserves_caller)
                                evaluator.suspendCurrentForQualifiedLoad()
                            else
                                evaluator.suspendCurrent()) catch {
                                evaluator.releaseDomain().releaseHeader(root_header);
                                return error.OutOfMemory;
                            };
                            var continuation = OwnedFrame.init(.{ .qualified_after_load = .{
                                .loading = register.loading.?.move(),
                                .name = register.name,
                                .path = register.path.?,
                                .request = register.request,
                                .artifact = .init(register.artifact),
                            } });
                            defer continuation.deinit(evaluator.releaseDomain(), evaluator.allocator());
                            register.loading = null;
                            register.path = null;
                            evaluator.appendFrame(&continuation) catch {
                                evaluator.releaseDomain().releaseHeader(root_header);
                                return error.OutOfMemory;
                            };
                            evaluator.unit.current = .{
                                .code = root_header,
                                .ip = 0,
                                .site = site,
                                .traced_word = no_word,
                            };
                        },
                    }
                    return .completed;
                },
                .storage => unreachable,
            };
            return .yielded;
        }
        pub fn advanceRetirement(
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
            self: *SourceDriver,
        ) bool {
            return switch (self.state) {
                .start, .activating => result: {
                    self.state = .storage;
                    break :result false;
                },
                .ingesting => |*ingestion| result: {
                    if (!ingestion.advanceRetirement()) break :result false;
                    self.state = .storage;
                    break :result false;
                },
                .storage => {
                    self.completion.deinit(releases, storage_allocator);
                    self.text.deinit(releases, storage_allocator);
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
                self.unit.pendingFailure().addData(.path, item)
            else if (transfer.diagnosticPath()) |item|
                self.unit.pendingFailure().addData(.path, item);
            self.unit.allocator.free(path);
            if (path_value) |item| self.releaseDomain().releaseValue(item);
            var transfer_cleanup = transfer;
            transfer_cleanup.deinit(self.releaseDomain());
            return failure;
        }
        try self.startDriver(FileSourceDriver{
            .allocator = self.unit.allocator,
            .state = .init(.{ .open = .{
                .path = .init(path),
                .path_value = if (path_value) |item| .init(item) else null,
                .transfer = .init(transfer),
            } }),
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
                    .push, .call, .session => null,
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
        const Context = struct {
            path: heap.Owned([]u8),
            path_value: ?heap.Owned(Value),
            transfer: heap.Owned(FileTransfer),

            fn move(self: *Context) Context {
                return .{
                    .path = .init(self.path.take()),
                    .path_value = if (self.path_value) |*item| .init(item.take()) else null,
                    .transfer = .init(self.transfer.take()),
                };
            }
            fn deinit(
                self: *Context,
                releases: *heap.ReleaseDomain,
                storage_allocator: std.mem.Allocator,
            ) void {
                self.transfer.deinit(releases, storage_allocator);
                if (self.path_value) |*item| item.deinit(releases, storage_allocator);
                self.path.deinit(releases, storage_allocator);
            }
        };
        const State = union(enum) {
            open: Context,
            size: struct { context: Context, file: heap.Owned(OpenFile) },
            read: struct {
                context: Context,
                file: heap.Owned(OpenFile),
                reader: std.Io.File.Reader,
                source: heap.Owned([]u8),
                offset: usize,
            },
            transfer: struct { context: Context, source: heap.Owned([]u8) },
            text: struct {
                context: Context,
                source: heap.Owned([]u8),
                builder: heap.Owned(kernel_storage.Utf8Materializer),
            },
            complete: struct { context: Context, source: heap.Owned([]u8) },

            pub fn deinit(
                self: *State,
                releases: *heap.ReleaseDomain,
                storage_allocator: std.mem.Allocator,
            ) void {
                switch (self.*) {
                    .open => |*context| context.deinit(releases, storage_allocator),
                    .size => |*size| {
                        size.file.deinit(releases, storage_allocator);
                        size.context.deinit(releases, storage_allocator);
                    },
                    .read => |*read| {
                        read.source.deinit(releases, storage_allocator);
                        read.file.deinit(releases, storage_allocator);
                        read.context.deinit(releases, storage_allocator);
                    },
                    .transfer => |*transfer| {
                        transfer.source.deinit(releases, storage_allocator);
                        transfer.context.deinit(releases, storage_allocator);
                    },
                    .complete => |*transfer| {
                        transfer.source.deinit(releases, storage_allocator);
                        transfer.context.deinit(releases, storage_allocator);
                    },
                    .text => |*text| {
                        text.builder.deinit(releases, storage_allocator);
                        text.source.deinit(releases, storage_allocator);
                        text.context.deinit(releases, storage_allocator);
                    },
                }
            }
        };

        allocator: std.mem.Allocator,
        state: heap.Owned(State),

        fn diagnosticPath(context: *Context) ?Value {
            if (context.path_value) |*item| return item.borrow();
            return context.transfer.borrow().diagnosticPath();
        }
        fn failIo(context: *Context, evaluator: *Machine, message: []const u8) MachineError {
            const failure = evaluator.fail(.io, message);
            if (diagnosticPath(context)) |item| evaluator.unit.pendingFailure().addData(.path, item);
            return failure;
        }
        pub fn advance(evaluator: *Machine, self: *FileSourceDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            const io = evaluator.unit.inherited.host_io.?;
            switch (self.state.borrowMut().*) {
                .open => |*context| {
                    const file = std.Io.Dir.cwd().openFile(io, context.path.borrow(), .{}) catch |err| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ context.path.borrow(), @errorName(err) },
                        );
                        if (diagnosticPath(context)) |item| evaluator.unit.pendingFailure().addData(.path, item);
                        return failure;
                    };
                    self.state.borrowMut().* = .{ .size = .{
                        .context = context.move(),
                        .file = .init(.{ .io = io, .file = file }),
                    } };
                    return .yielded;
                },
                .size => |*size| {
                    const opened = size.file.borrow();
                    const stat = opened.file.stat(opened.io) catch |err| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ size.context.path.borrow(), @errorName(err) },
                        );
                        if (diagnosticPath(&size.context)) |item| evaluator.unit.pendingFailure().addData(.path, item);
                        return failure;
                    };
                    if (stat.size > std.math.maxInt(usize))
                        return failIo(&size.context, evaluator, "source file is too large");
                    const source = try self.allocator.alloc(u8, @intCast(stat.size));
                    const file_reader = opened.file.reader(opened.io, &.{});
                    self.state.borrowMut().* = .{ .read = .{
                        .context = size.context.move(),
                        .file = .init(size.file.take()),
                        .reader = file_reader,
                        .source = .init(source),
                        .offset = 0,
                    } };
                    return .yielded;
                },
                .read => |*read| {
                    if (read.offset != read.source.borrow().len) {
                        const end = @min(read.offset + kernel_poll_quantum, read.source.borrow().len);
                        const amount = read.reader.interface.readSliceShort(
                            read.source.borrow()[read.offset..end],
                        ) catch {
                            const name = if (read.reader.err) |err| @errorName(err) else "ReadFailed";
                            const failure = evaluator.failFmt(
                                .io,
                                "cannot read `{s}`: {s}",
                                .{ read.context.path.borrow(), name },
                            );
                            if (diagnosticPath(&read.context)) |item| evaluator.unit.pendingFailure().addData(.path, item);
                            return failure;
                        };
                        if (amount == 0) return failIo(
                            &read.context,
                            evaluator,
                            "source file changed while being read",
                        );
                        read.offset += amount;
                        return .yielded;
                    }
                    const context = read.context.move();
                    const source = read.source.take();
                    read.file.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .transfer = .{
                        .context = context,
                        .source = .init(source),
                    } };
                    return .yielded;
                },
                .transfer => |*transfer| {
                    switch (transfer.context.transfer.borrow()) {
                        .text => {
                            const builder = kernel_storage.Utf8Materializer.init(
                                self.allocator,
                                transfer.source.borrow(),
                            );
                            self.state.borrowMut().* = .{ .text = .{
                                .context = transfer.context.move(),
                                .source = .init(transfer.source.take()),
                                .builder = .init(builder),
                            } };
                            return .yielded;
                        },
                        .source => {},
                    }
                    const path = transfer.context.path.take();
                    const source = transfer.source.take();
                    const completion = transfer.context.transfer.take().source;
                    evaluator.retireDriver(self);
                    try evaluator.sourceOwned(path, source, completion);
                    return .detached;
                },
                .text => |*text| switch (text.builder.borrowMut().advance(kernel_poll_quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return failIo(&text.context, evaluator, "file is not valid UTF-8"),
                }) {
                    .pending => return .yielded,
                    .complete => |text_value| {
                        text.builder.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.state.borrowMut().* = .{ .complete = .{
                            .context = text.context.move(),
                            .source = .init(text.source.take()),
                        } };
                        return .{ .output = text_value };
                    },
                },
                .complete => unreachable,
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
            self.unit.pendingFailure().addData(.path, path_value);
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
            evaluator.unit.pendingFailure().addData(.path, self.path_value.borrow());
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
        const State = union(enum) {
            open,
            read: std.Io.File.Reader,
            text: heap.Owned(kernel_storage.Utf8Materializer),
            complete,

            fn deinit(
                self: *State,
                releases: *heap.ReleaseDomain,
                storage_allocator: std.mem.Allocator,
            ) void {
                switch (self.*) {
                    .text => |*text| text.deinit(releases, storage_allocator),
                    .open, .read, .complete => {},
                }
            }
        };

        retirement: heap.ReleaseDomain.Retirement = .{},
        allocator: std.mem.Allocator,
        buffer: std.ArrayList(u8) = .empty,
        // SAFETY: only ever read through the prefix a read call just filled.
        chunk: [read_chunk]u8 = undefined,
        state: State = .open,

        const read_chunk: usize = 8192;

        pub fn advance(evaluator: *Machine, self: *StandardInputDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            switch (self.state) {
                .open => {
                    self.state = .{ .read = std.Io.File.stdin().reader(
                        evaluator.unit.inherited.host_io.?,
                        &.{},
                    ) };
                    return .yielded;
                },
                .read => |*file_reader| {
                    const amount = file_reader.interface.readSliceShort(&self.chunk) catch {
                        const name = if (file_reader.err) |err| @errorName(err) else "ReadFailed";
                        return evaluator.failFmt(.io, "cannot read standard input: {s}", .{name});
                    };
                    if (amount == 0) {
                        self.state = .{ .text = .init(.init(
                            self.allocator,
                            self.buffer.items,
                        )) };
                        return .yielded;
                    }
                    try self.buffer.appendSlice(self.allocator, self.chunk[0..amount]);
                    return .yielded;
                },
                .text => |*text| switch (text.borrowMut().advance(kernel_poll_quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return evaluator.fail(
                        .io,
                        "standard input is not valid UTF-8",
                    ),
                }) {
                    .pending => return .yielded,
                    .complete => |text_value| {
                        text.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.state = .complete;
                        return .{ .output = text_value };
                    },
                },
                .complete => unreachable,
            }
        }
        pub fn advanceRetirement(
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
            self: *StandardInputDriver,
        ) bool {
            self.state.deinit(releases, storage_allocator);
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
        self.unit.pendingFailure().addData(.path, path);
    }
    /// Tags the one absent-only publication conflict that an immutable
    /// package caller may recover after independently confirming the winner.
    pub fn addErrorDestinationExists(self: *Machine) void {
        self.unit.pendingFailure().addData(.@"destination-exists", .{ .int = 1 });
    }
    /// The one absence-is-absence failure for `getenv`: an unset variable is
    /// an error carrying the requested name, never an empty string.
    pub fn unsetEnvironVariable(
        self: *Machine,
        name: []const u8,
        name_value: Value,
    ) MachineError {
        const failure = self.failFmt(.io, "environment variable `{s}` is not set", .{name});
        self.unit.pendingFailure().addData(.name, name_value);
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
        self.unit.pendingFailure().addData(.name, .{ .symbol = name });
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
        self.unit.pendingFailure().addData(.name, .{ .symbol = word });
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
        self.unit.pendingFailure().addData(.scope, .{ .symbol = named });
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
        self.unit.pendingFailure().addData(.needed, .{ .int = @intCast(count) });
        self.unit.pendingFailure().addData(.available, .{ .int = @intCast(self.available()) });
        if (isolation) |guidance| self.unit.pendingFailure().addData(
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
                return OwnedUnitInput.init(null, quotation);
            },
            .unit_plan => |plan| {
                const seeds = heap.unitPlanSeeds(plan);
                const body = heap.unitPlanBody(plan);
                heap.incRef(seeds);
                heap.incRef(body);
                return OwnedUnitInput.init(seeds, body);
            },
            else => return self.typeError("a quotation/list or unit plan"),
        }
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
        if (self.unit.pendingFailureOptional()) |pending|
            pending.site = .{ .token = .{ .code = code, .index = index } };
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
        if (self.unit.pendingFailureOptional()) |pending| pending.trace_parent = word;
    }
    pub fn takePrimitiveFailure(self: *Machine) ?EclErr {
        if (!self.unit.hasPendingFailure()) return null;
        const failure = self.unit.takePendingForUnwind();
        self.unit.finishUnwindCaught();
        return failure;
    }
    fn installPrimitiveFailure(self: *Machine, failure_value: EclErr) MachineError {
        self.unit.installPendingFailure(failure_value);
        if (self.unit.pendingFailure().word == null and self.unit.active_word != no_word) {
            self.unit.pendingFailure().word = self.unit.active_word;
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
        self.unit.installPendingFailure(EclErr.init(kind, message));
        if (self.unit.active_word != no_word) self.unit.pendingFailure().word = self.unit.active_word;
        return error.Ecl;
    }
    fn failAtSource(
        self: *Machine,
        message: []const u8,
        source_name: []const u8,
        span: reader.Span,
    ) MachineError {
        const owned_source_name = self.unit.allocator.dupe(u8, source_name) catch
            return error.OutOfMemory;
        const failure = self.fail(.parse, message);
        self.unit.pendingFailure().site = .{ .explicit_location = .{
            .source_name = owned_source_name,
            .span = span,
        } };
        return failure;
    }
    pub fn failFmt(
        self: *Machine,
        kind: ErrorKind,
        comptime format: []const u8,
        args: anytype,
    ) MachineError {
        self.unit.installPendingFailure(EclErr.initFmt(kind, format, args));
        if (self.unit.active_word != no_word) self.unit.pendingFailure().word = self.unit.active_word;
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
        self.unit.pendingFailure().addData(.index, .{ .int = @intCast(index) });
        return failure;
    }
    /// Reports the two leading-axis lengths that failed to conform.
    pub fn conformError(self: *Machine, left: usize, right: usize) MachineError {
        const failure = self.failFmt(
            .conform,
            "{s} cannot conform leading axes {d} and {d}",
            .{ self.activeWordName(), left, right },
        );
        self.unit.pendingFailure().addData(.left, .{ .int = @intCast(left) });
        self.unit.pendingFailure().addData(.right, .{ .int = @intCast(right) });
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
        self.unit.pendingFailure().addData(.expected, expected);
        self.unit.pendingFailure().addData(.seeded, .{ .int = @intCast(depths.seeded) });
        self.unit.pendingFailure().addData(.observed, .{ .int = @intCast(depths.observed) });
        if (index) |element_index| {
            self.unit.pendingFailure().addData(.index, .{ .int = @intCast(element_index) });
        }
        const site: *ApplicationSelection = @ptrCast(@alignCast(opaque_site));
        self.unit.pendingFailure().site = .{ .contract_quotation = site.takeFailureSite(quotation) };
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
        if (comptime root_execution_metrics_enabled)
            self.unit.root_execution_metrics.logical_transitions += amount;
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
    pub fn attemptOwned(self: *Machine, input: OwnedUnitInput) error{OutOfMemory}!void {
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
                .ordinary,
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
        input: OwnedUnitInput,
    ) MachineError!void {
        var owned = input;
        defer owned.deinit(self.releaseDomain());
        const registry = self.unit.inherited.registry orelse {
            return self.fail(.domain, "module registry is unavailable");
        };
        const word = self.unit.active_word;
        const provenance = self.unit.current.?.site.registration_provenance;
        var candidate = try registry.createImage();
        errdefer candidate.deinit();
        // Attribution asks one question, of the exact designated body. The
        // archive consumes that body into either an unchanged owner or an
        // opaque exact-root admission awaiting a target scope. Seeds are a
        // separate value and are never reached either way.
        //
        // Both re-scoping and seeding are user-sized, so they are ordinary
        // resumable scheduler work: the driver holds the candidate image, the
        // seeds, and the source body until the copy is finished and the
        // boundary can open. Only a body with neither to do still opens it in
        // this step, and that case copies nothing at all.
        var body = heap.Owned(*Header).init(owned.takeBody());
        defer body.deinit(self.releaseDomain(), self.allocator());
        const prepared = try self.unit.archive.prepareConstructionBody(&body);
        switch (prepared) {
            .unchanged => |prepared_body| {
                var runnable = prepared_body;
                defer runnable.deinit(self.releaseDomain(), self.allocator());
                if (owned.seedHeader() == null) {
                    return self.openImageBoundary(
                        &candidate,
                        registration,
                        provenance,
                        word,
                        runnable.take(),
                    );
                }
                try self.startDriver(ConstructionDriver{
                    .state = .init(.{ .open = .{
                        .target = .init(.{ .image = .{
                            .candidate = candidate.move(),
                            .registration = registration,
                            .provenance = provenance,
                        } }),
                        .body = .init(runnable.take()),
                    } }),
                    .materializer = .init(.init(owned.takeSeeds().?)),
                    .word = word,
                });
            },
            .admitted => |admitted| {
                var admission: ?*spans.SpanArchive.AdmittedConstructionBody = admitted;
                defer if (admission) |remaining| remaining.deinit();
                // Only admitted reader text needs a stable image ScopeId. An
                // unchanged runtime body keeps its existing word scopes, so it
                // never creates an attribution-only directory cell.
                const home = candidate.executionHome(self.unit.module_access);
                const stamp_scope = try self.unit.environment.scopeIdForOwned(
                    home.scope(self.unit.module_access),
                    modules.anchorHandle(home, self.unit.module_access),
                );
                var cursor = heap.Owned(spans.SpanArchive.RescopeCursor).init(
                    admission.?.begin(@intFromEnum(stamp_scope)),
                );
                admission = null;
                defer cursor.deinit(self.releaseDomain(), self.allocator());
                try self.startDriver(ConstructionDriver{
                    .state = .init(.{ .rescope = .{
                        .target = .init(.{ .image = .{
                            .candidate = candidate.move(),
                            .registration = registration,
                            .provenance = provenance,
                        } }),
                        .cursor = .init(cursor.take()),
                    } }),
                    .materializer = if (owned.takeSeeds()) |seeds|
                        .init(.init(seeds))
                    else
                        null,
                    .word = word,
                });
            },
        }
    }
    /// Opens one construction boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure, and the image is
    /// consumed only once the boundary owns it.
    fn openImageBoundary(
        self: *Machine,
        candidate: *modules.OwnedImage,
        registration: ?u32,
        provenance: modules.RegistrationProvenance,
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
            .{ .module = .{
                .image = candidate.move(),
                .registration = registration,
                .provenance = provenance,
            } },
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
        const qualified_call_site = ErrorSite{
            .code = self.unit.current.?.code,
            .index = self.unit.active_index,
        };
        switch (self.unit.module_call_sites.lookupQualified(
            self.releaseDomain(),
            self.unit.module_access,
            qualified_call_site,
            word.name,
        )) {
            .absent => {},
            .stale => {
                if (comptime root_execution_metrics_enabled)
                    self.unit.root_execution_metrics.qualified_cache_heals += 1;
            },
            .hit => |resolution| {
                if (comptime root_execution_metrics_enabled)
                    self.unit.root_execution_metrics.qualified_cache_hits += 1;
                var resolved = resolution;
                defer resolved.deinit(self.unit.allocator);
                try executeResolved(self, &resolved);
                return;
            },
        }
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
        const local_context = LocalCacheContext.init(running_site, word.scope);
        if (local_context) |context| {
            switch (self.unit.module_call_sites.lookupLocal(
                qualified_call_site,
                word.name,
                context,
            )) {
                .absent => {
                    if (comptime root_execution_metrics_enabled)
                        self.unit.root_execution_metrics.local_cache_misses += 1;
                },
                .stale => unreachable,
                .hit => |resolution| {
                    if (comptime root_execution_metrics_enabled)
                        self.unit.root_execution_metrics.local_cache_hits += 1;
                    var resolved = resolution;
                    defer resolved.deinit(self.unit.allocator);
                    try executeResolved(self, &resolved);
                    return;
                },
            }
        }
        const local_cache_scope = if (local_context) |context| context.scope_id else null;
        if (word.scope != 0 and
            @intFromEnum(running_site.resolution_scope_id) == word.scope)
        {
            self.unit.active_word = .plain(word.name);
            try self.startDriver(DispatchDriver{
                .word = word.name,
                .call_site = qualified_call_site,
                .resolution = .init(.init(
                    self,
                    word.name,
                    running_site.resolution_scope,
                    null,
                    // The activation already holds this chain, so the fast path
                    // acquires nothing -- that is the point of it.
                    null,
                    local_cache_scope,
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
            .call_site = qualified_call_site,
            .resolution = .init(.init(
                self,
                word.name,
                written,
                owned_pin,
                owned_cell,
                local_cache_scope,
            )),
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
        self.unit.installPendingFailure(EclErr.init(.user, "raised error"));
        if (self.unit.active_word != no_word) self.unit.pendingFailure().word = self.unit.active_word;
        self.unit.pendingFailure().raised = raised;
        return error.Ecl;
    }
    fn beginAttemptOwned(
        self: *Machine,
        input: OwnedUnitInput,
    ) error{OutOfMemory}!void {
        var owned = input;
        defer owned.deinit(self.releaseDomain());
        // An unseeded `@attempt` opens its boundary in this step and allocates
        // nothing extra; a seeded one materializes a user-sized seed list, so
        // it becomes ordinary resumable scheduler work like every other
        // user-sized traversal.
        if (owned.seedHeader() == null) return self.openAttempt(owned.takeBody());
        return self.startDriver(ConstructionDriver{
            .state = .init(.{ .open = .{
                .target = .init(.attempt),
                .body = .init(owned.takeBody()),
            } }),
            .materializer = .init(.init(owned.takeSeeds().?)),
            .word = self.unit.active_word,
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

/// A non-owning child-launch projection. The decoded owner remains alive until
/// the scheduler has retained the quotation and initial operands into the new
/// Unit, so a child launch never invents a second teardown protocol.
pub const BorrowedUnitInput = struct {
    body: *Header,
    seeds: ?*Header,

    pub fn quotation(self: BorrowedUnitInput) *Header {
        return self.body;
    }

    pub fn initialStack(self: BorrowedUnitInput, element: ?Value) InitialStack {
        if (element) |item| {
            const seeds = self.seeds orelse return .{ .borrowed_element = item };
            return .{ .borrowed_element_and_seeds = .{ .element = item, .seeds = seeds } };
        }
        const seeds = self.seeds orelse return .empty;
        return .{ .borrowed_seeds = seeds };
    }
};

/// The decoded input every unit constructor takes. A raw quotation owns only
/// `body`; a plan independently owns both list references. This remains the
/// one nominal owner through validation, child borrowing, fan-out transfer,
/// and boundary handoff. Moving it empties the source, and `deinit` is the sole
/// destructor for an input that has not split into later boundary states.
pub const OwnedUnitInput = enum(u128) {
    consumed = 0,
    _,

    const pointer_mask: u128 = std.math.maxInt(u64);

    comptime {
        if (@bitSizeOf(usize) > 64)
            @compileError("OwnedUnitInput requires pointers no wider than 64 bits");
    }

    fn init(seeds: ?*Header, body: *Header) OwnedUnitInput {
        const body_bits: u128 = @intFromPtr(body);
        const seed_bits: u128 = if (seeds) |items| @intFromPtr(items) else 0;
        std.debug.assert(body_bits != 0 and body_bits <= pointer_mask);
        std.debug.assert(seed_bits <= pointer_mask);
        return @enumFromInt(body_bits | (seed_bits << 64));
    }

    fn bodyHeader(self: OwnedUnitInput) ?*Header {
        const bits = @intFromEnum(self) & pointer_mask;
        return if (bits == 0) null else @ptrFromInt(@as(usize, @intCast(bits)));
    }

    fn seedHeader(self: OwnedUnitInput) ?*Header {
        const bits = @intFromEnum(self) >> 64;
        return if (bits == 0) null else @ptrFromInt(@as(usize, @intCast(bits)));
    }

    pub fn borrow(self: *const OwnedUnitInput) BorrowedUnitInput {
        std.debug.assert(self.* != .consumed);
        return .{ .body = self.bodyHeader().?, .seeds = self.seedHeader() };
    }

    pub fn move(self: *OwnedUnitInput) OwnedUnitInput {
        std.debug.assert(self.* != .consumed);
        const moved = self.*;
        self.* = .consumed;
        return moved;
    }

    fn takeBody(self: *OwnedUnitInput) *Header {
        const body = self.bodyHeader().?;
        const seed_bits = @intFromEnum(self.*) & ~pointer_mask;
        self.* = if (seed_bits == 0) .consumed else @enumFromInt(seed_bits);
        return body;
    }

    fn takeSeeds(self: *OwnedUnitInput) ?*Header {
        const seeds = self.seedHeader();
        const body_bits = @intFromEnum(self.*) & pointer_mask;
        self.* = if (body_bits == 0) .consumed else @enumFromInt(body_bits);
        return seeds;
    }

    pub fn deinit(self: *OwnedUnitInput, releases: *heap.ReleaseDomain) void {
        if (self.seedHeader()) |items| releases.releaseHeader(items);
        if (self.bodyHeader()) |quotation| releases.releaseHeader(quotation);
        self.* = .consumed;
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
    std.debug.assert(unit.terminal == .evaluating);
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
        try evaluator.startDriver(ChildSeedDriver{
            .materializer = .init(.init(items)),
        });
    }
    heap.incRef(code);
    unit.current = .{
        .code = code,
        .ip = 0,
        .site = .root(unit),
        .traced_word = no_word,
    };
}

/// Installs one borrowed Session source as the root unit's first scheduled
/// work. The source bytes need only remain live until `runInitializedRoot`
/// returns; driver teardown is completed before that blocking call exits.
pub fn initializeSource(
    unit: *Unit,
    source_name: []const u8,
    source: []const u8,
) error{OutOfMemory}!void {
    var empty = heap.OwnedValue.init(
        unit.releases,
        try list.fromValuesGeneric(unit.allocator, &.{}),
    );
    defer empty.deinit();
    try initialize(unit, empty.borrow().list, .empty);
    var evaluator = Machine{ .unit = unit };
    try evaluator.sourceBorrowed(source_name, source);
}

pub fn runSlice(unit: *Unit) MachineError!RunStatus {
    var evaluator = Machine{ .unit = unit };
    defer unit.dropSpareScope();
    const status = loop(&evaluator) catch |err| switch (err) {
        error.Ecl => return error.Ecl,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (comptime root_execution_metrics_enabled) {
        if (status != .completed) unit.root_execution_metrics.scheduler_handoffs += 1;
    }
    return status;
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
            if (comptime root_execution_metrics_enabled)
                self.unit.root_execution_metrics.driver_resumes += 1;
            const progress = driver.advance(self) catch |err| {
                if (err == error.Ecl and self.unit.pendingFailure().site == null) {
                    if (driver.site) |site| self.unit.pendingFailure().site = .{ .token = site };
                }
                if (err == error.Ecl and self.unit.pendingFailure().trace_parent == null) {
                    self.unit.pendingFailure().trace_parent = driver.trace_parent;
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
        if (self.unit.hasRequestedExit()) {
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
                self.unit.installPendingFailure(EclErr.init(.cancelled, "unit cancelled"));
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
        if (comptime root_execution_metrics_enabled)
            self.unit.root_execution_metrics.logical_transitions += 1;
        dispatch(self, form) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                if (self.unit.pendingFailure().site == null and self.unit.current != null) {
                    self.unit.pendingFailure().site = .{ .token = .{
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
        .scope_closed => |status| self.unit.requestExit(status),
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
        .materializer = list.ValueMaterializer.init(
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
    materializer: list.ValueMaterializer,

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
    call_site: ?ErrorSite = null,
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
                const word = self.word;
                const request = QualifiedLoadRequest{
                    .qualified = word,
                    .continuation = .{ .dispatch = .{
                        .word = word,
                        .site = installed.site,
                        .trace_parent = installed.trace_parent,
                    } },
                };
                self.resolution.deinit(self_machine.releaseDomain(), self_machine.allocator());
                const allocator = self_machine.unit.allocator;
                const call_site = self.call_site;
                self_machine.retireDriver(self);
                switch (outcome) {
                    .resolved => |resolution| {
                        var resolved = resolution;
                        defer resolved.deinit(allocator);
                        if (comptime root_execution_metrics_enabled) {
                            if (resolved.execution_generation != null) {
                                self_machine.unit.root_execution_metrics.qualified_cache_misses += 1;
                            }
                        }
                        if (resolved.takeCallSiteCache()) |candidate_value| {
                            var candidate = candidate_value;
                            if (call_site) |site| {
                                self_machine.unit.module_call_sites.install(
                                    self_machine.releaseDomain(),
                                    site,
                                    word,
                                    candidate,
                                );
                            } else candidate.deinit();
                        }
                        try executeResolved(self_machine, &resolved);
                        return .detached;
                    },
                    // A qualified dispatch carries its exact word and
                    // provenance through loading, including dynamic execute.
                    .unknown_module_prefix => |prefix| {
                        try self_machine.startDriver(QualifiedLoadPreparationDriver.init(
                            prefix,
                            request,
                            .none,
                        ));
                        return .detached;
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

/// Resumable boundary between a qualified miss and module loading. A prefix
/// absent from the intern table is external, runtime-sized input; preserving
/// this cursor as its own driver keeps both insertion and module-name
/// validation inside scheduler safe points.
const QualifiedLoadPreparationDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    const Restore = union(enum) {
        none,
        operand: u32,
    };

    cursor: intern.InternModuleNameCursor,
    request: QualifiedLoadRequest,
    restore: Restore,

    fn init(
        prefix: []const u8,
        request: QualifiedLoadRequest,
        restore: Restore,
    ) QualifiedLoadPreparationDriver {
        return .{
            .cursor = intern.internModuleNameCursor(prefix),
            .request = request,
            .restore = restore,
        };
    }

    pub fn advance(
        evaluator: *Machine,
        self: *QualifiedLoadPreparationDriver,
    ) MachineError!WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (try self.cursor.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return switch (self.restore) {
                    .none => evaluator.undefinedWordIn(self.request.qualified, .qualified),
                    .operand => evaluator.undefinedNameIn(self.request.qualified, .qualified),
                };
                const request = self.request;
                const restore = self.restore;
                switch (restore) {
                    .none => {},
                    .operand => |requested| {
                        try evaluator.pushBorrowed(.{ .symbol = requested });
                        evaluator.unit.current.?.ip = evaluator.unit.active_index;
                    },
                }
                evaluator.retireDriver(self);
                try evaluator.autoLoadModule(name, request);
                return .detached;
            },
        };
        return .yielded;
    }
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
                .call_site = dispatch_request.site,
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
    loading: ?heap.Owned(modules.LoadingLease) = null,
    artifact: ?pkg_catalog.ArtifactId = null,
    module_index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *QualifiedRegistrationDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        switch (self.acquisition.borrowMut().advance()) {
            .pending => return .yielded,
            .complete => |maybe_generation| {
                const checked_name = if (self.artifact) |artifact|
                    evaluator.unit.inherited.project_lock.?.artifactModules(artifact)[self.module_index]
                else
                    self.name;
                const generation = maybe_generation orelse {
                    const failure = if (self.artifact != null)
                        evaluator.failFmt(
                            .io,
                            "loading package artifact registered nothing under declared module `{s}`",
                            .{intern.get(intern.moduleId(checked_name))},
                        )
                    else
                        evaluator.failFmt(
                            .io,
                            "loading module `{s}` registered nothing under that name",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                    evaluator.unit.pendingFailure().addData(.path, self.path.borrow());
                    return failure;
                };
                var lease = generation;
                defer lease.deinit();
                if (self.artifact) |artifact| {
                    const expected_package = evaluator.unit.inherited.project_lock.?.artifactPackage(artifact);
                    const valid_origin = switch (lease.provenance()) {
                        .package => |package| package == expected_package,
                        .ordinary, .root_package, .standard_library => false,
                    };
                    if (!valid_origin) {
                        const failure = evaluator.failFmt(
                            .domain,
                            "package artifact declared module `{s}` with foreign publication provenance",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                        evaluator.unit.pendingFailure().addData(.path, self.path.borrow());
                        return failure;
                    }
                    const modules_in_artifact = evaluator.unit.inherited.project_lock.?.artifactModules(artifact);
                    self.module_index += 1;
                    if (self.module_index != modules_in_artifact.len) {
                        self.acquisition.deinit(evaluator.releaseDomain(), evaluator.allocator());
                        self.acquisition = .init(evaluator.unit.inherited.registry.?.acquireCursor(
                            modules_in_artifact[self.module_index],
                        ));
                        return .yielded;
                    }
                    evaluator.unit.inherited.project_lock.?.commitArtifact(artifact);
                    self.loading.?.borrowMut().finish();
                }
                return continueQualifiedRequest(evaluator, self, self.request);
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
            if (resolved.origin == .core or resolved.origin == .standard_library) {
                heap.incRef(body_header);
                const fallback: DirectWordFallback = .{
                    .body = .init(body_header),
                    .word = resolved.trace_word,
                    .home = resolved.home,
                    .effect = if (cross_home_effect) |effect|
                        .init(RetainedEffect.init(effect))
                    else
                        null,
                    .pin = if (resolved.home) |home|
                        .init(home.pin(self.unit.module_access))
                    else
                        null,
                };
                return self.continueWithIdiom(
                    .{ .direct = .{
                        .body = body_header,
                        .word = resolved.trace_word.atom(),
                        .scope = if (resolved.home) |home|
                            home.scope(self.unit.module_access)
                        else
                            null,
                    } },
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

const RetainedEffect = struct {
    effect: env.Effect,

    fn init(effect: env.Effect) RetainedEffect {
        effect.retain();
        return .{ .effect = effect };
    }
    pub fn deinit(self: *RetainedEffect, releases: *heap.ReleaseDomain) void {
        self.effect.retire(releases);
        self.* = undefined;
    }
};

const DirectWordFallback = struct {
    body: heap.Owned(*Header),
    word: intern.TraceWord,
    home: ?*modules.ModuleHome,
    effect: ?heap.Owned(RetainedEffect),
    pin: ?heap.Owned(modules.GenerationPin),
    pub fn run(evaluator: *Machine, self: *DirectWordFallback) MachineError!void {
        return scheduleWord(
            evaluator,
            self.body.borrow(),
            self.word,
            self.home,
            null,
            if (self.effect) |*owned| owned.borrow().effect else null,
            if (self.pin) |*owned| owned.take() else null,
            null,
        );
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

pub const ResolutionOrigin = resolution_core.Origin;

fn moduleResolutionOrigin(home: *const modules.ModuleHome) ResolutionOrigin {
    return switch (home.registrationProvenance()) {
        .ordinary => .module,
        .standard_library => .standard_library,
        .root_package, .package => .module,
    };
}

/// How a module-local definition is spelled when reached through `home`. An
/// anonymous construction root has no name to qualify with, so code running
/// inside a body under construction traces by its local name alone.
fn homeTraceWord(home: *const modules.ModuleHome, local: intern.BindingName) intern.TraceWord {
    const name = home.name() orelse return .plain(intern.bindingId(local));
    return .moduleLocal(name, local);
}

const CallSiteCacheCandidate = union(enum) {
    qualified: struct {
        generation: modules.GenerationGuard,
        cell: env.BindingCellHandle,
    },
    local: struct {
        scope_id: env.ScopeId,
        cell: env.BindingCellHandle,
    },

    fn deinit(self: *CallSiteCacheCandidate) void {
        switch (self.*) {
            .qualified => |*qualified| {
                qualified.cell.deinit();
                qualified.generation.deinit();
            },
            .local => |*local| local.cell.deinit(),
        }
        self.* = undefined;
    }
};

const CallSiteCacheLookup = union(enum) {
    absent,
    stale,
    hit: Resolution,
};

/// Proof that this occurrence resolves directly in the exact module root the
/// running activation already owns. Scope and home travel together so a cache
/// hit cannot accidentally borrow one image's cell and another registration's
/// state authority.
const LocalCacheContext = struct {
    scope_id: env.ScopeId,
    home: *modules.ModuleHome,

    fn init(site: ExecutionSite, word_scope: u32) ?LocalCacheContext {
        if (word_scope == 0 or
            @intFromEnum(site.resolution_scope_id) != word_scope)
        {
            return null;
        }
        const scope = site.resolution_scope orelse return null;
        if (!scope.isModuleRoot()) return null;
        return .{
            .scope_id = site.resolution_scope_id,
            .home = site.home orelse return null,
        };
    }
};

/// A small, allocation-free lookaside indexed by the actual source call site.
/// Each entry owns its code root and one guarded target. Two ways keep a
/// caller's qualified site and its callee's local site from evicting each other
/// when their hashes share a set. Capacity remains a hard memory bound;
/// collisions lose performance only.
const ModuleCallSiteCache = struct {
    const capacity = 16;
    const ways = 2;
    const set_count = capacity / ways;
    const Entry = struct {
        code: OwnedCode,
        index: u32,
        word: u32,
        target: CallSiteCacheCandidate,

        fn deinit(self: *Entry, releases: *heap.ReleaseDomain) void {
            self.target.deinit();
            self.code.deinit(releases);
            self.* = undefined;
        }
    };

    entries: [capacity]?Entry = .{null} ** capacity,
    victims: [set_count]u1 = .{0} ** set_count,

    fn set(site: ErrorSite) usize {
        return (@intFromPtr(site.code) >> 4 ^ site.index) % set_count;
    }

    fn find(self: *ModuleCallSiteCache, site: ErrorSite, word: u32) ?usize {
        const base = set(site) * ways;
        for (0..ways) |way| {
            const index = base + way;
            const candidate = &(self.entries[index] orelse continue);
            if (candidate.code.borrow() == site.code and
                candidate.index == site.index and
                candidate.word == word)
            {
                return index;
            }
        }
        return null;
    }

    fn lookupQualified(
        self: *ModuleCallSiteCache,
        releases: *heap.ReleaseDomain,
        access: *const modules.ExecutionAccess,
        site: ErrorSite,
        word: u32,
    ) CallSiteCacheLookup {
        const slot_index = self.find(site, word) orelse return .absent;
        const candidate = &(self.entries[slot_index] orelse return .absent);
        const qualified = switch (candidate.target) {
            .qualified => |*target| target,
            .local => return .absent,
        };
        const execution = qualified.generation.tryEnterCurrent(access) orelse {
            candidate.deinit(releases);
            self.entries[slot_index] = null;
            return .stale;
        };
        const lease = qualified.cell.load();
        const home = execution.home(access);
        return .{ .hit = .{
            .lease = lease,
            .execution_generation = execution,
            .home = home,
            .trace_word = homeTraceWord(home, lease.traceWord().?),
            .origin = moduleResolutionOrigin(home),
        } };
    }

    fn lookupLocal(
        self: *ModuleCallSiteCache,
        site: ErrorSite,
        word: u32,
        context: LocalCacheContext,
    ) CallSiteCacheLookup {
        const slot_index = self.find(site, word) orelse return .absent;
        const candidate = &(self.entries[slot_index] orelse return .absent);
        const local = switch (candidate.target) {
            .local => |*target| target,
            .qualified => return .absent,
        };
        if (local.scope_id != context.scope_id) return .absent;
        const lease = local.cell.load();
        return .{ .hit = .{
            .lease = lease,
            .execution_generation = null,
            .home = context.home,
            .trace_word = homeTraceWord(context.home, lease.traceWord().?),
            .origin = moduleResolutionOrigin(context.home),
        } };
    }

    fn install(
        self: *ModuleCallSiteCache,
        releases: *heap.ReleaseDomain,
        site: ErrorSite,
        word: u32,
        candidate: CallSiteCacheCandidate,
    ) void {
        const set_index = set(site);
        const base = set_index * ways;
        const destination_index = self.find(site, word) orelse empty: {
            for (0..ways) |way| {
                const index = base + way;
                if (self.entries[index] == null) break :empty index;
            }
            const victim = base + self.victims[set_index];
            self.victims[set_index] ^= 1;
            break :empty victim;
        };
        const destination = &self.entries[destination_index];
        if (destination.*) |*previous| previous.deinit(releases);
        destination.* = .{
            .code = .retain(site.code),
            .index = site.index,
            .word = word,
            .target = candidate,
        };
    }

    fn deinit(self: *ModuleCallSiteCache, releases: *heap.ReleaseDomain) void {
        for (&self.entries) |*entry| if (entry.*) |*live| live.deinit(releases);
        self.* = undefined;
    }
};

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
    call_site_cache: ?CallSiteCacheCandidate = null,
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
        if (self.call_site_cache) |*candidate| candidate.deinit();
        self.lease.deinit();
        if (self.execution_generation) |*generation| generation.deinit();
        // Released only if the dispatch never scheduled a body; `scheduleWord`
        // consumes them otherwise.
        if (self.borrow_pin) |*pin| pin.deinit();
        if (self.borrowed_cell) |cell| cell.releaseBorrow();
        self.* = undefined;
    }

    fn takeCallSiteCache(self: *Resolution) ?CallSiteCacheCandidate {
        const candidate = self.call_site_cache;
        self.call_site_cache = null;
        return candidate;
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
        package_authorization,
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
        catalog: pkg_lock.LookupCursor,
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
                .catalog => |*cursor| cursor.deinit(),
                .none, .dot, .atom, .module_validation, .binding_validation => {},
            }
            self.* = .none;
        }
    };
    allocator: std.mem.Allocator,
    registry: ?*modules.Registry,
    project_lock: ?*const pkg_lock.ProjectLock,
    package: ?pkg_catalog.PackageId,
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
    /// Present only for a source occurrence resolving directly in the running
    /// module root. The activation is the liveness proof for this scope.
    local_cache_scope: ?env.ScopeId = null,

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
        return .init(evaluator, word, evaluator.unit.current.?.resolutionScope(), null, null, null);
    }

    pub fn init(
        evaluator: *Machine,
        word: u32,
        written: ?*env.Scope,
        borrow_pin: ?modules.GenerationPin,
        borrowed_cell: ?*env.ScopeCell,
        local_cache_scope: ?env.ScopeId,
    ) ResolutionCursor {
        const spelling = intern.get(word);
        return .{
            .borrow_pin = borrow_pin,
            .borrowed_cell = borrowed_cell,
            .local_cache_scope = local_cache_scope,
            .allocator = evaluator.unit.allocator,
            .registry = evaluator.unit.inherited.registry,
            .project_lock = evaluator.unit.inherited.project_lock,
            .package = evaluator.currentPackage(),
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

    fn directResult(
        self: *ResolutionCursor,
        lease: env.BindingLease,
        captured_cell: ?env.BindingCellHandle,
    ) Resolution {
        const local = lease.traceWord();
        const home = if (local == null) null else self.homeForLocalHit();
        var cell = captured_cell;
        const cache = cache: {
            const scope_id = self.local_cache_scope orelse {
                if (cell) |*owned| owned.deinit();
                break :cache null;
            };
            if (local == null) {
                if (cell) |*owned| owned.deinit();
                break :cache null;
            }
            break :cache CallSiteCacheCandidate{ .local = .{
                .scope_id = scope_id,
                .cell = cell.?,
            } };
        };
        return .{
            .lease = lease,
            .execution_generation = null,
            .home = home,
            .borrow_pin = self.takeBorrowPin(),
            .borrowed_cell = self.takeBorrowedCell(),
            .trace_word = if (home) |resolved| homeTraceWord(resolved, local.?) else .plain(self.word),
            .origin = if (home) |resolved| moduleResolutionOrigin(resolved) else .direct,
            // A module-local hit resolves against its image, which the home
            // supplies; anything else resolves against the scope it was found
            // in.
            .defining_scope = if (home != null) null else self.searched_scope,
            .call_site_cache = cache,
        };
    }

    /// A qualified reference resolved through a registered generation. It is
    /// the only path that hands a generation lease to its resolution, so the
    /// origin is always the module it named.
    fn generationResult(
        self: *ResolutionCursor,
        lease: env.BindingLease,
        captured_cell: ?env.BindingCellHandle,
    ) Resolution {
        var generation_lease = self.generation.?;
        self.generation = null;
        var cell = captured_cell;
        const cache = cache: {
            if (generation_lease.name() != self.prefix.?) {
                if (cell) |*owned| owned.deinit();
                break :cache null;
            }
            break :cache CallSiteCacheCandidate{ .qualified = .{
                .generation = generation_lease.guard(),
                .cell = cell.?,
            } };
        };
        const execution_generation = generation_lease.enterExecution(self.module_access);
        const home = execution_generation.home(self.module_access);
        return .{
            .lease = lease,
            .execution_generation = execution_generation,
            .home = home,
            .trace_word = homeTraceWord(home, lease.traceWord().?),
            .origin = moduleResolutionOrigin(home),
            .call_site_cache = cache,
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
                    if (self.project_lock) |project_lock| {
                        if (stdlib.find(intern.get(intern.moduleId(self.prefix.?))) != null) {
                            self.work = .{ .acquisition = self.registry.?.acquireCursor(self.prefix.?) };
                            self.phase = .qualified_acquire;
                        } else {
                            self.work = .{ .catalog = project_lock.lookupCursor(
                                self.package,
                                intern.get(intern.moduleId(self.prefix.?)),
                            ) };
                            self.phase = .package_authorization;
                        }
                    } else {
                        self.work = .{ .acquisition = self.registry.?.acquireCursor(self.prefix.?) };
                        self.phase = .qualified_acquire;
                    }
                    break :result .pending;
                },
            },
            .package_authorization => switch (self.work.catalog.advance()) {
                .pending => .pending,
                .complete => |outcome| result: {
                    self.work.deinit();
                    switch (outcome) {
                        .matched => |match| {
                            if (self.project_lock.?.artifactCommitted(match.artifact_id)) {
                                self.work = .{ .acquisition = self.registry.?.acquireCursor(self.prefix.?) };
                                self.phase = .qualified_acquire;
                                break :result .pending;
                            }
                            self.phase = .complete;
                            break :result .{ .complete = .{ .unregistered_module = self.prefix.? } };
                        },
                        .unmatched, .hidden, .invalid => {
                            self.phase = .complete;
                            break :result .{ .complete = .{ .unregistered_module = self.prefix.? } };
                        },
                    }
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
                    var export_lookup = self.generation.?.resolveCursor(
                        intern.bindingId(intern.qualifiedBinding(self.qualified_name.?)),
                    );
                    export_lookup.captureCell();
                    self.work = .{ .export_lookup = export_lookup };
                    self.phase = .qualified_export;
                    break :result .pending;
                },
            },
            .qualified_export => switch (self.work.export_lookup.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    const captured_cell = if (maybe_lease != null)
                        self.work.export_lookup.takeCell()
                    else
                        null;
                    self.work.deinit();
                    const lease = maybe_lease orelse {
                        self.releaseGeneration();
                        self.phase = .complete;
                        break :result .{ .complete = .{ .unresolved = .qualified } };
                    };
                    self.phase = .complete;
                    break :result .{ .complete = .{
                        .resolved = self.generationResult(lease, captured_cell),
                    } };
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
                    var direct = environment.directLookupCursor(self.word);
                    if (self.local_cache_scope != null) direct.captureCell();
                    self.work = .{ .direct = direct };
                    self.phase = .direct;
                }
                break :result .pending;
            },
            .direct => switch (self.work.direct.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| result: {
                    const captured_cell = if (maybe_lease != null)
                        self.work.direct.takeCell()
                    else
                        null;
                    self.work.deinit();
                    if (maybe_lease) |lease| {
                        self.phase = .complete;
                        break :result .{ .complete = .{
                            .resolved = self.directResult(lease, captured_cell),
                        } };
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
    const registration_provenance = if (resolved_home == null)
        self.unit.current.?.site.registration_provenance
    else
        resolved_home.?.registrationProvenance();
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
            .registration_provenance = registration_provenance,
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
        self.unit.pendingFailure().addData(.seeded, .{ .int = available });
        self.unit.pendingFailure().addData(.observed, .{ .int = available });
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
            if (comptime root_execution_metrics_enabled)
                self.unit.root_execution_metrics.application_resumes += 1;
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
            const artifact = continuation.artifact.artifact();
            const first_name = if (artifact) |artifact_id|
                self.unit.inherited.project_lock.?.artifactModules(artifact_id)[0]
            else
                continuation.name;
            if (artifact == null) loading.finish();
            try self.startDriver(QualifiedRegistrationDriver{
                .name = continuation.name,
                .path = .init(path.take()),
                .acquisition = .init(registry.acquireCursor(first_name)),
                .request = continuation.request,
                .loading = if (artifact != null) .init(loading.move()) else null,
                .artifact = artifact,
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
    self.unit.pendingFailure().addData(.seeded, .{ .int = check.entry_depth });
    self.unit.pendingFailure().addData(.observed, .{ .int = @intCast(observed_relative) });
    if (check.takeCandidate()) |candidate|
        self.unit.pendingFailure().site = .{ .contract_quotation = candidate };
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
    materializer: heap.Owned(list.ValueMaterializer),
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
        .state = .init(.{ .capture = .{
            .image = .init(image.move()),
            .remaining = observed,
            .completion = if (owned.registration) |symbol|
                .{ .named = .{
                    .cursor = .init(symbol),
                    .provenance = owned.provenance,
                } }
            else
                .value,
        } }),
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

/// The one bounded owner/progress state for plan seed materialization. Both an
/// in-machine construction boundary and a fresh child Unit embed this exact
/// state machine. Capacity for a granted slice is secured before its first
/// append, so allocation failure adds none of that slice; an earlier prefix is
/// ordinary stack ownership and retires with its boundary or Unit.
const SeedMaterializer = struct {
    seeds: heap.Owned(*Header),
    next: usize = 0,

    fn init(seeds: *Header) SeedMaterializer {
        return .{ .seeds = .init(seeds) };
    }

    pub fn deinit(
        self: *SeedMaterializer,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        self.seeds.deinit(releases, allocator);
        self.next = 0;
    }

    fn advance(
        self: *SeedMaterializer,
        unit: *Unit,
        budget: usize,
    ) error{OutOfMemory}!bool {
        const seeds = self.seeds.borrow();
        const count: usize = @intCast(seeds.length());
        const end = @min(self.next + budget, count);
        try unit.stack.ensureUnusedCapacity(unit.allocator, end - self.next);
        for (self.next..end) |index| {
            const item = list.atUnchecked(.{ .list = seeds }, index);
            unit.stack.appendAssumeCapacity(item);
            heap.retainValue(item);
        }
        self.next = end;
        return self.next == count;
    }
};

/// What a `ConstructionDriver` opens once its body is final.
const ConstructionTarget = union(enum) {
    /// `@attempt`: a child scope on the enclosing chain, created at open time.
    attempt,
    /// `@module`/`@defm`: the candidate image and the name it registers under.
    image: struct {
        candidate: modules.OwnedImage,
        registration: ?u32,
        provenance: modules.RegistrationProvenance,
    },

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
    const State = union(enum) {
        /// The re-scoping pass owns its exact admitted source and the target
        /// that will receive the completed copy.
        rescope: struct {
            target: heap.Owned(ConstructionTarget),
            cursor: heap.Owned(spans.SpanArchive.RescopeCursor),
        },
        /// The finished copy, or an unchanged input body, is owned until the
        /// target boundary consumes it on both success and failure.
        open: struct {
            target: heap.Owned(ConstructionTarget),
            body: heap.Owned(*Header),
        },
        /// The boundary exists and only the independently optional seeds may
        /// remain to be materialized.
        seed,

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .rescope => |*rescope| {
                    rescope.cursor.deinit(releases, allocator);
                    rescope.target.deinit(releases, allocator);
                },
                .open => |*open| {
                    open.body.deinit(releases, allocator);
                    open.target.deinit(releases, allocator);
                },
                .seed => {},
            }
            self.* = undefined;
        }
    };

    state: heap.Owned(State),
    materializer: ?heap.Owned(SeedMaterializer),
    /// The word that opened the construction, captured because the boundary is
    /// opened in a later step than the one that dispatched it.
    word: intern.TraceWord,

    pub fn advance(evaluator: *Machine, self: *ConstructionDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        switch (self.state.borrowMut().*) {
            .rescope => |*rescope| {
                var work: poll_api.WorkBudget = .init(construction_work_quantum);
                const progress = rescope.cursor.borrowMut().advance(&work) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidProvenance => @panic("archive refused its own completed re-scope publication"),
                };
                const stamped = switch (progress) {
                    .pending => return .yielded,
                    .complete => |header| header,
                };
                rescope.cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                const next = @FieldType(State, "open"){
                    .target = .init(rescope.target.take()),
                    .body = .init(stamped),
                };
                self.state.borrowMut().* = .{ .open = next };
                return .yielded;
            },
            .open => |*open| {
                // The body is consumed by the open, on success and on failure
                // alike; the seeds are not, so they stay owned here until the
                // boundary they seed exists.
                const body = open.body.take();
                switch (open.target.borrowMut().*) {
                    .attempt => {
                        try evaluator.openAttempt(body);
                    },
                    .image => |*owned| {
                        const registration = owned.registration;
                        try evaluator.openImageBoundary(
                            &owned.candidate,
                            registration,
                            owned.provenance,
                            self.word,
                            body,
                        );
                    },
                }
                open.target.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state.borrowMut().* = .seed;
                return .yielded;
            },
            .seed => {
                // A construction that only had a body to re-scope reaches this
                // phase with nothing to seed, which is the whole of its work.
                if (self.materializer) |*materializer| {
                    return if (try materializer.borrowMut().advance(
                        evaluator.unit,
                        construction_work_quantum,
                    )) .completed else .yielded;
                }
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
    materializer: heap.Owned(SeedMaterializer),

    pub fn advance(evaluator: *Machine, self: *ChildSeedDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        return if (try self.materializer.borrowMut().advance(
            evaluator.unit,
            construction_work_quantum,
        )) .completed else .yielded;
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
    state: heap.Owned(State),

    const State = union(enum) {
        capture: struct {
            image: heap.Owned(modules.OwnedImage),
            /// Construction-stack values still to move into the image
            /// template, counted from the top of the residual window down.
            remaining: usize,
            completion: union(enum) {
                value,
                named: struct {
                    cursor: intern.ModuleNameCursor,
                    provenance: modules.RegistrationProvenance,
                },
            },
        },
        value: heap.Owned(modules.SealedImage),
        validate: struct {
            sealed: heap.Owned(modules.SealedImage),
            cursor: intern.ModuleNameCursor,
            provenance: modules.RegistrationProvenance,
        },
        publish: struct {
            sealed: heap.Owned(modules.SealedImage),
            cursor: heap.Owned(modules.Registry.RegistrationCursor),
        },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .capture => |*capture| capture.image.deinit(releases, storage_allocator),
                .value => |*sealed| sealed.deinit(releases, storage_allocator),
                .validate => |*validate| validate.sealed.deinit(releases, storage_allocator),
                .publish => |*publish| {
                    publish.cursor.deinit(releases, storage_allocator);
                    publish.sealed.deinit(releases, storage_allocator);
                },
            }
            self.* = undefined;
        }
    };

    pub fn advance(evaluator: *Machine, self: *ModuleCompletionDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.state.borrowMut().*) {
            .capture => |*capture| {
                if (capture.remaining != 0) {
                    capture.remaining -= 1;
                    capture.image.borrow().placeTemplate(
                        capture.remaining,
                        evaluator.unit.takeStackOwned().?,
                    );
                    continue;
                }
                const completion = capture.completion;
                var sealed = heap.Owned(modules.SealedImage).init(capture.image.borrowMut().seal());
                capture.image.deinit(evaluator.releaseDomain(), evaluator.allocator());
                switch (completion) {
                    .value => self.state.borrowMut().* = .{ .value = .init(sealed.take()) },
                    .named => |validation| self.state.borrowMut().* = .{ .validate = .{
                        .sealed = .init(sealed.take()),
                        .cursor = validation.cursor,
                        .provenance = validation.provenance,
                    } },
                }
            },
            .value => |*sealed| {
                const item = try sealed.borrowMut().intoValue(evaluator.unit.allocator);
                sealed.deinit(evaluator.releaseDomain(), evaluator.allocator());
                return .{ .output = item };
            },
            .validate => |*validate| switch (validate.cursor.advance()) {
                .pending => {},
                .complete => |maybe_name| {
                    const name = maybe_name orelse return evaluator.fail(
                        .domain,
                        "@defm requires a valid module name",
                    );
                    switch (validate.provenance) {
                        .package => |package| if (!evaluator.unit.inherited.project_lock.?.packageDeclares(
                            package,
                            name,
                        )) return evaluator.fail(
                            .domain,
                            "package source may register only modules declared by its catalog",
                        ),
                        .ordinary, .root_package, .standard_library => {},
                    }
                    const provenance: modules.RegistrationProvenance = switch (validate.provenance) {
                        .root_package => .ordinary,
                        else => validate.provenance,
                    };
                    const registration = evaluator.unit.inherited.registry.?.registrationCursor(
                        validate.sealed.borrow().ref(),
                        name,
                        provenance,
                        &evaluator.unit.turn_authority,
                    );
                    self.state.borrowMut().* = .{ .publish = .{
                        .sealed = .init(validate.sealed.take()),
                        .cursor = .init(registration),
                    } };
                },
            },
            .publish => |*publish| return advanceRegistration(evaluator, publish.cursor.borrowMut()),
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
    std.debug.assert(!self.unit.hasWorkDriver() and self.unit.hasPendingFailure());
    const capacity = std.math.add(usize, self.unit.frames.items.len, 3) catch
        return error.OutOfMemory;
    const trace = try self.unit.allocator.alloc(intern.TraceWord, capacity);
    errdefer self.unit.allocator.free(trace);
    const resolved = try self.unit.allocator.alloc(u32, capacity);
    errdefer self.unit.allocator.free(resolved);
    const driver = try self.unit.allocator.create(FailureDriver);
    driver.* = .{
        .allocator = self.unit.allocator,
        .failure = self.unit.takePendingForUnwind(),
        .trace = trace,
        .resolved = resolved,
        .state = .{ .trace = self.unit.frames.items.len },
    };
    driver.appendInitial(self);
    self.adoptDriver(driver);
}

const FailureDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    const UnwindTarget = union(enum) {
        uncaught: struct { stack_base: usize },
        caught: struct {
            boundary_index: FrameIndex,
            stack_base: usize,
            locals_base: usize,
            previous_base: usize,
            previous_boundary: ?FrameIndex,
        },

        fn frameTarget(self: UnwindTarget) usize {
            return switch (self) {
                .uncaught => 0,
                .caught => |caught| @as(usize, @intFromEnum(caught.boundary_index)) + 1,
            };
        }
        fn localsTarget(self: UnwindTarget) usize {
            return switch (self) {
                .uncaught => 0,
                .caught => |caught| caught.locals_base,
            };
        }
        fn stackTarget(self: UnwindTarget) usize {
            return switch (self) {
                .uncaught => |uncaught| uncaught.stack_base,
                .caught => |caught| caught.stack_base,
            };
        }
        fn previousBase(self: UnwindTarget) usize {
            return switch (self) {
                .uncaught => 0,
                .caught => |caught| caught.previous_base,
            };
        }
        fn previousBoundary(self: UnwindTarget) ?FrameIndex {
            return switch (self) {
                .uncaught => null,
                .caught => |caught| caught.previous_boundary,
            };
        }
    };
    const Unwind = struct {
        error_value: Value,
        target: UnwindTarget,

        fn retire(self: *Unwind, releases: *heap.ReleaseDomain) void {
            releases.releaseValue(self.error_value);
        }
    };
    const State = union(enum) {
        trace: usize,
        spell: usize,
        resolve: struct { index: usize, cursor: intern.TraceWordCursor },
        locate: spans.SpanArchive.LocateCursor,
        value: ErrorValueCursor,
        nearest: struct { error_value: Value, boundary: ?FrameIndex },
        current: Unwind,
        frames: Unwind,
        boundary: Unwind,
        locals: Unwind,
        stack: Unwind,
        outcome_name: struct { error_value: Value, cursor: intern.InternInsertionCursor },
        outcome_prepare: Value,
        outcome: struct {
            error_value: Value,
            builder: dict.Materializer,
        },
        caught: Value,
        failed,

        fn deinit(self: *State, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .resolve => |*resolve| resolve.cursor.deinit(),
                .value => |*cursor| cursor.retire(releases),
                .nearest => |nearest| releases.releaseValue(nearest.error_value),
                .current, .frames, .boundary, .locals, .stack => |*unwind| unwind.retire(releases),
                .outcome_name => |outcome| releases.releaseValue(outcome.error_value),
                .outcome_prepare => |item| releases.releaseValue(item),
                .outcome => |*outcome| {
                    outcome.builder.retire(releases);
                    releases.releaseValue(outcome.error_value);
                },
                .caught => |item| releases.releaseValue(item),
                .trace, .spell, .locate, .failed => {},
            }
        }
    };

    allocator: std.mem.Allocator,
    failure: EclErr,
    /// The activation chain, innermost first. Entries are trace words rather
    /// than atoms because a module-local word's spelling depends on the
    /// registration it ran under; `resolved` holds the interned spellings.
    trace: []intern.TraceWord,
    resolved: []u32,
    trace_count: usize = 0,
    outcome_pair: [1]dict.Pair = .{dict.Pair{ .{ .int = 0 }, .{ .int = 0 } }},
    state: State,

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
        self.state.deinit(releases);
        self.failure.retire(releases);
        storage_allocator.free(self.trace);
        storage_allocator.free(self.resolved);
    }
    fn beginLocation(self: *FailureDriver, evaluator: *Machine) void {
        if (self.failure.site) |site| {
            switch (site) {
                .token => |token| {
                    self.state = .{ .locate = evaluator.unit.archive.locateCursor(token.code, token.index) };
                },
                .contract_quotation => |candidate| {
                    self.state = .{ .locate = evaluator.unit.archive.locateQuotationCursor(candidate.borrow()) };
                },
                .explicit_location => |location| {
                    self.beginValue(.{
                        .source_name = location.source_name,
                        .span = location.span,
                    });
                },
            }
        } else self.beginValue(null);
    }
    fn beginValue(self: *FailureDriver, location: ?spans.LocatedSpan) void {
        self.state = .{
            .value = .init(
                self.allocator,
                &self.failure,
                // `appendInitial` puts the failing word first when there is one,
                // so its spelling is the first resolved entry.
                .{
                    .word = if (self.failure.word != null) self.resolved[0] else null,
                    .trace = self.resolved[0..self.trace_count],
                },
                location,
            ),
        };
    }
    fn beginUnwind(self: *FailureDriver, error_value: Value, target: UnwindTarget) void {
        self.state = .{ .current = .{ .error_value = error_value, .target = target } };
    }
    pub fn advance(evaluator: *Machine, self: *FailureDriver) MachineError!WorkProgress {
        var budget: usize = kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.state) {
            .trace => |*frame_index| {
                if (frame_index.* == 0) {
                    self.state = .{ .spell = 0 };
                    continue;
                }
                frame_index.* -= 1;
                switch (evaluator.unit.frames.items[frame_index.*]) {
                    .eval => |frame| if (frame.traced_word != no_word) self.appendTrace(frame.traced_word),
                    .effect_check, .application, .qualified_after_load, .boundary => {},
                }
            },
            // Qualifying a module-local word interns its spelling. Failures
            // are rare, so this is the one place that cost is paid.
            .spell => |resolve_index| {
                if (resolve_index == self.trace_count) {
                    self.beginLocation(evaluator);
                    continue;
                }
                const cursor = try intern.TraceWordCursor.init(
                    self.allocator,
                    self.trace[resolve_index],
                );
                self.state = .{ .resolve = .{
                    .index = resolve_index,
                    .cursor = cursor,
                } };
            },
            .resolve => |*resolve| switch (try resolve.cursor.advance()) {
                .pending => {},
                .complete => |id| {
                    const index = resolve.index;
                    resolve.cursor.deinit();
                    self.resolved[index] = id;
                    self.state = .{ .spell = index + 1 };
                },
            },
            .locate => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |location| self.beginValue(location),
            },
            .value => |*cursor| switch (try cursor.advance()) {
                .pending => {},
                .complete => |item| {
                    cursor.retire(evaluator.releaseDomain());
                    self.state = .{ .nearest = .{
                        .error_value = item,
                        .boundary = evaluator.unit.boundary_index,
                    } };
                },
            },
            .nearest => |*nearest| {
                const boundary_index = nearest.boundary orelse {
                    const item = nearest.error_value;
                    self.beginUnwind(item, .{ .uncaught = .{
                        .stack_base = evaluator.unit.entry_base,
                    } });
                    continue;
                };
                const boundary = evaluator.unit.frames.items[@intFromEnum(boundary_index)].boundary;
                if (boundary.mode == .attempt) {
                    const item = nearest.error_value;
                    self.beginUnwind(item, .{ .caught = .{
                        .boundary_index = boundary_index,
                        .stack_base = boundary.stack_base,
                        .locals_base = boundary.locals_base,
                        .previous_base = boundary.previous_base,
                        .previous_boundary = boundary.previous_boundary,
                    } });
                } else nearest.boundary = boundary.previous_boundary;
            },
            .current => |*unwind| {
                releaseCurrent(evaluator);
                const next = unwind.*;
                self.state = .{ .frames = next };
            },
            .frames => |*unwind| {
                if (evaluator.unit.frames.items.len != unwind.target.frameTarget()) {
                    evaluator.unit.deinitPoppedFrame(evaluator.unit.frames.pop().?);
                } else {
                    const next = unwind.*;
                    self.state = .{ .boundary = next };
                }
            },
            .boundary => |*unwind| {
                if (unwind.target == .caught) {
                    evaluator.unit.deinitPoppedFrame(evaluator.unit.frames.pop().?);
                }
                const next = unwind.*;
                self.state = .{ .locals = next };
            },
            .locals => |*unwind| {
                const target = @min(unwind.target.localsTarget(), evaluator.unit.locals.items.len);
                if (evaluator.unit.locals.items.len != target) {
                    const item = evaluator.unit.locals.pop().?;
                    evaluator.releaseDomain().releaseValue(item);
                    continue;
                }
                const next = unwind.*;
                self.state = .{ .stack = next };
            },
            .stack => |*unwind| {
                const target = @min(unwind.target.stackTarget(), evaluator.unit.stack.items.len);
                if (evaluator.unit.stack.items.len != target) {
                    const item = evaluator.unit.stack.pop().?;
                    evaluator.releaseDomain().releaseValue(item);
                    continue;
                }
                evaluator.unit.stack_base = unwind.target.previousBase();
                evaluator.unit.boundary_index = unwind.target.previousBoundary();
                const error_value = unwind.error_value;
                switch (unwind.target) {
                    .uncaught => {
                        evaluator.unit.finishUnwindFailed(error_value);
                        self.state = .failed;
                    },
                    .caught => {
                        self.state = .{ .outcome_name = .{
                            .error_value = error_value,
                            .cursor = intern.insertionCursor("err"),
                        } };
                    },
                }
            },
            .outcome_name => |*outcome| switch (try outcome.cursor.advance()) {
                .pending => {},
                .complete => |key| {
                    const error_value = outcome.error_value;
                    self.outcome_pair[0] = .{ .{ .symbol = key }, error_value };
                    self.state = .{ .outcome_prepare = error_value };
                },
            },
            .outcome_prepare => |error_value| {
                const builder = try dict.Materializer.init(
                    self.allocator,
                    &self.outcome_pair,
                    false,
                );
                self.state = .{ .outcome = .{
                    .error_value = error_value,
                    .builder = builder,
                } };
            },
            .outcome => |*outcome_state| switch (try outcome_state.builder.advance(1)) {
                .pending => {},
                .duplicate_key => unreachable,
                .complete => |outcome| {
                    const error_value = outcome_state.error_value;
                    outcome_state.builder.deinit();
                    self.state = .{ .caught = error_value };
                    evaluator.unit.finishUnwindCaught();
                    return .{ .output = outcome };
                },
            },
            .caught => unreachable,
            .failed => return .failed,
        };
        return .yielded;
    }
};
fn releaseCurrent(self: *Machine) void {
    if (self.unit.current) |current| self.releaseDomain().releaseHeader(current.code);
    self.unit.current = null;
}
