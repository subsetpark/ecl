const std = @import("std");
const native_build = @import("src/native/build_helper.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime_linkage: ?std.builtin.LinkMode =
        if (target.result.os.tag == .linux) .dynamic else null;
    const minish = b.dependency("minish", .{}).module("minish");
    const ohsnap = b.dependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
        .module_name = @as([]const []const u8, &.{"root"}),
        .root_directory = @as([]const []const u8, &.{"test"}),
    }).module("ohsnap");
    const native_abi = b.createModule(.{
        .root_source_file = b.path("src/native/abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("ecl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;
    mod.addImport("native-abi", native_abi);
    const runtime_options = b.addOptions();
    runtime_options.addOption(usize, "default_worker_count", 1);
    runtime_options.addOption(bool, "instrument_root_execution", false);
    mod.addOptions("session_options", runtime_options);

    const native_sdk = b.addModule("ecl-native", .{
        .root_source_file = b.path("src/native/sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sdk.addImport("ecl-native-abi", native_abi);
    // First-party stdlib modules are authored against the public SDK and
    // linked into the shipped image, so the runtime module imports it too.
    mod.addImport("ecl-native", native_sdk);
    const native_sample = b.createModule(.{
        .root_source_file = b.path("test/native/sample.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sample.addImport("ecl-native", native_sdk);

    const fixture = native_build.addExtension(b, .{
        .name = "sample",
        .root_source_file = b.path("test/native/sample.zig"),
        .target = target,
        .optimize = optimize,
        .ecl_native = native_sdk,
    });
    fixture.root_module.link_libc = true;
    const fixture_install = native_build.installExtension(b, fixture, "native-fixture");
    const native_fixture_step = b.step("native-fixture", "Build the native SDK fixture artifacts");
    native_fixture_step.dependOn(fixture_install);
    const fixture_files = b.addWriteFiles();
    _ = fixture_files.addCopyFile(fixture.getEmittedBin(), "sample.eclmod");
    const native_fixture_options = b.addOptions();
    native_fixture_options.addOptionPath(
        "directory",
        fixture_files.getDirectory(),
    );
    const archive_fixture_options = b.addOptions();
    archive_fixture_options.addOption([]const u8, "empty", @embedFile("test/fixtures/archive/empty.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "valid", @embedFile("test/fixtures/archive/valid.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "pax", @embedFile("test/fixtures/archive/pax.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "gnu_long_name", @embedFile("test/fixtures/archive/gnu-long-name.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "absolute_path", @embedFile("test/fixtures/archive/absolute-path.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "parent_path", @embedFile("test/fixtures/archive/parent-path.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "symlink", @embedFile("test/fixtures/archive/symlink.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "hardlink", @embedFile("test/fixtures/archive/hardlink.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "char_device", @embedFile("test/fixtures/archive/char-device.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "block_device", @embedFile("test/fixtures/archive/block-device.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "fifo", @embedFile("test/fixtures/archive/fifo.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "duplicate", @embedFile("test/fixtures/archive/duplicate.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "oversized", @embedFile("test/fixtures/archive/oversized.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "malformed_tar", @embedFile("test/fixtures/archive/malformed-tar.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "malformed_pax", @embedFile("test/fixtures/archive/malformed-pax.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "malformed", @embedFile("test/fixtures/archive/malformed.tgz.hex"));
    archive_fixture_options.addOption([]const u8, "long_path", "pkg/" ++ ("s" ** 110) ++ ".ecl");
    archive_fixture_options.addOption([]const u8, "package_valid", @embedFile("test/fixtures/pkg/valid.tgz.hex"));

    const malformed_defects = [_][]const u8{
        "wrong-name",
        "abi-version",
        "descriptor-size",
        "duplicate-word",
        "missing-doc",
        "entry-failure",
        "entry-size",
        "invalid-effect",
        "unsupported-capability",
        "invalid-continuation",
        "unknown-entry-status",
        "stride-overread",
        "unknown-result",
        "result-size",
        "unknown-failure-kind",
        "unknown-scalar-kind",
        "scalar-size",
        "oversized-scalar",
        "invalid-utf8-scalar",
        "partial-complete",
        "undeclared-yield",
        "consume-without-state",
    };
    for (malformed_defects) |defect| {
        const malformed_options = b.addOptions();
        malformed_options.addOption([]const u8, "defect", defect);
        const malformed_module = b.createModule(.{
            .root_source_file = b.path("test/native/malformed.zig"),
            .target = target,
            .optimize = optimize,
        });
        malformed_module.addImport("native-abi", native_abi);
        malformed_module.addOptions("malformed_options", malformed_options);
        const malformed = b.addLibrary(.{
            .name = "sample",
            .root_module = malformed_module,
            .linkage = .dynamic,
        });
        const install = b.addInstallFileWithDir(
            malformed.getEmittedBin(),
            .{ .custom = b.fmt("native-fixture/{s}", .{defect}) },
            "sample.eclmod",
        );
        native_fixture_step.dependOn(&install.step);
        _ = fixture_files.addCopyFile(
            malformed.getEmittedBin(),
            b.fmt("{s}/sample.eclmod", .{defect}),
        );
    }

    const negative_cases = [_]struct { file: []const u8, message: []const u8 }{
        .{ .file = "no_call_parameter", .message = "ecl-native: callback first parameter must be *ecl.Call(\"inputs -- outputs\")" },
        .{ .file = "wrong_return_type", .message = "ecl-native: callback return type must be ecl.CallbackResult" },
        .{ .file = "generic_callback", .message = "ecl-native: callback must be non-generic and non-variadic" },
        .{ .file = "malformed_effect", .message = "ecl-native: effect must contain exactly one -- separator" },
        .{ .file = "partial_effect", .message = "ecl-native: effect rows are exact; `...` is not a native slot" },
        .{ .file = "output_arity_mismatch", .message = "ecl-native: complete output arity does not match the declared effect" },
        .{ .file = "unknown_capability", .message = "ecl-native: callback parameter is not a supported capability" },
        .{ .file = "duplicate_word", .message = "ecl-native: module contains a duplicate word name" },
        .{ .file = "empty_doc", .message = "ecl-native: word documentation must not be empty" },
    };
    const native_negative_step = b.step(
        "test-native-sdk-negative",
        "Check native SDK compile-time rejections",
    );
    for (negative_cases) |case| {
        const negative_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/native/negative/{s}.zig", .{case.file})),
            .target = target,
            .optimize = optimize,
        });
        negative_module.addImport("ecl-native", native_sdk);
        const negative = b.addObject(.{
            .name = b.fmt("native-negative-{s}", .{case.file}),
            .root_module = negative_module,
        });
        negative.expect_errors = .{ .contains = case.message };
        native_negative_step.dependOn(&negative.step);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ecl", mod);
    const exe = b.addExecutable(.{
        .name = "ecl",
        .root_module = exe_mod,
        .linkage = runtime_linkage,
    });
    b.installArtifact(exe);
    const native_runtime_options = b.addOptions();
    native_runtime_options.addOptionPath("ecl_exe", exe.getEmittedBin());
    native_runtime_options.addOptionPath(
        "fixture_dir",
        fixture_files.getDirectory(),
    );

    // Loopback HTTP fixture for the http module's server-backed tests.
    const http_fixture_mod = b.createModule(.{
        .root_source_file = b.path("test/http_fixture_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http_fixture = b.addExecutable(.{
        .name = "ecl-http-fixture",
        .root_module = http_fixture_mod,
    });
    const http_fixture_options = b.addOptions();
    http_fixture_options.addOptionPath("server_exe", http_fixture.getEmittedBin());

    // Hermetic child executable for process-port tests. Every caller receives
    // the emitted absolute path through build options; no test searches PATH
    // or invokes a shell.
    const process_fixture_mod = b.createModule(.{
        .root_source_file = b.path("test/process_fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    const process_fixture = b.addExecutable(.{
        .name = "ecl-process-fixture",
        .root_module = process_fixture_mod,
    });
    const process_fixture_options = b.addOptions();
    process_fixture_options.addOptionPath("process_exe", process_fixture.getEmittedBin());

    // Hermetic HTTPS/package fixture. The test process receives every path
    // explicitly; it binds loopback only and generates its deterministic
    // package graph after learning the OS-selected port.
    const pkg_fixture_options = b.addOptions();
    pkg_fixture_options.addOptionPath("server_script", b.path("test/pkg_https_fixture.py"));
    pkg_fixture_options.addOptionPath("ca_file", b.path("test/fixtures/pkg/ca.pem"));
    pkg_fixture_options.addOptionPath("server_cert", b.path("test/fixtures/pkg/server.pem"));
    pkg_fixture_options.addOptionPath("server_key", b.path("test/fixtures/pkg/server-key.pem"));

    const captured_test_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/captured_test_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const captured_test_runner = b.addExecutable(.{
        .name = "ecl-captured-test-runner",
        .root_module = captured_test_runner_mod,
    });

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
    test_options.addOption(bool, "instrument_root_execution", false);
    test_mod.addOptions("session_options", test_options);
    test_mod.addImport("minish", minish);
    test_mod.addImport("native-abi", native_abi);
    test_mod.addImport("ecl-native", native_sdk);
    test_mod.addImport("native-sample", native_sample);
    test_mod.addOptions("native_fixture_options", native_fixture_options);
    test_mod.addOptions("native_runtime_options", native_runtime_options);
    test_mod.addOptions("http_fixture_options", http_fixture_options);
    test_mod.addOptions("pkg_fixture_options", pkg_fixture_options);
    test_mod.addOptions("archive_fixture_options", archive_fixture_options);
    test_mod.addOptions("process_fixture_options", process_fixture_options);
    test_mod.link_libc = true;
    const tests = b.addTest(.{ .root_module = test_mod });
    tests.linkage = runtime_linkage;
    // Minish writes a passing summary to stderr. Run the two property-bearing
    // artifacts as explicit children so Zig 0.16 does not report a successful
    // test process as a failed command; the wrapper forwards real failures.
    const run_tests = addCapturedTestRun(b, captured_test_runner, tests);
    run_tests.step.dependOn(&fixture_files.step);
    const test_step = b.step("test", "Run the ecl test suite");
    test_step.dependOn(&run_tests.step);
    const run_ecl_tests = b.addRunArtifact(exe);
    run_ecl_tests.addArg("test");
    run_ecl_tests.setCwd(b.path("test/stdlib-tests"));
    const ecl_test_step = b.step(
        "test-ecl",
        "Run the first-class ECL test suite",
    );
    ecl_test_step.dependOn(&run_ecl_tests.step);
    test_step.dependOn(&run_ecl_tests.step);
    const native_runtime_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = &.{ "native:", "concurrency: native shutdown" },
    });
    native_runtime_tests.linkage = runtime_linkage;
    const run_native_runtime_tests = b.addRunArtifact(native_runtime_tests);
    run_native_runtime_tests.step.dependOn(&fixture_files.step);
    const native_runtime_step = b.step(
        "test-native-runtime",
        "Run native loader and transactional-call tests",
    );
    native_runtime_step.dependOn(&run_native_runtime_tests.step);
    const native_acceptance_mod = b.createModule(.{
        .root_source_file = b.path("test/native_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_acceptance_mod.addOptions("native_runtime_options", native_runtime_options);
    const native_acceptance_tests = b.addTest(.{ .root_module = native_acceptance_mod });
    const run_native_acceptance = b.addRunArtifact(native_acceptance_tests);
    run_native_acceptance.step.dependOn(&fixture_files.step);
    const native_acceptance_step = b.step(
        "test-native-acceptance",
        "Run the standalone native CLI acceptance tests",
    );
    native_acceptance_step.dependOn(&run_native_acceptance.step);
    native_runtime_step.dependOn(&run_native_acceptance.step);

    const fuzz_targets = [_]struct {
        step_name: []const u8,
        test_name: []const u8,
        description: []const u8,
    }{
        .{
            .step_name = "fuzz-render-cursor",
            .test_name = "fuzz: moved render cursor preserves its inline first action",
            .description = "Fuzz RenderCursor relocation with an inline first action",
        },
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
        .{
            .step_name = "fuzz-native-descriptor",
            .test_name = "fuzz: native descriptor metadata never escapes validation",
            .description = "Fuzz bounded native descriptor metadata",
        },
        .{
            .step_name = "fuzz-native-call",
            .test_name = "fuzz: native call transactions stay atomic under yield and cancellation",
            .description = "Fuzz native call transaction completion, yield, failure, and cancellation",
        },
    };
    const fuzz_step = b.step(
        "fuzz",
        "Run every fuzz seed corpus; use the named fuzz-* steps for bounded campaigns",
    );
    var fuzz_campaign_steps: [fuzz_targets.len]*std.Build.Step = undefined;
    for (fuzz_targets, 0..) |fuzz_target, index| {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/fuzz_root.zig"),
            .target = target,
            .optimize = optimize,
            // Zig 0.16.0's bundled fuzz runner passes builtin.StackTrace to
            // std.debug.writeStackTrace when error-return tracing is enabled.
            // Disable only that runner path until the upstream mismatch is fixed;
            // panics and sanitizer crashes still retain their diagnostics.
            .error_tracing = false,
        });
        fuzz_mod.addOptions("session_options", test_options);
        fuzz_mod.addImport("native-abi", native_abi);
        fuzz_mod.addImport("ecl-native", native_sdk);
        fuzz_mod.addOptions("native_runtime_options", native_runtime_options);
        const fuzz_tests = b.addTest(.{
            .root_module = fuzz_mod,
            .filters = &.{fuzz_target.test_name},
        });
        // Zig 0.16's x86_64 self-hosted backend accepts -ffuzz but emits an
        // empty sanitizer-coverage PC table. Select the backend that can
        // actually provide the coverage contract instead of letting a
        // campaign silently degrade to an uninstrumented executable.
        fuzz_tests.use_llvm = true;
        const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
        run_fuzz_tests.step.dependOn(&fixture_files.step);
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
    oom_mod.addImport("native-abi", native_abi);
    oom_mod.addImport("ecl-native", native_sdk);
    oom_mod.addOptions("native_fixture_options", native_fixture_options);
    oom_mod.addOptions("archive_fixture_options", archive_fixture_options);
    oom_mod.addOptions("process_fixture_options", process_fixture_options);
    oom_mod.link_libc = true;
    const oom_tests = b.addTest(.{
        .root_module = oom_mod,
        // Compile one stable artifact for every OOM family. Runtime selection
        // below keeps family and ordinal shards independent without changing
        // the compiler command or its cache key.
        .filters = &.{"oom:"},
    });
    oom_tests.linkage = runtime_linkage;
    const oom_surface_filter = b.option(
        []const u8,
        "oom-filter",
        "Run OOM tests whose names contain this substring",
    ) orelse "oom: standard-library and host:";
    const run_core_oom_tests = b.addRunArtifact(oom_tests);
    run_core_oom_tests.setEnvironmentVariable("ECL_OOM_FILTER", "oom: core:");
    run_core_oom_tests.step.dependOn(&fixture_files.step);
    const run_surface_oom_tests = b.addRunArtifact(oom_tests);
    run_surface_oom_tests.setEnvironmentVariable("ECL_OOM_FILTER", oom_surface_filter);
    run_surface_oom_tests.step.dependOn(&fixture_files.step);

    const oom_compile_step = b.step(
        "test-oom-compile",
        "Compile the shared initialized-Session OOM test artifact (ReleaseSafe)",
    );
    oom_compile_step.dependOn(&oom_tests.step);
    oom_compile_step.dependOn(&fixture_files.step);

    const oom_core_step = b.step(
        "test-oom-core",
        "Exhaust core initialized-Session allocation failures (ReleaseSafe)",
    );
    oom_core_step.dependOn(&run_core_oom_tests.step);
    const oom_surfaces_step = b.step(
        "test-oom-surfaces",
        "Exhaust standard-library and host allocation failures (ReleaseSafe)",
    );
    oom_surfaces_step.dependOn(&run_surface_oom_tests.step);
    const oom_step = b.step(
        "test-oom",
        "Exhaust initialized-session allocation failures in parallel (ReleaseSafe)",
    );
    oom_step.dependOn(oom_core_step);
    oom_step.dependOn(oom_surfaces_step);

    const audit_mod = b.createModule(.{
        .root_source_file = b.path("src/source_audit.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const audit_options = b.addOptions();
    audit_options.addOption(
        []const u8,
        "formal_values",
        @embedFile("design/formal/values.pant"),
    );
    audit_mod.addOptions("source_audit_options", audit_options);
    const audit_exe = b.addExecutable(.{ .name = "ecl-source-audit", .root_module = audit_mod });
    const run_audit = b.addRunArtifact(audit_exe);
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/bench_kernels.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("ecl", mod);
    bench_mod.link_libc = true;
    const bench_exe = b.addExecutable(.{ .name = "ecl-bench-kernels", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step(
        "bench-kernels",
        "Characterize the typed kernel seam (select a mode with -Doptimize)",
    );
    bench_step.dependOn(&run_bench.step);

    const workdriver_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/bench_workdrivers.zig"),
        .target = target,
        .optimize = optimize,
    });
    workdriver_bench_mod.addImport("ecl", mod);
    workdriver_bench_mod.link_libc = true;
    const workdriver_bench_exe = b.addExecutable(.{
        .name = "ecl-bench-workdrivers",
        .root_module = workdriver_bench_mod,
    });
    const run_workdriver_timing = b.addRunArtifact(workdriver_bench_exe);
    run_workdriver_timing.addArg("--timing");
    if (b.args) |args| run_workdriver_timing.addArgs(args);

    const instrumented_options = b.addOptions();
    instrumented_options.addOption(usize, "default_worker_count", 1);
    instrumented_options.addOption(bool, "instrument_root_execution", true);
    const instrumented_ecl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    instrumented_ecl.link_libc = true;
    instrumented_ecl.addImport("native-abi", native_abi);
    instrumented_ecl.addImport("ecl-native", native_sdk);
    instrumented_ecl.addOptions("session_options", instrumented_options);
    const workdriver_counter_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/bench_workdrivers.zig"),
        .target = target,
        .optimize = optimize,
    });
    workdriver_counter_mod.addImport("ecl", instrumented_ecl);
    workdriver_counter_mod.link_libc = true;
    const workdriver_counter_exe = b.addExecutable(.{
        .name = "ecl-bench-workdriver-counters",
        .root_module = workdriver_counter_mod,
    });
    const run_workdriver_counters = b.addRunArtifact(workdriver_counter_exe);
    run_workdriver_counters.addArg("--counters");
    if (b.args) |args| run_workdriver_counters.addArgs(args);
    run_workdriver_counters.step.dependOn(&run_workdriver_timing.step);
    const workdriver_bench_step = b.step(
        "bench-workdrivers",
        "Characterize WorkDriver and scheduler overhead (ReleaseSafe/ReleaseFast only)",
    );
    switch (optimize) {
        .ReleaseSafe, .ReleaseFast => workdriver_bench_step.dependOn(&run_workdriver_counters.step),
        else => {
            const release_required = b.addFail(
                "WorkDriver benchmarks require -Doptimize=ReleaseSafe or ReleaseFast",
            );
            workdriver_bench_step.dependOn(&release_required.step);
        },
    }

    const audit_step = b.step("source-audit", "Check source architecture");
    audit_step.dependOn(&run_audit.step);
    fuzz_step.dependOn(&run_audit.step);
    for (fuzz_campaign_steps) |campaign_step| campaign_step.dependOn(&run_audit.step);
    repl_step.dependOn(&run_audit.step);
    test_step.dependOn(&run_audit.step);
    oom_core_step.dependOn(&run_audit.step);
    oom_surfaces_step.dependOn(&run_audit.step);

    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("ecl_exe", exe.getEmittedBin());
    e2e_options.addOptionPath("process_exe", process_fixture.getEmittedBin());
    e2e_options.addOption(std.builtin.OptimizeMode, "optimize", optimize);
    e2e_options.addOptionPath(
        "native_fixture_dir",
        fixture_files.getDirectory(),
    );
    e2e_options.addOption([]const u8, "pkg_example_manifest", @embedFile("examples/pkg-smoke/ecl.pkg"));
    e2e_options.addOption([]const u8, "pkg_example_lock", @embedFile("examples/pkg-smoke/ecl.lock"));
    e2e_options.addOption([]const u8, "pkg_example_program", @embedFile("examples/pkg-smoke/main.ecl"));
    e2e_options.addOption([]const u8, "pkg_runtime_archive", @embedFile("test/fixtures/pkg/runtime-valid.tgz.hex"));
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addOptions("build_options", e2e_options);
    e2e_mod.addImport("minish", minish);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e_tests = addCapturedTestRun(b, captured_test_runner, e2e_tests);
    run_e2e_tests.step.dependOn(&fixture_files.step);
    test_step.dependOn(&run_e2e_tests.step);
    // The same CLI acceptance run as a named step, so it can be gated on its
    // own without building the whole suite.
    const e2e_step = b.step("test-e2e", "Run the CLI acceptance tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    const scheduler_shell_mod = b.createModule(.{
        .root_source_file = b.path("test/scheduler_shell_property.zig"),
        .target = target,
        .optimize = optimize,
    });
    scheduler_shell_mod.addOptions("build_options", e2e_options);
    scheduler_shell_mod.addImport("minish", minish);
    const scheduler_shell_tests = b.addTest(.{ .root_module = scheduler_shell_mod });
    const run_scheduler_shell_tests = addCapturedTestRun(
        b,
        captured_test_runner,
        scheduler_shell_tests,
    );
    const scheduler_shell_step = b.step(
        "test-scheduler-shell",
        "Run public executable scheduler properties",
    );
    scheduler_shell_step.dependOn(&run_scheduler_shell_tests.step);
    test_step.dependOn(&run_scheduler_shell_tests.step);
    // A filtered slice of the same suite, for iterating on one area without
    // paying for the whole run. Name fragments select tests by their fully
    // qualified name: `zig build test-kernels` covers the kernel, capability,
    // idiom, and combinator surfaces.
    const kernel_slice_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = &.{
            "typed kernels",
            "typed differential",
            "kernel",
            "leaf capabilities",
            "idiom",
            "combinator",
        },
    });
    kernel_slice_tests.linkage = runtime_linkage;
    const run_kernel_slice_tests = b.addRunArtifact(kernel_slice_tests);
    run_kernel_slice_tests.step.dependOn(&fixture_files.step);
    const kernel_slice_step = b.step("test-kernels", "Run the kernel and capability test slice");
    kernel_slice_step.dependOn(&run_kernel_slice_tests.step);

    const worker_step = b.step("test-workers", "Run worker-sensitive Session tests at one and eight workers");
    const worker_eight_step = b.step(
        "test-workers-8",
        "Run worker-sensitive Session tests with eight workers",
    );
    for ([_]usize{ 1, 8 }) |worker_count| {
        const worker_test_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const worker_options = b.addOptions();
        worker_options.addOption(usize, "default_worker_count", worker_count);
        worker_options.addOption(bool, "instrument_root_execution", false);
        worker_test_mod.addOptions("session_options", worker_options);
        worker_test_mod.addImport("minish", minish);
        worker_test_mod.addImport("native-abi", native_abi);
        worker_test_mod.addImport("ecl-native", native_sdk);
        worker_test_mod.addImport("native-sample", native_sample);
        worker_test_mod.addOptions("native_fixture_options", native_fixture_options);
        worker_test_mod.addOptions("native_runtime_options", native_runtime_options);
        worker_test_mod.addOptions("http_fixture_options", http_fixture_options);
        worker_test_mod.addOptions("pkg_fixture_options", pkg_fixture_options);
        worker_test_mod.addOptions("archive_fixture_options", archive_fixture_options);
        worker_test_mod.addOptions("process_fixture_options", process_fixture_options);
        worker_test_mod.link_libc = true;
        const worker_tests = b.addTest(.{
            .root_module = worker_test_mod,
            .filters = &.{"concurrency:"},
        });
        worker_tests.linkage = runtime_linkage;
        const run_worker_tests = b.addRunArtifact(worker_tests);
        run_worker_tests.step.dependOn(&fixture_files.step);
        worker_step.dependOn(&run_worker_tests.step);
        if (worker_count == 8) worker_eight_step.dependOn(&run_worker_tests.step);
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
    tsan_mod.addImport("native-abi", native_abi);
    tsan_mod.addImport("ecl-native", native_sdk);
    tsan_mod.addImport("native-sample", native_sample);
    tsan_mod.addOptions("native_fixture_options", native_fixture_options);
    tsan_mod.addOptions("native_runtime_options", native_runtime_options);
    tsan_mod.addOptions("http_fixture_options", http_fixture_options);
    tsan_mod.addOptions("pkg_fixture_options", pkg_fixture_options);
    tsan_mod.addOptions("archive_fixture_options", archive_fixture_options);
    tsan_mod.addOptions("process_fixture_options", process_fixture_options);
    tsan_mod.link_libc = true;
    const tsan_tests = b.addTest(.{
        .root_module = tsan_mod,
        .filters = &.{
            "concurrency:",
            "env: concurrent cell publication is lease-safe and TSan-clean",
            "env: concurrent readers writers and retirement reclaim production snapshots",
            "registry: concurrent commits are linearized without lost names",
            "native:",
            "archive: unpack-tgz preserves existing destinations and has one concurrent winner",
            "pkg store: existing immutable entry wins concurrent install",
            "process:",
        },
    });
    tsan_tests.linkage = runtime_linkage;
    const run_tsan_tests = b.addRunArtifact(tsan_tests);
    run_tsan_tests.step.dependOn(&fixture_files.step);
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

    const reference_options = b.addOptions();
    reference_options.addOptionPath("zig_exe", exe.getEmittedBin());
    const reference_mod = b.createModule(.{
        .root_source_file = b.path("test/reference_snapshots.zig"),
        .target = target,
        .optimize = optimize,
    });
    reference_mod.addOptions("reference_options", reference_options);
    reference_mod.addImport("ohsnap", ohsnap);
    const reference_tests = b.addTest(.{ .root_module = reference_mod });
    const run_reference_tests = b.addRunArtifact(reference_tests);
    const reference_step = b.step(
        "test-snapshots",
        "Check promoted Zig CLI behavior against reference snapshots",
    );
    reference_step.dependOn(&run_reference_tests.step);
    test_step.dependOn(&run_reference_tests.step);

    const acceptance_step = b.step(
        "acceptance",
        "Run the v1 terminal acceptance suite with a release binary",
    );
    if (optimize == .Debug) {
        const release_required = b.addFail(
            "v1 acceptance requires a release binary; pass -Doptimize=ReleaseSafe or ReleaseFast",
        );
        acceptance_step.dependOn(&release_required.step);
    } else {
        // GitHub Actions runs the workflow gates sequentially. The preceding named CI
        // gates already own the full behavioral, PTY, native, worker-count,
        // OOM, differential, TSan, and lint matrices; replaying them here
        // would add no evidence. This target owns only the M13-specific
        // release assertions and the architecture audit they rely on.
        const acceptance_unit_tests = b.addTest(.{
            .root_module = test_mod,
            .filters = &.{"acceptance:"},
        });
        acceptance_unit_tests.linkage = runtime_linkage;
        const run_acceptance_unit_tests = b.addRunArtifact(acceptance_unit_tests);
        run_acceptance_unit_tests.step.dependOn(&fixture_files.step);

        const acceptance_e2e_tests = b.addTest(.{
            .root_module = e2e_mod,
            .filters = &.{
                "soul test executes the installed artifact",
                "e2e: pp and final stack display elide huge leaves",
            },
        });
        const run_acceptance_e2e_tests = b.addRunArtifact(acceptance_e2e_tests);
        run_acceptance_e2e_tests.step.dependOn(&fixture_files.step);

        acceptance_step.dependOn(&run_audit.step);
        acceptance_step.dependOn(&run_acceptance_unit_tests.step);
        acceptance_step.dependOn(&run_acceptance_e2e_tests.step);
    }

    // ── Tier 1: the local precommit gate ───────────────────────────────────
    //
    // `zig build test` is a five-minute round trip after a one-line change,
    // and a handful of volume-heavy tests own most of it: the concurrency
    // fan-in, the typed differential, the dict-text update sweep, the
    // cross-home effect/TCO walk, the maximum-nesting formatter case, and the
    // twenty-thousand-deep recursion. None of those is the check that catches
    // an ordinary edit. This tier is what a developer runs on every commit
    // instead. Pull-request CI runs this tier in Debug and one complete
    // ReleaseSafe suite. The broader per-build-type matrix runs after merge,
    // and the release-candidate matrix owns the exhaustive initialized-Session
    // OOM sweep plus the full ReleaseFast suite.
    //
    // The tier deliberately separates *analysis* from *execution*. Every test
    // root is semantically analyzed with codegen suppressed, so a stale API
    // call anywhere — including in a test this tier does not run — is still a
    // local failure rather than a CI surprise. Only the fast core is then
    // executed.
    const analyzed_roots = [_]*std.Build.Module{
        test_mod,
        e2e_mod,
        native_acceptance_mod,
        differential_mod,
        reference_mod,
        oom_mod,
        scheduler_shell_mod,
    };
    const analysis_step = b.step(
        "check",
        "Semantically analyze every test root without running or linking it",
    );
    for (analyzed_roots) |analyzed| {
        const analysis = b.addTest(.{ .root_module = analyzed });
        analysis.linkage = runtime_linkage;
        // No binary is requested, so this is analysis only: the expensive
        // codegen and link stages never run.
        analysis.generated_bin = null;
        analysis_step.dependOn(&analysis.step);
    }

    // Selection is by fully qualified test name, so a new test in an included
    // source or family joins the tier automatically. Excluded by measured cost
    // or by ambient resource: `concurrency:`, `typed differential:`,
    // `dict-text:`, `module:`, `native:`, `fuzz:`, `acceptance:`,
    // `line editor:` (PTY), `http:` (sockets), `process:` (child processes),
    // and `pkg sync:` / `pkg store:` (a Python TLS process). Those cases still
    // compile through the analyzed roots; process startup would exceed the
    // measured fast budget.
    const precommit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = &.{
            // Whole verification sources whose every test is fast.
            "session.test.",
            "poll.test.",
            "heap.test.",
            "list.test.",
            "dict.test.",
            "equal.test.",
            "print.test.",
            "spans.test.",
            "env.test.",
            "console.test.",
            "tests.value_test.",
            "tests.reader_test.",
            "tests.machine_test.",
            // Select both module suites whole. Family selection is
            // what left this file's unprefixed tests invisible until CI found
            // one, and the registry and module-lifetime area is where a
            // CI-only miss costs the most.
            "tests.module_test.",
            "tests.module_source_test.",
            // This whole new source stays in the local gate. Its deliberately
            // large catalog case pays for proving discovery cancellation
            // across more than one kernel quantum rather than leaving the
            // closed test substrate as a CI-only behavior surface.
            "tests.test_language_test.",
            // Allocation budgets cost this tier about twenty seconds, taking
            // it from roughly eighty to roughly a hundred. That is the largest
            // single entry here and it is deliberate: a fast path that stops
            // firing still returns the right answer, so nothing else in the
            // suite notices, and finding out from a benchmark weeks later is
            // how the last two of these were found. The cost is already one
            // session per case rather than one per measurement; shrinking it
            // further means measuring fewer operations.
            "tests.allocation_budget_test.",
            "tests.kernel_numeric_test.",
            "tests.kernel_sequence_test.",
            "tests.kernel_order_test.",
            "tests.combinator_test.",
            "tests.prelude_test.",
            "tests.definition_test.",
            "tests.formatter_test.",
            "tests.module_value_test.",
            "tests.unit_input_test.",
            "tests.stdlib_test.",
            "tests.archive_test.",
            "tests.random_test.",
            "tests.hostio_test.",
            // Fast families inside sources that also hold heavy tests.
            "env:",
            "modules:",
            "module names:",
            "registry:",
            "loader:",
            "reflection",
            "session completion:",
            "binding:",
            "scope:",
        },
    });
    precommit_tests.linkage = runtime_linkage;
    const run_precommit_tests = addCapturedTestRun(b, captured_test_runner, precommit_tests);
    run_precommit_tests.step.dependOn(&fixture_files.step);
    const precommit_test_step = b.step(
        "test-precommit",
        "Run the fast core test tier (the test half of `precommit`)",
    );
    precommit_test_step.dependOn(&run_precommit_tests.step);

    // Zig sources are canonically formatted; so is every checked-in ECL source,
    // and every standard module still ends in `@defm`. All of it is cheap
    // enough that there is no reason to discover it in CI instead.
    const check_zig_fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "test" },
        .check = true,
    });
    const ecl_source_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/ecl_source_check.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    ecl_source_mod.addImport("ecl", mod);
    ecl_source_mod.link_libc = true;
    const ecl_source_exe = b.addExecutable(.{
        .name = "ecl-source-check",
        .root_module = ecl_source_mod,
    });
    const run_ecl_source = b.addRunArtifact(ecl_source_exe);
    const ecl_source_step = b.step(
        "check-ecl",
        "Check checked-in ECL source conventions: canonical formatting and module registration",
    );
    ecl_source_step.dependOn(&run_ecl_source.step);

    // SPEC.md is a checked-in rendering assembled by ECL. The build graph
    // supplies paths and generated fragments; language-level ordering and
    // inclusion remain ordinary ECL behavior in assemble.ecl.
    const render_module_spec = b.addSystemCommand(&.{
        "pant", "--markdown", "--module-path", "design/formal",
    });
    render_module_spec.addFileArg(b.path("design/formal/modules.pant"));
    const rendered_module_spec = render_module_spec.captureStdOut(.{
        .basename = "modules.md",
    });
    const render_value_spec = b.addSystemCommand(&.{
        "pant", "--markdown", "--module-path", "design/formal",
    });
    render_value_spec.addFileArg(b.path("design/formal/values.pant"));
    const rendered_value_spec = render_value_spec.captureStdOut(.{
        .basename = "values.md",
    });
    const render_printing_spec = b.addSystemCommand(&.{
        "pant", "--markdown", "--module-path", "design/formal",
    });
    render_printing_spec.addFileArg(b.path("design/formal/printing.pant"));
    const rendered_printing_spec = render_printing_spec.captureStdOut(.{
        .basename = "printing.md",
    });
    const render_error_spec = b.addSystemCommand(&.{
        "pant", "--markdown", "--module-path", "design/formal",
    });
    render_error_spec.addFileArg(b.path("design/formal/errors.pant"));
    const rendered_error_spec = render_error_spec.captureStdOut(.{
        .basename = "errors.md",
    });
    const render_unit_spec = b.addSystemCommand(&.{
        "pant", "--markdown", "--module-path", "design/formal",
    });
    render_unit_spec.addFileArg(b.path("design/formal/units.pant"));
    const rendered_unit_spec = render_unit_spec.captureStdOut(.{
        .basename = "units.md",
    });
    const render_concurrency_spec = b.addSystemCommand(&.{
        "pant", "--markdown", "--module-path", "design/formal",
    });
    render_concurrency_spec.addFileArg(b.path("design/formal/concurrency.pant"));
    const rendered_concurrency_spec = render_concurrency_spec.captureStdOut(.{
        .basename = "concurrency.md",
    });

    const assemble_spec = b.addRunArtifact(exe);
    assemble_spec.addFileArg(b.path("design/spec/assemble.ecl"));
    const assembled_spec = assemble_spec.addOutputFileArg("SPEC.md");
    assemble_spec.addFileArg(b.path("design/SPEC.src.md"));
    assemble_spec.addArg("generated-preamble");
    assemble_spec.addFileArg(b.path("design/spec/generated-preamble.md"));
    assemble_spec.addArg("value-model");
    assemble_spec.addFileArg(rendered_value_spec);
    assemble_spec.addArg("printing-model");
    assemble_spec.addFileArg(rendered_printing_spec);
    assemble_spec.addArg("error-model");
    assemble_spec.addFileArg(rendered_error_spec);
    assemble_spec.addArg("unit-model");
    assemble_spec.addFileArg(rendered_unit_spec);
    assemble_spec.addArg("concurrency-model");
    assemble_spec.addFileArg(rendered_concurrency_spec);
    assemble_spec.addArg("module-model");
    assemble_spec.addFileArg(rendered_module_spec);
    const update_spec = b.addUpdateSourceFiles();
    update_spec.addCopyFileToSource(assembled_spec, "design/SPEC.md");
    const spec_step = b.step("spec", "Assemble design/SPEC.md from its authored sources");
    spec_step.dependOn(&update_spec.step);

    const check_spec_run = b.addRunArtifact(exe);
    check_spec_run.addFileArg(b.path("design/spec/assemble.ecl"));
    check_spec_run.addArg("--check");
    check_spec_run.addFileArg(b.path("design/SPEC.md"));
    check_spec_run.addFileArg(b.path("design/SPEC.src.md"));
    check_spec_run.addArg("generated-preamble");
    check_spec_run.addFileArg(b.path("design/spec/generated-preamble.md"));
    check_spec_run.addArg("value-model");
    check_spec_run.addFileArg(rendered_value_spec);
    check_spec_run.addArg("printing-model");
    check_spec_run.addFileArg(rendered_printing_spec);
    check_spec_run.addArg("error-model");
    check_spec_run.addFileArg(rendered_error_spec);
    check_spec_run.addArg("unit-model");
    check_spec_run.addFileArg(rendered_unit_spec);
    check_spec_run.addArg("concurrency-model");
    check_spec_run.addFileArg(rendered_concurrency_spec);
    check_spec_run.addArg("module-model");
    check_spec_run.addFileArg(rendered_module_spec);
    const check_spec_step = b.step(
        "check-spec",
        "Check that design/SPEC.md matches its authored sources",
    );
    check_spec_step.dependOn(&check_spec_run.step);

    const check_formal_run = b.addSystemCommand(&.{
        "pant", "--check",   "--bound", "2",             "--steps",
        "2",    "--timeout", "8",       "--module-path", "design/formal",
    });
    check_formal_run.addFileArg(b.path("design/formal/modules.pant"));
    const check_units_formal_run = b.addSystemCommand(&.{
        "pant", "--check",   "--bound", "2",             "--steps",
        "2",    "--timeout", "8",       "--module-path", "design/formal",
    });
    check_units_formal_run.addFileArg(b.path("design/formal/units.pant"));
    const check_values_formal_run = b.addSystemCommand(&.{
        "pant", "--check",   "--bound", "2",             "--steps",
        "0",    "--timeout", "8",       "--module-path", "design/formal",
    });
    check_values_formal_run.addFileArg(b.path("design/formal/values.pant"));
    const check_printing_formal_run = b.addSystemCommand(&.{
        "pant", "--check",   "--bound", "2",             "--steps",
        "0",    "--timeout", "8",       "--module-path", "design/formal",
    });
    check_printing_formal_run.addFileArg(b.path("design/formal/printing.pant"));
    const check_errors_formal_run = b.addSystemCommand(&.{
        "pant", "--check",   "--bound", "2",             "--steps",
        "0",    "--timeout", "8",       "--module-path", "design/formal",
    });
    check_errors_formal_run.addFileArg(b.path("design/formal/errors.pant"));
    const check_concurrency_formal_run = b.addSystemCommand(&.{
        "pant", "--check",   "--bound", "2",             "--steps",
        "2",    "--timeout", "12",      "--module-path", "design/formal",
    });
    check_concurrency_formal_run.addFileArg(b.path("design/formal/concurrency.pant"));
    const check_formal_step = b.step(
        "check-formal",
        "Check the bounded Pantagruel language models (needs pant and z3)",
    );
    check_formal_step.dependOn(&check_formal_run.step);
    check_formal_step.dependOn(&check_units_formal_run.step);
    check_formal_step.dependOn(&check_values_formal_run.step);
    check_formal_step.dependOn(&check_printing_formal_run.step);
    check_formal_step.dependOn(&check_errors_formal_run.step);
    check_formal_step.dependOn(&check_concurrency_formal_run.step);

    // zlint is a downloaded binary rather than a Zig dependency, so it is
    // optional here and blocking in CI. It is wired in when it is on PATH
    // because a lint failure is otherwise only discoverable after a push, which
    // is the same round trip this tier exists to remove. Untracked sources are
    // included: a new file is exactly the one most likely to trip a rule.
    const lint_step = b.step("lint", "Run zlint over first-party Zig sources (needs zlint on PATH)");
    const zlint_available = if (b.findProgram(&.{"zlint"}, &.{})) |_| true else |_| false;
    const run_lint = b.addSystemCommand(&.{
        "sh", "-c",
        "{ git ls-files '*.zig'; git ls-files --others --exclude-standard '*.zig'; } | " ++
            "zlint -S --deny-warnings",
    });
    if (zlint_available) {
        lint_step.dependOn(&run_lint.step);
    } else {
        lint_step.dependOn(&b.addFail(
            "zlint is not on PATH; install it from github.com/DonIsaac/zlint to run this gate",
        ).step);
    }

    const precommit_step = b.step(
        "precommit",
        "The local gate: formatting, architecture audit, whole-tree analysis, and the fast test tier",
    );
    if (zlint_available) precommit_step.dependOn(&run_lint.step);
    precommit_step.dependOn(&check_zig_fmt.step);
    precommit_step.dependOn(&run_audit.step);
    precommit_step.dependOn(&run_ecl_source.step);
    precommit_step.dependOn(&check_spec_run.step);
    precommit_step.dependOn(check_formal_step);
    precommit_step.dependOn(b.getInstallStep());
    precommit_step.dependOn(analysis_step);
    precommit_step.dependOn(&run_precommit_tests.step);
}

fn addCapturedTestRun(
    b: *std.Build,
    runner: *std.Build.Step.Compile,
    tests: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(runner);
    run.addArtifactArg(tests);
    run.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    return run;
}
