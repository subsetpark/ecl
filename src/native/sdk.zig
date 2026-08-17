//! Root module of the Zig-only `ecl-native` author SDK.

const std = @import("std");
pub const abi = @import("ecl-native-abi");
const capability = @import("capability.zig");

pub const Outcome = capability.Outcome;
pub const ErrorKind = capability.ErrorKind;
pub const Kind = capability.Kind;
pub const Scalar = capability.Scalar;
pub const Candidate = capability.Candidate;
pub const ValueView = capability.ValueView;
pub const CursorStep = capability.CursorStep;
pub const DictCursorStep = capability.DictCursorStep;
pub const ListCursor = capability.ListCursor;
pub const DictCursor = capability.DictCursor;
pub const BuildValues = capability.BuildValues;
pub const BuildResult = capability.BuildResult;
pub const BuildAppendResult = capability.BuildAppendResult;
pub const Reschedule = capability.Reschedule;
pub const CallbackResult = error{ OutOfMemory, InvalidValue }!Outcome;

pub fn Call(comptime effect_source: []const u8) type {
    const EffectSpec = parseEffect(effect_source);
    return opaque {
        const Self = @This();
        pub const ecl_call_marker = void;
        pub const effect = EffectSpec;

        const AdapterState = struct {
            invocation: capability.Invocation,
            views: [EffectSpec.inputs.len]capability.ViewState,
            list_cursors: [EffectSpec.inputs.len]capability.ListCursorState,
            dict_cursors: [EffectSpec.inputs.len]capability.DictCursorState,
        };

        fn initAdapter(
            adapter_state: *AdapterState,
            host: *const abi.HostTable,
            context: *anyopaque,
        ) error{ OutOfMemory, InvalidValue }!void {
            adapter_state.invocation = .{ .host = host, .context = context };
            for (&adapter_state.views, 0..) |*view, index| {
                view.* = .{
                    .wire = .{ .kind = .int },
                    .invocation = &adapter_state.invocation,
                    .input_index = @intCast(index),
                };
                try capability.requireOk(host.input(context, @intCast(index), &view.wire));
            }
        }

        fn adapterPointer(adapter_state: *AdapterState) *Self {
            return @ptrCast(@alignCast(adapter_state));
        }

        fn state(self: *Self) *AdapterState {
            return @ptrCast(@alignCast(self));
        }

        pub fn input(self: *Self, comptime index: usize) *const ValueView {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: input index exceeds the declared effect");
            return @ptrCast(&self.state().views[index]);
        }

        pub fn listCursor(self: *Self, comptime index: usize, start: u64) ?*ListCursor {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: list cursor input exceeds the declared effect");
            const view = &self.state().views[index];
            if (view.wire.kind != .list or start > view.wire.aggregate_len) return null;
            return ListCursor.initAdapter(
                &self.state().list_cursors[index],
                &self.state().invocation,
                index,
                view.wire.aggregate_len,
                start,
            );
        }

        pub fn dictCursor(self: *Self, comptime index: usize, start: u64) ?*DictCursor {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: dictionary cursor input exceeds the declared effect");
            const view = &self.state().views[index];
            if (view.wire.kind != .dict or start > view.wire.aggregate_len) return null;
            return DictCursor.initAdapter(
                &self.state().dict_cursors[index],
                &self.state().invocation,
                index,
                view.wire.aggregate_len,
                start,
            );
        }

        pub fn forward(self: *Self, comptime index: usize) error{ OutOfMemory, InvalidValue }!Candidate {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: forwarded input exceeds the declared effect");
            var output: abi.Candidate = 0;
            try capability.requireOk(self.state().invocation.host.forward(
                self.state().invocation.context,
                index,
                &output,
            ));
            return @enumFromInt(output);
        }

        pub fn complete(self: *Self, outputs: anytype) error{ OutOfMemory, InvalidValue }!Outcome {
            const OutputTuple = @TypeOf(outputs);
            const tuple = switch (@typeInfo(OutputTuple)) {
                .@"struct" => |info| info,
                else => @compileError("ecl-native: complete expects a tuple of outputs"),
            };
            if (!tuple.is_tuple)
                @compileError("ecl-native: complete expects a tuple of outputs");
            if (tuple.fields.len != EffectSpec.outputs.len)
                @compileError("ecl-native: complete output arity does not match the declared effect");
            var candidates: [EffectSpec.outputs.len]abi.Candidate = undefined;
            inline for (tuple.fields, 0..) |field, index| {
                const candidate = try self.state().invocation.makeCandidate(@field(outputs, field.name));
                candidates[index] = @intFromEnum(candidate);
            }
            try capability.requireOk(self.state().invocation.host.complete(
                self.state().invocation.context,
                &candidates,
                candidates.len,
            ));
            return .complete;
        }

        pub fn fail(
            self: *Self,
            kind: ErrorKind,
            message: []const u8,
        ) error{ OutOfMemory, InvalidValue }!Outcome {
            const bounded = message[0..@min(message.len, abi.max_error_message_bytes)];
            try capability.requireOk(self.state().invocation.host.fail(
                self.state().invocation.context,
                kind,
                bounded.ptr,
                @intCast(bounded.len),
            ));
            return .fail;
        }
    };
}

