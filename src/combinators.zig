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
        .{ .name = "dip", .primitive = dip },
        .{ .name = "call", .primitive = call },
        .{ .name = "if", .primitive = ifWord },
        .{ .name = "while", .primitive = whileWord },
        .{ .name = "times", .primitive = times },
        .{ .name = "cond", .primitive = cond },
        .{ .name = "each", .primitive = each },
        .{ .name = "each2", .primitive = each2 },
        .{ .name = "for", .primitive = forWord },
        .{ .name = "fold", .primitive = fold },
        .{ .name = "scan", .primitive = scan },
        .{ .name = "infra", .primitive = infra },
    };
    try core.installBuiltins(definitions);
}

fn dip(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var protected = try evaluator.popValue();
    defer protected.deinit();
    try evaluator.dipOwned(try takeQuotation(evaluator, &quotation), protected.take());
}

fn call(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    try evaluator.callOwned(try takeQuotation(evaluator, &quotation));
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
    var expected = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try effectValue(evaluator.allocator(), &.{ "--", "bool" }),
    );
    defer expected.deinit();
    const state = try evaluator.allocator().create(WhileState);
    state.* = .{
        .condition = condition.take().list,
        .body = body.take().list,
        .expected = expected.take(),
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .word = evaluator.activeWordId(),
    };
    try evaluator.beginInlineApplication(state.application(state.condition));
}

const WhileState = struct {
    condition: *Header,
    body: *Header,
    expected: Value,
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    running_body: bool = false,
    word: u32,

    fn application(self: *WhileState, quotation: *Header) Application {
        return machine.typedApplication(self, quotation, self.parent, self.home, 0);
    }
    fn step(_: *WhileState, quotation: *Header) ApplicationStep {
        return .{ .quotation = quotation, .seeded = 0 };
    }

    pub fn resumeApplication(evaluator: *Machine, self: *WhileState, window: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        if (self.running_body) {
            self.running_body = false;
            return self.step(self.condition);
        }
        const observed = window.observed(evaluator.unit.stack.items.len) orelse {
            return evaluator.applicationContractError(self.expected, 0, 0, null);
        };
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected, 0, observed, null);
        }
        var predicate = try evaluator.popValue();
        defer predicate.deinit();
        if (!try boolValue(evaluator, &predicate)) return null;
        self.running_body = true;
        return self.step(self.body);
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *WhileState) void {
        releases.releaseHeader(self.condition);
        releases.releaseHeader(self.body);
        releases.releaseValue(self.expected);
        allocator.destroy(self);
    }
};

const TimesState = struct {
    quotation: *Header,
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    remaining: usize,
    word: u32,

    fn application(self: *TimesState) Application {
        return machine.typedApplication(self, self.quotation, self.parent, self.home, 0);
    }
    fn step(self: *TimesState) ApplicationStep {
        return .{ .quotation = self.quotation, .seeded = 0 };
    }

    pub fn resumeApplication(evaluator: *Machine, self: *TimesState, _: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        self.remaining -= 1;
        return if (self.remaining == 0) null else self.step();
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *TimesState) void {
        releases.releaseHeader(self.quotation);
        allocator.destroy(self);
    }
};

fn times(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
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
        .quotation = quotation.take().list,
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .remaining = @intCast(count_value.borrow().int),
        .word = evaluator.activeWordId(),
    };
    try evaluator.beginInlineApplication(state.application());
}

const CondState = struct {
    clauses: Value,
    expected: Value,
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    pair_index: usize = 0,
    running_action: bool = false,
    word: u32,

    fn application(self: *CondState, quotation: *Header) Application {
        return machine.typedApplication(self, quotation, self.parent, self.home, 0);
    }
    fn step(_: *CondState, quotation: *Header) ApplicationStep {
        return .{ .quotation = quotation, .seeded = 0 };
    }

    pub fn resumeApplication(evaluator: *Machine, self: *CondState, window: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        if (self.running_action) return null;
        const observed = window.observed(evaluator.unit.stack.items.len) orelse {
            return evaluator.applicationContractError(self.expected, 0, 0, self.pair_index / 2);
        };
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected, 0, observed, self.pair_index / 2);
        }
        var predicate = try evaluator.popValue();
        defer predicate.deinit();
        const selected = try boolValue(evaluator, &predicate);
        if (selected) {
            self.running_action = true;
            return self.step(list.atUnchecked(self.clauses, self.pair_index + 1).list);
        }
        self.pair_index += 2;
        const count: usize = @intCast(self.clauses.list.length());
        if (self.pair_index + 1 >= count) {
            self.running_action = true;
            return self.step(list.atUnchecked(self.clauses, count - 1).list);
        }
        return self.step(list.atUnchecked(self.clauses, self.pair_index).list);
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *CondState) void {
        releases.releaseValue(self.clauses);
        releases.releaseValue(self.expected);
        allocator.destroy(self);
    }
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
    const driver = try evaluator.allocator().create(CondDriver);
    driver.* = .{
        .clauses = clauses.take(),
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .word = evaluator.activeWordId(),
    };
    evaluator.installWorkDriver(driver);
}

