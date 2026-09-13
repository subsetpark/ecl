//! Cross-root copy and same-root rename own one transactional admission.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
const publication = @import("publication.zig");
const Mode = enum { copy, rename };
pub fn Resource(comptime roots: anytype) type {
    return ecl.Port(.{
        .cooperative = struct {
            pub const name = "pair-request";
            pub const State = struct {
                paths: [2]support.Preparation = .{ .{}, .{ .encoder = .init(4, .text), .lookup = .{ .position = 3 } } },
                mode: ?Mode = null,
                admission: support.Admission = .{},
                initialization: enum { paths, roots, admission, resolving, ready } = .paths,
                index: usize = 0,
                operation: enum { opening, copying, failures, result, commit, complete } = .opening,
                file: ?std.Io.File = null,
                staged: ?fs.StagedFile = null,
                buffer: ?[]u8 = null,
                size: u64 = 0,
                offset: u64 = 0,
                failures: publication.Failures = .{},
            };
            pub const operations = .{
                .execute = .{ .name = "execute-pair", .doc = "Atomically publish a copy or rename without replacement.", .handler = execute, .lane = .operation, .endpoints = .{} },
            };
            pub fn init() State {
                return .{};
            }
            pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
                if (state.mode == null) {
                    const selected = (ctx.input(&.{0}) orelse return error.InvalidValue).symbol() orelse return error.InvalidValue;
                    state.mode = std.meta.stringToEnum(Mode, selected) orelse return error.InvalidValue;
                }
                for (&state.paths) |*path| if (path.failure) |*failure| return failure.step(ctx);
                switch (state.initialization) {
                    .paths, .roots, .resolving => {
                        const current = &state.paths[state.index];
                        const mode: fs.ResolveMode = if (state.mode.? == .copy and state.index == 0) .follow_final else .no_follow_final;
                        const progress = try current.step(roots, ctx, mode, state.mode.? == .rename or state.index == 1, .resource, false);
                        if (current.failure != null) return progress;
                        const finished = switch (state.initialization) {
                            .paths => current.phase == .lookup,
                            .roots => current.phase == .admission,
                            .resolving => progress == .completed,
                            else => unreachable,
                        };
                        if (finished) {
                            state.index += 1;
                            if (state.index == 2) {
                                state.index = 0;
                                state.initialization = switch (state.initialization) {
                                    .paths => .roots,
                                    .roots => .admission,
                                    .resolving => .ready,
                                    else => unreachable,
                                };
                            }
                        }
                    },
                    .admission => {
                        state.admission = support.Admission.acquire(state.paths[0].owner.?, state.paths[0].root.?.ticket, state.paths[1].root.?.ticket) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.Limit => return state.paths[0].fail(.limit),
                        };
                        state.initialization = .resolving;
                    },
                    .ready => return .completed,
                }
                return .yielded;
            }
            fn execute(state: *State, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
                const prep = &state.paths[0];
                if (prep.failure) |*failure| return failure.step(ctx);
                const source = switch (prep.resolved.?) {
                    .directory => return prep.fail(if (state.mode.? == .copy) .not_regular else .invalid_path),
                    .entry => |entry| entry,
                };
                const destination = switch (state.paths[1].resolved.?) {
                    .directory => return prep.fail(.invalid_path),
                    .entry => |entry| entry,
                };
                switch (state.operation) {
                    .opening => {
                        if (state.mode.? == .rename) {
                            state.operation = .failures;
                            return .yielded;
                        }
                        const existing = destination.parent.dir.statFile(service.io(), destination.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                            error.FileNotFound => null,
                            else => return prep.fail(fs.reasonForError(err)),
                        };
                        if (existing != null) return prep.fail(.already_exists);
                        state.file = switch (fs.openRegularForRead(service.io(), source.parent.dir, source.name)) {
                            .file => |file| file,
                            .failed => |reason| return prep.fail(reason),
                        };
                        const info = switch (fs.regularFileInfo(service.io(), state.file.?, prep.owner.?.limits.max_transfer_bytes)) {
                            .regular => |info| info,
                            .failed => |reason| return prep.fail(reason),
                        };
                        state.size = info.size;
                        state.buffer = try prep.owner.?.allocator().alloc(u8, fs.transfer_quantum);
                        state.staged = switch (fs.StagedFile.create(service.io(), destination.parent.dir, info.permissions)) {
                            .staged => |staged| staged,
                            .failed => |reason| return prep.fail(reason),
                        };
                        state.operation = .copying;
                    },
                    .copying => {
                        if (state.offset == state.size) {
                            // SAFETY: the size probe observes only the returned count.
                            var probe: [1]u8 = undefined;
                            const extra = state.file.?.readPositionalAll(service.io(), &probe, state.size) catch |err| return prep.fail(fs.reasonForError(err));
                            if (extra != 0) return prep.fail(.changed);
                            state.operation = .failures;
                            return .yielded;
                        }
                        const count: usize = @intCast(@min(fs.transfer_quantum, state.size - state.offset));
                        const chunk = state.buffer.?[0..count];
                        const amount = state.file.?.readPositionalAll(service.io(), chunk, state.offset) catch |err| return prep.fail(fs.reasonForError(err));
                        if (amount != count) return prep.fail(.changed);
                        state.staged.?.file.?.writePositionalAll(service.io(), chunk, state.offset) catch |err| return prep.fail(fs.reasonForError(err));
                        state.offset += count;
                    },
                    .failures => {
                        const progress = try state.failures.step(ctx);
                        if (progress != .completed) return progress;
                        state.operation = .result;
                    },
                    .result => {
                        try ctx.builder().int(0);
                        try ctx.builder().result();
                        state.operation = .commit;
                    },
                    .commit => {
                        const progress = try ctx.builder().advance();
                        if (progress != .completed) return progress;
                        try ctx.beginCommit();
                        if (state.mode.? == .copy) {
                            if (state.staged.?.commitNoReplace(destination.name)) |reason| try state.failures.report(ctx, reason);
                        } else fs.renameNoReplace(service.io(), source.parent.dir, source.name, destination.parent.dir, destination.name) catch |err| try state.failures.report(ctx, fs.reasonForError(err));
                        state.operation = .complete;
                        return .completed;
                    },
                    .complete => return .completed,
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
                if (state.staged) |*staged| {
                    staged.dispose();
                    state.staged = null;
                    return .yielded;
                }
                if (state.buffer) |buffer| state.paths[0].owner.?.allocator().free(buffer);
                state.buffer = null;
                for (&state.paths) |*path| if (!path.retire()) return .yielded;
                state.admission.deinit();
                return .completed;
            }
        },
    });
}
