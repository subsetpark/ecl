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
        .{ .name = "@give", .primitive = give },
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
        .site = .{ .inherited = .{
            .scope = evaluator.currentScope(),
            .home = evaluator.currentHome(),
        } },
        .quotation = quotation,
        .initial_stack = initial_stack,
        .constructor = constructor,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Io => evaluator.fail(.io, "could not start scheduler worker threads"),
        // Only a request carrying a transfer can refuse, and those callers
        // replace this with the reason they recorded.
        error.Transfer => evaluator.fail(.domain, "could not give a port to the new unit"),
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

/// Moves a set of ports from the spawning unit into the child unit as part of
/// constructing it. Each port is attached to the child before it can run and
/// detached from the caller only once the spawn can no longer fail, so no port
/// is ever unowned and none is visible to the child before the child owns it.
/// The prepared moves are held as consuming capabilities: this context can
/// only finish moves it actually prepared.
const GiveTransfer = struct {
    origin: *anyopaque,
    ports: []const Value,
    prepared: []heap.PortTransfer,
    count: usize = 0,
    refusal: ?heap.PortTransferError = null,

    pub fn prepareScopeTransfer(
        self: *GiveTransfer,
        destination: *scheduler_api.TaskScope,
    ) scheduler_api.ScopeTransferError!void {
        for (self.ports, 0..) |port, index| {
            self.prepared[index] = heap.preparePortTransfer(
                port.port,
                self.origin,
                @ptrCast(destination),
            ) catch |err| {
                self.abortScopeTransfer();
                self.refusal = err;
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Transfer,
                };
            };
            self.count = index + 1;
        }
    }

    pub fn commitScopeTransfer(self: *GiveTransfer) void {
        for (self.prepared[0..self.count]) |*transfer| transfer.commit();
        self.count = 0;
    }

    pub fn abortScopeTransfer(self: *GiveTransfer) void {
        for (self.prepared[0..self.count]) |*transfer| transfer.abort();
        self.count = 0;
    }
};

fn give(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var body = try evaluator.popQuotation();
    defer body.deinit();
    var seeds = try evaluator.popList();
    defer seeds.deinit();
    var moved = try evaluator.popList();
    defer moved.deinit();

    const moved_count: usize = @intCast(moved.borrow().list.length());
    const seed_count: usize = @intCast(seeds.borrow().list.length());
    const allocator = evaluator.allocator();

    var ports = try allocator.alloc(Value, moved_count);
    defer allocator.free(ports);
    for (0..moved_count) |index| {
        const item = list.atUnchecked(moved.borrow(), index);
        if (item != .port) return evaluator.typeError("a list of ports to give");
        ports[index] = item;
    }
    const prepared = try allocator.alloc(heap.PortTransfer, moved_count);
    defer allocator.free(prepared);

    // The child starts on the given ports, deepest, then the ordinary values.
    var entries = try allocator.alloc(Value, moved_count + seed_count);
    defer allocator.free(entries);
    for (0..moved_count) |index| entries[index] = list.atUnchecked(moved.borrow(), index);
    for (0..seed_count) |index| entries[moved_count + index] = list.atUnchecked(seeds.borrow(), index);
    var initial = heap.OwnedValue.init(
        evaluator.releaseDomain(),
        try list.fromValuesGeneric(allocator, entries),
    );
    defer initial.deinit();

    var transfer = GiveTransfer{
        .origin = evaluator.unit.task_scope.?,
        .ports = ports,
        .prepared = prepared,
    };
    const stack: machine.InitialStack = if (entries.len == 0)
        .empty
    else
        .{ .borrowed_seeds = initial.borrow().list };
    const task = scheduler(evaluator).spawn(scope(evaluator), .{
        .parent_unit = evaluator.unit,
        .site = .{ .inherited = .{
            .scope = evaluator.currentScope(),
            .home = evaluator.currentHome(),
        } },
        .quotation = body.borrow().list,
        .initial_stack = stack,
        .constructor = .spawn,
        .transfer = scheduler_api.scopeTransfer(GiveTransfer, &transfer),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Io => return evaluator.fail(.io, "could not start scheduler worker threads"),
        error.Transfer => return switch (transfer.refusal.?) {
            error.NotOwner => evaluator.fail(
                .domain,
                "@give can only give a port owned by the calling unit",
            ),
            error.ScopeClosing => evaluator.fail(.cancelled, "the new unit's scope is closing"),
            error.Closed => evaluator.fail(.domain, "@give cannot give a closed port"),
            error.Unsupported => evaluator.fail(
                .domain,
                "@give cannot give this kind of port to another unit",
            ),
            error.Busy => evaluator.fail(.domain, "@give cannot give the same port twice"),
            error.OutOfMemory => error.OutOfMemory,
        },
    };
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
    const milliseconds: u63 = @intCast(duration.borrow().int);
    scheduler(evaluator).checkDeadline(milliseconds) catch
        return evaluator.fail(.overflow, "await-for deadline lies beyond the clock's range");
    try evaluator.park(.{ .deadline = .{
        .task = task.take(),
        .milliseconds = milliseconds,
    } });
}

fn parEach(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
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
    /// One moved decoded owner supplies the body and shared seeds to
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
