//! Zig build helpers for one-module `.eclmod` artifacts.

const std = @import("std");

pub const ExtensionOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ecl_native: *std.Build.Module,
};

pub fn addExtension(b: *std.Build, options: ExtensionOptions) *std.Build.Step.Compile {
    const module_root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
    });
    module_root.addImport("ecl-native", options.ecl_native);
    return b.addLibrary(.{
        .name = options.name,
        .root_module = module_root,
        .linkage = .dynamic,
    });
}

pub fn installExtension(
    b: *std.Build,
    extension: *std.Build.Step.Compile,
    install_dir: []const u8,
) *std.Build.Step {
    const install = b.addInstallFileWithDir(
        extension.getEmittedBin(),
        .{ .custom = install_dir },
        b.fmt("{s}.eclmod", .{extension.name}),
    );
    return &install.step;
}
