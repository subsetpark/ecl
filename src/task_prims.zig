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
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "@spawn", .primitive = spawn, .effect = "quotation -- task", .doc = "Run the quotation concurrently on an empty child stack; the ambient stack never crosses the boundary. To start the child on values, build them into the quotation: `values (q) cat @spawn`. Inside a module construction body, at any depth, this constructor is `` `domain ``: a module body defines words and starts no tasks (see Modules). See [Concurrency](SPEC.md#concurrency)." },
        .{ .name = "@give", .primitive = give, .effect = "ports quotation -- task", .doc = "Like `@spawn`, with the additional behaviour of reassigning every port in `ports` to the new unit. The child stack starts with the ports, in list order. \n\nIncluding a port in `ports` which isn't owned by the calling unit is `` `domain ``, as is giving a closed port or the same port twice. At most 16 ports may be given at once; more is `` `domain ``. The transfer is all-or-nothing: on any refusal, no port changes owner.\n\nOwnership doesn't determine what unit(s) a port is accessible from, but which unit controls its lifetime. See [Concurrency](SPEC.md#concurrency)." },
    };
    try core.installBuiltins(&definitions);
}

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Task handles are created by the core unit constructors `@spawn` and `@give`. A handle
    \\observes a task's lifetime and result. `task.address` derives the task's address, which
    \\names only its mailbox, and `task.self` is the executing task's own. Use `(task.await) each`
    \\to collect results in input order without cancelling siblings or re-raising task errors.
    \\
    \\Request and reply is a composition over `send` and `receive`: spawn a helper task, send its
    \\address with the request, and await the helper, whose result is the reply. `task.await-for`
    \\bounds the exchange.
;

pub const words = [_]env.BuiltinWord{
    .{ .name = "await", .primitive = await, .effect = "task -- result", .doc = "Park until the task completes; return its cached `{ok …}`/`{err …}` result. Idempotent. See [Concurrency](SPEC.md#concurrency)." },
    .{ .name = "cancel", .primitive = cancel, .effect = "task --", .doc = "Request cancellation; the task's result becomes `{err {kind cancelled …}}`. No-op when already terminal." },
    .{ .name = "cancel-self", .primitive = cancelSelf, .effect = "--", .doc = "Request cancellation of the current task." },
    .{ .name = "pending", .primitive = tasks, .effect = "-- tasks", .doc = "Pending descendant tasks in deterministic spawn preorder." },
    .{ .name = "await-any", .primitive = awaitAny, .effect = "tasks -- index result", .doc = "Race a nonempty all-task list; among tasks already terminal at entry the lowest index wins, otherwise the first completion." },
    .{ .name = "await-for", .primitive = awaitFor, .effect = "task milliseconds -- result", .doc = "`task.await` with a nonnegative int deadline; expiry returns `{err {kind timeout}}` without cancelling the task. A terminal task beats even a zero deadline. A deadline beyond any instant the scheduler clock can report is `` `overflow `` before the wait registers." },
    .{ .name = "address", .primitive = address, .effect = "task -- address", .doc = "The address of a task's mailbox. Two addresses of one task match. An address outlives its task; after the task ends it names a closed mailbox." },
    .{ .name = "self", .primitive = selfAddress, .effect = "-- address", .doc = "The executing task's own address. `` `domain `` outside a task: the session root owns tasks but has no mailbox." },
    .{ .name = "send", .primitive = send, .effect = "address value --", .doc = "Queue a value in the mailbox an address names. Any value may be sent except one containing a task handle, which is `` `type ``; addresses and ports pass. A mailbox holds sixteen messages, and a sender to a full one parks until the receiver takes a message. Sending to a task that has ended is `` `io `` with `` `reason `closed ``. Messages from one sender arrive in order; order across senders is unspecified." },
    .{ .name = "receive", .primitive = receive, .effect = "-- value", .doc = "Take the oldest message from the executing task's mailbox, parking until one arrives. `` `domain `` outside a task." },
    .{ .name = "receive-for", .primitive = receiveFor, .effect = "milliseconds -- result", .doc = "`task.receive` with a nonnegative int deadline: `{ok value}`, or `{err {kind timeout}}` when nothing arrives in time. A deadline beyond any instant the scheduler clock can report is `` `overflow ``. `` `domain `` outside a task." },
};

