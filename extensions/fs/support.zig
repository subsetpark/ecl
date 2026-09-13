//! Native descriptor and admission ownership shared by filesystem resource kinds.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
const service = @import("service.zig");
pub const Error = error{ OutOfMemory, InvalidValue, Failed, Closed, UnknownRoot, Limit };

/// Owns a separately opened descriptor and, when present, a reference to an
/// explicit extraction reservation. The SDK owns the input resource loan.
pub const RootHandle = struct {
    dir: std.Io.Dir,
    ticket: ?*service.Ticket = null,
    pub fn clone(dir: std.Io.Dir, ticket: ?*service.Ticket) !RootHandle {
        const copy = try dir.openDir(service.io(), ".", .{ .iterate = true });
        if (ticket) |reservation| reservation.retain();
        return .{ .dir = copy, .ticket = ticket };
    }
    pub fn deinit(self: *RootHandle) void {
        self.dir.close(service.io());
        if (self.ticket) |ticket| ticket.release();
    }
};

/// Lookup performs bounded comparisons even for host-configured root names.
/// Resource kinds are an exhaustive, caller-supplied nominal root capability set.
pub const RootLookup = struct {
    position: u64,
    index: usize = 0,
    offset: usize = 0,
    pub fn step(self: *RootLookup, comptime kinds: anytype, ctx: *ecl.Cooperative, owner: *service.Service.State, comptime lifetime: anytype) Error!union(enum) { pending, ready: RootHandle } {
        const input = ctx.input(&.{self.position}) orelse return error.InvalidValue;
        if (input.symbol()) |name| {
            while (ctx.consume(1)) {
                if (self.index == owner.roots.?.len) return error.UnknownRoot;
                const candidate = owner.roots.?[self.index];
                const count = @min(256, name.len - self.offset);
                if (name.len != candidate.name.len or !std.mem.eql(u8, name[self.offset..][0..count], candidate.name[self.offset..][0..count])) {
                    self.index += 1;
                    self.offset = 0;
                    continue;
                }
                self.offset += count;
                if (self.offset == name.len) return .{ .ready = RootHandle.clone(candidate.dir, null) catch return error.Failed };
            }
            return .pending;
        }
        inline for (kinds) |Kind| {
            const resource = ctx.initializationResource(Kind, &.{self.position}, lifetime) catch |err| switch (err) {
                error.InvalidValue => null,
                error.Closed => return error.Closed,
                error.Failed => return error.Failed,
            };
            if (resource) |root| return .{ .ready = RootHandle.clone(root.directory(), root.reservation()) catch return error.Failed };
        }
        return error.InvalidValue;
    }
};

/// One ordinary request consumes one slot. Explicit reservation roots already
/// own their slots; two distinct reserved roots must both be idle for a copy.
/// Acquisition is transactional and release requires neither allocation nor IO.
pub const Admission = struct {
    tickets: [2]?*service.Ticket = .{ null, null },
    pub fn acquire(owner: *service.Service.State, first: ?*service.Ticket, second: ?*service.Ticket) error{ OutOfMemory, Limit }!Admission {
        var result: Admission = .{};
        errdefer result.deinit();
        if (first == null and second == null) {
            result.tickets[0] = try owner.reserve() orelse return error.Limit;
            return result;
        }
        for ([_]?*service.Ticket{ first, second }) |candidate| {
            const ticket = candidate orelse continue;
            if (result.tickets[0] == ticket) continue;
            if (!ticket.acquire()) return error.Limit;
            ticket.retain();
            result.tickets[if (result.tickets[0] == null) @as(usize, 0) else 1] = ticket;
        }
        return result;
    }
    pub fn deinit(self: *Admission) void {
        for (&self.tickets) |*slot| if (slot.*) |ticket| {
            ticket.finish();
            ticket.release();
            slot.* = null;
        };
    }
};

pub const Failure = struct {
    reason: fs.Reason,
    message: ?[]const u8 = null,
    phase: enum { clearing, clear_wait, key, key_ready, value_ready, dictionary_ready, sealing, failed } = .clearing,
    pub fn step(self: *Failure, ctx: anytype) ecl.ControllerError!ecl.CooperativeProgress {
        const builder = ctx.errorData();
        switch (self.phase) {
            .clearing => {
                try builder.clear();
                self.phase = .clear_wait;
            },
            .clear_wait => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                self.phase = .key;
            },
            .key => {
                try builder.symbol("reason");
                self.phase = .key_ready;
            },
            .key_ready => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                try builder.symbol(self.reason.symbol());
                self.phase = .value_ready;
            },
            .value_ready => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                try builder.dictionary(1);
                self.phase = .dictionary_ready;
            },
            .dictionary_ready => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                try builder.seal();
                self.phase = .sealing;
            },
            .sealing => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                self.phase = .failed;
            },
            .failed => {
                ctx.fail(switch (self.reason) {
                    .invalid_path, .unknown_root => .domain,
                    .limit => .overflow,
                    else => .io,
                }, self.message orelse self.reason.message());
                return .completed;
            },
        }
        return .yielded;
    }
};

