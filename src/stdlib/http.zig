//! The internal `http` module: a client over `std.http.Client`.
//!
//! This is a builtin-backed module because TLS and sockets are host authority
//! no ECL program can express and the native SDK deliberately withholds — an
//! external module gets no allocator, no network, and no state that outlives a
//! yield. It is not exposed as an SDK capability.
//!
//! Exchanges run under Session-owned controller execution while this driver
//! prepares and materializes values in bounded scheduler steps.
const std = @import("std");
const service = @import("../http_service.zig");
const scheduler = @import("../scheduler.zig");
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
            "'path. Requests yield to other tasks and have a total 30-second deadline ('timeout). " ++
            "Finite Session transfer and admission limits fail with 'overflow; no partial response is returned.",
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
    const access = evaluator.unit.inherited.runtime().http_access;
    const deadline = worker(evaluator).deadlineAfter(access.limits().deadline_ms) catch
        return evaluator.fail(.overflow, "HTTP deadline lies beyond the clock's range");
    var request = try evaluator.popValue();
    errdefer request.deinit();
    const fields = try requestFields(evaluator, request.borrow());
    if (fields.method) |requested_method| if (requested_method.list.length() > 7)
        return evaluator.fail(.domain, "unsupported HTTP request method");
    const method = defaults.method orelse required_method: {
        if (fields.method == null)
            return evaluator.typeError("a request with a string 'method");
        // The request driver parses and replaces this placeholder before it
        // opens the URL. Requiring the field here keeps a missing method from
        // silently acquiring a transport-level default.
        break :required_method .GET;
    };
    _ = fields.target orelse return evaluator.typeError("a request with a string 'target URL");
    const admitted = access.admit() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => {
            const failure = evaluator.fail(.overflow, "HTTP request capacity exhausted");
            evaluator.addErrorPath(fields.target.?);
            return failure;
        },
    };
    errdefer _ = admitted.retire();
    try evaluator.startDriver(RequestDriver{
        .admitted = admitted,
        .limits = access.limits(),
        .deadline = deadline,
        .allocator = evaluator.allocator(),
        .method = method,
        .follow_redirects = defaults.follow_redirects,
        .response_mode = response_mode,
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

const RequestDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    method: std.http.Method,
    follow_redirects: bool,
    response_mode: ResponseMode,
    admitted: *service.Request,
    limits: service.Limits,
    deadline: scheduler.Deadline,
    request_header_bytes: usize = 0,
    chunks: Chunks = .{},
    request_value: heap.Owned(Value),
    fields: RequestFields,
    state: State,

    const RequestData = service.Input;
    const ExchangeData = service.Response;
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
            index: usize = 0,
        },
        exchange: ExchangeData,
        running,
        body_allocate: ExchangeData,
        body_flatten: struct { exchange: ExchangeData, offset: usize = 0 },
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
        finish_response: Results,
        finish_dictionary: struct {
            results: Results,
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
        if (self.deadline.reachedBy(worker(evaluator).now())) {
            self.admitted.cancel();
            const failure = evaluator.fail(.timeout, "HTTP request deadline expired");
            evaluator.addErrorPath(self.fields.target.?);
            return failure;
        }
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
            .method => |*encoder| switch (try self.advanceEncoder(evaluator, encoder)) {
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
            .url => |*encoder| switch (try self.advanceEncoder(evaluator, encoder)) {
                .pending => {},
                .complete => |bytes| {
                    encoder.deinit();
                    self.state = .{ .request_headers = .{
                        .request = .{ .url = bytes },
                    } };
                },
            },
            .request_headers => |*headers| {
                if (headers.request.fields.capacity == 0)
                    try headers.request.fields.ensureTotalCapacityPrecise(self.allocator, self.limits.header_fields);
                const header_value = self.fields.headers orelse {
                    const request = headers.request;
                    try self.beginBody(evaluator, request);
                    return .yielded;
                };
                const header_dict = header_value.dict;
                const count: usize = @intCast(dict.keysOf(header_dict).list.length());
                if (headers.index == count) {
                    const request = headers.request;
                    try self.beginBody(evaluator, request);
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
                    if (@as(usize, @intCast(values.list.length())) > self.limits.header_fields - headers.request.fields.items.len)
                        return self.overflow(evaluator);
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
            .request_header_name => |*header| switch (try self.advanceEncoder(evaluator, &header.encoder)) {
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
            .request_header_value => |*header| switch (try self.advanceEncoder(evaluator, &header.encoder)) {
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
                const count = header.name.len + header.value.len + 4;
                if (count > self.limits.header_bytes - self.request_header_bytes) return self.overflow(evaluator);
                self.request_header_bytes += count;
                header.request.fields.appendAssumeCapacity(.{
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
            .request_body => |*body| {
                const output = body.request.body.?;
                const end = @min(output.len, body.index + machine.kernel_poll_quantum);
                while (body.index < end) : (body.index += 1) {
                    const item = list.atUnchecked(self.fields.body.?, body.index);
                    if (item != .int or item.int < 0 or item.int > 255)
                        return evaluator.typeError("request 'body values to be integers from 0 through 255");
                    output[body.index] = @intCast(item.int);
                }
                if (body.index == output.len) {
                    const request = body.request;
                    self.state = .{ .exchange = .{ .request = request } };
                }
            },
            .exchange => |*exchange_state| {
                const input = exchange_state.request;
                self.state = .running;
                self.admitted.start(input, self.method, self.follow_redirects, @ptrCast(@alignCast(evaluator.unit.task_scope.?))) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.ScopeClosing => evaluator.fail(.cancelled, "HTTP scope is closing"),
                    else => self.failIo(evaluator, input.url, @errorName(err)),
                };
            },
            .running => {
                // Drain before waiting for completion: a full pipe is host
                // backpressure, never a reason to wait for the producer to join.
                const chunk = try self.chunks.writable(self.allocator);
                switch (self.admitted.pipe().read(chunk.bytes[chunk.len..])) {
                    .data => |count| {
                        chunk.len += count;
                        self.chunks.len += count;
                    },
                    .failed => |failure| return self.failResult(evaluator, failure),
                    .pending => try evaluator.park(.{ .external_until = .{
                        .source = self.admitted.pipe().readSource(),
                        .deadline = self.deadline,
                    } }),
                    .eof => switch (self.admitted.result()) {
                        .pending => try evaluator.park(.{ .external_until = .{ .source = self.admitted.source(), .deadline = self.deadline } }),
                        .failed => |failure| return self.failResult(evaluator, failure),
                        .complete => {
                            const response = self.admitted.take();
                            self.state = .{ .body_allocate = response };
                        },
                    },
                }
            },
            .body_allocate => |*exchange_data| {
                const bytes = try self.allocator.alloc(u8, self.chunks.len);
                exchange_data.body = .{ .items = bytes, .capacity = bytes.len };
                const exchange = exchange_data.*;
                self.state = .{ .body_flatten = .{ .exchange = exchange } };
            },
            .body_flatten => |*flatten| {
                if (self.chunks.first) |chunk| {
                    @memcpy(flatten.exchange.body.items[flatten.offset..][0..chunk.len], chunk.bytes[0..chunk.len]);
                    flatten.offset += chunk.len;
                    self.chunks.pop(self.allocator);
                } else {
                    const exchange = flatten.exchange;
                    self.state = .{ .response_headers = .{ .exchange = exchange } };
                }
            },
            .response_headers => |*headers| {
                if (headers.pairs.capacity == 0)
                    try headers.pairs.ensureTotalCapacityPrecise(self.allocator, headers.exchange.fields.items.len);
                if (headers.index == headers.exchange.fields.items.len) {
                    const moved = headers.*;
                    self.state = .{ .headers_dictionary_prepare = moved };
                } else {
                    const fields = headers.exchange.fields.items;
                    // The total encoded header budget bounds this comparison
                    // pass even when every occurrence repeats the same name.
                    for (fields[headers.index + 1 ..]) |later| {
                        if (std.ascii.eqlIgnoreCase(fields[headers.index].name, later.name)) {
                            headers.index += 1;
                            return .yielded;
                        }
                    }
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
                header.build.pairs.appendAssumeCapacity(.{ header.key, header.value });
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
                    self.state = .{ .finish_response = .{
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
                    self.state = .{ .finish_response = .{
                        .exchange = exchange_data,
                        .headers = headers,
                        .body = built,
                    } };
                },
            },
            .finish_response => |*results| {
                const status_key = try intern.intern("status");
                const headers_key = try intern.intern("headers");
                const body_key = try intern.intern("body");
                const slots = [_]dict.Pair{
                    .{ .{ .symbol = status_key }, .{ .int = @intCast(results.exchange.status) } },
                    .{ .{ .symbol = headers_key }, results.headers },
                    .{ .{ .symbol = body_key }, results.body },
                };
                const dictionary = try dict.Materializer.init(self.allocator, &slots, true);
                const moved = results.*;
                self.state = .{ .finish_dictionary = .{
                    .results = moved,
                    .dictionary = dictionary,
                } };
            },
            .finish_dictionary => |*finish| switch (try finish.dictionary.advance(machine.kernel_poll_quantum)) {
                .pending => {},
                .duplicate_key => return evaluator.fail(.domain, "http response keys collided"),
                .complete => |built| {
                    finish.dictionary.deinit();
                    const results = finish.results;
                    self.state = .{ .output = results };
                    if (self.deadline.reachedBy(worker(evaluator).now())) {
                        evaluator.releaseDomain().releaseValue(built);
                        return evaluator.fail(.timeout, "HTTP request deadline expired");
                    }
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

    fn beginBody(self: *RequestDriver, evaluator: *Machine, input: RequestData) MachineError!void {
        var request = input;
        if (self.fields.body) |body| {
            const count: usize = @intCast(body.list.length());
            if (count > self.limits.outbound_bytes) return self.overflow(evaluator);
            if (count != 0 and !self.method.requestHasBody())
                return evaluator.fail(.domain, "HTTP request method does not admit a body");
            request.body = try self.allocator.alloc(u8, count);
            self.state = .{ .request_body = .{ .request = request } };
        } else self.state = .{ .exchange = .{ .request = request } };
    }

    fn overflow(self: *RequestDriver, evaluator: *Machine) MachineError {
        const failure = evaluator.fail(.overflow, "HTTP transfer limit exceeded");
        evaluator.addErrorPath(self.fields.target.?);
        return failure;
    }

    fn failResult(self: *RequestDriver, evaluator: *Machine, failure: service.Failure) MachineError {
        return switch (failure) {
            .out_of_memory => error.OutOfMemory,
            .report => |report| blk: {
                if (report.kind == .io) break :blk self.failIo(evaluator, self.admitted.target(), report.message[0..report.len]);
                const result = evaluator.fail(report.kind, report.message[0..report.len]);
                evaluator.addErrorPath(self.fields.target.?);
                break :blk result;
            },
        };
    }

    fn advanceEncoder(
        self: *RequestDriver,
        evaluator: *Machine,
        encoder: *kernel_storage.StringEncoder,
    ) MachineError!kernel_storage.StringEncodeResult {
        const limit = switch (self.state) {
            .method => 28,
            .url => self.limits.target_bytes,
            else => self.limits.header_bytes - self.request_header_bytes,
        };
        return encoder.advanceLimited(machine.kernel_poll_quantum, limit) catch |err| switch (err) {
            error.Overflow => return self.overflow(evaluator),
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
                const request = body.request;
                self.state = .{ .cleanup_request = request };
            },
            .running => self.state = .cleanup_request_value,
            .body_flatten => |*flatten| {
                const exchange = flatten.exchange;
                self.state = .{ .cleanup_exchange = exchange };
            },
            .exchange, .body_allocate => |*exchange_data| {
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
            .finish_response => |*results| self.beginResultsCleanup(results),
            .finish_dictionary => |*finish| {
                finish.dictionary.retire(releases);
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
        self.admitted.cancel();
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
            .running,
            .body_allocate,
            .body_flatten,
            .response_headers,
            .response_header_name,
            .response_header_value,
            .response_header_append,
            .headers_dictionary_prepare,
            .headers_dictionary,
            .release_header_pairs,
            .response_body_text,
            .response_body_bytes,
            .finish_response,
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
                if (!cleanup.retire(self.allocator)) break :result false;
                self.state = .cleanup_request_value;
                break :result false;
            },
            .cleanup_request => |*cleanup| result: {
                if (!cleanup.retire(self.allocator)) break :result false;
                self.state = .cleanup_request_value;
                break :result false;
            },
            .cleanup_request_value => result: {
                self.request_value.deinit(releases, storage_allocator);
                self.state = .cleanup_destroy;
                break :result false;
            },
            .cleanup_destroy => {
                if (self.chunks.first != null) {
                    self.chunks.pop(self.allocator);
                    return false;
                }
                if (!self.admitted.retire()) return false;
                storage_allocator.destroy(self);
                return true;
            },
        };
    }
};

/// Unknown-length bodies retain fixed chunks until one exact-size, polled
/// materialization. Each removal is one bounded retirement step.
const Chunks = struct {
    const Chunk = struct { next: ?*Chunk = null, len: usize = 0, bytes: [16 * 1024]u8 };
    first: ?*Chunk = null,
    last: ?*Chunk = null,
    len: usize = 0,
    fn writable(self: *Chunks, allocator: std.mem.Allocator) !*Chunk {
        if (self.last) |last| if (last.len < last.bytes.len) return last;
        const chunk = try allocator.create(Chunk);
        // SAFETY: readers see only bytes below len, initialized by pipe.read.
        chunk.* = .{ .bytes = undefined };
        if (self.last) |last| last.next = chunk else self.first = chunk;
        self.last = chunk;
        return chunk;
    }
    fn pop(self: *Chunks, allocator: std.mem.Allocator) void {
        const chunk = self.first.?;
        self.first = chunk.next;
        if (self.first == null) self.last = null;
        allocator.destroy(chunk);
    }
};

fn worker(evaluator: *Machine) *const scheduler.WorkerScheduler {
    return @ptrCast(@alignCast(evaluator.unit.scheduler.?));
}
