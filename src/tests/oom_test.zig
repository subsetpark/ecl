//! Slow, exhaustive allocation-failure coverage across initialized sessions.
//!
//! Each logical standard-library, package, and host surface owns an independent
//! failure window. Operations in one module still share its publication cost;
//! unrelated modules never run as prefixes of one another's allocation
//! ordinals. Package synchronization and CLI additionally separate module
//! publication from their comparatively expensive operations.
//!
//! Component-level probes elsewhere inject failures into a directly
//! constructed subject (`list.zig`, `dict.zig`, `env.zig`, `equal.zig`, the
//! reader, formatter, line-editor, registry, and native-validation probes);
//! none of them bootstraps a Session. These are the only sweeps over fully
//! initialized Sessions, so a surface reachable only through one — a
//! word, a prelude definition, a module, reflection, the loader, the
//! scheduler — has no allocation-failure coverage unless a snippet below
//! reaches it, and its behavioral tests still pass. Adding such a surface
//! means adding a snippet here; see `test_heap.zig` for the allocator
//! policy.
//!
//! `checkAllAllocationFailures` re-runs the whole probe once per allocation
//! ordinal, so a snippet's cost is multiplied by the total allocation count.
//! Keep additions short and reaching: one line through a
//! path is coverage; a hundred lines through it is the same coverage, slower.
//! Snippets must leave the stack clean (`pop` what they push) and propagate
//! errors, or the sweep silently stops testing what follows. The core and
//! project probes exhaust their distinct Session initialization paths once;
//! the standard-library and host probes begin their failure windows after
//! initialization instead of repeating those same ordinals. Each probe
//! partitions its ordinals between four workers, matching the release-candidate
//! runner while preserving exhaustive failure injection.
const std = @import("std");
const session = @import("../session.zig");
const native_fixture = @import("native_fixture_options");
const archive_fixtures = @import("archive_fixture_options");
const process_fixture = @import("process_fixture_options");

/// Keep every OOM test in one compiled artifact while letting build and CI
/// runners select independent families at execution time. `@src().fn_name`
/// contains the declared test name, so a substring filter does not have to be
/// duplicated beside the declaration it selects.
fn requireSelectedOomTest(source: std.builtin.SourceLocation) !void {
    const filter = std.testing.environ.getPosix("ECL_OOM_FILTER") orelse return;
    if (std.mem.indexOf(u8, source.fn_name, filter) == null) return error.SkipZigTest;
}

fn archiveSource(allocator: std.mem.Allocator) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.valid);
    try source.writer.writeAll(" 'cwd \"archive\" archive.unpack-tgz pop");
    return allocator.dupe(u8, source.written());
}

const package_a_key = "a-1.0.0-1f9aefdfdd91996e4f2f80b7f89f1ac3d8907616b74f1cf55a1a48042556738a";
/// The lock hash of package `a` in the sync probes; the store probe verifies
/// the seal it just installed, so it needs the fixture's real digest.
const package_a_hash = "sha256-1f9aefdfdd91996e4f2f80b7f89f1ac3d8907616b74f1cf55a1a48042556738a";
const package_valid_seal_hash = "sha256-0e22c7712d6b5dc9fe01542ffcc7e6c01e641aab3c7ed0021a29fbf93004f4d8";

fn packageStoreSource(allocator: std.mem.Allocator) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" pkg.store.inspect pop ");
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" 'cache \"" ++ package_a_key ++ "\" pkg.store.install pop ");
    try source.writer.writeAll("'cache \"" ++ package_a_key ++ "\" pkg.store.present? pop ");
    try source.writer.writeAll("'cache \"" ++ package_a_key ++ "\" pkg.store.manifest pop ");
    try source.writer.writeAll("'cache \"" ++ package_a_key ++ "\" \"a\" \"" ++ package_valid_seal_hash ++ "\" pkg.store.verify ");
    try source.writer.writeAll("'cache \"" ++ package_a_key ++ "\" \"a\" \"" ++ package_valid_seal_hash ++ "\" pkg.store.read-seal pop");
    return allocator.dupe(u8, source.written());
}

const package_sync_source =
    "{'format 1 'name \"r\" 'version \"0.1.0\" 'exports {} 'requires " ++
    "{\"a\" {'package \"a\" 'version \"1.0.0\" 'url \"https://e.com/a.tgz\" " ++
    "'hash \"" ++ package_a_hash ++ "\"}}} pkg.sync.run pop";

const package_cli_source = "[] pkg.cli.tree";

const PackageScratch = struct {
    directory: std.testing.TmpDir,
    path: [:0]u8,

    fn init() !PackageScratch {
        const allocator = std.testing.allocator;
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(path);
        const lock_probe_hash = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "ecl.pkg",
            .data = "{'format 1 'name \"root\" 'version \"0.1.0\" 'exports {} 'requires {}}\n",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "ecl.lock",
            .data = "{'format 1 'root \"root\" 'packages {\"lockprobe\" {'version \"1.0.0\" 'url \"https://e.com/p.tgz\" 'hash \"sha256-" ++ lock_probe_hash ++ "\"}} 'requires {\"lockprobe\" {} \"root\" {\"lockprobe\" {'package \"lockprobe\" 'version \"1.0.0\"}}}}\n",
        });
        try directory.dir.createDir(
            std.testing.io,
            "lockprobe-1.0.0-" ++ lock_probe_hash,
            .default_dir,
        );
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "lockprobe-1.0.0-" ++ lock_probe_hash ++ "/lockprobe.ecl",
            .data = "[] ((42) 'answer def) 'lockprobe @defm\n",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "lockprobe-1.0.0-" ++ lock_probe_hash ++ "/ecl.pkg",
            .data = "{'format 1 'name \"lockprobe\" 'version \"1.0.0\" 'exports {\"lockprobe\" [\"**/*\"]} 'requires {}}\n",
        });
        return .{ .directory = directory, .path = path };
    }

    fn deinit(self: *PackageScratch) void {
        std.testing.allocator.free(self.path);
        self.directory.cleanup();
    }

    /// Materialize the already-verified package fixture as sync's offline
    /// prerequisite. `pkg.store.install` has its own exhaustive failure window
    /// in the package-store probe; running it through the injected Session for
    /// every `pkg.sync.run` ordinal made setup dominate the release gate.
    fn installPackageA(self: *PackageScratch) !void {
        const key = "a-1.0.0-1f9aefdfdd91996e4f2f80b7f89f1ac3d8907616b74f1cf55a1a48042556738a";
        try self.directory.dir.createDir(std.testing.io, key, .default_dir);
        try self.directory.dir.writeFile(std.testing.io, .{
            .sub_path = key ++ "/a.ecl",
            .data = "[] (() 'noop def) 'a @defm\n",
        });
        try self.directory.dir.writeFile(std.testing.io, .{
            .sub_path = key ++ "/ecl.pkg",
            .data = "{'format 1 'name \"a\" 'version \"1.0.0\" 'exports {\"a\" [\"**/*\"]} 'requires {}}\n",
        });
    }
};

