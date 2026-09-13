//! Bundled filesystem implementation over the public native resource SDK.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
const staging = @import("staging.zig");
pub const Configuration = service.Configuration;
pub const Limits = service.Limits;
pub const Root = service.Root;
const roots = .{ Directory, Stage, Reservation };

const Derivation = struct {
    phase: enum { input, child, result, complete } = .input,
    fn step(self: *Derivation, comptime Child: type, comptime dependency: @TypeOf(.inherited), ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        const builder = ctx.builder();
        const progress = try builder.advance();
        if (progress != .completed) return progress;
        switch (self.phase) {
            .input => {
                try builder.input(&.{});
                self.phase = .child;
            },
            .child => {
                try builder.child(Child, dependency);
                self.phase = .result;
            },
            .result => {
                try builder.result();
                self.phase = .complete;
            },
            .complete => return .completed,
        }
        return .yielded;
    }
};
fn directoryOperations(comptime State: type, comptime dependent: bool) type {
    return struct {
        fn directory(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return state.derivation.step(Directory, if (dependent) .dependent else .inherited, ctx);
        }
        fn stage(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return state.derivation.step(Stage, if (dependent) .dependent else .inherited, ctx);
        }
        fn writer(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return state.derivation.step(Writer, if (dependent) .dependent else .inherited, ctx);
        }
        fn cursor(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return state.derivation.step(Cursor, if (dependent) .dependent else .inherited, ctx);
        }
    };
}

pub const Directory = ecl.Port(.{ .cooperative = struct {
    pub const name = "directory";
    pub const State = struct {
        preparation: support.Preparation = .{},
        handle: ?support.RootHandle = null,
        derivation: Derivation = .{},
        phase: enum { start, host_encoding, host_validating, host_opening, confined, opening, retiring, ready } = .start,
        host_index: usize = 0,
        pub fn directory(self: *State) std.Io.Dir {
            return self.handle.?.dir;
        }
        pub fn reservation(self: *State) ?*service.Ticket {
            return self.handle.?.ticket;
        }
    };
    const Ops = directoryOperations(State, false);
    pub const operations = .{
        .directory = .{ .visibility = .private, .doc = "Derive an independently owned directory.", .handler = Ops.directory, .lane = .operation, .endpoints = .{} },
        .stage = .{ .visibility = .private, .doc = "Create private directory staging.", .handler = Ops.stage, .lane = .operation, .endpoints = .{} },
        .writer = .{ .visibility = .private, .doc = "Create a streaming writer with the root's lifetime dependency.", .handler = Ops.writer, .lane = .operation, .endpoints = .{} },
        .cursor = .{ .visibility = .private, .doc = "Open directory enumeration.", .handler = Ops.cursor, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        const prep = &state.preparation;
        if (prep.failure) |*failure| return failure.step(ctx);
        switch (state.phase) {
            .start => {
                prep.owner = ctx.instance(service.Service) orelse return error.InvalidValue;
                state.phase = if ((ctx.input(&.{0}) orelse return error.InvalidValue).int() == 0) .host_encoding else .confined;
            },
            .host_encoding => {
                if ((prep.encoder.step(ctx, prep.owner.?.allocator()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        ctx.fail(.type, "expected a string path");
                        return error.Failed;
                    },
                }) == .pending) return .yielded;
                prep.path = prep.encoder.take();
                if (!std.fs.path.isAbsolute(prep.path.?)) return prep.fail(.invalid_path);
                state.phase = .host_validating;
            },
            .host_validating => {
                const path = prep.path.?;
                while (state.host_index < path.len and ctx.consume(1)) : (state.host_index += 1) if (path[state.host_index] == 0) return prep.fail(.invalid_path);
                if (state.host_index == path.len) state.phase = .host_opening;
            },
            .host_opening => {
                const dir = std.Io.Dir.cwd().openDir(service.io(), prep.path.?, .{ .iterate = true }) catch |err| return prep.fail(fs.reasonForError(err));
                state.handle = .{ .dir = dir };
                state.phase = .retiring;
            },
            .confined => {
                const progress = try prep.step(roots, ctx, .follow_final, false, .initialization, true);
                if (progress != .completed or prep.failure != null) return progress;
                state.phase = .opening;
            },
            .opening => {
                const dir = openResolvedDirectory(prep.resolved.?) catch |err| return prep.fail(fs.reasonForError(err));
                const ticket = prep.root.?.ticket;
                if (ticket) |reservation| reservation.retain();
                state.handle = .{ .dir = dir, .ticket = ticket };
                state.phase = .retiring;
            },
            .retiring => {
                if (prep.retire()) state.phase = .ready;
            },
            .ready => return .completed,
        }
        return .yielded;
    }
    pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        state.derivation = .{};
        return .completed;
    }
    pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        if (!state.preparation.retire()) return .yielded;
        if (state.handle) |*handle| handle.deinit();
        state.handle = null;
        return .completed;
    }
} });
fn openResolvedDirectory(resolved: fs.Resolved) !std.Io.Dir {
    return switch (resolved) {
        .directory => |handle| handle.dir.openDir(service.io(), ".", .{ .iterate = true }),
        .entry => |entry| entry.parent.dir.openDir(service.io(), entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => error.EntryChanged,
            else => err,
        },
    };
}

