//! Language adapters for structured task operations.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const poll = @import("poll.zig");
const scheduler_api = @import("scheduler.zig");
const mailbox = @import("mailbox.zig");
const intern = @import("intern.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "@spawn", .primitive = spawn, .effect = "values quotation -- task", .doc = "*Unit constructor.* Initialize a child stack from the explicit values list and run the quotation concurrently. Use `[]` for no initial values; the ambient stack never crosses the boundary. Inside a module construction body, at any depth, this constructor is `` `domain ``: a module body defines words and starts no tasks (see Modules). See [Concurrency](SPEC.md#concurrency)." },
        .{ .name = "@spawn!", .primitive = spawnSeedless, .effect = "quotation -- task", .doc = "*Unit constructor.* `@spawn` with no values operand: the quotation runs on an empty stack, exactly as `[] (q) @spawn`." },
        .{ .name = "@give", .primitive = give, .effect = "ports values quotation -- task", .doc = "*Unit constructor.* Like `@spawn`, and additionally move every port in the ports list into the new unit, which owns them from before it starts running: the child's end closes them and the calling unit's end no longer does. The child stack is the given ports, deepest, then the explicit values. Use `[]` for no ports, which is exactly `@spawn`. Inside a module construction body, at any depth, this constructor is `` `domain ``: a module body defines words and starts no tasks (see Modules).\n\nEvery kind of port can be given: listeners, connections, and process ports alike. A port may only be given by the unit that owns it, so a unit holding a port another unit owns cannot give it away; that is `` `domain ``, as is giving a closed port or the same port twice. The move and the child's construction are one step: the port is never unowned, and the child never runs before it owns the port.\n\nAt most 16 ports may be given at once; more is `` `domain ``. That limit is checked before the list's elements are examined, so an oversized list of non-ports reports the limit rather than the element type. The ports list is otherwise validated in order, and a list holding a non-port is `` `type ``.\n\nGiving does not restrict use. The caller may still name a given port and read or write it, exactly as a child may use a port its parent owns; what changed is which unit's end closes it. See [Concurrency](SPEC.md#concurrency)." },
        .{ .name = "@give!", .primitive = giveSeedless, .effect = "ports quotation -- task", .doc = "*Unit constructor.* `@give` with no values operand: the child stack is the given ports alone, exactly as `ports [] (q) @give`." },
    };
    try core.installBuiltins(&definitions);
}

pub const words = [_]env.BuiltinWord{
    .{ .name = "await", .primitive = await, .effect = "task -- result", .doc = "Park until the task completes; return its cached `{ok …}`/`{err …}` result. Idempotent. See [Concurrency](SPEC.md#concurrency)." },
    .{ .name = "cancel", .primitive = cancel, .effect = "task --", .doc = "Request cancellation; the task's result becomes `{err {kind cancelled …}}`. No-op when already terminal." },
    .{ .name = "cancel-self", .primitive = cancelSelf, .effect = "--", .doc = "Request cancellation of the current task, exactly as `task.cancel` does with its handle. It is only a request: execution continues, and the task observes it at its next safe point. `` `domain `` outside a task. There is deliberately no way to obtain the current task's handle, so a task's result can never retain its own task." },
    .{ .name = "pending", .primitive = tasks, .effect = "-- tasks", .doc = "Pending descendant tasks in deterministic spawn preorder." },
    .{ .name = "await-any", .primitive = awaitAny, .effect = "tasks -- index result", .doc = "Race a nonempty all-task list; among tasks already terminal at entry the lowest index wins, otherwise the first completion." },
    .{ .name = "await-for", .primitive = awaitFor, .effect = "task milliseconds -- result", .doc = "`task.await` with a nonnegative int deadline; expiry returns `{err {kind timeout}}` without cancelling the task. A terminal task beats even a zero deadline. A deadline beyond any instant the scheduler clock can report is `` `overflow `` before the wait registers." },
    .{ .name = "address", .primitive = address, .effect = "task -- address", .doc = "The address of a task's mailbox. Two addresses of one task match. An address outlives its task; after the task ends it names a closed mailbox." },
    .{ .name = "self", .primitive = selfAddress, .effect = "-- address", .doc = "The executing task's own address. `` `domain `` outside a task: the session root owns tasks but has no mailbox." },
    .{ .name = "send", .primitive = send, .effect = "value address --", .doc = "Queue a value in the mailbox an address names. Any value may be sent except one containing a task handle, which is `` `type ``; addresses and ports pass. A mailbox holds sixteen messages, and a sender to a full one parks until the receiver takes a message. Sending to a task that has ended is `` `io `` with `` `reason `closed ``. Messages from one sender arrive in order; order across senders is unspecified." },
    .{ .name = "receive", .primitive = receive, .effect = "-- value", .doc = "Take the oldest message from the executing task's mailbox, parking until one arrives. `` `domain `` outside a task." },
    .{ .name = "receive-for", .primitive = receiveFor, .effect = "milliseconds -- result", .doc = "`task.receive` with a nonnegative int deadline: `{ok value}`, or `{err {kind timeout}}` when nothing arrives in time. A deadline beyond any instant the scheduler clock can report is `` `overflow ``. `` `domain `` outside a task." },
};

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