fn appendFixtureBytes(writer: *std.Io.Writer, encoded: []const u8) !void {
    try writer.writeByte('[');
    var high: ?u8 = null;
    var index: usize = 0;
    for (encoded) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        const nibble = try std.fmt.charToDigit(byte, 16);
        if (high) |first| {
            if (index != 0) try writer.writeByte(' ');
            try writer.print("{d}", .{first << 4 | nibble});
            high = null;
            index += 1;
        } else high = nibble;
    }
    if (high != null) return error.InvalidFixture;
    try writer.writeByte(']');
}

fn appendQuoted(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '\\' or byte == '"') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

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

/// Logs the failure before discarding it, and consumes it either way.
///
/// The sweep replays a probe once per allocation point, so a bare "produced an
/// unexpected language error" leaves nothing to act on: the only way forward is
/// to bisect the probe by hand. The dict names the word and the message
/// directly. Rendering allocates from the same injected allocator, so it can
/// legitimately fail mid-sweep — but a deterministic bug shows up on the first,
/// uninjected replay, which is exactly where rendering succeeds.
fn reportUnexpectedFailure(
    runtime: *session.Session,
    name: []const u8,
    failure: session.Value,
) error{UnexpectedLanguageError} {
    if (runtime.renderValue(failure)) |rendered| {
        var owned = rendered;
        defer owned.deinit();
        std.log.err("OOM probe `{s}` failed: {s}", .{ name, owned.bytes() });
    } else |_| {
        std.log.err("OOM probe `{s}` failed, and rendering it also ran out", .{name});
    }
    runtime.release(failure);
    return error.UnexpectedLanguageError;
}

