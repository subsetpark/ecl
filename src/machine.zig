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
const turn_core = @import("turn_core.zig");
const stdlib = @import("stdlib.zig");
const kernel_storage = @import("kernel_storage.zig");
const console_api = @import("console.zig");
const standard_streams = @import("standard_streams.zig");
const map_state = @import("module_snapshot.zig");
const external = @import("external.zig");
const scheduler_api = @import("scheduler.zig");
const idioms = @import("idioms.zig");
const binder = @import("binder.zig");
const reflection = @import("reflection.zig");
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
pub const ErrorSite = struct {
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
pub const UnitConstructor = enum { spawn, @"test" };

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
    operation,
    root,
    reason,
    @"source-root",
    @"source-path",
    @"destination-root",
    @"destination-path",
    address,
    port,
};
const ErrorData = struct {
    key: union(enum) { builtin: ErrorDataKey, symbol: u32 },
    value: Value,
};
const empty_error_data = ErrorData{ .key = .{ .builtin = .needed }, .value = .{ .int = 0 } };
/// Provenance attached to one filesystem failure. Values are borrowed; the
/// pending failure retains what it records.
pub const FilesystemErrorData = struct {
    operation: Value,
    reason: Value,
    target: union(enum) {
        single: struct { root: Value, path: Value },
        transfer: struct {
            source_root: Value,
            source_path: Value,
            destination_root: Value,
            destination_path: Value,
        },
    },
};
/// Zig errors carry no payload. The unit owns this allocation-free payload
/// until an unwind materializes the language dict.
pub const EclErr = struct {
    kind: ErrorKind,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    word: ?intern.TraceWord = null,
    trace_parent: ?intern.TraceWord = null,
    site: ?FailureSite = null,
    data: [6]ErrorData = @splat(empty_error_data),
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
        self.data[self.data_len] = .{ .key = .{ .builtin = key }, .value = item };
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
    pub fn advance(self: *OrdinaryErrorCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
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
                    trace.items[trace.index] = .{ .symbol = .{ .name = self.resolved.trace[trace.index] } };
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
    pub fn advance(self: *RaisedErrorCursor, work: *poll_api.WorkBudget) error{OutOfMemory}!ErrorValueProgress {
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
                    trace.items[trace.index] = .{ .symbol = .{ .name = self.resolved.trace[trace.index] } };
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
pub fn errorValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    failure: *EclErr,
    resolved: ResolvedTrace,
    location: ?spans.LocatedSpan,
) error{OutOfMemory}!Value {
    var cursor = ErrorValueCursor.init(allocator, failure, resolved, location);
    defer cursor.retire(releases);
    var work = poll_api.unbounded();
    return poll_api.driveFallible(Value, &cursor, .{&work});
}
pub fn stringValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    bytes: []const u8,
) error{OutOfMemory}!Value {
    var materializer = kernel_storage.TextMaterializer.init(allocator, bytes);
    defer materializer.retire(releases);
    var work = poll_api.unbounded();
    return poll_api.driveFallible(Value, &materializer, .{&work});
}
/// How an evaluation's words reach their targets.
const Program = union(enum) {
    /// Top-level source: each word is resolved when it is reached, so a
    /// definition made by one form is visible to the next. The evaluation
    /// owns one reference to its code.
    incremental,
    /// A quotation application whose binding has not run yet. Nothing in it
    /// executes until every top-level word is bound. The evaluation owns one
    /// reference to its code.
    unbound,
    /// A sealed executable. Its code is borrowed from the executable, which
    /// the evaluation keeps alive by holding the executable's owner.
    bound: *const env.Executable,
    /// A sealed executable the enclosing application frame owns for its
    /// whole invocation. The frame sits beneath this evaluation and outlives
    /// it, so the evaluation borrows the executable and its code.
    borrowed: *const env.Executable,

    fn executable(self: Program) ?*const env.Executable {
        return switch (self) {
            .bound, .borrowed => |sealed| sealed,
            .incremental, .unbound => null,
        };
    }
};

const Eval = struct {
    code: *Header,
    program: Program,
    position: union(enum) {
        source: u32,
        // Carries the call site's next source index, but dispatches no caller
        // forms. Its completion frame must run before the caller can resume.
        invocation: u32,
        // Loader retry dispatches just the restored invocation, not the rest
        // of its caller's quotation.
        replay: u32,
        // The replayed word is being resolved. Its existing completion frame
        // is reused when dispatch reaches that invocation again.
        redispatch: u32,
    },

    /// Where this body's definitions land, where its references resolve, and
    /// whose privacy it runs under. One value rather than
    /// three fields, so a construction site cannot set two of them and leave
    /// the third describing different code.
    site: ExecutionSite,
    traced_word: intern.TraceWord,
    /// The word whose body this is, set only when dispatch entered that body.
    /// `traced_word` cannot answer this: a tail position clears it, and an
    /// application may borrow a word for attribution. A locals binder opening
    /// the body is that word's arity check, so its failure is the word's.
    body_owner: intern.TraceWord = no_word,
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

    /// Releases what this evaluation owns.
    inline fn release(self: Eval, releases: *heap.ReleaseDomain) void {
        switch (self.program) {
            .incremental, .unbound => releases.releaseHeader(self.code),
            .bound => |executable| executable.owner.release(releases),
            .borrowed => {},
        }
    }

    /// Takes one more reference for a copy of this evaluation.
    fn retainCopy(self: Eval) void {
        switch (self.program) {
            .incremental, .unbound => heap.incRef(self.code),
            .bound => |executable| executable.owner.retain(),
            .borrowed => {},
        }
    }

    /// Moves this evaluation's ownership into one code reference, for a
    /// holder that keeps only the quotation.
    fn intoCode(self: Eval, releases: *heap.ReleaseDomain) *Header {
        switch (self.program) {
            .incremental, .unbound => return self.code,
            .bound => |executable| {
                heap.incRef(self.code);
                executable.owner.release(releases);
                return self.code;
            },
            .borrowed => {
                heap.incRef(self.code);
                return self.code;
            },
        }
    }

    fn nextIndex(self: Eval) u32 {
        return switch (self.position) {
            .source, .invocation, .replay, .redispatch => |index| index,
        };
    }
    fn hasInstructions(self: Eval) bool {
        return switch (self.position) {
            .source, .replay => |index| index < self.code.length(),
            .invocation, .redispatch => false,
        };
    }
    /// The index of the next form to dispatch, moving past it, or null when
    /// none remains: one test of the position where checking and advancing
    /// tested it twice.
    fn takeInstruction(self: *Eval) ?u32 {
        switch (self.position) {
            .source => |index| {
                if (index >= self.code.length()) return null;
                self.position = .{ .source = index + 1 };
                return index;
            },
            .replay => |index| {
                if (index >= self.code.length()) return null;
                self.position = .{ .redispatch = index + 1 };
                return index;
            },
            .invocation, .redispatch => return null,
        }
    }
    fn rewind(self: *Eval, index: u32) void {
        self.position = switch (self.position) {
            .source => .{ .source = index },
            .invocation, .replay, .redispatch => .{ .replay = index },
        };
    }

    /// Where this body's own definitions land, and the chain it hands to any
    /// quotation it invokes on a caller's behalf.
    pub fn scope(self: Eval) *env.Scope {
        return self.site.scope;
    }
    /// Whose privacy this body runs under.
    pub fn home(self: Eval) ?*modules.ModuleHome {
        return self.site.home;
    }
};
/// A module construction boundary. The body builds the image `@defm` named
/// before it ran; completion seals and publishes that image.
const ModuleBoundary = struct {
    image: modules.OwnedImage,
    /// Exact construction body admitted by `@defm`. A declaration
    /// is module-level only while this is the current activation; quotations
    /// called by the body may inherit its home but not its declaration site.
    root_code: *Header,

    fn deinit(self: ModuleBoundary) void {
        var owned = self.image;
        owned.deinit();
    }
};
const BoundaryMode = union(enum) {
    attempt,
    module: ModuleBoundary,
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
    fn deinit(self: Boundary) void {
        switch (self.mode) {
            .module => |boundary| boundary.deinit(),
            .attempt => {},
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
    invocation: ErrorSite,
};
const EffectCheck = struct {
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
            .none, .invocation => unreachable,
            .source => self.provenance.source.candidate.replaceBorrowed(releases, code),
        }
    }
    fn restoreActive(self: *const EffectCheck, unit: *Unit) void {
        switch (self.provenance) {
            .none, .invocation => {},
            .source => |source| {
                std.debug.assert(unit.effect_check_index == source.frame_index);
                unit.effect_check_index = source.previous;
            },
        }
    }
    fn takeCandidate(self: *EffectCheck) ?OwnedCode {
        return switch (self.provenance) {
            .none, .invocation => null,
            .source => .initOwned(self.provenance.source.candidate.take()),
        };
    }
    pub fn deinit(self: *EffectCheck, releases: *heap.ReleaseDomain) void {
        switch (self.provenance) {
            .none, .invocation => {},
            .source => self.provenance.source.candidate.deinit(releases),
        }
        self.provenance = .none;
    }
};
pub const StackWindow = enum(u32) {
    _,

    fn init(depth: usize, seeded: u32) ?StackWindow {
        if (depth < seeded) return null;
        return @fromBackingInt(@intCast(@as(u32, @intCast(depth - seeded))));
    }
    pub fn base(self: StackWindow) u32 {
        return @backingInt(self);
    }
    pub fn observed(self: StackWindow, depth: usize) ?usize {
        const start: usize = self.base();
        if (depth < start) return null;
        return depth - start;
    }
};
pub const ApplicationStep = union(enum) {
    apply: struct {
        quotation: *Header,
        seeded: u32,
        provenance: ApplicationProvenance = .boundary,
    },
    /// The callback installed bounded work which will launch a nested inline
    /// application. Reinsert this exact application continuation beneath that
    /// work so the child returns to it instead of replacing it.
    suspend_inline: *const ApplicationSuspension,
};
pub const ApplicationSuspension = opaque {};
/// Opaque, non-dereferenced capability for one live application frame. The
/// Unit encodes a process-unique nonce with the frame index and validates
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
        } else return @fromBackingInt(@intCast(@as(u32, @intCast(next))));
    }
    return error.OutOfMemory;
}

fn encodeApplicationProvenanceTarget(
    index: ApplicationFrameIndex,
    nonce: ApplicationProvenanceNonce,
) *const ApplicationProvenanceTarget {
    comptime if (@sizeOf(usize) != 8)
        @compileError("application provenance capabilities require a 64-bit target");
    const raw = (@as(usize, @backingInt(nonce)) << 32) |
        @as(usize, @backingInt(index));
    std.debug.assert(raw != 0);
    return @ptrFromInt(raw);
}

pub const ExecutionSite = struct {
    /// Where this body's own definitions land, and the chain it hands to any
    /// quotation it invokes on a caller's behalf.
    scope: *env.Scope,
    /// Whose privacy this body runs under. Correlated with the scope but not
    /// derivable from it: a homeless word called from module code inherits the
    /// caller's home. Where a word resolves is carried by the word itself.
    home: ?*modules.ModuleHome,
    /// Authority carried only while evaluating an embedded source module.
    /// A named module constructed by that source moves it into the immutable
    /// registration; ordinary source always carries ordinary provenance.
    registration_provenance: modules.RegistrationProvenance = .ordinary,
    /// Whether definitions may land in `scope`. True at root level: top-level
    /// code, a module construction body, and anything they call inline.
    /// Combinator applications, `@attempt` bodies, and tasks clear it, and
    /// everything they call inherits that, so a helper that defines works at
    /// top level and is refused inside an `each`.
    defining: bool,

    /// The base case: a unit's root activation, built from nothing.
    pub fn root(unit: *Unit) ExecutionSite {
        if (unit.root_execution_home) |home| return image(home, unit.module_access, unit.root_defining);
        const scope = unit.lexicalScope();
        return .{
            .scope = scope,
            .home = null,
            .defining = unit.root_defining,
            .registration_provenance = if (unit.inherited.module_snapshot) |module_snapshot|
                .{ .root_scope = module_snapshot.localScope() }
            else
                .ordinary,
        };
    }

    /// Code running as one module image: the image's own definitions, then
    /// core.
    pub fn image(
        home: *modules.ModuleHome,
        access: *const modules.ExecutionAccess,
        defining: bool,
    ) ExecutionSite {
        const scope = home.scope(access);
        return .{
            .scope = scope,
            .home = home,
            .defining = defining,
            .registration_provenance = home.registrationProvenance(),
        };
    }

    /// A nested activation continuing the same logical execution in `scope`:
    /// a dynamic `call`, an `@attempt` body, or a resumed qualified load.
    /// A quotation resolves where its invoker runs, so both scopes are the one
    /// it was handed. An applied quotation may have come from any caller, so
    /// it does not inherit embedded registration trust; a resumed load sets
    /// the provenance it registers under itself.
    pub fn inheriting(invoker: Eval, scope: *env.Scope) ExecutionSite {
        return resumed(scope, invoker.home(), invoker.site.registration_provenance.applied(), invoker.site.defining);
    }

    /// An application resuming in `scope` under its launch home. The only
    /// construction where the home does not come from a running activation,
    /// because an application's scope is decided when it launches.
    pub fn resumed(
        scope: *env.Scope,
        home: ?*modules.ModuleHome,
        registration_provenance: modules.RegistrationProvenance,
        defining: bool,
    ) ExecutionSite {
        return .{
            .scope = scope,
            .home = home,
            .registration_provenance = registration_provenance,
            .defining = defining,
        };
    }
};

pub const ApplicationProvenance = union(enum) {
    boundary,
    selected_target: *const ApplicationProvenanceTarget,
};
pub const ApplicationSite = struct {
    parent_scope: *env.Scope,
    home: ?*modules.ModuleHome,
    registration_provenance: modules.RegistrationProvenance,
    /// The launching activation's `defining`. An isolated launch clears it
    /// for the body regardless; an inline one passes it through.
    defining: bool,
};
pub const IsolatedApplication = struct {
    quotation: *Header,
    context: *anyopaque,
    resume_fn: *const fn (*Unit, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ApplicationSite,
    seeded: u32,
    provenance: ApplicationProvenance,
    /// Where a finite iteration keeps what its call has decided for its
    /// quotation's words.
    plan: ?*ResolutionPlan = null,
    /// The executables this invocation has bound so far, carried from one
    /// application to the next.
    bound: ApplicationReuse = .{},

    /// Releases an application that never became a frame.
    fn discard(self: IsolatedApplication, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        var bound = self.bound;
        bound.deinit(releases);
        self.deinit_fn(releases, allocator, self.context);
    }
};

/// The executables one combinator invocation bound for the quotations it
/// applies, so each later application reuses them instead of binding again.
/// A predicate and a body are separate quotations with separate bindings, so
/// two slots cover every combinator. The invocation owns what it holds, so no
/// cache eviction can disturb its remaining applications.
const ApplicationReuse = struct {
    slots: [2]?*env.AnonymousCode = .{ null, null },

    fn find(self: *const ApplicationReuse, code: *Header) ?*env.AnonymousCode {
        for (self.slots) |slot| if (slot) |held| if (held.executable.code == code) return held;
        return null;
    }

    fn remember(self: *ApplicationReuse, code: *env.AnonymousCode) void {
        for (&self.slots) |*slot| if (slot.* == null) {
            code.retain();
            slot.* = code;
            return;
        };
    }

    fn deinit(self: *ApplicationReuse, releases: *heap.ReleaseDomain) void {
        for (&self.slots) |*slot| if (slot.*) |held| {
            held.release(releases);
            slot.* = null;
        };
    }
};

/// The unit's bounded cache of explicit lookups: what a symbol resolved to,
/// valid only in the publication and under the provenance it was resolved in.
/// An entry holds a counted definition; static ones outlive the Session's
/// units. Consulted only by explicit lookup, never by bound dispatch.
const LookupReuse = struct {
    const capacity = 16;
    const Entry = struct {
        word: value.Symbol,
        publication: u64,
        provenance: u64,
        definition: *env.Definition,
    };
    entries: [capacity]?Entry = @splat(null),

    fn index(word: value.Symbol) usize {
        return @intCast((@as(u64, word.name) *% 0x9E3779B97F4A7C15 ^ word.slot) % capacity);
    }

    fn find(self: *const LookupReuse, word: value.Symbol, publication: u64, provenance: modules.RegistrationProvenance) ?*env.Definition {
        const entry = self.entries[index(word)] orelse return null;
        if (entry.word.name != word.name or entry.word.slot != word.slot or entry.publication != publication or
            entry.provenance != BindingReuse.provenanceKey(provenance)) return null;
        return entry.definition;
    }

    fn remember(
        self: *LookupReuse,
        releases: *heap.ReleaseDomain,
        word: value.Symbol,
        publication: u64,
        provenance: modules.RegistrationProvenance,
        definition: *env.Definition,
    ) void {
        const slot = &self.entries[index(word)];
        if (slot.*) |old| if (old.definition.lifetime == .counted) old.definition.release(releases);
        if (definition.lifetime == .counted) definition.retain();
        slot.* = .{ .word = word, .publication = publication, .provenance = BindingReuse.provenanceKey(provenance), .definition = definition };
    }

    fn deinit(self: *LookupReuse, releases: *heap.ReleaseDomain) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            if (entry.definition.lifetime == .counted) entry.definition.release(releases);
            slot.* = null;
        };
    }
};

/// The unit's bounded cache of anonymous bindings. An entry owns its executable
/// and, through it, its exact source quotation, so a pointer key cannot be
/// reused by another quotation while the entry lives. It is consulted only
/// where an application begins binding, and is valid only in the publication
/// and under the provenance it was bound in: any publication anywhere
/// conservatively invalidates it.
const BindingReuse = struct {
    const capacity = 16;
    const Entry = struct {
        code: *env.AnonymousCode,
        publication: u64,
        provenance: u64,
    };
    entries: [capacity]?Entry = @splat(null),

    fn index(code: *Header) usize {
        return (@intFromPtr(code) >> 4) % capacity;
    }

    fn provenanceKey(provenance: modules.RegistrationProvenance) u64 {
        return switch (provenance) {
            .ordinary => 0,
            .standard_library => 1,
            .root_scope => |scope| 2 | (@as(u64, @backingInt(scope)) << 2),
            .source => |source| @intFromPtr(source),
        };
    }

    fn find(
        self: *const BindingReuse,
        code: *Header,
        publication: u64,
        provenance: modules.RegistrationProvenance,
    ) ?*env.AnonymousCode {
        const entry = self.entries[index(code)] orelse return null;
        if (entry.code.executable.code != code or entry.publication != publication or
            entry.provenance != provenanceKey(provenance)) return null;
        entry.code.retain();
        return entry.code;
    }

    fn remember(
        self: *BindingReuse,
        releases: *heap.ReleaseDomain,
        code: *env.AnonymousCode,
        publication: u64,
        provenance: modules.RegistrationProvenance,
    ) void {
        const slot = &self.entries[index(code.executable.code)];
        if (slot.*) |old| old.code.release(releases);
        code.retain();
        slot.* = .{ .code = code, .publication = publication, .provenance = provenanceKey(provenance) };
    }

    fn deinit(self: *BindingReuse, releases: *heap.ReleaseDomain) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            entry.code.release(releases);
            slot.* = null;
        };
    }
};