/// A module body defines words and starts no tasks. Refusing at the
/// constructor, before any operand is consumed, keeps every task owned by a
/// task or the session root and never by an image under construction.
fn refuseDuringConstruction(evaluator: *Machine, comptime constructor: []const u8) MachineError!void {
    if (evaluator.unit.inModuleConstruction()) return evaluator.fail(
        .domain,
        constructor ++ " is legal only outside module construction: a module body defines words and starts no tasks",
    );
}

fn spawn(evaluator: *Machine) MachineError!void {
    try refuseDuringConstruction(evaluator, "@spawn");
    try spawnInput(evaluator, try evaluator.popUnitInput());
}

fn spawnSeedless(evaluator: *Machine) MachineError!void {
    try refuseDuringConstruction(evaluator, "@spawn!");
    try spawnInput(evaluator, try evaluator.popSeedlessUnitInput());
}

fn spawnInput(evaluator: *Machine, popped: machine.OwnedUnitInput) MachineError!void {
    var input = popped;
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
        var budget = poll.unbounded();
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
    /// Null for `@give!`, which takes no values operand.
    seeds: ?Value,
    body: Value,
    cursor: GiveCursor,

    pub fn deinit(self: *GiveDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        _ = allocator;
        releases.releaseValue(self.body);
        if (self.seeds) |seeds| releases.releaseValue(seeds);
        releases.releaseValue(self.moved);
    }

    pub fn advance(evaluator: *Machine, self: *GiveDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.cursor.phase == .validating) {
            if (self.cursor.advance(evaluator.workBudget()) == .pending) return .stepped;
            if (self.cursor.refusal == .not_a_port)
                return evaluator.typeError("a list of ports to give");
            self.cursor.phase = .done;
        }
        const task = try self.spawn(evaluator);
        return .{ .output = task };
    }

    fn spawn(self: *GiveDriver, evaluator: *Machine) MachineError!Value {
        const moved_count = self.cursor.count;
        const seed_count: usize = if (self.seeds) |seeds| @intCast(seeds.list.length()) else 0;
        // The child starts on the given ports, deepest, then the ordinary
        // values. Both lists are seeded in bounded slices by the child's seed
        // driver, so no concatenated copy is built here.
        const stack: machine.InitialStack = if (moved_count == 0 and seed_count == 0)
            .empty
        else if (moved_count == 0)
            .{ .borrowed_seeds = self.seeds.?.list }
        else if (seed_count == 0)
            // Ports alone seed exactly as an explicit values list would.
            .{ .borrowed_seeds = self.moved.list }
        else
            .{ .borrowed_pair = .{ .deep = self.moved.list, .seeds = self.seeds.?.list } };
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
    try refuseDuringConstruction(evaluator, "@give");
    try evaluator.require(3);
    var body = try evaluator.popQuotation();
    defer body.deinit();
    var seeds = try evaluator.popList();
    defer seeds.deinit();
    try giveInput(evaluator, &body, &seeds);
}

fn giveSeedless(evaluator: *Machine) MachineError!void {
    try refuseDuringConstruction(evaluator, "@give!");
    try evaluator.require(2);
    var body = try evaluator.popQuotation();
    defer body.deinit();
    try giveInput(evaluator, &body, null);
}

/// Takes the body and seeds only once the driver owns them; on failure the
/// callers' owners still release them.
fn giveInput(evaluator: *Machine, body: *heap.OwnedValue, seeds: ?*heap.OwnedValue) MachineError!void {
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
        .seeds = if (seeds) |owned| owned.take() else null,
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

fn cancelSelf(evaluator: *Machine) MachineError!void {
    if (!scheduler(evaluator).cancelScopeOwner(scope(evaluator)))
        return evaluator.fail(.domain, "task.cancel-self is legal only inside a task");
}

fn address(evaluator: *Machine) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    try evaluator.pushOwned(try scheduler(evaluator).taskAddress(task.borrow()));
}

fn selfAddress(evaluator: *Machine) MachineError!void {
    const own = try ownMailbox(evaluator, "task.self");
    try evaluator.pushOwned(try own.createAddress(evaluator.unit.allocator));
}

/// The executing task's mailbox. The root has none: it owns tasks but is
/// not one, so nothing could ever address it.
fn ownMailbox(evaluator: *Machine, comptime word: []const u8) MachineError!*mailbox.Mailbox {
    return scheduler(evaluator).currentMailbox(scope(evaluator)) orelse
        evaluator.fail(.domain, word ++ " is legal only inside a task");
}

