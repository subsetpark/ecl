//! Transactional host implementation of the native call capability table.

const std = @import("std");
const abi = @import("native-abi");
const descriptor_api = @import("native_descriptor.zig");
const dict = @import("dict.zig");
const env = @import("env.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const native_module = @import("native_module.zig");
const value = @import("value.zig");

const Value = value.Value;
const BuilderKind = enum { list, dict };

/// The transaction owns the entire chain. Cursor and backward links borrow
/// from that owner; retirement detaches one chunk per scheduler step.
const ScalarStage = struct {
    const Chunk = struct {
        retirement: heap.ReleaseDomain.Retirement = .{},
        next: ?*Chunk = null,
        previous: ?*Chunk = null,
        words: [256]u64,
        len: usize = 0,

        pub fn advanceRetirement(domain: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *Chunk) bool {
            if (self.next) |next| domain.retire(next, &next.retirement);
            allocator.destroy(self);
            return true;
        }
    };
    const Cursor = struct { chunk: *Chunk, index: usize };
    first: *Chunk,
    state: union(enum) { writing: *Chunk, forward: Cursor, reverse: Cursor },

    fn init(call: *Transaction) error{OutOfMemory}!ScalarStage {
        const first = try call.allocator.create(Chunk);
        // SAFETY: len exposes only words initialized by append.
        first.* = .{ .words = undefined };
        return .{ .first = first, .state = .{ .writing = first } };
    }
    fn append(self: *ScalarStage, call: *Transaction, words: []const u64) error{OutOfMemory}!bool {
        if (self.state != .writing) return false;
        for (words) |word| {
            if (self.state.writing.len == 256) {
                const next = try call.allocator.create(Chunk);
                // SAFETY: len exposes only words initialized by append.
                next.* = .{ .previous = self.state.writing, .words = undefined };
                self.state.writing.next = next;
                self.state.writing = next;
            }
            const chunk = self.state.writing;
            chunk.words[chunk.len] = word;
            chunk.len += 1;
        }
        return true;
    }
    fn read(self: *ScalarStage, words: []u64, forward: bool) bool {
        if (self.state == .writing) {
            const tail = self.state.writing;
            self.state = if (forward)
                .{ .forward = .{ .chunk = self.first, .index = 0 } }
            else
                .{ .reverse = .{ .chunk = tail, .index = tail.len } };
        }
        if (forward != (self.state == .forward)) return false;
        var cursor = if (forward) self.state.forward else self.state.reverse;
        for (0..words.len) |i| {
            if (forward) {
                if (cursor.index == cursor.chunk.len) {
                    cursor.chunk = cursor.chunk.next orelse return false;
                    cursor.index = 0;
                }
                words[i] = cursor.chunk.words[cursor.index];
                cursor.index += 1;
            } else {
                if (cursor.index == 0) {
                    cursor.chunk = cursor.chunk.previous orelse return false;
                    cursor.index = cursor.chunk.len;
                }
                cursor.index -= 1;
                words[words.len - i - 1] = cursor.chunk.words[cursor.index];
            }
        }
        self.state = if (forward) .{ .forward = cursor } else .{ .reverse = cursor };
        return true;
    }
    fn retire(self: *ScalarStage, releases: *heap.ReleaseDomain) void {
        releases.retire(self.first, &self.first.retirement);
    }
};

const BulkList = struct {
    kind: abi.BulkKind,
    expected: usize,
    reverse: bool,
    appended: usize = 0,
    text_span: ?TextSpan = null,
    state: union(enum) {
        preparing: heap.AnyListBuilder,
        writing: heap.AnyListBuilder,
        complete: Value,
    },

    fn init(allocator: std.mem.Allocator, kind: abi.BulkKind, count: usize, reverse: bool) error{OutOfMemory}!BulkList {
        const representation: value.HeapKind = switch (kind) {
            .integers => .leaf_i64,
            .floats => .leaf_f64,
            .char1 => .leaf_char1,
            .char2 => .leaf_char2,
            .char4 => .leaf_char4,
            .values => .generic_spine,
            else => unreachable,
        };
        const builder = try heap.AnyListBuilder.init(allocator, representation, if (kind == .values) 0 else count, count);
        return .{ .kind = kind, .expected = count, .reverse = reverse, .state = if (kind == .values and reverse) .{ .preparing = builder } else .{ .writing = builder } };
    }
    fn prepare(self: *BulkList, call: *Transaction) bool {
        if (self.state != .preparing) return true;
        const builder = &self.state.preparing.generic;
        while (builder.len() != self.expected) {
            if (charge(call, 1) != .ok) return false;
            const i = builder.len();
            builder.items()[i] = .{ .int = 0 };
            builder.setLen(i + 1);
        }
        const prepared = self.state.preparing;
        self.state = .{ .writing = prepared };
        return true;
    }
    fn write(self: *BulkList, item: Value) bool {
        if (self.state != .writing or self.appended == self.expected) return false;
        const index = if (self.reverse) self.expected - self.appended - 1 else self.appended;
        self.state.writing.writeValue(index, item);
        self.appended += 1;
        if (self.kind == .values) self.state.writing.generic.setLen(if (self.reverse) self.expected else self.appended);
        return true;
    }
    fn retire(self: *BulkList, releases: *heap.ReleaseDomain) void {
        if (self.text_span) |*span| span.builder.retirePartial(releases);
        switch (self.state) {
            .preparing, .writing => |*builder| builder.retirePartial(releases),
            .complete => |result| releases.releaseValue(result),
        }
    }
};

/// Partial decoding belongs to the output transaction, including on retry and
/// cancellation. Input coordinates identify a borrow from its pinned operands.
const TextSpan = struct {
    request: [5]u64,
    builder: heap.AnyListBuilder,
    position: usize = 0,
    written: usize = 0,
    byte_mode: ?bool = null,
    remaining: u8 = 0,
    codepoint: u32 = 0,
    minimum: u32 = 0,

    fn advance(self: *TextSpan, call: *Transaction) abi.HostStatus {
        // SAFETY: hostReadUnits initializes exactly the returned prefix.
        var units: [abi.max_bulk_units]u32 = undefined;
        var n: u32 = 0;
        var byte_wire: u32 = 0;
        const capacity: u32 = @intCast(@min(units.len, self.request[2] - self.position));
        const status = hostReadUnits(call, @intCast(self.request[0]), self.request[1] + self.position, &units, capacity, &n, &byte_wire);
        if (status != .ok) return status;
        const bytes = byte_wire != 0;
        if (n != 0) {
            if (self.byte_mode) |mode| {
                if (mode != bytes) return .invalid;
            } else self.byte_mode = bytes;
        }
        for (units[0..n]) |unit| {
            self.position += 1;
            var cp = unit;
            if (bytes) {
                if (self.remaining != 0) {
                    if (unit < 0x80 or unit > 0xbf) return .invalid;
                    self.codepoint = (self.codepoint << 6) | (unit & 63);
                    self.remaining -= 1;
                    if (self.remaining != 0) continue;
                    cp = self.codepoint;
                    if (cp < self.minimum) return .invalid;
                } else if (unit >= 128) {
                    if (unit >= 0xc2 and unit <= 0xdf) {
                        self.remaining = 1;
                        self.codepoint = unit & 31;
                        self.minimum = 128;
                    } else if (unit >= 0xe0 and unit <= 0xef) {
                        self.remaining = 2;
                        self.codepoint = unit & 15;
                        self.minimum = 2048;
                    } else if (unit >= 0xf0 and unit <= 0xf4) {
                        self.remaining = 3;
                        self.codepoint = unit & 7;
                        self.minimum = 65536;
                    } else return .invalid;
                    continue;
                }
            }
            if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff) or self.written == self.request[3]) return .invalid;
            const maximum: u32 = switch (self.builder) {
                .char1 => 255,
                .char2 => 65535,
                .char4 => 0x10ffff,
                else => unreachable,
            };
            if (cp > maximum) return .invalid;
            self.builder.writeCodepoint(self.written, cp);
            self.written += 1;
        }
        if (self.position != self.request[2]) {
            call.yield_requested = true;
            return .yield_required;
        }
        if (self.remaining != 0 or self.written != self.request[3]) return .invalid;
        return .ok;
    }
};

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
    state: State,

    const State = union(enum) {
        building: struct {
            appended: usize,
            source: heap.ListBuilder(.generic_spine),
        },
        materializing: struct {
            source: heap.ListBuilder(.generic_spine),
            materializer: list.ValueMaterializer,
        },
        complete: Value,

        fn retire(self: *State, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .building => |*building| building.source.retirePartial(releases),
                .materializing => |*materializing| {
                    materializing.materializer.retire(releases);
                    materializing.source.retirePartial(releases);
                },
                .complete => |result| releases.releaseValue(result),
            }
        }
    };

    fn init(allocator: std.mem.Allocator, expected: usize) error{OutOfMemory}!ListBuild {
        var source = try heap.ListBuilder(.generic_spine).init(allocator, expected, expected);
        source.setLen(0);
        return .{ .expected = expected, .state = .{ .building = .{
            .appended = 0,
            .source = source,
        } } };
    }

    fn append(self: *ListBuild, item: Value) bool {
        const building = switch (self.state) {
            .building => |*building| building,
            .materializing, .complete => return false,
        };
        if (building.appended == self.expected) return false;
        heap.retainValue(item);
        building.source.items()[building.appended] = item;
        building.appended += 1;
        building.source.setLen(building.appended);
        return true;
    }

    fn advance(self: *ListBuild, call: *Transaction) error{OutOfMemory}!?Value {
        switch (self.state) {
            .complete => |result| return result,
            .building => |*building| {
                if (building.appended != self.expected) return null;
                const appended = building.appended;
                const source = building.source;
                const materializer = list.ValueMaterializer.init(
                    call.allocator,
                    source.items()[0..appended],
                );
                self.state = .{ .materializing = .{
                    .source = source,
                    .materializer = materializer,
                } };
            },
            .materializing => {},
        }
        if (call.budget == 0) {
            call.yield_requested = true;
            return null;
        }
        while (call.budget != 0) {
            call.budget -= 1;
            const materializing = &self.state.materializing;
            switch (try materializing.materializer.advance(1)) {
                .pending => {},
                .complete => |result| {
                    materializing.materializer.deinit();
                    materializing.source.retirePartial(call.releases);
                    self.state = .{ .complete = result };
                    return result;
                },
            }
        }
        call.yield_requested = true;
        return null;
    }

    fn retire(self: *ListBuild, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases);
    }
};

