//! Transactional host implementation of the native call capability table.

const std = @import("std");
const abi = @import("native-abi");
const descriptor_api = @import("native_descriptor.zig");
const dict = @import("dict.zig");
const env = @import("env.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const storage = @import("kernel_storage.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const native_module = @import("native_module.zig");
const value = @import("value.zig");

const Value = value.Value;
const BuilderKind = enum { list, dict };

const BuilderOrigin = struct {
    slot: u32,
    serial: u32,
};

const CandidateEntry = struct {
    value: Value,
    origin: ?BuilderOrigin = null,
};

const ListBuild = struct {
    expected: usize,
    appended: usize = 0,
    source: ?heap.ListBuilder(.generic_spine),
    materializer: ?storage.ValueMaterializer = null,
    result: ?Value = null,

    fn init(allocator: std.mem.Allocator, expected: usize) error{OutOfMemory}!ListBuild {
        var source = try heap.ListBuilder(.generic_spine).init(allocator, expected, expected);
        source.setLen(0);
        return .{ .expected = expected, .source = source };
    }

    fn append(self: *ListBuild, item: Value) bool {
        if (self.materializer != null or self.result != null or self.appended == self.expected)
            return false;
        heap.retainValue(item);
        self.source.?.items()[self.appended] = item;
        self.appended += 1;
        self.source.?.setLen(self.appended);
        return true;
    }

    fn advance(self: *ListBuild, call: *Transaction) error{OutOfMemory}!?Value {
        if (self.result) |result| return result;
        if (self.appended != self.expected) return null;
        if (self.materializer == null)
            self.materializer = .init(call.allocator, self.source.?.items()[0..self.appended]);
        if (call.budget == 0) {
            call.yield_requested = true;
            return null;
        }
        while (call.budget != 0) {
            call.budget -= 1;
            switch (try self.materializer.?.advance(1)) {
                .pending => {},
                .complete => |result| {
                    self.materializer.?.deinit();
                    self.materializer = null;
                    self.source.?.retirePartial(call.releases);
                    self.source = null;
                    self.result = result;
                    return result;
                },
            }
        }
        call.yield_requested = true;
        return null;
    }

    fn retire(self: *ListBuild, releases: *heap.ReleaseDomain) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        if (self.source) |*source| source.retirePartial(releases);
        if (self.result) |result| releases.releaseValue(result);
    }
};

const DictBuild = struct {
    expected: usize,
    appended: usize = 0,
    keys: ?heap.ListBuilder(.generic_spine),
    values: ?heap.ListBuilder(.generic_spine),
    materializer: ?storage.DictMaterializer = null,
    result: ?Value = null,
    rejected: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        expected: usize,
    ) error{OutOfMemory}!DictBuild {
        var keys = try heap.ListBuilder(.generic_spine).init(allocator, expected, expected);
        keys.setLen(0);
        errdefer keys.retirePartial(releases);
        var values = try heap.ListBuilder(.generic_spine).init(allocator, expected, expected);
        values.setLen(0);
        return .{ .expected = expected, .keys = keys, .values = values };
    }

    fn append(self: *DictBuild, key: Value, item: Value) bool {
        if (self.materializer != null or self.result != null or self.rejected or
            self.appended == self.expected) return false;
        heap.retainValue(key);
        heap.retainValue(item);
        self.keys.?.items()[self.appended] = key;
        self.values.?.items()[self.appended] = item;
        self.appended += 1;
        self.keys.?.setLen(self.appended);
        self.values.?.setLen(self.appended);
        return true;
    }

    fn advance(self: *DictBuild, call: *Transaction) error{OutOfMemory}!?Value {
        if (self.result) |result| return result;
        if (self.rejected or self.appended != self.expected) return null;
        if (self.materializer == null) self.materializer = try .initSlices(
            call.allocator,
            self.keys.?.items()[0..self.appended],
            self.values.?.items()[0..self.appended],
            true,
        );
        if (call.budget == 0) {
            call.yield_requested = true;
            return null;
        }
        while (call.budget != 0) {
            call.budget -= 1;
            switch (try self.materializer.?.advance(1)) {
                .pending => {},
                .duplicate_key => {
                    self.materializer.?.retire(call.releases);
                    self.materializer = null;
                    self.keys.?.retirePartial(call.releases);
                    self.values.?.retirePartial(call.releases);
                    self.keys = null;
                    self.values = null;
                    self.rejected = true;
                    return null;
                },
                .complete => |result| {
                    self.materializer.?.deinit();
                    self.materializer = null;
                    self.keys.?.retirePartial(call.releases);
                    self.values.?.retirePartial(call.releases);
                    self.keys = null;
                    self.values = null;
                    self.result = result;
                    return result;
                },
            }
        }
        call.yield_requested = true;
        return null;
    }

    fn retire(self: *DictBuild, releases: *heap.ReleaseDomain) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        if (self.keys) |*keys| keys.retirePartial(releases);
        if (self.values) |*values| values.retirePartial(releases);
        if (self.result) |result| releases.releaseValue(result);
    }
};

