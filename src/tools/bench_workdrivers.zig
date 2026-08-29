//! Reproducible WorkDriver characterization through the public Session surface.
//!
//! The build runs this source twice. The timing artifact uses the ordinary
//! runtime, while the counter artifact enables compile-time machine counters.
//! Keeping those passes separate prevents instrumentation from becoming part
//! of the wall/CPU baseline it is intended to explain.
const std = @import("std");
const builtin = @import("builtin");
const ecl = @import("ecl");

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: std.atomic.Value(usize) = .init(0),
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn grew(self: *CountingAllocator, count: usize) void {
        const current = self.live.fetchAdd(count, .monotonic) + count;
        var observed = self.peak.load(.monotonic);
        while (current > observed) {
            observed = self.peak.cmpxchgWeak(observed, current, .monotonic, .monotonic) orelse return;
        }
    }

    fn shrank(self: *CountingAllocator, count: usize) void {
        var observed = self.live.load(.monotonic);
        while (true) {
            const updated = observed - @min(observed, count);
            observed = self.live.cmpxchgWeak(observed, updated, .monotonic, .monotonic) orelse return;
        }
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            _ = self.allocations.fetchAdd(1, .monotonic);
            self.grew(len);
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) self.grew(new_len - memory.len) else self.shrank(memory.len - new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            _ = self.allocations.fetchAdd(1, .monotonic);
            if (new_len >= memory.len) self.grew(new_len - memory.len) else self.shrank(memory.len - new_len);
        }
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.shrank(memory.len);
    }
};

const Case = struct {
    name: []const u8,
    setup: []const u8,
    workload: []const u8,
};

const Sample = struct {
    allocations: usize,
    peak_bytes: usize,
    polls: u64,
    wall_ns: u64,
    cpu_ns: u64,
    metrics: ecl.machine.RootExecutionMetrics,
};

const Mode = enum { timing, counters };
const full_sizes = [_]usize{ 1, 32, 1_024, 65_535, 65_536, 65_537, 1_048_576 };
const quick_sizes = [_]usize{ 32, 65_536 };
const full_cursor_sizes = [_]usize{ 1, 32, 1_024, 65_536 };
const quick_cursor_sizes = [_]usize{ 32, 4_096 };
const full_nested_cursor_sizes = [_]usize{ 1, 32, 1_024, 65_536 };
const quick_nested_cursor_sizes = [_]usize{ 32, 4_096 };
const full_materializer_budget_sizes = [_]usize{ 1, 32, 1_024, 65_536 };
const quick_materializer_budget_sizes = [_]usize{ 32, 4_096 };
const full_call_site_sizes = [_]usize{ 1, 32, 1_024, 65_536 };
const quick_call_site_sizes = [_]usize{ 32, 4_096 };
const full_local_call_site_sizes = [_]usize{ 1, 32, 1_024, 65_536 };
const quick_local_call_site_sizes = [_]usize{ 32, 4_096 };

fn timevalNs(value: std.posix.timeval) u64 {
    return @intCast(value.sec * std.time.ns_per_s + value.usec * std.time.ns_per_us);
}

fn cpuTimeNs() u64 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return 0;
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    return timevalNs(usage.utime) + timevalNs(usage.stime);
}

fn runSample(io: std.Io, workers: usize, case: Case) !Sample {
    var counting = CountingAllocator{ .backing = std.heap.smp_allocator };
    const session_allocator = if (comptime ecl.machine.root_execution_metrics_enabled)
        counting.allocator()
    else
        std.heap.smp_allocator;
    var runtime = try ecl.session.Session.initWithConfig(
        session_allocator,
        &.{},
        .{ .worker_pool = workers },
    );
    defer runtime.deinit();

    switch (try runtime.runUnit("<workdriver-setup>", case.setup)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.SetupFailed;
        },
        .incomplete => return error.SetupFailed,
    }

    const baseline_live = if (comptime ecl.machine.root_execution_metrics_enabled) baseline: {
        counting.allocations.store(0, .monotonic);
        const live = counting.live.load(.monotonic);
        counting.peak.store(live, .monotonic);
        break :baseline live;
    } else 0;
    const cpu_started = cpuTimeNs();
    const wall_started = std.Io.Timestamp.now(io, .awake);
    switch (try runtime.runUnit("<workdriver-workload>", case.workload)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.WorkloadFailed;
        },
        .incomplete => return error.WorkloadFailed,
    }
    const wall_elapsed = wall_started.durationTo(std.Io.Timestamp.now(io, .awake));
    return .{
        .allocations = if (comptime ecl.machine.root_execution_metrics_enabled)
            counting.allocations.load(.monotonic)
        else
            0,
        .peak_bytes = if (comptime ecl.machine.root_execution_metrics_enabled)
            counting.peak.load(.monotonic) - baseline_live
        else
            0,
        .polls = runtime.lastPolls(),
        .wall_ns = @intCast(@max(wall_elapsed.nanoseconds, 0)),
        .cpu_ns = cpuTimeNs() - cpu_started,
        .metrics = if (comptime ecl.machine.root_execution_metrics_enabled)
            ecl.session.RootExecutionObservation.last(&runtime)
        else
            .{},
    };
}

fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const rank = @min(values.len - 1, (values.len * numerator + denominator - 1) / denominator - 1);
    return values[rank];
}

fn printCase(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    workers: usize,
    size: usize,
    case: Case,
    repetitions: usize,
) !void {
    if (mode == .counters) {
        const sample = try runSample(io, workers, case);
        try out.print("{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
            case.name,
            workers,
            size,
            sample.allocations,
            sample.peak_bytes,
            sample.polls,
            sample.metrics.logical_transitions,
            sample.metrics.driver_resumes,
            sample.metrics.application_resumes,
            sample.metrics.scheduler_handoffs,
            sample.metrics.qualified_cache_hits,
            sample.metrics.qualified_cache_misses,
            sample.metrics.qualified_cache_heals,
            sample.metrics.local_cache_hits,
            sample.metrics.local_cache_misses,
        });
        return;
    }

    var wall: [101]u64 = undefined;
    var cpu: [101]u64 = undefined;
    var polls: u64 = 0;
    for (0..repetitions) |index| {
        const sample = try runSample(io, workers, case);
        wall[index] = sample.wall_ns;
        cpu[index] = sample.cpu_ns;
        polls = @max(polls, sample.polls);
    }
    const wall_values = wall[0..repetitions];
    const cpu_values = cpu[0..repetitions];
    try out.print("{s},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
        case.name,
        workers,
        size,
        repetitions,
        polls,
        percentile(wall_values, 50, 100),
        percentile(wall_values, 95, 100),
        percentile(wall_values, 99, 100),
        percentile(cpu_values, 50, 100),
        percentile(cpu_values, 95, 100),
    });
}

fn runScaling(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    sizes: []const usize,
    repetitions: usize,
) !void {
    for ([_]usize{ 1, 8 }) |workers| {
        for (sizes) |size| {
            const setup = try std.fmt.allocPrint(std.heap.smp_allocator, "{d} range", .{size});
            defer std.heap.smp_allocator.free(setup);
            try printCase(io, out, mode, workers, size, .{
                .name = "flat-x-scalar",
                .setup = setup,
                .workload = "1 + len",
            }, repetitions);

            const workload = try std.fmt.allocPrint(std.heap.smp_allocator, "pop {d} range len", .{size});
            defer std.heap.smp_allocator.free(workload);
            try printCase(io, out, mode, workers, size, .{
                .name = "range-materialize",
                .setup = "0",
                .workload = workload,
            }, repetitions);
            try out.flush();
        }
    }
}

fn runLatency(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    repetitions: usize,
    quick: bool,
) !void {
    const long_size: usize = if (quick) 200_000 else 5_000_000;
    const mixed = try std.fmt.allocPrint(
        std.heap.smp_allocator,
        "([1] {d} take sum) @spawn pop ([1] {d} take sum) @spawn (7) @spawn pair await-any pop",
        .{ long_size, long_size },
    );
    defer std.heap.smp_allocator.free(mixed);
    for ([_]usize{ 1, 8 }) |workers| {
        try printCase(io, out, mode, workers, long_size, .{
            .name = "mixed-short-latency",
            .setup = "0 pop",
            .workload = mixed,
        }, repetitions);
        try printCase(io, out, mode, workers, 0, .{
            .name = "cancellation-latency",
            .setup = "((1) () while) @spawn",
            .workload = "dup cancel await",
        }, repetitions);
        try out.flush();
    }
}

