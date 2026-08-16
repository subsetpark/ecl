//! Poll-aware ordering and output for interned reflection names.
const std = @import("std");
const env = @import("env.zig");
const intern = @import("intern.zig");
const modules = @import("modules.zig");
const printer = @import("print.zig");
const resolution_core = @import("resolution_core.zig");
const value = @import("value.zig");

pub const Action = union(enum) {
    bytes: []const u8,
    name: u32,
    value: value.Value,
};

pub const VisibleNameRoot = union(enum) {
    scope: *env.Scope,
    environment: env.EnvironmentView,
};

pub const VisibleNameProgress = union(enum) { pending, complete, name: u32 };
/// The one public-name traversal shared by reflection and Session completion.
/// A scope root is retained for the cursor's whole lifetime; all environment,
/// directory, and generation storage is reached only through owned leases.
pub const VisibleNameCursor = struct {
    const AfterEnvironment = union(enum) { scopes: ?*env.Scope, core };
    const DirectState = struct {
        cursor: env.NameCursor,
        after: AfterEnvironment,
    };
    const UsesState = struct {
        shape: env.ShapeLease,
        ordinal: usize,
        after: AfterEnvironment,
    };
    const AcquireState = struct {
        shape: env.ShapeLease,
        ordinal: usize,
        after: AfterEnvironment,
        cursor: modules.Registry.AcquireCursor,
    };
    const ExportState = struct {
        shape: env.ShapeLease,
        ordinal: usize,
        after: AfterEnvironment,
        generation: modules.GenerationLease,
        cursor: modules.ModuleGeneration.PublicNameCursor,
    };
    const Phase = union(enum) {
        scopes: struct { current: ?*env.Scope },
        direct: DirectState,
        uses: UsesState,
        acquire: AcquireState,
        exports: ExportState,
        core: env.NameCursor,
        complete,
    };

    retained_scope: ?*env.Scope,
    core: env.EnvironmentView,
    registry: ?*const modules.Registry,
    phase: Phase,

    pub fn init(
        root: VisibleNameRoot,
        core: env.EnvironmentView,
        registry: ?*const modules.Registry,
    ) VisibleNameCursor {
        return switch (root) {
            .scope => |scope| result: {
                scope.retain();
                break :result .{
                    .retained_scope = scope,
                    .core = core,
                    .registry = registry,
                    .phase = .{ .scopes = .{ .current = scope } },
                };
            },
            .environment => |environment| .{
                .retained_scope = null,
                .core = core,
                .registry = registry,
                .phase = .{ .direct = .{
                    .cursor = environment.nameCursor(),
                    .after = .core,
                } },
            },
        };
    }

    pub fn deinit(self: *VisibleNameCursor) void {
        switch (self.phase) {
            .scopes, .complete => {},
            .direct => |*state| state.cursor.deinit(),
            .uses => |*state| state.shape.deinit(),
            .acquire => |*state| {
                state.cursor.deinit();
                state.shape.deinit();
            },
            .exports => |*state| {
                state.cursor.deinit();
                state.generation.deinit();
                state.shape.deinit();
            },
            .core => |*cursor| cursor.deinit(),
        }
        if (self.retained_scope) |scope| scope.retire();
        self.* = undefined;
    }

    fn continueAfter(self: *VisibleNameCursor, after: AfterEnvironment) void {
        self.phase = switch (after) {
            .scopes => |current| .{ .scopes = .{ .current = current } },
            .core => .{ .core = self.core.nameCursor() },
        };
    }

    fn finishEnvironment(
        self: *VisibleNameCursor,
        state: *DirectState,
    ) void {
        const current = state.cursor.shape.environment;
        const after = state.after;
        state.cursor.deinit();
        if (self.registry == null) {
            self.continueAfter(after);
            return;
        }
        self.phase = .{ .uses = .{
            .shape = current.acquireShape(),
            .ordinal = 0,
            .after = after,
        } };
    }

    fn publicEntry(entry: env.NameEntry) VisibleNameProgress {
        var lease = entry.lease;
        defer lease.deinit();
        return if (lease.visibility == .public) .{ .name = entry.name } else .pending;
    }

    pub fn advance(self: *VisibleNameCursor) VisibleNameProgress {
        return switch (self.phase) {
            .scopes => |*state| result: {
                const current = state.current orelse {
                    self.phase = .{ .core = self.core.nameCursor() };
                    break :result .pending;
                };
                const next = current.parent;
                const environment = current.environmentOrNull() orelse {
                    state.current = next;
                    break :result .pending;
                };
                self.phase = .{ .direct = .{
                    .cursor = environment.nameCursor(),
                    .after = .{ .scopes = next },
                } };
                break :result .pending;
            },
            .direct => |*state| switch (state.cursor.advance()) {
                .pending => .pending,
                .entry => |entry| publicEntry(entry),
                .complete => result: {
                    self.finishEnvironment(state);
                    break :result .pending;
                },
            },
            .uses => |*state| result: {
                const uses = state.shape.useOrder();
                const index = resolution_core.usedIndex(uses.len, state.ordinal) orelse {
                    const after = state.after;
                    state.shape.deinit();
                    self.continueAfter(after);
                    break :result .pending;
                };
                self.phase = .{ .acquire = .{
                    .shape = state.shape,
                    .ordinal = state.ordinal + 1,
                    .after = state.after,
                    .cursor = self.registry.?.acquireCursor(uses[index]),
                } };
                break :result .pending;
            },
            .acquire => |*state| switch (state.cursor.advance()) {
                .pending => .pending,
                .complete => |maybe_generation| result: {
                    state.cursor.deinit();
                    if (maybe_generation) |lease| {
                        var generation = lease;
                        self.phase = .{ .exports = .{
                            .shape = state.shape,
                            .ordinal = state.ordinal,
                            .after = state.after,
                            .cursor = generation.publicNameCursor(),
                            .generation = generation,
                        } };
                    } else self.phase = .{ .uses = .{
                        .shape = state.shape,
                        .ordinal = state.ordinal,
                        .after = state.after,
                    } };
                    break :result .pending;
                },
            },
            .exports => |*state| switch (state.cursor.advance()) {
                .pending => .pending,
                .name => |name| .{ .name = name },
                .complete => result: {
                    state.cursor.deinit();
                    state.generation.deinit();
                    self.phase = .{ .uses = .{
                        .shape = state.shape,
                        .ordinal = state.ordinal,
                        .after = state.after,
                    } };
                    break :result .pending;
                },
            },
            .core => |*cursor| switch (cursor.advance()) {
                .pending => .pending,
                .entry => |entry| publicEntry(entry),
                .complete => result: {
                    cursor.deinit();
                    self.phase = .complete;
                    break :result .complete;
                },
            },
            .complete => .complete,
        };
    }
};

