//! Typed native resource declarations and host-owned controller exchanges.
const abi = @import("ecl-native-abi");
const capability = @import("capability.zig");

const declarations = @import("port-declarations");
pub const Cancellation = declarations.Cancellation;

const ControllerState = struct { table: *const abi.ControllerTable, context: *anyopaque, input_view: abi.ValueView = .{ .kind = .list } };
pub const ControllerError = declarations.ControllerError;
const ChildDependency = enum { independent, dependent };

fn childRequest(comptime P: type, dependency: ChildDependency) abi.MessageBuildRequest {
    if (!@hasDecl(P, "ecl_port_marker")) @compileError("ecl-native: child requires a declared Port type");
    return .{
        .action = .child,
        .kind_identity = P.kindIdentity(),
        .count = @intFromEnum(switch (dependency) {
            .independent => abi.ChildDependency.independent,
            .dependent => abi.ChildDependency.dependent,
        }),
    };
}

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
        return applyBuild(owned.table, owned.context, &request);
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
    pub fn child(self: *MessageBuilder, comptime P: type, dependency: ChildDependency) ControllerError!void {
        return self.apply(childRequest(P, dependency));
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
    pub fn instance(self: *Controller, comptime I: type) ?*I.State {
        const owned = self.state();
        return @ptrCast(@alignCast(owned.table.instance_state(owned.context, I.identity()) orelse return null));
    }
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
    /// Borrow the issuing parent's state only during initialization. This
    /// also permits an independent child to take independently owned native
    /// storage from its parent. Never retain this pointer after initialization;
    /// use parent() when the child requires a lifetime dependency instead.
    pub fn initializationParent(self: *Controller, comptime P: type) ?*P.StateType {
        comptime if (!@hasDecl(P, "ecl_port_marker")) @compileError("ecl-native: parent requires a declared Port type");
        const owned = self.state();
        return @ptrCast(@alignCast(owned.table.initialization_parent(owned.context, P.kindIdentity()) orelse return null));
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
/// Execution is an exhaustive author choice; neither mode can obtain the
/// other mode's execution authority through its borrowed context.
pub fn Port(comptime execution: union(enum) { controller: type, cooperative: type }) type {
    return switch (execution) {
        .controller => |Spec| ControllerPort(Spec),
        .cooperative => |Spec| CooperativePort(Spec),
    };
}

fn ControllerPort(comptime Spec: type) type {
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
        if (@hasDecl(Spec, "shutdown") and @TypeOf(Spec.shutdown) != fn (*Spec.State, *Shutdown) void)
            @compileError("ecl-native: shutdown requires fn (*State, *Shutdown) void");
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
    const activity_entries = if (@hasDecl(Spec, "activities")) Spec.activities else .{};
    const activity_fields = @import("std").meta.fields(@TypeOf(activity_entries));
    if (activity_fields.len > @import("port-declarations").max_activities) @compileError("ecl-native: at most four resource activities may be declared");
    const activity_definitions = blk: {
        var values: [activity_fields.len]abi.ActivityDefinition = undefined;
        var owned: u64 = 0;
        for (activity_fields, 0..) |field, index| {
            values[index] = activityDefinition(Spec.State, DeclaredEndpoints, @field(activity_entries, field.name));
            if (owned & values[index].endpoints != 0) @compileError("ecl-native: resource endpoints belong to one activity");
            owned |= values[index].endpoints;
        }
        break :blk values;
    };
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
        pub fn operationMode(comptime _: Operations.Name) abi.OperationMode {
            return .ordinary;
        }
        pub const name = Spec.name;
        // A mutable object's address supplies nominal identity even when two
        // specs have identical names or the linker folds identical callbacks.
        var kind_identity: u8 = 0;
        const activities = activity_definitions;
        fn kindIdentity() *const anyopaque {
            return &kind_identity;
        }
        pub fn definition() abi.PortDefinition {
            return .{ .activity_count = activities.len, .activities_ptr = if (activities.len == 0) null else &activities, .state_size = @sizeOf(Spec.State), .state_alignment = @alignOf(Spec.State), .name_ptr = name.ptr, .name_len = name.len, .init_state = initState, .initialize = initialize, .execute = execute, .cancel = cancelState, .cleanup = cleanup, .lane_count = @typeInfo(Lane).@"enum".fields.len, .cancellation = switch (cancellation) {
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

/// Graceful shutdown controls producer admission without acquiring stream data.
pub const Shutdown = opaque {
    fn controller(self: *Shutdown) *Controller {
        return @ptrCast(self);
    }
    pub fn instance(self: *Shutdown, comptime I: type) ?*I.State {
        return self.controller().instance(I);
    }
    pub fn input(self: *Shutdown, path: []const u64) ?*const MessageView {
        return self.controller().input(path);
    }
    pub fn cancelled(self: *Shutdown) bool {
        return self.controller().cancelled();
    }
    pub fn fail(self: *Shutdown, kind: capability.ErrorKind, message: []const u8) void {
        self.controller().fail(kind, message);
    }
    pub fn failOutOfMemory(self: *Shutdown) void {
        self.controller().failOutOfMemory();
    }
    /// Stop producer admission while allowing the resource activity to drain
    /// every accepted byte. This grants no reader or writer endpoint authority.
    pub fn finishInput(self: *Shutdown, comptime P: type, comptime name: P.Endpoints.Name) ControllerError!void {
        const spec = comptime P.Endpoints.get(name);
        comptime if (spec.owner != .resource or spec.transport != .bytes or spec.direction != .input)
            @compileError("ecl-native: shutdown finishes resource byte inputs");
        const owned = self.controller().state();
        if (!owned.table.finish_input(owned.context, P.kindIdentity(), P.Endpoints.id(name))) return if (self.cancelled()) error.Cancelled else error.InvalidValue;
    }
};

/// A joined resource activity owns only its declared byte-stream endpoints.
/// It can supervise native I/O without borrowing an initialization callback.
pub const Activity = opaque {
    fn controller(self: *Activity) *Controller {
        return @ptrCast(self);
    }
    pub fn instance(self: *Activity, comptime I: type) ?*I.State {
        return self.controller().instance(I);
    }
    pub fn cancelled(self: *Activity) bool {
        return self.controller().cancelled();
    }
    pub fn fail(self: *Activity, kind: capability.ErrorKind, message: []const u8) void {
        self.controller().fail(kind, message);
    }
    pub fn failResource(self: *Activity, kind: capability.ErrorKind, message: []const u8) void {
        self.controller().failResource(kind, message);
    }
    pub fn failOutOfMemory(self: *Activity) void {
        self.controller().failOutOfMemory();
    }
    pub fn endpoint(self: *Activity, comptime P: type, comptime name: P.Endpoints.Name) ControllerError!*Endpoint(P, name) {
        const spec = comptime P.Endpoints.get(name);
        comptime if (spec.owner != .resource or spec.transport != .bytes) @compileError("ecl-native: activities require resource byte endpoints");
        return self.controller().endpoint(P, name);
    }
};

fn activityMask(comptime EndpointSet: type, comptime endpoints: anytype) u64 {
    var mask: u64 = 0;
    for (endpoints) |name| {
        const selected: EndpointSet.Name = name;
        const endpoint = EndpointSet.get(selected);
        if (endpoint.owner != .resource or endpoint.transport != .bytes) @compileError("ecl-native: activities require resource byte endpoints");
        const bit = @as(u64, 1) << EndpointSet.id(selected);
        if (mask & bit != 0) @compileError("ecl-native: duplicate activity endpoint");
        mask |= bit;
    }
    return mask;
}
fn activityDefinition(comptime State: type, comptime EndpointSet: type, comptime entry: anytype) abi.ActivityDefinition {
    if (@TypeOf(entry.handler) != fn (*State, *Activity) void and @TypeOf(entry.handler) != fn (*State, *Activity) ControllerError!void)
        @compileError("ecl-native: activity handler requires resource state and activity context");
    const Bridge = struct {
        fn invoke(raw: *anyopaque, table: *const abi.ControllerTable, context: *anyopaque) callconv(.c) void {
            var state: ControllerState = .{ .table = table, .context = context };
            const activity: *Activity = @ptrCast(&state);
            if (@typeInfo(@TypeOf(entry.handler)).@"fn".return_type.? == void) entry.handler(@as(*State, @ptrCast(@alignCast(raw))), activity) else entry.handler(@as(*State, @ptrCast(@alignCast(raw))), activity) catch |err| switch (err) {
                error.OutOfMemory => activity.failOutOfMemory(),
                error.Cancelled => if (!activity.cancelled()) activity.fail(.contract, "activity reported cancellation without a request"),
                error.Failed => activity.fail(.io, "native activity failed"),
                error.InvalidValue => activity.fail(.contract, "invalid activity capability or value"),
            };
        }
    };
    return .{ .endpoints = activityMask(EndpointSet, entry.endpoints), .execute = Bridge.invoke };
}

pub const CooperativeProgress = enum { completed, yielded, parked };
const CooperativeState = struct { table: *const abi.CooperativeTable, context: *anyopaque, input_view: abi.ValueView = .{ .kind = .list } };

/// Invocation-local cooperative authority. The ABI table itself withholds
/// blocking streams, sends, and synchronous child initialization.
pub const Cooperative = opaque {
    fn state(self: *Cooperative) *CooperativeState {
        return @ptrCast(@alignCast(self));
    }
    pub fn consume(self: *Cooperative, units: u32) bool {
        const owned = self.state();
        return owned.table.consume(owned.context, units);
    }
    /// Capture a timer deadline now. Return parked only after this succeeds.
    /// Cancellation wakes the parked invocation so its private unwind can join.
    pub fn park(self: *Cooperative, milliseconds: u63) bool {
        const owned = self.state();
        return owned.table.park(owned.context, milliseconds);
    }
    pub fn input(self: *Cooperative, path: []const u64) ?*const MessageView {
        if (path.len > abi.max_read_path_depth) return null;
        const owned = self.state();
        if (!owned.table.input(owned.context, path.ptr, @intCast(path.len), &owned.input_view)) return null;
        return @ptrCast(&owned.input_view);
    }
    pub fn instance(self: *Cooperative, comptime I: type) ?*I.State {
        const owned = self.state();
        return @ptrCast(@alignCast(owned.table.instance_state(owned.context, I.identity()) orelse return null));
    }
    pub fn parent(self: *Cooperative, comptime P: type) ?*P.StateType {
        comptime if (!@hasDecl(P, "ecl_port_marker")) @compileError("ecl-native: parent requires a declared Port type");
        const owned = self.state();
        return @ptrCast(@alignCast(owned.table.parent_state(owned.context, P.kindIdentity()) orelse return null));
    }
    /// Initialization-only parent borrow, including independently owned
    /// children. It expires when initialization completes, fails, or is
    /// cancelled, and must not be retained by operations or cleanup.
    pub fn initializationParent(self: *Cooperative, comptime P: type) ?*P.StateType {
        comptime if (!@hasDecl(P, "ecl_port_marker")) @compileError("ecl-native: parent requires a declared Port type");
        const owned = self.state();
        return @ptrCast(@alignCast(owned.table.initialization_parent(owned.context, P.kindIdentity()) orelse return null));
    }
    pub fn cancelled(self: *Cooperative) bool {
        const owned = self.state();
        return owned.table.cancelled(owned.context);
    }
    pub fn fail(self: *Cooperative, kind: capability.ErrorKind, message: []const u8) void {
        const bounded = capability.boundedErrorMessage(message);
        const owned = self.state();
        owned.table.fail(owned.context, kind, bounded.ptr, @intCast(bounded.len));
    }
    pub fn failOutOfMemory(self: *Cooperative) void {
        const owned = self.state();
        owned.table.fail_allocation(owned.context);
    }
    pub fn builder(self: *Cooperative) *CooperativeBuilder {
        return @ptrCast(self);
    }
};

/// Scalar writes complete immediately. Symbol, copy, and aggregate commands
/// begin bounded construction; advance must finish them before another command.
/// Symbols contain at most 256 bytes. Construction survives callback yields and
/// its owner retires it on every completion or cancellation path.
pub const CooperativeBuilder = opaque {
    fn state(self: *CooperativeBuilder) *CooperativeState {
        return @ptrCast(@alignCast(self));
    }
    fn apply(self: *CooperativeBuilder, request: abi.MessageBuildRequest) ControllerError!void {
        const owned = self.state();
        return applyBuild(owned.table, owned.context, &request);
    }
    pub fn int(self: *CooperativeBuilder, value: i64) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.int(value).wire });
    }
    pub fn float(self: *CooperativeBuilder, value: f64) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.float(value).wire });
    }
    pub fn char(self: *CooperativeBuilder, value: u32) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.char(value).wire });
    }
    pub fn symbol(self: *CooperativeBuilder, bytes: []const u8) ControllerError!void {
        return self.apply(.{ .action = .scalar, .scalar = capability.Scalar.symbol(bytes).wire });
    }
    pub fn input(self: *CooperativeBuilder, path: []const u64) ControllerError!void {
        if (path.len > abi.max_read_path_depth) return error.InvalidValue;
        return self.apply(.{ .action = .copy_input, .path = path.ptr, .depth = @intCast(path.len) });
    }
    pub fn list(self: *CooperativeBuilder, count: u32) ControllerError!void {
        return self.apply(.{ .action = .list, .count = count });
    }
    pub fn dictionary(self: *CooperativeBuilder, pairs: u32) ControllerError!void {
        return self.apply(.{ .action = .dictionary, .count = pairs });
    }
    /// Operation completion also advances pending result publication.
    pub fn result(self: *CooperativeBuilder) ControllerError!void {
        return self.apply(.{ .action = .result });
    }
    pub fn clear(self: *CooperativeBuilder) ControllerError!void {
        return self.apply(.{ .action = .clear });
    }
    /// Begin replacing the top configuration with a provisionally owned child.
    /// Advance validates, initializes, and waits without blocking a controller.
    /// Failure retains private construction for joined cleanup.
    pub fn child(self: *CooperativeBuilder, comptime P: type, dependency: ChildDependency) ControllerError!void {
        return self.apply(childRequest(P, dependency));
    }
    /// Propagate yielded or parked progress from the callback. Only completed
    /// permits the next construction command. Child parking owns a registered
    /// readiness wait and does not poll or require a timer.
    pub fn advance(self: *CooperativeBuilder) ControllerError!CooperativeProgress {
        const owned = self.state();
        return switch (owned.table.build_message(owned.context, &.{ .action = .advance })) {
            .ok => .completed,
            .yield_required => .yielded,
            .parked => .parked,
            .out_of_memory => error.OutOfMemory,
            else => if (owned.table.cancelled(owned.context)) error.Cancelled else error.Failed,
        };
    }
};