const AggregateBuilder = struct {
    serial: u32,
    value: union(BuilderKind) {
        list: ListBuild,
        dict: DictBuild,
    },

    fn retire(self: *AggregateBuilder, releases: *heap.ReleaseDomain) void {
        switch (self.value) {
            inline else => |*builder| builder.retire(releases),
        }
    }
};

const Terminal = union(enum) {
    idle,
    complete,
    fail: struct {
        kind: machine.ErrorKind,
        message: [abi.max_error_message_bytes]u8,
        message_len: usize,
    },
};

const Transaction = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    active_evaluator: ?*machine.Machine = null,
    instance: *native_module.ModuleInstance,
    definition: *const descriptor_api.ValidatedDefinition,
    host_table: abi.HostTable,
    effect_check: ?machine.EffectCheck,
    candidates: std.ArrayList(CandidateEntry) = .empty,
    outputs: std.ArrayList(Value) = .empty,
    builders: [abi.max_builder_slots]?*AggregateBuilder =
        [_]?*AggregateBuilder{null} ** abi.max_builder_slots,
    next_builder_serial: u32 = 1,
    candidate_generation: u32 = 0,
    terminal: Terminal = .idle,
    continuation: ?[]align(64) u8 = null,
    budget: u32 = 0,
    yield_requested: bool = false,

    fn create(
        evaluator: *machine.Machine,
        callable: env.NativeCallable,
        definition: *const descriptor_api.ValidatedDefinition,
        effect_check: ?machine.EffectCheck,
    ) error{ OutOfMemory, NativeCallsClosed }!*Transaction {
        const call = try evaluator.allocator().create(Transaction);
        if (!callable.instance.retainCall()) {
            evaluator.allocator().destroy(call);
            return error.NativeCallsClosed;
        }
        call.* = .{
            .allocator = evaluator.allocator(),
            .releases = evaluator.releaseDomain(),
            .instance = callable.instance,
            .definition = definition,
            .host_table = callable.instance.mintHostTable(full_host_table),
            .effect_check = effect_check,
        };
        errdefer {
            call.instance.releasePin();
            evaluator.allocator().destroy(call);
        }
        if (definition.continuation_size != 0) {
            call.continuation = try evaluator.allocator().alignedAlloc(
                u8,
                .@"64",
                definition.continuation_size,
            );
            definition.init_continuation.?(call.continuation.?.ptr);
        }
        return call;
    }

    pub fn deinit(
        self: *Transaction,
        _: *heap.ReleaseDomain,
        _: std.mem.Allocator,
    ) void {
        for (self.outputs.items) |item| self.releases.releaseValue(item);
        self.clearCandidates();
        for (&self.builders) |*builder_entry| if (builder_entry.*) |owned| {
            owned.retire(self.releases);
            self.allocator.destroy(owned);
            builder_entry.* = null;
        };
        self.outputs.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        if (self.continuation) |state| {
            self.definition.deinit_continuation.?(state.ptr);
            self.allocator.free(state);
        }
        self.instance.releasePin();
    }

    fn appendCandidate(
        self: *Transaction,
        item: Value,
        origin: ?BuilderOrigin,
    ) abi.HostStatus {
        if (self.candidates.items.len >= machine.kernel_poll_quantum * 2 + 256) {
            self.releases.releaseValue(item);
            return .invalid;
        }
        self.candidates.append(self.allocator, .{ .value = item, .origin = origin }) catch {
            self.releases.releaseValue(item);
            return .out_of_memory;
        };
        return .ok;
    }

    fn candidate(self: *Transaction, wire: abi.Candidate) ?*const CandidateEntry {
        if (@as(u32, @truncate(wire >> 32)) != self.candidate_generation) return null;
        const low: u32 = @truncate(wire);
        if (low == 0) return null;
        const index: usize = low - 1;
        if (index >= self.candidates.items.len) return null;
        return &self.candidates.items[index];
    }

    fn candidateWire(self: *Transaction) abi.Candidate {
        return (@as(u64, self.candidate_generation) << 32) |
            @as(u32, @intCast(self.candidates.items.len));
    }

    fn clearCandidates(self: *Transaction) void {
        for (self.candidates.items) |entry| self.releases.releaseValue(entry.value);
        self.candidates.clearRetainingCapacity();
    }

    fn consumeOrigin(self: *Transaction, origin: ?BuilderOrigin) void {
        const identity = origin orelse return;
        if (identity.slot >= abi.max_builder_slots) return;
        const entry = &self.builders[identity.slot];
        const aggregate = entry.* orelse return;
        if (aggregate.serial != identity.serial) return;
        aggregate.retire(self.releases);
        self.allocator.destroy(aggregate);
        entry.* = null;
    }

    fn builder(
        self: *Transaction,
        slot: u32,
        expected_wire: u64,
        kind: BuilderKind,
    ) error{ OutOfMemory, Invalid }!*AggregateBuilder {
        if (slot >= abi.max_builder_slots) return error.Invalid;
        const expected = std.math.cast(usize, expected_wire) orelse return error.Invalid;
        if (expected >= std.math.maxInt(u32)) return error.Invalid;
        if (self.builders[slot]) |existing| {
            const matches = switch (existing.value) {
                .list => |builder_value| kind == .list and builder_value.expected == expected,
                .dict => |builder_value| kind == .dict and builder_value.expected == expected,
            };
            if (!matches) return error.Invalid;
            return existing;
        }
        const result = try self.allocator.create(AggregateBuilder);
        errdefer self.allocator.destroy(result);
        result.* = .{
            .serial = self.next_builder_serial,
            .value = switch (kind) {
                .list => .{ .list = try .init(self.allocator, expected) },
                .dict => .{ .dict = try .init(self.allocator, self.releases, expected) },
            },
        };
        self.next_builder_serial +%= 1;
        if (self.next_builder_serial == 0) self.next_builder_serial = 1;
        self.builders[slot] = result;
        return result;
    }

    fn activeEvaluator(self: *Transaction) *machine.Machine {
        return self.active_evaluator.?;
    }

    pub fn advance(
        evaluator: *machine.Machine,
        self: *Transaction,
    ) machine.MachineError!machine.WorkProgress {
        self.active_evaluator = evaluator;
        defer self.active_evaluator = null;
        try evaluator.pollKernel();
        self.budget = machine.kernel_poll_quantum;
        self.yield_requested = false;
        self.candidate_generation +%= 1;
        if (self.candidate_generation == 0) self.candidate_generation = 1;
        std.debug.assert(self.candidates.items.len == 0);
        defer self.clearCandidates();
        const timing = evaluator.beginNativeTiming();
        defer evaluator.finishNativeTiming(self.instance, timing);
        var result = abi.InvokeResult{ .tag = .fail, .adapter_status = 2 };
        self.instance.invoke()(&self.host_table, self, self.definition.callback_index, &result);
        if (result.size != @sizeOf(abi.InvokeResult))
            return evaluator.fail(.contract, "native callback returned an invalid result record size");
        if (result.adapter_status == 1) return error.OutOfMemory;
        if (result.adapter_status != 0)
            return evaluator.fail(.contract, "native callback returned an invalid adapter result");
        return switch (result.tag) {
            .complete => complete: {
                if (self.terminal != .complete)
                    return evaluator.fail(
                        .contract,
                        "native callback returned complete without committing its declared outputs",
                    );
                var replacement = try evaluator.reserveStackReplacement(
                    self.definition.effect.inputs,
                    self.definition.effect.outputs,
                );
                replacement.commitOwned(self.outputs.items);
                self.outputs.items.len = 0;
                if (self.effect_check) |check| try machine.finishEffectCheck(evaluator, check);
                break :complete .completed;
            },
            .fail => switch (self.terminal) {
                .fail => |failure| return evaluator.fail(
                    failure.kind,
                    failure.message[0..failure.message_len],
                ),
                .idle, .complete => return evaluator.fail(
                    .contract,
                    "native callback returned failure without a valid failure payload",
                ),
            },
            .yield => if (self.terminal != .idle or
                !self.instance.hasCapability(.reschedule) or !self.yield_requested)
                return evaluator.fail(
                    .contract,
                    "native callback yielded without Reschedule authority",
                )
            else
                .yielded,
            _ => return evaluator.fail(.contract, "native callback returned an unknown result tag"),
        };
    }
};

