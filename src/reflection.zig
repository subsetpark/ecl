//! Poll-aware ordering and output for interned reflection names.
const std = @import("std");
const heap = @import("heap.zig");
const env = @import("env.zig");
const intern = @import("intern.zig");
const modules = @import("modules.zig");
const poll = @import("poll.zig");
const printer = @import("print.zig");
const resolution_core = @import("resolution_core.zig");
const value = @import("value.zig");

pub const Action = union(enum) {
    bytes: []const u8,
    name: u32,
    /// A word whose spelling may be qualified by the registration it was
    /// reached through. Rendering writes the two atoms with a separator rather
    /// than interning a third, because this sink is already a byte stream.
    trace_word: intern.TraceWord,
    value: value.Value,
};

pub const VisibleNameRoot = union(enum) {
    scope: *env.Scope,
    environment: env.EnvironmentView,
};

pub const VisibleNameProgress = poll.StreamProgress(u32);
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
        cursor: modules.ModulePublicNameCursor,
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
        return if (lease.visibility == .public) .{ .item = entry.name } else .pending;
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
                .item => |entry| publicEntry(entry),
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
                .item => |name| .{ .item = name },
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
                .item => |entry| publicEntry(entry),
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

pub const PlanProgress = poll.Progress(void);
pub const PlanCursor = struct {
    allocator: std.mem.Allocator,
    actions: []const Action,
    action_index: usize = 0,
    byte_index: usize = 0,
    /// Which segment of a qualified spelling is being written: prefix, the
    /// separator, then the local name.
    word_part: enum { prefix, separator, local } = .prefix,
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
                .trace_word => |word| try self.writeTraceWord(writer, word),
            }
        }
        return if (self.action_index == self.actions.len and self.renderer == null)
            .complete
        else
            .pending;
    }
    fn writeSegment(
        self: *PlanCursor,
        writer: *std.Io.Writer,
        bytes: []const u8,
    ) std.Io.Writer.Error!bool {
        const end = @min(self.byte_index + 256, bytes.len);
        try writer.writeAll(bytes[self.byte_index..end]);
        self.byte_index = end;
        if (end != bytes.len) return false;
        self.byte_index = 0;
        return true;
    }
    fn writeBytes(self: *PlanCursor, writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
        if (try self.writeSegment(writer, bytes)) self.action_index += 1;
    }
    /// A qualified spelling is three segments, not one interned string: the
    /// registration's name, the separator, and the definition's own name.
    fn writeTraceWord(
        self: *PlanCursor,
        writer: *std.Io.Writer,
        word: intern.TraceWord,
    ) std.Io.Writer.Error!void {
        const local = intern.get(word.atom());
        const prefix = word.modulePrefix() orelse {
            if (try self.writeSegment(writer, local)) self.action_index += 1;
            return;
        };
        switch (self.word_part) {
            .prefix => if (try self.writeSegment(writer, prefix)) {
                self.word_part = .separator;
            },
            .separator => if (try self.writeSegment(writer, ".")) {
                self.word_part = .local;
            },
            .local => if (try self.writeSegment(writer, local)) {
                self.word_part = .prefix;
                self.action_index += 1;
            },
        }
    }
};

pub const OwnedPlanProgress = poll.Progress([]u8);
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

/// Non-relocating action accumulation followed by one exact materialization
/// and the shared resumable renderer. Callers never count actions or couple a
/// fixed buffer to another component's capacity.
pub const ActionPlan = struct {
    pub const owned_disposal: heap.OwnedDisposal = .retire;

    allocator: std.mem.Allocator,
    pending: poll.ChunkList(Action),
    actions: ?[]Action = null,
    iterator: ?poll.ChunkList(Action).Iterator = null,
    materialize_index: usize = 0,
    renderer: ?OwnedPlanCursor = null,
    sealed: bool = false,

    pub fn init(allocator: std.mem.Allocator) ActionPlan {
        return .{ .allocator = allocator, .pending = .init(allocator) };
    }

    pub fn add(self: *ActionPlan, action: Action) error{OutOfMemory}!void {
        std.debug.assert(!self.sealed);
        try self.pending.append(action);
    }

    pub fn count(self: *const ActionPlan) usize {
        return self.pending.count;
    }

    pub fn isSealed(self: *const ActionPlan) bool {
        return self.sealed;
    }

    pub fn seal(self: *ActionPlan) void {
        std.debug.assert(!self.sealed);
        self.sealed = true;
    }

    pub fn advance(self: *ActionPlan, budget: usize) error{OutOfMemory}!OwnedPlanProgress {
        std.debug.assert(self.sealed and budget != 0);
        var remaining = budget;
        if (self.actions == null) {
            self.actions = try self.allocator.alloc(Action, self.pending.count);
            self.iterator = self.pending.iterator();
        }
        while (remaining != 0 and self.iterator != null) : (remaining -= 1) {
            if (self.iterator.?.next()) |action| {
                self.actions.?[self.materialize_index] = action.*;
                self.materialize_index += 1;
            } else {
                self.iterator = null;
                self.renderer = .init(self.allocator, self.actions.?);
            }
        }
        if (self.iterator != null or self.renderer == null) return .pending;
        return self.renderer.?.advance(@max(remaining, 1));
    }

    pub fn deinit(self: *ActionPlan) void {
        if (self.renderer) |*renderer| renderer.deinit();
        if (self.actions) |actions| self.allocator.free(actions);
        self.pending.deinit();
        self.* = undefined;
    }

    pub fn retire(self: *ActionPlan, releases: *heap.ReleaseDomain) void {
        if (self.renderer) |*renderer| renderer.deinit();
        if (self.actions) |actions| self.allocator.free(actions);
        self.pending.retire(releases);
    }
};

const NameCompareCursor = struct {
    left: []const u8,
    right: []const u8,
    index: usize = 0,
    fn init(left: u32, right: u32) NameCompareCursor {
        return .{ .left = intern.get(left), .right = intern.get(right) };
    }
    fn advance(self: *NameCompareCursor, budget: usize) poll.Progress(std.math.Order) {
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

const NameComparator = struct {
    pub const Context = void;
    pub const Cursor = NameCompareCursor;

    pub fn init(_: Context, left: u32, right: u32) Cursor {
        return .init(left, right);
    }

    pub fn advance(cursor: *Cursor, budget: usize) poll.Progress(std.math.Order) {
        return cursor.advance(budget);
    }
};

const InternNameMergeSort = poll.MergeSortCursor(u32, NameComparator);
pub const NameSortProgress = poll.Progress(void);
pub const NameSortCursor = struct {
    sort: InternNameMergeSort,

    pub fn init(allocator: std.mem.Allocator, names: []u32) error{OutOfMemory}!NameSortCursor {
        return .{ .sort = try .init(allocator, names, {}) };
    }
    pub fn deinit(self: *NameSortCursor) void {
        self.sort.deinit();
        self.* = undefined;
    }
    pub fn advance(self: *NameSortCursor, budget: usize) NameSortProgress {
        return self.sort.advance(budget);
    }
};
