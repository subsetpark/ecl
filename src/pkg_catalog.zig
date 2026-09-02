//! Derived, inert package module catalogs.
//!
//! A catalog is built from validated package manifests and parsed ECL source;
//! no package source is evaluated during discovery. Export globs select source
//! artifacts, while top-level literal `@defm` declarations provide the exact
//! canonical module names those artifacts may publish.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const reader = @import("reader.zig");
const dict = @import("dict.zig");
const storage = @import("kernel_storage.zig");
const intern = @import("intern.zig");

const Value = value.Value;
const max_manifest_bytes = 16 * 1024 * 1024;
const max_source_bytes = 16 * 1024 * 1024;
const max_catalog_source_bytes = 64 * 1024 * 1024;
const max_artifacts = 4096;
const max_modules = 65_536;
const max_relative_path_bytes = 4096;

pub const PackageId = enum(u32) { _ };
pub const ArtifactId = enum(u32) { _ };

pub const PackageInput = struct {
    id: PackageId,
    name: []const u8,
    version: []const u8,
    root_dir: []const u8,
    /// The directory `root_dir` is relative to. Lock-derived inputs name
    /// trusted absolute store paths and leave this null; the installer
    /// validates a staged tree through the handle it already holds, so no
    /// path text is ever re-resolved from the process working directory.
    base_dir: ?std.Io.Dir = null,

    fn base(self: PackageInput) std.Io.Dir {
        return self.base_dir orelse std.Io.Dir.cwd();
    }
};

pub const Artifact = struct {
    package: PackageId,
    relative_path: []u8,
    absolute_path: []u8,
    modules: []intern.ModuleName,

    fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.absolute_path);
        allocator.free(self.modules);
        self.* = undefined;
    }
};

pub const Module = struct {
    name: intern.ModuleName,
    artifact: ArtifactId,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    artifacts: []Artifact,
    modules: []Module,

    pub fn deinit(self: *Catalog) void {
        for (self.artifacts) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.artifacts);
        self.allocator.free(self.modules);
        self.* = undefined;
    }

    pub fn find(self: *const Catalog, module_name: []const u8) ?Module {
        for (self.modules) |entry| {
            if (std.mem.eql(u8, intern.get(intern.moduleId(entry.name)), module_name)) return entry;
        }
        return null;
    }

    pub fn artifact(self: *const Catalog, id: ArtifactId) *const Artifact {
        return &self.artifacts[@intFromEnum(id)];
    }
};

pub const BuildError = error{ OutOfMemory, Invalid };

const Export = struct {
    namespace: []u8,
    globs: [][]u8,

    fn deinit(self: *Export, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
        for (self.globs) |glob| allocator.free(glob);
        allocator.free(self.globs);
        self.* = undefined;
    }
};

const Manifest = struct {
    name: []u8,
    version: []u8,
    exports: []Export,

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        for (self.exports) |*export_entry| export_entry.deinit(allocator);
        allocator.free(self.exports);
        self.* = undefined;
    }
};

