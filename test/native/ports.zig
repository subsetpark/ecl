const CounterMode = enum { step, receive_step, block, block_send, echo, checksum, failure, inspect, allocation_failure, noop, buffered_failure, finished_failure, pipeline, early_exit, resource_messages, resource_bytes, resource_notify, rpc, invalid_reply, reply_result, resource_compete_messages, resource_compete_bytes, datagram, watch, watch_config, transform_message, child, dependent_child, child_event, discard_child, child_pair, events, build_result, duplicate_result, oversize_event, build_received, messages, message_result, message_failure, blocked, long_failure };
const StorageMode = enum { query, transaction, durable, storage_status, detached_query, lookalike_child };
const CursorMode = enum { rows, position };
const TransactionPortMode = enum { transaction_write, commit, transaction_wait };
const BrokerMode = enum { deliver, redeliver, broker_status };
const DeliveryMode = enum { acknowledge, delivery_info };
const DeviceMode = enum { buffer, device_status };
const BufferMode = enum { compute, complete_work, buffer_update };
const MultiplexMode = enum { channel, disconnect, channel_count, fatal_allocation_failure };
// zlint-disable homeless-try -- Zig validates the SDK callback error unions.
const std = @import("std");
const ecl = @import("ecl-native");
var shutdowns: std.atomic.Value(u32) = .init(0);
var cleaned: std.atomic.Value(u32) = .init(0);
var entered: std.atomic.Value(u32) = .init(0);
var waiting: std.atomic.Value(u32) = .init(0);
var fail_open: std.atomic.Value(bool) = .init(false);
var block_open: std.atomic.Value(bool) = .init(false);
var gate_mutex: std.Io.Mutex = .init;
var gate_changed: std.Io.Condition = .init;
var permits: u32 = 0;
fn fixtureIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn awaitGate(cancelled: *std.atomic.Value(bool)) void {
    std.Io.Threaded.mutexLock(&gate_mutex);
    defer std.Io.Threaded.mutexUnlock(&gate_mutex);
    _ = entered.fetchAdd(1, .release);
    while (permits == 0 and !cancelled.load(.acquire)) gate_changed.waitUncancelable(fixtureIo(), &gate_mutex);
    if (!cancelled.load(.acquire)) permits -= 1;
}

