//! Defunctionalized CEK evaluator, boundary unwinding, and d.19 errors.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");

pub const Value = value.Value;
pub const Header = value.Header;
pub const MachineError = error{ OutOfMemory, Ecl };

const no_word = std.math.maxInt(u32);
const no_boundary = std.math.maxInt(u32);
const fuel_quantum: u32 = 1024;

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
    user,

    pub fn symbol(self: ErrorKind) []const u8 {
        return switch (self) {
            .underflow => "underflow",
            .undefined_word => "undefined-word",
            .type => "type",
            .shape => "shape",
            .conform => "conform",
            .overflow => "overflow",
            .domain => "domain",
            .contract => "contract",
            .parse => "parse",
            .io => "io",
            .user => "user",
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
    seeded,
    observed,

    fn text(self: ErrorDataKey) []const u8 {
        return switch (self) {
            .needed => "needed",
            .available => "available",
            .name => "name",
            .seeded => "seeded",
            .observed => "observed",
        };
    }
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
    site: ?ErrorSite = null,
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

    pub fn deinit(self: *EclErr, allocator: std.mem.Allocator) void {
        for (self.data[0..self.data_len]) |entry| {
            heap.releaseValue(allocator, entry.value);
        }
        if (self.raised) |raised| heap.releaseValue(allocator, raised);
        self.* = undefined;
    }

    /// Builds the ordinary immutable error value only on the unwind path.
    pub fn toDict(
        self: *EclErr,
        allocator: std.mem.Allocator,
        trace_ids: []const u32,
        location: ?spans.LocatedSpan,
    ) error{OutOfMemory}!Value {
        if (self.raised != null) return self.raisedToDict(allocator, trace_ids, location);

        const kind_id = try intern.intern(self.kind.symbol());
        const kind_key = try intern.intern("kind");
        const msg_key = try intern.intern("msg");
        const word_key = try intern.intern("word");
        const trace_key = try intern.intern("trace");
        const data_key = try intern.intern("data");

        const message_value = try stringValue(allocator, self.text());
        defer heap.releaseValue(allocator, message_value);

        const trace_values = try allocator.alloc(Value, trace_ids.len);
        defer allocator.free(trace_values);
        for (trace_ids, 0..) |id, index| trace_values[index] = .{ .symbol = id };
        const trace_value = try list.fromValues(allocator, trace_values);
        defer heap.releaseValue(allocator, trace_value);

        var data_pairs: [8]dict.Pair = undefined;
        var data_len: usize = 0;
        for (self.data[0..self.data_len]) |entry| {
            const key = try intern.intern(entry.key.text());
            data_pairs[data_len] = .{ .{ .symbol = key }, entry.value };
            data_len += 1;
        }
        var source_value: ?Value = null;
        defer if (source_value) |item| heap.releaseValue(allocator, item);
        if (location) |located| {
            const source_key = try intern.intern("source");
            const line_key = try intern.intern("line");
            const col_key = try intern.intern("col");
            source_value = try stringValue(allocator, located.source_name);
            data_pairs[data_len] = .{ .{ .symbol = source_key }, source_value.? };
            data_len += 1;
            data_pairs[data_len] = .{ .{ .symbol = line_key }, .{ .int = located.span.line } };
            data_len += 1;
            data_pairs[data_len] = .{ .{ .symbol = col_key }, .{ .int = located.span.col } };
            data_len += 1;
        }
        const data_value = try dict.fromUniquePairs(allocator, data_pairs[0..data_len]);
        defer heap.releaseValue(allocator, data_value);

        var pairs: [5]dict.Pair = undefined;
        var count: usize = 0;
        pairs[count] = .{ .{ .symbol = kind_key }, .{ .symbol = kind_id } };
        count += 1;
        pairs[count] = .{ .{ .symbol = msg_key }, message_value };
        count += 1;
        if (self.word) |word| {
            pairs[count] = .{ .{ .symbol = word_key }, .{ .symbol = word } };
            count += 1;
        }
        pairs[count] = .{ .{ .symbol = trace_key }, trace_value };
        count += 1;
        pairs[count] = .{ .{ .symbol = data_key }, data_value };
        count += 1;
        return dict.fromUniquePairs(allocator, pairs[0..count]);
    }

    /// Preserves every user field while completing the d.19 envelope from
    /// unwind context. Explicit fields win; only absent context is attached.
    fn raisedToDict(
        self: *EclErr,
        allocator: std.mem.Allocator,
        trace_ids: []const u32,
        location: ?spans.LocatedSpan,
    ) error{OutOfMemory}!Value {
        const raised = self.raised.?;
        const kind_key = try intern.intern("kind");
        const msg_key = try intern.intern("msg");
        const word_key = try intern.intern("word");
        const trace_key = try intern.intern("trace");
        const data_key = try intern.intern("data");

        const kind = (try dictField(allocator, raised, kind_key)).?;
        const old_message = try dictField(allocator, raised, msg_key);
        const old_word = try dictField(allocator, raised, word_key);
        const old_trace = try dictField(allocator, raised, trace_key);
        const old_data = try dictField(allocator, raised, data_key);

        var message_value: ?Value = null;
        defer if (message_value) |item| heap.releaseValue(allocator, item);
        if (old_message == null) {
            var buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buffer,
                "raised '{s}",
                .{intern.get(kind.symbol)},
            ) catch "raised user error";
            message_value = try stringValue(allocator, message);
        }

        var trace_value: ?Value = null;
        defer if (trace_value) |item| heap.releaseValue(allocator, item);
        if (old_trace == null) {
            const trace_values = try allocator.alloc(Value, trace_ids.len);
            defer allocator.free(trace_values);
            for (trace_ids, 0..) |id, index| trace_values[index] = .{ .symbol = id };
            trace_value = try list.fromValues(allocator, trace_values);
        }

        const data_value = try completeRaisedData(allocator, old_data, location);
        defer if (data_value) |item| heap.releaseValue(allocator, item);

        const old_count: usize = @intCast(raised.dict.len);
        const extra_count = @as(usize, @intFromBool(old_message == null)) +
            @as(usize, @intFromBool(old_word == null and self.word != null)) +
            @as(usize, @intFromBool(old_trace == null)) +
            @as(usize, @intFromBool(old_data == null));
        const pairs = try allocator.alloc(dict.Pair, old_count + extra_count);
        defer allocator.free(pairs);
        for (0..old_count) |index| {
            const key = dict.keyAt(raised.dict, index);
            const old_value = dict.valueAt(raised.dict, index);
            pairs[index] = .{
                key,
                if (key == .symbol and key.symbol == data_key and data_value != null)
                    data_value.?
                else
                    old_value,
            };
        }
        var count = old_count;
        if (old_message == null) {
            pairs[count] = .{ .{ .symbol = msg_key }, message_value.? };
            count += 1;
        }
        if (old_word == null) if (self.word) |word| {
            pairs[count] = .{ .{ .symbol = word_key }, .{ .symbol = word } };
            count += 1;
        };
        if (old_trace == null) {
            pairs[count] = .{ .{ .symbol = trace_key }, trace_value.? };
            count += 1;
        }
        if (old_data == null) {
            pairs[count] = .{ .{ .symbol = data_key }, data_value.? };
            count += 1;
        }
        std.debug.assert(count == pairs.len);
        return dict.fromUniquePairs(allocator, pairs);
    }
};