fn applyBuild(table: anytype, context: *anyopaque, request: *const abi.MessageBuildRequest) ControllerError!void {
    return switch (table.build_message(context, request)) {
        .ok => {},
        .out_of_memory => error.OutOfMemory,
        else => if (table.cancelled(context)) error.Cancelled else error.Failed,
    };
}

/// A sealing callback runs only after earlier work and dependent children join.
/// Prepare and advance the complete result before requesting commit authority.
pub const Finalizer = opaque {
    fn cooperative(self: *Finalizer) *Cooperative {
        return @ptrCast(self);
    }
    pub fn consume(self: *Finalizer, units: u32) bool {
        return self.cooperative().consume(units);
    }
    pub fn input(self: *Finalizer, path: []const u64) ?*const MessageView {
        return self.cooperative().input(path);
    }
    pub fn instance(self: *Finalizer, comptime I: type) ?*I.State {
        return self.cooperative().instance(I);
    }
    pub fn parent(self: *Finalizer, comptime P: type) ?*P.StateType {
        return self.cooperative().parent(P);
    }
    pub fn cancelled(self: *Finalizer) bool {
        return self.cooperative().cancelled();
    }
    pub fn fail(self: *Finalizer, kind: capability.ErrorKind, message: []const u8) void {
        self.cooperative().fail(kind, message);
    }
    pub fn failOutOfMemory(self: *Finalizer) void {
        self.cooperative().failOutOfMemory();
    }
    pub fn builder(self: *Finalizer) *FinalizerBuilder {
        return @ptrCast(self);
    }
    pub fn beginCommit(self: *Finalizer) ControllerError!void {
        const owned = self.cooperative().state();
        if (!owned.table.begin_commit(owned.context)) return if (self.cancelled()) error.Cancelled else error.InvalidValue;
    }
};

