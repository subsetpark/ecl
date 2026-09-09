//! Typed native resource declarations and host-owned controller exchanges.
const abi = @import("ecl-native-abi");
const capability = @import("capability.zig");

const declarations = @import("port-declarations");
pub const Cancellation = declarations.Cancellation;

const ControllerState = struct { table: *const abi.ControllerTable, context: *anyopaque, input_view: abi.ValueView = .{ .kind = .list } };
pub const ControllerError = declarations.ControllerError;

fn require(status: abi.ControllerStatus) ControllerError!void {
    return switch (status) {
        .ok => {},
        .cancelled => error.Cancelled,
        .failed => error.Failed,
        .out_of_memory => error.OutOfMemory,
        .eof, .invalid => error.InvalidValue,
        _ => error.InvalidValue,
    };
}

/// A borrowed controller endpoint has a statically fixed issuer, owner and
/// direction. Its opaque context expires when the invoking controller returns.
/// Acquiring it validates the issuing resource and operation endpoint set.
pub fn Endpoint(comptime P: type, comptime endpoint_name: P.Endpoints.Name) type {
    const spec = P.Endpoints.get(endpoint_name);
    const id = P.Endpoints.id(endpoint_name);
    const owner: abi.EndpointOwner = switch (spec.owner) {
        .resource => .resource,
        .exchange => .exchange,
    };
    const Access = struct {
        fn state(raw: *anyopaque) *ControllerState {
            return @ptrCast(@alignCast(raw));
        }
        fn finish(raw: *anyopaque) ControllerError!void {
            const owned = state(raw);
            if (!owned.table.finish_endpoint(owned.context, owner, id)) return error.InvalidValue;
        }
    };
    if (spec.transport == .bytes) {
        return switch (spec.direction) {
            .input => opaque {
                pub fn read(self: *@This(), bytes: []u8) ControllerError!?usize {
                    if (bytes.len == 0) return error.InvalidValue;
                    const owned = Access.state(self);
                    const result = owned.table.read_bytes(owned.context, owner, id, bytes.ptr, @intCast(@min(bytes.len, 64 * 1024)));
                    if (result.status == .eof) return null;
                    try require(result.status);
                    return result.count;
                }
            },
            .output => opaque {
                /// Success accepts the complete slice. Failure may leave an
                /// accepted prefix; callers must not automatically retry it.
                pub fn write(self: *@This(), bytes: []const u8) ControllerError!void {
                    const owned = Access.state(self);
                    try require(owned.table.write_bytes(owned.context, owner, id, bytes.ptr, bytes.len));
                }
                pub fn finish(self: *@This()) ControllerError!void {
                    try Access.finish(self);
                }
            },
        };
    }
    return switch (spec.direction) {
        .input => opaque {
            /// Append a reply sender to the current builder. The capability
            /// cannot grant output or completion authority.
            pub fn reply(self: *@This()) ControllerError!void {
                const controller: *Controller = @ptrCast(self);
                try controller.builder().apply(.{ .action = .reply_endpoint, .owner = owner, .endpoint = id });
            }
            /// Success owns one message in the controller's received slot;
            /// null is stable EOF. An unconsumed message rejects another read.
            pub fn receive(self: *@This()) ControllerError!?*const MessageView {
                const owned = Access.state(self);
                const result = owned.table.receive_event(owned.context, owner, id);
                if (result == .eof) return null;
                try require(result);
                const controller: *Controller = @ptrCast(self);
                return controller.received(&.{}) orelse error.InvalidValue;
            }
        },
        .output => opaque {
            /// Consumes this controller's completed builder only on success.
            pub fn send(self: *@This()) ControllerError!void {
                const controller: *Controller = @ptrCast(self);
                const builder = controller.builder();
                try builder.apply(.{ .action = .send, .owner = owner, .endpoint = id });
            }
            /// Consumes the current received message only on success.
            pub fn forward(self: *@This()) ControllerError!void {
                const owned = Access.state(self);
                if (!owned.table.forward_message(owned.context, owner, id))
                    return if (owned.table.cancelled(owned.context)) error.Cancelled else error.Failed;
            }
            pub fn finish(self: *@This()) ControllerError!void {
                try Access.finish(self);
            }
        },
    };
}