fn dictField(
    allocator: std.mem.Allocator,
    dictionary: Value,
    key: u32,
) error{OutOfMemory}!?Value {
    return dict.getWithAllocator(allocator, dictionary, .{ .symbol = key }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotADict => unreachable,
    };
}

/// Returns an owned replacement only when `data` is absent or provenance
/// fields must be appended. Existing user payload and positions are retained.
fn completeRaisedData(
    allocator: std.mem.Allocator,
    data: ?Value,
    location: ?spans.LocatedSpan,
) error{OutOfMemory}!?Value {
    const source_key = try intern.intern("source");
    const line_key = try intern.intern("line");
    const col_key = try intern.intern("col");
    const has_source = if (data) |item| (try dictField(allocator, item, source_key)) != null else false;
    const has_line = if (data) |item| (try dictField(allocator, item, line_key)) != null else false;
    const has_col = if (data) |item| (try dictField(allocator, item, col_key)) != null else false;
    if (data != null and (location == null or has_source and has_line and has_col)) return null;

    const old_count: usize = if (data) |item| @intCast(item.dict.len) else 0;
    const add_source = location != null and !has_source;
    const add_line = location != null and !has_line;
    const add_col = location != null and !has_col;
    const pairs = try allocator.alloc(
        dict.Pair,
        old_count + @as(usize, @intFromBool(add_source)) +
            @as(usize, @intFromBool(add_line)) +
            @as(usize, @intFromBool(add_col)),
    );
    defer allocator.free(pairs);
    if (data) |item| for (0..old_count) |index| {
        pairs[index] = .{ dict.keyAt(item.dict, index), dict.valueAt(item.dict, index) };
    };

    var source_value: ?Value = null;
    defer if (source_value) |item| heap.releaseValue(allocator, item);
    var count = old_count;
    if (location) |located| {
        if (add_source) {
            source_value = try stringValue(allocator, located.source_name);
            pairs[count] = .{ .{ .symbol = source_key }, source_value.? };
            count += 1;
        }
        if (add_line) {
            pairs[count] = .{ .{ .symbol = line_key }, .{ .int = located.span.line } };
            count += 1;
        }
        if (add_col) {
            pairs[count] = .{ .{ .symbol = col_key }, .{ .int = located.span.col } };
            count += 1;
        }
    }
    std.debug.assert(count == pairs.len);
    return try dict.fromUniquePairs(allocator, pairs);
}

