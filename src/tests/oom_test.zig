//! Slow, exhaustive allocation-failure coverage across initialized sessions.
//!
//! Four coarse probes keep the established core, general standard-library and
//! host surfaces, package synchronization, and package CLI separate. Each
//! still shares one embedded-prelude bootstrap across related paths instead
//! of bootstrapping once per word.
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
//! Keep additions short and reaching, not exhaustive — one line through a
//! path is coverage; a hundred lines through it is the same coverage, slower.
//! Snippets must leave the stack clean (`pop` what they push) and propagate
//! errors, or the sweep silently stops testing what follows. Each coarse probe
//! partitions those ordinals between two workers, preserving exhaustive
//! failure injection while bounding release-candidate wall time on four-core
//! runners.
const std = @import("std");
const session = @import("../session.zig");
const native_fixture = @import("native_fixture_options");
const archive_fixtures = @import("archive_fixture_options");

fn archiveSource(allocator: std.mem.Allocator, destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.valid);
    try source.writer.writeByte(' ');
    try appendQuoted(&source.writer, destination);
    try source.writer.writeAll(" archive.unpack-tgz pop");
    return allocator.dupe(u8, source.written());
}

fn packageStoreSource(
    allocator: std.mem.Allocator,
    destination: []const u8,
    lock_path: []const u8,
    manifest_path: []const u8,
) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" pkg.store.inspect pop ");
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" ");
    try appendQuoted(&source.writer, destination);
    try source.writer.writeAll(" pkg.store.install pop \"lock\\n\" ");
    try appendQuoted(&source.writer, lock_path);
    try source.writer.writeAll(" pkg.store.write-lock ");
    try source.writer.writeAll("\"manifest\\n\" ");
    try appendQuoted(&source.writer, manifest_path);
    try source.writer.writeAll(" pkg.store.write-new ");
    try appendQuoted(&source.writer, destination);
    try source.writer.writeAll(" pkg.store.present? pop ");
    try appendQuoted(&source.writer, destination);
    try source.writer.writeAll(
        " \"a\" \"sha256-587725eba4f45cf49f6b8b8bc597f830b259d12181e251dcbf2ba581105293e9\" pkg.store.verify ",
    );
    try appendQuoted(&source.writer, destination);
    try source.writer.writeAll(
        " \"a\" \"sha256-587725eba4f45cf49f6b8b8bc597f830b259d12181e251dcbf2ba581105293e9\" pkg.store.read-seal pop",
    );
    return allocator.dupe(u8, source.written());
}

fn packageInstallSource(allocator: std.mem.Allocator, destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try appendFixtureBytes(&source.writer, archive_fixtures.package_valid);
    try source.writer.writeAll(" \"a\" ");
    try appendQuoted(&source.writer, destination);
    try source.writer.writeAll(" pkg.store.install pop");
    return allocator.dupe(u8, source.written());
}

fn packageSyncSource(allocator: std.mem.Allocator, project: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeAll(
        "{'format 1 'name \"r\" 'version \"0.1.0\" 'requires " ++
            "{\"a\" {'version \"1.0.0\" 'url \"https://e.com/a.tgz\" " ++
            "'hash \"sha256-587725eba4f45cf49f6b8b8bc597f830b259d12181e251dcbf2ba581105293e9\"}}} ",
    );
    try appendQuoted(&source.writer, project);
    try source.writer.writeAll(" pkg.sync.run pop");
    return allocator.dupe(u8, source.written());
}