pub fn begin(
    evaluator: *machine.Machine,
    callable: env.NativeCallable,
    effect_check: ?machine.EffectCheck,
) machine.MachineError!void {
    const definition = callable.instance.definition(callable.definition);
    try evaluator.require(definition.effect.inputs);
    for (0..definition.effect.inputs) |index| switch (evaluator.nativeInputBorrowed(
        definition.effect.inputs,
        @intCast(index),
    )) {
        .task => return evaluator.fail(.type, "native words cannot observe task capabilities"),
        else => {},
    };
    const call = Transaction.create(evaluator, callable, definition, effect_check) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeCallsClosed => return evaluator.fail(
            .cancelled,
            "native call creation is closed during Session shutdown",
        ),
    };
    evaluator.adoptDriver(call);
}

const full_host_table = abi.HostTable{
    .input = hostInput,
    .forward = hostForward,
    .scalar = hostScalar,
    .complete = hostComplete,
    .fail = hostFail,
    .continuation_state = hostContinuationState,
    .consume = hostConsume,
    .request_yield = hostRequestYield,
    .list_at = hostListAt,
    .dict_at = hostDictAt,
    .build_list_append = hostBuildListAppend,
    .build_list_finish = hostBuildListFinish,
    .build_dict_append = hostBuildDictAppend,
    .build_dict_finish = hostBuildDictFinish,
};

