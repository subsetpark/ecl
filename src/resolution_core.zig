//! Pure name-resolution precedence decisions.
//!
//! The shell materializes binding and generation leases. This core classifies
//! the first candidate as the winner, every later candidate as a shadow, and
//! defines the single reverse-use traversal used by all resolution surfaces.

const intern = @import("intern.zig");

pub const Origin = enum { direct, used, module, core };

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

pub fn usedIndex(count: usize, ordinal: usize) ?usize {
    if (ordinal >= count) return null;
    return count - ordinal - 1;
}
