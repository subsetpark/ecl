//! Shared scope transfers and bounded byte transfers for every port backend.
const std = @import("std");
const heap = @import("heap.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const storage = @import("kernel_storage.zig");
const Value = @import("value.zig").Value;
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");

/// Attach outside the resource lock, then consume the membership under it.
/// The caller retains the cell throughout and owns backend rollback on failure.
/// Startup must revalidate backend cancellation under the same resource lock.
pub fn publishScope(
    comptime Cell: type,
    cell: *Cell,
    scope: *scheduler.TaskScope,
    comptime ownership: fn (*Cell) *external.Ownership,
) error{ OutOfMemory, ScopeClosing }!void {
    const membership = try scope.scheduler.attachExternal(scope, external.scopeMember(Cell, cell));
    std.Io.Threaded.mutexLock(&cell.mutex);
    var detached = ownership(cell).publish(membership);
    std.Io.Threaded.mutexUnlock(&cell.mutex);
    detached.detachAll();
}

/// Consumes the held cell mutex and the caller's final execution/publisher
/// reference. The backend must first establish quiescence (including a join
/// when code-image lifetime requires it) and publish its terminal facts.
/// No caller may access the cell after this returns. Drop the execution pin
/// before detachment lets the scope observe completion and destroy its domain.
pub fn completeControllerLocked(
    comptime Cell: type,
    cell: *Cell,
    ownership: *external.Ownership,
    comptime release: fn (*Cell) void,
) void {
    var detached = ownership.release();
    std.Io.Threaded.mutexUnlock(&cell.mutex);
    release(cell);
    detached.detachAll();
}

/// The backend supplies only its locked lifetime predicate and ownership
/// location. This boundary owns lock ordering, origin authorization, destination
/// attachment, revalidation, and consuming rollback for every port kind.
pub fn ScopeTransfer(
    comptime Cell: type,
    comptime ownership: fn (*Cell) *external.Ownership,
    comptime live: fn (*Cell) bool,
) type {
    return struct {
        pub fn prepare(cell: *Cell, from: *anyopaque, to: *anyopaque) heap.PortTransferError!void {
            const destination: *scheduler.TaskScope = @ptrCast(@alignCast(to));
            std.Io.Threaded.mutexLock(&cell.mutex);
            const rejected: ?heap.PortTransferError = if (!live(cell)) error.Closed else switch (ownership(cell).*) {
                .none, .provisional => error.Closed,
                .transferring => error.Busy,
                .owned => |current| if (current.owningScope() == from) null else error.NotOwner,
            };
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            if (rejected) |err| return err;

            // Scope cancellation takes the scope lock before the cell lock.
            // Allocating and attaching under the cell lock would reverse it.
            var token = try destination.scheduler.attachExternal(destination, external.scopeMember(Cell, cell));
            std.Io.Threaded.mutexLock(&cell.mutex);
            const owner = ownership(cell);
            const valid = live(cell) and switch (owner.*) {
                .owned => |current| current.owningScope() == from,
                .none, .provisional, .transferring => false,
            };
            if (valid) owner.beginTransfer(token);
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            if (!valid) {
                token.detach();
                return error.Closed;
            }
        }

        pub fn commit(cell: *Cell) void {
            std.Io.Threaded.mutexLock(&cell.mutex);
            var detached = ownership(cell).commitTransfer();
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            detached.detachAll();
        }

        pub fn abort(cell: *Cell) void {
            std.Io.Threaded.mutexLock(&cell.mutex);
            var detached = ownership(cell).abortTransfer();
            std.Io.Threaded.mutexUnlock(&cell.mutex);
            detached.detachAll();
        }
    };
}

/// One already-accounted capacity slot, with its issuing owner and release
/// policy inseparable. Moving empties the source; releasing an empty token is
/// harmless. Backend code decides when to reserve and when capacity returns.
pub fn Reservation(comptime Owner: type, comptime releaseSlot: fn (*Owner) void) type {
    return union(enum) {
        const Self = @This();
        held: *Owner,
        consumed,

        pub fn acquire(owner_value: *Owner, comptime reserveSlot: fn (*Owner) bool) ?Self {
            if (!reserveSlot(owner_value)) return null;
            return adoptReserved(owner_value);
        }
        /// Consumes one slot already reserved under the owner's own protocol.
        /// This supports reservation coupled to native reaper startup and IDs.
        pub fn adoptReserved(owner_value: *Owner) Self {
            return .{ .held = owner_value };
        }
        pub fn owner(self: *const Self) *Owner {
            return switch (self.*) {
                .held => |issuer| issuer,
                .consumed => @panic("capacity reservation already consumed"),
            };
        }
        pub fn isHeld(self: Self) bool {
            return self == .held;
        }
        /// Consumes either state, returning the reservation or an empty token.
        pub fn take(self: *Self) Self {
            const moved = self.*;
            self.* = .consumed;
            return moved;
        }
        pub fn release(self: *Self) void {
            const moved = self.take();
            switch (moved) {
                .held => |issuer| releaseSlot(issuer),
                .consumed => {},
            }
        }
    };
}

/// Ordered controller-lane ownership, independent of execution, stream state,
/// and wake policy. Queue observations require the owning resource mutex.
/// A ticket owns its turn until retirement, even when execution is cancelled.
pub fn ControllerLane(comptime Cell: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            cell: *Cell,
            previous: ?*Node = null,
            next: ?*Node = null,
            phase: enum { created, queued, active, retired } = .created,
        };
        pub const Ticket = opaque {
            fn node(self: *const Ticket) *Node {
                return @ptrCast(@alignCast(@constCast(self)));
            }
            pub fn create(allocator: std.mem.Allocator, cell: *Cell) error{OutOfMemory}!*Ticket {
                const entry = try allocator.create(Node);
                entry.* = .{ .cell = cell };
                return @ptrCast(entry);
            }
            /// Consumes an unqueued or retired ticket. Cancel readiness first.
            pub fn destroy(self: *Ticket, allocator: std.mem.Allocator) void {
                if (self.linked()) @panic("destroying a queued writer");
                allocator.destroy(self.node());
            }
            pub fn successor(self: *const Ticket) ?*Ticket {
                return if (self.node().next) |next| @ptrCast(next) else null;
            }
            pub fn owner(self: *const Ticket) *Cell {
                return self.node().cell;
            }
            pub fn checkCell(self: *const Ticket, cell: *Cell) void {
                if (self.owner() != cell or !self.linked()) @panic("invalid writer ticket");
            }
            pub fn active(self: *const Ticket) bool {
                return self.node().phase == .active;
            }
            pub fn linked(self: *const Ticket) bool {
                return switch (self.node().phase) {
                    .queued, .active => true,
                    .created, .retired => false,
                };
            }
        };
        count: usize = 0,
        first: ?*Node = null,
        last: ?*Node = null,

        pub fn front(self: *const Self) ?*Ticket {
            return if (self.first) |entry| @ptrCast(entry) else null;
        }
        pub fn empty(self: *const Self) bool {
            return self.front() == null;
        }
        /// Consumes the ticket's created state into FIFO ownership.
        pub fn append(self: *Self, ticket: *Ticket) void {
            const node = ticket.node();
            if (node.phase != .created) @panic("writer ticket already admitted");
            if (self.last) |last| {
                last.next = node;
                node.previous = last;
                node.phase = .queued;
            } else {
                self.first = node;
                node.phase = .active;
            }
            self.last = node;
            self.count += 1;
        }
        /// Retires a ticket and promotes its successor if it owned the turn.
        /// The caller notifies backend readiness, then destroys it outside the lock.
        pub fn remove(self: *Self, ticket: *Ticket) bool {
            const node = ticket.node();
            if (!ticket.linked()) return false;
            const was_active = ticket.active();
            if (node.previous) |previous| previous.next = node.next else self.first = node.next;
            if (node.next) |next| {
                next.previous = node.previous;
                if (was_active) next.phase = .active;
            } else self.last = node.previous;
            self.count -= 1;
            node.phase = .retired;
            node.previous = null;
            node.next = null;
            return true;
        }
    };
}

