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

const Resource = ecl.Port(struct {
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
});

pub const Extension = ecl.module(.{
    .linkage = .static,
    .name = "instanceprobe",
    .doc = "Instance isolation and retirement probe.",
    .instance = Instance,
    .ports = .{Resource},
    .words = .{
        ecl.word("next", "Read and increment instance state.", value),
        ecl.word("allocate", "Allocate and release native storage.", allocations),
        ecl.word("retirements", "Count completed fixture retirements.", retirements),
        ecl.factory("resource", "Open a configured resource.", Resource),
    },
});

comptime {
    _ = Extension;
}
