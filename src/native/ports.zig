//! Typed native resource declarations and invocation-local port operations.
const abi = @import("ecl-native-abi");
const capability = @import("capability.zig");

pub const Cancellation = enum { close_resource, acknowledge };

pub const Progress = union(enum) { ready, pending, failed, candidate: capability.Candidate, bytes: u32 };
pub const Interests = packed struct(u32) { readable: bool = true, writable: bool = true, reserved: u30 = 0 };

pub const ControllerState = struct { table: *const abi.ControllerTable, context: *anyopaque, input_view: abi.ValueView = .{ .kind = .list } };

/// Controller-local read-only view. Borrowed text and this view last until the
/// next input lookup or controller return. Port values expose only their kind.
pub const MessageView = opaque {
    fn wire(self: *const MessageView) *const abi.ValueView {
        return @ptrCast(@alignCast(self));
    }
    pub fn kind(self: *const MessageView) abi.ValueKindWire {
        return self.wire().kind;
    }
    pub fn int(self: *const MessageView) ?i64 {
        return if (self.kind() == .int) @bitCast(self.wire().scalar_bits) else null;
    }
    pub fn float(self: *const MessageView) ?f64 {
        return if (self.kind() == .float) @bitCast(self.wire().scalar_bits) else null;
    }
    pub fn char(self: *const MessageView) ?u21 {
        return if (self.kind() == .char) @intCast(self.wire().scalar_bits) else null;
    }
    pub fn symbol(self: *const MessageView) ?[]const u8 {
        if (self.kind() != .symbol) return null;
        return self.wire().bytes_ptr.?[0..@intCast(self.wire().bytes_len)];
    }
    pub fn length(self: *const MessageView) ?u64 {
        return switch (self.kind()) {
            .list, .dict => self.wire().aggregate_len,
            else => null,
        };
    }
};

/// A controller-local construction stack. Scalars append values; list and
/// dictionary replace the last values with one aggregate. Methods finish their
/// bounded host steps without entering ECL. Borrowed input/text lasts through
/// the method call. A failed send/result retains the finished message; success
/// consumes it and leaves the builder empty. Controller return discards it.
pub const MessageBuilder = opaque {
    fn state(self: *MessageBuilder) *ControllerState {
        return @ptrCast(@alignCast(self));
    }
    fn apply(self: *MessageBuilder, request: abi.MessageBuildRequest) bool {
        const owned = self.state();
        var status = owned.table.build_message(owned.context, &request);
        while (status == .yield_required) {
            if (owned.table.cancelled(owned.context)) return false;
            status = owned.table.build_message(owned.context, &.{ .action = .advance });
        }
        return status == .ok;
    }
    pub fn int(self: *MessageBuilder, item: i64) bool {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.int(item).wire });
    }
    pub fn float(self: *MessageBuilder, item: f64) bool {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.float(item).wire });
    }
    pub fn char(self: *MessageBuilder, item: u32) bool {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.char(item).wire });
    }
    pub fn symbol(self: *MessageBuilder, bytes: []const u8) bool {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.symbol(bytes).wire });
    }
    pub fn input(self: *MessageBuilder, path: []const u64) bool {
        if (path.len > abi.max_read_path_depth) return false;
        return self.apply(.{ .action = .copy_input, .path = path.ptr, .depth = @intCast(path.len) });
    }
    pub fn received(self: *MessageBuilder, path: []const u64) bool {
        if (path.len > abi.max_read_path_depth) return false;
        return self.apply(.{ .action = .copy_received, .path = path.ptr, .depth = @intCast(path.len) });
    }
    /// Append an attenuated sender for a declared message input. ECL may use
    /// it to reply; retaining it does not extend the exchange's scope lifetime.
    pub fn replyEndpoint(self: *MessageBuilder, endpoint: u6) bool {
        return self.apply(.{ .action = .reply_endpoint, .endpoint = endpoint });
    }
    pub fn list(self: *MessageBuilder, count: u32) bool {
        return self.apply(.{ .action = .list, .count = count });
    }
    pub fn dictionary(self: *MessageBuilder, pairs: u32) bool {
        return self.apply(.{ .action = .dictionary, .count = pairs });
    }
    pub fn send(self: *MessageBuilder, endpoint: u6) bool {
        return self.apply(.{ .action = .finish }) and self.apply(.{ .action = .send, .endpoint = endpoint });
    }
    pub fn sendResource(self: *MessageBuilder, endpoint: u6) bool {
        return self.apply(.{ .action = .finish }) and self.apply(.{ .action = .send, .endpoint = endpoint, .owner = .resource });
    }
    pub fn result(self: *MessageBuilder) bool {
        return self.apply(.{ .action = .finish }) and self.apply(.{ .action = .result });
    }
    pub fn clear(self: *MessageBuilder) bool {
        return self.apply(.{ .action = .clear });
    }
};

