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
    // these words hand their work to a scheduler driver, and a declared effect
    // is checked the instant the primitive returns.
    .{
        .name = "get",
        .doc = "( request -- response ) Fetch a partial or complete http.request with GET defaults, following " ++
            "redirects for bodyless requests, and return " ++
            "{'status int 'headers dict 'body string}.\n\n" ++
            "request is a dictionary under the http.request contract and must carry a string 'target URL. Its " ++
            "optional 'method overrides GET; optional 'headers maps lowercased string names to lists of string " ++
            "values, each sent in order; and optional 'body is an exact byte list for POST, PUT, or PATCH. A " ++
            "nonempty body with another method is 'domain. Other request fields are " ++
            "validated but do not affect the outbound exchange. A malformed request is 'type, and an unsupported " ++
            "method is 'domain. In the response, 'headers maps each header name the server " ++
            "sent to its value, keeping the last value of a repeated header, and 'body is the decoded text. A " ++
            "non-2xx status is an ordinary response, not an error.\n\n" ++
            "A transport or protocol failure, and a Session without network access, is 'io carrying the url in " ++
            "'path. The request occupies the calling unit's worker until it completes; there is no deadline.",
        .primitive = get,
    },
    .{
        .name = "get-bytes",
        .doc = "( request -- response ) Fetch a request exactly as get does, but return 'body as the exact response " ++
            "octets in a byte list of ints in 0...255 instead of decoded text.\n\n" ++
            "Arguments, redirects, response headers, and failures are those of get. Use this for archives and other " ++
            "binary content, and chars to decode a body known to be UTF-8.",
        .primitive = getBytes,
    },
    .{
        .name = "post",
        .doc = "( request -- response ) Fetch a partial or complete http.request with POST defaults and " ++
            "return {'status int 'headers dict 'body string}.\n\n" ++
            "request has the same contract as for get. Its optional 'method overrides POST, and POST supplies an " ++
            "empty request body when 'body is absent. Redirects are not followed: a 3xx status is returned as an " ++
            "ordinary response. Response headers, body decoding, validation, and 'io failures are those of get.",
        .primitive = post,
    },
    .{
        .name = "send",
        .doc = "( request -- response ) Send a complete http.request and return " ++
            "{'status int 'headers dict 'body string}.\n\n" ++
            "Unlike get and post, send supplies no method default: request must carry string 'method and 'target " ++
            "fields. Headers, body bytes, response decoding, validation, and 'io failures are those of get. " ++
            "Redirects are not followed, so send preserves the request method across exactly one exchange.",
        .primitive = send,
    },
};

/// Response bodies are bounded by ordinary allocation in v1.
const redirect_buffer_bytes: usize = 8 * 1024;

fn get(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .{ .method = .GET, .follow_redirects = true }, .text);
}

fn getBytes(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .{ .method = .GET, .follow_redirects = true }, .bytes);
}

fn post(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .{ .method = .POST }, .text);
}

fn send(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .{}, .text);
}

const ResponseMode = enum { text, bytes };

const RequestDefaults = struct {
    method: ?std.http.Method = null,
    follow_redirects: bool = false,
};

const RequestFields = struct {
    method: ?Value = null,
    target: ?Value = null,
    headers: ?Value = null,
    body: ?Value = null,
    params: ?Value = null,
};

fn begin(evaluator: *Machine, defaults: RequestDefaults, response_mode: ResponseMode) MachineError!void {
    var request = try evaluator.popValue();
    errdefer request.deinit();
    const fields = try requestFields(evaluator, request.borrow());
    const method = defaults.method orelse required_method: {
        if (fields.method == null)
            return evaluator.typeError("a request with a string 'method");
        // The request driver parses and replaces this placeholder before it
        // opens the URL. Requiring the field here keeps a missing method from
        // silently acquiring a transport-level default.
        break :required_method .GET;
    };
    const target = fields.target orelse return evaluator.typeError("a request with a string 'target URL");
    if (evaluator.unit.inherited.host_io == null) {
        const failure = evaluator.fail(.io, "network access is unavailable");
        evaluator.addErrorPath(target);
        return failure;
    }
    try evaluator.startDriver(RequestDriver{
        .allocator = evaluator.allocator(),
        .method = method,
        .follow_redirects = defaults.follow_redirects,
        .response_mode = response_mode,
        .tls_trust = evaluator.unit.inherited.tls_trust,
        .request_value = .init(request.take()),
        .fields = fields,
        .state = .start,
    });
}

