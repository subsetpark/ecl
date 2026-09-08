//! Value parsing for the registered process factory. The opening owns flat,
//! exact-capacity storage and borrows the validated request until retirement.
const std = @import("std");
const Value = @import("value.zig").Value;
const values = @import("value.zig");
const dict = @import("dict.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const external = @import("external.zig");
const process = @import("process_port.zig");
const factories = @import("port_factory.zig");
const message = @import("port_message.zig");
const Failure = factories.Failure;

pub fn open(allocator: std.mem.Allocator, access: ?*external.ProcessAccess, context: factories.Context, config: *const message.Validated) error{OutOfMemory}!factories.Start {
    if (config.value() != .dict) return .{ .failed = Failure.init(.type, "expected a process specification dict") };
    const granted = access orelse return .{ .failed = Failure.init(.domain, "process creation is unavailable") };
    const owned = try allocator.create(Parser);
    errdefer allocator.destroy(owned);
    const blob = try allocator.alloc(u8, config.footprint().bytes);
    errdefer allocator.free(blob);
    owned.* = .{ .memory = allocator, .access = granted, .context = context, .config = config.value(), .blob = blob, .keys = .{
        try intern.intern("executable"), try intern.intern("cwd"), try intern.intern("args"), try intern.intern("env"),
    } };
    return .{ .opening = try factories.Opening.create(Parser, owned) };
}

const Parser = struct {
    const Target = enum { executable, cwd, argument, env_name, env_value };
    const Text = struct { source: Value, target: Target, index: usize = 0, start: usize };
    memory: std.mem.Allocator,
    access: *external.ProcessAccess,
    context: factories.Context,
    config: Value,
    keys: [4]u32,
    blob: []u8,
    used: usize = 0,
    field: usize = 0,
    index: usize = 0,
    collection: Value = .{ .int = 0 },
    phase: union(enum) { fields, arguments, environment, text: Text, launch } = .fields,
    executable: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    args: ?[][]const u8 = null,
    environment: ?[]process.EnvironmentEntry = null,
    env_name: []const u8 = &.{},

    pub fn allocator(self: *Parser) std.mem.Allocator {
        return self.memory;
    }
    pub fn release(self: *Parser) void {
        const memory = self.memory;
        memory.free(self.blob);
        if (self.args) |args| memory.free(args);
        if (self.environment) |entries| memory.free(entries);
        memory.destroy(self);
    }
    fn beginText(self: *Parser, source: Value, target: Target) bool {
        if (!source.isString()) return false;
        self.phase = .{ .text = .{ .source = source, .target = target, .start = self.used } };
        return true;
    }
    pub fn advance(self: *Parser, quantum: usize) error{OutOfMemory}!factories.Progress {
        var remaining = quantum;
        while (remaining != 0) : (remaining -= 1) switch (self.phase) {
            .fields => {
                if (self.field == self.config.dict.length()) {
                    if (self.executable == null) return .{ .failed = Failure.init(.domain, "process spec requires 'executable") };
                    self.phase = .launch;
                    continue;
                }
                const key = dict.keyAt(self.config.dict, self.field);
                const item = dict.valueAt(self.config.dict, self.field);
                if (key != .symbol) return .{ .failed = Failure.init(.type, "expected symbol process specification keys") };
                if (key.symbol == self.keys[0] or key.symbol == self.keys[1]) {
                    if (!self.beginText(item, if (key.symbol == self.keys[0]) .executable else .cwd))
                        return .{ .failed = Failure.init(.type, "process string fields must contain strings") };
                } else if (key.symbol == self.keys[2]) {
                    if (item != .list) return .{ .failed = Failure.init(.type, "'args must be a list of strings") };
                    self.args = try self.memory.alloc([]const u8, @intCast(item.list.length()));
                    self.collection = item;
                    self.index = 0;
                    self.phase = .arguments;
                } else if (key.symbol == self.keys[3]) {
                    if (item != .dict) return .{ .failed = Failure.init(.type, "'env must be a string-to-string dict") };
                    self.environment = try self.memory.alloc(process.EnvironmentEntry, @intCast(item.dict.length()));
                    self.collection = item;
                    self.index = 0;
                    self.phase = .environment;
                } else return .{ .failed = Failure.init(.domain, "unknown process specification field") };
            },
            .arguments, .environment => {
                const count = if (self.phase == .arguments) self.args.?.len else self.environment.?.len;
                if (self.index == count) {
                    self.field += 1;
                    self.phase = .fields;
                    continue;
                }
                const source = if (self.phase == .arguments) list.atUnchecked(self.collection, self.index) else dict.keyAt(self.collection.dict, self.index);
                if (!self.beginText(source, if (self.phase == .arguments) .argument else .env_name))
                    return .{ .failed = Failure.init(.type, "process string fields must contain strings") };
            },
            .text => |*text| {
                if (text.index != text.source.list.length()) {
                    const scalar = values.unicodeScalar(list.atUnchecked(text.source, text.index).char) orelse
                        return .{ .failed = Failure.init(.domain, "process string contains an invalid Unicode scalar") };
                    var encoded: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(scalar, &encoded) catch
                        return .{ .failed = Failure.init(.domain, "process string contains an invalid Unicode scalar") };
                    @memcpy(self.blob[self.used..][0..count], encoded[0..count]);
                    self.used += count;
                    text.index += 1;
                    continue;
                }
                const slice = self.blob[text.start..self.used];
                switch (text.target) {
                    .executable, .cwd => |target| {
                        if (target == .executable) self.executable = slice else self.cwd = slice;
                        self.field += 1;
                        self.phase = .fields;
                    },
                    .argument => {
                        self.args.?[self.index] = slice;
                        self.index += 1;
                        self.phase = .arguments;
                    },
                    .env_name => {
                        self.env_name = slice;
                        if (!self.beginText(dict.valueAt(self.collection.dict, self.index), .env_value))
                            return .{ .failed = Failure.init(.type, "process string fields must contain strings") };
                    },
                    .env_value => {
                        self.environment.?[self.index] = .{ .name = self.env_name, .value = slice };
                        self.index += 1;
                        self.phase = .environment;
                    },
                }
            },
            .launch => {
                const resource = process.spawnFromUnit(self.access, self.context.scope.scheduler, self.context.scope, .{
                    .executable = self.executable.?,
                    .cwd = self.cwd,
                    .args = if (self.args) |args| args else &.{},
                    .environment = if (self.environment) |entries| entries else &.{},
                }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Unsupported => .{ .failed = Failure.init(.domain, "process ports are unsupported on this target") },
                    error.Denied => .{ .failed = Failure.init(.domain, "process specification denied by host policy") },
                    error.InvalidSpec => .{ .failed = Failure.init(.domain, "invalid process specification") },
                    error.LiveLimit => .{ .failed = Failure.init(.domain, "host process-port limit reached") },
                    error.ScopeClosing => .{ .failed = Failure.init(.cancelled, "process scope is closing") },
                    error.Io => .{ .failed = Failure.init(.io, "could not spawn process") },
                };
                return .{ .resource = resource };
            },
        };
        return .yielded;
    }
};
