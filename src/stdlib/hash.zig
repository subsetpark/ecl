//! Exact content digests over ECL byte lists.
const std = @import("std");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const storage = @import("../kernel_storage.zig");
const Value = @import("../value.zig").Value;

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Exact content digests. Binary payloads are ordinary lists of integers in `0...255`.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "sha256",
        .effect = "bytes -- lowercase-hex",
        .doc = "Return the SHA-256 digest of an integer byte list. Every item must be an integer in `0..255`; strings are not byte vectors and are not coerced.",
        .primitive = sha256,
    },
};

fn sha256(fiber: *Fiber) MachineError!void {
    var bytes_value = try fiber.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return fiber.typeError("an integer byte list");
    const encoder = storage.ByteVectorEncoder.init(fiber.allocator, bytes_value.borrow());
    try fiber.startDriver(Sha256Driver{
        .bytes_value = .init(bytes_value.take()),
        .encoder = .init(encoder),
    });
}

const Sha256Driver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    bytes_value: heap.Owned(Value),
    encoder: heap.Owned(storage.ByteVectorEncoder),
    bytes: ?heap.Owned(storage.ByteVector) = null,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    index: usize = 0,
    digest: [32]u8 = @splat(0),
    rendered: [64]u8 = @splat(0),
    text: ?heap.Owned(storage.ByteStringMaterializer) = null,

    pub fn advance(fiber: *Fiber, self: *Sha256Driver) MachineError!machine.WorkProgress {
        if (self.bytes == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return fiber.failAtIndex(
                .domain,
                "hash.sha256 expects integers from 0 through 255",
                self.encoder.borrow().invalid_index.?,
            ),
        }) {
            .pending => return .stepped,
            .complete => |bytes| self.bytes = .init(bytes),
        };
        const input = self.bytes.?.borrow().bytes();
        if (self.index != input.len) {
            const end = self.index + fiber.workBudget().take(input.len - self.index);
            self.hasher.update(input[self.index..end]);
            self.index = end;
            return .stepped;
        }
        if (self.text == null) {
            self.hasher.final(&self.digest);
            self.rendered = std.fmt.bytesToHex(self.digest, .lower);
            self.text = .init(.init(fiber.allocator, &self.rendered));
        }
        return switch (try self.text.?.borrowMut().advance(fiber.workBudget())) {
            .pending => .stepped,
            .complete => |result| .{ .output = result },
        };
    }
};
