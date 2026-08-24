//! Pure name-resolution precedence decisions.
//!
//! The shell materializes binding and generation leases. This core classifies
//! the first candidate as the winner and every later candidate as a shadow,
//! which is the one precedence decision every resolution surface shares.

const intern = @import("intern.zig");

pub const Origin = enum { direct, module, captured, core };

pub const Candidate = struct {
    trace_word: intern.TraceWord,
    origin: Origin,
};

pub const Search = union(enum) {
    searching,
    resolved: Candidate,
};

pub const Command = union(enum) {
    winner: Candidate,
    shadow: Candidate,
};

pub const Decision = struct {
    next: Search,
    command: Command,
};

pub fn consider(before: Search, candidate: Candidate) Decision {
    return switch (before) {
        .searching => .{
            .next = .{ .resolved = candidate },
            .command = .{ .winner = candidate },
        },
        .resolved => .{
            .next = before,
            .command = .{ .shadow = candidate },
        },
    };
}
