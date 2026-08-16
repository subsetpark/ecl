//! Definition annotations and binding metadata reflection.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const kernel_storage = @import("kernel_storage.zig");
const reflection = @import("reflection.zig");
const doc_text = @import("doc.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Mode = enum { def, set, defp, setp };
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
        .{ .name = "set", .primitive = bind(.set) },
        .{ .name = "defp", .primitive = bind(.defp) },
        .{ .name = "setp", .primitive = bind(.setp) },
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

    fn deinit(self: *Annotation, releases: *heap.ReleaseDomain) void {
        if (self.effect_value) |item| releases.releaseValue(item);
        if (self.doc_source) |item| releases.releaseValue(item);
        self.* = undefined;
    }
};

fn define(evaluator: *Machine, mode: Mode) MachineError!void {
    try evaluator.require(2);
    const word_binding = mode == .def or mode == .defp;
    const private = mode == .defp or mode == .setp;
    const scope = evaluator.currentScope();
    const module_root = scope.kind() == .module_root;
    if (private and !module_root) return evaluator.fail(.domain, "defp/setp are legal only in a module root");
    const name = try popSymbol(evaluator);
    var item = try evaluator.popValue();
    defer item.deinit();
    const driver = try evaluator.allocator().create(DefineDriver);
    driver.* = .{
        .mode = mode,
        .scope = scope,
        .name = name,
        .item = item.borrow(),
        .separator = try intern.intern("--"),
        .colon = try intern.intern(":"),
        .phase = if (word_binding and item.borrow() == .list) .scan_annotation else .validate_name,
    };
    _ = item.take();
    evaluator.installWorkDriver(driver);
}

