//! Language adapters for structured task operations.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const scheduler_api = @import("scheduler.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };
const par_each_work_quantum: usize = 256;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "spawn", .primitive = spawn },
        .{ .name = "await", .primitive = await },
        .{ .name = "cancel", .primitive = cancel },
        .{ .name = "tasks", .primitive = tasks },
        .{ .name = "await-any", .primitive = awaitAny },
        .{ .name = "await-for", .primitive = awaitFor },
        .{ .name = "par-each", .primitive = parEach },
    };
    try core.installBuiltins(definitions);
}

fn scheduler(evaluator: *Machine) *const scheduler_api.WorkerScheduler {
    return @ptrCast(@alignCast(evaluator.unit.scheduler.?));
}

fn scope(evaluator: *Machine) *scheduler_api.TaskScope {
    return @ptrCast(@alignCast(evaluator.unit.task_scope.?));
}

fn spawnTask(
    evaluator: *Machine,
    quotation: *value.ListHandle,
    initial_stack: machine.InitialStack,
) MachineError!Value {
    return scheduler(evaluator).spawn(scope(evaluator), .{
        .parent_unit = evaluator.unit,
        .parent_scope = evaluator.currentScope(),
        .parent_home = evaluator.currentHome(),
        .quotation = quotation,
        .initial_stack = initial_stack,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Io => evaluator.fail(.io, "could not start scheduler worker threads"),
    };
}

fn spawn(evaluator: *Machine) MachineError!void {
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    if (quotation.borrow() != .list) return evaluator.typeError("a quotation/list");
    const task = try spawnTask(evaluator, quotation.borrow().list, .empty);
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
    const driver = try evaluator.allocator().create(AwaitAnyDriver);
    driver.* = .{ .tasks = tasks_value.take() };
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

fn parEach(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var sequence = try evaluator.popValue();
    defer sequence.deinit();
    if (sequence.borrow() != .list) return evaluator.typeError("a list");
    if (quotation.borrow() != .list) return evaluator.typeError("a quotation");

    const count: usize = @intCast(sequence.borrow().list.length());
    var task_buffer = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), count);
    defer task_buffer.deinit();
    const driver = try evaluator.allocator().create(ParEachDriver);
    driver.* = .{
        .sequence = sequence.take(),
        .quotation = quotation.take(),
        .tasks = task_buffer.take(),
    };
    evaluator.installWorkDriver(driver);
}

const ParEachDriver = struct {
    sequence: Value,
    quotation: Value,
    tasks: heap.OwnedValueBuffer,
    index: usize = 0,

    pub fn advance(
        evaluator: *Machine,
        self: *ParEachDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.sequence.list.length());
        const end = @min(self.index + par_each_work_quantum, count);
        while (self.index != end) : (self.index += 1) {
            const task = try spawnTask(
                evaluator,
                self.quotation.list,
                .{ .borrowed_seed = list.atUnchecked(self.sequence, self.index) },
            );
            self.tasks.appendOwned(task);
        }
        if (self.index != count) return .yielded;
        const task_values = self.tasks.takeList();
        evaluator.detachWorkDriver(self);
        ParEachDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
        try evaluator.beginTaskJoinOwned(task_values);
        return .detached;
    }

    pub fn destroy(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *ParEachDriver,
    ) void {
        releases.releaseValue(self.sequence);
        releases.releaseValue(self.quotation);
        self.tasks.deinit();
        allocator.destroy(self);
    }
};

const AwaitAnyDriver = struct {
    tasks: ?Value,
    index: usize = 0,

    pub fn advance(
        evaluator: *Machine,
        self: *AwaitAnyDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const task_values = self.tasks.?;
        const count: usize = @intCast(task_values.list.length());
        const end = @min(self.index + machine.kernel_poll_quantum, count);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(task_values, self.index) != .task) {
                return evaluator.failAtIndex(
                    .type,
                    "await-any expected only tasks",
                    self.index,
                );
            }
        }
        if (self.index != count) return .yielded;
        self.tasks = null;
        evaluator.detachWorkDriver(self);
        AwaitAnyDriver.destroy(evaluator.releaseDomain(), evaluator.allocator(), self);
        evaluator.unit.installParkRequest(.{ .any = task_values });
        return .detached;
    }

    pub fn destroy(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *AwaitAnyDriver) void {
        if (self.tasks) |task_values| releases.releaseValue(task_values);
        allocator.destroy(self);
    }
};
