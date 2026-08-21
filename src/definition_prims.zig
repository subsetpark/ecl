//! Definition annotations and binding metadata reflection.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const lexer = @import("lexer.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const native_module = @import("native_module.zig");
const kernel_storage = @import("kernel_storage.zig");
const reflection = @import("reflection.zig");
const doc_text = @import("doc.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Mode = enum { def, defp };
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };

fn bind(comptime mode: Mode) env.PrimitiveImpl {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return define(evaluator, mode);
        }
    }.run;
}

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "def", .primitive = bind(.def) },
        .{ .name = "defp", .primitive = bind(.defp) },
        .{ .name = "body", .primitive = body },
        .{ .name = "doc", .primitive = doc },
        .{ .name = "which", .primitive = which },
        .{ .name = "see", .primitive = see },
    };
    try core.installBuiltins(definitions);
}

const Annotation = struct {
    effect: ?env.Effect = null,
    effect_value: ?Value = null,
    doc_value: ?*env.DocumentationString = null,
    doc_source: ?Value = null,

    pub fn deinit(self: *Annotation, releases: *heap.ReleaseDomain) void {
        if (self.effect_value) |item| releases.releaseValue(item);
        if (self.doc_source) |item| releases.releaseValue(item);
        self.* = undefined;
    }
};

fn define(evaluator: *Machine, mode: Mode) MachineError!void {
    try evaluator.require(2);
    const private = mode == .defp;
    const scope = evaluator.currentScope();
    const module_root = scope.kind() == .module_root;
    if (private and !module_root) return evaluator.fail(.domain, "defp/setp are legal only in a module root");
    const name = try evaluator.popSymbol();
    var item = try evaluator.popValue();
    defer item.deinit();
    const separator = try intern.intern("--");
    const colon = try intern.intern(":");
    const phase: DefineDriver.Phase = if (item.borrow() == .list)
        .scan_annotation
    else
        .validate_name;
    try evaluator.startDriver(DefineDriver{
        .mode = mode,
        .scope = scope,
        .name = name,
        .binding_validation = .init(name),
        .item = .init(item.take()),
        .separator = separator,
        .colon = colon,
        .phase = phase,
        .annotation = .init(.{}),
    });
}