pub const ReadProgress = union(enum) { pending, eof, data: usize };
pub const WriteProgress = union(enum) { pending, written: usize };

/// A backend supplies read, readSource, and endRead. The caller transfers an
/// active reader and its port value only after driver allocation succeeds.
pub fn ReadDriver(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const address_stable_driver = {};
        pub const ownership: heap.DriverOwnership = .self_owned;
        allocator: std.mem.Allocator,
        port: Value,
        backend: Backend,
        buffer: []u8,
        state: union(enum) {
            reading,
            materializing: list.ByteListMaterializer,
            complete,
        } = .reading,

        pub fn deinit(self: *Self, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            switch (self.state) {
                .materializing => |*materializer| materializer.retire(releases),
                .reading, .complete => {},
            }
            self.backend.endRead();
            allocator.free(self.buffer);
            releases.releaseValue(self.port);
        }

        pub fn advance(evaluator: *machine.Machine, self: *Self) machine.MachineError!machine.WorkProgress {
            try evaluator.pollKernel();
            if (self.state == .reading) {
                const count = switch (try self.backend.read(evaluator, self.buffer)) {
                    .pending => {
                        try evaluator.park(.{ .external = self.backend.readSource() });
                        return .yielded;
                    },
                    .eof => @as(usize, 0),
                    .data => |count| count,
                };
                self.state = .{ .materializing = .init(self.allocator, self.buffer[0..count]) };
            }
            return switch (try self.state.materializing.advance(machine.kernel_poll_quantum)) {
                .pending => .yielded,
                .complete => |item| complete: {
                    self.state.materializing.deinit();
                    self.state = .complete;
                    break :complete .{ .output = item };
                },
            };
        }
    };
}

