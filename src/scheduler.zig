//! Fixed worker pool, write-once task cells, and structured task scopes.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const kernel_storage = @import("kernel_storage.zig");
const machine = @import("machine.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const core = @import("scheduler_core.zig");

const Value = value.Value;
const ListHandle = value.ListHandle;
const TaskHandle = value.TaskHandle;

fn blockingIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn unitDecision(before: core.Unit, event: core.UnitEvent) core.UnitDecision {
    return core.decideUnit(before, event) catch @panic("invalid scheduler unit transition");
}

fn waitDecision(before: core.Wait, event: core.WaitEvent) core.WaitDecision {
    return core.decideWait(before, event) catch @panic("invalid scheduler wait transition");
}

fn registrationDecision(
    before: core.Registration,
    event: core.RegistrationEvent,
) core.RegistrationDecision {
    return core.decideRegistration(before, event) catch
        @panic("invalid scheduler registration transition");
}

fn scopeDecision(before: core.Scope, event: core.ScopeEvent) core.ScopeDecision {
    return core.decideScope(before, event) catch @panic("invalid scheduler scope transition");
}

pub const Config = union(enum) {
    cooperative,
    worker_pool: usize,

    pub fn validate(self: Config) error{InvalidWorkerCount}!void {
        switch (self) {
            .cooperative => {},
            .worker_pool => |count| if (count == 0) return error.InvalidWorkerCount,
        }
    }

    fn isCooperative(self: Config) bool {
        return self == .cooperative;
    }
};

const TerminalState = union(enum) {
    outcome: Value,
    oom,
};

const WaitKind = enum { one, any, deadline };
const Finish = enum { success, language_error, oom };

const FinishingWork = union(enum) {
    out_of_memory,
    language_error,
    success_unstarted,
    success_materializing: kernel_storage.ValueMaterializer,
    ready: TerminalState,
};

const ExecutionPhase = union(enum) {
    evaluating,
    finishing: FinishingWork,
};

const TaskExecution = struct {
    unit: machine.Unit,
    phase: ExecutionPhase = .evaluating,
};

/// Owns either an unpublished execution or a terminal result. The execution's
/// worker-private phase may advance without mutating the publication tag that
/// waiters inspect under the cell lock.
const TaskPublication = union(enum) {
    constructing,
    active: *TaskExecution,
    published: TerminalState,
};

const TaskHeaderState = union(enum) {
    unpublished,
    published: *TaskHandle,
};

const ParentMembership = union(enum) {
    detached: *TaskScope,
    linked: struct {
        scope: *TaskScope,
        previous: ?*TaskCell = null,
        next: ?*TaskCell = null,
    },
};

const RootWaiter = struct {
    scheduler: *const WorkerScheduler,
    unit: *machine.Unit,
    ready: std.atomic.Value(bool) = .init(false),
};

const WaitOwner = union(enum) {
    task: *TaskCell,
    root: *RootWaiter,
};

const QueueItem = union(enum) {
    task: *TaskCell,
    cancellation: *TaskCell,
    wait: *WaitSet,
};

const QueueEntry = struct {
    item: QueueItem,
    membership: union(enum) { detached, linked: ?*QueueEntry } = .detached,
};

const ExecutorArbitration = struct {
    const Turn = enum { ready, retirement };
    next: Turn = .ready,

    fn choose(self: *ExecutorArbitration, ready: bool, retirement: bool) ?Turn {
        if (!ready and !retirement) return null;
        if (!ready) return .retirement;
        if (!retirement) return .ready;
        const selected = self.next;
        self.next = if (selected == .ready) .retirement else .ready;
        return selected;
    }
};

const WaitRegistration = struct {
    wait: *WaitSet,
    refs: std.atomic.Value(usize) = .init(1),
    cell: ?*TaskCell = null,
    index: u32 = 0,
    previous: ?*WaitRegistration = null,
    next: ?*WaitRegistration = null,
    phase: core.Registration = .directory,

    fn retain(self: *WaitRegistration) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(usize));
    }

    fn release(self: *WaitRegistration) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        std.debug.assert(self.phase == .retired);
        self.wait.registrationRetired();
    }
};

const TimerNode = struct {
    wait: *WaitSet,
    deadline: std.Io.Timestamp = .zero,
    membership: union(enum) { detached, linked: usize } = .detached,
};

const timer_chunk_capacity = 64;
const TimerChunk = [timer_chunk_capacity]?*TimerNode;

const TimerHeap = struct {
    chunks: std.ArrayList(*TimerChunk) = .empty,
    len: usize = 0,

    fn deinit(self: *TimerHeap, allocator: std.mem.Allocator) void {
        std.debug.assert(self.len == 0);
        for (self.chunks.items) |chunk| allocator.destroy(chunk);
        self.chunks.deinit(allocator);
        self.* = .{};
    }

    fn peek(self: *const TimerHeap) ?*TimerNode {
        if (self.len == 0) return null;
        return self.get(0);
    }

    fn insert(
        self: *TimerHeap,
        allocator: std.mem.Allocator,
        node: *TimerNode,
    ) error{OutOfMemory}!void {
        std.debug.assert(node.membership == .detached);
        if (self.len == self.chunks.items.len * timer_chunk_capacity) {
            const chunk = try allocator.create(TimerChunk);
            errdefer allocator.destroy(chunk);
            chunk.* = [_]?*TimerNode{null} ** timer_chunk_capacity;
            try self.chunks.append(allocator, chunk);
        }
        const index = self.len;
        self.len += 1;
        self.set(index, node);
        node.membership = .{ .linked = index };
        self.siftUp(index);
    }

    fn remove(self: *TimerHeap, node: *TimerNode) void {
        const index = switch (node.membership) {
            .linked => |linked| linked,
            .detached => unreachable,
        };
        std.debug.assert(index < self.len and self.get(index) == node);
        const last_index = self.len - 1;
        const last = self.get(last_index);
        self.set(last_index, null);
        self.len = last_index;
        node.membership = .detached;
        if (index == last_index) return;
        self.set(index, last);
        last.membership = .{ .linked = index };
        if (index > 0 and earlier(last, self.get((index - 1) / 2)))
            self.siftUp(index)
        else
            self.siftDown(index);
    }

    fn siftUp(self: *TimerHeap, initial: usize) void {
        var index = initial;
        while (index > 0) {
            const parent = (index - 1) / 2;
            if (!earlier(self.get(index), self.get(parent))) return;
            self.swap(index, parent);
            index = parent;
        }
    }

    fn siftDown(self: *TimerHeap, initial: usize) void {
        var index = initial;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.len) return;
            const right = left + 1;
            const child = if (right < self.len and earlier(self.get(right), self.get(left)))
                right
            else
                left;
            if (!earlier(self.get(child), self.get(index))) return;
            self.swap(index, child);
            index = child;
        }
    }

    fn swap(self: *TimerHeap, left: usize, right: usize) void {
        const left_node = self.get(left);
        const right_node = self.get(right);
        self.set(left, right_node);
        self.set(right, left_node);
        left_node.membership = .{ .linked = right };
        right_node.membership = .{ .linked = left };
    }

    fn get(self: *const TimerHeap, index: usize) *TimerNode {
        return self.chunks.items[index / timer_chunk_capacity].*[index % timer_chunk_capacity].?;
    }

    fn set(self: *TimerHeap, index: usize, node: ?*TimerNode) void {
        self.chunks.items[index / timer_chunk_capacity].*[index % timer_chunk_capacity] = node;
    }

    fn earlier(left: *const TimerNode, right: *const TimerNode) bool {
        return left.deadline.nanoseconds < right.deadline.nanoseconds;
    }
};