const DefineDriver = struct {
    const Phase = enum { scan_annotation, validate_annotation, validate_name, normalize_doc, copy_effect, materialize_effect, publish };
    mode: Mode,
    scope: *env.Scope,
    name: u32,
    binding_validation: intern.NamespaceCursor,
    binding_name: ?intern.BindingName = null,
    item: ?heap.Owned(Value),
    annotation_source: ?heap.Owned(Value) = null,
    separator: u32,
    colon: u32,
    phase: Phase,
    index: usize = 0,
    separator_at: ?usize = null,
    colon_at: ?usize = null,
    effect_end: usize = 0,
    annotation: heap.Owned(Annotation),
    document: ?Value = null,
    normalizer: ?heap.Owned(doc_text.NormalizeCursor) = null,
    effect_items: ?heap.Owned([]Value) = null,
    effect_materializer: ?heap.Owned(kernel_storage.ValueMaterializer) = null,
    publisher: ?heap.Owned(env.Environment.BindCursor) = null,

    fn malformed(evaluator: *Machine) MachineError {
        return evaluator.fail(.domain, "malformed definition annotation");
    }

    pub fn advance(evaluator: *Machine, self: *DefineDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .scan_annotation => {
                const count: usize = @intCast(self.item.?.borrow().list.length());
                if (self.index == count) {
                    if (self.separator_at == null and self.colon_at == null) {
                        self.phase = .validate_name;
                        self.index = 0;
                        continue;
                    }
                    if (self.separator_at != null and self.colon_at != null and
                        self.separator_at.? > self.colon_at.?) return malformed(evaluator);
                    self.effect_end = self.colon_at orelse count;
                    if (self.separator_at == null and self.colon_at.? != 0)
                        return malformed(evaluator);
                    if (self.colon_at) |doc_at| {
                        if (count != doc_at + 2) return malformed(evaluator);
                        const document = list.atUnchecked(self.item.?.borrow(), doc_at + 1);
                        if (!document.isString()) return malformed(evaluator);
                        self.document = document;
                    }
                    self.index = 0;
                    self.phase = .validate_annotation;
                    continue;
                }
                const item = list.atUnchecked(self.item.?.borrow(), self.index);
                if (item == .word and item.word == self.separator) {
                    if (self.separator_at != null) return malformed(evaluator);
                    self.separator_at = self.index;
                } else if (item == .word and item.word == self.colon) {
                    if (self.colon_at != null) return malformed(evaluator);
                    self.colon_at = self.index;
                }
                self.index += 1;
                budget -= 1;
            },
            .validate_annotation => {
                if (self.separator_at) |split| {
                    if (self.index != self.effect_end) {
                        const slot = list.atUnchecked(self.item.?.borrow(), self.index);
                        if (self.index != split and slot != .word)
                            return malformed(evaluator);
                        // The after portion is all named slots or exactly the
                        // row token; the before portion never names a row.
                        if (slot == .word and
                            std.mem.eql(u8, intern.get(slot.word), lexer.row_token) and
                            (self.index <= split or self.effect_end != split + 2))
                            return malformed(evaluator);
                        self.index += 1;
                        budget -= 1;
                        continue;
                    }
                }
                self.annotation_source = .init(self.item.?.take());
                self.item = null;
                try evaluator.require(1);
                var item = try evaluator.popValue();
                self.item = .init(item.take());
                self.index = 0;
                if (self.document) |document| {
                    self.normalizer = .init(try .init(evaluator.allocator(), document));
                    self.phase = .normalize_doc;
                } else if (self.separator_at != null) {
                    self.effect_items = .init(try evaluator.allocator().alloc(Value, self.effect_end));
                    self.phase = .copy_effect;
                } else self.phase = .validate_name;
            },
            .normalize_doc => switch (try self.normalizer.?.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => |normalized| {
                    self.normalizer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.normalizer = null;
                    self.annotation.borrowMut().doc_source = normalized;
                    self.annotation.borrowMut().doc_value = env.documentation(normalized.list) orelse
                        return malformed(evaluator);
                    if (self.separator_at != null) {
                        self.effect_items = .init(try evaluator.allocator().alloc(Value, self.effect_end));
                        self.phase = .copy_effect;
                    } else self.phase = .validate_name;
                    return .yielded;
                },
            },
            .copy_effect => {
                if (self.index == self.effect_end) {
                    self.effect_materializer = .init(.init(
                        evaluator.allocator(),
                        self.effect_items.?.borrow(),
                    ));
                    self.phase = .materialize_effect;
                    continue;
                }
                self.effect_items.?.borrow()[self.index] = list.atUnchecked(
                    self.annotation_source.?.borrow(),
                    self.index,
                );
                self.index += 1;
                budget -= 1;
            },
            .materialize_effect => switch (try self.effect_materializer.?.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => |effect_value| {
                    self.effect_materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.effect_materializer = null;
                    self.annotation.borrowMut().effect_value = effect_value;
                    self.annotation.borrowMut().effect = env.ValidatedEffect.fromValidated(
                        effect_value.list,
                        self.separator_at.?,
                    );
                    self.phase = .validate_name;
                    self.index = 0;
                    return .yielded;
                },
            },
            .validate_name => {
                switch (self.binding_validation.advance()) {
                    .pending => {
                        budget -= 1;
                        continue;
                    },
                    .complete => |name| self.binding_name = name orelse return evaluator.fail(
                        .domain,
                        "def/set requires an unqualified, non-reserved name",
                    ),
                }
                // A module definition records only its own name. The
                // qualified spelling belongs to whichever registration a call
                // reaches it through, so there is nothing to intern here.
                self.phase = .publish;
            },
            .publish => {
                const private = self.mode == .defp;
                const module_root = self.scope.kind() == .module_root;
                if (self.item.?.borrow() != .list)
                    return evaluator.fail(.type, "def expected a list body; use set for values");
                const name = self.binding_name.?;
                const visibility: env.Visibility = if (private) .private else .public;
                if (self.publisher == null) self.publisher = .init(if (module_root)
                    try self.scope.publishModuleCursor(name, .{ .word = .{
                        .body = env.quotation(self.item.?.borrow().list) orelse
                            return evaluator.fail(.domain, "definition body has an invalid heap representation"),
                        .visibility = visibility,
                        .effect = self.annotation.borrow().effect,
                        .doc = self.annotation.borrow().doc_value,
                    } })
                else
                    try self.scope.publishTopCursor(name, .{ .word = .{
                        .body = env.quotation(self.item.?.borrow().list) orelse
                            return evaluator.fail(.domain, "definition body has an invalid heap representation"),
                        .effect = self.annotation.borrow().effect,
                        .doc = self.annotation.borrow().doc_value,
                    } }));
                switch (self.publisher.?.borrowMut().advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Frozen => return evaluator.fail(
                        .domain,
                        "module environments are immutable after registration",
                    ),
                }) {
                    .pending => budget -= 1,
                    .complete => return .completed,
                }
            },
        };
        return .yielded;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn body(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    return installLookup(evaluator, requested, .body);
}

