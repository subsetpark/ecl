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
            materializer: heap.Owned(list.ByteListMaterializer),
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
        .state = .keys_capacity,
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
    removed: usize = 0,
    state: State,

    const Root = struct { path: []u8, dir: std.Io.Dir };
    const Scan = struct { root: Root, iterator: std.Io.Dir.Iterator };
    const CleanupRoot = union(enum) {
        none,
        path: []u8,
        root: Root,
    };
    const State = union(enum) {
        keys_capacity,
        keys: usize,
        key: struct { index: usize, cursor: storage.ToUtf8Cursor },
        env_ecl_start,
        env_ecl: machine.Environ.LookupCursor,
        env_xdg_start,
        env_xdg: machine.Environ.LookupCursor,
        env_home_start,
        env_home: machine.Environ.LookupCursor,
        open_root: []u8,
        scan: Scan,
        detach: struct { scan: Scan, source: []u8 },
        open_candidate: struct { scan: Scan, trash: []u8 },
        delete_tree: struct { scan: Scan, trash: []u8, frame: *GcDeleteFrame },
        delete_root: struct { scan: Scan, trash: []u8 },
        complete_path: []u8,
        complete_root: Root,
        no_environment,
        cleanup_frame: struct { root: CleanupRoot, frame: *GcDeleteFrame },
        cleanup_root: CleanupRoot,
        cleanup_keys: usize,
        cleanup_value,
        cleanup_destroy,
    };

    pub fn advance(evaluator: *Machine, self: *GcDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.state) {
            .keys_capacity => {
                const count: usize = @intCast(self.retained_value.borrow().list.length());
                try self.retained.ensureTotalCapacity(@intCast(count));
                try self.retained_keys.ensureTotalCapacity(self.allocator, count);
                self.state = .{ .keys = 0 };
            },
            .keys => |index| {
                const count: usize = @intCast(self.retained_value.borrow().list.length());
                if (index == count) {
                    self.state = .env_ecl_start;
                } else {
                    const item = list.atUnchecked(self.retained_value.borrow(), index);
                    if (!item.isString())
                        return evaluator.failAtIndex(
                            .type,
                            "pkg.store.gc expects string store keys",
                            index,
                        );
                    self.state = .{ .key = .{
                        .index = index,
                        .cursor = .init(self.allocator, item),
                    } };
                }
            },
            .key => |*key_state| switch (key_state.cursor.advance(work_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCodepoint => return evaluator.failAtIndex(
                    .domain,
                    "a retained package store key contains an invalid Unicode scalar",
                    key_state.index,
                ),
            }) {
                .pending => {},
                .complete => |key| {
                    key_state.cursor.deinit();
                    const index = key_state.index;
                    if (!validStoreKey(key)) {
                        self.allocator.free(key);
                        return evaluator.failAtIndex(
                            .domain,
                            "pkg.store.gc expects canonical name-version-hash store keys",
                            index,
                        );
                    }
                    if (self.retained.contains(key)) {
                        self.allocator.free(key);
                    } else {
                        self.retained.putAssumeCapacityNoClobber(key, {});
                        self.retained_keys.appendAssumeCapacity(key);
                    }
                    self.state = .{ .keys = index + 1 };
                },
            },
            .env_ecl_start => self.state = .{ .env_ecl = evaluator.environLookup("ECL_CACHE") },
            .env_ecl => |*cursor| return self.lookupEnvironment(
                cursor,
                .env_xdg_start,
                .direct,
            ),
            .env_xdg_start => self.state = .{ .env_xdg = evaluator.environLookup("XDG_CACHE_HOME") },
            .env_xdg => |*cursor| return self.lookupEnvironment(
                cursor,
                .env_home_start,
                .xdg,
            ),
            .env_home_start => self.state = .{ .env_home = evaluator.environLookup("HOME") },
            .env_home => |*cursor| return self.lookupEnvironment(
                cursor,
                .no_environment,
                .home,
            ),
            .open_root => |path| {
                const directory = std.Io.Dir.cwd().openDir(self.io, path, .{
                    .follow_symlinks = false,
                    .iterate = true,
                }) catch |err| switch (err) {
                    error.FileNotFound => {
                        self.state = .{ .complete_path = path };
                        return .yielded;
                    },
                    else => return self.failIo(
                        evaluator,
                        path,
                        "cannot open package store for garbage collection",
                        err,
                    ),
                };
                self.state = .{ .scan = .{
                    .root = .{ .path = path, .dir = directory },
                    .iterator = directory.iterate(),
                } };
            },
            .scan => |*scan_state| {
                const entry = scan_state.iterator.next(self.io) catch |err|
                    return self.failIo(
                        evaluator,
                        scan_state.root.path,
                        "cannot enumerate package store for garbage collection",
                        err,
                    );
                if (entry == null) {
                    const root = scan_state.root;
                    self.state = .{ .complete_root = root };
                } else if (entry.?.kind == .directory) {
                    const stale = std.mem.startsWith(u8, entry.?.name, ".ecl-gc-");
                    if (stale or (validStoreKey(entry.?.name) and !self.retained.contains(entry.?.name))) {
                        const name = try self.allocator.dupe(u8, entry.?.name);
                        const scan = scan_state.*;
                        self.state = if (stale)
                            .{ .open_candidate = .{ .scan = scan, .trash = name } }
                        else
                            .{ .detach = .{ .scan = scan, .source = name } };
                    }
                }
            },
            .detach => |*candidate| {
                const identity = next_gc_identity.fetchAdd(1, .monotonic);
                const trash_name = try std.fmt.allocPrint(
                    self.allocator,
                    ".ecl-gc-{x}-{s}",
                    .{ identity, candidate.source },
                );
                candidate.scan.root.dir.rename(
                    candidate.source,
                    candidate.scan.root.dir,
                    trash_name,
                    self.io,
                ) catch |err| {
                    self.allocator.free(trash_name);
                    switch (err) {
                        error.DirNotEmpty => return .yielded,
                        error.FileNotFound => {
                            self.allocator.free(candidate.source);
                            const scan = candidate.scan;
                            self.state = .{ .scan = scan };
                            return .yielded;
                        },
                        else => return self.failIo(
                            evaluator,
                            candidate.scan.root.path,
                            "cannot detach unreferenced package store entry",
                            err,
                        ),
                    }
                };
                self.allocator.free(candidate.source);
                const scan = candidate.scan;
                self.removed += 1;
                self.state = .{ .open_candidate = .{
                    .scan = scan,
                    .trash = trash_name,
                } };
            },
            .open_candidate => |*candidate| {
                const directory = candidate.scan.root.dir.openDir(self.io, candidate.trash, .{
                    .follow_symlinks = false,
                    .iterate = true,
                }) catch |err| switch (err) {
                    error.FileNotFound => {
                        self.allocator.free(candidate.trash);
                        var scan = candidate.scan;
                        scan.iterator = scan.root.dir.iterate();
                        self.state = .{ .scan = scan };
                        return .yielded;
                    },
                    else => return self.failIo(
                        evaluator,
                        candidate.scan.root.path,
                        "cannot open detached package store entry",
                        err,
                    ),
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
                const scan = candidate.scan;
                const trash = candidate.trash;
                self.state = .{ .delete_tree = .{
                    .scan = scan,
                    .trash = trash,
                    .frame = frame,
                } };
            },
            .delete_tree => |*deletion| return self.deleteTree(evaluator, deletion),
            .delete_root => |*candidate| {
                candidate.scan.root.dir.deleteDir(self.io, candidate.trash) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return self.failIo(
                        evaluator,
                        candidate.scan.root.path,
                        "cannot remove detached package store entry",
                        err,
                    ),
                };
                self.allocator.free(candidate.trash);
                var scan = candidate.scan;
                scan.iterator = scan.root.dir.iterate();
                self.state = .{ .scan = scan };
            },
            .complete_path, .complete_root => return .{ .output = .{ .int = @intCast(self.removed) } },
            .no_environment => return evaluator.fail(
                .io,
                "pkg.store.gc needs ECL_CACHE, XDG_CACHE_HOME, or HOME to select a package store",
            ),
            .cleanup_frame,
            .cleanup_root,
            .cleanup_keys,
            .cleanup_value,
            .cleanup_destroy,
            => unreachable,
        }
        return .yielded;
    }

    const RootKind = enum { direct, xdg, home };

    fn lookupEnvironment(
        self: *GcDriver,
        cursor: *machine.Environ.LookupCursor,
        missing: State,
        kind: RootKind,
    ) MachineError!machine.WorkProgress {
        return switch (cursor.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |raw| complete: {
                const bytes = raw orelse "";
                if (bytes.len == 0) {
                    self.state = missing;
                    break :complete .yielded;
                }
                const path = switch (kind) {
                    .direct => try self.allocator.dupe(u8, bytes),
                    .xdg => std.fs.path.join(self.allocator, &.{ bytes, "ecl", "pkg" }) catch
                        return error.OutOfMemory,
                    .home => std.fs.path.join(self.allocator, &.{ bytes, ".cache", "ecl", "pkg" }) catch
                        return error.OutOfMemory,
                };
                self.state = .{ .open_root = path };
                break :complete .yielded;
            },
        };
    }
    fn deleteTree(
        self: *GcDriver,
        evaluator: *Machine,
        deletion: *@FieldType(State, "delete_tree"),
    ) MachineError!machine.WorkProgress {
        const frame = deletion.frame;
        const entry = frame.iterator.next(self.io) catch |err|
            return self.failIo(
                evaluator,
                deletion.scan.root.path,
                "cannot enumerate detached package store entry",
                err,
            );
        if (entry) |item| {
            if (item.kind != .directory) {
                frame.dir.?.deleteFile(self.io, item.name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return self.failIo(
                        evaluator,
                        deletion.scan.root.path,
                        "cannot remove detached package file",
                        err,
                    ),
                };
                return .yielded;
            }
            const name = try self.allocator.dupe(u8, item.name);
            const directory = frame.dir.?.openDir(self.io, name, .{
                .follow_symlinks = false,
                .iterate = true,
            }) catch |err| {
                self.allocator.free(name);
                return self.failIo(
                    evaluator,
                    deletion.scan.root.path,
                    "cannot open detached package directory",
                    err,
                );
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
            deletion.frame = child;
            return .yielded;
        }

        frame.dir.?.close(self.io);
        frame.dir = null;
        if (frame.parent) |parent| {
            parent.dir.?.deleteDir(self.io, frame.name.?) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return self.failIo(
                    evaluator,
                    deletion.scan.root.path,
                    "cannot remove detached package directory",
                    err,
                ),
            };
            self.allocator.free(frame.name.?);
            deletion.frame = parent;
            self.allocator.destroy(frame);
            return .yielded;
        }
        self.allocator.destroy(frame);
        const scan = deletion.scan;
        const trash = deletion.trash;
        self.state = .{ .delete_root = .{ .scan = scan, .trash = trash } };
        return .yielded;
    }

    fn failIo(
        self: *GcDriver,
        evaluator: *Machine,
        path: []const u8,
        message: []const u8,
        err: anyerror,
    ) MachineError {
        _ = self;
        return evaluator.failFmt(.io, "{s} `{s}`: {s}", .{ message, path, @errorName(err) });
    }

    fn beginRetirement(self: *GcDriver) void {
        switch (self.state) {
            .keys_capacity,
            .keys,
            .env_ecl_start,
            .env_ecl,
            .env_xdg_start,
            .env_xdg,
            .env_home_start,
            .env_home,
            .no_environment,
            => self.state = .{ .cleanup_root = .none },
            .key => |*key_state| {
                key_state.cursor.deinit();
                self.state = .{ .cleanup_root = .none };
            },
            .open_root, .complete_path => |path| {
                self.state = .{ .cleanup_root = .{ .path = path } };
            },
            .scan => |*scan| {
                const root = scan.root;
                self.state = .{ .cleanup_root = .{ .root = root } };
            },
            .detach => |*candidate| {
                self.allocator.free(candidate.source);
                const root = candidate.scan.root;
                self.state = .{ .cleanup_root = .{ .root = root } };
            },
            .open_candidate => |*candidate| {
                self.allocator.free(candidate.trash);
                const root = candidate.scan.root;
                self.state = .{ .cleanup_root = .{ .root = root } };
            },
            .delete_tree => |*deletion| {
                self.allocator.free(deletion.trash);
                const root = deletion.scan.root;
                const frame = deletion.frame;
                self.state = .{ .cleanup_frame = .{
                    .root = .{ .root = root },
                    .frame = frame,
                } };
            },
            .delete_root => |*candidate| {
                self.allocator.free(candidate.trash);
                const root = candidate.scan.root;
                self.state = .{ .cleanup_root = .{ .root = root } };
            },
            .complete_root => |root| {
                self.state = .{ .cleanup_root = .{ .root = root } };
            },
            .cleanup_frame,
            .cleanup_root,
            .cleanup_keys,
            .cleanup_value,
            .cleanup_destroy,
            => unreachable,
        }
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *GcDriver,
    ) bool {
        return switch (self.state) {
            .keys_capacity,
            .keys,
            .key,
            .env_ecl_start,
            .env_ecl,
            .env_xdg_start,
            .env_xdg,
            .env_home_start,
            .env_home,
            .open_root,
            .scan,
            .detach,
            .open_candidate,
            .delete_tree,
            .delete_root,
            .complete_path,
            .complete_root,
            .no_environment,
            => result: {
                self.beginRetirement();
                break :result false;
            },
            .cleanup_frame => |*cleanup| result: {
                const frame = cleanup.frame;
                const parent = frame.parent;
                if (frame.dir) |directory| directory.close(self.io);
                if (frame.name) |name| allocator.free(name);
                allocator.destroy(frame);
                if (parent) |next| {
                    cleanup.frame = next;
                } else {
                    const root = cleanup.root;
                    self.state = .{ .cleanup_root = root };
                }
                break :result false;
            },
            .cleanup_root => |*cleanup| result: {
                switch (cleanup.*) {
                    .none => {},
                    .path => |path| allocator.free(path),
                    .root => |root| {
                        root.dir.close(self.io);
                        allocator.free(root.path);
                    },
                }
                self.retained.deinit();
                self.state = .{ .cleanup_keys = 0 };
                break :result false;
            },
            .cleanup_keys => |index| result: {
                if (index != self.retained_keys.items.len) {
                    allocator.free(self.retained_keys.items[index]);
                    self.state = .{ .cleanup_keys = index + 1 };
                } else {
                    self.retained_keys.deinit(allocator);
                    self.state = .cleanup_value;
                }
                break :result false;
            },
            .cleanup_value => result: {
                self.retained_value.deinit(releases, allocator);
                self.state = .cleanup_destroy;
                break :result false;
            },
            .cleanup_destroy => {
                allocator.destroy(self);
                return true;
            },
        };
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
