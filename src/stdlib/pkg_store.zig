//! Narrow filesystem authority for immutable package-store entries and locks.
//!
//! Archive inspection and installation delegate to archive.zig's shared
//! hostile-input scanner. This module owns only the public capability table,
//! destination probing, and atomic lock replacement; it exposes no raw handle,
//! rename, or recursive-delete primitive to ECL.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
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
        .name = "write-lock",
        .doc = "( text path -- ) Atomically replace a regular project data file while preserving it on failure.",
        .primitive = writeLock,
    },
};

fn verify(evaluator: *Machine) MachineError!void {
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
        .allocator = evaluator.allocator(),
        .io = io,
        .destination_value = .init(destination_value.take()),
        .package_value = .init(package_value.take()),
        .hash_value = .init(hash_value.take()),
        .destination_encoder = .init(destination_encoder),
        .package_encoder = .init(package_encoder),
        .hash_encoder = .init(hash_encoder),
        // SAFETY: each hashed slice is fully initialized by readPositionalAll before use.
        .buffer = undefined,
    });
}

const VerifyDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    destination_value: heap.Owned(Value),
    package_value: heap.Owned(Value),
    hash_value: heap.Owned(Value),
    destination_encoder: heap.Owned(storage.ToUtf8Cursor),
    package_encoder: heap.Owned(storage.ToUtf8Cursor),
    hash_encoder: heap.Owned(storage.ToUtf8Cursor),
    destination: ?heap.Owned([]u8) = null,
    package: ?heap.Owned([]u8) = null,
    hash: ?heap.Owned([]u8) = null,
    seal_path: ?heap.Owned([]u8) = null,
    file: ?std.Io.File = null,
    size: u64 = 0,
    offset: u64 = 0,
    buffer: [work_quantum]u8,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    digest: [32]u8 = @splat(0),
    rendered: [64]u8 = @splat(0),
    phase: enum { encode_destination, encode_package, encode_hash, open, stat, read, compare } = .encode_destination,

    pub fn advance(evaluator: *Machine, self: *VerifyDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.phase) {
            .encode_destination => self.encodeDestination(evaluator),
            .encode_package => self.encodePackage(evaluator),
            .encode_hash => self.encodeHash(evaluator),
            .open => self.open(evaluator),
            .stat => self.stat(evaluator),
            .read => self.read(evaluator),
            .compare => self.compare(evaluator),
        };
    }

    fn encodeDestination(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.destination_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package destination contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |destination| {
                if (destination.len == 0) {
                    self.allocator.free(destination);
                    return self.failDomain(evaluator, "package destination is empty");
                }
                self.destination = .init(destination);
                self.phase = .encode_package;
                return .yielded;
            },
        }
    }

    fn encodePackage(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.package_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package name contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |package| {
                if (package.len == 0) {
                    self.allocator.free(package);
                    return self.failDomain(evaluator, "package name is empty");
                }
                self.package = .init(package);
                self.phase = .encode_hash;
                return .yielded;
            },
        }
    }

    fn encodeHash(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.hash_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package hash contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |hash| {
                if (!isSha256(hash)) {
                    self.allocator.free(hash);
                    return self.failDomain(evaluator, "a package hash is sha256- and 64 lowercase hex digits");
                }
                self.hash = .init(hash);
                self.seal_path = .init(try std.fs.path.join(self.allocator, &.{
                    self.destination.?.borrow(),
                    archive.package_seal_name,
                }));
                self.phase = .open;
                return .yielded;
            },
        }
    }

    fn open(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        self.file = std.Io.Dir.cwd().openFile(self.io, self.seal_path.?.borrow(), .{}) catch |err|
            return self.failIo(evaluator, "cannot open installed package archive seal", err);
        self.phase = .stat;
        return .yielded;
    }

    fn stat(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const info = self.file.?.stat(self.io) catch |err|
            return self.failIo(evaluator, "cannot inspect installed package archive seal", err);
        self.size = info.size;
        self.phase = .read;
        return .yielded;
    }

    fn read(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.offset == self.size) {
            self.file.?.close(self.io);
            self.file = null;
            self.hasher.final(&self.digest);
            self.rendered = std.fmt.bytesToHex(self.digest, .lower);
            self.phase = .compare;
            return .yielded;
        }
        const amount: usize = @intCast(@min(@as(u64, work_quantum), self.size - self.offset));
        const read_amount = self.file.?.readPositionalAll(self.io, self.buffer[0..amount], self.offset) catch |err|
            return self.failIo(evaluator, "cannot read installed package archive seal", err);
        if (read_amount != amount)
            return self.failIoName(evaluator, "installed package archive seal changed while being read");
        self.hasher.update(self.buffer[0..amount]);
        self.offset += amount;
        return .yielded;
    }

    fn compare(self: *VerifyDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (!std.mem.eql(u8, self.hash.?.borrow()[7..], &self.rendered))
            return evaluator.failFmt(
                .domain,
                "package `{s}` archive seal does not match lock hash",
                .{self.package.?.borrow()},
            );
        return .completed;
    }

    fn failDomain(self: *VerifyDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    fn failIo(self: *VerifyDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(
            .io,
            "{s} for package `{s}`: {s}",
            .{ message, self.package.?.borrow(), @errorName(err) },
        );
        evaluator.addErrorPath(self.destination_value.borrow());
        return failure;
    }

    fn failIoName(self: *VerifyDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.failFmt(.io, "{s} for package `{s}`", .{ message, self.package.?.borrow() });
        evaluator.addErrorPath(self.destination_value.borrow());
        return failure;
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *VerifyDriver,
    ) bool {
        if (self.file) |file| file.close(self.io);
        if (self.seal_path) |*path| path.deinit(releases, allocator);
        if (self.hash) |*hash| hash.deinit(releases, allocator);
        if (self.package) |*package| package.deinit(releases, allocator);
        if (self.destination) |*destination| destination.deinit(releases, allocator);
        self.hash_encoder.deinit(releases, allocator);
        self.package_encoder.deinit(releases, allocator);
        self.destination_encoder.deinit(releases, allocator);
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

fn writeLock(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var path_value = try evaluator.popValue();
    errdefer path_value.deinit();
    if (!path_value.borrow().isString()) return evaluator.typeError("a string lock path");
    var text_value = try evaluator.popValue();
    errdefer text_value.deinit();
    if (!text_value.borrow().isString()) return evaluator.typeError("lock text");
    const io = evaluator.unit.inherited.host_io orelse {
        const failure = evaluator.fail(.io, "lock publication is unavailable");
        evaluator.addErrorPath(path_value.borrow());
        return failure;
    };
    const text_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), text_value.borrow());
    const path_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), path_value.borrow());
    try evaluator.startDriver(WriteLockDriver{
        .allocator = evaluator.allocator(),
        .io = io,
        .text_value = .init(text_value.take()),
        .path_value = .init(path_value.take()),
        .text_encoder = .init(text_encoder),
        .path_encoder = .init(path_encoder),
    });
}

