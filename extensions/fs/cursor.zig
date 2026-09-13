//! Independently owned, incremental directory enumeration.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
const support = @import("support.zig");
pub fn Resource(comptime roots: anytype, comptime listing: bool) type {
    return ecl.Port(.{
        .cooperative = struct {
            pub const name = if (listing) "listing" else "enumeration";
            pub const State = struct {
                preparation: support.Preparation = .{},
                cursor: ?struct { dir: std.Io.Dir, iterator: std.Io.Dir.Iterator } = null,
                initialization: enum { preparing, opening, retiring, ready } = .preparing,
                operation: enum { reading, name_key, name, name_list, kind_key, kind, dictionary, batch, batch_result, result, complete } = .reading,
                // SAFETY: next copies the initialized name prefix before materialization.
                bytes: [std.Io.Dir.max_name_bytes]u8 = undefined,
                length: usize = 0,
                offset: usize = 0,
                scalars: u32 = 0,
                kind: fs.EntryKind = .other,
                failure: ?support.Failure = null,
                observed: usize = 0,
                name_bytes: usize = 0,
                batch_count: u32 = 0,
                batch_bytes: usize = 0,
            };
            pub const operations = .{
                .next = .{ .name = if (listing) "list-batch" else "next-entry", .doc = "Read one independently owned entry or an empty dictionary.", .handler = next, .lane = .operation, .endpoints = .{} },
            };
            pub fn init() State {
                return .{};
            }
            pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
                const prep = &state.preparation;
                if (prep.failure) |*failure| return failure.step(ctx);
                switch (state.initialization) {
                    .preparing => {
                        const progress = try prep.step(roots, ctx, .follow_final, false, if (listing) .resource else .initialization, true);
                        if (progress != .completed or prep.failure != null) return progress;
                        state.initialization = .opening;
                    },
                    .opening => {
                        const dir = (switch (prep.resolved.?) {
                            .directory => |handle| handle.dir.openDir(service.io(), ".", .{ .iterate = true }),
                            .entry => |entry| entry.parent.dir.openDir(service.io(), entry.name, .{ .iterate = true, .follow_symlinks = false }),
                        }) catch |err| return prep.fail(if (err == error.SymLinkLoop) .changed else fs.reasonForError(err));
                        state.cursor = .{ .dir = dir, .iterator = dir.iterate() };
                        state.initialization = if (listing) .ready else .retiring;
                    },
                    .retiring => {
                        if (prep.retire()) state.initialization = .ready;
                    },
                    .ready => return .completed,
                }
                return .yielded;
            }
            fn fail(state: *State, reason: fs.Reason) ecl.CooperativeProgress {
                state.failure = .{ .reason = reason };
                return .yielded;
            }
            fn next(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
                while (ctx.consume(1)) {
                    const phase = state.operation;
                    const progress = try nextStep(state, ctx);
                    if (progress != .yielded or phase == state.operation) return progress;
                }
                return .yielded;
            }
            fn nextStep(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
                if (state.failure) |*failure| return failure.step(ctx);
                const builder = ctx.builder();
                if (state.operation != .reading) {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                }
                switch (state.operation) {
                    .reading => {
                        const cursor = &state.cursor.?;
                        const entry = (cursor.iterator.next(service.io()) catch |err| return fail(state, fs.reasonForError(err))) orelse {
                            if (listing) try builder.list(state.batch_count) else try builder.dictionary(0);
                            state.operation = .result;
                            return .yielded;
                        };
                        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) return .yielded;
                        if (entry.name.len > state.bytes.len) return fail(state, .limit);
                        if (!std.unicode.utf8ValidateSlice(entry.name)) return fail(state, .invalid_utf8);
                        if (listing) {
                            const limits = state.preparation.owner.?.limits;
                            if (state.observed == limits.max_directory_entries) return fail(state, .limit);
                            state.name_bytes = std.math.add(usize, state.name_bytes, entry.name.len) catch return fail(state, .limit);
                            if (state.name_bytes > limits.max_directory_name_bytes) return fail(state, .limit);
                            state.observed += 1;
                            state.batch_bytes += entry.name.len;
                        }
                        @memcpy(state.bytes[0..entry.name.len], entry.name);
                        state.length = entry.name.len;
                        state.kind = if (entry.kind == .unknown) blk: {
                            const info = cursor.dir.statFile(service.io(), entry.name, .{ .follow_symlinks = false }) catch |err| return fail(state, fs.reasonForError(err));
                            break :blk fs.EntryKind.fromHost(info.kind);
                        } else fs.EntryKind.fromHost(entry.kind);
                        state.operation = .name_key;
                    },
                    .name_key => {
                        try builder.symbol("name");
                        state.operation = .name;
                    },
                    .name => {
                        while (state.offset < state.length and ctx.consume(1)) {
                            const width = std.unicode.utf8ByteSequenceLength(state.bytes[state.offset]) catch unreachable;
                            const scalar = std.unicode.utf8Decode(state.bytes[state.offset..][0..width]) catch unreachable;
                            try builder.char(scalar);
                            state.offset += width;
                            state.scalars += 1;
                        }
                        if (state.offset == state.length) state.operation = .name_list;
                    },
                    .name_list => {
                        try builder.list(state.scalars);
                        state.operation = .kind_key;
                    },
                    .kind_key => {
                        try builder.symbol("kind");
                        state.operation = .kind;
                    },
                    .kind => {
                        try builder.symbol(state.kind.symbol());
                        state.operation = .dictionary;
                    },
                    .dictionary => {
                        try builder.dictionary(2);
                        state.operation = if (listing) .batch else .result;
                    },
                    .batch => {
                        state.batch_count += 1;
                        state.offset = 0;
                        state.scalars = 0;
                        state.operation = if (state.batch_count == fs.listing_batch_entries or state.batch_bytes >= fs.listing_batch_bytes) .batch_result else .reading;
                    },
                    .batch_result => {
                        try builder.list(state.batch_count);
                        state.operation = .result;
                    },
                    .result => {
                        try builder.result();
                        state.operation = .complete;
                    },
                    .complete => return .completed,
                }
                return .yielded;
            }
            pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
                state.operation = .reading;
                state.length = 0;
                state.offset = 0;
                state.scalars = 0;
                state.failure = null;
                state.batch_count = 0;
                state.batch_bytes = 0;
                return .completed;
            }
            pub fn retire(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
                if (state.cursor) |cursor| {
                    cursor.dir.close(service.io());
                    state.cursor = null;
                    return .yielded;
                }
                return if (state.preparation.retire()) .completed else .yielded;
            }
        },
    });
}