/// Controller-local read-only view. Borrowed text and this view last until the
/// next view lookup or controller return. Port values expose only their kind.
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
    fn apply(self: *MessageBuilder, request: abi.MessageBuildRequest) ControllerError!void {
        const owned = self.state();
        switch (owned.table.build_message(owned.context, &request)) {
            .ok => return,
            .out_of_memory => return error.OutOfMemory,
            else => return if (owned.table.cancelled(owned.context)) error.Cancelled else error.Failed,
        }
    }
    pub fn int(self: *MessageBuilder, item: i64) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.int(item).wire });
    }
    pub fn float(self: *MessageBuilder, item: f64) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.float(item).wire });
    }
    pub fn char(self: *MessageBuilder, item: u32) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.char(item).wire });
    }
    pub fn symbol(self: *MessageBuilder, bytes: []const u8) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.symbol(bytes).wire });
    }
    pub fn input(self: *MessageBuilder, path: []const u64) ControllerError!void {
        if (path.len > abi.max_read_path_depth) return error.InvalidValue;
        return self.apply(.{ .action = .copy_input, .path = path.ptr, .depth = @intCast(path.len) });
    }
    pub fn received(self: *MessageBuilder, path: []const u64) ControllerError!void {
        if (path.len > abi.max_read_path_depth) return error.InvalidValue;
        return self.apply(.{ .action = .copy_received, .path = path.ptr, .depth = @intCast(path.len) });
    }
    /// Consume the completed configuration and replace it with a new resource.
    /// Success leaves that child provisionally owned by this exchange until
    /// ECL claims its result/message. Failure retains the configuration and
    /// the host cleans up any failed child. Dependent children close and join
    /// before their issuing parent's backend is destroyed; scope transfer
    /// never detaches that dependency.
    pub fn child(self: *MessageBuilder, comptime P: type, dependency: enum { independent, dependent }) ControllerError!void {
        if (!@hasDecl(P, "ecl_port_marker")) @compileError("ecl-native: child requires a declared Port type");
        return self.apply(.{
            .action = .child,
            .kind_identity = P.kindIdentity(),
            .count = @intFromEnum(switch (dependency) {
                .independent => abi.ChildDependency.independent,
                .dependent => abi.ChildDependency.dependent,
            }),
        });
    }
    pub fn list(self: *MessageBuilder, count: u32) ControllerError!void {
        return self.apply(.{ .action = .list, .count = count });
    }
    pub fn dictionary(self: *MessageBuilder, pairs: u32) ControllerError!void {
        return self.apply(.{ .action = .dictionary, .count = pairs });
    }
    pub fn result(self: *MessageBuilder) ControllerError!void {
        return self.apply(.{ .action = .result });
    }
    pub fn clear(self: *MessageBuilder) ControllerError!void {
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
    pub fn endpoint(self: *Controller, comptime P: type, comptime endpoint_name: P.Endpoints.Name) ControllerError!*Endpoint(P, endpoint_name) {
        const spec = P.Endpoints.get(endpoint_name);
        const owned = self.state();
        if (!owned.table.resolve_endpoint(owned.context, P.kindIdentity(), switch (spec.owner) {
            .resource => .resource,
            .exchange => .exchange,
        }, P.Endpoints.id(endpoint_name), switch (spec.transport) {
            .bytes => .bytes,
            .messages => .messages,
        }, switch (spec.direction) {
            .input => .input,
            .output => .output,
        }))
            return error.InvalidValue;
        return @ptrCast(self);
    }
    /// Borrow the issuing parent's native state when this resource was
    /// created as its dependent child. A root, independent child, or wrong
    /// parent kind returns null. The borrow lasts through child cleanup;
    /// native code must synchronize shared access across controller lanes.
    /// No ECL value, heap, allocator, or interpreter authority is exposed.
    pub fn parent(self: *Controller, comptime P: type) ?*P.StateType {
        comptime if (!@hasDecl(P, "ecl_port_marker")) @compileError("ecl-native: parent requires a declared Port type");
        const owned = self.state();
        const pointer = owned.table.parent_state(owned.context, P.kindIdentity()) orelse return null;
        return @ptrCast(@alignCast(pointer));
    }
    /// Borrowed view of the owned received message; the next view lookup
    /// invalidates this view. Message ownership is unchanged.
    pub fn received(self: *Controller, path: []const u64) ?*const MessageView {
        if (path.len > abi.max_read_path_depth) return null;
        const owned = self.state();
        if (!owned.table.received_message(owned.context, path.ptr, @intCast(path.len), &owned.input_view)) return null;
        return @ptrCast(&owned.input_view);
    }
    /// Success consumes the received message into the terminal result; failure
    /// retains it. Completion is still determined by controller return.
    pub fn resultMessage(self: *Controller) ControllerError!void {
        const owned = self.state();
        if (!owned.table.result_message(owned.context)) return if (self.cancelled()) error.Cancelled else error.Failed;
    }
    /// Success consumes the received message and expires its borrowed views.
    /// InvalidValue means no message was held. Builder copies retain their own values.
    pub fn discardMessage(self: *Controller) ControllerError!void {
        const owned = self.state();
        if (!owned.table.discard_message(owned.context)) return error.InvalidValue;
    }
    /// Read configuration during open, or structured parameters during run.
    /// Dictionary positions alternate key/value. Paths have at most 64 entries.
    pub fn input(self: *Controller, path: []const u64) ?*const MessageView {
        if (path.len > abi.max_read_path_depth) return null;
        const owned = self.state();
        if (!owned.table.input(owned.context, path.ptr, @intCast(path.len), &owned.input_view)) return null;
        return @ptrCast(&owned.input_view);
    }
    pub fn cancelled(self: *Controller) bool {
        return self.state().table.cancelled(self.state().context);
    }
    /// Acknowledge that an interrupted operation has restored reusable backend
    /// state. The lane remains occupied until its handler returns. False means the
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
    /// Fail this invocation and retire its resource after controller return.
    /// The failed exchange retains its accepted output and terminal error;
    /// outstanding operations and dependent children are then interrupted.
    /// Native backend work must still be joined before returning. This does
    /// not synchronously join the resource from its own controller.
    pub fn failResource(self: *Controller, kind: capability.ErrorKind, message: []const u8) void {
        const bounded = capability.boundedErrorMessage(message);
        const owned = self.state();
        owned.table.fail_resource(owned.context, kind, bounded.ptr, @intCast(bounded.len));
    }
};

