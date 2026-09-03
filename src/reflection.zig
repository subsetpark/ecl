//! Poll-aware ordering and output for interned reflection names.
const std = @import("std");
const heap = @import("heap.zig");
const env = @import("env.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");
const printer = @import("print.zig");
const value = @import("value.zig");

pub const Action = union(enum) {
    bytes: []const u8,
    name: u32,
    /// A word whose spelling may be qualified by the registration it was
    /// reached through. Rendering writes the two atoms with a separator rather
    /// than interning a third, because this sink is already a byte stream.
    trace_word: intern.TraceWord,
    value: value.Value,
    /// A documentation string written as prose: quoted, with only the quote
    /// and backslash escaped, so its line breaks reach the reader intact.
    /// Canonical rendering would spell them `\n`.
    document: value.Value,
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
    const Phase = union(enum) {
        scopes: struct { current: ?*env.Scope },
        direct: DirectState,
        core: env.NameCursor,
        complete,
    };

    retained_scope: ?*env.Scope,
    core: env.EnvironmentView,
    phase: Phase,

    pub fn init(
        root: VisibleNameRoot,
        core: env.EnvironmentView,
    ) VisibleNameCursor {
        return switch (root) {
            .scope => |scope| result: {
                scope.retain();
                break :result .{
                    .retained_scope = scope,
                    .core = core,
                    .phase = .{ .scopes = .{ .current = scope } },
                };
            },
            .environment => |environment| .{
                .retained_scope = null,
                .core = core,
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
        const after = state.after;
        state.cursor.deinit();
        self.continueAfter(after);
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
/// Characters of documentation written per plan step.
const document_slice: usize = 256;
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
                .document => |item| try self.writeDocument(writer, item),
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
    /// Write a documentation string in bounded slices, `byte_index` counting
    /// characters. The opening quote goes out with the first slice and the
    /// closing quote with the last.
    fn writeDocument(self: *PlanCursor, writer: *std.Io.Writer, item: value.Value) std.Io.Writer.Error!void {
        const count: usize = @intCast(item.list.length());
        if (self.byte_index == 0) try writer.writeByte('"');
        var written: usize = 0;
        while (self.byte_index < count and written < document_slice) : (written += 1) {
            const codepoint = list.atUnchecked(item, self.byte_index).char;
            switch (codepoint) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                else => {
                    var encoded: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch {
                        try writer.print("\\u{{{x}}}", .{codepoint});
                        self.byte_index += 1;
                        continue;
                    };
                    try writer.writeAll(encoded[0..length]);
                },
            }
            self.byte_index += 1;
        }
        if (self.byte_index == count) {
            try writer.writeByte('"');
            self.byte_index = 0;
            self.action_index += 1;
        }
    }
    fn writeBytes(self: *PlanCursor, writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
        if (try self.writeSegment(writer, bytes)) self.action_index += 1;
    }
    /// A qualified spelling retains three distinct segments: the
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
    state: State = .building,

    const State = union(enum) {
        building,
        sealed,
        materializing: struct {
            actions: []Action,
            iterator: poll.ChunkList(Action).Iterator,
            index: usize,
        },
        rendering: struct {
            actions: []Action,
            renderer: OwnedPlanCursor,
        },

        fn deinit(self: *State, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .building, .sealed => {},
                .materializing => |materializing| allocator.free(materializing.actions),
                .rendering => |*rendering| {
                    rendering.renderer.deinit();
                    allocator.free(rendering.actions);
                },
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) ActionPlan {
        return .{ .allocator = allocator, .pending = .init(allocator) };
    }

    pub fn add(self: *ActionPlan, action: Action) error{OutOfMemory}!void {
        std.debug.assert(self.state == .building);
        try self.pending.append(action);
    }

    pub fn count(self: *const ActionPlan) usize {
        return self.pending.count;
    }

    pub fn isSealed(self: *const ActionPlan) bool {
        return self.state != .building;
    }

    pub fn seal(self: *ActionPlan) void {
        std.debug.assert(self.state == .building);
        self.state = .sealed;
    }

    pub fn advance(self: *ActionPlan, budget: usize) error{OutOfMemory}!OwnedPlanProgress {
        std.debug.assert(self.state != .building and budget != 0);
        var remaining = budget;
        if (self.state == .sealed) {
            const actions = try self.allocator.alloc(Action, self.pending.count);
            self.state = .{ .materializing = .{
                .actions = actions,
                .iterator = self.pending.iterator(),
                .index = 0,
            } };
        }
        while (remaining != 0 and self.state == .materializing) : (remaining -= 1) {
            const materializing = &self.state.materializing;
            if (materializing.iterator.next()) |action| {
                materializing.actions[materializing.index] = action.*;
                materializing.index += 1;
            } else {
                const actions = materializing.actions;
                self.state = .{ .rendering = .{
                    .actions = actions,
                    .renderer = .init(self.allocator, actions),
                } };
            }
        }
        return switch (self.state) {
            .materializing => .pending,
            .rendering => |*rendering| rendering.renderer.advance(@max(remaining, 1)),
            .building, .sealed => unreachable,
        };
    }

    pub fn deinit(self: *ActionPlan) void {
        self.state.deinit(self.allocator);
        self.pending.deinit();
        self.* = undefined;
    }

    pub fn retire(self: *ActionPlan, releases: *heap.ReleaseDomain) void {
        self.state.deinit(self.allocator);
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
const NameSortProgress = poll.Progress(void);
const NameSortCursor = struct {
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

/// Owned sorted/unique names. `storage` retains the original exact allocation
/// while `items` exposes only the compacted prefix.
pub const SortedUniqueNames = struct {
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    storage: []u32,
    unique_len: usize,

    pub fn items(self: *const SortedUniqueNames) []const u32 {
        return self.storage[0..self.unique_len];
    }
    pub fn deinit(self: *SortedUniqueNames, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const SortedUniqueNameProgress = poll.Progress(SortedUniqueNames);

/// Common post-collection traversal for reflection names: exact
/// materialization, lexical sort, and in-place deduplication.
pub const SortedUniqueNameCursor = struct {
    allocator: std.mem.Allocator,
    iterator: poll.ChunkList(u32).Iterator,
    storage: ?[]u32,
    phase: enum { materialize, sort, unique, complete } = .materialize,
    index: usize = 0,
    unique_len: usize = 0,
    previous: ?u32 = null,
    sorter: ?NameSortCursor = null,

    pub fn init(
        allocator: std.mem.Allocator,
        found: *const poll.ChunkList(u32),
    ) error{OutOfMemory}!SortedUniqueNameCursor {
        return .{
            .allocator = allocator,
            .iterator = found.iterator(),
            .storage = try allocator.alloc(u32, found.count),
        };
    }
    pub fn deinit(self: *SortedUniqueNameCursor) void {
        if (self.sorter) |*sorter| sorter.deinit();
        if (self.storage) |storage| self.allocator.free(storage);
        self.* = undefined;
    }
    pub fn advance(
        self: *SortedUniqueNameCursor,
        budget: usize,
    ) error{OutOfMemory}!SortedUniqueNameProgress {
        std.debug.assert(budget != 0 and self.phase != .complete);
        var remaining = budget;
        while (remaining != 0) switch (self.phase) {
            .materialize => if (self.iterator.next()) |name| {
                self.storage.?[self.index] = name.*;
                self.index += 1;
                remaining -= 1;
            } else {
                self.sorter = try .init(self.allocator, self.storage.?);
                self.phase = .sort;
                return .pending;
            },
            .sort => switch (self.sorter.?.advance(remaining)) {
                .pending => return .pending,
                .complete => {
                    self.sorter.?.deinit();
                    self.sorter = null;
                    self.phase = .unique;
                    self.index = 0;
                    return .pending;
                },
            },
            .unique => {
                if (self.index == self.storage.?.len) {
                    const storage = self.storage.?;
                    const unique_len = self.unique_len;
                    self.storage = null;
                    self.phase = .complete;
                    return .{ .complete = .{
                        .storage = storage,
                        .unique_len = unique_len,
                    } };
                }
                const name = self.storage.?[self.index];
                self.index += 1;
                remaining -= 1;
                if (self.previous != null and self.previous.? == name) continue;
                self.storage.?[self.unique_len] = name;
                self.unique_len += 1;
                self.previous = name;
            },
            .complete => unreachable,
        };
        return .pending;
    }
};

test "sorted unique names share one resumable post-collection pipeline" {
    const allocator = std.testing.allocator;
    var found = poll.ChunkList(u32).init(allocator);
    defer found.deinit();
    const alpha = try intern.intern("sorted-alpha");
    const beta = try intern.intern("sorted-beta");
    try found.append(beta);
    try found.append(alpha);
    try found.append(beta);

    var cursor = try SortedUniqueNameCursor.init(allocator, &found);
    defer cursor.deinit();
    var pending: usize = 0;
    var names = while (true) switch (try cursor.advance(1)) {
        .pending => pending += 1,
        .complete => |result| break result,
    };
    defer names.deinit(allocator);

    try std.testing.expect(pending > found.count);
    try std.testing.expectEqualSlices(u32, &.{ alpha, beta }, names.items());
}