fn runOk(runtime: *session.Session, name: []const u8, source: []const u8) !void {
    switch (try runtime.runUnit(name, source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| return reportUnexpectedFailure(runtime, name, failure),
    }
}

fn runExpectedLanguageError(runtime: *session.Session, name: []const u8, source: []const u8) !void {
    switch (try runtime.runUnit(name, source)) {
        .ok, .incomplete => return error.ExpectedLanguageError,
        .err => |failure| runtime.release(failure),
    }
}

const allocation_failure_shard_count = 4;

fn checkAllocationFailureShard(
    backing_allocator: std.mem.Allocator,
    comptime probe: anytype,
    needed_alloc_count: usize,
    shard_index: usize,
) !void {
    var fail_index = shard_index;
    while (fail_index < needed_alloc_count) : (fail_index += allocation_failure_shard_count) {
        var failing = std.testing.FailingAllocator.init(backing_allocator, .{
            .fail_index = fail_index,
        });

        if (probe(failing.allocator())) |_| {
            if (failing.has_induced_failure) {
                return error.SwallowedOutOfMemoryError;
            }
            return error.NondeterministicMemoryUsage;
        } else |err| switch (err) {
            error.OutOfMemory => {
                if (failing.allocated_bytes != failing.freed_bytes) {
                    std.debug.print(
                        "\nfail_index: {d}/{d}\nallocated bytes: {d}\nfreed bytes: {d}\nallocations: {d}\ndeallocations: {d}\n",
                        .{
                            fail_index,
                            needed_alloc_count,
                            failing.allocated_bytes,
                            failing.freed_bytes,
                            failing.allocations,
                            failing.deallocations,
                        },
                    );
                    return error.MemoryLeakDetected;
                }
            },
            else => |unexpected| return unexpected,
        }
    }
}

fn checkAllAllocationFailuresParallel(
    backing_allocator: std.mem.Allocator,
    comptime probe: anytype,
) !void {
    // Process-lifetime intern and native-loader state can make the first
    // Session take a one-time allocation path. Settle it before measuring the
    // repeatable Session-owned ordinals that the failure sweep replays.
    try probe(backing_allocator);
    var baseline = std.testing.FailingAllocator.init(backing_allocator, .{});
    try probe(baseline.allocator());

    const Context = struct {
        backing_allocator: std.mem.Allocator,
        needed_alloc_count: usize,
        shard_index: usize,
        result: ?anyerror = null,

        fn run(context: *@This()) void {
            checkAllocationFailureShard(
                context.backing_allocator,
                probe,
                context.needed_alloc_count,
                context.shard_index,
            ) catch |err| {
                context.result = err;
            };
        }
    };

    var contexts: [allocation_failure_shard_count]Context = undefined;
    var threads: [allocation_failure_shard_count]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();

    for (&contexts, 0..) |*context, shard_index| {
        context.* = .{
            .backing_allocator = backing_allocator,
            .needed_alloc_count = baseline.alloc_index,
            .shard_index = shard_index,
        };
        threads[shard_index] = try std.Thread.spawn(.{}, Context.run, .{context});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (contexts) |context| if (context.result) |err| return err;
}

fn checkPostInitAllocationFailureShard(
    backing_allocator: std.mem.Allocator,
    comptime probe: anytype,
    needed_alloc_count: usize,
    ordinal_shard_index: usize,
    ordinal_shard_count: usize,
    worker_index: usize,
) !void {
    var failure_offset = ordinal_shard_index + worker_index * ordinal_shard_count;
    const stride = allocation_failure_shard_count * ordinal_shard_count;
    while (failure_offset < needed_alloc_count) : (failure_offset += stride) {
        var failing = std.testing.FailingAllocator.init(backing_allocator, .{});

        if (probe(&failing, failure_offset)) |_| {
            if (failing.has_induced_failure) {
                return error.SwallowedOutOfMemoryError;
            }
            return error.NondeterministicMemoryUsage;
        } else |err| switch (err) {
            error.OutOfMemory => {
                if (!failing.has_induced_failure) return error.UnexpectedOutOfMemory;
                if (failing.allocated_bytes != failing.freed_bytes) {
                    std.debug.print(
                        "\nfailure offset: {d}/{d}\nallocated bytes: {d}\nfreed bytes: {d}\nallocations: {d}\ndeallocations: {d}\n",
                        .{
                            failure_offset,
                            needed_alloc_count,
                            failing.allocated_bytes,
                            failing.freed_bytes,
                            failing.allocations,
                            failing.deallocations,
                        },
                    );
                    return error.MemoryLeakDetected;
                }
            },
            else => |unexpected| return unexpected,
        }
    }
}

/// Exhausts only allocations after a probe has initialized its Session.
///
/// `probe` returns the allocator ordinal where its distinct surface begins and
/// sets `fail_index` to that ordinal plus `failure_offset` when the offset is
/// non-null. Session initialization itself is already exhausted by the core
/// and project-session probes; replaying those same ordinals for every
/// standard-library, package, and host bundle multiplied the slow gate without
/// adding coverage.
fn checkAllPostInitAllocationFailuresParallel(
    backing_allocator: std.mem.Allocator,
    comptime probe: anytype,
) !void {
    return checkPostInitAllocationFailureOrdinalShard(
        backing_allocator,
        probe,
        0,
        1,
    );
}

/// Exhausts one residue class of a probe's post-init allocation ordinals.
///
/// Distinct test declarations can select every index in `ordinal_shard_count`
/// and run on independent CI workers. Each declaration still uses the normal
/// four local workers for its own offsets, so their union is exactly the
/// unsharded sweep without overlap.
fn checkPostInitAllocationFailureOrdinalShard(
    backing_allocator: std.mem.Allocator,
    comptime probe: anytype,
    comptime ordinal_shard_index: usize,
    comptime ordinal_shard_count: usize,
) !void {
    comptime {
        if (ordinal_shard_count == 0) @compileError("an OOM ordinal shard count must be nonzero");
        if (ordinal_shard_index >= ordinal_shard_count) @compileError("an OOM ordinal shard index must be in range");
    }
    var warm = std.testing.FailingAllocator.init(backing_allocator, .{});
    _ = try probe(&warm, null);

    var baseline = std.testing.FailingAllocator.init(backing_allocator, .{});
    const first_failure_index = try probe(&baseline, null);
    const needed_alloc_count = baseline.alloc_index - first_failure_index;
    if (needed_alloc_count == 0) return error.MissingAllocationCoverage;

    const Context = struct {
        backing_allocator: std.mem.Allocator,
        needed_alloc_count: usize,
        worker_index: usize,
        result: ?anyerror = null,

        fn run(context: *@This()) void {
            checkPostInitAllocationFailureShard(
                context.backing_allocator,
                probe,
                context.needed_alloc_count,
                ordinal_shard_index,
                ordinal_shard_count,
                context.worker_index,
            ) catch |err| {
                context.result = err;
            };
        }
    };

    var contexts: [allocation_failure_shard_count]Context = undefined;
    var threads: [allocation_failure_shard_count]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();

    for (&contexts, 0..) |*context, shard_index| {
        context.* = .{
            .backing_allocator = backing_allocator,
            .needed_alloc_count = needed_alloc_count,
            .worker_index = shard_index,
        };
        threads[shard_index] = try std.Thread.spawn(.{}, Context.run, .{context});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (contexts) |context| if (context.result) |err| return err;
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
        .{
            .io = std.testing.io,
            .output = &output,
            .diagnostics = &diagnostics,
            .ecl_path = search,
            .environ = &.{.{ .name = "ECL_OOM_PROBE", .value = "probe" }},
            // The sweep must never block on the test runner's own stdin;
            // the refusal path is what has allocation ordinals here.
            .standard_input = .program_source,
        },
        .cooperative,
    );
    defer runtime.deinit();

    // Cold dotted completion reaches the embedded builtin manifest before
    // any Unit has loaded or published that module.
    var cold_completion = try runtime.completionCandidates("json.pa");
    cold_completion.deinit();

    try runOk(
        &runtime,
        "oom-numeric.ecl",
        // The last three reach the typed seam's own allocation points and
        // nothing else: a solely-owned operand taking the reuse claim, a
        // recognized idiom entering the same loop, and the typed reduction.
        // Each stays two elements long because the sweep replays a snippet once
        // per allocation point.
        "[[1 2] [3]] 10 * pop [0 1] exp pop [0 1] [1 1] atan2 pop " ++
            "[1 2] 1 + pop [1 2] (1 +) each pop [1 2] 0 (+) fold pop " ++
            "\"aλ\" 1 + pop \"aλ\" \"bβ\" - pop",
    );
    try runOk(
        &runtime,
        "oom-sequence.ecl",
        "[[1 2] [3 4]] flip pop [1 2 3] [2 3] reshape pop " ++
            "[[1 2] [3]] raze pop [1 2] 5 take pop [2 0 3] where pop " ++
            // The typed copy and gather capabilities, and the typed draw fill.
            "[1 2] reverse pop [1 2] [0 1] at pop [3 1] 2 4 rand.ints pop pop " ++
            // Scalar and flat-list needles reach both typed membership drivers.
            "1 [1 2] in? pop [1 3] [1 2] in? pop [1 2] dup 0 9 put pop pop " ++
            "[1 2] [0 1] [3 4] put pop [1 2] [0 1] (1 +) update pop " ++
            "[1 2] [3] reshape pop " ++
            "{'rows ([10 20] [30 40])} ['rows 1 0] at-path pop",
    );
    try runOk(
        &runtime,
        "oom-display.ecl",
        "[0 1 2 3 4 5] [2 3] reshape dup io.pp io.stack",
    );
    var display = try runtime.stackDisplay();
    display.deinit();
    try runOk(&runtime, "oom-display-cleanup.ecl", "pop");
    try runOk(&runtime, "oom-order.ecl", "[2 1 2 1] grade group pop [1 2 1] distinct pop");
    try runOk(
        &runtime,
        "oom-dict-text.ecl",
        "{'a 1} 'b 2 put dict.keys pop [\"a\" \"b\"] \"—\" join \"—\" split pop " ++
            "['a 'b] [1 2] dict.from-lists dict.keys pop ['c 3] dict.from-flat dict.keys pop " ++
            "[1 2 3] 1 9 put pop [1 2] 0 del pop \"ab\" reverse 0 \\λ put pop " ++
            "['a 1] str [1] \"{}\" str.format pop [\"raw\"] \"{}\" str.format pop",
    );
    try runOk(
        &runtime,
        "oom-primitives.ecl",
        "(3 4 +) 'oom-sum def oom-sum pop " ++
            "1 2 stack pop pop pop " ++
            "1 'oom-unset set 'oom-unset unset 2 'oom-unset set 'oom-unset undef " ++
            "[] (1 0 /) @attempt pop [] (5 6 +) @attempt pop " ++
            "[] ({'kind 'custom 'data {'detail 7}} raise) @attempt pop " ++
            "[3 4] (+) with call pop 2 3 (+) (*) (-) tri2 pop pop pop " ++
            "[5 6] (+) @attempt pop " ++
            "[7 8] (+) @spawn await pop " ++
            "[1] (2) @attempt pop " ++
            // This admitted reader body reaches ConstructionDriver allocation
            // after the re-scope cursor owns its source. Exhausting that exact
            // allocation proves cleanup remains with only one movable owner.
            "[9 10] (+ 'x set) 'oom-seeded @defm oom-seeded.x pop",
    );
    try runOk(
        &runtime,
        "oom-session.ecl",
        "args pop \"42 missing\" parse pop \"1\" int pop \"1\" float pop " ++
            // Each conversion reaches its own driver once: spelling and byte
            // decoding, UTF-8 encoding, symbol lookup and insertion, and the
            // core qualifier. The insertion spelling is fresh on the first
            // replay and already interned on later ones, so both arms of the
            // intern cursor see allocation failure.
            "'a chars pop [97] chars pop \"a\" bytes pop \"a\" symbol pop \"oom-fresh-spelling\" intern pop " ++
            "97 char pop 1 core.dup pop pop",
    );
    try runOk(
        &runtime,
        "oom-combinators.ecl",
        "[(1) (111) (222)] cond pop " ++
            "1 (dup 0 =) () (1 -) () linrec pop " ++
            "[1 2 3] (dup 'each-local set each-local *) each pop " ++
            "[1] [2] (pop dup 'zip-with-local set zip-with-local pop) zip-with pop " ++
            "[1] (dup 'for-local set pop) for " ++
            "{'a 1} (1 + pop) for " ++
            "[1] 0 (+ dup 'fold-local set) fold pop " ++
            "[1] 0 (+ dup 'scan-local set) scan pop " ++
            "[1] (dup 'infra-local set) infra pop " ++
            "[1 2] 2 (sum) stencil pop " ++
            "1 (0 >) (dup 1 - swap) unfold pop pop " ++
            // Capture-shape recognition allocates on its own path (the fused
            // kernel) and on the rejected one (the generic frame machine);
            // both belong in the consolidated allocation-failure sweep.
            "[1 2 3] 3 (+) partial each pop " ++
            "[1 2 3] ((3 4) first +) each pop",
    );
    try runOk(
        &runtime,
        "oom-concurrency.ecl",
        "[] ([1 2 3] str) @spawn await pop " ++
            "[] (1) @spawn dup pair await-any pop pop " ++
            "[] (1) @spawn dup await pop 0 await-for pop " ++
            "[] (1) @spawn 1000000 await-for pop " ++
            "[] ((1) () while) @spawn dup cancel await pop " ++
            "[(1) (missing) (2 3)] ([] swap @spawn) each await-all pop " ++
            "[1 2 3] [] (dup *) @each pop",
    );
    try runOk(
        &runtime,
        "oom-reflection.ecl",
        "[] (( -- n ) (1) 'f def) 'reflection-module @defm " ++
            "'reflection-module ('f) import words " ++
            "'f which 'reflection-module.f see",
    );
    try runOk(&runtime, "oom-loader.ecl", "'stats ('answer) import answer pop");
    try runOk(
        &runtime,
        "oom-native.ecl",
        "'sample ('increment) import 41 sample.increment pop 7 sample.singleton pop " ++
            "7 'sample 'increment qualify execute pop " ++
            "[1 2] sample.sum-list pop {'a 1 'b 2} sample.sum-dict pop " ++
            "'answer 42 sample.pair-dict pop sample.builder-budget pop " ++
            "sample.cooperative pop [] (9 sample.draft-fail) @attempt pop " ++
            "[] (9 sample.yield-forever) @spawn dup cancel await pop",
    );
    try runOk(
        &runtime,
        "oom-module.ecl",
        "*file* pop " ++
            "[] (1 'x setp ( -- n ) (x) 'get def) 'allocation-module @defm " ++
            "'allocation-module ('get) import get pop 'short 'allocation-module alias short.get pop " ++
            "[] (2 'x setp ( -- n ) (x) 'get def) 'allocation-module @defm get pop " ++
            "[] ([] ((dup) 'f def) 'bad @defm) @attempt pop " ++
            // A non-empty construction stack is captured as durable slot
            // state, so capture, commit, and re-registration discard each
            // have an allocation-failure path of their own.
            "[11 12 13] (1 +) 'oom-stateful @defm " ++
            "[21 22] (2 +) 'oom-stateful @defm " ++
            // Transactional updates allocate on the draft, the replacement
            // snapshot, and the caller window; the failing half must leave
            // the durable stack and the caller stack untouched.
            "[0] (((1 + dup without) within) 'bump def " ++
            "((dup without missing) within) 'boom def " ++
            "((dup without) within) 'peek def) 'oom-within @defm " ++
            "oom-within.bump pop [] (oom-within.boom) @attempt pop " ++
            // The failing half must publish nothing, so the durable stack
            // still holds exactly what the successful half left.
            "oom-within.peek 1 match? pop " ++
            // Namespaced registration plus branded qualification and ordinary
            // late-bound execution each have Session-only allocation paths.
            "[] ((33) 'dynamic def) 'oom.namespaced @defm " ++
            "'oom.namespaced 'dynamic qualify execute pop " ++
            "3 (dup) first execute pop pop " ++
            // Removal closes, quiesces, and retires through the same bounded
            // work, so its allocation-failure paths belong in the sweep too.
            "[1 2] (((dup without) within) 'peek def) 'oom-removed @defm " ++
            "oom-removed.peek pop 'oom-removed unmodule",
    );
    try runOk(
        &runtime,
        "oom-module-value.ecl",
        // The value wrapper, the registration record, the copied state
        // template, and the barrier publication each have their own ordinals.
        // One construction registered twice and one reload reach all four.
        "[] (1) @module dup 'oom-left register 'oom-right register " ++
            "[] (2) @module 'oom-left register [] (3) @module pop",
    );
    var completion = try runtime.completionCandidates("allocation-");
    defer completion.deinit();
    if (completion.items().len != 0) _ = completion.items()[0].len;
    try runOk(
        &runtime,
        "oom-definition-initial.ecl",
        "(-- n : \"Old.\") (1) 'allocation-target def",
    );
    const outcome = runtime.runUnit(
        "oom-definition-replacement.ecl",
        "(input -- output : \"Replacement.\") (2) 'allocation-target def",
    ) catch |err| {
        try runOk(
            &runtime,
            "oom-definition-preserved.ecl",
            "allocation-target 1 match? 'allocation-target doc \"Old.\" match?",
        );
        return err;
    };
    switch (outcome) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| return reportUnexpectedFailure(
            &runtime,
            "oom-definition-preserved.ecl",
            failure,
        ),
    }
}

/// Exhausts the project-lock discovery branch of Session initialization once.
/// Every standard-library and package probe below uses the same host shape, so
/// their post-init windows do not need to replay these ordinals independently.
fn projectSessionInitializationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var scratch = try PackageScratch.init();
    defer scratch.deinit();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [1024]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(
        thread_safe_allocator,
        &.{"argument"},
        .{
            .io = std.testing.io,
            .output = &output,
            .diagnostics = &diagnostics,
            .project_start = scratch.path,
            .environ = &.{
                .{ .name = "ECL_OOM_PROBE", .value = "probe" },
                .{ .name = "ECL_CACHE", .value = scratch.path },
            },
            .standard_input = .program_source,
        },
        .cooperative,
    );
    runtime.deinit();
}

