//! Inline control and isolated quotation-taking combinators.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;
const Header = value.ListHandle;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Application = machine.IsolatedApplication;
const ApplicationStep = machine.ApplicationStep;
const StackWindow = machine.StackWindow;
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "call", .primitive = call },
        .{ .name = "if", .primitive = ifWord },
        .{ .name = "while", .primitive = whileWord },
        .{ .name = "times", .primitive = times },
        .{ .name = "cond", .primitive = cond },
        .{ .name = "each", .primitive = each },
        .{ .name = "zip-with", .primitive = zipWith },
        .{ .name = "for", .primitive = forWord },
        .{ .name = "fold", .primitive = fold },
        .{ .name = "scan", .primitive = scan },
        .{ .name = "infra", .primitive = infra },
    };
    try core.installBuiltins(definitions);
}

fn call(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    try evaluator.callOwned(quotation.take().list);
}

fn ifWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var otherwise = try evaluator.popValue();
    defer otherwise.deinit();
    var then = try evaluator.popValue();
    defer then.deinit();
    var predicate = try evaluator.popValue();
    defer predicate.deinit();
    if (then.borrow() != .list or otherwise.borrow() != .list)
        return evaluator.typeError("two quotation branches");
    const selected_then = try boolValue(evaluator, &predicate);
    try evaluator.callOwned(if (selected_then) then.take().list else otherwise.take().list);
}

fn whileWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var body = try evaluator.popValue();
    defer body.deinit();
    var condition = try evaluator.popValue();
    defer condition.deinit();
    if (body.borrow() != .list or condition.borrow() != .list)
        return evaluator.typeError("two quotations/lists");
    const first_condition = condition.borrow().list;
    var checkpoint = try GuardCheckpoint.init(evaluator);
    try evaluator.startDriver(GuardSnapshotDriver{
        .control = .init(.{
            .checkpoint = .init(checkpoint.take()),
            .selector = .{ .while_loop = .{
                .condition = .init(condition.take().list),
                .body = .init(body.take().list),
            } },
            .parent = evaluator.currentScope(),
            .home = evaluator.currentHome(),
            .word = evaluator.activeWordId(),
        }),
        .target = .{ .predicate = first_condition },
    });
}