fn Spec(comptime label: []const u8) type {
    return struct {
        pub const name = label;
        pub const State = struct { total: u8 = 0, cancelled: std.atomic.Value(bool) = .init(false) };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, controller: *ecl.Controller) void {
            if (block_open.swap(false, .acq_rel)) awaitGate(&state.cancelled);
            if (fail_open.swap(false, .acq_rel)) controller.fail(.domain, "deliberate initialization failure");
        }
        pub fn run(comptime P: type, state: *State, comptime mode: CounterMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
            if (switch (mode) {
                .step, .receive_step, .block, .block_send => true,
                else => false,
            }) {
                const amount = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected counter increment");
                if (amount < 0 or amount > 255) return controller.fail(.domain, "invalid counter increment");
                if (mode == .block or mode == .block_send) awaitGate(&state.cancelled);
                if (controller.cancelled()) return;
                state.total +%= @intCast(amount);
                try controller.builder().int(state.total);
                try controller.builder().result();
                return;
            }
            if (mode == .long_failure) {
                controller.fail(.io, ("x" ** 4095) ++ "€");
                return;
            }
            if (mode == .failure) {
                controller.fail(.domain, "deliberate operation failure");
                return;
            }
            if (mode == .blocked) {
                awaitGate(&state.cancelled);
                if (controller.cancelled()) return;
                state.total +%= 1;
            }
            var bytes: [64]u8 = undefined;
            while (true) {
                const count = (try (try controller.endpoint(P, .input)).read(&bytes) orelse 0);
                if (count == 0) break;
                for (bytes[0..count]) |byte| state.total +%= byte;
                if (mode == .echo) {
                    try (try controller.endpoint(P, .output)).write(bytes[0..count]);
                }
            }
            if (mode == .checksum or mode == .blocked) try (try controller.endpoint(P, .output)).write(&.{state.total});
        }
        pub fn cancel(state: *State) void {
            std.Io.Threaded.mutexLock(&gate_mutex);
            state.cancelled.store(true, .release);
            gate_changed.broadcast(fixtureIo());
            std.Io.Threaded.mutexUnlock(&gate_mutex);
        }
        pub fn deinit(_: *State) void {
            _ = cleaned.fetchAdd(1, .release);
        }
    };
}
const Counter = ecl.Port(struct {
    const Base = Spec("counter");
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{
        .input = ecl.declarations.Endpoint{ .name = "counter-input", .doc = "Write counter stream input.", .transport = .bytes, .direction = .input, .owner = .exchange },
        .output = ecl.declarations.Endpoint{ .name = "counter-output", .doc = "Read counter stream output.", .transport = .bytes, .direction = .output, .owner = .exchange },
    };
    pub const operations = .{
        .counter_step = .{ .name = "counter-step", .doc = "Apply a bounded structured increment.", .handler = on_counter_step, .lane = .operation, .endpoints = .{} },
        .counter_block = .{ .name = "counter-block", .doc = "Block before applying a structured increment.", .handler = on_counter_block, .lane = .operation, .endpoints = .{} },
        .counter_failure = .{ .name = "counter-failure", .doc = "Report an ordinary counter operation error.", .handler = on_counter_failure, .lane = .operation, .endpoints = .{} },
        .counter_long_failure = .{ .name = "counter-long-failure", .doc = "Report a bounded UTF-8 error.", .handler = on_counter_long_failure, .lane = .operation, .endpoints = .{} },
        .counter_echo = .{ .name = "counter-echo", .doc = "Echo exact byte streams through a single lane.", .handler = on_counter_echo, .lane = .operation, .endpoints = .{ .input, .output } },
    };
    fn on_counter_step(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Counter, state, .step, .operation, controller);
    }
    fn on_counter_block(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Counter, state, .block, .operation, controller);
    }
    fn on_counter_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Counter, state, .failure, .operation, controller);
    }
    fn on_counter_long_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Counter, state, .long_failure, .operation, controller);
    }
    fn on_counter_echo(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Counter, state, .echo, .operation, controller);
    }
});
const Other = ecl.Port(struct {
    const Base = Spec("other");
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{};
    pub const operations = .{
        .other_step = .{ .name = "other-step", .doc = "Apply a bounded increment to the other kind.", .handler = on_other_step, .lane = .operation, .endpoints = .{} },
    };
    fn on_other_step(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Other, state, .step, .operation, controller);
    }
});
fn DuplexSpec(comptime acknowledge: bool) type {
    return struct {
        const Base = Spec("lane");
        pub const name = if (acknowledge) "duplex" else "unacknowledged";
        pub const Lane = enum(u64) { receive, send };
        pub const cancellation: ecl.PortCancellation = .acknowledge;
        pub const State = struct {
            lanes: [2]Base.State = .{Base.State{}} ** 2,
            watcher_mode: std.atomic.Value(u32) = .init(0),
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, controller: *ecl.Controller) void {
            const config = controller.input(&.{}) orelse return controller.fail(.domain, "missing configuration");
            if (config.int()) |number| {
                if (number == 255) return controller.failOutOfMemory();
                if (number == 250) awaitGate(&state.lanes[0].cancelled);
                if (number < 0 or number > 255) return controller.fail(.domain, "invalid counter configuration");
                for (&state.lanes) |*current| current.total = @intCast(number);
            } else if (config.length() != 0) controller.fail(.domain, "expected an initial counter or empty configuration");
        }
        pub fn run(comptime P: type, state: *State, comptime mode: CounterMode, comptime selected_lane: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
            const current = &state.lanes[@intFromEnum(selected_lane)];
            defer if (acknowledge and controller.cancelled()) {
                current.cancelled.store(false, .release);
                _ = controller.acknowledgeCancellation();
            };
            if (switch (mode) {
                .resource_messages, .resource_bytes, .resource_notify, .rpc, .invalid_reply, .reply_result, .resource_compete_messages, .resource_compete_bytes, .datagram, .watch, .watch_config, .transform_message, .child, .dependent_child, .child_event, .discard_child, .child_pair, .events, .build_result, .duplicate_result, .oversize_event, .build_received => true,
                else => false,
            }) {
                if (mode == .resource_compete_messages) {
                    if ((try (try controller.endpoint(P, .resource_sender)).receive() != null)) try controller.resultMessage();
                    return;
                }
                if (mode == .resource_compete_bytes) {
                    var byte: [1]u8 = undefined;
                    _ = (try (try controller.endpoint(P, .resource_input)).read(&byte) orelse 0);
                    return;
                }
                if (mode == .resource_messages) {
                    _ = entered.fetchAdd(1, .release);
                    while ((try (try controller.endpoint(P, .resource_sender)).receive() != null)) try (try controller.endpoint(P, .resource_receiver)).forward();
                    if (!controller.cancelled()) try (try controller.endpoint(P, .resource_receiver)).finish();
                    return;
                }
                if (mode == .resource_bytes) {
                    _ = entered.fetchAdd(1, .release);
                    var bytes: [8]u8 = undefined;
                    while (true) {
                        const count = (try (try controller.endpoint(P, .resource_input)).read(&bytes) orelse 0);
                        if (count == 0) break;
                        try (try controller.endpoint(P, .resource_output)).write(bytes[0..count]);
                    }
                    if (!controller.cancelled()) try (try controller.endpoint(P, .resource_output)).finish();
                    return;
                }
                const builder = controller.builder();
                if (mode == .child_pair) {
                    try builder.int(0);
                    try builder.child(Duplex, .independent);
                    try builder.int(1);
                    try builder.child(Duplex, .independent);
                    try builder.list(2);
                    try builder.result();
                    return;
                }
                if (switch (mode) {
                    .child, .dependent_child, .child_event, .discard_child => true,
                    else => false,
                }) {
                    {
                        try builder.input(&.{});
                        try builder.child(Duplex, if (mode == .dependent_child) .dependent else .independent);
                    }
                    if (mode == .child_event) {
                        try (try controller.endpoint(P, .receiver)).send();
                    } else if (mode == .discard_child) {
                        {
                            try builder.clear();
                        }
                        try builder.int(42);
                        try builder.result();
                    } else try builder.result();
                    return;
                }
                if (mode == .transform_message) {
                    if (!(try (try controller.endpoint(P, .sender)).receive() != null)) return;
                    try builder.received(&.{});
                    try controller.discardMessage();
                    if (controller.discardMessage()) |_| {
                        return controller.fail(.contract, "received message consumption was not unique");
                    } else |err| if (err != error.InvalidValue) return err;
                    try (try controller.endpoint(P, .receiver)).send();
                    return;
                }
                if (mode == .datagram) {
                    if (!(try (try controller.endpoint(P, .sender)).receive() != null)) return;
                    {
                        try builder.symbol("payload");
                        try builder.received(&.{});
                        try builder.symbol("address");
                        try builder.symbol("127.0.0.1");
                        try builder.symbol("port");
                        try builder.int(42);
                        try builder.dictionary(3);
                        try (try controller.endpoint(P, .receiver)).send();
                    }
                    try controller.resultMessage();
                    try builder.symbol("kind");
                    try builder.symbol("loss");
                    try builder.symbol("count");
                    try builder.int(1);
                    try builder.dictionary(2);
                    try (try controller.endpoint(P, .receiver)).send();
                    return;
                }
                if (mode == .watch) {
                    for (0..2) |sequence| {
                        {
                            try builder.symbol("sequence");
                            try builder.int(@intCast(sequence));
                            try builder.symbol("mode");
                            try builder.int(state.watcher_mode.load(.acquire));
                            try builder.dictionary(2);
                            try (try controller.endpoint(P, .receiver)).send();
                        }
                        if (sequence == 0) {
                            if (!(try (try controller.endpoint(P, .sender)).receive() != null)) return;
                            try controller.discardMessage();
                        }
                    }
                    controller.fail(.io, "watcher disconnected");
                    return;
                }
                if (mode == .watch_config) {
                    const setting = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected watcher mode");
                    if (setting < 0 or setting > 255) return controller.fail(.domain, "invalid watcher mode");
                    state.watcher_mode.store(@intCast(setting), .release);
                    try builder.int(setting);
                    try builder.result();
                    return;
                }
                if (mode == .rpc) {
                    for (1..3) |id| {
                        {
                            try builder.symbol("id");
                            try builder.int(@intCast(id));
                            try builder.symbol("reply");
                            try (try controller.endpoint(P, .sender)).reply();
                            try builder.dictionary(2);
                            try (try controller.endpoint(P, .receiver)).send();
                        }
                        if (id == 1) {
                            {
                                try builder.symbol("notification");
                                try builder.int(7);
                                try builder.dictionary(1);
                                try (try controller.endpoint(P, .receiver)).send();
                            }
                        }
                    }
                    for (0..2) |index| {
                        if (!(try (try controller.endpoint(P, .sender)).receive() != null)) return;
                        const id = (controller.received(&.{0}) orelse return).int() orelse return;
                        const value = (controller.received(&.{1}) orelse return).int() orelse return;
                        if (id != 2 - @as(i64, @intCast(index)) or value != id * 10)
                            return controller.fail(.domain, "RPC reply correlation failed");
                        try (try controller.endpoint(P, .receiver)).forward();
                    }
                    try builder.int(42);
                    try builder.result();
                    return;
                }
                if (mode == .reply_result) {
                    try (try controller.endpoint(P, .sender)).reply();
                    try builder.result();
                    return;
                }
                if (mode == .resource_notify) {
                    try builder.int(42);
                    try (try controller.endpoint(P, .resource_receiver)).send();
                    return;
                }
                if (mode == .events) {
                    for (0..8) |index| {
                        try builder.int(@intCast(index));
                        try (try controller.endpoint(P, .receiver)).send();
                    }
                    return;
                }
                if (mode == .build_result) {
                    {
                        try builder.symbol("payload");
                        try builder.float(0.5);
                        try builder.char(0x03bb);
                        try builder.int(42);
                        try builder.symbol("tag");
                        try builder.input(&.{0});
                        try builder.list(5);
                        try builder.dictionary(1);
                        try builder.result();
                    }
                    return;
                }
                if (mode == .duplicate_result) {
                    {
                        try builder.symbol("key");
                        try builder.int(1);
                        try builder.symbol("key");
                        try builder.int(2);
                    }
                    try builder.dictionary(2);
                    return;
                }
                if (mode == .oversize_event) {
                    {
                        try builder.symbol("x" ** (64 * 1024));
                    }
                    if (builder.int(1)) |_| {
                        return controller.fail(.contract, "oversize construction unexpectedly succeeded");
                    } else |err| if (err != error.Failed) return err;
                    try (try controller.endpoint(P, .receiver)).send(); // Failed construction cannot publish a partial root.
                    return;
                }
                if (!(try (try controller.endpoint(P, .sender)).receive() != null)) return;
                {
                    try builder.symbol("discarded");
                    try builder.clear();
                    try builder.symbol("copy");
                    try builder.received(&.{0});
                    try builder.dictionary(1);
                    try controller.discardMessage();
                    try (try controller.endpoint(P, .receiver)).send();
                    try builder.list(0);
                    try (try controller.endpoint(P, .receiver)).send();
                    try builder.dictionary(0);
                    try builder.result();
                }
                return;
            }
            if (switch (mode) {
                .messages, .message_result, .message_failure => true,
                else => false,
            }) {
                while ((try (try controller.endpoint(P, .sender)).receive() != null)) {
                    if (controller.received(&.{}) == null) return controller.fail(.domain, "missing received message view");
                    if (mode == .message_result) {
                        try controller.resultMessage();
                        return;
                    }
                    try (try controller.endpoint(P, .receiver)).forward();
                    if (mode == .message_failure) return controller.fail(.domain, "failure after buffered message");
                }
                return;
            }
            if (mode == .allocation_failure) {
                controller.failOutOfMemory();
                controller.fail(.domain, "must not mask allocation exhaustion");
                return;
            }
            if (mode == .noop) return;
            if (mode == .buffered_failure or mode == .finished_failure) {
                try (try controller.endpoint(P, .output)).write(&.{ 4, 5, 6 });
                if (mode == .finished_failure) try (try controller.endpoint(P, .output)).finish();
                controller.fail(.domain, "failure after buffered output");
                return;
            }
            if (mode == .pipeline) {
                var buffer: [64]u8 = undefined;
                while (true) {
                    const count = (try (try controller.endpoint(P, .input)).read(&buffer) orelse 0);
                    if (count == 0) return;
                    try (try controller.endpoint(P, .output)).write(buffer[0..count]);
                    for (buffer[0..count]) |*byte| byte.* ^= 255;
                    try (try controller.endpoint(P, .diagnostics)).write(buffer[0..count]);
                }
            }
            if (mode == .early_exit) {
                var byte: [1]u8 = undefined;
                if ((try (try controller.endpoint(P, .input)).read(&byte) orelse 0) != 0) try (try controller.endpoint(P, .output)).write(&byte);
                return;
            }
            if (mode == .inspect) {
                if (current.total != 7 or !checkParameters(controller)) controller.fail(.domain, "structured parameters were not preserved");
                return;
            }
            try Base.run(P, current, mode, selected_lane, controller);
        }
        pub fn shutdown(state: *State, controller: *ecl.Controller) void {
            _ = shutdowns.fetchAdd(1, .release);
            const config = (controller.input(&.{}) orelse return).int() orelse 0;
            if (config == 252) return controller.failOutOfMemory();
            if (config == 254) return controller.fail(.domain, "deliberate shutdown failure");
            if (config == 253) awaitGate(&state.lanes[0].cancelled);
            // Completing the graceful callback permits the runtime to close
            // remaining exchanges and join their cancellation return.
        }
        pub fn cancelOperation(state: *State, selected: Lane) void {
            Base.cancel(&state.lanes[@intFromEnum(selected)]);
        }
        pub fn cancel(state: *State) void {
            for (&state.lanes) |*current| Base.cancel(current);
        }
        pub fn deinit(_: *State) void {
            _ = cleaned.fetchAdd(1, .release);
        }
    };
}
fn checkParameters(controller: *ecl.Controller) bool {
    if ((controller.input(&.{}) orelse return false).length() != 7) return false;
    if ((controller.input(&.{0}) orelse return false).int() != 42) return false;
    if ((controller.input(&.{1}) orelse return false).float() != 0.5) return false;
    if ((controller.input(&.{2}) orelse return false).char() != 'a') return false;
    if (!std.mem.eql(u8, (controller.input(&.{3}) orelse return false).symbol() orelse return false, "tag")) return false;
    if ((controller.input(&.{ 4, 0 }) orelse return false).int() != 7) return false;
    if (!std.mem.eql(u8, (controller.input(&.{ 5, 0 }) orelse return false).symbol() orelse return false, "key")) return false;
    if ((controller.input(&.{ 5, 1 }) orelse return false).int() != 9) return false;
    if ((controller.input(&.{6}) orelse return false).kind() != .port) return false;
    return controller.input(&.{7}) == null;
}
const DuplexSdk = ecl.Port(struct {
    const Base = DuplexSpec(true);
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const shutdown = Base.shutdown;
    pub const cancelOperation = Base.cancelOperation;
    pub const endpoints = .{
        .resource_input = ecl.declarations.Endpoint{ .name = "resource-input", .doc = "Resource byte input.", .transport = .bytes, .direction = .input, .owner = .resource },
        .resource_output = ecl.declarations.Endpoint{ .name = "resource-output", .doc = "Resource byte output.", .transport = .bytes, .direction = .output, .owner = .resource },
        .resource_sender = ecl.declarations.Endpoint{ .name = "resource-sender", .doc = "Resource structured input.", .transport = .messages, .direction = .input, .owner = .resource },
        .resource_receiver = ecl.declarations.Endpoint{ .name = "resource-receiver", .doc = "Resource structured output.", .transport = .messages, .direction = .output, .owner = .resource },
        .input = ecl.declarations.Endpoint{ .name = "input", .doc = "Exchange byte input.", .transport = .bytes, .direction = .input, .owner = .exchange },
        .output = ecl.declarations.Endpoint{ .name = "output", .doc = "Exchange byte output.", .transport = .bytes, .direction = .output, .owner = .exchange },
        .diagnostics = ecl.declarations.Endpoint{ .name = "diagnostics", .doc = "Independent pipeline diagnostic bytes.", .transport = .bytes, .direction = .output, .owner = .exchange },
        .sender = ecl.declarations.Endpoint{ .name = "sender", .doc = "Structured message input.", .transport = .messages, .direction = .input, .owner = .exchange },
        .receiver = ecl.declarations.Endpoint{ .name = "receiver", .doc = "Structured message output.", .transport = .messages, .direction = .output, .owner = .exchange },
    };
    pub const operations = .{
        .step = .{ .name = "step", .doc = "Apply an increment on the send lane.", .handler = on_step, .lane = .send, .endpoints = .{} },
        .receive_step = .{ .name = "receive-step", .doc = "Apply an increment on the receive lane.", .handler = on_receive_step, .lane = .receive, .endpoints = .{} },
        .block = .{ .name = "block", .doc = "Block a recoverable receive operation.", .handler = on_block, .lane = .receive, .endpoints = .{} },
        .block_send = .{ .name = "block-send", .doc = "Block a recoverable send operation.", .handler = on_block_send, .lane = .send, .endpoints = .{} },
        .echo = .{ .name = "echo", .doc = "Echo accepted input bytes.", .handler = on_echo, .lane = .receive, .endpoints = .{ .input, .output } },
        .checksum = .{ .name = "checksum", .doc = "Sum accepted input bytes.", .handler = on_checksum, .lane = .send, .endpoints = .{ .input, .output } },
        .failure = .{ .name = "failure", .doc = "Fail with a deterministic terminal error.", .handler = on_failure, .lane = .receive, .endpoints = .{} },
        .inspect = .{ .name = "inspect", .doc = "Validate structured parameters without additional streaming.", .handler = on_inspect, .lane = .receive, .endpoints = .{} },
        .allocation_failure = .{ .name = "allocation-failure", .doc = "Report asynchronous allocation exhaustion.", .handler = on_allocation_failure, .lane = .receive, .endpoints = .{ .output, .sender, .receiver } },
        .noop = .{ .name = "noop", .doc = "Complete without additional streaming.", .handler = on_noop, .lane = .receive, .endpoints = .{} },
        .buffered_failure = .{ .name = "buffered-failure", .doc = "Fail after accepting output bytes.", .handler = on_buffered_failure, .lane = .receive, .endpoints = .{.output} },
        .finished_failure = .{ .name = "finished-failure", .doc = "Fail after finishing the output endpoint.", .handler = on_finished_failure, .lane = .receive, .endpoints = .{.output} },
        .pipeline = .{ .name = "pipeline", .doc = "Stream input, output, and independent diagnostics.", .handler = on_pipeline, .lane = .receive, .endpoints = .{ .input, .output, .diagnostics } },
        .early_exit = .{ .name = "early-exit", .doc = "Stop consuming input after one byte.", .handler = on_early_exit, .lane = .receive, .endpoints = .{ .input, .output } },
        .resource_messages = .{ .name = "resource-messages", .doc = "Forward through resource-owned message channels.", .handler = on_resource_messages, .lane = .receive, .endpoints = .{} },
        .resource_bytes = .{ .name = "resource-bytes", .doc = "Forward through resource-owned byte streams.", .handler = on_resource_bytes, .lane = .receive, .endpoints = .{} },
        .resource_notify = .{ .name = "resource-notify", .doc = "Produce a resource event independently of exchange output.", .handler = on_resource_notify, .lane = .receive, .endpoints = .{} },
        .rpc = .{ .name = "rpc", .doc = "Request ECL replies through opaque sender endpoints.", .handler = on_rpc, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .invalid_reply = .{ .name = "invalid-reply", .doc = "Reject reply authority for an output endpoint.", .handler = on_invalid_reply, .lane = .receive, .endpoints = .{.receiver} },
        .resource_reply = .{ .name = "resource-reply", .doc = "Return a reply sender borrowed from the resource.", .handler = on_resource_reply, .lane = .send, .endpoints = .{} },
        .reply_result = .{ .name = "reply-result", .doc = "Return a retained endpoint after completion.", .handler = on_reply_result, .lane = .receive, .endpoints = .{.sender} },
        .resource_compete_messages = .{ .name = "resource-compete-messages", .doc = "Read resource messages on an independent lane.", .handler = on_resource_compete_messages, .lane = .send, .endpoints = .{} },
        .resource_compete_bytes = .{ .name = "resource-compete-bytes", .doc = "Read resource bytes on an independent lane.", .handler = on_resource_compete_bytes, .lane = .send, .endpoints = .{} },
        .datagram = .{ .name = "datagram", .doc = "Report packet metadata and explicit native loss.", .handler = on_datagram, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .watch = .{ .name = "watch", .doc = "Emit watcher events and a deterministic disconnect.", .handler = on_watch, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .watch_config = .{ .name = "watch-config", .doc = "Configure a watcher on an independent controller lane.", .handler = on_watch_config, .lane = .send, .endpoints = .{} },
        .transform_message = .{ .name = "transform-message", .doc = "Release consumed input while retaining a constructed response.", .handler = on_transform_message, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .child = .{ .name = "child", .doc = "Return an independent child resource.", .handler = on_child, .lane = .receive, .endpoints = .{} },
        .dependent_child = .{ .name = "dependent-child", .doc = "Return a dependent child resource.", .handler = on_dependent_child, .lane = .receive, .endpoints = .{} },
        .child_event = .{ .name = "child-event", .doc = "Send an independent child resource.", .handler = on_child_event, .lane = .receive, .endpoints = .{.receiver} },
        .discard_child = .{ .name = "discard-child", .doc = "Discard a provisional child before returning a scalar result.", .handler = on_discard_child, .lane = .receive, .endpoints = .{} },
        .child_pair = .{ .name = "child-pair", .doc = "Return two children in one atomic result publication.", .handler = on_child_pair, .lane = .receive, .endpoints = .{} },
        .events = .{ .name = "events", .doc = "Produce unsolicited structured events under pressure.", .handler = on_events, .lane = .receive, .endpoints = .{.receiver} },
        .build_result = .{ .name = "build-result", .doc = "Construct a nested structured result with a capability.", .handler = on_build_result, .lane = .receive, .endpoints = .{} },
        .duplicate_result = .{ .name = "duplicate-result", .doc = "Reject duplicate structured keys.", .handler = on_duplicate_result, .lane = .receive, .endpoints = .{} },
        .oversize_event = .{ .name = "oversize-event", .doc = "Reject oversize construction before output.", .handler = on_oversize_event, .lane = .receive, .endpoints = .{.receiver} },
        .build_received = .{ .name = "build-received", .doc = "Copy received values and construct empty aggregates.", .handler = on_build_received, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .messages = .{ .name = "messages", .doc = "Forward complete structured messages.", .handler = on_messages, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .message_result = .{ .name = "message-result", .doc = "Return one structured message as the terminal result.", .handler = on_message_result, .lane = .receive, .endpoints = .{.sender} },
        .message_failure = .{ .name = "message-failure", .doc = "Fail after accepting one output message.", .handler = on_message_failure, .lane = .receive, .endpoints = .{ .sender, .receiver } },
        .blocked = .{ .name = "blocked", .doc = "Wait for an explicit controller gate.", .handler = on_blocked, .lane = .receive, .endpoints = .{ .input, .output } },
    };
    fn on_step(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .step, .send, controller);
    }
    fn on_receive_step(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .receive_step, .receive, controller);
    }
    fn on_block(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .block, .receive, controller);
    }
    fn on_block_send(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .block_send, .send, controller);
    }
    fn on_echo(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .echo, .receive, controller);
    }
    fn on_checksum(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .checksum, .send, controller);
    }
    fn on_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .failure, .receive, controller);
    }
    fn on_inspect(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .inspect, .receive, controller);
    }
    fn on_allocation_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .allocation_failure, .receive, controller);
    }
    fn on_noop(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .noop, .receive, controller);
    }
    fn on_buffered_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .buffered_failure, .receive, controller);
    }
    fn on_finished_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .finished_failure, .receive, controller);
    }
    fn on_pipeline(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .pipeline, .receive, controller);
    }
    fn on_early_exit(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .early_exit, .receive, controller);
    }
    fn on_resource_messages(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .resource_messages, .receive, controller);
    }
    fn on_resource_bytes(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .resource_bytes, .receive, controller);
    }
    fn on_resource_notify(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .resource_notify, .receive, controller);
    }
    fn on_rpc(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .rpc, .receive, controller);
    }
    fn on_invalid_reply(_: *State, _: *ecl.Controller) void {
        unreachable; // Exercised by the malformed ABI callback below.
    }
    fn on_resource_reply(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const input = try controller.endpoint(Duplex, .resource_sender);
        try input.reply();
        try controller.builder().result();
    }
    fn on_reply_result(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .reply_result, .receive, controller);
    }
    fn on_resource_compete_messages(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .resource_compete_messages, .send, controller);
    }
    fn on_resource_compete_bytes(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .resource_compete_bytes, .send, controller);
    }
    fn on_datagram(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .datagram, .receive, controller);
    }
    fn on_watch(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .watch, .receive, controller);
    }
    fn on_watch_config(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .watch_config, .send, controller);
    }
    fn on_transform_message(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .transform_message, .receive, controller);
    }
    fn on_child(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .child, .receive, controller);
    }
    fn on_dependent_child(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .dependent_child, .receive, controller);
    }
    fn on_child_event(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .child_event, .receive, controller);
    }
    fn on_discard_child(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .discard_child, .receive, controller);
    }
    fn on_child_pair(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .child_pair, .receive, controller);
    }
    fn on_events(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .events, .receive, controller);
    }
    fn on_build_result(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .build_result, .receive, controller);
    }
    fn on_duplicate_result(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .duplicate_result, .receive, controller);
    }
    fn on_oversize_event(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .oversize_event, .receive, controller);
    }
    fn on_build_received(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .build_received, .receive, controller);
    }
    fn on_messages(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .messages, .receive, controller);
    }
    fn on_message_result(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .message_result, .receive, controller);
    }
    fn on_message_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .message_failure, .receive, controller);
    }
    fn on_blocked(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Duplex, state, .blocked, .receive, controller);
    }
});
// Deliberately bypass the SDK to test hostile wire metadata. Ordinary fixture
// operations still use the generated bridge and the same resource identity.
const Duplex = struct {
    pub const ecl_port_marker = void;
    pub const name = DuplexSdk.name;
    pub const StateType = DuplexSdk.StateType;
    pub const LaneType = DuplexSdk.LaneType;
    pub const Endpoints = DuplexSdk.Endpoints;
    pub const Operations = DuplexSdk.Operations;
    pub fn kindIdentity() *const anyopaque {
        return DuplexSdk.definition().identity.?;
    }
    pub fn definition() ecl.abi.PortDefinition {
        var result = DuplexSdk.definition();
        result.execute = execute;
        return result;
    }
    fn execute(raw: *anyopaque, operation: u32, table: *const ecl.abi.ControllerTable, context: *anyopaque) callconv(.c) void {
        if (operation == @intFromEnum(Operations.Name.invalid_reply)) {
            _ = table.build_message(context, &.{ .action = .reply_endpoint, .endpoint = Endpoints.id(.receiver) });
        } else DuplexSdk.definition().execute.?(raw, operation, table, context);
    }
};

