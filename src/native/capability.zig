//! Author-facing values for the closed native capability set.

const std = @import("std");
const abi = @import("ecl-native-abi");

pub const Outcome = enum(u32) {
    complete = @intFromEnum(abi.CallResult.complete),
    fail = @intFromEnum(abi.CallResult.fail),
    yield = @intFromEnum(abi.CallResult.yield),
};

pub const Kind = abi.ValueKindWire;
pub const ErrorKind = abi.ErrorKindWire;

pub const Candidate = enum(u64) {
    invalid = 0,
    _,
};

pub const Scalar = struct {
    wire: abi.Scalar,

    pub fn int(item: i64) Scalar {
        return .{ .wire = .{ .kind = .int, .bits = @bitCast(item) } };
    }

    pub fn float(item: f64) Scalar {
        return .{ .wire = .{ .kind = .float, .bits = @bitCast(item) } };
    }

    pub fn char(item: u32) Scalar {
        return .{ .wire = .{ .kind = .char, .bits = item } };
    }

    pub fn symbol(bytes: []const u8) Scalar {
        return .{ .wire = .{
            .kind = .symbol,
            .bytes_ptr = bytes.ptr,
            .bytes_len = bytes.len,
        } };
    }

    pub fn word(bytes: []const u8) Scalar {
        return .{ .wire = .{
            .kind = .word,
            .bytes_ptr = bytes.ptr,
            .bytes_len = bytes.len,
        } };
    }
};

pub const ViewState = struct {
    wire: abi.ValueView,
    invocation: *Invocation,
    input_index: u32,
};

pub const CursorStep = union(enum) {
    item: *const ValueView,
    end,
    yield_required,
    invalid,
};

pub const DictCursorStep = union(enum) {
    item: struct { key: *const ValueView, value: *const ValueView },
    end,
    yield_required,
    invalid,
};

pub const ListCursorState = struct {
    invocation: *Invocation,
    input_index: u32,
    next_index: u64,
    length: u64,
    item_state: ViewState,
};

/// Opaque, turn-local, budget-charging access to one declared list input. It
/// owns no ECL storage and exposes no backing slice. Reopen it from a scalar
/// continuation position after yielding.
pub const ListCursor = opaque {
    fn state(self: *ListCursor) *ListCursorState {
        return @ptrCast(@alignCast(self));
    }

    pub fn initAdapter(
        cursor_state: *?ListCursorState,
        invocation: *Invocation,
        input_index: u32,
        length: u64,
        start: u64,
    ) *ListCursor {
        cursor_state.* = .{
            .invocation = invocation,
            .input_index = input_index,
            .next_index = start,
            .length = length,
            .item_state = .{
                .wire = .{ .kind = .int },
                .invocation = invocation,
                .input_index = input_index,
            },
        };
        return @ptrCast(&cursor_state.*.?);
    }

    pub fn next(self: *ListCursor) CursorStep {
        const cursor = self.state();
        if (cursor.next_index == cursor.length) return .end;
        const status = (cursor.invocation.host.list_at orelse unreachable)(
            cursor.invocation.context,
            cursor.input_index,
            cursor.next_index,
            &cursor.item_state.wire,
        );
        return switch (status) {
            .ok => item: {
                cursor.next_index += 1;
                break :item .{ .item = @ptrCast(&cursor.item_state) };
            },
            .yield_required => .yield_required,
            .invalid => .invalid,
            .out_of_memory => unreachable,
            _ => .invalid,
        };
    }
};

pub const DictCursorState = struct {
    invocation: *Invocation,
    input_index: u32,
    next_index: u64,
    length: u64,
    key_state: ViewState,
    value_state: ViewState,
};