const TimesState = struct {
    quotation: heap.Owned(*Header),
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    remaining: usize,
    word: intern.TraceWord,

    fn application(self: *TimesState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.parent, self.home, 0);
    }
    fn step(self: *TimesState) ApplicationStep {
        return .{ .quotation = self.quotation.borrow(), .seeded = 0 };
    }

    pub fn resumeApplication(evaluator: *Machine, self: *TimesState, _: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        self.remaining -= 1;
        return if (self.remaining == 0) null else self.step();
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn times(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    if (quotation.borrow() != .list or count_value.borrow() != .int)
        return evaluator.typeError("a nonnegative int and quotation");
    if (count_value.borrow().int < 0)
        return evaluator.fail(.domain, "times requires a nonnegative count");
    if (count_value.borrow().int == 0) return;
    const state = try evaluator.allocator().create(TimesState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .remaining = @intCast(count_value.borrow().int),
        .word = evaluator.activeWordId(),
    };
    try evaluator.beginInlineApplication(state.application());
}

/// The private callback behind `dip` recognition. The prelude definition
/// `(swap literal compose call)` stays authoritative; matching it lets the
/// protected value ride in a continuation instead of building a capture
/// quotation and a composition on every application.
pub fn dipForIdiom(evaluator: *Machine) MachineError!void {
    std.debug.assert(evaluator.available() >= 2);
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var protected = try evaluator.popValue();
    defer protected.deinit();
    const state = try evaluator.allocator().create(DipState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .protected = .init(protected.take()),
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .word = evaluator.activeWordId(),
    };
    const word = state.word;
    try evaluator.beginInlineApplication(state.application());
    evaluator.setApplicationTraceParent(word);
}

const DipState = struct {
    quotation: heap.Owned(*Header),
    protected: heap.Owned(Value),
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    word: intern.TraceWord,

    fn application(self: *DipState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.parent, self.home, 0);
    }

    /// The protected value returns exactly once, after the quotation's own
    /// application completes, so a failing quotation leaves it to this
    /// driver's field ownership rather than to the rolled-back stack.
    pub fn resumeApplication(evaluator: *Machine, self: *DipState, _: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        try evaluator.pushOwned(self.protected.take());
        return null;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const GuardTarget = union(enum) {
    predicate: *Header,
    action: *Header,
    done,
};

const GuardCheckpoint = struct {
    values: heap.OwnedValueBuffer,
    depth: usize,
    index: usize = 0,
    phase: enum { capture, ready, discard, reserve, restore } = .capture,

    fn init(evaluator: *Machine) error{OutOfMemory}!heap.Owned(GuardCheckpoint) {
        const depth = evaluator.available();
        return .init(.{
            .values = try .init(evaluator.releaseDomain(), depth),
            .depth = depth,
        });
    }
    fn take(self: *GuardCheckpoint) GuardCheckpoint {
        return .{
            .values = self.values.take(),
            .depth = self.depth,
            .index = self.index,
            .phase = self.phase,
        };
    }
    fn advanceCapture(self: *GuardCheckpoint, evaluator: *Machine, budget: usize) bool {
        std.debug.assert(self.phase == .capture and evaluator.available() == self.depth);
        const end = @min(self.index + budget, self.depth);
        while (self.index != end) : (self.index += 1)
            self.values.appendBorrowed(evaluator.visibleOperandBorrowed(self.index));
        if (self.index != self.depth) return false;
        self.phase = .ready;
        return true;
    }
    fn beginRestore(self: *GuardCheckpoint) void {
        std.debug.assert(self.phase == .ready);
        self.phase = .discard;
        self.index = 0;
    }
    fn advanceRestore(
        self: *GuardCheckpoint,
        evaluator: *Machine,
        budget: usize,
    ) error{OutOfMemory}!bool {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) switch (self.phase) {
            .discard => if (evaluator.available() != 0) {
                evaluator.discard(1);
            } else {
                self.phase = .reserve;
            },
            .reserve => {
                _ = try evaluator.reserveStack(self.depth);
                self.phase = .restore;
            },
            .restore => if (self.index != self.depth) {
                try evaluator.pushBorrowed(self.values.values()[self.index]);
                self.index += 1;
            } else {
                self.phase = .ready;
                return true;
            },
            .capture, .ready => unreachable,
        };
        return false;
    }
    pub fn retire(self: *GuardCheckpoint, _: *heap.ReleaseDomain) void {
        self.values.deinit();
    }
};

const GuardControl = struct {
    checkpoint: heap.Owned(GuardCheckpoint),
    selector: union(enum) {
        cond: struct {
            clauses: heap.Owned(Value),
            pair_index: usize = 0,
        },
        while_loop: struct {
            condition: heap.Owned(*Header),
            body: heap.Owned(*Header),
        },
    },
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    word: intern.TraceWord,

    fn selectedTarget(self: *GuardControl, selected: bool) GuardTarget {
        return switch (self.selector) {
            .cond => |*state| if (selected)
                .{ .action = list.atUnchecked(state.clauses.borrow(), state.pair_index + 1).list }
            else next: {
                state.pair_index += 2;
                const count: usize = @intCast(state.clauses.borrow().list.length());
                if (state.pair_index + 1 >= count)
                    break :next .{ .action = list.atUnchecked(state.clauses.borrow(), count - 1).list };
                break :next .{ .predicate = list.atUnchecked(state.clauses.borrow(), state.pair_index).list };
            },
            .while_loop => |*state| if (selected)
                .{ .action = state.body.borrow() }
            else
                .done,
        };
    }
    fn afterAction(self: *GuardControl) ?*Header {
        return switch (self.selector) {
            .cond => null,
            .while_loop => |*state| state.condition.borrow(),
        };
    }
    pub fn retire(
        self: *GuardControl,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        self.checkpoint.deinit(releases, allocator);
        switch (self.selector) {
            .cond => |*state| state.clauses.deinit(releases, allocator),
            .while_loop => |*state| {
                state.body.deinit(releases, allocator);
                state.condition.deinit(releases, allocator);
            },
        }
    }
};

fn beginGuardTarget(
    evaluator: *Machine,
    control: *heap.Owned(GuardControl),
    target: GuardTarget,
) MachineError!void {
    switch (target) {
        .predicate => |quotation| {
            const state = try evaluator.allocator().create(GuardPredicateState);
            state.* = .{ .control = .init(control.take()) };
            try evaluator.beginInlineApplication(state.application(quotation));
        },
        .action => |quotation| {
            const state = try evaluator.allocator().create(GuardActionState);
            state.* = .{ .control = .init(control.take()) };
            try evaluator.beginInlineApplication(state.application(quotation));
        },
        .done => unreachable,
    }
}

const GuardSnapshotDriver = struct {
    control: heap.Owned(GuardControl),
    target: GuardTarget,

    pub fn advance(evaluator: *Machine, self: *GuardSnapshotDriver) MachineError!machine.WorkProgress {
        evaluator.setActiveWord(self.control.borrow().word);
        try evaluator.pollKernel();
        if (!self.control.borrowMut().checkpoint.borrowMut().advanceCapture(
            evaluator,
            machine.kernel_poll_quantum,
        )) return .yielded;
        var control = heap.Owned(GuardControl).init(self.control.take());
        defer control.deinit(evaluator.releaseDomain(), evaluator.allocator());
        const target = self.target;
        evaluator.retireDriver(self);
        try beginGuardTarget(evaluator, &control, target);
        return .detached;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

const GuardRestoreDriver = struct {
    control: heap.Owned(GuardControl),
    target: GuardTarget,

    pub fn advance(evaluator: *Machine, self: *GuardRestoreDriver) MachineError!machine.WorkProgress {
        evaluator.setActiveWord(self.control.borrow().word);
        try evaluator.pollKernel();
        if (!try self.control.borrowMut().checkpoint.borrowMut().advanceRestore(
            evaluator,
            machine.kernel_poll_quantum,
        )) return .yielded;
        var control = heap.Owned(GuardControl).init(self.control.take());
        defer control.deinit(evaluator.releaseDomain(), evaluator.allocator());
        const target = self.target;
        evaluator.retireDriver(self);
        if (target != .done) try beginGuardTarget(evaluator, &control, target);
        return .detached;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

const GuardPredicateState = struct {
    control: heap.Owned(GuardControl),

    fn application(self: *GuardPredicateState, quotation: *Header) Application {
        const control = self.control.borrow();
        return machine.typedApplication(self, quotation, control.parent, control.home, 0);
    }
    pub fn resumeApplication(
        evaluator: *Machine,
        self: *GuardPredicateState,
        _: StackWindow,
    ) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.control.borrow().word);
        var predicate = try evaluator.popValue();
        defer predicate.deinit();
        const target = self.control.borrowMut().selectedTarget(try boolValue(evaluator, &predicate));
        self.control.borrowMut().checkpoint.borrowMut().beginRestore();
        try evaluator.startDriver(GuardRestoreDriver{
            .control = .init(self.control.take()),
            .target = target,
        });
        return null;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

const GuardActionState = struct {
    control: heap.Owned(GuardControl),

    fn application(self: *GuardActionState, quotation: *Header) Application {
        const control = self.control.borrow();
        return machine.typedApplication(self, quotation, control.parent, control.home, 0);
    }
    pub fn resumeApplication(
        evaluator: *Machine,
        self: *GuardActionState,
        _: StackWindow,
    ) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.control.borrow().word);
        const condition = self.control.borrowMut().afterAction() orelse return null;
        var checkpoint = try GuardCheckpoint.init(evaluator);
        self.control.borrowMut().checkpoint.deinit(evaluator.releaseDomain(), evaluator.allocator());
        self.control.borrowMut().checkpoint = .init(checkpoint.take());
        try evaluator.startDriver(GuardSnapshotDriver{
            .control = .init(self.control.take()),
            .target = .{ .predicate = condition },
        });
        return null;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

fn cond(evaluator: *Machine) MachineError!void {
    var clauses = try evaluator.popValue();
    defer clauses.deinit();
    if (clauses.borrow() != .list) {
        return evaluator.typeError("a clause list");
    }
    const count: usize = @intCast(clauses.borrow().list.length());
    if (count == 0 or count % 2 == 0) {
        return evaluator.fail(.shape, "cond requires a nonempty odd clause list ending in else");
    }
    try evaluator.startDriver(CondDriver{
        .clauses = .init(clauses.take()),
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .word = evaluator.activeWordId(),
    });
}

const CondDriver = struct {
    clauses: heap.Owned(Value),
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    word: intern.TraceWord,
    index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *CondDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const clauses = self.clauses.borrow();
        const count: usize = @intCast(clauses.list.length());
        const end = @min(self.index + machine.kernel_poll_quantum, count);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(clauses, self.index) != .list)
                return evaluator.typeError("quotation clauses and else");
        }
        if (self.index != count) return .yielded;
        var checkpoint = try GuardCheckpoint.init(evaluator);
        const first: GuardTarget = if (count == 1)
            .{ .action = list.atUnchecked(clauses, 0).list }
        else
            .{ .predicate = list.atUnchecked(clauses, 0).list };
        const control = GuardControl{
            .checkpoint = .init(checkpoint.take()),
            .selector = .{ .cond = .{ .clauses = .init(self.clauses.take()) } },
            .parent = self.parent,
            .home = self.home,
            .word = self.word,
        };
        evaluator.retireDriver(self);
        try evaluator.startDriver(GuardSnapshotDriver{
            .control = .init(control),
            .target = first,
        });
        return .detached;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const IterationKind = enum { each, zip_with, for_word, fold, scan, infra };
const IterationState = struct {
    kind: IterationKind,
    left: heap.Owned(Value),
    right: ?heap.Owned(Value),
    quotation: heap.Owned(*Header),
    expected: ?heap.Owned(Value),
    results: ?heap.Owned(heap.OwnedValueBuffer) = null,
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    index: usize = 0,
    count: usize,
    word: intern.TraceWord,

    fn application(self: *IterationState, seeded: u32) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.parent, self.home, seeded);
    }
    fn step(self: *IterationState, seeded: u32) ApplicationStep {
        return .{ .quotation = self.quotation.borrow(), .seeded = seeded };
    }

    pub fn resumeApplication(evaluator: *Machine, self: *IterationState, window: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        const base: usize = window.base();
        const observed = window.observed(evaluator.unit.stack.items.len) orelse
            return evaluator.applicationContractError(self.expected.?.borrow(), 0, 0, self.index);
        return switch (self.kind) {
            .each, .zip_with => self.resumeCollect(evaluator, observed),
            .for_word => self.resumeFor(evaluator, observed),
            .fold, .scan => self.resumeFold(evaluator, observed),
            .infra => resumeInfra(evaluator, base),
        };
    }

    fn resumeCollect(self: *IterationState, evaluator: *Machine, observed: usize) MachineError!?ApplicationStep {
        const seeded: usize = if (self.kind == .each) 1 else 2;
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected.?.borrow(), seeded, observed, self.index);
        }
        var result = try evaluator.popValue();
        self.results.?.borrowMut().appendOwned(result.take());
        self.index += 1;
        if (self.index == self.count) {
            try self.installCollected(evaluator);
            return null;
        }
        try self.pushInputs(evaluator);
        return self.step(@intCast(seeded));
    }

    fn resumeFor(self: *IterationState, evaluator: *Machine, observed: usize) MachineError!?ApplicationStep {
        if (observed != 0) {
            return evaluator.applicationContractError(self.expected.?.borrow(), 1, observed, self.index);
        }
        self.index += 1;
        if (self.index == self.count) return null;
        try self.pushInputs(evaluator);
        return self.step(1);
    }

    fn resumeFold(self: *IterationState, evaluator: *Machine, observed: usize) MachineError!?ApplicationStep {
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected.?.borrow(), 2, observed, self.index);
        }
        var accumulator = try evaluator.popValue();
        defer accumulator.deinit();
        const accumulator_value = accumulator.borrow();
        if (self.kind == .scan) self.results.?.borrowMut().appendOwned(accumulator.take());
        self.index += 1;
        if (self.index == self.count) {
            if (self.kind == .scan) {
                try self.installCollected(evaluator);
            } else {
                try evaluator.pushOwned(accumulator.take());
            }
            return null;
        }
        if (self.kind == .scan) {
            try evaluator.pushBorrowed(accumulator_value);
        } else {
            try evaluator.pushOwned(accumulator.take());
        }
        try evaluator.pushBorrowed(list.atUnchecked(self.left.borrow(), self.index));
        return self.step(2);
    }

    fn resumeInfra(evaluator: *Machine, base: usize) MachineError!?ApplicationStep {
        try InfraResultDriver.install(evaluator, base);
        return null;
    }

    fn installCollected(self: *IterationState, evaluator: *Machine) error{OutOfMemory}!void {
        const values = self.results.?.take();
        self.results = null;
        try evaluator.startDriver(CollectedDriver{
            .materializer = .init(.init(evaluator.allocator(), values.values())),
            .values = .init(values),
        });
    }

    fn pushInputs(self: *IterationState, evaluator: *Machine) MachineError!void {
        try evaluator.pushBorrowed(inputAt(self.left.borrow(), self.index));
        if (self.kind == .zip_with) try evaluator.pushBorrowed(inputAt(
            self.right.?.borrow(),
            self.index,
        ));
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const CollectedDriver = struct {
    values: heap.Owned(heap.OwnedValueBuffer),
    materializer: heap.Owned(storage.ValueMaterializer),
    result: ?heap.Owned(Value) = null,

    pub fn advance(evaluator: *Machine, self: *CollectedDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.result == null) {
            switch (try self.materializer.borrowMut().advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |result| {
                    self.result = .init(result);
                    return .yielded;
                },
            }
        }
        self.values.deinit(evaluator.releaseDomain(), evaluator.allocator());
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const InfraResultDriver = struct {
    base: usize,
    materializer: heap.Owned(storage.ValueMaterializer),
    result: ?heap.Owned(Value) = null,

    fn install(evaluator: *Machine, base: usize) error{OutOfMemory}!void {
        try evaluator.startDriver(InfraResultDriver{
            .base = base,
            .materializer = .init(.init(evaluator.allocator(), evaluator.unit.stack.items[base..])),
        });
    }

    pub fn advance(evaluator: *Machine, self: *InfraResultDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.result == null) {
            switch (try self.materializer.borrowMut().advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |result| {
                    self.result = .init(result);
                    return .yielded;
                },
            }
        }
        var remaining = machine.kernel_poll_quantum;
        while (remaining != 0 and evaluator.unit.stack.items.len != self.base) : (remaining -= 1) {
            var discarded = try evaluator.popValue();
            discarded.deinit();
        }
        if (evaluator.unit.stack.items.len != self.base) return .yielded;
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const InfraBootstrapDriver = struct {
    iteration: heap.Owned(*IterationState),
    stack: machine.StackReservation,
    index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *InfraBootstrapDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const iteration = self.iteration.borrow();
        const end = @min(self.index + machine.kernel_poll_quantum, iteration.count);
        while (self.index != end) : (self.index += 1) {
            const item = list.atUnchecked(iteration.left.borrow(), self.index);
            self.stack.pushBorrowed(item);
        }
        if (self.index != iteration.count) return .yielded;
        std.debug.assert(self.stack.complete());
        const application = iteration.application(@intCast(iteration.count));
        _ = self.iteration.take();
        try evaluator.beginIsolatedApplication(application);
        return .completed;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn each(evaluator: *Machine) MachineError!void {
    return evaluator.continueWithIdiom(.each, statelessFallback(eachGeneric));
}
fn eachGeneric(evaluator: *Machine, _: ?*anyopaque) MachineError!void {
    return startUnaryIteration(evaluator, .each);
}

fn forWord(evaluator: *Machine) MachineError!void {
    return startUnaryIteration(evaluator, .for_word);
}

fn startUnaryIteration(evaluator: *Machine, kind: IterationKind) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return evaluator.typeError("a list and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    if (count == 0) {
        if (kind == .each) try pushGenericEmpty(evaluator);
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try effectValue(
            evaluator.allocator(),
            if (kind == .each) &.{ "a", "--", "b" } else &.{ "a", "--" },
        ),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        kind,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releaseDomain(), evaluator.allocator(), state);
    const state = state_owner.?;
    if (kind == .each) state.results = .init(try .init(evaluator.releaseDomain(), count));
    try state.pushInputs(evaluator);
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(1));
}

fn zipWith(evaluator: *Machine) MachineError!void {
    return evaluator.continueWithIdiom(.zip_with, statelessFallback(zipWithGeneric));
}
fn zipWithGeneric(evaluator: *Machine, _: ?*anyopaque) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const left_list = left.borrow() == .list;
    const right_list = right.borrow() == .list;
    if (!left_list and !right_list) return evaluator.typeError("at least one list");
    const count: usize = if (left_list)
        @intCast(left.borrow().list.length())
    else
        @intCast(right.borrow().list.length());
    if (left_list and right_list and left.borrow().list.length() != right.borrow().list.length()) {
        const left_len: usize = @intCast(left.borrow().list.length());
        const right_len: usize = @intCast(right.borrow().list.length());
        return evaluator.conformError(left_len, right_len);
    }
    if (count == 0) {
        try pushGenericEmpty(evaluator);
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try effectValue(evaluator.allocator(), &.{ "a", "b", "--", "c" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        .zip_with,
        &left,
        &right,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releaseDomain(), evaluator.allocator(), state);
    const state = state_owner.?;
    state.results = .init(try .init(evaluator.releaseDomain(), count));
    try state.pushInputs(evaluator);
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn fold(evaluator: *Machine) MachineError!void {
    return evaluator.continueWithIdiom(.fold, statelessFallback(foldGeneric));
}
fn foldGeneric(evaluator: *Machine, _: ?*anyopaque) MachineError!void {
    return startFold(evaluator, .fold);
}

fn scan(evaluator: *Machine) MachineError!void {
    return evaluator.continueWithIdiom(.scan, statelessFallback(scanGeneric));
}
fn scanGeneric(evaluator: *Machine, _: ?*anyopaque) MachineError!void {
    return startFold(evaluator, .scan);
}

fn statelessFallback(
    comptime run: *const fn (*Machine, ?*anyopaque) MachineError!void,
) machine.IdiomFallback {
    return .{ .run_fn = run, .deinit_fn = deinitStatelessFallback };
}
fn deinitStatelessFallback(_: *heap.ReleaseDomain, _: std.mem.Allocator, _: ?*anyopaque) void {}

fn startFold(evaluator: *Machine, kind: IterationKind) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var accumulator = try evaluator.popValue();
    defer accumulator.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return evaluator.typeError("a list, accumulator, and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    if (count == 0) {
        if (kind == .scan) {
            try pushGenericEmpty(evaluator);
        } else {
            try evaluator.pushOwned(accumulator.take());
        }
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try effectValue(evaluator.allocator(), &.{ "acc", "a", "--", "acc" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        kind,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releaseDomain(), evaluator.allocator(), state);
    const state = state_owner.?;
    if (kind == .scan) state.results = .init(try .init(evaluator.releaseDomain(), count));
    try evaluator.pushOwned(accumulator.take());
    try evaluator.pushBorrowed(list.atUnchecked(state.left.borrow(), 0));
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn infra(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return evaluator.typeError("a list and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    const state = try createIteration(evaluator, .infra, &input, null, &quotation, null, count);
    var state_owner: ?*IterationState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        evaluator.releaseDomain(),
        evaluator.allocator(),
        owned,
    );
    const stack = try evaluator.reserveStack(count);
    state_owner = null;
    try evaluator.startDriver(InfraBootstrapDriver{ .iteration = .init(state), .stack = stack });
}

fn createIteration(
    evaluator: *Machine,
    kind: IterationKind,
    left: *heap.OwnedValue,
    right: ?*heap.OwnedValue,
    quotation: *heap.OwnedValue,
    expected: ?*heap.OwnedValue,
    count: usize,
) error{OutOfMemory}!*IterationState {
    const state = try evaluator.allocator().create(IterationState);
    state.* = .{
        .kind = kind,
        .left = .init(left.take()),
        .right = if (right) |item| .init(item.take()) else null,
        .quotation = .init(quotation.take().list),
        .expected = if (expected) |item| .init(item.take()) else null,
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .count = count,
        .word = evaluator.activeWordId(),
    };
    return state;
}

fn inputAt(input: Value, index: usize) Value {
    return if (input == .list) list.atUnchecked(input, index) else input;
}

fn pushGenericEmpty(evaluator: *Machine) error{OutOfMemory}!void {
    try evaluator.pushOwned(try list.fromValuesGeneric(evaluator.allocator(), &.{}));
}

fn effectValue(allocator: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}!Value {
    const forms = try allocator.alloc(Value, names.len);
    defer allocator.free(forms);
    for (names, 0..) |name, index| forms[index] = .{ .word = try intern.intern(name) };
    return list.fromValuesGeneric(allocator, forms);
}

fn boolValue(evaluator: *Machine, item: *const heap.OwnedValue) MachineError!bool {
    return switch (item.borrow()) {
        .int => |integer| switch (integer) {
            0 => false,
            1 => true,
            else => evaluator.typeError("a 0/1 bool"),
        },
        .float, .char, .symbol, .word, .list, .dict, .task, .module => evaluator.typeError("a 0/1 bool"),
    };
}
