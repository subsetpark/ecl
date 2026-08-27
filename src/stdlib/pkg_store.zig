//! Narrow filesystem authority for immutable package-store entries and locks.
//!
//! Archive inspection and installation delegate to archive.zig's shared
//! hostile-input scanner. This module owns only the public capability table,
//! destination probing, and atomic lock replacement; it exposes no raw handle,
//! rename, or recursive-delete primitive to ECL.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const pkg_lock = @import("../pkg_lock.zig");
const storage = @import("../kernel_storage.zig");
const archive = @import("archive.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const work_quantum = machine.kernel_poll_quantum;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "inspect",
        .doc = "( bytes package-name -- manifest-text ) Validate a source package and return its exact root manifest.",
        .primitive = archive.inspectPackage,
    },
    .{
        .name = "install",
        .doc = "( bytes package-name destination -- regular-file-paths ) Validate and atomically install an immutable package.",
        .primitive = archive.installPackage,
    },
    .{
        .name = "present?",
        .doc = "( destination -- bool ) Return 1 only when an immutable package directory is present.",
        .primitive = present,
    },
    .{
        .name = "verify",
        .doc = "( destination package-name hash -- ) Stream and verify an installed package's sealed source archive.",
        .primitive = verify,
    },
    .{
        .name = "read-seal",
        .doc = "( destination package-name hash -- bytes ) Verify and return an installed package's exact sealed archive bytes.",
        .primitive = readSeal,
    },
    .{
        .name = "write-lock",
        .doc = "( text path -- ) Atomically replace a regular project data file while preserving it on failure.",
        .primitive = writeLock,
    },
    .{
        .name = "write-new",
        .doc = "( text path -- ) Atomically create a project data file without replacing a racing destination.",
        .primitive = writeNew,
    },
    .{
        .name = "gc",
        .doc = "( retained-store-keys -- removed-count ) Remove canonical shared-cache entries absent from every retained key.",
        .primitive = collectGarbage,
    },
};

fn verify(evaluator: *Machine) MachineError!void {
    return startSealDriver(evaluator, .verify);
}

fn readSeal(evaluator: *Machine) MachineError!void {
    return startSealDriver(evaluator, .read);
}

const SealMode = enum { verify, read };

fn startSealDriver(evaluator: *Machine, mode: SealMode) MachineError!void {
    try evaluator.require(3);
    var hash_value = try evaluator.popValue();
    errdefer hash_value.deinit();
    if (!hash_value.borrow().isString()) return evaluator.typeError("a package hash");
    var package_value = try evaluator.popValue();
    errdefer package_value.deinit();
    if (!package_value.borrow().isString()) return evaluator.typeError("a package name");
    var destination_value = try evaluator.popValue();
    errdefer destination_value.deinit();
    if (!destination_value.borrow().isString()) return evaluator.typeError("a string destination");
    const io = evaluator.unit.inherited.host_io orelse {
        const failure = evaluator.fail(.io, "package verification is unavailable");
        evaluator.addErrorPath(destination_value.borrow());
        return failure;
    };
    const destination_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), destination_value.borrow());
    const package_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), package_value.borrow());
    const hash_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), hash_value.borrow());
    try evaluator.startDriver(VerifyDriver{
        .mode = mode,
        .allocator = evaluator.allocator(),
        .io = io,
        .destination_value = .init(destination_value.take()),
        .package_value = .init(package_value.take()),
        .hash_value = .init(hash_value.take()),
        .state = .{ .encode_destination = .{
            .destination = .init(destination_encoder),
            .package = .init(package_encoder),
            .hash = .init(hash_encoder),
        } },
        // SAFETY: each hashed slice is fully initialized by readPositionalAll before use.
        .buffer = undefined,
    });
}

const VerifyDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    mode: SealMode,
    allocator: std.mem.Allocator,
    io: std.Io,
    destination_value: heap.Owned(Value),
    package_value: heap.Owned(Value),
    hash_value: heap.Owned(Value),
    state: State,
    buffer: [work_quantum]u8,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    digest: [32]u8 = @splat(0),
    rendered: [64]u8 = @splat(0),
    const Paths = struct {
        destination: heap.Owned([]u8),
        package: heap.Owned([]u8),
        hash: heap.Owned([]u8),
        seal: heap.Owned([]u8),

        fn deinit(self: *Paths, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            self.seal.deinit(releases, allocator);
            self.hash.deinit(releases, allocator);
            self.package.deinit(releases, allocator);
            self.destination.deinit(releases, allocator);
        }
    };
    const State = union(enum) {
        encode_destination: struct {
            destination: heap.Owned(storage.ToUtf8Cursor),
            package: heap.Owned(storage.ToUtf8Cursor),
            hash: heap.Owned(storage.ToUtf8Cursor),
        },
        encode_package: struct {
            destination: heap.Owned([]u8),
            package: heap.Owned(storage.ToUtf8Cursor),
            hash: heap.Owned(storage.ToUtf8Cursor),
        },
        encode_hash: struct {
            destination: heap.Owned([]u8),
            package: heap.Owned([]u8),
            hash: heap.Owned(storage.ToUtf8Cursor),
        },
        prepare_open: struct {
            destination: heap.Owned([]u8),
            package: heap.Owned([]u8),
            hash: heap.Owned([]u8),
        },
        open: Paths,
        stat: struct { paths: Paths, file: std.Io.File },
        read: struct {
            paths: Paths,
            file: std.Io.File,
            size: u64,
            offset: u64,
            contents: ?heap.Owned([]u8),
        },
        compare: struct { paths: Paths, contents: ?heap.Owned([]u8) },
        materialize: struct {
            paths: Paths,
            contents: heap.Owned([]u8),
            materializer: heap.Owned(storage.ByteListMaterializer),
        },
        complete: struct { paths: Paths, contents: heap.Owned([]u8) },

        fn deinit(self: *State, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, io: std.Io) void {
            switch (self.*) {
                .encode_destination => |*encode| {
                    encode.hash.deinit(releases, allocator);
                    encode.package.deinit(releases, allocator);
                    encode.destination.deinit(releases, allocator);
                },
                .encode_package => |*encode| {
                    encode.hash.deinit(releases, allocator);
                    encode.package.deinit(releases, allocator);
                    encode.destination.deinit(releases, allocator);
                },
                .encode_hash => |*encode| {
                    encode.hash.deinit(releases, allocator);
                    encode.package.deinit(releases, allocator);
                    encode.destination.deinit(releases, allocator);
                },
                .prepare_open => |*prepare| {
                    prepare.hash.deinit(releases, allocator);
                    prepare.package.deinit(releases, allocator);
                    prepare.destination.deinit(releases, allocator);
                },
                .open => |*paths| paths.deinit(releases, allocator),
                .stat => |*stat_state| {
                    stat_state.file.close(io);
                    stat_state.paths.deinit(releases, allocator);
                },
                .read => |*read_state| {
                    read_state.file.close(io);
                    if (read_state.contents) |*contents| contents.deinit(releases, allocator);
                    read_state.paths.deinit(releases, allocator);
                },
                .compare => |*compare_state| {
                    if (compare_state.contents) |*contents| contents.deinit(releases, allocator);
                    compare_state.paths.deinit(releases, allocator);
                },
                .materialize => |*materialize_state| {
                    materialize_state.materializer.deinit(releases, allocator);
                    materialize_state.contents.deinit(releases, allocator);
                    materialize_state.paths.deinit(releases, allocator);
                },
                .complete => |*complete| {
                    complete.contents.deinit(releases, allocator);
                    complete.paths.deinit(releases, allocator);
                },
            }
        }
    };

    pub fn advance(evaluator: *Machine, self: *VerifyDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .encode_destination => |*encode| self.encodeDestination(evaluator, encode),
            .encode_package => |*encode| self.encodePackage(evaluator, encode),
            .encode_hash => |*encode| self.encodeHash(evaluator, encode),
            .prepare_open => |*prepare| self.prepareOpen(prepare),
            .open => |*paths| self.open(evaluator, paths),
            .stat => |*stat_state| self.stat(evaluator, stat_state),
            .read => |*read_state| self.read(evaluator, read_state),
            .compare => |*compare_state| self.compare(evaluator, compare_state),
            .materialize => |*materialize_state| self.materialize(evaluator, materialize_state),
            .complete => unreachable,
        };
    }

    fn encodeDestination(
        self: *VerifyDriver,
        evaluator: *Machine,
        encode: *@FieldType(State, "encode_destination"),
    ) MachineError!machine.WorkProgress {
        switch (encode.destination.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package destination contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |destination| {
                if (destination.len == 0) {
                    self.allocator.free(destination);
                    return self.failDomain(evaluator, "package destination is empty");
                }
                const package_encoder = encode.package.take();
                const hash_encoder = encode.hash.take();
                encode.destination.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .encode_package = .{
                    .destination = .init(destination),
                    .package = .init(package_encoder),
                    .hash = .init(hash_encoder),
                } };
                return .yielded;
            },
        }
    }

    fn encodePackage(
        self: *VerifyDriver,
        evaluator: *Machine,
        encode: *@FieldType(State, "encode_package"),
    ) MachineError!machine.WorkProgress {
        switch (encode.package.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package name contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |package| {
                if (package.len == 0) {
                    self.allocator.free(package);
                    return self.failDomain(evaluator, "package name is empty");
                }
                const destination = encode.destination.take();
                const hash_encoder = encode.hash.take();
                encode.package.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .encode_hash = .{
                    .destination = .init(destination),
                    .package = .init(package),
                    .hash = .init(hash_encoder),
                } };
                return .yielded;
            },
        }
    }

    fn encodeHash(
        self: *VerifyDriver,
        evaluator: *Machine,
        encode: *@FieldType(State, "encode_hash"),
    ) MachineError!machine.WorkProgress {
        switch (encode.hash.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package hash contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |hash| {
                if (!isSha256(hash)) {
                    self.allocator.free(hash);
                    return self.failDomain(evaluator, "a package hash is sha256- and 64 lowercase hex digits");
                }
                const destination = encode.destination.take();
                const package = encode.package.take();
                encode.hash.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .prepare_open = .{
                    .destination = .init(destination),
                    .package = .init(package),
                    .hash = .init(hash),
                } };
                return .yielded;
            },
        }
    }

    fn prepareOpen(
        self: *VerifyDriver,
        prepare: *@FieldType(State, "prepare_open"),
    ) error{OutOfMemory}!machine.WorkProgress {
        const seal = try std.fs.path.join(self.allocator, &.{
            prepare.destination.borrow(),
            archive.package_seal_name,
        });
        self.state = .{ .open = .{
            .destination = .init(prepare.destination.take()),
            .package = .init(prepare.package.take()),
            .hash = .init(prepare.hash.take()),
            .seal = .init(seal),
        } };
        return .yielded;
    }

    fn open(
        self: *VerifyDriver,
        evaluator: *Machine,
        paths: *Paths,
    ) MachineError!machine.WorkProgress {
        const file = std.Io.Dir.cwd().openFile(self.io, paths.seal.borrow(), .{}) catch |err|
            return self.failIo(evaluator, "cannot open installed package archive seal", err);
        const moved_paths = paths.*;
        self.state = .{ .stat = .{ .paths = moved_paths, .file = file } };
        return .yielded;
    }

    fn stat(
        self: *VerifyDriver,
        evaluator: *Machine,
        stat_state: *@FieldType(State, "stat"),
    ) MachineError!machine.WorkProgress {
        const info = stat_state.file.stat(self.io) catch |err|
            return self.failIo(evaluator, "cannot inspect installed package archive seal", err);
        const contents: ?heap.Owned([]u8) = if (self.mode == .read) contents: {
            const length = std.math.cast(usize, info.size) orelse
                return self.failIoName(evaluator, "installed package archive seal is too large to materialize");
            break :contents .init(try self.allocator.alloc(u8, length));
        } else null;
        const paths = stat_state.paths;
        const file = stat_state.file;
        self.state = .{ .read = .{
            .paths = paths,
            .file = file,
            .size = info.size,
            .offset = 0,
            .contents = contents,
        } };
        return .yielded;
    }

    fn read(
        self: *VerifyDriver,
        evaluator: *Machine,
        read_state: *@FieldType(State, "read"),
    ) MachineError!machine.WorkProgress {
        if (read_state.offset == read_state.size) {
            const paths = read_state.paths;
            const contents = read_state.contents;
            read_state.file.close(self.io);
            self.hasher.final(&self.digest);
            self.rendered = std.fmt.bytesToHex(self.digest, .lower);
            self.state = .{ .compare = .{
                .paths = paths,
                .contents = contents,
            } };
            return .yielded;
        }
        const amount: usize = @intCast(@min(@as(u64, work_quantum), read_state.size - read_state.offset));
        const target = if (read_state.contents) |contents|
            contents.borrow()[@intCast(read_state.offset)..][0..amount]
        else
            self.buffer[0..amount];
        const read_amount = read_state.file.readPositionalAll(self.io, target, read_state.offset) catch |err|
            return self.failIo(evaluator, "cannot read installed package archive seal", err);
        if (read_amount != amount)
            return self.failIoName(evaluator, "installed package archive seal changed while being read");
        self.hasher.update(target);
        read_state.offset += amount;
        return .yielded;
    }

    fn compare(
        self: *VerifyDriver,
        evaluator: *Machine,
        compare_state: *@FieldType(State, "compare"),
    ) MachineError!machine.WorkProgress {
        if (!std.mem.eql(u8, compare_state.paths.hash.borrow()[7..], &self.rendered))
            return evaluator.failFmt(
                .domain,
                "package `{s}` archive seal does not match lock hash",
                .{compare_state.paths.package.borrow()},
            );
        if (self.mode == .verify) return .completed;
        const paths = compare_state.paths;
        const contents = compare_state.contents.?.take();
        self.state = .{ .materialize = .{
            .paths = paths,
            .contents = .init(contents),
            .materializer = .init(.init(self.allocator, contents)),
        } };
        return .yielded;
    }

    fn materialize(
        self: *VerifyDriver,
        evaluator: *Machine,
        materialize_state: *@FieldType(State, "materialize"),
    ) MachineError!machine.WorkProgress {
        return switch (try materialize_state.materializer.borrowMut().advance(work_quantum)) {
            .pending => .yielded,
            .complete => |result| complete: {
                const paths = materialize_state.paths;
                const contents = materialize_state.contents.take();
                materialize_state.materializer.deinit(
                    evaluator.releaseDomain(),
                    evaluator.allocator(),
                );
                self.state = .{ .complete = .{
                    .paths = paths,
                    .contents = .init(contents),
                } };
                break :complete .{ .output = result };
            },
        };
    }

    fn failDomain(self: *VerifyDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    fn failIo(self: *VerifyDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(
            .io,
            "{s} for package `{s}`: {s}",
            .{ message, self.packageBytes(), @errorName(err) },
        );
        evaluator.addErrorPath(self.destination_value.borrow());
        return failure;
    }

    fn failIoName(self: *VerifyDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.failFmt(.io, "{s} for package `{s}`", .{ message, self.packageBytes() });
        evaluator.addErrorPath(self.destination_value.borrow());
        return failure;
    }

    fn packageBytes(self: *VerifyDriver) []const u8 {
        return switch (self.state) {
            .encode_hash => |*encode| encode.package.borrow(),
            .prepare_open => |*prepare| prepare.package.borrow(),
            .open => |*paths| paths.package.borrow(),
            .stat => |*stat_state| stat_state.paths.package.borrow(),
            .read => |*read_state| read_state.paths.package.borrow(),
            .compare => |*compare_state| compare_state.paths.package.borrow(),
            .materialize => |*materialize_state| materialize_state.paths.package.borrow(),
            .complete => |*complete| complete.paths.package.borrow(),
            .encode_destination, .encode_package => unreachable,
        };
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *VerifyDriver,
    ) bool {
        self.state.deinit(releases, allocator, self.io);
        self.hash_value.deinit(releases, allocator);
        self.package_value.deinit(releases, allocator);
        self.destination_value.deinit(releases, allocator);
        allocator.destroy(self);
        return true;
    }
};

