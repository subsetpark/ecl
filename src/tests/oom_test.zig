//! Slow, exhaustive allocation-failure coverage across initialized sessions.
//!
//! Two coarse probes keep the established core and the M12 data/host surfaces
//! separate. Each still shares one embedded-prelude bootstrap across all of
//! its related paths instead of bootstrapping once per word.
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
//! errors, or the sweep silently stops testing what follows.
const std = @import("std");
const session = @import("../session.zig");
const native_fixture = @import("native_fixture_options");
const archive_fixtures = @import("archive_fixture_options");

fn archiveSource(allocator: std.mem.Allocator, destination: []const u8) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeByte('[');
    var high: ?u8 = null;
    var index: usize = 0;
    for (archive_fixtures.valid) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        const nibble = try std.fmt.charToDigit(byte, 16);
        if (high) |first| {
            if (index != 0) try source.writer.writeByte(' ');
            try source.writer.print("{d}", .{first << 4 | nibble});
            high = null;
            index += 1;
        } else high = nibble;
    }
    if (high != null) return error.InvalidFixture;
    try source.writer.writeAll("] \"");
    for (destination) |byte| {
        if (byte == '\\' or byte == '"') try source.writer.writeByte('\\');
        try source.writer.writeByte(byte);
    }
    try source.writer.writeAll("\" archive.unpack-tgz pop");
    return allocator.dupe(u8, source.written());
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
        "{'a 1} 'b 2 put keys pop [\"a\" \"b\"] \"—\" join \"—\" split pop " ++
            "['a 'b] [1 2] to-dict keys pop ['c 3] dict-of keys pop " ++
            "[1 2 3] 1 9 put pop \"ab\" reverse 0 \\λ put pop " ++
            "['a 1] str [1] \"{}\" format pop [\"raw\"] \"{}\" format pop",
    );
    try runOk(
        &runtime,
        "oom-primitives.ecl",
        "(3 4 +) 'sum def sum pop (1 0 /) @attempt pop (5 6 +) @attempt pop " ++
            "({'kind 'custom 'data {'detail 7}} raise) @attempt pop " ++
            "[3 4] (+) with call pop [5 6] (+) with @attempt pop " ++
            "[7 8] (+) with @spawn await pop " ++
            "[9 10] (+ 'x set) with 'oom-seeded @defm oom-seeded.x pop",
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
            "'reflection-module.f 'f import 'reflection-module.f body pop words " ++
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
            "[11 12 13] (1 +) with 'oom-stateful @defm " ++
            "[21 22] (2 +) with 'oom-stateful @defm " ++
            // Transactional updates allocate on the draft, the replacement
            // snapshot, and the caller window; the failing half must leave
            // the durable stack and the caller stack untouched.
            "[0] (((1 + dup without) within) 'bump def " ++
            "((dup without missing) within) 'boom def " ++
            "((dup without) within) 'peek def) with 'oom-within @defm " ++
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
            "[1 2] (((dup without) within) 'peek def) with 'oom-removed @defm " ++
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
        .err => |failure| {
            runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
}

fn stdlibSessionAllocationProbe(allocator: std.mem.Allocator) !void {
    var locked_allocator = LockedAllocator{ .child = allocator };
    const thread_safe_allocator = locked_allocator.allocator();
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
            .environ = &.{.{ .name = "ECL_OOM_PROBE", .value = "probe" }},
            .standard_input = .program_source,
        },
        .cooperative,
    );
    defer runtime.deinit();

    // M12's embedded modules and host effects form a second coarse Session
    // bundle. checkAllAllocationFailures is quadratic in one probe's total
    // allocation count; keeping these paths in the older core bundle creates
    // an enormous cross-product between unrelated ordinals. Two bundles still
    // share one bootstrap across every related surface rather than starting a
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
        "[1 2] result.ok (+) result.and-then result.or-raise pop " ++
            "\"  hi  \" str.trim str.upper pop " ++
            "\"a,b\\nc,d\" csv.parse dup csv.emit pop pop " ++
            "\"{\\\"a\\\":[1,null]}\" json.parse json.emit pop " ++
            "{\"r\" [\"e\" \"w\"] \"v\" [1 2]} " ++
            "[\"r\"] [[\"t\" \"v\" (sum)]] table.aggregate pop " ++
            "{\"id\" [1 2]} {\"cid\" [2] \"n\" [9]} [[\"id\" \"cid\"]] " ++
            "{\"n\" 0} table.left-join-with pop " ++
            "[97] archive.sha256 pop " ++
            "{'format 1 'name \"r\" 'version \"0.1.0\" 'requires " ++
            "{\"a\" {'version \"1.0.0\" 'url \"https://e.com/a.tgz\" " ++
            "'hash \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}} " ++
            "{\"a\" {\"1.0.0\" {'format 1 'name \"a\" 'version \"1.0.0\" 'requires {}}}} " ++
            "pkg.mvs.resolve pop",
    );

    // The host scripting words allocate on the read buffer, the decoded
    // path, the materialized string, and the environ snapshot lookup; only
    // this sweep injects failure at each of those ordinals.
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const scratch_path = try scratch.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        thread_safe_allocator,
    );
    defer thread_safe_allocator.free(scratch_path);
    const archive_destination = try std.fmt.allocPrint(
        thread_safe_allocator,
        "{s}{c}archive",
        .{ scratch_path, std.fs.path.sep },
    );
    defer thread_safe_allocator.free(archive_destination);
    const archive_source = try archiveSource(thread_safe_allocator, archive_destination);
    defer thread_safe_allocator.free(archive_source);
    try runOk(&runtime, "oom-archive.ecl", archive_source);
    const host_io_source = try std.fmt.allocPrint(
        thread_safe_allocator,
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
    defer thread_safe_allocator.free(host_io_source);
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

test "oom: full-session surfaces propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.heap.smp_allocator,
        fullSessionAllocationProbe,
        .{},
    );
}

test "oom: standard-library and host surfaces propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.heap.smp_allocator,
        stdlibSessionAllocationProbe,
        .{},
    );
}
