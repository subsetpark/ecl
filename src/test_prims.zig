//! Closed substrate for first-class test discovery and protected invocation.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const dict = @import("dict.zig");
const env = @import("env.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const modules = @import("modules.zig");
const poll = @import("poll.zig");
const scheduler_api = @import("scheduler.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Definition = struct { name: []const u8, primitive: env.PrimitiveImpl };

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]Definition{
        .{ .name = "tests", .primitive = discover },
        .{ .name = "@test", .primitive = invoke },
    };
    try core.installBuiltins(definitions);
}

const DescriptorKeys = struct {
    module: u32,
    name: u32,
    effect: u32,
    doc: u32,

    fn init() error{OutOfMemory}!DescriptorKeys {
        return .{
            .module = try intern.intern("module"),
            .name = try intern.intern("name"),
            .effect = try intern.intern("effect"),
            .doc = try intern.intern("doc"),
        };
    }
};

const Collected = struct {
    module: intern.ModuleName,
    metadata: modules.ModuleTestMetadata,

    fn retain(self: Collected) void {
        if (self.metadata.effect) |effect| effect.retain();
        if (self.metadata.doc) |doc| heap.incRef(env.documentationHeader(doc));
    }

    fn retire(self: Collected, releases: *heap.ReleaseDomain) void {
        if (self.metadata.effect) |effect| effect.retire(releases);
        if (self.metadata.doc) |doc| releases.releaseHeader(env.documentationHeader(doc));
    }
};

const CollectedComparator = struct {
    pub const Context = void;
    pub const Cursor = struct {
        left_module: []const u8,
        right_module: []const u8,
        left_name: []const u8,
        right_name: []const u8,
        phase: enum { module, name } = .module,
        index: usize = 0,
    };

    pub fn init(_: Context, left: Collected, right: Collected) Cursor {
        return .{
            .left_module = intern.get(intern.moduleId(left.module)),
            .right_module = intern.get(intern.moduleId(right.module)),
            .left_name = intern.get(intern.bindingId(left.metadata.name)),
            .right_name = intern.get(intern.bindingId(right.metadata.name)),
        };
    }

    pub fn advance(cursor: *Cursor, budget: usize) poll.Progress(std.math.Order) {
        std.debug.assert(budget != 0);
        var remaining = budget;
        while (remaining != 0) {
            const left = if (cursor.phase == .module) cursor.left_module else cursor.left_name;
            const right = if (cursor.phase == .module) cursor.right_module else cursor.right_name;
            const shared = @min(left.len, right.len);
            if (cursor.index == shared) {
                if (left.len != right.len)
                    return .{ .complete = if (left.len < right.len) .lt else .gt };
                if (cursor.phase == .name) return .{ .complete = .eq };
                cursor.phase = .name;
                cursor.index = 0;
                continue;
            }
            const left_byte = left[cursor.index];
            const right_byte = right[cursor.index];
            cursor.index += 1;
            remaining -= 1;
            if (left_byte != right_byte)
                return .{ .complete = if (left_byte < right_byte) .lt else .gt };
        }
        return .pending;
    }
};

const CollectedSortCursor = poll.MergeSortCursor(Collected, CollectedComparator);

fn descriptorValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    keys: DescriptorKeys,
    item: Collected,
) error{OutOfMemory}!Value {
    var pairs: [4]dict.Pair = undefined;
    var count: usize = 0;
    pairs[count] = .{
        .{ .symbol = keys.module },
        .{ .symbol = intern.moduleId(item.module) },
    };
    count += 1;
    pairs[count] = .{
        .{ .symbol = keys.name },
        .{ .symbol = intern.bindingId(item.metadata.name) },
    };
    count += 1;
    if (item.metadata.effect) |effect| {
        pairs[count] = .{ .{ .symbol = keys.effect }, .{ .list = effect.header() } };
        count += 1;
    }
    if (item.metadata.doc) |doc| {
        pairs[count] = .{ .{ .symbol = keys.doc }, .{ .list = env.documentationHeader(doc) } };
        count += 1;
    }
    return dict.fromUniquePairs(allocator, releases, pairs[0..count]);
}

const DiscoveryDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;

    cursor: ?modules.Registry.TestDiscoveryCursor,
    items: std.ArrayList(Collected) = .empty,
    values: ?heap.OwnedValueBuffer = null,
    sorter: ?CollectedSortCursor = null,
    keys: DescriptorKeys,
    phase: enum { discover, sort, descriptors, finish } = .discover,
    descriptor_index: usize = 0,

    pub fn deinit(
        self: *DiscoveryDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.cursor) |*cursor| cursor.deinit();
        if (self.sorter) |*sorter| sorter.deinit();
        if (self.values) |*values| values.deinit();
        for (self.items.items) |item| item.retire(releases);
        self.items.deinit(allocator);
    }

    pub fn advance(
        evaluator: *Machine,
        self: *DiscoveryDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .discover => switch (self.cursor.?.advance()) {
                .pending => budget -= 1,
                .item => |found| {
                    try self.items.ensureUnusedCapacity(evaluator.allocator(), 1);
                    const item = Collected{ .module = found.module, .metadata = found.metadata };
                    item.retain();
                    self.items.appendAssumeCapacity(item);
                    budget -= 1;
                },
                .complete => {
                    self.cursor.?.deinit();
                    self.cursor = null;
                    self.phase = .sort;
                },
            },
            .sort => {
                if (self.sorter == null)
                    self.sorter = try .init(evaluator.allocator(), self.items.items, {});
                switch (self.sorter.?.advance(1)) {
                    .pending => budget -= 1,
                    .complete => {
                        self.sorter.?.deinit();
                        self.sorter = null;
                        self.values = try heap.OwnedValueBuffer.init(
                            evaluator.releaseDomain(),
                            self.items.items.len,
                        );
                        self.phase = .descriptors;
                    },
                }
            },
            .descriptors => {
                if (self.descriptor_index == self.items.items.len) {
                    self.phase = .finish;
                    continue;
                }
                self.values.?.appendOwned(try descriptorValue(
                    evaluator.allocator(),
                    evaluator.releaseDomain(),
                    self.keys,
                    self.items.items[self.descriptor_index],
                ));
                self.descriptor_index += 1;
                budget -= 1;
            },
            .finish => {
                const result = self.values.?.takeList();
                self.values = null;
                return .{ .output = result };
            },
        };
        return .yielded;
    }
};

fn discover(evaluator: *Machine) MachineError!void {
    const access = evaluator.unit.inherited.test_observation orelse
        return evaluator.fail(.domain, "tests is available only in a test Session");
    const keys = try DescriptorKeys.init();
    const driver = try evaluator.allocator().create(DiscoveryDriver);
    driver.* = .{
        .cursor = access.discoveryCursor(),
        .keys = keys,
    };
    evaluator.adoptDriver(driver);
}

const InvocationDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;

    descriptor: heap.Owned(Value),
    keys: DescriptorKeys,
    scan_index: usize = 0,
    module_id: ?u32 = null,
    name_id: ?u32 = null,
    module_validation: ?intern.ModuleNameCursor = null,
    name_validation: ?intern.NamespaceCursor = null,
    module_name: ?intern.ModuleName = null,
    test_name: ?intern.BindingName = null,
    lookup: ?modules.Registry.TestLookupCursor = null,

    pub fn deinit(
        self: *InvocationDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.lookup) |*lookup| lookup.deinit();
        self.descriptor.deinit(releases, allocator);
    }

    fn invalid(evaluator: *Machine) MachineError {
        return evaluator.fail(
            .domain,
            "@test requires a descriptor produced by tests",
        );
    }

    fn missingOutcome(evaluator: *Machine) error{OutOfMemory}!Value {
        var failure = machine.EclErr.init(.domain, "test descriptor names no current test");
        defer failure.retire(evaluator.releaseDomain());
        const payload = try machine.errorValue(
            evaluator.allocator(),
            evaluator.releaseDomain(),
            &failure,
            .{},
            null,
        );
        return machine.outcomeDict(
            evaluator.allocator(),
            evaluator.releaseDomain(),
            "err",
            payload,
        );
    }

    pub fn advance(
        evaluator: *Machine,
        self: *InvocationDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) {
            if (self.lookup) |*lookup| switch (lookup.advance()) {
                .pending => {
                    budget -= 1;
                    continue;
                },
                .complete => |maybe_invocation| {
                    if (maybe_invocation == null)
                        return .{ .output = try missingOutcome(evaluator) };
                    var invocation = maybe_invocation.?;
                    defer invocation.deinit();
                    var target = invocation.enter(evaluator.unit.module_access);
                    defer target.deinit();
                    const home = target.home(evaluator.unit.module_access);
                    const scheduler: *const scheduler_api.WorkerScheduler =
                        @ptrCast(@alignCast(evaluator.unit.scheduler.?));
                    const scope: *scheduler_api.TaskScope =
                        @ptrCast(@alignCast(evaluator.unit.task_scope.?));
                    const task = scheduler.spawn(scope, .{
                        .parent_unit = evaluator.unit,
                        .site = .{ .module = home },
                        .quotation = target.quotation(),
                        .constructor = .@"test",
                    }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Io => return evaluator.fail(
                            .io,
                            "could not start scheduler workers for @test",
                        ),
                        // @test requests no resource transfer.
                        error.Transfer => unreachable,
                    };
                    const allocator = evaluator.allocator();
                    const releases = evaluator.releaseDomain();
                    evaluator.detachWorkDriver(self);
                    self.deinit(releases, allocator);
                    allocator.destroy(self);
                    try evaluator.park(.{ .task = task });
                    return .detached;
                },
            };

            if (self.module_validation) |*validation| switch (validation.advance()) {
                .pending => {
                    budget -= 1;
                    continue;
                },
                .complete => |maybe_name| {
                    self.module_validation = null;
                    self.module_name = maybe_name orelse return invalid(evaluator);
                    self.name_validation = .init(self.name_id.?);
                    continue;
                },
            };
            if (self.name_validation) |*validation| switch (validation.advance()) {
                .pending => {
                    budget -= 1;
                    continue;
                },
                .complete => |maybe_name| {
                    self.name_validation = null;
                    self.test_name = maybe_name orelse return invalid(evaluator);
                    self.lookup = evaluator.unit.inherited.test_execution.?.lookupCursor(
                        self.module_name.?,
                        self.test_name.?,
                    );
                    continue;
                },
            };

            const descriptor = self.descriptor.borrow();
            const count: usize = @intCast(descriptor.dict.length());
            if (self.scan_index != count) {
                const key = dict.keyAt(descriptor.dict, self.scan_index);
                const payload = dict.valueAt(descriptor.dict, self.scan_index);
                self.scan_index += 1;
                if (key != .symbol) return invalid(evaluator);
                if (key.symbol == self.keys.module) {
                    if (self.module_id != null or payload != .symbol) return invalid(evaluator);
                    self.module_id = payload.symbol;
                } else if (key.symbol == self.keys.name) {
                    if (self.name_id != null or payload != .symbol) return invalid(evaluator);
                    self.name_id = payload.symbol;
                } else if (key.symbol != self.keys.effect and key.symbol != self.keys.doc) {
                    return invalid(evaluator);
                }
                budget -= 1;
                continue;
            }
            if (self.module_id == null or self.name_id == null) return invalid(evaluator);
            self.module_validation = .init(self.module_id.?);
        }
        return .yielded;
    }
};

fn invoke(evaluator: *Machine) MachineError!void {
    if (evaluator.unit.inherited.test_execution == null)
        return evaluator.fail(.domain, "@test is available only in a test Session");
    var descriptor = try evaluator.popValue();
    defer descriptor.deinit();
    if (descriptor.borrow() != .dict)
        return evaluator.fail(.domain, "@test requires a descriptor produced by tests");
    const keys = try DescriptorKeys.init();
    const driver = try evaluator.allocator().create(InvocationDriver);
    driver.* = .{
        .descriptor = .init(descriptor.take()),
        .keys = keys,
    };
    evaluator.adoptDriver(driver);
}
