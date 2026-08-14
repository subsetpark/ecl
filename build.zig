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

    // Zig 0.16's TSan runtime crashes at process startup on macOS (including
    // for an empty test binary). SourceHut runs this step on Linux, where the
    // instrumentation is enabled; other hosts still compile and run the same
    // concurrency suite through this named step.
    const tsan_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = target.result.os.tag == .linux,
    });
    tsan_mod.addOptions("session_options", test_options);
    tsan_mod.addImport("minish", minish);
    const tsan_tests = b.addTest(.{ .root_module = tsan_mod });
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
