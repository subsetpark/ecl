//! Bounded validation and runtime-owned materialization of native descriptors.

const std = @import("std");
const abi = @import("native-abi");
const doc = @import("doc.zig");
const env = @import("env.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const storage = @import("kernel_storage.zig");
const value = @import("value.zig");

const max_module_name_bytes = 256;
const max_word_name_bytes = 256;
const max_document_bytes = 64 * 1024;
const max_definitions = 4096;
const max_capabilities = 64;
const max_effect_slots = 256;

pub const ValidateError = error{
    OutOfMemory,
    AbiVersionMismatch,
    UnsupportedCapabilityId,
    RecordSizeMismatch,
    RecordAlignmentMismatch,
    CountOverflow,
    CallbackIndexOutOfRange,
    InvalidUtf8,
    EmptyDocumentation,
    InvalidName,
    InvalidEffect,
    DuplicateDefinition,
    InvalidContinuation,
    ModuleNameMismatch,
    MissingInvoke,
};

pub const ValidatedDefinition = struct {
    name: intern.BindingName,
    doc: *env.DocumentationString,
    effect: env.ValidatedEffect,
    callback_index: u32,
    continuation_size: u32,
    continuation_alignment: u32,
    init_continuation: ?abi.StateInitFn,
    deinit_continuation: ?abi.StateDeinitFn,
};

const DescriptorState = struct {
    host: *const heap.HostCleanup,
    name: intern.ModuleName,
    doc: *env.DocumentationString,
    definitions: []ValidatedDefinition,
    requirements: []abi.CapabilityRequirement,
    invoke: abi.Invoke,
    callback_count: u32,

    fn deinit(self: *DescriptorState) void {
        const allocator = self.host.allocator();
        const releases = heap.hostDomain(self.host);
        releases.releaseHeader(env.documentationHeader(self.doc));
        for (self.definitions) |definition| {
            releases.releaseHeader(env.documentationHeader(definition.doc));
            definition.effect.retire(releases);
        }
        allocator.free(self.definitions);
        allocator.free(self.requirements);
        allocator.destroy(self);
    }
};

/// Opaque validated metadata. Construction is possible only through
/// `ValidateCursor`, and destruction stays bound to the issuing host root.
pub const ValidatedDescriptor = opaque {
    fn state(self: *const ValidatedDescriptor) *const DescriptorState {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *ValidatedDescriptor) void {
        const mutable: *DescriptorState = @ptrCast(@alignCast(self));
        mutable.deinit();
    }

    pub fn name(self: *const ValidatedDescriptor) intern.ModuleName {
        return self.state().name;
    }

    pub fn documentation(self: *const ValidatedDescriptor) *env.DocumentationString {
        return self.state().doc;
    }

    pub fn definitions(self: *const ValidatedDescriptor) []const ValidatedDefinition {
        return self.state().definitions;
    }

    pub fn requirements(self: *const ValidatedDescriptor) []const abi.CapabilityRequirement {
        return self.state().requirements;
    }

    pub fn invoke(self: *const ValidatedDescriptor) abi.Invoke {
        return self.state().invoke;
    }

    pub fn callbackCount(self: *const ValidatedDescriptor) u32 {
        return self.state().callback_count;
    }
};

pub const Progress = union(enum) {
    pending,
    complete: *ValidatedDescriptor,
};

const DocumentBuild = struct {
    host: *const heap.HostCleanup,
    state: State,

    const State = union(enum) {
        materialize: storage.TextMaterializer,
        source: value.Value,
        normalize: struct {
            source: value.Value,
            cursor: doc.NormalizeCursor,
        },
        complete: *env.DocumentationString,
        failed,
        consumed,
    };

    fn init(host: *const heap.HostCleanup, source: []const u8) DocumentBuild {
        return .{
            .host = host,
            .state = .{ .materialize = .init(host.allocator(), source) },
        };
    }

    fn deinit(self: *DocumentBuild) void {
        const releases = heap.hostDomain(self.host);
        switch (self.state) {
            .materialize => |*materializer| materializer.retire(releases),
            .source => |source| releases.releaseValue(source),
            .normalize => |*normalizing| {
                normalizing.cursor.retire(releases);
                releases.releaseValue(normalizing.source);
            },
            .complete => |result| releases.releaseHeader(env.documentationHeader(result)),
            .failed, .consumed => {},
        }
        self.* = undefined;
    }

    fn advance(self: *DocumentBuild, budget: usize) ValidateError!?*env.DocumentationString {
        switch (self.state) {
            .materialize => |*materializer| switch (try materializer.advance(budget)) {
                .pending => return null,
                .complete => |document| {
                    materializer.deinit();
                    self.state = .{ .source = document };
                    return null;
                },
            },
            .source => |source| {
                const normalizer = try doc.NormalizeCursor.init(self.host.allocator(), source);
                self.state = .{ .normalize = .{ .source = source, .cursor = normalizer } };
                return null;
            },
            .normalize => |*normalizing| switch (try normalizing.cursor.advance(budget)) {
                .pending => return null,
                .complete => |normalized| {
                    const source = normalizing.source;
                    normalizing.cursor.deinit();
                    heap.hostDomain(self.host).releaseValue(source);
                    if (normalized.list.length() == 0) {
                        heap.hostDomain(self.host).releaseValue(normalized);
                        self.state = .failed;
                        return error.EmptyDocumentation;
                    }
                    const result = env.documentation(normalized.list).?;
                    self.state = .{ .complete = result };
                    return result;
                },
            },
            .complete => |result| return result,
            .failed, .consumed => unreachable,
        }
    }

    fn take(self: *DocumentBuild) *env.DocumentationString {
        return switch (self.state) {
            .complete => |result| moved: {
                self.state = .consumed;
                break :moved result;
            },
            else => unreachable,
        };
    }
};

const EffectBuild = struct {
    host: *const heap.HostCleanup,
    definition: abi.Definition,
    tokens: []value.Value,
    state: State = .{ .inputs = .{} },

    const SlotState = struct {
        index: usize = 0,
        work: union(enum) {
            next,
            inserting: intern.InternInsertionCursor,
        } = .next,
    };
    const State = union(enum) {
        inputs: SlotState,
        separator,
        outputs: SlotState,
        materialize: storage.GenericValueMaterializer,
        materialized: value.Value,
        complete: env.ValidatedEffect,
        failed,
        consumed,
    };

    fn init(host: *const heap.HostCleanup, definition: abi.Definition) ValidateError!EffectBuild {
        const count = std.math.add(
            usize,
            @as(usize, definition.input_count),
            @as(usize, definition.output_count),
        ) catch return error.CountOverflow;
        if (definition.input_count > max_effect_slots or definition.output_count > max_effect_slots)
            return error.CountOverflow;
        const token_count = std.math.add(usize, count, 1) catch return error.CountOverflow;
        return .{
            .host = host,
            .definition = definition,
            .tokens = try host.allocator().alloc(value.Value, token_count),
        };
    }

    fn deinit(self: *EffectBuild) void {
        const releases = heap.hostDomain(self.host);
        switch (self.state) {
            .materialize => |*materializer| materializer.retire(releases),
            .materialized => |item| releases.releaseValue(item),
            .complete => |effect| effect.retire(releases),
            .inputs, .separator, .outputs, .failed, .consumed => {},
        }
        self.host.allocator().free(self.tokens);
        self.* = undefined;
    }

    fn advance(self: *EffectBuild, budget: usize) ValidateError!?env.ValidatedEffect {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) switch (self.state) {
            .inputs => |*slots| {
                if (try self.advanceSlot(slots, true)) self.state = .separator;
            },
            .separator => {
                self.tokens[self.definition.input_count] = .{ .word = .{ .name = try intern.intern("--") } };
                self.state = .{ .outputs = .{} };
            },
            .outputs => |*slots| {
                if (try self.advanceSlot(slots, false)) {
                    self.state = .{ .materialize = .init(self.host.allocator(), self.tokens) };
                }
            },
            .materialize => |*materializer| switch (try materializer.advance(remaining)) {
                .pending => return null,
                .complete => |item| {
                    materializer.deinit();
                    self.state = .{ .materialized = item };
                    return null;
                },
            },
            .materialized => |item| {
                const parsed = env.ValidatedEffect.parse(item.list, try intern.intern("--")) orelse {
                    heap.hostDomain(self.host).releaseValue(item);
                    self.state = .failed;
                    return error.InvalidEffect;
                };
                self.state = .{ .complete = parsed };
                return parsed;
            },
            .complete => |effect| return effect,
            .failed, .consumed => unreachable,
        };
        return null;
    }

    fn advanceSlot(self: *EffectBuild, slots: *SlotState, input: bool) ValidateError!bool {
        const index = slots.index;
        const count = if (input) self.definition.input_count else self.definition.output_count;
        if (index == count) return true;
        const base = if (input) self.definition.inputs_ptr else self.definition.outputs_ptr;
        const stride = if (input) self.definition.input_record_size else self.definition.output_record_size;
        switch (slots.work) {
            .inserting => |*inserter| return switch (try inserter.advance()) {
                .pending => false,
                .complete => |id| complete: {
                    const token_index = if (input)
                        slots.index
                    else
                        @as(usize, self.definition.input_count) + 1 + slots.index;
                    self.tokens[token_index] = .{ .word = .{ .name = id } };
                    slots.index += 1;
                    slots.work = .next;
                    break :complete false;
                },
            },
            .next => {
                const records = try RecordArray(abi.EffectSlot).init(base, count, stride);
                const slot = try records.read(index);
                try validateRecordSize(slot.size, @sizeOf(abi.EffectSlot));
                const bytes = guestUtf8(slot.name_ptr, slot.name_len, max_word_name_bytes) catch
                    return error.InvalidEffect;
                if (bytes.len == 0) return error.InvalidEffect;
                slots.work = .{ .inserting = intern.insertionCursor(bytes) };
                return false;
            },
        }
    }

    fn take(self: *EffectBuild) env.ValidatedEffect {
        return switch (self.state) {
            .complete => |effect| moved: {
                self.state = .consumed;
                break :moved effect;
            },
            else => unreachable,
        };
    }
};