const DictBuild = struct {
    expected: usize,
    state: State,

    const State = union(enum) {
        building: struct {
            appended: usize,
            keys: heap.ListBuilder(.generic_spine),
            values: heap.ListBuilder(.generic_spine),
        },
        materializing: struct {
            keys: heap.ListBuilder(.generic_spine),
            values: heap.ListBuilder(.generic_spine),
            materializer: dict.Materializer,
        },
        complete: Value,
        rejected,

        fn retire(self: *State, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .building => |*building| {
                    building.keys.retirePartial(releases);
                    building.values.retirePartial(releases);
                },
                .materializing => |*materializing| {
                    materializing.materializer.retire(releases);
                    materializing.keys.retirePartial(releases);
                    materializing.values.retirePartial(releases);
                },
                .complete => |result| releases.releaseValue(result),
                .rejected => {},
            }
        }
    };

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
        return .{ .expected = expected, .state = .{ .building = .{
            .appended = 0,
            .keys = keys,
            .values = values,
        } } };
    }

    fn append(self: *DictBuild, key: Value, item: Value) bool {
        const building = switch (self.state) {
            .building => |*building| building,
            .materializing, .complete, .rejected => return false,
        };
        if (building.appended == self.expected) return false;
        heap.retainValue(key);
        heap.retainValue(item);
        building.keys.items()[building.appended] = key;
        building.values.items()[building.appended] = item;
        building.appended += 1;
        building.keys.setLen(building.appended);
        building.values.setLen(building.appended);
        return true;
    }

    fn advance(self: *DictBuild, call: *Transaction) error{OutOfMemory}!?Value {
        switch (self.state) {
            .complete => |result| return result,
            .rejected => return null,
            .building => |*building| {
                if (building.appended != self.expected) return null;
                const appended = building.appended;
                const keys = building.keys;
                const values = building.values;
                const materializer = try dict.Materializer.initBorrowedSlices(
                    call.allocator,
                    keys.items()[0..appended],
                    values.items()[0..appended],
                    true,
                );
                self.state = .{ .materializing = .{
                    .keys = keys,
                    .values = values,
                    .materializer = materializer,
                } };
            },
            .materializing => {},
        }
        if (call.budget == 0) {
            call.yield_requested = true;
            return null;
        }
        while (call.budget != 0) {
            call.budget -= 1;
            const materializing = &self.state.materializing;
            switch (try materializing.materializer.advance(1)) {
                .pending => {},
                .duplicate_key => {
                    materializing.materializer.retire(call.releases);
                    materializing.keys.retirePartial(call.releases);
                    materializing.values.retirePartial(call.releases);
                    self.state = .rejected;
                    return null;
                },
                .complete => |result| {
                    materializing.materializer.deinit();
                    materializing.keys.retirePartial(call.releases);
                    materializing.values.retirePartial(call.releases);
                    self.state = .{ .complete = result };
                    return result;
                },
            }
        }
        call.yield_requested = true;
        return null;
    }

    fn retire(self: *DictBuild, releases: *heap.ReleaseDomain) void {
        self.state.retire(releases);
    }
};