const WaitSet = struct {
    allocator: std.mem.Allocator,
    scheduler: *const WorkerScheduler,
    owner: WaitOwner,
    kind: WaitKind,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    policy: core.Wait = .registering,
    queue: QueueEntry,
    registrations: []WaitRegistration,
    canonical: []CanonicalSlot,
    initialized: usize = 0,
    canonical_initialized: usize = 0,
    wake_handles: usize = 0,
    awaiting_handles: bool = false,
    request: ?machine.ParkRequest,
    setup_phase: SetupPhase = .initialize,
    setup_index: usize = 0,
    probe_index: usize = 0,
    cancel_index: usize = 0,
    cancel_cursor: ?CancellationCursor = null,
    discarding: bool = false,
    delivery_reason: ?core.WakeReason = null,
    park_result: ?machine.ParkResume = null,
    cleanup_index: usize = 0,
    cell_release_index: usize = 0,
    timer: TimerNode,
    absolute_deadline: ?std.Io.Timestamp = null,

    const SetupPhase = enum {
        initialize,
        cancel_join_tail,
        find_duplicate,
        register,
        timer,
        release_request,
        activate,
        complete,
    };

    const CanonicalSlot = struct {
        cell: ?*TaskCell = null,
        index: u32 = 0,
    };

    const DeliveryProgress = enum { yielded, waiting, complete };

    fn create(
        scheduler: *const WorkerScheduler,
        owner: WaitOwner,
        request: machine.ParkRequest,
    ) error{OutOfMemory}!*WaitSet {
        const kind = requestKind(request);
        const count = request.taskCount();
        const self = try scheduler.allocator().create(WaitSet);
        errdefer scheduler.allocator().destroy(self);
        const registrations = try scheduler.allocator().alloc(WaitRegistration, count);
        errdefer scheduler.allocator().free(registrations);
        const canonical_capacity = if (kind == .any) capacity: {
            const doubled = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
            break :capacity std.math.ceilPowerOfTwo(usize, @max(doubled, 2)) catch
                return error.OutOfMemory;
        } else 0;
        const canonical = try scheduler.allocator().alloc(CanonicalSlot, canonical_capacity);
        errdefer scheduler.allocator().free(canonical);
        self.* = .{
            .allocator = scheduler.allocator(),
            .scheduler = scheduler,
            .owner = owner,
            .kind = kind,
            .registrations = registrations,
            .canonical = canonical,
            .request = request,
            .timer = .{ .wait = self },
            .queue = .{ .item = .{ .wait = self } },
        };
        return self;
    }

    fn retain(self: *WaitSet) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(usize));
    }

    fn release(self: *WaitSet) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        std.debug.assert(self.wake_handles == 0);
        std.debug.assert(self.timer.membership == .detached);
        std.debug.assert(self.registrations.len == 0);
        std.debug.assert(self.canonical.len == 0);
        std.debug.assert(self.request == null);
        std.debug.assert(self.cancel_cursor == null);
        self.allocator.destroy(self);
    }

    fn registrationRetired(self: *WaitSet) void {
        var enqueue = false;
        std.Io.Threaded.mutexLock(&self.mutex);
        std.debug.assert(self.wake_handles != 0);
        self.wake_handles -= 1;
        if (self.wake_handles == 0 and self.awaiting_handles) {
            self.awaiting_handles = false;
            enqueue = true;
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (enqueue) self.scheduler.enqueueWait(self);
    }

    fn select(self: *WaitSet, candidate: core.WakeReason) void {
        // Delivery releases the owner and registration leases. A selector
        // needs an independent lease because a competing selector can perform
        // that delivery while this call is still observing the winner.
        self.retain();
        defer self.release();
        std.Io.Threaded.mutexLock(&self.mutex);
        const arbitrated = self.arbitrateDeadlineLocked(candidate);
        const decision = waitDecision(
            self.policy,
            .{ .candidate = arbitrated },
        );
        self.policy = decision.next;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.performWaitCommand(decision.command);
    }

    fn arbitrateDeadlineLocked(
        self: *WaitSet,
        candidate: core.WakeReason,
    ) core.WakeReason {
        const deadline = self.absolute_deadline orelse return candidate;
        return switch (self.policy) {
            .registering, .active => if (std.Io.Clock.awake.now(blockingIo()).nanoseconds >= deadline.nanoseconds)
                .timeout
            else
                candidate,
            .selected, .delivered => candidate,
        };
    }

    fn addTimer(self: *WaitSet, milliseconds: i64) error{ Io, OutOfMemory }!void {
        // The wait's semantic deadline starts before lazy infrastructure work.
        // A deadline that expires while the timer thread is being created is
        // resolved here while selectors are excluded, so startup latency can
        // neither extend the timeout nor let a later completion overtake it.
        const deadline = std.Io.Clock.awake.now(blockingIo()).addDuration(
            .fromMilliseconds(milliseconds),
        );
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.policy != .registering) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return;
        }
        self.absolute_deadline = deadline;
        if (std.Io.Clock.awake.now(blockingIo()).nanoseconds >= deadline.nanoseconds) {
            const decision = waitDecision(self.policy, .{ .candidate = .timeout });
            self.policy = decision.next;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            self.performWaitCommand(decision.command);
            return;
        }
        self.scheduler.ensureTimer() catch |err| {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return err;
        };
        if (std.Io.Clock.awake.now(blockingIo()).nanoseconds >= deadline.nanoseconds) {
            const decision = waitDecision(self.policy, .{ .candidate = .timeout });
            self.policy = decision.next;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            self.performWaitCommand(decision.command);
            return;
        }
        self.timer.deadline = deadline;
        const scheduler_state = self.scheduler.privateState();
        std.Io.Threaded.mutexLock(&scheduler_state.timer_mutex);
        scheduler_state.timer_heap.insert(self.scheduler.allocator(), &self.timer) catch {
            std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return error.OutOfMemory;
        };
        if (std.Io.Clock.awake.now(blockingIo()).nanoseconds >= deadline.nanoseconds) {
            scheduler_state.timer_heap.remove(&self.timer);
            const decision = waitDecision(self.policy, .{ .candidate = .timeout });
            self.policy = decision.next;
            std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            self.performWaitCommand(decision.command);
            return;
        }
        self.retain();
        std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        scheduler_state.timer_wake.set(blockingIo());
    }

    fn activate(self: *WaitSet) void {
        // Publishing `active` lets another selector deliver and release the
        // wait-set's owner reference. Keep this call's own lease until its
        // concurrent `maybeDeliver` attempt has returned.
        self.retain();
        defer self.release();
        std.Io.Threaded.mutexLock(&self.mutex);
        const decision = waitDecision(self.policy, .activate);
        self.policy = decision.next;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.performWaitCommand(decision.command);
    }

    fn performWaitCommand(self: *WaitSet, command: core.WaitCommand) void {
        const reason = switch (command) {
            .none => return,
            .deliver => |winner| winner,
        };
        std.debug.assert(self.delivery_reason == null);
        self.delivery_reason = reason;
        self.scheduler.enqueueWait(self);
    }

    fn discard(self: *WaitSet) void {
        std.debug.assert(self.policy == .registering);
        std.debug.assert(self.initialized == 0);
        self.discarding = true;
        self.scheduler.enqueueWait(self);
    }

    fn materializeResume(self: *WaitSet, reason: core.WakeReason) machine.ParkResume {
        return switch (reason) {
            .task => |index| outcome: {
                const cell = self.registrations[index].cell.?;
                const terminal_value = cell.terminalOwned() catch break :outcome .out_of_memory;
                const outcome_value = terminal_value orelse unreachable;
                break :outcome switch (self.kind) {
                    .one, .deadline => .{ .outcome = outcome_value },
                    .any => .{ .indexed = .{ .index = index, .outcome = outcome_value } },
                };
            },
            .timeout => .timeout,
            .cancellation => .cancelled,
            .io => .io,
            .out_of_memory => .out_of_memory,
        };
    }

    fn advanceSetup(self: *WaitSet) bool {
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.setup_phase) {
            .initialize => {
                if (self.initialized != self.registrations.len) {
                    self.registrations[self.initialized] = .{ .wait = self };
                    self.initialized += 1;
                    self.wake_handles += 1;
                    budget -= 1;
                    continue;
                }
                if (self.canonical_initialized != self.canonical.len) {
                    self.canonical[self.canonical_initialized] = .{};
                    self.canonical_initialized += 1;
                    budget -= 1;
                    continue;
                }
                {
                    self.setup_phase = .cancel_join_tail;
                    continue;
                }
            },
            .cancel_join_tail => {
                const join = switch (self.request.?) {
                    .join => |join| join,
                    else => {
                        self.setup_phase = .find_duplicate;
                        continue;
                    },
                };
                const start = join.cancel_from orelse {
                    self.setup_phase = .find_duplicate;
                    continue;
                };
                const count: usize = @intCast(join.tasks.list.length());
                if (self.cancel_index == 0) self.cancel_index = start;
                if (self.cancel_cursor) |*cursor| {
                    if (!cursor.advance()) return false;
                    cursor.deinit();
                    self.cancel_cursor = null;
                    self.cancel_index += 1;
                    budget -|= cancellation_tree_quantum;
                    continue;
                }
                if (self.cancel_index == count) {
                    self.setup_phase = .find_duplicate;
                    continue;
                }
                const cell = taskCell(list.atUnchecked(join.tasks, self.cancel_index)).?;
                cancelArriving(cell);
                self.cancel_cursor = .{ .root = &cell.scope };
                budget -= 1;
            },
            .find_duplicate => {
                if (self.setup_index == self.registrations.len) {
                    self.setup_phase = .timer;
                    continue;
                }
                if (self.kind != .any) {
                    self.setup_phase = .register;
                    continue;
                }
                const cell = self.requestCell(self.setup_index);
                if (self.probe_index == 0) self.probe_index = canonicalStart(
                    cell,
                    self.canonical.len,
                );
                const slot = &self.canonical[self.probe_index - 1];
                if (slot.cell == null) {
                    slot.* = .{ .cell = cell, .index = @intCast(self.setup_index) };
                    self.setup_phase = .register;
                } else if (slot.cell == cell) {
                    const terminal = self.registerCell(
                        self.setup_index,
                        cell,
                        slot.index,
                        false,
                    );
                    if (terminal) self.select(.{ .task = slot.index });
                    self.setup_index += 1;
                    self.probe_index = 0;
                } else self.probe_index = self.probe_index % self.canonical.len + 1;
                budget -= 1;
            },
            .register => {
                const cell = self.requestCell(self.setup_index);
                const terminal = self.registerCell(
                    self.setup_index,
                    cell,
                    @intCast(self.setup_index),
                    true,
                );
                if (terminal) self.select(.{ .task = @intCast(self.setup_index) });
                self.setup_index += 1;
                self.probe_index = 0;
                self.setup_phase = .find_duplicate;
                budget -= 1;
            },
            .timer => {
                if (self.request.? == .deadline) {
                    self.addTimer(self.request.?.deadline.milliseconds) catch |err| switch (err) {
                        error.Io => self.select(.io),
                        error.OutOfMemory => self.select(.out_of_memory),
                    };
                }
                self.setup_phase = .release_request;
            },
            .release_request => {
                self.scheduler.releaseDomain().releaseValue(self.request.?.ownedValue().?);
                self.request = null;
                self.setup_phase = .activate;
                budget -= 1;
            },
            .activate => {
                // `activate` publishes the wait set, and publication is what
                // lets another selector deliver and drop the last reference —
                // so `self` may be freed the moment it returns. The phase
                // therefore advances *before* the publish, and this arm
                // touches nothing afterward.
                self.setup_phase = .complete;
                self.activate();
                return true;
            },
            .complete => return true,
        };
        return false;
    }

    fn requestCell(self: *WaitSet, index: usize) *TaskCell {
        return taskCell(self.request.?.taskAt(index)).?;
    }

    fn registerCell(
        self: *WaitSet,
        index: usize,
        cell: *TaskCell,
        wake_index: u32,
        link: bool,
    ) bool {
        const registration = &self.registrations[index];
        std.debug.assert(registration.cell == null);
        registration.cell = cell;
        registration.index = wake_index;
        heap.incRef(cell.handle());
        std.Io.Threaded.mutexLock(&cell.mutex);
        const terminal = switch (cell.publication) {
            .constructing => unreachable,
            .active => false,
            .published => true,
        };
        if (!terminal and link) {
            const linked = registrationDecision(registration.phase, .link);
            registration.phase = linked.next;
            if (linked.command.retain_external) registration.retain();
            linkRegistrationLocked(cell, registration);
        }
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        return terminal;
    }

    fn advanceDelivery(self: *WaitSet) DeliveryProgress {
        if (self.discarding) return self.advanceDiscard();
        const reason = self.delivery_reason.?;
        if (self.park_result == null) self.park_result = self.materializeResume(reason);
        var budget: usize = machine.kernel_poll_quantum;
        while (self.cleanup_index != self.initialized and budget != 0) : (budget -= 1) {
            const registration = &self.registrations[self.cleanup_index];
            const command = if (registration.cell) |cell| command: {
                std.Io.Threaded.mutexLock(&cell.mutex);
                const cleanup = registrationDecision(registration.phase, .cleanup);
                registration.phase = cleanup.next;
                if (cleanup.command.unlink) unlinkRegistrationLocked(registration);
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                break :command cleanup.command;
            } else command: {
                const cleanup = registrationDecision(registration.phase, .cleanup);
                registration.phase = cleanup.next;
                break :command cleanup.command;
            };
            if (command.release_external) registration.release();
            if (command.release_directory) registration.release();
            self.cleanup_index += 1;
        }
        if (self.cleanup_index != self.initialized) return .yielded;
        self.removeTimer();
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.wake_handles != 0) {
            self.awaiting_handles = true;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return .waiting;
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);

        var release_budget: usize = machine.kernel_poll_quantum;
        while (self.cell_release_index != self.initialized and release_budget != 0) : (release_budget -= 1) {
            const registration = &self.registrations[self.cell_release_index];
            if (registration.cell) |cell| self.scheduler.releaseDomain().releaseHeader(cell.handle());
            registration.cell = null;
            self.cell_release_index += 1;
        }
        if (self.cell_release_index != self.initialized) return .yielded;
        self.allocator.free(self.registrations);
        self.registrations = &.{};
        self.allocator.free(self.canonical);
        self.canonical = &.{};
        const result = self.park_result.?;
        self.park_result = null;
        self.wakeOwner(reason, result);
        self.release();
        return .complete;
    }

    fn advanceDiscard(self: *WaitSet) DeliveryProgress {
        self.scheduler.releaseDomain().releaseValue(self.request.?.ownedValue().?);
        self.request = null;
        self.allocator.free(self.registrations);
        self.registrations = &.{};
        self.allocator.free(self.canonical);
        self.canonical = &.{};
        self.release();
        return .complete;
    }

    fn removeTimer(self: *WaitSet) void {
        const scheduler_state = self.scheduler.privateState();
        std.Io.Threaded.mutexLock(&scheduler_state.timer_mutex);
        const owned = self.timer.membership == .linked;
        if (owned) scheduler_state.timer_heap.remove(&self.timer);
        std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
        if (owned) {
            scheduler_state.timer_wake.set(blockingIo());
            self.release();
        }
    }

    fn wakeOwner(
        self: *WaitSet,
        reason: core.WakeReason,
        park_result: machine.ParkResume,
    ) void {
        switch (self.owner) {
            .task => |cell| {
                std.Io.Threaded.mutexLock(&cell.mutex);
                const unit = cell.evaluatingUnit();
                std.debug.assert(cell.waitset == self);
                const decision = unitDecision(cell.policy, .{ .wake = reason });
                cell.policy = decision.next;
                cell.waitset = null;
                unit.installParkResume(park_result);
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                std.debug.assert(decision.command == .enqueue);
                self.scheduler.enqueueTask(cell);
            },
            .root => |root| {
                // `ready` publishes a stack-owned RootWaiter back to the main
                // thread. Capture every field first and make the release store
                // the final access, so the next root park cannot reuse this
                // stack slot while an old selector still dereferences it.
                const scheduler = root.scheduler;
                const unit = root.unit;
                const scheduler_state = scheduler.privateState();
                unit.installParkResume(park_result);
                std.Io.Threaded.mutexLock(&scheduler_state.queue_mutex);
                root.ready.store(true, .release);
                scheduler_state.queue_condition.broadcast(blockingIo());
                std.Io.Threaded.mutexUnlock(&scheduler_state.queue_mutex);
            },
        }
    }
};

