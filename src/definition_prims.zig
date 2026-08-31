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
const reflection = @import("reflection.zig");
const formatter = @import("formatter.zig");
const doc_text = @import("doc.zig");
const reader_types = @import("reader_types.zig");
const modules = @import("modules.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Mode = enum { def, defp, test_declaration };
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
        .{ .name = "test", .primitive = bind(.test_declaration) },
        .{ .name = "unset", .primitive = unbind },
        .{ .name = "undef", .primitive = unbind },
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
    if (private and scope.publisher() != .module)
        return evaluator.fail(.domain, "defp/setp are legal only in a module root");
    const name = try evaluator.popSymbol();
    var item = try evaluator.popValue();
    defer item.deinit();
    const separator = try intern.intern("--");
    const colon = try intern.intern(":");
    var annotation_candidate: ?heap.Owned(Value) = null;
    if (item.borrow() == .list and evaluator.available() != 0) {
        const candidate = evaluator.visibleOperandBorrowed(evaluator.available() - 1);
        if (candidate == .list) {
            heap.retainValue(candidate);
            annotation_candidate = .init(candidate);
        }
    }
    try evaluator.startDriver(DefineDriver{
        .mode = mode,
        .scope = scope,
        .name = name,
        .item = .init(item.take()),
        .separator = separator,
        .colon = colon,
        .annotation = .init(.{}),
        .state = .init(if (annotation_candidate) |*candidate| .{ .scan_annotation = .{
            .candidate = .init(candidate.take()),
        } } else .{ .validate_name = .init(name) }),
    });
}

fn unbind(evaluator: *Machine) MachineError!void {
    const name = try evaluator.popSymbol();
    try evaluator.startDriver(UnbindDriver{
        .scope = evaluator.currentScope(),
        .state = .init(.{ .validate_name = .init(name) }),
    });
}

