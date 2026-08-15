const std = @import("std");
const minish = @import("minish");
const scheduler = @import("../scheduler_core.zig");

const max_tasks = 12;
const max_trace_steps = 160;

const Trace = struct {
    steps: []const u8,
};

const TraceGenerator = minish.gen.Generator(Trace);
const TraceShrinkFnPointer = @typeInfo(@FieldType(TraceGenerator, "shrinkFn")).optional.child;
const TraceShrinkFn = @typeInfo(TraceShrinkFnPointer).pointer.child;
const TraceShrinkIterator = @typeInfo(TraceShrinkFn).@"fn".return_type.?;

fn generateTrace(test_case: *minish.TestCase) minish.GenError!Trace {
    const length: usize = @intCast(try test_case.choice(max_trace_steps));
    const steps = try test_case.allocator.alloc(u8, length);
    errdefer test_case.allocator.free(steps);
    for (steps) |*step| step.* = @intCast(try test_case.choice(255));
    return .{ .steps = steps };
}

fn freeTrace(allocator: std.mem.Allocator, trace: Trace) void {
    allocator.free(trace.steps);
}

const TraceShrinkContext = struct {
    allocator: std.mem.Allocator,
    original: Trace,
    phase: Phase,
    index: usize = 0,

    const Phase = enum { empty, prefix, remove_one, simplify, done };

    fn candidate(self: *TraceShrinkContext, length: usize) ?[]u8 {
        return self.allocator.alloc(u8, length) catch null;
    }

    fn next(context_ptr: *anyopaque) ?Trace {
        const self: *TraceShrinkContext = @ptrCast(@alignCast(context_ptr));
        while (true) switch (self.phase) {
            .empty => {
                self.phase = .prefix;
                if (self.original.steps.len == 0) continue;
                return .{ .steps = self.candidate(0) orelse return null };
            },
            .prefix => {
                self.phase = .remove_one;
                if (self.original.steps.len < 2) continue;
                const length = self.original.steps.len / 2;
                const steps = self.candidate(length) orelse return null;
                @memcpy(steps, self.original.steps[0..length]);
                return .{ .steps = steps };
            },
            .remove_one => {
                if (self.original.steps.len <= 1 or self.index >= self.original.steps.len) {
                    self.phase = .simplify;
                    self.index = 0;
                    continue;
                }
                const removed = self.index;
                self.index += 1;
                const steps = self.candidate(self.original.steps.len - 1) orelse return null;
                @memcpy(steps[0..removed], self.original.steps[0..removed]);
                @memcpy(steps[removed..], self.original.steps[removed + 1 ..]);
                return .{ .steps = steps };
            },
            .simplify => {
                while (self.index < self.original.steps.len and self.original.steps[self.index] == 0) {
                    self.index += 1;
                }
                if (self.index == self.original.steps.len) {
                    self.phase = .done;
                    continue;
                }
                const simplified = self.index;
                self.index += 1;
                const steps = self.candidate(self.original.steps.len) orelse return null;
                @memcpy(steps, self.original.steps);
                steps[simplified] /= 2;
                return .{ .steps = steps };
            },
            .done => return null,
        };
    }

    fn deinit(context_ptr: *anyopaque) void {
        const self: *TraceShrinkContext = @ptrCast(@alignCast(context_ptr));
        self.allocator.destroy(self);
    }
};

fn shrinkTrace(allocator: std.mem.Allocator, trace: Trace) TraceShrinkIterator {
    const context = allocator.create(TraceShrinkContext) catch return TraceShrinkIterator.empty();
    context.* = .{ .allocator = allocator, .original = trace, .phase = .empty };
    return .{
        .context = context,
        .nextFn = TraceShrinkContext.next,
        .deinitFn = TraceShrinkContext.deinit,
    };
}

const trace_generator: TraceGenerator = .{
    .generateFn = generateTrace,
    .shrinkFn = shrinkTrace,
    .freeFn = freeTrace,
};

const Parent = union(enum) {
    root,
    task: u8,
};

const ModelTask = struct {
    used: bool = false,
    parent: Parent = .root,
    unit: scheduler.Unit = .constructing,
    scope: scheduler.Scope = .{ .open = 0 },
    queued: bool = false,
    wait: ?scheduler.Wait = null,
    park_wakes: u8 = 0,
    terminal_publications: u8 = 0,
};