fn send(evaluator: *Machine) MachineError!void {
    const pair = try evaluator.popPair();
    var payload = pair[0];
    defer payload.deinit();
    var target = pair[1];
    defer target.deinit();
    if (target.borrow() != .address) return evaluator.typeError("a value followed by an address");
    const check = try mailbox.HandleCheck.init(evaluator.unit.allocator, payload.borrow());
    try evaluator.startDriver(SendDriver{
        .payload = .init(payload.take()),
        .target = .init(target.take()),
        .check = .init(check),
    });
}

/// Checks the payload for handles under the work budget, then queues it,
/// parking for space while the target is full. The address value keeps the
/// mailbox alive across the park.
const SendDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    payload: heap.Owned(Value),
    target: heap.Owned(Value),
    check: heap.Owned(mailbox.HandleCheck),
    checked: bool = false,

    pub fn advance(evaluator: *Machine, self: *SendDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (!self.checked) {
            const progress = self.check.borrowMut().advance(evaluator.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Handle => return evaluator.fail(.type, "task.send cannot carry a task handle"),
            };
            if (progress == .pending) return .stepped;
            self.checked = true;
        }
        const target = mailbox.Mailbox.fromAddress(self.target.borrow());
        switch (target.enqueue(.{ .value = self.payload.borrow() })) {
            .accepted => {
                _ = self.payload.take();
                return .completed;
            },
            .closed => {
                const reason = try intern.intern("closed");
                const failure = evaluator.fail(.io, "task.send target has ended and its mailbox is closed");
                evaluator.addErrorReason(.{ .symbol = .{ .name = reason } });
                return failure;
            },
            .full => {
                try evaluator.park(.{ .mailbox = .{ .source = target.readinessSource(.space), .deadline = null } });
                return .{ .yielded = .park };
            },
        }
    }
};

fn receive(evaluator: *Machine) MachineError!void {
    _ = try ownMailbox(evaluator, "task.receive");
    try evaluator.startDriver(ReceiveDriver{ .deadline = null });
}

fn receiveFor(evaluator: *Machine) MachineError!void {
    var duration = try evaluator.popValue();
    defer duration.deinit();
    if (duration.borrow() != .int) return evaluator.typeError("an integer millisecond duration");
    if (duration.borrow().int < 0) return evaluator.fail(.domain, "task.receive-for duration must be nonnegative");
    _ = try ownMailbox(evaluator, "task.receive-for");
    const milliseconds: u63 = @intCast(duration.borrow().int);
    const deadline = scheduler(evaluator).deadlineAfter(milliseconds) catch
        return evaluator.fail(.overflow, "task.receive-for deadline lies beyond the clock's range");
    try evaluator.startDriver(ReceiveDriver{ .deadline = deadline });
}

/// Polls the executing task's own mailbox and parks until a message or the
/// deadline wakes it; the deadline is checked against the scheduler clock
/// after every wake, so a late message still wins over a timeout.
const ReceiveDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    deadline: ?scheduler_api.Deadline,

    pub fn advance(evaluator: *Machine, self: *ReceiveDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const own = scheduler(evaluator).currentMailbox(scope(evaluator)).?;
        if (own.dequeue()) |message| {
            if (self.deadline == null) return .{ .output = message.value };
            return .{ .output = try machine.outcomeDict(
                evaluator.unit.allocator,
                evaluator.releaseDomain(),
                "ok",
                message.value,
            ) };
        }
        if (self.deadline) |deadline| {
            if (deadline.reachedBy(scheduler(evaluator).now())) {
                var timeout = machine.EclErr.init(.timeout, "task.receive-for timed out");
                defer timeout.retire(evaluator.releaseDomain());
                const failure = try machine.errorValue(
                    evaluator.unit.allocator,
                    evaluator.releaseDomain(),
                    &timeout,
                    .{},
                    null,
                );
                return .{ .output = try machine.outcomeDict(
                    evaluator.unit.allocator,
                    evaluator.releaseDomain(),
                    "err",
                    failure,
                ) };
            }
        }
        try evaluator.park(.{ .mailbox = .{ .source = own.readinessSource(.receive), .deadline = self.deadline } });
        return .{ .yielded = .park };
    }
};

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
        return evaluator.fail(.domain, "task.await-any requires a nonempty list");
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
    if (duration.borrow().int < 0) return evaluator.fail(.domain, "task.await-for duration must be nonnegative");
    const milliseconds: u63 = @intCast(duration.borrow().int);
    scheduler(evaluator).checkDeadline(milliseconds) catch
        return evaluator.fail(.overflow, "task.await-for deadline lies beyond the clock's range");
    try evaluator.park(.{ .deadline = .{
        .task = task.take(),
        .milliseconds = milliseconds,
    } });
}

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
        const end = self.index + evaluator.workBudget().take(count - self.index);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(task_values, self.index) != .task) {
                return evaluator.failAtIndex(
                    .type,
                    "task.await-any expected only tasks",
                    self.index,
                );
            }
        }
        if (self.index != count) return .stepped;
        _ = self.tasks.?.take();
        self.tasks = null;
        evaluator.retireDriver(self);
        try evaluator.park(.{ .any = task_values });
        return .detached;
    }
};