pub const Stage = ecl.Port(.{ .cooperative = struct {
    pub const name = "stage";
    pub const State = struct {
        preparation: support.Preparation = .{},
        stage: ?staging.Directory = null,
        ticket: ?*service.Ticket = null,
        derivation: Derivation = .{},
        phase: enum { preparing, creating, retiring, ready } = .preparing,
        commit_phase: enum { result, ready, committed } = .result,
        commit_admission: support.Admission = .{},
        pub fn directory(self: *State) std.Io.Dir {
            return self.stage.?.directory();
        }
        pub fn reservation(self: *State) ?*service.Ticket {
            return self.ticket;
        }
    };
    const Ops = directoryOperations(State, true);
    pub const operations = .{
        .directory = .{ .visibility = .private, .doc = "Derive a staging-dependent directory.", .handler = Ops.directory, .lane = .operation, .endpoints = .{} },
        .stage = .{ .visibility = .private, .doc = "Create dependent private staging.", .handler = Ops.stage, .lane = .operation, .endpoints = .{} },
        .writer = .{ .visibility = .private, .doc = "Create a streaming writer with the root's lifetime dependency.", .handler = Ops.writer, .lane = .operation, .endpoints = .{} },
        .cursor = .{ .visibility = .private, .doc = "Enumerate private staging.", .handler = Ops.cursor, .lane = .operation, .endpoints = .{} },
        .commit = .{ .name = "commit-directory", .doc = "Seal and publish an absent directory.", .handler = commit, .lane = .operation, .endpoints = .{} },
    };
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
                state.phase = .creating;
            },
            .creating => {
                const entry = switch (prep.resolved.?) {
                    .directory => return prep.fail(.invalid_path),
                    .entry => |entry| entry,
                };
                state.stage = staging.Directory.create(prep.owner.?.allocator(), entry.parent.dir, entry.name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return prep.fail(fs.reasonForError(err)),
                };
                state.ticket = prep.root.?.ticket;
                if (state.ticket) |ticket| ticket.retain();
                state.phase = .retiring;
            },
            .retiring => {
                if (prep.retire()) state.phase = .ready;
            },
            .ready => return .completed,
        }
        return .yielded;
    }
    fn commit(state: *State, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
        switch (state.commit_phase) {
            .result => {
                if (state.ticket) |ticket| state.commit_admission = support.Admission.acquire(state.preparation.owner.?, ticket, null) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Limit => {
                        ctx.fail(.overflow, "filesystem operation limit reached");
                        return .completed;
                    },
                };
                try ctx.builder().int(0);
                try ctx.builder().result();
                state.commit_phase = .ready;
            },
            .ready => {
                const progress = try ctx.builder().advance();
                if (progress != .completed) return progress;
                try ctx.beginCommit();
                if (state.stage.?.commit()) |reason| ctx.fail(.io, reason.message());
                state.commit_phase = .committed;
                return .completed;
            },
            .committed => return .completed,
        }
        return .yielded;
    }
    pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        state.derivation = .{};
        state.commit_admission.deinit();
        return .completed;
    }
    pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        state.commit_admission.deinit();
        if (!state.preparation.retire()) return .yielded;
        if (state.stage) |*stage| {
            if (!stage.retire()) return .yielded;
            state.stage = null;
        }
        if (state.ticket) |ticket| ticket.release();
        state.ticket = null;
        return .completed;
    }
} });

