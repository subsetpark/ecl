//! Embedded target-language bootstrap loader.
const std = @import("std");
const print = @import("print.zig");
const heap = @import("heap.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const machine = @import("machine.zig");
const poll = @import("poll.zig");

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
    var environment = building.runtime();
    var archive = archive_owner.view();
    var diag: reader.Diag = .{};
    // Core alone is the chain for a primitive or an embedded prelude
    // definition, so every word this text contains links to a core slot.
    var ingestion = try archive.sourceIngestCursor(
        source_name,
        source,
        &diag,
        environment.linker(environment.coreScopeId()),
    );
    defer {
        while (!ingestion.advanceRetirement())
            _ = release_domain.advance(machine.kernel_poll_quantum);
        host.drain();
    }
    // The embedded prelude is a fixed, bounded input read on the installing
    // thread before any fiber exists, so no fiber's turn meters it.
    var work = poll.unbounded();
    const root_header = while (true) {
        switch (ingestion.advance(&work) catch |err| switch (err) {
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
    var fiber = machine.Fiber.init(
        allocator,
        release_domain,
        executionAccess(),
        .empty,
        &environment,
        &archive,
        // Phrases are recognized only once the core is frozen and the session
        // runs; the bootstrap fiber evaluates the prelude generically.
        .{ .registry = registry, .idiom_mode = .generic_only, .phase = .bootstrap },
        cancelled,
        .bootstrap,
        .own,
    );
    defer fiber.deinit();
    fiber.replaceRootScope(building.rootScope(allocator));
    machine.run(&fiber, root_header) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => {
            // The prelude is fixed at build time, so a failure here is a
            // source defect; name it rather than leaving a bare panic.
            if (fiber.terminal == .failed) {
                const rendered = try print.toOwnedString(allocator, fiber.terminal.failed);
                defer allocator.free(rendered);
                if (!@import("builtin").is_test) std.log.err("embedded prelude failed: {s}", .{rendered});
            }
            return error.InvalidPrelude;
        },
    };
    if (fiber.stack.items.len != 0) return error.InvalidPrelude;
    building.finish();
}
