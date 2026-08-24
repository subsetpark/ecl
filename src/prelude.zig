//! Embedded target-language bootstrap loader.
const std = @import("std");
const heap = @import("heap.zig");
const list = @import("list.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");

pub const Error = error{ OutOfMemory, InvalidPrelude };

var execution_access_seal: u8 = 0;

fn executionAccess() *const modules.ExecutionAccess {
    return @ptrCast(&execution_access_seal);
}

pub fn install(
    host: *const heap.HostCleanup,
    building: *env.BuildingEnv,
    registry: *modules.Registry,
    archive: *spans.SpanArchive,
    cancelled: *const std.atomic.Value(bool),
) Error!void {
    return installSource(
        host,
        building,
        registry,
        archive,
        cancelled,
        "prelude.ecl",
        @embedFile("prelude.ecl"),
    );
}

pub fn installSource(
    host: *const heap.HostCleanup,
    building: *env.BuildingEnv,
    registry: *modules.Registry,
    archive: *spans.SpanArchive,
    cancelled: *const std.atomic.Value(bool),
    source_name: []const u8,
    source: []const u8,
) Error!void {
    const allocator = host.allocator();
    const release_domain = heap.hostDomain(host);
    const environment = building.runtime();
    var diag: reader.Diag = .{};
    const result = archive.read(source_name, source, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => return error.InvalidPrelude,
    };
    var parsed = switch (result) {
        .complete => |complete| complete,
        .incomplete => return error.InvalidPrelude,
    };
    defer parsed.deinit();
    var root = heap.OwnedValue.init(release_domain, try archive.codeRoot(parsed.values()));
    defer root.deinit();
    const root_header = root.borrow().list;
    // Core alone is the chain for a primitive or an embedded prelude
    // definition, so every literal this text contains is labelled against core.
    archive.absorb(parsed.borrow(), root.borrow(), environment.coreCell().labeller()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProvenance => @panic("archive-bound prelude reader produced foreign provenance"),
    };
    _ = root.take();
    var arguments = heap.OwnedValue.init(release_domain, try list.fromValuesGeneric(allocator, &.{}));
    defer arguments.deinit();
    var unit = machine.Unit.init(
        allocator,
        release_domain,
        executionAccess(),
        .empty,
        environment,
        archive,
        null,
        arguments.borrow(),
        cancelled,
    );
    defer unit.deinit();
    unit.inherited.registry = registry;
    unit.replaceRootScope(building.rootScope(allocator));
    machine.run(&unit, root_header) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => return error.InvalidPrelude,
    };
    if (unit.stack.items.len != 0) return error.InvalidPrelude;
    building.finish();
}