const CondDriver = struct {
    clauses: ?Value,
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    word: u32,
    index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *CondDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const clauses = self.clauses.?;
        const count: usize = @intCast(clauses.list.length());
        const end = @min(self.index + machine.kernel_poll_quantum, count);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(clauses, self.index) != .list)
                return evaluator.typeError("quotation clauses and else");
        }
        if (self.index != count) return .yielded;
        var expected_value: ?Value = try effectValue(evaluator.allocator(), &.{ "--", "bool" });
        errdefer if (expected_value) |expected| evaluator.releaseDomain().releaseValue(expected);
        const state = try evaluator.allocator().create(CondState);
        state.* = .{
            .clauses = clauses,
            .expected = expected_value.?,
            .parent = self.parent,
            .home = self.home,
            .word = self.word,
        };
        expected_value = null;
        self.clauses = null;
        const first = if (count == 1) blk: {
            state.running_action = true;
            break :blk list.atUnchecked(clauses, 0).list;
        } else list.atUnchecked(clauses, 0).list;
        try evaluator.beginInlineApplication(state.application(first));
        return .completed;
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *CondDriver) void {
        if (self.clauses) |clauses| releases.releaseValue(clauses);
        allocator.destroy(self);
    }
};

const IterationKind = enum { each, each2, for_word, fold, scan, infra };
const IterationState = struct {
    kind: IterationKind,
    left: Value,
    right: ?Value,
    quotation: *Header,
    expected: ?Value,
    results: ?heap.OwnedValueBuffer = null,
    parent: *env.Scope,
    home: ?*modules.ModuleHome,
    index: usize = 0,
    count: usize,
    word: u32,

    fn application(self: *IterationState, seeded: u32) Application {
        return machine.typedApplication(self, self.quotation, self.parent, self.home, seeded);
    }
    fn step(self: *IterationState, seeded: u32) ApplicationStep {
        return .{ .quotation = self.quotation, .seeded = seeded };
    }

    pub fn resumeApplication(evaluator: *Machine, self: *IterationState, window: StackWindow) MachineError!?ApplicationStep {
        evaluator.setActiveWord(self.word);
        try evaluator.yieldNativeStep();
        const base: usize = window.base();
        const observed = window.observed(evaluator.unit.stack.items.len) orelse
            return evaluator.applicationContractError(self.expected.?, 0, 0, self.index);
        return switch (self.kind) {
            .each, .each2 => self.resumeCollect(evaluator, observed),
            .for_word => self.resumeFor(evaluator, observed),
            .fold, .scan => self.resumeFold(evaluator, observed),
            .infra => resumeInfra(evaluator, base),
        };
    }

    fn resumeCollect(self: *IterationState, evaluator: *Machine, observed: usize) MachineError!?ApplicationStep {
        const seeded: usize = if (self.kind == .each) 1 else 2;
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected.?, seeded, observed, self.index);
        }
        var result = try evaluator.popValue();
        self.results.?.appendOwned(result.take());
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
            return evaluator.applicationContractError(self.expected.?, 1, observed, self.index);
        }
        self.index += 1;
        if (self.index == self.count) return null;
        try self.pushInputs(evaluator);
        return self.step(1);
    }

    fn resumeFold(self: *IterationState, evaluator: *Machine, observed: usize) MachineError!?ApplicationStep {
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected.?, 2, observed, self.index);
        }
        var accumulator = try evaluator.popValue();
        defer accumulator.deinit();
        const accumulator_value = accumulator.borrow();
        if (self.kind == .scan) self.results.?.appendOwned(accumulator.take());
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
        try evaluator.pushBorrowed(list.atUnchecked(self.left, self.index));
        return self.step(2);
    }

    fn resumeInfra(evaluator: *Machine, base: usize) MachineError!?ApplicationStep {
        try InfraResultDriver.install(evaluator, base);
        return null;
    }

    fn installCollected(self: *IterationState, evaluator: *Machine) error{OutOfMemory}!void {
        const driver = try evaluator.allocator().create(CollectedDriver);
        var values = self.results.?.take();
        self.results = null;
        driver.* = .{
            .materializer = .init(evaluator.allocator(), values.values()),
            .values = values,
        };
        evaluator.installWorkDriver(driver);
    }

    fn pushInputs(self: *IterationState, evaluator: *Machine) MachineError!void {
        try evaluator.pushBorrowed(inputAt(self.left, self.index));
        if (self.kind == .each2) try evaluator.pushBorrowed(inputAt(self.right.?, self.index));
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *IterationState) void {
        releases.releaseValue(self.left);
        if (self.right) |right| releases.releaseValue(right);
        releases.releaseHeader(self.quotation);
        if (self.expected) |expected| releases.releaseValue(expected);
        if (self.results) |*results| results.deinit();
        allocator.destroy(self);
    }
};

