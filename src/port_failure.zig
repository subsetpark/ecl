//! Terminal allocation failure and bounded domain error data for port transports.
/// Allocation exhaustion remains a runtime failure across asynchronous native
/// execution and transport. It cannot be confused with a domain error symbol.
pub fn Failure(comptime Kind: type) type {
    return union(enum) {
        const Self = @This();
        out_of_memory,
        report: struct { kind: Kind, message: [4096]u8, len: u32 },

        pub fn init(kind: Kind, message: []const u8) Self {
            var length = @min(message.len, 4096);
            if (length < message.len) while (length != 0 and message[length] & 0xc0 == 0x80) {
                length -= 1;
            };
            // SAFETY: only the initialized prefix is exposed through len.
            var result: Self = .{ .report = .{ .kind = kind, .message = undefined, .len = @intCast(length) } };
            @memcpy(result.report.message[0..length], message[0..length]);
            return result;
        }
    };
}
