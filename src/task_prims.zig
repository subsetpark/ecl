//! Language adapters for structured task operations.
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
        .{ .name = "@spawn", .primitive = spawn },
        .{ .name = "await", .primitive = await },
        .{ .name = "cancel", .primitive = cancel },
        .{ .name = "tasks", .primitive = tasks },
        .{ .name = "await-any", .primitive = awaitAny },
        .{ .name = "await-for", .primitive = awaitFor },
        .{ .name = "@each", .primitive = parEach },
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
    constructor: machine.UnitConstructor,
) MachineError!Value {
    return scheduler(evaluator).spawn(scope(evaluator), .{
        .parent_unit = evaluator.unit,
        .parent_scope = evaluator.currentScope(),
        .parent_home = evaluator.currentHome(),
        .quotation = quotation,
        .initial_stack = initial_stack,
        .constructor = constructor,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Io => evaluator.fail(.io, "could not start scheduler worker threads"),
    };
}

fn spawn(evaluator: *Machine) MachineError!void {
    var input = try evaluator.popUnitInput();
    defer input.deinit(evaluator.releaseDomain());
    const borrowed = input.borrow();
    const task = try spawnTask(
        evaluator,
        borrowed.quotation(),
        borrowed.initialStack(null),
        .spawn,
    );
    try evaluator.pushOwned(task);
}

fn await(evaluator: *Machine) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    try evaluator.park(.{ .task = task.take() });
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
    try evaluator.startDriver(AwaitAnyDriver{ .tasks = .init(tasks_value.take()) });
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
    try evaluator.park(.{ .deadline = .{
        .task = task.take(),
        .milliseconds = duration.borrow().int,
    } });
}

fn parEach(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var input = try evaluator.popUnitInput();
    defer input.deinit(evaluator.releaseDomain());
    var sequence = try evaluator.popList();
    defer sequence.deinit();

    const count: usize = @intCast(sequence.borrow().list.length());
    var task_buffer = try heap.OwnedValueBuffer.init(evaluator.releaseDomain(), count);
    defer task_buffer.deinit();
    try evaluator.startDriver(ParEachDriver{
        .sequence = .init(sequence.take()),
        .input = .init(input.move()),
        .tasks = .init(task_buffer.take()),
    });
}

const ParEachDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    sequence: heap.Owned(Value),
    /// One moved decoded owner supplies the quotation and shared seeds to
    /// every immediate child launch; children retain their own references
    /// before this fan-out state advances.
    input: heap.Owned(machine.OwnedUnitInput),
    tasks: heap.Owned(heap.OwnedValueBuffer),
    index: usize = 0,

    pub fn advance(
        evaluator: *Machine,
        self: *ParEachDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const count: usize = @intCast(self.sequence.borrow().list.length());
        const end = @min(self.index + par_each_work_quantum, count);
        while (self.index != end) : (self.index += 1) {
            const element = list.atUnchecked(self.sequence.borrow(), self.index);
            const borrowed = self.input.borrow().borrow();
            const task = try spawnTask(
                evaluator,
                borrowed.quotation(),
                borrowed.initialStack(element),
                .each,
            );
            self.tasks.borrowMut().appendOwned(task);
        }
        if (self.index != count) return .yielded;
        const task_values = self.tasks.borrowMut().takeList();
        evaluator.retireDriver(self);
        try evaluator.beginTaskJoinOwned(task_values);
        return .detached;
    }
};

const AwaitAnyDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    tasks: ?heap.Owned(Value),
    index: usize = 0,

    pub fn advance(
        evaluator: *Machine,
        self: *AwaitAnyDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const task_values = self.tasks.?.borrow();
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
        _ = self.tasks.?.take();
        self.tasks = null;
        evaluator.retireDriver(self);
        try evaluator.park(.{ .any = task_values });
        return .detached;
    }
};