/// `init` constructs bounded initial state before publication. `open` precedes
/// all lane runs, and `deinit` follows their completion. Runs in distinct lanes
/// may overlap; same-lane runs are FIFO. `cancel` may run concurrently
/// with `open` or an operation handler: it must be bounded, thread-safe, and interrupt backend
/// waits. Optional `shutdown` runs independently of operation lanes, stops new
/// admission, and is joined before `deinit`. It may race operation handlers and `cancel`;
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
        if (cancellation == .acknowledge and (!@hasDecl(Spec, "cancelOperation") or @TypeOf(Spec.cancelOperation) != fn (*Spec.State, Lane) void))
            @compileError("ecl-native: recoverable cancellation requires fn cancelOperation(*State, Lane) void");
        if (@hasDecl(Spec, "shutdown") and @TypeOf(Spec.shutdown) != fn (*Spec.State, *Controller) void)
            @compileError("ecl-native: shutdown requires fn (*State, *Controller) void");
        for (.{ "State", "name", "init", "open", "cancel", "deinit" }) |name|
            if (!@hasDecl(Spec, name)) @compileError("ecl-native: Port spec requires State, name, init, open, cancel, and deinit");
        if (@sizeOf(Spec.State) == 0 or @sizeOf(Spec.State) > abi.max_port_state_bytes or @alignOf(Spec.State) > 64)
            @compileError("ecl-native: Port State exceeds the supported size or alignment");
        if (@TypeOf(Spec.init) != fn () Spec.State or
            @TypeOf(Spec.open) != fn (*Spec.State, *Controller) void or
            @TypeOf(Spec.cancel) != fn (*Spec.State) void or
            @TypeOf(Spec.deinit) != fn (*Spec.State) void)
            @compileError("ecl-native: Port callbacks have invalid signatures");
    }
    const DeclaredEndpoints = declarations.Endpoints(if (@hasDecl(Spec, "endpoints")) Spec.endpoints else .{});
    const DeclaredOperations = declarations.Operations(Lane, DeclaredEndpoints, if (@hasDecl(Spec, "operations")) Spec.operations else .{});
    comptime {
        for (@import("std").meta.tags(DeclaredOperations.Name)) |name| {
            if (@TypeOf(DeclaredOperations.get(name).handler) != fn (*Spec.State, *Controller) void and
                @TypeOf(DeclaredOperations.get(name).handler) != fn (*Spec.State, *Controller) ControllerError!void)
                @compileError("port: handler must accept resource state and controller");
        }
    }
    return opaque {
        pub const Endpoints = declarations.Endpoints(if (@hasDecl(Spec, "endpoints")) Spec.endpoints else .{});
        pub const Operations = declarations.Operations(Lane, Endpoints, if (@hasDecl(Spec, "operations")) Spec.operations else .{});
        pub const ecl_port_marker = void;
        pub const StateType = Spec.State;
        pub const LaneType = Lane;
        pub const name = Spec.name;
        // A mutable object's address supplies nominal identity even when two
        // specs have identical names or the linker folds identical callbacks.
        var kind_identity: u8 = 0;
        fn kindIdentity() *const anyopaque {
            return &kind_identity;
        }
        pub fn definition() abi.PortDefinition {
            return .{ .state_size = @sizeOf(Spec.State), .state_alignment = @alignOf(Spec.State), .name_ptr = name.ptr, .name_len = name.len, .init_state = initState, .initialize = initialize, .execute = execute, .cancel = cancelState, .cleanup = cleanup, .lane_count = @typeInfo(Lane).@"enum".fields.len, .cancellation = switch (cancellation) {
                .close_resource => .close_resource,
                .acknowledge => .acknowledge,
            }, .cancel_operation = if (cancellation == .acknowledge) cancelOperation else null, .shutdown = if (@hasDecl(Spec, "shutdown")) shutdown else null, .identity = kindIdentity() };
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
            inline for (comptime @import("std").meta.tags(Operations.Name)) |operation_name| {
                if (operation == @intFromEnum(operation_name)) {
                    const handler = Operations.get(operation_name).handler;
                    if (@typeInfo(@TypeOf(handler)).@"fn".return_type.? == void) {
                        handler(@ptrCast(@alignCast(raw)), @ptrCast(&state));
                    } else handler(@ptrCast(@alignCast(raw)), @ptrCast(&state)) catch |err| {
                        const controller: *Controller = @ptrCast(&state);
                        switch (err) {
                            error.Cancelled => if (!controller.cancelled()) controller.fail(.contract, "controller reported cancellation without a request"),
                            error.OutOfMemory => controller.failOutOfMemory(),
                            error.Failed => controller.fail(.io, "port controller transport failed"),
                            error.InvalidValue => controller.fail(.contract, "invalid controller capability or value"),
                        }
                    };
                    return;
                }
            }
            const controller: *Controller = @ptrCast(&state);
            controller.fail(.contract, "unsupported registered operation");
        }
        fn cancelState(raw: *anyopaque) callconv(.c) void {
            Spec.cancel(@ptrCast(@alignCast(raw)));
        }
        fn cleanup(raw: *anyopaque) callconv(.c) void {
            Spec.deinit(@ptrCast(@alignCast(raw)));
        }
    };
}