const Model = struct {
    tasks: [max_tasks]ModelTask = [_]ModelTask{.{}} ** max_tasks,
    root_scope: scheduler.Scope = .{ .open = 0 },
    used: usize = 0,

    fn spawn(self: *Model, parent: Parent) anyerror!void {
        if (self.used == self.tasks.len) return;
        const index = self.used;
        self.used += 1;
        self.tasks[index] = .{ .used = true, .parent = parent };
        const published = try scheduler.decideUnit(self.tasks[index].unit, .publish);
        self.tasks[index].unit = published.next;
        try self.performUnitCommand(index, published.command);
        const parent_scope = self.scope(parent);
        const registered = try scheduler.decideScope(parent_scope.*, .register_child);
        parent_scope.* = registered.next;
        if (registered.command == .cancel_arriving_child) try self.cancel(index);
    }

    fn scope(self: *Model, parent: Parent) *scheduler.Scope {
        return switch (parent) {
            .root => &self.root_scope,
            .task => |index| &self.tasks[index].scope,
        };
    }

    fn performUnitCommand(
        self: *Model,
        index: usize,
        command: scheduler.UnitCommand,
    ) anyerror!void {
        switch (command) {
            .none => {},
            .cancel_before_dispatch => {
                const stopped = try scheduler.decideUnit(
                    self.tasks[index].unit,
                    .{ .body_finished = .language_error },
                );
                self.tasks[index].unit = stopped.next;
                try self.performUnitCommand(index, stopped.command);
            },
            .enqueue => {
                try std.testing.expect(!self.tasks[index].queued);
                self.tasks[index].queued = true;
            },
            .register_wait => {
                try std.testing.expect(self.tasks[index].wait == null);
                self.tasks[index].wait = .registering;
                self.tasks[index].park_wakes = 0;
            },
            .race_cancellation => try self.wake(index, .cancellation),
            .close_scope => try self.closeTaskScope(index),
            .publish => try self.publishTerminal(index),
        }
    }

    fn dispatchAndAct(self: *Model, index: usize, action: u2) anyerror!void {
        if (!self.tasks[index].queued) return;
        self.tasks[index].queued = false;
        const dispatched = try scheduler.decideUnit(self.tasks[index].unit, .dispatch);
        self.tasks[index].unit = dispatched.next;
        try self.performUnitCommand(index, dispatched.command);
        if (dispatched.command == .cancel_before_dispatch) return;
        const decision = switch (action) {
            0 => try scheduler.decideUnit(self.tasks[index].unit, .yield),
            1 => try scheduler.decideUnit(self.tasks[index].unit, .park),
            else => try scheduler.decideUnit(
                self.tasks[index].unit,
                .{ .body_finished = if (self.tasks[index].unit.cancellationRequested())
                    .language_error
                else
                    .success },
            ),
        };
        self.tasks[index].unit = decision.next;
        try self.performUnitCommand(index, decision.command);
    }

    fn wake(self: *Model, index: usize, reason: scheduler.WakeReason) anyerror!void {
        try self.transitionWait(index, .{ .candidate = reason });
    }

    fn activateWait(self: *Model, index: usize) anyerror!void {
        const wait = self.tasks[index].wait orelse return;
        if (wait != .registering and wait != .selected) return;
        try self.transitionWait(index, .activate);
    }

    fn transitionWait(
        self: *Model,
        index: usize,
        event: scheduler.WaitEvent,
    ) anyerror!void {
        const wait = self.tasks[index].wait orelse return;
        const selected = try scheduler.decideWait(wait, event);
        self.tasks[index].wait = selected.next;
        switch (selected.command) {
            .none => {},
            .deliver => |winner| {
                self.tasks[index].park_wakes += 1;
                const woken = try scheduler.decideUnit(
                    self.tasks[index].unit,
                    .{ .wake = winner },
                );
                self.tasks[index].unit = woken.next;
                self.tasks[index].wait = null;
                try self.performUnitCommand(index, woken.command);
            },
        }
    }

    fn cancel(self: *Model, index: usize) anyerror!void {
        const decision = try scheduler.decideUnit(self.tasks[index].unit, .cancel);
        self.tasks[index].unit = decision.next;
        try self.performUnitCommand(index, decision.command);
        try self.cancelScope(&self.tasks[index].scope);
    }

    fn cancelScope(self: *Model, target: *scheduler.Scope) anyerror!void {
        const closing = try scheduler.decideScope(target.*, .close);
        target.* = closing.next;
        if (closing.command != .cancel_children) return;
        const owner = self.scopeOwner(target);
        for (self.tasks[0..self.used], 0..) |task, index| {
            if (!task.used or task.unit.phase() == .done) continue;
            if (sameParent(task.parent, owner)) try self.cancel(index);
        }
    }

    fn closeTaskScope(self: *Model, index: usize) anyerror!void {
        const closing = try scheduler.decideScope(self.tasks[index].scope, .close);
        self.tasks[index].scope = closing.next;
        if (closing.command == .cancel_children) {
            for (self.tasks[0..self.used], 0..) |task, child_index| {
                if (!task.used or task.unit.phase() == .done) continue;
                if (sameParent(task.parent, .{ .task = @intCast(index) })) {
                    try self.cancel(child_index);
                }
            }
        } else if (closing.command == .notify_quiescent) {
            const quiescent = try scheduler.decideUnit(self.tasks[index].unit, .scope_quiescent);
            self.tasks[index].unit = quiescent.next;
            try self.performUnitCommand(index, quiescent.command);
        }
    }

    fn publishTerminal(self: *Model, index: usize) anyerror!void {
        self.tasks[index].terminal_publications += 1;
        try std.testing.expectEqual(@as(u8, 1), self.tasks[index].terminal_publications);
        try std.testing.expectEqual(scheduler.UnitPhase.done, self.tasks[index].unit.phase());
        try std.testing.expectEqual(@as(u32, 0), self.tasks[index].scope.childCount());
        try std.testing.expect(!self.tasks[index].queued);
        try std.testing.expect(self.tasks[index].wait == null);

        const parent = self.tasks[index].parent;
        const parent_scope = self.scope(parent);
        const removed = try scheduler.decideScope(parent_scope.*, .child_terminal);
        parent_scope.* = removed.next;
        if (removed.command == .notify_quiescent) switch (parent) {
            .root => {},
            .task => |parent_index| {
                if (self.tasks[parent_index].unit.phase() == .closing) {
                    const quiescent = try scheduler.decideUnit(
                        self.tasks[parent_index].unit,
                        .scope_quiescent,
                    );
                    self.tasks[parent_index].unit = quiescent.next;
                    try self.performUnitCommand(parent_index, quiescent.command);
                }
            },
        };
    }

    fn scopeOwner(self: *Model, target: *scheduler.Scope) Parent {
        if (target == &self.root_scope) return .root;
        for (self.tasks[0..self.used], 0..) |*task, index| {
            if (target == &task.scope) return .{ .task = @intCast(index) };
        }
        unreachable;
    }

    fn assertSafety(self: *const Model) anyerror!void {
        var expected_root_children: u32 = 0;
        for (self.tasks[0..self.used], 0..) |task, index| {
            if (!task.used) continue;
            const ready = task.unit.phase() == .ready;
            try std.testing.expectEqual(ready, task.queued);
            try std.testing.expect(task.park_wakes <= 1);
            try std.testing.expect(task.terminal_publications <= 1);
            if (task.unit.phase() == .parked) {
                try std.testing.expect(task.wait != null);
            } else try std.testing.expect(task.wait == null);
            if (task.unit.phase() == .done) {
                try std.testing.expectEqual(@as(u8, 1), task.terminal_publications);
            }

            var direct_children: u32 = 0;
            for (self.tasks[0..self.used]) |child| {
                if (!child.used or child.unit.phase() == .done) continue;
                if (sameParent(child.parent, .{ .task = @intCast(index) })) direct_children += 1;
            }
            try std.testing.expectEqual(direct_children, task.scope.childCount());
            if (task.scope == .closed) try std.testing.expectEqual(@as(u32, 0), direct_children);
            if (task.unit.phase() != .done and task.parent == .root) expected_root_children += 1;
        }
        try std.testing.expectEqual(expected_root_children, self.root_scope.childCount());
        if (self.root_scope == .closed) try std.testing.expectEqual(@as(u32, 0), expected_root_children);
    }

    fn drain(self: *Model) anyerror!void {
        try self.cancelScope(&self.root_scope);
        var steps: usize = 0;
        while (self.root_scope != .closed and steps < max_tasks * 8) : (steps += 1) {
            var progressed = false;
            for (self.tasks[0..self.used], 0..) |task, index| {
                switch (task.unit.phase()) {
                    .ready => {
                        try self.dispatchAndAct(index, 2);
                        progressed = true;
                    },
                    .parked => {
                        try self.cancel(index);
                        try self.activateWait(index);
                        progressed = true;
                    },
                    .running => unreachable,
                    .closing, .done, .constructing => {},
                }
            }
            try self.assertSafety();
            if (!progressed) break;
        }
        try std.testing.expectEqual(scheduler.Scope{ .closed = {} }, self.root_scope);
        for (self.tasks[0..self.used]) |task| {
            try std.testing.expectEqual(scheduler.UnitPhase.done, task.unit.phase());
        }
    }
};