var next_lock_identity: std.atomic.Value(u64) = .init(1);

const WriteLockDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    text_value: heap.Owned(Value),
    path_value: heap.Owned(Value),
    text_encoder: heap.Owned(storage.ToUtf8Cursor),
    path_encoder: heap.Owned(storage.ToUtf8Cursor),
    text: ?heap.Owned([]u8) = null,
    path: ?heap.Owned([]u8) = null,
    temp_path: ?heap.Owned([]u8) = null,
    file: ?std.Io.File = null,
    offset: usize = 0,
    temp_created: bool = false,
    published: bool = false,
    phase: enum { encode_text, encode_path, inspect, create, write, sync_close, recheck, publish } = .encode_text,

    pub fn advance(evaluator: *Machine, self: *WriteLockDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.phase) {
            .encode_text => self.encodeText(evaluator),
            .encode_path => self.encodePath(evaluator),
            .inspect => self.inspectTarget(evaluator, .create),
            .create => self.createTemp(evaluator),
            .write => self.writeChunk(evaluator),
            .sync_close => self.syncClose(evaluator),
            .recheck => self.inspectTarget(evaluator, .publish),
            .publish => self.publish(evaluator),
        };
    }

    fn encodeText(self: *WriteLockDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.text_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "lock text contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |text| {
                self.text = .init(text);
                self.phase = .encode_path;
                return .yielded;
            },
        }
    }

    fn encodePath(self: *WriteLockDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.path_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "lock path contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| {
                if (path.len == 0) {
                    self.allocator.free(path);
                    return self.failDomain(evaluator, "lock path is empty");
                }
                self.path = .init(path);
                self.phase = .inspect;
                return .yielded;
            },
        }
    }

    fn inspectTarget(
        self: *WriteLockDriver,
        evaluator: *Machine,
        next: @TypeOf(self.phase),
    ) MachineError!machine.WorkProgress {
        const info = std.Io.Dir.cwd().statFile(
            self.io,
            self.path.?.borrow(),
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                self.phase = next;
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot inspect lock target", err),
        };
        if (info.kind != .file) return self.failIoName(evaluator, "lock target is not a regular file");
        self.phase = next;
        return .yielded;
    }

    fn createTemp(self: *WriteLockDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.temp_path == null) {
            const identity = next_lock_identity.fetchAdd(1, .monotonic);
            const path = self.path.?.borrow();
            const parent = std.fs.path.dirname(path) orelse ".";
            self.temp_path = .init(try std.fmt.allocPrint(
                self.allocator,
                "{s}{c}.ecl-lock-{x}-{s}",
                .{ parent, std.fs.path.sep, identity, std.fs.path.basename(path) },
            ));
        }
        self.file = std.Io.Dir.cwd().createFile(self.io, self.temp_path.?.borrow(), .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.temp_path.?.deinit(evaluator.releaseDomain(), self.allocator);
                self.temp_path = null;
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot create lock temporary file", err),
        };
        self.temp_created = true;
        self.phase = .write;
        return .yielded;
    }

    fn writeChunk(self: *WriteLockDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const text = self.text.?.borrow();
        if (self.offset != text.len) {
            const end = @min(self.offset + work_quantum, text.len);
            self.file.?.writePositionalAll(self.io, text[self.offset..end], self.offset) catch |err|
                return self.failIo(evaluator, "cannot write lock temporary file", err);
            self.offset = end;
            return .yielded;
        }
        self.phase = .sync_close;
        return .yielded;
    }

    fn syncClose(self: *WriteLockDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        self.file.?.sync(self.io) catch |err|
            return self.failIo(evaluator, "cannot synchronize lock temporary file", err);
        self.file.?.close(self.io);
        self.file = null;
        self.phase = .recheck;
        return .yielded;
    }

    fn publish(self: *WriteLockDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const path = self.path.?.borrow();
        const parent_path = std.fs.path.dirname(path) orelse ".";
        var parent = std.Io.Dir.cwd().openDir(self.io, parent_path, .{ .follow_symlinks = false }) catch |err|
            return self.failIo(evaluator, "cannot open lock parent", err);
        defer parent.close(self.io);
        parent.rename(
            std.fs.path.basename(self.temp_path.?.borrow()),
            parent,
            std.fs.path.basename(path),
            self.io,
        ) catch |err| return self.failIo(evaluator, "cannot publish lock", err);
        self.published = true;
        self.temp_created = false;
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

    fn failIoName(self: *WriteLockDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.path_value.borrow());
        return failure;
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *WriteLockDriver,
    ) bool {
        if (self.file) |file| file.close(self.io);
        self.file = null;
        if (!self.published and self.temp_created) {
            std.Io.Dir.cwd().deleteFile(self.io, self.temp_path.?.borrow()) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.log.err("package lock rollback could not remove its temporary file: {s}", .{@errorName(err)}),
            };
            self.temp_created = false;
            return false;
        }
        if (self.temp_path) |*path| path.deinit(releases, allocator);
        if (self.path) |*path| path.deinit(releases, allocator);
        if (self.text) |*text| text.deinit(releases, allocator);
        self.text_encoder.deinit(releases, allocator);
        self.path_encoder.deinit(releases, allocator);
        self.text_value.deinit(releases, allocator);
        self.path_value.deinit(releases, allocator);
        allocator.destroy(self);
        return true;
    }
};
