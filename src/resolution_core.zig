//! One bounded lexical candidate walk for execution and shadow inspection.
//! Callers keep the scope chain alive. Each hit transfers its binding lease
//! and optional captured cell to the caller; the cursor retains no hit.
//! Qualified module loading and execution authority remain with the caller.
const std = @import("std");
const env = @import("env.zig");
const poll = @import("poll.zig");

pub const Origin = enum { direct, module, standard_library, core };
pub const Location = union(enum) { scope: *env.Scope, core };
pub const Candidate = struct {
    location: Location,
    lease: env.BindingLease,
    cell: ?env.BindingCellHandle,

    pub fn deinit(self: *Candidate) void {
        self.lease.deinit();
        if (self.cell) |*cell| cell.deinit();
        self.* = undefined;
    }
};

/// The starting scope identity selects an immutable parent chain. Its live
/// scopes keep their once-installed environments alive. Revisions therefore
/// need neither raw scope pointers nor snapshot reader ownership.
const LexicalGuard = struct {
    const absent_environment = std.math.maxInt(u64); // Published revisions are even.
    revisions: [8]u64 = undefined,
    count: u8 = 0,
    core: ?env.ShapeRevision = null,

    pub fn valid(self: *const LexicalGuard, start: ?*env.Scope, core: env.EnvironmentView) bool {
        var current = start;
        for (self.revisions[0..self.count]) |revision| {
            const scope = current orelse return false;
            const environment = scope.environmentOrNull();
            if (revision == absent_environment) {
                if (environment != null) return false;
            } else if (!(environment orelse return false).matchesShape(@enumFromInt(revision))) return false;
            current = scope.parent;
        }
        if (self.core) |revision| return current == null and core.matchesShape(revision);
        return true;
    }

    pub fn selectedScope(self: *const LexicalGuard, start: ?*env.Scope) ?*env.Scope {
        var current = start;
        for (1..self.count) |_| current = current.?.parent;
        return current;
    }
};

/// Fixed observation storage belongs to the Unit, outside resumable result
/// unions. Reusing a slot invalidates its old token, including an unfinished
/// lookup; it never keeps a snapshot reader or scope alive.
pub const GuardId = enum(u64) { none = 0, _ };
const ConstructionId = enum(u64) { none = 0, _ };
pub const GuardContext = struct { pool: ?*GuardPool, scope_id: env.ScopeId };
pub const GuardResolution = union(enum) { absent, stale, hit: Location };

pub const GuardPool = struct {
    pub const capacity = 16;
    const Slot = struct {
        serial: u64 = 0,
        scope_id: env.ScopeId = @enumFromInt(0),
        phase: enum { building, validated } = .building,
        value: LexicalGuard = .{},
    };
    slots: [capacity]Slot = .{Slot{}} ** capacity,
    serial: u64 = 0,

    fn reserve(self: *GuardPool, scope_id: env.ScopeId) ConstructionId {
        if (self.serial == std.math.maxInt(u64)) return .none;
        self.serial += 1;
        self.slots[(self.serial - 1) % capacity] = .{ .serial = self.serial, .scope_id = scope_id };
        return @enumFromInt(self.serial);
    }
    fn slot(self: *GuardPool, serial: u64) ?*Slot {
        if (serial == 0) return null;
        const selected = &self.slots[(serial - 1) % capacity];
        return if (selected.serial == serial) selected else null;
    }
    fn building(self: *GuardPool, id: ConstructionId) ?*LexicalGuard {
        const selected = self.slot(@intFromEnum(id)) orelse return null;
        return if (selected.phase == .building) &selected.value else null;
    }
    fn finish(self: *GuardPool, id: ConstructionId, start: ?*env.Scope, core: env.EnvironmentView) GuardId {
        const selected = self.slot(@intFromEnum(id)) orelse return .none;
        if (selected.phase != .building or !selected.value.valid(start, core)) return .none;
        selected.phase = .validated;
        return @enumFromInt(@intFromEnum(id));
    }
    /// IDs are Unit-local observations; only this Unit's cache consumes them.
    /// The current activation supplies both context identity and chain liveness.
    pub fn resolve(self: *GuardPool, id: GuardId, scope_id: env.ScopeId, start: ?*env.Scope, core: env.EnvironmentView) GuardResolution {
        const selected = self.slot(@intFromEnum(id)) orelse return .absent;
        if (selected.scope_id != scope_id) return .absent;
        if (selected.phase != .validated or !selected.value.valid(start, core)) return .stale;
        return .{ .hit = if (selected.value.core != null) .core else .{ .scope = selected.value.selectedScope(start).? } };
    }
};