fn isSha256(hash: []const u8) bool {
    if (hash.len != 71 or !std.mem.eql(u8, hash[0..7], "sha256-")) return false;
    for (hash[7..]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn present(evaluator: *Machine) MachineError!void {
    var path_value = try evaluator.popValue();
    errdefer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string destination");
    const io = evaluator.unit.inherited.host_io orelse {
        const failure = evaluator.fail(.io, "package store inspection is unavailable");
        evaluator.addErrorPath(path_value.borrow());
        return failure;
    };
    const encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), path_value.borrow());
    try evaluator.startDriver(PresentDriver{
        .allocator = evaluator.allocator(),
        .io = io,
        .path_value = .init(path_value.take()),
        .encoder = .init(encoder),
    });
}

const PresentDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    allocator: std.mem.Allocator,
    io: std.Io,
    path_value: heap.Owned(Value),
    encoder: heap.Owned(storage.ToUtf8Cursor),
    path: ?heap.Owned([]u8) = null,

    pub fn advance(evaluator: *Machine, self: *PresentDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.path == null) switch (self.encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package destination contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| {
                if (path.len == 0) {
                    self.allocator.free(path);
                    return self.failDomain(evaluator, "package destination is empty");
                }
                self.path = .init(path);
                return .yielded;
            },
        };
        const info = std.Io.Dir.cwd().statFile(
            self.io,
            self.path.?.borrow(),
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return .{ .output = .{ .int = 0 } },
            else => return self.failIo(evaluator, "cannot inspect package destination", err),
        };
        if (info.kind != .directory)
            return self.failIoName(evaluator, "package destination is not a real directory");
        return .{ .output = .{ .int = 1 } };
    }

    fn failDomain(self: *PresentDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    fn failIo(self: *PresentDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(.io, "{s}: {s}", .{ message, @errorName(err) });
        evaluator.addErrorPath(self.path_value.borrow());
        return failure;
    }

    fn failIoName(self: *PresentDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.path_value.borrow());
        return failure;
    }
};