const CollectedDriver = struct {
    values: heap.OwnedValueBuffer,
    materializer: storage.ValueMaterializer,
    result: ?Value = null,

    pub fn advance(evaluator: *Machine, self: *CollectedDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.result == null) {
            switch (try self.materializer.advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |result| {
                    self.result = result;
                    return .yielded;
                },
            }
        }
        self.values.deinit();
        const result = self.result.?;
        self.result = null;
        return .{ .output = result };
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *CollectedDriver) void {
        self.materializer.retire(releases);
        self.values.deinit();
        if (self.result) |result| releases.releaseValue(result);
        allocator.destroy(self);
    }
};

const InfraResultDriver = struct {
    base: usize,
    materializer: storage.ValueMaterializer,
    result: ?Value = null,

    fn install(evaluator: *Machine, base: usize) error{OutOfMemory}!void {
        const driver = try evaluator.allocator().create(InfraResultDriver);
        driver.* = .{
            .base = base,
            .materializer = .init(evaluator.allocator(), evaluator.unit.stack.items[base..]),
        };
        evaluator.installWorkDriver(driver);
    }

    pub fn advance(evaluator: *Machine, self: *InfraResultDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.result == null) {
            switch (try self.materializer.advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |result| {
                    self.result = result;
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
        const result = self.result.?;
        self.result = null;
        return .{ .output = result };
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *InfraResultDriver) void {
        self.materializer.retire(releases);
        if (self.result) |result| releases.releaseValue(result);
        allocator.destroy(self);
    }
};

const InfraBootstrapDriver = struct {
    iteration: ?*IterationState,
    stack: machine.StackReservation,
    index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *InfraBootstrapDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const iteration = self.iteration.?;
        const end = @min(self.index + machine.kernel_poll_quantum, iteration.count);
        while (self.index != end) : (self.index += 1) {
            const item = list.atUnchecked(iteration.left, self.index);
            self.stack.pushBorrowed(item);
        }
        if (self.index != iteration.count) return .yielded;
        std.debug.assert(self.stack.complete());
        const application = iteration.application(@intCast(iteration.count));
        self.iteration = null;
        try evaluator.beginIsolatedApplication(application);
        return .completed;
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *InfraBootstrapDriver) void {
        if (self.iteration) |iteration| IterationState.destroy(releases, allocator, iteration);
        allocator.destroy(self);
    }
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
    errdefer if (state_owner) |state| IterationState.destroy(evaluator.releaseDomain(), evaluator.allocator(), state);
    const state = state_owner.?;
    if (kind == .each) state.results = try .init(evaluator.releaseDomain(), count);
    try state.pushInputs(evaluator);
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(1));
}

fn each2(evaluator: *Machine) MachineError!void {
    return evaluator.continueWithIdiom(.each2, statelessFallback(each2Generic));
}
fn each2Generic(evaluator: *Machine, _: ?*anyopaque) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    if (quotation.borrow() != .list) return evaluator.typeError("a quotation/list");
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
        .each2,
        &left,
        &right,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| IterationState.destroy(evaluator.releaseDomain(), evaluator.allocator(), state);
    const state = state_owner.?;
    state.results = try .init(evaluator.releaseDomain(), count);
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
    errdefer if (state_owner) |state| IterationState.destroy(evaluator.releaseDomain(), evaluator.allocator(), state);
    const state = state_owner.?;
    if (kind == .scan) state.results = try .init(evaluator.releaseDomain(), count);
    try evaluator.pushOwned(accumulator.take());
    try evaluator.pushBorrowed(list.atUnchecked(state.left, 0));
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
    errdefer IterationState.destroy(evaluator.releaseDomain(), evaluator.allocator(), state);
    const stack = try evaluator.reserveStack(count);
    const driver = try evaluator.allocator().create(InfraBootstrapDriver);
    driver.* = .{ .iteration = state, .stack = stack };
    evaluator.installWorkDriver(driver);
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
        .left = left.take(),
        .right = if (right) |item| item.take() else null,
        .quotation = quotation.take().list,
        .expected = if (expected) |item| item.take() else null,
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
        .float, .char, .symbol, .word, .list, .dict, .task => evaluator.typeError("a 0/1 bool"),
    };
}

fn takeQuotation(evaluator: *Machine, item: *heap.OwnedValue) MachineError!*Header {
    if (item.borrow() != .list) return evaluator.typeError("a quotation/list");
    return item.take().list;
}
