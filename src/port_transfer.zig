//! Shared bounded byte transfers; backend adapters own readiness and error policy.
const std = @import("std");
const heap = @import("heap.zig");
const list = @import("list.zig");
const machine = @import("machine.zig");
const storage = @import("kernel_storage.zig");
const Value = @import("value.zig").Value;

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
