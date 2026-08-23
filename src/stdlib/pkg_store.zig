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
        .name = "write-lock",
        .doc = "( text path -- ) Atomically replace a regular lock file while preserving it on failure.",
        .primitive = writeLock,
    },
};

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