fn collectGarbage(evaluator: *Machine) MachineError!void {
    var retained_value = try evaluator.popValue();
    errdefer retained_value.deinit();
    if (retained_value.borrow() != .list)
        return evaluator.typeError("a list of retained package store keys");
    try evaluator.startDriver(GcDriver{
        .allocator = evaluator.allocator(),
        .io = evaluator.unit.inherited.host_io orelse {
            return evaluator.fail(.io, "package store garbage collection is unavailable");
        },
        .retained_value = .init(retained_value.take()),
        .retained = std.StringHashMap(void).init(evaluator.allocator()),
    });
}

var next_gc_identity: std.atomic.Value(u64) = .init(1);

const GcDeleteFrame = struct {
    parent: ?*GcDeleteFrame,
    dir: ?std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
    name: ?[]u8,
};

const GcDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    retained_value: heap.Owned(Value),
    retained: std.StringHashMap(void),
    retained_keys: std.ArrayList([]u8) = .empty,
    retained_index: usize = 0,
    retained_capacity_ready: bool = false,
    key_cursor: ?storage.ToUtf8Cursor = null,
    environ_cursor: ?machine.Environ.LookupCursor = null,
    root_path: ?[]u8 = null,
    root_dir: ?std.Io.Dir = null,
    iterator: ?std.Io.Dir.Iterator = null,
    candidate_source: ?[]u8 = null,
    candidate_trash: ?[]u8 = null,
    delete_frame: ?*GcDeleteFrame = null,
    removed: usize = 0,
    retire_index: usize = 0,
    retire_phase: enum { resources, delete_frames, retained, finish } = .resources,
    phase: enum {
        keys,
        env_ecl_cache,
        env_xdg_cache,
        env_home,
        open_root,
        scan,
        detach_candidate,
        open_candidate,
        delete_tree,
        delete_root,
        finish,
    } = .keys,

    pub fn advance(evaluator: *Machine, self: *GcDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.phase) {
            .keys => self.encodeKeys(evaluator),
            .env_ecl_cache => self.lookupEnvironment(evaluator, "ECL_CACHE", .env_xdg_cache, .direct),
            .env_xdg_cache => self.lookupEnvironment(evaluator, "XDG_CACHE_HOME", .env_home, .xdg),
            .env_home => self.lookupEnvironment(evaluator, "HOME", .finish, .home),
            .open_root => self.openRoot(evaluator),
            .scan => self.scan(evaluator),
            .detach_candidate => self.detachCandidate(evaluator),
            .open_candidate => self.openCandidate(evaluator),
            .delete_tree => self.deleteTree(evaluator),
            .delete_root => self.deleteRoot(evaluator),
            .finish => if (self.root_path == null)
                evaluator.fail(
                    .io,
                    "pkg.store.gc needs ECL_CACHE, XDG_CACHE_HOME, or HOME to select a package store",
                )
            else
                .{ .output = .{ .int = @intCast(self.removed) } },
        };
    }

    fn encodeKeys(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const count: usize = @intCast(self.retained_value.borrow().list.length());
        if (!self.retained_capacity_ready) {
            try self.retained.ensureTotalCapacity(@intCast(count));
            try self.retained_keys.ensureTotalCapacity(self.allocator, count);
            self.retained_capacity_ready = true;
            return .yielded;
        }
        if (self.retained_index == count) {
            self.phase = .env_ecl_cache;
            return .yielded;
        }
        if (self.key_cursor == null) {
            const item = list.atUnchecked(self.retained_value.borrow(), self.retained_index);
            if (!item.isString())
                return evaluator.failAtIndex(
                    .type,
                    "pkg.store.gc expects string store keys",
                    self.retained_index,
                );
            self.key_cursor = .init(self.allocator, item);
        }
        return switch (self.key_cursor.?.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.failAtIndex(
                .domain,
                "a retained package store key contains an invalid Unicode scalar",
                self.retained_index,
            ),
        }) {
            .pending => .yielded,
            .complete => |key| complete: {
                self.key_cursor.?.deinit();
                self.key_cursor = null;
                if (!validStoreKey(key)) {
                    self.allocator.free(key);
                    return evaluator.failAtIndex(
                        .domain,
                        "pkg.store.gc expects canonical name-version-hash store keys",
                        self.retained_index,
                    );
                }
                if (self.retained.contains(key)) {
                    self.allocator.free(key);
                } else {
                    self.retained.putAssumeCapacityNoClobber(key, {});
                    self.retained_keys.appendAssumeCapacity(key);
                }
                self.retained_index += 1;
                break :complete .yielded;
            },
        };
    }

    const RootKind = enum { direct, xdg, home };

    fn lookupEnvironment(
        self: *GcDriver,
        evaluator: *Machine,
        name: []const u8,
        missing: @TypeOf(self.phase),
        kind: RootKind,
    ) MachineError!machine.WorkProgress {
        if (self.environ_cursor == null) self.environ_cursor = evaluator.environLookup(name);
        return switch (self.environ_cursor.?.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |raw| complete: {
                self.environ_cursor = null;
                const bytes = raw orelse "";
                if (bytes.len == 0) {
                    self.phase = missing;
                    break :complete .yielded;
                }
                self.root_path = switch (kind) {
                    .direct => try self.allocator.dupe(u8, bytes),
                    .xdg => std.fs.path.join(self.allocator, &.{ bytes, "ecl", "pkg" }) catch
                        return error.OutOfMemory,
                    .home => std.fs.path.join(self.allocator, &.{ bytes, ".cache", "ecl", "pkg" }) catch
                        return error.OutOfMemory,
                };
                self.phase = .open_root;
                break :complete .yielded;
            },
        };
    }

    fn openRoot(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        self.root_dir = std.Io.Dir.cwd().openDir(self.io, self.root_path.?, .{
            .follow_symlinks = false,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                self.phase = .finish;
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot open package store for garbage collection", err),
        };
        self.iterator = self.root_dir.?.iterate();
        self.phase = .scan;
        return .yielded;
    }

    fn scan(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const entry = self.iterator.?.next(self.io) catch |err|
            return self.failIo(evaluator, "cannot enumerate package store for garbage collection", err);
        if (entry == null) {
            self.iterator = null;
            self.phase = .finish;
            return .yielded;
        }
        if (entry.?.kind != .directory) return .yielded;
        const stale = std.mem.startsWith(u8, entry.?.name, ".ecl-gc-");
        if (!stale and (!validStoreKey(entry.?.name) or self.retained.contains(entry.?.name)))
            return .yielded;
        if (stale) {
            self.candidate_trash = try self.allocator.dupe(u8, entry.?.name);
            self.phase = .open_candidate;
        } else {
            self.candidate_source = try self.allocator.dupe(u8, entry.?.name);
            self.phase = .detach_candidate;
        }
        return .yielded;
    }

    fn detachCandidate(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const identity = next_gc_identity.fetchAdd(1, .monotonic);
        const trash_name = try std.fmt.allocPrint(
            self.allocator,
            ".ecl-gc-{x}-{s}",
            .{ identity, self.candidate_source.? },
        );
        self.root_dir.?.rename(self.candidate_source.?, self.root_dir.?, trash_name, self.io) catch |err| {
            self.allocator.free(trash_name);
            switch (err) {
                // Keep the candidate phase: the next bounded advance mints a
                // new monotonic identity, so a stale trash-name collision
                // cannot repeat the same rename indefinitely.
                error.DirNotEmpty => return .yielded,
                error.FileNotFound => {
                    self.allocator.free(self.candidate_source.?);
                    self.candidate_source = null;
                    self.phase = .scan;
                    return .yielded;
                },
                else => {
                    return self.failIo(evaluator, "cannot detach unreferenced package store entry", err);
                },
            }
        };
        self.allocator.free(self.candidate_source.?);
        self.candidate_source = null;
        self.candidate_trash = trash_name;
        self.removed += 1;
        self.phase = .open_candidate;
        return .yielded;
    }

    fn openCandidate(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const directory = self.root_dir.?.openDir(self.io, self.candidate_trash.?, .{
            .follow_symlinks = false,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                self.finishCandidate();
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot open detached package store entry", err),
        };
        const frame = self.allocator.create(GcDeleteFrame) catch |err| {
            directory.close(self.io);
            return err;
        };
        frame.* = .{
            .parent = null,
            .dir = directory,
            .iterator = directory.iterate(),
            .name = null,
        };
        self.delete_frame = frame;
        self.phase = .delete_tree;
        return .yielded;
    }

    fn deleteTree(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const frame = self.delete_frame.?;
        const entry = frame.iterator.next(self.io) catch |err|
            return self.failIo(evaluator, "cannot enumerate detached package store entry", err);
        if (entry) |item| {
            if (item.kind != .directory) {
                frame.dir.?.deleteFile(self.io, item.name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return self.failIo(evaluator, "cannot remove detached package file", err),
                };
                return .yielded;
            }
            const name = try self.allocator.dupe(u8, item.name);
            const directory = frame.dir.?.openDir(self.io, name, .{
                .follow_symlinks = false,
                .iterate = true,
            }) catch |err| {
                self.allocator.free(name);
                return self.failIo(evaluator, "cannot open detached package directory", err);
            };
            const child = self.allocator.create(GcDeleteFrame) catch |err| {
                directory.close(self.io);
                self.allocator.free(name);
                return err;
            };
            child.* = .{
                .parent = frame,
                .dir = directory,
                .iterator = directory.iterate(),
                .name = name,
            };
            self.delete_frame = child;
            return .yielded;
        }

        frame.dir.?.close(self.io);
        frame.dir = null;
        if (frame.parent) |parent| {
            parent.dir.?.deleteDir(self.io, frame.name.?) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return self.failIo(evaluator, "cannot remove detached package directory", err),
            };
            self.allocator.free(frame.name.?);
            self.delete_frame = parent;
            self.allocator.destroy(frame);
            return .yielded;
        }
        self.delete_frame = null;
        self.allocator.destroy(frame);
        self.phase = .delete_root;
        return .yielded;
    }

    fn deleteRoot(self: *GcDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        self.root_dir.?.deleteDir(self.io, self.candidate_trash.?) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return self.failIo(evaluator, "cannot remove detached package store entry", err),
        };
        self.finishCandidate();
        return .yielded;
    }

    fn finishCandidate(self: *GcDriver) void {
        if (self.candidate_trash) |name| self.allocator.free(name);
        self.candidate_trash = null;
        self.iterator = self.root_dir.?.iterate();
        self.phase = .scan;
    }

    fn failIo(self: *GcDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        return evaluator.failFmt(.io, "{s} `{s}`: {s}", .{ message, self.root_path orelse "", @errorName(err) });
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *GcDriver,
    ) bool {
        switch (self.retire_phase) {
            .resources => {
                if (self.root_dir) |directory| directory.close(self.io);
                self.root_dir = null;
                if (self.key_cursor) |*cursor| cursor.deinit();
                self.key_cursor = null;
                if (self.root_path) |path| allocator.free(path);
                self.root_path = null;
                if (self.candidate_source) |name| allocator.free(name);
                self.candidate_source = null;
                if (self.candidate_trash) |name| allocator.free(name);
                self.candidate_trash = null;
                self.retained.deinit();
                self.retire_phase = .delete_frames;
                self.retire_index = 0;
                return false;
            },
            .delete_frames => {
                if (self.delete_frame) |frame| {
                    self.delete_frame = frame.parent;
                    if (frame.dir) |directory| directory.close(self.io);
                    if (frame.name) |name| allocator.free(name);
                    allocator.destroy(frame);
                    return false;
                }
                self.retire_phase = .retained;
                self.retire_index = 0;
                return false;
            },
            .retained => {
                if (self.retire_index != self.retained_keys.items.len) {
                    allocator.free(self.retained_keys.items[self.retire_index]);
                    self.retire_index += 1;
                    return false;
                }
                self.retained_keys.deinit(allocator);
                self.retained_value.deinit(releases, allocator);
                self.retire_phase = .finish;
                return false;
            },
            .finish => {
                allocator.destroy(self);
                return true;
            },
        }
    }
};

