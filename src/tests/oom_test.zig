//! Slow, exhaustive allocation-failure coverage across initialized sessions.
//!
//! Keeping these surfaces in one probe avoids replaying the embedded prelude
//! bootstrap independently for every feature-specific failure index.
//!
//! Component-level probes elsewhere inject failures into a directly
//! constructed subject (`list.zig`, `dict.zig`, `env.zig`, `equal.zig`, the
//! reader, formatter, line-editor, registry, and native-validation probes);
//! none of them bootstraps a Session. This is the only sweep over a fully
//! initialized one, so a surface reachable only through a live Session — a
//! word, a prelude definition, a module, reflection, the loader, the
//! scheduler — has no allocation-failure coverage unless a snippet below
//! reaches it, and its behavioral tests still pass. Adding such a surface
//! means adding a snippet here; see `test_heap.zig` for the allocator
//! policy.
//!
//! `checkAllAllocationFailures` re-runs the whole probe once per allocation
//! ordinal, so a snippet's cost is multiplied by the total allocation count.
//! Keep additions short and reaching, not exhaustive — one line through a
//! path is coverage; a hundred lines through it is the same coverage, slower.
//! Snippets must leave the stack clean (`pop` what they push) and propagate
//! errors, or the sweep silently stops testing what follows.
const std = @import("std");
const session = @import("../session.zig");
const native_fixture = @import("native_fixture_options");

const LockedAllocator = struct {
    child: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn runOk(runtime: *session.Session, name: []const u8, source: []const u8) !void {
    switch (try runtime.runUnit(name, source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
}

fn fullSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [1024]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    const search = try std.fmt.allocPrint(
        thread_safe_allocator,
        "test/acceptance/modules{c}{s}",
        .{ std.fs.path.delimiter, native_fixture.directory },
    );
    defer thread_safe_allocator.free(search);
    var runtime = try session.Session.initWithHostConfig(
        thread_safe_allocator,
        &.{"argument"},
        std.testing.io,
        &output,
        &diagnostics,
        search,
        .cooperative,
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
            "[[1 2] [3]] raze pop [1 2] 5 take pop [2 0 3] where pop " ++
            "{'rows ([10 20] [30 40])} ['rows 1 0] at-path pop",
    );
    try runOk(
        &runtime,
        "oom-display.ecl",
        "[0 1 2 3 4 5] [2 3] reshape dup pp",
    );
    var display = try runtime.stackDisplay();
    display.deinit();
    try runOk(&runtime, "oom-display-cleanup.ecl", "pop");
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
            "({'kind 'custom 'data {'detail 7}} raise) attempt pop " ++
            "[3 4] (+) with call pop [5 6] (+) attempt-with pop " ++
            "[7 8] (+) spawn-with await pop " ++
            "[9 10] 'oom-seeded (+ 'x set) module-with oom-seeded.x pop",
    );
    try runOk(
        &runtime,
        "oom-session.ecl",
        "args pop \"42 missing\" parse pop",
    );
    try runOk(
        &runtime,
        "oom-combinators.ecl",
        "[(1) (111) (222)] cond pop " ++
            "[1 2 3] (dup 'each-local set each-local *) each pop " ++
            "[1] [2] (pop dup 'zip-with-local set zip-with-local pop) zip-with pop " ++
            "[1] (dup 'for-local set pop) for " ++
            "[1] 0 (+ dup 'fold-local set) fold pop " ++
            "[1] 0 (+ dup 'scan-local set) scan pop " ++
            "[1] (dup 'infra-local set) infra pop " ++
            // Capture-shape recognition allocates on its own path (the fused
            // kernel) and on the rejected one (the generic frame machine);
            // both belong in the consolidated allocation-failure sweep.
            "[1 2 3] 3 (+) partial each pop " ++
            "[1 2 3] ((3 4) first +) each pop",
    );
    try runOk(
        &runtime,
        "oom-concurrency.ecl",
        "([1 2 3] str) spawn await pop " ++
            "(1) spawn dup pair await-any pop pop " ++
            "(1) spawn dup await pop 0 await-for pop " ++
            "(1) spawn 1000000 await-for pop " ++
            "((1) () while) spawn dup cancel await pop " ++
            "[(1) (missing) (2 3)] (spawn) each await-all pop " ++
            "[1 2 3] (dup *) par-each pop",
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
        "oom-native.ecl",
        "'sample use 41 sample.increment pop 7 sample.singleton pop " ++
            "7 'sample 'increment qualify execute pop " ++
            "1000 range sample.sum-list pop {'a 1 'b 2} sample.sum-dict pop " ++
            "'answer 42 sample.pair-dict pop sample.builder-budget pop " ++
            "sample.cooperative pop (9 sample.draft-fail) attempt pop " ++
            "(9 sample.yield-forever) spawn dup cancel await pop",
    );
    try runOk(
        &runtime,
        "oom-module.ecl",
        "'allocation-module (1 'x setp (x) ( -- n ) 'get def) module " ++
            "'allocation-module use get pop 'short 'allocation-module alias short.get pop " ++
            "'allocation-module (2 'x setp (x) ( -- n ) 'get def) module get pop " ++
            "('bad ((dup) 'f def) module) attempt pop " ++
            // A non-empty construction stack is captured as durable slot
            // state, so capture, commit, and re-registration discard each
            // have an allocation-failure path of their own.
            "[11 12 13] 'oom-stateful (1 +) module-with " ++
            "[21 22] 'oom-stateful (2 +) module-with " ++
            // Transactional updates allocate on the draft, the replacement
            // snapshot, and the caller window; the failing half must leave
            // the durable stack and the caller stack untouched.
            "[0] 'oom-within (((1 + dup without) within) 'bump def " ++
            "((dup without missing) within) 'boom def " ++
            "((dup without) within) 'peek def) module-with " ++
            "oom-within.bump pop (oom-within.boom) attempt pop " ++
            // The failing half must publish nothing, so the durable stack
            // still holds exactly what the successful half left.
            "oom-within.peek 1 match pop " ++
            // Namespaced registration plus branded qualification and ordinary
            // late-bound execution each have Session-only allocation paths.
            "'oom.namespaced ((33) 'dynamic def) module " ++
            "'oom.namespaced 'dynamic qualify execute pop " ++
            "3 (dup) first execute pop pop " ++
            // Removal closes, quiesces, and retires through the same bounded
            // work, so its allocation-failure paths belong in the sweep too.
            "[1 2] 'oom-removed (((dup without) within) 'peek def) module-with " ++
            "oom-removed.peek pop 'oom-removed unmodule",
    );
    var completion = try runtime.completionCandidates("allocation-");
    defer completion.deinit();
    if (completion.items().len != 0) _ = completion.items()[0].len;
    try runOk(
        &runtime,
        "oom-definition-initial.ecl",
        "(1) (-- n : \"Old.\") 'allocation-target def",
    );
    const outcome = runtime.runUnit(
        "oom-definition-replacement.ecl",
        "(2) (input -- output : \"Replacement.\") 'allocation-target def",
    ) catch |err| {
        try runOk(
            &runtime,
            "oom-definition-preserved.ecl",
            "allocation-target 1 match 'allocation-target doc \"Old.\" match",
        );
        return err;
    };
    switch (outcome) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            runtime.release(failure);
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
