//! Immutable startup environment shared by evaluation and child processes.
const std = @import("std");

pub const EnvironmentEntry = struct { name: []const u8, value: []const u8 };

pub const View = struct {
    pub const Entry = EnvironmentEntry;

    entries: []const Entry = &.{},

    /// Resumable lookup: the environment block is host-sized rather than
    /// constant, so the scan yields on the ordinary polled budget.
    pub const LookupCursor = struct {
        entries: []const Entry,
        name: []const u8,
        index: usize = 0,

        pub fn advance(self: *LookupCursor, budget: usize) union(enum) { pending, complete: ?[]const u8 } {
            std.debug.assert(budget != 0);
            var remaining = budget;
            while (remaining != 0 and self.index != self.entries.len) : (remaining -= 1) {
                const entry = self.entries[self.index];
                self.index += 1;
                if (std.mem.eql(u8, entry.name, self.name)) return .{ .complete = entry.value };
            }
            if (self.index == self.entries.len) return .{ .complete = null };
            return .pending;
        }
    };

    pub fn lookupCursor(self: *const View, name: []const u8) LookupCursor {
        return .{ .entries = self.entries, .name = name };
    }
};

/// One owned copy of the host environment. Names and values live in a single
/// byte block so teardown is two frees regardless of how large the
/// environment was.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    entries: []EnvironmentEntry,
    bytes: ?[]u8,

    pub fn capture(
        allocator: std.mem.Allocator,
        source: []const EnvironmentEntry,
    ) error{ OutOfMemory, InvalidConfig }!Snapshot {
        if (source.len == 0) return .{ .allocator = allocator, .entries = &.{}, .bytes = null };
        var total: usize = 0;
        for (source) |entry| {
            if (!std.process.Environ.Map.validateKeyForPut(entry.name) or
                std.mem.indexOfScalar(u8, entry.value, 0) != null) return error.InvalidConfig;
            total = std.math.add(usize, total, entry.name.len) catch return error.OutOfMemory;
            total = std.math.add(usize, total, entry.value.len) catch return error.OutOfMemory;
        }
        const bytes = try allocator.alloc(u8, total);
        errdefer allocator.free(bytes);
        const entries = try allocator.alloc(EnvironmentEntry, source.len);
        var offset: usize = 0;
        for (source, entries) |entry, *copy| {
            const name_end = offset + entry.name.len;
            @memcpy(bytes[offset..name_end], entry.name);
            const value_end = name_end + entry.value.len;
            @memcpy(bytes[name_end..value_end], entry.value);
            copy.* = .{
                .name = bytes[offset..name_end],
                .value = bytes[name_end..value_end],
            };
            offset = value_end;
        }
        return .{ .allocator = allocator, .entries = entries, .bytes = bytes };
    }
    pub fn view(self: *const Snapshot) View {
        return .{ .entries = self.entries };
    }

    pub fn deinit(self: *Snapshot) void {
        const allocator = self.allocator;
        if (self.bytes) |bytes| allocator.free(bytes);
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = undefined;
    }
};

fn expectLookup(view: View, name: []const u8, expected: ?[]const u8) !void {
    var cursor = view.lookupCursor(name);
    while (true) switch (cursor.advance(1)) {
        .pending => {},
        .complete => |actual| {
            if (expected) |text| {
                try std.testing.expectEqualStrings(text, actual orelse return error.MissingEntry);
            } else try std.testing.expect(actual == null);
            return;
        },
    };
}

fn captureProbe(allocator: std.mem.Allocator) !void {
    var name = "NAME".*;
    var value = "first".*;
    var snapshot = try Snapshot.capture(allocator, &.{
        .{ .name = &name, .value = &value },
        .{ .name = "NAME", .value = "second" },
        .{ .name = "EMPTY", .value = "" },
    });
    defer snapshot.deinit();
    name[0] = 'X';
    value[0] = 'X';
    try expectLookup(snapshot.view(), "NAME", "first");
    try expectLookup(snapshot.view(), "EMPTY", "");
    try expectLookup(snapshot.view(), "ABSENT", null);
}

test "snapshot capture owns inputs and preserves lookup through allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, captureProbe, .{});
}

test "snapshot accepts an empty environment and rejects invalid entries" {
    var empty = try Snapshot.capture(std.testing.allocator, &.{});
    defer empty.deinit();
    try expectLookup(empty.view(), "ABSENT", null);
    for ([_]EnvironmentEntry{
        .{ .name = "", .value = "value" },
        .{ .name = "A=B", .value = "value" },
        .{ .name = "A\x00B", .value = "value" },
        .{ .name = "A", .value = "val\x00ue" },
    }) |entry| try std.testing.expectError(error.InvalidConfig, Snapshot.capture(std.testing.allocator, &.{entry}));
}