fn doc(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    return installLookup(evaluator, requested, .doc);
}

const LookupMode = enum { body, doc };
const ReflectionResolution = union(enum) {
    resolved: machine.Resolution,
    retry: machine.WorkProgress,
};

/// Reflection consumes its symbol before resolution. On a cold qualified
/// module, destroy the current driver and hand the symbol plus primitive call
/// back to the machine's ordinary load/retry protocol.
fn resolveForReflection(
    evaluator: *Machine,
    driver: anytype,
    requested: u32,
    outcome: machine.ResolutionOutcome,
) MachineError!ReflectionResolution {
    return switch (outcome) {
        .resolved => |resolved| .{ .resolved = resolved },
        .unresolved => evaluator.undefinedName(requested),
        .unknown_module_prefix, .unregistered_module => {
            evaluator.retireDriver(driver);
            return .{ .retry = try evaluator.retryQualifiedOperandAfterLoad(requested, outcome) };
        },
    };
}

fn installLookup(evaluator: *Machine, requested: u32, mode: LookupMode) MachineError!void {
    try evaluator.startDriver(LookupDriver{
        .requested = requested,
        .mode = mode,
        .resolution = .init(machine.ResolutionCursor.init(evaluator, requested)),
    });
}
const LookupDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    requested: u32,
    mode: LookupMode,
    resolution: heap.Owned(machine.ResolutionCursor),
    pub fn advance(evaluator: *Machine, self: *LookupDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.resolution.borrowMut().advance()) {
            .pending => {},
            .complete => |outcome| {
                var resolved = switch (try resolveForReflection(
                    evaluator,
                    self,
                    self.requested,
                    outcome,
                )) {
                    .retry => |progress| return progress,
                    .resolved => |resolution| resolution,
                };
                defer resolved.deinit(evaluator.allocator());
                switch (self.mode) {
                    .body => {
                        const source = switch (resolved.lease.binding) {
                            .word => |source| env.quotationHeader(source),
                            else => return evaluator.typeError("a source-defined word"),
                        };
                        try evaluator.pushBorrowed(.{ .list = source });
                    },
                    .doc => try evaluator.pushBorrowed(.{ .list = env.documentationHeader(
                        resolved.lease.doc orelse return evaluator.fail(.domain, "binding has no documentation"),
                    ) }),
                }
                return .completed;
            },
        };
        return .yielded;
    }
};

fn which(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    try evaluator.startDriver(WhichDriver.init(evaluator, requested));
}

const WhichDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    requested: u32,
    resolution: ?heap.Owned(machine.ResolutionCursor),
    shadow_cursor: ?heap.Owned(machine.ShadowCursor) = null,
    resolved: ?heap.Owned(machine.Resolution) = null,
    shadows: ?heap.Owned([]intern.TraceWord) = null,
    actions: heap.Owned(reflection.ActionPlan),
    initialized: bool = false,
    shadow_index: usize = 0,
    rendered: ?heap.Owned([]u8) = null,

    fn init(evaluator: *Machine, requested: u32) WhichDriver {
        return .{
            .requested = requested,
            .resolution = .init(machine.ResolutionCursor.init(evaluator, requested)),
            .actions = .init(reflection.ActionPlan.init(evaluator.allocator())),
        };
    }
    fn add(self: *WhichDriver, action: reflection.Action) error{OutOfMemory}!void {
        try self.actions.borrowMut().add(action);
    }
    fn initialize(self: *WhichDriver) error{OutOfMemory}!void {
        try self.add(.{ .name = self.requested });
        try self.add(.{ .bytes = " -> " });
        try self.add(.{ .trace_word = self.resolved.?.borrow().trace_word });
        try self.add(.{ .bytes = " " });
        try self.add(.{ .bytes = switch (self.resolved.?.borrow().lease.binding) {
            .word => "def",
            .builtin => "primitive",
            .native => "native",
        } });
        try self.add(.{ .bytes = " " });
        try self.add(.{ .bytes = @tagName(self.resolved.?.borrow().lease.visibility) });
        if (self.resolved.?.borrow().home) |home| {
            try self.add(.{ .bytes = " generation " });
            try self.add(.{ .value = .{ .int = @intCast(home.generationNumber()) } });
        }
        if (self.resolved.?.borrow().lease.effect) |effect| {
            try self.add(.{ .bytes = " " });
            try self.add(.{ .value = .{ .list = effect.header() } });
        }
        switch (self.resolved.?.borrow().lease.binding) {
            .native => |callable| {
                try self.add(.{ .bytes = " requires " });
                for (callable.instance.requirements(), 0..) |requirement, index| {
                    if (index != 0) try self.add(.{ .bytes = ", " });
                    try self.add(.{ .bytes = native_module.capabilityName(requirement.id) });
                }
            },
            else => {},
        }
        self.initialized = true;
    }
    pub fn advance(evaluator: *Machine, self: *WhichDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.resolved == null) {
            var budget: usize = machine.kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.resolution.?.borrowMut().advance()) {
                .pending => {},
                .complete => |outcome| {
                    self.resolved = .init(switch (try resolveForReflection(
                        evaluator,
                        self,
                        self.requested,
                        outcome,
                    )) {
                        .retry => |progress| return progress,
                        .resolved => |resolution| resolution,
                    });
                    self.resolution.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.resolution = null;
                    self.shadow_cursor = .init(machine.ShadowCursor.init(evaluator, self.requested));
                    return .yielded;
                },
            };
            return .yielded;
        }
        if (self.shadows == null) {
            var budget: usize = machine.kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (try self.shadow_cursor.?.borrowMut().advance()) {
                .pending => {},
                .complete => |shadows| {
                    self.shadows = .init(shadows);
                    self.shadow_cursor.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.shadow_cursor = null;
                    break;
                },
            };
            if (self.shadows == null) return .yielded;
        }
        if (!self.initialized) try self.initialize();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0 and self.shadow_index != self.shadows.?.borrow().len) : (budget -= 1) {
            try self.add(.{ .bytes = "; shadows " });
            try self.add(.{ .trace_word = self.shadows.?.borrow()[self.shadow_index] });
            self.shadow_index += 1;
        }
        if (self.shadow_index != self.shadows.?.borrow().len) return .yielded;
        if (!self.actions.borrow().isSealed()) {
            try self.add(.{ .bytes = "\n" });
            self.actions.borrowMut().seal();
        }
        if (self.rendered == null) switch (try self.actions.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |bytes| self.rendered = .init(bytes),
        };
        if (evaluator.unit.inherited.console) |console| {
            console.writeOutput(self.rendered.?.borrow(), false) catch return writeFailure(evaluator);
            return .completed;
        }
        const output = try outputWriter(evaluator);
        output.writeAll(self.rendered.?.borrow()) catch return writeFailure(evaluator);
        output.flush() catch return evaluator.fail(.io, "standard output flush failed");
        return .completed;
    }
};

fn see(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    try evaluator.startDriver(SeeDriver.init(evaluator, requested));
}

const SeeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    requested: u32,
    resolution: ?heap.Owned(machine.ResolutionCursor),
    resolved: ?heap.Owned(machine.Resolution) = null,
    annotation_items: ?heap.Owned([]Value) = null,
    annotation_index: usize = 0,
    annotation_materializer: ?heap.Owned(kernel_storage.ValueMaterializer) = null,
    annotation: ?heap.Owned(Value) = null,
    actions: heap.Owned(reflection.ActionPlan),
    plan_ready: bool = false,
    rendered: ?heap.Owned([]u8) = null,

    fn init(evaluator: *Machine, requested: u32) SeeDriver {
        return .{
            .requested = requested,
            .resolution = .init(machine.ResolutionCursor.init(evaluator, requested)),
            .actions = .init(reflection.ActionPlan.init(evaluator.allocator())),
        };
    }
    fn add(self: *SeeDriver, action: reflection.Action) error{OutOfMemory}!void {
        try self.actions.borrowMut().add(action);
    }

    fn buildPlan(self: *SeeDriver) error{OutOfMemory}!void {
        switch (self.resolved.?.borrow().lease.binding) {
            .word => |source| try self.add(.{ .value = .{ .list = env.quotationHeader(source) } }),
            .builtin => try self.add(.{ .bytes = "<primitive>" }),
            .native => {
                try self.add(.{ .bytes = "<native:" });
                try self.add(.{ .trace_word = self.resolved.?.borrow().trace_word });
                try self.add(.{ .bytes = ">" });
            },
        }
        if (self.annotation) |*annotation| {
            try self.add(.{ .bytes = " " });
            try self.add(.{ .value = annotation.borrow() });
        } else if (self.resolved.?.borrow().lease.effect) |effect| {
            try self.add(.{ .bytes = " " });
            try self.add(.{ .value = .{ .list = effect.header() } });
        }
        switch (self.resolved.?.borrow().lease.binding) {
            .native => |callable| {
                try self.add(.{ .bytes = " requires " });
                for (callable.instance.requirements(), 0..) |requirement, index| {
                    if (index != 0) try self.add(.{ .bytes = ", " });
                    try self.add(.{ .bytes = native_module.capabilityName(requirement.id) });
                }
            },
            else => {},
        }
        try self.add(.{ .bytes = " '" });
        try self.add(.{ .trace_word = self.resolved.?.borrow().trace_word });
        try self.add(.{ .bytes = switch (self.resolved.?.borrow().lease.binding) {
            .word => if (self.resolved.?.borrow().lease.visibility == .private) " defp\n" else " def\n",
            .builtin => " def\n",
            .native => " def\n",
        } });
        self.actions.borrowMut().seal();
        self.plan_ready = true;
    }

    pub fn advance(evaluator: *Machine, self: *SeeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.resolved == null) {
            var budget: usize = machine.kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.resolution.?.borrowMut().advance()) {
                .pending => {},
                .complete => |outcome| {
                    self.resolved = .init(switch (try resolveForReflection(
                        evaluator,
                        self,
                        self.requested,
                        outcome,
                    )) {
                        .retry => |progress| return progress,
                        .resolved => |resolution| resolution,
                    });
                    self.resolution.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.resolution = null;
                    break;
                },
            };
            if (self.resolved == null) return .yielded;
        }
        const document = self.resolved.?.borrow().lease.doc;
        if (!self.plan_ready and document != null) {
            const effect_count: usize = if (self.resolved.?.borrow().lease.effect) |effect|
                @intCast(effect.header().length())
            else
                0;
            if (self.annotation_items == null) self.annotation_items = .init(try evaluator.allocator().alloc(
                Value,
                effect_count + 2,
            ));
            const end = @min(
                self.annotation_index + machine.kernel_poll_quantum,
                effect_count,
            );
            while (self.annotation_index != end) : (self.annotation_index += 1) {
                self.annotation_items.?.borrow()[self.annotation_index] = list.atUnchecked(
                    .{ .list = self.resolved.?.borrow().lease.effect.?.header() },
                    self.annotation_index,
                );
            }
            if (self.annotation_index != effect_count) return .yielded;
            self.annotation_items.?.borrow()[effect_count] = .{ .word = try intern.intern(":") };
            self.annotation_items.?.borrow()[effect_count + 1] = .{
                .list = env.documentationHeader(document.?),
            };
            if (self.annotation_materializer == null) self.annotation_materializer = .init(kernel_storage.ValueMaterializer.init(
                evaluator.allocator(),
                self.annotation_items.?.borrow(),
            ));
            switch (try self.annotation_materializer.?.borrowMut().advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |annotation| {
                    self.annotation_materializer.?.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.annotation_materializer = null;
                    self.annotation = .init(annotation);
                    try self.buildPlan();
                    return .yielded;
                },
            }
        }
        if (!self.plan_ready) try self.buildPlan();
        if (self.rendered == null) switch (try self.actions.borrowMut().advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |bytes| self.rendered = .init(bytes),
        };
        if (evaluator.unit.inherited.console) |console| {
            console.writeOutput(self.rendered.?.borrow(), false) catch return writeFailure(evaluator);
            return .completed;
        }
        const output = try outputWriter(evaluator);
        output.writeAll(self.rendered.?.borrow()) catch return writeFailure(evaluator);
        output.flush() catch return evaluator.fail(.io, "standard output flush failed");
        return .completed;
    }
};

fn outputWriter(evaluator: *Machine) MachineError!*std.Io.Writer {
    return evaluator.unit.output orelse return evaluator.fail(.io, "standard output is unavailable");
}

fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}
