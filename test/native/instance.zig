//! Independently compiled author fixture for the instance lifecycle contract.
const std = @import("std");
const ecl = @import("ecl-native");

var retired = std.atomic.Value(i64).init(0);
const Lifecycle = struct {
    pub const State = struct {
        bytes: ?[]align(64) u8 = null,
        memory: ?*const ecl.NativeMemory = null,
        copied: usize = 0,
        value: std.atomic.Value(i64) = .init(0),
        cooperative_started: std.atomic.Value(i64) = .init(0),
        child_advances: std.atomic.Value(i64) = .init(0),
        capacity_retired: std.atomic.Value(i64) = .init(0),
        work_retired: std.atomic.Value(i64) = .init(0),
        work_operation_retired: std.atomic.Value(i64) = .init(0),
        packed_started: std.atomic.Value(i64) = .init(0),
        capacity_started: std.atomic.Value(i64) = .init(0),
    };
    pub fn init() State {
        return .{};
    }
    pub fn initialize(state: *State, context: *ecl.InstanceContext) ecl.InstanceResult {
        state.memory = context.memory();
        const configuration = context.configuration();
        if (state.bytes == null) {
            state.bytes = try context.allocate(@max(configuration.len, 1));
            return .pending;
        }
        while (state.copied < configuration.len and context.consume()) {
            state.bytes.?[state.copied] = configuration[state.copied];
            _ = state.value.fetchAdd(configuration[state.copied], .monotonic);
            state.copied += 1;
        }
        if (state.copied != configuration.len) return .pending;
        if (std.mem.eql(u8, configuration, "foreign")) try context.configureEndpoint(ForeignPort, .output, 1);
        if (std.mem.startsWith(u8, configuration, "capacity")) {
            const capacity: u32 = if (configuration.len >= 9) configuration[8] - '0' else 0;
            try context.configureEndpoint(ActivityResource, .output, capacity);
            try context.configureEndpoint(ActivityResource, .input, 2);
            try context.configureEndpoint(ActivityResource, .ready, 1);
            if (std.mem.eql(u8, configuration, "capacity3fail")) return error.Failed;
        }
        if (std.mem.eql(u8, configuration, "fail")) return error.Failed;
        return .complete;
    }
    pub fn retire(state: *State, context: *ecl.InstanceContext) bool {
        if (state.bytes) |bytes| {
            if (!context.consume()) return false;
            context.release(bytes);
            state.bytes = null;
            return false;
        }
        _ = retired.fetchAdd(1, .monotonic);
        return true;
    }
};
pub const Instance = ecl.Instance(Lifecycle);
const Foreign = ecl.Instance(struct {
    pub const State = struct { value: u8 = 0 };
});

fn value(call: *ecl.Call("-- value")) ecl.CallbackResult {
    const state = call.instance(Instance) orelse return call.fail(.contract, "missing instance");
    if (call.instance(Foreign) != null) return call.fail(.contract, "foreign instance exposed");
    return call.complete(.{ecl.Scalar.int(state.value.fetchAdd(1, .monotonic))});
}
fn allocations(call: *ecl.Call("-- value")) ecl.CallbackResult {
    const state = call.instance(Instance) orelse return call.fail(.contract, "missing instance");
    const memory = state.memory.?;
    const bytes = try memory.allocate(8);
    defer memory.release(bytes);
    @memset(bytes, 42);
    return call.complete(.{ecl.Scalar.int(bytes[7])});
}
fn memoryAllocator(call: *ecl.Call("-- value")) ecl.CallbackResult {
    const state = call.instance(Instance) orelse return call.fail(.contract, "missing instance");
    const storage = state.memory.?.allocator();
    var bytes = try storage.alloc(u8, 8);
    defer storage.free(bytes);
    @memset(bytes, 42);
    bytes = try storage.realloc(bytes, 16);
    if (bytes[7] != 42) return call.fail(.contract, "native allocator lost data");
    const aligned = try storage.alignedAlloc(u8, .@"64", 8);
    defer storage.free(aligned);
    if (@intFromPtr(aligned.ptr) % 64 != 0) return call.fail(.contract, "native allocator alignment");
    const value_ptr = try storage.create(i64);
    defer storage.destroy(value_ptr);
    value_ptr.* = 43;
    return call.complete(.{ecl.Scalar.int(value_ptr.*)});
}

fn retirements(call: *ecl.Call("-- value")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(retired.load(.monotonic))});
}

const ForeignPort = ecl.Port(.{ .controller = struct {
    pub const name = "foreign";
    pub const State = struct { byte: u8 = 0 };
    pub const endpoints = .{ .output = ecl.declarations.Endpoint{ .doc = "Undeclared kind endpoint.", .transport = .bytes, .direction = .output, .owner = .resource } };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
} });

