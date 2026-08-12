const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ecl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the value-core test suite");
    test_step.dependOn(&run_tests.step);

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
    const tsan_tests = b.addTest(.{ .root_module = tsan_mod });
    const run_tsan_tests = b.addRunArtifact(tsan_tests);
    const tsan_step = b.step("test-tsan", "Run tests under ThreadSanitizer");
    tsan_step.dependOn(&run_tsan_tests.step);
}