fn sameParent(a: Parent, b: Parent) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .root => true,
        .task => |index| index == b.task,
    };
}

fn chooseLiveTask(model: *const Model, selector: u8) ?usize {
    if (model.used == 0) return null;
    const start = @as(usize, selector) % model.used;
    for (0..model.used) |offset| {
        const index = (start + offset) % model.used;
        if (model.tasks[index].unit.phase() != .done) return index;
    }
    return null;
}

fn chooseReadyTask(model: *const Model, selector: u8) ?usize {
    if (model.used == 0) return null;
    const start = @as(usize, selector) % model.used;
    for (0..model.used) |offset| {
        const index = (start + offset) % model.used;
        if (model.tasks[index].queued) return index;
    }
    return null;
}

fn runGeneratedTrace(trace: Trace) anyerror!void {
    var model: Model = .{};
    try model.spawn(.root);
    for (trace.steps) |encoded| {
        switch (encoded % 6) {
            0 => if (model.used < max_tasks) {
                const parent: Parent = if (chooseLiveTask(&model, encoded / 6)) |index|
                    .{ .task = @intCast(index) }
                else
                    .root;
                try model.spawn(parent);
            },
            1, 2 => if (chooseReadyTask(&model, encoded / 6)) |index| {
                try model.dispatchAndAct(index, @intCast((encoded / 25) % 3));
            },
            3 => if (chooseLiveTask(&model, encoded / 6)) |index| try model.cancel(index),
            4 => if (chooseLiveTask(&model, encoded / 6)) |index| {
                const reason: scheduler.WakeReason = switch ((encoded / 25) % 5) {
                    0 => .{ .task = encoded },
                    1 => .timeout,
                    2 => .cancellation,
                    3 => .io,
                    else => .out_of_memory,
                };
                try model.wake(index, reason);
            },
            5 => if (chooseLiveTask(&model, encoded / 6)) |index| {
                try model.activateWait(index);
            },
            else => unreachable,
        }
        try model.assertSafety();
    }
    try model.drain();
}