fn transactionFrom(context: *anyopaque) *Transaction {
    return @ptrCast(@alignCast(context));
}

fn writeView(item: Value, output: *abi.ValueView) abi.HostStatus {
    output.* = switch (item) {
        .int => |number| .{ .kind = .int, .scalar_bits = @bitCast(number) },
        .float => |number| .{ .kind = .float, .scalar_bits = @bitCast(number) },
        .char => |codepoint| .{ .kind = .char, .scalar_bits = codepoint },
        .symbol => |id| .{
            .kind = .symbol,
            .bytes_ptr = intern.get(id).ptr,
            .bytes_len = intern.get(id).len,
        },
        .word => |id| .{
            .kind = .word,
            .bytes_ptr = intern.get(id).ptr,
            .bytes_len = intern.get(id).len,
        },
        .list => |header| .{ .kind = .list, .aggregate_len = header.length() },
        .dict => |header| .{ .kind = .dict, .aggregate_len = header.length() },
        .task => return .invalid,
    };
    return .ok;
}

fn charge(call: *Transaction, units: u32) abi.HostStatus {
    if (units <= call.budget) {
        call.budget -= units;
        return .ok;
    }
    call.budget = 0;
    call.yield_requested = true;
    return .yield_required;
}

fn hostInput(
    context: *anyopaque,
    index: u32,
    output: *abi.ValueView,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (index >= call.definition.effect.inputs) return .invalid;
    const item = call.activeEvaluator().nativeInputBorrowed(call.definition.effect.inputs, index);
    return writeView(item, output);
}

