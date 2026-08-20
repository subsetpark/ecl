//! Post-state characterization for the typed flat-leaf kernel seam.
//!
//! This tool measures the interpreter through its public surface — one
//! `Session` per case, one `runUnit` per workload — and reports two very
//! different kinds of number:
//!
//!   * **Deterministic counters** (allocation count, live bytes at peak, kernel
//!     safe points) are properties of the implementation. They are reproducible
//!     on any machine and are the durable content of the checked-in report.
//!   * **Timing** is a property of the machine, the toolchain, and the day. It
//!     is context for reading the counters, never evidence on its own, and is
//!     always re-measured rather than trusted from a file.
//!
//! It is deliberately not a before/after harness. The boxed flat route it
//! replaced no longer exists to measure, and the qualitative before-shape — one
//! boxed cell and one frame per element, then a profiling pass to recover a
//! representation the dispatch already knew — is recorded in the workstream's
//! verified-current-state inventory instead.
const std = @import("std");
const ecl = @import("ecl");

/// Wraps the session allocator to count what the run actually asked for. The
/// counters are the point: they do not vary with the machine.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn grew(self: *CountingAllocator, bytes: usize) void {
        self.live += bytes;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn shrank(self: *CountingAllocator, bytes: usize) void {
        self.live -= @min(self.live, bytes);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.allocations += 1;
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
            self.allocations += 1;
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
    class: []const u8,
    name: []const u8,
    /// Source run once for setup, left on the stack.
    setup: []const u8,
    /// The measured workload, applied to whatever setup left.
    workload: []const u8,
};

/// One case per operation class the workstream names, each paired with a ragged
/// or boxed case in the same class as the comparison floor.
const cases = [_]Case{
    .{ .class = "flat pervasion", .name = "leaf x scalar", .setup = "1000000 range", .workload = "1 + len" },
    .{ .class = "flat pervasion", .name = "leaf x leaf", .setup = "1000000 range", .workload = "dup + len" },
    .{ .class = "flat pervasion", .name = "unary", .setup = "1000000 range", .workload = "neg len" },
    .{ .class = "flat pervasion", .name = "boxed spine floor", .setup = "50000 range (wrap) each", .workload = "1 + len" },
    .{ .class = "mixed pervasion", .name = "i64 x f64 leaf", .setup = "1000000 range dup 0.5 *", .workload = "+ len" },
    .{ .class = "mixed pervasion", .name = "i64 leaf x float scalar", .setup = "1000000 range", .workload = "0.5 * len" },
    .{ .class = "recognized idiom", .name = "each", .setup = "1000000 range", .workload = "(1 +) each len" },
    .{ .class = "recognized idiom", .name = "zip-with", .setup = "1000000 range", .workload = "dup (+) zip-with len" },
    .{ .class = "recognized idiom", .name = "fold", .setup = "1000000 range", .workload = "0 (+) fold" },
    .{ .class = "recognized idiom", .name = "scan", .setup = "1000000 range", .workload = "0 (+) scan len" },
    .{ .class = "copy and gather", .name = "reverse", .setup = "1000000 range", .workload = "reverse len" },
    .{ .class = "copy and gather", .name = "cat", .setup = "1000000 range", .workload = "dup cat len" },
    .{ .class = "copy and gather", .name = "take cyclic", .setup = "1000 range", .workload = "1000000 take len" },
    .{ .class = "copy and gather", .name = "gather", .setup = "1000000 range", .workload = "dup at len" },
    .{ .class = "copy and gather", .name = "boxed spine floor", .setup = "50000 range (wrap) each", .workload = "reverse len" },
    // A mask, not arbitrary counts: `where` repeats each index by its count, so
    // a count vector of 1..n would ask for a result of quadratic size.
    .{ .class = "index vectors", .name = "where mask", .setup = "1000000 range 2 mod", .workload = "where len" },
    .{ .class = "index vectors", .name = "range", .setup = "0", .workload = "pop 1000000 range len" },
    .{ .class = "order", .name = "grade", .setup = "100000 range reverse", .workload = "grade len" },
    .{ .class = "order", .name = "group", .setup = "100000 range 100 mod", .workload = "group keys len" },
    .{ .class = "order", .name = "distinct", .setup = "5000 range 100 mod", .workload = "distinct len" },
    .{ .class = "text", .name = "split", .setup = "\"a,b,c,d,e,f,g,h\" 8000 take", .workload = "\",\" split len" },
    .{ .class = "text", .name = "join", .setup = "\"a,b,c,d,e,f,g,h\" 8000 take \",\" split", .workload = "\",\" join len" },
    .{ .class = "random", .name = "rand-ints", .setup = "[7 9]", .workload = "1000000 1000 rand-ints nip len" },
};