const AggregateBuilder = struct {
    serial: u32,
    value: union(enum) {
        list: ListBuild,
        dict: DictBuild,
        stage: ScalarStage,
        bulk: BulkList,
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
        };
        errdefer {
            call.instance.releasePin();
            evaluator.allocator().destroy(call);
        }
        if (definition.body.call.continuation_size != 0) {
            call.continuation = try evaluator.allocator().alignedAlloc(
                u8,
                .@"64",
                definition.body.call.continuation_size,
            );
            definition.body.call.init_continuation.?(call.continuation.?.ptr);
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
            self.definition.body.call.deinit_continuation.?(state.ptr);
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

    fn rejectCapability(self: *Transaction, message: []const u8) abi.HostStatus {
        if (self.terminal != .idle) return .invalid;
        var failure: Terminal = .{ .fail = .{
            .kind = .type,
            .message = [_]u8{0} ** abi.max_error_message_bytes,
            .message_len = message.len,
        } };
        @memcpy(failure.fail.message[0..message.len], message);
        self.terminal = failure;
        return .invalid;
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
                .stage, .bulk => false,
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
        self.instance.invoke()(&self.host_table, self, self.definition.body.call.callback_index, &result);
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
) machine.MachineError!void {
    const definition = callable.instance.definition(callable.definition);
    try evaluator.require(definition.effect.inputs);
    for (0..definition.effect.inputs) |index| switch (evaluator.nativeInputBorrowed(
        definition.effect.inputs,
        @intCast(index),
    )) {
        .task => return evaluator.fail(.type, "native words cannot observe task capabilities"),
        .module => return evaluator.fail(.type, "native words cannot observe module capabilities"),
        else => {},
    };
    const call = Transaction.create(evaluator, callable, definition) catch |err| switch (err) {
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
    .read_path = hostReadPath,
    .build_list_append = hostBuildListAppend,
    .build_list_finish = hostBuildListFinish,
    .read_units = hostReadUnits,
    .bulk_build = hostBulkBuild,
    .build_dict_append = hostBuildDictAppend,
    .build_dict_finish = hostBuildDictFinish,
    .forward_path = hostForwardPath,
};

fn transactionFrom(context: *anyopaque) *Transaction {
    return @ptrCast(@alignCast(context));
}

fn writeView(call: *Transaction, item: Value, output: *abi.ValueView) abi.HostStatus {
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
            .bytes_ptr = intern.get(id.name).ptr,
            .bytes_len = intern.get(id.name).len,
        },
        .list => |header| .{ .kind = .list, .aggregate_len = header.length() },
        .dict => |header| .{ .kind = .dict, .aggregate_len = header.length() },
        .task => return call.rejectCapability("native words cannot observe task capabilities"),
        .module => return call.rejectCapability("native words cannot observe module capabilities"),
        .port => .{ .kind = .port },
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
    return writeView(call, item, output);
}

fn hostReadUnits(context: *anyopaque, input_index: u32, start: u64, output: [*]u32, capacity: u32, count: *u32, bytes: *u32) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or call.continuation == null or capacity > abi.max_bulk_units or input_index >= call.definition.effect.inputs) return .invalid;
    const source = call.activeEvaluator().nativeInputBorrowed(call.definition.effect.inputs, input_index);
    if (source != .list or start > source.list.length()) return .invalid;
    const n: u32 = @intCast(@min(capacity, source.list.length() - start));
    if (charge(call, @max(n, 1)) != .ok) return .yield_required;
    const offset: usize = @intCast(start);
    switch (source.list.kind()) {
        .leaf_u8, .leaf_char1, .leaf_char2, .leaf_char4 => |kind| {
            switch (kind) {
                .leaf_u8 => for (heap.u8s(source.list)[offset..][0..n], 0..) |unit, i| {
                    output[i] = unit;
                },
                .leaf_char1 => for (heap.chars8(source.list)[offset..][0..n], 0..) |unit, i| {
                    output[i] = unit;
                },
                .leaf_char2 => for (heap.chars16(source.list)[offset..][0..n], 0..) |unit, i| {
                    output[i] = unit;
                },
                .leaf_char4 => @memcpy(output[0..n], heap.chars32(source.list)[offset..][0..n]),
                else => unreachable,
            }
            count.* = n;
            bytes.* = @intFromBool(kind == .leaf_u8);
            return .ok;
        },
        .leaf_i64 => {
            for (heap.i64s(source.list)[offset..][0..n], 0..) |unit, i| {
                if (unit < 0 or unit > 255) return .invalid;
                output[i] = @intCast(unit);
            }
            count.* = n;
            bytes.* = 1;
            return .ok;
        },
        else => {},
    }
    var byte_mode: ?bool = null;
    for (0..n) |i| {
        const item = list.atUnchecked(source, @as(usize, @intCast(start)) + i);
        const is_byte = item == .int;
        if (byte_mode) |mode| {
            if (mode != is_byte) return .invalid;
        } else byte_mode = is_byte;
        output[i] = switch (item) {
            .int => |v| if (v >= 0 and v <= 255) @intCast(v) else return .invalid,
            .char => |v| v,
            else => return .invalid,
        };
    }
    count.* = n;
    bytes.* = @intFromBool(byte_mode orelse false);
    return .ok;
}

