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
const Header = value.Header;

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

pub const Config = struct {
    worker_count: usize,

    pub fn validate(self: Config) error{InvalidWorkerCount}!void {
        if (self.worker_count == 0) return error.InvalidWorkerCount;
    }
};

const CellState = union(enum) {
    pending,
    outcome: Value,
    oom,
};

const WaitKind = enum { one, any, deadline };
const Finish = enum { success, language_error, oom };

const RootWaiter = struct {
    scheduler: *Scheduler,
    unit: *machine.Unit,
    ready: std.atomic.Value(bool) = .init(false),
};

const WaitOwner = union(enum) {
    task: *TaskCell,
    root: *RootWaiter,
};

const QueueItem = union(enum) {
    task: *TaskCell,
    wait: *WaitSet,
    release: *ReleaseJob,
};

const QueueEntry = struct {
    next: ?*QueueEntry = null,
    item: ?QueueItem = null,
};

const ReleaseJob = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    queue: QueueEntry = .{},
    cursor: ?heap.ReleaseCursor = null,

    fn start(self: *ReleaseJob, header: *Header) void {
        std.debug.assert(self.cursor == null);
        self.cursor = heap.ReleaseCursor.initHeader(self.allocator, header);
        self.scheduler.enqueueRelease(self);
    }

    fn advance(self: *ReleaseJob) bool {
        if (!self.cursor.?.advance(machine.kernel_poll_quantum)) return false;
        self.cursor = null;
        self.allocator.destroy(self);
        return true;
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
    heap_index: usize = no_timer_index,
};