const Claim = struct {
    relative_path: []u8,
    namespace: []const u8,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    host: *const heap.HostCleanup,
    io: std.Io,
    diagnostic: *?[]u8,
    artifacts: std.ArrayList(Artifact) = .empty,
    modules: std.ArrayList(Module) = .empty,
    source_bytes: usize = 0,

    fn fail(self: *Builder, comptime format: []const u8, args: anytype) BuildError {
        if (self.diagnostic.* == null) {
            self.diagnostic.* = std.fmt.allocPrint(self.allocator, format, args) catch
                return error.OutOfMemory;
        }
        return error.Invalid;
    }

    fn deinit(self: *Builder) void {
        for (self.artifacts.items) |*artifact| artifact.deinit(self.allocator);
        self.artifacts.deinit(self.allocator);
        self.modules.deinit(self.allocator);
    }

    /// Read and validate one package's manifest, then open the directory walk
    /// its export globs select over. The walk itself is resumable: a package
    /// tree holds thousands of artifacts and a scheduler step may not traverse
    /// them all at once.
    fn openPackage(self: *Builder, input: PackageInput) BuildError!Walk {
        var manifest = try self.readManifest(input);
        errdefer manifest.deinit(self.allocator);
        if (!std.mem.eql(u8, manifest.name, input.name) or
            (input.version.len != 0 and !std.mem.eql(u8, manifest.version, input.version)))
        {
            return self.fail(
                "package manifest at `{s}` identifies {s} {s}, expected {s} {s}",
                .{ input.root_dir, manifest.name, manifest.version, input.name, input.version },
            );
        }
        var directory = input.base().openDir(self.io, input.root_dir, .{ .iterate = true }) catch |err|
            return self.fail("cannot open package directory `{s}`: {s}", .{ input.root_dir, @errorName(err) });
        errdefer directory.close(self.io);
        const walker = directory.walk(self.allocator) catch return error.OutOfMemory;
        return .{ .manifest = manifest, .directory = directory, .walker = walker };
    }

    /// Claim up to `budget` directory entries for their export namespace.
    /// Returns false once the walk is exhausted.
    fn walkStep(self: *Builder, input: PackageInput, walk: *Walk, budget: usize) BuildError!bool {
        var remaining = budget;
        while (remaining != 0) : (remaining -= 1) {
            const next = walk.walker.next(self.io) catch |err| return self.fail(
                "cannot traverse package directory `{s}`: {s}",
                .{ input.root_dir, @errorName(err) },
            );
            const entry = next orelse return false;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ecl")) continue;
            if (entry.path.len > max_relative_path_bytes) return self.fail(
                "package `{s}` contains an ECL artifact path longer than {d} bytes",
                .{ input.name, max_relative_path_bytes },
            );
            var matched_namespace: ?[]const u8 = null;
            for (walk.manifest.exports) |export_entry| {
                var matched = false;
                for (export_entry.globs) |glob| {
                    if (globMatches(glob, entry.path)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
                if (matched_namespace) |prior| {
                    if (!std.mem.eql(u8, prior, export_entry.namespace)) return self.fail(
                        "package `{s}` artifact `{s}` is claimed by export namespaces `{s}` and `{s}`",
                        .{ input.name, entry.path, prior, export_entry.namespace },
                    );
                } else matched_namespace = export_entry.namespace;
            }
            if (matched_namespace) |namespace| {
                try walk.claims.ensureUnusedCapacity(self.allocator, 1);
                walk.claims.appendAssumeCapacity(.{
                    .relative_path = try self.allocator.dupe(u8, entry.path),
                    .namespace = namespace,
                });
            }
            if (self.artifacts.items.len + walk.claims.items.len > max_artifacts) return self.fail(
                "package graph contains more than {d} exported ECL artifacts",
                .{max_artifacts},
            );
        }
        return true;
    }

    /// Order the claims and prove every declared glob selected something. Both
    /// run over memory already held and are bounded by the manifest, so they
    /// stay one step.
    fn closeWalk(self: *Builder, input: PackageInput, walk: *Walk) BuildError!void {
        std.mem.sort(Claim, walk.claims.items, {}, struct {
            fn lessThan(_: void, left: Claim, right: Claim) bool {
                return std.mem.order(u8, left.relative_path, right.relative_path) == .lt;
            }
        }.lessThan);

        for (walk.manifest.exports) |export_entry| {
            for (export_entry.globs) |glob| {
                var matched = false;
                for (walk.claims.items) |claim| {
                    if (std.mem.eql(u8, claim.namespace, export_entry.namespace) and
                        globMatches(glob, claim.relative_path))
                    {
                        matched = true;
                        break;
                    }
                }
                if (!matched) return self.fail(
                    "package `{s}` export `{s}` glob `{s}` matches no ECL source artifact",
                    .{ input.name, export_entry.namespace, glob },
                );
            }
        }
    }

    fn buildArtifact(self: *Builder, input: PackageInput, claim: Claim) BuildError!void {
        const absolute = std.fs.path.join(self.allocator, &.{ input.root_dir, claim.relative_path }) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(absolute);
        const source = input.base().readFileAlloc(
            self.io,
            absolute,
            self.allocator,
            .limited(max_source_bytes),
        ) catch |err| return self.fail(
            "cannot read package `{s}` artifact `{s}`: {s}",
            .{ input.name, claim.relative_path, @errorName(err) },
        );
        defer self.allocator.free(source);
        self.source_bytes = std.math.add(usize, self.source_bytes, source.len) catch
            return self.fail("package catalog source exceeds its byte limit", .{});
        if (self.source_bytes > max_catalog_source_bytes) return self.fail(
            "package catalog source exceeds its {d}-byte limit",
            .{max_catalog_source_bytes},
        );

        var diag: reader.Diag = .{};
        const read_result = reader.read(self.host, absolute, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => return self.fail(
                "cannot parse package `{s}` artifact `{s}`: {s}",
                .{ input.name, claim.relative_path, diag.text() },
            ),
        };
        var parsed = switch (read_result) {
            .incomplete => |incomplete| return self.fail(
                "package `{s}` artifact `{s}` is incomplete: {s}",
                .{ input.name, claim.relative_path, incomplete.message },
            ),
            .complete => |complete| complete,
        };
        defer parsed.deinit();

        var names: std.ArrayList(intern.ModuleName) = .empty;
        defer names.deinit(self.allocator);
        const forms = parsed.values();
        for (forms, 0..) |form, index| {
            if (form != .word or !std.mem.eql(u8, intern.get(form.word.name), "@defm")) continue;
            if (index == 0 or forms[index - 1] != .symbol) return self.fail(
                "package `{s}` artifact `{s}` has a top-level @defm without a literal module name",
                .{ input.name, claim.relative_path },
            );
            const name = intern.moduleName(forms[index - 1].symbol) catch return self.fail(
                "package `{s}` artifact `{s}` declares an invalid module name",
                .{ input.name, claim.relative_path },
            );
            const name_bytes = intern.get(intern.moduleId(name));
            if (!ownsNamespace(claim.namespace, name_bytes)) return self.fail(
                "package `{s}` artifact `{s}` declares module `{s}` outside export namespace `{s}`",
                .{ input.name, claim.relative_path, name_bytes, claim.namespace },
            );
            for (names.items) |prior| if (prior == name) return self.fail(
                "package `{s}` artifact `{s}` declares module `{s}` more than once",
                .{ input.name, claim.relative_path, name_bytes },
            );
            for (self.modules.items) |prior| if (prior.name == name) return self.fail(
                "module `{s}` is declared by more than one package artifact",
                .{name_bytes},
            );
            try names.append(self.allocator, name);
            if (self.modules.items.len + names.items.len > max_modules) return self.fail(
                "package graph declares more than {d} modules",
                .{max_modules},
            );
        }
        if (names.items.len == 0) return self.fail(
            "package `{s}` artifact `{s}` declares no top-level statically named modules",
            .{ input.name, claim.relative_path },
        );

        const artifact_id: ArtifactId = @enumFromInt(@as(u32, @intCast(self.artifacts.items.len)));
        try self.artifacts.ensureUnusedCapacity(self.allocator, 1);
        try self.modules.ensureUnusedCapacity(self.allocator, names.items.len);
        const owned_names = try names.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_names);
        const relative = try self.allocator.dupe(u8, claim.relative_path);
        errdefer self.allocator.free(relative);
        self.artifacts.appendAssumeCapacity(.{
            .package = input.id,
            .relative_path = relative,
            .absolute_path = absolute,
            .modules = owned_names,
        });
        for (owned_names) |name| self.modules.appendAssumeCapacity(.{
            .name = name,
            .artifact = artifact_id,
        });
    }

    fn readManifest(self: *Builder, input: PackageInput) BuildError!Manifest {
        const path = std.fs.path.join(self.allocator, &.{ input.root_dir, "ecl.pkg" }) catch
            return error.OutOfMemory;
        defer self.allocator.free(path);
        const source = input.base().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(max_manifest_bytes),
        ) catch |err| return self.fail("cannot read package manifest `{s}`: {s}", .{ path, @errorName(err) });
        defer self.allocator.free(source);
        var diag: reader.Diag = .{};
        const read_result = reader.read(self.host, path, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => return self.fail("cannot parse package manifest `{s}`: {s}", .{ path, diag.text() }),
        };
        var parsed = switch (read_result) {
            .incomplete => |incomplete| return self.fail(
                "package manifest `{s}` is incomplete: {s}",
                .{ path, incomplete.message },
            ),
            .complete => |complete| complete,
        };
        defer parsed.deinit();
        if (parsed.values().len != 1) return self.fail(
            "package manifest `{s}` must contain exactly one form",
            .{path},
        );
        return self.parseManifest(path, parsed.values()[0]);
    }

    fn parseManifest(self: *Builder, path: []const u8, item: Value) BuildError!Manifest {
        const top = exactFields(item, &.{ "format", "name", "version", "exports", "requires" }) catch
            return self.fail("package manifest `{s}` does not have the exact format-1 fields", .{path});
        const format = field(top, "format") catch @panic("exact manifest lost its format field");
        if (format != .int or format.int != 1)
            return self.fail("package manifest `{s}` has an unsupported format", .{path});
        const name = ownedUtf8(
            self.allocator,
            field(top, "name") catch @panic("exact manifest lost its name field"),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return self.fail("package manifest `{s}` has a non-string name", .{path}),
        };
        errdefer self.allocator.free(name);
        if (!validCanonicalName(name))
            return self.fail("package manifest `{s}` has a non-canonical name", .{path});
        const version = ownedUtf8(
            self.allocator,
            field(top, "version") catch @panic("exact manifest lost its version field"),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return self.fail("package manifest `{s}` has a non-string version", .{path}),
        };
        errdefer self.allocator.free(version);

        const exports_dict = asDict(
            field(top, "exports") catch @panic("exact manifest lost its exports field"),
        ) catch
            return self.fail("package manifest `{s}` exports must be a dict", .{path});
        var exports: std.ArrayList(Export) = .empty;
        errdefer {
            for (exports.items) |*entry| entry.deinit(self.allocator);
            exports.deinit(self.allocator);
        }
        const export_count: usize = @intCast(exports_dict.length());
        try exports.ensureTotalCapacity(self.allocator, export_count);
        for (0..export_count) |index| {
            const namespace = ownedUtf8(self.allocator, dict.keyAt(exports_dict, index)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return self.fail("package manifest `{s}` has a non-string export namespace", .{path}),
            };
            errdefer self.allocator.free(namespace);
            if (!validCanonicalName(namespace) or !ownsNamespace(name, namespace)) return self.fail(
                "package `{s}` does not own export namespace `{s}`",
                .{ name, namespace },
            );
            const glob_list = switch (dict.valueAt(exports_dict, index)) {
                .list => |list_header| list_header,
                else => return self.fail(
                    "package manifest `{s}` export `{s}` must be a nonempty glob list",
                    .{ path, namespace },
                ),
            };
            const glob_count: usize = @intCast(glob_list.length());
            if (glob_count == 0) return self.fail(
                "package manifest `{s}` export `{s}` has an empty glob list",
                .{ path, namespace },
            );
            const globs = try self.allocator.alloc([]u8, glob_count);
            var built: usize = 0;
            errdefer {
                for (globs[0..built]) |glob| self.allocator.free(glob);
                self.allocator.free(globs);
            }
            for (0..glob_count) |glob_index| {
                const glob = ownedUtf8(
                    self.allocator,
                    @import("list.zig").atUnchecked(.{ .list = glob_list }, glob_index),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => return self.fail(
                        "package manifest `{s}` export `{s}` contains a non-string glob",
                        .{ path, namespace },
                    ),
                };
                if (!validGlob(glob)) {
                    self.allocator.free(glob);
                    return self.fail(
                        "package manifest `{s}` export `{s}` contains an unsafe glob",
                        .{ path, namespace },
                    );
                }
                for (globs[0..built]) |prior| if (std.mem.eql(u8, prior, glob)) {
                    self.allocator.free(glob);
                    return self.fail(
                        "package manifest `{s}` export `{s}` repeats a glob",
                        .{ path, namespace },
                    );
                };
                globs[built] = glob;
                built += 1;
            }
            exports.appendAssumeCapacity(.{ .namespace = namespace, .globs = globs });
        }

        if (!validVersion(version))
            return self.fail("package manifest `{s}` has a non-semver version", .{path});
        try self.validateRequires(path, name, top);
        return .{
            .name = name,
            .version = version,
            .exports = try exports.toOwnedSlice(self.allocator),
        };
    }

    /// The requirement contract `pkg.manifest.validate` states. The installer
    /// seals a staged package against this boundary rather than against the
    /// public validator, so a manifest the public validator rejects must not
    /// pass here either; anything less lets a direct caller publish a package
    /// nothing can later read back.
    fn validateRequires(
        self: *Builder,
        path: []const u8,
        name: []const u8,
        top: *value.DictHandle,
    ) BuildError!void {
        const requires = asDict(
            field(top, "requires") catch @panic("exact manifest lost its requires field"),
        ) catch
            return self.fail("package manifest `{s}` requires must be a dict", .{path});
        const count: usize = @intCast(requires.length());
        var required: std.ArrayList([]u8) = .empty;
        defer {
            for (required.items) |entry| self.allocator.free(entry);
            required.deinit(self.allocator);
        }
        try required.ensureTotalCapacity(self.allocator, count);
        for (0..count) |index| {
            const alias = ownedUtf8(self.allocator, dict.keyAt(requires, index)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return self.fail(
                    "package manifest `{s}` has a non-string requirement alias",
                    .{path},
                ),
            };
            defer self.allocator.free(alias);
            if (!validCanonicalName(alias)) return self.fail(
                "package manifest `{s}` requirement alias `{s}` is not a canonical package name",
                .{ path, alias },
            );
            const requirement = exactFields(
                dict.valueAt(requires, index),
                &.{ "package", "version", "url", "hash" },
            ) catch return self.fail(
                "package manifest `{s}` requirement `{s}` does not have the exact keys " ++
                    "'package 'version 'url 'hash",
                .{ path, alias },
            );
            const required_name = try self.requirementField(path, alias, requirement, "package");
            errdefer self.allocator.free(required_name);
            if (!validCanonicalName(required_name)) return self.fail(
                "package manifest `{s}` requirement `{s}` names a non-canonical package",
                .{ path, alias },
            );
            const version = try self.requirementField(path, alias, requirement, "version");
            defer self.allocator.free(version);
            if (!validVersion(version)) return self.fail(
                "package manifest `{s}` requirement `{s}` has a non-semver version",
                .{ path, alias },
            );
            const url = try self.requirementField(path, alias, requirement, "url");
            defer self.allocator.free(url);
            if (!validUrl(url)) return self.fail(
                "package manifest `{s}` requirement `{s}` url is not an https url",
                .{ path, alias },
            );
            const hash = try self.requirementField(path, alias, requirement, "hash");
            defer self.allocator.free(hash);
            if (!validHash(hash)) return self.fail(
                "package manifest `{s}` requirement `{s}` hash is not sha256- and 64 hex digits",
                .{ path, alias },
            );
            for (required.items) |prior| if (std.mem.eql(u8, prior, required_name)) return self.fail(
                "package manifest `{s}` requires `{s}` under more than one alias",
                .{ path, required_name },
            );
            required.appendAssumeCapacity(required_name);
        }
        for (required.items, 0..) |left, index| {
            if (related(name, left)) return self.fail(
                "package `{s}` may not require `{s}`: one name owns the other",
                .{ name, left },
            );
            for (required.items[index + 1 ..]) |right| if (related(left, right)) return self.fail(
                "package manifest `{s}` requires `{s}` and `{s}`: one name owns the other",
                .{ path, left, right },
            );
        }
    }

    fn requirementField(
        self: *Builder,
        path: []const u8,
        alias: []const u8,
        requirement: *value.DictHandle,
        key: []const u8,
    ) BuildError![]u8 {
        return ownedUtf8(
            self.allocator,
            field(requirement, key) catch @panic("exact requirement lost a field"),
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Invalid => self.fail(
                "package manifest `{s}` requirement `{s}` has a non-string {s}",
                .{ path, alias, key },
            ),
        };
    }
};

