//! Shared behavioral test helpers for M5 kernel families.
const std = @import("std");
const value = @import("../value.zig");
const session = @import("../session.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const printer = @import("../print.zig");

const allocator = std.testing.allocator;

pub const StackCase = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8,
};

pub const ExpectedValue = union(enum) {
    int: i64,
    symbol: []const u8,
    string: []const u8,
};

pub const DataField = struct {
    name: []const u8,
    expected: ExpectedValue,
};

pub const ErrorCase = struct {
    name: []const u8,
    source: []const u8,
    kind: []const u8,
    word: ?[]const u8 = null,
    data: []const DataField = &.{},
    message: ?[]const u8 = null,
    message_contains: ?[]const u8 = null,
};

pub fn expectStack(source: []const u8, expected: []const u8) !void {
    return expectStackCase(.{ .name = source, .source = source, .expected = expected });
}

pub fn expectStacks(cases: []const StackCase) !void {
    for (cases) |case| expectStackCase(case) catch |err| {
        std.log.err("stack case `{s}` failed; source: {s}", .{ case.name, case.source });
        return err;
    };
}

pub fn expectError(case: ErrorCase) !void {
    return expectErrorCase(case);
}

pub fn expectErrors(cases: []const ErrorCase) !void {
    for (cases) |case| expectErrorCase(case) catch |err| {
        std.log.err("language-error case `{s}` failed; source: {s}", .{ case.name, case.source });
        return err;
    };
}

pub fn expectLanguageError(failure: value.Value, expected: ErrorCase) !void {
    if (failure != .dict) {
        const rendered = try printer.toOwnedString(allocator, failure);
        defer allocator.free(rendered);
        std.log.err("expected a language-error dict, got: {s}", .{rendered});
        return error.TestUnexpectedResult;
    }

    try expectSymbolField(failure, "kind", expected.kind);
    if (expected.word) |word| try expectSymbolField(failure, "word", word);

    const data = try requiredField(failure, "data");
    if (data != .dict) {
        std.log.err("language-error field `data` is not a dict", .{});
        return error.TestUnexpectedResult;
    }
    for (expected.data) |field| {
        const actual = try requiredField(data, field.name);
        try expectValue(actual, field.expected);
    }

    if (expected.message != null or expected.message_contains != null) {
        const message = try requiredField(failure, "msg");
        const bytes = try stringBytes(message);
        defer allocator.free(bytes);
        if (expected.message) |exact| try std.testing.expectEqualStrings(exact, bytes);
        if (expected.message_contains) |fragment| {
            try std.testing.expect(std.mem.indexOf(u8, bytes, fragment) != null);
        }
    }
}

fn expectStackCase(case: StackCase) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    switch (try runtime.runUnit("<kernel-test>", case.source)) {
        .ok => {},
        .incomplete => return error.TestUnexpectedResult,
        .err => |failure| {
            defer heap.testing.releaseValue(allocator, failure);
            const rendered = try printer.toOwnedString(allocator, failure);
            defer allocator.free(rendered);
            std.log.err("unexpected language error: {s}", .{rendered});
            return error.TestUnexpectedResult;
        },
    }
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(case.expected, display.bytes());
}

fn expectErrorCase(case: ErrorCase) !void {
    var runtime = try session.Session.init(allocator, &.{});
    defer runtime.deinit();
    const failure = switch (try runtime.runUnit("<kernel-test>", case.source)) {
        .ok, .incomplete => return error.TestUnexpectedResult,
        .err => |item| item,
    };
    defer heap.testing.releaseValue(allocator, failure);
    try expectLanguageError(failure, case);
}

fn requiredField(dictionary: value.Value, name: []const u8) !value.Value {
    const key = try intern.intern(name);
    return (try dict.symbolField(allocator, dictionary, key)) orelse {
        std.log.err("language-error dict is missing field `{s}`", .{name});
        return error.TestUnexpectedResult;
    };
}

fn expectSymbolField(dictionary: value.Value, name: []const u8, expected: []const u8) !void {
    const actual = try requiredField(dictionary, name);
    if (actual != .symbol) {
        std.log.err("language-error field `{s}` is not a symbol", .{name});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(expected, intern.get(actual.symbol));
}

fn expectValue(actual: value.Value, expected: ExpectedValue) !void {
    switch (expected) {
        .int => |integer| {
            if (actual != .int) return error.TestUnexpectedResult;
            try std.testing.expectEqual(integer, actual.int);
        },
        .symbol => |symbol| {
            if (actual != .symbol) return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(symbol, intern.get(actual.symbol));
        },
        .string => |string| {
            const bytes = try stringBytes(actual);
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings(string, bytes);
        },
    }
}

fn stringBytes(item: value.Value) ![]u8 {
    if (!item.isString()) return error.TestUnexpectedResult;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const length: usize = @intCast(item.list.length());
    for (0..length) |index| {
        const codepoint = list.atUnchecked(item, index).char;
        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch
            return error.TestUnexpectedResult;
        try result.appendSlice(allocator, encoded[0..encoded_len]);
    }
    return result.toOwnedSlice(allocator);
}
