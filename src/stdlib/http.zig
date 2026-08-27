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
//! 'headers dict, 'body value}` leaks no backend detail.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const kernel_storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
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
        .name = "get-bytes",
        .doc = "( url headers -- response ) Fetch a url like get, returning " ++
            "the response body as an exact list of byte integers.",
        .primitive = getBytes,
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
    return begin(evaluator, .GET, .text);
}

fn getBytes(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .GET, .bytes);
}

fn post(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .POST, .text);
}

const ResponseMode = enum { text, bytes };

fn begin(evaluator: *Machine, method: std.http.Method, response_mode: ResponseMode) MachineError!void {
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
    const url_encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), url.borrow());
    try evaluator.startDriver(RequestDriver{
        .allocator = evaluator.allocator(),
        .method = method,
        .response_mode = response_mode,
        .tls_trust = evaluator.unit.inherited.tls_trust,
        .url_value = .init(url.take()),
        .headers_value = .init(headers.take()),
        .body_value = if (body) |*owned| .init(owned.take()) else null,
        .state = .{ .url = url_encoder },
    });
}

/// One owned name/value pair of bytes, on either side of the exchange.
const Field = struct {
    name: []u8,
    value: []u8,
};

const RequestDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    method: std.http.Method,
    response_mode: ResponseMode,
    tls_trust: ?machine.TlsTrust,
    url_value: heap.Owned(Value),
    headers_value: heap.Owned(Value),
    body_value: ?heap.Owned(Value),
    state: State,

    const RequestData = struct {
        url: []u8,
        body: ?[]u8 = null,
        fields: std.ArrayList(Field) = .empty,
    };
    const ExchangeData = struct {
        request: RequestData,
        status: u16 = 0,
        fields: std.ArrayList(Field) = .empty,
        body: std.ArrayList(u8) = .empty,
    };
    const HeaderBuild = struct {
        exchange: ExchangeData,
        pairs: std.ArrayList(dict.Pair) = .empty,
        index: usize = 0,
    };
    const Results = struct {
        exchange: ExchangeData,
        headers: Value,
        body: Value,
    };
    const FinishKeys = struct {
        status: u32,
        headers: u32,
        body: u32,
    };
    const State = union(enum) {
        url: kernel_storage.StringEncoder,
        request_headers: struct { request: RequestData, index: usize = 0 },
        request_header_name: struct {
            request: RequestData,
            index: usize,
            encoder: kernel_storage.StringEncoder,
        },
        request_header_value: struct {
            request: RequestData,
            index: usize,
            name: []u8,
            encoder: kernel_storage.StringEncoder,
        },
        request_header_append: struct {
            request: RequestData,
            index: usize,
            name: []u8,
            value: []u8,
        },
        request_body: struct {
            request: RequestData,
            encoder: kernel_storage.StringEncoder,
        },
        exchange: ExchangeData,
        response_headers: HeaderBuild,
        response_header_name: struct {
            build: HeaderBuild,
            text: kernel_storage.TextMaterializer,
        },
        response_header_value: struct {
            build: HeaderBuild,
            key: Value,
            text: kernel_storage.TextMaterializer,
        },
        response_header_append: struct {
            build: HeaderBuild,
            key: Value,
            value: Value,
        },
        headers_dictionary_prepare: HeaderBuild,
        headers_dictionary: struct {
            build: HeaderBuild,
            dictionary: kernel_storage.DictMaterializer,
        },
        release_header_pairs: struct { build: HeaderBuild, headers: Value },
        response_body_text: struct {
            exchange: ExchangeData,
            headers: Value,
            text: kernel_storage.TextMaterializer,
        },
        response_body_bytes: struct {
            exchange: ExchangeData,
            headers: Value,
            bytes: list.ByteListMaterializer,
        },
        finish_status: Results,
        finish_headers: struct { results: Results, status_key: u32 },
        finish_body: struct { results: Results, status_key: u32, headers_key: u32 },
        finish_allocate: struct { results: Results, keys: FinishKeys },
        finish_dictionary_prepare: struct {
            results: Results,
            slots: []dict.Pair,
        },
        finish_dictionary: struct {
            results: Results,
            slots: []dict.Pair,
            dictionary: kernel_storage.DictMaterializer,
        },
        output: Results,
        cleanup_pairs: HeaderBuild,
        cleanup_headers: struct { exchange: ExchangeData, headers: Value },
        cleanup_results_headers: Results,
        cleanup_results_body: struct { exchange: ExchangeData, body: Value },
        cleanup_exchange: ExchangeData,
        cleanup_request: RequestData,
        cleanup_url_value,
        cleanup_headers_value,
        cleanup_body_value,
        cleanup_destroy,
    };

    pub fn advance(evaluator: *Machine, self: *RequestDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.state) {
            .url => |*encoder| switch (try advanceEncoder(evaluator, encoder)) {
                .pending => {},
                .complete => |bytes| {
                    encoder.deinit();
                    self.state = .{ .request_headers = .{
                        .request = .{ .url = bytes },
                    } };
                },
            },
            .request_headers => |*headers| {
                const header_dict = self.headers_value.borrow().dict;
                const count: usize = @intCast(dict.keysOf(header_dict).list.length());
                if (headers.index == count) {
                    const request = headers.request;
                    if (self.body_value) |*body| self.state = .{ .request_body = .{
                        .request = request,
                        .encoder = .init(self.allocator, body.borrow()),
                    } } else self.state = .{ .exchange = .{ .request = request } };
                } else {
                    const key = dict.keyAt(header_dict, headers.index);
                    if (!key.isString())
                        return evaluator.typeError("request header names to be strings");
                    const request = headers.request;
                    const index = headers.index;
                    self.state = .{ .request_header_name = .{
                        .request = request,
                        .index = index,
                        .encoder = .init(self.allocator, key),
                    } };
                }
            },
            .request_header_name => |*header| switch (try advanceEncoder(evaluator, &header.encoder)) {
                .pending => {},
                .complete => |name| {
                    const item = dict.valueAt(self.headers_value.borrow().dict, header.index);
                    if (!item.isString()) {
                        self.allocator.free(name);
                        return evaluator.typeError("request header values to be strings");
                    }
                    header.encoder.deinit();
                    const request = header.request;
                    const index = header.index;
                    self.state = .{ .request_header_value = .{
                        .request = request,
                        .index = index,
                        .name = name,
                        .encoder = .init(self.allocator, item),
                    } };
                },
            },
            .request_header_value => |*header| switch (try advanceEncoder(evaluator, &header.encoder)) {
                .pending => {},
                .complete => |value_bytes| {
                    header.encoder.deinit();
                    const request = header.request;
                    const index = header.index;
                    const name = header.name;
                    self.state = .{ .request_header_append = .{
                        .request = request,
                        .index = index,
                        .name = name,
                        .value = value_bytes,
                    } };
                },
            },
            .request_header_append => |*header| {
                try header.request.fields.append(self.allocator, .{
                    .name = header.name,
                    .value = header.value,
                });
                const request = header.request;
                const index = header.index + 1;
                self.state = .{ .request_headers = .{ .request = request, .index = index } };
            },
            .request_body => |*body| switch (try advanceEncoder(evaluator, &body.encoder)) {
                .pending => {},
                .complete => |bytes| {
                    body.encoder.deinit();
                    var request = body.request;
                    request.body = bytes;
                    self.state = .{ .exchange = .{ .request = request } };
                },
            },
            .exchange => |*exchange_state| {
                try self.exchange(evaluator, exchange_state);
                const exchange_data = exchange_state.*;
                self.state = .{ .response_headers = .{ .exchange = exchange_data } };
            },
            .response_headers => |*headers| {
                if (headers.index == headers.exchange.fields.items.len) {
                    const moved = headers.*;
                    self.state = .{ .headers_dictionary_prepare = moved };
                } else {
                    const moved = headers.*;
                    self.state = .{ .response_header_name = .{
                        .build = moved,
                        .text = .init(self.allocator, moved.exchange.fields.items[moved.index].name),
                    } };
                }
            },
            .response_header_name => |*header| switch (try header.text.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .complete => |key| {
                    header.text.deinit();
                    const build = header.build;
                    self.state = .{ .response_header_value = .{
                        .build = build,
                        .key = key,
                        .text = .init(self.allocator, build.exchange.fields.items[build.index].value),
                    } };
                },
            },
            .response_header_value => |*header| switch (try header.text.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .complete => |value_text| {
                    header.text.deinit();
                    const build = header.build;
                    const key = header.key;
                    self.state = .{ .response_header_append = .{
                        .build = build,
                        .key = key,
                        .value = value_text,
                    } };
                },
            },
            .response_header_append => |*header| {
                try header.build.pairs.append(self.allocator, .{ header.key, header.value });
                var build = header.build;
                build.index += 1;
                self.state = .{ .response_headers = build };
            },
            .headers_dictionary_prepare => |*headers| {
                const dictionary = try kernel_storage.DictMaterializer.init(
                    self.allocator,
                    headers.pairs.items,
                    true,
                );
                const build = headers.*;
                self.state = .{ .headers_dictionary = .{
                    .build = build,
                    .dictionary = dictionary,
                } };
            },
            .headers_dictionary => |*headers| switch (try headers.dictionary.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .duplicate_key => unreachable,
                .complete => |built| {
                    headers.dictionary.deinit();
                    const build = headers.build;
                    self.state = .{ .release_header_pairs = .{
                        .build = build,
                        .headers = built,
                    } };
                },
            },
            .release_header_pairs => |*release| {
                if (release.build.pairs.pop()) |pair| {
                    evaluator.releaseDomain().releaseValue(pair[0]);
                    evaluator.releaseDomain().releaseValue(pair[1]);
                    return .yielded;
                }
                release.build.pairs.deinit(self.allocator);
                const exchange_data = release.build.exchange;
                const built = release.headers;
                self.state = switch (self.response_mode) {
                    .text => .{ .response_body_text = .{
                        .exchange = exchange_data,
                        .headers = built,
                        .text = .init(self.allocator, exchange_data.body.items),
                    } },
                    .bytes => .{ .response_body_bytes = .{
                        .exchange = exchange_data,
                        .headers = built,
                        .bytes = .init(self.allocator, exchange_data.body.items),
                    } },
                };
            },
            .response_body_text => |*body| switch (try body.text.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .complete => |built| {
                    body.text.deinit();
                    const exchange_data = body.exchange;
                    const headers = body.headers;
                    self.state = .{ .finish_status = .{
                        .exchange = exchange_data,
                        .headers = headers,
                        .body = built,
                    } };
                },
            },
            .response_body_bytes => |*body| switch (try body.bytes.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .complete => |built| {
                    body.bytes.deinit();
                    const exchange_data = body.exchange;
                    const headers = body.headers;
                    self.state = .{ .finish_status = .{
                        .exchange = exchange_data,
                        .headers = headers,
                        .body = built,
                    } };
                },
            },
            .finish_status => |*results| {
                const status_key = try intern.intern("status");
                const moved = results.*;
                self.state = .{ .finish_headers = .{ .results = moved, .status_key = status_key } };
            },
            .finish_headers => |*finish| {
                const headers_key = try intern.intern("headers");
                const results = finish.results;
                const status_key = finish.status_key;
                self.state = .{ .finish_body = .{
                    .results = results,
                    .status_key = status_key,
                    .headers_key = headers_key,
                } };
            },
            .finish_body => |*finish| {
                const body_key = try intern.intern("body");
                const results = finish.results;
                self.state = .{ .finish_allocate = .{
                    .results = results,
                    .keys = .{
                        .status = finish.status_key,
                        .headers = finish.headers_key,
                        .body = body_key,
                    },
                } };
            },
            .finish_allocate => |*finish| {
                const slots = try self.allocator.alloc(dict.Pair, 3);
                slots[0] = .{
                    .{ .symbol = finish.keys.status },
                    .{ .int = @intCast(finish.results.exchange.status) },
                };
                slots[1] = .{ .{ .symbol = finish.keys.headers }, finish.results.headers };
                slots[2] = .{ .{ .symbol = finish.keys.body }, finish.results.body };
                const results = finish.results;
                self.state = .{ .finish_dictionary_prepare = .{
                    .results = results,
                    .slots = slots,
                } };
            },
            .finish_dictionary_prepare => |*finish| {
                const dictionary = try kernel_storage.DictMaterializer.init(
                    self.allocator,
                    finish.slots,
                    true,
                );
                const results = finish.results;
                const slots = finish.slots;
                self.state = .{ .finish_dictionary = .{
                    .results = results,
                    .slots = slots,
                    .dictionary = dictionary,
                } };
            },
            .finish_dictionary => |*finish| switch (try finish.dictionary.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .duplicate_key => return evaluator.fail(.domain, "http response keys collided"),
                .complete => |built| {
                    finish.dictionary.deinit();
                    self.allocator.free(finish.slots);
                    const results = finish.results;
                    self.state = .{ .output = results };
                    return .{ .output = built };
                },
            },
            .output,
            .cleanup_pairs,
            .cleanup_headers,
            .cleanup_results_headers,
            .cleanup_results_body,
            .cleanup_exchange,
            .cleanup_request,
            .cleanup_url_value,
            .cleanup_headers_value,
            .cleanup_body_value,
            .cleanup_destroy,
            => unreachable,
        }
        return .yielded;
    }

    fn advanceEncoder(
        evaluator: *Machine,
        encoder: *kernel_storage.StringEncoder,
    ) MachineError!kernel_storage.StringEncodeResult {
        return encoder.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(
                .domain,
                "a request string contains an invalid Unicode scalar",
            ),
        };
    }

    fn failIo(
        self: *RequestDriver,
        evaluator: *Machine,
        url: []const u8,
        name: []const u8,
    ) MachineError {
        const failure = evaluator.failFmt(
            .io,
            "cannot reach `{s}`: {s}",
            .{ url, name },
        );
        evaluator.addErrorPath(self.url_value.borrow());
        return failure;
    }

    /// The whole exchange in one scheduler step: this is the documented
    /// blocking exception. Response headers are copied before the body stream
    /// is initialized, because that invalidates them.
    fn exchange(
        self: *RequestDriver,
        evaluator: *Machine,
        exchange_data: *ExchangeData,
    ) MachineError!void {
        const io = evaluator.unit.inherited.host_io.?;
        const uri = std.Uri.parse(exchange_data.request.url) catch
            return self.failIo(evaluator, exchange_data.request.url, "InvalidUrl");
        const extra = try self.allocator.alloc(std.http.Header, exchange_data.request.fields.items.len);
        defer self.allocator.free(extra);
        for (exchange_data.request.fields.items, extra) |field, *header|
            header.* = .{ .name = field.name, .value = field.value };

        var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
        defer client.deinit();
        if (self.tls_trust) |trust| {
            client.now = trust.now;
            client.ca_bundle.addCertsFromFilePathAbsolute(
                self.allocator,
                io,
                trust.now,
                trust.ca_file,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.failIo(evaluator, exchange_data.request.url, @errorName(err)),
            };
        }
        const sends_body = exchange_data.request.body != null;
        var request = client.request(self.method, uri, .{
            .redirect_behavior = if (sends_body) .unhandled else @enumFromInt(3),
            .extra_headers = extra,
        }) catch |err| return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
        defer request.deinit();

        if (exchange_data.request.body) |payload| {
            request.transfer_encoding = .{ .content_length = payload.len };
            var body = request.sendBodyUnflushed(&.{}) catch |err|
                return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
            body.writer.writeAll(payload) catch |err|
                return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
            body.end() catch |err| return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
            request.connection.?.flush() catch |err|
                return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
        } else request.sendBodiless() catch |err|
            return self.failIo(evaluator, exchange_data.request.url, @errorName(err));

        const redirect_buffer = try self.allocator.alloc(u8, redirect_buffer_bytes);
        defer self.allocator.free(redirect_buffer);
        var response = request.receiveHead(redirect_buffer) catch |err|
            return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
        exchange_data.status = @intFromEnum(response.head.status);

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
            for (exchange_data.fields.items) |*field| {
                if (std.ascii.eqlIgnoreCase(field.name, name)) {
                    self.allocator.free(field.name);
                    self.allocator.free(field.value);
                    field.* = .{ .name = name, .value = item };
                    break;
                }
            } else try exchange_data.fields.append(
                self.allocator,
                .{ .name = name, .value = item },
            );
        }

        const decompress_bytes: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            .deflate, .gzip => std.compress.flate.max_window_len,
            .compress => return self.failIo(
                evaluator,
                exchange_data.request.url,
                "UnsupportedCompressionMethod",
            ),
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
            return self.failIo(evaluator, exchange_data.request.url, "ReadFailed");
        exchange_data.body.deinit(self.allocator);
        exchange_data.body = .empty;
        try exchange_data.body.appendSlice(self.allocator, collected.written());
    }

    fn beginRetirement(self: *RequestDriver, releases: *heap.ReleaseDomain) void {
        switch (self.state) {
            .url => |*encoder| {
                encoder.deinit();
                self.state = .cleanup_url_value;
            },
            .request_headers => |*headers| {
                const request = headers.request;
                self.state = .{ .cleanup_request = request };
            },
            .request_header_name => |*header| {
                header.encoder.deinit();
                const request = header.request;
                self.state = .{ .cleanup_request = request };
            },
            .request_header_value => |*header| {
                header.encoder.deinit();
                self.allocator.free(header.name);
                const request = header.request;
                self.state = .{ .cleanup_request = request };
            },
            .request_header_append => |*header| {
                self.allocator.free(header.value);
                self.allocator.free(header.name);
                const request = header.request;
                self.state = .{ .cleanup_request = request };
            },
            .request_body => |*body| {
                body.encoder.deinit();
                const request = body.request;
                self.state = .{ .cleanup_request = request };
            },
            .exchange => |*exchange_data| {
                const moved = exchange_data.*;
                self.state = .{ .cleanup_exchange = moved };
            },
            .response_headers => |*headers| self.beginHeaderCleanup(headers),
            .response_header_name => |*header| {
                header.text.retire(releases);
                self.beginHeaderCleanup(&header.build);
            },
            .response_header_value => |*header| {
                header.text.retire(releases);
                releases.releaseValue(header.key);
                self.beginHeaderCleanup(&header.build);
            },
            .response_header_append => |*header| {
                releases.releaseValue(header.key);
                releases.releaseValue(header.value);
                self.beginHeaderCleanup(&header.build);
            },
            .headers_dictionary_prepare => |*headers| self.beginHeaderCleanup(headers),
            .headers_dictionary => |*headers| {
                headers.dictionary.retire(releases);
                self.beginHeaderCleanup(&headers.build);
            },
            .release_header_pairs => |*release| {
                releases.releaseValue(release.headers);
                self.beginHeaderCleanup(&release.build);
            },
            .response_body_text => |*body| {
                body.text.retire(releases);
                const exchange_data = body.exchange;
                const headers = body.headers;
                self.state = .{ .cleanup_headers = .{
                    .exchange = exchange_data,
                    .headers = headers,
                } };
            },
            .response_body_bytes => |*body| {
                body.bytes.retire(releases);
                const exchange_data = body.exchange;
                const headers = body.headers;
                self.state = .{ .cleanup_headers = .{
                    .exchange = exchange_data,
                    .headers = headers,
                } };
            },
            .finish_status => |*results| self.beginResultsCleanup(results),
            .finish_headers => |*finish| self.beginResultsCleanup(&finish.results),
            .finish_body => |*finish| self.beginResultsCleanup(&finish.results),
            .finish_allocate => |*finish| self.beginResultsCleanup(&finish.results),
            .finish_dictionary_prepare => |*finish| {
                self.allocator.free(finish.slots);
                self.beginResultsCleanup(&finish.results);
            },
            .finish_dictionary => |*finish| {
                finish.dictionary.retire(releases);
                self.allocator.free(finish.slots);
                self.beginResultsCleanup(&finish.results);
            },
            .output => |*results| self.beginResultsCleanup(results),
            .cleanup_pairs,
            .cleanup_headers,
            .cleanup_results_headers,
            .cleanup_results_body,
            .cleanup_exchange,
            .cleanup_request,
            .cleanup_url_value,
            .cleanup_headers_value,
            .cleanup_body_value,
            .cleanup_destroy,
            => unreachable,
        }
    }

    fn beginHeaderCleanup(self: *RequestDriver, build: *HeaderBuild) void {
        const moved = build.*;
        self.state = .{ .cleanup_pairs = moved };
    }

    fn beginResultsCleanup(self: *RequestDriver, results: *Results) void {
        const moved = results.*;
        self.state = .{ .cleanup_results_headers = moved };
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
        self: *RequestDriver,
    ) bool {
        return switch (self.state) {
            .url,
            .request_headers,
            .request_header_name,
            .request_header_value,
            .request_header_append,
            .request_body,
            .exchange,
            .response_headers,
            .response_header_name,
            .response_header_value,
            .response_header_append,
            .headers_dictionary_prepare,
            .headers_dictionary,
            .release_header_pairs,
            .response_body_text,
            .response_body_bytes,
            .finish_status,
            .finish_headers,
            .finish_body,
            .finish_allocate,
            .finish_dictionary_prepare,
            .finish_dictionary,
            .output,
            => result: {
                self.beginRetirement(releases);
                break :result false;
            },
            .cleanup_pairs => |*cleanup| result: {
                if (cleanup.pairs.pop()) |pair| {
                    releases.releaseValue(pair[0]);
                    releases.releaseValue(pair[1]);
                    break :result false;
                }
                cleanup.pairs.deinit(self.allocator);
                const exchange_data = cleanup.exchange;
                self.state = .{ .cleanup_exchange = exchange_data };
                break :result false;
            },
            .cleanup_headers => |*cleanup| result: {
                releases.releaseValue(cleanup.headers);
                const exchange_data = cleanup.exchange;
                self.state = .{ .cleanup_exchange = exchange_data };
                break :result false;
            },
            .cleanup_results_headers => |*cleanup| result: {
                releases.releaseValue(cleanup.headers);
                const exchange_data = cleanup.exchange;
                const body = cleanup.body;
                self.state = .{ .cleanup_results_body = .{
                    .exchange = exchange_data,
                    .body = body,
                } };
                break :result false;
            },
            .cleanup_results_body => |*cleanup| result: {
                releases.releaseValue(cleanup.body);
                const exchange_data = cleanup.exchange;
                self.state = .{ .cleanup_exchange = exchange_data };
                break :result false;
            },
            .cleanup_exchange => |*cleanup| result: {
                if (cleanup.fields.pop()) |field| {
                    self.allocator.free(field.name);
                    self.allocator.free(field.value);
                    break :result false;
                }
                cleanup.fields.deinit(self.allocator);
                cleanup.body.deinit(self.allocator);
                const request = cleanup.request;
                self.state = .{ .cleanup_request = request };
                break :result false;
            },
            .cleanup_request => |*cleanup| result: {
                if (cleanup.fields.pop()) |field| {
                    self.allocator.free(field.name);
                    self.allocator.free(field.value);
                    break :result false;
                }
                cleanup.fields.deinit(self.allocator);
                if (cleanup.body) |body| self.allocator.free(body);
                self.allocator.free(cleanup.url);
                self.state = .cleanup_url_value;
                break :result false;
            },
            .cleanup_url_value => result: {
                self.url_value.deinit(releases, storage_allocator);
                self.state = .cleanup_headers_value;
                break :result false;
            },
            .cleanup_headers_value => result: {
                self.headers_value.deinit(releases, storage_allocator);
                self.state = .cleanup_body_value;
                break :result false;
            },
            .cleanup_body_value => result: {
                if (self.body_value) |*owned| owned.deinit(releases, storage_allocator);
                self.body_value = null;
                self.state = .cleanup_destroy;
                break :result false;
            },
            .cleanup_destroy => {
                storage_allocator.destroy(self);
                return true;
            },
        };
    }
};