const scaling_sizes = [_]usize{ 1, 32, 1_024, 65_535, 65_536, 65_537, 1_048_576 };

const Measurement = struct {
    allocations: usize,
    peak_bytes: usize,
    polls: u64,
    nanoseconds: u64,
    failed: bool,
};

fn measure(io: std.Io, case: Case) !Measurement {
    var backing: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = backing.deinit();
    var counting = CountingAllocator{ .backing = backing.allocator() };
    var runtime = try ecl.session.Session.init(counting.allocator(), &.{});
    defer runtime.deinit();

    switch (try runtime.runUnit("<bench-setup>", case.setup)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.SetupFailed;
        },
        .incomplete => return error.SetupFailed,
    }

    // The measured window starts after setup so the counters describe the
    // workload rather than the input it was handed.
    counting.allocations = 0;
    counting.peak = counting.live;
    const started = std.Io.Timestamp.now(io, .awake);
    const outcome = try runtime.runUnit("<bench-workload>", case.workload);
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    const failed = switch (outcome) {
        .ok => false,
        .err => |failure| blk: {
            runtime.release(failure);
            break :blk true;
        },
        .incomplete => true,
    };
    return .{
        .allocations = counting.allocations,
        .peak_bytes = counting.peak - @min(counting.peak, counting.live),
        .polls = runtime.lastPolls(),
        .nanoseconds = @intCast(@max(elapsed.nanoseconds, 0)),
        .failed = failed,
    };
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;

    try out.print("# step14 kernel characterization\n\n", .{});
    try out.print("optimize: {s}\n", .{@tagName(@import("builtin").mode)});
    try out.print("zig: {s}\n", .{@import("builtin").zig_version_string});
    try out.print("target: {s}-{s}\n\n", .{
        @tagName(@import("builtin").cpu.arch),
        @tagName(@import("builtin").os.tag),
    });
    try out.print(
        "{s: <18} {s: <26} {s: >12} {s: >14} {s: >10} {s: >12}\n",
        .{ "class", "case", "allocations", "peak bytes", "polls", "ms" },
    );
    try out.flush();
    for (scaling_sizes) |size| {
        for ([_]bool{ false, true }) |ragged| {
            const setup = if (ragged)
                try std.fmt.allocPrint(std.heap.page_allocator, "{d} range (wrap) each", .{size})
            else
                try std.fmt.allocPrint(std.heap.page_allocator, "{d} range", .{size});
            defer std.heap.page_allocator.free(setup);
            const result = measure(init.io, .{
                .class = "scaling",
                .name = if (ragged) "ragged x scalar" else "flat x scalar",
                .setup = setup,
                .workload = "1 + len",
            }) catch |err| {
                try out.print(
                    "{s: <18} {s: <26} {d: >12} {s: >14}\n",
                    .{ "scaling", if (ragged) "ragged x scalar" else "flat x scalar", size, @errorName(err) },
                );
                try out.flush();
                continue;
            };
            try out.print(
                "{s: <18} {s: <26} {d: >12} {d: >14} {d: >10} {d: >12.3}{s}  n={d}\n",
                .{
                    "scaling",
                    if (ragged) "ragged x scalar" else "flat x scalar",
                    result.allocations,
                    result.peak_bytes,
                    result.polls,
                    @as(f64, @floatFromInt(result.nanoseconds)) / std.time.ns_per_ms,
                    if (result.failed) "  (failed)" else "",
                    size,
                },
            );
            try out.flush();
        }
    }
    for (cases) |case| {
        const result = measure(init.io, case) catch |err| {
            try out.print("{s: <18} {s: <26} {s: >12}\n", .{ case.class, case.name, @errorName(err) });
            try out.flush();
            continue;
        };
        try out.print(
            "{s: <18} {s: <26} {d: >12} {d: >14} {d: >10} {d: >12.3}{s}\n",
            .{
                case.class,
                case.name,
                result.allocations,
                result.peak_bytes,
                result.polls,
                @as(f64, @floatFromInt(result.nanoseconds)) / std.time.ns_per_ms,
                if (result.failed) "  (failed)" else "",
            },
        );
        try out.flush();
    }
    try out.flush();
}