fn validStoreKey(key: []const u8) bool {
    if (key.len < 67) return false;
    const hash_start = key.len - 64;
    if (key[hash_start - 1] != '-') return false;
    for (key[hash_start..]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    const prefix = key[0 .. hash_start - 1];
    for (prefix, 0..) |byte, index| {
        if (byte != '-' or index == 0 or index + 1 == prefix.len) continue;
        if (pkg_lock.validPackageName(prefix[0..index]) and
            pkg_lock.validVersion(prefix[index + 1 ..])) return true;
    }
    return false;
}

fn writeLock(evaluator: *Machine) MachineError!void {
    return startWriteDriver(evaluator, .replace);
}

fn writeNew(evaluator: *Machine) MachineError!void {
    return startWriteDriver(evaluator, .create);
}

const PublicationMode = enum { replace, create };

fn startWriteDriver(evaluator: *Machine, mode: PublicationMode) MachineError!void {
    try evaluator.require(2);
    var path_value = try evaluator.popValue();
    errdefer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string project file path");
    var text_value = try evaluator.popValue();
    errdefer text_value.deinit();
    if (!text_value.borrow().isString()) return evaluator.typeError("project file text");
    const io = evaluator.unit.inherited.host_io orelse {
        const failure = evaluator.fail(.io, "project file publication is unavailable");
        evaluator.addErrorPath(path_value.borrow());
        return failure;
    };
    const text_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), text_value.borrow());
    const path_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), path_value.borrow());
    try evaluator.startDriver(WriteLockDriver{
        .mode = mode,
        .allocator = evaluator.allocator(),
        .io = io,
        .text_value = .init(text_value.take()),
        .path_value = .init(path_value.take()),
        .state = .{ .encode_text = .{
            .text = .init(text_encoder),
            .path = .init(path_encoder),
        } },
    });
}