pub const TaskScope = struct {
    scheduler: *const WorkerScheduler,
    mutex: std.Io.Mutex = .init,
    quiescent: std.Io.Condition = .init,
    first: ?*TaskCell = null,
    last: ?*TaskCell = null,
    policy: core.Scope = .{ .open = 0 },
    closing_owner: ?*TaskCell = null,
    cancellation_walk_active: bool = false,
    owner: ?*TaskCell = null,

    pub fn init(scheduler: *const WorkerScheduler) TaskScope {
        return .{ .scheduler = scheduler };
    }

    pub fn pending(self: *TaskScope) usize {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.policy.childCount();
    }
};

const CancellationWork = union(enum) {
    none,
    task: CancellationCursor,
    external: CancellationCursor,
};

const TaskCell = struct {
    allocator: std.mem.Allocator,
    scheduler: *const WorkerScheduler,
    header_state: TaskHeaderState = .unpublished,
    mutex: std.Io.Mutex = .init,
    policy: core.Unit = .constructing,
    cancelled: std.atomic.Value(bool) = .init(false),
    publication: TaskPublication = .constructing,
    scope: TaskScope,
    parent_membership: ParentMembership,
    queue: QueueEntry,
    cancellation_queue: QueueEntry,
    waiter_first: ?*WaitRegistration = null,
    waiter_last: ?*WaitRegistration = null,
    waitset: ?*WaitSet = null,
    cancellation: CancellationWork = .none,

    pub fn destroy(allocator: std.mem.Allocator, self: *TaskCell) ?Value {
        std.debug.assert(self.parent_membership == .detached);
        std.debug.assert(self.cancellation == .none);
        const child = switch (self.publication) {
            .constructing, .active => unreachable,
            .published => |terminal| switch (terminal) {
                .outcome => |outcome| outcome,
                .oom => null,
            },
        };
        allocator.destroy(self);
        return child;
    }

    fn terminalOwned(self: *TaskCell) error{OutOfMemory}!?Value {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.publication) {
            .constructing, .active => null,
            .published => |terminal| switch (terminal) {
                .outcome => |outcome| owned: {
                    heap.retainValue(outcome);
                    break :owned outcome;
                },
                .oom => error.OutOfMemory,
            },
        };
    }

    fn evaluatingUnit(self: *TaskCell) *machine.Unit {
        const execution = switch (self.publication) {
            .active => |execution| execution,
            .constructing, .published => unreachable,
        };
        std.debug.assert(execution.phase == .evaluating);
        return &execution.unit;
    }

    fn handle(self: *const TaskCell) *TaskHandle {
        return switch (self.header_state) {
            .unpublished => unreachable,
            .published => |header| header,
        };
    }
};

