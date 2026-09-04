//! One bounded lexical candidate walk for execution and shadow inspection.
//! Callers keep the scope chain alive. Each hit transfers its binding lease
//! and optional captured cell to the caller; the cursor retains no hit.
//! Qualified module loading and execution authority remain with the caller.
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

pub const LexicalCursor = struct {
    core: env.EnvironmentView,
    word: u32,
    capture_cells: bool,
    state: union(enum) {
        search: ?*env.Scope,
        lookup: struct { location: Location, cursor: env.DirectLookupCursor },
        complete,
    },

    pub fn init(core: env.EnvironmentView, scope: ?*env.Scope, word: u32, capture_cells: bool) LexicalCursor {
        return .{ .core = core, .word = word, .capture_cells = capture_cells, .state = .{ .search = scope } };
    }

    pub fn deinit(self: *LexicalCursor) void {
        switch (self.state) {
            .lookup => |*lookup| lookup.cursor.deinit(),
            .search, .complete => {},
        }
        self.* = undefined;
    }

    pub fn advance(self: *LexicalCursor) poll.StreamProgress(Candidate) {
        return switch (self.state) {
            .search => |scope| step: {
                if (scope) |current| {
                    if (current.environmentOrNull()) |environment| {
                        var cursor = environment.directLookupCursor(self.word);
                        if (self.capture_cells) cursor.captureCell();
                        self.state = .{ .lookup = .{ .location = .{ .scope = current }, .cursor = cursor } };
                    } else self.state = .{ .search = current.parent };
                } else {
                    self.state = .{ .lookup = .{ .location = .core, .cursor = self.core.directLookupCursor(self.word) } };
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
                        break :step .pending;
                    }
                    break :step .{ .item = .{ .location = location, .lease = lease, .cell = cell } };
                },
            },
            .complete => .complete,
        };
    }
};