fn requestFields(evaluator: *Machine, request: Value) MachineError!RequestFields {
    if (request != .dict) return evaluator.typeError("a request dict");
    if (request.dict.length() > 8)
        return evaluator.typeError("a request dict with only recognized fields");
    var fields: RequestFields = .{};
    for (0..@as(usize, @intCast(request.dict.length()))) |index| {
        const key = dict.keyAt(request.dict, index);
        if (key != .symbol) return evaluator.typeError("symbol request field names");
        const item = dict.valueAt(request.dict, index);
        const name = intern.get(key.symbol);
        if (std.mem.eql(u8, name, "method")) {
            if (!item.isString()) return evaluator.typeError("a string request 'method");
            fields.method = item;
        } else if (std.mem.eql(u8, name, "target")) {
            if (!item.isString()) return evaluator.typeError("a string request 'target");
            fields.target = item;
        } else if (std.mem.eql(u8, name, "path") or
            std.mem.eql(u8, name, "query") or
            std.mem.eql(u8, name, "peer"))
        {
            if (!item.isString()) return evaluator.typeError("string request 'path, 'query, and 'peer fields");
        } else if (std.mem.eql(u8, name, "headers")) {
            if (item != .dict) return evaluator.typeError("a request 'headers dict");
            fields.headers = item;
        } else if (std.mem.eql(u8, name, "body")) {
            if (item != .list or item.isString()) return evaluator.typeError("a request 'body byte list");
            fields.body = item;
        } else if (std.mem.eql(u8, name, "params")) {
            if (item != .dict) return evaluator.typeError("a request 'params dict");
            fields.params = item;
        } else return evaluator.typeError("a request dict with only recognized fields");
    }
    return fields;
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
    follow_redirects: bool,
    response_mode: ResponseMode,
    tls_trust: ?machine.TlsTrust,
    request_value: heap.Owned(Value),
    fields: RequestFields,
    state: State,

    const RequestData = struct {
        url: []u8,
        body: ?kernel_storage.ByteVector = null,
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
        start,
        params: usize,
        method: kernel_storage.StringEncoder,
        url: kernel_storage.StringEncoder,
        request_headers: struct { request: RequestData, index: usize = 0 },
        request_header_name: struct {
            request: RequestData,
            index: usize,
            value_index: usize,
            encoder: kernel_storage.StringEncoder,
        },
        request_header_value: struct {
            request: RequestData,
            index: usize,
            value_index: usize,
            name: []u8,
            encoder: kernel_storage.StringEncoder,
        },
        request_header_append: struct {
            request: RequestData,
            index: usize,
            value_index: usize,
            name: []u8,
            value: []u8,
        },
        request_body: struct {
            request: RequestData,
            encoder: kernel_storage.ByteVectorEncoder,
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
            dictionary: dict.Materializer,
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
            dictionary: dict.Materializer,
        },
        output: Results,
        cleanup_pairs: HeaderBuild,
        cleanup_headers: struct { exchange: ExchangeData, headers: Value },
        cleanup_results_headers: Results,
        cleanup_results_body: struct { exchange: ExchangeData, body: Value },
        cleanup_exchange: ExchangeData,
        cleanup_request: RequestData,
        cleanup_request_value,
        cleanup_destroy,
    };

    pub fn advance(evaluator: *Machine, self: *RequestDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.state) {
            .start => if (self.fields.params != null) {
                self.state = .{ .params = 0 };
            } else self.beginMethod(),
            .params => |*index| {
                const params = self.fields.params.?.dict;
                const count: usize = @intCast(params.length());
                if (index.* == count) {
                    self.beginMethod();
                } else {
                    if (!dict.keyAt(params, index.*).isString() or
                        !dict.valueAt(params, index.*).isString())
                        return evaluator.typeError("request 'params string names and values");
                    index.* += 1;
                }
            },
            .method => |*encoder| switch (try advanceEncoder(evaluator, encoder)) {
                .pending => {},
                .complete => |bytes| {
                    encoder.deinit();
                    defer self.allocator.free(bytes);
                    self.method = std.meta.stringToEnum(std.http.Method, bytes) orelse {
                        self.state = .cleanup_request_value;
                        return evaluator.fail(.domain, "unsupported HTTP request method");
                    };
                    self.beginUrl();
                },
            },
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
                const header_value = self.fields.headers orelse {
                    const request = headers.request;
                    self.beginBody(request);
                    return .yielded;
                };
                const header_dict = header_value.dict;
                const count: usize = @intCast(dict.keysOf(header_dict).list.length());
                if (headers.index == count) {
                    const request = headers.request;
                    self.beginBody(request);
                } else {
                    const key = dict.keyAt(header_dict, headers.index);
                    if (!key.isString())
                        return evaluator.typeError("request header names to be strings");
                    const values = dict.valueAt(header_dict, headers.index);
                    if (values != .list)
                        return evaluator.typeError("request header values to be lists of strings");
                    if (values.list.length() == 0) {
                        headers.index += 1;
                        return .yielded;
                    }
                    const request = headers.request;
                    const index = headers.index;
                    self.state = .{ .request_header_name = .{
                        .request = request,
                        .index = index,
                        .value_index = 0,
                        .encoder = .init(self.allocator, key),
                    } };
                }
            },
            .request_header_name => |*header| switch (try advanceEncoder(evaluator, &header.encoder)) {
                .pending => {},
                .complete => |name| {
                    for (name) |char| if (std.ascii.isUpper(char)) {
                        self.allocator.free(name);
                        return evaluator.typeError("lowercased request header names");
                    };
                    const values = dict.valueAt(self.fields.headers.?.dict, header.index).list;
                    const item = list.atUnchecked(.{ .list = values }, header.value_index);
                    if (!item.isString()) {
                        self.allocator.free(name);
                        return evaluator.typeError("request header values to be lists of strings");
                    }
                    header.encoder.deinit();
                    const request = header.request;
                    const index = header.index;
                    const value_index = header.value_index;
                    self.state = .{ .request_header_value = .{
                        .request = request,
                        .index = index,
                        .value_index = value_index,
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
                    const value_index = header.value_index;
                    const name = header.name;
                    self.state = .{ .request_header_append = .{
                        .request = request,
                        .index = index,
                        .value_index = value_index,
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
                const values = dict.valueAt(self.fields.headers.?.dict, header.index).list;
                const next_value = header.value_index + 1;
                if (next_value == @as(usize, @intCast(values.length()))) {
                    self.state = .{ .request_headers = .{
                        .request = request,
                        .index = header.index + 1,
                    } };
                } else {
                    const key = dict.keyAt(self.fields.headers.?.dict, header.index);
                    self.state = .{ .request_header_name = .{
                        .request = request,
                        .index = header.index,
                        .value_index = next_value,
                        .encoder = .init(self.allocator, key),
                    } };
                }
            },
            .request_body => |*body| switch (body.encoder.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidByte => return evaluator.typeError(
                    "request 'body values to be integers from 0 through 255",
                ),
            }) {
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
                const dictionary = try dict.Materializer.init(
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
                const dictionary = try dict.Materializer.init(
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
            .cleanup_request_value,
            .cleanup_destroy,
            => unreachable,
        }
        return .yielded;
    }

    fn beginMethod(self: *RequestDriver) void {
        if (self.fields.method) |method| {
            self.state = .{ .method = .init(self.allocator, method) };
        } else self.beginUrl();
    }

    fn beginUrl(self: *RequestDriver) void {
        self.state = .{ .url = .init(self.allocator, self.fields.target.?) };
    }

    fn beginBody(self: *RequestDriver, request: RequestData) void {
        if (self.fields.body) |body| {
            self.state = .{ .request_body = .{
                .request = request,
                .encoder = .init(self.allocator, body),
            } };
        } else self.state = .{ .exchange = .{ .request = request } };
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
        evaluator.addErrorPath(self.fields.target.?);
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
        const sends_body = self.method.requestHasBody();
        if (!sends_body) if (exchange_data.request.body) |*body| {
            if (body.bytes().len != 0)
                return evaluator.fail(.domain, "HTTP request method does not admit a body");
        };
        var request = client.request(self.method, uri, .{
            .redirect_behavior = if (self.follow_redirects and !sends_body) @enumFromInt(3) else .unhandled,
            .extra_headers = extra,
        }) catch |err| return self.failIo(evaluator, exchange_data.request.url, @errorName(err));
        defer request.deinit();

        if (sends_body) {
            const payload = if (exchange_data.request.body) |*body| body.bytes() else &.{};
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
            .start, .params => self.state = .cleanup_request_value,
            .method => |*encoder| {
                encoder.deinit();
                self.state = .cleanup_request_value;
            },
            .url => |*encoder| {
                encoder.deinit();
                self.state = .cleanup_request_value;
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
            .cleanup_request_value,
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
            .start,
            .params,
            .method,
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
                if (cleanup.body) |*body| body.retire(releases, self.allocator);
                self.allocator.free(cleanup.url);
                self.state = .cleanup_request_value;
                break :result false;
            },
            .cleanup_request_value => result: {
                self.request_value.deinit(releases, storage_allocator);
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