/// One package's directory traversal, held across scheduler steps.
const Walk = struct {
    manifest: Manifest,
    directory: std.Io.Dir,
    walker: std.Io.Dir.Walker,
    claims: std.ArrayList(Claim) = .empty,

    fn deinit(self: *Walk, allocator: std.mem.Allocator, io: std.Io) void {
        for (self.claims.items) |claim| allocator.free(claim.relative_path);
        self.claims.deinit(allocator);
        self.walker.deinit();
        self.directory.close(io);
        self.manifest.deinit(allocator);
    }
};

pub const Progress = enum { pending, done };

/// A resumable catalog build. One `advance` reads one manifest, claims up to
/// `budget` directory entries, or parses one source artifact, so a caller
/// inside the scheduler can traverse a package tree of any size without
/// monopolizing its worker or deferring cancellation. `build` below is the
/// same walk run to completion for callers that are not on a scheduler step.
pub const Build = struct {
    builder: Builder,
    packages: []const PackageInput,
    owned_input: ?OwnedInput = null,
    package_index: usize = 0,
    stage: Stage = .manifest,

    const OwnedInput = struct {
        input: PackageInput,
        name: []u8,
        root_dir: []u8,
    };
    const Stage = union(enum) {
        manifest,
        walking: Walk,
        artifacts: struct { walk: Walk, index: usize = 0 },
        finished,
    };

    pub fn init(
        host: *const heap.HostCleanup,
        io: std.Io,
        packages: []const PackageInput,
        diagnostic: *?[]u8,
    ) Build {
        diagnostic.* = null;
        return .{
            .builder = .{
                .allocator = host.allocator(),
                .host = host,
                .io = io,
                .diagnostic = diagnostic,
            },
            .packages = packages,
        };
    }

    /// The single-package form the installer uses. It copies the identity it
    /// validates, because the caller's own storage may not outlive a build
    /// that now spans scheduler steps.
    pub fn initOwned(
        host: *const heap.HostCleanup,
        io: std.Io,
        name: []const u8,
        root_dir: []const u8,
        base_dir: ?std.Io.Dir,
        diagnostic: *?[]u8,
    ) error{OutOfMemory}!Build {
        const allocator = host.allocator();
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_root = try allocator.dupe(u8, root_dir);
        errdefer allocator.free(owned_root);
        var result = init(host, io, &.{}, diagnostic);
        result.owned_input = .{
            .input = .{
                .id = @enumFromInt(0),
                .name = owned_name,
                .version = "",
                .root_dir = owned_root,
                .base_dir = base_dir,
            },
            .name = owned_name,
            .root_dir = owned_root,
        };
        return result;
    }

    /// The owned input is held by value rather than pointed at, because this
    /// cursor is stored inside a driver state that moves between steps and a
    /// slice into itself would not survive the copy.
    fn packageCount(self: *const Build) usize {
        return if (self.owned_input != null) 1 else self.packages.len;
    }

    fn currentInput(self: *const Build) PackageInput {
        if (self.owned_input) |owned| return owned.input;
        return self.packages[self.package_index];
    }

    pub fn advance(self: *Build, budget: usize) BuildError!Progress {
        if (self.package_index == self.packageCount()) {
            self.stage = .finished;
            return .done;
        }
        const input = self.currentInput();
        switch (self.stage) {
            .manifest => {
                // Open into a local first: writing the union directly would
                // let a failing `openPackage` leave the stage tagged over an
                // unwritten payload, which `deinit` would then release.
                const opened = try self.builder.openPackage(input);
                self.stage = .{ .walking = opened };
                return .pending;
            },
            .walking => |*walk| {
                if (try self.builder.walkStep(input, walk, budget)) return .pending;
                try self.builder.closeWalk(input, walk);
                // Move the walk out before the union store: writing the new
                // stage in place would otherwise overlap the payload being
                // copied out of it.
                const traversed = walk.*;
                self.stage = .{ .artifacts = .{ .walk = traversed } };
                return .pending;
            },
            .artifacts => |*artifacts| {
                if (artifacts.index == artifacts.walk.claims.items.len) {
                    artifacts.walk.deinit(self.builder.allocator, self.builder.io);
                    self.stage = .manifest;
                    self.package_index += 1;
                    return if (self.package_index == self.packageCount()) .done else .pending;
                }
                try self.builder.buildArtifact(input, artifacts.walk.claims.items[artifacts.index]);
                artifacts.index += 1;
                return .pending;
            },
            .finished => return .done,
        }
    }

    /// Take the finished catalog. Only valid once `advance` reported `.done`.
    pub fn take(self: *Build) BuildError!Catalog {
        std.debug.assert(self.stage == .finished or self.package_index == self.packageCount());
        const allocator = self.builder.allocator;
        const artifacts = try self.builder.artifacts.toOwnedSlice(allocator);
        errdefer {
            for (artifacts) |*artifact| artifact.deinit(allocator);
            allocator.free(artifacts);
        }
        const modules = try self.builder.modules.toOwnedSlice(allocator);
        self.releaseInput();
        return .{ .allocator = allocator, .artifacts = artifacts, .modules = modules };
    }

    fn releaseInput(self: *Build) void {
        const owned = self.owned_input orelse return;
        self.builder.allocator.free(owned.name);
        self.builder.allocator.free(owned.root_dir);
        self.owned_input = null;
    }

    pub fn deinit(self: *Build) void {
        switch (self.stage) {
            .walking => |*walk| walk.deinit(self.builder.allocator, self.builder.io),
            .artifacts => |*artifacts| artifacts.walk.deinit(self.builder.allocator, self.builder.io),
            .manifest, .finished => {},
        }
        self.stage = .finished;
        self.builder.deinit();
        self.releaseInput();
    }
};