pub fn word(
    comptime word_name: []const u8,
    comptime word_documentation: []const u8,
    comptime callback_fn: anytype,
) type {
    if (word_documentation.len == 0) @compileError("ecl-native: word documentation must not be empty");
    if (!identifier(word_name)) @compileError("ecl-native: word name must be a nonempty identifier");
    const Callback = @TypeOf(callback_fn);
    const function = switch (@typeInfo(Callback)) {
        .@"fn" => |info| info,
        else => @compileError("ecl-native: callback must be a function"),
    };
    if (function.is_generic or function.is_var_args)
        @compileError("ecl-native: callback must be non-generic and non-variadic");
    if (function.params.len == 0 or function.params[0].type == null)
        @compileError("ecl-native: callback first parameter must be *ecl.Call(\"inputs -- outputs\")");
    const First = function.params[0].type.?;
    const first_pointer = switch (@typeInfo(First)) {
        .pointer => |pointer| pointer,
        else => @compileError("ecl-native: callback first parameter must be *ecl.Call(\"inputs -- outputs\")"),
    };
    if (first_pointer.size != .one or !@hasDecl(first_pointer.child, "ecl_call_marker"))
        @compileError("ecl-native: callback first parameter must be *ecl.Call(\"inputs -- outputs\")");
    if (function.return_type == null or function.return_type.? != CallbackResult)
        @compileError("ecl-native: callback return type must be ecl.CallbackResult");
    var build_values = false;
    var reschedule = false;
    var RescheduleType: type = void;
    for (function.params[1..], 1..) |parameter, parameter_index| {
        if (parameter.type == null) @compileError("ecl-native: callback capabilities must have concrete types");
        if (parameter.type.? == *BuildValues) {
            if (build_values) @compileError("ecl-native: callback names a capability more than once");
            if (reschedule)
                @compileError("ecl-native: BuildValues must precede Reschedule");
            build_values = true;
        } else if (isReschedulePointer(parameter.type.?)) {
            if (reschedule) @compileError("ecl-native: callback names a capability more than once");
            if (build_values and parameter_index != 2)
                @compileError("ecl-native: BuildValues must precede Reschedule");
            reschedule = true;
            RescheduleType = @typeInfo(parameter.type.?).pointer.child;
        } else {
            @compileError("ecl-native: callback parameter is not a supported capability");
        }
    }
    const CallbackValue = callback_fn;
    const WordName = word_name;
    const WordDocumentation = word_documentation;
    const NativeCallType = first_pointer.child;
    const UsesBuildValues = build_values;
    const UsesReschedule = reschedule;
    const NativeRescheduleType = RescheduleType;
    return struct {
        pub const callback = CallbackValue;
        pub const name = WordName;
        pub const documentation = WordDocumentation;
        pub const NativeCall = NativeCallType;
        pub const uses_build_values = UsesBuildValues;
        pub const uses_reschedule = UsesReschedule;

        pub const input_slots = makeSlots(NativeCall.effect.inputs);
        pub const output_slots = makeSlots(NativeCall.effect.outputs);

        pub fn definition(index: u32) abi.Definition {
            return .{
                .callback_index = index,
                .name_ptr = name.ptr,
                .name_len = name.len,
                .doc_ptr = documentation.ptr,
                .doc_len = documentation.len,
                .input_count = input_slots.len,
                .inputs_ptr = &input_slots,
                .output_count = output_slots.len,
                .outputs_ptr = &output_slots,
                .continuation_size = if (uses_reschedule)
                    NativeRescheduleType.continuation_size
                else
                    0,
                .continuation_alignment = if (uses_reschedule)
                    NativeRescheduleType.continuation_alignment
                else
                    0,
                .init_continuation = if (uses_reschedule)
                    NativeRescheduleType.initState
                else
                    null,
                .deinit_continuation = if (uses_reschedule)
                    NativeRescheduleType.deinitState
                else
                    null,
            };
        }

        pub fn invoke(
            host: *const abi.HostTable,
            context: *anyopaque,
            output: *abi.InvokeResult,
        ) void {
            var call_state: NativeCall.AdapterState = undefined;
            NativeCall.initAdapter(&call_state, host, context) catch |err| {
                writeAdapterFailure(host, context, output, err);
                return;
            };
            const call = NativeCall.adapterPointer(&call_state);
            var build_state: capability.BuildState = undefined;
            const build: *BuildValues = if (uses_build_values) build: {
                build_state = .{ .invocation = &call_state.invocation };
                break :build @ptrCast(&build_state);
            } else undefined;
            var reschedule_state: if (uses_reschedule)
                NativeRescheduleType.AdapterState
            else
                void = undefined;
            const schedule: if (uses_reschedule) *NativeRescheduleType else void =
                if (uses_reschedule) schedule: {
                    NativeRescheduleType.initAdapter(
                        &reschedule_state,
                        &call_state.invocation,
                    ) catch {
                        output.* = .{ .tag = .fail, .reserved = 1 };
                        return;
                    };
                    break :schedule NativeRescheduleType.adapterPointer(&reschedule_state);
                } else {};
            const result: CallbackResult = if (uses_build_values and uses_reschedule)
                callback(call, build, schedule)
            else if (uses_build_values)
                callback(call, build)
            else if (uses_reschedule)
                callback(call, schedule)
            else
                callback(call);
            const outcome = result catch |err| switch (err) {
                error.OutOfMemory => {
                    output.* = .{ .tag = .fail, .reserved = 1 };
                    return;
                },
                error.InvalidValue => {
                    writeAdapterFailure(host, context, output, error.InvalidValue);
                    return;
                },
            };
            output.* = .{ .tag = @enumFromInt(@intFromEnum(outcome)) };
        }
    };
}