pub fn stringValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) error{OutOfMemory}!Value {
    var codepoints: std.ArrayList(u32) = .empty;
    defer codepoints.deinit(allocator);
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        for (bytes) |byte| try codepoints.append(allocator, byte);
    } else {
        var index: usize = 0;
        while (index < bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
                @panic("validated UTF-8 reached an invalid start byte");
            const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch
                @panic("validated UTF-8 reached an invalid sequence");
            try codepoints.append(allocator, codepoint);
            index += length;
        }
    }
    return list.fromCodepoints(allocator, codepoints.items);
}

const Eval = struct {
    code: *Header,
    ip: u32,
    environment: *env.Env,
    traced_word: u32,
};

const BoundaryKind = enum(u8) { attempt, dict_of };

const Boundary = struct {
    kind: BoundaryKind,
    stack_base: u32,
    previous_base: u32,
    previous_boundary: u32,
    word: u32,
};

pub const Frame = union(enum(u8)) {
    eval: Eval,
    restore: Value,
    while_after_cond: struct {
        condition: *Header,
        body: *Header,
        environment: *env.Env,
        base: u32,
        word: u32,
    },
    while_after_body: struct {
        condition: *Header,
        body: *Header,
        environment: *env.Env,
        word: u32,
    },
    boundary: Boundary,

    fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        switch (self) {
            .eval => |frame| heap.decRef(allocator, frame.code),
            .restore => |item| heap.releaseValue(allocator, item),
            .while_after_cond => |frame| {
                heap.decRef(allocator, frame.condition);
                heap.decRef(allocator, frame.body);
            },
            .while_after_body => |frame| {
                heap.decRef(allocator, frame.condition);
                heap.decRef(allocator, frame.body);
            },
            .boundary => {},
        }
    }
};

comptime {
    if (@sizeOf(Frame) > 48) @compileError("machine frames must remain at most 48 bytes");
}

pub const Unit = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,
    stack: std.ArrayList(Value),
    environment: *env.Env,
    archive: *const spans.SpanArchive,
    output: ?*std.Io.Writer,
    arguments: Value,
    cancelled: *const std.atomic.Value(bool),
    fuel: u32 = fuel_quantum,
    polls: u64 = 0,
    max_frames: usize = 0,
    entry_base: usize,
    stack_base: usize,
    boundary_index: u32 = no_boundary,
    pending: ?EclErr = null,
    last_error: ?Value = null,
    exit_status: ?u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        stack: std.ArrayList(Value),
        environment: *env.Env,
        archive: *const spans.SpanArchive,
        output: ?*std.Io.Writer,
        arguments: Value,
        cancelled: *const std.atomic.Value(bool),
    ) Unit {
        return .{
            .allocator = allocator,
            .stack = stack,
            .environment = environment,
            .archive = archive,
            .output = output,
            .arguments = arguments,
            .cancelled = cancelled,
            .entry_base = stack.items.len,
            .stack_base = 0,
        };
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

    pub fn deinit(self: *Unit) void {
        for (self.frames.items) |frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        for (self.stack.items) |item| heap.releaseValue(self.allocator, item);
        self.stack.deinit(self.allocator);
        if (self.pending) |*pending| pending.deinit(self.allocator);
        if (self.last_error) |item| heap.releaseValue(self.allocator, item);
        self.* = undefined;
    }
};

