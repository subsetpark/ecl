//! Bounded copies from capability-free SDK message views into native storage.
const std = @import("std");
const ecl = @import("ecl-native");
const fs = @import("algorithms.zig");
pub const Error = error{ OutOfMemory, InvalidType, InvalidByte, Limit, InvalidPath };
pub const Progress = enum { pending, complete };

pub const Encoder = struct {
    position: u64,
    kind: enum { text, bytes },
    phase: union(enum) { start, measure: struct { index: usize = 0, bytes: usize = 0 }, copy: struct { index: usize = 0, offset: usize = 0 }, complete } = .start,
    count: usize = 0,
    buffer: ?[]u8 = null,
    pub fn init(position: u64, kind: @FieldType(Encoder, "kind")) Encoder {
        return .{ .position = position, .kind = kind };
    }
    pub fn step(self: *Encoder, ctx: *ecl.Cooperative, allocator: std.mem.Allocator) Error!Progress {
        while (ctx.consume(1)) switch (self.phase) {
            .start => {
                const input = ctx.input(&.{self.position}) orelse return error.InvalidType;
                if (input.kind() != .list or (self.kind == .text and !input.isString())) return error.InvalidType;
                self.count = std.math.cast(usize, input.length().?) orelse return error.Limit;
                self.phase = .{ .measure = .{} };
            },
            .measure => |*measuring| {
                if (measuring.index == self.count) {
                    self.buffer = try allocator.alloc(u8, measuring.bytes);
                    self.phase = .{ .copy = .{} };
                    continue;
                }
                const input = ctx.input(&.{ self.position, measuring.index }) orelse return error.InvalidType;
                const count: usize = switch (self.kind) {
                    .text => std.unicode.utf8CodepointSequenceLength(input.char() orelse return error.InvalidType) catch return error.InvalidType,
                    .bytes => blk: {
                        const value = input.int() orelse return error.InvalidByte;
                        if (value < 0 or value > 255) return error.InvalidByte;
                        break :blk 1;
                    },
                };
                measuring.bytes = std.math.add(usize, measuring.bytes, count) catch return error.Limit;
                measuring.index += 1;
            },
            .copy => |*copying| {
                if (copying.index == self.count) {
                    self.phase = .complete;
                    return .complete;
                }
                const input = ctx.input(&.{ self.position, copying.index }) orelse return error.InvalidType;
                copying.offset += switch (self.kind) {
                    .text => std.unicode.utf8Encode(input.char().?, self.buffer.?[copying.offset..][0..@min(4, self.buffer.?.len - copying.offset)]) catch return error.InvalidType,
                    .bytes => blk: {
                        self.buffer.?[copying.offset] = @intCast(input.int().?);
                        break :blk 1;
                    },
                };
                copying.index += 1;
            },
            .complete => return .complete,
        };
        return .pending;
    }
    pub fn take(self: *Encoder) []u8 {
        const buffer = self.buffer.?;
        self.buffer = null;
        return buffer;
    }
    pub fn deinit(self: *Encoder, allocator: std.mem.Allocator) void {
        if (self.buffer) |buffer| allocator.free(buffer);
        self.buffer = null;
    }
};

/// Caller-owned UTF-8 path storage stays stable through validation. Each slice
/// examines at most one SDK work unit per scalar, including long components.
pub const PathValidator = struct {
    index: usize = 0,
    component_start: usize = 0,
    pub fn step(self: *PathValidator, ctx: *ecl.Cooperative, bytes: []const u8) Error!union(enum) { pending, complete: fs.PathClass } {
        if (std.mem.eql(u8, bytes, ".")) return .{ .complete = .root };
        if (bytes.len == 0 or bytes[0] == '/' or bytes[bytes.len - 1] == '/') return error.InvalidPath;
        while (self.index < bytes.len and ctx.consume(1)) {
            const byte = bytes[self.index];
            if (byte == 0) return error.InvalidPath;
            if (byte == '/') {
                try component(bytes[self.component_start..self.index]);
                self.index += 1;
                self.component_start = self.index;
            } else {
                const count = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidPath;
                if (count > bytes.len - self.index) return error.InvalidPath;
                _ = std.unicode.utf8Decode(bytes[self.index..][0..count]) catch return error.InvalidPath;
                self.index += count;
            }
        }
        if (self.index != bytes.len) return .pending;
        try component(bytes[self.component_start..]);
        return .{ .complete = .entry };
    }
    fn component(bytes: []const u8) error{InvalidPath}!void {
        if (bytes.len == 0 or std.mem.eql(u8, bytes, ".") or std.mem.eql(u8, bytes, "..")) return error.InvalidPath;
    }
};