fn writeAdapterFailure(
    host: *const abi.HostTable,
    context: *anyopaque,
    output: *abi.InvokeResult,
    err: error{ OutOfMemory, InvalidValue },
) void {
    switch (err) {
        error.OutOfMemory => output.* = .{ .tag = .fail, .reserved = 1 },
        error.InvalidValue => {
            const message = "native SDK capability argument was rejected";
            _ = host.fail(context, .domain, message.ptr, message.len);
            output.* = .{ .tag = .fail, .reserved = 0 };
        },
    }
}

pub fn module(comptime spec: anytype) type {
    if (!identifier(spec.name)) @compileError("ecl-native: module name must be a nonempty identifier");
    if (spec.doc.len == 0) @compileError("ecl-native: module documentation must not be empty");
    const words = spec.words;
    const word_count = words.len;
    @setEvalBranchQuota(1000 + word_count * word_count * 16);
    inline for (words, 0..) |Word, index| {
        inline for (0..index) |prior_index| {
            const Prior = words[prior_index];
            if (std.mem.eql(u8, Word.name, Prior.name))
                @compileError("ecl-native: module contains a duplicate word name");
        }
    }
    const ModuleName = spec.name;
    const ModuleDocumentation = spec.doc;
    const Words = words;
    const uses_build_values = uses: {
        var result = false;
        for (words) |Word| result = result or Word.uses_build_values;
        break :uses result;
    };
    const uses_reschedule = uses: {
        var result = false;
        for (words) |Word| result = result or Word.uses_reschedule;
        break :uses result;
    };
    const requirement_count: usize = 1 +
        @as(usize, @intFromBool(uses_build_values)) +
        @as(usize, @intFromBool(uses_reschedule));
    return struct {
        const Self = @This();
        pub const definitions = definitions: {
            var result: [word_count]abi.Definition = undefined;
            for (Words, 0..) |Word, index| result[index] = Word.definition(index);
            break :definitions result;
        };
        pub const requirements = requirements: {
            var result: [requirement_count]abi.CapabilityRequirement = undefined;
            result[0] = .{ .id = @intFromEnum(abi.CapabilityId.call), .version = 1 };
            if (uses_build_values)
                result[1] = .{ .id = @intFromEnum(abi.CapabilityId.build_values), .version = 2 };
            if (uses_reschedule)
                result[1 + @as(usize, @intFromBool(uses_build_values))] = .{
                    .id = @intFromEnum(abi.CapabilityId.reschedule),
                    .version = 1,
                };
            break :requirements result;
        };
        pub const descriptor_value = abi.Descriptor{
            .module_name_ptr = ModuleName.ptr,
            .module_name_len = ModuleName.len,
            .module_doc_ptr = ModuleDocumentation.ptr,
            .module_doc_len = ModuleDocumentation.len,
            .definition_count = definitions.len,
            .definitions_ptr = &definitions,
            .capability_count = requirements.len,
            .capabilities_ptr = &requirements,
            .callback_count = definitions.len,
            .invoke = invoke,
        };

        pub fn descriptor() *const abi.Descriptor {
            return &descriptor_value;
        }

        pub fn invoke(
            host: *const abi.HostTable,
            context: *anyopaque,
            callback_index: u32,
            output: *abi.InvokeResult,
        ) callconv(.c) void {
            inline for (Words, 0..) |Word, index| if (callback_index == index) {
                Word.invoke(host, context, output);
                return;
            };
            output.* = .{ .tag = .fail, .reserved = 2 };
        }

        pub export fn ecl_module_abi_v1(output: *abi.EntryResult) callconv(.c) void {
            output.* = .{ .status = .descriptor, .descriptor = &descriptor_value };
        }

        comptime {
            _ = Self.ecl_module_abi_v1;
        }
    };
}

