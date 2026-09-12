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
fn retirements(call: *ecl.Call("-- value")) ecl.CallbackResult {
    return call.complete(.{ecl.Scalar.int(retired.load(.monotonic))});
}

const Resource = ecl.Port(.{ .controller = struct {
    pub const name = "resource";
    pub const State = struct { value: i64 = 0 };
    pub const operations = .{ .value = .{ .doc = "Read the host-configured value.", .handler = read, .lane = .operation, .endpoints = .{} } };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, controller: *ecl.Controller) void {
        const instance = controller.instance(Instance) orelse return controller.fail(.contract, "missing instance");
        state.value = instance.value.load(.monotonic);
    }
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
    fn read(state: *State, controller: *ecl.Controller) ecl.ControllerError!void {
        const builder = controller.builder();
        try builder.int(state.value);
        try builder.result();
    }
} });

fn cooperativeStarted(call: *ecl.Call("-- value")) ecl.CallbackResult {
    const state = call.instance(Instance) orelse return call.fail(.contract, "missing instance");
    return call.complete(.{ecl.Scalar.int(state.cooperative_started.load(.acquire))});
}
const CooperativeResource = ecl.Port(.{ .cooperative = struct {
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
    };
    pub const operations = .{
        .values = .{ .doc = "Build a result over several bounded slices.", .handler = values, .lane = .operation, .endpoints = .{} },
        .park = .{ .doc = "Park until cancelled, then join private retirement.", .handler = park, .lane = .operation, .endpoints = .{} },
    };
    pub fn init() State {
        return .{};
    }
    pub fn open(state: *State, context: *ecl.Cooperative) ecl.ControllerError!ecl.CooperativeProgress {
        const instance = context.instance(Instance) orelse return error.InvalidValue;
        state.memory = instance.memory;
        if (state.bytes == null) state.bytes = try state.memory.?.allocate(1024);
        while (state.initialized < state.bytes.?.len and context.consume(1)) {
            state.bytes.?[state.initialized] = @truncate(state.initialized);
            state.initialized += 1;
        }
        if (state.initialized != state.bytes.?.len) return .yielded;
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
                if (!try builder.advance()) return .yielded;
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
    pub fn retireOperation(state: *State, context: *ecl.Cooperative) ecl.CooperativeProgress {
        while (state.retire_remaining != 0 and context.consume(1)) state.retire_remaining -= 1;
        if (state.retire_remaining != 0) return .yielded;
        state.phase = .start;
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
} });

pub const Extension = ecl.module(.{
    .linkage = .static,
    .name = "instanceprobe",
    .doc = "Instance isolation and retirement probe.",
    .instance = Instance,
    .ports = .{ Resource, CooperativeResource },
    .words = .{
        ecl.word("next", "Read and increment instance state.", value),
        ecl.word("allocate", "Allocate and release native storage.", allocations),
        ecl.word("retirements", "Count completed fixture retirements.", retirements),
        ecl.factory("resource", "Open a configured resource.", Resource),
        ecl.factory("cooperative", "Open a resumable resource.", CooperativeResource),
        ecl.word("started", "Observe cooperative operation startup.", cooperativeStarted),
    },
});

comptime {
    _ = Extension;
}
