//! Generated ownership and reclamation interleavings for snapshot publication.
const std = @import("std");
const minish = @import("minish");
const snapshot = @import("../snapshot_core.zig");

const max_readers = 4;
const max_versions = 18;

const Version = struct {
    owners: u8 = 0,
    current: bool = false,
    retired: bool = false,
};

const Reader = struct {
    phase: snapshot.Reader = .idle,
    lease: ?usize = null,
};

const Model = struct {
    readers: [max_readers]Reader = [_]Reader{.{}} ** max_readers,
    versions: [max_versions]Version = [_]Version{.{}} ** max_versions,
    version_count: usize = 1,
    current: usize = 0,
    announced: usize = 0,

    fn init() Model {
        var result = Model{};
        result.versions[0] = .{ .owners = 1, .current = true };
        return result;
    }

    fn announce(self: *Model, index: usize) !void {
        const reader = &self.readers[index];
        if (reader.lease != null) return;
        const decision = snapshot.decideReader(reader.phase, .announce) catch return;
        try std.testing.expect(decision.command == .announce);
        reader.phase = decision.next;
        self.announced += 1;
    }

    fn protect(self: *Model, index: usize) !void {
        const reader = &self.readers[index];
        const decision = snapshot.decideReader(reader.phase, .protect) catch return;
        try std.testing.expect(decision.command == .retain_payload);
        reader.phase = decision.next;
        reader.lease = self.current;
        self.versions[self.current].owners += 1;
    }

    fn leave(self: *Model, index: usize) !void {
        const reader = &self.readers[index];
        const decision = snapshot.decideReader(reader.phase, .leave) catch return;
        try std.testing.expect(decision.command == .leave);
        reader.phase = decision.next;
        self.announced -= 1;
    }

    fn releaseLease(self: *Model, index: usize) !void {
        const version = self.readers[index].lease orelse return;
        self.readers[index].lease = null;
        try std.testing.expect(self.versions[version].owners > 0);
        self.versions[version].owners -= 1;
    }

    fn publish(self: *Model) void {
        if (self.version_count == self.versions.len) return;
        self.versions[self.current].current = false;
        self.versions[self.current].retired = true;
        self.current = self.version_count;
        self.version_count += 1;
        self.versions[self.current] = .{ .owners = 1, .current = true };
    }

    fn reclaim(self: *Model) !void {
        var retired_count: usize = 0;
        for (self.versions[0..self.version_count]) |version|
            retired_count += @intFromBool(version.retired);
        const command = snapshot.decideReclamation(self.announced, retired_count);
        if (command == .keep) return;
        try std.testing.expectEqual(@as(usize, 0), self.announced);
        for (self.versions[0..self.version_count]) |*version| if (version.retired) {
            try std.testing.expect(version.owners > 0);
            version.retired = false;
            version.owners -= 1;
        };
    }

    fn assertSafety(self: *const Model) !void {
        var announced: usize = 0;
        for (self.readers) |reader| {
            announced += @intFromBool(reader.phase != .idle);
            if (reader.lease) |version| try std.testing.expect(self.versions[version].owners > 0);
        }
        try std.testing.expectEqual(announced, self.announced);
        try std.testing.expect(self.versions[self.current].current);
        try std.testing.expect(self.versions[self.current].owners > 0);
        for (self.versions[0..self.version_count], 0..) |version, index| {
            if (version.current) try std.testing.expectEqual(self.current, index);
            if (version.owners == 0) {
                try std.testing.expect(!version.current and !version.retired);
                for (self.readers) |reader| try std.testing.expect(reader.lease != index);
            }
        }
    }

    fn drain(self: *Model) !void {
        for (0..self.readers.len) |index| {
            if (self.readers[index].phase != .idle) try self.leave(index);
            try self.releaseLease(index);
        }
        try self.reclaim();
        try self.assertSafety();
        for (self.versions[0..self.version_count], 0..) |version, index| {
            if (index == self.current) try std.testing.expectEqual(@as(u8, 1), version.owners) else try std.testing.expectEqual(@as(u8, 0), version.owners);
        }
    }
};

fn runTrace(encoded: u64) !void {
    var model = Model.init();
    var remaining = encoded;
    for (0..16) |_| {
        const event: u4 = @truncate(remaining);
        remaining >>= 4;
        const reader = event % max_readers;
        switch (event / max_readers) {
            0 => try model.announce(reader),
            1 => try model.protect(reader),
            2 => try model.leave(reader),
            3 => switch (reader) {
                0 => try model.releaseLease(event % max_readers),
                1 => model.publish(),
                2, 3 => try model.reclaim(),
                else => unreachable,
            },
            else => unreachable,
        }
        try model.assertSafety();
    }
    try model.drain();
}

test "snapshot properties: arbitrary readers publications and reclamation are safe" {
    try minish.check(std.testing.allocator, minish.gen.int(u64), runTrace, .{
        .num_runs = 512,
        .seed = 0x5a9_5a07_0a11,
        .max_shrink_attempts = 512,
    });
}
