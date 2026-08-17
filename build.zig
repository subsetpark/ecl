const std = @import("std");
const native_build = @import("src/native/build_helper.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    mod.addImport("native-abi", native_abi);
    const runtime_options = b.addOptions();
    runtime_options.addOption(usize, "default_worker_count", 1);
    mod.addOptions("session_options", runtime_options);

    const native_sdk = b.addModule("ecl-native", .{
        .root_source_file = b.path("src/native/sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sdk.addImport("ecl-native-abi", native_abi);
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

    const malformed_defects = [_][]const u8{
        "wrong-name",
        "abi-major",
        "capability-version",
        "duplicate-word",
        "missing-doc",
        "entry-failure",
        "invalid-effect",
        "reserved-capability",
        "reserved-state",
        "unknown-entry-status",
        "stride-overread",
        "unknown-result",
        "unknown-failure-kind",
        "unknown-scalar-kind",
        "oversized-scalar",
        "invalid-utf8-scalar",
        "partial-complete",
        "undeclared-yield",
        "consume-without-state",
        "old-v1",
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
    test_mod.addImport("native-abi", native_abi);
    test_mod.addImport("native-sample", native_sample);
    test_mod.addOptions("native_fixture_options", native_fixture_options);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&fixture_files.step);
    const test_step = b.step("test", "Run the ecl test suite");
    test_step.dependOn(&run_tests.step);
    const native_runtime_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = &.{ "native:", "concurrency: native shutdown" },
    });
    const run_native_runtime_tests = b.addRunArtifact(native_runtime_tests);
    run_native_runtime_tests.step.dependOn(&fixture_files.step);
    const native_runtime_step = b.step(
        "test-native-runtime",
        "Run native loader and transactional-call tests",
    );
    native_runtime_step.dependOn(&run_native_runtime_tests.step);
    const native_runtime_options = b.addOptions();
    native_runtime_options.addOptionPath("ecl_exe", exe.getEmittedBin());
    native_runtime_options.addOptionPath(
        "fixture_dir",
        fixture_files.getDirectory(),
    );
    const native_acceptance_mod = b.createModule(.{
        .root_source_file = b.path("test/native_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_acceptance_mod.addOptions("native_runtime_options", native_runtime_options);
    const native_acceptance_tests = b.addTest(.{ .root_module = native_acceptance_mod });
    const run_native_acceptance = b.addRunArtifact(native_acceptance_tests);
    run_native_acceptance.step.dependOn(&fixture_files.step);
    native_runtime_step.dependOn(&run_native_acceptance.step);

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
        fuzz_mod.addImport("native-abi", native_abi);
        fuzz_mod.addImport("native-sample", native_sample);
        fuzz_mod.addOptions("native_fixture_options", native_fixture_options);
        const fuzz_tests = b.addTest(.{
            .root_module = fuzz_mod,
            .filters = &.{fuzz_target.test_name},
        });
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
    oom_mod.addOptions("native_fixture_options", native_fixture_options);
    const oom_tests = b.addTest(.{
        .root_module = oom_mod,
        .filters = &.{"oom:"},
    });
    const run_oom_tests = b.addRunArtifact(oom_tests);
    run_oom_tests.step.dependOn(&fixture_files.step);
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
    const audit_step = b.step("source-audit", "Check source architecture");
    audit_step.dependOn(&run_audit.step);
    fuzz_step.dependOn(&run_audit.step);
    for (fuzz_campaign_steps) |campaign_step| campaign_step.dependOn(&run_audit.step);
    repl_step.dependOn(&run_audit.step);
    test_step.dependOn(&run_audit.step);
    oom_step.dependOn(&run_audit.step);

    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("ecl_exe", exe.getEmittedBin());
    e2e_options.addOptionPath(
        "native_fixture_dir",
        fixture_files.getDirectory(),
    );
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addOptions("build_options", e2e_options);
    e2e_mod.addImport("minish", minish);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.step.dependOn(&fixture_files.step);
    test_step.dependOn(&run_e2e_tests.step);

    const worker_step = b.step("test-workers", "Run worker-sensitive Session tests at one and eight workers");
    for ([_]usize{ 1, 8 }) |worker_count| {
        const worker_test_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const worker_options = b.addOptions();
        worker_options.addOption(usize, "default_worker_count", worker_count);
        worker_test_mod.addOptions("session_options", worker_options);
        worker_test_mod.addImport("minish", minish);
        worker_test_mod.addImport("native-abi", native_abi);
        worker_test_mod.addImport("native-sample", native_sample);
        worker_test_mod.addOptions("native_fixture_options", native_fixture_options);
        const worker_tests = b.addTest(.{
            .root_module = worker_test_mod,
            .filters = &.{"concurrency:"},
        });
        const run_worker_tests = b.addRunArtifact(worker_tests);
        run_worker_tests.step.dependOn(&fixture_files.step);
        worker_step.dependOn(&run_worker_tests.step);
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
    tsan_mod.addImport("native-sample", native_sample);
    tsan_mod.addOptions("native_fixture_options", native_fixture_options);
    const tsan_tests = b.addTest(.{
        .root_module = tsan_mod,
        .filters = &.{
            "concurrency:",
            "env: concurrent cell publication is lease-safe and TSan-clean",
            "env: concurrent readers writers and retirement reclaim production snapshots",
            "registry: concurrent commits are linearized without lost names",
            "native:",
        },
    });
    const run_tsan_tests = b.addRunArtifact(tsan_tests);
    const tsan_cwd = b.addWriteFiles();
    tsan_cwd.mode = .tmp;
    _ = tsan_cwd.add(".keep", "");
    run_tsan_tests.setCwd(tsan_cwd.getDirectory());
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
}
