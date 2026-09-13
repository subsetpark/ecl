//! One admitted filesystem request retains its selected root through cleanup.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
const Operation = enum {
    stat,
    lstat,
    exists,
    mkdir,
    mkdirs,
    remove_file,
    remove_dir,
    remove_tree,
    fn follows(self: Operation) bool {
        return self == .stat or self == .mkdirs;
    }
    fn requiresEntry(self: Operation) bool {
        return switch (self) {
            .stat, .lstat, .exists, .mkdirs => false,
            else => true,
        };
    }
};
pub fn Resource(comptime roots: anytype) type {
    return ecl.Port(.{ .cooperative = struct {
        pub const name = "request";
        pub const State = struct {
            preparation: support.Preparation = .{},
            selected: ?Operation = null,
            phase: enum { acting, removing, metadata_key, metadata_kind, metadata_size_key, metadata_size, metadata_dictionary, result, complete, exhausted } = .acting,
            metadata: struct { kind: fs.EntryKind = .other, size: u64 = 0 } = .{},
            tree: ?fs.TreeRemoval = null,
        };
        pub const operations = .{
            .execute = .{ .name = "execute-request", .doc = "Execute one admitted filesystem request.", .handler = execute, .lane = .operation, .endpoints = .{} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            if (state.selected == null) {
                const selected_name = (ctx.input(&.{0}) orelse return error.InvalidValue).symbol() orelse return error.InvalidValue;
                state.selected = std.meta.stringToEnum(Operation, selected_name) orelse return error.InvalidValue;
                state.preparation.create_parents = state.selected.? == .mkdirs;
            }
            const operation = state.selected.?;
            return state.preparation.step(roots, ctx, if (operation.follows()) .follow_final else .no_follow_final, operation.requiresEntry(), .resource, true);
        }
        fn complete(state: *State, ctx: *ecl.Cooperative, number: i64) ecl.ControllerError!ecl.CooperativeProgress {
            try ctx.builder().int(number);
            state.phase = .result;
            return .yielded;
        }
        fn execute(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const prep = &state.preparation;
            if (prep.failure) |*failure| return failure.step(ctx);
            const builder = ctx.builder();
            switch (state.phase) {
                .acting => switch (state.selected.?) {
                    .stat, .lstat => {
                        const info = (switch (prep.resolved.?) {
                            .directory => |handle| handle.dir.stat(service.io()),
                            .entry => |entry| entry.parent.dir.statFile(service.io(), entry.name, .{ .follow_symlinks = false }),
                        }) catch |err| return prep.fail(fs.reasonForError(err));
                        const kind = fs.EntryKind.fromHost(info.kind);
                        if (state.selected.? == .stat and kind == .symlink) return prep.fail(.changed);
                        state.metadata = .{ .kind = kind, .size = info.size };
                        state.phase = .metadata_key;
                    },
                    .exists => {
                        const present: i64 = switch (prep.resolved.?) {
                            .directory => 1,
                            .entry => |entry| present: {
                                _ = entry.parent.dir.statFile(service.io(), entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                                    error.FileNotFound => break :present 0,
                                    else => return prep.fail(fs.reasonForError(err)),
                                };
                                break :present 1;
                            },
                        };
                        return complete(state, ctx, present);
                    },
                    .mkdir => {
                        const entry = switch (prep.resolved.?) {
                            .directory => return prep.fail(.invalid_path),
                            .entry => |entry| entry,
                        };
                        entry.parent.dir.createDir(service.io(), entry.name, .default_dir) catch |err| return prep.fail(fs.reasonForError(err));
                        return complete(state, ctx, 0);
                    },
                    .mkdirs => {
                        switch (prep.resolved.?) {
                            .directory => {},
                            .entry => |entry| entry.parent.dir.createDir(service.io(), entry.name, .default_dir) catch |err| switch (err) {
                                error.PathAlreadyExists => {
                                    const dir = entry.parent.dir.openDir(service.io(), entry.name, .{ .follow_symlinks = false }) catch |open_err| return prep.fail(fs.reasonForError(open_err));
                                    dir.close(service.io());
                                },
                                else => return prep.fail(fs.reasonForError(err)),
                            },
                        }
                        return complete(state, ctx, 0);
                    },
                    .remove_file, .remove_dir => {
                        const entry = switch (prep.resolved.?) {
                            .directory => return prep.fail(.invalid_path),
                            .entry => |entry| entry,
                        };
                        const info = entry.parent.dir.statFile(service.io(), entry.name, .{ .follow_symlinks = false }) catch |err| return prep.fail(fs.reasonForError(err));
                        if (state.selected.? == .remove_file) {
                            if (info.kind == .directory) return prep.fail(.is_directory);
                            entry.parent.dir.deleteFile(service.io(), entry.name) catch |err| return prep.fail(fs.reasonForError(err));
                        } else {
                            if (info.kind != .directory) return prep.fail(.not_directory);
                            entry.parent.dir.deleteDir(service.io(), entry.name) catch |err| return prep.fail(fs.reasonForError(err));
                        }
                        return complete(state, ctx, 0);
                    },
                    .remove_tree => {
                        const entry = switch (prep.resolved.?) {
                            .directory => return prep.fail(.invalid_path),
                            .entry => |entry| entry,
                        };
                        const dir = entry.parent.dir.openDir(service.io(), entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return prep.fail(fs.reasonForError(err));
                        state.tree = .init(service.io(), dir);
                        state.phase = .removing;
                    },
                },
                .removing => switch (state.tree.?.step()) {
                    .pending => return .yielded,
                    .failed => |reason| return prep.fail(reason),
                    .complete => {
                        const entry = prep.resolved.?.entry;
                        entry.parent.dir.deleteDir(service.io(), entry.name) catch |err| switch (err) {
                            error.DirNotEmpty => {
                                state.tree.?.restart();
                                return .yielded;
                            },
                            else => return prep.fail(fs.reasonForError(err)),
                        };
                        state.tree.?.deinit();
                        state.tree = null;
                        return complete(state, ctx, 0);
                    },
                },
                .metadata_key => {
                    try builder.symbol("kind");
                    state.phase = .metadata_kind;
                },
                .metadata_kind => {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                    try builder.symbol(state.metadata.kind.symbol());
                    state.phase = if (state.metadata.kind == .file) .metadata_size_key else .metadata_dictionary;
                },
                .metadata_size_key => {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                    try builder.symbol("size");
                    state.phase = .metadata_size;
                },
                .metadata_size => {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                    try builder.int(std.math.cast(i64, state.metadata.size) orelse std.math.maxInt(i64));
                    state.phase = .metadata_dictionary;
                },
                .metadata_dictionary => {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                    try builder.dictionary(if (state.metadata.kind == .file) 2 else 1);
                    state.phase = .result;
                },
                .result => {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                    try builder.result();
                    state.phase = .complete;
                },
                .complete => return .completed,
                .exhausted => {
                    ctx.fail(.domain, "filesystem request has already completed");
                    return .completed;
                },
            }
            return .yielded;
        }
        pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            state.phase = .exhausted;
            return .completed;
        }
        pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            if (state.tree) |*tree| {
                tree.deinit();
                state.tree = null;
                return .yielded;
            }
            return if (state.preparation.retire()) .completed else .yielded;
        }
    } });
}
