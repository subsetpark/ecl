//! Bounded file reads retain one admission and input root lease for the stream.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
pub fn Resource(comptime roots: anytype) type {
    return ecl.Port(.{
        .cooperative = struct {
            pub const name = "reader";
            pub const State = struct {
                preparation: support.Preparation = .{},
                file: ?std.Io.File = null,
                buffer: ?[]u8 = null,
                size: u64 = 0,
                offset: u64 = 0,
                initialization: enum { preparing, opening, inspecting, allocating, ready } = .preparing,
                operation: enum { reading, building, complete } = .reading,
            };
            pub const operations = .{
                .read = .{ .name = "read-chunk", .doc = "Read at most 65536 bytes, checking the captured file size.", .handler = read, .lane = .operation, .endpoints = .{} },
            };
            pub fn init() State {
                return .{};
            }
            pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
                const prep = &state.preparation;
                if (prep.failure) |*failure| return failure.step(ctx);
                switch (state.initialization) {
                    .preparing => {
                        const progress = try prep.step(roots, ctx, .follow_final, false, .resource, true);
                        if (progress != .completed or prep.failure != null) return progress;
                        state.initialization = .opening;
                    },
                    .opening => {
                        const entry = switch (prep.resolved.?) {
                            .directory => return prep.fail(.is_directory),
                            .entry => |entry| entry,
                        };
                        state.file = switch (fs.openRegularForRead(service.io(), entry.parent.dir, entry.name)) {
                            .file => |file| file,
                            .failed => |reason| return prep.fail(reason),
                        };
                        state.initialization = .inspecting;
                    },
                    .inspecting => {
                        state.size = switch (fs.regularFileInfo(service.io(), state.file.?, prep.owner.?.limits.max_transfer_bytes)) {
                            .regular => |info| info.size,
                            .failed => |reason| return prep.fail(reason),
                        };
                        state.initialization = .allocating;
                    },
                    .allocating => {
                        state.buffer = try prep.owner.?.allocator().alloc(u8, @intCast(@min(state.size, fs.transfer_quantum)));
                        state.initialization = .ready;
                    },
                    .ready => return .completed,
                }
                return .yielded;
            }
            fn read(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
                const prep = &state.preparation;
                if (prep.failure) |*failure| return failure.step(ctx);
                const builder = ctx.builder();
                switch (state.operation) {
                    .reading => {
                        if (state.offset == state.size) {
                            // SAFETY: readPositionalAll initializes only the reported
                            // prefix; only its count is observed for the growth probe.
                            var probe: [1]u8 = undefined;
                            const extra = state.file.?.readPositionalAll(service.io(), &probe, state.size) catch |err| return prep.fail(fs.reasonForError(err));
                            if (extra != 0) return prep.fail(.changed);
                            try builder.byteList("");
                        } else {
                            const count: usize = @intCast(@min(state.size - state.offset, fs.transfer_quantum));
                            const chunk = state.buffer.?[0..count];
                            const amount = state.file.?.readPositionalAll(service.io(), chunk, state.offset) catch |err| return prep.fail(fs.reasonForError(err));
                            if (amount != count) return prep.fail(.changed);
                            state.offset += count;
                            try builder.byteList(chunk);
                        }
                        state.operation = .building;
                    },
                    .building => {
                        const progress = try builder.advance();
                        if (progress != .completed) return progress;
                        try builder.result();
                        state.operation = .complete;
                    },
                    .complete => return .completed,
                }
                return .yielded;
            }
            pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
                state.operation = .reading;
                return .completed;
            }
            pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
                if (state.file) |file| {
                    file.close(service.io());
                    state.file = null;
                    return .yielded;
                }
                if (state.buffer) |buffer| state.preparation.owner.?.allocator().free(buffer);
                state.buffer = null;
                return if (state.preparation.retire()) .completed else .yielded;
            }
        },
    });
}
