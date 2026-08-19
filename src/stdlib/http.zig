//! The internal `http` module: a client over `std.http.Client`.
//!
//! This is a builtin-backed module because TLS and sockets are host authority
//! no ECL program can express and the native SDK deliberately withholds — an
//! external module gets no allocator, no network, and no state that outlives a
//! yield. It is not exposed as an SDK capability.
//!
//! **The request blocks the calling unit's worker thread.** That is the one
//! documented first-party v1 exception to the cooperative-scheduling rule: a
//! `@each` over N urls at N workers runs at most N concurrent requests, and
//! at one worker it serializes. There is also no request deadline in v1, so an
//! unresponsive server occupies its worker until the host gives up. Both go
//! away with the future `Offload` capability without changing the value-level
//! API, which is why the response shape is fixed now: `{'status int,
//! 'headers dict, 'body string}` leaks no backend detail.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const kernel_storage = @import("../kernel_storage.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    // As with `json`, the stack shape is prose rather than a declared effect:
    // both words hand their work to a scheduler driver, and a declared effect
    // is checked the instant the primitive returns.
    .{
        .name = "get",
        .doc = "( url headers -- response ) Fetch a url with caller-supplied headers, " ++
            "returning {'status 'headers 'body}. Use {} for no headers.",
        .primitive = get,
    },
    .{
        .name = "post",
        .doc = "( url headers body -- response ) Post a body to a url with " ++
            "caller-supplied headers, returning {'status 'headers 'body}.",
        .primitive = post,
    },
};

/// Response bodies are bounded by ordinary allocation in v1.
const redirect_buffer_bytes: usize = 8 * 1024;

fn get(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .GET);
}

fn post(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .POST);
}

fn begin(evaluator: *Machine, method: std.http.Method) MachineError!void {
    const sends_body = method == .POST;
    try evaluator.require(if (sends_body) 3 else 2);
    var body: ?heap.OwnedValue = null;
    errdefer if (body) |*owned| owned.deinit();
    if (sends_body) {
        body = try evaluator.popValue();
        if (!body.?.borrow().isString())
            return evaluator.typeError("a string request body");
    }
    var headers = try evaluator.popValue();
    errdefer headers.deinit();
    if (headers.borrow() != .dict) return evaluator.typeError("a dict of request headers");
    var url = try evaluator.popValue();
    errdefer url.deinit();
    if (!url.borrow().isString()) return evaluator.typeError("a string url");
    if (evaluator.unit.inherited.host_io == null) {
        const failure = evaluator.fail(.io, "network access is unavailable");
        evaluator.addErrorPath(url.borrow());
        return failure;
    }
    try evaluator.startDriver(RequestDriver{
        .allocator = evaluator.allocator(),
        .method = method,
        .url_value = .init(url.take()),
        .headers_value = .init(headers.take()),
        .body_value = if (body) |*owned| .init(owned.take()) else null,
    });
}

/// One owned name/value pair of bytes, on either side of the exchange.
const Field = struct {
    name: []u8,
    value: []u8,
};

const Phase = enum {
    /// Encode the url to bytes.
    url,
    /// Encode each request header name and value to bytes.
    request_headers,
    /// Encode the request body to bytes.
    request_body,
    /// Perform the whole exchange. This is the blocking step.
    exchange,
    /// Materialize response header names and values as strings.
    response_headers,
    /// Materialize the response body as a string.
    response_body,
    /// Assemble the response dict.
    finish,
};

const RequestDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url_value: heap.Owned(Value),
    headers_value: heap.Owned(Value),
    body_value: ?heap.Owned(Value),
    phase: Phase = .url,

    /// Encoding an ECL string to bytes is resumable, one string at a time.
    encoder: ?kernel_storage.StringEncoder = null,
    url: ?[]u8 = null,
    request_body: ?[]u8 = null,
    request_fields: std.ArrayList(Field) = .empty,
    pending_name: ?[]u8 = null,
    field_index: usize = 0,
    encoding_value: bool = false,

    status: u16 = 0,
    response_fields: std.ArrayList(Field) = .empty,
    response_body: std.ArrayList(u8) = .empty,

    /// Materializing a string or a dict is resumable too.
    text: ?kernel_storage.TextMaterializer = null,
    pairs: std.ArrayList(dict.Pair) = .empty,
    pair_key: ?Value = null,
    dictionary: ?kernel_storage.DictMaterializer = null,
    headers_result: ?Value = null,
    body_result: ?Value = null,
    outer: ?[]dict.Pair = null,

    pub fn advance(evaluator: *Machine, self: *RequestDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.phase) {
            .url => {
                const bytes = try self.encode(evaluator, self.url_value.borrow()) orelse
                    return .yielded;
                self.url = bytes;
                self.phase = .request_headers;
                return .yielded;
            },
            .request_headers => return self.advanceRequestHeaders(evaluator),
            .request_body => {
                const bytes = try self.encode(evaluator, self.body_value.?.borrow()) orelse
                    return .yielded;
                self.request_body = bytes;
                self.phase = .exchange;
                return .yielded;
            },
            .exchange => {
                try self.exchange(evaluator);
                self.phase = .response_headers;
                return .yielded;
            },
            .response_headers => return self.advanceResponseHeaders(evaluator),
            .response_body => {
                if (self.text == null)
                    self.text = .init(self.allocator, self.response_body.items);
                switch (try self.text.?.advance(machine.kernel_poll_quantum)) {
                    .pending => return .yielded,
                    .complete => |text| {
                        self.text.?.deinit();
                        self.text = null;
                        self.body_result = text;
                        self.phase = .finish;
                        return .yielded;
                    },
                }
            },
            .finish => return self.finish(evaluator),
        }
    }

    /// Drives one string's encoding, returning null until it completes.
    fn encode(
        self: *RequestDriver,
        evaluator: *Machine,
        item: Value,
    ) MachineError!?[]u8 {
        if (self.encoder == null) self.encoder = .init(self.allocator, item);
        return switch (self.encoder.?.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "a request string contains an invalid Unicode scalar",
            ),
        }) {
            .pending => null,
            .complete => |bytes| bytes: {
                self.encoder.?.deinit();
                self.encoder = null;
                break :bytes bytes;
            },
        };
    }

    fn advanceRequestHeaders(
        self: *RequestDriver,
        evaluator: *Machine,
    ) MachineError!machine.WorkProgress {
        const header_dict = self.headers_value.borrow().dict;
        const count: usize = @intCast(dict.keysOf(header_dict).list.length());
        if (self.field_index == count) {
            // Response-header materialization starts its own traversal after
            // the exchange. Do not let the number of request headers skip
            // that many response headers.
            self.field_index = 0;
            self.phase = if (self.body_value == null) .exchange else .request_body;
            return .yielded;
        }
        if (!self.encoding_value) {
            const key = dict.keyAt(header_dict, self.field_index);
            if (!key.isString())
                return evaluator.typeError("request header names to be strings");
            const bytes = try self.encode(evaluator, key) orelse return .yielded;
            self.pending_name = bytes;
            self.encoding_value = true;
            return .yielded;
        }
        const item = dict.valueAt(header_dict, self.field_index);
        if (!item.isString())
            return evaluator.typeError("request header values to be strings");
        const bytes = try self.encode(evaluator, item) orelse return .yielded;
        self.request_fields.append(self.allocator, .{
            .name = self.pending_name.?,
            .value = bytes,
        }) catch |err| {
            // `pending_name` is still owned by the driver; the value just
            // encoded is not, so a failed append frees it here.
            self.allocator.free(bytes);
            return err;
        };
        self.pending_name = null;
        self.encoding_value = false;
        self.field_index += 1;
        return .yielded;
    }

    fn failIo(self: *RequestDriver, evaluator: *Machine, name: []const u8) MachineError {
        const failure = evaluator.failFmt(
            .io,
            "cannot reach `{s}`: {s}",
            .{ self.url.?, name },
        );
        evaluator.addErrorPath(self.url_value.borrow());
        return failure;
    }

    /// The whole exchange in one scheduler step: this is the documented
    /// blocking exception. Response headers are copied before the body stream
    /// is initialized, because that invalidates them.
    fn exchange(self: *RequestDriver, evaluator: *Machine) MachineError!void {
        const io = evaluator.unit.inherited.host_io.?;
        const uri = std.Uri.parse(self.url.?) catch
            return self.failIo(evaluator, "InvalidUrl");
        const extra = try self.allocator.alloc(std.http.Header, self.request_fields.items.len);
        defer self.allocator.free(extra);
        for (self.request_fields.items, extra) |field, *header|
            header.* = .{ .name = field.name, .value = field.value };

        var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
        defer client.deinit();
        const sends_body = self.request_body != null;
        var request = client.request(self.method, uri, .{
            .redirect_behavior = if (sends_body) .unhandled else @enumFromInt(3),
            .extra_headers = extra,
        }) catch |err| return self.failIo(evaluator, @errorName(err));
        defer request.deinit();

        if (self.request_body) |payload| {
            request.transfer_encoding = .{ .content_length = payload.len };
            var body = request.sendBodyUnflushed(&.{}) catch |err|
                return self.failIo(evaluator, @errorName(err));
            body.writer.writeAll(payload) catch |err|
                return self.failIo(evaluator, @errorName(err));
            body.end() catch |err| return self.failIo(evaluator, @errorName(err));
            request.connection.?.flush() catch |err|
                return self.failIo(evaluator, @errorName(err));
        } else request.sendBodiless() catch |err|
            return self.failIo(evaluator, @errorName(err));

        const redirect_buffer = try self.allocator.alloc(u8, redirect_buffer_bytes);
        defer self.allocator.free(redirect_buffer);
        var response = request.receiveHead(redirect_buffer) catch |err|
            return self.failIo(evaluator, @errorName(err));
        self.status = @intFromEnum(response.head.status);

        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            const name = try self.allocator.dupe(u8, header.name);
            errdefer self.allocator.free(name);
            const item = try self.allocator.dupe(u8, header.value);
            errdefer self.allocator.free(item);
            // HTTP field names are case-insensitive and repeated fields are
            // legal. The value-level API exposes a dict, so retain the last
            // occurrence under its spelling instead of asking the dict
            // materializer to reject a duplicate.
            for (self.response_fields.items) |*field| {
                if (std.ascii.eqlIgnoreCase(field.name, name)) {
                    self.allocator.free(field.name);
                    self.allocator.free(field.value);
                    field.* = .{ .name = name, .value = item };
                    break;
                }
            } else try self.response_fields.append(
                self.allocator,
                .{ .name = name, .value = item },
            );
        }

        const decompress_bytes: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            .deflate, .gzip => std.compress.flate.max_window_len,
            .compress => return self.failIo(evaluator, "UnsupportedCompressionMethod"),
        };
        const decompress_buffer = try self.allocator.alloc(u8, decompress_bytes);
        defer self.allocator.free(decompress_buffer);
        // SAFETY: the decompressor writes this scratch before any read of it.
        var transfer_buffer: [64]u8 = undefined;
        // SAFETY: initialized by readerDecompressing before any use.
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(
            &transfer_buffer,
            &decompress,
            decompress_buffer,
        );
        var collected = std.Io.Writer.Allocating.init(self.allocator);
        defer collected.deinit();
        _ = reader.streamRemaining(&collected.writer) catch
            return self.failIo(evaluator, "ReadFailed");
        self.response_body.deinit(self.allocator);
        self.response_body = .empty;
        try self.response_body.appendSlice(self.allocator, collected.written());
    }

    fn advanceResponseHeaders(
        self: *RequestDriver,
        evaluator: *Machine,
    ) MachineError!machine.WorkProgress {
        if (self.field_index < self.response_fields.items.len) {
            const field = self.response_fields.items[self.field_index];
            const source = if (self.pair_key == null) field.name else field.value;
            if (self.text == null) self.text = .init(self.allocator, source);
            switch (try self.text.?.advance(machine.kernel_poll_quantum)) {
                .pending => return .yielded,
                .complete => |text| {
                    self.text.?.deinit();
                    self.text = null;
                    if (self.pair_key == null) {
                        self.pair_key = text;
                        return .yielded;
                    }
                    self.pairs.append(self.allocator, .{ self.pair_key.?, text }) catch |err| {
                        evaluator.releaseDomain().releaseValue(text);
                        return err;
                    };
                    self.pair_key = null;
                    self.field_index += 1;
                    return .yielded;
                },
            }
        }
        if (self.dictionary == null)
            self.dictionary = try .init(self.allocator, self.pairs.items, true);
        switch (try self.dictionary.?.advance(machine.kernel_poll_quantum)) {
            .pending => return .yielded,
            // `exchange` coalesces case-insensitive HTTP field names before
            // they reach this ordinary, case-sensitive ECL dictionary.
            .duplicate_key => unreachable,
            .complete => |built| {
                self.dictionary.?.deinit();
                self.dictionary = null;
                self.headers_result = built;
                self.releasePairs(evaluator.releaseDomain());
                self.phase = .response_body;
                return .yielded;
            },
        }
    }

    fn releasePairs(self: *RequestDriver, releases: *heap.ReleaseDomain) void {
        // The materializer retained what it copied, so this driver's own
        // references to the header strings are released here.
        for (self.pairs.items) |pair| {
            releases.releaseValue(pair[0]);
            releases.releaseValue(pair[1]);
        }
        self.pairs.clearRetainingCapacity();
    }

    fn finish(self: *RequestDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.outer == null) {
            const slots = try self.allocator.alloc(dict.Pair, 3);
            slots[0] = .{
                .{ .symbol = try intern.intern("status") },
                .{ .int = @intCast(self.status) },
            };
            slots[1] = .{
                .{ .symbol = try intern.intern("headers") },
                self.headers_result.?,
            };
            slots[2] = .{
                .{ .symbol = try intern.intern("body") },
                self.body_result.?,
            };
            self.outer = slots;
            self.dictionary = try .init(self.allocator, slots, true);
        }
        return switch (try self.dictionary.?.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .duplicate_key => evaluator.fail(.domain, "http response keys collided"),
            .complete => |built| output: {
                self.dictionary.?.deinit();
                self.dictionary = null;
                break :output .{ .output = built };
            },
        };
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
        self: *RequestDriver,
    ) bool {
        if (self.encoder) |*encoder| encoder.deinit();
        self.encoder = null;
        if (self.text) |*text| text.retire(releases);
        self.text = null;
        if (self.dictionary) |*dictionary| dictionary.retire(releases);
        self.dictionary = null;
        if (self.pair_key) |key| releases.releaseValue(key);
        self.pair_key = null;
        for (self.pairs.items) |pair| {
            releases.releaseValue(pair[0]);
            releases.releaseValue(pair[1]);
        }
        self.pairs.deinit(self.allocator);
        if (self.headers_result) |built| releases.releaseValue(built);
        self.headers_result = null;
        if (self.body_result) |built| releases.releaseValue(built);
        self.body_result = null;
        if (self.outer) |slots| self.allocator.free(slots);
        self.outer = null;
        if (self.url) |bytes| self.allocator.free(bytes);
        self.url = null;
        if (self.request_body) |bytes| self.allocator.free(bytes);
        self.request_body = null;
        if (self.pending_name) |bytes| self.allocator.free(bytes);
        self.pending_name = null;
        for (self.request_fields.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.request_fields.deinit(self.allocator);
        for (self.response_fields.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.response_fields.deinit(self.allocator);
        self.response_body.deinit(self.allocator);
        self.url_value.deinit(releases, storage_allocator);
        self.headers_value.deinit(releases, storage_allocator);
        if (self.body_value) |*owned| owned.deinit(releases, storage_allocator);
        self.body_value = null;
        storage_allocator.destroy(self);
        return true;
    }
};