fn ApplicationAdapters(comptime Driver: type) type {
    return struct {
        fn run(
            evaluator: *Unit,
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
    site: ApplicationSite,
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
        .site = site,
        .seeded = seeded,
        .provenance = .boundary,
    };
}
const ApplicationMode = union(enum) {
    in_place: StackWindow,
    isolated: struct {
        previous_base: StackWindow,
    },
};
const ApplicationFrame = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Unit, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ApplicationSite,
    mode: ApplicationMode,
    traced_word: intern.TraceWord,
    selection: ApplicationSelection,
    provenance_nonce: ?ApplicationProvenanceNonce = null,
    /// Borrowed from the combinator state `context` names.
    plan: ?*ResolutionPlan = null,
    /// Owned: what this invocation has bound for its quotations.
    bound: ApplicationReuse = .{},
    fn deinit(self: ApplicationFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        var selection = self.selection;
        selection.deinit(releases);
        var bound = self.bound;
        bound.deinit(releases);
        switch (self.mode) {
            .in_place, .isolated => {},
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
    /// Dispatch the exact word again by explicit lookup.
    dispatch: struct {
        word: value.Symbol,
        site: ?ErrorSite,
        trace_parent: ?intern.TraceWord,
    },
    /// Bind the restored evaluation again, against a view that now holds the
    /// loaded module. Nothing in it has executed.
    rebind,
    load_only,
};
const QualifiedLoadRequest = struct {
    context: modules.RegistrationProvenance,
    qualified: u32,
    continuation: QualifiedLoadContinuation,
};
const SourceLoadRequest = union(enum) {
    module: struct { name: intern.ModuleName, operation: QualifiedLoadRequest },
    source,

    fn preservesCaller(self: SourceLoadRequest) bool {
        return switch (self) {
            .module => |module| switch (module.operation.continuation) {
                .replay, .dispatch, .rebind => true,
                .load_only => false,
            },
            .source => false,
        };
    }
};
const ArtifactLoad = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    fn init(maybe_artifact: ?map_state.ArtifactId) ArtifactLoad {
        return if (maybe_artifact) |id| @fromBackingInt(@intCast(@backingInt(id))) else .none;
    }
    fn artifact(self: ArtifactLoad) ?map_state.ArtifactId {
        return if (self == .none) null else @fromBackingInt(@intCast(@backingInt(self)));
    }
};
pub const Frame = union(enum(u8)) {
    eval: Eval,
    effect_check: EffectCheck,
    application: ApplicationFrame,
    qualified_after_load: struct {
        loading: modules.LoadingLease,
        path: Value,
        request: SourceLoadRequest,
        artifact: ArtifactLoad,
    },
    boundary: Boundary,
    fn deinit(self: Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self) {
            .eval => |frame| frame.release(releases),
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
            .boundary => |boundary| boundary.deinit(),
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
    // on correlated Unit fields. Application frames likewise own the lexical scope
    // provenance every sibling resumption must preserve.
    // File-owned execution provenance carries a Session-scoped source capability.
    if (@sizeOf(Frame) > 144) @compileError("machine frames must remain at most 144 bytes");
}
/// A user quotation offered to a combinator, recognized where it is applied.
pub const IdiomRequest = enum { each, zip_with, fold, fold1, scan, lex_cmp };
/// A call of a trusted source word whose body was recognized when its
/// environment froze. Only whether this call's operands admit the entry is left.
pub const TrustedCall = struct {
    body: *Header,
    idiom: env.DirectIdiom,
};

/// What a trusted call's recognition decided. `declined` runs the body as any
/// source word runs; `offered` stands for a combinator, whose quotation is
/// offered with the body as its fallback.
pub const TrustedOutcome = union(enum) { applied, declined, offered: IdiomRequest };
pub const IdiomFallback = struct {
    /// What to do if recognition declines, carried by value. Recognition holds
    /// at most one fallback at a time and the only one with any state is a core
    /// word's body and trace word, so describing the decline costs no
    /// allocation. Storing it inline also removes the question a pointer
    /// raised: with every payload here, teardown always retires fields and
    /// never frees storage.
    pub const storage_len = 96;
    storage: [storage_len]u8 align(@alignOf(usize)) = @splat(0),
    run_fn: *const fn (*Unit, ?*anyopaque) MachineError!void,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, ?*anyopaque) void,
    pub fn run(self: *IdiomFallback, evaluator: *Unit) MachineError!void {
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
    registry: *modules.Registry,
    test_observation: ?*const modules.TestObservationAccess = null,
    test_execution: ?*const modules.TestExecutionAccess = null,
    native_diagnostics: bool = false,
    tls_trust: ?TlsTrust = null,
    ecl_path: ?[]const u8 = null,
    module_snapshot: ?*const map_state.Snapshot = null,
    idiom_mode: IdiomMode = .automatic,
    phase: union(enum) { bootstrap, runtime: RuntimeContext },

    pub fn console(self: *const InheritedContext) ?*console_api.Console {
        return switch (self.phase) {
            .bootstrap => null,
            .runtime => |context| context.console,
        };
    }

    fn libraries(self: *const InheritedContext) EmbeddedLibraries {
        return switch (self.phase) {
            .bootstrap => .bundled,
            .runtime => |context| .{ .registered = context.native_loader },
        };
    }
    pub fn runtime(self: *const InheritedContext) *const RuntimeContext {
        return switch (self.phase) {
            .runtime => |*context| context,
            .bootstrap => @panic("runtime service requested during prelude construction"),
        };
    }
};

/// Complete runtime services, borrowed from the Session that encloses every
/// Unit and descendant. Bootstrap evaluation has no runtime services.
pub const RuntimeContext = struct {
    native_loader: *native_module.Loader,
    console: *console_api.Console,
    host_io: std.Io,
    startup_cwd: []const u8,
    filesystem_access: *external.FilesystemAccess,
    http_access: *@import("http_service.zig").Access,
    wall_clock: WallClock,
    environ: Environ,
    standard_streams: *standard_streams.Devices,
};

/// Wall time is always available at runtime. Overrides are deterministic
/// testing inputs, independent of permissions. Values are Unix milliseconds.
pub const WallClock = union(enum) {
    host: std.Io,
    fixed: i64,
    anchored: i64,
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
pub const Environ = @import("startup_environment.zig").View;

/// Where standard input stands at session start: data a program may read
/// through `fd.in`, or the program source itself, which `fd.in` refuses.
pub const StandardInput = struct {
    pub const Availability = standard_streams.Availability;
};

fn IdiomFallbackAdapters(comptime Payload: type) type {
    return struct {
        fn run(evaluator: *Unit, raw: ?*anyopaque) MachineError!void {
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
/// What to do if recognition declines, made only when something needs it: to
/// decline, or to carry into a match that must wait. An applied match never
/// makes one. `context` is borrowed for the synchronous call that receives the
/// source, so the recognizer makes the fallback before it returns or not at all.
pub const FallbackSource = struct {
    context: ?*const anyopaque = null,
    make_fn: *const fn (?*const anyopaque, *Unit) IdiomFallback,

    pub fn make(self: FallbackSource, evaluator: *Unit) IdiomFallback {
        return self.make_fn(self.context, evaluator);
    }
};

pub const ParkRequest = union(enum) {
    task: Value,
    any: Value,
    deadline: struct { task: Value, milliseconds: u63 },
    /// Park for a number of milliseconds with nothing to wait for but the
    /// clock. Shares the deadline wait's timer registration and arbitration
    /// and resumes through the `sleep` family, never a task result.
    sleep: u63,
    close_scope: u8,
    external: external.ReadinessSource,
    external_until: struct { source: external.ReadinessSource, deadline: scheduler_api.Deadline },
    /// Park on a task mailbox, for a message or for space to queue one. A
    /// deadline resumes the driver exactly as readiness does, so a timed
    /// receive hands back a value instead of raising.
    mailbox: struct { source: external.ReadinessSource, deadline: ?scheduler_api.Deadline },

    /// The one value graph owned by every parking request that carries one.
    /// Scheduler setup, abandonment, and ordinary deinit all use this mapping.
    pub fn ownedValue(self: ParkRequest) ?Value {
        return switch (self) {
            .task, .any => |item| item,
            .deadline => |deadline| deadline.task,
            .close_scope, .external, .external_until, .mailbox, .sleep => null,
        };
    }

    pub fn taskCount(self: ParkRequest) usize {
        return switch (self) {
            .task, .deadline => 1,
            .any => |tasks| @intCast(tasks.list.length()),
            .close_scope, .external, .external_until, .mailbox, .sleep => 0,
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
            .close_scope, .external, .external_until, .mailbox, .sleep => unreachable,
        };
    }

    pub fn deinit(self: ParkRequest, releases: *heap.ReleaseDomain) void {
        if (self.ownedValue()) |item| releases.releaseValue(item);
        switch (self) {
            .external_until => |timed| {
                var owned = timed.source;
                owned.deinit();
            },
            .external => |source| {
                var owned = source;
                owned.deinit();
            },
            .mailbox => |waiting| {
                var owned = waiting.source;
                owned.deinit();
            },
            else => {},
        }
    }
};

/// How a wait on one or more tasks ended.
pub const TaskWaitResume = union(enum) {
    outcome: Value,
    indexed: struct { index: u32, outcome: Value },
    timeout,
    cancelled,
    io,
    /// The deadline lay beyond any instant the scheduler clock can report.
    overflow,
    out_of_memory,

    fn ownedValue(self: TaskWaitResume) ?Value {
        return switch (self) {
            .outcome => |outcome| outcome,
            .indexed => |indexed| indexed.outcome,
            .timeout, .cancelled, .io, .overflow, .out_of_memory => null,
        };
    }
};

/// How a `clock.sleep` ended. Nothing is ever pushed.
pub const SleepResume = enum { elapsed, cancelled, io, overflow, out_of_memory };

/// How a wait on host readiness ended.
pub const ExternalResume = union(enum) {
    timeout,
    /// The source reported readiness or its own failure; the driver polls.
    wake: external.Wake,
    cancelled,
    io,
    out_of_memory,
};

/// How a wait on a task mailbox ended. Readiness and the deadline both
/// resume the driver, which polls the mailbox and reads the clock itself.
pub const MailboxResume = enum { ready, cancelled, io, out_of_memory };

/// One family per park request, so a sleep cannot deliver a task outcome, a
/// task wait cannot report that it slept, and each family's failure wording
/// describes what the unit was actually doing.
pub const ParkResume = union(enum) {
    task_wait: TaskWaitResume,
    sleep: SleepResume,
    external: ExternalResume,
    mailbox: MailboxResume,
    scope_closed: u8,

    pub fn ownedValue(self: ParkResume) ?Value {
        return switch (self) {
            .task_wait => |wait| wait.ownedValue(),
            .sleep, .external, .mailbox, .scope_closed => null,
        };
    }

    /// The failure a request receives when no wait service could start.
    pub fn serviceUnavailable(request: ParkRequest) ParkResume {
        return switch (request) {
            .sleep => .{ .sleep = .io },
            .external, .external_until => .{ .external = .io },
            .mailbox => .{ .mailbox = .io },
            .task, .any, .deadline => .{ .task_wait = .io },
            .close_scope => unreachable,
        };
    }

    /// The failure a request receives when its unit was cancelled before the
    /// wait registered.
    pub fn cancelledFor(request: ParkRequest) ParkResume {
        return switch (request) {
            .sleep => .{ .sleep = .cancelled },
            .external, .external_until => .{ .external = .cancelled },
            .mailbox => .{ .mailbox = .cancelled },
            .task, .any, .deadline => .{ .task_wait = .cancelled },
            .close_scope => unreachable,
        };
    }

    fn deinit(self: ParkResume, releases: *heap.ReleaseDomain) void {
        if (self.ownedValue()) |item| releases.releaseValue(item);
    }
};

/// A driver transfers an owned result through this completion state. The
/// evaluator destroys the driver before committing that value to the stack,
/// so stack-growth failure always has exactly one resumable owner.
///
/// `stepped` and `yielded` separate progress from surrender, and a yield names
/// why the driver ends its turn; `turn_core` decides what the evaluator does
/// with either.
pub const WorkProgress = union(enum) {
    completed,
    output: Value,
    reserved_output: struct { reservation: StackReservation, value: Value },
    stepped,
    yielded: turn_core.Yield,
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

    /// Moves one already-reserved output through the evaluator's driver
    /// completion boundary. No allocation can follow a consuming result claim.
    pub fn output(self: StackReservation, item: Value) WorkProgress {
        std.debug.assert(self.remaining == 1);
        return .{ .reserved_output = .{ .reservation = self, .value = item } };
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

/// Type-erased owned continuation for native work that must return to the
/// scheduler between bounded slices.
pub const WorkDriver = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Unit, *anyopaque) MachineError!WorkProgress,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ?ErrorSite,
    trace_parent: ?intern.TraceWord = null,

    pub fn advance(self: WorkDriver, evaluator: *Unit) MachineError!WorkProgress {
        return self.resume_fn(evaluator, self.context);
    }

    fn deinit(self: WorkDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, self.context);
    }
};

/// The scheduler-visible native continuation owned by a unit. A work driver
/// carries its wait request or delivered result in the same variant, so the
/// evaluator cannot represent an unrelated driver and park at once.
pub const NativeContinuation = union(enum) {
    idle,
    work: WorkDriver,
    work_park_request: struct { driver: WorkDriver, request: ParkRequest },
    work_park_resume: struct { driver: WorkDriver, result: ParkResume },
    park_request: ParkRequest,
    park_resume: ParkResume,
};

fn WorkDriverAdapters(comptime Driver: type) type {
    return struct {
        pub fn advance(evaluator: *Unit, raw: *anyopaque) MachineError!WorkProgress {
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
        @compileError(std.fmt.comptimePrint("{s} ({d} bytes) exceeds the unit inline driver slot ({d} bytes)", .{ @typeName(Driver), @sizeOf(Driver), Unit.driver_slot_len }));
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
    plain_cache_hits: u64 = 0,
    plain_cache_misses: u64 = 0,
};

pub const root_execution_metrics_enabled = session_options.instrument_root_execution;

/// One driver for a primitive that must encode a path argument to bytes before
/// it can act. Encoding and its failure are the same work whatever follows, so
/// the action is the only thing that varies; the ownership order — take the
/// path, take the value, retire, then act — is stated once here rather than
/// copied per primitive.
pub fn PathActionDriver(
    comptime action: fn (*Unit, []u8, Value) MachineError!void,
) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;
        path_value: heap.Owned(Value),
        encoder: heap.Owned(kernel_storage.StringEncoder),
        path: ?heap.Owned([]u8) = null,

        pub fn advance(evaluator: *Unit, self: *Self) MachineError!WorkProgress {
            try evaluator.pollKernel();
            if (self.path == null) switch (self.encoder.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCodepoint => return evaluator.fail(.domain, "path contains an invalid Unicode scalar"),
            }) {
                .pending => return .stepped,
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
        // Activations point at this address, so it must never move while the
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
    inherited: InheritedContext,
    lifetime: LifetimeGuard,
    archive: *spans.SpanArchive,
    arguments: Value,
    cancelled: *const std.atomic.Value(bool),
    fuel: u32 = fuel_quantum,
    /// The unit's one allowance for logical kernel work in a turn. Cursors
    /// doing this unit's work draw on it through `Unit.workBudget`, and
    /// exhausting it ends the turn: only the start of the next turn refills it.
    kernel_budget: poll_api.WorkBudget = .init(kernel_poll_quantum),
    polls: u64 = 0,
    root_execution_metrics: if (root_execution_metrics_enabled) RootExecutionMetrics else void = if (root_execution_metrics_enabled) .{} else {},
    /// Anonymous bindings this unit may reuse at an application boundary.
    reuse: BindingReuse = .{},
    /// Explicit lookups this unit may reuse.
    lookups: LookupReuse = .{},
    max_frames: usize = 0,
    entry_base: usize,
    stack_base: usize,
    boundary_index: ?FrameIndex = null,
    /// The innermost active source effect check. Effect-check frames form an
    /// intrusive chain so nested checks restore their predecessor exactly.
    effect_check_index: ?EffectCheckIndex = null,
    terminal: TerminalState = .evaluating,
    idiom_hits: u64 = 0,
    /// The idiom hits that were phrases continued by following words.
    phrase_hits: u64 = 0,
    scheduler: ?*const scheduler_api.WorkerScheduler = null,
    task_scope: ?*scheduler_api.TaskScope = null,
    is_root_unit: bool = true,
    /// For a child unit, the `@` word that constructed it.
    constructor: UnitConstructor = .spawn,
    execution_scope: ?*env.Scope = null,
    /// Whether this unit's root activation may define. False for a task,
    /// which runs in its spawner's scope without being a root of its own.
    root_defining: bool = true,
    /// Protected invocation may start this child at one selected registered
    /// module generation. The Unit lifetime pins the home before installation.
    root_execution_home: ?*modules.ModuleHome = null,
    native: NativeContinuation = .idle,
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
    /// Locals. The declared names live here for the length of the
    /// quotation body that introduced them, never on the operand stack, so a
    /// body's declared stack effect describes its operands alone and an
    /// ordinary form between two local reads needs no shuffling to see past
    /// them. Reads are top-relative: the last local introduced is
    /// index 0.
    locals: std.ArrayList(Value) = .empty,
    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        module_access: *const modules.ExecutionAccess,
        stack: std.ArrayList(Value),
        environment: *env.Env,
        archive: *spans.SpanArchive,
        inherited: InheritedContext,
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
            .inherited = inherited,
            .arguments = arguments,
            .cancelled = cancelled,
            .entry_base = stack.items.len,
            .stack_base = 0,
            // SAFETY: this field supplies storage only. `driver_slot_busy` is the only
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

    pub fn executeRootAtModule(self: *Unit, home: *modules.ModuleHome) void {
        self.root_execution_home = home;
        self.execution_scope = home.scope(self.module_access);
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
        return self.native == .park_request or self.native == .work_park_request;
    }
    pub fn parkRequest(self: *const Unit) ?ParkRequest {
        return switch (self.native) {
            .park_request => |request| request,
            .work_park_request => |state| state.request,
            else => null,
        };
    }
    pub fn takeParkRequest(self: *Unit) ?ParkRequest {
        return switch (self.native) {
            .park_request => |request| result: {
                self.native = .idle;
                break :result request;
            },
            .work_park_request => |state| result: {
                self.native = .{ .work = state.driver };
                break :result state.request;
            },
            else => null,
        };
    }
    fn installParkRequest(self: *Unit, request: ParkRequest) void {
        self.native = switch (self.native) {
            .idle => .{ .park_request = request },
            .work => |driver| .{ .work_park_request = .{ .driver = driver, .request = request } },
            else => unreachable,
        };
    }
    pub fn installParkResume(self: *Unit, result: ParkResume) void {
        self.native = switch (self.native) {
            .idle => .{ .park_resume = result },
            .work => |driver| .{ .work_park_resume = .{ .driver = driver, .result = result } },
            else => unreachable,
        };
    }
    fn takeParkResume(self: *Unit) ?ParkResume {
        return switch (self.native) {
            .park_resume => |result| delivery: {
                self.native = .idle;
                break :delivery result;
            },
            .work_park_resume => |state| delivery: {
                self.native = .{ .work = state.driver };
                break :delivery state.result;
            },
            else => null,
        };
    }
    pub fn workDriver(self: *Unit) ?*WorkDriver {
        return switch (self.native) {
            .work => |*driver| driver,
            .work_park_request => |*state| &state.driver,
            .work_park_resume => |*state| &state.driver,
            else => null,
        };
    }
    pub fn takeWorkDriver(self: *Unit) ?WorkDriver {
        return switch (self.native) {
            .work => |driver| result: {
                self.native = .idle;
                break :result driver;
            },
            .work_park_request => |state| result: {
                state.request.deinit(self.releases);
                self.native = .idle;
                break :result state.driver;
            },
            .work_park_resume => |state| result: {
                state.result.deinit(self.releases);
                self.native = .idle;
                break :result state.driver;
            },
            else => null,
        };
    }
    /// The kind of the innermost saved frame, or null with none saved.
    fn topFrameTag(self: *const Unit) ?std.meta.Tag(Frame) {
        const frames = self.frames.items;
        return if (frames.len == 0) null else std.meta.activeTag(frames[frames.len - 1]);
    }
    /// Removes the innermost saved frame, which is a `tag`, and returns its
    /// payload. Popping the whole frame copied the union's largest variant.
    fn popFrame(self: *Unit, comptime tag: std.meta.Tag(Frame)) @FieldType(Frame, @tagName(tag)) {
        const payload = @field(self.frames.items[self.frames.items.len - 1], @tagName(tag));
        self.frames.items.len -= 1;
        return payload;
    }
    pub fn hasWorkDriver(self: *const Unit) bool {
        return self.native == .work or self.native == .work_park_request or
            self.native == .work_park_resume;
    }
    /// Scheduler-owned teardown of all user-sized evaluator cargo. Each unit
    /// of budget retires at most one continuation, operand, native owner, or
    /// generation pin. Array storage is released by `deinit` after this cursor
    /// reports complete.
    pub fn advanceSchedulerTeardown(self: *Unit, budget: usize) CleanupProgress {
        std.debug.assert(budget != 0);
        var consumed: usize = 0;
        while (consumed != budget) {
            switch (self.native) {
                .work, .work_park_request, .work_park_resume => {
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
                .idle => {},
            }
            if (self.current) |current| {
                self.current = null;
                current.release(self.releases);
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
            const boundary = self.frames.items[@backingInt(frame_index)].boundary;
            if (boundary.mode == .attempt) return true;
            index = boundary.previous_boundary;
        }
        return false;
    }
    /// Whether a module construction is open anywhere in this unit's frame
    /// stack. Unlike the direct-root test `testDeclarationCursor` applies, any
    /// depth counts: a helper word the body calls and an `@attempt` nested in
    /// the body are still construction, so a body cannot launder a task launch
    /// through code it defines first.
    /// The names `words` lists from where this activation runs: a session
    /// root's top-level directory, or a published image's.
    pub fn visibleNameRoot(self: *Unit) reflection.VisibleNameRoot {
        const scope = self.currentScope();
        if (scope.isModuleRoot()) if (modules.homeForModuleRootScope(scope)) |home| {
            if (home.isPublished()) return .{ .image = .{
                .entries = home.publishedEntries(),
                .pin = home.pin(self.module_access),
            } };
            return .core;
        };
        if (scope.storage == .core_build) return .core;
        return .{ .session = self.inherited.registry.view() };
    }

    /// The image under construction whose root is `scope`, found through the
    /// open module boundaries: the one place its staged names are written.
    pub fn stagingImage(self: *Unit, scope: *env.Scope) ?*modules.OwnedImage {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = &self.frames.items[@backingInt(frame_index)].boundary;
            switch (boundary.mode) {
                .module => |*module| {
                    if (module.image.executionHome(self.module_access).scope(self.module_access) == scope)
                        return &module.image;
                },
                .attempt => {},
            }
            index = boundary.previous_boundary;
        }
        return null;
    }
    pub fn inModuleConstruction(self: *const Unit) bool {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = self.frames.items[@backingInt(frame_index)].boundary;
            if (boundary.mode == .module) return true;
            index = boundary.previous_boundary;
        }
        return false;
    }
    pub fn pinGeneration(self: *Unit, generation: *modules.ModuleHome) error{OutOfMemory}!void {
        try self.lifetime.pin(self.allocator, generation, self.module_access);
    }

    /// Sized to the drivers that opt in, checked by `inlineDriverCapable`.
    /// Includes native registration authority and a reference to the Unit's
    /// bounded lexical observations for lookup and idiom recognition. Preserve the
    /// complete ownership state without allocating on ordinary resolution.
    pub const driver_slot_len = 736;
    pub const driver_slot_align = 16;

    fn acquireInlineDriver(self: *Unit, comptime Driver: type) ?*Driver {
        if (self.driver_slot_busy) return null;
        self.driver_slot_busy = true;
        return @ptrCast(@alignCast(&self.driver_slot));
    }

    fn ownsInlineDriver(self: *const Unit, driver: *const anyopaque) bool {
        return @intFromPtr(driver) == @intFromPtr(&self.driver_slot);
    }

    fn releaseInlineDriver(self: *Unit) void {
        std.debug.assert(self.driver_slot_busy);
        self.driver_slot_busy = false;
    }

    pub fn deinit(self: *Unit) void {
        self.reuse.deinit(self.releases);
        self.lookups.deinit(self.releases);
        if (self.current) |current| current.release(self.releases);
        while (self.frames.pop()) |frame| self.deinitPoppedFrame(frame);
        self.frames.deinit(self.allocator);
        for (self.stack.items) |item| self.releases.releaseValue(item);
        self.stack.deinit(self.allocator);
        self.terminal.deinit(self.releases);
        switch (self.native) {
            .idle => {},
            .work => |driver| driver.deinit(self.releases, self.allocator),
            .work_park_request => |state| {
                state.request.deinit(self.releases);
                state.driver.deinit(self.releases, self.allocator);
            },
            .work_park_resume => |state| {
                state.result.deinit(self.releases);
                state.driver.deinit(self.releases, self.allocator);
            },
            .park_request => |request| request.deinit(self.releases),
            .park_resume => |result| result.deinit(self.releases),
        }
        for (self.locals.items) |item| self.releases.releaseValue(item);
        self.locals.deinit(self.allocator);
        self.lifetime.deinit(self.releases, self.allocator);
        self.* = undefined;
    }

    fn deinitPoppedFrame(self: *Unit, popped: Frame) void {
        var frame = popped;
        if (frame == .effect_check) frame.effect_check.restoreActive(self);
        frame.deinit(self.releases, self.allocator);
    }

    pub fn beginNativeTiming(self: *const Unit) ?i128 {
        if (!self.inherited.native_diagnostics) return null;
        const io = self.inherited.runtime().host_io;
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
        self: *Unit,
        instance: *native_module.ModuleInstance,
        started: ?i128,
    ) void {
        const start = started orelse return;
        const io = self.inherited.runtime().host_io;
        const end = std.Io.Clock.awake.now(io).nanoseconds;
        const elapsed: u64 = @intCast(@max(end - start, 0));
        if (!instance.recordDuration(elapsed)) return;
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "native module `{s}` returned after an over-quantum slice ({d} ns)\n",
            .{ intern.get(intern.moduleId(instance.name())), elapsed },
        ) catch return;
        if (self.inherited.console()) |console| {
            settleAdvisoryDiagnostic(console.writeDiagnostics(line, false));
        }
    }
    pub fn currentScope(self: *const Unit) *env.Scope {
        return self.current.?.scope();
    }
    /// Links words written into `scope`, a root, to that root. An image's
    /// cell carries its owner anchor, so a word that escapes the image proves
    /// the image live before reading its directory.
    pub fn rootLinker(self: *Unit, scope: *env.Scope) error{OutOfMemory}!env.SymbolLinker {
        return switch (scope.storage) {
            .session => self.environment.linker(self.environment.sessionScopeId()),
            .core_build => self.environment.linker(self.environment.coreScopeId()),
            .module_root => self.environment.linker((try self.environment.scopeCell(
                scope,
                modules.anchorHandle(modules.homeForModuleRootScope(scope).?, self.module_access),
            )).id),
        };
    }
    /// The word `name` linked to its slot in the running activation's root, as
    /// a word built at run time on that activation's behalf is.
    pub fn linkedWord(self: *Unit, name: u32) error{OutOfMemory}!value.Symbol {
        const linker = try self.rootLinker(self.currentScope());
        return .{ .name = name, .slot = try linker.link(name) };
    }
    /// The word `name` linked to its core slot, as a word the implementation
    /// builds for itself is: it means core's binding wherever it runs.
    pub fn coreWord(self: *Unit, name: u32) error{OutOfMemory}!value.Symbol {
        const linker = self.environment.linker(self.environment.coreScopeId());
        return .{ .name = name, .slot = try linker.link(name) };
    }
    /// The root a definition, removal, or import writes. Refused inside a
    /// combinator application, an `@attempt`, or a task, which are not roots.
    pub fn definitionScope(self: *Unit) MachineError!*env.Scope {
        const scope = self.currentScope();
        if (!self.current.?.site.defining) return self.fail(
            .domain,
            "definitions are legal only at root level, not inside a combinator application, @attempt, or task",
        );
        return scope;
    }
    /// The source name attached to the occurrence being dispatched. The
    /// archive owns the returned bytes for at least as long as the current
    /// code header, which the activation retains across any driver this call
    /// starts. Runtime-built code has no entry and returns null.
    pub fn activeSourceName(self: *const Unit) ?[]const u8 {
        const current = self.current orelse return null;
        const located = self.archive.locate(current.code, self.active_index) orelse
            return null;
        return located.source_name;
    }
    pub fn currentHome(self: *const Unit) ?*modules.ModuleHome {
        return self.current.?.home();
    }
    /// Begin publishing one first-class test into the candidate owned by the
    /// immediately enclosing module-construction boundary. Requiring that
    /// boundary to be the top frame distinguishes the construction body's
    /// direct root from quotations or child units that merely inherit its
    /// scope and private home.
    pub fn testDeclarationCursor(
        self: *Unit,
        name: intern.BindingName,
        body: *env.Quotation,
        effect: ?env.ValidatedEffect,
        doc: ?*env.DocumentationString,
    ) MachineError!modules.TestDeclarationCursor {
        const boundary_index = self.boundary_index orelse
            return self.fail(.domain, "test is legal only at a direct module construction root");
        if (@backingInt(boundary_index) + 1 != self.frames.items.len)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        const frame = &self.frames.items[@backingInt(boundary_index)];
        if (frame.* != .boundary or frame.boundary.mode != .module)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        const candidate = &frame.boundary.mode.module.image;
        if (self.current.?.code != frame.boundary.mode.module.root_code)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        const home = candidate.executionHome(self.module_access);
        if (self.currentHome() != home or self.currentScope() != home.scope(self.module_access))
            return self.fail(.domain, "test is legal only at a direct module construction root");
        if (self.inherited.test_execution == null)
            return .discard();
        return candidate.testDeclarationCursor(name, body, effect, doc);
    }
    pub fn applicationSite(self: *const Unit) ApplicationSite {
        const current = self.current.?;
        return .{
            .parent_scope = current.scope(),
            .home = current.home(),
            // A combinator applies a quotation value, which may have come from
            // any caller, so embedded trust stays with the embedded code.
            .registration_provenance = current.site.registration_provenance.applied(),
            .defining = current.site.defining,
        };
    }
    fn installDriver(self: *Unit, context: anytype) void {
        const Context = @TypeOf(context);
        const pointer = switch (@typeInfo(Context)) {
            .pointer => |info| info,
            else => @compileError("work driver context must be a pointer"),
        };
        if (pointer.size != .one) @compileError("work driver context must be a single-item pointer");
        const Driver = pointer.child;
        const adapters = WorkDriverAdapters(Driver);
        const installed = WorkDriver{
            .context = @ptrCast(context),
            .resume_fn = adapters.advance,
            .deinit_fn = if (comptime inlineDriverCapable(Driver))
                (if (self.ownsInlineDriver(context)) adapters.deinitInline else adapters.deinit)
            else
                adapters.deinit,
            .site = if (self.current) |current| .{
                .code = current.code,
                .index = self.active_index,
            } else null,
        };
        std.debug.assert(self.native == .idle);
        self.native = .{ .work = installed };
    }
    /// Consumes a fully initialized, heap-allocated continuation whose type
    /// explicitly requires address-stable construction. Ordinary drivers use
    /// `startDriver`, which owns allocation failure as well as installation.
    pub fn adoptDriver(self: *Unit, context: anytype) void {
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
    pub fn startDriver(self: *Unit, initial: anytype) error{OutOfMemory}!void {
        const Driver = @TypeOf(initial);
        switch (comptime heap.validateDriverOwnership(Driver)) {
            .fields, .bounded_retirement => {},
            .self_owned => @compileError("self-owned drivers require address-stable construction"),
        }
        var pending = initial;
        if (comptime inlineDriverCapable(Driver)) {
            if (self.acquireInlineDriver(Driver)) |slot| {
                slot.* = pending;
                self.installDriver(slot);
                return;
            }
        }
        const driver = self.allocator.create(Driver) catch |err| {
            heap.deinitDriverFields(self.releases, self.allocator, &pending);
            return err;
        };
        driver.* = pending;
        self.installDriver(driver);
    }

    /// Starts a driver by running its first step where it is started, and
    /// installs it only when that step leaves work for a later one. The step
    /// draws on the same budget, and a failure surfaces at the same site, as
    /// it would from the machine loop, so a driver whose work fits the rest of
    /// the turn costs no installation and no loop round trip. A driver started
    /// here completes or steps; it never detaches or parks, since it has not
    /// been installed.
    pub fn runDriver(self: *Unit, initial: anytype) MachineError!void {
        var pending = initial;
        return self.runDriverAt(&pending);
    }

    /// `runDriver` over a driver its caller built in place, which consumes
    /// the driver's fields exactly as `runDriver` does without copying it.
    pub fn runDriverAt(self: *Unit, pending: anytype) MachineError!void {
        const Driver = @typeInfo(@TypeOf(pending)).pointer.child;
        if (!turn_core.mayDispatch(self.kernel_budget)) return self.startDriver(pending.*);
        const progress = Driver.advance(self, pending) catch |err| {
            heap.deinitDriverFields(self.releases, self.allocator, pending);
            return err;
        };
        switch (progress) {
            .stepped => return self.startDriver(pending.*),
            .output => |item| {
                heap.deinitDriverFields(self.releases, self.allocator, pending);
                return self.pushOwned(item);
            },
            .completed => heap.deinitDriverFields(self.releases, self.allocator, pending),
            .yielded, .reserved_output, .detached, .failed => unreachable,
        }
    }

    /// Destroy a driver that may be living in the unit's inline slot. A driver
    /// that opts into inline storage must retire itself through this rather
    /// than `heap.destroyDriver`, which would hand slot memory to the
    /// allocator.
    pub fn finishDriver(self: *Unit, driver: anytype) void {
        const Driver = @typeInfo(@TypeOf(driver)).pointer.child;
        if (comptime inlineDriverCapable(Driver)) {
            if (self.ownsInlineDriver(driver)) {
                heap.deinitDriverFields(self.releases, self.allocator, driver);
                self.releaseInlineDriver();
                return;
            }
        }
        heap.destroyDriver(self.releases, self.allocator, driver);
    }
    /// Moves the top `count` operands into the unit's locals, the
    /// first declared local ending on top. The operand stack is machine-owned,
    /// so the move lives here and the primitive keeps only its validation.
    pub fn bindLocals(self: *Unit, count: usize) error{OutOfMemory}!void {
        try self.locals.ensureUnusedCapacity(self.allocator, count);
        const base = self.stack.items.len - count;
        var remaining = count;
        while (remaining != 0) {
            remaining -= 1;
            self.locals.appendAssumeCapacity(self.stack.items[base + remaining]);
        }
        self.stack.shrinkRetainingCapacity(base);
    }

    pub fn readLocal(self: *Unit, index: usize) error{OutOfMemory}!void {
        const depth = self.locals.items.len;
        try self.pushBorrowed(self.locals.items[depth - 1 - index]);
    }

    pub fn unbindLocals(self: *Unit, count: usize) void {
        for (0..count) |_| {
            const item = self.locals.pop().?;
            self.releases.releaseValue(item);
        }
    }

    /// Detach the installed continuation and destroy it. A driver that has
    /// finished its own work ends exactly this way, and routing every one of
    /// them through a single place is what keeps inline-slot storage from ever
    /// reaching the allocator.
    pub fn retireDriver(self: *Unit, driver: anytype) void {
        self.detachWorkDriver(driver);
        self.finishDriver(driver);
    }
    /// Consumes the currently installed erased continuation without invoking
    /// its destructor. Self-replacing drivers use this before destroying their
    /// concrete state and installing the typed successor.
    pub fn detachWorkDriver(self: *Unit, context: anytype) void {
        const driver = self.takeWorkDriver().?;
        std.debug.assert(driver.context == @as(*anyopaque, @ptrCast(context)));
    }
    /// Charges one finished application continuation to the unit's dispatch
    /// fuel, exactly as fetching a form does. A body that dispatches nothing
    /// still spends fuel here, so an empty iteration reaches the exhaustion
    /// safe point where cancellation is observed and the slice ends. The
    /// continuation itself never ends a slice: the same bound that limits a
    /// run of forms limits a run of resumed continuations.
    pub fn chargeContinuationStep(self: *Unit) void {
        self.fuel -|= 1;
    }

    /// Mints the nominal proof that this callback installed the work which
    /// will launch its nested inline child. The machine validates the proof
    /// against the still-installed driver before preserving the parent frame.
    pub fn suspendInlineApplication(self: *Unit) ApplicationStep {
        const driver = self.workDriver() orelse unreachable;
        return .{ .suspend_inline = @ptrCast(driver.context) };
    }
    /// Start the ordinary qualified-name loader without executing or importing
    /// an export. The caller supplies an initialized root and drives it through
    /// `runInitializedRoot`; reflection and completion use this same path.
    pub fn loadModuleOnly(self: *Unit, name: intern.ModuleName) MachineError!void {
        self.active_word = .plain(intern.moduleId(name));
        try self.autoLoadModule(name, .{
            .qualified = intern.moduleId(name),
            .context = self.current.?.site.registration_provenance,
            .continuation = .load_only,
        });
    }

    /// A reflection primitive already consumed its symbol before discovering
    /// a cold qualified module. Restore that operand and rewind the primitive
    /// call, then use the same loader/retry protocol as executable dispatch.
    pub fn retryQualifiedOperandAfterLoad(
        self: *Unit,
        requested: value.Symbol,
        outcome: binder.Miss,
    ) MachineError!WorkProgress {
        if (self.current == null)
            return self.undefinedNameIn(requested.name, .qualified);
        switch (outcome) {
            .unknown_module_prefix => |prefix| {
                try self.startDriver(QualifiedLoadPreparationDriver.init(
                    prefix,
                    .{ .qualified = requested.name, .context = self.current.?.site.registration_provenance, .continuation = .replay },
                    .{ .operand = requested },
                ));
                return .detached;
            },
            .unregistered_module => |name| {
                try self.pushBorrowed(.{ .symbol = requested });
                self.current.?.rewind(self.active_index);
                try self.autoLoadModule(name, .{
                    .qualified = requested.name,
                    .context = self.current.?.site.registration_provenance,
                    .continuation = .replay,
                });
                return .detached;
            },
            .unresolved => |chain| return self.undefinedNameIn(requested.name, chain),
            .retired, .alias_cycle => return self.failUnbound(requested, outcome),
        }
    }
    /// A batch import consumes its module symbol and requested-name list before
    /// discovering a cold module. Restore both operands, rewind the primitive,
    /// and share the ordinary qualified-name auto-load/retry path.
    pub fn retryImportAfterLoad(
        self: *Unit,
        module_id: u32,
        requested: Value,
        module_name: intern.ModuleName,
        requested_word: u32,
    ) MachineError!WorkProgress {
        if (self.current == null) {
            self.releases.releaseValue(requested);
            return self.undefinedNameIn(requested_word, .qualified);
        }
        try self.restoreImportOperands(module_id, requested);
        self.current.?.rewind(self.active_index);
        try self.autoLoadModule(module_name, .{
            .qualified = requested_word,
            .context = self.current.?.site.registration_provenance,
            .continuation = .replay,
        });
        return .detached;
    }
    /// Consumes the requested-name list on both success and allocation
    /// failure. Keeping the exact stack commit outside the driver-returning
    /// retry function preserves the WorkProgress output boundary audited for
    /// every driver.
    fn restoreImportOperands(self: *Unit, module_id: u32, requested: Value) error{OutOfMemory}!void {
        var owned = heap.Owned(Value).init(requested);
        defer owned.deinit(self.releases, self.allocator);
        var reservation = try self.reserveStack(2);
        reservation.pushBorrowed(.{ .symbol = .{ .name = module_id } });
        reservation.pushOwned(owned.take());
        std.debug.assert(reservation.complete());
    }
    /// A completed auto-load registers the module before resuming the tagged
    /// qualified operation. The requested spelling also identifies a
    /// misspelled export in the final undefined-word error.
    fn autoLoadModule(
        self: *Unit,
        name: intern.ModuleName,
        request: QualifiedLoadRequest,
    ) MachineError!void {
        const registry = self.inherited.registry;
        try self.startDriver(AutoLoadDriver{
            .request = .{ .module = .{ .name = name, .operation = request } },
            .state = .init(.{ .begin = registry.beginLoadingCursor(name, .of(self)) }),
        });
    }
    pub fn loadSourceOnly(self: *Unit, source: *const map_state.SourceScope) MachineError!void {
        const location = source.location();
        try self.startDriver(AutoLoadDriver{
            .request = .source,
            .state = .init(.{ .artifact_begin = .{
                .target = .{
                    .scope_name = location.scope_name,
                    .root = location.root,
                    .relative_path = location.relative_path,
                    .scope_id = location.scope_id,
                    .artifact_id = location.artifact_id,
                    .kind = location.kind,
                },
                .cursor = self.inherited.registry.beginArtifactLoadingCursor(location.artifact_id, .of(self)),
            } }),
        });
    }

    /// Standard-library names are reserved, like `core`: only embedded loading
    /// registers them, so a stdlib name means the same module in every scope,
    /// whether or not it has loaded. User registration, aliasing, and removal
    /// under one are `'domain`.
    pub fn refuseReservedModule(self: *Unit, name: intern.ModuleName, provenance: modules.RegistrationProvenance) MachineError!void {
        if (provenance == .standard_library) return;
        if (self.inherited.libraries().find(name) == null) return;
        return self.failFmt(
            .domain,
            "module name `{s}` is reserved for the standard library",
            .{intern.get(intern.moduleId(name))},
        );
    }

    pub fn publicationRegistry(self: *const Unit, name: intern.ModuleName, provenance: modules.RegistrationProvenance) *modules.Registry {
        if (provenance == .source and !provenance.source.exports(name)) return provenance.source.registry();
        return self.inherited.registry;
    }
    const AutoLoadDriver = struct {
        const FileKind = enum { source, native };
        const CandidateOrigin = union(enum) {
            search_path: struct {
                component_start: usize,
                component_end: usize,
                next_search: usize,
            },
            mapped: struct {
                scope_name: []const u8,
                root: []const u8,
                scope_id: map_state.ScopeId,
                artifact_id: map_state.ArtifactId,
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
                artifact: ?map_state.ArtifactId,
            },
            native: ?map_state.ArtifactId,
            embedded: stdlib.Entry,
            fail: []const u8,
        };
        const MappedTarget = struct {
            scope_name: []const u8,
            root: []const u8,
            relative_path: []const u8,
            scope_id: map_state.ScopeId,
            artifact_id: map_state.ArtifactId,
            kind: @import("module_map.zig").Kind,
        };
        const State = union(enum) {
            begin: modules.Registry.BeginLoadingCursor,
            registered: struct {
                loading: heap.Owned(modules.LoadingLease),
                cursor: heap.Owned(modules.Registry.AcquireCursor),
            },
            map_lookup: struct {
                loading: heap.Owned(modules.LoadingLease),
                cursor: heap.Owned(map_state.LookupCursor),
            },
            artifact_begin: struct {
                target: MappedTarget,
                cursor: modules.Registry.BeginLoadingCursor,
            },
            committed: heap.Owned(modules.Registry.AcquireCursor),
            mapped_root: struct {
                loading: heap.Owned(modules.LoadingLease),
                target: MappedTarget,
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
                    .map_lookup => |*lookup| {
                        lookup.cursor.deinit(releases, storage_allocator);
                        lookup.loading.deinit(releases, storage_allocator);
                    },
                    .artifact_begin => |*begin| begin.cursor.deinit(),
                    .committed => |*cursor| cursor.deinit(releases, storage_allocator),
                    .mapped_root => |*mapped| mapped.loading.deinit(releases, storage_allocator),
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

        request: SourceLoadRequest,
        state: heap.Owned(State),

        fn makeFilename(
            self: *AutoLoadDriver,
            evaluator: *Unit,
            loading: *heap.Owned(modules.LoadingLease),
            kind: FileKind,
            target: FilenameTarget,
        ) error{OutOfMemory}!FilenameState {
            const module_name = intern.get(intern.moduleId(self.request.module.name));
            const extension = switch (kind) {
                .source => ".ecl",
                .native => ".eclmod",
            };
            const length = std.math.add(usize, module_name.len, extension.len) catch
                return error.OutOfMemory;
            const filename = try evaluator.allocator.alloc(u8, length);
            return .{
                .loading = .init(loading.take()),
                .filename = .init(filename),
                .kind = kind,
                .target = target,
            };
        }
        fn makeCandidate(
            evaluator: *Unit,
            loading: *heap.Owned(modules.LoadingLease),
            filename: *heap.Owned([]u8),
            kind: FileKind,
            origin: CandidateOrigin,
        ) error{OutOfMemory}!CandidateState {
            const directory = switch (origin) {
                .mapped => |mapped| mapped.root,
                .search_path => |legacy| legacy_directory: {
                    const search = evaluator.inherited.ecl_path.?;
                    break :legacy_directory search[legacy.component_start..legacy.component_end];
                },
            };
            const separator = directory.len != 0 and !std.fs.path.isSep(directory[directory.len - 1]);
            var length = std.math.add(usize, directory.len, filename.borrow().len) catch
                return error.OutOfMemory;
            if (separator) length = std.math.add(usize, length, 1) catch
                return error.OutOfMemory;
            const candidate = try evaluator.allocator.alloc(u8, length);
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
            evaluator: *Unit,
            loading: *heap.Owned(modules.LoadingLease),
            entry: stdlib.Entry,
        ) error{OutOfMemory}!void {
            const provenance = switch (entry) {
                .source => |source| source.name,
                .native, .builtin => intern.get(intern.moduleId(self.request.module.name)),
            };
            var candidate = heap.Owned([]u8).init(try evaluator.allocator.dupe(u8, provenance));
            const materializer = kernel_storage.Utf8Materializer.init(
                evaluator.allocator,
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
            evaluator: *Unit,
            loading: *heap.Owned(modules.LoadingLease),
        ) MachineError!WorkProgress {
            loading.borrowMut().finish();
            return continueSourceRequest(evaluator, self, self.request);
        }
        fn notFound(self: *AutoLoadDriver, evaluator: *Unit) MachineError {
            return evaluator.undefinedWordIn(self.request.module.operation.qualified, .qualified);
        }
        fn sourceCompletion(
            self: *AutoLoadDriver,
            transfer: *@FieldType(State, "transfer"),
            provenance: modules.RegistrationProvenance,
            artifact: ?map_state.ArtifactId,
        ) SourceCompletion {
            return .{ .register = .{
                .loading = transfer.loading.borrowMut().move(),
                .path = transfer.path.take(),
                .request = self.request,
                .provenance = provenance,
                .artifact = artifact,
            } };
        }
        pub fn advance(evaluator: *Unit, self: *AutoLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            const work = evaluator.workBudget();
            work: while (work.spend()) switch (self.state.borrowMut().*) {
                .begin => |*cursor| switch (try cursor.advance()) {
                    .pending => {},
                    .complete => |outcome| switch (outcome) {
                        .cycle => return evaluator.failFmt(
                            .domain,
                            "recursive auto-load of module `{s}`",
                            .{intern.get(intern.moduleId(self.request.module.name))},
                        ),
                        // Another unit is loading this name. Wait for it
                        // rather than publishing a second copy; the recheck
                        // below is what makes the winner's work count.
                        .contended => {
                            cursor.deinit();
                            self.state.borrowMut().* = .{ .begin = evaluator.inherited.registry.beginLoadingCursor(
                                self.request.module.name,
                                .of(evaluator),
                            ) };
                            return .{ .yielded = .wait };
                        },
                        .granted => |lease| {
                            cursor.deinit();
                            if (evaluator.inherited.module_snapshot != null and
                                evaluator.inherited.libraries().find(self.request.module.name) == null)
                            {
                                self.state.borrowMut().* = .{ .map_lookup = .{
                                    .loading = .init(lease),
                                    .cursor = .init(evaluator.inherited.module_snapshot.?.lookupCursor(
                                        self.request.module.operation.context.scopeId(),
                                        intern.get(intern.moduleId(self.request.module.name)),
                                    )),
                                } };
                            } else {
                                self.state.borrowMut().* = .{ .registered = .{
                                    .loading = .init(lease),
                                    .cursor = .init(evaluator.inherited.registry.acquireCursor(self.request.module.name)),
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
                        defer loading.deinit(evaluator.releases, evaluator.allocator);
                        registered.cursor.deinit(
                            evaluator.releases,
                            evaluator.allocator,
                        );
                        if (maybe_generation) |generation| {
                            var lease = generation;
                            lease.deinit();
                            return self.finishWithoutLoading(evaluator, &loading);
                        }
                        // The embedded manifest is consulted before the
                        // search path: a stdlib name resolves without filesystem lookup
                        // and no ECL_PATH, and no path module can shadow one.
                        if (evaluator.inherited.libraries().find(self.request.module.name)) |entry| {
                            try self.beginEmbedded(evaluator, &loading, entry);
                            continue;
                        }
                        if (evaluator.inherited.module_snapshot) |module_snapshot| {
                            self.state.borrowMut().* = .{ .map_lookup = .{
                                .loading = .init(loading.take()),
                                .cursor = .init(module_snapshot.lookupCursor(
                                    self.request.module.operation.context.scopeId(),
                                    intern.get(intern.moduleId(self.request.module.name)),
                                )),
                            } };
                            continue;
                        }
                        if (evaluator.inherited.ecl_path == null)
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
                .map_lookup => |*lookup| switch (lookup.cursor.borrowMut().advance()) {
                    .pending => {},
                    .complete => |outcome| {
                        var loading = heap.Owned(modules.LoadingLease).init(lookup.loading.take());
                        defer loading.deinit(evaluator.releases, evaluator.allocator);
                        lookup.cursor.deinit(
                            evaluator.releases,
                            evaluator.allocator,
                        );
                        switch (outcome) {
                            .unmatched => {
                                return evaluator.failFmt(
                                    .undefined_word,
                                    "module `{s}` is not exported by the active module map",
                                    .{intern.get(intern.moduleId(self.request.module.name))},
                                );
                            },
                            .hidden => |hidden| {
                                return evaluator.failFmt(
                                    .undefined_word,
                                    "module `{s}` is exported by scope `{s}`, but is not visible to `{s}`",
                                    .{
                                        intern.get(intern.moduleId(self.request.module.name)),
                                        hidden.owner,
                                        hidden.consumer,
                                    },
                                );
                            },
                            .matched => |match| {
                                loading.borrowMut().finish();
                                const target: MappedTarget = .{
                                    .scope_name = match.scope_name,
                                    .root = match.root,
                                    .relative_path = match.relative_path,
                                    .scope_id = match.scope_id,
                                    .artifact_id = match.artifact_id,
                                    .kind = match.kind,
                                };
                                self.state.borrowMut().* = .{ .artifact_begin = .{
                                    .target = target,
                                    .cursor = evaluator.inherited.registry.beginArtifactLoadingCursor(match.artifact_id, .of(evaluator)),
                                } };
                            },
                        }
                    },
                },
                .artifact_begin => |*begin| switch (try begin.cursor.advance()) {
                    .pending => {},
                    .complete => |outcome| switch (outcome) {
                        .cycle => return evaluator.failFmt(
                            .domain,
                            "recursive auto-load of mapped artifact `{s}`",
                            .{begin.target.relative_path},
                        ),
                        .contended => {
                            const target = begin.target;
                            begin.cursor.deinit();
                            self.state.borrowMut().* = .{ .artifact_begin = .{
                                .target = target,
                                .cursor = evaluator.inherited.registry.beginArtifactLoadingCursor(
                                    target.artifact_id,
                                    .of(evaluator),
                                ),
                            } };
                            return .{ .yielded = .wait };
                        },
                        .granted => |lease| {
                            const target = begin.target;
                            begin.cursor.deinit();
                            self.state.borrowMut().* = .{ .mapped_root = .{ .target = target, .loading = .init(lease) } };
                            if (evaluator.inherited.module_snapshot.?.artifactCommitted(target.artifact_id)) {
                                self.state.borrowMut().mapped_root.loading.borrowMut().finish();
                                if (self.request == .source) return .completed;
                                self.state.borrowMut().mapped_root.loading.deinit(evaluator.releases, evaluator.allocator);
                                self.state.borrowMut().* = .{ .committed = .init(evaluator.inherited.registry.acquireCursor(self.request.module.name)) };
                            }
                        },
                    },
                },
                .committed => |*cursor| switch (cursor.borrowMut().advance()) {
                    .pending => {},
                    .complete => |maybe_generation| {
                        cursor.deinit(evaluator.releases, evaluator.allocator);
                        const generation = maybe_generation orelse return evaluator.failFmt(
                            .io,
                            "a committed mapped artifact is missing module `{s}`",
                            .{intern.get(intern.moduleId(self.request.module.name))},
                        );
                        var lease = generation;
                        lease.deinit();
                        return continueSourceRequest(evaluator, self, self.request);
                    },
                },
                .mapped_root => |*mapped| {
                    var loading = heap.Owned(modules.LoadingLease).init(mapped.loading.take());
                    defer loading.deinit(evaluator.releases, evaluator.allocator);
                    const origin: CandidateOrigin = .{ .mapped = .{
                        .scope_name = mapped.target.scope_name,
                        .root = mapped.target.root,
                        .scope_id = mapped.target.scope_id,
                        .artifact_id = mapped.target.artifact_id,
                    } };
                    const filename_bytes = try evaluator.allocator.dupe(u8, mapped.target.relative_path);
                    const filename = FilenameState{
                        .loading = .init(loading.take()),
                        .filename = .init(filename_bytes),
                        .index = filename_bytes.len,
                        .kind = if (mapped.target.kind == .ecl) .source else .native,
                        .target = .{ .candidate = origin },
                    };
                    self.state.borrowMut().* = .{ .filename = filename };
                },
                .filename => |*filename| {
                    if (filename.index != filename.filename.borrow().len) {
                        const module_name = intern.get(intern.moduleId(self.request.module.name));
                        const extension = switch (filename.kind) {
                            .source => ".ecl",
                            .native => ".eclmod",
                        };
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
                    const search = evaluator.inherited.ecl_path.?;
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
                    const search = evaluator.inherited.ecl_path.?;
                    if (component.search_index == search.len or
                        search[component.search_index] == std.fs.path.delimiter)
                    {
                        const component_end = component.search_index;
                        var next_search = component.search_index;
                        if (next_search != search.len) next_search += 1;
                        const origin: CandidateOrigin = .{ .search_path = .{
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
                        .mapped => |mapped| mapped.root,
                        .search_path => |legacy| legacy_directory: {
                            const search = evaluator.inherited.ecl_path.?;
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
                            .search_path => .{ .provenance = .ordinary, .artifact = null },
                            .mapped => |mapped| .{
                                .provenance = .{ .source = evaluator.inherited.module_snapshot.?.sourceScope(mapped.artifact_id) },
                                .artifact = mapped.artifact_id,
                            },
                        } },
                        .native => .{ .native = switch (access.origin) {
                            .search_path => null,
                            .mapped => |mapped| mapped.artifact_id,
                        } },
                    };
                    std.Io.Dir.cwd().access(
                        evaluator.inherited.runtime().host_io,
                        access.candidate.borrow(),
                        .{ .read = true },
                    ) catch |err| switch (err) {
                        error.FileNotFound => {
                            const origin = access.origin;
                            switch (origin) {
                                .mapped => |mapped| return evaluator.failFmt(
                                    .undefined_word,
                                    "mapped source `{s}` is absent from scope `{s}`",
                                    .{ access.candidate.borrow(), mapped.scope_name },
                                ),
                                .search_path => |legacy| {
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
                                    access.candidate.deinit(evaluator.releases, evaluator.allocator);
                                    access.filename.deinit(evaluator.releases, evaluator.allocator);
                                    self.state.borrowMut().* = .{ .filename = filename };
                                    continue :work;
                                },
                            }
                        },
                        else => disposition = .{ .fail = @errorName(err) },
                    };
                    const materializer = kernel_storage.Utf8Materializer.init(
                        evaluator.allocator,
                        access.candidate.borrow(),
                    );
                    access.filename.deinit(evaluator.releases, evaluator.allocator);
                    const next = @FieldType(State, "path_value"){
                        .loading = .init(access.loading.take()),
                        .candidate = .init(access.candidate.take()),
                        .materializer = .init(materializer),
                        .disposition = disposition,
                    };
                    self.state.borrowMut().* = .{ .path_value = next };
                },
                .path_value => |*path| switch (path.materializer.borrowMut().advance(work) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => return evaluator.fail(.io, "module path is not valid UTF-8"),
                }) {
                    .pending => {},
                    .complete => |path_value| {
                        path.materializer.deinit(
                            evaluator.releases,
                            evaluator.allocator,
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
                        evaluator.pendingFailure().addData(.path, transfer.path.borrow());
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
            return .stepped;
        }
        /// The manifest owns constant bytes, and `sourceOwned` frees what it
        /// is given, so the text is duped for the reader to consume. A linked
        /// descriptor needs no transport at all: `startStatic` publishes it
        /// through the same validate/publish/commit phases as a dynamic
        /// image, with a no-op image pin.
        fn transferEmbedded(
            self: *AutoLoadDriver,
            evaluator: *Unit,
            transfer: *@FieldType(State, "transfer"),
            entry: stdlib.Entry,
        ) MachineError!WorkProgress {
            const text = switch (entry) {
                .source => |source| try evaluator.allocator.dupe(u8, source.text),
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
            evaluator: *Unit,
            transfer: *@FieldType(State, "transfer"),
            words: []const env.BuiltinWord,
        ) MachineError!WorkProgress {
            // The candidate is created before ownership moves: struct-literal
            // fields evaluate in order, so a failure here would otherwise
            // strand the lease and path this driver had already taken.
            const publication = try modules.Registry.BuiltinCandidateCursor.init(evaluator.inherited.registry, self.request.module.name, .standard_library, words);
            // No errdefer: from here nothing fails until `startDriver`, which
            // disposes the whole uninstalled driver's owned fields itself.
            const next = BuiltinLoadDriver{
                .name = self.request.module.name,
                .request = self.request.module.operation,
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
            evaluator: *Unit,
            transfer: *@FieldType(State, "transfer"),
            descriptor: *const native_abi.Descriptor,
        ) MachineError!WorkProgress {
            const loader_authority = evaluator.inherited.runtime().native_loader;
            const loader = switch (loader_authority.startStatic(self.request.module.name, descriptor)) {
                .failure => |failure| {
                    const failed = evaluator.fail(.io, failure.text());
                    evaluator.pendingFailure().addData(.path, transfer.path.borrow());
                    return failed;
                },
                .loading => |loading| loading,
            };
            const next = NativeLoadDriver{
                .name = self.request.module.name,
                .request = self.request.module.operation,
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
            evaluator: *Unit,
            transfer: *@FieldType(State, "transfer"),
        ) MachineError!WorkProgress {
            const loader_authority = evaluator.inherited.runtime().native_loader;
            const start = try loader_authority.startDynamic(
                self.request.module.name,
                transfer.candidate.borrow(),
            );
            const loader = switch (start) {
                .failure => |failure| {
                    const failed = evaluator.fail(.io, failure.text());
                    evaluator.pendingFailure().addData(.path, transfer.path.borrow());
                    return failed;
                },
                .loading => |loading| loading,
            };
            const next = NativeLoadDriver{
                .name = self.request.module.name,
                .request = self.request.module.operation,
                .provenance = if (transfer.disposition.native) |id| .{ .source = evaluator.inherited.module_snapshot.?.sourceScope(id) } else .ordinary,
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
        commit: ?heap.Owned(modules.Registry.RegistrationCursor) = null,

        pub fn advance(evaluator: *Unit, self: *BuiltinLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            if (self.commit == null) {
                switch (self.publication.borrowMut().advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidName => return evaluator.fail(
                        .contract,
                        "builtin module declares an invalid word name",
                    ),
                }) {
                    .pending => return .stepped,
                    .complete => |candidate| {
                        var built = candidate;
                        defer built.deinit();
                        const sealed = built.sealLiteralGroup() catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.Duplicate, error.UnboundWord => return evaluator.fail(
                                .contract,
                                "builtin module declares an invalid word",
                            ),
                        };
                        self.commit = .init(evaluator.inherited.registry.registrationCursor(sealed));
                        return .stepped;
                    },
                }
            }
            switch (self.commit.?.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return evaluator.failFmt(
                    .io,
                    "cannot publish builtin module `{s}`: {s}",
                    .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
                ),
            }) {
                .pending => return .stepped,
                .complete => {},
            }
            self.commit.?.deinit(evaluator.releases, evaluator.allocator);
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
                cursor: heap.Owned(modules.Registry.RegistrationCursor),
            },
            published: struct {
                instance: heap.Owned(*native_module.ModuleInstance),
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
                        commit.instance.deinit(releases, storage_allocator);
                    },
                    .published => |*published| published.instance.deinit(releases, storage_allocator),
                }
                self.* = undefined;
            }
        };

        fn failLoad(self: *NativeLoadDriver, evaluator: *Unit, message: []const u8) MachineError {
            const failure = evaluator.fail(.io, message);
            evaluator.pendingFailure().addData(.path, self.path.borrow());
            return failure;
        }

        pub fn advance(evaluator: *Unit, self: *NativeLoadDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            switch (self.state.borrowMut().*) {
                .validate => |*loader| switch (try loader.borrowMut().advance(evaluator.workBudget())) {
                    .pending => return .stepped,
                    .failure => |failure| return self.failLoad(evaluator, failure.text()),
                    .loaded => |instance| {
                        loader.deinit(evaluator.releases, evaluator.allocator);
                        self.state.borrowMut().* = .{ .loaded = .init(instance) };
                        return .stepped;
                    },
                },
                .loaded => |*instance| {
                    const publication = try modules.Registry.NativeCandidateCursor.init(
                        evaluator.inherited.registry,
                        self.name,
                        self.provenance,
                        instance.borrow(),
                    );
                    self.state.borrowMut().* = .{ .definitions = .{
                        .instance = .init(instance.take()),
                        .publication = .init(publication),
                    } };
                    return .stepped;
                },
                .definitions => |*definitions| switch (try definitions.publication.borrowMut().advance()) {
                    .pending => return .stepped,
                    .complete => |candidate| {
                        // Sealing can fail; until it succeeds the instance and
                        // the publication stay with this driver's state.
                        var built = candidate;
                        defer built.deinit();
                        const sealed = built.sealLiteralGroup() catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.Duplicate, error.UnboundWord => return self.failLoad(evaluator, "native module declares an invalid word"),
                        };
                        const instance = definitions.instance.take();
                        definitions.publication.deinit(
                            evaluator.releases,
                            evaluator.allocator,
                        );
                        const cursor = evaluator.inherited.registry.registrationCursor(sealed);
                        self.state.borrowMut().* = .{ .commit = .{
                            .instance = .init(instance),
                            .cursor = .init(cursor),
                        } };
                        return .stepped;
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
                    .pending => return .stepped,
                    .complete => {
                        const next: State = .{ .published = .{
                            .instance = commit.instance,
                        } };
                        var cursor = commit.cursor;
                        self.state.borrowMut().* = next;
                        cursor.deinit(evaluator.releases, evaluator.allocator);
                        if (self.provenance == .source) evaluator.inherited.module_snapshot.?.commitArtifact(self.loading.borrowMut().artifactCommit());
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
    pub fn parseSourceOwned(self: *Unit, source: []u8) MachineError!void {
        const source_name = self.allocator.dupe(u8, "<parse>") catch |err| {
            self.allocator.free(source);
            return err;
        };
        try self.startDriver(SourceDriver{
            .text = .init(.{ .owned = .{ .source_name = source_name, .source = source } }),
            .completion = .init(.push),
        });
    }
    const SourceCompletion = union(enum) {
        push,
        call: ?*const map_state.SourceScope,
        session: ?*const map_state.SourceScope,
        /// Registration only: the source runs, then the loading lease and
        /// tagged qualified operation transfer to the return frame.
        register: struct {
            loading: ?modules.LoadingLease,
            path: ?Value,
            request: SourceLoadRequest,
            provenance: modules.RegistrationProvenance,
            artifact: ?map_state.ArtifactId,
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
        self: *Unit,
        source_name: []u8,
        source: []u8,
        completion: SourceCompletion,
    ) error{OutOfMemory}!void {
        try self.startDriver(SourceDriver{
            .text = .init(.{ .owned = .{ .source_name = source_name, .source = source } }),
            .completion = .init(completion),
        });
    }
    const SourceDriver = struct {
        const State = union(enum) {
            start,
            locating: map_state.SourcePathCursor,
            ingesting: spans.SpanArchive.SourceIngestCursor,
            activating: *Header,
            storage,
        };

        retirement: heap.ReleaseDomain.Retirement = .{},
        text: heap.Owned(SourceText),
        completion: heap.Owned(SourceCompletion),
        diag: reader.Diag = .{},
        state: State = .start,

        fn beginIngest(self: *SourceDriver, evaluator: *Unit) error{OutOfMemory}!void {
            const ingestion = try evaluator.archive.sourceIngestCursor(
                self.text.borrow().sourceName(),
                self.text.borrow().source(),
                &self.diag,
                try evaluator.rootLinker(evaluator.lexicalScope()),
            );
            self.state = .{ .ingesting = ingestion };
        }

        pub fn advance(evaluator: *Unit, self: *SourceDriver) MachineError!WorkProgress {
            // Preserve the established pre-cancelled-unit behavior for a
            // source that fits in its first bounded slice: activate it first,
            // so evaluation can attach cancellation to the responsible word.
            // A source that needs another slice observes cancellation before
            // doing any more ingestion work.
            if (self.state != .start) try evaluator.pollKernel();
            const work = evaluator.workBudget();
            while (work.spend()) switch (self.state) {
                .start => {
                    if ((self.completion.borrow() == .call or self.completion.borrow() == .session) and
                        evaluator.inherited.module_snapshot != null)
                    {
                        const cursor = try evaluator.inherited.module_snapshot.?.sourcePathCursor(self.text.borrow().sourceName());
                        self.state = .{ .locating = cursor };
                    } else try self.beginIngest(evaluator);
                },
                .locating => |*cursor| switch (cursor.advance()) {
                    .pending => {},
                    .complete => |source| {
                        cursor.deinit();
                        self.state = .start;
                        switch (self.completion.borrowMut().*) {
                            .call => |*context| context.* = source,
                            .session => |*context| context.* = source,
                            else => unreachable,
                        }
                        try self.beginIngest(evaluator);
                    },
                },
                .ingesting => |*ingestion| {
                    switch (ingestion.advance(work) catch |err| switch (err) {
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
                                    evaluator.finishIncomplete(value_incomplete);
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
                        .call, .session => |source| {
                            heap.incRef(root_header);
                            try evaluator.callProgramOwned(root_header, .incremental);
                            if (source) |context| {
                                evaluator.current.?.site.registration_provenance = .{ .source = context };
                            } else if (self.completion.borrow() == .call) {
                                evaluator.current.?.site.registration_provenance = .ordinary;
                            }
                        },
                        .register => |*register| {
                            var site = ExecutionSite.inheriting(
                                evaluator.current.?,
                                evaluator.current.?.scope(),
                            );
                            site.registration_provenance = register.provenance;
                            heap.incRef(root_header);
                            const preserves_caller = register.request.preservesCaller();
                            _ = (if (preserves_caller)
                                evaluator.suspendCurrentForQualifiedLoad()
                            else
                                evaluator.suspendCurrent()) catch {
                                evaluator.releases.releaseHeader(root_header);
                                return error.OutOfMemory;
                            };
                            var continuation = OwnedFrame.init(.{ .qualified_after_load = .{
                                .loading = register.loading.?.move(),
                                .path = register.path.?,
                                .request = register.request,
                                .artifact = .init(register.artifact),
                            } });
                            defer continuation.deinit(evaluator.releases, evaluator.allocator);
                            register.loading = null;
                            register.path = null;
                            evaluator.appendFrame(&continuation) catch {
                                evaluator.releases.releaseHeader(root_header);
                                return error.OutOfMemory;
                            };
                            evaluator.current = .{
                                .code = root_header,
                                .program = .incremental,
                                .position = .{ .source = 0 },
                                .site = site,
                                .traced_word = no_word,
                            };
                        },
                    }
                    return .completed;
                },
                .storage => unreachable,
            };
            return .stepped;
        }
        pub fn advanceRetirement(
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
            self: *SourceDriver,
        ) bool {
            return switch (self.state) {
                .locating => |*cursor| {
                    cursor.deinit();
                    self.state = .storage;
                    return false;
                },
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
    pub fn loadFileOwned(self: *Unit, path: []u8, path_value: Value) MachineError!void {
        return self.fileTransferOwned(path, path_value, .{ .source = .{ .call = null } });
    }
    fn fileSourceOwned(
        self: *Unit,
        path: []u8,
        path_value: ?Value,
        completion: SourceCompletion,
    ) MachineError!void {
        return self.fileTransferOwned(path, path_value, .{ .source = completion });
    }
    fn fileTransferOwned(
        self: *Unit,
        path: []u8,
        path_value: ?Value,
        transfer: FileTransfer,
    ) MachineError!void {
        try self.startDriver(FileSourceDriver{
            .allocator = self.allocator,
            .state = .init(.{ .open = .{
                .path = .init(path),
                .path_value = if (path_value) |item| .init(item) else null,
                .transfer = .init(transfer),
            } }),
        });
    }
    /// What one read file's bytes become. Module loading is the only client
    /// of this trusted host read; caller-selected file access goes through the
    /// capability-gated `fs` module instead.
    const FileTransfer = union(enum) {
        /// Hand the bytes to the reader as source text.
        source: SourceCompletion,

        pub fn deinit(self: *FileTransfer, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .source => |*completion| completion.deinit(releases),
            }
            self.* = undefined;
        }
        fn diagnosticPath(self: FileTransfer) ?Value {
            return switch (self) {
                .source => |completion| switch (completion) {
                    .register => |register| register.path,
                    .push, .call, .session => null,
                },
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
                }
            }
        };

        allocator: std.mem.Allocator,
        state: heap.Owned(State),

        fn diagnosticPath(context: *Context) ?Value {
            if (context.path_value) |*item| return item.borrow();
            return context.transfer.borrow().diagnosticPath();
        }
        fn failIo(context: *Context, evaluator: *Unit, message: []const u8) MachineError {
            const failure = evaluator.fail(.io, message);
            if (diagnosticPath(context)) |item| evaluator.pendingFailure().addData(.path, item);
            return failure;
        }
        pub fn advance(evaluator: *Unit, self: *FileSourceDriver) MachineError!WorkProgress {
            try evaluator.pollKernel();
            const io = evaluator.inherited.runtime().host_io;
            switch (self.state.borrowMut().*) {
                .open => |*context| {
                    const file = std.Io.Dir.cwd().openFile(io, context.path.borrow(), .{}) catch |err| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ context.path.borrow(), @errorName(err) },
                        );
                        if (diagnosticPath(context)) |item| evaluator.pendingFailure().addData(.path, item);
                        return failure;
                    };
                    self.state.borrowMut().* = .{ .size = .{
                        .context = context.move(),
                        .file = .init(.{ .io = io, .file = file }),
                    } };
                    return .stepped;
                },
                .size => |*size| {
                    const opened = size.file.borrow();
                    const stat = opened.file.stat(opened.io) catch |err| {
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ size.context.path.borrow(), @errorName(err) },
                        );
                        if (diagnosticPath(&size.context)) |item| evaluator.pendingFailure().addData(.path, item);
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
                    return .stepped;
                },
                .read => |*read| {
                    if (read.offset != read.source.borrow().len) {
                        const end = read.offset + evaluator.workBudget().take(read.source.borrow().len - read.offset);
                        const amount = read.reader.interface.readSliceShort(
                            read.source.borrow()[read.offset..end],
                        ) catch {
                            const name = if (read.reader.err) |err| @errorName(err) else "ReadFailed";
                            const failure = evaluator.failFmt(
                                .io,
                                "cannot read `{s}`: {s}",
                                .{ read.context.path.borrow(), name },
                            );
                            if (diagnosticPath(&read.context)) |item| evaluator.pendingFailure().addData(.path, item);
                            return failure;
                        };
                        if (amount == 0) return failIo(
                            &read.context,
                            evaluator,
                            "source file changed while being read",
                        );
                        read.offset += amount;
                        return .stepped;
                    }
                    const context = read.context.move();
                    const source = read.source.take();
                    read.file.deinit(evaluator.releases, evaluator.allocator);
                    self.state.borrowMut().* = .{ .transfer = .{
                        .context = context,
                        .source = .init(source),
                    } };
                    return .stepped;
                },
                .transfer => |*transfer| {
                    const path = transfer.context.path.take();
                    const source = transfer.source.take();
                    const completion = transfer.context.transfer.take().source;
                    evaluator.retireDriver(self);
                    try evaluator.sourceOwned(path, source, completion);
                    return .detached;
                },
                .complete => unreachable,
            }
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
    /// Records the offending path or url on the failure being raised, which is
    /// the shape every host-IO error reports. Keeps `ErrorDataKey` private
    /// while letting a builtin module attach the one datum it owns.
    pub fn addErrorPath(self: *Unit, path: Value) void {
        self.pendingFailure().addData(.path, path);
    }
    /// Tags the one absent-only publication conflict that an immutable
    /// caller may recover after independently confirming the winner.
    pub fn addErrorDestinationExists(self: *Unit) void {
        self.pendingFailure().addData(.@"destination-exists", .{ .int = 1 });
    }
    /// The stable data dictionary every capability-gated filesystem failure
    /// carries: the public operation, the named root and path (or both ends of
    /// a transfer), and a closed portable reason symbol.
    pub fn addErrorFilesystem(self: *Unit, data: FilesystemErrorData) void {
        const failure = self.pendingFailure();
        failure.addData(.operation, data.operation);
        switch (data.target) {
            .single => |single| {
                failure.addData(.root, single.root);
                failure.addData(.path, single.path);
            },
            .transfer => |transfer| {
                failure.addData(.@"source-root", transfer.source_root);
                failure.addData(.@"source-path", transfer.source_path);
                failure.addData(.@"destination-root", transfer.destination_root);
                failure.addData(.@"destination-path", transfer.destination_path);
            },
        }
        failure.addData(.reason, data.reason);
    }
    /// Attach the closed-vocabulary `'reason` symbol a capability refusal
    /// reports, so programs branch on the symbol rather than the message.
    pub fn addErrorReason(self: *Unit, reason: Value) void {
        self.pendingFailure().addData(.reason, reason);
    }
    /// The one absence-is-absence failure for `getenv`: an unset variable is
    /// an error carrying the requested name, never an empty string.
    pub fn unsetEnvironVariable(
        self: *Unit,
        name: []const u8,
        name_value: Value,
    ) MachineError {
        const failure = self.failFmt(.io, "environment variable `{s}` is not set", .{name});
        self.pendingFailure().addData(.name, name_value);
        return failure;
    }
    /// Resolves one environment variable against the session snapshot.
    pub fn environLookup(self: *Unit, name: []const u8) Environ.LookupCursor {
        const entries: []const Environ.Entry =
            self.inherited.runtime().environ.entries;
        return .{ .entries = entries, .name = name };
    }
    pub fn undefinedModule(self: *Unit, name: u32) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined module `{s}`", .{intern.get(name)});
        self.pendingFailure().addData(.name, .{ .symbol = .{ .name = name } });
        return failure;
    }
    /// A resolution miss, reported as the reference the program actually
    /// wrote, including a dotted one whose module never loaded, with the
    /// lookup chain that was searched.
    pub fn undefinedWordIn(self: *Unit, word: u32, chain: LookupChain) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(word)});
        self.pendingFailure().addData(.name, .{ .symbol = .{ .name = word } });
        self.addLookupChain(chain) catch return error.OutOfMemory;
        return failure;
    }
    /// The same failure as `undefinedWordIn`, for a name that is not the word
    /// currently being traced: the active word becomes the requested name so
    /// the diagnostic reports what was asked for.
    pub fn undefinedNameIn(self: *Unit, name: u32, chain: LookupChain) MachineError {
        self.active_word = .plain(name);
        return self.undefinedWordIn(name, chain);
    }
    fn addLookupChain(self: *Unit, chain: LookupChain) error{OutOfMemory}!void {
        const named = try intern.intern(chain.spelling());
        self.pendingFailure().addData(.scope, .{ .symbol = .{ .name = named } });
    }
    pub fn available(self: *const Unit) usize {
        return self.stack.items.len - self.stack_base;
    }
    pub inline fn require(self: *Unit, count: usize) MachineError!void {
        if (self.available() < count) return self.failUnderflow(count);
    }
    noinline fn failUnderflow(self: *Unit, count: usize) MachineError {
        @branchHint(.cold);
        return self.failUnderflowOf(self.activeWordName(), count);
    }
    /// A locals binder that cannot take its values. The reader lowered it into
    /// the reserved `_ll`, which names nothing a program wrote. Opening a
    /// word's body, the binder is that word's arity check, so the word fails
    /// as a primitive would: it is the failing word, and its body activation,
    /// which never got past entry, is not repeated in the trace. Opening any
    /// other quotation, there is no word to blame, and the binding itself is
    /// what fails.
    noinline fn failBinding(self: *Unit, count: usize) MachineError {
        @branchHint(.cold);
        const current = &self.current.?;
        const owner = current.body_owner;
        self.active_word = owner;
        if (owner == no_word) return self.failUnderflowOf("local binding", count);
        current.traced_word = no_word;
        return self.failUnderflowOf(self.activeWordName(), count);
    }
    fn failUnderflowOf(self: *Unit, subject: []const u8, count: usize) MachineError {
        // Underflow against the floor of a unit constructor's substack is the
        // one underflow whose cause is invisible: the values the caller meant
        // to pass are right there and unreachable. Name the isolation and the
        // seeding remedy rather than reporting a bare shortfall.
        const isolation = self.isolationGuidance();
        const failure = if (isolation) |guidance| self.failFmt(
            .underflow,
            "{s} needs {d} stack value{s}, but found {d}; {s}",
            .{
                subject,
                count,
                if (count == 1) "" else "s",
                self.available(),
                guidance.advice,
            },
        ) else self.failFmt(
            .underflow,
            "{s} needs {d} stack value{s}, but found {d}",
            .{
                subject,
                count,
                if (count == 1) "" else "s",
                self.available(),
            },
        );
        self.pendingFailure().addData(.needed, .{ .int = @intCast(count) });
        self.pendingFailure().addData(.available, .{ .int = @intCast(self.available()) });
        if (isolation) |guidance| self.pendingFailure().addData(
            .isolation,
            .{ .symbol = .{ .name = intern.intern(guidance.constructor) catch return failure } },
        );
        return failure;
    }
    const IsolationGuidance = struct { constructor: []const u8, advice: []const u8 };
    /// Which unit constructor, if any, owns the floor this underflow hit.
    fn isolationGuidance(self: *Unit) ?IsolationGuidance {
        if (self.stack_base > 0) {
            const boundary = self.boundary_index orelse return null;
            // During an unwind the index momentarily names the frame that was
            // just popped, so only bounds determine whether it may be read.
            const index: usize = @backingInt(boundary);
            if (index >= self.frames.items.len) return null;
            const frame = self.frames.items[index];
            if (frame != .boundary) return null;
            if (frame.boundary.stack_base != self.stack_base) return null;
            return switch (frame.boundary.mode) {
                .attempt => .{
                    .constructor = "@attempt",
                    .advice = "the substack is isolated from the caller's stack — " ++
                        "pass initial values in the constructor's values operand",
                },
                .module => .{
                    .constructor = "@defm",
                    .advice = "the substack is isolated from the caller's stack — " ++
                        "pass initial values in the constructor's values operand: `values (body) `name @defm`",
                },
            };
        }
        if (self.is_root_unit) return null;
        return switch (self.constructor) {
            .spawn => .{
                .constructor = "@spawn",
                .advice = "the child unit's stack is isolated from the caller's stack — " ++
                    "pass initial values in the constructor's values operand",
            },
            .@"test" => .{
                .constructor = "@test",
                .advice = "the test unit's stack is isolated from the runner stack",
            },
        };
    }
    pub fn popValue(self: *Unit) MachineError!heap.OwnedValue {
        try self.require(1);
        return .init(self.releases, self.takeStackOwned().?);
    }
    /// The top two operands, the lower first, after one underflow check.
    pub fn popPair(self: *Unit) MachineError!struct { heap.OwnedValue, heap.OwnedValue } {
        try self.require(2);
        const right = self.takeStackOwned().?;
        const left = self.takeStackOwned().?;
        return .{ .init(self.releases, left), .init(self.releases, right) };
    }
    fn popChecked(
        self: *Unit,
        comptime expected: []const u8,
        comptime accepts: fn (Value) bool,
    ) MachineError!heap.OwnedValue {
        var item = try self.popValue();
        errdefer item.deinit();
        if (!accepts(item.borrow())) return self.typeError(expected);
        return item;
    }
    pub fn popList(self: *Unit) MachineError!heap.OwnedValue {
        return self.popChecked("a list", struct {
            fn accepts(item: Value) bool {
                return item == .list;
            }
        }.accepts);
    }
    pub fn popDict(self: *Unit) MachineError!heap.OwnedValue {
        return self.popChecked("a dict", struct {
            fn accepts(item: Value) bool {
                return item == .dict;
            }
        }.accepts);
    }
    pub fn popQuotation(self: *Unit) MachineError!heap.OwnedValue {
        return self.popChecked("a quotation/list", struct {
            fn accepts(item: Value) bool {
                return item == .list;
            }
        }.accepts);
    }
    /// Pops the two inputs every unit constructor takes: a seed-values list
    /// followed by the construction body. The fixed arity keeps the exact body
    /// separate without a wrapper value. The returned owner takes both stack
    /// references directly; an empty seed list is released here and represented
    /// internally by null so an unseeded construction needs no materializer.
    pub fn popUnitInput(self: *Unit) MachineError!OwnedUnitInput {
        try self.require(2);
        var body = try self.popQuotation();
        errdefer body.deinit();
        var seeds = try self.popList();
        defer seeds.deinit();
        const seed_header = if (seeds.borrow().list.length() == 0)
            null
        else
            seeds.take().list;
        return OwnedUnitInput.init(seed_header, body.take().list);
    }
    /// The `!` constructors take no values operand: the input is exactly the
    /// empty-seed representation `[] body` would decode to.
    pub fn popSeedlessUnitInput(self: *Unit) MachineError!OwnedUnitInput {
        var body = try self.popQuotation();
        return OwnedUnitInput.init(null, body.take().list);
    }
    pub fn popString(self: *Unit) MachineError!heap.OwnedValue {
        return self.popChecked("a string", struct {
            fn accepts(item: Value) bool {
                return item.isString();
            }
        }.accepts);
    }
    /// A symbol operand with its link, as written: what an explicit lookup
    /// resolves in its own root.
    pub fn popWord(self: *Unit) MachineError!value.Symbol {
        var item = try self.popValue();
        defer item.deinit();
        return switch (item.borrow()) {
            .symbol => |word| .{ .name = word.name, .slot = env.unquoted(word.slot) },
            else => self.typeError("a symbol name"),
        };
    }
    pub fn popSymbol(self: *Unit) MachineError!u32 {
        var item = try self.popValue();
        defer item.deinit();
        return switch (item.borrow()) {
            .symbol => |name| name.name,
            else => self.typeError("a symbol name"),
        };
    }
    pub fn discard(self: *Unit, count: usize) void {
        std.debug.assert(self.available() >= count);
        for (0..count) |_| self.releases.releaseValue(self.takeStackOwned().?);
    }
    pub fn reserveStack(self: *Unit, count: usize) error{OutOfMemory}!StackReservation {
        try self.stack.ensureUnusedCapacity(self.allocator, count);
        return .init(self, count);
    }
    pub fn reserveStackReplacement(
        self: *Unit,
        input_count: usize,
        output_count: usize,
    ) error{OutOfMemory}!StackReplacement {
        std.debug.assert(self.available() >= input_count);
        const base = self.stack.items.len - input_count;
        try self.stack.ensureTotalCapacity(self.allocator, base + output_count);
        return .{
            .unit = self,
            .base = base,
            .input_count = input_count,
            .output_count = output_count,
        };
    }
    pub fn nativeInputBorrowed(self: *const Unit, input_count: usize, index: usize) Value {
        std.debug.assert(index < input_count and self.available() >= input_count);
        return self.stack.items[self.stack.items.len - input_count + index];
    }
    /// Observes one value in the currently visible operand window, bottom
    /// first. Checkpoint cursors retain the returned borrow before yielding;
    /// no raw stack storage escapes this boundary.
    pub fn visibleOperandBorrowed(self: *const Unit, index: usize) Value {
        std.debug.assert(index < self.available());
        return self.stack.items[self.stack_base + index];
    }
    /// Consumes `item`. The stack owns it on success; the release domain owns
    /// its constant-time retirement if stack growth fails.
    pub inline fn pushOwned(self: *Unit, item: Value) error{OutOfMemory}!void {
        // A push is a capacity test and a store; only growth is a call.
        const stack = &self.stack;
        if (stack.items.len == stack.capacity) return self.pushOwnedGrowing(item);
        stack.appendAssumeCapacity(item);
    }
    fn pushOwnedGrowing(self: *Unit, item: Value) error{OutOfMemory}!void {
        self.stack.append(self.allocator, item) catch {
            self.releases.releaseValue(item);
            return error.OutOfMemory;
        };
    }
    /// Consumes `item` into a slot this primitive freed by popping, which
    /// cannot grow the stack.
    pub fn pushIntoFreed(self: *Unit, item: Value) void {
        self.stack.appendAssumeCapacity(item);
    }
    pub fn pushBorrowed(self: *Unit, item: Value) error{OutOfMemory}!void {
        heap.retainValue(item);
        return self.pushOwned(item);
    }
    /// Places the pending failure at `code[index]`, the position the failing
    /// path ran in place of, unless an inner position already holds it.
    pub fn setFailureSite(self: *Unit, code: *Header, index: u32) void {
        if (self.pendingFailureOptional()) |pending| if (pending.site == null) {
            pending.site = .{ .token = .{ .code = code, .index = index } };
        };
    }
    pub fn setWorkDriverSite(self: *Unit, code: *Header, index: u32) void {
        if (self.workDriver()) |driver| driver.site = .{ .code = code, .index = index };
    }
    pub fn setWorkDriverTraceParent(self: *Unit, word: intern.TraceWord) void {
        if (self.workDriver()) |driver| driver.trace_parent = word;
    }

    /// Attributes the application the caller just began to `word`. A
    /// recognized idiom whose callback applies a quotation stands in for the
    /// source body frame that would otherwise have carried the word, so
    /// failures inside that quotation still trace through the word the caller
    /// wrote. Only the installing callback may claim an application this way:
    /// an unrelated enclosing application owns its own attribution.
    pub fn setApplicationTraceParent(self: *Unit, word: intern.TraceWord) void {
        const frame = &self.frames.items[self.frames.items.len - 1];
        std.debug.assert(frame.* == .application);
        frame.application.traced_word = word;
        self.current.?.traced_word = word;
    }

    /// The single parking choke point. A parked unit would hold its slot's
    /// turn across an unbounded wait, so a state application refuses to park
    /// here — before any wait — rather than in each parking word, which is
    /// what makes the prohibition total as new parking words are added.
    pub fn park(self: *Unit, request: ParkRequest) MachineError!void {
        self.installParkRequest(request);
    }

    /// Whether the words after a phrase head continue a recognized phrase,
    /// which then ran in its place.
    pub fn continuesPhrase(self: *Unit, first_entry: u16) MachineError!bool {
        return idioms.applyHeaded(self, first_entry);
    }
    /// The forms after the dispatching word in its own code, when it was
    /// dispatched from a source position and `count` of them follow. A word
    /// reached any other way (an invocation, a replay) has no phrase after it.
    pub fn followingForms(self: *const Unit, count: u32) ?FollowingForms {
        const current = self.current orelse return null;
        const next = switch (current.position) {
            .source => |index| index,
            .invocation, .replay, .redispatch => return null,
        };
        if (next == 0 or next - 1 != self.active_index) return null;
        if (@as(u64, next) + count > current.code.length()) return null;
        return .{ .code = current.code, .start = next };
    }
    pub const FollowingForms = struct {
        code: *Header,
        start: u32,

        pub fn at(self: FollowingForms, offset: u32) Value {
            return list.atUnchecked(.{ .list = self.code }, self.start + offset);
        }
    };
    /// Consumes `count` following forms that a recognized phrase executed.
    pub fn skipFollowingForms(self: *Unit, count: u32) void {
        const current = &self.current.?;
        current.position = .{ .source = current.position.source + count };
    }
    pub fn commitDirectIdiomTrace(self: *Unit) intern.TraceWord {
        const parent = self.active_word;
        if (self.current.?.nextIndex() >= self.current.?.code.length()) self.current.?.traced_word = no_word;
        return parent;
    }
    /// Traces the pending failure through `word`, the definition whose frame
    /// the failing path elided, unless an inner one already holds it.
    pub fn setFailureTraceParent(self: *Unit, word: intern.TraceWord) void {
        if (self.pendingFailureOptional()) |pending| if (pending.trace_parent == null) {
            pending.trace_parent = word;
        };
    }
    pub fn takePrimitiveFailure(self: *Unit) ?EclErr {
        if (!self.hasPendingFailure()) return null;
        const failure = self.takePendingForUnwind();
        self.finishUnwindCaught();
        return failure;
    }
    fn installPrimitiveFailure(self: *Unit, failure_value: EclErr) MachineError {
        self.installPendingFailure(failure_value);
        if (self.pendingFailure().word == null and self.active_word != no_word) {
            self.pendingFailure().word = self.active_word;
        }
        return error.Ecl;
    }
    pub fn continueWithIdiom(self: *Unit, request: IdiomRequest, source: FallbackSource) MachineError!void {
        return idioms.tryApply(self, request, source);
    }
    /// The active word as a diagnostic spells it. A module-local word has no
    /// single interned spelling, so the rendering borrows the unit's scratch;
    /// the returned slice is valid until the next call.
    pub fn activeWordName(self: *Unit) []const u8 {
        if (self.active_word == no_word) return "evaluation";
        return self.active_word.render(&self.word_scratch);
    }
    pub fn fail(self: *Unit, kind: ErrorKind, message: []const u8) MachineError {
        self.installPendingFailure(EclErr.init(kind, message));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        return error.Ecl;
    }
    /// Diagnostic views are bounded and capability-free. Retain their values
    /// before the observing driver releases its resource or exchange.
    pub fn failWithErrorData(self: *Unit, observation: @import("port_error_data.zig").Observation) MachineError {
        const report = switch (observation.report) {
            .out_of_memory => return error.OutOfMemory,
            .report => |report| report,
        };
        const failure = self.fail(report.kind, report.message[0..report.len]);
        const pending = self.pendingFailure();
        comptime {
            if (@import("port_error_data.zig").max_entries + 2 > @typeInfo(@FieldType(EclErr, "data")).array.len)
                @compileError("native diagnostics must reserve space for source diagnostics");
        }
        if (observation.details) |details| for (0..details.len()) |index| {
            const item = details.value(index);
            heap.retainValue(item);
            pending.data[pending.data_len] = .{ .key = .{ .symbol = details.key(index) }, .value = item };
            pending.data_len += 1;
        };
        return failure;
    }
    fn failAtSource(
        self: *Unit,
        message: []const u8,
        source_name: []const u8,
        span: reader.Span,
    ) MachineError {
        const owned_source_name = self.allocator.dupe(u8, source_name) catch
            return error.OutOfMemory;
        const failure = self.fail(.parse, message);
        self.pendingFailure().site = .{ .explicit_location = .{
            .source_name = owned_source_name,
            .span = span,
        } };
        return failure;
    }
    pub fn failFmt(
        self: *Unit,
        kind: ErrorKind,
        comptime format: []const u8,
        args: anytype,
    ) MachineError {
        self.installPendingFailure(EclErr.initFmt(kind, format, args));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        return error.Ecl;
    }
    pub fn typeError(self: *Unit, expected: []const u8) MachineError {
        return self.failFmt(
            .type,
            "{s} expected {s}",
            .{ self.activeWordName(), expected },
        );
    }
    /// Raises a language error at a zero-based logical data index. Kernels
    /// call this only after locating the first failing element.
    pub fn failAtIndex(
        self: *Unit,
        kind: ErrorKind,
        message: []const u8,
        index: usize,
    ) MachineError {
        const failure = self.fail(kind, message);
        self.pendingFailure().addData(.index, .{ .int = @intCast(index) });
        return failure;
    }
    /// Reports the two leading-axis lengths that failed to conform.
    pub fn conformError(self: *Unit, left: usize, right: usize) MachineError {
        const failure = self.failFmt(
            .conform,
            "{s} cannot conform leading axes {d} and {d}",
            .{ self.activeWordName(), left, right },
        );
        self.pendingFailure().addData(.left, .{ .int = @intCast(left) });
        self.pendingFailure().addData(.right, .{ .int = @intCast(right) });
        return failure;
    }
    pub fn applicationContractError(
        self: *Unit,
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
        self.pendingFailure().addData(.expected, expected);
        self.pendingFailure().addData(.seeded, .{ .int = @intCast(depths.seeded) });
        self.pendingFailure().addData(.observed, .{ .int = @intCast(depths.observed) });
        if (index) |element_index| {
            self.pendingFailure().addData(.index, .{ .int = @intCast(element_index) });
        }
        const site: *ApplicationSelection = @ptrCast(@alignCast(opaque_site));
        self.pendingFailure().site = .{ .contract_quotation = site.takeFailureSite(quotation) };
        return failure;
    }
    /// Kernel safe point. A flat loop calls this between bounded chunks;
    /// kernels never create threads or make scheduling decisions themselves.
    pub fn pollKernel(self: *Unit) MachineError!void {
        self.polls += 1;
        if (self.cancelled.load(.acquire)) {
            return self.fail(.cancelled, "unit cancelled");
        }
    }
    /// Charges logical kernel work against the unit's one budget for the turn.
    /// Keeping the remainder on Unit means ragged recursion and consecutive
    /// short loops cannot evade the 65,536-element cancellation bound by
    /// resetting a local index. Calls are bounded to one quantum; a block that
    /// reaches the boundary polls before executing and exhausts the turn.
    pub fn advanceKernel(self: *Unit, amount: usize) MachineError!void {
        _ = try self.chargeKernel(amount);
    }
    /// What a typed cursor may still charge before the interval ends. A loop
    /// bounds its next half-open range by this so the range it commits to is
    /// the range the budget can pay for, rather than discovering the boundary
    /// mid-chunk.
    pub fn remainingKernelFuel(self: *const Unit) usize {
        return self.kernel_budget.remaining;
    }
    /// The unit's kernel allowance for work done on its behalf in this turn.
    /// A cursor draws on it directly and hands the same pointer to any cursor
    /// it drives, so nested work cannot begin a quantum of its own. The
    /// machine settles exhaustion after the driver returns.
    /// The result for a step that may have installed a park request: the unit
    /// parks if it did, and otherwise has more of its own work to do.
    pub fn afterStep(self: *const Unit) WorkProgress {
        return if (self.hasParkRequest()) .{ .yielded = .park } else .stepped;
    }
    pub fn workBudget(self: *Unit) *poll_api.WorkBudget {
        return &self.kernel_budget;
    }
    /// A cancellable completion settles its last charge before transferring
    /// execution. Committed delivery and failure cleanup must not use this.
    pub fn pollCancellableCompletion(self: *Unit) MachineError!void {
        if (turn_core.completionPolls(self.workBudget().*)) try self.pollKernel();
    }
    /// Charges work that has already been committed, such as an inline kernel
    /// block that cannot stop part way. A charge that reaches the end of the
    /// turn's allowance polls cancellation and leaves the allowance exhausted:
    /// it never begins a second quantum within the same turn.
    fn chargeKernel(self: *Unit, amount: usize) MachineError!bool {
        std.debug.assert(amount <= kernel_poll_quantum);
        if (amount == 0) return false;
        if (comptime root_execution_metrics_enabled)
            self.root_execution_metrics.logical_transitions += amount;
        if (!turn_core.charge(&self.kernel_budget, amount)) return false;
        try self.pollKernel();
        return true;
    }
    /// Consumes a quotation header and applies it inline.
    /// Applies a quotation dynamically: it binds before it runs.
    pub fn callOwned(self: *Unit, quotation: *Header) error{OutOfMemory}!void {
        return self.callProgramOwned(quotation, .unbound);
    }

    /// Runs `quotation` inline with the caller, as an application that binds
    /// first or as top-level source resolved one form at a time.
    pub fn callProgramOwned(self: *Unit, quotation: *Header, program: Program) error{OutOfMemory}!void {
        std.debug.assert(program != .bound);
        const effect_tail = self.replaceTailEffectCandidate(quotation);
        const application_tail = self.tailApplicationIndex();
        if (application_tail) |application_index| {
            const frame = &self.frames.items[@backingInt(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(quotation);
        }
        const site = ExecutionSite.inheriting(self.current.?, self.current.?.scope());
        const inherited_trace = self.suspendCurrent() catch {
            self.releases.releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = quotation,
            .program = program,
            .position = .{ .source = 0 },
            .site = site,
            .traced_word = inherited_trace,
            .effect_tail = effect_tail,
            .application_tail = application_tail,
            .application_selection = application_tail,
        };
    }

    /// A completion contract follows authored tail control. Generic application
    /// machinery deliberately does not call this helper:
    /// their continuation restarts once per element and must not add a pair of
    /// code-header atomics to that hot path.
    fn replaceTailEffectCandidate(self: *Unit, code: *Header) ?EffectCheckIndex {
        const current = self.current orelse return null;
        const check_index = current.effect_tail orelse return null;
        if (!self.isSourceTailPosition(current)) return null;
        std.debug.assert(self.effect_check_index == check_index);
        const frame = &self.frames.items[@backingInt(check_index)];
        std.debug.assert(frame.* == .effect_check);
        frame.effect_check.replaceSourceCandidate(self.releases, code);
        return check_index;
    }

    /// Propagates one application's authority through ordinary tail word
    /// dispatch without changing its selected quotation. Only a dynamic
    /// `call` marks code for ownership transfer into the candidate.
    fn tailApplicationIndex(self: *Unit) ?ApplicationFrameIndex {
        const current = self.current orelse return null;
        const application_index = current.application_tail orelse return null;
        if (!self.isSourceTailPosition(current)) return null;
        return application_index;
    }

    fn validateApplicationProvenanceTarget(
        self: *Unit,
        target: *const ApplicationProvenanceTarget,
    ) ?ApplicationFrameIndex {
        const raw = @intFromPtr(target);
        const raw_index: u32 = @truncate(raw);
        const raw_nonce: u32 = @truncate(raw >> 32);
        if (raw_nonce == 0 or raw_index >= self.frames.items.len) return null;
        const index: ApplicationFrameIndex = @fromBackingInt(@intCast(raw_index));
        const frame = &self.frames.items[@backingInt(index)];
        if (frame.* != .application) return null;
        const nonce = frame.application.provenance_nonce orelse return null;
        if (@backingInt(nonce) != raw_nonce) return null;
        return index;
    }

    /// Captures the current tail-selection boundary for trusted control
    /// machinery that must suspend through bounded native work before it can
    /// launch the semantically selected quotation. The frame owns the nonce;
    /// relocation preserves it and frame retirement makes the handle stale.
    pub fn applicationProvenanceTarget(
        self: *Unit,
    ) error{OutOfMemory}!?*const ApplicationProvenanceTarget {
        const index = self.tailApplicationIndex() orelse return null;
        const frame = &self.frames.items[@backingInt(index)];
        std.debug.assert(frame.* == .application);
        if (frame.application.provenance_nonce == null)
            frame.application.provenance_nonce = try mintApplicationProvenanceNonce();
        return encodeApplicationProvenanceTarget(index, frame.application.provenance_nonce.?);
    }

    /// Consumes an exhausted Eval. A dynamically applied quotation moves its
    /// already-owned header into the application frame; every other Eval uses
    /// the ordinary release. This delays one existing release but creates no
    /// additional retain/release pair.
    fn retireCompletedEval(self: *Unit, current: Eval) void {
        if (current.application_selection) |application_index| {
            const frame = &self.frames.items[@backingInt(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.completeOwned(self.releases, current.intoCode(self.releases));
        } else {
            current.release(self.releases);
        }
    }

    /// Reader-lowered locals end in a `_dl` operation. That cleanup must run
    /// after the authored final form, but it does not make a final control
    /// transfer semantically non-tail. The exact reserved epilogue is the only
    /// continuation shape granted this exception.
    fn isSourceTailPosition(self: *const Unit, current: Eval) bool {
        const length = current.code.length();
        if (current.nextIndex() == length) return true;
        if (length - current.nextIndex() == 1) {
            const drop = list.atUnchecked(.{ .list = current.code }, current.nextIndex());
            if (drop != .symbol or drop.symbol.name != self.environment.localsWords().drop) return false;
            const count = env.localOperand(drop.symbol.slot) orelse return false;
            return count <= self.locals.items.len;
        }
        return false;
    }
    /// Starts one quotation application behind a base-index stack barrier.
    /// `application.context` is consumed on every path. Its callback either
    /// returns null (finished) or transfers that same ownership into the next
    /// application.
    pub fn beginIsolatedApplication(
        self: *Unit,
        application: IsolatedApplication,
    ) MachineError!void {
        return self.beginApplication(application, .isolated, null);
    }
    /// The inline counterpart keeps the current stack and scope visible with the same bounded,
    /// defunctionalized continuation representation.
    pub fn beginInlineApplication(
        self: *Unit,
        application: IsolatedApplication,
    ) MachineError!void {
        return self.beginApplication(application, .in_place, null);
    }
    const ApplicationLaunch = enum { in_place, isolated };
    /// Hands back an isolated application scope. One that never bound and is
    /// unshared is parked for the next application over the same parent rather
    /// than retired; anything else takes the ordinary path.
    fn beginApplication(
        self: *Unit,
        application: IsolatedApplication,
        launch: ApplicationLaunch,
        inherited: ?intern.TraceWord,
    ) MachineError!void {
        self.require(application.seeded) catch |err| {
            application.discard(self.releases, self.allocator);
            return err;
        };
        const base = StackWindow.init(self.stack.items.len, application.seeded) orelse unreachable;
        const provenance_target: ?ApplicationFrameIndex = switch (application.provenance) {
            .boundary => null,
            .selected_target => |target| self.validateApplicationProvenanceTarget(target) orelse {
                application.discard(self.releases, self.allocator);
                return self.fail(.domain, "application provenance target is stale or foreign");
            },
        };
        const select_initial = application.provenance != .boundary;
        var inherited_trace = inherited orelse no_word;
        if (self.current != null) {
            std.debug.assert(inherited == null);
            inherited_trace = self.suspendCurrent() catch {
                application.discard(self.releases, self.allocator);
                return error.OutOfMemory;
            };
        }
        const application_index: ApplicationFrameIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        var continuation = OwnedFrame.init(.{ .application = .{
            .context = application.context,
            .resume_fn = application.resume_fn,
            .deinit_fn = application.deinit_fn,
            .site = application.site,
            .mode = switch (launch) {
                .in_place => .{ .in_place = base },
                .isolated => .{ .isolated = .{
                    .previous_base = @fromBackingInt(@intCast(@as(u32, @intCast(self.stack_base)))),
                } },
            },
            .traced_word = inherited_trace,
            .selection = .{},
            .plan = application.plan,
            .bound = application.bound,
        } });
        defer continuation.deinit(self.releases, self.allocator);
        try self.appendFrame(&continuation);
        if (launch == .isolated) self.stack_base = base.base();
        if (select_initial) {
            const target = provenance_target.?;
            const frame = &self.frames.items[@backingInt(target)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(application.quotation);
        }
        // An executable this invocation already bound for the quotation is
        // reused; otherwise the application binds when it first runs.
        const program: Program = if (application.bound.find(application.quotation)) |code| reused: {
            break :reused .{ .borrowed = &code.executable };
        } else unbound: {
            heap.incRef(application.quotation);
            break :unbound .unbound;
        };
        self.current = .{
            .code = application.quotation,
            .program = program,
            .position = .{ .source = 0 },
            // An isolated body runs in its caller's scope but is not a root,
            // so nothing it calls may define there.
            .site = .resumed(
                application.site.parent_scope,
                application.site.home,
                application.site.registration_provenance,
                launch == .in_place and application.site.defining,
            ),
            .traced_word = inherited_trace,
            .application_tail = provenance_target orelse application_index,
            .application_selection = if (select_initial) provenance_target else null,
        };
    }
    pub fn attemptOwned(self: *Unit, input: OwnedUnitInput) error{OutOfMemory}!void {
        return self.beginAttemptOwned(input);
    }
    /// Opens a construction boundary for `@defm`. The name has already been
    /// validated; the body evaluates against a fresh image, and completion
    /// publishes that image under the name.
    pub fn moduleOwned(
        self: *Unit,
        name: intern.ModuleName,
        input: OwnedUnitInput,
    ) MachineError!void {
        var owned = input;
        defer owned.deinit(self.releases);
        const registry = self.inherited.registry;
        const word = self.active_word;
        const provenance = self.current.?.site.registration_provenance;
        var candidate = try registry.createImage(name, provenance);
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
        defer body.deinit(self.releases, self.allocator);
        const prepared = try self.archive.prepareConstructionBody(&body);
        switch (prepared) {
            .unchanged => |prepared_body| {
                var runnable = prepared_body;
                defer runnable.deinit(self.releases, self.allocator);
                if (owned.seedHeader() == null) {
                    return self.openImageBoundary(&candidate, word, runnable.take());
                }
                try self.startDriver(ConstructionDriver{
                    .state = .init(.{ .open = .{
                        .target = .init(.{ .image = candidate.move() }),
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
                const home = candidate.executionHome(self.module_access);
                const image_cell = try self.environment.scopeCell(
                    home.scope(self.module_access),
                    modules.anchorHandle(home, self.module_access),
                );
                var cursor = heap.Owned(spans.SpanArchive.RescopeCursor).init(
                    admission.?.begin(self.environment.linker(image_cell.id)),
                );
                admission = null;
                defer cursor.deinit(self.releases, self.allocator);
                try self.startDriver(ConstructionDriver{
                    .state = .init(.{ .rescope = .{
                        .target = .init(.{ .image = candidate.move() }),
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
        self: *Unit,
        candidate: *modules.OwnedImage,
        word: intern.TraceWord,
        body_header: *Header,
    ) MachineError!void {
        const home = candidate.executionHome(self.module_access);
        const site = ExecutionSite.image(home, self.module_access, true);
        _ = self.suspendCurrent() catch {
            self.releases.releaseHeader(body_header);
            return error.OutOfMemory;
        };
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body_header);
            return error.OutOfMemory;
        }
        try self.openBoundary(
            .{ .module = .{
                .image = candidate.move(),
                .root_code = body_header,
            } },
            @intCast(self.stack.items.len),
            word,
            body_header,
        );
        self.current = .{
            .code = body_header,
            .program = .unbound,
            .position = .{ .source = 0 },
            .site = site,
            .traced_word = no_word,
        };
    }
    /// The context a binding or explicit lookup resolves under, over `view`,
    /// which the context then owns.
    pub fn resolutionContext(self: *Unit, view: modules.View) binder.Context {
        return .{
            .environment = self.environment,
            .view = view,
            .module_access = self.module_access,
            .registry = self.inherited.registry,
            .project = self.inherited.module_snapshot,
            .libraries = self.inherited.libraries(),
            .provenance = self.current.?.site.registration_provenance,
        };
    }

    /// What a plain word resolves to now, for idiom recognition. Only a static
    /// definition outlives the lookup, and recognition only ever declines, so
    /// anything else is simply not a match.
    pub fn peekWord(self: *Unit, word: value.Symbol) ?PeekedWord {
        if (binder.executableWord(.{ .symbol = word }) == null) return null;
        var context = self.resolutionContext(self.inherited.registry.view());
        defer context.deinit();
        var resolver = binder.Resolver.init(&context, word);
        defer resolver.deinit();
        const definition = switch (poll_api.drive(binder.Outcome, &resolver, .{&context})) {
            .resolved => |found| found,
            .missed => return null,
        };
        if (definition.lifetime != .static) return null;
        const home = modules.definitionHome(definition);
        return .{
            .definition = definition,
            .trace_word = definitionTraceWord(definition, home, word.name),
            .origin = definitionOrigin(definition, home),
        };
    }

    /// The plan of the finite iteration applying the running code, when that
    /// code is the combinator's own quotation.
    fn applicationPlan(self: *Unit) ?*ResolutionPlan {
        const current = &self.current.?;
        const index = current.application_tail orelse return null;
        const plan = switch (self.frames.items[@backingInt(index)]) {
            .application => |application| application.plan orelse return null,
            else => return null,
        };
        return if (plan.code == current.code) plan else null;
    }

    /// The running finite iteration's entry for the position executing now,
    /// made on first use, or null when no plan applies.
    pub fn planEntry(self: *Unit) error{OutOfMemory}!?*PlanEntry {
        const plan = self.applicationPlan() orelse return null;
        return try plan.entry(self.allocator, self.active_index);
    }

    /// Runs a lowered locals operation: bind the top `operand` values, read
    /// local `operand`, or drop `operand` locals. The lowerer computed the
    /// operand, so the checks only guard a word built or moved by hand.
    fn localOperation(self: *Unit, name: u32, operand: u32) MachineError!void {
        const locals = self.environment.localsWords();
        self.active_word = .plain(name);
        if (name == locals.get) {
            if (operand >= self.locals.items.len) return self.fail(.domain, "_gl index is out of bounds");
            return self.readLocal(operand);
        }
        if (name == locals.load) {
            if (self.available() < operand) return self.failBinding(operand);
            return self.bindLocals(operand);
        }
        if (name == locals.drop) {
            if (operand > self.locals.items.len) return self.fail(.domain, "_dl count exceeds the live locals");
            return self.unbindLocals(operand);
        }
        return self.fail(.domain, "a locals operand on a word that is not a locals operation");
    }

    /// Runs an occurrence by explicit lookup, against the current publication
    /// view: incremental top-level source, `execute`, and a word resumed after
    /// loading. `dispatch` pushes a quoted occurrence instead, and `execute`
    /// strips the quote before calling here.
    pub fn executeWord(self: *Unit, word: value.Symbol) MachineError!void {
        std.debug.assert(!env.isQuoted(word.slot));
        if (env.localOperand(word.slot)) |operand| return self.localOperation(word.name, operand);
        self.active_word = .plain(word.name);
        if (self.inherited.phase != .bootstrap) {
            if (self.lookups.find(word, modules.currentPublication(), self.current.?.site.registration_provenance)) |definition|
                return invokeDefinition(self, definition, word.name);
        }
        const site: ?ErrorSite = if (self.current) |current| .{ .code = current.code, .index = self.active_index } else null;
        try self.startDriver(LookupDispatchDriver{
            .word = word,
            .site = site,
            .context = .init(self.resolutionContext(self.inherited.registry.view())),
            .resolver = .none,
        });
    }

    /// Starts binding the current evaluation, whose application has not run.
    /// An executable this application or this unit already bound for the same
    /// quotation in the same publication is reused instead.
    fn bindCurrent(self: *Unit) MachineError!void {
        const current = &self.current.?;
        std.debug.assert(current.program == .unbound);
        if (self.applicationExecutable(current.code)) |executable| {
            self.releases.releaseHeader(current.code);
            current.program = .{ .borrowed = executable };
            return;
        }
        if (self.reusableExecutable(current.code)) |code| {
            self.releases.releaseHeader(current.code);
            current.program = .{ .bound = &code.executable };
            return;
        }
        var context = self.resolutionContext(self.inherited.registry.view());
        const cursor = binder.BindingCursor.init(self.allocator, self.releases, current.code) catch |err| {
            context.deinit();
            return err;
        };
        try self.startDriver(BindingDriver{
            .context = .init(context),
            .cursor = .init(cursor),
        });
    }

    /// A retained executable for `code`, from the running application's own
    /// bindings or the unit's reuse cache.
    fn reusableExecutable(self: *Unit, code: *Header) ?*env.AnonymousCode {
        if (self.inherited.phase == .bootstrap) return null;
        return self.reuse.find(code, modules.currentPublication(), self.current.?.site.registration_provenance);
    }

    /// An executable the running application already bound for `code`,
    /// borrowed from its frame, which lives beneath the evaluation.
    fn applicationExecutable(self: *Unit, code: *Header) ?*const env.Executable {
        const index = self.current.?.application_tail orelse return null;
        return switch (self.frames.items[@backingInt(index)]) {
            .application => |*application| if (application.bound.find(code)) |found| &found.executable else null,
            else => null,
        };
    }

    /// Records a fresh binding where later applications of the same
    /// quotation will find it.
    fn rememberExecutable(self: *Unit, code: *env.AnonymousCode, publication: u64) void {
        if (self.current.?.application_tail) |index| {
            switch (self.frames.items[@backingInt(index)]) {
                .application => |*application| application.bound.remember(code),
                else => {},
            }
        }
        if (self.inherited.phase == .bootstrap) return;
        self.reuse.remember(self.releases, code, publication, self.current.?.site.registration_provenance);
    }

    /// The failure for a word that did not bind and will not after a load.
    pub fn failUnbound(self: *Unit, word: value.Symbol, miss: binder.Miss) MachineError {
        self.active_word = .plain(word.name);
        return switch (miss) {
            .unresolved => |chain| self.undefinedWordIn(word.name, chain),
            .unknown_module_prefix, .unregistered_module => self.undefinedWordIn(word.name, .qualified),
            .retired => self.failRetiredWord(word.name),
            .alias_cycle => self.failFmt(.domain, "the aliases from `{s}` never reach a definition", .{intern.get(word.name)}),
        };
    }

    /// A primitive consumed `operands` (owned, in stack order) before a word
    /// it binds turned out to need a module loaded. Restore them, rewind the
    /// primitive call, and run it again once the module is registered.
    pub fn retryWithOperandsAfterLoad(
        self: *Unit,
        operands: []const Value,
        word: value.Symbol,
        miss: binder.Miss,
    ) MachineError!WorkProgress {
        try self.restoreOperands(operands);
        self.current.?.rewind(self.active_index);
        const request = QualifiedLoadRequest{
            .qualified = word.name,
            .context = self.current.?.site.registration_provenance,
            .continuation = .replay,
        };
        switch (miss) {
            .unknown_module_prefix => |prefix| try self.startDriver(QualifiedLoadPreparationDriver.init(prefix, request, .none)),
            .unregistered_module => |name| try self.autoLoadModule(name, request),
            else => unreachable,
        }
        return .detached;
    }

    /// Consumes `operands` on success and allocation failure alike.
    fn restoreOperands(self: *Unit, operands: []const Value) error{OutOfMemory}!void {
        var reservation = self.reserveStack(operands.len) catch |err| {
            for (operands) |item| self.releases.releaseValue(item);
            return err;
        };
        for (operands) |item| reservation.pushOwned(item);
    }

    /// Fails a binding or lookup miss for `word`, starting a module load when
    /// one may make it resolvable. `continuation` says how to resume after the
    /// load: rebind the current evaluation, or dispatch the word again.
    fn missOrLoad(
        self: *Unit,
        word: value.Symbol,
        miss: binder.Miss,
        continuation: QualifiedLoadContinuation,
    ) MachineError!void {
        self.active_word = .plain(word.name);
        const request = QualifiedLoadRequest{
            .qualified = word.name,
            .context = self.current.?.site.registration_provenance,
            .continuation = continuation,
        };
        switch (miss) {
            .unknown_module_prefix => |prefix| try self.startDriver(QualifiedLoadPreparationDriver.init(
                prefix,
                request,
                .none,
            )),
            .unregistered_module => |name| try self.autoLoadModule(name, request),
            .unresolved, .retired, .alias_cycle => return self.failUnbound(word, miss),
        }
    }

    fn failRetiredWord(self: *Unit, name: u32) MachineError {
        self.active_word = .plain(name);
        return self.fail(.domain, "the scope this word was written in has retired");
    }

    pub fn raiseOwned(self: *Unit, raised: Value) MachineError {
        self.installPendingFailure(EclErr.init(.user, "raised error"));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        self.pendingFailure().raised = raised;
        return error.Ecl;
    }
    fn beginAttemptOwned(
        self: *Unit,
        input: OwnedUnitInput,
    ) error{OutOfMemory}!void {
        var owned = input;
        defer owned.deinit(self.releases);
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
            .word = self.active_word,
        });
    }
    /// Opens one `@attempt` boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure.
    fn openAttempt(self: *Unit, body: *Header) error{OutOfMemory}!void {
        const invoker = self.current.?;
        const word = self.active_word;
        _ = self.suspendCurrent() catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        }
        // The body runs in its invoker's scope but is not a root: nothing it
        // calls may define, so a failure has no definitions to discard.
        var site = ExecutionSite.inheriting(invoker, invoker.scope());
        site.defining = false;
        try self.openBoundary(
            .attempt,
            @intCast(self.stack.items.len),
            word,
            body,
        );
        self.current = .{
            .code = body,
            .program = .unbound,
            .position = .{ .source = 0 },
            .site = site,
            .traced_word = no_word,
        };
    }
    /// Opens one stack boundary: the frame recording where to return to, and
    /// the base its operands start from. The three boundary modes — a module
    /// body, a state application, and `@attempt` — differ in what they record
    /// and what runs inside them, never in how the boundary is opened. The
    /// caller keeps the frame-count check, because what it has to release on
    /// refusal differs; past that point failure releases the body here. A
    /// seed values are never handed in: they belong to the driver that
    /// materializes them after the boundary is open.
    fn openBoundary(
        self: *Unit,
        mode: BoundaryMode,
        stack_base: u32,
        word: intern.TraceWord,
        quotation: *Header,
    ) error{OutOfMemory}!void {
        const index: FrameIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        var continuation = OwnedFrame.init(.{ .boundary = .{
            .mode = mode,
            .stack_base = stack_base,
            .locals_base = @intCast(self.locals.items.len),
            .previous_base = @intCast(self.stack_base),
            .previous_boundary = self.boundary_index,
            .word = word,
        } });
        defer continuation.deinit(self.releases, self.allocator);
        self.appendFrame(&continuation) catch {
            self.releases.releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.boundary_index = index;
        self.stack_base = stack_base;
    }
    fn appendFrame(self: *Unit, owned: *OwnedFrame) error{OutOfMemory}!void {
        try self.frames.append(self.allocator, owned.frame.?);
        _ = owned.take();
        self.max_frames = @max(self.max_frames, self.frames.items.len);
    }
    /// Establishes completion before invoking foreign implementation code.
    /// The saved caller owns the source lifetime for the check's diagnostic
    /// site; the invocation activation supplies execution context but cannot
    /// dispatch the caller's next form. Drivers, parks, and nested quotations
    /// therefore finish before the ordinary frame resumer checks outputs.
    /// Allocation failure leaves the caller unchanged.
    fn beginInvocation(self: *Unit, effect: env.Effect, word: intern.TraceWord) MachineError!void {
        if (self.current.?.position == .redispatch) {
            const index = self.current.?.position.redispatch;
            self.current.?.position = .{ .invocation = index };
            return;
        }
        var check = try prepareEffectCheck(self, effect, word);
        try self.frames.ensureUnusedCapacity(self.allocator, 2);
        var caller = self.current.?;
        check.provenance = .{ .invocation = .{
            .code = caller.code,
            .index = self.active_index,
        } };
        var invocation = caller;
        invocation.position = .{ .invocation = caller.nextIndex() };
        invocation.traced_word = no_word;
        if (!self.isSourceTailPosition(caller)) {
            invocation.effect_tail = null;
            invocation.application_tail = null;
        }
        // Selection follows the invoked tail quotation. Resuming the caller
        // later must not overwrite that selection with its original body.
        caller.application_selection = null;
        invocation.retainCopy();
        self.frames.appendAssumeCapacity(.{ .eval = caller });
        self.frames.appendAssumeCapacity(.{ .effect_check = check });
        self.max_frames = @max(self.max_frames, self.frames.items.len);
        self.current = invocation;
    }
    /// Suspends a non-tail continuation. An exhausted anonymous quotation
    /// inherits its named trace owner so inline control does not erase the
    /// activation that selected it.
    fn suspendCurrent(self: *Unit) error{OutOfMemory}!intern.TraceWord {
        const current = &self.current.?;
        if (current.hasInstructions()) {
            // Built in place: an appended frame was a stack temporary copied
            // into the array.
            const frame = try self.frames.addOne(self.allocator);
            frame.* = .{ .eval = current.* };
            self.max_frames = @max(self.max_frames, self.frames.items.len);
            self.current = null;
            return no_word;
        }
        const inherited_trace = current.traced_word;
        self.retireCompletedEval(current.*);
        self.current = null;
        return inherited_trace;
    }
    /// A source-backed module load nests inside the requesting evaluation.
    /// Preserve even an exhausted caller: after publication the qualified
    /// request still needs its resolution scope, home, and continuation, and
    /// only the eventual dispatched word may consume the tail position.
    fn suspendCurrentForQualifiedLoad(self: *Unit) error{OutOfMemory}!intern.TraceWord {
        const current = self.current.?;
        try self.frames.append(self.allocator, .{ .eval = current });
        self.max_frames = @max(self.max_frames, self.frames.items.len);
        self.current = null;
        return no_word;
    }
};

/// Why a slice returned. `exhausted` means the turn's quantum ran out with
/// work still runnable: the unit can continue at once. `yielded` means it
/// stopped for something outside itself (a wait, settlement, unfinished
/// cleanup, or backpressure), so its executor should let other work run.
pub const RunStatus = enum { completed, exhausted, yielded, parked };

/// The decoded input every unit constructor takes. It remains the one nominal
/// owner through validation, child borrowing, fan-out transfer, and boundary
/// handoff. Empty seeds use the null representation; otherwise it owns both
/// list references. Moving it empties the source, and `deinit` is the sole
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
        return @fromBackingInt(@intCast(body_bits | (seed_bits << 64)));
    }

    fn bodyHeader(self: OwnedUnitInput) ?*Header {
        const bits = @backingInt(self) & pointer_mask;
        return if (bits == 0) null else @ptrFromInt(@as(usize, @intCast(bits)));
    }

    fn seedHeader(self: OwnedUnitInput) ?*Header {
        const bits = @backingInt(self) >> 64;
        return if (bits == 0) null else @ptrFromInt(@as(usize, @intCast(bits)));
    }

    /// The body, borrowed: the input stays alive until the scheduler has
    /// retained it and the initial operands into the new Unit, so a child
    /// launch never invents a second teardown protocol.
    pub fn quotation(self: *const OwnedUnitInput) *Header {
        std.debug.assert(self.* != .consumed);
        return self.bodyHeader().?;
    }

    pub fn initialStack(self: *const OwnedUnitInput, element: ?Value) InitialStack {
        std.debug.assert(self.* != .consumed);
        if (element) |item| {
            const seeds = self.seedHeader() orelse return .{ .borrowed_element = item };
            return .{ .borrowed_element_and_seeds = .{ .element = item, .seeds = seeds } };
        }
        const seeds = self.seedHeader() orelse return .empty;
        return .{ .borrowed_seeds = seeds };
    }

    pub fn move(self: *OwnedUnitInput) OwnedUnitInput {
        std.debug.assert(self.* != .consumed);
        const moved = self.*;
        self.* = .consumed;
        return moved;
    }

    fn takeBody(self: *OwnedUnitInput) *Header {
        const body = self.bodyHeader().?;
        const seed_bits = @backingInt(self.*) & ~pointer_mask;
        self.* = if (seed_bits == 0) .consumed else @fromBackingInt(@intCast(seed_bits));
        return body;
    }

    fn takeSeeds(self: *OwnedUnitInput) ?*Header {
        const seeds = self.seedHeader();
        const body_bits = @backingInt(self.*) & pointer_mask;
        self.* = if (body_bits == 0) .consumed else @fromBackingInt(@intCast(body_bits));
        return seeds;
    }

    pub fn deinit(self: *OwnedUnitInput, releases: *heap.ReleaseDomain) void {
        if (self.seedHeader()) |items| releases.releaseHeader(items);
        if (self.bodyHeader()) |body| releases.releaseHeader(body);
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
    /// Explicit seed values, in list order.
    borrowed_seeds: *Header,
    /// `@each` with shared seeds: the element deepest and the seeds above it.
    borrowed_element_and_seeds: struct { element: Value, seeds: *Header },
    /// `@give`'s moved ports deepest, then the explicit seed values. Both are
    /// materialized in bounded slices rather than concatenated up front.
    borrowed_pair: struct { deep: *Header, seeds: *Header },
};

/// Starts a unit on top-level source, which resolves one form at a time.
pub fn initialize(unit: *Unit, code: *Header, initial_stack: InitialStack) error{OutOfMemory}!void {
    return initializeProgram(unit, code, initial_stack, .incremental);
}

/// Starts a unit applying a quotation, which binds before it runs: a task's
/// body.
pub fn initializeApplication(unit: *Unit, code: *Header, initial_stack: InitialStack) error{OutOfMemory}!void {
    return initializeProgram(unit, code, initial_stack, .unbound);
}

fn initializeProgram(unit: *Unit, code: *Header, initial_stack: InitialStack, program: Program) error{OutOfMemory}!void {
    std.debug.assert(program != .bound);
    std.debug.assert(unit.frames.items.len == 0);
    std.debug.assert(unit.terminal == .evaluating);
    std.debug.assert(unit.current == null);
    if (initial_stack == .borrowed_pair) {
        const pair = initial_stack.borrowed_pair;
        heap.incRef(pair.deep);
        heap.incRef(pair.seeds);
        try unit.startDriver(ChildSeedDriver{
            .materializer = .init(.initPair(pair.deep, pair.seeds)),
        });
        heap.incRef(code);
        unit.current = .{
            .code = code,
            .program = program,
            .position = .{ .source = 0 },
            .site = .root(unit),
            .traced_word = no_word,
        };
        return;
    }
    const element: ?Value, const seeds: ?*Header = switch (initial_stack) {
        .empty => .{ null, null },
        .borrowed_element => |item| .{ item, null },
        .borrowed_seeds => |items| .{ null, items },
        .borrowed_element_and_seeds => |both| .{ both.element, both.seeds },
        .borrowed_pair => unreachable,
    };
    // One element is O(1) and goes on now, deepest. Explicit seeds are
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
        try unit.startDriver(ChildSeedDriver{
            .materializer = .init(.init(items)),
        });
    }
    heap.incRef(code);
    unit.current = .{
        .code = code,
        .program = program,
        .position = .{ .source = 0 },
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
    try unit.startDriver(Unit.SourceDriver{
        .text = .init(.{ .borrowed = .{ .source_name = source_name, .source = source } }),
        .completion = .init(.{ .session = null }),
    });
}

pub fn runSlice(unit: *Unit) MachineError!RunStatus {
    // Each turn begins with one full kernel quantum. The charge that exhausted
    // the previous one already polled cancellation, and every driver polls
    // before it draws.
    unit.kernel_budget = turn_core.beginTurn(kernel_poll_quantum);
    const status = loop(unit) catch |err| switch (err) {
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
            .exhausted, .yielded => {},
            .parked => unreachable,
        }
    }
}

fn loop(self: *Unit) MachineError!RunStatus {
    var first_step = true;
    while (true) {
        // Completion and output delivery may spend the last unit too. Never
        // enter another driver, continuation, or Eval with an empty allowance.
        if (!turn_core.mayDispatch(self.kernel_budget)) return .exhausted;
        // Admission reserves progress, not a whole instruction quantum of
        // allocation after pressure rises. Complete at least one transition
        // before yielding so a granted waiter cannot repeatedly lose its turn.
        // Cancellation must continue through failure and terminal cleanup.
        if (!first_step and !self.cancelled.load(.acquire) and
            self.releases.evaluationBackpressured()) return .yielded;
        first_step = false;
        switch (self.native) {
            // Nothing native is pending: no cleanup, resumption, park
            // request, or work driver precedes the next evaluation step.
            .idle => {},
            else => {
                if (self.native == .park_resume or self.native == .work_park_resume) {
                    resumePark(self) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Ecl => {
                            try startFailure(self);
                            continue;
                        },
                    };
                }
                if (self.hasParkRequest()) return .parked;
                if (self.workDriver()) |driver_ptr| {
                    const driver = driver_ptr.*;
                    if (comptime root_execution_metrics_enabled)
                        self.root_execution_metrics.driver_resumes += 1;
                    const progress = driver.advance(self) catch |err| {
                        // `setFailureSite`'s rule, spelled inline: calling it
                        // here grew the run loop's frame (fannkuch +0.08%).
                        if (err == error.Ecl and self.pendingFailure().site == null) {
                            if (driver.site) |site| self.pendingFailure().site = .{ .token = site };
                        }
                        if (err == error.Ecl) if (driver.trace_parent) |word| self.setFailureTraceParent(word);
                        clearWorkDriver(self);
                        switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.Ecl => {
                                try startFailure(self);
                                continue;
                            },
                        }
                    };
                    switch (progress) {
                        inline .stepped, .yielded => |_, tag| {
                            const outcome: turn_core.Outcome = switch (tag) {
                                .stepped => .stepped,
                                .yielded => .{ .yielded = progress.yielded },
                                else => comptime unreachable,
                            };
                            const decision = turn_core.afterDriver(
                                outcome,
                                &self.kernel_budget,
                                self.hasParkRequest(),
                            ) catch @panic("driver outcome contradicts its park request");
                            if (decision.poll_cancellation) self.pollKernel() catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                error.Ecl => {
                                    try startFailure(self);
                                    continue;
                                },
                            };
                            switch (decision.action) {
                                .resume_driver => continue,
                                .end_turn => return .exhausted,
                                .surrender => return .yielded,
                                .park => return .parked,
                            }
                        },
                        .completed => {
                            clearWorkDriver(self);
                            continue;
                        },
                        .output => |item| {
                            clearWorkDriver(self);
                            try self.pushOwned(item);
                            continue;
                        },
                        .reserved_output => |reserved| {
                            clearWorkDriver(self);
                            var destination = reserved.reservation;
                            destination.pushOwned(reserved.value);
                            continue;
                        },
                        // The driver destroyed and detached itself before invoking a
                        // continuation which may have installed its successor.
                        .detached => continue,
                        .failed => {
                            clearWorkDriver(self);
                            return error.Ecl;
                        },
                    }
                }
            },
        }
        if (self.hasRequestedExit()) {
            return .completed;
        }
        if (self.current == null) {
            const resumed = resumeFrames(self) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    try startFailure(self);
                    continue;
                },
            };
            if (!resumed) return .completed;
        }
        // Exhaustion is checked before another continuation, an owned driver,
        // or an exhausted Eval runs. A body that dispatched nothing spent its
        // fuel in its continuation.
        if (self.fuel == 0) {
            self.polls += 1;
            self.fuel = fuel_quantum;
            if (self.cancelled.load(.acquire)) {
                self.active_word = no_word;
                self.installPendingFailure(EclErr.init(.cancelled, "unit cancelled"));
                try startFailure(self);
                continue;
            }
            return .exhausted;
        }
        // A frame continuation may replace its native-stack tail with an
        // owned driver. Let that driver run before dispatching the parent
        // Eval which resumeFrames may also have restored.
        if (self.hasWorkDriver()) continue;
        const current = &self.current.?;
        // An application binds every top-level word before any of them runs.
        if (current.program == .unbound) {
            self.bindCurrent() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    try startFailure(self);
                    continue;
                },
            };
            continue;
        }
        const index = current.takeInstruction() orelse {
            self.retireCompletedEval(current.*);
            self.current = null;
            continue;
        };
        poll(self) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                try startFailure(self);
                continue;
            },
        };
        self.active_index = index;
        if (comptime root_execution_metrics_enabled)
            self.root_execution_metrics.logical_transitions += 1;
        // A bound word follows its fixed target; everything else is a form.
        const dispatched = if (current.program.executable()) |executable| bound: {
            if (executable.target(index)) |target| {
                const name = heap.valuesConst(current.code)[index].symbol.name;
                break :bound invokeDefinition(self, target, name);
            }
            break :bound dispatch(self, formAt(current.code, index));
        } else dispatch(self, formAt(current.code, index));
        dispatched catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                if (self.current) |failed| self.setFailureSite(failed.code, self.active_index);
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

fn resumePark(self: *Unit) MachineError!void {
    const delivery = self.takeParkResume().?;
    switch (delivery) {
        .task_wait => |wait| return resumeTaskWait(self, wait),
        .sleep => |sleep| {
            // Successful timer waits resume the driver that requested them,
            // just as successful external readiness waits do.
            if (sleep == .elapsed) return;
            // A work-driver park owns backend state across the wait. Move its
            // cleanup through the ordinary driver destructor before raising;
            // the failure unwinder requires that no native continuation still
            // owns the operands or external registration it is abandoning.
            clearWorkDriver(self);
            return switch (sleep) {
                .elapsed => unreachable,
                .cancelled => self.fail(.cancelled, "unit cancelled while sleeping"),
                .io => self.fail(.io, "could not start the scheduler timer service"),
                .overflow => self.fail(.overflow, "sleep deadline lies beyond the clock's range"),
                .out_of_memory => error.OutOfMemory,
            };
        },
        .external => |ready| switch (ready) {
            .wake => {},
            .timeout => {
                clearWorkDriver(self);
                return self.fail(.timeout, "host operation deadline expired");
            },
            .cancelled => {
                clearWorkDriver(self);
                return self.fail(.cancelled, "unit cancelled while awaiting host readiness");
            },
            .io => {
                clearWorkDriver(self);
                return self.fail(.io, "could not start a scheduler wait service");
            },
            .out_of_memory => {
                clearWorkDriver(self);
                return error.OutOfMemory;
            },
        },
        .mailbox => |ready| switch (ready) {
            .ready => {},
            .cancelled => {
                clearWorkDriver(self);
                return self.fail(.cancelled, "unit cancelled while awaiting a message");
            },
            .io => {
                clearWorkDriver(self);
                return self.fail(.io, "could not start a scheduler wait service");
            },
            .out_of_memory => {
                clearWorkDriver(self);
                return error.OutOfMemory;
            },
        },
        .scope_closed => |status| self.requestExit(status),
    }
}

fn resumeTaskWait(self: *Unit, wait: TaskWaitResume) MachineError!void {
    switch (wait) {
        .outcome => |outcome| try self.pushOwned(outcome),
        .indexed => |indexed| {
            var window = self.reserveStack(2) catch {
                self.releases.releaseValue(indexed.outcome);
                return error.OutOfMemory;
            };
            window.pushOwned(.{ .int = indexed.index });
            window.pushOwned(indexed.outcome);
        },
        .timeout => {
            clearWorkDriver(self);
            var timeout = EclErr.init(.timeout, "task wait timed out");
            defer timeout.retire(self.releases);
            const failure = try errorValue(
                self.allocator,
                self.releases,
                &timeout,
                .{},
                null,
            );
            try self.pushOwned(try outcomeDict(
                self.allocator,
                self.releases,
                "err",
                failure,
            ));
        },
        .cancelled => {
            clearWorkDriver(self);
            return self.fail(.cancelled, "unit cancelled while awaiting a task");
        },
        .io => {
            clearWorkDriver(self);
            return self.fail(.io, "could not start a scheduler wait service");
        },
        .overflow => {
            clearWorkDriver(self);
            return self.fail(.overflow, "task.await-for deadline lies beyond the clock's range");
        },
        .out_of_memory => {
            clearWorkDriver(self);
            return error.OutOfMemory;
        },
    }
}

/// The form at `index`. Code is nearly always a spine of forms; any other
/// list runs too.
fn formAt(code: *Header, index: u32) Value {
    return if (code.kind() == .generic_spine)
        heap.valuesConst(code)[index]
    else
        list.atUnchecked(.{ .list = code }, index);
}

fn poll(self: *Unit) MachineError!void {
    self.fuel -= 1;
}
inline fn dispatch(self: *Unit, form: Value) MachineError!void {
    const word = switch (form) {
        .symbol => |reference| reference,
        .int, .float, .char, .list, .dict, .task, .port, .address => return self.pushBorrowed(form),
    };
    // A quoted occurrence pushes its symbol, linked as written and unmarked:
    // the value `(x) first` pushes.
    if (env.isQuoted(word.slot))
        return self.pushBorrowed(.{ .symbol = .{ .name = word.name, .slot = env.unquoted(word.slot) } });
    try self.executeWord(word);
}

/// Runs a builtin under `trace_word`, translating its failure payload the one
/// way resolved execution does.
fn invokeBuiltin(self: *Unit, trace_word: intern.TraceWord, primitive: env.PrimitiveImpl) MachineError!void {
    self.active_word = trace_word;
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
}
/// Resolves one word against the current view and invokes what it finds.
const LookupDispatchDriver = struct {
    word: value.Symbol,
    site: ?ErrorSite,
    context: heap.Owned(binder.Context),
    resolver: heap.Owned(binder.Resolver),

    /// Started once per explicitly looked-up word, so it uses the inline slot.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;

    pub fn advance(evaluator: *Unit, self: *LookupDispatchDriver) MachineError!WorkProgress {
        if (!self.resolver.isPresent()) self.resolver = .init(binder.Resolver.init(self.context.borrowMut(), self.word));
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.resolver.borrowMut().advance(self.context.borrowMut())) {
            .pending => {},
            .complete => |outcome| {
                const word = self.word;
                switch (outcome) {
                    .resolved => |definition| {
                        // The view keeps a counted definition alive; hold it
                        // across the invocation, which retains what it keeps.
                        const counted = definition.lifetime == .counted;
                        if (counted) definition.retain();
                        defer if (counted) definition.release(evaluator.releases);
                        if (evaluator.inherited.phase != .bootstrap) evaluator.lookups.remember(
                            evaluator.releases,
                            word,
                            self.context.borrow().view.publication,
                            self.context.borrow().provenance,
                            definition,
                        );
                        evaluator.retireDriver(self);
                        try invokeDefinition(evaluator, definition, word.name);
                        return .detached;
                    },
                    .missed => |miss| {
                        const site = self.site;
                        evaluator.retireDriver(self);
                        try evaluator.missOrLoad(word, miss, .{ .dispatch = .{ .word = word, .site = site, .trace_parent = null } });
                        return .detached;
                    },
                }
            },
        };
        return .stepped;
    }
};

/// Binds the current evaluation's quotation before any of it runs. Success
/// seals an anonymous executable and resumes the evaluation bound to it; a
/// miss fails at the word it could not bind, having executed nothing, or
/// loads the module that may make it resolvable and binds again.
const BindingDriver = struct {
    context: heap.Owned(binder.Context),
    cursor: heap.Owned(binder.BindingCursor),

    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;

    pub fn advance(evaluator: *Unit, self: *BindingDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        const progress = try self.cursor.borrowMut().advance(self.context.borrowMut(), evaluator.workBudget());
        const result = switch (progress) {
            .pending => return .stepped,
            .complete => |result| result,
        };
        const publication = self.context.borrow().view.publication;
        switch (result) {
            .bound => |parts| {
                const code = env.AnonymousCode.create(evaluator.allocator, parts) catch |err| {
                    parts.discard(evaluator.releases, evaluator.allocator);
                    return err;
                };
                evaluator.retireDriver(self);
                const current = &evaluator.current.?;
                std.debug.assert(current.program == .unbound and current.code == code.executable.code);
                evaluator.releases.releaseHeader(current.code);
                current.program = .{ .bound = &code.executable };
                evaluator.rememberExecutable(code, publication);
                return .detached;
            },
            .failed => |failure| {
                const word = heap.valuesConst(self.cursor.borrow().code)[failure.index].symbol;
                const code = self.cursor.borrow().code;
                evaluator.retireDriver(self);
                evaluator.active_index = failure.index;
                evaluator.missOrLoad(word, failure.miss, .rebind) catch |err| {
                    if (err == error.Ecl) evaluator.setFailureSite(code, failure.index);
                    return err;
                };
                return .detached;
            },
        }
    }
};

/// Resumable boundary between a qualified miss and module loading. A prefix
/// absent from the intern table is external, runtime-sized input; preserving
/// this cursor as its own driver keeps both insertion and module-name
/// validation inside scheduler safe points.
const QualifiedLoadPreparationDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    const Restore = union(enum) {
        none,
        operand: value.Symbol,
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
        evaluator: *Unit,
        self: *QualifiedLoadPreparationDriver,
    ) MachineError!WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (try self.cursor.advance()) {
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
                        evaluator.current.?.rewind(evaluator.active_index);
                    },
                }
                evaluator.retireDriver(self);
                try evaluator.autoLoadModule(name, request);
                return .detached;
            },
        };
        return .stepped;
    }
};

/// After an auto-load, the requested module must actually be registered.
/// Checking that is what bounds the operation: a source that registered
/// nothing, or a different name, fails once here instead of starting another
/// load when its tagged continuation resumes.
fn continueSourceRequest(evaluator: *Unit, driver: anytype, request: SourceLoadRequest) MachineError!WorkProgress {
    return switch (request) {
        .source => .completed,
        .module => |module| continueQualifiedRequest(evaluator, driver, module.operation),
    };
}

fn continueQualifiedRequest(
    evaluator: *Unit,
    driver: anytype,
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    return switch (request.continuation) {
        .replay, .load_only, .rebind => .completed,
        .dispatch => |dispatch_request| continuation: {
            evaluator.retireDriver(driver);
            evaluator.active_word = .plain(dispatch_request.word.name);
            var context = evaluator.resolutionContext(evaluator.inherited.registry.view());
            context.provenance = request.context;
            try evaluator.startDriver(LookupDispatchDriver{
                .word = dispatch_request.word,
                .site = dispatch_request.site,
                .context = .init(context),
                .resolver = .none,
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
    evaluator: *Unit,
    driver: anytype,
    name: intern.ModuleName,
    loading: *heap.Owned(modules.LoadingLease),
    path: *heap.Owned(Value),
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    loading.borrowMut().finish();
    const registry = evaluator.inherited.registry;
    const next = QualifiedRegistrationDriver{
        .path = .init(path.take()),
        .acquisition = .init(registry.acquireCursor(name)),
        .request = .{ .module = .{ .name = name, .operation = request } },
    };
    evaluator.retireDriver(driver);
    try evaluator.startDriver(next);
    return .detached;
}

const QualifiedRegistrationDriver = struct {
    path: heap.Owned(Value),
    acquisition: heap.Owned(modules.Registry.AcquireCursor),
    request: SourceLoadRequest,
    loading: ?heap.Owned(modules.LoadingLease) = null,
    artifact: ?map_state.ArtifactId = null,
    module_index: usize = 0,

    pub fn advance(evaluator: *Unit, self: *QualifiedRegistrationDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        switch (self.acquisition.borrowMut().advance()) {
            .pending => return .stepped,
            .complete => |maybe_generation| {
                const checked_name = if (self.artifact) |artifact|
                    evaluator.inherited.module_snapshot.?.artifactModules(artifact)[self.module_index]
                else
                    self.request.module.name;
                const generation = maybe_generation orelse {
                    const failure = if (self.artifact != null)
                        evaluator.failFmt(
                            .io,
                            "loading mapped artifact registered nothing under declared module `{s}`",
                            .{intern.get(intern.moduleId(checked_name))},
                        )
                    else
                        evaluator.failFmt(
                            .io,
                            "loading module `{s}` registered nothing under that name",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                    evaluator.pendingFailure().addData(.path, self.path.borrow());
                    return failure;
                };
                var lease = generation;
                defer lease.deinit();
                if (self.artifact) |artifact| {
                    const expected_source = evaluator.inherited.module_snapshot.?.sourceScope(artifact);
                    const valid_origin = switch (lease.provenance()) {
                        .source => |source| source == expected_source,
                        .ordinary, .root_scope, .standard_library => false,
                    };
                    if (!valid_origin) {
                        const failure = evaluator.failFmt(
                            .domain,
                            "mapped artifact declared module `{s}` with foreign publication provenance",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                        evaluator.pendingFailure().addData(.path, self.path.borrow());
                        return failure;
                    }
                    const modules_in_artifact = evaluator.inherited.module_snapshot.?.artifactModules(artifact);
                    self.module_index += 1;
                    if (self.module_index != modules_in_artifact.len) {
                        self.acquisition.deinit(evaluator.releases, evaluator.allocator);
                        self.acquisition = .init(evaluator.inherited.registry.acquireCursor(
                            modules_in_artifact[self.module_index],
                        ));
                        return .stepped;
                    }
                    var artifact_lease = self.loading.?.borrowMut();
                    evaluator.inherited.module_snapshot.?.commitArtifact(
                        artifact_lease.artifactCommit(),
                    );
                    artifact_lease.finish();
                }
                return continueSourceRequest(evaluator, self, self.request);
            },
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

/// One explicit lookup of a supplied symbol, in the root its link names and
/// against the current view: what reflection and `execute` resolve.
pub const ExplicitLookup = struct {
    context: binder.Context,
    resolver: binder.Resolver,

    pub fn init(evaluator: *Unit, word: value.Symbol) ExplicitLookup {
        const context = evaluator.resolutionContext(evaluator.inherited.registry.view());
        return .{ .context = context, .resolver = binder.Resolver.init(&context, word) };
    }

    pub fn deinit(self: *ExplicitLookup) void {
        self.resolver.deinit();
        self.context.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *ExplicitLookup) binder.Progress {
        return self.resolver.advance(&self.context);
    }
};

/// A definition an explicit lookup selected, held while reflection reads it.
pub const Reflected = struct {
    definition: *env.Definition,
    trace_word: intern.TraceWord,
    home: ?*modules.ModuleHome,
    releases: *heap.ReleaseDomain,

    /// Holds a definition the lookup's view kept alive.
    pub fn hold(evaluator: *Unit, definition: *env.Definition, name: u32) Reflected {
        if (definition.lifetime == .counted) definition.retain();
        const home = modules.definitionHome(definition);
        return .{
            .definition = definition,
            .trace_word = definitionTraceWord(definition, home, name),
            .home = home,
            .releases = evaluator.releases,
        };
    }

    pub fn deinit(self: *Reflected) void {
        if (self.definition.lifetime == .counted) self.definition.release(self.releases);
        self.* = undefined;
    }

    /// The core definition this one shadows, if any: what `which` reports.
    pub fn shadows(self: *const Reflected, environment: *env.Env, name: u32) ?intern.TraceWord {
        if (self.definition.root == .core) return null;
        var cursor = environment.coreLookup(@fromBackingInt(name));
        const entry = poll_api.drive(?env.Entry, &cursor, .{}) orelse return null;
        return switch (entry) {
            .definition => |definition| if (definition != self.definition and definition.visibility == .public)
                .plain(name)
            else
                null,
            .alias => null,
        };
    }
};

/// What one definition is, as dispatch and recognition see it.
pub const PeekedWord = struct {
    definition: *env.Definition,
    trace_word: intern.TraceWord,
    origin: ResolutionOrigin,
};

pub const ResolutionOrigin = enum { direct, module, standard_library, core };

fn definitionOrigin(definition: *const env.Definition, home: ?*const modules.ModuleHome) ResolutionOrigin {
    if (home) |owner| return moduleResolutionOrigin(owner);
    return switch (definition.root) {
        .core => .core,
        .session, .image => .direct,
    };
}

/// How a call names a definition: a module-local one by its home's spelling,
/// anything else by the name the call used.
fn definitionTraceWord(definition: *const env.Definition, home: ?*const modules.ModuleHome, name: u32) intern.TraceWord {
    if (home) |owner| if (definition.traceWord()) |local| return homeTraceWord(owner, local);
    return .plain(name);
}

/// Invokes one fixed target. A module word's declared effect is a contract
/// checked where a call crosses into its module, except a standard-library
/// word's: its effects are reflective metadata, and its arity failures are
/// those of the code it runs.
fn invokeDefinition(self: *Unit, definition: *env.Definition, name: u32) MachineError!void {
    // A homeless builtin has no effect boundary and no recognition: the
    // common case, run directly.
    if (definition.home == null) switch (definition.body) {
        .builtin => |primitive| return invokeBuiltin(self, .plain(name), primitive),
        else => {},
    };
    const home = modules.definitionHome(definition);
    const trace_word = definitionTraceWord(definition, home, name);
    self.active_word = trace_word;
    const origin = definitionOrigin(definition, home);
    const cross_home = home != null and home != self.current.?.home();
    const checked = cross_home and origin != .standard_library;
    const cross_home_effect = if (checked) definition.effect else null;
    switch (definition.body) {
        .source => |*executable| {
            // A trusted definition's recognition was decided when its group
            // sealed; one that recognized nothing runs as any source word does.
            const trusted = origin == .core or origin == .standard_library;
            if (trusted) if (definition.direct_idiom) |idiom| {
                switch (try idioms.applyTrusted(self, .{ .body = executable.code, .idiom = idiom })) {
                    .applied => return,
                    .declined => {},
                    .offered => |request| {
                        const body_fallback: DirectWordFallback.Source = .{
                            .definition = definition,
                            .word = trace_word,
                            .effect = cross_home_effect,
                        };
                        return idioms.tryApply(self, request, body_fallback.source());
                    },
                }
            };
            try scheduleWord(self, executable, trace_word, home, cross_home_effect);
        },
        .builtin => |primitive| {
            // A declared effect is the called word's contract, so its check
            // names that word; a failure inside the builtin names it too.
            if (cross_home_effect) |effect| try self.beginInvocation(effect, trace_word);
            try invokeBuiltin(self, trace_word, primitive);
        },
        .native => |callable| {
            if (checked) {
                const effect = cross_home_effect orelse
                    return self.fail(.domain, "module word has no effect declaration");
                try self.beginInvocation(effect, trace_word);
            }
            try native_call.begin(self, callable);
        },
        .reserved => unreachable,
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

/// A trusted definition's body, run when a recognizer it offered declines.
/// Trusted definitions are static, so the fallback borrows the definition.
const DirectWordFallback = struct {
    definition: *env.Definition,
    word: intern.TraceWord,
    effect: ?heap.Owned(RetainedEffect),

    const Source = struct {
        definition: *env.Definition,
        word: intern.TraceWord,
        effect: ?env.Effect,

        fn source(self: *const Source) FallbackSource {
            return .{ .context = self, .make_fn = make };
        }

        fn make(context: ?*const anyopaque, _: *Unit) IdiomFallback {
            const self: *const Source = @ptrCast(@alignCast(context.?));
            std.debug.assert(self.definition.lifetime == .static);
            return typedIdiomFallback(DirectWordFallback{
                .definition = self.definition,
                .word = self.word,
                .effect = if (self.effect) |effect| .init(RetainedEffect.init(effect)) else null,
            });
        }
    };
    pub fn run(evaluator: *Unit, self: *DirectWordFallback) MachineError!void {
        return scheduleWord(
            evaluator,
            &self.definition.body.source,
            self.word,
            modules.definitionHome(self.definition),
            if (self.effect) |*owned| owned.borrow().effect else null,
        );
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

fn moduleResolutionOrigin(home: *const modules.ModuleHome) ResolutionOrigin {
    return switch (home.registrationProvenance()) {
        .ordinary => .module,
        .standard_library => .standard_library,
        .root_scope, .source => .module,
    };
}

/// How a module-local definition is spelled when reached through `home`: by
/// the name the image was built for, during construction as well as after.
fn homeTraceWord(home: *const modules.ModuleHome, local: intern.BindingName) intern.TraceWord {
    return .moduleLocal(home.name(), local);
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

    fn spelling(self: LookupChain) []const u8 {
        return switch (self) {
            .session => "session",
            .module => "module",
            .core => "core",
            .qualified => "qualified",
        };
    }
};

/// What one finite-iteration call has decided for a word position of its
/// quotation, kept for the rest of the call.
pub const PlanEntry = struct {
    /// For a word that offers a phrase to idiom recognition, the first phrase
    /// it offered in the call and what recognition made of it.
    offered: ?OfferedMatch = null,
};

/// The registry entry whose pattern an offered phrase matched, or none, with
/// what the match captured from the phrase. Whether the entry applies still
/// depends on each application's operands.
pub const OfferedMatch = struct {
    /// Which recognition the phrase was offered to: a dispatched word at one
    /// position may offer the same phrase to a different one.
    request: IdiomRequest,
    /// Retained, so a later phrase at the same address is this one.
    phrase: *Header,
    entry: ?u16,
    constant: ?Value,
    active_word: ?u32,
    active_index: ?u32,
};

/// The decisions one finite-iteration call has made for the words of its
/// quotation. A word's binding, and the idiom match of a phrase it was
/// offered, are decided at its first execution in the call and reused by every
/// later application, so the call is atomic under its bindings: a replacement
/// made while it runs takes effect at its next call.
pub const ResolutionPlan = struct {
    /// Borrowed: the combinator owns its quotation for the whole call.
    code: *Header,
    /// Allocated at the first entry.
    tree: ?*PlanTree = null,

    pub fn init(code: *Header) ResolutionPlan {
        return .{ .code = code };
    }

    /// The entry for word position `index`, made on first use.
    fn entry(self: *ResolutionPlan, allocator: std.mem.Allocator, index: u32) error{OutOfMemory}!*PlanEntry {
        const tree = self.tree orelse made: {
            const fresh = try allocator.create(PlanTree);
            fresh.* = .{ .allocator = allocator, .depth = PlanTree.depthFor(self.code.length()) };
            self.tree = fresh;
            break :made fresh;
        };
        return tree.entry(index);
    }

    /// Hands the entries to the release domain, which frees them a page or a
    /// node per turn.
    pub fn retire(self: *ResolutionPlan, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        const tree = self.tree orelse return;
        self.tree = null;
        releases.retire(tree, &tree.retirement);
    }
};

/// A plan's entries by word position: pages of `page_len` entries under
/// `fanout`-way nodes, as many levels as the quotation's length needs. Every
/// node and page is allocated and cleared, a constant amount of work, by the
/// first entry that needs it, so no step does work in proportion to the
/// quotation, and a plan has no capacity.
const PlanTree = struct {
    const page_bits = 4;
    const page_len = 1 << page_bits;
    const fanout_bits = 6;
    const fanout = 1 << fanout_bits;
    /// Enough levels for any u32 position.
    const max_depth = (32 - page_bits + fanout_bits - 1) / fanout_bits;
    const Page = [page_len]PlanEntry;
    /// A node one level above the pages holds pages; any higher node holds
    /// nodes.
    const Node = struct {
        nodes: [fanout]?*Node = @splat(null),
        pages: [fanout]?*Page = @splat(null),
    };

    allocator: std.mem.Allocator,
    /// Node levels above the pages: zero when one page covers the code.
    depth: u8,
    root_page: ?*Page = null,
    root_node: ?*Node = null,
    retirement: heap.ReleaseDomain.Retirement = .{},
    /// Retirement's descent, one node per level.
    // SAFETY: only the first `stack_len` frames are read, each written first.
    stack: [max_depth]struct { node: *Node, next: u8 } = undefined,
    stack_len: u8 = 0,
    retiring: bool = false,

    fn depthFor(length: u64) u8 {
        if (length <= page_len) return 0;
        const bits: u8 = @intCast(64 - @clz(length - 1));
        return @intCast((bits - page_bits + fanout_bits - 1) / fanout_bits);
    }

    fn page(self: *PlanTree, slot: *?*Page) error{OutOfMemory}!*Page {
        if (slot.*) |held| return held;
        const fresh = try self.allocator.create(Page);
        fresh.* = @splat(.{});
        slot.* = fresh;
        return fresh;
    }

    fn node(self: *PlanTree, slot: *?*Node) error{OutOfMemory}!*Node {
        if (slot.*) |held| return held;
        const fresh = try self.allocator.create(Node);
        fresh.* = .{};
        slot.* = fresh;
        return fresh;
    }

    fn entry(self: *PlanTree, index: u32) error{OutOfMemory}!*PlanEntry {
        const offset = index & (page_len - 1);
        if (self.depth == 0) return &(try self.page(&self.root_page))[offset];
        var current = try self.node(&self.root_node);
        var level = self.depth;
        while (level != 1) : (level -= 1) {
            const shift: u5 = @intCast(page_bits + fanout_bits * (level - 1));
            current = try self.node(&current.nodes[(index >> shift) & (fanout - 1)]);
        }
        return &(try self.page(&current.pages[(index >> page_bits) & (fanout - 1)]))[offset];
    }

    fn retirePage(self: *PlanTree, releases: *heap.ReleaseDomain, held: *Page) void {
        for (held) |*planned| {
            if (planned.offered) |offered| releases.releaseHeader(offered.phrase);
        }
        self.allocator.destroy(held);
    }

    /// One page or one node edge per call.
    pub fn advanceRetirement(releases: *heap.ReleaseDomain, _: std.mem.Allocator, self: *PlanTree) bool {
        if (!self.retiring) {
            self.retiring = true;
            if (self.root_page) |held| self.retirePage(releases, held);
            if (self.root_node) |held| {
                self.stack[0] = .{ .node = held, .next = 0 };
                self.stack_len = 1;
            }
            return false;
        }
        if (self.stack_len == 0) {
            self.allocator.destroy(self);
            return true;
        }
        const top = &self.stack[self.stack_len - 1];
        if (top.next == fanout) {
            self.allocator.destroy(top.node);
            self.stack_len -= 1;
            return false;
        }
        const child = top.next;
        top.next += 1;
        if (self.stack_len == self.depth) {
            if (top.node.pages[child]) |held| self.retirePage(releases, held);
        } else if (top.node.nodes[child]) |held| {
            self.stack[self.stack_len] = .{ .node = held, .next = 0 };
            self.stack_len += 1;
        }
        return false;
    }
};

/// One visibility boundary for named module observation. Private registrations
/// are searched only in the lexical source; public lookup never searches other
/// files' private registries, regardless of their load state.
pub const EmbeddedLibraries = union(enum) {
    bundled,
    registered: *native_module.Loader,
    fn find(self: EmbeddedLibraries, name: intern.ModuleName) ?stdlib.Entry {
        if (stdlib.find(intern.get(intern.moduleId(name)))) |entry| return entry;
        switch (self) {
            .bundled => {},
            .registered => |loader| if (loader.registeredDescriptor(name)) |descriptor| return .{ .native = descriptor },
        }
        return null;
    }
};

pub const ModuleLookupCursor = struct {
    registry: *modules.Registry,
    /// The captured view public lookups read, when the lookup belongs to one
    /// binding; a fresh snapshot otherwise.
    view: ?modules.View = null,
    libraries: EmbeddedLibraries,
    project: ?*const map_state.Snapshot,
    context: modules.RegistrationProvenance,
    name: intern.ModuleName,
    state: union(enum) {
        private: modules.Registry.AcquireCursor,
        catalog: map_state.LookupCursor,
        public: modules.Registry.AcquireCursor,
        complete,
    },
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    pub fn init(registry: *modules.Registry, project: ?*const map_state.Snapshot, libraries: EmbeddedLibraries, context: modules.RegistrationProvenance, name: intern.ModuleName) ModuleLookupCursor {
        var result: ModuleLookupCursor = .{ .registry = registry, .libraries = libraries, .project = project, .context = context, .name = name, .state = .complete };
        if (context.sourceScope()) |local| result.state = .{ .private = local.registry().acquireCursor(name) } else result.beginPublic();
        return result;
    }

    /// A lookup whose public registry reads come from `view`.
    pub fn initIn(view: *const modules.View, registry: *modules.Registry, project: ?*const map_state.Snapshot, libraries: EmbeddedLibraries, context: modules.RegistrationProvenance, name: intern.ModuleName) ModuleLookupCursor {
        var result: ModuleLookupCursor = .{ .registry = registry, .view = view.clone(), .libraries = libraries, .project = project, .context = context, .name = name, .state = .complete };
        if (context.sourceScope()) |local| result.state = .{ .private = local.registry().acquireCursor(name) } else result.beginPublic();
        return result;
    }

    fn publicCursor(self: *const ModuleLookupCursor) modules.Registry.AcquireCursor {
        if (self.view) |*captured| return captured.acquireCursor(self.name);
        return self.registry.acquireCursor(self.name);
    }

    pub fn atCurrent(evaluator: *Unit, name: intern.ModuleName) ModuleLookupCursor {
        return .init(evaluator.inherited.registry, evaluator.inherited.module_snapshot, evaluator.inherited.libraries(), evaluator.current.?.site.registration_provenance, name);
    }

    fn beginPublic(self: *ModuleLookupCursor) void {
        if (self.project) |project| {
            if (self.libraries.find(self.name) == null and
                !(if (self.context.sourceScope()) |source| source.exports(self.name) else false))
            {
                self.state = .{ .catalog = project.lookupCursor(self.context.scopeId(), intern.get(intern.moduleId(self.name))) };
                return;
            }
        }
        self.state = .{ .public = self.publicCursor() };
    }

    pub fn advance(self: *ModuleLookupCursor) poll_api.Progress(?modules.GenerationLease) {
        return switch (self.state) {
            .private => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |generation| result: {
                    cursor.deinit();
                    self.state = .complete;
                    if (generation) |lease| break :result .{ .complete = lease };
                    self.beginPublic();
                    break :result .pending;
                },
            },
            .catalog => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |outcome| result: {
                    cursor.deinit();
                    self.state = .complete;
                    if (outcome == .matched and self.project.?.artifactCommitted(outcome.matched.artifact_id)) {
                        self.state = .{ .public = self.publicCursor() };
                        break :result .pending;
                    }
                    break :result .{ .complete = null };
                },
            },
            .public => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .complete => |generation| result: {
                    cursor.deinit();
                    self.state = .complete;
                    break :result .{ .complete = generation };
                },
            },
            .complete => unreachable,
        };
    }

    pub fn deinit(self: *ModuleLookupCursor) void {
        switch (self.state) {
            .private, .public => |*cursor| cursor.deinit(),
            .catalog => |*cursor| cursor.deinit(),
            .complete => {},
        }
        if (self.view) |*captured| captured.deinit();
        self.* = undefined;
    }
};

fn scheduleWord(
    self: *Unit,
    executable: *const env.Executable,
    word: intern.TraceWord,
    resolved_home: ?*modules.ModuleHome,
    effect: ?env.Effect,
) MachineError!void {
    const scope = if (resolved_home) |home|
        home.scope(self.module_access)
    else
        self.current.?.scope();
    const home = resolved_home orelse self.current.?.home();
    const registration_provenance = if (resolved_home == null)
        self.current.?.site.registration_provenance
    else
        resolved_home.?.registrationProvenance();
    // A body defines where its caller could, and no further.
    const defining = self.current.?.site.defining;
    const check = if (effect != null) try prepareEffectCheck(self, effect, word) else null;
    return enterBody(self, executable, word, .{
        .scope = scope,
        .home = home,
        .defining = defining,
        .registration_provenance = registration_provenance,
    }, check);
}
/// Suspends the caller and makes `executable` the running evaluation at
/// `site`, under its effect check if it has one. The callee's owner is secured
/// before the caller can retire: in tail position the caller's executable may
/// hold the callee's last reference.
fn enterBody(self: *Unit, executable: *const env.Executable, word: intern.TraceWord, site: ExecutionSite, effect: ?EffectCheck) MachineError!void {
    var check = effect;
    executable.owner.retain();
    var entered = false;
    defer if (!entered) executable.owner.release(self.releases);
    var effect_tail = self.replaceTailEffectCandidate(executable.code);
    const application_tail = self.tailApplicationIndex();
    _ = self.suspendCurrent() catch return error.OutOfMemory;
    if (check) |*effect_check| {
        const check_index: EffectCheckIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        effect_check.activateSource(executable.code, check_index, self.effect_check_index);
        var continuation = OwnedFrame.init(.{ .effect_check = effect_check.* });
        defer continuation.deinit(self.releases, self.allocator);
        try self.appendFrame(&continuation);
        self.effect_check_index = check_index;
        effect_tail = check_index;
    }
    entered = true;
    self.current = .{
        .code = executable.code,
        .program = .{ .bound = executable },
        .position = .{ .source = 0 },
        .site = site,
        .traced_word = word,
        .body_owner = word,
        .effect_tail = effect_tail,
        .application_tail = application_tail,
    };
}
fn prepareEffectCheck(
    self: *Unit,
    effect: ?env.Effect,
    word: intern.TraceWord,
) MachineError!EffectCheck {
    const declared = effect orelse {
        self.active_word = word;
        return self.fail(.domain, "module word has no effect declaration");
    };
    const available: u32 = @intCast(self.available());
    if (available < declared.inputs) {
        self.active_word = word;
        const failure = self.failFmt(
            .contract,
            "{s} declared {d} input{s}, but found {d}",
            .{ self.activeWordName(), declared.inputs, if (declared.inputs == 1) "" else "s", available },
        );
        self.pendingFailure().addData(.seeded, .{ .int = available });
        self.pendingFailure().addData(.observed, .{ .int = available });
        return failure;
    }
    return .{
        .expected_depth = @intCast(self.stack.items.len - declared.inputs + declared.outputs),
        .entry_depth = available,
        .inputs = declared.inputs,
        .outputs = declared.outputs,
        .row = declared.row,
        .word = word,
    };
}
fn resumeFrames(self: *Unit) MachineError!bool {
    while (self.fuel != 0) switch (self.topFrameTag() orelse return false) {
        .eval => {
            const continuation = self.popFrame(.eval);
            self.current = continuation;
            return true;
        },
        .effect_check => {
            const owned = self.popFrame(.effect_check);
            var check = owned;
            defer check.deinit(self.releases);
            try finishEffectCheck(self, &check);
        },
        .application => {
            const continuation = self.popFrame(.application);
            var application_selection = continuation.selection;
            defer application_selection.deinit(self.releases);
            const launch: Unit.ApplicationLaunch, const base: StackWindow = switch (continuation.mode) {
                .in_place => |window| .{ .in_place, window },
                .isolated => |isolated| blk: {
                    const window: StackWindow = @fromBackingInt(@intCast(@as(u32, @intCast(self.stack_base))));
                    self.stack_base = isolated.previous_base.base();
                    break :blk .{ .isolated, window };
                },
            };
            if (comptime root_execution_metrics_enabled)
                self.root_execution_metrics.application_resumes += 1;
            var application_bound = continuation.bound;
            const next = continuation.resume_fn(
                self,
                continuation.context,
                base,
                @ptrCast(&application_selection),
            ) catch |err| {
                if (continuation.traced_word != no_word) {
                    self.setFailureTraceParent(continuation.traced_word);
                }
                application_bound.deinit(self.releases);
                continuation.deinit_fn(self.releases, self.allocator, continuation.context);
                return err;
            };
            if (next) |step| switch (step) {
                .apply => |application| {
                    try self.beginApplication(.{
                        .quotation = application.quotation,
                        .context = continuation.context,
                        .resume_fn = continuation.resume_fn,
                        .deinit_fn = continuation.deinit_fn,
                        .site = continuation.site,
                        .seeded = application.seeded,
                        .provenance = application.provenance,
                        .plan = continuation.plan,
                        .bound = application_bound,
                    }, launch, continuation.traced_word);
                    return true;
                },
                .suspend_inline => |suspension| {
                    const installed = self.workDriver() orelse {
                        application_bound.deinit(self.releases);
                        continuation.deinit_fn(
                            self.releases,
                            self.allocator,
                            continuation.context,
                        );
                        return self.fail(.domain, "application suspension has no installed work");
                    };
                    if (launch != .in_place or
                        @intFromPtr(suspension) != @intFromPtr(installed.context))
                    {
                        application_bound.deinit(self.releases);
                        continuation.deinit_fn(
                            self.releases,
                            self.allocator,
                            continuation.context,
                        );
                        clearWorkDriver(self);
                        return self.fail(.domain, "application suspension is stale or foreign");
                    }
                    var suspended = OwnedFrame.init(.{ .application = .{
                        .context = continuation.context,
                        .resume_fn = continuation.resume_fn,
                        .deinit_fn = continuation.deinit_fn,
                        .site = continuation.site,
                        .mode = .{ .in_place = base },
                        .traced_word = continuation.traced_word,
                        .selection = application_selection,
                        .provenance_nonce = continuation.provenance_nonce,
                        .plan = continuation.plan,
                        .bound = application_bound,
                    } });
                    application_selection = .{};
                    application_bound = .{};
                    defer suspended.deinit(self.releases, self.allocator);
                    try self.appendFrame(&suspended);
                    return true;
                },
            };
            application_bound.deinit(self.releases);
            continuation.deinit_fn(self.releases, self.allocator, continuation.context);
            // Native work installed by an application continuation is the
            // continuation's tail. Do not cross later continuation frames until
            // that owned work has produced its stack result. A continuation
            // that installed nothing has charged its fuel; the next frame is
            // resumed only while fuel remains.
            if (self.hasWorkDriver()) return true;
        },
        .qualified_after_load => {
            const continuation = self.popFrame(.qualified_after_load);
            var loading = continuation.loading;
            defer loading.deinit();
            var path = heap.OwnedValue.init(self.releases, continuation.path);
            defer path.deinit();
            // Source loading temporarily replaces the caller's evaluation.
            // Replay requests resume at their restored primitive operands;
            // dispatch requests resume the exact stored word without replay.
            if (continuation.request.preservesCaller()) {
                const caller = self.frames.pop().?;
                self.current = switch (caller) {
                    .eval => |evaluation| evaluation,
                    else => unreachable,
                };
            }
            // The registration check bounds the retry and gives every
            // transport the same post-load handoff.
            const registry = self.inherited.registry;
            const artifact = continuation.artifact.artifact();
            const first_name = if (artifact) |artifact_id| name: {
                const names = self.inherited.module_snapshot.?.artifactModules(artifact_id);
                if (names.len == 0) {
                    self.inherited.module_snapshot.?.commitArtifact(loading.artifactCommit());
                    loading.finish();
                    continue;
                }
                break :name names[0];
            } else continuation.request.module.name;
            if (artifact == null) loading.finish();
            try self.startDriver(QualifiedRegistrationDriver{
                .path = .init(path.take()),
                .acquisition = .init(registry.acquireCursor(first_name)),
                .request = continuation.request,
                .loading = if (artifact != null) .init(loading.move()) else null,
                .artifact = artifact,
            });
            return true;
        },
        .boundary => {
            if (self.frames.items[self.frames.items.len - 1].boundary.mode == .module) {
                // The image stays in its frame until it is sealed: binding the
                // group may load modules, which run above the frame.
                try startModuleSeal(self);
                return true;
            }
            const boundary = self.popFrame(.boundary);
            std.debug.assert(@backingInt(self.boundary_index.?) == self.frames.items.len);
            self.boundary_index = boundary.previous_boundary;
            self.stack_base = boundary.previous_base;
            self.active_word = boundary.word;
            switch (boundary.mode) {
                .attempt => {
                    defer boundary.deinit();
                    try finishAttempt(self, boundary.stack_base);
                    return true;
                },
                .module => unreachable,
            }
        },
    };
    // Even if this was the last frame, the evaluator must poll cancellation
    // and yield before reporting completion.
    return true;
}
fn finishEffectCheck(self: *Unit, check: *EffectCheck) MachineError!void {
    check.restoreActive(self);
    if (check.row) return;
    const observed = self.stack.items.len;
    if (observed == check.expected_depth) return;
    self.active_word = check.word;
    const observed_relative = observed - self.stack_base;
    const failure = self.failFmt(
        .contract,
        "{s} declared ({d} -- {d}); seeded {d}, observed {d}",
        .{ self.activeWordName(), check.inputs, check.outputs, check.entry_depth, observed_relative },
    );
    self.pendingFailure().addData(.seeded, .{ .int = check.entry_depth });
    self.pendingFailure().addData(.observed, .{ .int = @intCast(observed_relative) });
    if (check.provenance == .invocation)
        self.pendingFailure().site = .{ .token = check.provenance.invocation };
    if (check.takeCandidate()) |candidate|
        self.pendingFailure().site = .{ .contract_quotation = candidate };
    return failure;
}
fn finishAttempt(self: *Unit, base: u32) MachineError!void {
    try self.startDriver(AttemptResultDriver.init(
        self.allocator,
        base,
        self.stack.items[base..],
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
    pub fn advance(evaluator: *Unit, self: *AttemptResultDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .materialize => switch (try self.materializer.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |results| {
                    self.results = .init(results);
                    self.phase = .release;
                    return .stepped;
                },
            },
            .release => {
                if (evaluator.stack.items.len == self.base) {
                    self.phase = .outcome;
                    continue;
                }
                evaluator.releases.releaseValue(evaluator.stack.pop().?);
                _ = work.spend();
            },
            .outcome => {
                const results = self.results.?.take();
                self.results = null;
                const outcome = try outcomeDict(self.allocator, evaluator.releases, "ok", results);
                return .{ .output = outcome };
            },
        };
        return .stepped;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
/// Drives one registry publication, mapping its refusals to language errors.
fn advanceRegistration(
    evaluator: *Unit,
    cursor: *modules.Registry.RegistrationCursor,
) MachineError!WorkProgress {
    return switch (cursor.advance() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NameConflict => return evaluator.fail(.domain, "module name collides with an alias"),
        error.ReservedName => return evaluator.fail(.domain, "module name `core` is reserved for the core qualifier"),
    }) {
        .pending => .stepped,
        .complete => .completed,
    };
}

/// The one bounded owner/progress state for explicit seed materialization. Both an
/// in-machine construction boundary and a fresh child Unit embed this exact
/// state machine. Capacity for a granted slice is secured before its first
/// append, so allocation failure adds none of that slice; an earlier prefix is
/// ordinary stack ownership and retires with its boundary or Unit.
/// Materializes one or two seed lists onto a fresh child's stack in bounded
/// slices. `deep`, when present, is materialized first and therefore ends up
/// beneath `seeds`: `@give` uses it for the ports it moves, so no caller has
/// to build a concatenated list eagerly to seed a child.
const SeedMaterializer = struct {
    deep: ?heap.Owned(*Header) = null,
    seeds: heap.Owned(*Header),
    next: usize = 0,
    deep_done: bool = false,

    fn init(seeds: *Header) SeedMaterializer {
        return .{ .seeds = .init(seeds), .deep_done = true };
    }

    fn initPair(deep: *Header, seeds: *Header) SeedMaterializer {
        return .{ .deep = .init(deep), .seeds = .init(seeds) };
    }

    pub fn deinit(
        self: *SeedMaterializer,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.deep) |*deep| deep.deinit(releases, allocator);
        self.deep = null;
        self.seeds.deinit(releases, allocator);
        self.next = 0;
    }

    fn advance(
        self: *SeedMaterializer,
        unit: *Unit,
        work: *poll_api.WorkBudget,
    ) error{OutOfMemory}!bool {
        if (!self.deep_done) {
            if (!try self.copy(unit, self.deep.?.borrow(), work)) return false;
            self.deep_done = true;
            self.next = 0;
        }
        return self.copy(unit, self.seeds.borrow(), work);
    }

    fn copy(
        self: *SeedMaterializer,
        unit: *Unit,
        source: *Header,
        work: *poll_api.WorkBudget,
    ) error{OutOfMemory}!bool {
        const count: usize = @intCast(source.length());
        const end = self.next + work.take(count - self.next);
        try unit.stack.ensureUnusedCapacity(unit.allocator, end - self.next);
        for (self.next..end) |index| {
            const item = list.atUnchecked(.{ .list = source }, index);
            unit.stack.appendAssumeCapacity(item);
            heap.retainValue(item);
        }
        self.next = end;
        return self.next == count;
    }
};

/// What a `ConstructionDriver` opens once its body is final.
const ConstructionTarget = union(enum) {
    /// `@attempt`: a failure boundary in the invoker's scope.
    attempt,
    /// `@defm`: the candidate image, carrying its validated name and its
    /// constructing site's provenance.
    image: modules.OwnedImage,

    pub fn deinit(self: *ConstructionTarget) void {
        switch (self.*) {
            .attempt => {},
            .image => |*owned| owned.deinit(),
        }
        self.* = .attempt;
    }
};

/// The user-sized half of opening a unit: re-scoping a witnessed construction
/// body, and materializing explicit seed values onto the construction stack.
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

    pub fn advance(evaluator: *Unit, self: *ConstructionDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        switch (self.state.borrowMut().*) {
            .rescope => |*rescope| {
                const progress = rescope.cursor.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidProvenance => @panic("archive refused its own completed re-scope publication"),
                };
                const stamped = switch (progress) {
                    .pending => return .stepped,
                    .complete => |header| header,
                };
                rescope.cursor.deinit(evaluator.releases, evaluator.allocator);
                const next = @FieldType(State, "open"){
                    .target = .init(rescope.target.take()),
                    .body = .init(stamped),
                };
                self.state.borrowMut().* = .{ .open = next };
                return .stepped;
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
                    .image => |*owned| try evaluator.openImageBoundary(owned, self.word, body),
                }
                open.target.deinit(evaluator.releases, evaluator.allocator);
                self.state.borrowMut().* = .seed;
                return .stepped;
            },
            .seed => {
                // A construction that only had a body to re-scope reaches this
                // phase with nothing to seed, which is the whole of its work.
                if (self.materializer) |*materializer| {
                    if (!try materializer.borrowMut().advance(
                        evaluator,
                        evaluator.workBudget(),
                    )) return .stepped;
                }
                try evaluator.pollCancellableCompletion();
                return .completed;
            },
        }
    }
};

/// The child half of the same rule: a fresh Unit's own first slices put its
/// input's seeds on its stack, so a spawn never copies a user-sized seed list
/// inside the step that created it — and `@each` cannot multiply that copy by
/// the number of children it starts per turn.
const ChildSeedDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .fields;
    materializer: heap.Owned(SeedMaterializer),

    pub fn advance(evaluator: *Unit, self: *ChildSeedDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        if (try self.materializer.borrowMut().advance(
            evaluator,
            evaluator.workBudget(),
        )) {
            // An empty body has no later dispatch safe point. Settle the
            // final seed-copy charge before completion can retire this driver.
            try evaluator.pollCancellableCompletion();
            return .completed;
        }
        return .stepped;
    }
};

/// Begins sealing the module whose construction boundary is the top frame. A
/// module body defines words and keeps no state, so a residual operand window
/// is refused before anything is bound. Otherwise every staged body binds
/// against the complete group, and only once all of them have bound is any
/// sealed: a module load in between restarts the seal against a view that
/// holds the loaded module. A placeholder evaluation at the image's site is the
/// caller such a load suspends and returns to.
fn startModuleSeal(self: *Unit) MachineError!void {
    const frame = &self.frames.items[self.frames.items.len - 1].boundary;
    const observed = self.stack.items.len - frame.stack_base;
    if (observed != 0) {
        const boundary = self.popFrame(.boundary);
        self.boundary_index = boundary.previous_boundary;
        self.stack_base = boundary.previous_base;
        self.active_word = boundary.word;
        boundary.deinit();
        return self.failFmt(
            .domain,
            "@defm body left {d} value{s} on its stack; a module body defines words and keeps no state",
            .{ observed, if (observed == 1) "" else "s" },
        );
    }
    self.active_word = frame.word;
    const image = &frame.mode.module.image;
    const home = image.executionHome(self.module_access);
    const placeholder = try list.fromValuesGeneric(self.allocator, &.{});
    self.current = .{
        .code = placeholder.list,
        .program = .incremental,
        .position = .{ .source = 0 },
        .site = .image(home, self.module_access, false),
        .traced_word = no_word,
    };
    var context = self.resolutionContext(self.inherited.registry.view());
    context.group = .{
        .image_scope = home.scope(self.module_access).cellId(),
        .module = image.moduleName(),
        .directory = null,
    };
    try self.startDriver(ModuleSealDriver{
        .context = .init(context),
        .phase = .init(.{ .group = image.groupCursor() }),
        .pending = .init(.init(self.allocator)),
    });
}

/// What a word in a sealing group resolves to, against directories that can no
/// longer change: the group's own for a word written in its image, then core.
/// Words written anywhere else are not admitted.
const FrozenGroup = struct {
    environment: *env.Env,
    image_scope: ?env.ScopeId,
    directory: ?*const env.NameMap,

    fn resolve(context: *const anyopaque, word: value.Symbol) ?idioms.FrozenHit {
        const self: *const FrozenGroup = @ptrCast(@alignCast(context));
        const binding: intern.BindingName = @fromBackingInt(word.name);
        const own = switch (env.wordTarget(word.slot)) {
            .local => return null,
            .unlinked => false,
            .root => |id| own: {
                if (id == self.environment.coreScopeId()) break :own false;
                if (self.image_scope != null and id == self.image_scope.?) break :own true;
                return null;
            },
        };
        if (own) if (self.directory) |directory| {
            var cursor = directory.rawLookup(binding);
            if (poll_api.drive(?env.Entry, &cursor, .{})) |entry| switch (entry) {
                .definition => |definition| return .{ .definition = definition, .in_core = false },
                .alias => return null,
            };
        };
        var cursor = self.environment.coreLookup(binding);
        const entry = poll_api.drive(?env.Entry, &cursor, .{}) orelse return null;
        return switch (entry) {
            .definition => |definition| if (definition.visibility == .public) .{ .definition = definition, .in_core = true } else null,
            .alias => null,
        };
    }
};

/// Records recognition for a standard-library group's trusted definitions,
/// against bodies that are bound and directories that are sealed.
fn recognizeGroup(evaluator: *Unit, image: *modules.OwnedImage) void {
    const home = image.executionHome(evaluator.module_access);
    const frozen: FrozenGroup = .{
        .environment = evaluator.environment,
        .image_scope = home.scope(evaluator.module_access).cellId(),
        .directory = image.groupDirectory(),
    };
    const lookup: idioms.FrozenLookup = .{ .context = &frozen, .resolve_fn = FrozenGroup.resolve };
    for (idioms.direct_names) |spelling| {
        // A dotted spelling names one module's word; a plain one, any group's.
        const local = if (std.mem.lastIndexOfScalar(u8, spelling, '.')) |dot| local: {
            if (!std.mem.eql(u8, spelling[0..dot], intern.get(intern.moduleId(image.moduleName())))) continue;
            break :local spelling[dot + 1 ..];
        } else spelling;
        const id = intern.intern(local) catch continue;
        var cursor = image.groupDirectory().rawLookup(@fromBackingInt(id));
        const entry = poll_api.drive(?env.Entry, &cursor, .{}) orelse continue;
        const definition = switch (entry) {
            .definition => |definition| definition,
            .alias => continue,
        };
        if (definition.body != .source) continue;
        definition.direct_idiom = idioms.recognizeTrusted(lookup, spelling, definition);
    }
}

/// Records recognition for core's trusted definitions as core freezes.
pub fn recognizeCore(environment: env.Env, spelling: []const u8, definition: *env.Definition) void {
    var held = environment;
    const frozen: FrozenGroup = .{ .environment = &held, .image_scope = null, .directory = null };
    const lookup: idioms.FrozenLookup = .{ .context = &frozen, .resolve_fn = FrozenGroup.resolve };
    definition.direct_idiom = idioms.recognizeTrusted(lookup, spelling, definition);
}

/// One bound body awaiting the group's seal.
const PendingSeal = struct {
    definition: *env.Definition,
    parts: env.Executable.Parts,
};

/// The bound parts of a group not yet sealed. Discarding them leaves every
/// definition reserved, so a restarted seal binds the whole group again.
const PendingSeals = struct {
    allocator: std.mem.Allocator,
    items: poll_api.ChunkStack(PendingSeal),

    fn init(allocator: std.mem.Allocator) PendingSeals {
        return .{ .allocator = allocator, .items = .init(allocator) };
    }

    pub fn deinit(self: *PendingSeals, releases: *heap.ReleaseDomain) void {
        while (self.items.pop()) |pending| pending.parts.discard(releases, self.allocator);
        self.items.deinit();
    }
};

const ModuleSealDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    context: heap.Owned(binder.Context),
    phase: heap.Owned(Phase),
    pending: heap.Owned(PendingSeals),

    const Phase = union(enum) {
        group: modules.GroupCursor,
        bind: struct {
            entries: env.NameMap.RawEntryCursor,
            current: ?struct { definition: *env.Definition, cursor: binder.BindingCursor } = null,
        },
        seal,

        pub fn deinit(self: *Phase) void {
            switch (self.*) {
                .group => |*cursor| cursor.deinit(),
                .bind => |*bind| if (bind.current) |*current| current.cursor.deinit(),
                .seal => {},
            }
            self.* = undefined;
        }
    };

    fn image(evaluator: *Unit) *modules.OwnedImage {
        return &evaluator.frames.items[evaluator.frames.items.len - 1].boundary.mode.module.image;
    }

    pub fn advance(evaluator: *Unit, self: *ModuleSealDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.phase.borrowMut().*) {
            .group => |*cursor| switch (cursor.advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Duplicate => return evaluator.failFmt(
                    .domain,
                    "the name `{s}` is introduced more than once in this module",
                    .{intern.get(intern.bindingId(cursor.duplicate.?))},
                ),
            }) {
                .pending => {},
                .complete => {
                    const owned = image(evaluator);
                    self.context.borrowMut().group.?.directory = owned.groupDirectory();
                    cursor.deinit();
                    self.phase.borrowMut().* = .{ .bind = .{ .entries = owned.groupEntries() } };
                },
            },
            .bind => |*bind| {
                if (bind.current) |*current| {
                    const progress = try current.cursor.advance(self.context.borrowMut(), work);
                    const result = switch (progress) {
                        .pending => continue,
                        .complete => |result| result,
                    };
                    const definition = current.definition;
                    switch (result) {
                        .bound => |parts| {
                            current.cursor.deinit();
                            bind.current = null;
                            self.pending.borrowMut().items.push(.{ .definition = definition, .parts = parts }) catch |err| {
                                parts.discard(evaluator.releases, evaluator.allocator);
                                return err;
                            };
                        },
                        .failed => |failure| {
                            const code = definition.reservedBody();
                            const word = heap.valuesConst(code)[failure.index].symbol;
                            evaluator.retireDriver(self);
                            evaluator.missOrLoad(word, failure.miss, .load_only) catch |err| {
                                if (err == error.Ecl) evaluator.setFailureSite(code, failure.index);
                                return err;
                            };
                            return .detached;
                        },
                    }
                    continue;
                }
                switch (bind.entries.advance()) {
                    .pending => {},
                    .item => |entry| switch (entry.value) {
                        .definition => |definition| if (definition.body == .reserved) {
                            bind.current = .{
                                .definition = definition,
                                .cursor = try binder.BindingCursor.init(
                                    evaluator.allocator,
                                    evaluator.releases,
                                    definition.reservedBody(),
                                ),
                            };
                        },
                        .alias => {},
                    },
                    .complete => self.phase.borrowMut().* = .seal,
                }
            },
            .seal => {
                // Every body bound against one view; seal them together.
                if (self.pending.borrowMut().items.pop()) |pending| {
                    pending.definition.seal(evaluator.releases, pending.parts);
                    continue;
                }
                const owned = image(evaluator);
                const provenance = owned.provenance();
                const name = owned.moduleName();
                if (provenance == .standard_library) recognizeGroup(evaluator, owned);
                evaluator.retireDriver(self);
                releaseCurrent(evaluator);
                const boundary = evaluator.popFrame(.boundary);
                evaluator.boundary_index = boundary.previous_boundary;
                evaluator.stack_base = boundary.previous_base;
                evaluator.active_word = boundary.word;
                var built = boundary.mode.module.image;
                var sealed = heap.Owned(modules.SealedImage).init(built.seal());
                errdefer sealed.deinit(evaluator.releases, evaluator.allocator);
                const driver = try evaluator.allocator.create(ModuleCompletionDriver);
                // The cursor owns the sealed image from here; nothing can fail after.
                driver.* = .{
                    .cursor = .init(evaluator.publicationRegistry(name, provenance).registrationCursor(sealed.take())),
                };
                evaluator.adoptDriver(driver);
                return .detached;
            },
        };
        return .stepped;
    }
};

/// Publishes a sealed image through the registry as resumable work.
const ModuleCompletionDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .fields;
    cursor: heap.Owned(modules.Registry.RegistrationCursor),

    pub fn advance(evaluator: *Unit, self: *ModuleCompletionDriver) MachineError!WorkProgress {
        try evaluator.pollKernel();
        return advanceRegistration(evaluator, self.cursor.borrowMut());
    }
};
pub fn outcomeDict(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    name: []const u8,
    payload: Value,
) error{OutOfMemory}!Value {
    defer releases.releaseValue(payload);
    const key = try intern.intern(name);
    return dict.fromUniquePairs(allocator, releases, &.{.{ .{ .symbol = .{ .name = key } }, payload }});
}
fn startFailure(self: *Unit) error{OutOfMemory}!void {
    std.debug.assert(self.hasPendingFailure());
    // Failure entry owns the native tail too: it must be detached before the
    // frame unwinder can replace it with the failure driver.
    clearWorkDriver(self);
    const capacity = std.math.add(usize, self.frames.items.len, 3) catch
        return error.OutOfMemory;
    const trace = try self.allocator.alloc(intern.TraceWord, capacity);
    errdefer self.allocator.free(trace);
    const resolved = try self.allocator.alloc(u32, capacity);
    errdefer self.allocator.free(resolved);
    const driver = try self.allocator.create(FailureDriver);
    driver.* = .{
        .allocator = self.allocator,
        .failure = self.takePendingForUnwind(),
        .trace = trace,
        .resolved = resolved,
        .state = .{ .trace = self.frames.items.len },
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
                .caught => |caught| @as(usize, @backingInt(caught.boundary_index)) + 1,
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

    fn appendInitial(self: *FailureDriver, evaluator: *Unit) void {
        if (self.failure.word) |word| self.appendTrace(word);
        if (self.failure.trace_parent) |word| self.appendTrace(word);
        if (evaluator.current) |current|
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
    fn beginLocation(self: *FailureDriver, evaluator: *Unit) void {
        if (self.failure.site) |site| {
            switch (site) {
                .token => |token| {
                    self.state = .{ .locate = evaluator.archive.locateCursor(token.code, token.index) };
                },
                .contract_quotation => |candidate| {
                    self.state = .{ .locate = evaluator.archive.locateQuotationCursor(candidate.borrow()) };
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
    /// Draws on the unit's budget, but yields rather than stepping when it is
    /// spent: a stepped driver's charge can observe cancellation, and an
    /// unwind already in progress must not start another failure.
    pub fn advance(evaluator: *Unit, self: *FailureDriver) MachineError!WorkProgress {
        const work = evaluator.workBudget();
        while (switch (self.state) {
            .value, .outcome => !work.exhausted(),
            else => work.spend(),
        }) switch (self.state) {
            .trace => |*frame_index| {
                if (frame_index.* == 0) {
                    self.state = .{ .spell = 0 };
                    continue;
                }
                frame_index.* -= 1;
                switch (evaluator.frames.items[frame_index.*]) {
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
            .value => |*cursor| switch (try cursor.advance(work)) {
                .pending => return .{ .yielded = .settle },
                .complete => |item| {
                    cursor.retire(evaluator.releases);
                    self.state = .{ .nearest = .{
                        .error_value = item,
                        .boundary = evaluator.boundary_index,
                    } };
                },
            },
            .nearest => |*nearest| {
                const boundary_index = nearest.boundary orelse {
                    const item = nearest.error_value;
                    self.beginUnwind(item, .{ .uncaught = .{
                        .stack_base = evaluator.entry_base,
                    } });
                    continue;
                };
                const boundary = evaluator.frames.items[@backingInt(boundary_index)].boundary;
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
                if (evaluator.frames.items.len != unwind.target.frameTarget()) {
                    evaluator.deinitPoppedFrame(evaluator.frames.pop().?);
                } else {
                    const next = unwind.*;
                    self.state = .{ .boundary = next };
                }
            },
            .boundary => |*unwind| {
                if (unwind.target == .caught) {
                    evaluator.deinitPoppedFrame(evaluator.frames.pop().?);
                }
                const next = unwind.*;
                self.state = .{ .locals = next };
            },
            .locals => |*unwind| {
                const target = @min(unwind.target.localsTarget(), evaluator.locals.items.len);
                if (evaluator.locals.items.len != target) {
                    const item = evaluator.locals.pop().?;
                    evaluator.releases.releaseValue(item);
                    continue;
                }
                const next = unwind.*;
                self.state = .{ .stack = next };
            },
            .stack => |*unwind| {
                const target = @min(unwind.target.stackTarget(), evaluator.stack.items.len);
                if (evaluator.stack.items.len != target) {
                    const item = evaluator.stack.pop().?;
                    evaluator.releases.releaseValue(item);
                    continue;
                }
                evaluator.stack_base = unwind.target.previousBase();
                evaluator.boundary_index = unwind.target.previousBoundary();
                const error_value = unwind.error_value;
                switch (unwind.target) {
                    .uncaught => {
                        evaluator.finishUnwindFailed(error_value);
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
                    self.outcome_pair[0] = .{ .{ .symbol = .{ .name = key } }, error_value };
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
            .outcome => |*outcome_state| switch (try outcome_state.builder.advance(work)) {
                .pending => return .{ .yielded = .settle },
                .duplicate_key => unreachable,
                .complete => |outcome| {
                    const error_value = outcome_state.error_value;
                    outcome_state.builder.deinit();
                    self.state = .{ .caught = error_value };
                    evaluator.finishUnwindCaught();
                    return .{ .output = outcome };
                },
            },
            .caught => unreachable,
            .failed => return .failed,
        };
        return .{ .yielded = .settle };
    }
};
fn releaseCurrent(self: *Unit) void {
    if (self.current) |current| current.release(self.releases);
    self.current = null;
}
