//! Embedded target-language bootstrap loader.
const std = @import("std");
const heap = @import("heap.zig");
const list = @import("list.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const poll = @import("poll.zig");

pub const Error = error{ OutOfMemory, InvalidPrelude };

pub fn install(
    allocator: std.mem.Allocator,
    building: *env.BuildingEnv,
    registry: *modules.Registry,
    archive: *spans.SpanArchive,
    cancelled: *const std.atomic.Value(bool),
) Error!void {
    return installSource(
        allocator,
        building,
        registry,
        archive,
        cancelled,
        "prelude.ecl",
        @embedFile("prelude.ecl"),
    );
}

pub fn installSource(
    allocator: std.mem.Allocator,
    building: *env.BuildingEnv,
    registry: *modules.Registry,
    archive: *spans.SpanArchive,
    cancelled: *const std.atomic.Value(bool),
    source_name: []const u8,
    source: []const u8,
) Error!void {
    const environment = building.runtime();
    var diag: reader.Diag = .{};
    const result = reader.read(allocator, source_name, source, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => return error.InvalidPrelude,
    };
    var parsed = switch (result) {
        .complete => |complete| complete,
        .incomplete => return error.InvalidPrelude,
    };
    defer parsed.deinit();
    const root = try list.fromValuesGeneric(allocator, parsed.forms);
    var root_owned = true;
    defer if (root_owned) heap.releaseValue(allocator, root);
    archive.absorb(&parsed, root, poll.WorkContext.unlimited()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => unreachable,
    };
    root_owned = false;
    const arguments = try list.fromValuesGeneric(allocator, &.{});
    defer heap.releaseValue(allocator, arguments);
    var unit = machine.Unit.init(
        allocator,
        .empty,
        environment,
        archive,
        null,
        arguments,
        cancelled,
    );
    defer unit.deinit();
    unit.registry = registry;
    unit.root_scope = building.rootScope(allocator);
    machine.run(&unit, root.list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.InvalidPrelude,
    };
    if (unit.stack.items.len != 0) return error.InvalidPrelude;
    building.finish();
}