/// Capability-free result construction. Finalizers cannot create descendants or
/// transport endpoints; committing freezes further result mutation at the host.
pub const FinalizerBuilder = opaque {
    fn builder(self: *FinalizerBuilder) *CooperativeBuilder {
        return @ptrCast(self);
    }
    pub fn int(self: *FinalizerBuilder, value: i64) ControllerError!void {
        return self.builder().int(value);
    }
    pub fn float(self: *FinalizerBuilder, value: f64) ControllerError!void {
        return self.builder().float(value);
    }
    pub fn char(self: *FinalizerBuilder, value: u32) ControllerError!void {
        return self.builder().char(value);
    }
    pub fn symbol(self: *FinalizerBuilder, value: []const u8) ControllerError!void {
        return self.builder().symbol(value);
    }
    pub fn input(self: *FinalizerBuilder, value: []const u64) ControllerError!void {
        return self.builder().input(value);
    }
    pub fn list(self: *FinalizerBuilder, value: u32) ControllerError!void {
        return self.builder().list(value);
    }
    pub fn dictionary(self: *FinalizerBuilder, value: u32) ControllerError!void {
        return self.builder().dictionary(value);
    }
    pub fn result(self: *FinalizerBuilder) ControllerError!void {
        return self.builder().result();
    }
    pub fn clear(self: *FinalizerBuilder) ControllerError!void {
        return self.builder().clear();
    }
    pub fn advance(self: *FinalizerBuilder) ControllerError!CooperativeProgress {
        return self.builder().advance();
    }
};