pub const Machine = struct {
    unit: *Unit,
    current: ?Eval,
    active_index: u32 = 0,
    active_word: u32 = no_word,

    pub fn allocator(self: *const Machine) std.mem.Allocator {
        return self.unit.allocator;
    }

    pub fn currentEnv(self: *const Machine) *env.Env {
        return self.current.?.environment;
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

    pub fn popOwned(self: *Machine) MachineError!Value {
        try self.require(1);
        return self.unit.stack.pop().?;
    }

    /// Consumes `item`, releasing it if stack growth fails.
    pub fn pushOwned(self: *Machine, item: Value) error{OutOfMemory}!void {
        self.unit.stack.append(self.unit.allocator, item) catch {
            heap.releaseValue(self.unit.allocator, item);
            return error.OutOfMemory;
        };
    }

    pub fn pushBorrowed(self: *Machine, item: Value) error{OutOfMemory}!void {
        heap.retainValue(item);
        return self.pushOwned(item);
    }

    pub fn activeWordId(self: *const Machine) u32 {
        return self.active_word;
    }

    pub fn activeWordName(self: *const Machine) []const u8 {
        return if (self.active_word == no_word) "evaluation" else intern.get(self.active_word);
    }

    pub fn fail(self: *Machine, kind: ErrorKind, message: []const u8) MachineError {
        std.debug.assert(self.unit.pending == null);
        self.unit.pending = EclErr.init(kind, message);
        if (self.active_word != no_word) self.unit.pending.?.word = self.active_word;
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
        if (self.active_word != no_word) self.unit.pending.?.word = self.active_word;
        return error.Ecl;
    }

    pub fn typeError(self: *Machine, expected: []const u8) MachineError {
        return self.failFmt(
            .type,
            "{s} expected {s}",
            .{ self.activeWordName(), expected },
        );
    }

    /// Consumes a quotation header and applies it inline.
    pub fn callOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        const environment = self.current.?.environment;
        const inherited_trace = self.suspendCurrent() catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = quotation,
            .ip = 0,
            .environment = environment,
            .traced_word = inherited_trace,
        };
    }

    /// Consumes both values and restores `protected` after the quotation.
    pub fn dipOwned(
        self: *Machine,
        quotation: *Header,
        protected: Value,
    ) error{OutOfMemory}!void {
        const environment = self.current.?.environment;
        const inherited_trace = self.suspendCurrent() catch {
            heap.decRef(self.unit.allocator, quotation);
            heap.releaseValue(self.unit.allocator, protected);
            return error.OutOfMemory;
        };
        self.appendFrame(.{ .restore = protected }) catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = quotation,
            .ip = 0,
            .environment = environment,
            .traced_word = inherited_trace,
        };
    }

    /// Consumes condition and body and schedules the iterative while frames.
    pub fn whileOwned(
        self: *Machine,
        condition: *Header,
        body: *Header,
    ) error{OutOfMemory}!void {
        const environment = self.current.?.environment;
        const word = self.active_word;
        const inherited_trace = self.suspendCurrent() catch {
            heap.decRef(self.unit.allocator, condition);
            heap.decRef(self.unit.allocator, body);
            return error.OutOfMemory;
        };
        self.appendFrame(.{ .while_after_cond = .{
            .condition = condition,
            .body = body,
            .environment = environment,
            .base = @intCast(self.unit.stack.items.len),
            .word = word,
        } }) catch return error.OutOfMemory;
        heap.incRef(condition);
        self.current = .{
            .code = condition,
            .ip = 0,
            .environment = environment,
            .traced_word = inherited_trace,
        };
    }

    pub fn attemptOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        return self.beginBoundaryOwned(.attempt, quotation);
    }

    pub fn dictOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        return self.beginBoundaryOwned(.dict_of, quotation);
    }

    pub fn raiseOwned(self: *Machine, raised: Value) MachineError {
        std.debug.assert(self.unit.pending == null);
        self.unit.pending = EclErr.init(.user, "raised error");
        if (self.active_word != no_word) self.unit.pending.?.word = self.active_word;
        self.unit.pending.?.raised = raised;
        return error.Ecl;
    }

    fn beginBoundaryOwned(
        self: *Machine,
        kind: BoundaryKind,
        quotation: *Header,
    ) error{OutOfMemory}!void {
        const environment = self.current.?.environment;
        const word = self.active_word;
        _ = self.suspendCurrent() catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= no_boundary) {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        }
        const index: u32 = @intCast(self.unit.frames.items.len);
        self.appendFrame(.{ .boundary = .{
            .kind = kind,
            .stack_base = @intCast(self.unit.stack.items.len),
            .previous_base = @intCast(self.unit.stack_base),
            .previous_boundary = self.unit.boundary_index,
            .word = word,
        } }) catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        self.unit.boundary_index = index;
        self.unit.stack_base = self.unit.stack.items.len;
        self.current = .{ .code = quotation, .ip = 0, .environment = environment, .traced_word = no_word };
    }

    fn appendFrame(self: *Machine, frame: Frame) error{OutOfMemory}!void {
        self.unit.frames.append(self.unit.allocator, frame) catch {
            frame.deinit(self.unit.allocator);
            return error.OutOfMemory;
        };
        self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
    }

    /// Suspends a non-tail continuation. An exhausted anonymous quotation
    /// inherits its named trace owner so inline control does not erase the
    /// activation that selected it.
    fn suspendCurrent(self: *Machine) error{OutOfMemory}!u32 {
        const current = self.current.?;
        const inherited_trace = if (current.ip >= current.code.len)
            current.traced_word
        else
            no_word;
        if (current.ip < current.code.len) {
            try self.unit.frames.append(self.unit.allocator, .{ .eval = current });
            self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
        } else {
            heap.decRef(self.unit.allocator, current.code);
        }
        self.current = null;
        return inherited_trace;
    }
};

