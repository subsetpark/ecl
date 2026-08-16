const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const minish = b.dependency("minish", .{}).module("minish");

    const mod = b.addModule("ecl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_options = b.addOptions();
    runtime_options.addOption(usize, "default_worker_count", 1);
    mod.addOptions("session_options", runtime_options);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ecl", mod);
    const exe = b.addExecutable(.{
        .name = "ecl",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const repl_tests = b.addSystemCommand(&.{"expect"});
    repl_tests.addFileArg(b.path("test/repl.exp"));
    repl_tests.addArtifactArg(exe);
    const repl_step = b.step("test-repl", "Run the real REPL under a PTY");
    repl_step.dependOn(&repl_tests.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_options = b.addOptions();
    test_options.addOption(usize, "default_worker_count", 1);
    test_mod.addOptions("session_options", test_options);
    test_mod.addImport("minish", minish);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the ecl test suite");
    test_step.dependOn(&run_tests.step);

    const fuzz_targets = [_]struct {
        step_name: []const u8,
        test_name: []const u8,
        description: []const u8,
    }{
        .{
            .step_name = "fuzz-reader",
            .test_name = "fuzz: reader accepts arbitrary bounded input",
            .description = "Fuzz bounded reader input",
        },
        .{
            .step_name = "fuzz-formatter",
            .test_name = "fuzz: formatter is idempotent for every accepted source",
            .description = "Fuzz formatter acceptance and idempotence",
        },
        .{
            .step_name = "fuzz-editor",
            .test_name = "fuzz: editor action traces preserve scalar boundaries and ownership",
            .description = "Fuzz editor actions and owned-line transitions",
        },
        .{
            .step_name = "fuzz-completion",
            .test_name = "fuzz: completion survives prefixes definitions aliases and reloads",
            .description = "Fuzz completion across live mutation and reloads",
        },
        .{
            .step_name = "fuzz-history",
            .test_name = "fuzz: history parsing merging and corruption preservation",
            .description = "Fuzz history parsing, merging, and corruption handling",
        },
        .{
            .step_name = "fuzz-pending",
            .test_name = "fuzz: pending unit accumulates lines and lexical state",
            .description = "Fuzz pending-unit accumulation and incremental lexical state",
        },
        .{
            .step_name = "fuzz-scheduler",
            .test_name = "fuzz: real scheduler publication cancellation and join traces settle",
            .description = "Fuzz production scheduler publication and cancellation traces",
        },
    };
    const fuzz_step = b.step(
        "fuzz",
        "Run every fuzz seed corpus; use the named fuzz-* steps for bounded campaigns",
    );
    var fuzz_campaign_steps: [fuzz_targets.len]*std.Build.Step = undefined;
    for (fuzz_targets, 0..) |fuzz_target, index| {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            // Zig 0.16.0's bundled fuzz runner passes builtin.StackTrace to
            // std.debug.writeStackTrace when error-return tracing is enabled.
            // Disable only that runner path until the upstream mismatch is fixed;
            // panics and sanitizer crashes still retain their diagnostics.
            .error_tracing = false,
        });
        fuzz_mod.addOptions("session_options", test_options);
        fuzz_mod.addImport("minish", minish);
        const fuzz_tests = b.addTest(.{
            .root_module = fuzz_mod,
            .filters = &.{fuzz_target.test_name},
        });
        const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
        fuzz_step.dependOn(&run_fuzz_tests.step);
        const campaign_step = b.step(fuzz_target.step_name, fuzz_target.description);
        campaign_step.dependOn(&run_fuzz_tests.step);
        fuzz_campaign_steps[index] = campaign_step;
    }

    const oom_mod = b.createModule(.{
        .root_source_file = b.path("src/oom_root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    oom_mod.addOptions("session_options", test_options);
    const oom_tests = b.addTest(.{
        .root_module = oom_mod,
        .filters = &.{"oom:"},
    });
    const run_oom_tests = b.addRunArtifact(oom_tests);
    const oom_step = b.step(
        "test-oom",
        "Exhaust full-session allocation failures (ReleaseSafe)",
    );
    oom_step.dependOn(&run_oom_tests.step);

    const audit_mod = b.createModule(.{
        .root_source_file = b.path("src/source_audit.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const audit_exe = b.addExecutable(.{ .name = "ecl-source-audit", .root_module = audit_mod });
    const run_audit = b.addRunArtifact(audit_exe);
    const audit_step = b.step("source-audit", "Check source architecture and line budgets");
    audit_step.dependOn(&run_audit.step);
    fuzz_step.dependOn(&run_audit.step);
    for (fuzz_campaign_steps) |campaign_step| campaign_step.dependOn(&run_audit.step);
    repl_step.dependOn(&run_audit.step);
    test_step.dependOn(&run_audit.step);
    oom_step.dependOn(&run_audit.step);

    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("ecl_exe", exe.getEmittedBin());
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addOptions("build_options", e2e_options);
    e2e_mod.addImport("minish", minish);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    test_step.dependOn(&run_e2e_tests.step);

    const worker_step = b.step("test-workers", "Run the full suite with one and eight workers");
    for ([_][]const u8{ "1", "8" }) |workers| {
        const worker_count: usize = if (std.mem.eql(u8, workers, "1")) 1 else 8;
        const worker_test_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const worker_options = b.addOptions();
        worker_options.addOption(usize, "default_worker_count", worker_count);
        worker_test_mod.addOptions("session_options", worker_options);
        worker_test_mod.addImport("minish", minish);
        const worker_tests = b.addTest(.{ .root_module = worker_test_mod });
        const run_worker_tests = b.addRunArtifact(worker_tests);
        worker_step.dependOn(&run_worker_tests.step);
        const run_worker_e2e = b.addRunArtifact(e2e_tests);
        run_worker_e2e.setEnvironmentVariable("ECL_WORKERS", workers);
        worker_step.dependOn(&run_worker_e2e.step);
    }

    // Keep TSan focused on genuinely threaded behavior. The ordinary suite owns
    // exhaustive property and allocator-failure coverage; instrumenting those
    // single-threaded cases turns this race detector into a multi-minute stress
    // test without increasing its race coverage.
    const tsan_supported = target.result.os.tag == .linux or target.result.os.tag == .macos;
    const tsan_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan_supported,
    });
    tsan_mod.addOptions("session_options", test_options);
    tsan_mod.addImport("minish", minish);
    const tsan_tests = b.addTest(.{
        .root_module = tsan_mod,
        .filters = &.{
            "concurrency:",
            "reference counting remains exact across threads",
            "concurrent interning publishes stable lock-free reads",
            "env: concurrent cell publication is lease-safe and TSan-clean",
            "env: concurrent readers writers and retirement reclaim production snapshots",
            "registry: concurrent commits are linearized without lost names",
        },
    });
    const run_tsan_tests = b.addRunArtifact(tsan_tests);
    const tsan_step = b.step("test-tsan", "Run tests under ThreadSanitizer");
    tsan_step.dependOn(&run_tsan_tests.step);

    const differential_mod = b.createModule(.{
        .root_source_file = b.path("test/idiom_differential.zig"),
        .target = target,
        .optimize = optimize,
    });
    differential_mod.addImport("ecl", mod);
    const differential_tests = b.addTest(.{ .root_module = differential_mod });
    const run_differential = b.addRunArtifact(differential_tests);
    const differential_step = b.step("differential", "Compare automatic and generic idiom execution");
    differential_step.dependOn(&run_differential.step);

    const oracle_step = b.step(
        "oracle-differential",
        "Compare shared semantics with the frozen Rust PoC",
    );
    if (b.option([]const u8, "oracle-exe", "Path to the frozen Rust ecl executable")) |rust_exe| {
        const oracle_options = b.addOptions();
        oracle_options.addOptionPath("zig_exe", exe.getEmittedBin());
        oracle_options.addOption([]const u8, "rust_exe", rust_exe);
        const oracle_mod = b.createModule(.{
            .root_source_file = b.path("test/oracle_differential.zig"),
            .target = target,
            .optimize = optimize,
        });
        oracle_mod.addOptions("oracle_options", oracle_options);
        const oracle_tests = b.addTest(.{ .root_module = oracle_mod });
        const run_oracle_tests = b.addRunArtifact(oracle_tests);
        oracle_step.dependOn(&run_oracle_tests.step);
    } else {
        const missing_oracle = b.addFail(
            "oracle-differential requires -Doracle-exe=path/to/poc/rust/ecl",
        );
        oracle_step.dependOn(&missing_oracle.step);
    }
}