pub const LexicalCursor = struct {
    core: env.EnvironmentView,
    word: u32,
    guard: ConstructionId = .none,
    guards: ?*GuardPool = null,
    capture_scope: ?env.ScopeId = null,
    start: ?*env.Scope,
    state: union(enum) {
        search: ?*env.Scope,
        lookup: struct { location: Location, cursor: env.DirectLookupCursor },
        complete,
    },

    pub fn init(core: env.EnvironmentView, scope: ?*env.Scope, word: u32, guards: ?GuardContext) LexicalCursor {
        return .{ .core = core, .word = word, .state = .{ .search = scope }, .start = scope, .guard = if (guards) |context| if (context.pool) |pool| pool.reserve(context.scope_id) else .none else .none, .guards = if (guards) |context| context.pool else null, .capture_scope = if (guards) |context| context.scope_id else null };
    }

    pub fn deinit(self: *LexicalCursor) void {
        switch (self.state) {
            .lookup => |*lookup| lookup.cursor.deinit(),
            .search, .complete => {},
        }
        self.* = undefined;
    }

    /// Finish observations only after the caller accepts a candidate, before
    /// releasing this cursor. Guard metadata never widens the hot result union.
    pub fn finishGuard(self: *LexicalCursor) GuardId {
        const result = if (self.guards) |pool| pool.finish(self.guard, self.start, self.core) else .none;
        self.guard = .none;
        return result;
    }

    pub fn advance(self: *LexicalCursor) poll.StreamProgress(Candidate) {
        return switch (self.state) {
            .search => |scope| step: {
                if (scope) |current| {
                    const observed_environment = current.environmentOrNull();
                    if (self.guards) |pool| if (pool.building(self.guard)) |guard| {
                        if (guard.count == guard.revisions.len) {
                            self.guard = .none;
                        } else {
                            const shape = if (observed_environment) |environment| environment.observeShape() else null;
                            if (observed_environment != null and shape == null) {
                                self.guard = .none;
                            } else {
                                guard.revisions[guard.count] = if (shape) |revision| @intFromEnum(revision) else LexicalGuard.absent_environment;
                                guard.count += 1;
                            }
                        }
                    } else {
                        self.guard = .none;
                    };
                    if (observed_environment) |environment| {
                        var cursor = environment.directLookupCursor(self.word);
                        if (self.guards != null or (current.isModuleRoot() and self.capture_scope != null and current.cellId() == self.capture_scope.?)) cursor.captureCell();
                        self.state = .{ .lookup = .{ .location = .{ .scope = current }, .cursor = cursor } };
                    } else self.state = .{ .search = current.parent };
                } else {
                    if (self.guards) |pool| if (pool.building(self.guard)) |guard| {
                        guard.core = self.core.observeShape();
                        if (guard.core == null) self.guard = .none;
                    } else {
                        self.guard = .none;
                    };
                    var cursor = self.core.directLookupCursor(self.word);
                    if (self.guards != null) cursor.captureCell();
                    self.state = .{ .lookup = .{ .location = .core, .cursor = cursor } };
                }
                break :step .pending;
            },
            .lookup => |*lookup| switch (lookup.cursor.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| step: {
                    const location = lookup.location;
                    const cell = if (maybe_lease != null) lookup.cursor.takeCell() else null;
                    lookup.cursor.deinit();
                    self.state = switch (location) {
                        .scope => |scope| .{ .search = scope.parent },
                        .core => .complete,
                    };
                    var lease = maybe_lease orelse break :step .pending;
                    if (location == .core and lease.visibility == .private) {
                        lease.deinit();
                        if (cell) |owned| {
                            var rejected = owned;
                            rejected.deinit();
                        }
                        break :step .pending;
                    }
                    break :step .{ .item = .{ .location = location, .lease = lease, .cell = cell } };
                },
            },
            .complete => .complete,
        };
    }
};