pub const Reservation = ecl.Port(.{ .cooperative = struct {
    pub const name = "reservation";
    pub const State = struct {
        preparation: support.Preparation = .{},
        handle: ?support.RootHandle = null,
        derivation: Derivation = .{},
        phase: enum { preparing, opening, retiring, ready } = .preparing,
        pub fn directory(self: *State) std.Io.Dir {
            return self.handle.?.dir;
        }
        pub fn reservation(self: *State) ?*service.Ticket {
            return self.handle.?.ticket;
        }
    };
    const Ops = directoryOperations(State, false);
    pub const operations = .{
        .directory = .{ .visibility = .private, .doc = "Derive a reserved directory.", .handler = Ops.directory, .lane = .operation, .endpoints = .{} },
        .stage = .{ .visibility = .private, .doc = "Create reserved private staging.", .handler = Ops.stage, .lane = .operation, .endpoints = .{} },
        .writer = .{ .visibility = .private, .doc = "Create a streaming writer with the root's lifetime dependency.", .handler = Ops.writer, .lane = .operation, .endpoints = .{} },
        .cursor = .{ .visibility = .private, .doc = "Enumerate beneath a reservation.", .handler = Ops.cursor, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        const prep = &state.preparation;
        if (prep.failure) |*failure| return failure.step(ctx);
        switch (state.phase) {
            .preparing => {
                const progress = try prep.step(roots, ctx, .follow_final, false, .resource, true);
                if (progress != .completed or prep.failure != null) return progress;
                state.phase = .opening;
            },
            .opening => {
                const dir = openResolvedDirectory(prep.resolved.?) catch |err| return prep.fail(fs.reasonForError(err));
                const ticket = prep.admission.tickets[0].?;
                ticket.retain();
                state.handle = .{ .dir = dir, .ticket = ticket };
                state.phase = .retiring;
            },
            .retiring => {
                if (prep.retire()) state.phase = .ready;
            },
            .ready => return .completed,
        }
        return .yielded;
    }
    pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        state.derivation = .{};
        return .completed;
    }
    pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        if (!state.preparation.retire()) return .yielded;
        if (state.handle) |*handle| handle.deinit();
        state.handle = null;
        return .completed;
    }
} });

pub const Request = @import("request.zig").Resource(roots);
pub const Writer = @import("writer.zig").Resource(roots);
pub const Lock = @import("lock.zig").Resource(roots);
pub const Reader = @import("reader.zig").Resource(roots);
pub const PairRequest = @import("pair_request.zig").Resource(roots);
pub const Listing = @import("cursor.zig").Resource(roots, true);
pub const Cursor = @import("cursor.zig").Resource(roots, false);
fn isRoot(call: *ecl.Call("value -- bool")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(@intFromBool(call.input(0).kind() == .symbol or call.inputIsResource(Directory, 0) or call.inputIsResource(Stage, 0) or call.inputIsResource(Reservation, 0)))});
}
pub const Module = ecl.module(.{
    .linkage = .static,
    .name = "fs.core",
    .doc = "Confined cooperative filesystem resources.",
    .instance = service.Service,
    .ports = .{ Directory, Stage, Reservation, Cursor, Request, Reader, Lock, Writer, PairRequest, Listing },
    .words = .{
        ecl.word("root-value", "Recognize configured names and same-instance directory resources, including closed resources.", isRoot),
        ecl.word("string-value", "Recognize string values before marshalling.", @import("validation.zig").isString),
        ecl.word("byte-error-index", "Return the first invalid byte index or the list length.", @import("validation.zig").byteErrorIndex),
        ecl.overload("derive-directory", "Open a directory beneath a resource root.", .{ .{ Directory, .directory }, .{ Stage, .directory }, .{ Reservation, .directory } }),
        ecl.overload("derive-stage", "Open a private directory beneath a resource root.", .{ .{ Directory, .stage }, .{ Stage, .stage }, .{ Reservation, .stage } }),
        ecl.overload("derive-writer", "Create a streaming writer beneath a resource root.", .{ .{ Directory, .writer }, .{ Stage, .writer }, .{ Reservation, .writer } }),
        ecl.overload("derive-cursor", "Open enumeration beneath a resource root.", .{ .{ Directory, .cursor }, .{ Stage, .cursor }, .{ Reservation, .cursor } }),
        ecl.factory("request", "Own one admitted filesystem request.", Request),
        ecl.factory("lock", "Acquire an independent advisory lock.", Lock),
        ecl.factory("writer", "Create a private streaming writer.", Writer),
        ecl.factory("pair-request", "Own an admitted copy or rename.", PairRequest),
        ecl.factory("listing", "Collect bounded directory batches under one admission.", Listing),
        ecl.factory("reader", "Read a regular file through bounded chunks.", Reader),
        ecl.factory("directory", "Open an owned directory.", Directory),
        ecl.factory("stage", "Open private directory staging.", Stage),
        ecl.factory("reservation", "Reserve filesystem admission and root lifetime.", Reservation),
        ecl.factory("cursor", "Open incremental enumeration.", Cursor),
    },
});
pub fn descriptor() *const ecl.abi.Descriptor {
    return Module.descriptor();
}