pub fn run(unit: *Unit, code: *Header) MachineError!void {
    std.debug.assert(unit.frames.items.len == 0);
    std.debug.assert(unit.pending == null and unit.last_error == null);
    heap.incRef(code);
    var evaluator = Machine{
        .unit = unit,
        .current = .{
            .code = code,
            .ip = 0,
            .environment = unit.environment,
            .traced_word = no_word,
        },
    };
    loop(&evaluator) catch |err| switch (err) {
        error.Ecl => return error.Ecl,
        error.OutOfMemory => {
            abort(&evaluator, true);
            return error.OutOfMemory;
        },
    };
}

fn loop(self: *Machine) MachineError!void {
    while (true) {
        if (self.unit.exit_status != null) {
            cleanupControl(self);
            return;
        }
        if (self.current == null) {
            const resumed = resumeFrames(self) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    if (try handleFailure(self)) continue;
                    return error.Ecl;
                },
            };
            if (!resumed) return;
        }

        const current = &self.current.?;
        if (current.ip >= current.code.len) {
            heap.decRef(self.unit.allocator, current.code);
            self.current = null;
            continue;
        }
        poll(self) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                if (try handleFailure(self)) continue;
                return error.Ecl;
            },
        };
        self.active_index = current.ip;
        const form = list.atUnchecked(.{ .list = current.code }, current.ip);
        current.ip += 1;
        dispatch(self, form) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                if (self.unit.pending.?.site == null and self.current != null) {
                    self.unit.pending.?.site = .{
                        .code = self.current.?.code,
                        .index = self.active_index,
                    };
                }
                if (try handleFailure(self)) continue;
                return error.Ecl;
            },
        };
    }
}

fn poll(self: *Machine) MachineError!void {
    if (self.unit.fuel == 0) {
        self.unit.polls += 1;
        self.unit.fuel = fuel_quantum;
        if (self.unit.cancelled.load(.acquire)) {
            self.active_word = no_word;
            return self.fail(.user, "unit cancelled");
        }
    }
    self.unit.fuel -= 1;
}

fn dispatch(self: *Machine, form: Value) MachineError!void {
    const word = switch (form) {
        .word => |id| id,
        .int, .float, .char, .symbol, .list, .dict => return self.pushBorrowed(form),
    };
    self.active_word = word;
    const binding = self.current.?.environment.lookup(word) orelse {
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(word)});
        self.unit.pending.?.addData(.name, .{ .symbol = word });
        return failure;
    };
    switch (binding) {
        .value => |item| try self.pushBorrowed(item),
        .word => |body| try scheduleWord(self, body, word),
        .primitive => |primitive| try primitive(self),
    }
}

