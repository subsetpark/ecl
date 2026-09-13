//! Private streaming writes publish only through the common sealing protocol.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
const encoding = @import("encoding.zig");
const publication = @import("publication.zig");
const Mode = enum { create, replace, publish };
pub fn Resource(comptime roots: anytype) type {
    return ecl.Port(.{ .cooperative = struct {
        pub const name = "writer";
        pub const State = struct {
            preparation: support.Preparation = .{},
            mode: ?Mode = null,
            staged: ?fs.StagedFile = null,
            written: u64 = 0,
            initialization: enum { preparing, creating, ready } = .preparing,
            admission: union(enum) { open, failed: fs.Reason, sealed } = .open,
            invocation: union(enum) {
                idle,
                append: struct {
                    encoder: encoding.Encoder = .init(0, .bytes),
                    bytes: ?[]u8 = null,
                    phase: enum { encoding, writing, result, complete } = .encoding,
                },
                commit: struct {
                    failures: publication.Failures = .{},
                    phase: enum { preparing, result, ready, complete } = .preparing,
                },
            } = .idle,
        };
        pub const operations = .{
            .append = .{ .name = "write-chunk", .doc = "Append a bounded byte chunk to private storage.", .handler = append, .lane = .operation, .endpoints = .{} },
            .commit = .{ .name = "commit-file", .doc = "Seal input and atomically publish a complete file.", .handler = commit, .lane = .operation, .endpoints = .{} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const prep = &state.preparation;
            if (prep.failure) |*failure| return failure.step(ctx);
            if (state.mode == null) {
                const selected = (ctx.input(&.{0}) orelse return error.InvalidValue).symbol() orelse return error.InvalidValue;
                state.mode = std.meta.stringToEnum(Mode, selected) orelse return error.InvalidValue;
                if (ctx.input(&.{3})) |size| if (size.int()) |amount| {
                    if (amount < 0) return error.InvalidValue;
                    prep.transfer_bytes = @intCast(amount);
                };
            }
            switch (state.initialization) {
                .preparing => {
                    const progress = try prep.step(roots, ctx, .no_follow_final, true, .resource, true);
                    if (progress != .completed or prep.failure != null) return progress;
                    state.initialization = .creating;
                },
                .creating => {
                    const entry = switch (prep.resolved.?) {
                        .directory => return prep.fail(.invalid_path),
                        .entry => |entry| entry,
                    };
                    const existing = entry.parent.dir.statFile(service.io(), entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                        error.FileNotFound => null,
                        else => return prep.fail(fs.reasonForError(err)),
                    };
                    const permissions: std.Io.File.Permissions = switch (state.mode.?) {
                        .create => if (existing != null) return prep.fail(.already_exists) else .default_file,
                        .replace, .publish => permissions: {
                            const info = existing orelse {
                                if (state.mode.? == .replace) return prep.fail(.not_found);
                                break :permissions .default_file;
                            };
                            if (info.kind != .file) return prep.fail(.not_regular);
                            break :permissions info.permissions;
                        },
                    };
                    state.staged = switch (fs.StagedFile.create(service.io(), entry.parent.dir, permissions)) {
                        .staged => |staged| staged,
                        .failed => |reason| return prep.fail(reason),
                    };
                    state.initialization = .ready;
                },
                .ready => return .completed,
            }
            return .yielded;
        }
        fn fail(state: *State, reason: fs.Reason) ecl.CooperativeProgress {
            state.admission = .{ .failed = reason };
            return state.preparation.fail(reason);
        }
        fn append(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const prep = &state.preparation;
            if (prep.failure) |*failure| return failure.step(ctx);
            if (state.admission != .open) return error.InvalidValue;
            if (state.invocation == .idle) {
                state.invocation = .{ .append = .{} };
                state.invocation.append.encoder.byte_limit = @intCast(@min(fs.transfer_quantum, (if (prep.transfer_bytes != null) prep.owner.?.limits.max_transfer_bytes else prep.owner.?.limits.max_stream_transfer_bytes) - state.written));
            }
            const current = &state.invocation.append;
            switch (current.phase) {
                .encoding => {
                    if ((current.encoder.step(ctx, prep.owner.?.allocator()) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Limit => return fail(state, .limit),
                        else => {
                            state.admission = .{ .failed = .io };
                            ctx.fail(.type, "byte list members must be integers from 0 through 255");
                            return error.Failed;
                        },
                    }) == .pending) return .yielded;
                    current.bytes = current.encoder.take();
                    const length = current.bytes.?.len;
                    if (length > fs.transfer_quantum or length > (if (prep.transfer_bytes != null) prep.owner.?.limits.max_transfer_bytes else prep.owner.?.limits.max_stream_transfer_bytes) - state.written) return fail(state, .limit);
                    current.phase = .writing;
                },
                .writing => {
                    state.staged.?.file.?.writePositionalAll(service.io(), current.bytes.?, state.written) catch |err| return fail(state, fs.reasonForError(err));
                    state.written += current.bytes.?.len;
                    try ctx.builder().int(0);
                    try ctx.builder().result();
                    current.phase = .result;
                },
                .result => {
                    const progress = try ctx.builder().advance();
                    if (progress != .completed) return progress;
                    current.phase = .complete;
                    return .completed;
                },
                .complete => return .completed,
            }
            return .yielded;
        }
        fn commit(state: *State, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
            const prep = &state.preparation;
            if (prep.failure) |*failure| return failure.step(ctx);
            if (state.admission == .failed) {
                _ = prep.fail(state.admission.failed);
                return .yielded;
            }
            if (state.invocation == .idle) state.invocation = .{ .commit = .{} };
            const current = &state.invocation.commit;
            switch (current.phase) {
                .preparing => {
                    const progress = try current.failures.step(ctx);
                    if (progress != .completed) return progress;
                    current.phase = .result;
                },
                .result => {
                    try ctx.builder().int(0);
                    try ctx.builder().result();
                    current.phase = .ready;
                },
                .ready => {
                    const progress = try ctx.builder().advance();
                    if (progress != .completed) return progress;
                    try ctx.beginCommit();
                    state.admission = .sealed;
                    const entry = prep.resolved.?.entry;
                    const failure = switch (state.mode.?) {
                        .create => state.staged.?.commitNoReplace(entry.name),
                        .replace => state.staged.?.commitExchange(entry.name),
                        .publish => state.staged.?.commitReplace(entry.name),
                    };
                    if (failure) |reason| try current.failures.report(ctx, reason);
                    current.phase = .complete;
                    return .completed;
                },
                .complete => return .completed,
            }
            return .yielded;
        }
        fn retireInvocation(state: *State) void {
            switch (state.invocation) {
                .idle, .commit => {},
                .append => |*current| {
                    if (current.phase != .complete and state.admission == .open) state.admission = .{ .failed = .io };
                    if (current.bytes) |bytes| state.preparation.owner.?.allocator().free(bytes);
                    current.encoder.deinit(state.preparation.owner.?.allocator());
                },
            }
            state.invocation = .idle;
        }
        pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            retireInvocation(state);
            if (state.preparation.failure) |*failure| failure.* = .{ .reason = failure.reason, .message = failure.message };
            return .completed;
        }
        pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            retireInvocation(state);
            if (state.staged) |*staged| {
                staged.dispose();
                state.staged = null;
                return .yielded;
            }
            return if (state.preparation.retire()) .completed else .yielded;
        }
    } });
}
