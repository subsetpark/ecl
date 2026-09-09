//! Session-owned HTTP execution. Worker capabilities never await or cancel I/O futures.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const scheduler = @import("scheduler.zig");
const controllers = @import("port_controller.zig");
const transport = @import("port_bytes.zig");
const machine = @import("machine.zig");
pub const Failure = transport.Failure;
pub const Field = struct { name: []u8, value: []u8 };
pub const Input = struct { url: []u8, body: ?[]u8 = null, fields: std.ArrayList(Field) = .empty };
pub const Response = struct { request: Input, status: u16 = 0, fields: std.ArrayList(Field) = .empty };
pub const Limits = struct {
    live_requests: usize = 16,
    deadline_ms: u63 = 30_000,
    target_bytes: usize = 16 * 1024,
    outbound_bytes: usize = 16 * 1024 * 1024,
    encoded_bytes: usize = 64 * 1024 * 1024,
    decoded_bytes: usize = 64 * 1024 * 1024,
    header_bytes: usize = 64 * 1024,
    header_fields: usize = 256,
    transport_bytes: usize = 64 * 1024,
    scratch_bytes: usize = 16 * 1024 * 1024,

    fn validate(self: Limits) error{InvalidConfig}!void {
        if (self.live_requests == 0 or self.live_requests > 256 or self.deadline_ms == 0 or
            self.target_bytes == 0 or self.target_bytes > 16 * 1024 or
            self.outbound_bytes > 16 * 1024 * 1024 or self.encoded_bytes > 64 * 1024 * 1024 or
            self.decoded_bytes > 64 * 1024 * 1024 or self.header_bytes == 0 or self.header_bytes > 64 * 1024 or
            self.header_fields == 0 or self.header_fields > 256 or self.transport_bytes == 0 or
            self.transport_bytes > 64 * 1024 or self.scratch_bytes == 0) return error.InvalidConfig;
    }
};
const Service = struct {
    host: *const heap.HostCleanup,
    io: std.Io,
    trust: ?machine.TlsTrust,
    limits: Limits,
    executor: *controllers.Owner,
    live: std.atomic.Value(usize) = .init(0),
    fn owner(self: *Service) *Owner {
        return @ptrCast(self);
    }
};
pub const Owner = opaque {
    fn state(self: *Owner) *Service {
        return @ptrCast(@alignCast(self));
    }
    pub fn init(host: *const heap.HostCleanup, io: std.Io, trust: ?machine.TlsTrust, limits: Limits) !*Owner {
        try limits.validate();
        const service = try host.allocator().create(Service);
        errdefer host.allocator().destroy(service);
        service.* = .{ .host = host, .io = io, .trust = trust, .limits = limits, .executor = try controllers.Owner.init(host.allocator(), limits.live_requests + 1) };
        return service.owner();
    }
    pub fn access(self: *Owner) *Access {
        return @ptrCast(self);
    }
    /// Scope shutdown and driver retirement precede destruction of this owner.
    pub fn deinit(self: *Owner) void {
        const service = self.state();
        service.executor.deinit();
        std.debug.assert(service.live.load(.acquire) == 0);
        service.host.allocator().destroy(service);
    }
};
pub const Access = opaque {
    fn state(self: *Access) *Service {
        return @ptrCast(@alignCast(self));
    }
    pub fn limits(self: *Access) Limits {
        return self.state().limits;
    }
    pub fn admit(self: *Access) error{ OutOfMemory, Overflow }!*Request {
        const service = self.state();
        var live = service.live.load(.acquire);
        while (true) {
            if (live == service.limits.live_requests) return error.Overflow;
            live = service.live.cmpxchgWeak(live, live + 1, .acq_rel, .acquire) orelse break;
        }
        errdefer _ = service.live.fetchSub(1, .acq_rel);
        const allocator = service.host.allocator();
        const cell = try allocator.create(Cell);
        errdefer allocator.destroy(cell);
        const pair = transport.create(service.host, service.limits.transport_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCapacity => unreachable,
        };
        errdefer pair.pipe.release();
        const group = try Group.init(allocator, service.executor.access(), cell);
        cell.* = .{ .service = service, .allocator = allocator, .pair = pair, .group = group };
        return @ptrCast(cell);
    }
};
const Fault = union(enum) { out_of_memory, overflow, io: anyerror };
const Group = controllers.Group(Cell, ?Fault, .{
    .retain = Cell.retainReadiness,
    .release = Cell.releaseReadiness,
    .retireLocked = Cell.retireLocked,
    .ownership = Cell.scopeOwnership,
});
const Cell = struct {
    service: *Service,
    allocator: std.mem.Allocator,
    pair: transport.Pair,
    group: *Group,
    refs: std.atomic.Value(usize) = .init(1),
    cancelled: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    waits: external.WaitList(Cell) = .{},
    ownership: external.Ownership = .provisional,
    phase: union(enum) {
        preparing,
        active: Response,
        joined: struct { response: Response, failure: ?Failure },
        taken,
    } = .preparing,
    method: std.http.Method = .GET,
    redirects: bool = false,
    io_finished: bool = false,
    fn scopeOwnership(self: *Cell) *external.Ownership {
        return &self.ownership;
    }
    pub fn retainReadiness(self: *Cell) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn releaseReadiness(self: *Cell) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.phase == .preparing or self.phase == .taken);
        self.group.deinit();
        self.pair.pipe.release();
        _ = self.service.live.fetchSub(1, .acq_rel);
        self.allocator.destroy(self);
    }
    pub fn retainExternalMember(self: *Cell) void {
        self.retainReadiness();
    }
    pub fn releaseExternalMember(self: *Cell) void {
        self.releaseReadiness();
    }
    pub fn cancelExternalMember(self: *Cell, scope: *external.ScopeIdentity) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.ownership.authorizesCancellation(scope)) self.cancelLocked();
    }
    fn cancelLocked(self: *Cell) void {
        self.cancelled.store(true, .release);
        self.pair.pipe.interrupt();
        self.changed.broadcast(blockingIo());
    }
    fn prepare(self: *Cell, scope: *scheduler.TaskScope) !void {
        try @import("port_transfer.zig").publishScope(Cell, self, scope, Cell.scopeOwnership);
    }
    fn rollback(_: *Cell) void {}
    fn retireLocked(self: *Cell, result: controllers.Outcome(?Fault)) void {
        const failure = switch (result) {
            .aborted => Failure.init(.io, "HTTP controller startup failed"),
            .completed => |fault| if (fault) |f| switch (f) {
                .out_of_memory => Failure.out_of_memory,
                .overflow => Failure.init(.overflow, "HTTP transfer or scratch limit exceeded"),
                .io => |err| Failure.init(.io, @errorName(err)),
            } else null,
        };
        const response = self.phase.active;
        self.phase = .{ .joined = .{ .response = response, .failure = failure } };
        self.pair.pipe.finish();
        self.waits.notifyLocked(self);
    }
    pub fn readyLocked(self: *Cell, _: u64) bool {
        return self.phase == .joined;
    }
    pub fn wakeReasonLocked(_: *Cell, _: u64) external.Wake {
        return .ready;
    }
    pub fn registerReadiness(self: *Cell, key: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return external.WaitList(Cell).register(self, key, target);
    }
    fn run(_: *controllers.Execution, self: *Cell) ?Fault {
        // This controller alone owns the Future. Cancellation only signals us;
        // it never operates on that Future from a scheduler worker.
        var future = std.Io.concurrent(self.service.io, Cell.exchangeTask, .{self}) catch |err| return .{ .io = err };
        std.Io.Threaded.mutexLock(&self.mutex);
        while (!self.io_finished and !self.cancelled.load(.acquire))
            self.changed.waitUncancelable(blockingIo(), &self.mutex);
        const cancel = self.cancelled.load(.acquire);
        std.Io.Threaded.mutexUnlock(&self.mutex);
        return if (cancel) future.cancel(self.service.io) else future.await(self.service.io);
    }
    fn exchangeTask(self: *Cell) ?Fault {
        defer {
            std.Io.Threaded.mutexLock(&self.mutex);
            self.io_finished = true;
            self.changed.broadcast(blockingIo());
            std.Io.Threaded.mutexUnlock(&self.mutex);
        }
        var scratch: Accounting = .{ .parent = self.allocator, .limit = self.service.limits.scratch_bytes };
        self.exchange(scratch.allocator()) catch |err| return if (scratch.exhausted)
            .overflow
        else switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Overflow => .overflow,
            else => .{ .io = err },
        };
        return null;
    }
    fn exchange(self: *Cell, scratch: std.mem.Allocator) !void {
        const limits = self.service.limits;
        const response = &self.phase.active;
        var uri = std.Uri.parse(response.request.url) catch return error.InvalidUrl;
        const extra = try scratch.alloc(std.http.Header, response.request.fields.items.len);
        defer scratch.free(extra);
        for (response.request.fields.items, extra) |field, *header| header.* = .{ .name = field.name, .value = field.value };
        var client: std.http.Client = .{ .allocator = scratch, .io = self.service.io, .read_buffer_size = limits.header_bytes + 8192 };
        defer client.deinit();
        if (self.service.trust) |trust| {
            client.now = trust.now;
            try client.ca_bundle.addCertsFromFilePathAbsolute(scratch, self.service.io, trust.now, trust.ca_file);
        }
        const redirect_storage = try scratch.alloc(u8, 8 * 1024);
        defer scratch.free(redirect_storage);
        var redirect_space = redirect_storage;
        var redirects: usize = 0;
        var method = self.method;
        var encoded: usize = 0;
        var decoded: usize = 0;
        var header_bytes: usize = 0;
        var header_fields: usize = 0;
        while (true) {
            if (self.cancelled.load(.acquire)) return error.Canceled;
            var request = try client.request(method, uri, .{ .redirect_behavior = .unhandled, .extra_headers = extra });
            defer request.deinit();
            if (method.requestHasBody()) {
                const payload = response.request.body orelse &.{};
                request.transfer_encoding = .{ .content_length = payload.len };
                var body = try request.sendBodyUnflushed(&.{});
                try body.writer.writeAll(payload);
                try body.end();
                try request.connection.?.flush();
            } else try request.sendBodiless();
            var head = request.receiveHead(&.{}) catch |err| switch (err) {
                error.HttpHeadersOversize => return error.Overflow,
                else => return err,
            };
            response.status = @intFromEnum(head.head.status);
            const redirect = self.redirects and !method.requestHasBody() and head.head.status.class() == .redirect and head.head.status != .not_modified;
            const status_end = std.mem.indexOf(u8, head.head.bytes, "\r\n") orelse return error.HttpHeadersInvalid;
            const field_bytes = head.head.bytes.len - status_end - 4;
            if (field_bytes > limits.header_bytes - header_bytes) return error.Overflow;
            header_bytes += field_bytes;
            var iterator = head.head.iterateHeaders();
            while (iterator.next()) |field| {
                header_fields += 1;
                if (header_fields > limits.header_fields) return error.Overflow;
                if (redirect) continue;
                const name = try self.allocator.dupe(u8, field.name);
                errdefer self.allocator.free(name);
                const text = try self.allocator.dupe(u8, field.value);
                errdefer self.allocator.free(text);
                try response.fields.append(self.allocator, .{ .name = name, .value = text });
            }
            const next_uri: ?std.Uri = if (redirect) blk: {
                if (redirects == 3) return error.TooManyHttpRedirects;
                const location = head.head.location orelse return error.HttpRedirectLocationMissing;
                if (location.len > redirect_space.len) return error.HttpRedirectLocationOversize;
                @memcpy(redirect_space[0..location.len], location);
                break :blk try uri.resolveInPlace(location.len, &redirect_space);
            } else null;
            const next_method: std.http.Method = if (redirect and head.head.status == .see_other) .GET else method;
            const encoding = head.head.content_encoding;
            if (encoding == .compress) return error.UnsupportedCompressionMethod;
            const decompress_buffer = try scratch.alloc(u8, encoding.minBufferCapacity());
            defer scratch.free(decompress_buffer);
            var transfer_buffer: [4096]u8 = undefined;
            var encoded_buffer: [4096]u8 = undefined;
            var counted: CountedReader = .{ .upstream = head.reader(&transfer_buffer), .count = &encoded, .limit = limits.encoded_bytes, .reader = .{ .vtable = &.{ .stream = CountedReader.stream }, .buffer = &encoded_buffer, .seek = 0, .end = 0 } };
            // SAFETY: init fills the selected decompressor before reader use.
            var decompress: std.http.Decompress = undefined;
            const reader = decompress.init(&counted.reader, decompress_buffer, encoding);
            var buffer: [16 * 1024]u8 = undefined;
            while (true) {
                const count = reader.readSliceShort(&buffer) catch |err| {
                    if (counted.exceeded) return error.Overflow;
                    return err;
                };
                if (count == 0) break;
                if (count > limits.decoded_bytes - decoded) return error.Overflow;
                decoded += count;
                if (!redirect) switch (self.pair.controller.writeAll(buffer[0..count], &self.cancelled)) {
                    .complete => {},
                    .cancelled => return error.Canceled,
                    .out_of_memory => return error.OutOfMemory,
                    .failed => return error.WriteFailed,
                };
            }
            // Compression may end before its encoded source. Charge the rest too.
            _ = counted.reader.discardRemaining() catch |err| {
                if (counted.exceeded) return error.Overflow;
                return err;
            };
            if (next_uri) |next| {
                uri = next;
                method = next_method;
                redirects += 1;
            } else return;
        }
    }
};
fn blockingIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Request = opaque {
    fn state(self: *Request) *Cell {
        return @ptrCast(@alignCast(self));
    }
    /// Always consumes input, including startup failure; retirement owns rollback.
    pub fn start(self: *Request, input: Input, method: std.http.Method, redirects: bool, scope: *scheduler.TaskScope) !void {
        const cell = self.state();
        cell.phase = .{ .active = .{ .request = input } };
        cell.method = method;
        cell.redirects = redirects;
        try cell.group.start(.{scope}, Cell.prepare, Cell.run, Cell.rollback);
    }
    pub fn target(self: *Request) []const u8 {
        return self.state().phase.joined.response.request.url;
    }
    pub fn pipe(self: *Request) *transport.Pipe {
        return self.state().pair.pipe;
    }
    pub fn source(self: *Request) external.ReadinessSource {
        return external.readinessSource(Cell, self.state(), 0);
    }
    pub fn result(self: *Request) union(enum) { pending, complete, failed: Failure } {
        const cell = self.state();
        std.Io.Threaded.mutexLock(&cell.mutex);
        defer std.Io.Threaded.mutexUnlock(&cell.mutex);
        return switch (cell.phase) {
            .preparing, .active => .pending,
            .joined => |joined| if (joined.failure) |f| .{ .failed = f } else .complete,
            .taken => unreachable,
        };
    }
    /// Completion synchronizes every response write and transfers its storage.
    pub fn take(self: *Request) Response {
        const cell = self.state();
        std.Io.Threaded.mutexLock(&cell.mutex);
        defer std.Io.Threaded.mutexUnlock(&cell.mutex);
        std.debug.assert(cell.phase == .joined);
        const response = cell.phase.joined.response;
        cell.phase = .taken;
        return response;
    }
    pub fn cancel(self: *Request) void {
        const cell = self.state();
        std.Io.Threaded.mutexLock(&cell.mutex);
        defer std.Io.Threaded.mutexUnlock(&cell.mutex);
        cell.cancelLocked();
    }
    /// Cancels, waits by polling, and retires one owned field per step. True
    /// consumes the observer; admission survives until its final borrower.
    pub fn retire(self: *Request) bool {
        const cell = self.state();
        self.cancel();
        std.Io.Threaded.mutexLock(&cell.mutex);
        const active = cell.phase == .active;
        std.Io.Threaded.mutexUnlock(&cell.mutex);
        if (active) return false;
        if (cell.phase == .joined) {
            const response = &cell.phase.joined.response;
            if (response.fields.pop()) |field| {
                cell.allocator.free(field.name);
                cell.allocator.free(field.value);
                return false;
            }
            if (response.request.fields.pop()) |field| {
                cell.allocator.free(field.name);
                cell.allocator.free(field.value);
                return false;
            }
            response.fields.deinit(cell.allocator);
            response.request.fields.deinit(cell.allocator);
            if (response.request.body) |body| cell.allocator.free(body);
            cell.allocator.free(response.request.url);
            cell.phase = .taken;
        }
        cell.releaseReadiness();
        return true;
    }
};
const CountedReader = struct {
    upstream: *std.Io.Reader,
    count: *usize,
    limit: usize,
    exceeded: bool = false,
    reader: std.Io.Reader,
    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CountedReader = @fieldParentPtr("reader", reader);
        const remaining = self.limit - self.count.*;
        if (remaining == 0) {
            var probe: [1]u8 = undefined;
            if (try self.upstream.readSliceShort(&probe) == 0) return error.EndOfStream;
            self.exceeded = true;
            return error.ReadFailed;
        }
        const count = try self.upstream.stream(writer, limit.min(.limited(remaining)));
        self.count.* += count;
        return count;
    }
};
/// Backend-local accounting preserves the allocator's OOM distinction. No
/// allocator operation on this state runs concurrently with another.
const Accounting = struct {
    parent: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    exhausted: bool = false,
    fn allocator(self: *Accounting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn charge(self: *Accounting, old: usize, new: usize) bool {
        if (new > old and new - old > self.limit - self.used) {
            self.exhausted = true;
            return false;
        }
        return true;
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Accounting = @ptrCast(@alignCast(raw));
        self.exhausted = false;
        if (!self.charge(0, len)) return null;
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        return result;
    }
    fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Accounting = @ptrCast(@alignCast(raw));
        self.exhausted = false;
        if (!self.charge(bytes.len, len) or !self.parent.rawResize(bytes, alignment, len, ra)) return false;
        self.used = self.used - bytes.len + len;
        return true;
    }
    fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Accounting = @ptrCast(@alignCast(raw));
        self.exhausted = false;
        if (!self.charge(bytes.len, len)) return null;
        const result = self.parent.rawRemap(bytes, alignment, len, ra) orelse return null;
        self.used = self.used - bytes.len + len;
        return result;
    }
    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Accounting = @ptrCast(@alignCast(raw));
        self.parent.rawFree(bytes, alignment, ra);
        self.used -= bytes.len;
    }
};