const UnbindDriver = struct {
    scope: *env.Scope,
    state: heap.Owned(State),

    const State = union(enum) {
        validate_name: intern.NamespaceCursor,
        unpublishing: heap.Owned(env.Scope.UnpublishCursor),

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .validate_name => {},
                .unpublishing => |*cursor| cursor.deinit(releases, allocator),
            }
        }
    };

    pub fn advance(evaluator: *Machine, self: *UnbindDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.state.borrowMut().*) {
            .validate_name => |*validation| switch (validation.advance()) {
                .pending => {},
                .complete => |maybe_name| {
                    const name = maybe_name orelse return evaluator.fail(
                        .domain,
                        "unset/undef requires an unqualified, non-reserved name",
                    );
                    self.state.borrowMut().* = .{ .unpublishing = .init(
                        self.scope.unpublishWordCursor(name),
                    ) };
                },
            },
            .unpublishing => |*cursor| switch (cursor.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Frozen => return evaluator.fail(
                    .domain,
                    "module environments are immutable after registration",
                ),
            }) {
                .pending => {},
                .complete => return .completed,
            },
        };
        return .yielded;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const DefineDriver = struct {
    mode: Mode,
    scope: *env.Scope,
    name: u32,
    item: heap.Owned(Value),
    separator: u32,
    colon: u32,
    annotation: heap.Owned(Annotation),
    state: heap.Owned(State),

    const AnnotationScan = struct {
        candidate: heap.Owned(Value),
        index: usize = 0,
        separator_at: ?usize = null,
        colon_at: ?usize = null,
    };
    const AnnotationContext = struct {
        source: heap.Owned(Value),
        separator_at: ?usize,
        effect_end: usize,
    };
    const State = union(enum) {
        scan_annotation: AnnotationScan,
        validate_annotation: struct {
            context: AnnotationContext,
            document: ?Value,
            index: usize = 0,
        },
        normalize_doc: struct {
            context: AnnotationContext,
            normalizer: heap.Owned(doc_text.NormalizeCursor),
        },
        prepare_effect: AnnotationContext,
        copy_effect: struct {
            context: AnnotationContext,
            items: heap.Owned([]Value),
            index: usize = 0,
        },
        materialize_effect: struct {
            context: AnnotationContext,
            items: heap.Owned([]Value),
            materializer: heap.Owned(list.ValueMaterializer),
        },
        validate_name: intern.NamespaceCursor,
        source: struct {
            binding_name: intern.BindingName,
            cursor: @import("spans.zig").SpanArchive.SourceCursor,
        },
        prepare_publish: struct {
            binding_name: intern.BindingName,
            source: ?heap.Owned(reader_types.SourceSlice),
        },
        publishing: struct {
            source: ?heap.Owned(reader_types.SourceSlice),
            publisher: heap.Owned(env.Environment.BindCursor),
        },
        publishing_test: modules.TestDeclarationCursor,

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .scan_annotation => |*scan| scan.candidate.deinit(releases, allocator),
                .validate_annotation => |*validation| validation.context.source.deinit(releases, allocator),
                .normalize_doc => |*normalization| {
                    normalization.normalizer.deinit(releases, allocator);
                    normalization.context.source.deinit(releases, allocator);
                },
                .prepare_effect => |*context| context.source.deinit(releases, allocator),
                .copy_effect => |*copy| {
                    copy.items.deinit(releases, allocator);
                    copy.context.source.deinit(releases, allocator);
                },
                .materialize_effect => |*materialization| {
                    materialization.materializer.deinit(releases, allocator);
                    materialization.items.deinit(releases, allocator);
                    materialization.context.source.deinit(releases, allocator);
                },
                .prepare_publish => |*publication| {
                    if (publication.source) |*source| source.deinit(releases, allocator);
                },
                .publishing => |*publication| {
                    publication.publisher.deinit(releases, allocator);
                    if (publication.source) |*source| source.deinit(releases, allocator);
                },
                .validate_name, .source, .publishing_test => {},
            }
        }
    };

    fn malformed(evaluator: *Machine) MachineError {
        return evaluator.fail(.domain, "malformed definition annotation");
    }

    pub fn advance(evaluator: *Machine, self: *DefineDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.state.borrowMut().*) {
            .scan_annotation => |*scan| {
                const count: usize = @intCast(scan.candidate.borrow().list.length());
                if (scan.index == count) {
                    if (scan.separator_at == null and scan.colon_at == null) {
                        scan.candidate.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        self.state.borrowMut().* = .{ .validate_name = .init(self.name) };
                        continue;
                    }
                    if (scan.separator_at != null and scan.colon_at != null and
                        scan.separator_at.? > scan.colon_at.?) return malformed(evaluator);
                    const effect_end = scan.colon_at orelse count;
                    if (scan.separator_at == null and scan.colon_at.? != 0)
                        return malformed(evaluator);
                    const document = if (scan.colon_at) |doc_at| document: {
                        if (count != doc_at + 2) return malformed(evaluator);
                        const value_at = list.atUnchecked(scan.candidate.borrow(), doc_at + 1);
                        if (!value_at.isString()) return malformed(evaluator);
                        break :document value_at;
                    } else null;
                    evaluator.discard(1);
                    const source = scan.candidate.take();
                    self.state.borrowMut().* = .{ .validate_annotation = .{
                        .context = .{
                            .source = .init(source),
                            .separator_at = scan.separator_at,
                            .effect_end = effect_end,
                        },
                        .document = document,
                    } };
                    continue;
                }
                const item = list.atUnchecked(scan.candidate.borrow(), scan.index);
                if (item == .word and item.word.name == self.separator) {
                    if (scan.separator_at != null) return malformed(evaluator);
                    scan.separator_at = scan.index;
                } else if (item == .word and item.word.name == self.colon) {
                    if (scan.colon_at != null) return malformed(evaluator);
                    scan.colon_at = scan.index;
                }
                scan.index += 1;
                budget -= 1;
            },
            .validate_annotation => |*validation| {
                if (validation.context.separator_at) |split| {
                    if (validation.index != validation.context.effect_end) {
                        const slot = list.atUnchecked(
                            validation.context.source.borrow(),
                            validation.index,
                        );
                        if (validation.index != split and slot != .word)
                            return malformed(evaluator);
                        // The after portion is all named slots or exactly the
                        // row token; the before portion never names a row.
                        if (slot == .word and
                            std.mem.eql(u8, intern.get(slot.word.name), lexer.row_token) and
                            (validation.index <= split or validation.context.effect_end != split + 2))
                            return malformed(evaluator);
                        validation.index += 1;
                        budget -= 1;
                        continue;
                    }
                }
                if (validation.document) |document| {
                    const normalizer = try doc_text.NormalizeCursor.init(evaluator.allocator(), document);
                    const context = validation.context;
                    self.state.borrowMut().* = .{ .normalize_doc = .{
                        .context = context,
                        .normalizer = .init(normalizer),
                    } };
                } else if (validation.context.separator_at != null) {
                    const context = validation.context;
                    self.state.borrowMut().* = .{ .prepare_effect = context };
                } else {
                    validation.context.source.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    self.state.borrowMut().* = .{ .validate_name = .init(self.name) };
                }
            },
            .normalize_doc => |*normalization| switch (try normalization.normalizer.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => |normalized| {
                    self.annotation.borrowMut().doc_source = normalized;
                    self.annotation.borrowMut().doc_value = env.documentation(normalized.list) orelse
                        return malformed(evaluator);
                    normalization.normalizer.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    if (normalization.context.separator_at != null) {
                        const context = normalization.context;
                        self.state.borrowMut().* = .{ .prepare_effect = context };
                    } else {
                        normalization.context.source.deinit(
                            evaluator.releaseDomain(),
                            evaluator.allocator(),
                        );
                        self.state.borrowMut().* = .{ .validate_name = .init(self.name) };
                    }
                    return .yielded;
                },
            },
            .prepare_effect => |*context| {
                const items = try evaluator.allocator().alloc(Value, context.effect_end);
                const moved = context.*;
                self.state.borrowMut().* = .{ .copy_effect = .{
                    .context = moved,
                    .items = .init(items),
                } };
            },
            .copy_effect => |*copy| {
                if (copy.index == copy.context.effect_end) {
                    const materializer = list.ValueMaterializer.init(
                        evaluator.allocator(),
                        copy.items.borrow(),
                    );
                    const context = copy.context;
                    const items = copy.items.take();
                    self.state.borrowMut().* = .{ .materialize_effect = .{
                        .context = context,
                        .items = .init(items),
                        .materializer = .init(materializer),
                    } };
                    continue;
                }
                copy.items.borrow()[copy.index] = list.atUnchecked(
                    copy.context.source.borrow(),
                    copy.index,
                );
                copy.index += 1;
                budget -= 1;
            },
            .materialize_effect => |*materialization| switch (try materialization.materializer.borrowMut().advance(budget)) {
                .pending => return .yielded,
                .complete => |effect_value| {
                    self.annotation.borrowMut().effect_value = effect_value;
                    self.annotation.borrowMut().effect = env.ValidatedEffect.fromValidated(
                        effect_value.list,
                        materialization.context.separator_at.?,
                    );
                    materialization.materializer.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    materialization.items.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    materialization.context.source.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    self.state.borrowMut().* = .{ .validate_name = .init(self.name) };
                    return .yielded;
                },
            },
            .validate_name => |*validation| {
                switch (validation.advance()) {
                    .pending => {
                        budget -= 1;
                        continue;
                    },
                    .complete => |name| {
                        const binding_name = name orelse return evaluator.fail(
                            .domain,
                            if (self.mode == .test_declaration)
                                "test requires an unqualified, non-reserved name"
                            else
                                "def/set requires an unqualified, non-reserved name",
                        );
                        if (self.item.borrow() != .list)
                            return evaluator.fail(
                                .type,
                                if (self.mode == .test_declaration)
                                    "test expected a list body"
                                else
                                    "def expected a list body; use set for values",
                            );
                        self.state.borrowMut().* = .{ .source = .{
                            .binding_name = binding_name,
                            .cursor = evaluator.sourceCursor(self.item.borrow().list),
                        } };
                    },
                }
            },
            .source => |*source_state| switch (source_state.cursor.advance()) {
                .pending => budget -= 1,
                .complete => |source| {
                    // A module definition records only its own name. The
                    // qualified spelling belongs to whichever registration a call
                    // reaches it through, so there is nothing to intern here.
                    self.state.borrowMut().* = .{ .prepare_publish = .{
                        .binding_name = source_state.binding_name,
                        .source = if (source) |owned_source| .init(owned_source) else null,
                    } };
                },
            },
            .prepare_publish => |*publication| {
                if (self.mode == .test_declaration) {
                    const cursor = try evaluator.testDeclarationCursor(
                        publication.binding_name,
                        env.quotation(self.item.borrow().list) orelse
                            return evaluator.fail(.domain, "test body has an invalid heap representation"),
                        self.annotation.borrow().effect,
                        self.annotation.borrow().doc_value,
                    );
                    if (publication.source) |*source| source.deinit(
                        evaluator.releaseDomain(),
                        evaluator.allocator(),
                    );
                    self.state.borrowMut().* = .{ .publishing_test = cursor };
                    continue;
                }
                const private = self.mode == .defp;
                const visibility: env.Visibility = if (private) .private else .public;
                const publisher = try self.scope.publishWordCursor(publication.binding_name, .{
                    .body = env.quotation(self.item.borrow().list) orelse
                        return evaluator.fail(.domain, "definition body has an invalid heap representation"),
                    .source = if (publication.source) |*source| source.borrow() else null,
                    .visibility = visibility,
                    .effect = self.annotation.borrow().effect,
                    .doc = self.annotation.borrow().doc_value,
                });
                const source: ?heap.Owned(reader_types.SourceSlice) =
                    if (publication.source) |*owned| .init(owned.take()) else null;
                self.state.borrowMut().* = .{ .publishing = .{
                    .source = source,
                    .publisher = .init(publisher),
                } };
            },
            .publishing => |*publication| {
                switch (publication.publisher.borrowMut().advance() catch |err| switch (err) {
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
            .publishing_test => |*cursor| {
                switch (cursor.advance() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.DuplicateTest => return evaluator.fail(.domain, "duplicate test name in module"),
                    error.Frozen => return evaluator.fail(
                        .domain,
                        "module test catalogs are immutable after registration",
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

fn doc(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    return installLookup(evaluator, requested);
}

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
        .unresolved => |chain| evaluator.undefinedNameIn(requested, chain),
        .unknown_module_prefix, .unregistered_module => {
            evaluator.retireDriver(driver);
            return .{ .retry = try evaluator.retryQualifiedOperandAfterLoad(requested, outcome) };
        },
    };
}

/// Documentation is the only reflection that yields a value. There is no
/// counterpart for a binding's stored body: nothing lifts a published body out
/// of the home it resolves against, which is what keeps a quotation's scope
/// label impossible to re-site.
fn installLookup(evaluator: *Machine, requested: u32) MachineError!void {
    try evaluator.startDriver(LookupDriver{
        .requested = requested,
        .resolution = .init(machine.ResolutionCursor.initAtCurrent(evaluator, requested)),
    });
}
const LookupDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    requested: u32,
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
                try evaluator.pushBorrowed(.{ .list = env.documentationHeader(
                    resolved.lease.doc orelse return evaluator.fail(.domain, "binding has no documentation"),
                ) });
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
    actions: heap.Owned(reflection.ActionPlan),
    state: heap.Owned(State),

    const OwnedContext = struct {
        resolved: heap.Owned(machine.Resolution),
        shadows: heap.Owned([]intern.TraceWord),

        fn deinit(
            self: *OwnedContext,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            self.shadows.deinit(releases, allocator);
            self.resolved.deinit(releases, allocator);
        }
    };
    const State = union(enum) {
        resolve: heap.Owned(machine.ResolutionCursor),
        shadow: struct {
            resolved: heap.Owned(machine.Resolution),
            cursor: heap.Owned(machine.ShadowCursor),
        },
        base_actions: struct {
            context: OwnedContext,
            step: u8,
            requirement_index: usize,
            requirement_separator: bool,
        },
        shadow_actions: struct {
            context: OwnedContext,
            index: usize,
            emit_name: bool,
        },
        render: OwnedContext,
        write: struct {
            context: OwnedContext,
            rendered: heap.Owned([]u8),
        },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .resolve => |*cursor| cursor.deinit(releases, allocator),
                .shadow => |*shadow| {
                    shadow.cursor.deinit(releases, allocator);
                    shadow.resolved.deinit(releases, allocator);
                },
                .base_actions => |*base| base.context.deinit(releases, allocator),
                .shadow_actions => |*shadows| shadows.context.deinit(releases, allocator),
                .render => |*context| context.deinit(releases, allocator),
                .write => |*write| {
                    write.rendered.deinit(releases, allocator);
                    write.context.deinit(releases, allocator);
                },
            }
        }
    };

    fn init(evaluator: *Machine, requested: u32) WhichDriver {
        return .{
            .requested = requested,
            .actions = .init(reflection.ActionPlan.init(evaluator.allocator())),
            .state = .init(.{ .resolve = .init(
                machine.ResolutionCursor.initAtCurrent(evaluator, requested),
            ) }),
        };
    }
    fn add(self: *WhichDriver, action: reflection.Action) error{OutOfMemory}!void {
        try self.actions.borrowMut().add(action);
    }
    fn advanceBaseActions(
        self: *WhichDriver,
        base: *@FieldType(State, "base_actions"),
    ) error{OutOfMemory}!void {
        const resolved = base.context.resolved.borrow();
        switch (base.step) {
            0 => try self.add(.{ .name = self.requested }),
            1 => try self.add(.{ .bytes = " -> " }),
            2 => try self.add(.{ .trace_word = resolved.trace_word }),
            3 => try self.add(.{ .bytes = " " }),
            4 => try self.add(.{ .bytes = switch (resolved.lease.binding) {
                .word => "def",
                .builtin => "primitive",
                .native => "native",
            } }),
            5 => try self.add(.{ .bytes = " " }),
            6 => try self.add(.{ .bytes = @tagName(resolved.lease.visibility) }),
            7 => if (resolved.home != null)
                try self.add(.{ .bytes = " generation " }),
            8 => if (resolved.home) |home|
                try self.add(.{ .value = .{ .int = @intCast(home.generationNumber()) } }),
            9 => if (resolved.lease.effect != null) try self.add(.{ .bytes = " " }),
            10 => if (resolved.lease.effect) |effect|
                try self.add(.{ .value = .{ .list = effect.header() } }),
            11 => switch (resolved.lease.binding) {
                .native => try self.add(.{ .bytes = " requires " }),
                else => {},
            },
            12 => {
                const requirements = switch (resolved.lease.binding) {
                    .native => |callable| callable.instance.requirements(),
                    else => &.{},
                };
                if (base.requirement_index == requirements.len) {
                    const context = base.context;
                    self.state.borrowMut().* = .{ .shadow_actions = .{
                        .context = context,
                        .index = 0,
                        .emit_name = false,
                    } };
                    return;
                }
                if (base.requirement_index != 0 and !base.requirement_separator) {
                    try self.add(.{ .bytes = ", " });
                    base.requirement_separator = true;
                    return;
                }
                try self.add(.{ .bytes = native_module.capabilityName(
                    requirements[base.requirement_index].id,
                ) });
                base.requirement_index += 1;
                base.requirement_separator = false;
                return;
            },
            else => unreachable,
        }
        base.step += 1;
    }
    pub fn advance(evaluator: *Machine, self: *WhichDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.state.borrowMut().*) {
            .resolve => |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |outcome| {
                    const resolved = switch (try resolveForReflection(
                        evaluator,
                        self,
                        self.requested,
                        outcome,
                    )) {
                        .retry => |progress| return progress,
                        .resolved => |resolution| resolution,
                    };
                    cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .shadow = .{
                        .resolved = .init(resolved),
                        .cursor = .init(machine.ShadowCursor.init(evaluator, self.requested)),
                    } };
                },
            },
            .shadow => |*shadow| switch (try shadow.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |shadows| {
                    const resolved = shadow.resolved.take();
                    shadow.cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .base_actions = .{
                        .context = .{
                            .resolved = .init(resolved),
                            .shadows = .init(shadows),
                        },
                        .step = 0,
                        .requirement_index = 0,
                        .requirement_separator = false,
                    } };
                },
            },
            .base_actions => |*base| try self.advanceBaseActions(base),
            .shadow_actions => |*shadows| {
                if (shadows.index == shadows.context.shadows.borrow().len) {
                    try self.add(.{ .bytes = "\n" });
                    self.actions.borrowMut().seal();
                    const context = shadows.context;
                    self.state.borrowMut().* = .{ .render = context };
                } else if (!shadows.emit_name) {
                    try self.add(.{ .bytes = "; shadows " });
                    shadows.emit_name = true;
                } else {
                    try self.add(.{ .trace_word = shadows.context.shadows.borrow()[shadows.index] });
                    shadows.index += 1;
                    shadows.emit_name = false;
                }
            },
            .render => |*context| switch (try self.actions.borrowMut().advance(1)) {
                .pending => {},
                .complete => |bytes| {
                    const moved = context.*;
                    self.state.borrowMut().* = .{ .write = .{
                        .context = moved,
                        .rendered = .init(bytes),
                    } };
                },
            },
            .write => |*write| {
                if (evaluator.unit.inherited.console) |console| {
                    console.writeOutput(write.rendered.borrow(), false) catch return writeFailure(evaluator);
                    return .completed;
                }
                const output = try outputWriter(evaluator);
                output.writeAll(write.rendered.borrow()) catch return writeFailure(evaluator);
                output.flush() catch return evaluator.fail(.io, "standard output flush failed");
                return .completed;
            },
        };
        return .yielded;
    }
};

