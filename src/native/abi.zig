//! Exact, C-shaped wire contract shared by ecl and the `ecl-native` SDK.
//!
//! This pre-release contract does not negotiate record tails or capability
//! versions. Every sized record and array stride must match this definition.

const builtin = @import("builtin");

pub const entry_symbol: [:0]const u8 = "ecl_module_abi_v2";
pub const abi_version: u32 = 2;

pub const max_error_message_bytes: u32 = 4096;
pub const max_guest_scalar_bytes: u32 = 4096;
pub const max_builder_slots: u32 = 1024;
pub const max_continuation_state_bytes: u32 = 4096;
pub const max_continuation_alignment: u32 = 64;
/// How deep a nested input read may address. The bound is what keeps one
/// `read_path` call constant-cost — and, for recursive formats, keeps a
/// pathological document a bounded error instead of unbounded host work.
pub const max_read_path_depth: u32 = 64;

pub const CapabilityId = enum(u32) {
    call = 1,
    build_values = 2,
    reschedule = 3,
    ports = 4,
    _,
};

pub const CallResult = enum(u32) {
    complete = 0,
    fail = 1,
    yield = 2,
    _,
};

pub const ErrorKindWire = enum(u32) {
    type = 0,
    shape = 1,
    conform = 2,
    overflow = 3,
    domain = 4,
    parse = 5,
    io = 6,
    user = 7,
    _,
};

pub const EntryStatus = enum(u32) {
    descriptor = 0,
    fail = 1,
    _,
};

pub const HostStatus = enum(u32) {
    ok = 0,
    out_of_memory = 1,
    invalid = 2,
    yield_required = 3,
    _,
};

pub const ValueKindWire = enum(u32) {
    int = 0,
    float = 1,
    char = 2,
    symbol = 3,
    word = 4,
    list = 5,
    dict = 6,
    port = 7,
    _,
};

pub const Candidate = u64;

pub const max_port_definitions = 64;
pub const max_port_state_bytes = 1 << 20;
pub const max_operation_slots = 16;

pub const PortAction = enum(u32) { create, check, begin, write, finish_request, read, result, wait, close, release, _ };
pub const PortStatus = enum(u32) { ready, pending, failed, _ };
pub const PortRequest = extern struct {
    size: u32 = @sizeOf(PortRequest),
    action: PortAction,
    definition: u32,
    slot: u32 = 0,
    port: Candidate = 0,
    operation: u32 = 0,
    interests: u32 = 3,
    bytes: ?[*]u8 = null,
    length: u32 = 0,
};
pub const PortReply = extern struct {
    size: u32 = @sizeOf(PortReply),
    status: PortStatus = .ready,
    candidate: Candidate = 0,
    transferred: u32 = 0,
};
pub const PortFn = *const fn (*anyopaque, *const PortRequest, *PortReply) callconv(.c) HostStatus;
/// Controller streams block only their private host controller. Zero bytes
/// denotes request EOF or cancellation; failure is reported separately.
pub const ControllerTable = extern struct {
    read: *const fn (*anyopaque, [*]u8, u32) callconv(.c) u32,
    write: *const fn (*anyopaque, [*]const u8, u32) callconv(.c) u32,
    cancelled: *const fn (*anyopaque) callconv(.c) bool,
    fail: *const fn (*anyopaque, ErrorKindWire, [*]const u8, u32) callconv(.c) void,
};
pub const PortControllerFn = *const fn (*anyopaque, *const ControllerTable, *anyopaque) callconv(.c) void;
pub const PortOperationFn = *const fn (*anyopaque, u32, *const ControllerTable, *anyopaque) callconv(.c) void;
pub const PortDefinition = extern struct {
    size: u32 = @sizeOf(PortDefinition),
    state_size: u32,
    state_alignment: u32,
    name_len: u32,
    name_ptr: [*]const u8,
    init_state: ?StateInitFn,
    initialize: ?PortControllerFn,
    execute: ?PortOperationFn,
    cancel: ?StateDeinitFn,
    cleanup: ?StateDeinitFn,
};

