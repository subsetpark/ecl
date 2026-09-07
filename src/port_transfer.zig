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

/// Factory-owned storage and capacity. Backend initialization cannot extract
/// or duplicate quota authority; rollback returns it with the allocation.
pub fn Resource(
    comptime Cell: type,
    comptime Issuer: type,
    comptime allocatorOf: fn (*Issuer) std.mem.Allocator,
    comptime reserve: anytype,
    comptime release: fn (*Issuer) void,
) type {
    return struct {
        // Capacity lives in the allocation, never in a transferable value.
        // Copies of a cell pointer cannot duplicate its capacity obligation.
        const Allocation = struct {
            issuer: *Issuer,
            allocator: std.mem.Allocator,
            capacity: enum { vacant, held, returned } = .held,
            cell: Cell,
        };
        fn allocation(cell: *Cell) *Allocation {
            return @alignCast(@fieldParentPtr("cell", cell));
        }
        /// Storage can precede capacity when a pending request waits for a
        /// resource. Its owner keeps this candidate until activation succeeds.
        pub const Candidate = opaque {
            fn state(self: *@This()) *Allocation {
                return @ptrCast(@alignCast(self));
            }
            pub fn deinit(self: *@This()) void {
                const owned = self.state();
                owned.allocator.destroy(owned);
            }
            /// Failure retains the candidate. Success transfers its allocation
            /// into the initialized cell; the request replaces its state.
            pub fn activate(self: *@This(), args: anytype, comptime initialize: anytype) (@typeInfo(@typeInfo(@TypeOf(reserve)).@"fn".return_type.?).error_union.error_set ||
                @typeInfo(@typeInfo(@TypeOf(initialize)).@"fn".return_type.?).error_union.error_set)!*Cell {
                const owned = self.state();
                try reserve(owned.issuer);
                errdefer release(owned.issuer);
                try @call(.auto, initialize, .{ &owned.cell, owned.issuer } ++ args);
                owned.capacity = .held;
                return &owned.cell;
            }
        };
        pub fn prepare(issuer: *Issuer) error{OutOfMemory}!*Candidate {
            const allocator = allocatorOf(issuer);
            const owned = try allocator.create(Allocation);
            owned.issuer = issuer;
            owned.allocator = allocator;
            owned.capacity = .vacant;
            return @ptrCast(owned);
        }
        pub fn create(issuer: *Issuer, args: anytype, comptime initialize: anytype) (error{OutOfMemory} ||
            @typeInfo(@typeInfo(@TypeOf(reserve)).@"fn".return_type.?).error_union.error_set ||
            @typeInfo(@typeInfo(@TypeOf(initialize)).@"fn".return_type.?).error_union.error_set)!*Cell {
            try reserve(issuer);
            errdefer release(issuer);
            const allocator = allocatorOf(issuer);
            const owned = try allocator.create(Allocation);
            errdefer allocator.destroy(owned);
            owned.issuer = issuer;
            owned.allocator = allocator;
            owned.capacity = .held;
            // Initialization owns its partial backend resources on failure;
            // this factory owns storage and capacity on every exit path.
            try @call(.auto, initialize, .{ &owned.cell, issuer } ++ args);
            return &owned.cell;
        }
        /// Called by terminal retirement under the resource's lifetime lock.
        /// Retained metadata keeps its allocation, but no longer holds quota.
        pub fn retire(cell: *Cell) void {
            const owned = allocation(cell);
            switch (owned.capacity) {
                .held => {
                    owned.capacity = .returned;
                    release(owned.issuer);
                },
                .vacant, .returned => {},
            }
        }
        /// Consumes final allocation ownership after backend destruction.
        pub fn destroy(cell: *Cell) void {
            const owned = allocation(cell);
            const allocator = owned.allocator;
            retire(cell);
            allocator.destroy(owned);
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
                    state.permit.cancel();
                    state.encoder.deinit();
                },
                .writing => |*state| {
                    state.permit.cancel();
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
                state.permit.finish();
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
                    try evaluator.park(.{ .external = state.permit.source() });
                    break :parked .yielded;
                },
            };
        }
    };
}