const cancellation_tree_quantum = 256;
const task_waiter_quantum = 256;

/// Stable, resumable pre-order traversal of a closing task scope. Tree links
/// are borrowed only while holding `tree_mutex`; a retained cursor keeps the
/// next cell alive between slices. A mutation invalidates the saved path and
/// restarts the idempotent cancellation walk from the root.
const CancellationCursor = struct {
    root: *TaskScope,
    retained_next: ?*TaskCell = null,
    observed_epoch: u64 = 0,
    started: bool = false,

    pub fn advance(self: *CancellationCursor) bool {
        const scheduler = self.root.scheduler;
        const scheduler_state = scheduler.privateState();
        const old_retained = self.retained_next;
        std.Io.Threaded.mutexLock(&scheduler_state.tree_mutex);
        var current = if (self.started and self.observed_epoch == scheduler_state.tree_epoch)
            old_retained
        else
            self.root.first;
        var visited: usize = 0;
        while (current != null and visited < cancellation_tree_quantum) : (visited += 1) {
            const cell = current.?;
            const following = nextDescendant(self.root, cell);
            _ = cancelOne(cell);
            current = following;
        }
        if (current) |next| heap.incRef(next.handle());
        self.retained_next = current;
        self.observed_epoch = scheduler_state.tree_epoch;
        self.started = true;
        std.Io.Threaded.mutexUnlock(&scheduler_state.tree_mutex);
        if (old_retained) |old| scheduler.releaseDomain().releaseHeader(old.handle());
        notifyCancellation(scheduler);
        return current == null;
    }

    fn deinit(self: *CancellationCursor) void {
        if (self.retained_next) |cell| cell.scheduler.releaseDomain().releaseHeader(cell.handle());
        self.* = undefined;
    }
};

pub const SpawnRequest = struct {
    parent_unit: *machine.Unit,
    parent_scope: *env.Scope,
    parent_home: ?*modules.ModuleHome,
    quotation: *ListHandle,
    initial_stack: machine.InitialStack = .empty,
    /// Which constructor made this child, so an underflow against its floor
    /// can name the word the caller actually wrote.
    constructor: machine.UnitConstructor = .spawn,
};

pub const SpawnError = error{ OutOfMemory, Io };

const WorkerState = struct {
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    config: Config,
    start_mutex: std.Io.Mutex = .init,
    queue_mutex: std.Io.Mutex = .init,
    tree_mutex: std.Io.Mutex = .init,
    tree_epoch: u64 = 0,
    queue_condition: std.Io.Condition = .init,
    queue_first: ?*QueueEntry = null,
    queue_last: ?*QueueEntry = null,
    stopping: bool = false,
    started: bool = false,
    threads: []std.Thread = &.{},
    worker_threads: std.atomic.Value(usize) = .init(0),
    timer_thread: ?std.Thread = null,
    timer_mutex: std.Io.Mutex = .init,
    timer_wake: std.Io.Event = .unset,
    timer_stopping: bool = false,
    timer_heap: TimerHeap = .{},
    timer_threads: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),
    cooperative_arbitration: ExecutorArbitration = .{},
};

