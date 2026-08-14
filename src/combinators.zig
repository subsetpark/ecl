//! Inline control and isolated quotation-taking combinators.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");

const Value = value.Value;
const Header = value.Header;
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
    const quotation = try evaluator.popOwned();
    const protected = try evaluator.popOwned();
    const header = quotationHeader(evaluator, quotation) catch |err| {
        heap.releaseValue(evaluator.allocator(), protected);
        return err;
    };
    try evaluator.dipOwned(header, protected);
}

fn call(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    try evaluator.callOwned(try quotationHeader(evaluator, quotation));
}

fn ifWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    const otherwise = try evaluator.popOwned();
    const then = try evaluator.popOwned();
    const predicate = try evaluator.popOwned();
    if (then != .list or otherwise != .list) {
        releaseThree(evaluator.allocator(), predicate, then, otherwise);
        return evaluator.typeError("two quotation branches");
    }
    const selected_then = boolValue(evaluator, predicate) catch |err| {
        heap.releaseValue(evaluator.allocator(), then);
        heap.releaseValue(evaluator.allocator(), otherwise);
        return err;
    };
    const selected = if (selected_then) then else otherwise;
    heap.releaseValue(evaluator.allocator(), if (selected_then) otherwise else then);
    try evaluator.callOwned(selected.list);
}

fn whileWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const body = try evaluator.popOwned();
    const condition = try evaluator.popOwned();
    const body_header = quotationHeader(evaluator, body) catch |err| {
        heap.releaseValue(evaluator.allocator(), condition);
        return err;
    };
    const condition_header = quotationHeader(evaluator, condition) catch |err| {
        heap.decRef(evaluator.allocator(), body_header);
        return err;
    };
    const expected = effectValue(evaluator.allocator(), &.{ "--", "bool" }) catch {
        heap.decRef(evaluator.allocator(), condition_header);
        heap.decRef(evaluator.allocator(), body_header);
        return error.OutOfMemory;
    };
    const state = evaluator.allocator().create(WhileState) catch {
        heap.decRef(evaluator.allocator(), condition_header);
        heap.decRef(evaluator.allocator(), body_header);
        heap.releaseValue(evaluator.allocator(), expected);
        return error.OutOfMemory;
    };
    state.* = .{
        .condition = condition_header,
        .body = body_header,
        .expected = expected,
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .word = evaluator.activeWordId(),
    };
    try evaluator.beginInlineApplication(state.application(condition_header));
}

const WhileState = struct {
    condition: *Header,
    body: *Header,
    expected: Value,
    parent: *env.Scope,
    home: ?*modules.ModuleGeneration,
    running_body: bool = false,
    word: u32,

    fn application(self: *WhileState, quotation: *Header) Application {
        return .{
            .quotation = quotation,
            .context = self,
            .resume_fn = resumeApplication,
            .deinit_fn = destroy,
            .parent_scope = self.parent,
            .home = self.home,
            .seeded = 0,
        };
    }
    fn step(_: *WhileState, quotation: *Header) ApplicationStep {
        return .{ .quotation = quotation, .seeded = 0 };
    }

    fn resumeApplication(evaluator: *Machine, raw: *anyopaque, window: StackWindow) MachineError!?ApplicationStep {
        const self: *WhileState = @ptrCast(@alignCast(raw));
        evaluator.setActiveWord(self.word);
        try evaluator.advanceKernel(1);
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
        if (!try boolValue(evaluator, try evaluator.popOwned())) return null;
        self.running_body = true;
        return self.step(self.body);
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *WhileState = @ptrCast(@alignCast(raw));
        heap.decRef(allocator, self.condition);
        heap.decRef(allocator, self.body);
        heap.releaseValue(allocator, self.expected);
        allocator.destroy(self);
    }
};

