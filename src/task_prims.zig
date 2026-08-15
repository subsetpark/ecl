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
    };
    try core.installBuiltins(definitions);
    try core.installInternalBuiltin("task-join", taskJoin);
}

fn scheduler(evaluator: *Machine) *const scheduler_api.WorkerScheduler {
    return @ptrCast(@alignCast(evaluator.unit.scheduler.?));
}

fn scope(evaluator: *Machine) *scheduler_api.TaskScope {
    return @ptrCast(@alignCast(evaluator.unit.task_scope.?));
}

fn spawn(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    if (quotation.borrow() != .list) return evaluator.typeError("a quotation/list");
    const task = scheduler(evaluator).spawn(scope(evaluator), .{
        .parent_unit = evaluator.unit,
        .parent_scope = evaluator.currentScope(),
        .parent_home = evaluator.currentHome(),
        .quotation = quotation.borrow().list,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Io => return evaluator.fail(.io, "could not start scheduler worker threads"),
    };
    try evaluator.pushOwned(task);
}

fn await(evaluator: *Machine) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    evaluator.unit.installParkRequest(.{ .task = task.take() });
}

fn cancel(evaluator: *Machine) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    scheduler(evaluator).cancelOwned(task.take());
}

fn tasks(evaluator: *Machine) MachineError!void {
    try scheduler(evaluator).installTasksDriver(evaluator, scope(evaluator));
}

fn awaitAny(evaluator: *Machine) MachineError!void {
    var tasks_value = try evaluator.popValue();
    defer tasks_value.deinit();
    const task_list = tasks_value.borrow();
    if (task_list != .list) {
        return evaluator.typeError("a nonempty list of tasks");
    }
    const count: usize = @intCast(task_list.list.length());
    if (count == 0) {
        return evaluator.fail(.domain, "await-any requires a nonempty list");
    }
    const driver = try evaluator.allocator().create(TaskListDriver);
    driver.* = .{ .tasks = tasks_value.take(), .mode = .await_any };
    evaluator.installWorkDriver(driver);
}

fn awaitFor(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var duration = try evaluator.popValue();
    defer duration.deinit();
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task followed by milliseconds");
    if (duration.borrow() != .int) return evaluator.typeError("an integer millisecond duration");
    if (duration.borrow().int < 0) return evaluator.fail(.domain, "await-for duration must be nonnegative");
    evaluator.unit.installParkRequest(.{ .deadline = .{
        .task = task.take(),
        .milliseconds = duration.borrow().int,
    } });
}

fn taskJoin(evaluator: *Machine) MachineError!void {
    var tasks_value = try evaluator.popValue();
    defer tasks_value.deinit();
    const task_list = tasks_value.borrow();
    if (task_list != .list) return evaluator.typeError("a list of tasks");
    const driver = evaluator.allocator().create(TaskListDriver) catch {
        evaluator.beginTaskJoinInputCleanupOwned(tasks_value.take());
        return error.OutOfMemory;
    };
    driver.* = .{ .tasks = tasks_value.take(), .mode = .join };
    evaluator.installWorkDriver(driver);
}

const TaskListDriver = struct {
    tasks: ?value.Value,
    mode: enum { await_any, join },
    index: usize = 0,

    pub fn advance(
        evaluator: *Machine,
        self: *TaskListDriver,
    ) MachineError!machine.WorkProgress {
        evaluator.pollKernel() catch |err| {
            self.abandonJoinInput(evaluator);
            return err;
        };
        const task_values = self.tasks.?;
        const count: usize = @intCast(task_values.list.length());
        const end = @min(self.index + machine.kernel_poll_quantum, count);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(task_values, self.index) != .task) {
                const failure = evaluator.failAtIndex(
                    .type,
                    if (self.mode == .await_any)
                        "await-any expected only tasks"
                    else
                        "task-join expected only tasks",
                    self.index,
                );
                self.abandonJoinInput(evaluator);
                return failure;
            }
        }
        if (self.index != count) return .yielded;
        switch (self.mode) {
            .await_any => {
                self.tasks = null;
                evaluator.detachWorkDriver(self);
                TaskListDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
                evaluator.unit.installParkRequest(.{ .any = task_values });
                return .detached;
            },
            .join => {
                const ok_id = intern.intern("ok") catch |err| {
                    self.abandonJoinInput(evaluator);
                    return err;
                };
                const err_id = intern.intern("err") catch |err| {
                    self.abandonJoinInput(evaluator);
                    return err;
                };
                self.tasks = null;
                evaluator.detachWorkDriver(self);
                TaskListDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
                try evaluator.beginTaskJoinOwned(task_values, ok_id, err_id);
                return .detached;
            },
        }
    }

    fn abandonJoinInput(self: *TaskListDriver, evaluator: *Machine) void {
        if (self.mode != .join) return;
        const task_values = self.tasks orelse return;
        self.tasks = null;
        evaluator.detachWorkDriver(self);
        TaskListDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
        evaluator.beginTaskJoinInputCleanupOwned(task_values);
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *TaskListDriver) void {
        if (self.tasks) |task_values| releases.releaseValue(task_values);
        allocator.destroy(self);
    }
};