pub const WorkerScheduler = enum(usize) {
    invalid = 0,
    _,

    fn privateState(self: *const WorkerScheduler) *WorkerState {
        std.debug.assert(self.* != .invalid);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    fn allocator(self: *const WorkerScheduler) std.mem.Allocator {
        return self.privateState().allocator;
    }

    fn releaseDomain(self: *const WorkerScheduler) *heap.ReleaseDomain {
        return self.privateState().releases;
    }

    pub fn wakeRetirement(self: *const WorkerScheduler) void {
        const state_ = self.privateState();
        std.Io.Threaded.mutexLock(&state_.queue_mutex);
        state_.queue_condition.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
    }

    fn shutdown(self: *const WorkerScheduler, root_scope: *TaskScope) void {
        const state_ = self.privateState();
        self.closeRootScope(root_scope);
        std.Io.Threaded.mutexLock(&state_.timer_mutex);
        state_.timer_stopping = true;
        std.Io.Threaded.mutexUnlock(&state_.timer_mutex);
        state_.timer_wake.set(blockingIo());
        if (state_.timer_thread) |thread| thread.join();
        state_.timer_thread = null;
        state_.timer_heap.deinit(self.allocator());

        std.Io.Threaded.mutexLock(&state_.queue_mutex);
        state_.stopping = true;
        state_.queue_condition.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
        for (state_.threads) |thread| thread.join();
        if (state_.threads.len > 0) self.allocator().free(state_.threads);
        state_.threads = &.{};
        if (state_.config.isCooperative()) {
            while (self.runNextCooperative()) {}
        }
        std.debug.assert(state_.queue_first == null);
    }

    fn ensureStarted(self: *const WorkerScheduler) SpawnError!void {
        const state_ = self.privateState();
        std.Io.Threaded.mutexLock(&state_.start_mutex);
        defer std.Io.Threaded.mutexUnlock(&state_.start_mutex);
        if (state_.started) return;
        if (state_.config.isCooperative()) {
            state_.started = true;
            return;
        }
        const threads = try self.allocator().alloc(std.Thread, state_.config.worker_pool);
        var started: usize = 0;
        errdefer {
            std.Io.Threaded.mutexLock(&state_.queue_mutex);
            state_.stopping = true;
            state_.queue_condition.broadcast(blockingIo());
            std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
            for (threads[0..started]) |thread| thread.join();
            state_.stopping = false;
            self.allocator().free(threads);
        }
        while (started < threads.len) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, workerMain, .{self}) catch return error.Io;
        }
        state_.threads = threads;
        state_.started = true;
        state_.worker_threads.store(threads.len, .release);
    }

    fn ensureTimer(self: *const WorkerScheduler) error{Io}!void {
        const state_ = self.privateState();
        std.Io.Threaded.mutexLock(&state_.start_mutex);
        defer std.Io.Threaded.mutexUnlock(&state_.start_mutex);
        if (state_.timer_thread != null) return;
        state_.timer_thread = std.Thread.spawn(.{}, timerMain, .{self}) catch return error.Io;
        state_.timer_threads.store(1, .release);
    }

    pub fn spawn(self: *const WorkerScheduler, parent: *TaskScope, request: SpawnRequest) SpawnError!Value {
        try self.ensureStarted();
        const state_ = self.privateState();
        const cell = try self.allocator().create(TaskCell);
        errdefer self.allocator().destroy(cell);
        cell.* = .{
            .allocator = self.allocator(),
            .scheduler = self,
            .scope = TaskScope.init(self),
            .parent_membership = .{ .detached = parent },
            .queue = .{ .item = .{ .task = cell } },
            .cancellation_queue = .{ .item = .{ .cancellation = cell } },
        };
        cell.scope.owner = cell;

        const execution = try self.allocator().create(TaskExecution);
        errdefer self.allocator().destroy(execution);
        execution.* = .{ .unit = machine.Unit.init(
            self.allocator(),
            self.releaseDomain(),
            request.parent_unit.module_access,
            .empty,
            request.parent_unit.environment,
            request.parent_unit.archive,
            request.parent_unit.output,
            request.parent_unit.arguments,
            &cell.cancelled,
        ) };
        const unit = &execution.unit;
        errdefer unit.deinit();
        unit.replaceRootScope(env.Scope.lazy(self.allocator(), request.parent_scope));
        unit.inherited = request.parent_unit.inherited;
        unit.scheduler = self;
        unit.task_scope = &cell.scope;
        unit.is_root_unit = false;
        unit.constructor = request.constructor;
        if (request.parent_home) |generation| try unit.pinGeneration(generation);
        try machine.initialize(unit, request.quotation, request.initial_stack);
        const identity = state_.next_identity.fetchAdd(1, .monotonic);
        const header = try heap.createTask(TaskCell, self.allocator(), identity, cell);
        cell.header_state = .{ .published = header };
        cell.publication = .{ .active = execution };

        std.Io.Threaded.mutexLock(&state_.tree_mutex);
        std.Io.Threaded.mutexLock(&parent.mutex);
        std.Io.Threaded.mutexLock(&cell.mutex);
        const publish = unitDecision(cell.policy, .publish);
        cell.policy = publish.next;
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        std.debug.assert(publish.command == .enqueue);
        const scope_decision = scopeDecision(parent.policy, .register_child);
        parent.policy = scope_decision.next;
        if (parent.last) |last| {
            switch (last.parent_membership) {
                .linked => |*membership| membership.next = cell,
                .detached => unreachable,
            }
            cell.parent_membership = .{ .linked = .{ .scope = parent, .previous = last } };
        } else parent.first = cell;
        if (parent.last == null)
            cell.parent_membership = .{ .linked = .{ .scope = parent } };
        parent.last = cell;
        state_.tree_epoch +%= 1;
        heap.incRef(header);
        const kill_on_arrival = scope_decision.command == .cancel_arriving_child;
        if (kill_on_arrival) _ = cancelOne(cell);
        std.Io.Threaded.mutexUnlock(&parent.mutex);
        std.Io.Threaded.mutexUnlock(&state_.tree_mutex);

        heap.incRef(header);
        if (kill_on_arrival) notifyCancellation(self);
        self.enqueueTask(cell);
        return .{ .task = header };
    }

    pub fn runRoot(
        self: *const WorkerScheduler,
        unit: *machine.Unit,
        code: *ListHandle,
    ) machine.MachineError!void {
        try machine.initialize(unit, code, .empty);
        return self.runInitializedRoot(unit);
    }

    /// Drive a root whose caller installed its initial machine work. Session
    /// observation uses this to auto-load a module without manufacturing a
    /// public word call or importing that module into the session scope.
    pub fn runInitializedRoot(
        self: *const WorkerScheduler,
        unit: *machine.Unit,
    ) machine.MachineError!void {
        const state_ = self.privateState();
        while (true) {
            const status = machine.runSlice(unit) catch |err| {
                if (err == error.OutOfMemory) self.drainAbandonedRootWork(unit);
                return err;
            };
            _ = self.releaseDomain().advance(machine.kernel_poll_quantum);
            switch (status) {
                .completed => {
                    if (unit.exit_status != null)
                        while (!unit.advanceSchedulerTeardown(machine.kernel_poll_quantum).complete) {
                            _ = self.releaseDomain().tryAdvance(machine.kernel_poll_quantum);
                        };
                    return;
                },
                .yielded => if (!state_.config.isCooperative() or !self.runNextCooperative())
                    std.Thread.yield() catch @panic("scheduler root yield failed"),
                .parked => self.handleRootPark(unit) catch |err| {
                    self.drainAbandonedRootWork(unit);
                    return err;
                },
            }
        }
    }

    fn drainAbandonedRootWork(self: *const WorkerScheduler, unit: *machine.Unit) void {
        while (!unit.advanceSchedulerTeardown(machine.kernel_poll_quantum).complete) {
            _ = self.releaseDomain().tryAdvance(machine.kernel_poll_quantum);
            std.Thread.yield() catch @panic("root teardown yield failed");
        }
    }

    fn handleRootPark(self: *const WorkerScheduler, unit: *machine.Unit) error{OutOfMemory}!void {
        const state_ = self.privateState();
        const request = unit.parkRequest().?;
        if (request == .close_scope) {
            const status = request.close_scope;
            _ = unit.takeParkRequest();
            self.closeRootScope(@ptrCast(@alignCast(unit.task_scope.?)));
            unit.installParkResume(.{ .scope_closed = status });
            return;
        }
        var root = RootWaiter{ .scheduler = self, .unit = unit };
        const wait = try WaitSet.create(
            self,
            .{ .root = &root },
            request,
        );
        _ = unit.takeParkRequest();
        while (!wait.advanceSetup()) std.Thread.yield() catch
            @panic("scheduler root wait setup yield failed");
        while (!root.ready.load(.acquire)) {
            if (state_.config.isCooperative()) {
                if (!self.runNextCooperative())
                    std.Thread.yield() catch @panic("cooperative scheduler yield failed");
                continue;
            }
            std.Io.Threaded.mutexLock(&state_.queue_mutex);
            if (!root.ready.load(.acquire) and state_.queue_first == null and !state_.stopping) {
                state_.queue_condition.waitUncancelable(blockingIo(), &state_.queue_mutex);
            }
            std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
        }
    }

    pub fn cancelOwned(
        self: *const WorkerScheduler,
        task: Value,
    ) void {
        const cell = taskCell(task).?;
        std.debug.assert(cell.scheduler == self);
        const enqueue_cancellation = beginExternalCancellation(cell);
        self.releaseDomain().releaseValue(task);
        if (enqueue_cancellation) self.enqueueCancellation(cell);
        notifyCancellation(self);
    }

    pub fn installTasksDriver(
        self: *const WorkerScheduler,
        evaluator: *machine.Machine,
        scope: *TaskScope,
    ) error{OutOfMemory}!void {
        try evaluator.startDriver(TasksDriver{ .scheduler = self, .scope = scope });
    }

    fn closeRootScope(self: *const WorkerScheduler, scope: *TaskScope) void {
        const state_ = self.privateState();
        std.debug.assert(scope.owner == null);
        std.Io.Threaded.mutexLock(&scope.mutex);
        const decision = scopeDecision(scope.policy, .close);
        scope.policy = decision.next;
        const cancel_children = decision.command == .cancel_children;
        std.Io.Threaded.mutexUnlock(&scope.mutex);
        if (cancel_children) cancelScopeTree(scope);
        std.Io.Threaded.mutexLock(&scope.mutex);
        while (scope.policy.childCount() != 0) {
            if (state_.config.isCooperative()) {
                std.Io.Threaded.mutexUnlock(&scope.mutex);
                if (!self.runNextCooperative())
                    std.Thread.yield() catch @panic("cooperative scope-close yield failed");
                std.Io.Threaded.mutexLock(&scope.mutex);
            } else scope.quiescent.waitUncancelable(blockingIo(), &scope.mutex);
        }
        std.Io.Threaded.mutexUnlock(&scope.mutex);
    }

    fn enqueueTask(self: *const WorkerScheduler, cell: *TaskCell) void {
        self.enqueue(&cell.queue);
    }

    fn enqueueCancellation(self: *const WorkerScheduler, cell: *TaskCell) void {
        self.enqueue(&cell.cancellation_queue);
    }

    fn enqueueWait(self: *const WorkerScheduler, wait: *WaitSet) void {
        self.enqueue(&wait.queue);
    }

    fn enqueue(self: *const WorkerScheduler, entry: *QueueEntry) void {
        const state_ = self.privateState();
        std.Io.Threaded.mutexLock(&state_.queue_mutex);
        std.debug.assert(entry.membership == .detached);
        if (state_.queue_last) |last| switch (last.membership) {
            .linked => |*next| next.* = entry,
            .detached => unreachable,
        } else state_.queue_first = entry;
        entry.membership = .{ .linked = null };
        state_.queue_last = entry;
        state_.queue_condition.signal(blockingIo());
        std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
    }

    fn popLocked(self: *const WorkerScheduler) ?*QueueEntry {
        const state_ = self.privateState();
        const entry = state_.queue_first orelse return null;
        state_.queue_first = switch (entry.membership) {
            .linked => |next| next,
            .detached => unreachable,
        };
        if (state_.queue_first == null) state_.queue_last = null;
        entry.membership = .detached;
        return entry;
    }

    fn runNextCooperative(self: *const WorkerScheduler) bool {
        const state_ = self.privateState();
        std.debug.assert(state_.config.isCooperative());
        return self.runArbitrated(&state_.cooperative_arbitration);
    }

    fn runArbitrated(self: *const WorkerScheduler, arbitration: *ExecutorArbitration) bool {
        const state_ = self.privateState();
        const retirement_ready = self.releaseDomain().hasPending();
        std.Io.Threaded.mutexLock(&state_.queue_mutex);
        const turn = arbitration.choose(state_.queue_first != null, retirement_ready) orelse {
            std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
            return false;
        };
        const entry = if (turn == .ready) self.popLocked() else null;
        std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
        if (entry) |ready| {
            self.runEntry(ready);
            return true;
        }
        if (self.releaseDomain().tryAdvance(machine.kernel_poll_quantum) == null)
            std.Thread.yield() catch @panic("scheduler retirement arbitration yield failed");
        return true;
    }

    fn runEntry(self: *const WorkerScheduler, entry: *QueueEntry) void {
        switch (entry.item) {
            .task => |cell| self.runQueued(cell),
            .cancellation => |cell| self.runCancellation(cell),
            .wait => |wait| self.runWait(wait),
        }
    }

    fn execute(self: *const WorkerScheduler, cell: *TaskCell) void {
        const unit = cell.evaluatingUnit();
        const result = machine.runSlice(unit);
        if (result) |status| switch (status) {
            .yielded => {
                std.Io.Threaded.mutexLock(&cell.mutex);
                const decision = unitDecision(cell.policy, .yield);
                cell.policy = decision.next;
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                std.debug.assert(decision.command == .enqueue);
                self.enqueueTask(cell);
                return;
            },
            .parked => self.parkTask(cell),
            .completed => self.finish(cell, .success),
        } else |err| switch (err) {
            error.Ecl => self.finish(cell, .language_error),
            error.OutOfMemory => self.finish(cell, .oom),
        }
    }

    fn parkTask(self: *const WorkerScheduler, cell: *TaskCell) void {
        const unit = cell.evaluatingUnit();
        const request = unit.parkRequest().?;
        const wait = WaitSet.create(
            self,
            .{ .task = cell },
            request,
        ) catch return self.finish(cell, .oom);
        _ = unit.takeParkRequest();

        std.Io.Threaded.mutexLock(&cell.mutex);
        const parking = unitDecision(cell.policy, .park);
        cell.policy = parking.next;
        if (parking.command == .register_wait) cell.waitset = wait;
        std.Io.Threaded.mutexUnlock(&cell.mutex);

        if (parking.command == .enqueue) {
            unit.installParkResume(.cancelled);
            wait.discard();
            self.enqueueTask(cell);
            return;
        }
        std.debug.assert(parking.command == .register_wait);
        if (!wait.advanceSetup()) self.enqueueTask(cell);
    }

    fn advanceParkSetup(self: *const WorkerScheduler, cell: *TaskCell) void {
        const wait = cell.waitset.?;
        if (!wait.advanceSetup()) self.enqueueTask(cell);
    }

    fn finish(self: *const WorkerScheduler, cell: *TaskCell, disposition: Finish) void {
        const completion: core.Completion = switch (disposition) {
            .success => .success,
            .language_error => .language_error,
            .oom => .out_of_memory,
        };
        std.Io.Threaded.mutexLock(&cell.mutex);
        const finishing = unitDecision(cell.policy, .{ .body_finished = completion });
        cell.policy = finishing.next;
        const execution = switch (cell.publication) {
            .active => |execution| execution,
            .constructing, .published => unreachable,
        };
        std.debug.assert(execution.phase == .evaluating);
        execution.phase = .{ .finishing = switch (disposition) {
            .success => .success_unstarted,
            .language_error => .language_error,
            .oom => .out_of_memory,
        } };
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        std.debug.assert(finishing.command == .close_scope);
        self.beginTaskClose(cell);
    }

    fn beginTaskClose(self: *const WorkerScheduler, cell: *TaskCell) void {
        const state_ = self.privateState();
        std.Io.Threaded.mutexLock(&state_.tree_mutex);
        std.Io.Threaded.mutexLock(&cell.scope.mutex);
        const decision = scopeDecision(cell.scope.policy, .close);
        cell.scope.policy = decision.next;
        const ready = decision.command == .notify_quiescent;
        if (!ready) {
            std.debug.assert(cell.scope.closing_owner == null);
            cell.scope.closing_owner = cell;
        }
        const start_cancellation = !ready and
            cell.scope.policy == .closing and
            !cell.scope.cancellation_walk_active;
        if (start_cancellation) {
            std.debug.assert(!cell.scope.cancellation_walk_active);
            cell.scope.cancellation_walk_active = true;
            std.debug.assert(cell.cancellation == .none);
            cell.cancellation = .{ .task = .{ .root = &cell.scope } };
        }
        std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
        std.Io.Threaded.mutexUnlock(&state_.tree_mutex);
        if (start_cancellation) {
            self.enqueueTask(cell);
            return;
        }
        if (ready) self.publishFinished(cell);
    }

    fn advanceTaskClose(self: *const WorkerScheduler, cell: *TaskCell) void {
        const state_ = self.privateState();
        std.debug.assert(cell.cancellation == .task);
        const cursor = &cell.cancellation.task;
        if (!cursor.advance()) {
            self.enqueueTask(cell);
            return;
        }
        cursor.deinit();
        cell.cancellation = .none;
        std.Io.Threaded.mutexLock(&state_.tree_mutex);
        std.Io.Threaded.mutexLock(&cell.scope.mutex);
        cell.scope.cancellation_walk_active = false;
        const closing_owner = if (cell.scope.policy == .closed)
            cell.scope.closing_owner
        else
            null;
        if (closing_owner != null) cell.scope.closing_owner = null;
        std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
        std.Io.Threaded.mutexUnlock(&state_.tree_mutex);
        if (closing_owner) |owner| self.publishFinished(owner);
    }

    fn publishFinished(self: *const WorkerScheduler, cell: *TaskCell) void {
        const execution = switch (cell.publication) {
            .constructing => unreachable,
            .active => |execution| execution,
            .published => return self.advancePublication(cell),
        };
        const finishing = switch (execution.phase) {
            .evaluating => unreachable,
            .finishing => |*work| work,
        };
        if (!self.advanceTerminalMaterialization(execution)) {
            self.enqueueTask(cell);
            return;
        }
        if (!self.advanceFinishedUnitCleanup(&execution.unit)) {
            self.enqueueTask(cell);
            return;
        }
        const terminal = switch (finishing.*) {
            .ready => |ready| ready,
            else => unreachable,
        };
        execution.unit.deinit();
        std.Io.Threaded.mutexLock(&cell.mutex);
        const completed = unitDecision(cell.policy, .scope_quiescent);
        cell.policy = completed.next;
        std.debug.assert(completed.command == .publish);
        cell.publication = .{ .published = terminal };
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        self.allocator().destroy(execution);
        self.advancePublication(cell);
    }

    fn advanceFinishedUnitCleanup(_: *const WorkerScheduler, unit: *machine.Unit) bool {
        return unit.advanceSchedulerTeardown(machine.kernel_poll_quantum).complete;
    }

    fn advanceTerminalMaterialization(
        self: *const WorkerScheduler,
        execution: *TaskExecution,
    ) bool {
        const work = switch (execution.phase) {
            .evaluating => unreachable,
            .finishing => |*pending| pending,
        };
        while (true) switch (work.*) {
            .out_of_memory => {
                work.* = .{ .ready = .oom };
                return true;
            },
            .language_error => {
                const failure = execution.unit.takeError().?;
                const wrapped = machine.outcomeDict(self.allocator(), self.releaseDomain(), "err", failure) catch {
                    work.* = .{ .ready = .oom };
                    return true;
                };
                work.* = .{ .ready = .{ .outcome = wrapped } };
                return true;
            },
            .success_unstarted => {
                work.* = .{
                    .success_materializing = kernel_storage.ValueMaterializer.init(
                        self.allocator(),
                        execution.unit.stack.items,
                    ),
                };
            },
            .success_materializing => |*materializer| {
                const materialized = materializer.advance(machine.kernel_poll_quantum) catch {
                    materializer.retire(self.releaseDomain());
                    work.* = .{ .ready = .oom };
                    return true;
                };
                const results = switch (materialized) {
                    .pending => return false,
                    .complete => |complete| complete,
                };
                materializer.retire(self.releaseDomain());
                const wrapped = machine.outcomeDict(self.allocator(), self.releaseDomain(), "ok", results) catch {
                    work.* = .{ .ready = .oom };
                    return true;
                };
                work.* = .{ .ready = .{ .outcome = wrapped } };
                return true;
            },
            .ready => return true,
        };
    }

    fn advancePublication(self: *const WorkerScheduler, cell: *TaskCell) void {
        const state_ = self.privateState();
        var delivered: usize = 0;
        while (delivered != task_waiter_quantum) : (delivered += 1) {
            std.Io.Threaded.mutexLock(&cell.mutex);
            const registration = cell.waiter_first orelse {
                std.Io.Threaded.mutexUnlock(&cell.mutex);
                break;
            };
            cell.waiter_first = registration.next;
            if (registration.next) |next| next.previous = null else cell.waiter_last = null;
            registration.previous = null;
            registration.next = null;
            const detached = registrationDecision(registration.phase, .detach);
            registration.phase = detached.next;
            std.Io.Threaded.mutexUnlock(&cell.mutex);

            registration.wait.select(.{ .task = registration.index });
            std.Io.Threaded.mutexLock(&cell.mutex);
            const returned = registrationDecision(registration.phase, .delivery_returned);
            registration.phase = returned.next;
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            if (returned.command.release_external) registration.release();
        }
        std.Io.Threaded.mutexLock(&cell.mutex);
        const has_waiters = cell.waiter_first != null;
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        if (has_waiters) {
            self.enqueueTask(cell);
            return;
        }

        std.Io.Threaded.mutexLock(&state_.tree_mutex);
        const closing_parent = unlinkParent(cell);
        std.Io.Threaded.mutexUnlock(&state_.tree_mutex);
        std.Io.Threaded.mutexLock(&state_.queue_mutex);
        state_.queue_condition.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&state_.queue_mutex);
        const header = cell.handle();
        if (closing_parent) |parent| self.enqueueTask(parent);
        self.releaseDomain().releaseHeader(header);
    }

    fn runQueued(self: *const WorkerScheduler, cell: *TaskCell) void {
        std.Io.Threaded.mutexLock(&cell.mutex);
        const phase = cell.policy.phase();
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        switch (phase) {
            .ready => {
                const command = dispatch(cell);
                if (command == .cancel_before_dispatch)
                    machine.armCancellationBeforeDispatch(cell.evaluatingUnit());
                self.execute(cell);
            },
            .closing => switch (cell.cancellation) {
                .task => self.advanceTaskClose(cell),
                .external => {},
                .none => self.publishFinished(cell),
            },
            .parked => self.advanceParkSetup(cell),
            .done => self.advancePublication(cell),
            .constructing, .running => unreachable,
        }
    }

    fn runWait(self: *const WorkerScheduler, wait: *WaitSet) void {
        switch (wait.advanceDelivery()) {
            .yielded => self.enqueueWait(wait),
            .waiting, .complete => {},
        }
    }

    fn runCancellation(self: *const WorkerScheduler, cell: *TaskCell) void {
        const state_ = self.privateState();
        std.debug.assert(cell.cancellation == .external);
        const cursor = &cell.cancellation.external;
        if (!cursor.advance()) {
            self.enqueueCancellation(cell);
            return;
        }
        cursor.deinit();
        cell.cancellation = .none;
        std.Io.Threaded.mutexLock(&state_.tree_mutex);
        std.Io.Threaded.mutexLock(&cell.scope.mutex);
        cell.scope.cancellation_walk_active = false;
        const closing_owner = if (cell.scope.policy == .closed)
            cell.scope.closing_owner
        else
            null;
        if (closing_owner != null) cell.scope.closing_owner = null;
        std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
        std.Io.Threaded.mutexUnlock(&state_.tree_mutex);
        if (closing_owner) |owner| self.publishFinished(owner);
        self.releaseDomain().releaseHeader(cell.handle());
    }
};