/// Opaque, turn-local dictionary input access. Each successful step observes
/// one key/value pair and charges one scheduler budget unit.
pub const DictCursor = opaque {
    fn state(self: *DictCursor) *DictCursorState {
        return @ptrCast(@alignCast(self));
    }

    pub fn initAdapter(
        cursor_state: *?DictCursorState,
        invocation: *Invocation,
        input_index: u32,
        length: u64,
        start: u64,
    ) *DictCursor {
        const empty: ViewState = .{
            .wire = .{ .kind = .int },
            .invocation = invocation,
            .input_index = input_index,
        };
        cursor_state.* = .{
            .invocation = invocation,
            .input_index = input_index,
            .next_index = start,
            .length = length,
            .key_state = empty,
            .value_state = empty,
        };
        return @ptrCast(&cursor_state.*.?);
    }

    pub fn next(self: *DictCursor) DictCursorStep {
        const cursor = self.state();
        if (cursor.next_index == cursor.length) return .end;
        const status = (cursor.invocation.host.dict_at orelse unreachable)(
            cursor.invocation.context,
            cursor.input_index,
            cursor.next_index,
            &cursor.key_state.wire,
            &cursor.value_state.wire,
        );
        return switch (status) {
            .ok => item: {
                cursor.next_index += 1;
                break :item .{ .item = .{
                    .key = @ptrCast(&cursor.key_state),
                    .value = @ptrCast(&cursor.value_state),
                } };
            },
            .yield_required => .yield_required,
            .invalid => .invalid,
            .out_of_memory => unreachable,
            _ => .invalid,
        };
    }
};

pub const ValueView = opaque {
    fn state(self: *const ValueView) *const ViewState {
        return @ptrCast(@alignCast(self));
    }

    pub fn kind(self: *const ValueView) Kind {
        return self.state().wire.kind;
    }

    pub fn int(self: *const ValueView) ?i64 {
        return if (self.kind() == .int) @bitCast(self.state().wire.scalar_bits) else null;
    }

    pub fn float(self: *const ValueView) ?f64 {
        return if (self.kind() == .float) @bitCast(self.state().wire.scalar_bits) else null;
    }

    pub fn char(self: *const ValueView) ?u32 {
        return if (self.kind() == .char) @intCast(self.state().wire.scalar_bits) else null;
    }

    pub fn bytes(self: *const ValueView) ?[]const u8 {
        return switch (self.kind()) {
            .symbol, .word => self.state().wire.bytes_ptr.?[0..self.state().wire.bytes_len],
            .int, .float, .char, .list, .dict, .port => null,
            _ => null,
        };
    }

    pub fn aggregateLength(self: *const ValueView) ?u64 {
        return switch (self.kind()) {
            .list, .dict => self.state().wire.aggregate_len,
            .int, .float, .char, .symbol, .word, .port => null,
            _ => null,
        };
    }
};

/// One nested input read. `invalid` covers both a malformed path and a path
/// that leaves the aggregate, so an author never has to guess which of its
/// own index computations the host rejected.
pub const NestedStep = union(enum) {
    item: *const ValueView,
    yield_required,
    invalid,
};

/// One step of a path into a declared aggregate input. A list level is indexed
/// directly; a dict level addresses an entry's key or value. Building steps
/// through these constructors keeps the wire encoding out of author code.
pub const Path = struct {
    pub const max_depth: usize = abi.max_read_path_depth;

    pub fn item(index: u64) u64 {
        return index;
    }
    pub fn key(entry: u64) u64 {
        return entry * 2;
    }
    pub fn value(entry: u64) u64 {
        return entry * 2 + 1;
    }
};

pub const NestedState = struct {
    wire: abi.ValueView,
    invocation: *Invocation,
    input_index: u32,
};

pub const Invocation = struct {
    host: *const abi.HostTable,
    context: *anyopaque,

    pub fn makeCandidate(self: *Invocation, item: anytype) error{ OutOfMemory, InvalidValue }!Candidate {
        const Item = @TypeOf(item);
        if (Item == Candidate) return item;
        if (Item != Scalar) @compileError("ecl-native: outputs must be Candidate or Scalar values");
        var wire = item.wire;
        var result: abi.Candidate = 0;
        try requireOk(self.host.scalar(self.context, &wire, &result));
        return @enumFromInt(result);
    }
};