pub const ValidateCursor = struct {
    host: *const heap.HostCleanup,
    requested: intern.ModuleName,
    descriptor_ptr: *const abi.Descriptor,
    state: State = .header,
    failure_definition: ?u32 = null,

    const Allocated = struct {
        descriptor: abi.Descriptor,
        requirements: []abi.CapabilityRequirement,
        definitions: []ValidatedDefinition,
    };
    const ModuleArtifacts = struct {
        descriptor: abi.Descriptor,
        name: intern.ModuleName,
        doc: *env.DocumentationString,
        requirements: []abi.CapabilityRequirement,
        capability_index: usize = 0,
        definitions: []ValidatedDefinition,
        definition_index: usize = 0,
    };
    const DefinitionBuild = struct {
        module: ModuleArtifacts,
        definition: abi.Definition,
        name: intern.NamespaceName,
    };
    const State = union(enum) {
        header,
        module_name: Allocated,
        module_doc: struct {
            allocated: Allocated,
            name: intern.ModuleName,
            builder: DocumentBuild,
        },
        capabilities: ModuleArtifacts,
        definition: ModuleArtifacts,
        definition_doc: struct {
            build: DefinitionBuild,
            builder: DocumentBuild,
        },
        definition_effect_init: struct {
            build: DefinitionBuild,
            doc: *env.DocumentationString,
        },
        definition_effect: struct {
            build: DefinitionBuild,
            doc: *env.DocumentationString,
            builder: EffectBuild,
        },
        finish: ModuleArtifacts,
        complete,
        failed,
    };

    pub fn init(
        host: *const heap.HostCleanup,
        requested: intern.ModuleName,
        descriptor: *const abi.Descriptor,
    ) ValidateCursor {
        return .{ .host = host, .requested = requested, .descriptor_ptr = descriptor };
    }

    pub fn deinit(self: *ValidateCursor) void {
        self.cleanup();
        self.* = undefined;
    }

    pub fn failingDefinition(self: *const ValidateCursor) ?u32 {
        return self.failure_definition;
    }

    pub fn advance(self: *ValidateCursor, budget: usize) ValidateError!Progress {
        std.debug.assert(budget != 0 and self.state != .complete and self.state != .failed);
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) switch (self.state) {
            .header => self.validateHeader() catch |err| return self.reject(err, null),
            .module_name => |allocated| self.validateModuleName(allocated) catch |err|
                return self.reject(err, null),
            .module_doc => |*module_doc| {
                const completed = module_doc.builder.advance(remaining) catch |err|
                    return self.reject(err, null);
                if (completed == null) return .pending;
                const allocated = module_doc.allocated;
                const name = module_doc.name;
                const document = module_doc.builder.take();
                module_doc.builder.deinit();
                self.state = .{ .capabilities = .{
                    .descriptor = allocated.descriptor,
                    .name = name,
                    .doc = document,
                    .requirements = allocated.requirements,
                    .definitions = allocated.definitions,
                } };
            },
            .capabilities => |*module| self.validateCapability(module) catch |err|
                return self.reject(err, null),
            .definition => |*module| self.prepareDefinition(module) catch |err|
                return self.reject(err, @intCast(module.definition_index)),
            .definition_doc => |*definition_doc| {
                const definition_index = definition_doc.build.module.definition_index;
                const completed = definition_doc.builder.advance(remaining) catch |err|
                    return self.reject(err, @intCast(definition_index));
                if (completed == null) return .pending;
                const build = definition_doc.build;
                const document = definition_doc.builder.take();
                definition_doc.builder.deinit();
                self.state = .{ .definition_effect_init = .{
                    .build = build,
                    .doc = document,
                } };
            },
            .definition_effect_init => |initializing| {
                const builder = EffectBuild.init(self.host, initializing.build.definition) catch |err|
                    return self.reject(err, @intCast(initializing.build.module.definition_index));
                self.state = .{ .definition_effect = .{
                    .build = initializing.build,
                    .doc = initializing.doc,
                    .builder = builder,
                } };
            },
            .definition_effect => |*definition_effect| {
                const definition_index = definition_effect.build.module.definition_index;
                const completed = definition_effect.builder.advance(remaining) catch |err|
                    return self.reject(err, @intCast(definition_index));
                if (completed == null) return .pending;
                var module = definition_effect.build.module;
                const definition = definition_effect.build.definition;
                const name = definition_effect.build.name;
                const document = definition_effect.doc;
                const effect = definition_effect.builder.take();
                definition_effect.builder.deinit();
                module.definitions[module.definition_index] = .{
                    .name = name,
                    .doc = document,
                    .effect = effect,
                    .callback_index = definition.callback_index,
                    .continuation_size = definition.continuation_size,
                    .continuation_alignment = definition.continuation_alignment,
                    .init_continuation = definition.init_continuation,
                    .deinit_continuation = definition.deinit_continuation,
                };
                module.definition_index += 1;
                self.state = .{ .definition = module };
            },
            .finish => return self.finish() catch |err| self.reject(err, null),
            .complete, .failed => unreachable,
        };
        return .pending;
    }

    fn validateHeader(self: *ValidateCursor) ValidateError!void {
        const declared_size = self.descriptor_ptr.size;
        try validateRecordSize(declared_size, @sizeOf(abi.Descriptor));
        const descriptor = self.descriptor_ptr.*;
        if (descriptor.abi_version != abi.abi_version) return error.AbiVersionMismatch;
        if (descriptor.definition_count > max_definitions or
            descriptor.capability_count > max_capabilities)
            return error.CountOverflow;
        _ = try RecordArray(abi.Definition).init(
            descriptor.definitions_ptr,
            descriptor.definition_count,
            descriptor.definition_record_size,
        );
        _ = try RecordArray(abi.CapabilityRequirement).init(
            descriptor.capabilities_ptr,
            descriptor.capability_count,
            descriptor.capability_record_size,
        );
        if (descriptor.callback_count != 0 and descriptor.invoke == null)
            return error.MissingInvoke;
        const requirements = try self.host.allocator().alloc(
            abi.CapabilityRequirement,
            descriptor.capability_count,
        );
        errdefer self.host.allocator().free(requirements);
        const definitions = try self.host.allocator().alloc(
            ValidatedDefinition,
            descriptor.definition_count,
        );
        self.state = .{ .module_name = .{
            .descriptor = descriptor,
            .requirements = requirements,
            .definitions = definitions,
        } };
    }

    fn validateModuleName(self: *ValidateCursor, allocated: Allocated) ValidateError!void {
        const bytes = try guestUtf8(
            allocated.descriptor.module_name_ptr,
            allocated.descriptor.module_name_len,
            max_module_name_bytes,
        );
        const name = intern.internModuleName(bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => return error.InvalidName,
        };
        if (name != self.requested) return error.ModuleNameMismatch;
        const document = try guestUtf8(
            allocated.descriptor.module_doc_ptr,
            allocated.descriptor.module_doc_len,
            max_document_bytes,
        );
        self.state = .{ .module_doc = .{
            .allocated = allocated,
            .name = name,
            .builder = .init(self.host, document),
        } };
    }

    fn validateCapability(self: *ValidateCursor, module: *ModuleArtifacts) ValidateError!void {
        if (module.capability_index == module.descriptor.capability_count) {
            const moved = module.*;
            self.state = .{ .definition = moved };
            return;
        }
        const records = try RecordArray(abi.CapabilityRequirement).init(
            module.descriptor.capabilities_ptr,
            module.descriptor.capability_count,
            module.descriptor.capability_record_size,
        );
        const requirement = try records.read(module.capability_index);
        try validateRecordSize(requirement.size, @sizeOf(abi.CapabilityRequirement));
        switch (@as(abi.CapabilityId, @enumFromInt(requirement.id))) {
            .call, .build_values, .reschedule => {},
            _ => return error.UnsupportedCapabilityId,
        }
        module.requirements[module.capability_index] = requirement;
        module.capability_index += 1;
    }

    fn prepareDefinition(self: *ValidateCursor, module: *ModuleArtifacts) ValidateError!void {
        if (module.definition_index == module.descriptor.definition_count) {
            const moved = module.*;
            self.state = .{ .finish = moved };
            return;
        }
        const records = try RecordArray(abi.Definition).init(
            module.descriptor.definitions_ptr,
            module.descriptor.definition_count,
            module.descriptor.definition_record_size,
        );
        const definition = try records.read(module.definition_index);
        try validateRecordSize(definition.size, @sizeOf(abi.Definition));
        if (definition.callback_index >= module.descriptor.callback_count)
            return error.CallbackIndexOutOfRange;
        const has_continuation = definition.continuation_size != 0 or
            definition.continuation_alignment != 0 or
            definition.init_continuation != null or definition.deinit_continuation != null;
        if (has_continuation) {
            if (definition.continuation_size == 0 or
                definition.continuation_size > abi.max_continuation_state_bytes or
                definition.continuation_alignment == 0 or
                definition.continuation_alignment > abi.max_continuation_alignment or
                !std.math.isPowerOfTwo(definition.continuation_alignment) or
                definition.init_continuation == null or definition.deinit_continuation == null or
                !hasCapability(module, .reschedule))
                return error.InvalidContinuation;
        }
        _ = try RecordArray(abi.EffectSlot).init(
            definition.inputs_ptr,
            definition.input_count,
            definition.input_record_size,
        );
        _ = try RecordArray(abi.EffectSlot).init(
            definition.outputs_ptr,
            definition.output_count,
            definition.output_record_size,
        );
        const name_bytes = try guestUtf8(definition.name_ptr, definition.name_len, max_word_name_bytes);
        const name = intern.internNamespace(name_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => return error.InvalidName,
        };
        for (module.definitions[0..module.definition_index]) |prior|
            if (prior.name == name) return error.DuplicateDefinition;
        const document = try guestUtf8(definition.doc_ptr, definition.doc_len, max_document_bytes);
        const moved = module.*;
        self.state = .{ .definition_doc = .{
            .build = .{ .module = moved, .definition = definition, .name = name },
            .builder = .init(self.host, document),
        } };
    }

    fn hasCapability(module: *const ModuleArtifacts, id: abi.CapabilityId) bool {
        for (module.requirements[0..module.capability_index]) |requirement|
            if (requirement.id == @intFromEnum(id)) return true;
        return false;
    }

    fn finish(self: *ValidateCursor) ValidateError!Progress {
        const module = self.state.finish;
        const invoke = module.descriptor.invoke orelse return error.MissingInvoke;
        const state = try self.host.allocator().create(DescriptorState);
        state.* = .{
            .host = self.host,
            .name = module.name,
            .doc = module.doc,
            .definitions = module.definitions,
            .requirements = module.requirements,
            .invoke = invoke,
            .callback_count = module.descriptor.callback_count,
        };
        self.state = .complete;
        return .{ .complete = @ptrCast(state) };
    }

    fn reject(self: *ValidateCursor, err: ValidateError, definition: ?u32) ValidateError {
        self.failure_definition = definition;
        self.cleanup();
        self.state = .failed;
        return err;
    }

    fn cleanup(self: *ValidateCursor) void {
        const releases = heap.hostDomain(self.host);
        switch (self.state) {
            .header, .complete, .failed => {},
            .module_name => |*allocated| self.cleanupAllocated(allocated),
            .module_doc => |*module_doc| {
                module_doc.builder.deinit();
                self.cleanupAllocated(&module_doc.allocated);
            },
            .capabilities => |*module| self.cleanupModule(module, releases),
            .definition => |*module| self.cleanupModule(module, releases),
            .definition_doc => |*definition_doc| {
                definition_doc.builder.deinit();
                self.cleanupModule(&definition_doc.build.module, releases);
            },
            .definition_effect_init => |*initializing| {
                releases.releaseHeader(env.documentationHeader(initializing.doc));
                self.cleanupModule(&initializing.build.module, releases);
            },
            .definition_effect => |*definition_effect| {
                definition_effect.builder.deinit();
                releases.releaseHeader(env.documentationHeader(definition_effect.doc));
                self.cleanupModule(&definition_effect.build.module, releases);
            },
            .finish => |*module| self.cleanupModule(module, releases),
        }
    }

    fn cleanupAllocated(self: *ValidateCursor, allocated: *Allocated) void {
        self.host.allocator().free(allocated.definitions);
        self.host.allocator().free(allocated.requirements);
    }

    fn cleanupModule(
        self: *ValidateCursor,
        module: *ModuleArtifacts,
        releases: *heap.ReleaseDomain,
    ) void {
        releases.releaseHeader(env.documentationHeader(module.doc));
        for (module.definitions[0..module.definition_index]) |definition| {
            releases.releaseHeader(env.documentationHeader(definition.doc));
            definition.effect.retire(releases);
        }
        self.host.allocator().free(module.definitions);
        self.host.allocator().free(module.requirements);
    }
};