const no_timer_index = std.math.maxInt(usize);
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
        std.debug.assert(node.heap_index == no_timer_index);
        if (self.len == self.chunks.items.len * timer_chunk_capacity) {
            const chunk = try allocator.create(TimerChunk);
            errdefer allocator.destroy(chunk);
            chunk.* = [_]?*TimerNode{null} ** timer_chunk_capacity;
            try self.chunks.append(allocator, chunk);
        }
        const index = self.len;
        self.len += 1;
        self.set(index, node);
        node.heap_index = index;
        self.siftUp(index);
    }

    fn remove(self: *TimerHeap, node: *TimerNode) void {
        const index = node.heap_index;
        std.debug.assert(index < self.len and self.get(index) == node);
        const last_index = self.len - 1;
        const last = self.get(last_index);
        self.set(last_index, null);
        self.len = last_index;
        node.heap_index = no_timer_index;
        if (index == last_index) return;
        self.set(index, last);
        last.heap_index = index;
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
        left_node.heap_index = right;
        right_node.heap_index = left;
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
    scheduler: *Scheduler,
    owner: WaitOwner,
    kind: WaitKind,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    policy: core.Wait = .registering,
    queue: QueueEntry = .{},
    registrations: []WaitRegistration,
    canonical: []CanonicalSlot,
    initialized: usize = 0,
    canonical_initialized: usize = 0,
    wake_handles: usize = 0,
    awaiting_handles: bool = false,
    request: ?machine.ParkRequest,
    request_release: ?heap.ReleaseCursor = null,
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
    cell_release: ?heap.ReleaseCursor = null,
    timer: TimerNode,

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
        scheduler: *Scheduler,
        owner: WaitOwner,
        kind: WaitKind,
        count: usize,
        request: machine.ParkRequest,
    ) error{OutOfMemory}!*WaitSet {
        const self = try scheduler.allocator.create(WaitSet);
        errdefer scheduler.allocator.destroy(self);
        const registrations = try scheduler.allocator.alloc(WaitRegistration, count);
        errdefer scheduler.allocator.free(registrations);
        const canonical_capacity = if (kind == .any) capacity: {
            const doubled = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
            break :capacity std.math.ceilPowerOfTwo(usize, @max(doubled, 2)) catch
                return error.OutOfMemory;
        } else 0;
        const canonical = try scheduler.allocator.alloc(CanonicalSlot, canonical_capacity);
        errdefer scheduler.allocator.free(canonical);
        self.* = .{
            .allocator = scheduler.allocator,
            .scheduler = scheduler,
            .owner = owner,
            .kind = kind,
            .registrations = registrations,
            .canonical = canonical,
            .request = request,
            .timer = .{ .wait = self },
        };
        self.queue.item = .{ .wait = self };
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
        std.debug.assert(self.timer.heap_index == no_timer_index);
        std.debug.assert(self.registrations.len == 0);
        std.debug.assert(self.canonical.len == 0);
        std.debug.assert(self.request == null and self.request_release == null);
        std.debug.assert(self.cancel_cursor == null and self.cell_release == null);
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
        const decision = waitDecision(
            self.policy,
            .{ .candidate = candidate },
        );
        self.policy = decision.next;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.performWaitCommand(decision.command);
    }

    fn addTimer(self: *WaitSet, milliseconds: i64) error{ Io, OutOfMemory }!void {
        try self.scheduler.ensureTimer();
        self.timer.deadline = std.Io.Clock.awake.now(blockingIo()).addDuration(
            .fromMilliseconds(milliseconds),
        );
        std.Io.Threaded.mutexLock(&self.mutex);
        if (self.policy != .registering) {
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return;
        }
        std.Io.Threaded.mutexLock(&self.scheduler.timer_mutex);
        self.scheduler.timer_heap.insert(self.scheduler.allocator, &self.timer) catch {
            std.Io.Threaded.mutexUnlock(&self.scheduler.timer_mutex);
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return error.OutOfMemory;
        };
        self.retain();
        std.Io.Threaded.mutexUnlock(&self.scheduler.timer_mutex);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        self.scheduler.timer_wake.set(blockingIo());
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
                const value_owned = cell.terminalOwned() catch break :outcome .out_of_memory;
                const outcome_value = value_owned orelse unreachable;
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
                if (self.request_release == null) {
                    self.request_release = heap.ReleaseCursor.initValue(
                        self.allocator,
                        requestOwnedValue(self.request.?),
                    );
                    self.request = null;
                }
                if (!self.request_release.?.advance(budget)) return false;
                self.request_release = null;
                self.setup_phase = .activate;
            },
            .activate => {
                self.activate();
                self.setup_phase = .complete;
                return true;
            },
            .complete => return true,
        };
        return false;
    }

    fn requestCell(self: *WaitSet, index: usize) *TaskCell {
        return taskCell(switch (self.request.?) {
            .task => |task| task,
            .deadline => |deadline| deadline.task,
            .any => |tasks| list.atUnchecked(tasks, index),
            .join => |join| list.atUnchecked(join.tasks, join.index),
            .close_scope => unreachable,
        }).?;
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
        heap.incRef(cell.header);
        std.Io.Threaded.mutexLock(&cell.mutex);
        const terminal = switch (cell.state) {
            .pending => false,
            .outcome, .oom => true,
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
        while (self.cell_release_index != self.initialized and release_budget != 0) {
            if (self.cell_release == null) {
                const registration = &self.registrations[self.cell_release_index];
                const cell = registration.cell orelse {
                    self.cell_release_index += 1;
                    continue;
                };
                registration.cell = null;
                self.cell_release = heap.ReleaseCursor.initHeader(self.allocator, cell.header);
            }
            const released = self.cell_release.?.advanceCounted(release_budget);
            release_budget -= @max(released.consumed, 1);
            if (!released.complete) return .yielded;
            self.cell_release = null;
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
        if (self.request_release == null) {
            self.request_release = heap.ReleaseCursor.initValue(
                self.allocator,
                requestOwnedValue(self.request.?),
            );
            self.request = null;
        }
        if (!self.request_release.?.advance(machine.kernel_poll_quantum)) return .yielded;
        self.request_release = null;
        self.allocator.free(self.registrations);
        self.registrations = &.{};
        self.allocator.free(self.canonical);
        self.canonical = &.{};
        self.release();
        return .complete;
    }

    fn removeTimer(self: *WaitSet) void {
        std.Io.Threaded.mutexLock(&self.scheduler.timer_mutex);
        const owned = self.timer.heap_index != no_timer_index;
        if (owned) self.scheduler.timer_heap.remove(&self.timer);
        std.Io.Threaded.mutexUnlock(&self.scheduler.timer_mutex);
        if (owned) {
            self.scheduler.timer_wake.set(blockingIo());
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
                std.debug.assert(cell.waitset == self and cell.unit.?.park_resume == null);
                const decision = unitDecision(cell.policy, .{ .wake = reason });
                cell.policy = decision.next;
                cell.waitset = null;
                cell.unit.?.park_resume = park_result;
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
                std.debug.assert(root.unit.park_resume == null);
                unit.park_resume = park_result;
                std.Io.Threaded.mutexLock(&scheduler.queue_mutex);
                root.ready.store(true, .release);
                scheduler.queue_condition.broadcast(blockingIo());
                std.Io.Threaded.mutexUnlock(&scheduler.queue_mutex);
            },
        }
    }
};

pub const TaskScope = struct {
    scheduler: *Scheduler,
    mutex: std.Io.Mutex = .init,
    quiescent: std.Io.Condition = .init,
    first: ?*TaskCell = null,
    last: ?*TaskCell = null,
    policy: core.Scope = .{ .open = 0 },
    closing_owner: ?*TaskCell = null,
    cancellation_walk_active: bool = false,
    owner: ?*TaskCell = null,

    pub fn init(scheduler: *Scheduler) TaskScope {
        return .{ .scheduler = scheduler };
    }

    pub fn pending(self: *TaskScope) usize {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.policy.childCount();
    }
};