test "scheduler properties: arbitrary program traces are safe and close live" {
    try minish.check(std.testing.allocator, trace_generator, runGeneratedTrace, .{
        .num_runs = 512,
        .seed = 0x5ced_71a5_ec1,
        .max_shrink_attempts = 4096,
    });
}

test "scheduler properties: every wake permutation selects exactly one winner" {
    const candidates = [_]scheduler.WakeReason{
        .{ .task = 0 },
        .{ .task = 1 },
        .timeout,
        .cancellation,
        .io,
        .out_of_memory,
    };
    for (0..256) |seed| {
        var order = candidates;
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().shuffle(scheduler.WakeReason, &order);
        var state: scheduler.Wait = .active;
        var wakes: usize = 0;
        for (order) |candidate| {
            const decision = try scheduler.decideWait(state, .{ .candidate = candidate });
            state = decision.next;
            switch (decision.command) {
                .none => {},
                .deliver => |winner| {
                    wakes += 1;
                    try std.testing.expect(winner.eql(order[0]));
                },
            }
        }
        try std.testing.expectEqual(@as(usize, 1), wakes);
        try std.testing.expect(state.delivered.eql(order[0]));
    }
}

test "scheduler properties: cancelled ready units cannot dispatch body work" {
    var unit: scheduler.Unit = .{ .ready = .{} };
    unit = (try scheduler.decideUnit(unit, .cancel)).next;
    const dispatch = try scheduler.decideUnit(unit, .dispatch);
    try std.testing.expect(dispatch.command == .cancel_before_dispatch);
    try std.testing.expectEqual(scheduler.UnitPhase.running, dispatch.next.phase());

    const stopped = try scheduler.decideUnit(
        dispatch.next,
        .{ .body_finished = .language_error },
    );
    try std.testing.expect(stopped.command == .close_scope);
}