const DefineDriver = struct {
    mode: Mode,
    scope: *env.Scope,
    name: u32,
    item: ?Value,
    annotation_source: ?Value = null,
    separator: u32,
    colon: u32,
    phase: enum { scan_annotation, validate_annotation, validate_name, normalize_doc, copy_effect, materialize_effect, qualify_name, publish },
    index: usize = 0,
    separator_at: ?usize = null,
    colon_at: ?usize = null,
    effect_end: usize = 0,
    annotation: Annotation = .{},
    document: ?Value = null,
    normalizer: ?doc_text.NormalizeCursor = null,
    effect_items: ?[]Value = null,
    effect_materializer: ?kernel_storage.ValueMaterializer = null,
    qualified: ?intern.QualifiedCursor = null,
    trace_word: ?u32 = null,
    publisher: ?env.Environment.BindCursor = null,

    fn malformed(evaluator: *Machine) MachineError {
        return evaluator.fail(.domain, "malformed definition annotation");
    }

    pub fn advance(evaluator: *Machine, self: *DefineDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .scan_annotation => {
                const count: usize = @intCast(self.item.?.list.length());
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
                        const document = list.atUnchecked(self.item.?, doc_at + 1);
                        if (!document.isString()) return malformed(evaluator);
                        self.document = document;
                    }
                    self.index = 0;
                    self.phase = .validate_annotation;
                    continue;
                }
                const item = list.atUnchecked(self.item.?, self.index);
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
                        if (self.index != split and list.atUnchecked(self.item.?, self.index) != .word)
                            return malformed(evaluator);
                        self.index += 1;
                        budget -= 1;
                        continue;
                    }
                }
                self.annotation_source = self.item;
                self.item = null;
                try evaluator.require(1);
                var item = try evaluator.popValue();
                self.item = item.take();
                self.index = 0;
                if (self.document) |document| {
                    self.normalizer = try .init(evaluator.allocator(), document);
                    self.phase = .normalize_doc;
                } else if (self.separator_at != null) {
                    self.effect_items = try evaluator.allocator().alloc(Value, self.effect_end);
                    self.phase = .copy_effect;
                } else self.phase = .validate_name;
            },
            .normalize_doc => switch (try self.normalizer.?.advance(budget)) {
                .pending => return .yielded,
                .complete => |normalized| {
                    self.normalizer.?.deinit();
                    self.normalizer = null;
                    self.annotation.doc_source = normalized;
                    self.annotation.doc_value = env.documentation(normalized.list) orelse
                        return malformed(evaluator);
                    if (self.separator_at != null) {
                        self.effect_items = try evaluator.allocator().alloc(Value, self.effect_end);
                        self.phase = .copy_effect;
                    } else self.phase = .validate_name;
                    return .yielded;
                },
            },
            .copy_effect => {
                if (self.index == self.effect_end) {
                    self.effect_materializer = .init(evaluator.allocator(), self.effect_items.?);
                    self.phase = .materialize_effect;
                    continue;
                }
                self.effect_items.?[self.index] = list.atUnchecked(self.annotation_source.?, self.index);
                self.index += 1;
                budget -= 1;
            },
            .materialize_effect => switch (try self.effect_materializer.?.advance(budget)) {
                .pending => return .yielded,
                .complete => |effect_value| {
                    self.effect_materializer.?.deinit();
                    self.effect_materializer = null;
                    self.annotation.effect_value = effect_value;
                    self.annotation.effect = env.ValidatedEffect.fromValidated(
                        effect_value.list,
                        self.separator_at.?,
                    );
                    self.phase = .validate_name;
                    self.index = 0;
                    return .yielded;
                },
            },
            .validate_name => {
                const bytes = intern.get(self.name);
                if (bytes.len == 0 or std.mem.eql(u8, bytes, "--") or std.mem.eql(u8, bytes, ":"))
                    return evaluator.fail(.domain, "def/set requires an unqualified, non-reserved name");
                if (self.index != bytes.len) {
                    if (bytes[self.index] == '.')
                        return evaluator.fail(.domain, "def/set requires an unqualified, non-reserved name");
                    self.index += 1;
                    budget -= 1;
                    continue;
                }
                if (self.scope.kind() == .module_root) {
                    self.qualified = try .init(
                        evaluator.allocator(),
                        intern.namespaceId(evaluator.currentHome().?.name()),
                        self.name,
                    );
                    self.phase = .qualify_name;
                } else self.phase = .publish;
            },
            .qualify_name => switch (try self.qualified.?.advance()) {
                .pending => budget -= 1,
                .complete => |trace_word| {
                    self.trace_word = trace_word;
                    self.phase = .publish;
                },
            },
            .publish => {
                const word_binding = self.mode == .def or self.mode == .defp;
                const private = self.mode == .defp or self.mode == .setp;
                const module_root = self.scope.kind() == .module_root;
                if (word_binding and self.item.? != .list)
                    return evaluator.fail(.type, "def expected a list body; use set for values");
                if (module_root and word_binding and self.annotation.effect == null)
                    return evaluator.fail(.domain, "module def/defp requires an effect declaration");
                const name: intern.NamespaceName = @enumFromInt(self.name);
                const visibility: env.Visibility = if (private) .private else .public;
                if (self.publisher == null) self.publisher = if (module_root)
                    try self.scope.publishModuleCursor(name, self.trace_word.?, if (word_binding) .{ .word = .{
                        .body = env.quotation(self.item.?.list) orelse
                            return evaluator.fail(.domain, "definition body has an invalid heap representation"),
                        .visibility = visibility,
                        .effect = self.annotation.effect.?,
                        .doc = self.annotation.doc_value,
                    } } else .{ .value = .{ .item = self.item.?, .visibility = visibility } })
                else
                    try self.scope.publishTopCursor(name, if (word_binding) .{ .word = .{
                        .body = env.quotation(self.item.?.list) orelse
                            return evaluator.fail(.domain, "definition body has an invalid heap representation"),
                        .effect = self.annotation.effect,
                        .doc = self.annotation.doc_value,
                    } } else .{ .value = self.item.? });
                switch (self.publisher.?.advance() catch |err| switch (err) {
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

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *DefineDriver) void {
        if (self.normalizer) |*normalizer| normalizer.retire(releases);
        if (self.effect_materializer) |*materializer| materializer.retire(releases);
        if (self.qualified) |*qualified| qualified.deinit();
        if (self.publisher) |*publisher| publisher.deinit();
        if (self.effect_items) |items| allocator.free(items);
        self.annotation.deinit(releases);
        if (self.annotation_source) |item| releases.releaseValue(item);
        if (self.item) |item| releases.releaseValue(item);
        allocator.destroy(self);
    }
};

fn body(evaluator: *Machine) MachineError!void {
    const requested = try popSymbol(evaluator);
    return installLookup(evaluator, requested, .body);
}

fn doc(evaluator: *Machine) MachineError!void {
    const requested = try popSymbol(evaluator);
    return installLookup(evaluator, requested, .doc);
}

const LookupMode = enum { body, doc };
fn installLookup(evaluator: *Machine, requested: u32, mode: LookupMode) MachineError!void {
    const driver = try evaluator.allocator().create(LookupDriver);
    driver.* = .{ .requested = requested, .mode = mode, .resolution = .init(evaluator, requested) };
    evaluator.installWorkDriver(driver);
}
const LookupDriver = struct {
    requested: u32,
    mode: LookupMode,
    resolution: machine.ResolutionCursor,
    pub fn advance(evaluator: *Machine, self: *LookupDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.resolution.advance()) {
            .pending => {},
            .complete => |maybe_resolved| {
                var resolved = maybe_resolved orelse return evaluator.undefinedName(self.requested);
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
    pub fn destroy(_: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *LookupDriver) void {
        self.resolution.deinit();
        allocator.destroy(self);
    }
};

fn which(evaluator: *Machine) MachineError!void {
    const requested = try popSymbol(evaluator);
    const driver = try evaluator.allocator().create(WhichDriver);
    driver.* = .{
        .requested = requested,
        .resolution = .init(evaluator, requested),
    };
    evaluator.installWorkDriver(driver);
}

const WhichDriver = struct {
    requested: u32,
    resolution: ?machine.ResolutionCursor,
    shadow_cursor: ?machine.ShadowCursor = null,
    resolved: ?machine.Resolution = null,
    shadows: ?[]u32 = null,
    actions: ?[]reflection.Action = null,
    initialized: bool = false,
    shadow_index: usize = 0,
    action_index: usize = 0,
    plan: ?reflection.OwnedPlanCursor = null,
    rendered: ?[]u8 = null,

    fn add(self: *WhichDriver, action: reflection.Action) void {
        self.actions.?[self.action_index] = action;
        self.action_index += 1;
    }
    fn initialize(self: *WhichDriver) void {
        self.add(.{ .name = self.requested });
        self.add(.{ .bytes = " -> " });
        self.add(.{ .name = self.resolved.?.trace_word });
        self.add(.{ .bytes = " " });
        self.add(.{ .bytes = switch (self.resolved.?.lease.binding) {
            .word => "def",
            .value => "set",
            .primitive, .builtin => "primitive",
        } });
        self.add(.{ .bytes = " " });
        self.add(.{ .bytes = @tagName(self.resolved.?.lease.visibility) });
        if (self.resolved.?.home) |home| {
            self.add(.{ .bytes = " generation " });
            self.add(.{ .value = .{ .int = @intCast(home.generationNumber()) } });
        }
        if (self.resolved.?.lease.effect) |effect| {
            self.add(.{ .bytes = " " });
            self.add(.{ .value = .{ .list = effect.header() } });
        }
        self.initialized = true;
    }
    pub fn advance(evaluator: *Machine, self: *WhichDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.resolved == null) {
            var budget: usize = machine.kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.resolution.?.advance()) {
                .pending => {},
                .complete => |maybe_resolved| {
                    self.resolved = maybe_resolved orelse return evaluator.undefinedName(self.requested);
                    self.resolution.?.deinit();
                    self.resolution = null;
                    self.shadow_cursor = .init(evaluator, self.requested);
                    return .yielded;
                },
            };
            return .yielded;
        }
        if (self.shadows == null) {
            var budget: usize = machine.kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (try self.shadow_cursor.?.advance()) {
                .pending => {},
                .complete => |shadows| {
                    self.shadows = shadows;
                    self.shadow_cursor.?.deinit();
                    self.shadow_cursor = null;
                    const fixed_count: usize = 8 +
                        @as(usize, @intFromBool(self.resolved.?.home != null)) * 2 +
                        @as(usize, @intFromBool(self.resolved.?.lease.effect != null)) * 2;
                    self.actions = try evaluator.allocator().alloc(
                        reflection.Action,
                        fixed_count + shadows.len * 2,
                    );
                    break;
                },
            };
            if (self.shadows == null) return .yielded;
        }
        if (!self.initialized) self.initialize();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0 and self.shadow_index != self.shadows.?.len) : (budget -= 1) {
            self.add(.{ .bytes = "; shadows " });
            self.add(.{ .name = self.shadows.?[self.shadow_index] });
            self.shadow_index += 1;
        }
        if (self.shadow_index != self.shadows.?.len) return .yielded;
        if (self.plan == null) {
            self.add(.{ .bytes = "\n" });
            std.debug.assert(self.action_index == self.actions.?.len);
            self.plan = .init(evaluator.allocator(), self.actions.?);
        }
        if (self.rendered == null) switch (try self.plan.?.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |bytes| self.rendered = bytes,
        };
        if (evaluator.unit.console) |console| {
            console.writeOutput(self.rendered.?, false) catch return writeFailure(evaluator);
            return .completed;
        }
        const output = try outputWriter(evaluator);
        output.writeAll(self.rendered.?) catch return writeFailure(evaluator);
        output.flush() catch return evaluator.fail(.io, "standard output flush failed");
        return .completed;
    }
    pub fn destroy(_: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *WhichDriver) void {
        if (self.resolution) |*cursor| cursor.deinit();
        if (self.shadow_cursor) |*cursor| cursor.deinit();
        if (self.plan) |*plan| plan.deinit();
        if (self.rendered) |rendered| allocator.free(rendered);
        if (self.actions) |actions| allocator.free(actions);
        if (self.shadows) |shadows| allocator.free(shadows);
        if (self.resolved) |*resolved| resolved.deinit(allocator);
        allocator.destroy(self);
    }
};