pub const PlanProgress = enum { pending, complete };
pub const PlanCursor = struct {
    allocator: std.mem.Allocator,
    actions: []const Action,
    action_index: usize = 0,
    byte_index: usize = 0,
    renderer: ?printer.RenderCursor = null,

    pub fn init(allocator: std.mem.Allocator, actions: []const Action) PlanCursor {
        return .{ .allocator = allocator, .actions = actions };
    }
    pub fn deinit(self: *PlanCursor) void {
        if (self.renderer) |*renderer| renderer.deinit();
        self.* = undefined;
    }
    pub fn advance(
        self: *PlanCursor,
        writer: *std.Io.Writer,
        budget: usize,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!PlanProgress {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
            if (self.renderer) |*renderer| switch (try renderer.advance(writer, 1)) {
                .pending => continue,
                .complete => {
                    renderer.deinit();
                    self.renderer = null;
                    self.action_index += 1;
                    continue;
                },
            };
            if (self.action_index == self.actions.len) return .complete;
            switch (self.actions[self.action_index]) {
                .value => |item| self.renderer = try .init(self.allocator, item),
                .bytes => |bytes| try self.writeBytes(writer, bytes),
                .name => |name| try self.writeBytes(writer, intern.get(name)),
            }
        }
        return if (self.action_index == self.actions.len and self.renderer == null)
            .complete
        else
            .pending;
    }
    fn writeBytes(self: *PlanCursor, writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
        const end = @min(self.byte_index + 256, bytes.len);
        try writer.writeAll(bytes[self.byte_index..end]);
        self.byte_index = end;
        if (end == bytes.len) {
            self.byte_index = 0;
            self.action_index += 1;
        }
    }
};

