//! Owned subprocess results and common CLI expectations.
const std = @import("std");

const allocator = std.testing.allocator;
const io = std.testing.io;

pub const Expectation = struct {
    exit_code: u8,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    stdout_contains: []const []const u8 = &.{},
    stderr_contains: []const []const u8 = &.{},
    stdout_excludes: []const []const u8 = &.{},
    stderr_excludes: []const []const u8 = &.{},
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Result) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    pub fn expect(self: *const Result, expected: Expectation) !void {
        switch (self.term) {
            .exited => |actual| try std.testing.expectEqual(expected.exit_code, actual),
            .signal, .stopped, .unknown => return error.UnexpectedTermination,
        }
        if (expected.stdout) |exact| try std.testing.expectEqualStrings(exact, self.stdout);
        if (expected.stderr) |exact| try std.testing.expectEqualStrings(exact, self.stderr);
        try expectFragments(self.stdout, expected.stdout_contains, true);
        try expectFragments(self.stderr, expected.stderr_contains, true);
        try expectFragments(self.stdout, expected.stdout_excludes, false);
        try expectFragments(self.stderr, expected.stderr_excludes, false);
    }
};

pub fn run(arguments: []const []const u8) !Result {
    return runOptions(.{ .argv = arguments });
}

pub fn runOptions(options: std.process.RunOptions) !Result {
    const result = try std.process.run(allocator, io, options);
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn expectFragments(haystack: []const u8, fragments: []const []const u8, present: bool) !void {
    for (fragments) |fragment| {
        const found = std.mem.indexOf(u8, haystack, fragment) != null;
        if (found != present) {
            std.log.err(
                "expected output to {s} `{s}`; actual output:\n{s}",
                .{ if (present) "contain" else "exclude", fragment, haystack },
            );
            return error.TestExpectedEqual;
        }
    }
}