/// Isolates the per-operation first-frame allocation identified by the
/// allocation-budget suite. The focused range stops at 65,536 because that is
/// enough to expose linear allocation while keeping the durable full run
/// proportionate to the general throughput cases.
fn runCursorStorage(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    sizes: []const usize,
    repetitions: usize,
) !void {
    for ([_]usize{ 1, 8 }) |workers| {
        for (sizes) |size| {
            const setup = try std.fmt.allocPrint(std.heap.smp_allocator, "{d} range", .{size});
            defer std.heap.smp_allocator.free(setup);
            try printCase(io, out, mode, workers, size, .{
                .name = "single-frame-cursor",
                .setup = setup,
                .workload = "(pop 2 [[1 2] [3]] in?) each len",
            }, repetitions);
            try out.flush();
        }
    }
}

/// Exercises a parent cursor repeatedly completing a structural comparison
/// child. This is the focused case that distinguishes conservative integer
/// handoff from one explicit parent/child allowance.
fn runNestedCursorBatching(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    sizes: []const usize,
    repetitions: usize,
) !void {
    for ([_]usize{ 1, 8 }) |workers| {
        for (sizes) |size| {
            const setup = try std.fmt.allocPrint(
                std.heap.smp_allocator,
                "{d} range (pop {{'a 1}}) each",
                .{size},
            );
            defer std.heap.smp_allocator.free(setup);
            try printCase(io, out, mode, workers, size, .{
                .name = "nested-cursor-membership",
                .setup = setup,
                .workload = "{'z 1} swap in?",
            }, repetitions);
            try out.flush();
        }
    }
}

/// Exercises many small result materializers nested under one membership
/// cursor without invoking structural equality. Each singleton needle builds
/// a one-element result before the outer result is materialized.
fn runMaterializerBudget(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    sizes: []const usize,
    repetitions: usize,
) !void {
    for ([_]usize{ 1, 8 }) |workers| {
        for (sizes) |size| {
            const setup = try std.fmt.allocPrint(
                std.heap.smp_allocator,
                "{d} range (pop [1]) each",
                .{size},
            );
            defer std.heap.smp_allocator.free(setup);
            try printCase(io, out, mode, workers, size, .{
                .name = "membership-result-materialize",
                .setup = setup,
                .workload = "0 wrap in?",
            }, repetitions);
            try out.flush();
        }
    }
}

/// Separates a cold canonical qualified call from repeated execution of one
/// reader-owned call site. The quotation passed to `times` is one stable code
/// root, so every iteration after the first is eligible for the same cache
/// entry without changing the called module or binding.
fn runQualifiedCallSite(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    sizes: []const usize,
    repetitions: usize,
) !void {
    for ([_]usize{ 1, 8 }) |workers| {
        for (sizes) |size| {
            const workload = try std.fmt.allocPrint(
                std.heap.smp_allocator,
                "{d} (callsite-bench.one pop) times",
                .{size},
            );
            defer std.heap.smp_allocator.free(workload);
            try printCase(io, out, mode, workers, size, .{
                .name = "qualified-call-site",
                .setup = "((1) 'one def) 'callsite-bench @defm",
                .workload = workload,
            }, repetitions);
            try out.flush();
        }
    }
}

/// Keeps the outer qualified call identical in both variants and isolates the
/// repeated direct lookup of one word defined in the running module image.
fn runModuleLocalCallSite(
    io: std.Io,
    out: *std.Io.Writer,
    mode: Mode,
    sizes: []const usize,
    repetitions: usize,
) !void {
    for ([_]usize{ 1, 8 }) |workers| {
        for (sizes) |size| {
            const workload = try std.fmt.allocPrint(
                std.heap.smp_allocator,
                "{d} (local-callsite-bench.outer pop) times",
                .{size},
            );
            defer std.heap.smp_allocator.free(workload);
            try printCase(io, out, mode, workers, size, .{
                .name = "module-local-call-site",
                .setup = "((1) 'leaf def (leaf) 'outer def) 'local-callsite-bench @defm",
                .workload = workload,
            }, repetitions);
            try out.flush();

            const core_workload = try std.fmt.allocPrint(
                std.heap.smp_allocator,
                "{d} (local-core-bench.outer pop) times",
                .{size},
            );
            defer std.heap.smp_allocator.free(core_workload);
            try printCase(io, out, mode, workers, size, .{
                .name = "module-local-core-fallback",
                .setup = "((1 1 +) 'outer def) 'local-core-bench @defm",
                .workload = core_workload,
            }, repetitions);
            try out.flush();
        }
    }
}