fn scheduleWord(self: *Machine, body: *Header, word: u32) error{OutOfMemory}!void {
    const environment = self.current.?.environment;
    _ = self.suspendCurrent() catch return error.OutOfMemory;
    heap.incRef(body);
    self.current = .{ .code = body, .ip = 0, .environment = environment, .traced_word = word };
}

fn resumeFrames(self: *Machine) MachineError!bool {
    while (self.unit.frames.pop()) |frame| switch (frame) {
        .eval => |continuation| {
            self.current = continuation;
            return true;
        },
        .restore => |item| try self.pushOwned(item),
        .while_after_cond => |continuation| {
            self.active_word = continuation.word;
            if (self.unit.stack.items.len != @as(usize, continuation.base) + 1) {
                std.debug.assert(@as(usize, continuation.base) >= self.unit.stack_base);
                std.debug.assert(self.unit.stack.items.len >= self.unit.stack_base);
                const seeded = @as(usize, continuation.base) - self.unit.stack_base;
                const observed = self.unit.stack.items.len - self.unit.stack_base;
                continuationFrameRelease(self.unit.allocator, continuation.condition, continuation.body);
                const failure = self.failFmt(
                    .contract,
                    "while condition must leave exactly one bool; seeded {d}, observed {d}",
                    .{ seeded, observed },
                );
                self.unit.pending.?.addData(.seeded, .{ .int = @intCast(seeded) });
                self.unit.pending.?.addData(.observed, .{ .int = @intCast(observed) });
                return failure;
            }
            const predicate_value = self.unit.stack.pop().?;
            const predicate = switch (predicate_value) {
                .int => |integer| switch (integer) {
                    0 => false,
                    1 => true,
                    else => {
                        heap.releaseValue(self.unit.allocator, predicate_value);
                        continuationFrameRelease(self.unit.allocator, continuation.condition, continuation.body);
                        return self.typeError("a 0/1 bool");
                    },
                },
                .float, .char, .symbol, .word, .list, .dict => {
                    heap.releaseValue(self.unit.allocator, predicate_value);
                    continuationFrameRelease(self.unit.allocator, continuation.condition, continuation.body);
                    return self.typeError("a 0/1 bool");
                },
            };
            if (!predicate) {
                continuationFrameRelease(self.unit.allocator, continuation.condition, continuation.body);
                continue;
            }
            try self.appendFrame(.{ .while_after_body = .{
                .condition = continuation.condition,
                .body = continuation.body,
                .environment = continuation.environment,
                .word = continuation.word,
            } });
            heap.incRef(continuation.body);
            self.current = .{
                .code = continuation.body,
                .ip = 0,
                .environment = continuation.environment,
                .traced_word = no_word,
            };
            return true;
        },
        .while_after_body => |continuation| {
            try self.appendFrame(.{ .while_after_cond = .{
                .condition = continuation.condition,
                .body = continuation.body,
                .environment = continuation.environment,
                .base = @intCast(self.unit.stack.items.len),
                .word = continuation.word,
            } });
            heap.incRef(continuation.condition);
            self.current = .{
                .code = continuation.condition,
                .ip = 0,
                .environment = continuation.environment,
                .traced_word = no_word,
            };
            return true;
        },
        .boundary => |boundary| {
            std.debug.assert(self.unit.boundary_index == self.unit.frames.items.len);
            self.unit.boundary_index = boundary.previous_boundary;
            self.unit.stack_base = boundary.previous_base;
            self.active_word = boundary.word;
            switch (boundary.kind) {
                .attempt => try finishAttempt(self, boundary.stack_base),
                .dict_of => try finishDict(self, boundary.stack_base),
            }
        },
    };
    return false;
}

fn continuationFrameRelease(allocator: std.mem.Allocator, a: *Header, b: *Header) void {
    heap.decRef(allocator, a);
    heap.decRef(allocator, b);
}

fn finishAttempt(self: *Machine, base: u32) MachineError!void {
    const start: usize = base;
    const results = try list.fromValues(self.unit.allocator, self.unit.stack.items[start..]);
    truncateStack(self, start);
    const outcome = try outcomeDict(self.unit.allocator, "ok", results);
    try self.pushOwned(outcome);
}