const Resource = ecl.Port(.{ .controller = struct {
    pub const name = "resource";
    pub const CapacityFailure = CapacityReporter;
    pub const State = struct { value: i64 = 0, cancelled: std.atomic.Value(bool) = .init(false) };
    pub const operations = .{
        .private_value = .{ .name = "hidden-value", .visibility = .private, .doc = "Private controller selector member.", .handler = read, .lane = .operation, .endpoints = .{} },
        .value = .{ .doc = "Read the host-configured value.", .handler = read, .lane = .operation, .endpoints = .{} },
        .child = .{ .doc = "Create an independent child using its initialization borrow.", .handler = child, .lane = .operation, .endpoints = .{} },
        .cooperative_child = .{ .name = "cooperative-child", .doc = "Create an independent cooperative child using its initialization borrow.", .handler = cooperativeChild, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        const instance = controller.instance(Instance) orelse return controller.fail(.contract, "missing instance");
        state.value = instance.value.load(.monotonic);
        if (controller.initializationParent(Resource)) |parent| {
            if (controller.parent(Resource) != null) return controller.fail(.contract, "independent child acquired a lifetime borrow");
            state.value = parent.value + 10;
        }
    }
    pub fn cancel(state: *State) void {
        state.cancelled.store(true, .release);
    }
    pub fn deinit(state: *State) void {
        state.value = -1;
    }
    fn read(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        if (controller.initializationParent(Resource) != null) return error.InvalidValue;
        const builder = controller.builder();
        try builder.int(state.value);
        try builder.result();
    }
    fn child(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        try builder.list(0);
        try builder.child(Resource, .independent);
        try builder.result();
    }
    fn cooperativeChild(_: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        try builder.list(0);
        try builder.child(CooperativeResource, .independent);
        try builder.result();
    }
} });

fn cooperativeStarted(call: *ecl.Call("-- value")) ecl.CallbackResult {
    const state = call.instance(Instance) orelse return call.fail(.contract, "missing instance");
    return call.complete(.{ecl.Scalar.int(state.cooperative_started.load(.acquire))});
}
fn childAdvances(call: *ecl.Call("-- value")) ecl.CallbackResult {
    const state = call.instance(Instance) orelse return call.fail(.contract, "missing instance");
    return call.complete(.{ecl.Scalar.int(state.child_advances.load(.acquire))});
}
const CooperativeResource = ecl.Port(.{
    .cooperative = struct {
        pub const name = "cooperative";
        pub const CapacityFailure = CapacityReporter;
        pub const State = struct {
            memory: ?*const ecl.NativeMemory = null,
            bytes: ?[]align(64) u8 = null,
            initialized: usize = 0,
            phase: enum { start, values, aggregate, completed } = .start,
            index: u32 = 0,
            target: u32 = 1024,
            retire_remaining: u32 = 513,
            cleanup_remaining: u32 = 513,
            copied_parent: ?i64 = null,
            construction: enum { start, clear, key, scalars, dictionary, input, list } = .start,
            creating: enum { start, configuration, child } = .start,
            initialization_parked: bool = false,
            finalization: enum { start, result, commit, retiring } = .start,
            final_slices: u32 = 8,
        };
        pub const operations = .{
            .private_value = .{ .name = "hidden-value", .visibility = .private, .doc = "Private cooperative selector member.", .handler = borrowed, .lane = .operation, .endpoints = .{} },
            .seal = .{ .doc = "Seal admission and commit a prepared result.", .handler = seal, .lane = .operation, .endpoints = .{} },
            .values = .{ .doc = "Build a result over several bounded slices.", .handler = values, .lane = .operation, .endpoints = .{} },
            .park = .{ .doc = "Park until cancelled, then join private retirement.", .handler = park, .lane = .operation, .endpoints = .{} },
            .borrowed = .{ .doc = "Read an independently copied initialization value.", .handler = borrowed, .lane = .operation, .endpoints = .{} },
            .message = .{ .doc = "Construct a heterogeneous message using bounded SDK builders.", .handler = message, .lane = .operation, .endpoints = .{} },
            .spawn = .{ .name = "cooperative-spawn", .doc = "Create an independent child through resumable construction.", .handler = spawn, .lane = .operation, .endpoints = .{} },
            .inherited = .{ .name = "cooperative-inherited", .doc = "Inherit the lifetime group without retaining the immediate parent.", .handler = inherited, .lane = .operation, .endpoints = .{} },
            .dependent = .{ .name = "cooperative-dependent", .doc = "Create a dependent child through resumable construction.", .handler = dependent, .lane = .operation, .endpoints = .{} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const instance = context.instance(Instance) orelse return error.InvalidValue;
            state.memory = instance.memory;
            if (context.initializationParent(Resource)) |parent| {
                if (context.parent(Resource) != null) return error.InvalidValue;
                state.copied_parent = parent.value + 20;
            }
            if (context.initializationParent(CooperativeResource)) |parent| {
                state.copied_parent = parent.copied_parent.? + 1;
            }
            if (state.copied_parent == null) state.copied_parent = instance.value.load(.monotonic);
            if (state.bytes == null) state.bytes = try state.memory.?.allocate(1024);
            while (state.initialized < state.bytes.?.len and context.consume(1)) {
                state.bytes.?[state.initialized] = @truncate(state.initialized);
                state.initialized += 1;
            }
            if (state.initialized != state.bytes.?.len) return .yielded;
            if (context.input(&.{}).?.int() == 2 and !state.initialization_parked) {
                state.initialization_parked = true;
                instance.cooperative_started.store(2, .release);
                if (!context.park(3_600_000)) return error.InvalidValue;
                return .parked;
            }
            if (context.input(&.{}).?.int() == 1) context.fail(.io, "requested cooperative initialization failure");
            return .completed;
        }
        fn values(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const builder = context.builder();
            switch (state.phase) {
                .start => {
                    const requested = context.input(&.{}).?.int();
                    state.target = if (requested) |count| @intCast(@max(0, @min(count, 1024))) else 1024;
                    state.phase = .values;
                    state.retire_remaining = 513;
                    return .yielded;
                },
                .values => {
                    while (state.index < state.target and context.consume(1)) {
                        try builder.int(state.index);
                        state.index += 1;
                    }
                    if (state.index != state.target) return .yielded;
                    try builder.list(state.index);
                    state.phase = .aggregate;
                    return .yielded;
                },
                .aggregate => {
                    const progress = try builder.advance();
                    if (progress != .completed) return progress;
                    try builder.result();
                    state.phase = .completed;
                    return .completed;
                },
                .completed => unreachable,
            }
        }
        fn park(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            const instance = context.instance(Instance) orelse return error.InvalidValue;
            state.retire_remaining = 513;
            instance.cooperative_started.store(1, .release);
            if (!context.park(3_600_000)) return error.InvalidValue;
            return .parked;
        }
        fn borrowed(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            if (context.initializationParent(Resource) != null or context.parent(Resource) != null) return error.InvalidValue;
            if (context.initializationParent(CooperativeResource) != null or context.parent(CooperativeResource) != null) return error.InvalidValue;
            try context.builder().int(state.copied_parent orelse return error.InvalidValue);
            try context.builder().result();
            return .completed;
        }
        fn spawn(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return createChild(state, context, .independent);
        }
        fn dependent(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return createChild(state, context, .dependent);
        }
        fn inherited(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return createChild(state, context, .inherited);
        }
        fn createChild(state: *State, context: *ecl.Cooperative, comptime dependency: anytype) ecl.ControllerError!ecl.CooperativeProgress {
            const builder = context.builder();
            const instance = context.instance(Instance).?;
            if (state.creating == .start) instance.child_advances.store(0, .release);
            if (state.creating == .child) _ = instance.child_advances.fetchAdd(1, .acq_rel);
            if (state.creating != .start) {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
            }
            switch (state.creating) {
                .start => {
                    state.retire_remaining = 513;
                    try builder.input(&.{});
                    state.creating = .configuration;
                },
                .configuration => {
                    try builder.child(CooperativeResource, dependency);
                    state.creating = .child;
                },
                .child => {
                    try builder.result();
                    return .completed;
                },
            }
            return .yielded;
        }
        fn message(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return constructMessage(state, context);
        }
        fn constructMessage(state: *State, context: anytype) ecl.ControllerError!ecl.CooperativeProgress {
            const builder = context.builder();
            if (state.construction != .start) {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
            }
            switch (state.construction) {
                .start => {
                    try builder.int(99);
                    try builder.clear();
                    state.construction = .clear;
                },
                .clear => {
                    try builder.symbol("answer");
                    state.construction = .key;
                },
                .key => {
                    try builder.float(0.5);
                    try builder.char(955);
                    try builder.list(2);
                    state.construction = .scalars;
                },
                .scalars => {
                    try builder.dictionary(1);
                    state.construction = .dictionary;
                },
                .dictionary => {
                    try builder.input(&.{});
                    state.construction = .input;
                },
                .input => {
                    try builder.list(2);
                    state.construction = .list;
                },
                .list => {
                    try builder.result();
                    return .completed;
                },
            }
            return .yielded;
        }
        fn seal(state: *State, context: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
            const instance = context.instance(Instance) orelse return error.InvalidValue;
            const mode = context.input(&.{}).?.int() orelse return error.InvalidValue;
            if (context.parent(Resource) != null) return error.InvalidValue;
            if (!context.consume(1)) return .yielded;
            switch (state.finalization) {
                .start => {
                    instance.cooperative_started.store(3, .release);
                    if (mode == 1) return .yielded;
                    if (mode == 2) {
                        context.fail(.io, "requested finalizer failure");
                        return .completed;
                    }
                    if (mode == 4) return .completed;
                    if (mode == 8) {
                        context.failOutOfMemory();
                        return .completed;
                    }
                    if (mode == 7) {
                        const progress = try constructMessage(state, context);
                        if (progress != .completed) return progress;
                        state.finalization = .result;
                        return .yielded;
                    }
                    try context.builder().int(42);
                    try context.builder().result();
                    state.finalization = .result;
                },
                .result => {
                    const progress = try context.builder().advance();
                    if (progress != .completed) return progress;
                    state.finalization = .commit;
                },
                .commit => {
                    if (mode == 5 and instance.value.load(.monotonic) != 11065) return error.InvalidValue;
                    if (mode == 6 and instance.value.load(.monotonic) != 1065) return error.InvalidValue;
                    try context.beginCommit();
                    _ = instance.value.fetchAdd(100000, .monotonic);
                    instance.cooperative_started.store(4, .release);
                    state.finalization = .retiring;
                },
                .retiring => {
                    // Bounded private retirement keeps committed execution alive.
                    if (state.final_slices != 0) {
                        state.final_slices -= 1;
                        return .yielded;
                    }
                    if (mode == 3) {
                        context.builder().int(99) catch |err| {
                            if (err == error.InvalidValue) return .completed;
                            return err;
                        };
                        return error.InvalidValue;
                    }
                    return .completed;
                },
            }
            return .yielded;
        }
        pub fn retireOperation(state: *State, context: *ecl.Cooperative) ecl.CooperativeProgress {
            while (state.retire_remaining != 0 and context.consume(1)) state.retire_remaining -= 1;
            if (state.retire_remaining != 0) return .yielded;
            state.phase = .start;
            state.construction = .start;
            state.creating = .start;
            state.index = 0;
            const instance = context.instance(Instance).?;
            _ = instance.value.fetchAdd(1000, .monotonic);
            return .completed;
        }
        pub fn retire(state: *State, context: *ecl.Cooperative) ecl.CooperativeProgress {
            while (state.cleanup_remaining != 0 and context.consume(1)) state.cleanup_remaining -= 1;
            if (state.cleanup_remaining != 0) return .yielded;
            if (state.bytes) |bytes| state.memory.?.release(bytes);
            state.bytes = null;
            _ = context.instance(Instance).?.value.fetchAdd(10000, .monotonic);
            return .completed;
        }
    },
});

const ActivityResource = ecl.Port(.{
    .controller = struct {
        pub const name = "activity";
        pub const State = struct {
            instance: ?*Instance.State = null,
            mode: i64 = 0,
            finished: std.atomic.Value(u32) = .init(0),
            echo_finished: std.Io.Event = .unset,
            output_ready: std.Io.Event = .unset,
            received: usize = 0,
        };
        pub const endpoints = .{
            .input = ecl.declarations.Endpoint{ .name = "activity-in", .doc = "Feed the joined byte pump.", .transport = .bytes, .direction = .input, .owner = .resource },
            .output = ecl.declarations.Endpoint{ .name = "activity-out", .doc = "Read the joined byte pump.", .transport = .bytes, .direction = .output, .owner = .resource },
            .ready = ecl.declarations.Endpoint{ .name = "activity-ready", .doc = "Read the independent startup marker.", .transport = .bytes, .direction = .output, .owner = .resource },
        };
        pub const operations = .{
            .health = .{ .name = "activity-health", .doc = "Observe retained operation admission.", .handler = health, .lane = .operation, .endpoints = .{} },
        };
        fn health(state: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
            try ctx.builder().int(if (state.mode == 8) @intCast(state.received) else 1);
            try ctx.builder().result();
        }
        pub const activities = .{
            .echo = .{ .handler = echo, .endpoints = .{ .input, .output } },
            .marker = .{ .handler = marker, .endpoints = .{.ready} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, context: *ecl.Controller) void {
            state.instance = context.instance(Instance);
            state.mode = context.input(&.{}).?.int() orelse 0;
        }
        pub fn cancel(state: *State) void {
            state.output_ready.set(std.Io.Threaded.global_single_threaded.io());
        }
        pub fn deinit(state: *State) void {
            if (state.instance) |instance| _ = instance.value.fetchAdd(if (state.finished.load(.acquire) == 2) 10000 else -1000000, .monotonic);
        }
        pub fn shutdown(state: *State, context: *ecl.Shutdown) void {
            if (context.instance(Instance) != state.instance) return context.fail(.contract, "shutdown instance mismatch");
            context.finishInput(ActivityResource, .input) catch return;
            state.echo_finished.waitUncancelable(std.Io.Threaded.global_single_threaded.io());
            if (state.mode == 4 and state.received != 3) context.fail(.contract, "shutdown lost accepted input");
        }
        fn echo(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            defer state.echo_finished.set(std.Io.Threaded.global_single_threaded.io());
            defer _ = state.finished.fetchAdd(1, .release);
            if (context.instance(Instance) != state.instance) return error.InvalidValue;
            const input = try context.endpoint(ActivityResource, .input);
            const output = try context.endpoint(ActivityResource, .output);
            // Possessing an activity context does not grant another pump's endpoint.
            if (context.endpoint(ActivityResource, .ready)) |_| return error.InvalidValue else |err| if (err != error.InvalidValue) return err;
            if (state.mode == 6) {
                try output.write(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
                return;
            }
            if (state.mode == 8) {
                defer state.output_ready.set(std.Io.Threaded.global_single_threaded.io());
                var bytes: [2]u8 = undefined;
                const count = (try input.read(&bytes)) orelse return error.InvalidValue;
                state.received = count;
                try output.write(bytes[0..count]);
                state.output_ready.set(std.Io.Threaded.global_single_threaded.io());
                output.write(&.{3}) catch |err| if (err != error.Failed) return err;
                if (try input.read(&bytes) != null) return error.InvalidValue;
                state.received += 100;
                return;
            }
            var bytes: [4096]u8 = undefined;
            while (try input.read(&bytes)) |count| {
                if (state.mode == 1) {
                    context.fail(.io, "requested byte pump failure");
                    return;
                }
                if (state.mode == 2) {
                    context.failResource(.io, "requested whole resource failure");
                    return;
                }
                if (state.mode == 3) {
                    context.failOutOfMemory();
                    return;
                }
                state.received += count;
                if (state.mode != 4) try output.write(bytes[0..count]);
                if (state.mode == 7) {
                    context.failStreams(.io, "all streams failed");
                    return;
                }
                if (state.mode == 5) {
                    context.fail(.io, "failure after accepted output");
                    return;
                }
            }
        }
        fn marker(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            defer _ = state.finished.fetchAdd(1, .release);
            if (state.mode == 8) {
                state.output_ready.waitUncancelable(std.Io.Threaded.global_single_threaded.io());
                if (context.cancelled()) return;
                if (context.stopOutput(ForeignPort, .output)) |_| return error.InvalidValue else |err| if (err != error.InvalidValue) return err;
                try context.finishInput(ActivityResource, .input);
                try context.stopOutput(ActivityResource, .output);
                state.echo_finished.waitUncancelable(std.Io.Threaded.global_single_threaded.io());
            }
            if (!context.cancelled()) try (try context.endpoint(ActivityResource, .ready)).write(&.{7});
        }
    },
});

pub const Extension = ecl.module(.{
    .linkage = .static,
    .name = "instanceprobe",
    .doc = "Instance isolation and retirement probe.",
    .instance = Instance,
    .ports = .{ Resource, CooperativeResource, ActivityResource, DiagnosticController, DiagnosticCooperative, PackedController, PackedCooperative, ControllerLoan, CooperativeLoan, FinalizationLoan },
    .words = .{
        ecl.overload("private-value", "Read privately declared operation members.", .{ .{ Resource, .private_value }, .{ CooperativeResource, .private_value } }),
        ecl.overload("shared-value", "Read either controller or cooperative resource state.", .{ .{ Resource, .value }, .{ CooperativeResource, .borrowed } }),
        ecl.word("string-fact", "Observe the semantic string predicate.", isString),
        ecl.factory("controller-loan", "Borrow an input resource through controller initialization.", ControllerLoan),
        ecl.factory("cooperative-loan", "Borrow an input resource through cooperative initialization.", CooperativeLoan),
        ecl.factory("finalization-loan", "Hold a cooperative target through finalization admission.", FinalizationLoan),
        ecl.factory("packed-controller", "Open a bounded native value constructor.", PackedController),
        ecl.factory("packed-cooperative", "Open a resumable native value constructor.", PackedCooperative),
        ecl.factory("diagnostic-controller", "Open a controller diagnostic probe.", DiagnosticController),
        ecl.factory("diagnostic-cooperative", "Open a cooperative diagnostic probe.", DiagnosticCooperative),
        ecl.word("work-retired", "Observe native resource retirement work granted by the host.", workRetired),
        ecl.word("work-operation-retired", "Observe native operation retirement work granted by the host.", workOperationRetired),
        ecl.word("packed-started", "Observe partial symbol construction before parking.", packedStarted),
        ecl.word("capacity-started", "Observe rejected opening work.", capacityStarted),
        ecl.word("capacity-retirements", "Observe settled capacity rejection cleanup.", capacityRetirements),
        ecl.word("next", "Read and increment instance state.", value),
        ecl.word("allocate", "Allocate and release native storage.", allocations),
        ecl.word("memory-allocator", "Use accounted native storage with standard allocation APIs.", memoryAllocator),
        ecl.word("retirements", "Count completed fixture retirements.", retirements),
        ecl.factory("resource", "Open a configured resource.", Resource),
        ecl.factory("cooperative", "Open a resumable resource.", CooperativeResource),
        ecl.factory("activity", "Open independently supervised byte pumps.", ActivityResource),
        ecl.word("started", "Observe cooperative operation startup.", cooperativeStarted),
        ecl.word("child-advances", "Observe cooperative child initialization dispatches.", childAdvances),
    },
});

comptime {
    _ = Extension;
}

pub const CooperativeOnly = ecl.module(.{
    .linkage = .static,
    .name = "cooperative.probe",
    .doc = "Cooperative instance resource budget probe.",
    .instance = Instance,
    .ports = .{CooperativeResource},
    .words = .{ecl.factory("resource", "Create a cooperative resource.", CooperativeResource)},
});

fn isString(call: *ecl.Call("value -- result")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(@intFromBool(call.input(0).isString()))});
}
const DiagnosticController = ecl.Port(.{ .controller = struct {
    pub const name = "diagnostic-controller";
    pub const State = struct { reserved: u8 = 0 };
    pub const operations = .{
        .diagnose = .{ .name = "controller-diagnose", .doc = "Fail with owned diagnostics.", .handler = diagnose, .lane = .operation, .endpoints = .{} },
        .string = .{ .name = "controller-string-fact", .doc = "Observe a controller string value.", .handler = string, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, ctx: *ecl.Controller) void {
        if (ctx.input(&.{0})) |mode| if (mode.int() == 1) {
            const builder = ctx.errorData();
            builder.input(&.{1}) catch return;
            builder.seal() catch return;
            ctx.fail(.io, "diagnostic initialization");
        };
    }
    fn diagnose(_: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
        const builder = ctx.errorData();
        try builder.input(&.{});
        try builder.seal();
        ctx.fail(.io, "diagnostic operation");
    }
    fn string(_: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
        const result = (ctx.input(&.{}) orelse return error.InvalidValue).isString();
        try ctx.builder().int(@intFromBool(result));
        try ctx.builder().result();
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
} });
const DiagnosticCooperative = ecl.Port(.{ .cooperative = struct {
    pub const name = "diagnostic-cooperative";
    pub const State = struct { phase: enum { copy, copying, seal, sealing, fail, waiting } = .copy };
    pub const operations = .{
        .diagnose = .{ .name = "cooperative-diagnose", .doc = "Fail with resumably owned diagnostics.", .handler = diagnose, .lane = .operation, .endpoints = .{} },
        .finalize = .{ .name = "diagnostic-finalize", .doc = "Fail after committing with reserved diagnostics.", .handler = finalize, .lane = .operation, .endpoints = .{} },
        .string = .{ .name = "cooperative-string-fact", .doc = "Observe a cooperative string value.", .handler = string, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        if (ctx.input(&.{0})) |mode| if (mode.int() == 1) return report(state, ctx, &.{1});
        return .completed;
    }
    fn report(state: *State, ctx: anytype, path: []const u64) ecl.ControllerError!ecl.CooperativeProgress {
        const builder = ctx.errorData();
        switch (state.phase) {
            .waiting => unreachable,
            .copy => {
                try builder.input(path);
                state.phase = .copying;
            },
            .copying => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                state.phase = .seal;
            },
            .seal => {
                try builder.seal();
                state.phase = .sealing;
            },
            .sealing => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                state.phase = .fail;
            },
            .fail => {
                if (@TypeOf(ctx) == *ecl.Finalizer) try ctx.beginCommit();
                ctx.fail(.io, "cooperative diagnostic failure");
                return .completed;
            },
        }
        return .yielded;
    }
    fn diagnose(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        return report(state, ctx, &.{});
    }
    fn finalize(state: *State, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
        return report(state, ctx, &.{});
    }
    fn string(_: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        const result = (ctx.input(&.{}) orelse return error.InvalidValue).isString();
        try ctx.builder().int(@intFromBool(result));
        try ctx.builder().result();
        return .completed;
    }
    pub fn retireOperation(state: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        state.phase = .copy;
        return .completed;
    }
    pub fn retire(_: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
        return .completed;
    }
} });

fn capacityStarted(call: *ecl.Call("-- count")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(call.instance(Instance).?.capacity_started.load(.acquire))});
}
fn capacityRetirements(call: *ecl.Call("-- count")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(call.instance(Instance).?.capacity_retired.load(.acquire))});
}
const CapacityReporter = ecl.CapacityFailure(struct {
    pub const State = struct {
        phase: enum { copy, copying, seal, sealing, fail, waiting } = .copy,
        remaining: usize = 513,
    };
    pub fn init() State {
        return .{};
    }
    pub fn step(state: *State, ctx: *ecl.RejectedOpen) ecl.RejectionResult {
        if (ctx.input(&.{}).?.kind() == .int and ctx.input(&.{}).?.int() == -1) {
            if (state.phase != .waiting) {
                state.phase = .waiting;
                _ = ctx.instance(Instance).?.capacity_started.fetchAdd(1, .release);
            }
            return .yielded;
        }
        if (ctx.input(&.{}).?.kind() == .list) {
            ctx.fail(.domain, "configured resource capacity reached");
            return .completed;
        }
        if (ctx.input(&.{}).?.kind() != .dict) {
            ctx.fail(.type, "expected a resource configuration dictionary");
            return .completed;
        }
        const builder = ctx.errorData();
        switch (state.phase) {
            .waiting => unreachable,
            .copy => {
                try builder.input(&.{});
                state.phase = .copying;
            },
            .copying => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                state.phase = .seal;
            },
            .seal => {
                try builder.seal();
                state.phase = .sealing;
            },
            .sealing => {
                const progress = try builder.advance();
                if (progress != .completed) return progress;
                state.phase = .fail;
            },
            .fail => {
                ctx.fail(.domain, "configured resource capacity reached");
                return .completed;
            },
        }
        return .yielded;
    }
    pub fn retire(state: *State, ctx: *ecl.RejectedOpen) bool {
        while (state.remaining != 0 and ctx.consume(1)) state.remaining -= 1;
        if (state.remaining != 0) return false;
        _ = ctx.instance(Instance).?.capacity_retired.fetchAdd(1, .release);
        return true;
    }
});

