//! Hostile-input-safe gzip decompression over ECL byte lists.
const std = @import("std");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const storage = @import("../kernel_storage.zig");

const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const max_output_bytes: usize = 1_073_741_824;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Hostile-input-safe gzip decompression. Binary payloads are ordinary lists of integers in
    \\`0...255`.
;

pub const words = [_]env.BuiltinWord{.{
    .name = "decompress",
    .effect = "bytes -- bytes",
    .doc = "Decompress one gzip member and return its payload. The payload is limited to 1,073,741,824 bytes. Malformed gzip data, trailing input, a size or checksum that disagrees with the footer, an over-limit payload, and invalid byte items are `` `domain ``; a non-list input is `` `type ``.",
    .primitive = decompress,
}};

fn decompress(fiber: *Fiber) MachineError!void {
    var bytes = try fiber.popValue();
    errdefer bytes.deinit();
    if (bytes.borrow() != .list) return fiber.typeError("an integer byte list");
    const encoder = storage.ByteVectorEncoder.init(fiber.allocator, bytes.borrow());
    try fiber.startDriver(DecompressDriver{
        .bytes_value = .init(bytes.take()),
        .encoder = .init(encoder),
    });
}

const Decoder = struct {
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    const State = struct {
        input: std.Io.Reader,
        window: [std.compress.flate.max_window_len]u8,
        decompressor: std.compress.flate.Decompress,
    };

    allocator: std.mem.Allocator,
    state: *State,

    fn init(allocator: std.mem.Allocator, input_bytes: []const u8) error{OutOfMemory}!Decoder {
        const state = try allocator.create(State);
        state.input = .fixed(input_bytes);
        state.decompressor = .init(&state.input, .gzip, &state.window);
        return .{ .allocator = allocator, .state = state };
    }

    fn read(self: *Decoder, output: []u8) std.Io.Reader.ShortError!usize {
        return self.state.decompressor.reader.readSliceShort(output);
    }

    fn consumedAllInput(self: *const Decoder) bool {
        return self.state.input.seek == self.state.input.end;
    }

    pub fn deinit(self: *Decoder) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }
};

/// Encodes the input, sizes the output from the footer, inflates and checks
/// it, then copies it into a byte list; every phase spends the work budget.
const DecompressDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    bytes_value: heap.Owned(@import("../value.zig").Value),
    encoder: heap.Owned(storage.ByteVectorEncoder),
    bytes: ?heap.Owned(storage.ByteVector) = null,
    output: ?heap.Owned([]u8) = null,
    decoder: ?heap.Owned(Decoder) = null,
    phase: enum { inflate, verify, materialize } = .inflate,
    index: usize = 0,
    crc: std.hash.Crc32 = .init(),
    result: ?heap.Owned(list.ByteListMaterializer) = null,

    pub fn advance(fiber: *Fiber, self: *DecompressDriver) MachineError!machine.WorkProgress {
        if (self.bytes == null) {
            switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidByte => return fiber.failAtIndex(
                    .domain,
                    "gzip.decompress expects integers from 0 through 255",
                    self.encoder.borrow().invalid_index.?,
                ),
            }) {
                .pending => return .stepped,
                .complete => |bytes| self.bytes = .init(bytes),
            }
            return .stepped;
        }
        const compressed = self.bytes.?.borrow().bytes();
        if (self.output == null) {
            if (compressed.len < 18 or compressed[0] != 0x1f or compressed[1] != 0x8b)
                return fiber.fail(.domain, "malformed gzip data");
            const expected: usize = std.mem.readInt(u32, compressed[compressed.len - 4 ..][0..4], .little);
            if (expected > max_output_bytes)
                return fiber.fail(.domain, "gzip payload exceeds the 1 GiB limit");
            self.output = .init(try fiber.allocator.alloc(u8, expected));
            return .stepped;
        }
        if (self.decoder == null) {
            self.decoder = .init(try Decoder.init(fiber.allocator, compressed));
            return .stepped;
        }
        const output = self.output.?.borrow();
        switch (self.phase) {
            .inflate => {
                const decoder = self.decoder.?.borrowMut();
                if (self.index != output.len) {
                    const end = self.index + fiber.workBudget().take(output.len - self.index);
                    const read = decoder.read(output[self.index..end]) catch
                        return fiber.fail(.domain, "malformed gzip data");
                    if (read == 0) return fiber.fail(.domain, "gzip size does not match its footer");
                    self.index += read;
                    return .stepped;
                }
                var extra: [1]u8 = undefined;
                const read = decoder.read(&extra) catch return fiber.fail(.domain, "malformed gzip data");
                if (read != 0 or !decoder.consumedAllInput())
                    return fiber.fail(.domain, "gzip size does not match its footer");
                self.phase = .verify;
                self.index = 0;
                return .stepped;
            },
            .verify => {
                if (self.index != output.len) {
                    const end = self.index + fiber.workBudget().take(output.len - self.index);
                    self.crc.update(output[self.index..end]);
                    self.index = end;
                    return .stepped;
                }
                const expected_crc = std.mem.readInt(u32, compressed[compressed.len - 8 ..][0..4], .little);
                if (self.crc.final() != expected_crc)
                    return fiber.fail(.domain, "gzip checksum does not match its payload");
                self.result = .init(.init(fiber.allocator, output));
                self.phase = .materialize;
                return .stepped;
            },
            .materialize => return switch (try self.result.?.borrowMut().advance(fiber.workBudget())) {
                .pending => .stepped,
                .complete => |payload| .{ .output = payload },
            },
        }
    }
};