pub const BuildState = struct {
    invocation: *Invocation,
};

pub const BuildResult = union(enum) {
    candidate: Candidate,
    yield_required,
    invalid,
};

pub const BuildAppendResult = enum {
    appended,
    yield_required,
    invalid,
};

pub const BuildValues = opaque {
    fn state(self: *BuildValues) *BuildState {
        return @ptrCast(@alignCast(self));
    }

    pub fn scalar(self: *BuildValues, item: Scalar) error{ OutOfMemory, InvalidValue }!Candidate {
        return self.state().invocation.makeCandidate(item);
    }

    /// Append one value to a host-owned, exact-size list builder. `slot` is a
    /// logical identifier stored safely in continuation state; it is not a
    /// pointer or host handle. Repeating the same slot and count resumes the
    /// same builder on a later turn.
    pub fn appendList(
        self: *BuildValues,
        slot: u32,
        item_count: u64,
        item: Candidate,
    ) error{OutOfMemory}!BuildAppendResult {
        return buildAppendResult((self.state().invocation.host.build_list_append orelse unreachable)(
            self.state().invocation.context,
            slot,
            item_count,
            @intFromEnum(item),
        ));
    }

    pub fn finishList(
        self: *BuildValues,
        slot: u32,
        item_count: u64,
    ) error{OutOfMemory}!BuildResult {
        var output: abi.Candidate = 0;
        return buildResult(
            (self.state().invocation.host.build_list_finish orelse unreachable)(
                self.state().invocation.context,
                slot,
                item_count,
                &output,
            ),
            output,
        );
    }

    pub fn appendDict(
        self: *BuildValues,
        slot: u32,
        entry_count: u64,
        key: Candidate,
        item: Candidate,
    ) error{OutOfMemory}!BuildAppendResult {
        return buildAppendResult((self.state().invocation.host.build_dict_append orelse unreachable)(
            self.state().invocation.context,
            slot,
            entry_count,
            @intFromEnum(key),
            @intFromEnum(item),
        ));
    }

    pub fn finishDict(
        self: *BuildValues,
        slot: u32,
        entry_count: u64,
    ) error{OutOfMemory}!BuildResult {
        var output: abi.Candidate = 0;
        return buildResult(
            (self.state().invocation.host.build_dict_finish orelse unreachable)(
                self.state().invocation.context,
                slot,
                entry_count,
                &output,
            ),
            output,
        );
    }
};

fn buildAppendResult(status: abi.HostStatus) error{OutOfMemory}!BuildAppendResult {
    return switch (status) {
        .ok => .appended,
        .yield_required => .yield_required,
        .invalid => .invalid,
        .out_of_memory => error.OutOfMemory,
        _ => .invalid,
    };
}

fn buildResult(status: abi.HostStatus, output: abi.Candidate) error{OutOfMemory}!BuildResult {
    return switch (status) {
        .ok => .{ .candidate = @enumFromInt(output) },
        .yield_required => .yield_required,
        .invalid => .invalid,
        .out_of_memory => error.OutOfMemory,
        _ => .invalid,
    };
}