pub const CapabilityRequirement = extern struct {
    size: u32 = @sizeOf(CapabilityRequirement),
    id: u32,
};

pub const EffectSlot = extern struct {
    size: u32 = @sizeOf(EffectSlot),
    name_ptr: [*]const u8,
    name_len: u64,
};

pub const Definition = extern struct {
    size: u32 = @sizeOf(Definition),
    callback_index: u32,
    name_ptr: [*]const u8,
    name_len: u64,
    doc_ptr: [*]const u8,
    doc_len: u64,
    input_count: u32,
    input_record_size: u32 = @sizeOf(EffectSlot),
    inputs_ptr: [*]const EffectSlot,
    output_count: u32,
    output_record_size: u32 = @sizeOf(EffectSlot),
    outputs_ptr: [*]const EffectSlot,
    continuation_size: u32 = 0,
    continuation_alignment: u32 = 0,
    init_continuation: ?StateInitFn = null,
    deinit_continuation: ?StateDeinitFn = null,
};

pub const ValueView = extern struct {
    size: u32 = @sizeOf(ValueView),
    kind: ValueKindWire,
    scalar_bits: u64 = 0,
    aggregate_len: u64 = 0,
    bytes_ptr: ?[*]const u8 = null,
    bytes_len: u64 = 0,
};

pub const Scalar = extern struct {
    size: u32 = @sizeOf(Scalar),
    kind: ValueKindWire,
    bits: u64 = 0,
    bytes_ptr: ?[*]const u8 = null,
    bytes_len: u64 = 0,
};

pub const InvokeResult = extern struct {
    size: u32 = @sizeOf(InvokeResult),
    tag: CallResult,
    adapter_status: u64 = 0,
};

pub const InputFn = *const fn (
    call_context: *anyopaque,
    index: u32,
    output: *ValueView,
) callconv(.c) HostStatus;
pub const ForwardFn = *const fn (
    call_context: *anyopaque,
    index: u32,
    output: *Candidate,
) callconv(.c) HostStatus;
pub const ScalarFn = *const fn (
    call_context: *anyopaque,
    scalar: *const Scalar,
    output: *Candidate,
) callconv(.c) HostStatus;
pub const BuildListAppendFn = *const fn (
    call_context: *anyopaque,
    slot: u32,
    item_count: u64,
    item: Candidate,
) callconv(.c) HostStatus;
pub const BuildListFinishFn = *const fn (
    call_context: *anyopaque,
    slot: u32,
    item_count: u64,
    output: *Candidate,
) callconv(.c) HostStatus;
pub const BuildDictAppendFn = *const fn (
    call_context: *anyopaque,
    slot: u32,
    entry_count: u64,
    key: Candidate,
    item: Candidate,
) callconv(.c) HostStatus;
pub const BuildDictFinishFn = *const fn (
    call_context: *anyopaque,
    slot: u32,
    entry_count: u64,
    output: *Candidate,
) callconv(.c) HostStatus;
pub const ListAtFn = *const fn (
    call_context: *anyopaque,
    input_index: u32,
    item_index: u64,
    output: *ValueView,
) callconv(.c) HostStatus;
pub const DictAtFn = *const fn (
    call_context: *anyopaque,
    input_index: u32,
    item_index: u64,
    key_output: *ValueView,
    value_output: *ValueView,
) callconv(.c) HostStatus;
/// Reads one value nested inside a declared aggregate input. `path` holds one
/// step per level from the input's root: a list level is indexed directly,
/// while a dict level addresses entry `n`'s key as `2 * n` and its value as
/// `2 * n + 1`. An empty path names the input itself. Cost is bounded by
/// `max_read_path_depth`, and the budget is charged per step walked.
pub const ReadPathFn = *const fn (
    call_context: *anyopaque,
    input_index: u32,
    path_ptr: [*]const u64,
    path_len: u32,
    output: *ValueView,
) callconv(.c) HostStatus;
/// Retains the value addressed by the same bounded path as `read_path` in
/// the current invocation's candidate table. No backend authority is granted.
pub const ForwardPathFn = *const fn (
    call_context: *anyopaque,
    input_index: u32,
    path_ptr: [*]const u64,
    path_len: u32,
    output: *Candidate,
) callconv(.c) HostStatus;
pub const CompleteFn = *const fn (
    call_context: *anyopaque,
    outputs: [*]const Candidate,
    output_count: u32,
) callconv(.c) HostStatus;
pub const FailFn = *const fn (
    call_context: *anyopaque,
    kind: ErrorKindWire,
    message_ptr: [*]const u8,
    message_len: u32,
) callconv(.c) HostStatus;
pub const StateInitFn = *const fn (state: *anyopaque) callconv(.c) void;
pub const StateDeinitFn = *const fn (state: *anyopaque) callconv(.c) void;
pub const ContinuationStateFn = *const fn (
    call_context: *anyopaque,
    output: *?*anyopaque,
) callconv(.c) HostStatus;
pub const ConsumeFn = *const fn (
    call_context: *anyopaque,
    units: u32,
) callconv(.c) HostStatus;
pub const RequestYieldFn = *const fn (call_context: *anyopaque) callconv(.c) HostStatus;