fn spawnTask(
    evaluator: *Fiber,
    quotation: *value.ListHandle,
) MachineError!Value {
    return evaluator.scheduler.?.spawn(evaluator.task_scope.?, .{
        .parent_fiber = evaluator,
        .site = .{ .inherited = evaluator.currentScope() },
        .quotation = quotation,
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
fn refuseDuringConstruction(evaluator: *Fiber, comptime constructor: []const u8) MachineError!void {
    if (evaluator.inModuleConstruction()) return evaluator.fail(
        .domain,
        constructor ++ " is legal only outside module construction: a module body defines words and starts no tasks",
    );
}

fn spawn(evaluator: *Fiber) MachineError!void {
    try refuseDuringConstruction(evaluator, "@spawn");
    var body = try evaluator.popQuotation();
    defer body.deinit();
    const task = try spawnTask(evaluator, body.borrow().list);
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
pub const GiveCursor = struct {
    const Phase = enum { validating, preparing, rolling_back, committing, done };

    /// What stopped the cursor, for the prim to turn into a language error.
    const Refusal = union(enum) {
        none,
        not_a_port,
        transfer: heap.PortTransferError,
    };

    origin: *heap.ScopeIdentity,
    moved: Value,
    count: usize,
    /// Filled by validation, then read by preparation. An unused slot is
    /// `null` rather than uninitialized, so the cursor has no garbage state.
    ports: [max_given_ports]?Value = @splat(null),
    prepared: [max_given_ports]?heap.PortTransfer = @splat(null),
    destination: ?*scheduler_api.TaskScope = null,
    /// Room on the child's stack for every port, reserved by prepare and
    /// filled by commit, so the child holds a port only once it owns it.
    child_stack: ?machine.StackReservation = null,
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
                self.destination.?.identity(),
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

    /// `SpawnRequest.transfer` hooks. Preparation reserves the child's stack
    /// before it touches a membership, and leaves every origin membership in
    /// place, so a refusal rolls back to exactly the state before the give.
    pub fn prepareScopeTransfer(
        self: *GiveCursor,
        destination: *scheduler_api.TaskScope,
        child: *machine.Fiber,
    ) scheduler_api.ScopeTransferError!void {
        self.child_stack = try child.reserveStack(self.count);
        self.destination = destination;
        self.ready = 0;
        self.run(.preparing);
        switch (self.refusal) {
            .none => {},
            .not_a_port => unreachable,
            .transfer => |err| {
                self.child_stack = null;
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
        var stack = self.child_stack.?;
        self.child_stack = null;
        for (self.ports[0..self.count]) |port| stack.pushBorrowed(port.?);
        std.debug.assert(stack.complete());
    }

    /// The reservation needs no undo: the spawn that failed discards the
    /// child, and its stack is still empty.
    pub fn abortScopeTransfer(self: *GiveCursor) void {
        self.child_stack = null;
        self.run(.rolling_back);
    }
};

const max_given_ports = machine.max_given_ports;

/// Validates the port list in bounded slices and then performs the spawn that
/// moves them, so an oversized list cannot occupy a scheduler step.
const GiveDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    moved: Value,
    body: Value,
    cursor: GiveCursor,

    pub fn deinit(self: *GiveDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        _ = allocator;
        releases.releaseValue(self.body);
        releases.releaseValue(self.moved);
    }

    pub fn advance(evaluator: *Fiber, self: *GiveDriver) MachineError!machine.WorkProgress {
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

    fn spawn(self: *GiveDriver, evaluator: *Fiber) MachineError!Value {
        return evaluator.scheduler.?.spawn(evaluator.task_scope.?, .{
            .parent_fiber = evaluator,
            .site = .{ .inherited = evaluator.currentScope() },
            .quotation = self.body.list,
            .transfer = &self.cursor,
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

/// Takes the body only once the driver owns it; on failure its owner here
/// still releases it.
fn give(evaluator: *Fiber) MachineError!void {
    try refuseDuringConstruction(evaluator, "@give");
    try evaluator.require(2);
    var body = try evaluator.popQuotation();
    defer body.deinit();
    var moved = try evaluator.popList();
    errdefer moved.deinit();

    const moved_count: usize = @intCast(moved.borrow().list.length());
    if (moved_count > max_given_ports)
        return evaluator.fail(.domain, "@give accepts at most 16 ports at once");

    const driver = try evaluator.allocator.create(GiveDriver);
    // Bind the list before building the driver: reading `driver.moved` from
    // inside the literal that initializes it would depend on field order.
    const moved_list = moved.take();
    driver.* = .{
        .moved = moved_list,
        .body = body.take(),
        .cursor = .{
            .origin = evaluator.task_scope.?.identity(),
            .moved = moved_list,
            .count = moved_count,
        },
    };
    evaluator.adoptDriver(driver);
}

fn await(evaluator: *Fiber) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    try evaluator.park(.{ .task = task.take() });
}

fn cancel(evaluator: *Fiber) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    evaluator.scheduler.?.cancelOwned(task.take());
}

fn cancelSelf(evaluator: *Fiber) MachineError!void {
    if (!evaluator.scheduler.?.cancelScopeOwner(evaluator.task_scope.?))
        return evaluator.fail(.domain, "task.cancel-self is legal only inside a task");
}

fn address(evaluator: *Fiber) MachineError!void {
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task");
    try evaluator.pushOwned(try evaluator.scheduler.?.taskAddress(task.borrow()));
}

fn selfAddress(evaluator: *Fiber) MachineError!void {
    const own = try ownMailbox(evaluator, "task.self");
    try evaluator.pushOwned(try own.createAddress(evaluator.allocator));
}

/// The executing task's mailbox. The root has none: it owns tasks but is
/// not one, so nothing could ever address it.
fn ownMailbox(evaluator: *Fiber, comptime word: []const u8) MachineError!*mailbox.Mailbox {
    return evaluator.scheduler.?.currentMailbox(evaluator.task_scope.?) orelse
        evaluator.fail(.domain, word ++ " is legal only inside a task");
}

fn send(evaluator: *Fiber) MachineError!void {
    const pair = try evaluator.popPair();
    var target = pair[0];
    defer target.deinit();
    var payload = pair[1];
    defer payload.deinit();
    if (target.borrow() != .address) return evaluator.typeError("an address followed by a value");
    const check = try mailbox.HandleCheck.init(evaluator.allocator, payload.borrow());
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

    pub fn advance(evaluator: *Fiber, self: *SendDriver) MachineError!machine.WorkProgress {
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

fn receive(evaluator: *Fiber) MachineError!void {
    _ = try ownMailbox(evaluator, "task.receive");
    try evaluator.startDriver(ReceiveDriver{ .deadline = null });
}

fn receiveFor(evaluator: *Fiber) MachineError!void {
    var duration = try evaluator.popValue();
    defer duration.deinit();
    if (duration.borrow() != .int) return evaluator.typeError("an integer millisecond duration");
    if (duration.borrow().int < 0) return evaluator.fail(.domain, "task.receive-for duration must be nonnegative");
    _ = try ownMailbox(evaluator, "task.receive-for");
    const milliseconds: u63 = @intCast(duration.borrow().int);
    const deadline = evaluator.scheduler.?.deadlineAfter(milliseconds) catch
        return evaluator.fail(.overflow, "task.receive-for deadline lies beyond the clock's range");
    try evaluator.startDriver(ReceiveDriver{ .deadline = deadline });
}

/// Polls the executing task's own mailbox and parks until a message or the
/// deadline wakes it; the deadline is checked against the scheduler clock
/// after every wake, so a late message still wins over a timeout.
const ReceiveDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    deadline: ?scheduler_api.Deadline,

    pub fn advance(evaluator: *Fiber, self: *ReceiveDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const own = evaluator.scheduler.?.currentMailbox(evaluator.task_scope.?).?;
        if (own.dequeue()) |message| {
            if (self.deadline == null) return .{ .output = message.value };
            return .{ .output = try machine.outcomeDict(
                evaluator.allocator,
                evaluator.releases,
                "ok",
                message.value,
            ) };
        }
        if (self.deadline) |deadline| {
            if (deadline.reachedBy(evaluator.scheduler.?.now())) {
                var timeout = machine.EclErr.init(.timeout, "task.receive-for timed out");
                defer timeout.retire(evaluator.releases);
                const failure = try machine.errorValue(
                    evaluator.allocator,
                    evaluator.releases,
                    &timeout,
                    .{},
                    null,
                );
                return .{ .output = try machine.outcomeDict(
                    evaluator.allocator,
                    evaluator.releases,
                    "err",
                    failure,
                ) };
            }
        }
        try evaluator.park(.{ .mailbox = .{ .source = own.readinessSource(.receive), .deadline = self.deadline } });
        return .{ .yielded = .park };
    }
};

fn tasks(evaluator: *Fiber) MachineError!void {
    try evaluator.scheduler.?.installTasksDriver(evaluator, evaluator.task_scope.?);
}

fn awaitAny(evaluator: *Fiber) MachineError!void {
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

fn awaitFor(evaluator: *Fiber) MachineError!void {
    try evaluator.require(2);
    var duration = try evaluator.popValue();
    defer duration.deinit();
    var task = try evaluator.popValue();
    defer task.deinit();
    if (task.borrow() != .task) return evaluator.typeError("a task followed by milliseconds");
    if (duration.borrow() != .int) return evaluator.typeError("an integer millisecond duration");
    if (duration.borrow().int < 0) return evaluator.fail(.domain, "task.await-for duration must be nonnegative");
    const milliseconds: u63 = @intCast(duration.borrow().int);
    evaluator.scheduler.?.checkDeadline(milliseconds) catch
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
        evaluator: *Fiber,
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
