//! Slow, exhaustive allocation-failure coverage across initialized sessions.
//!
//! Keeping these surfaces in one probe avoids replaying the embedded prelude
//! bootstrap independently for every feature-specific failure index.
const std = @import("std");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const session = @import("../session.zig");

fn runOk(runtime: *session.Session, name: []const u8, source: []const u8) !void {
    switch (try runtime.runUnit(name, source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            heap.releaseValue(runtime.allocator, failure);
            return error.UnexpectedLanguageError;
        },
    }
}

fn fullSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [1024]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    var runtime = try session.Session.initWithHost(
        allocator,
        &.{"argument"},
        std.testing.io,
        &output,
        &diagnostics,
        "test/acceptance/modules",
    );
    defer runtime.deinit();

    try runOk(
        &runtime,
        "oom-numeric.ecl",
        "[[1 2] [3]] 10 * pop [0 1] exp pop [0 1] [1 1] atan2 pop",
    );
    try runOk(
        &runtime,
        "oom-sequence.ecl",
        "[[1 2] [3 4]] flip pop [1 2 3] [2 3] reshape pop " ++
            "[[1 2] [3]] raze pop [1 2] 5 take pop [2 0 3] where pop",
    );
    try runOk(&runtime, "oom-order.ecl", "[2 1 2 1] grade group pop");
    try runOk(
        &runtime,
        "oom-dict-text.ecl",
        "{'a 1} 'b 2 put keys pop [\"a\" \"b\"] \"—\" join \"—\" split pop " ++
            "['a 'b] [1 2] to-dict keys pop ['c 3] dict-of keys pop " ++
            "[1 2 3] 1 9 put pop \"ab\" reverse 0 \\λ put pop " ++
            "['a 1] str [1] \"{}\" format pop",
    );
    try runOk(
        &runtime,
        "oom-primitives.ecl",
        "(3 4 +) 'sum def sum pop (1 0 /) attempt pop (5 6 +) attempt pop " ++
            "({'kind 'custom 'data {'detail 7}} raise) attempt pop",
    );
    try runOk(
        &runtime,
        "oom-session.ecl",
        "args pop \"42 missing\" parse pop",
    );
    try runOk(
        &runtime,
        "oom-combinators.ecl",
        "[1 2 3] (dup 'each-local set each-local *) each pop " ++
            "[1] [2] (pop dup 'each2-local set each2-local pop) each2 pop " ++
            "[1] (dup 'for-local set pop) for " ++
            "[1] 0 (+ dup 'fold-local set) fold pop " ++
            "[1] 0 (+ dup 'scan-local set) scan pop " ++
            "[1] (dup 'infra-local set) infra pop",
    );
    try runOk(
        &runtime,
        "oom-reflection.ecl",
        "'reflection-module ((1) ( -- n ) 'f def) module " ++
            "'reflection-module use 'reflection-module.f body pop words " ++
            "'f which 'reflection-module.f see",
    );
    try runOk(&runtime, "oom-loader.ecl", "'stats use answer pop");
    try runOk(
        &runtime,
        "oom-module.ecl",
        "'allocation-module (1 'x setp (x) ( -- n ) 'get def) module " ++
            "'allocation-module use get pop 'short 'allocation-module alias short.get pop " ++
            "'allocation-module (2 'x setp (x) ( -- n ) 'get def) module get pop " ++
            "('bad ((dup) 'f def) module) attempt pop",
    );

    try runOk(
        &runtime,
        "oom-definition-initial.ecl",
        "(1) (-- n : \"Old.\") 'allocation-target def",
    );
    const id = try intern.intern("allocation-target");
    var old = (try runtime.environment.session.resolveDirect(id, .unlimited())).?;
    defer old.deinit(allocator);
    const outcome = runtime.runUnit(
        "oom-definition-replacement.ecl",
        "(2) (input -- output : \"Replacement.\") 'allocation-target def",
    ) catch |err| {
        var current = (try runtime.environment.session.resolveDirect(id, .unlimited())).?;
        defer current.deinit(allocator);
        try std.testing.expectEqual(old.binding.word, current.binding.word);
        try std.testing.expectEqual(old.effect.?.quotation, current.effect.?.quotation);
        try std.testing.expectEqual(old.doc.?, current.doc.?);
        return err;
    };
    switch (outcome) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            heap.releaseValue(allocator, failure);
            return error.UnexpectedLanguageError;
        },
    }
}

test "oom: full-session surfaces propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.heap.smp_allocator,
        fullSessionAllocationProbe,
        .{},
    );
}