pub fn main(init: std.process.Init) !void {
    if (builtin.mode == .Debug) return error.ReleaseBuildRequired;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip();
    var mode: Mode = .timing;
    var quick = false;
    var cursor_storage_only = false;
    var nested_cursor_only = false;
    var materializer_budget_only = false;
    var call_site_only = false;
    var local_call_site_only = false;
    var latency_only = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--counters")) mode = .counters;
        if (std.mem.eql(u8, arg, "--quick")) quick = true;
        if (std.mem.eql(u8, arg, "--cursor-storage-only")) cursor_storage_only = true;
        if (std.mem.eql(u8, arg, "--nested-cursor-only")) nested_cursor_only = true;
        if (std.mem.eql(u8, arg, "--materializer-budget-only")) materializer_budget_only = true;
        if (std.mem.eql(u8, arg, "--call-site-only")) call_site_only = true;
        if (std.mem.eql(u8, arg, "--local-call-site-only")) local_call_site_only = true;
        if (std.mem.eql(u8, arg, "--latency-only")) latency_only = true;
    }
    if ((mode == .counters) != ecl.machine.root_execution_metrics_enabled)
        return error.InstrumentationModeMismatch;
    const repetitions: usize = if (mode == .counters) 1 else if (quick) 3 else 101;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    try out.print("# schema=ecl.workdrivers.{s}.v6\n", .{@tagName(mode)});
    try out.print("# WorkDriver baseline ({s})\n", .{@tagName(mode)});
    try out.print("optimize={s},target={s}-{s},zig={s},root_counters={}\n", .{
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        builtin.zig_version_string,
        ecl.machine.root_execution_metrics_enabled,
    });
    if (mode == .timing)
        try out.writeAll("case,workers,size,repetitions,polls_max,wall_p50_ns,wall_p95_ns,wall_p99_ns,cpu_p50_ns,cpu_p95_ns\n")
    else
        try out.writeAll("case,workers,size,allocations,peak_bytes,root_polls,root_logical_transitions,root_driver_resumes,root_application_resumes,root_scheduler_handoffs,qualified_cache_hits,qualified_cache_misses,qualified_cache_heals,local_cache_hits,local_cache_misses\n");
    if (latency_only) {
        try runLatency(init.io, out, mode, repetitions, quick);
    } else if (call_site_only) {
        try runQualifiedCallSite(
            init.io,
            out,
            mode,
            if (quick) &quick_call_site_sizes else &full_call_site_sizes,
            repetitions,
        );
    } else if (local_call_site_only) {
        try runModuleLocalCallSite(
            init.io,
            out,
            mode,
            if (quick) &quick_local_call_site_sizes else &full_local_call_site_sizes,
            repetitions,
        );
    } else if (materializer_budget_only) {
        try runMaterializerBudget(
            init.io,
            out,
            mode,
            if (quick) &quick_materializer_budget_sizes else &full_materializer_budget_sizes,
            repetitions,
        );
    } else if (nested_cursor_only) {
        try runNestedCursorBatching(
            init.io,
            out,
            mode,
            if (quick) &quick_nested_cursor_sizes else &full_nested_cursor_sizes,
            repetitions,
        );
    } else if (cursor_storage_only) {
        try runCursorStorage(init.io, out, mode, if (quick) &quick_cursor_sizes else &full_cursor_sizes, repetitions);
    } else {
        try runScaling(init.io, out, mode, if (quick) &quick_sizes else &full_sizes, repetitions);
        try runCursorStorage(init.io, out, mode, if (quick) &quick_cursor_sizes else &full_cursor_sizes, repetitions);
        try runNestedCursorBatching(
            init.io,
            out,
            mode,
            if (quick) &quick_nested_cursor_sizes else &full_nested_cursor_sizes,
            repetitions,
        );
        try runMaterializerBudget(
            init.io,
            out,
            mode,
            if (quick) &quick_materializer_budget_sizes else &full_materializer_budget_sizes,
            repetitions,
        );
        try runQualifiedCallSite(
            init.io,
            out,
            mode,
            if (quick) &quick_call_site_sizes else &full_call_site_sizes,
            repetitions,
        );
        try runModuleLocalCallSite(
            init.io,
            out,
            mode,
            if (quick) &quick_local_call_site_sizes else &full_local_call_site_sizes,
            repetitions,
        );
        try runLatency(init.io, out, mode, repetitions, quick);
    }
    try out.flush();
}