/// One construction owns every partially encoded path, resolver continuation,
/// descriptor and admission reservation until bounded retirement completes.
pub const Preparation = struct {
    owner: ?*service.Service.State = null,
    encoder: @import("encoding.zig").Encoder = .init(2, .text),
    validator: @import("encoding.zig").PathValidator = .{},
    lookup: RootLookup = .{ .position = 1 },
    path: ?[]u8 = null,
    root: ?RootHandle = null,
    admission: Admission = .{},
    resolver: ?fs.Resolver = null,
    create_parents: bool = false,
    transfer_bytes: ?u64 = null,
    resolved: ?fs.Resolved = null,
    failure: ?Failure = null,
    phase: enum { encoding, validating, lookup, admission, resolving, ready } = .encoding,
    pub fn step(self: *Preparation, comptime kinds: anytype, ctx: *ecl.Cooperative, mode: fs.ResolveMode, requires_entry: bool, comptime lifetime: anytype, reserve: bool) ecl.ControllerError!ecl.CooperativeProgress {
        if (self.failure) |*failure| return failure.step(ctx);
        if (self.owner == null) self.owner = ctx.instance(service.Service) orelse return error.InvalidValue;
        const owner = self.owner.?;
        switch (self.phase) {
            .encoding => {
                if ((self.encoder.step(ctx, owner.allocator()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidType, error.InvalidByte => {
                        ctx.fail(.type, "expected a string path");
                        return error.Failed;
                    },
                    error.Limit => return self.fail(.limit),
                    error.InvalidPath => return self.fail(.invalid_path),
                }) == .pending) return .yielded;
                self.path = self.encoder.take();
                self.phase = .validating;
            },
            .validating => switch (self.validator.step(ctx, self.path.?) catch return self.fail(.invalid_path)) {
                .pending => return .yielded,
                .complete => |kind| {
                    if (requires_entry and kind == .root) return self.fail(.invalid_path);
                    self.phase = .lookup;
                },
            },
            .lookup => switch (self.lookup.step(kinds, ctx, owner, lifetime) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidValue => {
                    ctx.fail(.type, "expected a filesystem root symbol or directory resource");
                    return error.Failed;
                },
                error.UnknownRoot => return self.fail(.unknown_root),
                error.Closed => {
                    self.failure = .{ .reason = .io, .message = "directory resource is closed" };
                    return .yielded;
                },
                error.Failed => return self.fail(.io),
                error.Limit => return self.fail(.limit),
            }) {
                .pending => return .yielded,
                .ready => |root| {
                    self.root = root;
                    self.phase = .admission;
                },
            },
            .admission => {
                if (self.transfer_bytes) |bytes| if (bytes > owner.limits.max_transfer_bytes) return self.fail(.limit);
                if (reserve) self.admission = Admission.acquire(owner, self.root.?.ticket, null) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Limit => return self.fail(.limit),
                };
                self.resolver = fs.Resolver.init(owner.allocator(), service.io(), self.root.?.dir, self.path.?, owner.limits, mode) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PathTooLong => return self.fail(.limit),
                };
                if (self.create_parents) self.resolver.?.createParents();
                self.phase = .resolving;
            },
            .resolving => switch (try self.resolver.?.step()) {
                .pending => return .yielded,
                .failed => |reason| return self.fail(reason),
                .complete => |resolved| {
                    self.resolved = resolved;
                    self.phase = .ready;
                },
            },
            .ready => return .completed,
        }
        return .yielded;
    }
    pub fn fail(self: *Preparation, reason: fs.Reason) ecl.CooperativeProgress {
        self.failure = .{ .reason = reason };
        return .yielded;
    }
    pub fn retire(self: *Preparation) bool {
        const owner = self.owner orelse return true;
        if (self.resolver) |*resolver| {
            if (!resolver.retireStep()) return false;
            self.resolver = null;
            return false;
        }
        if (self.resolved) |*resolved| {
            resolved.deinit(owner.allocator(), service.io());
            self.resolved = null;
            return false;
        }
        if (self.root) |*root| {
            root.deinit();
            self.root = null;
            return false;
        }
        if (self.path) |path| owner.allocator().free(path);
        self.path = null;
        self.encoder.deinit(owner.allocator());
        self.admission.deinit();
        return true;
    }
};
