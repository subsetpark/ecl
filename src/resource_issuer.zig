//! Issuer identity for filesystem and archive resources: allocation
//! ownership and a counter for distinct resource identities, retained by
//! every resource the issuer created.
const std = @import("std");

const IdentityState = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    next_identity: std.atomic.Value(u64) = .init(1),
};

/// Retained issuer metadata stays valid after its service has joined. It
/// carries identity and allocation ownership, without operational authority.
pub const Identity = opaque {
    fn state(self: *Identity) *IdentityState {
        return @ptrCast(@alignCast(self));
    }
    pub fn create(memory: std.mem.Allocator) error{OutOfMemory}!*Identity {
        const owned = try memory.create(IdentityState);
        owned.* = .{ .allocator = memory };
        return @ptrCast(owned);
    }
    pub fn allocator(self: *Identity) std.mem.Allocator {
        return self.state().allocator;
    }
    pub fn next(self: *Identity) u64 {
        return self.state().next_identity.fetchAdd(1, .monotonic);
    }
    pub fn retain(self: *Identity) void {
        _ = self.state().refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Identity) void {
        const owned = self.state();
        if (owned.refs.fetchSub(1, .acq_rel) == 1) owned.allocator.destroy(owned);
    }
};
