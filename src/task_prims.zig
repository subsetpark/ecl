//! Language adapters for structured task operations.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const scheduler_api = @import("scheduler.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "spawn", .primitive = spawn },
        .{ .name = "await", .primitive = await },
        .{ .name = "cancel", .primitive = cancel },
        .{ .name = "tasks", .primitive = tasks },
        .{ .name = "await-any", .primitive = awaitAny },
        .{ .name = "await-for", .primitive = awaitFor },
        .{ .name = "task-join", .primitive = taskJoin },
    };
    try core.installBuiltins(definitions);
}

fn scheduler(evaluator: *Machine) *scheduler_api.Scheduler {
    return @ptrCast(@alignCast(evaluator.unit.scheduler.?));
}

fn scope(evaluator: *Machine) *scheduler_api.TaskScope {
    return @ptrCast(@alignCast(evaluator.unit.task_scope.?));
}

fn spawn(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), quotation);
    if (quotation != .list) return evaluator.typeError("a quotation/list");
    const task = scheduler(evaluator).spawn(scope(evaluator), .{
        .parent_unit = evaluator.unit,
        .parent_scope = evaluator.currentScope(),
        .parent_home = evaluator.currentHome(),
        .quotation = quotation.list,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Io => return evaluator.fail(.io, "could not start scheduler worker threads"),
    };
    try evaluator.pushOwned(task);
}

fn await(evaluator: *Machine) MachineError!void {
    const task = try evaluator.popOwned();
    if (task != .task) {
        heap.releaseValue(evaluator.allocator(), task);
        return evaluator.typeError("a task");
    }
    std.debug.assert(evaluator.unit.park_request == null);
    evaluator.unit.park_request = .{ .task = task };
}

fn cancel(evaluator: *Machine) MachineError!void {
    const task = try evaluator.popOwned();
    if (task != .task) {
        heap.releaseValue(evaluator.allocator(), task);
        return evaluator.typeError("a task");
    }
    scheduler(evaluator).cancelOwned(evaluator, task) catch |err| {
        heap.releaseValue(evaluator.allocator(), task);
        return err;
    };
}

fn tasks(evaluator: *Machine) MachineError!void {
    try scheduler(evaluator).installTasksDriver(evaluator, scope(evaluator));
}

fn awaitAny(evaluator: *Machine) MachineError!void {
    const task_list = try evaluator.popOwned();
    var task_list_owned = true;
    defer if (task_list_owned) heap.releaseValue(evaluator.allocator(), task_list);
    if (task_list != .list) {
        return evaluator.typeError("a nonempty list of tasks");
    }
    const count: usize = @intCast(task_list.list.length());
    if (count == 0) {
        return evaluator.fail(.domain, "await-any requires a nonempty list");
    }
    const driver = try evaluator.allocator().create(TaskListDriver);
    driver.* = .{ .tasks = task_list, .mode = .await_any };
    task_list_owned = false;
    evaluator.installWorkDriver(driver, TaskListDriver.advance, TaskListDriver.destroy);
}

fn awaitFor(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const duration = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), duration);
    const task = try evaluator.popOwned();
    if (task != .task) {
        heap.releaseValue(evaluator.allocator(), task);
        return evaluator.typeError("a task followed by milliseconds");
    }
    if (duration != .int) {
        heap.releaseValue(evaluator.allocator(), task);
        return evaluator.typeError("an integer millisecond duration");
    }
    if (duration.int < 0) {
        heap.releaseValue(evaluator.allocator(), task);
        return evaluator.fail(.domain, "await-for duration must be nonnegative");
    }
    std.debug.assert(evaluator.unit.park_request == null);
    evaluator.unit.park_request = .{ .deadline = .{
        .task = task,
        .milliseconds = duration.int,
    } };
}

fn taskJoin(evaluator: *Machine) MachineError!void {
    const task_list = try evaluator.popOwned();
    var task_list_owned = true;
    defer if (task_list_owned) heap.releaseValue(evaluator.allocator(), task_list);
    if (task_list != .list) return evaluator.typeError("a list of tasks");
    const driver = try evaluator.allocator().create(TaskListDriver);
    driver.* = .{ .tasks = task_list, .mode = .join };
    task_list_owned = false;
    evaluator.installWorkDriver(driver, TaskListDriver.advance, TaskListDriver.destroy);
}

const TaskListDriver = struct {
    tasks: value.Value,
    mode: enum { await_any, join },
    index: usize = 0,
    owned: bool = true,

    fn advance(
        evaluator: *Machine,
        raw: *anyopaque,
    ) MachineError!machine.WorkProgress {
        const self: *TaskListDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        const count: usize = @intCast(self.tasks.list.length());
        const end = @min(self.index + machine.kernel_poll_quantum, count);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(self.tasks, self.index) != .task) {
                return evaluator.failAtIndex(
                    .type,
                    if (self.mode == .await_any)
                        "await-any expected only tasks"
                    else
                        "task-join expected only tasks",
                    self.index,
                );
            }
        }
        if (self.index != count) return .yielded;
        const task_values = self.tasks;
        self.owned = false;
        switch (self.mode) {
            .await_any => {
                std.debug.assert(evaluator.unit.park_request == null);
                evaluator.unit.park_request = .{ .any = task_values };
            },
            .join => try evaluator.beginTaskJoinOwned(
                task_values,
                try intern.intern("ok"),
                try intern.intern("err"),
            ),
        }
        return .completed;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *TaskListDriver = @ptrCast(@alignCast(raw));
        if (self.owned) heap.releaseValue(allocator, self.tasks);
        allocator.destroy(self);
    }
};