const EagerState = ecl.Instance(struct {
    pub const State = struct { file: ?std.Io.File = null, value: u8 = 0, phase: enum { open, read, close, ready } = .open };
    pub fn init() State {
        return .{};
    }
    pub fn initialize(state: *State, context: *ecl.InstanceContext) ecl.InstanceResult {
        if (!context.consume()) return .pending;
        const io = std.Io.Threaded.global_single_threaded.io();
        switch (state.phase) {
            .open => {
                state.file = std.Io.Dir.cwd().openFile(io, context.configuration(), .{}) catch return error.Failed;
                state.phase = .read;
            },
            .read => {
                const count = state.file.?.readStreaming(io, &.{std.mem.asBytes(&state.value)}) catch return error.Failed;
                if (count != 1) return error.Failed;
                state.phase = .close;
            },
            .close => {
                state.file.?.close(io);
                state.file = null;
                state.phase = .ready;
            },
            .ready => return .complete,
        }
        return .pending;
    }
    pub fn retire(state: *State, context: *ecl.InstanceContext) bool {
        if (!context.consume()) return false;
        if (state.file) |file| file.close(std.Io.Threaded.global_single_threaded.io());
        state.file = null;
        return true;
    }
});
fn eagerValue(call: *ecl.Call("-- value")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(call.instance(EagerState).?.value)});
}
pub const EagerExtension = ecl.module(.{
    .linkage = .static,
    .name = "eagerprobe",
    .doc = "Observe a controlled startup input through instance initialization.",
    .instance = EagerState,
    .words = .{ecl.word("value", "Read the captured byte.", eagerValue)},
});