const StdlibSurface = enum {
    locked_project_module,
    random,
    dict,
    error_value,
    result,
    string,
    csv,
    json,
    table,
    archive_hash,
    archive_unpack,
    package_store,
    package_store_gc,
    host_io,
    filesystem,
    clock,
    time,
    http,
    http_server,
    process,
    net,
    net_connection,
    net_give,
    package_sync_module,
    package_sync,
    package_cli_module,
    package_cli,
};

fn stdlibSessionAllocationProbe(
    comptime surface: StdlibSurface,
    failing: *std.testing.FailingAllocator,
    failure_offset: ?usize,
) !usize {
    const allocator = failing.allocator();
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var scratch = try PackageScratch.init();
    defer scratch.deinit();
    if (surface == .package_sync) try scratch.installPackageA();
    // Paths and source strings are borrowed test scaffolding outside Session
    // ownership. Keep their construction outside the injected allocator so
    // the sweep enumerates live Session paths rather than this helper's writer.
    const scaffold_allocator = std.testing.allocator;
    const scratch_path = scratch.path;
    const process_path = if (surface == .process)
        try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, process_fixture.process_exe, scaffold_allocator)
    else
        null;
    defer if (surface == .process) scaffold_allocator.free(process_path);
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [1024]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    // The scratch directory is the working-directory root, the project root,
    // and the shared cache store at once: every host surface a snippet names
    // resolves to the same temporary directory.
    var runtime = try session.Session.initPackageCommand(
        thread_safe_allocator,
        &.{"argument"},
        .{
            .io = std.testing.io,
            .output = &output,
            .diagnostics = &diagnostics,
            .project_start = scratch_path,
            .environ = &.{
                .{ .name = "ECL_OOM_PROBE", .value = "probe" },
                .{ .name = "ECL_CACHE", .value = scratch_path },
            },
            .standard_input = .program_source,
            .process_policy = if (surface == .process) .{
                .executables = .{ .exact = &.{process_path} },
                .stdin_capacity = 16,
                .stdout_capacity = 16,
                .stderr_capacity = 16,
            } else null,
            .net_policy = if (surface == .net or surface == .net_connection or
                surface == .net_give or surface == .http_server) .{
                .binds = .{ .exact = &.{.{ .address = "127.0.0.1", .port = 0 }} },
            } else null,
            .filesystem_policy = .{ .roots = &.{
                .{ .name = "cwd", .absolute_path = scratch_path, .permissions = .all },
                .{
                    .name = "project",
                    .absolute_path = scratch_path,
                    .permissions = .{ .read_data = true, .inspect = true, .create = true, .replace = true },
                },
            } },
        },
        .cooperative,
        .{ .synchronize = .{ .cache = scratch_path, .project = scratch.directory.dir } },
    );
    defer runtime.deinit();

    // Loading these large embedded modules has its own failure window. Their
    // public operation probes start after publication so definitions added to
    // either module do not multiply the expensive operation's replay count.
    switch (surface) {
        .package_sync => try runOk(
            &runtime,
            "oom-pkg-sync-setup.ecl",
            "'pkg.sync ('run) import",
        ),
        .package_cli => try runOk(
            &runtime,
            "oom-pkg-cli-setup.ecl",
            "'pkg.cli ('tree) import",
        ),
        else => {},
    }

    const first_failure_index = failing.alloc_index;
    if (failure_offset) |offset| failing.fail_index = first_failure_index + offset;

    switch (surface) {
        .locked_project_module => try runOk(
            &runtime,
            "oom-lock-tier.ecl",
            "lockprobe.answer pop",
        ),
        .random => try runOk(
            &runtime,
            "oom-random.ecl",
            "'rng ('seed 'deal 'shuffle 'ints 'float) import " ++
                "42 seed 2 4 deal shuffle pop 2 6 ints pop float pop " ++
                "[7 0] 2 6 rand.ints nip pop",
        ),
        .dict => try runOk(
            &runtime,
            "oom-dict.ecl",
            "[['a 1] ['b 2]] dict.from-pairs dup dict.keys pop dup dict.vals pop " ++
                "dup 'a dict.has? pop dup ['b 'a] dict.at pop dup {} dict.merge dup dict.pairs dict.from-pairs pop " ++
                "dup ['a 'b] dict.keys-exactly? pop dup ['a] (1 +) dict.update " ++
                "dup 'c 0 (1 +) dict.update-or dup (nip) dict.map dup (1 +) each " ++
                "dup (pop pop 1) dict.filter dup (pop pop 0) dict.reject dup ['a] dict.take " ++
                "dup ['a] dict.drop dup ['a] dict.split pop pop " ++
                "{'a 2} (|key left right| key pop left right +) dict.merge-with pop " ++
                "['a 'b] 0 dict.from-keys pop",
        ),
        .error_value => try runOk(
            &runtime,
            "oom-error.ecl",
            "'io error.new \"read failed\" error.with-message {'path \"p\"} error.with-data " ++
                "dup error.valid? pop dup 'io error.kind? pop ['io 'timeout] error.kind-in? pop",
        ),
        .result => try runOk(
            &runtime,
            "oom-result.ecl",
            "[1 2] result.ok (+) result.and-then result.or-raise pop",
        ),
        .string => try runOk(
            &runtime,
            "oom-string.ecl",
            "\"  hi  \" str.trim str.upper pop",
        ),
        .csv => try runOk(
            &runtime,
            "oom-csv.ecl",
            "\"a,b\\nc,d\" csv.parse dup csv.emit pop pop",
        ),
        .json => try runOk(
            &runtime,
            "oom-json.ecl",
            "\"{\\\"a\\\":[1,null]}\" json.parse json.emit pop",
        ),
        .table => try runOk(
            &runtime,
            "oom-table.ecl",
            "{\"r\" [\"e\" \"w\"] \"v\" [1 2]} " ++
                "[\"r\"] [[\"t\" \"v\" (sum)]] table.aggregate pop " ++
                "{\"id\" [1 2]} {\"cid\" [2] \"n\" [9]} [[\"id\" \"cid\"]] " ++
                "{\"n\" 0} table.left-join-with pop",
        ),
        .archive_hash => try runOk(
            &runtime,
            "oom-archive-hash.ecl",
            "[97] archive.sha256 pop",
        ),
        .archive_unpack => {
            const archive_source = try archiveSource(scaffold_allocator);
            defer scaffold_allocator.free(archive_source);
            try runOk(&runtime, "oom-archive.ecl", archive_source);
        },
        .package_store => {
            const package_source = try packageStoreSource(scaffold_allocator);
            defer scaffold_allocator.free(package_source);
            try runOk(&runtime, "oom-pkg-store.ecl", package_source);
        },
        .package_store_gc => try runOk(
            &runtime,
            "oom-pkg-gc.ecl",
            "[\"a-1.0.0-1f9aefdfdd91996e4f2f80b7f89f1ac3d8907616b74f1cf55a1a48042556738a\"] pkg.store.gc pop",
        ),
        .host_io => try runOk(
            &runtime,
            "oom-hostio.ecl",
            // Console, environment, and standard-input refusal paths.
            "\"probe\" io.eprint 1 \"probe\" io.debug pop " ++
                "\"ECL_OOM_PROBE\" getenv pop " ++
                "[] (\"ECL_OOM_ABSENT\" getenv) @attempt pop [] (io.stdin) @attempt pop",
        ),
        .filesystem => try runOk(
            &runtime,
            "oom-fs.ecl",
            // Every fs word once, through the same root: encoders, the
            // resolver, staging, listing, metadata, and the structured
            // failure dictionary all have Session-only allocation paths.
            "\"pr\\n\" 'cwd \"p.txt\" fs.create-text " ++
                "'cwd \"p.txt\" fs.read-text pop 'cwd \"p.txt\" fs.read-bytes pop " ++
                "[7 8] 'cwd \"p.txt\" fs.replace-bytes \"z\" 'cwd \"p.txt\" fs.replace-text " ++
                "'cwd \"p.txt\" fs.stat pop 'cwd \"p.txt\" fs.lstat pop 'cwd \"p.txt\" fs.exists? pop " ++
                "'cwd \"d\" fs.mkdir 'cwd \"d\" fs.list pop " ++
                "'cwd \"p.txt\" 'cwd \"d/c.txt\" fs.copy 'cwd \"d/c.txt\" \"d/m.txt\" fs.rename " ++
                "'cwd \"d/m.txt\" fs.remove-file 'cwd \"d\" fs.remove-dir " ++
                "[] ('cwd \"absent\" fs.read-text) @attempt pop " ++
                "[] ('none \"x\" fs.exists?) @attempt pop " ++
                "\"a//b/../c\" path.normalize pop (\"a\" \"b\") path.join pop " ++
                "\"a/b.c\" path.dirname pop \"a/b.c\" path.basename pop \"a/b.c\" path.extension pop " ++
                "\"a/b\" path.components pop \"a/b\" path.valid-relative? pop",
        ),
        .clock => try runOk(
            &runtime,
            "oom-clock.ecl",
            // The probe Session grants no wall clock, so `unix` exercises the
            // refusal path; a zero sleep parks and resumes without a timer.
            "clock.now clock.elapsed pop [] (0 clock.sleep 1) @spawn await pop " ++
                "[] (clock.unix) @attempt pop",
        ),
        .net => try runOk(
            &runtime,
            "oom-net.ecl",
            // One granted bind read back and closed twice, one denied port,
            // and one listener released by its child scope.
            "{'address \"127.0.0.1\" 'port 0} net.listen dup net.local-address pop " ++
                "dup net.close net.close " ++
                "[] ({'address \"127.0.0.1\" 'port 1} net.listen) @attempt pop " ++
                "[] ({'address \"127.0.0.1\" 'port 0} net.listen net.local-address) @spawn await pop",
        ),
        // A live exchange has scheduling-dependent readiness cardinality (the
        // acceptor thread may fill the slot before or after the driver's first
        // poll), so like the process surface it cannot be an oracle for
        // allocation ordinals; the connection cell's own lifecycle is swept
        // by a unit test in net_port.zig. Here every ordinal is deterministic
        // under the cooperative scheduler: a child parks in accept with no
        // peer, the parent closes the listener, and the child fails closed.
        // These probes are ECL source only and `net` has no outbound connect
        // word, so no program here can hold a connection: the driver that
        // `net.close` installs for one, and the drain wait it registers, are
        // swept by `connectionLifecycle` in net_port.zig instead, which can
        // supply a real peer and still keep its ordinals deterministic.
        .net_connection => try runOk(
            &runtime,
            "oom-net-connection.ecl",
            "{'address \"127.0.0.1\" 'port 0} net.listen 'l set " ++
                "[] (l net.accept) @spawn 'waiting set 0 clock.sleep l net.close " ++
                "waiting await pop [] (l net.accept) @attempt pop",
        ),
        // Every ordinal is deterministic: two binds, one closed, then a give
        // whose second port refuses after the first is already prepared, so
        // the rollback path runs, and finally a give that commits and whose
        // child scope closes what it was given.
        .net_give => try runOk(
            &runtime,
            "oom-give.ecl",
            "{'address \"127.0.0.1\" 'port 0} net.listen 'a set " ++
                "{'address \"127.0.0.1\" 'port 0} net.listen 'b set b net.close " ++
                "[] (a b 2 pack [] (pop pop) @give) @attempt pop " ++
                "[] (a a 2 pack [] (pop pop) @give) @attempt pop " ++
                "a wrap [] (pop) @give await pop",
        ),
        .time => try runOk(
            &runtime,
            "oom-time.ecl",
            "\"2024-02-29T12:34:56.789+05:30\" time.parse dup time.format pop " ++
                "dup time.to-utc time.from-utc pop dup 5 time.add time.diff pop " ++
                "0 time.from-unix 1 time.from-unix time.cmp pop 3 time.seconds pop " ++
                "[] (\"2024-02-30T00:00:00Z\" time.parse) @attempt pop",
        ),
        // The pure words once each, then a serving unit whose acceptor parks
        // with no peer and is cancelled at once, so every ordinal is
        // deterministic (a live exchange cannot be an allocation oracle).
        .http_server => try runOk(
            &runtime,
            "oom-http-server.ecl",
            "{'address \"127.0.0.1\" 'port 0} net.listen 'l set " ++
                "\"GET /a?b=1 HTTP/1.1\" http.server.parse-request-line pop " ++
                "(\"Host: x\") http.server.parse-headers dup http.server.content-length pop pop " ++
                "200 \"ok\" http.response.text dup \"content-type\" http.response.header pop " ++
                "http.server.render-response pop " ++
                "\"GET\" \"/a?b=1\" http.request.new dup http.request.query pop \"x\" \"y\" http.request.with-header pop " ++
                "[] (l {'max-in-flight 1} (pop http.response.not-found) http.server.@serve) @spawn " ++
                "0 clock.sleep dup cancel await pop l net.close",
        ),
        .http => try runOk(
            &runtime,
            "oom-http.ecl",
            "[] (\"http://127.0.0.1:1/x\" {} http.get) @attempt pop " ++
                "[] (\"http://127.0.0.1:1/x\" {} http.get-bytes) @attempt pop",
        ),
        .process => {
            // A successful live capture has scheduling-dependent readiness
            // cardinality and therefore cannot be an oracle for allocation
            // ordinals. Exercise controller construction and scope teardown
            // with one allowed spawn, then drive every run-only parser and
            // launch allocation deterministically up to policy rejection.
            const process_source = try std.fmt.allocPrint(
                scaffold_allocator,
                "'proc ('spawn 'run) import " ++
                    "{{'executable \"{s}\" 'args (\"block\")}} spawn pop " ++
                    "{{'executable \"/definitely/not/allowed\" " ++
                    "'args (\"one\" \"two\") 'cwd \"/\" " ++
                    "'env {{\"ECL_OOM_PROCESS\" \"probe\"}} 'stdin [0 1 255 2] " ++
                    "'stdout-limit 8 'stderr-limit 8 'timeout-ms 1}} run",
                .{process_path},
            );
            defer scaffold_allocator.free(process_source);
            try runExpectedLanguageError(&runtime, "oom-process.ecl", process_source);
        },
        .package_sync_module => try runOk(
            &runtime,
            "oom-pkg-sync-module.ecl",
            "'pkg.sync ('run) import",
        ),
        .package_sync => try runOk(&runtime, "oom-pkg-sync.ecl", package_sync_source),
        .package_cli_module => try runOk(
            &runtime,
            "oom-pkg-cli-module.ecl",
            "'pkg.cli ('tree) import",
        ),
        .package_cli => try runOk(&runtime, "oom-pkg-cli.ecl", package_cli_source),
    }
    return first_failure_index;
}