pub const HostTable = extern struct {
    size: u32 = @sizeOf(HostTable),
    input: InputFn,
    forward: ForwardFn,
    scalar: ScalarFn,
    complete: CompleteFn,
    fail: FailFn,
    continuation_state: ?ContinuationStateFn,
    consume: ?ConsumeFn,
    request_yield: ?RequestYieldFn,
    list_at: ?ListAtFn,
    dict_at: ?DictAtFn,
    read_path: ?ReadPathFn,
    build_list_append: ?BuildListAppendFn,
    build_list_finish: ?BuildListFinishFn,
    build_dict_append: ?BuildDictAppendFn,
    build_dict_finish: ?BuildDictFinishFn,
    forward_path: ?ForwardPathFn = null,
    port: ?PortFn = null,
};

pub const Invoke = *const fn (
    host: *const HostTable,
    call_context: *anyopaque,
    callback_index: u32,
    output: *InvokeResult,
) callconv(.c) void;

pub const Descriptor = extern struct {
    size: u32 = @sizeOf(Descriptor),
    abi_version: u32 = abi_version,
    module_name_ptr: [*]const u8,
    module_name_len: u64,
    module_doc_ptr: [*]const u8,
    module_doc_len: u64,
    definition_count: u32,
    definition_record_size: u32 = @sizeOf(Definition),
    definitions_ptr: [*]const Definition,
    capability_count: u32,
    capability_record_size: u32 = @sizeOf(CapabilityRequirement),
    capabilities_ptr: [*]const CapabilityRequirement,
    callback_count: u32,
    invoke: ?Invoke,
    port_count: u32 = 0,
    port_record_size: u32 = @sizeOf(PortDefinition),
    ports_ptr: ?[*]const PortDefinition = null,
};

pub const EntryResult = extern struct {
    size: u32 = @sizeOf(EntryResult),
    status: EntryStatus,
    descriptor: ?*const Descriptor = null,
    message_ptr: ?[*]const u8 = null,
    message_len: u64 = 0,
};

pub const EntryFn = *const fn (output: *EntryResult) callconv(.c) void;