const Unacknowledged = ecl.Port(struct {
    const Base = DuplexSpec(false);
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const shutdown = Base.shutdown;
    pub const cancelOperation = Base.cancelOperation;
    pub const endpoints = .{};
    pub const operations = .{
        .unrecoverable_block = .{ .name = "unrecoverable-block", .doc = "Block the unrecoverable receive lane.", .handler = on_unrecoverable_block, .lane = .receive, .endpoints = .{} },
        .unrecoverable_send = .{ .name = "unrecoverable-send", .doc = "Block the unrecoverable send lane.", .handler = on_unrecoverable_send, .lane = .send, .endpoints = .{} },
    };
    fn on_unrecoverable_block(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Unacknowledged, state, .block, .receive, controller);
    }
    fn on_unrecoverable_send(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Unacknowledged, state, .block_send, .send, controller);
    }
});

const Schedule = ecl.Reschedule(struct {
    pub const State = u8;
    pub fn init() State {
        return 0;
    }
    pub fn deinit(_: *State) void {}
});
fn cleanupCount(call: *ecl.Call("-- n")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(cleaned.load(.acquire))});
}
fn shutdownCount(call: *ecl.Call("-- n")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(shutdowns.load(.acquire))});
}
fn failLong(call: *ecl.Call("--")) ecl.CallbackResult {
    return call.fail(.io, ("x" ** 4095) ++ "€");
}
fn unblock(call: *ecl.Call("--")) ecl.CallbackResult {
    std.Io.Threaded.mutexLock(&gate_mutex);
    permits += 1;
    gate_changed.broadcast(fixtureIo());
    std.Io.Threaded.mutexUnlock(&gate_mutex);
    return call.complete(.{});
}
fn reset(call: *ecl.Call("--")) ecl.CallbackResult {
    shutdowns.store(0, .release);
    cleaned.store(0, .release);
    entered.store(0, .release);
    waiting.store(0, .release);
    fail_open.store(false, .release);
    block_open.store(false, .release);
    std.Io.Threaded.mutexLock(&gate_mutex);
    permits = 0;
    std.Io.Threaded.mutexUnlock(&gate_mutex);
    return call.complete(.{});
}
fn failNext(call: *ecl.Call("--")) ecl.CallbackResult {
    fail_open.store(true, .release);
    return call.complete(.{});
}
fn blockNext(call: *ecl.Call("--")) ecl.CallbackResult {
    block_open.store(true, .release);
    return call.complete(.{});
}
fn awaitCounter(comptime counter: *std.atomic.Value(u32)) type {
    return struct {
        fn run(call: *ecl.Call("n --"), schedule: *Schedule) ecl.CallbackResult {
            const n = call.input(0).int() orelse return call.fail(.type, "expected counter target");
            if (n < 0) return call.fail(.domain, "negative counter target");
            if (counter.load(.acquire) >= n) return call.complete(.{});
            return schedule.yield();
        }
    };
}
fn signalWaiting(call: *ecl.Call("--")) ecl.CallbackResult {
    _ = waiting.fetchAdd(1, .release);
    return call.complete(.{});
}
const StorageSpec = struct {
    pub const name = "storage";
    pub const State = struct {
        value: std.atomic.Value(i64) = .init(0),
        durable: std.atomic.Value(i64) = .init(0),
        transaction: std.atomic.Value(bool) = .init(false),
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(comptime P: type, state: *State, comptime mode: StorageMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        switch (mode) {
            .query, .detached_query => {
                try builder.input(&.{});
                try builder.child(Cursor, if (mode == .query) .dependent else .independent);
                try builder.result();
            },
            .transaction => {
                if (state.transaction.load(.acquire)) return controller.fail(.contract, "transaction is already active");
                try builder.list(0);
                try builder.child(TransactionPort, .dependent);
                try builder.result();
            },
            .durable => {
                const durable = state.value.load(.acquire);
                state.durable.store(durable, .release);
                try builder.int(durable);
                try builder.result();
            },
            .storage_status => {
                try builder.int(state.value.load(.acquire));
                try builder.int(state.durable.load(.acquire));
                try builder.int(@intFromBool(state.transaction.load(.acquire)));
                try builder.list(3);
                try builder.result();
            },
            .lookalike_child => {
                try builder.list(0);
                try builder.child(LookalikeStorage, .dependent);
                try builder.result();
            },
        }
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Storage = ecl.Port(struct {
    const Base = StorageSpec;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{};
    pub const operations = .{
        .query = .{ .name = "query", .doc = "Create a dependent cursor from structured offset and count parameters.", .handler = on_query, .lane = .operation, .endpoints = .{} },
        .transaction = .{ .name = "transaction", .doc = "Create an exclusive transaction child.", .handler = on_transaction, .lane = .operation, .endpoints = .{} },
        .durable = .{ .name = "durable", .doc = "Acknowledge durable storage separately from commit.", .handler = on_durable, .lane = .operation, .endpoints = .{} },
        .storage_status = .{ .name = "storage-status", .doc = "Observe committed, durable, and transaction state.", .handler = on_storage_status, .lane = .operation, .endpoints = .{} },
        .detached_query = .{ .name = "detached-query", .doc = "Reject parent-state access by an independent child.", .handler = on_detached_query, .lane = .operation, .endpoints = .{} },
        .lookalike_child = .{ .name = "lookalike-child", .doc = "Reject an unregistered type with a registered kind's name.", .handler = on_lookalike_child, .lane = .operation, .endpoints = .{} },
    };
    fn on_query(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Storage, state, .query, .operation, controller);
    }
    fn on_transaction(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Storage, state, .transaction, .operation, controller);
    }
    fn on_durable(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Storage, state, .durable, .operation, controller);
    }
    fn on_storage_status(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Storage, state, .storage_status, .operation, controller);
    }
    fn on_detached_query(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Storage, state, .detached_query, .operation, controller);
    }
    fn on_lookalike_child(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Storage, state, .lookalike_child, .operation, controller);
    }
});

