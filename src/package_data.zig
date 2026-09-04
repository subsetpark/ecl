//! Host-side decoding of inert package records. These helpers are blocking:
//! catalog discovery and lock loading own their input limits and schemas.
//! Borrowed values remain owned by the input; ownedUtf8 transfers its buffer
//! on success and frees unfinished conversion storage on every failure.
const std = @import("std");
const value = @import("value.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const storage = @import("kernel_storage.zig");
const Value = value.Value;

pub const ValidationError = error{ Invalid, OutOfMemory };

pub fn exactFields(item: Value, names: []const []const u8) ValidationError!*value.DictHandle {
    const header = try asDict(item);
    if (header.length() != names.len) return error.Invalid;
    for (0..@as(usize, @intCast(header.length()))) |index| {
        const key = dict.keyAt(header, index);
        if (key != .symbol) return error.Invalid;
        var known = false;
        for (names) |name| known = known or std.mem.eql(u8, intern.get(key.symbol), name);
        if (!known) return error.Invalid;
    }
    for (names) |name| _ = try field(header, name);
    return header;
}

pub fn field(header: *value.DictHandle, name: []const u8) ValidationError!Value {
    for (0..@as(usize, @intCast(header.length()))) |index| {
        const key = dict.keyAt(header, index);
        if (key == .symbol and std.mem.eql(u8, intern.get(key.symbol), name))
            return dict.valueAt(header, index);
    }
    return error.Invalid;
}

pub fn asDict(item: Value) ValidationError!*value.DictHandle {
    return switch (item) {
        .dict => |header| header,
        else => error.Invalid,
    };
}

pub fn ownedUtf8(allocator: std.mem.Allocator, item: Value) ValidationError![]u8 {
    if (!item.isString()) return error.Invalid;
    var cursor = storage.StringEncoder.init(allocator, item);
    defer cursor.deinit();
    while (true) switch (cursor.advance(65_536) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCodepoint => return error.Invalid,
    }) {
        .pending => {},
        .complete => |bytes| return bytes,
    };
}
