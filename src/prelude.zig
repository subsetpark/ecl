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
    archive_owner: *spans.SpanArchiveOwner,
    cancelled: *const std.atomic.Value(bool),
) Error!void {
    return installSource(
        host,
        building,
        registry,
        archive_owner,
        cancelled,
        "prelude.ecl",
        @embedFile("prelude.ecl"),
    );
}

pub fn installSource(
    host: *const heap.HostCleanup,
    building: *env.BuildingEnv,
    registry: *modules.Registry,
    archive_owner: *spans.SpanArchiveOwner,
    cancelled: *const std.atomic.Value(bool),
    source_name: []const u8,
    source: []const u8,
) Error!void {
    const allocator = host.allocator();
    const release_domain = heap.hostDomain(host);
    const environment = building.runtime();
    var archive = archive_owner.view();
    var diag: reader.Diag = .{};
    // Core alone is the chain for a primitive or an embedded prelude
    // definition, so every word this text contains carries the core scope.
    var ingestion = try archive.sourceIngestCursor(
        source_name,
        source,
        &diag,
        @intFromEnum(environment.coreScopeId()),
    );
    defer {
        while (!ingestion.advanceRetirement())
            _ = release_domain.advance(machine.kernel_poll_quantum);
        host.drain();
    }
    const root_header = while (true) {
        switch (ingestion.advance() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => return error.InvalidPrelude,
            error.InvalidProvenance => @panic("archive-bound prelude reader produced foreign provenance"),
        }) {
            .pending => _ = release_domain.advance(machine.kernel_poll_quantum),
            .complete => |result| switch (result) {
                .complete => |header| break header,
                .incomplete => return error.InvalidPrelude,
            },
        }
    };
    var arguments = heap.OwnedValue.init(release_domain, try list.fromValuesGeneric(allocator, &.{}));
    defer arguments.deinit();
    var unit = machine.Unit.init(
        allocator,
        release_domain,
        executionAccess(),
        .empty,
        environment,
        &archive,
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