pub const OwnedPlanProgress = union(enum) { pending, complete: []u8 };
pub const OwnedPlanCursor = struct {
    allocator: std.mem.Allocator,
    actions: []const Action,
    cursor: PlanCursor,
    phase: enum { count, fill, complete } = .count,
    byte_count: usize = 0,
    output: ?[]u8 = null,
    written: usize = 0,

    pub fn init(allocator: std.mem.Allocator, actions: []const Action) OwnedPlanCursor {
        return .{ .allocator = allocator, .actions = actions, .cursor = .init(allocator, actions) };
    }
    pub fn deinit(self: *OwnedPlanCursor) void {
        self.cursor.deinit();
        if (self.output) |output| self.allocator.free(output);
        self.* = undefined;
    }
    pub fn advance(self: *OwnedPlanCursor, budget: usize) error{OutOfMemory}!OwnedPlanProgress {
        switch (self.phase) {
            .count => {
                var buffer: [256]u8 = undefined;
                var counter = std.Io.Writer.Discarding.init(&buffer);
                const progress = self.cursor.advance(&counter.writer, budget) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
                const produced = std.math.cast(usize, counter.fullCount()) orelse return error.OutOfMemory;
                self.byte_count = std.math.add(usize, self.byte_count, produced) catch return error.OutOfMemory;
                if (progress == .pending) return .pending;
                const output = try self.allocator.alloc(u8, self.byte_count);
                self.cursor.deinit();
                self.cursor = .init(self.allocator, self.actions);
                self.output = output;
                self.phase = .fill;
                return .pending;
            },
            .fill => {
                var fixed = std.Io.Writer.fixed(self.output.?[self.written..]);
                const progress = self.cursor.advance(&fixed, budget) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
                self.written += fixed.buffered().len;
                if (progress == .pending) return .pending;
                const result = self.output.?;
                self.output = null;
                self.phase = .complete;
                return .{ .complete = result };
            },
            .complete => unreachable,
        }
    }
};

const NameCompareCursor = struct {
    left: []const u8,
    right: []const u8,
    index: usize = 0,
    fn init(left: u32, right: u32) NameCompareCursor {
        return .{ .left = intern.get(left), .right = intern.get(right) };
    }
    fn advance(self: *NameCompareCursor, budget: usize) union(enum) {
        pending,
        complete: std.math.Order,
    } {
        const shared = @min(self.left.len, self.right.len);
        const end = @min(self.index + budget, shared);
        while (self.index != end) : (self.index += 1) {
            if (self.left[self.index] < self.right[self.index]) return .{ .complete = .lt };
            if (self.left[self.index] > self.right[self.index]) return .{ .complete = .gt };
        }
        if (self.index != shared) return .pending;
        return .{ .complete = std.math.order(self.left.len, self.right.len) };
    }
};

pub const NameSortProgress = enum { pending, complete };
pub const NameSortCursor = struct {
    allocator: std.mem.Allocator,
    names: []u32,
    scratch: []u32,
    width: usize = 1,
    start: usize = 0,
    middle: usize = 0,
    end: usize = 0,
    left: usize = 0,
    right: usize = 0,
    output: usize = 0,
    run_ready: bool = false,
    source_scratch: bool = false,
    comparator: ?NameCompareCursor = null,
    copy_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, names: []u32) error{OutOfMemory}!NameSortCursor {
        return .{ .allocator = allocator, .names = names, .scratch = try allocator.alloc(u32, names.len) };
    }
    pub fn deinit(self: *NameSortCursor) void {
        self.allocator.free(self.scratch);
        self.* = undefined;
    }
    pub fn advance(self: *NameSortCursor, budget: usize) NameSortProgress {
        var remaining = budget;
        while (remaining != 0) {
            if (self.width >= self.names.len) {
                if (!self.source_scratch) return .complete;
                const end = @min(self.copy_index + remaining, self.names.len);
                const copied = end - self.copy_index;
                @memcpy(self.names[self.copy_index..end], self.scratch[self.copy_index..end]);
                self.copy_index = end;
                if (self.copy_index == self.names.len) return .complete;
                remaining -= copied;
                continue;
            }
            if (!self.run_ready) {
                if (self.start == self.names.len) {
                    self.source_scratch = !self.source_scratch;
                    self.start = 0;
                    self.width = if (self.width > self.names.len / 2)
                        self.names.len
                    else
                        self.width * 2;
                    continue;
                }
                self.middle = self.start + @min(self.width, self.names.len - self.start);
                self.end = self.middle + @min(self.width, self.names.len - self.middle);
                self.left = self.start;
                self.right = self.middle;
                self.output = self.start;
                self.run_ready = true;
            }
            if (self.output == self.end) {
                self.start = self.end;
                self.run_ready = false;
                continue;
            }
            const source = if (self.source_scratch) self.scratch else self.names;
            var choose_left = self.right == self.end;
            if (!choose_left and self.left != self.middle) {
                if (self.comparator == null)
                    self.comparator = .init(source[self.left], source[self.right]);
                switch (self.comparator.?.advance(1)) {
                    .pending => {
                        remaining -= 1;
                        continue;
                    },
                    .complete => |ordering| {
                        self.comparator = null;
                        choose_left = ordering != .gt;
                    },
                }
            }
            const destination = if (self.source_scratch) self.names else self.scratch;
            destination[self.output] = if (choose_left) source[self.left] else source[self.right];
            if (choose_left) self.left += 1 else self.right += 1;
            self.output += 1;
            remaining -= 1;
        }
        return .pending;
    }
};