const SchedulerState = struct {
    host: *const heap.HostCleanup,
    worker_facade: WorkerScheduler,
    worker: WorkerState,
};

/// Host-side scheduler lifecycle authority. Executing units receive only the
/// `WorkerScheduler` facade, which cannot drain or destroy the host domain.
pub const Scheduler = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Scheduler) *SchedulerState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@intFromEnum(self.*));
    }

    pub fn init(host: *const heap.HostCleanup, config: Config) error{OutOfMemory}!Scheduler {
        config.validate() catch @panic("scheduler worker count must be positive when using a pool");
        const backing = try host.allocator().create(SchedulerState);
        backing.* = .{
            .host = host,
            .worker_facade = .invalid,
            .worker = .{
                .allocator = host.allocator(),
                .releases = heap.hostDomain(host),
                .config = config,
            },
        };
        backing.worker_facade = @enumFromInt(@intFromPtr(&backing.worker));
        return @enumFromInt(@intFromPtr(backing));
    }

    fn workerMutable(self: *Scheduler) *WorkerScheduler {
        return &self.privateState().worker_facade;
    }

    pub fn worker(self: *const Scheduler) *const WorkerScheduler {
        return &self.privateState().worker_facade;
    }

    /// Installs the wake capability only after the scheduler has reached its
    /// stable SessionCore address.
    pub fn attachRetirement(self: *Scheduler) void {
        const facade = self.workerMutable();
        facade.releaseDomain().attachWake(facade);
    }

    pub fn deinit(self: *Scheduler, root_scope: *TaskScope) void {
        const backing = self.privateState();
        const owner_allocator = backing.host.allocator();
        const facade = self.workerMutable();
        facade.shutdown(root_scope);
        backing.host.drain();
        facade.releaseDomain().detachWake();
        owner_allocator.destroy(backing);
        self.* = .consumed;
    }

    pub fn runRoot(
        self: *Scheduler,
        unit: *machine.Unit,
        code: *ListHandle,
    ) machine.MachineError!void {
        return self.worker().runRoot(unit, code);
    }

    pub fn runInitializedRoot(
        self: *Scheduler,
        unit: *machine.Unit,
    ) machine.MachineError!void {
        return self.worker().runInitializedRoot(unit);
    }

    /// A blocking mutation turn is a settlement barrier, not merely a wakeup.
    /// It waits behind an active worker retirement slice, then drains every
    /// causally enqueued successor before returning to the host.
    pub fn settleRootRetirement(self: *Scheduler) void {
        self.privateState().host.drain();
    }

    pub fn workerThreadCount(self: *const Scheduler) usize {
        return self.privateState().worker.worker_threads.load(.acquire);
    }

    pub fn timerThreadCount(self: *const Scheduler) usize {
        return self.privateState().worker.timer_threads.load(.acquire);
    }

    pub fn timerEntryCount(self: *Scheduler) usize {
        const execution = &self.privateState().worker;
        std.Io.Threaded.mutexLock(&execution.timer_mutex);
        defer std.Io.Threaded.mutexUnlock(&execution.timer_mutex);
        return execution.timer_heap.len;
    }
};