fn CooperativePort(comptime Spec: type) type {
    const Lane = enum { operation };
    const EndpointSet = declarations.Endpoints(.{});
    const OperationSet = declarations.Operations(Lane, EndpointSet, Spec.operations);
    comptime {
        for (.{ "State", "name", "init", "open", "retireOperation", "retire", "operations" }) |name|
            if (!@hasDecl(Spec, name)) @compileError("ecl-native: cooperative Port requires State, name, init, open, retireOperation, retire, and operations");
        if (@sizeOf(Spec.State) == 0 or @sizeOf(Spec.State) > abi.max_port_state_bytes or @alignOf(Spec.State) > 64)
            @compileError("ecl-native: Port State exceeds the supported size or alignment");
        if (@TypeOf(Spec.init) != fn () Spec.State or
            @TypeOf(Spec.retireOperation) != fn (*Spec.State, *Cooperative) CooperativeProgress or
            @TypeOf(Spec.retire) != fn (*Spec.State, *Cooperative) CooperativeProgress)
            @compileError("ecl-native: cooperative Port callbacks have invalid signatures");
        if (@TypeOf(Spec.open) != fn (*Spec.State, *Cooperative) CooperativeProgress and
            @TypeOf(Spec.open) != fn (*Spec.State, *Cooperative) ControllerError!CooperativeProgress)
            @compileError("ecl-native: cooperative initialization requires cooperative context");
        for (@import("std").meta.tags(OperationSet.Name)) |name|
            validateCooperativeHandler(Spec.State, OperationSet.get(name).handler);
    }
    return opaque {
        pub const ecl_port_marker = void;
        pub const StateType = Spec.State;
        pub const LaneType = Lane;
        pub const Endpoints = EndpointSet;
        pub const Operations = OperationSet;
        pub fn operationMode(comptime operation: Operations.Name) abi.OperationMode {
            return if (@typeInfo(@TypeOf(Operations.get(operation).handler)).@"fn".params[1].type.? == *Finalizer) .finalizer else .ordinary;
        }
        pub const name = Spec.name;
        var identity: u8 = 0;
        fn kindIdentity() *const anyopaque {
            return &identity;
        }
        const callbacks: abi.CooperativeDefinition = .{ .initialize = initialize, .execute = execute, .retire_operation = retireOperation, .retire = retire };
        pub fn definition() abi.PortDefinition {
            return .{
                .state_size = @sizeOf(Spec.State),
                .state_alignment = @alignOf(Spec.State),
                .name_ptr = name.ptr,
                .name_len = name.len,
                .init_state = initState,
                .initialize = null,
                .execute = null,
                .cancel = null,
                .cleanup = null,
                .cancellation = .acknowledge,
                .identity = kindIdentity(),
                .execution = .cooperative,
                .cooperative = &callbacks,
            };
        }
        fn initState(raw: *anyopaque) callconv(.c) void {
            const state: *Spec.State = @ptrCast(@alignCast(raw));
            state.* = Spec.init();
        }
        fn initialize(raw: *anyopaque, table: *const abi.CooperativeTable, context: *anyopaque) callconv(.c) abi.CooperativeProgress {
            return invoke(Spec.open, raw, table, context);
        }
        fn execute(raw: *anyopaque, code: u32, table: *const abi.CooperativeTable, context: *anyopaque) callconv(.c) abi.CooperativeProgress {
            inline for (comptime @import("std").meta.tags(Operations.Name)) |operation| {
                if (code == @intFromEnum(operation)) return invoke(Operations.get(operation).handler, raw, table, context);
            }
            table.fail(context, .contract, "unsupported registered operation", "unsupported registered operation".len);
            return .completed;
        }
        fn retireOperation(raw: *anyopaque, table: *const abi.CooperativeTable, context: *anyopaque) callconv(.c) abi.CooperativeProgress {
            return invoke(Spec.retireOperation, raw, table, context);
        }
        fn retire(raw: *anyopaque, table: *const abi.CooperativeTable, context: *anyopaque) callconv(.c) abi.CooperativeProgress {
            return invoke(Spec.retire, raw, table, context);
        }
        fn invoke(comptime handler: anytype, raw: *anyopaque, table: *const abi.CooperativeTable, context: *anyopaque) abi.CooperativeProgress {
            var state: CooperativeState = .{ .table = table, .context = context };
            const call: *Cooperative = @ptrCast(&state);
            const Context = @typeInfo(@TypeOf(handler)).@"fn".params[1].type.?;
            const typed_call: Context = @ptrCast(&state);
            const progress = if (@typeInfo(@TypeOf(handler)).@"fn".return_type.? == CooperativeProgress)
                handler(@as(*Spec.State, @ptrCast(@alignCast(raw))), typed_call)
            else
                handler(@as(*Spec.State, @ptrCast(@alignCast(raw))), typed_call) catch |err| blk: {
                    switch (err) {
                        error.OutOfMemory => call.failOutOfMemory(),
                        error.Cancelled => if (!call.cancelled()) call.fail(.contract, "cooperative callback reported cancellation without a request"),
                        error.Failed => call.fail(.io, "cooperative resource operation failed"),
                        error.InvalidValue => call.fail(.contract, "invalid cooperative capability or value"),
                    }
                    break :blk CooperativeProgress.completed;
                };
            return switch (progress) {
                .completed => .completed,
                .yielded => .yielded,
                .parked => .parked,
            };
        }
    };
}

fn validateCooperativeHandler(comptime State: type, comptime handler: anytype) void {
    if (@TypeOf(handler) != fn (*State, *Cooperative) CooperativeProgress and
        @TypeOf(handler) != fn (*State, *Cooperative) ControllerError!CooperativeProgress and
        @TypeOf(handler) != fn (*State, *Finalizer) CooperativeProgress and
        @TypeOf(handler) != fn (*State, *Finalizer) ControllerError!CooperativeProgress)
        @compileError("ecl-native: cooperative handler requires resource state and cooperative context");
}
