//! Root module of the Zig-only `ecl-native` author SDK.

const std = @import("std");
pub const abi = @import("ecl-native-abi");
const capability = @import("capability.zig");
const ports = @import("ports.zig");
pub const Port = ports.Port;
pub const Controller = ports.Controller;
pub const PortProgress = ports.Progress;
pub const PortInterests = ports.Interests;

pub const Outcome = capability.Outcome;
pub const ErrorKind = capability.ErrorKind;
pub const Kind = capability.Kind;
pub const Scalar = capability.Scalar;
pub const Candidate = capability.Candidate;
pub const ValueView = capability.ValueView;
pub const CursorStep = capability.CursorStep;
pub const DictCursorStep = capability.DictCursorStep;
pub const ListCursor = capability.ListCursor;
pub const NestedStep = capability.NestedStep;
pub const Path = capability.Path;
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
            views: [EffectSpec.inputs.len]?capability.ViewState = .{null} ** EffectSpec.inputs.len,
            list_cursors: [EffectSpec.inputs.len]?capability.ListCursorState = .{null} ** EffectSpec.inputs.len,
            dict_cursors: [EffectSpec.inputs.len]?capability.DictCursorState = .{null} ** EffectSpec.inputs.len,
            nested: [EffectSpec.inputs.len]?capability.NestedState = .{null} ** EffectSpec.inputs.len,
        };

        fn initAdapter(
            host: *const abi.HostTable,
            context: *anyopaque,
        ) AdapterState {
            return .{ .invocation = .{ .host = host, .context = context } };
        }

        fn loadInputs(adapter_state: *AdapterState) error{ OutOfMemory, InvalidValue }!void {
            for (&adapter_state.views, 0..) |*view, index| {
                view.* = .{
                    .wire = .{ .kind = .int },
                    .invocation = &adapter_state.invocation,
                    .input_index = @intCast(index),
                };
                try capability.requireOk(adapter_state.invocation.host.input(
                    adapter_state.invocation.context,
                    @intCast(index),
                    &view.*.?.wire,
                ));
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
            return @ptrCast(&self.state().views[index].?);
        }

        pub fn listCursor(self: *Self, comptime index: usize, start: u64) ?*ListCursor {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: list cursor input exceeds the declared effect");
            const view = &self.state().views[index].?;
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
            const view = &self.state().views[index].?;
            if (view.wire.kind != .dict or start > view.wire.aggregate_len) return null;
            return DictCursor.initAdapter(
                &self.state().dict_cursors[index],
                &self.state().invocation,
                index,
                view.wire.aggregate_len,
                start,
            );
        }

        /// Reads one value nested inside a declared aggregate input. The path
        /// is the whole position, so it lives happily in continuation state
        /// and a yield between reads costs nothing. The returned view borrows
        /// per-input storage and is valid until the next read of that input.
        pub fn nested(
            self: *Self,
            comptime index: usize,
            path: []const u64,
        ) NestedStep {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: nested read input exceeds the declared effect");
            if (path.len > Path.max_depth) return .invalid;
            const slot = &self.state().nested[index];
            slot.* = .{
                .wire = .{ .kind = .int },
                .invocation = &self.state().invocation,
                .input_index = @intCast(index),
            };
            const status = (self.state().invocation.host.read_path orelse
                return .invalid)(
                self.state().invocation.context,
                @intCast(index),
                path.ptr,
                @intCast(path.len),
                &slot.*.?.wire,
            );
            return switch (status) {
                .ok => .{ .item = @ptrCast(&slot.*.?) },
                .yield_required => .yield_required,
                .invalid, .out_of_memory => .invalid,
                _ => .invalid,
            };
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

        /// Forward a nested input without decoding or rebuilding it. The
        /// candidate is invocation-local, including when it denotes a port.
        /// A port view grants no access to its private backend state.
        pub fn forwardNested(
            self: *Self,
            comptime index: usize,
            path: []const u64,
        ) error{OutOfMemory}!BuildResult {
            if (index >= EffectSpec.inputs.len)
                @compileError("ecl-native: forwarded input exceeds the declared effect");
            if (path.len > Path.max_depth) return .invalid;
            var output: abi.Candidate = 0;
            const invocation = &self.state().invocation;
            return switch ((invocation.host.forward_path orelse return .invalid)(
                invocation.context,
                @intCast(index),
                path.ptr,
                @intCast(path.len),
                &output,
            )) {
                .ok => .{ .candidate = @enumFromInt(output) },
                .yield_required => .yield_required,
                .out_of_memory => error.OutOfMemory,
                .invalid => .invalid,
                _ => .invalid,
            };
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
            const bounded = capability.boundedErrorMessage(message);
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
    var uses_ports = false;
    for (function.params[1..], 1..) |parameter, parameter_index| {
        if (parameter.type == null) @compileError("ecl-native: callback capabilities must have concrete types");
        if (parameter.type.? == *BuildValues) {
            if (build_values) @compileError("ecl-native: callback names a capability more than once");
            if (reschedule)
                @compileError("ecl-native: BuildValues must precede Reschedule");
            build_values = true;
        } else if (isReschedulePointer(parameter.type.?)) {
            if (reschedule) @compileError("ecl-native: callback names a capability more than once");

            reschedule = true;
            RescheduleType = @typeInfo(parameter.type.?).pointer.child;
        } else if (isPortPointer(parameter.type.?)) {
            for (function.params[1..parameter_index]) |prior| if (prior.type.? == parameter.type.?)
                @compileError("ecl-native: callback names a capability more than once");
            uses_ports = true;
        } else {
            @compileError("ecl-native: callback parameter is not a supported capability");
        }
    }
    if (uses_ports and !reschedule) @compileError("ecl-native: Port operations require Reschedule");
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

        var input_slots_storage = makeSlots(NativeCall.effect.inputs);
        var output_slots_storage = makeSlots(NativeCall.effect.outputs);

        pub fn definition(index: u32) abi.Definition {
            return .{
                .callback_index = index,
                .name_ptr = name.ptr,
                .name_len = name.len,
                .doc_ptr = documentation.ptr,
                .doc_len = documentation.len,
                .input_count = input_slots_storage.len,
                .inputs_ptr = &input_slots_storage,
                .output_count = output_slots_storage.len,
                .outputs_ptr = &output_slots_storage,
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
            comptime Ports: anytype,
            host: *const abi.HostTable,
            context: *anyopaque,
            output: *abi.InvokeResult,
        ) void {
            var call_state = NativeCall.initAdapter(host, context);
            NativeCall.loadInputs(&call_state) catch |err| {
                writeAdapterFailure(host, context, output, err);
                return;
            };
            const call = NativeCall.adapterPointer(&call_state);
            var build_state: capability.BuildState = .{ .invocation = &call_state.invocation };
            var reschedule_state: if (uses_reschedule) NativeRescheduleType.AdapterState else void = if (uses_reschedule)
                NativeRescheduleType.initAdapter(&call_state.invocation) catch {
                    output.* = .{ .tag = .fail, .adapter_status = 1 };
                    return;
                }
            else {};
            var port_states: [function.params.len]ports.Adapter = .{ports.Adapter{ .invocation = &call_state.invocation, .definition = 0 }} ** function.params.len;
            // SAFETY: every callback parameter is initialized by the exhaustive capability dispatch below.
            var arguments: std.meta.ArgsTuple(Callback) = undefined;
            arguments[0] = call;
            inline for (function.params[1..], 1..) |parameter, index| {
                const T = parameter.type.?;
                if (comptime T == *BuildValues) arguments[index] = @ptrCast(&build_state) else if (comptime isReschedulePointer(T)) arguments[index] = NativeRescheduleType.adapterPointer(&reschedule_state) else {
                    port_states[index].definition = comptime portIndex(Ports, @typeInfo(T).pointer.child);
                    arguments[index] = @ptrCast(&port_states[index]);
                }
            }
            const result = @call(.auto, callback, arguments);
            const outcome = result catch |err| switch (err) {
                error.OutOfMemory => {
                    output.* = .{ .tag = .fail, .adapter_status = 1 };
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
        error.OutOfMemory => output.* = .{ .tag = .fail, .adapter_status = 1 },
        error.InvalidValue => {
            const message = "native SDK capability argument was rejected";
            _ = host.fail(context, .domain, message.ptr, message.len);
            output.* = .{ .tag = .fail, .adapter_status = 0 };
        },
    }
}

/// How a module reaches its host. A dynamically loaded extension is found
/// through the ABI entry symbol, so exactly one may define it per image; a
/// module linked into a host is handed to the loader as a descriptor and must
/// not export the symbol at all, which is what lets one image carry several.
pub const Linkage = enum { dynamic, static };

pub fn module(comptime spec: anytype) type {
    if (!identifier(spec.name)) @compileError("ecl-native: module name must be a nonempty identifier");
    if (spec.doc.len == 0) @compileError("ecl-native: module documentation must not be empty");
    const module_linkage: Linkage = if (@hasField(@TypeOf(spec), "linkage")) spec.linkage else .dynamic;
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
    const Ports = if (@hasField(@TypeOf(spec), "ports")) spec.ports else .{};
    if (Ports.len > abi.max_port_definitions) @compileError("ecl-native: too many port definitions");
    inline for (Ports, 0..) |P, index| {
        if (!identifier(P.name)) @compileError("ecl-native: port name must be an identifier");
        inline for (0..index) |prior_index| {
            const prior = Ports[prior_index];
            if (std.mem.eql(u8, P.name, prior.name))
                @compileError("ecl-native: module contains a duplicate port name");
        }
    }
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
        @as(usize, @intFromBool(uses_reschedule)) + @as(usize, @intFromBool(Ports.len != 0));
    return struct {
        const Self = @This();
        var definitions_storage = definitions: {
            var result: [word_count]abi.Definition = undefined;
            for (Words, 0..) |Word, index| result[index] = Word.definition(index);
            break :definitions result;
        };
        var ports_storage = definitions: {
            // SAFETY: every declared port contributes exactly one initialized record.
            var result: [Ports.len]abi.PortDefinition = undefined;
            for (Ports, 0..) |P, index| result[index] = P.definition();
            break :definitions result;
        };
        var requirements_storage = requirements: {
            var result: [requirement_count]abi.CapabilityRequirement = undefined;
            result[0] = .{ .id = @intFromEnum(abi.CapabilityId.call) };
            if (uses_build_values)
                result[1] = .{ .id = @intFromEnum(abi.CapabilityId.build_values) };
            if (uses_reschedule)
                result[1 + @as(usize, @intFromBool(uses_build_values))] = .{
                    .id = @intFromEnum(abi.CapabilityId.reschedule),
                };
            if (Ports.len != 0) result[requirement_count - 1] = .{ .id = @intFromEnum(abi.CapabilityId.ports) };
            break :requirements result;
        };
        // The entry point returns this graph after its stack frame is gone;
        // mutable storage forces image-lifetime data symbols on every target.
        var descriptor_storage = abi.Descriptor{
            .module_name_ptr = ModuleName.ptr,
            .module_name_len = ModuleName.len,
            .module_doc_ptr = ModuleDocumentation.ptr,
            .module_doc_len = ModuleDocumentation.len,
            .definition_count = definitions_storage.len,
            .definitions_ptr = &definitions_storage,
            .capability_count = requirements_storage.len,
            .capabilities_ptr = &requirements_storage,
            .callback_count = definitions_storage.len,
            .invoke = invoke,
            .port_count = Ports.len,
            .ports_ptr = &ports_storage,
        };

        pub fn descriptor() *const abi.Descriptor {
            return &descriptor_storage;
        }

        pub fn invoke(
            host: *const abi.HostTable,
            context: *anyopaque,
            callback_index: u32,
            output: *abi.InvokeResult,
        ) callconv(.c) void {
            inline for (Words, 0..) |Word, index| if (callback_index == index) {
                Word.invoke(Ports, host, context, output);
                return;
            };
            output.* = .{ .tag = .fail, .adapter_status = 2 };
        }

        pub fn entryPoint(output: *abi.EntryResult) callconv(.c) void {
            output.* = .{ .status = .descriptor, .descriptor = descriptor() };
        }

        comptime {
            // Only a dynamically loaded extension claims the ABI entry
            // symbol, so several statically linked modules can coexist in one
            // image without colliding on it.
            if (module_linkage == .dynamic)
                @export(&entryPoint, .{ .name = abi.entry_symbol });
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
        // A native `complete` requires the exact output tuple, so the row
        // token — which exists to leave the after row unchecked — has no
        // meaning here and is rejected rather than silently treated as a slot.
        if (std.mem.eql(u8, token, "..."))
            @compileError("ecl-native: effect rows are exact; `...` is not a native slot");
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

fn isPortPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and switch (@typeInfo(p.child)) {
            .@"opaque" => @hasDecl(p.child, "ecl_port_marker"),
            else => false,
        },
        else => false,
    };
}
fn portIndex(comptime Ports: anytype, comptime P: type) u32 {
    inline for (Ports, 0..) |Declared, index| if (Declared == P) return index;
    @compileError("ecl-native: callback port capability is not declared by the module");
}