fn isReschedulePointer(comptime CandidateType: type) bool {
    return switch (@typeInfo(CandidateType)) {
        .pointer => |pointer| pointer.size == .one and
            switch (@typeInfo(pointer.child)) {
                .@"opaque", .@"struct", .@"union", .@"enum" => @hasDecl(pointer.child, "ecl_reschedule_marker"),
                else => false,
            },
        else => false,
    };
}

fn parseEffect(comptime source: []const u8) type {
    const counts = effectCounts(source);
    const InputNames = effectSide(source, true, counts.inputs);
    const OutputNames = effectSide(source, false, counts.outputs);
    return struct {
        pub const text = source;
        pub const inputs = InputNames;
        pub const outputs = OutputNames;
    };
}

const EffectCounts = struct { inputs: usize, outputs: usize };

fn effectCounts(comptime source: []const u8) EffectCounts {
    var separator_count: usize = 0;
    var before = true;
    var inputs: usize = 0;
    var outputs: usize = 0;
    var prior: [64][]const u8 = undefined;
    var prior_count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (iterator.next()) |token| {
        if (std.mem.eql(u8, token, "--")) {
            separator_count += 1;
            before = false;
            continue;
        }
        if (!identifier(token)) @compileError("ecl-native: effect contains a non-identifier slot");
        for (prior[0..prior_count]) |seen| if (std.mem.eql(u8, seen, token))
            @compileError("ecl-native: effect contains a duplicate slot name");
        if (prior_count == prior.len) @compileError("ecl-native: effect contains too many slots");
        prior[prior_count] = token;
        prior_count += 1;
        if (before) inputs += 1 else outputs += 1;
    }
    if (separator_count != 1)
        @compileError("ecl-native: effect must contain exactly one -- separator");
    return .{ .inputs = inputs, .outputs = outputs };
}

fn effectSide(
    comptime source: []const u8,
    comptime want_inputs: bool,
    comptime count: usize,
) [count][]const u8 {
    var result: [count][]const u8 = undefined;
    var output_index: usize = 0;
    var before = true;
    var iterator = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (iterator.next()) |token| {
        if (std.mem.eql(u8, token, "--")) {
            before = false;
        } else if (before == want_inputs) {
            result[output_index] = token;
            output_index += 1;
        }
    }
    return result;
}

fn makeSlots(comptime names: anytype) [names.len]abi.EffectSlot {
    var result: [names.len]abi.EffectSlot = undefined;
    for (names, 0..) |name, index| result[index] = .{
        .name_ptr = name.ptr,
        .name_len = name.len,
    };
    return result;
}

fn identifier(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if (!asciiAlpha(bytes[0]) and bytes[0] != '_') return false;
    for (bytes[1..]) |byte|
        if (!asciiAlpha(byte) and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') return false;
    return true;
}

fn asciiAlpha(byte: u8) bool {
    return std.ascii.isAlphabetic(byte);
}