fn SurfaceProbe(comptime surface: StdlibSurface) type {
    return struct {
        fn run(
            failing: *std.testing.FailingAllocator,
            failure_offset: ?usize,
        ) !usize {
            return stdlibSessionAllocationProbe(surface, failing, failure_offset);
        }
    };
}

fn testSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var diagnostics_buffer: [1024]u8 = undefined;
    var diagnostics = std.Io.Writer.fixed(&diagnostics_buffer);
    var runtime = try session.Session.initTestWithHostConfig(
        thread_safe_allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output,
            .diagnostics = &diagnostics,
            .standard_input = .program_source,
        },
        .cooperative,
    );
    defer runtime.deinit();
    try runOk(
        &runtime,
        "oom-tests.ecl",
        "[] ((1) 'one test) 'oom.tests @defm tests first @test pop",
    );
}

const structured_find_source = "[[1]] [1] find pop";

fn structuredFindAllocationCount() !usize {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try session.Session.initWithConfig(
        failing.allocator(),
        &.{},
        .cooperative,
    );
    defer runtime.deinit();

    const before = failing.alloc_index;
    try std.testing.expectEqual(
        .ok,
        try runtime.runUnit("oom-structured-find-count.ecl", structured_find_source),
    );
    return failing.alloc_index - before;
}

