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
const module_snapshot = @import("module_snapshot.zig");
const scheduler_api = @import("scheduler.zig");

const Value = value.Value;
const Unit = machine.Unit;
const MachineError = machine.MachineError;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "tests", .primitive = discover, .effect = "-- descriptors", .doc = "Test-Session-only discovery of current canonical registrations, including root sources' private registrations, sorted by module then test name and source identifier. Each dictionary contains symbol fields `` `module `` and `` `name `` plus optional declared `` `effect `` and `` `doc ``. File-private registrations also include an integer `` `source `` identifier local to the test Session, distinguishing equal names in different files. Descriptors never contain executable bodies or authority handles. Aliases do not duplicate entries. Ordinary Sessions receive `` `domain ``." },
        .{ .name = "@test", .primitive = invoke, .effect = "descriptor -- result", .doc = "Test-Session-only protected invocation. Validate a pure descriptor returned by `tests`, late-bind its module/name and optional source identifier to the current catalog, and run the body as a fresh isolated Unit under that registration's private home and durable state. Return exactly `{ok (values)}` or `{err error}`; a missing current test is a reified error. Ordinary Sessions receive `` `domain ``." },
    };
    try core.installBuiltins(&definitions);
}

const DescriptorKeys = struct {
    module: u32,
    name: u32,
    effect: u32,
    doc: u32,
    source: u32,

    fn init() error{OutOfMemory}!DescriptorKeys {
        return .{
            .module = try intern.intern("module"),
            .name = try intern.intern("name"),
            .effect = try intern.intern("effect"),
            .doc = try intern.intern("doc"),
            .source = try intern.intern("source"),
        };
    }
};

const Collected = struct {
    module: intern.ModuleName,
    source: ?module_snapshot.ArtifactId,
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
    pub const Error = error{};
    pub fn deinit(_: *Cursor) void {}
    pub const Cursor = struct {
        left_module: []const u8,
        right_module: []const u8,
        left_name: []const u8,
        right_name: []const u8,
        source_order: std.math.Order,
        phase: enum { module, name } = .module,
        index: usize = 0,
    };

    pub fn init(_: Context, left: Collected, right: Collected) Cursor {
        return .{
            .source_order = std.math.order(if (left.source) |id| @as(i64, @backingInt(id)) else -1, if (right.source) |id| @as(i64, @backingInt(id)) else -1),
            .left_module = intern.get(intern.moduleId(left.module)),
            .right_module = intern.get(intern.moduleId(right.module)),
            .left_name = intern.get(intern.bindingId(left.metadata.name)),
            .right_name = intern.get(intern.bindingId(right.metadata.name)),
        };
    }

    pub fn advance(cursor: *Cursor, work: *poll.WorkBudget) Error!poll.Progress(std.math.Order) {
        while (true) {
            const left = if (cursor.phase == .module) cursor.left_module else cursor.left_name;
            const right = if (cursor.phase == .module) cursor.right_module else cursor.right_name;
            const shared = @min(left.len, right.len);
            if (cursor.index == shared) {
                if (left.len != right.len)
                    return .{ .complete = if (left.len < right.len) .lt else .gt };
                if (cursor.phase == .name) return .{ .complete = cursor.source_order };
                cursor.phase = .name;
                cursor.index = 0;
                continue;
            }
            if (!work.spend()) return .pending;
            const left_byte = left[cursor.index];
            const right_byte = right[cursor.index];
            cursor.index += 1;
            if (left_byte != right_byte)
                return .{ .complete = if (left_byte < right_byte) .lt else .gt };
        }
    }
};

const CollectedSortCursor = poll.MergeSortCursor(Collected, CollectedComparator);

fn descriptorValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    keys: DescriptorKeys,
    item: Collected,
) error{OutOfMemory}!Value {
    var pairs: [5]dict.Pair = undefined;
    var count: usize = 0;
    pairs[count] = .{
        .{ .symbol = .{ .name = keys.module } },
        .{ .symbol = .{ .name = intern.moduleId(item.module) } },
    };
    count += 1;
    pairs[count] = .{
        .{ .symbol = .{ .name = keys.name } },
        .{ .symbol = .{ .name = intern.bindingId(item.metadata.name) } },
    };
    count += 1;
    if (item.source) |source| {
        pairs[count] = .{ .{ .symbol = .{ .name = keys.source } }, .{ .int = @backingInt(source) } };
        count += 1;
    }
    if (item.metadata.effect) |effect| {
        pairs[count] = .{ .{ .symbol = .{ .name = keys.effect } }, .{ .list = effect.header() } };
        count += 1;
    }
    if (item.metadata.doc) |doc| {
        pairs[count] = .{ .{ .symbol = .{ .name = keys.doc } }, .{ .list = env.documentationHeader(doc) } };
        count += 1;
    }
    return dict.fromUniquePairs(allocator, releases, pairs[0..count]);
}

const DiscoveryDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;

    cursor: ?modules.TestSessionDiscoveryCursor,
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
        evaluator: *Unit,
        self: *DiscoveryDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .discover => switch (self.cursor.?.advance()) {
                .pending => _ = work.spend(),
                .item => |found| {
                    try self.items.ensureUnusedCapacity(evaluator.allocator, 1);
                    const item = Collected{ .module = found.module, .source = found.source, .metadata = found.metadata };
                    item.retain();
                    self.items.appendAssumeCapacity(item);
                    _ = work.spend();
                },
                .complete => {
                    self.cursor.?.deinit();
                    self.cursor = null;
                    self.phase = .sort;
                },
            },
            .sort => {
                if (self.sorter == null)
                    self.sorter = try .init(evaluator.allocator, self.items.items, {});
                switch (self.sorter.?.advance(work) catch |err| switch (err) {}) {
                    .pending => _ = work.spend(),
                    .complete => {
                        self.sorter.?.deinit();
                        self.sorter = null;
                        self.values = try heap.OwnedValueBuffer.init(
                            evaluator.releases,
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
                    evaluator.allocator,
                    evaluator.releases,
                    self.keys,
                    self.items.items[self.descriptor_index],
                ));
                self.descriptor_index += 1;
                _ = work.spend();
            },
            .finish => {
                const result = self.values.?.takeList();
                self.values = null;
                return .{ .output = result };
            },
        };
        return .stepped;
    }
};

fn discover(evaluator: *Unit) MachineError!void {
    const access = evaluator.inherited.test_observation orelse
        return evaluator.fail(.domain, "tests is available only in a test Session");
    const keys = try DescriptorKeys.init();
    const driver = try evaluator.allocator.create(DiscoveryDriver);
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
    source_id: ?module_snapshot.ArtifactId = null,
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

    fn invalid(evaluator: *Unit) MachineError {
        return evaluator.fail(
            .domain,
            "@test requires a descriptor produced by tests",
        );
    }

    fn missingOutcome(evaluator: *Unit) error{OutOfMemory}!Value {
        var failure = machine.EclErr.init(.domain, "test descriptor names no current test");
        defer failure.retire(evaluator.releases);
        const payload = try machine.errorValue(
            evaluator.allocator,
            evaluator.releases,
            &failure,
            .{},
            null,
        );
        return machine.outcomeDict(
            evaluator.allocator,
            evaluator.releases,
            "err",
            payload,
        );
    }

    pub fn advance(
        evaluator: *Unit,
        self: *InvocationDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) {
            if (self.lookup) |*lookup| switch (lookup.advance()) {
                .pending => {
                    _ = work.spend();
                    continue;
                },
                .complete => |maybe_invocation| {
                    if (maybe_invocation == null)
                        return .{ .output = try missingOutcome(evaluator) };
                    var invocation = maybe_invocation.?;
                    defer invocation.deinit();
                    var target = invocation.enter(evaluator.module_access);
                    defer target.deinit();
                    const home = target.home(evaluator.module_access);
                    const scheduler: *const scheduler_api.WorkerScheduler =
                        @ptrCast(@alignCast(evaluator.scheduler.?));
                    const scope: *scheduler_api.TaskScope =
                        @ptrCast(@alignCast(evaluator.task_scope.?));
                    const task = scheduler.spawn(scope, .{
                        .parent_unit = evaluator,
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
                    const allocator = evaluator.allocator;
                    const releases = evaluator.releases;
                    evaluator.detachWorkDriver(self);
                    self.deinit(releases, allocator);
                    allocator.destroy(self);
                    try evaluator.park(.{ .task = task });
                    return .detached;
                },
            };

            if (self.module_validation) |*validation| switch (validation.advance()) {
                .pending => {
                    _ = work.spend();
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
                    _ = work.spend();
                    continue;
                },
                .complete => |maybe_name| {
                    self.name_validation = null;
                    self.test_name = maybe_name orelse return invalid(evaluator);
                    self.lookup = evaluator.inherited.test_execution.?.lookupCursor(
                        self.module_name.?,
                        self.test_name.?,
                        self.source_id,
                    );
                    if (self.lookup == null) return .{ .output = try missingOutcome(evaluator) };
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
                if (key.symbol.name == self.keys.module) {
                    if (self.module_id != null or payload != .symbol) return invalid(evaluator);
                    self.module_id = payload.symbol.name;
                } else if (key.symbol.name == self.keys.name) {
                    if (self.name_id != null or payload != .symbol) return invalid(evaluator);
                    self.name_id = payload.symbol.name;
                } else if (key.symbol.name == self.keys.source) {
                    if (self.source_id != null or payload != .int or payload.int < 0 or payload.int > std.math.maxInt(u32)) return invalid(evaluator);
                    self.source_id = @fromBackingInt(@intCast(@as(u32, @intCast(payload.int))));
                } else if (key.symbol.name != self.keys.effect and key.symbol.name != self.keys.doc) {
                    return invalid(evaluator);
                }
                _ = work.spend();
                continue;
            }
            if (self.module_id == null or self.name_id == null) return invalid(evaluator);
            self.module_validation = .init(self.module_id.?);
        }
        return .stepped;
    }
};

fn invoke(evaluator: *Unit) MachineError!void {
    if (evaluator.inherited.test_execution == null)
        return evaluator.fail(.domain, "@test is available only in a test Session");
    var descriptor = try evaluator.popValue();
    defer descriptor.deinit();
    if (descriptor.borrow() != .dict)
        return evaluator.fail(.domain, "@test requires a descriptor produced by tests");
    const keys = try DescriptorKeys.init();
    const driver = try evaluator.allocator.create(InvocationDriver);
    driver.* = .{
        .descriptor = .init(descriptor.take()),
        .keys = keys,
    };
    evaluator.adoptDriver(driver);
}