const TimesState = struct {
    quotation: *Header,
    parent: *env.Scope,
    home: ?*modules.ModuleGeneration,
    remaining: usize,
    word: u32,

    fn application(self: *TimesState) Application {
        return .{
            .quotation = self.quotation,
            .context = self,
            .resume_fn = resumeApplication,
            .deinit_fn = destroy,
            .parent_scope = self.parent,
            .home = self.home,
            .seeded = 0,
        };
    }
    fn step(self: *TimesState) ApplicationStep {
        return .{ .quotation = self.quotation, .seeded = 0 };
    }

    fn resumeApplication(evaluator: *Machine, raw: *anyopaque, _: StackWindow) MachineError!?ApplicationStep {
        const self: *TimesState = @ptrCast(@alignCast(raw));
        evaluator.setActiveWord(self.word);
        try evaluator.advanceKernel(1);
        self.remaining -= 1;
        return if (self.remaining == 0) null else self.step();
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *TimesState = @ptrCast(@alignCast(raw));
        heap.decRef(allocator, self.quotation);
        allocator.destroy(self);
    }
};

fn times(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const quotation = try evaluator.popOwned();
    const count_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), count_value);
    const header = try quotationHeader(evaluator, quotation);
    if (count_value != .int) {
        heap.decRef(evaluator.allocator(), header);
        return evaluator.typeError("a nonnegative int");
    }
    if (count_value.int < 0) {
        heap.decRef(evaluator.allocator(), header);
        return evaluator.fail(.domain, "times requires a nonnegative count");
    }
    if (count_value.int == 0) {
        heap.decRef(evaluator.allocator(), header);
        return;
    }
    const state = evaluator.allocator().create(TimesState) catch {
        heap.decRef(evaluator.allocator(), header);
        return error.OutOfMemory;
    };
    state.* = .{
        .quotation = header,
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .remaining = @intCast(count_value.int),
        .word = evaluator.activeWordId(),
    };
    try evaluator.beginInlineApplication(state.application());
}

const CondState = struct {
    clauses: Value,
    expected: Value,
    parent: *env.Scope,
    home: ?*modules.ModuleGeneration,
    pair_index: usize = 0,
    running_action: bool = false,
    word: u32,

    fn application(self: *CondState, quotation: *Header) Application {
        return .{
            .quotation = quotation,
            .context = self,
            .resume_fn = resumeApplication,
            .deinit_fn = destroy,
            .parent_scope = self.parent,
            .home = self.home,
            .seeded = 0,
        };
    }
    fn step(_: *CondState, quotation: *Header) ApplicationStep {
        return .{ .quotation = quotation, .seeded = 0 };
    }

    fn resumeApplication(evaluator: *Machine, raw: *anyopaque, window: StackWindow) MachineError!?ApplicationStep {
        const self: *CondState = @ptrCast(@alignCast(raw));
        evaluator.setActiveWord(self.word);
        try evaluator.advanceKernel(1);
        if (self.running_action) return null;
        const observed = window.observed(evaluator.unit.stack.items.len) orelse {
            return evaluator.applicationContractError(self.expected, 0, 0, self.pair_index / 2);
        };
        if (observed != 1) {
            return evaluator.applicationContractError(self.expected, 0, observed, self.pair_index / 2);
        }
        const predicate = try evaluator.popOwned();
        const selected = try boolValue(evaluator, predicate);
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

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *CondState = @ptrCast(@alignCast(raw));
        heap.releaseValue(allocator, self.clauses);
        heap.releaseValue(allocator, self.expected);
        allocator.destroy(self);
    }
};

fn cond(evaluator: *Machine) MachineError!void {
    const clauses = try evaluator.popOwned();
    var clauses_owned = true;
    defer if (clauses_owned) heap.releaseValue(evaluator.allocator(), clauses);
    if (clauses != .list) {
        return evaluator.typeError("a clause list");
    }
    const count: usize = @intCast(clauses.list.length());
    if (count == 0 or count % 2 == 0) {
        return evaluator.fail(.shape, "cond requires a nonempty odd clause list ending in else");
    }
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        if (list.atUnchecked(clauses, index) != .list) {
            return evaluator.typeError("quotation clauses and else");
        }
    }
    const expected = effectValue(evaluator.allocator(), &.{ "--", "bool" }) catch {
        return error.OutOfMemory;
    };
    var expected_owned = true;
    defer if (expected_owned) heap.releaseValue(evaluator.allocator(), expected);
    const state = evaluator.allocator().create(CondState) catch {
        return error.OutOfMemory;
    };
    state.* = .{
        .clauses = clauses,
        .expected = expected,
        .parent = evaluator.currentScope(),
        .home = evaluator.currentHome(),
        .word = evaluator.activeWordId(),
    };
    clauses_owned = false;
    expected_owned = false;
    const first = if (count == 1) blk: {
        state.running_action = true;
        break :blk list.atUnchecked(clauses, 0).list;
    } else list.atUnchecked(clauses, 0).list;
    try evaluator.beginInlineApplication(state.application(first));
}