test "oom: core: recognized structured find propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    const allocation_count = try structuredFindAllocationCount();
    try std.testing.expect(allocation_count != 0);

    // Bootstrap outside the failure window, then exhaust the smallest public
    // operation that reaches the recognized driver's structural match cursor.
    for (0..allocation_count) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var runtime = try session.Session.initWithConfig(
            failing.allocator(),
            &.{},
            .cooperative,
        );
        defer runtime.deinit();

        failing.fail_index = failing.alloc_index + offset;
        const result = runtime.runUnit("oom-structured-find-failure.ecl", structured_find_source);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectError(error.OutOfMemory, result);
    }
}

test "oom: core: full-session surfaces propagate every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        fullSessionAllocationProbe,
    );
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        testSessionAllocationProbe,
    );
}

const admitted_construction_source = "[] () 'oom-driver @defm";

fn admittedConstructionAllocationCount() !usize {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try session.Session.initWithConfig(
        failing.allocator(),
        &.{},
        .cooperative,
    );
    defer runtime.deinit();

    const before = failing.alloc_index;
    try std.testing.expectEqual(
        .ok,
        try runtime.runUnit("oom-driver-count.ecl", admitted_construction_source),
    );
    return failing.alloc_index - before;
}

test "oom: core: admitted construction driver allocation failure transfers its cursor once" {
    try requireSelectedOomTest(@src());
    const allocation_count = try admittedConstructionAllocationCount();
    try std.testing.expect(allocation_count != 0);

    // Bootstrap outside the failure window, then exhaust every allocation in
    // the smallest public operation that admits reader text and installs a
    // ConstructionDriver. In particular, failure of the driver's own pending
    // allocation must destroy its re-scope cursor once, without leaving a
    // second local owner to destroy the same source header again.
    for (0..allocation_count) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var runtime = try session.Session.initWithConfig(
            failing.allocator(),
            &.{},
            .cooperative,
        );
        defer runtime.deinit();

        failing.fail_index = failing.alloc_index + offset;
        const result = runtime.runUnit("oom-driver-failure.ecl", admitted_construction_source);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectError(error.OutOfMemory, result);
    }
}