fn see(evaluator: *Machine) MachineError!void {
    const requested = try popSymbol(evaluator);
    const driver = try evaluator.allocator().create(SeeDriver);
    driver.* = .{ .requested = requested, .resolution = .init(evaluator, requested) };
    evaluator.installWorkDriver(driver);
}

const SeeDriver = struct {
    requested: u32,
    resolution: ?machine.ResolutionCursor,
    resolved: ?machine.Resolution = null,
    annotation_items: ?[]Value = null,
    annotation_index: usize = 0,
    annotation_materializer: ?kernel_storage.ValueMaterializer = null,
    annotation: ?Value = null,
    actions: [8]reflection.Action = .{reflection.Action{ .bytes = "" }} ** 8,
    action_count: usize = 0,
    plan: ?reflection.OwnedPlanCursor = null,
    rendered: ?[]u8 = null,

    fn add(self: *SeeDriver, action: reflection.Action) void {
        self.actions[self.action_count] = action;
        self.action_count += 1;
    }

    fn buildPlan(self: *SeeDriver, allocator: std.mem.Allocator) void {
        switch (self.resolved.?.lease.binding) {
            .word => |source| self.add(.{ .value = .{ .list = env.quotationHeader(source) } }),
            .value => |item| self.add(.{ .value = item }),
            .primitive, .builtin => self.add(.{ .bytes = "<primitive>" }),
        }
        if (self.annotation) |annotation| {
            self.add(.{ .bytes = " " });
            self.add(.{ .value = annotation });
        } else if (self.resolved.?.lease.effect) |effect| {
            self.add(.{ .bytes = " " });
            self.add(.{ .value = .{ .list = effect.header() } });
        }
        self.add(.{ .bytes = " '" });
        self.add(.{ .name = self.resolved.?.trace_word });
        self.add(.{ .bytes = switch (self.resolved.?.lease.binding) {
            .value => if (self.resolved.?.lease.visibility == .private) " setp\n" else " set\n",
            .word => if (self.resolved.?.lease.visibility == .private) " defp\n" else " def\n",
            .primitive, .builtin => " def\n",
        } });
        self.plan = .init(allocator, self.actions[0..self.action_count]);
    }

    pub fn advance(evaluator: *Machine, self: *SeeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.resolved == null) {
            var budget: usize = machine.kernel_poll_quantum;
            while (budget != 0) : (budget -= 1) switch (self.resolution.?.advance()) {
                .pending => {},
                .complete => |maybe_resolved| {
                    self.resolved = maybe_resolved orelse return evaluator.undefinedName(self.requested);
                    self.resolution.?.deinit();
                    self.resolution = null;
                    break;
                },
            };
            if (self.resolved == null) return .yielded;
        }
        const document = self.resolved.?.lease.doc;
        if (self.plan == null and document != null) {
            const effect_count: usize = if (self.resolved.?.lease.effect) |effect|
                @intCast(effect.header().length())
            else
                0;
            if (self.annotation_items == null) self.annotation_items = try evaluator.allocator().alloc(
                Value,
                effect_count + 2,
            );
            const end = @min(
                self.annotation_index + machine.kernel_poll_quantum,
                effect_count,
            );
            while (self.annotation_index != end) : (self.annotation_index += 1) {
                self.annotation_items.?[self.annotation_index] = list.atUnchecked(
                    .{ .list = self.resolved.?.lease.effect.?.header() },
                    self.annotation_index,
                );
            }
            if (self.annotation_index != effect_count) return .yielded;
            self.annotation_items.?[effect_count] = .{ .word = try intern.intern(":") };
            self.annotation_items.?[effect_count + 1] = .{
                .list = env.documentationHeader(document.?),
            };
            if (self.annotation_materializer == null) self.annotation_materializer = .init(
                evaluator.allocator(),
                self.annotation_items.?,
            );
            switch (try self.annotation_materializer.?.advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |annotation| {
                    self.annotation_materializer.?.deinit();
                    self.annotation_materializer = null;
                    self.annotation = annotation;
                    self.buildPlan(evaluator.allocator());
                    return .yielded;
                },
            }
        }
        if (self.plan == null) self.buildPlan(evaluator.allocator());
        if (self.rendered == null) switch (try self.plan.?.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            .complete => |bytes| self.rendered = bytes,
        };
        if (evaluator.unit.console) |console| {
            console.writeOutput(self.rendered.?, false) catch return writeFailure(evaluator);
            return .completed;
        }
        const output = try outputWriter(evaluator);
        output.writeAll(self.rendered.?) catch return writeFailure(evaluator);
        output.flush() catch return evaluator.fail(.io, "standard output flush failed");
        return .completed;
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *SeeDriver) void {
        if (self.resolution) |*cursor| cursor.deinit();
        if (self.annotation_materializer) |*materializer| materializer.retire(releases);
        if (self.plan) |*plan| plan.deinit();
        if (self.rendered) |rendered| allocator.free(rendered);
        if (self.annotation) |annotation| releases.releaseValue(annotation);
        if (self.annotation_items) |items| allocator.free(items);
        if (self.resolved) |*resolved| resolved.deinit(allocator);
        allocator.destroy(self);
    }
};

fn popSymbol(evaluator: *Machine) MachineError!u32 {
    var item = try evaluator.popValue();
    defer item.deinit();
    return switch (item.borrow()) {
        .symbol => |id| id,
        else => evaluator.typeError("a symbol name"),
    };
}

fn outputWriter(evaluator: *Machine) MachineError!*std.Io.Writer {
    return evaluator.unit.output orelse return evaluator.fail(.io, "standard output is unavailable");
}

fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}