test "http: owner initialization and admission rollback survive allocation failure" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var cleanup = heap.testing.Cleanup.init(allocator);
            defer cleanup.deinit();
            const owner = try Owner.init(cleanup.capability(), std.testing.io, null, .{ .live_requests = 1 });
            defer owner.deinit();
            const request = try owner.access().admit();
            defer _ = request.retire();
            try std.testing.expectError(error.Overflow, owner.access().admit());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "http: independent admission budgets recover after provisional cancellation" {
    var cleanup = heap.testing.Cleanup.init(std.testing.allocator);
    defer cleanup.deinit();
    const first = try Owner.init(cleanup.capability(), std.testing.io, null, .{ .live_requests = 1 });
    defer first.deinit();
    const second = try Owner.init(cleanup.capability(), std.testing.io, null, .{ .live_requests = 1 });
    defer second.deinit();
    for (0..20) |_| {
        const a = try first.access().admit();
        const b = try second.access().admit();
        try std.testing.expectError(error.Overflow, first.access().admit());
        a.cancel();
        try std.testing.expect(a.retire());
        try std.testing.expect(b.retire());
    }
}

test "http: backend accounting distinguishes limits from allocator failure" {
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var accounting: Accounting = .{ .parent = failed.allocator(), .limit = 16 };
    const alloc = accounting.allocator();
    const bytes = try alloc.alloc(u8, 16);
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
    try std.testing.expect(accounting.exhausted);
    alloc.free(bytes);
    failed.fail_index = failed.alloc_index;
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
    try std.testing.expect(!accounting.exhausted);
}