fn packageCliSource(allocator: std.mem.Allocator, project: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeByte('[');
    try appendQuoted(&source.writer, project);
    try source.writer.writeAll("] pkg.cli.tree");
    return allocator.dupe(u8, source.written());
}

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
            .data = "{'format 1 'name \"root\" 'version \"0.1.0\" 'requires {}}\n",
        });
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "ecl.lock",
            .data = "{'format 1 'root \"root\" 'packages {\"lockprobe\" {'version \"1.0.0\" 'url \"https://e.com/p.tgz\" 'hash \"sha256-" ++ lock_probe_hash ++ "\"}} 'requires {\"root\" {\"lockprobe\" \"1.0.0\"}}}\n",
        });
        try directory.dir.createDir(
            std.testing.io,
            "lockprobe-1.0.0-" ++ lock_probe_hash,
            .default_dir,
        );
        try directory.dir.writeFile(std.testing.io, .{
            .sub_path = "lockprobe-1.0.0-" ++ lock_probe_hash ++ "/lockprobe.ecl",
            .data = "((42) 'answer def) 'lockprobe @defm\n",
        });
        return .{ .directory = directory, .path = path };
    }

    fn deinit(self: *PackageScratch) void {
        std.testing.allocator.free(self.path);
        self.directory.cleanup();
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

const allocation_failure_shard_count = 2;

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
            "[1 2] reverse pop [1 2] [0 1] at pop [3 1] 2 4 rand-ints pop pop " ++
            // Scalar and flat-list needles reach both typed membership drivers.
            "1 [1 2] in? pop [1 3] [1 2] in? pop [1 2] dup 0 9 put pop pop " ++
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
            "['a 1] str [1] \"{}\" format pop [\"raw\"] \"{}\" format pop",
    );
    try runOk(
        &runtime,
        "oom-primitives.ecl",
        "(3 4 +) 'oom-sum def oom-sum pop " ++
            "1 'oom-unset set 'oom-unset unset 2 'oom-unset set 'oom-unset undef " ++
            "(1 0 /) @attempt pop (5 6 +) @attempt pop " ++
            "({'kind 'custom 'data {'detail 7}} raise) @attempt pop " ++
            "[3 4] (+) with call pop [5 6] (+) seed @attempt pop " ++
            "[7 8] (+) seed @spawn await pop " ++
            "[1] (2) seed unseed seed @attempt pop " ++
            // This admitted reader body reaches ConstructionDriver allocation
            // after the re-scope cursor owns its source. Exhausting that exact
            // allocation proves cleanup remains with only one movable owner.
            "[9 10] (+ 'x set) seed 'oom-seeded @defm oom-seeded.x pop",
    );
    try runOk(
        &runtime,
        "oom-session.ecl",
        "args pop \"42 missing\" parse pop \"1\" parse-int pop \"1\" parse-float pop",
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
        "([1 2 3] str) @spawn await pop " ++
            "(1) @spawn dup pair await-any pop pop " ++
            "(1) @spawn dup await pop 0 await-for pop " ++
            "(1) @spawn 1000000 await-for pop " ++
            "((1) () while) @spawn dup cancel await pop " ++
            "[(1) (missing) (2 3)] (@spawn) each await-all pop " ++
            "[1 2 3] (dup *) @each pop",
    );
    try runOk(
        &runtime,
        "oom-reflection.ecl",
        "(( -- n ) (1) 'f def) 'reflection-module @defm " ++
            "'reflection-module.f 'f import words " ++
            "'f which 'reflection-module.f see",
    );
    try runOk(&runtime, "oom-loader.ecl", "'stats.answer 'answer import answer pop");
    try runOk(
        &runtime,
        "oom-native.ecl",
        "'sample.increment 'increment import 41 sample.increment pop 7 sample.singleton pop " ++
            "7 'sample 'increment qualify execute pop " ++
            "[1 2] sample.sum-list pop {'a 1 'b 2} sample.sum-dict pop " ++
            "'answer 42 sample.pair-dict pop sample.builder-budget pop " ++
            "sample.cooperative pop (9 sample.draft-fail) @attempt pop " ++
            "(9 sample.yield-forever) @spawn dup cancel await pop",
    );
    try runOk(
        &runtime,
        "oom-module.ecl",
        "(1 'x setp ( -- n ) (x) 'get def) 'allocation-module @defm " ++
            "'allocation-module.get 'get import get pop 'short 'allocation-module alias short.get pop " ++
            "(2 'x setp ( -- n ) (x) 'get def) 'allocation-module @defm get pop " ++
            "(((dup) 'f def) 'bad @defm) @attempt pop " ++
            // A non-empty construction stack is captured as durable slot
            // state, so capture, commit, and re-registration discard each
            // have an allocation-failure path of their own.
            "[11 12 13] (1 +) seed 'oom-stateful @defm " ++
            "[21 22] (2 +) seed 'oom-stateful @defm " ++
            // Transactional updates allocate on the draft, the replacement
            // snapshot, and the caller window; the failing half must leave
            // the durable stack and the caller stack untouched.
            "[0] (((1 + dup without) within) 'bump def " ++
            "((dup without missing) within) 'boom def " ++
            "((dup without) within) 'peek def) seed 'oom-within @defm " ++
            "oom-within.bump pop (oom-within.boom) @attempt pop " ++
            // The failing half must publish nothing, so the durable stack
            // still holds exactly what the successful half left.
            "oom-within.peek 1 match? pop " ++
            // Namespaced registration plus branded qualification and ordinary
            // late-bound execution each have Session-only allocation paths.
            "((33) 'dynamic def) 'oom.namespaced @defm " ++
            "'oom.namespaced 'dynamic qualify execute pop " ++
            "3 (dup) first execute pop pop " ++
            // Removal closes, quiesces, and retires through the same bounded
            // work, so its allocation-failure paths belong in the sweep too.
            "[1 2] (((dup without) within) 'peek def) seed 'oom-removed @defm " ++
            "oom-removed.peek pop 'oom-removed unmodule",
    );
    try runOk(
        &runtime,
        "oom-module-value.ecl",
        // The value wrapper, the registration record, the copied state
        // template, and the barrier publication each have their own ordinals.
        // One construction registered twice and one reload reach all four.
        "(1) @module dup 'oom-left register 'oom-right register " ++
            "(2) @module 'oom-left register (3) @module pop",
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

fn stdlibSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var scratch = try PackageScratch.init();
    defer scratch.deinit();
    // Paths and source strings are borrowed test scaffolding, not values the
    // Session owns. Keep their construction outside the injected allocator so
    // the sweep enumerates live Session paths rather than this helper's writer.
    const scaffold_allocator = std.testing.allocator;
    const scratch_path = scratch.path;
    var output_buffer: [16384]u8 = undefined;
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
            .project_start = scratch_path,
            .environ = &.{
                .{ .name = "ECL_OOM_PROBE", .value = "probe" },
                .{ .name = "ECL_CACHE", .value = scratch_path },
            },
            .standard_input = .program_source,
        },
        .cooperative,
    );
    defer runtime.deinit();

    // The smallest locked program reaches one-time project discovery,
    // independent format-1 validation, bounded prefix lookup, candidate
    // materialization, and ordinary source publication.
    try runOk(&runtime, "oom-lock-tier.ecl", "lockprobe.answer pop");

    // M12's general embedded modules and host effects form one coarse Session
    // bundle. Package synchronization and CLI have independent probes below:
    // their allocation counts dominate this gate, and combining them creates
    // a quadratic cross-product between unrelated ordinals. Each bundle still
    // shares one bootstrap across related surfaces rather than starting a
    // Session per word.
    // `rng` reaches the vector-draw driver, which builds its result across
    // resumptions, and the state list each primitive returns.
    try runOk(
        &runtime,
        "oom-random.ecl",
        "'rng.seed 'seed import 'rng.deal 'deal import 'rng.shuffle 'shuffle import " ++
            "'rng.ints 'ints import 'rng.float 'float import 42 seed 2 4 deal shuffle pop 2 6 ints pop float pop " ++
            "[7 0] 2 6 rand-ints nip pop",
    );
    // Each stdlib module has its own Session-reachable load path: embedded
    // source, a linked native descriptor, and a builtin word table. One short
    // call per module reaches the publication path and the module's own work.
    try runOk(
        &runtime,
        "oom-stdlib.ecl",
        "[['a 1] ['b 2]] dict.from-pairs dup dict.keys pop dup dict.vals pop " ++
            "dup 'a dict.has? pop dup {} dict.merge dup dict.pairs dict.from-pairs pop " ++
            "dup ['a 'b] dict.keys-exactly? pop dup 'a (1 +) dict.update " ++
            "dup 'c 0 (1 +) dict.update-or dup (nip) dict.map dup (1 +) dict.map-values " ++
            "dup (nip 1) dict.filter dup (nip 0) dict.reject dup ['a] dict.take " ++
            "dup ['a] dict.drop dup ['a] dict.split pop pop " ++
            "{'a 2} (|key left right| key pop left right +) dict.merge-with pop " ++
            "['a 'b] 0 dict.from-keys pop " ++
            "'io error.new \"read failed\" error.with-message {'path \"p\"} error.with-data " ++
            "dup error.valid? pop dup 'io error.kind? pop ['io 'timeout] error.kind-in? pop " ++
            "[1 2] result.ok (+) result.and-then result.or-raise pop " ++
            "\"  hi  \" str.trim str.upper pop " ++
            "\"a,b\\nc,d\" csv.parse dup csv.emit pop pop " ++
            "\"{\\\"a\\\":[1,null]}\" json.parse json.emit pop " ++
            "{\"r\" [\"e\" \"w\"] \"v\" [1 2]} " ++
            "[\"r\"] [[\"t\" \"v\" (sum)]] table.aggregate pop " ++
            "{\"id\" [1 2]} {\"cid\" [2] \"n\" [9]} [[\"id\" \"cid\"]] " ++
            "{\"n\" 0} table.left-join-with pop " ++
            "[97] archive.sha256 pop",
    );

    // The host scripting words allocate on the read buffer, the decoded
    // path, the materialized string, and the environ snapshot lookup; only
    // this sweep injects failure at each of those ordinals.
    const archive_destination = try std.fmt.allocPrint(
        scaffold_allocator,
        "{s}{c}archive",
        .{ scratch_path, std.fs.path.sep },
    );
    defer scaffold_allocator.free(archive_destination);
    const archive_source = try archiveSource(scaffold_allocator, archive_destination);
    defer scaffold_allocator.free(archive_source);
    try runOk(&runtime, "oom-archive.ecl", archive_source);
    const package_destination = try std.fmt.allocPrint(
        scaffold_allocator,
        "{s}{c}a-1.0.0-587725eba4f45cf49f6b8b8bc597f830b259d12181e251dcbf2ba581105293e9",
        .{ scratch_path, std.fs.path.sep },
    );
    defer scaffold_allocator.free(package_destination);
    const lock_path = try std.fmt.allocPrint(
        scaffold_allocator,
        "{s}{c}ecl.lock",
        .{ scratch_path, std.fs.path.sep },
    );
    defer scaffold_allocator.free(lock_path);
    // `pkg.store.write-new` refuses an existing destination, so its probe
    // needs a path this scaffolding has not already written. The scratch
    // directory's own `ecl.pkg` belongs to the lock-tier snippet above.
    const manifest_path = try std.fmt.allocPrint(
        scaffold_allocator,
        "{s}{c}created.pkg",
        .{ scratch_path, std.fs.path.sep },
    );
    defer scaffold_allocator.free(manifest_path);
    const package_source = try packageStoreSource(
        scaffold_allocator,
        package_destination,
        lock_path,
        manifest_path,
    );
    defer scaffold_allocator.free(package_source);
    try runOk(&runtime, "oom-pkg-store.ecl", package_source);
    try runOk(
        &runtime,
        "oom-pkg-gc.ecl",
        "[\"a-1.0.0-587725eba4f45cf49f6b8b8bc597f830b259d12181e251dcbf2ba581105293e9\"] pkg.store.gc pop",
    );
    const host_io_source = try std.fmt.allocPrint(
        scaffold_allocator,
        "1 \"probe\" io.debug pop " ++
            "\"probe\\ntext\" \"{s}{c}probe.txt\" io.spit " ++
            "\"{s}{c}probe.txt\" io.slurp pop " ++
            "\"{s}{c}probe.txt\" io.lines pop " ++
            "\"{s}{c}absent.txt\" (io.slurp) partial @attempt pop " ++
            "\"ECL_OOM_PROBE\" getenv pop " ++
            "(\"ECL_OOM_ABSENT\" getenv) @attempt pop (io.stdin) @attempt pop",
        .{
            scratch_path, std.fs.path.sep,
            scratch_path, std.fs.path.sep,
            scratch_path, std.fs.path.sep,
            scratch_path, std.fs.path.sep,
        },
    );
    defer scaffold_allocator.free(host_io_source);
    try runOk(&runtime, "oom-hostio.ecl", host_io_source);

    // The socket/client path has the largest fixed cost per allocation site;
    // keeping it last prevents it from being replayed for unrelated ordinals.
    try runOk(
        &runtime,
        "oom-http.ecl",
        "(\"http://127.0.0.1:1/x\" {} http.get) @attempt pop " ++
            "(\"http://127.0.0.1:1/x\" {} http.get-bytes) @attempt pop",
    );
}