fn hostListAt(
    context: *anyopaque,
    input_index: u32,
    item_index: u64,
    output: *abi.ValueView,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or call.continuation == null or
        input_index >= call.definition.effect.inputs)
        return .invalid;
    const source = call.activeEvaluator().nativeInputBorrowed(
        call.definition.effect.inputs,
        input_index,
    );
    const header = switch (source) {
        .list => |value_header| value_header,
        else => return .invalid,
    };
    if (item_index >= header.length()) return .invalid;
    if (charge(call, 1) != .ok) return .yield_required;
    return writeView(list.atUnchecked(source, @intCast(item_index)), output);
}

fn hostDictAt(
    context: *anyopaque,
    input_index: u32,
    item_index: u64,
    key_output: *abi.ValueView,
    value_output: *abi.ValueView,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or call.continuation == null or
        input_index >= call.definition.effect.inputs)
        return .invalid;
    const header = switch (call.activeEvaluator().nativeInputBorrowed(
        call.definition.effect.inputs,
        input_index,
    )) {
        .dict => |value_header| value_header,
        else => return .invalid,
    };
    if (item_index >= header.length()) return .invalid;
    if (charge(call, 1) != .ok) return .yield_required;
    if (writeView(dict.keyAt(header, @intCast(item_index)), key_output) != .ok)
        return .invalid;
    return writeView(dict.valueAt(header, @intCast(item_index)), value_output);
}

fn hostForward(
    context: *anyopaque,
    index: u32,
    output: *abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (index >= call.definition.effect.inputs or call.terminal != .idle) return .invalid;
    const item = call.activeEvaluator().nativeInputBorrowed(call.definition.effect.inputs, index);
    heap.retainValue(item);
    const status = call.appendCandidate(item, null);
    if (status == .ok) output.* = call.candidateWire();
    return status;
}

fn hostScalar(
    context: *anyopaque,
    scalar: *const abi.Scalar,
    output: *abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or scalar.size != @sizeOf(abi.Scalar)) return .invalid;
    const units: u32 = switch (scalar.kind) {
        .symbol, .word => @max(1, std.math.cast(u32, scalar.bytes_len) orelse return .invalid),
        .int, .float, .char => 0,
        .list, .dict => return .invalid,
        _ => return .invalid,
    };
    if (units > abi.max_guest_scalar_bytes) return .invalid;
    if (units != 0 and charge(call, units) != .ok) return .yield_required;
    const item: Value = switch (scalar.kind) {
        .int => .{ .int = @bitCast(scalar.bits) },
        .float => .{ .float = @bitCast(scalar.bits) },
        .char => if (value.unicodeScalar(scalar.bits)) |codepoint|
            .{ .char = codepoint }
        else
            return .invalid,
        .symbol, .word => item: {
            const bytes = descriptor_api.guestUtf8(
                scalar.bytes_ptr,
                scalar.bytes_len,
                abi.max_guest_scalar_bytes,
            ) catch return .invalid;
            const id = intern.intern(bytes) catch return .out_of_memory;
            break :item if (scalar.kind == .symbol) .{ .symbol = id } else .{ .word = id };
        },
        .list, .dict => return .invalid,
        _ => return .invalid,
    };
    const status = call.appendCandidate(item, null);
    if (status == .ok) output.* = call.candidateWire();
    return status;
}

fn hostBuildListAppend(
    context: *anyopaque,
    slot: u32,
    item_count: u64,
    item_wire: abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle) return .invalid;
    const item = call.candidate(item_wire) orelse return .invalid;
    const aggregate = call.builder(slot, item_count, .list) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Invalid => .invalid,
    };
    if (charge(call, 1) != .ok) return .yield_required;
    const appended = switch (aggregate.value) {
        .list => |*builder| builder.append(item.value),
        .dict => unreachable,
    };
    if (!appended) return .invalid;
    call.consumeOrigin(item.origin);
    return .ok;
}