const TaskCell = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    header: *Header,
    retirement: *ReleaseJob,
    mutex: std.Io.Mutex = .init,
    state: CellState = .pending,
    policy: core.Unit = .constructing,
    cancelled: std.atomic.Value(bool) = .init(false),
    unit: ?*machine.Unit,
    scope: TaskScope,
    parent: *TaskScope,
    parent_previous: ?*TaskCell = null,
    parent_next: ?*TaskCell = null,
    parent_linked: bool = false,
    queue: QueueEntry = .{},
    waiter_first: ?*WaitRegistration = null,
    waiter_last: ?*WaitRegistration = null,
    waitset: ?*WaitSet = null,
    finish_disposition: ?Finish = null,
    terminal_ready: ?CellState = null,
    result_materializer: ?kernel_storage.ValueMaterializer = null,
    unit_release: ?heap.ReleaseCursor = null,
    cancellation_cursor: ?CancellationCursor = null,
    publication_started: bool = false,

    fn destroy(allocator: std.mem.Allocator, payload: *anyopaque) ?Value {
        const self: *TaskCell = @ptrCast(@alignCast(payload));
        std.debug.assert(self.unit == null and !self.parent_linked);
        std.debug.assert(self.terminal_ready == null);
        std.debug.assert(self.result_materializer == null);
        std.debug.assert(self.unit_release == null);
        std.debug.assert(self.cancellation_cursor == null);
        std.debug.assert(self.publication_started);
        const child = switch (self.state) {
            .pending => unreachable,
            .outcome => |outcome| outcome,
            .oom => null,
        };
        allocator.destroy(self);
        return child;
    }

    fn terminalOwned(self: *TaskCell) error{OutOfMemory}!?Value {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return switch (self.state) {
            .pending => null,
            .outcome => |outcome| owned: {
                heap.retainValue(outcome);
                break :owned outcome;
            },
            .oom => error.OutOfMemory,
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

    fn advance(self: *CancellationCursor) bool {
        const scheduler = self.root.scheduler;
        const old_retained = self.retained_next;
        std.Io.Threaded.mutexLock(&scheduler.tree_mutex);
        var current = if (self.started and self.observed_epoch == scheduler.tree_epoch)
            old_retained
        else
            self.root.first;
        var visited: usize = 0;
        while (current != null and visited < cancellation_tree_quantum) : (visited += 1) {
            const cell = current.?;
            const following = nextDescendant(self.root, cell);
            cancelOne(cell);
            current = following;
        }
        if (current) |next| heap.incRef(next.header);
        self.retained_next = current;
        self.observed_epoch = scheduler.tree_epoch;
        self.started = true;
        std.Io.Threaded.mutexUnlock(&scheduler.tree_mutex);
        if (old_retained) |old| heap.decRef(old.allocator, old.header);
        notifyCancellation(scheduler);
        return current == null;
    }

    fn deinit(self: *CancellationCursor) void {
        if (self.retained_next) |cell| heap.decRef(cell.allocator, cell.header);
        self.* = undefined;
    }
};

const CancelDriver = struct {
    task: Value,
    cursor: CancellationCursor,
    owner_cancelled: bool = false,

    fn advance(
        evaluator: *machine.Machine,
        raw: *anyopaque,
    ) machine.MachineError!machine.WorkProgress {
        const self: *CancelDriver = @ptrCast(@alignCast(raw));
        if (!self.owner_cancelled) {
            const cell = taskCell(self.task).?;
            std.Io.Threaded.mutexLock(&cell.scheduler.tree_mutex);
            cancelOne(cell);
            std.Io.Threaded.mutexUnlock(&cell.scheduler.tree_mutex);
            notifyCancellation(cell.scheduler);
            self.owner_cancelled = true;
        }
        if (!self.cursor.advance()) return .yielded;
        // Cancellation is cleanup-critical: if this unit cancelled itself or
        // an ancestor, finish propagating the tree before observing its own
        // flag. The cursor still returns to the scheduler after every slice.
        try evaluator.pollKernel();
        return .completed;
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *CancelDriver = @ptrCast(@alignCast(raw));
        self.cursor.deinit();
        heap.releaseValue(allocator, self.task);
        allocator.destroy(self);
    }
};

pub const SpawnRequest = struct {
    parent_unit: *machine.Unit,
    parent_scope: *env.Scope,
    parent_home: ?*modules.ModuleGeneration,
    quotation: *Header,
};

pub const SpawnError = error{ OutOfMemory, Io };

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    config: Config,
    start_mutex: std.Io.Mutex = .init,
    queue_mutex: std.Io.Mutex = .init,
    tree_mutex: std.Io.Mutex = .init,
    tree_epoch: u64 = 0,
    queue_condition: std.Io.Condition = .init,
    queue_first: ?*QueueEntry = null,
    queue_last: ?*QueueEntry = null,
    stopping: bool = false,
    threads: []std.Thread = &.{},
    worker_threads: std.atomic.Value(usize) = .init(0),
    timer_thread: ?std.Thread = null,
    timer_mutex: std.Io.Mutex = .init,
    timer_wake: std.Io.Event = .unset,
    timer_stopping: bool = false,
    timer_heap: TimerHeap = .{},
    timer_threads: std.atomic.Value(usize) = .init(0),
    next_identity: std.atomic.Value(u64) = .init(1),

    pub fn init(allocator: std.mem.Allocator, config: Config) Scheduler {
        config.validate() catch @panic("scheduler worker count must be positive");
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Scheduler, root_scope: *TaskScope) void {
        self.closeRootScope(root_scope);
        std.Io.Threaded.mutexLock(&self.timer_mutex);
        self.timer_stopping = true;
        std.Io.Threaded.mutexUnlock(&self.timer_mutex);
        self.timer_wake.set(blockingIo());
        if (self.timer_thread) |thread| thread.join();
        self.timer_thread = null;
        self.timer_heap.deinit(self.allocator);

        std.Io.Threaded.mutexLock(&self.queue_mutex);
        self.stopping = true;
        self.queue_condition.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        for (self.threads) |thread| thread.join();
        if (self.threads.len > 0) self.allocator.free(self.threads);
        self.threads = &.{};
        std.debug.assert(self.queue_first == null);
        self.* = undefined;
    }

    pub fn workerThreadCount(self: *const Scheduler) usize {
        return self.worker_threads.load(.acquire);
    }

    pub fn timerThreadCount(self: *const Scheduler) usize {
        return self.timer_threads.load(.acquire);
    }

    pub fn timerEntryCount(self: *Scheduler) usize {
        std.Io.Threaded.mutexLock(&self.timer_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.timer_mutex);
        return self.timer_heap.len;
    }

    fn ensureStarted(self: *Scheduler) SpawnError!void {
        std.Io.Threaded.mutexLock(&self.start_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.start_mutex);
        if (self.threads.len != 0) return;
        const threads = try self.allocator.alloc(std.Thread, self.config.worker_count);
        var started: usize = 0;
        errdefer {
            std.Io.Threaded.mutexLock(&self.queue_mutex);
            self.stopping = true;
            self.queue_condition.broadcast(blockingIo());
            std.Io.Threaded.mutexUnlock(&self.queue_mutex);
            for (threads[0..started]) |thread| thread.join();
            self.stopping = false;
            self.allocator.free(threads);
        }
        while (started < threads.len) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, workerMain, .{self}) catch return error.Io;
        }
        self.threads = threads;
        self.worker_threads.store(threads.len, .release);
    }

    fn ensureTimer(self: *Scheduler) error{Io}!void {
        std.Io.Threaded.mutexLock(&self.start_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.start_mutex);
        if (self.timer_thread != null) return;
        self.timer_thread = std.Thread.spawn(.{}, timerMain, .{self}) catch return error.Io;
        self.timer_threads.store(1, .release);
    }

    pub fn spawn(self: *Scheduler, parent: *TaskScope, request: SpawnRequest) SpawnError!Value {
        try self.ensureStarted();
        const unit = try self.allocator.create(machine.Unit);
        errdefer self.allocator.destroy(unit);
        unit.* = machine.Unit.init(
            self.allocator,
            .empty,
            request.parent_unit.environment,
            request.parent_unit.archive,
            request.parent_unit.output,
            request.parent_unit.arguments,
            // SAFETY: The child cannot run until publication below, and its
            // cancellation pointer is installed from the owning TaskCell first.
            undefined,
        );
        errdefer unit.deinit();
        unit.root_scope = env.Scope.lazy(self.allocator, request.parent_scope);
        unit.registry = request.parent_unit.registry;
        unit.diagnostics = request.parent_unit.diagnostics;
        unit.console = request.parent_unit.console;
        unit.host_io = request.parent_unit.host_io;
        unit.ecl_path = request.parent_unit.ecl_path;
        unit.idiom_mode = request.parent_unit.idiom_mode;
        unit.phrase_recognizer = request.parent_unit.phrase_recognizer;
        unit.scheduler = self;
        unit.is_root_unit = false;
        if (request.parent_home) |generation| try unit.pinGeneration(generation);

        const cell = try self.allocator.create(TaskCell);
        errdefer self.allocator.destroy(cell);
        const retirement = try self.allocator.create(ReleaseJob);
        errdefer self.allocator.destroy(retirement);
        retirement.* = .{ .allocator = self.allocator, .scheduler = self };
        retirement.queue.item = .{ .release = retirement };
        cell.* = .{
            .allocator = self.allocator,
            .scheduler = self,
            // SAFETY: Header publication requires this stable cell address;
            // no observer can reach the cell until the header is installed.
            .header = undefined,
            .retirement = retirement,
            .unit = unit,
            .scope = TaskScope.init(self),
            .parent = parent,
        };
        cell.queue.item = .{ .task = cell };
        cell.scope.owner = cell;
        unit.cancelled = &cell.cancelled;
        unit.task_scope = &cell.scope;
        const identity = self.next_identity.fetchAdd(1, .monotonic);
        const initializing = try heap.allocTaskHeader(
            self.allocator,
            identity,
            cell,
            TaskCell.destroy,
        );
        const header = heap.publish(initializing);
        cell.header = header;
        machine.initialize(unit, request.quotation);

        std.Io.Threaded.mutexLock(&self.tree_mutex);
        std.Io.Threaded.mutexLock(&parent.mutex);
        const scope_decision = scopeDecision(parent.policy, .register_child);
        parent.policy = scope_decision.next;
        if (parent.last) |last| {
            last.parent_next = cell;
            cell.parent_previous = last;
        } else parent.first = cell;
        parent.last = cell;
        cell.parent_linked = true;
        self.tree_epoch +%= 1;
        heap.incRef(header);
        const kill_on_arrival = scope_decision.command == .cancel_arriving_child;
        std.Io.Threaded.mutexUnlock(&parent.mutex);
        std.Io.Threaded.mutexUnlock(&self.tree_mutex);

        heap.incRef(header);
        std.Io.Threaded.mutexLock(&cell.mutex);
        const publish = unitDecision(cell.policy, .publish);
        cell.policy = publish.next;
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        std.debug.assert(publish.command == .enqueue);
        if (kill_on_arrival) cancelArriving(cell);
        self.enqueueTask(cell);
        return .{ .task = header };
    }

    pub fn runRoot(
        self: *Scheduler,
        unit: *machine.Unit,
        code: *Header,
    ) machine.MachineError!void {
        machine.initialize(unit, code);
        while (true) switch (try machine.runSlice(unit)) {
            .completed => return,
            .yielded => std.Thread.yield() catch @panic("scheduler root yield failed"),
            .parked => try self.handleRootPark(unit),
        };
    }

    fn handleRootPark(self: *Scheduler, unit: *machine.Unit) error{OutOfMemory}!void {
        const request = unit.park_request.?;
        if (request == .close_scope) {
            const status = request.close_scope;
            unit.park_request = null;
            self.closeRootScope(@ptrCast(@alignCast(unit.task_scope.?)));
            unit.park_resume = .{ .scope_closed = status };
            return;
        }
        var root = RootWaiter{ .scheduler = self, .unit = unit };
        const wait = try WaitSet.create(
            self,
            .{ .root = &root },
            requestKind(request),
            requestCount(request),
            request,
        );
        unit.park_request = null;
        while (!wait.advanceSetup()) std.Thread.yield() catch
            @panic("scheduler root wait setup yield failed");
        while (!root.ready.load(.acquire)) {
            std.Io.Threaded.mutexLock(&self.queue_mutex);
            if (!root.ready.load(.acquire) and self.queue_first == null and !self.stopping) {
                self.queue_condition.waitUncancelable(blockingIo(), &self.queue_mutex);
            }
            std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        }
    }

    pub fn cancelOwned(
        self: *Scheduler,
        evaluator: *machine.Machine,
        task: Value,
    ) error{OutOfMemory}!void {
        _ = self;
        const cell = taskCell(task).?;
        const driver = try evaluator.allocator().create(CancelDriver);
        driver.* = .{
            .task = task,
            .cursor = .{ .root = &cell.scope },
        };
        evaluator.installWorkDriver(driver, CancelDriver.advance, CancelDriver.destroy);
    }

    pub fn installTasksDriver(
        self: *Scheduler,
        evaluator: *machine.Machine,
        scope: *TaskScope,
    ) error{OutOfMemory}!void {
        const driver = try self.allocator.create(TasksDriver);
        driver.* = .{ .scheduler = self, .scope = scope };
        evaluator.installWorkDriver(driver, TasksDriver.advance, TasksDriver.destroy);
    }

    fn closeRootScope(self: *Scheduler, scope: *TaskScope) void {
        _ = self;
        std.debug.assert(scope.owner == null);
        std.Io.Threaded.mutexLock(&scope.mutex);
        const decision = scopeDecision(scope.policy, .close);
        scope.policy = decision.next;
        const cancel_children = decision.command == .cancel_children;
        std.Io.Threaded.mutexUnlock(&scope.mutex);
        if (cancel_children) cancelScopeTree(scope);
        std.Io.Threaded.mutexLock(&scope.mutex);
        while (scope.policy.childCount() != 0) {
            scope.quiescent.waitUncancelable(blockingIo(), &scope.mutex);
        }
        std.Io.Threaded.mutexUnlock(&scope.mutex);
    }

    fn enqueueTask(self: *Scheduler, cell: *TaskCell) void {
        self.enqueue(&cell.queue);
    }

    fn enqueueWait(self: *Scheduler, wait: *WaitSet) void {
        self.enqueue(&wait.queue);
    }

    fn enqueueRelease(self: *Scheduler, release: *ReleaseJob) void {
        self.enqueue(&release.queue);
    }

    fn enqueue(self: *Scheduler, entry: *QueueEntry) void {
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        std.debug.assert(entry.next == null);
        if (self.queue_last) |last| last.next = entry else self.queue_first = entry;
        self.queue_last = entry;
        self.queue_condition.signal(blockingIo());
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
    }

    fn popLocked(self: *Scheduler) ?*QueueEntry {
        const entry = self.queue_first orelse return null;
        self.queue_first = entry.next;
        if (self.queue_first == null) self.queue_last = null;
        entry.next = null;
        return entry;
    }

    fn execute(self: *Scheduler, cell: *TaskCell) void {
        const unit = cell.unit.?;
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

    fn parkTask(self: *Scheduler, cell: *TaskCell) void {
        const unit = cell.unit.?;
        const request = unit.park_request.?;
        const wait = WaitSet.create(
            self,
            .{ .task = cell },
            requestKind(request),
            requestCount(request),
            request,
        ) catch return self.finish(cell, .oom);
        unit.park_request = null;

        std.Io.Threaded.mutexLock(&cell.mutex);
        const parking = unitDecision(cell.policy, .park);
        cell.policy = parking.next;
        if (parking.command == .register_wait) cell.waitset = wait;
        std.Io.Threaded.mutexUnlock(&cell.mutex);

        if (parking.command == .enqueue) {
            unit.park_resume = .cancelled;
            wait.discard();
            self.enqueueTask(cell);
            return;
        }
        std.debug.assert(parking.command == .register_wait);
        if (!wait.advanceSetup()) self.enqueueTask(cell);
    }

    fn advanceParkSetup(self: *Scheduler, cell: *TaskCell) void {
        const wait = cell.waitset.?;
        if (!wait.advanceSetup()) self.enqueueTask(cell);
    }

    fn finish(self: *Scheduler, cell: *TaskCell, disposition: Finish) void {
        const completion: core.Completion = switch (disposition) {
            .success => .success,
            .language_error => .language_error,
            .oom => .out_of_memory,
        };
        std.Io.Threaded.mutexLock(&cell.mutex);
        const finishing = unitDecision(cell.policy, .{ .body_finished = completion });
        cell.policy = finishing.next;
        cell.finish_disposition = disposition;
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        std.debug.assert(finishing.command == .close_scope);
        self.beginTaskClose(cell);
    }

    fn beginTaskClose(self: *Scheduler, cell: *TaskCell) void {
        std.Io.Threaded.mutexLock(&self.tree_mutex);
        std.Io.Threaded.mutexLock(&cell.scope.mutex);
        const decision = scopeDecision(cell.scope.policy, .close);
        cell.scope.policy = decision.next;
        const ready = decision.command == .notify_quiescent;
        if (!ready) {
            std.debug.assert(cell.scope.closing_owner == null);
            cell.scope.closing_owner = cell;
        }
        if (decision.command == .cancel_children) {
            std.debug.assert(!cell.scope.cancellation_walk_active);
            cell.scope.cancellation_walk_active = true;
            std.debug.assert(cell.cancellation_cursor == null);
            cell.cancellation_cursor = .{ .root = &cell.scope };
        }
        std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
        std.Io.Threaded.mutexUnlock(&self.tree_mutex);
        if (decision.command == .cancel_children) {
            self.enqueueTask(cell);
            return;
        }
        if (ready) self.publishFinished(cell);
    }

    fn advanceTaskClose(self: *Scheduler, cell: *TaskCell) void {
        if (!cell.cancellation_cursor.?.advance()) {
            self.enqueueTask(cell);
            return;
        }
        cell.cancellation_cursor.?.deinit();
        cell.cancellation_cursor = null;
        std.Io.Threaded.mutexLock(&self.tree_mutex);
        std.Io.Threaded.mutexLock(&cell.scope.mutex);
        cell.scope.cancellation_walk_active = false;
        const closing_owner = if (cell.scope.policy == .closed)
            cell.scope.closing_owner
        else
            null;
        if (closing_owner != null) cell.scope.closing_owner = null;
        std.Io.Threaded.mutexUnlock(&cell.scope.mutex);
        std.Io.Threaded.mutexUnlock(&self.tree_mutex);
        if (closing_owner) |owner| self.publishFinished(owner);
    }

    fn publishFinished(self: *Scheduler, cell: *TaskCell) void {
        if (!cell.publication_started) {
            if (cell.terminal_ready == null) {
                cell.terminal_ready = self.materializeTerminal(cell) orelse {
                    self.enqueueTask(cell);
                    return;
                };
            }
            if (!self.advanceFinishedUnitCleanup(cell)) {
                self.enqueueTask(cell);
                return;
            }
            const terminal = cell.terminal_ready.?;
            cell.terminal_ready = null;
            const unit = cell.unit.?;
            unit.deinit();
            self.allocator.destroy(unit);
            cell.unit = null;
            cell.finish_disposition = null;
            std.Io.Threaded.mutexLock(&cell.mutex);
            std.debug.assert(cell.state == .pending);
            const completed = unitDecision(cell.policy, .scope_quiescent);
            cell.policy = completed.next;
            std.debug.assert(completed.command == .publish);
            cell.state = terminal;
            cell.publication_started = true;
            std.Io.Threaded.mutexUnlock(&cell.mutex);
        }
        self.advancePublication(cell);
    }

    fn advanceFinishedUnitCleanup(self: *Scheduler, cell: *TaskCell) bool {
        const unit = cell.unit.?;
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) {
            if (cell.unit_release) |*release| {
                const progress = release.advanceCounted(budget);
                budget -= @max(progress.consumed, 1);
                if (!progress.complete) return false;
                cell.unit_release = null;
                continue;
            }
            if (unit.park_request) |request| {
                unit.park_request = null;
                cell.unit_release = heap.ReleaseCursor.initValue(
                    self.allocator,
                    requestOwnedValue(request),
                );
                continue;
            }
            const item = unit.stack.pop() orelse return true;
            cell.unit_release = heap.ReleaseCursor.initValue(self.allocator, item);
        }
        return false;
    }

    fn materializeTerminal(self: *Scheduler, cell: *TaskCell) ?CellState {
        const unit = cell.unit.?;
        const disposition = cell.finish_disposition.?;
        return switch (disposition) {
            .oom => .oom,
            .language_error => outcome: {
                const failure = unit.takeError().?;
                const wrapped = machine.outcomeDict(self.allocator, "err", failure) catch break :outcome .oom;
                break :outcome .{ .outcome = wrapped };
            },
            .success => outcome: {
                if (cell.result_materializer == null) {
                    cell.result_materializer = kernel_storage.ValueMaterializer.init(
                        self.allocator,
                        unit.stack.items,
                    );
                }
                const materialized = cell.result_materializer.?.advance(machine.kernel_poll_quantum) catch {
                    cell.result_materializer.?.deinit();
                    cell.result_materializer = null;
                    break :outcome .oom;
                };
                const results = switch (materialized) {
                    .pending => return null,
                    .complete => |complete| complete,
                };
                cell.result_materializer.?.deinit();
                cell.result_materializer = null;
                const wrapped = machine.outcomeDict(self.allocator, "ok", results) catch
                    break :outcome .oom;
                break :outcome .{ .outcome = wrapped };
            },
        };
    }

    fn advancePublication(self: *Scheduler, cell: *TaskCell) void {
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

        std.Io.Threaded.mutexLock(&self.tree_mutex);
        const closing_parent = unlinkParent(cell);
        std.Io.Threaded.mutexUnlock(&self.tree_mutex);
        std.Io.Threaded.mutexLock(&self.queue_mutex);
        self.queue_condition.broadcast(blockingIo());
        std.Io.Threaded.mutexUnlock(&self.queue_mutex);
        const retirement = cell.retirement;
        const header = cell.header;
        if (closing_parent) |parent| self.enqueueTask(parent);
        retirement.start(header);
    }

    fn runQueued(self: *Scheduler, cell: *TaskCell) void {
        std.Io.Threaded.mutexLock(&cell.mutex);
        const phase = cell.policy.phase();
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        switch (phase) {
            .ready => {
                dispatch(cell);
                self.execute(cell);
            },
            .closing => if (cell.cancellation_cursor != null)
                self.advanceTaskClose(cell)
            else
                self.publishFinished(cell),
            .parked => self.advanceParkSetup(cell),
            .done => self.advancePublication(cell),
            .constructing, .running => unreachable,
        }
    }

    fn runWait(self: *Scheduler, wait: *WaitSet) void {
        switch (wait.advanceDelivery()) {
            .yielded => self.enqueueWait(wait),
            .waiting, .complete => {},
        }
    }

    fn runRelease(self: *Scheduler, release: *ReleaseJob) void {
        if (!release.advance()) self.enqueueRelease(release);
    }
};

