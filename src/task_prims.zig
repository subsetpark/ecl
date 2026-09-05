//! Language adapters for structured task operations.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const poll = @import("poll.zig");
const scheduler_api = @import("scheduler.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const par_each_work_quantum: usize = 256;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "@spawn", .primitive = spawn, .effect = "values quotation -- task", .doc = "Run a quotation with an explicit initial stack concurrently in a fresh child unit." },
        .{ .name = "@give", .primitive = give, .effect = "ports values quotation -- task", .doc = "Run a quotation concurrently in a fresh child unit that owns the given ports: the child unit closes them when it ends, and the calling unit no longer does." },
        .{ .name = "await", .primitive = await, .effect = "task -- result", .doc = "Wait for a task and return its success or error result." },
        .{ .name = "cancel", .primitive = cancel, .effect = "task --", .doc = "Request cancellation of a task, doing nothing if it is already complete." },
        .{ .name = "tasks", .primitive = tasks, .effect = "-- tasks", .doc = "Return pending descendant tasks in deterministic spawn order." },
        .{ .name = "await-any", .primitive = awaitAny, .effect = "tasks -- index result", .doc = "Wait for any task in a nonempty list and return its index and result." },
        .{ .name = "await-for", .primitive = awaitFor, .effect = "task milliseconds -- result", .doc = "Wait up to a nonnegative number of milliseconds for a task result." },
        .{ .name = "@each", .primitive = parEach, .effect = "sequence values quotation -- results", .doc = "Apply a quotation with an explicit shared initial stack concurrently in one fresh unit per element and return one result per element in input order." },
    };
    try core.installBuiltins(&definitions);
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

/// The single source of truth for one `@give`: which ports it must move, how
/// far each phase has got, and what has to be undone if a later port refuses.
/// Storage is fixed, so the cursor is bounded by construction rather than by
/// the caller's input, and every phase advances by a slice of a shared work
/// budget. The same cursor serves both drivers: the prim's bounded driver
/// advances validation and yields between slices, while preparation, rollback
/// and commit are driven synchronously from inside `spawn`, where the child's
/// scope already exists and a yield would expose half-moved ownership.
const GiveCursor = struct {
    const Phase = enum { validating, preparing, rolling_back, committing, done };

    /// What stopped the cursor, for the prim to turn into a language error.
    const Refusal = union(enum) {
        none,
        not_a_port,
        transfer: heap.PortTransferError,
    };

    origin: *anyopaque,
    moved: Value,
    count: usize,
    /// Filled by validation, then read by preparation. An unused slot is
    /// `null` rather than uninitialized, so the cursor has no garbage state.
    ports: [max_given_ports]?Value = @splat(null),
    prepared: [max_given_ports]?heap.PortTransfer = @splat(null),
    destination: ?*scheduler_api.TaskScope = null,
    phase: Phase = .validating,
    index: usize = 0,
    ready: usize = 0,
    refusal: Refusal = .none,

    pub fn advance(self: *GiveCursor, budget: *poll.WorkBudget) poll.Progress(void) {
        return switch (self.phase) {
            .validating => self.advanceValidating(budget),
            .preparing => self.advancePreparing(budget),
            .rolling_back => self.advanceRollingBack(budget),
            .committing => self.advanceCommitting(budget),
            .done => .complete,
        };
    }

    fn advanceValidating(self: *GiveCursor, budget: *poll.WorkBudget) poll.Progress(void) {
        while (self.index < self.count) {
            if (!budget.spend()) return .pending;
            const item = list.atUnchecked(self.moved, self.index);
            if (item != .port) {
                self.refusal = .not_a_port;
                return .complete;
            }
            self.ports[self.index] = item;
            self.index += 1;
        }
        return .complete;
    }

    fn advancePreparing(self: *GiveCursor, budget: *poll.WorkBudget) poll.Progress(void) {
        while (self.ready < self.count) {
            if (!budget.spend()) return .pending;
            self.prepared[self.ready] = heap.preparePortTransfer(
                self.ports[self.ready].?.port,
                self.origin,
                @ptrCast(self.destination.?),
            ) catch |err| {
                self.refusal = .{ .transfer = err };
                return .complete;
            };
            self.ready += 1;
        }
        return .complete;
    }

    fn advanceRollingBack(self: *GiveCursor, budget: *poll.WorkBudget) poll.Progress(void) {
        while (self.ready != 0) {
            if (!budget.spend()) return .pending;
            self.ready -= 1;
            if (self.prepared[self.ready]) |*transfer| transfer.abort();
            self.prepared[self.ready] = null;
        }
        return .complete;
    }

    fn advanceCommitting(self: *GiveCursor, budget: *poll.WorkBudget) poll.Progress(void) {
        while (self.ready != 0) {
            if (!budget.spend()) return .pending;
            self.ready -= 1;
            if (self.prepared[self.ready]) |*transfer| transfer.commit();
            self.prepared[self.ready] = null;
        }
        return .complete;
    }

    /// Run one phase to its end without yielding. Used for the phases that
    /// must not be interrupted; the work is bounded by the cursor's fixed
    /// storage, not by the caller's input.
    fn run(self: *GiveCursor, phase: Phase) void {
        self.phase = phase;
        var budget: poll.WorkBudget = .init(max_given_ports + 1);
        poll.driveVoid(self, .{&budget});
        self.phase = .done;
    }

    /// `ScopeTransfer` hooks. Preparation leaves every origin membership in
    /// place, so a refusal rolls back to exactly the state before the give.
    pub fn prepareScopeTransfer(
        self: *GiveCursor,
        destination: *scheduler_api.TaskScope,
    ) scheduler_api.ScopeTransferError!void {
        self.destination = destination;
        self.ready = 0;
        self.run(.preparing);
        switch (self.refusal) {
            .none => {},
            .not_a_port => unreachable,
            .transfer => |err| {
                self.run(.rolling_back);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Transfer,
                };
            },
        }
    }

    pub fn commitScopeTransfer(self: *GiveCursor) void {
        self.run(.committing);
    }

    pub fn abortScopeTransfer(self: *GiveCursor) void {
        self.run(.rolling_back);
    }
};