pub fn build(
    host: *const heap.HostCleanup,
    io: std.Io,
    packages: []const PackageInput,
    diagnostic: *?[]u8,
) BuildError!Catalog {
    var cursor: Build = .init(host, io, packages, diagnostic);
    errdefer cursor.deinit();
    while (try cursor.advance(std.math.maxInt(usize)) == .pending) {}
    return cursor.take();
}

fn validGlob(glob: []const u8) bool {
    if (glob.len == 0 or glob[0] == '/' or std.mem.indexOfScalar(u8, glob, '\\') != null)
        return false;
    var segments = std.mem.splitScalar(u8, glob, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return false;
        if (std.mem.indexOf(u8, segment, "**") != null and !std.mem.eql(u8, segment, "**"))
            return false;
    }
    return true;
}

fn globMatches(glob: []const u8, path: []const u8) bool {
    return matchSegments(glob, 0, path, 0);
}

fn matchSegments(glob: []const u8, glob_start: usize, path: []const u8, path_start: usize) bool {
    const glob_end = std.mem.indexOfScalarPos(u8, glob, glob_start, '/') orelse glob.len;
    const path_end = std.mem.indexOfScalarPos(u8, path, path_start, '/') orelse path.len;
    const glob_segment = glob[glob_start..glob_end];
    if (std.mem.eql(u8, glob_segment, "**")) {
        if (glob_end == glob.len) return true;
        const next_glob = glob_end + 1;
        var next_path = path_start;
        while (true) {
            if (matchSegments(glob, next_glob, path, next_path)) return true;
            const slash = std.mem.indexOfScalarPos(u8, path, next_path, '/') orelse return false;
            next_path = slash + 1;
        }
    }
    if (!matchSegment(glob_segment, path[path_start..path_end])) return false;
    if (glob_end == glob.len or path_end == path.len)
        return glob_end == glob.len and path_end == path.len;
    return matchSegments(glob, glob_end + 1, path, path_end + 1);
}

