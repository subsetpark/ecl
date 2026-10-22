//! One bounded lexical candidate walk for slot misses and shadow inspection:
//! a root's own environment, then core. Callers keep the root alive. Each hit
//! transfers its binding lease to the caller; the cursor retains no hit.
//! Qualified module loading and execution authority remain with the caller.
const env = @import("env.zig");
const poll = @import("poll.zig");

pub const Origin = enum { direct, module, standard_library, core };
pub const Location = union(enum) { scope: *env.Scope, core };
pub const Candidate = struct {
    location: Location,
    lease: env.BindingLease,

    pub fn deinit(self: *Candidate) void {
        self.lease.deinit();
        self.* = undefined;
    }
};

pub const LexicalCursor = struct {
    core: env.EnvironmentView,
    word: u32,
    /// The binding version the reader observes in a session root.
    pin: ?u64,
    state: union(enum) {
        root: ?*env.Scope,
        lookup: struct { location: Location, cursor: env.DirectLookupCursor },
        complete,
    },

    /// `root` is the root a word was written in, or null for core alone.
    pub fn init(core: env.EnvironmentView, root: ?*env.Scope, word: u32, pin: ?u64) LexicalCursor {
        return .{ .core = core, .word = word, .pin = pin, .state = .{ .root = root } };
    }

    pub fn deinit(self: *LexicalCursor) void {
        switch (self.state) {
            .lookup => |*lookup| lookup.cursor.deinit(),
            .root, .complete => {},
        }
        self.* = undefined;
    }

    pub fn advance(self: *LexicalCursor) poll.StreamProgress(Candidate) {
        return switch (self.state) {
            .root => |maybe_root| step: {
                if (maybe_root) |root| {
                    if (root.environmentOrNull()) |environment| {
                        self.state = .{ .lookup = .{
                            .location = .{ .scope = root },
                            .cursor = environment.directLookupCursor(self.word).at(if (root.isSession()) self.pin else null),
                        } };
                        break :step .pending;
                    }
                }
                self.state = .{ .lookup = .{
                    .location = .core,
                    .cursor = self.core.directLookupCursor(self.word),
                } };
                break :step .pending;
            },
            .lookup => |*lookup| switch (lookup.cursor.advance()) {
                .pending => .pending,
                .complete => |maybe_lease| step: {
                    const location = lookup.location;
                    lookup.cursor.deinit();
                    self.state = switch (location) {
                        .scope => .{ .root = null },
                        .core => .complete,
                    };
                    var lease = maybe_lease orelse break :step .pending;
                    // A private core binding is reachable only through core's
                    // own qualified spelling, never by a plain word.
                    if (location == .core and lease.spec().visibility == .private) {
                        lease.deinit();
                        break :step .pending;
                    }
                    break :step .{ .item = .{ .location = location, .lease = lease } };
                },
            },
            .complete => .complete,
        };
    }
};