fn hostBuildListFinish(
    context: *anyopaque,
    slot: u32,
    item_count: u64,
    output: *abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle) return .invalid;
    const aggregate = call.builder(slot, item_count, .list) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Invalid => .invalid,
    };
    const result = switch (aggregate.value) {
        .list => |*builder| builder.advance(call) catch return .out_of_memory,
        .dict => unreachable,
    } orelse return if (call.yield_requested) .yield_required else .invalid;
    heap.retainValue(result);
    const status = call.appendCandidate(result, .{ .slot = slot, .serial = aggregate.serial });
    if (status == .ok) output.* = call.candidateWire();
    return status;
}

fn hostBuildDictAppend(
    context: *anyopaque,
    slot: u32,
    entry_count: u64,
    key_wire: abi.Candidate,
    item_wire: abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle) return .invalid;
    const key = call.candidate(key_wire) orelse return .invalid;
    const item = call.candidate(item_wire) orelse return .invalid;
    const aggregate = call.builder(slot, entry_count, .dict) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Invalid => .invalid,
    };
    if (charge(call, 1) != .ok) return .yield_required;
    const appended = switch (aggregate.value) {
        .dict => |*builder| builder.append(key.value, item.value),
        .list => unreachable,
    };
    if (!appended) return .invalid;
    call.consumeOrigin(key.origin);
    call.consumeOrigin(item.origin);
    return .ok;
}

fn hostBuildDictFinish(
    context: *anyopaque,
    slot: u32,
    entry_count: u64,
    output: *abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle) return .invalid;
    const aggregate = call.builder(slot, entry_count, .dict) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Invalid => .invalid,
    };
    const result = switch (aggregate.value) {
        .dict => |*builder| builder.advance(call) catch return .out_of_memory,
        .list => unreachable,
    } orelse return if (call.yield_requested) .yield_required else .invalid;
    heap.retainValue(result);
    const status = call.appendCandidate(result, .{ .slot = slot, .serial = aggregate.serial });
    if (status == .ok) output.* = call.candidateWire();
    return status;
}

fn hostComplete(
    context: *anyopaque,
    outputs: [*]const abi.Candidate,
    output_count: u32,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or output_count != call.definition.effect.outputs) return .invalid;
    call.outputs.ensureTotalCapacity(call.allocator, output_count) catch return .out_of_memory;
    for (outputs[0..output_count]) |wire| _ = call.candidate(wire) orelse return .invalid;
    for (outputs[0..output_count]) |wire| {
        const item = call.candidate(wire).?;
        heap.retainValue(item.value);
        call.outputs.appendAssumeCapacity(item.value);
        call.consumeOrigin(item.origin);
    }
    call.terminal = .complete;
    return .ok;
}

fn hostFail(
    context: *anyopaque,
    kind: abi.ErrorKindWire,
    message_ptr: [*]const u8,
    message_len: u32,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle) return .invalid;
    const message = descriptor_api.guestUtf8(
        message_ptr,
        message_len,
        abi.max_error_message_bytes,
    ) catch return .invalid;
    const kind_value = descriptor_api.mapErrorKind(kind) orelse return .invalid;
    var failure: Terminal = .{ .fail = .{
        .kind = kind_value,
        .message = [_]u8{0} ** abi.max_error_message_bytes,
        .message_len = message.len,
    } };
    @memcpy(failure.fail.message[0..message.len], message);
    call.terminal = failure;
    return .ok;
}

fn hostContinuationState(
    context: *anyopaque,
    output: *?*anyopaque,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or call.continuation == null) return .invalid;
    const state = call.continuation orelse return .invalid;
    output.* = state.ptr;
    return .ok;
}

fn hostConsume(
    context: *anyopaque,
    units: u32,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or call.continuation == null) return .invalid;
    return charge(call, units);
}

fn hostRequestYield(context: *anyopaque) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or call.continuation == null) return .invalid;
    call.yield_requested = true;
    return .ok;
}