comptime {
    heap.requireOpaqueWorkerFacade(WorkerScheduler, WorkerState);
    heap.requireOpaqueHostRoot(Scheduler, SchedulerState);
}

fn requestKind(request: machine.ParkRequest) WaitKind {
    return switch (request) {
        .task, .join => .one,
        .any => .any,
        .deadline => .deadline,
        .close_scope => unreachable,
    };
}

fn canonicalStart(cell: *TaskCell, capacity: usize) usize {
    std.debug.assert(capacity != 0 and std.math.isPowerOfTwo(capacity));
    var address = @intFromPtr(cell);
    const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&address));
    return (@as(usize, @truncate(hash)) & (capacity - 1)) + 1;
}

fn taskCell(task: Value) ?*TaskCell {
    if (task != .task) return null;
    return @ptrCast(@alignCast(heap.taskStorage(task.task).payload));
}

const task_snapshot_quantum = 256;

const TaskSnapshotPass = struct {
    tree_epoch: u64,
    position: union(enum) {
        start,
        retained: *TaskCell,
    } = .start,

    fn releaseRetained(self: TaskSnapshotPass, releases: *heap.ReleaseDomain) void {
        switch (self.position) {
            .start => {},
            .retained => |next| releases.releaseHeader(next.handle()),
        }
    }

    pub fn retire(self: *TaskSnapshotPass, releases: *heap.ReleaseDomain) void {
        self.releaseRetained(releases);
    }
};