fn finishDict(self: *Machine, base: u32) MachineError!void {
    const start: usize = base;
    const items = self.unit.stack.items[start..];
    if (items.len % 2 != 0) {
        return self.fail(.contract, "dict-of body must produce an even number of values");
    }
    const pairs: []const dict.Pair = @ptrCast(items);
    const dictionary = dict.fromPairs(self.unit.allocator, pairs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateKey => return self.fail(.domain, "dict-of produced a duplicate key"),
    };
    truncateStack(self, start);
    try self.pushOwned(dictionary);
}

fn outcomeDict(
    allocator: std.mem.Allocator,
    name: []const u8,
    payload: Value,
) error{OutOfMemory}!Value {
    defer heap.releaseValue(allocator, payload);
    const key = try intern.intern(name);
    return dict.fromUniquePairs(allocator, &.{.{ .{ .symbol = key }, payload }});
}

fn handleFailure(self: *Machine) error{OutOfMemory}!bool {
    var trace: std.ArrayList(u32) = .empty;
    defer trace.deinit(self.unit.allocator);
    try collectTrace(self, &trace);
    const location = if (self.unit.pending.?.site) |site|
        self.unit.archive.locate(site.code, site.index)
    else
        null;
    var pending = self.unit.pending.?;
    self.unit.pending = null;
    const error_value = pending.toDict(self.unit.allocator, trace.items, location) catch |err| {
        pending.deinit(self.unit.allocator);
        return err;
    };
    pending.deinit(self.unit.allocator);

    const attempt_index = nearestAttempt(self);
    if (attempt_index == no_boundary) {
        cleanupControl(self);
        truncateStack(self, self.unit.entry_base);
        self.unit.stack_base = 0;
        self.unit.boundary_index = no_boundary;
        self.unit.last_error = error_value;
        return false;
    }

    const boundary = self.unit.frames.items[attempt_index].boundary;
    releaseCurrent(self);
    var index = self.unit.frames.items.len;
    while (index > attempt_index) {
        index -= 1;
        self.unit.frames.items[index].deinit(self.unit.allocator);
    }
    self.unit.frames.shrinkRetainingCapacity(attempt_index);
    truncateStack(self, boundary.stack_base);
    self.unit.stack_base = boundary.previous_base;
    self.unit.boundary_index = boundary.previous_boundary;
    const outcome = try outcomeDict(self.unit.allocator, "err", error_value);
    try self.pushOwned(outcome);
    return true;
}

fn nearestAttempt(self: *const Machine) u32 {
    var index = self.unit.boundary_index;
    while (index != no_boundary) {
        const boundary = self.unit.frames.items[index].boundary;
        if (boundary.kind == .attempt) return index;
        index = boundary.previous_boundary;
    }
    return no_boundary;
}

fn collectTrace(self: *Machine, trace: *std.ArrayList(u32)) error{OutOfMemory}!void {
    if (self.unit.pending.?.word) |word| try trace.append(self.unit.allocator, word);
    if (self.current) |current| {
        if (current.traced_word != no_word) {
            try trace.append(self.unit.allocator, current.traced_word);
        }
    }
    var index = self.unit.frames.items.len;
    while (index > 0) {
        index -= 1;
        switch (self.unit.frames.items[index]) {
            .eval => |frame| if (frame.traced_word != no_word) {
                try trace.append(self.unit.allocator, frame.traced_word);
            },
            .restore, .while_after_cond, .while_after_body, .boundary => {},
        }
    }
}

fn truncateStack(self: *Machine, length: usize) void {
    const target = @min(length, self.unit.stack.items.len);
    for (self.unit.stack.items[target..]) |item| heap.releaseValue(self.unit.allocator, item);
    self.unit.stack.shrinkRetainingCapacity(target);
}

fn releaseCurrent(self: *Machine) void {
    if (self.current) |current| heap.decRef(self.unit.allocator, current.code);
    self.current = null;
}

fn cleanupControl(self: *Machine) void {
    releaseCurrent(self);
    for (self.unit.frames.items) |frame| frame.deinit(self.unit.allocator);
    self.unit.frames.clearRetainingCapacity();
    self.unit.boundary_index = no_boundary;
    self.unit.stack_base = 0;
}