/// Available only on the controller. Streams may block this private thread;
/// cancellation interrupts host stream waits. No ECL values are accessible.
pub const Controller = opaque {
    fn state(self: *Controller) *ControllerState {
        return @ptrCast(@alignCast(self));
    }
    pub fn builder(self: *Controller) *MessageBuilder {
        return @ptrCast(self);
    }
    /// Own the next complete message until forwarding, returning it as the
    /// result, or controller return. Refuses to discard an unconsumed message.
    pub fn receiveMessage(self: *Controller, endpoint: u6) bool {
        const owned = self.state();
        return owned.table.receive_message(owned.context, .exchange, endpoint);
    }
    /// Borrowed view of the owned received message; the next view lookup
    /// invalidates this view. Message ownership is unchanged.
    pub fn received(self: *Controller, path: []const u64) ?*const MessageView {
        if (path.len > abi.max_read_path_depth) return null;
        const owned = self.state();
        if (!owned.table.received_message(owned.context, path.ptr, @intCast(path.len), &owned.input_view)) return null;
        return @ptrCast(&owned.input_view);
    }
    /// Success consumes the received message into the output queue. Failure
    /// retains it for retry or automatic cleanup at controller return.
    pub fn forwardMessage(self: *Controller, endpoint: u6) bool {
        const owned = self.state();
        return owned.table.forward_message(owned.context, .exchange, endpoint);
    }
    /// Success consumes the received message into the terminal result; failure
    /// retains it. Completion is still determined by controller return.
    pub fn resultMessage(self: *Controller) bool {
        const owned = self.state();
        return owned.table.result_message(owned.context);
    }
    /// Read configuration during open, or structured parameters during run.
    /// Dictionary positions alternate key/value. Paths have at most 64 entries.
    pub fn input(self: *Controller, path: []const u64) ?*const MessageView {
        if (path.len > abi.max_read_path_depth) return null;
        const owned = self.state();
        if (!owned.table.input(owned.context, path.ptr, @intCast(path.len), &owned.input_view)) return null;
        return @ptrCast(&owned.input_view);
    }
    pub fn readResourceFrom(self: *Controller, endpoint: u6, bytes: []u8) usize {
        const owned = self.state();
        return owned.table.read_endpoint(owned.context, .resource, endpoint, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn writeResourceTo(self: *Controller, endpoint: u6, bytes: []const u8) usize {
        const owned = self.state();
        return owned.table.write_endpoint(owned.context, .resource, endpoint, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn finishResourceOutput(self: *Controller, endpoint: u6) bool {
        const owned = self.state();
        return owned.table.finish_endpoint(owned.context, .resource, endpoint);
    }
    pub fn receiveResourceMessage(self: *Controller, endpoint: u6) bool {
        const owned = self.state();
        return owned.table.receive_message(owned.context, .resource, endpoint);
    }
    pub fn forwardResourceMessage(self: *Controller, endpoint: u6) bool {
        const owned = self.state();
        return owned.table.forward_message(owned.context, .resource, endpoint);
    }
    pub fn read(self: *Controller, bytes: []u8) usize {
        const state_value = self.state();
        return state_value.table.read(state_value.context, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn readFrom(self: *Controller, endpoint: u6, bytes: []u8) usize {
        const owned = self.state();
        return owned.table.read_endpoint(owned.context, .exchange, endpoint, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn writeTo(self: *Controller, endpoint: u6, bytes: []const u8) usize {
        const owned = self.state();
        return owned.table.write_endpoint(owned.context, .exchange, endpoint, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn finishOutput(self: *Controller, endpoint: u6) bool {
        const owned = self.state();
        return owned.table.finish_endpoint(owned.context, .exchange, endpoint);
    }
    pub fn write(self: *Controller, bytes: []const u8) usize {
        const state_value = self.state();
        return state_value.table.write(state_value.context, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn cancelled(self: *Controller) bool {
        return self.state().table.cancelled(self.state().context);
    }
    /// Acknowledge that an interrupted operation has restored reusable backend
    /// state. The lane remains occupied until run returns. False means the
    /// resource is closing, or this invocation has no recoverable cancellation.
    pub fn acknowledgeCancellation(self: *Controller) bool {
        const value = self.state();
        return value.table.acknowledge_cancellation(value.context);
    }
    /// Report allocation exhaustion as the runtime OOM outcome. It remains
    /// observable through completion and endpoints, and cleanup still joins.
    pub fn failOutOfMemory(self: *Controller) void {
        const owned = self.state();
        owned.table.fail_allocation(owned.context);
    }
    pub fn fail(self: *Controller, kind: capability.ErrorKind, message: []const u8) void {
        const bounded = capability.boundedErrorMessage(message);
        self.state().table.fail(self.state().context, kind, bounded.ptr, @intCast(bounded.len));
    }
};

pub const Adapter = struct { invocation: *capability.Invocation, definition: u32 };

/// `init` constructs bounded initial state before publication. `open` precedes
/// all lane runs, and `deinit` follows their completion. Runs in distinct lanes
/// may overlap; same-lane runs are FIFO. `cancel` may run concurrently
/// with `open` or `run`: it must be bounded, thread-safe, and interrupt backend
/// waits. Optional `shutdown` runs independently of operation lanes, stops new
/// admission, and is joined before `deinit`. It may race `run` and `cancel`;
/// cancellation must interrupt its waits too. Cleanup runs even when `open` fails.
pub fn Port(comptime Spec: type) type {
    const Lane = if (@hasDecl(Spec, "Lane")) Spec.Lane else enum { operation };
    const cancellation: Cancellation = if (@hasDecl(Spec, "cancellation")) Spec.cancellation else .close_resource;
    comptime {
        if (@typeInfo(Lane) != .@"enum") @compileError("ecl-native: Port Lane must be an enum");
        const info = @typeInfo(Lane).@"enum";
        if (!info.is_exhaustive or info.fields.len == 0 or info.fields.len > abi.max_port_lanes)
            @compileError("ecl-native: Port Lane must declare 1 to 16 exhaustive lanes");
        for (info.fields, 0..) |field, index| if (field.value != index)
            @compileError("ecl-native: Port Lane values must be contiguous from zero");
        if (@hasDecl(Spec, "Lane") and (!@hasDecl(Spec, "lane") or @TypeOf(Spec.lane) != fn (u32) Lane))
            @compileError("ecl-native: Port lanes require fn lane(u32) Lane");
        if (cancellation == .acknowledge and (!@hasDecl(Spec, "cancelOperation") or @TypeOf(Spec.cancelOperation) != fn (*Spec.State, Lane) void))
            @compileError("ecl-native: recoverable cancellation requires fn cancelOperation(*State, Lane) void");
        if (@hasDecl(Spec, "shutdown") and @TypeOf(Spec.shutdown) != fn (*Spec.State, *Controller) void)
            @compileError("ecl-native: shutdown requires fn (*State, *Controller) void");
        for (.{ "State", "name", "init", "open", "run", "cancel", "deinit" }) |name|
            if (!@hasDecl(Spec, name)) @compileError("ecl-native: Port spec requires State, name, init, open, run, cancel, and deinit");
        if (@sizeOf(Spec.State) == 0 or @sizeOf(Spec.State) > abi.max_port_state_bytes or @alignOf(Spec.State) > 64)
            @compileError("ecl-native: Port State exceeds the supported size or alignment");
        if (@TypeOf(Spec.init) != fn () Spec.State or
            @TypeOf(Spec.open) != fn (*Spec.State, *Controller) void or
            @TypeOf(Spec.run) != fn (*Spec.State, u32, *Controller) void or
            @TypeOf(Spec.cancel) != fn (*Spec.State) void or
            @TypeOf(Spec.deinit) != fn (*Spec.State) void)
            @compileError("ecl-native: Port callbacks have invalid signatures");
    }
    return opaque {
        const Self = @This();
        pub const ecl_port_marker = void;
        pub const LaneType = Lane;
        pub const name = Spec.name;
        fn adapter(self: *Self) *Adapter {
            return @ptrCast(@alignCast(self));
        }
        pub fn definition() abi.PortDefinition {
            return .{ .state_size = @sizeOf(Spec.State), .state_alignment = @alignOf(Spec.State), .name_ptr = name.ptr, .name_len = name.len, .init_state = initState, .initialize = initialize, .execute = execute, .cancel = cancelState, .cleanup = cleanup, .lane_count = @typeInfo(Lane).@"enum".fields.len, .cancellation = switch (cancellation) {
                .close_resource => .close_resource,
                .acknowledge => .acknowledge,
            }, .select_lane = selectLane, .cancel_operation = if (cancellation == .acknowledge) cancelOperation else null, .shutdown = if (@hasDecl(Spec, "shutdown")) shutdown else null };
        }
        fn selectLane(operation: u32) callconv(.c) u32 {
            return if (@hasDecl(Spec, "Lane")) @intCast(@intFromEnum(Spec.lane(operation))) else 0;
        }
        fn cancelOperation(raw: *anyopaque, lane: u32) callconv(.c) void {
            Spec.cancelOperation(@ptrCast(@alignCast(raw)), @enumFromInt(lane));
        }
        fn initState(raw: *anyopaque) callconv(.c) void {
            const state: *Spec.State = @ptrCast(@alignCast(raw));
            state.* = Spec.init();
        }
        fn initialize(raw: *anyopaque, table: *const abi.ControllerTable, context: *anyopaque) callconv(.c) void {
            var state: ControllerState = .{ .table = table, .context = context };
            Spec.open(@ptrCast(@alignCast(raw)), @ptrCast(&state));
        }
        fn shutdown(raw: *anyopaque, table: *const abi.ControllerTable, context: *anyopaque) callconv(.c) void {
            var state: ControllerState = .{ .table = table, .context = context };
            Spec.shutdown(@ptrCast(@alignCast(raw)), @ptrCast(&state));
        }
        fn execute(raw: *anyopaque, operation: u32, table: *const abi.ControllerTable, context: *anyopaque) callconv(.c) void {
            var state: ControllerState = .{ .table = table, .context = context };
            Spec.run(@ptrCast(@alignCast(raw)), operation, @ptrCast(&state));
        }
        fn cancelState(raw: *anyopaque) callconv(.c) void {
            Spec.cancel(@ptrCast(@alignCast(raw)));
        }
        fn cleanup(raw: *anyopaque) callconv(.c) void {
            Spec.deinit(@ptrCast(@alignCast(raw)));
        }
        fn request(self: *Self, request_value: abi.PortRequest) error{OutOfMemory}!Progress {
            var reply: abi.PortReply = .{};
            const adapter_value = self.adapter();
            const status = (adapter_value.invocation.host.port orelse return .failed)(adapter_value.invocation.context, &request_value, &reply);
            if (status == .yield_required) return .pending;
            if (status == .out_of_memory) return error.OutOfMemory;
            if (status != .ok) return .failed;
            return switch (reply.status) {
                .pending => .pending,
                .failed => .failed,
                .ready => switch (request_value.action) {
                    .create, .export_exchange => .{ .candidate = @enumFromInt(reply.candidate) },
                    .read, .write => .{ .bytes = reply.transferred },
                    else => .ready,
                },
                _ => .failed,
            };
        }
        pub fn create(self: *Self, slot: u32) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .create, .definition = self.adapter().definition, .slot = slot });
        }
        pub fn check(self: *Self, port: capability.Candidate) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .check, .definition = self.adapter().definition, .port = @intFromEnum(port) });
        }
        pub fn begin(self: *Self, slot: u32, port: capability.Candidate, operation: u32) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .begin, .definition = self.adapter().definition, .slot = slot, .port = @intFromEnum(port), .operation = operation });
        }
        /// Offers an admitted exchange as an ordinary opaque value. Successful
        /// callback publication preserves scope ownership beyond this call;
        /// callback failure closes it and joins cancellation through its scope.
        pub fn exportExchange(self: *Self, slot: u32) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .export_exchange, .definition = self.adapter().definition, .slot = slot });
        }
        pub fn write(self: *Self, slot: u32, bytes: []const u8) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .write, .definition = self.adapter().definition, .slot = slot, .bytes = @constCast(bytes.ptr), .length = @intCast(@min(bytes.len, 64 * 1024)) });
        }
        pub fn read(self: *Self, slot: u32, bytes: []u8) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .read, .definition = self.adapter().definition, .slot = slot, .bytes = bytes.ptr, .length = @intCast(@min(bytes.len, 64 * 1024)) });
        }
        pub fn finishRequest(self: *Self, slot: u32) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .finish_request, .definition = self.adapter().definition, .slot = slot });
        }
        pub fn result(self: *Self, slot: u32) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .result, .definition = self.adapter().definition, .slot = slot });
        }
        /// Park on the requested stream directions (or terminal completion).
        /// Return `.yield` from the native callback after `.pending`.
        pub fn wait(self: *Self, slot: u32, interests: Interests) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .wait, .definition = self.adapter().definition, .slot = slot, .interests = @bitCast(interests) });
        }
        pub fn close(self: *Self, slot: u32, port: capability.Candidate) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .close, .definition = self.adapter().definition, .slot = slot, .port = @intFromEnum(port) });
        }
        pub fn release(self: *Self, slot: u32) error{OutOfMemory}!Progress {
            return self.request(.{ .action = .release, .definition = self.adapter().definition, .slot = slot });
        }
    };
}