fn workRetired(call: *ecl.Call("-- count")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(call.instance(Instance).?.work_retired.load(.acquire))});
}
fn workOperationRetired(call: *ecl.Call("-- count")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(call.instance(Instance).?.work_operation_retired.load(.acquire))});
}
fn packedStarted(call: *ecl.Call("-- count")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(call.instance(Instance).?.packed_started.load(.acquire))});
}
const packed_bytes = [_]u8{165} ** (65536 + 1);
const packed_symbol = "λ" ** 300;
const PackedConstruction = struct {
    mode: i64 = 0,
    phase: enum { header, bytes, symbol, chunks, symbol_end, list, dictionary, finish, done } = .header,
    offset: usize = 0,
    fn step(self: *PackedConstruction, builder: anytype, comptime diagnostic: bool) ecl.ControllerError!ecl.CooperativeProgress {
        if (comptime @hasDecl(@typeInfo(@TypeOf(builder)).pointer.child, "advance")) {
            const progress = try builder.advance();
            if (progress == .yielded) return .yielded;
            if (progress != .completed) return error.InvalidValue;
        }
        switch (self.phase) {
            .header => {
                if (diagnostic) try builder.symbol("payload");
                self.phase = .bytes;
            },
            .bytes => {
                const length: usize = switch (self.mode) {
                    1 => 65536,
                    2 => 65537,
                    else => 2,
                };
                try builder.byteList(packed_bytes[0..length]);
                self.phase = .symbol;
            },
            .symbol => {
                try builder.beginSymbol(packed_symbol.len);
                self.phase = .chunks;
            },
            .chunks => {
                const end = @min(self.offset + (if (self.mode == 4) @as(usize, 257) else 255), packed_symbol.len);
                try builder.symbolChunk(packed_symbol[self.offset..end]);
                self.offset = end;
                if (end == packed_symbol.len or self.mode == 3) self.phase = .symbol_end;
            },
            .symbol_end => {
                try builder.endSymbol();
                self.phase = .list;
            },
            .list => {
                try builder.list(2);
                self.phase = if (diagnostic) .dictionary else .finish;
            },
            .dictionary => {
                try builder.dictionary(1);
                self.phase = .finish;
            },
            .finish => {
                if (diagnostic) try builder.seal() else try builder.result();
                self.phase = .done;
            },
            .done => return .completed,
        }
        return .yielded;
    }
};
const PackedController = ecl.Port(.{ .controller = struct {
    pub const name = "packed-controller";
    pub const State = struct { unused: u8 = 0 };
    pub const operations = .{
        .values = .{ .name = "controller-packed-values", .doc = "Build bounded bytes and a chunked symbol.", .handler = values, .lane = .operation, .endpoints = .{} },
        .diagnose = .{ .name = "controller-packed-diagnostic", .doc = "Build bounded diagnostic values.", .handler = diagnose, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
    fn values(_: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
        var building: PackedConstruction = .{ .mode = ctx.input(&.{}).?.int() orelse 0 };
        while (try building.step(ctx.builder(), false) != .completed) {}
    }
    fn diagnose(_: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
        var building: PackedConstruction = .{ .mode = ctx.input(&.{}).?.int() orelse 0 };
        while (try building.step(ctx.errorData(), true) != .completed) {}
        ctx.fail(.io, "packed diagnostic");
    }
} });
const PackedCooperative = ecl.Port(.{ .cooperative = struct {
    pub const name = "packed-cooperative";
    pub const State = struct { building: PackedConstruction = .{}, parked: bool = false, initialization_work: u32 = 0 };
    pub const CapacityFailure = PackedRejection;
    pub const operations = .{
        .budget = .{ .name = "packed-budget", .doc = "Consume and report the host callback work grant.", .handler = budget, .lane = .operation, .endpoints = .{} },
        .initial_budget = .{ .name = "packed-initial-budget", .doc = "Report the initialization work grant.", .handler = initialBudget, .lane = .operation, .endpoints = .{} },
        .values = .{ .name = "cooperative-packed-values", .doc = "Build bytes and a symbol over bounded slices.", .handler = values, .lane = .operation, .endpoints = .{} },
        .diagnose = .{ .name = "cooperative-packed-diagnostic", .doc = "Build resumable diagnostic values.", .handler = diagnose, .lane = .operation, .endpoints = .{} },
        .finalize = .{ .name = "packed-finalize", .doc = "Commit a bounded constructed result.", .handler = finalize, .lane = .operation, .endpoints = .{} },
        .finalize_error = .{ .name = "packed-finalize-error", .doc = "Commit with bounded constructed diagnostics.", .handler = finalizeError, .lane = .operation, .endpoints = .{} },
        .clock = .{ .name = "packed-clock", .doc = "Read the Session-relative monotonic clock.", .handler = clock, .lane = .operation, .endpoints = .{} },
        .park = .{ .name = "packed-park", .doc = "Park with a partly supplied symbol until cancellation.", .handler = park, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        while (ctx.consume(1)) state.initialization_work += 1;
        return .completed;
    }
    fn budget(_: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        var amount: u32 = 0;
        while (ctx.consume(1)) amount += 1;
        try ctx.builder().int(amount);
        try ctx.builder().result();
        return .completed;
    }
    fn initialBudget(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        try ctx.builder().int(state.initialization_work);
        try ctx.builder().result();
        return .completed;
    }
    fn prepare(state: *State, ctx: anytype) void {
        if (state.building.phase == .header) state.building.mode = ctx.input(&.{}).?.int() orelse 0;
    }
    fn values(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        prepare(state, ctx);
        return state.building.step(ctx.builder(), false);
    }
    fn diagnose(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        prepare(state, ctx);
        const progress = try state.building.step(ctx.errorData(), true);
        if (progress == .completed) ctx.fail(.io, "packed diagnostic");
        return progress;
    }
    fn finalize(state: *State, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
        prepare(state, ctx);
        const progress = try state.building.step(ctx.builder(), false);
        if (progress == .completed) try ctx.beginCommit();
        return progress;
    }
    fn finalizeError(state: *State, ctx: *ecl.Finalizer) ecl.ControllerError!ecl.CooperativeProgress {
        prepare(state, ctx);
        const progress = try state.building.step(ctx.errorData(), true);
        if (progress == .completed) {
            try ctx.beginCommit();
            ctx.fail(.io, "committed packed diagnostic");
        }
        return progress;
    }
    fn clock(_: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        try ctx.builder().int(try ctx.monotonicMilliseconds());
        try ctx.builder().result();
        return .completed;
    }
    fn park(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        if (!state.parked) {
            try ctx.builder().beginSymbol(600);
            try ctx.builder().symbolChunk("prefix");
            state.parked = true;
            _ = ctx.instance(Instance).?.packed_started.fetchAdd(1, .release);
        }
        if (!ctx.park(3_600_000)) return error.InvalidValue;
        return .parked;
    }
    pub fn retireOperation(state: *State, ctx: *ecl.Cooperative) ecl.CooperativeProgress {
        var amount: u32 = 0;
        while (ctx.consume(1)) amount += 1;
        ctx.instance(Instance).?.work_operation_retired.store(amount, .release);
        const initial_work = state.initialization_work;
        state.* = .{ .initialization_work = initial_work };
        return .completed;
    }
    pub fn retire(_: *State, ctx: *ecl.Cooperative) ecl.CooperativeProgress {
        var amount: u32 = 0;
        while (ctx.consume(1)) amount += 1;
        ctx.instance(Instance).?.work_retired.store(amount, .release);
        return .completed;
    }
} });
const PackedRejection = ecl.CapacityFailure(struct {
    pub const State = PackedConstruction;
    pub fn init() State {
        return .{};
    }
    pub fn step(state: *State, ctx: *ecl.RejectedOpen) ecl.RejectionResult {
        const progress = try state.step(ctx.errorData(), true);
        if (progress == .completed) {
            ctx.fail(.domain, "packed capacity diagnostic");
            return .completed;
        }
        return .yielded;
    }
    pub fn retire(_: *State, _: *ecl.RejectedOpen) bool {
        return true;
    }
});

fn LoanState(comptime Parent: type) type {
    return struct {
        borrowed: ?*Parent.StateType = null,
        copied: i64 = 0,
        mode: i64 = 0,
        remaining: usize = 513,
        fn parentValue(parent: *Parent.StateType) i64 {
            return if (Parent == Resource) parent.value else parent.copied_parent.?;
        }
        fn acquire(self: *@This(), ctx: anytype) ecl.ControllerError!void {
            self.mode = ctx.input(&.{1}).?.int() orelse return error.InvalidValue;
            const borrowed = ctx.initializationResource(Parent, &.{0}, if (self.mode == 1) .initialization else .resource) catch |err| switch (err) {
                error.Closed => {
                    ctx.fail(.io, "input resource closed");
                    return error.Failed;
                },
                error.InvalidValue => {
                    ctx.fail(.type, "input resource has another issuer or kind");
                    return error.Failed;
                },
                error.Failed => return error.Failed,
            };
            if (self.mode == 4) for (0..32) |_| {
                const again = ctx.initializationResource(Parent, &.{0}, .resource) catch return error.Failed;
                if (again != borrowed) return error.InvalidValue;
            };
            if (self.mode == 5) for (0..17) |index| {
                _ = ctx.initializationResource(Parent, &.{ 2, index }, .resource) catch return error.Failed;
            };
            self.copied = parentValue(borrowed);
            self.borrowed = if (self.mode == 1) null else borrowed;
            if (self.mode == 2) {
                ctx.fail(.io, "requested failure after input lease");
                return error.Failed;
            }
        }
        fn read(self: *@This(), ctx: anytype) ecl.ControllerError!void {
            try ctx.builder().int(if (self.borrowed) |borrowed| parentValue(borrowed) else self.copied);
            try ctx.builder().result();
        }
        fn probe(_: *@This(), ctx: anytype) ecl.ControllerError!void {
            _ = ctx.initializationResource(Parent, &.{0}, .resource) catch |err| {
                if (err != error.InvalidValue) return error.InvalidValue;
                try ctx.builder().int(1);
                try ctx.builder().result();
                return;
            };
            return error.InvalidValue;
        }
    };
}
const ControllerLoan = ecl.Port(.{ .controller = struct {
    pub const name = "controller-loan";
    pub const State = LoanState(Resource);
    pub const operations = .{
        .read = .{ .name = "controller-loan-read", .doc = "Read admitted native state through its lifetime lease.", .handler = read, .lane = .operation, .endpoints = .{} },
        .probe = .{ .name = "controller-loan-probe", .doc = "Reject lifetime acquisition after initialization.", .handler = probe, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, ctx: *ecl.Controller) void {
        state.acquire(ctx) catch |err| switch (err) {
            error.OutOfMemory => ctx.failOutOfMemory(),
            error.Cancelled, error.Failed => {},
            error.InvalidValue => ctx.fail(.type, "invalid lease configuration"),
        };
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
    fn read(state: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
        try state.read(ctx);
    }
    fn probe(state: *State, ctx: *ecl.Controller) ecl.ControllerError!void {
        try state.probe(ctx);
    }
} });
fn CooperativeLoanType(comptime Parent: type, comptime resource_name: []const u8) type {
    return ecl.Port(.{ .cooperative = struct {
        pub const name = resource_name;
        pub const State = LoanState(Parent);
        pub const operations = .{
            .read = .{ .name = resource_name ++ "-read", .doc = "Read admitted native state through its lifetime lease.", .handler = read, .lane = .operation, .endpoints = .{} },
            .probe = .{ .name = resource_name ++ "-probe", .doc = "Reject lifetime acquisition after initialization.", .handler = probe, .lane = .operation, .endpoints = .{} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            try state.acquire(ctx);
            if (state.mode == 3) {
                ctx.instance(Instance).?.cooperative_started.store(5, .release);
                if (!ctx.park(3_600_000)) return error.InvalidValue;
                return .parked;
            }
            return .completed;
        }
        fn read(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            try state.read(ctx);
            return .completed;
        }
        fn probe(state: *State, ctx: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            try state.probe(ctx);
            return .completed;
        }
        pub fn retireOperation(_: *State, _: *ecl.Cooperative) ecl.CooperativeProgress {
            return .completed;
        }
        pub fn retire(state: *State, ctx: *ecl.Cooperative) ecl.CooperativeProgress {
            while (state.remaining != 0 and ctx.consume(1)) state.remaining -= 1;
            return if (state.remaining == 0) .completed else .yielded;
        }
    } });
}
const CooperativeLoan = CooperativeLoanType(Resource, "cooperative-loan");
const FinalizationLoan = CooperativeLoanType(CooperativeResource, "finalization-loan");

pub const ForeignLoanExtension = ecl.module(.{
    .linkage = .static,
    .name = "loanforeign",
    .doc = "Separate instance for native input lease authority checks.",
    .instance = Instance,
    .ports = .{ Resource, CooperativeLoan },
    .words = .{ ecl.factory("resource", "Create a separately issued resource.", Resource), ecl.factory("loan", "Attempt a separately issued resource loan.", CooperativeLoan) },
});