const LookalikeStorageBackend = struct {
    pub const name = StorageSpec.name;
    pub const State = struct { unrelated: u8 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(comptime P: type, _: *State, comptime _: P.LaneType, _: *ecl.Controller) ecl.ControllerError!void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
};
const LookalikeStorage = ecl.Port(struct {
    const Base = LookalikeStorageBackend;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{};
    pub const operations = .{};
});

const CursorBackend = struct {
    pub const name = "cursor";
    pub const State = struct { parent: ?*Storage.StateType = null, position: i64 = 0, end: i64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        state.parent = controller.parent(Storage) orelse return controller.fail(.domain, "cursor requires a storage parent");
        if (controller.parent(Duplex) != null) return controller.fail(.contract, "parent kind was not validated");
        if (controller.parent(LookalikeStorage) != null) return controller.fail(.contract, "same-name parent type was accepted");
        const offset = (controller.input(&.{0}) orelse return controller.fail(.type, "missing cursor offset")).int() orelse return controller.fail(.type, "expected cursor offset");
        const count = (controller.input(&.{1}) orelse return controller.fail(.type, "missing cursor count")).int() orelse return controller.fail(.type, "expected cursor count");
        if (offset < 0 or count < 0 or offset > 4 or count > 4 - offset) return controller.fail(.domain, "cursor range exceeds fixture rows");
        state.position = offset;
        state.end = offset + count;
    }
    pub fn run(comptime P: type, state: *State, comptime mode: CursorMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        switch (mode) {
            .rows => while (state.position < state.end) : (state.position += 1) {
                {
                    try builder.symbol("id");
                    try builder.int(state.position);
                    try builder.symbol("value");
                    try builder.int(state.parent.?.value.load(.acquire) + state.position);
                    try builder.dictionary(2);
                    try (try controller.endpoint(P, .row)).send();
                }
                _ = entered.fetchAdd(1, .release);
            },
            .position => {
                const position = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected position");
                if (position < 0 or position > state.end) return controller.fail(.domain, "position exceeds cursor range");
                state.position = position;
                try builder.int(position);
                try builder.result();
            },
        }
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Cursor = ecl.Port(struct {
    const Base = CursorBackend;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{
        .row = ecl.declarations.Endpoint{ .name = "row", .doc = "Read complete cursor rows.", .transport = .messages, .direction = .output, .owner = .exchange },
    };
    pub const operations = .{
        .rows = .{ .name = "rows", .doc = "Stream complete row messages under bounded pressure.", .handler = on_rows, .lane = .operation, .endpoints = .{.row} },
        .position = .{ .name = "position", .doc = "Position the cursor with a registered operation.", .handler = on_position, .lane = .operation, .endpoints = .{} },
    };
    fn on_rows(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Cursor, state, .rows, .operation, controller);
    }
    fn on_position(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Cursor, state, .position, .operation, controller);
    }
});

const TransactionPortBackend = struct {
    pub const name = "transaction";
    pub const State = struct {
        parent: ?*Storage.StateType = null,
        pending: i64 = 0,
        committed: bool = false,
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        const parent = controller.parent(Storage) orelse return controller.fail(.domain, "transaction requires a storage parent");
        if (parent.transaction.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return controller.fail(.contract, "transaction is already active");
        state.parent = parent;
        state.pending = parent.value.load(.acquire);
    }
    pub fn run(comptime P: type, state: *State, comptime mode: TransactionPortMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        if (state.committed) return controller.fail(.contract, "transaction is already committed");
        switch (mode) {
            .transaction_write => {
                state.pending = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected transaction value");
                try builder.int(state.pending);
                try builder.result();
            },
            .commit => {
                state.parent.?.value.store(state.pending, .release);
                state.committed = true;
                try builder.int(state.pending);
                try builder.result();
            },
            .transaction_wait => {
                _ = entered.fetchAdd(1, .release);
                if ((try (try controller.endpoint(P, .input)).receive() != null)) try controller.discardMessage();
            },
        }
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(state: *State) void {
        // This write deliberately occurs during destruction. The parent's
        // dependency join must keep its native state alive through this point.
        if (state.parent) |parent| parent.transaction.store(false, .release);
        _ = cleaned.fetchAdd(1, .release);
    }
};
const TransactionPort = ecl.Port(struct {
    const Base = TransactionPortBackend;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{
        .input = ecl.declarations.Endpoint{ .name = "transaction-input", .doc = "Transaction control input.", .transport = .messages, .direction = .input, .owner = .exchange },
    };
    pub const operations = .{
        .transaction_write = .{ .name = "transaction-write", .doc = "Stage an uncommitted value.", .handler = on_transaction_write, .lane = .operation, .endpoints = .{} },
        .commit = .{ .name = "commit", .doc = "Commit once without implying durability.", .handler = on_commit, .lane = .operation, .endpoints = .{} },
        .transaction_wait = .{ .name = "transaction-wait", .doc = "Block until input or cancellation.", .handler = on_transaction_wait, .lane = .operation, .endpoints = .{.input} },
    };
    fn on_transaction_write(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(TransactionPort, state, .transaction_write, .operation, controller);
    }
    fn on_commit(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(TransactionPort, state, .commit, .operation, controller);
    }
    fn on_transaction_wait(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(TransactionPort, state, .transaction_wait, .operation, controller);
    }
});

const BrokerSpec = struct {
    pub const name = "broker";
    const Phase = union(enum) { empty, pending: u32, acknowledged: u32 };
    pub const State = struct {
        mutex: std.Io.Mutex = .init,
        phase: Phase = .empty,
        active: u32 = 0,
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(comptime P: type, state: *State, comptime mode: BrokerMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        std.Io.Threaded.mutexLock(&state.mutex);
        if (mode == .broker_status) {
            const phase = state.phase;
            const active = state.active;
            std.Io.Threaded.mutexUnlock(&state.mutex);
            const label: []const u8 = switch (phase) {
                .empty => "empty",
                .pending => "pending",
                .acknowledged => "acknowledged",
            };
            const attempt: u32 = switch (phase) {
                .empty => 0,
                .pending, .acknowledged => |number| number,
            };
            try builder.symbol(label);
            try builder.int(attempt);
            try builder.int(active);
            try builder.list(3);
            try builder.result();
            return;
        }
        const attempt: u32 = if (mode == .deliver and state.phase == .empty) 1 else if (mode == .redeliver and state.phase == .pending) next: {
            if (state.phase.pending == std.math.maxInt(u32)) {
                std.Io.Threaded.mutexUnlock(&state.mutex);
                return controller.fail(.overflow, "delivery attempt limit reached");
            }
            break :next state.phase.pending + 1;
        } else {
            std.Io.Threaded.mutexUnlock(&state.mutex);
            return controller.fail(.contract, "delivery requires an explicit pending redelivery");
        };
        state.phase = .{ .pending = attempt };
        std.Io.Threaded.mutexUnlock(&state.mutex);
        if (mode == .deliver) {
            try builder.symbol("delivery");
            try builder.int(attempt);
            try builder.child(Delivery, .dependent);
            try builder.symbol("payload");
            try builder.list(0);
            try builder.dictionary(2);
            try (try controller.endpoint(P, .deliveries)).send();
        } else {
            try builder.int(attempt);
            try builder.child(Delivery, .dependent);
            try builder.result();
        }
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(state: *State) void {
        std.Io.Threaded.mutexLock(&state.mutex);
        if (state.active != 0) @panic("broker cleanup preceded dependent delivery destruction");
        std.Io.Threaded.mutexUnlock(&state.mutex);
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Broker = ecl.Port(struct {
    const Base = BrokerSpec;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{
        .deliveries = ecl.declarations.Endpoint{ .name = "deliveries", .doc = "Receive complete delivery messages.", .transport = .messages, .direction = .output, .owner = .exchange },
    };
    pub const operations = .{
        .deliver = .{ .name = "deliver", .doc = "Deliver one opaque acknowledgement capability with an empty payload.", .handler = on_deliver, .lane = .operation, .endpoints = .{.deliveries} },
        .redeliver = .{ .name = "redeliver", .doc = "Explicitly replace an unacknowledged delivery attempt.", .handler = on_redeliver, .lane = .operation, .endpoints = .{} },
        .broker_status = .{ .name = "broker-status", .doc = "Observe acknowledgement state and live deliveries.", .handler = on_broker_status, .lane = .operation, .endpoints = .{} },
    };
    fn on_deliver(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Broker, state, .deliver, .operation, controller);
    }
    fn on_redeliver(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Broker, state, .redeliver, .operation, controller);
    }
    fn on_broker_status(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Broker, state, .broker_status, .operation, controller);
    }
});

const DeliveryBackend = struct {
    pub const name = "delivery";
    pub const State = struct { parent: ?*Broker.StateType = null, attempt: u32 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        const parent = controller.parent(Broker) orelse return controller.fail(.domain, "delivery requires a broker parent");
        const attempt = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected delivery attempt");
        std.Io.Threaded.mutexLock(&parent.mutex);
        defer std.Io.Threaded.mutexUnlock(&parent.mutex);
        if (parent.phase != .pending or parent.phase.pending != attempt)
            return controller.fail(.contract, "delivery attempt is no longer pending");
        state.* = .{ .parent = parent, .attempt = @intCast(attempt) };
        parent.active += 1;
    }
    pub fn run(comptime P: type, state: *State, comptime mode: DeliveryMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        if (mode == .delivery_info) {
            try builder.symbol("id");
            try builder.int(1);
            try builder.symbol("attempt");
            try builder.int(state.attempt);
            try builder.dictionary(2);
            try builder.result();
            return;
        }
        const parent = state.parent.?;
        std.Io.Threaded.mutexLock(&parent.mutex);
        const accepted = mode == .acknowledge and parent.phase == .pending and parent.phase.pending == state.attempt;
        if (accepted) parent.phase = .{ .acknowledged = state.attempt };
        std.Io.Threaded.mutexUnlock(&parent.mutex);
        if (!accepted) return controller.fail(.contract, "delivery acknowledgement is stale or already consumed");
        try builder.int(state.attempt);
        try builder.result();
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(state: *State) void {
        if (state.parent) |parent| {
            std.Io.Threaded.mutexLock(&parent.mutex);
            parent.active -= 1;
            std.Io.Threaded.mutexUnlock(&parent.mutex);
        }
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Delivery = ecl.Port(struct {
    const Base = DeliveryBackend;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{};
    pub const operations = .{
        .acknowledge = .{ .name = "acknowledge", .doc = "Acknowledge the current delivery exactly once.", .handler = on_acknowledge, .lane = .operation, .endpoints = .{} },
        .delivery_info = .{ .name = "delivery-info", .doc = "Observe delivery identity and explicit attempt number.", .handler = on_delivery_info, .lane = .operation, .endpoints = .{} },
    };
    fn on_acknowledge(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Delivery, state, .acknowledge, .operation, controller);
    }
    fn on_delivery_info(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Delivery, state, .delivery_info, .operation, controller);
    }
});

const DeviceSpec = struct {
    pub const name = "device";
    pub const State = struct {
        buffers: std.atomic.Value(u32) = .init(0),
        working: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(comptime P: type, state: *State, comptime mode: DeviceMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        switch (mode) {
            .buffer => {
                try builder.input(&.{});
                try builder.child(Buffer, .dependent);
                try builder.result();
            },
            .device_status => {
                try builder.int(state.buffers.load(.acquire));
                try builder.int(state.working.load(.acquire));
                try builder.int(state.completed.load(.acquire));
                try builder.list(3);
                try builder.result();
            },
        }
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(state: *State) void {
        if (state.buffers.load(.acquire) != 0 or state.working.load(.acquire) != 0)
            @panic("device destruction preceded backend work and buffer cleanup");
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Device = ecl.Port(struct {
    const Base = DeviceSpec;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{};
    pub const operations = .{
        .buffer = .{ .name = "buffer", .doc = "Create an opaque dependent eight-byte buffer.", .handler = on_buffer, .lane = .operation, .endpoints = .{} },
        .device_status = .{ .name = "device-status", .doc = "Observe live buffers and backend work.", .handler = on_device_status, .lane = .operation, .endpoints = .{} },
    };
    fn on_buffer(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Device, state, .buffer, .operation, controller);
    }
    fn on_device_status(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Device, state, .device_status, .operation, controller);
    }
});

const BufferSpec = struct {
    pub const name = "buffer";
    pub const Lane = enum(u32) { compute, control };
    pub const cancellation: ecl.PortCancellation = .acknowledge;
    pub const State = struct {
        parent: ?*Device.StateType = null,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        bytes: [8]u8 = .{0} ** 8,
        ready: bool = false,
        stopped: bool = false,
        working: bool = false,
        checksum: u32 = 0,
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        const parent = controller.parent(Device) orelse return controller.fail(.domain, "buffer requires a device parent");
        const byte = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected buffer byte");
        if (byte < 0 or byte > 255) return controller.fail(.domain, "buffer byte must be in 0...255");
        state.parent = parent;
        state.bytes = .{@as(u8, @intCast(byte))} ** 8;
        _ = parent.buffers.fetchAdd(1, .release);
    }
    fn work(state: *State) void {
        std.Io.Threaded.mutexLock(&state.mutex);
        defer std.Io.Threaded.mutexUnlock(&state.mutex);
        state.working = true;
        _ = state.parent.?.working.fetchAdd(1, .release);
        _ = entered.fetchAdd(1, .release);
        while (!state.ready and !state.stopped) state.changed.waitUncancelable(fixtureIo(), &state.mutex);
        if (!state.stopped) {
            state.checksum = 0;
            for (state.bytes) |byte| state.checksum += byte;
            state.ready = false;
            _ = state.parent.?.completed.fetchAdd(1, .release);
        }
        _ = state.parent.?.working.fetchSub(1, .release);
        state.working = false;
    }
    pub fn run(comptime P: type, state: *State, comptime mode: BufferMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        if (mode == .compute) {
            // The native worker borrows only backend state. A controller must
            // join it before acknowledging cancellation or publishing a result.
            const worker = std.Thread.spawn(.{}, work, .{state}) catch return controller.fail(.io, "cannot start device work");
            worker.join();
            if (controller.cancelled()) {
                std.Io.Threaded.mutexLock(&state.mutex);
                state.stopped = false;
                std.Io.Threaded.mutexUnlock(&state.mutex);
                _ = controller.acknowledgeCancellation();
                return;
            }
            try controller.builder().int(state.checksum);
            try controller.builder().result();
            return;
        }
        defer if (controller.cancelled()) {
            _ = controller.acknowledgeCancellation();
        };
        switch (mode) {
            .compute => unreachable,
            .complete_work => {
                std.Io.Threaded.mutexLock(&state.mutex);
                state.ready = true;
                state.changed.broadcast(fixtureIo());
                std.Io.Threaded.mutexUnlock(&state.mutex);
            },
            .buffer_update => {
                const index = (controller.input(&.{0}) orelse return).int() orelse return controller.fail(.type, "expected buffer index");
                const byte = (controller.input(&.{1}) orelse return).int() orelse return controller.fail(.type, "expected buffer byte");
                if (index < 0 or index >= 8 or byte < 0 or byte > 255) return controller.fail(.domain, "invalid positioned buffer update");
                std.Io.Threaded.mutexLock(&state.mutex);
                state.bytes[@intCast(index)] = @intCast(byte);
                std.Io.Threaded.mutexUnlock(&state.mutex);
            },
        }
    }
    pub fn cancelOperation(state: *State, selected: Lane) void {
        if (selected == .compute) cancel(state);
    }
    pub fn cancel(state: *State) void {
        std.Io.Threaded.mutexLock(&state.mutex);
        state.stopped = true;
        state.changed.broadcast(fixtureIo());
        std.Io.Threaded.mutexUnlock(&state.mutex);
    }
    pub fn deinit(state: *State) void {
        if (state.working) @panic("buffer destruction preceded native worker return");
        if (state.parent) |parent| _ = parent.buffers.fetchSub(1, .release);
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Buffer = ecl.Port(struct {
    const Base = BufferSpec;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const cancelOperation = Base.cancelOperation;
    pub const endpoints = .{};
    pub const operations = .{
        .compute = .{ .name = "compute", .doc = "Defer a checksum on a native worker until completion or cancellation.", .handler = on_compute, .lane = .compute, .endpoints = .{} },
        .complete_work = .{ .name = "complete-work", .doc = "Permit deferred work on the independent control lane.", .handler = on_complete_work, .lane = .control, .endpoints = .{} },
        .buffer_update = .{ .name = "buffer-update", .doc = "Apply a positioned buffer byte update.", .handler = on_buffer_update, .lane = .control, .endpoints = .{} },
    };
    fn on_compute(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Buffer, state, .compute, .compute, controller);
    }
    fn on_complete_work(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Buffer, state, .complete_work, .control, controller);
    }
    fn on_buffer_update(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Buffer, state, .buffer_update, .control, controller);
    }
});

const MultiplexSpec = struct {
    pub const name = "multiplex";
    pub const State = struct { channels: std.atomic.Value(u32) = .init(0) };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(comptime P: type, state: *State, comptime mode: MultiplexMode, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        switch (mode) {
            .channel => {
                try builder.input(&.{});
                try builder.child(Channel, .dependent);
                try builder.result();
            },
            .disconnect => {
                {
                    try builder.int(9);
                    try (try controller.endpoint(P, .event)).send();
                }
                controller.failResource(.io, "multiplexed connection disconnected");
            },
            .channel_count => {
                try builder.int(state.channels.load(.acquire));
                try builder.result();
            },
            .fatal_allocation_failure => {
                const order = (controller.input(&.{}) orelse return).int() orelse 0;
                if (order == 0) controller.failResource(.io, "device is unusable");
                controller.failOutOfMemory();
                controller.failResource(.io, "device is unusable");
            },
        }
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(state: *State) void {
        if (state.channels.load(.acquire) != 0) @panic("connection destruction preceded channel cleanup");
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Multiplex = ecl.Port(struct {
    const Base = MultiplexSpec;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const endpoints = .{
        .event = ecl.declarations.Endpoint{ .name = "disconnect-event", .doc = "Receive the final connection diagnostic.", .transport = .messages, .direction = .output, .owner = .exchange },
    };
    pub const operations = .{
        .channel = .{ .name = "channel", .doc = "Open a dependent channel with an opaque identity.", .handler = on_channel, .lane = .operation, .endpoints = .{} },
        .disconnect = .{ .name = "disconnect", .doc = "Fail the connection after emitting its final diagnostic.", .handler = on_disconnect, .lane = .operation, .endpoints = .{.event} },
        .channel_count = .{ .name = "channel-count", .doc = "Observe live dependent channels.", .handler = on_channel_count, .lane = .operation, .endpoints = .{} },
        .fatal_allocation_failure = .{ .name = "fatal-allocation-failure", .doc = "Preserve allocation exhaustion while retiring the resource.", .handler = on_fatal_allocation_failure, .lane = .operation, .endpoints = .{} },
    };
    fn on_channel(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Multiplex, state, .channel, .operation, controller);
    }
    fn on_disconnect(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Multiplex, state, .disconnect, .operation, controller);
    }
    fn on_channel_count(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Multiplex, state, .channel_count, .operation, controller);
    }
    fn on_fatal_allocation_failure(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Multiplex, state, .fatal_allocation_failure, .operation, controller);
    }
});
const ChannelBackend = struct {
    pub const name = "channel";
    pub const Lane = enum(u32) { operation };
    pub const cancellation: ecl.PortCancellation = .acknowledge;
    pub const State = struct { parent: ?*Multiplex.StateType = null, id: i64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        const parent = controller.parent(Multiplex) orelse return controller.fail(.domain, "channel requires a connection parent");
        const id = (controller.input(&.{}) orelse return).int() orelse return controller.fail(.type, "expected channel id");
        state.* = .{ .parent = parent, .id = id };
        _ = parent.channels.fetchAdd(1, .release);
    }
    pub fn run(comptime P: type, state: *State, comptime _: P.LaneType, controller: *ecl.Controller) ecl.ControllerError!void {
        defer if (controller.cancelled()) {
            _ = controller.acknowledgeCancellation();
        };
        const builder = controller.builder();
        while ((try (try controller.endpoint(P, .input)).receive() != null)) {
            _ = entered.fetchAdd(1, .release);
            {
                try builder.symbol("channel");
                try builder.int(state.id);
                try builder.symbol("payload");
                try builder.received(&.{});
                try controller.discardMessage();
                try builder.dictionary(2);
                try (try controller.endpoint(P, .output)).send();
            }
        }
    }
    pub fn cancelOperation(_: *State, _: Lane) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(state: *State) void {
        if (state.parent) |parent| _ = parent.channels.fetchSub(1, .release);
        _ = cleaned.fetchAdd(1, .release);
    }
};
const Channel = ecl.Port(struct {
    const Base = ChannelBackend;
    pub const name = Base.name;
    pub const State = Base.State;
    pub const Lane = if (@hasDecl(Base, "Lane")) Base.Lane else enum { operation };
    pub const cancellation = if (@hasDecl(Base, "cancellation")) Base.cancellation else ecl.PortCancellation.close_resource;
    pub const init = Base.init;
    pub const open = Base.open;
    pub const cancel = Base.cancel;
    pub const deinit = Base.deinit;
    pub const cancelOperation = Base.cancelOperation;
    pub const endpoints = .{
        .input = ecl.declarations.Endpoint{ .name = "channel-input", .doc = "Send a complete message on one channel.", .transport = .messages, .direction = .input, .owner = .exchange },
        .output = ecl.declarations.Endpoint{ .name = "channel-output", .doc = "Receive complete messages tagged with their channel.", .transport = .messages, .direction = .output, .owner = .exchange },
    };
    pub const operations = .{
        .channel_stream = .{ .name = "channel-stream", .doc = "Stream complete channel messages until finish or cancellation.", .handler = on_channel_stream, .lane = .operation, .endpoints = .{ .input, .output } },
    };
    fn on_channel_stream(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try Base.run(Channel, state, .operation, controller);
    }
});

const Declared = ecl.Port(struct {
    pub const name = "declared";
    pub const State = u8;
    pub const Lane = enum { data, control };
    pub const endpoints = .{
        .@"declared-input" = ecl.declarations.Endpoint{ .doc = "Write declared input.", .transport = .bytes, .direction = .input },
        .@"declared-messages-in" = ecl.declarations.Endpoint{ .doc = "Send declared messages.", .transport = .messages, .direction = .input },
        .@"declared-messages-out" = ecl.declarations.Endpoint{ .doc = "Receive declared messages.", .transport = .messages, .direction = .output },
        .@"declared-shared-output" = ecl.declarations.Endpoint{ .doc = "Read shared resource output.", .transport = .bytes, .direction = .output, .owner = .resource },
        .@"declared-output" = ecl.declarations.Endpoint{ .doc = "Read declared output.", .transport = .bytes, .direction = .output },
    };
    pub const operations = .{
        .@"declared-byte-echo" = .{ .doc = "Echo complete byte writes.", .handler = byteEcho, .lane = .data, .endpoints = .{ .@"declared-input", .@"declared-output" } },
        .@"declared-message-echo" = .{ .doc = "Forward whole messages.", .handler = messageEcho, .lane = .data, .endpoints = .{ .@"declared-messages-in", .@"declared-messages-out" } },
        .@"declared-publish" = .{ .doc = "Publish one built message.", .handler = publish, .lane = .data, .endpoints = .{.@"declared-messages-out"} },
        .@"declared-first" = .{ .doc = "Write the first contiguous resource slice.", .handler = first, .lane = .data, .endpoints = .{} },
        .@"declared-second" = .{ .doc = "Write the second contiguous resource slice.", .handler = second, .lane = .control, .endpoints = .{} },
        .@"declared-result" = .{ .doc = "Return the request through a named handler.", .handler = result, .lane = .data, .endpoints = .{} },
        .@"declared-stream" = .{ .doc = "Write to a declared exchange endpoint.", .handler = stream, .lane = .data, .endpoints = .{.@"declared-output"} },
    };
    pub fn init() State {
        return 0;
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    fn result(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        try controller.builder().input(&.{});
        try controller.builder().result();
    }
    fn stream(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const output = try controller.endpoint(Declared, .@"declared-output");
        try output.write(&.{ 40, 41, 42 });
        try output.finish();
    }
    fn byteEcho(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const input = try controller.endpoint(Declared, .@"declared-input");
        const output = try controller.endpoint(Declared, .@"declared-output");
        var bytes: [8]u8 = undefined;
        while (try input.read(&bytes)) |count| try output.write(bytes[0..count]);
        try output.finish();
    }
    fn messageEcho(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const input = try controller.endpoint(Declared, .@"declared-messages-in");
        const output = try controller.endpoint(Declared, .@"declared-messages-out");
        while (try input.receive()) |_| try output.forward();
        try output.finish();
    }
    fn publish(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const output = try controller.endpoint(Declared, .@"declared-messages-out");
        {
            try controller.builder().input(&.{});
        }
        try output.send();
        try output.finish();
    }
    fn first(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const output = try controller.endpoint(Declared, .@"declared-shared-output");
        try output.write(&.{ 40, 41, 42 });
    }
    fn second(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const output = try controller.endpoint(Declared, .@"declared-shared-output");
        try output.write(&.{ 50, 51, 52 });
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {
        _ = cleaned.fetchAdd(1, .release);
    }
});

pub const Extension = extension: {
    @setEvalBranchQuota(20_000);
    break :extension ecl.module(.{
        .name = @import("port_fixture_options").module_name,
        .doc = "Hermetic native port controller fixture.",
        .ports = .{ Counter, Other, Duplex, Unacknowledged, Storage, Cursor, TransactionPort, Broker, Delivery, Device, Buffer, Multiplex, Channel, Declared },
        .words = .{
            ecl.factory("declared", "Open a port with named declarations.", Declared),

            ecl.factory("counter", "Open a single-lane counter.", Counter),

            ecl.factory("other", "Open a distinct counter kind.", Other),

            ecl.factory("unrecoverable", "Open a resource that refuses cancellation recovery.", Unacknowledged),

            ecl.word("signal-waiting", "Mark a caller's checkpoint before bounded admission.", signalWaiting),
            ecl.factory("multiplex", "Open a deterministic multiplexed connection.", Multiplex),

            ecl.factory("device", "Open a deterministic native compute device.", Device),

            ecl.factory("broker", "Open a deterministic broker session.", Broker),

            ecl.factory("storage", "Open a deterministic storage session.", Storage),

            ecl.factory("orphan-cursor", "Reject cursor initialization without its native parent.", Cursor),

            ecl.factory("factory", "Create an independently scheduled duplex resource.", Duplex),

            ecl.word("fail-next", "Fail the next initialization.", failNext),
            ecl.word("block-next", "Block the next initialization.", blockNext),
            ecl.word("unblock", "Release one blocked controller.", unblock),
            ecl.word("reset", "Reset observations between isolated fixture runs.", reset),
            ecl.word("await-blocked", "Wait for controller gate entries.", awaitCounter(&entered).run),
            ecl.word("await-waiting", "Wait for admission pressure.", awaitCounter(&waiting).run),
            ecl.word("await-cleaned", "Wait for cleanup callbacks.", awaitCounter(&cleaned).run),
            ecl.word("shutdowns", "Observe graceful callbacks.", shutdownCount),
            ecl.word("cleaned", "Observe completed cleanup.", cleanupCount),
            ecl.word("fail-long", "Report a bounded UTF-8 word error.", failLong),
        },
    });
};
comptime {
    _ = Extension;
}
