//! Private streaming storage uses the same confined publication primitives as
//! whole-file writes. Its resource owns the root lease and admission until join.
const std = @import("std");
const fs = @import("filesystem_port.zig");
const heap = @import("heap.zig");
const external = @import("external.zig");
const Identity = @import("module_bindings.zig").Identity;

const State = struct {
    issuer: *Identity,
    access: *external.FilesystemAccess,
    root: fs.RootSelection,
    slot: fs.OperationSlot,
    target: fs.Resolved,
    staged: fs.StagedFile,
    written: u64 = 0,
    phase: union(enum) { open, failed: fs.Reason, published } = .open,
    retirement: heap.ReleaseDomain.Retirement = .{},
    pub fn advanceRetirement(_: *heap.ReleaseDomain, _: std.mem.Allocator, self: *State) bool {
        return Stream.fromState(self).cleanupStep();
    }
};

pub const Stream = opaque {
    fn fromState(owned: *State) *Stream {
        return @ptrCast(owned);
    }
    fn state(self: *Stream) *State {
        return @ptrCast(@alignCast(self));
    }
    /// Consumes all three capabilities on success and failure. The caller has
    /// already validated an absent destination and created private storage.
    pub fn create(access: *external.FilesystemAccess, root: fs.RootSelection, slot: fs.OperationSlot, target: fs.Resolved, staged: fs.StagedFile) error{OutOfMemory}!*Stream {
        const issuer = fs.resourceIssuer(access);
        const owned = issuer.allocator().create(State) catch |err| {
            var file = staged;
            file.dispose();
            var destination = target;
            destination.deinit(issuer.allocator(), fs.hostIo(access));
            var admission = slot;
            admission.release();
            root.deinit();
            return err;
        };
        issuer.retain();
        owned.* = .{ .issuer = issuer, .access = access, .root = root, .slot = slot, .target = target, .staged = staged };
        return fromState(owned);
    }
    pub fn remaining(self: *Stream) u64 {
        const owned = self.state();
        return fs.limitsOf(owned.access).max_stream_transfer_bytes - owned.written;
    }
    pub fn failure(self: *Stream) ?fs.Reason {
        return switch (self.state().phase) {
            .failed => |reason| reason,
            .open, .published => null,
        };
    }
    pub fn fail(self: *Stream, reason: fs.Reason) void {
        if (self.state().phase == .open) self.state().phase = .{ .failed = reason };
    }
    /// Called under the resource lock before borrowing the active writer's file.
    pub fn prepareAppend(self: *Stream, length: usize) ?fs.Reason {
        if (self.failure()) |reason| return reason;
        if (length > fs.transfer_quantum or length > self.remaining()) {
            self.fail(.limit);
            return .limit;
        }
        return null;
    }
    /// The active FIFO claim pins storage across this unlocked host call.
    /// Queued writers cannot change the offset; closure waits for the claim.
    pub fn write(self: *Stream, bytes: []const u8) ?fs.Reason {
        const owned = self.state();
        owned.staged.file.?.writePositionalAll(fs.hostIo(owned.access), bytes, owned.written) catch |err|
            return fs.reasonForError(err);
        return null;
    }
    /// Publishes progress under the resource lock after the host call returns.
    pub fn finishAppend(self: *Stream, length: usize, failure_reason: ?fs.Reason) ?fs.Reason {
        if (failure_reason) |reason| self.fail(reason);
        if (self.failure()) |reason| return reason;
        self.state().written += length;
        return null;
    }
    pub fn commit(self: *Stream) ?fs.Reason {
        const owned = self.state();
        if (self.failure()) |reason| return reason;
        if (owned.phase == .published) return null;
        if (owned.staged.commitNoReplace(owned.target.entry.name)) |reason| return reason;
        owned.phase = .published;
        return null;
    }
    pub fn cleanupStep(self: *Stream) bool {
        const owned = self.state();
        const issuer = owned.issuer;
        owned.staged.dispose();
        owned.target.deinit(issuer.allocator(), fs.hostIo(owned.access));
        owned.slot.release();
        owned.root.deinit();
        issuer.allocator().destroy(owned);
        issuer.release();
        return true;
    }
    pub fn retire(self: *Stream) void {
        const owned = self.state();
        fs.retireHandle(owned.access, owned, &owned.retirement);
    }
};
