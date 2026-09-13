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
    pub const State = struct { value: i64 = 0 };
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
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
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
            return createChild(state, context, false);
        }
        fn dependent(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
            return createChild(state, context, true);
        }
        fn createChild(state: *State, context: *ecl.Cooperative, comptime dependent_child: bool) ecl.ControllerError!ecl.CooperativeProgress {
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
                    try builder.child(CooperativeResource, if (dependent_child) .dependent else .independent);
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
            received: usize = 0,
        };
        pub const endpoints = .{
            .input = ecl.declarations.Endpoint{ .name = "activity-in", .doc = "Feed the joined byte pump.", .transport = .bytes, .direction = .input, .owner = .resource },
            .output = ecl.declarations.Endpoint{ .name = "activity-out", .doc = "Read the joined byte pump.", .transport = .bytes, .direction = .output, .owner = .resource },
            .ready = ecl.declarations.Endpoint{ .name = "activity-ready", .doc = "Read the independent startup marker.", .transport = .bytes, .direction = .output, .owner = .resource },
        };
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
        pub fn cancel(_: *State) void {}
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
                if (state.mode == 5) {
                    context.fail(.io, "failure after accepted output");
                    return;
                }
            }
        }
        fn marker(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            defer _ = state.finished.fetchAdd(1, .release);
            if (!context.cancelled()) try (try context.endpoint(ActivityResource, .ready)).write(&.{7});
        }
    },
});

pub const Extension = ecl.module(.{
    .linkage = .static,
    .name = "instanceprobe",
    .doc = "Instance isolation and retirement probe.",
    .instance = Instance,
    .ports = .{ Resource, CooperativeResource, ActivityResource },
    .words = .{
        ecl.overload("private-value", "Read privately declared operation members.", .{ .{ Resource, .private_value }, .{ CooperativeResource, .private_value } }),
        ecl.overload("shared-value", "Read either controller or cooperative resource state.", .{ .{ Resource, .value }, .{ CooperativeResource, .borrowed } }),
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