const batch_import_setup = "[] (1 'a set 2 'b set) 'oom-import @defm";
const batch_import_source = "'oom-import ('a 'b) import";

fn batchImportAllocationCount() !usize {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try session.Session.initWithConfig(
        failing.allocator(),
        &.{},
        .cooperative,
    );
    defer runtime.deinit();
    try runOk(&runtime, "oom-import-setup.ecl", batch_import_setup);

    const before = failing.alloc_index;
    try runOk(&runtime, "oom-import-count.ecl", batch_import_source);
    return failing.alloc_index - before;
}

test "oom: core: batch import propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    const allocation_count = try batchImportAllocationCount();
    try std.testing.expect(allocation_count != 0);

    for (0..allocation_count) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var runtime = try session.Session.initWithConfig(
            failing.allocator(),
            &.{},
            .cooperative,
        );
        defer runtime.deinit();
        try runOk(&runtime, "oom-import-setup.ecl", batch_import_setup);

        failing.fail_index = failing.alloc_index + offset;
        const result = runtime.runUnit("oom-import-failure.ecl", batch_import_source);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectError(error.OutOfMemory, result);
    }
}

test "oom: standard-library and host: host: project initialization propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        projectSessionInitializationProbe,
    );
}

fn checkStdlibSurface(comptime surface: StdlibSurface) !void {
    try checkAllPostInitAllocationFailuresParallel(
        std.heap.smp_allocator,
        SurfaceProbe(surface).run,
    );
}