fn abort(self: *Machine, release_error: bool) void {
    cleanupControl(self);
    truncateStack(self, self.unit.entry_base);
    if (self.unit.pending) |*pending| pending.deinit(self.unit.allocator);
    self.unit.pending = null;
    if (release_error) {
        if (self.unit.last_error) |item| heap.releaseValue(self.unit.allocator, item);
        self.unit.last_error = null;
    }
}

test "machine pushes values and late-bound word bodies" {
    const allocator = std.testing.allocator;
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    const name = try intern.intern("answer");
    const body = try list.fromValuesGeneric(allocator, &.{.{ .int = 7 }});
    defer heap.releaseValue(allocator, body);
    try environment.define(name, .{ .word = body.list });
    const code = try list.fromValuesGeneric(allocator, &.{.{ .word = name }});
    defer heap.releaseValue(allocator, code);

    var archive = spans.SpanArchive.init(allocator);
    defer archive.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    var unit = Unit.init(allocator, .empty, &environment, &archive, null, .{ .int = 0 }, &cancelled);
    defer unit.deinit();
    try run(&unit, code.list);
    try std.testing.expectEqual(@as(usize, 1), unit.stack.items.len);
    try std.testing.expectEqual(@as(i64, 7), unit.stack.items[0].int);
}

test "tail word calls reuse evaluator state" {
    const allocator = std.testing.allocator;
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    const end = try intern.intern("tail-end");
    const start = try intern.intern("tail-start");
    const end_body = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, end_body);
    const start_body = try list.fromValuesGeneric(allocator, &.{.{ .word = end }});
    defer heap.releaseValue(allocator, start_body);
    try environment.define(end, .{ .word = end_body.list });
    try environment.define(start, .{ .word = start_body.list });
    const code = try list.fromValuesGeneric(allocator, &.{.{ .word = start }});
    defer heap.releaseValue(allocator, code);

    var archive = spans.SpanArchive.init(allocator);
    defer archive.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    var unit = Unit.init(allocator, .empty, &environment, &archive, null, .{ .int = 0 }, &cancelled);
    defer unit.deinit();
    try run(&unit, code.list);
    try std.testing.expectEqual(@as(usize, 0), unit.max_frames);
}

test "fuel polls without changing execution" {
    const allocator = std.testing.allocator;
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    const code = try list.fromValuesGeneric(allocator, &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer heap.releaseValue(allocator, code);
    var archive = spans.SpanArchive.init(allocator);
    defer archive.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    var unit = Unit.init(allocator, .empty, &environment, &archive, null, .{ .int = 0 }, &cancelled);
    defer unit.deinit();
    unit.fuel = 1;
    try run(&unit, code.list);
    try std.testing.expectEqual(@as(u64, 1), unit.polls);
    try std.testing.expectEqual(@as(usize, 2), unit.stack.items.len);
}

test "cancellation unwinds into an ordinary language error" {
    const allocator = std.testing.allocator;
    var environment = env.Env.init(allocator);
    defer environment.deinit();
    const code = try list.fromValuesGeneric(allocator, &.{.{ .int = 1 }});
    defer heap.releaseValue(allocator, code);
    var archive = spans.SpanArchive.init(allocator);
    defer archive.deinit();
    const cancelled = std.atomic.Value(bool).init(true);
    var unit = Unit.init(allocator, .empty, &environment, &archive, null, .{ .int = 0 }, &cancelled);
    defer unit.deinit();
    unit.fuel = 0;

    try std.testing.expectError(error.Ecl, run(&unit, code.list));
    const error_value = unit.takeError().?;
    defer heap.releaseValue(allocator, error_value);
    try std.testing.expectEqual(@as(usize, 0), unit.stack.items.len);
}

test "errors: machine-built user dict has the complete d.19 envelope" {
    const allocator = std.testing.allocator;
    const worker = try intern.intern("worker");
    var language_error = EclErr.init(.user, "machine user error");
    defer language_error.deinit(allocator);
    language_error.word = worker;
    const error_value = try language_error.toDict(allocator, &.{worker}, null);
    defer heap.releaseValue(allocator, error_value);
    const rendered = try @import("print.zig").toOwnedString(allocator, error_value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'user 'msg \"machine user error\" 'word 'worker " ++
            "'trace ['worker] 'data {}}",
        rendered,
    );
}

test "frame representation stays within the frozen budget" {
    try std.testing.expect(@sizeOf(Frame) <= 48);
}