fn requestKind(request: machine.ParkRequest) WaitKind {
    return switch (request) {
        .task, .join => .one,
        .any => .any,
        .deadline => .deadline,
        .close_scope => unreachable,
    };
}

fn requestCount(request: machine.ParkRequest) usize {
    return switch (request) {
        .task, .deadline, .join => 1,
        .any => |task_list| @intCast(task_list.list.length()),
        .close_scope => unreachable,
    };
}

fn requestOwnedValue(request: machine.ParkRequest) Value {
    return switch (request) {
        .task, .any => |item| item,
        .deadline => |deadline| deadline.task,
        .join => |join| join.tasks,
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

/// Two-pass, generic-list snapshot of pending descendants. Only the cursor's
/// next cell is retained between slices; collected task ownership moves
/// directly into the exact-capacity result header.
const TasksDriver = struct {
    scheduler: *Scheduler,
    scope: *TaskScope,
    next: ?*TaskCell = null,
    started: bool = false,
    phase: enum { count, collect } = .count,
    count: usize = 0,
    result: ?*heap.InitializingHeader = null,
    filled: usize = 0,

    fn advance(
        evaluator: *machine.Machine,
        raw: *anyopaque,
    ) machine.MachineError!machine.WorkProgress {
        const self: *TasksDriver = @ptrCast(@alignCast(raw));
        try evaluator.pollKernel();
        const old_next = self.next;
        std.Io.Threaded.mutexLock(&self.scheduler.tree_mutex);
        var current = if (self.started) old_next else self.scope.first;
        var visited: usize = 0;
        while (current != null and visited < task_snapshot_quantum) : (visited += 1) {
            const cell = current.?;
            current = nextDescendant(self.scope, cell);
            if (cell.state != .pending) continue;
            switch (self.phase) {
                .count => self.count = std.math.add(usize, self.count, 1) catch {
                    std.Io.Threaded.mutexUnlock(&self.scheduler.tree_mutex);
                    return error.OutOfMemory;
                },
                .collect => if (self.filled != self.count) {
                    heap.incRef(cell.header);
                    heap.initValues(self.result.?)[self.filled] = .{ .task = cell.header };
                    self.filled += 1;
                    heap.setInitializingLength(self.result.?, self.filled);
                },
            }
        }
        if (current) |following| heap.incRef(following.header);
        self.next = current;
        self.started = true;
        std.Io.Threaded.mutexUnlock(&self.scheduler.tree_mutex);
        if (old_next) |old| heap.decRef(self.scheduler.allocator, old.header);
        if (current != null) return .yielded;
        switch (self.phase) {
            .count => {
                if (self.count >= std.math.maxInt(u32)) return error.OutOfMemory;
                self.result = try heap.allocHeader(
                    self.scheduler.allocator,
                    .generic_spine,
                    0,
                    self.count,
                );
                self.phase = .collect;
                self.next = null;
                self.started = false;
                return .yielded;
            },
            .collect => {
                const result: Value = .{ .list = heap.publish(self.result.?) };
                self.result = null;
                errdefer heap.releaseValue(self.scheduler.allocator, result);
                try evaluator.pushOwned(result);
                return .completed;
            },
        }
    }

    fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *TasksDriver = @ptrCast(@alignCast(raw));
        if (self.next) |cell| heap.decRef(allocator, cell.header);
        if (self.result) |result| heap.decRef(allocator, heap.publish(result));
        allocator.destroy(self);
    }
};

fn nextDescendant(root: *const TaskScope, cell: *TaskCell) ?*TaskCell {
    if (cell.scope.first) |child| return child;
    var current = cell;
    while (true) {
        if (current.parent_next) |sibling| return sibling;
        if (current.parent == root) return null;
        current = current.parent.owner.?;
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
    std.Io.Threaded.mutexLock(&cell.scheduler.tree_mutex);
    cancelOne(cell);
    std.Io.Threaded.mutexUnlock(&cell.scheduler.tree_mutex);
    notifyCancellation(cell.scheduler);
}

fn cancelScopeTree(scope: *TaskScope) void {
    var cursor = CancellationCursor{ .root = scope };
    defer cursor.deinit();
    while (!cursor.advance()) std.Thread.yield() catch
        @panic("scheduler cancellation yield failed");
}

fn cancelOne(cell: *TaskCell) void {
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
}

fn notifyCancellation(scheduler: *Scheduler) void {
    std.Io.Threaded.mutexLock(&scheduler.queue_mutex);
    scheduler.queue_condition.broadcast(blockingIo());
    std.Io.Threaded.mutexUnlock(&scheduler.queue_mutex);
}

fn unlinkParent(cell: *TaskCell) ?*TaskCell {
    const parent = cell.parent;
    std.Io.Threaded.mutexLock(&parent.mutex);
    if (cell.parent_previous) |previous| previous.parent_next = cell.parent_next else parent.first = cell.parent_next;
    if (cell.parent_next) |next| next.parent_previous = cell.parent_previous else parent.last = cell.parent_previous;
    cell.parent_linked = false;
    cell.scheduler.tree_epoch +%= 1;
    const decision = scopeDecision(parent.policy, .child_terminal);
    parent.policy = decision.next;
    const closing_owner = if (decision.command == .notify_quiescent and !parent.cancellation_walk_active)
        parent.closing_owner
    else
        null;
    if (closing_owner != null) parent.closing_owner = null;
    if (decision.command == .notify_quiescent) parent.quiescent.broadcast(blockingIo());
    std.Io.Threaded.mutexUnlock(&parent.mutex);
    heap.decRef(cell.allocator, cell.header);
    return closing_owner;
}

fn workerMain(scheduler: *Scheduler) void {
    while (true) {
        std.Io.Threaded.mutexLock(&scheduler.queue_mutex);
        while (scheduler.queue_first == null and !scheduler.stopping) {
            scheduler.queue_condition.waitUncancelable(blockingIo(), &scheduler.queue_mutex);
        }
        if (scheduler.stopping and scheduler.queue_first == null) {
            std.Io.Threaded.mutexUnlock(&scheduler.queue_mutex);
            return;
        }
        const entry = scheduler.popLocked().?;
        std.Io.Threaded.mutexUnlock(&scheduler.queue_mutex);
        switch (entry.item.?) {
            .task => |cell| scheduler.runQueued(cell),
            .wait => |wait| scheduler.runWait(wait),
            .release => |release| scheduler.runRelease(release),
        }
    }
}

fn dispatch(cell: *TaskCell) void {
    std.Io.Threaded.mutexLock(&cell.mutex);
    const decision = unitDecision(cell.policy, .dispatch);
    cell.policy = decision.next;
    std.Io.Threaded.mutexUnlock(&cell.mutex);
    std.debug.assert(decision.command == .none);
}

fn timerMain(scheduler: *Scheduler) void {
    const io = blockingIo();
    while (true) {
        scheduler.timer_wake.reset();
        std.Io.Threaded.mutexLock(&scheduler.timer_mutex);
        if (scheduler.timer_stopping) {
            std.Io.Threaded.mutexUnlock(&scheduler.timer_mutex);
            return;
        }
        const first = scheduler.timer_heap.peek();
        var next_deadline: ?std.Io.Timestamp = null;
        if (first) |node| {
            const now = std.Io.Clock.awake.now(io);
            if (now.nanoseconds >= node.deadline.nanoseconds) {
                scheduler.timer_heap.remove(node);
                std.Io.Threaded.mutexUnlock(&scheduler.timer_mutex);
                node.wait.select(.timeout);
                node.wait.release();
                continue;
            }
            next_deadline = node.deadline;
        }
        std.Io.Threaded.mutexUnlock(&scheduler.timer_mutex);
        if (next_deadline) |deadline| {
            scheduler.timer_wake.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => @panic("uncancelable scheduler timer wait was canceled"),
            };
        } else scheduler.timer_wake.waitUncancelable(io);
    }
}