test "scheduler properties: every child registered after close is killed on arrival" {
    const registered = try scheduler.decideScope(.closed, .register_child);
    try std.testing.expectEqual(scheduler.Scope{ .closing = 1 }, registered.next);
    try std.testing.expect(registered.command == .cancel_arriving_child);
}

test "scheduler properties: selection before activation delivers once on activation" {
    const candidates = [_]scheduler.WakeReason{
        .{ .task = 0 },
        .timeout,
        .cancellation,
        .io,
        .out_of_memory,
    };
    for (candidates) |candidate| {
        const selected = try scheduler.decideWait(
            .registering,
            .{ .candidate = candidate },
        );
        try std.testing.expect(selected.next.selected.eql(candidate));
        try std.testing.expect(selected.command == .none);
        const activated = try scheduler.decideWait(selected.next, .activate);
        switch (activated.command) {
            .none => return error.ExpectedDelivery,
            .deliver => |winner| try std.testing.expect(winner.eql(candidate)),
        }
        const late = try scheduler.decideWait(
            activated.next,
            .{ .candidate = .timeout },
        );
        try std.testing.expect(late.command == .none);
        try std.testing.expect(late.next.delivered.eql(candidate));
    }
}

fn applyRegistrationEvent(
    state: *scheduler.Registration,
    owners: *u2,
    event: scheduler.RegistrationEvent,
) !void {
    const decision = scheduler.decideRegistration(state.*, event) catch |err| switch (err) {
        error.InvalidTransition => return,
    };
    const command = decision.command;
    if (command.retain_external) owners.* += 1;
    if (command.release_directory) {
        try std.testing.expect(owners.* > 0);
        owners.* -= 1;
    }
    if (command.release_external) {
        try std.testing.expect(owners.* > 0);
        owners.* -= 1;
    }
    if (command.unlink) try std.testing.expect(state.* == .linked);
    state.* = decision.next;
    try std.testing.expectEqual(state.ownerCount(), owners.*);
}

fn runRegistrationTrace(encoded: u64) !void {
    var remaining = encoded;
    var state: scheduler.Registration = .directory;
    var owners: u2 = state.ownerCount();
    for (0..32) |_| {
        const event: scheduler.RegistrationEvent = @enumFromInt(remaining & 0x3);
        remaining >>= 2;
        try applyRegistrationEvent(&state, &owners, event);
    }

    switch (state) {
        .directory, .directory_after_delivery => try applyRegistrationEvent(&state, &owners, .cleanup),
        .linked => try applyRegistrationEvent(&state, &owners, .cleanup),
        .detached => {
            if ((encoded & 1) == 0) {
                try applyRegistrationEvent(&state, &owners, .cleanup);
                try applyRegistrationEvent(&state, &owners, .delivery_returned);
            } else {
                try applyRegistrationEvent(&state, &owners, .delivery_returned);
                try applyRegistrationEvent(&state, &owners, .cleanup);
            }
        },
        .delivery_after_cleanup => try applyRegistrationEvent(&state, &owners, .delivery_returned),
        .retired => {},
    }
    try std.testing.expectEqual(scheduler.Registration.retired, state);
    try std.testing.expectEqual(@as(u2, 0), owners);
}

test "scheduler properties: registration owners retire under arbitrary event order" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), runRegistrationTrace, .{
        .num_runs = 512,
        .seed = 0x0a8a_1afe_51fe,
        .max_shrink_attempts = 256,
    });
}