fn checkStdlibSurfaceOrdinalShard(
    comptime surface: StdlibSurface,
    comptime ordinal_shard_index: usize,
    comptime ordinal_shard_count: usize,
) !void {
    try checkPostInitAllocationFailureOrdinalShard(
        std.heap.smp_allocator,
        SurfaceProbe(surface).run,
        ordinal_shard_index,
        ordinal_shard_count,
    );
}

test "oom: standard-library and host: package: locked project module propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.locked_project_module);
}

test "oom: standard-library and host: stdlib: clock propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.clock);
}

test "oom: standard-library and host: stdlib: @give propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.net_give);
}

test "oom: standard-library and host: stdlib: time propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.time);
}

test "oom: standard-library and host: stdlib: random propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.random);
}

test "oom: standard-library and host: stdlib: dict propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.dict);
}

test "oom: standard-library and host: stdlib: error values propagate every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.error_value);
}

test "oom: standard-library and host: stdlib: result propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.result);
}

test "oom: standard-library and host: stdlib: string propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.string);
}

test "oom: standard-library and host: stdlib: CSV propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.csv);
}

test "oom: standard-library and host: stdlib: JSON propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.json);
}

test "oom: standard-library and host: stdlib: table propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.table);
}

test "oom: standard-library and host: stdlib: archive hash propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.archive_hash);
}

test "oom: standard-library and host: stdlib: archive unpack propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.archive_unpack);
}

test "oom: standard-library and host: package: store propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.package_store);
}

test "oom: standard-library and host: package: store GC propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.package_store_gc);
}

test "oom: standard-library and host: host: IO propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.host_io);
}

test "oom: standard-library and host: host: filesystem propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.filesystem);
}

test "oom: standard-library and host: host: network listeners propagate every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.net);
}

test "oom: standard-library and host: host: network connections propagate every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.net_connection);
}

test "oom: standard-library and host: host: HTTP propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.http);
}

test "oom: standard-library and host: stdlib: http server propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.http_server);
}

test "oom: standard-library and host: package: sync module propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.package_sync_module);
}

test "oom: standard-library and host: sync: operation ordinal shard 1 of 4" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurfaceOrdinalShard(.package_sync, 0, 4);
}

test "oom: standard-library and host: sync: operation ordinal shard 2 of 4" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurfaceOrdinalShard(.package_sync, 1, 4);
}

test "oom: standard-library and host: sync: operation ordinal shard 3 of 4" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurfaceOrdinalShard(.package_sync, 2, 4);
}

test "oom: standard-library and host: sync: operation ordinal shard 4 of 4" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurfaceOrdinalShard(.package_sync, 3, 4);
}

test "oom: standard-library and host: package: CLI module propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.package_cli_module);
}

test "oom: standard-library and host: package: CLI operation propagates every allocation failure" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.package_cli);
}
test "oom: standard-library and host: process port lifecycle" {
    try requireSelectedOomTest(@src());
    try checkStdlibSurface(.process);
}