var next_lock_identity: std.atomic.Value(u64) = .init(1);

const WriteLockDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    mode: PublicationMode,
    allocator: std.mem.Allocator,
    io: std.Io,
    text_value: heap.Owned(Value),
    path_value: heap.Owned(Value),
    state: State,

    const Paths = struct {
        text: heap.Owned([]u8),
        path: heap.Owned([]u8),

        fn deinit(self: *Paths, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            self.path.deinit(releases, allocator);
            self.text.deinit(releases, allocator);
        }
    };
    const Temporary = struct {
        paths: Paths,
        temp_path: heap.Owned([]u8),

        fn deinit(self: *Temporary, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            self.temp_path.deinit(releases, allocator);
            self.paths.deinit(releases, allocator);
        }
    };
    const OpenTemporary = struct {
        temporary: Temporary,
        file: std.Io.File,
        offset: usize,
    };
    const State = union(enum) {
        encode_text: struct {
            text: heap.Owned(storage.ToUtf8Cursor),
            path: heap.Owned(storage.ToUtf8Cursor),
        },
        encode_path: struct {
            text: heap.Owned([]u8),
            path: heap.Owned(storage.ToUtf8Cursor),
        },
        inspect_initial: Paths,
        make_temp: Paths,
        temp_ready: Temporary,
        write: OpenTemporary,
        sync_close: OpenTemporary,
        recheck: Temporary,
        publish: Temporary,
        published: Temporary,
        cleanup: Temporary,

        fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) void {
            switch (self.*) {
                .encode_text => |*encode| {
                    encode.path.deinit(releases, allocator);
                    encode.text.deinit(releases, allocator);
                },
                .encode_path => |*encode| {
                    encode.path.deinit(releases, allocator);
                    encode.text.deinit(releases, allocator);
                },
                .inspect_initial, .make_temp => |*paths| paths.deinit(releases, allocator),
                .temp_ready, .recheck, .publish, .published, .cleanup => |*temporary| temporary.deinit(releases, allocator),
                .write, .sync_close => |*open| {
                    open.file.close(io);
                    open.temporary.deinit(releases, allocator);
                },
            }
        }
    };

    pub fn advance(evaluator: *Machine, self: *WriteLockDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .encode_text => |*encode| self.encodeText(evaluator, encode),
            .encode_path => |*encode| self.encodePath(evaluator, encode),
            .inspect_initial => |*paths| self.inspectInitial(evaluator, paths),
            .make_temp => |*paths| self.makeTemp(paths),
            .temp_ready => |*temporary| self.createTemp(evaluator, temporary),
            .write => |*open| self.writeChunk(evaluator, open),
            .sync_close => |*open| self.syncClose(evaluator, open),
            .recheck => |*temporary| self.recheck(evaluator, temporary),
            .publish => |*temporary| self.publish(evaluator, temporary),
            .published, .cleanup => unreachable,
        };
    }

    fn encodeText(
        self: *WriteLockDriver,
        evaluator: *Machine,
        encode: *@FieldType(State, "encode_text"),
    ) MachineError!machine.WorkProgress {
        switch (encode.text.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "project file text contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |text| {
                const path_encoder = encode.path.take();
                encode.text.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .encode_path = .{
                    .text = .init(text),
                    .path = .init(path_encoder),
                } };
                return .yielded;
            },
        }
    }

    fn encodePath(
        self: *WriteLockDriver,
        evaluator: *Machine,
        encode: *@FieldType(State, "encode_path"),
    ) MachineError!machine.WorkProgress {
        switch (encode.path.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "project file path contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| {
                if (path.len == 0) {
                    self.allocator.free(path);
                    return self.failDomain(evaluator, "project file path is empty");
                }
                const text = encode.text.take();
                encode.path.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .inspect_initial = .{
                    .text = .init(text),
                    .path = .init(path),
                } };
                return .yielded;
            },
        }
    }

    fn inspectInitial(
        self: *WriteLockDriver,
        evaluator: *Machine,
        paths: *Paths,
    ) MachineError!machine.WorkProgress {
        const info = std.Io.Dir.cwd().statFile(
            self.io,
            paths.path.borrow(),
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const moved = paths.*;
                self.state = .{ .make_temp = moved };
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot inspect project file target", err),
        };
        if (info.kind != .file) return self.failNotRegular(evaluator);
        if (self.mode == .create) return self.failAlreadyExists(evaluator);
        const moved = paths.*;
        self.state = .{ .make_temp = moved };
        return .yielded;
    }

    fn makeTemp(
        self: *WriteLockDriver,
        paths: *Paths,
    ) error{OutOfMemory}!machine.WorkProgress {
        const identity = next_lock_identity.fetchAdd(1, .monotonic);
        const path = paths.path.borrow();
        const parent = std.fs.path.dirname(path) orelse ".";
        const temp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}{c}.ecl-lock-{x}-{s}",
            .{ parent, std.fs.path.sep, identity, std.fs.path.basename(path) },
        );
        const moved = paths.*;
        self.state = .{ .temp_ready = .{
            .paths = moved,
            .temp_path = .init(temp_path),
        } };
        return .yielded;
    }

    fn createTemp(
        self: *WriteLockDriver,
        evaluator: *Machine,
        temporary: *Temporary,
    ) MachineError!machine.WorkProgress {
        const file = std.Io.Dir.cwd().createFile(self.io, temporary.temp_path.borrow(), .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const paths = temporary.paths;
                temporary.temp_path.deinit(evaluator.releaseDomain(), self.allocator);
                self.state = .{ .make_temp = paths };
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot create project temporary file", err),
        };
        const moved = temporary.*;
        self.state = .{ .write = .{
            .temporary = moved,
            .file = file,
            .offset = 0,
        } };
        return .yielded;
    }

    fn writeChunk(
        self: *WriteLockDriver,
        evaluator: *Machine,
        open: *OpenTemporary,
    ) MachineError!machine.WorkProgress {
        const text = open.temporary.paths.text.borrow();
        if (open.offset != text.len) {
            const end = @min(open.offset + work_quantum, text.len);
            open.file.writePositionalAll(self.io, text[open.offset..end], open.offset) catch |err|
                return self.failIo(evaluator, "cannot write project temporary file", err);
            open.offset = end;
            return .yielded;
        }
        const moved = open.*;
        self.state = .{ .sync_close = moved };
        return .yielded;
    }

    fn syncClose(
        self: *WriteLockDriver,
        evaluator: *Machine,
        open: *OpenTemporary,
    ) MachineError!machine.WorkProgress {
        open.file.sync(self.io) catch |err|
            return self.failIo(evaluator, "cannot synchronize project temporary file", err);
        const temporary = open.temporary;
        open.file.close(self.io);
        self.state = .{ .recheck = temporary };
        return .yielded;
    }

    fn recheck(
        self: *WriteLockDriver,
        evaluator: *Machine,
        temporary: *Temporary,
    ) MachineError!machine.WorkProgress {
        const info = std.Io.Dir.cwd().statFile(
            self.io,
            temporary.paths.path.borrow(),
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const moved = temporary.*;
                self.state = .{ .publish = moved };
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot inspect project file target", err),
        };
        if (info.kind != .file) return self.failNotRegular(evaluator);
        if (self.mode == .create) return self.failAlreadyExists(evaluator);
        const moved = temporary.*;
        self.state = .{ .publish = moved };
        return .yielded;
    }

    fn publish(
        self: *WriteLockDriver,
        evaluator: *Machine,
        temporary: *Temporary,
    ) MachineError!machine.WorkProgress {
        const path = temporary.paths.path.borrow();
        const parent_path = std.fs.path.dirname(path) orelse ".";
        var parent = std.Io.Dir.cwd().openDir(self.io, parent_path, .{ .follow_symlinks = false }) catch |err|
            return self.failIo(evaluator, "cannot open project file parent", err);
        defer parent.close(self.io);
        const old_name = std.fs.path.basename(temporary.temp_path.borrow());
        const new_name = std.fs.path.basename(path);
        switch (self.mode) {
            .replace => parent.rename(old_name, parent, new_name, self.io) catch |err|
                return self.failIo(evaluator, "cannot publish project file", err),
            .create => archive.renamePreserve(parent, old_name, new_name, self.io) catch |err| switch (err) {
                error.PathAlreadyExists => return self.failAlreadyExists(evaluator),
                else => return self.failIo(evaluator, "cannot publish project file", err),
            },
        }
        const moved = temporary.*;
        self.state = .{ .published = moved };
        return .completed;
    }

    fn failDomain(self: *WriteLockDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    fn failIo(self: *WriteLockDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(.io, "{s}: {s}", .{ message, @errorName(err) });
        evaluator.addErrorPath(self.path_value.borrow());
        return failure;
    }

    fn failAlreadyExists(self: *WriteLockDriver, evaluator: *Machine) MachineError {
        const failure = evaluator.failFmt(
            .io,
            "project file `{s}` already exists",
            .{self.pathBytes()},
        );
        evaluator.addErrorPath(self.path_value.borrow());
        return failure;
    }

    fn failNotRegular(self: *WriteLockDriver, evaluator: *Machine) MachineError {
        const failure = evaluator.failFmt(
            .io,
            "project file `{s}` is not a regular file",
            .{self.pathBytes()},
        );
        evaluator.addErrorPath(self.path_value.borrow());
        return failure;
    }

    fn pathBytes(self: *WriteLockDriver) []const u8 {
        return switch (self.state) {
            .inspect_initial, .make_temp => |*paths| paths.path.borrow(),
            .temp_ready, .recheck, .publish, .published, .cleanup => |*temporary| temporary.paths.path.borrow(),
            .write, .sync_close => |*open| open.temporary.paths.path.borrow(),
            .encode_text, .encode_path => unreachable,
        };
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *WriteLockDriver,
    ) bool {
        switch (self.state) {
            .write, .sync_close => |*open| {
                const temporary = open.temporary;
                open.file.close(self.io);
                self.state = .{ .cleanup = temporary };
                return false;
            },
            .recheck, .publish => |*temporary| {
                const moved = temporary.*;
                self.state = .{ .cleanup = moved };
                return false;
            },
            .cleanup => |*temporary| {
                const moved = temporary.*;
                std.Io.Dir.cwd().deleteFile(self.io, temporary.temp_path.borrow()) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => std.log.err("project file rollback could not remove its temporary file: {s}", .{@errorName(err)}),
                };
                self.state = .{ .published = moved };
                return false;
            },
            else => {},
        }
        self.state.deinit(releases, allocator, self.io);
        self.text_value.deinit(releases, allocator);
        self.path_value.deinit(releases, allocator);
        allocator.destroy(self);
        return true;
    }
};