fn assertWireField(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool, .void, .@"opaque" => {},
        .@"enum" => |enumeration| if (enumeration.is_exhaustive)
            @compileError("native ABI wire enums must have a non-exhaustive `_` tag: " ++ @typeName(T)),
        .pointer => |pointer| {
            if (pointer.size == .slice)
                @compileError("native ABI records cannot contain Zig slices");
            assertWireField(pointer.child);
        },
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => assertWireField(optional.child),
            else => @compileError("native ABI optionals must be pointer-shaped"),
        },
        .@"fn" => |function| {
            const CallingConvention = @TypeOf(function.calling_convention);
            const convention: CallingConvention.Tag = function.calling_convention;
            const c_convention: CallingConvention.Tag = builtin.target.cCallingConvention().?;
            if (convention != c_convention or
                function.is_generic or function.is_var_args)
                @compileError("native ABI callbacks must be non-generic C functions");
            inline for (function.params) |parameter| {
                if (parameter.type == null) @compileError("native ABI callbacks require concrete parameters");
                assertWireField(parameter.type.?);
            }
            if (function.return_type) |Return| assertWireField(Return);
        },
        .@"struct" => |record| {
            if (record.layout != .@"extern")
                @compileError("native ABI nested records must use extern layout");
            inline for (record.fields) |field| assertWireField(field.type);
        },
        else => @compileError("native ABI records contain a non-wire field type: " ++ @typeName(T)),
    }
}

fn assertRecord(comptime T: type, comptime expected_size: usize, comptime expected_alignment: usize) void {
    const record = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("native ABI record must be a struct"),
    };
    if (record.layout != .@"extern") @compileError("native ABI record must use extern layout");
    inline for (record.fields) |field| assertWireField(field.type);
    if (@sizeOf(T) != expected_size or @alignOf(T) != expected_alignment)
        @compileError("native ABI record layout changed: " ++ @typeName(T));
}

comptime {
    @setEvalBranchQuota(8000);
    if (@sizeOf(usize) != 8) @compileError("native ABI v2 supports 64-bit targets only");

    assertRecord(CapabilityRequirement, 8, 4);
    assertRecord(EffectSlot, 24, 8);
    assertRecord(Definition, 96, 8);
    assertRecord(ValueView, 40, 8);
    assertRecord(Scalar, 32, 8);
    assertRecord(InvokeResult, 16, 8);
    assertRecord(HostTable, 144, 8);
    assertRecord(Descriptor, 104, 8);
    assertRecord(PortDefinition, 64, 8);
    assertRecord(PortRequest, 48, 8);
    assertRecord(PortReply, 24, 8);
    assertRecord(ControllerTable, 32, 8);
    assertRecord(EntryResult, 32, 8);

    if (@offsetOf(Definition, "callback_index") != 4 or
        @offsetOf(Definition, "name_ptr") != 8 or
        @offsetOf(Definition, "inputs_ptr") != 48 or
        @offsetOf(Definition, "outputs_ptr") != 64)
        @compileError("native ABI Definition offsets changed");
    if (@offsetOf(Descriptor, "module_name_ptr") != 8 or
        @offsetOf(Descriptor, "definitions_ptr") != 48 or
        @offsetOf(Descriptor, "capabilities_ptr") != 64 or
        @offsetOf(Descriptor, "invoke") != 80)
        @compileError("native ABI Descriptor offsets changed");

    // The SDK does not import machine.zig. Keeping this list closed and
    // name-stable lets the runtime assert the inverse mapping exhaustively.
    const expected_error_names = [_][]const u8{
        "type", "shape", "conform", "overflow", "domain", "parse", "io", "user",
    };
    const fields = @typeInfo(ErrorKindWire).@"enum".fields;
    if (fields.len != expected_error_names.len)
        @compileError("native ABI author error-kind set changed");
    for (fields, expected_error_names) |field, expected|
        if (!sameBytes(field.name, expected)) @compileError("native ABI author error-kind mapping changed");
}

fn sameBytes(comptime left: []const u8, comptime right: []const u8) bool {
    if (left.len != right.len) return false;
    inline for (left, right) |a, b| if (a != b) return false;
    return true;
}