fn packageSyncSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var scratch = try PackageScratch.init();
    defer scratch.deinit();
    const scaffold_allocator = std.testing.allocator;
    var output_buffer: [16384]u8 = undefined;
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
    defer runtime.deinit();

    // The installed one-package fixture keeps synchronization offline while
    // the injected run still crosses discovery, pkg.mvs.resolve, the selected
    // entry skip, canonical rendering, and atomic lock replacement.
    const package_destination = try std.fmt.allocPrint(
        scaffold_allocator,
        "{s}{c}a-1.0.0-587725eba4f45cf49f6b8b8bc597f830b259d12181e251dcbf2ba581105293e9",
        .{ scratch.path, std.fs.path.sep },
    );
    defer scaffold_allocator.free(package_destination);
    const install_source = try packageInstallSource(scaffold_allocator, package_destination);
    defer scaffold_allocator.free(install_source);
    try runOk(&runtime, "oom-pkg-sync-install.ecl", install_source);
    const sync_source = try packageSyncSource(scaffold_allocator, scratch.path);
    defer scaffold_allocator.free(sync_source);
    try runOk(&runtime, "oom-pkg-sync.ecl", sync_source);
}

fn packageCliSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
    var scratch = try PackageScratch.init();
    defer scratch.deinit();
    const scaffold_allocator = std.testing.allocator;
    var output_buffer: [16384]u8 = undefined;
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
    defer runtime.deinit();

    const cli_source = try packageCliSource(scaffold_allocator, scratch.path);
    defer scaffold_allocator.free(cli_source);
    try runOk(&runtime, "oom-pkg-cli.ecl", cli_source);
}

test "oom: full-session surfaces propagate every allocation failure" {
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        fullSessionAllocationProbe,
    );
}

const admitted_construction_source = "() 'oom-driver @defm";

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

test "oom: admitted construction driver allocation failure transfers its cursor once" {
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

test "oom: standard-library and host surfaces propagate every allocation failure" {
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        stdlibSessionAllocationProbe,
    );
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        packageSyncSessionAllocationProbe,
    );
    try checkAllAllocationFailuresParallel(
        std.heap.smp_allocator,
        packageCliSessionAllocationProbe,
    );
}