const IterationKind = enum { each, each2, for_word, fold, scan, infra };
const IterationState = struct {
    kind: IterationKind,
    left: Value,
    right: ?Value,
    quotation: *Header,
    expected: ?Value,
    results: std.ArrayList(Value) = .empty,
    parent: *env.Scope,
    home: ?*modules.ModuleGeneration,
    index: usize = 0,
    count: usize,
    word: u32,

    fn application(self: *IterationState, seeded: u32) Application {
        return .{
            .quotation = self.quotation,
            .context = self,
            .resume_fn = resumeApplication,
            .deinit_fn = destroy,
            .parent_scope = self.parent,
            .home = self.home,
            .seeded = seeded,
        };
    }
    fn step(self: *IterationState, seeded: u32) ApplicationStep {
        return .{ .quotation = self.quotation, .seeded = seeded };
    }

    fn resumeApplication(evaluator: *Machine, raw: *anyopaque, window: StackWindow) MachineError!?ApplicationStep {
        const self: *IterationState = @ptrCast(@alignCast(raw));
        evaluator.setActiveWord(self.word);
        try evaluator.advanceKernel(1);
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
        self.results.appendAssumeCapacity(evaluator.unit.stack.pop().?);
        self.index += 1;
        if (self.index == self.count) {
            try pushCollected(evaluator, self.results.items);
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
        const accumulator = evaluator.unit.stack.pop().?;
        if (self.kind == .scan) self.results.appendAssumeCapacity(accumulator);
        self.index += 1;
        if (self.index == self.count) {
            if (self.kind == .scan) {
                try pushCollected(evaluator, self.results.items);
            } else {
                try evaluator.pushOwned(accumulator);
            }
            return null;
        }
        if (self.kind == .scan) {
            try evaluator.pushBorrowed(accumulator);
        } else {
            try evaluator.pushOwned(accumulator);
        }
        try evaluator.pushBorrowed(list.atUnchecked(self.left, self.index));
        return self.step(2);
    }

    fn resumeInfra(evaluator: *Machine, base: usize) MachineError!?ApplicationStep {
        const result = try storage.fromValues(
            evaluator.allocator(),
            evaluator.unit.stack.items[base..],
            (support.Context{ .evaluator = evaluator }).structuralPoller(),
        );
        for (evaluator.unit.stack.items[base..]) |item| heap.releaseValue(evaluator.allocator(), item);
        evaluator.unit.stack.shrinkRetainingCapacity(base);
        try evaluator.pushOwned(result);
        return null;
    }

    fn pushInputs(self: *IterationState, evaluator: *Machine) MachineError!void {
        try evaluator.pushBorrowed(inputAt(self.left, self.index));
        if (self.kind == .each2) try evaluator.pushBorrowed(inputAt(self.right.?, self.index));
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *IterationState = @ptrCast(@alignCast(raw));
        heap.releaseValue(allocator, self.left);
        if (self.right) |right| heap.releaseValue(allocator, right);
        heap.decRef(allocator, self.quotation);
        if (self.expected) |expected| heap.releaseValue(allocator, expected);
        for (self.results.items) |item| heap.releaseValue(allocator, item);
        self.results.deinit(allocator);
        allocator.destroy(self);
    }
};

fn each(evaluator: *Machine) MachineError!void {
    if (try evaluator.tryIdiom(.each)) return;
    return startUnaryIteration(evaluator, .each);
}

fn forWord(evaluator: *Machine) MachineError!void {
    return startUnaryIteration(evaluator, .for_word);
}

fn startUnaryIteration(evaluator: *Machine, kind: IterationKind) MachineError!void {
    try evaluator.require(2);
    const quotation_value = try evaluator.popOwned();
    const input = try evaluator.popOwned();
    const quotation = quotationHeader(evaluator, quotation_value) catch |err| {
        heap.releaseValue(evaluator.allocator(), input);
        return err;
    };
    if (input != .list) {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        return evaluator.typeError("a list");
    }
    const count: usize = @intCast(input.list.length());
    if (count == 0) {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        if (kind == .each) try pushGenericEmpty(evaluator);
        return;
    }
    const expected = effectValue(
        evaluator.allocator(),
        if (kind == .each) &.{ "a", "--", "b" } else &.{ "a", "--" },
    ) catch {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        return error.OutOfMemory;
    };
    const state = try createIteration(evaluator, kind, input, null, quotation, expected, count);
    var state_owned = true;
    errdefer if (state_owned) IterationState.destroy(evaluator.allocator(), state);
    if (kind == .each) try state.results.ensureTotalCapacity(evaluator.allocator(), count);
    try state.pushInputs(evaluator);
    state_owned = false;
    try evaluator.beginIsolatedApplication(state.application(1));
}

fn each2(evaluator: *Machine) MachineError!void {
    if (try evaluator.tryIdiom(.each2)) return;
    try evaluator.require(3);
    const quotation_value = try evaluator.popOwned();
    const right = try evaluator.popOwned();
    const left = try evaluator.popOwned();
    const quotation = quotationHeader(evaluator, quotation_value) catch |err| {
        heap.releaseValue(evaluator.allocator(), left);
        heap.releaseValue(evaluator.allocator(), right);
        return err;
    };
    const left_list = left == .list;
    const right_list = right == .list;
    if (!left_list and !right_list) {
        releaseIterationInputs(evaluator.allocator(), quotation, left, right);
        return evaluator.typeError("at least one list");
    }
    const count: usize = if (left_list) @intCast(left.list.length()) else @intCast(right.list.length());
    if (left_list and right_list and left.list.length() != right.list.length()) {
        const left_len: usize = @intCast(left.list.length());
        const right_len: usize = @intCast(right.list.length());
        releaseIterationInputs(evaluator.allocator(), quotation, left, right);
        return evaluator.conformError(left_len, right_len);
    }
    if (count == 0) {
        releaseIterationInputs(evaluator.allocator(), quotation, left, right);
        try pushGenericEmpty(evaluator);
        return;
    }
    const expected = effectValue(evaluator.allocator(), &.{ "a", "b", "--", "c" }) catch {
        releaseIterationInputs(evaluator.allocator(), quotation, left, right);
        return error.OutOfMemory;
    };
    const state = try createIteration(evaluator, .each2, left, right, quotation, expected, count);
    var state_owned = true;
    errdefer if (state_owned) IterationState.destroy(evaluator.allocator(), state);
    try state.results.ensureTotalCapacity(evaluator.allocator(), count);
    try state.pushInputs(evaluator);
    state_owned = false;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn fold(evaluator: *Machine) MachineError!void {
    if (try evaluator.tryIdiom(.fold)) return;
    return startFold(evaluator, .fold);
}

fn scan(evaluator: *Machine) MachineError!void {
    if (try evaluator.tryIdiom(.scan)) return;
    return startFold(evaluator, .scan);
}

fn startFold(evaluator: *Machine, kind: IterationKind) MachineError!void {
    try evaluator.require(3);
    const quotation_value = try evaluator.popOwned();
    const accumulator = try evaluator.popOwned();
    var accumulator_owned = true;
    defer if (accumulator_owned) heap.releaseValue(evaluator.allocator(), accumulator);
    const input = try evaluator.popOwned();
    const quotation = quotationHeader(evaluator, quotation_value) catch |err| {
        heap.releaseValue(evaluator.allocator(), input);
        return err;
    };
    if (input != .list) {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        return evaluator.typeError("a list");
    }
    const count: usize = @intCast(input.list.length());
    if (count == 0) {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        if (kind == .scan) {
            try pushGenericEmpty(evaluator);
        } else {
            accumulator_owned = false;
            try evaluator.pushOwned(accumulator);
        }
        return;
    }
    const expected = effectValue(evaluator.allocator(), &.{ "acc", "a", "--", "acc" }) catch {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        return error.OutOfMemory;
    };
    const state = try createIteration(evaluator, kind, input, null, quotation, expected, count);
    var state_owned = true;
    errdefer if (state_owned) IterationState.destroy(evaluator.allocator(), state);
    if (kind == .scan) try state.results.ensureTotalCapacity(evaluator.allocator(), count);
    accumulator_owned = false;
    try evaluator.pushOwned(accumulator);
    try evaluator.pushBorrowed(list.atUnchecked(input, 0));
    state_owned = false;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn infra(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const quotation_value = try evaluator.popOwned();
    const input = try evaluator.popOwned();
    const quotation = quotationHeader(evaluator, quotation_value) catch |err| {
        heap.releaseValue(evaluator.allocator(), input);
        return err;
    };
    if (input != .list) {
        heap.decRef(evaluator.allocator(), quotation);
        heap.releaseValue(evaluator.allocator(), input);
        return evaluator.typeError("a list");
    }
    const count: usize = @intCast(input.list.length());
    const state = try createIteration(evaluator, .infra, input, null, quotation, null, count);
    var state_owned = true;
    errdefer if (state_owned) IterationState.destroy(evaluator.allocator(), state);
    for (0..count) |index| {
        try evaluator.advanceKernel(1);
        try evaluator.pushBorrowed(list.atUnchecked(input, index));
    }
    state_owned = false;
    try evaluator.beginIsolatedApplication(state.application(@intCast(count)));
}

fn createIteration(
    evaluator: *Machine,
    kind: IterationKind,
    left: Value,
    right: ?Value,
    quotation: *Header,
    expected: ?Value,
    count: usize,
) error{OutOfMemory}!*IterationState {
    const state = evaluator.allocator().create(IterationState) catch {
        heap.releaseValue(evaluator.allocator(), left);
        if (right) |item| heap.releaseValue(evaluator.allocator(), item);
        heap.decRef(evaluator.allocator(), quotation);
        if (expected) |item| heap.releaseValue(evaluator.allocator(), item);
        return error.OutOfMemory;
    };
    state.* = .{
        .kind = kind,
        .left = left,
        .right = right,
        .quotation = quotation,
        .expected = expected,
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

fn pushCollected(evaluator: *Machine, values: []const Value) MachineError!void {
    try evaluator.pushOwned(try storage.fromValues(
        evaluator.allocator(),
        values,
        (support.Context{ .evaluator = evaluator }).structuralPoller(),
    ));
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

fn boolValue(evaluator: *Machine, item: Value) MachineError!bool {
    defer heap.releaseValue(evaluator.allocator(), item);
    return switch (item) {
        .int => |integer| switch (integer) {
            0 => false,
            1 => true,
            else => evaluator.typeError("a 0/1 bool"),
        },
        .float, .char, .symbol, .word, .list, .dict => evaluator.typeError("a 0/1 bool"),
    };
}

fn quotationHeader(evaluator: *Machine, item: Value) MachineError!*Header {
    return switch (item) {
        .list => |header| header,
        .int, .float, .char, .symbol, .word, .dict => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a quotation/list");
        },
    };
}

fn releaseThree(allocator: std.mem.Allocator, a: Value, b: Value, c: Value) void {
    heap.releaseValue(allocator, a);
    heap.releaseValue(allocator, b);
    heap.releaseValue(allocator, c);
}

fn releaseIterationInputs(allocator: std.mem.Allocator, quotation: *Header, left: Value, right: Value) void {
    heap.decRef(allocator, quotation);
    heap.releaseValue(allocator, left);
    heap.releaseValue(allocator, right);
}
