//! Defunctionalized CEK evaluator, boundary unwinding, and d.19 errors.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const reader = @import("reader.zig");
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
    /// d.19 freezes this set, so `else` cannot silently absorb a new kind.
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
    pub fn deinit(self: *EclErr, allocator: std.mem.Allocator) void {
        for (self.data[0..self.data_len]) |entry| {
            heap.releaseValue(allocator, entry.value);
        }
        if (self.raised) |raised| heap.releaseValue(allocator, raised);
        self.* = undefined;
    }
    pub fn setLocation(self: *EclErr, source_name: []const u8, span: @import("lexer.zig").Span) void {
        const selected = source_name[0..@min(source_name.len, self.source.len)];
        @memcpy(self.source[0..selected.len], selected);
        self.source_len = selected.len;
        self.source_line = span.line;
        self.source_col = span.col;
    }
    /// Builds the ordinary immutable error value only on the unwind path.
    pub fn toDict(
        self: *EclErr,
        allocator: std.mem.Allocator,
        trace_ids: []const u32,
        location: ?spans.LocatedSpan,
    ) error{OutOfMemory}!Value {
        const effective_location = if (self.source_len > 0)
            spans.LocatedSpan{
                .source_name = self.source[0..self.source_len],
                .span = .{ .line = self.source_line, .col = self.source_col },
            }
        else
            location;
        if (self.raised != null) return self.raisedToDict(allocator, trace_ids, effective_location);
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
            const key = try intern.intern(@tagName(entry.key));
            data_pairs[data_len] = .{ .{ .symbol = key }, entry.value };
            data_len += 1;
        }
        var source_value: ?Value = null;
        defer if (source_value) |item| heap.releaseValue(allocator, item);
        if (effective_location) |located| {
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
        const kind = (try dict.symbolField(allocator, raised, kind_key)).?;
        const old_message = try dict.symbolField(allocator, raised, msg_key);
        const old_word = try dict.symbolField(allocator, raised, word_key);
        const old_trace = try dict.symbolField(allocator, raised, trace_key);
        const old_data = try dict.symbolField(allocator, raised, data_key);
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
    const has_source = if (data) |item| (try dict.symbolField(allocator, item, source_key)) != null else false;
    const has_line = if (data) |item| (try dict.symbolField(allocator, item, line_key)) != null else false;
    const has_col = if (data) |item| (try dict.symbolField(allocator, item, col_key)) != null else false;
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
    scope: *env.Scope,
    home: ?*modules.ModuleGeneration,
    traced_word: u32,
};
const BoundaryKind = enum(u8) { attempt, dict_of, module };
const Boundary = struct {
    kind: BoundaryKind,
    stack_base: u32,
    previous_base: u32,
    previous_boundary: u32,
    word: u32,
    scope: *env.Scope,
    candidate: ?*modules.ModuleGeneration = null,
    fn deinit(self: Boundary, allocator: std.mem.Allocator) void {
        if (self.candidate) |candidate| {
            candidate.destroy();
        } else {
            self.scope.deinit();
            allocator.destroy(self.scope);
        }
    }
};
const EffectCheck = struct {
    expected_depth: u32,
    entry_depth: u32,
    inputs: u32,
    outputs: u32,
    word: u32,
};
pub const Frame = union(enum(u8)) {
    eval: Eval,
    restore: Value,
    while_after_cond: struct {
        condition: *Header,
        body: *Header,
        scope: *env.Scope,
        home: ?*modules.ModuleGeneration,
        base: u32,
        word: u32,
    },
    while_after_body: struct {
        condition: *Header,
        body: *Header,
        scope: *env.Scope,
        home: ?*modules.ModuleGeneration,
        word: u32,
    },
    effect_check: EffectCheck,
    use_after_load: struct {
        registry: *modules.Registry,
        scope: *env.Scope,
        name: u32,
        path: Value,
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
            .effect_check => {},
            .use_after_load => |frame| {
                frame.registry.endLoading(frame.name);
                heap.releaseValue(allocator, frame.path);
            },
            .boundary => |boundary| boundary.deinit(allocator),
        }
    }
};
comptime {
    if (@sizeOf(Frame) > 48) @compileError("machine frames must remain at most 48 bytes");
}
pub const Unit = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,
    generation_pins: std.ArrayList(*modules.ModuleGeneration) = .empty,
    stack: std.ArrayList(Value),
    environment: *env.Env,
    registry: ?*modules.Registry = null,
    root_scope: env.Scope,
    archive: *spans.SpanArchive,
    output: ?*std.Io.Writer,
    diagnostics: ?*std.Io.Writer = null,
    host_io: ?std.Io = null,
    ecl_path: ?[]const u8 = null,
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
        archive: *spans.SpanArchive,
        output: ?*std.Io.Writer,
        arguments: Value,
        cancelled: *const std.atomic.Value(bool),
    ) Unit {
        return .{
            .allocator = allocator,
            .stack = stack,
            .environment = environment,
            .root_scope = env.Scope.direct(allocator, &environment.session, null, .session),
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
    fn pinGeneration(self: *Unit, generation: *modules.ModuleGeneration) error{OutOfMemory}!void {
        for (self.generation_pins.items) |pinned| if (pinned == generation) return;
        try self.generation_pins.append(self.allocator, generation);
        generation.retain();
    }
    pub fn deinit(self: *Unit) void {
        for (self.frames.items) |frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        for (self.generation_pins.items) |generation| generation.release();
        self.generation_pins.deinit(self.allocator);
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
        return self.unit.environment;
    }
    pub fn currentScope(self: *const Machine) *env.Scope {
        return self.current.?.scope;
    }
    pub fn currentHome(self: *const Machine) ?*modules.ModuleGeneration {
        return self.current.?.home;
    }
    pub fn useModule(self: *Machine, name: u32) MachineError!bool {
        return self.installUse(self.currentScope(), name);
    }
    fn installUse(self: *Machine, scope: *env.Scope, name: u32) MachineError!bool {
        const registry = self.unit.registry orelse return false;
        const canonical = registry.canonical(name) orelse return false;
        if (scope.kind == .session) try emitShadowNotices(self, scope, canonical);
        scope.moveUseToTop(canonical) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Frozen => return self.fail(.domain, "registered module environments are immutable"),
        };
        return true;
    }
    pub fn useOrLoad(self: *Machine, name: u32) MachineError!void {
        if (try self.useModule(name)) return;
        const registry = self.unit.registry orelse return self.undefinedModule(name);
        const io = self.unit.host_io orelse return self.undefinedModule(name);
        const search = self.unit.ecl_path orelse return self.undefinedModule(name);
        if (!try registry.beginLoading(name)) {
            return self.failFmt(.domain, "recursive auto-load of module `{s}`", .{intern.get(name)});
        }
        var loading_owned = true;
        defer if (loading_owned) registry.endLoading(name);
        const filename = try std.fmt.allocPrint(self.unit.allocator, "{s}.ecl", .{intern.get(name)});
        defer self.unit.allocator.free(filename);
        var paths = std.mem.splitScalar(u8, search, std.fs.path.delimiter);
        while (paths.next()) |directory| {
            if (directory.len == 0) continue;
            const candidate = try std.fs.path.join(self.unit.allocator, &.{ directory, filename });
            defer self.unit.allocator.free(candidate);
            std.Io.Dir.cwd().access(io, candidate, .{ .read = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    const path_value = try stringValue(self.unit.allocator, candidate);
                    defer heap.releaseValue(self.unit.allocator, path_value);
                    const failure = self.failFmt(.io, "cannot access module file `{s}`: {s}", .{ candidate, @errorName(err) });
                    self.unit.pending.?.addData(.path, path_value);
                    return failure;
                },
            };
            try self.loadPathOwned(candidate, name);
            loading_owned = false;
            return;
        }
        return self.undefinedModule(name);
    }
    pub fn loadPathOwned(self: *Machine, path: []const u8, retry_use: ?u32) MachineError!void {
        const path_value = try stringValue(self.unit.allocator, path);
        defer heap.releaseValue(self.unit.allocator, path_value);
        const io = self.unit.host_io orelse {
            const failure = self.fail(.io, "filesystem access is unavailable");
            self.unit.pending.?.addData(.path, path_value);
            return failure;
        };
        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.unit.allocator,
            .unlimited,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const failure = self.failFmt(.io, "cannot read `{s}`: {s}", .{ path, @errorName(err) });
                self.unit.pending.?.addData(.path, path_value);
                return failure;
            },
        };
        defer self.unit.allocator.free(source);
        var diag: reader.Diag = .{};
        const read_result = reader.read(self.unit.allocator, path, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => {
                const failure = self.fail(.parse, diag.text());
                self.unit.pending.?.setLocation(path, diag.span);
                return failure;
            },
        };
        var parsed = switch (read_result) {
            .incomplete => |incomplete| {
                const failure = self.fail(.parse, incomplete.message);
                self.unit.pending.?.setLocation(path, incomplete.span);
                return failure;
            },
            .complete => |complete| complete,
        };
        defer parsed.deinit();
        const root = try list.fromValuesGeneric(self.unit.allocator, parsed.forms);
        var root_owned = true;
        defer if (root_owned) heap.releaseValue(self.unit.allocator, root);
        try self.unit.archive.absorb(&parsed, root);
        root_owned = false;
        heap.incRef(root.list);
        if (retry_use) |name| {
            const scope = self.current.?.scope;
            const home = self.current.?.home;
            _ = self.suspendCurrent() catch {
                heap.decRef(self.unit.allocator, root.list);
                return error.OutOfMemory;
            };
            self.unit.frames.append(self.unit.allocator, .{ .use_after_load = .{
                .registry = self.unit.registry.?,
                .scope = scope,
                .name = name,
                .path = path_value,
            } }) catch {
                heap.decRef(self.unit.allocator, root.list);
                return error.OutOfMemory;
            };
            heap.retainValue(path_value);
            self.unit.max_frames = @max(self.unit.max_frames, self.unit.frames.items.len);
            self.current = .{ .code = root.list, .ip = 0, .scope = scope, .home = home, .traced_word = no_word };
        } else {
            try self.callOwned(root.list);
        }
    }
    pub fn aliasModule(self: *Machine, short: u32, target: u32) MachineError!void {
        const registry = self.unit.registry orelse
            return self.fail(.domain, "module registry is unavailable");
        registry.alias(short, target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NameConflict => return self.fail(.domain, "alias collides with a module name"),
            error.MissingModule => return self.undefinedModule(target),
            error.InvalidDefinition => return self.fail(.domain, "module and alias names must be unqualified"),
        };
    }
    pub fn undefinedModule(self: *Machine, name: u32) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined module `{s}`", .{intern.get(name)});
        self.unit.pending.?.addData(.name, .{ .symbol = name });
        return failure;
    }
    pub fn undefinedName(self: *Machine, name: u32) MachineError {
        self.active_word = name;
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(name)});
        self.unit.pending.?.addData(.name, .{ .symbol = name });
        return failure;
    }
    pub fn resolveName(self: *Machine, name: u32) error{OutOfMemory}!?Resolution {
        return resolveWord(self, name);
    }
    pub fn visibleNamesOwned(self: *Machine) error{OutOfMemory}![]u32 {
        var found: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer found.deinit(self.unit.allocator);
        var scope: ?*env.Scope = self.current.?.scope;
        while (scope) |current_scope| : (scope = current_scope.parent) {
            if (current_scope.environment) |environment| {
                const direct = try environment.namesOwned(self.unit.allocator);
                defer self.unit.allocator.free(direct);
                for (direct) |name| try found.put(self.unit.allocator, name, {});
                if (self.unit.registry) |registry| {
                    const uses = environment.useOrder();
                    var index = uses.len;
                    while (index > 0) {
                        index -= 1;
                        var generation_lease = registry.acquire(uses[index]) orelse continue;
                        defer generation_lease.deinit();
                        const names = try generation_lease.generation.publicNamesOwned(self.unit.allocator);
                        defer self.unit.allocator.free(names);
                        for (names) |name| if (!found.contains(name)) {
                            try found.put(self.unit.allocator, name, {});
                        };
                    }
                }
            }
        }
        const core_names = try self.unit.environment.core.namesOwned(self.unit.allocator);
        defer self.unit.allocator.free(core_names);
        for (core_names) |name| if (!found.contains(name)) try found.put(self.unit.allocator, name, {});
        const result = try self.unit.allocator.alloc(u32, found.count());
        var iterator = found.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |name| : (index += 1) result[index] = name.*;
        return result;
    }
    pub fn shadowTraceIdsOwned(self: *Machine, name: u32) error{OutOfMemory}![]u32 {
        if (std.mem.indexOfScalar(u8, intern.get(name), '.') != null) return self.unit.allocator.alloc(u32, 0);
        var result: std.ArrayList(u32) = .empty;
        errdefer result.deinit(self.unit.allocator);
        var found_winner = false;
        var scope: ?*env.Scope = self.current.?.scope;
        while (scope) |current_scope| : (scope = current_scope.parent) {
            if (current_scope.environment) |environment| {
                if (environment.resolveDirect(name)) |loaded| {
                    var lease = loaded;
                    defer lease.deinit(self.unit.allocator);
                    const trace_word = if (lease.home) |home|
                        try qualifiedWordId(self.unit.allocator, home, name)
                    else
                        name;
                    if (found_winner) try result.append(self.unit.allocator, trace_word) else found_winner = true;
                }
                if (self.unit.registry) |registry| {
                    const uses = environment.useOrder();
                    var index = uses.len;
                    while (index > 0) {
                        index -= 1;
                        var generation_lease = registry.acquire(uses[index]) orelse continue;
                        defer generation_lease.deinit();
                        var lease = generation_lease.generation.resolve(name, true) orelse continue;
                        defer lease.deinit(self.unit.allocator);
                        const trace_word = try qualifiedWordId(
                            self.unit.allocator,
                            generation_lease.generation.name,
                            name,
                        );
                        if (found_winner) try result.append(self.unit.allocator, trace_word) else found_winner = true;
                    }
                }
            }
        }
        if (self.unit.environment.core.resolveDirect(name)) |loaded| {
            var lease = loaded;
            defer lease.deinit(self.unit.allocator);
            if (found_winner) try result.append(self.unit.allocator, name);
        }
        return result.toOwnedSlice(self.unit.allocator);
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
        const scope = self.current.?.scope;
        const home = self.current.?.home;
        const inherited_trace = self.suspendCurrent() catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = quotation,
            .ip = 0,
            .scope = scope,
            .home = home,
            .traced_word = inherited_trace,
        };
    }
    /// Consumes both values and restores `protected` after the quotation.
    pub fn dipOwned(
        self: *Machine,
        quotation: *Header,
        protected: Value,
    ) error{OutOfMemory}!void {
        const scope = self.current.?.scope;
        const home = self.current.?.home;
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
            .scope = scope,
            .home = home,
            .traced_word = inherited_trace,
        };
    }
    /// Consumes condition and body and schedules the iterative while frames.
    pub fn whileOwned(
        self: *Machine,
        condition: *Header,
        body: *Header,
    ) error{OutOfMemory}!void {
        const scope = self.current.?.scope;
        const home = self.current.?.home;
        const word = self.active_word;
        const inherited_trace = self.suspendCurrent() catch {
            heap.decRef(self.unit.allocator, condition);
            heap.decRef(self.unit.allocator, body);
            return error.OutOfMemory;
        };
        self.appendFrame(.{ .while_after_cond = .{
            .condition = condition,
            .body = body,
            .scope = scope,
            .home = home,
            .base = @intCast(self.unit.stack.items.len),
            .word = word,
        } }) catch return error.OutOfMemory;
        heap.incRef(condition);
        self.current = .{
            .code = condition,
            .ip = 0,
            .scope = scope,
            .home = home,
            .traced_word = inherited_trace,
        };
    }
    pub fn attemptOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        return self.beginBoundaryOwned(.attempt, quotation);
    }
    pub fn dictOwned(self: *Machine, quotation: *Header) error{OutOfMemory}!void {
        return self.beginBoundaryOwned(.dict_of, quotation);
    }
    pub fn moduleOwned(self: *Machine, name: u32, quotation: *Header) MachineError!void {
        const registry = self.unit.registry orelse {
            heap.decRef(self.unit.allocator, quotation);
            return self.fail(.domain, "module registry is unavailable");
        };
        const word = self.active_word;
        const candidate = registry.createCandidate(name) catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        _ = self.suspendCurrent() catch {
            candidate.destroy();
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= no_boundary) {
            candidate.destroy();
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        }
        const index: u32 = @intCast(self.unit.frames.items.len);
        self.appendFrame(.{ .boundary = .{
            .kind = .module,
            .stack_base = @intCast(self.unit.stack.items.len),
            .previous_base = @intCast(self.unit.stack_base),
            .previous_boundary = self.unit.boundary_index,
            .word = word,
            .scope = &candidate.scope,
            .candidate = candidate,
        } }) catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        self.unit.boundary_index = index;
        self.unit.stack_base = self.unit.stack.items.len;
        self.current = .{
            .code = quotation,
            .ip = 0,
            .scope = &candidate.scope,
            .home = candidate,
            .traced_word = no_word,
        };
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
        const parent_scope = self.current.?.scope;
        const home = self.current.?.home;
        const word = self.active_word;
        const child = self.unit.allocator.create(env.Scope) catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        child.* = env.Scope.lazy(self.unit.allocator, parent_scope);
        _ = self.suspendCurrent() catch {
            child.deinit();
            self.unit.allocator.destroy(child);
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        if (self.unit.frames.items.len >= no_boundary) {
            child.deinit();
            self.unit.allocator.destroy(child);
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
            .scope = child,
        } }) catch {
            heap.decRef(self.unit.allocator, quotation);
            return error.OutOfMemory;
        };
        self.unit.boundary_index = index;
        self.unit.stack_base = self.unit.stack.items.len;
        self.current = .{
            .code = quotation,
            .ip = 0,
            .scope = child,
            .home = home,
            .traced_word = no_word,
        };
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
            .scope = &unit.root_scope,
            .home = null,
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
    var resolved = (try resolveWord(self, word)) orelse {
        self.active_word = word;
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(word)});
        self.unit.pending.?.addData(.name, .{ .symbol = word });
        return failure;
    };
    defer resolved.deinit(self.unit.allocator);
    self.active_word = resolved.trace_word;
    const cross_home = resolved.home != null and resolved.home != self.current.?.home;
    switch (resolved.lease.binding) {
        .value => |item| try self.pushBorrowed(item),
        .word => |body| try scheduleWord(
            self,
            body,
            resolved.trace_word,
            resolved.home,
            if (cross_home) resolved.lease.effect else null,
        ),
        .primitive => |primitive| {
            const check = if (cross_home)
                try prepareEffectCheck(self, resolved.lease.effect, resolved.trace_word)
            else
                null;
            try primitive(self);
            if (check) |effect_check| try finishEffectCheck(self, effect_check);
        },
    }
}
pub const ResolutionOrigin = enum { direct, used, module, core };
pub const Resolution = struct {
    lease: env.BindingLease,
    generation_lease: ?modules.GenerationLease,
    home: ?*modules.ModuleGeneration,
    trace_word: u32,
    origin: ResolutionOrigin,
    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        self.lease.deinit(allocator);
        if (self.generation_lease) |*lease| lease.deinit();
        self.* = undefined;
    }
};
fn resolveWord(self: *Machine, word: u32) error{OutOfMemory}!?Resolution {
    const spelling = intern.get(word);
    if (std.mem.indexOfScalar(u8, spelling, '.')) |dot| {
        const registry = self.unit.registry orelse return null;
        if (dot == 0 or dot + 1 == spelling.len) return null;
        const prefix = try intern.intern(spelling[0..dot]);
        const export_name = try intern.intern(spelling[dot + 1 ..]);
        var generation_lease = registry.acquire(prefix) orelse return null;
        const generation = generation_lease.generation;
        var lease = generation.resolve(export_name, true) orelse {
            generation_lease.deinit();
            return null;
        };
        errdefer {
            lease.deinit(self.unit.allocator);
            generation_lease.deinit();
        }
        return .{
            .lease = lease,
            .generation_lease = generation_lease,
            .home = generation,
            .trace_word = try qualifiedWordId(self.unit.allocator, generation.name, export_name),
            .origin = .module,
        };
    }
    var scope: ?*env.Scope = self.current.?.scope;
    while (scope) |current_scope| : (scope = current_scope.parent) {
        if (current_scope.environment) |environment| {
            if (environment.resolveDirect(word)) |loaded| {
                var lease = loaded;
                errdefer lease.deinit(self.unit.allocator);
                const home = if (lease.home != null and self.current.?.home != null and
                    lease.home.? == self.current.?.home.?.name)
                    self.current.?.home
                else
                    null;
                return .{
                    .lease = lease,
                    .generation_lease = null,
                    .home = home,
                    .trace_word = if (home) |generation|
                        try qualifiedWordId(self.unit.allocator, generation.name, word)
                    else
                        word,
                    .origin = if (home != null) .module else .direct,
                };
            }
            if (self.unit.registry) |registry| {
                const uses = environment.useOrder();
                var index = uses.len;
                while (index > 0) {
                    index -= 1;
                    var generation_lease = registry.acquire(uses[index]) orelse continue;
                    const generation = generation_lease.generation;
                    var lease = generation.resolve(word, true) orelse {
                        generation_lease.deinit();
                        continue;
                    };
                    errdefer {
                        lease.deinit(self.unit.allocator);
                        generation_lease.deinit();
                    }
                    return .{
                        .lease = lease,
                        .generation_lease = generation_lease,
                        .home = generation,
                        .trace_word = try qualifiedWordId(self.unit.allocator, generation.name, word),
                        .origin = .used,
                    };
                }
            }
        }
    }
    if (self.unit.environment.core.resolveDirect(word)) |lease| {
        return .{ .lease = lease, .generation_lease = null, .home = null, .trace_word = word, .origin = .core };
    }
    return null;
}
fn qualifiedWordId(
    allocator: std.mem.Allocator,
    module_name: u32,
    word: u32,
) error{OutOfMemory}!u32 {
    const module_bytes = intern.get(module_name);
    const word_bytes = intern.get(word);
    const bytes = try allocator.alloc(u8, module_bytes.len + 1 + word_bytes.len);
    defer allocator.free(bytes);
    @memcpy(bytes[0..module_bytes.len], module_bytes);
    bytes[module_bytes.len] = '.';
    @memcpy(bytes[module_bytes.len + 1 ..], word_bytes);
    return intern.intern(bytes);
}
fn emitShadowNotices(self: *Machine, scope: *env.Scope, canonical: u32) MachineError!void {
    const output = self.unit.diagnostics orelse return;
    var generation_lease = self.unit.registry.?.acquire(canonical).?;
    defer generation_lease.deinit();
    const generation = generation_lease.generation;
    const names = try generation.publicNamesOwned(self.unit.allocator);
    defer self.unit.allocator.free(names);
    std.mem.sort(u32, names, {}, struct {
        fn lessThan(_: void, left: u32, right: u32) bool {
            return std.mem.lessThan(u8, intern.get(left), intern.get(right));
        }
    }.lessThan);
    const direct = scope.environment orelse return;
    for (names) |name| {
        if (direct.cell(name) == null) continue;
        output.print(
            "session `{s}` shadows `{s}.{s}`\n",
            .{ intern.get(name), intern.get(generation.name), intern.get(name) },
        ) catch return self.fail(.io, "standard error write failed");
    }
    output.flush() catch return self.fail(.io, "standard error flush failed");
}
fn scheduleWord(
    self: *Machine,
    body: *Header,
    word: u32,
    resolved_home: ?*modules.ModuleGeneration,
    effect: ?env.Effect,
) MachineError!void {
    const scope = if (resolved_home) |home| &home.scope else self.current.?.scope;
    const home = resolved_home orelse self.current.?.home;
    if (resolved_home) |generation| try self.unit.pinGeneration(generation);
    const check = if (effect != null) try prepareEffectCheck(self, effect, word) else null;
    _ = self.suspendCurrent() catch return error.OutOfMemory;
    if (check) |effect_check| try self.appendFrame(.{ .effect_check = effect_check });
    heap.incRef(body);
    self.current = .{ .code = body, .ip = 0, .scope = scope, .home = home, .traced_word = word };
}
fn prepareEffectCheck(
    self: *Machine,
    effect: ?env.Effect,
    word: u32,
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
                .scope = continuation.scope,
                .home = continuation.home,
                .word = continuation.word,
            } });
            heap.incRef(continuation.body);
            self.current = .{
                .code = continuation.body,
                .ip = 0,
                .scope = continuation.scope,
                .home = continuation.home,
                .traced_word = no_word,
            };
            return true;
        },
        .while_after_body => |continuation| {
            try self.appendFrame(.{ .while_after_cond = .{
                .condition = continuation.condition,
                .body = continuation.body,
                .scope = continuation.scope,
                .home = continuation.home,
                .base = @intCast(self.unit.stack.items.len),
                .word = continuation.word,
            } });
            heap.incRef(continuation.condition);
            self.current = .{
                .code = continuation.condition,
                .ip = 0,
                .scope = continuation.scope,
                .home = continuation.home,
                .traced_word = no_word,
            };
            return true;
        },
        .effect_check => |check| try finishEffectCheck(self, check),
        .use_after_load => |continuation| {
            defer heap.releaseValue(self.unit.allocator, continuation.path);
            continuation.registry.endLoading(continuation.name);
            self.active_word = try intern.intern("use");
            if (!try self.installUse(continuation.scope, continuation.name)) {
                const failure = self.undefinedModule(continuation.name);
                self.unit.pending.?.addData(.path, continuation.path);
                return failure;
            }
        },
        .boundary => |boundary| {
            defer if (boundary.kind != .module) boundary.deinit(self.unit.allocator);
            std.debug.assert(self.unit.boundary_index == self.unit.frames.items.len);
            self.unit.boundary_index = boundary.previous_boundary;
            self.unit.stack_base = boundary.previous_base;
            self.active_word = boundary.word;
            switch (boundary.kind) {
                .attempt => try finishAttempt(self, boundary.stack_base),
                .dict_of => try finishDict(self, boundary.stack_base),
                .module => try finishModule(self, boundary),
            }
        },
    };
    return false;
}
fn continuationFrameRelease(allocator: std.mem.Allocator, a: *Header, b: *Header) void {
    heap.decRef(allocator, a);
    heap.decRef(allocator, b);
}
fn finishEffectCheck(self: *Machine, check: EffectCheck) MachineError!void {
    const observed = self.unit.stack.items.len;
    if (observed == check.expected_depth) return;
    self.active_word = check.word;
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
fn finishModule(self: *Machine, boundary: Boundary) MachineError!void {
    const candidate = boundary.candidate.?;
    var candidate_owned = true;
    defer if (candidate_owned) candidate.destroy();
    const base: usize = boundary.stack_base;
    const observed = self.unit.stack.items.len - base;
    if (observed != 0) {
        truncateStack(self, base);
        const failure = self.failFmt(
            .contract,
            "module body must leave an empty stack; observed {d} values",
            .{observed},
        );
        self.unit.pending.?.addData(.seeded, .{ .int = 0 });
        self.unit.pending.?.addData(.observed, .{ .int = @intCast(observed) });
        return failure;
    }
    _ = self.unit.registry.?.commit(candidate) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NameConflict => return self.fail(.domain, "module name collides with an alias"),
        error.MissingModule => unreachable,
        error.InvalidDefinition => return self.fail(.domain, "module names must be unqualified"),
    };
    candidate_owned = false;
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
    while (index > @as(usize, attempt_index) + 1) {
        index -= 1;
        self.unit.frames.items[index].deinit(self.unit.allocator);
    }
    boundary.deinit(self.unit.allocator);
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
            .restore, .while_after_cond, .while_after_body, .effect_check, .use_after_load, .boundary => {},
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
