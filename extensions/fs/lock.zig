//! Cancellable advisory locking with cooperative timer parking.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
pub fn Resource(comptime roots: anytype) type {
    return ecl.Port(.{ .cooperative = struct {
        pub const name = "advisory-lock";
        pub const State = struct {
            preparation: support.Preparation = .{},
            file: ?std.Io.File = null,
            phase: enum { preparing, opening, waiting, retiring, ready } = .preparing,
        };
        pub const operations = .{};
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const prep = &state.preparation;
            if (prep.failure) |*failure| return failure.step(ctx);
            switch (state.phase) {
                .preparing => {
                    const progress = try prep.step(roots, ctx, .no_follow_final, true, .initialization, true);
                    if (progress != .completed or prep.failure != null) return progress;
                    state.phase = .opening;
                },
                .opening => {
                    const entry = switch (prep.resolved.?) {
                        .directory => return prep.fail(.invalid_path),
                        .entry => |entry| entry,
                    };
                    state.file = switch (fs.openLockFile(service.io(), entry.parent.dir, entry.name)) {
                        .file => |file| file,
                        .failed => |reason| return prep.fail(reason),
                    };
                    state.phase = .waiting;
                },
                .waiting => {
                    if (!(state.file.?.tryLock(service.io(), .exclusive) catch |err| return prep.fail(fs.reasonForError(err)))) {
                        if (!ctx.park(10)) return error.Cancelled;
                        return .parked;
                    }
                    state.phase = .retiring;
                },
                .retiring => {
                    if (prep.retire()) state.phase = .ready;
                },
                .ready => return .completed,
            }
            return .yielded;
        }
        pub fn retireOperation(_: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            return .completed;
        }
        pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            if (state.file) |file| {
                file.close(service.io());
                state.file = null;
                return .yielded;
            }
            return if (state.preparation.retire()) .completed else .yielded;
        }
    } });
}
