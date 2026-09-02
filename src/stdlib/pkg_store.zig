//! Narrow package-store authority over the Session's retained store handles.
//!
//! Archive inspection and installation delegate to archive.zig's shared
//! hostile-input scanner. Every other word here addresses one immutable entry
//! by its canonical `<name>-<version>-<hex>` key inside the `'cache` or
//! `'vendor` store the package authority opened at Session construction; no
//! absolute path, raw handle, rename, or recursive-delete primitive reaches
//! ECL, and a Session without package authority fails closed.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const env = @import("../env.zig");
const fsport = @import("../filesystem_port.zig");
const machine = @import("../machine.zig");
const pkg_lock = @import("../pkg_lock.zig");
const storage = @import("../kernel_storage.zig");
const archive = @import("archive.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const work_quantum = machine.kernel_poll_quantum;
/// A stored manifest larger than the lock reader's own bound is invalid data.
const max_manifest_bytes: u64 = 16 * 1024 * 1024;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "inspect",
        .doc = "( bytes package-name -- manifest-text ) Validate a source package and return its exact root manifest.",
        .primitive = archive.inspectPackage,
    },
    .{
        .name = "install",
        .doc = "( bytes package-name store key -- regular-file-paths ) Validate and atomically install an immutable package under a canonical store key.",
        .primitive = archive.installPackage,
    },
    .{
        .name = "present?",
        .doc = "( store key -- bool ) Return 1 only when an immutable package directory is present under the key.",
        .primitive = present,
    },
    .{
        .name = "verify",
        .doc = "( store key package-name hash -- ) Stream and verify an installed package's sealed source archive.",
        .primitive = verify,
    },
    .{
        .name = "read-seal",
        .doc = "( store key package-name hash -- bytes ) Verify and return an installed package's exact sealed archive bytes.",
        .primitive = readSeal,
    },
    .{
        .name = "manifest",
        .doc = "( store key -- manifest-text ) Read an installed package's root manifest text.",
        .primitive = manifest,
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
    try evaluator.require(4);
    var hash_value = try evaluator.popValue();
    errdefer hash_value.deinit();
    if (!hash_value.borrow().isString()) return evaluator.typeError("a package hash");
    var package_value = try evaluator.popValue();
    errdefer package_value.deinit();
    if (!package_value.borrow().isString()) return evaluator.typeError("a package name");
    var key_value = try evaluator.popValue();
    errdefer key_value.deinit();
    if (!key_value.borrow().isString()) return evaluator.typeError("a string store key");
    var store_value = try evaluator.popValue();
    defer store_value.deinit();
    if (store_value.borrow() != .symbol) return evaluator.typeError("a store symbol");
    const store = try archive.packageStore(evaluator, store_value.borrow(), key_value.borrow());
    const key_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), key_value.borrow());
    const package_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), package_value.borrow());
    const hash_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), hash_value.borrow());
    try evaluator.startDriver(VerifyDriver{
        .mode = mode,
        .allocator = evaluator.allocator(),
        .io = evaluator.unit.inherited.host_io.?,
        .store = store,
        .key_value = .init(key_value.take()),
        .package_value = .init(package_value.take()),
        .hash_value = .init(hash_value.take()),
        .state = .{ .encode_key = .{
            .key = .init(key_encoder),
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
    store: std.Io.Dir,
    key_value: heap.Owned(Value),
    package_value: heap.Owned(Value),
    hash_value: heap.Owned(Value),
    state: State,
    buffer: [work_quantum]u8,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    digest: [32]u8 = @splat(0),
    rendered: [64]u8 = @splat(0),
    const Names = struct {
        key: heap.Owned([]u8),
        package: heap.Owned([]u8),
        hash: heap.Owned([]u8),

        fn deinit(self: *Names, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            self.hash.deinit(releases, allocator);
            self.package.deinit(releases, allocator);
            self.key.deinit(releases, allocator);
        }
    };
    const State = union(enum) {
        encode_key: struct {
            key: heap.Owned(storage.ToUtf8Cursor),
            package: heap.Owned(storage.ToUtf8Cursor),
            hash: heap.Owned(storage.ToUtf8Cursor),
        },
        encode_package: struct {
            key: heap.Owned([]u8),
            package: heap.Owned(storage.ToUtf8Cursor),
            hash: heap.Owned(storage.ToUtf8Cursor),
        },
        encode_hash: struct {
            key: heap.Owned([]u8),
            package: heap.Owned([]u8),
            hash: heap.Owned(storage.ToUtf8Cursor),
        },
        open: Names,
        stat: struct { names: Names, file: std.Io.File },
        read: struct {
            names: Names,
            file: std.Io.File,
            size: u64,
            offset: u64,
            contents: ?heap.Owned([]u8),
        },
        compare: struct { names: Names, contents: ?heap.Owned([]u8) },
        materialize: struct {
            names: Names,
            contents: heap.Owned([]u8),
            materializer: heap.Owned(list.ByteListMaterializer),
        },
        complete: struct { names: Names, contents: heap.Owned([]u8) },

        fn deinit(self: *State, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, io: std.Io) void {
            switch (self.*) {
                .encode_key => |*encode| {
                    encode.hash.deinit(releases, allocator);
                    encode.package.deinit(releases, allocator);
                    encode.key.deinit(releases, allocator);
                },
                .encode_package => |*encode| {
                    encode.hash.deinit(releases, allocator);
                    encode.package.deinit(releases, allocator);
                    encode.key.deinit(releases, allocator);
                },
                .encode_hash => |*encode| {
                    encode.hash.deinit(releases, allocator);
                    encode.package.deinit(releases, allocator);
                    encode.key.deinit(releases, allocator);
                },
                .open => |*names| names.deinit(releases, allocator),
                .stat => |*stat_state| {
                    stat_state.file.close(io);
                    stat_state.names.deinit(releases, allocator);
                },
                .read => |*read_state| {
                    read_state.file.close(io);
                    if (read_state.contents) |*contents| contents.deinit(releases, allocator);
                    read_state.names.deinit(releases, allocator);
                },
                .compare => |*compare_state| {
                    if (compare_state.contents) |*contents| contents.deinit(releases, allocator);
                    compare_state.names.deinit(releases, allocator);
                },
                .materialize => |*materialize_state| {
                    materialize_state.materializer.deinit(releases, allocator);
                    materialize_state.contents.deinit(releases, allocator);
                    materialize_state.names.deinit(releases, allocator);
                },
                .complete => |*complete| {
                    complete.contents.deinit(releases, allocator);
                    complete.names.deinit(releases, allocator);
                },
            }
        }
    };

    pub fn advance(evaluator: *Machine, self: *VerifyDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .encode_key => |*encode| self.encodeKey(evaluator, encode),
            .encode_package => |*encode| self.encodePackage(evaluator, encode),
            .encode_hash => |*encode| self.encodeHash(evaluator, encode),
            .open => |*names| self.open(evaluator, names),
            .stat => |*stat_state| self.stat(evaluator, stat_state),
            .read => |*read_state| self.read(evaluator, read_state),
            .compare => |*compare_state| self.compare(evaluator, compare_state),
            .materialize => |*materialize_state| self.materialize(evaluator, materialize_state),
            .complete => unreachable,
        };
    }

    fn encodeKey(
        self: *VerifyDriver,
        evaluator: *Machine,
        encode: *@FieldType(State, "encode_key"),
    ) MachineError!machine.WorkProgress {
        switch (encode.key.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package store key contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |key| {
                if (!pkg_lock.validStoreKey(key)) {
                    self.allocator.free(key);
                    return self.failDomain(evaluator, "package store key is not canonical");
                }
                const package_encoder = encode.package.take();
                const hash_encoder = encode.hash.take();
                encode.key.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .encode_package = .{
                    .key = .init(key),
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
                const key = encode.key.take();
                const hash_encoder = encode.hash.take();
                encode.package.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .encode_hash = .{
                    .key = .init(key),
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
                const key = encode.key.take();
                const package = encode.package.take();
                encode.hash.deinit(evaluator.releaseDomain(), evaluator.allocator());
                self.state = .{ .open = .{
                    .key = .init(key),
                    .package = .init(package),
                    .hash = .init(hash),
                } };
                return .yielded;
            },
        }
    }

    fn open(
        self: *VerifyDriver,
        evaluator: *Machine,
        names: *Names,
    ) MachineError!machine.WorkProgress {
        var entry = self.store.openDir(self.io, names.key.borrow(), .{ .follow_symlinks = false }) catch |err|
            return self.failIo(evaluator, "cannot open installed package entry", err);
        defer entry.close(self.io);
        const file = switch (fsport.openRegularForRead(self.io, entry, archive.package_seal_name)) {
            .failed => |reason| return self.failIoName(evaluator, reason.message()),
            .file => |file| file,
        };
        const moved_names = names.*;
        self.state = .{ .stat = .{ .names = moved_names, .file = file } };
        return .yielded;
    }

    fn stat(
        self: *VerifyDriver,
        evaluator: *Machine,
        stat_state: *@FieldType(State, "stat"),
    ) MachineError!machine.WorkProgress {
        const info = stat_state.file.stat(self.io) catch |err|
            return self.failIo(evaluator, "cannot inspect installed package archive seal", err);
        if (info.kind != .file) return self.failIoName(evaluator, "installed package archive seal is not a regular file");
        const contents: ?heap.Owned([]u8) = if (self.mode == .read) contents: {
            const length = std.math.cast(usize, info.size) orelse
                return self.failIoName(evaluator, "installed package archive seal is too large to materialize");
            break :contents .init(try self.allocator.alloc(u8, length));
        } else null;
        const names = stat_state.names;
        const file = stat_state.file;
        self.state = .{ .read = .{
            .names = names,
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
            const names = read_state.names;
            const contents = read_state.contents;
            read_state.file.close(self.io);
            self.hasher.final(&self.digest);
            self.rendered = std.fmt.bytesToHex(self.digest, .lower);
            self.state = .{ .compare = .{
                .names = names,
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
        if (!std.mem.eql(u8, compare_state.names.hash.borrow()[7..], &self.rendered))
            return evaluator.failFmt(
                .domain,
                "package `{s}` archive seal does not match lock hash",
                .{compare_state.names.package.borrow()},
            );
        if (self.mode == .verify) return .completed;
        const names = compare_state.names;
        const contents = compare_state.contents.?.take();
        self.state = .{ .materialize = .{
            .names = names,
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
                const names = materialize_state.names;
                const contents = materialize_state.contents.take();
                materialize_state.materializer.deinit(
                    evaluator.releaseDomain(),
                    evaluator.allocator(),
                );
                self.state = .{ .complete = .{
                    .names = names,
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
        evaluator.addErrorPath(self.key_value.borrow());
        return failure;
    }

    fn failIoName(self: *VerifyDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.failFmt(.io, "{s} for package `{s}`", .{ message, self.packageBytes() });
        evaluator.addErrorPath(self.key_value.borrow());
        return failure;
    }

    fn packageBytes(self: *VerifyDriver) []const u8 {
        return switch (self.state) {
            .encode_hash => |*encode| encode.package.borrow(),
            .open => |*names| names.package.borrow(),
            .stat => |*stat_state| stat_state.names.package.borrow(),
            .read => |*read_state| read_state.names.package.borrow(),
            .compare => |*compare_state| compare_state.names.package.borrow(),
            .materialize => |*materialize_state| materialize_state.names.package.borrow(),
            .complete => |*complete| complete.names.package.borrow(),
            .encode_key, .encode_package => unreachable,
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
        self.key_value.deinit(releases, allocator);
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

/// Pops `( store key )`, validates both, and returns the store handle with
/// the owned key value.
fn popStoreKey(evaluator: *Machine) MachineError!struct { store: std.Io.Dir, key: heap.OwnedValue } {
    try evaluator.require(2);
    var key_value = try evaluator.popValue();
    errdefer key_value.deinit();
    if (!key_value.borrow().isString()) return evaluator.typeError("a string store key");
    var store_value = try evaluator.popValue();
    defer store_value.deinit();
    if (store_value.borrow() != .symbol) return evaluator.typeError("a store symbol");
    const store = try archive.packageStore(evaluator, store_value.borrow(), key_value.borrow());
    return .{ .store = store, .key = key_value };
}

fn present(evaluator: *Machine) MachineError!void {
    var popped = try popStoreKey(evaluator);
    errdefer popped.key.deinit();
    const encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), popped.key.borrow());
    try evaluator.startDriver(PresentDriver{
        .allocator = evaluator.allocator(),
        .io = evaluator.unit.inherited.host_io.?,
        .store = popped.store,
        .key_value = .init(popped.key.take()),
        .encoder = .init(encoder),
    });
}

const PresentDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    allocator: std.mem.Allocator,
    io: std.Io,
    store: std.Io.Dir,
    key_value: heap.Owned(Value),
    encoder: heap.Owned(storage.ToUtf8Cursor),
    key: ?heap.Owned([]u8) = null,

    pub fn advance(evaluator: *Machine, self: *PresentDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.key == null) switch (self.encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package store key contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |key| {
                if (!pkg_lock.validStoreKey(key)) {
                    self.allocator.free(key);
                    return self.failDomain(evaluator, "package store key is not canonical");
                }
                self.key = .init(key);
                return .yielded;
            },
        };
        const info = self.store.statFile(
            self.io,
            self.key.?.borrow(),
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
        evaluator.addErrorPath(self.key_value.borrow());
        return failure;
    }

    fn failIoName(self: *PresentDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.key_value.borrow());
        return failure;
    }
};

fn manifest(evaluator: *Machine) MachineError!void {
    var popped = try popStoreKey(evaluator);
    errdefer popped.key.deinit();
    const encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), popped.key.borrow());
    try evaluator.startDriver(ManifestDriver{
        .allocator = evaluator.allocator(),
        .io = evaluator.unit.inherited.host_io.?,
        .store = popped.store,
        .key_value = .init(popped.key.take()),
        .state = .{ .encode = encoder },
    });
}

/// Reads one stored root manifest through the store handle and the entry's
/// own directory handle, never following a link at either level.
const ManifestDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    store: std.Io.Dir,
    key_value: heap.Owned(Value),
    state: State,

    const State = union(enum) {
        encode: storage.ToUtf8Cursor,
        open: []u8,
        read: struct { file: std.Io.File, buffer: []u8, offset: usize },
        text: struct { buffer: []u8, materializer: storage.Utf8Materializer },
        complete,
    };

    pub fn advance(evaluator: *Machine, self: *ManifestDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.state) {
            .encode => |*encoder| switch (encoder.advance(work_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCodepoint => return evaluator.fail(.domain, "package store key contains an invalid Unicode scalar"),
            }) {
                .pending => return .yielded,
                .complete => |key| {
                    encoder.deinit();
                    self.state = .{ .open = key };
                    if (!pkg_lock.validStoreKey(key))
                        return evaluator.fail(.domain, "package store key is not canonical");
                    return .yielded;
                },
            },
            .open => |key| {
                var entry = self.store.openDir(self.io, key, .{ .follow_symlinks = false }) catch |err|
                    return self.failIo(evaluator, "cannot open installed package entry", err);
                defer entry.close(self.io);
                const file = switch (fsport.openRegularForRead(self.io, entry, "ecl.pkg")) {
                    .failed => |reason| return self.failIoName(evaluator, reason.message()),
                    .file => |file| file,
                };
                const size = switch (fsport.regularFileInfo(self.io, file, max_manifest_bytes)) {
                    .failed => |reason| {
                        file.close(self.io);
                        return self.failIoName(evaluator, reason.message());
                    },
                    .regular => |info| info.size,
                };
                const buffer = self.allocator.alloc(u8, @intCast(size)) catch |err| {
                    file.close(self.io);
                    return err;
                };
                self.allocator.free(key);
                self.state = .{ .read = .{ .file = file, .buffer = buffer, .offset = 0 } };
                return .yielded;
            },
            .read => |*read| {
                switch (fsport.readQuantum(self.io, read.file, read.buffer, &read.offset)) {
                    .pending => return .yielded,
                    .failed => |reason| return self.failIoName(evaluator, reason.message()),
                    .complete => {},
                }
                read.file.close(self.io);
                const buffer = read.buffer;
                self.state = .{ .text = .{ .buffer = buffer, .materializer = .init(self.allocator, buffer) } };
                return .yielded;
            },
            .text => |*text| return switch (text.materializer.advance(work_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return self.failIoName(evaluator, "installed package manifest is not valid UTF-8"),
            }) {
                .pending => .yielded,
                .complete => |result| complete: {
                    text.materializer.deinit();
                    self.allocator.free(text.buffer);
                    self.state = .complete;
                    break :complete .{ .output = result };
                },
            },
            .complete => unreachable,
        }
    }

    fn failIo(self: *ManifestDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(.io, "{s}: {s}", .{ message, @errorName(err) });
        evaluator.addErrorPath(self.key_value.borrow());
        return failure;
    }

    fn failIoName(self: *ManifestDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.key_value.borrow());
        return failure;
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *ManifestDriver,
    ) bool {
        switch (self.state) {
            .encode => |*encoder| encoder.deinit(),
            .open => |key| allocator.free(key),
            .read => |*read| {
                read.file.close(self.io);
                allocator.free(read.buffer);
            },
            .text => |*text| {
                text.materializer.retire(releases);
                allocator.free(text.buffer);
            },
            .complete => {},
        }
        self.key_value.deinit(releases, allocator);
        allocator.destroy(self);
        return true;
    }
};

fn collectGarbage(evaluator: *Machine) MachineError!void {
    var retained_value = try evaluator.popValue();
    errdefer retained_value.deinit();
    if (retained_value.borrow() != .list)
        return evaluator.typeError("a list of retained package store keys");
    const access = evaluator.unit.inherited.package_access orelse
        return evaluator.fail(.domain, "package store authority is unavailable");
    try evaluator.startDriver(GcDriver{
        .allocator = evaluator.allocator(),
        .io = @import("../package_authority.zig").hostIo(access),
        .root = @import("../package_authority.zig").storeDir(access, .cache),
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
    /// The shared cache handle, borrowed from the package authority; null
    /// when the host selected no cache or it does not exist yet.
    root: ?std.Io.Dir,
    retained_value: heap.Owned(Value),
    retained: std.StringHashMap(void),
    retained_keys: std.ArrayList([]u8) = .empty,
    removed: usize = 0,
    state: State,

    const Scan = struct { dir: std.Io.Dir, iterator: std.Io.Dir.Iterator };
    const State = union(enum) {
        keys_capacity,
        keys: usize,
        key: struct { index: usize, cursor: storage.ToUtf8Cursor },
        open_root,
        scan: Scan,
        detach: struct { scan: Scan, source: []u8 },
        open_candidate: struct { scan: Scan, trash: []u8 },
        delete_tree: struct { scan: Scan, trash: []u8, frame: *GcDeleteFrame },
        delete_root: struct { scan: Scan, trash: []u8 },
        complete,
        cleanup_frame: *GcDeleteFrame,
        cleanup_root,
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
                    self.state = .open_root;
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
                    if (!pkg_lock.validStoreKey(key)) {
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
            .open_root => {
                const root = self.root orelse {
                    self.state = .complete;
                    return .yielded;
                };
                self.state = .{ .scan = .{ .dir = root, .iterator = root.iterate() } };
            },
            .scan => |*scan_state| {
                const entry = scan_state.iterator.next(self.io) catch |err|
                    return self.failIo(evaluator, "cannot enumerate package store for garbage collection", err);
                if (entry == null) {
                    self.state = .complete;
                } else if (entry.?.kind == .directory) {
                    const stale = std.mem.startsWith(u8, entry.?.name, ".ecl-gc-");
                    if (stale or (pkg_lock.validStoreKey(entry.?.name) and !self.retained.contains(entry.?.name))) {
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
                candidate.scan.dir.rename(
                    candidate.source,
                    candidate.scan.dir,
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
                        else => return self.failIo(evaluator, "cannot detach unreferenced package store entry", err),
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
                const directory = candidate.scan.dir.openDir(self.io, candidate.trash, .{
                    .follow_symlinks = false,
                    .iterate = true,
                }) catch |err| switch (err) {
                    error.FileNotFound => {
                        self.allocator.free(candidate.trash);
                        var scan = candidate.scan;
                        scan.iterator = scan.dir.iterate();
                        self.state = .{ .scan = scan };
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
                candidate.scan.dir.deleteDir(self.io, candidate.trash) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return self.failIo(evaluator, "cannot remove detached package store entry", err),
                };
                self.allocator.free(candidate.trash);
                var scan = candidate.scan;
                scan.iterator = scan.dir.iterate();
                self.state = .{ .scan = scan };
            },
            .complete => return .{ .output = .{ .int = @intCast(self.removed) } },
            .cleanup_frame,
            .cleanup_root,
            .cleanup_keys,
            .cleanup_value,
            .cleanup_destroy,
            => unreachable,
        }
        return .yielded;
    }

    fn deleteTree(
        self: *GcDriver,
        evaluator: *Machine,
        deletion: *@FieldType(State, "delete_tree"),
    ) MachineError!machine.WorkProgress {
        const frame = deletion.frame;
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
            deletion.frame = child;
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
        message: []const u8,
        err: anyerror,
    ) MachineError {
        _ = self;
        return evaluator.failFmt(.io, "{s} in the package cache: {s}", .{ message, @errorName(err) });
    }

    fn beginRetirement(self: *GcDriver) void {
        switch (self.state) {
            .keys_capacity, .keys, .open_root, .scan, .complete => self.state = .cleanup_root,
            .key => |*key_state| {
                key_state.cursor.deinit();
                self.state = .cleanup_root;
            },
            .detach => |*candidate| {
                self.allocator.free(candidate.source);
                self.state = .cleanup_root;
            },
            .open_candidate => |*candidate| {
                self.allocator.free(candidate.trash);
                self.state = .cleanup_root;
            },
            .delete_tree => |*deletion| {
                self.allocator.free(deletion.trash);
                self.state = .{ .cleanup_frame = deletion.frame };
            },
            .delete_root => |*candidate| {
                self.allocator.free(candidate.trash);
                self.state = .cleanup_root;
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
            .open_root,
            .scan,
            .detach,
            .open_candidate,
            .delete_tree,
            .delete_root,
            .complete,
            => result: {
                self.beginRetirement();
                break :result false;
            },
            .cleanup_frame => |frame| result: {
                const parent = frame.parent;
                if (frame.dir) |directory| directory.close(self.io);
                if (frame.name) |name| allocator.free(name);
                allocator.destroy(frame);
                self.state = if (parent) |next| .{ .cleanup_frame = next } else .cleanup_root;
                break :result false;
            },
            .cleanup_root => result: {
                // The cache handle is borrowed from the package authority and
                // stays open for the Session.
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
