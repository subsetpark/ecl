//! Reserve all portable failure outcomes before a filesystem commit syscall.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
pub const Failures = struct {
    const reasons = std.enums.values(fs.Reason);
    choices: [reasons.len]?*const ecl.PreparedFailure = @splat(null),
    index: usize = 0,
    phase: enum { key, reason, dictionary, reserve, token } = .key,
    pub fn step(self: *Failures, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
        const builder = ctx.errorData();
        while (self.index != reasons.len and ctx.consume(1)) {
            const progress = try builder.advance();
            if (progress != .completed) return progress;
            const reason = reasons[self.index];
            switch (self.phase) {
                .key => {
                    try builder.symbol("reason");
                    self.phase = .reason;
                },
                .reason => {
                    try builder.symbol(reason.symbol());
                    self.phase = .dictionary;
                },
                .dictionary => {
                    try builder.dictionary(1);
                    self.phase = .reserve;
                },
                .reserve => {
                    try ctx.prepareFailure(switch (reason) {
                        .invalid_path, .unknown_root => .domain,
                        .limit => .overflow,
                        else => .io,
                    }, reason.message());
                    self.phase = .token;
                },
                .token => {
                    self.choices[self.index] = try ctx.preparedFailure();
                    self.index += 1;
                    self.phase = .key;
                },
            }
        }
        return if (self.index == reasons.len) .completed else .yielded;
    }
    pub fn report(self: *const Failures, ctx: *ecl.Finalizer, reason: fs.Reason) ecl.ControllerError!void {
        try ctx.failPrepared(self.choices[@intFromEnum(reason)].?);
    }
};