fn matchSegment(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star: ?usize = null;
    var star_text: usize = 0;
    while (text_index < text.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index]))
        {
            pattern_index += 1;
            text_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star = pattern_index;
            pattern_index += 1;
            star_text = text_index;
        } else if (star) |star_index| {
            pattern_index = star_index + 1;
            star_text += 1;
            text_index = star_text;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

/// Two package names collide when either owns the other as a dotted prefix.
fn related(left: []const u8, right: []const u8) bool {
    return ownsNamespace(left, right) or ownsNamespace(right, left);
}

fn ownsNamespace(namespace: []const u8, module_name: []const u8) bool {
    return std.mem.eql(u8, namespace, module_name) or
        (module_name.len > namespace.len and
            std.mem.startsWith(u8, module_name, namespace) and
            module_name[namespace.len] == '.');
}

pub fn validHash(hash: []const u8) bool {
    if (hash.len != 71 or !std.mem.eql(u8, hash[0..7], "sha256-")) return false;
    for (hash[7..]) |byte| if (!((byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

pub fn validUrl(url: []const u8) bool {
    return url.len > "https://".len and std.mem.startsWith(u8, url, "https://");
}

pub fn validVersion(version: []const u8) bool {
    if (version.len == 0 or std.mem.indexOfScalar(u8, version, '+') != null) return false;
    const hyphen = std.mem.indexOfScalar(u8, version, '-');
    const core = if (hyphen) |index| version[0..index] else version;
    var fields = std.mem.splitScalar(u8, core, '.');
    var count: usize = 0;
    while (fields.next()) |part| {
        count += 1;
        if (!validNumeric(part)) return false;
    }
    if (count != 3) return false;
    if (hyphen) |index| {
        const prerelease = version[index + 1 ..];
        var identifiers = std.mem.splitScalar(u8, prerelease, '.');
        var identifier_count: usize = 0;
        while (identifiers.next()) |identifier| {
            identifier_count += 1;
            if (identifier.len == 0) return false;
            var numeric = true;
            for (identifier) |byte| {
                const digit = byte >= '0' and byte <= '9';
                numeric = numeric and digit;
                if (!(digit or (byte >= 'a' and byte <= 'z') or
                    (byte >= 'A' and byte <= 'Z') or byte == '-')) return false;
            }
            if (numeric and identifier.len > 1 and identifier[0] == '0') return false;
        }
        if (identifier_count == 0) return false;
    }
    return true;
}

fn validNumeric(field_bytes: []const u8) bool {
    if (field_bytes.len == 0 or (field_bytes.len > 1 and field_bytes[0] == '0')) return false;
    for (field_bytes) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

pub fn validCanonicalName(name: []const u8) bool {
    if (name.len == 0) return false;
    var segment_start: usize = 0;
    for (name, 0..) |byte, index| {
        if (byte == '.') {
            if (!validSegment(name[segment_start..index])) return false;
            segment_start = index + 1;
        }
    }
    return validSegment(name[segment_start..]);
}

fn validSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment[0] < 'a' or segment[0] > 'z') return false;
    for (segment[1..]) |byte| if (!((byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or byte == '-')) return false;
    return true;
}

const ValidationError = error{ Invalid, OutOfMemory };

fn exactFields(item: Value, names: []const []const u8) ValidationError!*value.DictHandle {
    const header = try asDict(item);
    if (header.length() != names.len) return error.Invalid;
    for (0..@as(usize, @intCast(header.length()))) |index| {
        const key = dict.keyAt(header, index);
        if (key != .symbol) return error.Invalid;
        var known = false;
        for (names) |name| known = known or std.mem.eql(u8, intern.get(key.symbol), name);
        if (!known) return error.Invalid;
    }
    for (names) |name| _ = try field(header, name);
    return header;
}

fn field(header: *value.DictHandle, name: []const u8) ValidationError!Value {
    for (0..@as(usize, @intCast(header.length()))) |index| {
        const key = dict.keyAt(header, index);
        if (key == .symbol and std.mem.eql(u8, intern.get(key.symbol), name))
            return dict.valueAt(header, index);
    }
    return error.Invalid;
}

fn asDict(item: Value) ValidationError!*value.DictHandle {
    return switch (item) {
        .dict => |header| header,
        else => error.Invalid,
    };
}

fn ownedUtf8(allocator: std.mem.Allocator, item: Value) ValidationError![]u8 {
    if (!item.isString()) return error.Invalid;
    var cursor = storage.ToUtf8Cursor.init(allocator, item);
    defer cursor.deinit();
    while (true) switch (cursor.advance(65_536) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCodepoint => return error.Invalid,
    }) {
        .pending => {},
        .complete => |bytes| return bytes,
    };
}