fn validateRecordSize(size: u32, expected: u32) ValidateError!void {
    if (size != expected) return error.RecordSizeMismatch;
}

/// The single module-to-host text ingress. Callers choose only their semantic
/// length ceiling; pointer/null, representability, and UTF-8 policy live here.
pub fn guestUtf8(
    pointer: ?[*]const u8,
    length: u64,
    maximum: usize,
) ValidateError![]const u8 {
    const len = std.math.cast(usize, length) orelse return error.CountOverflow;
    if (len > maximum) return error.CountOverflow;
    if (len == 0) return "";
    const bytes = (pointer orelse return error.InvalidUtf8)[0..len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

fn RecordArray(comptime T: type) type {
    return struct {
        pointer: [*]const T,
        count: usize,
        stride: usize,

        fn init(pointer: [*]const T, count_wire: u32, stride_wire: u32) ValidateError!@This() {
            try validateRecordSize(stride_wire, @sizeOf(T));
            if (count_wire == 0) return .{ .pointer = pointer, .count = 0, .stride = @sizeOf(T) };
            if (stride_wire % @alignOf(T) != 0 or @intFromPtr(pointer) % @alignOf(T) != 0)
                return error.RecordAlignmentMismatch;
            const count: usize = count_wire;
            const stride: usize = stride_wire;
            const last_offset = std.math.mul(usize, count - 1, stride) catch
                return error.CountOverflow;
            _ = std.math.add(usize, last_offset, @sizeOf(T)) catch return error.CountOverflow;
            return .{ .pointer = pointer, .count = count, .stride = stride };
        }

        fn read(self: @This(), index: usize) ValidateError!T {
            if (index >= self.count) return error.CountOverflow;
            const offset = std.math.mul(usize, self.stride, index) catch
                return error.CountOverflow;
            const address = std.math.add(usize, @intFromPtr(self.pointer), offset) catch
                return error.CountOverflow;
            const record: *const T = @ptrFromInt(address);
            const declared_size = record.size;
            try validateRecordSize(declared_size, @sizeOf(T));
            return record.*;
        }
    };
}

pub fn mapErrorKind(kind: abi.ErrorKindWire) ?machine.ErrorKind {
    return switch (kind) {
        .type => .type,
        .shape => .shape,
        .conform => .conform,
        .overflow => .overflow,
        .domain => .domain,
        .parse => .parse,
        .io => .io,
        .user => .user,
        _ => null,
    };
}

comptime {
    for (@typeInfo(abi.ErrorKindWire).@"enum".fields) |field| {
        const wire: abi.ErrorKindWire = @enumFromInt(field.value);
        if (!std.mem.eql(u8, @tagName(mapErrorKind(wire).?), field.name))
            @compileError("native error-kind mapping no longer matches machine.ErrorKind");
    }
}