fn hostBulkBuild(context: *anyopaque, slot: u32, action: abi.BulkAction, kind: abi.BulkKind, count_wire: u64, reverse_wire: u32, words: [*]u64, n: u32, output: *abi.Candidate) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    if (call.terminal != .idle or slot >= abi.max_builder_slots or n > abi.max_bulk_units or reverse_wire > 1) return .invalid;
    const count = std.math.cast(usize, count_wire) orelse return .invalid;
    if (count >= std.math.maxInt(u32)) return .invalid;
    switch (kind) {
        .integers, .floats, .char1, .char2, .char4, .values => {},
        else => return .invalid,
    }
    switch (action) {
        .stage, .read_staged, .read_staged_forward, .append_text_span, .append, .append_candidate, .finish => {},
        else => return .invalid,
    }
    if (charge(call, @max(n, 1)) != .ok) return .yield_required;
    const staged = action == .stage or action == .read_staged or action == .read_staged_forward;
    if (call.builders[slot] == null) {
        const aggregate = call.allocator.create(AggregateBuilder) catch return .out_of_memory;
        aggregate.* = .{ .serial = call.next_builder_serial, .value = if (staged)
            .{ .stage = ScalarStage.init(call) catch {
                call.allocator.destroy(aggregate);
                return .out_of_memory;
            } }
        else
            .{ .bulk = BulkList.init(call.allocator, kind, count, reverse_wire != 0) catch {
                call.allocator.destroy(aggregate);
                return .out_of_memory;
            } } };
        call.next_builder_serial +%= 1;
        if (call.next_builder_serial == 0) call.next_builder_serial = 1;
        call.builders[slot] = aggregate;
    }
    const aggregate = call.builders[slot].?;
    if (staged) {
        if (aggregate.value != .stage) return .invalid;
        const success = if (action == .stage)
            aggregate.value.stage.append(call, words[0..n]) catch return .out_of_memory
        else
            aggregate.value.stage.read(words[0..n], action == .read_staged_forward);
        return if (success) .ok else .invalid;
    }
    if (aggregate.value != .bulk) return .invalid;
    const builder = &aggregate.value.bulk;
    if (builder.kind != kind or builder.expected != count or builder.reverse != (reverse_wire != 0)) return .invalid;
    if (!builder.prepare(call)) return .yield_required;
    if (builder.text_span != null and action != .append_text_span) return .invalid;
    switch (action) {
        .append => {
            if (kind == .values or builder.state != .writing or n > count - builder.appended) return .invalid;
            for (words[0..n]) |word| switch (kind) {
                .char1 => if (word > 255) {
                    return .invalid;
                },
                .char2 => if (word > 65535 or (word >= 0xd800 and word <= 0xdfff)) {
                    return .invalid;
                },
                .char4 => if (word > 0x10ffff or (word >= 0xd800 and word <= 0xdfff)) {
                    return .invalid;
                },
                else => {},
            };
            switch (builder.state.writing) {
                inline .i64, .f64, .char1, .char2, .char4 => |*typed| {
                    for (words[0..n], 0..) |word, i| {
                        const index = if (builder.reverse) count - builder.appended - i - 1 else builder.appended + i;
                        const Element = @TypeOf(typed.items()[index]);
                        typed.items()[index] = if (Element == i64 or Element == f64) @bitCast(word) else @intCast(word);
                    }
                },
                else => unreachable,
            }
            builder.appended += n;
        },
        .append_text_span => {
            if (kind != .values or reverse_wire != 0 or n != 5 or builder.state != .writing or builder.appended == count) return .invalid;
            const request = words[0..5];
            if (request[0] >= call.definition.effect.inputs) return .invalid;
            const source = call.activeEvaluator().nativeInputBorrowed(call.definition.effect.inputs, @intCast(request[0]));
            if (source != .list or request[1] > source.list.length() or request[2] > source.list.length() - request[1] or request[3] >= std.math.maxInt(u32)) return .invalid;
            const representation: value.HeapKind = switch (request[4]) {
                @intFromEnum(abi.BulkKind.char1) => .leaf_char1,
                @intFromEnum(abi.BulkKind.char2) => .leaf_char2,
                @intFromEnum(abi.BulkKind.char4) => .leaf_char4,
                else => return .invalid,
            };
            if (builder.text_span == null) {
                builder.text_span = .{
                    .request = request.*,
                    .builder = heap.AnyListBuilder.init(call.allocator, representation, @intCast(request[3]), @intCast(request[3])) catch return .out_of_memory,
                };
            }
            const span = &builder.text_span.?;
            if (!std.mem.eql(u64, &span.request, request)) return .invalid;
            const status = span.advance(call);
            if (status != .ok) return status;
            // Decoding charged every unit before mutation; this final transfer
            // is O(1) and cannot yield after consuming the completed string.
            const text: Value = .{ .list = span.builder.finish() };
            builder.text_span = null;
            if (!builder.write(text)) unreachable;
            call.releases.releaseValue(text);
        },
        .append_candidate => {
            if (kind != .values) return .invalid;
            const item = call.candidate(output.*) orelse return .invalid;
            // A builder cannot consume itself through a candidate alias.
            if (item.origin) |origin| if (origin.slot == slot) return .invalid;
            if (!builder.write(item.value)) return .invalid;
            call.consumeOrigin(item.origin);
        },
        .finish => {
            if (builder.appended != count) return .invalid;
            if (builder.state == .writing) {
                const finished: Value = .{ .list = builder.state.writing.finish() };
                builder.state = .{ .complete = finished };
            }
            const result = builder.state.complete;
            heap.retainValue(result);
            const status = call.appendCandidate(result, .{ .slot = slot, .serial = aggregate.serial });
            if (status == .ok) output.* = call.candidateWire();
            return status;
        },
        else => unreachable,
    }
    return .ok;
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
    return writeView(call, list.atUnchecked(source, @intCast(item_index)), output);
}