/// Two-pass, generic-list snapshot of pending descendants. Only the cursor's
/// next cell is retained between slices; collected task ownership moves
/// directly into the exact-capacity result header.
const TasksDriver = struct {
    scheduler: *const WorkerScheduler,
    scope: *TaskScope,
    pass: ?heap.Owned(TaskSnapshotPass) = null,
    phase: enum { count, collect } = .count,
    count: usize = 0,
    result: ?heap.Owned(heap.ListBuilder(.generic_spine)) = null,
    filled: usize = 0,

    pub fn advance(
        evaluator: *machine.Machine,
        self: *TasksDriver,
    ) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const old_pass = if (self.pass) |*pass| pass.take() else null;
        self.pass = null;
        const scheduler_state = self.scheduler.privateState();
        std.Io.Threaded.mutexLock(&scheduler_state.tree_mutex);
        if (old_pass) |pass| if (pass.tree_epoch != scheduler_state.tree_epoch) {
            self.pass = null;
            self.count = 0;
            self.filled = 0;
            self.phase = .count;
            if (self.result) |*result| {
                result.deinit(self.scheduler.releaseDomain(), self.scheduler.allocator());
                self.result = null;
            }
            std.Io.Threaded.mutexUnlock(&scheduler_state.tree_mutex);
            pass.releaseRetained(self.scheduler.releaseDomain());
            return .yielded;
        };
        const pass_epoch = if (old_pass) |pass| pass.tree_epoch else scheduler_state.tree_epoch;
        var current = if (old_pass) |pass| switch (pass.position) {
            .start => self.scope.first,
            .retained => |next| next,
        } else self.scope.first;
        var visited: usize = 0;
        while (current != null and visited < task_snapshot_quantum) : (visited += 1) {
            const cell = current.?;
            current = nextDescendant(self.scope, cell);
            std.Io.Threaded.mutexLock(&cell.mutex);
            const pending = switch (cell.publication) {
                .constructing => unreachable,
                .active => true,
                .published => false,
            };
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            if (!pending) continue;
            switch (self.phase) {
                .count => self.count = std.math.add(usize, self.count, 1) catch {
                    std.Io.Threaded.mutexUnlock(&scheduler_state.tree_mutex);
                    return error.OutOfMemory;
                },
                .collect => if (self.filled != self.count) {
                    heap.incRef(cell.handle());
                    self.result.?.borrowMut().items()[self.filled] = .{ .task = cell.handle() };
                    self.filled += 1;
                    self.result.?.borrowMut().setLen(self.filled);
                },
            }
        }
        self.pass = .init(.{ .tree_epoch = pass_epoch });
        if (current) |following| {
            heap.incRef(following.handle());
            self.pass.?.borrowMut().position = .{ .retained = following };
        }
        std.Io.Threaded.mutexUnlock(&scheduler_state.tree_mutex);
        if (old_pass) |pass| pass.releaseRetained(self.scheduler.releaseDomain());
        if (current != null) return .yielded;
        switch (self.phase) {
            .count => {
                if (self.count >= std.math.maxInt(u32)) return error.OutOfMemory;
                self.result = .init(try heap.ListBuilder(.generic_spine).init(
                    self.scheduler.allocator(),
                    0,
                    self.count,
                ));
                self.phase = .collect;
                return .yielded;
            },
            .collect => {
                var result_builder = self.result.?.take();
                self.result = null;
                if (self.pass) |*pass| pass.deinit(
                    self.scheduler.releaseDomain(),
                    self.scheduler.allocator(),
                );
                self.pass = null;
                const result: Value = .{ .list = result_builder.finish() };
                return .{ .output = result };
            },
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn nextDescendant(root: *const TaskScope, cell: *TaskCell) ?*TaskCell {
    if (cell.scope.first) |child| return child;
    var current = cell;
    while (true) {
        const membership = switch (current.parent_membership) {
            .linked => |membership| membership,
            .detached => unreachable,
        };
        if (membership.next) |sibling| return sibling;
        if (membership.scope == root) return null;
        current = membership.scope.owner.?;
    }
}

fn linkRegistrationLocked(cell: *TaskCell, registration: *WaitRegistration) void {
    std.debug.assert(registration.phase == .linked);
    std.debug.assert(registration.previous == null and registration.next == null);
    if (cell.waiter_last) |last| {
        last.next = registration;
        registration.previous = last;
    } else cell.waiter_first = registration;
    cell.waiter_last = registration;
}

fn unlinkRegistrationLocked(registration: *WaitRegistration) void {
    std.debug.assert(registration.phase == .retired);
    const cell = registration.cell.?;
    if (registration.previous) |previous| previous.next = registration.next else cell.waiter_first = registration.next;
    if (registration.next) |next| next.previous = registration.previous else cell.waiter_last = registration.previous;
    registration.previous = null;
    registration.next = null;
}

fn cancelArriving(cell: *TaskCell) void {
    const scheduler_state = cell.scheduler.privateState();
    std.Io.Threaded.mutexLock(&scheduler_state.tree_mutex);
    _ = cancelOne(cell);
    std.Io.Threaded.mutexUnlock(&scheduler_state.tree_mutex);
    notifyCancellation(cell.scheduler);
}

fn beginExternalCancellation(cell: *TaskCell) bool {
    const scheduler = cell.scheduler;
    const scheduler_state = scheduler.privateState();
    std.Io.Threaded.mutexLock(&scheduler_state.tree_mutex);
    const close_command = cancelOne(cell);
    var enqueue = false;
    if (close_command == .cancel_children) {
        std.Io.Threaded.mutexLock(&cell.scope.mutex);
        if (!cell.scope.cancellation_walk_active) {
            cell.scope.cancellation_walk_active = true;
            std.debug.assert(cell.cancellation == .none);
            cell.cancellation = .{ .external = .{ .root = &cell.scope } };
            heap.incRef(cell.handle());
            enqueue = true;
        }
        std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
    }
    std.Io.Threaded.mutexUnlock(&scheduler_state.tree_mutex);
    return enqueue;
}

fn cancelScopeTree(scope: *TaskScope) void {
    var cursor = CancellationCursor{ .root = scope };
    defer cursor.deinit();
    while (!cursor.advance()) std.Thread.yield() catch
        @panic("scheduler cancellation yield failed");
}

fn cancelOne(cell: *TaskCell) core.ScopeCommand {
    _ = cell.cancelled.swap(true, .release);
    std.Io.Threaded.mutexLock(&cell.mutex);
    const decision = unitDecision(cell.policy, .cancel);
    cell.policy = decision.next;
    const wait = if (decision.command == .race_cancellation) cell.waitset.? else null;
    if (wait) |pending| pending.retain();
    std.Io.Threaded.mutexUnlock(&cell.mutex);
    std.debug.assert(decision.command == .none or decision.command == .race_cancellation);
    if (wait) |pending| {
        pending.select(.cancellation);
        pending.release();
    }
    std.Io.Threaded.mutexLock(&cell.scope.mutex);
    const closing = scopeDecision(cell.scope.policy, .close);
    cell.scope.policy = closing.next;
    std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
    return closing.command;
}

fn notifyCancellation(scheduler: *const WorkerScheduler) void {
    const scheduler_state = scheduler.privateState();
    std.Io.Threaded.mutexLock(&scheduler_state.queue_mutex);
    scheduler_state.queue_condition.broadcast(blockingIo());
    std.Io.Threaded.mutexUnlock(&scheduler_state.queue_mutex);
}

fn unlinkParent(cell: *TaskCell) ?*TaskCell {
    const membership = switch (cell.parent_membership) {
        .linked => |membership| membership,
        .detached => unreachable,
    };
    const parent = membership.scope;
    std.Io.Threaded.mutexLock(&parent.mutex);
    if (membership.previous) |previous| switch (previous.parent_membership) {
        .linked => |*previous_link| previous_link.next = membership.next,
        .detached => unreachable,
    } else parent.first = membership.next;
    if (membership.next) |next| switch (next.parent_membership) {
        .linked => |*next_link| next_link.previous = membership.previous,
        .detached => unreachable,
    } else parent.last = membership.previous;
    cell.parent_membership = .{ .detached = parent };
    cell.scheduler.privateState().tree_epoch +%= 1;
    const decision = scopeDecision(parent.policy, .child_terminal);
    parent.policy = decision.next;
    const closing_owner = if (decision.command == .notify_quiescent and !parent.cancellation_walk_active)
        parent.closing_owner
    else
        null;
    if (closing_owner != null) parent.closing_owner = null;
    if (decision.command == .notify_quiescent) parent.quiescent.broadcast(blockingIo());
    std.Io.Threaded.mutexUnlock(&parent.mutex);
    cell.scheduler.releaseDomain().releaseHeader(cell.handle());
    return closing_owner;
}

fn workerMain(scheduler: *const WorkerScheduler) void {
    const scheduler_state = scheduler.privateState();
    var arbitration = ExecutorArbitration{};
    while (true) {
        if (scheduler.runArbitrated(&arbitration)) continue;
        std.Io.Threaded.mutexLock(&scheduler_state.queue_mutex);
        while (scheduler_state.queue_first == null and
            !scheduler.releaseDomain().hasPending() and
            !scheduler_state.stopping)
        {
            scheduler_state.queue_condition.waitUncancelable(blockingIo(), &scheduler_state.queue_mutex);
        }
        if (scheduler_state.stopping and scheduler_state.queue_first == null) {
            std.Io.Threaded.mutexUnlock(&scheduler_state.queue_mutex);
            return;
        }
        std.Io.Threaded.mutexUnlock(&scheduler_state.queue_mutex);
    }
}

fn dispatch(cell: *TaskCell) core.UnitCommand {
    std.Io.Threaded.mutexLock(&cell.mutex);
    const decision = unitDecision(cell.policy, .dispatch);
    cell.policy = decision.next;
    std.Io.Threaded.mutexUnlock(&cell.mutex);
    std.debug.assert(decision.command == .none or decision.command == .cancel_before_dispatch);
    return decision.command;
}

fn timerMain(scheduler: *const WorkerScheduler) void {
    const io = blockingIo();
    const scheduler_state = scheduler.privateState();
    while (true) {
        scheduler_state.timer_wake.reset();
        std.Io.Threaded.mutexLock(&scheduler_state.timer_mutex);
        if (scheduler_state.timer_stopping) {
            std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
            return;
        }
        const first = scheduler_state.timer_heap.peek();
        var next_deadline: ?std.Io.Timestamp = null;
        if (first) |node| {
            const now = std.Io.Clock.awake.now(io);
            if (now.nanoseconds >= node.deadline.nanoseconds) {
                scheduler_state.timer_heap.remove(node);
                std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
                node.wait.select(.timeout);
                node.wait.release();
                continue;
            }
            next_deadline = node.deadline;
        }
        std.Io.Threaded.mutexUnlock(&scheduler_state.timer_mutex);
        if (next_deadline) |deadline| {
            scheduler_state.timer_wake.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => @panic("uncancelable scheduler timer wait was canceled"),
            };
        } else scheduler_state.timer_wake.waitUncancelable(io);
    }
}