/// Typed cooperative continuation. State is host-owned, contains no pointers
/// or ephemeral capabilities, and survives only while the native call's real
/// scheduler WorkDriver is alive. The API exposes budget charging and yield,
/// never an allocator, scheduler, Unit, or raw ECL storage.
pub fn Reschedule(comptime Spec: type) type {
    comptime validateContinuationSpec(Spec);
    return opaque {
        const Self = @This();
        pub const ecl_reschedule_marker = void;
        pub const State = Spec.State;
        pub const continuation_size: u32 = @sizeOf(State);
        pub const continuation_alignment: u32 = @alignOf(State);

        pub const AdapterState = struct {
            invocation: *Invocation,
            state_ptr: *anyopaque,
        };

        pub fn initAdapter(invocation: *Invocation) error{OutOfMemory}!AdapterState {
            var state_ptr: ?*anyopaque = null;
            switch ((invocation.host.continuation_state orelse unreachable)(invocation.context, &state_ptr)) {
                .ok => {},
                .out_of_memory => return error.OutOfMemory,
                .invalid, .yield_required => unreachable,
                _ => unreachable,
            }
            return .{ .invocation = invocation, .state_ptr = state_ptr.? };
        }

        pub fn adapterPointer(adapter_state: *AdapterState) *Self {
            return @ptrCast(@alignCast(adapter_state));
        }

        fn adapterState(self: *Self) *AdapterState {
            return @ptrCast(@alignCast(self));
        }

        pub fn state(self: *Self) *State {
            return @ptrCast(@alignCast(self.adapterState().state_ptr));
        }

        pub fn consume(self: *Self, units: u32) bool {
            return switch ((self.adapterState().invocation.host.consume orelse unreachable)(
                self.adapterState().invocation.context,
                units,
            )) {
                .ok => true,
                .yield_required => false,
                .out_of_memory, .invalid => unreachable,
                _ => unreachable,
            };
        }

        pub fn yield(self: *Self) error{OutOfMemory}!Outcome {
            switch ((self.adapterState().invocation.host.request_yield orelse unreachable)(
                self.adapterState().invocation.context,
            )) {
                .ok, .yield_required => return .yield,
                .out_of_memory => return error.OutOfMemory,
                .invalid => unreachable,
                _ => unreachable,
            }
        }

        pub fn initState(raw: *anyopaque) callconv(.c) void {
            const state_ptr: *State = @ptrCast(@alignCast(raw));
            state_ptr.* = Spec.init();
        }

        pub fn deinitState(raw: *anyopaque) callconv(.c) void {
            const state_ptr: *State = @ptrCast(@alignCast(raw));
            Spec.deinit(state_ptr);
        }
    };
}

fn validateContinuationSpec(comptime Spec: type) void {
    if (!@hasDecl(Spec, "State") or !@hasDecl(Spec, "init") or !@hasDecl(Spec, "deinit"))
        @compileError("ecl-native: Reschedule spec requires State, init, and deinit");
    if (@TypeOf(Spec.init) != fn () Spec.State)
        @compileError("ecl-native: Reschedule init must return State");
    if (@TypeOf(Spec.deinit) != fn (*Spec.State) void)
        @compileError("ecl-native: Reschedule deinit must accept *State and return void");
    if (@sizeOf(Spec.State) == 0 or @sizeOf(Spec.State) > abi.max_continuation_state_bytes or
        @alignOf(Spec.State) > abi.max_continuation_alignment)
        @compileError("ecl-native: Reschedule State exceeds the supported size or alignment");
    validateContinuationState(Spec.State);
}

fn validateContinuationState(comptime State: type) void {
    if (State == Candidate or State == ValueView or State == BuildValues)
        @compileError("ecl-native: Reschedule State cannot embed an ephemeral capability");
    switch (@typeInfo(State)) {
        .bool, .int, .float, .@"enum" => {},
        .array => |array| validateContinuationState(array.child),
        .optional => |optional| validateContinuationState(optional.child),
        .@"struct" => |record| inline for (record.fields) |field|
            validateContinuationState(field.type),
        else => @compileError(
            "ecl-native: Reschedule State must contain only owned scalar value fields",
        ),
    }
}

pub fn requireOk(status: abi.HostStatus) error{ OutOfMemory, InvalidValue }!void {
    switch (status) {
        .ok => {},
        .out_of_memory => return error.OutOfMemory,
        .invalid, .yield_required => return error.InvalidValue,
        _ => return error.InvalidValue,
    }
}

comptime {
    if (@sizeOf(Candidate) != @sizeOf(abi.Candidate))
        @compileError("ecl-native Candidate wire size changed");
    _ = std;
}