/// A `@give` moves at most this many ports. Validation is resumable, but
/// preparation and commit run inside `spawn` and cannot yield, so the count is
/// capped rather than unbounded: that is what keeps the phases which must be
/// atomic inside one scheduler step, and what lets the cursor hold its ports
/// in fixed storage. Realistic calls move one port.
pub const max_given_ports: usize = 16;

/// Validates the port list in bounded slices and then performs the spawn that
/// moves them, so an oversized list cannot occupy a scheduler step.
const GiveDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    moved: Value,
    seeds: Value,
    body: Value,
    cursor: GiveCursor,

    pub fn deinit(self: *GiveDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        _ = allocator;
        releases.releaseValue(self.body);
        releases.releaseValue(self.seeds);
        releases.releaseValue(self.moved);
    }

    pub fn advance(evaluator: *Machine, self: *GiveDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.cursor.phase == .validating) {
            var budget: poll.WorkBudget = .init(machine.kernel_poll_quantum);
            if (self.cursor.advance(&budget) == .pending) return .yielded;
            if (self.cursor.refusal == .not_a_port)
                return evaluator.typeError("a list of ports to give");
            self.cursor.phase = .done;
        }
        const task = try self.spawn(evaluator);
        return .{ .output = task };
    }

    fn spawn(self: *GiveDriver, evaluator: *Machine) MachineError!Value {
        const moved_count = self.cursor.count;
        const seed_count: usize = @intCast(self.seeds.list.length());
        // The child starts on the given ports, deepest, then the ordinary
        // values. Both lists are seeded in bounded slices by the child's seed
        // driver, so no concatenated copy is built here.
        const stack: machine.InitialStack = if (moved_count == 0 and seed_count == 0)
            .empty
        else if (moved_count == 0)
            .{ .borrowed_seeds = self.seeds.list }
        else
            .{ .borrowed_pair = .{ .deep = self.moved.list, .seeds = self.seeds.list } };
        return scheduler(evaluator).spawn(scope(evaluator), .{
            .parent_unit = evaluator.unit,
            .site = .{ .inherited = .{
                .scope = evaluator.currentScope(),
                .home = evaluator.currentHome(),
            } },
            .quotation = self.body.list,
            .initial_stack = stack,
            .constructor = .spawn,
            .transfer = scheduler_api.scopeTransfer(GiveCursor, &self.cursor),
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Io => evaluator.fail(.io, "could not start scheduler worker threads"),
            error.Transfer => switch (self.cursor.refusal.transfer) {
                error.NotOwner => evaluator.fail(
                    .domain,
                    "@give can only give a port owned by the calling unit",
                ),
                error.ScopeClosing => evaluator.fail(.cancelled, "the new unit's scope is closing"),
                error.Closed => evaluator.fail(.domain, "@give cannot give a closed port"),
                error.Busy => evaluator.fail(.domain, "@give cannot give the same port twice"),
                error.OutOfMemory => error.OutOfMemory,
            },
        };
    }
};

fn give(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var body = try evaluator.popQuotation();
    errdefer body.deinit();
    var seeds = try evaluator.popList();
    errdefer seeds.deinit();
    var moved = try evaluator.popList();
    errdefer moved.deinit();

    const moved_count: usize = @intCast(moved.borrow().list.length());
    if (moved_count > max_given_ports)
        return evaluator.fail(.domain, "@give accepts at most 16 ports at once");

    const driver = try evaluator.allocator().create(GiveDriver);
    // Bind the list before building the driver: reading `driver.moved` from
    // inside the literal that initializes it would depend on field order.
    const moved_list = moved.take();
    driver.* = .{
        .moved = moved_list,
        .seeds = seeds.take(),
        .body = body.take(),
        .cursor = .{
            .origin = evaluator.unit.task_scope.?,
            .moved = moved_list,
            .count = moved_count,
        },
    };
    evaluator.adoptDriver(driver);
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
