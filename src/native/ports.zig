//! Typed native resource declarations and invocation-local port operations.
const abi = @import("ecl-native-abi");
const capability = @import("capability.zig");

pub const Progress = union(enum) { ready, pending, failed, candidate: capability.Candidate, bytes: u32 };
pub const Interests = packed struct(u32) { readable: bool = true, writable: bool = true, reserved: u30 = 0 };

pub const ControllerState = struct { table: *const abi.ControllerTable, context: *anyopaque };

/// Available only on the controller. Streams may block this private thread;
/// cancellation interrupts host stream waits. No ECL values are accessible.
pub const Controller = opaque {
    fn state(self: *Controller) *ControllerState {
        return @ptrCast(@alignCast(self));
    }
    pub fn read(self: *Controller, bytes: []u8) usize {
        const state_value = self.state();
        return state_value.table.read(state_value.context, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn write(self: *Controller, bytes: []const u8) usize {
        const state_value = self.state();
        return state_value.table.write(state_value.context, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
    }
    pub fn cancelled(self: *Controller) bool {
        return self.state().table.cancelled(self.state().context);
    }
    pub fn fail(self: *Controller, kind: capability.ErrorKind, message: []const u8) void {
        const bounded = capability.boundedErrorMessage(message);
        self.state().table.fail(self.state().context, kind, bounded.ptr, @intCast(bounded.len));
    }
};

pub const Adapter = struct { invocation: *capability.Invocation, definition: u32 };

/// `init` constructs bounded initial state before publication. `open`, `run`,
/// and `deinit` execute on the private controller. `cancel` may run concurrently
/// with `open` or `run`: it must be bounded, thread-safe, and interrupt backend
/// waits. It never races `deinit`. Cleanup runs even when `open` fails.
pub fn Port(comptime Spec: type) type {
    comptime {
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
        pub const name = Spec.name;
        fn adapter(self: *Self) *Adapter {
            return @ptrCast(@alignCast(self));
        }
        pub fn definition() abi.PortDefinition {
            return .{ .state_size = @sizeOf(Spec.State), .state_alignment = @alignOf(Spec.State), .name_ptr = name.ptr, .name_len = name.len, .init_state = initState, .initialize = initialize, .execute = execute, .cancel = cancelState, .cleanup = cleanup };
        }
        fn initState(raw: *anyopaque) callconv(.c) void {
            const state: *Spec.State = @ptrCast(@alignCast(raw));
            state.* = Spec.init();
        }
        fn initialize(raw: *anyopaque, table: *const abi.ControllerTable, context: *anyopaque) callconv(.c) void {
            var state: ControllerState = .{ .table = table, .context = context };
            Spec.open(@ptrCast(@alignCast(raw)), @ptrCast(&state));
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
                    .create => .{ .candidate = @enumFromInt(reply.candidate) },
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