/// The encoding and writing phases each own the reserved write ticket.
/// Completion consumes the ticket and retains only the encoded buffer for
/// cleanup. Failure leaves every resource owned by the driver.
pub fn WriteDriver(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const address_stable_driver = {};
        pub const ownership: heap.DriverOwnership = .self_owned;
        port: Value,
        bytes_value: Value,
        backend: Backend,
        state: union(enum) {
            encoding: struct { encoder: storage.ByteVectorEncoder, permit: *Backend.WritePermit },
            writing: struct { bytes: storage.ByteVector, permit: *Backend.WritePermit, offset: usize = 0 },
            complete: storage.ByteVector,
        },

        pub fn init(allocator: std.mem.Allocator, port: Value, bytes: Value, backend: Backend, permit: *Backend.WritePermit) Self {
            return .{
                .port = port,
                .bytes_value = bytes,
                .backend = backend,
                .state = .{ .encoding = .{ .encoder = .init(allocator, bytes), .permit = permit } },
            };
        }

        pub fn deinit(self: *Self, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            switch (self.state) {
                .encoding => |*state| {
                    self.backend.cell.abandonWrite(state.permit);
                    state.encoder.deinit();
                },
                .writing => |*state| {
                    self.backend.cell.abandonWrite(state.permit);
                    state.bytes.retire(releases, allocator);
                },
                .complete => |*bytes| bytes.retire(releases, allocator),
            }
            releases.releaseValue(self.bytes_value);
            releases.releaseValue(self.port);
        }

        pub fn advance(evaluator: *machine.Machine, self: *Self) machine.MachineError!machine.WorkProgress {
            try evaluator.pollKernel();
            if (self.state == .encoding) {
                const progress = self.state.encoding.encoder.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidByte => return evaluator.fail(.domain, Backend.invalid_byte_message),
                };
                switch (progress) {
                    .pending => return .yielded,
                    .complete => |bytes| {
                        const permit = self.state.encoding.permit;
                        self.state.encoding.encoder.deinit();
                        self.state = .{ .writing = .{ .bytes = bytes, .permit = permit } };
                    },
                }
            }
            const state = &self.state.writing;
            const source = state.bytes.bytes();
            if (state.offset == source.len) {
                self.backend.cell.finishWrite(state.permit);
                const bytes = state.bytes;
                self.state = .{ .complete = bytes };
                return .completed;
            }
            return switch (try self.backend.write(evaluator, state.permit, source[state.offset..])) {
                .written => |count| progressed: {
                    state.offset += count;
                    break :progressed .yielded;
                },
                .pending => parked: {
                    try evaluator.park(.{ .external = self.backend.cell.writeSource(state.permit) });
                    break :parked .yielded;
                },
            };
        }
    };
}