fn see(evaluator: *Machine) MachineError!void {
    const requested = try evaluator.popSymbol();
    try evaluator.startDriver(SeeDriver.init(evaluator, requested));
}

const SeeDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    requested: u32,
    actions: heap.Owned(reflection.ActionPlan),
    state: heap.Owned(State),

    const Context = struct {
        resolved: heap.Owned(machine.Resolution),
        annotation: ?heap.Owned(Value),

        fn deinit(
            self: *Context,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            if (self.annotation) |*annotation| annotation.deinit(releases, allocator);
            self.resolved.deinit(releases, allocator);
        }
    };
    const AnnotationBuild = struct {
        resolved: heap.Owned(machine.Resolution),
        items: heap.Owned([]Value),
        effect_count: usize,
        index: usize,
    };
    const State = union(enum) {
        resolve: heap.Owned(machine.ResolutionCursor),
        annotation_allocate: heap.Owned(machine.Resolution),
        annotation_copy: AnnotationBuild,
        annotation_materialize: struct {
            resolved: heap.Owned(machine.Resolution),
            items: heap.Owned([]Value),
            materializer: heap.Owned(list.ValueMaterializer),
        },
        plan: struct {
            context: Context,
            step: u8,
            requirement_index: usize,
            requirement_separator: bool,
        },
        render: Context,
        format: struct { context: Context, source: heap.Owned([]u8) },
        write: struct { context: Context, rendered: heap.Owned([]u8) },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .resolve => |*cursor| cursor.deinit(releases, allocator),
                .annotation_allocate => |*resolved| resolved.deinit(releases, allocator),
                .annotation_copy => |*annotation| {
                    annotation.items.deinit(releases, allocator);
                    annotation.resolved.deinit(releases, allocator);
                },
                .annotation_materialize => |*annotation| {
                    annotation.materializer.deinit(releases, allocator);
                    annotation.items.deinit(releases, allocator);
                    annotation.resolved.deinit(releases, allocator);
                },
                .plan => |*plan| plan.context.deinit(releases, allocator),
                .render => |*context| context.deinit(releases, allocator),
                .format => |*format_state| {
                    format_state.source.deinit(releases, allocator);
                    format_state.context.deinit(releases, allocator);
                },
                .write => |*write| {
                    write.rendered.deinit(releases, allocator);
                    write.context.deinit(releases, allocator);
                },
            }
        }
    };

    fn init(evaluator: *Machine, requested: u32) SeeDriver {
        return .{
            .requested = requested,
            .actions = .init(reflection.ActionPlan.init(evaluator.allocator())),
            .state = .init(.{ .resolve = .init(
                machine.ResolutionCursor.initAtCurrent(evaluator, requested),
            ) }),
        };
    }
    fn add(self: *SeeDriver, action: reflection.Action) error{OutOfMemory}!void {
        try self.actions.borrowMut().add(action);
    }

    fn advancePlan(
        self: *SeeDriver,
        plan: *@FieldType(State, "plan"),
    ) error{OutOfMemory}!void {
        const resolved = plan.context.resolved.borrow();
        switch (plan.step) {
            0 => if (plan.context.annotation) |*annotation|
                try self.add(.{ .value = annotation.borrow() })
            else if (resolved.lease.effect) |effect|
                try self.add(.{ .value = .{ .list = effect.header() } }),
            1 => if (plan.context.annotation != null or resolved.lease.effect != null)
                try self.add(.{ .bytes = " " }),
            2 => switch (resolved.lease.binding) {
                .word => |word_body| if (resolved.lease.source) |source|
                    try self.add(.{ .bytes = source.bytes() })
                else
                    try self.add(.{ .value = .{ .list = env.quotationHeader(word_body) } }),
                .builtin => try self.add(.{ .bytes = "<primitive>" }),
                .native => try self.add(.{ .bytes = "<native:" }),
            },
            3 => switch (resolved.lease.binding) {
                .native => try self.add(.{ .trace_word = resolved.trace_word }),
                else => {},
            },
            4 => switch (resolved.lease.binding) {
                .native => try self.add(.{ .bytes = ">" }),
                else => {},
            },
            5 => switch (resolved.lease.binding) {
                .native => try self.add(.{ .bytes = " requires " }),
                else => {},
            },
            6 => {
                const requirements = switch (resolved.lease.binding) {
                    .native => |callable| callable.instance.requirements(),
                    else => &.{},
                };
                if (plan.requirement_index != requirements.len) {
                    if (plan.requirement_index != 0 and !plan.requirement_separator) {
                        try self.add(.{ .bytes = ", " });
                        plan.requirement_separator = true;
                        return;
                    }
                    try self.add(.{ .bytes = native_module.capabilityName(
                        requirements[plan.requirement_index].id,
                    ) });
                    plan.requirement_index += 1;
                    plan.requirement_separator = false;
                    return;
                }
            },
            7 => {
                self.actions.borrowMut().seal();
                const context = plan.context;
                self.state.borrowMut().* = .{ .render = context };
                return;
            },
            else => unreachable,
        }
        plan.step += 1;
    }

    pub fn advance(evaluator: *Machine, self: *SeeDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) : (budget -= 1) switch (self.state.borrowMut().*) {
            .resolve => |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |outcome| {
                    const resolved = switch (try resolveForReflection(
                        evaluator,
                        self,
                        self.requested,
                        outcome,
                    )) {
                        .retry => |progress| return progress,
                        .resolved => |resolution| resolution,
                    };
                    cursor.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = if (resolved.lease.doc != null)
                        .{ .annotation_allocate = .init(resolved) }
                    else
                        .{ .plan = .{
                            .context = .{ .resolved = .init(resolved), .annotation = null },
                            .step = 0,
                            .requirement_index = 0,
                            .requirement_separator = false,
                        } };
                },
            },
            .annotation_allocate => |*resolved| {
                const effect_count: usize = if (resolved.borrow().lease.effect) |effect|
                    @intCast(effect.header().length())
                else
                    0;
                const items = try evaluator.allocator().alloc(Value, effect_count + 2);
                self.state.borrowMut().* = .{ .annotation_copy = .{
                    .resolved = .init(resolved.take()),
                    .items = .init(items),
                    .effect_count = effect_count,
                    .index = 0,
                } };
            },
            .annotation_copy => |*annotation| {
                if (annotation.index != annotation.effect_count) {
                    annotation.items.borrow()[annotation.index] = list.atUnchecked(
                        .{ .list = annotation.resolved.borrow().lease.effect.?.header() },
                        annotation.index,
                    );
                    annotation.index += 1;
                    continue;
                }
                annotation.items.borrow()[annotation.effect_count] = .{ .word = .{ .name = try intern.intern(":") } };
                annotation.items.borrow()[annotation.effect_count + 1] = .{
                    .list = env.documentationHeader(annotation.resolved.borrow().lease.doc.?),
                };
                const materializer = list.ValueMaterializer.init(
                    evaluator.allocator(),
                    annotation.items.borrow(),
                );
                self.state.borrowMut().* = .{ .annotation_materialize = .{
                    .resolved = .init(annotation.resolved.take()),
                    .items = .init(annotation.items.take()),
                    .materializer = .init(materializer),
                } };
            },
            .annotation_materialize => |*annotation| switch (try annotation.materializer.borrowMut().advance(1)) {
                .pending => return .yielded,
                .complete => |annotation_value| {
                    const resolved = annotation.resolved.take();
                    annotation.materializer.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    annotation.items.deinit(evaluator.releaseDomain(), evaluator.allocator());
                    self.state.borrowMut().* = .{ .plan = .{
                        .context = .{
                            .resolved = .init(resolved),
                            .annotation = .init(annotation_value),
                        },
                        .step = 0,
                        .requirement_index = 0,
                        .requirement_separator = false,
                    } };
                },
            },
            .plan => |*plan| try self.advancePlan(plan),
            .render => |*context| switch (try self.actions.borrowMut().advance(1)) {
                .pending => {},
                .complete => |source| {
                    const moved = context.*;
                    self.state.borrowMut().* = .{ .format = .{
                        .context = moved,
                        .source = .init(source),
                    } };
                },
            },
            .format => |*format_state| {
                const rendered = formatter.format(
                    evaluator.allocator(),
                    format_state.source.borrow(),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // The reflection plan emits only reader-valid canonical
                    // values and fixed binding descriptors. Failure here is an
                    // internal disagreement between those two production
                    // boundaries, not a user program error.
                    error.InvalidUtf8, error.InvalidSource => unreachable,
                };
                const context = format_state.context;
                format_state.source.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state.borrowMut().* = .{ .write = .{
                    .context = context,
                    .rendered = .init(rendered),
                } };
            },
            .write => |*write| {
                if (evaluator.unit.inherited.console) |console| {
                    console.writeOutput(write.rendered.borrow(), false) catch return writeFailure(evaluator);
                    return .completed;
                }
                const output = try outputWriter(evaluator);
                output.writeAll(write.rendered.borrow()) catch return writeFailure(evaluator);
                output.flush() catch return evaluator.fail(.io, "standard output flush failed");
                return .completed;
            },
        };
        return .yielded;
    }
};

fn outputWriter(evaluator: *Machine) MachineError!*std.Io.Writer {
    return evaluator.unit.output orelse return evaluator.fail(.io, "standard output is unavailable");
}

fn writeFailure(evaluator: *Machine) MachineError {
    return evaluator.fail(.io, "standard output write failed");
}