/// Walks a declared input down one bounded path. Charging one unit per step
/// keeps the whole read constant-cost against the scheduler budget, and every
/// rejection is a wire status rather than a host-side assumption about the
/// author's arithmetic.
fn hostReadPath(
    context: *anyopaque,
    input_index: u32,
    path_ptr: [*]const u64,
    path_len: u32,
    output: *abi.ValueView,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    return switch (readPath(call, input_index, path_ptr, path_len)) {
        .value => |item| writeView(call, item, output),
        .status => |status| status,
    };
}

fn hostForwardPath(
    context: *anyopaque,
    input_index: u32,
    path_ptr: [*]const u64,
    path_len: u32,
    output: *abi.Candidate,
) callconv(.c) abi.HostStatus {
    const call = transactionFrom(context);
    const item = switch (readPath(call, input_index, path_ptr, path_len)) {
        .value => |item| item,
        .status => |status| return status,
    };
    var view: abi.ValueView = .{ .kind = .int };
    const observed = writeView(call, item, &view);
    if (observed != .ok) return observed;
    heap.retainValue(item);
    const status = call.appendCandidate(item, null);
    if (status == .ok) output.* = call.candidateWire();
    return status;
}

const PathRead = union(enum) { value: Value, status: abi.HostStatus };

fn readPath(
    call: *Transaction,
    input_index: u32,
    path_ptr: [*]const u64,
    path_len: u32,
) PathRead {
    if (call.terminal != .idle or call.continuation == null or
        input_index >= call.definition.effect.inputs)
        return .{ .status = .invalid };
    if (path_len > abi.max_read_path_depth) return .{ .status = .invalid };
    if (charge(call, @max(path_len, 1)) != .ok) return .{ .status = .yield_required };
    var current = call.activeEvaluator().nativeInputBorrowed(
        call.definition.effect.inputs,
        input_index,
    );
    for (path_ptr[0..path_len]) |step| switch (current) {
        .list => |header| {
            if (step >= header.length()) return .{ .status = .invalid };
            current = list.atUnchecked(current, @intCast(step));
        },
        .dict => |header| {
            const entry = step / 2;
            if (entry >= dict.keysOf(header).list.length()) return .{ .status = .invalid };
            current = if (step % 2 == 0)
                dict.keyAt(header, @intCast(entry))
            else
                dict.valueAt(header, @intCast(entry));
        },
        .int, .float, .char, .symbol, .word, .task, .module, .port => return .{ .status = .invalid },
    };
    return .{ .value = current };
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
    if (writeView(call, dict.keyAt(header, @intCast(item_index)), key_output) != .ok)
        return .invalid;
    return writeView(call, dict.valueAt(header, @intCast(item_index)), value_output);
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
        .list, .dict, .port => return .invalid,
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
            break :item if (scalar.kind == .symbol) .{ .symbol = id } else .{ .word = .{ .name = id } };
        },
        .list, .dict, .port => return .invalid,
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
        else => unreachable,
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
        else => unreachable,
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
        else => unreachable,
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
        else => unreachable,
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
